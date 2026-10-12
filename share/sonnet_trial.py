# TEMP-SONNET-TRIAL(fixers): the whole file; EXPERIMENTS.json entry `sonnet-fixes` removes it.
"""The arms of the Sonnet-vs-Opus fixer trial, printed by `night-run report` while the marker is live and by
`sonnet_trial.py <worker-run> <night.json> --evidence` at any time. Round arms: claudeb fixers of fit/legacy review
rounds, Sonnet the runs whose meta carries `trial`, Opus the untagged Opus ones of those lenses since BASELINE_DAYS
before the trial began. Speed arms: doctor-fix records by their `trial.arm`.

landed and reverted count fixes (fixed verdict rows, fixed decisions) of runs whose content reached main, and of those
a path main holds again at its pre-fix blob; findings are confirmed review findings of later rounds whose line git
blames on a landing commit of the fix.
"""

import calendar
import collections
import glob
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import night_churn  # noqa: E402
import night_spend  # noqa: E402
import time_budget  # noqa: E402
from spend import read_json  # noqa: E402

ID = "sonnet-fixes"
BASELINE_DAYS = 14
LENS = re.compile(r"^(fit|legacy(-.*)?)$")
NO_BLOB = re.compile(r"^(0+|e69de29bb2d1d6434b8b29ae775ad8c2e48c5391)$")
ARMS = (("round", "sonnet"), ("round", "opus"), ("speed", "sonnet"), ("speed", "opus"))


def marker_path(night_path=None):
    return os.environ.get("SONNET_TRIAL_MARKER") or os.path.join(night_churn.doctors_dir(night_path), "sonnet-trial.json")


def marker(night_path=None):
    found = read_json(marker_path(night_path), None)
    return found if isinstance(found, dict) and isinstance(found.get("until"), (int, float)) else None


def git(top, *args):
    if not top:
        return None
    done = subprocess.run(["git", "-C", top, *args], capture_output=True, text=True, errors="replace")
    return done.stdout if done.returncode == 0 else None


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def main_blob(top, path):
    return (git(top, "rev-parse", "--verify", "-q", "main:" + path) or "").strip() or None


def fix_record(top, fixes, ended, rows, commits=None):
    """rows: (before, after, path) of the fix in top; commits: its landing commits, else found by the after blobs."""
    found = set(commits or ())
    if commits is None:
        for before, after, path in rows:
            if not NO_BLOB.match(after) and after != before:
                found |= set((git(top, "log", "main", "--format=%H", "--since=" + iso(ended - 86400),
                                  "--find-object=" + after, "--", path) or "").split())
    return {"top": top, "fixes": fixes, "ended": ended, "commits": found, "paths": {p for _, _, p in rows},
            "landed": bool(found), "reverted": bool(found) and any(
                not NO_BLOB.match(before) and before != after and main_blob(top, path) == before
                for before, after, path in rows)}


def round_runs(start):
    for directory in glob.glob(f"{night_spend.RUNS}/claudeb-*"):
        parts = os.path.basename(directory).split("-")
        if len(parts) < 2 or not parts[1].isdigit() or int(parts[1]) < start - BASELINE_DAYS * 86400:
            continue
        meta = read_json(f"{directory}/meta.json", {})
        round_id = meta.get("review_round")
        if not round_id or meta.get("light"):
            continue
        if meta.get("trial") == ID:
            arm = "sonnet"
        elif meta.get("model") == "opus" and LENS.match(
                str(read_json(f"{night_spend.BENCHES}/{round_id}/meta.json", {}).get("lens") or "")):
            arm = "opus"
        else:
            continue
        yield arm, os.path.basename(directory), directory, meta, int(parts[1])


def fixed_findings(directory):
    return [r.get("finding") for r in night_spend.rows(f"{directory}/verdicts.jsonl")
            if r.get("kind") == "fixer" and r.get("outcome") == "fixed"]


def directory_fix(directory, meta, began, fixes):
    workdir = str(meta.get("workdir") or "")
    top = (git(workdir, "rev-parse", "--show-toplevel") or "").strip()
    if not top and "/.claude/worktrees/" in workdir:
        top = (git(workdir.split("/.claude/worktrees/")[0], "rev-parse", "--show-toplevel") or "").strip()
    rows = [tuple(line.split("\t")[:3]) for line in night_spend.read(f"{directory}/produced").splitlines()
            if line.count("\t") >= 2]
    ended = meta.get("ended_at") or began
    record = fix_record(top, fixes, ended, rows)
    # A debt job commits its round's fixers together: a later fixer's edit replaces an earlier one's blob.
    if not record["landed"] and meta.get("review_round") and rows:
        commits = set((git(top, "log", "main", "--format=%H", "--since=" + iso(ended - 86400), "-F",
                           "--grep=" + meta["review_round"], "--", *{p for _, _, p in rows}) or "").split())
        if commits:
            record = fix_record(top, fixes, ended, rows, commits)
    return record


def round_fix(directory, meta, began):
    return directory_fix(directory, meta, began, len(fixed_findings(directory)))


def speed_fixes(ddir):
    """(arm, record, [fix per repository]) of each trial Speed record; a fix per repository its landed commits touched."""
    jobs = {}
    for path in glob.glob(f"{ddir}/nights/*.json"):
        for job in read_json(path, {}).get("jobs") or ():
            if isinstance(job, dict) and job.get("ref"):
                jobs[job["ref"]] = job
    for path in sorted(glob.glob(f"{ddir}/runs/*.json")):
        record = read_json(path, {})
        trial = record.get("trial") if isinstance(record, dict) else None
        if not isinstance(trial, dict) or trial.get("id") != ID:
            continue
        fixes = sum(1 for d in record.get("decisions") or () if isinstance(d, dict) and d.get("verdict") == "fixed")
        ended = night_spend.epoch(record["closed_at"]) if record.get("closed_at") else time.time()
        job = jobs.get(record.get("id"))
        out = []
        if job:
            by_repo = collections.defaultdict(list)
            for commit in job.get("commits") or [] if job.get("state") == "merged" else []:
                by_repo[night_churn.repo_dir(commit.get("repo") or "")].append(commit.get("hash"))
            for top, hashes in by_repo.items():
                rows = []
                for sha in hashes:
                    for line in (git(top, "diff-tree", "-r", "--no-commit-id", "--no-renames", sha) or "").splitlines():
                        head, _, name = line.partition("\t")
                        fields = head.split()
                        if len(fields) >= 4:
                            rows.append((fields[2], fields[3], name))
                out.append(fix_record(top, 0, ended, rows, set(hashes)))
        else:
            worktree = (record.get("worktrees") or [""])[0]
            top = worktree.split("/.claude/worktrees/")[0]
            gone = record.get("closed_at") and not git(top, "rev-parse", "--verify", "-q", "refs/heads/" + str(record.get("branch")))
            out.append({"top": top, "fixes": 0, "ended": ended, "commits": set(), "paths": set(),
                        "landed": bool(gone), "reverted": False})
        if out:
            out[0]["fixes"] = fixes
            out[0]["landed"] = any(f["landed"] for f in out)
        yield trial.get("arm"), record, out


def findings_on(fixes):
    """Per fix index: confirmed findings of rounds begun after it whose line git blames on one of its commits."""
    targets = collections.defaultdict(list)
    for index, fix in enumerate(fixes):
        if fix["landed"] and fix["commits"]:
            for path in fix["paths"]:
                targets[f"{os.path.basename(fix['top'])}/{path}"].append(index)
    counts = collections.Counter()
    if not targets:
        return counts
    earliest = min(fixes[i]["ended"] for found in targets.values() for i in found)
    for bench in sorted(glob.glob(f"{night_spend.BENCHES}/*")):
        try:
            began = calendar.timegm(time.strptime(os.path.basename(bench)[:16], "%Y%m%dT%H%M%SZ"))
        except ValueError:
            continue
        if began < earliest:
            continue
        confirmed = collections.defaultdict(set)
        for row in night_spend.rows(f"{bench}/verdicts.jsonl"):
            if row.get("verdict") == "confirmed" and isinstance(row.get("idx"), int):
                confirmed[row.get("rater")].add(row["idx"])
        if not confirmed:
            continue
        meta = read_json(f"{bench}/meta.json", {})
        heads = {os.path.basename(str(r.get("repo") or "")): r.get("commit") for r in meta.get("repos") or () if isinstance(r, dict)}
        for rater, indexes in confirmed.items():
            for idx, finding in enumerate(night_spend.rows(f"{bench}/findings-{rater}.jsonl")):
                name, line = str(finding.get("file") or ""), finding.get("line")
                if idx not in indexes or name not in targets or not isinstance(line, int) or line < 1:
                    continue
                repo, _, rel = name.partition("/")
                commit = heads.get(repo) or meta.get("commit")
                for index in targets[name]:
                    if began <= fixes[index]["ended"]:
                        continue
                    blamed = (git(fixes[index]["top"], "blame", "--porcelain", "-L", f"{line},{line}", str(commit), "--", rel) or "").split()
                    if blamed and blamed[0] in fixes[index]["commits"]:
                        counts[index] += 1
    return counts


def arms(worker_run, night_path, start):
    ddir = night_churn.doctors_dir(night_path)
    stats = {arm: collections.Counter() for arm in ARMS}
    spend = {arm: collections.Counter() for arm in ARMS}
    fixes, owner, seen = [], [], set()
    for arm, run, directory, meta, began in round_runs(start):
        stats[("round", arm)]["runs"] += 1
        fix = round_fix(directory, meta, began)
        fixes.append(fix)
        owner.append(("round", arm))
        spend[("round", arm)] += night_spend.run_usage(worker_run, run, "claudeb", seen) or collections.Counter()
    records, by_workdir = {}, collections.defaultdict(list)
    for directory in glob.glob(f"{night_spend.RUNS}/*-*"):
        parts = os.path.basename(directory).split("-")
        if len(parts) > 1 and parts[1].isdigit() and int(parts[1]) >= start:
            meta = read_json(f"{directory}/meta.json", {})
            if meta.get("workdir"):
                by_workdir[os.path.realpath(meta["workdir"])].append(
                    (os.path.basename(directory), meta.get("vendor") or parts[0]))
    for arm, record, found in speed_fixes(ddir):
        if ("speed", arm) not in stats:
            continue
        stats[("speed", arm)]["runs"] += 1
        records[record["id"]] = ("speed", arm)
        fixes += found
        owner += [("speed", arm)] * len(found)
        for worktree in record.get("worktrees") or ():
            for run, vendor in by_workdir.get(os.path.realpath(worktree), ()):
                spend[("speed", arm)] += night_spend.run_usage(worker_run, run, vendor, seen) or collections.Counter()
    for index, fix in enumerate(fixes):
        if fix["landed"]:
            stats[owner[index]]["landed"] += fix["fixes"]
            stats[owner[index]]["reverted"] += fix["fixes"] if fix["reverted"] else 0
    for index, count in findings_on(fixes).items():
        stats[owner[index]]["findings"] += count
    gains = collections.Counter()
    nights = [] if not records else [p for _, p, n in time_budget.nights_upto(night_path) if night_spend.epoch(n["started_at"]) >= start - 86400]
    time_budget.roi_lines([time_budget.cached_row(worker_run, p) for p in nights], time_budget.now_s(), gains)
    for ref, gain in gains.items():
        if ref in records:
            stats[records[ref]]["min_day"] += gain
    return stats, spend


def lines(worker_run, night_path, found):
    stats, spend = arms(worker_run, night_path, found.get("started") or found["until"] - 15 * 86400)
    dash = "–"
    rows = [["", "runs", "landed", "reverted", "findings", "min/day", night_spend.UNIT]]
    for kind, arm in ARMS:
        s = stats[(kind, arm)]
        rows.append([f"{kind} {arm}", str(s["runs"]), str(s["landed"]), str(s["reverted"]), str(s["findings"]),
                     "%.1f" % s["min_day"] if kind == "speed" else dash,
                     night_spend.mega(night_spend.weighted(spend[(kind, arm)]))])
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    head = "trial %s → %s" % (ID, time.strftime("%d %b", time.localtime(found["until"])).lstrip("0"))
    return [head] + ["  ".join(c.rjust(w) if i else c.ljust(w) for i, (c, w) in enumerate(zip(r, widths))) for r in rows]


def main(argv):
    worker_run, night_path = argv[:2]
    found = marker(night_path)
    if not found or "--evidence" not in argv[2:] and found["until"] <= time.time():
        return 0
    night_spend.pricing()
    print("\n".join(lines(worker_run, night_path, found)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
