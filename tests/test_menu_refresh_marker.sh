#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# Every task a hammerspoon/*.lua module starts is classified here: a refresh wears menu-style.lua's
# BUSY marker on the Automations title through the module's busySource (the menu harnesses assert it
# while a stubbed task runs and after it ends), anything else says why it is not a refresh. A new
# spawn site fails until it is classified, so no menu starts a background refresh without the marker.
# Modules: llm-limits.lua doctors.lua token-tracking.lua instruction-watch.lua dia-flag-watch.lua
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

check() {
python3 - "$@" <<'PY'
import glob
import os
import re
import sys

root = sys.argv[1]
MARKED = {
    ("llm-limits.lua", "runAccountCommand"): ("LLM limits", "llm-limits.lua"),
    ("llm-limits.lua", "refreshData"): ("LLM limits", "llm-limits.lua"),
    ("llm-limits.lua", "M.redeemReset"): ("LLM limits", "llm-limits.lua"),
    ("llm-limits.lua", "M.setWorkerPaused"): ("LLM limits", "llm-limits.lua"),
    ("llm-limits.lua", "M.setWorkerRole"): ("LLM limits", "llm-limits.lua"),
    ("llm-limits.lua", "startDiagnosticsTask"): ("Doctors", "doctors.lua"),
    ("doctors.lua", "refreshDoctor"): ("Doctors", "doctors.lua"),
    ("token-tracking.lua", "startStep"): ("Token tracking", "token-tracking.lua"),
    ("token-tracking.lua", "startSpend"): ("Token tracking", "token-tracking.lua"),
}
EXEMPT = {
    ("llm-limits.lua", "newCollectorTask"): "the factory; its callers are classified",
    ("llm-limits.lua", "collectOnOpen"): "the passive open-time collect, never an indicator (DIAGNOSTICS.md)",
    ("llm-limits.lua", "M.refreshRouting"): "a sub-second worker-pick read rerun on every store rewrite",
    ("llm-limits.lua", "copyChatCommand"): "a click action",
    ("llm-limits.lua", "focusChat"): "a click action",
    ("llm-limits.lua", "M.switchChatTo"): "a click action",
    ("doctors.lua", "launch"): "opens a fixer or night chat, a job rather than a refresh",
    ("doctors.lua", "M.refreshNight"): "a 70 ms night-run status read on build",
    ("token-tracking.lua", "taskFn"): "the factory",
    ("token-tracking.lua", "M.setTask"): "the factory",
    ("token-tracking.lua", "M.menuItems"): "opens the token map page",
    ("instruction-watch.lua", "runOpenCommand"): "a click action",
    ("instruction-watch.lua", "runChatResolver"): "a chat-name lookup for rows already shown",
    ("instruction-watch.lua", "M.menuItems"): "reveals the change log in Finder",
    ("dia-flag-watch.lua", "M.check"): "no menu",
}
SPAWN = re.compile(r"hs\.task\.new\b|\btaskFn\(|\bnewCollectorTask\(")
DEFINE = re.compile(r"^(?:local\s+)?function\s+([\w.:]+)|^(?:local\s+)?([\w.]+)\s*=\s*function\b")
problems, seen = [], set()
for path in sorted(glob.glob(os.path.join(root, "*.lua"))):
    name, owner = os.path.basename(path), None
    with open(path, encoding="utf-8") as fh:
        for number, line in enumerate(fh, 1):
            found = DEFINE.match(line)
            if found:
                owner = found.group(1) or found.group(2)
            if SPAWN.search(line) and not line.lstrip().startswith("--"):
                key = (name, owner)
                seen.add(key)
                if key not in MARKED and key not in EXEMPT:
                    problems.append(f"{name}:{number}: {owner} starts a task nobody classified; a refresh"
                                    " reports it through menu-style busySource, else add an EXEMPT reason")
for key, (source, home) in MARKED.items():
    with open(os.path.join(root, home), encoding="utf-8") as fh:
        if f'busySource("{source}"' not in fh.read():
            problems.append(f"{key[0]}: {key[1]} is marked {source!r} but {home} registers no such busySource")
for key in sorted(set(MARKED) | set(EXEMPT)):
    if key not in seen:
        problems.append(f"{key[0]}: {key[1]} starts no task any more; drop its entry")
print("\n".join(problems))
PY
}

out=$(check "$ROOT/hammerspoon") || fail "the checker threw: $out"
[ -z "$out" ] || fail "$out"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT"/hammerspoon/*.lua "$WORK/"
printf 'function M.recompute()\n  hs.task.new("/bin/true", nil, {}):start()\nend\n' >>"$WORK/doctors.lua"
out=$(check "$WORK")
case "$out" in *"M.recompute starts a task nobody classified"*) ;; *) fail "an unclassified spawn passed: $out" ;; esac
cp "$ROOT/hammerspoon/doctors.lua" "$WORK/doctors.lua"
grep -v 'busySource("Token tracking"' "$ROOT/hammerspoon/token-tracking.lua" >"$WORK/token-tracking.lua"
out=$(check "$WORK")
case "$out" in *"registers no such busySource"*) ;; *) fail "a marked refresh without its source passed: $out" ;; esac
echo "OK: every menu task is a marked refresh or names why not"
