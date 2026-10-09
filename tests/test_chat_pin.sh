#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/chat-pin: one chat's own pin line. Every path is a fixture: HOME, CLAUDEB_DIR, CHAT_PINS_DIR and the limits store.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/share/test-scope.sh"
PROJECTS=$(git_projects "$ROOT")
PIN="$ROOT/bin/chat-pin"
WORK="$(mktemp -d)"
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
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
unset WORKER_STATS_DIR
mkdir -p "$HOME" "$CODEXB_PROFILES_DIR/.codexb"
printf 'benched\n' >"$CODEXB_PROFILES_DIR/.codexb/disabled"
cat >"$LLM_LIMITS_FILE" <<'JSON'
{"vendors": {
  "claude": {"accounts": [{"account": "alpha"}, {"account": "shared"}]},
  "codex": {"accounts": [{"account": "beta"}, {"account": "shared"}, {"account": "benched"}]},
  "gemini": {"accounts": [{"account": "gamma"}, {"account": "Zeta"}]},
  "grok": {"accounts": [{"account": "delta"}, {"account": "gone", "removed": true}]}
}}
JSON

CHAT="$CHAT_PINS_DIR/sess-1"

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

# --- Outside a session ------------------------------------------------------------------------
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
# «воркер на все»: one line that opens every vendor and pins none.
assert "$PIN" all
assert chat_is 'open=all'
assert contains "$("$PIN")" 'opens every vendor for workers and reviews'
assert "$PIN" все
assert chat_is 'open=all'

# --- Fast is a modifier of the pin: two lines, written and replaced together ---------------------
assert "$PIN" grok-fast
assert chat_is 'grok_profile=*
grok_fast=on'
assert contains "$("$PIN")" 'every grok pool account (*) · fast'
# The plain vendor pin is what turns fast off.
assert "$PIN" grok
assert chat_is 'grok_profile=*'
assert_fails contains "$("$PIN")" 'fast'
assert "$PIN" codex-fast
assert chat_is 'codex_profile=*
codex_fast=on'
# Only the two CLIs with a fast twin take the word; anything else is an account name and there is
# no account called that.
assert exits 2 "$PIN" gemini-fast
assert contains "$(cat "$WORK/out")" 'unknown account: gemini-fast'
assert exits 2 "$PIN" claudeb-fast
assert "$PIN" auto
assert_fails test -e "$CHAT"

# --- An account name finds its vendor through the live pool -------------------------------------
assert "$PIN" beta
assert chat_is 'codex_profile=beta'
assert contains "$("$PIN")" 'pins workers to beta (codex)'
assert contains "$("$PIN")" 'its reviews may use codex too'
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

# --- Inside a session: any target moves this chat's pin, no word of his needed ------------------
export CLAUDECODE=1
assert "$PIN" codex
assert chat_is 'codex_profile=*'
assert "$PIN" claude
assert chat_is 'claudeb_profile=*'
assert "$PIN" beta
assert chat_is 'codex_profile=beta'
assert exits 2 "$PIN" zeta
assert "$PIN" Zeta
assert chat_is 'gemini_profile=Zeta'
assert "$PIN" grok-fast
assert chat_is 'grok_profile=*
grok_fast=on'
assert "$PIN" all
assert chat_is 'open=all'
assert "$PIN" auto
assert_fails test -e "$CHAT"
assert "$PIN" grok
assert contains "$("$PIN")" 'every grok pool account (*)'
assert "$PIN" grok-fast

# --- The pin reaches the one resolver every reader uses -----------------------------------------
. "$ROOT/share/worker-model.sh"
assert [ "$(worker_model_pin_scope grok)" = vendor ]
assert [ "$(worker_model_pins grok)" = delta ]
assert [ "$(worker_model_pin_scope codex)" = none ]
# The fast line rides beside the pin without becoming one, and only for the vendor it names.
assert worker_model_chat_fast grok
assert_fails worker_model_chat_fast codex

# A wall that empties the chat file removes it.
export WORKER_WALLS_DIR="$WORK/walls"
worker_walls_record grok delta "$(($(date +%s) + 3600))"
assert worker_model_clear_walled_pin grok delta 2>/dev/null
assert_fails test -e "$CHAT"
assert [ "$(worker_model_pin_scope grok)" = none ]
: >"$CHAT"
assert exits 0 "$PIN" auto
assert contains "$(cat "$WORK/out")" 'no chat pin'

# A `*` pin's first account is worker-pick's pick among the pins, never the store's order.
FAKE="$WORK/fake-root"
mkdir -p "$FAKE/share" "$FAKE/bin"
cp "$ROOT"/share/worker-model.sh "$ROOT"/share/worker-pool.sh "$ROOT"/share/worker-walls.sh "$FAKE/share/"
printf 'codex_profile=*\n' >"$CHAT"
first_with_pick() { # stub body → pin_first codex
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$FAKE/bin/worker-pick"
  chmod +x "$FAKE/bin/worker-pick"
  (. "$FAKE/share/worker-model.sh" && worker_model_pin_first codex)
}
assert [ "$(first_with_pick '[ "$*" = "--account codex" ] && echo shared')" = shared ]
assert [ "$(first_with_pick 'echo benched')" = beta ]
assert [ "$(first_with_pick 'exit 3')" = beta ]
printf 'codex_profile=shared,beta\n' >"$CHAT"
assert [ "$(first_with_pick 'echo beta')" = shared ]

# An unreadable limits store expands `*` to nothing, and says which file it could not read.
printf 'codex_profile=*\n' >"$CHAT"
assert [ -z "$(LLM_LIMITS_FILE="$WORK/missing.json" worker_model_pins codex 2>"$WORK/err")" ]
assert contains "$(cat "$WORK/err")" "$WORK/missing.json"

printf 'PASS: %s asserts; chat-pin writes one pin line for one chat — a vendor as `*`, an account through the vendor whose live pool holds it, `codex-fast`/`grok-fast` adding a second `<vendor>_fast=on` line that any other target clears, ambiguous and unknown names refused — inside a session or out, with no word of his needed\n' "$asserts"
