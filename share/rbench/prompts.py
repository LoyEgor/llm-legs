import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
from collections import Counter
from pathlib import Path

from . import store as _store
from . import raters as _raters
from . import accounts as _accounts

READ_ONLY_REVIEW_INSTRUCTION = (
    "You are read-only: do not run checkout, restore, reset, clean, stash, revert, commit, "
    "or any other Git command that changes the tree or refs; return findings only."
)
# Toolless raters get a vendor review methodology injected into the prompt. The text
# is read from the installed skill so a cell measures the real published guidance;
# a missing file fails the cell instead of quietly reviewing without methodology.
REVIEW_PROFILE_FILES = {
    "anthropic": Path.home() / ".claude/plugins/marketplaces/claude-plugins-official"
                 / "plugins/code-review/commands/code-review.md",
    "google": Path.home() / ".gemini/extensions/code-review/skills"
              / "code-review-commons/SKILL.md",
}
REVIEW_PROFILES = tuple(REVIEW_PROFILE_FILES)
# A lens swaps the reviewer's methodology for a registered one while the rest of the pipeline —
# targets, severities, recording — stays the tool's. Registered rather than passed as a file so
# a run records a slug whose text is reconstructible, and versioned next to the tool that reads
# it; REVIEW_BENCH_LENS_DIR redirects the whole registry for tests.
LENS_DIR = _store.REPO_ROOT / "lenses"
LENS_SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
LENS_FRONTMATTER_KEYS = ("name", "when", "source", "source_hash", "repeats", "aliases")
LENS_SEVERITIES = ("P1", "P2", "P3")
# The OpenCode raters already spend their prompt on a vendor profile and the Antigravity raters
# receive no methodology at all — they run their own installed review skill from a literal
# "/code-review". Either one would record a lens against a panel that never read it.
LENS_EXCLUDED_SIDES = ("opencode", "agy")
LENS_FLAG_HELP = (
    "Review with this registered lens instead of the raters' own methodology "
    "(review-bench lens list)"
)
def normalize_severity(value):
    match = _raters.PRIORITY_RE.search(str(value or ""))
    return match.group(1).upper() if match else None


def finding_from_dict(value, rater):
    severity = normalize_severity(
        value.get("severity") or value.get("priority") or value.get("title")
    )
    if not severity:
        if not (value.get("file") and value.get("summary")):
            return None
        severity = "P3"
    location = value.get("code_location") or value.get("location") or {}
    if not isinstance(location, dict):
        location = {}
    file_name = (
        value.get("file")
        or value.get("path")
        or location.get("absolute_file_path")
        or location.get("file")
        or ""
    )
    line = value.get("line")
    if line is None:
        line = value.get("line_number")
    line_range = location.get("line_range") or {}
    if line is None and isinstance(line_range, dict):
        line = line_range.get("start")
    try:
        line = int(line) if line is not None else None
    except (TypeError, ValueError):
        line = None
    summary = value.get("summary") or value.get("title") or value.get("body") or ""
    summary = _raters.PRIORITY_RE.sub("", str(summary), count=1).strip(" []:-")
    if not summary:
        return None
    # Codex writes the location into the prose and leaves `file` empty; unrecovered, the
    # claim has nowhere to be verified or deduplicated against.
    if not file_name:
        location = _raters.LOCATION_RE.search(summary)
        if location:
            file_name = location.group("file").strip("`'\"()[],.")
            if line is None:
                line = int(location.group("line"))
    return {"severity": severity, "file": str(file_name), "line": line,
            "summary": " ".join(summary.split()), "rater": rater}


def findings_from_value(value, rater):
    findings = []
    if isinstance(value, dict):
        direct = finding_from_dict(value, rater)
        if direct:
            findings.append(direct)
        for key, nested in value.items():
            if key in {"findings", "result", "message", "content", "text", "output_text", "item"}:
                if isinstance(nested, str):
                    findings.extend(normalize_findings(nested, rater))
                else:
                    findings.extend(findings_from_value(nested, rater))
    elif isinstance(value, list):
        for nested in value:
            findings.extend(findings_from_value(nested, rater))
    return findings


def normalize_findings(text, rater):
    findings = []
    for value in _store.extract_json_values(text):
        findings.extend(findings_from_value(value, rater))
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(("{", "[")):
            continue
        severity = normalize_severity(line)
        if not severity:
            continue
        location = _raters.LOCATION_RE.search(line)
        summary = _raters.PRIORITY_RE.sub("", line, count=1).strip(" -*[]:—")
        if location:
            summary = summary.replace(location.group(0), "").strip(" -:—()`")
        if summary:
            findings.append({
                "severity": severity,
                "file": location.group("file").strip("`'\"()[]") if location else "",
                "line": int(location.group("line")) if location else None,
                "summary": " ".join(summary.split()),
                "rater": rater,
            })
    unique = []
    seen = set()
    for finding in findings:
        key = (finding["severity"], finding["file"], finding["line"], finding["summary"])
        if key not in seen:
            seen.add(key)
            unique.append(finding)
    return unique


def normalize_codex_stream(text, rater, repo):
    return normalize_findings(text, rater)


def normalize_claude_output(text, rater, repo):
    return normalize_findings(text, rater)


def normalize_json_objects(text):
    objects = [
        value
        for value in _store.extract_json_values(text)
        if isinstance(value, dict)
    ]
    if not objects:
        return text
    return "\n".join(json.dumps(value, ensure_ascii=False) for value in objects)


AGY_SKILL_SEVERITIES = {
    "CRITICAL": "P1",
    "HIGH": "P1",
    "P1": "P1",
    "MEDIUM": "P2",
    "MODERATE": "P2",
    "P2": "P2",
    "LOW": "P3",
    "INFO": "P3",
    "P3": "P3",
}


def agy_structured_clean_review(text):
    body = (text or "").strip()
    output = re.search(
        r"(?:^|\n)<OUTPUT>\s*(.*?)\s*</OUTPUT>\s*$", body,
        re.IGNORECASE | re.DOTALL,
    )
    candidate = output.group(1).strip() if output else body
    surrounding = body[:output.start()].strip() if output else ""
    fence = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", candidate, re.IGNORECASE | re.DOTALL)
    if fence:
        candidate = fence.group(1).strip()
    try:
        document = json.loads(candidate)
    except (TypeError, ValueError):
        return False
    if not isinstance(document, dict) or not document:
        return False
    if not set(document).issubset({"comments", "findings"}):
        return False
    if not all(value == [] for value in document.values()):
        return False
    if (
        contains_clean_token(surrounding, CLEAN_PROSE_BLOCKERS)
        or CLEAN_TRUNCATION_RE.search(surrounding)
    ):
        return False
    return not any(
        contains_clean_token(sentence, CLEAN_DEFECT_TOKENS)
        and not contains_clean_token(sentence, CLEAN_NEGATION_TOKENS)
        for sentence in clean_review_sentences(surrounding)
    )


def normalize_agy_skill_output(text, rater):
    if re.search(r"\bNo git repository detected\b", text, re.IGNORECASE):
        raise ValueError("agy -skill did not enter the sealed git repository")
    findings = []
    current_file = ""
    lines = text.splitlines()
    file_re = re.compile(r"^##\s+File:\s+(.+?)\s*$", re.IGNORECASE)
    issue_re = re.compile(
        r"^###\s+(?:L(?P<plain>\d+)(?:-L?\d+)?|"
        r"\[L(?P<linked>\d+)(?:-L?\d+)?\]\([^)]+\))"
        r"\s*:\s*\[(?P<severity>[A-Za-z0-9]+)\]\s*(?P<title>.+?)\s*$"
    )
    for index, line in enumerate(lines):
        file_match = file_re.match(line.strip())
        if file_match:
            current_file = file_match.group(1).strip(" `")
            continue
        issue_match = issue_re.match(line.strip())
        if not issue_match or not current_file:
            continue
        line_number = issue_match.group("plain") or issue_match.group("linked")
        raw_severity = issue_match.group("severity")
        title = issue_match.group("title")
        severity = AGY_SKILL_SEVERITIES.get(raw_severity.upper())
        if not severity:
            continue
        details = []
        for following in lines[index + 1:]:
            stripped = following.strip()
            if stripped.startswith(("### ", "## ")):
                break
            if stripped == "Suggested change:" or stripped.startswith("```"):
                break
            if stripped:
                details.append(stripped)
        summary = title.strip()
        if details:
            summary += " — " + " ".join(details)
        findings.append({
            "severity": severity,
            "file": current_file,
            "line": int(line_number),
            "summary": " ".join(summary.split()),
            "rater": rater,
        })
    if not findings:
        for line in lines:
            severity = normalize_severity(line)
            location = _raters.LOCATION_RE.search(line)
            if not (severity and location):
                continue
            summary = _raters.PRIORITY_RE.sub("", line, count=1)
            summary = summary.replace(location.group(0), "").strip(" -*[]:—`()")
            if summary:
                findings.append({
                    "severity": severity,
                    "file": location.group("file").strip("`'\"()[]"),
                    "line": int(location.group("line")),
                    "summary": " ".join(summary.split()),
                    "rater": rater,
                })
    clean = (
        re.search(r"\bNo issues found\b", text, re.IGNORECASE)
        or agy_structured_clean_review(text)
    )
    if not findings and not clean:
        raise ValueError(
            "agy -skill returned malformed Markdown: expected /code-review findings "
            "or an explicit no-issues result"
        )
    return "\n".join(json.dumps(row, ensure_ascii=False) for row in findings) or '{"findings":[]}'


# A clean review and a rater that answered in prose or stopped mid-turn are the same empty
# findings file, and only an explicit marker tells a result from a cell that must be rerun.
CLEAN_REVIEW_MARKER = "NO FINDINGS"
CLEAN_REVIEW_RE = re.compile(
    r"no findings|no issues found|\{\s*\"findings\"\s*:\s*\[\s*\]\s*\}", re.IGNORECASE
)
# The two shapes the review contract accepts, as an extended regex for opencode-go's
# --answer-must-match. Kept beside CLEAN_REVIEW_RE because it is the same contract read by the
# transport: a model whose answer went into its reasoning field leaves a one-line announce that
# matches neither, and only that lets the reasoning-off negotiation move to its next strategy.
# Named fields, not a bare brace: an announce that quotes the requested format carries one, and
# accepting it is how the negotiation stops on the strategy that produced no review.
OPENCODE_ANSWER_SHAPE = r"\"severity\"|\"findings\"|no findings|no issues found"
# The verifier answers a verdict object, not findings, so it needs its own shape or the same
# announce-only reply stops on the first strategy and the finding is kept unchecked: a fail-open
# row reads exactly like a verified one.
OPENCODE_VERDICT_SHAPE = r"\"code_matches\""
CLEAN_ASSERTION_VERBS = (
    "found", "was", "were", "is", "are", "exists", "detected", "identified", "confirmed",
    "has", "have", "contains", "contain", "remains", "remain",
)
CLEAN_NEGATION_TOKENS = ("no", "not", "don't", "do not", "none", "without")
CLEAN_DEFECT_TOKENS = (
    "finding", "findings", "issue", "issues", "defect", "defects", "bug", "bugs",
    "regression", "regressions", "problem", "problems", "loss", "losses",
)
CLEAN_CLAIM_QUANTIFIERS = (
    "a", "an", "one", "two", "three", "four", "five", "some", "several", "multiple",
)
CLEAN_PRAISE_TOKENS = (
    "correctly", "correct", "passes", "pass", "covers", "cover", "coverage", "validates",
    "valid", "sound", "safe", "as intended", "matches", "hermetic", "addresses", "handles",
    "successfully", "consistent",
)
CLEAN_CONTRAST_TOKENS = (
    "except", "but", "however", "other than", "aside", "apart", "though", "although",
    "yet", "nevertheless", "nonetheless", "that said",
)
CLEAN_FAILURE_TOKENS = (
    "could not", "couldn't", "unable", "cannot", "can't", "failed", "error", "timed out",
    "fail", "fails", "failing", "failure", "failures",
)
# A praise word does not vouch for the rest of its sentence: "correctly handles X while
# silently dropping Y" is a defect claim, so defect verbs block the whole answer.
CLEAN_DEFECT_VERBS = (
    "break", "breaks", "broken", "leak", "leaks", "leaking", "crash", "crashes", "crashing",
    "drop", "drops", "dropping", "violate", "violates", "regress", "regresses",
    "corrupt", "corrupts", "lose", "loses", "losing", "lost", "exhaust", "exhausts",
    "incorrect", "incorrectly", "wrong", "wrongly", "improper", "improperly",
    "bypass", "bypasses", "bypassed", "bypassing", "omit", "omits", "omitted", "omitting",
    "skip", "skips", "skipped", "skipping", "ignore", "ignores", "ignored", "ignoring",
)
CLEAN_SEVERITY_TOKENS = ("p1", "p2", "p3", "severity")
CLEAN_ANNOUNCE_BLOCKERS = (
    CLEAN_ASSERTION_VERBS + CLEAN_CLAIM_QUANTIFIERS + CLEAN_CONTRAST_TOKENS
    + CLEAN_FAILURE_TOKENS + CLEAN_SEVERITY_TOKENS + CLEAN_DEFECT_VERBS
)
CLEAN_PROSE_BLOCKERS = (
    CLEAN_CONTRAST_TOKENS + CLEAN_FAILURE_TOKENS + CLEAN_SEVERITY_TOKENS
    + CLEAN_DEFECT_VERBS
)
CLEAN_MARKER_TAIL_RE = re.compile(r"no findings\.?$", re.IGNORECASE)
# "Regression: …"/"Bug: …" is a finding stated as a label, not an announcement of intent —
# but a defect noun elsewhere in a preamble stays legal ("Reviewing the diff for issues").
CLEAN_DEFECT_LABEL_RE = re.compile(
    rf"^(?:{'|'.join(re.escape(token) for token in CLEAN_DEFECT_TOKENS)})\s*:",
    re.IGNORECASE,
)
CLEAN_PATH_RE = re.compile(r"\S+\.[a-z]{2,4}\b|\w+/\w+")
# Announce preambles say things like "for logic/correctness issues"; only a dotted file
# name is a location signal there, while prose answers keep the stricter slash test.
CLEAN_ANNOUNCE_PATH_RE = re.compile(r"\S+\.[a-z]{2,4}\b")
CLEAN_LINE_RE = re.compile(r"\bline\s+\d+\b|:\d+\b", re.IGNORECASE)
CLEAN_TRUNCATION_RE = re.compile(r"\btruncat\w*", re.IGNORECASE)


ANSWER_KEYS = frozenset({"result", "message", "text", "content", "answer", "output"})


def clean_marker_candidates(text):
    body = (text or "").strip()
    fence = re.fullmatch(r"```[A-Za-z]*\s*(.*?)\s*```", body, re.DOTALL)
    if fence:
        body = fence.group(1)
    yield body
    # Claude hands over its whole result envelope and Codex appends event JSON to the answer,
    # so a clean review arrives as a string inside JSON rather than as the entire text. Only the
    # keys that carry the answer are read: offering every string would let
    # {"status": "NO FINDINGS", "detail": "<a real defect>"} pass as a clean review.
    prose = []
    for line in (body.splitlines() if "\n" in body else [body]):
        line = line.strip()
        document = None
        if line[:1] in ("{", "["):
            try:
                document = json.loads(line)
            except ValueError:
                document = None
        if document is None:
            if line:
                prose.append(line)
            continue
        stack = [document]
        while stack:
            item = stack.pop()
            if isinstance(item, dict):
                for key, value in item.items():
                    if isinstance(value, str) and key in ANSWER_KEYS:
                        yield value
                    else:
                        stack.append(value)
            elif isinstance(item, list):
                stack.extend(item)
    # What is left once the machine events are dropped is the answer the rater actually wrote.
    if prose:
        yield "\n".join(prose)


# "regression tests/coverage" is a test artifact, not a defect declaration; masked before
# token matching so the compound never trips the defect-noun rule, while a bare "regression"
# (introduced, caused, found) still does.
CLEAN_BENIGN_COMPOUND_RE = re.compile(
    r"(?<!\w)regressions? (test(s|ing)?|suites?|coverage|pins?)(?!\w)", re.IGNORECASE
)


def contains_clean_token(text, tokens):
    text = CLEAN_BENIGN_COMPOUND_RE.sub("testing", text)
    return any(
        re.search(rf"(?<!\w){re.escape(token)}(?!\w)", text, re.IGNORECASE)
        for token in tokens
    )


def clean_review_sentences(text):
    # A newline ends a sentence too: "…defects in the implementation\nNo findings" must not
    # merge into one sentence whose negation vouches for the defect half. Fragments without
    # a word character (stray markdown like "**") are not sentences.
    return [
        sentence.strip()
        for sentence in re.split(r"[.!?\n]+", text)
        if re.search(r"\w", sentence)
    ]


def announce_clean_review(text):
    marker = CLEAN_MARKER_TAIL_RE.search(text)
    if not marker:
        return False
    preamble = text[:marker.start()].strip()
    if not preamble:
        return True
    # A defect noun in the preamble is a stated finding ("risks data loss") unless it names
    # what was searched FOR ("reviewing for issues"), which stays a legal announcement. Only
    # the noun itself is exempted, not everything after "for" — a wide scrub hid findings.
    scanned = re.sub(
        rf"\bfor\s+(?:[\w/,'-]+\s+){{0,3}}?(?:{'|'.join(CLEAN_DEFECT_TOKENS)})\b",
        "", preamble, flags=re.IGNORECASE,
    )
    return (
        len(preamble) <= 200
        and len(clean_review_sentences(preamble)) == 1
        and not contains_clean_token(preamble, CLEAN_ANNOUNCE_BLOCKERS)
        and not contains_clean_token(scanned, CLEAN_DEFECT_TOKENS)
        and not CLEAN_DEFECT_LABEL_RE.match(preamble)
        and not CLEAN_TRUNCATION_RE.search(preamble)
        and not any(character.isdigit() for character in preamble)
        and not CLEAN_ANNOUNCE_PATH_RE.search(preamble)
        and not CLEAN_LINE_RE.search(preamble)
    )


def prose_clean_review(text):
    sentences = clean_review_sentences(text)
    if (
        contains_clean_token(text, CLEAN_PROSE_BLOCKERS)
        or CLEAN_TRUNCATION_RE.search(text)
        or CLEAN_PATH_RE.search(text)
        or CLEAN_LINE_RE.search(text)
        or any(
            contains_clean_token(sentence, CLEAN_DEFECT_TOKENS)
            and contains_clean_token(sentence, CLEAN_CLAIM_QUANTIFIERS)
            for sentence in sentences
        )
    ):
        return False
    declared = False
    for sentence in sentences:
        clean = (
            contains_clean_token(sentence, CLEAN_NEGATION_TOKENS)
            and contains_clean_token(sentence, CLEAN_DEFECT_TOKENS)
        )
        declared = declared or clean
        # A praise word does not clear a sentence that names a defect noun without negating
        # it: "handles requests, defects remain" must keep the answer errored.
        if not clean and (
            not contains_clean_token(sentence, CLEAN_PRAISE_TOKENS)
            or contains_clean_token(sentence, CLEAN_DEFECT_TOKENS)
        ):
            return False
    return declared


def clean_review_declared(text):
    # The marker has to be the whole answer: matched anywhere, a rater that writes "found no
    # findings there, but here is a real defect" and then rambles is recorded as a clean run.
    for candidate in clean_marker_candidates(text):
        candidate = candidate.strip().strip("`").strip()
        if CLEAN_REVIEW_RE.fullmatch(candidate.rstrip(".").strip()):
            return True
        try:
            document = json.loads(candidate)
        except ValueError:
            document = None
        if isinstance(document, (dict, list)):
            continue
        if announce_clean_review(candidate) or prose_clean_review(candidate):
            return True
    return False


def unusable_review(text, findings):
    """Why this cell must be rerun rather than recorded, or "" when it is a real result."""
    if findings or clean_review_declared(text):
        return ""
    return ("rater produced no parseable finding and did not declare a clean review: "
            + (" ".join((text or "").split())[:200] or "(empty answer)"))


def review_profile_text(profile):
    override = os.environ.get("REVIEW_BENCH_PROFILE_DIR")
    path = Path(override) / f"{profile}.md" if override else REVIEW_PROFILE_FILES[profile]
    try:
        text = path.read_text()
    except OSError as exc:
        raise RuntimeError(f"review profile {profile!r} unreadable at {path}: {exc}") from exc
    if not text.strip():
        raise RuntimeError(f"review profile {profile!r} is empty at {path}")
    return text


def split_frontmatter(text):
    """The leading `---` block of a registered markdown file and the body after it, or
    (None, text) when the file carries no block at all."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        return None, text
    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            return "".join(lines[1:index]), "".join(lines[index + 1:])
    return None, text


def unquote_scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def parse_frontmatter(block):
    """`key: value`, an inline `[a, b]` list, or a `- item` block under the preceding key."""
    fields = {}
    key = None
    for raw in block.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("- "):
            if key is None:
                raise ValueError(f"list item before any key: {line!r}")
            # `key:` on its own line is the header of a block list, not a key holding "".
            if fields[key] == "":
                fields[key] = []
            if not isinstance(fields[key], list):
                raise ValueError(f"key {key!r} has both a value and list items")
            fields[key].append(unquote_scalar(line[2:]))
            continue
        if ":" not in line:
            raise ValueError(f"line is not `key: value`: {line!r}")
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            fields[key] = [
                unquote_scalar(part) for part in value[1:-1].split(",") if part.strip()
            ]
        else:
            fields[key] = unquote_scalar(value)
    return fields


def lens_dir():
    override = os.environ.get("REVIEW_BENCH_LENS_DIR")
    return Path(override) if override else LENS_DIR


def read_lens(path):
    """One registered lens, or the reason a run must not launch against it."""
    # Hashed as bytes and decoded once: read_text() would translate newlines, and its digest
    # would then disagree with what shasum reports for the same file.
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise RuntimeError(f"lens {path} is unreadable: {exc}") from exc
    try:
        text = data.decode()
    except UnicodeDecodeError as exc:
        raise RuntimeError(f"lens {path} is not valid UTF-8: {exc}") from exc
    block, body = split_frontmatter(text)
    if block is None:
        raise RuntimeError(f"lens {path} has no `---` frontmatter block")
    try:
        fields = parse_frontmatter(block)
    except ValueError as exc:
        raise RuntimeError(f"lens {path} frontmatter: {exc}") from exc
    unknown = sorted(set(fields) - set(LENS_FRONTMATTER_KEYS))
    if unknown:
        raise RuntimeError(
            f"lens {path} has unknown frontmatter key(s): {', '.join(unknown)}; "
            f"known keys are {', '.join(LENS_FRONTMATTER_KEYS)}"
        )
    name = fields.get("name")
    # The slug is the stats identity, so it is the file's to declare and not the filename's:
    # renaming a file must not split one lens's record in two.
    if not isinstance(name, str) or not LENS_SLUG_RE.fullmatch(name):
        raise RuntimeError(
            f"lens {path} needs a frontmatter `name` that is a lowercase slug; got {name!r}"
        )
    aliases = fields.get("aliases", [])
    if isinstance(aliases, str):
        aliases = [aliases] if aliases else []
    for alias in aliases:
        if not LENS_SLUG_RE.fullmatch(alias):
            raise RuntimeError(f"lens {name}: alias {alias!r} is not a lowercase slug")
    # A file naming one slug twice — or naming its own name as an alias — claims nothing against
    # itself; only another file claiming the same slug is the ambiguity load_lenses refuses.
    aliases = [alias for alias in dict.fromkeys(aliases) if alias != name]
    for key in ("when", "source", "source_hash"):
        if not isinstance(fields.get(key, ""), str):
            raise RuntimeError(
                f"lens {name}: {key} must be a single value, got {fields[key]!r}"
            )
    repeats = fields.get("repeats", "")
    if repeats == "" or repeats == []:
        repeats = None
    else:
        try:
            repeats = int(repeats)
        except (TypeError, ValueError):
            raise RuntimeError(
                f"lens {name}: repeats must be an integer, got {fields['repeats']!r}"
            ) from None
        if repeats < 1:
            raise RuntimeError(f"lens {name}: repeats must be at least 1, got {repeats}")
    missing = [
        level for level in LENS_SEVERITIES
        if not re.search(rf"\b{level}\b", body, re.IGNORECASE)
    ]
    if missing:
        raise RuntimeError(
            f"lens {name} at {path} never maps {', '.join(missing)}: a lens body has to say "
            "how its own findings land on P1, P2 and P3"
        )
    return {
        "name": name,
        "path": path,
        "body": body.strip(),
        "hash": hashlib.sha256(data).hexdigest(),
        "repeats": repeats,
        "when": fields.get("when") or "",
        "source": fields.get("source") or "",
        "source_hash": fields.get("source_hash") or "",
        "aliases": list(aliases),
    }


def load_lenses():
    """Every registered lens by canonical slug. A registry with a broken or ambiguous entry
    fails whole: a slug resolving to whichever file sorted first is a run recorded under a
    methodology it did not use."""
    directory = lens_dir()
    lenses = {}
    owners = {}
    for path in sorted(directory.glob("*.md")) if directory.is_dir() else []:
        lens = read_lens(path)
        for slug in (lens["name"], *lens["aliases"]):
            if slug in owners:
                raise RuntimeError(
                    f"lens slug {slug!r} is claimed by both {owners[slug]} and {path}"
                )
            owners[slug] = path
        lenses[lens["name"]] = lens
    return lenses


def resolve_lens(slug):
    lenses = load_lenses()
    if slug in lenses:
        return lenses[slug]
    for lens in lenses.values():
        if slug in lens["aliases"]:
            return lens
    known = ", ".join(sorted(lenses)) or "none registered"
    raise ValueError(f"unknown lens {slug!r}; registered: {known} (in {lens_dir()})")


def lens_source_path(lens):
    if not lens["source"]:
        return None
    path = Path(lens["source"]).expanduser()
    return path if path.is_absolute() else lens["path"].parent / path


def lens_source_digest(path):
    """The source's digest over its bytes — the one shasum would print — or None when the file
    cannot be read. A source is any file, so it is never required to be text at all."""
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def lens_source_status(lens):
    """Whether the skill this lens was distilled from still reads the way it did. Informational
    on every path: a drifted source makes the lens older than its origin, not unusable."""
    path = lens_source_path(lens)
    if path is None:
        return "no source recorded"
    digest = lens_source_digest(path)
    if digest is None:
        return f"source missing at {path}"
    if not lens["source_hash"]:
        return "source hash not recorded"
    return "current" if digest == lens["source_hash"] else f"drifted from {path}"


def lens_plain_cell(rater):
    """The cell as a lens run actually launches it. A -skill cell takes the plain prompt under a
    lens, so carrying the -skill spec would count it apart from its bare twin — two paid runs of
    one cell — and record a skill run that never happened."""
    if not rater["skill"]:
        return rater
    plain = dict(rater)
    plain["skill"] = False
    model_spec, separator, attempt = rater["spec"].partition("#")
    if model_spec.endswith("-skill"):
        model_spec = model_spec[:-len("-skill")]
    plain["spec"] = model_spec + (separator + attempt if separator else "")
    return plain


def lens_panel(raters, lens):
    """The cells a lens run may launch, and the ones it dropped getting there: the sides a lens
    can actually reach, as the plain cells they run as, trimmed to the lens's own repeat count.
    Applied after tier resolution, so a tier stays one composition rather than growing a lens
    variant."""
    dropped = []
    kept = []
    for rater in raters:
        if rater["side"] in LENS_EXCLUDED_SIDES:
            dropped.append((rater["spec"], f"{rater['side']} side is out of a lens's reach"))
        else:
            kept.append(rater)
    plain = []
    specs = set()
    for rater in kept:
        cell = lens_plain_cell(rater)
        # Dropped here rather than left to refuse_retired_cells, which would answer a lens run of
        # this cell by telling the reader to ask for the -skill spec they already asked for.
        if rater["skill"] and _accounts.measured_skill_only(cell):
            dropped.append(
                (rater["spec"], "reviews only through the skill a lens replaces")
            )
            continue
        if cell["spec"] in specs:
            dropped.append(
                (rater["spec"], f"runs as {cell['spec']} under a lens, already on the panel")
            )
            continue
        specs.add(cell["spec"])
        plain.append((cell, rater["spec"]))
    if not lens["repeats"]:
        trimmed = [cell for cell, _ in plain]
    else:
        seen = Counter()
        trimmed = []
        for rater, requested_spec in plain:
            base = _raters.normalize_legacy_rater(rater["spec"])
            seen[base] += 1
            if seen[base] <= lens["repeats"]:
                trimmed.append(rater)
            else:
                dropped.append(
                    (requested_spec, f"over lens {lens['name']} repeats={lens['repeats']}")
                )
    if not trimmed:
        raise RuntimeError(
            f"lens {lens['name']} has no cell to run after applying its panel constraints"
        )
    return trimmed, dropped


def lens_rows(rows, lens=None):
    """Corpus rows measured under one methodology: the tool's own when `lens` is None.

    A lens run answers a different question from the tool's own reviews, so mixing the two
    would let a methodology nobody benchmarked pick the cells of an ordinary panel and decide
    when a repository counts as reviewed.
    """
    return [row for row in rows if row.get("lens") == lens]


def uses_skill_brief(rater):
    """A -skill cell runs the vendor's own review skill, which is the one thing a lens run
    cannot let it do — the lens is the methodology, so the cell takes the plain prompt."""
    return rater["skill"] and not rater.get("lens")


def methodology_adaptation(diff_only):
    """What an injected methodology may not keep: its own output format, and — where the rater
    was handed a diff rather than a repository — everything it says about going and looking."""
    scope = (
        "you have no tools, no subagents, no repository access and no network — only the "
        "commit diff below. Ignore every instruction about delegating to agents, reading "
        "additional files, inspecting git history, running builds, posting review comments, "
        "and ignore its output format."
        if diff_only else
        "ignore every instruction about delegating to agents, about posting review comments, "
        "and ignore its output format."
    )
    return (
        f"Adaptation, which overrides the methodology wherever they conflict: {scope} Apply "
        "its review criteria, its severity guidance and above all its false-positive "
        "exclusions; where it defines a confidence rubric, report only findings you would "
        "score 80 or higher. Map its severities onto P1 (critical/high), P2 (medium) and "
        "P3 (low)."
    )


def review_prompt(sha, focus, profile=None, lens=None):
    suffix = f"\nAdditional focus: {focus}" if focus else ""
    contract = (
        f"Review commit {sha}. Return findings only, one JSON object per line, with exactly "
        "these fields: severity (P1, P2, or P3), file, line, summary. Use changed lines for "
        f"locations. Reply with exactly {CLEAN_REVIEW_MARKER} and nothing else when the commit "
        f"has no findings. {READ_ONLY_REVIEW_INSTRUCTION}"
    )
    # A lens replaces the methodology rather than joining it: two of them in one prompt would
    # be a cell measuring neither.
    if lens:
        return (
            f"The following is the {lens['name']} code-review methodology.\n\n"
            f"{lens['body']}\n\n{methodology_adaptation(True)}\n\n{contract}"
            + suffix
        )
    if not profile:
        return contract + suffix
    return (
        f"The following is the published {profile} code-review methodology.\n\n"
        f"{review_profile_text(profile)}\n\n{methodology_adaptation(True)}\n\n{contract}"
        + suffix
    )


def chunk_instruction(sha, paths):
    """What a cell reading part of a chunked commit is told, for the sides handed a repository
    rather than a diff. One sentence, in the same words the pasted-diff chunks carry. A chunk is
    whole files and never a piece of one, so its paths say the whole of what it holds."""
    if not paths:
        return ""
    listed = " ".join(shlex.quote(path) for path in paths)
    return (
        f" This commit was split into chunks so no reviewer is handed more diff than it reads "
        f"reliably: review ONLY these files of it — {', '.join(paths)} — and report nothing about "
        f"what is missing from them, since the other files are being reviewed in parallel by "
        f"other cells. Read them with `git show {sha} -- {listed}`."
    )


def skill_brief(sha, focus, repo_path, paths=()):
    suffix = f"\nAdditional review focus: {focus}" if focus else ""
    suffix = chunk_instruction(sha, paths) + suffix
    return (
        f"You are a code-review worker. The repository is your current working directory "
        f"({repo_path}). Review commit {sha} the way you normally would: invoke the "
        "/code-review skill and follow its methodology, inspecting the changed code with the "
        f"repository's tools (start from `git show {sha}`). Return findings only, one JSON "
        "object per line, with exactly these fields: severity (P1, P2, or P3), file, line, "
        "summary. Use changed lines for locations. Reply with exactly "
        f"{CLEAN_REVIEW_MARKER} and nothing else when the commit has no findings. "
        f"{READ_ONLY_REVIEW_INSTRUCTION}"
        + suffix
    )


def seal_overlay_clone(repo, sha):
    full = subprocess.run(["git", "-C", str(repo), "rev-parse", f"{sha}^{{commit}}"],
                          capture_output=True, text=True).stdout.strip()
    if not full:
        raise RuntimeError(f"cannot resolve bench commit {sha!r} in {repo}")
    pid = os.getpid()
    ref = f"refs/review-bench/seal-{full[:12]}-{pid}-{threading.get_ident()}"
    # "--claude-worktrees-" makes the AI-usage exporter's stock normalize_project
    # collapse every seal dir into one "review-bench" project; a plain "-seal-"
    # prefix turns each run into a distinct project in the usage reports.
    tmp = tempfile.mkdtemp(prefix="review-bench--claude-worktrees-")
    try:
        subprocess.run(["git", "-C", str(repo), "update-ref", ref, full],
                       capture_output=True, text=True, timeout=30)
        try:
            for command in (
                ["git", "init", "-q", tmp],
                ["git", "-C", tmp, "fetch", "-q", "--depth=2", str(repo), ref],
                ["git", "-C", tmp, "checkout", "-q", "FETCH_HEAD"],
            ):
                proc = subprocess.run(command, capture_output=True, text=True, timeout=120)
                if proc.returncode != 0:
                    raise RuntimeError(
                        f"sealed clone step {command[1:3]} failed: "
                        f"{proc.stderr.strip() or proc.returncode}"
                    )
        finally:
            subprocess.run(["git", "-C", str(repo), "update-ref", "-d", ref],
                           capture_output=True, text=True, timeout=30)
        head = subprocess.run(["git", "-C", tmp, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        if head != full:
            raise RuntimeError(
                f"sealed clone HEAD {head[:7]} does not match bench commit {full[:7]}"
            )
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return tmp


