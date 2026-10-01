#!/usr/bin/env bash
# bin/pkill (and bin/pgrep, a link to it) refuses an option placed after the first pattern and
# otherwise execs the real tool with its arguments untouched. The real tool is always a fake
# that prints its argv: this suite never lists or signals a real process.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
eq() { [ "$1" = "$2" ] || { printf 'expected [%s]\n     got [%s]\n' "$2" "$1" >&2; return 1; }; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/real" "$WORK/path"
for tool in pkill pgrep; do
  cat >"$WORK/real/$tool" <<EOF
#!/bin/bash
printf 'REAL $tool argc=%s' "\$#"
printf ' [%s]' "\$@"
printf '\n'
printf 'ran\n' >>"$WORK/real.log"
EOF
  chmod +x "$WORK/real/$tool"
  ln -s "$ROOT/bin/$tool" "$WORK/path/$tool"
done
export PKILL_GUARD_REAL_DIR="$WORK/real"

PAT="zz-pkill-guard-test-$$"
OUT="$WORK/out"
ERR="$WORK/err"
run() {
  rm -f "$WORK/real.log"
  "$WORK/path/$1" "${@:2}" >"$OUT" 2>"$ERR"
}

# Canary before any pkill case: a shim that ignored the override would signal real processes.
run pgrep -f "$PAT"
grep -q '^REAL pgrep ' "$OUT" || { cat "$OUT" "$ERR" >&2; echo "ABORT: the fake real pgrep did not run; no pkill case is safe" >&2; exit 1; }

refused() {
  local rc
  run "$@"; rc=$?
  eq "$rc" 2 && [ ! -e "$WORK/real.log" ] && [ ! -s "$OUT" ] &&
    grep -q "^$1: refused: option .* comes after the first pattern" "$ERR" &&
    grep -qF 'Put every option before the pattern' "$ERR"
}
passed() {
  local rc expected tool=$1
  run "$@"; rc=$?
  shift
  expected="REAL $tool argc=$#$(printf ' [%s]' "$@")"
  [ "$#" -gt 0 ] || expected="REAL $tool argc=0 []"
  eq "$rc" 0 && [ -e "$WORK/real.log" ] && [ ! -s "$ERR" ] && eq "$(cat "$OUT")" "$expected"
}

for tool in pkill pgrep; do
  assert refused "$tool" -f "$PAT" -P 1
  assert refused "$tool" -f "$PAT" -P1
  assert refused "$tool" "$PAT" -f
  assert refused "$tool" -fP1 "$PAT" -l
  assert refused "$tool" -f "$PAT" -- y
  assert refused "$tool" -f - -P 1
  assert refused "$tool" -f "$PAT" "$PAT-2" -x
  assert passed "$tool" -P 1 -f "$PAT"
  assert passed "$tool" -fP 1 "$PAT"
  assert passed "$tool" -fP1 "$PAT"
  assert passed "$tool" -f -- -x
  assert passed "$tool" -f -- "$PAT" -P 1
  assert passed "$tool" -lf "$PAT"
  assert passed "$tool" -f "$PAT" "$PAT-2"
  assert passed "$tool" -f "$PAT -P with spaces"
  assert passed "$tool" -F /tmp/p
  assert passed "$tool" -u me -f "$PAT"
  assert passed "$tool" -f ''
  assert passed "$tool"
done

assert refused pkill -9 "$PAT" -u me
assert grep -qF 'Claude Bash tool shell contains `pwd -P`' "$ERR"
assert refused pkill -STOP "$PAT" -P 1
assert refused pkill -term "$PAT" -P 1
assert refused pkill -SIGHUP "$PAT" -P 1
assert refused pkill - -P 1
assert passed pkill -9 -f "$PAT"
assert passed pkill -TERM -f "$PAT"
assert passed pkill -SIGTERM -f "$PAT"
assert passed pkill -STOP -P 1 "$PAT"
assert refused pgrep -TERM "$PAT" -P 1

ln -s "$ROOT/bin/pkill" "$WORK/path/pkill-other"
rm -f "$WORK/real.log"
"$WORK/path/pkill-other" -f "$PAT" >"$OUT" 2>"$ERR"
assert eq "$?" 2
assert [ ! -e "$WORK/real.log" ]

assert eq "$(readlink "$ROOT/bin/pgrep")" pkill
for tool in pkill pgrep; do
  assert grep -qF -- "- \`bin/$tool\` → \`~/.local/bin/$tool\`" "$ROOT/README.md"
done

printf 'PASS: %s asserts; pkill and pgrep refuse an option after the first pattern and pass everything else through untouched\n' "$asserts"
