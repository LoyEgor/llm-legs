#!/usr/bin/env bash
# bin/chat-pin: one chat's own pin line, moved only with the grant Egor's words wrote for that chat
# and that target. Every path is a fixture: HOME, CLAUDEB_DIR, CHAT_PINS_DIR and the limits store.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/bin/chat-pin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export CLAUDEB_DIR="$WORK/store"
export CHAT_PINS_DIR="$WORK/chat-pins"
export CODEXB_PROFILES_DIR="$WORK/codex-profiles"
export GEMINIB_PROFILES_DIR="$WORK/gemini-profiles"
export GROKB_PROFILES_DIR="$WORK/grok-profiles"
export LLM_LIMITS_FILE="$WORK/llm-limits.json"
export WORKER_PICK_CONFIG_FILE="$WORK/worker-model"
export CLAUDE_CODE_SESSION_ID=sess-1
unset WORKER_STATS_DIR WORKER_MODEL_PIN_TTL_MIN
mkdir -p "$HOME" "$CODEXB_PROFILES_DIR/.codexb"
printf 'benched\n' >"$CODEXB_PROFILES_DIR/.codexb/disabled"
cat >"$LLM_LIMITS_FILE" <<'JSON'
{"vendors": {
  "claude": {"accounts": [{"account": "alpha"}, {"account": "shared"}]},
  "codex": {"accounts": [{"account": "beta"}, {"account": "shared"}, {"account": "benched"}]},
  "gemini": {"accounts": [{"account": "gamma"}]},
  "grok": {"accounts": [{"account": "delta"}, {"account": "gone", "removed": true}]}
}}
JSON

CHAT="$CHAT_PINS_DIR/sess-1"
GRANT="$CLAUDEB_DIR/worker-stats/pin-grants/chat-sess-1"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }
contains() { grep -Fq -- "$2" <<<"$1"; }
chat_is() { [ "$(cat "$CHAT" 2>/dev/null)" = "$1" ]; }
exits() { # code command...
  local want=$1 got
  shift
  "$@" >"$WORK/out" 2>&1
  got=$?
  [ "$got" = "$want" ] || { printf 'exit %s, wanted %s: %s\n' "$got" "$want" "$(cat "$WORK/out")" >&2; return 1; }
}
grant() { mkdir -p "$(dirname "$GRANT")"; printf '%s\n' "$1" >"$GRANT"; }

# --- Outside a session: no grant needed ---------------------------------------------------------
unset CLAUDECODE
assert contains "$("$PIN")" 'no chat pin'
assert "$PIN" codex
assert chat_is 'codex_profile=*'
assert contains "$("$PIN")" 'every codex pool account (*)'
# One line, replaced: a second pin never stands beside the first.
assert "$PIN" claude
assert chat_is 'claudeb_profile=*'
assert "$PIN" gemini
assert chat_is 'gemini_profile=*'
assert "$PIN" grok
assert chat_is 'grok_profile=*'
assert "$PIN" claudeb
assert chat_is 'claudeb_profile=*'

# --- An account name finds its vendor through the live pool -------------------------------------
assert "$PIN" beta
assert chat_is 'codex_profile=beta'
assert contains "$("$PIN")" 'pins workers to beta (codex)'
assert "$PIN" alpha
assert chat_is 'claudeb_profile=alpha'
assert "$PIN" delta
assert chat_is 'grok_profile=delta'
assert exits 2 "$PIN" shared
assert contains "$(cat "$WORK/out")" 'ambiguous account'
assert chat_is 'grok_profile=delta'
for missing in nobody benched gone 'bad/name' '-x'; do
  assert exits 2 "$PIN" "$missing"
  assert chat_is 'grok_profile=delta'
done

assert "$PIN" auto
assert_fails test -e "$CHAT"
assert contains "$("$PIN" auto)" 'no chat pin'
assert exits 2 "$PIN" codex extra

# --- No session id: nothing to pin to ------------------------------------------------------------
for sid in '' '../x' 'a/b'; do
  assert exits 2 env CLAUDE_CODE_SESSION_ID="$sid" "$PIN" codex
  assert contains "$(cat "$WORK/out")" 'no session id'
  assert exits 2 env CLAUDE_CODE_SESSION_ID="$sid" "$PIN"
done
assert_fails test -e "$CHAT_PINS_DIR/x"

# --- Inside a session: only his grant, for this chat and this target, opens it ------------------
export CLAUDECODE=1
rm -f "$GRANT"
assert exits 3 "$PIN" codex
assert contains "$(cat "$WORK/out")" "no fresh grant for 'codex'"
assert_fails test -e "$CHAT"

grant gemini
assert exits 3 "$PIN" codex
assert_fails test -e "$CHAT"

grant codex
assert "$PIN" codex
assert chat_is 'codex_profile=*'

# The alias the hook writes is the vendor key, so `claude` spends a `claudeb` grant.
grant claudeb
assert "$PIN" claude
assert chat_is 'claudeb_profile=*'

# Case never decides a grant: the hook folds his words, the pool keeps its own spelling.
grant BETA
assert "$PIN" beta
assert chat_is 'codex_profile=beta'

# Another chat's grant opens nothing here.
rm -f "$GRANT"
mkdir -p "$(dirname "$GRANT")"
printf 'codex\n' >"$(dirname "$GRANT")/chat-sess-2"
assert exits 3 "$PIN" codex
assert chat_is 'codex_profile=beta'

grant auto
touch -t 202601010000 "$GRANT"
assert exits 3 "$PIN" auto
assert chat_is 'codex_profile=beta'
grant auto
assert "$PIN" auto
assert_fails test -e "$CHAT"

# The TTL is the module's knob, not a second clock.
grant grok
touch -t "$(date -v-10M +%Y%m%d%H%M)" "$GRANT"
assert exits 3 env WORKER_MODEL_PIN_TTL_MIN=5 "$PIN" grok
assert env WORKER_MODEL_PIN_TTL_MIN=30 "$PIN" grok
assert chat_is 'grok_profile=*'

# Reading the state is never gated.
rm -f "$GRANT"
assert contains "$("$PIN")" 'every grok pool account (*)'

# --- The pin reaches the one resolver every reader uses -----------------------------------------
. "$ROOT/share/worker-model.sh"
assert [ "$(worker_model_pin_scope grok)" = vendor ]
assert [ "$(worker_model_pins grok)" = delta ]
assert [ "$(worker_model_pin_scope codex)" = none ]

printf 'PASS: %s asserts; chat-pin writes one pin line for one chat — a vendor as `*`, an account through the vendor whose live pool holds it, ambiguous and unknown names refused — and inside a session only with a fresh grant naming this chat and this target\n' "$asserts"
