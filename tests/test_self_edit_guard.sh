#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts unexpectedly held: $*"; }

# 2026-10-06: a chat edited bin/land in place while land ran, and land died at its end on
# "unexpected EOF while looking for matching" with its worktree, branch and report undone.
OPEN='{'
CLOSE='exit; }'
DUAL_CLOSE='case $0 in "${BASH_SOURCE[0]}") exit; esac; }'

body() { # the lines a chat's edit deletes: the first comment
  printf '%s\n' '# a chat deletes this line' \
    ': >"$1/ready"' \
    'while [ ! -e "$1/go" ]; do sleep 0.05; done' \
    'printf '"'%s\\n'"' "original tail"'
}
edited_body() { body | sed 1d; }
unguarded() { printf '#!/usr/bin/env bash\n'; "$1"; }
guarded() { printf '#!/usr/bin/env bash\n%s\n' "$OPEN"; "$1"; printf '%s\n' "$CLOSE"; }

edit_mid_run() { # interpreter script new-content-file -> rc; stdout/stderr in $WORK/out, $WORK/err
  rm -f "$WORK/ready" "$WORK/go"
  "$1" "$2" "$WORK" >"$WORK/out" 2>"$WORK/err" &
  local pid=$! i inode
  for i in $(seq 1 200); do [ -e "$WORK/ready" ] && break; sleep 0.05; done
  inode=$(ls -i "$2" | awk '{print $1}')
  cat "$3" >"$2"
  [ "$(ls -i "$2" | awk '{print $1}')" = "$inode" ] || fail "the rewrite replaced $2 instead of editing it in place"
  : >"$WORK/go"
  wait "$pid"
}

interpreters=(bash)
[ -x /bin/bash ] && [ "$(command -v bash)" != /bin/bash ] && interpreters+=(/bin/bash)

for sh in "${interpreters[@]}"; do
  unguarded body >"$WORK/plain.sh"
  unguarded edited_body >"$WORK/plain.new"
  rc=0; edit_mid_run "$sh" "$WORK/plain.sh" "$WORK/plain.new" || rc=$?
  assert test "$rc" -ne 0
  assert grep -q 'unexpected EOF while looking for matching' "$WORK/err"
  assert_fails grep -q 'original tail' "$WORK/out"

  guarded body >"$WORK/guarded.sh"
  guarded edited_body >"$WORK/guarded.new"
  rc=0; edit_mid_run "$sh" "$WORK/guarded.sh" "$WORK/guarded.new" || rc=$?
  assert test "$rc" -eq 0
  assert test "$(cat "$WORK/out")" = 'original tail'
  assert test ! -s "$WORK/err"

  guarded body >"$WORK/guarded.sh"
  yes 'exit 97' | head -n 20000 >"$WORK/junk.new"
  rc=0; edit_mid_run "$sh" "$WORK/guarded.sh" "$WORK/junk.new" || rc=$?
  assert test "$rc" -eq 0
  assert test "$(cat "$WORK/out")" = 'original tail'

  # `exit` keeps the status of the body's last command, and the EXIT trap still runs.
  printf '#!/usr/bin/env bash\n%s\n%s\n%s\n%s\n' "$OPEN" "trap 'echo trapped' EXIT" '(exit 5)' "$CLOSE" >"$WORK/rc.sh"
  rc=0; "$sh" "$WORK/rc.sh" >"$WORK/out" || rc=$?
  assert test "$rc" -eq 5
  assert test "$(cat "$WORK/out")" = trapped

  # A file both sourced and executed closes on DUAL_CLOSE: run, it exits with main's status and
  # survives the edit; sourced, it returns to its caller with the status of a skipped main.
  dual() {
    printf '#!/usr/bin/env bash\n%s\n' "$OPEN"
    printf '%s\n' 'dual_main() { : >"$1/ready"; while [ ! -e "$1/go" ]; do sleep 0.05; done; echo "original main"; return 4; }' \
      'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' '  dual_main "$@"' 'fi'
    printf '%s\n' "$DUAL_CLOSE"
  }
  dual >"$WORK/dual.sh"
  rc=0; edit_mid_run "$sh" "$WORK/dual.sh" "$WORK/junk.new" || rc=$?
  assert test "$rc" -eq 4
  assert test "$(cat "$WORK/out")" = 'original main'
  dual >"$WORK/dual.sh"
  assert test "$("$sh" -c '. "$1"; echo "sourced:$?"; declare -F dual_main' _ "$WORK/dual.sh")" = "$(printf 'sourced:0\ndual_main')"
done

printf 'PASS: test_self_edit_guard.sh (%s asserts)\n' "$asserts"
