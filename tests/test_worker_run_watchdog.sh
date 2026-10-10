#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# shards: 4 wait
. "$(dirname "$0")/worker_run_harness.sh" || exit 1

watchdog_tests() {
if suite_shard_owns 1 wd-deadline; then
# A wedged vendor CLI is killed at the deadline and the run turns terminal.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=wedged STUB_SLEEP=30 WORKER_RUN_DEADLINE=1
launched=$(date +%s)
start_ok codex
unset STUB_SLEEP WORKER_RUN_DEADLINE
deadline_wait=$("$RUNNER" wait "$RUN_ID" --max 30)
assert grep -q '^STATUS: failed$' <<<"$deadline_wait"
assert grep -qx 'OUTCOME: CODEX_UNAVAILABLE' <<<"$deadline_wait"
# And says which watchdog did it: a bare 143 sends the reader hunting a vendor fault.
assert grep -q '^KILLED: deadline — the 1s ceiling' <<<"$deadline_wait"
# The end and its reason are stamped apart: started_at keeps the launch it budgets the deadline from.
assert jq -e --argjson l "$launched" '.terminal_reason == "deadline" and .started_at >= $l
  and .started_at <= .cli_starts[0] and .ended_at >= .started_at + 1 and .attempt_rcs == [143]' "$RUN_DIR/meta.json" >/dev/null
fi

if suite_shard_owns 1 wd-lastwords; then
  # A run the deadline ended has no final answer, and its report carries its last messages instead.
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=lastwords STUB_SLEEP=30 WORKER_RUN_DEADLINE=2 STUB_TRANSCRIPT_SESSION=lastwords-session \
    STUB_TRANSCRIPT_ACCOUNT=lastwords STUB_TRANSCRIPT_SAY='Traced 40 of 120 files; next the c46 set.'
  start_ok claudeb
  unset STUB_SLEEP WORKER_RUN_DEADLINE STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT STUB_TRANSCRIPT_SAY
  "$RUNNER" wait "$RUN_ID" --max 30 >/dev/null
  lastwords_report=$("$RUNNER" report "$RUN_ID")
  assert grep -qx 'Traced 40 of 120 files; next the c46 set.' <<<"$lastwords_report"
  assert grep -q "^(no final answer; the worker's last messages:)$" <<<"$lastwords_report"
fi

if suite_shard_owns 1 wd-busy; then
# A worker that keeps writing is working, however long it takes: the idle watchdog reads the run's
# own files, and a suite that runs for minutes returns through them.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=busy STUB_HEARTBEAT=8 WORKER_RUN_IDLE_S=3 WORKER_RUN_DEADLINE=600
start_ok codex
unset STUB_HEARTBEAT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
busy_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: done$' <<<"$busy_wait"
assert jq -e '.terminal_reason == "done" and .attempt_secs[0] >= 7 and .ended_at - .started_at >= 7' "$RUN_DIR/meta.json" >/dev/null
fi

if suite_shard_owns 2 wd-idle; then
# A worker that writes nothing at all is wedged, and the ceiling is hours away.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=wedged STUB_SLEEP=60 WORKER_RUN_IDLE_S=2 WORKER_RUN_DEADLINE=600
start_ok codex
unset STUB_SLEEP WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
idle_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: failed$' <<<"$idle_wait"
assert grep -qx 'OUTCOME: CODEX_UNAVAILABLE' <<<"$idle_wait"
assert grep -q '^KILLED: idle watchdog — nothing this run writes changed for 2s' <<<"$idle_wait"
assert grep -q '^KILLED: idle watchdog' <<<"$("$RUNNER" report "$RUN_ID")"
assert jq -se --arg r "$RUN_ID" 'map(select(.run == $r)) | length == 1 and .[0].reason == "idle" and .[0].status == "failed"' \
  "$CLAUDEB_DIR/worker-stats/runs.jsonl" >/dev/null
fi

if suite_shard_owns 3 wd-patient; then
# WORKER_RUN_IDLE_S=0 disarms the idle half alone: the same silent stub runs to its own end.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=patient STUB_SLEEP=3 WORKER_RUN_IDLE_S=0 WORKER_RUN_DEADLINE=600
start_ok codex
unset STUB_SLEEP WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
assert grep -q '^STATUS: done$' <<<"$("$RUNNER" wait "$RUN_ID" --max 60)"
fi

if suite_shard_owns 4 wd-transcript-session; then
# A claudeb run killed before it could write `out` still names its session: the transcript carries
# the id from the first turn, and without it three hours of work cannot be resumed.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=picked STUB_SLEEP=60 STUB_TRANSCRIPT_SESSION=live-session-id \
  STUB_TRANSCRIPT_ACCOUNT=picked WORKER_RUN_IDLE_S=2 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
killed_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: failed$' <<<"$killed_wait"
# A located transcript IS an observable source, so its silence is evidence and the kill lands.
assert grep -q '^KILLED: idle watchdog — nothing this run writes changed for 2s' <<<"$killed_wait"
assert grep -qx 'SESSION: live-session-id' <<<"$killed_wait"
assert grep -qx 'SESSION: live-session-id' <<<"$("$RUNNER" report "$RUN_ID")"
# And the pairing the review hooks price a live run by is written while the run lives, not after.
assert grep -qxF 'live-session-id' "$RUN_DIR/worker-session"
# Matched on the brief this run was launched with, so a co-tenant run in the same profile tree
# cannot be adopted as this one. Recorded PHYSICALLY, which is the one spelling of a tree every
# profile reaches through a symlink of its own.
assert grep -qxF "$(cd "$CLAUDEB_PROFILES_ROOT/picked/projects" && pwd -P)/fixture/live-session-id.jsonl" \
  "$RUN_DIR/session-file"
fi

if suite_shard_owns 4 wd-linked-tree; then
# And a profile whose `projects` IS that symlink answers at all: `find` handed a symlinked directory
# as its own argument walks nothing, so every real profile here — each of them a link into the one
# shared tree — resolved no session for any live run until the root was resolved physically (live
# 2026-09-04: a 23-minute run reported `SESSION: -` and could not be resumed).
clear_stub
set_config 'claudeb_profile=pinned'
SHARED_TREE="$WORK/shared-transcripts"
mkdir -p "$SHARED_TREE" "$CLAUDEB_PROFILES_ROOT/linkedacct"
ln -sfn "$SHARED_TREE" "$CLAUDEB_PROFILES_ROOT/linkedacct/projects"
export PICK_RC=0 PICK_ACCOUNT=linkedacct STUB_SLEEP=60 STUB_TRANSCRIPT_SESSION=linked-session-id \
  STUB_TRANSCRIPT_ACCOUNT=linkedacct WORKER_RUN_IDLE_S=2 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
linked_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -qx 'SESSION: linked-session-id' <<<"$linked_wait"
assert grep -qxF "$(cd "$SHARED_TREE" && pwd -P)/fixture/linked-session-id.jsonl" \
  "$RUN_DIR/session-file"
assert grep -qxF 'linked-session-id' "$RUN_DIR/worker-session"
fi

if suite_shard_owns 3 wd-growing; then
# Silence is nothing happening ANYWHERE, not an empty `out`: claudeb in `--output-format json`
# writes its one line at the very end, so out/err stay empty for the whole run while the transcript
# grows — read as silence that killed a working run at ten minutes (live 2026-09-08,
# claudeb-1788874421-31215-0684). The silent verdict needs the fingerprint frozen too.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=growing STUB_SLEEP=6 STUB_TRANSCRIPT_SESSION=growing-session \
  STUB_TRANSCRIPT_ACCOUNT=growing STUB_TRANSCRIPT_GROW=1 \
  WORKER_RUN_SILENT_S=2 WORKER_RUN_IDLE_S=0 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT STUB_TRANSCRIPT_GROW \
  WORKER_RUN_SILENT_S WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
growing_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -qx 'STATUS: done' <<<"$growing_wait"
assert test "$(grep -c 'KILLED: silent' <<<"$growing_wait")" -eq 0
assert test ! -e "$RUN_DIR/killed"
# The run really did stay mute for longer than the window that would have killed it.
assert test "$(wc -l <"$CLAUDEB_PROFILES_ROOT/growing/projects/fixture/growing-session.jsonl")" -ge 3
fi

if suite_shard_owns 2 wd-paused; then
# A run that has worked and then sits in one long tool call (a suite, ten-plus minutes) freezes
# every source; that is IDLE's to judge, never silence (live 2026-09-24: two fixers killed mid-suite).
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=paused STUB_SLEEP=9 STUB_TRANSCRIPT_SESSION=paused-session \
  STUB_TRANSCRIPT_ACCOUNT=paused STUB_TRANSCRIPT_GROW=1 STUB_TRANSCRIPT_GROW_TURNS=3 \
  WORKER_RUN_SILENT_S=2 WORKER_RUN_IDLE_S=0 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT STUB_TRANSCRIPT_GROW \
  STUB_TRANSCRIPT_GROW_TURNS WORKER_RUN_SILENT_S WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
paused_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -qx 'STATUS: done' <<<"$paused_wait"
assert test "$(grep -c 'KILLED: silent' <<<"$paused_wait")" -eq 0
assert test ! -e "$RUN_DIR/killed"
assert test "$(wc -l <"$CLAUDEB_PROFILES_ROOT/paused/projects/fixture/paused-session.jsonl")" -eq 4
fi

if suite_shard_owns 3 wd-frozen; then
# And the same empty out/err with a transcript that never moves is still silence: killed.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=frozen STUB_SLEEP=6 STUB_TRANSCRIPT_SESSION=frozen-session \
  STUB_TRANSCRIPT_ACCOUNT=frozen WORKER_RUN_SILENT_S=2 WORKER_RUN_IDLE_S=0 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT \
  WORKER_RUN_SILENT_S WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
frozen_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -qx 'KILLED: silent — no output in 2s' <<<"$frozen_wait"
assert grep -qx 'silent 2' "$RUN_DIR/killed"
assert test ! -s "$RUN_DIR/out"
assert test ! -s "$RUN_DIR/err"
fi

if suite_shard_owns 1 wd-answered; then
# Found already holding the launch's first answer, then frozen: one long first tool call, no hung start.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=answered STUB_SLEEP=6 STUB_TRANSCRIPT_SESSION=answered-session \
  STUB_TRANSCRIPT_ACCOUNT=answered STUB_TRANSCRIPT_SAY='running the suite' \
  WORKER_RUN_SILENT_S=2 WORKER_RUN_IDLE_S=0 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT STUB_TRANSCRIPT_SAY \
  WORKER_RUN_SILENT_S WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
answered_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -qx 'STATUS: done' <<<"$answered_wait"
assert test ! -e "$RUN_DIR/killed"
fi

if suite_shard_owns 4 wd-symlink; then
# Through a SYMLINK, because that is the only shape a real profile has: `<profile>/projects` points
# at `~/.claude/projects`, and a walk that does not follow one answers an empty tree — so discovery
# never succeeded for any live claudeb run on this machine, the launcher pairing was never written
# while the run lived, and the watchdog was left with nothing to watch (live 2026-09-04).
clear_stub
set_config 'claudeb_profile=pinned'
mkdir -p "$CLAUDEB_PROFILES_ROOT/shared-corpus" "$CLAUDEB_PROFILES_ROOT/symacct"
ln -sfn ../shared-corpus "$CLAUDEB_PROFILES_ROOT/symacct/projects"
export PICK_RC=0 PICK_ACCOUNT=symacct STUB_SLEEP=60 STUB_TRANSCRIPT_SESSION=through-a-symlink \
  STUB_TRANSCRIPT_ACCOUNT=symacct WORKER_RUN_IDLE_S=2 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
symlinked_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -qx 'SESSION: through-a-symlink' <<<"$symlinked_wait"
assert grep -qxF 'through-a-symlink' "$RUN_DIR/worker-session"
fi

if suite_shard_owns 3 wd-foreign; then
# A transcript belonging to another task is not this run's session, whatever else the tree holds.
clear_stub
set_config 'claudeb_profile=pinned'
foreign_dir="$CLAUDEB_PROFILES_ROOT/picked/projects/fixture"
mkdir -p "$foreign_dir"
rm -f "$foreign_dir"/*.jsonl
# The ceiling ends this one, not the idle half: with no transcript of its own and no workdir edit
# to read, the run is unobservable, and only the deadline may end a run nobody can watch.
export PICK_RC=0 PICK_ACCOUNT=picked STUB_SLEEP=60 WORKER_RUN_IDLE_S=2 WORKER_RUN_DEADLINE=8
start_ok claudeb
jq -cn '{type:"user",message:{role:"user",content:"a different task entirely"}}' \
  >"$foreign_dir/foreign-session.jsonl"
unset STUB_SLEEP WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
foreign_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: failed$' <<<"$foreign_wait"
assert grep -qx 'SESSION: -' <<<"$foreign_wait"
assert grep -q '^KILLED: deadline — the 8s ceiling' <<<"$foreign_wait"
rm -f "$foreign_dir/foreign-session.jsonl"
fi

if suite_shard_owns 1 wd-blind; then
# A blind run is not an idle run. claudeb writes `out` once, at exit, so a claudeb run whose
# transcript was never located and whose workdir is no repository emits nothing the watchdog can
# read — and killing it for that silence killed a healthy 23-minute run whose worker was editing
# files at the time (live 2026-09-04, exit 143). It now lives to its own end.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=picked STUB_SLEEP=16 WORKER_RUN_IDLE_S=5 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
blind_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: done$' <<<"$blind_wait"
assert_fails grep -q '^KILLED: ' <<<"$blind_wait"
fi

if suite_shard_owns 2 wd-editing; then
# And a run whose EDITS are the only thing moving is working: the transcript is written once and
# never grows, `out` lands at exit, and the files under the workdir are what LAST-EDIT reads — so
# the watchdog reads them too, or a worker mid-edit dies at the idle window.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=picked STUB_SLEEP=14 STUB_TRANSCRIPT_SESSION=frozen-transcript \
  STUB_TRANSCRIPT_ACCOUNT=picked STUB_EDIT_PATH=bin/the-worker-is-mid-edit WORKER_RUN_IDLE_S=3 WORKER_RUN_DEADLINE=600
start_ok claudeb --workdir "$DIRT_REPO"
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
unset STUB_EDIT_PATH
assert test ! -e "$RUN_DIR/files"
# Edits last until the run ends, not a fixed count: under load the stub starts late and outlives
# twelve seconds of edits by more than the idle window.
editing=0
while [ ! -e "$RUN_DIR/exit_code" ] && [ "$editing" -lt 60 ]; do
  editing=$((editing + 1))
  printf 'edit %s\n' "$editing" >"$DIRT_REPO/bin/the-worker-is-mid-edit"
  sleep 1
done
editing_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: done$' <<<"$editing_wait"
assert_fails grep -q '^KILLED: ' <<<"$editing_wait"
rm -f "$DIRT_REPO/bin/the-worker-is-mid-edit"
fi

if suite_shard_owns 4 wd-retry-cotenant; then
# A run's SECOND attempt is a second session. Brief text cannot tell the two apart — the retry
# hands the CLI the same words — so a run that relaunches adopts the transcript its abandoned
# attempt left in the tree, and reports and RESUMEs a session holding none of its work. The token
# each launch carries is what settles it, and the attempt's own launch is the floor: anything
# written before it belongs to an attempt that is over.
clear_stub
set_config 'claudeb_profile=pinned'
retry_tree="$CLAUDEB_PROFILES_ROOT/picked/projects/fixture"
mkdir -p "$retry_tree"
rm -f "$retry_tree"/*.jsonl
: >"$STUB_DIR/claudeb_drop_effort"
export PICK_RC=0 PICK_ACCOUNT=picked STUB_SLEEP=3 STUB_TRANSCRIPT_SESSION=attempt \
  STUB_TRANSCRIPT_ACCOUNT=picked WORKER_RUN_IDLE_S=8 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
retry_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: done$' <<<"$retry_wait"
assert test -f "$retry_tree/attempt.jsonl"
assert test -f "$retry_tree/attempt-2.jsonl"
assert grep -qxF "$(cd "$retry_tree" && pwd -P)/attempt-2.jsonl" "$RUN_DIR/session-file"
assert grep -qx 'attempt-2' "$RUN_DIR/session"
rm -f "$STUB_DIR/claudeb_drop_effort" "$retry_tree"/*.jsonl

# And a co-tenant run of the SAME brief, on the same account, is not this run: every profile writes
# into the one transcript tree, so identity is the token and not the words both briefs carry. This
# run writes no transcript of its own, and the only candidate in the tree is that co-tenant's —
# adopted, it hands the launcher another chat's session to read and to RESUME.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=picked STUB_SLEEP=6 WORKER_RUN_IDLE_S=8 WORKER_RUN_DEADLINE=600
start_ok claudeb
unset STUB_SLEEP WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
# Written after this run's own launch, so it is inside the window and newest-first offers it first.
jq -cn --arg t "$(sed 's/^RUN-TOKEN: .*/RUN-TOKEN: claudeb-1-1-ffff-a1/' "$RUN_DIR/brief.launch")" \
  '{type:"user",message:{role:"user",content:$t}}' >"$retry_tree/a-co-tenant.jsonl"
cotenant_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: done$' <<<"$cotenant_wait"
assert test ! -s "$RUN_DIR/session-file"
assert_fails grep -q 'a-co-tenant' "$RUN_DIR/worker-session"
rm -f "$retry_tree"/*.jsonl
fi

if suite_shard_owns 4 wd-signal; then
# Killing the supervisor kills the run. A TERM that stops the supervisor and leaves the vendor CLI
# writing is a worker nobody watches, a record that never gets an exit code, and edits landing in
# the workdir after the launcher was told the run had ended (live 2026-09-04: run
# claudeb-1788518882-986-6f32, TERMed at 41s, whose worker went on to finish its task).
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=signalled STUB_SLEEP=60 WORKER_RUN_IDLE_S=0 WORKER_RUN_DEADLINE=600
start_ok codex
unset STUB_SLEEP WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
for waiting in $(seq 1 200); do [ -s "$STUB_DIR/codex.child.pid" ] && break; sleep 0.05; done
assert test -s "$STUB_DIR/codex.child.pid"
stub_pid=$(cat "$STUB_DIR/codex.pid")
stub_child=$(cat "$STUB_DIR/codex.child.pid")
# The live CLI's own pid on the record, beside the supervisor's and never equal to it: memlogd's
# memory guard kills the DESCENDANTS of the pid a run registers, so with only .pid there the CLI is
# a descendant and the agent dies with the hog it spawned instead of reporting it.
for waiting in $(seq 1 200); do
  [ -n "$(jq -r '.cli_pid // empty' "$RUN_DIR/meta.json" 2>/dev/null)" ] && break
  sleep 0.05
done
assert test "$(jq -r '.cli_pid // empty' "$RUN_DIR/meta.json")" = "$stub_pid"
assert jq -e '.cli_pid != .pid' "$RUN_DIR/meta.json" >/dev/null
# And the launch instant beside the number, because that is what makes the number checkable: pids
# are reused within the day, and memlogd's guard verifies a registered root by comparing the
# process's own start against this stamp, skipping what it cannot verify rather than killing it.
# Asserted against the CLI's REAL elapsed time — a stamp taken at some other moment fails here.
cli_began=$(jq -r '.cli_pid_started_at // empty' "$RUN_DIR/meta.json")
assert test -n "$cli_began"
cli_start=$(( $(date +%s) - $(ps -p "$stub_pid" -o etime= | awk -F: '{ print $(NF-1) * 60 + $NF }') ))
assert test "$(( cli_start > cli_began ? cli_start - cli_began : cli_began - cli_start ))" -le 5
kill -TERM "$(jq -r '.pid' "$RUN_DIR/meta.json")"
signal_wait=$("$RUNNER" wait "$RUN_ID" --max 30)
assert grep -q '^STATUS: failed$' <<<"$signal_wait"
assert grep -q '^KILLED: signal TERM' <<<"$signal_wait"
assert grep -qx term "$RUN_DIR/killed"
assert jq -e '.terminal_reason == "term"' "$RUN_DIR/meta.json" >/dev/null
assert grep -q '^KILLED: signal TERM' <<<"$("$RUNNER" report "$RUN_ID")"
# A stopped run is no vendor verdict, in the report or the outcome record llm-doctor reads.
assert grep -qx 'OUTCOME: STOPPED' <<<"$signal_wait"
assert grep -qx 'OUTCOME: STOPPED' <<<"$("$RUNNER" report "$RUN_ID")"
assert_fails grep -Eq '_(UNAVAILABLE|FAILED)' <<<"$signal_wait"
assert test "$(cat "$RUN_DIR/outcome")" = STOPPED
assert_fails kill -0 "$stub_pid"
# Not the wrapper alone: the CLI's own children go with its group, or the `sleep` here — a worker
# mid-edit in the real thing — outlives the run that was reported over.
for waiting in $(seq 1 60); do kill -0 "$stub_child" 2>/dev/null || break; sleep 0.1; done
assert_fails kill -0 "$stub_child"
fi

if suite_shard_owns 3 wd-hung; then
# A watchdog tick that never returns is ended with the run, not left behind: killing the watchdog
# alone orphaned its in-flight command substitutions, and one blocked forever (a here-string past a
# full pipe) kept a chain of `_supervise` subshells alive 31 h after exit_code (live 2026-10-04,
# claudeb-1791078365-20910-7f9b). The stub jq blocks once, on the watchdog's own transcript read.
clear_stub
set_config 'claudeb_profile=pinned'
real_jq=$(command -v jq)
mkdir -p "$WORK/hang-bin"
cat >"$WORK/hang-bin/jq" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *'is_error? == true'*)
    if mv "\$STUB_DIR/jq_hang" "\$STUB_DIR/jq_hung" 2>/dev/null; then
      printf '%s\n' "\$\$" >"\$STUB_DIR/jq_hung"
      exec sleep 600
    fi
    ;;
esac
exec "$real_jq" "\$@"
EOF
chmod +x "$WORK/hang-bin/jq"
: >"$STUB_DIR/jq_hang"
export PICK_RC=0 PICK_ACCOUNT=hung STUB_SLEEP=6 STUB_TRANSCRIPT_SESSION=hung-session \
  STUB_TRANSCRIPT_ACCOUNT=hung WORKER_RUN_IDLE_S=20 WORKER_RUN_DEADLINE=600
PATH="$WORK/hang-bin:$PATH" start_ok claudeb
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
assert grep -q '^STATUS: done$' <<<"$("$RUNNER" wait "$RUN_ID" --max 60)"
assert test -s "$STUB_DIR/jq_hung"
for waiting in $(seq 1 100); do
  leftover=$(ps -A -o pid=,command= | awk -v dir="$RUN_DIR" -v hung="$(cat "$STUB_DIR/jq_hung")" \
    '$1 == hung || index($0, "_supervise " dir) { print $1 }')
  [ -n "$leftover" ] || break
  sleep 0.1
done
[ -z "$leftover" ] || kill $leftover 2>/dev/null
assert test -z "$leftover"
fi
}

dirt_repo_init
watchdog_tests

echo "PASS: $asserts asserts; the watchdog: deadlines, idle and silent kills, signals"
