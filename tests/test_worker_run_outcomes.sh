#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# shards: 3
# Runs on an edit of the worker-run modules it exercises (tests/affected): share/worker-run-files.sh
# share/worker-run-snapshot.sh share/worker-run-vendors.sh share/worker-run-wait.sh
. "$(dirname "$0")/worker_run_harness.sh" || exit 1
if suite_shard_owns 1 outcomes-readonly; then
light_workdir="$WORK/light-workdir"
mkdir -p "$light_workdir"
git -C "$light_workdir" init -q
printf 'base\n' >"$light_workdir/file"
git -C "$light_workdir" add file
git -C "$light_workdir" -c user.name=fixture -c user.email=fixture@example.test commit -qm base

readonly_runs="$WORK/readonly-runs"
readonly_workdir="$WORK/readonly-workdir"
mkdir -p "$readonly_runs" "$readonly_workdir"
git -C "$readonly_workdir" init -q
readonly_workdir=$(cd "$readonly_workdir" && pwd -P)
export WORKER_RUN_DIR="$readonly_runs" WORKER_TEST_WORKDIR="$readonly_workdir"
printf 'test brief\nsecond line\n' >"$WORK/brief"

clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=readonly-one STUB_TRANSCRIPT_SESSION=readonly-one STUB_SESSION=readonly-one
export STUB_TRANSCRIPT_ACCOUNT=readonly-one
start_ok claudeb
assert await_exit
assert test -f "$RUN_DIR/dirty-before"
assert test -f "$RUN_DIR/dirty-before-shas"
assert test "$(cd "$(jq -r '.workdir' "$RUN_DIR/meta.json")" && pwd -P)" = "$(cd "$readonly_workdir" && pwd -P)"
assert test "$(jq 'has("served_model")' "$RUN_DIR/meta.json")" = false
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'MODEL: opus·high' <<<"$report"
assert_fails grep -q '^SERVED:' <<<"$report"
assert grep -qx 'HINT: .*; read-only worker runs this month: 1' <<<"$report"
assert jq -se --arg run "$RUN_ID" 'map(select(.run == $run)) | .[0].user_md_loaded == false' "$CLAUDEB_DIR/worker-stats/runs.jsonl" >/dev/null
assert test -f "$RUN_DIR/report-readonly"
assert_fails grep -q '^ESCALATE' <<<"$report"
# A cheap-model run hands itself back: its ESCALATE line is surfaced with the brief, ready for the default model.
printf 'MODEL: sonnet\nEFFORT: medium\nROUND: none\nland it\nMODEL: prose stays\n' >"$RUN_DIR/brief"
printf 'found a logic conflict\nESCALATE: rebase conflict in logic\n' >"$RUN_DIR/result"
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'ESCALATE: rebase conflict in logic' <<<"$report"
assert grep -qx "ESCALATE-BRIEF: $WORKER_RUN_DIR/$RUN_ID/escalate.brief.md" <<<"$report"
assert test "$(head -n 3 "$RUN_DIR/escalate.brief.md")" = $'ROUND: none\nland it\nMODEL: prose stays'
assert grep -qF "escalated: rebase conflict in logic. Its report: \`$RUNNER report $RUN_ID\`" "$RUN_DIR/escalate.brief.md"
assert grep -qx 'ESCALATE: rebase conflict in logic' < <("$RUNNER" wait "$RUN_ID")
rm -f "$RUN_DIR/result"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=readonly-two STUB_TRANSCRIPT_SESSION=readonly-two STUB_SESSION=readonly-two
export STUB_TRANSCRIPT_ACCOUNT=readonly-two STUB_TRANSCRIPT_USER_MD=/home/.claude/CLAUDE.md
start_ok claudeb
assert await_exit
# The chat's CLAUDE.md reaching a worker despite claudeMdExcludes is journaled for Spend.
assert jq -se --arg run "$RUN_ID" 'map(select(.run == $run)) | .[0].user_md_loaded == true' "$CLAUDEB_DIR/worker-stats/runs.jsonl" >/dev/null
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'HINT: .*; read-only worker runs this month: 2' <<<"$report"
assert test -f "$RUN_DIR/report-readonly"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=readonly-changed STUB_TRANSCRIPT_SESSION=readonly-changed STUB_SESSION=readonly-changed
export STUB_TRANSCRIPT_ACCOUNT=readonly-changed
start_ok claudeb
assert await_exit
printf 'changed\n' >"$readonly_workdir/changed.txt"
report=$("$RUNNER" report "$RUN_ID")
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0
assert test ! -e "$RUN_DIR/report-readonly"
rm -f "$readonly_workdir/changed.txt"
assert test -z "$(git -C "$readonly_workdir" status --porcelain -uall)"

# An edit git cannot see — the path is ignored — is still an edit: the transcript's Edit call wins.
clear_stub
printf 'ignored/\n' >>"$readonly_workdir/.git/info/exclude"
mkdir -p "$readonly_workdir/ignored"
printf 'edited\n' >"$readonly_workdir/ignored/lane.py"
export PICK_RC=0 PICK_ACCOUNT=readonly-ignored STUB_TRANSCRIPT_SESSION=readonly-ignored STUB_SESSION=readonly-ignored
export STUB_TRANSCRIPT_ACCOUNT=readonly-ignored STUB_EDIT_PATH="$readonly_workdir/ignored/lane.py"
start_ok claudeb
assert await_exit
report=$("$RUNNER" report "$RUN_ID")
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0
assert test ! -e "$RUN_DIR/report-readonly"
assert grep -qx "RUN-FILES: unknown (the run's own calls name 1 path(s) git shows no change for here: ignored/lane.py)" <<<"$report"
rm -rf "$readonly_workdir/ignored"

# A shell program that may have written somewhere git cannot see leaves the listing a floor, never a 0.
clear_stub
mkdir -p "$CLAUDEB_PROFILES_ROOT/readonly-shell/projects/fixture"
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'python3 tools/bench.py' >"$CLAUDEB_PROFILES_ROOT/readonly-shell/projects/fixture/readonly-shell.jsonl"
export PICK_RC=0 PICK_ACCOUNT=readonly-shell STUB_SESSION=readonly-shell
start_ok claudeb
assert await_exit
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: unknown (the run also ran shell commands, whose edits no transcript records)' <<<"$report"
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0

# Neither a failed run nor one whose transcript cannot be read is a read-only lookup.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=readonly-failed STUB_TRANSCRIPT_SESSION=readonly-failed STUB_SESSION=readonly-failed
export STUB_TRANSCRIPT_ACCOUNT=readonly-failed STUB_CODE=1
export STUB_STDOUT='{"type":"result","is_error":true,"result":"API Error: 500","session_id":"readonly-failed"}'
start_ok claudeb
assert await_exit
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'STATUS: failed' <<<"$report"
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0
assert test ! -e "$RUN_DIR/report-readonly"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=readonly-blind STUB_SESSION=readonly-blind
start_ok claudeb
assert await_exit
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'STATUS: done' <<<"$report"
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0
assert test ! -e "$RUN_DIR/report-readonly"

declared_workdir="$WORK/declared-readonly-workdir"
mkdir -p "$declared_workdir"
git -C "$declared_workdir" init -q
declared_workdir=$(cd "$declared_workdir" && pwd -P)
export WORKER_TEST_WORKDIR="$declared_workdir"
printf 'READ-ONLY: deliberate relay lookup\n' >"$WORK/brief"
clear_stub
export PICK_RC=0 PICK_ACCOUNT=readonly-declared STUB_TRANSCRIPT_SESSION=readonly-declared STUB_SESSION=readonly-declared
export STUB_TRANSCRIPT_ACCOUNT=readonly-declared
start_ok claudeb
assert await_exit
assert test -f "$RUN_DIR/dirty-before"
assert test -f "$RUN_DIR/dirty-before-shas"
assert test "$(cd "$(jq -r '.workdir' "$RUN_DIR/meta.json")" && pwd -P)" = "$(cd "$declared_workdir" && pwd -P)"
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 0' <<<"$report"
assert test -z "$(git -C "$declared_workdir" status --porcelain -uall)"
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0
assert test ! -e "$RUN_DIR/report-readonly"

# A Light run and a research run ARE the cheap read-only leg the hint points at, so neither is
# told to reroute itself — whatever their brief's first line says.
export WORKER_TEST_WORKDIR="$readonly_workdir"
printf 'test brief\nsecond line\n' >"$WORK/brief"
clear_stub
set_config 'light_edit=claudeb:sonnet'
export PICK_RC=0 PICK_ACCOUNT=readonly-light STUB_TRANSCRIPT_SESSION=readonly-light STUB_SESSION=readonly-light
export STUB_TRANSCRIPT_ACCOUNT=readonly-light
WORKER_TEST_WORKDIR="$light_workdir" start_ok light
assert await_exit
assert jq -e '.light == "edit"' "$RUN_DIR/meta.json" >/dev/null
report=$("$RUNNER" report "$RUN_ID")
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0
assert test ! -e "$RUN_DIR/report-readonly"

clear_stub
# On the row's own vendor: off it, a research launch with no --model is refused rather than served
# the vendor's strong default under the light class.
set_config 'claudeb_model=opus' 'claudeb_effort=high' 'light_research=claudeb:sonnet'
export PICK_RC=0 PICK_ACCOUNT=readonly-research STUB_TRANSCRIPT_SESSION=readonly-research STUB_SESSION=readonly-research
export STUB_TRANSCRIPT_ACCOUNT=readonly-research
start_ok claudeb --role research
assert await_exit
assert jq -e '.role == "research"' "$RUN_DIR/meta.json" >/dev/null
report=$("$RUNNER" report "$RUN_ID")
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0
assert test ! -e "$RUN_DIR/report-readonly"
fi

export WORKER_RUN_DIR="$WORK/runs"
unset WORKER_TEST_WORKDIR
printf 'test brief\nsecond line\n' >"$WORK/brief"

if suite_shard_owns 2 outcomes-classification; then
# A clean exit whose text merely mentions quotas is not a limit: no OUTCOME line.
clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=high'
export PICK_RC=0 PICK_ACCOUNT=chatty STUB_CODE=0 STUB_ERROR='discussed quota and 429 handling'
printf 'chatty\n' >"$STUB_DIR/gemini_profiles"
start_ok gemini
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME:' "$WORK/wait.out")" -eq 0

# A failed run whose ANSWER (stdout) mentions quotas is a plain failure, not a
# limit: only stderr carries vendor limit signatures.
clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=high'
export PICK_RC=0 PICK_ACCOUNT=chatty STUB_CODE=5 STUB_STDOUT='the task discussed quota and 429 handling'
printf 'chatty\n' >"$STUB_DIR/gemini_profiles"
start_ok gemini
assert await_done
assert grep -qx 'OUTCOME: GEMINI_UNAVAILABLE' "$WORK/wait.out"

for spec in 'claudeb:CLAUDEB_FAILED' 'codex:CODEX_UNAVAILABLE' 'gemini:GEMINI_UNAVAILABLE'; do
  IFS=: read -r vendor outcome <<<"$spec"
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' 'gemini_model=flash38' 'gemini_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=failedacct STUB_CODE=7 STUB_ERROR='ordinary failure'
  printf 'failedacct\n' >"$STUB_DIR/gemini_profiles"
  start_ok "$vendor"
  assert await_done
  assert grep -qx "OUTCOME: $outcome" "$WORK/wait.out"
  assert grep -q '^ERR-TAIL:$' "$WORK/wait.out"
  assert grep -q 'ordinary failure' "$WORK/wait.out"
done

# A claudeb run its CLI ended on a failed login refresh records the account login needed through claudeb;
# the same words in a result that is no error record nothing.
for spec in 'true:1' 'false:0'; do
  IFS=: read -r is_error calls <<<"$spec"
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=authdead STUB_CODE=1 STUB_ERROR='' STUB_STDOUT="{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":$is_error,\"result\":\"Failed to authenticate: OAuth session expired and could not be refreshed\"}"
  start_ok claudeb
  assert await_exit
  assert test "$(grep -c '^ARG=auth-needed$' "$CALL_LOG")" -eq "$calls"
  [ "$calls" = 0 ] || assert test "$(grep -A1 '^ARG=auth-needed$' "$CALL_LOG" | tail -n1)" = ARG=authdead
done
fi

if suite_shard_owns 3 outcomes-codex-retries; then
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=trusted
: >"$STUB_DIR/codex_trusted"
start_ok codex
assert await_exit
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert grep -q '^ARG=--skip-git-repo-check$' "$CALL_LOG"
assert jq -e '.trusted_dir_retry == true' "$RUN_DIR/meta.json" >/dev/null

# Trusted-dir retry keeps a resume command intact: the flag is appended, never
# spliced between `exec resume` and its id.
clear_stub
set_config 'codex_effort=high'
: >"$STUB_DIR/codex_trusted"
start_ok codex --account trusted --resume codex-resume
assert await_done
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert grep -q '^ARG=--skip-git-repo-check$' "$CALL_LOG"
assert grep -q '^ARG=resume$' "$CALL_LOG"
assert test "$(grep -A1 -x 'ARG=resume' "$CALL_LOG" | grep -cx 'ARG=codex-resume')" -eq 2
assert grep -q '^STATUS: done$' "$WORK/wait.out"

# A clean exit whose stderr mentions the trusted-directory phrase is not rerun.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=trusted STUB_ERROR='Not inside a trusted directory'
start_ok codex
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert jq -e 'has("trusted_dir_retry") | not' "$RUN_DIR/meta.json" >/dev/null

# A brief's model override the account cannot use is dropped once and rerun:
# worker-pick's own default always resolves, so the run survives.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=badmodel
: >"$STUB_DIR/codex_bad_model"
start_ok codex --model sol
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 1
assert test "$(grep -c '^ARG=gpt-5.6-sol$' "$CALL_LOG")" -eq 1
assert grep -qxF 'ARG=model=\"gpt-6.1-astra\"' "$CALL_LOG"
assert jq -e '.model_flag_dropped == true' "$RUN_DIR/meta.json" >/dev/null
assert_launched_brief "$STUB_DIR/codex.stdin"
# A refusal is never recorded (gpt-6.1-sol's on 2026-09-30 was rollout lag): the next launch on
# that account asks for the same slug again.
: >"$CALL_LOG"
rm -f "$STUB_DIR/codex_bad_model"
start_ok codex --model sol
assert await_exit
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert grep -qx 'ARG=gpt-5.6-sol' "$CALL_LOG"

# The default resolving to the refused slug itself: the server would refuse it again.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=badmodel
: >"$STUB_DIR/codex_bad_model"
start_ok codex --model astra
assert await_done
assert grep -q '^STATUS: failed$' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert jq -e 'has("model_flag_dropped") | not' "$RUN_DIR/meta.json" >/dev/null

# A clean exit whose stderr mentions the phrase is not rerun.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=badmodel STUB_ERROR='note: that model is not supported everywhere'
start_ok codex --model astra
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert jq -e 'has("model_flag_dropped") | not' "$RUN_DIR/meta.json" >/dev/null

# A rejected model is a 400, never a wall: the failure must not be relabelled a
# usage limit just because the echoed brief spells CODEX_USAGE_LIMIT out.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=badmodel
: >"$STUB_DIR/codex_bad_model_always"
start_ok codex --model sol
assert await_done
assert grep -q '^STATUS: failed$' "$WORK/wait.out"
assert grep -qx 'OUTCOME: CODEX_UNAVAILABLE' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME: CODEX_USAGE_LIMIT$' "$WORK/wait.out")" -eq 0
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2

# An unsupported-model failure with no -m to drop is not retried verbatim.
clear_stub
set_config 'codex_effort=high'
: >"$STUB_DIR/codex_bad_model_always"
start_ok codex --account resumeacct --resume codex-resume
assert await_done
assert grep -q '^STATUS: failed$' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert jq -e 'has("model_flag_dropped") | not' "$RUN_DIR/meta.json" >/dev/null

# The unsupported-model phrase buried deep in the streamed transcript neither
# suppresses a genuine limit fatal at the tail nor triggers a retry.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=badmodel
: >"$STUB_DIR/codex_phrase_deep"
start_ok codex --model astra
assert await_done
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert jq -e 'has("model_flag_dropped") | not' "$RUN_DIR/meta.json" >/dev/null

# codex streams the brief and every file the worker reads onto stderr: bare
# "quota"/"usage_limit"/"rate-limit" tokens there are prose, not a wall.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=noisyacct STUB_CODE=7 STUB_ERROR='ordinary failure'
: >"$STUB_DIR/codex_noise"
start_ok codex
assert await_done
assert grep -qx 'OUTCOME: CODEX_UNAVAILABLE' "$WORK/wait.out"

# Even a verbatim limit phrase counts only where the CLI's fatal error is — deep
# in the transcript it is a file the worker read.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=noisyacct STUB_CODE=7 STUB_ERROR='ordinary failure'
: >"$STUB_DIR/codex_noise_deep"
start_ok codex
assert await_done
assert grep -qx 'OUTCOME: CODEX_UNAVAILABLE' "$WORK/wait.out"
fi

if suite_shard_owns 2 outcomes-self-edit-prune; then
# A worker editing this very script mid-run must not corrupt it: bash re-reads
# the file after the last top-level command and a grown file parses as garbage.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=selfedit
SELF_RUNNER="$WORK/bin/worker-run-selfedit"
cp "$RUNNER" "$SELF_RUNNER"
# worker-run sources its share files relative to its own resolved root, so a copy needs the share
# tree beside it.
cp -R "$ROOT/share" "$WORK/"
[ -e "$WORK/bin/codexb" ] || ln -s "$ROOT/bin/codexb" "$WORK/bin/codexb"
[ -e "$WORK/bin/cyrillic-share" ] || ln -s "$ROOT/bin/cyrillic-share" "$WORK/bin/cyrillic-share"
printf '%s\n' "$SELF_RUNNER" >"$STUB_DIR/codex_append_target"
"$SELF_RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" >"$WORK/start.out" 2>"$WORK/start.err" || fail "self-edit start failed: $(<"$WORK/start.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/start.out")
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert grep -q '^EXIT: 0$' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME:' "$WORK/wait.out")" -eq 0

# Same hazard on the caller's side: a `wait` polling across the edit must report,
# not die on a syntax error in its own script.
clear_stub
set_config 'codex_effort=high'
cp "$RUNNER" "$SELF_RUNNER"
export PICK_RC=0 PICK_ACCOUNT=selfedit
start_gated codex
(sleep 0.5; printf 'garbage )(\n' >>"$SELF_RUNNER") &
appender=$!
rc=0
"$SELF_RUNNER" wait "$RUN_ID" --max 1 >"$WORK/selfedit-wait.out" 2>"$WORK/selfedit-wait.err" || rc=$?
wait "$appender"
assert test "$rc" -eq 0
assert test "$(grep -ci 'syntax error' "$WORK/selfedit-wait.err")" -eq 0
assert grep -q '^STATUS: running$' "$WORK/selfedit-wait.out"
gate_open
assert await_exit

# Run dirs older than 7 days are pruned on start; fresh dirs survive.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=pruner
mkdir -p "$WORKER_RUN_DIR/codex-1-1-dead"
touch -t 202601010000 "$WORKER_RUN_DIR/codex-1-1-dead"
touch -t 202601010000 "$WORKER_RUN_DIR/.prune"
start_ok codex
assert test ! -d "$WORKER_RUN_DIR/codex-1-1-dead"
assert test -d "$RUN_DIR"
assert await_exit
fi


echo "PASS: $asserts asserts; read-only runs, outcome classification, codex trust and model retries, self-edit, pruning"
