#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/system-doctor over fixture probes: the tick's counters and its attribution of births and reaped-child CPU to
# own parent scripts, the nightly pass over a fixture DiagnosticReports dir and `last`, every problem rule at its
# limit and just under it, the ledger, the envelope, install-agent into a fixture HOME and doctor-fix's refusal.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
WORK=$(cd -P "$WORK" && pwd)
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fix"
mkdir -p "$FIX" "$WORK/home" "$WORK/own/bin" "$WORK/diag" "$WORK/agents" "$WORK/caches/.cache/uv" "$WORK/bin"
export HOME="$WORK/home" SYSTEM_DOCTOR_DIR="$WORK/state" DOCTORS_DIR="$WORK/doctors" SYSTEM_DOCTOR_FIX="$FIX"
export SYSTEM_DOCTOR_LEDGER="$WORK/ledger.json" SYSTEM_DOCTOR_OWN_ROOTS="$WORK/own/" SYSTEM_DOCTOR_WINDOW_S=0
export SYSTEM_DOCTOR_DIAG_DIRS="$WORK/diag" SYSTEM_DOCTOR_AGENTS_DIRS="$WORK/agents"
export SYSTEM_DOCTOR_CACHE_ROOTS="$WORK/caches/.cache" SYSTEM_DOCTOR_CACHE_DIRS= SYSTEM_DOCTOR_HOST_TICKS="$FIX/host"
export SYSTEM_DOCTOR_LIBEXEC_DIR="$HOME/.local/libexec" SYSTEM_DOCTOR_AGENT_DIR="$HOME/Library/LaunchAgents"
export SYSTEM_DOCTOR_RUSAGE="$FIX/rusage.json" SYSTEM_DOCTOR_PROCS="$FIX/procs.json" WORKER_RUN_DIR="$WORK/runs"
export SSD_SAMPLER_DIR="$WORK/ssd" SSD_SAMPLER_PLIST="$WORK/ssd-sampler.plist"
printf '{"owner": "System doctor", "rows": [], "blind_spots": []}\n' >"$SYSTEM_DOCTOR_LEDGER"
mkdir -p "$WORK/repos/llm-legs/bin" "$WORK/repos/hammerspoon"
for name in statusline.sh memlogd vendor-fingerprint worker-run ssd-sampler; do printf '#!/bin/bash\n' >"$WORK/repos/llm-legs/bin/$name"; done
printf -- '--\n' >"$WORK/repos/hammerspoon/init.lua"
git -C "$WORK/repos/llm-legs" init -q && git -C "$WORK/repos/hammerspoon" init -q
printf '%s\n' "$WORK/repos/llm-legs" "$WORK/repos/hammerspoon" >"$WORK/sweep-repos"
export NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" SYSTEM_DOCTOR_REPOS_DIR="$WORK/repos"
for name in ps vm_stat sysctl ioreg df last diskutil launchctl log; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$SYSTEM_DOCTOR_FIX/%s.calls"\ncase " $* " in *" -S "*) cat "$SYSTEM_DOCTOR_FIX/%s-children" ;; *) cat "$SYSTEM_DOCTOR_FIX/%s" 2>/dev/null ;; esac\n' \
    "$name" "$name" "$name" >"$WORK/bin/$name"
  chmod +x "$WORK/bin/$name"
  export "SYSTEM_DOCTOR_$(printf %s "$name" | tr '[:lower:]' '[:upper:]')=$WORK/bin/$name"
done
cat >>"$WORK/bin/ps" <<'SH'
case " $* " in *" -S "*) printf '%5d %5d %3d %10s %6d %s %s\n' "$$" "$PPID" 501 0:00.00 1024 "Mon Oct  5 09:30:00 2026" "/bin/ps $*" ;; esac
SH
printf '#!/bin/bash\n' >"$WORK/bin/du"
printf 'printf "%%s\\t%%s\\n" 23068672 "$4/uv" 1048576 "$4/small" 24117248 "$4"\n' >>"$WORK/bin/du"
chmod +x "$WORK/bin/du"
export SYSTEM_DOCTOR_DU="$WORK/bin/du"

python3 - "$ROOT" "$WORK" <<'PY'
import concurrent.futures
import contextlib
import glob
import importlib.machinery
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time

root, work = sys.argv[1], sys.argv[2]
fix = os.path.join(work, "fix")
own = os.path.join(work, "own")
asserts = 0


def check(ok, what):
    global asserts
    asserts += 1
    if not ok:
        print("FAIL: assert %d: %s" % (asserts, what))
        sys.exit(1)


def put(name, text):
    with open(os.path.join(fix, name), "w") as handle:
        handle.write(text)


loader = importlib.machinery.SourceFileLoader("system_doctor", os.path.join(root, "bin", "system-doctor"))
spec = importlib.util.spec_from_loader("system_doctor", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)


def cli(*args, env=None):
    return subprocess.run([os.path.join(root, "bin", "system-doctor")] + list(args), capture_output=True, text=True,
                          env=dict(os.environ, **(env or {})))


check(m.LIMITS == {"spawn_s": 1000, "spawn_heavy_s": 2500, "kernel": 0.40, "kernel_heavy": 0.55, "kernel_heavy_min": 30,
                   "compressor": 0.33, "compressor_min": 10, "swap": 0.50, "ssd_gb_day": 200, "ssd_heavy_gb_day": 400,
                   "swap_writes_gib_day": 20, "free_gib": 25, "free_heavy_gib": 10, "hammerspoon_crashes": 1,
                   "job_crashes_day": 1, "unclean_reboots": 1, "log_growth_gib_day": 1.0,
                   "log_growth_heavy_gib_day": 3.0}, "the limits are the design's: %s" % m.LIMITS)

# ---- births counter: PIDs restart at 100 after 99998, the closing ps itself is not a birth
check(m.births_rate(100, 2101, 2.0) == 1000.0, "births over a 2 s window: %s" % m.births_rate(100, 2101, 2.0))
check(m.births_rate(99000, 1000, 2.0) == (1899 - 1) / 2.0,
      "births across the PID wrap, where macOS restarts at 100 after 99998: %s" % m.births_rate(99000, 1000, 2.0))
check(m.births_rate(None, 5, 2.0) is None and m.births_rate(1, 5, 0) is None, "no rate without both pids and a window")

# ---- classification of one process by its argv, kept in memory only
roots = (own + "/",)
check(m.classify("/bin/bash %s/bin/statusline.sh --x" % own, 501, roots) == ("statusline.sh", "own"), "own script under bash")
check(m.classify("/opt/homebrew/bin/python3.13 %s/bin/worker-pick" % own, 501, roots) == ("worker-pick", "own"),
      "own script under a versioned python")
check(m.classify("/bin/zsh %s/bin/snapshot-zsh-1791240132990-rulnxr.sh" % own, 501, roots) == ("snapshot-zsh-N.sh", "own"),
      "a generated script name loses its unique part")
check(m.classify("/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon -x", 501, roots) == ("Hammerspoon", "own"),
      "Hammerspoon is own")
check(m.classify("/usr/libexec/xpcproxy com.x", 0, roots) == ("xpcproxy", "apple"), "a system path is Apple's")
check(m.classify("/usr/local/bin/thing", 501, roots) == ("thing", "third-party"), "/usr/local is not Apple's")
check(m.classify("/Applications/Dia Browser.app/Contents/MacOS/Dia Browser --type=renderer", 501, roots)
      == ("Dia Browser", "third-party"), "an app bundle with a space in its name")

# ---- the light tick over fixture probes
start = "Mon Oct  5 09:00:00 2026"
born = "Mon Oct  5 09:30:00 2026"


def ps_rows(rows):
    return "".join("%5d %5d %3d %10s %6d %s %s\n" % (row[:4] + (2048,) + row[4:]) for row in rows)


base = [(1, 0, 0, "0:01.00", start, "/sbin/launchd"),
        (100, 1, 501, "0:00.50", start, "/bin/bash %s/bin/statusline.sh" % own),
        (300, 1, 501, "0:00.10", start, "/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon"),
        (400, 1, 0, "0:00.10", start, "/usr/libexec/xpcproxy")]
newborns = [(201, 100, 501, "0:00.00", born, "/opt/homebrew/bin/jq .x"),
            (202, 201, 501, "0:00.00", born, "/usr/bin/git status"),
            (203, 300, 501, "0:00.00", born, "/bin/sh -c true"),
            (204, 400, 0, "0:00.00", born, "/usr/libexec/helper")]
put("ps", ps_rows(base))
put("ps-children", ps_rows(base + newborns))
put("host", "1000 1000 8000 0\n")
put("vm_stat", "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages occupied by compressor: 393216\n"
               "Pages stored in compressor: 800000\nPageins: 1000\nSwapins: 10\nSwapouts: 100\n")
put("sysctl", "{ sec = 1790000000, usec = 0 } Mon Sep 21 10:00:00 2026\n25769803776\n"
              "total = 6144.00M  used = 4608.00M  free = 1536.00M  (encrypted)\n")


def ioreg(read, wrote, ext_read):
    return ('+-o AppleANS3NVMeController  <class IOBlockStorageDevice>\n'
            '    "Protocol Characteristics" = {"Physical Interconnect"="Apple Fabric","Physical Interconnect Location"="Internal"}\n'
            '    "Statistics" = {"Bytes (Read)"=%d,"Bytes (Write)"=%d}\n'
            '  +-o IOMedia\n      "BSD Name" = "disk0"\n'
            '+-o USB  <class IOBlockStorageDevice>\n'
            '    "Protocol Characteristics" = {"Physical Interconnect Location"="External"}\n'
            '    "Statistics" = {"Bytes (Read)"=%d,"Bytes (Write)"=7}\n'
            '  +-o IOMedia\n      "BSD Name" = "disk4"\n') % (read, wrote, ext_read)


put("ioreg", ioreg(2000, 1000, 50))
put("df", "Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on\n"
          "/dev/disk3s1 971350180 10000000 104857600 9% 1 2 1% /\n"
          "/dev/disk3s5 971350180 800000000 104857600 89% 1 2 1% /System/Volumes/Data\n"
          "/dev/disk4s1 1953514584 100 20971520 1% 1 2 1% /Volumes/Work Disk\n")
put("rusage.json", json.dumps({"100": [0, 0, 0, 0, 2.0], "300": [0, 0, 0, 0, 50.0]}))
first = cli("tick", "--quiet")
check(first.returncode == 0, "the first tick runs: %s" % first.stderr)
later = [(100, 1, 501, "0:01.50", start, "/bin/bash %s/bin/statusline.sh" % own),
         (300, 1, 501, "0:01.10", start, "/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon")] + base[3:] + base[:1]
put("ps", ps_rows(later))
put("ps-children", ps_rows(later + newborns))
# reaped children: statusline.sh's grew 2 -> 11 s; Hammerspoon's fell 50 -> 3 s, a restarted counter, so its own 1 s only
put("rusage.json", json.dumps({"100": [0, 0, 0, 0, 11.0], "300": [0, 0, 0, 0, 3.0]}))
put("host", "1500 1500 9000 0\n")
put("vm_stat", "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages occupied by compressor: 393216\n"
               "Pages stored in compressor: 800000\nPageins: 1000\nSwapins: 10\nSwapouts: 1100\n")
put("ioreg", ioreg(2500, 5000, 1050))
second = cli("tick")
check(second.returncode == 0, "the second tick runs: %s" % second.stderr)
row = json.loads(second.stdout)
check(isinstance(row["births_s"], int) and row["births_seen"] == 4, "births counted: %s" % row)
check(row["births_top"] == [["statusline.sh", 2, "own"], ["Hammerspoon", 1, "own"], ["xpcproxy", 1, "apple"]],
      "births attributed to the nearest own script or app above the newborn: %s" % row["births_top"])


def chain_causers(cli_tag):
    """A worker's chain: worker-run (own) -> the CLI -> zsh -c -> git, and run-suites.sh -> bash; worker-run -> jq."""
    procs = {"10": [1, 0, "llm-legs/bin/worker-run", "own", 10, me_uid, "script"], "11": [10, 0, cli_tag, "third-party", 11, me_uid, None],
             "12": [11, 0, "zsh", "apple", 12, me_uid, "inline"], "13": [12, 0, "git", "apple", 13, me_uid, None],
             "14": [12, 0, "llm-legs/share/run-suites.sh", "own", 14, me_uid, "script"],
             "15": [14, 0, "bash", "apple", 15, me_uid, None], "16": [10, 0, "jq", "third-party", 16, me_uid, None]}
    by_pid = {entry[4]: key for key, entry in procs.items()}
    return [m.causer(key, procs, by_pid) for key in ("13", "15", "16")]


me_uid = os.getuid()
causers = {tag: chain_causers(tag) for tag in ("claude", "codex", "grok", "agy")}
check(all(found == [(tag, "third-party"), ("llm-legs/share/run-suites.sh", "own"), ("llm-legs/bin/worker-run", "own")]
          for tag, found in causers.items()),
      "a command below an LLM CLI is the CLI's, an own script below it its own, and the launcher above keeps only what "
      "it spawns itself: %s" % causers)
check(row["cpu_top"] == [["statusline.sh", 10.0, 9.0, "own"], ["Hammerspoon", 1.0, 0.0, "own"]],
      "statusline.sh's CPU = its own ps time plus its rusage's reaped-children growth; a shrunk counter adds none: %s"
      % row["cpu_top"])
many = [{"t": 1.0, "cpu_top": [["third%d" % i, 100.0, 0.0, "third-party"] for i in range(m.TOP)],
         "cpu_own": [["own%d" % i, 1.0, 0.0, "own"] for i in range(m.TOP + 2)]}] * 2
hour = m.summarize(many)
check(row["cpu_own"] == row["cpu_top"] and len(hour["cpu_own"]) == m.TOP + 2
      and hour["cpu_own"][0] == ["own0", 2.0, 0.0, "own"] and not any(e[3] == "own" for e in hour["cpu_top"]),
      "every own process's CPU is kept beside the top, however far below it: %s" % hour["cpu_own"][:2])
check(row["kernel"] == 0.25 and row["busy"] == 0.5, "kernel and busy shares off host ticks: %s %s" % (row["kernel"], row["busy"]))
check(row["comp_share"] == 0.25 and row["comp_gib"] == 6.0 and row["mem_gib"] == 24.0, "compressor share of RAM: %s" % row)
check(row["swap_share"] == 0.75 and row["swapout_b"] == 1000 * 16384, "swap use and swap writes: %s" % row)
check(row["disk"] == {"internal:disk0": [500, 4000], "external:disk4": [1000, 0]}, "disk deltas per device: %s" % row["disk"])
check(row["free_gib"] == {"Data": 100.0, "Work Disk": 20.0}, "free space of Data and /Volumes mounts: %s" % row["free_gib"])
check(set(row["self"]["steps"]) == {"host", "ps", "ps_children", "vm_stat", "sysctl", "ioreg", "df", "rusage"}
      and all(len(v) == 2 for v in row["self"]["steps"].values()), "each step's wall and CPU: %s" % row["self"])
state = json.load(open(os.path.join(work, "state", "tick-state.json")))
text = json.dumps(state) + open(os.path.join(work, "state", "ticks", m.local_day(time.time()) + ".jsonl")).read()
check("statusline.sh" in text and own not in text and "jq .x" not in text and "git status" not in text,
      "no argv or path persisted, script basenames only")
check(not os.path.exists(os.path.join(work, "doctors", "collector-runs.jsonl")), "a tick journals no collector run")
put("sysctl", "{ sec = 1790099999, usec = 0 } Mon Sep 21 10:00:00 2026\n25769803776\n"
              "total = 6144.00M  used = 4608.00M  free = 1536.00M  (encrypted)\n")
row = json.loads(cli("tick").stdout)
check(row["dt"] is None and row["kernel"] is None and row["cpu_top"] == [] and "disk" not in row,
      "a new boot starts a fresh series: %s" % row)
saved = {name: open(os.path.join(fix, name)).read() for name in ("ps", "ps-children")}
me = os.getuid()
parent_row = (100, 1, 501, "0:01.00", start, "/bin/bash %s/bin/statusline.sh" % own)


def reaped_ticks(child_exe):
    """cpu_top of six ticks: a child_exe child under an own launcher lives, dies, then dies with a helper grandchild."""
    lives = []
    # (child's ps time, grandchild's ps time, rusage reaped-children CPU of [parent, child])
    for child, grandchild, reaped in (("0:02.00", None, [0.0, 0.0]), ("0:07.00", None, [0.0, 0.0]), (None, None, [8.0, 0.0]),
                                      ("0:00.00", "0:00.00", [8.0, 0.0]), ("0:01.00", "0:02.00", [8.0, 0.5]),
                                      (None, None, [15.5, 0.0])):
        rows = [parent_row] + ([(600, 100, me, child, born, child_exe)] if child else []) \
            + ([(700, 600, me, grandchild, born, "/opt/homebrew/bin/helper -p")] if grandchild else [])
        put("ps", ps_rows(rows))
        put("ps-children", ps_rows(rows))
        put("rusage.json", json.dumps({"100": [0, 0, 0, 0, reaped[0]], "600": [0, 0, 0, 0, reaped[1]], "700": [0, 0, 0, 0, 0.0]}))
        lives.append(json.loads(cli("tick").stdout)["cpu_top"])
    return lives


lives = reaped_ticks("/opt/homebrew/bin/helper -p")
check(lives[1:3] == [[["helper", 5.0, 0.0, "third-party"]], [["statusline.sh", 3.0, 3.0, "own"]]],
      "a child reaped after living through ticks charges its parent only the CPU its own ticks never did: %s" % lives)
check(lives[4] == [["helper", 3.5, 0.5, "third-party"]] and lives[5] == [["statusline.sh", 4.0, 4.0, "own"]],
      "a grandchild dead with its parent counts against the nearest live ancestor, its parent's reaped CPU included: %s"
      % lives[3:])
lives = reaped_ticks("/Users/x/.nvm/lib/node_modules/@openai/codex/vendor/bin/codex exec")
check(lives[1:3] == [[["codex", 5.0, 0.0, "third-party"]], [["codex", 3.0, 3.0, "third-party"]]]
      and lives[4] == [["helper", 2.0, 0.0, "third-party"], ["codex", 1.5, 0.5, "third-party"]]
      and lives[5] == [["codex", 4.0, 4.0, "third-party"]],
      "what an own launcher reaps beyond the ticks' charge when an LLM CLI below it dies is the CLI's, never the "
      "launcher's: %s" % lives)
os.remove(os.path.join(fix, "rusage.json"))
for name, text in saved.items():
    put(name, text)

# ---- the nightly pass: report headers, relaunched jobs, `last`, caches, SMART
now = time.time()


def stamp(at, fmt="%Y-%m-%d %H:%M:%S.00 %z"):
    return time.strftime(fmt, time.localtime(at))


def report(name, first_line, body="", age=None):
    path = os.path.join(work, "diag", name)
    with open(path, "w") as handle:
        handle.write(first_line + "\n" + body)
    if age is not None:
        os.utime(path, (now - age, now - age))


def ips(app, at, bug="309", **extra):
    return json.dumps(dict({"app_name": app, "timestamp": stamp(at), "bug_type": bug}, **extra))


with open(os.path.join(work, "agents", "own.plist"), "wb") as handle:
    plistlib.dump({"Label": "com.llm-legs.memlogd", "ProgramArguments": ["%s/bin/memlogd" % own], "KeepAlive": True}, handle)
with open(os.path.join(work, "agents", "vendor.plist"), "wb") as handle:
    plistlib.dump({"Label": "com.vendor.sync", "Program": "/Applications/Vendor.app/Contents/MacOS/vsync",
                   "StartInterval": 300}, handle)
with open(os.path.join(work, "agents", "once.plist"), "wb") as handle:
    plistlib.dump({"Label": "com.vendor.once", "Program": "/opt/once/oncejob", "RunAtLoad": True}, handle)
report("Hammerspoon-2026-10-05-120000.ips", ips("Hammerspoon", now - 2 * 3600))
report("Hammerspoon-2026-10-04-120000.ips", ips("Hammerspoon", now - 30 * 3600))
report("memlogd-2026-10-05-110000.ips", ips("memlogd", now - 3 * 3600))
report("vsync-2026-10-05-110000.ips", ips("vsync", now - 4 * 3600))
report("oncejob-2026-10-05-110000.ips", ips("oncejob", now - 4 * 3600))
report("ExcUserFault_bash-2026-10-05.ips", ips("bash", now - 3600, is_simulated=True))
report("JetsamEvent-2026-10-05.ips", ips(None, now - 3600, bug="298"))
report("python3.13_2026-10-05.diag", "Date/Time:        %s" % stamp(now - 5 * 3600, "%Y-%m-%d %H:%M:%S.000 %z"),
       "Event:            disk writes\nCommand:          python3.13\nPath:             /opt/homebrew/bin/python3.13\n")
report("git-2026-10-05.diag", "Date/Time:        %s" % stamp(now - 5 * 3600, "%Y-%m-%d %H:%M:%S.000 %z"),
       "Event:            disk writes\nCommand:          git\nPath:             /usr/bin/git\n")
report("bird_2026-10-04.diag", "Date/Time:        %s" % stamp(now - 26 * 3600, "%Y-%m-%d %H:%M:%S.000 %z"),
       "Event:            disk writes\nCommand:          python3.13\n")
report("shutdown-2026-10-04.shutdownStall", "Date/Time:        %s" % stamp(now - 24 * 3600 - 600, "%Y-%m-%d %H:%M:%S %z"),
       "Command:          vendor-fingerprint\nPath:             %s/bin/vendor-fingerprint\n" % own)
report("old-2026-09-20.ips", ips("Hammerspoon", now - 10 * 86400), age=10 * 86400)
put("last", "".join("%-9s ~                         %s\n" % (kind, stamp(at, "%a %b %e %H:%M"))
                    for kind, at in (("reboot", now - 86400), ("reboot", now - 2 * 86400), ("shutdown", now - 2 * 86400 - 60),
                                     ("reboot", now - 9 * 86400), ("reboot", now - 10 * 86400))))
put("diskutil", "   Device Identifier:         disk0\n   SMART Status:              Verified\n")
run = cli("nightly")
check(run.returncode == 0, "nightly runs: %s" % run.stderr)
night = json.load(open(os.path.join(work, "state", "nightly.json")))
kinds = sorted((r["kind"], r["name"], r["owner"], r["job"]) for r in night["reports"])
check(kinds == [("crash", "Hammerspoon", "own", False), ("crash", "Hammerspoon", "own", False),
                ("crash", "memlogd", "own", True), ("crash", "oncejob", "third-party", False),
                ("crash", "vsync", "third-party", True), ("diskwrites", "git", "apple", False),
                ("diskwrites", "python3.13", "own", False), ("diskwrites", "python3.13", "own", False),
                ("fault", "bash", "own", False), ("jetsam", "JetsamEvent", "apple", False),
                ("shutdownStall", "vendor-fingerprint", "own", False)],
      "report headers by kind, process and owner, old reports skipped: %s" % kinds)
check(night["relaunched"] == 2, "KeepAlive and StartInterval jobs only: %s" % night["relaunched"])
check(len(night["unclean"]) == 2 and night["boots"] == 2, "unclean = a boot after a boot: %s" % night)
check(night["caches"] == [["uv", 22.0], ["small", 1.0]], "cache sizes in GiB, the root itself skipped: %s" % night["caches"])
check(night["smart"] == "Verified" and "info disk0" in open(os.path.join(fix, "diskutil.calls")).read(),
      "SMART of the internal disk via diskutil: %s" % night["smart"])
check(set(night["steps"]) == {"jobs", "reports", "last", "boots", "caches", "smart"}, "nightly step costs: %s" % night["steps"])
check(open(os.path.join(fix, "log.calls")).read().count("firstLoginAfterHardRestart") == 2,
      "each boot after a boot asks the login log once")
put("log", "2026-10-11 13:08:14.543 Df loginwindow[179:9ef] [com.apple.loginwindow.logging:TAL] -[PersistentAppsSupport "
    "checkTALLoginOptions] |      firstLoginAfterPanic:0, firstLoginAfterHardRestart:0, lastTALLogoutPrefSetting:0\n")
cleared = m.nightly()
put("log", "loginwindow firstLoginAfterPanic:0, firstLoginAfterHardRestart:1\n")
cached = m.nightly()
check(cleared["unclean"] == [] and cached["unclean"] == []
      and open(os.path.join(fix, "log.calls")).read().count("firstLoginAfterHardRestart") == 4,
      "a GUI or Software Update restart its login log calls clean is no unclean reboot, asked once and kept: %s"
      % cleared["unclean"])
os.remove(os.path.join(work, "state", "boots.json"))
check(len(m.nightly()["unclean"]) == 2,
      "a hard restart in the login log stays unclean")
os.remove(os.path.join(work, "state", "boots.json"))
os.remove(os.path.join(fix, "log"))
m.nightly()
os.remove(os.path.join(fix, "log.calls"))
last_saved = open(os.path.join(fix, "last")).read()
put("last", "reboot    ~                         Wed Dec 30 10:00\nreboot    ~                         Sun Dec 20 10:00\n")
january = time.mktime((2027, 1, 3, 12, 0, 0, 0, 0, -1))
check([time.localtime(at)[:3] for at, _kind in m.boot_events(january)] == [(2026, 12, 30), (2026, 12, 20)],
      "a boot of last month in early January is last year's: %s" % m.boot_events(january))
put("last", last_saved)
report("Odd-2026-10-05.ips", "[1]")
check(m.report_header(os.path.join(work, "diag", "Odd-2026-10-05.ips"), "Odd-2026-10-05.ips", {})["kind"] == "other",
      "an .ips whose first line is JSON but no object reads as an unknown report")
os.remove(os.path.join(work, "diag", "Odd-2026-10-05.ips"))
patched = {name: getattr(m, name) for name in ("tick", "launch_due", "nightly_due", "nightly")}
m.tick = m.launch_due = lambda *a: None
m.nightly_due = lambda now: True


def broken_nightly(*a):
    raise RuntimeError("nightly broke")


m.nightly = broken_nightly
try:
    did = m.agent()
except RuntimeError:
    did = None
for name, value in patched.items():
    setattr(m, name, value)
broke = m.read_json(os.path.join(work, "state", "latest.json"), {})
if broke:
    os.remove(os.path.join(work, "state", "latest.json"))
check(did == ["nightly"] and broke.get("status") == "error" and "nightly broke" in broke["self"]["error"],
      "a failed nightly pass writes the error document, never leaves the last one standing: %s" % did)
launched_path = os.path.join(work, "state", "launched.json")
failed_at = m.read_json(launched_path, {}).get("nightly_failed")
night_path = os.path.join(work, "state", "nightly.json")
night_saved = open(night_path).read()
json.dump(dict(json.loads(night_saved), as_of_s=failed_at - 40 * 3600), open(night_path, "w"))
check(isinstance(failed_at, float) and not m.nightly_due(failed_at + 60) and m.nightly_due(failed_at + 3601),
      "a failed nightly pass is retried an hour later, never on every minute's run: %s" % failed_at)
open(night_path, "w").write(night_saved)
judge = m.Judge(failed_at + 60, None)
m.judge_nightly(judge, {"as_of_s": failed_at - 3600, "reports": []})
check(judge.blind == ["nightly"], "the documents judged while the nightly pass is broken read it blind: %s" % judge.blind)
m.write_json(launched_path, {k: v for k, v in m.read_json(launched_path, {}).items() if k != "nightly_failed"})

# ---- the judge: each rule at its limit fires, just under it does not
def tick_row(t, **values):
    return dict({"t": t, "dt": 60}, **values)


def judged(rows=(), days=(), night=None, at=None):
    judge = m.Judge(at or now, night)
    m.judge_ticks(judge, list(rows), list(days))
    if night is not None:
        m.judge_nightly(judge, night)
    return {p["id"]: p for p in judge.problems}, judge


def minutes(n, **values):
    return [tick_row(now - 60 * i, **values) for i in range(n, 0, -1)]


fired, _ = judged(minutes(3, births_s=1000, births_seen=10, births_top=[["statusline.sh", 7, "own"], ["xpcproxy", 3, "apple"]]))
spawn = fired.get("spawn:machine")
check(spawn and spawn["severity"] == "review" and spawn["cause"] == {"name": "statusline.sh", "share": 0.7, "owner": "own",
                                                                     "fix_target": True, "files": ["llm-legs/bin/statusline.sh"]}
      and "top cause statusline.sh 70%" in spawn["fact"], "spawn 1000/s fires with its top cause: %s" % spawn)
check("spawn:machine" not in judged(minutes(3, births_s=999))[0], "spawn 999/s stays quiet")
check("spawn:machine" not in judged(minutes(2, births_s=5000))[0], "spawn needs three ticks")
check(judged(minutes(3, births_s=2500))[0]["spawn:machine"]["severity"] == "heavy", "spawn 2500/s is heavy")
apple = judged(minutes(3, births_s=1200, births_seen=4, births_top=[["xpcproxy", 4, "apple"]]))[0]["spawn:machine"]
check(apple["cause"]["fix_target"] is False and "(apple, report only)" in apple["fact"], "an Apple cause is report-only: %s" % apple)
elsewhere = judged(minutes(3, births_s=1200, births_seen=4, births_top=[["bench.py", 4, "own"]]))[0]["spawn:machine"]
check(elsewhere["cause"]["fix_target"] is False and elsewhere["cause"]["files"] == [] and "(own, report only)" in elsewhere["fact"],
      "an own script outside the sweep repositories is report-only: %s" % elsewhere["cause"])

check(judged(minutes(3, kernel=0.40))[0]["kernel:machine"]["severity"] == "review", "kernel 0.40 fires")
check("kernel:machine" not in judged(minutes(3, kernel=0.39))[0], "kernel 0.39 stays quiet")
check(judged(minutes(30, kernel=0.55))[0]["kernel:machine"]["severity"] == "heavy", "kernel 0.55 for 30 min is heavy")
check(judged(minutes(30, kernel=0.55) + [tick_row(now, kernel=0.54)])[0]["kernel:machine"]["severity"] == "review",
      "one tick under 0.55 in the 30 min keeps it review")

check("compressor:machine" in judged(minutes(10, comp_share=0.33))[0], "compressor 33% for 10 min fires")
check("compressor:machine" not in judged(minutes(9, comp_share=0.33) + [tick_row(now, comp_share=0.32)])[0],
      "one tick under 33% in the 10 min stays quiet")

swap = dict(swap_used_mb=3072.0, swap_total_mb=6144.0)
check("swap:machine" in judged([tick_row(now - 30, swap_share=0.5, **swap)])[0], "swap 50% fires")
check("swap:machine" not in judged([tick_row(now - 30, swap_share=0.49, **swap)])[0], "swap 49% stays quiet")
check("swap:machine" not in judged([tick_row(now - 700, swap_share=0.9, **swap)])[0], "a stale tick judges no swap")

limit = 20 * m.GIB * 3600 / 86400
check("swap-writes:machine" in judged([tick_row(now - 1800, dt=1800, swapout_b=limit / 2),
                                       tick_row(now, dt=1800, swapout_b=limit / 2)])[0], "swap writes 20 GiB/day fires")
check("swap-writes:machine" not in judged([tick_row(now - 1800, dt=1800, swapout_b=limit / 2),
                                           tick_row(now, dt=1800, swapout_b=limit / 2 - 2 ** 20)])[0],
      "swap writes just under 20 GiB/day stay quiet")
check("swap-writes:machine" not in judged([tick_row(now, dt=1800, swapout_b=limit * 10)])[0], "under an hour covered judges nothing")


def day_rows(gb):
    return [{"day": m.local_day(now - i * 86400), "covered_s": 86400, "ssd_w_b": gb * 1e9, "ssd_gb_day": gb} for i in range(3)]


reports = {"reports": [{"at": now, "kind": "diskwrites", "name": "python3.13", "owner": "own"}] * 2
           + [{"at": now, "kind": "diskwrites", "name": "git", "owner": "apple"}], "as_of_s": now}
ssd = judged(days=day_rows(201), night=reports)[0].get("ssd-writes:internal")
check(ssd and ssd["severity"] == "review" and ssd["cause"]["name"] == "python3.13" and ssd["exposure"] == 3,
      "SSD writes 201 GB/day over the week fire with the top disk-writes report: %s" % ssd)
writers = [dict(d, cohort=[["Google Chrome", "third-party", 0, 0, 90e9, 0, 0, 0, 1],
                          ["llm-legs/bin/statusline.sh", "own", 0, 0, 50e9, 0, 0, 0, 1]]) for d in day_rows(201)]
ssd = judged(days=writers, night=reports)[0]["ssd-writes:internal"]
check(ssd["cause"] == {"name": "llm-legs/bin/statusline.sh", "share": 0.25, "owner": "own", "fix_target": True,
                       "files": ["llm-legs/bin/statusline.sh"]},
      "SSD writes name the week's top own writer by measured bytes over a bigger third-party one and the reports: %s"
      % ssd["cause"])
check(m.levers(ssd["cause"]["name"], "ssd-writes") == [m.RULE_LEVERS["ssd-writes"]], "an SSD-writes cause carries the write levers")
check("ssd-writes:internal" not in judged(days=day_rows(200))[0], "SSD writes 200 GB/day stay quiet")
check(judged(days=day_rows(401))[0]["ssd-writes:internal"]["severity"] == "heavy", "SSD writes 401 GB/day are heavy")
old = [{"day": m.local_day(now - 9 * 86400), "covered_s": 86400, "ssd_w_b": 900e9}]
check("ssd-writes:internal" not in judged(days=old + day_rows(150))[0], "a day older than the week is out of the mean")

night_caches = {"as_of_s": now, "caches": [[".cache/uv", 22.0]]}
low = judged([tick_row(now - 30, free_gib={"Data": 24.9, "Work": 25.0})], night=night_caches)[0]
check("free-space:Data" in low and "free-space:Work" not in low, "free space 24.9 GiB fires, 25 stays quiet: %s" % list(low))
check(low["free-space:Data"]["cause"] == {"name": ".cache/uv", "share": None, "owner": "own", "fix_target": False},
      "low Data space names the biggest cache, not a fix target")
check(judged([tick_row(now - 30, free_gib={"Data": 9.9})])[0]["free-space:Data"]["severity"] == "heavy", "free 9.9 GiB is heavy")

fired, _ = judged(night=night)
check(fired["hammerspoon-crash:Hammerspoon"]["value"] == 1 and fired["hammerspoon-crash:Hammerspoon"]["cause"]["fix_target"],
      "one Hammerspoon crash in the day fires, the one before it is out: %s" % fired.get("hammerspoon-crash:Hammerspoon"))
check(fired["job-crash:memlogd"]["cause"]["fix_target"] is True and fired["job-crash:vsync"]["cause"]["fix_target"] is False,
      "relaunched jobs' crashes fire, third-party report-only: %s" % sorted(fired))
check("job-crash:oncejob" not in fired and "job-crash:bash" not in fired, "no row for a job launchd does not relaunch or a fault")
reboot = fired["unclean-reboot:machine"]
check(reboot["value"] == 1 and reboot["cause"]["name"] == "vendor-fingerprint" and reboot["cause"]["fix_target"],
      "the unclean reboot inside 7 days fires with the shutdown stall beside it: %s" % reboot)
quiet = dict(night, reports=[r for r in night["reports"] if r["name"] not in ("Hammerspoon", "memlogd", "vsync")],
             unclean=[now - 8 * 86400])
fired, _ = judged(night=quiet)
check(not [k for k in fired if k.split(":")[0] in ("hammerspoon-crash", "job-crash", "unclean-reboot")],
      "no crash, no unclean reboot inside 7 days: quiet: %s" % sorted(fired))

# ---- blind spots, the ledger and the envelope
_, judge = judged([], night=None)
m.judge_nightly(judge, None)
check(judge.blind == ["ticks", "nightly"], "no ticks and no nightly pass are blind: %s" % judge.blind)
_, judge = judged(minutes(3), night=dict(night, as_of_s=now - 37 * 3600))
check(judge.blind == ["nightly"], "a nightly pass older than 36 h is blind: %s" % judge.blind)

ledger = {"owner": "System doctor", "blind_spots": [{"id": "x"}], "rows": [
    {"id": "SYS-1", "status": "not-a-bug", "match": {"rule": "swap", "key": "machine"}},
    {"id": "SYS-2", "status": "fixed", "match": {"rule": "kernel", "key": "machine"}, "fixes": [{"at": m.iso_time(now - 7200)}]},
    {"id": "SYS-3", "status": "fixed", "match": {"rule": "spawn", "key": "machine"}, "fixes": [{"at": m.iso_time(now + 60)}]},
    {"id": "SYS-4", "status": "fixed-pending", "match": {"rule": "compressor", "key": "machine"}},
    {"id": "SYS-5", "status": "open", "match": {"rule": "free-space", "key": "Data"}},
    {"id": "SYS-6", "status": "open", "match": {"rule": "free-space"}}]}
json.dump(ledger, open(os.environ["SYSTEM_DOCTOR_LEDGER"], "w"))
rows = minutes(10, births_s=1500, kernel=0.45, comp_share=0.4, swap_share=0.8, swap_used_mb=4915.0, swap_total_mb=6144.0,
               free_gib={"Data": 20.0})
os.makedirs(os.path.join(work, "state", "ticks"), exist_ok=True)
for name in os.listdir(os.path.join(work, "state", "ticks")):
    os.remove(os.path.join(work, "state", "ticks", name))
with open(os.path.join(work, "state", "ticks", m.local_day(now) + ".jsonl"), "w") as handle:
    handle.write("".join(json.dumps(r) + "\n" for r in rows))
doc = m.document(now, now)
states = {p["id"]: p["state"] for p in doc["problems"]}
check(states == {"SYS-2": "regressed", "SYS-3": "watch", "SYS-4": "fixed-pending", "SYS-5": "open",
                 "ledger:SYS-6": "new", "unclean-reboot:machine": "new", "hammerspoon-crash:Hammerspoon": "new",
                 "job-crash:memlogd": "new", "job-crash:vsync": "new"},
      "ledger rows match exact rule and key; not-a-bug drops, fixed regresses after its fix: %s" % states)
check(doc["problem_count"] == 7 and doc["status"] == "problems", "problem_count counts new/open/regressed: %s" % doc["problem_count"])
check({"contract", "doctor", "as_of", "as_of_s", "judge", "status", "problem_count", "problems", "blind_spots", "self"}
      <= set(doc) and doc["contract"] == 1 and doc["doctor"] == "system" and len(doc["judge"]) == 64
      and doc["blind_spots"] == [{"id": "x"}], "the shared envelope: %s" % sorted(doc))
for problem in doc["problems"]:
    check({"id", "rule", "state", "fact", "value", "limit", "unit", "window_h", "exposure", "count", "first_seen",
           "last_seen", "evidence", "ledger", "label"} <= set(problem) and len(problem["evidence"]) <= 3,
          "problem fields: %s" % problem["id"])
check(doc["measures"]["births_s"] == 1500 and doc["measures"]["swap_share"] == 0.8 and doc["nightly"]["reports"]["crash"] == 5,
      "measures and the nightly summary: %s" % doc["measures"])
check(os.path.exists(os.path.join(work, "state", "days.jsonl")) and os.path.exists(
    os.path.join(work, "state", "hours", m.local_day(now) + ".jsonl")), "the judge rolls hours and days up")
stale = os.path.join(work, "state", "ticks", m.local_day(now - 15 * 86400) + ".jsonl")
open(stale, "w").write("{}\n")
m.document(now, now)
check(not os.path.exists(stale), "minute rows older than 14 days are deleted")

days_path = os.path.join(work, "state", "days.jsonl")
kept_days = open(days_path).read()
with open(days_path, "a") as handle:
    for back, covered in ((3, 86000), (4, 1800), (9, 86000)):
        handle.write(json.dumps({"day": m.local_day(now - back * 86400), "covered_s": covered, "busy": 0.5, "kernel": 0.2,
                                 "births_s": 400, "ssd_gb_day": 250.0, "free_min_gib": {"Data": 60.0}}) + "\n")
os.makedirs(os.path.join(work, "state", "logstores"), exist_ok=True)
logs_day = os.path.join(work, "state", "logstores", m.local_day(now - 2 * 86400) + ".jsonl")
with open(logs_day, "a") as handle:
    handle.write(json.dumps({"t": now - 2 * 86400, "stores": [], "total_bytes": 4.2e9}) + "\n")
doc = m.document(now, now)
series, three = doc["days"], m.local_day(now - 3 * 86400)
check(series["busy"] == {three: 0.5} and series["births_s"] == {three: 400} and series["free_gib"] == {"Data": {three: 60.0}}
      and series["logs_gb"].get(m.local_day(now - 2 * 86400)) == 4.2 and doc["measures"]["cores"] == os.cpu_count(),
      "the days block keeps the last 7 days covered >= 1 h and the log stores' daily totals: %s" % series)
open(days_path, "w").write(kept_days)
os.remove(logs_day)

run = cli()
check(run.returncode == 0 and run.stdout.startswith("System doctor: problems"), "the CLI judge prints its view: %s" % run.stdout)
latest = json.load(open(os.path.join(work, "state", "latest.json")))
check(latest["doctor"] == "system", "latest.json is written under SYSTEM_DOCTOR_DIR")
journal = [json.loads(line) for line in open(os.path.join(work, "doctors", "collector-runs.jsonl"))]
check([r["doctor"] for r in journal] == ["system", "system"], "nightly and judge each journal one collector run: %s" % journal)
days = [json.loads(line) for line in open(os.path.join(work, "doctors", "problem-days.jsonl"))]
check(days and days[-1]["doctor"] == "system" and latest["status"] == days[-1]["status"] == "problems"
      and days[-1]["count"] == latest["problem_count"] > 0, "the judge writes its problem day: %s" % days)


def files_state():
    paths = [os.path.join(work, "doctors", "problem-days.jsonl")]
    for folder, _, names in os.walk(os.path.join(work, "state")):
        paths += [os.path.join(folder, name) for name in names]
    return {path: (os.stat(path).st_ino, os.stat(path).st_mtime_ns, os.stat(path).st_size) for path in paths}


before = files_state()
check(cli("--json").returncode == 0 and json.load(open(os.path.join(work, "state", "latest.json")))["as_of_s"]
      == latest["as_of_s"] and files_state() == before, "--json writes nothing")

# ---- install-agent: a named wrapper and a low-priority plist, loaded through launchctl
put("launchctl", "")
run = cli("install-agent")
check(run.returncode == 0, "install-agent runs: %s" % run.stderr)
wrapper = os.path.join(os.environ["SYSTEM_DOCTOR_LIBEXEC_DIR"], "system-doctor")
body = open(wrapper).read()
check(os.access(wrapper, os.X_OK) and "exec \"$script\" \"$@\"" in body
      and "script=%s/bin/system-doctor" % root in body, "the wrapper execs the real script: %s" % body)
plist = plistlib.load(open(os.path.join(os.environ["SYSTEM_DOCTOR_AGENT_DIR"], "com.llm-legs.system-doctor.plist"), "rb"))
check(plist["ProgramArguments"] == [wrapper, "agent"] and plist["StartInterval"] == 60 and plist["Nice"] == 10
      and plist["LowPriorityIO"] is True and plist["ProcessType"] == "Standard", "the plist: %s" % plist)
calls = open(os.path.join(fix, "launchctl.calls")).read().splitlines()
check([c.split()[0] for c in calls] == ["bootout", "bootstrap"], "launchctl bootout then bootstrap: %s" % calls)
busy = os.path.join(work, "bin", "launchctl-busy")
with open(busy, "w") as handle:
    handle.write('#!/bin/bash\nprintf "%%s\\n" "$1" >>"%s/busy.calls"\n[ "$1" = bootstrap ] || exit 0\n'
                 'n=$(grep -c bootstrap "%s/busy.calls")\n[ "$n" -gt "${BUSY_TRIES:-1}" ] || { echo "Input/output error" >&2; exit 5; }\n'
                 % (fix, fix))
os.chmod(busy, 0o755)


def install_waits(tries):
    waits, out, err, real_time = [], io.StringIO(), io.StringIO(), m.time

    # Never the shared time.sleep: subprocess's wait polls through it and would count as bootstrap pauses.
    class PausesOnly:
        sleep = staticmethod(waits.append)

        def __getattr__(self, name):
            return getattr(real_time, name)

    os.environ.update(SYSTEM_DOCTOR_LAUNCHCTL=busy, BUSY_TRIES=tries)
    m.time = PausesOnly()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = m.install_agent()
    finally:
        m.time = real_time
        os.environ["SYSTEM_DOCTOR_LAUNCHCTL"] = os.path.join(work, "bin", "launchctl")
        del os.environ["BUSY_TRIES"]
    return rc, out.getvalue(), err.getvalue(), waits


rc, out, err, waits = install_waits("1")
check(rc == 0 and "Installed" in out and len(waits) == 2 and waits[1] > 0
      and open(os.path.join(fix, "busy.calls")).read().split() == ["bootout", "bootstrap", "bootstrap"],
      "a bootstrap racing the bootout's teardown is retried after a pause: %s %s %s" % (out, err, waits))
os.remove(os.path.join(fix, "busy.calls"))
rc, out, err, waits = install_waits("9")
check(rc == 1 and "Installed" not in out and "Input/output error" in err,
      "an agent bootstrap never loaded fails install-agent: %s %s" % (out, err))
cli("uninstall-agent")
check(not os.path.exists(wrapper) and not os.listdir(os.environ["SYSTEM_DOCTOR_AGENT_DIR"]), "uninstall-agent removes both")

# ---- proofs: a fix of one cause, its births/s and CPU after it reached main against the 7 days before
check(m.PROOF == {"sightings": 30, "min_s": 7200, "max_s": 7 * 86400, "baseline_s": 7 * 86400, "drop": 0.25,
                  "reports_s": 7 * 86400}, "the proof parameters are the design's: %s" % m.PROOF)
for name in os.listdir(os.path.join(work, "state", "ticks")):
    os.remove(os.path.join(work, "state", "ticks", name))


def series(start, count, step, born, spent, name="statusline.sh"):
    return [{"t": start + i * step, "dt": step, "births_s": 1000, "births_seen": 10,
             "births_top": [[name, born, "own"], ["xpcproxy", 10 - born, "apple"]] if born else [["xpcproxy", 10, "apple"]],
             "cpu_top": [[name, spent, 0.0, "own"]] if spent else []} for i in range(count)]


def write_ticks(rows):
    folder = os.path.join(work, "state", "ticks")
    for name in os.listdir(folder):
        os.remove(os.path.join(folder, name))
    days = {}
    for row in rows:
        days.setdefault(m.local_day(row["t"]), []).append(json.dumps(row) + "\n")
    for day, lines in days.items():
        with open(os.path.join(folder, day + ".jsonl"), "w") as handle:
            handle.writelines(lines)


since = now - 3 * 3600
write_ticks(series(since - 6 * 3600, 360, 60, 5, 6.0) + series(since, 180, 60, 2, 2.0))
found = m.proof("statusline.sh", "spawn", since, now)
check(found["verdict"] == "proven" and found["before"]["births_s"] == 500 and found["after"]["births_s"] == 200
      and found["before"]["cores"] == 0.1 and found["need_s"] == 7200,
      "a per-minute cause proves a drop over 2 h after against the baseline: %s" % found)
check(m.proof("statusline.sh", "spawn", since, since + 3600)["verdict"] == "pending",
      "one hour after a per-minute cause is not yet a fair window")
write_ticks(series(since - 6 * 3600, 360, 60, 5, 6.0) + series(since, 180, 60, 5, 5.0))
found = m.proof("statusline.sh", "spawn", since, now)
check(found["verdict"] == "refused" and "births 500.0 -> 500.0 /s" in found["why"],
      "no drop over a fair window is not proven, the numbers say why: %s" % found)
write_ticks(series(since - 6 * 3600, 360, 60, 6, 0.0) + series(since, 180, 60, 2, 0.0))
check(m.proof("statusline.sh", "spawn", since, now)["verdict"] == "proven", "births alone dropping by 25 %% or more proves it")
write_ticks(series(since - 6 * 3600, 360, 60, 6, 1.0) + series(since, 180, 60, 2, 3.0))
check(m.proof("statusline.sh", "spawn", since, now)["verdict"] == "refused", "fewer births bought with more CPU is no proof")
write_ticks(series(since - 6 * 3600, 360, 60, 6, 1.0) + series(since, 180, 60, 2, 1.0))
found = m.proof("statusline.sh", "cohort", since, now)
check(m.proof("statusline.sh", "spawn", since, now)["verdict"] == "proven" and found["verdict"] == "refused"
      and "births" not in found["why"], "a cohort fix whose births fell but CPU held is no proof, B has no births: %s" % found)
wrote = [dict(r, io_top=[["statusline.sh", 6e8 if r["t"] < since else 1e8, 0, 0, "own"]])
         for r in series(since - 6 * 3600, 360, 60, 5, 6.0) + series(since, 180, 60, 5, 6.0)]
write_ticks(wrote)
found = m.proof("statusline.sh", "ssd-writes", since, now)
check(found["verdict"] == "proven" and found["before"]["mb_h"] == 36000 and found["after"]["mb_h"] == 6000
      and found["why"].startswith("writes 36000.0 -> 6000.0 MB/h"),
      "an SSD-writes fix is proven by its written bytes alone, births and CPU unchanged: %s" % found)
check(m.proof("statusline.sh", "cohort", since, now)["verdict"] == "proven",
      "a cohort fix whose writes fell is proven though its births and CPU held")
write_ticks([dict(r, io_top=[["statusline.sh", 6e8, 0, 0, "own"]]) for r in wrote])
check(m.proof("statusline.sh", "ssd-writes", since, now)["verdict"] == "refused", "unchanged written bytes refuse an SSD-writes fix")
sparse = [r if i % 30 == 0 else dict(r, births_top=[["xpcproxy", 10, "apple"]], cpu_top=[])
          for i, r in enumerate(series(since - 6 * 86400, 6 * 1440, 60, 5, 6.0))]
write_ticks(sparse + series(since, 180, 60, 0, 0.0))
found = m.proof("statusline.sh", "spawn", since, now)
check(found["verdict"] == "pending" and found["need_s"] == 30 * 1800,
      "a cause seen every 30 min needs 30 sightings' worth, 15 h, after its fix: %s" % found)
write_ticks(series(since - 6 * 3600, 20, 60, 5, 6.0) + series(since, 180, 60, 0, 0.0))
check(m.proof("statusline.sh", "spawn", since, now)["verdict"] == "refused", "a cause seen 20 times has no baseline")
check(m.proof("statusline.sh", "spawn", None, now)["verdict"] == "pending", "a fix not in main is pending")
crash = {"as_of_s": now, "reports": [{"at": now - 86400, "kind": "crash", "name": "memlogd", "owner": "own"}]}
check(m.proof("memlogd", "job-crash", now - 3 * 86400, now, crash)["verdict"] == "refused"
      and m.proof("memlogd", "job-crash", now - 8 * 86400 - 10, now, dict(crash, reports=[]))["verdict"] == "proven"
      and m.proof("memlogd", "job-crash", now - 3 * 86400, now, dict(crash, reports=[]))["verdict"] == "pending",
      "a crash cause: any crash after the fix refuses it, 7 quiet days prove it")
landed = now - 9 * 86400
memo = {}
check(m.proof("memlogd", "job-crash", landed, now, dict(crash, reports=[dict(crash["reports"][0], at=landed + 3600,
                                                                               ref="memlogd-1.ips")]), memo)["verdict"] == "refused"
      and m.proof("memlogd", "job-crash", landed, now + 86400, dict(crash, as_of_s=now + 86400, reports=[]), memo)["verdict"]
      == "refused", "a crash after the fix still refuses it once its report ages out of the nightly pass: %s" % memo)
night_path = os.path.join(work, "state", "nightly.json")
night_saved = open(night_path).read()
json.dump({"as_of_s": now, "reports": []}, open(night_path, "w"))
m.write_json(m.proofs_path(), memo)
check(m.check("memlogd", "job-crash", landed, now)[0] == 1,
      "check <cause> reads the same memo as the document, so an aged-out crash still refuses: %s" % (m.check("memlogd", "job-crash", landed, now),))
os.remove(m.proofs_path())
check(m.check("memlogd", "job-crash", landed, now)[0] == 0, "with no memo and no report the same fix is proven")
open(night_path, "w").write(night_saved)
fix_since = m.fix_since
shown = m.Judge(now, {"as_of_s": now, "reports": []})
shown.rows = [{"id": "SYS-10", "status": "fixed-pending", "match": {"rule": "job-crash", "key": "memlogd", "cause": "memlogd"},
               "fixes": [{"at": m.iso_time(landed)}]}]
m.fix_since = lambda row: now - 8 * 86400
shown.apply_ledger()
fresh = [(p["id"], p["state"]) for p in shown.problems]
shown.problems = []
m.fix_since = lambda row: now - 15 * 86400
shown.apply_ledger()
m.fix_since = fix_since
check(fresh == [("SYS-10", "watch")] and shown.problems == [],
      "a crash fix proven after its 7 quiet days reads watch for 7 more, then leaves: %s %s" % (fresh, shown.problems))
row = {"id": "SYS-9", "match": {"rule": "spawn", "key": "machine", "cause": "statusline.sh"}}
fix_since = m.fix_since
m.fix_since = lambda row: since
write_ticks(series(since - 6 * 3600, 360, 60, 5, 6.0) + series(since, 180, 60, 2, 2.0))
first_judge = m.Judge(now, {})
check(first_judge.prove({"fact": ""}, row) == "proven", "the fix proves against its baseline")
m.write_json(m.proofs_path(), first_judge.memo)
write_ticks(series(since, 180, 60, 2, 2.0))
check(m.proof("statusline.sh", "spawn", since, now)["verdict"] == "refused"
      and m.Judge(now, {}).prove({"fact": ""}, row) == "proven",
      "a proven fix stays proven once the minute rows of its baseline are deleted")
os.remove(m.proofs_path())
m.fix_since = fix_since

write_ticks(series(since - 6 * 3600, 360, 60, 5, 6.0) + series(since, 180, 60, 2, 2.0))
run = cli("check", "statusline.sh", "--rule", "spawn", "--since", str(since))
check(run.returncode == 0 and run.stdout.startswith("statusline.sh spawn: proven · births 500.0 -> 200.0 /s"),
      "check <cause> prints the proof and exits 0: %s %s" % (run.stdout, run.stderr))
check(cli("check", "statusline.sh", "--rule", "spawn", "--since", str(since + 7200)).returncode == 3,
      "check exits 3 while the window is short")
write_ticks(series(since - 6 * 3600, 360, 60, 5, 6.0) + series(since, 180, 60, 5, 6.0))
run = cli("check", "statusline.sh", "--rule", "spawn", "--since", str(since))
check(run.returncode == 1 and "refused" in run.stdout, "check refuses no drop with exit 1: %s" % run.stdout)
check(cli("check", "nothing.sh").returncode == 1, "check of a cause no ledger row names refuses")

write_ticks(series(since - 6 * 3600, 360, 60, 5, 6.0) + series(since, 180, 60, 2, 2.0)
            + series(now - 3600, 60, 60, 10, 1.0, "worker-run"))
fixes = [{"at": m.iso_time(since), "by": "run", "files": ["llm-legs/bin/statusline.sh"], "in": None, "regressed_at": None}]
rows = [{"id": "SYS-7", "status": "fixed-pending", "match": {"rule": "spawn", "key": "machine", "cause": "statusline.sh"},
         "fixes": fixes}]
json.dump({"owner": "System doctor", "rows": rows, "blind_spots": []}, open(os.environ["SYSTEM_DOCTOR_LEDGER"], "w"))
m.fix_since = lambda row: since
doc = {p["id"]: p for p in m.document(now, now, persist=False)["problems"]}
check(doc["SYS-7"]["state"] == "watch" and doc["SYS-7"]["proof"]["verdict"] == "proven"
      and doc["spawn:machine"]["cause"]["name"] == "worker-run" and doc["spawn:machine"]["state"] == "new",
      "a proven fix reads watch, and the other cause of the same rule stays its own problem: %s" % [(doc[k]["state"], doc[k].get("cause"), doc[k].get("proof")) for k in ("SYS-7", "spawn:machine")])
write_ticks(series(since - 6 * 3600, 360, 60, 5, 6.0) + series(since, 180, 60, 5, 6.0))
doc = m.document(now, now, persist=False)
check([(p["id"], p["state"]) for p in doc["problems"] if p["id"] == "SYS-7"] == [("SYS-7", "open")]
      and doc["problem_count"] >= 1 and "not proven · births" in next(p["fact"] for p in doc["problems"] if p["id"] == "SYS-7"),
      "a fix with no drop over a fair window stays open with its numbers")
m.fix_since = lambda row: None
doc = {p["id"]: p for p in m.document(now, now, persist=False)["problems"]}
check(doc["SYS-7"]["state"] == "fixed-pending", "a fix not yet in main reads fixed-pending")

norm = open(os.path.join(root, "bin", "night-run")).read().split("JQ_PROBLEM_NORM='", 1)[1].split("'\n", 1)[0]
states = subprocess.run(["jq", "-c", norm + " [.[] | norm_problem]"], capture_output=True, text=True, input=json.dumps([
    {"state": "watch", "proof": {"verdict": "proven"}}, {"state": "open", "proof": {"verdict": "refused"}},
    {"state": "fixed-pending", "proof": {"verdict": "pending"}}, {"state": "watch", "fact": "x"}])).stdout.strip()
check(states == '["proved","open","pending","watch"]', "the night report counts a proven System fix as proved: %s" % states)

# ---- close gate: a fixed own cause needs its ledger row and a baseline a later proof can measure
record = os.path.join(work, "record.json")
json.dump({"id": "r", "doctor": "system", "worktrees": [], "problems": [
    {"id": "spawn:machine", "rule": "spawn", "cause": "statusline.sh"},
    {"id": "job-crash:memlogd", "rule": "job-crash", "cause": "memlogd"},
    {"id": "spawn:other", "rule": "spawn", "cause": "worker-run"}]}, open(record, "w"))
decisions = os.path.join(work, "decisions.tsv")
open(decisions, "w").write("spawn:machine\tfixed\tllm-legs/bin/statusline.sh\tt\njob-crash:memlogd\tfixed\tx\ty\n"
                           "spawn:other\truled-out\tx\ty\n")
faults = m.check_record(record, decisions, now)
check(len(faults) == 1 and faults[0].startswith("job-crash:memlogd: fixed, but no fixed-pending ledger row"),
      "close needs a fixed-pending row naming the cause: %s" % faults)
wt = os.path.join(work, "wt")
os.makedirs(os.path.join(wt, "share"))
json.dump({"rows": rows + [{"id": "SYS-8", "status": "fixed-pending", "fixes": fixes,
                            "match": {"rule": "job-crash", "key": "memlogd", "cause": "memlogd"}}]},
          open(os.path.join(wt, "share", "system-ledger.json"), "w"))
json.dump(dict(json.load(open(record)), worktrees=[wt]), open(record, "w"))
check(m.check_record(record, decisions, now) == [], "a night run's own worktree ledger satisfies the gate")
write_ticks(series(now - 3600, 10, 60, 5, 6.0))
faults = m.check_record(record, decisions, now)
check(len(faults) == 1 and "no measurable baseline" in faults[0], "a births cause without a baseline cannot close fixed: %s" % faults)

# ---- phase 3: the storm census, its trigger and its rate limit
uid = os.getuid()
check(m.COLLECT["storm_s"] == 2000 and m.COLLECT["storm_min"] == 2 and m.COLLECT["storm_kernel"] == 0.5
      and m.COLLECT["census_s"] == 60 and m.COLLECT["census_every_s"] == 1800, "the census trigger is the design's: %s" % m.COLLECT)
storm = [{"t": now - 62, "births_s": 2000, "kernel": 0.3}, {"t": now - 2, "births_s": 2400, "kernel": 0.3}]
check(m.census_due(storm, now) == {"births_s": 2000, "kernel": 0.3}, "2,000 births/s on every tick of 2 min calls a census")
check(m.census_due([dict(storm[0], births_s=1999), storm[1]], now) is None, "1,999/s on one tick of the 2 min does not")
check(m.census_due(storm[1:], now) is None and m.census_due([dict(storm[0], t=now - 125), storm[1]], now) is None,
      "one storm tick is not 2 min of storm")
check(m.census_due([{"t": now - 2, "births_s": 100, "kernel": 0.5}], now) == {"births_s": 100, "kernel": 0.5}
      and m.census_due([{"t": now - 2, "births_s": 100, "kernel": 0.49}], now) is None, "kernel share 0.5 calls one, 0.49 not")
check(m.census_due(storm, now, now - 1799) is None and m.census_due(storm, now, now - 1800) is not None,
      "at most one census every 30 min")
state_path = os.path.join(work, "state", "tick-state.json")
saved_state = open(state_path).read()
json.dump({"recent": storm}, open(state_path, "w"))
started = []
due = m.launch_due(now, started.append)
check(due == ["census", "dumpstate", "harvest", "logstores"] and started == due, "a storm starts a census beside the "
      "hourly, 6-hourly and daily collectors: %s" % due)
check(m.launch_due(now + 60, started.append) == [] and len(started) == 4, "nothing starts again a minute later")
json.dump({"recent": [dict(r, t=r["t"] + 1700) for r in storm]}, open(state_path, "w"))
check(m.launch_due(now + 1700, started.append) == [], "a storm 28 min after the census starts none")
json.dump({"recent": [dict(r, t=r["t"] + 3600) for r in storm]}, open(state_path, "w"))
check(m.launch_due(now + 3600, started.append) == ["census", "dumpstate"], "an hour on: the census and the hourly snapshot")
open(state_path, "w").write(saved_state)

frames = [[1, 100, 300, 400], [1, 100, 300, 400, 201, 202, 203, 204, 205]]
json.dump({"frames": frames, "procs": {
    "1": [0, 0, 0, "/sbin/launchd"], "100": [1, uid, 1000, "/bin/bash %s/bin/statusline.sh --token" % own],
    "300": [1, uid, 1000, "/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon"], "400": [1, 0, 0, "/usr/libexec/xpcproxy"],
    "201": [100, uid, 2000, "/opt/homebrew/bin/jq .secret"], "202": [201, uid, 2000, "/usr/bin/git status"],
    "203": [300, uid, 2000, "/bin/sh -c true"], "204": [400, 0, 0, "/usr/libexec/helper"]}}, open(os.path.join(fix, "procs.json"), "w"))
row = m.census(now, seconds=0.05, poll=0.01)
check(row["births_top"] == [["statusline.sh", 2, "own"], ["Hammerspoon", 1, "own"], ["xpcproxy", 1, "apple"]]
      and row["births_seen"] == 4 and row["unreadable"] == 1 and row["polls"] >= 1,
      "the census charges each newborn it catches to the nearest own script or app above it: %s" % row)
text = open(os.path.join(work, "state", "census", m.local_day(now) + ".jsonl")).read()
check(own not in text and "--token" not in text and ".secret" not in text and "git status" not in text,
      "the census persists basenames and counts only")
spawn_rows = minutes(3, births_s=1200, births_seen=2, births_top=[["xpcproxy", 2, "apple"]])
judge = m.Judge(now, None)
judge.censuses = [{"t": now - 600, "births_seen": 40, "births_top": [["statusline.sh", 30, "own"], ["xpcproxy", 10, "apple"]]}]
m.judge_ticks(judge, spawn_rows, [])
found = {p["id"]: p for p in judge.problems}["spawn:machine"]["cause"]
check(found["name"] == "statusline.sh" and found["fix_target"] and found["share"] == round(30 / 46, 2),
      "the census's attribution names the spawn cause the ticks alone miss: %s" % found)
judge = m.Judge(now, None)
judge.censuses = [dict(judge.censuses[0] if judge.censuses else {}, t=now - 3700, births_seen=40,
                       births_top=[["statusline.sh", 30, "own"]])]
m.judge_ticks(judge, spawn_rows, [])
check({p["id"]: p for p in judge.problems}["spawn:machine"]["cause"]["name"] == "xpcproxy", "a census over an hour old is out")

# ---- phase 3: launchctl dumpstate, parsed into run deltas, orphans and job-loop causes
def service(header, **fields):
    lines = ["%s = {" % header, "\tactive count = 0", "\tenvironment = {", "\t\tTOKEN => %s/secret-path" % own, "\t}",
             "\targuments = {", "\t\t%s/bin/memlogd" % own, "\t\t--password=hunter2", "\t}"]
    lines += ["\t%s = %s" % (key.replace("_", " "), value) for key, value in fields.items()]
    return "\n".join(lines + ["\tresource coalition = {", "\t\truns = 999", "\t}", "}", ""])


def dump(memlogd, vsync, mdworker, doctor):
    return "".join([
        service("system", **{"runs": "notacounter"}),
        service("gui/%d/com.llm-legs.memlogd" % uid, program="%s/bin/memlogd" % own, properties="keepalive | runatload",
                runs=memlogd, last_exit_code="1", pid="777"),
        service("gui/%d/com.vendor.sync" % uid, program="/Applications/Vendor.app/Contents/MacOS/vsync", runs=vsync,
                last_exit_code="0", last_terminating_signal="Segmentation fault: 11", run_interval="300 seconds"),
        service("user/89/com.apple.mdworker.shared.0C000000-0400-0000-0000-000000000000", program="/usr/libexec/mdworker_shared",
                runs=mdworker, last_exit_code="(never exited)"),
        service("user/%d/com.apple.mdworker.shared.0D000000-0400-0000-0000-000000000000" % uid,
                program="/usr/libexec/mdworker_shared", runs=mdworker, last_exit_code="0"),
        service("gui/%d/com.llm-legs.system-doctor" % uid, program="%s/bin/system-doctor" % own, runs=doctor,
                last_exit_code="0", run_interval="60 seconds"),
        service("pid/4242/com.apple.xpc.thing")])


services = m.parse_dumpstate(dump(10, 5, 50, 100))
check(sorted(services) == ["gui/%d/com.llm-legs.memlogd" % uid, "gui/%d/com.llm-legs.system-doctor" % uid,
                           "gui/%d/com.vendor.sync" % uid,
                           "user/%d/com.apple.mdworker.shared.0D000000-0400-0000-0000-000000000000" % uid,
                           "user/89/com.apple.mdworker.shared.0C000000-0400-0000-0000-000000000000"],
      "services with a run counter only: %s" % sorted(services))
memlogd = services["gui/%d/com.llm-legs.memlogd" % uid]
check(memlogd == {"label": "com.llm-legs.memlogd", "name": "memlogd", "owner": "own", "runs": 10, "exit": "exit 1",
                  "pid": 777, "every": None, "relaunched": True}, "an own KeepAlive job: %s" % memlogd)
vsync = services["gui/%d/com.vendor.sync" % uid]
check(vsync["exit"] == "signal 11" and vsync["owner"] == "third-party" and vsync["every"] == 300 and vsync["name"] == "com.vendor.sync",
      "a third-party job's crash signal and schedule: %s" % vsync)
check({s["label"] for s in services.values() if s["owner"] == "apple"} == {"com.apple.mdworker.shared"},
      "unique parts and domains leave the label")
launchctl_fixture = os.path.join(fix, "launchctl")
ps_saved = open(os.path.join(fix, "ps")).read()
put("ps", ps_rows([(1, 0, 0, "0:01.00", start, "/sbin/launchd"),
                   (777, 1, uid, "0:00.50", start, "/bin/bash %s/bin/memlogd" % own),
                   (900, 1, uid, "0:00.10", start, "/opt/homebrew/bin/python3 %s/bin/worker-run" % own),
                   (901, 1, uid, "0:00.10", born, "/opt/homebrew/bin/python3 %s/bin/worker-run" % own),
                   (902, 1, uid, "0:00.10", born, "/bin/bash %s/bin/stray.sh" % own),
                   (903, 300, uid, "0:00.10", born, "/bin/bash %s/bin/child.sh" % own),
                   (300, 1, uid, "0:00.10", start, "/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon")]))
os.makedirs(os.path.join(work, "runs", "open-run"))
json.dump({"pid": 900}, open(os.path.join(work, "runs", "open-run", "meta.json"), "w"))
hour = 3600
for step, (mem_runs, vsync_runs, md_runs, doctor_runs) in enumerate(((10, 5, 50, 100), (130, 6, 300, 160), (250, 7, 600, 220),
                                                                    (370, 8, 900, 280))):
    put("launchctl", dump(mem_runs, vsync_runs, md_runs, doctor_runs))
    row = m.dumpstate(now - (3 - step) * hour)
check(row["services"] == 5 and row["dt"] == hour and row["reloaded"] == 0, "the fourth hourly snapshot: %s" % row)
jobs = {j["label"]: j for j in row["jobs"]}
check(jobs["com.llm-legs.memlogd"] == {"label": "com.llm-legs.memlogd", "name": "memlogd", "owner": "own", "runs": 120,
                                       "bad": 1, "exit": "exit 1", "every": None, "relaunched": True}
      and jobs["com.apple.mdworker.shared"]["runs"] == 600 and jobs["com.vendor.sync"]["bad"] == 1
      and jobs["com.llm-legs.system-doctor"]["runs"] == 60, "run deltas per label, summed over domains: %s" % jobs)
check(row["orphans"] == {"count": 3, "supervisors": 1, "top": [["worker-run", 2, row["orphans"]["top"][0][2], 1, "own"],
                                                               ["stray.sh", 1, row["orphans"]["top"][1][2], 0, "own"]]},
      "orphans: own processes launchd adopted that are no job, worker supervisors counted apart: %s" % row["orphans"])
text = "".join(open(f).read() for f in glob.glob(os.path.join(work, "state", "launchd", "*.jsonl"))) + open(
    os.path.join(work, "state", "dumpstate-state.json")).read()
check("hunter2" not in text and "secret-path" not in text and own not in text, "dumpstate keeps labels and counters only")
put("launchctl", dump(5, 9, 950, 300))
reloaded = m.dumpstate(now + 1)
check(reloaded["reloaded"] == 1 and {j["label"]: j["runs"] for j in reloaded["jobs"]}["com.llm-legs.memlogd"] == 5,
      "a counter that fell was re-registered: its runs since count: %s" % reloaded)
put("launchctl", "")
check(m.dumpstate(now + 2)["services"] == 0, "a dumpstate that timed out reads no service")
put("launchctl", dump(6, 9, 950, 300))
after_gap = m.dumpstate(now + 3)
check({j["label"]: j["runs"] for j in after_gap["jobs"]} == {"com.llm-legs.memlogd": 1},
      "the snapshot after a timed-out one counts against the last real one, never every counter since boot: %s" % after_gap["jobs"])
check(m.exit_text("78: EX_CONFIG") == "exit 78" and m.abnormal(m.exit_text("78: EX_CONFIG"))
      and m.exit_text("(never exited)") is None, "dumpstate's sysexits form `78: EX_CONFIG` is an abnormal exit")
launch_rows = m.tick_rows(now - 2 * 86400, now + 0.5, "launchd")
judge = m.Judge(now, None)
m.judge_launchd(judge, launch_rows, [])
loops = {p["id"]: p for p in judge.problems}
check(sorted(loops) == ["job-loop:com.llm-legs.memlogd", "job-loop:com.vendor.sync"],
      "a KeepAlive job relaunching 120 times an hour and a job crashing 3 times a day loop; an on-demand Apple worker and a "
      "60 s job on schedule do not: %s" % sorted(loops))
mem = loops["job-loop:com.llm-legs.memlogd"]
check(mem["value"] == 120 and mem["unit"] == "runs/h" and mem["severity"] == "review" and mem["cause"]["name"] == "memlogd"
      and mem["cause"]["fix_target"] and mem["cause"]["files"] == ["llm-legs/bin/memlogd"] and mem["cause"]["label"] == "com.llm-legs.memlogd",
      "an own looping job is a fix target by its program's file: %s" % mem)
judge = m.Judge(now, None)
m.judge_launchd(judge, launch_rows + [dict(launch_rows[0], t=now - 3 * 86400)], [])
check({p["id"]: p["exposure"] for p in judge.problems}["job-loop:com.llm-legs.memlogd"] == len(launch_rows),
      "a job-loop's exposure is the snapshots of its 24 h window, not the whole lookback: %s" % judge.problems)
sync = loops["job-loop:com.vendor.sync"]
check(sync["value"] == 3 and sync["unit"] == "abnormal exits/day" and not sync["cause"]["fix_target"]
      and "(third-party, report only)" in sync["fact"] and "signal 11" in sync["fact"], "a third-party crashing job is report-only: %s" % sync)
check(m.loop_rate({"runs": 360, "relaunched": True}, {"dt": 3600}) == 360 and m.loop_rate({"runs": 59, "relaunched": True}, {"dt": 3600}) == 59
      and m.loop_rate({"runs": 120, "relaunched": True, "every": 60}, {"dt": 3600}) == 0
      and m.loop_rate({"runs": 121, "relaunched": True, "every": 60}, {"dt": 3600}) == 121
      and m.loop_rate({"runs": 500, "relaunched": False}, {"dt": 3600}) == 0 and m.loop_rate({"runs": 500, "relaunched": True}, {"dt": 600}) == 0,
      "loop rate: twice the schedule, launchd's own relaunches, at least 30 min between snapshots")
judge = m.Judge(now, None)
m.judge_launchd(judge, [{"t": now - 600, "dt": 3600, "jobs": [{"label": "x", "name": "x", "owner": "own", "runs": 360,
                                                                 "bad": 0, "every": None, "relaunched": True}]}], [])
check(judge.problems[0]["severity"] == "heavy", "360 runs an hour is heavy")


def loop_ids(runs, bad=0):
    judge = m.Judge(now, None)
    m.judge_launchd(judge, [{"t": now - 600 - hour * i, "dt": 3600, "jobs": [
        {"label": "x", "name": "x", "owner": "own", "runs": runs, "bad": bad, "every": None, "relaunched": True}]}
        for i in range(3)], [])
    return [(p["id"], p["severity"]) for p in judge.problems]


check(loop_ids(60) == [("job-loop:x", "review")] and loop_ids(59) == [] and loop_ids(359) == [("job-loop:x", "review")],
      "60 relaunches an hour is a loop, 59 not, 359 still review")
check(loop_ids(1, 1) == [("job-loop:x", "review")] and loop_ids(1, 0) == [], "3 abnormal exits in a day are a dying job, none is nothing")
put("ps", ps_saved)

# ---- phase 3: the unified-log harvest, bounded by time and lines, counters only
log_lines = [
    "Timestamp               Ty Process[PID:TID]",
    "%s.100 Df launchd[1:2f2b54bb] [gui/%d/com.llm-legs.memlogd [777]:] exited due to exit(1), ran for 1200ms",
    "%s.200 Df launchd[1:2f2b54bb] [user/89/com.apple.mdworker.shared.05000000-0400-0000-0000-000000000000 [12]:] "
    "exited due to SIGKILL | sent by mds[134], ran for 72285ms",
    "%s.300 Df launchd[1:2f2b54bb] [gui/%d/com.vendor.sync [55]:] exited due to SIGSEGV, ran for 50ms",
    "%s.400 Df launchd[1:2f2b54bb] [pid/80032/com.apple.SetStoreUpdateService [80158]:] exited with exit reason "
    "(namespace: 15 code: 0x0) - OS_REASON_RUNNINGBOARD | <RBSTerminateContext| explanation:/private/secret>, ran for 9ms",
    "%s.500 Df dasd[157:2f25ffae] [com.apple.duetactivityscheduler:scoring] 501:com.apple.spotlight.pipeline:D98EA4, Decision: CP Score: 0.78}",
    "%s.600 Df dasd[157:2f25ffae] [com.apple.duetactivityscheduler:scoring] 501:com.apple.spotlight.pipeline:628B97:[",
    "\t{name: CPU Usage Policy, policyWeight: 5.0, response: {MNP, 0.00, [{[Max allowed CPU Usage level]: Required:90, Observed:99},]}}",
    " ], Decision: MNP}",
    "%s.700 Df dasd[157:2f25ffae] [com.apple.duetactivityscheduler:lifecycle] STARTED <_DASActivity: \"501:com.apple.spotlight.pipeline:D98EA4\", ...>",
    "%s.800 Df dasd[157:2f2575b3] [com.apple.duetactivityscheduler:BGSTHelper] Completed 501:com.apple.spotlight.pipeline (0x7825bf7480)",
    "%s.810 Df dasd[157:2f25ffae] [com.apple.duetactivityscheduler:scoring] 501:PDCardFileManager.RevocationCheck:1A2B3C, Decision: MNP}",
    "%s.820 Df dasd[157:2f25ffae] [com.apple.duetactivityscheduler:scoring] 501:com.google.keystone.update:4D5E6F, Decision: CP Score: 0.5}",
    "%s.900 Df spindump[86702:2eeea41a] [com.apple.spindump:logging] Hammerspoon [91820]: spin: not sampling due to conditions 0x400000000",
    "%s.950 Df spindump[86702:2eeea41a] [com.apple.spindump:logging] Dia Browser [38286]: slow hid response (0.9s): not sampling due to conditions 0x48"]


def stamp_log(stamp_at):
    filled = []
    for line in log_lines:
        values = [time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stamp_at))] if "%s" in line else []
        if "%d" in line:
            values.append(uid)
        filled.append(line % tuple(values) if values else line)
    put("log.txt", "\n".join(filled) + "\n")
    return filled


filled = stamp_log(now - 600)
open(os.path.join(work, "bin", "log"), "w").write(
    '#!/bin/bash\nprintf "%s\\n" "$*" >>"$SYSTEM_DOCTOR_FIX/log.calls"\n[ -n "${LOG_SLEEP:-}" ] && { head -2 "$SYSTEM_DOCTOR_FIX/log.txt"; sleep "$LOG_SLEEP"; }\n'
    'cat "$SYSTEM_DOCTOR_FIX/log.txt"\n')
os.chmod(os.path.join(work, "bin", "log"), 0o755)
os.environ["SYSTEM_DOCTOR_LOG"] = os.path.join(work, "bin", "log")
check(m.HARVEST[0][2:] == (300, 100000) and m.HARVEST[1][2:] == (150, 1200000) and m.HARVEST[2][2:] == (60, 20000)
      and m.COLLECT["harvest_every_s"] == 6 * 3600 and m.COLLECT["harvest_back_s"] == 11 * 3600,
      "the harvest's cadence, look-back and per-source time and line budgets: %s %s" % (m.HARVEST, m.COLLECT))
row = m.harvest(now)
exits = {r[0]: r for r in row["launchd"]}
check(exits["com.llm-legs.memlogd"] == ["com.llm-legs.memlogd", 1, 1.2, 1.2, 1, {"exit 1": 1}, "own"]
      and exits["com.vendor.sync"][4] == 1 and exits["com.vendor.sync"][5] == {"signal 11": 1}
      and exits["com.apple.mdworker.shared"][4] == 0 and exits["com.apple.mdworker.shared"][5] == {"signal 9": 1}
      and exits["com.apple.SetStoreUpdateService"][5] == {"OS_REASON_RUNNINGBOARD": 1},
      "launchd exits per label: runs, wall, longest, abnormal (non-zero exit or a crash signal) and kinds: %s" % exits)
check(row["das"] == [["com.apple.spotlight.pipeline", 1, 1, {"CP": 1, "MNP": 1}, "apple"], ["PDCardFileManager.RevocationCheck", 0, 0, {"MNP": 1}, "apple"],
                     ["com.google.keystone.update", 0, 0, {"CP": 1}, "third-party"]],
      "DAS verdicts, starts, completions; a bare activity name is an Apple daemon's: %s" % row["das"])
check(sorted(row["hangs"]) == [["Dia Browser", 0, 1, 0.9, "third-party"], ["Hammerspoon", 1, 0, 0.0, "own"]], "hangs per app: %s" % row["hangs"])
check(all(row["sources"][s]["cut"] is None and row["sources"][s]["to"] == round(now) and row["sources"][s]["lines"] == len(filled)
          and row["sources"][s]["from"] == round(now - 11 * 3600) for s in ("launchd", "das", "hangs")),
      "a first harvest reads 11 h back to now: %s" % row["sources"])
calls = open(os.path.join(fix, "log.calls")).read().splitlines()
check(len(calls) == 3 and all(c.startswith("show --style compact --start ") and " --predicate " in c for c in calls)
      and 'processID == 1 AND eventMessage CONTAINS "ran for"' in calls[0], "log show per source with its predicate: %s" % calls)
text = "".join(open(f).read() for f in glob.glob(os.path.join(work, "state", "harvest", "*.jsonl")))
check("secret" not in text and "sent by" not in text and "not sampling" not in text and "Max allowed" not in text,
      "the harvest keeps counters, never message bodies")
filled = stamp_log(now + 6 * 3600 - 600)
row = m.harvest(now + 6 * 3600, max_lines=3)
check(row["sources"]["launchd"]["cut"] == "lines" and row["sources"]["launchd"]["lines"] == 3
      and row["sources"]["launchd"]["from"] == round(now) and row["sources"]["launchd"]["to"] == round(m.log_time(filled[2][:23]))
      and len(row["launchd"]) == 2, "a harvest cut at its line budget keeps the lines it read and resumes after them: %s" % row["sources"]["launchd"])
os.environ["LOG_SLEEP"] = "5"
began = time.time()
row = m.harvest(now + 30 * 3600, budget_s=0.5)
del os.environ["LOG_SLEEP"]
check(all(row["sources"][s]["cut"] == "time" and row["sources"][s]["lines"] == 2 for s in ("launchd", "das", "hangs"))
      and time.time() - began < 3, "a harvest past its time budget is killed: %s in %.1f s" % (row["sources"], time.time() - began))
check(abs(row["sources"]["hangs"]["lost_s"] - (13 * 3600 + 600)) <= 1
      and row["sources"]["hangs"]["from"] == round(now + 19 * 3600),
      "a cursor older than the log's retention starts 11 h back and counts the lost seconds: %s" % row["sources"]["hangs"])
judge = m.Judge(now + 30 * 3600, None)
m.judge_launchd(judge, [], [{"t": now + 30 * 3600 - 60, "launchd": [["com.x.dies", 5, 1.0, 0.5, 3, {"exit 2": 3}, "own"]]}])
check([p["id"] for p in judge.problems] == ["job-loop:com.x.dies"] and judge.problems[0]["value"] == 3,
      "the log's abnormal exits alone name a dying job: %s" % judge.problems)

# ---- phase 3: footprints and disk counters of every process of this uid per tick
chrome = [(500, 1, os.getuid(), "0:00.10", start, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")]
put("ps", ps_rows(base + chrome))
put("ps-children", ps_rows(base + chrome + newborns))
json.dump({"100": [300 << 20, 1000, 5000, 7], "300": [100 << 20, 10, 20, 1], "400": [50 << 20, 0, 0, 0],
           "500": [200 << 20, 0, 0, 0]}, open(os.path.join(fix, "rusage.json"), "w"))
for name in os.listdir(os.path.join(work, "state", "ticks")):
    os.remove(os.path.join(work, "state", "ticks", name))
os.remove(state_path)
first = json.loads(cli("tick").stdout)
json.dump({"100": [310 << 20, 3000, 9000, 17], "300": [100 << 20, 10, 20, 1], "400": [50 << 20, 9, 9 << 20, 9],
           "500": [200 << 20, 100, 6000, 3]}, open(os.path.join(fix, "rusage.json"), "w"))
row = json.loads(cli("tick").stdout)
check(row["own_procs"] == 2 and row["usage_read"] == 3 and row["mem_top"] == [["statusline.sh", 310 << 20, "own"],
                                                                             ["Google Chrome", 200 << 20, "third-party"],
                                                                             ["Hammerspoon", 100 << 20, "own"]],
      "footprints of this uid's processes by tag, another uid's never read: %s" % row)
check(row["io_top"] == [["Google Chrome", 6000, 100, 3, "third-party"], ["statusline.sh", 4000, 2000, 10, "own"]],
      "disk bytes written, read and idle wakeups since the last tick, a same-uid app's too: %s" % row["io_top"])
check(row["usage_blind"] == [["xpcproxy", "apple"]], "a listed item with another uid's process is usage-blind: %s" % row["usage_blind"])
check(first["io_top"] == [], "the first tick has no deltas")
check(row["rss_total"] == (9 * 2048 + 1024) << 10 and ["Hammerspoon", 2048 << 10, 1, "own"] in row["rss_top"],
      "resident memory of every process on the machine, summed by tag with its process count: %s" % row["rss_top"])
read = {(r[0], r[1]): r[8] for r in m.cohort_sums([row])}
check(read == {("Google Chrome", "third-party"): 1, ("statusline.sh", "own"): 1, ("Hammerspoon", "own"): 1, ("xpcproxy", "apple"): 0},
      "the day's cohort marks which items' rusage every row read: %s" % read)
check({r[0]: r[8] for r in m.cohort_sums([row, {k: v for k, v in row.items() if k != "usage_blind"}])}["Google Chrome"] == 0,
      "a day holding a row from before every same-uid process was read leaves a third-party item unread")
os.environ["HARNESS_DOCTOR_DIR"] = os.path.join(work, "harness")
os.makedirs(os.path.join(work, "harness", "statusline"))
at = time.mktime(time.strptime("2026-10-13 12:00", "%Y-%m-%d %H:%M"))
with open(os.path.join(work, "harness", "statusline", "2026-10-13.tsv"), "w") as handle:
    for end, cpu in ((at + 30, "14000"), (at + 90, "4000"), (at - 10, "7000"), (at + 150, "9000"), (at + 40, "-")):
        handle.write("%d\t%d\tsid\t%s\t0\n" % (end * 1e6 - 50000, end * 1e6, cpu))
    handle.write("garbage\n")
spans = [{"t": at + 60, "dt": 60, "cpu_top": [["claude", 20.0, 12.0, "third-party"], ["claude", 3.0, 3.0, "own"]]},
         {"t": at + 120, "dt": 60, "cpu_top": [["claude", 2.0, 1.0, "third-party"]]}, {"t": at + 180, "dt": None}]
cpu = {(r[0], r[1]): r[2] for r in m.cohort_sums(spans)}
check(cpu == {(m.STATUSLINE, "own"): 18.0, ("claude", "third-party"): 9.0, ("claude", "own"): 1.0},
      "the statusline journal's render CPU inside covered spans moves off claude's reaped CPU to the statusline: %s" % cpu)
del os.environ["HARNESS_DOCTOR_DIR"]
saved_rusage = open(os.path.join(fix, "rusage.json")).read()
json.dump({}, open(os.path.join(fix, "rusage.json"), "w"))
row = json.loads(cli("tick").stdout)
doc = m.document(time.time(), time.time(), persist=False)
check(row["usage_read"] == 0 and "footprints" in doc["blind"], "unreadable own footprints are a blind collector: %s" % doc["blind"])
open(os.path.join(fix, "rusage.json"), "w").write(saved_rusage)

lines = "".join(line + "\n" for line in (
    "18:21:20.100000  WrData[A]  D=0x01  B=0x1000  /dev/disk3s1  /Users/someone/.cache/tool/a/b.json  0.000100 W Python.77",
    "18:21:20.200000  WrData[A]  D=0x02  B=0x3000  /dev/disk3s1  /Users/someone/.cache/tool/c.json  0.000100 W Python.78",
    "18:21:20.300000  PgOut[A]  D=0x03  B=0x8000  /dev/disk3s6  /System/Volumes/VM/swapfile0  0.000200 W kernel_task.0",
    "18:21:20.400000  RdData[A]  D=0x04  B=0x9000  /dev/disk3s1  /Users/someone/x/y  0.000100 W bash.5",
    "18:21:20.500000  WrMeta[A]  D=0x05  B=0x1000  /dev/disk7s1  0.000100 W launchd.1",
    "18:22:21.000000  WrData[A]  D=0x06  B=0x2000  /dev/disk7s1  /System/Volumes/Data/Volumes/Work/tmp/x/y  0.000100 W Python.9",
    "18:22:21.100000  WrData[A]  D=0x07  B=0x4000  /dev/disk3s1  /private/var/db/ssd-sampler/calibration  0.000100 W Python.3",
    "18:22:21.200000  WrData[A]  D=0x08  B=0x1000  /dev/disk3s1  /tmp/z  0.000100 W .4411",
    "18:22:21.300000  WrData[A]  D=0x09  B=0x1000  /dev/disk3s1  kuku/zz  0.000100 W mds.2",
    "18:22:21.400000  WrData[A]  D=0x0a  B=0x1000  0.000100 W odd.1",
    "18:22:21.500000  WrData[AT1]  D=0x0b  B=0x1000  /dev/disk3s1  private/var/folders/hh/q3x/T/tmpa/render.png  0.000100 W resvg.5"))
sampler = importlib.machinery.SourceFileLoader("ssd_sampler", os.path.join(root, "bin", "ssd-sampler")).load_module()
stats, sampled = sampler.aggregate(io.StringIO(lines))
out = json.loads(json.dumps({**stats, "rows": sorted([*k, *v] for k, v in sampled.items())}))
check(out["lines"] == 11 and out["rows"] == [
          ["?", "disk3s1", "/tmp", 4096, 1], ["Python", "disk3s1", "/private/var/db", 16384, 1],
          ["Python", "disk3s1", "~/.cache/tool", 16384, 2], ["Python", "disk7s1", "/Volumes/Work/tmp", 8192, 1],
          ["kernel_task", "disk3s6", "/System/Volumes/VM", 32768, 1], ["launchd", "disk7s1", "(none)", 4096, 1],
          ["mds", "disk3s1", "(rel)", 4096, 1], ["resvg", "disk3s1", "$TMPDIR", 4096, 1]],
      "ssd-sampler keeps write events by process, disk and directory, two levels below a home, the Data volume's "
      "firmlink prefix dropped, a slashless system path and the per-user temp folder named: %s" % out["rows"])
check(out["calls"] == {"WrData": [57344, 8], "PgOut": [32768, 1], "WrMeta": [4096, 1]} and out["calibration"] == 16384
      and out["first"] == 18 * 3600 + 21 * 60 + 20.1 and out["last"] == 18 * 3600 + 22 * 60 + 21.5 and out["cut"] is None
      and out["ticks"] == {"0 disk3s1": 16384, "0 disk3s6": 32768, "0 disk7s1": 4096, "6 disk7s1": 8192,
                           "6 disk3s1": 16384 + 4096 * 3},
      "ssd-sampler counts write bytes per call, per tick and device, and the calibration file's: %s" % out)
check({kind: slot[:2] + [len(slot[2])] for kind, slot in out["odd"].items()}
      == {"noproc": [4096, 1, 1], "rel": [4096, 1, 1], "nodev": [4096, 1, 1]}
      and out["odd"]["noproc"][2][0].endswith("W .4411"),
      "ssd-sampler keeps raw lines with no process, a relative path or no device: %s" % out["odd"])
work = os.path.dirname(os.environ["SSD_SAMPLER_DIR"])


def sample_off(tag, script, **patch): # -> probe, sample, seconds taken, its sample directory
    fake, out = os.path.join(work, "fake-fs-usage-" + tag), os.environ["SSD_SAMPLER_DIR"] + "-" + tag
    open(fake, "w").write("#!/bin/bash\n" + script)
    os.chmod(fake, 0o755)
    shutil.rmtree(out, ignore_errors=True)
    began = time.time()
    probe = subprocess.run([sys.executable, "-I", "-c", """
import importlib.machinery, json, os, sys, time
s = importlib.machinery.SourceFileLoader("sampler", sys.argv[1]).load_module()
s.FS_USAGE, s.TICK_S, s.CALIBRATION_B = sys.argv[2], 1, 2 << 20
for name, value in json.loads(sys.argv[3]).items():
    setattr(s, name, value)
s.os.geteuid = lambda: 0
s.internal = lambda dev: int(dev.startswith("disk3"))
count = [0]
def devices():
    count[0] += 1
    return {"internal:disk0": 10 ** 6 * count[0], "external:disk6": 3 * 10 ** 6 * count[0]}
s.devices = devices
remove = s.os.remove
s.os.remove = lambda path: (print("calibration", os.path.getsize(path)) if path.endswith("/calibration") else None,
                            remove(path))
s.run()
""", os.path.join(root, "bin", "ssd-sampler"), fake, json.dumps(patch)], capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, SSD_SAMPLER_DIR=out))
    took = time.time() - began
    names = [n for n in os.listdir(out) if n.endswith(".json")] if os.path.isdir(out) else []
    sample = json.load(open(os.path.join(out, names[0]))) if len(names) == 1 else None
    return probe, sample, took, out


LINE = ('  echo "$t  WrData[A]  D=0x01  B=0x1000  /dev/disk3s1  /Users/someone/.cache/tool/a  0.000100 W Python.7"\n'
        '  echo "$t  WrData[A]  D=0x11  B=0x2000  /dev/disk7s1  /Volumes/Work/x/y/z  0.000100 W rsync.8"\n')
# The four runs wait on real time, never on each other: they run side by side, each with its own fake and directory.
with concurrent.futures.ThreadPoolExecutor(4) as pool:
    sampled_off = [
        pool.submit(sample_off, "span", "for i in 1 2 3 4 5 6; do\n  t=$(/bin/date +%H:%M:%S).$((100000 + i))\n" + LINE +
                    "  sleep 0.5\ndone\necho 'fs_usage: lost events' >&2\n"),
        pool.submit(sample_off, "lag", "t=$(/bin/date -v-60S +%H:%M:%S).100000\n" + LINE + LINE + "exec /bin/sleep 30\n"),
        pool.submit(sample_off, "rss", "for i in $(seq 1 40); do\n  t=$(/bin/date +%H:%M:%S).100000\n" + LINE +
                    "  sleep 0.25\ndone\n", RSS_CUT_B=1),
        pool.submit(sample_off, "timeout", "exec /bin/sleep 30\n", SECS=1, GRACE_S=1)]
probe, sample, took, out = sampled_off[0].result()
check(probe.returncode == 0 and sample and "calibration %d" % (2 << 20) in probe.stdout,
      "ssd-sampler run writes the calibration file and one sample off fakes: %s %s" % (probe.stdout, probe.stderr[-800:]))
if sample:
    check(sample["v"] == 3 and sample["calibration"] == {"wrote": 2 << 20, "seen": 0}
          and sample["trace"]["exit"] == 0 and "lost events" in sample["trace"]["stderr"] and sample["trace"]["cut"] is None
          and 2 <= sample["trace"]["span"] <= 3 and sample["trace"]["lag_max"] < 2
          and sample["devices"]["internal:disk0"] > 0 and sample["devices"]["external:disk6"] == 3 * sample["devices"]["internal:disk0"]
          and sorted(r[:4] for r in sample["rows"]) == [["Python", "disk3s1", 1, "~/.cache/tool"], ["rsync", "disk7s1", 0, "/Volumes/Work/x"]]
          and len(sample["ticks"]) >= 2 and all(len(t) == 5 for t in sample["ticks"])
          and sum(t[1] for t in sample["ticks"]) > 0 and sum(t[4] for t in sample["ticks"]) > 0
          and sample["cost"]["cpu_s"] >= 0 and sample["cost"]["rss_max_b"] > 2 ** 20 and sample["cost"]["ran_s"] >= 2
          and sample["cost"]["wrote_b"] == 2 << 20
          and not os.path.exists(os.path.join(out, "calibration")),
          "ssd-sampler run: a v3 sample with the calibration write, fs_usage stderr, the traced span, device ticks and "
          "its own cost: %s" % {k: sample[k] for k in ("trace", "calibration", "devices", "ticks", "cost")})
probe, sample, took, out = sampled_off[1].result()
check(sample and sample["trace"]["cut"] == "lag" and sample["lines"] == 1 and sample["rows"] == [] and took < 8,
      "ssd-sampler stops a trace that lags 20 s behind its events, where the kernel starts dropping them: %s %.1f s %s"
      % (sample and sample["trace"], took, probe.stderr[-400:]))
probe, sample, took, out = sampled_off[2].result()
check(sample and sample["trace"]["cut"] == "rss" and took < 8,
      "ssd-sampler stops fs_usage past its memory cap: %s %.1f s %s" % (sample and sample["trace"], took, probe.stderr[-400:]))
probe, sample, took, out = sampled_off[3].result()
check(sample and sample["lines"] == 0 and took < 10 and sample["trace"]["exit"] not in (0, None),
      "ssd-sampler kills an fs_usage that outlives its timeout: %s %.1f s" % (sample and sample["trace"], took))
for run in sampled_off:
    shutil.rmtree(run.result()[3], ignore_errors=True)
shutil.rmtree(os.environ["SSD_SAMPLER_DIR"], ignore_errors=True)
ssd = os.environ["SSD_SAMPLER_DIR"]
os.makedirs(ssd)
now = time.time()
for name, end, devices, rows in (
        ("old", now - 8 * 86400, {"internal:disk0": 10 ** 9}, [["Python", "disk3s1", 1, "~/old", 10 ** 9, 1]]),
        ("v2", now - 60, {"internal:disk0": 10 ** 9}, [["Python", "disk3s1", 1, "/System/Volumes/Data", 10 ** 9, 1]]),
        ("a", now - 3600, {"internal:disk0": 1100, "external:disk6": 5000},
         [["kernel_task", "disk3s6", 1, "/System/Volumes/VM", 400, 9], ["Python", "disk7s1", 0, "/Volumes/Work", 5000, 9],
          ["Python", "disk3s1", 1, "~/.cache/tool", 100, 3], ["Python", "disk3s1", 1, "/private/var/db", 100, 1]]),
        ("b", now - 600, {"internal:disk0": 1000}, [["kernel_task", "disk3s6", 1, "/System/Volumes/VM", 200, 2]])):
    json.dump({"v": 2 if name == "v2" else 3, "start": end - 600, "end": end, "devices": devices, "rows": rows,
               "calibration": {"wrote": 100, "seen": 100 if name == "a" else 0}},
              open(os.path.join(ssd, name + ".json"), "w"))
sampled = m.document(now, now, persist=False)["measures"]["ssd_sampled"]
check(sampled == {"samples": 2, "minutes": 20, "newest": now - 600, "attributed": 0.35,
                  "top": [["kernel_task", "swap", 0.3], ["Python", "~/.cache/tool", 0.05]]},
      "the week's v3 root samples: each process and directory's share of the internal disks' bytes, external rows and "
      "the sampler's own calibration file out: %s"
      % sampled)
open(os.environ["SSD_SAMPLER_PLIST"], "w").close()
os.utime(os.environ["SSD_SAMPLER_PLIST"], (now - 20 * 3600, now - 20 * 3600))
check("ssd-sampler" not in m.document(now, now, persist=False)["blind"], "a sample younger than 15 h keeps the sampler seen")
check("ssd-sampler" in m.document(now + 16 * 3600, now + 16 * 3600, persist=False)["blind"],
      "an installed sampler with no sample for 15 h is a blind collector")
os.remove(os.environ["SSD_SAMPLER_PLIST"])
shutil.rmtree(ssd)

# ---- phase 3: LLM profiles on disk against the menubar roster
saved_env = dict(os.environ)
for key in list(os.environ):
    if key.startswith(("CLAUDEB_", "CODEXB_", "GEMINIB_", "GROKB_", "LLM_LIMITS_", "OPENCODE_GO")):
        del os.environ[key]
home = os.environ["HOME"]
os.environ["CLAUDEB_DIR"] = os.path.join(home, ".claude-profiles", ".claudeb")
made = [".gemini-profiles/abel/.gemini", ".gemini-profiles/Bad_Name/x", ".gemini-profiles/.geminib-state",
        ".gemini/antigravity", ".grok/bin", ".codex-profiles/a/sessions", ".kimi-work/w", ".claude/projects/p",
        ".cursor-tutor/t", ".notes/n", ".codex/sessions", ".llm-limits.json.lock"]
web = next(folder for vendor, label, folder in m.account_stores() if label == "gemini-web browser profile")
quota = next(folder for vendor, label, folder in m.account_stores() if label == "quota cache")
made += [os.path.relpath(os.path.join(web, name), home) for name in ("abel", "zed")] + [os.path.relpath(quota, home)]
for rel in made:
    os.makedirs(os.path.join(home, rel), exist_ok=True)
old = time.time() - 9 * 86400
for top, dirs, files in os.walk(os.path.join(home, ".kimi-work")):
    for name in dirs + files + [""]:
        os.utime(os.path.join(top, name) if name else top, (old, old))
roster = m.account_roster
m.account_roster = lambda vendor: None if vendor == "grok" else roster(vendor) - {"main"} if vendor == "codex" else roster(vendor)
census = m.llm_profiles({os.path.join(home, ".gemini-profiles", "abel"): 2048},
                        {"stores": [{"globs": ["~/.claude/projects/*/*.jsonl", "~/*.log"]}], "ignore": [{"glob": "~/.cursor-tutor"}]},
                        time.time())
m.account_roster = roster
by_path = {r["path"]: r for r in census}
check({p: r["status"] for p, r in by_path.items()} == {
          "~/.codex-profiles/a": "menu", "~/.codex": "home", "~/.gemini": "menu", "~/.gemini-profiles/abel": "menu",
          "~/.gemini-profiles/Bad_Name": "off", "~/.grok": "unknown", "~/.kimi-work": "unknown",
          m.tilde(os.path.join(web, "abel")): "menu", m.tilde(os.path.join(web, "zed")): "off"}
      and by_path[m.tilde(os.path.join(web, "zed"))].get("owner") == "llm-doctor"
      and not by_path["~/.gemini-profiles/Bad_Name"].get("owner"),
      "every profile against its vendor's roster (a name the roster rejects is off the menu, a main home it dropped "
      "home, an unreadable roster unknown, a browser profile off it the llm doctor's remnant), and LLM-named home "
      "directories no profile root, account store or registry entry knows but a lock, a glob at HOME's top registering none of them: %s" % census)
check(by_path["~/.gemini-profiles/abel"]["mb"] == 2 and by_path["~/.kimi-work"]["mb"] is None
      and 8.9 < by_path["~/.kimi-work"]["age_d"] < 9.1 and by_path["~/.gemini-profiles/abel"]["age_d"] < 0.1,
      "a profile carries its du size and its last change: %s" % census)
judge = m.Judge(time.time(), None)
m.judge_logstores(judge, [{"t": time.time(), "stores": [], "profiles": census}])
orphans = {p["id"]: p for p in judge.problems if p["rule"] == "orphan-profile"}
check(list(orphans) == ["orphan-profile:~/.gemini-profiles/Bad_Name"] and orphans["orphan-profile:~/.gemini-profiles/Bad_Name"]["cause"] is None,
      "only a named profile off the menu is a problem, for the owner to decide (no fixer), a browser profile left to the "
      "llm doctor: %s" % list(orphans))
for rel in {r.split("/")[0] for r in made}:
    shutil.rmtree(os.path.join(home, rel))
os.environ.clear()
os.environ.update(saved_env)

# ---- phase 3: a profile too big, a vanished one, and the night's tidy judge moving garbage to the Trash
now = time.time()
def tree(rel, age_days=40, name="f"):
    folder = os.path.join(home, rel)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, name)
    open(path, "w").write("x")
    at = now - age_days * 86400
    os.utime(path, (at, at))
for rel in (".kimi-work/bin", ".kimi-fresh", ".gemini-profiles/Bad_Name", ".gemini-web/profiles/abel/Model"):
    tree(rel)
tree(".kimi-fresh", 1, "new")
tree(".gemini-web/profiles/abel/Default", 40, "Cookies")
census = [{"label": "home", "name": ".kimi-work", "path": "~/.kimi-work", "mb": 137, "age_d": 40, "status": "unknown"},
          {"label": "home", "name": ".kimi-fresh", "path": "~/.kimi-fresh", "mb": 1, "age_d": 40, "status": "unknown"},
          {"label": "home", "name": ".kimi-new", "path": "~/.kimi-new", "mb": 1, "age_d": 2, "status": "unknown"},
          {"label": "gemini", "name": "Bad_Name", "path": "~/.gemini-profiles/Bad_Name", "mb": 1, "age_d": 9, "status": "off"},
          {"label": "gemini-web", "name": "abel", "path": "~/.gemini-web/profiles/abel", "mb": 5000, "age_d": 1,
           "status": "menu", "owner": "llm-doctor"},
          {"label": "gemini", "name": "main", "path": "~/.gemini", "mb": 5000, "age_d": 1, "status": "home"},
          {"label": "gemini", "name": "gone", "path": "~/.gemini-profiles/gone", "mb": 9000, "age_d": 99, "status": "off"}]
os.makedirs(os.path.join(home, ".gemini"), exist_ok=True)
judge = m.Judge(now, None)
m.judge_logstores(judge, [{"t": now, "stores": [], "profiles": census}])
sized = sorted(p["id"] for p in judge.problems if p["rule"] in ("profile-size", "orphan-profile"))
check(sized == ["orphan-profile:~/.gemini-profiles/Bad_Name", "profile-size:~/.gemini-web/profiles/abel"],
      "a profile past 3 GB is a problem, a default home never, a vanished path neither: %s" % sized)
check([p["path"] for p in m.logstores_view([{"t": now, "stores": [], "total_bytes": 0, "profiles": census}])["profiles"]]
      == ["~/.kimi-work", "~/.kimi-fresh", "~/.gemini-profiles/Bad_Name", "~/.gemini-web/profiles/abel", "~/.gemini"],
      "the menu drops a profile deleted since the scan")
tidy_was, du_was, state_was = dict(m.TIDY), os.environ["SYSTEM_DOCTOR_DU"], os.environ["SYSTEM_DOCTOR_DIR"]
m.TIDY["child_mb"] = 0
os.environ.update(SYSTEM_DOCTOR_DU="/usr/bin/du", SYSTEM_DOCTOR_DIR=os.path.join(work, "tidy-state"))
candidates = m.tidy_candidates(census, now, [{"t": now - 86400, "path": "~/.kimi-kept", "verdict": "keep"}])
check([(c["path"], c["kind"]) for c in candidates] == [("~/.kimi-work", "dir"), ("~/.gemini-profiles/Bad_Name", "dir"),
                                                        ("~/.gemini-web/profiles/abel/Model", "inside")],
      "candidates: an idle unknown dir, a profile off the menu, a folder without credentials inside one too big; never "
      "a dir with a file changed this week, a home, a menu profile itself or a vanished path: %s" % candidates)
fake = os.path.join(work, "fake-worker-run")
open(fake, "w").write("""#!/bin/bash
case $1 in
  start) [ -e "$FAKE_TIDY_FAIL" ] && { echo boom >&2; exit 1; }; while [ "$1" != --brief ]; do shift; done; cp "$2" "$FAKE_TIDY_BRIEF"; echo "RUN: r1" ;;
  wait) echo "STATUS: done" ;;
  report) printf 'STATUS: done\\nRESULT:\\n'; cat "$FAKE_TIDY_VERDICTS" ;;
esac
""")
os.chmod(fake, 0o755)
os.environ.update(SYSTEM_DOCTOR_WORKER_RUN=fake, FAKE_TIDY_BRIEF=os.path.join(work, "tidy-brief.md"),
                  FAKE_TIDY_VERDICTS=os.path.join(work, "tidy-verdicts"), FAKE_TIDY_FAIL=os.path.join(work, "tidy-fail"))
open(os.environ["FAKE_TIDY_VERDICTS"], "w").write("\n".join(json.dumps(v) for v in (
    {"path": "~/.kimi-work", "verdict": "garbage", "why": "an abandoned CLI"},
    {"path": "~/.gemini-profiles/Bad_Name", "verdict": "keep", "why": "holds a keychain"},
    {"path": "~/.gemini-web/profiles/abel/Model", "verdict": "garbage", "why": "Chrome downloads it again"},
    {"path": "~/.kimi-odd", "verdict": "delete", "why": "a word the brief never offered"},
    {"path": "~/Documents", "verdict": "garbage", "why": "invented"})) + "\n")
m.append_row("logstores", {"t": now - 60, "stores": [], "profiles": census})
dry = m.tidy(now, dry_run=True)
check([r["action"] for r in dry] == ["dry run", "kept", "dry run"] and os.path.isdir(os.path.join(home, ".kimi-work"))
      and not os.path.exists(os.path.join(os.environ["SYSTEM_DOCTOR_DIR"], "tidy.jsonl")),
      "a dry run judges and moves or records nothing: %s" % dry)
brief = open(os.environ["FAKE_TIDY_BRIEF"]).read()
check(brief.startswith("ROUND: none\n") and "## ~/.kimi-work" in brief and "- bin 0 MB" in brief
      and "inside the profile ~/.gemini-web/profiles/abel" in brief and "Cookies" not in brief,
      "the brief names each candidate with its top folders: %s" % brief[-600:])
tree(".kimi-odd/bin")
m.append_row("logstores", {"t": now - 50, "stores": [], "profiles": census + [
    {"label": "home", "name": ".kimi-odd", "path": "~/.kimi-odd", "mb": 1, "age_d": 40, "status": "unknown"}]})
done = m.tidy(now)
trash = os.listdir(os.path.join(home, ".Trash"))
check([(r["path"], r["action"]) for r in done] == [("~/.kimi-work", "trashed"), ("~/.gemini-profiles/Bad_Name", "kept"),
                                                    ("~/.gemini-web/profiles/abel/Model", "trashed")]
      and sorted(t.split(" ")[0] for t in trash) == [".kimi-work", "Model"]
      and not os.path.exists(os.path.join(home, ".kimi-work")) and os.path.isdir(os.path.join(home, ".gemini-web/profiles/abel/Default"))
      and os.path.isdir(os.path.join(home, ".gemini-profiles/Bad_Name")) and os.path.isdir(os.path.join(home, ".kimi-odd")),
      "garbage goes to the Trash, a kept, invented or unknown-word path stays: %s %s" % (done, trash))
view = m.logstores_view([{"t": now - 60, "stores": [], "total_bytes": 0, "profiles": census}])
check([t["path"] for t in view["tidied"]] == ["~/.kimi-work", "~/.gemini-web/profiles/abel/Model"]
      and "~/.kimi-work" not in [p["path"] for p in view["profiles"]],
      "the menu lists what went to the Trash this week, gone from the profiles: %s" % view["tidied"])
again = m.tidy_candidates(census, now, m.read_jsonl(os.path.join(os.environ["SYSTEM_DOCTOR_DIR"], "tidy.jsonl")))
check(again == [], "a kept verdict is not asked again, a trashed path is gone: %s" % again)
tree(".kimi-late", 40)
late = {"path": "~/.kimi-late", "kind": "dir", "mb": 1}
check(m.refusal(late, now) is None, "an idle dir passes the move's re-check")
tree(".kimi-late", 0, "touched")
check(m.refusal(late, now) == "changed within 7 days", "a dir written after the listing is refused at the move")
os.symlink(os.path.join(home, ".kimi-late"), os.path.join(home, ".kimi-link"))
check(m.refusal({"path": "~/.kimi-link", "kind": "dir"}, now) == "gone or a link", "a link is never moved")
census.append({"label": "home", "name": ".kimi-other", "path": "~/.kimi-other", "mb": 1, "age_d": 40, "status": "unknown"})
tree(".kimi-other/bin")
m.append_row("logstores", {"t": now - 30, "stores": [], "profiles": census})
open(os.environ["FAKE_TIDY_FAIL"], "w").close()
failed = m.tidy(now)
check(len(failed) == 1 and failed[0]["action"] == "judge failed" and "boom" in failed[0]["why"]
      and os.path.isdir(os.path.join(home, ".kimi-other")), "a failed judge moves nothing and says why: %s" % failed)
m.TIDY.clear()
m.TIDY.update(tidy_was)
os.environ.update(SYSTEM_DOCTOR_DU=du_was, SYSTEM_DOCTOR_DIR=state_was)
for rel in (".kimi-fresh", ".kimi-odd", ".gemini-profiles", ".gemini-web", ".gemini", ".kimi-late", ".kimi-link", ".kimi-other", ".Trash"):
    path = os.path.join(home, rel)
    os.remove(path) if os.path.islink(path) else shutil.rmtree(path)
shutil.rmtree(os.path.join(work, "tidy-state"))
for key in ("SYSTEM_DOCTOR_WORKER_RUN", "FAKE_TIDY_BRIEF", "FAKE_TIDY_VERDICTS", "FAKE_TIDY_FAIL"):
    del os.environ[key]

# ---- Background: every program and launchd job grouped by where it comes from, explained by one night worker
state_was, agents_was = os.environ["SYSTEM_DOCTOR_DIR"], os.environ["SYSTEM_DOCTOR_AGENTS_DIRS"]
bg = os.path.join(work, "bg")
os.environ.update(SYSTEM_DOCTOR_DIR=os.path.join(bg, "state"), SYSTEM_DOCTOR_AGENTS_DIRS=os.path.join(bg, "agents"))
for folder in ("state", "agents"):
    os.makedirs(os.path.join(bg, folder))
repos_real = m.repos_top()
for rel, text in (("find-truth/pipeline/run_watch.sh", "#!/bin/bash\n"),):
    os.makedirs(os.path.dirname(os.path.join(repos_real, rel)), exist_ok=True)
    open(os.path.join(repos_real, rel), "w").write(text)
loose = {".local/libexec/wrapped": "#!/bin/bash\nexec /bin/bash %sfind-truth/pipeline/run_watch.sh \"$@\"\n" % repos_real,
         ".local/libexec/envset": "#!/bin/sh\nexec /bin/launchctl setenv A b\n",
         ".local/libexec/memlogd": "#!/bin/bash\necho\n", ".local/libexec/mine": "#!/bin/bash\necho\n"}
for rel, text in loose.items():
    os.makedirs(os.path.dirname(os.path.join(home, rel)), exist_ok=True)
    open(os.path.join(home, rel), "w").write(text)
os.makedirs(os.path.join(home, ".local/bin"), exist_ok=True)
os.symlink(os.path.join(repos_real, "llm-legs/bin/worker-run"), os.path.join(home, ".local/bin/tool"))
check([m.origin(path) for path in (
    repos_real + "llm-legs/bin/memlogd", repos_real + "find-truth/pipeline/run_watch.sh", home + "/.claude/hooks/x.sh",
    home + "/.local/libexec/wrapped", home + "/.local/libexec/memlogd", home + "/.local/libexec/mine", home + "/.local/bin/tool",
    "/Applications/Dia.app/Contents/Frameworks/Helpers/Browser Helper.app/Contents/MacOS/Browser Helper",
    "/System/Applications/Mail.app/Contents/MacOS/Mail",
    "/opt/homebrew/Cellar/python@3.13/Frameworks/Python.framework/Resources/Python.app/Contents/MacOS/Python",
    home + "/.nvm/versions/node/v24/lib/node_modules/@openai/codex-darwin-arm64/vendor/codex",
    home + "/.local/share/claude/versions/2.1", "/Library/Application Support/find-truth/guard.sh",
    "/Library/Application Support/Vendor/tool", "/Library/PrivilegedHelperTools/com.macpaw.CleanMyMac4.Agent",
    "/usr/libexec/trustd", home + "/bin/odd.sh", home + "/Downloads/x/y/z.sh", "/private/tmp/x.sh", "relative", None)]
      == ["harness", "find-truth", "harness", "find-truth", "harness", "~/.local/libexec", "harness", "Dia", "Apple",
          "Homebrew", "codex", "Claude Code", "find-truth", "Vendor", "Macpaw", "Apple", "~/bin", "~/Downloads/x", None,
          None, None],
      "a file's group: a sweep repository is the harness, another repository its own, a wrapper the repository it names, "
      "an installed copy the sweep repository with its name, the outermost app, Homebrew before its Python.app, a node "
      "package, ~/.local/share and Application Support folders, a helper tool's vendor, Apple, a home folder")
check([m.item_group(*args) for args in (
    ("bash", "apple", "/bin/bash", None), ("(bash)", "third-party", None, None), ("WindowServer", "apple", None, None),
    ("find-truth/pipeline/run_watch.sh", "own", None, None), ("llm-legs/bin/worker-run", "own", None, None),
    ("Hammerspoon", "third-party", None, None), ("tool", "third-party", "/opt/homebrew/bin/tool", None),
    ("statusline.sh", "own", home + "/.cache/snap/statusline.sh", None), ("lonely.sh", "own", home + "/.cache/snap/lonely.sh", None),
    ("ghost", "third-party", None, {"runs": "/Applications/Ghost.app/Contents/MacOS/ghost"}), ("ghost", "third-party", None, None))]
      == ["other", "other", "Apple", "find-truth", "harness", "harness", "harness", "harness", "~/.cache/snap", "Ghost", "other"],
      "an item's group: inline commands are other before Apple, a repository tag its repository, an own app the harness, "
      "a command in ~/.local/bin before its place, a script copy in a home folder the sweep repository with its name")
check([m.schedule(plist) for plist in (
    {"KeepAlive": True, "StartInterval": 60}, {"StartInterval": 300}, {"StartInterval": 7200}, {"StartInterval": 172800},
    {"StartCalendarInterval": {"Hour": 9, "Minute": 30}}, {"StartCalendarInterval": {"Hour": 10, "Weekday": 1}},
    {"StartCalendarInterval": {"Minute": 5}}, {"StartCalendarInterval": [{"Hour": 1}, {"Hour": 2}]},
    {"WatchPaths": ["/x"]}, {"RunAtLoad": True}, {})]
      == ["always on", "every 5 min", "every 2 h", "every 2 d", "daily 09:30", "weekly 10:00", "hourly :05",
          "2 times a day", "on file change", "at login", "on demand"], "a job's schedule in words")
for label, args, extra in (("com.ft.watch", [home + "/.local/libexec/wrapped"], {"StartCalendarInterval": {"Hour": 9, "Minute": 30}}),
                           ("com.gone.job", ["/bin/bash", home + "/.local/bin/gone.sh"], {"KeepAlive": True}),
                           ("com.env.set", [home + "/.local/libexec/envset"], {"RunAtLoad": True}),
                           ("com.dup.a", ["/Applications/Dup.app/Contents/MacOS/Dup"], {}),
                           ("com.dup.b", ["/Applications/Dup.app/Contents/MacOS/Dup"], {}),
                           ("com.egor.hs", ["/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon"], {"KeepAlive": True})):
    with open(os.path.join(bg, "agents", label + ".plist"), "wb") as handle:
        plistlib.dump(dict({"Label": label, "ProgramArguments": args}, **extra), handle)
check(all(job["loaded"] is None for job in m.background_jobs().values()), "no dumpstate yet: whether launchd holds a job is unknown")
m.write_json(os.path.join(bg, "state", "dumpstate-state.json"),
             {"t": now, "services": {"gui/501/com.ft.watch": [3, "exit 0"], "gui/501/com.dup.a": [1, None]}})
jobs = m.background_jobs()
plists = os.path.join(bg, "agents")
check(sorted(jobs) == ["Dup", "Hammerspoon", "com.dup.b", "com.env.set", "find-truth/pipeline/run_watch.sh", "gone.sh"]
      and {k: v for k, v in jobs["find-truth/pipeline/run_watch.sh"].items() if k != "owner"} == {
          "label": "com.ft.watch", "plist": plists + "/com.ft.watch.plist", "schedule": "daily 09:30",
          "runs": repos_real + "find-truth/pipeline/run_watch.sh", "missing": False, "loaded": True}
      and jobs["gone.sh"]["missing"] is True and jobs["gone.sh"]["loaded"] is False
      and jobs["com.env.set"]["runs"] == home + "/.local/libexec/envset" and jobs["Dup"]["loaded"] is True,
      "every plist is a job named as the ticks name what it runs (through its wrapper; by label when that is an Apple "
      "command or a second plist runs the same file), with its schedule, a gone file and launchd's hold: %s" % jobs)
m.write_json(os.path.join(bg, "state", "origins.json"), {"claude": home + "/.local/share/claude/versions/2.1"})
m.write_json(m.about_path(), {"Dup": {"about": "a dup app", "t": now}})
score = {"covered_days": 7.0, "items": [
    {"name": "llm-legs/bin/worker-run", "owner": "own", "B": 92.0, "terms": {"C": 92.0, "L": 0.5},
     "per_day": {"S": 7948800.0, "C": 79488.0, "L": 720.0}, "unknown": []},
    {"name": "claude", "owner": "third-party", "B": 3.0, "terms": {"L": 3.0}, "per_day": {"S": 259200.0, "L": 4320.0},
     "unknown": ["W", "D"]},
    {"name": "claude", "owner": "own", "B": 2.0, "terms": {"C": 2.0}, "per_day": {"C": 1728.0}, "unknown": ["W"]},
    {"name": "WindowServer", "owner": "apple", "B": 1.5, "terms": {"C": 1.5}, "per_day": {"C": 1296.0}, "unknown": []},
    {"name": "com.dup.a", "owner": "third-party", "B": 0.5, "terms": {"L": 0.5}, "per_day": {"L": 720.0}, "unknown": []},
    {"name": "com.dup.b", "owner": "third-party", "B": 0.5, "terms": {"L": 0.5}, "per_day": {"L": 720.0}, "unknown": []},
    {"name": "Dup", "owner": "third-party", "B": 0.2, "terms": {"C": 0.2}, "per_day": {"C": 172.8}, "unknown": ["W"]},
    {"name": "llm-legs/bin/statusline.sh", "owner": "own", "B": 0.05, "terms": {"C": 0.05}, "per_day": {"C": 43.2}, "unknown": []},
    {"name": "tiny", "owner": "third-party", "B": 0.001, "terms": {"C": 0.001}, "per_day": {"C": 0.9}, "unknown": []}]}
items_was = m.BACKGROUND["items"]
m.BACKGROUND["items"] = 1
view = m.background(score, now)
m.BACKGROUND["items"] = items_was
found = {i["name"]: i for g in view["groups"] for i in g["items"]}
check([(g["name"], g["B"], [i["name"] for i in g["items"]]) for g in view["groups"]] == [
    ("harness", 92.0, ["llm-legs/bin/worker-run", "Hammerspoon"]), ("Claude Code", 3.0, ["claude"]),
    ("Apple", 1.5, ["WindowServer"]), ("Dup", 0.5, ["Dup", "com.dup.b"]),
    ("find-truth", 0.0, ["find-truth/pipeline/run_watch.sh"]), ("~/.local/bin", 0.0, ["gone.sh"]),
    ("~/.local/libexec", 0.0, ["com.env.set"])],
      "groups by their heaviest item: a group past its row cap keeps its jobs and items at the limit, a launches row "
      "named by label joins its job, the same name of two owners is one row, a quiet non-job item is dropped: %s"
      % [(g["name"], [i["name"] for i in g["items"]]) for g in view["groups"]])
check(found["claude"]["terms"] == {"L": 3.0, "C": 2.0} and found["claude"]["per_day"]["S"] == 259200.0
      and found["claude"]["unknown"] == ["W"]
      and found["claude"]["place"] == "~/.local/share/claude/versions/2.1" and found["claude"]["job"] is None
      and found["Dup"]["terms"] == {"C": 0.2, "L": 0.5} and found["Dup"]["about"] == "a dup app"
      and found["Dup"]["job"] == {"label": "com.dup.a", "plist": plists + "/com.dup.a.plist", "schedule": "on demand",
                                  "missing": True, "loaded": True}
      and found["Hammerspoon"]["B"] == 0.0 and found["gone.sh"]["place"] == "~/.local/bin/gone.sh",
      "an item carries its merged terms, the place the ticks saw, its job without internals and the night's about: %s"
      % [found[k] for k in ("claude", "Dup")])
blind = m.background({"covered_days": 3.0, "items": None}, now)
check(all(i["B"] is None for g in blind["groups"] for i in g["items"]) and all(g["B"] is None for g in blind["groups"])
      and blind["covered_days"] == 3.0, "before 7 covered days a job's cost is unknown, never 0")
m.write_json(os.path.join(bg, "state", "latest.json"), {"background": view})
explain_was = dict(m.EXPLAIN)
m.EXPLAIN["max"] = 5
check([i["name"] for i in m.explain_candidates(view, {"Dup": {}})] == [
    "llm-legs/bin/worker-run", "claude", "WindowServer", "com.dup.b", "Hammerspoon"],
      "the night explains the heaviest unexplained items: an Apple one at its limit, a quiet one only as a job")
os.environ.update(SYSTEM_DOCTOR_WORKER_RUN=fake, FAKE_TIDY_BRIEF=os.path.join(bg, "brief.md"),
                  FAKE_TIDY_VERDICTS=os.path.join(bg, "answers"), FAKE_TIDY_FAIL=os.path.join(bg, "fail"))
open(os.environ["FAKE_TIDY_VERDICTS"], "w").write("\n".join([
    json.dumps({"name": "llm-legs/bin/worker-run", "about": "starts the cheap workers"}),
    json.dumps({"name": "claude", "about": "  "}), json.dumps({"name": "invented", "about": "x"}), "not json",
    "`" + json.dumps({"name": "WindowServer", "about": "draws the screen"}) + "`"]) + "\n")
dry = m.explain(now, dry_run=True)
check([(r["name"], r["action"]) for r in dry] == [("llm-legs/bin/worker-run", "dry run"), ("WindowServer", "dry run")]
      and m.read_json(m.about_path(), {}) == {"Dup": {"about": "a dup app", "t": now}},
      "a dry run asks and records nothing: %s" % dry)
brief = open(os.environ["FAKE_TIDY_BRIEF"]).read()
check(brief.startswith("ROUND: none\n") and "## llm-legs/bin/worker-run" in brief
      and "- costs 92.00 of its limit a day, mostly 79488 cpu-s a day" in brief
      and "- launchd job com.dup.b (%s/com.dup.b.plist), on demand, its file is gone" % plists in brief
      and "## Dup\n" not in brief, "the brief names each item with its group, place, job and cost: %s" % brief[-700:])
done = m.explain(now)
abouts = m.read_json(m.about_path(), {})
check([r["action"] for r in done] == ["explained", "explained"] and abouts["llm-legs/bin/worker-run"]["about"]
      == "starts the cheap workers" and abouts["WindowServer"]["about"] == "draws the screen" and "invented" not in abouts
      and "claude" not in abouts, "an answer for an asked name lands in about.json, a blank or invented one never: %s" % abouts)
check("WindowServer" not in [i["name"] for i in m.explain_candidates(view, abouts)], "an explained item is not asked again")
open(os.environ["FAKE_TIDY_VERDICTS"], "w").write(json.dumps({"name": "claude", "about": "the Claude Code CLI"}) + "\n")
printed = cli("explain", "--dry-run")
check(printed.returncode == 0 and printed.stdout == "dry run\tclaude\tthe Claude Code CLI\n",
      "explain prints action, name and about per row: %r" % printed.stdout)
open(os.environ["FAKE_TIDY_FAIL"], "w").close()
failed = m.explain(now)
check(len(failed) == 1 and failed[0]["action"] == "judge failed" and "boom" in failed[0]["about"]
      and m.read_json(m.about_path(), {}) == abouts, "a failed judge records nothing and says why: %s" % failed)
check(cli("explain").returncode == 1, "explain exits 1 when its judge failed")
m.EXPLAIN.clear()
m.EXPLAIN.update(explain_was)
for key in ("SYSTEM_DOCTOR_WORKER_RUN", "FAKE_TIDY_BRIEF", "FAKE_TIDY_VERDICTS", "FAKE_TIDY_FAIL"):
    del os.environ[key]
os.environ.update(SYSTEM_DOCTOR_DIR=state_was, SYSTEM_DOCTOR_AGENTS_DIRS=agents_was)
for rel in (".local", ".claude"):
    shutil.rmtree(os.path.join(home, rel), ignore_errors=True)
shutil.rmtree(bg)
shutil.rmtree(os.path.join(repos_real, "find-truth"))

# ---- phase 3: the cohort score at its edges, amortized over >= 7 days
check(m.COHORT["cpu_s"] == 864 and m.COHORT["wakes"] == 86400 and m.COHORT["writes_b"] == m.GIB and m.COHORT["reads_b"] == 100 * m.GIB
      and m.COHORT["footprint_b"] == 512 * 2 ** 20 and "births" not in m.COHORT and m.COHORT["launches"] == 1440
      and m.COHORT["review"] == 1 and m.COHORT["heavy"] == 5 and m.COHORT["days"] == 7, "the cohort divisors are the design's: %s" % m.COHORT)


def week(entries, days=7, covered=86400):
    return [{"day": m.local_day(now - i * 86400), "covered_s": covered, "cohort": entries} for i in range(days)]


def score(entries, launches=(), days=7, covered=86400):
    found = m.cohort_score(week(entries, days, covered), list(launches), now)
    return {(i["name"], i["owner"]): i for i in found["items"]} if found["items"] is not None else found


for index, (term, total) in enumerate((("C", 864), ("D", m.GIB), ("R", 100 * m.GIB), ("W", 86400))):
    values = [0.0] * 6
    values[["C", "S", "D", "R", "W"].index(term)] = total
    at = score([["edge", "own"] + values])[("edge", "own")]
    under = [0.0] * 6
    under[["C", "S", "D", "R", "W"].index(term)] = total * 0.999
    check(abs(at["B"] - 1) < 1e-9 and at["terms"][term] == 1 and score([["edge", "own"] + under])[("edge", "own")]["B"] < 1,
          "%s at its divisor a day scores B 1, just under it less: %s" % (term, at))
born = score([["worker-run", "own", 432, 86400 * 92, 0, 0, 0, 0]])[("worker-run", "own")]
check(abs(born["B"] - 0.5) < 1e-9 and "S" not in born["terms"] and born["per_day"]["S"] == 86400 * 92
      and "S" not in born["unknown"],
      "92 births a second score nothing, a start's cost is its parent's C; births stay in per_day as a hint: %s" % born)
held = score([["fat", "own", 0, 0, 0, 0, 0, 512 * 2 ** 20 * 86400]])[("fat", "own")]
half = score([["fat", "own", 0, 0, 0, 0, 0, 512 * 2 ** 20 * 43200]])[("fat", "own")]
check(abs(held["B"] - 1) < 1e-9 and abs(half["B"] - 0.5) < 1e-9,
      "512 MiB held under pressure all day scores 1, under pressure half the day 0.5: %s %s" % (held, half))
crowded = [{"t": now, "dt": 60, "comp_share": 0.5, "cpu_top": [["busy%d" % i, 1.0, "own"] for i in range(m.COHORT["items_day"])],
            "mem_top": [["fat", 2 ** 30, "own"]]}]
check("fat" in [r[0] for r in m.cohort_sums(crowded)],
      "the day's cut ranks memory held under pressure beside the other terms: %s" % m.cohort_sums(crowded)[-1])
spawny = [dict(crowded[0], mem_top=[], births_s=1000, births_seen=10, births_top=[["spawny", 10, "own"]])]
check("spawny" not in [r[0] for r in m.cohort_sums(spawny)],
      "the day's cut never ranks by births, which no B scores: %s" % m.cohort_sums(spawny)[:2])
launches = [{"t": now - 3600, "jobs": [{"name": "com.apple.thing", "owner": "apple", "runs": 1440 * 7}]}]
apple = score([], launches)[("com.apple.thing", "apple")]
check(abs(apple["B"] - 1) < 1e-9 and apple["unknown"] == ["W", "D", "R", "M"] and set(apple["terms"]) == {"C", "L"},
      "1,440 launches a day scores 1; an Apple item's W, D, R and M are unknown: %s" % apple)
chrome = [score([["Chrome", "third-party", 0, 0, m.GIB, 0, 0, 0] + flag])[("Chrome", "third-party")] for flag in ([1], [0], [])]
check(chrome[0]["unknown"] == [] and abs(chrome[0]["B"] - 1) < 1e-9 and chrome[0]["terms"]["D"] == 1
      and all(c["unknown"] == ["W", "D", "R", "M"] and c["B"] == 0 for c in chrome[1:]),
      "a third-party item read on every day scores its 1 GB a day; one unread, or from before, keeps W D R M unknown: %s" % chrome)
mixed = m.cohort_score([{"day": d["day"], "covered_s": 86400, "cohort": [["Chrome", "third-party", 0, 0, m.GIB, 0, 0, 0, i > 0]]}
                        for i, d in enumerate(week([]))], [], now)["items"][0]
check(mixed["unknown"] == ["W", "D", "R", "M"], "one unread day of seven keeps the item's W D R M unknown: %s" % mixed)
check(score([["edge", "own", 864 * 5, 0, 0, 0, 0, 0]])[("edge", "own")]["B"] == 5, "5x the CPU divisor is B 5")
short = score([["edge", "own", 864 * 100, 0, 0, 0, 0, 0]], days=6)
check(short == {"covered_days": 6.0, "items": None}, "under 7 covered days nothing is scored: %s" % short)
os.makedirs(os.environ["SSD_SAMPLER_DIR"], exist_ok=True)
for name, v, cost in (("a", 3, {"cpu_s": 864 * 7, "rss_max_b": 0, "ran_s": 120, "wrote_b": 7 * m.GIB // 2}),
                      ("b", 3, {"cpu_s": 0, "rss_max_b": 512 * 2 ** 20, "ran_s": 7 * 86400 // 2, "wrote_b": 0}),
                      ("c", 2, {"cpu_s": 864 * 70})):
    json.dump({"v": v, "start": now - 3600, "end": now - 3480, "devices": {}, "rows": [], "cost": cost},
              open(os.path.join(os.environ["SSD_SAMPLER_DIR"], name + ".json"), "w"))
sampler = score([])[(m.SAMPLER_TAG, "own")]
check(abs(sampler["B"] - 1) < 1e-9 and sampler["terms"] == {"C": 1, "L": 0, "W": 0, "D": 0.5, "R": 0, "M": 0.5},
      "the root sampler's own cost from its v3 samples is an own cohort item: %s" % sampler)
for name in ("b", "c"):
    os.remove(os.path.join(os.environ["SSD_SAMPLER_DIR"], name + ".json"))
json.dump({"v": 3, "start": now - 3600, "end": now - 3480, "devices": {}, "rows": [], "cost": {"cpu_s": 864 * 14}},
          open(os.path.join(os.environ["SSD_SAMPLER_DIR"], "a.json"), "w"))
judge = m.Judge(now, None)
m.judge_cohort(judge, m.cohort_score(week([]), [], now))
costly = {p["id"]: p for p in judge.problems}.get("cohort:" + m.SAMPLER_TAG)
check(costly and costly["state"] == "new" and costly["cause"]["fix_target"] and costly["cause"]["files"] == [m.SAMPLER_TAG],
      "a sampler costing B 2 is an own cohort problem the night fixes in bin/ssd-sampler: %s" % (costly and costly["cause"]))
shutil.rmtree(os.environ["SSD_SAMPLER_DIR"])
spread = m.cohort_score(week([["edge", "own", 864, 0, 0, 0, 0, 0]], days=14, covered=43200), [], now)
check(spread["covered_days"] == 7.0 and abs(spread["items"][0]["B"] - 2) < 1e-9,
      "half-covered days are amortized over their covered time, 14 days back at most: %s" % spread)


def cohort_problems(entries, launches=()):
    judge = m.Judge(now, None)
    m.judge_cohort(judge, m.cohort_score(week(entries), list(launches), now))
    return {p["id"]: p for p in judge.problems}


found = cohort_problems([["statusline.sh", "own", 864 * 5, 0, 0, 0, 0, 0], ["helper.sh", "own", 864 * 0.999, 0, 0, 0, 0, 0],
                         ["worker-run", "own", 864, 0, 0, 0, 0, 0], ["bench.py", "own", 864 * 2, 0, 0, 0, 0, 0]],
                        [{"t": now - 3600, "jobs": [{"name": "com.apple.mdworker.shared", "owner": "apple", "runs": 1440 * 70}]}])
check(sorted(found) == ["cohort:bench.py", "cohort:com.apple.mdworker.shared", "cohort:statusline.sh", "cohort:worker-run"],
      "B >= 1 is a cohort problem, 0.999 is not: %s" % sorted(found))
check(found["cohort:statusline.sh"]["severity"] == "heavy" and found["cohort:worker-run"]["severity"] == "review"
      and found["cohort:statusline.sh"]["state"] == "new" and found["cohort:statusline.sh"]["cause"]["fix_target"]
      and found["cohort:statusline.sh"]["cause"]["files"] == ["llm-legs/bin/statusline.sh"]
      and "tune it" in found["cohort:statusline.sh"]["fact"], "an own item in a sweep repository is tuned: %s" % found["cohort:statusline.sh"])
apple = found["cohort:com.apple.mdworker.shared"]
check(apple["state"] == "watch" and not apple["cause"]["fix_target"] and "(apple, report only)" in apple["fact"]
      and "never remove" in apple["fact"] and apple["severity"] == "heavy", "an Apple item reads watch, report-only: %s" % apple)
check(found["cohort:bench.py"]["state"] == "watch" and not found["cohort:bench.py"]["cause"]["fix_target"],
      "an own item outside the sweep repositories is watched, not fixed")
many = cohort_problems([], [{"t": now - 3600, "jobs": [{"name": "com.apple.%d" % i, "owner": "apple", "runs": 1440 * 7 * (i + 1)}
                                                       for i in range(10)]}])
check(len(many) == 6, "at most 6 watched items: %d" % len(many))
check(cohort_problems([["worker-run", "own", 432, 86400 * 92, 0, 0, 0, 0]]) == {},
      "an item at 92 births a second but half its CPU limit is no cohort problem")

for sub in ("launchd", "harvest", "census"):
    shutil.rmtree(os.path.join(work, "state", sub), ignore_errors=True)

# ---- doctor-fix routes own causes to a System fixer and never a report-only one
fake = os.path.join(work, "fakebin")
os.makedirs(fake)
for name, body in (("claudeb", "exit 0"), ("worker-pick", "printf 'acct\\n'"), ("opener", "exit 0")):
    open(os.path.join(fake, name), "w").write("#!/bin/bash\n%s\n" % body)
    os.chmod(os.path.join(fake, name), 0o755)
write_ticks(minutes(10, births_s=1500, births_seen=10, births_top=[["statusline.sh", 7, "own"], ["xpcproxy", 3, "apple"]],
                    kernel=0.6))
json.dump({"owner": "System doctor", "rows": [], "blind_spots": []}, open(os.environ["SYSTEM_DOCTOR_LEDGER"], "w"))
json.dump({"as_of_s": time.time()}, open(os.path.join(work, "state", "nightly.json"), "w"))
check(cli().returncode == 0, "the judge writes a fresh document")
fixer_repo = os.path.join(work, "fixer-repo")
subprocess.run(["git", "init", "-q", "-b", "main", fixer_repo], check=True)
subprocess.run(["git", "-C", fixer_repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base"], check=True)
env = dict(os.environ, PATH=fake + ":/usr/bin:/bin", DOCTOR_FIX_OPENER=os.path.join(fake, "opener"),
           DOCTOR_FIX_WORKER_PICK=os.path.join(fake, "worker-pick"), DOCTOR_FIX_WORKTREE_REPO=fixer_repo)
run = subprocess.run(["bash", os.path.join(root, "bin", "doctor-fix"), "launch", "system"], capture_output=True, text=True, env=env)
check(run.returncode == 0 and run.stdout.endswith("system fixer opened: 1 runs in one orchestrator chat\n"), "doctor-fix launch system opens a fixer: %s %s"
      % (run.stdout, run.stderr))
fixer = json.load(open(glob.glob(os.path.join(work, "doctors", "runs", "system-system-*.json"))[0]))
routed = {p["id"]: p for p in fixer["problems"]}
check(sorted(routed) == ["kernel:machine", "spawn:machine"] and routed["spawn:machine"]["cause"] == "statusline.sh"
      and routed["spawn:machine"]["area"] == "system"
      and routed["spawn:machine"]["component"]["files"] == [os.path.join(work, "repos", "llm-legs", "bin", "statusline.sh")]
      and "levers: cache git and jq per render" in routed["spawn:machine"]["component"]["what"],
      "an own cause routes with its sweep-repository file and its levers: %s" % routed)
write_ticks(minutes(10, births_s=1500, births_seen=10, births_top=[["xpcproxy", 10, "apple"]]))
check(cli().returncode == 0, "the judge rewrites the document")
run = subprocess.run(["bash", os.path.join(root, "bin", "doctor-fix"), "abandon", fixer["id"]], capture_output=True, text=True, env=env)
run = subprocess.run(["bash", os.path.join(root, "bin", "doctor-fix"), "launch", "system"], capture_output=True, text=True, env=env)
check(run.returncode != 0 and "nothing to fix" in run.stderr and len(glob.glob(os.path.join(work, "doctors", "runs", "system-*.json"))) == 1,
      "an Apple cause is never in a fixer snapshot: %s" % run.stderr)
open(os.environ["SSD_SAMPLER_PLIST"], "w").close()
os.utime(os.environ["SSD_SAMPLER_PLIST"], (time.time() - 20 * 3600, time.time() - 20 * 3600))
check(cli().returncode == 0, "the judge rewrites the document with a stale sampler")
run = subprocess.run(["bash", os.path.join(root, "bin", "doctor-fix"), "launch", "system"], capture_output=True, text=True, env=env)
blinds = sorted(glob.glob(os.path.join(work, "doctors", "runs", "system-*.json")), key=os.path.getmtime)
routed = {p["id"]: p for p in json.load(open(blinds[-1]))["problems"]} if len(blinds) == 2 else {}
check(run.returncode == 0 and sorted(routed) == ["collector:ssd-sampler"]
      and routed["collector:ssd-sampler"]["component"]["files"]
      == [re.sub(r"/\.claude/worktrees/[^/]+(?=/)", "", os.path.join(os.path.realpath(root), "bin", "system-doctor"))],
      "a blind System collector is a night problem on bin/system-doctor: %s %s" % (routed, run.stderr))
blind = json.load(open(blinds[-1]))["id"]
subprocess.run(["bash", os.path.join(root, "bin", "doctor-fix"), "abandon", blind], capture_output=True, env=env)
os.remove(os.environ["SSD_SAMPLER_PLIST"])
os.remove(blinds[-1])
os.makedirs(os.path.join(work, "state", "launchd"), exist_ok=True)
at = time.time()
with open(os.path.join(work, "state", "launchd", m.local_day(at) + ".jsonl"), "w") as handle:
    for hours_ago in (2, 1, 0):
        handle.write(json.dumps({"t": at - hours_ago * 3600 - 60, "dt": 3600, "services": 5, "jobs": [
            {"label": "com.llm-legs.memlogd", "name": "memlogd", "owner": "own", "runs": 120, "bad": 1, "exit": "exit 1",
             "every": None, "relaunched": True},
            {"label": "com.vendor.sync", "name": "com.vendor.sync", "owner": "third-party", "runs": 1, "bad": 1,
             "exit": "signal 11", "every": 300, "relaunched": True}]}) + "\n")
check(cli().returncode == 0, "the judge reads the launchd rows")
run = subprocess.run(["bash", os.path.join(root, "bin", "doctor-fix"), "launch", "system"], capture_output=True, text=True, env=env)
fixers = sorted(glob.glob(os.path.join(work, "doctors", "runs", "system-*.json")), key=os.path.getmtime)
routed = {p["id"]: p for p in json.load(open(fixers[-1]))["problems"]} if len(fixers) == 2 else {}
check(run.returncode == 0 and sorted(routed) == ["job-loop:com.llm-legs.memlogd"]
      and routed["job-loop:com.llm-legs.memlogd"]["component"]["files"] == [os.path.join(work, "repos", "llm-legs", "bin", "memlogd")]
      and "back off before exiting non-zero" in routed["job-loop:com.llm-legs.memlogd"]["component"]["what"],
      "an own looping job routes to the fixer by its program's file, a third-party crashing one never: %s %s" % (routed, run.stderr))
live = "".join(subprocess.run(["git", "-C", root] + cmd, capture_output=True, text=True).stdout
               for cmd in (["worktree", "list", "--porcelain"], ["for-each-ref", "--format=%(refname)"]))
launched = [fixer["id"], blind, json.load(open(fixers[-1]))["id"]]
check(not [i for i in launched if i in live], "no fixture launch adds a worktree, branch or ref to the live repository: %s"
      % [line for line in live.splitlines() if any(i in line for i in launched)])

contract = open(os.path.join(root, "docs", "doctors-contract.md")).read().split("\nSystem doctor ", 1)[-1].split("\n\n", 1)[0]
check(all("`%s`" % rule in contract for rule in m.RULE_LABELS),
      "the contract's System doctor section names every rule: missing %s" % [r for r in m.RULE_LABELS if "`%s`" % r not in contract])

# ---- an interpreter is named by the script it runs, so our own load has a fix target
repos = os.path.join(work, "repos")
for rel in ("llm-legs/bin/x.py", "llm-legs/pkg/tool.py", "llm-legs/bin/x.sh", "helper/bin/gate.py"):
    os.makedirs(os.path.dirname(os.path.join(repos, rel)), exist_ok=True)
    open(os.path.join(repos, rel), "w").write("#\n")
os.makedirs(os.path.join(repos, "llm-legs", ".claude", "worktrees", "fix-a", "bin"), exist_ok=True)
os.symlink(os.path.join(repos, "llm-legs", "bin", "x.py"), os.path.join(own, "linked.py"))
m.repo_files.cache_clear()
script = os.path.join(repos, "llm-legs", "bin", "x.py")
check(m.classify("/opt/homebrew/bin/python3 %s --flag" % script, 501, roots) == ("llm-legs/bin/x.py", "own"),
      "python3 running a sweep-repo script is named repo/path: %s" % (m.classify("/opt/homebrew/bin/python3 %s" % script, 501, roots),))
check(m.classify("/usr/bin/python3 -u -X dev -B %s" % script, 501, roots) == ("llm-legs/bin/x.py", "own"),
      "interpreter options before the script are skipped, -X with its value")
check(m.classify("/bin/bash %s/llm-legs/.claude/worktrees/fix-a/bin/x.py" % repos, 501, roots) == ("llm-legs/bin/x.py", "own"),
      "a worktree's script folds into its repository")
check(m.classify("/opt/homebrew/bin/python3 %s/linked.py" % own, 501, roots) == ("llm-legs/bin/x.py", "own"),
      "a link into a repository is named by its target")
check(m.classify("/opt/homebrew/bin/python3 %s/helper/bin/gate.py" % repos, 501, roots) == ("helper/bin/gate.py", "own"),
      "a helper repository's script is named by its path too")
check(m.classify("/opt/homebrew/bin/python3 -m pkg.tool --x", 501, roots, lambda: os.path.join(repos, "llm-legs"))
      == ("llm-legs/pkg/tool.py", "own"), "python3 -m resolves the module's file in its working directory")
check(m.classify("%s/venv/bin/python3 -m bench.worker" % own, 501, roots) == ("bench.worker", "own"),
      "an unresolved -m module is named by the module")
check(m.classify("/bin/bash bin/x.sh", 501, roots, lambda: os.path.join(repos, "llm-legs")) == ("llm-legs/bin/x.sh", "own"),
      "a relative script resolves against the process's working directory")
check(m.classify("/opt/homebrew/bin/python3 bin/x.py", 501, roots, lambda: None) == ("python3", "third-party")
      and m.classify("/opt/homebrew/bin/python3", 501, roots) == ("python3", "third-party")
      and m.classify("/opt/homebrew/bin/python3 -", 501, roots) == ("python3", "third-party"),
      "no readable script keeps the interpreter's name")
llm = lambda: os.path.join(repos, "llm-legs")
bundled = [m.describe(exe, words, roots, llm) for exe, words in (
    ("/usr/bin/perl", ["-pe", "s/x/defined $1/"]), ("/usr/bin/perl", ["-lne", "print"]),
    ("/usr/bin/perl", ["-0777", "-nE", "say"]), ("/usr/bin/ruby", ["-ne", "puts"]), ("/opt/homebrew/bin/node", ["-pe", "1"]))]
check([b[2] for b in bundled] == ["inline"] * 5 and [b[0] for b in bundled] == ["perl", "perl", "perl", "ruby", "node"],
      "an inline flag bundled with others is inline code, never a script named by its first word: %s" % bundled)
check(m.describe("/usr/bin/perl", ["-Mbase", "x.pl"], roots, llm)[2] == "script",
      "a module flag ending in e stays an option")
check(m.program_name("%s/venv/bin/python3" % own, ["%s/venv/bin/python3" % own, "-u", script]) == "llm-legs/bin/x.py"
      and m.program_name("%s/bin/memlogd" % own, ["%s/bin/memlogd" % own, "--x"]) == "memlogd",
      "a launchd job running an interpreter is named by its script")
libexec = os.environ["SYSTEM_DOCTOR_LIBEXEC_DIR"]
os.makedirs(libexec, exist_ok=True)
wrappers = {"refresh-heartbeat": "script=%s\n[ -r \"$script\" ] || exit 0\nexec \"$script\" \"$@\"\n"
                                  % os.path.join(repos, "llm-legs", "bin", "worker-run"),
            "x-proxy": "exec /opt/homebrew/bin/python3 %s \"$@\"\n" % script,
            "hs-app": "exec /Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon \"$@\"\n"}
for name, body in wrappers.items():
    open(os.path.join(libexec, name), "w").write("#!/bin/sh\n" + body)
named = {name: m.program_name(os.path.join(libexec, name), [os.path.join(libexec, name)]) for name in wrappers}
check(named == {"refresh-heartbeat": "llm-legs/bin/worker-run", "x-proxy": "llm-legs/bin/x.py", "hs-app": "Hammerspoon"},
      "a job behind a libexec wrapper is named by what the wrapper execs, as its ticks and crash reports name it: %s" % named)
for name in wrappers:
    os.remove(os.path.join(libexec, name))
odd = os.path.join(work, "agents", "odd.plist")
with open(odd, "wb") as handle:
    plistlib.dump({"Label": "com.x.odd", "ProgramArguments": {"a": "b"}, "KeepAlive": True}, handle)
check("com.x.odd" not in [label for label, _program, _plist in m.job_plists()], "a plist whose ProgramArguments is no list is skipped")
os.remove(odd)
job = m.parse_dumpstate("gui/501/com.x.py = {\n\tprogram = %s/venv/bin/python3\n\targuments = {\n\t\t%s/venv/bin/python3\n\t\t%s\n\t}\n"
                        "\truns = 3\n}\n" % (own, own, script))
check(job["gui/501/com.x.py"]["name"] == "llm-legs/bin/x.py", "dumpstate names an interpreter job by its arguments: %s" % job)
put("ps", ps_rows([(1, 0, 0, "0:01.00", start, "/sbin/launchd"),
                   (700, 1, uid, "0:01.00", start, "/opt/homebrew/bin/python3 %s" % script),
                   (701, 700, uid, "0:00.10", start, "/bin/bash -c jq .x"),
                   (702, 701, uid, "0:00.10", start, "/bin/sh -c true"),
                   (703, 700, uid, "0:00.10", start, "/opt/homebrew/bin/claude -p"),
                   (704, 703, uid, "0:00.10", start, "/bin/zsh -c ls")]))
tags = {entry[4]: (entry[2], entry[3]) for entry in m.ps_snapshot(False)[1].values()}
check(tags[701] == tags[702] == ("llm-legs/bin/x.py", "own") and tags[704] == ("zsh", "apple"),
      "inline code takes its parent's script through inline parents only: %s" % tags)
procs_was = open(os.environ["SYSTEM_DOCTOR_PROCS"]).read()
json.dump(dict(json.loads(procs_was), path={"705": "/Applications/Ghost.app/Contents/MacOS/ghostd"}),
          open(os.environ["SYSTEM_DOCTOR_PROCS"], "w"))
put("ps", open(os.path.join(fix, "ps")).read() + ps_rows([(705, 1, uid, "0:00.10", start, "ghostd --x")]))
check(all(entry[8] is None for entry in m.ps_snapshot(False)[1].values()), "no known tags given: no file is looked up")
places = {entry[4]: entry[8] for entry in m.ps_snapshot(False, {"claude": "~/x"})[1].values()}
check(places[700] == places[701] == places[702] == script and places[703] is None and places[704] == "/bin/zsh"
      and places[705] == "/Applications/Ghost.app/Contents/MacOS/ghostd" and places[1] == "/sbin/launchd",
      "a process's file: its interpreter's script, inline code its script's, an executable named bare by pid, a known "
      "tag none: %s" % places)
open(os.environ["SYSTEM_DOCTOR_PROCS"], "w").write(procs_was)
put("ps-children", open(os.path.join(fix, "ps")).read())
state2 = os.path.join(work, "state2")
check(cli("tick", "--quiet", env={"SYSTEM_DOCTOR_DIR": state2}).returncode == 0, "a tick sees the script")
origins = m.read_json(os.path.join(state2, "origins.json"), {})
check(origins.get("llm-legs/bin/x.py") == script and origins.get("claude") == "/opt/homebrew/bin/claude",
      "a tick keeps the file of each tag it has not seen before: %s" % origins)
put("ps", ps_rows([(1, 0, 0, "0:01.00", start, "/sbin/launchd")]))
put("ps-children", open(os.path.join(fix, "ps")).read())
check(cli("tick", "--quiet", env={"SYSTEM_DOCTOR_DIR": state2}).returncode == 0, "a tick sees it gone")
gone = [r for f in glob.glob(os.path.join(state2, "pids", "*.jsonl")) for r in m.read_jsonl(f)]
check(len(gone) == 1 and [g[0] for g in gone[0]["gone"]] == [700, 701, 702]
      and gone[0]["gone"][0][3:] == ["llm-legs/bin/x.py", "own"] and own not in json.dumps(gone),
      "a dead interpreter's pid and script name are kept, no argv: %s" % gone)
os.environ["SYSTEM_DOCTOR_DIR"] = state2
scripts = m.pid_scripts(time.time() + 60)
os.environ["SYSTEM_DOCTOR_DIR"] = os.path.join(work, "state")
began = m.start_epoch("700@%s" % " ".join(start.split()))
diag2 = os.path.join(work, "diag2")
os.makedirs(diag2)
named = []
for pid, at in ((700, began + 600), (700, now + 3 * 86400), (999, began + 600)):
    path = os.path.join(diag2, "Python_%d_%d.diag" % (pid, at))
    open(path, "w").write("Date/Time:        %s\nEnd time:         %s\nCommand:          Python\nPath:             "
                          "/opt/homebrew/*/Python.app/Contents/MacOS/Python\nPID:              %d\nEvent:            disk writes\n"
                          % (stamp(at, "%Y-%m-%d %H:%M:%S.000 %z"), stamp(at + 60, "%Y-%m-%d %H:%M:%S.000 %z"), pid))
    named.append(m.report_header(path, os.path.basename(path), {}, scripts))
check([(r["name"], r["owner"]) for r in named] == [("llm-legs/bin/x.py", "own"), ("Python", "own"), ("Python", "own")],
      "a Python disk-writes report names the script its pid ran then; a reused or unseen pid keeps Python: %s" % named)
for reports_seen, target in ((named[:1] * 3 + named[2:], True), (named[2:] * 3 + named[:1], False)):
    ssd = judged(days=day_rows(250), night={"as_of_s": now, "reports": reports_seen})[0]["ssd-writes:internal"]["cause"]
    check(ssd["fix_target"] is target and ssd["files"] == (["llm-legs/bin/x.py"] if target else []),
          "an SSD cause named by its script is a fix target, the interpreter-only one stays report-only: %s" % ssd)
check(m.own_sources("helper/bin/gate.py") == [] and m.source_path("llm-legs/bin/x.py") == script
      and m.levers("llm-legs/bin/statusline.sh", "cohort") == [m.LEVERS[0][1]],
      "a helper repository's script stays report-only; a repo/path cause finds its file and levers by basename")
for name in ("helper", "other"):
    subprocess.run(["git", "init", "-q", os.path.join(repos, name)], check=True)
os.makedirs(os.path.join(repos, "other", "bin"), exist_ok=True)
open(os.path.join(repos, "other", "bin", "y.py"), "w").write("#\n")
open(os.path.join(work, "helper-repos"), "w").write(os.path.join(repos, "helper") + "\n")
os.environ["NIGHT_RUN_HELPER_REPOS"] = os.path.join(work, "helper-repos")
m.repo_files.cache_clear()
check(m.own_sources("helper/bin/gate.py") == ["helper/bin/gate.py"]
      and m.source_path("helper/bin/gate.py") == os.path.join(repos, "helper", "bin", "gate.py")
      and m.own_sources("other/bin/y.py") == [] and m.source_path("other/bin/y.py") is None and m.own_sources("gate.py") == [],
      "a listed helper repository's repo/path is night-fixable with its absolute path; another sibling and a bare name there are not")
helper_report = dict(named[0], name="helper/bin/gate.py")
other_report = dict(named[0], name="other/bin/y.py")
for reports_seen, target in (([helper_report] * 3, True), ([other_report] * 3, False)):
    ssd = judged(days=day_rows(250), night={"as_of_s": now, "reports": reports_seen})[0]["ssd-writes:internal"]["cause"]
    check(ssd["fix_target"] is target, "a helper's cause is a fix target, another sibling's report-only: %s" % ssd)
del os.environ["NIGHT_RUN_HELPER_REPOS"]

endless = os.path.join(work, "bin", "endless-log")
with open(endless, "w") as handle:
    handle.write("#!/bin/bash\necho first\nexec sleep 20\n")
os.chmod(endless, 0o755)
os.environ["SYSTEM_DOCTOR_LOG"] = endless


def boom(line):
    raise ValueError(line)


began, raised = time.monotonic(), None
try:
    m.machine_probe.stream("log", ["stream"], 60, 100, boom)
except ValueError as error:
    raised = str(error)
check(raised == "first" and time.monotonic() - began < 10,
      "an on_line that raises kills the probe instead of waiting it out: %r after %.1fs" % (raised, time.monotonic() - began))

# The child's first line comes from its own code, so its argv is final by then.
child = subprocess.Popen([sys.executable, "-c", "import time; print(flush=True); time.sleep(30)", "", "--flag"],
                         env=dict(os.environ, PROBE_SECRET="secret"), stdout=subprocess.PIPE)
try:
    child.stdout.readline()
    seen = m.machine_probe._argv(child.pid)
finally:
    child.kill()
    child.wait()
check(seen[-2:] == ["", "--flag"] and not any("PROBE_SECRET" in word for word in seen),
      "an empty argument shifts _argv into the environment: %r" % seen)

print("OK: PASS: %d system doctor checks" % asserts)
PY
