#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# TEMP-SONNET-TRIAL(fixers): the whole suite; EXPERIMENTS.json entry `sonnet-fixes` removes it.
# share/sonnet_trial.py over fixture stores: each arm's runs, landed and reverted fixes, confirmed findings git blames
# on a fix's commits, Speed min/day by run, and the table only while the marker is live (--evidence regardless).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$WORK"' EXIT
export TZ=UTC HOME="$WORK/home" DOCTORS_DIR="$WORK/doctors" WORKER_STATS_DIR="$WORK/stats" WORKER_RUN_DIR="$WORK/runs" \
  SONNET_TRIAL_MARKER="$WORK/marker.json" NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" HARNESS_DOCTOR_DIR="$WORK/harness" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset CLAUDEB_DIR XDG_CACHE_HOME
mkdir -p "$HOME" "$DOCTORS_DIR/runs" "$DOCTORS_DIR/nights" "$WORKER_STATS_DIR/benches" "$WORKER_RUN_DIR"
: >"$WORK/sweep-repos"

python3 -B - "$ROOT" "$WORK" <<'EOF' || exit 1
import json, os, subprocess, sys, time

root, work = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "share"))
import sonnet_trial as S

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


repo = os.path.join(work, "repo")
start = int(time.time()) - 2 * 86400


def git(*args, at=None):
    env = dict(os.environ, GIT_AUTHOR_DATE="@%d" % at, GIT_COMMITTER_DATE="@%d" % at) if at else None
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, env=env, check=True).stdout.strip()


def commit(at, **files):
    for name, text in files.items():
        write(os.path.join(repo, name), text)
    git("add", "-A")
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c%d" % at, at=at)
    return git("rev-parse", "HEAD")


def blob(text):
    return subprocess.run(["git", "hash-object", "--stdin"], input=text, capture_output=True, text=True).stdout.strip()


subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
commit(start - 5 * 86400, **{"a.sh": "1\n2\n3\n", "b.sh": "x\n", "c.sh": "p\n"})
commit(start + 200, **{"a.sh": "1\nFIX\n3\n"})
commit(start - 86400 + 200, **{"b.sh": "y\n"})
commit(start + 300, **{"b.sh": "x\n"})
speed_commit = commit(start + 400, **{"c.sh": "q\n"})
stamp = lambda t: time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(t))
fit_round, bugs_round, later = stamp(start + 10) + "-1f17a00", stamp(start - 86400) + "-0b0950f", stamp(start + 3600) + "-1a7e400"
benches = os.path.join(work, "stats", "benches")
write(f"{benches}/{fit_round}/meta.json", {"lens": "fit"})
write(f"{benches}/{bugs_round}/meta.json", {})
write(f"{benches}/{later}/meta.json", {"repos": [{"repo": repo, "commit": git("rev-parse", "HEAD")}]})
write(f"{benches}/{later}/findings-r.jsonl",
      "".join(json.dumps(f) + "\n" for f in ({"file": "repo/a.sh", "line": 2}, {"file": "repo/a.sh", "line": 1},
                                             {"file": "repo/a.sh", "line": 3})))
write(f"{benches}/{later}/verdicts.jsonl",
      "".join(json.dumps({"rater": "r", "idx": i, "verdict": v}) + "\n"
              for i, v in enumerate(("confirmed", "confirmed", "false_positive"))))


def run(name, began, meta, produced, fixed):
    directory = os.path.join(work, "runs", "claudeb-%d-%s" % (began, name))
    write(f"{directory}/meta.json", dict(meta, vendor="claudeb", workdir=repo, ended_at=began + 100))
    write(f"{directory}/produced", "".join("%s\t%s\t%s\n" % row for row in produced))
    write(f"{directory}/verdicts.jsonl", "".join(json.dumps({"kind": "fixer", "finding": i, "outcome": "fixed"}) + "\n"
                                                for i in range(fixed)))


run("1-sonnet", start + 100, {"model": "sonnet", "trial": "sonnet-fixes", "trial_lens": "fit", "review_round": fit_round},
    [(blob("1\n2\n3\n"), blob("1\nFIX\n3\n"), "a.sh")], 2)
run("2-opus", start - 86400 + 100, {"model": "opus", "review_round": fit_round}, [(blob("x\n"), blob("y\n"), "b.sh")], 1)
run("3-bugs", start + 100, {"model": "opus", "review_round": bugs_round}, [(blob("x\n"), blob("y\n"), "b.sh")], 4)
run("4-old", start - 20 * 86400, {"model": "opus", "review_round": fit_round}, [], 4)
night = os.path.join(work, "doctors", "nights", "n1.json")
write(night, {"id": "n1", "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start + 300)), "jobs": [
    {"ref": "speed-a", "state": "merged", "commits": [{"repo": repo, "hash": speed_commit}]},
    {"ref": "speed-b", "state": "left", "commits": []}]})
for ref, arm in (("speed-a", "sonnet"), ("speed-b", "opus")):
    write(os.path.join(work, "doctors", "runs", ref + ".json"),
          {"id": ref, "area": "speed-x", "trial": {"id": "sonnet-fixes", "arm": arm}, "closed_at": "2026-01-01T00:00:00Z",
           "decisions": [{"id": "p", "verdict": "fixed"}, {"id": "judge", "verdict": "changed"}], "worktrees": []})
write(os.path.join(work, "doctors", "runs", "speed-c.json"), {"id": "speed-c", "area": "speed-y"})

S.time_budget.roi_lines = lambda rows, now, gains: gains.update({"speed-a": 6.5, "speed-z": 9.0})
S.time_budget.cached_row = lambda worker_run, path: None
stats, _ = S.arms("/usr/bin/false", night, start)
got = {arm: {k: v for k, v in stats[arm].items() if v} for arm in S.ARMS}
check(got[("round", "sonnet")] == {"runs": 1, "landed": 2, "findings": 1},
      "a tagged fit fixer's fixes landed, one confirmed finding on its own line, none on lines it did not write: %s" % got)
check(got[("round", "opus")] == {"runs": 1, "landed": 1, "reverted": 1},
      "an untagged Opus fit fixer since the baseline is the Opus arm; main back at its pre-fix blob is a revert; "
      "a bugs-lens fixer and one older than the baseline count nowhere: %s" % got)
check(got[("speed", "sonnet")] == {"runs": 1, "landed": 1, "min_day": 6.5},
      "a merged Speed job's fixed decisions landed, its run's ROI minutes go to its arm: %s" % got)
check(got[("speed", "opus")] == {"runs": 1}, "a left Speed job landed nothing: %s" % got)

gone = os.path.join(repo, ".claude", "worktrees", "gone")
commit(start + 500, **{"d.sh": "d0\n"})
commit(start + 600, **{"d.sh": "d1\n"})
write(os.path.join(repo, "d.sh"), "d1\nd2\n")
git("add", "d.sh")
git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "Debt fit round %s: two fixers" % fit_round, at=start + 900)
debt = git("rev-parse", "HEAD")
extra = os.path.join(work, "extra")
for name, after in (("on-main", "d1\n"), ("superseded", "d0\nmine\n")):
    write(f"{extra}/{name}/produced", "%s\t%s\td.sh\n" % (blob("d0\n"), blob(after)))
    meta = {"workdir": gone, "review_round": fit_round, "ended_at": start + 550}
    check(S.directory_fix(f"{extra}/{name}", meta, start + 450, 1)["landed"],
          "a fixer whose worktree is gone still finds its landing (%s)" % name)
check(S.directory_fix(f"{extra}/superseded", {"workdir": gone, "review_round": fit_round, "ended_at": start + 550},
                      start + 450, 1)["commits"] == {debt}, "a superseded blob lands through the debt commit naming its round")
check(not S.directory_fix(f"{extra}/superseded", {"workdir": gone, "review_round": later, "ended_at": start + 550},
                          start + 450, 1)["landed"], "a commit naming another round is not this fixer's landing")

write(os.environ["SONNET_TRIAL_MARKER"], {"id": "sonnet-fixes", "started": start, "until": int(time.time()) + 3600})
out = subprocess.run([sys.executable, "-B", os.path.join(root, "share", "sonnet_trial.py"), "/usr/bin/false", night],
                     capture_output=True, text=True)
check(out.returncode == 0 and out.stdout.splitlines()[1].split() == ["runs", "landed", "reverted", "findings", "min/day", "Opus-eq"]
      and out.stdout.splitlines()[2].split()[:6] == ["round", "sonnet", "1", "2", "0", "1"],
      "the live marker prints the arm table: %s %s" % (out.stdout, out.stderr))
write(os.environ["SONNET_TRIAL_MARKER"], {"id": "sonnet-fixes", "started": start, "until": int(time.time()) - 1})
spent = lambda *extra: subprocess.run([sys.executable, "-B", os.path.join(root, "share", "sonnet_trial.py"),
                                       "/usr/bin/false", night, *extra], capture_output=True, text=True).stdout
check(spent() == "", "a spent marker prints nothing in the report")
check(spent("--evidence").startswith("trial sonnet-fixes"), "--evidence prints the arms once the trial is over")
print("PASS: test_night_report_trial.sh (%d asserts)" % count[0])
EOF
