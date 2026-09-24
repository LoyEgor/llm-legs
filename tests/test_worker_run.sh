#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/bin/worker-run"
WORK="$(mktemp -d)"
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
. "$ROOT/tests/fixtures/codexb-models.sh"
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
export CLAUDEB_DIR="$HOME/.claude-profiles/.claudeb"
export XDG_CACHE_HOME="$WORK/cache"
export WORKER_RUN_ALLOW_DUPLICATE=1
export WORKER_RUN_DIR="$WORK/runs"
export WORKER_WALLS_DIR="$WORK/walls"
export CHAT_PINS_DIR="$WORK/chat-pins"
export WORKER_RUN_CONFIG_FILE="$WORK/worker-model"
# A worker harness exports WORKER_PICK_CONFIG_FILE at Egor's real toggle, and worker-run reads the
# pin through it: inherited, every case here would be judged on whatever he has pinned today.
unset WORKER_PICK_CONFIG_FILE
# Inherited from a worker harness, the launcher would be that harness's chat in every case below.
unset CLAUDE_LAUNCHER_SESSION
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
mkdir -p "$HOME" "$WORK/bin" "$WORKER_RUN_DIR" "$WORKER_WALLS_DIR" "$STUB_DIR" "$WORK/workdir" "$WORK/extra"
export PATH="$WORK/bin:$PATH"
export REPORT_BUS_LOG="$WORK/report-posts.jsonl"
: >"$REPORT_BUS_LOG"
cat >"$WORK/bin/report-bus" <<'REPORTBUS'
#!/usr/bin/env bash
body=$(cat)
jq -cn --arg body "$body" --args '{argv:$ARGS.positional,body:$body}' -- "$@" >>"$REPORT_BUS_LOG"
REPORTBUS
chmod +x "$WORK/bin/report-bus"
cat >"$WORK/bin/review-bench" <<'REVIEWBENCH'
#!/usr/bin/env bash
[ -z "${REVIEW_BENCH_STUB_FAIL:-}" ] || exit 3
[ -n "${REVIEW_BENCH_STUB_EMPTY:-}" ] || printf 'STUB FIX RULE %s\nwrite verdicts.jsonl rows\n' "$*"
REVIEWBENCH
chmod +x "$WORK/bin/review-bench"
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
# The anchors store's two names for the same run: who owes what this worker writes, and where the
# worker's own verdict rows go.
printf '%s\n' "${CLAUDE_DEBT_OWNER-}" >"$STUB_DIR/debt_owner_env"
printf '%s\n' "${WORKER_RUN_RECORD-}" >"$STUB_DIR/run_record_env"
# What a relay's own journal hook is: a process inside the launched CLI, reaching the launching
# chat through the environment and through nothing else.
[ ! -x "$STUB_DIR/relay_hook" ] || "$STUB_DIR/relay_hook" "${STUB_SESSION-claude-session}"
# The real CLI refuses an empty stdin in --print mode; the stub must too, or a
# lost brief (background stdin defaulting to /dev/null) passes the suite.
input=$(cat)
printf '%s\n' "$input" >"$STUB_DIR/claudeb.stdin"
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
  if [ -n "${STUB_EDIT_PATH:-}" ]; then
    jq -cn --arg path "$STUB_EDIT_PATH" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{timestamp:$timestamp,type:"assistant",message:{content:[{type:"tool_use",name:"Edit",input:{file_path:$path}}]}}' \
      >>"$transcript_dir/$transcript_name.jsonl"
  fi
fi
if [ -n "${STUB_TRANSCRIPT_GROW:-}" ] && [ -n "${STUB_TRANSCRIPT_SESSION:-}" ]; then
  # A working claudeb writes NOTHING to stdout until its very last line; the transcript growing is
  # the whole evidence that the run is alive.
  grown=0
  while [ "$grown" -lt "${STUB_SLEEP:-0}" ]; do
    sleep 1
    grown=$((grown + 1))
    jq -cn --arg n "$grown" \
      '{type:"assistant",message:{content:[{type:"text",text:("turn " + $n)}]}}' \
      >>"$transcript_dir/$transcript_name.jsonl"
  done
else
  [ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
fi
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
  jq -cn --arg session "${STUB_SESSION-claude-session}" --argjson usage "${STUB_MODEL_USAGE:-null}" \
    '{result:"claudeb result",session_id:$session,total_cost_usd:1.25} + if $usage then {modelUsage:$usage} else {} end'
fi
exit "${STUB_CODE:-0}"
EOF

cat >"$WORK/bin/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'codex-cli 0.156.1\n'; exit 0 ;;
  debug) exit 0 ;;
esac
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
  printf '%s\n' "${STUB_WALL_TEXT:-ERROR: You have hit your usage limit.}" >&2
  if [ -n "${STUB_WALL_ECHO:-}" ]; then
    for _ in $(seq "$STUB_WALL_ECHO"); do sleep 1; printf 'still reading files\n' >&2; done
    printf '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}\n'
    exit 0
  fi
  if [ -n "${STUB_WALL_SLEEP:-}" ]; then
    printf '%s\n' "$$" >"$STUB_DIR/wall.pid"
    sleep "$STUB_WALL_SLEEP" &
    printf '%s\n' "$!" >"$STUB_DIR/wall.child.pid"
    wait $!
  fi
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
  [ -z "${STUB_PICK_WALL:-}" ] || printf '%s\n' 'worker-pick: no selectable codex account (main WALLED)' >&2
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
  if [ -r "$STUB_DIR/codex_rollout" ]; then
    mkdir -p "${CODEX_HOME:-$HOME/.codex}/sessions/2026/09/23"
    cp "$STUB_DIR/codex_rollout" "${CODEX_HOME:-$HOME/.codex}/sessions/2026/09/23/rollout-2026-09-23T00-00-00-codex-session.jsonl"
  fi
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
[ -z "${STUB_GEMINI_LABEL:-}" ] ||
  printf 'model_config_manager.go:327] Propagating selected model override to backend: label="%s"\n' "$STUB_GEMINI_LABEL" >>"$log"
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
  unset STUB_SLEEP STUB_HEARTBEAT STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT STUB_TRANSCRIPT_GROW \
    STUB_EDIT_PATH STUB_PICK_WALL \
    STUB_ERROR STUB_CODE STUB_STDOUT STUB_GEMINI_LABEL STUB_SESSION STUB_GROK_SESSION STUB_GROK_MODEL \
    STUB_GROK_ANSWER STUB_GROK_ERROR_EVENT STUB_GROK_TURNS STUB_MODEL_USAGE
  rm -f "$STUB_DIR/claudeb_drop_effort" "$STUB_DIR/codex_trusted" "$STUB_DIR/codex.stdin" \
    "$STUB_DIR/codex_bad_model" "$STUB_DIR/codex_bad_model_always" "$STUB_DIR/codex_noise" \
    "$STUB_DIR/codex_noise_deep" "$STUB_DIR/codex_phrase_deep" "$STUB_DIR/codex_append_target" \
    "$STUB_DIR/wall_accounts" "$STUB_DIR/pick_queue" "$STUB_DIR/grok_wall_accounts" \
    "$STUB_DIR/grok_auth" "$STUB_DIR/grok_transient" "$STUB_DIR/grok_denied" \
    "$STUB_DIR/grok_max_turns" "$STUB_DIR/grok_cancelled" "$STUB_DIR/grok_cancelled_worked" \
    "$STUB_DIR/codex.pid" "$STUB_DIR/codex.child.pid"
  rm -f "$WORKER_WALLS_DIR"/*
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

effort_refused() {
  local vendor="$1" model="$2" effort="$3" rc=0 runs_before
  shift 3
  clear_stub
  runs_before=$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
  "$RUNNER" start "$vendor" --brief "$WORK/brief" --model "$model" --effort "$effort" "$@" \
    >"$WORK/effort.out" 2>"$WORK/effort.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/effort.out"
  assert grep -Fq "$vendor model $model does not allow effort $effort" "$WORK/effort.err"
  assert test ! -s "$CALL_LOG"
  assert test ! -s "$PICK_LOG"
  assert test "$runs_before" = "$(find "$WORKER_RUN_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  assert test "$(tail -n1 "$WORKER_RUN_DIR/prelaunch.jsonl" | jq -r '"\(.outcome) \(.vendor) \(.ts | type)"')" = \
    "EFFORT_REFUSED $vendor number"
}

model_effort_tests() {
  local spec vendor model effort
  set_config
  export PICK_RC=0 PICK_ACCOUNT=picked
  for spec in codex:astra:low codex:sol:medium claudeb:opus:high claudeb:fable:low gemini:flash38:high grok:auto:high grok:grok-4.6:high; do
    vendor=${spec%%:*}; model=${spec#*:}; effort=${model##*:}; model=${model%:*}
    clear_stub
    start_ok "$vendor" --model "$model" --account main
    assert await_done
    assert test "$(jq -r '.model' "$RUN_DIR/meta.json")" = "$model"
    assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = "$effort"
  done
  assert test "$(jq -r '.model_id' "$RUN_DIR/meta.json")" = null
  clear_stub
  start_ok codex --account main
  assert await_done
  assert grep -qx 'ARG=model_reasoning_effort=low' "$CALL_LOG"
  assert test "$(jq -r '[.model, .model_id] | join(" ")' "$RUN_DIR/meta.json")" = 'astra gpt-6.1-astra'
  assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
  assert grep -qx 'main · astra · low' "$RUN_DIR/tag"
  set_config 'codex_effort=high'
  clear_stub
  start_ok codex --account main
  assert await_done
  assert grep -qx 'ARG=model_reasoning_effort=high' "$CALL_LOG"
  for spec in codex:astra:xhigh codex:gpt-5.6-sol:low claudeb:fable:max claudeb:opus:low; do
    vendor=${spec%%:*}; model=${spec#*:}; effort=${model##*:}; model=${model%:*}
    clear_stub
    start_ok "$vendor" --model "$model" --effort "$effort" --account main
    assert await_done
    assert grep -qx "ARG=$([ "$model" = astra ] && printf gpt-6.1-astra || printf %s "$model")" "$CALL_LOG"
    assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = "$effort"
    if [ "$model" = gpt-5.6-sol ]; then
      assert grep -qx 'ARG=-m' "$CALL_LOG"
      assert grep -qx 'ARG=model_reasoning_effort=low' "$CALL_LOG"
      assert grep -qx 'main · sol · low' "$RUN_DIR/tag"
    fi
  done
  set_config 'claudeb_model=fable'
  clear_stub
  start_ok claudeb --account main
  assert await_done
  assert grep -qx 'ARG=fable' "$CALL_LOG"
  assert test "$(jq -r '.effort' "$RUN_DIR/meta.json")" = low
  # `gemini:flash38:ultra` and not `xhigh`: every effort the table knows is RAISED to high on a
  # Gemini leg, so only a word that is no effort at all can be refused there.
  for spec in codex:astra:max codex:gpt-5.6-sol:max claudeb:opus:ultra gemini:flash38:ultra grok:auto:low grok:grok-4.6:medium; do
    vendor=${spec%%:*}; model=${spec#*:}; effort=${model##*:}; model=${model%:*}
    effort_refused "$vendor" "$model" "$effort"
  done
  effort_refused codex astra max --account main --resume codex-resume
  effort_refused claudeb opus ultra --account main --resume claude-resume
  effort_refused gemini flash38 ultra --account main --resume gemini-resume
  effort_refused grok auto low --account main --resume grok-resume
  set_config 'codex_effort=max'
  clear_stub
  rc=0
  "$RUNNER" start codex --brief "$WORK/brief" >"$WORK/effort.out" 2>&1 || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/effort.out"
  assert test ! -s "$PICK_LOG"
  assert test ! -s "$CALL_LOG"
  clear_stub
  start_ok codex --account main --resume codex-resume
  assert await_done
  assert_fails grep -q '^ARG=model_reasoning_effort=' "$CALL_LOG"
  effort_refused codex astra max --account main --resume codex-resume
  set_config
  clear_stub
}

reliability_cleanup() {
  local meta pid
  for meta in "$WORK/reliability-runs"/*/meta.json; do
    [ -f "$meta" ] && [ ! -e "${meta%/meta.json}/exit_code" ] || continue
    while IFS= read -r pid; do
      [ "$pid" -gt 1 ] || continue
      if [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ]; then
        kill -TERM -- "-$pid" 2>/dev/null || :
      fi
      kill -TERM "$pid" 2>/dev/null || :
    done < <(jq -r '.cli_pid // 0, .pid // 0' "$meta")
  done
}
trap 'reliability_cleanup; rm -rf "$WORK"' EXIT

reliability_case() { [ -z "${WORKER_RUN_TEST_CASE:-}" ] || [ "$WORKER_RUN_TEST_CASE" = "$1" ]; }
reliability_tests() {
  local WORKER_RUN_DIR="$WORK/reliability-runs" WORKER_RUN_IDLE_S=0 WORKER_RUN_SILENT_S=0 WORKER_RUN_WALL_SETTLE_S=0
  local WORKER_RUN_DEADLINE=10 CLAUDE_CODE_SESSION_ID=reliability-launcher
  local PICK_RC=0 PICK_ACCOUNT=rescue STUB_WALL_SLEEP=8 STUB_WALL_TEXT
  local old_id old_dir result rc started cli_pid child_pid fixture live_pid
  export WORKER_RUN_DIR WORKER_RUN_IDLE_S WORKER_RUN_SILENT_S WORKER_RUN_DEADLINE WORKER_RUN_WALL_SETTLE_S
  export CLAUDE_CODE_SESSION_ID PICK_RC PICK_ACCOUNT STUB_WALL_SLEEP
  mkdir -p "$WORKER_RUN_DIR"
  set_config 'codex_effort=high'

  if reliability_case R1; then
    clear_stub
    fixture="$WORK/live-edits"
    mkdir -p "$fixture"
    git -C "$fixture" init -q
    STUB_SLEEP=7 STUB_SESSION=live-edits STUB_TRANSCRIPT_SESSION=live-edits STUB_TRANSCRIPT_ACCOUNT=edits \
      STUB_EDIT_PATH=owned WORKER_RUN_IDLE_S=3 start_ok claudeb --account edits --workdir "$fixture"
    for started in 1 2 3 4 5 6; do
      printf '%s\n' "$started" >"$fixture/owned"
      assert test ! -e "$RUN_DIR/files"
      sleep 1
    done
    result=$("$RUNNER" wait "$RUN_ID" --max 10)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert test ! -e "$RUN_DIR/killed"
    assert grep -qx owned "$RUN_DIR/files"
  fi

  if reliability_case R2; then
    (
      eval "$(sed -n '/^record_run_wall() {/,/^}/p' "$RUNNER")"
      . "$ROOT/share/worker-walls.sh"
      worker_model_clear_walled_pin() { :; }
      date() { printf '%s\n' "$(cat "$WORK/wall-clock")"; }
      fixture="$WORK/wall-epoch"
      mkdir -p "$fixture"
      printf '{"account":"epoch"}\n' >"$fixture/meta.json"
      printf '1\n' >"$fixture/attempt"
      : >"$fixture/out"
      for text in 'resets in 2 hours' ''; do
        printf '%s\n' "$text" >"$fixture/err"
        printf '1000000\n' >"$WORK/wall-clock"
        record_run_wall "$fixture" codex
        epoch=$(sed -n 1p "$WORKER_WALLS_DIR/codex-epoch")
        [ "$(sed -n 2p "$WORKER_WALLS_DIR/codex-epoch")" = 1000000 ] || exit 1
        printf '1000120\n' >"$WORK/wall-clock"
        record_run_wall "$fixture" codex
        [ "$(sed -n 1p "$WORKER_WALLS_DIR/codex-epoch")" = "$epoch" ] || exit 1
        [ "$(sed -n 2p "$WORKER_WALLS_DIR/codex-epoch")" = 1000120 ] || exit 1
        printf '%s\n' "$(( $(cat "$fixture/attempt") + 1 ))" >"$fixture/attempt"
        record_run_wall "$fixture" codex
        [ "$(sed -n 1p "$WORKER_WALLS_DIR/codex-epoch")" -gt "$epoch" ] || exit 1
        printf '%s\n' "$(( $(cat "$fixture/attempt") + 1 ))" >"$fixture/attempt"
      done
    )
    assert test "$?" -eq 0
  fi

  if reliability_case R3; then
    clear_stub
    : >"$STUB_DIR/codex_bad_model_always"
    STUB_PICK_WALL=1 start_ok codex --account model
    result=$("$RUNNER" wait "$RUN_ID" --max 10)
    assert grep -qx 'OUTCOME: CODEX_UNAVAILABLE' <<<"$result"
    assert_fails grep -q 'REROUTE\|KILLED: wall' <<<"$result"
    assert test ! -s "$PICK_LOG"
    assert test ! -e "$WORKER_WALLS_DIR/codex-model"
  fi

  if reliability_case R3-default; then
    for resume in '' default-session; do
      clear_stub
      start_ok codex --account model --model default --resume "$resume"
      assert await_done
      assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
      assert_fails grep -qx 'ARG=default' "$CALL_LOG"
    done
  fi

  if reliability_case R3-retry; then
    clear_stub
    : >"$STUB_DIR/codex_bad_model"
    start_ok codex --account model
    assert await_done
    assert grep -qxF 'ARG=model=\"gpt-6.1-astra\"' "$CALL_LOG"
    clear_stub
    : >"$STUB_DIR/codex_bad_model"
    # config.toml is Egor's interactive pick: a terra there changes nothing about the retry,
    # which respells the allow-list's own model.
    printf 'model = "gpt-5.6-terra"\n' >"$WORKER_RUN_CODEX_CONFIG"
    start_ok codex --account model --model astra
    assert await_done
    assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
    assert grep -qxF 'ARG=model=\"gpt-6.1-astra\"' "$CALL_LOG"
    assert_fails grep -qx 'OUTCOME: CODEX_UNAVAILABLE' "$WORK/wait.out"
    printf 'model = "gpt-6-astra"\n' >"$WORKER_RUN_CODEX_CONFIG"
  fi

  if reliability_case A-mtime; then
    (
      eval "$(sed -n '/^newest_mtime() {/,/^}/p' "$RUNNER")"
      stat() {
        [ "$1" != -f ] || { printf 'filesystem info\n'; return 1; }
        case "$3" in out) printf '100\n' ;; err) printf '200\n' ;; *) return 1 ;; esac
      }
      [ "$(newest_mtime out err missing)" = 200 ]
    )
    assert test "$?" -eq 0
  fi

  if reliability_case A-heartbeat; then
    clear_stub
    cat >"$WORK/bin/heartbeat-grokb" <<'EOF'
#!/usr/bin/env bash
if [ "$2" = wall ]; then
  printf '%s\n' '{"type":"error","message":"You have hit the credit limit for your plan."}'
  while :; do printf 'heartbeat\n' >&2; sleep 0.2; done
fi
printf '%s\n' '{"type":"end","sessionId":"heartbeat-rescue","stopReason":"end_turn"}'
EOF
    chmod +x "$WORK/bin/heartbeat-grokb"
    WORKER_RUN_GROKB="$WORK/bin/heartbeat-grokb" WORKER_RUN_WALL_SETTLE_S=60 start_ok grok --account wall
    result=$("$RUNNER" wait "$RUN_ID" --max 6)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert grep -qx 'REROUTE: walled on wall → continued on rescue' <<<"$result"
    assert test "$(sed -n 1p "$WORKER_WALLS_DIR/grok-wall")" -gt "$(date +%s)"
  fi

  if reliability_case A; then
    clear_stub
    printf 'wall\n' >"$STUB_DIR/wall_accounts"
    start_ok codex --account wall
    result=$("$RUNNER" wait "$RUN_ID" --max 6)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert grep -qx 'REROUTE: walled on wall → continued on rescue' <<<"$result"
    assert test "$(sed -n 1p "$WORKER_WALLS_DIR/codex-wall")" -gt "$(date +%s)"
    assert test "$(cat "$RUN_DIR/attempt")" = 2
    assert_fails kill -0 "$(cat "$STUB_DIR/wall.pid")"
    assert_fails kill -0 "$(cat "$STUB_DIR/wall.child.pid")"
  fi

  if reliability_case A-echo; then
    clear_stub
    printf 'wall\n' >"$STUB_DIR/wall_accounts"
    STUB_WALL_ECHO=5 WORKER_RUN_WALL_SETTLE_S=3 start_ok codex --account wall
    result=$("$RUNNER" wait "$RUN_ID" --max 10)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert_fails grep -q 'REROUTE\|KILLED' <<<"$result"
    assert test ! -e "$RUN_DIR/killed"
    assert test ! -e "$WORKER_WALLS_DIR/codex-wall"
    unset STUB_WALL_ECHO
  fi

  if reliability_case A-resume; then
    clear_stub
    printf 'wall\n' >"$STUB_DIR/wall_accounts"
    start_ok codex --account wall --resume wall-session
    result=$("$RUNNER" wait "$RUN_ID" --max 6)
    assert grep -qx 'KILLED: wall — vendor usage limit detected' <<<"$result"
    assert grep -qx 'WALL: resumed session stays on wall' <<<"$result"
    assert grep -qx wall "$RUN_DIR/killed"
    assert test ! -s "$PICK_LOG"
  fi

  if reliability_case B; then
    clear_stub
    export STUB_SLEEP=8
    WORKER_RUN_SILENT_S=2 start_ok codex --account silent
    result=$("$RUNNER" wait "$RUN_ID" --max 6)
    assert grep -qx 'KILLED: silent — no output in 2s' <<<"$result"
    assert grep -qx 'silent 2' "$RUN_DIR/killed"
    assert test ! -s "$RUN_DIR/out"
    assert test ! -s "$RUN_DIR/err"
    assert test ! -e "$WORKER_WALLS_DIR/codex-silent"
    unset STUB_SLEEP
    start_ok codex --account silent --resume silent-session
    assert await_done
    assert grep -qx 'STATUS: done' "$WORK/wait.out"
    export STUB_SLEEP=3
    WORKER_RUN_SILENT_S=0 start_ok codex --account silent
    assert await_done
    assert grep -qx 'STATUS: done' "$WORK/wait.out"
    unset STUB_SLEEP
  fi

  if reliability_case C; then
    clear_stub
    export STUB_SLEEP=8
    start_ok codex --account busy --resume busy-session
    old_id=$RUN_ID old_dir=$RUN_DIR
    assert grep -qx busy-session "$old_dir/worker-session"
    rc=0
    "$RUNNER" start codex --brief "$WORK/brief" --account busy --resume busy-session >"$WORK/busy.out" 2>&1 || rc=$?
    assert test "$rc" -eq 4
    assert grep -qx "OUTCOME: RESUME_BUSY $old_id" "$WORK/busy.out"
    assert grep -qx "ATTACH $old_id" "$WORK/busy.out"
    kill -TERM "$(jq -r '.pid' "$old_dir/meta.json")"
    "$RUNNER" wait "$old_id" --max 6 >/dev/null
    unset STUB_SLEEP
    start_ok codex --account busy --resume busy-session
    assert await_done
    assert grep -qx 'STATUS: done' "$WORK/wait.out"
  fi

  if reliability_case D; then
    clear_stub
    export STUB_SLEEP=8
    start_ok codex --account duplicate
    old_id=$RUN_ID old_dir=$RUN_DIR
    rc=0
    WORKER_RUN_ALLOW_DUPLICATE=0 "$RUNNER" start codex --brief "$WORK/brief" --account duplicate >"$WORK/duplicate.out" 2>&1 || rc=$?
    assert test "$rc" -eq 4
    assert grep -qx "OUTCOME: DUPLICATE_RUN $old_id" "$WORK/duplicate.out"
    assert grep -qx "ATTACH $old_id" "$WORK/duplicate.out"
    unset STUB_SLEEP
    WORKER_RUN_ALLOW_DUPLICATE=1 start_ok codex --account duplicate
    assert await_done
    assert grep -qx 'STATUS: done' "$WORK/wait.out"
    CLAUDE_CODE_SESSION_ID=another-launcher WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate
    assert await_done
    rc=0
    CLAUDE_CODE_SESSION_ID=nested-worker CLAUDE_LAUNCHER_SESSION=reliability-launcher WORKER_RUN_ALLOW_DUPLICATE=0 \
      "$RUNNER" start codex --brief "$WORK/brief" --account duplicate >"$WORK/duplicate.out" 2>&1 || rc=$?
    assert test "$rc" -eq 4
    assert grep -qx "OUTCOME: DUPLICATE_RUN $old_id" "$WORK/duplicate.out"
    printf 'different brief\n' >"$WORK/different-brief"
    WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate --brief "$WORK/different-brief"
    assert await_done
    kill -TERM "$(jq -r '.pid' "$old_dir/meta.json")"
    "$RUNNER" wait "$old_id" --max 6 >/dev/null
    WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate
    assert await_done
    fixture="$WORKER_RUN_DIR/old-live"
    mkdir -p "$fixture"
    sleep 30 & live_pid=$!
    cp "$WORK/brief" "$fixture/brief"
    printf '%s\n' "$CLAUDE_CODE_SESSION_ID" >"$fixture/launcher"
    jq -cn --argjson pid "$live_pid" --argjson start "$(($(date +%s) - 1800))" '{pid:$pid,started_at:$start}' >"$fixture/meta.json"
    WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate
    assert await_done
    kill "$live_pid"
    wait "$live_pid" 2>/dev/null || :
    WORKER_RUN_ALLOW_DUPLICATE=0 start_ok codex --account duplicate
    assert await_done
    printf '0\n' >"$fixture/exit_code"
  fi

  if reliability_case E1; then
    clear_stub
    printf 'main\n' >"$STUB_DIR/wall_accounts"
    printf '2\n0 rescue\n' >"$STUB_DIR/pick_queue"
    export STUB_WALL_TEXT='worker-pick: no selectable codex account (main 0%/d ×7d WALLED)'
    start_ok codex
    result=$("$RUNNER" wait "$RUN_ID" --max 6)
    assert grep -qx 'STATUS: done' <<<"$result"
    assert grep -qx 'REROUTE: walled on main → continued on rescue' <<<"$result"
    unset STUB_WALL_TEXT
  fi

  if reliability_case E2; then
    clear_stub
    fixture="$WORK/reliability-repo"
    mkdir -p "$fixture"
    git -C "$fixture" init -q
    export STUB_SLEEP=8
    WORKER_RUN_IDLE_S=2 start_ok codex --account wedged --workdir "$fixture"
    for started in 1 2 3 4; do
      printf '%s\n' "$started" >"$fixture/cotenant-edit"
      sleep 1
    done
    result=$("$RUNNER" wait "$RUN_ID" --max 0)
    assert grep -q '^KILLED: idle watchdog' <<<"$result"
    unset STUB_SLEEP
  fi

  if reliability_case E3; then
    clear_stub
    export STUB_SLEEP=8
    start_ok codex --account main
    for started in $(seq 1 100); do [ -s "$STUB_DIR/codex.child.pid" ] && break; sleep 0.05; done
    cli_pid=$(cat "$STUB_DIR/codex.pid")
    child_pid=$(cat "$STUB_DIR/codex.child.pid")
    kill -TERM "$(jq -r '.pid' "$RUN_DIR/meta.json")"
    result=$("$RUNNER" wait "$RUN_ID" --max 6)
    assert grep -qx term "$RUN_DIR/killed"
    assert grep -q '^KILLED: signal TERM' <<<"$result"
    assert_fails kill -0 "$cli_pid"
    assert_fails kill -0 "$child_pid"
    unset STUB_SLEEP
  fi

  if reliability_case E4; then
    . "$ROOT/share/worker-pool.sh"
    fixture="$WORK/reliability-pool"
    mkdir -p "$fixture/shielded"
    : >"$fixture/shielded/main"
    reliability_names() { printf 'main\nother\n'; }
    worker_pool_set_all "$fixture" fixture reliability_names on >/dev/null
    assert grep -qx main "$fixture/disabled"
    assert grep -qx other "$fixture/disabled"
    rm "$fixture/shielded/main"
    assert worker_pool_is_disabled "$fixture" main
  fi
  clear_stub
}
report_bus_tests() {
  local CLAUDE_CODE_SESSION_ID=report-launcher CLAUDE_LAUNCHER_SESSION=report-launcher
  local WORKER_RUN_IDLE_S=0 WORKER_RUN_SILENT_S=0 WORKER_RUN_DEADLINE=600
  local PICK_RC=0 PICK_ACCOUNT=reportacct rc early_id old_id old_dir
  export CLAUDE_CODE_SESSION_ID CLAUDE_LAUNCHER_SESSION WORKER_RUN_IDLE_S WORKER_RUN_SILENT_S WORKER_RUN_DEADLINE PICK_RC PICK_ACCOUNT
  set_config 'codex_effort=high'
  clear_stub
  start_ok codex --account reportacct
  assert await_done
  "$RUNNER" report "$RUN_ID" >/dev/null
  "$RUNNER" wait "$RUN_ID" --max 0 >/dev/null
  assert_worker_post "$RUN_ID" DONE

  local place_repo="$WORK/place-repo" place_top
  git init -q "$place_repo"
  place_top=$(cd "$place_repo" && pwd -P)
  clear_stub
  TMPDIR=/nonexistent WORKER_TEST_WORKDIR=$place_repo start_ok codex --account reportacct
  assert await_done
  TMPDIR=/nonexistent "$RUNNER" report "$RUN_ID" >/dev/null
  assert test "$(cut -f2,3 "$HOME/.cache/claude-statusline/place-report-launcher" | tr '\t' ' ')" = "worker-start $place_top
worker-end $place_top"

  local norb_repo="$WORK/place-repo-norb" norb_top norb_path place_dir
  git init -q "$norb_repo"
  norb_top=$(cd "$norb_repo" && pwd -P)
  mv "$WORK/bin/report-bus" "$WORK/report-bus.aside"
  norb_path=$(IFS=:; for place_dir in $PATH; do [ -x "$place_dir/report-bus" ] || printf '%s:' "$place_dir"; done)
  clear_stub
  PATH=${norb_path%:} TMPDIR=/nonexistent WORKER_TEST_WORKDIR=$norb_repo start_ok codex --account reportacct
  PATH=${norb_path%:} assert await_done
  mv "$WORK/report-bus.aside" "$WORK/bin/report-bus"
  TMPDIR=/nonexistent "$RUNNER" report "$RUN_ID" >/dev/null
  assert test "$(tail -n 2 "$HOME/.cache/claude-statusline/place-report-launcher" | cut -f2,3 | tr '\t' ' ')" = "worker-start $norb_top
worker-end $norb_top"

  clear_stub
  STUB_SLEEP=60 start_ok codex --account reportacct
  sleep 0.3
  kill -TERM "$(jq -r .pid "$RUN_DIR/meta.json")"
  assert await_done
  "$RUNNER" report "$RUN_ID" >/dev/null
  assert_worker_post "$RUN_ID" CODEX_UNAVAILABLE

  clear_stub
  rc=0
  PICK_RC=3 "$RUNNER" start codex --brief "$WORK/brief" >"$WORK/report-limit.out" 2>"$WORK/report-limit.err" || rc=$?
  assert test "$rc" = 3
  assert test -z "$(sed -n 's/^RUN: //p' "$WORK/report-limit.out")"
  early_id=$(posted_id CODEX_USAGE_LIMIT)
  assert test -n "$early_id"
  assert_worker_post "$early_id" CODEX_USAGE_LIMIT

  clear_stub
  STUB_SLEEP=60 start_ok codex --account reportacct
  old_id=$RUN_ID old_dir=$RUN_DIR
  rc=0
  WORKER_RUN_ALLOW_DUPLICATE=0 "$RUNNER" start codex --account reportacct --brief "$WORK/brief" >"$WORK/report-duplicate.out" 2>&1 || rc=$?
  assert test "$rc" = 4
  assert test -z "$(sed -n 's/^RUN: //p' "$WORK/report-duplicate.out")"
  early_id=$(posted_id "DUPLICATE_RUN $old_id")
  assert test -n "$early_id"
  assert test "$early_id" != "$old_id"
  assert_worker_post "$early_id" "DUPLICATE_RUN $old_id"
  kill -TERM "$(jq -r .pid "$old_dir/meta.json")"
  assert await_done
  assert_worker_post "$old_id" CODEX_UNAVAILABLE
  clear_stub
}
# A refusal that never made a run directory prints no `RUN:` line — that line means a run exists to
# wait on — so its report id is read back off the bus.
posted_id() { # outcome
  jq -rs --arg o "OUTCOME: $1" \
    '[.[] | select(.body | startswith($o))] | last | .argv[4] // ""' "$REPORT_BUS_LOG"
}
assert_worker_post() {
  local id="$1" outcome="$2" rows
  rows=$(jq -s --arg id "$id" '[.[] | select(.argv[4] == $id)]' "$REPORT_BUS_LOG")
  assert test "$(jq length <<<"$rows")" = 1
  assert jq -e --arg id "$id" '.[0].argv == ["post","--kind","notice","--id",$id,"--session","report-launcher"]' <<<"$rows" >/dev/null
  assert test "$(jq -r '.[0].body' <<<"$rows" | head -n1)" = "OUTCOME: $outcome"
  assert test "$(jq -r '.[0].body' <<<"$rows" | wc -l | tr -d ' ')" = 3
  assert grep -q 'wall-clock: [0-9]*s' <<<"$(jq -r '.[0].body' <<<"$rows")"
  assert grep -q '^files: ' <<<"$(jq -r '.[0].body' <<<"$rows")"
}
report_bus_tests

for marker_state in dead aged; do
  marker_run="$WORKER_RUN_DIR/codex-stale-$marker_state"
  mkdir -p "$marker_run/.report-posting"
  printf '{"vendor":"codex","account":"main","model":"gpt-6-astra","effort":"medium","started_at":1}\n' >"$marker_run/meta.json"
  printf 'report-launcher\n' >"$marker_run/launcher"
  printf '0\n' >"$marker_run/exit_code"
  if [ "$marker_state" = dead ]; then printf '99999999\n' >"$marker_run/.report-posting/pid"
  else printf '%s\n' "$$" >"$marker_run/.report-posting/pid"; touch -t 202001010001 "$marker_run/.report-posting"; fi
  "$RUNNER" report "${marker_run##*/}" >"$WORK/stale-report.out"
  assert test -f "$marker_run/report-posted"
  assert test ! -e "$marker_run/.report-posting"
done

if [ "${WORKER_RUN_TEST_REPORTS_ONLY:-0}" = 1 ]; then
  printf 'PASS: %s report producer asserts\n' "$asserts"
  exit 0
fi

browse_tests() {
  local BT_WORK="$WORK/browse_tests"
  mkdir -p "$BT_WORK"
  local BT_DIA="$BT_WORK/dia_user_data"
  local BT_CHROME="$BT_WORK/chrome_user_data"
  local BT_CODEX_CONF="$BT_WORK/codex_config.toml"
  local BT_WP="$BT_WORK/bin/worker-pick"
  local BT_RUNS="$BT_WORK/runs"
  mkdir -p "$BT_DIA" "$BT_CHROME" "$BT_WORK/bin" "$BT_RUNS"

  local BROWSE_CUA_SYNC="$BT_WORK/bin/cua-sync"
  local BROWSE_CHROME_MANIFEST="$BT_WORK/native-hosts/manifest.json"
  local BROWSE_NATIVE_HOST="$BT_WORK/native-hosts/shared-host"
  local BT_SYNC_MODE=auto BT_SYNC_LOG="$BT_WORK/sync-calls"
  export BROWSE_CUA_SYNC BROWSE_CHROME_MANIFEST BROWSE_NATIVE_HOST BT_SYNC_MODE BT_SYNC_LOG
  mkdir -p "${BROWSE_CHROME_MANIFEST%/*}"
  printf '#!/bin/sh\nexit 0\n' >"$BROWSE_NATIVE_HOST"
  chmod +x "$BROWSE_NATIVE_HOST"
  jq -n --arg path "$BROWSE_NATIVE_HOST" '{path:$path, name:"kept", allowed_origins:["extension://kept"]}' >"$BROWSE_CHROME_MANIFEST"
  cat >"$BROWSE_CUA_SYNC" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-repair}" >>"$BT_SYNC_LOG"
case "$BT_SYNC_MODE:${1:-repair}" in
  registered:*) exit 0 ;;
  repaired:--check) exit 1 ;;
  repaired:repair) exit 0 ;;
  broken:* ) printf 'fake registration failure\nsecond diagnostic\n' >&2; exit 1 ;;
esac
if grep -q '^\[mcp_servers.cua_repl\]' "$BROWSE_CODEX_CONFIG"; then exit 0; fi
printf 'fake registration failure\n' >&2
exit 1
EOF
  chmod +x "$BROWSE_CUA_SYNC"

  cat >"$BT_DIA/Local State" <<'EOF'
{
  "profile": {
    "info_cache": {
      "Profile 8": {
        "name": "work dia"
      }
    },
    "last_used": "Profile 8"
  }
}
EOF

  local BT_DIA_EXT="$BT_DIA/Profile 8/Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn"
  mkdir -p "$BT_DIA_EXT"
  printf 'bridgeDeviceId\x01\x0c\x0d\x3f\xd06ada21d4-ae66-4990-9040-97e18bb7b529"\x07\x12\x0ddisplayName\x01\x2b\x01\x05<<\"Dia browser\"\x02\x26\x04\x05\x09hControl' >"$BT_DIA_EXT/000001.log"

  cat >"$BT_CHROME/Local State" <<'EOF'
{
  "profile": {
    "info_cache": {
      "Profile 1": {
        "name": "Egor work"
      }
    },
    "last_used": "Profile 1"
  }
}
EOF

  local BT_CHROME_EXT="$BT_CHROME/Profile 1/Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn"
  mkdir -p "$BT_CHROME_EXT"
  printf 'bridgeDeviceId\x01\x0c\x0d\x3f\xd0b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d"\x07\x12\x0ddisplayName\x01\x2b\x01\x05<<\"Chrome browser\"\x02\x26' >"$BT_CHROME_EXT/000001.log"

  cat >"$BT_CODEX_CONF" <<'EOF'
[mcp_servers.cua_repl]
startup_timeout_sec = 120
command = "/path/to/node"
args = ["/path/to/launch.mjs"]
EOF

  cat >"$BT_WP" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
codex:    7.4%/d ×7.0d   48%   48%   main                 astra·high
          5.0%/d ×7.0d   90%   100%  wall                 astra·high   ↺ Thu 02:51  WALLED
claude:  11.4%/d ×7.0d   20%   20%   com                  opus·high
          8.6%/d ×7.0d   40%   30%   extra                opus·high    off
         * = this session account
OUTPUT
EOF
  chmod +x "$BT_WP"

  # The transport a vendor drives the browser through is a process tree plus a socket, and both
  # belong to Egor's real machine: every case here reads a fixture listing instead, so no assertion
  # depends on which browser happens to be open while the suite runs.
  local BT_PS="$BT_WORK/bin/ps-fixture" BT_LSOF="$BT_WORK/bin/lsof-fixture"
  local BT_PS_LISTING="$BT_WORK/ps-listing"
  local BT_SOCK_CLAUDE="$BT_WORK/sockets/claude" BT_SOCK_CODEX="$BT_WORK/sockets/codex"
  mkdir -p "$BT_SOCK_CLAUDE" "$BT_SOCK_CODEX"
  : >"$BT_SOCK_CLAUDE/101.sock"
  : >"$BT_SOCK_CLAUDE/201.sock"
  : >"$BT_SOCK_CODEX/1f0c9d3a.sock"
  cat >"$BT_WORK/ps-connected" <<'EOF'
  100     1 /Applications/Dia.app/Contents/MacOS/Dia
  101   100 /Users/egorloy/.local/bin/claude --chrome-native-host
  102   100 /Users/egorloy/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/
  200     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  201   200 /Users/egorloy/.local/bin/claude --chrome-native-host
  202   200 /Users/egorloy/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/
  300   100 /Applications/Dia.app/Contents/MacOS/Dia --type=renderer
EOF
  # Chrome is up with no transport of its own, spelled through every near miss: the extension hosts
  # under it belong to Dia (101 even holds a socket), the one child Chrome does have is an ordinary
  # renderer whose flags are not a host command, and the host that IS Chrome's (205) has no socket.
  # Each line fails a different one of the three tests — command, parentage, its own socket.
  cat >"$BT_WORK/ps-chrome-bare" <<'EOF'
  100     1 /Applications/Dia.app/Contents/MacOS/Dia
  101   100 /Users/egorloy/.local/bin/claude --chrome-native-host
  102   100 /Users/egorloy/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/
  200     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  201   200 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=utility --utility-sub-type=network.mojom.NetworkService
  205   200 /Users/egorloy/.local/bin/claude --chrome-native-host
EOF
  cat >"$BT_WORK/ps-dia-bare" <<'EOF'
  100     1 /Applications/Dia.app/Contents/MacOS/Dia
  200     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  202   200 /Users/egorloy/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/
EOF
  cp "$BT_WORK/ps-connected" "$BT_PS_LISTING"
  cat >"$BT_PS" <<EOF
#!/bin/sh
cat "$BT_PS_LISTING"
EOF
  cat >"$BT_LSOF" <<EOF
#!/bin/sh
printf 'ChatGPT %s egorloy 3u unix 0x0 0t0 %s/1f0c9d3a.sock\n' "\$2" "$BT_SOCK_CODEX"
EOF
  chmod +x "$BT_PS" "$BT_LSOF"
  local BROWSE_PS="$BT_PS" BROWSE_LSOF="$BT_LSOF"
  local BROWSE_CLAUDE_SOCKET_DIR="$BT_SOCK_CLAUDE" BROWSE_CODEX_SOCKET_DIR="$BT_SOCK_CODEX"
  export BROWSE_PS BROWSE_LSOF BROWSE_CLAUDE_SOCKET_DIR BROWSE_CODEX_SOCKET_DIR

  local out rc=0 preamble_path
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" \
        BROWSE_WORKER_PICK="$BT_WP" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'DIA: running' <<<"$out"
  assert grep -qx 'DIA-PROFILE: work dia (Profile 8)' <<<"$out"
  assert grep -qx 'DIA-DEVICE: 6ada21d4-ae66-4990-9040-97e18bb7b529 "Dia browser"' <<<"$out"
  assert grep -qx 'TARGET: dia' <<<"$out"
  assert grep -qx 'CHROME-DEVICE: b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d "Chrome browser"' <<<"$out"
  assert grep -qx 'CHROME-PROFILE: Egor work (Profile 1)' <<<"$out"
  assert test "$(grep -c '^BANNED-DEVICES:' <<<"$out")" -eq 0
  assert test "$(grep -c '^LAUNCHED:' <<<"$out")" -eq 0
  assert grep -qx 'CHROME: absent' <<<"$out"
  assert grep -qx 'CUA-REPL: registered' <<<"$out"
  assert grep -qx 'SKY: running' <<<"$out"
  assert grep -qx 'NEXT-CLAUDE-ACCOUNTS: com' <<<"$out"
  assert grep -qx 'NEXT-CODEX-ACCOUNT: main' <<<"$out"
  assert grep -qx 'REASON: claudeb/extra skipped — out of pool' <<<"$out"
  assert grep -qx 'REASON: codex/wall skipped — walled' <<<"$out"
  assert test "$(grep -c 'this session account' <<<"$out")" -eq 0
  assert grep -qx 'PLAN: codex account=main' <<<"$out"
  assert grep -q '^PREAMBLE-FILE: ' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert test -f "$preamble_path"
  assert grep -q 'await cua.getState()' "$preamble_path"
  assert grep -q 'https://example.com' "$preamble_path"
  assert grep -q 'work dia' "$preamble_path"
  assert grep -q 'irrelevant to `cua`' "$preamble_path"
  assert grep -q 'agent.browsers.list()' "$preamble_path"
  assert grep -q 'WITHOUT a `profileName`' "$preamble_path"
  assert grep -q 'Egor work.*is Google Chrome' "$preamble_path"
  assert grep -q 'Never drive Google Chrome' "$preamble_path"
  assert test "$(grep -c '6ada21d4-ae66-4990-9040-97e18bb7b529' "$preamble_path")" -eq 0
  assert test "$(grep -c 'b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d' "$preamble_path")" -eq 0

  cat >"$BT_CODEX_CONF.nocua" <<'EOF'
[model]
name = "gpt-6-astra"
EOF
  rc=0
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua" \
        BROWSE_WORKER_PICK="$BT_WP" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'CUA-REPL: broken' <<<"$out"
  assert grep -qx 'REASON: codex skipped — cua_repl registration failed: fake registration failure' <<<"$out"
  assert grep -qx 'PLAN: claudeb account=com device=6ada21d4-ae66-4990-9040-97e18bb7b529 source=probe' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert test -f "$preamble_path"
  assert grep -q 'list_connected_browsers' "$preamble_path"
  assert grep -qF 'Target Dia device ID: 6ada21d4-ae66-4990-9040-97e18bb7b529' "$preamble_path"
  assert grep -qF 'Off-target extension device IDs (Google Chrome — never drive one, never `switch_browser` to it): b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d' "$preamble_path"

  rc=0
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" \
        BROWSE_WORKER_PICK="$BT_WP" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'PLAN: claudeb account=com device=6ada21d4-ae66-4990-9040-97e18bb7b529 source=probe' <<<"$out"

  cat >"$BT_WP.multi" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
claude:  11.4%/d ×7.0d   20%   20%   com                  opus·high
          8.6%/d ×7.0d   40%   30%   spare                opus·high
OUTPUT
EOF
  chmod +x "$BT_WP.multi"

  rc=0
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua" \
        BROWSE_WORKER_PICK="$BT_WP.multi" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse --record 6ada21d4-ae66-4990-9040-97e18bb7b529 spare) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'RECORDED: 6ada21d4-ae66-4990-9040-97e18bb7b529 spare' <<<"$out"
  assert grep -qx 'NEXT-CLAUDE-ACCOUNTS: spare,com' <<<"$out"
  assert grep -qx 'PLAN: claudeb account=spare device=6ada21d4-ae66-4990-9040-97e18bb7b529 source=cached' <<<"$out"

  cat >"$BT_WP.empty" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
codex:   unavailable
claude:  no accounts
OUTPUT
EOF
  chmod +x "$BT_WP.empty"

  rc=0
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" \
        BROWSE_WORKER_PICK="$BT_WP.empty" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'PLAN: none' <<<"$out"

  local json_out
  rc=0
  json_out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
             BROWSE_CHROME_USER_DATA="$BT_CHROME" \
             BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" \
             BROWSE_WORKER_PICK="$BT_WP" \
             WORKER_RUN_DIR="$BT_RUNS" \
             BROWSE_SKIP_PROCESSES=1 \
             "$RUNNER" browse --json) || rc=$?
  assert test "$rc" -eq 0
  assert jq -e . <<<"$json_out" >/dev/null
  assert test "$(jq -r .dia <<<"$json_out")" = 'running'
  assert test "$(jq -r .dia_profile.dir <<<"$json_out")" = 'Profile 8'
  assert test "$(jq -r .dia_profile.name <<<"$json_out")" = 'work dia'
  assert test "$(jq -r .dia_device.id <<<"$json_out")" = '6ada21d4-ae66-4990-9040-97e18bb7b529'
  assert test "$(jq -r .target <<<"$json_out")" = 'dia'
  assert test "$(jq -r .chrome_device.id <<<"$json_out")" = 'b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d'
  assert test "$(jq -r .chrome_profile.name <<<"$json_out")" = 'Egor work'
  assert test "$(jq -r .chrome_profile.dir <<<"$json_out")" = 'Profile 1'
  assert test "$(jq -r .launched <<<"$json_out")" = 'null'
  assert test "$(jq -r 'has("banned_devices")' <<<"$json_out")" = 'false'
  assert test "$(jq -r .cua_repl <<<"$json_out")" = 'registered'
  assert test "$(jq -r .plan.vendor <<<"$json_out")" = 'codex'
  assert test "$(jq -r .plan.account <<<"$json_out")" = 'main'

  local BROWSE_DIA_USER_DATA="$BT_DIA" BROWSE_CHROME_USER_DATA="$BT_CHROME"
  local BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" BROWSE_WORKER_PICK="$BT_WP.multi" BROWSE_SKIP_PROCESSES=1
  local WORKER_RUN_DIR="$BT_RUNS"
  export BROWSE_DIA_USER_DATA BROWSE_CHROME_USER_DATA BROWSE_CODEX_CONFIG BROWSE_WORKER_PICK BROWSE_SKIP_PROCESSES WORKER_RUN_DIR
  local dev=6ada21d4-ae66-4990-9040-97e18bb7b529 other_dev=8e70ec10-fa25-45a9-8e57-2ecae0629d12
  local chrome_dev=b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d
  local cache="$BT_RUNS/browse/devices.json" fixture="$BT_RUNS/codex-browser-fixture"
  mkdir -p "$fixture"
  printf '{"vendor":"codex","account":"spare","workdir":"%s","started_at":0,"pid":0,"browser":true}\n' "$WORK/workdir" >"$fixture/meta.json"
  : >"$fixture/err"
  printf 'BROWSER-DEVICE-ACCOUNT: %s spare\n' "$dev" >"$fixture/out"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].account == "spare" and (.[$dev].seen | test("Z$"))' "$cache" >/dev/null
  jq --arg dev "$dev" '.[$dev].seen = "old"' "$cache" >"$cache.fixture"
  mv "$cache.fixture" "$cache"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].seen == "old"' "$cache" >/dev/null
  cp -R "$fixture" "$fixture-refresh"
  fixture="$fixture-refresh"
  rm "$fixture/result"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].seen != "old"' "$cache" >/dev/null
  cp -R "$fixture" "$fixture-other-account"
  fixture="$fixture-other-account"
  rm "$fixture/result"
  printf 'OUTCOME: BROWSER_DEVICE_NOT_IN_ACCOUNT device=%s account=com\n' "$dev" >"$fixture/out"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].account == "spare"' "$cache" >/dev/null
  cp -R "$fixture" "$fixture-drop"
  fixture="$fixture-drop"
  rm "$fixture/result"
  printf 'OUTCOME: BROWSER_DEVICE_NOT_IN_ACCOUNT device=%s account=spare\n' "$dev" >"$fixture/out"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].account == "spare" and .[$dev].denied == true' "$cache" >/dev/null
  cp -R "$fixture" "$fixture-claudeb"
  fixture="$fixture-claudeb"
  rm "$fixture/result"
  jq '.vendor = "claudeb"' "$fixture/meta.json" >"$fixture/meta.next"
  mv "$fixture/meta.next" "$fixture/meta.json"
  jq -n --arg result "BROWSER-DEVICE-ACCOUNT: $dev com" '{result:$result}' >"$fixture/out"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].account == "com"' "$cache" >/dev/null

  BROWSE_WORKER_PICK="$BT_WP"
  for BT_SYNC_MODE in registered repaired broken; do
    : >"$BT_SYNC_LOG"
    rc=0
    out=$("$RUNNER" browse --vendor codex) || rc=$?
    assert grep -qx "CUA-REPL: $BT_SYNC_MODE" <<<"$out"
    if [ "$BT_SYNC_MODE" = broken ]; then
      assert test "$rc" -eq 2
      assert grep -qx 'PLAN: none' <<<"$out"
      assert grep -qx 'REASON: codex skipped — cua_repl registration failed: fake registration failure' <<<"$out"
      assert test "$(grep -c 'second diagnostic' <<<"$out")" -eq 0
    else
      assert test "$rc" -eq 0
      assert grep -qx 'PLAN: codex account=main' <<<"$out"
    fi
    assert grep -qx -- '--check' "$BT_SYNC_LOG"
    if [ "$BT_SYNC_MODE" = registered ]; then
      assert test "$(wc -l <"$BT_SYNC_LOG" | tr -d ' ')" -eq 1
    else
      assert grep -qx repair "$BT_SYNC_LOG"
    fi
  done
  BT_SYNC_MODE=registered

  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'MANIFEST: ok' <<<"$out"
  jq '.path = "/dead/profile/chrome-native-host"' "$BROWSE_CHROME_MANIFEST" >"$BT_WORK/dead-manifest"
  cp "$BT_WORK/dead-manifest" "$BROWSE_CHROME_MANIFEST"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'MANIFEST: repaired' <<<"$out"
  assert grep -qxF "REASON: manifest path repaired: /dead/profile/chrome-native-host -> $BROWSE_NATIVE_HOST" <<<"$out"
  assert jq -e --arg path "$BROWSE_NATIVE_HOST" '.path == $path and .name == "kept" and .allowed_origins == ["extension://kept"]' "$BROWSE_CHROME_MANIFEST" >/dev/null
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'MANIFEST: ok' <<<"$out"
  rc=0
  out=$(BROWSE_CHROME_MANIFEST="$BT_WORK/absent.json" "$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'MANIFEST: missing' <<<"$out"
  assert grep -qx 'REASON: claudeb skipped — native messaging manifest missing' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  rc=0
  out=$(BROWSE_CHROME_MANIFEST="$BT_WORK/dead-manifest" BROWSE_NATIVE_HOST="$BT_WORK/absent-host" "$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'MANIFEST: broken' <<<"$out"
  assert grep -qx 'REASON: claudeb skipped — native host missing at /dead/profile/chrome-native-host' <<<"$out"
  chmod -x "$BROWSE_NATIVE_HOST"
  rc=0
  out=$("$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'MANIFEST: broken' <<<"$out"
  chmod +x "$BROWSE_NATIVE_HOST"

  jq '.profile.last_active_profiles = ["Profile 8", "Profile 7", "Profile 8"] | .profile.info_cache["Profile 7"].name = "home dia"' \
    "$BT_DIA/Local State" >"$BT_WORK/two-profiles"
  cp "$BT_WORK/two-profiles" "$BT_DIA/Local State"
  mkdir -p "$BT_DIA/Profile 7/Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn"
  printf 'bridgeDeviceId "%s" displayName "Home browser"\n' "$other_dev" >"$BT_DIA/Profile 7/Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn/000001.log"
  out=$("$RUNNER" browse --record "$other_dev" notcom)
  cat >"$BT_WP.profiles" <<'EOF'
#!/bin/sh
printf 'claude: com WALLED\n        notcom\n'
EOF
  chmod +x "$BT_WP.profiles"
  BROWSE_WORKER_PICK="$BT_WP.profiles"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'DIA-PROFILE: home dia (Profile 7)' <<<"$out"
  assert grep -qx "PLAN: claudeb account=notcom device=$other_dev source=cached" <<<"$out"
  assert grep -qx "DIA-OTHER: work dia (Profile 8) $dev account=com" <<<"$out"
  assert grep -qx 'REASON: dia/work dia skipped — account com walled' <<<"$out"
  assert test "$(grep -c '^DIA-OTHER:' <<<"$out")" -eq 1
  json_out=$("$RUNNER" browse --vendor claudeb --json)
  assert jq -e '.dia_profile.dir == "Profile 7" and .dia_other[0].account == "com" and .manifest == "ok"' <<<"$json_out" >/dev/null
  assert jq -e '.reasons | index("dia/work dia skipped — account com walled") != null' <<<"$json_out" >/dev/null
  rc=0
  out=$("$RUNNER" browse --vendor claudeb --dia-profile 'Profile 8') || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'DIA-PROFILE: work dia (Profile 8)' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  assert test "$(grep -c '^DIA-OTHER:' <<<"$out")" -eq 0
  BROWSE_WORKER_PICK="$BT_WP.multi"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'DIA-PROFILE: work dia (Profile 8)' <<<"$out"
  assert grep -qx "DIA-OTHER: home dia (Profile 7) $other_dev account=notcom" <<<"$out"
  printf '{}\n' >"$cache"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx "PLAN: claudeb account=com device=$dev source=probe" <<<"$out"
  assert grep -qx "DIA-OTHER: home dia (Profile 7) $other_dev unknown" <<<"$out"

  local vendor original_brief
  original_brief=$(cat "$WORK/brief")
  for vendor in codex claudeb; do
    clear_stub
    rc=0
    out=$(BROWSE_WORKER_PICK="$BT_WP.empty" "$RUNNER" start "$vendor" --browser --brief "$WORK/brief") || rc=$?
    assert test "$rc" -eq 2
    assert grep -qx 'REASON: claudeb skipped — no usable accounts' <<<"$out"
    assert grep -qx 'REASON: codex skipped — no usable accounts' <<<"$out"
    assert test ! -s "$CALL_LOG"
    assert test "$(grep -c '^RUN:' <<<"$out")" -eq 0
  done
  clear_stub
  out=$("$RUNNER" browse --record "$dev" com)
  rc=0
  out=$("$RUNNER" start claudeb --browser --account spare --brief "$WORK/brief") || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx "REASON: claudeb/spare cannot see device $dev; plan says com" <<<"$out"
  assert test ! -s "$CALL_LOG"

  clear_stub
  BROWSE_WORKER_PICK="$BT_WP"
  start_ok claudeb --browser
  assert await_done
  assert meta_account_is com
  assert test ! -s "$PICK_LOG"
  assert grep -qx 'ARG=--chrome' "$CALL_LOG"
  assert jq -e --arg dev "$dev" '.browser == true and .chrome == true and .browser_device == $dev and .browser_account == "com"' "$RUN_DIR/meta.json" >/dev/null
  assert test "$(head -n1 "$RUN_DIR/brief.launch")" = '# Browser Automation Preamble (Claudeb / Dia)'
  assert grep -q 'list_connected_browsers' "$STUB_DIR/claudeb.stdin"
  assert grep -qx 'test brief' "$STUB_DIR/claudeb.stdin"
  assert cmp -s "$WORK/brief" "$RUN_DIR/brief"
  assert test "$(cat "$WORK/brief")" = "$original_brief"

  clear_stub
  start_ok claudeb --browser --account com
  assert await_done
  assert meta_account_is com

  clear_stub
  start_ok codex --browser --account alternate
  assert await_done
  assert meta_account_is alternate
  assert jq -e '.browser == true and .chrome == false and .browser_account == "alternate"' "$RUN_DIR/meta.json" >/dev/null
  assert grep -q 'await cua.getState()' "$STUB_DIR/codex.stdin"
  assert grep -qx 'test brief' "$STUB_DIR/codex.stdin"
  assert test "$(cat "$WORK/brief")" = "$original_brief"

  # A codex plan names no device, and what the run then records is the TARGET's browser: the other
  # browser's uuid in meta.json points every later reader at a device the run never touched.
  clear_stub
  start_ok codex --browser --target chrome --account alternate
  assert await_done
  assert jq -e --arg dev "$chrome_dev" '.browser_device == $dev' "$RUN_DIR/meta.json" >/dev/null
  clear_stub
  start_ok codex --browser --target dia --account alternate
  assert await_done
  assert jq -e --arg dev "$dev" '.browser_device == $dev' "$RUN_DIR/meta.json" >/dev/null

  clear_stub
  BT_SYNC_MODE=broken
  rc=0
  out=$("$RUNNER" start codex --browser --brief "$WORK/brief") || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'REASON: codex skipped — cua_repl registration failed: fake registration failure' <<<"$out"
  assert test ! -s "$CALL_LOG"
  BT_SYNC_MODE=registered

  clear_stub
  export STUB_CODE=1 STUB_ERROR='hit your usage limit'
  start_ok claudeb --browser
  assert await_done
  assert meta_account_is com
  assert test ! -s "$PICK_LOG"
  assert test "$(grep -c '^CLAUDEB_CALL$' "$CALL_LOG")" -eq 1
  assert grep -qx 'WALL: browser device stays on com' "$WORK/wait.out"
  clear_stub

  unset BROWSE_CODEX_CONFIG
  local SYNC_TEST_HOME="$BT_WORK/codex_sync_home"
  local SYNC_MANIFEST_DIR="$SYNC_TEST_HOME/plugins/cache/openai-bundled/unified-computer-use/26.901.51231"
  mkdir -p "$SYNC_MANIFEST_DIR" "$SYNC_TEST_HOME" "$BT_WORK/bin"

  cat >"$SYNC_MANIFEST_DIR/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "cua_repl": {
      "command": "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node",
      "args": ["/path/to/launch.mjs"],
      "env": {
        "NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER": "Browser instructions from manifest",
        "NODE_REPL_NODE_PATH": "/path/to/node"
      }
    }
  }
}
EOF

  cat >"$SYNC_TEST_HOME/config.toml" <<'EOF'
[mcp_servers.node_repl.env]
NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = ""
EOF

  local SYNC_LOG="$BT_WORK/codex_cli.log"
  : >"$SYNC_LOG"
  cat >"$BT_WORK/bin/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SYNC_LOG"
EOF
  chmod +x "$BT_WORK/bin/codex"

  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null 2>&1 || rc=$?
  assert test "$rc" -eq 1

  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/sync.out" || rc=$?
  assert test "$rc" -eq 0
  assert test "$(grep -c 'mcp remove cua_repl' "$SYNC_LOG")" -eq 0
  assert grep -q 'mcp add cua_repl' "$SYNC_LOG"
  assert grep -q 'startup_timeout_sec = 120' "$SYNC_TEST_HOME/config.toml"
  assert grep -q 'NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "Browser instructions from manifest"' "$SYNC_TEST_HOME/config.toml"

  rc=0
  out=$(CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check) || rc=$?
  assert test "$rc" -eq 0
  assert test "$out" = 'unchanged'
  local newer_manifest="$SYNC_TEST_HOME/plugins/cache/openai-bundled/unified-computer-use/26.901.100000/.mcp.json"
  mkdir -p "${newer_manifest%/*}"
  jq '.mcpServers.cua_repl.args = ["/new-version/launch.mjs"]' "$SYNC_MANIFEST_DIR/.mcp.json" >"$newer_manifest"
  touch -t 202001010000 "$newer_manifest"
  printf '\n[mcp_servers.decoy]\nargs = ["/new-version/launch.mjs"]\n' >>"$SYNC_TEST_HOME/config.toml"
  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null || rc=$?
  assert test "$rc" -eq 1
  assert env CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/sync-update.out"
  assert env CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null
  assert grep -qx 'args = ["/new-version/launch.mjs"]' "$SYNC_TEST_HOME/config.toml" -F
  assert grep -qx '[mcp_servers.decoy]' "$SYNC_TEST_HOME/config.toml" -F

  cp "$SYNC_TEST_HOME/config.toml" "$BT_WORK/override.toml"
  jq '.mcpServers.cua_repl.args = ["/third-version/launch.mjs"]' "$newer_manifest" >"$BT_WORK/updated-manifest"
  mv "$BT_WORK/updated-manifest" "$newer_manifest"
  assert env CODEX_HOME="$SYNC_TEST_HOME" BROWSE_CODEX_CONFIG="$BT_WORK/override.toml" PATH="$BT_WORK/bin:$PATH" \
    "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/override-sync.out"
  assert grep -qxF 'args = ["/third-version/launch.mjs"]' "$BT_WORK/override.toml"
  assert test "$(grep -c '/third-version/' "$SYNC_TEST_HOME/config.toml")" -eq 0

  # 1: multiline/quoted instruction values survive TOML fill
  jq '.mcpServers.cua_repl.env.NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "line1\nquote \"here\" and \\slash"' \
    "$newer_manifest" >"$BT_WORK/nl-manifest" && mv "$BT_WORK/nl-manifest" "$newer_manifest"
  cat >"$BT_WORK/nl.toml" <<'EOF'
[mcp_servers.node_repl.env]
NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = ""
EOF
  assert env CODEX_HOME="$SYNC_TEST_HOME" BROWSE_CODEX_CONFIG="$BT_WORK/nl.toml" PATH="$BT_WORK/bin:$PATH" \
    "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/nl-sync.out"
  python3 -c '
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
needle = "NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "
idx = text.find(needle)
assert idx >= 0, text
rest = text[idx + len(needle):].splitlines()[0]
got = json.loads(rest)
assert got == "line1\nquote \"here\" and \\slash", got
' "$BT_WORK/nl.toml"
  rc=0
  out=$(CODEX_HOME="$SYNC_TEST_HOME" BROWSE_CODEX_CONFIG="$BT_WORK/nl.toml" PATH="$BT_WORK/bin:$PATH" \
    "$ROOT/bin/codex-cua-repl-sync" --check) || rc=$?
  assert test "$rc" -eq 0
  assert test "$out" = 'unchanged'

  # 3: extra args/env keys are out of sync
  assert env CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >/dev/null
  python3 -c '
from pathlib import Path
p = Path("'"$SYNC_TEST_HOME"'/config.toml")
text = p.read_text()
sec = text.find("[mcp_servers.cua_repl]")
assert sec >= 0, text
idx = text.find("args = ", sec)
nxt = text.find("\n[", idx + 1)
if nxt < 0: nxt = len(text)
assert idx >= 0 and idx < nxt, text
end = text.find("]", idx)
text = text[:end] + ", \"stale-extra\"" + text[end:]
p.write_text(text)
'
  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null || rc=$?
  assert test "$rc" -eq 1
  assert env CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >/dev/null
  awk '
    /^[[:space:]]*\[mcp_servers\.cua_repl\.env\]/ { print; print "STALE_ENV_KEY = \"nope\""; next }
    { print }
  ' "$SYNC_TEST_HOME/config.toml" >"$BT_WORK/stale-env.toml"
  mv "$BT_WORK/stale-env.toml" "$SYNC_TEST_HOME/config.toml"
  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null || rc=$?
  assert test "$rc" -eq 1

  # 4: empty-array --check under bash 3.2 + set -u
  if [ -x /bin/bash ]; then
    rc=0
    CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" \
      /bin/bash "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null 2>"$BT_WORK/bash32.err" || rc=$?
    assert test "$rc" -ne 127
    assert test "$(grep -c 'unbound variable' "$BT_WORK/bash32.err")" -eq 0
  fi

  # 5: mcp add failure still writes TOML and does not remove first
  : >"$SYNC_LOG"
  cat >"$BT_WORK/bin/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SYNC_LOG"
exit 1
EOF
  chmod +x "$BT_WORK/bin/codex"
  jq '.mcpServers.cua_repl.args = ["/after-failed-add/launch.mjs"]' "$newer_manifest" >"$BT_WORK/fail-add-manifest"
  mv "$BT_WORK/fail-add-manifest" "$newer_manifest"
  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/fail-add.out" || rc=$?
  assert test "$rc" -eq 0
  assert test "$(grep -c 'mcp remove cua_repl' "$SYNC_LOG")" -eq 0
  assert grep -q 'mcp add cua_repl' "$SYNC_LOG"
  assert grep -qxF 'args = ["/after-failed-add/launch.mjs"]' "$SYNC_TEST_HOME/config.toml"

  # 6: missing Sky app → SKY: absent without polling; --vendor claudeb does not launch Sky
  cat >"$BT_WORK/bin/pgrep-dia" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in *Dia*) exit 0 ;; esac
done
exit 1
EOF
  chmod +x "$BT_WORK/bin/pgrep-dia"
  : >"$BT_WORK/open.log"
  cat >"$BT_WORK/bin/open-log" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BT_WORK/open.log"
exit 1
EOF
  chmod +x "$BT_WORK/bin/open-log"
  SECONDS=0
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-dia" BROWSE_OPEN="$BT_WORK/bin/open-log" BROWSE_SKIP_PROCESSES=0 \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse --vendor codex) || rc=$?
  assert test "$SECONDS" -lt 5
  assert grep -qx 'SKY: absent' <<<"$out"
  assert test "$(grep -c 'Computer Use' "$BT_WORK/open.log")" -eq 0
  mkdir -p "$BT_WORK/Codex Computer Use.app"
  : >"$BT_WORK/open.log"
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-dia" BROWSE_OPEN="$BT_WORK/bin/open-log" BROWSE_SKIP_PROCESSES=0 \
        BROWSE_SKY_APP="$BT_WORK/Codex Computer Use.app" \
        "$RUNNER" browse --vendor claudeb) || true
  assert grep -qx 'SKY: absent' <<<"$out"
  assert test "$(grep -c 'Computer Use' "$BT_WORK/open.log")" -eq 0

  # 12: Dia absent + failed launch → PLAN: none
  cat >"$BT_WORK/bin/pgrep-none" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$BT_WORK/bin/pgrep-none"
  SECONDS=0
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-none" BROWSE_OPEN="$BT_WORK/bin/open-log" BROWSE_SKIP_PROCESSES=0 \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse) || rc=$?
  assert test "$rc" -eq 2
  assert test "$SECONDS" -lt 20
  assert grep -qx 'DIA: absent' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  assert grep -qx 'REASON: dia not running' <<<"$out"
  assert test "$(grep -c '^PLAN: codex' <<<"$out")" -eq 0
  assert test "$(grep -c '^PLAN: claudeb' <<<"$out")" -eq 0

  # 7: prune preamble-*.md older than 24h
  mkdir -p "$BT_RUNS/browse"
  printf 'stale\n' >"$BT_RUNS/browse/preamble-old.md"
  touch -t 202001010000 "$BT_RUNS/browse/preamble-old.md"
  out=$("$RUNNER" browse)
  assert test ! -e "$BT_RUNS/browse/preamble-old.md"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert test -f "$preamble_path"

  # 9: start prune must not delete browse/
  mkdir -p "$BT_RUNS/codex-ancient-run" "$BT_RUNS/browse"
  printf '{}\n' >"$BT_RUNS/browse/devices.json"
  touch -t 202001010000 "$BT_RUNS/codex-ancient-run" "$BT_RUNS/browse" "$BT_RUNS/browse/devices.json" "$BT_RUNS/.prune"
  clear_stub
  export PICK_ACCOUNT=fast PICK_RC=0
  start_ok codex
  assert test -d "$BT_RUNS/browse"
  assert test -f "$BT_RUNS/browse/devices.json"
  assert test ! -d "$BT_RUNS/codex-ancient-run"

  # 10: dead pid lock is stolen
  mkdir -p "$BT_RUNS/browse/devices.lock.d"
  printf '99999999\n' >"$BT_RUNS/browse/devices.lock.d/pid"
  printf '{}\n' >"$BT_RUNS/browse/devices.json"
  out=$("$RUNNER" browse --record "$dev" com)
  assert grep -qx "RECORDED: $dev com" <<<"$out"
  assert jq -e --arg dev "$dev" '.[$dev].account == "com"' "$BT_RUNS/browse/devices.json" >/dev/null
  assert test ! -e "$BT_RUNS/browse/devices.lock.d"

  # 13: denied mapping orders that account last
  jq -n --arg dev "$dev" --arg seen "2026-09-01T00:00:00Z" \
    '{($dev): {account:"com", seen:$seen, denied:true}}' >"$cache"
  BROWSE_WORKER_PICK="$BT_WP.multi"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx "REASON: claudeb/com skipped — device $dev not visible (probe failed 2026-09-01T00:00:00Z)" <<<"$out"
  assert grep -qx 'NEXT-CLAUDE-ACCOUNTS: spare,com' <<<"$out"
  assert grep -qx "PLAN: claudeb account=spare device=$dev source=probe" <<<"$out"
  BROWSE_WORKER_PICK="$BT_WP"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF"

  # 14: ordinary runs do not mutate devices.json
  printf '{"com":{"account":"com","seen":"keep"}}\n' >"$cache"
  ordinary="$BT_RUNS/codex-ordinary"
  mkdir -p "$ordinary"
  printf '{"vendor":"codex","account":"main","workdir":"%s","started_at":0,"pid":0,"browser":false,"chrome":false}\n' \
    "$WORK/workdir" >"$ordinary/meta.json"
  : >"$ordinary/err"
  printf 'BROWSER-DEVICE-ACCOUNT: %s poisoned\n' "$dev" >"$ordinary/out"
  assert "$RUNNER" _deliver "$ordinary" 0 >/dev/null
  assert jq -e '.com.account == "com" and .com.seen == "keep"' "$cache" >/dev/null
  assert jq -e --arg dev "$dev" 'has($dev) | not' "$cache" >/dev/null

  # 15: pin-lapse note is not an account named pin; PINNED flag is not an account
  cat >"$BT_WP.pinned" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
claude:  pin com walled → extra
          8.6%/d ×7.0d   40%   30%   extra                opus·high
         11.4%/d ×7.0d   20%   20%   com                  opus·high PINNED
OUTPUT
EOF
  chmod +x "$BT_WP.pinned"
  BROWSE_WORKER_PICK="$BT_WP.pinned"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua"
  printf '{}\n' >"$cache"
  out=$("$RUNNER" browse --vendor claudeb)
  assert test "$(grep -c 'claudeb/pin ' <<<"$out")" -eq 0
  assert test "$(grep -c 'account=pin' <<<"$out")" -eq 0
  assert grep -qx 'NEXT-CLAUDE-ACCOUNTS: extra,com' <<<"$out"
  assert grep -qx "PLAN: claudeb account=extra device=$dev source=probe" <<<"$out"
  BROWSE_WORKER_PICK="$BT_WP"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF"

  # 16: --target chrome flips which device is drivable and which is off-target
  printf '{}\n' >"$cache"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua"
  out=$("$RUNNER" browse --target chrome --vendor claudeb)
  assert grep -qx 'TARGET: chrome' <<<"$out"
  assert grep -qx 'CHROME-DEVICE: b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d "Chrome browser"' <<<"$out"
  assert grep -qx 'DIA-DEVICE: 6ada21d4-ae66-4990-9040-97e18bb7b529 "Dia browser"' <<<"$out"
  assert grep -qx 'PLAN: claudeb account=com device=b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d source=probe' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert grep -qF 'Target Google Chrome device ID: b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d' "$preamble_path"
  assert grep -qF 'Off-target extension device IDs (Dia — never drive one, never `switch_browser` to it): ' "$preamble_path"
  assert grep -qF '6ada21d4-ae66-4990-9040-97e18bb7b529' "$preamble_path"
  assert grep -qxF -- '- Never drive Dia.' "$preamble_path"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF"
  out=$("$RUNNER" browse --target chrome --vendor codex)
  assert grep -qx 'PLAN: codex account=main' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert grep -q 'Codex / Google Chrome' "$preamble_path"
  assert grep -q 'profileName. is "Egor work"' "$preamble_path"
  assert grep -q 'WITHOUT a `profileName` is Dia' "$preamble_path"
  assert grep -q 'Never drive Dia' "$preamble_path"
  json_out=$("$RUNNER" browse --target chrome --vendor codex --json)
  assert test "$(jq -r .target <<<"$json_out")" = 'chrome'

  # 17: the default is a literal, and only dia|chrome are targets
  out=$("$RUNNER" browse --vendor codex)
  assert grep -qx 'TARGET: dia' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert test "$(grep -c 'Codex / Dia' "$preamble_path")" -eq 1
  for bad in opera '' --json; do
    rc=0
    "$RUNNER" browse --target "$bad" >/dev/null 2>&1 || rc=$?
    assert test "$rc" -eq 2
  done
  rc=0
  "$RUNNER" browse --target >/dev/null 2>&1 || rc=$?
  assert test "$rc" -eq 2
  clear_stub
  rc=0
  "$RUNNER" start codex --target chrome --brief "$WORK/brief" >/dev/null 2>&1 || rc=$?
  assert test "$rc" -eq 2
  assert test ! -s "$CALL_LOG"

  # 18: a closed target browser launches itself, in the background and without a URL
  : >"$BT_WORK/launch.log"
  cat >"$BT_WORK/bin/open-launch" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BT_WORK/launch.log"
cp "$BT_WORK/ps-connected" "$BT_PS_LISTING"
: >"$BT_WORK/launched.marker"
EOF
  chmod +x "$BT_WORK/bin/open-launch"
  cat >"$BT_WORK/bin/pgrep-marker" <<EOF
#!/bin/sh
test -e "$BT_WORK/launched.marker"
EOF
  chmod +x "$BT_WORK/bin/pgrep-marker"
  rm -f "$BT_WORK/launched.marker"
  : >"$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_OPEN="$BT_WORK/bin/open-launch" \
        BROWSE_SKIP_PROCESSES=0 BROWSE_LAUNCH_TIMEOUT=5 BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'LAUNCHED: dia' <<<"$out"
  assert grep -qx 'DIA: launched' <<<"$out"
  assert grep -qx -- '-g -a Dia' "$BT_WORK/launch.log"
  assert test "$(grep -c Chrome "$BT_WORK/launch.log")" -eq 0
  assert grep -q '^PLAN: claudeb ' <<<"$out"

  rm -f "$BT_WORK/launched.marker"
  : >"$BT_PS_LISTING"
  : >"$BT_WORK/launch.log"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_OPEN="$BT_WORK/bin/open-launch" \
        BROWSE_SKIP_PROCESSES=0 BROWSE_LAUNCH_TIMEOUT=5 BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse --target chrome --vendor claudeb) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'LAUNCHED: chrome' <<<"$out"
  assert grep -qx 'CHROME: launched' <<<"$out"
  assert grep -qF -- '--profile-directory=Profile 1' "$BT_WORK/launch.log"
  assert test "$(grep -c ' Dia' "$BT_WORK/launch.log")" -eq 0
  # Chrome's own claude host answers for it, so the wait ends instead of timing out.
  assert test "$(grep -c 'did not connect' <<<"$out")" -eq 0

  # 19: launched but the extension never connects — one instruction, and no plan
  cat >"$BT_WORK/bin/open-launch-mute" <<EOF
#!/bin/sh
cp "$BT_WORK/ps-chrome-bare" "$BT_PS_LISTING"
: >"$BT_WORK/launched.marker"
EOF
  chmod +x "$BT_WORK/bin/open-launch-mute"
  rm -f "$BT_WORK/launched.marker"
  : >"$BT_PS_LISTING"
  SECONDS=0
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_OPEN="$BT_WORK/bin/open-launch-mute" \
        BROWSE_SKIP_PROCESSES=0 BROWSE_LAUNCH_TIMEOUT=1 BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse --target chrome --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  assert test "$SECONDS" -lt 15
  assert grep -qx 'LAUNCHED: chrome' <<<"$out"
  assert grep -qx "REASON: Google Chrome launched but the Claude extension did not connect within 1s — open Google Chrome's extensions page and check the extension is enabled in Egor work" <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"

  # 20: a ChatGPT host under the other browser is not this target's transport
  cp "$BT_WORK/ps-chrome-bare" "$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_SKIP_PROCESSES=0 BROWSE_CHROME_STATUS=running \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" "$RUNNER" browse --target chrome --vendor codex) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'REASON: codex skipped — the ChatGPT extension is not connected in Google Chrome (Egor work); enable it at chrome://extensions and sign in' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  cp "$BT_WORK/ps-connected" "$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_SKIP_PROCESSES=0 BROWSE_CHROME_STATUS=running \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" "$RUNNER" browse --target chrome --vendor codex) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'PLAN: codex account=main' <<<"$out"
  assert test "$(grep -c 'ChatGPT extension is not connected' <<<"$out")" -eq 0

  # 20b: the same parentage the other way round — Chrome's ChatGPT host is not Dia's transport
  cat >"$BT_WORK/bin/pgrep-yes" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$BT_WORK/bin/pgrep-yes"
  cp "$BT_WORK/ps-dia-bare" "$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-yes" BROWSE_SKIP_PROCESSES=0 \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" "$RUNNER" browse --vendor codex) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'REASON: codex skipped — the ChatGPT extension is not connected in Dia (work dia); enable it at dia://extensions and sign in' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  cp "$BT_WORK/ps-connected" "$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-yes" BROWSE_SKIP_PROCESSES=0 \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" "$RUNNER" browse --vendor codex) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'PLAN: codex account=main' <<<"$out"
  assert test "$(grep -c 'ChatGPT extension is not connected' <<<"$out")" -eq 0

  # 21: a device no pool account can see is a sign-in instruction, never a plan
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua"
  cat >"$BT_WP.single" <<'EOF'
#!/bin/sh
printf 'claude: com\n'
EOF
  chmod +x "$BT_WP.single"
  jq -n --arg dev b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d --arg seen '2026-09-01T00:00:00Z' \
    '{($dev): {account:"com", seen:$seen, denied:true}}' >"$cache"
  rc=0
  out=$(BROWSE_WORKER_PICK="$BT_WP.single" "$RUNNER" browse --target chrome --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'REASON: sign in the Claude extension in Google Chrome (Egor work) as com — device b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d is visible to no pool account' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  rc=0
  out=$(BROWSE_WORKER_PICK="$BT_WP.multi" "$RUNNER" browse --target chrome --vendor claudeb) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'PLAN: claudeb account=spare device=b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d source=probe' <<<"$out"
  assert test "$(grep -c 'sign in the Claude extension' <<<"$out")" -eq 0
  printf '{}\n' >"$cache"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF"

}

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
tool_call() {
  jq -cn --arg name "$1" --arg key "$2" --arg path "$3" --arg id "${4-}" --arg ts "$TOOL_TS" \
    '{type: "assistant", timestamp: $ts,
      message: {content: [{type: "tool_use", name: $name, input: {($key): $path}}
      + (if $id == "" then {} else {id: $id} end)]}}'
}
attribution_repair_tests() {
  local repo="$WORK/attribution-repair" outside="$WORK/outside-repair" command variant report note
  eval "$(sed -n '/^writes_through_shell() {/,/^}/p' "$RUNNER")"
  parser_failure_is_unknown() (
    python3() { return 2; }
    writes_through_shell 'git diff'
  )
  assert parser_failure_is_unknown
  for command in 'python3 -c "rewrite()"' 'python3 -' 'tee target' 'perl -pi -e s/a/b/ target' \
      'git apply changes.patch' 'patch -p1' 'mv source target' 'cp source target' \
      'install source target' 'bash tests/../rewrite.sh' 'printf data >target' 'grep x source >target' \
      'sed -n "1p" -e "w target" source' 'bash -c "rewrite"' 'unknown-command' \
      'grep "unterminated' 'printf "$(rewrite)"' 'pnpm install >/dev/null 2>&1' \
      "node -e 'items.filter(x => x)'"; do
    assert writes_through_shell "$command"
  done
  for command in '' 'grep x source' 'sed -n "1,5p" source' 'git diff --stat' \
      'bash tests/test_worker_run.sh' 'git status --short 2>/dev/null' \
      'grep x source | head -n 3' 'git diff 2>&1' \
      "printf '%s' 'a >= b' 'x => x'"; do
    assert_fails writes_through_shell "$command"
  done
  clear_stub
  set_config 'claudeb_model=opus' 'claudeb_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc STUB_SLEEP=1
  mkdir -p "$repo/bin" "$outside" "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
  git -C "$repo" init -q
  printf 'base\n' >"$repo/bin/restored"
  git -C "$repo" add bin/restored
  git -C "$repo" -c user.name=fixture -c user.email=fixture@example.test commit -qm base
  repo=$(cd "$repo" && pwd -P)
  outside=$(cd "$outside" && pwd -P)
  for variant in readonly python sed bash unknown empty whitespace undated comment splitcalls unreadable missing namedonly shellonly; do
    [ -z "${WORKER_RUN_TEST_ATTRIBUTION_CASE:-}" ] || [ "$variant" = "$WORKER_RUN_TEST_ATTRIBUTION_CASE" ] || continue
    case "$variant" in
      readonly) command='grep base bin/restored; sed -n "1,5p" bin/restored; git diff; bash tests/run.sh' ;;
      python) command=$'python3 - <<\'EOF\'\nfrom pathlib import Path\nPath("bin/restored").write_text("base\\n")\nEOF' ;;
      sed) command='sed -i "" s/dirty/base/ bin/restored' ;;
      bash) command='bash -c "python3 rewrite.py"' ;;
      unknown) command='custom-rewriter bin/restored' ;;
      empty) command='' ;;
      whitespace) command='   ' ;;
      undated) command='grep base bin/restored' ;;
      comment) command=$'grep base bin/restored # inspected\npython3 -c "rewrite()"' ;;
      splitcalls) command="echo '" ;;
      unreadable|missing) command='git diff' ;;
      namedonly) command='python3 -c "rewrite()"' ;;
      shellonly) command=$'python3 - <<\'EOF\'\nfrom pathlib import Path\nPath("bin/restored").write_text("base\\n")\nEOF' ;;
    esac
    printf 'dirty\n' >"$repo/bin/restored"
    TOOL_TS=$(iso $(($(date +%s) + 60)))
    {
      [ "$variant" = shellonly ] || tool_call Edit file_path "$repo/bin/named"
      if [ "$variant" = undated ]; then
        tool_call Bash command "$command" | jq '.timestamp = "unparseable"'
      else
        tool_call Bash command "$command"
      fi
      [ "$variant" != splitcalls ] || tool_call Bash command "python3 -c rewrite #'"
    } >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
    case "$variant" in
      unreadable) printf 'not json\n' >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl" ;;
      missing) rm "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl" ;;
    esac
    if [ "$variant" = shellonly ]; then
      printf '#!/usr/bin/env bash\n%s\n' "$command" >"$STUB_DIR/relay_hook"
      chmod +x "$STUB_DIR/relay_hook"
    fi
    start_ok claudeb --workdir "$repo"
    [ "$variant" = namedonly ] || git -C "$repo" show HEAD:bin/restored >"$repo/bin/restored"
    [ "$variant" = shellonly ] || printf '%s\n' "$variant" >"$repo/bin/named"
    assert await_done
    rm -f "$STUB_DIR/relay_hook"
    if [ "$variant" = unreadable ] || [ "$variant" = missing ]; then
      assert_fails grep -qx bin/named "$RUN_DIR/files"
      assert_fails grep -q bin/named "$RUN_DIR/produced"
      assert grep -qx bin/named "$RUN_DIR/dirty"
      assert grep -qx bin/restored "$RUN_DIR/dirty"
      assert_fails grep -q 'snapshot stands\|another writer' "$RUN_DIR/files-note"
      assert "$RUNNER" claim "$RUN_ID" --paths bin/named bin/restored >/dev/null
      assert grep -qx bin/restored "$RUN_DIR/files"
      assert grep -q bin/restored "$RUN_DIR/produced"
      continue
    elif [ "$variant" = shellonly ]; then
      assert grep -qx base "$repo/bin/restored"
      assert_fails grep -qx bin/named "$RUN_DIR/files"
    else
      assert grep -qx bin/named "$RUN_DIR/files"
      assert grep -q bin/named "$RUN_DIR/produced"
    fi
    assert bash -c '! grep -qx "$1" "$2"' \
      'rule change: restoring a co-tenant path does not establish ownership' bin/restored "$RUN_DIR/files"
    assert_fails grep -q bin/restored "$RUN_DIR/produced"
    if [ "$variant" = namedonly ]; then
      assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
      assert test ! -e "$RUN_DIR/dirty"
      continue
    fi
    if [ "$variant" = readonly ]; then
      note="1 path(s) changed in the checkout during the run by another writer and are not this run's: bin/restored"
      assert_fails grep -q '^PARTIAL: ' "$RUN_DIR/files"
      assert test ! -e "$RUN_DIR/dirty"
    else
      note="1 path(s) changed in the run's window that its own listing does not name and nobody answers for (the run also ran shell commands, whose edits no transcript records): bin/restored"
      assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
      assert grep -qx bin/restored "$RUN_DIR/dirty"
      assert_fails grep -qx bin/named "$RUN_DIR/dirty"
      assert_fails grep -q 'another writer' "$RUN_DIR/files-note"
    fi
    assert grep -qxF "$note" "$RUN_DIR/files-note"
    report=$("$RUNNER" report "$RUN_ID")
    assert grep -qxF "RUN-FILES-NOTE: $note" <<<"$report"
    if [ "$variant" != readonly ]; then
      assert grep -q "^UNNAMED: .*worker-run claim $RUN_ID" <<<"$report"
      assert "$RUNNER" claim "$RUN_ID" --paths bin/restored >/dev/null
      assert grep -qx bin/restored "$RUN_DIR/files"
      assert grep -q bin/restored "$RUN_DIR/produced"
    fi
  done
  for variant in outside outside_dotdot outside_only; do
    [ -z "${WORKER_RUN_TEST_ATTRIBUTION_CASE:-}" ] || [ "$variant" = "$WORKER_RUN_TEST_ATTRIBUTION_CASE" ] || continue
    git -C "$outside" init -q
    printf 'before\n' >"$outside/edited"
    git -C "$outside" add edited
    git -C "$outside" -c user.name=fixture -c user.email=fixture@example.test commit -qm base
    TOOL_TS=$(iso $(($(date +%s) + 60)))
    {
      [ "$variant" = outside_only ] || tool_call Edit file_path "$repo/bin/named"
      if [ "$variant" = outside_dotdot ]; then
        tool_call Edit file_path "$repo/../outside-repair/edited"
      else
        tool_call Edit file_path "$outside/edited"
      fi
      tool_call Edit file_path "$repo/../outside-repair/second"
    } >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
    start_ok claudeb --workdir "$repo"
    [ "$variant" = outside_only ] || printf 'inside %s\n' "$variant" >"$repo/bin/named"
    printf 'after\n' >"$outside/edited"
    printf 'after\n' >"$outside/second"
    printf 'co-tenant\n' >"$repo/bin/outside-cotenant"
    assert await_done
    if [ "$variant" = outside_only ]; then
      assert_fails grep -qx bin/named "$RUN_DIR/files"
      assert test ! -s "$RUN_DIR/produced"
    else
      assert grep -qx bin/named "$RUN_DIR/files"
      assert grep -q bin/named "$RUN_DIR/produced"
    fi
    note="UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: $outside/edited"
    assert grep -qxF "$note" "$RUN_DIR/files-note"
    assert grep -qxF "RUN-FILES-NOTE: $note" <<<"$("$RUNNER" report "$RUN_ID")"
    note="UNKNOWN: transcript names a write outside the snapshotted repository; no content baseline was recorded: $outside/second"
    assert grep -qxF "$note" "$RUN_DIR/files-note"
    assert grep -qxF "RUN-FILES-NOTE: $note" <<<"$("$RUNNER" report "$RUN_ID")"
    assert grep -q '^PARTIAL: .*outside the snapshotted repository' "$RUN_DIR/files"
    assert_fails grep -q '^UNKNOWN: ' "$RUN_DIR/files"
    assert_fails grep -q "$outside/edited" "$RUN_DIR/produced"
    assert test ! -e "$RUN_DIR/dirty"
    assert_fails grep -q bin/outside-cotenant "$RUN_DIR/produced"
  done
}

if [ "${WORKER_RUN_TEST_ATTRIBUTION_ONLY:-0}" = 1 ]; then
  attribution_repair_tests
  printf 'PASS: %s attribution repair asserts\n' "$asserts"
  exit 0
fi

model_effort_tests
if [ "${WORKER_RUN_TEST_MODEL_EFFORT_ONLY:-0}" = 1 ]; then
  printf 'PASS %s\n' "$asserts"
  exit 0
fi

browse_tests
if [ "${WORKER_RUN_TEST_BROWSE_ONLY:-0}" = 1 ]; then
  printf 'PASS: %s browse asserts\n' "$asserts"
  exit 0
fi

reliability_tests
if [ "${WORKER_RUN_TEST_RELIABILITY_ONLY:-0}" = 1 ]; then
  printf 'PASS: %s reliability asserts\n' "$asserts"
  exit 0
fi

clear_stub
set_config 'codex_effort=high'
export PICK_ACCOUNT=fast PICK_RC=0 STUB_SLEEP=2
SECONDS=0
start_ok codex
assert test "$SECONDS" -lt 2
assert test "$(wc -l <"$WORK/start.out" | tr -d ' ')" -eq 4
assert grep -Eq '^RUN: codex-[0-9]+-[0-9]+-[0-9a-f]{4}$' "$WORK/start.out"
assert grep -qx 'TAG: fast · astra · high' "$WORK/start.out"
assert grep -qx 'WEB: off' "$WORK/start.out"
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
printf 'server.go:1017] Created conversation relaunched-conversation\n' >>"$RUN_DIR/log"
assert grep -q '^SESSION: relaunched-conversation$' <<<"$("$RUNNER" report "$RUN_ID")"
printf 'printmode.go:174] Print mode: starting (conversationID="resumed-conversation")\n' >>"$RUN_DIR/log"
assert grep -q '^SESSION: resumed-conversation$' <<<"$("$RUNNER" report "$RUN_ID")"

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
  assert jq -e 'has("pinned") | not' "$RUN_DIR/meta.json" >/dev/null
  assert await_done

  clear_stub
  export PICK_ACCOUNT=ignored PICK_RC=2
  start_ok "$vendor"
  assert meta_account_is pinned
  assert jq -e 'has("pinned") | not' "$RUN_DIR/meta.json" >/dev/null
  assert await_done
done

# A light edit asks the picker under the `light` role, so `<vendor>_workers=off` closes neither
# door it passes: not the picker's, and not worker-run's own wall over the resolved vendor.
clear_stub
set_config 'light_edit=claudeb:sonnet' 'claudeb_workers=off' 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_ACCOUNT=picked PICK_RC=0
# A Light edit launches under the SCOPE/VERIFY contract and inside a worktree off the workdir's
# HEAD, so it needs a repository with a commit; tests/test_light_edit.sh owns that contract.
light_workdir="$WORK/light-workdir"
mkdir -p "$light_workdir"
git -C "$light_workdir" init -q
printf 'base\n' >"$light_workdir/file"
git -C "$light_workdir" add file
git -C "$light_workdir" -c user.name=fixture -c user.email=fixture@example.test commit -qm base
printf 'SCOPE: file\ntest brief\nsecond line\n' >"$WORK/brief"
WORKER_TEST_WORKDIR="$light_workdir" start_ok light
printf 'test brief\nsecond line\n' >"$WORK/brief"
assert meta_account_is picked
assert grep -qx -- '--account claudeb --role light --claim' "$PICK_LOG"
assert jq -e '.model == "sonnet" and .light == "edit"' "$RUN_DIR/meta.json" >/dev/null
assert await_done

# With Light off (Egor's menu) there is no light leg: `start light` is refused before any account is
# asked, and research is a plain run on the vendor's own default model, off the light row or not.
clear_stub
set_config 'light_paused=on' 'light_edit=claudeb:sonnet' 'light_research=gemini' 'claudeb_model=opus' 'claudeb_effort=high'
: >"$PICK_LOG"
printf 'SCOPE: file\ntest brief\n' >"$WORK/brief"
rc=0
WORKER_TEST_WORKDIR="$light_workdir" "$RUNNER" start light --brief "$WORK/brief" --workdir "$light_workdir" \
  >"$WORK/lightoff.out" 2>"$WORK/lightoff.err" || rc=$?
assert test "$rc" -ne 0
assert grep -qx 'OUTCOME: LIGHT_OFF' "$WORK/lightoff.out"
assert test ! -s "$PICK_LOG"
printf 'test brief\nsecond line\n' >"$WORK/brief"
start_ok claudeb --role research
assert jq -e '.model == "opus" and (has("light") | not)' "$RUN_DIR/meta.json" >/dev/null
assert await_done

# The Light write sandbox never receives $HOME as a root. gemini's main account IS the real HOME
# (shared-invariants row `m`), so it is granted the agy state directory a named profile's own home
# holds anyway — the shape codex and grok main already have.
clear_stub
set_config 'light_edit=gemini:flash38' 'gemini_model=flash38' 'gemini_effort=high'
export PICK_ACCOUNT=main PICK_RC=0
printf 'SCOPE: file\ntest brief\n' >"$WORK/brief"
WORKER_TEST_WORKDIR="$light_workdir" start_ok light
printf 'test brief\nsecond line\n' >"$WORK/brief"
home_real=$(cd "$HOME" && pwd -P)
assert meta_account_is main
assert_fails grep -qF "(subpath \"$home_real\")" "$RUN_DIR/light-sandbox.sb"
assert grep -qF "(subpath \"$home_real/.gemini\")" "$RUN_DIR/light-sandbox.sb"
assert await_done
export PICK_ACCOUNT=picked

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
  assert grep -qx DONE "$RUN_DIR/outcome"
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
  assert test "$(tail -n1 "$WORKER_RUN_DIR/prelaunch.jsonl" | jq -r '"\(.outcome) \(.vendor)"')" = \
    "$(tr '[:lower:]' '[:upper:]' <<<"$vendor")_USAGE_LIMIT $vendor"
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

# A vendor pin (`*`) covers every pool account the limits store carries, and a chat's own pin file
# replaces the global pin for that session — both open the role wall exactly like an account pin.
printf '%s\n' '{"vendors":{"codex":{"available":true,"accounts":[{"account":"explicit"},{"account":"other"}]}}}' \
  >"$HOME/.llm-limits.json"
clear_stub
set_config 'codex_workers=off' 'codex_profile=*' 'codex_effort=medium'
export PICK_ACCOUNT=ignored PICK_RC=2
start_ok codex --account explicit
assert meta_account_is explicit
assert await_done
clear_stub
rc=0
"$RUNNER" start codex --brief "$WORK/brief" --account ghost \
  >"$WORK/role-star.out" 2>"$WORK/role-star.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'codex is switched off for workers' "$WORK/role-star.err"
mkdir -p "$CHAT_PINS_DIR"
printf 'codex_profile=other\n' >"$CHAT_PINS_DIR/chat-pin-test"
set_config 'codex_workers=off' 'codex_profile=explicit' 'codex_effort=medium'
clear_stub
rc=0
CLAUDE_CODE_SESSION_ID=chat-pin-test "$RUNNER" start codex --brief "$WORK/brief" --account explicit \
  >"$WORK/role-chat.out" 2>"$WORK/role-chat.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'codex is switched off for workers' "$WORK/role-chat.err"
clear_stub
CLAUDE_CODE_SESSION_ID=chat-pin-test start_ok codex --account other
assert meta_account_is other
assert await_done
# «воркер на все» (open=all) opens the switched-off vendor to a named account in that chat alone.
printf 'open=all
' >"$CHAT_PINS_DIR/chat-open-all"
set_config 'codex_workers=off' 'codex_effort=medium'
clear_stub
CLAUDE_CODE_SESSION_ID=chat-open-all start_ok codex --account explicit
assert meta_account_is explicit
assert await_done
clear_stub
rc=0
CLAUDE_CODE_SESSION_ID=chat-pin-test "$RUNNER" start codex --brief "$WORK/brief" --account explicit   >"$WORK/role-open.out" 2>"$WORK/role-open.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'codex is switched off for workers' "$WORK/role-open.err"
rm -rf "$CHAT_PINS_DIR" "$HOME/.llm-limits.json"

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
# Every Gemini leg runs high: an effort below it is RAISED with one note on stderr, never refused,
# and an effort above it is the same word for the same tier.
for forced in low medium xhigh max; do
  clear_stub
  start_ok gemini --account main --model flash38 --effort "$forced"
  assert meta_agy_is 'gemini-3.8-flash-high'
  assert grep -qx 'gemini effort forced to high' "$WORK/start.err"
  assert await_done
done
# The knob is raised the same way the flag is.
clear_stub
set_config 'gemini_model=flash38' 'gemini_effort=low'
start_ok gemini --account main
assert meta_agy_is 'gemini-3.8-flash-high'
assert await_done
set_config 'gemini_model=flash38' 'gemini_effort=high'
# The other families and Pro, each at the one effort they run.
for pair in 'flash37:gemini-3.7-flash-high' 'flash36:gemini-3.6-flash-high' 'pro:gemini-3.1-pro-high'; do
  clear_stub
  start_ok gemini --account main --model "${pair%%:*}"
  assert meta_agy_is "${pair#*:}"
  assert await_done
done
# No model named anywhere: the newest Flash family is the default, never `pro` however new it is.
clear_stub
set_config 'gemini_effort=high'
assert test "$(bash -c '. "$1"; worker_model_default_model gemini' _ "$ROOT/share/worker-model.sh")" = flash38
start_ok gemini --account main
assert meta_agy_is 'gemini-3.8-flash-high'
assert await_done
set_config 'gemini_model=flash38' 'gemini_effort=high'
# A word the table knows nothing of is a typo, and a typo is still refused rather than raised.
for bad_effort in ultra tiny; do
  clear_stub
  rc=0
  "$RUNNER" start gemini --brief "$WORK/brief" --account main --model flash38 --effort "$bad_effort" >"$WORK/reject.out" 2>&1 || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/reject.out"
  assert test ! -s "$CALL_LOG"
done
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
start_ok codex --account resumeacct --resume codex-resume --model astra --effort low
assert grep -qx 'TAG: resumeacct · astra · low' "$WORK/start.out"
assert await_done
assert grep -q '^ARG=resume$' "$CALL_LOG"
assert grep -q '^ARG=-m$' "$CALL_LOG"
assert grep -q '^ARG=gpt-6.1-astra$' "$CALL_LOG"
assert grep -q '^ARG=model_reasoning_effort=low$' "$CALL_LOG"

# Fast Mode is per account and has to reach the worker launch, not only the menu: codexb writes
# the marker, and every codex command line is the only place a tier can still be applied.
clear_stub
mkdir -p "$HOME/.codex-profiles/.codexb/fast-mode"
printf 'fast\n' >"$HOME/.codex-profiles/.codexb/fast-mode/fastacct"
start_ok codex --account fastacct
assert await_done
assert grep -qxF 'ARG=--enable' "$CALL_LOG"
assert grep -qxF 'ARG=fast_mode' "$CALL_LOG"
assert grep -qxF 'ARG=service_tier=\"priority\"' "$CALL_LOG"

# OpenAI switches Fast per account and model in the catalog: switched on here but not listed there,
# the run goes standard and says so; listed again, it is Fast again with nobody touching the switch.
clear_stub
mkdir -p "$CODEX_PROFILES_DIR/fastacct"
jq '.models |= map(del(.service_tiers))' "$CODEXB_MODELS_CACHE" >"$CODEX_PROFILES_DIR/fastacct/models_cache.json"
start_ok codex --account fastacct
assert await_done
assert test "$(grep -c '^ARG=service_tier=' "$CALL_LOG")" -eq 1
assert grep -qxF 'ARG=service_tier=\"default\"' "$CALL_LOG"
assert grep -q 'OpenAI offers no Fast for gpt-6.1-astra on fastacct' "$WORK/start.err"
clear_stub
jq '.models |= map(.service_tiers = [{"id": "priority", "name": "Fast"}])' "$CODEXB_MODELS_CACHE" \
  >"$CODEX_PROFILES_DIR/fastacct/models_cache.json"
start_ok codex --account fastacct
assert await_done
assert grep -qxF 'ARG=service_tier=\"priority\"' "$CALL_LOG"
assert_fails grep -q 'offers no Fast' "$WORK/start.err"
rm -r "$CODEX_PROFILES_DIR/fastacct"

clear_stub
printf 'default\n' >"$HOME/.codex-profiles/.codexb/fast-mode/fastacct"
start_ok codex --account fastacct
assert await_done
assert grep -qxF 'ARG=service_tier=\"default\"' "$CALL_LOG"

clear_stub
printf 'garbage\n' >"$HOME/.codex-profiles/.codexb/fast-mode/fastacct"
start_ok codex --account fastacct
assert await_done
assert test "$(grep -c '^ARG=service_tier=' "$CALL_LOG")" -eq 1
assert grep -qxF 'ARG=service_tier=\"default\"' "$CALL_LOG"

clear_stub
start_ok codex --account resumeacct
assert await_done
assert test "$(grep -c '^ARG=service_tier=' "$CALL_LOG")" -eq 1
assert grep -qxF 'ARG=service_tier=\"default\"' "$CALL_LOG"

# `chat-pin codex-fast` outranks the account's standing switch for the runs of this chat alone, and
# travels to the detached supervisor in meta.json.
clear_stub
mkdir -p "$CHAT_PINS_DIR"
printf 'codex_profile=*\ncodex_fast=on\n' >"$CHAT_PINS_DIR/chat-codex-fast"
CLAUDE_CODE_SESSION_ID=chat-codex-fast start_ok codex --account resumeacct
assert test "$(jq -r '.fast' "$RUN_DIR/meta.json")" = true
assert await_done
assert grep -qxF 'ARG=--enable' "$CALL_LOG"
assert grep -qxF 'ARG=fast_mode' "$CALL_LOG"
assert grep -qxF 'ARG=service_tier=\"priority\"' "$CALL_LOG"
assert test "$(grep -c '^ARG=service_tier=' "$CALL_LOG")" -eq 1
rm -f "$CHAT_PINS_DIR/chat-codex-fast"
rm -r "$HOME/.codex-profiles/.codexb/fast-mode"

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

clear_stub
export PICK_RC=0 PICK_ACCOUNT=servedacct
export STUB_MODEL_USAGE='{"claude-haiku-4-5-20251001":{"outputTokens":500},"claude-opus-4-8":{"outputTokens":43}}'
start_ok claudeb
assert await_done
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = claude-opus-4-8

# Codex: the rollout's last turn_context model, or the server's reroute after it.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=servedcodex
printf '%s\n' '{"type":"session_meta","payload":{}}' '{"type":"turn_context","payload":{"model":"gpt-6.1-astra"}}' \
  '{"type":"event_msg","payload":{"type":"model_reroute","from_model":"gpt-6.1-astra","to_model":"gpt-6-astra"}}' \
  >"$STUB_DIR/codex_rollout"
start_ok codex
assert await_done
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = gpt-6-astra
assert grep -qx 'SERVED: gpt-6-astra' <<<"$("$RUNNER" report "$RUN_ID")"
clear_stub
export PICK_ACCOUNT=servedcodex2
printf '%s\n' '{"type":"turn_context","payload":{"model":"gpt-6.1-astra"}}' >"$STUB_DIR/codex_rollout"
start_ok codex
assert await_done
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = gpt-6.1-astra
rm -f "$STUB_DIR/codex_rollout"

# Gemini: the last backend override label in agy's log.
clear_stub
export STUB_GEMINI_LABEL='Gemini 3.8 Flash (High)'
start_ok gemini --account main
assert await_done
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = 'Gemini 3.8 Flash (High)'
assert grep -qx 'SERVED: Gemini 3.8 Flash (High)' <<<"$("$RUNNER" report "$RUN_ID")"

# A family word is resolved again on the account the attempt runs on: its own list, not the
# machine-wide newest one.
clear_stub
saved_models_cache=$CODEXB_MODELS_CACHE
unset CODEXB_MODELS_CACHE
mkdir -p "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/otherlist"
jq '.client_version = "0.156.1" | .fetched_at = "2026-09-23T00:00:00.000000Z"' "$saved_models_cache" \
  >"$HOME/.codex-profiles/ownlist/models_cache.json"
jq '.client_version = "0.156.1" | .fetched_at = "2026-09-24T00:00:00.000000Z" | .models |= map(select(.slug != "gpt-6.1-astra"))' \
  "$saved_models_cache" >"$HOME/.codex-profiles/otherlist/models_cache.json"
export PICK_RC=0 PICK_ACCOUNT=ownlist
start_ok codex --model astra
assert await_done
assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
assert test "$(jq -r '.model_id' "$RUN_DIR/meta.json")" = gpt-6.1-astra
rm -r "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/otherlist"
export CODEXB_MODELS_CACHE=$saved_models_cache

# The launch line resolves on the account too, not only the supervisor: Fast is judged on the slug
# the account really runs, and a family only the picked account lists is no refusal.
clear_stub
unset CODEXB_MODELS_CACHE
mkdir -p "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/otherlist" "$HOME/.codex-profiles/.codexb/fast-mode"
jq '.client_version = "0.156.1" | .fetched_at = "2026-09-23T00:00:00.000000Z"
    | .models |= map(if .slug == "gpt-6.1-astra" then .service_tiers = [{"id": "priority", "name": "Fast"}] else . end)' \
  "$saved_models_cache" >"$HOME/.codex-profiles/ownlist/models_cache.json"
jq '.client_version = "0.156.1" | .fetched_at = "2026-09-24T00:00:00.000000Z" | .models |= map(select(.slug != "gpt-6.1-astra"))' \
  "$saved_models_cache" >"$HOME/.codex-profiles/otherlist/models_cache.json"
printf 'fast\n' >"$HOME/.codex-profiles/.codexb/fast-mode/ownlist"
export PICK_RC=0 PICK_ACCOUNT=ownlist
start_ok codex --model astra
assert_fails grep -q 'offers no Fast' "$WORK/start.err"
assert jq -e 'any(.cmd[]; . == "gpt-6.1-astra")' "$RUN_DIR/meta.json"
assert await_done
assert grep -qxF 'ARG=service_tier=\"priority\"' "$CALL_LOG"
clear_stub
jq '.models |= map(select(.slug | test("astra") | not))' "$saved_models_cache" \
  | jq '.client_version = "0.156.1" | .fetched_at = "2026-09-24T00:00:00.000000Z"' >"$HOME/.codex-profiles/otherlist/models_cache.json"
start_ok codex --model astra
assert await_done
assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
clear_stub
start_ok codex --model astra --account ownlist
assert await_done
assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
rm -r "$HOME/.codex-profiles/ownlist" "$HOME/.codex-profiles/otherlist" "$HOME/.codex-profiles/.codexb/fast-mode/ownlist"
export CODEXB_MODELS_CACHE=$saved_models_cache

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
assert grep -qx 'HINT: this run edited nothing — a read-only lookup is cheaper on the light-research agent (see ~/.claude/CLAUDE.md, Model routing); read-only relay runs this month: 1' <<<"$report"
assert test -f "$RUN_DIR/report-readonly"

clear_stub
export PICK_RC=0 PICK_ACCOUNT=readonly-two STUB_TRANSCRIPT_SESSION=readonly-two STUB_SESSION=readonly-two
export STUB_TRANSCRIPT_ACCOUNT=readonly-two
start_ok claudeb
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'HINT: this run edited nothing — a read-only lookup is cheaper on the light-research agent (see ~/.claude/CLAUDE.md, Model routing); read-only relay runs this month: 2' <<<"$report"
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
printf 'SCOPE: file\ntest brief\nsecond line\n' >"$WORK/brief"
WORKER_TEST_WORKDIR="$light_workdir" start_ok light
printf 'test brief\nsecond line\n' >"$WORK/brief"
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
start_ok codex --model astra
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert test "$(grep -c '^ARG=-m$' "$CALL_LOG")" -eq 1
assert test "$(grep -c '^ARG=gpt-6.1-astra$' "$CALL_LOG")" -eq 1
assert jq -e '.model_flag_dropped == true' "$RUN_DIR/meta.json" >/dev/null
assert_launched_brief "$STUB_DIR/codex.stdin"

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
start_ok codex --model astra
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
  "$ROOT/share/web-search.sh" "$WORK/share/"
[ -e "$WORK/bin/codexb" ] || ln -s "$ROOT/bin/codexb" "$WORK/bin/codexb"
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
export STUB_MODEL_USAGE='{"opus":{"canonicalModel":"claude-opus-5-5"},"claude-haiku-4-5-20251001":{"outputTokens":5}}'
: >"$STUB_DIR/claudeb_drop_effort"
start_ok claudeb
assert await_done
assert test "$(grep -c '^CLAUDEB_CALL$' "$CALL_LOG")" -eq 2
assert test "$(grep -c '^ARG=--effort$' "$CALL_LOG")" -eq 1
assert jq -e '.effort_flag_dropped == true' "$RUN_DIR/meta.json" >/dev/null
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = claude-opus-5-5

report=$("$RUNNER" report "$RUN_ID")
assert test "$(head -n1 <<<"$report")" = 'ACCOUNT: effortacct (claudeb)'
assert test "$(sed -n 2,3p <<<"$report")" = $'MODEL: opus·high\nSERVED: claude-opus-5-5'
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

transcript_report() (
  local directory="$1" name workdir count
  local SCRIPT_DIRECTORY="$ROOT/bin" gemini_base_home="$HOME" gemini_profiles_dir="$GEMINIB_PROFILES_DIR"
  . "$ROOT/share/gemini-accounts.sh"
  for name in compute_transcript_files session_id session_transcript codex_home grok_home \
      grok_end_field grok_session_dir_matches classify_tool_rows resolve_tool_path \
      writes_through_shell gemini_tool_rows codex_tool_rows grok_tool_rows transcript_files \
      transcript_wrote_through_shell workdir_escape_line; do
    eval "$(sed -n "/^$name() {/,/^}/p" "$RUNNER")"
  done
  eval "$(sed -n '/^SHELL_FLOOR_PARTIAL=/p' "$RUNNER")"
  compute_transcript_files "$directory"
  workdir=$(jq -r '.workdir' "$directory/meta.json")
  { printf 'WORKDIR: %s\n' "$workdir"
    [ -z "$RUN_FILES_REASON" ] || printf 'UNKNOWN: %s\n' "$RUN_FILES_REASON"
    [ -z "$RUN_FILES_PARTIAL" ] || printf 'PARTIAL: %s\n' "$RUN_FILES_PARTIAL"
    [ -z "$RUN_FILES_LIST" ] || printf '%s\n' "$RUN_FILES_LIST"
  } >"$WORK/transcript-files"
  workdir_escape_line "$directory"
  if [ -n "$RUN_FILES_REASON" ]; then
    printf 'RUN-FILES: unknown (%s)\n' "$RUN_FILES_REASON"
  elif [ -z "$RUN_FILES_LIST" ]; then
    printf 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)\n'
  else
    printf 'WORKDIR: %s\n' "$workdir"
    count=$(grep -c . <<<"$RUN_FILES_LIST")
    printf 'RUN-FILES: %s\n' "$count"
    sed 's/^/RUN-FILE: /' <<<"$RUN_FILES_LIST"
  fi
  [ -z "$RUN_FILES_PARTIAL" ] || printf 'RUN-FILES-PARTIAL: %s\n' "$RUN_FILES_PARTIAL"
  return 0
)

assert grep -qx 'RUN-FILES: unknown (no session transcript for claude-session)' \
  <<<"$(transcript_report "$RUN_DIR")"
mkdir -p "$CLAUDEB_PROFILES_ROOT/effortacct/projects/fixture"
run_workdir=$(jq -r '.workdir' "$RUN_DIR/meta.json")
run_started=$(jq -r '.started_at' "$RUN_DIR/meta.json")
# Milliseconds on purpose: that is what a real transcript writes, and jq's own fromdateiso8601
# refuses them — a fixture stamped to the whole second would pass over the parse this depends on.
tool_error() {
  jq -cn --arg id "$1" --arg ts "$TOOL_TS" \
    '{type: "user", timestamp: $ts, message: {content: [{type: "tool_result", tool_use_id: $id,
      is_error: true, content: "permission denied"}]}}'
}
TOOL_TS=$(iso $((run_started + 1)))
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
report=$(transcript_report "$RUN_DIR")
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
report=$(transcript_report "$RUN_DIR")
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
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 2' <<<"$report"
assert grep -qx 'RUN-FILE: bin/at-start' <<<"$report"
assert grep -qx 'RUN-FILE: bin/this-run' <<<"$report"
assert test "$(grep -c 'pre-resume' <<<"$report")" -eq 0

# Nothing recorded is not "nothing changed": an edit made through the shell — `sed -i`, a redirect,
# `mv` — appears in no transcript as a tool call, so the zero says what it actually counted.
: >"$TRANSCRIPT"
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"
# Nothing to resolve, so nothing to resolve it against: a bare WORKDIR line over a count that names
# no file reads as a directory this run is claiming.
assert test "$(grep -c '^WORKDIR: ' <<<"$(transcript_report "$RUN_DIR")")" -eq 0

# A transcript jq cannot parse is unknown, never 0: the pipeline used to swallow the parse failure
# and report an authoritative "changed nothing" about a run nobody could read.
printf 'not json {\n' >"$TRANSCRIPT"
assert grep -qx 'RUN-FILES: unknown (transcript unreadable)' <<<"$(transcript_report "$RUN_DIR")"

# A run whose transcript cannot be found says so; a silent 0 would read as a run that changed
# nothing. Every vendor answers here now, so the reason names the missing rollout and no longer
# claims the vendor keeps no record at all.
clear_stub
set_config 'codex_effort=high'
export PICK_RC=0 PICK_ACCOUNT=filesacct
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (no session transcript for codex-session)' \
  <<<"$(transcript_report "$RUN_DIR")"

# The record and launcher mapping exist even when the workdir cannot be snapshotted.
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $(jq -r '.workdir' "$RUN_DIR/meta.json")"
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert test "$(cat "$RUN_DIR/worker-session")" = codex-session
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc
mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
start_ok claudeb
assert await_done
assert test "$(cat "$RUN_DIR/launcher")" = chat-abc
assert test "$(cat "$STUB_DIR/launcher_env")" = chat-abc
# The task row's state file ends where the run ended, rounds counted by the waits.
assert jq -e '.phase == "done" and .exit_code == 0 and .session == "chat-abc" and .account == "recordacct"
  and .model == "opus" and .effort == "high" and .round >= 1 and (.started_epoch | type) == "number"' \
  "$RUN_DIR/state.json" >/dev/null
assert test "$(cat "$RUN_DIR/worker-session")" = claude-session
printf 'walled-session\n' >>"$RUN_DIR/worker-session"
"$RUNNER" _supervise "$RUN_DIR" >/dev/null 2>&1
assert test "$(grep -c . "$RUN_DIR/worker-session")" -eq 2
assert_fails grep -q '^PARTIAL: ' "$RUN_DIR/files"

# Started inside a relay agent, the run claims the tag file its launch marked in the LAUNCHER's tag
# cache — the main chat's, not the session id the worker process journals under — and every
# transition rewrites the state the task row reads.
clear_stub
export STUB_SLEEP=2
TR_TAGS="$HOME/.cache/claude-worker-tags/chat-main"
mkdir -p "$TR_TAGS"
printf 'seed · opus · high\nstart=%s\nedit=1\n' "$(date +%s)" >"$TR_TAGS/agent-x"
printf 'other · opus · high\nstart=%s\n' "$(($(date +%s) - 600))" >"$TR_TAGS/agent-stale"
CLAUDE_LAUNCHER_SESSION=chat-main start_ok claudeb
assert test "$(cat "$RUN_DIR/launcher")" = chat-main
assert jq -e --arg run "$RUN_ID" '.phase == "start" and .round == 0 and .agent_task_id == "agent-x" and .session == "chat-main"' \
  "$RUN_DIR/state.json" >/dev/null
assert test "$(head -n1 "$TR_TAGS/agent-x")" = "recordacct · opus · high"
assert test "$(grep -c '^start=' "$TR_TAGS/agent-x")" = 0
assert grep -qx "run=$RUN_ID" "$TR_TAGS/agent-x"
assert grep -qx 'edit=1' "$TR_TAGS/agent-x"
assert grep -q '^start=' "$TR_TAGS/agent-stale"
"$RUNNER" wait "$RUN_ID" --max 0 >/dev/null
assert jq -e '.phase == "wait" and .round == 1 and .agent_task_id == "agent-x"' "$RUN_DIR/state.json" >/dev/null
assert await_done
assert jq -e '.phase == "done" and .exit_code == 0 and .round >= 2' "$RUN_DIR/state.json" >/dev/null
unset STUB_SLEEP
# Two launches of one chat claiming at once take two rows, never the newest one twice; the sed shim
# widens the read-then-swap window so the race is not left to timing.
RACE_TAGS="$HOME/.cache/claude-worker-tags/chat-race"
mkdir -p "$RACE_TAGS" "$WORK/race-a" "$WORK/race-b" "$WORK/slow-sed"
printf 'a · opus · high\n' >"$WORK/race-a/tag"
printf 'b · opus · high\n' >"$WORK/race-b/tag"
printf 'a · opus · high\nstart=%s\n' "$(($(date +%s) - 5))" >"$RACE_TAGS/agent-old"
printf 'b · opus · high\nstart=%s\n' "$(date +%s)" >"$RACE_TAGS/agent-new"
printf '#!/bin/bash\nsleep 0.5\nexec /usr/bin/sed "$@"\n' >"$WORK/slow-sed/sed"
chmod +x "$WORK/slow-sed/sed"
claim_race() (
  eval "$(sed -n '/^claim_agent_tag() {/,/^}/p' "$RUNNER")"
  eval "$(sed -n '/^claim_agent_tag_locked() {/,/^}/p' "$RUNNER")"
  PATH="$WORK/slow-sed:$PATH"
  unset CLAUDE_AGENT_ID
  claim_agent_tag "$1" chat-race
)
claim_race "$WORK/race-a" & race_a=$!
claim_race "$WORK/race-b" & race_b=$!
wait "$race_a" "$race_b"
assert test "$(cat "$WORK/race-a/agent-task" "$WORK/race-b/agent-task" | sort | tr '\n' ,)" = 'agent-new,agent-old,'
assert test ! -e "$RACE_TAGS/.claim.lock"
# A launch that outwaits a live holder leaves that holder's lock alone; a lock a dead holder left
# more than a minute ago is cleared on the way in.
printf 'c · opus · high\nstart=%s\n' "$(date +%s)" >"$RACE_TAGS/agent-live"
mkdir "$RACE_TAGS/.claim.lock"
claim_race "$WORK/race-a"
assert test -d "$RACE_TAGS/.claim.lock"
touch -t 202001010000 "$RACE_TAGS/.claim.lock"
claim_race "$WORK/race-b"
assert test ! -e "$RACE_TAGS/.claim.lock"

clear_stub
DIRT_REPO="$WORK/dirt-repo"
mkdir -p "$DIRT_REPO/bin" "$DIRT_REPO/tests"
git -C "$DIRT_REPO" init -q .
printf 'original\n' >"$DIRT_REPO/bin/shell-edited"
printf 'original\n' >"$DIRT_REPO/tests/tracked-by-the-editor"
printf 'original\n' >"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
git -C "$DIRT_REPO" add -A >/dev/null
git -C "$DIRT_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
printf 'egor was here\n' >>"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
DIRT_TOP=$(cd "$DIRT_REPO" && pwd -P)
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor"
  tool_call Bash command 'sed -i "" s/original/rewritten/ bin/shell-edited'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'rewritten\n' >"$DIRT_REPO/bin/shell-edited"
printf 'rewritten\n' >"$DIRT_REPO/tests/tracked-by-the-editor"
printf 'brand new\n' >"$DIRT_REPO/bin/created-through-a-redirect"
mkdir -p "$DIRT_REPO/notes"
printf 'brand new\n' >"$DIRT_REPO/notes/inside-an-untracked-directory"
assert await_done
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $DIRT_TOP"
assert grep -qx 'tests/tracked-by-the-editor' "$RUN_DIR/files"
# What the shell wrote, no record of this run names: a snapshot says a file moved, never who moved
# it, and in a shared checkout the difference is another chat's live work. They are the dirt record's
# until the launching chat claims them — nobody's, rather than invented as this run's.
assert_fails grep -qx 'bin/shell-edited' "$RUN_DIR/files"
assert grep -qx 'bin/shell-edited' "$RUN_DIR/dirty"
assert grep -qx 'bin/created-through-a-redirect' "$RUN_DIR/dirty"
assert grep -qx 'notes/inside-an-untracked-directory' "$RUN_DIR/dirty"
assert_fails grep -qx 'notes/' "$RUN_DIR/dirty"
assert_fails grep -qx 'tests/tracked-by-the-editor' "$RUN_DIR/dirty"
assert_fails grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/files"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/x/y/ bin/the-co-tenant-was-already-editing-this' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'the run rewrote it\n' >>"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
assert await_done
# The floor still SEES a rewrite of a file that was already dirty at launch — that is what the
# launch-time shas are for — it just answers for it as nobody's rather than as this run's.
assert grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/dirty"
assert_fails grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/files"
assert_fails grep -qx 'bin/somebody-elses-file' "$RUN_DIR/files"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'and again\n' >"$DIRT_REPO/bin/somebody-elses-file"
assert await_done
assert test "$(grep -c '^PARTIAL: ' "$RUN_DIR/files")" -eq 0
assert test ! -e "$RUN_DIR/dirty"

# The contract in a checkout other chats are working in RIGHT NOW: the snapshot holds every path
# that moved in the run's window, and only the run's own listing says which of them the run wrote.
# Handed the rest, the launching chat inherits a co-tenant's live work as its own review debt —
# live 2026-09-11, a run that edited 2 files was charged with 8.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$DIRT_TOP/tests/edited-by-the-run" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'the run wrote this\n' >"$DIRT_REPO/tests/edited-by-the-run"
printf 'a co-tenant wrote this\n' >"$DIRT_REPO/bin/written-by-a-co-tenant"
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: tests/edited-by-the-run' <<<"$report"
assert test "$(grep -c '^RUN-FILE: ' <<<"$report")" -eq 1
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert_fails grep -q 'written-by-a-co-tenant' "$RUN_DIR/produced"
assert grep -qxF "1 path(s) changed in the checkout during the run by another writer and are not this run's: bin/written-by-a-co-tenant" \
  "$RUN_DIR/files-note"
# The snapshot did NOT stand here, and saying it did is what sent the co-tenant's paths through.
assert_fails grep -q 'snapshot attribution stands' "$RUN_DIR/files-note"

# A worker that merely RAN something — its own suite — named every file it wrote. Doubted there,
# every serious run is back to claiming the whole window.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$DIRT_TOP/tests/edited-by-the-run"
  tool_call Bash command 'bash tests/run.sh'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'the run wrote this again\n' >"$DIRT_REPO/tests/edited-by-the-run"
printf 'a co-tenant wrote this again\n' >"$DIRT_REPO/bin/written-by-a-co-tenant"
assert await_done
report=$("$RUNNER" report "$RUN_ID")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: tests/edited-by-the-run' <<<"$report"
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert_fails grep -q 'snapshot attribution stands' "$RUN_DIR/files-note"

# And a Bash call that WRITES is the one case the listing cannot be trusted to be whole: it is a
# FLOOR, so what it names is still this run's and the rest of the window is attributed to NOBODY.
# Handed the rest, the run owns whatever a co-tenant wrote beside it (Egor, 2026-09-12: a snapshot
# detects changes, not their author), and the launching chat can only claim what it recognises.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$DIRT_TOP/tests/edited-by-the-run"
  tool_call Bash command 'sed -i "" s/a/b/ bin/written-by-a-co-tenant'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'once more\n' >"$DIRT_REPO/tests/edited-by-the-run"
printf 'once more\n' >"$DIRT_REPO/bin/written-by-a-co-tenant"
assert await_done
assert grep -qx 'tests/edited-by-the-run' "$RUN_DIR/files"
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert_fails grep -q 'written-by-a-co-tenant' "$RUN_DIR/produced"
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert_fails grep -q 'snapshot attribution stands' "$RUN_DIR/files-note"
assert grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/dirty"
assert_fails grep -qx 'tests/edited-by-the-run' "$RUN_DIR/dirty"
report=$("$RUNNER" report "$RUN_ID")
assert grep -q "^UNNAMED: .*worker-run claim $RUN_ID" <<<"$report"
assert grep -q 'written-by-a-co-tenant' <<<"$report"
# And the launching chat says which of them were its worker's: a claim names the path and the
# record answers for its content again.
assert "$RUNNER" claim "$RUN_ID" --paths bin/written-by-a-co-tenant >/dev/null
assert grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert grep -q 'written-by-a-co-tenant' "$RUN_DIR/produced"
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/dirty"

# An unreadable listing cannot turn the snapshot into evidence of ownership.
clear_stub
export STUB_SLEEP=1
printf 'not json at all\n' >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$DIRT_REPO"
printf 'unreadable\n' >"$DIRT_REPO/tests/edited-by-the-run"
printf 'unreadable\n' >"$DIRT_REPO/bin/written-by-a-co-tenant"
assert await_done
assert_fails grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/files"
assert_fails grep -qx 'tests/edited-by-the-run' "$RUN_DIR/files"
assert grep -qx 'bin/written-by-a-co-tenant' "$RUN_DIR/dirty"
assert grep -qx 'tests/edited-by-the-run' "$RUN_DIR/dirty"
assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert grep -q '^transcript cross-check unavailable: ' "$RUN_DIR/files-note"
assert grep -q 'changed paths remain unnamed' "$RUN_DIR/files-note"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Bash command 'sed -i "" s/rewritten/again/ bin/shell-edited'
  tool_call Edit file_path "$DIRT_TOP/tests/named-from-a-subdirectory"
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO/tests"
printf 'from a subdirectory\n' >"$DIRT_REPO/bin/edited-from-a-subdirectory"
printf 'from a subdirectory\n' >"$DIRT_REPO/tests/named-from-a-subdirectory"
assert await_done
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $DIRT_TOP/tests"
assert grep -qx 'named-from-a-subdirectory' "$RUN_DIR/files"
assert_fails grep -qx 'tests/named-from-a-subdirectory' "$RUN_DIR/files"
# The listing spells a path against the WORKDIR, the dirt record against the repository TOP, and
# the unattributed rest of the window is the difference between the two spellings of one set.
assert_fails grep -qxF "$DIRT_TOP/bin/edited-from-a-subdirectory" "$RUN_DIR/files"
assert grep -qx 'bin/edited-from-a-subdirectory' "$RUN_DIR/dirty"
assert_fails grep -qx 'tests/named-from-a-subdirectory' "$RUN_DIR/dirty"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/again/once more/ bin/shell-edited' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
assert test -e "$RUN_DIR/dirty-before"
rm -f "$RUN_DIR/dirty-before-shas"
printf 'nobody measured the floor\n' >"$DIRT_REPO/bin/without-a-floor"
assert await_done
assert test ! -e "$RUN_DIR/dirty"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ somewhere' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb
assert await_done
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/dirty"
assert test ! -e "$RUN_DIR/dirty-before"

snapshot_shell_tests() {
  local vendor path frozen variant note
  for vendor in claudeb codex gemini grok; do
    clear_stub
    set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=high' 'gemini_model=flash38' 'gemini_effort=high' 'grok_effort=high'
    printf 'recordacct\n' >"$STUB_DIR/gemini_profiles"
    export SNAPSHOT_DELETED="$DIRT_REPO/bin/shell-deleted-$vendor"
    export SNAPSHOT_TOUCHED="$DIRT_REPO/bin/shell-touched-$vendor"
    printf 'delete this\n' >"$SNAPSHOT_DELETED"
    printf 'keep this\n' >"$SNAPSHOT_TOUCHED"
    git -C "$DIRT_REPO" add "bin/shell-deleted-$vendor" "bin/shell-touched-$vendor"
    git -C "$DIRT_REPO" -c user.name=fixture -c user.email=fixture@example.test commit -qm 'shell attribution fixture'
    cat >"$STUB_DIR/relay_hook" <<'EOF'
#!/usr/bin/env bash
printf 'shell content\n' >"$SNAPSHOT_TARGET"
rm "$SNAPSHOT_DELETED"
touch "$SNAPSHOT_TOUCHED"
EOF
    chmod +x "$STUB_DIR/relay_hook"
    export SNAPSHOT_TARGET="$DIRT_REPO/bin/shell-only-$vendor"
    # The hook above writes through the SHELL, and claudeb is the one vendor here whose transcript
    # this suite writes: without the Bash call that did it, its listing reads as complete and the
    # snapshot narrows to nothing — which is the whole point of the shell floor.
    if [ "$vendor" = claudeb ]; then
      TOOL_TS=$(iso $(($(date +%s) + 600)))
      tool_call Bash command 'printf "shell content\n" >bin/shell-only-claudeb; rm bin/shell-deleted-claudeb' \
        >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
    fi
    start_ok "$vendor" --workdir "$DIRT_REPO"
    assert await_done
    path="bin/shell-only-$vendor"
    assert_fails grep -qx "$path" "$RUN_DIR/files"
    assert grep -qx "$path" "$RUN_DIR/dirty"
    assert grep -qx "bin/shell-deleted-$vendor" "$RUN_DIR/dirty"
    assert_fails grep -q "bin/shell-touched-$vendor" "$RUN_DIR/dirty"
    assert grep -q '^PARTIAL: ' "$RUN_DIR/files"
    assert "$RUNNER" claim "$RUN_ID" --paths "$path" "bin/shell-deleted-$vendor" >/dev/null
    assert grep -qx "$path" "$RUN_DIR/files"
    assert grep -q "$path" "$RUN_DIR/produced"
    assert grep -qx "bin/shell-deleted-$vendor" "$RUN_DIR/files"
    assert grep -q $'\t-\t'"bin/shell-deleted-$vendor"'$' "$RUN_DIR/produced"
    assert_fails grep -q "bin/shell-touched-$vendor" "$RUN_DIR/files"
    assert_fails grep -q "bin/shell-touched-$vendor" "$RUN_DIR/produced"
    assert_fails grep -q '^UNKNOWN: ' "$RUN_DIR/files"
    assert test ! -e "$RUN_DIR/dirty"
    frozen=$(cat "$RUN_DIR/produced")
    printf 'later content\n' >"$SNAPSHOT_TARGET"
    assert grep -qx "RUN-FILE: $path" <<<"$("$RUNNER" report "$RUN_ID")"
    assert "$RUNNER" claim "$RUN_ID" --paths "$path" >/dev/null
    assert test "$(cat "$RUN_DIR/produced")" = "$frozen"
    assert_fails "$RUNNER" claim "$RUN_ID" --paths "bin/shell-touched-$vendor" >"$WORK/snapshot-claim.out" 2>&1
    assert grep -q "not in this run's snapshot diff" "$WORK/snapshot-claim.out"
    rm -f "$STUB_DIR/relay_hook"
  done
  unset SNAPSHOT_TARGET SNAPSHOT_DELETED SNAPSHOT_TOUCHED
  for variant in cotenant unnamed; do
    clear_stub
    set_config 'claudeb_model=opus' 'claudeb_effort=high'
    export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc STUB_SLEEP=1
    mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
    printf 'co-tenant dirty\n' >"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
    TOOL_TS=$(iso $(($(date +%s) + 60)))
    {
      tool_call Edit file_path "$DIRT_TOP/tests/tracked-by-the-editor"
      [ "$variant" = cotenant ] ||
        tool_call Bash command 'sed -i "" s/a/b/ bin/shell-edited'
    } >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
    start_ok claudeb --workdir "$DIRT_REPO"
    git -C "$DIRT_REPO" show HEAD:bin/the-co-tenant-was-already-editing-this \
      >"$DIRT_REPO/bin/the-co-tenant-was-already-editing-this"
    assert await_done
    assert bash -c '! grep -qx "$1" "$2"' \
      'rule change: restoring a co-tenant path does not establish ownership' \
      'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/files"
    assert_fails grep -q 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/produced"
    if [ "$variant" = cotenant ]; then
      note="1 path(s) changed in the checkout during the run by another writer and are not this run's: bin/the-co-tenant-was-already-editing-this"
      assert test ! -e "$RUN_DIR/dirty"
    else
      note="1 path(s) changed in the run's window that its own listing does not name and nobody answers for (the run also ran shell commands, whose edits no transcript records): bin/the-co-tenant-was-already-editing-this"
      assert grep -qx 'bin/the-co-tenant-was-already-editing-this' "$RUN_DIR/dirty"
    fi
    assert grep -qxF "$note" "$RUN_DIR/files-note"
    assert grep -qxF "RUN-FILES-NOTE: $note" <<<"$("$RUNNER" report "$RUN_ID")"
  done
  clear_stub
}
snapshot_shell_tests

clear_stub
INITIAL_REPO="$WORK/initial-repo"
mkdir -p "$INITIAL_REPO"
INITIAL_REPO=$(cd "$INITIAL_REPO" && pwd -P)
git -C "$INITIAL_REPO" init -q
export STUB_SLEEP=1
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Write file_path "$INITIAL_REPO/initial" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
start_ok claudeb --workdir "$INITIAL_REPO"
printf 'initial content\n' >"$INITIAL_REPO/initial"
git -C "$INITIAL_REPO" add initial
git -C "$INITIAL_REPO" -c user.name=fixture -c user.email=fixture@example.test commit -qm initial
assert await_done
assert grep -qx initial "$RUN_DIR/files"
assert grep -qxF -- $'-\t'"$(git -C "$INITIAL_REPO" rev-parse HEAD:initial)"$'\tinitial\tcommit' "$RUN_DIR/produced"

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
printf 'orig\n' >"$PROD_REPO/bin/committed-open"
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
printf 'egor was here\n' >"$PROD_REPO/bin/committed-open"
printf 'egor was here\n' >"$PROD_REPO/$PROD_ESC"
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$PROD_TOP/bin/modified"
  tool_call Write file_path "$PROD_TOP/bin/born"
  tool_call Edit file_path "$PROD_TOP/bin/deleted"
  tool_call Edit file_path "$PROD_TOP/bin/untouched"
  tool_call Edit file_path "$PROD_TOP/bin/co-tenant-open"
  tool_call Edit file_path "$PROD_TOP/$PROD_ESC"
  tool_call Edit file_path "$PROD_TOP/bin/committed"
  tool_call Edit file_path "$PROD_TOP/bin/committed-open"
  tool_call Write file_path "$PROD_TOP/bin/committed-born"
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc STUB_SLEEP=1
start_ok claudeb --workdir "$PROD_REPO"
# The commit the tree stood on when the run was launched, written before the CLI takes a token: read
# at the end instead, every link the run committed would be measured against its own result.
assert test "$(cat "$RUN_DIR/head-before")" = "$PROD_BASE"
printf 'two\n' >"$PROD_REPO/bin/modified"
printf 'born\n' >"$PROD_REPO/bin/born"
rm -f "$PROD_REPO/bin/deleted"
touch "$PROD_REPO/bin/untouched"
printf 'the worker rewrote it\n' >"$PROD_REPO/bin/co-tenant-open"
printf 'the worker rewrote it\n' >"$PROD_REPO/$PROD_ESC"
printf 'after\n' >"$PROD_REPO/bin/committed"
printf 'the worker rewrote it\n' >"$PROD_REPO/bin/committed-open"
printf 'landed\n' >"$PROD_REPO/bin/committed-born"
git -C "$PROD_REPO" add bin/committed bin/committed-born bin/committed-open >/dev/null
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
assert_fails grep -qx 'bin/untouched' "$RUN_DIR/files"
assert grep -qx 'bin/deleted' "$RUN_DIR/files"
assert test -f "$RUN_DIR/dirty-after-shas"
assert test "$(cat "$RUN_DIR/head-after")" = "$(git -C "$PROD_REPO" rev-parse HEAD)"
assert_fails grep -q '^UNKNOWN: \|^PARTIAL: ' "$RUN_DIR/files"
# The commits the run made, in the transitions git prints for them, marked so the reader can apply
# the first-row-wins rule that a cherry-picked blob needs and an edit does not.
assert grep -qxF -- "$(blob_of before)$tab$(blob_of after)${tab}bin/committed${tab}commit" "$RUN_DIR/produced"
assert grep -qxF -- "-$tab$(blob_of landed)${tab}bin/committed-born${tab}commit" "$RUN_DIR/produced"
assert grep -qxF -- "$(blob_of 'egor was here')$tab$(blob_of 'the worker rewrote it')${tab}bin/committed-open" "$RUN_DIR/produced"
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
assert grep -qx 'bin/claimed-content' "$RUN_DIR/dirty"
assert "$RUNNER" claim "$RUN_ID" --paths bin/claimed-content >/dev/null
assert grep -qxF -- "-$tab$(blob_of 'claimed content')${tab}bin/claimed-content" "$RUN_DIR/produced"
# APPENDED, never recomputed: the rows already standing were measured when the run ended, and a
# fresh pass over the record now dates whatever a co-tenant has done since to this run.
printf 'a co-tenant moved it on\n' >"$PROD_REPO/bin/claimed-content"
assert "$RUNNER" claim "$RUN_ID" --paths bin/claimed-content >/dev/null
assert grep -qxF -- "-$tab$(blob_of 'claimed content')${tab}bin/claimed-content" "$RUN_DIR/produced"
assert test "$(grep -cF 'bin/claimed-content' "$RUN_DIR/produced")" -eq 1


legacy_claim_record() {
  local path
  printf 'WORKDIR: %s\nPARTIAL: legacy transcript listing\n' "$(jq -r '.workdir' "$RUN_DIR/meta.json")" >"$RUN_DIR/files"
  printf 'WORKDIR: %s\n' "$DIRT_TOP" >"$RUN_DIR/dirty"
  for path in "$@"; do printf '%s\n' "$path" >>"$RUN_DIR/dirty"; done
  rm -f "$RUN_DIR/dirty-after-shas" "$RUN_DIR/head-after"
  "$RUNNER" wait "$RUN_ID" --max 0 >"$WORK/wait.out"
}

# --- Naming what the run could not name -----------------------------------------------------------
# A run that worked through the shell lists nothing and its work is owned by nobody. The launching
# chat is the one reader who knows which of the paths that changed in the run's window are its
# worker's, so `wait` prints them and `claim` records the answer.
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Bash command 'sed -i "" s/a/b/ bin/claimed-one' \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export CLAUDE_CODE_SESSION_ID=chat-abc
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'through the shell\n' >"$DIRT_REPO/bin/claimed-one"
printf 'through the shell\n' >"$DIRT_REPO/bin/claimed-two"
assert await_done
legacy_claim_record 'bin/claimed-one' 'bin/claimed-two'
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
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'through the shell\n' >"$DIRT_REPO/bin/named with a space"
assert await_done
legacy_claim_record 'bin/named with a space'
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
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO/tests"
printf 'through the shell\n' >"$DIRT_REPO/bin/claimed-from-a-subdirectory"
assert await_done
legacy_claim_record 'bin/claimed-from-a-subdirectory'
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
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
printf 'through the shell\n' >"$DIRT_REPO/bin/still-unnamed"
assert await_done
legacy_claim_record 'bin/still-unnamed'
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
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO"
for capped in one two three; do
  printf 'through the shell\n' >"$DIRT_REPO/bin/capped-$capped"
done
assert await_done
legacy_claim_record 'bin/capped-one' 'bin/capped-two' 'bin/capped-three'
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
export STUB_SLEEP=1
start_ok claudeb --workdir "$DIRT_REPO/tests"
for capped in one two three; do
  printf 'through the shell\n' >"$DIRT_REPO/bin/capped-sub-$capped"
done
assert await_done
legacy_claim_record 'bin/capped-sub-one' 'bin/capped-sub-two' 'bin/capped-sub-three'
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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 2' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-written' <<<"$report"
assert grep -qxF "RUN-FILE: $WORK/outside/agy-absolute" <<<"$report"
# A file the run only READ is not a file it changed, and every listed path is one somebody will be
# asked to review.
assert test "$(grep -c 'agy-only-read' <<<"$report")" -eq 0
# A read-only shell command does not spoil the list, but any shell at all makes the list a floor —
# the same sentence claudeb's own runs carry, since it is the same fact about a transcript.
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"
assert grep -qx 'bin/agy-written' "$WORK/transcript-files"
assert test "$(grep -c '^UNKNOWN: ' "$WORK/transcript-files")" -eq 0
assert test ! -e "$RUN_DIR/workdir-escape"

# Relative tool targets are anchored to the run workdir before both rendering and escape detection.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
agy_write write_to_file 'bin/agy-relative' >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"
assert grep -qx 'UNKNOWN: the run wrote through the shell, whose targets no transcript names' \
  "$WORK/transcript-files"
# And no path stands beside the UNKNOWN: half a list read as the whole of one is the claim the
# fail-closed rule exists to refuse.
assert test "$(grep -c 'agy-written' "$WORK/transcript-files")" -eq 0

# Numbered and ampersand redirects open files too, so every supported fd spelling spoils the list.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell 'printf one 1>one; printf two 2>two; printf three 3>three; printf all &>all' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A redirect to a file descriptor or to /dev/null writes no file. Counted as a write it made every
# `2>/dev/null` in a read-only review run unanswerable, which is most of them.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell 'grep pattern file >/dev/null 2>&1; git diff 2>&1 | head -20; rg -n pattern . 2>/dev/null' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 1' <<<"$(transcript_report "$RUN_DIR")"

# The /dev/null exception ends at the device name; a similarly prefixed file is still a write.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell 'printf hidden >/dev/null.log' "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Comparison and arrow operators are not redirects; the shell still makes this exact editor list a floor.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
{
  agy_write write_to_file "$agy_workdir/bin/agy-written"
  agy_shell "printf '%s' 'a >= b' 'x => x'" "$agy_workdir"
} >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: generate_image)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A write whose target the transcript leaves empty is the same refusal.
clear_stub
AGY_TS=$(agy_iso $(($(date +%s) + 60)))
agy_row "$AGY_TS" write_to_file '{"CodeContent": "x"}' >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a write whose target it does not name)' \
  <<<"$(transcript_report "$RUN_DIR")"

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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/agy-at-the-start' <<<"$report"
unset STUB_SLEEP

# A syntactically valid mutating row with no usable time cannot be silently excluded from the run.
clear_stub
AGY_TS=not-a-timestamp
agy_write write_to_file "$agy_workdir/bin/agy-unparseable-time" >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a mutating context with an unparseable timestamp)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A transcript jq cannot parse is unknown, never 0.
clear_stub
printf 'not json {\n' >"$AGY_TRANSCRIPT"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (transcript unreadable)' <<<"$(transcript_report "$RUN_DIR")"

# No transcript at all — an agy too old to keep one, a conversation id the log never printed, a
# profile that is not where it was looked for — is unknown too, and never the workdir.
clear_stub
mv "$AGY_TRANSCRIPT" "$AGY_TRANSCRIPT.moved"
start_ok gemini
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (no session transcript for gemini-conversation)' \
  <<<"$(transcript_report "$RUN_DIR")"
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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
report=$(transcript_report "$RUN_DIR")
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
transcript_report "$RUN_DIR" >/dev/null
assert test ! -e "$RUN_DIR/workdir-escape"
assert test "$(grep -c '^WORKDIR-ESCAPE: ' <<<"$(transcript_report "$RUN_DIR")")" -eq 0

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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 4' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-patched' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-moved-from' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-moved-to' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-from-the-patch-text' <<<"$report"
assert test "$(grep -c 'cx-patch-failed' <<<"$report")" -eq 0
assert test "$(grep -c 'cx-patch-text-failed' <<<"$report")" -eq 0
assert test "$(grep -c 'cx-no-event-failed' <<<"$report")" -eq 0
assert grep -q '^RUN-FILES-PARTIAL: the run also ran shell commands' <<<"$report"
assert grep -qx 'bin/cx-patched' "$WORK/transcript-files"

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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 4' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-patched' <<<"$report"
assert grep -qxF 'RUN-FILE: bin/cost$report.txt' <<<"$report"
assert grep -qxF 'RUN-FILE: bin/cost$.txt' <<<"$report"
assert grep -qxF 'RUN-FILE: bin/cost`report.txt' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*cx-from-a-variable' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*cx-from-a-brace' <<<"$report"
assert_fails grep -q '^RUN-FILE: .*cx-from-a-backtick' <<<"$report"
assert test "$(grep -v '^WORKDIR: \|^UNKNOWN: \|^PARTIAL: ' "$WORK/transcript-files" | grep -c 'cx-from-a-')" -eq 0
# The text itself, so a reader can see what the transcript could not resolve.
assert grep -qx 'RUN-FILES-PARTIAL: the run named a target the transcript cannot resolve: $cx_workdir/bin/cx-from-a-variable' <<<"$report"
assert grep -qx 'PARTIAL: the run named a target the transcript cannot resolve: $cx_workdir/bin/cx-from-a-variable' "$WORK/transcript-files"
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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Single quotes and backticks are string literals like any other, and a call spelled with them reads.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "await tools.exec_command({cmd:'git status',workdir:'$cx_workdir'}); await tools.exec_command({cmd:\`git status\`,workdir:\`$cx_workdir\`});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# An interpolated template literal names no command this reader can read, and fails closed.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "const verb = 'status'; const cmd = \`git \${verb}\`; await tools.exec_command({cmd, workdir:'$cx_workdir'});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: exec_command arguments)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Shorthand resolves by NAME against the binding standing before the call, so an explicit value and a
# shorthand one interleaved each keep their own command; taking them in two blocks paired the second
# call with the first binding, and its `sed` spoiled a run that never wrote through the shell.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "var cmd = \"sed -i '' s/a/b/ bin/cx-not-this-one\"; await tools.exec_command({cmd: 'git status'}); var cmd = 'cat bin/cx-read-only'; await tools.exec_command({cmd});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# The same binding serves every shorthand call that follows it, however many there are.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "const cmd = 'git status --short'; await tools.exec_command({cmd}); await tools.exec_command({cmd});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A shorthand name with no binding before it resolves to nothing at all.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "await tools.exec_command({cmd}); const cmd = 'git status';" >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: exec_command arguments)' \
  <<<"$(transcript_report "$RUN_DIR")"

# workdir resolves per call the same way: the shorthand of the second call is the directory bound
# before IT, and reading the first binding instead put every command outside the workdir.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "var workdir = '$WORK/extra'; await tools.exec_command({cmd: 'git status', workdir: '$WORK/extra'}); var workdir = '$cx_workdir'; await tools.exec_command({cmd: 'ls', workdir});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert test ! -e "$RUN_DIR/workdir-escape"
assert test "$(grep -c '^WORKDIR-ESCAPE: ' <<<"$(transcript_report "$RUN_DIR")")" -eq 0

# Tool-looking text in strings and comments is not an executed call.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec $'await tools.view_image({path:"fixture.png"}); const note = "tools.fs_write()"; // tools.js()' \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Direct function-call arguments must be a JSON object, not prose containing field-shaped text.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_call exec_command "arbitrary text cmd: \"git status\", workdir: \"$cx_workdir\"" >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: exec_command arguments)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Bare JavaScript object keys are the dominant exec_command rollout form and use the same shell rule.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_exec "const r = await tools.exec_command({cmd:\"sed -i '' s/a/b/ bin/cx-bare-shell\",workdir:\"$cx_workdir\"}); text(r.output);"
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# JavaScript shorthand arguments resolve through their string bindings.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
cx_exec "const cmd = \"git status --short\"; const workdir = \"$cx_workdir\"; await tools.exec_command({cmd, workdir, yield_time_ms:10000});" \
  >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

# Bytes typed into a shell a previous call started are read as a command line like any other.
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_call write_stdin '{"session_id":1,"chars":"cat header > bin/cx-typed-in\n"}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

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
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: js)' \
  <<<"$(transcript_report "$RUN_DIR")"
clear_stub
CX_TS=$(iso $(($(date +%s) + 60)))
{
  cx_patch_event "$cx_workdir/bin/cx-patched" '' true
  cx_row '{"type": "mcp_tool_call_end", "invocation": {"server": "s", "tool": "fs.write"}}'
} >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: fs.write)' \
  <<<"$(transcript_report "$RUN_DIR")"

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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
assert grep -qx 'RUN-FILES: 1' <<<"$report"
assert grep -qx 'RUN-FILE: bin/cx-at-the-start' <<<"$report"
unset STUB_SLEEP

# Codex mutating rows with unusable timestamps fail closed just like Gemini rows.
clear_stub
CX_TS=not-a-timestamp
cx_patch_event "$cx_workdir/bin/cx-unparseable-time" '' true >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a mutating context with an unparseable timestamp)' \
  <<<"$(transcript_report "$RUN_DIR")"

# An unusable timestamp on a classified read-only call remains read-only.
clear_stub
CX_TS=not-a-timestamp
cx_call view_image '{"path":"fixture.png"}' >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: 0 (editor tool calls only; shell edits are not tracked)' \
  <<<"$(transcript_report "$RUN_DIR")"

assert grep -E '^\| am \|.*record_workdir_escape.*workdir_escape_line' "$ROOT/docs/shared-invariants.md" >/dev/null

clear_stub
printf 'not json {\n' >"$CX_ROLLOUT"
start_ok codex
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (transcript unreadable)' <<<"$(transcript_report "$RUN_DIR")"
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

# A resumed session stays on its account: the session lives there, so the WALL line says so
# rather than sending the orchestrator hunting a pool that was never consulted.
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export STUB_CODE=9 STUB_ERROR='usage limit reached'
start_ok claudeb --account pinacct --resume resumed-session
assert await_done
assert grep -qx 'OUTCOME: CLAUDEB_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: resumed session stays on pinacct' "$WORK/wait.out"
assert test "$(grep -c '^REROUTE:' "$WORK/wait.out")" -eq 0
assert test ! -s "$PICK_LOG"

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
  STUB_TRANSCRIPT_ACCOUNT=picked STUB_EDIT_PATH=bin/the-worker-is-mid-edit WORKER_RUN_IDLE_S=3 WORKER_RUN_DEADLINE=600
start_ok claudeb --workdir "$DIRT_REPO"
unset STUB_SLEEP STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT WORKER_RUN_IDLE_S WORKER_RUN_DEADLINE
unset STUB_EDIT_PATH
assert test ! -e "$RUN_DIR/files"
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
assert grep -qx term "$RUN_DIR/killed"
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

# An explicit --account is spent first, then the pool: a wall moves the same brief on.
clear_stub
set_config 'codex_effort=high'
printf 'pinnedacct\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 rescue3' >"$STUB_DIR/pick_queue"
start_ok codex --account pinnedacct
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME:' "$WORK/wait.out")" -eq 0
assert meta_account_is rescue3
assert jq -e '.walled_accounts == ["pinnedacct"]' "$RUN_DIR/meta.json" >/dev/null
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 2
assert grep -qx -- '--account codex --claim --exclude pinnedacct' "$PICK_LOG"
assert grep -qx 'REROUTE: walled on pinnedacct → continued on rescue3' "$WORK/wait.out"
assert test -f "$WORKER_WALLS_DIR/codex-pinnedacct"
wall_epoch=$(sed -n 1p "$WORKER_WALLS_DIR/codex-pinnedacct" | tr -d '[:space:]')
now=$(date +%s)
assert test "$wall_epoch" -ge $((now + 3600 - 30))
assert test "$wall_epoch" -le $((now + 3600 + 30))

# Pin fallback is the same rule: spent first, then the pool.
clear_stub
set_config 'codex_effort=high' 'codex_profile=pinacct'
printf 'pinacct\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '2' '0 rescue4' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert meta_account_is rescue4
assert jq -e '.walled_accounts == ["pinacct"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'REROUTE: walled on pinacct → continued on rescue4' "$WORK/wait.out"
assert test -f "$WORKER_WALLS_DIR/codex-pinacct"
assert_fails grep -q '^codex_profile=' "$WORKER_RUN_CONFIG_FILE"

# (iii) a met wall drops only that pinned name; the run lands on the other pin.
clear_stub
set_config 'codex_effort=high' 'codex_profile=hot,cool'
printf 'hot\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '2' '0 cool' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
assert meta_account_is cool
assert jq -e '.walled_accounts == ["hot"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'codex_profile=cool' "$WORKER_RUN_CONFIG_FILE"
assert test -f "$WORKER_WALLS_DIR/codex-hot"
assert_fails test -f "$WORKER_WALLS_DIR/codex-cool"

# (iv) last pin removed → key deleted.
clear_stub
set_config 'codex_effort=high' 'codex_profile=lastpin'
printf 'lastpin\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '2' '0 leftover' >"$STUB_DIR/pick_queue"
start_ok codex
assert await_done
assert meta_account_is leftover
assert_fails grep -q '^codex_profile=' "$WORKER_RUN_CONFIG_FILE"

# (h) limits at 100% without a run-observed wall still launch on the pin first.
clear_stub
now=$(date +%s)
set_config 'claudeb_model=opus' 'claudeb_effort=high' 'claudeb_profile=hot'
jq -cn --argjson now "$now" '{schema:1,fetched_at:$now,vendors:{claude:{available:true,accounts:[
  {account:"hot",enabled:true,auth:{status:"ok"},
   five_hour:{used_pct:10,as_of:$now},weekly:{used_pct:100,as_of:$now},
   rotation:{usable:{general:true,fable:true}}},
  {account:"cool",enabled:true,auth:{status:"ok"},
   five_hour:{used_pct:0,as_of:$now},weekly:{used_pct:0,as_of:$now},
   rotation:{usable:{general:true,fable:true}}}]}}}' >"$WORK/h-limits.json"
mkdir -p "$HOME/.claude-profiles/.claudeb"
: >"$HOME/.claude-profiles/.claudeb/disabled"
export WORKER_RUN_WORKER_PICK="$ROOT/bin/worker-pick"
export LLM_LIMITS_FILE="$WORK/h-limits.json"
export WORKER_PICK_CONFIG_FILE="$WORKER_RUN_CONFIG_FILE"
export WORKER_PICK_NOW="$now"
export CLAUDEB_DIR="$HOME/.claude-profiles/.claudeb"
export PICK_RC=0 PICK_ACCOUNT=should-not-use-stub
start_ok claudeb
assert meta_account_is hot
assert await_done
assert grep -q '^STATUS: done$' "$WORK/wait.out"
export WORKER_RUN_WORKER_PICK="$WORK/bin/worker-pick"
unset LLM_LIMITS_FILE WORKER_PICK_CONFIG_FILE WORKER_PICK_NOW

# --resume is the one run that stays: the session lives on that account.
clear_stub
set_config 'codex_effort=high'
printf 'resacct\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 rescue5' >"$STUB_DIR/pick_queue"
start_ok codex --account resacct --resume sess-stay
assert await_done
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: resumed session stays on resacct' "$WORK/wait.out"
assert meta_account_is resacct
assert jq -e 'has("walled_accounts") | not' "$RUN_DIR/meta.json" >/dev/null
assert test "$(grep -c '^CODEX_CALL$' "$CALL_LOG")" -eq 1
assert test "$(grep -c '^REROUTE: ' "$WORK/wait.out")" -eq 0
assert grep -qx '0 rescue5' "$STUB_DIR/pick_queue"
assert test -f "$WORKER_WALLS_DIR/codex-resacct"

# A named account that walls, then every remaining pick walls: pool exhausted.
clear_stub
set_config 'codex_effort=high'
printf 'walled1\nwalled2\n' >"$STUB_DIR/wall_accounts"
printf '%s\n' '0 walled2' '3' >"$STUB_DIR/pick_queue"
start_ok codex --account walled1
assert await_done
assert grep -q '^STATUS: failed$' "$WORK/wait.out"
assert grep -qx 'OUTCOME: CODEX_USAGE_LIMIT' "$WORK/wait.out"
assert grep -qx 'WALL: pool exhausted (walled: walled1, walled2)' "$WORK/wait.out"
assert meta_account_is walled2
assert jq -e '.walled_accounts == ["walled1"]' "$RUN_DIR/meta.json" >/dev/null
assert grep -qx 'REROUTE: walled on walled1 → continued on walled2' "$WORK/wait.out"

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
REVIEW_BENCH_STUB_EMPTY=1 "$RUNNER" start codex --brief "$WORK/deleg-brief" --workdir "$WORK/workdir" \
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
assert test "$(jq 'has("review_round")' "$RUN_DIR/meta.json")" = false
await_done || fail "the delegated run never finished"

# A fixing worker's brief names the review round it fixes — line 1, or line 2 under a RESUME/ATTACH
# line — and the run record keeps it: review-bench closes the round on what that run produced.
clear_stub
mkdir -p "$DELEG_BENCHES/20260801T140000Z-0a1b2c3"
round_start() {
  "$RUNNER" start codex --brief "$WORK/round-brief" --workdir "$WORK/workdir" "$@" \
    >"$WORK/round.out" 2>"$WORK/round.err"
}
printf 'ROUND: 20260801T140000Z-0a1b2c3\nFix the confirmed findings.\n' >"$WORK/round-brief"
round_start || fail "round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
# A round brief a chat wrote by hand carries no fixer-row rule; the launch gets review-bench's.
assert test "$(sed '/^AUDIENCE: /,$d' "$RUN_DIR/brief.launch")" = "ROUND: 20260801T140000Z-0a1b2c3
Fix the confirmed findings.

STUB FIX RULE fix 20260801T140000Z-0a1b2c3 --print
write verdicts.jsonl rows"
assert test "$(sed -n '7p' "$RUN_DIR/brief.launch" | cut -c1-10)" = "AUDIENCE: "
assert cmp -s "$WORK/round-brief" "$RUN_DIR/brief"
await_done || fail "the round run never finished"
clear_stub
printf 'ROUND: 20260801T140000Z-0a1b2c3\nWrite one row per finding into $WORKER_RUN_RECORD/verdicts.jsonl.\n' >"$WORK/round-brief"
round_start || fail "verdicts round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert_fails grep -q 'STUB FIX RULE' "$RUN_DIR/brief.launch"
await_done || fail "the verdicts round run never finished"
clear_stub
printf 'ROUND: 20260801T140000Z-0a1b2c3\nNothing is left.\n' >"$WORK/round-brief"
REVIEW_BENCH_STUB_EMPTY=1 round_start || fail "fixed round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(sed -n '4p' "$RUN_DIR/brief.launch" | cut -c1-10)" = "AUDIENCE: "
await_done || fail "the fixed round run never finished"
clear_stub
printf 'ROUND: 20260801T140000Z-0a1b2c3\nFix it.\n' >"$WORK/round-brief"
rc=0
REVIEW_BENCH_STUB_FAIL=1 round_start || rc=$?
assert test "$rc" -eq 4
assert test "$(wc -l <"$WORK/round.err" | tr -d ' ')" = 1
assert grep -Fq 'review-bench fix 20260801T140000Z-0a1b2c3 --print failed' "$WORK/round.err"
assert_fails grep -q '^RUN: ' "$WORK/round.out"
clear_stub
printf 'RESUME codex-resume:\nROUND: 20260801T140000Z-0a1b2c3\nFix the rest.\n' >"$WORK/round-brief"
round_start --account main --resume codex-resume || fail "resumed round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
await_done || fail "the resumed round run never finished"
clear_stub
printf 'ACCOUNT: main\nEFFORT: high\nROUND: 20260801T140000Z-0a1b2c3\n\nFix the findings.\n' >"$WORK/round-brief"
round_start || fail "header round start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
await_done || fail "the header round run never finished"
clear_stub
printf 'ACCOUNT: main\n\nThe brief must carry the line\nROUND: 20260801T140000Z-0a1b2c3\n' >"$WORK/round-brief"
# A ROUND: past the header is not a header line — it is prose naming an open round, and prose is
# asked about rather than bound.
rc=0
round_start || rc=$?
assert test "$rc" -eq 4
assert grep -Fq "open review round(s) 20260801T140000Z-0a1b2c3 but has no ROUND: line" "$WORK/round.err"
assert_fails grep -q '^RUN: ' "$WORK/round.out"

# A brief that names an open round in prose alone is refused, never bound: bound, a read-only audit
# that cited a run as evidence was handed that round's findings to fix (2026-09-23), and unasked a
# hand-written fix brief lands its fixes as debt. The refusal names both headers that answer it.
clear_stub
printf 'ACCOUNT: main\n\nAudit the labels of review round 20260801T140000Z-0a1b2c3 (see the bench). Edit nothing.\n' >"$WORK/round-brief"
rc=0
round_start || rc=$?
assert test "$rc" -eq 4
assert test "$(wc -l <"$WORK/round.err" | tr -d ' ')" = 1
assert grep -Fq "add 'ROUND: <id>' when this run fixes that round, or 'ROUND: none' when it only cites it" "$WORK/round.err"
assert_fails grep -q '^RUN: ' "$WORK/round.out"
# `ROUND: none` launches it unbound: no round, no fix rule appended.
clear_stub
printf 'ACCOUNT: main\nROUND: none\n\nAudit the labels of review round 20260801T140000Z-0a1b2c3 (see the bench). Edit nothing.\n' >"$WORK/round-brief"
round_start || fail "ROUND: none start failed: $(<"$WORK/round.err")"
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq 'has("review_round")' "$RUN_DIR/meta.json")" = false
assert_fails grep -q 'STUB FIX RULE' "$RUN_DIR/brief.launch"
await_done || fail "the ROUND: none run never finished"

# The same brief against a settled round: `fix --print` prints nothing, so nothing is asked — a
# round with no confirmed finding left is not a round this run could fix.
clear_stub
printf 'ACCOUNT: main\n\nFix the three findings of review round 20260801T140000Z-0a1b2c3 (see the bench).\n' >"$WORK/round-brief"
REVIEW_BENCH_STUB_EMPTY=1 round_start || fail "settled brief-text start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq 'has("review_round")' "$RUN_DIR/meta.json")" = false
assert test "$(jq 'has("round_source")' "$RUN_DIR/meta.json")" = false
assert_fails grep -q 'STUB FIX RULE' "$RUN_DIR/brief.launch"
assert_fails grep -q 'ROUND: line' "$WORK/round.err"
await_done || fail "the settled brief-text run never finished"

# A member id of a chunked round is one token to the scan as well as to the validator: the prose of
# a chunk's fix brief names `<round>-<n>`, and a scan blind to the suffix would ask nothing.
clear_stub
mkdir -p "$DELEG_BENCHES/20260801T140000Z-0a1b2c3-2"
printf 'ACCOUNT: main\n\nFix the findings of review round 20260801T140000Z-0a1b2c3-2 (see the bench).\n' >"$WORK/round-brief"
rc=0
round_start || rc=$?
assert test "$rc" -eq 4
assert grep -Fq "open review round(s) 20260801T140000Z-0a1b2c3-2 but" "$WORK/round.err"

# Two open rounds in the prose and no line choosing between them: a run that picked one would
# anchor half its fixes against the other, so it refuses and asks for the ROUND: line.
clear_stub
printf 'ACCOUNT: main\n\nFix 20260801T140000Z-0a1b2c3 and then 20260801T130000Z-def4560.\n' >"$WORK/round-brief"
rc=0
round_start || rc=$?
assert test "$rc" -eq 4
assert test "$(wc -l <"$WORK/round.err" | tr -d ' ')" = 1
assert grep -Fq '20260801T140000Z-0a1b2c3 20260801T130000Z-def4560' "$WORK/round.err"
assert grep -Fq "add 'ROUND: <id>'" "$WORK/round.err"
assert_fails grep -q '^RUN: ' "$WORK/round.out"

# A ROUND: header answers alone: the prose beside it names another open round and is never scanned.
clear_stub
printf 'ROUND: 20260801T140000Z-0a1b2c3\nThe findings 20260801T130000Z-def4560 raised are already fixed.\n' >"$WORK/round-brief"
round_start || fail "header-wins start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T140000Z-0a1b2c3
assert test "$(jq -r '.round_source' "$RUN_DIR/meta.json")" = header
assert_fails grep -q 'ROUND: line' "$WORK/round.err"
await_done || fail "the header-wins run never finished"

# The flag answers alone the same way, and names its own source.
clear_stub
round_start --round 20260801T130000Z-def4560 || fail "flag-source start failed: $(<"$WORK/round.err")"
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260801T130000Z-def4560
assert test "$(jq -r '.round_source' "$RUN_DIR/meta.json")" = flag
await_done || fail "the flag-source run never finished"

# Round-SHAPED is not a round id: a bare timestamp, a date and a run id are tokens the scan drops
# before it asks review-bench anything.
clear_stub
printf 'ACCOUNT: main\n\nThe 20260801T140000Z snapshot of 2026-08-01, run codex-20260801-1234-ab12.\n' >"$WORK/round-brief"
round_start || fail "non-round token start failed: $(<"$WORK/round.err")"
RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/round.out")
RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/round.out")
assert test "$(jq 'has("review_round")' "$RUN_DIR/meta.json")" = false
assert_fails grep -q 'ROUND: line' "$WORK/round.err"
await_done || fail "the non-round token run never finished"

for bad_round in 'ROUND: 20260801T140000Z-0A1B2C3' 'ROUND: 20260801T140000Z-0a1b2c' \
  'ROUND: 20260801T150000Z-0a1b2c3' 'ROUND: 20260801T140000Z- 0a1b2c3'; do
  clear_stub
  printf '%s\nFix it.\n' "$bad_round" >"$WORK/round-brief"
  rc=0
  round_start || rc=$?
  assert test "$rc" -eq 4
  assert test "$(wc -l <"$WORK/round.err" | tr -d ' ')" = 1
  assert grep -Fq "the shape is 'ROUND: <review-bench run id YYYYMMDDTHHMMSSZ-<7 hex>>'" "$WORK/round.err"
  assert_fails grep -q '^RUN: ' "$WORK/round.out"
done


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
assert test "$(jq -r '.served_model' "$RUN_DIR/meta.json")" = grok-4.7-build
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
# A model that is not the one `grokb models` marks default is its own label; only that default
# and `auto` collapse to the vendor word.
set_config 'grok_model=grok-4.6' 'grok_effort=high'
start_ok grok
assert grep -qx 'TAG: grokacct · grok-4.6 · high' "$WORK/start.out"
assert grep -qx 'grokacct · grok-4.6 · high' "$RUN_DIR/tag"
assert await_done
assert grep -qx 'ARG=-m' "$CALL_LOG"
assert grep -qx 'ARG=grok-4.6' "$CALL_LOG"
assert grep -qx 'ARG=--reasoning-effort' "$CALL_LOG"
assert grep -qx 'ARG=high' "$CALL_LOG"

# --- fast is the chat pin's modifier, and it is workers only -------------------------------------
# `chat-pin grok-fast` writes `grok_fast=on` beside the pin: the default model becomes the `-fast`
# sibling `grokb models` lists beside it, carrying that slug's own label instead of the vendor word.
mkdir -p "$CHAT_PINS_DIR"
printf 'grok_profile=*\ngrok_fast=on\n' >"$CHAT_PINS_DIR/chat-fast"
clear_stub
set_config 'grok_model=auto' 'grok_effort=high'
CLAUDE_CODE_SESSION_ID=chat-fast start_ok grok
assert grep -qx 'TAG: grokacct · grok-4.7-build-fast · high' "$WORK/start.out"
assert test "$(jq -r '.model' "$RUN_DIR/meta.json")" = grok-4.7-build-fast
assert await_done
assert grep -qx 'ARG=-m' "$CALL_LOG"
assert grep -qx 'ARG=grok-4.7-build-fast' "$CALL_LOG"

# A model someone named is a choice and travels as named: fast stands in for the default and for
# `auto`, never for that.
clear_stub
set_config 'grok_model=grok-4.6' 'grok_effort=high'
CLAUDE_CODE_SESSION_ID=chat-fast start_ok grok
assert grep -qx 'TAG: grokacct · grok-4.6 · high' "$WORK/start.out"
assert await_done
assert grep -qx 'ARG=grok-4.6' "$CALL_LOG"

# Research is not a worker leg and never takes it (Egor).
clear_stub
set_config 'grok_model=auto' 'grok_effort=high' 'light_research=grok'
CLAUDE_CODE_SESSION_ID=chat-fast start_ok grok --role research
assert grep -qx 'TAG: grokacct · grok · high' "$WORK/start.out"
assert test "$(jq -r '.model' "$RUN_DIR/meta.json")" = auto
assert await_done

# Another chat's fast line is not this chat's.
clear_stub
set_config 'grok_model=auto' 'grok_effort=high'
CLAUDE_CODE_SESSION_ID=chat-plain start_ok grok
assert grep -qx 'TAG: grokacct · grok · high' "$WORK/start.out"
assert await_done
rm -f "$CHAT_PINS_DIR/chat-fast"

# The account's own Fast Mode swaps the model after the effort was checked on `auto`: the swapped
# slug's catalog efforts still decide, before anything launches.
cp "$GROKB_CACHE_DIR/models.json" "$WORK/grok-models.saved"
jq '.models |= map(if .slug == "grok-4.7-build-fast" then .efforts = ["high"] else . end)' "$WORK/grok-models.saved" \
  >"$GROKB_CACHE_DIR/models.json"
mkdir -p "$GROKB_PROFILES_DIR/.grokb/fast-mode"
printf 'fast\n' >"$GROKB_PROFILES_DIR/.grokb/fast-mode/grokacct"
clear_stub
set_config 'grok_model=auto' 'grok_effort=high'
rc=0
"$RUNNER" start grok --brief "$WORK/brief" --effort xhigh >"$WORK/grok-effort.out" 2>"$WORK/grok-effort.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/grok-effort.out"
assert grep -q 'grok-4.7-build-fast' "$WORK/grok-effort.err"
assert test ! -s "$CALL_LOG"
cp "$WORK/grok-models.saved" "$GROKB_CACHE_DIR/models.json"
# The account's own catalog decides whether its Fast twin exists, not the shared list.
mkdir -p "$GROKB_PROFILES_DIR/grokacct"
printf '{"models":{"grok-4.7":{},"grok-4.6":{}}}\n' >"$GROKB_PROFILES_DIR/grokacct/models_cache.json"
clear_stub
start_ok grok
assert await_done
assert_fails grep -qx 'ARG=grok-4.7-build-fast' "$CALL_LOG"
assert grep -q 'grok: grokacct lists no grok-4.7-build-fast now' "$WORK/start.err"
printf '{"models":{"grok-4.7":{},"grok-4.7-build-fast":{}}}\n' >"$GROKB_PROFILES_DIR/grokacct/models_cache.json"
clear_stub
start_ok grok
assert await_done
assert grep -qx 'ARG=grok-4.7-build-fast' "$CALL_LOG"
rm -f "$GROKB_PROFILES_DIR/.grokb/fast-mode/grokacct" "$GROKB_PROFILES_DIR/grokacct/models_cache.json"

# `xhigh` is the CLI's to know: it travels as asked instead of being
# clamped here, and only an effort no grok has is refused before launch.
clear_stub
start_ok grok --effort xhigh
assert await_done
assert grep -qx 'ARG=xhigh' "$CALL_LOG"
clear_stub
rc=0
"$RUNNER" start grok --brief "$WORK/brief" --effort ultra >"$WORK/grok-effort.out" 2>"$WORK/grok-effort.err" || rc=$?
assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: EFFORT_REFUSED' "$WORK/grok-effort.out"
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

# A research run is refused with them: grok reads the one tree `--cwd` names, so a brief over
# several repositories would be answered from the only one the run could open.
clear_stub
rc=0
"$RUNNER" start grok --brief "$WORK/brief" --role research --add-dir "$WORK/extra" \
  >"$WORK/grok-research.out" 2>"$WORK/grok-research.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'grok does not support --add-dir or --image' "$WORK/grok-research.err"
assert test ! -s "$CALL_LOG"

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
assert jq -e 'has("pinned") | not' "$RUN_DIR/meta.json" >/dev/null
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

# The vendor refusing a NEW session: two handshake events, a cancelled end, exit 0 and an empty
# stderr. Exit 0 alone reported it as a finished run and handed the orchestrator an empty result
# (live 2026-09-08). It is weather, so no wall is recorded and the pin stays honorable.
clear_stub
set_config 'grok_effort=high'
export PICK_RC=0 PICK_ACCOUNT=grokcancel STUB_CODE=0
: >"$STUB_DIR/grok_cancelled"
start_ok grok
assert await_done
assert grep -qx 'STATUS: failed' "$WORK/wait.out"
assert grep -qx "OUTCOME: GROK_CANCELLED $RUN_ID" "$WORK/wait.out"
assert grep -qx 'REASON: cancelled — grok ended the session before its first turn; capacity weather, not a wall: pause and relaunch once' \
  "$WORK/wait.out"
assert test "$(grep -c 'GROK_UNAVAILABLE\|GROK_USAGE_LIMIT' "$WORK/wait.out")" -eq 0
assert test ! -e "$WORKER_WALLS_DIR/grok-grokcancel"
assert grep -qx "OUTCOME: GROK_CANCELLED $RUN_ID" <<<"$("$RUNNER" report "$RUN_ID")"
assert grep -qx 'STATUS: failed' <<<"$("$RUNNER" report "$RUN_ID")"

# One tool call in front of the same cancelled end is an ordinary run that ended: the classifier
# reads the FIRST turn-or-end event, never the stop reason alone.
clear_stub
export PICK_RC=0 PICK_ACCOUNT=grokcancel STUB_CODE=0
: >"$STUB_DIR/grok_cancelled"
: >"$STUB_DIR/grok_cancelled_worked"
start_ok grok
assert await_done
assert grep -qx 'STATUS: done' "$WORK/wait.out"
assert test "$(grep -c '^OUTCOME: ' "$WORK/wait.out")" -eq 0
clear_stub

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
  grok_call p1 todo_write plan false '{"todos": []}'
  grok_update p1 completed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a call whose file targets it does not name: image_gen)' \
  <<<"$(transcript_report "$RUN_DIR")"

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
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the run wrote through the shell, whose targets no transcript names)' \
  <<<"$(transcript_report "$RUN_DIR")"

# A mutating row with no usable time cannot be silently dropped out of the run's window.
clear_stub
GROK_TS=null
{
  grok_call w1 write write false "$(jq -cn --arg p "$grok_workdir/bin/grok-timeless" '{file_path: $p}')"
  grok_update w1 completed
} >"$GROK_UPDATES"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILES: unknown (the transcript records a mutating context with an unparseable timestamp)' \
  <<<"$(transcript_report "$RUN_DIR")"

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
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx "RUN-FILES: unknown (no session transcript for $GROK_SESSION)" <<<"$(transcript_report "$RUN_DIR")"
# With no summary.json at all the encoded directory name is what answers, and it answers for this
# run: a record whose own cwd cannot be read is not a licence to claim it.
rm -f "$(dirname "$GROK_UPDATES")/summary.json"
clear_stub
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx 'RUN-FILE: bin/grok-elsewhere' <<<"$(transcript_report "$RUN_DIR")"

# No record at all is unknown too, and never the workdir.
clear_stub
mv "$GROK_UPDATES" "$GROK_UPDATES.moved"
start_ok grok
assert await_done
transcript_report "$RUN_DIR" >/dev/null
assert grep -qx "RUN-FILES: unknown (no session transcript for $GROK_SESSION)" <<<"$(transcript_report "$RUN_DIR")"
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
transcript_report "$RUN_DIR" >/dev/null
report=$(transcript_report "$RUN_DIR")
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
for spec in 'claudeb:sonnet' 'claudeb:haiku' 'codex:gpt-5.6-terra' \
            'codex:gpt-5.6-luna' 'codex:gpt-5.6' 'gemini:flash' \
            'gemini:flash35' 'gemini:flash39' 'grok:grok-3'; do
  vendor=${spec%%:*}
  bad=${spec#*:}
  assert model_refused "$vendor" "$bad" --model "$bad"
done

# The same refusal when the toggle file carries it and no brief names a model at all.
for spec in 'claudeb:claudeb_model=sonnet' 'gemini:gemini_model=flash35' 'grok:grok_model=grok-3'; do
  vendor=${spec%%:*}
  key=${spec#*:}
  set_config "$key" 'claudeb_effort=high' 'codex_effort=medium' 'gemini_effort=high' 'grok_effort=high'
  assert model_refused "$vendor" "${key#*=}"
done
# Codex has no key of its own and its default is the allow-list's model, never `config.toml`'s:
# Egor's interactive picks land in that shared file and must neither refuse nor switch a worker.
set_config 'codex_effort=medium'
printf 'model = "gpt-5.6-terra"\n' >"$WORKER_RUN_CODEX_CONFIG"
for flags in '' '--model default'; do
  clear_stub
  # shellcheck disable=SC2086
  start_ok codex --account model $flags
  assert await_done
  assert grep -qx 'ARG=gpt-6.1-astra' "$CALL_LOG"
done
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
start_ok codex --model astra
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
# until its CLI exits, so a pairing read off the run record arrives AFTER every touch the worker
# made while it ran (live run claudeb-1788388059-13078-3ffd, 2026-09-03). So the chat is stamped
# into the launched process's ENVIRONMENT as CLAUDE_DEBT_OWNER, which every relay inherits whatever
# the vendor and whatever it goes on to launch, and the touch writer charges the anchors store to it.
#
# One case per relay type, each end to end: worker-run launches the stubbed CLI under a fake
# launching chat, a process inside that CLI edits a file in a git fixture and records it exactly as
# the relay's own PostToolUse hook would, and the touch that reaches the store must carry the
# LAUNCHER's id. Break the stamp for one relay and only that relay's case fails.
STAMP_HOOK="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/commit-journal.sh"
STAMP_LIB="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/lib/review-journal.sh"
STAMP_ANCHORS="${REVIEW_BENCH_ROOT:-$ROOT/../review-bench}/bin/review-anchors"
if [ -r "$STAMP_HOOK" ] && [ -r "$STAMP_LIB" ] && [ -x "$STAMP_ANCHORS" ]; then
  STAMP_REPO="$WORK/stamp-repo"
  mkdir -p "$STAMP_REPO" "$WORK/stamp-bin"
  ln -sf "$STAMP_ANCHORS" "$WORK/stamp-bin/review-anchors"
  git -C "$STAMP_REPO" init -q -b main
  git -C "$STAMP_REPO" config user.email t@example.test
  git -C "$STAMP_REPO" config user.name t
  printf 'base\n' >"$STAMP_REPO/base.txt"
  git -C "$STAMP_REPO" add base.txt
  git -C "$STAMP_REPO" commit -q -m base
  STAMP_STORE=$(git -C "$STAMP_REPO" rev-parse --path-format=absolute --git-common-dir)/review-anchors.json
  STAMP_KEY=$(cd "$(git -C "$STAMP_REPO" rev-parse --absolute-git-dir)" && pwd -P)
  # The hook skips anything under TMPDIR and this suite's fixtures live there: it is pinned to a
  # directory no fixture sits under, or the paths asserted on here are silenced by where the suite
  # happens to run.
  STAMP_HOME="$WORK/stamp-home"
  mkdir -p "$STAMP_HOME" "$WORK/stamp-tmpdir"
  # The relay's own hook pair, both halves: the PreToolUse content snapshot the touch writer
  # measures a change against, then the PostToolUse payload naming the file the relay just wrote.
  # `$1` is the worker's OWN session id — the only one a relay's hook ever knows.
  cat >"$STUB_DIR/relay_hook" <<STAMPEOF
#!/usr/bin/env bash
worker=\$1
tag=\$(cat "$STUB_DIR/relay_tag" 2>/dev/null) || tag=untagged
path="$STAMP_REPO/relay-\$tag.txt"
export HOME="$STAMP_HOME" TMPDIR="$WORK/stamp-tmpdir" WORKER_RUN_DIR="$WORKER_RUN_DIR"
export GIT_CEILING_DIRECTORIES="$WORK" PATH="$WORK/stamp-bin:\$PATH"
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
  # Who holds a touch on a path in the store, one id per line.
  stamp_owners() { # tag
    jq -r --arg k "$STAMP_KEY" --arg p "relay-$1.txt" '(.touches[$k][$p] // {}) | keys[]' \
      "$STAMP_STORE" 2>/dev/null | sort -u
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
    # The launcher alone: a touch under the worker's own id is debt no chat on this machine reads.
    assert test "$(stamp_owners "$tag" | grep -c .)" -eq 1
  }
  set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=medium' \
    'gemini_model=flash38' 'gemini_effort=high' 'grok_model=auto' 'grok_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=stampacct
  stamp_relay claudeb claudeb
  stamp_relay codex codex
  stamp_relay gemini gemini --account main
  stamp_relay grok grok
  # A RE-ATTACHED run: a `--resume` launch repeats the id the worker session already had, and its
  # touches still reach the launcher rather than that resumed id.
  export STUB_SESSION=reattached-session
  stamp_relay reattach claudeb --account stampacct --resume reattached-session
  assert grep -qx 'reattached-session' "$RUN_DIR/worker-session"
  assert_fails grep -qx 'reattached-session' <<<"$(stamp_owners reattach)"
  unset STUB_SESSION
  # An IMAGE SCRIPT and a POOL-RUN CELL are processes a relay starts, not relays of their own: they
  # record through whoever ran them, so the one thing they must not do is drop the stamp. Stood in
  # for here by a bare shell — which is what both are to the environment — launched with the
  # environment worker-run exported.
  printf '%s\n' image-cell >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( export CLAUDE_DEBT_OWNER=stamp-chat-image-cell CLAUDE_CODE_SESSION_ID=some-worker
    "$STUB_DIR/relay_hook" nested-image-worker )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 0
  assert grep -qx 'stamp-chat-image-cell' <<<"$(stamp_owners image-cell)"
  assert_fails grep -qx 'nested-image-worker' <<<"$(stamp_owners image-cell)"
  # A worker with no stamp at all charges its own session id: the touch is still a fact, and the
  # hook stays quiet inside a worker.
  printf '%s\n' unstamped >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( unset CLAUDE_DEBT_OWNER
    export CLAUDEB_WORKER=1
    "$STUB_DIR/relay_hook" unstamped-worker )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 0
  assert test "$(stamp_owners unstamped)" = unstamped-worker
  # And a chat's own shell is no relay worker: its touches are its own outright.
  printf '%s\n' quiet >"$STUB_DIR/relay_tag"
  rm -f "$STUB_DIR/relay_hook_rc"
  ( unset CLAUDE_DEBT_OWNER CLAUDEB_WORKER GROK_WORKER
    "$STUB_DIR/relay_hook" a-chat-of-its-own )
  assert test "$(cat "$STUB_DIR/relay_hook_rc")" = 0
  assert grep -qx 'a-chat-of-its-own' <<<"$(stamp_owners quiet)"
  rm -f "$STUB_DIR/relay_hook" "$STUB_DIR/relay_tag"
  unset PICK_RC PICK_ACCOUNT
  clear_stub
else
  fail "the touch writer of ../claude-setup or ../review-bench's review-anchors is unreadable (set CLAUDE_SETUP_ROOT / REVIEW_BENCH_ROOT)"
fi

# Snapshot attribution P1/P2 (after-snapshot UNKNOWN, first-row-wins, foreign HEAD, path shape, symlink, claim).
clear_stub
set_config 'claudeb_model=opus' 'claudeb_effort=high'
export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=chat-abc
mkdir -p "$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture"
ATTR_REPO="$WORK/attr-repo"
mkdir -p "$ATTR_REPO/bin"
git -C "$ATTR_REPO" init -q .
printf 'base\n' >"$ATTR_REPO/bin/keep"
git -C "$ATTR_REPO" add -A >/dev/null
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
ATTR_TOP=$(cd "$ATTR_REPO" && pwd -P)
tab=$'\t'
blob_of() { printf '%s\n' "$1" | git -C "${1:-$ATTR_REPO}" hash-object --stdin; }
attr_blob() { printf '%s\n' "$1" | git -C "$ATTR_REPO" hash-object --stdin; }
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"

export STUB_SLEEP=1
start_ok claudeb --workdir "$ATTR_REPO"
printf 'stale-produced\n' >"$RUN_DIR/produced"
printf 'WORKDIR: %s\nstale-dirty\n' "$ATTR_TOP" >"$RUN_DIR/dirty"
mv "$ATTR_REPO/.git" "$ATTR_REPO/.git.hidden"
assert await_done
mv "$ATTR_REPO/.git.hidden" "$ATTR_REPO/.git"
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/produced"
assert test ! -e "$RUN_DIR/dirty"
assert grep -q '^UNNAMED: ' "$WORK/wait.out"
assert grep -q "claim $RUN_ID" "$WORK/wait.out"
assert grep -q '^UNNAMED: ' <<<"$("$RUNNER" report "$RUN_ID")"
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/keep >"$WORK/claim-unknown.out" 2>&1
assert grep -q 'no after-snapshot' "$WORK/claim-unknown.out"

clear_stub
printf 'B\n' >"$ATTR_REPO/bin/rewritten-open"
git -C "$ATTR_REPO" add bin/rewritten-open
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'head blob B' >/dev/null
printf 'D\n' >"$ATTR_REPO/bin/rewritten-open"
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/rewritten-open" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$ATTR_REPO"
printf 'C\n' >"$ATTR_REPO/bin/rewritten-open"
git -C "$ATTR_REPO" add bin/rewritten-open
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'the run committed C' >/dev/null
assert await_done
assert grep -qxF -- "$(attr_blob D)$tab$(attr_blob C)${tab}bin/rewritten-open" "$RUN_DIR/produced"
assert_fails grep -q $'\tbin/rewritten-open\tcommit$' "$RUN_DIR/produced"
assert_fails grep -qxF -- "$(attr_blob B)$tab$(attr_blob C)${tab}bin/rewritten-open${tab}commit" "$RUN_DIR/produced"

clear_stub
UP_REPO="$WORK/upstream-repo"
mkdir -p "$UP_REPO/bin"
git -C "$UP_REPO" init -q .
printf 'shared\n' >"$UP_REPO/bin/shared"
git -C "$UP_REPO" add -A >/dev/null
git -C "$UP_REPO" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
git clone -q "$UP_REPO" "$WORK/run-clone"
printf 'upstream\n' >"$UP_REPO/bin/from-upstream"
git -C "$UP_REPO" add bin/from-upstream
GIT_AUTHOR_DATE='2020-01-01T00:00:00' GIT_COMMITTER_DATE='2020-01-01T00:00:00' \
  git -C "$UP_REPO" -c user.email=t@t -c user.name=t commit -qm 'old upstream' >/dev/null
CLONE_TOP=$(cd "$WORK/run-clone" && pwd -P)
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$CLONE_TOP/bin/ours" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$WORK/run-clone"
git -C "$WORK/run-clone" fetch -q origin && git -C "$WORK/run-clone" merge --ff-only -q FETCH_HEAD
printf 'ours\n' >"$WORK/run-clone/bin/ours"
assert await_done
assert grep -q 'bin/ours' "$RUN_DIR/produced"
assert_fails grep -q 'from-upstream' "$RUN_DIR/produced"
assert_fails grep -qx 'bin/from-upstream' "$RUN_DIR/files"
assert grep -q 'outside the run window' "$RUN_DIR/files-note"

clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$ATTR_REPO"
printf 'dash\n' >"$ATTR_REPO/-odd-name"
assert await_done
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert_fails grep -q -- '-odd-name' "$RUN_DIR/files"
assert test ! -e "$RUN_DIR/produced"
rm -f "$ATTR_REPO/-odd-name"

clear_stub
mkdir -p "$ATTR_REPO/target-dir"
printf 'old-target\n' >"$ATTR_REPO/old-file"
printf 'new-target\n' >"$ATTR_REPO/new-file"
ln -s old-file "$ATTR_REPO/link-file"
ln -s target-dir "$ATTR_REPO/link-dir"
git -C "$ATTR_REPO" add -A >/dev/null
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'symlinks' >/dev/null
TOOL_TS=$(iso $(($(date +%s) + 60)))
# A symlink is made with `ln`, never with an editor call: the run says so, or the two links below
# that no tool call names read as another writer's.
{
  tool_call Edit file_path "$ATTR_TOP/link-file"
  tool_call Bash command 'ln -sf new-file link-file; ln -s missing dangling'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$ATTR_REPO"
ln -sf new-file "$ATTR_REPO/link-file"
ln -s missing "$ATTR_REPO/dangling"
ln -s target-dir "$ATTR_REPO/new-link-dir"
assert await_done
link_prev=$(printf '%s' old-file | git -C "$ATTR_REPO" hash-object --stdin)
link_cur=$(printf '%s' new-file | git -C "$ATTR_REPO" hash-object --stdin)
dang_cur=$(printf '%s' missing | git -C "$ATTR_REPO" hash-object --stdin)
dir_cur=$(printf '%s' target-dir | git -C "$ATTR_REPO" hash-object --stdin)
assert grep -qxF -- "$link_prev$tab$link_cur${tab}link-file" "$RUN_DIR/produced"
assert_fails grep -q 'dangling\|new-link-dir' "$RUN_DIR/produced"
assert grep -qx dangling "$RUN_DIR/dirty"
assert grep -qx new-link-dir "$RUN_DIR/dirty"
assert "$RUNNER" claim "$RUN_ID" --paths dangling new-link-dir >/dev/null
assert grep -qxF -- "-$tab$dang_cur${tab}dangling" "$RUN_DIR/produced"
assert grep -qxF -- "-$tab$dir_cur${tab}new-link-dir" "$RUN_DIR/produced"
assert_fails grep -q $'\t-\tdangling$' "$RUN_DIR/produced"
assert_fails grep -q $'\t-\tnew-link-dir$' "$RUN_DIR/produced"
assert_fails grep -q $'\t-\tlink-dir$' "$RUN_DIR/produced"

# snapshot_tab_or_newline_path_unknown
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$ATTR_REPO"
printf 'during-run\n' >"$ATTR_REPO/bin/keep"
printf 'tabbed\n' >"$ATTR_REPO/bin/has${tab}tab"
printf 'nl\n' >"$ATTR_REPO/bin/has"$'\n'"nl"
assert await_done
assert test "$(head -n1 "$RUN_DIR/files")" = "WORKDIR: $ATTR_TOP"
assert grep -q '^UNKNOWN: ' "$RUN_DIR/files"
assert_fails grep -q '^PARTIAL: ' "$RUN_DIR/files"
assert test "$(grep -cv '^WORKDIR: \|^UNKNOWN: ' "$RUN_DIR/files")" -eq 0
assert_fails grep -qx 'bin/keep' "$RUN_DIR/files"
assert test ! -s "$RUN_DIR/produced"
rm -f "$ATTR_REPO/bin/has${tab}tab" "$ATTR_REPO/bin/has"$'\n'"nl"

# snapshot_linked_worktree_attribution
clear_stub
WT_DIR="$WORK/attr-linked-wt"
git -C "$ATTR_REPO" worktree add -b attr-linked "$WT_DIR" >/dev/null
WT_TOP=$(cd "$WT_DIR" && pwd -P)
printf 'wt-head\n' >"$WT_DIR/bin/in-wt"
git -C "$WT_DIR" add bin/in-wt
git -C "$WT_DIR" -c user.email=t@t -c user.name=t commit -qm 'worktree head' >/dev/null
WT_HEAD=$(git -C "$WT_DIR" rev-parse HEAD)
WT_PREV=$(git -C "$WT_DIR" rev-parse HEAD:bin/in-wt)
MAIN_HEAD=$(git -C "$ATTR_REPO" rev-parse HEAD)
assert test "$WT_HEAD" != "$MAIN_HEAD"
printf 'main-only\n' >"$ATTR_REPO/bin/main-dirt"
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$WT_TOP/bin/in-wt" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$WT_DIR"
printf 'run-edit\n' >"$WT_DIR/bin/in-wt"
assert await_done
assert test "$(cat "$RUN_DIR/head-before")" = "$WT_HEAD"
assert grep -qx 'bin/in-wt' "$RUN_DIR/files"
assert grep -qxF -- "$WT_PREV$tab$(attr_blob run-edit)${tab}bin/in-wt" "$RUN_DIR/produced"
assert_fails grep -q 'main-dirt' "$RUN_DIR/files"
assert_fails grep -q 'main-dirt' "$RUN_DIR/produced"
assert_fails grep -q '^UNKNOWN: \|^PARTIAL: ' "$RUN_DIR/files"

# snapshot_rename_delete_and_birth
clear_stub
printf 'same-blob\n' >"$ATTR_REPO/bin/renamed-from"
git -C "$ATTR_REPO" add bin/renamed-from
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'to rename' >/dev/null
TOOL_TS=$(iso $(($(date +%s) + 60)))
{
  tool_call Edit file_path "$ATTR_TOP/bin/renamed-from"
  tool_call Write file_path "$ATTR_TOP/bin/renamed-to"
  tool_call Bash command 'git mv bin/renamed-from bin/renamed-to'
} >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$ATTR_REPO"
git -C "$ATTR_REPO" mv bin/renamed-from bin/renamed-to
git -C "$ATTR_REPO" -c user.email=t@t -c user.name=t commit -qm 'rename inside the run' >/dev/null
assert await_done
rename_blob=$(attr_blob same-blob)
assert grep -qx 'bin/renamed-from' "$RUN_DIR/files"
assert grep -qx 'bin/renamed-to' "$RUN_DIR/files"
assert grep -qxF -- "$rename_blob$tab-${tab}bin/renamed-from${tab}commit" "$RUN_DIR/produced"
assert grep -qxF -- "-$tab$rename_blob${tab}bin/renamed-to${tab}commit" "$RUN_DIR/produced"
assert_fails grep -q 'renamed-from.*renamed-to' "$RUN_DIR/produced"
assert_fails grep -q 'renamed-to.*renamed-from' "$RUN_DIR/produced"

# snapshot_missing_after_killed_supervisor
clear_stub
TOOL_TS=$(iso $(($(date +%s) + 60)))
tool_call Edit file_path "$ATTR_TOP/bin/keep" \
  >"$CLAUDEB_PROFILES_ROOT/recordacct/projects/fixture/claude-session.jsonl"
export STUB_SLEEP=1
start_ok claudeb --workdir "$ATTR_REPO"
printf 'killed-edit\n' >"$ATTR_REPO/bin/keep"
assert await_done
assert test -f "$RUN_DIR/dirty-before-shas"
assert test -f "$RUN_DIR/head-before"
rm -f "$RUN_DIR/head-after" "$RUN_DIR/dirty-after-shas" "$RUN_DIR/files" "$RUN_DIR/produced"
killed_report=$("$RUNNER" report "$RUN_ID")
assert grep -qi 'UNKNOWN\|unknown' <<<"$killed_report"
assert grep -q "claim $RUN_ID" <<<"$killed_report"
assert_fails "$RUNNER" claim "$RUN_ID" --paths bin/keep >"$WORK/claim-killed.out" 2>&1
assert grep -q 'no after-snapshot' "$WORK/claim-killed.out"

clear_stub
rc=0
"$RUNNER" start codex --brief "$WORK/brief" --chrome >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
assert test "$rc" -eq 4
assert grep -q 'only claudeb supports --chrome' "$WORK/start.err"
assert test ! -s "$CALL_LOG"

clear_stub
start_ok claudeb
assert await_done
assert test "$(grep -c '^ARG=--chrome$' "$CALL_LOG")" -eq 0
assert jq -e '.chrome == false' "$RUN_DIR/meta.json" >/dev/null

clear_stub
start_ok claudeb --chrome
assert await_done
assert grep -qx 'ARG=--chrome' "$CALL_LOG"
assert jq -e '.chrome == true' "$RUN_DIR/meta.json" >/dev/null
assert jq -e '.cmd | index("--chrome") != null' "$RUN_DIR/meta.json" >/dev/null

clear_stub
: >"$STUB_DIR/claudeb_drop_effort"
start_ok claudeb --chrome
assert await_done
assert test "$(grep -c '^CLAUDEB_CALL$' "$CALL_LOG")" -eq 2
assert test "$(grep -c '^ARG=--chrome$' "$CALL_LOG")" -eq 2
assert jq -e '.effort_flag_dropped == true' "$RUN_DIR/meta.json" >/dev/null
assert jq -e '.chrome == true' "$RUN_DIR/meta.json" >/dev/null

# --- the anchors store ---------------------------------------------------------------------------
# `review-anchors` belongs to another repository; here it is a PATH shim logging one tab-separated
# line per call, so what worker-run promises the store is checked without the store existing.
anchors_store_tests() {
  local repo bench gaps rc bad changed fold bases saved_path
  local dirty_base doomed_base empty_blob=e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
  local anchors_tab=$'\t'
  ANCHOR_LOG="$WORK/anchors.log"
  export ANCHOR_LOG
  cat >"$WORK/bin/review-anchors" <<'ANCHORS'
#!/usr/bin/env bash
{ printf '%s' "$1"; shift; [ "$#" -eq 0 ] || printf '\t%s' "$@"; printf '\n'; } >>"$ANCHOR_LOG"
[ -z "${ANCHORS_FAIL:-}" ] || { printf 'store locked\nsecond line\n' >&2; exit 3; }
ANCHORS
  chmod +x "$WORK/bin/review-anchors"
  : >"$ANCHOR_LOG"

  anchors_line() { grep "^$1$anchors_tab" "$ANCHOR_LOG" | tail -n 1; }
  anchors_changed() {
    anchors_line run-fold | tr '\t' '\n' |
      awk '/^--/ { listing = 0 } listing { sub(/^\.\//, ""); print } $0 == "--changed" { listing = 1 }'
  }
  anchors_bases() {
    anchors_line run-fold | tr '\t' '\n' | awk 'sub(/^--base=\.\//, "") { print }'
  }

  repo="$WORK/anchors-repo"
  mkdir -p "$repo/bin"
  git -C "$repo" init -q .
  printf 'base\n' >"$repo/bin/keep"
  printf 'gone\n' >"$repo/bin/doomed"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
  repo=$(cd "$repo" && pwd -P)
  bench="${CLAUDEB_DIR}/worker-stats/benches"
  mkdir -p "$bench/20260901T100000Z-aaaaaaa" "$bench/20260901T110000Z-bbbbbbb"
  gaps="$HOME/.cache/claude/review-debt/gaps/anchors-chat"

  set_config 'codex_model=default' 'codex_effort=high' 'claudeb_model=opus' 'claudeb_effort=high'
  export PICK_RC=0 PICK_ACCOUNT=recordacct CLAUDE_CODE_SESSION_ID=anchors-chat

  # An id of the wrong shape and an id no bench holds are refused at LAUNCH and alike: a run bound
  # to a round nothing recorded would anchor its fix against nothing at all.
  for bad in 20260901T100000Z-AAAAAAA 20260901T100000Z-aaaaaa 20260901T990000Z-fffffff; do
    clear_stub
    rc=0
    "$RUNNER" start codex --brief "$WORK/brief" --workdir "$repo" --round "$bad" \
      >"$WORK/anchors.out" 2>"$WORK/anchors.err" || rc=$?
    assert test "$rc" -eq 4
    assert test "$(wc -l <"$WORK/anchors.err" | tr -d ' ')" = 1
    assert grep -Fq -- '--round names no review round on record' "$WORK/anchors.err"
    assert_fails grep -q '^RUN: ' "$WORK/anchors.out"
  done
  assert test ! -s "$ANCHOR_LOG"

  # The flag is the binding review-bench composes; the header it also writes is the fallback, so a
  # brief naming another round loses to it.
  clear_stub
  printf 'ROUND: 20260901T110000Z-bbbbbbb\nFix the confirmed findings.\n' >"$WORK/anchors-brief"
  # Left dirty BEFORE the launch, so the base the fold reports for it can only have come from the
  # run's own before-listing and not from the commit the run started on.
  printf 'first\n' >"$repo/bin/dirty-first"
  dirty_base=$(git -C "$repo" hash-object "$repo/bin/dirty-first")
  doomed_base=$(git -C "$repo" rev-parse HEAD:bin/doomed)
  export STUB_SLEEP=3
  "$RUNNER" start codex --brief "$WORK/anchors-brief" --workdir "$repo" \
    --round 20260901T100000Z-aaaaaaa >"$WORK/anchors.out" 2>"$WORK/anchors.err" ||
    fail "round start failed: $(<"$WORK/anchors.err")"
  RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/anchors.out")
  RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/anchors.out")
  assert test "$(jq -r '.review_round' "$RUN_DIR/meta.json")" = 20260901T100000Z-aaaaaaa
  # Opened while it runs, so the launching chat's verdict says `?run` instead of a confident number
  # about a tree a worker is writing in.
  assert test "$(anchors_line run-start)" = \
    "run-start${anchors_tab}--repo${anchors_tab}${repo}${anchors_tab}--run${anchors_tab}${RUN_ID}${anchors_tab}--session${anchors_tab}anchors-chat"
  # Every kind of change the run's own listings can see, and nothing the transcript has to name: a
  # file written through a heredoc, a file deleted, a file committed inside the run.
  printf 'heredoc\n' >"$repo/bin/heredoc-only"
  printf 'second\n' >>"$repo/bin/dirty-first"
  rm "$repo/bin/doomed"
  printf 'committed\n' >"$repo/bin/committed"
  git -C "$repo" add bin/committed >/dev/null
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm inside >/dev/null
  assert await_done
  changed=$(anchors_changed)
  assert grep -qx 'bin/heredoc-only' <<<"$changed"
  assert grep -qx 'bin/doomed' <<<"$changed"
  assert grep -qx 'bin/committed' <<<"$changed"
  assert grep -qx 'bin/dirty-first' <<<"$changed"
  assert_fails grep -qx 'bin/keep' <<<"$changed"
  # Every changed path carries what it stood at before the run, which is the only thing that lets
  # the store anchor a path no review has ever read: the path's own before-content where it had
  # one, the HEAD it started from where it was clean, and the empty blob where the run made it.
  bases=$(anchors_bases)
  assert test "$(grep -c . <<<"$bases")" = "$(grep -c . <<<"$changed")"
  assert grep -qx "bin/dirty-first=$dirty_base" <<<"$bases"
  assert grep -qx "bin/doomed=$doomed_base" <<<"$bases"
  assert grep -qx "bin/heredoc-only=$empty_blob" <<<"$bases"
  assert grep -qx "bin/committed=$empty_blob" <<<"$bases"
  assert test "$(git -C "$repo" hash-object -t blob /dev/null)" = "$empty_blob"
  fold=$(anchors_line run-fold)
  assert grep -qF -- "--repo${anchors_tab}${repo}${anchors_tab}--run${anchors_tab}${RUN_ID}" <<<"$fold"
  assert grep -qF -- "--session${anchors_tab}anchors-chat" <<<"$fold"
  assert grep -qF -- "--round${anchors_tab}20260901T100000Z-aaaaaaa" <<<"$fold"
  assert grep -qF -- "--after=./bin/heredoc-only=$(git -C "$repo" hash-object bin/heredoc-only)" <<<"$fold"
  assert grep -qF -- "--after=./bin/doomed=$empty_blob" <<<"$fold"
  assert test ! -e "$gaps"

  # A run that also writes in another repository the launching chat works in is folded there too,
  # or a fix it makes there is never anchored and the launcher owes the fix itself.
  clear_stub
  : >"$ANCHOR_LOG"
  other="$WORK/anchors-other"
  mkdir -p "$other"
  git -C "$other" init -q .
  printf 'base\n' >"$other/kept"
  git -C "$other" add -A >/dev/null
  git -C "$other" -c user.email=t@t -c user.name=t commit -qm base >/dev/null
  other=$(cd "$other" && pwd -P)
  mkdir -p "$HOME/.cache/claude/review-journal"
  printf '%s\n%s\n' "$repo" "$other" >"$HOME/.cache/claude/review-journal/anchors-chat.repos"
  kept_base=$(git -C "$other" rev-parse HEAD:kept)
  export STUB_SLEEP=3
  "$RUNNER" start codex --brief "$WORK/anchors-brief" --workdir "$repo" \
    --round 20260901T100000Z-aaaaaaa >"$WORK/anchors.out" 2>"$WORK/anchors.err" ||
    fail "two-family start failed: $(<"$WORK/anchors.err")"
  RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/anchors.out")
  assert grep -qxF "run-start${anchors_tab}--repo${anchors_tab}${other}${anchors_tab}--run${anchors_tab}${RUN_ID}${anchors_tab}--session${anchors_tab}anchors-chat" "$ANCHOR_LOG"
  printf 'fixed\n' >>"$other/kept"
  assert await_done
  fold=$(grep "^run-fold${anchors_tab}--repo${anchors_tab}${other}${anchors_tab}" "$ANCHOR_LOG" | tail -n 1)
  assert grep -qF -- "--run${anchors_tab}${RUN_ID}" <<<"$fold"
  assert grep -qF -- "--round${anchors_tab}20260901T100000Z-aaaaaaa" <<<"$fold"
  assert grep -qF -- "--changed${anchors_tab}./kept${anchors_tab}" <<<"$fold"
  assert grep -qF -- "--base=./kept=$kept_base" <<<"$fold"
  assert grep -qF -- "--after=./kept=$(git -C "$other" hash-object kept)" <<<"$fold"
  assert test "$(grep -c "^run-fold${anchors_tab}--repo${anchors_tab}${other}${anchors_tab}" "$ANCHOR_LOG")" = 1
  rm -f "$HOME/.cache/claude/review-journal/anchors-chat.repos"

  # A run that failed is folded like any other — the store's question is what content moved, never
  # how the vendor ended — and a run that moved nothing carries no `--changed` at all. The paths
  # the case above left dirty stand in both snapshots and are not this run's.
  clear_stub
  : >"$ANCHOR_LOG"
  export STUB_SLEEP=1 STUB_CODE=3
  "$RUNNER" start codex --brief "$WORK/brief" --workdir "$repo" \
    >"$WORK/anchors.out" 2>"$WORK/anchors.err" || fail "failing start failed: $(<"$WORK/anchors.err")"
  RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/anchors.out")
  assert await_done
  assert grep -q '^STATUS: failed' "$WORK/wait.out"
  fold=$(anchors_line run-fold)
  assert grep -qF -- "--run${anchors_tab}${RUN_ID}" <<<"$fold"
  assert_fails grep -qF -- '--changed' <<<"$fold"
  assert_fails grep -qF -- '--round' <<<"$fold"

  # No binary is not silence: the fact goes to the gaps file, which needs no repository, no lock
  # and no python, and the launching chat's verdict reads `?gap` until somebody looks.
  clear_stub
  : >"$ANCHOR_LOG"
  mv "$WORK/bin/review-anchors" "$WORK/bin/review-anchors.off"
  # A machine with no store to write to, which is not the machine the suite runs on: a real
  # `review-anchors` is installed beside it, and every directory holding one leaves the path.
  saved_path=$PATH
  PATH=$(IFS=:; keep=''
    for entry in $PATH; do
      { [ -z "$entry" ] || [ -x "$entry/review-anchors" ]; } && continue
      keep="${keep:+$keep:}$entry"
    done
    printf '%s' "$keep")
  export PATH
  export STUB_SLEEP=1
  start_ok codex --workdir "$repo"
  printf 'gap\n' >"$repo/bin/gap-file"
  assert await_done
  PATH=$saved_path
  export PATH
  assert test ! -s "$ANCHOR_LOG"
  assert grep -qxF "run-start${anchors_tab}${RUN_ID} $repo: review-anchors not on PATH" <<<"$(cut -f2- "$gaps")"
  assert grep -qxF "run-fold${anchors_tab}${RUN_ID} $repo: review-anchors not on PATH" <<<"$(cut -f2- "$gaps")"
  assert test "$(awk -F'\t' 'END { print ($1 ~ /^[0-9]+$/) }' "$gaps")" = 1
  mv "$WORK/bin/review-anchors.off" "$WORK/bin/review-anchors"

  # And a binary that refuses is the same case: the call is made, the failure is recorded.
  clear_stub
  : >"$ANCHOR_LOG"
  : >"$gaps"
  export STUB_SLEEP=1 ANCHORS_FAIL=1
  start_ok codex --workdir "$repo"
  assert await_done
  assert grep -q "^run-fold$anchors_tab" "$ANCHOR_LOG"
  assert grep -qxF "run-start${anchors_tab}${RUN_ID} $repo: review-anchors exited 3: store locked" <<<"$(cut -f2- "$gaps")"
  assert grep -qxF "run-fold${anchors_tab}${RUN_ID} $repo: review-anchors exited 3: store locked" <<<"$(cut -f2- "$gaps")"
  unset ANCHORS_FAIL

  # A workdir that became a repository during the run has nothing to fold; its families still do.
  clear_stub
  : >"$ANCHOR_LOG"
  : >"$gaps"
  born="$WORK/anchors-born"
  mkdir -p "$born"
  born=$(cd "$born" && pwd -P)
  printf '%s\n' "$repo" >"$HOME/.cache/claude/review-journal/anchors-chat.repos"
  export STUB_SLEEP=3
  WORKER_TEST_WORKDIR=$born start_ok codex
  git -C "$born" init -q .
  git -C "$born" -c user.email=t@t -c user.name=t commit -q --allow-empty -m born
  assert await_done
  rm -f "$HOME/.cache/claude/review-journal/anchors-chat.repos"
  assert_fails grep -qF "${anchors_tab}run-fold${anchors_tab}" "$gaps"
  assert_fails grep -qF "run-fold${anchors_tab}--repo${anchors_tab}${born}${anchors_tab}" "$ANCHOR_LOG"
  assert test ! -e "$born/.git/review-anchors.json"
  assert grep -qF "run-fold${anchors_tab}--repo${anchors_tab}${repo}${anchors_tab}--run${anchors_tab}${RUN_ID}" "$ANCHOR_LOG"

  # The vendor process is told both: whose debt what it writes is, and where its own run record is.
  clear_stub
  : >"$ANCHOR_LOG"
  export STUB_SLEEP=1
  start_ok claudeb --workdir "$repo"
  assert await_done
  assert test "$(cat "$STUB_DIR/debt_owner_env")" = anchors-chat
  assert test "$(cat "$STUB_DIR/run_record_env")" = "$RUN_DIR"

  clear_stub
  unset CLAUDE_CODE_SESSION_ID
}

# Web search, every vendor against every entry point, driven from the one table the launcher reads:
# a vendor or an entry point added without the capability fails here rather than answering a
# research brief from memory.
web_search_tests() {
  local vendor entry brief expected workdir state WEB_SEARCH_ENTRY=''
  . "$ROOT/share/web-search.sh"
  cat >"$WORK/bin/sandbox-exec" <<'SANDBOX'
#!/usr/bin/env bash
shift 2
exec "$@"
SANDBOX
  chmod +x "$WORK/bin/sandbox-exec"
  export GEMINI_RESEARCH_SANDBOX_EXEC="$WORK/bin/sandbox-exec"
  workdir="$WORK/websearch-workdir"
  # The research sandbox profile resolves the account's home with `readlink -f`, which fails on a
  # path that does not exist — without the directory gemini's research row dies as GEMINI_UNAVAILABLE.
  mkdir -p "$workdir" "$WORK/websearch" "$HOME/.gemini-profiles/websearch"
  git -C "$workdir" init -q
  printf 'base\n' >"$workdir/file"
  git -C "$workdir" add file
  git -C "$workdir" -c user.name=fixture -c user.email=fixture@example.test commit -qm base
  printf 'probe\nsecond line\n' >"$WORK/websearch/plain"
  printf 'WEB: on\nprobe\nsecond line\n' >"$WORK/websearch/on"
  printf 'WEB: off\nprobe\nsecond line\n' >"$WORK/websearch/off"
  printf 'web: ON\nprobe\nsecond line\n' >"$WORK/websearch/on-lower"
  printf 'SCOPE: file\nprobe\n' >"$WORK/websearch/light-plain"
  printf 'WEB: on\nSCOPE: file\nprobe\n' >"$WORK/websearch/light-on"
  printf 'websearch\n' >"$STUB_DIR/gemini_profiles"
  export PICK_RC=0 PICK_ACCOUNT=websearch

  web_search_launch() { # brief vendor extra-arg...
    local file="$1" target="$2"
    shift 2
    clear_stub
    printf 'websearch\n' >"$STUB_DIR/gemini_profiles"
    "$RUNNER" start "$target" --brief "$file" --workdir "$workdir" "$@" \
      >"$WORK/start.out" 2>"$WORK/start.err" || fail "web-search start $target failed: $(<"$WORK/start.err")"
    RUN_ID=$(sed -n 's/^RUN: //p' "$WORK/start.out")
    RUN_DIR=$(sed -n 's/^DIR: //p' "$WORK/start.out")
    WEB_SEARCH_ENTRY=$target
    assert await_done
  }

  # The stubs record each argument as `ARG=%q`, so a table cell carrying anything the shell quotes
  # (claudeb's `WebSearch,WebFetch`) never matches the raw cell text.
  web_search_quoted() { # argv words on stdin
    local word
    while IFS= read -r word; do printf '%q\n' "$word"; done
  }

  # The state's whole argv as one adjacent run, never word by word: `-c` is codex's ordinary config
  # flag and stands in both states and elsewhere in the command, so a per-word search reads a state
  # the run was never launched in.
  web_search_sequence_present() { # vendor state
    local needle haystack
    needle=$(web_search_args "$1" "$2" | web_search_quoted | paste -sd $'\x1f' -)
    [ -n "$needle" ] || return 1
    if [ "$WEB_SEARCH_ENTRY" = light ]; then
      # A Light edit run launches inside the write sandbox, which denies every path outside the Light
      # worktree and the run directory — the stub's shared call log among them — so the command the
      # launcher recorded is the only record of this entry point's argv.
      haystack=$'\x1f'$(jq -r '.cmd[]' "$RUN_DIR/meta.json" | web_search_quoted | paste -sd $'\x1f' -)$'\x1f'
    else
      haystack=$'\x1f'$(sed -n 's/^ARG=//p' "$CALL_LOG" | paste -sd $'\x1f' -)$'\x1f'
    fi
    case "$haystack" in *$'\x1f'"$needle"$'\x1f'*) return 0 ;; esac
    return 1
  }

  web_search_assert() { # vendor state
    local target="$1" want="$2" other=on
    [ "$want" = off ] || other=off
    [ -z "$(web_search_args "$target" "$want")" ] || assert web_search_sequence_present "$target" "$want"
    [ -z "$(web_search_args "$target" "$other")" ] || assert_fails web_search_sequence_present "$target" "$other"
    assert test "$(jq -r '.web_search' "$RUN_DIR/meta.json")" = "$([ "$want" = on ] && printf true || printf false)"
    # Named where a reader looks, not only in meta.json: the launch line and the report.
    assert grep -qx "WEB: $want" "$WORK/start.out"
    assert grep -qx "WEB: $want" <("$RUNNER" report "$RUN_ID")
  }

  # A state the vendor's column cannot reach, asked for outright: refused before an account is spent.
  web_search_refused() { # brief vendor extra-arg...
    local file="$1" target="$2" rc=0
    shift 2
    clear_stub
    printf 'websearch\n' >"$STUB_DIR/gemini_profiles"
    "$RUNNER" start "$target" --brief "$file" --workdir "$workdir" "$@" \
      >"$WORK/start.out" 2>"$WORK/start.err" || rc=$?
    assert test "$rc" -eq 4
    assert grep -qx 'OUTCOME: MODEL_REFUSED' "$WORK/start.out"
    assert grep -qF 'no switch that turns web search off' "$WORK/start.err"
    assert test ! -s "$CALL_LOG"
  }

  # The vendors come from the table: a row added without an entry point, or an entry point that
  # stops reading the table, is what this grid exists to catch — a hand-written list catches neither.
  for vendor in $(web_search_table | cut -f1); do
    # Both columns empty argv is only legal where the vendor HAS no off switch: a blank cell there
    # would read as "the CLI already does this" and hide a flag nobody wired.
    if [ -z "$(web_search_args "$vendor" on)" ] && [ -z "$(web_search_args "$vendor" off)" ]; then
      assert test "$(web_search_column "$vendor" off)" = '!'
    fi
    set_config 'claudeb_model=opus' 'claudeb_effort=high' 'codex_effort=low' \
      'gemini_model=flash38' 'gemini_effort=high' 'grok_model=auto' 'grok_effort=high' \
      "light_research=$vendor" "light_edit=$vendor"
    expected=$(web_search_state "$vendor" false)
    web_search_launch "$WORK/websearch/plain" "$vendor"
    web_search_assert "$vendor" "$expected"
    web_search_launch "$WORK/websearch/light-plain" light
    web_search_assert "$vendor" "$expected"

    expected=$(web_search_state "$vendor" true)
    web_search_launch "$WORK/websearch/plain" "$vendor" --web-search
    web_search_assert "$vendor" "$expected"
    web_search_launch "$WORK/websearch/on" "$vendor"
    web_search_assert "$vendor" "$expected"
    # The key and the state are case-insensitive: `web: ON` was silently ignored while `WEB: yes`
    # failed loudly, so the shape a caller guesses wrong is the one that costs a run.
    web_search_launch "$WORK/websearch/on-lower" "$vendor"
    web_search_assert "$vendor" "$expected"
    web_search_launch "$WORK/websearch/light-on" light
    web_search_assert "$vendor" "$expected"
    # Research needs no flag and no header: the role is the ask.
    web_search_launch "$WORK/websearch/plain" "$vendor" --role research
    web_search_assert "$vendor" "$expected"

    if [ "$(web_search_column "$vendor" off)" = '!' ]; then
      web_search_refused "$WORK/websearch/off" "$vendor" --role research
      web_search_refused "$WORK/websearch/plain" "$vendor" --no-web-search
    else
      expected=$(web_search_state "$vendor" false)
      web_search_launch "$WORK/websearch/off" "$vendor" --role research
      web_search_assert "$vendor" "$expected"
      web_search_launch "$WORK/websearch/plain" "$vendor" --no-web-search
      web_search_assert "$vendor" "$expected"
    fi
  done

  # A header that is neither state is a typo, not a default: launching on it would silently pick one.
  clear_stub
  printf 'WEB: maybe\nprobe\n' >"$WORK/websearch/bad"
  rc=0
  "$RUNNER" start claudeb --brief "$WORK/websearch/bad" --workdir "$workdir" \
    >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qF "brief header 'WEB: maybe' names no state" "$WORK/websearch.err"
  assert test ! -s "$CALL_LOG"

  # A WEB: line the header block cannot reach is refused, never dropped: a prose first line, a blank
  # line above the header, a space before the colon and a launcher's own prefix pushing it down all
  # used to launch a web-facing brief with search off and no word about it anywhere.
  printf 'probe\n\nWEB: on\n' >"$WORK/websearch/stray"
  printf 'WEB : on\nprobe\n' >"$WORK/websearch/spaced"
  printf 'REPOSITORY: /tmp\n\nWEB: on\nprobe\n' >"$WORK/websearch/pushed"
  for stray in stray spaced pushed; do
    clear_stub
    rc=0
    "$RUNNER" start claudeb --brief "$WORK/websearch/$stray" --workdir "$workdir" \
      >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
    assert test "$rc" -eq 4
    assert grep -qF 'spells a WEB: state worker-run does not read' "$WORK/websearch.err"
    assert test ! -s "$CALL_LOG"
  done
  # A body line that merely starts with `web:` names no state: `Web: <url>` is prose, not a header.
  printf 'probe\n\nWeb: https://example.test/page\n web: nginx\n' >"$WORK/websearch/prose"
  assert test "$(web_search_brief_state "$WORK/websearch/prose"; printf 'rc=%s' "$?")" = rc=0

  # Flag against header: the flag used to win in silence, so a brief that ruled live pages out was
  # launched on them by a caller who passed --web-search out of habit.
  while read -r flag brief; do
    clear_stub
    rc=0
    "$RUNNER" start claudeb --brief "$WORK/websearch/$brief" --workdir "$workdir" "$flag" \
      >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
    assert test "$rc" -eq 4
    assert grep -qF 'ask for opposite states' "$WORK/websearch.err"
    assert test ! -s "$CALL_LOG"
  done <<'CONTRADICTIONS'
--web-search off
--no-web-search on
CONTRADICTIONS
  clear_stub
  rc=0
  "$RUNNER" start claudeb --brief "$WORK/websearch/plain" --workdir "$workdir" --web-search --no-web-search \
    >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qF 'ask for opposite states' "$WORK/websearch.err"

  # A run recorded before the table existed carries no state at all, and the CLIs that search by
  # default did search: reported `off`, it promises a relaunch a capability its answer already had.
  for vendor in $(web_search_table | cut -f1); do
    expected=off
    [ "$(web_search_column "$vendor" on)" != '-' ] || expected=on
    jq -cn --arg v "$vendor" '{vendor:$v}' >"$WORK/websearch/legacy.json"
    assert test "$(web_search_meta_state "$WORK/websearch/legacy.json")" = "$expected"
    jq -cn --arg v "$vendor" '{vendor:$v,web_search:false}' >"$WORK/websearch/legacy.json"
    assert test "$(web_search_meta_state "$WORK/websearch/legacy.json")" = off
  done

  # The grok research leg is policed from outside by a tree digest, and the answer contract now asks
  # it to fetch pages: the fence rides in the launched brief only, never in the recorded one.
  set_config 'grok_model=auto' 'grok_effort=high' 'light_research=grok' 'light_edit=grok'
  web_search_launch "$WORK/websearch/plain" grok --role research
  assert grep -qF 'READ-ONLY TREE' "$RUN_DIR/brief.launch"
  assert test "$(grep -cF 'READ-ONLY TREE' "$RUN_DIR/brief")" = 0
  web_search_launch "$WORK/websearch/plain" grok
  assert test "$(grep -cF 'READ-ONLY TREE' "$RUN_DIR/brief.launch")" = 0

  # Off the light_research row the refusal names what to pass, not just that something is missing.
  set_config 'codex_effort=low' 'light_research=gemini' 'light_edit=gemini'
  clear_stub
  rc=0
  "$RUNNER" start codex --brief "$WORK/websearch/plain" --workdir "$workdir" --role research \
    >"$WORK/websearch.out" 2>"$WORK/websearch.err" || rc=$?
  assert test "$rc" -eq 4
  assert grep -qx 'OUTCOME: MODEL_REFUSED' "$WORK/websearch.out"
  assert grep -qF -- '--model <id>' "$WORK/websearch.err"
  assert grep -qF 'light ids (astra' "$WORK/websearch.err"
  assert test ! -s "$CALL_LOG"

  unset GEMINI_RESEARCH_SANDBOX_EXEC
  rm -f "$STUB_DIR/gemini_profiles"
  clear_stub
  set_config
}

web_search_tests

anchors_store_tests

attribution_repair_tests

echo "PASS: $asserts asserts; worker-run lifecycle, routing, snapshot attribution, transcript diagnostics, legacy claims, web search as one table every vendor and every entry point resolves through, the review-anchors store and launcher journal integration"
