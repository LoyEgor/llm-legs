#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/light_research_harness.sh" || exit 1

# --attach lands a run whose first call is gone (a stopped background Bash) with the run's own exit code.
cat >"$BIN/geminib" <<'SLOW'
#!/usr/bin/env bash
if [ "$1" = list ]; then printf 'researcher: ready\n'; exit 0; fi
printf 'slow Gemini answer\n'
SLOW
rm -f "$WORK/answer"
run; rc=$?; assert test "$rc" -eq 0
slow_run=$(sed -n 's/^RUN: //p' "$WORK/out" | tail -1); assert test -d "$RUNS/$slow_run"
rm -f "$WORK/answer"
assert test ! -e "$REPO/answer-in-repo"
attach --attach "$slow_run" --out "$REPO/answer-in-repo"; rc=$?; assert test "$rc" -eq 2
assert test ! -e "$REPO/answer-in-repo"
attach --attach "$slow_run" --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'slow Gemini answer'; assert grep -q '^ACCOUNT: researcher (gemini)$' "$WORK/out"
assert grep -qx 'WEB: on' "$WORK/out"
# --attach lands the same headed answer file, and its stdout carries the header lines, not the answer.
assert grep -qx 'CITATIONS: 0/0' "$WORK/out"
assert grep -qx "ANSWER: $(cd "$WORK" && pwd -P)/answer" "$WORK/out"
assert test "$(grep -c 'slow Gemini answer' "$WORK/out")" = 0
attach --attach "$slow_run" --out "$WORK/answer" --repo "$REPO"; rc=$?; assert test "$rc" -eq 2
attach --attach codex-1-2-none --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: CODEX_UNAVAILABLE$' "$WORK/out"

# A batch exits on the worst rc a unit brought back — a usage limit is what the caller routes on —
# and keeps its units on disk, so an --attach of any unit reports the same.
cat >"$BIN/geminib" <<'QUOTASLOW'
#!/usr/bin/env bash
if [ "$1" = list ]; then printf 'researcher: ready\n'; exit 0; fi
log=''; brief=''
while [ "$#" -gt 1 ]; do
  case $1 in --log-file) log=$2 ;; --print) brief=$2 ;; esac
  shift
done
case $brief in
  *QUOTA-Q*) [ -z "$log" ] || printf 'RESOURCE_EXHAUSTED\n' >"$log"; exit 1 ;;
esac
printf 'slow Gemini answer\n'
QUOTASLOW
chmod +x "$BIN/geminib"
printf 'QUOTA-Q: the leg answers with a quota wall.\n' >"$WORK/prompt"
printf 'Research the repository slowly.\n' >"$WORK/prompt-slow"
rm -f "$WORK/answer"; rm -rf "$WORK/answer.units"
run --prompt-file "$WORK/prompt-slow"; rc=$?
assert test "$rc" -eq 3
assert test ! -e "$WORK/answer"
assert test "$(grep -c . "$WORK/answer.units/table")" = 2
assert test "$(cat "$WORK/answer.units/rc.0")" = 3
slow_run=$(sed -n 's/^RUN: //p' "$WORK/out" | tail -1)
attach --attach "$slow_run" --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 3
assert grep -qx 'OUTCOME: GEMINI_USAGE_LIMIT' "$WORK/out"
rm -rf "$WORK/answer.units"

# --attach re-assembles the WHOLE batch, not the one run it was handed: the other units' answers
# live beside --out, and the work directory of the launching call is long gone.
cat >"$BIN/geminib" <<'TWOSLOW'
#!/usr/bin/env bash
if [ "$1" = list ]; then printf 'researcher: ready\n'; exit 0; fi
brief=''
while [ "$#" -gt 1 ]; do
  case $1 in --print) brief=$2 ;; esac
  shift
done
case $brief in
  *'Second question'*) printf 'second batched answer\n' ;;
  *) printf 'first batched answer\n' ;;
esac
TWOSLOW
chmod +x "$BIN/geminib"
printf 'First question.\n' >"$WORK/prompt"
printf 'Second question.\n' >"$WORK/prompt2"
rm -f "$WORK/answer"; rm -rf "$WORK/answer.units"
run --prompt-file "$WORK/prompt2"; rc=$?
assert test "$rc" -eq 0
assert test -f "$WORK/answer.units/table"
batch_run=$(sed -n 's/^RUN: //p' "$WORK/out" | tail -1)
rm -f "$WORK/answer"
attach --attach "$batch_run" --out "$WORK/answer"; rc=$?
assert test "$rc" -eq 0
assert grep -qx 'first batched answer' "$WORK/answer"
assert grep -qx 'second batched answer' "$WORK/answer"
assert test "$(grep -n '^## Q1$' "$WORK/answer" | cut -d: -f1)" -lt "$(grep -n '^## Q2$' "$WORK/answer" | cut -d: -f1)"
assert test -f "$WORK/answer.units/table"
cp "$WORK/answer" "$WORK/first-answer"
while IFS=$'\t' read -r attached_run rest; do
  attach --attach "$attached_run" --out "$WORK/answer"; rc=$?
  assert test "$rc" -eq 0
  assert cmp -s "$WORK/first-answer" "$WORK/answer"
done <"$WORK/answer.units/table"

printf 'PASS: %s asserts; --attach lands a finished run and re-assembles a whole batch from its units table\n' "$asserts"
