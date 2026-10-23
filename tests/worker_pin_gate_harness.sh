# Shared by tests/test_worker_pin_gate*.sh: bin/worker-pin-gate.sh in a sandbox HOME, its event builders
# and asserts. No network, no daemon; every pin file is a fixture.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/bin/worker-pin-gate.sh"
# The gate reads the parsed command through claude-setup's hooks/lib/argv.sh.
. "$ROOT/share/test-scope.sh"
export ARGV_LIB="${CLAUDE_SETUP_ROOT:-$(git_projects "$ROOT")/claude-setup}/hooks/lib/argv.sh"
[ -r "$ARGV_LIB" ] || { echo "FAIL: argv.sh not readable (set CLAUDE_SETUP_ROOT)" >&2; exit 1; }
WORK="$(mktemp -d)"
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
trap 'rm -rf "$WORK"' EXIT
export CLAUDEB_DIR="$WORK/store"
unset LLM_LIMITS_FILE CODEXB_PROFILES_DIR GEMINIB_PROFILES_DIR GROKB_PROFILES_DIR

# The sandbox HOME comes FIRST, before a single assertion: both doors resolve the pin under $HOME
# and read the pin lines standing in it, so anything asserted against the real $HOME is a test whose
# outcome is Egor's live worker-model — passing here, flaking on a clean machine.
export HOME="$WORK/home"
mkdir -p "$HOME/.claude"
printf 'worker=auto\nclaudeb_model=opus\n' >"$HOME/.claude/worker-model"
PIN_FILE="$HOME/.claude/worker-model"

asserts=0
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
denied() { contains "$1" '"permissionDecision":"deny"'; }
allowed() { lacks "$1" '"permissionDecision"'; }

write_event() {
  jq -cn --arg p "$1" --arg c "${2-claudeb_profile=beta}" \
    '{hook_event_name: "PreToolUse", session_id: "s", tool_name: "Write",
      tool_input: {file_path: $p, content: $c}}' \
    | "$GATE" write
}

edit_event() {
  jq -cn --arg p "$1" --arg o "$2" --arg n "$3" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit",
      tool_input: {file_path: $p, old_string: $o, new_string: $n}}' \
    | "$GATE" write
}

read_event() {
  jq -cn --arg p "$1" \
    '{hook_event_name: "PreToolUse", tool_name: "Read", tool_input: {file_path: $p}}' \
    | "$GATE" write
}

bash_event() {
  jq -cn --arg c "$1" \
    '{hook_event_name: "PreToolUse", session_id: "s", tool_name: "Bash", tool_input: {command: $c}}' |
    "$GATE" bash
}

# The model check reads a shell write too, and only a write: each case carries an unlisted model on
# a comment line of its own, so a write the door sees is denied and a read passes.
written() { denied "$(bash_event "$1"$'\n''# codex_model=gpt-5.6-terra')"; }
not_written() { allowed "$(bash_event "$1"$'\n''# codex_model=gpt-5.6-terra')"; }
