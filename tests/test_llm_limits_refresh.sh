#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/llm_limits_harness.sh"

home_fixture_after_first_suite
seed_claudeb_store
seed_gemini_cache

CLAUDEB_BIN="$ROOT/bin/claudeb"
OAUTH_HOME="$WORK/oauth-home"
OAUTH_STORE="$WORK/oauth-store"
OAUTH_BIN="$WORK/oauth-bin"
OAUTH_SENTINEL="$WORK/oauth-curl-called"
OAUTH_CLAUDE_SENTINEL="$WORK/oauth-claude-called"
mkdir -p "$OAUTH_HOME/.claude-profiles/stuck" "$OAUTH_STORE/tokens" "$OAUTH_STORE/limits" "$OAUTH_BIN"
printf 'fixture-token\n' >"$OAUTH_STORE/tokens/stuck"
printf 'stuck\n' >"$OAUTH_STORE/.claudeb-state"
cat >"$OAUTH_BIN/security" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -w "*) printf '{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":%s}}\n' "${OAUTH_EXPIRES_AT:-1}" ;;
  *) exit 0 ;;
esac
EOF
cat >"$OAUTH_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OAUTH_SENTINEL"
headers=''
previous=''
for arg in "$@"; do
  if [ "$previous" = -D ]; then headers=$arg; fi
  previous=$arg
done
case "$*" in
  *platform.claude.com*) printf '\n400' ;;
  *api.anthropic.com/v1/messages*)
    if [ "${OAUTH_MESSAGES_HTTP:-200}" != 200 ]; then printf '%s' "$OAUTH_MESSAGES_HTTP"; exit; fi
    printf '%s\n' 'HTTP/2 200' 'anthropic-ratelimit-unified-status: allowed' \
      'anthropic-ratelimit-unified-5h-utilization: 0.01' \
      "anthropic-ratelimit-unified-5h-reset: $(($(date +%s) + 3600))" >"$headers"
    printf '200'
    ;;
  *) printf '%s' "${OAUTH_USAGE_HTTP:-401}" ;;
esac
EOF
cat >"$OAUTH_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OAUTH_CLAUDE_SENTINEL"
printf '%s\n' '{"result":"usage"}'
EOF
chmod +x "$OAUTH_BIN/security" "$OAUTH_BIN/curl" "$OAUTH_BIN/claude"
# A "failed" record from the direct-refresh path (curl against the OAuth token
# endpoint) must never gate the zero-cost warm fallback — heal proceeds anyway,
# since warm refreshes through the `claude` CLI's own auth, not that curl call.
printf '{"stuck":{"attempted_at":%s,"outcome":"failed","retry_after_until":0}}\n' "$now" >"$OAUTH_STORE/oauth-attempts.json"
OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend --heal >/dev/null 2>"$WORK/oauth-backoff.err" || true
grep -q -- '-p /usage --output-format json' "$OAUTH_CLAUDE_SENTINEL" || fail "a direct-refresh failure record blocked the zero-cost warm fallback"

# A recent warm-failed outcome (warm's own bookkeeping) DOES throttle repeat
# heal attempts, at most once per account per 30 minutes. The throttle is a
# capacity condition, not evidence of dead credentials, so a throttled cycle must
# leave any prior auth verdict byte-untouched — never stamping or re-stamping one
# (a capacity "backoff" cause would refresh checked_at and disguise an unproven
# verdict as freshly confirmed).
rm -f "$OAUTH_STORE/oauth-attempts.json" "$OAUTH_SENTINEL" "$OAUTH_CLAUDE_SENTINEL"
printf '{"stuck":{"attempted_at":%s,"outcome":"warm-failed","retry_after_until":0}}\n' "$now" >"$OAUTH_STORE/oauth-attempts.json"
printf '{"auth":{"status":"expired","checked_at":31337,"cause":"prior sentinel"}}' >"$OAUTH_STORE/limits/stuck.json"
OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend --heal >/dev/null 2>/dev/null || true
[ ! -e "$OAUTH_CLAUDE_SENTINEL" ] || fail "a recent warm-failed outcome was not throttled to once per 30 minutes"
jq -e '.auth.status == "expired" and .auth.checked_at == 31337 and .auth.cause == "prior sentinel"' "$OAUTH_STORE/limits/stuck.json" >/dev/null \
  || fail "throttled heal must leave a prior auth verdict byte-untouched"

rm -f "$OAUTH_STORE/oauth-attempts.json" "$OAUTH_SENTINEL" "$OAUTH_CLAUDE_SENTINEL"
OAUTH_EXPIRES_AT="$(((now + 3600) * 1000))" OAUTH_USAGE_HTTP=403 OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend >/dev/null 2>/dev/null || fail "plain refresh routing fixture failed"
[ ! -e "$OAUTH_CLAUDE_SENTINEL" ] || fail "plain accounts triggered warm without --heal"

rm -f "$OAUTH_STORE/oauth-attempts.json" "$OAUTH_SENTINEL" "$OAUTH_CLAUDE_SENTINEL"
OAUTH_EXPIRES_AT="$(((now + 3600) * 1000))" OAUTH_USAGE_HTTP=403 OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend --heal >/dev/null 2>/dev/null || true
grep -q -- '-p /usage --output-format json' "$OAUTH_CLAUDE_SENTINEL" || fail "--heal did not self-heal auth with /usage"
grep -q -- '-p ok --model haiku' "$OAUTH_CLAUDE_SENTINEL" && fail "plain refresh used the paid warm fallback"

rm -f "$OAUTH_SENTINEL" "$OAUTH_CLAUDE_SENTINEL"
printf '{"stuck":{"attempted_at":%s,"outcome":"warming","retry_after_until":0}}\n' "$((now - 181))" >"$OAUTH_STORE/oauth-attempts.json"
OAUTH_EXPIRES_AT="$(((now + 3600) * 1000))" OAUTH_USAGE_HTTP=403 OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend --heal >/dev/null 2>/dev/null || true
grep -q -- '-p /usage --output-format json' "$OAUTH_CLAUDE_SENTINEL" || fail "stale warming state did not expire"

if HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" bash "$CLAUDEB_BIN" add warm </dev/null >/dev/null 2>&1; then
  fail "add accepted reserved account name warm"
fi

rm -f "$OAUTH_STORE/oauth-attempts.json" "$OAUTH_SENTINEL"
OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" CLAUDEB_WARM_USER_EXPLICIT=true \
  bash "$CLAUDEB_BIN" --refresh --start-windows >/dev/null 2>/dev/null || fail "start-windows auth fallback fixture failed"
grep -q 'api.anthropic.com/v1/messages' "$OAUTH_SENTINEL" || fail "start-windows did not use the messages fallback after auth failure"

WARM_HOME="$WORK/warm-home"
WARM_STORE="$WORK/warm-store"
WARM_BIN="$WORK/warm-bin"
WARM_SENTINEL="$WORK/warm-called"
mkdir -p "$WARM_HOME/.claude-profiles/one" "$WARM_HOME/.claude-profiles/two" \
  "$WARM_STORE/tokens" "$WARM_STORE/limits" "$WARM_BIN"
printf 'fixture\n' >"$WARM_STORE/tokens/one"
printf 'fixture\n' >"$WARM_STORE/tokens/two"
printf 'two\n' >"$WARM_STORE/disabled"
cat >"$WARM_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$CLAUDE_LIMITS_ACCOUNT" "$CLAUDE_CONFIG_DIR" "$*" >>"$WARM_SENTINEL"
if [ "${WARM_USAGE_429:-0}" = 1 ] && [ "${2:-}" = /usage ]; then printf 'HTTP 429 rate limit\n' >&2; exit 7; fi
if [ "${WARM_FAIL_USAGE:-0}" = 1 ] && [ "${2:-}" = /usage ]; then exit 7; fi
printf '%s\n' '{"result":"ok"}'
EOF
cat >"$WARM_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":$(((now + 3600) * 1000))}}'
EOF
cat >"$WARM_BIN/curl" <<EOF
#!/usr/bin/env bash
output=''
previous=''
for arg in "\$@"; do
  if [ "\$previous" = -o ]; then output=\$arg; fi
  previous=\$arg
done
printf '%s\n' '{"five_hour":{"utilization":10,"resets_at":"2026-07-13T01:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-07-19T01:00:00Z"},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":30,"resets_at":"2026-07-19T01:00:00Z"}]}' >"\$output"
printf '200'
EOF
chmod +x "$WARM_BIN/claude" "$WARM_BIN/security" "$WARM_BIN/curl"
WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm >/dev/null || fail "default warm fixture failed"
grep -q '^one|' "$WARM_SENTINEL" || fail "default warm omitted an enabled account"
grep -q '^two|' "$WARM_SENTINEL" && fail "default warm included a disabled account"
grep -q -- "-p /usage --output-format json" "$WARM_SENTINEL" || fail "warm did not use client-side /usage first"
grep -q -- "-p ok --model haiku" "$WARM_SENTINEL" && fail "successful /usage triggered the paid fallback"
: >"$WARM_SENTINEL"
WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm two >/dev/null || fail "explicit disabled warm fixture failed"
grep -q '^two|' "$WARM_SENTINEL" || fail "explicit warm did not include a disabled account"
: >"$WARM_SENTINEL"
# By default a failed /usage warm reports and stops; it must never spend on the paid probe.
WARM_FAIL_USAGE=1 WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm one >/dev/null 2>/dev/null && fail "failed /usage warm unexpectedly succeeded by default"
[ "$(wc -l <"$WARM_SENTINEL" | tr -d ' ')" -eq 1 ] || fail "default warm spent on the paid fallback"
sed -n '1p' "$WARM_SENTINEL" | grep -q -- '-p /usage --output-format json' || fail "default warm did not try /usage first"
grep -q -- '-p ok --model haiku' "$WARM_SENTINEL" && fail "default warm must not fire the paid fallback"
: >"$WARM_SENTINEL"
# The paid probe runs only behind the explicit opt-in no automated caller sets.
WARM_FAIL_USAGE=1 CLAUDEB_WARM_ALLOW_PAID=true WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm one >/dev/null || fail "opt-in warm paid-fallback fixture failed"
[ "$(wc -l <"$WARM_SENTINEL" | tr -d ' ')" -eq 2 ] || fail "opt-in failed /usage did not produce exactly one fallback"
sed -n '2p' "$WARM_SENTINEL" | grep -q -- '-p ok --model haiku --output-format json' || fail "opt-in failed /usage did not use the minimal paid fallback"
: >"$WARM_SENTINEL"
WARM_USAGE_429=1 WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm one >/dev/null 2>/dev/null && fail "rate-limited warm unexpectedly succeeded"
[ "$(wc -l <"$WARM_SENTINEL" | tr -d ' ')" -eq 1 ] || fail "rate-limited /usage retried through the paid fallback"

FAKE_BIN="$WORK/bin"
SENTINEL="$WORK/claudeb-called"
CODEX_SENTINEL="$WORK/codex-called"
CODEX_QUOTA_SENTINEL="$WORK/codex-quota-called"
CODEX_CACHE="$WORK/codex-quota.json"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/claudeb" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  echo "  claudeb --refresh [--no-spend] [--start-windows]"
  exit 0
fi
printf '%s\n' "$*" >>"$CLAUDEB_SENTINEL"
# A real free refresh restamps as_of; model it or the staleness check sees a stuck run.
if [ -n "${CLAUDEB_DIR:-}" ]; then
  for f in "$CLAUDEB_DIR"/limits/*.json; do [ -e "$f" ] && touch "$f"; done
fi
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >>"$CODEX_SENTINEL"\n' >"$FAKE_BIN/codex"
cat >"$WORK/fake-codex-quota" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$CODEX_QUOTA_SENTINEL"
printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":31,"windowDurationMins":300,"resetsAt":$((now + 4000))},"secondary":{"usedPercent":64,"windowDurationMins":10080,"resetsAt":$((now + 90000))},"planType":"plus"}}'
EOF
chmod +x "$FAKE_BIN/claudeb" "$FAKE_BIN/codex" "$WORK/fake-codex-quota"
GROK_FIXTURE="$ROOT/tests/fixtures/fake-grok-quota.sh"
GROK_CACHE="$WORK/grok-quota.json"

# --refresh is zero token spend: claudeb tier-1 snapshot, codex app-server usage query
# (never codex exec), and the live snapshot outranks the stale rollout tail.
refresh_out=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh) || fail "refresh collection failed"
[ -s "$SENTINEL" ] || fail "--refresh did not invoke claudeb accounts"
grep -q 'accounts --no-spend' "$SENTINEL" || fail "Claude refresh was not tier-1-only"
grep -qx -- '--all-accounts' "$CODEX_QUOTA_SENTINEL" \
  || fail "--refresh did not ask the codex quota helper to discover all accounts"
[ ! -e "$CODEX_SENTINEL" ] || fail "--refresh must be zero-spend but codex exec was invoked"
jq -e '.vendors.codex.five_hour.used_pct == 31 and .vendors.codex.weekly.used_pct == 64 and
  .vendors.codex.five_hour.origin == "usage" and .vendors.codex.source == "codex-app-server" and
  .vendors.codex.five_hour.stale == false and .vendors.codex.plan_type == "plus" and
  (.vendors.codex | has("refresh_error") | not)' <<<"$refresh_out" >/dev/null \
  || fail "live codex quota did not outrank stale rollouts"

cat >"$WORK/fake-codex-quota-weekly" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":$((now + 90000))},"secondary":null,"planType":"plus"}}'
EOF
chmod +x "$WORK/fake-codex-quota-weekly"
weekly_only=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota-weekly" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  bash "$SCRIPT" --refresh --no-write 2>/dev/null) || fail "weekly-only codex refresh failed"
jq -e '.vendors.codex.available == true and .vendors.codex.five_hour.used_pct == null and
  .vendors.codex.weekly.used_pct == 0 and .vendors.codex.source == "codex-app-server" and
  (.vendors.codex | has("refresh_error") | not)' <<<"$weekly_only" >/dev/null \
  || fail "weekly-only codex payload was not normalized as an available vendor"
weekly_only_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" bash "$SCRIPT" --table 2>/dev/null) || fail "weekly-only codex table failed"
weekly_only_table=$(strip_ansi <<<"$weekly_only_table")
awk '$1 == "codex" {print}' <<<"$weekly_only_table" | grep -Eq '^codex +- +0%' \
  || fail "weekly-only codex table did not render unknown 5h and weekly percentage"
codex_restored=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  bash "$SCRIPT" --refresh --no-write 2>/dev/null) || fail "codex fixture restore failed"
refresh_failed=$(CLAUDEB_SENTINEL="$SENTINEL" LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD=/usr/bin/false LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || fail "refresh with one vendor failure: expected partial exit 0, got $rc"
jq -e --arg asof "$(jq -r '.vendors.codex.as_of' <<<"$codex_restored")" \
  '.vendors.codex.refresh_error.cause == "live query failed" and
   (.vendors.codex.refresh_error.at | type) == "number" and
   .vendors.codex.five_hour.used_pct == 31 and .vendors.codex.as_of == $asof and
   (.refresh_error | not)' \
  <<<"$refresh_failed" >/dev/null || fail "Codex refresh failure was not machine-readable or stale data was lost"
rm -f "$SENTINEL" "$CODEX_QUOTA_SENTINEL"
cached_codex=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT") || fail "default gated collection failed"
[ ! -e "$SENTINEL" ] || fail "default collection invoked claudeb"
[ ! -e "$CODEX_SENTINEL" ] || fail "default collection invoked codex"
[ ! -e "$CODEX_QUOTA_SENTINEL" ] || fail "default collection invoked the codex quota helper"
jq -e '.vendors.codex.five_hour.used_pct == 31 and .vendors.codex.five_hour.origin == "usage"' <<<"$cached_codex" >/dev/null \
  || fail "passive run did not reuse the codex quota cache"
jq -e '.vendors.codex.refresh_error.cause == "live query failed"' <<<"$cached_codex" >/dev/null \
  || fail "passive run cleared a standing vendor refresh error"

all_failed=$(LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD=/usr/bin/false \
  LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" LLM_LIMITS_CODEX_REFRESH=1 \
  LLM_LIMITS_CODEX_QUOTA_CMD=/usr/bin/false LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  LLM_LIMITS_GROK_REFRESH=1 LLM_LIMITS_GROK_QUOTA=/usr/bin/false LLM_LIMITS_GROK_CACHE="$GROK_CACHE" \
  LLM_LIMITS_CLAUDEB_CMD=/usr/bin/false HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" \
  LLM_LIMITS_CACHE="$CACHE" /bin/bash "$SCRIPT" --refresh 2>/dev/null)
rc=$?
[ "$rc" -eq 4 ] || fail "all-vendor refresh failure: expected exit 4, got $rc"
jq -e '
  .refresh_error.cause == "all vendor refreshes failed" and
  all(.vendors | del(.opencode) | .[];
      (.refresh_error.cause | type) == "string" and (.refresh_error.at | type) == "number") and
  .vendors.codex.five_hour.used_pct == 31 and .vendors.gemini.five_hour.used_pct == 1' \
  <<<"$all_failed" >/dev/null || fail "all-vendor failure lost structured errors or old buckets"

restored_after_failure=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  GEMINI_SENTINEL="$GEMINI_SENTINEL" \
  LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$GEMINI_HELPER" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  LLM_LIMITS_GROK_REFRESH=1 LLM_LIMITS_GROK_QUOTA="$GROK_FIXTURE" LLM_LIMITS_GROK_CACHE="$GROK_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  /bin/bash "$SCRIPT" --refresh) || fail "successful refresh did not clear standing errors"
jq -e '(. | has("refresh_error") | not) and all(.vendors[]; has("refresh_error") | not)' \
  <<<"$restored_after_failure" >/dev/null || fail "successful vendor refresh did not clear standing errors"

CODEX_ACCOUNTS_HOME="$WORK/codex-accounts-home"
CODEX_ACCOUNTS_CACHE="$WORK/codex-accounts.json"
mkdir -p "$CODEX_ACCOUNTS_HOME/.codex-profiles/work3"
five_reset_epoch=$((now + 4000))
expired_reset_epoch=$((now - 60))
week_reset_epoch=$((now + 90000))
cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"accounts":[{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"alpha"}
EOF
CODEX_DISCOVERY_SENTINEL="$WORK/codex-discovery-called"
cat >"$WORK/fake-codex-discovery" <<EOF
#!/usr/bin/env bash
printf 'args=%s timeout=%s\n' "\$*" "\${CODEX_QUOTA_TIMEOUT-}" >"$CODEX_DISCOVERY_SENTINEL"
test -d "\$HOME/.codex-profiles/work3" || exit 90
printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":11,"windowDurationMins":300,"resetsAt":$five_reset_epoch},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":$week_reset_epoch},"planType":"plus"},"accounts":[{"account":"main","plan_type":"plus","five_hour":{"used_pct":11,"resets_at":$five_reset_epoch},"weekly":{"used_pct":12,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"work3","plan_type":"plus","five_hour":{"used_pct":3,"resets_at":$five_reset_epoch},"weekly":{"used_pct":4,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"main"}'
EOF
chmod +x "$WORK/fake-codex-discovery"
HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_REFRESH=1 \
  LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-discovery" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh --no-write >/dev/null \
  || fail "Codex discovery refresh failed"
grep -qx -- 'args=--all-accounts timeout=10' "$CODEX_DISCOVERY_SENTINEL" \
  || fail "Codex discovery refresh did not use --all-accounts"
jq -e '.current == "main" and ([.accounts[] | select(.account == "work3")] | length) == 1' \
  "$CODEX_ACCOUNTS_CACHE" >/dev/null \
  || fail "Codex discovery refresh did not add the disk profile or preserve all-account current semantics"

BOUND_HOME="$WORK/usage-bound-home"
BOUND_LOG="$WORK/usage-bound.log"
mkdir -p "$BOUND_HOME/.gemini-profiles/g1" "$BOUND_HOME/.codex-profiles/work3"
cat >"$WORK/fake-bound-helper" <<EOF
#!/usr/bin/env bash
printf 'agy=%s codex=%s\n' "\${AGY_QUOTA_TIMEOUT-}" "\${CODEX_QUOTA_TIMEOUT-}" >>"$BOUND_LOG"
exit 1
EOF
chmod +x "$WORK/fake-bound-helper"
usage_bound_seen() {
  : >"$BOUND_LOG"
  env -u AGY_QUOTA_TIMEOUT -u CODEX_QUOTA_TIMEOUT HOME="$BOUND_HOME" GEMINIB_SECURITY_CMD=/usr/bin/true \
    LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$WORK/fake-bound-helper" \
    LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$WORK/usage-bound-gemini" LLM_LIMITS_GEMINI_CACHE="$WORK/usage-bound-gemini.json" \
    LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-bound-helper" \
    LLM_LIMITS_CODEX_CACHE="$WORK/usage-bound-codex.json" LLM_LIMITS_CACHE="$CACHE" "$@" >/dev/null 2>&1 || true
  cat "$BOUND_LOG"
}
seen=$(usage_bound_seen bash "$SCRIPT" --refresh-account gemini/g1 --no-write)
[ "$seen" = 'agy=180 codex=' ] \
  || fail "Gemini per-account read must run under the 180 s usage-read bound, saw: $seen"
seen=$(usage_bound_seen bash "$SCRIPT" --refresh-account codex/work3 --no-write)
[ "$seen" = 'agy= codex=180' ] \
  || fail "Codex per-account read must run under the same usage-read bound, saw: $seen"
seen=$(usage_bound_seen env LLM_LIMITS_USAGE_READ_TIMEOUT=7 bash "$SCRIPT" --refresh-account gemini/g1 --no-write)
[ "$seen" = 'agy=7 codex=' ] || fail "LLM_LIMITS_USAGE_READ_TIMEOUT did not set the Gemini read bound, saw: $seen"

mkdir -p "$BOUND_HOME/.gemini-profiles/g2" "$BOUND_HOME/.gemini-profiles/g3" "$BOUND_HOME/.codex-profiles/work4"
cat >"$WORK/fake-list-helper" <<EOF
#!/usr/bin/env bash
printf 'home=%s args=%s\n' "\$(basename "\$HOME")" "\$*" >>"$BOUND_LOG"
exit 1
EOF
chmod +x "$WORK/fake-list-helper"
seen=$(usage_bound_seen env LLM_LIMITS_GEMINI_CMD="$WORK/fake-list-helper" \
  bash "$SCRIPT" --refresh-account gemini/g1,g3 --no-write | sort | paste -sd'|' -)
[ "$seen" = 'home=g1 args=|home=g3 args=' ] || fail "a Gemini account list must read exactly the listed accounts, saw: $seen"
seen=$(usage_bound_seen env LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-list-helper" \
  bash "$SCRIPT" --refresh-account codex/work3,work4 --no-write)
[ "$seen" = 'home=usage-bound-home args=--profile work3 --profile work4 --no-cache' ] \
  || fail "a Codex account list must be one helper call naming every account, saw: $seen"
list_rc=0
HOME="$BOUND_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh-account claude/a,b --no-write \
  >/dev/null 2>&1 || list_rc=$?
[ "$list_rc" -eq 2 ] || fail "a Claude account list must be refused (revive stays one account), got $list_rc"
CODEX_PARTIAL_HOME="$WORK/codex-partial-home"
CODEX_PARTIAL_CACHE="$WORK/codex-partial-cache.json"
mkdir -p "$CODEX_PARTIAL_HOME/.codex-profiles/a" "$CODEX_PARTIAL_HOME/.codex-profiles/b"
cat >"$CODEX_PARTIAL_CACHE" <<EOF
{"accounts":[{"account":"main","five_hour":{"used_pct":1,"resets_at":$five_reset_epoch},"weekly":{"used_pct":2,"resets_at":$week_reset_epoch},"as_of":$((now - 300))},{"account":"a","five_hour":{"used_pct":3,"resets_at":$five_reset_epoch},"weekly":{"used_pct":4,"resets_at":$week_reset_epoch},"as_of":$((now - 400))},{"account":"b","five_hour":{"used_pct":61,"resets_at":$five_reset_epoch},"weekly":{"used_pct":62,"resets_at":$week_reset_epoch},"as_of":$((now - 700))},{"account":"removed","five_hour":{"used_pct":81,"resets_at":$five_reset_epoch},"weekly":{"used_pct":82,"resets_at":$week_reset_epoch},"as_of":$((now - 800))}],"current":"main"}
EOF
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/codex-quota.py" "$CODEX_PARTIAL_HOME" "$CODEX_PARTIAL_CACHE" "$now" >"$WORK/codex-partial-result.json" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("codex_quota", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = Path(sys.argv[2])
old = json.loads(Path(sys.argv[3]).read_text())
now = int(sys.argv[4])
accounts = module.profile_accounts(home)
results = []
for account, _ in accounts:
    if account == "b":
        results.append((account, None, now, "codex app-server timed out"))
    else:
        results.append((account, {
            "rateLimits": {
                "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": now + 4000},
                "secondary": {"usedPercent": 20, "windowDurationMins": 10080, "resetsAt": now + 90000},
            }
        }, now, None))
print(json.dumps(module.cache_payload(results, old, True, "main")))
PY
jq -e --argjson old_as_of "$((now - 700))" '
  ([.accounts[] | select(.account == "b")][0] |
    .five_hour.used_pct == 61 and .weekly.used_pct == 62 and
    .as_of == $old_as_of and (has("error") | not)) and
  ([.accounts[] | select(.account == "removed")] | length) == 0
' "$WORK/codex-partial-result.json" >/dev/null \
  || fail "Codex all-account partial failure lost cached buckets or retained a removed profile"
cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"schema":1,"fetched_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","plan_type":"plus","five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"accounts":[{"account":"beta","plan_type":"team","reset_credits":0,"five_hour":{"used_pct":100,"resets_at":$expired_reset_epoch},"weekly":{"used_pct":100,"resets_at":$week_reset_epoch},"as_of":$((now - 22000))},{"account":"alpha","plan_type":"plus","reset_credits":2,"reset_credits_expires_at":"2099-09-21T00:16:44Z","five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$((now - 1900))}],"current":"alpha"}
EOF
codex_accounts_full=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex multi-account collection failed"
jq -e '.vendors.codex.current_account == "alpha" and (.vendors.codex.accounts | length) == 2 and
  .vendors.codex.accounts[0].is_current == true and
  .vendors.codex.accounts[0].reset_credits == 2 and
  .vendors.codex.accounts[0].reset_credits_stale == false and
  .vendors.codex.accounts[0].reset_credits_expires_at == "2099-09-21T00:16:44Z" and
  (.vendors.codex.accounts[1].reset_credits_expires_at | type) == "null" and
  (.vendors.codex.accounts[0].reset_credits_as_of | type) == "number" and
  .vendors.codex.accounts[0].five_hour.effective_pct == 100 and
  .vendors.codex.accounts[0].five_hour.stale == true and
  .vendors.codex.accounts[0].weekly.stale == false and
  .vendors.codex.accounts[1].five_hour.effective_pct == 0 and
  .vendors.codex.accounts[1].reset_credits == 0 and
  .vendors.codex.accounts[1].reset_credits_stale == true and
  .vendors.codex.accounts[1].five_hour.expired == true and
  (.vendors.codex.accounts[1].five_hour.resets_at | type) == "string" and
  .vendors.codex.accounts[1].weekly.effective_pct == 100 and
  .vendors.codex.accounts[1].weekly.stale == true and
  .vendors.codex.five_hour == .vendors.codex.accounts[0].five_hour and
  .vendors.codex.weekly == .vendors.codex.accounts[0].weekly and
  .vendors.codex.usable_now == false' <<<"$codex_accounts_full" >/dev/null \
  || fail "Codex multi-account normalization mismatch"
codex_accounts_table=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "Codex multi-account table failed"
[ "$(grep -c '^codex/' <<<"$codex_accounts_table")" -eq 2 ] || fail "Codex table did not render both accounts"
grep -q '^codex/alpha\*' <<<"$codex_accounts_table" || fail "Codex table current account marker missing"
grep -q '^codex/beta' <<<"$codex_accounts_table" || fail "Codex table secondary account missing"
awk '$1 == "codex/alpha*" {print $(NF-1)}' <<<"$codex_accounts_table" | grep -qx '↻2' \
  || fail "Codex reset credits missing from CR"
awk '$1 == "codex/beta" {print $(NF-1)}' <<<"$codex_accounts_table" | grep -qx '↻0' \
  || fail "zero Codex reset credits missing from CR"
grep -q 'plus\|team' <<<"$codex_accounts_table" && fail "Codex plan tag leaked into table"
codex_accounts_plain=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "Codex multi-account plain failed"
grep 'codex/alpha\*:' <<<"$codex_accounts_plain" | grep -q '| cr ↻2 |' || fail "plain Codex credits missing"
grep 'codex/beta:' <<<"$codex_accounts_plain" | grep -q '| cr ↻0 |' || fail "plain zero Codex credits missing"
CODEX_NULL_CACHE="$WORK/codex-null-window.json"
cat >"$CODEX_NULL_CACHE" <<EOF
{"accounts":[{"account":"main","reset_credits":1,"five_hour":{"used_pct":null,"resets_at":$five_reset_epoch,"as_of":$((now - 20000))},"weekly":{"used_pct":33,"resets_at":$week_reset_epoch,"as_of":$((now - 600))},"as_of":$((now - 100))}],"current":"main"}
EOF
codex_null=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_NULL_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex null-window collection failed"
jq -e --argjson data_as_of "$((now - 600))" --argjson credits_as_of "$((now - 100))" '
  .vendors.codex.accounts[0] as $a |
  $a.five_hour.used_pct == null and $a.five_hour.as_of < $data_as_of and
  ($a.as_of | fromdateiso8601) == $data_as_of and
  (.vendors.codex.as_of | fromdateiso8601) == $data_as_of and
  $a.reset_credits_as_of == $credits_as_of and $a.reset_credits_stale == false' \
  <<<"$codex_null" >/dev/null || fail "null Codex window affected data age or reset-credit freshness"
codex_null_table=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_NULL_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "Codex null-window table failed"
codex_null_age=$(awk '$1 == "codex" {print $(NF-3)}' <<<"$codex_null_table")
codex_null_minutes=${codex_null_age%m}
codex_null_expected=$(( ($(date +%s) - (now - 600)) / 60 ))
[[ "$codex_null_minutes" =~ ^[0-9]+$ ]] &&
  [ "$codex_null_minutes" -ge "$((codex_null_expected - 1))" ] &&
  [ "$codex_null_minutes" -le "$codex_null_expected" ] \
  || fail "Codex AGE included a null window: $codex_null_table"
# `codexb remove main` writes its marker beside main's legacy cache file — the one path the
# menubar's `--codex-remove` writes too. main is the real ~/.codex and mirrors whatever account the
# Codex app is signed into, so its removal is permanent: it leaves the store entirely — no row at
# all, not even a removed one — and the first NAMED account carries the vendor from then on.
CODEX_NO_MAIN_CACHE="$WORK/codex-no-main.json"
CODEX_NO_MAIN_MARKER="$CODEX_NO_MAIN_CACHE.removed"
CODEX_NO_MAIN_STORE="$WORK/codex-no-main-store.json"
CODEX_NO_MAIN_HOME="$WORK/codex-no-main-home"
mkdir -p "$CODEX_NO_MAIN_HOME"
cat >"$CODEX_NO_MAIN_CACHE" <<EOF
{"accounts":[{"account":"main","plan_type":"plus","five_hour":{"used_pct":71,"resets_at":$five_reset_epoch},"weekly":{"used_pct":72,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"com","plan_type":"plus","five_hour":{"used_pct":11,"resets_at":$five_reset_epoch},"weekly":{"used_pct":12,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"work3","plan_type":"plus","five_hour":{"used_pct":31,"resets_at":$five_reset_epoch},"weekly":{"used_pct":32,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"main"}
EOF
codex_no_main() {
  HOME="$CODEX_NO_MAIN_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_NO_MAIN_CACHE" \
    LLM_LIMITS_CACHE="$CODEX_NO_MAIN_STORE" bash "$SCRIPT" "$@"
}
codex_with_main=$(codex_no_main --json) || fail "Codex roster with main failed"
jq -e '.vendors.codex.current_account == "main" and
  ([.vendors.codex.accounts[] | select(.account == "main")] | length) == 1' \
  <<<"$codex_with_main" >/dev/null || fail "the codex no-main fixture never had main to remove"
# The path codexb itself would write, resolved by the module both tools source — a marker spelled
# anywhere else is one codexb writes and llm-limits.sh never sees.
codex_no_main_marker_shared=$(LLM_LIMITS_CODEX_CACHE="$CODEX_NO_MAIN_CACHE" \
  /bin/bash -c '. "'"$ROOT"'/share/codex-accounts.sh" && codex_removal_marker main')
[ "$codex_no_main_marker_shared" = "$CODEX_NO_MAIN_MARKER" ] \
  || fail "the shared resolver names $codex_no_main_marker_shared, the collector reads $CODEX_NO_MAIN_MARKER"
codex_removed=$(codex_no_main --codex-remove --json) || fail "--codex-remove failed"
jq -e '.vendors.codex.available == true and .vendors.codex.current_account == "com" and
  ([.vendors.codex.accounts[] | select(.account == "main")] | length) == 0 and
  .vendors.codex.accounts[0].account == "com" and .vendors.codex.accounts[0].is_current == true and
  .vendors.codex.accounts[1].account == "work3" and .vendors.codex.accounts[1].is_current == false and
  .vendors.codex.five_hour.used_pct == 11 and .vendors.codex.weekly.used_pct == 12' \
  <<<"$codex_removed" >/dev/null \
  || fail "codex-remove did not take main out of its own run or hoist the first named account"
[ -e "$CODEX_NO_MAIN_MARKER" ] || fail "codex-remove did not persist the removed marker"
codex_still=$(codex_no_main --json) || fail "passive collect after codex-remove failed"
jq -e '([.vendors.codex.accounts[]? | select(.account == "main")] | length) == 0 and
  .vendors.codex.current_account == "com"' <<<"$codex_still" >/dev/null \
  || fail "removed codex main came back on a passive collect"
[ -e "$CODEX_NO_MAIN_MARKER" ] || fail "a passive collect cleared the codex main removal marker"
codex_no_main_table=$(codex_no_main --table) || fail "codex no-main table failed"
grep -q '^codex/main' <<<"$codex_no_main_table" && fail "removed Codex main still rendered a table row"
grep -q '^codex/com\*' <<<"$codex_no_main_table" || fail "Codex current account lost its table mark"
grep -q '^codex/work3 ' <<<"$codex_no_main_table" || fail "remaining Codex account missing from the table"
codex_no_main_plain=$(codex_no_main --plain) || fail "codex no-main plain failed"
grep -q '^codex/main' <<<"$codex_no_main_plain" && fail "removed Codex main still rendered a plain row"
grep -q '^codex/com\*:' <<<"$codex_no_main_plain" || fail "Codex current account lost its plain mark"
# Deleting the marker is the whole undo.
rm -f "$CODEX_NO_MAIN_MARKER"
codex_back=$(codex_no_main --json) || fail "codex collect after deleting the marker failed"
jq -e '.vendors.codex.current_account == "main" and
  ([.vendors.codex.accounts[] | select(.account == "main")] | length) == 1' \
  <<<"$codex_back" >/dev/null || fail "deleting the marker did not bring codex main back"
# main removed with no named profile beside it: the vendor states its REMOVAL rather than a missing
# snapshot, which is what makes the menubar drop the section instead of rendering "no live data".
CODEX_ONLY_MAIN_CACHE="$WORK/codex-only-main.json"
cat >"$CODEX_ONLY_MAIN_CACHE" <<EOF
{"accounts":[{"account":"main","plan_type":"plus","five_hour":{"used_pct":71,"resets_at":$five_reset_epoch},"weekly":{"used_pct":72,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"main"}
EOF
codex_empty=$(HOME="$CODEX_NO_MAIN_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ONLY_MAIN_CACHE" \
  LLM_LIMITS_CACHE="$WORK/codex-only-main-store.json" bash "$SCRIPT" --codex-remove --json) || true
jq -e '.vendors.codex.available == false and .vendors.codex.removed == true and
  (.vendors.codex.accounts | type) != "array" and
  (.vendors.codex | has("refresh_error") | not)' <<<"$codex_empty" >/dev/null \
  || fail "codex with main removed and no named profile did not state its removal"
[ -e "$CODEX_ONLY_MAIN_CACHE.removed" ] || fail "codex-remove left no marker on the empty roster"

CODEX_TARGET_SENTINEL="$WORK/codex-target-called"
cat >"$WORK/fake-codex-target" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$CODEX_TARGET_SENTINEL"
printf '%s\n' '{"accounts":[{"account":"beta","plan_type":"team","five_hour":{"used_pct":22,"resets_at":$five_reset_epoch},"weekly":{"used_pct":33,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$((now - 1900))}],"current":"beta"}'
EOF
chmod +x "$WORK/fake-codex-target"
codex_targeted=$(CODEX_TARGET_SENTINEL="$CODEX_TARGET_SENTINEL" HOME="$CODEX_ACCOUNTS_HOME" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-target" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh-account codex/beta) \
  || fail "Codex targeted account refresh failed"
grep -qx -- '--profile beta --no-cache' "$CODEX_TARGET_SENTINEL" \
  || fail "Codex targeted refresh did not use the existing single-profile RPC"
jq -e --argjson now "$now" '.vendors.codex.current_account == "alpha" and
  ([.vendors.codex.accounts[] | select(.account == "beta")][0] |
    .as_of == ($now | todateiso8601) and .five_hour.used_pct == 22)' \
  <<<"$codex_targeted" >/dev/null || fail "Codex targeted refresh changed current account or failed to advance only real target data"
jq '(.accounts[] | select(.account == "beta") | .five_hour.used_pct) = 25 |
    (.accounts[] | select(.account == "beta") | .weekly.used_pct) = 30' \
  "$CODEX_ACCOUNTS_CACHE" >"$CODEX_ACCOUNTS_CACHE.tmp"
mv "$CODEX_ACCOUNTS_CACHE.tmp" "$CODEX_ACCOUNTS_CACHE"
codex_accounts_free=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex free-account collection failed"
jq -e '.vendors.codex.usable_now == true and .vendors.codex.five_hour.effective_pct == 100' \
  <<<"$codex_accounts_free" >/dev/null || fail "Codex one-free-account usability mismatch"

cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"accounts":[{"account":"work","auth_needed":true,"as_of":$now,"error":"codex account authentication required to read rate limits"}],"current":"work"}
EOF
codex_auth_needed=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex auth-needed collection failed"
jq -e '.vendors.codex.available == true and .vendors.codex.current_account == "work" and
  .vendors.codex.usable_now == false and (.vendors.codex.accounts | length) == 1 and
  .vendors.codex.accounts[0].account == "work" and .vendors.codex.accounts[0].auth_needed == true and
  (.vendors.codex.accounts[0] | has("five_hour") or has("weekly") or has("as_of") or has("stale_seconds") | not)' \
  <<<"$codex_auth_needed" >/dev/null || fail "Codex auth-needed account normalization mismatch"
codex_auth_table=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "Codex auth-needed table failed"
codex_auth_table=$(strip_ansi <<<"$codex_auth_table")
codex_auth_plain=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "Codex auth-needed plain failed"
grep -Eq '^codex/work\* +- +- +- +- +- +- +never +- +- +login needed$' <<<"$codex_auth_table" \
  || fail "Codex auth-needed table status missing: $codex_auth_table"
grep -q '^codex/work\*: .* | status login needed$' <<<"$codex_auth_plain" \
  || fail "Codex auth-needed plain status missing: $codex_auth_plain"

# --refresh-account with an invalidated token: the helper reports auth (rc 2) with a SHORT
# cause and no raw RPC blob; llm-limits.sh must persist the per-account auth-needed marker,
# render login-needed, preserve the current account, and keep the raw 401 text out of every
# user-visible cause.
cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"schema":1,"fetched_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","accounts":[{"account":"beta","plan_type":"team","five_hour":{"used_pct":22,"resets_at":$five_reset_epoch},"weekly":{"used_pct":33,"resets_at":$week_reset_epoch},"as_of":$now},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"alpha"}
EOF
cat >"$WORK/fake-codex-auth" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"error":"rateLimits/read failed: 401 Unauthorized; token_invalidated","source":"codex-app-server","account":"beta"}' >&2
printf '%s\n' '{"auth_needed":true,"cause":"login needed: token invalidated","accounts":[{"account":"beta","auth_needed":true,"as_of":$now,"cause":"login needed: token invalidated"},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$now}],"current":"beta"}'
exit 2
EOF
chmod +x "$WORK/fake-codex-auth"
CODEX_AUTH_LOG="$WORK/codex-auth.log"
codex_target_auth=$(HOME="$CODEX_ACCOUNTS_HOME" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-auth" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh-account codex/beta 2>"$CODEX_AUTH_LOG") \
  || fail "Codex targeted auth refresh failed"
# The raw RPC error survives in the log (HTTP/RPC context) even though the cache/UI keep only
# the short cause.
grep -q 'token_invalidated' "$CODEX_AUTH_LOG" \
  || fail "targeted auth refresh dropped the raw RPC error from the log: $(cat "$CODEX_AUTH_LOG")"
grep -q 'login needed: token invalidated' "$CODEX_AUTH_LOG" \
  || fail "targeted auth refresh did not log the short cause"
jq -e '.current == "alpha" and ([.accounts[] | select(.account == "beta")][0] |
  .auth_needed == true and .cause == "login needed: token invalidated" and (has("error") | not))' \
  "$CODEX_ACCOUNTS_CACHE" >/dev/null \
  || fail "targeted auth refresh did not persist the codex auth marker or leaked a raw error"
jq -e '.vendors.codex.available == true and .vendors.codex.current_account == "alpha" and
  ([.vendors.codex.accounts[] | select(.account == "beta")][0] |
    .auth_needed == true and .status == "login needed" and
    .cause == "login needed: token invalidated" and .needs_user_entry == true) and
  (.vendors.codex | has("refresh_error") | not)' <<<"$codex_target_auth" >/dev/null \
  || fail "targeted auth refresh did not surface login-needed without a vendor error"
[ -z "$(jq -r '.. | strings | select(test("token_invalidated|Unauthorized|rateLimits/read"))' <<<"$codex_target_auth")" ] \
  || fail "raw RPC blob leaked into the unified codex cache"

CODEX_LEGACY_CACHE="$WORK/codex-legacy.json"
cat >"$CODEX_LEGACY_CACHE" <<EOF
{"schema":1,"fetched_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","plan_type":"plus","five_hour":{"used_pct":31,"resets_at":$five_reset_epoch},"weekly":{"used_pct":64,"resets_at":$week_reset_epoch}}
EOF
codex_legacy=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_LEGACY_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex legacy cache collection failed"
jq -e '.vendors.codex.available == true and .vendors.codex.source == "codex-app-server" and
  .vendors.codex.plan_type == "plus" and .vendors.codex.current_account == "main" and
  .vendors.codex.five_hour.used_pct == 31 and .vendors.codex.weekly.used_pct == 64 and
  (.vendors.codex.accounts | length) == 1 and .vendors.codex.accounts[0].account == "main" and
  .vendors.codex.accounts[0].is_current == true and
  (.vendors.codex.accounts[0] | has("reset_credits") | not) and
  .vendors.codex.five_hour == .vendors.codex.accounts[0].five_hour and
  .vendors.codex.weekly == .vendors.codex.accounts[0].weekly' <<<"$codex_legacy" >/dev/null \
  || fail "Codex legacy cache compatibility mismatch"
# Rollout events newer than the cached RPC snapshot must win (fixture rollout is 2026-07-11T10:00Z).
touch -t 202607110500 "$CODEX_CACHE"
rollout_wins=$(LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT") || fail "rollout-preference collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 74 and .vendors.codex.five_hour.origin == "usage" and .vendors.codex.source == "session-rollout"' <<<"$rollout_wins" >/dev/null \
  || fail "newer rollout event did not outrank an older quota cache"
rm -f "$CODEX_CACHE"

# A newer rollout describes the MAIN codex home only: it overlays main's numbers and must
# never collapse the multi-account roster the cache owns (the other profiles keep their own
# as_of so the heartbeat can still see them go stale).
ROSTER_CACHE="$WORK/codex-roster.json"
roster_asof=$((now - 100))
cat >"$ROSTER_CACHE" <<EOF
{"schema":1,"accounts":[{"account":"main","plan_type":"plus","five_hour":{"used_pct":10,"resets_at":$five_reset_epoch},"weekly":{"used_pct":11,"resets_at":$week_reset_epoch},"as_of":$roster_asof},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":20,"resets_at":$five_reset_epoch},"weekly":{"used_pct":21,"resets_at":$week_reset_epoch},"as_of":$roster_asof},{"account":"beta","plan_type":"team","five_hour":{"used_pct":30,"resets_at":$five_reset_epoch},"weekly":{"used_pct":31,"resets_at":$week_reset_epoch},"as_of":$roster_asof},{"account":"gamma","plan_type":"plus","five_hour":{"used_pct":40,"resets_at":$five_reset_epoch},"weekly":{"used_pct":41,"resets_at":$week_reset_epoch},"as_of":$roster_asof}],"current":"main"}
EOF
touch -t 202607110500 "$ROSTER_CACHE"
roster_wins=$(LLM_LIMITS_CODEX_CACHE="$ROSTER_CACHE" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" \
  LLM_LIMITS_CACHE="$WORK/roster-store.json" bash "$SCRIPT" --no-write) || fail "rollout-over-roster collection failed"
jq -e --argjson asof "$roster_asof" '
  .vendors.codex.source == "session-rollout" and .vendors.codex.current_account == "main" and
  (.vendors.codex.accounts | length) == 4 and
  ([.vendors.codex.accounts[].account] == ["main","alpha","beta","gamma"]) and
  ([.vendors.codex.accounts[] | select(.account == "main")][0] |
    .five_hour.used_pct == 74 and .weekly.used_pct == 31 and
    .five_hour.origin == "usage" and .weekly.origin == "usage") and
  .vendors.codex.five_hour.used_pct == 74 and
  ([.vendors.codex.accounts[] | select(.account != "main")] |
    ([.[].five_hour.used_pct] == [20,30,40]) and ([.[].weekly.used_pct] == [21,31,41]) and
    all(.[]; .five_hour.as_of == $asof and .weekly.as_of == $asof and
              .five_hour.origin == "usage" and .plan_type != null))' \
  <<<"$roster_wins" >/dev/null \
  || fail "a newer rollout replaced the cached codex roster instead of overlaying main"
roster_table=$(LLM_LIMITS_CODEX_CACHE="$ROSTER_CACHE" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" \
  LLM_LIMITS_CACHE="$WORK/roster-store.json" bash "$SCRIPT" --table --no-write 2>/dev/null) || fail "rollout-over-roster table failed"
for account in main alpha beta gamma; do
  grep -Eq "^codex/$account\*? " <<<"$roster_table" \
    || fail "table lost the codex/$account row under a newer rollout: $roster_table"
done
rm -f "$ROSTER_CACHE"

HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --start-windows >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "--start-windows without --refresh: expected exit 2, got $rc"

# --refresh --start-windows with a fresh codex 5h window: claudeb gets the window-start
# request (its help advertises the flag) and codex exec stays untouched.
rm -f "$SENTINEL" "$CODEX_SENTINEL" "$CODEX_QUOTA_SENTINEL"
CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows >/dev/null 2>"$WORK/start-fresh.err" || fail "start-windows (fresh) collection failed"
grep -qx -- '--refresh --start-windows --heal' "$SENTINEL" || fail "claudeb window start was not requested"
[ ! -e "$CODEX_SENTINEL" ] || fail "fresh codex window must not trigger a spend"
grep -q 'gemini window start skipped' "$WORK/start-fresh.err" || fail "disabled gemini start must be reported, not silent"

# Expired codex 5h window: one micro-spend via codex exec, then the quota is re-read.
cat >"$WORK/fake-codex-quota-expired" <<EOF
#!/usr/bin/env bash
printf 'called\n' >>"\$CODEX_QUOTA_SENTINEL"
if [ -e "\$CODEX_QUOTA_STATE" ]; then
  printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":12,"resetsAt":$((now + 4000))},"secondary":{"usedPercent":34,"resetsAt":$((now + 90000))},"planType":"plus"}}'
else
  : >"\$CODEX_QUOTA_STATE"
  printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":99,"resetsAt":$((now - 60))},"secondary":{"usedPercent":34,"resetsAt":$((now + 90000))},"planType":"plus"}}'
fi
EOF
chmod +x "$WORK/fake-codex-quota-expired"
rm -f "$SENTINEL" "$CODEX_SENTINEL" "$CODEX_QUOTA_SENTINEL" "$CODEX_CACHE"
spend_out=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  CODEX_QUOTA_STATE="$WORK/codex-quota-state" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota-expired" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  LLM_LIMITS_CODEX_MODEL="fixture model" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows 2>/dev/null) || fail "start-windows (expired) collection failed"
[ -s "$CODEX_SENTINEL" ] || fail "expired codex window did not trigger the window-start spend"
grep -qx -- '--sandbox' "$CODEX_SENTINEL" && grep -qx 'read-only' "$CODEX_SENTINEL" || fail "codex window start did not use the read-only sandbox"
grep -qx 'model_reasoning_effort="low"' "$CODEX_SENTINEL" || fail "codex window start did not request low reasoning effort"
grep -qx -- '-m' "$CODEX_SENTINEL" || fail "codex model override flag was not passed"
grep -qx 'fixture model' "$CODEX_SENTINEL" || fail "codex model override was not passed as one argument"
[ "$(wc -l <"$CODEX_QUOTA_SENTINEL" | tr -d ' ')" -eq 2 ] || fail "codex quota was not re-read after the window start"
jq -e '.vendors.codex.five_hour.used_pct == 12' <<<"$spend_out" >/dev/null || fail "post-spend codex snapshot was not picked up"
rm -f "$CODEX_CACHE" "$WORK/codex-quota-state"

# claudeb builds that predate --start-windows: explicit notice, free refresh fallback.
FAKE_BIN_OLD="$WORK/bin-old"
mkdir -p "$FAKE_BIN_OLD"
cat >"$FAKE_BIN_OLD/claudeb" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  echo "  claudeb --refresh [--no-spend]"
  exit 0
fi
printf '%s\n' "$*" >>"$CLAUDEB_SENTINEL"
EOF
cp "$FAKE_BIN/codex" "$FAKE_BIN_OLD/codex"
chmod +x "$FAKE_BIN_OLD/claudeb" "$FAKE_BIN_OLD/codex"
rm -f "$SENTINEL" "$CODEX_SENTINEL" "$CODEX_QUOTA_SENTINEL"
CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN_OLD:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows >/dev/null 2>"$WORK/start-old.err" || fail "start-windows (old claudeb) collection failed"
grep -q 'claudeb lacks --start-windows' "$WORK/start-old.err" || fail "unsupported claudeb flag was skipped silently"
grep -q 'accounts --no-spend' "$SENTINEL" || fail "old claudeb did not fall back to the free refresh"
grep -q -- '--refresh --start-windows' "$SENTINEL" && fail "unsupported flag was passed to old claudeb"
rm -f "$SENTINEL" "$CODEX_SENTINEL" "$CODEX_QUOTA_SENTINEL" "$CODEX_CACHE"

# Undeterminable codex freshness (fresh event, null resets_at) must neither crash the run
# under set -u nor trigger the window-start spend; the unknown state must be reported.
NULLRESET_HOME="$WORK/nullreset-codex-home"
mkdir -p "$NULLRESET_HOME/.codex/sessions"
printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":41,"resets_at":null},"secondary":{"used_percent":22,"resets_at":null}}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$NULLRESET_HOME/.codex/sessions/rollout-nullreset.jsonl"
CODEX_SENTINEL="$CODEX_SENTINEL" LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/nonexistent-quota" \
  PATH="$FAKE_BIN:$PATH" HOME="$NULLRESET_HOME" CLAUDEB_DIR="$WORK/no-claudeb-store" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows >/dev/null 2>"$WORK/null.err"
rc=$?
# The run must not crash (e.g. an unset-variable abort), but a genuinely missing codex
# quota helper is a real refresh error and must exit non-zero, never a silent/clean 0.
[ "$rc" -eq 4 ] || fail "null resets_at refresh: expected exit 4 (codex refresh_error), got $rc"
[ ! -e "$CODEX_SENTINEL" ] || fail "unknown codex window state triggered a spend"
grep -q 'codex 5h window state unknown' "$WORK/null.err" || fail "unknown codex window state was skipped silently"
null_reset=$(HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "null resets_at collection failed"
jq -e '.vendors.codex.available == true and .vendors.codex.five_hour.used_pct == 41 and .vendors.codex.five_hour.resets_at == null' <<<"$null_reset" >/dev/null || fail "null resets_at not normalized"
HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain | grep -q 'codex: 5h 41% @ - | wk 22% @ -' || fail "null resets_at plain render failed"
HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table | grep -q '^codex' || fail "null resets_at table render failed"

PLACEHOLDER_HOME="$WORK/placeholder-home"
PLACEHOLDER_STORE="$WORK/placeholder-store"
mkdir -p "$PLACEHOLDER_HOME" "$PLACEHOLDER_STORE/limits"
printf 'zero\n' >"$PLACEHOLDER_STORE/.claudeb-state"
printf '%s\n' '{"five_hour":{"used_percentage":10,"resets_at":0}}' >"$PLACEHOLDER_STORE/limits/zero.json"
printf '%s\n' '{"five_hour":{"used_percentage":20,"resets_at":12345}}' >"$PLACEHOLDER_STORE/limits/epoch-1970.json"
printf '%s\n' '{"five_hour":{"used_percentage":30,"resets_at":""}}' >"$PLACEHOLDER_STORE/limits/empty.json"
printf '{"five_hour":{"used_percentage":40,"resets_at":%s}}\n' "$((now - 1800))" >"$PLACEHOLDER_STORE/limits/recent-past.json"
placeholder_json=$(HOME="$PLACEHOLDER_HOME" CLAUDEB_DIR="$PLACEHOLDER_STORE" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --json) || fail "placeholder reset collection failed"
jq -e 'all(.vendors.claude.accounts[] | select(.account == "zero" or .account == "epoch-1970" or .account == "empty");
    .five_hour.resets_at == null) and
  ([.vendors.claude.accounts[] | select(.account == "recent-past")][0].five_hour |
    (.resets_at | type) == "string" and .expired == true)' <<<"$placeholder_json" >/dev/null \
  || fail "placeholder or real past resets_at normalization mismatch"

# Gemini window start: an expired 5h bucket in the refreshed quota triggers one bounded
# agy --print call, then the quota helper runs again.
GEMINI_START_SENTINEL="$WORK/agy-called"
GEMINI_STATE="$WORK/gemini-quota-state"
GEMINI_CACHE2="$WORK/gemini-start.json"
FAKE_AGY="$WORK/fake-agy"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" "OPEN=$(command -v open)" >>"$GEMINI_START_SENTINEL"\n' >"$FAKE_AGY"
cat >"$WORK/fake-gemini-quota" <<EOF
#!/usr/bin/env bash
printf 'called\n' >>"\$GEMINI_SENTINEL"
if [ -e "\$GEMINI_STATE" ]; then
  printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.6,"resetTime":"$(date -u -r $((now + 500000)) '+%Y-%m-%dT%H:%M:%SZ')"},{"window":"5h","remainingFraction":0.9,"resetTime":"$(date -u -r $((now + 7200)) '+%Y-%m-%dT%H:%M:%SZ')"}]}]}'
else
  : >"\$GEMINI_STATE"
  printf '%s\n' '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.75,"resetTime":"$(date -u -r $((now + 500000)) '+%Y-%m-%dT%H:%M:%SZ')"},{"window":"5h","remainingFraction":0.995,"resetTime":"2026-07-11T00:00:00Z"}]}]}'
fi
EOF
chmod +x "$FAKE_AGY" "$WORK/fake-gemini-quota"
rm -f "$GEMINI_SENTINEL"
gemini_start=$(GEMINI_SENTINEL="$GEMINI_SENTINEL" GEMINI_STATE="$GEMINI_STATE" GEMINI_START_SENTINEL="$GEMINI_START_SENTINEL" \
  CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" \
  LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$WORK/fake-gemini-quota" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE2" \
  AGY_BIN="$FAKE_AGY" AGY_WORKDIR="$WORK" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows 2>/dev/null) || fail "gemini start-windows collection failed"
grep -q -- '--print' "$GEMINI_START_SENTINEL" || fail "expired gemini window did not trigger agy --print"
grep -qxF "OPEN=$ROOT/share/no-browser/open" "$GEMINI_START_SENTINEL" || fail "gemini window start ran agy with a real open on PATH"
[ "$(grep -c called "$GEMINI_SENTINEL")" -eq 2 ] || fail "gemini quota was not re-read after the window start"
jq -e '.vendors.gemini.weekly.used_pct == 40' <<<"$gemini_start" >/dev/null || fail "post-start gemini snapshot was not picked up"
rm -f "$GEMINI_SENTINEL" "$GEMINI_START_SENTINEL" "$GEMINI_STATE" "$GEMINI_CACHE2"

table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "table collection failed"
grep -q $'\x1b' <<<"$table" && fail "piped table output contains ANSI escapes"
head -n 1 <<<"$table" | grep -q '^SOURCE ' || fail "table header missing"
grep -q '^claude/main' <<<"$table" && fail "main account must be hidden from the table"
[ "$(grep -c '^claude/' <<<"$table")" -eq 1 ] || fail "table must render one row per non-main claude account"
order=$(awk 'NR > 1 {print $1}' <<<"$table" | paste -sd, -)
[ "$order" = "claude/alona*,codex,gemini,grok" ] || fail "default table order mismatch: $order"
head -n 1 <<<"$table" | grep -q 'FB%' || fail "Fable percentage column missing from table"
head -n 1 <<<"$table" | grep -q 'FB RESET' || fail "Fable reset column missing from table"
head -n 1 <<<"$table" | grep -q 'NOTE' && fail "NOTE column still present"
awk '$1 == "claude/alona*" {print $4}' <<<"$table" | grep -qx '33%' || fail "Fable percentage cell missing"
awk '$1 == "codex" {print $4}' <<<"$table" | grep -qx '-' || fail "non-Fable row must render a dash"
grep -q 'Gemini Models\|plus' <<<"$table" && fail "junk labels leaked into table"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now - 1))" >"$CLAUDEB/limits/alona.json"
expired_fable=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "expired fable table failed"
# Canonical expired cell (shared-invariants row y): effective value 0 plus the
# expired marker — the same number the menu grays out, never yesterday's raw pct.
awk '$1 == "claude/alona*" {print $4}' <<<"$expired_fable" | grep -qx '0%!' \
  || fail "expired fable must render effective 0 with the expired marker"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s},"fable":{"used_percentage":33,"resets_at":%s}}\n' "$((now + 5000))" "$((now + 5500))" >"$CLAUDEB/limits/alona.json"
awk 'NR > 1 && $1 == "codex"' <<<"$table" | grep -Eq '[0-9]{2}:[0-9]{2}' || fail "codex reset time not rendered"
sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort 5h) || fail "sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$sorted" | paste -sd, -)
[ "$order" = "codex,claude/alona*,gemini,grok" ] || fail "--sort 5h order mismatch: $order"
echo "PASS: claudeb OAuth heal and warm fallbacks, Codex multi-account refresh and roster, reset placeholders, table output"
