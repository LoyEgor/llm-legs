#!/usr/bin/env bash
# grok-quota.py against a local stand-in for cli-chat-proxy.grok.com: the real endpoint is never
# reached, and the access token in auth.json may never appear in anything the helper prints.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/grok-quota.py"
WORK="$(mktemp -d)"
SERVER_PID=''
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); }

TOKEN='grok-access-token-SENTINEL-must-never-be-printed'
REFRESH='grok-refresh-token-SENTINEL'
HEADER_LOG="$WORK/headers.log"

cat >"$WORK/server.py" <<'PY'
import json
import http.server
import sys
import threading
import time

HEADER_LOG = sys.argv[1]
PORT_FILE = sys.argv[2]

WEEKLY = {"type": "USAGE_PERIOD_TYPE_WEEKLY",
          "start": "2026-08-30T14:50:11.237680+00:00",
          "end": "2026-09-06T14:50:11.237680+00:00"}
ZERO = {"config": {"currentPeriod": WEEKLY,
                   "onDemandCap": {"val": 0}, "onDemandUsed": {"val": 0},
                   "isUnifiedBillingUser": True, "prepaidBalance": {"val": 0}}}
ZERO_BUILD = {"config": {"currentPeriod": WEEKLY,
                         "productUsage": [{"product": "PRODUCT_GROK_BUILD",
                                           "usagePercent": 18.5}]}}
BUSY = {"subscriptionTier": "SUBSCRIPTION_TIER_SUPERGROK",
        "config": {"creditUsagePercent": 61.2, "currentPeriod": WEEKLY,
                   "productUsage": [{"product": "PRODUCT_GROK_CHAT", "usagePercent": 40.0},
                                    {"product": "PRODUCT_GROK_BUILD", "usagePercent": 18.5}]}}
PREFER = {"subscriptionTier": "SUBSCRIPTION_TIER_SUPERGROK",
          "productUsage": [{"product": "PRODUCT_GROK_BUILD", "usagePercent": 90.0}],
          "config": {"creditUsagePercent": 10.0, "currentPeriod": WEEKLY,
                     "productUsage": [{"product": "PRODUCT_GROK_CHAT", "usagePercent": 40.0},
                                      {"product": "PRODUCT_GROK_BUILD", "usagePercent": 50.0}]}}
NO_PERIOD = {"subscriptionTier": "SUBSCRIPTION_TIER_SUPERGROK",
             "config": {"creditUsagePercent": 22.5}}
BAD_PERIOD = {"config": {"creditUsagePercent": 33,
                         "currentPeriod": {"type": 7, "start": WEEKLY["start"],
                                           "end": "not-a-date"}}}
EMPTY_END = {"config": {"creditUsagePercent": 33,
                        "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
                                          "start": WEEKLY["start"], "end": ""}}}
NO_CONFIG = {"subscriptionTier": "SUBSCRIPTION_TIER_SUPERGROK",
             "creditUsagePercent": 61.2}
EMPTY_BODY = {}
PERIOD_NOT_OBJECT = {"config": {"creditUsagePercent": 4,
                                "currentPeriod": "USAGE_PERIOD_TYPE_WEEKLY"}}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(HEADER_LOG, "a") as handle:
            handle.write(json.dumps({"path": self.path,
                                     "headers": {k.lower(): v for k, v in self.headers.items()}}) + "\n")
        route = self.path.split("?")[0]
        if route == "/slow":
            time.sleep(3)
            route = "/zero"
        if route == "/zero":
            self.reply(200, ZERO)
        elif route == "/zero-build":
            self.reply(200, ZERO_BUILD)
        elif route == "/busy":
            self.reply(200, BUSY)
        elif route == "/prefer":
            self.reply(200, PREFER)
        elif route == "/no-period":
            self.reply(200, NO_PERIOD)
        elif route == "/bad-period":
            self.reply(200, BAD_PERIOD)
        elif route == "/empty-end":
            self.reply(200, EMPTY_END)
        elif route == "/period-not-object":
            self.reply(200, PERIOD_NOT_OBJECT)
        elif route == "/no-config":
            self.reply(200, NO_CONFIG)
        elif route == "/empty-body":
            self.reply(200, EMPTY_BODY)
        elif route == "/unauthorized":
            self.reply(401, {"error": "unauthorized"})
        elif route == "/not-signed-in":
            self.reply(401, {"error": "Not signed in"})
        elif route == "/session-expired":
            self.reply(401, {"error": "session has expired or your credentials were rejected"})
        elif route == "/forbidden":
            self.reply(403, {"error": "forbidden"})
        elif route == "/payment-required":
            self.reply(402, {"error": "You have hit the credit limit for your plan"})
        elif route == "/credits-exhausted":
            self.reply(402, {"error": "Your team has run out of credits"})
        elif route == "/rate-limit":
            self.reply(402, {"error": "You have hit the rate limit for your plan"})
        elif route == "/free-usage-exhausted":
            self.reply(402, {"error": "subscription:free-usage-exhausted"})
        elif route == "/unknown-402":
            self.reply(402, {"error": "Payment required for this request"})
        elif route == "/too-many":
            self.reply(429, {"error": "Too Many Requests"})
        elif route == "/unavailable":
            self.reply(503, {"error": "Service Unavailable"})
        elif route == "/boom":
            self.reply(500, {"error": "server"})
        elif route == "/garbage":
            body = b"not json at all"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif route == "/truncated":
            body = b'{"config": {"creditUsagePercent": 61.2'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.reply(404, {"error": "unknown"})

    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as handle:
    handle.write(str(server.server_address[1]))
threading.Thread(target=server.serve_forever, daemon=True).start()
while True:
    time.sleep(3600)
PY

python3 "$WORK/server.py" "$HEADER_LOG" "$WORK/port" &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$WORK/port" ] && break
  sleep 0.2
done
PORT=$(cat "$WORK/port" 2>/dev/null || true)
[ -n "$PORT" ] || fail "the local billing stand-in never bound a port"
BASE="http://127.0.0.1:$PORT"

PROFILES="$WORK/grok-profiles"
mkdir -p "$PROFILES/supergrok" "$PROFILES/second" "$PROFILES/.grokb" "$WORK/home/.grok"

write_auth() {
  local dir=$1 token=$2 refresh=${3:-}
  mkdir -p "$dir"
  if [ -n "$refresh" ]; then
    printf '{"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828":{"key":"%s","refresh_token":"%s","user_id":"u-%s","email":"%s@example.com","expires_at":1788000000}}\n' \
      "$token" "$refresh" "$(basename "$dir")" "$(basename "$dir")" >"$dir/auth.json"
  else
    printf '{"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828":{"key":"%s","user_id":"u-%s","email":"%s@example.com","expires_at":1788000000}}\n' \
      "$token" "$(basename "$dir")" "$(basename "$dir")" >"$dir/auth.json"
  fi
}
write_auth "$PROFILES/supergrok" "$TOKEN" "$REFRESH"
write_auth "$PROFILES/second" "$TOKEN"

run() {
  local route=$1
  shift
  env HOME="$WORK/home" GROK_QUOTA_ENDPOINT="$BASE/$route?format=credits" \
    GROK_QUOTA_CLIENT_VERSION=9.9.9 \
    python3 "$HELPER" --profiles-dir "$PROFILES" "$@" 2>"$WORK/last.err"
}

no_secret() {
  case "$1" in
    *"$TOKEN"*|*"$REFRESH"*) fail "the token leaked into $2" ;;
  esac
  grep -q "$TOKEN" "$WORK/last.err" && fail "the token leaked into stderr while $2"
  grep -q "$REFRESH" "$WORK/last.err" && fail "the refresh token leaked into stderr while $2"
  return 0
}

no_traceback() {
  grep -q 'Traceback (most recent call last)' "$WORK/last.err" \
    && fail "traceback on stderr while $1: $(cat "$WORK/last.err")"
  return 0
}

# A fresh account: the endpoint omits creditUsagePercent entirely and names no tier.
out=$(run zero --account supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "zero-usage read: expected exit 0, got $rc"
jq -e '(.accounts | length) == 1 and (.accounts[0] |
  .account == "supergrok" and .auth == "ok" and .used_pct == 0 and
  .resets_at == "2026-09-06T14:50:11Z" and .period == "USAGE_PERIOD_TYPE_WEEKLY" and
  .email == "supergrok@example.com" and (has("plan_type") | not) and
  (has("build_pct") | not) and (.as_of | type) == "number")' <<<"$out" >/dev/null \
  || fail "zero-usage body was not mapped as 0%: $out"
no_secret "$out" "reading a zero-usage account"
pass

out=$(run busy --account supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "measured read: expected exit 0, got $rc"
jq -e '.accounts[0] | .used_pct == 61.2 and .build_pct == 18.5 and
  .plan_type == "SUBSCRIPTION_TIER_SUPERGROK" and .period == "USAGE_PERIOD_TYPE_WEEKLY"' \
  <<<"$out" >/dev/null || fail "measured body lost the percent, tier or Build split: $out"
no_secret "$out" "reading a measured account"
pass

# The CLI's own headers, including the bearer the endpoint refuses without.
last_headers=$(tail -n 1 "$HEADER_LOG")
jq -e --arg token "$TOKEN" '.headers |
  .authorization == ("Bearer " + $token) and
  .["x-xai-token-auth"] == "xai-grok-cli" and .["x-userid"] == "u-supergrok" and
  .["x-grok-client-version"] == "9.9.9" and .accept == "application/json"' \
  <<<"$last_headers" >/dev/null || fail "request headers mismatch: $last_headers"
jq -e '.path == "/busy?format=credits"' <<<"$last_headers" >/dev/null \
  || fail "the credits query string was dropped: $last_headers"
pass

# 401/403 with a refresh token is the CLI's own to heal; without one only a human login can. The
# cause carries the code that came back, so each route is asserted against its own.
for spec in unauthorized:401 forbidden:403; do
  route=${spec%:*}
  code=${spec##*:}
  out=$(run "$route" --account supergrok); rc=$?
  [ "$rc" -eq 2 ] || fail "$route with a refresh token: expected exit 2, got $rc"
  jq -e --arg code "$code" '.accounts[0] | .auth == "expired" and (.cause | test($code)) and
    (has("used_pct") | not)' <<<"$out" >/dev/null \
    || fail "$route with a refresh token was not read as a refreshable token: $out"
  no_secret "$out" "reading a rejected token"
  out=$(run "$route" --account second); rc=$?
  [ "$rc" -eq 2 ] || fail "$route without a refresh token: expected exit 2, got $rc"
  jq -e '.accounts[0].auth == "needs_login"' <<<"$out" >/dev/null \
    || fail "$route without a refresh token must demand a login: $out"
  no_secret "$out" "reading a dead token"
done
pass

# No auth.json at all is the one definite "nobody is logged in".
mkdir -p "$PROFILES/never-logged-in"
out=$(run zero --account never-logged-in); rc=$?
[ "$rc" -eq 2 ] || fail "never-logged-in: expected exit 2, got $rc"
jq -e '.accounts[0] | .auth == "needs_login" and (has("used_pct") | not)' <<<"$out" >/dev/null \
  || fail "a profile with no auth.json was not read as needs_login: $out"
# A file that does not parse is the CLI rewriting it under a lock this reader never takes: a
# transient error row, because needs_login is a verdict that overwrites the last good reading.
mkdir -p "$PROFILES/broken"
printf '{"https://auth.x.ai::b1a0":{"key":"gro\n' >"$PROFILES/broken/auth.json"
out=$(run zero --account broken); rc=$?
[ "$rc" -eq 1 ] || fail "unreadable auth.json: expected exit 1, got $rc"
jq -e '.accounts[0] | (.error | test("auth.json")) and (has("auth") | not) and
  (has("used_pct") | not)' <<<"$out" >/dev/null \
  || fail "a truncated auth.json was read as a login verdict: $out"
no_traceback "reading a truncated auth.json"
# A well-formed document with no key in it is nobody logged in, not a race.
printf '{"https://auth.x.ai::b1a0":{"user_id":"u-broken"}}\n' >"$PROFILES/broken/auth.json"
out=$(run zero --account broken); rc=$?
[ "$rc" -eq 2 ] || fail "keyless auth.json: expected exit 2, got $rc"
jq -e '.accounts[0].auth == "needs_login"' <<<"$out" >/dev/null \
  || fail "a keyless auth.json was not read as needs_login: $out"
# The flat shape auth_entry also accepts: the token sits at the top level, with no wrapper.
mkdir -p "$PROFILES/flat"
printf '{"key":"%s","refresh_token":"%s","user_id":"u-flat"}\n' "$TOKEN" "$REFRESH" \
  >"$PROFILES/flat/auth.json"
out=$(run busy --account flat); rc=$?
[ "$rc" -eq 0 ] || fail "flat auth.json: expected exit 0, got $rc"
jq -e '.accounts[0] | .account == "flat" and .auth == "ok" and .used_pct == 61.2' <<<"$out" >/dev/null \
  || fail "a flat auth.json was not read: $out"
[ "$(jq -r '.headers["x-userid"]' <<<"$(tail -n 1 "$HEADER_LOG")")" = "u-flat" ] \
  || fail "the flat entry's user id did not reach the request header"
no_secret "$out" "reading a flat auth.json"
rm -rf "$PROFILES/flat"
requests_before=$(wc -l <"$HEADER_LOG")
run zero --account never-logged-in >/dev/null
[ "$(wc -l <"$HEADER_LOG")" -eq "$requests_before" ] \
  || fail "a profile with no token still issued a billing request"
rm -rf "$PROFILES/never-logged-in" "$PROFILES/broken"
pass

# Weather is never an auth verdict (docs/DIAGNOSTICS.md 429 taxonomy): a 5xx, a body that is not
# JSON and a timeout are transient errors that keep the account's auth state unstated.
for route in boom garbage; do
  out=$(run "$route" --account supergrok); rc=$?
  [ "$rc" -eq 1 ] || fail "$route: expected exit 1, got $rc"
  jq -e '.accounts[0] | (.error | type) == "string" and (has("auth") | not) and
    (has("used_pct") | not)' <<<"$out" >/dev/null \
    || fail "$route was not reported as a transient error: $out"
  no_secret "$out" "reporting a $route response"
  no_traceback "reporting a $route response"
done
out=$(run slow --account supergrok --timeout 1); rc=$?
[ "$rc" -eq 1 ] || fail "timeout: expected exit 1, got $rc"
jq -e '.accounts[0] | (.error | type) == "string" and (has("auth") | not)' <<<"$out" >/dev/null \
  || fail "a timeout was not reported as a transient error: $out"
no_secret "$out" "reporting a timeout"
pass

# A 200 whose shape this reader does not know must stay unstated: reporting 0% would publish a
# measurement nobody made and rank a possibly-exhausted account as the freest in the pool.
for route in no-config empty-body; do
  out=$(run "$route" --account supergrok); rc=$?
  [ "$rc" -eq 1 ] || fail "$route: expected exit 1, got $rc"
  jq -e '.accounts[0] | (.error | test("config")) and (has("used_pct") | not) and
    (has("auth") | not)' <<<"$out" >/dev/null \
    || fail "$route was published as a measurement instead of an error row: $out"
  no_secret "$out" "reading a $route response"
  no_traceback "reading a $route response"
done
pass

# Every profile with no --account, main included only once it has a login of its own.
out=$(run busy); rc=$?
[ "$rc" -eq 0 ] || fail "roster read: expected exit 0, got $rc"
[ "$(jq -r '[.accounts[].account] | join(",")' <<<"$out")" = "second,supergrok" ] \
  || fail "roster order or membership mismatch: $out"
write_auth "$WORK/home/.grok" "$TOKEN" "$REFRESH"
out=$(run busy)
[ "$(jq -r '[.accounts[].account] | join(",")' <<<"$out")" = "main,second,supergrok" ] \
  || fail "a logged-in ~/.grok was not listed as main: $out"
jq -e 'all(.accounts[]; .account != ".grokb")' <<<"$out" >/dev/null \
  || fail "the pool state directory was published as an account: $out"
# `main` names ~/.grok everywhere and --account main resolves there, so a hand-made profile under
# that name may not become a second row nothing can address.
mkdir -p "$PROFILES/main"
write_auth "$PROFILES/main" "$TOKEN" "$REFRESH"
out=$(run busy)
[ "$(jq -r '[.accounts[].account] | join(",")' <<<"$out")" = "main,second,supergrok" ] \
  || fail "a profile directory named main was published as a second main row: $out"
out=$(run busy --account main)
[ "$(jq -r '.accounts[0].email' <<<"$out")" = ".grok@example.com" ] \
  || fail "--account main did not resolve to ~/.grok: $out"
rm -rf "$PROFILES/main"
no_secret "$out" "reading the whole roster"
pass

# A roster mixing a readable account with an auth verdict is the normal call shape, and a measured
# row is what decides the exit code there.
mkdir -p "$PROFILES/no-login-yet"
out=$(run busy --account supergrok --account no-login-yet); rc=$?
[ "$rc" -eq 0 ] || fail "mixed roster: a measured row must win the exit code, got $rc"
jq -e '[.accounts[] | .account] == ["supergrok","no-login-yet"] and
  .accounts[0].used_pct == 61.2 and .accounts[1].auth == "needs_login"' <<<"$out" >/dev/null \
  || fail "mixed roster lost a row: $out"
out=$(run unauthorized --account second --account no-login-yet); rc=$?
[ "$rc" -eq 2 ] || fail "verdict-only roster: expected exit 2, got $rc"
rm -rf "$PROFILES/no-login-yet"
pass

# Stdout is JSON and nothing else, the same contract codex-quota.py and agy-quota.py hold: every
# reader of a vendor collector parses, and a human form would be a fourth surface to keep in step.
out=$(run busy --account supergrok)
jq -e '.accounts | length == 1' <<<"$out" >/dev/null || fail "stdout was not a JSON payload: $out"
[ "$(wc -l <<<"$out" | tr -d ' ')" -eq 1 ] || fail "stdout carried more than the payload: $out"
grep -q 'wk 61.2%' <<<"$out" && fail "the removed human form is still printed: $out"
no_secret "$out" "printing the payload"
pass

# The client version comes from the installed CLI, and a missing one is not a reason to fail.
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
printf '#!/usr/bin/env bash\nprintf "grok/1.2.3 darwin-arm64\\n"\n' >"$FAKE_BIN/grok"
chmod +x "$FAKE_BIN/grok"
env HOME="$WORK/home" PATH="$FAKE_BIN:$PATH" GROK_QUOTA_ENDPOINT="$BASE/busy?format=credits" \
  python3 "$HELPER" --profiles-dir "$PROFILES" --account supergrok >/dev/null 2>&1
[ "$(jq -r '.headers["x-grok-client-version"]' <<<"$(tail -n 1 "$HEADER_LOG")")" = "1.2.3" ] \
  || fail "the installed grok version did not reach the request header"
env HOME="$WORK/home" GROK_BIN="$WORK/no-such-grok" GROK_QUOTA_ENDPOINT="$BASE/busy?format=credits" \
  python3 "$HELPER" --profiles-dir "$PROFILES" --account supergrok >/dev/null 2>&1
[ "$(jq -r '.headers["x-grok-client-version"]' <<<"$(tail -n 1 "$HEADER_LOG")")" = "1.0.13" ] \
  || fail "a missing grok CLI did not fall back to the pinned client version"
pass

# The helper is a reader: auth.json must be byte-for-byte what it was, and no lock may be left.
before=$(shasum -a 256 "$PROFILES/supergrok/auth.json" | awk '{print $1}')
run busy >/dev/null
[ "$(shasum -a 256 "$PROFILES/supergrok/auth.json" | awk '{print $1}')" = "$before" ] \
  || fail "the helper rewrote auth.json"
[ ! -e "$PROFILES/supergrok/auth.json.lock" ] || fail "the helper left an auth.json lock behind"
pass

# Absent creditUsagePercent is still 0% when PRODUCT_GROK_BUILD is the only percent in the body.
out=$(run zero-build --account supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "absent creditUsagePercent with Build split: expected exit 0, got $rc"
jq -e '.accounts[0] | .used_pct == 0 and .build_pct == 18.5 and
  (has("plan_type") | not)' <<<"$out" >/dev/null \
  || fail "absent creditUsagePercent must stay 0% even with a Build split: $out"
no_secret "$out" "reading a zero-usage account that still splits Build"
pass

# used_pct is creditUsagePercent; body-level PRODUCT_GROK_BUILD is only build_pct, even when larger.
out=$(run prefer --account supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "credit+Build split: expected exit 0, got $rc"
jq -e '.accounts[0] | .used_pct == 10 and .build_pct == 90 and
  .plan_type == "SUBSCRIPTION_TIER_SUPERGROK"' <<<"$out" >/dev/null \
  || fail "creditUsagePercent must win used_pct over PRODUCT_GROK_BUILD: $out"
no_secret "$out" "preferring creditUsagePercent over the Build split"
pass

# Only persistent plan-wall wording turns a 402 into measured exhaustion.
for route in payment-required credits-exhausted rate-limit free-usage-exhausted; do
  out=$(run "$route" --account supergrok); rc=$?
  [ "$rc" -eq 0 ] || fail "$route: expected exit 0, got $rc"
  jq -e '.accounts[0] | .auth == "ok" and .used_pct == 100 and .resets_at == null and
    (has("error") | not)' <<<"$out" >/dev/null \
    || fail "$route was not mapped to the persistent-limit row: $out"
  no_secret "$out" "reading a $route response"
  no_traceback "reading a $route response"
done
out=$(run unknown-402 --account supergrok); rc=$?
[ "$rc" -eq 1 ] || fail "unknown 402: expected exit 1, got $rc"
jq -e '.accounts[0] | (.error | test("402")) and (has("auth") | not) and
  (has("used_pct") | not)' <<<"$out" >/dev/null \
  || fail "an unrecognized 402 body was not kept transient: $out"
no_secret "$out" "reading an unrecognized 402 response"
no_traceback "reading an unrecognized 402 response"
pass

# 429/503 are weather, the same class as 5xx: an error row, never a 100% wall and never auth.
for spec in too-many:429 unavailable:503; do
  route=${spec%:*}
  code=${spec##*:}
  out=$(run "$route" --account supergrok); rc=$?
  [ "$rc" -eq 1 ] || fail "$route: expected exit 1, got $rc"
  jq -e --arg code "$code" '.accounts[0] | (.error | test($code)) and
    (has("auth") | not) and (has("used_pct") | not)' <<<"$out" >/dev/null \
    || fail "$route was not a transient HTTP $code error: $out"
  no_secret "$out" "reading a $route response"
  no_traceback "reading a $route response"
done
pass

# Truncated JSON is the same class as garbage: a clean error row, never a traceback.
out=$(run truncated --account supergrok); rc=$?
[ "$rc" -eq 1 ] || fail "truncated JSON: expected exit 1, got $rc"
jq -e '.accounts[0] | (.error | test("unparsable")) and (has("auth") | not) and
  (has("used_pct") | not)' <<<"$out" >/dev/null \
  || fail "truncated JSON was not a clean error row: $out"
no_secret "$out" "parsing truncated JSON"
no_traceback "parsing truncated JSON"
pass

# Auth failure wordings ride on HTTP 401 and must stay an auth verdict, never a wall or a weather row.
for route in not-signed-in session-expired; do
  out=$(run "$route" --account supergrok); rc=$?
  [ "$rc" -eq 2 ] || fail "$route with a refresh token: expected exit 2, got $rc"
  jq -e '.accounts[0] | .auth == "expired" and (.cause | test("401")) and
    (has("used_pct") | not) and (has("error") | not)' <<<"$out" >/dev/null \
    || fail "$route with a refresh token was not an auth error: $out"
  no_secret "$out" "reading $route with a refresh token"
  out=$(run "$route" --account second); rc=$?
  [ "$rc" -eq 2 ] || fail "$route without a refresh token: expected exit 2, got $rc"
  jq -e '.accounts[0] | .auth == "needs_login" and (has("used_pct") | not) and
    (has("error") | not)' <<<"$out" >/dev/null \
    || fail "$route without a refresh token must demand a login: $out"
  no_secret "$out" "reading $route without a refresh token"
done
pass

# Malformed or missing weekly period fields drop resets_at/period and keep the percent; they must not crash.
out=$(run no-period --account supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "missing currentPeriod: expected exit 0, got $rc"
jq -e '.accounts[0] | .used_pct == 22.5 and .resets_at == null and
  (has("period") | not) and .auth == "ok"' <<<"$out" >/dev/null \
  || fail "missing currentPeriod crashed or dropped the percent: $out"
no_secret "$out" "reading a body with no currentPeriod"
# `end` is the field resets_at is taken from: an unparsable one must leave resets_at unstated
# rather than hand every limits surface a word it will render as a time.
out=$(run bad-period --account supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "malformed period end: expected exit 0, got $rc"
jq -e '.accounts[0] | .used_pct == 33 and .resets_at == null and
  (has("period") | not) and .auth == "ok"' <<<"$out" >/dev/null \
  || fail "an unparsable period end was published verbatim or lost the percent: $out"
no_secret "$out" "reading a malformed period end"
out=$(run empty-end --account supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "empty period end: expected exit 0, got $rc"
jq -e '.accounts[0] | .used_pct == 33 and .resets_at == null and
  .period == "USAGE_PERIOD_TYPE_WEEKLY" and .auth == "ok"' <<<"$out" >/dev/null \
  || fail "an empty period end did not leave resets_at unstated: $out"
no_secret "$out" "reading an empty period end"
out=$(run period-not-object --account supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "currentPeriod as a string: expected exit 0, got $rc"
jq -e '.accounts[0] | .used_pct == 4 and .resets_at == null and
  (has("period") | not) and .auth == "ok"' <<<"$out" >/dev/null \
  || fail "a non-object currentPeriod crashed or dropped the percent: $out"
no_secret "$out" "reading a non-object currentPeriod"
no_traceback "reading a degraded weekly period"
pass

printf 'PASS: %s grok-quota tests\n' "$passed"
