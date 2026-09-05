#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/bin/worker-run"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL(line %s): %s\n' "${BASH_LINENO[1]-?}" "$*" >&2; exit 1; }
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

# What the vendor is handed is the brief plus worker-run's standing preamble; what the record keeps
# is the brief the caller wrote, byte for byte, because report/RESUME/ATTACH quote that one back.
assert_launched_brief() { # capture-of-what-the-CLI-read
  assert grep -qF 'TEST LOOP: while iterating run a one-off probe' "$1"
  # The memory guard's own sentence: a worker whose command is SIGKILLed by it sees exit 137 and
  # nothing else, and the obvious next move — rerun the command that just took the machine down —
  # is the one the preamble has to answer before it happens.
  assert grep -qF 'ended by signal 9 (exit 137) was killed by the machine' "$1"
  assert cmp -s "$WORK/brief" <(head -n "$(wc -l <"$WORK/brief")" "$1")
  assert cmp -s "$WORK/brief" "$RUN_DIR/brief"
}

export HOME="$WORK/home"
export WORKER_RUN_DIR="$WORK/runs"
export WORKER_RUN_CONFIG_FILE="$WORK/worker-model"
export WORKER_RUN_CODEX_CONFIG="$WORK/config.toml"
export WORKER_RUN_WORKER_PICK="$WORK/bin/worker-pick"
export WORKER_RUN_CLAUDEB="$WORK/bin/claudeb"
export WORKER_RUN_CODEX="$WORK/bin/codex"
export WORKER_RUN_GEMINIB="$WORK/bin/geminib"
export WORKER_RUN_GROKB="$WORK/bin/grokb"
export CLAUDEB_PROFILES_ROOT="$HOME/.claude-profiles"
export CODEX_PROFILES_DIR="$HOME/.codex-profiles"
export GEMINIB_PROFILES_DIR="$HOME/.gemini-profiles"
export GROKB_PROFILES_DIR="$HOME/.grok-profiles"
export STUB_DIR="$WORK/stub-state"
export CALL_LOG="$WORK/calls"
export PICK_LOG="$WORK/picks"
mkdir -p "$HOME" "$WORK/bin" "$WORKER_RUN_DIR" "$STUB_DIR" "$WORK/workdir" "$WORK/extra"
printf 'model = "gpt-6-astra"\n' >"$WORKER_RUN_CODEX_CONFIG"
printf 'test brief\nsecond line\n' >"$WORK/brief"
printf 'image\n' >"$WORK/image.png"

cat >"$WORK/bin/worker-pick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PICK_LOG"
# A reroute chain needs a different answer per call, and the env of the detached
# supervisor is frozen at launch: the queue file feeds one "<rc> [account]" line
# per pick, oldest first.
if [ -s "$STUB_DIR/pick_queue" ]; then
  IFS= read -r queued <"$STUB_DIR/pick_queue"
  sed '1d' "$STUB_DIR/pick_queue" >"$STUB_DIR/pick_queue.next" && mv "$STUB_DIR/pick_queue.next" "$STUB_DIR/pick_queue"
  # shellcheck disable=SC2086
  set -- $queued
  [ "$1" = 0 ] || exit "$1"
  printf '%s\n' "$2"
  exit 0
fi
case "${PICK_RC:-0}" in
  0)
    [ -z "${PICK_STDERR:-}" ] || printf '%s\n' "$PICK_STDERR" >&2
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
# Beside the argv, because the launching chat reaches the worker only through the environment:
# inside the CLI, CLAUDE_CODE_SESSION_ID is the worker's own chat.
printf '%s\n' "${CLAUDE_LAUNCHER_SESSION-}" >"$STUB_DIR/launcher_env"
# What a relay's own journal hook is: a process inside the launched CLI, reaching the launching
# chat through the environment and through nothing else.
[ ! -x "$STUB_DIR/relay_hook" ] || "$STUB_DIR/relay_hook" "${STUB_SESSION-claude-session}"
# The real CLI refuses an empty stdin in --print mode; the stub must too, or a
# lost brief (background stdin defaulting to /dev/null) passes the suite.
input=$(cat)
if [ -z "$input" ]; then
  printf 'Error: Input must be provided either through stdin or as a prompt argument\n' >&2
  exit 1
fi
# The real CLI names a transcript after the session and fills it from the first turn, long before
# `out` exists; a run killed mid-work has nothing else to report a SESSION: from.
if [ -n "${STUB_TRANSCRIPT_SESSION:-}" ]; then
  transcript_dir="$CLAUDEB_PROFILES_ROOT/${STUB_TRANSCRIPT_ACCOUNT:-picked}/projects/fixture"
  mkdir -p "$transcript_dir"
  # A file per LAUNCH, named after the attempt the brief carries, because the real CLI opens a new
  # session for every launch: a stub that reuses one name cannot show which attempt's transcript a
  # relaunched run adopts. Attempt 1 keeps the plain name every other case here asserts on.
  transcript_name=$STUB_TRANSCRIPT_SESSION
  attempt=${input##*-a}
  case "$attempt" in ''|*[!0-9]*) attempt=1 ;; esac
  [ "$attempt" = 1 ] || transcript_name="$STUB_TRANSCRIPT_SESSION-$attempt"
  jq -cn --arg t "$input" '{type:"user",message:{role:"user",content:$t}}' \
    >"$transcript_dir/$transcript_name.jsonl"
fi
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
has_effort=false
for arg in "$@"; do [ "$arg" != --effort ] || has_effort=true; done
# After the sleep, so a dropped-effort attempt can be given a lifetime: discovery runs on the
# watchdog's tick, and an attempt that exits before the first tick is never looked for at all.
if [ -e "$STUB_DIR/claudeb_drop_effort" ] && [ "$has_effort" = true ]; then
  printf 'unknown option --effort\n' >&2
  exit 2
fi
[ -z "${STUB_ERROR:-}" ] || printf '%s\n' "$STUB_ERROR" >&2
[ -z "${STUB_STDOUT:-}" ] || printf '%s\n' "$STUB_STDOUT"
if [ "${STUB_CODE:-0}" -eq 0 ]; then
  printf '{"result":"claudeb result","session_id":"%s","total_cost_usd":1.25}\n' "${STUB_SESSION-claude-session}"
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
# A worker that is working writes: STUB_HEARTBEAT seconds of stderr, which the supervisor
# redirects into the run's `err`, is what the idle watchdog must read as activity.
beats=${STUB_HEARTBEAT:-0}
while [ "$beats" -gt 0 ]; do
  printf 'working\n' >&2
  sleep 1
  beats=$((beats - 1))
done
# What a relay's own journal hook is: a process inside the launched CLI, reaching the launching
# chat through the environment and through nothing else.
[ ! -x "$STUB_DIR/relay_hook" ] || "$STUB_DIR/relay_hook" codex-session
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
if [ -n "${STUB_SLEEP:-}" ]; then
  # Backgrounded and waited on, with both pids on disk: a signal that reaches only this wrapper
  # leaves the sleep orphaned and running, which is the shape of a supervisor killed out from
  # under a live CLI.
  printf '%s\n' "$$" >"$STUB_DIR/codex.pid"
  sleep "$STUB_SLEEP" &
  printf '%s\n' "$!" >"$STUB_DIR/codex.child.pid"
  wait $!
fi
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
# What a relay's own journal hook is: a process inside the launched CLI, reaching the launching
# chat through the environment and through nothing else.
[ ! -x "$STUB_DIR/relay_hook" ] || "$STUB_DIR/relay_hook" gemini-conversation
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
[ -z "${STUB_ERROR:-}" ] || printf '%s\n' "$STUB_ERROR" >&2
[ -z "${STUB_STDOUT:-}" ] || printf '%s\n' "$STUB_STDOUT"
[ "${STUB_CODE:-0}" -ne 0 ] || printf 'gemini result\n'
exit "${STUB_CODE:-0}"
EOF

cp "$ROOT/tests/fixtures/fake-grokb.sh" "$WORK/bin/grokb"
chmod +x "$WORK/bin"/*

set_config() {
  printf '%s\n' "$@" >"$WORKER_RUN_CONFIG_FILE"
}

clear_stub() {
  : >"$CALL_LOG"
  : >"$PICK_LOG"
  unset STUB_SLEEP STUB_HEARTBEAT STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT \
    STUB_ERROR STUB_CODE STUB_STDOUT STUB_SESSION STUB_GROK_SESSION STUB_GROK_MODEL \
    STUB_GROK_ANSWER STUB_GROK_ERROR_EVENT STUB_GROK_TURNS
  rm -f "$STUB_DIR/claudeb_drop_effort" "$STUB_DIR/codex_trusted" "$STUB_DIR/codex.stdin" \
    "$STUB_DIR/codex_bad_model" "$STUB_DIR/codex_bad_model_always" "$STUB_DIR/codex_noise" \
    "$STUB_DIR/codex_noise_deep" "$STUB_DIR/codex_phrase_deep" "$STUB_DIR/codex_append_target" \
    "$STUB_DIR/wall_accounts" "$STUB_DIR/pick_queue" "$STUB_DIR/grok_wall_accounts" \
    "$STUB_DIR/grok_auth" "$STUB_DIR/grok_transient" "$STUB_DIR/grok_denied" \
    "$STUB_DIR/grok_max_turns" "$STUB_DIR/codex.pid" "$STUB_DIR/codex.child.pid"
}

start_ok() {
  local vendor="$1"
  shift
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --workdir "${WORKER_TEST_WORKDIR:-$WORK/workdir}" "$@" >"$WORK/start.out" 2>"$WORK/start.err" || fail "start $vendor failed: $(<"$WORK/start.err")"
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
assert grep -qx 'TAG: fast · astra · high' "$WORK/start.out"
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
# A terminal wait names the answer and never quotes it: the relay reads `report` next in any case,
# and a tail here handed the orchestrator the same result twice.
assert grep -qxF "RESULT: run \`worker-run report $RUN_ID\`" <<<"$second_wait"
assert test "$(grep -c 'codex result' <<<"$second_wait")" -eq 0
assert grep -qx 'codex result' <<<"$("$RUNNER" report "$RUN_ID")"
assert grep -q 'test brief' "$STUB_DIR/codex.stdin"
assert grep -q 'second line' "$STUB_DIR/codex.stdin"
unset STUB_SLEEP

clear_stub
set_config 'codex_effort=high'
export PICK_ACCOUNT=fast PICK_RC=0
start_ok codex --model default
assert grep -qx 'TAG: fast · astra · high' "$WORK/start.out"
assert grep -qx 'fast · astra · high' "$RUN_DIR/tag"
assert await_done

# A running run whose vendor has already surfaced its id reports it mid-flight,
# so a budget-spent relay can still hand back a resumable session.
clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=high'
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
  set_config "${vendor}_profile=pinned" 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' 'gemini_model=flash38' 'gemini_effort=high'
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
  # Claims own cross-run spreading, so every automatic launch makes one claimed query and does
  # not derive a second exclusion layer from worker-run's live-run registry.
  assert grep -qx -- "--account $vendor --claim" "$PICK_LOG"
  assert jq -e '.pinned == false' "$RUN_DIR/meta.json" >/dev/null
  assert await_done

  clear_stub
  export PICK_ACCOUNT=ignored PICK_RC=2
  start_ok "$vendor"
  assert meta_account_is pinned
  assert jq -e '.pinned == true' "$RUN_DIR/meta.json" >/dev/null
  assert await_done
done

# Legacy picker stderr remains visible but has no routing or report semantics.
clear_stub
set_config 'codex_effort=medium'
export PICK_ACCOUNT=picked PICK_RC=0 PICK_STDERR='worker-pick: legacy SESSION RESERVE note'
start_ok codex
assert meta_account_is picked
assert grep -qxF "$PICK_STDERR" "$WORK/start.err"
assert jq -e 'has("session_reserve") | not' "$RUN_DIR/meta.json" >/dev/null
assert await_done
assert grep -q '^ACCOUNT: picked (codex)$' <<<"$("$RUNNER" report "$RUN_ID")"
unset PICK_STDERR

for vendor in codex gemini; do
  clear_stub
  set_config 'codex_effort=medium' 'gemini_model=flash38' 'gemini_effort=high'
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

# A paused vendor is parked, not spent: its refusal must land as UNAVAILABLE the way role-off does.
for vendor in claudeb codex gemini grok; do
  clear_stub
  set_config 'codex_effort=medium'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  export PICK_STDERR="worker-pick: $vendor is paused (${vendor}_paused=on in ~/.claude/worker-model)"
  rc=0
  "$RUNNER" start "$vendor" --brief "$WORK/brief" >"$WORK/paused.out" 2>"$WORK/paused.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx "OUTCOME: $(tr '[:lower:]' '[:upper:]' <<<"$vendor")_UNAVAILABLE" "$WORK/paused.out"
  assert grep -q "$vendor is paused" "$WORK/paused.err"
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
    grok) printf '%s/.grok-profiles/.grokb\n' "$HOME" ;;
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
set_config 'gemini_model=flash38' 'gemini_effort=high'
export PICK_RC=2
start_ok gemini --account main
assert meta_agy_is 'gemini-3.8-flash-high'
assert await_done
start_ok gemini --account main --model flash38 --effort low
assert meta_agy_is 'gemini-3.8-flash-low'
assert await_done
# Unlike the Pro this leg used to run, 3.8 Flash serves `medium` too, so it is a launch and not
# the refusal the pair used to be.
start_ok gemini --account main --model flash38 --effort medium
assert meta_agy_is 'gemini-3.8-flash-medium'
assert await_done
start_ok gemini --account main --model flash38 --effort ultra
assert meta_agy_is 'gemini-3.8-flash-high'
assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = high
assert await_done
rc=0
"$RUNNER" start gemini --brief "$WORK/brief" --account main --model flash38 --effort tiny >"$WORK/reject.out" 2>&1 || rc=$?
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
# A resume with no explicit model keeps the session's own: the config default must not travel.
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 0
assert await_done

# Explicit --model/--effort override a resumed session; config defaults never do.
clear_stub
set_config 'codex_effort=high'
start_ok codex --account resumeacct --resume codex-resume --model gpt-6-astra --effort low
assert grep -qx 'TAG: resumeacct · astra · low' "$WORK/start.out"
assert await_done
assert grep -q '^ARG=resume$' "$CALL_LOG"
assert grep -q '^ARG=-m$' "$CALL_LOG"
assert grep -q '^ARG=gpt-6-astra$' "$CALL_LOG"
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
assert grep -q "^ARG=\$'test brief" <<<"$(tail -n1 "$CALL_LOG")"
assert grep -qF 'TEST LOOP: while iterating run a one-off probe' <<<"$(tail -n1 "$CALL_LOG")"
assert grep -qF 'ended by signal 9 (exit 137) was killed by the machine' <<<"$(tail -n1 "$CALL_LOG")"
assert cmp -s "$WORK/brief" "$RUN_DIR/brief"

clear_stub
set_config 'codex_effort=high'
start_ok codex --account options --add-dir "$WORK/extra" --image "$WORK/image.png" --web-search
assert await_done
assert grep -q '^ARG=--add-dir$' "$CALL_LOG"
assert grep -q '^ARG=-i$' "$CALL_LOG"
assert grep -q '^ARG=web_search=live$' "$CALL_LOG"
assert_launched_brief "$STUB_DIR/codex.stdin"

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
# Codex's "out of credits" is the same wall in other words: the plan's window is spent and it
# offers paid credits to continue — the account is back at the reset, not broken.
for spec in 'claudeb:usage limit reached:CLAUDEB_USAGE_LIMIT' 'codex:quota exhausted:CODEX_USAGE_LIMIT' 'codex:Your workspace is out of credits:CODEX_USAGE_LIMIT' 'gemini:RESOURCE_EXHAUSTED:GEMINI_USAGE_LIMIT'; do
  IFS=: read -r vendor error outcome <<<"$spec"
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' 'gemini_model=flash38' 'gemini_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9 STUB_ERROR="$error"
  printf 'limitacct\n' >"$STUB_DIR/gemini_profiles"
  start_ok "$vendor"
  assert await_done
  assert grep -q '^STATUS: failed$' "$WORK/wait.out"
  assert grep -qx "OUTCOME: $outcome" "$WORK/wait.out"
  assert grep -qx 'WALL: pool exhausted (walled: limitacct)' "$WORK/wait.out"
done

clear_stub
set_config 'codex_effort=medium'
export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9
export STUB_ERROR='ERROR: unexpected status 402 Payment Required: Payment Required, url: https://chatgpt.com/backend-api/codex/responses, cf-ray: a34f7001de413244-VIE, auth error: 402, auth error code: deactivated_workspace'
start_ok codex
assert await_done
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"

clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=limitacct STUB_CODE=9
export STUB_STDOUT="{\"result\":\"You've hit your session limit · resets 10:40pm (Europe/Kiev)\",\"is_error\":true}"
start_ok claudeb
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_USAGE_LIMIT' "$WORK/wait.out"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=ordinary STUB_CODE=9
export STUB_STDOUT='{"result":"ordinary failure","is_error":true}'
start_ok claudeb
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_FAILED' "$WORK/wait.out"

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
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'HINT: this run edited nothing — a read-only lookup is cheaper as a native Explore/research helper (see ~/.claude/CLAUDE.md, Model routing); read-only relay runs this month: 1' <<<"$report"
assert test -f "$RUN_DIR/report-readonly"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=readonly-two STUB_TRANSCRIPT_SESSION=readonly-two STUB_SESSION=readonly-two
export STUB_TRANSCRIPT_ACCOUNT=readonly-two
start_ok claudeb
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'HINT: this run edited nothing — a read-only lookup is cheaper as a native Explore/research helper (see ~/.claude/CLAUDE.md, Model routing); read-only relay runs this month: 2' <<<"$report"
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
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' <<<"$report"
assert test -z "$(git -C "$declared_workdir" status --porcelain -uall)"
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
start_ok codex --model gpt-6-astra
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 1
assert test "$(grep -c '^ARG=gpt-6-astra$' "$CALL_LOG")" -eq 1
assert jq -e '.model_flag_dropped == true' "$RUN_DIR/meta.json" >/dev/null
assert_launched_brief "$STUB_DIR/codex.stdin"

# A clean exit whose stderr mentions the phrase is not rerun.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=badmodel STUB_ERROR='note: that model is not supported everywhere'
start_ok codex --model gpt-6-astra
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
start_ok codex --model gpt-6-astra
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
start_ok codex --model gpt-6-astra
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
cp "$ROOT/share/worker-pool.sh" "$ROOT/share/gemini-accounts.sh" "$ROOT/share/worker-model.sh" \
  "$ROOT/share/limits-view.sh" "$WORK/share/"
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

# A run whose transcript cannot be found says so; a silent 0 would read as a run that changed
# nothing. Every vendor answers here now, so the reason names the missing rollout and no longer
# claims the vendor keeps no record at all.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=filesacct
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (no session transcript for codex-session)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# --- The run record ------------------------------------------------------------------------------
# What a run wrote, and for whom, kept beside the run itself. A report answers only whoever printed
# it: unprinted it named nobody's work, truncated it named part of it, and pasted elsewhere it named
# the wrong chat. The record is written whether or not anyone ever looks, and a vendor that cannot
# name files says so here too — a reader must not take the silence for an empty list.
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $(jq -r '.workdir' "$RUN_DIR/meta.json")"
assert grep -qx 'UNKNOWN: no session transcript for codex-session' "$RUN_DIR/files"
# And the run's own session is recorded whatever the vendor: grok loads this machine's hooks out of
# `~/.claude/settings.json` for Claude compatibility and journals under its own id, a codex or agy
# id reaching a journal is that case one relay deeper, and an id that reaches no journal costs a
# reader nothing — the pairing is only ever consulted about an id some row already carries.
assert test "$(cat "$RUN_DIR/worker-session")" = codex-session

clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=recordacct
mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
# Stamped ahead of now because the run has not started yet and its own start is the cut: a fixture
# written at this second would be filtered out as the work of some earlier run.
TOOL_TS=$(iso $(($(date +%s) + 60)))
# The run records its workdir as git and the shell resolve it, and a fixture spelled through the
# symlink a temporary directory reaches it by strips against nothing.
record_workdir=$(cd "$WORK/workdir" && pwd -P)
{
  tool_call Edit file_path "$record_workdir/bin/recorded"
  tool_call Write file_path "$WORK/outside/recorded-absolute"
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc
start_ok claudeb
assert await_done
assert test "$(cat "$RUN_DIR/launcher")" = chat-abc
# And in the launched process's environment, under a name the harness does not overwrite: a report
# the worker produces is queued for the chat that asked for it, and this is the only thing that
# names one — inside the CLI, CLAUDE_CODE_SESSION_ID is the worker's own session, so a lost export
# files the report in the worker's own outbox where nobody ever reads it.
assert test "$(cat "$STUB_DIR/launcher_env")" = chat-abc
# The worker's OWN session beside the chat that launched it. A run that edits through the shell
# alone names no file here, while its own hooks journaled every one of those edits under this id —
# without the pair on record the launching chat commits its worker's work as nobody's.
assert test "$(cat "$RUN_DIR/worker-session")" = claude-session
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $record_workdir"
assert grep -qx 'bin/recorded' "$RUN_DIR/files"
assert grep -qxF "$WORK/outside/recorded-absolute" "$RUN_DIR/files"
assert test "$(grep -c '^UNKNOWN: ' "$RUN_DIR/files")" -eq 0
# The same paths the report prints: one answer rendered twice, never two answers that can disagree.
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILE: bin/recorded' <<<"$report"

# A walled attempt wrote whatever it wrote before the wall, and rerouting restamps the run's start
# and takes a new session — so the later attempt's own list cannot see it. The record is a union
# across attempts, or the first attempt's files belong to nobody at all.
printf '%s\n' "WORKDIR: $record_workdir" \
  'UNKNOWN: no session transcript for the walled attempt' bin/from-the-walled-attempt >"$RUN_DIR/files"
# The session that attempt ran under, which the reroute replaced: what it journaled stands under
# that id and under no other, so the sessions are unioned exactly as the paths are.
printf 'walled-session\n' >>"$RUN_DIR/worker-session"
"$RUNNER" _supervise "$RUN_DIR" >/dev/null 2>&1
assert grep -qx 'walled-session' "$RUN_DIR/worker-session"
assert grep -qx 'claude-session' "$RUN_DIR/worker-session"
# Once per id however often the record is rewritten: a resumed run repeats the id its session
# already had, and the readers walk this file against every journal row they hold.
assert test "$(grep -c . "$RUN_DIR/worker-session")" -eq 2
assert grep -qx 'bin/from-the-walled-attempt' "$RUN_DIR/files"
assert grep -qx 'bin/recorded' "$RUN_DIR/files"
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $record_workdir"
# The uncertainty carries forward with the paths: an attempt whose list was unanswerable stays
# unanswerable however cleanly the attempt after it read.
assert grep -qx 'UNKNOWN: no session transcript for the walled attempt' "$RUN_DIR/files"

# An editor list answers for editor calls. A run that also worked through the shell changed files no
# transcript records, so its list is a floor — said per run, since a run that ran no shell command
# has a complete one. PARTIAL rather than UNKNOWN: the paths beside it are real and reviewable, and
# the gate speaks about UNKNOWN alone.
assert test "$(grep -c '^PARTIAL: ' "$RUN_DIR/files")" -eq 0
assert test "$(grep -c 'RUN-FILES-PARTIAL: ' <<<"$report")" -eq 0
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$record_workdir/bin/recorded"
  tool_call Bash command 'sed -i "" s/a/b/ bin/edited-through-the-shell'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc
start_ok claudeb
assert await_done
assert grep -qx 'bin/recorded' "$RUN_DIR/files"
assert grep -q '^PARTIAL: the run also ran shell commands' "$RUN_DIR/files"
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$("$RUNNER" report "$RUN_ID")"

# What the run's own repository gained uncommitted content on while it ran — the only evidence a
# shell edit leaves anywhere. Nothing records `sed -i` as a tool call, so a file rewritten that way
# is in no listing, in no journal and under no artifact, and every standing-debt reader answered
# `none` over it (live case 2026-08-21).
clear_stub
DIRT_REPO="$WORK/dirt-repo"
mkdir -p "$DIRT_REPO/bin" "$DIRT_REPO/tests"
git -C "$DIRT_REPO" init -q .
printf 'original\n' >"$DIRT_REPO/bin/shell-edited"
printf 'original\n' >"$DIRT_REPO/tests/tracked-by-the-editor"
printf 'original\n' >"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
git -C "$DIRT_REPO" add -A >/dev/null
git -C "$DIRT_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
# Somebody else's live work, uncommitted BEFORE this run existed. The floor the snapshot is taken
# against, or every file Egor had open becomes evidence produced by whichever run finished beside it.
printf 'egor was here\n' >>"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
DIRT_TOP=$(cd "$DIRT_REPO" && pwd -P)
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor"
  tool_call Bash command 'sed -i "" s/original/rewritten/ bin/shell-edited'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc
start_ok claudeb --workdir "$DIRT_REPO"
# The stub never runs the worker's commands, so the shell edit and the editor call are made here —
# what is under test is which of them the record claims, not that a CLI can write a file.
printf 'rewritten\n' >"$DIRT_REPO/bin/shell-edited"
printf 'rewritten\n' >"$DIRT_REPO/tests/tracked-by-the-editor"
printf 'brand new\n' >"$DIRT_REPO/bin/created-through-a-redirect"
mkdir -p "$DIRT_REPO/notes"
printf 'brand new\n' >"$DIRT_REPO/notes/inside-an-untracked-directory"
assert await_done
assert test "$(head -n1 "$RUN_DIR/dirty")" = "WORKDIR: $DIRT_TOP"
assert grep -qx 'bin/shell-edited' "$RUN_DIR/dirty"
assert grep -qx 'bin/created-through-a-redirect' "$RUN_DIR/dirty"
# A file under a directory git has never tracked: named only with -uall, and reported as the bare
# directory otherwise — which is no path any reader of this record can price.
assert grep -qx 'notes/inside-an-untracked-directory' "$RUN_DIR/dirty"
assert_fails grep -qx 'notes/' "$RUN_DIR/dirty"
# Already dirty before the run began: a co-tenant's, and this run has no evidence about it.
assert_fails grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/dirty"
# The tracker named this one, so it is priced through the owner the listing carries; repeated here
# it would be one path claimed twice, once with an owner and once without.
assert_fails grep -qx 'tests/tracked-by-the-editor' "$RUN_DIR/dirty"
assert grep -qx 'tests/tracked-by-the-editor' "$RUN_DIR/files"

# A file already dirty that the run REWRITES is this run's work too. The floor is a set of NAMES,
# and subtracted by name a path that was on it before is invisible however far its content moved:
# a fixing pass whose every edit landed in files somebody already had open reached the record as
# nothing at all (live case 2026-08-22). So the floor carries each path's content beside its name,
# and a changed sha is the evidence a name comparison never had.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/x/y/ bin/the-co-tenant-was-already-editing-this' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
printf 'the run rewrote it\n' >>"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
assert await_done
assert grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/dirty"
# And a file on the same floor this run never touched is still the co-tenant's: same name, same
# content, no claim.
assert_fails grep -qx 'bin/somebody-elses-file' "$RUN_DIR/dirty"

# A run whose transcript answered for every edit it made has named its work already. The rest of a
# shared checkout's dirt is somebody else's, and a snapshot of it here is this run's record
# vouching for another chat's file.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
printf 'and again\n' >"$DIRT_REPO/bin/somebody-elses-file"
assert await_done
assert test "$(grep -c '^PARTIAL: ' "$RUN_DIR/files")" -eq 0
assert test ! -e "$RUN_DIR/dirty"

# A run launched in a SUBDIRECTORY still records its repository's own spelling of every path:
# `--porcelain` answers against the repository top whatever directory it was asked from, and
# anchored on the workdir instead every path would resolve one level deep and price nothing.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Bash command 'sed -i "" s/rewritten/again/ bin/shell-edited'
  tool_call Edit file_path "$DIRT_TOP/tests/named-from-a-subdirectory"
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO/tests"
printf 'from a subdirectory\n' >"$DIRT_REPO/bin/edited-from-a-subdirectory"
printf 'from a subdirectory\n' >"$DIRT_REPO/tests/named-from-a-subdirectory"
assert await_done
assert test "$(head -n1 "$RUN_DIR/dirty")" = "WORKDIR: $DIRT_TOP"
assert grep -qx 'bin/edited-from-a-subdirectory' "$RUN_DIR/dirty"
# And the listing still bounds the snapshot from one directory in: the two are spelled against
# different anchors, so subtracted in the listing's own spelling every path the run's own tracker
# named is recorded here a second time with no owner at all.
assert grep -qx 'named-from-a-subdirectory' "$RUN_DIR/files"
assert_fails grep -qx 'tests/named-from-a-subdirectory' "$RUN_DIR/dirty"

# The floor and a clean tree are the same empty set, so a floor git could not answer for is written
# nowhere at all and the snapshot refuses to run without one: measured against nothing, every file
# Egor and every co-tenant chat had open is content this run gained.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/again/once more/ bin/shell-edited' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
assert test -e "$RUN_DIR/dirty-before"
rm -f "$RUN_DIR/dirty-before"
printf 'nobody measured the floor\n' >"$DIRT_REPO/bin/without-a-floor"
assert await_done
assert test ! -e "$RUN_DIR/dirty"

# A workdir in no repository has no dirty set to take, and the run says nothing rather than
# guessing.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ somewhere' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb
assert await_done
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/dirty"
assert test ! -e "$RUN_DIR/dirty-before"

# --- What the run PRODUCED ------------------------------------------------------------------------
# A listing names paths; a debt reader prices CONTENT. `produced` is the run's own answer in the
# links that reader walks — `<prev>\t<cur>\t<path>`, with a fourth field `commit` on the transitions
# the run's own commits made — so ownership follows the BLOB and no longer a path and an epoch.
clear_stub
PROD_REPO="$WORK/produced-repo"
mkdir -p "$PROD_REPO/bin" "$PROD_REPO/tests"
git -C "$PROD_REPO" init -q .
printf 'one\n' >"$PROD_REPO/bin/modified"
printf 'here\n' >"$PROD_REPO/bin/deleted"
printf 'before\n' >"$PROD_REPO/bin/committed"
printf 'never moved\n' >"$PROD_REPO/bin/untouched"
printf 'orig\n' >"$PROD_REPO/bin/co-tenant-open"
# A filename holding a BACKSLASH, which is a legal name git records verbatim. Handed to awk through
# `-v` it arrives with its escapes expanded, so the floor lookup matched no row and the link was
# priced from HEAD's blob instead of from the content the co-tenant left standing.
PROD_ESC='bin/back\slash'
printf 'orig\n' >"$PROD_REPO/$PROD_ESC"
git -C "$PROD_REPO" add -A >/dev/null
git -C "$PROD_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
PROD_TOP=$(cd "$PROD_REPO" && pwd -P)
PROD_BASE=$(git -C "$PROD_REPO" rev-parse HEAD)
tab=$'\t'
blob_of() { printf '%s\n' "$1" | git -C "$PROD_REPO" hash-object --stdin; }
# A co-tenant's live edit, standing before this run was launched: it is what the run's own rewrite is
# measured against, and the one case HEAD's blob answers wrongly.
printf 'egor was here\n' >"$PROD_REPO/bin/co-tenant-open"
printf 'egor was here\n' >"$PROD_REPO/$PROD_ESC"
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$PROD_TOP/bin/modified"
  tool_call Write file_path "$PROD_TOP/bin/born"
  tool_call Edit file_path "$PROD_TOP/bin/deleted"
  tool_call Edit file_path "$PROD_TOP/bin/untouched"
  tool_call Edit file_path "$PROD_TOP/bin/co-tenant-open"
  tool_call Edit file_path "$PROD_TOP/$PROD_ESC"
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc STUB_SLEEP=1
start_ok claudeb --workdir "$PROD_REPO"
# The commit the tree stood on when the run was launched, written before the CLI takes a token: read
# at the end instead, every link the run committed would be measured against its own result.
assert test "$(cat "$RUN_DIR/head-before")" = "$PROD_BASE"
printf 'two\n' >"$PROD_REPO/bin/modified"
printf 'born\n' >"$PROD_REPO/bin/born"
rm -f "$PROD_REPO/bin/deleted"
printf 'the worker rewrote it\n' >"$PROD_REPO/bin/co-tenant-open"
printf 'the worker rewrote it\n' >"$PROD_REPO/$PROD_ESC"
printf 'after\n' >"$PROD_REPO/bin/committed"
printf 'landed\n' >"$PROD_REPO/bin/committed-born"
git -C "$PROD_REPO" add bin/committed bin/committed-born >/dev/null
git -C "$PROD_REPO" -c user.email=t@t -c user.name=t commit -qm 'the run committed' >/dev/null
assert await_done
assert grep -qxF -- "$(blob_of one)$tab$(blob_of two)${tab}bin/modified" "$RUN_DIR/produced"
# A file born and a file gone are the same row with `-` on the side holding no content: priced off
# the path alone, a birth reads as an edit of a file that was never there.
assert grep -qxF -- "-$tab$(blob_of born)${tab}bin/born" "$RUN_DIR/produced"
assert grep -qxF -- "$(blob_of here)$tab-${tab}bin/deleted" "$RUN_DIR/produced"
# Already dirty at launch: the floor's content is the prev, never HEAD's blob. Measured against the
# commit instead, this row claims a link the co-tenant produced.
assert grep -qxF -- "$(blob_of 'egor was here')$tab$(blob_of 'the worker rewrote it')${tab}bin/co-tenant-open" \
  "$RUN_DIR/produced"
# The same path spelled with a BACKSLASH, which is where the lookup into that floor is either
# literal or nothing: expanded as an escape, the name matched no row and the prev fell back to
# HEAD's blob, claiming the co-tenant's line as this run's.
assert grep -qxF -- "$(blob_of 'egor was here')$tab$(blob_of 'the worker rewrote it')$tab$PROD_ESC" \
  "$RUN_DIR/produced"
# Both sides WRITTEN to the object store, not merely named: the reader prices this link by diffing
# the two blobs there, and a side no store holds prices the whole file. Neither content is in any
# commit and `blob_of` writes nothing, so the floor's `-w` and the record's are all that can be
# holding them — the prev from the launch snapshot, the cur from the record written at the end.
assert git -C "$PROD_REPO" cat-file -e "$(blob_of 'egor was here')"
assert git -C "$PROD_REPO" cat-file -e "$(blob_of 'the worker rewrote it')"
# A listed path whose content never moved produced nothing: a row for it owns a link that is not
# there, and the reader would price the whole file against a base nobody wrote.
assert_fails grep -q 'bin/untouched' "$RUN_DIR/produced"
# The commits the run made, in the transitions git prints for them, marked so the reader can apply
# the first-row-wins rule that a cherry-picked blob needs and an edit does not.
assert grep -qxF -- "$(blob_of before)$tab$(blob_of after)${tab}bin/committed${tab}commit" "$RUN_DIR/produced"
assert grep -qxF -- "-$tab$(blob_of landed)${tab}bin/committed-born${tab}commit" "$RUN_DIR/produced"
# One grammar for both kinds, or the sweep reading these rows splits a path off the wrong field.
assert test "$(awk -F'\t' 'NF < 3 || NF > 4' "$RUN_DIR/produced" | wc -l | tr -d ' ')" -eq 0
assert test "$(awk -F'\t' 'NF == 4 && $4 != "commit"' "$RUN_DIR/produced" | wc -l | tr -d ' ')" -eq 0
assert test "$(awk -F'\t' '$3 == "bin/modified" { print NF }' "$RUN_DIR/produced")" = 3

# A repository CLEAN at launch writes an empty floor, and the rewrite scan that would re-hash the
# tree at the end is skipped over one — so the RECORD's own `hash-object -w` is the only thing that
# can put this `cur` in the store the reader diffs it out of. Which is the shape of every fresh
# worktree a worker is handed, and the case a repository already dirty at launch hides.
clear_stub
CLEAN_REPO="$WORK/clean-repo"
mkdir -p "$CLEAN_REPO/bin"
git -C "$CLEAN_REPO" init -q .
printf 'base\n' >"$CLEAN_REPO/bin/edited"
git -C "$CLEAN_REPO" add -A >/dev/null
git -C "$CLEAN_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
CLEAN_TOP=$(cd "$CLEAN_REPO" && pwd -P)
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$CLEAN_TOP/bin/edited" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$CLEAN_REPO"
assert test ! -s "$RUN_DIR/dirty-before-shas"
printf 'rewritten\n' >"$CLEAN_REPO/bin/edited"
assert await_done
assert grep -qxF -- "$(blob_of base)$tab$(blob_of rewritten)${tab}bin/edited" "$RUN_DIR/produced"
assert git -C "$CLEAN_REPO" cat-file -e "$(blob_of rewritten)"

# A run that answers to a chat and worked in a git tree writes the record even when it holds nothing:
# its PRESENCE is this run answering for its own content, and its absence is what sends a reader back
# to the listing and the floor.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Read file_path "$PROD_TOP/bin/untouched" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$PROD_REPO"
assert await_done
assert test -e "$RUN_DIR/produced"
assert test ! -s "$RUN_DIR/produced"

# A run no chat answers for produces nothing anybody owns: rows written here would be content
# attributed to the empty session, which is what the dirt record already says better.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$PROD_TOP/bin/modified" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
unset CLAUDE_CODE_SESSION_ID
start_ok claudeb --workdir "$PROD_REPO"
assert await_done
assert test ! -e "$RUN_DIR/launcher"
assert test ! -e "$RUN_DIR/produced"
export CLAUDE_CODE_SESSION_ID=chat-abc

# A workdir in no repository has no blobs to name, and neither record is invented for it.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$WORK/workdir/bin/somewhere" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb
assert await_done
assert test ! -e "$RUN_DIR/head-before"
assert test ! -e "$RUN_DIR/produced"

# The rows are spelled the way the listing is — against the WORKDIR, absolute where they fall outside
# it — so one reader resolves both records the same way for a run launched a directory in.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$PROD_TOP/tests/named-here"
  tool_call Edit file_path "$PROD_TOP/bin/named-from-the-top"
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$PROD_REPO/tests"
printf 'in the workdir\n' >"$PROD_REPO/tests/named-here"
printf 'above the workdir\n' >"$PROD_REPO/bin/named-from-the-top"
assert await_done
assert grep -qxF -- "-$tab$(blob_of 'in the workdir')${tab}named-here" "$RUN_DIR/produced"
assert grep -qxF -- "-$tab$(blob_of 'above the workdir')$tab$PROD_TOP/bin/named-from-the-top" \
  "$RUN_DIR/produced"

# What the launching chat CLAIMS is content this run produced too. Left out of the record, the very
# paths a claim exists to name are invisible to every reader that takes `produced` over the listing.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/claimed-content' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$PROD_REPO"
printf 'claimed content\n' >"$PROD_REPO/bin/claimed-content"
assert await_done
assert_fails grep -q 'bin/claimed-content' "$RUN_DIR/produced"
assert "$RUNNER" claim "$RUN_ID" --paths bin/claimed-content >/dev/null
assert grep -qxF -- "-$tab$(blob_of 'claimed content')${tab}bin/claimed-content" "$RUN_DIR/produced"
# APPENDED, never recomputed: the rows already standing were measured when the run ended, and a
# fresh pass over the record now dates whatever a co-tenant has done since to this run.
printf 'a co-tenant moved it on\n' >"$PROD_REPO/bin/claimed-content"
assert "$RUNNER" claim "$RUN_ID" --paths bin/claimed-content >/dev/null
assert grep -qxF -- "-$tab$(blob_of 'claimed content')${tab}bin/claimed-content" "$RUN_DIR/produced"
assert test "$(grep -cF 'bin/claimed-content' "$RUN_DIR/produced")" -eq 2


# --- Naming what the run could not name -----------------------------------------------------------
# A run that worked through the shell lists nothing and its work is owned by nobody. The launching
# chat is the one reader who knows which of the paths that changed in the run's window are its
# worker's, so `wait` prints them and `claim` records the answer.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/claimed-one' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc
start_ok claudeb --workdir "$DIRT_REPO"
printf 'through the shell\n' >"$DIRT_REPO/bin/claimed-one"
printf 'through the shell\n' >"$DIRT_REPO/bin/claimed-two"
assert await_done
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
# The line the orchestrator acts on, and the paths in it are already spelled the way `claim` takes
# them: a list it has to re-spell is a list it gets wrong.
assert grep -qxF "UNNAMED: 2 path(s) changed in this run's window that no record names — claim yours: worker-run claim $RUN_ID --paths $DIRT_TOP/bin/claimed-one $DIRT_TOP/bin/claimed-two" \
  "$WORK/wait.out"

# A live run is still writing its own record, and a claim landing mid-flight is overwritten by the
# next sweep — so the run has to have ended before anybody may name its files.
mv "$RUN_DIR/exit_code" "$RUN_DIR/exit_code.held"
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one
assert grep -q 'is still running' \
  <<<"$("$RUNNER" claim "$RUN_ID" --paths bin/claimed-one 2>&1 >/dev/null)"
mv "$RUN_DIR/exit_code.held" "$RUN_DIR/exit_code"

# Only the chat that spawned the run may name its work: another chat signing for it is one session
# taking a waiver over work it has never read.
assert_fails env CLAUDE_CODE_SESSION_ID=chat-somebody-else "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one
assert grep -q 'launched by chat-abc' \
  <<<"$(CLAUDE_CODE_SESSION_ID=chat-somebody-else "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one 2>&1 >/dev/null)"

# A shell that names no chat at all is not the launching chat either: read as an empty session it
# would match a record whose launcher is empty and claim the work of a run nobody can answer for.
assert_fails env -u CLAUDE_CODE_SESSION_ID "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one
assert grep -q 'this shell names no chat' \
  <<<"$(env -u CLAUDE_CODE_SESSION_ID "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one 2>&1 >/dev/null)"

# And a run whose own record names no launching chat is claimable by nobody, whoever is asking:
# the answer to "whose worker was this" is the record, and an empty one is not an open invitation.
mv "$RUN_DIR/launcher" "$RUN_DIR/launcher.held"
: >"$RUN_DIR/launcher"
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one
assert grep -q 'records no launching chat' \
  <<<"$("$RUNNER" claim "$RUN_ID" --paths bin/claimed-one 2>&1 >/dev/null)"
mv -f "$RUN_DIR/launcher.held" "$RUN_DIR/launcher"

# A path outside the run's workdir is not the run's to claim, and the whole call is refused rather
# than half applied — a claim that took some of its paths leaves the caller unable to tell which.
assert_fails "$RUNNER" claim "$RUN_ID" --paths /etc/hosts
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one ../outside-the-workdir
assert_fails grep -qx 'bin/claimed-one' "$RUN_DIR/files"
assert_fails "$RUNNER" claim "$RUN_ID"

# The claim itself: an ordinary listing row, the caveat beside it untouched, and the path gone from
# the dirt record — it carries an owner now.
claimed=$("$RUNNER" claim "$RUN_ID" --paths bin/claimed-one)
assert grep -qx "CLAIMED: 1 path(s) for $RUN_ID" <<<"$claimed"
assert grep -qx 'bin/claimed-one' <<<"$claimed"
assert grep -qx 'bin/claimed-one' "$RUN_DIR/files"
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $DIRT_TOP"
assert_fails grep -qx 'bin/claimed-one' "$RUN_DIR/dirty"
assert grep -qx 'bin/claimed-two' "$RUN_DIR/dirty"
# The rewritten record keeps the header its rows are spelled against: dropped, `unnamed_line` bails
# out on an empty `top` and every later wait silently stops naming what nobody has claimed.
assert test "$(head -n1 "$RUN_DIR/dirty")" = "WORKDIR: $DIRT_TOP"

# Absolute or workdir-relative, one answer; and a path the dirt record never held is named without
# being ADDED to the set of paths nobody names.
assert "$RUNNER" claim "$RUN_ID" --paths "$DIRT_TOP/bin/claimed-two" bin/never-was-dirty >/dev/null
assert grep -qx 'bin/claimed-two' "$RUN_DIR/files"
assert grep -qx 'bin/never-was-dirty' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/dirty"
# Nothing left unnamed, so the line is gone although the run's own list is still a floor.
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert_fails grep -q '^UNNAMED: ' <<<"$("$RUNNER" wait "$RUN_ID" --max 0)"

# `--complete` is the caller stating that this IS the whole list, and it is the only thing that
# retires the caveat: an ordinary claim adds real paths and says nothing about what stands beside
# them.
printf '%s\n' "UNKNOWN: no session transcript for a claim test" >>"$RUN_DIR/files"
assert "$RUNNER" claim "$RUN_ID" --paths bin/claimed-one --complete >/dev/null
assert test "$(grep -c '^PARTIAL: \|^UNKNOWN: ' "$RUN_DIR/files")" -eq 0
assert grep -qx 'bin/claimed-one' "$RUN_DIR/files"
assert grep -qx 'bin/claimed-two' "$RUN_DIR/files"
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $DIRT_TOP"

# The printed line is pasted into a shell, so it has to survive one: a path carrying a space
# reached `claim` as several paths, and one carrying a `*` as whatever the tree held beside it.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ "bin/named with a space"' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
printf 'through the shell\n' >"$DIRT_REPO/bin/named with a space"
assert await_done
printed=$(grep '^UNNAMED: ' "$WORK/wait.out")
assert test -n "$printed"
assert eval "\"$RUNNER\" ${printed#*claim yours: worker-run }" >/dev/null
assert grep -qxF 'bin/named with a space' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/dirty"

# The path split inside `claim` is lexical too: a `*` answered by the directory the caller happens
# to be standing in names a file this run never touched, and names it as the caller's own work.
printf 'a decoy the split must not find\n' >"$DIRT_REPO/globbedXstar"
assert eval '(cd "$DIRT_REPO" && "$RUNNER" claim "$RUN_ID" --paths "bin/globbed*star")' >/dev/null
assert grep -qxF 'bin/globbed*star' "$RUN_DIR/files"
assert_fails grep -q 'globbedXstar' "$RUN_DIR/files"

# A run launched in a SUBDIRECTORY: its dirt is its REPOSITORY's, spelled against the top, so the
# command `wait` prints names paths outside the workdir. Checked against the workdir alone, that
# exact command is refused whole and not one of its paths is claimed.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/claimed-from-a-subdirectory' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO/tests"
printf 'through the shell\n' >"$DIRT_REPO/bin/claimed-from-a-subdirectory"
assert await_done
assert grep -qxF "UNNAMED: 1 path(s) changed in this run's window that no record names — claim yours: worker-run claim $RUN_ID --paths $DIRT_TOP/bin/claimed-from-a-subdirectory" \
  "$WORK/wait.out"
assert eval "\"$RUNNER\" $(grep '^UNNAMED: ' "$WORK/wait.out" | sed 's/.*claim yours: worker-run //')" >/dev/null
# Spelled absolutely in the listing, exactly as any path outside the workdir is.
assert grep -qxF "$DIRT_TOP/bin/claimed-from-a-subdirectory" "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/dirty"
# Outside the repository is still nobody's to claim: what widened is the run's own tree, no more.
assert_fails "$RUNNER" claim "$RUN_ID" --paths /etc/hosts

# What the UNNAMED line turns on is the run saying it cannot name its own files — not on there
# being dirt. A caveat retired by `--complete` over a record that still holds rows prints nothing,
# and the complete-listing run below would pass that assertion with the guard deleted.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/still-unnamed' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
printf 'through the shell\n' >"$DIRT_REPO/bin/still-unnamed"
assert await_done
assert grep -q '^UNNAMED: ' "$WORK/wait.out"
assert "$RUNNER" claim "$RUN_ID" --paths bin/was-never-dirty --complete >/dev/null
assert grep -qx 'bin/still-unnamed' "$RUN_DIR/dirty"
assert_fails grep -q '^UNNAMED: ' <<<"$("$RUNNER" wait "$RUN_ID" --max 0)"

# A run whose window changed hundreds of paths printed all of them shell-quoted into ONE line at
# the end of every wait — multiple kilobytes, crowding out the outcome and the result tail it is
# printed beside. Past the cap the count is still exact and the reader is sent to the record.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/capped-one' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
for capped in one two three; do
  printf 'through the shell\n' >"$DIRT_REPO/bin/capped-$capped"
done
assert await_done
CAPPED_COUNT=$(grep -cv '^WORKDIR: ' "$RUN_DIR/dirty")
assert test "$CAPPED_COUNT" -ge 3
capped_line=$(WORKER_RUN_UNNAMED_INLINE_MAX=1 "$RUNNER" wait "$RUN_ID" --max 0 | grep '^UNNAMED: ')
assert grep -qF "UNNAMED: $CAPPED_COUNT path(s)" <<<"$capped_line"
# Named by the run's own record — spelled the way `wait` spells it, which is not always the
# absolute form `start` printed.
assert grep -qF "listed one per line in " <<<"$capped_line"
assert grep -qF "$RUN_ID/dirty" <<<"$capped_line"
assert_fails grep -q 'bin/capped-one' <<<"$capped_line"
assert test "${#capped_line}" -lt 400
# Under the cap it is still the paste-ready list, spelled the way `claim` takes it.
capped_full=$(WORKER_RUN_UNNAMED_INLINE_MAX="$CAPPED_COUNT" "$RUNNER" wait "$RUN_ID" --max 0 \
  | grep '^UNNAMED: ')
assert grep -qF "$DIRT_TOP/bin/capped-one" <<<"$capped_full"
assert eval "\"$RUNNER\" $(sed 's/.*claim yours: worker-run //' <<<"$capped_full")" >/dev/null

# The record it sends the reader to is spelled against the repository TOP, while `claim` resolves a
# relative operand against the run's WORKDIR: for a run launched in a subdirectory a row pasted as
# it stands names a path the run never touched, and the widened repository check takes it. So the
# line states the prefix, and following it mechanically claims what the record actually holds.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/capped-sub-one' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO/tests"
for capped in one two three; do
  printf 'through the shell\n' >"$DIRT_REPO/bin/capped-sub-$capped"
done
assert await_done
capped_sub_line=$(WORKER_RUN_UNNAMED_INLINE_MAX=1 "$RUNNER" wait "$RUN_ID" --max 0 \
  | grep '^UNNAMED: ')
assert grep -qF -e "--paths $DIRT_TOP/<row>" <<<"$capped_sub_line"
capped_sub_rows=$(grep -v '^WORKDIR: ' "$RUN_DIR/dirty" | sed '/^$/d')
capped_sub_paths=$(while IFS= read -r capped_row; do
  printf '%q ' "$DIRT_TOP/$capped_row"
done <<<"$capped_sub_rows")
assert eval "\"$RUNNER\" claim \"$RUN_ID\" --paths $capped_sub_paths" >/dev/null
while IFS= read -r capped_row; do
  assert grep -qxF "$DIRT_TOP/$capped_row" "$RUN_DIR/files"
done <<<"$capped_sub_rows"
assert test ! -e "$RUN_DIR/dirty"

# A run whose own list is complete has nothing for anyone to claim, so the line is never printed.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
assert await_done
assert_fails grep -q '^UNNAMED: ' "$WORK/wait.out"

# A running run's liveness, for the one reader who has nothing else: claudeb writes its JSON once,
# at the end, so OUT-BYTES reads 0 for the whole run and a wrapper agent declared a healthy
# 52-minute run stalled one minute before it finished (live 2026-08-24). The dirt tracker already
# knows which paths are this run's, and the newest of their mtimes is the answer.
clear_stub
printf 'delete me\n' >"$DIRT_REPO/bin/deletion-is-work"
git -C "$DIRT_REPO" add bin/deletion-is-work
git -C "$DIRT_REPO" -c user.email=t@t -c user.name=t commit -qm 'track deletion liveness'
# Every probe below has to land while the run is still going, and there are a dozen of them: at 4s
# the block failed under a parallel suite wave (2026-09-04) purely on machine load, while
# `await_done` at the end of it budgets ~20s.
export STUB_SLEEP=12
start_ok claudeb --workdir "$DIRT_REPO"
idle=$("$RUNNER" wait "$RUN_ID" --max 0)
assert grep -qx 'STATUS: running' <<<"$idle"
assert grep -qx 'OUT-BYTES: 0' <<<"$idle"
# Nothing has changed yet, and the dirt every co-tenant left behind before this run started is on
# the floor rather than in this answer.
assert grep -qx 'LAST-EDIT: none' <<<"$idle"
rm -f "$DIRT_REPO/bin/deletion-is-work"
deleting=$("$RUNNER" wait "$RUN_ID" --max 0)
assert grep -Eq '^LAST-EDIT: [0-9]$' <<<"$deleting"
printf 'the run is working\n' >"$DIRT_REPO/bin/proof-of-life"
working=$("$RUNNER" wait "$RUN_ID" --max 0)
assert grep -Eq '^LAST-EDIT: [0-9]$' <<<"$working"
assert grep -qx 'OUT-BYTES: 0' <<<"$working"
assert grep -Eq '^CPU-SECONDS: [0-9]+$' <<<"$working"
# The rows a relay already parses keep their bytes.
assert grep -Eq '^ELAPSED: [0-9]+$' <<<"$working"
assert grep -Eq '^ERR-BYTES: [0-9]+$' <<<"$working"
assert grep -Eq '^SESSION: ' <<<"$working"
assert grep -Eq '^(LAST-EDIT|CPU-SECONDS): ' <<<"$("$RUNNER" report "$RUN_ID")"
# Past the long-run mark the report says so next to ELAPSED: the launching chat's prompt cache
# cools past the hour, so the remainder belongs in a split brief rather than in this run.
assert_fails grep -q '^LONG-RUN: ' <<<"$working"
sleep 1
assert grep -q '^LONG-RUN: 0 min — the orchestrator' \
  <<<"$(WORKER_RUN_LONG_RUN_S=1 "$RUNNER" wait "$RUN_ID" --max 0)"
# And once per RUN: a relay returns a checkpoint on any LONG-RUN line, so a second round past the
# same mark saying it again bounced an attached relay back every ~9 minutes. The rest of the
# running rows are unchanged there.
said_again=$(WORKER_RUN_LONG_RUN_S=1 "$RUNNER" wait "$RUN_ID" --max 0)
assert_fails grep -q '^LONG-RUN: ' <<<"$said_again"
assert grep -qx 'STATUS: running' <<<"$said_again"
assert test -f "$RUN_DIR/long-run-said"
# That marker is the whole of what silences it: the threshold and its knob answer as before.
rm -f "$RUN_DIR/long-run-said"
jq '.started_at -= 1560' "$RUN_DIR/meta.json" >"$WORK/aged-meta.json"
mv "$WORK/aged-meta.json" "$RUN_DIR/meta.json"
long=$("$RUNNER" wait "$RUN_ID" --max 0)
assert grep -q '^LONG-RUN: 26 min — the orchestrator' <<<"$long"
assert grep -Eq '^ELAPSED: [0-9]+$' <<<"$long"
assert grep -qx 'STATUS: running' <<<"$long"
assert await_done
# A terminal report answers with the run's files instead; a liveness row there is a run still going.
assert test "$(grep -c '^LAST-EDIT: \|^CPU-SECONDS: ' "$WORK/wait.out")" -eq 0
unset STUB_SLEEP
unset CLAUDE_CODE_SESSION_ID

# --- Per-file lists from the gemini and codex transcripts ----------------------------------------
# Those vendors DO name the files they write, each in its own log, and a listless run claimed the
# whole workdir dirt of its time window — every path a co-tenant chat had edited in the same
# minutes read as this run's (shared-invariants row am bounds the claim, and only a real list can
# narrow it). The rule is fail-closed and whole-run: the list is exact only where every mutating
# action named its target.
clear_stub
unset CLAUDE_CODE_SESSION_ID
set_config 'gemini_model=flash38' 'gemini_effort=high'
printf 'gemfiles\n' >"$STUB_DIR/gemini_profiles"
agy_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
agy_row_status() { # created_at status name args-json
  jq -cn --arg ts "$1" --arg status "$2" --arg name "$3" --argjson args "$4" \
    '{step_index: 0, source: "MODEL", type: "PLANNER_RESPONSE", status: "DONE",
      created_at: $ts, tool_calls: [{name: $name, args: $args}]}'
  case "$3" in
    write_to_file|replace_file_content|multi_replace_file_content)
      jq -cn --arg ts "$1" --arg status "$2" \
        '{step_index: 1, source: "TOOL", type: "CODE_ACTION", created_at: $ts, status: $status}'
      ;;
  esac
}
agy_row() { agy_row_status "$1" DONE "$2" "$3"; }
agy_write() { agy_row "$AGY_TS" "$1" "$(jq -cn --arg p "$2" '{TargetFile: $p}')"; }
agy_read() { agy_row "$AGY_TS" view_file "$(jq -cn --arg p "$1" '{AbsolutePath: $p}')"; }
agy_shell() { agy_row "$AGY_TS" run_command "$(jq -cn --arg c "$1" --arg d "$2" '{CommandLine: $c, Cwd: $d}')"; }
AGY_TRANSCRIPT="$GEMINIB_PROFILES_DIR/gemfiles/.gemini/antigravity-cli/brain/gemini-conversation/.system_generated/logs/transcript_full.jsonl"
mkdir -p "$(dirname "$AGY_TRANSCRIPT")"
# The workdir as the shell resolves it: a fixture spelled through the symlink a temporary directory
# reaches strips against nothing, and every path then reads as one the run worked outside its own
# directory.
agy_workdir=$(cd "$WORK/workdir" && pwd -P)
export PICK_RC=0 PICK_ACCOUNT=gemfiles
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_write replace_file_content "$agy_workdir/bin/agy-written"
  agy_write multi_replace_file_content "$WORK/outside/agy-absolute"
  agy_read "$agy_workdir/bin/agy-only-read"
  agy_shell 'git status --short 2>/dev/null' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 2' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-written' <<<"$report"
assert grep -qxF "RUN-FILE: $WORK/outside/agy-absolute" <<<"$report"
# A file the run only READ is not a file it changed, and every listed path is one somebody will be
# asked to review.
assert test "$(grep -c 'agy-only-read' <<<"$report")" -eq 0
# A read-only shell command does not spoil the list, but any shell at all makes the list a floor —
# the same sentence claudeb's own runs carry, since it is the same fact about a transcript.
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"
assert grep -qx 'bin/agy-written' "$RUN_DIR/files"
assert test "$(grep -c '^UNKNOWN: ' "$RUN_DIR/files")" -eq 0
assert test ! -e "$RUN_DIR/workdir-escape"

# Relative tool targets are anchored to the run workdir before both rendering and escape detection.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
agy_write write_to_file 'bin/agy-relative' >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-relative' <<<"$report"
assert test ! -e "$RUN_DIR/workdir-escape"

# A rejected write changed nothing and cannot make the successful call beside it review debt.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-write-succeeded"
  agy_row_status "$AGY_TS" FAILED write_to_file \
    "$(jq -cn --arg p "$agy_workdir/bin/agy-write-failed" '{TargetFile: $p}')"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert test "$(grep -c '^RUN-FILE: ' <<<"$report")" -eq 1
assert grep -qx 'RUN-FILE: bin/agy-write-succeeded' <<<"$report"
assert test "$(grep -c 'agy-write-failed' <<<"$report")" -eq 0

# `transcript.jsonl` sits beside the one that was read and carries the same rows with the tool_call
# ARGUMENTS stripped: read instead of `transcript_full.jsonl` it can name no file ever again.
assert grep -q 'transcript_full.jsonl' "$ROOT/bin/worker-run"

# A shell command that WRITES leaves the run exactly as unanswerable as it was before any extractor
# existed: the transcript names the editor calls and nothing names the redirect beside them.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell "printf hello > $agy_workdir/bin/agy-through-a-redirect" "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$("$RUNNER" report "$RUN_ID")"
assert grep -qx 'UNKNOWN: the run wrote through the shell, whose targets no transcript names' \
  "$RUN_DIR/files"
# And no path stands beside the UNKNOWN: half a list read as the whole of one is the claim the
# fail-closed rule exists to refuse.
assert test "$(grep -c 'agy-written' "$RUN_DIR/files")" -eq 0

# Numbered and ampersand redirects open files too, so every supported fd spelling spoils the list.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell 'printf one 1>one; printf two 2>two; printf three 3>three; printf all &>all' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# A redirect to a file descriptor or to /dev/null writes no file. Counted as a write it made every
# `2>/dev/null` in a read-only review run unanswerable, which is most of them.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell 'pnpm install >/dev/null 2>&1; git diff 2>&1 | head -20; rg -n pattern . 2>/dev/null' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
assert grep -qx 'RUN-FILES: 1' <<<"$("$RUNNER" report "$RUN_ID")"

# The /dev/null exception ends at the device name; a similarly prefixed file is still a write.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell 'printf hidden >/dev/null.log' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# Comparison and arrow operators are not redirects; the shell still makes this exact editor list a floor.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell "awk '\$2 >= 5' data; node -e 'items.filter(x => x)'" "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"

# A tool this reader does not know is a tool whose targets it cannot name: agy's own image
# generation names only the image's LABEL, and a subagent it invokes edits under a transcript of
# its own. Neither may pass as a complete list, and the reason names the call so the next reader
# knows what to teach it.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_row "$AGY_TS" generate_image '{"ImageName": "asset", "AspectRatio": "1:1"}'
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: generate_image)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# A write whose target the transcript leaves empty is the same refusal.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
agy_row "$AGY_TS" write_to_file '{"CodeContent": "x"}' >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a write whose target it does not name)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# A resumed conversation APPENDS to the same transcript, so the file holds the calls of the runs
# before it — reported unfiltered this run claims a file an earlier one edited. The run's own start
# is the cut, and a call stamped in that very second is this run's.
clear_stub
export STUB_SLEEP=0.3
start_ok gemini
run_started=$(jq -r '.started_at' "$RUN_DIR/meta.json")
AGY_TS=$(agy_iso $((run_started - 7200)))
agy_write write_to_file "$agy_workdir/bin/agy-before-the-resume" >"$AGY_TRANSCRIPT"
AGY_TS=$(agy_iso "$run_started")
AGY_TS="${AGY_TS%Z}.123Z"
agy_write write_to_file "$agy_workdir/bin/agy-at-the-start" >>"$AGY_TRANSCRIPT"
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-at-the-start' <<<"$report"
unset STUB_SLEEP

# A syntactically valid mutating row with no usable time cannot be silently excluded from the run.
clear_stub
AGY_TS=not-a-timestamp
agy_write write_to_file "$agy_workdir/bin/agy-unparseable-time" >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a mutating context with an unparseable timestamp)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# A transcript jq cannot parse is unknown, never 0.
clear_stub
printf 'not json {\n' >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
assert grep -qx 'RUN-FILES: unknown (transcript unreadable)' <<<"$("$RUNNER" report "$RUN_ID")"

# No transcript at all — an agy too old to keep one, a conversation id the log never printed, a
# profile that is not where it was looked for — is unknown too, and never the workdir.
clear_stub
mv "$AGY_TRANSCRIPT" "$AGY_TRANSCRIPT.moved"
start_ok gemini
assert await_done
assert grep -qx 'RUN-FILES: unknown (no session transcript for gemini-conversation)' \
  <<<"$("$RUNNER" report "$RUN_ID")"
rm -f "$AGY_TRANSCRIPT.moved"

# Live-reproduced 2026-08-24: handed a workdir it does not trust, agy moved into the first
# --add-dir, worked THERE, and reported success — a green run over an untouched workdir, which is
# the one failure a launcher cannot see. Not "a path outside the workdir", which is ordinary: the
# signal is that NOTHING the run named is inside it. Said in the report and marked beside the run,
# and said even where the list itself is unanswerable — the escape is the louder of the two facts.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$WORK/extra/agy-went-elsewhere"
  agy_shell "printf x > $WORK/extra/and-wrote-here" "$WORK/extra"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qxF "WORKDIR-ESCAPE: the run named no path inside its own workdir; it worked in $WORK/extra/agy-went-elsewhere" \
  <<<"$report"
assert grep -q '^RUN-FILES: unknown' <<<"$report"
assert grep -qxF "$WORK/extra/agy-went-elsewhere" "$RUN_DIR/workdir-escape"
# The same sentence in the report `wait` prints the moment the run ends, which computes no list of
# its own: read only where a report was asked for, the loudest fact about the run reaches nobody.
assert grep -q '^WORKDIR-ESCAPE: ' "$WORK/wait.out"
"$RUNNER" _supervise "$RUN_DIR" >/dev/null 2>&1
assert test "$(grep -c . "$RUN_DIR/workdir-escape")" -eq 1
# Every escaped destination accumulated across attempts reaches the report once.
printf '%s\n' "$WORK/outside/agy-second-escape" >>"$RUN_DIR/workdir-escape"
report=$("$RUNNER" report "$RUN_ID")
assert test "$(grep -c '^WORKDIR-ESCAPE: ' <<<"$report")" -eq 2
# A run that touched its own workdir AND wrote outside it is doing its job: a worker reads
# ~/.claude and writes /tmp, and screamed about every time this line would say nothing at all.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_write write_to_file "$WORK/extra/agy-also-here"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
assert test ! -e "$RUN_DIR/workdir-escape"
assert test "$(grep -c '^WORKDIR-ESCAPE: ' <<<"$("$RUNNER" report "$RUN_ID")")" -eq 0

# codex names its edits twice over and neither alone is complete: the patch event holds the paths of
# a patch that applied, the call itself holds the patch TEXT (both gaps live-measured over the local
# rollout corpus), so the run answers with the union.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=codexfiles
CX_ROLLOUT="$CODEX_PROFILES_DIR/codexfiles/sessions/fixture/rollout-codex-session.jsonl"
mkdir -p "$(dirname "$CX_ROLLOUT")"
cx_row() { jq -cn --arg ts "$CX_TS" --argjson p "$1" '{timestamp: $ts, type: "response_item", payload: $p}'; }
cx_patch_event() { # target move-or-empty success
  cx_row "$(jq -cn --arg t "$1" --arg m "$2" --argjson ok "$3" \
    '{type: "patch_apply_end", success: $ok,
      changes: {($t): {type: "update", move_path: (if $m == "" then null else $m end)}}}')"
}
cx_exec() { cx_row "$(jq -cn --arg s "$1" '{type: "custom_tool_call", name: "exec", input: $s}')"; }
cx_exec_id() { cx_row "$(jq -cn --arg id "$1" --arg s "$2" '{type: "custom_tool_call", name: "exec", call_id: $id, input: $s}')"; }
cx_call() { cx_row "$(jq -cn --arg n "$1" --arg a "$2" '{type: "function_call", name: $n, arguments: $a}')"; }
cx_call_id() { cx_row "$(jq -cn --arg id "$1" --arg n "$2" --arg a "$3" '{type: "function_call", name: $n, call_id: $id, arguments: $a}')"; }
cx_output() { cx_row "$(jq -cn --arg id "$1" --arg out "$2" '{type: "custom_tool_call_output", call_id: $id, output: $out}')"; }
cx_workdir=$(cd "$WORK/workdir" && pwd -P)
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_patch_event "$cx_workdir/bin/cx-moved-from" "$cx_workdir/bin/cx-moved-to" true
  # A failed event cannot contribute either its changes map or the patch text in the call before it.
  cx_exec "const patch = \"*** Begin Patch\\n*** Update File: $cx_workdir/bin/cx-patch-text-failed\\n*** End Patch\"; await tools.apply_patch({\"input\": patch});"
  cx_patch_event "$cx_workdir/bin/cx-patch-text-failed" '' false
  cx_patch_event "$cx_workdir/bin/cx-patch-failed" '' false
  # A failed apply_patch has no patch_apply_end in current rollouts; its call result is the join.
  cx_exec_id cx-no-event-failed "const patch = \"*** Begin Patch\\n*** Update File: $cx_workdir/bin/cx-no-event-failed\\n*** End Patch\"; await tools.apply_patch({\"input\": patch});"
  cx_output cx-no-event-failed 'Script failed: apply_patch verification failed'
  # The patch text alone, for the runs whose event never arrived.
  cx_exec_id cx-no-event-success "const patch = \"*** Begin Patch\\n*** Update File: $cx_workdir/bin/cx-from-the-patch-text\\n*** End Patch\"; await tools.apply_patch({\"input\": patch});"
  cx_output cx-no-event-success 'Script completed'
  cx_call exec_command "{\"cmd\":\"git status --short\",\"workdir\":\"$cx_workdir\"}"
  # An empty stdin write is codex polling a long command for more output: it writes nothing, and
  # spoiled wholesale this one call left almost every real codex run unanswerable.
  cx_call write_stdin '{"session_id":1,"chars":"","yield_time_ms":1000}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 4' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-patched' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-moved-from' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-moved-to' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-from-the-patch-text' <<<"$report"
assert test "$(grep -c 'cx-patch-failed' <<<"$report")" -eq 0
assert test "$(grep -c 'cx-patch-text-failed' <<<"$report")" -eq 0
assert test "$(grep -c 'cx-no-event-failed' <<<"$report")" -eq 0
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"
assert grep -qx 'bin/cx-patched' "$RUN_DIR/files"

# A target still carrying an unexpanded `$name` or a backtick is text, not a path anybody can
# attribute: a run editing this suite's own fixtures patches their `*** Update File: $cx_workdir/…`
# headers, and the variable reached a live run's file list as a file (2026-08-24). The run says so
# instead of naming it.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_patch_event '$cx_workdir/bin/cx-from-a-variable' '' true
  cx_patch_event '${workdir}/bin/cx-from-a-brace' '' true
  cx_patch_event '`pwd`/bin/cx-from-a-backtick' '' true
  cx_patch_event "$cx_workdir/bin/cost"'$report.txt' '' true
  cx_patch_event "$cx_workdir/bin/cost"'$.txt' '' true
  cx_patch_event "$cx_workdir/bin/cost"'`report.txt' '' true
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 4' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-patched' <<<"$report"
assert grep -qxF 'RUN-FILE: bin/cost$report.txt' <<<"$report"
assert grep -qxF 'RUN-FILE: bin/cost$.txt' <<<"$report"
assert grep -qxF 'RUN-FILE: bin/cost`report.txt' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*cx-from-a-variable' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*cx-from-a-brace' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*cx-from-a-backtick' <<<"$report"
assert test "$(grep -v '^WORKDIR: \|^UNKNOWN: \|^PARTIAL: ' "$RUN_DIR/files" | grep -c 'cx-from-a-')" -eq 0
# The text itself, so a reader can see what the transcript could not resolve.
assert grep -qx 'RUN-FILES-PARTIAL: the run named a target the transcript cannot resolve: $cx_workdir/bin/cx-from-a-variable' <<<"$report"
assert grep -qx 'PARTIAL: the run named a target the transcript cannot resolve: $cx_workdir/bin/cx-from-a-variable' "$RUN_DIR/files"
# And it never reads as the whole list being unanswerable: the paths beside it are real.
assert_fails grep -q '^RUN-FILES: unknown' <<<"$report"

# The same guard for agy, which names its targets in its own log through the same reader.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=gemfiles
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_write write_to_file '$agy_workdir/bin/agy-from-a-variable'
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-written' <<<"$report"
assert grep -qx 'RUN-FILES-PARTIAL: the run named a target the transcript cannot resolve: $agy_workdir/bin/agy-from-a-variable' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*agy-from-a-variable' <<<"$report"
export PICK_RC=0 PICK_ACCOUNT=codexfiles

# Patch headers printed by a shell command are text, not editor targets.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_call exec_command "$(jq -cn --arg d "$cx_workdir" '{cmd:"printf %s *** Update File: bin/cx-mentioned-only",workdir:$d}')"
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert test "$(grep -c 'cx-mentioned-only' <<<"$report")" -eq 0

# CRLF patch headers produce the same path bytes as LF headers.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
printf -v crlf_patch '*** Begin Patch\r\n*** Update File: %s/bin/cx-crlf\r\n*** End Patch\r\n' "$cx_workdir"
{
  cx_call_id cx-crlf apply_patch "$crlf_patch"
  cx_output cx-crlf '{"output":"Success. Updated the following files","metadata":{"exit_code":0}}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILE: bin/cx-crlf' <<<"$report"
assert test "$(printf '%s' "$report" | tr -cd '\r' | wc -c | tr -d ' ')" -eq 0

# codex's shell arrives as JSON inside the harness call, and the write list reads it the same way
# whichever wrapper carries it — the JS `exec` dispatcher included.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_exec "const r = await tools.exec_command({\"cmd\":\"sed -i '' s/a/b/ bin/cx-through-the-shell\",\"workdir\":\"$cx_workdir\"}); text(r.output);"
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# Single quotes and backticks are string literals like any other, and a call spelled with them reads.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "await tools.exec_command({cmd:'git status',workdir:'$cx_workdir'}); await tools.exec_command({cmd:\`git status\`,workdir:\`$cx_workdir\`});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# An interpolated template literal names no command this reader can read, and fails closed.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "const verb = 'status'; const cmd = \`git \${verb}\`; await tools.exec_command({cmd, workdir:'$cx_workdir'});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: exec_command arguments)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# Shorthand resolves by NAME against the binding standing before the call, so an explicit value and a
# shorthand one interleaved each keep their own command; taking them in two blocks paired the second
# call with the first binding, and its `sed` spoiled a run that never wrote through the shell.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "var cmd = \"sed -i '' s/a/b/ bin/cx-not-this-one\"; await tools.exec_command({cmd: 'git status'}); var cmd = 'cat bin/cx-read-only'; await tools.exec_command({cmd});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# The same binding serves every shorthand call that follows it, however many there are.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "const cmd = 'git status --short'; await tools.exec_command({cmd}); await tools.exec_command({cmd});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# A shorthand name with no binding before it resolves to nothing at all.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "await tools.exec_command({cmd}); const cmd = 'git status';" >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: exec_command arguments)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# workdir resolves per call the same way: the shorthand of the second call is the directory bound
# before IT, and reading the first binding instead put every command outside the workdir.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "var workdir = '$WORK/extra'; await tools.exec_command({cmd: 'git status', workdir: '$WORK/extra'}); var workdir = '$cx_workdir'; await tools.exec_command({cmd: 'ls', workdir});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert test ! -e "$RUN_DIR/workdir-escape"
assert test "$(grep -c '^WORKDIR-ESCAPE: ' <<<"$("$RUNNER" report "$RUN_ID")")" -eq 0

# Tool-looking text in strings and comments is not an executed call.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec $'await tools.view_image({path:"fixture.png"}); const note = "tools.fs_write()"; // tools.js()' \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# Direct function-call arguments must be a JSON object, not prose containing field-shaped text.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_call exec_command "arbitrary text cmd: \"git status\", workdir: \"$cx_workdir\"" >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: exec_command arguments)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# Bare JavaScript object keys are the dominant exec_command rollout form and use the same shell rule.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_exec "const r = await tools.exec_command({cmd:\"sed -i '' s/a/b/ bin/cx-bare-shell\",workdir:\"$cx_workdir\"}); text(r.output);"
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# JavaScript shorthand arguments resolve through their string bindings.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "const cmd = \"git status --short\"; const workdir = \"$cx_workdir\"; await tools.exec_command({cmd, workdir, yield_time_ms:10000});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# Bytes typed into a shell a previous call started are read as a command line like any other.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_call write_stdin '{"session_id":1,"chars":"cat header > bin/cx-typed-in\n"}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# A tool this reader does not know: node's own REPL, a spawned subagent, an MCP server's write —
# each can put bytes on disk under no name the rollout carries.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_call js '{"code":"nodeRepl.write(1)"}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: js)' \
  <<<"$("$RUNNER" report "$RUN_ID")"
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_row '{"type": "mcp_tool_call_end", "invocation": {"server": "s", "tool": "fs.write"}}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: fs.write)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# A resumed codex session appends to the rollout it already had, and the cut is the run's own start.
clear_stub
export STUB_SLEEP=0.3
start_ok codex
run_started=$(jq -r '.started_at' "$RUN_DIR/meta.json")
CX_TS=$(iso $((run_started - 7200)))
cx_patch_event "$cx_workdir/bin/cx-before-the-resume" '' true >"$CX_ROLLOUT"
CX_TS=$(iso "$run_started")
cx_patch_event "$cx_workdir/bin/cx-at-the-start" '' true >>"$CX_ROLLOUT"
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-at-the-start' <<<"$report"
unset STUB_SLEEP

# Codex mutating rows with unusable timestamps fail closed just like Gemini rows.
clear_stub
CX_TS=not-a-timestamp
cx_patch_event "$cx_workdir/bin/cx-unparseable-time" '' true >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a mutating context with an unparseable timestamp)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# An unusable timestamp on a classified read-only call remains read-only.
clear_stub
CX_TS=not-a-timestamp
cx_call view_image '{"path":"fixture.png"}' >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

assert grep -E '^\| am \|.*record_workdir_escape.*workdir_escape_line' "$ROOT/docs/shared-invariants.md" >/dev/null

clear_stub
printf 'not json {\n' >"$CX_ROLLOUT"
start_ok codex
assert await_done
assert grep -qx 'RUN-FILES: unknown (transcript unreadable)' <<<"$("$RUNNER" report "$RUN_ID")"
rm -f "$CX_ROLLOUT"
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_ACCOUNT=recordacct

# A failed run wrote whatever it wrote before it died, and that is the launching chat's work too.
clear_stub
export STUB_CODE=9 STUB_ERROR='plain failure'
start_ok claudeb
assert await_done
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $(jq -r '.workdir' "$RUN_DIR/meta.json")"
unset STUB_CODE STUB_ERROR

# A record is written even when there is nothing to put in it — here, a run that could not reach its
# own workdir. No record at all is what an unfinished run looks like, and both readers take that
# absence for "this run wrote nothing", which is the one answer that is certainly wrong.
clear_stub
start_ok claudeb
assert await_done
jq '.workdir = null' "$RUN_DIR/meta.json" >"$WORK/meta.noworkdir" &&
  mv "$WORK/meta.noworkdir" "$RUN_DIR/meta.json"
rm -f "$RUN_DIR/files"
"$RUNNER" _supervise "$RUN_DIR" >/dev/null 2>&1
assert grep -qx 'UNKNOWN: the run recorded no workdir to resolve its files against' "$RUN_DIR/files"
assert test "$(grep -c '^WORKDIR: ' "$RUN_DIR/files")" -eq 0

# No chat to answer for it, or an id that cannot be compared as one: the run is nobody's rather than
# somebody's by accident.
clear_stub
unset CLAUDE_CODE_SESSION_ID
start_ok claudeb
assert await_done
assert test ! -e "$RUN_DIR/launcher"
export CLAUDE_CODE_SESSION_ID='../elsewhere'
clear_stub
start_ok claudeb
assert await_done
assert test ! -e "$RUN_DIR/launcher"
unset CLAUDE_CODE_SESSION_ID
# An id the vendor never printed is never guessed at either: no file at all, which reads as "this
# run's own journal entries cannot be found" rather than as somebody else's session.
clear_stub
export STUB_SESSION=''
start_ok claudeb
assert await_done
assert test ! -e "$RUN_DIR/worker-session"
unset STUB_SESSION

# A RESUMED run's worker session is known before its first token — the session keeps the id it
# already had — and the gate that prices a live run's worker work reads this file while the run is
# going. Written only when the attempt ends, everything that session journals in the meantime is
# priced as nobody's, which is the hole the pair on record exists to close.
clear_stub
export STUB_SESSION=resumed-session STUB_SLEEP=0.5
start_ok claudeb --account resumeacct --resume resumed-session
assert test "$(cat "$RUN_DIR/worker-session")" = resumed-session
assert await_done
# And once per id, however many times the record is rewritten over it.
assert test "$(grep -c . "$RUN_DIR/worker-session")" -eq 1
unset STUB_SESSION STUB_SLEEP

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

# A pinned run never consulted the pool, and its WALL line says so: worker agents relay these
# lines verbatim in place of describing routing themselves.
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export STUB_CODE=9 STUB_ERROR='usage limit reached'
start_ok claudeb --account pinacct
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: pinned account pinacct — pool not consulted' "$WORK/wait.out"
assert test "$(grep -c '^REROUTE:' "$WORK/wait.out")" -eq 0

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

# A pid is not a supervisor. The number is reused within a day on a busy machine, and whatever
# inherits it answers a signal probe exactly as the supervisor would — so the launch instant the
# record stamped is compared against the process's own start, the way the review hooks judge these
# same runs. A run reading "running" here while they read it as gone is a chat told to wait forever.
clear_stub
sleep 120 &
LIVE_SUPERVISOR=$!
RECYCLED_DIR="$WORKER_RUN_DIR/codex-9-9-bbbb"
mkdir -p "$RECYCLED_DIR"
: >"$RECYCLED_DIR/out"
: >"$RECYCLED_DIR/err"
jq -cn --argjson pid "$LIVE_SUPERVISOR" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"recycled",pid:$pid,started_at:$now,pid_started_at:1000}' \
  >"$RECYCLED_DIR/meta.json"
recycled_wait=$("$RUNNER" wait codex-9-9-bbbb --max 0)
assert grep -q '^STATUS: failed$' <<<"$recycled_wait"
assert grep -q '^EXIT: unknown$' <<<"$recycled_wait"
recycled_report=$("$RUNNER" report codex-9-9-bbbb)
assert grep -q '^STATUS: failed$' <<<"$recycled_report"
# The same live pid whose start MATCHES the stamp is the supervisor itself, and it is left alone.
jq -cn --argjson pid "$LIVE_SUPERVISOR" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"recycled",pid:$pid,started_at:$now,pid_started_at:$now}' \
  >"$RECYCLED_DIR/meta.json"
assert grep -q '^STATUS: running$' <<<"$("$RUNNER" report codex-9-9-bbbb)"
# A record written before the launch stamp existed has nothing to compare and keeps the old answer:
# every run started before that field went in would otherwise begin reading dead.
jq -cn --argjson pid "$LIVE_SUPERVISOR" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"legacy",pid:$pid,started_at:$now}' >"$RECYCLED_DIR/meta.json"
assert grep -q '^STATUS: running$' <<<"$("$RUNNER" report codex-9-9-bbbb)"
# A ps that cannot answer at all — a sandbox that hides other processes, a fork that failed —
# prints exactly what "no such process" prints, and reading that as death reports a live run
# failed. The signal probe, which this otherwise never uses, answers where ps cannot.
mkdir -p "$WORK/blind-ps"
printf '#!/bin/sh\nexit 1\n' >"$WORK/blind-ps/ps"
chmod +x "$WORK/blind-ps/ps"
jq -cn --argjson pid "$LIVE_SUPERVISOR" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"recycled",pid:$pid,started_at:$now,pid_started_at:1000}' \
  >"$RECYCLED_DIR/meta.json"
assert grep -q '^STATUS: running$' <<<"$(PATH="$WORK/blind-ps:$PATH" "$RUNNER" report codex-9-9-bbbb)"
# The pid that decides whether ps can answer at all cannot be our own: a sandbox that hides every
# process but this one still lists it, and that is exactly where a supervisor of another session
# reads gone.
mkdir -p "$WORK/self-ps"
printf '#!/bin/sh\ncase " $* " in *" -p 1 "*|*" -p %s "*) exit 0 ;; esac\necho "   01:00"\n' \
  "$LIVE_SUPERVISOR" >"$WORK/self-ps/ps"
chmod +x "$WORK/self-ps/ps"
assert grep -q '^STATUS: running$' <<<"$(PATH="$WORK/self-ps:$PATH" "$RUNNER" report codex-9-9-bbbb)"
# The probe still answers about the process: a pid nothing is behind reads gone, blind ps or not.
GONE_PID=$(sh -c 'echo $$')
while kill -0 "$GONE_PID" 2>/dev/null; do GONE_PID=$((GONE_PID + 1)); done
jq -cn --argjson pid "$GONE_PID" --argjson now "$(date +%s)" \
  '{vendor:"codex",account:"recycled",pid:$pid,started_at:$now,pid_started_at:$now}' \
  >"$RECYCLED_DIR/meta.json"
assert grep -q '^STATUS: failed$' <<<"$(PATH="$WORK/blind-ps:$PATH" "$RUNNER" report codex-9-9-bbbb)"
kill "$LIVE_SUPERVISOR" 2>/dev/null
wait "$LIVE_SUPERVISOR" 2>/dev/null
rm -rf "$RECYCLED_DIR"

# A wedged vendor CLI is killed at the deadline and the run turns terminal.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=wedged STUB_SLEEP=30 WORKER_RUN_DEADLINE=1
start_ok codex
unset STUB_SLEEP WORKER_RUN_DEADLINE
deadline_wait=$("$RUNNER" wait "$RUN_ID" --max 30)
assert grep -q '^STATUS: failed$' <<<"$deadline_wait"
assert grep -qx 'OUTCOME: CODEX_UNAVAILABLE' <<<"$deadline_wait"
# And says which watchdog did it: a bare 143 sends the reader hunting a vendor fault.
assert grep -q '^KILLED: deadline — the 1s ceiling' <<<"$deadline_wait"

# A worker that keeps writing is working, however long it takes: the idle watchdog reads the run's
# own files, and a suite that runs for minutes returns through them.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=busy STUB_HEARTBEAT=8 WORKER_RUN_IDLE_S=3 WORKER_RUN_DEADLINE=600
start_ok codex
unset STUB_HEARTBEAT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
busy_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: done$' <<<"$busy_wait"

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

# WORKER_RUN_IDLE_S=0 disarms the idle half alone: the same silent stub runs to its own end.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=patient STUB_SLEEP=3 WORKER_RUN_IDLE_S=0 WORKER_RUN_DEADLINE=600
start_ok codex
unset STUB_SLEEP WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
assert grep -q '^STATUS: done$' <<<"$("$RUNNER" wait "$RUN_ID" --max 60)"

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

# And a run whose EDITS are the only thing moving is working: the transcript is written once and
# never grows, `out` lands at exit, and the files under the workdir are what LAST-EDIT reads — so
# the watchdog reads them too, or a worker mid-edit dies at the idle window.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=picked STUB_SLEEP=14 STUB_TRANSCRIPT_SESSION=frozen-transcript \
  STUB_TRANSCRIPT_ACCOUNT=picked WORKER_RUN_IDLE_S=3 WORKER_RUN_DEADLINE=600
start_ok claudeb --workdir "$DIRT_REPO"
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
for editing in 1 2 3 4 5 6; do
  sleep 2
  printf 'edit %s\n' "$editing" >"$DIRT_REPO/bin/the-worker-is-mid-edit"
done
editing_wait=$("$RUNNER" wait "$RUN_ID" --max 60)
assert grep -q '^STATUS: done$' <<<"$editing_wait"
assert_fails grep -q '^KILLED: ' <<<"$editing_wait"
rm -f "$DIRT_REPO/bin/the-worker-is-mid-edit"

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
assert grep -q '^KILLED: signal TERM' <<<"$("$RUNNER" report "$RUN_ID")"
assert_fails kill -0 "$stub_pid"
# Not the wrapper alone: the CLI's own children go with its group, or the `sleep` here — a worker
# mid-edit in the real thing — outlives the run that was reported over.
for waiting in $(seq 1 60); do kill -0 "$stub_child" 2>/dev/null || break; sleep 0.1; done
assert_fails kill -0 "$stub_child"

# A brief with no first line cannot identify its run: RESUME/ATTACH are read off the top of it, and
# a discovery prefix taken from a blank line matches every transcript in the tree at once.
clear_stub
set_config 'claudeb_profile=pinned'
export PICK_RC=0 PICK_ACCOUNT=picked
printf '\nthe ask is on line two\n' >"$WORK/blank-first-brief"
printf '   \nthe ask is on line two\n' >"$WORK/spaces-first-brief"
: >"$WORK/empty-brief"
for bad_brief in blank-first-brief spaces-first-brief empty-brief; do
  rc=0
  "$RUNNER" start claudeb --brief "$WORK/$bad_brief" --workdir "$WORK/workdir" \
    >"$WORK/blank.out" 2>"$WORK/blank.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -q 'brief starts with a blank line' "$WORK/blank.err"
  assert_fails grep -q '^RUN: ' "$WORK/blank.out"
done
unset PICK_RC PICK_ACCOUNT

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
set_config 'gemini_model=flash38' 'gemini_effort=high'
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
# The supervisor's launch instant survives the reroute untouched while started_at is restamped:
# it is the clock liveness is judged by, and a restamped one reads a live rerouted run as dead.
assert jq -e '(.pid_started_at | type == "number") and .pid_started_at <= .started_at' \
  "$RUN_DIR/meta.json" >/dev/null
assert grep -qx -- '--account codex --claim' "$PICK_LOG"
assert grep -qx -- '--account codex --claim --exclude walled1' "$PICK_LOG"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert grep -q '^CODEX_HOME=.*/\.codex-profiles/rescue1$' "$CALL_LOG"
assert grep -qx 'REROUTE: walled on walled1 → continued on rescue1' "$WORK/wait.out"
assert grep -qx 'rescue1 · astra · high' "$RUN_DIR/tag"
# The relaunch starts the brief fresh on the new account.
assert_launched_brief "$STUB_DIR/codex.stdin"
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
assert grep -qx -- '--account codex --claim --exclude walled1' "$PICK_LOG"
assert grep -qx -- '--account codex --claim --exclude walled1,walled2' "$PICK_LOG"
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
assert grep -qx 'WALL: pool exhausted (walled: walled1, walled2)' "$WORK/wait.out"
assert meta_account_is walled2
assert jq -e '.walled_accounts == ["walled1"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'REROUTE: walled on walled1 → continued on walled2' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2

# A gemini rescue account must hold a usable geminib profile, the same check
# start_run applies: an unlisted answer ends the run instead of relaunching
# into a CLI error.
clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=high'
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

# A brief carrying a bench run's own `record` command is that run's triage, delegated: the bench is
# stamped with the supervisor's pid, which is what tells the Stop gate somebody is writing the
# report — and, once the pid is gone, that nobody is.
clear_stub
export PICK_ACCOUNT=deleg PICK_RC=0 STUB_SLEEP=3
DELEG_BENCHES="$HOME/.claude-profiles/.claudeb/worker-stats/benches"
mkdir -p "$DELEG_BENCHES/20260801T120000Z-abc123f" "$DELEG_BENCHES/20260801T130000Z-def4560"
cat >"$WORK/deleg-brief" <<'DELEGBRIEF'
STEP 1 — blind triage.
Record exactly with: review-bench record 20260801T120000Z-abc123f --no-corpus --verdicts /tmp/v.jsonl
No bench holds review-bench record 20260801T990000Z-fffffff, so nothing is stamped for it.
DELEGBRIEF
"$RUNNER" start codex --brief "$WORK/deleg-brief" --workdir "$WORK/workdir" \
  >"$WORK/deleg.out" 2>"$WORK/deleg.err" || fail "delegated start failed: $(<"$WORK/deleg.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/deleg.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/deleg.out")
assert test -s "$DELEG_BENCHES/20260801T120000Z-abc123f/delegated"
assert test "$(awk 'NR == 1 {print $1}' "$DELEG_BENCHES/20260801T120000Z-abc123f/delegated")" \
  = "$(jq -r '.pid' "$RUN_DIR/meta.json")"
assert kill -0 "$(awk 'NR == 1 {print $1}' "$DELEG_BENCHES/20260801T120000Z-abc123f/delegated")"
# The launch instant stands beside the pid, and it is the same one the record stamps: read on the
# pid alone the stamp silences an untriaged run for as long as whatever recycled the number lives
# (shared-invariants row ar).
assert test "$(awk 'NR == 1 {print $2}' "$DELEG_BENCHES/20260801T120000Z-abc123f/delegated")" \
  = "$(jq -r '.pid_started_at' "$RUN_DIR/meta.json")"
# The stamp answers for a run that exists: an id no bench holds is not a directory to invent, and a
# brief that delegates no triage stamps nothing at all.
assert test ! -e "$DELEG_BENCHES/20260801T990000Z-fffffff"
assert test ! -e "$DELEG_BENCHES/20260801T130000Z-def4560/delegated"
await_done || fail "the delegated run never finished"


# --- grok ----------------------------------------------------------------------------------------
# The brief rides a FILE (1.0.13 takes no prompt on argv), memory is off by env because the flag
# that did it is gone, and web search is off unless the brief asks: a worker inheriting the
# profile's memory carries another task's notes into this one.
clear_stub
set_config 'grok_model=auto' 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokacct
grok_workdir=$(cd "$WORK/workdir" && pwd -P)
start_ok grok
assert grep -qx 'TAG: grokacct · grok · high' "$WORK/start.out"
assert grep -qx 'grokacct · grok · high' "$RUN_DIR/tag"
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert grep -qx 'SESSION: 01a05811-7788-7d22-a9c9-c028072cbff5' "$WORK/wait.out"
assert meta_account_is grokacct
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = grok-4.6-build
# No turn cap by default: the wall-clock deadline is the runaway guard here as it is for claudeb,
# codex and gemini, and a cap borrowed from short reviewer cells ends an implementation brief the
# vendor was still serving.
assert test "$(jq -r 'has("max_turns")' "$RUN_DIR/meta.json")" = false
assert test "$(grep -c '^ARG=--max-turns$' "$CALL_LOG")" -eq 0
assert grep -qx 'GROK_MEMORY=0' "$CALL_LOG"
assert grep -qx 'ARG=--prompt-file' "$CALL_LOG"
assert grep -qxF "ARG=$RUN_DIR/brief.launch" "$CALL_LOG"
assert_launched_brief "$RUN_DIR/brief.launch"
assert grep -qx 'ARG=streaming-json' "$CALL_LOG"
assert grep -qx 'ARG=--always-approve' "$CALL_LOG"
assert grep -qx 'ARG=--no-subagents' "$CALL_LOG"
assert grep -qx 'ARG=--disable-web-search' "$CALL_LOG"
assert grep -qxF "ARG=$grok_workdir" "$CALL_LOG"
# `auto` means "whatever the account defaults to": a resolved id here pins a model nobody named.
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 0
# The answer arrives as `text` chunks; the raw NDJSON is the one shape a report cannot be read from.
assert grep -qx 'grok result' <<<"$("$RUNNER" report "$RUN_ID")"

clear_stub
set_config 'grok_model=grok-4.6' 'grok_effort=medium'
start_ok grok
assert grep -qx 'TAG: grokacct · grok · medium' "$WORK/start.out"
assert grep -qx 'grokacct · grok · medium' "$RUN_DIR/tag"
assert await_done
assert grep -qx 'ARG=-m' "$CALL_LOG"
assert grep -qx 'ARG=grok-4.6' "$CALL_LOG"
assert grep -qx 'ARG=--reasoning-effort' "$CALL_LOG"
assert grep -qx 'ARG=medium' "$CALL_LOG"

# `xhigh` exists on grok-4.6 alone and the CLI is what knows: it travels as asked instead of being
# clamped here, and only an effort no grok has is refused before launch.
clear_stub
start_ok grok --effort xhigh
assert await_done
assert grep -qx 'ARG=xhigh' "$CALL_LOG"
clear_stub
rc=0
"$RUNNER" start grok --brief "$WORK/brief" --effort ultra >"$WORK/grok-effort.out" 2>"$WORK/grok-effort.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/grok-effort.out"
assert test ! -s "$CALL_LOG"

clear_stub
set_config 'grok_effort=high'
export WORKER_RUN_GROK_MAX_TURNS=7
start_ok grok
assert await_done
assert grep -qx 'ARG=--max-turns' "$CALL_LOG"
assert grep -qx 'ARG=7' "$CALL_LOG"
assert test "$(jq -r '.max_turns' "$RUN_DIR/meta.json")" = 7
# A cap that is not a positive count is no cap at all — silently reading it as some default number
# would launch the run under a limit nobody asked for.
clear_stub
export WORKER_RUN_GROK_MAX_TURNS=nonsense
start_ok grok
assert await_done
assert test "$(grep -c '^ARG=--max-turns$' "$CALL_LOG")" -eq 0
assert test "$(jq -r 'has("max_turns")' "$RUN_DIR/meta.json")" = false
unset WORKER_RUN_GROK_MAX_TURNS

clear_stub
start_ok grok --web-search
assert await_done
assert test "$(grep -c '^ARG=--disable-web-search$' "$CALL_LOG")" -eq 0

# 1.0.13 grants directories through --cwd alone and attaches no images, so those flags are refused
# where a caller can still read the refusal instead of in a CLI error nobody sees.
for grok_flag in "--add-dir $WORK/extra" "--image $WORK/image.png"; do
  clear_stub
  rc=0
  # shellcheck disable=SC2086
  "$RUNNER" start grok --brief "$WORK/brief" $grok_flag >"$WORK/grok-flag.out" 2>"$WORK/grok-flag.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -q 'grok does not support --add-dir or --image' "$WORK/grok-flag.err"
  assert test ! -s "$CALL_LOG"
done

# A continued session rides `-r`: `-s` only ever CREATES and rejects an id that already exists, so
# handing it the session to continue ends the run before the brief is read.
clear_stub
export STUB_GROK_SESSION=grok-resumed-1
start_ok grok --account grokacct --resume grok-resumed-1
assert await_done
assert grep -qx 'ARG=-r' "$CALL_LOG"
assert grep -qx 'ARG=grok-resumed-1' "$CALL_LOG"
assert grep -qx 'SESSION: grok-resumed-1' "$WORK/wait.out"
assert test "$(grep -c '^ARG=-s$' "$CALL_LOG")" -eq 0
grok_collision_rc=0
CALL_LOG="$WORK/grok-collision-calls" "$WORK/bin/grokb" profile grokacct -s grok-resumed-1 \
  >"$WORK/grok-collision.out" 2>"$WORK/grok-collision.err" || grok_collision_rc=$?
assert test "$grok_collision_rc" -eq 1
assert grep -q 'already in use' "$WORK/grok-collision.err"
assert test ! -s "$WORK/grok-collision.out"

# grok's `main` is the real ~/.grok, which holds no worker login: with the picker gone and nothing
# pinned the run fails closed where codex and agy fall back to main.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=2 PICK_ACCOUNT=ignored
rc=0
"$RUNNER" start grok --brief "$WORK/brief" >"$WORK/grok-nomain.out" 2>"$WORK/grok-nomain.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/grok-nomain.out"
assert grep -q 'grok has no account to fall back on' "$WORK/grok-nomain.err"
assert test ! -s "$CALL_LOG"
assert test "$(grep -c 'main' "$WORK/grok-nomain.err")" -eq 0
clear_stub
set_config 'grok_effort=high' 'grok_profile=grokpin'
start_ok grok
assert meta_account_is grokpin
assert jq -e '.pinned == true' "$RUN_DIR/meta.json" >/dev/null
assert await_done

# A vendor the picker can read NOTHING about — no accounts, no usage snapshot — is not a walled one:
# its quota may be untouched, and this whole system exists so nothing reports a limit it has no data
# for. Live-caught on the grok leg before its quota reader landed: `no selectable grok account
# (unavailable)` came back as GROK_USAGE_LIMIT.
# The reasons are the ones worker-pick really prints: its whole vendor line sits inside the
# parens, so an unprefixed sentence would test only the stub (tests/test_worker_pick.sh pins
# `no selectable grok account (grok: unavailable)` on the producing side).
for pick_reason in 'grok: unavailable' 'grok: no quota data' \
                   'grok: pin gone absent → no selectable account | unavailable'; do
  clear_stub
  set_config 'grok_effort=high'
  export PICK_RC=3 PICK_ACCOUNT=ignored
  export PICK_STDERR="worker-pick: no selectable grok account ($pick_reason)"
  rc=0
  "$RUNNER" start grok --brief "$WORK/brief" >"$WORK/grok-nodata.out" 2>"$WORK/grok-nodata.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/grok-nodata.out"
  assert grep -q 'no usage data for grok' "$WORK/grok-nodata.err"
  assert test ! -s "$CALL_LOG"
  unset PICK_STDERR
done
# Any other reason at that exit is the wall it says it is.
clear_stub
export PICK_RC=3 PICK_ACCOUNT=ignored
export PICK_STDERR='worker-pick: no selectable grok account (grok: all walled)'
rc=0
"$RUNNER" start grok --brief "$WORK/brief" >"$WORK/grok-walled-reason.out" 2>&1 || rc=$?
assert test "$rc" -eq 3
assert grep -qx 'OUTCOME: GROK_USAGE_LIMIT' "$WORK/grok-walled-reason.out"
unset PICK_STDERR

# A vendor switched off for workers is a decision, not a wall: the sentence handed back must be the
# one every other vendor gives, vendor word apart, or a relay reads a closed role as an outage.
clear_stub
set_config 'gemini_workers=off' 'gemini_model=flash38' 'gemini_effort=high'
export PICK_RC=0 PICK_ACCOUNT=picked
printf 'picked\n' >"$STUB_DIR/gemini_profiles"
"$RUNNER" start gemini --brief "$WORK/brief" --account picked \
  >"$WORK/off-gemini.out" 2>"$WORK/off-gemini.err" || :
set_config 'grok_workers=off' 'grok_effort=high'
"$RUNNER" start grok --brief "$WORK/brief" --account picked \
  >"$WORK/off-grok.out" 2>"$WORK/off-grok.err" || :
grok_off=$(grep 'switched off for workers' "$WORK/off-grok.err")
assert test -n "$grok_off"
assert test "${grok_off/grok/gemini}" = "$(grep 'switched off for workers' "$WORK/off-gemini.err")"
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/off-grok.out"
assert test ! -s "$CALL_LOG"
clear_stub
set_config 'grok_workers=off' 'grok_profile=picked' 'grok_effort=high'
start_ok grok --account picked
assert meta_account_is picked
assert await_done

clear_stub
set_config 'grok_effort=high'
grok_pool=$(pool_dir_for grok)
mkdir -p "$grok_pool"
printf 'benched\n' >"$grok_pool/disabled"
rc=0
"$RUNNER" start grok --brief "$WORK/brief" --account benched >"$WORK/grok-pool.out" 2>"$WORK/grok-pool.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/grok-pool.out"
assert grep -q 'benched is out of the worker pool' "$WORK/grok-pool.err"
assert test ! -s "$CALL_LOG"
# The vendor pin is the one override, here as for every other vendor: it names an account on
# purpose, so the pool's consent wall steps aside for it.
set_config 'grok_profile=benched' 'grok_effort=high'
start_ok grok --account benched
assert meta_account_is benched
assert await_done
rm -f "$grok_pool/disabled"

# Only the PERSISTENT wording walls an account, and an unpinned run continues on the next one
# before the outcome ever reaches the caller.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=unused
printf 'gwall1\n' >"$STUB_DIR/grok_wall_accounts"
printf '%s\n' '0 gwall1' '0 grescue1' >"$STUB_DIR/pick_queue"
start_ok grok
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert meta_account_is grescue1
assert jq -e '.walled_accounts == ["gwall1"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'REROUTE: walled on gwall1 → continued on grescue1' "$WORK/wait.out"
assert grep -qx -- '--account grok --claim --exclude gwall1' "$PICK_LOG"
assert test "$(grep -c '^GROK_CALL$' "$CALL_LOG")" -eq 2

# ALL WALLED is the only way the usage-limit outcome still reaches the caller.
clear_stub
printf '%s\n' gwall1 gwall2 >"$STUB_DIR/grok_wall_accounts"
printf '%s\n' '0 gwall1' '0 gwall2' '3' >"$STUB_DIR/pick_queue"
start_ok grok
assert await_done
assert grep -q '^STATUS: failed$' "$WORK/wait.out"
assert grep -qx 'OUTCOME: GROK_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: pool exhausted (walled: gwall1, gwall2)' "$WORK/wait.out"
assert test "$(grep -c '^REROUTE: ' "$WORK/wait.out")" -eq 1

# A picker that already knows every grok account is walled ends `start` on the limit exit, and a pin
# is no way around a wall it never consulted.
clear_stub
set_config 'grok_effort=high' 'grok_profile=grokpin'
export PICK_RC=3 PICK_ACCOUNT=ignored
rc=0
"$RUNNER" start grok --brief "$WORK/brief" >"$WORK/grok-wall.out" 2>"$WORK/grok-wall.err" || rc=$?
assert test "$rc" -eq 3
assert grep -qx 'OUTCOME: GROK_USAGE_LIMIT' "$WORK/grok-wall.out"
assert test ! -s "$CALL_LOG"

# Every other persistent wording says the same thing, and the CLI's transient classes say something
# else entirely: xAI folds 429 and 5xx into the same internal rate-limit class as a real wall, so a
# bare "rate limit" here would report an exhausted plan on every bad minute.
for grok_spec in 'You have hit the rate limit for your plan:GROK_USAGE_LIMIT' \
  'error: subscription:free-usage-exhausted:GROK_USAGE_LIMIT' \
  'Your team has run out of credits:GROK_USAGE_LIMIT' \
  "You've reached your free Grok Build usage limit for now:GROK_USAGE_LIMIT" \
  'You’ve reached your free Grok Build usage limit for now:GROK_USAGE_LIMIT' \
  'request failed with status 402 Payment Required:GROK_USAGE_LIMIT' \
  'request failed with status 429 Too Many Requests:GROK_UNAVAILABLE' \
  'upstream returned status 503:GROK_UNAVAILABLE' \
  'rate limit exceeded, Retry-After: 30:GROK_UNAVAILABLE'; do
  grok_error=${grok_spec%:*}
  grok_outcome=${grok_spec##*:}
  clear_stub
  set_config 'grok_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=grokwording STUB_CODE=1 STUB_ERROR="$grok_error"
  start_ok grok
  assert await_done
  assert grep -qx "OUTCOME: $grok_outcome" "$WORK/wait.out"
  if [ "$grok_outcome" = GROK_UNAVAILABLE ]; then
    assert grep -qx 'REASON: transient — capacity weather, not a wall; the brief may be relaunched' \
      "$WORK/wait.out"
  fi
done

# An expired login needs a human and says so: relaunching it anywhere spends nothing but time.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokauth STUB_CODE=0
: >"$STUB_DIR/grok_auth"
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/wait.out"
assert grep -qx 'REASON: auth — the account needs a human login (grokb add <account>)' "$WORK/wait.out"
assert test "$(grep -c '^GROK_CALL$' "$CALL_LOG")" -eq 1

# A run that outran its turn budget answered nothing, but the vendor served every turn it was asked
# for: folded into GROK_UNAVAILABLE it reads as capacity weather, and the orchestrator reroutes a
# brief that will outrun the same budget wherever it lands next.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokturns
: >"$STUB_DIR/grok_max_turns"
export WORKER_RUN_GROK_MAX_TURNS=5 STUB_GROK_TURNS=5
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_MAX_TURNS' "$WORK/wait.out"
assert test "$(grep -c 'GROK_UNAVAILABLE' "$WORK/wait.out")" -eq 0
assert grep -qx 'REASON: max-turns — the brief outran --max-turns (5); the vendor answered fine, so relaunching it whole buys nothing' \
  "$WORK/wait.out"
assert test "$(grep -c '^GROK_CALL$' "$CALL_LOG")" -eq 1
assert grep -qx 'OUTCOME: GROK_MAX_TURNS' <<<"$("$RUNNER" report "$RUN_ID")"
unset WORKER_RUN_GROK_MAX_TURNS STUB_GROK_TURNS

# With no cap asked for, the cap that ended the run was the CLI's own, so the REASON names no number
# of ours — the outcome is still the vendor serving, not an outage.
clear_stub
: >"$STUB_DIR/grok_max_turns"
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_MAX_TURNS' "$WORK/wait.out"
assert grep -q '^REASON: max-turns — the brief outran --max-turns (?);' "$WORK/wait.out"

# A wall stated mid-run arrives as an `error` event on stdout, where every other vendor puts it on
# stderr: read on stderr alone this run reports an outage while the plan is actually exhausted.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokevent STUB_CODE=1 \
  STUB_GROK_ERROR_EVENT='You have hit the rate limit for your plan'
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_USAGE_LIMIT' "$WORK/wait.out"

# A failed run whose ANSWER discusses quotas is a plain failure: this repository's own briefs are
# about walls, and the scan reads stderr and the stream's `error` events, never the agent's text.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokchatty STUB_CODE=5 \
  STUB_GROK_ANSWER='You have hit the credit limit for your plan is what the docs say'
start_ok grok
assert await_done
assert grep -qx 'OUTCOME: GROK_UNAVAILABLE' "$WORK/wait.out"

# A tool the permission policy refused ends the run normally and is neither a wall nor a failure —
# but a thin result is unreadable without knowing something was refused.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokdenied
: >"$STUB_DIR/grok_denied"
start_ok grok
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME:' "$WORK/wait.out")" -eq 0
assert jq -e '.denied_tools == 1' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'DENIED-TOOLS: 1' <<<"$("$RUNNER" report "$RUN_ID")"
# `wait` is what a relay worker actually reads back, so the count has to survive that path too.
assert grep -qx 'DENIED-TOOLS: 1' "$WORK/wait.out"

# The agent quotes the refusal back in its own answer — live-observed, and the whole reason the count
# is read off the failed tool_call_update: the denial is stated once however often the text repeats it.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokdenied \
  STUB_GROK_ANSWER='I could not run it: Tool `run_terminal_command` was not executed: Denied by permission policy: deny rule on bash'
: >"$STUB_DIR/grok_denied"
start_ok grok
assert await_done
assert jq -e '.denied_tools == 1' "$RUN_DIR/meta.json" >/dev/null

# A run that only DISCUSSES a refusal was refused nothing: this repository's own briefs quote the
# sentence verbatim, and a stream scanned as text reports a denial no policy ever made.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokquoting \
  STUB_GROK_ANSWER='The gate answers with `Tool `x` was not executed: Denied by permission policy` when a deny rule matches'
start_ok grok
assert await_done
assert jq -e 'has("denied_tools") | not' "$RUN_DIR/meta.json" >/dev/null
assert test "$(grep -c '^DENIED-TOOLS:' <<<"$("$RUNNER" report "$RUN_ID")")" -eq 0
assert test "$(grep -c '^DENIED-TOOLS:' "$WORK/wait.out")" -eq 0

# grok names the files it wrote in its own session record, filed under the URL-encoded cwd it ran
# in: an id found by globbing can belong to a session from another directory entirely, so the
# session's own summary.json is checked against this run's workdir before a single path is claimed.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokfiles
GROK_SESSION=01a05811-7788-7d22-a9c9-c028072cbff5
grok_encode() { printf '%s' "$1" | jq -sRr @uri; }
GROK_UPDATES="$GROKB_PROFILES_DIR/grokfiles/sessions/$(grok_encode "$grok_workdir")/$GROK_SESSION/updates.jsonl"
mkdir -p "$(dirname "$GROK_UPDATES")"
grok_summary() { jq -n --arg d "$1" '{info: {cwd: $d}}' >"$(dirname "$GROK_UPDATES")/summary.json"; }
grok_call() { # id name kind read-only input-json
  jq -cn --argjson ts "$GROK_TS" --arg id "$1" --arg name "$2" --arg kind "$3" \
    --argjson ro "$4" --argjson input "$5" \
    '{timestamp: $ts, method: "session/update", params: {sessionId: "s", update: {
       sessionUpdate: "tool_call", toolCallId: $id, status: "in_progress", rawInput: $input,
       _meta: {"x.ai/tool": {name: $name, kind: $kind, read_only: $ro}}}}}'
}
grok_update() { # id status [current-dir]
  jq -cn --argjson ts "$GROK_TS" --arg id "$1" --arg status "$2" --arg dir "${3:-}" \
    '{timestamp: $ts, method: "session/update", params: {sessionId: "s", update: {
       sessionUpdate: "tool_call_update", toolCallId: $id, status: $status,
       rawOutput: (if $dir == "" then null else {current_dir: $dir} end)}}}'
}
GROK_TS=$(($(date +%s) + 60))
grok_summary "$grok_workdir"
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-written" '{file_path: $p}')"
  grok_update w1 completed
  grok_call e1 search_replace edit false "$(jq -cn --arg p "$WORK/outside/grok-absolute" '{file_path: $p}')"
  grok_update e1 completed
  grok_call r1 read_file read true "$(jq -cn --arg p "$grok_workdir/bin/grok-only-read" '{file_path: $p}')"
  grok_update r1 completed
  grok_call c1 run_terminal_command execute false "$(jq -cn '{command: "git status --short"}')"
  grok_update c1 completed "$grok_workdir"
} >"$GROK_UPDATES"
start_ok grok
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 2' <<<"$report"
assert grep -qx 'RUN-FILE: bin/grok-written' <<<"$report"
assert grep -qxF "RUN-FILE: $WORK/outside/grok-absolute" <<<"$report"
assert test "$(grep -c 'grok-only-read' <<<"$report")" -eq 0
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"
assert test ! -e "$RUN_DIR/workdir-escape"

# A refused write changed nothing and cannot make the successful call beside it review debt.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-kept" '{file_path: $p}')"
  grok_update w1 completed
  grok_call w2 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-refused" '{file_path: $p}')"
  grok_update w2 failed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/grok-kept' <<<"$report"
assert test "$(grep -c 'grok-refused' <<<"$report")" -eq 0

# A tool this reader cannot classify leaves the run unanswerable rather than short by one file, and
# an unknown tool is the ordinary case: the vendor keeps adding them.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-written" '{file_path: $p}')"
  grok_update w1 completed
  grok_call i1 image_gen other false '{}'
  grok_update i1 completed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: image_gen)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# The dispatcher tool answers for what it dispatched: a shell through it is a shell.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call u1 use_tool other false \
    "$(jq -cn '{tool_name: "bash", tool_input: {command: "printf x > out.txt"}}')"
  grok_update u1 completed "$grok_workdir"
} >"$GROK_UPDATES"
start_ok grok
assert await_done
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# A mutating row with no usable time cannot be silently dropped out of the run's window.
clear_stub
GROK_TS=null
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-timeless" '{file_path: $p}')"
  grok_update w1 completed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
assert grep -qx 'RUN-FILES: unknown (the transcript records a mutating context with an unparseable timestamp)' \
  <<<"$("$RUNNER" report "$RUN_ID")"

# A session record filed under another directory is not this run's, however well the id matches.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-elsewhere" '{file_path: $p}')"
  grok_update w1 completed
} >"$GROK_UPDATES"
grok_summary "$WORK/extra"
start_ok grok
assert await_done
assert grep -qx "RUN-FILES: unknown (no session transcript for $GROK_SESSION)" <<<"$("$RUNNER" report "$RUN_ID")"
# With no summary.json at all the encoded directory name is what answers, and it answers for this
# run: a record whose own cwd cannot be read is not a licence to claim it.
rm -f "$(dirname "$GROK_UPDATES")/summary.json"
clear_stub
start_ok grok
assert await_done
assert grep -qx 'RUN-FILE: bin/grok-elsewhere' <<<"$("$RUNNER" report "$RUN_ID")"

# No record at all is unknown too, and never the workdir.
clear_stub
mv "$GROK_UPDATES" "$GROK_UPDATES.moved"
start_ok grok
assert await_done
assert grep -qx "RUN-FILES: unknown (no session transcript for $GROK_SESSION)" <<<"$("$RUNNER" report "$RUN_ID")"
mv "$GROK_UPDATES.moved" "$GROK_UPDATES"

# Nothing inside the workdir at all is the one failure a launcher cannot see: a green run over an
# untouched directory.
clear_stub
GROK_TS=$(($(date +%s) + 60))
{
  grok_call w1 write write false "$(jq -cn --arg p "$WORK/extra/grok-went-elsewhere" '{file_path: $p}')"
  grok_update w1 completed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qxF "WORKDIR-ESCAPE: the run named no path inside its own workdir; it worked in $WORK/extra/grok-went-elsewhere" \
  <<<"$report"
assert grep -qxF "$WORK/extra/grok-went-elsewhere" "$RUN_DIR/workdir-escape"
rm -rf "$GROKB_PROFILES_DIR/grokfiles"

# A model no implementation worker may run is refused before the account is resolved: an explicit
# --model, the vendor's own `*_model=` key, and the default a missing key falls back to are three
# roads to the same list, and none of them may spend a run on a cheap model.
model_refused() { # vendor expected-offender [flags...]
  local vendor="$1" offender="$2" runs_before runs_after rc=0
  shift 2
  clear_stub
  runs_before=$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --workdir "$WORK/workdir" "$@" \
    >"$WORK/refuse.out" 2>"$WORK/refuse.err" || rc=$?
  runs_after=$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$rc" -eq 4 ] || { printf 'model_refused %s: exit %s\n' "$vendor" "$rc" >&2; return 1; }
  grep -qx 'OUTCOME: MODEL_REFUSED' "$WORK/refuse.out" || return 1
  grep -qF -- "$offender" "$WORK/refuse.err" || return 1
  # Nothing was spent: no pick, no vendor call, no run directory.
  [ ! -s "$PICK_LOG" ] || return 1
  [ ! -s "$CALL_LOG" ] || return 1
  [ "$runs_before" = "$runs_after" ]
}

set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' \
  'gemini_model=flash38' 'gemini_effort=high' 'grok_model=auto' 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=picked
printf 'picked\n' >"$STUB_DIR/gemini_profiles"
for spec in 'claudeb:sonnet' 'claudeb:haiku' 'claudeb:fable' 'codex:gpt-5.6-terra' \
            'codex:gpt-5.6-luna' 'codex:gpt-5.6' 'gemini:flash' 'gemini:flash36' \
            'gemini:flash35' 'gemini:flash37' 'gemini:pro' 'grok:grok-4.5'; do
  vendor=${spec%%:*}
  bad=${spec#*:}
  assert model_refused "$vendor" "$bad" --model "$bad"
done

# The same refusal when the toggle file carries it and no brief names a model at all.
for spec in 'claudeb:claudeb_model=sonnet' 'gemini:gemini_model=pro' 'grok:grok_model=grok-4.5'; do
  vendor=${spec%%:*}
  key=${spec#*:}
  set_config "$key" 'claudeb_effort=high' 'codex_effort=medium' 'gemini_effort=high' 'grok_effort=high'
  assert model_refused "$vendor" "${key#*=}"
done
# Codex has no key of its own: its default is whatever `config.toml` names, so a cheap model
# written there is refused exactly as one asked for by name.
set_config 'codex_effort=medium'
printf 'model = "gpt-5.6-terra"\n' >"$WORKER_RUN_CODEX_CONFIG"
assert model_refused codex gpt-5.6-terra
assert model_refused codex gpt-5.6-terra --model default
# A resume is not that run: `exec resume` keeps the session's own model and nothing sends the
# config's, so the file cannot refuse a resumed session — only a model the caller names can.
assert model_refused codex gpt-5.6-terra --account resumeacct --resume codex-resume --model gpt-5.6-terra
clear_stub
start_ok codex --account resumeacct --resume codex-resume
assert await_done
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 0
printf 'model = "gpt-6-astra"\n' >"$WORKER_RUN_CODEX_CONFIG"

# The allowed model of every vendor still launches, from the brief and from the file alike.
set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' \
  'gemini_model=flash38' 'gemini_effort=high' 'grok_model=auto' 'grok_effort=high'
clear_stub
start_ok claudeb --model opus
assert await_done
clear_stub
start_ok codex --model gpt-6-astra
assert await_done
clear_stub
start_ok gemini --account main --model flash38
assert meta_agy_is 'gemini-3.8-flash-high'
assert await_done
clear_stub
start_ok grok --model grok-4.6
assert await_done
clear_stub
start_ok grok --model auto
assert await_done

# --- One stamping point: every relay's rows reach the LAUNCHING chat ------------------------------
# The launcher is known at `start` and nowhere else: a fresh relay's own session id is not printed
# until its CLI exits, so the `worker-session` pairing beside the run record arrives AFTER every row
# the worker journaled while it ran, and each of those rows landed under an id no chat on this
# machine answers for (live run claudeb-1788388059-13078-3ffd, 2026-09-03). So the chat is stamped
# into the launched process's ENVIRONMENT, which every relay inherits whatever the vendor and
# whatever it goes on to launch — an image script, a pool-run cell, a nested worker-run — and the
# ledger writer reads it for the first hop of the launch chain.
#
# One case per relay type, each end to end: worker-run launches the stubbed CLI under a fake
# launching chat, a process inside that CLI edits a file in a git fixture and journals it exactly
# as the relay's own PostToolUse hook would, and the row that reaches the ledger must carry the
# LAUNCHER's id. Break the stamp for one relay and only that relay's case fails.
STAMP_HOOK="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/commit-journal.sh"
STAMP_LIB="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/lib/review-journal.sh"
if [ -r "$STAMP_HOOK" ] && [ -r "$STAMP_LIB" ]; then
  STAMP_REPO="$WORK/stamp-repo"
  mkdir -p "$STAMP_REPO"
  git -C "$STAMP_REPO" init -q -b main
  git -C "$STAMP_REPO" config user.email t@example.test
  git -C "$STAMP_REPO" config user.name t
  printf 'base\n' >"$STAMP_REPO/base.txt"
  git -C "$STAMP_REPO" add base.txt
  git -C "$STAMP_REPO" commit -q -m base
  STAMP_LEDGER=$(git -C "$STAMP_REPO" rev-parse --absolute-git-dir)/claude-commit-journal
  # The hook skips anything under TMPDIR and this suite's fixtures live there: it is pinned to a
  # directory no fixture sits under, or the paths asserted on here are silenced by where the suite
  # happens to run.
  STAMP_HOME="$WORK/stamp-home"
  mkdir -p "$STAMP_HOME" "$WORK/stamp-tmpdir"
  # The relay's own hook pair, both halves: the PreToolUse content snapshot the ledger writer
  # measures a link against, then the PostToolUse payload naming the file the relay just wrote.
  # `$1` is the worker's OWN session id — the only one a relay's hook ever knows.
  cat >"$STUB_DIR/relay_hook" <<STAMPEOF
#!/usr/bin/env bash
worker=\$1
tag=\$(cat "$STUB_DIR/relay_tag" 2>/dev/null) || tag=untagged
path="$STAMP_REPO/relay-\$tag.txt"
export HOME="$STAMP_HOME" TMPDIR="$WORK/stamp-tmpdir" WORKER_RUN_DIR="$WORKER_RUN_DIR"
export GIT_CEILING_DIRECTORIES="$WORK"
. "$STAMP_LIB" || exit 0
rj_snapshot_content "\$worker" "call-\$tag" "$STAMP_REPO" "" "relay-\$tag.txt"
printf 'written by %s\n' "\$worker" >"\$path"
jq -cn --arg s "\$worker" --arg p "\$path" --arg c "$STAMP_REPO" --arg call "call-\$tag" \
  '{hook_event_name:"PostToolUse",tool_name:"Write",cwd:\$c,session_id:\$s,tool_use_id:\$call,
    tool_input:{file_path:\$p}}' |
  bash "$STAMP_HOOK" >"$STUB_DIR/relay_hook_out" 2>"$STUB_DIR/relay_hook_err"
printf '%s\n' "\$?" >"$STUB_DIR/relay_hook_rc"
STAMPEOF
  chmod +x "$STUB_DIR/relay_hook"
  # Who owns a path in the ledger, one id per line.
  stamp_owners() { # tag
    tr '\0' '\n' <"$STAMP_LEDGER" 2>/dev/null |
      awk -F'\t' -v p="relay-$1.txt" '$NF == p { print $1 }' | sort -u
  }
  stamp_relay() { # tag vendor [start-args...]
    local tag="$1" vendor="$2" keep_session="${STUB_SESSION-}"
    shift 2
    printf '%s\n' "$tag" >"$STUB_DIR/relay_tag"
    rm -f "$STUB_DIR/relay_hook_rc" "$STUB_DIR/relay_hook_err"
    # `clear_stub` unsets STUB_SESSION, and the re-attach case is exactly the one that sets it:
    # cleared, the run records the stub default and the case proves nothing about a resumed id.
    clear_stub
    [ -z "$keep_session" ] || export STUB_SESSION="$keep_session"
    export CLAUDE_CODE_SESSION_ID="stamp-chat-$tag"
    start_ok "$vendor" "$@"
    await_done || fail "the $vendor stamping run never finished"
    unset CLAUDE_CODE_SESSION_ID
    assert test "$(cat "$STUB_DIR/relay_hook_rc" 2>/dev/null)" = 0
    assert grep -qx "stamp-chat-$tag" <<<"$(stamp_owners "$tag")"
    # The worker's own id stays on its own row beside the launcher's: the gate inside the live
    # worker asks about the work under that id, and answered `other` it could not settle what it
    # had just done.
    assert test "$(stamp_owners "$tag" | grep -c .)" -eq 2
  }
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' \
    'gemini_model=flash38' 'gemini_effort=high' 'grok_model=auto' 'grok_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=stampacct
  stamp_relay claudeb claudeb
  stamp_relay codex codex
  stamp_relay gemini gemini --account main
  stamp_relay grok grok
  # A RE-ATTACHED run: a `--resume` launch repeats the id the worker session already had, so its
  # rows carry the launcher from the run's first token rather than from the moment it ends — which
  # is the whole window the run record could never answer for.
  export STUB_SESSION=reattached-session
  stamp_relay reattach claudeb --account stampacct --resume reattached-session
  assert grep -qx 'reattached-session' "$RUN_DIR/worker-session"
  # The stamp the LIVE worker writes carries the resumed id, not the id a fresh launch would have
  # minted: this is the only case where the two differ, and the ledger is read by that id.
  assert grep -qx 'reattached-session' <<<"$(stamp_owners reattach)"
  unset STUB_SESSION
  # An IMAGE SCRIPT and a POOL-RUN CELL are processes a relay starts, not relays of their own: they
  # journal through whoever ran them, so the one thing they must not do is drop the stamp. Stood in
  # for here by a bare shell — which is what both are to the environment — launched with the
  # environment worker-run exported.
  printf '%s\n' image-cell >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( export CLAUDE_LAUNCHER_SESSION=stamp-chat-image-cell CLAUDE_CODE_SESSION_ID=some-worker
    "$STUB_DIR/relay_hook" nested-image-worker )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 0
  assert grep -qx 'stamp-chat-image-cell' <<<"$(stamp_owners image-cell)"
  # And the stamp is read for the row of the session the process IS and for no other. A hook that
  # SWEEPS a finished run of another chat writes that run's rows under ITS launcher, and read
  # against this process's environment instead they would land under the sweeper's own chat — one
  # chat handed a waiver over a stranger's work.
  swept=$WORKER_RUN_DIR/claudeb-swept-by-a-worker
  mkdir -p "$swept"
  printf 'sweep-other-chat\n' >"$swept/launcher"
  printf 'written by nobody here\n' >"$STAMP_REPO/relay-swept.txt"
  printf '%s\n' "WORKDIR: $STAMP_REPO" relay-swept.txt >"$swept/files"
  printf -- '-\t%s\trelay-swept.txt\n' \
    "$(git -C "$STAMP_REPO" hash-object -w "$STAMP_REPO/relay-swept.txt")" >"$swept/produced"
  printf '0\n' >"$swept/exit_code"
  printf '%s\n' sweeper >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( export CLAUDE_LAUNCHER_SESSION=stamp-chat-sweeper CLAUDEB_WORKER=1
    "$STUB_DIR/relay_hook" a-sweeping-worker )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 0
  assert grep -qx 'sweep-other-chat' <<<"$(stamp_owners swept)"
  assert_fails grep -qx 'stamp-chat-sweeper' <<<"$(stamp_owners swept)"
  # Its own row, made in the same call, still reaches its own launcher.
  assert grep -qx 'stamp-chat-sweeper' <<<"$(stamp_owners sweeper)"
  rm -rf "$swept"
  # An orphan a chat launched is impossible and LOUD. A relay worker whose stamp is missing — no
  # environment, no run record pairing its session with a launcher — writes a row no chat answers
  # for, and that is the one ledger state nothing downstream repairs: the content is priced as owed
  # by nobody for as long as it stands. So the hook says it on stderr under a NON-ZERO exit, the one
  # channel a PostToolUse reaches a model through, on every such call rather than once a session.
  printf '%s\n' loud >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( unset CLAUDE_LAUNCHER_SESSION
    export CLAUDEB_WORKER=1
    "$STUB_DIR/relay_hook" unstamped-worker )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 2
  assert grep -q 'no chat above it' "$STUB_DIR/relay_hook_err"
  assert grep -q 'the launcher stamp is missing' "$STUB_DIR/relay_hook_err"
  # The row is still written — a fact stays a fact, and the fault belongs in front of a model
  # rather than in a number — under the worker's own id and under no chat.
  assert grep -qx 'unstamped-worker' <<<"$(stamp_owners loud)"
  assert test "$(stamp_owners loud | grep -c .)" -eq 1
  # And a chat's own shell is no relay worker: the same missing stamp there is Egor editing by hand,
  # which owns its rows outright and is nobody's fault to report.
  printf '%s\n' quiet >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( unset CLAUDE_LAUNCHER_SESSION CLAUDEB_WORKER GROK_WORKER
    "$STUB_DIR/relay_hook" a-chat-of-its-own )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 0
  assert grep -qx 'a-chat-of-its-own' <<<"$(stamp_owners quiet)"
  rm -f "$STUB_DIR/relay_hook" "$STUB_DIR/relay_tag"
  unset PICK_RC PICK_ACCOUNT
  clear_stub
else
  fail "the ledger writer of ../claude-setup is unreadable (set CLAUDE_SETUP_ROOT)"
fi

echo "PASS: $asserts asserts; worker-run detaches vendor CLIs, preserves live runs across bounded waits, resolves accounts and model knobs, reroutes an unpinned run off a walled account until every candidate is walled, retries only documented compatibility failures, records beside each run the chat that launched it, the worker session it ran under and the files it wrote — read for claudeb, codex, agy and grok alike out of that vendor's own transcript, the same list its report prints, unioned across every attempt, an UNKNOWN line where a mutating call names no target, a shell command writes, a tool is one this reader cannot classify or the workdir leaves the list unanswerable, a PARTIAL one where the run also worked through the shell or named a target still carrying an unexpanded shell variable, and a WORKDIR-ESCAPE line beside a run that named no path inside its own workdir at all, written for a failed run and for a run that never reached its workdir too, and for no chat at all when none can be named — answers a still-running wait with LAST-EDIT and CPU-SECONDS beside the stdout byte counts that say nothing about liveness, stamps the bench of a triage its brief delegates with the supervisor's pid and its launch instant, records the live vendor CLI's own pid beside the supervisor's for the memory guard to root its kill at, hands every launch the preamble's answer to an exit 137, ends a wait over an incomplete listing with the UNNAMED line naming every path in the run's window no record answers for — spelled as \`claim\` takes them while they are few enough to read, replaced past that cap by the exact count and the record holding the list, and never printed for a run whose own list is complete — takes that answer from the LAUNCHING chat alone and only once the run has ended, refusing a foreign chat, a live run and any path outside the run's workdir without applying half a claim, writes the claimed paths in as ordinary listing rows, drops them from the dirt record without adding one it never held, keeps the PARTIAL/UNKNOWN caveat standing until \`--complete\` says the list is whole, and reports terminal outcomes, and refuses every model outside the per-vendor allowed list — from the brief, the toggle file or the codex config alike — with \`OUTCOME: MODEL_REFUSED\` before an account is resolved or a run directory exists"
