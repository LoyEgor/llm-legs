import concurrent.futures
import json
import re
import subprocess
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

from . import store as _store
from . import catalog as _catalog
from . import raters as _raters
from . import accounts as _accounts
from . import panel as _panel
from . import prompts as _prompts
from . import launch as _launch

def verifier_model(spec):
    """Every refusal a rater faces applies here too, or the cheapest way to run a refused
    model is to ask for it as the verifier — once per finding rather than once per run.
    """
    rater = _raters.parse_rater(spec)
    _accounts.refuse_retired_cells([rater])
    if rater["side"] != "opencode":
        raise ValueError(f"invalid verifier {spec!r}; the verifier is an in-plan OpenCode model")
    if rater["effort"]:
        raise ValueError(
            f"invalid verifier {spec!r}; the verifier prompt suppresses reasoning, so it "
            "cannot carry an effort"
        )
    # A rater runs once; a verifier runs once per finding, against a much shorter deadline.
    # A model that cannot answer inside it times out on every claim and fails them all open.
    expected = _launch.opencode_expected_s(rater)
    if expected > _launch.VERIFY_TIMEOUT_S:
        raise ValueError(
            f"invalid verifier {spec!r}; a review costs it {expected:.0f}s against the "
            f"{_launch.VERIFY_TIMEOUT_S}s verifier deadline, so every finding would time out"
        )
    return rater["model"]


def verifier_choices():
    usable = []
    for model in sorted(_catalog.OPENCODE_MODEL_IDS):
        try:
            verifier_model(model)
        except (ValueError, RuntimeError):
            continue
        usable.append(model)
    return usable


def auto_pick(number, rows, available, unreachable=None):
    """`unreachable` maps a side to why this run cannot use it at all, keeping such cells out of
    the pool rather than picked and dropped later — a pick spent on one is a cell short of what
    was asked for while eligible cells sat unpicked."""
    if number < 1:
        raise ValueError("--auto must be at least 1")
    counts = _panel.review_counts(rows)
    eligible = []
    skipped = []
    unreachable = unreachable or {}
    for order, spec in enumerate(_catalog.AUTO_RATERS):
        rater = _raters.parse_rater(spec)
        if rater["side"] in unreachable:
            skipped.append((spec, unreachable[rater["side"]]))
        elif _accounts.cell_available(available, rater):
            eligible.append((counts[spec], order, rater))
        else:
            skipped.append((spec, _accounts.unaffordable_reason(rater["side"])))
    eligible.sort(key=lambda item: (item[0], item[1]))
    if len(eligible) < number:
        if unreachable:
            raise RuntimeError(
                f"only {len(eligible)} benchmark cells are within the lens's reach for "
                f"--auto {number}; OpenCode and Antigravity cells are excluded"
            )
        raise RuntimeError(
            f"only {len(eligible)} affordable benchmark cells are available for --auto {number}"
        )
    return [item[2] for item in eligible[:number]], counts, skipped


# geminib enforces the print timeout itself, so the outer deadline is only what its teardown
# costs — the same grace the rater path gives it. A wider one would pin a verify worker long
# past the VERIFY_TIMEOUT_S budget every configured verifier is held to.
GEMINI_VERIFY_TIMEOUT_S = _launch.GEMINI_VERIFY_PRINT_TIMEOUT_S + _catalog.AGY_TIMEOUT_GRACE_S


def repo_tree(repo, sha):
    # The parent's tree too, or a citation of a file the commit deletes resolves against
    # nothing — and that citation is exactly the one file_at_commit reads from the parent.
    # The two stay separate tiers: merged, a commit adding `new/foo.sh` beside the parent's
    # `old/foo.sh` makes a bare `foo.sh` citation ambiguous and it resolves to neither.
    tiers = []
    for ref in (sha, f"{sha}^"):
        proc = subprocess.run(["git", "ls-tree", "-r", "--name-only", ref],
                              cwd=repo, capture_output=True, text=True)
        tiers.append(sorted(set(proc.stdout.splitlines())) if proc.returncode == 0 else [])
    return {"reviewed": tiers[0], "parent": tiers[1]}


def tree_tiers(tree):
    if isinstance(tree, dict):
        return [tier for tier in (tree.get("reviewed"), tree.get("parent")) if tier]
    return [tree]


def _exact_in_tier(path, tree):
    return path if path in tree else None


def _suffix_across_tiers(path, tiers):
    # The longest suffix is the most specific spelling of the same file, so it outranks tier
    # order: asked tier by tier, an absolute citation of the parent's `old/foo.sh` would answer
    # with a bare `foo.sh` the reviewed tree happens to have.
    hits = [(index, name) for index, tier in enumerate(tiers)
            for name in tier if path.endswith("/" + name)]
    if not hits:
        return None
    return max(hits, key=lambda hit: (len(hit[1]), -hit[0]))[1]


def _basename_across_tiers(path, tiers):
    """The loosest rule, so ambiguity is judged across every tier at once.

    Asking one tier at a time would answer a citation the reviewed tree cannot place with a
    same-named file from it anyway, and would call a basename unique that the parent also has.
    """
    tail = path.rsplit("/", 1)[-1]
    hits = [(index, name) for index, tier in enumerate(tiers)
            for name in tier if name.rsplit("/", 1)[-1] == tail]
    if len(hits) == 1:
        return hits[0][1]
    deeper = [hit for hit in hits if hit[1].endswith(path)]
    if len(deeper) == 1:
        return deeper[0][1]
    reviewed = [hit for hit in (deeper or hits) if hit[0] == 0]
    return reviewed[0][1] if len(reviewed) == 1 else None


def resolve_in_tree(path, tree):
    """Exact spellings win everywhere before any guess is made anywhere.

    Ordering the tiers inside each rule instead of the rules inside each tier is what keeps a
    precise citation of a file only the parent has from being rewritten to a same-named file
    the reviewed commit introduces.
    """
    if not path:
        return None
    tiers = tree_tiers(tree)
    for tier in tiers:
        hit = _exact_in_tier(path, tier)
        if hit:
            return hit
    return _suffix_across_tiers(path, tiers) or _basename_across_tiers(path, tiers)


def canonical_finding_path(path, tree):
    """Raters cite files as markdown links, absolute paths or sealed-clone paths.

    Those spellings point at real files but do not match the repository, which
    silently breaks both deduplication and any check that reads the cited file.
    """
    path = (path or "").strip().strip("`").strip()
    candidates = [path]
    match = re.fullmatch(r"\[([^\]]*)\]\(([^)]*)\)", path)
    if match:
        # A link's text is prose as often as it is a path ("[Line 42](src/foo.py)"), so the
        # target is the citation and the text is only what is left when the target is a URL.
        candidates = [
            match.group(2).strip().strip("`").split("#", 1)[0].strip(),
            match.group(1).strip().strip("`").strip(),
        ]
    for candidate in candidates:
        resolved = resolve_in_tree(candidate, tree)
        if resolved:
            return resolved
    return next((candidate for candidate in candidates if candidate), path)


def file_at_commit(repo, sha, path):
    """Return (lines, ref) for a cited file, falling back to the commit's parent.

    A commit that deletes a file is exactly where a finding about that file belongs, and
    reading only the reviewed commit leaves the verifier nothing to judge such a claim on.
    """
    if not path:
        return None, sha
    for ref in (sha, f"{sha}^"):
        proc = subprocess.run(["git", "show", f"{ref}:{path}"], cwd=repo,
                              capture_output=True, text=True)
        if proc.returncode == 0:
            return proc.stdout.splitlines(), ref
    return None, sha


VERIFY_STOCK_TAIL = (
    "Decide from the shown code alone:\n"
    "1. code_matches — does the code actually do what the claim describes? False if the "
    "claim describes behaviour the code does not have, cites the wrong place, or is "
    "contradicted by the code shown.\n"
    "2. is_defect — if the code does behave that way, would a maintainer treat the "
    "consequence as a bug worth fixing? False for style preferences, restatements of "
    "what the change does, and cases the code deliberately handles.\n"
    "If the shown lines are not enough to decide, set the field you cannot decide to "
    "true only when the claim is plausible on the visible evidence.\n\n"
    "Known failure modes of the reviewer — check each:\n"
    "1. Treat documented behavior or code with explicit explanatory comments as intended "
    "design, not a defect.\n"
    "2. Rigorously re-check boolean logic, edge-case conditions, and sort/ordering direction "
    "against what the code actually computes, line by line.\n"
    "3. Trace variable state through short-circuit branches and string filters to confirm "
    "the claimed failure can occur in practice.\n"
    "4. Reject findings resting on speculative or highly unlikely environment states.\n\n"
    "Answer with exactly one JSON object and nothing else:\n"
    '{"code_matches": true|false, "is_defect": true|false, "why": "<max 15 words>"}'
)
# The shapes are the ones the OpenCode raters' adjudicated-false claims actually take, so this
# names what to look for rather than telling the model how strict to be.
VERIFY_SHAPES_TAIL = (
    "Decide from the shown code alone.\n"
    "1. code_matches — does the code do what the claim describes?\n"
    "2. is_defect — would a maintainer fix it?\n\n"
    "Answer false if the claim has any of these shapes, which is what this reviewer "
    "produces when it is wrong:\n"
    "- hedged: 'could', 'may', 'might', 'potentially', 'if the format changes' — a "
    "condition the claim does not show to hold.\n"
    "- contradicted: the shown code assigns, initialises, quotes or guards the very "
    "thing the claim says is missing. Re-read the lines before agreeing.\n"
    "- deliberate: an else-branch, a fallback or a comment shows the case is handled "
    "on purpose.\n"
    "- self-answering: the claim argues both sides and settles nothing, or asks for "
    "verification instead of stating a defect.\n"
    "- narration: it restates what the diff does, or reports a missing test or doc.\n"
    "- direction: it asserts a comparison, sort order or boolean runs the wrong way. "
    "Evaluate the expression yourself before believing it.\n\n"
    "Undecidable on the shown lines means false.\n\n"
    "Answer with exactly one JSON object and nothing else:\n"
    '{"code_matches": true|false, "is_defect": true|false, "why": "<max 15 words>"}'
)
# Both cases argued before the verdict: a model that must write the strongest case FOR the
# claim cannot reject on tone, and one that must write the case AGAINST cannot agree out of
# politeness. The two extra keys precede the verdict on purpose — written after it they would
# be a rationalisation of a decision already made.
VERIFY_DUAL_TAIL = (
    "Before deciding, write both cases from the shown code:\n"
    "- against: the strongest concrete reason this claim is wrong — a line that "
    "contradicts it, a branch it ignores, a condition it never establishes.\n"
    "- for: the strongest concrete reason it is right — the line that would actually "
    "fail, and what breaks.\n"
    "Each must cite the code, not the claim. 'The claim says so' is not a case.\n\n"
    "Then decide which case the code supports:\n"
    "1. code_matches — does the code do what the claim describes?\n"
    "2. is_defect — would a maintainer fix the consequence?\n"
    "If the case for the claim needed a condition the shown code does not establish, "
    "both are false.\n\n"
    "Answer with exactly one JSON object and nothing else:\n"
    '{"against": "<max 20 words>", "for": "<max 20 words>", '
    '"code_matches": true|false, "is_defect": true|false, "why": "<max 12 words>"}'
)
VERIFY_PROMPT_TAILS = {
    "stock": VERIFY_STOCK_TAIL,
    "shapes": VERIFY_SHAPES_TAIL,
    "dual": VERIFY_DUAL_TAIL,
}
# Which wording each verifier is measured best at, scored 2026-08-04 on the hand-adjudicated
# corpus. A model with no entry gets the stock wording it was measured on.
VERIFY_PROMPT_STYLES = {"oc-dsv4flash": "shapes", "oc-kimik3": "dual"}


def verify_prompt_style(model):
    return VERIFY_PROMPT_STYLES.get(model, "stock")


def verify_prompt(finding, sha, path, lines, ref=None, style="stock"):
    ref = ref or sha
    claim = (f"[{finding.get('severity')}] {path}:{finding.get('line')} — "
             f"{finding.get('summary')}")
    if lines is None:
        shown = f"The file {path or '(unnamed)'} does not exist in commit {sha}."
    else:
        try:
            line = int(finding.get("line") or 0)
        except (TypeError, ValueError):
            line = 0
        if len(lines) <= _launch.VERIFY_WHOLE_FILE_LINES:
            low, high = 1, len(lines)
        else:
            # Unclamped, a line past the end of the file yields an empty excerpt, so the
            # most obviously bogus claim is the one the verifier cannot refute.
            line = min(max(line or 1, 1), len(lines))
            low = max(1, line - _launch.VERIFY_WINDOW_LINES)
            high = min(len(lines), line + _launch.VERIFY_WINDOW_LINES)
        body = "\n".join(f"{number}: {lines[number - 1]}" for number in range(low, high + 1))
        origin = (
            f"File {path} in commit {sha}" if ref == sha
            else f"File {path} as it stands in {ref}, the parent of {sha}, which deletes it"
        )
        shown = f"{origin}, lines {low}-{high} of {len(lines)}:\n\n{body}"
    return (
        "You are checking one claim from a code review. Below is the claim and the actual "
        "content of the file it points at, as it is in the reviewed commit.\n\n"
        f"Claim: {claim}\n\n{shown}\n\n"
        + VERIFY_PROMPT_TAILS[style]
    )


def parse_verify_answer(text):
    # A verifier that pretty-prints its verdict is answering correctly, so the object is
    # scanned for rather than matched line by line.
    for value in _store.extract_json_values(text or ""):
        if not isinstance(value, dict):
            continue
        if isinstance(value.get("code_matches"), bool) and isinstance(value.get("is_defect"), bool):
            return value
    return None


def verify_row(index, finding):
    return {
        "idx": index, "file": finding.get("file"), "line": finding.get("line"),
        "severity": finding.get("severity"), "summary": finding.get("summary"),
    }


def unverified_row(index, finding, why):
    row = verify_row(index, finding)
    row.update(kept=True, code_matches=None, is_defect=None, walled=True, why=why)
    return row


def verifier_chain(model, side="opencode"):
    chain = [model] + [name for name in _catalog.OPENCODE_VERIFIER_CHAIN if name != model]
    if side == "agy":
        chain.insert(0, _catalog.GEMINI_VERIFIER)
    return chain


def gemini_verify(prompt_text, slot):
    """One verdict off Gemini's own transport, rotating accounts the way an agy rater does.

    Returns (judgment, asked, walled): a link that never reached an account, one that answered
    unusably, and one whose side spent its quota answering are three different rows in the
    audit, and only this call can tell them apart.

    A walled account is retired and the pool asked again rather than the link giving up: the
    quota is per model, which is the bucket the agy cells on this model already share.
    """
    excluded = set()
    asked = False
    walled = False
    with tempfile.TemporaryDirectory(prefix="review-bench-gemini-verify-") as workdir:
        log_file = Path(workdir) / "verify.log"
        while True:
            account = _accounts.pool_account("agy", excluded, slot, _catalog.GEMINI_VERIFIER)
            if account is None or account in excluded:
                return None, asked, walled
            if _accounts.is_walled("agy", account, _catalog.GEMINI_VERIFIER):
                excluded.add(account)
                continue
            log_file.unlink(missing_ok=True)
            command = [
                _store.command_path("REVIEW_BENCH_GEMINIB_BIN", "geminib"), "profile", account,
                "--model", _launch.agy_model_id(_catalog.GEMINI_VERIFIER_RATER),
                "--mode", "plan", "--new-project", "--dangerously-skip-permissions",
                "--print-timeout", _launch.GEMINI_VERIFY_PRINT_TIMEOUT,
                "--log-file", str(log_file), "--print", prompt_text,
            ]
            try:
                proc = subprocess.run(
                    command, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                    timeout=GEMINI_VERIFY_TIMEOUT_S, cwd=workdir,
                )
            except subprocess.TimeoutExpired:
                # The account was reached and spent the deadline, unlike a transport that
                # never started: one is a verifier that answered badly, the other is none.
                return None, True, walled
            except OSError:
                return None, asked, walled
            asked = True
            log_text = log_file.read_text(errors="replace") if log_file.exists() else ""
            # Fail closed on a substitution exactly as the rater path does: a keep/drop rate
            # measured on this model says nothing about whichever one agy served instead.
            if _launch.agy_model_mismatch(_launch.agy_served_labels(log_text), _catalog.GEMINI_VERIFIER_RATER):
                return None, asked, walled
            # Only a run that finished speaks for the model, exactly as the rater path and the
            # OpenCode link read their answer: geminib prints what it had when its own
            # deadline cut it off, and that text is not a verdict this rate was measured on.
            judgment = parse_verify_answer(proc.stdout) if proc.returncode == 0 else None
            if judgment is not None:
                return judgment, asked, walled
            # The gateway's own words decide this, never the verifier's answer: a claim about
            # 429 handling is exactly what this link is asked to judge, and a wall read off
            # that prose retires an account the agy raters share out from under them.
            # Antigravity states a per-model exhaustion only in its log, which is where the
            # detail the classifier reads comes from.
            detail = _launch.agy_failure_detail(proc.stderr or "", log_text)
            if not _accounts.SIDE_WALL["agy"](proc.returncode, "", detail):
                return None, asked, walled
            _accounts.mark_walled("agy", account, _catalog.GEMINI_VERIFIER, _accounts.wall_reset_at(proc.stderr))
            excluded.add(account)
            walled = True


def verify_one(index, finding, repo, sha, model, lines, ref=None, side="opencode"):
    prompt_file = tempfile.NamedTemporaryFile(
        mode="w", prefix="review-bench-verify-", suffix=".txt", delete=False
    )
    prompt_file.close()
    account, proc, judgment, walled, timeout_stderr = None, None, None, False, ""
    answered_by = model
    chain = verifier_chain(model, side)
    asked = False
    gemini_walled = False
    holds_gate = False

    def take_gate():
        """Hold a gateway slot only while this finding is actually on the gateway.

        The gate rations OpenCode concurrency, and its queue is ordered by expected runtime, so
        a verifier entering it at priority zero waits behind rater cells holding slots for their
        full timeouts. A side whose chain leads on its own transport must not pay that wait to
        make a call the gateway is not part of — which is the whole point of the agy side
        leading with Gemini.
        """
        nonlocal holds_gate
        if not holds_gate:
            _launch.OPENCODE_GATE.acquire(0)
            holds_gate = True

    def drop_gate():
        """Whatever wall this thread found goes on record before the slot changes hands.

        The contract belongs to the release, not to the caller: a link that hands the gate to
        the thread queued behind it must not leave that thread a wall to rediscover. Today the
        only release before the loop's end is Gemini's, which leads the agy chain and so has no
        OpenCode call behind it to have walled anything — the point is that reordering the chain
        cannot quietly take the guarantee away.
        """
        nonlocal holds_gate
        if holds_gate:
            record_opencode_wall()
            holds_gate = False
            _launch.OPENCODE_GATE.release()

    if chain[0] != _catalog.GEMINI_VERIFIER:
        take_gate()

    def record_opencode_wall():
        """The wall this thread found, on record before it lets go of the gate.

        A verifier queued on the slot would otherwise acquire it in between, pass the post-gate
        check and send one more doomed request. A named burst throttle is not this account's
        window: the verifier gives up on the finding rather than retiring an account that still
        has quota.
        """
        nonlocal walled
        if walled:
            return
        wall_stderr = "\n".join(filter(None, [
            proc.stderr if proc is not None and proc.returncode != 0 else "",
            timeout_stderr,
        ]))
        walled = bool(
            _accounts.opencode_usage_wall(wall_stderr) and not _accounts.opencode_burst_throttle(wall_stderr)
        )
        if walled and account is not None:
            _accounts.mark_walled("opencode", account, reset_at=_accounts.wall_reset_at(wall_stderr),
                        window=_accounts.opencode_wall_window(wall_stderr))

    try:
        account = _accounts.pool_account("opencode", set(), index)
        skip_opencode = account is None or _accounts.is_walled("opencode", account)
        if skip_opencode and _catalog.GEMINI_VERIFIER not in chain:
            return unverified_row(
                index, finding, "verifier walled off while queued; finding kept unverified"
            )
        for candidate in chain:
            answered_by = candidate
            prompt_text = verify_prompt(
                finding, sha, finding.get("file"), lines, ref,
                style=verify_prompt_style(candidate),
            )
            if candidate == _catalog.GEMINI_VERIFIER:
                # Gemini answers on its own transport, so holding a slot of the gateway this
                # link exists to outlive would stall the OpenCode cells queued behind it for
                # as long as the rotation takes.
                drop_gate()
                judgment, gemini_asked, gemini_walled = gemini_verify(prompt_text, index)
                asked = asked or gemini_asked
                if judgment is not None:
                    break
                # The slot was never this thread's, or was another thread's for the length of
                # that rotation, and either way the account may have retired meanwhile.
                skip_opencode = skip_opencode or _accounts.is_walled("opencode", account)
                continue
            if skip_opencode:
                continue
            take_gate()
            # Asked again on the far side of the wait, because the wait is where the answer
            # changes: the gate's queue is ordered by expected runtime, so a verifier entering
            # it at priority zero sits behind rater cells holding slots for their full timeouts,
            # and a wall another thread recorded meanwhile is exactly what the pre-gate check
            # could not have seen. Without this every queued claim spends one more doomed
            # request on a retired account and deepens the wall by the queue's depth — the same
            # race run_opencode closes for the rater cells.
            if _accounts.is_walled("opencode", account):
                skip_opencode = True
                continue
            Path(prompt_file.name).write_text(prompt_text)
            command = [
                _store.command_path("REVIEW_BENCH_OPENCODE_BIN", "opencode-go"),
                "run", _catalog.OPENCODE_MODEL_IDS[candidate], "--prompt-file", prompt_file.name,
                "--json", "--max-tokens", str(_launch.VERIFY_MAX_TOKENS), "--no-reasoning",
                "--answer-must-match", _prompts.OPENCODE_VERDICT_SHAPE,
                "--retries", "2",
            ]
            asked = True
            try:
                proc = subprocess.run(
                    command, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                    timeout=_launch.VERIFY_TIMEOUT_S, env=_launch.opencode_env(account)
                )
            except subprocess.TimeoutExpired as exc:
                # Every remaining link shares the gateway that just hung, so a claim reaching
                # here carries on nowhere: on the agy side its own transport already led and
                # declined, and on the OpenCode side there was never a second one. The loop
                # continues to reach the fail-open row, not to reach another verifier.
                proc, judgment = None, None
                timeout_stderr = _store.subprocess_text(exc.stderr)
                skip_opencode = True
                continue
            answer = ""
            if proc.returncode == 0:
                try:
                    envelope = json.loads(proc.stdout)
                    answer = envelope["choices"][0]["message"]["content"] or ""
                except (KeyError, IndexError, TypeError, ValueError, json.JSONDecodeError):
                    answer = ""
            judgment = parse_verify_answer(answer)
            if judgment is not None:
                break
            # Only a refusal aimed at the model is worth asking a different one. A walled
            # account is walled for everything on it, while a throttle and a dead provider
            # belong to the model upstream: measured 2026-07-31, kimi-k3 was refused on a
            # brand-new account while grok-4.5 answered on that same one, and on 2026-08-04
            # grok-4.5's provider was down for a whole run whose 85 claims all filed
            # unverified without the chain ever being asked. Anything else — a bad answer, a
            # broken envelope — repeats on the next model and would only triple the requests.
            # The outage reading needs the exit code too: a call that answered after its own
            # 5xx retries leaves those status lines on stderr, and a bad answer from a model
            # that did reply is not an outage.
            candidate_stderr = proc.stderr or ""
            if not (_accounts.opencode_burst_throttle(candidate_stderr)
                    or (proc.returncode != 0
                        and _accounts.opencode_provider_unavailable(candidate_stderr))):
                # Done with this gateway, not with the claim: a spent account or a refused
                # model says nothing about a transport sharing neither of them, so the links
                # behind it are skipped rather than the loop left.
                skip_opencode = True
    finally:
        record_opencode_wall()
        drop_gate()
        Path(prompt_file.name).unlink(missing_ok=True)
    row = verify_row(index, finding)
    if judgment is None:
        # The wall is recorded either way, but it only decides the row where nothing answered:
        # a link on another transport that did answer has already judged this claim.
        if walled or gemini_walled:
            return unverified_row(
                index, finding, "verifier hit the plan's usage wall; finding kept unverified"
            )
        if not asked:
            return unverified_row(
                index, finding, "verifier walled off while queued; finding kept unverified"
            )
        row.update(kept=True, code_matches=None, is_defect=None,
                   why="verifier gave no usable answer; finding kept")
        return row
    why = str(judgment.get("why") or "")[:200]
    # Against the head of THIS side's chain, not against the configured OpenCode model: on the
    # agy side Gemini leads by construction, so `!= model` would mark every one of its verdicts
    # as a fallback and spend 24 of the 200 characters saying what the side always does.
    if answered_by != chain[0]:
        why = f"[verified by {answered_by}] {why}"[:200]
    row.update(
        kept=bool(judgment["code_matches"] and judgment["is_defect"]),
        code_matches=judgment["code_matches"], is_defect=judgment["is_defect"],
        why=why, verifier=answered_by,
    )
    return row


def verifier_tally(audit, configured):
    """Which model answered, counted per finding. The chain advances on a burst throttle, so
    one cell's claims can be judged by two models, and a row that fails open was judged by
    nobody — crediting the configured model for either would name a model that never ran.
    """
    return dict(Counter(
        row.get("verifier") or configured
        for row in audit if row.get("code_matches") is not None
    ))


VERDICT_FIELDS = ("kept", "code_matches", "is_defect", "why", "verifier", "walled")


def claim_fingerprint(summary):
    return " ".join(re.findall(r"[a-z0-9]+", str(summary or "").lower()))


def verify_place(index, finding):
    """The group that shares one verifier call: one claim about one place, restated.

    The verdict is rendered on a single claim's text, so the wording has to be part of the key.
    Two different claims about one line settled by one call would decide the one the verifier
    never saw, and a run's real defect co-located with a false claim would go with it. An
    uncited claim is nobody's neighbour either: with no file or no line there is no place to
    share, and the index keeps each of those on its own.
    """
    path, line = finding.get("file"), finding.get("line")
    if not path or line is None:
        return ("", index)
    return (str(path), str(line), claim_fingerprint(finding.get("summary")))


def verify_findings(findings, repo, sha, model, tree, side="opencode"):
    """Return (kept findings, audit rows) after checking each claim against its file.

    One claim filed twice at one place — the same words under a different severity, or the same
    sentence repunctuated — is one question asked once, and every original claim still gets its
    own audit row carrying the shared verdict.
    """
    cache = {}
    for finding in findings:
        path = finding.get("file")
        if path not in cache:
            cache[path] = file_at_commit(repo, sha, path)
    places = defaultdict(list)
    for index, finding in enumerate(findings):
        places[verify_place(index, finding)].append(index)
    groups = list(places.values())
    verdicts = {}
    workers = min(_launch.OPENCODE_MAX_CONCURRENCY, max(1, len(groups)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {}
        for members in groups:
            index = members[0]
            finding = findings[index]
            lines, ref = cache[finding.get("file")]
            futures[pool.submit(
                verify_one, index, finding, repo, sha, model, lines, ref, side
            )] = index
        for future in concurrent.futures.as_completed(futures):
            index = futures[future]
            try:
                verdicts[index] = future.result()
            except Exception as exc:
                # The raters already spent their quota: a crashed verifier costs the run its
                # filtering, never the findings file it has not written yet.
                row = verify_row(index, findings[index])
                row.update(kept=True, code_matches=None, is_defect=None,
                           why=f"verifier crashed: {exc}"[:200])
                verdicts[index] = row
    audit = []
    for members in groups:
        verdict = verdicts[members[0]]
        shared = {
            field: verdict[field] for field in VERDICT_FIELDS if field in verdict
        }
        for index in members:
            row = verify_row(index, findings[index])
            row.update(shared)
            audit.append(row)
    audit.sort(key=lambda row: row["idx"])
    kept = [findings[row["idx"]] for row in audit if row["kept"]]
    return kept, audit


