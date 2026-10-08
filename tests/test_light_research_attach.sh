#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/light_research_harness.sh"

# One wait round per call: a run still going hands back its id, and --attach waits one more round
# and lands the answer with the run's own exit code.
# A unit holds until the test opens the gate: a fixed sleep was outlived by a launch under load.
cat >"$BIN/geminib" <<'GATED'
#!/usr/bin/env bash
if [ "$1" = list ]; then printf 'researcher: ready\n'; exit 0; fi
while [ ! -e "${0%/bin/*}/gate" ] && [ -d "${0%/*}" ]; do sleep 0.1; done
printf 'slow Gemini answer\n'
GATED
rm -f "$WORK/answer"
WORKER_RUN_LONG_RUN_S=0 LIGHT_RESEARCH_WAIT_MAX=0 run; rc=$?; assert test "$rc" -eq 0
assert grep -q '^STATUS: running$' "$WORK/out"; assert test ! -e "$WORK/answer"
# worker-run says LONG-RUN once per run, so a running round that drops it loses it for good.
assert grep -q '^LONG-RUN: 0 min' "$WORK/out"
# The state is recorded at launch, so the round that hands back a running id already names it.
assert grep -qx 'WEB: on' "$WORK/out"
assert grep -qx "OUT: $(cd "$WORK" && pwd -P)/answer" "$WORK/out"
slow_run=$(sed -n 's/^RUN: //p' "$WORK/out" | tail -1); assert test -d "$RUNS/$slow_run"
: >"$WORK/gate"
assert test ! -e "$REPO/answer-in-repo"
attach --attach "$slow_run" --out "$REPO/answer-in-repo"; rc=$?; assert test "$rc" -eq 2
assert test ! -e "$REPO/answer-in-repo"
attach --attach "$slow_run" --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'slow Gemini answer'; assert grep -q '^ACCOUNT: researcher (gemini)$' "$WORK/out"
# --attach lands the same headed answer file, and its stdout carries the header lines, not the answer.
assert grep -qx 'CITATIONS: 0/0' "$WORK/out"
assert grep -qx "ANSWER: $(cd "$WORK" && pwd -P)/answer" "$WORK/out"
assert test "$(grep -c 'slow Gemini answer' "$WORK/out")" = 0
attach --attach "$slow_run" --out "$WORK/answer" --repo "$REPO"; rc=$?; assert test "$rc" -eq 2
attach --attach codex-1-2-none --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: CODEX_UNAVAILABLE$' "$WORK/out"

# A batch whose last unit is still running still exits on the worst rc a finished unit brought
# back — a usage limit is what the caller routes on — and keeps the units it collected on disk.
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
while [ ! -e "${0%/bin/*}/gate" ] && [ -d "${0%/*}" ]; do sleep 0.1; done
printf 'slow Gemini answer\n'
QUOTASLOW
chmod +x "$BIN/geminib"
printf 'QUOTA-Q: the leg answers with a quota wall.\n' >"$WORK/prompt"
printf 'Research the repository slowly.\n' >"$WORK/prompt-slow"
rm -f "$WORK/answer" "$WORK/gate"; rm -rf "$WORK/answer.units"
LIGHT_RESEARCH_WAIT_MAX=10 run --prompt-file "$WORK/prompt-slow"; rc=$?
assert test "$rc" -eq 3
assert grep -q '^STATUS: running$' "$WORK/out"
assert test ! -e "$WORK/answer"
assert test "$(grep -c . "$WORK/answer.units/table")" = 2
assert test "$(cat "$WORK/answer.units/rc.0")" = 3
: >"$WORK/gate"; rm -rf "$WORK/answer.units"

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
while [ ! -e "${0%/bin/*}/gate" ] && [ -d "${0%/*}" ]; do sleep 0.1; done
case $brief in
  *'Second question'*) printf 'second batched answer\n' ;;
  *) printf 'first batched answer\n' ;;
esac
TWOSLOW
chmod +x "$BIN/geminib"
printf 'First question.\n' >"$WORK/prompt"
printf 'Second question.\n' >"$WORK/prompt2"
rm -f "$WORK/answer" "$WORK/gate"; rm -rf "$WORK/answer.units"
LIGHT_RESEARCH_WAIT_MAX=0 run --prompt-file "$WORK/prompt2"; rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^STATUS: running$' "$WORK/out")" = 2
assert test -f "$WORK/answer.units/table"
assert test ! -e "$WORK/answer"
batch_run=$(sed -n 's/^RUN: //p' "$WORK/out" | tail -1)
: >"$WORK/gate"
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

printf 'PASS: %s asserts; one wait round per call with --attach continuing a running run and re-assembling a whole batch\n' "$asserts"
