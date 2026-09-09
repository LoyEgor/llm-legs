#!/usr/bin/env bash
# agy-quota.py against a stub agy: the login chooser flashes for a logged-in profile too, so it is
# a verdict only once it outlives the confirm window without the ready footer.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/agy-quota.py"
WORK="$(mktemp -d)"
trap 'pkill -f "$WORK/agy" 2>/dev/null; rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

cat >"$WORK/agy" <<'STUB'
#!/usr/bin/env python3
import http.server, json, os, sys, time

RPC_PATH = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
QUOTA = {"response": {"groups": [{"displayName": "Gemini Models", "buckets": [
    {"window": "5h", "remainingFraction": 0.9, "resetTime": "2026-09-10T00:00:00Z"},
    {"window": "weekly", "remainingFraction": 0.5, "resetTime": "2026-09-14T00:00:00Z"}]}]}}


def say(text):
    sys.stdout.write(text)
    sys.stdout.flush()


mode = os.environ.get("STUB_MODE", "stuck")
if mode == "exit":
    sys.exit(0)
say(" Welcome to the Antigravity CLI. You are currently not signed in.\n\n"
    " ⢷  Signing in...\n Select login method:\n\n > 1. Google OAuth\n"
    "2. Use a Google Cloud project\n\n↑/↓ Navigate · enter Select\n")
if mode == "stuck":
    while True:
        time.sleep(1)
time.sleep(0.4)
if mode == "cleared":
    say("\x1b[2J\x1b[H Loading workspace...\n")
    time.sleep(4)
say("\x1b[2J\x1b[H Gemini 3.8 Flash · ? for shortcuts\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.dumps(QUOTA if self.path == RPC_PATH else {"error": "unknown rpc"}).encode()
        self.send_response(200 if self.path == RPC_PATH else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", 0), Handler).serve_forever()
STUB
chmod +x "$WORK/agy"

now() { python3 -c 'import time; print(time.time())'; }
elapsed() { python3 -c 'import sys; print(float(sys.argv[2]) - float(sys.argv[1]))' "$1" "$2"; }
within() { python3 -c 'import sys; v, lo, hi = map(float, sys.argv[1:]); sys.exit(0 if lo <= v <= hi else 1)' "$1" "$2" "$3"; }

run_helper() {
  local mode=$1; shift
  started=$(now)
  rc=0
  env STUB_MODE="$mode" AGY_BIN="$WORK/agy" AGY_WORKDIR="$WORK" "$@" \
    python3 "$HELPER" >"$WORK/out" 2>"$WORK/err" || rc=$?
  took=$(elapsed "$started" "$(now)")
}

# A chooser that gives way to the ready footer is startup, not a logout: the RPC answers.
run_helper transient
assert test "$rc" -eq 0
assert jq -e '(.groups[0].buckets | length) == 2 and .groups[0].displayName == "Gemini Models"' "$WORK/out" >/dev/null
assert within "$took" 0 15
transient_took=$took

# A chooser cleared off the screen stops the confirm clock even when the ready footer is late.
run_helper cleared AGY_QUOTA_STARTUP_TIMEOUT=30 AGY_QUOTA_LOGIN_CONFIRM_TIMEOUT=2
assert test "$rc" -eq 0
assert jq -e '(.groups[0].buckets | length) == 2' "$WORK/out" >/dev/null
assert within "$took" 4 20

# A chooser still standing after the confirm window is the verdict, well before the startup timeout.
run_helper stuck AGY_QUOTA_STARTUP_TIMEOUT=30 AGY_QUOTA_LOGIN_CONFIRM_TIMEOUT=2
assert test "$rc" -eq 2
assert jq -e '.auth_needed == true and .detail == "login screen" and .source == "agy-local-rpc"' "$WORK/out" >/dev/null
assert within "$took" 2 15
stuck_took=$took

# The confirm window never outlives the startup deadline.
run_helper stuck AGY_QUOTA_STARTUP_TIMEOUT=3 AGY_QUOTA_LOGIN_CONFIRM_TIMEOUT=60
assert test "$rc" -eq 2
assert jq -e '.auth_needed == true and .detail == "login screen"' "$WORK/out" >/dev/null
assert within "$took" 3 12
capped_took=$took

# An agy that dies on start is a failed query, never a login verdict.
run_helper exit
assert test "$rc" -eq 1
assert test ! -s "$WORK/out"
assert jq -e '.error | test("agy exited during startup")' "$WORK/err" >/dev/null

echo "PASS: $asserts asserts; a flashed login chooser yields to the ready footer and the RPC answers (${transient_took%.*}s), a chooser cleared off the screen stops the confirm clock, a standing chooser is the login verdict once the confirm window passes (${stuck_took%.*}s) and never later than the startup deadline (${capped_took%.*}s), an agy dead on start is a failed query"
