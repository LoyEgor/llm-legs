#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/pkill (and bin/pgrep, a link to it) refuses an option placed after the first pattern and
# otherwise execs the real tool with its arguments untouched. The real tool is always a fake
# that prints its argv: this suite never lists a real process and signals only its own sleeps.
set -u
unset WORKER_RUN_ID

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
  printf -v expected ' [%s]' "$@"
  expected="REAL $tool argc=$#$expected"
  eq "$rc" 0 && [ -e "$WORK/real.log" ] && [ ! -s "$ERR" ] && eq "$(<"$OUT")" "$expected"
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
assert refused pkill -int "$PAT" -P 1
assert passed pkill -Exit "$PAT" -P 1
mkdir -p "$WORK/count"
printf '#!/bin/sh\necho tr >>"%s/execs"\nexec /usr/bin/tr "$@"\n' "$WORK" >"$WORK/count/tr"
chmod +x "$WORK/count/tr"
PATH="$WORK/count:$PATH" run pkill -SIGTERM -f "$PAT"
assert [ ! -e "$WORK/execs" ]

# A worker run in a worktree leaves alone the matches working in another worktree or the main checkout.
R="$(cd "$WORK" && pwd -P)/repo" MINE="$(cd "$WORK" && pwd -P)/repo/.claude/worktrees/mine"
mkdir -p "$WORK/real2" "$MINE" "$R/.claude/worktrees/other"
git -C "$MINE" init -q
printf '#!/bin/bash\ncat "%s/pids"\n' "$WORK" >"$WORK/real2/pgrep"
printf '#!/bin/bash\nprintf ran >>"%s/real.log"\n' "$WORK" >"$WORK/real2/pkill"
chmod +x "$WORK/real2/pgrep" "$WORK/real2/pkill"
spawn() { # cwd -> SPAWNED, a sleep working there
  (cd "$1" && exec sleep 1000) & SPAWNED=$!
  until [ "$(ps -o comm= -p "$SPAWNED")" = sleep ]; do sleep 0.05; done
}
wpkill() { (cd "$1" && WORKER_RUN_ID=run-mine PKILL_GUARD_REAL_DIR="$WORK/real2" "$WORK/path/pkill" "${@:2}") >"$OUT" 2>"$ERR"; }
spawn "$R/.claude/worktrees/other"; other=$SPAWNED
spawn "$R"; chat=$SPAWNED
mine=''
trap 'kill "$other" "$chat" $mine 2>/dev/null; rm -rf "$WORK"' EXIT
for sig in '' -KILL; do
  spawn "$MINE"; mine=$SPAWNED
  printf '%s\n' "$mine" "$other" "$chat" >"$WORK/pids"
  rm -f "$WORK/real.log"
  wpkill "$MINE" $sig -f "$PAT"
  assert eq "$?" 0
  assert [ ! -e "$WORK/real.log" ]
  { wait "$mine"; } 2>/dev/null
  assert eq "$?" "$([ -n "$sig" ] && echo 137 || echo 143)"
  assert kill -0 "$other"
  assert kill -0 "$chat"
  assert grep -qxF "pkill: left alone 2 matching process(es) working in another checkout: $other in $R/.claude/worktrees/other, $chat in $R" "$ERR"
done
printf '%s\n' "$other" >"$WORK/pids"
wpkill "$MINE" -f "$PAT"
assert eq "$?" 1
assert kill -0 "$other"
wpkill "$R" -f "$PAT"
assert [ -e "$WORK/real.log" ]
rm -f "$WORK/real.log"
(cd "$MINE" && PKILL_GUARD_REAL_DIR="$WORK/real2" "$WORK/path/pkill" -f "$PAT")
assert [ -e "$WORK/real.log" ]

ln -s "$ROOT/bin/pkill" "$WORK/path/pkill-other"
rm -f "$WORK/real.log"
"$WORK/path/pkill-other" -f "$PAT" >"$OUT" 2>"$ERR"
assert eq "$?" 2
assert [ ! -e "$WORK/real.log" ]

assert eq "$(readlink "$ROOT/bin/pgrep")" pkill
for tool in pkill pgrep; do
  assert grep -qF -- "- \`bin/$tool\` → \`~/.local/bin/$tool\`" "$ROOT/README.md"
done

printf 'PASS: %s asserts; pkill and pgrep refuse an option after the first pattern and pass everything else through untouched; pkill in a worker worktree leaves the processes of other checkouts alone\n' "$asserts"
