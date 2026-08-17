#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/bin/worker-run"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then
    fail "assert $asserts unexpectedly succeeded: $*"
  else
    status=$?
    [ "$status" -ne 127 ] || fail "assert $asserts command not found: $*"
  fi
}

export HOME="$WORK/home"
export WORKER_RUN_DIR="$WORK/runs"
export WORKER_RUN_CONFIG_FILE="$WORK/worker-model"
export WORKER_RUN_CODEX_CONFIG="$WORK/config.toml"
export WORKER_RUN_WORKER_PICK="$WORK/bin/worker-pick"
export WORKER_RUN_CLAUDEB="$WORK/bin/claudeb"
export WORKER_RUN_CODEX="$WORK/bin/codex"
export WORKER_RUN_GEMINIB="$WORK/bin/geminib"
export CLAUDEB_PROFILES_ROOT="$HOME/.claude-profiles"
export CODEX_PROFILES_DIR="$HOME/.codex-profiles"
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
# A reroute chain needs a different answer per call, and the env of the detached
# supervisor is frozen at launch: the queue file feeds one "<rc> [account]
# [reserve]" line per pick, oldest first.
if [ -s "$STUB_DIR/pick_queue" ]; then
  IFS= read -r queued <"$STUB_DIR/pick_queue"
  sed '1d' "$STUB_DIR/pick_queue" >"$STUB_DIR/pick_queue.next" && mv "$STUB_DIR/pick_queue.next" "$STUB_DIR/pick_queue"
  # shellcheck disable=SC2086
  set -- $queued
  [ "$1" = 0 ] || exit "$1"
  [ "${3:-}" != reserve ] || printf 'worker-pick: %s is the session account (SESSION RESERVE)\n' "$2" >&2
  printf '%s\n' "$2"
  exit 0
fi
case "${PICK_RC:-0}" in
  0)
    # The real picker announces a session-reserve answer on stderr only; stdout stays the
    # bare account name.
    [ "${PICK_ACCOUNT:-picked}" != "${PICK_RESERVE_ACCOUNT:-}" ] ||
      printf 'worker-pick: %s is the session account (SESSION RESERVE)\n' "${PICK_ACCOUNT}" >&2
    printf '%s\n' "${PICK_ACCOUNT:-picked}"
    ;;
  *)
    [ -z "${PICK_STDERR:-}" ] || printf '%s\n' "$PICK_STDERR" >&2
    exit "${PICK_RC}"
    ;;
esac
EOF

cat >"$WORK/bin/claudeb" <<'EOF'
#!/usr/bin/env bash
{
  printf 'CLAUDEB_CALL\n'
  printf 'ARG=%q\n' "$@"
} >>"$CALL_LOG"
# The real CLI refuses an empty stdin in --print mode; the stub must too, or a
# lost brief (background stdin defaulting to /dev/null) passes the suite.
input=$(cat)
if [ -z "$input" ]; then
  printf 'Error: Input must be provided either through stdin or as a prompt argument\n' >&2
  exit 1
fi
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
has_model=false
previous=''
for arg in "$@"; do
  [ "$previous" != -o ] || out="$arg"
  [ "$arg" != --skip-git-repo-check ] || skip=true
  [ "$arg" != -m ] || has_model=true
  previous="$arg"
done
cat >"$STUB_DIR/codex.stdin"
codex_account=main
case "${CODEX_HOME-}" in */*) codex_account=${CODEX_HOME##*/} ;; esac
if [ -r "$STUB_DIR/wall_accounts" ] && grep -qx "$codex_account" "$STUB_DIR/wall_accounts"; then
  printf 'ERROR: You have hit your usage limit.\n' >&2
  exit 9
fi
# Real codex mutated the running worker-run mid-session and killed a successful
# run; the stub reproduces that by appending to the script it was launched from.
[ ! -r "$STUB_DIR/codex_append_target" ] || printf 'garbage )(\n' >>"$(cat "$STUB_DIR/codex_append_target")"
if [ -e "$STUB_DIR/codex_trusted" ] && [ "$skip" = false ]; then
  printf 'Not inside a trusted directory\n' >&2
  exit 1
fi
bad_model=false
[ ! -e "$STUB_DIR/codex_bad_model" ] || [ "$has_model" = false ] || bad_model=true
[ ! -e "$STUB_DIR/codex_bad_model_always" ] || bad_model=true
if [ "$bad_model" = true ]; then
  # codex echoes the brief and every file the worker reads onto stderr; those
  # lines named CODEX_USAGE_LIMIT and quotas in the live incident.
  printf 'RETURN (max 120 words): OUTCOME first (DONE/FAILED/CODEX_USAGE_LIMIT)\n' >&2
  printf 'docs say: quota exhausted means the account is walled\n' >&2
  printf 'ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The %s model is not supported when using Codex with a ChatGPT account."}}\n' "'gpt-5.6'" >&2
  exit 1
fi
if [ -e "$STUB_DIR/codex_phrase_deep" ]; then
  printf 'note: that model is not supported everywhere\n' >&2
  seq 1 60 | sed 's/^/transcript line /' >&2
  printf 'ERROR: You have hit your usage limit.\n' >&2
  exit 1
fi
if [ -e "$STUB_DIR/codex_noise" ]; then
  printf 'RETURN: OUTCOME first (DONE/FAILED/CODEX_USAGE_LIMIT), then per fix\n' >&2
  printf 'rate-limit and usage_limit and quota appear in this repo prose\n' >&2
fi
if [ -e "$STUB_DIR/codex_noise_deep" ]; then
  printf 'the docs even spell out "quota exhausted" verbatim\n' >&2
  seq 1 60 | sed 's/^/transcript line /' >&2
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
  rm -f "$STUB_DIR/claudeb_drop_effort" "$STUB_DIR/codex_trusted" "$STUB_DIR/codex.stdin" \
    "$STUB_DIR/codex_bad_model" "$STUB_DIR/codex_bad_model_always" "$STUB_DIR/codex_noise" \
    "$STUB_DIR/codex_noise_deep" "$STUB_DIR/codex_phrase_deep" "$STUB_DIR/codex_append_target" \
    "$STUB_DIR/wall_accounts" "$STUB_DIR/pick_queue"
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
assert grep -q 'test brief' "$STUB_DIR/codex.stdin"
assert grep -q 'second line' "$STUB_DIR/codex.stdin"
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
  assert jq -e '.pinned == false' "$RUN_DIR/meta.json" >/dev/null
  assert await_done

  clear_stub
  export PICK_ACCOUNT=ignored PICK_RC=2
  start_ok "$vendor"
  assert meta_account_is pinned
  assert jq -e '.pinned == true' "$RUN_DIR/meta.json" >/dev/null
  assert await_done
done

# The picker's reserve note is the only warning that a worker is about to spend the live
# session's own quota, so it must reach the launch context and the run's own record.
clear_stub
set_config 'codex_effort=medium'
export PICK_ACCOUNT=reserved PICK_RC=0 PICK_RESERVE_ACCOUNT=reserved
start_ok codex
assert meta_account_is reserved
assert grep -q 'reserved is the session account (SESSION RESERVE)' "$WORK/start.err"
assert jq -e '.session_reserve == true' "$RUN_DIR/meta.json" >/dev/null
assert await_done
assert grep -q '^ACCOUNT: reserved (codex) SESSION RESERVE$' <<<"$("$RUNNER" report "$RUN_ID")"

clear_stub
export PICK_ACCOUNT=picked
start_ok codex
assert meta_account_is picked
assert test ! -s "$WORK/start.err"
assert jq -e 'has("session_reserve") | not' "$RUN_DIR/meta.json" >/dev/null
assert await_done
assert grep -q '^ACCOUNT: picked (codex)$' <<<"$("$RUNNER" report "$RUN_ID")"
unset PICK_RESERVE_ACCOUNT

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

# An empty worker pool is a decision, not a limit: reporting it as a usage limit would send the
# orchestrator hunting for quota that was never the problem.
for vendor in claudeb codex gemini; do
  clear_stub
  set_config 'codex_effort=medium'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  export PICK_STDERR="worker-pick: every $vendor account is out of the worker pool (claude: one 3% off)"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" >"$WORK/pool-empty.out" 2>"$WORK/pool-empty.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/pool-empty.out"
  assert grep -q "every $vendor account is out of the worker pool" "$WORK/pool-empty.err"
  assert test ! -s "$CALL_LOG"
  unset PICK_STDERR
done

# A vendor switched off for workers is the same decision one step higher: its accounts may sit
# at 0%, so reading it as a usage limit would report a wall that does not exist.
for vendor in claudeb codex gemini; do
  clear_stub
  set_config 'codex_effort=medium'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  export PICK_STDERR="worker-pick: $vendor is switched off for workers"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" >"$WORK/role-off.out" 2>"$WORK/role-off.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/role-off.out"
  assert grep -q "$vendor is switched off for workers" "$WORK/role-off.err"
  assert test ! -s "$CALL_LOG"
  unset PICK_STDERR
done

# The role switch closes the vendor, not one account of it, so naming an account outright — or
# falling back to the pin — cannot walk around it the way it cannot walk around the pool.
for vendor in claudeb codex gemini; do
  clear_stub
  set_config "${vendor}_workers=off" 'codex_effort=medium'
  export PICK_ACCOUNT=picked PICK_RC=0
  printf 'explicit\npicked\n' >"$STUB_DIR/gemini_profiles"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --account explicit \
    >"$WORK/role-wall.out" 2>"$WORK/role-wall.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/role-wall.out"
  assert grep -q "$vendor is switched off for workers" "$WORK/role-wall.err"
  assert test ! -s "$CALL_LOG"
  # The vendor pin is the one override, the same way it is the only way past the pool.
  clear_stub
  set_config "${vendor}_workers=off" "${vendor}_profile=explicit" 'codex_effort=medium'
  export PICK_ACCOUNT=ignored PICK_RC=2
  start_ok "$vendor"
  assert meta_account_is explicit
  assert await_done
  clear_stub
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --account other \
    >"$WORK/role-pin.out" 2>"$WORK/role-pin.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/role-pin.out"
  assert test ! -s "$CALL_LOG"
  # Only the literal `off` closes it.
  clear_stub
  set_config "${vendor}_workers=on" 'codex_effort=medium'
  export PICK_ACCOUNT=picked PICK_RC=0
  start_ok "$vendor" --account explicit
  assert meta_account_is explicit
  assert await_done
done

# A missing wall is loud: worker-run must refuse to launch rather than read every account as
# excluded because its include went missing.
NOSHARE_RUNNER="$WORK/noshare/bin/worker-run"
mkdir -p "$WORK/noshare/bin"
cp "$RUNNER" "$NOSHARE_RUNNER"
noshare_rc=0
"$NOSHARE_RUNNER" start codex --brief "$WORK/brief" >"$WORK/noshare.out" 2>"$WORK/noshare.err" || noshare_rc=$?
assert test "$noshare_rc" -eq 4
assert grep -q 'share/worker-pool.sh is missing' "$WORK/noshare.err"
assert_fails grep -q 'out of the worker pool' "$WORK/noshare.err"

# The pool is a wall, not advice to the picker: a brief naming an excluded account cannot get in,
# and only the vendor pin overrides.
pool_dir_for() {
  case "$1" in
    claudeb) printf '%s/.claude-profiles/.claudeb\n' "$HOME" ;;
    codex) printf '%s/.codex-profiles/.codexb\n' "$HOME" ;;
    gemini) printf '%s/.gemini-profiles/.geminib\n' "$HOME" ;;
  esac
}
for vendor in claudeb codex gemini; do
  clear_stub
  set_config 'codex_effort=medium'
  export PICK_ACCOUNT=picked PICK_RC=0
  printf 'explicit\npicked\n' >"$STUB_DIR/gemini_profiles"
  pool_dir=$(pool_dir_for "$vendor")
  mkdir -p "$pool_dir"
  printf 'explicit\n' >"$pool_dir/disabled"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --account explicit \
    >"$WORK/pool-wall.out" 2>"$WORK/pool-wall.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/pool-wall.out"
  assert grep -q 'explicit is out of the worker pool' "$WORK/pool-wall.err"
  assert test ! -s "$CALL_LOG"
  set_config "${vendor}_profile=explicit" 'codex_effort=medium'
  start_ok "$vendor" --account explicit
  assert meta_account_is explicit
  assert await_done
  rm -f "$pool_dir/disabled"
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

mkdir -p "$CLAUDEB_PROFILES_ROOT/resumeacct/projects/fixture"
claude_transcript="$CLAUDEB_PROFILES_ROOT/resumeacct/projects/fixture/claude-cold.jsonl"
printf '%s\n' '{"message":{"usage":{"input_tokens":1}}}' '{"message":{"usage":{"input_tokens":2,"cache_read_input_tokens":150000,"cache_creation_input_tokens":500}}}' >"$claude_transcript"
touch -t 202001010000 "$claude_transcript"
clear_stub
start_ok claudeb --account resumeacct --resume claude-cold
assert grep -q 'RESUME-COLD: claudeb' "$WORK/start.err"
assert grep -q 'context ~151k tokens' "$WORK/start.err"
assert await_done

touch "$claude_transcript"
clear_stub
start_ok claudeb --account resumeacct --resume claude-cold
assert test "$(grep -c 'RESUME-COLD:' "$WORK/start.err")" -eq 0
assert await_done

clear_stub
start_ok claudeb --account resumeacct --resume claude-missing
assert test "$(grep -c 'RESUME-COLD:' "$WORK/start.err")" -eq 0
assert await_done

clear_stub
set_config 'codex_effort=high'
start_ok codex --account resumeacct --resume codex-resume
assert await_done
assert grep -q '^CODEX_HOME=.*/\.codex-profiles/resumeacct$' "$CALL_LOG"
assert grep -q '^ARG=resume$' "$CALL_LOG"
assert grep -q '^ARG=codex-resume$' "$CALL_LOG"
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 0
assert test "$(grep -c '^ARG=--color$' "$CALL_LOG")" -eq 0

mkdir -p "$CODEX_PROFILES_DIR/resumeacct/sessions/fixture"
codex_transcript="$CODEX_PROFILES_DIR/resumeacct/sessions/fixture/rollout-codex-cold.jsonl"
printf '%04000d\n' 0 >"$codex_transcript"
touch -t 202001010000 "$codex_transcript"
clear_stub
start_ok codex --account resumeacct --resume codex-cold
assert grep -q 'RESUME-COLD: codex' "$WORK/start.err"
assert grep -q 'cache TTL ~30m expired' "$WORK/start.err"
assert await_done

touch "$codex_transcript"
clear_stub
start_ok codex --account resumeacct --resume codex-cold
assert test "$(grep -c 'RESUME-COLD:' "$WORK/start.err")" -eq 0
assert await_done

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
gemini_transcript="$CLAUDEB_PROFILES_ROOT/resumeacct/projects/fixture/gemini-resume.jsonl"
printf '{}\n' >"$gemini_transcript"
touch -t 202001010000 "$gemini_transcript"
start_ok gemini --account resumeacct --resume gemini-resume
assert test "$(grep -c 'RESUME-COLD:' "$WORK/start.err")" -eq 0
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

# These picks keep naming the one account that walls — a picker that ignores
# --exclude — so the run has nowhere to reroute and the limit outcome reaches
# the caller.
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

# A brief's model override the account cannot use is dropped once and rerun:
# worker-pick's own default always resolves, so the run survives.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=badmodel
: >"$STUB_DIR/codex_bad_model"
start_ok codex --model gpt-5.6
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 1
assert test "$(grep -c '^ARG=gpt-5.6$' "$CALL_LOG")" -eq 1
assert jq -e '.model_flag_dropped == true' "$RUN_DIR/meta.json" >/dev/null
assert cmp -s "$WORK/brief" "$STUB_DIR/codex.stdin"

# A clean exit whose stderr mentions the phrase is not rerun.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=badmodel STUB_ERROR='note: that model is not supported everywhere'
start_ok codex --model gpt-5.6
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
start_ok codex --model gpt-5.6
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
start_ok codex --model gpt-5.6
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
# worker-run sources share/worker-pool.sh relative to its own resolved root, so a copy needs the
# share tree beside it — the pool wall must never be a file the runner can quietly do without.
mkdir -p "$WORK/share"
cp "$ROOT/share/worker-pool.sh" "$WORK/share/"
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
assert grep -q '^COST: 625k tok-eq$' <<<"$report"
assert grep -q '^RESULT:$' <<<"$report"
assert grep -q '^claudeb result$' <<<"$report"

jq '.total_cost_usd = 0.0005' "$RUN_DIR/out" >"$WORK/out.small" && mv "$WORK/out.small" "$RUN_DIR/out"
assert grep -q '^COST: 250 tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"
export WORKER_RUN_S5_USD_PER_M=0
assert grep -q '^COST: 250 tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"
export WORKER_RUN_S5_USD_PER_M=not-a-number
assert grep -q '^COST: 250 tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"
unset WORKER_RUN_S5_USD_PER_M

jq '.total_cost_usd = 0.001999' "$RUN_DIR/out" >"$WORK/out.rollover" && mv "$WORK/out.rollover" "$RUN_DIR/out"
assert grep -q '^COST: 1k tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"

jq '.total_cost_usd = 0.0000005' "$RUN_DIR/out" >"$WORK/out.tiny" && mv "$WORK/out.tiny" "$RUN_DIR/out"
assert grep -q '^COST: <1 tok-eq$' <<<"$("$RUNNER" report "$RUN_ID")"

# The changed files a report claims are the ones the RUN's own transcript recorded. A shared
# checkout carries other agents' live work, so nothing here may fall back to the workdir: a missing
# transcript answers "unknown" rather than with somebody else's hunks.
assert grep -qx 'RUN-FILES: unknown (no session transcript for claude-session)' \
  <<<"$("$RUNNER" report "$RUN_ID")"
mkdir -p "$CLAUDEB_PROFILES_ROOT/effortacct/projects/fixture"
run_workdir=$(jq -r '.workdir' "$RUN_DIR/meta.json")
run_started=$(jq -r '.started_at' "$RUN_DIR/meta.json")
# Milliseconds on purpose: that is what a real transcript writes, and jq's own fromdateiso8601
# refuses them — a fixture stamped to the whole second would pass over the parse this depends on.
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
TOOL_TS=$(iso $((run_started + 1)))
tool_call() {
  jq -cn --arg name "$1" --arg key "$2" --arg path "$3" --arg id "${4-}" --arg ts "$TOOL_TS" \
    '{type: "assistant", timestamp: $ts,
      message: {content: [{type: "tool_use", name: $name, input: {($key): $path}}
      + (if $id == "" then {} else {id: $id} end)]}}'
}
tool_error() {
  jq -cn --arg id "$1" --arg ts "$TOOL_TS" \
    '{type: "user", timestamp: $ts, message: {content: [{type: "tool_result", tool_use_id: $id,
      is_error: true, content: "permission denied"}]}}'
}
TRANSCRIPT="$CLAUDEB_PROFILES_ROOT/effortacct/projects/fixture/claude-session.jsonl"
# An edit the run was DENIED, or one that failed, is a file the run never changed: counting it puts
# somebody else's untouched file in this run's own list.
{
  tool_call Edit file_path "$run_workdir/bin/one"
  tool_call Write file_path "$run_workdir/bin/one"
  tool_call NotebookEdit notebook_path "$run_workdir/tests/two.ipynb"
  tool_call Read file_path "$run_workdir/never-written"
  tool_call Edit file_path "$WORK/outside/three"
  tool_call Write file_path "$run_workdir/bin/refused" tu_1
  tool_error tu_1
} >"$TRANSCRIPT"
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 3' <<<"$report"
assert grep -qx 'RUN-FILE: bin/one' <<<"$report"
assert grep -qx 'RUN-FILE: tests/two.ipynb' <<<"$report"
assert grep -qxF "RUN-FILE: $WORK/outside/three" <<<"$report"
# The paths are workdir-relative, and the reader that journals them for the launching chat stands
# somewhere else entirely: without this line above the count they resolve against the wrong tree.
assert grep -qxF "WORKDIR: $run_workdir" <<<"$report"
assert test "$(grep -n '^WORKDIR: ' <<<"$report" | cut -d: -f1)" \
  -lt "$(grep -n '^RUN-FILES: ' <<<"$report" | cut -d: -f1)"
assert test "$(grep -c 'never-written' <<<"$report")" -eq 0
assert test "$(grep -c 'bin/refused' <<<"$report")" -eq 0

# A trailing slash on the workdir is the same workdir: doubling the prefix stopped the stripping and
# printed every path absolute, as if the run had worked outside its own directory.
jq --arg w "$run_workdir/" '.workdir = $w' "$RUN_DIR/meta.json" >"$WORK/meta.slash" \
  && mv "$WORK/meta.slash" "$RUN_DIR/meta.json"
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 3' <<<"$report"
assert grep -qx 'RUN-FILE: bin/one' <<<"$report"
jq --arg w "$run_workdir" '.workdir = $w' "$RUN_DIR/meta.json" >"$WORK/meta.plain" \
  && mv "$WORK/meta.plain" "$RUN_DIR/meta.json"

# A --resume run appends to the SAME session transcript, so the file still holds the calls of the
# runs before it: reported unfiltered, this run claims files an earlier one edited — the shared-work
# mistake this whole list exists to avoid, one directory in. The run's own started_at is the cut, and
# a call stamped in that very second is this run's.
TOOL_TS=$(iso $((run_started - 7200)))
{
  tool_call Edit file_path "$run_workdir/bin/pre-resume"
  tool_call Write file_path "$run_workdir/tests/pre-resume.sh"
} >"$TRANSCRIPT"
TOOL_TS=$(iso "$run_started")
tool_call Edit file_path "$run_workdir/bin/at-start" >>"$TRANSCRIPT"
TOOL_TS=$(iso $((run_started + 2)))
tool_call Write file_path "$run_workdir/bin/this-run" >>"$TRANSCRIPT"
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 2' <<<"$report"
assert grep -qx 'RUN-FILE: bin/at-start' <<<"$report"
assert grep -qx 'RUN-FILE: bin/this-run' <<<"$report"
assert test "$(grep -c 'pre-resume' <<<"$report")" -eq 0

# Nothing recorded is not "nothing changed": an edit made through the shell — `sed -i`, a redirect,
# `mv` — appears in no transcript as a tool call, so the zero says what it actually counted.
: >"$TRANSCRIPT"
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$("$RUNNER" report "$RUN_ID")"
# Nothing to resolve, so nothing to resolve it against: a bare WORKDIR line over a count that names
# no file reads as a directory this run is claiming.
assert test "$(grep -c '^WORKDIR: ' <<<"$("$RUNNER" report "$RUN_ID")")" -eq 0

# A transcript jq cannot parse is unknown, never 0: the pipeline used to swallow the parse failure
# and report an authoritative "changed nothing" about a run nobody could read.
printf 'not json {\n' >"$TRANSCRIPT"
assert grep -qx 'RUN-FILES: unknown (transcript unreadable)' <<<"$("$RUNNER" report "$RUN_ID")"

# A vendor whose transcript records no per-file tool calls says so; a silent 0 would read as a run
# that changed nothing.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=filesacct
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (codex records no per-file tool calls in a transcript)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

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

# An account that walls mid-task does not end the run: the same brief continues
# on the next account the picker offers, and the caller re-dispatches nothing.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=unused
printf 'walled1\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 walled1' '0 rescue1' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME:' "$WORK/wait.out")" -eq 0
assert meta_account_is rescue1
assert jq -e '.walled_accounts == ["walled1"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx -- '--account codex' "$PICK_LOG"
assert grep -qx -- '--account codex --exclude walled1' "$PICK_LOG"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert grep -q '^CODEX_HOME=.*/\.codex-profiles/rescue1$' "$CALL_LOG"
assert grep -qx 'REROUTE: walled on walled1 → continued on rescue1' "$WORK/wait.out"
assert grep -qx 'rescue1 · sol · high' "$RUN_DIR/tag"
# The relaunch starts the brief fresh on the new account.
assert cmp -s "$WORK/brief" "$STUB_DIR/codex.stdin"
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'ACCOUNT: rescue1 (codex)' <<<"$report"
assert grep -qx 'REROUTE: walled on walled1 → continued on rescue1' <<<"$report"

# The chain survives several walls, and every account already burnt stays
# excluded from the next query.
clear_stub
set_config 'codex_effort=high'
printf 'walled1\nwalled2\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 walled1' '0 walled2' '0 rescue2' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert meta_account_is rescue2
assert jq -e '.walled_accounts == ["walled1","walled2"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx -- '--account codex --exclude walled1' "$PICK_LOG"
assert grep -qx -- '--account codex --exclude walled1,walled2' "$PICK_LOG"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 3
assert test "$(grep -c '^REROUTE: ' "$WORK/wait.out")" -eq 2
assert grep -qx 'REROUTE: walled on walled2 → continued on rescue2' "$WORK/wait.out"

# ALL WALLED is the only way the usage-limit outcome still reaches the caller.
clear_stub
set_config 'codex_effort=high'
printf 'walled1\nwalled2\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 walled1' '0 walled2' '3' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: failed$' "$WORK/wait.out"
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"
assert meta_account_is walled2
assert jq -e '.walled_accounts == ["walled1"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'REROUTE: walled on walled1 → continued on walled2' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2

# A gemini rescue account must hold a usable geminib profile, the same check
# start_run applies: an unlisted answer ends the run instead of relaunching
# into a CLI error.
clear_stub
set_config 'gemini_model=pro' 'gemini_effort=high'
printf 'walledg\n' >"$STUB_DIR/gemini_profiles"
export STUB_CODE=9 STUB_ERROR='RESOURCE_EXHAUSTED'
printf '%s\n' '0 walledg' '0 unlisted' >"$STUB_DIR/pick_queue"
start_ok gemini
assert await_done
assert grep -qx 'OUTCOME: GEMINI_USAGE_LIMIT' "$WORK/wait.out"
assert meta_account_is walledg
assert test "$(grep -c '^REROUTE: ' "$WORK/wait.out")" -eq 0

# An explicit --account is the caller's decision: a pinned run reports the wall
# instead of spending someone else's quota on it.
clear_stub
set_config 'codex_effort=high'
printf 'pinnedacct\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 rescue3' >"$STUB_DIR/pick_queue"
start_ok codex --account pinnedacct
assert await_done
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"
assert meta_account_is pinnedacct
assert jq -e 'has("walled_accounts") | not' "$RUN_DIR/meta.json" >/dev/null
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert test ! -s "$PICK_LOG"
assert grep -qx '0 rescue3' "$STUB_DIR/pick_queue"
assert test "$(grep -c '^REROUTE: ' "$WORK/wait.out")" -eq 0

# A re-pick that lands on the session account must say so exactly as the first
# pick does — the reroute is not a quieter path onto the live chat's quota.
clear_stub
set_config 'codex_effort=high'
printf 'walled1\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 walled1' '0 reserved1 reserve' >"$STUB_DIR/pick_queue"
start_ok codex
assert test ! -s "$WORK/start.err"
assert await_done
assert meta_account_is reserved1
assert jq -e '.session_reserve == true' "$RUN_DIR/meta.json" >/dev/null
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'ACCOUNT: reserved1 (codex) SESSION RESERVE' <<<"$report"
assert grep -qx 'REROUTE: walled on walled1 → continued on reserved1' <<<"$report"

# ...and the note belongs to the account actually in use: rerouting off the
# reserve clears it.
clear_stub
set_config 'codex_effort=high'
printf 'reserved0\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 reserved0 reserve' '0 plain1' >"$STUB_DIR/pick_queue"
start_ok codex
assert grep -q 'reserved0 is the session account (SESSION RESERVE)' "$WORK/start.err"
assert await_done
assert meta_account_is plain1
assert jq -e 'has("session_reserve") | not' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'ACCOUNT: plain1 (codex)' <<<"$("$RUNNER" report "$RUN_ID")"

echo "PASS: $asserts asserts; worker-run detaches vendor CLIs, preserves live runs across bounded waits, resolves accounts and model knobs, reroutes an unpinned run off a walled account until every candidate is walled, retries only documented compatibility failures, and reports terminal outcomes"
