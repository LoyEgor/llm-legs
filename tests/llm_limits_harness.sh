# Sourced by every tests/test_llm_limits*.sh: each suite builds its own $WORK of fixtures from here.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/llm-limits.sh"
WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
strip_ansi() { sed $'s/\033\[[0-9;]*m//g'; }
unset CLICOLOR_FORCE
# Every fixture owns its worker-model through HOME; an inherited path would point the run at
# the real one, where a vendor Egor parked is missing from the store the asserts describe.
unset WORKER_PICK_CONFIG_FILE
# Unit fixtures must never discover and launch the developer's real agy binary.
export LLM_LIMITS_GEMINI_REFRESH=0
export LLM_LIMITS_CODEX_REFRESH=0
export LLM_LIMITS_GROK_REFRESH=0
# Weather fixtures would otherwise spin claudeb's real convergence loop (240s of sleeps).
export CLAUDEB_REFRESH_CONVERGE_S=0
export CLAUDEB_WEATHER_RETRY_DELAY=0
export CLAUDEB_OAUTH_TOKEN_SPACING=0

HOME_FIXTURE="$WORK/home"
mkdir -p "$HOME_FIXTURE/.claude" "$HOME_FIXTURE/.codex/sessions/2026/07/10" "$HOME_FIXTURE/.codex/sessions/2026/07/11"
now=$(date +%s)
printf '{"five_hour":{"used_percentage":19,"resets_at":%s},"seven_day":{"used_percentage":53,"resets_at":%s}}\n' "$((now + 1800))" "$((now + 7200))" >"$HOME_FIXTURE/.claude/statusline-cache-rl"
printf '{"model":{"display_name":"Fable 5"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":%s},"seven_day":{"used_percentage":40,"resets_at":%s}}}\n' "$((now + 2400))" "$((now + 8400))" >"$HOME_FIXTURE/.claude/statusline-last.json"
cat >"$HOME_FIXTURE/.codex/sessions/2026/07/10/rollout-old.jsonl" <<EOF
{"timestamp":"2026-07-11T10:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":74,"window_minutes":300,"resets_at":$((now + 1000))},"secondary":{"used_percent":31,"window_minutes":10080,"resets_at":$((now + 2000))},"plan_type":"plus"}}}
{"timestamp":"2026-07-11T10:01:00Z","payload":{"type":"other"}}
EOF
# Older than rollout-new.jsonl by more than the second the collector sorts mtimes at.
touch -t "$(date -r "$((now - 60))" +%Y%m%d%H%M.%S)" "$HOME_FIXTURE/.codex/sessions/2026/07/10/rollout-old.jsonl"
printf '%s\n' '{"timestamp":"2026-07-11T11:00:00Z","payload":{"type":"session_meta"}}' >"$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-new.jsonl"
WALLS="$WORK/served-models.jsonl"
printf '%s\n' \
  '{"timestamp":"2026-07-11T08:00:00Z","leg":"gemini","rc":5}' \
  '{"timestamp":"2026-07-11T09:00:00Z","leg":"codex","rc":5}' >"$WALLS"

CACHE="$WORK/cache.json"

# Gemini refresh: the helper's raw remainingFraction snapshot is cached and normalized to the
# same used_pct/reset schema as Claude and Codex. A normal collection reuses it without a call.
GEMINI_HELPER="$WORK/fake-agy-quota"
GEMINI_CACHE="$WORK/gemini.json"
GEMINI_SENTINEL="$WORK/gemini-called"
# Both windows are stated ahead of now rather than on fixed dates: a reset the clock has carried
# more than a day past is dropped by the collector, so a frozen date would stop being a reset to
# pass through at all and this would assert the drop instead of the normalization it is here for.
GEMINI_FIVE_RESET=$(date -u -r "$((now + 43200))" +%Y-%m-%dT%H:%M:%SZ)
GEMINI_WEEK_RESET=$(date -u -r "$((now + 604800))" +%Y-%m-%dT%H:%M:%SZ)
export GEMINI_FIVE_RESET GEMINI_WEEK_RESET
cat >"$GEMINI_HELPER" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$GEMINI_SENTINEL"
printf '{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.75,"resetTime":"%s"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.995,"resetTime":"%s"}]}]}\n' \
  "$GEMINI_WEEK_RESET" "$GEMINI_FIVE_RESET"
EOF
chmod +x "$GEMINI_HELPER"
GEMINI_SECURITY_STUB="$WORK/fake-security"
cat >"$GEMINI_SECURITY_STUB" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != create-keychain ] || printf '%s' "$3" >"$4"
EOF
chmod +x "$GEMINI_SECURITY_STUB"

# What the first suite leaves in the shared fixtures that the later ones were written against.
home_fixture_after_first_suite() {
  rm -f "$HOME_FIXTURE/.claude/statusline-last.json"
  mkdir -p "$HOME_FIXTURE/.codex-profiles/.codexb" "$HOME_FIXTURE/Library/Keychains" "$HOME_FIXTURE/.llm-limits-gemini"
}
seed_gemini_cache() {
  GEMINI_SENTINEL="$WORK/gemini-seeded" "$GEMINI_HELPER" >"$GEMINI_CACHE"
  gemini_cache_saved=$(cat "$GEMINI_CACHE")
}
CLAUDEB="$WORK/claudeb-store"
seed_claudeb_store() {
  mkdir -p "$CLAUDEB/limits" "$CLAUDEB/tokens"
  : >"$CLAUDEB/tokens/alona"
  printf 'alona\n' >"$CLAUDEB/.claudeb-state"
  printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' "$((now + 5000))" "$((now + 5500))" "$now" >"$CLAUDEB/limits/alona.json"
  printf '{"five_hour":{"used_percentage":21,"resets_at":%s},"seven_day":{"used_percentage":62,"resets_at":%s}}\n' "$((now + 6000))" "$((now + 7000))" >"$CLAUDEB/limits/main.json"
  printf '{"five_hour":{"used_percentage":99,"resets_at":%s}}\n' "$((now + 6000))" >"$CLAUDEB/limits/-.json"
}
