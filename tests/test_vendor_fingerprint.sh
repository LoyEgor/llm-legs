#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
export WORKER_STATS_DIR="$WORK/worker-stats"
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
export VENDOR_FINGERPRINT_WORKER_PICK="$FAKE_BIN/worker-pick"
export DOCTORS_DIR="$WORK/doctors" UPDATER_DOCTOR_DIR="$WORK/updater"
unset VENDOR_FINGERPRINT_DOCTOR_FIX
RUNS="$WORK/doctors/runs"
# Only the fakes: the real CLIs live in ~/.local/bin, nvm and /usr/local/bin, none of which is here.
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
CODEX_PACKAGE="$WORK/node/lib/node_modules/@openai/codex"
CODEX_NATIVE="$CODEX_PACKAGE/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
STATE="$HOME/.cache/vendor-cli-update"
EVENTS="$STATE/events"
LOG="$STATE/update.log"
mkdir -p "$WORK/updater" "$FAKE_BIN" "$DATA" "$(dirname "$CODEX_NATIVE")" "$CODEX_PACKAGE/bin" "$HOME/.grok/bin" "$HOME/.grok/docs" \
  "$HOME/.codex" "$HOME/.codex-profiles/a/skills/.system/imagegen" "$HOME/.cache/grokb" "$STATE"
: >"$OPENED"
printf '{"contract":1,"doctor":"updater","judge":"u1"}\n' >"$WORK/updater/latest.json"

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
printf 'openai gpt-6-sol gpt-5.6-lunaopenai gpt-5.6-luna gpt-image-2 gpt-5.2-codexgemini-3.6-flash-high gpt-live-1-codextransport_closed\n' >"$CODEX_NATIVE"
fake_cli "$FAKE_BIN/grok" grok
printf 'grok-4.7 grok-imagine-video-1.5\n/xai/target/release-dist/build/xai-grok-memory-api-38bd164a103e0d8a/out/grok.memory.v1.rs\n' \
  >"$HOME/.grok/bin/grok-1.0.41"
ln -s grok-1.0.41 "$HOME/.grok/bin/grok"
# Glued as agy 1.3.0 packs its Go string table.
fake_cli "$FAKE_BIN/agy" agy gemini-3.8-flash gemini-3.1-flash-image gemini-3.8-flash-highgemini-3.7-flash-lowGemini \
  gemini-3.1-pro-low-thinkingx-cloudaicompanion-trace-id gemini-3.1-pro-lowResolving gemini-3.1-pro-highparse \
  gemini-3.1-pro-previewgemini-3-pro-previewtext/x-python gemini-3.1-pro-preview-customtools gemini-3.1-flash-lite \
  gemini-2.5-flash-liteuserStatus gemini-3.5-flashcheckUrl gpt-oss-20b-maasTRIGGER gpt-oss-120b-maasunmarshal \
  gemini-2.5-pro-windsurf-debugStarting gemini-2.5-pro-windsurfgenerate_commit grok-shell-2025-11-25transportFailed \
  RESPONSE_STYLE_CREATIVEgemini-3.7-flash-tieredopenai/gpt-oss-20b-maasRenew claude-opus-5-5@default
fake_cli "$FAKE_BIN/claude" claude claude-opus-5-5 claude-sonnet-5
cat >"$FAKE_BIN/opener" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$DATA/opener-fails" ] || exit 1
printf '%s\n' "$*" >>"$OPENED"
EOF
chmod +x "$FAKE_BIN/opener"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$DATA/pick-args"\ncat "$DATA/pick"\n' >"$FAKE_BIN/worker-pick"
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
# grokb lists the models the later checks find new in the binary: only a served id is a release.
printf '{"models":[{"slug":"grok-4.7","default":true,"label":"grok-4.7"},{"slug":"grok-5"},{"slug":"grok-6"},{"slug":"grok-7"},{"slug":"grok-8"}]}\n' \
  >"$HOME/.cache/grokb/models.json"
codex_cache() { # home client-version models-json
  printf '{"client_version":"%s","fetched_at":"2026-09-23T00:00:00Z","models":%s}\n' "$2" "$3" >"$1/models_cache.json"
}
PROMPT=$(printf 'You are Codex. %.0s' $(seq 1 40))
codex_cache "$HOME/.codex-profiles/a" 0.156.1 \
  "[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"model_messages\":{\"instructions_template\":\"$PROMPT\"}}]"
# The ChatGPT app's older codex wrote this home: its list is not the installed client's.
codex_cache "$HOME/.codex" 0.154.0 '[{"slug":"gpt-5.6-sol"}]'

# Day requests make worktrees in the script's repository: a fixture one, never this checkout.
fixture_repo() { # dir
  mkdir -p "$1/bin" "$1/share" "$1/docs"
  cp "$ROOT/bin/vendor-fingerprint" "$ROOT/bin/doctor-fix" "$1/bin/"
  cp "$ROOT"/share/{chat-open.sh,worktree.sh,store-lock.sh,test-scope.sh,report_frame.py,doctor-areas.json,fix_commit.py,spend.py,knobs.py} "$1/share/"
  cp "$ROOT/docs/vendor-release.md" "$1/docs/"
  git -C "$1" init -q -b main
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm base
}
DREPO="$WORK/day-repo"
fixture_repo "$DREPO"
SCRIPT="$DREPO/bin/vendor-fingerprint"
# A check of every vendor costs four probes; a section that changes one vendor checks that one.
check() { [ $# -gt 0 ] || fail "check names the vendors its section changes, or is check_all"; bash "$SCRIPT" check "$@"; }
check_all() { bash "$SCRIPT" check; }
quiet() { "$@" 2>/dev/null; }
events() { find "$EVENTS" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
last_event() { ls -t "$EVENTS"/*.json 2>/dev/null | head -n 1; }
field() { jq -r "$1" "$(last_event)"; }
# The chat Egor opened takes every waiting event, so the next change is an event of its own.
taken() {
  local file
  for file in "$EVENTS"/*.json; do
    jq -e '.status == "open" and .launched_at == null' "$file" >/dev/null || continue
    jq '.launched_at = "2026-09-24T00:00:00Z"' "$file" >"$WORK/taken"
    touch -r "$file" "$WORK/taken"
    mv "$WORK/taken" "$file"
    rm -f "${file%.json}.base"
  done
}

# The first check is the baseline: every installed vendor is recorded and nothing is reported.
check_all || fail "check exited non-zero"
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
# Model ids from the native binary, not the launcher; glued neighbours and cargo build hashes are cut off.
assert jqe '.facets.ids == ["gemini-3.6-flash-high", "gpt-5.2-codex", "gpt-5.6-luna", "gpt-6-sol", "gpt-image-2", "gpt-live-1-codex"]' "$FP_CODEX"
assert jqe '.facets.ids == ["grok-4.7", "grok-imagine-video-1.5"]' "$STATE/fingerprints/grok.json"
FP_GEMINI="$STATE/fingerprints/gemini.json"
assert jqe '.facets.ids == ["claude-opus-5-5", "gemini-2.5-flash-lite", "gemini-2.5-pro-windsurf",
  "gemini-2.5-pro-windsurf-debug", "gemini-3-pro-preview", "gemini-3.1-flash-image", "gemini-3.1-flash-lite",
  "gemini-3.1-pro-high", "gemini-3.1-pro-low", "gemini-3.1-pro-low-thinking", "gemini-3.1-pro-preview",
  "gemini-3.1-pro-preview-customtools", "gemini-3.5-flash", "gemini-3.7-flash-low", "gemini-3.7-flash-tiered",
  "gemini-3.8-flash",
  "gemini-3.8-flash-high", "gpt-oss-120b-maas", "gpt-oss-20b-maas", "grok-shell-2025-11-25"]' "$FP_GEMINI"
assert jqe '.facets["help: agy --help"] | test("Model for the current CLI session")' "$STATE/fingerprints/gemini.json"
assert jqe '.facets["help: claude --help"] | test("Claude Code <version>")' "$STATE/fingerprints/claude.json"
assert jqe '.facets.probe_failures == []' "$STATE/fingerprints/claude.json"

check_all
assert [ "$(events)" = 0 ]
# A list an older glue rule stored is no release once the current rule cuts it the same way.
jq '.facets.ids += ["gemini-3.1-pro-low-thinkingx", "gemini-3.5-flashcheck", "gemini-3.7-flash-tieredopenai"]' \
  "$FP_GEMINI" >"$WORK/glued"
mv "$WORK/glued" "$FP_GEMINI"
check gemini
assert [ "$(events)" = 0 ]
assert jqe '.facets.ids | index("gemini-3.1-pro-low-thinkingx") == null' "$FP_GEMINI"
assert jqe '.facets.ids | index("gemini-3.7-flash-tieredopenai") == null' "$FP_GEMINI"

# A release that changes nothing but the version closes itself.
printf '2.1.281\n' >"$DATA/ver-claude"
printf 'Claude Code 2.1.281\n  --model <model>\n' >"$DATA/help-claude"
check claude
assert [ "$(events)" = 1 ]
assert [ "$(field .status)" = auto-closed ]
assert [ "$(field '.changed | join(",")')" = version ]
assert [ "$(field '"\(.from) \(.to)"')" = "2.1.280 2.1.281" ]
assert [ ! -s "$OPENED" ]

# A new model id in the binary is an open event, and no chat opens by itself.
printf 'grok-4.7 grok-imagine-video-1.5 grok-imagine-image-3.0\n' >"$HOME/.grok/bin/grok-1.0.41"
check grok
assert [ "$(events)" = 2 ]
fid=$(field .id)
assert [ "$(field .vendor)" = grok ]
assert [ "$(field .status)" = open ]
assert [ "$(field '.substantive | join(",")')" = ids ]
assert grep -qxF '+grok-imagine-image-3.0' "$EVENTS/$fid.diff"
assert [ ! -s "$OPENED" ]
assert [ "$(field '.launched_at == null')" = true ]
# Egor's request takes the vendor's waiting release event into its own fixer run of doctor updater, a
# worktree off main and a brief, as a night does, then opens one orchestrator chat on the strong model,
# in this repository, through the shared opener.
id=$(bash "$SCRIPT" request grok | head -n 1)
assert [ "$id" = "$fid" ]
run=$(jq -r .run "$EVENTS/$id.json")
tree="$DREPO/.claude/worktrees/vendor-$id"
assert [ "$(cat "$EVENTS/$run.lines")" = "$run	$EVENTS/$id.brief.md	$tree" ]
assert [ "$(git -C "$tree" rev-parse --abbrev-ref HEAD)" = "vendor/$id" ]
assert [ "$(git -C "$tree" rev-parse HEAD)" = "$(git -C "$DREPO" rev-parse main)" ]
assert [ "$(head -n 1 "$EVENTS/$id.brief.md")" = "ROUND: none" ]
assert grep -qxF "Vendor release events of grok:" "$EVENTS/$id.brief.md"
assert grep -qF "Working directory: $tree, the llm-legs worktree on branch vendor/$id." "$EVENTS/$id.brief.md"
assert_fails grep -qi 'night' "$EVENTS/$id.brief.md"
assert [ "$(cat "$OPENED")" = "$EVENTS/$run.command" ]
assert grep -qxF "cd $(printf '%q' "$DREPO") || exit 1" "$EVENTS/$run.command"
launch_sid=$(sed -n 's/.* --session-id \([^ ]*\) .*/\1/p' "$EVENTS/$run.command")
assert grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' <<<"$launch_sid"
assert grep -qF -- "exec $FAKE_BIN/claudeb profile acct-b --session-id $launch_sid --model opus --effort high Fix\\ orchestrator:\\ read\\ $DREPO/docs/fix-orchestrator.md\\ in\\ full\\ and\\ follow\\ it\\ for\\ the\\ runs\\ in\\ $EVENTS/$run.lines." "$EVENTS/$run.command"
# The chat it opens gets no chat pin: vendors are Egor's worker switches, never a launch default.
assert [ "$(grep -c 'chat-pin' "$EVENTS/$run.command")" = 0 ]
assert jqe '.launched_at != null and .launched == "day" and .night == null' "$EVENTS/$id.json"
assert jqe --arg id "$id" --arg s "$launch_sid" --arg c "$EVENTS/$run.command" --arg w "$tree" '.doctor == "updater" and .launched_at != null
  and .closed_at == null and .account == "acct-b" and .session == $s and .command == $c and .judge_at_launch == "u1"
  and .night == null and .branch == "vendor/\($id)" and .worktrees == [$w] and (.problems | map(.id)) == [$id]' "$RUNS/$run.json"
check grok
assert [ "$(wc -l <"$OPENED" | tr -d ' ')" = 1 ]
assert [ ! -e "$EVENTS/$fid.base" ]
taken
# The account is a chat's, asked past the workers switch; and launchd's PATH carries no repo bin, so
# the picker is the one beside the script.
assert grep -qxF -- '--account claudeb --role chat --model opus --claim' "$DATA/pick-args"
fixture_repo "$WORK/repo"
printf '#!/usr/bin/env bash\nprintf "repo-acct\\n"\n' >"$WORK/repo/bin/worker-pick"
chmod +x "$WORK/repo/bin/worker-pick"
: >"$OPENED"
env -u VENDOR_FINGERPRINT_WORKER_PICK PATH="$FAKE_BIN:/usr/bin:/bin" bash "$WORK/repo/bin/vendor-fingerprint" request grok >/dev/null
assert grep -qF 'profile repo-acct ' "$(cat "$OPENED")"

# A new catalog field is substantive; a changed prompt alone is recorded and closes itself.
: >"$OPENED"
codex_cache "$HOME/.codex-profiles/a" 0.156.1 \
  "[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"supports_computer_use\":true,\"model_messages\":{\"instructions_template\":\"$PROMPT\"}}]"
check codex
assert [ "$(field .vendor)" = codex ]
assert [ "$(field '.substantive | join(",")')" = catalog ]
assert grep -qxF '+gpt-6-sol.supports_computer_use = true' "$(field .diff)"
assert [ ! -s "$OPENED" ]
taken
codex_cache "$HOME/.codex-profiles/a" 0.156.1 \
  "[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"supports_computer_use\":true,\"model_messages\":{\"instructions_template\":\"$PROMPT changed\"}}]"
check codex
assert [ "$(field '.changed | join(",")')" = catalog_text ]
assert [ "$(field .status)" = auto-closed ]
# A field gaining an empty container has a diff line for its close to decide, like any other value.
codex_cache "$HOME/.codex-profiles/a" 0.156.1 \
  "[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"supports_computer_use\":true,\"input_modalities\":[],\"model_messages\":{\"instructions_template\":\"$PROMPT changed\"}}]"
check codex
assert [ "$(field '.substantive | join(",")')" = catalog ]
assert grep -qxF '+gpt-6-sol.input_modalities = []' "$(field .diff)"
taken
codex_cache "$HOME/.codex-profiles/a" 0.156.1 \
  "[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"supports_computer_use\":true,\"model_messages\":{\"instructions_template\":\"$PROMPT changed\"}}]"
check codex
assert grep -qxF -- '-gpt-6-sol.input_modalities = []' "$(field .diff)"
taken

# Accounts served different catalogs: a field they disagree on is recorded as its value set, and
# ~/.codex dropping in and out of the homes as the app and our client take turns writing it is no
# release.
count=$(events)
VARIANT="[{\"slug\":\"gpt-6-sol\",\"context_window\":272000,\"supports_computer_use\":true,\"default_service_tier\":\"priority\",\"model_messages\":{\"instructions_template\":\"$PROMPT changed\"}}]"
mkdir -p "$HOME/.codex-profiles/b"
ln -s "$HOME/.codex-profiles/a/skills" "$HOME/.codex/skills"
codex_cache "$HOME/.codex-profiles/b" 0.156.1 "$VARIANT"
check codex
assert [ "$(events)" = $((count + 1)) ]
assert [ "$(field '.substantive | join(",")')" = catalog ]
assert grep -qxF '+gpt-6-sol.default_service_tier.per_account.1 = "priority"' "$(field .diff)"
taken
count=$(events)
codex_cache "$HOME/.codex" 0.156.1 "$VARIANT"
check codex
codex_cache "$HOME/.codex" 0.154.0 '[{"slug":"gpt-5.6-sol"}]'
check codex
assert [ "$(events)" = "$count" ]

# The list order differs per account and flaps; every launch resolves its -m, so it opens no chat.
count=$(events)
codex_cache "$HOME/.codex-profiles/a" 0.156.1 \
  "[{\"slug\":\"gpt-6-sol\",\"priority\":2,\"context_window\":272000,\"supports_computer_use\":true,\"model_messages\":{\"instructions_template\":\"$PROMPT changed\"}}]"
codex_cache "$HOME/.codex-profiles/b" 0.156.1 "${VARIANT/\"slug\":\"gpt-6-sol\",/\"slug\":\"gpt-6-sol\",\"priority\":3,}"
check codex
assert [ "$(events)" = $((count + 1)) ]
assert [ "$(field '.changed | join(",")')" = catalog_order ]
assert [ "$(field .status)" = auto-closed ]
assert grep -qxF '+gpt-6-sol.per_account.0 = 2' "$(field .diff)"
assert_fails jqe '.facets.catalog["gpt-6-sol"] | has("priority")' "$STATE/fingerprints/codex.json"
# A fingerprint stored while priority was still in the catalog loses it with no chat.
count=$(events)
: >"$OPENED"
jq '.facets.catalog["gpt-6-sol"].priority = {per_account: [2, 3]}' "$STATE/fingerprints/codex.json" >"$WORK/old-codex.json"
mv "$WORK/old-codex.json" "$STATE/fingerprints/codex.json"
check codex
assert [ "$(events)" = $((count + 1)) ]
assert [ "$(field '.changed | join(",")')" = catalog ]
assert [ "$(field .status)" = auto-closed ]
assert [ ! -s "$OPENED" ]

# An A/B variant rolled back — every value is one some account already had — closes itself; a value
# no account had before still opens a chat.
count=$(events)
: >"$OPENED"
REGROUPED="[{\"slug\":\"gpt-6-sol\",\"priority\":3,\"context_window\":272000,\"supports_computer_use\":true,\"model_messages\":{\"instructions_template\":\"$PROMPT changed\"}}]"
codex_cache "$HOME/.codex-profiles/b" 0.156.1 "$REGROUPED"
check codex
assert [ "$(events)" = $((count + 1)) ]
assert [ "$(field '.changed | join(",")')" = catalog ]
assert [ "$(field .status)" = auto-closed ]
assert [ ! -s "$OPENED" ]
codex_cache "$HOME/.codex-profiles/b" 0.156.1 "${REGROUPED/\"priority\":3,/\"priority\":3,\"default_service_tier\":\"flex\",}"
check codex
assert [ "$(events)" = $((count + 2)) ]
assert [ "$(field '.substantive | join(",")')" = catalog ]
assert [ "$(field .status)" = open ]
taken

# Another client's list never enters the catalog, and an unreachable catalog keeps its last value.
count=$(events)
codex_cache "$HOME/.codex" 0.154.0 '[{"slug":"gpt-5.6-sol"},{"slug":"gpt-5.5"}]'
: >"$DATA/agy-models-fail"
check codex gemini
assert [ "$(events)" = "$count" ]
# The Updater doctor reads which facets a remote read missed, kept beside the facets so it is no change.
assert jqe '.remote_failures == ["catalog"] and (.facets.catalog | length) > 0' "$STATE/fingerprints/gemini.json"
rm "$DATA/agy-models-fail"
printf 'gemini-4-flash-high\tGemini 4 Flash (High)\n' >>"$DATA/models-agy"
check gemini
assert jqe '.remote_failures == []' "$STATE/fingerprints/gemini.json"
assert [ "$(field .vendor)" = gemini ]
assert grep -qxF "+gemini-4-flash-high	Gemini 4 Flash (High)" "$(field .diff)"
taken

# A probe that breaks locally is news; the facet it could not read keeps its value.
rm "$HOME/.grok/bin/grok"
check grok
assert [ "$(field .vendor)" = grok ]
assert [ "$(field '.substantive | join(",")')" = probe_failures ]
assert jqe '.facets.ids | index("grok-imagine-image-3.0")' "$STATE/fingerprints/grok.json"
taken
ln -s grok-1.0.41 "$HOME/.grok/bin/grok"
check grok
taken
printf '# Imagine\n' >"$HOME/.grok/docs/28-imagine.md"
check grok
assert [ "$(field '.substantive | join(",")')" = docs ]
assert grep -qF '+28-imagine.md = ' "$(field .diff)"
taken

# Divergence: an account missing a model is substantive; a foreign client is recorded, and it stays
# recorded while the app that runs it is closed.
printf '{"codex":{"divergence":["catalog\\tb\\tmissing gpt-6-sol"]}}\n' >"$STATE/state.json"
check codex
assert [ "$(field '.substantive | join(",")')" = divergence ]
taken
printf '{"codex":{"divergence":["catalog\\tb\\tmissing gpt-6-sol","client\\t/Applications/ChatGPT.app/codex\\t0.154.0"]}}\n' >"$STATE/state.json"
check codex
assert [ "$(field '.changed | join(",")')" = foreign_clients ]
assert [ "$(field .status)" = auto-closed ]
count=$(events)
printf '{"codex":{"divergence":["catalog\\tb\\tmissing gpt-6-sol"]}}\n' >"$STATE/state.json"
check codex
assert [ "$(events)" = "$count" ]

# A second, older install of a CLI is found on any PATH or nvm.
mkdir -p "$HOME/.nvm/versions/node/v24.0.0/bin"
count=$(events)
second() { printf '#!/usr/bin/env bash\nprintf "%s (Claude Code)\\n"\n' "$1" >"$HOME/.nvm/versions/node/v24.0.0/bin/claude"; }
second 2.1.281
chmod +x "$HOME/.nvm/versions/node/v24.0.0/bin/claude"
check claude
assert [ "$(events)" = "$count" ]
second 2.1.201
check claude
assert [ "$(field .vendor)" = claude ]
assert [ "$(field '.substantive | join(",")')" = installs ]
assert grep -qxF "+$HOME/.nvm/versions/node/v24.0.0/bin/claude = \"2.1.201\"" "$(field .diff)"
# Once its chat is open, the install catching up or still lagging is no new event to handle.
taken
second 2.1.250
check claude
assert [ "$(field '.changed | join(",")')" = installs ]
assert [ "$(field .status)" = auto-closed ]
second 2.1.281
check claude
assert [ "$(field '.changed | join(",")')" = installs ]
assert [ "$(field .status)" = auto-closed ]
# An install that moved ahead of the primary is no event: the primary's version event follows.
second 2.1.289
check claude
assert [ "$(field '.changed | join(",")')" = installs ]
assert [ "$(field .status)" = auto-closed ]
assert grep -qxF "+$HOME/.nvm/versions/node/v24.0.0/bin/claude = \"2.1.289\"" "$(field .diff)"
second 2.1.281
check claude

# A request for a vendor whose release event waits takes that event, never a manual one beside it. A
# request with no Claude account to run on, or whose chat could not be opened, is opened by the next
# check, once; a fingerprint event nobody requested is not.
: >"$OPENED"
: >"$DATA/pick"
fake_cli "$FAKE_BIN/claude" claude claude-opus-5-5 claude-sonnet-5 claude-opus-6
check claude
id=$(field .id)
assert [ "$(field '.launched_at == null')" = true ]
count=$(events)
retry=$(bash "$SCRIPT" request claude | head -n 1)
assert [ "$retry" = "$id" ]
assert [ "$(events)" = "$count" ]
assert jqe '.launched_at == null and .run == null and .requested_at != null' "$EVENTS/$retry.json"
: >"$DATA/opener-fails"
printf 'acct-b\n' >"$DATA/pick"
check claude
assert jqe '.launched_at == null' "$EVENTS/$retry.json"
assert [ -s "$EVENTS/$retry.base" ]
assert [ ! -s "$OPENED" ]
printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\ngemini-4-flash\tGemini 4 Flash\n' >"$DATA/models-agy"
VENDOR_FINGERPRINT_HOLD=1 check gemini
unrequested=$(field .id)
assert [ "$(jq -r .vendor "$EVENTS/$unrequested.json")" = gemini ]
rm "$DATA/opener-fails"
check claude
check gemini
assert [ "$(cat "$OPENED")" = "$EVENTS/$(jq -r .run "$EVENTS/$retry.json").command" ]
assert jqe '.launched_at != null and .run != null' "$EVENTS/$retry.json"
assert [ ! -e "$EVENTS/$retry.base" ]
assert [ "$(jq -s --arg e "$retry" '[.[] | select(.problems[0].id == $e) | .failed_at != null] | sort' "$RUNS"/updater-*.json | jq -c .)" = '[false,true,true]' ]
assert jqe '.launched_at == null' "$EVENTS/$unrequested.json"
taken

# Open events are listed until closed; a manual request opens a chat without a fingerprint change.
assert grep -qxF "$id" <(bash "$SCRIPT" events | cut -f1)
# The completeness gate: no event closes while a changed line of its diff has no decision.
assert_fails bash "$SCRIPT" close "$id" "integrated claude-opus-6" 2>"$WORK/close.err"
assert grep -qxF "ids	+claude-opus-6" "$WORK/close.err"
printf 'ids\t+claude-opus-6\tdone\tdocs/vendor-release.md\tworker-model alias\n' >"$WORK/decisions"
assert_fails quiet bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6"
printf 'help: claude --help\t+claude-opus-6\tintegrated\tdocs/vendor-release.md\twrong facet\n' >"$WORK/decisions"
assert_fails quiet bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6"
printf 'ids\t+claude-opus-*\tintegrated\tdocs/vendor-release.md\t\n' >"$WORK/decisions"
assert_fails quiet bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6"
# Every decided line cites its surface's purpose, and it resolves by doctor-fix's own rule.
printf 'ids\t+claude-opus-*\tintegrated\tthe opus alias resolves it; tests/test_x.sh\n' >"$WORK/decisions"
assert_fails quiet bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6"
printf 'ids\t+claude-opus-*\tintegrated\tdocs/no-such-file.md\tthe opus alias resolves it\n' >"$WORK/decisions"
assert_fails bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6" 2>"$WORK/close.err"
assert grep -qF "row 1: purpose 'docs/no-such-file.md' resolves to no commit" "$WORK/close.err"
assert [ "$(jq -r .status "$EVENTS/$id.json")" = open ]
printf 'ids\t+claude-opus-*\tintegrated\tdocs/vendor-release.md:88\tthe opus alias resolves it; tests/test_x.sh\n' >"$WORK/decisions"
# Purposes that cannot be judged hold the close like purposes that resolve nowhere.
assert_fails env TMPDIR="$WORK/no-tmp" bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6" 2>"$WORK/close.err"
assert grep -qF "no record to judge purposes with under $WORK/no-tmp" "$WORK/close.err"
assert [ "$(jq -r .status "$EVENTS/$id.json")" = open ]
bash "$SCRIPT" close "$id" --decisions "$WORK/decisions" "integrated claude-opus-6" || fail "close failed"
assert [ "$(jq -r '.decisions[0] | "\(.decision) \(.purpose)"' "$EVENTS/$id.json")" = "integrated docs/vendor-release.md:88" ]
assert jqe --arg id "$id" '.closed_at != null and .decisions == [{id: $id, purpose: "docs/vendor-release.md:88", verdict: "integrated",
  evidence: "1 decision rows: 1 integrated, 0 not-applicable, 0 blocked · integrated claude-opus-6"}]' "$RUNS/$(jq -r .run "$EVENTS/$id.json").json"
assert [ "$(jq -r '"\(.status) \(.note)"' "$EVENTS/$id.json")" = "closed integrated claude-opus-6" ]
assert_fails grep -qxF "$id" <(bash "$SCRIPT" events | cut -f1)
assert grep -qxF "$id" <(bash "$SCRIPT" events --all | cut -f1)
# The npm CLI is found under nvm with no PATH naming it.
: >"$OPENED"
mv "$FAKE_BIN/grok" "$HOME/.nvm/versions/node/v24.0.0/bin/grok"
manual=$(bash "$SCRIPT" request grok 'catch up' | head -n 1)
assert [ "$(jq -r '"\(.status) \(.reason) \(.to)"' "$EVENTS/$manual.json")" = "open manual request: catch up 1.0.41" ]
assert [ "$(cat "$OPENED")" = "$EVENTS/$(jq -r .run "$EVENTS/$manual.json").command" ]
# Inside a chat already doing the pass, --here records it without opening another. A manual event's
# diff is the vendor's whole fingerprint, so it never closes on its note alone.
: >"$OPENED"
here=$(bash "$SCRIPT" request --here gemini | head -n 1)
assert [ "$(jq -r '"\(.status) \(.launched)"' "$EVENTS/$here.json")" = "open here" ]
assert [ ! -s "$OPENED" ]
assert grep -qxF "+gemini-4-flash	Gemini 4 Flash" "$EVENTS/$here.diff"
assert grep -qxF "+gemini-3.8-flash" "$EVENTS/$here.diff"
assert_fails grep -qxF '### version' "$EVENTS/$here.diff"
assert_fails quiet bash "$SCRIPT" close "$here" "nothing new"
sed -n 's/^### \(.*\)/\1	+*	not-applicable	docs\/vendor-release.md	nothing new/p' "$EVENTS/$here.diff" >"$WORK/decisions"
assert bash "$SCRIPT" close "$here" --decisions "$WORK/decisions" "nothing new"
# A request before any check baselined its vendor points its event at the snapshot its diff was taken from.
fresh_id=$(VENDOR_CLI_UPDATE_STATE_DIR="$WORK/unbaselined" bash "$SCRIPT" request --here grok | head -n 1)
assert jqe --arg f "$WORK/unbaselined/events/$fresh_id.fingerprint" '.fingerprint == $f' "$WORK/unbaselined/events/$fresh_id.json"
assert jqe '.facets.ids | length > 0' "$WORK/unbaselined/events/$fresh_id.fingerprint"
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
assert_fails quiet check_all
assert [ "$(events)" = "$count" ]
# Parallel vendor workers run `check --here` at nearly the same time: it waits for the lock, bounded.
env VENDOR_FINGERPRINT_LOCK_WAIT=1 bash "$SCRIPT" check --here grok 2>/dev/null &
here_wait=$!
# A request waits for it too: a check's launch_pending would see it requested and open a second chat.
env VENDOR_FINGERPRINT_LOCK_WAIT=1 bash "$SCRIPT" request grok 2>/dev/null &
request_wait=$!
assert_fails wait "$here_wait"
assert_fails wait "$request_wait"
assert [ "$(events)" = "$count" ]
(sleep 1; kill "$HOLDER" 2>/dev/null) &

# The integration chat's own change moved a facet: `check --here` records the event as its own and
# opens no other chat.
: >"$OPENED"
assert bash "$SCRIPT" check --here grok
wait "$HOLDER" 2>/dev/null
HOLDER=""
assert [ "$(events)" = "$((count + 1))" ]
assert [ "$(field '"\(.vendor) \(.status) \(.launched)"')" = "grok open here" ]
assert [ ! -s "$OPENED" ]

# Events wait for Egor's request, however long. A change meanwhile joins its vendor's waiting event and
# is judged against the fingerprint from before it, so a flap that has reverted by then closes the event.
: >"$OPENED"
count=$(events)
grok_ids() { printf 'grok-4.7 grok-imagine-video-1.5 grok-imagine-image-3.0 grok-5 %s\n' "$*" >"$HOME/.grok/bin/grok-1.0.41"; }
grok_ids grok-6
check grok
grok_id=$(field .id)
assert [ "$(field '"\(.vendor) \(.status) \(.launched_at)"')" = "grok open null" ]
grok_ids grok-6 grok-7
check grok
assert [ "$(events)" = $((count + 1)) ]
assert grep -qxF '+grok-6' "$EVENTS/$grok_id.diff"
assert grep -qxF '+grok-7' "$EVENTS/$grok_id.diff"
printf 'gemini-5-pro\tGemini 5 Pro\n' >>"$DATA/models-agy"
check gemini
gemini_id=$(field .id)
assert [ "$(field '"\(.vendor) \(.status)"')" = "gemini open" ]
jq '.facets.ids += ["gemini-3.1-pro-low-thinkingx"]' "$EVENTS/$gemini_id.base" >"$WORK/glued"
mv "$WORK/glued" "$EVENTS/$gemini_id.base"
sed -i '' '/gemini-5-pro/d' "$DATA/models-agy"
check gemini
assert [ "$(jq -r .status "$EVENTS/$gemini_id.json")" = auto-closed ]
assert [ "$(events)" = $((count + 2)) ]
fake_cli "$FAKE_BIN/claude" claude claude-opus-5-5 claude-sonnet-5 claude-opus-6 claude-opus-7
check claude
claude_id=$(field .id)
assert [ "$(events)" = $((count + 3)) ]
assert [ ! -s "$OPENED" ]
jq --arg t "$(date -u -r $(($(date +%s) - 30 * 86400)) +%Y-%m-%dT%H:%M:%SZ)" '.created_at = $t' "$EVENTS/$grok_id.json" >"$WORK/old"
touch -r "$EVENTS/$grok_id.json" "$WORK/old"
mv "$WORK/old" "$EVENTS/$grok_id.json"
check grok
assert [ ! -s "$OPENED" ]
assert jqe '.launched_at == null' "$EVENTS/$grok_id.json"
assert [ ! -e "$STATE/fingerprints/last-launch" ]

# The manual update's own check launches nothing, not even a manual request whose chat failed.
: >"$DATA/opener-fails"
manual=$(bash "$SCRIPT" request codex | head -n 1)
rm "$DATA/opener-fails"
VENDOR_FINGERPRINT_HOLD=1 bash "$SCRIPT" check codex
assert [ ! -s "$OPENED" ]
assert jqe '.launched_at == null' "$EVENTS/$manual.json"
# Egor's update word: every vendor now — the waiting events carry their vendors' passes, each other
# vendor gets a manual one — a fixer run per vendor, all in one orchestrator chat.
bash "$SCRIPT" request --all "update word" >"$WORK/all-ids"
assert [ "$(xargs -I{} jq -r .vendor "$EVENTS/{}.json" <"$WORK/all-ids" | sort -u | xargs)" = "claude codex gemini grok" ]
for waiting_id in "$grok_id" "$claude_id" "$manual"; do assert grep -qxF "$waiting_id" "$WORK/all-ids"; done
assert [ "$(wc -l <"$OPENED" | tr -d ' ')" = 1 ]
OPENED_CMD=$(cat "$OPENED")
lines="${OPENED_CMD%.command}.lines"
assert [ "$(wc -l <"$lines" | tr -d ' ')" = 4 ]
assert [ "$(cut -f1 "$lines" | sort -u | wc -l | tr -d ' ')" = 4 ]
assert [ "$(xargs -I{} jq -r .run "$EVENTS/{}.json" <"$WORK/all-ids" | sort)" = "$(cut -f1 "$lines" | sort)" ]
grok_run=$(jq -r .run "$EVENTS/$grok_id.json")
assert grep -qxF "$grok_run	$EVENTS/$grok_id.brief.md	$DREPO/.claude/worktrees/vendor-$grok_id" "$lines"
assert grep -qF "bin/vendor-fingerprint show $grok_id" "$EVENTS/$grok_id.brief.md"
assert grep -qF 'per event in turn' "$EVENTS/$grok_id.brief.md"
assert [ "$(xargs -I{} jq -r '.launched_at != null' "$EVENTS/{}.json" <"$WORK/all-ids" | sort -u)" = true ]
assert [ "$(ls "$EVENTS"/*.base 2>/dev/null | wc -l | tr -d ' ')" = 0 ]
while IFS=$'\t' read -r run _; do
  assert jqe --arg c "$OPENED_CMD" '.doctor == "updater" and .closed_at == null and .command == $c and (.problems | length) == 1' "$RUNS/$run.json"
done <"$lines"
# Each run closes with its event, one decision line per event, past a decisions array a killed close left;
# the others stay open meanwhile.
printf '[{"id":"stale"}]\n' >"$EVENTS/updater-release-stale.decisions.json"
open=4
while IFS= read -r event_id; do
  run=$(jq -r .run "$EVENTS/$event_id.json")
  awk '/^### / { f = substr($0, 5); next } $0 == "--- before" || $0 == "+++ after" { next }
    /^[+-]/ { l = $0; if (index(l, "\t")) l = substr(l, 1, index(l, "\t") - 1) "*"
      print f "\t" l "\tintegrated\tdocs/vendor-release.md\ttests/test_x.sh" }' "$EVENTS/$event_id.diff" >"$WORK/decide"
  bash "$SCRIPT" close "$event_id" --decisions "$WORK/decide" "done $event_id" </dev/null || fail "close $event_id failed"
  open=$((open - 1))
  assert jqe --arg e "$event_id" '.closed_at != null and .judge_at_close == "u1" and (.decisions | map(.id)) == [$e]' "$RUNS/$run.json"
  assert [ "$(cut -f1 "$lines" | xargs -I{} jq -r 'select(.closed_at == null) | .id' "$RUNS/{}.json" | wc -l | tr -d ' ')" = "$open" ]
done <"$WORK/all-ids"
assert [ "$(ls "$EVENTS" | grep -c 'decisions')" = 1 ]
rm "$EVENTS/updater-release-stale.decisions.json"
assert jqe --arg g "$grok_id" '.decisions[] | select(.id == $g) | .verdict == "integrated" and .purpose == "docs/vendor-release.md"
  and (.evidence | startswith("2 decision rows: 2 integrated, 0 not-applicable, 0 blocked · done "))' "$RUNS/$grok_run.json"
assert jqe --arg m "$manual" '.decisions[] | select(.id == $m) | .verdict == "integrated" and .purpose == "docs/vendor-release.md"' "$RUNS/$(jq -r .run "$EVENTS/$manual.json").json"
assert jqe --arg g "$grok_id" '.note | contains("\($g): done \($g)")' "$RUNS/$grok_run.json"

# Night: each vendor with a real waiting release gets its own worktree, branch and brief; a manual
# request waiting beside it is left for the day, and no chat opens.
NREPO="$WORK/night-repo"
fixture_repo "$NREPO"
night() { bash "$NREPO/bin/vendor-fingerprint" request --night "$@"; }
: >"$OPENED"
assert night N0 >"$WORK/night0"
assert [ ! -s "$WORK/night0" ]
assert [ ! -e "$NREPO/.claude/worktrees" ]
: >"$DATA/opener-fails"
day_manual=$(bash "$SCRIPT" request claude | head -n 1)
rm "$DATA/opener-fails"
grok_ids grok-6 grok-7 grok-8
VENDOR_FINGERPRINT_HOLD=1 check grok
night_grok=$(field .id)
assert [ "$(field '"\(.vendor) \(.status) \(.launched_at)"')" = "grok open null" ]
# No base ref: no worktree from HEAD, and the event keeps waiting.
assert_fails night N1 >"$WORK/night1" 2>"$WORK/err"
assert grep -qF "no refs/night/N1/base in $NREPO" "$WORK/err"
assert [ ! -e "$NREPO/.claude/worktrees/night-N1-grok" ]
assert jqe '.launched_at == null' "$EVENTS/$night_grok.json"
git -C "$NREPO" update-ref refs/night/N1/base HEAD
SIB="$WORK/review-bench"
git init -q "$SIB"
git -C "$SIB" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$SIB" update-ref refs/night/N1/base HEAD
SIB_WT="$SIB/.claude/worktrees/night-N1-grok"
# The night request joins the event under the check lock, so a scheduled check never rewrites it meanwhile.
lockf -k "$STATE/fingerprints/check.lock" sleep 30 &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lockf -k -t 0 "$STATE/fingerprints/check.lock" true 2>/dev/null || break
  sleep 0.2
done
assert_fails env VENDOR_FINGERPRINT_LOCK_WAIT=1 bash "$NREPO/bin/vendor-fingerprint" request --night N1 >"$WORK/night1" 2>/dev/null
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
assert [ ! -s "$WORK/night1" ]
assert jqe '.launched_at == null' "$EVENTS/$night_grok.json"
assert [ ! -e "$NREPO/.claude/worktrees/night-N1-grok" ]
assert night N1 >"$WORK/night1"
assert [ "$(wc -l <"$WORK/night1" | tr -d ' ')" = 1 ]
# The ref is the event's updater fixer run, so the orchestrator's doctor-fix show reads it like a fixer's.
IFS=$'\t' read -r n_run n_brief n_tree <"$WORK/night1"
assert grep -qE '^updater-release-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$' <<<"$n_run"
assert [ "$n_brief" = "$EVENTS/$night_grok.brief.md" ]
assert [ "$n_tree" = "$NREPO/.claude/worktrees/night-N1-grok" ]
assert jqe --arg e "$night_grok" --arg w "$n_tree" --arg s "$SIB_WT" '.night == "N1" and .branch == "night/N1/grok"
  and .worktrees == [$w, $s] and [.problems[].id] == [$e] and .launched_at != null and .closed_at == null' "$RUNS/$n_run.json"
assert [ "$(git -C "$SIB_WT" rev-parse --abbrev-ref HEAD)" = night/N1/grok ]
eval "$(sed -n '/^brief_add_dirs() {/,/^}/p' "$ROOT/bin/worker-run")"
assert [ "$(brief_add_dirs "$n_brief")" = "$SIB_WT" ]
assert [ "$(head -n 1 "$n_brief")" = "ROUND: none" ]
assert jqe --arg r "$n_run" '.run == $r' "$EVENTS/$night_grok.json"
bash "$NREPO/bin/doctor-fix" show "$n_run" >"$WORK/show" || fail "doctor-fix show of the night vendor run"
assert grep -qF "run $n_run · updater doctor · area release · open" "$WORK/show"
assert [ "$(git -C "$n_tree" rev-parse --abbrev-ref HEAD)" = night/N1/grok ]
assert [ -z "$(git -C "$NREPO" status --porcelain)" ]
assert grep -qF "Working directory: $n_tree, the llm-legs worktree on branch night/N1/grok." "$n_brief"
assert grep -qF "Read $NREPO/docs/vendor-release.md in full" "$n_brief"
assert grep -qF "bin/vendor-fingerprint show $night_grok" "$n_brief"
assert grep -qF '`blocked-on-egor:`' "$n_brief"
assert grep -qF 'Look at the older blocks around what you touch, not only at what you add' "$n_brief"
assert jqe '.launched == "night" and .night == "N1" and .launched_at != null' "$EVENTS/$night_grok.json"
assert [ ! -e "$EVENTS/$night_grok.base" ]
assert jqe '.launched_at == null' "$EVENTS/$day_manual.json"
assert [ ! -s "$OPENED" ]
assert night N1 >"$WORK/night1"
assert [ ! -s "$WORK/night1" ]
# The worker runs check --here and close inside its worktree; a purpose may cite a file only it holds,
# and the rule is whatever doctor-fix's is.
assert bash "$n_tree/bin/vendor-fingerprint" check --here grok
printf '# why\n' >"$n_tree/docs/new-surface.md"
sed -n 's/^### \(.*\)/\1	+*	integrated	docs\/new-surface.md	tests\/test_x.sh/p' "$EVENTS/$night_grok.diff" >"$WORK/decisions"
printf '#!/usr/bin/env bash\n[ "$1" != help ] || echo "doctor-fix touches <record-file> <id> <purpose>"\nexit 1\n' >"$WORK/strict-doctor-fix"
chmod +x "$WORK/strict-doctor-fix"
assert_fails quiet env VENDOR_FINGERPRINT_DOCTOR_FIX="$WORK/strict-doctor-fix" bash "$n_tree/bin/vendor-fingerprint" close "$night_grok" --decisions "$WORK/decisions" "night"
assert_fails quiet env VENDOR_FINGERPRINT_DOCTOR_FIX=/dev/null bash "$n_tree/bin/vendor-fingerprint" close "$night_grok" --decisions "$WORK/decisions" "night"
assert_fails quiet bash "$SCRIPT" close "$night_grok" --decisions "$WORK/decisions" "night"
assert bash "$n_tree/bin/vendor-fingerprint" close "$night_grok" --decisions "$WORK/decisions" "night"
assert jqe '.status == "closed" and (.decisions | map(.purpose) | unique) == ["docs/new-surface.md"]' "$EVENTS/$night_grok.json"
assert jqe --arg e "$night_grok" '.closed_at != null and .decisions[0].id == $e and .decisions[0].verdict == "integrated"' "$RUNS/$n_run.json"

# A string id no served catalog lists opens nothing (claude-haiku-3-55, gemini-3.5-flash-lite in 2026-10);
# one the catalog serves does. Claude's catalog is the one its binary bakes in.
held_check() { VENDOR_FINGERPRINT_HOLD=1 check "$@"; }
claude_ids='claude-opus-5-5 claude-sonnet-5 claude-opus-6 claude-opus-7 first_party:"claude-opus-5-5" first_party:"claude-haiku-4-5"'
fake_cli "$FAKE_BIN/claude" claude $claude_ids
held_check claude
taken
count=$(events)
fake_cli "$FAKE_BIN/claude" claude $claude_ids claude-haiku-3-55
held_check claude
assert [ "$(events)" = $((count + 1)) ]
assert [ "$(field '"\(.vendor) \(.status) \(.changed | join(","))"')" = "claude auto-closed ids" ]
sed -i '' '2s/$/ gemini-3.5-flash-lite/' "$FAKE_BIN/agy"
held_check gemini
assert [ "$(events)" = $((count + 2)) ]
assert [ "$(field '"\(.vendor) \(.status)"')" = "gemini auto-closed" ]
fake_cli "$FAKE_BIN/claude" claude $claude_ids claude-haiku-3-55 claude-haiku-5-5 'first_party:"claude-haiku-5-5"'
held_check claude
night_claude=$(field .id)
assert [ "$(field '"\(.vendor) \(.status) \(.substantive | join(","))"')" = "claude open ids" ]
assert grep -qxF '+claude-haiku-5-5' "$EVENTS/$night_claude.diff"
# Help text alone goes to Sonnet, told when to hand itself back; a new served model stays on the default.
printf 'grok usage\n  -p, --print\n  --fast\n' >"$DATA/help-grok"
held_check grok
night_help=$(field .id)
assert [ "$(field '"\(.vendor) \(.status) \(.substantive | join(","))"')" = "grok open help: grok --help" ]
git -C "$NREPO" update-ref refs/night/N2/base HEAD
git -C "$SIB" update-ref refs/night/N2/base HEAD
assert night N2 >"$WORK/night2"
help_brief=$(jq -r .brief "$EVENTS/$night_help.json")
assert [ "$(sed -n 2p "$help_brief")" = "MODEL: sonnet" ]
assert grep -qF 'end with `ESCALATE: <reason>`' "$help_brief"
claude_brief=$(jq -r .brief "$EVENTS/$night_claude.json")
assert_fails grep -q '^MODEL:' "$claude_brief"
assert_fails grep -q 'ESCALATE' "$claude_brief"
assert_fails grep -q '^MODEL:' "$n_brief"

# A field that is a leaf in one home and a container in another no longer kills the codex catalog
# merge (gpt-6.1-sol vanished from every catalog facet this way), and a merge that does fail is a
# broken probe, never a silently missing facet.
v=$(cat "$DATA/ver-codex")
mkdir -p "$HOME/.codex-profiles/x" "$HOME/.codex-profiles/y" "$HOME/.codex-profiles/z"
codex_cache "$HOME/.codex-profiles/x" "$v" '[{"slug":"gpt-7-test","available_in_plans":[]}]'
codex_cache "$HOME/.codex-profiles/y" "$v" '[{"slug":"gpt-7-test","available_in_plans":["pro"]}]'
bash "$SCRIPT" snapshot codex >"$WORK/merge.json"
assert jqe '.facets.catalog["gpt-7-test"].available_in_plans.per_account == [[], ["pro"]]' "$WORK/merge.json"
assert jqe '[.failed[] | select(.facet == "catalog")] == []' "$WORK/merge.json"
# Accounts served two prompt texts leave no trace in the catalog, only in catalog_text.
codex_cache "$HOME/.codex-profiles/x" "$v" "[{\"slug\":\"gpt-7-test\",\"model_messages\":{\"policy\":\"$PROMPT\"}}]"
codex_cache "$HOME/.codex-profiles/y" "$v" "[{\"slug\":\"gpt-7-test\",\"model_messages\":{\"policy\":\"$PROMPT v2\"}}]"
bash "$SCRIPT" snapshot codex >"$WORK/texts.json"
assert jqe '.facets.catalog["gpt-7-test"].model_messages == {}' "$WORK/texts.json"
assert jqe '.facets.catalog_text | has("gpt-7-test.model_messages.policy.per_account.1")' "$WORK/texts.json"
codex_cache "$HOME/.codex-profiles/z" "$v" '[1]'
bash "$SCRIPT" snapshot codex >"$WORK/broken.json"
assert jqe '(.facets | has("catalog") | not) and ([.failed[] | select(.facet == "catalog")] == [{facet: "catalog", where: "local"}])' "$WORK/broken.json"

# A vendor's later event that cannot be written gives back the earlier ones, base and all, so a
# later request launches them all.
: >"$DATA/opener-fails"
bash "$SCRIPT" request codex >/dev/null
rm "$DATA/opener-fails"
printf 'Codex CLI\n  --model <MODEL>\n  --fast\n' >"$DATA/help-codex"
held_check codex
two=$(jq -r 'select(.status == "open" and .launched_at == null) | .id' "$EVENTS"/codex-*.json)
assert [ "$(wc -l <<<"$two" | tr -d ' ')" = 2 ]
bases=$(ls "$EVENTS"/codex-*.base)
mkdir -p "$WORK/jq-fails"
printf '#!/usr/bin/env bash\ncase "$*" in *".launched_at = \$t | .launched = (if"*) n=$(($(cat "$DATA/jq-calls" 2>/dev/null || echo 0) + 1)); echo "$n" >"$DATA/jq-calls"; [ "$n" -lt 2 ] || exit 1 ;; esac\nexec /usr/bin/jq "$@"\n' \
  >"$WORK/jq-fails/jq"
chmod +x "$WORK/jq-fails/jq"
PATH="$WORK/jq-fails:$PATH" bash "$SCRIPT" request codex >/dev/null 2>&1
assert [ "$(cat "$DATA/jq-calls")" = 2 ]
for e in $two; do assert jqe '.launched_at == null and .run == null' "$EVENTS/$e.json"; done
assert [ "$(ls "$EVENTS"/codex-*.base)" = "$bases" ]
bash "$SCRIPT" request codex >/dev/null
for e in $two; do assert jqe '.launched_at != null and .run != null' "$EVENTS/$e.json"; done
assert [ "$(ls "$EVENTS"/codex-*.base 2>/dev/null)" = "" ]

echo "PASS: $asserts asserts; baseline, version-only releases close themselves, new ids/catalog fields/docs/help/newly lagging installs/divergence open an event each, an install catching up, still lagging or ahead of the primary closes itself, prompts and foreign clients are informational, unreadable facets keep their value, broken local probes are reported, manual requests, close, lock, check --here, no chat from check for a waiting event however old, a failed manual request retried by check, waiting events joined and reverts closed, day requests as per-vendor fixer runs of doctor updater (worktree off main, brief) dispatched by one orchestrator chat, every vendor in that chat on request --all, each run closing with its event, a failed chat failing its run, a request taking its vendor's waiting event, manual diffs that carry the whole fingerprint, decision purposes judged by doctor-fix, a bounded lock wait for check --here, one worktree, branch, brief and updater fixer run (the printed ref) per vendor on request --night and none without a base ref, a codex catalog merge across homes whose field shapes differ, a failed merge reported as a broken probe, a night request under the check lock, purposes that cannot be judged holding the close, string ids no served catalog lists opening nothing, and help-only releases briefed for Sonnet"
