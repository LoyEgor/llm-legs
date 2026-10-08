#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh"
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
assert await_done
assert test -f "$RUN_DIR/dirty-before"
assert test -f "$RUN_DIR/dirty-before-shas"
assert test "$(cd "$(jq -r '.workdir' "$RUN_DIR/meta.json")" && pwd -P)" = "$(cd "$readonly_workdir" && pwd -P)"
assert test "$(jq 'has("served_model")' "$RUN_DIR/meta.json")" = false
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'MODEL: opus·high' <<<"$report"
assert_fails grep -q '^SERVED:' <<<"$report"
assert grep -qx 'HINT: this run edited nothing — a read-only lookup is cheaper as a light research run (`light-research`, see ~/.claude/CLAUDE.md, Model routing); read-only worker runs this month: 1' <<<"$report"
assert test -f "$RUN_DIR/report-readonly"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=readonly-two STUB_TRANSCRIPT_SESSION=readonly-two STUB_SESSION=readonly-two
export STUB_TRANSCRIPT_ACCOUNT=readonly-two
start_ok claudeb
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'HINT: this run edited nothing — a read-only lookup is cheaper as a light research run (`light-research`, see ~/.claude/CLAUDE.md, Model routing); read-only worker runs this month: 2' <<<"$report"
assert test -f "$RUN_DIR/report-readonly"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=readonly-changed STUB_TRANSCRIPT_SESSION=readonly-changed STUB_SESSION=readonly-changed
export STUB_TRANSCRIPT_ACCOUNT=readonly-changed
start_ok claudeb
assert await_done
printf 'changed\n' >"$readonly_workdir/changed.txt"
report=$("$RUNNER" report "$RUN_ID")
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0
assert test ! -e "$RUN_DIR/report-readonly"
rm -f "$readonly_workdir/changed.txt"
assert test -z "$(git -C "$readonly_workdir" status --porcelain -uall)"

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
assert await_done
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
assert await_done
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
assert await_done
assert jq -e '.role == "research"' "$RUN_DIR/meta.json" >/dev/null
report=$("$RUNNER" report "$RUN_ID")
assert test "$(grep -c '^HINT:' <<<"$report")" -eq 0
assert test ! -e "$RUN_DIR/report-readonly"

export WORKER_RUN_DIR="$WORK/runs"
unset WORKER_TEST_WORKDIR
printf 'test brief\nsecond line\n' >"$WORK/brief"

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
  assert await_done
  assert test "$(grep -c '^ARG=auth-needed$' "$CALL_LOG")" -eq "$calls"
  [ "$calls" = 0 ] || assert test "$(grep -A1 '^ARG=auth-needed$' "$CALL_LOG" | tail -n1)" = ARG=authdead
done

clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=trusted
: >"$STUB_DIR/codex_trusted"
start_ok codex
assert await_done
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

# A refusal is never recorded (gpt-6.1-sol's on 2026-09-30 was rollout lag): the next launch on
# that account asks for the same slug again.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=badmodel
: >"$STUB_DIR/codex_bad_model"
start_ok codex --model sol
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test ! -e "$HOME/.codex-profiles/.codexb/refused-models"
: >"$CALL_LOG"
rm -f "$STUB_DIR/codex_bad_model"
start_ok codex --model sol
assert await_done
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert grep -qx 'ARG=gpt-5.6-sol' "$CALL_LOG"

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

# A worker editing this very script mid-run must not corrupt it: bash re-reads
# the file after the last top-level command and a grown file parses as garbage.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=selfedit
SELF_RUNNER="$WORK/bin/worker-run-selfedit"
cp "$RUNNER" "$SELF_RUNNER"
# worker-run sources its share files relative to its own resolved root, so a copy needs the share
# tree beside it — the pool wall must never be a file the runner can quietly do without, the agy
# HOME mapping is not a formula worker-run may fall back to spelling itself, and the allowed-model
# list is not one it may guess at either.
mkdir -p "$WORK/share"
cp "$ROOT/share/worker-pool.sh" "$ROOT/share/gemini-accounts.sh" "$ROOT/share/codex-accounts.sh" \
  "$ROOT/share/worker-model.sh" "$ROOT/share/limits-view.sh" "$ROOT/share/worker-walls.sh" \
  "$ROOT/share/web-search.sh" "$ROOT/share/run-liveness.sh" "$ROOT/share/store-lock.sh" \
  "$ROOT/share/slots.sh" "$ROOT/share/limiter-hold.sh" "$ROOT/share/worktree-branch.sh" "$ROOT/share/worker-claims.sh" "$ROOT/share/processes.sh" \
  "$ROOT/share/worker-inbox.sh" "$WORK/share/"
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
export PICK_RC=0 PICK_ACCOUNT=selfedit STUB_SLEEP=3
start_ok codex
unset STUB_SLEEP
(sleep 0.5; printf 'garbage )(\n' >>"$SELF_RUNNER") &
appender=$!
rc=0
"$SELF_RUNNER" wait "$RUN_ID" --max 1 >"$WORK/selfedit-wait.out" 2>"$WORK/selfedit-wait.err" || rc=$?
wait "$appender"
assert test "$rc" -eq 0
assert test "$(grep -ci 'syntax error' "$WORK/selfedit-wait.err")" -eq 0
assert grep -q '^STATUS: running$' "$WORK/selfedit-wait.out"
assert await_done

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
assert await_done

# Codex walls with a bare clock time and a trailing dot; read as now+1h, worker-pick freed the
# account hours before its real reset.
. "$ROOT/share/worker-walls.sh"
now=$(date +%s)
reset_2341=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%F) 23:41:00" +%s)
[ "$reset_2341" -gt "$now" ] || reset_2341=$(date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$(date +%F) 23:41:00" +%s)
for text in 'try again at 11:41 PM.' '11:41PM' '23:41'; do
  assert test "$(WORKER_WALLS_NOW=$now worker_walls_parse_reset "$text")" = "$reset_2341"
done
passed=$(( (now - 3600) / 60 * 60 ))
rolled=$(worker_walls_parse_reset "$(date -r "$passed" +%H:%M)")
assert test "$rolled" -gt "$now"
assert test "$(( rolled - passed ))" -ge 82800
assert test "$(( rolled - passed ))" -le 90000
this_minute=$(worker_walls_parse_reset "try again at $(date -r "$(( now / 60 * 60 ))" '+%I:%M %p')")
assert test "$this_minute" -le "$now"
assert test "$(worker_walls_kind codex "$this_minute")" = unknown

# Real wall wordings read as their reset, never now+1h: claude's zone suffix, comma and bare hour,
# codex's dated retry behind a transcript's `git reset --hard`, gemini's compound duration, ISO UTC.
wall_reset() { printf '%b\n' "$1" >"$WORK/wall.out"; worker_walls_parse_reset "$(worker_walls_extract_reset "$WORK/wall.out")"; }
at() { date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
tomorrow=$(date -j -v+1d +%Y-%m-%d)
kiev_2240=$(TZ=Europe/Kiev date -j -f '%Y-%m-%d %H:%M:%S' "$(TZ=Europe/Kiev date +%F) 22:40:00" +%s)
[ "$kiev_2240" -gt "$((now - 300))" ] || kiev_2240=$((kiev_2240 + 86400))
assert test "$(wall_reset '{"result":"You'\''ve hit your session limit · resets 10:40pm (Europe/Kiev)","is_error":true}')" = "$kiev_2240"
assert test "$(wall_reset "You've hit your weekly limit · resets $(date -j -v+1d '+%b %e' | tr -s ' '), 9am")" = "$(at "$tomorrow 09:00:00")"
assert test "$(wall_reset "\"result\":\"You've hit your weekly limit · resets $(date -j -v+1d '+%b %e' | tr -s ' ') at 10pm (Europe/Kiev)\"")" = \
  "$(TZ=Europe/Kiev date -j -f '%Y-%m-%d %H:%M:%S' "$(TZ=Europe/Kiev date -j -v+1d +%F) 22:00:00" +%s)"
three_pm=$(at "$(date +%F) 15:00:00")
[ "$three_pm" -gt "$((now - 300))" ] || three_pm=$(at "$tomorrow 15:00:00")
assert test "$(wall_reset 'resets 3pm')" = "$three_pm"
assert test "$(wall_reset "run \`git reset --hard\` first\nor try again at $(date -j -v+2d '+%b %eth, %Y 3:52 AM' | tr -s ' ').")" = \
  "$(at "$(date -j -v+2d +%F) 03:52:00")"
gemini=$(wall_reset 'Individual quota reached. Resets in 1h40m8s.')
assert test "$(( gemini - now ))" -ge 6008
assert test "$(( gemini - now ))" -le 6068
iso=$(date -u -j -v+1d +%Y-%m-%dT15:00:00)
assert test "$(wall_reset "resets ${iso}Z")" = "$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$iso" +%s)"
assert test -z "$(printf 'Connection reset by peer\npreset: 5\nretry at most once\n' >"$WORK/wall.out"; worker_walls_extract_reset "$WORK/wall.out")"
dec31=$(at "$(date +%Y)-12-31 10:00:00")
assert test "$(WORKER_WALLS_NOW=$dec31 worker_walls_parse_reset 'resets Jan 2 3:00 PM')" = "$(date -j -v+1y -f '%Y-%m-%d %H:%M:%S' "$(date +%Y)-01-02 15:00:00" +%s)"

echo "PASS: $asserts asserts; read-only runs, outcome classification, codex trust and model retries, self-edit, pruning"
