#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/light_research_harness.sh"
. "$ROOT/share/test-scope.sh"
PROJECTS=$(git_projects "$ROOT")

# The toggle rows: absent means the gemini default, a vendor alone means its default model, and a
# light-only model is valid on a light row without reaching the worker table.
toggle(){ WORKER_PICK_CONFIG_FILE="$TOGGLE" bash -c '. "$1/share/worker-model.sh"; shift; "$@"' _ "$ROOT" "$@"; }
assert test "$(toggle worker_light_vendor research)" = gemini
assert test "$(toggle worker_light_model edit)" = "$(toggle worker_model_default_model gemini)"
assert test "$(toggle worker_light_effort research)" = high
printf 'worker=auto\nlight_research=claudeb:sonnet\nlight_edit=codex\n' >"$TOGGLE"
assert test "$(toggle worker_light_vendor research) $(toggle worker_light_model research) $(toggle worker_light_effort research)" = 'claudeb sonnet medium'
assert test "$(toggle worker_light_vendor edit) $(toggle worker_light_model edit)" = 'codex astra'
assert test "$(toggle eval 'worker_model_allows claudeb sonnet; echo $?')" = 1
printf 'light_research=mistral\nlight_edit=grok:opus\n' >"$TOGGLE"
assert test "$(toggle eval 'worker_light_vendor research 2>/dev/null; echo $?')" = 2
assert test "$(toggle eval 'worker_light_model edit 2>/dev/null; echo $?')" = 2
rm -f "$TOGGLE"

run
rc=$?; assert test "$rc" -eq 0
# The answer file is always headed by its citation count, and a body with no citation line is
# passed through whole under `CITATIONS: 0/0` — a closed yes/no answer stays legal.
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 0/0'
assert test "$(sed '1,2d' "$WORK/answer")" = 'tracked Gemini answer'
assert grep -q '^ACCOUNT: researcher (gemini)$' "$WORK/out"; assert grep -q '^RUN: gemini-' "$WORK/out"
assert grep -qx 'WEB: on' "$WORK/out"
assert test "$(sed -n 2p "$WORK/answer")" = 'LINKS: 0'
# The answer stays on disk: stdout carries the header lines and none of the answer.
assert grep -qx 'CITATIONS: 0/0' "$WORK/out"
assert grep -qx "ANSWER: $(cd "$WORK" && pwd -P)/answer" "$WORK/out"
assert grep -qx 'LINES: 3' "$WORK/out"
assert test "$(grep -c 'tracked Gemini answer' "$WORK/out")" = 0
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1); assert test -d "$RUNS/$run_id"; assert test -f "$RUNS/$run_id/meta.json"
assert jq -e '.role == "research" and .light == "research" and .account == "researcher" and .agy_model == "gemini-3.8-flash-high"' "$RUNS/$run_id/meta.json"
assert grep -q -- '--role research' "$WORK/picks"; assert grep -q '^profile=researcher$' "$WORK/gemini.log"
# geminib's capacity markers live in the cache every other Gemini launch reads, so research may write there.
assert grep -qxF "(allow file-write* (subpath \"$(readlink -f "$HOME/.cache/geminib")\"))" "$RUNS/$run_id/sandbox.sb"
FAKE_EDIT="$REPO/blocked" run; rc=$?; assert test "$rc" -eq 5; assert grep -q 'OUTCOME: READ_ONLY_VIOLATION' "$WORK/out"; assert test ! -e "$REPO/blocked"
assert jq -e --arg fake "$ROOT/bin/light-research" '.cli != $fake' "$RUNS/$run_id/meta.json"
assert grep -q 'supervise_gemini_research' "$ROOT/bin/worker-run"
# run_with_deadline installs the supervisor's TERM/INT traps in its CALLER's shell, so a subshell
# around the call orphans the sandboxed CLI when the run is signalled.
assert test "$(grep -cE '\(cd .*run_with_deadline' "$ROOT/share/light-research.sh")" = 0

mkdir -p "$HOME/.gemini-profiles/rescuer"
printf '%s\n' researcher rescuer >"$WORK/pick-queue"
FAKE_LOG_QUOTA=1 PICK_QUEUE="$WORK/pick-queue" run
rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'tracked Gemini answer'
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert jq -e '.walled_accounts == ["researcher"] and .account == "rescuer"' "$RUNS/$run_id/meta.json"

# A research brief names a round to read its logs, never to fix it: the prose scan that binds a
# hand-written fix brief to an open round is a workers-role door, and a ROUND: line here is refused.
mkdir -p "$WORKER_STATS_DIR/benches/20260801T140000Z-0a1b2c3"
printf '#!/usr/bin/env bash\nprintf "STUB FIX RULE %%s\\nwrite verdicts.jsonl rows\\n" "$*"\n' >"$BIN/review-bench"; chmod +x "$BIN/review-bench"
printf 'Read the cell logs of round 20260801T140000Z-0a1b2c3 and report how many steps each took.\n' >"$WORK/prompt"
run; rc=$?; assert test "$rc" -eq 0
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert test "$(jq 'has("review_round") or has("round_source")' "$RUNS/$run_id/meta.json")" = false
assert test ! -e "$RUNS/$run_id/fix-rule"
if grep -q 'STUB FIX RULE\|taken from the brief text' "$WORK/err" "$WORK/out" "$RUNS/$run_id/brief.launch" 2>/dev/null; then fail "a research run was bound to the round its brief only reads"; fi
printf 'ROUND: 20260801T140000Z-0a1b2c3\nRead the cell logs.\n' >"$WORK/prompt"
run; rc=$?; assert test "$rc" -ne 0
assert grep -q 'a research run fixes nothing' "$WORK/err" "$WORK/out"
printf 'Research the repository.\n' >"$WORK/prompt"

# The rename leaves no trace of the vendor-bound name outside git history.
old_name="gemini""-research"
assert test -z "$(git -C "$ROOT" grep -l -F "$old_name" -- . 2>/dev/null)"
setup_root=${CLAUDE_SETUP_ROOT:-$PROJECTS/claude-setup}
if [ -d "$setup_root/agents" ]; then
  assert test ! -e "$setup_root/agents/$old_name.md"; assert test -f "$setup_root/agents/light-worker.md"
fi

printf 'PASS: %s asserts; light toggle rows and defaults, tracked gemini research with its read-only sandbox, a log-only quota walling the account, and a research brief that names a round but never fixes it\n' "$asserts"
