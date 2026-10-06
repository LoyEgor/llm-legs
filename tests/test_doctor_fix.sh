#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  "$@" && fail "assert $asserts unexpectedly succeeded: $*"
  return 0
}
jqe() { jq -e "$@" >/dev/null; }

HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
DATA="$WORK/data"
OPENED="$WORK/opened"
RUNS="$WORK/doctors/runs"
export HOME DATA OPENED
export DOCTORS_DIR="$WORK/doctors" LLM_DOCTOR_DIR="$WORK/llm" HARNESS_DOCTOR_DIR="$WORK/harness" \
  UPDATER_DOCTOR_DIR="$WORK/updater" VENDOR_CLI_UPDATE_STATE_DIR="$WORK/vcu" DOCTOR_FIX_PROJECTS="$WORK/projects" \
  DOCTOR_FIX_OPENER="$FAKE_BIN/opener" DOCTOR_FIX_WORKER_PICK="$FAKE_BIN/worker-pick" \
  DOCTOR_FIX_VENDOR_CLI_UPDATE="$FAKE_BIN/vendor-cli-update" DOCTOR_FIX_DOCS="$WORK/docs" \
  LLM_DOCTOR_LEDGER="$WORK/ledgers/llm.json" HARNESS_LEDGER="$WORK/ledgers/harness.json" \
  UPDATER_DOCTOR_LEDGER="$WORK/ledgers/updater.json" HARNESS_SETTINGS="$WORK/settings.json" \
  DOCTOR_FIX_WORKTREE_REPO="$WORK/projects/llm-legs" LLM_DOCTOR_REPOS="$WORK/projects" HARNESS_REPOS_DIR="$WORK/projects" \
  WORKER_PICK_CONFIG_FILE="$HOME/.claude/worker-model"
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$FAKE_BIN" "$DATA" "$HOME" "$WORK/llm" "$WORK/harness" "$WORK/updater" "$WORK/vcu/events" "$WORK/projects" \
  "$WORK/docs/handoffs" "$WORK/ledgers"
printf '{"owner": "LLM owner", "owners": {}, "rows": [], "blind_spots": []}\n' >"$WORK/ledgers/llm.json"
: >"$OPENED"
cat >"$FAKE_BIN/opener" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$DATA/opener-fails" ] || exit 1
printf '%s\n' "$*" >>"$OPENED"
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$DATA/pick-args"\nprintf "acct-b\\n"\n' >"$FAKE_BIN/worker-pick"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/claudeb"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$DATA/vcu-args"\nprintf "vendor update started: fake\\n"\n' >"$FAKE_BIN/vendor-cli-update"
chmod +x "$FAKE_BIN"/*

FIX="$ROOT/bin/doctor-fix"
fix() { bash "$FIX" "$@"; }
now() { date +%s; }
doc() { # doctor as_of_s status problem_count judge [contract]
  jq -n --arg d "$1" --argjson s "$2" --arg st "$3" --argjson n "$4" --arg j "$5" --argjson c "${6:-1}" \
    '{contract: $c, doctor: $d, as_of: "2026-09-29T12:00:00+03:00", as_of_s: $s, judge: $j, status: $st, problem_count: $n,
      problems: [
        {id: "A", state: "new", fact: "a new bug"},
        {id: "B", state: "open", fact: "an open row"},
        {id: "C", state: "watch", fact: "a watched value"},
        {id: "D", state: "fixed-pending", fact: "a pending fix"},
        {id: "E", state: "regressed", fact: "a regressed fix"}],
      blind_spots: [], self: {collector_s: 0.1, error: null}}' >"$WORK/$1/latest.json"
}
record() { printf '%s/%s.json' "$RUNS" "$1"; }

# Launch refusals: no document, a foreign contract, a stale document, nothing to fix.
assert_fails fix launch llm 2>"$WORK/err"
assert grep -qF 'Refresh the doctor first.' "$WORK/err"
doc llm "$(now)" problems 3 j1 2
assert_fails fix launch llm 2>"$WORK/err"
assert grep -qF 'not 1. Refresh the doctor first.' "$WORK/err"
doc llm $(($(now) - 3 * 3600)) problems 3 j1
assert_fails fix launch llm 2>"$WORK/err"
assert grep -qF 'is 3 h old. Refresh the doctor first.' "$WORK/err"
doc llm "$(now)" ok 0 j1
assert_fails fix launch llm 2>"$WORK/err"
assert grep -qF 'nothing to fix' "$WORK/err"
assert [ ! -s "$OPENED" ]
assert [ -z "$(ls "$RUNS" 2>/dev/null)" ]

# A fresh document with problems opens one chat on the snapshot of its fixable problems.
doc llm $(($(now) - 60)) problems 3 j1
fix launch llm >"$WORK/out" || fail "launch llm failed"
id=$(sed -n 's/^llm fixer opened: run \(llm-all-[0-9]\{8\}T[0-9]\{6\}Z-[0-9a-f]\{4\}\), 3 problems$/\1/p' "$WORK/out")
assert [ -n "$id" ]
assert [ "$(wc -l <"$WORK/out" | tr -d ' ')" = 1 ]
R=$(record "$id")
assert jqe 'keys == (["id", "doctor", "area", "night", "created_at", "launched_at", "closed_at", "abandoned_at", "failed_at",
  "account", "session", "command", "branch", "worktrees", "judge_at_launch", "judge_at_close", "problems", "quiet", "decisions", "note"] | sort)' "$R"
assert jqe --arg id "$id" '.id == $id and .doctor == "llm" and .area == "all" and .night == null and .account == "acct-b"
  and .judge_at_launch == "j1" and .closed_at == null and .abandoned_at == null and .failed_at == null and .decisions == []
  and .note == null and .branch == null and .worktrees == []' "$R"
assert jqe '[.created_at, .launched_at] | all(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' "$R"
assert jqe '[.problems[] | {id, state, fact}] == [{id: "A", state: "new", fact: "a new bug"}, {id: "B", state: "open", fact: "an open row"},
  {id: "E", state: "regressed", fact: "a regressed fix"}]' "$R"
assert jqe --arg e "$WORK/projects/llm-legs/bin/llm-doctor" '[.problems[] | .area] == ["doctor", "doctor", "doctor"]
  and all(.problems[]; .component.files == [$e])' "$R"
session=$(jq -r .session "$R")
assert grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' <<<"$session"
assert_fails grep -qF "$session" "$WORK/out"
# The chat opens through the shared helper: picked account, pinned session, strong model, the procedure.
assert [ "$(jq -r .command "$R")" = "$RUNS/$id.command" ]
assert [ "$(cat "$OPENED")" = "$RUNS/$id.command" ]
assert grep -qxF -- '--account claudeb --role chat --model opus --claim' "$DATA/pick-args"
assert grep -qxF "cd $(printf '%q' "$ROOT") || exit 1" "$RUNS/$id.command"
assert test "$(grep -c 'chat-pin' "$RUNS/$id.command")" = 0
assert grep -qF -- "exec $FAKE_BIN/claudeb profile acct-b --session-id $session --model opus --effort high Doctor\\ fixer\\ run\\ $id:\\ read\\ $ROOT/docs/doctor-fix.md\\ in\\ full\\ and\\ follow\\ it\\ for\\ this\\ run." "$RUNS/$id.command"

# An open run younger than 12 h is named, and no second chat opens; an older one is abandoned.
assert_fails fix launch llm 2>"$WORK/err"
assert grep -qF "run $id of the llm doctor is still open" "$WORK/err"
assert [ "$(wc -l <"$OPENED" | tr -d ' ')" = 1 ]
jq --arg t "$(date -u -r $(($(now) - 13 * 3600)) +%Y-%m-%dT%H:%M:%SZ)" '.launched_at = $t' "$R" >"$WORK/r" && mv "$WORK/r" "$R"
sleep 1
fix launch llm >"$WORK/out" 2>&1 || fail "launch over an old run failed"
assert grep -qF "run $id abandoned: open for 13 h" "$WORK/out"
assert jqe '.abandoned_at != null and .closed_at == null' "$R"
id2=$(sed -n 's/^llm fixer opened: run \(llm-[^,]*\), 3 problems$/\1/p' "$WORK/out")
assert [ -n "$id2" ] && assert [ "$id2" != "$id" ]
R2=$(record "$id2")
# Another doctor's open run is no obstacle. Runs list newest first, by the second they were made.
sleep 1
doc harness "$(now)" problems 1 h1
fix launch harness >"$WORK/out" || fail "launch harness failed"
hid=$(sed -n 's/^harness fixer opened: run \(harness-[^,]*\), 3 problems$/\1/p' "$WORK/out")
assert [ -n "$hid" ]
# A chat that does not open leaves an unopened record and fails.
sleep 1
: >"$DATA/opener-fails"
jq '.launched_at = "2026-01-01T00:00:00Z"' "$(record "$hid")" >"$WORK/r" && mv "$WORK/r" "$(record "$hid")"
assert_fails fix launch harness 2>"$WORK/err" >/dev/null
rm "$DATA/opener-fails"
assert grep -qF 'the harness fixer did not open' "$WORK/err"
failed=$(fix runs harness --json | jq -r '.[0].id')
assert jqe '.launched_at == null and .failed_at != null and (.note | startswith("chat did not open"))' "$(record "$failed")"
assert_fails fix close "$failed" --decisions /dev/null "x" 2>"$WORK/err"
assert grep -qF "run $failed failed to launch: chat did not open" "$WORK/err"

# Close refusals. The doctor must have rerun since the launch.
mkdir -p "$WORK/projects/proj"
git -C "$WORK/projects/proj" init -q
printf 'why\n' >"$WORK/projects/proj/README"
git -C "$WORK/projects/proj" add README
git -C "$WORK/projects/proj" -c user.name=t -c user.email=t@t commit -qm purpose
hash=$(git -C "$WORK/projects/proj" rev-parse --short HEAD)
# The llm-legs repository: its doctors are the doctor area's entry and what night worktrees rerun.
L="$WORK/projects/llm-legs"
mkdir -p "$L/bin"
for d in llm harness updater code; do
  cat >"$L/bin/$d-doctor" <<EOF
#!/bin/bash
printf '%s\n' "\$PWD" >>"\$DATA/$d-doctor-runs"
if [ -f "\$DATA/$d-doc.json" ]; then cat "\$DATA/$d-doc.json"; else printf '{"judge": "base-$d"}\n'; fi
EOF
done
chmod +x "$L"/bin/*
git -C "$L" init -q && git -C "$L" add bin && git -C "$L" -c user.name=t -c user.email=t@t commit -qm base
lhash=$(git -C "$L" rev-parse --short HEAD)
printf 'A\tfixed\tllm-legs@%s\tbin/x.py:12 fixed; tests/test_x.sh\nB\truled-out\tllm-legs/bin/llm-doctor:40\tthe row is the design\nE\tweather\tllm-legs/bin/llm-doctor\tvendor 429s\n' \
  "$lhash" >"$WORK/decisions"
assert_fails fix close "$id2" --decisions "$WORK/decisions" "done" 2>"$WORK/err"
assert grep -qF 'rerun the llm doctor, the proof reads its fresh numbers' "$WORK/err"
doc llm $(($(now) + 5)) problems 3 j1
# Every problem id needs a decision.
head -n 2 "$WORK/decisions" >"$WORK/partial"
assert_fails fix close "$id2" --decisions "$WORK/partial" "done" 2>"$WORK/err"
assert grep -qxF 'E: undecided' "$WORK/err"
# A purpose must resolve: a file that exists, or a commit in that project.
sed 's#llm-legs/bin/llm-doctor:40#docs/no-such-file.md#' "$WORK/decisions" >"$WORK/bad-path"
assert_fails fix close "$id2" --decisions "$WORK/bad-path" "done" 2>"$WORK/err"
assert grep -qF "line 2 (B): purpose 'docs/no-such-file.md' resolves to no commit" "$WORK/err"
assert grep -qxF 'B: undecided' "$WORK/err"
sed "s#llm-legs@$lhash#llm-legs@deadbeef#" "$WORK/decisions" >"$WORK/bad-commit"
assert_fails fix close "$id2" --decisions "$WORK/bad-commit" "done" 2>"$WORK/err"
assert grep -qF "line 1 (A): purpose 'llm-legs@deadbeef' resolves to no commit" "$WORK/err"
sed 's#llm-legs/bin/llm-doctor:40#llm-legs/bin#' "$WORK/decisions" >"$WORK/dir-purpose"
assert_fails fix close "$id2" --decisions "$WORK/dir-purpose" "done" 2>/dev/null
# A problem with no ledger fix still has its block's entry file: a purpose elsewhere does not touch it.
sed 's#llm-legs/bin/llm-doctor:40#proj/README#' "$WORK/decisions" >"$WORK/off-component"
assert_fails fix close "$id2" --decisions "$WORK/off-component" "done" 2>"$WORK/err"
assert grep -qF "line 2 (B): purpose 'proj/README' does not touch the component" "$WORK/err"
sed 's#\tvendor 429s$#\t#' "$WORK/decisions" >"$WORK/no-evidence"
assert_fails fix close "$id2" --decisions "$WORK/no-evidence" "done" 2>"$WORK/err"
assert grep -qF 'line 3 (E): no evidence' "$WORK/err"
sed 's#\truled-out\t#\tdone\t#' "$WORK/decisions" >"$WORK/bad-verdict"
assert_fails fix close "$id2" --decisions "$WORK/bad-verdict" "done" 2>"$WORK/err"
assert grep -qF "line 2 (B): verdict 'done' is not one of" "$WORK/err"
# A judge that changed since launch needs its own line.
doc llm $(($(now) + 5)) problems 3 j2
assert_fails fix close "$id2" --decisions "$WORK/decisions" "done" 2>"$WORK/err"
assert grep -qF "judge: the llm doctor's judge changed since launch (j1 -> j2)" "$WORK/err"
assert jqe '.closed_at == null and .decisions == []' "$R2"
printf 'judge\tchanged\tdocs/doctors-contract.md\tthe owner narrowed a dismissal row\n' >>"$WORK/decisions"
# The judge line cites the judge itself: the doctor's code or its ledger.
assert_fails fix close "$id2" --decisions "$WORK/decisions" "done" 2>"$WORK/err"
assert grep -qF "line 4 (judge): purpose 'docs/doctors-contract.md' does not touch the component" "$WORK/err"
sed -i '' 's#^judge\tchanged\tdocs/doctors-contract.md#judge\tchanged\tbin/llm-doctor#' "$WORK/decisions"
# fixed needs the doctor's rerun to read the problem fixed-pending or gone.
assert_fails fix close "$id2" --decisions "$WORK/decisions" "done" 2>"$WORK/err"
assert grep -qxF 'line 1 (A): fixed, but the rerun llm doctor still reads it new: a fix leaves it fixed-pending or gone' "$WORK/err"
jq '(.problems[] | select(.id == "A") | .state) = "fixed-pending"' "$WORK/llm/latest.json" >"$WORK/l" && mv "$WORK/l" "$WORK/llm/latest.json"
cp "$WORK/ledgers/llm.json" "$WORK/ledger-kept"
jq '.rows = [{id: "R1", fixes: [{at: "2026-09-01T00:00:00+00:00", by: "c", files: ["llm-legs/bin/x"], in: null}]}]' \
  "$WORK/ledger-kept" >"$WORK/ledgers/llm.json"
assert_fails fix close "$id2" --decisions "$WORK/decisions" "x" 2>"$WORK/err"
assert grep -qF "ledger $WORK/ledgers/llm.json: row R1 fixes[0] lacks regressed_at: every fix record is {at, by, files, in, regressed_at}" "$WORK/err"
cp "$WORK/ledger-kept" "$WORK/ledgers/llm.json"
# A day run's markdown is nobody's to measure: only a night run is net zero.
printf '%0500d\n' 0 >"$L/DAY.md"
fix close "$id2" --decisions "$WORK/decisions" "three fixed or ruled out" >"$WORK/out" || fail "clean close failed"
rm "$L/DAY.md"
assert grep -qxF "run $id2 closed: 4 decisions" "$WORK/out"
assert jqe '.closed_at != null and .judge_at_close == "j2" and .note == "three fixed or ruled out"' "$R2"
assert jqe --arg h "llm-legs@$lhash" '.decisions == [
  {id: "A", verdict: "fixed", purpose: $h, evidence: "bin/x.py:12 fixed; tests/test_x.sh"},
  {id: "B", verdict: "ruled-out", purpose: "llm-legs/bin/llm-doctor:40", evidence: "the row is the design"},
  {id: "E", verdict: "weather", purpose: "llm-legs/bin/llm-doctor", evidence: "vendor 429s"},
  {id: "judge", verdict: "changed", purpose: "bin/llm-doctor", evidence: "the owner narrowed a dismissal row"}]' "$R2"
assert_fails fix close "$id2" --decisions "$WORK/decisions" "again" 2>/dev/null

# show and runs.
fix show "$id2" >"$WORK/show"
assert grep -qF "run $id2 · llm doctor · area all · closed" "$WORK/show"
assert grep -qF "  E	regressed	a regressed fix" "$WORK/show"
assert grep -qF "  judge	changed	bin/llm-doctor	the owner narrowed a dismissal row" "$WORK/show"
assert_fails grep -qF "$(jq -r .session "$R2")" "$WORK/show"
fix runs >"$WORK/runs"
assert [ "$(cut -f1 "$WORK/runs" | xargs)" = "$failed $hid $id2 $id" ]
assert [ "$(cut -f2 "$WORK/runs" | xargs)" = "failed abandoned closed abandoned" ]
assert [ "$(fix runs llm --json | jq -r 'map(.id) | join(" ")')" = "$id2 $id" ]
assert [ -z "$(fix runs --open)" ]

# Updater runs: recorded by vendor-fingerprint's launch, closed with their last event, never by close.
jq -n '{id: "grok-1", vendor: "grok", from: "1.0.40", to: "1.0.44", substantive: ["ids"]}' >"$WORK/vcu/events/grok-1.json"
jq -n '{contract: 1, doctor: "updater", judge: "u1"}' >"$WORK/updater/latest.json"
uid=$(fix record updater --session s-1 --account acct-b --command "$WORK/cmd" --problems grok-1 claude-9) || fail "record updater failed"
assert jqe '.doctor == "updater" and .area == "release" and .launched_at == .created_at and .judge_at_launch == "u1" and .session == "s-1"
  and .problems == [{id: "grok-1", state: "open", fact: "grok 1.0.40 → 1.0.44: ids"}, {id: "claude-9", state: "open", fact: null}]' "$(record "$uid")"
assert [ "$(fix runs --open | cut -f1)" = "$uid" ]
assert_fails fix close "$uid" --decisions "$WORK/decisions" "x" 2>"$WORK/err"
assert grep -qF 'through vendor-fingerprint close' "$WORK/err"
printf '[{"id":"grok-1","verdict":"integrated","purpose":null,"evidence":"1 decision rows"}]\n' >"$WORK/ujson"
fix record-close "$uid" --decisions "$WORK/ujson" "grok-1: integrated" || fail "record-close failed"
assert jqe '.closed_at != null and .judge_at_close == "u1" and .decisions[0].verdict == "integrated" and .note == "grok-1: integrated"' "$(record "$uid")"
fix launch updater >"$WORK/out" || fail "launch updater failed"
assert [ "$(cat "$WORK/out")" = "vendor update started: fake" ]
assert [ "$(cat "$DATA/vcu-args")" = now ]
# A night vendor run has no chat: its night, branch and worktree instead, so show and abandon reach it.
nid=$(fix record updater --night n9 --branch night/n9/grok --worktree "$WORK/wt-grok" --problems grok-1) ||
  fail "record updater --night failed"
assert jqe --arg w "$WORK/wt-grok" '.night == "n9" and .area == "release" and .branch == "night/n9/grok" and .worktrees == [$w]
  and .session == null and .account == null and .command == null and .launched_at != null
  and [.problems[].id] == ["grok-1"]' "$(record "$nid")"
fix show "$nid" >"$WORK/show"
assert grep -qxF "night n9 · branch night/n9/grok · worktrees $WORK/wt-grok" "$WORK/show"
assert_fails fix record updater --night n9 --problems grok-1 2>/dev/null
assert_fails fix record updater --night n9 --branch b --worktree w --session s --problems grok-1 2>/dev/null
fix record-close "$nid" --decisions "$WORK/ujson" "grok-1: integrated" || fail "record-close of a night vendor run failed"

# Parallel record writes never share an id.
for n in 1 2 3 4 5 6; do fix record updater --session "s-$n" --account a --command c --problems "e-$n" >"$DATA/par-$n" & done
wait
assert [ "$(cat "$DATA"/par-* | sort -u | grep -cE '^updater-release-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$')" = 6 ]
for n in 1 2 3 4 5 6; do assert jqe --arg s "s-$n" '.session == $s' "$(record "$(cat "$DATA/par-$n")")"; done

# Night fixtures: a component repository, docs and memory beside the llm-legs repository the worktrees branch from.
mkdir -p "$WORK/projects/claude-setup/hooks" "$WORK/projects/review-bench/bin" "$HOME/.claude-profiles/p1/projects/-Volumes-Work-Projects-llm-legs/memory"
printf '#!/bin/bash\n' >"$WORK/projects/review-bench/bin/review-bench"
printf '#!/bin/bash\n' >"$WORK/projects/claude-setup/hooks/gate.sh"
jq -n --arg c "$WORK/projects/claude-setup/hooks/gate.sh" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]}}' \
  >"$WORK/settings.json"
printf 'other\n' >"$WORK/projects/proj/OTHER"
git -C "$WORK/projects/proj" add OTHER && git -C "$WORK/projects/proj" -c user.name=t -c user.email=t@t commit -qm other
other=$(git -C "$WORK/projects/proj" rev-parse --short HEAD)
jq -n '{owner: "LLM owner", owners: {reviewers: "RB chat", workers: "W chat"}, blind_spots: [],
  rows: [{id: "R9", title: "a twice-fixed row", block: "reviewers", match: {word: "crashed", detail: "boom"}, status: "fixed-pending",
    fixes: [{at: "2026-09-01T00:00:00Z", by: "a chat", files: ["proj/README"], in: null, regressed_at: null}],
    same_cause: ["R8"], handoff: "docs/handoffs/h.md"},
    {id: "Q1", title: "a quiet row", block: "workers", match: {word: "bad output"}, status: "open", fixes: [],
      note: "the cause in the judge prompt still stands"},
    {id: "Q2", title: "a dismissed row", block: "workers", match: {word: "crashed"}, status: "not-a-bug", fixes: []}]}' >"$WORK/ledgers/llm.json"
printf '# R9 again\n\nStatus: open\nR9 crashed twice.\n' >"$WORK/docs/handoffs/2026-09-30-r9.md"
printf '# unrelated\n\nR99 only.\n' >"$WORK/docs/handoffs/2026-09-30-other.md"
printf '| # | Invariant |\n|---|---|\n| zz | R9 stays narrow |\n| yy | nothing |\n' >"$WORK/docs/shared-invariants.md"
M="$HOME/.claude-profiles/p1/projects/-Volumes-Work-Projects-llm-legs/memory"
printf 'R9 was fixed twice.\n' >"$M/r9.md"
printf 'R99 is another row.\n' >"$M/r99.md"
jq -n '{id: "llm-reviewers-20260101T000000Z-0000", doctor: "llm", area: "reviewers", created_at: "2026-01-01T00:00:00Z",
  launched_at: "2026-01-01T00:00:00Z", closed_at: "2026-01-01T01:00:00Z", problems: [],
  decisions: [{id: "R9", verdict: "ruled-out", purpose: "proj/README", evidence: "old evidence"}]}' \
  >"$RUNS/llm-reviewers-20260101T000000Z-0000.json"
jq -n --argjson s "$(now)" '{contract: 1, doctor: "llm", as_of_s: $s, judge: "live-j", status: "problems", problem_count: 4,
  blocks: [{block: "reviewers", machinery: {classes: [{class: "anchors"}]}, problems: []}, {block: "workers", problems: []}],
  health: [{name: "debt", rules: [{rule: "debt-gap", key: "x"}, {rule: "debt-handoff", key: "proj/h"}]}],
  problems: [
    {id: "leg-escape:workers/escaped", rule: "leg-escape", state: "new", fact: "escaped", ledger: null},
    {id: "R9", rule: "leg-failure", state: "regressed", fact: "crashed again", ledger: "R9"},
    {id: "debt-gap:x", rule: "debt-gap", state: "new", fact: "a debt gap", ledger: null},
    {id: "debt-handoff:proj/h", rule: "debt-handoff", state: "new", fact: "a stale handoff: night-run carry owns it", ledger: null},
    {id: "W", rule: "leg-failure", state: "watch", fact: "watched", ledger: null},
    {id: "machinery:anchors", rule: "machinery", state: "new", fact: "anchors", ledger: null}]}' >"$WORK/llm/latest.json"

# An unknown argument after the night id (a "--dry-run" probe) is refused before any run is launched.
before=$(ls "$RUNS"/*.json)
assert_fails fix launch harness --night n0 --dry-run >/dev/null 2>"$WORK/err"
assert grep -qF 'usage: doctor-fix launch' "$WORK/err"
assert [ "$(ls "$RUNS"/*.json)" = "$before" ]

# A night with no base ref fails its runs instead of branching from HEAD.
before=$(ls "$RUNS"/*.json)
assert_fails fix launch llm --night n0 >/dev/null 2>"$WORK/err"
assert grep -qF "worktree not created: no refs/night/n0/base in $L" "$WORK/err"
for f in $(comm -13 <(printf '%s\n' "$before") <(ls "$RUNS"/*.json)); do assert jqe '.failed_at != null and .launched_at == null' "$f"; done
assert [ -z "$(git -C "$L" branch --list 'night/n0/*')" ]
mkdir -p "$L/docs" && printf '%0199d\n' 0 >"$L/docs/stale.md"
git -C "$L" add docs && git -C "$L" -c user.name=t -c user.email=t@t commit -qm stale
for n in n1 n3 n4; do git -C "$L" update-ref "refs/night/$n/base" HEAD; done
git -C "$WORK/projects/proj" update-ref refs/night/n1/base HEAD
eval "$(sed -n '/^brief_add_dirs() {/,/^}/p' "$ROOT/bin/worker-run")"

# A night launch opens no chat: one run per area, each with its worktree on its own branch and a brief.
# A fix's files resolve where the doctor itself resolves them, never through doctor-fix's own projects dir.
opened_before=$(wc -l <"$OPENED")
DOCTOR_FIX_PROJECTS="$WORK/nowhere" fix launch llm --night n1 >"$WORK/night" 2>"$WORK/err" ||
  fail "night launch failed: $(cat "$WORK/err")"
assert [ "$(wc -l <"$OPENED")" = "$opened_before" ]
assert [ "$(wc -l <"$WORK/night" | tr -d ' ')" = 3 ]
assert [ "$(cut -f1 "$WORK/night" | sed -E 's/^llm-([a-z]+)-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$/\1/' | xargs)" = "debt reviewers workers" ]
rid=$(awk -F'\t' '$1 ~ /^llm-reviewers-/ {print $1}' "$WORK/night")
wid=$(awk -F'\t' '$1 ~ /^llm-workers-/ {print $1}' "$WORK/night")
hid=$(awk -F'\t' '$1 ~ /^llm-debt-/ {print $1}' "$WORK/night")
WT="$L/.claude/worktrees/night-n1-$rid"
assert [ "$(grep "^$rid" "$WORK/night")" = "$rid	$RUNS/$rid.brief.md	$WT" ]
assert [ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "night/n1/$rid" ]
assert grep -qxF '.claude/worktrees/' "$L/.git/info/exclude"
assert [ -z "$(git -C "$L" status --porcelain)" ]
RR=$(record "$rid")
# Each other repository the component lives in gets its worktree on the same branch, granted by an
# ADD-DIR: line worker-run's own parser reads; one it cannot branch (review-bench, no repository) gets none.
PW="$WORK/projects/proj/.claude/worktrees/night-n1-$rid"
assert [ "$(git -C "$PW" rev-parse --abbrev-ref HEAD)" = "night/n1/$rid" ]
assert [ "$(brief_add_dirs "$RUNS/$rid.brief.md")" = "$PW" ]
assert [ "$(sed -n 2p "$RUNS/$rid.brief.md")" = "ADD-DIR: $PW" ]
# A brief citing an open review round's id without ROUND: is refused by worker-run; a fixer fixes no round.
assert [ "$(head -n 1 "$RUNS/$rid.brief.md")" = "ROUND: none" ]
assert [ "$(head -n 1 "$RUNS/$wid.brief.md")" = "ROUND: none" ]
assert [ -z "$(brief_add_dirs "$RUNS/$wid.brief.md")" ]
assert jqe --arg w "$WT" --arg p "$PW" --arg b "night/n1/$rid" '.night == "n1" and .area == "reviewers" and .branch == $b and .worktrees == [$w, $p]
  and .launched_at != null and .failed_at == null and .account == null and .judge_at_launch == "base-llm"
  and ([.problems[].id] == ["R9", "machinery:anchors"])' "$RR"
assert jqe --arg f "$WORK/projects/proj/README" --arg e "$WORK/projects/review-bench/bin/review-bench" '.problems[0].component.files == [$f, $e]
  and .problems[1].component.files == [$e]
  and .problems[0].component.what == "reviewers block · owner «RB chat»"
  and (.problems[0].component.rule_at | startswith("bin/llm-doctor:"))
  and .problems[1].component.what == "review-bench doctor class anchors · reviewers block · owner «RB chat»"' "$RR"
assert jqe '[.problems[].id] == ["debt-gap:x"] and .quiet == []' "$(record "$hid")"
# Debt health is the doctor's own handoff reader: the run gets its worktree alone.
assert jqe --arg p "$WORK/projects" '.problems[0].component.files == (["llm-legs/bin/llm-doctor"]
  | map($p + "/" + .))' "$(record "$hid")"
# An open ledger row no current problem matched is known but quiet: its own section in its area's brief.
assert jqe --arg e "$WORK/projects/llm-legs/bin/worker-run" '[.problems[].id] == ["leg-escape:workers/escaped"]
  and [.quiet[] | {id, state, area, files: .component.files}] == [{id: "Q1", state: "quiet", area: "workers", files: [$e]}]' "$(record "$wid")"
WB="$RUNS/$wid.brief.md"
assert grep -qF 'area workers · 1 problems · 1 known, quiet.' "$WB"
assert grep -qF 'Your scope is the problems below and the known quiet rows after them' "$WB"
assert grep -qxF "known, quiet (1): open ledger rows the doctor did not see in its window. Check in the code whether each cause still stands, then fix it, or write in the row's note why not:" "$WB"
assert grep -qxF "$(printf '  Q1\tquiet\ta quiet row')" "$WB"
assert grep -qxF "    note: the cause in the judge prompt still stands" "$WB"
assert grep -qF "Whatever you found but did not fix, and every cause you ruled out, goes into the ledger" "$WB"
assert [ "$(grep -c 'known, quiet (' "$RUNS/$rid.brief.md")" = 0 ]
# The brief is complete: the procedure, the close line with a run-local document, and the packet.
B="$RUNS/$rid.brief.md"
assert grep -qF "docs/doctor-fix.md\`: sections 0-6, \"Night\" and \"LLM doctor\" only." "$B"
assert grep -qF "cd $WT && DOCTORS_DIR=$WORK/doctors bin/doctor-fix close $rid --decisions $RUNS/$rid.d/decisions.tsv <one-line note>" "$B"
assert grep -qF 'Close reruns `bin/llm-doctor --json` in this worktree itself' "$B"
assert grep -qF 'Look at the older blocks around what you touch, not only at what you add' "$B"
assert grep -qF 'hand off to the next night, whose `night-run carry` makes every open handoff a job; Egor gets only a trade, a handoff whose `To:` names him carrying `Cost:`, `Loss:` and `Recommendation:` lines.' "$B"
assert grep -qF 'Markdown is net zero at night: close refuses a worktree whose *.md bytes (handoffs included) grew since `refs/night/n1/base`, so for every line you add cut stale ones' "$B"
assert grep -qF 'Settle every stuck review round (`machinery:closure_pending`) of the sweep repositories yourself' "$B"
assert grep -qF 'never touch a round of another project' "$B"
assert [ "$(grep -c 'Settle every stuck review round' "$WB")" = 0 ]
assert grep -qxF "  R9	regressed	crashed again" "$B"
assert grep -qxF "    ledger R9 fixed-pending · a twice-fixed row" "$B"
assert grep -qxF "    fix 2026-09-01T00:00:00Z by a chat: proj/README → None" "$B"
assert grep -qxF "    same cause: R8" "$B"
assert grep -qxF "    handoff: docs/handoffs/h.md" "$B"
assert grep -qxF "    earlier llm-reviewers-20260101T000000Z-0000 ruled-out: old evidence" "$B"
assert grep -qxF "    file $WORK/projects/proj/README" "$B"
assert grep -qE "^      created $hash [0-9-]{10} purpose$" "$B"
assert grep -qxF "    handoffs: docs/handoffs/2026-09-30-r9.md" "$B"
assert grep -qxF "    invariant rows: zz" "$B"
assert grep -qxF "    memory: ~/.claude-profiles/p1/projects/-Volumes-Work-Projects-llm-legs/memory/r9.md" "$B"
fix show "$rid" >"$WORK/show"
assert grep -qxF "night n1 · branch night/n1/$rid · worktrees $WT $PW" "$WORK/show"
# One open run per (doctor, area): a second launch of the same night makes nothing.
before=$(ls "$RUNS"/*.json | wc -l)
fix launch llm --night n1 >"$WORK/night2" 2>"$WORK/err" || fail "a held night relaunch failed"
assert [ ! -s "$WORK/night2" ]
assert grep -qF "run $rid of the llm doctor is still open" "$WORK/err"
assert [ "$(ls "$RUNS"/*.json | wc -l)" = "$before" ]
assert_fails fix launch llm 2>/dev/null

# A night close reruns the doctor in the run's worktree itself, once per close: a document the worker
# hands in proves nothing. Every purpose must touch its component.
printf 'R9\tfixed\tproj@%s\tproj/README fixed; tests/x\nmachinery:anchors\thandoff\treview-bench/bin/review-bench\tdocs/handoffs/2026-09-30-r9.md\n' "$hash" >"$WORK/nd"
night_doc() { # R9-state judge [doctor] -> what the worktree's llm doctor prints
  jq -n --argjson s $(($(now) + 5)) --arg st "$1" --arg j "$2" --arg d "${3:-llm}" '{contract: 1, doctor: $d, as_of_s: $s, judge: $j,
    problems: [{id: "R9", state: $st}, {id: "machinery:anchors", state: "new"}]}' >"$DATA/llm-doc.json"
}
mkdir -p "$RUNS/$rid.d"
jq -n --argjson s $(($(now) + 5)) '{contract: 1, doctor: "llm", as_of_s: $s, judge: "base-llm", problems: []}' >"$RUNS/$rid.d/forged.json"
assert_fails fix close "$rid" --decisions "$WORK/nd" --doc "$RUNS/$rid.d/forged.json" "x" 2>/dev/null
night_doc regressed base-llm harness
assert_fails fix close "$rid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qF "$RUNS/$rid.d/latest.json is no contract-1 llm doctor document" "$WORK/err"
night_doc regressed base-llm
: >"$DATA/llm-doctor-runs"
assert_fails fix close "$rid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qxF 'line 1 (R9): fixed, but the rerun llm doctor still reads it regressed: a fix leaves it fixed-pending or gone' "$WORK/err"
assert [ "$(cat "$DATA/llm-doctor-runs")" = "$WT" ]
night_doc fixed-pending base-llm
sed "s#^R9\tfixed\tproj@$hash#R9\tfixed\tproj@$other#" "$WORK/nd" >"$WORK/nd-other"
assert_fails fix close "$rid" --decisions "$WORK/nd-other" "x" 2>"$WORK/err"
assert grep -qF "line 1 (R9): purpose 'proj@$other' does not touch the component" "$WORK/err"
sed 's#^R9\tfixed\tproj@[0-9a-f]*#R9\tfixed\tdocs/doctors-contract.md#' "$WORK/nd" >"$WORK/nd-path"
assert_fails fix close "$rid" --decisions "$WORK/nd-path" "x" 2>"$WORK/err"
assert grep -qF "line 1 (R9): purpose 'docs/doctors-contract.md' does not touch the component" "$WORK/err"
night_doc fixed-pending loosened
assert_fails fix close "$rid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qF "judge changed since launch (base-llm -> loosened)" "$WORK/err"
night_doc fixed-pending base-llm
# Night markdown is net zero against the night base in every worktree of the run: committed, deleted and
# untracked *.md bytes all count.
printf '%099d\n' 0 >"$WT/docs/grown.md"
git -C "$WT" add docs/grown.md && git -C "$WT" -c user.name=t -c user.email=t@t commit -qm grown
assert_fails fix close "$rid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qF "markdown grew by 100 bytes since refs/night/n1/base in $WT (docs/grown.md +100): markdown is net zero at night" "$WORK/err"
printf '%049d\n' 0 >"$WT/docs/stale.md"
printf '%079d\n' 0 >"$WT/new.md"
assert_fails fix close "$rid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qF "markdown grew by 30 bytes since refs/night/n1/base in $WT (docs/grown.md +100, new.md +80)" "$WORK/err"
rm "$WT/new.md"
git -C "$PW" update-ref -d refs/night/n1/base
assert_fails fix close "$rid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qxF "markdown: no refs/night/n1/base in $PW to measure it against" "$WORK/err"
assert [ "$(grep -c 'markdown grew' "$WORK/err")" = 0 ]
git -C "$PW" update-ref refs/night/n1/base "$(git -C "$WORK/projects/proj" rev-parse HEAD)"
# A handoff addressed to Egor is a trade or nothing: its Cost:, Loss: and Recommendation: lines.
printf '# anchors\n\nTo: Egor.\nStatus: open\nShould anchors stay?\n' >"$WORK/docs/handoffs/2026-10-02-egor.md"
sed 's#docs/handoffs/2026-09-30-r9.md#(docs/handoffs/2026-10-02-egor.md),#' "$WORK/nd" >"$WORK/nd-egor"
assert_fails fix close "$rid" --decisions "$WORK/nd-egor" "x" 2>"$WORK/err"
assert grep -qxF "line 2 (machinery:anchors): handoff to Egor docs/handoffs/2026-10-02-egor.md lacks Cost: Loss: Recommendation:: Egor decides only a trade (each way's cost and loss, the recommendation); otherwise hand it to an owner or decide what research settles" "$WORK/err"
sed 's#docs/handoffs/2026-09-30-r9.md#see docs/handoffs/2026-10-02-egor.md.#' "$WORK/nd" >"$WORK/nd-dot"
assert_fails fix close "$rid" --decisions "$WORK/nd-dot" "x" 2>"$WORK/err"
assert grep -qF "handoff to Egor docs/handoffs/2026-10-02-egor.md lacks Cost:" "$WORK/err"
printf 'Cost: keeping anchors costs 2 s a run.\n- **Loss:** dropping them loses the round links.\nRecommendation: keep.\n' >>"$WORK/docs/handoffs/2026-10-02-egor.md"
assert jqe '.closed_at == null' "$RR"
fix close "$rid" --decisions "$WORK/nd-egor" "R9 fixed" >"$WORK/out" 2>"$WORK/err" || fail "night close failed: $(cat "$WORK/err")"
assert grep -qxF "run $rid closed: 2 decisions" "$WORK/out"
assert jqe '.closed_at != null and .judge_at_close == "base-llm"' "$RR"
assert [ "$(wc -l <"$DATA/llm-doctor-runs" | tr -d ' ')" = 10 ]

# abandon: the deadline's verb. An abandoned run closes no more; a closed one cannot be abandoned.
fix abandon "$wid" --reason "deadline passed" >"$WORK/out" || fail "abandon failed"
assert grep -qxF "run $wid abandoned" "$WORK/out"
assert jqe '.abandoned_at != null and .closed_at == null and .note == "deadline passed"' "$(record "$wid")"
assert_fails fix close "$wid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qF "run $wid was abandoned" "$WORK/err"
assert_fails fix abandon "$rid" 2>"$WORK/err"
assert grep -qF "run $rid is already closed" "$WORK/err"
assert_fails fix abandon "$wid" --bogus 2>/dev/null
fix abandon "$hid" >/dev/null || fail "abandon without a reason failed"

# A worktree that cannot be made fails its run: failed_at and a note, never left pending.
mkdir -p "$WORK/projects/broken/.claude"
git -C "$WORK/projects/broken" init -q
git -C "$WORK/projects/broken" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$WORK/projects/broken" update-ref refs/night/n2/base HEAD
: >"$WORK/projects/broken/.claude/worktrees"
before=$(ls "$RUNS"/*.json)
assert_fails env DOCTOR_FIX_WORKTREE_REPO="$WORK/projects/broken" bash "$FIX" launch llm --night n2 >"$WORK/out" 2>"$WORK/err"
assert [ ! -s "$WORK/out" ]
new=$(comm -13 <(printf '%s\n' "$before") <(ls "$RUNS"/*.json))
assert [ "$(printf '%s\n' "$new" | wc -l | tr -d ' ')" = 3 ]
for f in $new; do assert jqe '.failed_at != null and .launched_at == null and (.note | startswith("worktree not created"))' "$f"; done
assert grep -qF 'failed: worktree not created' "$WORK/err"
assert [ -z "$(fix runs llm --open)" ]

# Harness: areas are the document's sections; the snapshot adds the top 8 watch rows of Hooks and Hook waits.
jq -n --argjson s "$(now)" '{contract: 1, doctor: "harness", as_of_s: $s, judge: "h-live", status: "problems", problem_count: 3,
  sections: [
    {name: "Hooks", rows: [{cells: ["gate.sh"], judge: [{rule: "hook_every_call", ident: "gate.sh", level: "red"},
      {rule: "hook_p50", ident: "gate.sh", level: null}]}]},
    {name: "Hook waits", rows: [{cells: ["tool"], judge: [{rule: "floor", ident: "tool", level: null}]}]},
    {name: "Load", rows: [], nav: [{cells: ["load"], menu: {rows: [{cells: ["host"],
      judge: [{rule: "load", ident: "host", level: "red"}]}]}}]}],
  problems: ([
    {id: "hook_every_call:gate.sh", rule: "hook_every_call", state: "new", fact: "gate every call", value: 1, exposure: 1},
    {id: "gate-row", rule: "hook_every_call", state: "open", fact: "a ledger row naming its hook by regex", ledger: "gate-row"},
    {id: "load:host", rule: "load", state: "new", fact: "busy", value: 9, exposure: 9},
    {id: "collector:run", rule: "collector", state: "new", fact: "slow collector"},
    {id: "floor:event:PreToolUse", rule: "floor", state: "new", fact: "slow tool hooks", value: 1, exposure: 1},
    {id: "test_slow:proj:test_x", rule: "test_slow", state: "new", fact: "slow suite"},
    {id: "test_long_pole:proj:test_x", rule: "test_long_pole", state: "new", fact: "the long pole"},
    {id: "test_daily_cost:proj:test_x", rule: "test_daily_cost", state: "new", fact: "a costly suite"},
    {id: "test_hang:proj:test_x", rule: "test_hang", state: "new", fact: "a hung suite"},
    {id: "menu_build:automation", rule: "menu_build", state: "new", fact: "11 menu opens waited 450 ms"},
    {id: "floor:tool", rule: "floor", state: "watch", fact: "floor", value: 100, exposure: 100},
    {id: "load:quiet", rule: "load", state: "watch", fact: "quiet", value: 1000, exposure: 1000}]
    + [range(10) | {id: "hook_p50:w\(.)", rule: "hook_p50", state: "watch", fact: "w", value: ., exposure: 10}])}' \
  >"$WORK/harness/latest.json"
mkdir -p "$WORK/projects/proj/tests" && printf '#!/bin/bash\n' >"$WORK/projects/proj/tests/test_x.sh"
printf '{"owner": "H owner", "rows": [{"id": "gate-row", "status": "open", "match": {"rule": "hook_every_call", "ident": "gate\\\\.sh"}}, {"id": "quiet-hook", "title": "a hook gone quiet", "status": "open", "match": {"rule": "hook_every_call", "ident": "gate\\\\.sh"}}]}\n' \
  >"$WORK/ledgers/harness.json"
mkdir -p "$WORK/projects/hammerspoon" "$L/hammerspoon"
: >"$WORK/projects/hammerspoon/automation_menu.lua"
: >"$L/hammerspoon/llm-limits.lua"
O="$WORK/projects/other"
git init -q "$O" && git -C "$O" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$O" update-ref refs/night/n3/base HEAD
printf '%s\n' "$L" "$O" >"$WORK/sweep-repos"
export NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos"
for n in 1 2 3 4; do bash "$FIX" launch harness --night n3 >"$DATA/h-$n" 2>/dev/null & done
wait
assert [ "$(cat "$DATA"/h-* | cut -f1 | sed -E 's/^harness-([a-z-]+)-[0-9]{8}.*/\1/' | sort | xargs)" = "doctor hook-waits hooks load" ]
assert [ "$(ls "$RUNS"/harness-*-*-*.json | grep -c -- '-hooks-')" = 1 ]
hk=$(cat "$DATA"/h-* | awk -F'\t' '$1 ~ /^harness-hooks-/ {print $1}')
assert jqe '[.problems[].id] == ["hook_every_call:gate.sh", "gate-row", "hook_p50:w9", "hook_p50:w8", "hook_p50:w7", "hook_p50:w6",
  "hook_p50:w5", "hook_p50:w4", "hook_p50:w3"] and .judge_at_launch == "base-harness"' "$(record "$hk")"
assert jqe --arg f "$WORK/projects/claude-setup/hooks/gate.sh" '[.quiet[] | {id, files: .component.files}] == [{id: "quiet-hook", files: [$f]}]' "$(record "$hk")"
assert [ "$(cat "$DATA"/h-* | cut -f1 | while read -r r; do jq '.quiet | length' "$RUNS/$r.json"; done | paste -sd+ - | bc)" = 1 ]
assert jqe --arg f "$WORK/projects/claude-setup/hooks/gate.sh" '.problems[0].component.files == [$f] and .problems[1].component.files == [$f]
  and (.problems[0].component.rule_at | startswith("bin/harness-doctor:"))' "$(record "$hk")"
assert jqe --arg f "$WORK/projects/claude-setup/hooks/gate.sh" '[.problems[].id] == ["floor:event:PreToolUse", "floor:tool"]
  and .problems[0].component.files == [$f]' "$(cat "$DATA"/h-* | awk -F'\t' '$1 ~ /^harness-hook-waits-/ {print $1".json"}' | sed "s#^#$RUNS/#")"
# Every other harness row gets the file it names; one that names none closes, marked component unverified.
self=$(cat "$DATA"/h-* | awk -F'\t' '$1 ~ /^harness-doctor-/ {print $1}')
assert jqe --arg c "$(cd -P "$ROOT" && pwd | sed -E 's#/\.claude/worktrees/[^/]+$##')/bin/harness-doctor" --arg t "$WORK/projects/proj/tests/test_x.sh" \
  '[.problems[] | {id, files: .component.files}] == [{id: "collector:run", files: [$c]}, {id: "test_slow:proj:test_x", files: [$t]},
  {id: "test_long_pole:proj:test_x", files: [$t]}, {id: "test_daily_cost:proj:test_x", files: [$t]},
  {id: "test_hang:proj:test_x", files: [$t]},
  {id: "menu_build:automation", files: [$h, $m]}]' --arg h "$WORK/projects/hammerspoon/automation_menu.lua" \
  --arg m "$L/hammerspoon/llm-limits.lua" "$(record "$self")"
assert grep -qF "Test speed is this run's to fix, never a handoff" "$RUNS/$self.brief.md"
assert grep -qF "A hung suite (\`test_hang\`) is this run's to fix, never a handoff (\`close\` refuses one)" "$RUNS/$self.brief.md"
assert grep -qF "The proof is the doctor's own: no \`test_hang\` row for that suite after the fix." "$RUNS/$self.brief.md"
assert grep -qF "Menu delays (\`menu_build\`) are this run's to fix, never a handoff" "$RUNS/$self.brief.md"
assert [ "$(grep -c 'never a handoff' "$RUNS/$hk.brief.md")" = 0 ]
assert jqe --arg o "$O/.claude/worktrees/night-n3-$self" '.worktrees | index($o) != null' "$(record "$self")"
assert jqe '.worktrees | length == 1' "$(record "$hk")"
jq -n --argjson s $(($(now) + 5)) '{contract: 1, doctor: "harness", as_of_s: $s, judge: "base-harness", problems: []}' \
  >"$DATA/harness-doc.json"
printf '%s\thandoff\tproj/tests/test_x.sh\tdocs/handoffs/x.md\n' test_slow:proj:test_x test_long_pole:proj:test_x \
  test_daily_cost:proj:test_x test_hang:proj:test_x >"$WORK/hd"
printf 'menu_build:automation\thandoff\thammerspoon/automation_menu.lua\tdocs/handoffs/x.md\n' >>"$WORK/hd"
printf 'collector:run\thandoff\tllm-legs/bin/harness-doctor\tdocs/handoffs/x.md\n' >>"$WORK/hd"
printf 'quiet-hook\thandoff\tproj/README\tdocs/handoffs/x.md\n' >>"$WORK/hd"
assert_fails fix close "$self" --decisions "$WORK/hd" "handed off" 2>"$WORK/err"
assert [ "$(grep -c "handoff refused: test speed and menu delays are this run's to fix" "$WORK/err")" = 5 ]
assert grep -qF 'line 4 (test_hang:proj:test_x): handoff refused' "$WORK/err"
assert grep -qF 'line 5 (menu_build:automation): handoff refused' "$WORK/err"
assert_fails grep -qF "(collector:run): handoff refused" "$WORK/err"
assert_fails grep -qF "(quiet-hook): handoff refused" "$WORK/err"
rm "$DATA/harness-doc.json"
load=$(cat "$DATA"/h-* | awk -F'\t' '$1 ~ /^harness-load-/ {print $1}')
assert jqe '.problems[0].id == "load:host" and .problems[0].component.files == []' "$(record "$load")"
fix touches "$(record "$load")" load:host proj/README
assert [ $? = 3 ]
fix touches "$(record "$load")" "row 1" proj/README || fail "a purpose for no listed problem only has to resolve"
jq -n --argjson s $(($(now) + 5)) '{contract: 1, doctor: "harness", as_of_s: $s, judge: "base-harness",
  problems: [{id: "load:host", state: "fixed-pending"}]}' >"$DATA/harness-doc.json"
printf 'load:host\tfixed\tproj/README\ttests/test_x.sh\n' >"$WORK/ld"
fix close "$load" --decisions "$WORK/ld" "load fixed" >/dev/null 2>"$WORK/err" || fail "a row naming no file blocks close: $(cat "$WORK/err")"
assert jqe '.decisions == [{id: "load:host", verdict: "fixed", purpose: "proj/README", evidence: "tests/test_x.sh", component: "unverified"}]' "$(record "$load")"
fix show "$load" >"$WORK/show"
assert grep -qxF "$(printf '  load:host\tfixed\tproj/README\ttests/test_x.sh\tcomponent unverified')" "$WORK/show"
rm "$DATA/harness-doc.json"
assert grep -qF 'sections 0-6, "Night" and "Harness doctor" only.' "$RUNS/$hk.brief.md"

# Updater: its own machinery is one area, the doctor's own; vendor release events are vendor-fingerprint's. Nothing to do prints nothing.
jq -n --argjson s "$(now)" '{contract: 1, doctor: "updater", as_of_s: $s, judge: "u1", status: "problems", problem_count: 1,
  problems: [{id: "event-waiting:grok-1", rule: "event-waiting", state: "new", fact: "waiting"},
    {id: "foreign-client:codex", rule: "foreign-client", state: "watch", fact: "foreign"}]}' >"$WORK/updater/latest.json"
fix launch updater --night n4 >"$WORK/out" 2>&1 || fail "an empty updater night failed"
assert [ ! -s "$WORK/out" ]
jq --argjson s "$(now)" '.problems += [{id: "pass-stale", rule: "pass-stale", state: "new", fact: "stale pass"}] | .as_of_s = $s' \
  "$WORK/updater/latest.json" >"$WORK/u" && mv "$WORK/u" "$WORK/updater/latest.json"
fix launch updater --night n4 >"$WORK/out" || fail "updater night failed"
uid=$(cut -f1 "$WORK/out")
assert grep -qE '^updater-doctor-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$' <<<"$uid"
assert jqe --arg f "$WORK/projects/llm-legs/bin/vendor-cli-update" '[.problems[].id] == ["pass-stale"]
  and .problems[0].component.files == [$f] and .judge_at_launch == "base-updater"' "$(record "$uid")"
assert_fails fix close "$uid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qF "$RUNS/$uid.d/latest.json is no contract-1 updater doctor document" "$WORK/err"
assert_fails fix launch llm --night 'bad night' 2>/dev/null

# A release run recorded before runs had an area is a release run, not an all-areas one.
fix abandon "$uid" >/dev/null || fail "abandon of the updater night run failed"
jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{id: "updater-20260101T000000Z", doctor: "updater", night: null, created_at: $t,
  launched_at: $t, closed_at: null, abandoned_at: null, problems: [{id: "grok-1", state: "open"}], decisions: []}' \
  >"$RUNS/updater-20260101T000000Z.json"
fix launch updater --night n4 >"$WORK/out" 2>"$WORK/err" || fail "a legacy release run blocked the updater night: $(cat "$WORK/err")"
assert grep -qE '^updater-doctor-' "$WORK/out"
assert jqe '.abandoned_at == null' "$RUNS/updater-20260101T000000Z.json"
fix record-close updater-20260101T000000Z --decisions "$WORK/ujson" "grok-1: integrated" || fail "a legacy release run does not close"

# A commit citation that is a merge touches what the merge brought in.
P="$WORK/projects/proj"
git -C "$P" checkout -qb side
printf 'why more\n' >>"$P/README"
git -C "$P" -c user.name=t -c user.email=t@t commit -qam side
git -C "$P" checkout -q -
printf 'x\n' >"$P/MAIN" && git -C "$P" add MAIN && git -C "$P" -c user.name=t -c user.email=t@t commit -qm main
git -C "$P" -c user.name=t -c user.email=t@t merge -q --no-ff side -m merge
fix touches "$RR" R9 "proj@$(git -C "$P" rev-parse --short HEAD)" || fail "a merge that changed the component does not touch it"

# A malformed ledger row the doctor reports still snapshots, so its fixer can repair it.
for n in n5 n6 n7; do git -C "$L" update-ref "refs/night/$n/base" HEAD; done
jq -n '{owner: "LLM owner", owners: {}, blind_spots: [], rows: [{id: "R7", block: "workers", match: "bad",
  fixes: [null, {files: "proj/README"}, {at: "2026-09-02T00:00:00Z", files: ["proj/README", 3]}], same_cause: [1, "R6"]}]}' \
  >"$WORK/ledgers/llm.json"
jq -n --argjson s "$(now)" '{contract: 1, doctor: "llm", as_of_s: $s, judge: "j", status: "problems", problem_count: 1, blocks: [],
  problems: [{id: "ledger:R7", rule: "ledger", state: "new", fact: "fixes[0] is no object", ledger: null}]}' >"$WORK/llm/latest.json"
fix launch llm --night n5 >"$WORK/out" 2>"$WORK/err" || fail "a malformed ledger row broke the night snapshot: $(cat "$WORK/err")"
mid=$(cut -f1 "$WORK/out")
assert jqe --arg w "$WORK/projects/llm-legs/bin/worker-run" --arg f "$WORK/projects/proj/README" \
  '.area == "workers" and [.problems[] | {id, files: .component.files}] == [{id: "ledger:R7", files: [$w, $f]}]' "$(record "$mid")"
assert grep -qxF "$(printf '  ledger:R7\tnew\tfixes[0] is no object')" "$RUNS/$mid.brief.md"
cp "$WORK/ledger-kept" "$WORK/ledgers/llm.json"

# A collector that failed is a problem of its own, and a fix of it holds only once the rerun doctor stops failing.
jq -n --argjson s "$(now)" '{contract: 1, doctor: "llm", as_of_s: $s, judge: null, status: "error", problem_count: 0, problems: [],
  blind_spots: [], self: {collector_s: null, error: "KeyError: '\''x'\''"}}' >"$WORK/llm/latest.json"
fix launch llm --night n6 >"$WORK/out" 2>"$WORK/err" || fail "a failed collector launched nothing: $(cat "$WORK/err")"
cid=$(cut -f1 "$WORK/out")
assert grep -qE '^llm-doctor-' <<<"$cid"
assert jqe --arg e "$WORK/projects/llm-legs/bin/llm-doctor" '[.problems[] | {id, rule, state, fact, files: .component.files}]
  == [{id: "collector:error", rule: "collector", state: "new", fact: "the collector failed: KeyError: '\''x'\''", files: [$e]}]' "$(record "$cid")"
printf 'collector:error\tfixed\tllm-legs/bin/llm-doctor\ttests/test_llm_doctor.sh\n' >"$WORK/cd"
jq -n --argjson s $(($(now) + 5)) '{contract: 1, doctor: "llm", as_of_s: $s, judge: "base-llm", status: "error", problems: [],
  self: {error: "KeyError: '\''x'\''"}}' >"$DATA/llm-doc.json"
assert_fails fix close "$cid" --decisions "$WORK/cd" "x" 2>"$WORK/err"
assert grep -qxF "line 1 (collector:error): fixed, but the rerun llm doctor fails: KeyError: 'x'" "$WORK/err"
jq -n --argjson s $(($(now) + 5)) '{contract: 1, doctor: "llm", as_of_s: $s, judge: "base-llm", status: "ok", problems: []}' >"$DATA/llm-doc.json"
fix close "$cid" --decisions "$WORK/cd" "collector fixed" >/dev/null || fail "a fixed collector does not close"

# A launched_at that is not written fails that run, not only the last area's.
cat >"$FAKE_BIN/mv" <<'EOF'
#!/bin/bash
src=${*: -2:1}
if [ -f "$src" ] && grep -q '"launched_at": "' "$src"; then
  [ ! -e "$DATA/mv-refuse-launch" ] || exit 1
  ! rm "$DATA/mv-term-launch" 2>/dev/null || kill -TERM "$PPID"
fi
exec /bin/mv "$@"
EOF
chmod +x "$FAKE_BIN/mv"
jq -n --argjson s "$(now)" '{contract: 1, doctor: "llm", as_of_s: $s, judge: "j", status: "problems", problem_count: 2,
  blocks: [{block: "reviewers", machinery: {classes: [{class: "anchors"}]}, problems: []}],
  problems: [{id: "debt-gap:y", rule: "debt-gap", state: "new", fact: "a debt gap", ledger: null},
    {id: "machinery:anchors", rule: "machinery", state: "new", fact: "anchors", ledger: null}]}' >"$WORK/llm/latest.json"
before=$(ls "$RUNS"/*.json)
: >"$DATA/mv-refuse-launch"
assert_fails fix launch llm --night n7 >/dev/null 2>"$WORK/err"
rm "$DATA/mv-refuse-launch"
new=$(comm -13 <(printf '%s\n' "$before") <(ls "$RUNS"/*.json))
assert [ "$(printf '%s\n' "$new" | wc -l | tr -d ' ')" = 2 ]
for f in $new; do assert jqe '.failed_at != null and .launched_at == null and .note == "launched_at not written"' "$f"; done

# A launcher killed while it holds the runs lock still fails its pending run on the way out.
for open in $(fix runs --open --json | jq -r '.[].id'); do fix abandon "$open" >/dev/null; done
doc llm "$(now)" problems 3 j1
: >"$DATA/mv-term-launch"
assert_fails env LLM_STORE_LOCK_RETRIES=8 bash "$FIX" launch llm >/dev/null 2>&1
killed=$(fix runs llm --json | jq -r '.[0].id')
assert grep -qE '^llm-all-' <<<"$killed"
assert jqe '.failed_at != null and .note == "the launcher exited before the run opened"' "$(record "$killed")"
assert [ ! -e "$RUNS/.lock" ]
rm "$FAKE_BIN/mv"

fix --help >"$WORK/help"
for word in launch show runs close abandon record record-close touches; do assert grep -qE "doctor-fix $word( |$)" "$WORK/help"; done
assert_fails fix bogus 2>/dev/null

# Prefix words are quoted onto the exec line only. Unset, the launches above stay bare claudeb.
. "$ROOT/share/chat-open.sh"
prefix_cmd=$WORK/prefix.command
mkdir -p "$WORK/wd"
CHAT_OPEN_OPENER="$FAKE_BIN/opener" \
CHAT_OPEN_WORKER_PICK="$FAKE_BIN/worker-pick" \
CHAT_OPEN_PREFIX='caffeinate -i;$(touch)' \
  chat_open "$prefix_cmd" "$WORK/wd" 'say hi' >"$WORK/prefix.out"
assert grep -qxF "cd $(printf '%q' "$WORK/wd") || exit 1" "$prefix_cmd"
assert [ "$(grep -c caffeinate "$prefix_cmd")" = 1 ]
prefix_words=$(bash -c 'line=$(grep "^exec " "$1"); line=${line#exec }; eval "set -- $line"; printf "%s\n" "$1" "$2" "$3" "$4" "$5"' _ "$prefix_cmd")
assert [ "$(sed -n 1p <<<"$prefix_words")" = caffeinate ]
assert [ "$(sed -n 2p <<<"$prefix_words")" = '-i;$(touch)' ]
assert [ "$(sed -n 3p <<<"$prefix_words")" = "$FAKE_BIN/claudeb" ]
assert [ "$(sed -n 4p <<<"$prefix_words")" = profile ]
assert [ "$(sed -n 5p <<<"$prefix_words")" = acct-b ]
assert grep -q '^acct-b ' "$WORK/prefix.out"

# A resume reopens the chat on its own launcher: a claudegpt-stamped chat stays on its gateway account.
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/claudegpt"
chmod +x "$FAKE_BIN/claudegpt"
mkdir -p "$HOME/.local/share/claudegpt/sessions"
printf 'v1 gw-acct sol\n' >"$HOME/.local/share/claudegpt/sessions/sess-gw"
CHAT_OPEN_OPENER="$FAKE_BIN/opener" CHAT_OPEN_WORKER_PICK="$FAKE_BIN/worker-pick" \
  chat_open "$WORK/resume-gw.command" "$WORK/wd" 'go on' sess-gw >"$WORK/resume-gw.out"
assert grep -qxF "exec $FAKE_BIN/claudegpt p gw-acct --model sol --resume sess-gw --permission-mode bypassPermissions go\\ on" "$WORK/resume-gw.command"
assert grep -qxF 'gw-acct sess-gw' "$WORK/resume-gw.out"
CHAT_OPEN_OPENER="$FAKE_BIN/opener" CHAT_OPEN_WORKER_PICK="$FAKE_BIN/worker-pick" \
  chat_open "$WORK/resume-cb.command" "$WORK/wd" 'go on' sess-cb >"$WORK/resume-cb.out"
assert grep -qxF "exec $FAKE_BIN/claudeb profile acct-b --resume sess-cb --permission-mode bypassPermissions go\\ on" "$WORK/resume-cb.command"

# A doctor that reads ok still opens its day fixer while a quiet open ledger row waits; with none, nothing to fix.
mkdir -p "$WORK/llm-q"
jq -n --argjson s "$(now)" '{contract: 1, doctor: "llm", as_of_s: $s, judge: "q", status: "ok", problem_count: 0, problems: []}' \
  >"$WORK/llm-q/latest.json"
printf '{"owner": "o", "rows": [{"id": "Q7", "title": "quiet", "block": "workers", "status": "fixed", "match": {"word": "x"}}]}\n' >"$WORK/ledgers/q.json"
assert_fails env DOCTORS_DIR="$WORK/doctors-q" LLM_DOCTOR_DIR="$WORK/llm-q" LLM_DOCTOR_LEDGER="$WORK/ledgers/q.json" bash "$FIX" launch llm 2>"$WORK/err"
assert grep -qF 'nothing to fix' "$WORK/err"
printf '{"owner": "o", "rows": [{"id": "Q7", "title": "quiet", "block": "workers", "status": "open", "match": {"word": "x"}}]}\n' >"$WORK/ledgers/q.json"
DOCTORS_DIR="$WORK/doctors-q" LLM_DOCTOR_DIR="$WORK/llm-q" LLM_DOCTOR_LEDGER="$WORK/ledgers/q.json" bash "$FIX" launch llm >"$WORK/out" 2>"$WORK/err" ||
  fail "a quiet open row must open the fixer: $(cat "$WORK/err")"
assert grep -qE '^llm fixer opened: run llm-all-[^,]+, 0 problems · 1 known, quiet$' "$WORK/out"
qid=$(sed -n 's/^llm fixer opened: run \([^,]*\),.*/\1/p' "$WORK/out")
DOCTORS_DIR="$WORK/doctors-q" LLM_DOCTOR_LEDGER="$WORK/ledgers/q.json" bash "$FIX" show "$qid" >"$WORK/show"
assert grep -qF 'known, quiet (1): ' "$WORK/show"
assert grep -qxF "$(printf '  Q7\tquiet\tquiet')" "$WORK/show"

# Code: one area, top-K by value, needs-Egor problems stay out, close runs code-doctor check.
export CODE_DOCTOR_DIR="$WORK/code" CODE_DOCTOR_REPOS="" CODE_DOCTOR_LEDGER="$WORK/ledgers/code.json"
mkdir -p "$WORK/code"
printf '{"rows": []}\n' >"$CODE_DOCTOR_LEDGER"
jq -n --argjson s "$(now)" '{contract: 1, doctor: "code", as_of_s: $s, judge: "c1", status: "problems", problem_count: 5,
  problems: ([range(4) | {id: "cause:proj/f\(.)", rule: "unreachable", group: "dead", state: "new", fact: "f\(.) is dead",
    value: (10 + .), units: [], files: ["proj/README"]}]
    + [{id: "cause:registration:/x", rule: "registration", group: "dead", state: "new", fact: "needs Egor: x", value: 99,
       needs_egor: true, units: [], files: []}])}' >"$WORK/code/latest.json"
fix launch code --night n5 >"$WORK/out" || fail "code night failed"
cid=$(cut -f1 "$WORK/out")
assert grep -qE '^code-code-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$' <<<"$cid"
assert jqe --arg f "$WORK/projects/proj/README" '[.problems[].id] == ["cause:proj/f3", "cause:proj/f2", "cause:proj/f1"]
  and .problems[0].component.files == [$f] and .area == "code" and .judge_at_launch == "base-code"' "$(record "$cid")"
assert grep -qF 'Code runs: every problem carries its judged plan' "$RUNS/$cid.brief.md"
assert grep -qF 'sections 0-6, "Night" and "Code doctor" only.' "$RUNS/$cid.brief.md"
jq -n --argjson s "$(($(now) + 5))" '{contract: 1, doctor: "code", as_of_s: $s, judge: "base-code", status: "ok", problem_count: 0,
  problems: []}' >"$DATA/code-doc.json"
printf 'cause:proj/f%s\tfixed\tproj/README\tdeleted, the suites pass\n' 3 2 1 >"$WORK/cd-decisions"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$DATA/code-checks"\necho "proj/f3: deletion proof: a live entry point still reaches it"\nexit 1\n' \
  >"$FAKE_BIN/code-check-refuses"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$DATA/code-checks"\n' >"$FAKE_BIN/code-check-passes"
chmod +x "$FAKE_BIN/code-check-refuses" "$FAKE_BIN/code-check-passes"
DOCTOR_FIX_CODE_DOCTOR="$FAKE_BIN/code-check-refuses" fix close "$cid" --decisions "$WORK/cd-decisions" "done" 2>"$WORK/err" &&
  fail "a refused code-doctor check closed the run"
assert grep -qF 'code-doctor check: proj/f3: deletion proof: a live entry point still reaches it' "$WORK/err"
assert grep -qxF "check $RUNS/$cid.json --base refs/night/n5/base" "$DATA/code-checks"
DOCTOR_FIX_CODE_DOCTOR="$FAKE_BIN/code-check-passes" fix close "$cid" --decisions "$WORK/cd-decisions" "done" >/dev/null ||
  fail "a passing code-doctor check left the run open"
assert jqe '.closed_at != null and (.decisions | length) == 3' "$(record "$cid")"
assert jqe '.problems[0] | has("units") and has("digest") and .needs_egor == null' "$(record "$cid")"
fix launch code --night n5 >"$WORK/out" || fail "a second code launch in one night failed"
assert test ! -s "$WORK/out"
assert test "$(ls "$RUNS"/code-*.json | wc -l | tr -d ' ')" = 1
printf '{"rows": [{"id": "code-q", "title": "an open row past top-K", "status": "open", "match": {"cause": "cause:proj/f0"}},
  {"id": "code-egor", "title": "needs Egor: a registration", "status": "open", "match": {"cause": "cause:registration:/x"}}]}\n' \
  >"$CODE_DOCTOR_LEDGER"
fix launch code --night n6 >"$WORK/out" 2>"$WORK/err" || fail "code night n6 failed"
assert jqe '.quiet == [] and (.problems | length) == 3' "$(record "$(cut -f1 "$WORK/out")")"
for open in $(fix runs code --open --json | jq -r '.[].id'); do fix abandon "$open" >/dev/null; done
printf '{"rows": []}\n' >"$CODE_DOCTOR_LEDGER"
jq '.problems |= map(select(.needs_egor)) | .problem_count = 1' "$WORK/code/latest.json" >"$WORK/code/egor.json" &&
  mv "$WORK/code/egor.json" "$WORK/code/latest.json"
before=$(ls "$RUNS"/code-*.json)
assert_fails fix launch code 2>"$WORK/err"
assert grep -qF 'nothing to fix: every code doctor problem is held back' "$WORK/err"
assert [ "$(ls "$RUNS"/code-*.json)" = "$before" ]
jq '.problems |= map(del(.needs_egor)) | .scope = {foreign: ["/x/web"], report_only: "report-only scope: /x/web is not a sweep repository, so no fixer edits it"}' \
  "$WORK/code/latest.json" >"$WORK/code/scoped.json" && mv "$WORK/code/scoped.json" "$WORK/code/latest.json"
assert_fails fix launch code 2>"$WORK/err"
assert [ "$(cat "$WORK/err")" = 'doctor-fix: report-only scope: /x/web is not a sweep repository, so no fixer edits it' ]
assert_fails fix launch code --night n7 2>"$WORK/err"
assert grep -qF 'report-only scope' "$WORK/err"
assert [ "$(ls "$RUNS"/code-*.json)" = "$before" ]

# Speed: a harness night takes the loud regressions and Speed's chosen opportunities as area speed. Over the calibration
# transcripts, a quiet-band contention probe and a heavy llm-legs suite, that is design §6's Night 1: #2, #1, #5 stage 1.
S="$WORK/speed-cal"
mkdir -p "$L/tests" && : >"$L/tests/test_llm_limits.sh"
python3 - "$ROOT" "$S" <<'EOF' || fail "the calibration fixture did not build"
import json, os, sys, time
root, work = sys.argv[1:3]
sys.path.insert(0, os.path.join(root, "tests", "lib"))
from speed_calibration import HI, fold, harness
h = harness(root)
fold(h, root, work)
os.makedirs(os.path.join(work, "harness", "speed-days"))
probe = lambda ms: [1, ms, ms, ms, 0, 0, []]
for ago in (3, 2, 1):
    with open(os.path.join(work, "harness", "speed-days", h.local_day(HI - ago * 86400) + ".json"), "w") as handle:
        json.dump({"machine": {"band_s": {"<1": 8200, "2-4": 1800}, "probe_ms": {"<1": probe(10), "2-4": probe(40)}}}, handle)
os.makedirs(os.path.join(work, "sl"))
with open(os.path.join(work, "sl", "test-history.jsonl"), "w") as handle:
    for secs in (300, 310, 290):
        handle.write(json.dumps({"end": HI - 3600, "secs": secs, "who": "chat", "repo": "llm-legs",
                                 "label": "test_llm_limits"}) + "\n")
with open(os.path.join(work, "harness", "latest.json"), "w") as handle:
    json.dump({"contract": 1, "doctor": "harness", "as_of_s": int(time.time()), "judge": "base-harness", "status": "ok",
               "problem_count": 0, "problems": [], "blind_spots": [], "sections": [], "periods": {}, "extras": [],
               "title": "Harness doctor: ok", "footer": ""}, handle)
with open(os.path.join(work, "ledger.json"), "w") as handle:
    json.dump({"owner": "H", "rows": [], "blind_spots": []}, handle)
EOF
speed_env=(HARNESS_DOCTOR_DIR="$S/harness" HARNESS_LEDGER="$S/ledger.json")
env "${speed_env[@]}" CODE_LEDGER="$S/none.json" STATUSLINE_CACHE_DIR="$S/sl" SPEED_DOCTOR_NOW=1790967000 \
  SPEED_DOCTOR_DIR="$S/speed" WORKER_STATS_DIR="$S/ws" CODE_DOCTOR_DIR="$S/code" "$ROOT/bin/speed-doctor" --quiet ||
  fail "speed-doctor did not merge its section"
night1='["opportunity:tests/llm-legs/test_llm_limits", "opportunity:chat/hooks", "opportunity:machine/contention"]'
assert jqe --argjson n "$night1" '.speed.selection == $n' "$S/harness/latest.json"
mkdir -p "$L/share/rbench" "$L/share/briefs" "$L/agents"
printf '# the per-model call\nclaudeb opus high high,xhigh low,medium,max no\n' >"$L/share/worker-model.sh"
printf '| claudeb / opus | high | high, xhigh |\nPlain prose.\n' >"$L/share/worker-policy.md"
printf '    "T0": {"efforts": {"claude": "low", "codex": "low"}},\n' >"$L/share/rbench/catalog.py"
printf -- '---\nname: w\nmodel: opus\n---\nbody\n' >"$L/agents/w.md"
printf "CLAUDEB_CLAUDE_MODEL='fable'\n" >"$L/bin/claudeb"
printf 'EFFORT: high\nDo the thing.\n' >"$L/share/briefs/r.md"
git -C "$L" add share agents bin/claudeb && git -C "$L" -c user.name=t -c user.email=t@t commit -qm knobs
rfg="$WORK/projects/claude-setup/hooks/review-flow-gate.sh"
printf '#!/bin/bash\n' >"$rfg"
jq --arg c "$rfg" '. + {model: "opus"} | .hooks.PreToolUse[0].hooks += [{type: "command", command: $c}]' "$WORK/settings.json" \
  >"$WORK/settings.new" && mv "$WORK/settings.new" "$WORK/settings.json"
git -C "$L" update-ref refs/night/n8/base HEAD
env "${speed_env[@]}" bash "$FIX" launch harness --night n8 >"$WORK/out" 2>"$WORK/err" ||
  fail "the speed night did not launch: $(cat "$WORK/err")"
assert [ "$(wc -l <"$WORK/out" | tr -d ' ')" = 1 ]
sid=$(cut -f1 "$WORK/out")
assert jqe --argjson n "$night1" --arg t "$L/tests/test_llm_limits.sh" --arg h "$rfg" '.area == "speed" and [.problems[].id] == $n
  and [.problems[].component.files] == [[$t], [$h], []]' "$(record "$sid")"

# Its close refuses any added or removed line that sets a model, effort or thinking knob, committed, uncommitted,
# untracked or in the live settings and worker-model files; a speed diff touching none of them closes.
swt="$L/.claude/worktrees/night-n8-$sid"
gw() { git -C "$swt" -c user.name=t -c user.email=t@t "$@"; }
sed -i '' 's/opus high high/opus medium high/' "$swt/share/worker-model.sh"
sed -i '' 's/model: opus/model: haiku/' "$swt/agents/w.md"
gw commit -qam "tune"
sed -i '' 's/| high |/| medium |/' "$swt/share/worker-policy.md"
sed -i '' 's/"claude": "low"/"claude": "medium"/' "$swt/share/rbench/catalog.py"
sed -i '' 's/fable/haiku/' "$swt/bin/claudeb"
printf 'MODEL: haiku\n' >"$swt/share/briefs/new.md"
sed -i '' 's/"opus"/"haiku"/' "$WORK/settings.json"
mkdir -p "$HOME/.claude" && printf 'claudeb_model=sonnet\n' >"$HOME/.claude/worker-model"
jq -n --argjson s $(($(now) + 5)) '{contract: 1, doctor: "harness", as_of_s: $s, judge: "base-harness", problems: []}' \
  >"$DATA/harness-doc.json"
printf 'opportunity:machine/contention\truled-out\tnone\tthe lever is elsewhere\n' >"$WORK/sd"
printf 'opportunity:chat/hooks\truled-out\tclaude-setup/hooks/review-flow-gate.sh\tthe snapshot stays\n' >>"$WORK/sd"
printf 'opportunity:tests/llm-legs/test_llm_limits\truled-out\tllm-legs/tests/test_llm_limits.sh\tno sleeps\n' >>"$WORK/sd"
assert_fails fix close "$sid" --decisions "$WORK/sd" "tuned" 2>"$WORK/err"
knob() { grep -qF "model/effort knob, $1: $2" "$WORK/err"; }
assert knob "share/worker-model.sh table" "llm-legs/share/worker-model.sh:2: +claudeb opus medium"
assert knob "agent model frontmatter" "llm-legs/agents/w.md:3: -model: opus"
assert knob "share/worker-policy.md effort" "llm-legs/share/worker-policy.md:1: +| claudeb / opus | medium |"
assert knob "review-bench tier effort/rater" "llm-legs/share/rbench/catalog.py:1: -"
assert knob "claudeb default model" "llm-legs/bin/claudeb:1: +CLAUDEB_CLAUDE_MODEL='haiku'"
assert knob "brief-template EFFORT/MODEL" "llm-legs/share/briefs/new.md:1: +MODEL: haiku"
assert [ "$(grep -c '^model/effort knob, ' "$WORK/err")" = 11 ]
gw reset -q --hard refs/night/n8/base && gw clean -qfd
sed -i '' 's/the per-model call/the per-model table/' "$swt/share/worker-model.sh"
sed -i '' 's/Plain prose/Plain words/' "$swt/share/worker-policy.md"
gw commit -qam "words"
printf 'cache=1\n' >"$swt/bin/statusline-cache.sh"
# A live settings or worker-model change since launch may be Egor's own /model: a note, never a refusal.
fix close "$sid" --decisions "$WORK/sd" "a speed diff" >/dev/null 2>"$WORK/err" ||
  fail "a speed diff touching no knob stays open: $(cat "$WORK/err")"
live() { grep -qF "doctor-fix: note: live model/effort knob changed since launch, $1: $2" "$WORK/err"; }
assert live "settings model/effort/thinking" "$WORK/settings.json:$(grep -n '"model"' "$WORK/settings.json" | cut -d: -f1): +"
assert live "worker-model" "$HOME/.claude/worker-model:1: +claudeb_model=sonnet"
sed -i '' 's/"haiku"/"opus"/' "$WORK/settings.json" && rm "$HOME/.claude/worker-model"
rm "$DATA/harness-doc.json"
jq --argjson s "$(now)" '.as_of_s = $s | .speed.selection += ["opportunity:chat/tests"]
  | (.problems[] | select(.id == "opportunity:chat/tests") | .opportunity.quality) = "risk"' "$S/harness/latest.json" >"$S/risk.json" &&
  mv "$S/risk.json" "$S/harness/latest.json"
git -C "$L" update-ref refs/night/n9/base HEAD
env "${speed_env[@]}" bash "$FIX" launch harness --night n9 >"$WORK/out" 2>"$WORK/err" || fail "speed night n9: $(cat "$WORK/err")"
assert jqe --argjson n "$night1" '[.problems[].id] == $n' "$(record "$(cut -f1 "$WORK/out")")"
assert [ ! -s "$WORK/err" ]
# A Speed section that selects nothing says why on stderr instead of skipping silently.
jq --argjson s "$(now)" '.as_of_s = $s | .speed.selection = [] | .speed.why_none = "no equivalent lever scores 0.2 within the night budget; 1.2 of 7 days covered"' \
  "$S/harness/latest.json" >"$S/picked-none.json" && mv "$S/picked-none.json" "$S/harness/latest.json"
git -C "$L" update-ref refs/night/n10/base HEAD
env "${speed_env[@]}" bash "$FIX" launch harness --night n10 >"$WORK/out" 2>"$WORK/err" || fail "speed night n10: $(cat "$WORK/err")"
assert [ ! -s "$WORK/out" ]
assert [ "$(cat "$WORK/err")" = "harness: Speed selects nothing: no equivalent lever scores 0.2 within the night budget; 1.2 of 7 days covered" ]

echo "PASS: $asserts asserts; code runs (one area, top-K, needs-Egor out, close through code-doctor check); launch refusals (no or foreign or stale document, nothing to fix, open run under 12 h), an old run abandoned, the snapshot without watch/fixed-pending, the chat through the shared opener, the record fields, a failed opener, close refusals (doctor not rerun, undecided id, missing path, missing commit, a directory, no evidence, bad verdict, judge changed without its line), a clean close, show, runs, updater records and launch, parallel ids, night launch (areas, worktrees, branches, briefs, the packet, one open run per area), night vendor records, a night without a base ref, llm components with their block's entry file, fixed only once the doctor reads it fixed-pending or gone, night close (markdown net zero per worktree: committed, untracked and cut bytes, a worktree without its base; a day run unmeasured; the doctor rerun once in the worktree, a handed-in document refused, purpose touching its component, judge), abandon, a failed worktree, harness sections and top watch rows under parallel launch, updater machinery, a legacy release run, a merge citation, a malformed ledger row, a failed collector, an unwritten launched_at, a launcher killed under the lock, quiet open ledger rows (their own brief section, the day launch), a speed night (design Night 1 over the calibration fixture, an empty Speed pick named on stderr, a refusal per worktree model/effort knob site, a live settings change only a note, a knob-free diff closes)"
