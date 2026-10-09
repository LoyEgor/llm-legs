# Sourced by every tests/test_worker_run_*.sh: each suite builds its own $WORK of stubs from here.
set -u
# worker-run opens start and wait outside Claude Code only; its relay door is tested with CLAUDECODE set.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDEB_WORKER GROK_WORKER WORKER_RUN_ID WORKER_RUN_RELAY WORKER_RUN_RECORD

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/bin/worker-run"
WORK="$(mktemp -d)"
. "$ROOT/share/test-scope.sh"
if test_scope_narrowed "$0" WORKER_RUN_TEST_; then
  test_scope_partial "$0"
fi
# Hundreds of 0.05 s polls per suite: a forked `sleep` each cost more than the pause under load.
enable -f "${BASH%/bin/*}/lib/bash/sleep" sleep 2>/dev/null || :
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
  # No worker waits for a full run: night 2026-10-04 queued workers 2-3 h for a run-all slot.
  assert grep -qF 'never the full `tests/run-all`' "$1"
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
# How often a `wait --max N` looks again, never what it reports: 5s per round was most of this suite.
export WORKER_RUN_WAIT_POLL_S=1
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
export CAFFEINATE_LOG="$WORK/caffeinate.calls"
cat >"$WORK/bin/caffeinate" <<'CAFFEINATE'
#!/usr/bin/env bash
printf '%s run-id=%s\n' "$*" "${WORKER_RUN_ID-unset}" >>"$CAFFEINATE_LOG"
exit 1
CAFFEINATE
chmod +x "$WORK/bin/caffeinate"
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
  if [ "$1" != 0 ]; then
    [ -z "${PICK_STDERR:-}" ] || printf '%s\n' "$PICK_STDERR" >&2
    exit "$1"
  fi
  [ -z "${PICK_CLAIMS:-}" ] || { mkdir -p "$PICK_CLAIMS/codex" && touch "$PICK_CLAIMS/codex/$2"; }
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
printf '%s\n' "${WORKER_RUN_ID-}" >"$STUB_DIR/run_id_env"
printf '%s\n' "${CLAUDE_CODE_DISABLE_BACKGROUND_TASKS-__unset__} ${BASH_MAX_TIMEOUT_MS-__unset__} ${BASH_DEFAULT_TIMEOUT_MS-__unset__}" >"$STUB_DIR/background_env"
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
  while IFS= read -r edit_path; do
    [ -n "$edit_path" ] || continue
    jq -cn --arg path "$edit_path" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{timestamp:$timestamp,type:"assistant",message:{content:[{type:"tool_use",name:"Edit",input:{file_path:$path}}]}}' \
      >>"$transcript_dir/$transcript_name.jsonl"
  done <<<"${STUB_EDIT_PATH:-}"
  [ -z "${STUB_TRANSCRIPT_SAY:-}" ] ||
    jq -cn --arg t "$STUB_TRANSCRIPT_SAY" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{timestamp:$timestamp,type:"assistant",message:{content:[{type:"text",text:$t}]}}' \
      >>"$transcript_dir/$transcript_name.jsonl"
fi
if [ -n "${STUB_TRANSCRIPT_GROW:-}" ] && [ -n "${STUB_TRANSCRIPT_SESSION:-}" ]; then
  # A working claudeb writes NOTHING to stdout until its very last line; the transcript growing is
  # the whole evidence that the run is alive.
  grown=0
  while [ "$grown" -lt "${STUB_SLEEP:-0}" ]; do
    sleep 1
    grown=$((grown + 1))
    [ "$grown" -le "${STUB_TRANSCRIPT_GROW_TURNS:-$grown}" ] || continue
    jq -cn --arg n "$grown" \
      '{type:"assistant",message:{content:[{type:"text",text:("turn " + $n)}]}}' \
      >>"$transcript_dir/$transcript_name.jsonl"
  done
else
  [ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
fi
[ -z "${STUB_BURN:-}" ] || while [ ! -e "$STUB_GATE" ] && [ -d "${STUB_GATE%/*}" ]; do :; done
[ -z "${STUB_GATE:-}" ] || enable -f "${BASH%/bin/*}/lib/bash/sleep" sleep 2>/dev/null || :
[ -z "${STUB_GATE:-}" ] || while [ ! -e "$STUB_GATE" ] && [ -d "${STUB_GATE%/*}" ]; do sleep 0.05; done
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
  [ -z "${STUB_WALL_SESSION:-}" ] || printf 'session id: %s\n' "$STUB_WALL_SESSION" >&2
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
[ -z "${STUB_GATE:-}" ] || enable -f "${BASH%/bin/*}/lib/bash/sleep" sleep 2>/dev/null || :
[ -z "${STUB_GATE:-}" ] || while [ ! -e "$STUB_GATE" ] && [ -d "${STUB_GATE%/*}" ]; do sleep 0.05; done
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
  unset STUB_SLEEP STUB_HEARTBEAT STUB_TRANSCRIPT_SESSION STUB_TRANSCRIPT_ACCOUNT STUB_TRANSCRIPT_SAY STUB_TRANSCRIPT_GROW STUB_TRANSCRIPT_GROW_TURNS \
    STUB_EDIT_PATH STUB_PICK_WALL STUB_BURN STUB_WALL_SESSION \
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
  await_launched
}

# The floor is taken by the supervisor before its CLI starts: a fixture write before that is no run's.
await_launched() {
  local tick
  for tick in $(seq 1 400); do
    { [ -e "$RUN_DIR/exit_code" ] || jq -e '.cli_pid // empty' "$RUN_DIR/meta.json" >/dev/null 2>&1; } && return 0
    sleep 0.05
  done
}

gate_shut() {
  export STUB_GATE="$WORK/gate.$$"
  rm -f "$STUB_GATE"
}

start_gated() {
  gate_shut
  start_ok "$@"
}

gate_open() {
  : >"$STUB_GATE"
  unset STUB_GATE
}

await_done() {
  local output index tick pid
  for index in $(seq 1 500); do
    # The file only paces the loop; `wait` alone decides. It runs once the exit code is there, at
    # once when the supervisor is gone (dying without an exit code is terminal too), and every 5th
    # round regardless: a running `wait` builds a full report, ~1.5 s under load, most of a case.
    for tick in {1..20}; do
      [ ! -e "$WORKER_RUN_DIR/$RUN_ID/exit_code" ] || break
      sleep 0.05
    done
    if [ ! -e "$WORKER_RUN_DIR/$RUN_ID/exit_code" ] && [ $((index % 5)) -ne 0 ]; then
      pid=$(jq -r '.pid // 0' "$WORKER_RUN_DIR/$RUN_ID/meta.json" 2>/dev/null) || pid=0
      [ "${pid:-0}" -le 0 ] 2>/dev/null || ! kill -0 "$pid" 2>/dev/null || continue
    fi
    output=$("$RUNNER" wait "$RUN_ID" --max 0)
    if grep -q '^STATUS: done\|^STATUS: failed' <<<"$output"; then
      printf '%s\n' "$output" >"$WORK/wait.out"
      return 0
    fi
  done
  return 1
}

meta_account_is() { [ "$(jq -r '.account' "$RUN_DIR/meta.json")" = "$1" ]; }
meta_agy_is() { [ "$(jq -r '.agy_model' "$RUN_DIR/meta.json")" = "$1" ]; }

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
tool_call() {
  jq -cn --arg name "$1" --arg key "$2" --arg path "$3" --arg id "${4-}" --arg ts "$TOOL_TS" \
    '{type: "assistant", timestamp: $ts,
      message: {content: [{type: "tool_use", name: $name, input: {($key): $path}}
      + (if $id == "" then {} else {id: $id} end)]}}'
}

dirt_repo_init() {
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
}

pool_dir_for() {
  case "$1" in
    claudeb) printf '%s/.claude-profiles/.claudeb\n' "$HOME" ;;
    codex) printf '%s/.codex-profiles/.codexb\n' "$HOME" ;;
    gemini) printf '%s/.gemini-profiles/.geminib\n' "$HOME" ;;
    grok) printf '%s/.grok-profiles/.grokb\n' "$HOME" ;;
  esac
}

transcript_report() (
  local directory="$1" name workdir count
  local SCRIPT_DIRECTORY="$ROOT/bin" gemini_base_home="$HOME" gemini_profiles_dir="$GEMINIB_PROFILES_DIR"
  . "$ROOT/share/gemini-accounts.sh"
  if [ ! -s "$WORK/transcript-report.fns" ]; then
    for name in compute_transcript_files compute_transcript_rows session_id session_transcript codex_home grok_home \
        grok_end_field grok_session_dir_matches classify_tool_rows resolve_tool_path \
        writes_through_shell gemini_tool_rows codex_tool_rows grok_tool_rows transcript_files \
        listing_spelling transcript_wrote_through_shell workdir_escape_line; do
      sed -n "/^$name() {/,/^}/p" "$RUNNER"
    done >"$WORK/transcript-report.fns"
    sed -n '/^SHELL_FLOOR_PARTIAL=/p' "$RUNNER" >>"$WORK/transcript-report.fns"
  fi
  . "$WORK/transcript-report.fns"
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
