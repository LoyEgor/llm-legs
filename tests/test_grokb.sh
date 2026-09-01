#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/grokb"
FAKE_GROK="$ROOT/tests/fixtures/fake-grok.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }

export HOME="$WORK/home"
export GROKB_PROFILES_DIR="$WORK/profiles"
export GROKB_GROK_BIN="$FAKE_GROK"
export GROK_CALLS="$WORK/grok-calls"
export WORKER_PICK_CONFIG_FILE="$WORK/worker-model"
export GROKB_QUOTA_CMD="$ROOT/tests/fixtures/fake-grok-quota.sh"
export FAKE_GROK_ROSTER='main alpha beta'
export LLM_LIMITS_GROK_CACHE="$WORK/llm-limits-grok.json"
mkdir -p "$HOME/.grok" "$GROKB_PROFILES_DIR"
: >"$GROK_CALLS"

unset GROK_WORKER GROK_HOME GROK_CLAUDE_MCPS_ENABLED GROK_CLAUDE_SKILLS_ENABLED GROK_DISABLE_AUTOUPDATER
export ANNOUNCE_LOG="$WORK/announce-log"
export LLM_LIMITS_ANNOUNCE_CMD="$WORK/fake-announce"
printf "#!/usr/bin/env bash\nprintf '%%s\\n' \"\$*\" >>\"\$ANNOUNCE_LOG\"\n" >"$LLM_LIMITS_ANNOUNCE_CMD"
chmod +x "$LLM_LIMITS_ANNOUNCE_CMD"
wait_announce() {
  local expected="$1" tries=0
  while [ "$tries" -lt 50 ]; do
    grep -qxF -- "$expected" "$ANNOUNCE_LOG" 2>/dev/null && return 0
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}

add_output=$(bash "$SCRIPT" add alpha) || fail "add alpha failed"
assert test -d "$GROKB_PROFILES_DIR/alpha"
assert grep -qF "GROK_HOME=$GROKB_PROFILES_DIR/alpha $FAKE_GROK login --device-auth" <<<"$add_output"
assert grep -qx 'Device authentication complete' <<<"$add_output"
assert grep -qx "CALL home=$GROKB_PROFILES_DIR/alpha mcps=<unset> skills=<unset> updater=<unset> worker=<unset> argc=2" "$GROK_CALLS"
assert grep -qx 'ARG=login' "$GROK_CALLS"
assert grep -qx 'ARG=--device-auth' "$GROK_CALLS"
assert wait_announce '--refresh-account grok/alpha'
assert_fails bash "$SCRIPT" add alpha >/dev/null 2>&1

assert_fails bash "$SCRIPT" add main >/dev/null 2>&1
for reserved in profile p run add remove list status pick help login enable disable use; do
  assert_fails bash "$SCRIPT" add "$reserved" >/dev/null 2>&1
  assert_fails bash "$SCRIPT" profile "$reserved" -p fixture >/dev/null 2>&1
done
assert_fails bash "$SCRIPT" add Bad >/dev/null 2>&1
assert_fails bash "$SCRIPT" profile ../escape -p fixture >/dev/null 2>&1
assert test ! -e "$WORK/escape"

# The pool state directory sits beside the accounts from the first `disable` on, so the listing is
# asked about it while it is really there.
mkdir -p "$GROKB_PROFILES_DIR/beta" "$GROKB_PROFILES_DIR/.grokb"
cat >"$GROKB_PROFILES_DIR/alpha/auth.json" <<'JSON'
{"issuer::client":{"email":"alpha@example.com","expires_at":"2026-09-01T12:00:00Z","key":"key-secret-sentinel","refresh_token":"refresh-secret-sentinel"}}
JSON
cat >"$GROKB_PROFILES_DIR/beta/auth.json" <<'JSON'
{"issuer::client":{"email":"beta@example.com","expires_at":"2026-09-02T13:00:00Z","key":"","refresh_token":""}}
JSON

list_output=$(bash "$SCRIPT" list) || fail "list failed"
assert grep -qx 'main: login needed' <<<"$list_output"
assert grep -qx 'alpha: Logged in as alpha@example.com' <<<"$list_output"
assert grep -qx 'beta: Logged in as beta@example.com (no refresh token)' <<<"$list_output"
assert_fails grep -q '^\.grokb:' <<<"$list_output"

# One line shape for every vendor wrapper: name, the vendor's own login state, the pool suffix,
# then the quota columns — `codexb status` and `geminib status` print the same frame with a 5H
# column grok has no bucket for. Token timestamps stay out of it: the CLI heals an expired access
# token itself, so only a missing refresh token is a human's business.
status_output=$(bash "$SCRIPT" status) || fail "status failed"
assert grep -qx 'main: login needed | WEEKLY - reset unknown' <<<"$status_output"
assert grep -qE '^alpha: Logged in as alpha@example\.com \| WEEKLY 61% reset ' <<<"$status_output"
assert grep -qE '^beta: Logged in as beta@example\.com \(no refresh token\) \| WEEKLY 61% reset ' <<<"$status_output"
assert_fails grep -q '5H' <<<"$status_output"
assert_fails grep -q '2026-09-01T12:00:00Z' <<<"$status_output"
assert_fails grep -q 'key-secret-sentinel' <<<"$status_output"
assert_fails grep -q 'refresh-secret-sentinel' <<<"$status_output"

RUN_OUT="$WORK/run.out"
run_grokb() { bash "$SCRIPT" "$@" >"$RUN_OUT" 2>&1; }
assert run_grokb disable alpha
assert grep -qx 'grokb: disabled alpha' "$RUN_OUT"
assert grep -qx alpha "$GROKB_PROFILES_DIR/.grokb/disabled"
assert grep -q 'alpha: Logged in as alpha@example.com (out of pool)' <<<"$(bash "$SCRIPT" list)"
assert grep -q 'alpha: .* (out of pool) | WEEKLY ' <<<"$(bash "$SCRIPT" status)"

# An interactive run is Egor, not a worker: only grok's headless flags answer to the pool, the way
# codexb gates on `exec` and geminib on `--print` — otherwise the menu's Log in… could not reach an
# account he took out of the pool.
: >"$GROK_CALLS"
assert bash "$SCRIPT" profile alpha login --device-auth
assert grep -qx "CALL home=$GROKB_PROFILES_DIR/alpha mcps=0 skills=0 updater=1 worker=<unset> argc=2" "$GROK_CALLS"
for invocation in 'profile alpha -p fixture' 'run alpha --prompt-file brief' 'alpha exec -p fixture'; do
  before=$(wc -l <"$GROK_CALLS")
  rc=0
  # shellcheck disable=SC2086
  bash "$SCRIPT" $invocation >"$RUN_OUT" 2>&1 || rc=$?
  assert test "$rc" -eq 2
  assert grep -q 'grok: alpha is out of the worker pool' "$RUN_OUT"
  assert test "$(wc -l <"$GROK_CALLS")" -eq "$before"
done

assert run_grokb enable alpha
assert grep -qx 'grokb: enabled alpha' "$RUN_OUT"
assert test ! -s "$GROKB_PROFILES_DIR/.grokb/disabled"
: >"$GROK_CALLS"
assert bash "$SCRIPT" profile alpha -p 'two words'
assert grep -qx "CALL home=$GROKB_PROFILES_DIR/alpha mcps=0 skills=0 updater=1 worker=1 argc=2" "$GROK_CALLS"
assert grep -qx 'ARG=-p' "$GROK_CALLS"
assert grep -qxF 'ARG=two\ words' "$GROK_CALLS"

: >"$GROK_CALLS"
assert bash "$SCRIPT" p alpha -p alias
assert grep -qx "CALL home=$GROKB_PROFILES_DIR/alpha mcps=0 skills=0 updater=1 worker=1 argc=2" "$GROK_CALLS"
assert grep -qx 'ARG=alias' "$GROK_CALLS"

: >"$GROK_CALLS"
assert bash "$SCRIPT" run alpha --prompt-file "$WORK/brief"
assert grep -qx "CALL home=$GROKB_PROFILES_DIR/alpha mcps=0 skills=0 updater=1 worker=1 argc=2" "$GROK_CALLS"
assert grep -qx 'ARG=--prompt-file' "$GROK_CALLS"

: >"$GROK_CALLS"
assert bash "$SCRIPT" alpha exec -p fixture
assert grep -qx "CALL home=$GROKB_PROFILES_DIR/alpha mcps=0 skills=0 updater=1 worker=1 argc=2" "$GROK_CALLS"
assert_fails grep -qx 'ARG=exec' "$GROK_CALLS"

: >"$GROK_CALLS"
assert env GROK_HOME=poison bash "$SCRIPT" run main -p fixture
assert grep -qx 'CALL home=<unset> mcps=0 skills=0 updater=1 worker=1 argc=2' "$GROK_CALLS"

assert run_grokb disable --all
assert test "$(LC_ALL=C sort "$GROKB_PROFILES_DIR/.grokb/disabled")" = $'alpha\nbeta\nmain'
assert run_grokb enable --all
assert test ! -s "$GROKB_PROFILES_DIR/.grokb/disabled"
assert_fails run_grokb disable missing
assert_fails run_grokb enable missing

printf 'worker=auto\nclaudeb_profile=other\n' >"$WORKER_PICK_CONFIG_FILE"
assert bash "$SCRIPT" use alpha
assert grep -qx 'grok_profile=alpha' "$WORKER_PICK_CONFIG_FILE"
assert grep -qx 'claudeb_profile=other' "$WORKER_PICK_CONFIG_FILE"
assert test "$(grep -c '^grok_profile=' "$WORKER_PICK_CONFIG_FILE")" -eq 1
assert grep -qx 'grokb: workers are pinned to alpha' <<<"$(bash "$SCRIPT" use)"
# The pin is reported by `use`, exactly where codexb and geminib report theirs; status carries no
# second spelling of it.
assert_fails grep -q 'pin=' <<<"$(bash "$SCRIPT" status)"
assert run_grokb disable alpha
: >"$GROK_CALLS"
assert bash "$SCRIPT" profile alpha -p pinned
assert grep -q "CALL home=$GROKB_PROFILES_DIR/alpha" "$GROK_CALLS"
assert bash "$SCRIPT" use --clear
assert_fails grep -q '^grok_profile=' "$WORKER_PICK_CONFIG_FILE"
assert_fails bash "$SCRIPT" use missing >/dev/null 2>&1
assert run_grokb enable alpha

# Top-level auth.json (the shape grok-quota.py reads first) is still a live login.
mkdir -p "$GROKB_PROFILES_DIR/gamma"
printf '%s\n' '{"email":"gamma@example.com","key":"gamma-key","refresh_token":"gamma-refresh"}' \
  >"$GROKB_PROFILES_DIR/gamma/auth.json"
assert grep -qx 'gamma: Logged in as gamma@example.com' <<<"$(bash "$SCRIPT" list)"
assert_fails bash "$SCRIPT" remove gamma >/dev/null 2>&1
assert test -d "$GROKB_PROFILES_DIR/gamma"
assert bash "$SCRIPT" remove gamma --force >/dev/null

# Multiple top-level entries: any nested key/refresh is a live login.
mkdir -p "$GROKB_PROFILES_DIR/delta"
printf '%s\n' '{"issuer::a":{"email":"delta@example.com","key":"delta-key","refresh_token":""},"issuer::b":{"email":"other@example.com","key":"","refresh_token":""}}' \
  >"$GROKB_PROFILES_DIR/delta/auth.json"
assert grep -qx 'delta: Logged in as delta@example.com (no refresh token)' <<<"$(bash "$SCRIPT" list)"
assert_fails bash "$SCRIPT" remove delta >/dev/null 2>&1
assert test -d "$GROKB_PROFILES_DIR/delta"
assert bash "$SCRIPT" remove delta --force >/dev/null

# Unparseable auth.json: fail closed, same as codexb — never an unguarded delete.
mkdir -p "$GROKB_PROFILES_DIR/epsilon"
printf 'not json\n' >"$GROKB_PROFILES_DIR/epsilon/auth.json"
assert_fails bash "$SCRIPT" remove epsilon >/dev/null 2>&1
assert test -d "$GROKB_PROFILES_DIR/epsilon"
assert bash "$SCRIPT" remove epsilon --force >/dev/null

assert_fails bash "$SCRIPT" remove alpha >/dev/null 2>&1
assert test -d "$GROKB_PROFILES_DIR/alpha"
printf '{"accounts":[{"account":"alpha","used_pct":61.2},{"account":"beta","used_pct":10}]}\n' \
  >"$LLM_LIMITS_GROK_CACHE"
# The removals above already wrote the collector's empty line, so the announce this removal owes
# is only observable against a truncated log.
: >"$ANNOUNCE_LOG"
remove_output=$(bash "$SCRIPT" remove alpha --force) || fail "remove alpha failed"
assert grep -qx 'grokb: removed alpha' <<<"$remove_output"
assert test ! -e "$GROKB_PROFILES_DIR/alpha"
# A cached row outliving its account keeps every surface reading a percentage for an account that
# is gone; codexb and geminib prune theirs on removal too.
assert test "$(jq -r '[.accounts[].account] | join(",")' "$LLM_LIMITS_GROK_CACHE")" = beta
assert wait_announce ''
assert_fails bash "$SCRIPT" remove main >/dev/null 2>&1
assert_fails bash "$SCRIPT" remove ../escape >/dev/null 2>&1

remove_output=$(bash "$SCRIPT" remove beta) || fail "remove beta failed"
assert grep -qx 'grokb: removed beta' <<<"$remove_output"
assert test ! -e "$GROKB_PROFILES_DIR/beta"
assert_fails "$FAKE_GROK" unknown-subcommand >/dev/null 2>&1

: >"$ANNOUNCE_LOG"
: >"$GROK_CALLS"
fresh_output=$(bash "$SCRIPT" profile fresh -p fixture 2>&1) || fail "profile fresh failed"
assert test -d "$GROKB_PROFILES_DIR/fresh"
assert grep -q "new profile 'fresh' created" <<<"$fresh_output"
assert wait_announce '--refresh-account grok/fresh'
assert grep -q "CALL home=$GROKB_PROFILES_DIR/fresh mcps=0 skills=0 updater=1 worker=1" "$GROK_CALLS"

printf 'PASS: %s asserts; Grok profile creation/login, safe status, pool gating, pinned launch environments, main isolation, account pinning, reserved names, removal, announcements, and the fake CLI contract are covered\n' "$asserts"
