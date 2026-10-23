#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# agy-quota.py against a stub agy: quota comes from print mode `/usage`, and a logged-out leg is
# the stderr line, read before the timeout, never a browser window.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/agy-quota.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0

cat >"$WORK/agy" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARG %s\n' "$@"
  printf 'OPEN=%s\n' "$(command -v open)"
  printf 'CWD=%s\n' "$PWD"
} >"$STUB_LOG"

usage_payload='{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t70%","duration_seconds":0,"num_turns":0,"usage":{"total_tokens":0},"command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit.","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","description":"","window":"weekly","remaining_fraction":0.7032511234283447,"reset_time":"2026-09-17T19:00:30Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","description":"","window":"5h","remaining_fraction":0.013935700058937073,"reset_time":"2026-09-12T16:41:01Z"}]},{"name":"Claude and GPT models","description":"Third-party models","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-09-19T12:35:05Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-09-12T17:35:05Z"}]}]}}}'

case "${STUB_MODE:-ok}" in
  ok)
    printf '%s\n' "$usage_payload"
    ;;
  nogemini)
    printf '%s\n' "${usage_payload//Gemini Models/Other Models}"
    ;;
  nologin)
    echo "$$" >"$STUB_PIDS"
    printf 'Authentication required. Please visit the URL to log in:\n' >&2
    printf 'https://accounts.google.com/o/oauth2/auth?client_id=stub\n' >&2
    sleep 60 &
    echo "$!" >>"$STUB_PIDS"
    wait
    ;;
  error)
    printf '%s\n' '{"conversation_id":"","status":"ERROR","response":"","error":"language server unavailable","duration_seconds":1,"num_turns":0}'
    ;;
  autherror)
    printf '%s\n' '{"conversation_id":"","status":"ERROR","response":"","error":"authentication failed or timed out","duration_seconds":1,"num_turns":0}'
    ;;
  garbage)
    printf 'Antigravity CLI starting...\nnot json at all\n'
    ;;
  ineligible)
    printf 'error: Eligibility check failed: Your current account is not eligible for Antigravity. Verify your account to continue.\n\nAlternatively, try signing in with another personal Google account.\n\nPlease verify your account in your browser to continue: https://accounts.google.com/signin/continue?stub\n' >&2
    exit 1
    ;;
  dies)
    printf 'boom\n' >&2
    exit 3
    ;;
esac
STUB
chmod +x "$WORK/agy"

now_ms() {
  suite_journal_ms "$1"
  [ -n "${!1}" ] || suite_journal_ms "$1" "$(python3 -c 'import time; print(time.time())')"
}

run_helper() {
  local mode=$1; shift
  : >"$WORK/stub.log"
  : >"$WORK/stub.pids"
  now_ms started
  rc=0
  env STUB_MODE="$mode" STUB_LOG="$WORK/stub.log" STUB_PIDS="$WORK/stub.pids" \
    AGY_BIN="$WORK/agy" AGY_WORKDIR="$WORK" "$@" \
    python3 "$HELPER" >"$WORK/out" 2>"$WORK/err" || rc=$?
  now_ms took
  took=$(( took - started ))
}

# Print mode answers with the structured /usage payload; the cache shape is the helper's own.
run_helper ok
assert test "$rc" -eq 0
assert jq -e '.description == "Within each group, models share a weekly limit." and
  (.groups | length) == 2 and .groups[0].displayName == "Gemini Models" and
  .groups[0].description == "Models within this group: Gemini Flash, Gemini Pro" and
  ([.groups[0].buckets[] | select(.window == "5h")][0] |
    .remainingFraction == 0.013935700058937073 and .resetTime == "2026-09-12T16:41:01Z" and
    .name == "Five Hour Limit Remaining") and
  ([.groups[0].buckets[] | select(.window == "weekly")][0].remainingFraction) == 0.7032511234283447 and
  .groups[1].displayName == "Claude and GPT models"' "$WORK/out" >/dev/null

# The argv and the browser muzzle are the contract with agy itself.
assert grep -qxF 'ARG -p' "$WORK/stub.log"
assert grep -qxF 'ARG /usage' "$WORK/stub.log"
assert grep -qxF 'ARG --output-format' "$WORK/stub.log"
assert grep -qxF 'ARG json' "$WORK/stub.log"
assert grep -qxF "OPEN=$(cd "$ROOT" && pwd -P)/share/no-browser/open" "$WORK/stub.log"
assert "$ROOT/share/no-browser/open" 'https://accounts.google.com/o/oauth2/auth?client_id=stub'

# A payload without a usable Gemini group is an unexpected response, never a quota.
run_helper nogemini
assert test "$rc" -eq 1
assert test ! -s "$WORK/out"
assert jq -e '.error | test("unexpected /usage response")' "$WORK/err" >/dev/null

# The login line on stderr is the verdict at once: waiting for the timeout would leave agy
# holding an OAuth prompt open for the whole window.
run_helper nologin AGY_QUOTA_TIMEOUT=60
assert test "$rc" -eq 2
assert jq -e '.auth_needed == true and .source == "agy-print-usage" and
  (.detail | test("Authentication required"))' "$WORK/out" >/dev/null
assert test "$took" -ge 0 -a "$took" -le 5000
suite_journal_secs nologin_took "$took"
stub_dead=1
while read -r pid; do
  [ -n "$pid" ] || continue
  for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || continue 2; sleep 0.05; done
  stub_dead=0
done <"$WORK/stub.pids"
assert test "$stub_dead" -eq 1

# An authentication failure reported inside the JSON is the same verdict.
run_helper autherror
assert test "$rc" -eq 2
assert jq -e '.auth_needed == true and (.detail | test("authentication"))' "$WORK/out" >/dev/null

# Google refusing the account until its owner verifies it (run dd96a57's abel) is a login verdict:
# as a failed query the menu kept the account healthy and the pool kept handing it out.
run_helper ineligible
assert test "$rc" -eq 2
assert jq -e '.auth_needed == true and (.detail | test("^error: Eligibility check failed"))' "$WORK/out" >/dev/null

# Any other reported error is a failed query, not a logout.
run_helper error
assert test "$rc" -eq 1
assert test ! -s "$WORK/out"
assert jq -e '.error == "language server unavailable" and .source == "agy-print-usage"' "$WORK/err" >/dev/null

# Output that is not JSON stays a failed query.
run_helper garbage
assert test "$rc" -eq 1
assert jq -e '.error | test("not JSON")' "$WORK/err" >/dev/null

# An agy that dies is a failed query, never a login verdict.
run_helper dies
assert test "$rc" -eq 1
assert test ! -s "$WORK/out"
assert jq -e '.error | test("agy exited with status 3")' "$WORK/err" >/dev/null

echo "PASS: $asserts asserts; print-mode /usage yields the cache shape with the browser muzzled, a login line on stderr is the verdict in ${nologin_took%.*}s and kills agy with it, an account Google wants verified is a login verdict, and an unusable payload, a reported error, non-JSON output or a dead agy all stay failed queries"
