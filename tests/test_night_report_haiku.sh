#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# TEMP-HAIKU-TRIAL(report): the whole suite; EXPERIMENTS.json entry `haiku-review-cells` removes it.
# share/haiku_trial.py over fixture stores: one line per fit/legacy/speed round of the night staffing a Haiku cell, with
# the judge state, found and confirmed per cell family, and its fixers' fixes landed, reverted or unlanded.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$WORK"' EXIT
export TZ=UTC HOME="$WORK/home" DOCTORS_DIR="$WORK/doctors" WORKER_STATS_DIR="$WORK/stats" WORKER_RUN_DIR="$WORK/runs" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset CLAUDEB_DIR XDG_CACHE_HOME
mkdir -p "$HOME" "$DOCTORS_DIR/nights" "$WORKER_STATS_DIR/benches" "$WORKER_RUN_DIR"
grep -q 'share/haiku_trial.py" "$file"' "$ROOT/bin/night-run" || { echo "FAIL: night-run report does not print the haiku trial" >&2; exit 1; }

python3 -B - "$ROOT" "$WORK" <<'EOF' || exit 1
import json, os, subprocess, sys, time

root, work = sys.argv[1], sys.argv[2]
count = [0]


def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)


def write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(value if isinstance(value, str) else json.dumps(value))


def jsonl(path, rows):
    write(path, "".join(json.dumps(r) + "\n" for r in rows))


repo = os.path.join(work, "repo")
start = int(time.time()) - 3 * 3600


def git(*args, at=None):
    env = dict(os.environ, GIT_AUTHOR_DATE="@%d" % at, GIT_COMMITTER_DATE="@%d" % at) if at else None
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, env=env, check=True).stdout.strip()


def commit(at, **files):
    for name, text in files.items():
        write(os.path.join(repo, name), text)
    git("add", "-A")
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c%d" % at, at=at)


def blob(text):
    return subprocess.run(["git", "hash-object", "--stdin"], input=text, capture_output=True, text=True).stdout.strip()


subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
commit(start - 86400, **{"a.sh": "1\n", "b.sh": "x\n"})
commit(start + 600, **{"a.sh": "FIX\n"})
commit(start + 700, **{"b.sh": "y\n"})
commit(start + 800, **{"b.sh": "x\n"})
stamp = lambda t: time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(t))
benches = os.path.join(work, "stats", "benches")
cells = [{"spec": "haiku-high"}, {"spec": "haiku-high#2"}, {"spec": "sol-high"}, {"spec": "flash"}]
legacy, fit, bugs, before = (stamp(start + t) + "-" + s for t, s in ((60, "1e9a"), (120, "f17"), (180, "b09"), (-600, "01d")))
write(f"{benches}/{legacy}/meta.json", {"lens": "legacy", "panel_raters": cells, "judge": {"state": "ran"}})
for spec, n in (("haiku-high", 3), ("haiku-high#2", 2), ("sol-high", 2), ("flash", 1)):
    jsonl(f"{benches}/{legacy}/findings-{spec}.jsonl", [{"file": "repo/a.sh", "line": 1}] * n)
jsonl(f"{benches}/{legacy}/verdicts.jsonl", [
    {"rater": "haiku-high", "idx": 0, "verdict": "confirmed", "by": "judge"},
    {"rater": "sol-high", "idx": 0, "verdict": "confirmed", "by": "judge"},
    {"rater": "haiku-high#2", "idx": 1, "verdict": "confirmed", "by": "judge"},
    {"rater": "haiku-high", "idx": 1, "verdict": "false_positive", "by": "judge"},
    {"rater": "flash", "idx": 0, "verdict": "duplicate", "by": "judge"},
    {"kind": "fixer", "finding": 0, "outcome": "fixed"}])
write(f"{benches}/{fit}/meta.json", {"lens": "fit", "panel_raters": cells[:1],
                                     "judge": {"state": "skipped", "reason": "--only"}})
jsonl(f"{benches}/{fit}/findings-haiku-high.jsonl", [{"file": "repo/a.sh", "line": 1}])
write(f"{benches}/{bugs}/meta.json", {"panel_raters": [{"spec": "opus-high"}], "judge": {"state": "ran"}})
write(f"{benches}/{before}/meta.json", {"lens": "legacy", "panel_raters": cells, "judge": {"state": "ran"}})


def run(name, began, round_id, produced, fixed):
    directory = os.path.join(work, "runs", "claudeb-%d-%s" % (began, name))
    write(f"{directory}/meta.json", {"vendor": "claudeb", "workdir": repo, "ended_at": began + 100, "review_round": round_id})
    write(f"{directory}/produced", "".join("%s\t%s\t%s\n" % row for row in produced))
    jsonl(f"{directory}/verdicts.jsonl", [{"kind": "fixer", "finding": i, "outcome": o} for i, o in fixed])


run("landed", start + 500, legacy, [(blob("1\n"), blob("FIX\n"), "a.sh")], [(0, "fixed"), (1, "fixed")])
run("reverted", start + 650, legacy, [(blob("x\n"), blob("y\n"), "b.sh")], [(2, "fixed"), (3, "false")])
run("unlanded", start + 900, legacy, [(blob("1\n"), blob("NEVER\n"), "a.sh")], [(0, "fixed")])
run("other", start + 500, bugs, [(blob("1\n"), blob("FIX\n"), "a.sh")], [(0, "fixed")])
night = os.path.join(work, "doctors", "nights", "n1.json")
write(night, {"id": "n1", "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start)), "jobs": []})

out = subprocess.run([sys.executable, "-B", os.path.join(root, "share", "haiku_trial.py"), night], capture_output=True, text=True)
lines = out.stdout.splitlines()
check(out.returncode == 0 and len(lines) == 2,
      "one line per fit/legacy round of the night with a Haiku cell; a bugs round and one before the night print none: %r %s"
      % (out.stdout, out.stderr))
check(lines[0] == f"haiku trial · legacy · {legacy} · judge ran · 8 found · 3 confirmed · haiku-high 2/5 · flash 0/1 · sol-high 1/2"
      " · fixes 4 (haiku 3) · reverted 1 (haiku 1) · unlanded 1 (haiku 1)",
      "repeated cells fold into their family, Haiku first; a fixer row's finding is its judge row's position "
      "(the bench's own fixer row is not one); a fix landed, one reverted on main, one never landed: %s" % lines[0])
check(lines[1] == f"haiku trial · fit · {fit} · judge skipped (--only) · 1 found · 0 confirmed · haiku-high 0/1"
      " · fixes 0 (haiku 0) · reverted 0 (haiku 0) · unlanded 0 (haiku 0)",
      "a round the judge skipped says so and why: %s" % lines[1])
print("PASS: test_night_report_haiku.sh (%d asserts)" % (count[0] + 1))
EOF
