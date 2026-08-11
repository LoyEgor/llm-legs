#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/llm-limits.sh"
WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

REAL_JQ=$(command -v jq) || fail "jq is required"
HOME_FIXTURE="$WORK/home"
PROFILES="$WORK/profiles"
GEMINI_CACHES="$WORK/gemini-caches"
CACHE="$WORK/limits.json"
mkdir -p "$HOME_FIXTURE" "$PROFILES/a" "$PROFILES/b" "$GEMINI_CACHES"

snapshot='{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.5,"resetTime":"2099-01-01T00:00:00Z"},{"window":"5h","remainingFraction":0.6,"resetTime":"2099-01-01T00:00:00Z"}]}]}'
printf '%s\n' "$snapshot" >"$WORK/gemini-main.json"
printf '%s\n' "$snapshot" >"$GEMINI_CACHES/a.json"
printf '%s\n' "$snapshot" >"$GEMINI_CACHES/b.json"

common_env=(HOME="$HOME_FIXTURE" GEMINIB_PROFILES_DIR="$PROFILES"
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$GEMINI_CACHES"
  LLM_LIMITS_GEMINI_CACHE="$WORK/gemini-main.json"
  LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_CODEX_REFRESH=0
  LLM_LIMITS_CACHE="$CACHE" LLM_STORE_LOCK_DELAY=0.02 LLM_STORE_LOCK_RETRIES=1000)

env "${common_env[@]}" bash "$SCRIPT" --json >/dev/null || fail "fixture cache creation failed"
cache_tmp="$WORK/limits-with-errors.json"
"$REAL_JQ" '.vendors.gemini.accounts |= map(
  if .account == "a" or .account == "b"
  then .refresh_error = {cause:"old",at:1}
  else . end)' "$CACHE" >"$cache_tmp" || fail "fixture cache update failed"
mv "$cache_tmp" "$CACHE"

JQ_BIN="$WORK/bin"
SIGNALS="$WORK/signals"
mkdir -p "$JQ_BIN" "$SIGNALS"
cat >"$JQ_BIN/jq" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$LLM_LIMITS_CACHE" ]; then
    : >"$LLM_TEST_SIGNALS/$PPID"
    break
  fi
done
exec "$LLM_TEST_REAL_JQ" "$@"
EOF
chmod +x "$JQ_BIN/jq"

mkdir "$CACHE.lock"
env "${common_env[@]}" PATH="$JQ_BIN:$PATH" LLM_TEST_REAL_JQ="$REAL_JQ" \
  LLM_TEST_SIGNALS="$SIGNALS" bash "$SCRIPT" --refresh-account gemini/a --json \
  >"$WORK/a.out" 2>"$WORK/a.err" &
pid_a=$!
env "${common_env[@]}" PATH="$JQ_BIN:$PATH" LLM_TEST_REAL_JQ="$REAL_JQ" \
  LLM_TEST_SIGNALS="$SIGNALS" bash "$SCRIPT" --refresh-account gemini/b --json \
  >"$WORK/b.out" 2>"$WORK/b.err" &
pid_b=$!
for _ in $(seq 1 200); do
  [ "$(find "$SIGNALS" -type f | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 0.02
done
[ "$(find "$SIGNALS" -type f | wc -l | tr -d ' ')" -ge 2 ] || fail "collectors did not read the shared initial state"
kill -0 "$pid_a" 2>/dev/null || fail "first collector skipped the live lock"
kill -0 "$pid_b" 2>/dev/null || fail "second collector skipped the live lock"
rmdir "$CACHE.lock"
wait "$pid_a" || fail "first concurrent collector failed"
wait "$pid_b" || fail "second concurrent collector failed"
"$REAL_JQ" -e '[.vendors.gemini.accounts[] |
  select((.account == "a" or .account == "b") and .refresh_error.cause == "refresh disabled")] |
  length == 2' "$CACHE" >/dev/null || fail "concurrent account updates were lost"

mkdir "$CACHE.lock"
touch -t 202001010000 "$CACHE.lock"
env "${common_env[@]}" LLM_STORE_LOCK_STALE_SECONDS=1 bash "$SCRIPT" --json >/dev/null \
  || fail "stale lock blocked the writer"
[ ! -e "$CACHE.lock" ] || fail "stale lock was not recovered"

mkdir "$CACHE.lock"
before=$(shasum -a 256 "$CACHE" | awk '{print $1}')
env "${common_env[@]}" bash "$SCRIPT" --json >"$WORK/wait.out" 2>"$WORK/wait.err" &
waiter=$!
sleep 0.2
kill -0 "$waiter" 2>/dev/null || fail "writer silently skipped a fresh lock"
[ "$(shasum -a 256 "$CACHE" | awk '{print $1}')" = "$before" ] || fail "writer changed the cache while another lock was live"
rmdir "$CACHE.lock"
wait "$waiter" || fail "waiting writer failed after lock release"
[ ! -e "$CACHE.lock" ] || fail "waiting writer left its lock behind"

mkdir "$CACHE.lock"
env "${common_env[@]}" LLM_STORE_LOCK_RETRIES=1 bash "$SCRIPT" --no-write --json >/dev/null \
  || fail "read-only collector tried to acquire the store lock"
rmdir "$CACHE.lock"

OWNER_LOCK="$WORK/owner.lock"
bash -c '. "$1/share/store-lock.sh"; store_lock_acquire "$2"' _ "$ROOT" "$OWNER_LOCK" \
  || fail "acquire on a free lock failed"
[ -d "$OWNER_LOCK" ] || fail "acquire did not create the lock directory"
grep -qE '^[0-9]+$' "$OWNER_LOCK/pid" || fail "acquire did not record an owner pid"
bash -c '. "$1/share/store-lock.sh"; store_lock_release "$2"' _ "$ROOT" "$OWNER_LOCK"
[ -d "$OWNER_LOCK" ] || fail "release by a non-owner deleted a live lock"
rm -rf "$OWNER_LOCK"
bash -c '. "$1/share/store-lock.sh"
  store_lock_acquire "$2" || exit 1
  store_lock_release "$2"' _ "$ROOT" "$OWNER_LOCK" \
  || fail "owner acquire/release cycle failed"
[ ! -e "$OWNER_LOCK" ] || fail "owner release did not clear its own lock"

RACE_LOCK="$WORK/race.lock"
RACE_LOG="$WORK/race.log"
GO="$WORK/race.go"
mkdir "$RACE_LOCK"
touch -t 200001010000 "$RACE_LOCK"
: >"$RACE_LOG"
for _ in 1 2 3 4; do
  env LLM_STORE_LOCK_STALE_SECONDS=60 LLM_STORE_LOCK_RETRIES=1 LLM_STORE_LOCK_DELAY=0.02 \
    bash -c '. "$1/share/store-lock.sh"
      while [ ! -e "$4" ]; do :; done
      store_lock_acquire "$2" || exit 0
      printf "enter %s\n" "$$" >>"$3"
      sleep 0.3
      printf "leave %s\n" "$$" >>"$3"
      store_lock_release "$2"' _ "$ROOT" "$RACE_LOCK" "$RACE_LOG" "$GO" &
done
: >"$GO"
wait
[ "$(grep -c '^enter' "$RACE_LOG")" -eq 1 ] || \
  fail "racing waiters did not settle on a single stale-lock winner"
[ "$(grep -c '^leave' "$RACE_LOG")" -eq 1 ] || fail "the stale-lock winner did not finish"
[ ! -e "$RACE_LOCK" ] || fail "the stale-lock winner left its lock behind"

CAPTURE_LOCK="$WORK/capture.lock"
mkdir "$CAPTURE_LOCK"
sleep 30 &
capture_pid=$!
printf '%s\n' "$capture_pid" >"$CAPTURE_LOCK/pid"
env LLM_STORE_LOCK_STALE_SECONDS=60 LLM_STORE_LOCK_RETRIES=2 LLM_STORE_LOCK_DELAY=0.02 \
  bash -c '. "$1/share/store-lock.sh"
    store_lock_mtime() { case "$1" in *.break.*) date +%s ;; *) printf "0\n" ;; esac; }
    store_lock_acquire "$2"' _ "$ROOT" "$CAPTURE_LOCK" \
  && fail "acquire kept a lock a racer had recreated between the staleness probe and the capture"
[ -d "$CAPTURE_LOCK" ] || fail "the captured newborn lock was discarded instead of restored"
grep -qx "$capture_pid" "$CAPTURE_LOCK/pid" || fail "the restored lock lost its owner"
[ -z "$(find "$WORK" -maxdepth 1 -name 'capture.lock.break.*')" ] || \
  fail "a captured lock directory was left aside"
kill "$capture_pid" 2>/dev/null
wait "$capture_pid" 2>/dev/null
rm -rf "$CAPTURE_LOCK"

DEAD_LOCK="$WORK/dead.lock"
mkdir "$DEAD_LOCK"
sleep 0 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
printf '%s\n' "$dead_pid" >"$DEAD_LOCK/pid"
env LLM_STORE_LOCK_STALE_SECONDS=600 LLM_STORE_LOCK_RETRIES=1 LLM_STORE_LOCK_DELAY=0.02 \
  bash -c '. "$1/share/store-lock.sh"; store_lock_acquire "$2"' _ "$ROOT" "$DEAD_LOCK" \
  || fail "a lock whose holder has exited was not broken before the grace ran out"
grep -qx "$dead_pid" "$DEAD_LOCK/pid" && fail "the dead holder kept ownership of the lock"
rm -rf "$DEAD_LOCK"

LIVE_LOCK="$WORK/live.lock"
mkdir "$LIVE_LOCK"
sleep 30 &
live_pid=$!
printf '%s\n' "$live_pid" >"$LIVE_LOCK/pid"
old_stamp=$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '-10 minutes' +%Y%m%d%H%M)
touch -t "$old_stamp" "$LIVE_LOCK"
env LLM_STORE_LOCK_STALE_SECONDS=1 LLM_STORE_LOCK_RETRIES=2 LLM_STORE_LOCK_DELAY=0.02 \
  bash -c '. "$1/share/store-lock.sh"; store_lock_acquire "$2"' _ "$ROOT" "$LIVE_LOCK" \
  && fail "a running holder lost its lock once the directory aged past the grace"
grep -qx "$live_pid" "$LIVE_LOCK/pid" || fail "the running holder lost ownership of its lock"
touch -t "$old_stamp" "$LIVE_LOCK"
env LLM_STORE_LOCK_STALE_SECONDS=1 LLM_STORE_LOCK_CEILING_SECONDS=60 LLM_STORE_LOCK_RETRIES=1 \
  LLM_STORE_LOCK_DELAY=0.02 \
  bash -c '. "$1/share/store-lock.sh"; store_lock_acquire "$2"' _ "$ROOT" "$LIVE_LOCK" \
  || fail "a lock older than the pid-reuse ceiling stayed unbreakable"
kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null
rm -rf "$LIVE_LOCK"

CLAIM_LOCK="$WORK/claim-foreign.lock"
mkdir "$CLAIM_LOCK"
printf '%s\n' 424242 >"$CLAIM_LOCK/pid"
chmod 444 "$CLAIM_LOCK/pid"
bash -c '. "$1/share/store-lock.sh"; store_lock_claim "$2"' _ "$ROOT" "$CLAIM_LOCK" \
  && fail "a failed pid write still reported ownership"
[ -d "$CLAIM_LOCK" ] || fail "a failed pid write removed a lock another pid owns"
grep -qx 424242 "$CLAIM_LOCK/pid" || fail "another holder's pid file did not survive"
chmod 644 "$CLAIM_LOCK/pid"
rm -rf "$CLAIM_LOCK"

MISMATCH_LOCK="$WORK/claim-mismatch.lock"
mkdir "$MISMATCH_LOCK"
ln -s /dev/null "$MISMATCH_LOCK/pid"
bash -c '. "$1/share/store-lock.sh"; store_lock_claim "$2"' _ "$ROOT" "$MISMATCH_LOCK" \
  && fail "a pid that did not read back still reported ownership"
[ -d "$MISMATCH_LOCK" ] || fail "a readback mismatch removed a lock that is not ours"
rm -rf "$MISMATCH_LOCK"

CLEANUP_LOCK="$WORK/claim-cleanup.lock"
mkdir "$CLEANUP_LOCK"
chmod 500 "$CLEANUP_LOCK"
bash -c '. "$1/share/store-lock.sh"; store_lock_claim "$2"' _ "$ROOT" "$CLEANUP_LOCK" \
  && fail "a lock with no pid file reported ownership"
[ ! -e "$CLEANUP_LOCK" ] || fail "a claim that wrote no pid left its own lock behind"

echo "PASS: shared store lock (10 checks)"
