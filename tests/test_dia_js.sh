#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/dia-js over stubbed osascript, open and ps: tab choice, errors, the relaunch a Dia without
# --enable-applescript-javascript needs, the watcher mode's off switch and guard; then
# hammerspoon/dia-flag-watch.lua over stubbed hs.* (skipped without the Hammerspoon CLI).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }

DIA='/Applications/Dia.app/Contents/MacOS/Dia'
mkdir -p "$WORK/bin"
printf '  400 %s\n  401 %s --type=renderer\n' "$DIA" "$DIA" >"$WORK/ps.bare"
printf '  500 %s --enable-applescript-javascript\n' "$DIA" >"$WORK/ps.flag"
printf 'T1\t0\thttps://a.example/form\tForm\nT2\t1\thttps://b.example/\tFront\nT3\t0\thttps://a.example/other\tOther\n' >"$WORK/tabs.before"
printf 'N1\t1\thttps://b.example/\tFront\nN2\t0\thttps://a.example/form\tForm\nN3\t0\thttps://a.example/other\tOther\n' >"$WORK/tabs.after"
cat >"$WORK/bin/ps" <<EOF
#!/bin/sh
cat "$WORK/ps.now"
EOF
cat >"$WORK/bin/osascript" <<EOF
#!/bin/sh
cat >/dev/null
shift
printf '%s\n' "\$*" >>"$WORK/osa.log"
case "\$1" in
  list) cat "$WORK/tabs.now" ;;
  count) grep -c . "$WORK/tabs.now" ;;
  front) awk -F '\t' '\$2 == "1" { print \$3 }' "$WORK/tabs.now" ;;
  quit) : >"$WORK/ps.now"; : >"$WORK/tabs.now" ;;
  exec) printf 'ran %s focus=%s js=%s\n' "\$2" "\$3" "\$4" ;;
esac
EOF
cat >"$WORK/bin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/open.log"
case "\$*" in
  *--enable-applescript-javascript*) cp "$WORK/ps.flag" "$WORK/ps.now"; cp "$WORK/tabs.restored" "$WORK/tabs.now" ;;
esac
EOF
chmod +x "$WORK/bin/"*
export BROWSE_PS="$WORK/bin/ps" BROWSE_OPEN="$WORK/bin/open" DIA_JS_OSASCRIPT="$WORK/bin/osascript"
export DIA_JS_STATE_DIR="$WORK/state" DIA_JS_WAIT_S=3 DIA_JS_POLL_S=0.05
reset() { # ps tabs-now tabs-restored
  cp "$WORK/$1" "$WORK/ps.now"; cp "$WORK/$2" "$WORK/tabs.now"; cp "$WORK/$3" "$WORK/tabs.restored"
  rm -f "$WORK/osa.log" "$WORK/open.log"
}
DJ="$ROOT/bin/dia-js"

# 1: a flagged Dia runs the JavaScript in the chosen tab and nothing else
reset ps.flag tabs.before tabs.after
assert test "$(printf 'document.title' | "$DJ" --active)" = 'ran T2 focus=0 js=document.title'
assert test "$(printf 'x' | "$DJ" --tab-id T3)" = 'ran T3 focus=0 js=x'
printf 'from-file' >"$WORK/code.js"
assert test "$("$DJ" --url-contains /form --file "$WORK/code.js")" = 'ran T1 focus=0 js=from-file'
assert test "$(grep -c '^quit' "$WORK/osa.log")" -eq 0
assert test ! -e "$WORK/open.log"

# 2: no match and several matches are errors that run nothing
rm -f "$WORK/osa.log"
rc=0
err=$(printf 'x' | "$DJ" --url-contains nowhere 2>&1 >/dev/null) || rc=$?
assert test "$rc" -eq 1
assert grep -q 'no open Dia tab matches (url nowhere)' <<<"$err"
rc=0
err=$(printf 'x' | "$DJ" --url-contains a.example 2>&1 >/dev/null) || rc=$?
assert test "$rc" -eq 1
assert grep -q '2 Dia tabs match' <<<"$err"
assert grep -q 'T1  https://a.example/form  Form' <<<"$err"
assert test "$(grep -c '^exec' "$WORK/osa.log")" -eq 0
rc=0
"$DJ" --active </dev/null >/dev/null 2>&1 || rc=$?
assert test "$rc" -eq 1
rc=0
"$DJ" >/dev/null 2>&1 || rc=$?
assert test "$rc" -eq 2

# 3: a Dia without the flag is quit, reopened with it, and the tab found again by URL under its new id
reset ps.bare tabs.before tabs.after
out=$(printf 'fill()' | "$DJ" --url-contains /form 2>"$WORK/err")
assert test "$out" = 'ran N2 focus=1 js=fill()'
assert grep -qx 'quit' "$WORK/osa.log"
assert grep -qx -- '-b company.thebrowser.dia --args --enable-applescript-javascript' "$WORK/open.log"
assert grep -qx 'RELAUNCHED: yes' "$WORK/err"
assert grep -q '^WARNING: .*unsaved input on open pages may be lost' "$WORK/err"
assert test "$(grep -c '^REOPENED:' "$WORK/err")" -eq 0

# 4: a cold start's front tab that session restore does not bring back is reopened
printf 'N1\t1\thttps://restored.example/\tOld\n' >"$WORK/tabs.restored-only"
printf 'L1\t1\thttps://clicked.example/link\tLink\n' >"$WORK/tabs.cold"
reset ps.bare tabs.cold tabs.restored-only
out=$("$DJ" --relaunch 2>&1)
assert grep -qx 'REOPENED: https://clicked.example/link' <<<"$out"
assert grep -qx -- '-b company.thebrowser.dia https://clicked.example/link' "$WORK/open.log"

# 5: watcher mode: flagged or closed is silent, the off switch and the 2-minute guard skip
reset ps.flag tabs.before tabs.after
assert test -z "$("$DJ" --relaunch --auto 2>&1)"
assert test "$("$DJ" --relaunch)" = 'FLAGGED: yes, nothing to relaunch'
: >"$WORK/ps.now"
assert test -z "$("$DJ" --relaunch --auto 2>&1)"
reset ps.bare tabs.before tabs.after
mkdir -p "$WORK/state"
: >"$WORK/state/watch-off"
assert grep -q '^SKIPPED: watcher off' <<<"$("$DJ" --relaunch --auto)"
assert test ! -e "$WORK/open.log"
rm "$WORK/state/watch-off"
"$DJ" --relaunch --auto >/dev/null 2>&1
assert grep -q -- '--enable-applescript-javascript' "$WORK/open.log"
reset ps.bare tabs.before tabs.after
assert grep -q '^SKIPPED: relaunched [0-9]*s ago' <<<"$("$DJ" --relaunch --auto)"
assert test ! -e "$WORK/open.log"
touch -t 202601010000 "$WORK/state/last-relaunch"
"$DJ" --relaunch --auto >/dev/null 2>&1
assert grep -q -- '--enable-applescript-javascript' "$WORK/open.log"

# 5b: --open brings Dia forward and a closed one starts with the flag
reset ps.bare tabs.before tabs.after
"$DJ" --open
assert grep -qx -- '-b company.thebrowser.dia --args --enable-applescript-javascript' "$WORK/open.log"
assert test ! -e "$WORK/osa.log"

# 6: a Dia that never quits is left alone
reset ps.bare tabs.before tabs.after
printf '#!/bin/sh\ncat >/dev/null\nshift\ncase "$1" in count) echo 3 ;; front) echo https://b.example/ ;; esac\n' >"$WORK/bin/osascript-stuck"
chmod +x "$WORK/bin/osascript-stuck"
rc=0
err=$(DIA_JS_OSASCRIPT="$WORK/bin/osascript-stuck" DIA_JS_WAIT_S=1 "$DJ" --relaunch 2>&1) || rc=$?
assert test "$rc" -eq 1
assert grep -q 'did not quit' <<<"$err"
assert test ! -e "$WORK/open.log"

if command -v hs >/dev/null 2>&1; then
  output=$(python3 - "$ROOT/tests/dia_flag_watch_harness.lua" <<'HSPY'
import subprocess, sys, time
# Concurrent `hs -c` clients make the CLI exit 65 or crash now and then; a real harness error repeats.
for attempt in range(4):
    if attempt:
        time.sleep(attempt)
    result = subprocess.run(["hs", "-q", "-t", "60", "-c", f"return loadfile([[{sys.argv[1]}]])()"],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=70)
    if result.returncode == 0:
        break
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
HSPY
  ) || fail "the Hammerspoon harness threw or timed out: $output"
  result=$(printf '%s\n' "$output" | grep -v '^-- Loading extension: ' | awk '/^(PASS|FAIL)/ { found = 1 } found')
  case "$result" in
    'PASS: '[0-9]*' dia-flag-watch checks'*) asserts=$((asserts + 1)) ;;
    *) fail "${result:-$output}" ;;
  esac
else
  echo "   (Hammerspoon harness skipped: no hs CLI)"
fi

echo "PASS: $asserts asserts; dia-js tab choice, relaunch with the AppleScript flag, watcher guard; dia-flag-watch"
