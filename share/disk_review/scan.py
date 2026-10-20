#!/usr/bin/env python3
"""Disk review scan (docs/disk-review.md): du maps of the system disk and Work, every file over 200 MB, each app's
last use. The walk runs inside Hammerspoon, which holds Full Disk Access, so TCC folders (Chrome, Telegram, Mail…)
are sized too; without it the walk runs here and those folders read as missing.

  scan.py run              start the walk in the background, return at once
  scan.py wait [seconds]   block until the walk lands (exit 1 on timeout)
  scan.py kids PATH [-n N] [--min-mb MB]   children of PATH by size
  scan.py top REGEX [--min-mb MB]          topmost directories whose path matches REGEX
  scan.py size PATH...                     GB of each path, from the maps (a file: its own size)
  scan.py apps                             apps by size with last use
"""
import argparse
import os
import re
import shlex
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
DIR = os.path.join(os.environ.get("DISK_REVIEW_DIR") or os.path.join(HOME, ".cache", "disk-review"), "scan")
DATA = "/System/Volumes/Data"
WORK = os.environ.get("DISK_REVIEW_WORK", "/Volumes/Work")
MAPS = {"mac": "mac.du", "work": "work.du"}
GIB = 1048576  # du -k units per GiB


def walk_script():
    q = shlex.quote
    out = q(DIR)
    roots = " ".join(q(r) for r in (DATA + "/Users", DATA + "/Applications", DATA + "/private/tmp", WORK) if os.path.isdir(r))
    return f"""#!/bin/bash
cd {out} || exit 1
rm -f done
du -xk {q(DATA)} > mac.du.part 2>/dev/null; mv -f mac.du.part mac.du
[ -d {q(WORK)} ] && {{ du -xk {q(WORK)} > work.du.part 2>/dev/null; mv -f work.du.part work.du; }}
find {roots} -xdev -type f -size +200M -exec stat -f '%z%t%Sm%t%N' -t %F {{}} + > big.tsv.part 2>/dev/null
mv -f big.tsv.part big.tsv
date +%s > done
"""


def apps():
    rows = []
    for base in ("/Applications", "/Applications/Utilities", HOME + "/Applications"):
        try:
            names = os.listdir(base)
        except OSError:
            continue
        for name in names:
            if not name.endswith(".app"):
                continue
            path = os.path.join(base, name)
            r = subprocess.run(["mdls", "-raw", "-name", "kMDItemLastUsedDate", path], capture_output=True, text=True)
            used = r.stdout.strip()[:10] if r.returncode == 0 and r.stdout.strip() not in ("", "(null)") else "never"
            rows.append(f"{used}\t{path}")
    return rows


def run():
    os.makedirs(DIR, exist_ok=True)
    script = os.path.join(DIR, "walk.sh")
    with open(script, "w") as f:
        f.write(walk_script())
    os.chmod(script, 0o755)
    with open(os.path.join(DIR, "apps.tsv"), "w") as f:
        f.write("\n".join(apps()) + "\n")
    # A global keeps the hs.task alive for the whole walk; a collected task object stops its process.
    lua = f"_G.__diskReviewScan = hs.task.new('/bin/bash', nil, {{'{script}'}}); _G.__diskReviewScan:start()"
    try:
        hs = subprocess.run(["hs", "-t", "8", "-c", lua], capture_output=True, text=True, timeout=12)
        via = "hammerspoon" if hs.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        via = None
    if not via:
        subprocess.Popen(["/bin/bash", script], start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        via = "this shell (no Full Disk Access: TCC folders read as missing)"
    print(f"scan started via {via}; `scan.py wait` blocks until {DIR}/done")


def wait(seconds):
    done, start = os.path.join(DIR, "done"), time.time()
    while time.time() - start < seconds:
        if os.path.exists(done):
            print("scan done")
            return 0
        time.sleep(5)
    print("scan still running", file=sys.stderr)
    return 1


def norm(path):
    return path[len(DATA):] or "/" if path.startswith(DATA + "/") or path == DATA else path


_maps = {}


def load(group):
    if group not in _maps:
        sizes = {}
        try:
            with open(os.path.join(DIR, MAPS[group]), errors="replace") as f:
                for line in f:
                    k, _, p = line.rstrip("\n").partition("\t")
                    if k.isdigit():
                        sizes[norm(p)] = int(k)
        except OSError:
            pass
        _maps[group] = sizes
    return _maps[group]


def group_of(path):
    return "work" if path == WORK or path.startswith(WORK + "/") else "mac"


def size_kb(path):
    path = norm(os.path.abspath(os.path.expanduser(path)))
    hit = load(group_of(path)).get(path)
    if hit is not None:
        return hit
    try:
        st = os.lstat(path)
        if not os.path.isdir(path):
            return st.st_blocks // 2
    except OSError:
        return 0
    r = subprocess.run(["du", "-sk", path], capture_output=True, text=True)
    return int(r.stdout.split("\t")[0]) if r.stdout else 0


def kids(path, n, min_kb):
    path = norm(os.path.abspath(os.path.expanduser(path))).rstrip("/")
    pre, sizes = path + "/", load(group_of(path))
    out = sorted(((v, q) for q, v in sizes.items() if q.startswith(pre) and "/" not in q[len(pre):] and v >= min_kb),
                 reverse=True)
    return out[:n]


def top(regex, min_kb):
    rx = re.compile(regex)
    found = []
    for group in MAPS:
        hits = sorted((p, v) for p, v in load(group).items() if v >= min_kb and rx.search(p))
        for p, v in hits:
            if not any(p.startswith(t + "/") for t, _ in found):
                found.append((p, v))
    return sorted(((v, p) for p, v in found), reverse=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["run", "wait", "kids", "top", "size", "apps"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("-n", type=int, default=15)
    ap.add_argument("--min-mb", type=float, default=100)
    a = ap.parse_args()
    min_kb = int(a.min_mb * 1024)
    if a.cmd == "run":
        return run()
    if a.cmd == "wait":
        return wait(float(a.args[0]) if a.args else 1800)
    if a.cmd == "kids":
        for v, p in kids(a.args[0], a.n, min_kb):
            print(f"{v / GIB:7.2f}\t{p}")
    elif a.cmd == "top":
        for v, p in top(a.args[0], min_kb)[:a.n * 4]:
            print(f"{v / GIB:7.2f}\t{p}")
    elif a.cmd == "size":
        for p in a.args:
            print(f"{size_kb(p) / GIB:7.2f}\t{p}")
    elif a.cmd == "apps":
        try:
            rows = [l.rstrip("\n").split("\t", 1) for l in open(os.path.join(DIR, "apps.tsv")) if "\t" in l]
        except OSError:
            rows = []
        for used, p in sorted(rows, key=lambda r: -size_kb(r[1])):
            print(f"{size_kb(p) / GIB:7.2f}\t{used}\t{p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
