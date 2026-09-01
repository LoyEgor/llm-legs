#!/usr/bin/env bash
# bin/llm-reset-redeem against local stand-ins for both backends: a fake grok.com and a fake
# `codex` binary. Neither vendor's real write is ever called, because it spends a one-per-period
# consumable on the owner's own account. Every profile, token and collector here is a fixture.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REDEEM="$ROOT/bin/llm-reset-redeem"
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
out=$(redeem claude/notcom); rc=$?
[ "$rc" -eq 4 ] || fail "claude: expected exit 4, got $rc"
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

# Every run leaves a line where the other bin tools log, and none of them carries a token.
[ -s "$WORK/claudeb/reset-redeem.log" ] || fail "no run was logged"
grep -q "$TOKEN" "$WORK/claudeb/reset-redeem.log" && fail "the log carries an access token"
grep -q 'grok/supergrok' "$WORK/claudeb/reset-redeem.log" \
  || fail "the log does not name what was redeemed"
pass

printf 'PASS: %s llm-reset-redeem tests\n' "$passed"
