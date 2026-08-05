#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/bin/worker-run"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

export HOME="$WORK/home"
export WORKER_RUN_DIR="$WORK/runs"
export WORKER_RUN_CONFIG_FILE="$WORK/worker-model"
export WORKER_RUN_CODEX_CONFIG="$WORK/config.toml"
export WORKER_RUN_WORKER_PICK="$WORK/bin/worker-pick"
export WORKER_RUN_CLAUDEB="$WORK/bin/claudeb"
export WORKER_RUN_CODEX="$WORK/bin/codex"
export WORKER_RUN_GEMINIB="$WORK/bin/geminib"
export STUB_DIR="$WORK/stub-state"
export CALL_LOG="$WORK/calls"
export PICK_LOG="$WORK/picks"
mkdir -p "$HOME" "$WORK/bin" "$WORKER_RUN_DIR" "$STUB_DIR" "$WORK/workdir" "$WORK/extra"
printf 'model = "gpt-5.6-sol"\n' >"$WORKER_RUN_CODEX_CONFIG"
printf 'test brief\nsecond line\n' >"$WORK/brief"
printf 'image\n' >"$WORK/image.png"

cat >"$WORK/bin/worker-pick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PICK_LOG"
case "${PICK_RC:-0}" in
  0) printf '%s\n' "${PICK_ACCOUNT:-picked}" ;;
  *) exit "${PICK_RC}" ;;
esac
EOF

cat >"$WORK/bin/claudeb" <<'EOF'
#!/usr/bin/env bash
{
  printf 'CLAUDEB_CALL\n'
  printf 'ARG=%q\n' "$@"
} >>"$CALL_LOG"
has_effort=false
for arg in "$@"; do [ "$arg" != --effort ] || has_effort=true; done
if [ -e "$STUB_DIR/claudeb_drop_effort" ] && [ "$has_effort" = true ]; then
  printf 'unknown option --effort\n' >&2
  exit 2
fi
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
[ -z "${STUB_ERROR:-}" ] || printf '%s\n' "$STUB_ERROR" >&2
if [ "${STUB_CODE:-0}" -eq 0 ]; then
  printf '{"result":"claudeb result","session_id":"claude-session","total_cost_usd":1.25}\n'
fi
exit "${STUB_CODE:-0}"
EOF

cat >"$WORK/bin/codex" <<'EOF'
#!/usr/bin/env bash
{
  printf 'CODEX_CALL\n'
  printf 'CODEX_HOME=%q\n' "${CODEX_HOME-__unset__}"
  printf 'ARG=%q\n' "$@"
} >>"$CALL_LOG"
out=''
skip=false
previous=''
for arg in "$@"; do
  [ "$previous" != -o ] || out="$arg"
  [ "$arg" != --skip-git-repo-check ] || skip=true
  previous="$arg"
done
cat >"$STUB_DIR/codex.stdin"
if [ -e "$STUB_DIR/codex_trusted" ] && [ "$skip" = false ]; then
  printf 'Not inside a trusted directory\n' >&2
  exit 1
fi
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
[ -z "${STUB_ERROR:-}" ] || printf '%s\n' "$STUB_ERROR" >&2
if [ "${STUB_CODE:-0}" -eq 0 ]; then
  printf 'session id: codex-session\n' >&2
  printf 'codex result\n' >"$out"
fi
exit "${STUB_CODE:-0}"
EOF

cat >"$WORK/bin/geminib" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  printf 'main: Logged in\n'
  [ ! -r "$STUB_DIR/gemini_profiles" ] || while IFS= read -r name; do printf '%s: Logged in\n' "$name"; done <"$STUB_DIR/gemini_profiles"
  exit 0
fi
{
  printf 'GEMINI_CALL\n'
  printf 'ARG=%q\n' "$@"
} >>"$CALL_LOG"
log=''
previous=''
for arg in "$@"; do
  [ "$previous" != --log-file ] || log="$arg"
  previous="$arg"
done
printf 'server.go:1017] Created conversation gemini-conversation\n' >"$log"
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
[ -z "${STUB_ERROR:-}" ] || printf '%s\n' "$STUB_ERROR" >&2
[ -z "${STUB_STDOUT:-}" ] || printf '%s\n' "$STUB_STDOUT"
[ "${STUB_CODE:-0}" -ne 0 ] || printf 'gemini result\n'
exit "${STUB_CODE:-0}"
EOF

chmod +x "$WORK/bin"/*

set_config() {
  printf '%s\n' "$@" >"$WORKER_RUN_CONFIG_FILE"
}

clear_stub() {
  : >"$CALL_LOG"
  : >"$PICK_LOG"
  unset STUB_SLEEP STUB_ERROR STUB_CODE STUB_STDOUT
  rm -f "$STUB_DIR/claudeb_drop_effort" "$STUB_DIR/codex_trusted"
}

start_ok() {
  local vendor="$1"
  shift
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --workdir "$WORK/workdir" "$@" >"$WORK/start.out" 2>"$WORK/start.err" || fail "start $vendor failed: $(<"$WORK/start.err")"
  RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
  RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/start.out")
}

await_done() {
  local output index
  for index in $(seq 1 100); do
    output=$("$RUNNER" wait "$RUN_ID" --max 0)
    if grep -q '^STATUS: done\|^STATUS: failed' <<<"$output"; then
      printf '%s\n' "$output" >"$WORK/wait.out"
      return 0
    fi
    sleep 0.05
  done
  return 1
}

meta_account_is() { [ "$(jq -r '.account' "$RUN_DIR/meta.json")" = "$1" ]; }
meta_agy_is() { [ "$(jq -r '.agy_model' "$RUN_DIR/meta.json")" = "$1" ]; }

clear_stub
set_config 'codex_effort=high'
export PICK_ACCOUNT=fast PICK_RC=0 STUB_SLEEP=2
SECONDS=0
start_ok codex
assert test "$SECONDS" -lt 2
assert test "$(wc -l <"$WORK/start.out" | tr -d ' ')" -eq 3
assert grep -Eq '^RUN: codex-[0-9]+-[0-9]+-[0-9a-f]{4}$' "$WORK/start.out"
assert grep -qx 'TAG: fast · sol · high' "$WORK/start.out"
assert grep -qx "DIR: $RUN_DIR" "$WORK/start.out"
pid=$(jq -r '.pid' "$RUN_DIR/meta.json")
assert kill -0 "$pid"
first_wait=$("$RUNNER" wait "$RUN_ID" --max 1)
assert grep -q '^STATUS: running$' <<<"$first_wait"
assert grep -q '^SESSION: -$' <<<"$first_wait"
assert kill -0 "$pid"
assert test ! -e "$RUN_DIR/exit_code"
second_wait=$("$RUNNER" wait "$RUN_ID" --max 6)
assert grep -q '^STATUS: done$' <<<"$second_wait"
assert grep -q '^SESSION: codex-session$' <<<"$second_wait"
assert grep -q '^RESULT-TAIL:$' <<<"$second_wait"
unset STUB_SLEEP

# A running run whose vendor has already surfaced its id reports it mid-flight,
# so a budget-spent relay can still hand back a resumable session.
clear_stub
set_config 'gemini_model=pro' 'gemini_effort=high'
printf 'fast\n' >"$STUB_DIR/gemini_profiles"
export PICK_ACCOUNT=fast PICK_RC=0 STUB_SLEEP=2
start_ok gemini
running_wait=$("$RUNNER" wait "$RUN_ID" --max 1)
assert grep -q '^STATUS: running$' <<<"$running_wait"
assert grep -q '^SESSION: gemini-conversation$' <<<"$running_wait"
running_report=$("$RUNNER" report "$RUN_ID")
assert grep -q '^STATUS: running$' <<<"$running_report"
assert grep -q '^SESSION: gemini-conversation$' <<<"$running_report"
assert await_done
unset STUB_SLEEP

for vendor in claudeb codex gemini; do
  clear_stub
  set_config "${vendor}_profile=pinned" 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' 'gemini_model=pro' 'gemini_effort=high'
  printf 'explicit\npicked\npinned\n' >"$STUB_DIR/gemini_profiles"
  export PICK_ACCOUNT=picked PICK_RC=0
  start_ok "$vendor" --account explicit
  assert meta_account_is explicit
  assert test ! -s "$PICK_LOG"
  assert await_done

  clear_stub
  export PICK_ACCOUNT=picked PICK_RC=0
  start_ok "$vendor"
  assert meta_account_is picked
  assert grep -qx -- "--account $vendor" "$PICK_LOG"
  assert await_done

  clear_stub
  export PICK_ACCOUNT=ignored PICK_RC=2
  start_ok "$vendor"
  assert meta_account_is pinned
  assert await_done
done

for vendor in codex gemini; do
  clear_stub
  set_config 'codex_effort=medium' 'gemini_model=pro' 'gemini_effort=high'
  export PICK_RC=2 PICK_ACCOUNT=ignored
  start_ok "$vendor"
  assert meta_account_is main
  assert await_done
done

for vendor in claudeb codex gemini; do
  clear_stub
  set_config 'claudeb_profile=pin' 'gemini_profile=pin'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" >"$WORK/refused.out" 2>"$WORK/refused.err" || rc=$?
  assert test "$rc" -eq 3
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_USAGE_LIMIT" "$WORK/refused.out"
  assert test ! -s "$CALL_LOG"
done

clear_stub
set_config 'codex_effort=medium'
export PICK_RC=2
rc=0
"$RUNNER" start claudeb --brief "$WORK/brief" >"$WORK/no-pin.out" 2>"$WORK/no-pin.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'needs an explicit account' "$WORK/no-pin.err"

clear_stub
set_config 'gemini_model=pro' 'gemini_effort=high'
export PICK_RC=2
start_ok gemini --account main
assert meta_agy_is 'Gemini 3.1 Pro (High)'
assert await_done
start_ok gemini --account main --model pro --effort low
assert meta_agy_is 'gemini-3.1-pro-low'
assert await_done
start_ok gemini --account main --model flash --effort medium
assert meta_agy_is 'gemini-3.6-flash-medium'
assert test "$(jq -r '.model' "$RUN_DIR/meta.json")" = flash36
assert await_done
start_ok gemini --account main --model flash35 --effort low
assert meta_agy_is 'gemini-3.5-flash-low'
assert await_done
start_ok gemini --account main --model flash36 --effort ultra
assert meta_agy_is 'gemini-3.6-flash-high'
assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = high
assert await_done
rc=0
"$RUNNER" start gemini --brief "$WORK/brief" --account main --model pro --effort medium >"$WORK/reject.out" 2>&1 || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GEMINI_UNAVAILABLE' "$WORK/reject.out"
printf 'known\n' >"$STUB_DIR/gemini_profiles"
rc=0
"$RUNNER" start gemini --brief "$WORK/brief" --account unknown >"$WORK/unknown.out" 2>&1 || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GEMINI_UNAVAILABLE' "$WORK/unknown.out"

clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=resumeacct

# Resume without an explicit account must refuse: worker-pick may route to a
# profile that does not hold the session being resumed.
rc=0
"$RUNNER" start claudeb --brief "$WORK/brief" --resume claude-resume >"$WORK/resume-noacct.out" 2>&1 || rc=$?
assert test "$rc" -eq 4
assert grep -q -- '--resume requires --account' "$WORK/resume-noacct.out"

start_ok claudeb --account resumeacct --resume claude-resume
assert await_done
assert grep -q '^ARG=--resume$' "$CALL_LOG"
assert grep -q '^ARG=claude-resume$' "$CALL_LOG"
assert test "$(tail -n1 "$CALL_LOG")" = 'ARG=claude-resume'

clear_stub
set_config 'codex_effort=high'
start_ok codex --account resumeacct --resume codex-resume
assert await_done
assert grep -q '^CODEX_HOME=.*/\.codex-profiles/resumeacct$' "$CALL_LOG"
assert grep -q '^ARG=resume$' "$CALL_LOG"
assert grep -q '^ARG=codex-resume$' "$CALL_LOG"
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 0
assert test "$(grep -c '^ARG=--color$' "$CALL_LOG")" -eq 0

# Explicit --model/--effort override a resumed session; config defaults never do.
clear_stub
set_config 'codex_effort=high'
start_ok codex --account resumeacct --resume codex-resume --model gpt-5.6-zenith --effort low
assert grep -qx 'TAG: resumeacct · zenith · low' "$WORK/start.out"
assert await_done
assert grep -q '^ARG=resume$' "$CALL_LOG"
assert grep -q '^ARG=-m$' "$CALL_LOG"
assert grep -q '^ARG=gpt-5.6-zenith$' "$CALL_LOG"
assert grep -q '^ARG=model_reasoning_effort=low$' "$CALL_LOG"

# codex resume cannot carry --add-dir; refuse before launching anything.
clear_stub
rc=0
"$RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" --account resumeacct --resume codex-resume --add-dir "$WORK/extra" >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'codex resume does not support --add-dir' "$WORK/start.err"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 0

clear_stub
printf 'resumeacct\n' >"$STUB_DIR/gemini_profiles"
start_ok gemini --account resumeacct --resume gemini-resume
assert await_done
assert grep -qxF "ARG=$HOME/.claude" "$CALL_LOG"
assert grep -q '^ARG=--conversation$' "$CALL_LOG"
assert grep -q '^ARG=gemini-resume$' "$CALL_LOG"
assert test "$(tail -n2 "$CALL_LOG" | head -n1)" = 'ARG=--print'
assert test "$(tail -n1 "$CALL_LOG")" = "ARG=\$'test brief\\nsecond line'"

clear_stub
set_config 'codex_effort=high'
start_ok codex --account options --add-dir "$WORK/extra" --image "$WORK/image.png" --web-search
assert await_done
assert grep -q '^ARG=--add-dir$' "$CALL_LOG"
assert grep -q '^ARG=-i$' "$CALL_LOG"
assert grep -q '^ARG=web_search=live$' "$CALL_LOG"
assert cmp -s "$WORK/brief" "$STUB_DIR/codex.stdin"

# Relative --image/--add-dir are pinned to the caller's cwd: the detached
# supervisor cds to workdir before the CLI resolves them.
clear_stub
set_config 'codex_effort=high'
printf 'img\n' >"$WORK/rel-image.png"
mkdir -p "$WORK/rel-extra"
(cd "$WORK" && "$RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" --account options --add-dir rel-extra --image rel-image.png) >"$WORK/start.out" 2>"$WORK/start.err" || fail "relative-path start failed: $(<"$WORK/start.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/start.out")
assert await_done
assert grep -qxF "ARG=$WORK/rel-extra" "$CALL_LOG"
assert grep -qxF "ARG=$WORK/rel-image.png" "$CALL_LOG"

for spec in 'claudeb:usage limit reached:CLAUDEB_USAGE_LIMIT' 'codex:quota exhausted:CODEX_USAGE_LIMIT' 'gemini:RESOURCE_EXHAUSTED:GEMINI_USAGE_LIMIT'; do
  IFS=: read -r vendor error outcome <<<"$spec"
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' 'gemini_model=pro' 'gemini_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9 STUB_ERROR="$error"
  printf 'limitacct\n' >"$STUB_DIR/gemini_profiles"
  start_ok "$vendor"
  assert await_done
  assert grep -q '^STATUS: failed$' "$WORK/wait.out"
  assert grep -qx "OUTCOME: $outcome" "$WORK/wait.out"
done

# A clean exit whose text merely mentions quotas is not a limit: no OUTCOME line.
clear_stub
set_config 'gemini_model=pro' 'gemini_effort=high'
export PICK_RC=0 PICK_ACCOUNT=chatty STUB_CODE=0 STUB_ERROR='discussed quota and 429 handling'
printf 'chatty\n' >"$STUB_DIR/gemini_profiles"
start_ok gemini
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME:' "$WORK/wait.out")" -eq 0

# A failed run whose ANSWER (stdout) mentions quotas is a plain failure, not a
# limit: only stderr carries vendor limit signatures.
clear_stub
set_config 'gemini_model=pro' 'gemini_effort=high'
export PICK_RC=0 PICK_ACCOUNT=chatty STUB_CODE=5 STUB_STDOUT='the task discussed quota and 429 handling'
printf 'chatty\n' >"$STUB_DIR/gemini_profiles"
start_ok gemini
assert await_done
assert grep -qx 'OUTCOME: GEMINI_UNAVAILABLE' "$WORK/wait.out"

for spec in 'claudeb:CLAUDEB_FAILED' 'codex:CODEX_UNAVAILABLE' 'gemini:GEMINI_UNAVAILABLE'; do
  IFS=: read -r vendor outcome <<<"$spec"
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' 'gemini_model=pro' 'gemini_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=failedacct STUB_CODE=7 STUB_ERROR='ordinary failure'
  printf 'failedacct\n' >"$STUB_DIR/gemini_profiles"
  start_ok "$vendor"
  assert await_done
  assert grep -qx "OUTCOME: $outcome" "$WORK/wait.out"
  assert grep -q '^ERR-TAIL:$' "$WORK/wait.out"
  assert grep -q 'ordinary failure' "$WORK/wait.out"
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

clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=effortacct
: >"$STUB_DIR/claudeb_drop_effort"
start_ok claudeb
assert await_done
assert test "$(grep -c '^CLAUDEB_CALL$' "$CALL_LOG")" -eq 2
assert test "$(grep -c '^ARG=--effort$' "$CALL_LOG")" -eq 1
assert jq -e '.effort_flag_dropped == true' "$RUN_DIR/meta.json" >/dev/null

report=$("$RUNNER" report "$RUN_ID")
assert test "$(head -n1 <<<"$report")" = 'ACCOUNT: effortacct (claudeb)'
assert grep -q '^COST: 1.25$' <<<"$report"
assert grep -q '^RESULT:$' <<<"$report"
assert grep -q '^claudeb result$' <<<"$report"

# "429" only counts as a limit signature with digit boundaries: an error id that
# merely contains it stays an ordinary failure.
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9 STUB_ERROR='request failed, incident 42903'
start_ok claudeb
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_FAILED' "$WORK/wait.out"
clear_stub
export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9 STUB_ERROR='HTTP 429 too many requests'
start_ok claudeb
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_USAGE_LIMIT' "$WORK/wait.out"

# Accounts carrying a live same-vendor run are excluded from the pick, so
# parallel starts spread instead of stacking on one account.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=other STUB_SLEEP=2
start_ok codex --account busy1
BUSY_RUN_ID=$RUN_ID
unset STUB_SLEEP
start_ok codex
assert meta_account_is other
assert grep -qx -- '--account codex --exclude busy1' "$PICK_LOG"
assert await_done

# Busy is a preference, not a wall: an excluded pick that fails is retried
# without exclusions before any limit verdict.
clear_stub
export PICK_RC=3 PICK_ACCOUNT=ignored
rc=0
"$RUNNER" start codex --brief "$WORK/brief" >"$WORK/busy-walled.out" 2>&1 || rc=$?
assert test "$rc" -eq 3
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/busy-walled.out"
assert grep -qx -- '--account codex --exclude busy1' "$PICK_LOG"
assert grep -qx -- '--account codex' "$PICK_LOG"
export PICK_RC=0
RUN_ID=$BUSY_RUN_ID
assert await_done

# A pid that outlives its run (reboot reuse, supervisor killed before writing
# exit_code) must not report "running" forever once the deadline is long past.
clear_stub
STALE_DIR="$WORKER_RUN_DIR/codex-9-9-aaaa"
mkdir -p "$STALE_DIR"
: >"$STALE_DIR/out"
: >"$STALE_DIR/err"
jq -cn --argjson pid "$$" '{vendor:"codex",account:"stale",pid:$pid,started_at:1000}' >"$STALE_DIR/meta.json"
stale_wait=$("$RUNNER" wait codex-9-9-aaaa --max 0)
assert grep -q '^STATUS: failed$' <<<"$stale_wait"
assert grep -q '^EXIT: unknown$' <<<"$stale_wait"
stale_report=$("$RUNNER" report codex-9-9-aaaa)
assert grep -q '^STATUS: failed$' <<<"$stale_report"

# A wedged vendor CLI is killed at the deadline and the run turns terminal.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=wedged STUB_SLEEP=30 WORKER_RUN_DEADLINE=1
start_ok codex
unset STUB_SLEEP WORKER_RUN_DEADLINE
deadline_wait=$("$RUNNER" wait "$RUN_ID" --max 30)
assert grep -q '^STATUS: failed$' <<<"$deadline_wait"
assert grep -qx 'OUTCOME: CODEX_UNAVAILABLE' <<<"$deadline_wait"

# A garbage deadline falls back to the default instead of disarming the watchdog.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=deadacct WORKER_RUN_DEADLINE='not-a-number'
start_ok codex
unset WORKER_RUN_DEADLINE
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"

# The gemini brief travels on argv: oversized briefs are refused up front.
clear_stub
set_config 'gemini_model=pro' 'gemini_effort=high'
export PICK_RC=0 PICK_ACCOUNT=main
head -c 200000 /dev/zero | tr '\0' 'x' >"$WORK/huge-brief"
rc=0
"$RUNNER" start gemini --brief "$WORK/huge-brief" >"$WORK/huge.out" 2>"$WORK/huge.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'briefs over 128KB cannot launch' "$WORK/huge.err"

echo "PASS: $asserts asserts; worker-run detaches vendor CLIs, preserves live runs across bounded waits, resolves accounts and model knobs, retries only documented compatibility failures, and reports terminal outcomes"
