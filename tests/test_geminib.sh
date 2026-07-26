#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/geminib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then
    fail "assert $asserts unexpectedly succeeded: $*"
  else
    status=$?
    [ "$status" -ne 127 ] || fail "assert $asserts command not found: $*"
  fi
}

HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
AGY_CALLS="$WORK/agy-calls"
export HOME AGY_CALLS
mkdir -p "$HOME/.gemini/antigravity-cli" "$HOME/.gemini/config" "$HOME/.gemini/extensions" "$FAKE_BIN" \
  "$HOME/Library/Keychains"
printf 'instructions\n' >"$HOME/.gemini/GEMINI.md"
printf '{}\n' >"$HOME/.gemini/settings.json"
printf '{}\n' >"$HOME/.gemini/antigravity-cli/settings.json"
printf 'config\n' >"$HOME/.gemini/config/value"
printf 'extension\n' >"$HOME/.gemini/extensions/value"

cat >"$FAKE_BIN/agy" <<'EOF'
#!/usr/bin/env bash
{
  printf 'CALL home=%s argc=%s\n' "$HOME" "$#"
  for argument in "$@"; do printf 'ARG=%q\n' "$argument"; done
} >>"$AGY_CALLS"
EOF
chmod +x "$FAKE_BIN/agy"

SECURITY_CALLS="$WORK/security-calls"
GEMINIB_SECURITY_CMD="$FAKE_BIN/security"
SECURITY_LIST_FILE="$WORK/security-list"
GEMINIB_TEST_BASE_HOME="$HOME"
export SECURITY_CALLS GEMINIB_SECURITY_CMD SECURITY_LIST_FILE GEMINIB_TEST_BASE_HOME
cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
printf 'CALL home=%s %s\n' "$HOME" "$*" >>"$SECURITY_CALLS"
if [ "${1:-}" = list-keychains ]; then
  if [ "${4:-}" = -s ] && [ "$HOME" = "$GEMINIB_TEST_BASE_HOME" ]; then
    : >"$SECURITY_LIST_FILE"
    shift 4
    for keychain in "$@"; do printf '    "%s"\n' "$keychain" >>"$SECURITY_LIST_FILE"; done
  elif [ "$HOME" = "$GEMINIB_TEST_BASE_HOME" ] && [ -f "$SECURITY_LIST_FILE" ]; then
    cat "$SECURITY_LIST_FILE"
  fi
  exit 0
fi
if [ "${1:-}" = find-generic-password ]; then
  printf 'fixture-oauth-token'
  exit 0
fi
[ "${1:-}" != create-keychain ] || printf '%s' "$3" >"$4"
EOF
chmod +x "$FAKE_BIN/security"
AGY_BIN="$FAKE_BIN/agy"
export AGY_BIN

cat >"$WORK/fake-quota" <<'EOF'
#!/usr/bin/env bash
account=main
case "$HOME" in */.gemini-profiles/*) account=$(basename "$HOME") ;; esac
if [ -n "${GEMINI_PROBE_LOG:-}" ]; then
  printf 'START %s\n' "$account" >>"$GEMINI_PROBE_LOG"
  sleep 1
  printf 'END %s\n' "$account" >>"$GEMINI_PROBE_LOG"
fi
if [ "$(cat "${GEMINI_AUTH_DIR:?}/$account" 2>/dev/null)" != ok ]; then
  printf '{"auth_needed":true,"detail":"login screen"}\n'
  exit 2
fi
cat "${GEMINI_QUOTA_DIR:?}/$account.json"
EOF
chmod +x "$WORK/fake-quota"
GEMINIB_QUOTA_CMD="$WORK/fake-quota"
GEMINI_AUTH_DIR="$WORK/auth"
GEMINI_QUOTA_DIR="$WORK/quota"
export GEMINIB_QUOTA_CMD GEMINI_AUTH_DIR GEMINI_QUOTA_DIR
mkdir -p "$GEMINI_AUTH_DIR" "$GEMINI_QUOTA_DIR"

future='2026-07-25T12:00:00Z'
week='2026-07-30T12:00:00Z'
quota() {
  printf '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":%s,"resetTime":"%s"},{"window":"weekly","remainingFraction":%s,"resetTime":"%s"}]}]}\n' \
    "$2" "$future" "$3" "$week" >"$GEMINI_QUOTA_DIR/$1.json"
}
printf 'ok\n' >"$GEMINI_AUTH_DIR/main"
quota main 0.7 0.8

cat >"$SECURITY_LIST_FILE" <<EOF
    "$HOME/Library/Keychains/login.keychain-db"
    "$HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db"
    "$HOME/.gemini-profiles/alpha/Library/Keychains/.staging.old/login.keychain-db"
    "/private/var/folders/a/b/T/tmp.example/gp/alpha/Library/Keychains/.staging.old/login.keychain-db"
    "/Library/Keychains/System.keychain"
    "$WORK/foreign.keychain-db"
EOF
add_output=$(bash "$SCRIPT" add alpha) || fail "add alpha failed"
assert grep -qx "HOME=$HOME/.gemini-profiles/alpha agy" <<<"$add_output"
assert grep -qx 'alpha: Not logged in' <<<"$add_output"
assert test -d "$HOME/.gemini-profiles/alpha/.gemini/antigravity-cli"
for item in GEMINI.md config extensions settings.json; do
  assert test -L "$HOME/.gemini-profiles/alpha/.gemini/$item"
done
assert test -L "$HOME/.gemini-profiles/alpha/.gemini/antigravity-cli/settings.json"
assert test ! -L "$HOME/.gemini-profiles/alpha/Library/Keychains"
assert test -f "$HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db"
assert test "$(stat -f %Lp "$HOME/.gemini-profiles/alpha/.keychain-password")" = 600
assert grep -qx "    \"$HOME/Library/Keychains/login.keychain-db\"" "$SECURITY_LIST_FILE"
assert grep -qx '    "/Library/Keychains/System.keychain"' "$SECURITY_LIST_FILE"
assert grep -qx "    \"$WORK/foreign.keychain-db\"" "$SECURITY_LIST_FILE"
assert_fails grep -q '\.gemini-profiles/alpha/Library/Keychains' "$SECURITY_LIST_FILE"
assert_fails grep -q '/tmp\.example/gp/' "$SECURITY_LIST_FILE"
assert grep -q "CALL home=$HOME/.gemini-profiles/alpha create-keychain" "$SECURITY_CALLS"
assert_fails grep -q "CALL home=$HOME create-keychain" "$SECURITY_CALLS"

mkdir -p "$HOME/.gemini-profiles/trap/.gemini/config" "$HOME/.gemini-profiles/trap/Library/Keychains"
printf 'keep\n' >"$HOME/.gemini-profiles/trap/.gemini/config/value"
printf 'own\n' >"$HOME/.gemini-profiles/trap/Library/Keychains/login.keychain-db"
bash "$SCRIPT" list >/dev/null
assert test ! -L "$HOME/.gemini-profiles/trap/.gemini/config"
assert grep -qx keep "$HOME/.gemini-profiles/trap/.gemini/config/value"
assert test ! -L "$HOME/.gemini-profiles/trap/Library/Keychains"
assert grep -qx own "$HOME/.gemini-profiles/trap/Library/Keychains/login.keychain-db"

gemini_base_home="$HOME"
gemini_profiles_dir="$HOME/.gemini-profiles"
. "$ROOT/share/gemini-accounts.sh"
migrate_home="$WORK/migrate-home"
mkdir -p "$migrate_home/Library/Keychains"
printf 'legacy\n' >"$migrate_home/Library/Keychains/login.keychain-db"
(umask 077; printf 'migration-password' >"$migrate_home/.keychain-password")
gemini_ensure_keychain "$migrate_home"
assert grep -qx 2 "$migrate_home/.keychain-version"
assert grep -qx legacy "$migrate_home/Library/Keychains/.geminib-legacy.keychain-db"
assert grep -qx migration-password "$migrate_home/Library/Keychains/login.keychain-db"
assert grep -q 'add-generic-password -U -s gemini -a antigravity -w fixture-oauth-token' \
  "$SECURITY_CALLS"
gemini_ensure_keychain "$migrate_home"
assert test ! -e "$migrate_home/Library/Keychains/.geminib-unlock.keychain-db"

rm -rf "$HOME/.gemini-profiles/alpha/Library/Keychains" "$HOME/.gemini-profiles/alpha/.keychain-password"
ln -sfn "$HOME/Library/Keychains" "$HOME/.gemini-profiles/alpha/Library/Keychains"
warning=$(gemini_ensure_keychain "$HOME/.gemini-profiles/alpha" 2>&1 >/dev/null)
assert test ! -L "$HOME/.gemini-profiles/alpha/Library/Keychains"
assert test -f "$HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db"
assert grep -q 'sign it in again' <<<"$warning"
assert test ! -e "$HOME/Library/Keychains/Keychains"
assert test ! -e "$HOME/Library/Keychains/login.keychain-db"

printf 'existing\n' >"$HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db"
gemini_ensure_keychain "$HOME/.gemini-profiles/alpha"
assert grep -qx existing "$HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db"
assert grep -q 'unlock-keychain .*\.geminib-unlock\.keychain-db' "$SECURITY_CALLS"
assert test ! -e "$HOME/.gemini-profiles/alpha/Library/Keychains/.geminib-unlock.keychain-db"
gemini_ensure_keychain "$HOME/.gemini-profiles/vanished"
assert test ! -e "$HOME/.gemini-profiles/vanished"
gemini_ensure_keychain "$HOME"
assert test ! -e "$HOME/Library/Keychains/login.keychain-db"

rm -f "$HOME/.gemini-profiles/alpha/.keychain-password"
warning=$(gemini_ensure_keychain "$HOME/.gemini-profiles/alpha" 2>&1 >/dev/null)
assert grep -q 'no saved password' <<<"$warning"

rm -rf "$HOME/.gemini-profiles/alpha/Library/Keychains"
warning=$(GEMINIB_SECURITY_CMD=/usr/bin/false gemini_ensure_keychain "$HOME/.gemini-profiles/alpha" 2>&1 >/dev/null)
assert test ! -e "$HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db"
assert grep -q 'could not create a keychain' <<<"$warning"

# A run killed mid-creation leaves staging behind; the next one must still produce a keychain.
mkdir -p "$HOME/.gemini-profiles/alpha/Library/Keychains/.staging.crashed"
for _ in $(seq 1 40); do gemini_ensure_keychain "$HOME/.gemini-profiles/alpha" & done
wait
assert test -f "$HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db"
assert test "$(cat "$HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db")" \
  = "$(cat "$HOME/.gemini-profiles/alpha/.keychain-password")"
assert test "$(stat -f %Lp "$HOME/.gemini-profiles/alpha/.keychain-password")" = 600
assert test "$(ls -A "$HOME/.gemini-profiles/alpha/Library/Keychains" | grep -c '^\.staging\.[A-Za-z0-9]\{6\}$')" = 0
assert_fails bash "$SCRIPT" add main >/dev/null 2>&1
assert_fails bash "$SCRIPT" add Bad >/dev/null 2>&1
assert_fails bash "$SCRIPT" add alpha >/dev/null 2>&1

custom_profiles="$WORK/custom-profiles"
custom_output=$(GEMINIB_PROFILES_DIR="$custom_profiles" bash "$SCRIPT" add override) \
  || fail "add with profiles override failed"
assert grep -qx "HOME=$custom_profiles/override agy" <<<"$custom_output"

bash "$SCRIPT" add beta >/dev/null || fail "add beta failed"
printf 'ok\n' >"$GEMINI_AUTH_DIR/alpha"
quota alpha 0.4 0.55
list_output=$(bash "$SCRIPT" list) || fail "list failed"
assert test "$(sed -n '1p' <<<"$list_output")" = 'main: Logged in'
assert grep -qx 'alpha: Logged in' <<<"$list_output"
assert grep -qx 'beta: Not logged in' <<<"$list_output"

GEMINI_PROBE_LOG="$WORK/list-probes"
export GEMINI_PROBE_LOG
bash "$SCRIPT" list >/dev/null || fail "parallel list failed"
assert test "$(awk '/^END / {print NR; exit}' "$GEMINI_PROBE_LOG")" -gt 4
unset GEMINI_PROBE_LOG

status_output=$(bash "$SCRIPT" status) || fail "status failed"
assert grep -Eq '^main: Logged in \| 5H 30% reset .+ \| WEEKLY 20% reset .+$' <<<"$status_output"
assert grep -Eq '^alpha: Logged in \| 5H 60% reset .+ \| WEEKLY 45% reset .+$' <<<"$status_output"
assert grep -Eq '^beta: Not logged in \| 5H - reset unknown \| WEEKLY - reset unknown$' <<<"$status_output"

GEMINI_PROBE_LOG="$WORK/status-probes"
export GEMINI_PROBE_LOG
bash "$SCRIPT" status >/dev/null || fail "parallel status failed"
assert test "$(awk '/^END / {print NR; exit}' "$GEMINI_PROBE_LOG")" -gt 4
unset GEMINI_PROBE_LOG

: >"$AGY_CALLS"
bash "$SCRIPT" run main --flag 'two words' '*' '' || fail "main run failed"
assert grep -qx "CALL home=$HOME argc=4" "$AGY_CALLS"
assert grep -qx 'ARG=two\\ words' "$AGY_CALLS"
assert grep -qx 'ARG=\\\*' "$AGY_CALLS"
assert grep -qx "ARG=''" "$AGY_CALLS"

: >"$AGY_CALLS"
bash "$SCRIPT" alpha exec --json 'two words' || fail "profile shorthand failed"
assert grep -qx "CALL home=$HOME/.gemini-profiles/alpha argc=2" "$AGY_CALLS"
assert test "$(sed -n '2p' "$AGY_CALLS")" = 'ARG=--json'
assert test "$(sed -n '3p' "$AGY_CALLS")" = 'ARG=two\ words'

: >"$AGY_CALLS"
fresh_output=$(bash "$SCRIPT" profile fresh 2>&1) || fail "profile fresh failed"
assert test -d "$HOME/.gemini-profiles/fresh"
assert grep -q "new profile 'fresh' created" <<<"$fresh_output"
assert grep -qx "CALL home=$HOME/.gemini-profiles/fresh argc=0" "$AGY_CALLS"

: >"$AGY_CALLS"
reopen_output=$(bash "$SCRIPT" p alpha 2>&1) || fail "reopen alpha failed"
if grep -q "new profile" <<<"$reopen_output"; then fail "reopen reprinted the created note"; fi

for reserved in profile p run add remove list status pick help login; do
  assert_fails bash "$SCRIPT" profile "$reserved" </dev/null >/dev/null 2>&1
  assert_fails bash "$SCRIPT" add "$reserved" </dev/null >/dev/null 2>&1
done
assert test ! -d "$HOME/.gemini-profiles/status"
reserved_err=$(bash "$SCRIPT" profile add </dev/null 2>&1); reserved_rc=$?
assert test "$reserved_rc" -eq 2
assert grep -qx "geminib: invalid profile name 'add'" <<<"$reserved_err"
assert_fails bash "$SCRIPT" profile Bad </dev/null >/dev/null 2>&1
assert_fails bash "$SCRIPT" add -h </dev/null >/dev/null 2>&1
assert_fails bash "$SCRIPT" profile -dash </dev/null >/dev/null 2>&1
mkdir -p "$HOME/.gemini-profiles/-existing"
assert_fails bash "$SCRIPT" -existing exec </dev/null >/dev/null 2>&1
assert test ! -e "$HOME/.gemini-profiles/-h"
assert test ! -e "$HOME/.gemini-profiles/-dash"

mkdir -p "$HOME/.gemini-profiles/pick"
for route in profile p run; do
  : >"$AGY_CALLS"
  bash "$SCRIPT" "$route" pick --reserved >/dev/null 2>&1 || fail "$route pick failed"
  assert grep -qx "CALL home=$HOME/.gemini-profiles/pick argc=1" "$AGY_CALLS"
done
: >"$AGY_CALLS"
bash "$SCRIPT" pick exec --reserved >/dev/null 2>&1 || fail "pick exec failed"
assert grep -qx "CALL home=$HOME/.gemini-profiles/pick argc=1" "$AGY_CALLS"
assert bash "$SCRIPT" remove pick
assert test ! -e "$HOME/.gemini-profiles/pick"

: >"$AGY_CALLS"
exec_err=$(bash "$SCRIPT" wrok exec --json </dev/null 2>&1); exec_rc=$?
assert test "$exec_rc" -eq 2
assert grep -qx 'geminib: unknown account: wrok' <<<"$exec_err"
assert test ! -d "$HOME/.gemini-profiles/wrok"
assert test ! -s "$AGY_CALLS"

for flag in -h --help; do
  help_out=$(bash "$SCRIPT" profile "$flag" </dev/null) || fail "profile $flag failed"
  assert grep -q 'geminib profile <name>' <<<"$help_out"
  assert test ! -d "$HOME/.gemini-profiles/$flag"
done

# --- worker pool: the same "don't burn this one" state claudeb and codexb have ---
# Output goes to a file rather than redirecting the assert itself: a redirected `assert` swallows
# its own FAIL line and the suite then dies silently with no output at all.
POOL_OUT="$WORK/pool.out"
gb() { bash "$SCRIPT" "$@" >"$POOL_OUT" 2>&1; }
assert gb disable alpha
assert grep -qx alpha "$HOME/.gemini-profiles/.geminib/disabled"
# The pool file lives beside the profiles and must never be read back as one.
assert gb list
assert_fails grep -q '^\.geminib:' "$POOL_OUT"
assert grep -q 'alpha: .*(out of pool)' "$POOL_OUT"
assert_fails grep -q 'main: .*(out of pool)' "$POOL_OUT"
assert gb status
assert grep -q 'alpha: .*(out of pool) | 5H' "$POOL_OUT"
assert gb disable alpha
assert grep -q 'already disabled' "$POOL_OUT"
assert gb enable alpha
assert_fails grep -qx alpha "$HOME/.gemini-profiles/.geminib/disabled"
assert gb enable alpha
assert grep -q 'already enabled' "$POOL_OUT"
assert_fails gb disable ghost-account
assert_fails gb enable ghost-account
assert_fails gb disable
# An empty pool leaves selection with nothing to answer and no way back but editing the file.
for pool_profile in "$HOME/.gemini-profiles"/*/; do
  pool_profile=$(basename "$pool_profile")
  case "$pool_profile" in .*) continue ;; esac
  gb disable "$pool_profile" || true
done
assert_fails gb disable main
assert grep -q 'last enabled account' "$POOL_OUT"
for pool_profile in "$HOME/.gemini-profiles"/*/; do
  pool_profile=$(basename "$pool_profile")
  case "$pool_profile" in .*) continue ;; esac
  gb enable "$pool_profile" || true
done

cache_dir="$HOME/.llm-limits-gemini"
mkdir -p "$cache_dir"
printf '{}\n' >"$cache_dir/alpha.json"
printf 'removed\n' >"$cache_dir/alpha.json.removed"
assert bash "$SCRIPT" remove alpha
assert test ! -e "$HOME/.gemini-profiles/alpha"
assert test ! -e "$cache_dir/alpha.json"
assert test -e "$cache_dir/alpha.json.removed"
assert_fails bash "$SCRIPT" remove main
assert_fails bash "$SCRIPT" remove ../outside
assert_fails bash "$SCRIPT" remove never-existed

echo "PASS: $asserts asserts; base and isolated HOME routing, worker-pool exclusion (own file beside the profiles, last member protected, visible in list/status), shared configuration links, isolated per-profile keychain creation/unlock and search-list healing, parallel ordered list/status probes, one-step creation, strict launch names, exec delimiter stripping, override-aware login hints, and persistent remove markers"
