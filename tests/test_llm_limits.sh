#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/llm-limits.sh"
WORK="$(mktemp -d)"
daemon_pid=''
cleanup() {
  [ -z "$daemon_pid" ] || kill "$daemon_pid" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Unit fixtures must never discover and launch the developer's real agy binary.
export LLM_LIMITS_GEMINI_REFRESH=0
export LLM_LIMITS_CODEX_REFRESH=0
export CLAUDEBD_PORT=1

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
jq -e '.vendors.codex.five_hour.used_pct == 74 and .vendors.codex.weekly.used_pct == 31 and
  .vendors.codex.plan_type == "plus" and .vendors.codex.current_account == "main" and
  (.vendors.codex.accounts | length) == 1 and .vendors.codex.accounts[0].account == "main"' \
  <<<"$out" >/dev/null || fail "Codex fallback mismatch"
jq -e '.vendors.claude.five_hour.effective_pct == .vendors.claude.five_hour.used_pct and
  .vendors.claude.accounts[0].weekly.effective_pct == .vendors.claude.accounts[0].weekly.used_pct and
  .vendors.codex.five_hour.effective_pct == .vendors.codex.five_hour.used_pct and
  .vendors.claude.usable_now == true and .vendors.codex.usable_now == true and
  .vendors.gemini.usable_now == false' <<<"$out" >/dev/null || fail "live effective percentages or usable state mismatch"
jq -e '(.vendors.claude.five_hour.as_of | type) == "number" and .vendors.claude.five_hour.stale == false and .vendors.claude.stale == false' <<<"$out" >/dev/null || fail "Claude bucket freshness fields missing"
jq -e '.vendors.codex.five_hour.origin == "headers" and (.vendors.codex.five_hour.as_of | type) == "number" and .vendors.codex.five_hour.stale == true and .vendors.codex.stale == true' <<<"$out" >/dev/null || fail "Codex rollout freshness fields mismatch"
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
  .vendors.gemini.five_hour.used_pct == 1 and
  .vendors.gemini.weekly.used_pct == 25 and
  .vendors.gemini.five_hour.resets_at == "2026-07-11T22:00:00Z"' <<<"$gemini_live" >/dev/null \
  || fail "Gemini quota normalization mismatch (used_pct must be an integer)"
jq -e '.vendors.gemini.five_hour.origin == "usage" and .vendors.gemini.five_hour.stale == false and
  (.vendors.gemini.five_hour.as_of | type) == "number" and .vendors.gemini.stale == false and
  (.vendors.gemini | has("refresh_error") | not)' <<<"$gemini_live" >/dev/null \
  || fail "Gemini freshness fields mismatch"
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
grep 'codex: 74%/31%' <<<"$plain" | grep -q '(stale ' || fail "plain stale-age suffix missing or not in English"
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

DAEMON_PORT_FILE="$WORK/claudebd-fixture.port"
cat >"$WORK/claudebd-fixture.py" <<'EOF'
import http.server
import json
import os

payload = {
    "pid": 123,
    "uptime_s": 60,
    "port": 45789,
    "current": "alona",
    "current_fable": "alona",
    "accounts": {
        "alona": {"h5": 50, "wk": 10, "hreset": 4102444800, "wreset": 4102440000,
                  "walled": True, "auth_failed_until": 0, "fable_walled_until": 0},
    },
    "scopes": {"general": None, "fable": "alona"},
    "walls": [
        {"account": "alona", "scope": "general", "until": "2100-01-01T01:00:00.000Z",
         "reason": "transient"},
    ],
    "pins": [
        {"account": "alona", "pinned_at": "2100-01-01T00:00:00.000Z"},
    ],
    "all_walled_until": {"general": 4102448400, "fable": None},
}
legacy_payload = {
    "pid": 123,
    "uptime_s": 61,
    "port": 45789,
    "current": "alona",
    "current_fable": "alona",
    "accounts": {
        "alona": {"h5": 98, "wk": 40, "hreset": 4102444800, "wreset": 4102440000,
                  "walled": True, "auth_failed_until": 0, "fable_walled_until": 4102445000},
    },
}

class Handler(http.server.BaseHTTPRequestHandler):
    requests = 0

    def do_GET(self):
        if self.path != "/claudebd/status":
            self.send_error(404)
            return
        body = json.dumps(payload if Handler.requests == 0 else legacy_payload).encode()
        Handler.requests += 1
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.environ["DAEMON_PORT_FILE"], "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
EOF
DAEMON_PORT_FILE="$DAEMON_PORT_FILE" python3 "$WORK/claudebd-fixture.py" &
daemon_pid=$!
for _ in {1..40}; do
  [ -s "$DAEMON_PORT_FILE" ] && break
  sleep 0.05
done
[ -s "$DAEMON_PORT_FILE" ] || fail "claudebd fixture server did not start"
daemon_port=$(cat "$DAEMON_PORT_FILE")
daemon_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" CLAUDEBD_PORT="$daemon_port" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "claudebd status collection failed"
jq -e '.vendors.claude.daemon == {
  walls:[
    {account:"alona",scope:"general",until:"2100-01-01T01:00:00.000Z",reason:"transient"}
  ],
  pins:[{account:"alona",pinned_at:"2100-01-01T00:00:00.000Z"}],
  all_walled_until:{general:4102448400,fable:null},
  reachable:true
}' <<<"$daemon_json" >/dev/null || fail "native daemon wall fields were not passed through"
daemon_legacy=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" CLAUDEBD_PORT="$daemon_port" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "legacy claudebd status collection failed"
jq -e '.vendors.claude.daemon == {
  walls:[
    {account:"alona",scope:"general",until:"2100-01-01T00:00:00Z",reason:"walled"},
    {account:"alona",scope:"fable",until:"2100-01-01T00:03:20Z",reason:"fable_walled"}
  ],
  all_walled_until:{general:"2100-01-01T00:00:00Z",fable:"2100-01-01T00:03:20Z"},
  reachable:true
}' <<<"$daemon_legacy" >/dev/null || fail "legacy daemon wall derivation mismatch"
kill "$daemon_pid" 2>/dev/null || true
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=''
daemon_down=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" CLAUDEBD_PORT="$daemon_port" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "daemon-down collection failed"
jq -e '.vendors.claude.daemon == {reachable:false} and
  .vendors.claude.available == true and .vendors.claude.accounts[0].account == "alona"' \
  <<<"$daemon_down" >/dev/null || fail "daemon-down state blocked or damaged Claude collection"

printf 'main\n' >"$CLAUDEB/.claudeb-state"
invalid_current=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "invalid current fallback failed"
jq -e '.vendors.claude.current_account == "alona" and all(.vendors.claude.accounts[]; .account != "main")' <<<"$invalid_current" >/dev/null || fail "invalid current did not fall back to the first real account"
printf 'alona\n' >"$CLAUDEB/.claudeb-state"
multi_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "claudeb plain collection failed"
grep -q 'claude/alona: 7%/- |' <<<"$multi_plain" || fail "claudeb missing-weekly plain output mismatch"
grep -q 'claude/main' <<<"$multi_plain" && fail "main account leaked into plain output"
jq -e 'all(.vendors.claude.accounts[]; .enabled == true)' <<<"$multi" >/dev/null || fail "missing disabled file must default to enabled:true"

# Rotation membership: a name listed in $CLAUDEB_DIR/disabled flips enabled to false
# for that account only, on the token-free passive path.
CLAUDEB_DIS="$WORK/claudeb-disabled-store"
mkdir -p "$CLAUDEB_DIS/limits"
printf 'alona\n' >"$CLAUDEB_DIS/.claudeb-state"
printf '{"five_hour":{"used_percentage":7,"resets_at":%s}}\n' "$((now + 5000))" >"$CLAUDEB_DIS/limits/alona.json"
printf '{"five_hour":{"used_percentage":21,"resets_at":%s}}\n' "$((now + 6000))" >"$CLAUDEB_DIS/limits/bree.json"
printf 'bree\n' >"$CLAUDEB_DIS/disabled"
disabled_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_DIS" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "disabled-flag collection failed"
jq -e '(.vendors.claude.accounts | length) == 2 and
  ([.vendors.claude.accounts[] | select(.account == "alona")][0].enabled == true) and
  ([.vendors.claude.accounts[] | select(.account == "bree")][0].enabled == false)' <<<"$disabled_json" >/dev/null || fail "disabled file did not map to enabled flags"
disabled_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_DIS" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "disabled table collection failed"
awk '$1 == "claude/bree"' <<<"$disabled_table" | grep -q 'off' || fail "disabled account not marked off in table"
awk '$1 == "claude/alona*"' <<<"$disabled_table" | grep -q 'off' && fail "enabled account wrongly marked off in table"
disabled_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_DIS" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "disabled plain collection failed"
grep 'claude/bree' <<<"$disabled_plain" | grep -q ' | off' || fail "disabled account not marked off in plain output"
grep 'claude/alona' <<<"$disabled_plain" | grep -q ' | off' && fail "enabled account wrongly marked off in plain output"

# Shared staleness contract: per-bucket as_of/origin pass through from the snapshot store;
# a bucket is stale on expired auth, cached origin, or age over the window threshold
# (5h: 1800s, weekly/fable: 21600s); missing as_of falls back to the snapshot mtime.
CLAUDEB_FRESH="$WORK/claudeb-freshness-store"
mkdir -p "$CLAUDEB_FRESH/limits"
printf 'aged\n' >"$CLAUDEB_FRESH/.claudeb-state"
printf '{"five_hour":{"used_percentage":7.000000000000001,"resets_at":%s,"as_of":%s,"origin":"usage"},"seven_day":{"used_percentage":56.99999999999999,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now - 3000))" "$((now + 90000))" "$((now - 3000))" "$now" >"$CLAUDEB_FRESH/limits/aged.json"
printf '{"five_hour":{"used_percentage":11,"resets_at":%s,"as_of":%s,"origin":"cached"}}\n' \
  "$((now + 5000))" "$now" >"$CLAUDEB_FRESH/limits/cachedorigin.json"
printf '{"five_hour":{"used_percentage":13,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"expired","checked_at":%s}}\n' \
  "$((now + 5000))" "$now" "$now" >"$CLAUDEB_FRESH/limits/badauth.json"
printf '{"five_hour":{"used_percentage":17,"resets_at":%s}}\n' "$((now + 5000))" >"$CLAUDEB_FRESH/limits/legacy.json"
touch -t 202607110500 "$CLAUDEB_FRESH/limits/legacy.json"
printf '{"auth":{"status":"expired","checked_at":%s}}\n' "$now" >"$CLAUDEB_FRESH/limits/authonly.json"
fresh_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "freshness-contract collection failed"
jq -e --argjson asof "$((now - 3000))" '
  [.vendors.claude.accounts[] | select(.account == "aged")][0] as $a |
  $a.five_hour.as_of == $asof and $a.five_hour.origin == "usage" and
  ($a.as_of | fromdateiso8601) == $asof and
  $a.five_hour.stale == true and $a.weekly.stale == false and $a.auth.status == "ok"' <<<"$fresh_json" >/dev/null \
  || fail "as_of threshold staleness mismatch"
jq -e '[.vendors.claude.accounts[] | select(.account == "cachedorigin")][0]
  | .five_hour.origin == "cached" and .five_hour.stale == true' <<<"$fresh_json" >/dev/null \
  || fail "cached origin must mark the bucket stale"
jq -e '[.vendors.claude.accounts[] | select(.account == "badauth")][0]
  | .auth.status == "expired" and .five_hour.stale == true' <<<"$fresh_json" >/dev/null \
  || fail "expired auth must mark buckets stale and pass auth through"
jq -e '[.vendors.claude.accounts[] | select(.account == "legacy")][0]
  | (.five_hour.as_of | type) == "number" and .five_hour.stale == true' <<<"$fresh_json" >/dev/null \
  || fail "missing as_of must fall back to snapshot mtime"
jq -e '.vendors.claude.stale == true and .vendors.claude.auth.status == "ok"' <<<"$fresh_json" >/dev/null \
  || fail "vendor-level stale/auth hoist mismatch"
# Auth-only snapshot (failed probe, no five_hour): the account stays visible as unknown.
jq -e '[.vendors.claude.accounts[] | select(.account == "authonly")][0]
  | .five_hour.used_pct == null and .five_hour.effective_pct == null and .five_hour.stale == true and .auth.status == "expired"' <<<"$fresh_json" >/dev/null \
  || fail "auth-only snapshot must stay visible with unknown values"
printf 'authonly\n' >"$CLAUDEB_FRESH/.claudeb-state"
auth_current=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "auth-only current collection failed"
jq -e '.vendors.claude.current_account == "authonly" and
  .vendors.claude.accounts[0].five_hour.used_pct == null and
  (.vendors.claude.five_hour.used_pct | type) == "number"' <<<"$auth_current" >/dev/null \
  || fail "auth-only current account must hoist the first populated five-hour bucket"
printf 'aged\n' >"$CLAUDEB_FRESH/.claudeb-state"
fresh_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "rounding table collection failed"
grep -Eq '^claude/aged\* +7% +57% ' <<<"$fresh_table" || fail "table percentages must round to integers"
grep -Eq '^claude/authonly +- +- ' <<<"$fresh_table" || fail "auth-only account missing from table"
fresh_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB_FRESH" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "rounding plain collection failed"
grep -q 'claude/aged: 7%/57% ' <<<"$fresh_plain" || fail "plain percentages must round to integers"
grep -q 'claude/authonly: -/-' <<<"$fresh_plain" || fail "auth-only account missing from plain output"
jq -e '(.vendors.claude.refresh_error | contains("authonly") and endswith(" auth"))' <<<"$auth_current" >/dev/null \
  || fail "Claude auth failure was not exposed as vendor refresh_error"

CLAUDEB_BIN="$ROOT/bin/claudeb"
OAUTH_HOME="$WORK/oauth-home"
OAUTH_STORE="$WORK/oauth-store"
OAUTH_BIN="$WORK/oauth-bin"
OAUTH_SENTINEL="$WORK/oauth-curl-called"
OAUTH_CLAUDE_SENTINEL="$WORK/oauth-claude-called"
mkdir -p "$OAUTH_HOME/.claude-profiles/stuck" "$OAUTH_STORE/tokens" "$OAUTH_STORE/limits" "$OAUTH_BIN"
printf 'fixture-daemon-token\n' >"$OAUTH_STORE/tokens/stuck"
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
# heal attempts, at most once per account per 30 minutes, and records why.
rm -f "$OAUTH_STORE/oauth-attempts.json" "$OAUTH_SENTINEL" "$OAUTH_CLAUDE_SENTINEL"
printf '{"stuck":{"attempted_at":%s,"outcome":"warm-failed","retry_after_until":0}}\n' "$now" >"$OAUTH_STORE/oauth-attempts.json"
OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" accounts --no-spend --heal >/dev/null 2>/dev/null || true
[ ! -e "$OAUTH_CLAUDE_SENTINEL" ] || fail "a recent warm-failed outcome was not throttled to once per 30 minutes"
jq -e '.auth.cause | test("^backoff [0-9]+m$")' "$OAUTH_STORE/limits/stuck.json" >/dev/null \
  || fail "throttled heal did not record a per-account backoff cause"

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
OAUTH_SENTINEL="$OAUTH_SENTINEL" OAUTH_CLAUDE_SENTINEL="$OAUTH_CLAUDE_SENTINEL" PATH="$OAUTH_BIN:$PATH" HOME="$OAUTH_HOME" CLAUDEB_DIR="$OAUTH_STORE" \
  bash "$CLAUDEB_BIN" --refresh --start-windows >/dev/null 2>/dev/null || fail "start-windows auth fallback fixture failed"
grep -q 'api.anthropic.com/v1/messages' "$OAUTH_SENTINEL" || fail "start-windows did not use daemon-token messages fallback after auth failure"

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
WARM_FAIL_USAGE=1 WARM_SENTINEL="$WARM_SENTINEL" PATH="$WARM_BIN:$PATH" HOME="$WARM_HOME" CLAUDEB_DIR="$WARM_STORE" \
  bash "$CLAUDEB_BIN" warm one >/dev/null || fail "warm paid-fallback fixture failed"
[ "$(wc -l <"$WARM_SENTINEL" | tr -d ' ')" -eq 2 ] || fail "failed /usage did not produce exactly one fallback"
sed -n '1p' "$WARM_SENTINEL" | grep -q -- '-p /usage --output-format json' || fail "fallback fixture did not try /usage first"
sed -n '2p' "$WARM_SENTINEL" | grep -q -- '-p ok --model haiku --output-format json' || fail "failed /usage did not use the minimal paid fallback"
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
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >>"$CODEX_SENTINEL"\n' >"$FAKE_BIN/codex"
cat >"$WORK/fake-codex-quota" <<EOF
#!/usr/bin/env bash
printf 'called\n' >>"\$CODEX_QUOTA_SENTINEL"
printf '%s\n' '{"rateLimits":{"primary":{"usedPercent":31,"windowDurationMins":300,"resetsAt":$((now + 4000))},"secondary":{"usedPercent":64,"windowDurationMins":10080,"resetsAt":$((now + 90000))},"planType":"plus"}}'
EOF
chmod +x "$FAKE_BIN/claudeb" "$FAKE_BIN/codex" "$WORK/fake-codex-quota"

# --refresh is zero token spend: claudeb tier-1 snapshot, codex app-server usage query
# (never codex exec), and the live snapshot outranks the stale rollout tail.
refresh_out=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh) || fail "refresh collection failed"
[ -s "$SENTINEL" ] || fail "--refresh did not invoke claudeb accounts"
grep -q 'accounts --no-spend' "$SENTINEL" || fail "Claude refresh was not tier-1-only"
[ -s "$CODEX_QUOTA_SENTINEL" ] || fail "--refresh did not invoke the codex quota helper"
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
awk '$1 == "codex" {print}' <<<"$weekly_only_table" | grep -Eq '^codex +- +0%' \
  || fail "weekly-only codex table did not render unknown 5h and weekly percentage"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/fake-codex-quota" LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  bash "$SCRIPT" --refresh --no-write >/dev/null 2>&1 || fail "codex fixture restore failed"
refresh_failed=$(LLM_LIMITS_CODEX_REFRESH=1 LLM_LIMITS_CODEX_QUOTA_CMD=/usr/bin/false LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --refresh 2>/dev/null) \
  || fail "failed Codex refresh collection failed"
jq -e '.vendors.codex.refresh_error == "live query failed" and .vendors.codex.five_hour.used_pct == 31' \
  <<<"$refresh_failed" >/dev/null || fail "Codex refresh failure was not machine-readable or stale data was lost"
rm -f "$SENTINEL" "$CODEX_QUOTA_SENTINEL"
cached_codex=$(CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" CODEX_QUOTA_SENTINEL="$CODEX_QUOTA_SENTINEL" \
  LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT") || fail "default gated collection failed"
[ ! -e "$SENTINEL" ] || fail "default collection invoked claudeb"
[ ! -e "$CODEX_SENTINEL" ] || fail "default collection invoked codex"
[ ! -e "$CODEX_QUOTA_SENTINEL" ] || fail "default collection invoked the codex quota helper"
jq -e '.vendors.codex.five_hour.used_pct == 31 and .vendors.codex.five_hour.origin == "usage"' <<<"$cached_codex" >/dev/null \
  || fail "passive run did not reuse the codex quota cache"

CODEX_ACCOUNTS_HOME="$WORK/codex-accounts-home"
CODEX_ACCOUNTS_CACHE="$WORK/codex-accounts.json"
mkdir -p "$CODEX_ACCOUNTS_HOME"
five_reset_epoch=$((now + 4000))
expired_reset_epoch=$((now - 60))
week_reset_epoch=$((now + 90000))
cat >"$CODEX_ACCOUNTS_CACHE" <<EOF
{"schema":1,"fetched_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","plan_type":"plus","five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"accounts":[{"account":"beta","plan_type":"team","five_hour":{"used_pct":100,"resets_at":$expired_reset_epoch},"weekly":{"used_pct":100,"resets_at":$week_reset_epoch},"as_of":$((now - 22000))},{"account":"alpha","plan_type":"plus","five_hour":{"used_pct":100,"resets_at":$five_reset_epoch},"weekly":{"used_pct":20,"resets_at":$week_reset_epoch},"as_of":$((now - 1900))}],"current":"alpha"}
EOF
codex_accounts_full=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex multi-account collection failed"
jq -e '.vendors.codex.current_account == "alpha" and (.vendors.codex.accounts | length) == 2 and
  .vendors.codex.accounts[0].is_current == true and
  .vendors.codex.accounts[0].five_hour.effective_pct == 100 and
  .vendors.codex.accounts[0].five_hour.stale == true and
  .vendors.codex.accounts[0].weekly.stale == false and
  .vendors.codex.accounts[1].five_hour.effective_pct == 0 and
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
jq '(.accounts[] | select(.account == "beta") | .five_hour.used_pct) = 25 |
    (.accounts[] | select(.account == "beta") | .weekly.used_pct) = 30' \
  "$CODEX_ACCOUNTS_CACHE" >"$CODEX_ACCOUNTS_CACHE.tmp"
mv "$CODEX_ACCOUNTS_CACHE.tmp" "$CODEX_ACCOUNTS_CACHE"
codex_accounts_free=$(HOME="$CODEX_ACCOUNTS_HOME" LLM_LIMITS_CODEX_CACHE="$CODEX_ACCOUNTS_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex free-account collection failed"
jq -e '.vendors.codex.usable_now == true and .vendors.codex.five_hour.effective_pct == 100' \
  <<<"$codex_accounts_free" >/dev/null || fail "Codex one-free-account usability mismatch"

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
  .vendors.codex.five_hour == .vendors.codex.accounts[0].five_hour and
  .vendors.codex.weekly == .vendors.codex.accounts[0].weekly' <<<"$codex_legacy" >/dev/null \
  || fail "Codex legacy cache compatibility mismatch"
# Rollout events newer than the cached RPC snapshot must win (fixture rollout is 2026-07-11T10:00Z).
touch -t 202607110500 "$CODEX_CACHE"
rollout_wins=$(LLM_LIMITS_CODEX_CACHE="$CODEX_CACHE" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT") || fail "rollout-preference collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 74 and .vendors.codex.five_hour.origin == "headers" and .vendors.codex.source == "session-rollout"' <<<"$rollout_wins" >/dev/null \
  || fail "newer rollout event did not outrank an older quota cache"
rm -f "$CODEX_CACHE"

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
[ "$(grep -c called "$CODEX_QUOTA_SENTINEL")" -eq 2 ] || fail "codex quota was not re-read after the window start"
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
  bash "$SCRIPT" --refresh --start-windows >/dev/null 2>"$WORK/null.err" || fail "null resets_at refresh crashed"
[ ! -e "$CODEX_SENTINEL" ] || fail "unknown codex window state triggered a spend"
grep -q 'codex 5h window state unknown' "$WORK/null.err" || fail "unknown codex window state was skipped silently"
null_reset=$(HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "null resets_at collection failed"
jq -e '.vendors.codex.available == true and .vendors.codex.five_hour.used_pct == 41 and .vendors.codex.five_hour.resets_at == null' <<<"$null_reset" >/dev/null || fail "null resets_at not normalized"
HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain | grep -q 'codex: 41%/22%' || fail "null resets_at plain render failed"
HOME="$NULLRESET_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table | grep -q '^codex' || fail "null resets_at table render failed"

# Gemini window start: an expired 5h bucket in the refreshed quota triggers one bounded
# agy --print call, then the quota helper runs again.
GEMINI_START_SENTINEL="$WORK/agy-called"
GEMINI_STATE="$WORK/gemini-quota-state"
GEMINI_CACHE2="$WORK/gemini-start.json"
FAKE_AGY="$WORK/fake-agy"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$GEMINI_START_SENTINEL"\n' >"$FAKE_AGY"
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
gemini_start=$(GEMINI_SENTINEL="$GEMINI_SENTINEL" GEMINI_STATE="$GEMINI_STATE" GEMINI_START_SENTINEL="$GEMINI_START_SENTINEL" \
  CLAUDEB_SENTINEL="$SENTINEL" CODEX_SENTINEL="$CODEX_SENTINEL" \
  LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_GEMINI_CMD="$WORK/fake-gemini-quota" LLM_LIMITS_GEMINI_CACHE="$GEMINI_CACHE2" \
  AGY_BIN="$FAKE_AGY" AGY_WORKDIR="$WORK" \
  PATH="$FAKE_BIN:$PATH" HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --refresh --start-windows 2>/dev/null) || fail "gemini start-windows collection failed"
grep -q -- '--print' "$GEMINI_START_SENTINEL" || fail "expired gemini window did not trigger agy --print"
[ "$(grep -c called "$GEMINI_SENTINEL")" -eq 2 ] || fail "gemini quota was not re-read after the window start"
jq -e '.vendors.gemini.weekly.used_pct == 40' <<<"$gemini_start" >/dev/null || fail "post-start gemini snapshot was not picked up"
rm -f "$GEMINI_SENTINEL" "$GEMINI_START_SENTINEL" "$GEMINI_STATE" "$GEMINI_CACHE2"

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
grep -q 'fable 33%' <<<"$expired_fable" || fail "expired fable must keep its last known value in the note"
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
SORT_RESET_STORE="$WORK/sort-reset-store"
EMPTY_SORT_HOME="$WORK/sort-reset-home"
mkdir -p "$SORT_RESET_STORE/limits" "$EMPTY_SORT_HOME"
printf 'future-a\n' >"$SORT_RESET_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$((now + 1000))" >"$SORT_RESET_STORE/limits/future-a.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s}}\n' "$((now + 2000))" >"$SORT_RESET_STORE/limits/future-b.json"
printf '{"five_hour":{"used_percentage":30,"resets_at":%s}}\n' "$((now - 18000))" >"$SORT_RESET_STORE/limits/expired.json"
reset_expired=$(HOME="$EMPTY_SORT_HOME" CLAUDEB_DIR="$SORT_RESET_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort reset) || fail "expired reset-sort collection failed"
order=$(awk 'NR > 1 && $1 ~ /^claude\// {print $1}' <<<"$reset_expired" | paste -sd, -)
[ "$order" = "claude/future-a*,claude/future-b,claude/expired" ] || fail "--sort reset must place an expired-window account last: $order"
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

# Passive snapshot whose 5h reset already passed: flagged expired, table keeps the last
# known value and reset time (dimmed only on a TTY, so piped output stays escape-free),
# sort treats the stale 100% as 0. The fresh weekly window stays unflagged.
sleep 1
printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":44,"window_minutes":10080,"resets_at":%s},"plan_type":"plus"}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$((now - 600))" "$((now + 4000))" \
  >"$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-expired.jsonl"
expired_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "expired-window collection failed"
jq -e '.vendors.codex.five_hour.expired == true and .vendors.codex.five_hour.used_pct == 100 and
  .vendors.codex.five_hour.effective_pct == 0 and .vendors.codex.usable_now == true and
  (.vendors.codex.weekly | has("expired") | not) and
  (.vendors.claude.accounts[0].five_hour | has("expired") | not)' <<<"$expired_json" >/dev/null || fail "expired flag mismatch"
expired_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "expired table collection failed"
codex_row=$(awk 'NR > 1 && $1 == "codex"' <<<"$expired_table")
grep -Eq '^codex +100% +44% +[0-9]{2}:[0-9]{2}' <<<"$codex_row" || fail "expired window must keep its last known value and reset time: $codex_row"
grep -q '5h reset passed' <<<"$codex_row" || fail "expired note missing from table"
expired_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "expired plain collection failed"
grep -q 'codex: 100%/44%' <<<"$expired_plain" || fail "expired plain output must keep the last known value"
expired_sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort 5h) || fail "expired sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$expired_sorted" | paste -sd, -)
[ "$order" = "claude/alona*,codex,gemini" ] || fail "expired 5h sort must rank the stale 100% as 0: $order"

USABLE_STORE="$WORK/usable-store"
USABLE_HOME="$WORK/usable-home"
mkdir -p "$USABLE_STORE/limits" "$USABLE_HOME/.codex/sessions"
printf 'full\n' >"$USABLE_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":100,"resets_at":%s},"seven_day":{"used_percentage":100,"resets_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" >"$USABLE_STORE/limits/full.json"
claude_full=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude exhausted usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_full" >/dev/null || fail "Claude all-exhausted usability mismatch"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" >"$USABLE_STORE/limits/free.json"
claude_free=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude free-account usability collection failed"
jq -e '.vendors.claude.usable_now == true' <<<"$claude_free" >/dev/null || fail "Claude one-free-account usability mismatch"
printf 'free\n' >"$USABLE_STORE/disabled"
claude_disabled=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude disabled-account usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_disabled" >/dev/null || fail "Disabled under-limit account must not make Claude usable"
rm "$USABLE_STORE/disabled"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"auth":{"status":"expired"}}\n' \
  "$((now + 5000))" "$((now + 9000))" >"$USABLE_STORE/limits/free.json"
claude_expired_auth=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude expired-auth usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_expired_auth" >/dev/null || fail "Expired-auth under-limit account must not make Claude usable"
rm "$USABLE_STORE/limits/free.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"fable":{"used_percentage":100,"resets_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" "$((now + 6000))" >"$USABLE_STORE/limits/full.json"
claude_fable=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude fable usability collection failed"
jq -e '.vendors.claude.fable.effective_pct == 100 and .vendors.claude.usable_now == true' <<<"$claude_fable" >/dev/null || fail "Fable exhaustion must not block general Claude work"

printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"resets_at":%s},"secondary":{"used_percent":40,"resets_at":%s}}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$((now + 5000))" "$((now + 9000))" >"$USABLE_HOME/.codex/sessions/rollout-full.jsonl"
codex_full=$(HOME="$USABLE_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex exhausted usability collection failed"
jq -e '.vendors.codex.five_hour.effective_pct == 100 and .vendors.codex.usable_now == false' <<<"$codex_full" >/dev/null || fail "Codex exhausted usability mismatch"

FORMAT_STORE="$WORK/reset-format-store"
FORMAT_HOME="$WORK/reset-format-home"
mkdir -p "$FORMAT_STORE/limits" "$FORMAT_STORE/tokens" "$FORMAT_HOME"
printf 'clock\n' >"$FORMAT_STORE/.claudeb-state"
clock_epoch=$(( $(date +%s) + 3600 ))
weekday_epoch=$(( clock_epoch + 172800 ))
date_epoch=$(( clock_epoch + 691200 ))
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$clock_epoch" >"$FORMAT_STORE/limits/clock.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s}}\n' "$weekday_epoch" >"$FORMAT_STORE/limits/weekday.json"
printf '{"five_hour":{"used_percentage":30,"resets_at":%s}}\n' "$date_epoch" >"$FORMAT_STORE/limits/date.json"
touch "$FORMAT_STORE/tokens/clock" "$FORMAT_STORE/tokens/weekday" "$FORMAT_STORE/tokens/date"
clock_text=$(date -r "$clock_epoch" '+%H:%M')
weekday_num=$(date -r "$weekday_epoch" '+%w')
weekdays=(Sun Mon Tue Wed Thu Fri Sat)
weekday_text="${weekdays[$weekday_num]} $(date -r "$weekday_epoch" '+%H:%M')"
date_text=$(date -r "$date_epoch" '+%m-%d %H:%M')
format_table=$(HOME="$FORMAT_HOME" CLAUDEB_DIR="$FORMAT_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "reset-format table fixture failed"
format_plain=$(HOME="$FORMAT_HOME" CLAUDEB_DIR="$FORMAT_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "reset-format plain fixture failed"
claudeb_plain=$(HOME="$FORMAT_HOME" CLAUDEB_DIR="$FORMAT_STORE" bash "$ROOT/bin/claudeb" status --cached --plain) || fail "claudeb reset-format fixture failed"
for rendered in "$clock_text" "$weekday_text" "$date_text"; do
  grep -Fq "$rendered" <<<"$format_table" || fail "table reset tier missing: $rendered"
  grep -Fq "$rendered" <<<"$format_plain" || fail "plain reset tier missing: $rendered"
  grep -Fq "$rendered" <<<"$claudeb_plain" || fail "claudeb reset tier missing: $rendered"
done

EMPTY="$WORK/empty-home"
mkdir -p "$EMPTY"
HOME="$EMPTY" bash "$SCRIPT" --no-write >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] || fail "all-missing case: expected exit 3, got $rc"

echo "PASS: schema, Claude unique accounts and fallback, Codex multi-account and legacy cache, Claude daemon status, enabled flags, freshness contract, machine effective percentages and usability, zero-spend refresh, start-windows, small-file fallback, truncated boundary, walls, plain output, table output and sorts, reset tiers, expired windows, bare JSON default, atomic cache, missing exit 3"
exit 0
