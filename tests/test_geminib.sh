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
mkdir -p "$HOME/.gemini/antigravity-cli" "$HOME/.gemini/config" "$HOME/.gemini/extensions" "$FAKE_BIN"
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
AGY_BIN="$FAKE_BIN/agy"
export AGY_BIN

cat >"$WORK/fake-quota" <<'EOF'
#!/usr/bin/env bash
account=main
case "$HOME" in */.gemini-profiles/*) account=$(basename "$HOME") ;; esac
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

add_output=$(bash "$SCRIPT" add alpha) || fail "add alpha failed"
assert grep -qx 'HOME=~/.gemini-profiles/alpha agy' <<<"$add_output"
assert grep -qx 'alpha: Not logged in' <<<"$add_output"
assert test -d "$HOME/.gemini-profiles/alpha/.gemini/antigravity-cli"
for item in GEMINI.md config extensions settings.json; do
  assert test -L "$HOME/.gemini-profiles/alpha/.gemini/$item"
done
assert test -L "$HOME/.gemini-profiles/alpha/.gemini/antigravity-cli/settings.json"

mkdir -p "$HOME/.gemini-profiles/trap/.gemini/config"
printf 'keep\n' >"$HOME/.gemini-profiles/trap/.gemini/config/value"
bash "$SCRIPT" list >/dev/null
assert test ! -L "$HOME/.gemini-profiles/trap/.gemini/config"
assert grep -qx keep "$HOME/.gemini-profiles/trap/.gemini/config/value"
assert_fails bash "$SCRIPT" add main >/dev/null 2>&1
assert_fails bash "$SCRIPT" add Bad >/dev/null 2>&1
assert_fails bash "$SCRIPT" add alpha >/dev/null 2>&1

bash "$SCRIPT" add beta >/dev/null || fail "add beta failed"
printf 'ok\n' >"$GEMINI_AUTH_DIR/alpha"
quota alpha 0.4 0.55
list_output=$(bash "$SCRIPT" list) || fail "list failed"
assert test "$(sed -n '1p' <<<"$list_output")" = 'main: Logged in'
assert grep -qx 'alpha: Logged in' <<<"$list_output"
assert grep -qx 'beta: Not logged in' <<<"$list_output"

status_output=$(bash "$SCRIPT" status) || fail "status failed"
assert grep -Eq '^main: Logged in \| 5H 30% reset .+ \| WEEKLY 20% reset .+$' <<<"$status_output"
assert grep -Eq '^alpha: Logged in \| 5H 60% reset .+ \| WEEKLY 45% reset .+$' <<<"$status_output"
assert grep -Eq '^beta: Not logged in \| 5H - reset unknown \| WEEKLY - reset unknown$' <<<"$status_output"

: >"$AGY_CALLS"
bash "$SCRIPT" run main --flag 'two words' '*' '' || fail "main run failed"
assert grep -qx "CALL home=$HOME argc=4" "$AGY_CALLS"
assert grep -qx 'ARG=two\\ words' "$AGY_CALLS"
assert grep -qx 'ARG=\\\*' "$AGY_CALLS"
assert grep -qx "ARG=''" "$AGY_CALLS"

: >"$AGY_CALLS"
bash "$SCRIPT" alpha exec --json 'two words' || fail "profile shorthand failed"
assert grep -qx "CALL home=$HOME/.gemini-profiles/alpha argc=3" "$AGY_CALLS"
assert test "$(sed -n '2p' "$AGY_CALLS")" = 'ARG=exec'
assert test "$(sed -n '3p' "$AGY_CALLS")" = 'ARG=--json'
assert test "$(sed -n '4p' "$AGY_CALLS")" = 'ARG=two\ words'

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
assert grep -qx "CALL home=$HOME/.gemini-profiles/pick argc=2" "$AGY_CALLS"
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

cache_dir="$HOME/.llm-limits-gemini"
mkdir -p "$cache_dir"
printf '{}\n' >"$cache_dir/alpha.json"
printf 'removed\n' >"$cache_dir/alpha.json.removed"
assert bash "$SCRIPT" remove alpha
assert test ! -e "$HOME/.gemini-profiles/alpha"
assert test ! -e "$cache_dir/alpha.json"
assert test ! -e "$cache_dir/alpha.json.removed"
assert_fails bash "$SCRIPT" remove main
assert_fails bash "$SCRIPT" remove ../outside
assert_fails bash "$SCRIPT" remove never-existed

echo "PASS: $asserts asserts; base and isolated HOME routing, shared configuration links, list/status auth and quota, one-step creation, reserved-name parity, help short-circuit, legacy exec guard, and cache-pruning remove"
