"""fix-audit (docs/directions/doctors.md, goal fix-audit): every landed fix of a fit, legacy or speed round is read
again, blind, a week later.

- collect: each finding a round's fixer settled `fixed` maps to the commits on main that name its round and position
  (`<round> F<n>`, the rule worker-run hands every round fixer; a commit naming the round alone, or a doctor fixer's
  merged branch, maps to all of its fixed findings), with lens, finder cell, judge, fixer model and fixer cost.
- read (the night's prep, since a headless worker launches no worker): nightly it keeps who fixed what from the
  run records in FIXERS; weekly by itself, up to PER_KIND unread fixes
  >= DUE_DAYS old per lens x finder model become blind packets (no model, round or fixer named) under
  FIX_AUDIT_DIR/<date>, their key beside them; one reader per READER_ITEMS, outside the judge's family when
  `worker-pick --list --role reviewers` has such a vendor on, else Opus, each in its own workdir (worker-run runs
  one worker per workdir); a batch already read is never relaunched, so a rerun reads only the missing ones.
- apply (the night's fix-audit job, in its worktree): collect, then the pending reads' verdicts, into
  share/fix-ledger.json; a batch counts once its verdicts cover every item, a read once all its batches do.
- A false or harmful fix, or a useless one that added code, is a Harness row (rule fix_audit) until a commit naming
  `revert <round> F<n>` lands on main.
"""

import collections
import datetime
import difflib
import glob
import json
import os
import random
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fix_commit import siblings_dir  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")
# Beside the Harness ledger, whose rows it raises: a fixture HARNESS_LEDGER takes it along.
LEDGER = os.path.join(os.path.dirname(os.environ.get("HARNESS_LEDGER") or "") or os.path.join(ROOT, "share"),
                      "fix-ledger.json")
AUDIT_DIR = os.environ.get("FIX_AUDIT_DIR") or os.path.join(HOME, ".cache", "fix-audit")
BENCHES = os.path.join(os.environ.get("WORKER_STATS_DIR") or os.path.join(
    os.environ.get("CLAUDEB_DIR") or os.path.join(HOME, ".claude-profiles", ".claudeb"), "worker-stats"), "benches")
RUNS = os.environ.get("WORKER_RUN_DIR") or os.path.join(HOME, ".cache", "claude-worker-runs")
DOCTOR_RUNS = os.path.join(os.environ.get("DOCTORS_DIR") or os.path.join(HOME, ".cache", "doctors"), "runs")
# Who fixed what, kept from the run records (pruned after about 9 days) by the nightly read.
FIXERS = os.path.join(AUDIT_DIR, "fixers.json")
SWEEP = os.environ.get("NIGHT_RUN_SWEEP_REPOS") or os.path.join(HOME, ".claude", "sweep-repos")
# Run records before 10-19 are pruned (no fixer model); the retro audit of 10-28 seeded the ledger with its 40.
SINCE = "20261019T000000Z"
DUE_DAYS = 7
PER_KIND = 20
READER_ITEMS = 20
CONTEXT = 12
NEAR = 20
LENS = re.compile(r"^(fit|legacy(-.*)?|speed)$")
RID = re.compile(r"\d{8}T\d{6}Z-[0-9a-f]{7}")
NAMED = re.compile(r"\s*\)?[,;]?\s*\(?\s*(?:findings?|F)\s*((?:\d+(?:\s*-\s*\d+)?(?:\s*(?:,|and|&)\s*F?)?)+)")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
BLIND = re.compile(r"haiku|sonnet|opus|fable|(?:grok\d*|gpt[\w.]*|gemini[\w.]*)-(?:low|medium|high|xhigh)|"
                   + RID.pattern, re.I)
VERDICTS = ("needed", "useless", "not-fixed", "false", "harmful")
FAMILY = {"claudeb": "claude", "codex": "gpt", "gemini": "gemini", "grok": "grok"}


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch(stamp):
    return datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()


def read_json(path, default):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = "%s.tmp.%d" % (path, os.getpid())
    with open(temporary, "w") as handle:
        json.dump(value, handle, indent=1, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


def jsonl(path):
    out = []
    try:
        with open(path, errors="replace") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
                    out.append(row)
    except OSError:
        pass
    return out


def git(repo, *args):
    done = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, errors="replace")
    return done.stdout if done.returncode == 0 else None


def repos_dir():
    return os.environ.get("FIX_AUDIT_REPOS") or siblings_dir(ROOT)


def sweep_names():
    try:
        with open(SWEEP) as handle:
            return [os.path.basename(line.strip().rstrip("/")) for line in handle if line.strip()]
    except OSError:
        return []


def load():
    ledger = read_json(LEDGER, {})
    return ledger if isinstance(ledger, dict) and isinstance(ledger.get("rows"), list) else {"rows": []}


def family(model):
    """The vendor family of a model or cell label: opus-high, sonnet or a full claude-* id -> claude."""
    name = str(model or "").lower()
    if re.match(r"(claude-)?(opus|sonnet|haiku|fable)", name):
        return "claude"
    return next((fam for fam in ("gpt", "gemini", "grok") if name.startswith(fam) or fam == "gpt" and "codex" in name),
                name.split("-")[0] or "?")


def finder(cell):
    return str(cell or "?").split("#")[0].split("-")[0]


def to_revert(ledger):
    """Rows a Harness fixer reverts: false or harmful, or useless with code added; none once a revert landed."""
    return [row for row in ledger.get("rows") or () if isinstance(row, dict) and not row.get("reverted")
            and (row.get("verdict") in ("false", "harmful")
                 or row.get("verdict") == "useless" and (row.get("net_lines") or 0) > 0)]


def ledger_row(ident, ledger=None):
    return next((row for row in (ledger or load()).get("rows") or () if row.get("id") == ident), None)


def revert_what(row):
    return ("Fix-audit read this landed fix %s (%s): revert its hunks in %s of %s@%s, keeping what the commit did for "
            "other findings; the commit message names `revert %s F%s`" % (
                row.get("verdict"), row.get("reason") or "no reason", row.get("file"), row.get("repo"),
                ",".join(c[:8] for c in row.get("commits") or ()), row.get("round"), row.get("finding")))


def round_commits(repo, since):
    """{round: [(hash, epoch, positions or None, body)]} of the commits on main naming a round since `since`."""
    out = collections.defaultdict(list)
    log = git(repo, "log", "main", "--since=%s" % since, "--format=%x01%H %ct%n%B") or ""
    for block in log.split("\x01")[1:]:
        head, _, body = block.partition("\n")
        commit, stamp = head.split()
        seen = {}
        for found in RID.finditer(body):
            named = NAMED.match(body[found.end():found.end() + 80])
            nums = seen.get(found.group(0))
            if named:
                nums = nums or set()
                for low, high in re.findall(r"(\d+)(?:\s*-\s*(\d+))?", named.group(1)):
                    nums.update(range(int(low), int(high) + 1) if high else [int(low)])
            seen[found.group(0)] = nums
        for rnd, nums in seen.items():
            out[rnd].append((commit, int(stamp), nums, body))
    return out


def merged_commits(repo, branch, since):
    """[(hash, epoch, None, body)] a merge on main brought in from `branch` (a doctor fixer's, named by no message)."""
    log = git(repo, "log", "main", "--merges", "--first-parent", "--since=%s" % since, "--format=%H%x09%s") or ""
    for line in log.splitlines():
        merge, _, subject = line.partition("\t")
        if branch and "'%s'" % branch in subject:
            out = git(repo, "log", "--no-merges", "--format=%x01%H %ct%n%B", "%s^1..%s^2" % (merge, merge)) or ""
            return [(head.split()[0], int(head.split()[1]), None, body)
                    for head, _, body in (block.partition("\n") for block in out.split("\x01")[1:])]
    return []


def run_index():
    """{round: [(run, meta)]} of the worker-run runs bound to a round, read while their records last."""
    out = collections.defaultdict(list)
    for path in glob.glob(os.path.join(RUNS, "*", "meta.json")):
        try:
            with open(path) as handle:
                text = handle.read()
        except OSError:
            continue
        if '"review_round"' not in text:
            continue
        try:
            meta = json.loads(text)
        except ValueError:
            continue
        if isinstance(meta, dict) and meta.get("review_round"):
            out[meta["review_round"]].append((os.path.basename(os.path.dirname(path)), meta))
    return out


def doctor_index():
    out = {}
    for path in glob.glob(os.path.join(DOCTOR_RUNS, "*.json")):
        record = read_json(path, None)
        if isinstance(record, dict) and record.get("lens_round"):
            out[record["lens_round"]] = record
    return out


def run_cost(run, vendor):
    """The run's spend in Opus-eq (night_spend's pricing), None where its transcript or token-map is gone."""
    try:
        import night_spend
        usage = night_spend.run_usage(worker_bin("worker-run"), run, vendor, set())
        return round(sum(usage.values()), 1) if usage is not None else None
    except (SystemExit, Exception):
        return None


def fixer_of(rnd, finding, runs, doctors, costs):
    for run, meta in runs.get(rnd, ()):
        fixed = [r.get("finding") for r in jsonl(os.path.join(RUNS, run, "verdicts.jsonl"))
                 if r.get("kind") == "fixer" and r.get("outcome") == "fixed"]
        if finding in fixed:
            if run not in costs:
                costs[run] = run_cost(run, meta.get("vendor") or "claudeb")
            cost = costs[run] / len(set(fixed)) if costs[run] is not None else None
            return meta.get("model") or meta.get("vendor") or "unknown", run, cost
    record = doctors.get(rnd)
    if record:
        return (record.get("trial") or {}).get("arm") or record.get("model") or "opus", record.get("id"), None
    return "unknown", None, None


def judge_rows(rows):
    """The judge rows `finding` indexes (review-anchors bench_rows' order)."""
    return [r for r in rows if r.get("rater") and r.get("verdict") and r.get("kind") != "fixer"]


def finding_of(bench, row, cache):
    rater, idx = row.get("rater"), row.get("idx")
    if rater not in cache:
        cache[rater] = jsonl(os.path.join(bench, "findings-%s.jsonl" % rater))
    found = cache[rater][idx] if isinstance(idx, int) and 0 <= idx < len(cache[rater]) else {}
    location = row.get("location") if isinstance(row.get("location"), dict) else {}
    return dict(found, file=location.get("file") or found.get("file"), line=location.get("line") or found.get("line"))


def repo_of(meta, found, names):
    if found.get("repo") in names:
        return found["repo"]
    for where in (meta.get("workdir"), meta.get("repo")):
        hit = re.search(r"/Projects/([^/]+)", str(where or ""))
        if hit and hit.group(1) in names:
            return hit.group(1)
    first = str(found.get("file") or "").split("/")[0]
    if first in names:
        return first
    return os.path.basename(str(meta.get("repo") or "").rstrip("/")) if os.path.basename(
        str(meta.get("repo") or "").rstrip("/")) in names else None


def collect(write=True, since=SINCE):
    """The ledger with every newly fixed finding of a fit, legacy or speed round added and landed reverts marked,
    saved when `write`; returns (ledger, added, unmapped)."""
    ledger = load()
    known = {row.get("id") for row in ledger["rows"]}
    names = sweep_names()
    day = "%s-%s-%s" % (since[:4], since[4:6], since[6:8])
    commits = {name: round_commits(os.path.join(repos_dir(), name), day) for name in names
               if os.path.isdir(os.path.join(repos_dir(), name))}
    runs, doctors, costs = run_index(), doctor_index(), {}
    fixers = read_json(FIXERS, {})
    seen_fixers = dict(fixers)
    added, unmapped = [], collections.Counter()
    for bench in sorted(glob.glob(os.path.join(BENCHES, "2*"))):
        rnd = os.path.basename(bench)
        if rnd < since:
            continue
        meta = read_json(os.path.join(bench, "meta.json"), {})
        lens = str(meta.get("lens") or "")
        if not LENS.match(lens):
            continue
        rows = jsonl(os.path.join(bench, "verdicts.jsonl"))
        judged = judge_rows(rows)
        fixed = sorted({r["finding"] for r in rows if r.get("kind") == "fixer" and r.get("outcome") == "fixed"
                        and isinstance(r.get("finding"), int) and r["finding"] < len(judged)})
        cache = {}
        for pos in fixed:
            ident = "%s/F%d" % (rnd, pos)
            if ident in known:
                continue
            found = finding_of(bench, judged[pos], cache)
            repo = repo_of(meta, found, names)
            candidates = commits.get(repo, {}).get(rnd, [])
            if not candidates and repo in commits and (doctors.get(rnd) or {}).get("branch"):
                candidates = commits[repo][rnd] = merged_commits(
                    os.path.join(repos_dir(), repo), doctors[rnd]["branch"], day)
            named = [c for c in candidates if c[2] and pos in c[2]]
            loose = [c for c in candidates if not c[2] or not set(c[2]) & set(fixed)]
            use = named or loose
            if not use:
                unmapped["no commit on main names %s" % ("its round" if not candidates else "this finding")] += 1
                continue
            cited = str(found.get("file") or "")
            path = cited[len(repo) + 1:] if cited.startswith(repo + "/") else cited
            reviewed = meta.get("reviewed") if isinstance(meta.get("reviewed"), dict) else {}
            model, run, cost = fixers.get(ident) or fixer_of(rnd, pos, runs, doctors, costs)
            if model != "unknown":
                fixers[ident] = [model, run, cost]
            row = {"id": ident, "round": rnd, "finding": pos, "lens": "legacy" if lens.startswith("legacy") else lens,
                   "cell": str(judged[pos].get("rater")).split("#")[0], "judge": (meta.get("judge") or {}).get("model"),
                   "fixer": model, "fixer_run": run, "cost": cost, "repo": repo, "file": path,
                   "line": found.get("line") if isinstance(found.get("line"), int) else None,
                   "reviewed": reviewed.get(cited) or reviewed.get("%s/%s" % (repo, path)) or reviewed.get(path),
                   "claim": found.get("summary"), "mapping": "named" if named else "round",
                   "commits": [c[0] for c in sorted(use, key=lambda c: c[1])],
                   "at": iso(min(c[1] for c in use)), "verdict": None}
            ledger["rows"].append(row)
            known.add(ident)
            added.append(row)
    for row in to_revert(ledger):
        for commit, stamp, _, body in commits.get(row.get("repo"), {}).get(row.get("round"), []):
            if stamp >= epoch(row["at"]) and commit not in row["commits"] and re.search(
                    r"revert[^\n]*%s F%s\b" % (re.escape(row["round"]), row["finding"]), body, re.I):
                row["reverted"] = commit
    ledger["rows"].sort(key=lambda row: row["id"])
    if fixers != seen_fixers:
        write_json(FIXERS, fixers)
    if write:
        write_json(LEDGER, ledger)
    return ledger, added, unmapped


def parse_diff(text):
    hunks, current = [], None
    for line in (text or "").splitlines():
        head = HUNK.match(line)
        if head:
            current = {"os": int(head.group(1)), "on": int(head.group(2) if head.group(2) is not None else 1),
                       "lines": [line]}
            hunks.append(current)
        elif line.startswith("diff --git"):
            current = None
        elif current is not None:
            current["lines"].append(line)
    return hunks


def mapped_line(repo, reviewed, commit, path, line):
    """The finding's reviewed line in the pre-fix file, the code having moved between review and fix."""
    old = (git(repo, "cat-file", "-p", reviewed) or "").splitlines() if reviewed else None
    new = (git(repo, "show", "%s^:%s" % (commit, path)) or "").splitlines()
    if not old or not new or not line:
        return line
    for tag, i1, i2, j1, _ in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        if i1 <= line - 1 < i2:
            return j1 + (line - 1 - i1) + 1 if tag == "equal" else j1 + 1
    return line


def packet(row, number):
    """(text, net added lines) of a blind packet, None where no hunk of its commits touches the finding's file."""
    repo = os.path.join(repos_dir(), row["repo"])
    body, net, shown = [], 0, []
    for commit in row["commits"]:
        hunks = parse_diff(git(repo, "show", "--format=", "--no-color", "-U%d" % CONTEXT, commit, "--", row["file"]))
        if not hunks:
            continue
        line = mapped_line(repo, row.get("reviewed"), commit, row["file"], row.get("line"))
        near = [h for h in hunks if line and h["os"] - NEAR - CONTEXT <= line <= h["os"] + max(h["on"], 1) + NEAR]
        body += ["Commit %s: its hunks in `%s`%s." % (commit[:12], row["file"], " near the finding's line" if near else ""),
                 "", "```diff", "--- a/%s" % row["file"], "+++ b/%s" % row["file"]]
        for hunk in near or hunks:
            body += hunk["lines"]
            net += sum(1 for l in hunk["lines"][1:] if l.startswith("+")) - sum(
                1 for l in hunk["lines"][1:] if l.startswith("-"))
        body += ["```", ""]
        shown.append(commit)
    head = ["# Item %02d" % number, "", "- Lens: %s" % row["lens"], "- Repo: %s" % row["repo"],
            "- Commit: %s" % ", ".join(shown), "", "## Finding", "",
            "Reviewed file: `%s`%s" % (row["file"], ", line %d" % row["line"] if row.get("line") else ""), "",
            "> " + str(row.get("claim") or "").replace("\n", "\n> "), "", "## Fix hunks", ""]
    return ("\n".join(head + body) + "\n", net) if shown else None


def brief(items, items_dir, out):
    projects = repos_dir()
    return """ROUND: none
EFFORT: high

You audit landed fixes after the fact. A night review raised a finding, a judge confirmed it, a fixer changed the code, and the change landed on main. Decide for each item whether that fix was real.

## Your items

Your items are %s/NN.md for NN in %s. Each packet gives:
- the lens: `fit` means duplication or misplaced code, `legacy` means dead or obsolete code, `speed` means wasted time;
- the repo, as a directory of %s;
- the commit;
- the finding's claim;
- the fix hunks.

Check the claim against the code itself:
- `git -C <repo> show <commit>^:<path>` for the code before the fix;
- `git -C <repo> show --format= <commit>` for the change;
- `git -C <repo> log --format='%%h %%ad' --date=short -L<range>:<path> <commit>..main` for what happened to those lines later.

Do not read commit messages. Do not look for or open any other file under %s: who raised or fixed an item is withheld on purpose.

## One verdict per item

- `needed`: the problem existed in the pre-fix code, and the change removes it at a gain that matters.
  - Speed: the path runs often, or it blocks a chat or the night.
  - Fit and legacy: the code shrinks or one owner replaces copies, and behavior is kept.
- `useless`: the claim is technically true, but the change gains nothing that matters. Examples:
  - a saving on a rarely run path, or one far below a second a day;
  - code rearranged without shrinking;
  - a "cleanup" that adds code.
  This is work done for its own sake.
- `not-fixed`: the problem is real, but the change does not remove it.
- `false`: the claimed problem did not exist in the pre-fix code.
- `harmful`: the change broke or lost behavior, or made something worse. Count a later commit that restored what the fix removed.

## Output

Write %s, tab-separated, with a header and these columns:
- `item`;
- `verdict`;
- `confidence`: high, medium or low;
- `reason`: one line;
- `evidence`: file:line in the pre-fix code, or a later commit's short hash.

Judge each item on its own evidence. Expect any mix of verdicts; there is no quota.

## Rules

- You only read repos. Write nothing but the verdicts file.
- Never launch a worker, review or night.

## Report

80 words or fewer:
- verdict counts;
- the items you marked low confidence;
- the output path.
""" % (items_dir, " ".join(items), projects, AUDIT_DIR, out)


def sample(ledger, now=None):
    """Writes the blind packets and the key of the fixes due; returns the key directory, None with none due."""
    now = now or time.time()
    day = datetime.date.fromtimestamp(now).isoformat()
    due = collections.defaultdict(list)
    for row in ledger["rows"]:
        if row.get("verdict") is None and epoch(row["at"]) <= now - DUE_DAYS * 86400:
            due[(row["lens"], finder(row["cell"]))].append(row)
    rng = random.Random(day)
    picked = []
    for kind in sorted(due):
        rows = sorted(due[kind], key=lambda row: row["id"])
        rng.shuffle(rows)
        took = 0
        for row in rows:
            made = packet(row, 0)
            if made and not BLIND.search(made[0]):
                picked.append(row)
                took += 1
                if took == PER_KIND:
                    break
    if not picked:
        return None
    rng.shuffle(picked)
    folder, key_dir = os.path.join(AUDIT_DIR, day), os.path.join(AUDIT_DIR, day + "-key")
    items_dir = os.path.join(folder, "packets", "items")
    os.makedirs(items_dir, exist_ok=True)
    os.makedirs(key_dir, exist_ok=True)
    key, by_judge = {}, collections.defaultdict(list)
    for number, row in enumerate(picked, 1):
        text, net = packet(row, number)
        with open(os.path.join(items_dir, "%02d.md" % number), "w") as handle:
            handle.write(text)
        key["%02d" % number] = {"id": row["id"], "net_lines": net}
        by_judge[family(row.get("judge") or "opus")].append("%02d" % number)
    chunks = []
    for judge, items in sorted(by_judge.items()):
        for start in range(0, len(items), READER_ITEMS):
            part = items[start:start + READER_ITEMS]
            out = os.path.join(folder, "verdicts-%d.tsv" % (len(chunks) + 1))
            path = os.path.join(key_dir, "brief-%d" % (len(chunks) + 1))
            with open(path, "w") as handle:
                handle.write(brief(part, items_dir, out))
            chunks.append({"judge": judge, "items": part, "brief": path, "out": out})
    write_json(os.path.join(key_dir, "key.json"), {"items": key, "chunks": chunks})
    return key_dir


def key_dirs():
    """{date: key directory} of every weekly read."""
    found = {}
    for path in glob.glob(os.path.join(AUDIT_DIR, "*-key")):
        day = os.path.basename(path)[:-4]
        if re.match(r"^\d{4}-\d{2}-\d{2}$", day) and os.path.isfile(os.path.join(path, "key.json")):
            found[day] = path
    return found


def pending(ledger):
    """The weekly reads whose verdicts the ledger has not recorded yet, oldest first."""
    return [path for day, path in sorted(key_dirs().items()) if day not in (ledger.get("read") or ())]


def worker_bin(name):
    return os.environ.get("FIX_AUDIT_%s" % name.upper().replace("-", "_")) or os.path.join(ROOT, "bin", name)


def reader(judge):
    """(vendor, model) of a reader outside the judge's family when a vendor of another family is on, else Opus."""
    listed = subprocess.run([worker_bin("worker-pick"), "--list", "--role", "reviewers"], capture_output=True,
                            text=True).stdout
    for line in listed.splitlines():
        cells = line.split("\t")
        if len(cells) >= 4 and cells[3] == "ok" and FAMILY.get(cells[0], cells[0]) != judge:
            return cells[0], None
    return "claudeb", "opus"


def chunk_read(chunk):
    """The chunk's verdicts when they cover every one of its items, else None (a refused, failed or partial read)."""
    rows = verdict_rows(chunk["out"])
    return rows if set(chunk["items"]) <= set(rows) else None


def read(key_dir, deadline=None):
    """Runs one reader a chunk not read yet, all at once, each in its own workdir; returns {chunk out: error or None}."""
    import collector_runs
    key = read_json(os.path.join(key_dir, "key.json"), {})
    deadline = deadline or time.time() + 3 * 3600
    started, errors = {}, {}
    for number, chunk in enumerate(key.get("chunks") or (), 1):
        if chunk_read(chunk):
            errors[chunk["out"]] = None
            continue
        chunk.pop("run", None)
        vendor, model = reader(chunk["judge"])
        chunk["reader"] = "%s:%s" % (vendor, model or "default")
        flags = ["--model", model, "--effort", "high"] if model else []
        workdir = os.path.join(os.path.dirname(chunk["out"]), "reader-%d" % number)
        os.makedirs(workdir, exist_ok=True)
        done = subprocess.run([worker_bin("worker-run"), "start", vendor, *flags, "--brief", chunk["brief"],
                               "--workdir", workdir], capture_output=True, text=True)
        run = next((l[5:].strip() for l in done.stdout.splitlines() if l.startswith("RUN: ")), None)
        if done.returncode or not run:
            errors[chunk["out"]] = "worker-run start rc %d: %s" % (done.returncode, (done.stderr or done.stdout)[-300:])
            continue
        chunk["run"] = run
        started[run] = time.time()
    for chunk in key.get("chunks") or ():
        if chunk.get("run") in started:
            waited = subprocess.run([worker_bin("worker-run"), "wait", chunk["run"], "--max",
                                     str(int(max(1, deadline - time.time())))], capture_output=True, text=True).stdout
            collector_runs.worker_launched("fix-audit", started[chunk["run"]], "FIX_AUDIT_DIR", chunk["run"], waited)
            errors.setdefault(chunk["out"], None if chunk_read(chunk) else "run %s left items unread" % chunk["run"])
    write_json(os.path.join(key_dir, "key.json"), key)
    return errors


def verdict_rows(path):
    rows = {}
    try:
        with open(path) as handle:
            for line in handle:
                cells = line.rstrip("\n").split("\t")
                if len(cells) >= 2 and re.match(r"^\d+$", cells[0].strip()) and cells[1].strip() in VERDICTS:
                    rows["%02d" % int(cells[0])] = cells + [""] * (5 - len(cells))
    except OSError:
        pass
    return rows


def apply(ledger, key_dir, now=None):
    """Records the verdicts of a read's batches read in full, and the read as done once all are; returns
    (verdicts recorded, batches still unread)."""
    now = now or time.time()
    key = read_json(os.path.join(key_dir, "key.json"), {})
    by_id = {row["id"]: row for row in ledger["rows"]}
    count = unread = 0
    for chunk in key.get("chunks") or ():
        rows = chunk_read(chunk)
        if rows is None:
            unread += 1
            continue
        for item, cells in rows.items():
            entry = (key.get("items") or {}).get(item)
            row = entry and by_id.get(entry["id"])
            if not row or item not in chunk["items"] or row.get("verdict"):
                continue
            row.update(verdict=cells[1].strip(), confidence=cells[2].strip() or None, reason=cells[3].strip() or None,
                       evidence=cells[4].strip() or None, reader=chunk.get("reader"), audited_at=iso(now),
                       net_lines=entry["net_lines"])
            count += 1
    if not unread:
        ledger["read"] = sorted(set(ledger.get("read") or ()) | {os.path.basename(key_dir)[:-4]})
    return count, unread


def report(ledger=None):
    """One line per kind (lens, finder, fixer): read, needed, share not needed, Opus-eq per needed fix."""
    kinds = collections.defaultdict(list)
    for row in (ledger or load())["rows"]:
        if row.get("verdict"):
            kinds[(row["lens"], finder(row["cell"]), row.get("fixer") or "unknown")].append(row)
    lines = ["lens\tfinder\tfixer\tread\tneeded\tnot needed\tOpus-eq per needed fix"]
    for (lens, cell, fixer), rows in sorted(kinds.items()):
        needed = sum(1 for row in rows if row["verdict"] == "needed")
        costs = [row["cost"] for row in rows if isinstance(row.get("cost"), (int, float))]
        per = "%.0f" % (sum(costs) / needed) if needed and len(costs) == len(rows) else "-"
        lines.append("%s\t%s\t%s\t%d\t%d\t%.0f %%\t%s" % (lens, cell, fixer, len(rows), needed,
                                                          100.0 * (len(rows) - needed) / len(rows), per))
    return "\n".join(lines)


def night_brief():
    return """Run `bin/fix-audit apply` in this worktree: it adds the newly landed round fixes to share/fix-ledger.json and records the verdicts of the blind reads the night's prep ran (`fix-audit read`). Commit share/fix-ledger.json by path, one line naming the counts it printed. A false or harmful fix becomes a Harness row by itself: never revert one here. Report the table it printed.
"""


def main(argv):
    usage = "usage: fix-audit read [<key-dir>] | pending | apply | report | brief"
    command, key_dir = (argv + ["", ""])[:2]
    if command == "read":
        if not key_dir:
            ledger = collect(write=False)[0]
            found = key_dirs()
            last = max(found or [""])
            if last and datetime.date.fromisoformat(last) > datetime.date.today() - datetime.timedelta(days=DUE_DAYS):
                key = read_json(os.path.join(found[last], "key.json"), {})
                if all(chunk_read(chunk) for chunk in key.get("chunks") or ()):
                    print("read %s; the next read is due %s" % (last, datetime.date.fromisoformat(last)
                                                                  + datetime.timedelta(days=DUE_DAYS)))
                    return 0
                key_dir = found[last]
            else:
                key_dir = sample(ledger)
            if not key_dir:
                print("no landed fix is due a read")
                return 0
        for out, error in read(key_dir).items():
            print("%s: %s" % (out, error or "read"))
        return 0
    if command == "pending":
        found = pending(load())
        print("\n".join(found))
        return 0 if found else 1
    if command == "apply":
        ledger, added, unmapped = collect(write=False)
        print("collected %d fixed finding(s)%s" % (len(added), "; unmapped: " + ", ".join(
            "%d %s" % (n, why) for why, n in sorted(unmapped.items())) if unmapped else ""))
        for path in pending(ledger):
            count, unread = apply(ledger, path)
            print("recorded %d verdict(s) of %s%s" % (count, path, "; %d batch(es) unread, pending `fix-audit read %s`"
                                                      % (unread, path) if unread else ""))
        write_json(LEDGER, ledger)
        print(report(ledger))
        return 0
    if command == "report":
        print(report())
        return 0
    if command == "brief":
        sys.stdout.write(night_brief())
        return 0
    print(usage, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
