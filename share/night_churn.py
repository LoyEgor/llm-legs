"""The observational churn block of `night-run report`: per-branch vs other review rounds,
problems touched again without proof and regressions from after snapshots, fixer spend
without proof, and rewritten lines written in the previous 7 days.

Measurement only: printed as part of the report header, gates nothing.
"""

import collections
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import handoffs
import night_spend

HOME = os.path.expanduser("~")
_attr_cache = {}


def doctors_dir(night_path=None):
    if os.environ.get("DOCTORS_DIR"):
        return os.environ["DOCTORS_DIR"]
    if night_path:
        cand = os.path.dirname(os.path.dirname(night_path))
        if os.path.isdir(os.path.join(cand, "runs")):
            return cand
    return f"{HOME}/.cache/doctors"


def repo_dir(repo):
    if repo.startswith("/"):
        return repo
    return next((p for p in handoffs.sweep_repos() + handoffs.helper_repos() if os.path.basename(p) == repo), None)


def check_linguist_generated(repo_path, file_paths):
    needed = [f for f in file_paths if (repo_path, f) not in _attr_cache]
    if needed:
        try:
            res = subprocess.run(["git", "-C", repo_path, "check-attr", "linguist-generated", "--"] + needed,
                                 capture_output=True, text=True, errors="replace")
            for line in res.stdout.splitlines():
                parts = line.split(": ")
                if len(parts) >= 3 and parts[1] == "linguist-generated":
                    _attr_cache[(repo_path, parts[0])] = parts[2] in ("set", "true")
        except OSError:
            pass
    return {f: _attr_cache.get((repo_path, f), False) for f in file_paths}


def reviews_line(night):
    per_branch_reviews = {job["review"] for job in night.get("jobs", []) if job.get("review")}

    per_branch_n, per_branch_w = 0, 0.0
    other_n, other_w = 0, 0.0

    for bench in night_spend.night_benches(*night_spend.window(night)):
        bname = os.path.basename(bench)
        w = night_spend.weighted(night_spend.bench_usage(bench))
        if bname in per_branch_reviews:
            per_branch_n += 1
            per_branch_w += w
        else:
            other_n += 1
            other_w += w

    if per_branch_n == 0 and other_n == 0:
        return None
    return (f"reviews · per-branch {per_branch_n} rounds ({night_spend.mega(per_branch_w)} {night_spend.UNIT}) · "
            f"other {other_n} rounds ({night_spend.mega(other_w)} {night_spend.UNIT})")


def problem_counts(night, night_path):
    """(touched again without proof as (doctor, id, nights, state), regressed count), or None without a fixer job
    or an after snapshot."""
    fixer_jobs = [j for j in night.get("jobs", []) if j.get("kind") == "fixer"]
    after_snapshot = night.get("doctor_problems_after")
    if not fixer_jobs or after_snapshot is None:
        return None

    ddir = doctors_dir(night_path)
    nights_dir = os.path.join(ddir, "nights")
    runs_dir = os.path.join(ddir, "runs")

    earlier_problem_nights = collections.defaultdict(set)
    for f in sorted(glob.glob(os.path.join(nights_dir, "*.json"))):
        try:
            with open(f) as h:
                other = json.load(h)
        except (OSError, ValueError):
            continue
        if (other.get("started_at", ""), other.get("id", "")) < (night.get("started_at", ""), night.get("id", "")):
            en_id = other.get("id")
            for job in other.get("jobs", []):
                if job.get("kind") == "fixer" and job.get("ref"):
                    ref = job["ref"]
                    run_file = os.path.join(runs_dir, f"{ref}.json")
                    try:
                        with open(run_file) as rh:
                            run_data = json.load(rh)
                    except (OSError, ValueError):
                        continue
                    doctor = run_data.get("doctor") or ref.split("-")[0]
                    for d in run_data.get("decisions", []):
                        pid = d.get("id")
                        if pid:
                            earlier_problem_nights[(doctor, pid)].add(en_id)

    tonight_pids = set()
    for job in night.get("jobs", []):
        if job.get("kind") == "fixer" and job.get("ref"):
            ref = job["ref"]
            run_file = os.path.join(runs_dir, f"{ref}.json")
            try:
                with open(run_file) as rh:
                    run_data = json.load(rh)
            except (OSError, ValueError):
                continue
            doctor = run_data.get("doctor") or ref.split("-")[0]
            for d in run_data.get("decisions", []):
                pid = d.get("id")
                if pid:
                    tonight_pids.add((doctor, pid))

    touched_without_proof = []
    for (doctor, pid) in tonight_pids:
        if (doctor, pid) in earlier_problem_nights:
            n_nights = len(earlier_problem_nights[(doctor, pid)]) + 1
            doc_probs = after_snapshot.get(doctor) or {}
            if pid not in doc_probs:
                continue
            state = doc_probs[pid]
            if state == "proved":
                continue
            touched_without_proof.append((doctor, pid, n_nights, state))

    R = 0
    for doc_probs in after_snapshot.values():
        if isinstance(doc_probs, dict):
            for st in doc_probs.values():
                if st == "regressed":
                    R += 1

    return touched_without_proof, R


def problems_lines(night, night_path):
    if not [j for j in night.get("jobs", []) if j.get("kind") == "fixer"]:
        return []
    if night.get("doctor_problems_after") is None:
        return ["problems · no snapshot"]
    touched_without_proof, R = problem_counts(night, night_path)
    K = len(touched_without_proof)
    if K == 0 and R == 0:
        return []

    lines = [f"problems · {K} touched again without proof · {R} regressed"]
    if K > 0:
        touched_without_proof.sort(key=lambda item: (-item[2], item[0], item[1]))
        for doctor, pid, n_nights, state in touched_without_proof[:8]:
            lines.append(f"problem · {doctor}/{pid} · nights touched {n_nights} · now {state}")
    return lines


def fixer_spend(night, night_path, worker_run):
    """(fixer jobs, their run records, usage per job ref, all usage of the night's runs), or None with no fixer job."""
    ddir = doctors_dir(night_path)
    runs_dir = os.path.join(ddir, "runs")

    fixer_jobs = [j for j in night.get("jobs", []) if j.get("kind") == "fixer"]
    if not fixer_jobs:
        return None

    fixer_runs_data = {}
    for j in fixer_jobs:
        ref = j["ref"]
        try:
            with open(os.path.join(runs_dir, f"{ref}.json")) as h:
                fixer_runs_data[ref] = json.load(h)
        except (OSError, ValueError):
            fixer_runs_data[ref] = {}

    seen = set()
    fixer_spend = collections.defaultdict(collections.Counter)
    all_fixer_usage = collections.Counter()

    for run, directory, meta, vendor in night_spend.night_runs(*night_spend.window(night)):
        usage = night_spend.run_usage(worker_run, run, vendor, seen)
        if usage is None:
            continue
        all_fixer_usage += usage

        matched_ref = None
        workdir = meta.get("workdir", "")
        brief_launch = night_spend.read(f"{directory}/brief.launch")
        brief = night_spend.read(f"{directory}/brief")

        for j in fixer_jobs:
            ref = j["ref"]
            rdata = fixer_runs_data.get(ref, {})
            worktrees = rdata.get("worktrees", [])
            if meta.get("ref") == ref or meta.get("job") == ref or run == ref:
                matched_ref = ref
                break
            if workdir and (workdir in worktrees or any(wt in workdir for wt in worktrees)):
                matched_ref = ref
                break
            if ref in workdir:
                matched_ref = ref
                break
            if ref in brief_launch or ref in brief:
                matched_ref = ref
                break
        if matched_ref:
            fixer_spend[matched_ref] += usage
    return fixer_jobs, fixer_runs_data, fixer_spend, all_fixer_usage


def fixer_spend_line(night, night_path, worker_run):
    after_snapshot = night.get("doctor_problems_after")
    found = fixer_spend(night, night_path, worker_run)
    if found is None:
        return None
    fixer_jobs, fixer_runs_data, fixer_spend_by_ref, all_fixer_usage = found

    total_Y = night_spend.weighted(all_fixer_usage)
    if total_Y == 0:
        return None

    if after_snapshot is None:
        return "fixer spend without proof · no snapshot"

    unproven_X = 0.0
    for j in fixer_jobs:
        ref = j["ref"]
        rdata = fixer_runs_data.get(ref, {})
        doctor = rdata.get("doctor") or ref.split("-")[0]
        decisions = rdata.get("decisions", [])
        decided_pids = [d["id"] for d in decisions if d.get("id")]

        has_proof = False
        doc_probs = after_snapshot.get(doctor)
        for pid in decided_pids:
            if isinstance(doc_probs, dict) and (pid not in doc_probs or doc_probs[pid] == "proved"):
                has_proof = True
                break
        if not has_proof:
            unproven_X += night_spend.weighted(fixer_spend_by_ref[ref])

    if unproven_X == 0:
        return None
    return (f"fixer spend without proof · {night_spend.mega(unproven_X)} {night_spend.UNIT} "
            f"of {night_spend.mega(total_Y)}")


def rewrite_counts(night):
    """(lines deleted that were written in the 7 days before, lines deleted, of them by night commits, unreadable
    commits), or None when the night merged no commit."""
    low = night_spend.epoch(night["started_at"])
    cutoff = low - 7 * 86400

    total_M = 0
    total_N = 0
    total_P = 0
    unreadable = 0

    merged_jobs = [j for j in night.get("jobs", []) if j.get("state") == "merged"]
    all_commits = []
    for j in merged_jobs:
        for c in j.get("commits", []):
            all_commits.append(c)

    if not all_commits:
        return None

    for c in all_commits:
        repo_name = c.get("repo")
        h = c.get("hash")
        d = repo_dir(repo_name) if repo_name else None
        if not d or not h:
            unreadable += 1
            continue

        res = subprocess.run(["git", "-C", d, "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-color",
                              "--src-prefix=a/", "--dst-prefix=b/", "-U0", f"{h}^", h],
                             capture_output=True, text=True, errors="replace")
        if res.returncode != 0:
            unreadable += 1
            continue

        current_file = None
        file_ranges = collections.defaultdict(list)
        for line in res.stdout.splitlines():
            if line.startswith("--- "):
                current_file = line[6:].rstrip("\t") if line.startswith("--- a/") else None
            elif line.startswith("@@ ") and current_file:
                m = re.match(r"^@@ -(\d+)(?:,(\d+))? \+", line)
                if m:
                    start = int(m.group(1))
                    count = int(m.group(2)) if m.group(2) is not None else 1
                    if count > 0:
                        file_ranges[current_file].append((start, start + count - 1, count))

        if not file_ranges:
            continue

        attr_map = check_linguist_generated(d, list(file_ranges.keys()))
        for fpath, ranges in file_ranges.items():
            if attr_map.get(fpath, False):
                continue
            blame_args = ["git", "-C", d, "blame", "--porcelain"]
            for s, e, count in ranges:
                blame_args.extend(["-L", f"{s},{e}"])
            blame_args.extend([f"{h}^", "--", fpath])
            bres = subprocess.run(blame_args, capture_output=True, text=True, errors="replace")
            if bres.returncode != 0:
                continue
            total_M += sum(count for s, e, count in ranges)

            commits_meta = {}
            current_sha = None
            for bline in bres.stdout.splitlines():
                if bline.startswith("\t"):
                    cm = commits_meta.get(current_sha, {})
                    atime = cm.get("author-time", 0)
                    summary = cm.get("summary", "")
                    if cutoff <= atime < low:
                        total_N += 1
                        if summary.startswith("Night"):
                            total_P += 1
                elif " " in bline and len(bline.split()[0]) == 40:
                    current_sha = bline.split()[0]
                    if current_sha not in commits_meta:
                        commits_meta[current_sha] = {}
                elif current_sha and " " in bline:
                    k, _, v = bline.partition(" ")
                    if k == "author-time" and v.isdigit():
                        commits_meta[current_sha][k] = int(v)
                    elif k == "summary":
                        commits_meta[current_sha][k] = v

    return total_N, total_M, total_P, unreadable


def rewrite_lines(night):
    counts = rewrite_counts(night)
    if counts is None:
        return []
    total_N, total_M, total_P, unreadable = counts
    lines = []
    if total_M > 0:
        night_part = f" ({total_P} by earlier night commits)" if total_P > 0 else ""
        lines.append(f"rewrite · {total_N} of {total_M} lines deleted tonight were written in the 7 days before{night_part}")
    if unreadable > 0:
        lines.append(f"rewrite · {unreadable} commits unreadable")
    return lines


def report(worker_run, path):
    with open(path) as handle:
        night = json.load(handle)

    rev_line = reviews_line(night)
    if rev_line:
        print(rev_line)

    for p_line in problems_lines(night, path):
        print(p_line)

    fix_line = fixer_spend_line(night, path, worker_run)
    if fix_line:
        print(fix_line)

    for r_line in rewrite_lines(night):
        print(r_line)


def main():
    try:
        worker_run = sys.argv[1] if len(sys.argv) > 2 else "worker-run"
        path = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1]
        report(worker_run, path)
    except Exception as e:
        print(f"churn · unavailable: {e}")


if __name__ == "__main__":
    main()
