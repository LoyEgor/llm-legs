#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/llm-reset-redeem against local stand-ins for both backends: a fake grok.com and a fake
# `codex` binary. Neither vendor's real write is ever called, because it spends a one-per-period
# consumable on the owner's own account. Every profile, token and collector here is a fixture.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REDEEM="$ROOT/bin/llm-reset-redeem"
WORK="$(mktemp -d)"
SERVER_PID=''
CLAUDE_SERVER_PID=''
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  [ -z "$CLAUDE_SERVER_PID" ] || kill "$CLAUDE_SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); }

TOKEN='grok-access-token-SENTINEL-must-never-be-printed'
ROTATED='grok-rotated-token-SENTINEL'
REFRESH='grok-refresh-token-SENTINEL'
CALL_LOG="$WORK/calls.log"
STATE="$WORK/state"

cat >"$WORK/server.py" <<'PY'
import http.server
import json
import sys
import threading
import time

CALL_LOG = sys.argv[1]
PORT_FILE = sys.argv[2]
STATE = sys.argv[3]


def varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def delimited(field, payload):
    return varint(field << 3 | 2) + varint(len(payload)) + payload


def reset_token(token_id, start, end):
    return (delimited(10, token_id.encode())
            + delimited(20, b"\x08" + varint(start))
            + delimited(30, b"\x08" + varint(end)))


def frame(payload):
    return b"\x00" + len(payload).to_bytes(4, "big") + payload


def trailer(status="0"):
    raw = ("grpc-status: %s\r\n" % status).encode()
    return b"\x80" + len(raw).to_bytes(4, "big") + raw


ONE = frame(delimited(10, reset_token("restok_vpYDqo", 1786560540, 1789238940))) + trailer()
NONE = frame(b"") + trailer()
# Listed latest-first, so spending `tokens[0]` would let the deadline the menu shows lapse.
TWO = frame(delimited(10, reset_token("restok_later", 1786560540, 1799238940))
            + delimited(10, reset_token("restok_soon", 1786560540, 1789238940))) + trailer()


def mode():
    with open(STATE) as handle:
        return handle.read().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        method = self.path.rsplit("/", 1)[-1]
        with open(CALL_LOG, "a") as handle:
            handle.write(json.dumps({
                "method": method, "body": body.hex(),
                "authorization": self.headers.get("Authorization", "")}) + "\n")
        case = mode()
        if case == "expired-until-rotated":
            # The touch rewrites auth.json; the poller only gets past this once it presents the
            # token that rotation produced.
            if "rotated" in self.headers.get("Authorization", ""):
                case = "one"
            else:
                self.reply(401, {"error": "unauthorized"})
                return
        if case == "one":
            self.grpc(200, ONE if method == "GetRemainingResets" else NONE)
        elif case == "two":
            self.grpc(200, TWO if method == "GetRemainingResets" else NONE)
        elif case == "none":
            self.grpc(200, NONE)
        elif case == "expired":
            self.reply(401, {"error": "unauthorized"})
        elif case == "weather":
            self.reply(503, {"error": "Service Unavailable"})
        elif case == "redeem-weather":
            if method == "GetRemainingResets":
                self.grpc(200, ONE)
            else:
                self.reply(503, {"error": "Service Unavailable"})
        else:
            self.reply(404, {"error": "unknown"})

    def grpc(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/grpc-web+proto")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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

printf 'one\n' >"$STATE"
python3 "$WORK/server.py" "$CALL_LOG" "$WORK/port" "$STATE" &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$WORK/port" ] && break
  sleep 0.2
done
PORT=$(cat "$WORK/port" 2>/dev/null || true)
[ -n "$PORT" ] || fail "the local ConsumerUiSvc stand-in never bound a port"
BASE="http://127.0.0.1:$PORT"

PROFILES="$WORK/grok-profiles"
mkdir -p "$PROFILES/supergrok"
write_auth() {
  printf '{"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828":{"key":"%s","refresh_token":"%s","user_id":"u-1","email":"owner@example.com","expires_at":1788000000}}\n' \
    "$1" "$REFRESH" >"$PROFILES/supergrok/auth.json"
}
write_auth "$TOKEN"

REFRESH_LOG="$WORK/refresh.log"
GROKB_LOG="$WORK/grokb.log"
cat >"$WORK/fake-collector.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$REFRESH_LOG"
exit \${FAKE_COLLECTOR_RC:-0}
EOF
chmod +x "$WORK/fake-collector.sh"
# The one sanctioned way to renew a grok token: the vendor's own CLI, which rewrites auth.json as a
# side effect of any authenticated subcommand. Never a hand-rolled POST to the token endpoint.
cat >"$WORK/fake-grokb.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$GROKB_LOG"
printf '{"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828":{"key":"$ROTATED","refresh_token":"$REFRESH","user_id":"u-1","email":"owner@example.com","expires_at":1799000000}}\n' \
  >"$PROFILES/supergrok/auth.json"
EOF
chmod +x "$WORK/fake-grokb.sh"

LOG="$WORK/reset-redeem.log"
redeem() {
  env HOME="$WORK/home" CLAUDEB_DIR="$WORK/claudeb" \
    GROKB_PROFILES_DIR="$PROFILES" GROK_RESETS_ENDPOINT="$BASE" \
    GROK_QUOTA_ENDPOINT="$BASE/never-read" \
    LLM_RESET_REDEEM_COLLECTOR="$WORK/fake-collector.sh" \
    LLM_RESET_REDEEM_GROKB="$WORK/fake-grokb.sh" \
    "$REDEEM" "$@" 2>"$WORK/last.err"
}

no_secret() {
  case "$1" in
    *"$TOKEN"*|*"$ROTATED"*|*"$REFRESH"*) fail "a token leaked into $2" ;;
  esac
  grep -q "$TOKEN" "$WORK/last.err" && fail "the token leaked into stderr while $2"
  return 0
}

# A vendor with no redeem RPC is a state, not an error to guess at: it says so by name.
out=$(redeem gemini/main); rc=$?
[ "$rc" -eq 4 ] || fail "gemini: expected exit 4, got $rc"
grep -q 'NO_REDEEM_BACKEND' <<<"$out$(cat "$WORK/last.err")" \
  || fail "gemini did not name NO_REDEEM_BACKEND: $out $(cat "$WORK/last.err")"
[ ! -s "$CALL_LOG" ] || fail "a vendor with no backend still called the reset service"
out=$(redeem opencode/main); rc=$?
[ "$rc" -eq 4 ] || fail "opencode: expected exit 4, got $rc"
out=$(redeem grok); rc=$?
[ "$rc" -eq 2 ] || fail "a target with no account: expected exit 2, got $rc"
pass

# Nothing to redeem is its own answer, and it may never reach RedeemReset.
printf 'none\n' >"$STATE"
: >"$CALL_LOG"
out=$(redeem grok/supergrok); rc=$?
[ "$rc" -eq 2 ] || fail "empty reset list: expected exit 2, got $rc"
grep -q 'no usage reset' <<<"$out$(cat "$WORK/last.err")" \
  || fail "an empty reset list was not reported: $out $(cat "$WORK/last.err")"
grep -q RedeemReset "$CALL_LOG" && fail "an empty reset list still called RedeemReset"
[ ! -s "$REFRESH_LOG" ] || fail "a redeem that never happened still refreshed the account"
pass

# The redeem itself: one read, one write carrying the token_id the read named, then the targeted
# refresh that moves the menubar's number.
printf 'one\n' >"$STATE"
: >"$CALL_LOG"
out=$(redeem grok/supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "redeem: expected exit 0, got $rc ($(cat "$WORK/last.err"))"
grep -q 'usage reset redeemed' <<<"$out" || fail "the redeem printed no outcome line: $out"
grep -q '0 left' <<<"$out" || fail "the redeem did not report what the service left: $out"
[ "$(grep -c GetRemainingResets "$CALL_LOG")" -eq 1 ] \
  || fail "the redeem did not read the remaining resets exactly once: $(cat "$CALL_LOG")"
[ "$(grep -c RedeemReset "$CALL_LOG")" -eq 1 ] \
  || fail "the redeem did not spend exactly one consumable: $(cat "$CALL_LOG")"
# `restok_vpYDqo` length-delimited in field 10 — the grant id the read handed back, verbatim.
grep RedeemReset "$CALL_LOG" | grep -q '520d726573746f6b5f76705944716f' \
  || fail "RedeemReset carried no token_id frame: $(cat "$CALL_LOG")"
grep -qx -- '--refresh-account grok/supergrok' "$REFRESH_LOG" \
  || fail "the redeem did not trigger the targeted refresh: $(cat "$REFRESH_LOG")"
no_secret "$out" "redeeming a reset"
pass

# With two grants in hand the one that lapses first is spent — that is the deadline the poller
# published and the menu is showing, and taking the other one lets it expire unused.
printf 'two\n' >"$STATE"
: >"$CALL_LOG"; : >"$REFRESH_LOG"
out=$(redeem grok/supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "two grants: expected exit 0, got $rc ($(cat "$WORK/last.err"))"
redeem_body=$(grep RedeemReset "$CALL_LOG")
grep -q '520b726573746f6b5f736f6f6e' <<<"$redeem_body" \
  || fail "the soonest-lapsing grant was not the one spent: $redeem_body"
grep -q '726573746f6b5f6c61746572' <<<"$redeem_body" \
  && fail "the later grant was spent instead: $redeem_body"
pass

# A refresh that failed is not a redeem that failed: the consumable is spent either way, and
# reporting an error would send the owner to redeem it a second time.
: >"$REFRESH_LOG"
out=$(FAKE_COLLECTOR_RC=1 redeem grok/supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "a failed refresh must not turn a spent redeem into a failure, got $rc"
grep -q 'quota re-read failed' <<<"$out" || fail "a failed refresh was not reported at all: $out"
pass

# An expired access token is the CLI's own to heal: one touch, one retry, and never a hand-rolled
# token POST. The retry runs on the token rotation produced, not on the one that was refused.
printf 'expired-until-rotated\n' >"$STATE"
: >"$CALL_LOG"; : >"$GROKB_LOG"; : >"$REFRESH_LOG"
write_auth "$TOKEN"
out=$(redeem grok/supergrok); rc=$?
[ "$rc" -eq 0 ] || fail "expired token: expected the touch to heal it, got exit $rc ($out)"
grep -qx 'supergrok exec models' "$GROKB_LOG" \
  || fail "the expired token was not healed through the vendor CLI: $(cat "$GROKB_LOG")"
[ "$(wc -l <"$GROKB_LOG" | tr -d ' ')" -eq 1 ] \
  || fail "the CLI touch ran more than once: $(cat "$GROKB_LOG")"
grep -q "Bearer $ROTATED" "$CALL_LOG" || fail "the retry did not use the rotated token"
grep -qx -- '--refresh-account grok/supergrok' "$REFRESH_LOG" \
  || fail "the healed redeem did not refresh the account"
no_secret "$out" "healing an expired token"
pass

# A token still refused after the one touch is the owner's to fix, and the tool says how.
printf 'expired\n' >"$STATE"
: >"$CALL_LOG"; : >"$GROKB_LOG"; : >"$REFRESH_LOG"
write_auth "$TOKEN"
out=$(redeem grok/supergrok); rc=$?
[ "$rc" -eq 3 ] || fail "a token refused after the touch: expected exit 3, got $rc"
grep -q 'grokb supergrok exec models' "$WORK/last.err" \
  || fail "exit 3 did not name the command that heals it: $(cat "$WORK/last.err")"
[ "$(wc -l <"$GROKB_LOG" | tr -d ' ')" -eq 1 ] \
  || fail "a still-refused token was touched more than once: $(cat "$GROKB_LOG")"
grep -q RedeemReset "$CALL_LOG" && fail "a refused read still tried to spend the consumable"
[ ! -s "$REFRESH_LOG" ] || fail "a failed redeem still refreshed the account"
no_secret "$out" "reporting a refused token"
pass

# Weather is never a verdict and never a second attempt: a 5xx on the read stops before the write,
# and a 5xx on the write is left ambiguous rather than retried into a double spend.
printf 'weather\n' >"$STATE"
: >"$CALL_LOG"; : >"$GROKB_LOG"
write_auth "$TOKEN"
out=$(redeem grok/supergrok); rc=$?
[ "$rc" -eq 5 ] || fail "a 503 on the read: expected exit 5, got $rc"
[ ! -s "$GROKB_LOG" ] || fail "weather was treated as an auth problem and touched the CLI"
grep -q RedeemReset "$CALL_LOG" && fail "a failed read still tried to spend the consumable"
printf 'redeem-weather\n' >"$STATE"
: >"$CALL_LOG"
out=$(redeem grok/supergrok); rc=$?
[ "$rc" -eq 5 ] || fail "a 503 on the write: expected exit 5, got $rc"
[ "$(grep -c RedeemReset "$CALL_LOG")" -eq 1 ] \
  || fail "an ambiguous redeem was retried: $(cat "$CALL_LOG")"
no_secret "$out" "reporting weather"
pass

# A profile nobody is logged into cannot be healed by a touch, so it asks for a login instead.
mkdir -p "$PROFILES/never-logged-in"
: >"$GROKB_LOG"
out=$(redeem grok/never-logged-in); rc=$?
[ "$rc" -eq 3 ] || fail "a profile with no auth.json: expected exit 3, got $rc"
grep -q 'grokb add never-logged-in' "$WORK/last.err" \
  || fail "a logged-out profile was not told to log in: $(cat "$WORK/last.err")"
[ ! -s "$GROKB_LOG" ] || fail "a logged-out profile was touched instead of asked to log in"
pass

# --- codex: the same contract over the app-server channel, against a fake `codex` binary ---
CODEX_STATE="$WORK/codex-state"
CODEX_CALL_LOG="$WORK/codex-calls.log"
CREDIT_ID='RateLimitResetCredit_fixture'
cat >"$WORK/fake-codex.sh" <<EOF
#!/usr/bin/env bash
while IFS= read -r line; do
  case "\$line" in
    *account/rateLimits/read*)
      printf '%s\n' "read" >>"$CODEX_CALL_LOG"
      if [ "\$(cat "$CODEX_STATE")" = summary ]; then
        jq -cn '{jsonrpc:"2.0",id:2,result:{
          rateLimits:{primary:{usedPercent:10,windowDurationMins:300,resetsAt:0},
                      secondary:{usedPercent:20,windowDurationMins:10080,resetsAt:0},planType:"plus"},
          rateLimitResetCredits:{availableCount:2}}}'
      else
        jq -cn '{jsonrpc:"2.0",id:2,result:{
          rateLimits:{primary:{usedPercent:10,windowDurationMins:300,resetsAt:0},
                      secondary:{usedPercent:20,windowDurationMins:10080,resetsAt:0},planType:"plus"},
          rateLimitResetCredits:{availableCount:1,credits:[
            {id:"spent-one",status:"redeemed",expiresAt:1},
            {id:"$CREDIT_ID",resetType:"codexRateLimits",status:"available",expiresAt:1789949804}]}}}'
      fi
      exit 0 ;;
    *rateLimitResetCredit/consume*)
      printf '%s\n' "\$line" >>"$CODEX_CALL_LOG"
      case "\$(cat "$CODEX_STATE")" in
        reset) jq -cn '{jsonrpc:"2.0",id:2,result:{outcome:"reset"}}' ;;
        already) jq -cn '{jsonrpc:"2.0",id:2,result:{outcome:"alreadyRedeemed"}}' ;;
        nothing) jq -cn '{jsonrpc:"2.0",id:2,result:{outcome:"nothingToReset"}}' ;;
        falsy) jq -cn '{jsonrpc:"2.0",id:2,result:{nothingToReset:false,outcome:"reset"}}' ;;
        *) sleep 10 ;;
      esac
      exit 0 ;;
  esac
done
EOF
chmod +x "$WORK/fake-codex.sh"
codex_redeem() {
  env HOME="$WORK/home" CLAUDEB_DIR="$WORK/claudeb" \
    CODEX_BIN="$WORK/fake-codex.sh" CODEX_QUOTA_TIMEOUT=3 \
    LLM_RESET_REDEEM_COLLECTOR="$WORK/fake-collector.sh" \
    "$REDEEM" "$@" 2>"$WORK/last.err"
}

# The read names the only credit still available, and the write carries exactly that id plus a
# non-empty idempotency key — the vendor refuses either one empty.
printf 'reset\n' >"$CODEX_STATE"
: >"$CODEX_CALL_LOG"; : >"$REFRESH_LOG"
out=$(codex_redeem codex/main); rc=$?
[ "$rc" -eq 0 ] || fail "codex redeem: expected exit 0, got $rc ($(cat "$WORK/last.err"))"
grep -q 'usage reset redeemed' <<<"$out" || fail "the codex redeem printed no outcome line: $out"
grep -q 'unrecognized outcome' <<<"$out" && fail "a known outcome was reported as unrecognized: $out"
[ "$(grep -c '^read$' "$CODEX_CALL_LOG")" -eq 1 ] \
  || fail "the codex redeem did not read the credits exactly once: $(cat "$CODEX_CALL_LOG")"
consume=$(grep consume "$CODEX_CALL_LOG")
[ "$(wc -l <<<"$consume" | tr -d ' ')" -eq 1 ] \
  || fail "the codex redeem did not consume exactly once: $consume"
[ "$(jq -r '.params.creditId' <<<"$consume")" = "$CREDIT_ID" ] \
  || fail "the consume did not carry the available credit's id: $consume"
[ -n "$(jq -r '.params.idempotencyKey // ""' <<<"$consume")" ] \
  || fail "the consume carried an empty idempotency key: $consume"
grep -qx -- '--refresh-account codex/main' "$REFRESH_LOG" \
  || fail "the codex redeem did not trigger the targeted refresh: $(cat "$REFRESH_LOG")"
pass

# The key is derived from the credit, not drawn fresh, so a reply lost in transit costs nothing:
# clicking again presents the same key and the vendor answers it instead of spending a second reset.
printf 'reset\n' >"$CODEX_STATE"
: >"$CODEX_CALL_LOG"
codex_redeem codex/main >/dev/null
first_key=$(grep consume "$CODEX_CALL_LOG" | jq -r '.params.idempotencyKey')
: >"$CODEX_CALL_LOG"
codex_redeem codex/main >/dev/null
[ "$(grep consume "$CODEX_CALL_LOG" | jq -r '.params.idempotencyKey')" = "$first_key" ] \
  || fail "a second run drew a fresh idempotency key: $first_key"
: >"$CODEX_CALL_LOG"
codex_redeem codex/nexerod >/dev/null 2>&1
[ "$(grep consume "$CODEX_CALL_LOG" | jq -r '.params.idempotencyKey')" != "$first_key" ] \
  || fail "two accounts shared one idempotency key"
pass

# Answered under our own key, `alreadyRedeemed` says the earlier attempt landed — a redeem, not a
# no-op, and the quota re-read is exactly what a user who clicked twice is waiting for.
printf 'already\n' >"$CODEX_STATE"
: >"$CODEX_CALL_LOG"; : >"$REFRESH_LOG"
out=$(codex_redeem codex/main); rc=$?
[ "$rc" -eq 0 ] || fail "an already-redeemed credit under our own key: expected exit 0, got $rc"
grep -q 'already landed' <<<"$out" || fail "the outcome was not explained: $out"
grep -qx -- '--refresh-account codex/main' "$REFRESH_LOG" \
  || fail "a landed redeem did not re-read the quota: $(cat "$REFRESH_LOG")"
pass

# A field name is not an answer: `nothingToReset: false` alongside `outcome: "reset"` is a reset.
printf 'falsy\n' >"$CODEX_STATE"
: >"$CODEX_CALL_LOG"; : >"$REFRESH_LOG"
out=$(codex_redeem codex/main); rc=$?
[ "$rc" -eq 0 ] || fail "a falsy negative field turned a spent reset into a no-op: exit $rc"
grep -qx -- '--refresh-account codex/main' "$REFRESH_LOG" \
  || fail 'a spent reset was not followed by the quota re-read'
pass

# A real negative outcome still is one.
printf 'nothing\n' >"$CODEX_STATE"
: >"$CODEX_CALL_LOG"; : >"$REFRESH_LOG"
out=$(codex_redeem codex/main); rc=$?
[ "$rc" -eq 2 ] || fail "nothingToReset: expected exit 2, got $rc"
[ ! -s "$REFRESH_LOG" ] || fail "a redeem that spent nothing still refreshed the account"
pass

# The count and the credit id come from two halves of one payload: a summary without the array
# leaves a reset this tool cannot name, and saying "nothing to redeem" would contradict the menu.
printf 'summary\n' >"$CODEX_STATE"
: >"$CODEX_CALL_LOG"; : >"$REFRESH_LOG"
out=$(codex_redeem codex/main); rc=$?
[ "$rc" -eq 2 ] || fail "a summary-only payload: expected exit 2, got $rc"
grep -q 'credit details' <<<"$out$(cat "$WORK/last.err")" \
  || fail "a summary-only payload did not say what was missing: $(cat "$WORK/last.err")"
grep -q 'vendor UI' <<<"$out$(cat "$WORK/last.err")" \
  || fail "a summary-only payload did not say where to redeem: $(cat "$WORK/last.err")"
grep -q consume "$CODEX_CALL_LOG" && fail "a summary-only payload still tried to consume"
pass

# No `codex` binary is a broken machine, not a Python traceback: the menubar shows this line.
: >"$CODEX_CALL_LOG"
out=$(env HOME="$WORK/home" CLAUDEB_DIR="$WORK/claudeb" CODEX_BIN="$WORK/no-such-codex" \
  CODEX_QUOTA_TIMEOUT=3 LLM_RESET_REDEEM_COLLECTOR="$WORK/fake-collector.sh" \
  "$REDEEM" codex/main 2>"$WORK/last.err"); rc=$?
[ "$rc" -eq 5 ] || fail "an unrunnable codex binary: expected exit 5, got $rc"
grep -q Traceback "$WORK/last.err" && fail "the tool died with a traceback: $(cat "$WORK/last.err")"
[ "$(wc -l <"$WORK/last.err" | tr -d ' ')" -eq 1 ] \
  || fail "the failure was not one human line: $(cat "$WORK/last.err")"
pass

# A consume that never answers is ambiguous, never a second attempt.
printf 'timeout\n' >"$CODEX_STATE"
: >"$CODEX_CALL_LOG"; : >"$REFRESH_LOG"
out=$(codex_redeem codex/main); rc=$?
[ "$rc" -eq 5 ] || fail "a consume that timed out: expected exit 5, got $rc"
[ "$(grep -c consume "$CODEX_CALL_LOG")" -eq 1 ] \
  || fail "an ambiguous consume was retried: $(cat "$CODEX_CALL_LOG")"
[ ! -s "$REFRESH_LOG" ] || fail "a redeem that never landed still refreshed the account"
pass

# --- claude: the cedar_ember program over a local stand-in for api.anthropic.com ---
CLAUDE_TOKEN='claude-access-token-SENTINEL-must-never-be-printed'
CLAUDE_STATE="$WORK/claude-state"
CLAUDE_CALL_LOG="$WORK/claude-calls.log"
CLAUDE_HOME="$WORK/claude-home"
ORG='5d3c1a2b-0000-4000-8000-00000000c1a0'
mkdir -p "$CLAUDE_HOME/.claude-profiles/notcom" "$CLAUDE_HOME/.claude-profiles/nokeychain" "$WORK/bin"
for profile in notcom nokeychain; do
  printf '{"oauthAccount":{"organizationUuid":"%s"}}\n' "$ORG" \
    >"$CLAUDE_HOME/.claude-profiles/$profile/.claude.json"
done
NOTCOM_SERVICE="Claude Code-credentials-$(printf '%s' "$CLAUDE_HOME/.claude-profiles/notcom" \
  | shasum -a 256 | cut -c1-8)"
cat >"$WORK/bin/security" <<EOF
#!/usr/bin/env bash
[ "\$1" = find-generic-password ] && [ "\$3" = "$NOTCOM_SERVICE" ] || exit 44
printf '{"claudeAiOauth":{"accessToken":"$CLAUDE_TOKEN","refreshToken":"r","expiresAt":4102444800000}}\n'
EOF
chmod +x "$WORK/bin/security"

cat >"$WORK/claude-server.py" <<'PY'
import http.server
import json
import sys
import threading
import time

CALL_LOG, PORT_FILE, STATE = sys.argv[1:4]


def grant(grant_id, ends_at, resets_left=1, **extra):
    return {"id": grant_id, "resets_total": 1, "resets_left": resets_left,
            "starts_at": "2026-09-22T16:00:00+00:00", "ends_at": ends_at,
            "clears": ["five_hour", "seven_day"], "paused": False, "usable_now": True,
            "use_requires_limit": False, **extra}


def program(grants, next_grant_id=None):
    return {"eligible": True, "ineligible_reason": None, "at_limit": False, "exhausted": [],
            "grants": grants, "next_grant_id": next_grant_id,
            "weekly_resets_at": "2026-09-27T05:00:00+00:00", "cooldown_until": None}


ONE = program([grant("opus55-launch-team-20260921", "2026-10-22T16:00:00+00:00")],
              "opus55-launch-team-20260921")
# Listed latest-first, so taking grants[0] would let the deadline the menu shows lapse.
TWO_SOONEST = program([grant("grant-later", "2026-12-01T00:00:00+00:00"),
                       grant("grant-soon", "2026-10-01T00:00:00+00:00")])
TWO_NEXT = program([grant("grant-soon", "2026-10-01T00:00:00+00:00"),
                    grant("grant-named", "2026-12-01T00:00:00+00:00")], "grant-named")
MULTI = [program([grant("grant-multi", "2026-10-22T16:00:00+00:00", left)]) for left in (1, 2)]
READS = {"one": ONE, "already": ONE, "post429": ONE, "post503": ONE, "soonest": TWO_SOONEST,
         "multi503": MULTI[1], "multiafter": MULTI[0],
         "next": TWO_NEXT, "empty": program([]),
         "zero": program([grant("spent-grant", "2026-10-22T16:00:00+00:00", 0)]),
         "null": None}


def mode():
    with open(STATE) as handle:
        return handle.read().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def record(self, body):
        with open(CALL_LOG, "a") as handle:
            handle.write(json.dumps({
                "method": self.command, "path": self.path, "body": body,
                "authorization": self.headers.get("Authorization", ""),
                "beta": self.headers.get("anthropic-beta", "")}) + "\n")

    def do_GET(self):
        self.record(None)
        case = mode()
        if case == "get401":
            return self.reply(401, {"error": "unauthorized"})
        if not self.path.startswith("/api/oauth/usage"):
            return self.reply(404, {"error": "unknown"})
        self.reply(200, {"five_hour": {"utilization": 10, "resets_at": None},
                         "seven_day": {"utilization": 20, "resets_at": None},
                         "cedar_ember": READS.get(case)})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode()
        self.record(body)
        case = mode()
        if case == "post429":
            return self.reply(429, {"error": "rate_limited"})
        if case in ("post503", "multi503"):
            return self.reply(503, {"error": "overloaded"})
        if case == "already":
            return self.reply(200, {"result": "already_used"})
        self.reply(200, {"result": "reset", "resets_left": 0, "cleared": ["five_hour", "seven_day"]})

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
printf 'one\n' >"$CLAUDE_STATE"
python3 "$WORK/claude-server.py" "$CLAUDE_CALL_LOG" "$WORK/claude-port" "$CLAUDE_STATE" &
CLAUDE_SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$WORK/claude-port" ] && break
  sleep 0.2
done
[ -s "$WORK/claude-port" ] || fail "the local api.anthropic.com stand-in never bound a port"
CLAUDE_BASE="http://127.0.0.1:$(cat "$WORK/claude-port")"
claude_redeem() {
  env HOME="$CLAUDE_HOME" CLAUDEB_DIR="$WORK/claudeb" PATH="$WORK/bin:$PATH" \
    CLAUDE_RESETS_ENDPOINT="$CLAUDE_BASE" \
    LLM_RESET_REDEEM_COLLECTOR="$WORK/fake-collector.sh" \
    "$REDEEM" "$@" 2>"$WORK/last.err"
}
claude_posts() { grep -c '"method": "POST"' "$CLAUDE_CALL_LOG"; }
claude_post_field() { grep '"method": "POST"' "$CLAUDE_CALL_LOG" | tail -1 | jq -r '.body' | jq -r "$1"; }
claude_no_secret() {
  case "$1" in *"$CLAUDE_TOKEN"*) fail "the claude token leaked into $2" ;; esac
  grep -q "$CLAUDE_TOKEN" "$WORK/last.err" && fail "the claude token leaked into stderr while $2"
  return 0
}

# One read of the usage body with the program asked for, one write naming the program, the grant
# the read handed back and a request id in the shape the server accepts, then the targeted refresh.
printf 'one\n' >"$CLAUDE_STATE"
: >"$CLAUDE_CALL_LOG"; : >"$REFRESH_LOG"
out=$(claude_redeem claude/notcom); rc=$?
[ "$rc" -eq 0 ] || fail "claude redeem: expected exit 0, got $rc ($(cat "$WORK/last.err"))"
grep -q 'usage reset redeemed' <<<"$out" || fail "the claude redeem printed no outcome line: $out"
grep -q '"method": "GET", "path": "/api/oauth/usage?cedar_ember=1"' "$CLAUDE_CALL_LOG" \
  || fail "the claude read did not ask for cedar_ember: $(cat "$CLAUDE_CALL_LOG")"
[ "$(claude_posts)" -eq 1 ] || fail "the claude redeem did not POST exactly once: $(cat "$CLAUDE_CALL_LOG")"
grep '"method": "POST"' "$CLAUDE_CALL_LOG" \
  | grep -q "\"path\": \"/api/organizations/$ORG/reset_rate_limits\"" \
  || fail "the claude POST did not target the profile's organization: $(cat "$CLAUDE_CALL_LOG")"
[ "$(claude_post_field .program)" = cedar_ember ] || fail "the POST named the wrong program"
[ "$(claude_post_field .grant_id)" = opus55-launch-team-20260921 ] \
  || fail "the POST did not carry the read's grant: $(claude_post_field .grant_id)"
first_request=$(claude_post_field .request_id)
grep -Eq '^[A-Za-z0-9_-]{1,64}$' <<<"$first_request" \
  || fail "the request id is outside the server's shape: $first_request"
grep '"method": "POST"' "$CLAUDE_CALL_LOG" | grep -q "\"authorization\": \"Bearer $CLAUDE_TOKEN\", \"beta\": \"oauth-2025-04-20\"" \
  || fail "the claude POST did not carry the keychain token and the oauth beta header"
grep -qx -- '--refresh-account claude/notcom' "$REFRESH_LOG" \
  || fail "the claude redeem did not trigger the targeted refresh: $(cat "$REFRESH_LOG")"
claude_no_secret "$out" "redeeming a claude reset"
reset_at=$(cat "$WORK/claudeb/limits/notcom.reset-at" 2>/dev/null)
[ -n "$reset_at" ] && [ "$(( $(date +%s) - reset_at ))" -lt 60 ] \
  || fail "a claude redeem left no reset marker for the statusline merge: '$reset_at'"
pass

# The request id is derived, never drawn: a re-click after a lost reply presents the same one.
: >"$CLAUDE_CALL_LOG"
claude_redeem claude/notcom >/dev/null
[ "$(claude_post_field .request_id)" = "$first_request" ] \
  || fail "a second claude run drew a fresh request id"
pass

# Answered under our own request id, already_used means the earlier attempt landed.
printf 'already\n' >"$CLAUDE_STATE"
: >"$CLAUDE_CALL_LOG"; : >"$REFRESH_LOG"
out=$(claude_redeem claude/notcom); rc=$?
[ "$rc" -eq 0 ] || fail "claude already_used: expected exit 0, got $rc"
[ "$(claude_posts)" -eq 1 ] || fail "already_used was not exactly one POST: $(cat "$CLAUDE_CALL_LOG")"
grep -q 'already landed' <<<"$out" || fail "already_used was not explained: $out"
grep -qx -- '--refresh-account claude/notcom' "$REFRESH_LOG" \
  || fail "a landed claude redeem did not re-read the quota"
pass

# Nothing to redeem — no grants, a spent grant, or no program at all — never reaches the POST.
for state in empty zero null; do
  printf '%s\n' "$state" >"$CLAUDE_STATE"
  : >"$CLAUDE_CALL_LOG"; : >"$REFRESH_LOG"
  out=$(claude_redeem claude/notcom); rc=$?
  [ "$rc" -eq 2 ] || fail "claude $state: expected exit 2, got $rc ($(cat "$WORK/last.err"))"
  [ "$(claude_posts)" -eq 0 ] || fail "claude $state still POSTed: $(cat "$CLAUDE_CALL_LOG")"
  [ ! -s "$REFRESH_LOG" ] || fail "claude $state still refreshed the account"
done
pass

# next_grant_id wins; without one, the soonest ends_at is spent whatever the listing order.
printf 'next\n' >"$CLAUDE_STATE"
: >"$CLAUDE_CALL_LOG"
claude_redeem claude/notcom >/dev/null || fail "claude next_grant_id: redeem failed"
[ "$(claude_post_field .grant_id)" = grant-named ] \
  || fail "next_grant_id was not the grant spent: $(claude_post_field .grant_id)"
printf 'soonest\n' >"$CLAUDE_STATE"
: >"$CLAUDE_CALL_LOG"
claude_redeem claude/notcom >/dev/null || fail "claude soonest: redeem failed"
[ "$(claude_post_field .grant_id)" = grant-soon ] \
  || fail "the soonest-lapsing grant was not the one spent: $(claude_post_field .grant_id)"
pass

# A refused token is the owner's to fix: no POST, no refresh from this path, a one-line hint.
printf 'get401\n' >"$CLAUDE_STATE"
: >"$CLAUDE_CALL_LOG"; : >"$REFRESH_LOG"
out=$(claude_redeem claude/notcom); rc=$?
[ "$rc" -eq 3 ] || fail "claude 401: expected exit 3, got $rc"
[ "$(claude_posts)" -eq 0 ] || fail "a refused claude read still POSTed"
[ ! -s "$REFRESH_LOG" ] || fail "a refused claude read still refreshed the account"
grep -q 'press Refresh' "$WORK/last.err" || fail "exit 3 gave no hint: $(cat "$WORK/last.err")"
[ "$(wc -l <"$WORK/last.err" | tr -d ' ')" -eq 1 ] \
  || fail "the claude 401 was not one human line: $(cat "$WORK/last.err")"
claude_no_secret "$out" "reporting a refused claude token"
pass

# 429 and 5xx on the write are ambiguous: exit 5 after exactly one POST, never a second.
for state in post429 post503; do
  printf '%s\n' "$state" >"$CLAUDE_STATE"
  : >"$CLAUDE_CALL_LOG"; : >"$REFRESH_LOG"
  out=$(claude_redeem claude/notcom); rc=$?
  [ "$rc" -eq 5 ] || fail "claude $state: expected exit 5, got $rc"
  [ "$(claude_posts)" -eq 1 ] || fail "claude $state was retried: $(cat "$CLAUDE_CALL_LOG")"
  [ ! -s "$REFRESH_LOG" ] || fail "claude $state still refreshed the account"
done
pass

# A reset that landed under a lost reply lowers resets_left; the re-click must still present the
# unanswered request id so it collides into already_used, and only an answered one moves the key on.
printf 'multi503\n' >"$CLAUDE_STATE"
: >"$CLAUDE_CALL_LOG"
claude_redeem claude/notcom >/dev/null
lost_request=$(claude_post_field .request_id)
printf 'multiafter\n' >"$CLAUDE_STATE"
: >"$CLAUDE_CALL_LOG"
claude_redeem claude/notcom >/dev/null || fail "claude re-click after a lost reply failed"
[ "$(claude_post_field .request_id)" = "$lost_request" ] \
  || fail "the re-click after a lost reply drew a new request id"
: >"$CLAUDE_CALL_LOG"
claude_redeem claude/notcom >/dev/null
[ "$(claude_post_field .request_id)" != "$lost_request" ] \
  || fail "an answered request id was presented again"
pass

# No keychain entry is a login to fix, found before anything reaches the network.
printf 'one\n' >"$CLAUDE_STATE"
: >"$CLAUDE_CALL_LOG"
out=$(claude_redeem claude/nokeychain); rc=$?
[ "$rc" -eq 3 ] || fail "claude without a keychain entry: expected exit 3, got $rc"
[ ! -s "$CLAUDE_CALL_LOG" ] || fail "a profile with no keychain entry still called the service"
pass

# --- auto-redeem: armed only by Egor's own words, fired at the account's main weekly wall ---
AUTO="$WORK/auto"
ARM="$AUTO/claudeb/reset-arm/claude-notcom"
SESSION="$AUTO/projects/-Volumes-proj/chat.jsonl"
mkdir -p "$(dirname "$SESSION")" "$AUTO/claudeb/limits" "$AUTO/codex-profiles/notcom" "$AUTO/grok-profiles/notcom"
printf '{}\n' >"$AUTO/claudeb/limits/notcom.json"
printf '{}\n' >"$AUTO/claudeb/limits/com.json"
export CODEXB_PROFILES_DIR="$AUTO/codex-profiles" GROKB_PROFILES_DIR="$AUTO/grok-profiles" GROKB_MAIN_GROK_HOME="$AUTO/no-grok"
SETUP="${CLAUDE_SETUP_ROOT:-$(. "$ROOT/share/test-scope.sh"; git_projects "$ROOT")/claude-setup}"
cat >"$AUTO/alert.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$AUTO/alerts"
EOF
chmod +x "$AUTO/alert.sh"
auto() {
  env HOME="$CLAUDE_HOME" CLAUDEB_DIR="$AUTO/claudeb" PATH="$WORK/bin:$PATH" \
    CLAUDE_RESETS_ENDPOINT="$CLAUDE_BASE" LLM_LIMITS_CACHE="$AUTO/limits.json" \
    LLM_RESET_REDEEM_ALERT="$AUTO/alert.sh" CHAT_NAME_ROOTS="$AUTO/projects" \
    CLAUDE_SETUP_ROOT="$SETUP" LLM_RESET_REDEEM_COLLECTOR="$WORK/fake-collector.sh" \
    "$REDEEM" "$@" >/dev/null 2>"$WORK/last.err"
}
store() { # weekly-pct five-hour-pct credits [fable-pct]
  local now; now=$(date +%s)
  jq -n --argjson w "$1" --argjson f "$2" --argjson c "$3" --argjson fb "${4:-0}" --argjson now "$now" '
    def bucket($p): {used_pct: $p, effective_pct: $p, resets_at: ($now + 259200), as_of: $now};
    {schema: 1, vendors: {
      claude: {accounts: [{account: "notcom", weekly: bucket($w), fable: bucket($fb),
                           five_hour: (bucket($f) | .resets_at = ($now + 7200)), reset_credits: $c},
                          {account: "com", weekly: bucket(10)}]},
      codex: {accounts: [{account: "notcom", weekly: bucket(10)}]},
      grok: {accounts: [{account: "notcom", weekly: bucket(10)}]}}}' >"$AUTO/limits.json"
}
say() { # type text [extra-json]
  jq -cn --arg t "$1" --arg x "$2" --argjson extra "${3:-{\}}" '
    if $t == "assistant" then {type: "assistant", message: {role: "assistant", content: [{type: "text", text: $x}]}}
    elif $t == "tool" then {type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: "t1", content: $x}]}}
    else {type: "user", message: {role: "user", content: $x}} end + $extra' >>"$SESSION"
}
fresh() { : >"$CLAUDE_CALL_LOG"; : >"$REFRESH_LOG"; : >"$AUTO/alerts"; }
backdate() { awk -v t=$(($(date +%s) - 700)) 'NR == 1 { print; next } { print t, $2 }' "$ARM" \
  >"$ARM.tmp" && mv "$ARM.tmp" "$ARM"; }
HIS='ок, сделай ресет claude notcom пожалуйста'
arm() { auto --arm claude/notcom --word 'сделай ресет claude notcom' || fail "his own words did not arm: $(cat "$WORK/last.err")"; }
say user "$HIS"
say assistant 'сделай ресет codex notcom'
say tool 'сделай ресет grok notcom'
say user 'сделай ресет claude com' '{"isMeta": true}'
printf 'one\n' >"$CLAUDE_STATE"
store 100 0 1

fresh
auto --fire-armed || fail "an unarmed fire exited nonzero"
[ ! -s "$CLAUDE_CALL_LOG" ] || fail "an unarmed weekly wall reached the reset service"
pass

# A bare name several vendors hold arms nothing from his prompt: it would spend a reset he did not mean.
read_out=$(env HOME="$CLAUDE_HOME" CLAUDEB_DIR="$AUTO/claudeb" LLM_LIMITS_CACHE="$AUTO/limits.json" \
  python3 -B - "$REDEEM" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("redeem", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)
print(" | ".join(module.arm_words([(None, "notcom")], "сделай ресет notcom", "test")))
PY
)
[ "$read_out" = "notcom: which vendor? claude, codex, grok" ] && [ -z "$(ls "$AUTO/claudeb/reset-arm" 2>/dev/null)" ] \
  || fail "a bare name held by several vendors armed or read wrong: '$read_out' $(ls "$AUTO/claudeb/reset-arm" 2>/dev/null)"
pass

# The CLI arm: his words, verbatim in a prompt of his from the last day, naming the account
# after a reset verb — never model text, a tool result or a meta message.
auto --arm claude/notcom; rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$ARM" ] || fail "an arm without his words was accepted (exit $rc)"
for refused in 'codex/notcom|сделай ресет codex notcom' 'grok/notcom|сделай ресет grok notcom' \
    'claude/com|сделай ресет claude com' 'claude/notcom|claude notcom пожалуйста' \
    'claude/com|сделай ресет claude notcom'; do
  auto --arm "${refused%%|*}" --word "${refused#*|}"; rc=$?
  [ "$rc" -ne 0 ] && [ -z "$(ls "$AUTO/claudeb/reset-arm" 2>/dev/null)" ] \
    || fail "--arm ${refused%%|*} --word '${refused#*|}' armed (exit $rc)"
done
touch -t 202001010000 "$SESSION"
auto --arm claude/notcom --word 'сделай ресет claude notcom'; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$ARM" ] || fail "words older than a day still armed"
touch "$SESSION"
arm
grep -Eq '^[0-9]+$' "$ARM" || fail "the arm holds no arm time: $(cat "$ARM" 2>&1)"
grep -q 'arm .*claude/notcom by cli (chat.jsonl) «сделай ресет claude notcom»' "$AUTO/claudeb/reset-redeem.log" \
  || fail "the arm did not journal who armed it and his words: $(cat "$AUTO/claudeb/reset-redeem.log")"
pass

fresh
auto --fire-armed || fail "an armed fire exited nonzero"
[ "$(claude_posts)" -eq 1 ] || fail "an armed weekly wall did not redeem exactly once: $(cat "$CLAUDE_CALL_LOG")"
[ ! -e "$ARM" ] || fail "a landed auto-redeem did not consume the arm"
grep -qx -- '--refresh-account claude/notcom' "$REFRESH_LOG" || fail "the auto-redeem did not re-read the quota"
[ "$(wc -l <"$AUTO/alerts" | tr -d ' ')" -eq 1 ] && grep -q 'usage reset redeemed' "$AUTO/alerts" \
  || fail "the auto-redeem did not alert exactly one line: $(cat "$AUTO/alerts")"
grep -q 'auto-fire' "$AUTO/claudeb/reset-redeem.log" || fail "the auto-redeem was not journaled"
fresh
auto --fire-armed
auto --fire-armed claude/notcom --wall weekly
[ ! -s "$CLAUDE_CALL_LOG" ] || fail "a later wall after the redeem called the service again"
pass

# His own phrasing, read by a model from the intake's hint: a reset word and the account's name arm
# it in any word order; a vendor his words did not name, or words without a reset word, do not.
FREE='когда claude notcom упрётся в недельный лимит, пусть сам произойдёт ресет'
say user "$FREE"
say user 'claude notcom снова упёрся в лимит'
for refused in "codex/notcom|$FREE" 'claude/notcom|claude notcom снова упёрся в лимит'; do
  auto --arm "${refused%%|*}" --word "${refused#*|}"; rc=$?
  [ "$rc" -eq 2 ] && [ -z "$(ls "$AUTO/claudeb/reset-arm" 2>/dev/null)" ] \
    || fail "--arm ${refused%%|*} --word '${refused#*|}' armed (exit $rc)"
done
auto --arm claude/notcom --word "$FREE" || fail "his own phrasing did not arm: $(cat "$WORK/last.err")"
[ -e "$ARM" ] || fail "his own phrasing left no arm"
auto --disarm claude/notcom
pass

# Only the main weekly bucket: a five-hour or fable wall never fires, by the store or a run, and a
# run that cannot name its bucket waits for the store.
arm
for case in '60 100 1 0|unknown' '60 0 1 100|unknown' '60 0 1 0|unknown'; do
  fresh; store ${case%%|*}
  auto --fire-armed claude/notcom --wall "${case#*|}"
  auto --fire-armed
  [ ! -s "$CLAUDE_CALL_LOG" ] || fail "store ${case%%|*} with a ${case#*|} run wall reached the reset service"
done
[ -e "$ARM" ] || fail "a wall that is not the weekly one dropped the arm"
pass

fresh; store 100 0 0
auto --fire-armed
[ ! -s "$CLAUDE_CALL_LOG" ] || fail "an armed wall with no credits reached the reset service"
[ -e "$ARM" ] || fail "no credits dropped the arm"
pass

# A run that names its weekly wall fires before the collector has read it.
fresh; store 60 0 1
auto --fire-armed claude/notcom --wall weekly
[ "$(claude_posts)" -eq 1 ] && [ ! -e "$ARM" ] || fail "a run-observed weekly wall did not redeem once and disarm"
pass

# A run's weekly wall that meets the collector holding the lock waits its turn: the collector reads
# every wall as unknown and, with the store not showing this one yet, redeems nothing.
arm
fresh; store 60 0 1
python3 -c 'import fcntl, sys, time
lock = open(sys.argv[1], "w"); fcntl.flock(lock, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(1.5)' \
  "$AUTO/claudeb/reset-arm/.lock" "$AUTO/held" &
holder=$!
until [ -e "$AUTO/held" ]; do sleep 0.05; done
auto --fire-armed claude/notcom --wall weekly
wait "$holder"
rm -f "$AUTO/held"
[ "$(claude_posts)" -eq 1 ] && [ ! -e "$ARM" ] || fail "a run's weekly wall behind the collector's lock was dropped"
pass

# A --disarm while a redeem is in flight stays disarmed when that redeem fails transiently.
arm
fresh; store 100 0 1
printf 'post503\n' >"$CLAUDE_STATE"
env HOME="$CLAUDE_HOME" CLAUDEB_DIR="$AUTO/claudeb" PATH="$WORK/bin:$PATH" \
  CLAUDE_RESETS_ENDPOINT="$CLAUDE_BASE" LLM_LIMITS_CACHE="$AUTO/limits.json" \
  LLM_RESET_REDEEM_ALERT="$AUTO/alert.sh" LLM_RESET_REDEEM_COLLECTOR="$WORK/fake-collector.sh" \
  python3 -B - "$REDEEM" <<'PY' >/dev/null 2>"$WORK/last.err" || fail "the in-flight disarm probe failed: $(cat "$WORK/last.err")"
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("redeem", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)
redeem = module.REDEEMERS["claude"]
def disarmed_meanwhile(account, target):
    code = redeem(account, target)
    module.main(["--disarm", target])
    return code
module.REDEEMERS["claude"] = disarmed_meanwhile
module.fire("claude", "notcom", int(time.time()), "weekly")
PY
[ "$(claude_posts)" -eq 1 ] && [ ! -e "$ARM" ] || fail "a transient redeem re-armed what --disarm dropped: $(cat "$ARM" 2>&1)"
printf 'one\n' >"$CLAUDE_STATE"
pass

# How a run names its bucket.
kind() { ( . "$ROOT/share/worker-walls.sh"; worker_walls_kind "$@" ); }
printf "You've hit your weekly limit · resets Oct 9, 9am\n" >"$AUTO/weekly.out"
printf "You've hit your Fable limit · resets Oct 9, 9am\n" >"$AUTO/fable.out"
printf "You've hit your session limit · resets 10:40pm\n" >"$AUTO/session.out"
[ "$(kind claudeb '' "$AUTO/weekly.out")" = weekly ] || fail "claude's weekly wall was not read as weekly"
for other in fable session; do
  [ "$(kind claudeb '' "$AUTO/$other.out")" = unknown ] || fail "claude's $other wall was read as weekly"
done
[ "$(kind codex $(($(date +%s) + 259200)))" = weekly ] || fail "a codex reset days out was not weekly"
[ "$(kind codex $(($(date +%s) + 7200)))" = unknown ] || fail "a codex five-hour reset was read as weekly"
[ "$(kind codex '')" = unknown ] || fail "an unparsed codex reset was read as weekly"
[ "$(kind grok '')" = weekly ] || fail "grok's only wall was not weekly"
pass

# Transient failure: at most three attempts, ten minutes apart, then disarmed with the reason.
arm
fresh; store 100 0 1
printf 'post503\n' >"$CLAUDE_STATE"
auto --fire-armed
auto --fire-armed
[ "$(claude_posts)" -eq 1 ] || fail "a transient failure was retried inside ten minutes: $(cat "$CLAUDE_CALL_LOG")"
[ -e "$ARM" ] || fail "one transient failure dropped the arm"
backdate; auto --fire-armed
backdate; auto --fire-armed
[ "$(claude_posts)" -eq 3 ] || fail "transient attempts were not three: $(claude_posts)"
[ ! -e "$ARM" ] || fail "three transient failures left the arm standing"
grep -q '3 attempts failed' "$AUTO/alerts" && [ "$(wc -l <"$AUTO/alerts" | tr -d ' ')" -eq 1 ] \
  || fail "the transient ladder did not alert its reason once: $(cat "$AUTO/alerts")"
auto --fire-armed
[ "$(claude_posts)" -eq 3 ] || fail "a disarmed account was tried a fourth time"
pass

# A refused token disarms at once, with the reason.
arm
fresh; printf 'get401\n' >"$CLAUDE_STATE"
auto --fire-armed
[ "$(claude_posts)" -eq 0 ] && [ ! -e "$ARM" ] && grep -q 'press Refresh' "$AUTO/alerts" \
  || fail "exit 3 did not disarm at once with its reason"
pass

# Fixture seams with the arms resolving to the default store never fire.
printf 'one\n' >"$CLAUDE_STATE"
mkdir -p "$CLAUDE_HOME/.claude-profiles/.claudeb/reset-arm"
date +%s >"$CLAUDE_HOME/.claude-profiles/.claudeb/reset-arm/claude-notcom"
fresh; store 100 0 1
env HOME="$CLAUDE_HOME" PATH="$WORK/bin:$PATH" CLAUDE_RESETS_ENDPOINT="$CLAUDE_BASE" \
  LLM_LIMITS_CACHE="$AUTO/limits.json" LLM_RESET_REDEEM_ALERT="$AUTO/alert.sh" \
  LLM_RESET_REDEEM_COLLECTOR="$WORK/fake-collector.sh" "$REDEEM" --fire-armed 2>/dev/null
[ ! -s "$CLAUDE_CALL_LOG" ] || fail "a fixture cache fired an arm in the default store"
pass

# Every run leaves a line where the other bin tools log, and none of them carries a token.
[ -s "$WORK/claudeb/reset-redeem.log" ] || fail "no run was logged"
grep -q "$TOKEN" "$WORK/claudeb/reset-redeem.log" && fail "the log carries an access token"
grep -q "$CLAUDE_TOKEN" "$WORK/claudeb/reset-redeem.log" && fail "the log carries the claude token"
grep -q 'grok/supergrok' "$WORK/claudeb/reset-redeem.log" \
  || fail "the log does not name what was redeemed"
pass

printf 'PASS: %s llm-reset-redeem tests\n' "$passed"
