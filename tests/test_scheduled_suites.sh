#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/scheduled-suites on a stub repository whose stub suite fails from one commit on: a tick that is not due makes no
# git call, one with main unmoved one; a red main is run twice, bisected over the commits touching covered files (an
# unbuildable step skipped) and handed off once, with the budget key's was/now; red again is not reported again; a
# docs-only move runs nothing; a fix settles the handoff; a live landing or another tick defers; --install-agent
# writes the plist naming the script itself.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT
asserts=0
REAL_GIT=$(command -v git)
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/xdg" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
  SCHEDULED_SUITES_DIR="$WORK/state" SCHEDULED_SUITES_REPOS="$WORK/repos" RUN_SUITES_JOURNAL="$WORK/runs.jsonl" \
  STUB_RUNS="$WORK/suite-runs" GIT_CALLS="$WORK/git.calls"
unset WORKER_RUN_ID CLAUDE_CODE_SESSION_ID RUN_SCHEDULED
mkdir -p "$HOME" "$WORK/shim"
printf '[user]\n\tname = t\n\temail = t@t\n[core]\n\thooksPath = /dev/null\n[init]\n\tdefaultBranch = main\n' >"$GIT_CONFIG_GLOBAL"
printf '#!/bin/sh\necho "$*" >>"$GIT_CALLS"\nexec %s "$@"\n' "$REAL_GIT" >"$WORK/shim/git"
printf '#!/bin/sh\necho "$*" >>"%s/launchctl.calls"\n[ "$1" != print ] || [ -e "%s/loaded" ]\n' "$WORK" "$WORK" >"$WORK/shim/launchctl"
chmod +x "$WORK/shim/git" "$WORK/shim/launchctl"
export PATH="$WORK/shim:$PATH"
S="$ROOT/bin/scheduled-suites"
R="$WORK/repo"
ST="$SCHEDULED_SUITES_DIR/repo/test_stub.sh"
LOG="$SCHEDULED_SUITES_DIR/scheduled.log"
printf '%s\n' "$R" >"$SCHEDULED_SUITES_REPOS"

commit() { # file text subject
  mkdir -p "$(dirname "$R/$1")" && printf '%s\n' "$2" >"$R/$1" && git -C "$R" add "$1" && git -C "$R" commit -qm "$3"
}
tick() { : >"$GIT_CALLS"; SCHEDULED_SUITES_NOW=$1 "$S" tick; }
runs() { wc -l <"$STUB_RUNS" 2>/dev/null | tr -d ' ' || echo 0; }
last() { tail -1 "$LOG" | cut -d' ' -f3-; }
sha() { git -C "$R" rev-parse "$1"; }

mkdir -p "$R/tests" "$R/src"
git -C "$R" init -q
cat >"$R/tests/test_stub.sh" <<'EOF'
#!/usr/bin/env bash
echo run >>"$STUB_RUNS"
[ ! -e src/broken ] || exit 125
v=$(cat src/value)
if [ "$v" -lt 5 ]; then echo "perf stub_k: $v n (budget 4)"; else echo "FAIL: perf stub_k: $v n over budget 4 (set at: t). Fix: f"; exit 1; fi
EOF
printf 'test_stub.sh 3 tests/budgets.json\n' >"$R/tests/scheduled-suites"
printf '{}\n' >"$R/tests/budgets.json"
printf '1\n' >"$R/src/value"
git -C "$R" add -A && git -C "$R" commit -qm init
T=1800000000 H=10801

# The first tick runs main and records it good.
tick $T
assert test "$(runs)" = 1
assert test "$(cat "$ST/good")" = "$(sha main)"
assert test "$(last)" = "repo test_stub.sh: ran here: green at $(sha main | cut -c1-12)"
# Not due: no git call at all.
tick $((T + 60))
assert test ! -s "$GIT_CALLS"
assert test "$(last)" = 'repo test_stub.sh: not due (ran 0 h 1 min ago, every 3 h)'

# Red from the commit setting 5; docs commits between are not candidates, the unbuildable value-3 commit is skipped.
commit src/value 2 'value 2'
commit docs/notes.md n1 'notes 1'
commit src/value 3 'value 3'; commit src/broken x 'broken'
git -C "$R" rm -q src/broken; commit src/value 4 'value 4'
commit src/value 5 'value 5: the regression'; bad=$(sha main)
commit docs/notes.md n2 'notes 2'
commit src/value 6 'value 6'
tick $((T + H))
doc=$(ls "$R"/docs/handoffs/*-scheduled-test_stub-"${bad:0:7}".md 2>/dev/null)
assert test -n "$doc"
assert grep -qx 'Status: open' "$doc"
assert grep -qF "fails from \`${bad:0:12}\`" "$doc"
assert grep -qF 'value 5: the regression' "$doc"
assert grep -qxF -- '- `stub_k`: was 4, now 5 n' "$doc"
assert grep -qF '`src/value`' "$doc"
assert grep -qF "test_stub.sh red on main from ${bad:0:12} value 5: the regression" "$ST/open"
assert grep -q 'red at .*, run once more' "$LOG"
assert grep -q 'step [0-9]* at .*: skip' "$LOG"
assert test "$(last)" = "repo test_stub.sh: ran here: red from ${bad:0:12} (passed at $(sha "$bad~1" | cut -c1-12)); reported in ${doc#"$R"/}"
# 1 + 2 at main + 1 at the last good (green: the cause is in the diff) + steps (value 3 skipped, value 4 pass, value 5
# fail, at most one more)
assert test "$(runs)" -ge 7
assert test "$(runs)" -le 8
# The picker's line names the open failure to the next chat working there.
assert grep -qF "scheduled: test_stub.sh red on main from ${bad:0:12}" <(bash "$ROOT/share/affected-suites.sh" --repo "$R" docs/x.md 2>&1)

# Main unmoved: one git call, no run.
n=$(runs)
tick $((T + 2 * H))
assert test "$(wc -l <"$GIT_CALLS" | tr -d ' ')" = 1
assert grep -q ' rev-parse --verify -q refs/heads/main$' "$GIT_CALLS"
assert test "$(runs)" = "$n"
assert test "$(last)" = "repo test_stub.sh: main unmoved at $(sha main | cut -c1-12)"
# Still red after a covered move: run, no second report.
commit src/value 7 'value 7'
tick $((T + 3 * H))
assert test "$(ls "$R"/docs/handoffs | wc -l | tr -d ' ')" = 1
assert test "$(last)" = "repo test_stub.sh: ran here: still red at $(sha main | cut -c1-12), reported: $doc"
# A docs-only move: nothing runs.
n=$(runs)
commit docs/notes.md n3 'notes 3'
tick $((T + 4 * H))
assert test "$(runs)" = "$n"
assert test "$(last)" = "repo test_stub.sh: main moved to $(sha main | cut -c1-12) in no file the suite covers"
# A live landing defers the run; another tick in progress ends this one.
commit src/value 1 'value 1: the fix'
mkdir -p "$R/.git/land-feat+x.lock" && printf '%s\n' "$$" >"$R/.git/land-feat+x.lock/pid"
tick $((T + 5 * H))
assert test "$(runs)" = "$n"
assert test "$(last)" = "repo test_stub.sh: a landing runs (pid $$, land-feat+x.lock): the next tick"
rm -r "$R/.git/land-feat+x.lock"
mkdir -p "$SCHEDULED_SUITES_DIR/.tick.lock" && printf '%s\n' "$$" >"$SCHEDULED_SUITES_DIR/.tick.lock/pid"
tick $((T + 5 * H))
assert test "$(last)" = "another tick runs (pid $$): this one ends"
rm -r "$SCHEDULED_SUITES_DIR/.tick.lock"
# The fix clears it: the handoff settled, no open line.
tick $((T + 5 * H))
assert test "$(runs)" = $((n + 1))
assert grep -q '^Status: settled .*: the scheduled run passed on main at ' "$doc"
assert test ! -e "$ST/open"
assert test "$(last)" = "repo test_stub.sh: ran here: green again at $(sha main | cut -c1-12); settled ${doc#"$R"/}"
assert test -z "$(bash "$ROOT/share/affected-suites.sh" --repo "$R" docs/x.md 2>&1)"
# The run's worktree is its own, detached, and the main checkout stays on main.
assert test "$(git -C "$R" symbolic-ref --short HEAD)" = main
assert test -z "$(git -C "$ST/wt" symbolic-ref -q HEAD)"

# ---- Boxes and debts (Egor 2026-11-14), on a second repository whose stub suite sends itself to a stub bench when
# $BOX/open exists (its last line `[bench ...]`), else runs here and says so, as tests/rig/bench-entry.sh does.
R2="$WORK/repo2" BOX="$WORK/box"
ST2="$SCHEDULED_SUITES_DIR/repo2/test_box.sh"
export BOX LIMIT_HITS_LOG="$WORK/hits.jsonl"
mkdir -p "$R2/tests" "$R2/src" "$BOX"
git -C "$R2" init -q
cat >"$R2/tests/test_box.sh" <<'EOF'
#!/usr/bin/env bash
where=here; [ -e "$BOX/open" ] && where=bench
[ "$where" = bench ] || echo "test_box.sh: on this Mac, the bench is closed (stub)" >&2
echo "$where $(cat src/value)" >>"$BOX/runs"
case $(cat "$BOX/mode" 2>/dev/null) in
  hang) echo $$ >"$BOX/hang.pid"; sleep 60; exit 0 ;;
  nofail) echo "bench: no run lock on stub (it does not answer)" >&2; exit 1 ;;
  failall) echo "FAIL: test_box.sh: the Release build failed: xcode-select: no developer tools"; exit 1 ;;
esac
rc=0; [ "$(cat src/value)" -lt 5 ] || { echo "FAIL: perf box_k: $(cat src/value) n over budget 4 (set at: t). Fix: f"; rc=1; }
[ "$where" = here ] || echo "[bench 1 s, fallback alone] done"
exit $rc
EOF
cat >"$R2/tests/scheduled-suites" <<'EOF'
box bench ready [ -e "$BOX/open" ] || { echo "stub bench closed"; exit 1; }
box bench says ^\[bench [0-9]+ s,
box here says : on this Mac, the bench is closed
test_box.sh 3 boxes=bench,here needs=bench
EOF
printf '1\n' >"$R2/src/value"
git -C "$R2" add -A && git -C "$R2" commit -qm init
printf '%s\n' "$R2" >"$SCHEDULED_SUITES_REPOS"
c2() { printf '%s\n' "$1" >"$R2/src/value" && git -C "$R2" commit -qam "value $1"; }
s2() { git -C "$R2" rev-parse main | cut -c1-12; }
brun() { cat "$BOX/runs" 2>/dev/null | wc -l | tr -d ' '; }
T2=$((T + 100 * H))

# The state 9f866159 wrote (no box-* directory: one record, any box) is read as every box's: main unmoved, no run.
mkdir -p "$ST2"
for f in tested checked good; do git -C "$R2" rev-parse main >"$ST2/$f"; done
echo $((T2 - 4 * 3600)) >"$ST2/ran"
tick $T2
assert test "$(wc -l <"$GIT_CALLS" | tr -d ' ')" = 1
assert test "$(brun)" = 0
assert test "$(last)" = "repo2 test_box.sh: main unmoved at $(s2)"
SCHEDULED_SUITES_NOW=$T2 "$S" status >"$WORK/status.out"
assert grep -qxF "  bench  finished on $(s2) 4 h 0 min ago, green (state before boxes: any box)" "$WORK/status.out"

# Many ticks missed (the Mac off over three moves): one run, on the newest main. The bench closed: here takes the
# counted readings and the bench is owed.
c2 2; c2 3; c2 4
tick $((T2 + 10 * H))
assert test "$(cat "$BOX/runs")" = 'here 4'
assert test "$(last)" = "repo2 test_box.sh: ran here: green at $(s2)"
assert test "$(cat "$ST2/box-here/done" | cut -c1-12)" = "$(s2)"
assert test ! -e "$ST2/box-bench/done"
assert grep -q ' not ready: stub bench closed$' "$ST2/box-bench/owed"
# A tick later: the bench owed, nothing runs, and a box that was not ready is asked again only after the period (its
# probe wakes the M1's display).
tick $((T2 + 10 * H + 60))
assert test "$(brun)" = 1
assert test "$(last)" = 'repo2 test_box.sh: owed bench: not due (tried 0 h 1 min ago, every 3 h)'
tick $((T2 + 11 * H))
assert test "$(brun)" = 1
assert test "$(last)" = 'repo2 test_box.sh: owed bench: not ready: stub bench closed'
# The same second again: a tick does not ask a box it has just tried; `retry` does (he says the M1 is free now).
tick $((T2 + 11 * H))
assert test "$(last)" = 'repo2 test_box.sh: owed bench: not due (tried 0 h 0 min ago, every 3 h)'
: >"$GIT_CALLS"; SCHEDULED_SUITES_NOW=$((T2 + 11 * H)) "$S" retry
assert test "$(brun)" = 1
assert test "$(last)" = 'repo2 test_box.sh: owed bench: not ready: stub bench closed'
# Ready: the bench pays main, once; then nothing is owed and the period holds again.
touch "$BOX/open"
tick $((T2 + 12 * H))
assert test "$(tail -1 "$BOX/runs")" = 'bench 4'
assert test "$(last)" = "repo2 test_box.sh: ran bench: green at $(s2)"
assert test ! -e "$ST2/box-bench/owed"
tick $((T2 + 12 * H + 60))
assert test "$(brun)" = 2
assert test ! -s "$GIT_CALLS"

# A counted regression found here is reported once; the bench, paying later, finds it red and sends nothing.
rm "$BOX/open"
c2 5; bad2=$(s2)
tick $((T2 + 15 * H))
assert test "$(ls "$R2"/docs/handoffs | wc -l | tr -d ' ')" = 1
assert test "$(cat "$ST2/open.box")" = here
touch "$BOX/open"
tick $((T2 + 18 * H))
assert test "$(tail -1 "$BOX/runs")" = 'bench 5'
assert test "$(last)" = "repo2 test_box.sh: ran bench: still red at $bad2, reported: $(ls "$R2"/docs/handoffs/*)"
assert test "$(ls "$R2"/docs/handoffs | wc -l | tr -d ' ')" = 1
c2 1
tick $((T2 + 21 * H))
assert test "$(last)" = "repo2 test_box.sh: ran bench: green again at $(s2); settled $(cd "$R2" && ls docs/handoffs/*)"

# Could not run (a non-zero exit with no FAIL line: the bench's ssh, here closed): no bisect, no handoff; owed; past a
# day one limit hit per owed box, once.
rm "$BOX/open"; echo nofail >"$BOX/mode"
c2 2
steps=$(grep -c ' step ' "$LOG")
T3=$((T2 + 24 * H))
tick $T3
assert test "$(last)" = "repo2 test_box.sh: owed here: could not run at $(s2): bench: no run lock on stub (it does not answer)"
assert test "$(ls "$R2"/docs/handoffs | wc -l | tr -d ' ')" = 1
assert test "$(grep -c ' step ' "$LOG")" = "$steps"
assert test ! -e "$ST2/open"
# A could-not-run run holds that box for its period; a tick between is cheap.
n=$(brun)
tick $((T3 + 60))
assert test "$(brun)" = "$n"
assert test "$(last)" = 'repo2 test_box.sh: owed bench: not due (tried 0 h 1 min ago, every 3 h); owed here: not due (tried 0 h 1 min ago, every 3 h)'
tick $((T3 + 86400 + 60))
assert test "$(grep -c 'owed on here since' "$LIMIT_HITS_LOG")" = 1
assert test "$(grep -c 'owed on bench since' "$LIMIT_HITS_LOG")" = 1
assert test "$(jq -r .limit "$LIMIT_HITS_LOG" | sort -u)" = 'llm-legs:scheduled-suites.owed'
tick $((T3 + 86400 + 4 * H))
assert test "$(wc -l <"$LIMIT_HITS_LOG" | tr -d ' ')" = 2
SCHEDULED_SUITES_NOW=$((T3 + 86400 + 4 * H)) "$S" status >"$WORK/status.out"
assert grep -qE "^  here   finished on [0-9a-f]{12} .*, red; owed since .* \(1 d 12 h\): could not run at $(s2): bench: no run lock on stub \(it does not answer\); the doctor told$" "$WORK/status.out"
# The build broken outside the diff (red at main and at its last good too): could not run, no bisect, no handoff.
echo failall >"$BOX/mode"
tick $((T3 + 86400 + 8 * H))
assert test "$(last)" = "repo2 test_box.sh: owed here: red at $(s2) and at its last good $(cut -c1-12 "$ST2/box-here/good") too: the cause is not in the diff (FAIL: test_box.sh: the Release build failed: xcode-select: no developer tools)"
assert test "$(ls "$R2"/docs/handoffs | wc -l | tr -d ' ')" = 1
assert test "$(grep -c ' step ' "$LOG")" = "$steps"

# A cut run (the Mac slept or rebooted mid-run: every process gone at once) records nothing: the next tick runs it
# again, the period not eaten.
echo hang >"$BOX/mode"; rm -f "$BOX/hang.pid"
T4=$((T3 + 86400 + 12 * H))
SCHEDULED_SUITES_NOW=$T4 "$S" tick &
tp=$!
"$ROOT/bin/wait-until" --max 30 files "$BOX/hang.pid" 1 >/dev/null
tree() { local p; echo "$1"; for p in $(pgrep -P "$1"); do tree "$p"; done; }
pids=$(tree "$tp")
kill -STOP $pids 2>/dev/null; kill -9 $pids 2>/dev/null; wait "$tp" 2>/dev/null
rm -f "$BOX/mode"; n=$(brun)
tick $((T4 + 60))
assert grep -q "repo2 test_box.sh: owed here: the run started .* was cut (no result)$" "$LOG"
assert test "$(brun)" = $((n + 1))
assert test "$(last)" = "repo2 test_box.sh: ran here: green at $(s2)"
# The cap cuts the same way: no result, owed, run again by the next tick.
echo hang >"$BOX/mode"; c2 3
SCHEDULED_SUITES_CAP_S=1 tick $((T4 + 4 * H))
assert test "$(last)" = "repo2 test_box.sh: owed here: cut at the cap (1 s) at $(s2) (no result): it runs again"
rm -f "$BOX/mode"
tick $((T4 + 4 * H + 60))
assert test "$(last)" = "repo2 test_box.sh: ran here: green at $(s2)"
# A tick lock written before the boot names a pid of the last boot, maybe reused now: cleared.
mkdir -p "$SCHEDULED_SUITES_DIR/.tick.lock" && printf '%s\n' "$$" >"$SCHEDULED_SUITES_DIR/.tick.lock/pid"
touch -t 202601010000 "$SCHEDULED_SUITES_DIR/.tick.lock/pid"
SCHEDULED_SUITES_BOOT=$(date +%s) tick $((T4 + 4 * H + 120))
assert test "$(last)" = 'repo2 test_box.sh: owed bench: not due (tried 0 h 2 min ago, every 3 h)'

# ---- A box's first red run (Egor 2026-11-14 04:20, chats-app test_swift_perf.sh: the bench red on its first run named
# main's innocent newest commit, "(passed at )" empty, this Mac's readings as the bench's "was", each key twice). A
# stub suite with two keys: k3's budget the same on both boxes (the bench reads $BOX/off more), w3's 20 here and 10 on
# the bench (marked `, m1`, as perf-judge prints); each FAIL line printed again at the end, as perf-judge's summary.
mkperf() { # repo
  mkdir -p "$1/tests" "$1/src"
  git -C "$1" init -q
  cat >"$1/tests/test_perf3.sh" <<'EOF'
#!/usr/bin/env bash
where=here; [ -e "$BOX/open" ] && where=bench
[ "$where" = bench ] || echo "test_perf3.sh: on this Mac, the bench is closed (stub)" >&2
echo "$where $(cat src/value) $(cat src/wait)" >>"$BOX/runs"
bad=''
judge() { # key got budget mark
  if [ "$2" -le "$3" ]; then echo "perf $1: $2 n (budget $3$4)"
  else echo "FAIL: perf $1: $2 n over budget $3 (set at: t). Fix: f"; bad+="FAIL: perf $1: $2 n over budget $3 (set at: t). Fix: f"$'\n'; fi
}
off=0; [ "$where" = here ] || off=$(cat "$BOX/off" 2>/dev/null || echo 0)
judge k3 $(($(cat src/value) + off)) 4 ''
if [ "$where" = bench ]; then judge w3 "$(cat src/wait)" 10 ', m1'; else judge w3 "$(cat src/wait)" 20 ''; fi
[ "$where" = here ] || echo "[bench 1 s, fallback alone] done"
[ -z "$bad" ] || { printf '%s' "$bad"; exit 1; }
EOF
  cat >"$1/tests/scheduled-suites" <<'EOF'
box bench ready [ -e "$BOX/open" ] || { echo "stub bench closed"; exit 1; }
box bench says ^\[bench [0-9]+ s,
box here says : on this Mac, the bench is closed
test_perf3.sh 3 boxes=bench,here needs=bench
EOF
  printf '%s\n' "$1" >"$SCHEDULED_SUITES_REPOS"
}
cv() { # repo value wait subject
  printf '%s\n' "$2" >"$1/src/value"; printf '%s\n' "$3" >"$1/src/wait"; git -C "$1" add -A; git -C "$1" commit -qm "$4"
}
s12() { git -C "$1" rev-parse "${2:-main}" | cut -c1-12; }
T5=$((T4 + 100 * H))

# The bench's first run red, here green two covered commits back: searched from here's green commit, on the bench.
BOX="$WORK/box3" R3="$WORK/repo3"; mkdir -p "$BOX"; mkperf "$R3"
cv "$R3" 1 5 init; a3=$(s12 "$R3")
tick $T5
assert test "$(last)" = "repo3 test_perf3.sh: ran here: green at $a3"
cv "$R3" 2 5 'value 2'; b3=$(s12 "$R3")
cv "$R3" 5 15 'value 5, wait 15: the regression'; c3=$(s12 "$R3")
mkdir -p "$R3/docs" && echo n >"$R3/docs/notes.md" && git -C "$R3" add -A && git -C "$R3" commit -qm 'notes: not covered'
touch "$BOX/open"
tick $((T5 + H))
doc3=$(ls "$R3"/docs/handoffs/*-scheduled-test_perf3-"${c3:0:7}".md 2>/dev/null)
assert test -n "$doc3"
assert test "$(last)" = "repo3 test_perf3.sh: ran bench: red from $c3 (passed at $b3; green on here at $a3; first run on bench); reported in ${doc3#"$R3"/}"
assert grep -qF "on bench fails from \`$c3\` (" "$doc3"
assert grep -qF "; passed at $b3; green on here at $a3; first run on bench): value 5, wait 15: the regression" "$doc3"
assert grep -qxF -- '- `k3`: was 2, now 5 n' "$doc3"
assert grep -qxF -- '- `w3`: was 5, now 15 n' "$doc3"
assert test "$(grep -c '^- `' "$doc3")" = 2
assert grep -qxF 'The commit'"'"'s files: `src/value`, `src/wait`.' "$doc3"
assert grep -qF "test_perf3.sh red on main from $c3 value 5, wait 15: the regression (passed at $b3; green on here at $a3; first run on bench): $doc3" "$SCHEDULED_SUITES_DIR/repo3/test_perf3.sh/open"
cp "$doc3" "$WORK/first-run-searched.md"

# No green run on any box: no search, "red at <sha>, first measured", no commit's files.
BOX="$WORK/box4" R4="$WORK/repo4"; mkdir -p "$BOX"; mkperf "$R4"; touch "$BOX/open"
cv "$R4" 5 5 'value 5 from the start'; a4=$(s12 "$R4")
tick $T5
doc4=$(ls "$R4"/docs/handoffs/*-scheduled-test_perf3-"${a4:0:7}".md 2>/dev/null)
assert test -n "$doc4"
assert test "$(last)" = "repo4 test_perf3.sh: ran bench: red at $a4, first measured; reported in ${doc4#"$R4"/}"
assert grep -qxF "# Hand-off: tests/test_perf3.sh red at $a4, first measured (the scheduled run)" "$doc4"
assert grep -qxF -- '- `k3`: now 5 n' "$doc4"
assert test "$(grep -c '^- `' "$doc4")" = 1
assert test -z "$(grep -e "commit's files" -e 'src/value' -e 'passed at' -e ' from ' "$doc4")"
assert test "$(cat "$SCHEDULED_SUITES_DIR/repo4/test_perf3.sh/open")" = "test_perf3.sh red at $a4, first measured: $doc4"
SCHEDULED_SUITES_NOW=$T5 "$S" status >"$WORK/status.out"
assert grep -qF "; open: test_perf3.sh red at $a4, first measured: $doc4" "$WORK/status.out"
cp "$doc4" "$WORK/first-measured.md"

# Red on the bench at here's green commit too: first measured; here's reading labelled, w3's (a budget by box) left out.
BOX="$WORK/box5" R5="$WORK/repo5"; mkdir -p "$BOX"; mkperf "$R5"
cv "$R5" 3 15 init; a5=$(s12 "$R5")
tick $T5
echo x >"$R5/src/other" && git -C "$R5" add -A && git -C "$R5" commit -qm other; c5=$(s12 "$R5")
touch "$BOX/open"; echo 3 >"$BOX/off"
tick $((T5 + H))
doc5=$(ls "$R5"/docs/handoffs/*-scheduled-test_perf3-"${c5:0:7}".md 2>/dev/null)
assert test "$(last)" = "repo5 test_perf3.sh: ran bench: red at $c5, first measured; reported in ${doc5#"$R5"/}"
assert grep -qxF "Red on bench at $a5 too, where here was green: no commit of main is the cause." "$doc5"
assert grep -qxF -- '- `k3`: was 3 on here, now 6 n' "$doc5"
assert grep -qxF -- '- `w3`: now 15 n' "$doc5"
assert test -z "$(grep -e "commit's files" -e 'src/other' "$doc5")"

# --install-agent: the plist starts the libexec wrapper of the script (Login Items show its name), every 15 min; again,
# a no-op.
"$S" --install-agent >"$WORK/agent.out"
PL="$HOME/Library/LaunchAgents/com.llm-legs.scheduled-suites.plist"
assert test "$(plutil -extract ProgramArguments.0 raw "$PL")" = "$HOME/.local/libexec/scheduled-suites"
assert grep -qxF "exec $S \"\$@\"" "$HOME/.local/libexec/scheduled-suites"
assert test "$(plutil -extract ProgramArguments.1 raw "$PL")" = tick
assert test "$(plutil -extract StartInterval raw "$PL")" = 900
# After a boot the owed runs start at the login, not 15 min later.
assert test "$(plutil -extract RunAtLoad raw "$PL")" = true
assert grep -q '^bootstrap ' "$WORK/launchctl.calls"
touch "$WORK/loaded"
"$S" --install-agent >"$WORK/agent.out"
assert grep -q 'already loaded' "$WORK/agent.out"
# A reload while a tick runs: bootout answers before the job is gone and the first bootstrap fails; tried again.
rm -f "$WORK/loaded"; touch "$WORK/busy"; : >"$WORK/launchctl.calls"
printf '#!/bin/sh\necho "$*" >>"%s/launchctl.calls"\nif [ "$1" = bootstrap ] && [ -e "%s/busy" ]; then rm "%s/busy"; exit 5; fi\n[ "$1" != print ] || [ -e "%s/loaded" ]\n' "$WORK" "$WORK" "$WORK" "$WORK" >"$WORK/shim/launchctl"
"$S" --install-agent >"$WORK/agent.out" 2>&1
assert grep -q 'loaded (every' "$WORK/agent.out"
assert test "$(grep -c '^bootstrap ' "$WORK/launchctl.calls")" = 2

printf 'PASS: %s asserts; scheduled-suites decides cheaply, bisects a red main to its commit, reports it once and settles it\n' "$asserts"
