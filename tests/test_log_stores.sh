#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/log_stores.py, bin/log-sweep and `system-doctor logstores` on a temp tree: the registry's validation, units
# and their age, each criterion with and without slack, the du fallback (covered, ignored, nested roots, residuals,
# growth), log-sweep --dry-run removing nothing, the real sweep (held-open skip, parent pruning, tail truncation, its
# capped record), and the collector plus judge (broken cleaner, failed sweep, unregistered store, growth, blindness).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
WORK=$(cd -P "$WORK" && pwd)
TMPW=$(mktemp -d /private/tmp/test-log-stores.XXXXXX)
trap 'rm -rf "$WORK" "$TMPW"' EXIT
mkdir -p "$WORK/home" "$WORK/bin" "$WORK/state"
export HOME="$WORK/home" LOG_SWEEP_DIR="$WORK/sweep" LOG_STORES_REGISTRY="$WORK/registry.json" TMPDIR="$WORK/tmpdir"
export SYSTEM_DOCTOR_DIR="$WORK/state" DOCTORS_DIR="$WORK/doctors" SYSTEM_DOCTOR_LEDGER="$WORK/ledger.json"
export LOG_SWEEP_LSOF="$WORK/bin/lsof" SYSTEM_DOCTOR_DU="$WORK/bin/du" SYSTEM_DOCTOR_LOG_SWEEP="$ROOT/bin/log-sweep"
printf '{"owner": "System doctor", "rows": [], "blind_spots": []}\n' >"$SYSTEM_DOCTOR_LEDGER"
printf '#!/bin/bash\ncat "%s/open-paths" 2>/dev/null\n' "$WORK" >"$WORK/bin/lsof"
printf '#!/bin/bash\nawk -F"\\t" -v top="${@: -1}" '"'"'$2 == top || index($2, top "/") == 1'"'"' "%s/du-lines"\n' "$WORK" >"$WORK/bin/du"
chmod +x "$WORK/bin/lsof" "$WORK/bin/du"

python3 - "$ROOT" "$WORK" "$TMPW" <<'PY'
import importlib.machinery
import importlib.util
import json
import os
import socket
import subprocess
import sys
import time

root, work, tmpw = sys.argv[1], sys.argv[2], sys.argv[3]
home = os.path.join(work, "home")
sys.path.insert(0, os.path.join(root, "share"))
import log_stores as ls  # noqa: E402

asserts = 0
now = time.time()
DAY = 86400


def check(ok, what):
    global asserts
    asserts += 1
    if not ok:
        print("FAIL: assert %d: %s" % (asserts, what))
        sys.exit(1)


def put(rel, size=10, age_days=0, text=None):
    path = os.path.join(home, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(text if text is not None else b"x" * size)
    at = now - age_days * DAY
    os.utime(path, (at, at))
    return path


def age(rel, age_days):
    at = now - age_days * DAY
    os.utime(os.path.join(home, rel), (at, at))


def registry(stores, ignore=(), scan=None):
    stores = [dict({"kind": "log", "readers": ["r"]}, **s) for s in stores]
    value = {"stores": stores, "ignore": list(ignore), "scan": scan or {}}
    with open(os.environ["LOG_STORES_REGISTRY"], "w") as handle:
        json.dump(value, handle)
    return value


def raises(value):
    with open(os.path.join(work, "bad.json"), "w") as handle:
        json.dump(value, handle)
    try:
        ls.load(os.path.join(work, "bad.json"))
    except ValueError as error:
        return str(error)
    return None


# ---- registry validation
real = ls.load(os.path.join(root, "share", "log-stores.json"))
check(len(real["stores"]) >= 30 and all(e.get("why") for e in real["stores"]), "the shipped registry loads, each store says why")
check("needs exactly one" in (raises({"stores": [{"name": "a", "globs": ["~/a"], "cleaner": "sweep"}]}) or ""),
      "a sweep store without a criterion is refused")
check(raises({"stores": [{"name": "a", "globs": ["~/a"], "cleaner": "self", "days": 1, "max_mb": 2}]}),
      "two criteria are refused")
check(raises({"stores": [{"name": "a", "globs": ["~/a"], "cleaner": "keep"}, {"name": "a", "globs": ["~/b"], "cleaner": "keep"}]}),
      "a repeated name is refused")
check(raises({"stores": [], "ignore": [{"glob": "~/x"}]}), "an ignore entry without a reason is refused")
check(raises({"stores": [{"name": "a", "globs": ["~/a"], "cleaner": "trash"}]}), "an unknown cleaner is refused")
check(raises({"stores": [{"name": "a", "globs": ["~/a"], "cleaner": "cap", "kind": "app"}]}) is None,
      "a cap store needs no criterion, an app store no readers")
check("needs a kind" in (raises({"stores": [{"name": "a", "globs": ["~/a"], "cleaner": "cap"}]}) or ""),
      "a store without a kind is refused")
check("needs readers" in (raises({"stores": [{"name": "a", "globs": ["~/a"], "cleaner": "cap", "kind": "log"}]}) or "")
      and raises({"stores": [{"name": "a", "globs": ["~/a"], "cleaner": "cap", "kind": "log", "readers": []}]}) is None,
      "a log store lists its readers, [] allowed")
check(all(isinstance(e.get("readers"), list) for e in real["stores"] if e["kind"] == "log")
      and {e["name"] for e in real["stores"] if e["kind"] == "app"} >= {"claude-desktop", "gemini-web-profiles", "transcriptions-gpt"},
      "the shipped registry names readers for every log store and keeps app data apart")
check(ls.expand("$TMPDIR/x") == os.path.join(work, "tmpdir", "x") and ls.expand("~/a/") == os.path.join(home, "a"),
      "~ and $TMPDIR expand")

# ---- units, age and criteria
put("logs/s1/old.txt", 100, 70)
put("logs/s1/new.txt", 100, 1)
age("logs/s1", 70)
put("logs/s2/a.txt", 100, 61)
age("logs/s2", 61)
put("logs/s3/a.txt", 100, 63)
age("logs/s3", 63)
put("logs/keep/a.txt", 100, 300)
put("logs/top.jsonl", 100, 90)
entry = {"name": "s", "globs": ["~/logs/*"], "exclude": ["*/keep", "*.jsonl"], "cleaner": "sweep", "days": 60}
rows = {os.path.basename(r["path"]): r for r in ls.measure(entry)}
check(sorted(rows) == ["s1", "s2", "s3"], "exclude drops units by pattern: %s" % sorted(rows))
check([os.path.basename(r["path"]) for r in ls.measure({"name": "f", "globs": ["~/logs/*"], "type": "file", "cleaner": "keep"})]
      == ["top.jsonl"], "type file keeps the loose files beside the directories")
os.symlink(os.path.join(home, "logs", "s1"), os.path.join(home, "logs", "link"))
check(sorted(os.path.basename(r["path"]) for r in ls.measure({"name": "d", "globs": ["~/logs/*"], "type": "dir", "cleaner": "keep"}))
      == ["keep", "s1", "s2", "s3"], "type dir keeps directories, never a loose file or a symlink")
os.remove(os.path.join(home, "logs", "link"))
os.makedirs(os.path.join(tmpw, "bridge"))
bridge = socket.socket(socket.AF_UNIX)
bridge.bind(os.path.join(tmpw, "bridge", "1.sock"))
os.mkfifo(os.path.join(tmpw, "bridge", "fifo"))
os.symlink(os.path.join(home, "logs", "top.jsonl"), os.path.join(tmpw, "bridge", "link"))
with open(os.path.join(tmpw, "bridge", "loose.txt"), "w") as handle:
    handle.write("x")
check([os.path.basename(r["path"]) for r in ls.measure({"name": "f", "globs": [tmpw + "/bridge/*"], "type": "file", "cleaner": "keep"})]
      == ["loose.txt"], "type file keeps regular files only, never a socket, FIFO or symlink")
check(sorted(os.path.basename(r["path"]) for r in ls.measure({"name": "a", "globs": [tmpw + "/bridge/*"], "cleaner": "keep"}))
      == ["link", "loose.txt"], "no store takes a socket or FIFO as a unit")
check(rows["s1"]["files"] == 2 and rows["s1"]["newest"] >= now - DAY - 5 and rows["s1"]["bytes"] > 0,
      "a directory unit ages by the newest mtime inside it")
gone = sorted(os.path.basename(r["path"]) for r, action in ls.doomed(entry, list(rows.values()), now))
check(gone == ["s2", "s3"], "days 60 removes units untouched 60+ days: %s" % gone)
over = sorted(os.path.basename(r["path"]) for r, _a in ls.doomed(entry, list(rows.values()), now, slack=True))
check(over == ["s3"], "with 2 days of slack only the 63-day unit is past: %s" % over)
summary = ls.summary(entry, list(rows.values()), now)
check(summary["units"] == 3 and summary["over_units"] == 1 and summary["over_oldest_s"] <= now - 63 * DAY + 5,
      "the summary counts what lies past criterion plus slack: %s" % summary)
check(ls.outermost(["/a/b", "/a", "/c/d", "/c/de"]) == ["/a", "/c/d", "/c/de"], "nested matches fold into the outer one")

for i in range(5):
    put("vers/v%d" % i, 2 << 20, 10 - i)
keep = {"name": "v", "globs": ["~/vers/*"], "cleaner": "self", "keep_newest": 2}
vrows = ls.measure(keep)
check(sorted(os.path.basename(r["path"]) for r, _a in ls.doomed(keep, vrows, now)) == ["v0", "v1", "v2"],
      "keep_newest 2 removes all but the two newest")
check(len(ls.doomed(keep, vrows, now, slack=True)) == 2, "slack keeps one more")
cap = {"name": "v", "globs": ["~/vers/*"], "cleaner": "sweep", "max_mb": 5}
check(sorted(os.path.basename(r["path"]) for r, _a in ls.doomed(cap, vrows, now)) == ["v0", "v1", "v2"],
      "max_mb 5 keeps the newest within 5 MB, oldest go first")
check(sorted(os.path.basename(r["path"]) for r, _a in ls.doomed(cap, vrows, now, slack=True)) == ["v0", "v1"],
      "max_mb slack is 25%: 6.25 MB holds a third 2 MB unit")
put("app/big.log", text=b"".join(b"line %06d\n" % i for i in range(300000)))
put("app/small.log", 100)
tail = {"name": "t", "globs": ["~/app/*.log"], "cleaner": "sweep", "tail_mb": 1}
trows = ls.measure(tail)
check([(os.path.basename(r["path"]), a) for r, a in ls.doomed(tail, trows, now)] == [("big.log", "truncate")],
      "tail_mb truncates only files over the tail")
check(len(ls.doomed(tail, trows, now, slack=True)) == 1, "a 3.6 MB file is past twice its 1 MB tail")
check(ls.doomed(dict(tail, tail_mb=2), trows, now, slack=True) == [], "under twice its tail it is within the slack")

# ---- du fallback
K = 1024
H = home
sizes = {H: 5000 * K, H + "/a": 300 * K, H + "/b": 500 * K, H + "/b/x": 400 * K, H + "/c": 900 * K,
         H + "/.cache": 600 * K, H + "/.cache/d": 250 * K, H + "/L": 2000 * K, H + "/L/Other": 300 * K,
         H + "/L/Caches": 1000 * K, H + "/L/Caches/pkg": 600 * K, H + "/L/Caches/app": 300 * K,
         H + "/e": 100 * K, H + "/f": 450 * K, H + "/f/g": 300 * K, H + "/h": 50 * K, H + "/h/i": 40 * K,
         H + "/h/i/j": 30 * K, H + "/h/i/j/k": 25 * K}
roots = [H, H + "/.cache", H + "/L/Caches"]
claims = {H + "/b/x": 400 * K * K}
ignores = [H + "/c", H + "/L", H + "/L/Caches/pkg"]
_reported, old = ls.unregistered(sizes, roots, 3, claims, ignores, 200 * K, 50 * K, 10 * K)
old[H + "/e"] = [30 * K, 30 * K]
reported, scan = ls.unregistered(sizes, roots, 3, claims, ignores, 200 * K, 50 * K, 10 * K, old, 1.0)
names = {r["path"][len(H):]: r for r in reported}
check(set(names) == {"/a", "/.cache/d", "/.cache/*", "/L/Caches/app", "/e", "/f/g"},
      "reported: an uncovered 300 MB dir, one under a nested root, one under an ignored parent's own root, a growing one, "
      "the deepest big one, a root's 350 MB of loose files: %s" % sorted(names))
check(names["/e"]["grow_kb_day"] == 70 * K and names["/e"]["residual_kb"] == 100 * K,
      "growth is the residual's change a day against the previous scan")
check(H + "/f" not in [r["path"] for r in reported] and scan[H + "/f"] == [450 * K, 150 * K],
      "a reported child's residual leaves its parent, never counted twice")
check(scan[H + "/b"] == [500 * K, 100 * K] and H + "/b/x" not in scan, "a store unit covers its dir and leaves the parent")
check(H + "/c" not in scan and H + "/L/Other" not in scan and H + "/L/Caches/pkg" not in scan,
      "ignored dirs are neither reported nor kept, an ignore inside a nested root too")
check(H + "/.cache" not in scan and H + "/L/Caches" not in scan, "roots themselves are never judged")
check(H + "/h/i/j/k" not in scan and H + "/h/i/j" in scan, "only 1..depth levels below a root are judged")
reported, _scan = ls.unregistered(sizes, roots, 3, claims, ignores, 200 * K, 50 * K, 10 * K)
check(H + "/e" not in [r["path"] for r in reported], "with no earlier scan a small dir is not reported")
check(ls.du_plan([H, H + "/L/Caches", "/t"], 3) == [(H, 5), ("/t", 3)], "one du per top root, deep enough for nested roots")
put("appbin/tool-1", 8192)
os.makedirs(os.path.join(home, "appbin", "cache"), exist_ok=True)
apps = ls.app_claims({"stores": [{"name": "b", "kind": "app", "globs": ["~/appbin/*"], "cleaner": "keep"},
                                 {"name": "l", "kind": "log", "readers": [], "globs": ["~/logs/*"], "cleaner": "keep"}]},
                     {H + "/appbin/cache": 700})
check(apps == {H + "/appbin/tool-1": os.lstat(H + "/appbin/tool-1").st_blocks * 512, H + "/appbin/cache": 700 * K},
      "app units are claimed, log units not: a file du never lists by its own size, a listed dir by du's: %s" % apps)
R = "/r"
loose, _scan = ls.unregistered({R: 500 * K, R + "/d": 100 * K, R + "/d/e": 60 * K}, [R], 3, {R + "/f.log": 50 * K * K, R + "/d/x": 9 * K * K},
                               [], 200 * K, 50 * K, 10 * K)
check([(r["path"], r["residual_kb"]) for r in loose] == [(R + "/*", 350 * K)],
      "a root's loose files are judged as <root>/*: its size minus its dirs and claimed files: %s" % loose)
small, scan = ls.unregistered({R: 500 * K, R + "/d": 400 * K}, [R], 3, {R + "/d": 400 * K * K}, [], 200 * K, 50 * K, 10 * K)
grown, _scan = ls.unregistered({R: 500 * K, R + "/d": 400 * K}, [R], 3, {R + "/d": 400 * K * K}, [], 200 * K, 50 * K, 10 * K,
                               {R + "/*": [40 * K, 40 * K]}, 1.0)
check(small == [] and scan[R + "/*"] == [100 * K, 100 * K] and [r["grow_kb_day"] for r in grown] == [60 * K],
      "loose files under min_mb stay unreported, kept for the next scan, and reported when they grow")
check(ls.parse_du("12\t/a/b/\nbad\n7\t/c\n") == {"/a/b": 12, "/c": 7}, "du lines parse")

# ---- log-sweep: dry run, then the real sweep
registry([{"name": "s", "globs": ["~/logs/*"], "exclude": ["*/keep", "*.jsonl"], "cleaner": "sweep", "days": 60},
          {"name": "deep", "globs": ["~/deep/*/*/*"], "cleaner": "sweep", "days": 14},
          {"name": "t", "globs": ["~/app/*.log"], "cleaner": "sweep", "tail_mb": 1},
          {"name": "v", "globs": ["~/vers/*"], "cleaner": "self", "keep_newest": 2}])
put("deep/p1/kind/old.jsonl", 100, 20)
put("deep/p2/kind/new.jsonl", 100, 1)
put("deep/p2/kind/old.jsonl", 100, 20)
with open(os.path.join(work, "open-paths"), "w") as handle:
    handle.write("p1234\nn%s/logs/s3/a.txt\n" % home)
before = sorted(os.path.relpath(os.path.join(d, f), home) for d, _s, fs in os.walk(home) for f in fs)
dry = subprocess.run([os.path.join(root, "bin", "log-sweep"), "--dry-run"], capture_output=True, text=True)
after = sorted(os.path.relpath(os.path.join(d, f), home) for d, _s, fs in os.walk(home) for f in fs)
check(dry.returncode == 0 and before == after, "--dry-run removes nothing: %s" % dry.stderr)
check("delete" in dry.stdout and "/logs/s2" in dry.stdout and "/deep/p1/kind/old.jsonl" in dry.stdout
      and "truncate" in dry.stdout and "MB" in dry.stdout and "/vers/" not in dry.stdout,
      "--dry-run lists each removal with its size, sweep stores only: %s" % dry.stdout)
check("/logs/s3" not in dry.stdout and "1 held open" in dry.stdout, "a dir some process holds open is skipped")
check(not os.path.exists(os.path.join(work, "sweep", "sweeps.jsonl")), "a dry run records nothing")
real_run = subprocess.run([os.path.join(root, "bin", "log-sweep"), "--json"], capture_output=True, text=True)
result = json.loads(real_run.stdout)
check(real_run.returncode == 0 and result["units"] == 4 and result["skipped_open"] == 1 and result["errors"] == 0,
      "the sweep removes s2 and two old deep files and truncates big.log: %s" % result)
check(not os.path.exists(os.path.join(home, "logs/s2")) and os.path.exists(os.path.join(home, "logs/s3"))
      and os.path.exists(os.path.join(home, "logs/s1")) and os.path.exists(os.path.join(home, "logs/keep")),
      "only what the criterion names is gone")
check(not os.path.exists(os.path.join(home, "deep/p1")) and os.path.exists(os.path.join(home, "deep/p2/kind/new.jsonl"))
      and os.path.isdir(os.path.join(home, "deep")), "emptied parents up to the glob's fixed base go, the base stays")
big = open(os.path.join(home, "app/big.log"), "rb").read()
check(len(big) <= 1 << 20 and big.startswith(b"line ") and big.endswith(b"line 299999\n"),
      "truncation keeps the last MB from a line start")
check(os.path.getsize(os.path.join(home, "app/small.log")) == 100, "a file under its tail is untouched")
check(len(os.listdir(os.path.join(home, "vers"))) == 5, "a self store is never swept")
record = open(os.path.join(work, "sweep", "sweeps.jsonl")).read().splitlines()
check(len(record) == 1 and json.loads(record[0])["units"] == 4, "one summary line per real run")
loader = importlib.machinery.SourceFileLoader("log_sweep", os.path.join(root, "bin", "log-sweep"))
spec = importlib.util.spec_from_loader("log_sweep", loader)
sweep_mod = importlib.util.module_from_spec(spec)
loader.exec_module(sweep_mod)
sweep_mod.RECORD_MAX_BYTES = 2000
for i in range(40):
    sweep_mod.record({"t": i, "pad": "x" * 100})
text = open(os.path.join(work, "sweep", "sweeps.jsonl")).read()
check(len(text) <= 2000 and '"t":39' in text and '"units":4' not in text, "the record is capped, oldest lines go first")
check(home.startswith("/private/var/"), "the suite's home is a /private/var realpath: %s" % home)
for rel in ("bridge/1.sock", "bridge/fifo", "bridge/link", "bridge/loose.txt"):
    os.utime(os.path.join(tmpw, rel), (now - 20 * DAY, now - 20 * DAY), follow_symlinks=False)
for rel in ("vheld/d1/a.txt", "vheld/d2/a.txt"):
    put(rel, 100, 20)
for rel in ("vheld/d1", "vheld/d2"):
    age(rel, 20)
os.makedirs(os.path.join(tmpw, "sheld", "d1"))
for rel in ("sheld/old.log", "sheld/free.log", "sheld/d1/a.txt", "sheld/d1"):
    path = os.path.join(tmpw, rel)
    if not os.path.isdir(path):
        open(path, "w").close()
    os.utime(path, (now - 20 * DAY, now - 20 * DAY))
registry([{"name": "bridge", "globs": [tmpw + "/bridge/*"], "type": "file", "cleaner": "sweep", "days": 7},
          {"name": "vheld", "globs": [home[len("/private"):] + "/vheld/*"], "cleaner": "sweep", "days": 7},
          {"name": "sheld", "globs": [tmpw + "/sheld/*"], "cleaner": "sweep", "days": 7}])
alias = tmpw[len("/private"):]
with open(os.path.join(work, "open-paths"), "w") as handle:
    handle.write("p1\nn%s/vheld/d1/a.txt\nn%s/sheld/old.log\nn%s/sheld/d1/a.txt\nn%s/bridge/1.sock\n" % (home, alias, alias, alias))
dry = subprocess.run([os.path.join(root, "bin", "log-sweep"), "--dry-run"], capture_output=True, text=True)
check("bridge/loose.txt" in dry.stdout and "1.sock" not in dry.stdout and "fifo" not in dry.stdout and "/link" not in dry.stdout,
      "the dry run lists the old regular file, never the socket, FIFO or symlink: %s" % dry.stdout)
held_run = json.loads(subprocess.run([os.path.join(root, "bin", "log-sweep"), "--json"], capture_output=True, text=True).stdout)
check(sorted(os.listdir(os.path.join(tmpw, "bridge"))) == ["1.sock", "fifo", "link"] and os.path.exists(os.path.join(home, "logs/top.jsonl")),
      "the sweep never deletes a socket, a FIFO or a symlink's target")
check(os.path.exists(os.path.join(home, "vheld/d1")) and not os.path.exists(os.path.join(home, "vheld/d2")),
      "a /var/... unit is held by lsof's /private/var/... spelling")
check(sorted(os.listdir(os.path.join(tmpw, "sheld"))) == ["d1", "old.log"] and held_run["skipped_open"] == 3,
      "a /private/tmp/... file or dir is held by lsof's /tmp/... spelling: %s" % held_run)

# ---- system-doctor logstores collector and judge
loader = importlib.machinery.SourceFileLoader("system_doctor", os.path.join(root, "bin", "system-doctor"))
spec = importlib.util.spec_from_loader("system_doctor", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
put("cache/stray/blob", 10)
put("ignored/blob", 10)
put("logs/s4/a.txt", 100, 80)
age("logs/s4", 80)
registry([{"name": "s", "globs": ["~/logs/*"], "exclude": ["*/keep", "*.jsonl"], "cleaner": "self", "days": 60,
           "writer": "worker-run", "owner": "own"},
          {"name": "v", "globs": ["~/vers/*"], "cleaner": "self", "keep_newest": 2, "writer": "Vendor", "owner": "third-party"},
          {"name": "u", "globs": ["~/unread/*"], "cleaner": "sweep", "days": 7, "readers": [], "writer": "Vendor"},
          {"name": "uk", "globs": ["~/kept/*"], "cleaner": "keep", "readers": [], "writer": "Vendor"},
          {"name": "a", "kind": "app", "globs": ["~/appdata/*"], "cleaner": "keep"}],
         ignore=[{"glob": "~/ignored", "why": "test"}],
         scan={"roots": ["~", "~/cache"], "depth": 3, "min_mb": 200, "grow_mb_day": 50, "floor_mb": 10, "budget_s": 60})
put("unread/trace.jsonl", 100, 1)
put("kept/trace.jsonl", 100, 1)
put("appdata/vm/disk.img", 5000)
with open(os.path.join(work, "du-lines"), "w") as handle:
    handle.write("".join("%d\t%s\n" % (kb, path) for path, kb in (
        (home + "/cache/stray", 300 * K), (home + "/cache", 300 * K), (home + "/ignored", 900 * K),
        (home + "/appdata/vm", 400 * K), (home + "/appdata", 400 * K), (home + "/logs", 1 * K), (home, 1700 * K))))
row = m.logstores(now)
stores = {s["name"]: s for s in row["stores"]}
check(row.get("sweep", {}).get("errors") == 0 and stores["s"]["over_units"] == 2 and stores["v"]["over_units"] == 2,
      "the collector sweeps, then measures every store: %s" % row)
check(row["unread"] == ["u", "uk"], "the row lists every unread store, bounded or not: %s" % row.get("unread"))
check(set(stores) == {"s", "v", "u", "uk"} and row["total_bytes"] == sum(s["bytes"] for s in stores.values()),
      "an app store is neither measured nor counted in the total: %s" % sorted(stores))
check([u["path"] for u in row["unregistered"]] == ["~/cache/stray"] and row["scan"]["cut"] == [],
      "the fallback names the uncovered 300 MB dir as ~/…, never the ignored one or an app store's: %s" % row["unregistered"])
check(os.path.exists(os.path.join(work, "state", "logscan", m.local_day(now) + ".json")), "the scan is kept for growth")
later = now + 1
judge = m.Judge(later, None)
logs = m.tick_rows(now - 9 * DAY, later, "logstores")
m.judge_logstores(judge, logs)
found = {p["id"]: p for p in judge.problems}
check(set(found) == {"log-store:s", "log-store:v", "log-unread:uk", "unregistered-store:~/cache/stray"},
      "problems: %s" % sorted(found))
check("read by nobody and never deleted" in found["log-unread:uk"]["fact"] and found["log-unread:uk"]["cause"] is None,
      "a log no one reads and nothing deletes is its own problem, a swept one is not: %s" % found["log-unread:uk"])
check(found["log-store:s"]["cause"]["name"] == "worker-run" and found["log-store:s"]["cause"]["owner"] == "own"
      and "60 days" in found["log-store:s"]["fact"], "a broken self cleaner names its writer: %s" % found["log-store:s"])
check(found["log-store:v"]["cause"]["fix_target"] is False and "newest 2" in found["log-store:v"]["fact"],
      "a third-party cleaner is report-only")
check(found["unregistered-store:~/cache/stray"]["cause"] is None, "an unregistered store names no cause, its path is the key")
failed = dict(logs[-1], sweep={"error": "exit 1: registry: boom"}, stores=[], unregistered=[])
judge = m.Judge(now, None)
m.judge_logstores(judge, [failed])
check([p["id"] for p in judge.problems] == ["log-store:log-sweep"] and judge.problems[0]["cause"]["name"] == "log-sweep",
      "a failed sweep is a broken cleaner, log-sweep its cause")
series = [{"t": now - (7 - d) * DAY, "stores": [], "total_bytes": int((100 + 1.2 * d) * m.GIB)} for d in range(8)]
one, seven = m.log_growth(series)
check(round(one, 2) == 1.2 and round(seven, 2) == 1.2, "growth over 1 and 7 days: %s %s" % (one, seven))
judge = m.Judge(now, None)
m.judge_logstores(judge, series)
check([p["id"] for p in judge.problems] == ["log-growth:total"] and judge.problems[0]["severity"] == "review",
      "1.2 GiB/day over 7 days, still growing, fires log-growth")
flat = series[:-1] + [dict(series[-1], total_bytes=series[-2]["total_bytes"])]
judge = m.Judge(now, None)
m.judge_logstores(judge, flat)
check(judge.problems == [], "a total that stopped growing in the last day does not fire")
judge = m.Judge(now, None)
m.judge_logstores(judge, series[3:])
check(judge.problems == [] and m.log_growth(series[3:])[1] is None, "under 5 days of series nothing fires")
ticks = [{"t": now - 2 * DAY}]
judge = m.Judge(now, None)
m.judge_collectors(judge, ticks, [], [], [], [])
check("logstores" in judge.blind, "no scan for 36 h while the doctor ran is blind")
judge = m.Judge(now, None)
m.judge_collectors(judge, ticks, [], [], [], [dict(logs[-1], scan={"cut": ["~"]})])
check("logstores" in judge.blind, "a cut du is blind")
judge = m.Judge(now, None)
m.judge_collectors(judge, ticks, [], [], [], logs)
check("logstores" not in judge.blind, "a fresh full scan sees")
check(m.logstores_due(None, now) and not m.logstores_due(now - 3600, now) and m.logstores_due(now - 37 * 3600, now),
      "the scan is due once a day after the nightly hour, or after 36 h")
view = m.logstores_view(logs)
check(view["stores"][0][0] in ("s", "v") and view["unregistered"][0]["path"] == "~/cache/stray", "the document's log_stores view")
check(m.proof("worker-run", "log-store", now - 10, now + 1)["verdict"] == "refused"
      and m.proof("Other", "log-store", now - 10, now + 1)["verdict"] == "proven"
      and m.proof("worker-run", "log-store", now + 5, now + 6)["verdict"] == "pending",
      "a log-store fix is proven by the next scan no longer firing it")
print("OK: PASS: %d log store checks" % asserts)
PY
