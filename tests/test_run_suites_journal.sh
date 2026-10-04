#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# The run-suites journal: one row per run-suites run, one per direct `bash tests/x.sh` run.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'touch "$WORK/release"; sleep 0.3; [ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts unexpectedly held: $*"; }
jqe() { jq -e "$@" >/dev/null; }
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/xdg" HARNESS_HOLDS_DIR="$WORK/holds" STATUSLINE_CACHE_DIR="$WORK/sl" \
  RUN_SUITES_TIMES="$WORK/rs/times.tsv" RUN_SUITES_SLOTS_DIR="$WORK/slots" SLOTS_POLL_S=0.2
unset RUN_SUITES_SLOT RUN_SUITES_JOURNAL SUITE_JOURNAL SUITE_JOURNAL_PID WORKER_RUN_ID CLAUDE_LAUNCHER_SESSION
LIB="$ROOT/tests/lib/suite-journal.sh"
JOURNAL="$WORK/rs/runs.jsonl"
KEYS='["complete","ended_at","head","j","kind","pid","queued_at","repo","repo_root","scope","session","signal","slot","started_at","suite_set","suites","worker_run"]'
mkdir -p "$HOME" "$WORK/rs"

new_repo() { # dir
  mkdir -p "$1/tests"
  git -C "$1" init -q
  git -C "$1" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -q --allow-empty -m init
}
suite() { # repo name body
  printf '#!/usr/bin/env bash\n. "%s"\n%s\n' "$LIB" "$3" >"$1/tests/$2"
}
REPO="$WORK/repo"
new_repo "$REPO"
SHA=$(git -C "$REPO" rev-parse HEAD)
suite "$REPO" test_cpu.sh 'i=0; while [ "$i" -lt 30000 ]; do i=$((i + 1)); done'
suite "$REPO" test_env.sh "env | grep -E '^(WORKER_RUN_ID|SUITE_JOURNAL_PID)=' >\"$WORK/env.out\"; exit 0"
suite "$REPO" test_fail.sh 'exit 3'
printf '%s\ttest_gone.sh\t5\n/elsewhere\ttest_gone.sh\t5\n' "$REPO" >"$RUN_SUITES_TIMES"

# A full run: its row names the run, the worker and chat it ran for, and each suite's verdict and CPU;
# the suites it ran, which source the library too, journal nothing of their own.
WORKER_RUN_ID=wr-7 CLAUDE_CODE_SESSION_ID=sess-7 bash "$ROOT/share/run-suites.sh" --repo "$REPO" -j 2 >/dev/null 2>&1
assert test "$(wc -l <"$JOURNAL" | tr -d ' ')" = 1
assert jqe --argjson keys "$KEYS" --arg repo "$REPO" --arg sha "$SHA" --arg slots "$WORK/slots/" '
  (keys == $keys) and .kind == "suites" and (.pid | type == "number") and .queued_at <= .started_at
  and .started_at < .ended_at and .repo == $repo and .repo_root == $repo and .head == $sha and .scope == "full"
  and .worker_run == "wr-7" and .session == "sess-7" and .j == 2 and (.slot | startswith($slots))
  and .signal == null and .complete == true and (.suite_set | test("^[0-9a-f]{8}$"))
  and (.suites | keys) == ["test_cpu.sh","test_env.sh","test_fail.sh"]
  and ([.suites[].rc] == [0,0,3]) and all(.suites[]; (.secs | type == "number") and (.cpu_s | type == "number") and .forks == null)
  and .suites["test_cpu.sh"].cpu_s > 0 and .suites["test_cpu.sh"].secs > 0' "$JOURNAL"
run_pid=$(jq -r .pid "$JOURNAL")
assert test "$(cat "$WORK/env.out")" = "SUITE_JOURNAL_PID=$run_pid"
# A bash with wait -n but no EPOCHREALTIME (4.3, 4.4) leaves a suite's start empty; its CPU stays CPU.
bash -c 'unset EPOCHREALTIME; . "$0" "$@"' "$ROOT/share/run-suites.sh" --repo "$REPO" -j 2 >/dev/null 2>&1
assert jqe '.suites["test_cpu.sh"] | (.cpu_s | type == "number") and .cpu_s > 0' <(tail -1 "$JOURNAL")
sed -i '' '$d' "$JOURNAL"
assert test ! -e "$XDG_CACHE_HOME/run-suites/runs.jsonl"
# times.tsv forgets a suite whose file is gone, for this checkout only.
assert grep -qx $'/elsewhere\ttest_gone.sh\t5' "$RUN_SUITES_TIMES"
assert_fails grep -q $'\ttest_gone.sh\t5$' <(grep -v '^/elsewhere' "$RUN_SUITES_TIMES")
assert grep -q "^$REPO"$'\ttest_cpu.sh\t' "$RUN_SUITES_TIMES"
mkdir -p "$WORK/extra"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/extra/test_extra.sh"
bash "$ROOT/share/run-suites.sh" --repo "$REPO" "$WORK/extra/test_extra.sh" >/dev/null 2>&1
assert grep -q "^$REPO"$'\ttest_extra.sh\t' "$RUN_SUITES_TIMES"

# One suite named alone has the set digest a direct run of it has; the full set has another.
bash "$ROOT/share/run-suites.sh" --repo "$REPO" test_cpu.sh >/dev/null 2>&1
named=$(tail -1 "$JOURNAL")
assert jqe '.scope == "named" and .worker_run == null and (.suites | keys) == ["test_cpu.sh"]' <<<"$named"
SUITE_JOURNAL="$WORK/direct.jsonl" bash "$REPO/tests/test_cpu.sh"
assert test "$(jq -r .suite_set "$WORK/direct.jsonl")" = "$(jq -r .suite_set <<<"$named")"
assert test "$(jq -r .suite_set "$WORK/direct.jsonl")" != "$(head -1 "$JOURNAL" | jq -r .suite_set)"

# A linked worktree's run folds into its main checkout, at the worktree's own HEAD.
git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/wt"
mkdir -p "$REPO/.claude/worktrees/wt/tests"
cp "$REPO/tests/test_cpu.sh" "$REPO/.claude/worktrees/wt/tests/"
bash "$ROOT/share/run-suites.sh" --repo "$REPO/.claude/worktrees/wt" test_cpu.sh >/dev/null 2>&1
assert jqe --arg repo "$REPO" --arg sha "$SHA" '.repo == $repo + "/.claude/worktrees/wt" and .repo_root == $repo and .head == $sha' \
  <(tail -1 "$JOURNAL")
SUITE_JOURNAL="$WORK/wt.jsonl" /bin/bash "$REPO/.claude/worktrees/wt/tests/test_cpu.sh"
assert jqe --arg repo "$REPO" --arg sha "$SHA" '.repo == $repo + "/.claude/worktrees/wt" and .repo_root == $repo and .head == $sha' \
  "$WORK/wt.jsonl"

# A run stopped by a signal writes its row, incomplete, gives up its slot and still dies of the signal.
R2="$WORK/r2"
new_repo "$R2"
suite "$R2" test_quick.sh 'exit 0'
suite "$R2" test_wait.sh "while [ ! -e \"$WORK/release\" ]; do sleep 0.2; done"
bash "$ROOT/share/run-suites.sh" --repo "$R2" -j 2 >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 300); do
  [ -f "$STATUSLINE_CACHE_DIR/suites-$pid" ] && read -r logdir _ <"$STATUSLINE_CACHE_DIR/suites-$pid" &&
    [ -f "$logdir/test_quick.sh.status" ] && break
  sleep 0.1
done
kill -TERM "$pid"
wait "$pid"
assert test "$?" = 143
assert jqe --arg repo "$R2" '.repo == $repo and .signal == 15 and .complete == false and (.suites | keys) == ["test_quick.sh"]' \
  <(tail -1 "$JOURNAL")
assert_fails grep -qx "$pid" <(cat "$WORK"/slots/*/pid 2>/dev/null)
assert test -f "$STATUSLINE_CACHE_DIR/suites-$pid.done"

# signal group|pid command... once $READY exists -> "<returncode> <ms from signal to exit>"; a negative
# returncode is a death by that signal. Dispositions reset: `< <(...)` starts it with SIGINT ignored.
cat >"$WORK/sigrun.py" <<'PY'
import os, signal, subprocess, sys, time
sig, target, cmd = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
for inherited in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(inherited, signal.SIG_DFL)
p = subprocess.Popen(cmd, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(600):
    if os.path.exists(os.environ["READY"]): break
    time.sleep(0.05)
at = time.time()
os.killpg(p.pid, sig) if target == "group" else p.send_signal(sig)
rc = p.wait()
print(rc, int((time.time() - at) * 1000))
PY
sigrun() { READY=$1 python3 "$WORK/sigrun.py" "${@:2}"; }
alive() { kill -0 "$1" 2>/dev/null; }
# The serial tail stops at once too, on a TERM to the runner alone and on a Ctrl-C to the group, which
# ends the suite with it; each run dies of its signal and journals it.
R4="$WORK/r4"
new_repo "$R4"
suite "$R4" test_commit_journal.sh "printf '%s\\n' \"\$\$\" >\"$WORK/tail-pid\"; touch \"$WORK/tail-ready\"; sleep 10"
for case in "15 pid" "2 group"; do
  rm -f "$WORK/tail-ready" "$WORK/tail-pid"
  read -r rc ms < <(sigrun "$WORK/tail-ready" ${case} bash "$ROOT/share/run-suites.sh" --repo "$R4")
  assert test "$rc" = "-${case% *}"
  assert test "$ms" -lt 2000
  assert jqe --arg repo "$R4" --argjson sig "${case% *}" '.repo == $repo and .signal == $sig and .complete == false' <(tail -1 "$JOURNAL")
done
sleep 0.5
assert_fails alive "$(cat "$WORK/tail-pid")"

# A direct run, under macOS bash 3.2 and a modern one: its row goes where the journal pointed when
# it started, whatever HOME it sets; its own EXIT trap still runs and its exit code stays its own;
# a subshell's trap adds no row.
suite "$REPO" test_trap.sh "set -e
HOME=\"$WORK/elsewhere\"
trap 'rm -f \"$WORK/marker-\$1\"' EXIT
touch \"$WORK/marker-\$1\"
( trap 'echo sub >/dev/null' EXIT; true )
[ \"\${2:-0}\" = 0 ] || false
exit \"\${3:-0}\""
for b in /bin/bash "$BASH"; do
  tag=${b//\//_}
  rm -f "$WORK/h/.cache/run-suites/runs.jsonl" "$WORK/rcs$tag"
  for args in "a$tag 0 0" "b$tag 1 0" "c$tag 0 5"; do
    env -u XDG_CACHE_HOME HOME="$WORK/h" "$b" "$REPO/tests/test_trap.sh" $args
    printf '%s\n' "$?" >>"$WORK/rcs$tag"
  done
  assert test "$(paste -sd' ' - <"$WORK/rcs$tag")" = '0 1 5'
  assert test -z "$(ls "$WORK" | grep '^marker-')"
  assert jqe -s --argjson keys "$KEYS" --arg repo "$REPO" --arg sha "$SHA" 'length == 3
    and all(.[]; (keys == $keys) and .kind == "direct" and .scope == "direct" and .j == 1 and .slot == null
      and .signal == null and .complete == true and .repo == $repo and .repo_root == $repo and .head == $sha
      and .queued_at == .started_at and .started_at <= .ended_at and (.suites | keys) == ["test_trap.sh"]
      and (.suites["test_trap.sh"] | (.cpu_s | type == "number") and (.secs | type == "number") and .forks == null))
    and [.[].suites["test_trap.sh"].rc] == [0,1,5]' "$WORK/h/.cache/run-suites/runs.jsonl"
done
assert test ! -e "$WORK/elsewhere"
# One that already journals (a run-suites suite, a nested test) adds none.
SUITE_JOURNAL="$WORK/nested.jsonl" SUITE_JOURNAL_PID=1 bash "$REPO/tests/test_cpu.sh"
assert test ! -e "$WORK/nested.jsonl"
# A test that traps TERM itself is journaled as stopped by it.
suite "$REPO" test_term.sh "trap 'exit 1' TERM
touch \"$WORK/term-ready\"
while :; do sleep 0.1; done"
for b in /bin/bash "$BASH"; do
  rm -f "$WORK/term-ready"
  SUITE_JOURNAL="$WORK/term.jsonl" "$b" "$REPO/tests/test_term.sh" &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$WORK/term-ready" ] && break; sleep 0.1; done
  kill -TERM "$pid"
  wait "$pid"
done
assert jqe -s 'length == 2 and all(.[]; .signal == 15 and .complete == false and .suites["test_term.sh"].rc == 143)' "$WORK/term.jsonl"
# `trap - EXIT HUP` gives HUP back to the journal, never ignores it; a test's own signal action still reads its $?.
# HUP, not INT: run-suites starts suites in the background, where INT is ignored and untrappable.
suite "$REPO" test_untrap.sh "trap 'true' EXIT
trap - EXIT HUP
trap -p HUP >\"$WORK/untrap-\$1\"
trap 'printf %s \"\$?\" >\"$WORK/sig-rc-\$1\"' TERM
sh -c 'kill -TERM \$PPID; exit 7'"
for b in /bin/bash "$BASH"; do
  tag=${b//\//_}
  SUITE_JOURNAL="$WORK/untrap.jsonl" "$b" "$REPO/tests/test_untrap.sh" "$tag"
  assert grep -q 'suite_journal_die 1' "$WORK/untrap-$tag"
  assert test "$(cat "$WORK/sig-rc-$tag")" = 7
done
# A row over 1 KiB in bytes goes through the single dd write, however few characters it has.
LC_ALL=en_US.UTF-8 bash -c '. "$1" --lib
  log=$2
  dd() { echo dd >>"$log"; command dd "$@"; }
  suite_journal_line=$(printf "é%.0s" $(seq 1 600))
  suite_journal_append "$3"' _ "$ROOT/tests/lib/suite-journal.sh" "$WORK/dd.log" "$WORK/mb.jsonl"
assert grep -qx dd "$WORK/dd.log"
assert test "$(wc -c <"$WORK/mb.jsonl" | tr -d ' ')" = 1201
# One that traps nothing, or resets its own trap, is journaled as stopped by the signal, never with its last status: its EXIT
# action still runs and it still dies of the signal. A SIGKILL leaves no row.
suite "$REPO" test_sig.sh "trap : HUP INT TERM
trap - HUP INT TERM
trap 'rm -f \"$WORK/sig-marker\"' EXIT
touch \"$WORK/sig-marker\" \"$WORK/sig-ready\"
while :; do sleep 0.1; done"
suite "$REPO" test_bare.sh "touch \"$WORK/sig-ready\"
while :; do sleep 0.1; done"
for b in /bin/bash "$BASH"; do
  rm -f "$WORK/sig-ready" "$WORK/bare.jsonl"
  read -r rc ms < <(SUITE_JOURNAL="$WORK/bare.jsonl" sigrun "$WORK/sig-ready" 15 pid "$b" "$REPO/tests/test_bare.sh")
  assert test "$rc" = -15
  assert jqe -s 'length == 1 and .[0].signal == 15 and .[0].complete == false' "$WORK/bare.jsonl"
  for sig in 1 2 15 9; do
    rm -f "$WORK/sig-ready" "$WORK/sig.jsonl"
    read -r rc ms < <(SUITE_JOURNAL="$WORK/sig.jsonl" sigrun "$WORK/sig-ready" "$sig" pid "$b" "$REPO/tests/test_sig.sh")
    assert test "$rc" = "-$sig"
    if [ "$sig" = 9 ]; then assert test ! -e "$WORK/sig.jsonl"; continue; fi
    assert test ! -e "$WORK/sig-marker"
    assert jqe -s --argjson sig "$sig" 'length == 1 and .[0].signal == $sig and .[0].complete == false
      and .[0].suites["test_sig.sh"].rc == 128 + $sig' "$WORK/sig.jsonl"
  done
done

# HEAD through packed refs, read without git.
R3="$WORK/r3"
new_repo "$R3"
git -C "$R3" pack-refs --all
assert test ! -e "$R3/.git/$(git -C "$R3" symbolic-ref HEAD)"
suite "$R3" test_p.sh 'exit 0'
SUITE_JOURNAL="$WORK/packed.jsonl" /bin/bash "$R3/tests/test_p.sh"
assert test "$(jq -r .head "$WORK/packed.jsonl")" = "$(git -C "$R3" rev-parse HEAD)"

# Rows longer than one 1 KiB write stay whole beside concurrent appends.
long=$(printf '%03000d' 0)
for w in 1 2 3 4; do
  bash -c '. "$1" --lib; for i in $(seq 1 40); do suite_journal_line="{\"w\":$2,\"pad\":\"$3\"}"; suite_journal_append "$4"; done' \
    _ "$LIB" "$w" "$long" "$WORK/race.jsonl" &
done
wait
assert test "$(jq -cR 'fromjson? | .w' "$WORK/race.jsonl" | wc -l | tr -d ' ')" = 160
assert test -z "$(ls "$WORK" | grep '\.row$')"

# --changed keeps a split suite whose sourced harness names the changed file, and drops the bystander.
R4="$WORK/r4"
new_repo "$R4"
mkdir -p "$R4/bin"
printf 'echo v1\n' >"$R4/bin/tool.sh"
printf 'SCRIPT="$(dirname "$0")/../bin/tool.sh"\n' >"$R4/tests/tool_harness.sh"
suite "$R4" test_tool_part.sh '. "$(dirname "$0")/tool_harness.sh"; exit 0'
suite "$R4" test_other.sh 'exit 0'
git -C "$R4" add -A
git -C "$R4" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -q -m suites
printf 'echo v2\n' >"$R4/bin/tool.sh"
changed_out=$(bash "$ROOT/share/run-suites.sh" --repo "$R4" -j 2 --changed 2>&1)
assert grep -q 'test_tool_part.sh .*PASS' <<<"$changed_out"
assert_fails grep -q 'test_other.sh' <<<"$changed_out"
# tests/affected: the same suites for named files, test_consistency.sh for a file shared-invariants
# names, never a live-machine suite, and nothing for a file no suite names.
suite "$R4" e2e_surfaces.sh 'echo tool.sh; exit 0'
assert test "$(bash "$ROOT/share/affected-suites.sh" --repo "$R4" bin/tool.sh)" = "$R4/tests/test_tool_part.sh"
assert test "$(bash "$ROOT/share/affected-suites.sh" --repo "$R4" share/limiter-hold.sh)" = "$ROOT/tests/test_consistency.sh"
assert test -z "$(bash "$ROOT/share/affected-suites.sh" --repo "$R4" nowhere-named.txt)"
assert grep -qx "$ROOT/tests/test_slots.sh" <<<"$(bash "$ROOT/tests/affected" share/slots.sh)"

# A suite that posts into the runner's own report queue fails though it exits 0; one on a cache of its
# own passes, and the live queue receives nothing.
R5="$WORK/r5"
new_repo "$R5"
post_leak="printf '{\"word\":\"t\",\"rows\":[[\"a\",\"b\"]]}' | bash '$ROOT/bin/report-bus' post --kind notice --id leak --session leaky"
suite "$R5" test_leaks.sh "$post_leak; exit 0"
suite "$R5" test_sandboxed.sh "XDG_CACHE_HOME=\"\$TMPDIR/cache\"; export XDG_CACHE_HOME; $post_leak; exit 0"
leak_out=$(bash "$ROOT/share/run-suites.sh" --repo "$R5" -j 2 2>&1)
assert grep -q 'test_leaks.sh .*FAIL' <<<"$leak_out"
assert grep -q 'test_sandboxed.sh .*PASS' <<<"$leak_out"
assert test ! -e "$XDG_CACHE_HOME/claude-reports/leaky"
assert jqe '.suites["test_leaks.sh"].rc == 1 and .suites["test_sandboxed.sh"].rc == 0' <(tail -1 "$JOURNAL")

printf 'PASS: %s asserts; run-suites and direct suite runs journal one row each\n' "$asserts"
