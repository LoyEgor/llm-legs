#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/light_research_harness.sh"

# Light switched off in Egor's menu launches nothing and names why.
printf 'light_paused=on\n' >"$TOGGLE"
: >"$WORK/vendor.log"
run; rc=$?; assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: LIGHT_OFF' "$WORK/out"
assert test ! -s "$WORK/vendor.log"

# Every vendor runs the same tracked read-only role, placed by the light_research row alone.
printf 'light_research=claudeb:sonnet\n' >"$TOGGLE"
: >"$WORK/vendor.log"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'claude research answer'
assert grep -q '^ACCOUNT: researcher (claudeb)$' "$WORK/out"
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert jq -e '.vendor == "claudeb" and .role == "research" and .model == "sonnet" and .effort == "medium"' "$RUNS/$run_id/meta.json"
assert grep -q -- '--model sonnet --effort medium --output-format json --permission-mode plan' "$WORK/vendor.log"
assert test "$(grep -c -- '--dangerously-skip-permissions' "$WORK/vendor.log")" = 0

printf 'light_research=codex\n' >"$TOGGLE"
mkdir -p "$HOME/.codex-profiles/researcher"
: >"$WORK/vendor.log"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'codex research answer'
assert grep -q '^ACCOUNT: researcher (codex)$' "$WORK/out"
assert grep -q -- '--sandbox read-only' "$WORK/vendor.log"

printf 'light_research=grok\n' >"$TOGGLE"
: >"$WORK/vendor.log"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'grok research answer'
assert grep -q '^ACCOUNT: researcher (grok)$' "$WORK/out"
# Grok has no read-only mode: a tree that changed under the run fails it, answer withheld.
rm -f "$WORK/answer"
FAKE_GROK_EDIT="$REPO/file" run; rc=$?; assert test "$rc" -eq 5
assert grep -q '^OUTCOME: READ_ONLY_VIOLATION$' "$WORK/out"; assert test ! -e "$WORK/answer"
git -C "$REPO" checkout -q -- file

printf 'light_research=grok:opus\n' >"$TOGGLE"
run; rc=$?; assert test "$rc" -eq 4; assert grep -q '^OUTCOME: MODEL_REFUSED$' "$WORK/out"

# Light edit: `worker-run start light` takes vendor, model and effort from the light_edit row, and a
# light-only model stays refused on the full worker leg.
printf 'light_edit=claudeb:sonnet\n' >"$TOGGLE"
# A Light edit launches under the SCOPE/VERIFY contract (tests/test_light_edit.sh owns it): the
# brief fences the paths the run may touch, and without that line there is no launch at all.
printf 'SCOPE: file\nVERIFY: true\n\nEdit the repository file.\n' >"$WORK/edit-brief"
: >"$WORK/vendor.log"
wr start light --brief "$WORK/edit-brief" --workdir "$REPO"; rc=$?; assert test "$rc" -eq 0
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert jq -e '.vendor == "claudeb" and .role == "workers" and .light == "edit" and .model == "sonnet" and .effort == "medium"' "$RUNS/$run_id/meta.json"
wr wait "$run_id" --max 60; assert grep -q '^STATUS: done$' "$WORK/out"
assert grep -q -- '--dangerously-skip-permissions' "$HOME/.claude-profiles/researcher/vendor.log"
wr start claudeb --model sonnet --brief "$WORK/prompt" --workdir "$REPO"; rc=$?; assert test "$rc" -ne 0
assert grep -q '^OUTCOME: MODEL_REFUSED$' "$WORK/out"
printf 'light_edit=grok:opus\n' >"$TOGGLE"
wr start light --brief "$WORK/edit-brief" --workdir "$REPO"; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: MODEL_REFUSED$' "$WORK/out"
rm -f "$TOGGLE"

printf 'PASS: %s asserts; Light off launching nothing, tracked research on claudeb/codex/grok with each read-only mechanism, and `worker-run start light` from the light_edit row\n' "$asserts"
