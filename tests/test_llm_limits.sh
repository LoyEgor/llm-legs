#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/llm-limits.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Unit fixtures must never discover and launch the developer's real agy binary.
export LLM_LIMITS_GEMINI_REFRESH=0
export LLM_LIMITS_CODEX_REFRESH=0

HOME_FIXTURE="$WORK/home"
mkdir -p "$HOME_FIXTURE/.claude" "$HOME_FIXTURE/.codex/sessions/2026/07/10" "$HOME_FIXTURE/.codex/sessions/2026/07/11"
now=$(date +%s)
printf '{"five_hour":{"used_percentage":19,"resets_at":%s},"seven_day":{"used_percentage":53,"resets_at":%s}}\n' "$((now + 1800))" "$((now + 7200))" >"$HOME_FIXTURE/.claude/statusline-cache-rl"
printf '{"model":{"display_name":"Fable 5"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":%s},"seven_day":{"used_percentage":40,"resets_at":%s}}}\n' "$((now + 2400))" "$((now + 8400))" >"$HOME_FIXTURE/.claude/statusline-last.json"
cat >"$HOME_FIXTURE/.codex/sessions/2026/07/10/rollout-old.jsonl" <<EOF
{"timestamp":"2026-07-11T10:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":74,"window_minutes":300,"resets_at":$((now + 1000))},"secondary":{"used_percent":31,"window_minutes":10080,"resets_at":$((now + 2000))},"plan_type":"plus"}}}
{"timestamp":"2026-07-11T10:01:00Z","payload":{"type":"other"}}
EOF
sleep 1
printf '%s\n' '{"timestamp":"2026-07-11T11:00:00Z","payload":{"type":"session_meta"}}' >"$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-new.jsonl"
WALLS="$WORK/served-models.jsonl"
printf '%s\n' \
  '{"timestamp":"2026-07-11T08:00:00Z","leg":"gemini","rc":5}' \
  '{"timestamp":"2026-07-11T09:00:00Z","leg":"codex","rc":5}' >"$WALLS"

CACHE="$WORK/cache.json"
out=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_WALLS_LOG="$WALLS" bash "$SCRIPT" --json) || fail "fixture collection failed"
jq -e '.schema == 1 and (.vendors | keys == ["claude","codex","gemini"])' <<<"$out" >/dev/null || fail "schema mismatch"
jq -e '.vendors.claude.five_hour.used_pct == 12 and .vendors.claude.weekly.used_pct == 40 and .vendors.claude.source == "statusline-last" and .vendors.claude.current_account == "main" and (.vendors.claude.accounts | length) == 1 and (.vendors.claude | has("session_model") | not)' <<<"$out" >/dev/null || fail "Claude primary snapshot mismatch"
jq -e '.vendors.codex.five_hour.used_pct == 74 and .vendors.codex.weekly.used_pct == 31 and .vendors.codex.plan_type == "plus"' <<<"$out" >/dev/null || fail "Codex fallback mismatch"
jq -e '.vendors.gemini.available == false and .vendors.gemini.status == "no quota snapshot" and .vendors.gemini.last_wall == "2026-07-11T08:00:00Z"' <<<"$out" >/dev/null || fail "Gemini state mismatch"
jq -e . "$CACHE" >/dev/null || fail "cache was not valid JSON"
compgen -G "$CACHE.tmp.*" >/dev/null && fail "atomic-write temporary file remains"

# Gemini refresh: the helper's raw remainingFraction snapshot is cached and normalized to the
# same used_pct/reset schema as Claude and Codex. A normal collection reuses it without a call.
GEMINI_HELPER="$WORK/fake-agy-quota"
GEMINI_CACHE="$WORK/gemini.json"
GEMINI_SENTINEL="$WORK/gemini-called"
cat >"$GEMINI_HELPER" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$GEMINI_SENTINEL"
printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.75,"resetTime":"2026-07-18T12:00:00Z"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.995,"resetTime":"2026-07-11T22:00:00Z"}]}]}'
EOF
chmod +x "$GEMINI_HELPER"
gemini_live=$(GEMINI_SENTINEL="$GEMINI_SENTINEL" LLM_LIMITS_GEMINI_REFRESH=1 \
  LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh) \
  || fail "Gemini refresh collection failed"
jq -e '.vendors.gemini.available == true and .vendors.gemini.source == "agy-local-rpc" and
  (.vendors.gemini.five_hour.used_pct > 0.49 and .vendors.gemini.five_hour.used_pct < 0.51) and
  .vendors.gemini.weekly.used_pct == 25 and
  .vendors.gemini.five_hour.resets_at == "2026-07-11T22:00:00Z"' <<<"$gemini_live" >/dev/null \
  || fail "Gemini quota normalization mismatch"
[ -s "$GEMINI_SENTINEL" ] || fail "Gemini helper was not invoked by --refresh"
rm -f "$GEMINI_SENTINEL"
gemini_cached=$(LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" HOME="$HOME_FIXTURE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Gemini cached collection failed"
jq -e '.vendors.gemini.available == true and .vendors.gemini.weekly.used_pct == 25' \
  <<<"$gemini_cached" >/dev/null || fail "Gemini cached snapshot missing"
[ ! -e "$GEMINI_SENTINEL" ] || fail "default collection invoked Gemini helper"

# Regression: statusline-last.json goes stale while cache-rl keeps updating —
# the fresher cache-rl must win even though last.json is present and valid.
sleep 1
touch "$HOME_FIXTURE/.claude/statusline-cache-rl"
fresher=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "freshest-wins collection failed"
jq -e '.vendors.claude.five_hour.used_pct == 19 and .vendors.claude.source == "statusline-cache" and (.vendors.claude | has("session_model") | not)' <<<"$fresher" >/dev/null || fail "stale statusline-last.json outranked a fresher cache-rl"

rm "$HOME_FIXTURE/.claude/statusline-last.json"
fallback=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude fallback collection failed"
jq -e '.vendors.claude.five_hour.used_pct == 19 and .vendors.claude.weekly.used_pct == 53 and (.vendors.claude | has("session_model") | not) and .vendors.claude.source == "statusline-cache"' <<<"$fallback" >/dev/null || fail "Claude cache fallback mismatch"

plain=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "plain collection failed"
grep -q 'claude/main: 19%/53%' <<<"$plain" || fail "plain Claude values missing"
grep -q 'codex: 74%/31%' <<<"$plain" || fail "plain Codex values missing"
fallback_table=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "fallback table collection failed"
grep -q '^claude/main' <<<"$fallback_table" || fail "unique fallback main account missing from table"

CLAUDEB="$WORK/claudeb-store"
mkdir -p "$CLAUDEB/limits" "$CLAUDEB/tokens"
: >"$CLAUDEB/tokens/alona"
printf 'alona\n' >"$CLAUDEB/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now + 5500))" >"$CLAUDEB/limits/alona.json"
printf '{"five_hour":{"used_percentage":21,"resets_at":%s},"seven_day":{"used_percentage":62,"resets_at":%s}}\n' "$((now + 6000))" "$((now + 7000))" >"$CLAUDEB/limits/main.json"
multi=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "claudeb collection failed"
jq -e '.vendors.claude.source == "claudeb-store" and (.vendors.claude.accounts | length) == 1 and .vendors.claude.accounts[0].account == "alona" and .vendors.claude.accounts[0].is_current == true and (.vendors.claude.accounts[0] | has("weekly") | not) and .vendors.claude.five_hour == .vendors.claude.accounts[0].five_hour and (.vendors.claude | has("weekly") | not)' <<<"$multi" >/dev/null || fail "claudeb schema, uniqueness, or hoist mismatch"
jq -e '.vendors.claude.accounts[0].fable.used_pct == 33 and .vendors.claude.fable.used_pct == 33 and all(.vendors.claude.accounts[]; .account != "main")' <<<"$multi" >/dev/null || fail "claudeb fable or unique-account mismatch"
printf 'main\n' >"$CLAUDEB/.claudeb-state"
invalid_current=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "invalid current fallback failed"
jq -e '.vendors.claude.current_account == "alona" and all(.vendors.claude.accounts[]; .account != "main")' <<<"$invalid_current" >/dev/null || fail "invalid current did not fall back to the first real account"
printf 'alona\n' >"$CLAUDEB/.claudeb-state"
multi_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "claudeb plain collection failed"
grep -q 'claude/alona: 7%/- |' <<<"$multi_plain" || fail "claudeb missing-weekly plain output mismatch"
grep -q 'claude/main' <<<"$multi_plain" && fail "main account leaked into plain output"

FAKE_BIN="$WORK/bin"
SENTINEL="$WORK/claudeb-called"
CODEX_SENTINEL="$WORK/codex-called"
mkdir -p "$FAKE_BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$CLAUDEB_SENTINEL"\n' >"$FAKE_BIN/claudeb"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >>"$CODEX_SENTINEL"\n' >"$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/claudeb" "$FAKE_BIN/codex"
CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" LLM_LIMITS_CODEX_REFRESH=1 PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh >/dev/null || fail "refresh collection failed"
[ -s "$SENTINEL" ] || fail "--refresh did not invoke claudeb accounts"
grep -q 'accounts --no-spend' "$SENTINEL" || fail "Claude refresh was not tier-1-only"
[ -s "$CODEX_SENTINEL" ] || fail "--refresh did not invoke codex"
grep -qx -- '--sandbox' "$CODEX_SENTINEL" && grep -qx 'read-only' "$CODEX_SENTINEL" || fail "Codex refresh did not use the read-only sandbox"
grep -qx 'model_reasoning_effort="low"' "$CODEX_SENTINEL" || fail "Codex refresh did not request low reasoning effort"
grep -qx -- '-m' "$CODEX_SENTINEL" && fail "Codex refresh unexpectedly overrode the configured model"
rm -f "$SENTINEL"
rm -f "$CODEX_SENTINEL"
CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" >/dev/null || fail "default gated collection failed"
[ ! -e "$SENTINEL" ] || fail "default collection invoked claudeb"
[ ! -e "$CODEX_SENTINEL" ] || fail "default collection invoked codex"

fresh_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12,"resets_at":%s},"secondary":{"used_percent":34,"resets_at":%s}}}}\n' "$fresh_ts" "$((now + 5000))" "$((now + 9000))" >"$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-fresh.jsonl"
CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" LLM_LIMITS_CODEX_REFRESH=1 PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh >/dev/null || fail "fresh refresh collection failed"
[ ! -e "$CODEX_SENTINEL" ] || fail "fresh Codex data triggered a paid refresh"
rm "$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-fresh.jsonl"

EXPIRED_HOME="$WORK/expired-codex-home"
mkdir -p "$EXPIRED_HOME/.codex/sessions"
printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99,"resets_at":%s},"secondary":{"used_percent":34,"resets_at":%s}}}}\n' "$fresh_ts" "$((now - 1))" "$((now + 9000))" >"$EXPIRED_HOME/.codex/sessions/rollout-expired.jsonl"
CODEX_SENTINEL="$CODEX_SENTINEL" LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_MODEL="fixture model" PATH="$FAKE_BIN:$PATH" HOME="$EXPIRED_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh >/dev/null || fail "expired refresh collection failed"
[ -s "$CODEX_SENTINEL" ] || fail "expired Codex data did not trigger refresh"
grep -qx -- '-m' "$CODEX_SENTINEL" || fail "Codex model override flag was not passed"
grep -qx 'fixture model' "$CODEX_SENTINEL" || fail "Codex model override was not passed as one argument"
rm -f "$CODEX_SENTINEL"

# Undeterminable Codex freshness (fresh event, null resets_at) must neither crash the
# run under set -u nor force the paid codex poll.
NULLRESET_HOME="$WORK/nullreset-codex-home"
mkdir -p "$NULLRESET_HOME/.codex/sessions"
printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":41,"resets_at":null},"secondary":{"used_percent":22,"resets_at":null}}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$NULLRESET_HOME/.codex/sessions/rollout-nullreset.jsonl"
CODEX_SENTINEL="$CODEX_SENTINEL" LLM_LIMITS_CODEX_REFRESH=1 PATH="$FAKE_BIN:$PATH" HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh >/dev/null || fail "null resets_at refresh crashed"
[ ! -e "$CODEX_SENTINEL" ] || fail "unknown Codex freshness forced a paid refresh"
null_reset=$(HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "null resets_at collection failed"
jq -e '.vendors.codex.available == true and .vendors.codex.five_hour.used_pct == 41 and .vendors.codex.five_hour.resets_at == null' <<<"$null_reset" >/dev/null || fail "null resets_at not normalized"
HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain | grep -q 'codex: 41%/22%' || fail "null resets_at plain render failed"
HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table | grep -q '^codex' || fail "null resets_at table render failed"

table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "table collection failed"
grep -q $'\x1b' <<<"$table" && fail "piped table output contains ANSI escapes"
head -n 1 <<<"$table" | grep -q '^SOURCE ' || fail "table header missing"
grep -q '^claude/main' <<<"$table" && fail "main account must be hidden from the table"
jq -e 'all(.vendors.claude.accounts[]; .account != "main")' <<<"$multi" >/dev/null || fail "duplicate main account remained in JSON"
[ "$(grep -c '^claude/' <<<"$table")" -eq 1 ] || fail "table must render one row per non-main claude account"
order=$(awk 'NR > 1 {print $1}' <<<"$table" | paste -sd, -)
[ "$order" = "claude/alona*,codex,gemini" ] || fail "default table order mismatch: $order"
grep -q 'fable 33%' <<<"$table" || fail "fable note missing from table"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now - 1))" >"$CLAUDEB/limits/alona.json"
expired_fable=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "expired fable table failed"
grep -q 'fable 33%' <<<"$expired_fable" && fail "expired fable remained in table note"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now + 5500))" >"$CLAUDEB/limits/alona.json"
awk 'NR > 1 && $1 == "codex"' <<<"$table" | grep -Eq '[0-9]{2}:[0-9]{2}' || fail "codex reset time not rendered"
sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort 5h) || fail "sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$sorted" | paste -sd, -)
[ "$order" = "codex,claude/alona*,gemini" ] || fail "--sort 5h order mismatch: $order"
# zoe: distant 5h reset but imminent weekly reset — --sort reset must use min(5h, weekly).
printf '{"five_hour":{"used_percentage":11,"resets_at":%s},"seven_day":{"used_percentage":97,"resets_at":%s}}\n' "$((now + 50000))" "$((now + 500))" >"$CLAUDEB/limits/zoe.json"
reset_sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort reset) || fail "reset-sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$reset_sorted" | paste -sd, -)
[ "$order" = "claude/zoe,codex,claude/alona*,gemini" ] || fail "--sort reset min(5h, weekly) order mismatch: $order"
rm "$CLAUDEB/limits/zoe.json"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort bogus >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "unknown --sort value: expected exit 2, got $rc"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort= >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "empty --sort=: expected exit 2, got $rc"
bare=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT") || fail "bare piped collection failed"
jq -e '.schema == 1 and (.vendors | keys == ["claude","codex","gemini"])' <<<"$bare" >/dev/null || fail "piped bare invocation must emit schema-1 JSON"

sleep 1
TRUNCATED="$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-truncated.jsonl"
printf '{"padding":"%0700d"}\n' 0 >"$TRUNCATED"
printf '{"timestamp":"2026-07-11T12:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":88,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":44,"window_minutes":10080,"resets_at":%s},"plan_type":"plus"}}}\n' "$((now + 3000))" "$((now + 4000))" >>"$TRUNCATED"
truncated=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_CHUNK_BYTES=512 bash "$SCRIPT" --json) || fail "truncated-chunk collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 88 and .vendors.codex.weekly.used_pct == 44' <<<"$truncated" >/dev/null || fail "valid event after truncated boundary was lost"

CROSS_HOME="$WORK/cross-home"
mkdir -p "$CROSS_HOME/.codex/sessions"
printf '{"timestamp":"2026-07-12T03:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":37,"resets_at":%s},"secondary":{"used_percent":23,"resets_at":%s}}}}\n' "$((now + 5000))" "$((now + 9000))" >"$CROSS_HOME/.codex/sessions/rollout-numeric.jsonl"
printf '%s\n' '{"timestamp":"2026-07-12T04:00:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":{"used_percent":99}}}}' >"$CROSS_HOME/.codex/sessions/rollout-null.jsonl"
touch -t 202607120100 "$CROSS_HOME/.codex/sessions/rollout-numeric.jsonl"
touch -t 202607120200 "$CROSS_HOME/.codex/sessions/rollout-null.jsonl"
cross_null=$(HOME="$CROSS_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "cross-file null-primary collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 37 and .vendors.codex.weekly.used_pct == 23' <<<"$cross_null" >/dev/null || fail "null-primary file hid a valid cross-file event"

printf '{"timestamp":"2026-07-12T02:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":61,"resets_at":%s},"secondary":{"used_percent":41,"resets_at":%s}}}}\n' "$((now + 6000))" "$((now + 10000))" >"$CROSS_HOME/.codex/sessions/rollout-mtime-newest.jsonl"
printf '{"timestamp":"2026-07-12T08:00:00+03:00","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":17,"resets_at":%s},"secondary":{"used_percent":11,"resets_at":%s}}}}\n' "$((now + 7000))" "$((now + 11000))" >"$CROSS_HOME/.codex/sessions/rollout-timestamp-latest.jsonl"
touch -t 202607120400 "$CROSS_HOME/.codex/sessions/rollout-timestamp-latest.jsonl"
touch -t 202607120500 "$CROSS_HOME/.codex/sessions/rollout-mtime-newest.jsonl"
cross_latest=$(HOME="$CROSS_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "cross-file timestamp collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 17 and .vendors.codex.weekly.used_pct == 11' <<<"$cross_latest" >/dev/null || fail "mtime order outranked the latest event timestamp"

# Passive snapshot whose 5h reset already passed: flagged expired, table shows dashes
# and a note, sort treats the stale 100% as 0. The fresh weekly window stays unflagged.
sleep 1
printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":44,"window_minutes":10080,"resets_at":%s},"plan_type":"plus"}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$((now - 600))" "$((now + 4000))" \
  >"$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-expired.jsonl"
expired_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "expired-window collection failed"
jq -e '.vendors.codex.five_hour.expired == true and .vendors.codex.five_hour.used_pct == 100 and
  (.vendors.codex.weekly | has("expired") | not) and
  (.vendors.claude.accounts[0].five_hour | has("expired") | not)' <<<"$expired_json" >/dev/null || fail "expired flag mismatch"
expired_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "expired table collection failed"
codex_row=$(awk 'NR > 1 && $1 == "codex"' <<<"$expired_table")
grep -Eq '^codex +- +44% +- ' <<<"$codex_row" || fail "expired table columns not dashed: $codex_row"
grep -q '5h reset passed' <<<"$codex_row" || fail "expired note missing from table"
expired_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "expired plain collection failed"
grep -q 'codex: -/44%' <<<"$expired_plain" || fail "expired plain value was not blanked"
expired_sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort 5h) || fail "expired sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$expired_sorted" | paste -sd, -)
[ "$order" = "claude/alona*,codex,gemini" ] || fail "expired 5h sort must rank the stale 100% as 0: $order"

EMPTY="$WORK/empty-home"
mkdir -p "$EMPTY"
HOME="$EMPTY" bash "$SCRIPT" --no-write >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] || fail "all-missing case: expected exit 3, got $rc"

echo "PASS: schema, Claude unique accounts and fallback, refresh gating, small-file fallback, truncated boundary, walls, plain output, table output and sorts, expired windows, bare JSON default, atomic cache, missing exit 3"
exit 0
