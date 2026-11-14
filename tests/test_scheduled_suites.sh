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
assert test "$(last)" = "repo test_stub.sh: green at $(sha main | cut -c1-12)"
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
assert test "$(last)" = "repo test_stub.sh: red from ${bad:0:12} (passed at $(sha "$bad~1" | cut -c1-12)); reported in ${doc#"$R"/}"
# 1 + 2 at main + steps (value 3 skipped, value 4 pass, value 5 fail, at most one more)
assert test "$(runs)" -ge 6
assert test "$(runs)" -le 7
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
assert test "$(last)" = "repo test_stub.sh: still red at $(sha main | cut -c1-12), reported: $doc"
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
assert test "$(last)" = "repo test_stub.sh: green again at $(sha main | cut -c1-12); settled ${doc#"$R"/}"
assert test -z "$(bash "$ROOT/share/affected-suites.sh" --repo "$R" docs/x.md 2>&1)"
# The run's worktree is its own, detached, and the main checkout stays on main.
assert test "$(git -C "$R" symbolic-ref --short HEAD)" = main
assert test -z "$(git -C "$ST/wt" symbolic-ref -q HEAD)"

# --install-agent: the plist starts the libexec wrapper of the script (Login Items show its name), every 15 min; again,
# a no-op.
"$S" --install-agent >"$WORK/agent.out"
PL="$HOME/Library/LaunchAgents/com.llm-legs.scheduled-suites.plist"
assert test "$(plutil -extract ProgramArguments.0 raw "$PL")" = "$HOME/.local/libexec/scheduled-suites"
assert grep -qxF "exec $S \"\$@\"" "$HOME/.local/libexec/scheduled-suites"
assert test "$(plutil -extract ProgramArguments.1 raw "$PL")" = tick
assert test "$(plutil -extract StartInterval raw "$PL")" = 900
assert grep -q '^bootstrap ' "$WORK/launchctl.calls"
touch "$WORK/loaded"
"$S" --install-agent >"$WORK/agent.out"
assert grep -q 'already loaded' "$WORK/agent.out"

printf 'PASS: %s asserts; scheduled-suites decides cheaply, bisects a red main to its commit, reports it once and settles it\n' "$asserts"
