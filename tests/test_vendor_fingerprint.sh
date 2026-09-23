#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
HOLDER=""
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  "$@" && fail "assert $asserts unexpectedly succeeded: $*"
  return 0
}
jqe() { jq -e "$@" >/dev/null; }

HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
DATA="$WORK/data"
OPENED="$WORK/opened"
export HOME DATA OPENED
unset CODEXB_PROFILES_DIR VENDOR_CLI_UPDATE_STATE_DIR VENDOR_FINGERPRINT_LOCKED GROK_HOME GROKB_CACHE_DIR
unset VENDOR_FINGERPRINT_NATIVE_codex VENDOR_FINGERPRINT_NATIVE_grok VENDOR_FINGERPRINT_NATIVE_gemini VENDOR_FINGERPRINT_NATIVE_claude
export VENDOR_FINGERPRINT_OPENER="$FAKE_BIN/opener"
# Only the fakes: the real CLIs live in ~/.local/bin, nvm and /usr/local/bin, none of which is here.
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
CODEX_PACKAGE="$WORK/node/lib/node_modules/@openai/codex"
CODEX_NATIVE="$CODEX_PACKAGE/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
STATE="$HOME/.cache/vendor-cli-update"
EVENTS="$STATE/events"
LOG="$STATE/update.log"
mkdir -p "$FAKE_BIN" "$DATA" "$(dirname "$CODEX_NATIVE")" "$CODEX_PACKAGE/bin" "$HOME/.grok/bin" "$HOME/.grok/docs" \
  "$HOME/.codex" "$HOME/.codex-profiles/a/skills/.system/imagegen" "$HOME/.cache/grokb" "$STATE"
: >"$OPENED"

cat >"$DATA/behave" <<'EOF'
#!/usr/bin/env bash
vendor=$1
shift
case "$vendor:$*" in
  codex:--version) printf 'codex-cli %s\n' "$(cat "$DATA/ver-codex")" ;;
  grok:--version) printf 'grok %s (4220f3b224a6) [alpha]\n' "$(cat "$DATA/ver-grok")" ;;
  agy:--version) cat "$DATA/ver-agy" ;;
  claude:--version) printf '%s (Claude Code)\n' "$(cat "$DATA/ver-claude")" ;;
  agy:--help) cat "$DATA/help-agy" >&2 ;;
  *:--help) cat "$DATA/help-$vendor" ;;
  "codex:exec --help") cat "$DATA/help-codex-exec" ;;
  "codex:features list") cat "$DATA/features" ;;
  agy:models)
    [ ! -e "$DATA/agy-models-fail" ] || exit 1
    printf 'Fetching available models...\n'
    cat "$DATA/models-agy"
    ;;
esac
EOF
chmod +x "$DATA/behave"
# A CLI is its own native binary unless the vendor ships a launcher: its model ids are strings in it.
fake_cli() { # path vendor ids...
  local path=$1 vendor=$2
  shift 2
  printf '#!/usr/bin/env bash\n# %s\nexec "$DATA/behave" %s "$@"\n' "$*" "$vendor" >"$path"
  chmod +x "$path"
}
fake_cli "$CODEX_PACKAGE/bin/codex.js" codex
ln -s "$CODEX_PACKAGE/bin/codex.js" "$FAKE_BIN/codex"
printf 'openai gpt-6-sol gpt-5.6-lunaopenai gpt-5.6-luna gpt-image-2 gpt-5.2-codexgemini-3.6-flash-high\n' >"$CODEX_NATIVE"
fake_cli "$FAKE_BIN/grok" grok
printf 'grok-4.7 grok-imagine-video-1.5\n' >"$HOME/.grok/bin/grok-1.0.41"
ln -s grok-1.0.41 "$HOME/.grok/bin/grok"
fake_cli "$FAKE_BIN/agy" agy gemini-3.8-flash gemini-3.1-flash-image
fake_cli "$FAKE_BIN/claude" claude claude-opus-5-5 claude-sonnet-5
cat >"$FAKE_BIN/opener" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$DATA/opener-fails" ] || exit 1
printf '%s\n' "$*" >>"$OPENED"
EOF
chmod +x "$FAKE_BIN/opener"
printf '#!/usr/bin/env bash\ncat "$DATA/pick"\n' >"$FAKE_BIN/worker-pick"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/claudeb"
chmod +x "$FAKE_BIN/worker-pick" "$FAKE_BIN/claudeb"
printf 'acct-b\n' >"$DATA/pick"

printf '0.156.1\n' >"$DATA/ver-codex"
printf '1.0.41\n' >"$DATA/ver-grok"
printf '1.2.9\n' >"$DATA/ver-agy"
printf '2.1.280\n' >"$DATA/ver-claude"
printf 'Codex CLI\n  --model <MODEL>\n' >"$DATA/help-codex"
printf 'Run Codex non-interactively\n  --json\n' >"$DATA/help-codex-exec"
printf 'grok usage\n  -p, --print\n' >"$DATA/help-grok"
printf 'Usage of agy:\n  --model  Model for the current CLI session\n' >"$DATA/help-agy"
printf 'Claude Code 2.1.280\n  --model <model>\n' >"$DATA/help-claude"
printf 'image_generation         stable             true\nagent_message_board      under development  false\n' >"$DATA/features"
printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n' >"$DATA/models-agy"
printf 'image generation skill\n' >"$HOME/.codex-profiles/a/skills/.system/imagegen/SKILL.md"
printf '# Headless\n' >"$HOME/.grok/docs/14-headless-mode.md"
printf '{"models":[{"slug":"grok-4.7","default":true,"label":"grok-4.7"}]}\n' >"$HOME/.cache/grokb/models.json"
codex_cache() { # home client-version models-json
  printf '{"client_version":"%s","fetched_at":"2026-09-23T00:00:00Z","models":%s}\n' "$2" "$3" >"$1/models_cache.json"
}
PROMPT=$(printf 'You are Codex. %.0s' $(seq 1 40))
codex_cache "$HOME/.codex-profiles/a" 0.156.1 \
  "[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"model_messages\":{\"instructions_template\":\"$PROMPT\"}}]"
# The ChatGPT app's older codex wrote this home: its list is not the installed client's.
codex_cache "$HOME/.codex" 0.154.0 '[{"slug":"gpt-5.6-sol"}]'

SCRIPT="$ROOT/bin/vendor-fingerprint"
check() { bash "$SCRIPT" check "$@"; }
quiet() { "$@" 2>/dev/null; }
events() { find "$EVENTS" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
last_event() { ls -t "$EVENTS"/*.json 2>/dev/null | head -n 1; }
field() { jq -r "$1" "$(last_event)"; }

# The first check is the baseline: every installed vendor is recorded and nothing is reported.
check || fail "check exited non-zero"
for vendor in codex grok gemini claude; do assert test -s "$STATE/fingerprints/$vendor.json"; done
assert [ "$(events)" = 0 ]
assert [ ! -s "$OPENED" ]
assert [ "$(grep -c ' baseline ' "$LOG")" = 4 ]
FP_CODEX="$STATE/fingerprints/codex.json"
assert jqe '.facets.catalog | keys == ["gpt-6-sol"]' "$FP_CODEX"
assert jqe '.facets.catalog["gpt-6-sol"].model_messages == {}' "$FP_CODEX"
assert jqe '.facets.catalog_text | keys == ["gpt-6-sol.model_messages.instructions_template"]' "$FP_CODEX"
assert jqe '.facets.features == ["image_generation stable", "agent_message_board under development"]' "$FP_CODEX"
assert jqe '.facets.docs | keys == ["imagegen/SKILL.md"]' "$FP_CODEX"
# Model ids from the native binary, not the launcher; glued neighbours are cut off.
assert jqe '.facets.ids == ["gemini-3.6-flash-high", "gpt-5.2-codex", "gpt-5.6-luna", "gpt-6-sol", "gpt-image-2"]' "$FP_CODEX"
assert jqe '.facets.ids == ["grok-4.7", "grok-imagine-video-1.5"]' "$STATE/fingerprints/grok.json"
assert jqe '.facets["help: agy --help"] | test("Model for the current CLI session")' "$STATE/fingerprints/gemini.json"
assert jqe '.facets["help: claude --help"] | test("Claude Code <version>")' "$STATE/fingerprints/claude.json"
assert jqe '.facets.probe_failures == []' "$STATE/fingerprints/claude.json"

check
assert [ "$(events)" = 0 ]

# A release that changes nothing but the version closes itself.
printf '2.1.281\n' >"$DATA/ver-claude"
printf 'Claude Code 2.1.281\n  --model <model>\n' >"$DATA/help-claude"
check
assert [ "$(events)" = 1 ]
assert [ "$(field .status)" = auto-closed ]
assert [ "$(field '.changed | join(",")')" = version ]
assert [ "$(field '"\(.from) \(.to)"')" = "2.1.280 2.1.281" ]
assert [ ! -s "$OPENED" ]

# A new model id in the binary opens one integration chat on the strong model, in this repository.
printf 'grok-4.7 grok-imagine-video-1.5 grok-imagine-image-3.0\n' >"$HOME/.grok/bin/grok-1.0.41"
check
assert [ "$(events)" = 2 ]
id=$(field .id)
assert [ "$(field .vendor)" = grok ]
assert [ "$(field .status)" = open ]
assert [ "$(field '.substantive | join(",")')" = ids ]
assert grep -qxF '+grok-imagine-image-3.0' "$EVENTS/$id.diff"
assert [ "$(cat "$OPENED")" = "$EVENTS/$id.command" ]
assert grep -qxF "cd $(printf '%q' "$ROOT") || exit 1" "$EVENTS/$id.command"
launch_sid=$(sed -n 's/^CLAUDE_CODE_SESSION_ID=\([^ ]*\) .*/\1/p' "$EVENTS/$id.command")
assert grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' <<<"$launch_sid"
assert grep -qF -- "exec $FAKE_BIN/claudeb profile acct-b --session-id $launch_sid --model opus --effort high Vendor\\ release\\ event\\ $id:\\ read\\ $ROOT/docs/vendor-release.md" "$EVENTS/$id.command"
# The chat it opens has every vendor open: the pin line lands in that session's chat pin file.
launch_pins="$WORK/chat-pins"
sed -n '/^CLAUDE_CODE_SESSION_ID=/p' "$EVENTS/$id.command" >"$WORK/pin-line.sh"
env -u CLAUDECODE CHAT_PINS_DIR="$launch_pins" bash "$WORK/pin-line.sh"
assert [ "$(cat "$launch_pins/$launch_sid")" = open=all ]
assert [ "$(field '.launched_at != null')" = true ]
check
assert [ "$(wc -l <"$OPENED" | tr -d ' ')" = 1 ]

# A new catalog field is substantive; a changed prompt alone is recorded and closes itself.
: >"$OPENED"
codex_cache "$HOME/.codex-profiles/a" 0.156.1 \
  "[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"supports_computer_use\":true,\"model_messages\":{\"instructions_template\":\"$PROMPT\"}}]"
check
assert [ "$(field .vendor)" = codex ]
assert [ "$(field '.substantive | join(",")')" = catalog ]
assert grep -qxF '+gpt-6-sol.supports_computer_use = true' "$(field .diff)"
assert [ "$(wc -l <"$OPENED" | tr -d ' ')" = 1 ]
codex_cache "$HOME/.codex-profiles/a" 0.156.1 \
  "[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"supports_computer_use\":true,\"model_messages\":{\"instructions_template\":\"$PROMPT changed\"}}]"
check
assert [ "$(field '.changed | join(",")')" = catalog_text ]
assert [ "$(field .status)" = auto-closed ]

# Accounts served different catalogs: a field they disagree on is recorded as its value set, and
# ~/.codex dropping in and out of the homes as the app and our client take turns writing it is no
# release.
count=$(events)
VARIANT="[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"supports_computer_use\":true,\"default_service_tier\":\"priority\",\"model_messages\":{\"instructions_template\":\"$PROMPT changed\"}}]"
mkdir -p "$HOME/.codex-profiles/b"
ln -s "$HOME/.codex-profiles/a/skills" "$HOME/.codex/skills"
codex_cache "$HOME/.codex-profiles/b" 0.156.1 "$VARIANT"
check
assert [ "$(events)" = $((count + 1)) ]
assert [ "$(field '.substantive | join(",")')" = catalog ]
assert grep -qxF '+gpt-6-sol.default_service_tier.per_account.1 = "priority"' "$(field .diff)"
count=$(events)
codex_cache "$HOME/.codex" 0.156.1 "$VARIANT"
check
codex_cache "$HOME/.codex" 0.154.0 '[{"slug":"gpt-5.6-sol"}]'
check
assert [ "$(events)" = "$count" ]

# Another client's list never enters the catalog, and an unreachable catalog keeps its last value.
count=$(events)
codex_cache "$HOME/.codex" 0.154.0 '[{"slug":"gpt-5.6-sol"},{"slug":"gpt-5.5"}]'
: >"$DATA/agy-models-fail"
check
assert [ "$(events)" = "$count" ]
rm "$DATA/agy-models-fail"
printf 'gemini-4-flash-high\tGemini 4 Flash (High)\n' >>"$DATA/models-agy"
check
assert [ "$(field .vendor)" = gemini ]
assert grep -qxF "+gemini-4-flash-high	Gemini 4 Flash (High)" "$(field .diff)"

# A probe that breaks locally is news; the facet it could not read keeps its value.
rm "$HOME/.grok/bin/grok"
check
assert [ "$(field .vendor)" = grok ]
assert [ "$(field '.substantive | join(",")')" = probe_failures ]
assert jqe '.facets.ids | index("grok-imagine-image-3.0")' "$STATE/fingerprints/grok.json"
ln -s grok-1.0.41 "$HOME/.grok/bin/grok"
check
printf '# Imagine\n' >"$HOME/.grok/docs/28-imagine.md"
check
assert [ "$(field '.substantive | join(",")')" = docs ]
assert grep -qF '+28-imagine.md = ' "$(field .diff)"

# Divergence: an account missing a model is substantive; a foreign client is recorded, and it stays
# recorded while the app that runs it is closed.
printf '{"codex":{"divergence":["catalog\\tb\\tmissing gpt-6-sol"]}}\n' >"$STATE/state.json"
check
assert [ "$(field '.substantive | join(",")')" = divergence ]
printf '{"codex":{"divergence":["catalog\\tb\\tmissing gpt-6-sol","client\\t/Applications/ChatGPT.app/codex\\t0.154.0"]}}\n' >"$STATE/state.json"
check
assert [ "$(field '.changed | join(",")')" = foreign_clients ]
assert [ "$(field .status)" = auto-closed ]
count=$(events)
printf '{"codex":{"divergence":["catalog\\tb\\tmissing gpt-6-sol"]}}\n' >"$STATE/state.json"
check
assert [ "$(events)" = "$count" ]

# A second, older install of a CLI is found on any PATH or nvm.
mkdir -p "$HOME/.nvm/versions/node/v24.0.0/bin"
count=$(events)
second() { printf '#!/usr/bin/env bash\nprintf "%s (Claude Code)\\n"\n' "$1" >"$HOME/.nvm/versions/node/v24.0.0/bin/claude"; }
second 2.1.281
chmod +x "$HOME/.nvm/versions/node/v24.0.0/bin/claude"
check
assert [ "$(events)" = "$count" ]
second 2.1.201
check
assert [ "$(field .vendor)" = claude ]
assert [ "$(field '.substantive | join(",")')" = installs ]
assert grep -qxF "+$HOME/.nvm/versions/node/v24.0.0/bin/claude = \"2.1.201\"" "$(field .diff)"

# A chat with no Claude account to run on, or that could not be opened, is opened by the next run, once.
: >"$OPENED"
: >"$DATA/pick"
fake_cli "$FAKE_BIN/claude" claude claude-opus-5-5 claude-sonnet-5 claude-opus-6
check
id=$(field .id)
assert [ "$(field '.launched_at == null')" = true ]
: >"$DATA/opener-fails"
printf 'acct-b\n' >"$DATA/pick"
check
assert [ "$(field '.launched_at == null')" = true ]
assert [ ! -s "$OPENED" ]
rm "$DATA/opener-fails"
check
check
assert [ "$(cat "$OPENED")" = "$EVENTS/$id.command" ]

# Open events are listed until closed; a manual request opens a chat without a fingerprint change.
assert grep -qF "$id" <(bash "$SCRIPT" events)
# The completeness gate: no event closes while a changed line of its diff has no decision.
assert_fails bash "$SCRIPT" close "$id" "integrated claude-opus-6" 2>"$WORK/close.err"
assert grep -qxF "ids	+claude-opus-6" "$WORK/close.err"
printf 'ids\t+claude-opus-6\tdone\tworker-model alias\n' >"$WORK/decisions"
assert_fails quiet bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6"
printf 'help: claude --help\t+claude-opus-6\tintegrated\twrong facet\n' >"$WORK/decisions"
assert_fails quiet bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6"
printf 'ids\t+claude-opus-*\tintegrated\t\n' >"$WORK/decisions"
assert_fails quiet bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6"
assert [ "$(jq -r .status "$EVENTS/$id.json")" = open ]
printf 'ids\t+claude-opus-*\tintegrated\tthe opus alias resolves it; tests/test_x.sh\n' >"$WORK/decisions"
bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6" || fail "close failed"
assert [ "$(jq -r '.decisions[0].decision' "$EVENTS/$id.json")" = integrated ]
assert [ "$(jq -r '"\(.status) \(.note)"' "$EVENTS/$id.json")" = "closed integrated claude-opus-6" ]
assert_fails grep -qF "$id" <(bash "$SCRIPT" events)
assert grep -qF "$id" <(bash "$SCRIPT" events --all)
# The npm CLI is found under nvm with no PATH naming it.
: >"$OPENED"
mv "$FAKE_BIN/grok" "$HOME/.nvm/versions/node/v24.0.0/bin/grok"
manual=$(bash "$SCRIPT" request grok 'catch up' | head -n 1)
assert [ "$(jq -r '"\(.status) \(.reason) \(.to)"' "$EVENTS/$manual.json")" = "open manual request: catch up 1.0.41" ]
assert [ "$(cat "$OPENED")" = "$EVENTS/$manual.command" ]
# Inside a chat already doing the pass, --here records it without opening another; a manual event has
# no changed lines, so it closes on its note.
: >"$OPENED"
here=$(bash "$SCRIPT" request --here gemini | head -n 1)
assert [ "$(jq -r '"\(.status) \(.launched)"' "$EVENTS/$here.json")" = "open here" ]
assert [ ! -s "$OPENED" ]
assert bash "$SCRIPT" close "$here" "nothing new"
assert_fails quiet bash "$SCRIPT" request nosuch

# A check while another holds the lock does nothing.
count=$(events)
printf 'grok-4.7 grok-imagine-video-1.5 grok-imagine-image-3.0 grok-5\n' >"$HOME/.grok/bin/grok-1.0.41"
lockf -k "$STATE/fingerprints/check.lock" sleep 30 &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lockf -k -t 0 "$STATE/fingerprints/check.lock" true 2>/dev/null || break
  sleep 0.2
done
assert_fails quiet check
assert [ "$(events)" = "$count" ]
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
HOLDER=""

# The integration chat's own change moved a facet: `check --here` records the event as its own and
# opens no other chat.
: >"$OPENED"
bash "$SCRIPT" check --here grok
assert [ "$(events)" = "$((count + 1))" ]
assert [ "$(field '"\(.vendor) \(.status) \(.launched)"')" = "grok open here" ]
assert [ ! -s "$OPENED" ]

echo "PASS: $asserts asserts; baseline, version-only releases close themselves, new ids/catalog fields/docs/help/installs/divergence open one integration chat per event, prompts and foreign clients are informational, unreadable facets keep their value, broken local probes are reported, manual requests, close, lock, check --here"
