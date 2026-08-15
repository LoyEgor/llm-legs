#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="$ROOT/bin/claude-session-driver"
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
CLAUDEB_DIR="$WORK/store"
FAKE_BIN="$WORK/bin"
SESSION_CWD="$WORK/trusted"
export HOME CLAUDEB_DIR
mkdir -p "$HOME" "$CLAUDEB_DIR" "$FAKE_BIN" "$SESSION_CWD"
# A stripped PATH, not a prefixed one: a test that removes its fake `claudeb` would
# otherwise reach the installed one and drive a real account.
PATH="$FAKE_BIN:/usr/bin:/bin"
export PATH
printf '#!/usr/bin/env bash\nexit 97\n' >"$FAKE_BIN/claude"
chmod +x "$FAKE_BIN/claude"

# The real cadence is 25s to /exit and 15s to the interrupts; the suite drives the
# same ladder on a compressed clock.
CLAUDEB_SESSION_EXIT_DELAY=1
CLAUDEB_SESSION_CR_DELAY=0.3
CLAUDEB_SESSION_INTERRUPT_DELAY=1
CLAUDEB_SESSION_GRACE=2
export CLAUDEB_SESSION_EXIT_DELAY CLAUDEB_SESSION_CR_DELAY CLAUDEB_SESSION_INTERRUPT_DELAY CLAUDEB_SESSION_GRACE

KEYCHAIN="$WORK/keychain"
CALLS="$WORK/claudeb-calls"
TYPED="$WORK/typed"
SIGNALS="$WORK/signals"
LOG_DIR="$CLAUDEB_DIR/session-logs"
mkdir -p "$KEYCHAIN"

kc_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
svc_of() { printf 'Claude Code-credentials-%s' "$(printf '%s' "$HOME/.claude-profiles/$1" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"; }
seed_token() {
  printf '{"claudeAiOauth":{"refreshToken":"rt","accessToken":"at","expiresAt":%s}}' "$2" \
    >"$KEYCHAIN/$(kc_key "$(svc_of "$1")")"
}
fresh_ms=$((($(date +%s) + 28800) * 1000))

cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
previous=''
service=''
for argument in "\$@"; do
  [ "\$previous" = -s ] && service="\$argument"
  previous="\$argument"
done
key=\$(printf '%s' "\$service" | tr -c 'A-Za-z0-9._-' '_')
cat '$KEYCHAIN'/"\$key" 2>/dev/null || exit 44
EOF
chmod +x "$FAKE_BIN/security"

# Every fake session records the launch argv and the environment the driver promises
# the child (child-session marker, no state stamp, TERM, trusted cwd) before playing
# its own script.
write_claudeb() {
  write_claudeb_at "$FAKE_BIN/claudeb" "$CALLS" "$1"
}

write_claudeb_at() {
  cat >"$1" <<EOF
#!/usr/bin/env bash
printf 'args=%s cwd=%s child=%s nostamp=%s term=%s\n' "\$*" "\$PWD" "\${CLAUDE_CODE_CHILD_SESSION:-}" "\${CLAUDEB_NO_STATE_STAMP:-}" "\${TERM:-}" >>'$2'
$3
EOF
  chmod +x "$1"
}

reset_state() {
  : >"$CALLS"
  rm -f "$TYPED" "$SIGNALS"
  rm -rf "$LOG_DIR"
}

# --- argument validation: nothing is driven until the request is well formed ---
reset_state
write_claudeb 'exit 0'
for bad in '' 'bad name' '../escape' '-legacy'; do
  bad_rc=0
  if [ -z "$bad" ]; then
    "$DRIVER" >/dev/null 2>&1 || bad_rc=$?
  else
    "$DRIVER" "$bad" >/dev/null 2>&1 || bad_rc=$?
  fi
  assert test "$bad_rc" -eq 2
done
timeout_rc=0
"$DRIVER" alpha --timeout 0 >/dev/null 2>&1 || timeout_rc=$?
assert test "$timeout_rc" -eq 2
timeout_word_rc=0
"$DRIVER" alpha --timeout later >/dev/null 2>&1 || timeout_word_rc=$?
assert test "$timeout_word_rc" -eq 2
cwd_rc=0
"$DRIVER" alpha --cwd "$WORK/absent" >/dev/null 2>&1 || cwd_rc=$?
assert test "$cwd_rc" -eq 2
assert_fails test -s "$CALLS"

# --- rotation: /exit lands, the keychain re-read is the verdict ---
reset_state
seed_token alpha "$fresh_ms"
write_claudeb "printf 'fake claude ui\n'
while IFS= read -r line; do
  printf '%s\n' \"\$line\" >>'$TYPED'
  case \"\$line\" in */exit*) exit 0 ;; esac
done
exit 0"
ok_rc=0
"$DRIVER" alpha --cwd "$SESSION_CWD" --timeout 20 >"$WORK/ok.out" 2>"$WORK/ok.err" || ok_rc=$?
assert test "$ok_rc" -eq 0
# nostamp=1: the driver's session is machinery, so claudeb must not restamp the
# user's current account behind their back.
assert grep -qx "args=profile alpha cwd=$(cd -P "$SESSION_CWD" && pwd) child=1 nostamp=1 term=xterm-256color" "$CALLS"
assert grep -q '/exit' "$TYPED"
assert test "$(grep -c '' "$TYPED")" -eq 1
assert grep -q 'alpha: success' "$WORK/ok.out"
assert grep -q '^timestamp=.* outcome=success exit_code=0$' "$LOG_DIR/alpha.log"
assert grep -q 'fake claude ui' "$LOG_DIR/alpha.log"
# Atomic like persist_warm_output: the finished log is the only file left behind.
assert test "$(find "$LOG_DIR" -type f | grep -c '')" -eq 1

EXIT_ON_EXIT="printf 'ui\n'
while IFS= read -r line; do
  case \"\$line\" in */exit*) exit 0 ;; esac
done
exit 0"

# --- the caller's claudeb is preferred over PATH, and only if it can actually run ---
reset_state
seed_token eta "$fresh_ms"
ALT_CALLS="$WORK/alt-calls"
: >"$ALT_CALLS"
write_claudeb_at "$WORK/alt-claudeb" "$ALT_CALLS" "$EXIT_ON_EXIT"
write_claudeb "$EXIT_ON_EXIT"
alt_rc=0
CLAUDE_SESSION_DRIVER_CLAUDEB="$WORK/alt-claudeb" \
  "$DRIVER" eta --cwd "$SESSION_CWD" --timeout 20 >/dev/null 2>&1 || alt_rc=$?
assert test "$alt_rc" -eq 0
assert grep -q '^args=profile eta ' "$ALT_CALLS"
assert_fails test -s "$CALLS"

reset_state
seed_token theta "$fresh_ms"
printf 'not executable\n' >"$WORK/dud-claudeb"
dud_rc=0
CLAUDE_SESSION_DRIVER_CLAUDEB="$WORK/dud-claudeb" \
  "$DRIVER" theta --cwd "$SESSION_CWD" --timeout 20 >/dev/null 2>&1 || dud_rc=$?
assert test "$dud_rc" -eq 0
assert grep -q '^args=profile theta ' "$CALLS"

# --- a session that ignores /exit is escalated to two interrupts, never to typing ---
reset_state
seed_token beta "$fresh_ms"
write_claudeb "trap 'printf \"int\n\" >>'$SIGNALS'; [ \"\$(grep -c \"\" '$SIGNALS')\" -ge 2 ] && exit 0' INT
printf 'stubborn but interruptible\n'
while :; do sleep 0.2; done"
int_rc=0
"$DRIVER" beta --cwd "$SESSION_CWD" --timeout 20 >"$WORK/int.out" 2>&1 || int_rc=$?
assert test "$int_rc" -eq 0
assert test "$(grep -c '' "$SIGNALS")" -eq 2
assert_fails test -e "$TYPED"
assert grep -q 'outcome=success' "$LOG_DIR/beta.log"

# --- login screen: the account needs a human, and nothing is typed into the prompt ---
reset_state
seed_token gamma 1
write_claudeb "printf 'Select login method:\n'
printf '  1. Claude account with subscription\n'
while IFS= read -r line; do printf '%s\n' \"\$line\" >>'$TYPED'; done"
login_rc=0
"$DRIVER" gamma --cwd "$SESSION_CWD" --timeout 20 >"$WORK/login.out" 2>&1 || login_rc=$?
assert test "$login_rc" -eq 4
assert_fails test -e "$TYPED"
assert grep -q 'gamma: login-needed' "$WORK/login.out"
assert grep -q 'outcome=login-needed' "$LOG_DIR/gamma.log"

# --- the same screen text with a live token is a success: the keychain outranks the UI ---
reset_state
seed_token iota "$fresh_ms"
write_claudeb "printf 'tip: run /login to switch accounts\n'
while :; do sleep 0.2; done"
uitext_rc=0
"$DRIVER" iota --cwd "$SESSION_CWD" --timeout 20 >"$WORK/uitext.out" 2>&1 || uitext_rc=$?
assert test "$uitext_rc" -eq 0
assert grep -q 'iota: success' "$WORK/uitext.out"
assert grep -q 'outcome=success' "$LOG_DIR/iota.log"

# --- a session that survives the whole ladder is killed, and an unrotated token fails ---
reset_state
seed_token delta 1
write_claudeb "trap '' INT
printf 'ignores everything\n'
while :; do sleep 0.2; done"
kill_started=$SECONDS
kill_rc=0
"$DRIVER" delta --cwd "$SESSION_CWD" --timeout 40 >"$WORK/kill.out" 2>&1 || kill_rc=$?
assert test "$kill_rc" -eq 5
# The grace window after the last interrupt, not the caller's timeout, ends the session.
assert test "$((SECONDS - kill_started))" -lt 25
assert grep -q 'outcome=failed' "$LOG_DIR/delta.log"

# --- a clean session that did not rotate the token is a failure, not a success ---
reset_state
seed_token epsilon 1
write_claudeb "printf 'ui\n'
while IFS= read -r line; do
  case \"\$line\" in */exit*) exit 0 ;; esac
done"
stale_rc=0
"$DRIVER" epsilon --cwd "$SESSION_CWD" --timeout 20 >"$WORK/stale.out" 2>&1 || stale_rc=$?
assert test "$stale_rc" -eq 5
assert grep -q '^timestamp=.* outcome=failed exit_code=0$' "$LOG_DIR/epsilon.log"

# --- no claudeb to exec: the child dies 127 and the driver reports a plain failure ---
reset_state
seed_token zeta "$fresh_ms"
rm -f "$FAKE_BIN/claudeb"
missing_rc=0
"$DRIVER" zeta --cwd "$SESSION_CWD" --timeout 20 >"$WORK/missing.out" 2>&1 || missing_rc=$?
# The token was already valid, so only the exec failure distinguishes this run.
assert test "$missing_rc" -eq 0
assert grep -q 'exit_code=127' "$LOG_DIR/zeta.log"

echo "PASS: $asserts asserts; claude-session-driver argument validation refusing to launch anything, a driven session typing only /exit and reporting the keychain re-read, interrupt escalation when /exit is ignored, a login screen exiting 4 with nothing typed while the same text over a live token still succeeds, the caller's claudeb path preferred over PATH unless it cannot run, a stubborn session killed inside the grace window instead of the caller's timeout, a clean session that left the token expired failing, and warm-logs-style session logs written atomically under CLAUDEB_DIR"
