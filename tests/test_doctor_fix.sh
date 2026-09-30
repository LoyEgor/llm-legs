#!/usr/bin/env bash
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
  DOCTOR_FIX_WORKTREE_REPO="$WORK/projects/llm-legs" LLM_DOCTOR_REPOS="$WORK/projects" HARNESS_REPOS_DIR="$WORK/projects"
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
  "account", "session", "command", "branch", "worktrees", "judge_at_launch", "judge_at_close", "problems", "decisions", "note"] | sort)' "$R"
assert jqe --arg id "$id" '.id == $id and .doctor == "llm" and .area == "all" and .night == null and .account == "acct-b"
  and .judge_at_launch == "j1" and .closed_at == null and .abandoned_at == null and .failed_at == null and .decisions == []
  and .note == null and .branch == null and .worktrees == []' "$R"
assert jqe '[.created_at, .launched_at] | all(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' "$R"
assert jqe '[.problems[] | {id, state, fact}] == [{id: "A", state: "new", fact: "a new bug"}, {id: "B", state: "open", fact: "an open row"},
  {id: "E", state: "regressed", fact: "a regressed fix"}]' "$R"
assert jqe '[.problems[] | .area] == ["health", "health", "health"] and all(.problems[]; .component.files == [])' "$R"
session=$(jq -r .session "$R")
assert grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' <<<"$session"
assert_fails grep -qF "$session" "$WORK/out"
# The chat opens through the shared helper: picked account, pinned session, strong model, the procedure.
assert [ "$(jq -r .command "$R")" = "$RUNS/$id.command" ]
assert [ "$(cat "$OPENED")" = "$RUNS/$id.command" ]
assert grep -qxF -- '--account claudeb --role chat --claim' "$DATA/pick-args"
assert grep -qxF "cd $(printf '%q' "$ROOT") || exit 1" "$RUNS/$id.command"
assert grep -qF "CLAUDE_CODE_SESSION_ID=$session $(printf '%q' "$ROOT/bin/chat-pin") all" "$RUNS/$id.command"
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
printf 'A\tfixed\tproj@%s\tbin/x.py:12 fixed; tests/test_x.sh\nB\truled-out\tdocs/doctors-contract.md:40\tthe row is the design\nE\tweather\tproj/README\tvendor 429s\n' \
  "$hash" >"$WORK/decisions"
assert_fails fix close "$id2" --decisions "$WORK/decisions" "done" 2>"$WORK/err"
assert grep -qF 'rerun the llm doctor, the proof reads its fresh numbers' "$WORK/err"
doc llm $(($(now) + 5)) problems 3 j1
# Every problem id needs a decision.
head -n 2 "$WORK/decisions" >"$WORK/partial"
assert_fails fix close "$id2" --decisions "$WORK/partial" "done" 2>"$WORK/err"
assert grep -qxF 'E: undecided' "$WORK/err"
# A purpose must resolve: a file that exists, or a commit in that project.
sed 's#docs/doctors-contract.md:40#docs/no-such-file.md#' "$WORK/decisions" >"$WORK/bad-path"
assert_fails fix close "$id2" --decisions "$WORK/bad-path" "done" 2>"$WORK/err"
assert grep -qF "line 2 (B): purpose 'docs/no-such-file.md' resolves to no commit" "$WORK/err"
assert grep -qxF 'B: undecided' "$WORK/err"
sed "s#proj@$hash#proj@deadbeef#" "$WORK/decisions" >"$WORK/bad-commit"
assert_fails fix close "$id2" --decisions "$WORK/bad-commit" "done" 2>"$WORK/err"
assert grep -qF "line 1 (A): purpose 'proj@deadbeef' resolves to no commit" "$WORK/err"
sed 's#docs/doctors-contract.md:40#docs#' "$WORK/decisions" >"$WORK/dir-purpose"
assert_fails fix close "$id2" --decisions "$WORK/dir-purpose" "done" 2>/dev/null
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
fix close "$id2" --decisions "$WORK/decisions" "three fixed or ruled out" >"$WORK/out" || fail "clean close failed"
assert grep -qxF "run $id2 closed: 4 decisions" "$WORK/out"
assert jqe '.closed_at != null and .judge_at_close == "j2" and .note == "three fixed or ruled out"' "$R2"
assert jqe --arg h "proj@$hash" '.decisions == [
  {id: "A", verdict: "fixed", purpose: $h, evidence: "bin/x.py:12 fixed; tests/test_x.sh"},
  {id: "B", verdict: "ruled-out", purpose: "docs/doctors-contract.md:40", evidence: "the row is the design"},
  {id: "E", verdict: "weather", purpose: "proj/README", evidence: "vendor 429s"},
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

# Parallel record writes never share an id.
for n in 1 2 3 4 5 6; do fix record updater --session "s-$n" --account a --command c --problems "e-$n" >"$DATA/par-$n" & done
wait
assert [ "$(cat "$DATA"/par-* | sort -u | grep -cE '^updater-release-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$')" = 6 ]
for n in 1 2 3 4 5 6; do assert jqe --arg s "s-$n" '.session == $s' "$(record "$(cat "$DATA/par-$n")")"; done

# Night fixtures: the llm-legs repository the worktrees branch from, a component repository, docs and memory.
L="$WORK/projects/llm-legs"
mkdir -p "$L/bin" "$WORK/projects/claude-setup/hooks" "$HOME/.claude-profiles/p1/projects/-Volumes-Work-Projects-llm-legs/memory"
for d in llm harness updater; do
  printf '#!/bin/bash\nprintf "{\\"judge\\": \\"base-%s\\"}\\n"\n' "$d" >"$L/bin/$d-doctor"
done
chmod +x "$L"/bin/*
git -C "$L" init -q && git -C "$L" add bin && git -C "$L" -c user.name=t -c user.email=t@t commit -qm base
printf '#!/bin/bash\n' >"$WORK/projects/claude-setup/hooks/gate.sh"
jq -n --arg c "$WORK/projects/claude-setup/hooks/gate.sh" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]}}' \
  >"$WORK/settings.json"
printf 'other\n' >"$WORK/projects/proj/OTHER"
git -C "$WORK/projects/proj" add OTHER && git -C "$WORK/projects/proj" -c user.name=t -c user.email=t@t commit -qm other
other=$(git -C "$WORK/projects/proj" rev-parse --short HEAD)
jq -n '{owner: "LLM owner", owners: {reviewers: "RB chat", workers: "W chat"}, blind_spots: [],
  rows: [{id: "R9", title: "a twice-fixed row", block: "reviewers", match: {word: "crashed", detail: "boom"}, status: "fixed-pending",
    fixes: [{at: "2026-09-01T00:00:00Z", by: "a chat", files: ["proj/README"], in: null, regressed_at: null}],
    same_cause: ["R8"], handoff: "docs/handoffs/h.md"}]}' >"$WORK/ledgers/llm.json"
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
  problems: [
    {id: "leg-escape:workers/escaped", rule: "leg-escape", state: "new", fact: "escaped", ledger: null},
    {id: "R9", rule: "leg-failure", state: "regressed", fact: "crashed again", ledger: "R9"},
    {id: "debt-gap:x", rule: "debt-gap", state: "new", fact: "a debt gap", ledger: null},
    {id: "W", rule: "leg-failure", state: "watch", fact: "watched", ledger: null},
    {id: "machinery:anchors", rule: "machinery", state: "new", fact: "anchors", ledger: null}]}' >"$WORK/llm/latest.json"

# A night launch opens no chat: one run per area, each with its worktree on its own branch and a brief.
# A fix's files resolve where the doctor itself resolves them, never through doctor-fix's own projects dir.
opened_before=$(wc -l <"$OPENED")
DOCTOR_FIX_PROJECTS="$WORK/nowhere" fix launch llm --night n1 >"$WORK/night" 2>"$WORK/err" ||
  fail "night launch failed: $(cat "$WORK/err")"
assert [ "$(wc -l <"$OPENED")" = "$opened_before" ]
assert [ "$(wc -l <"$WORK/night" | tr -d ' ')" = 3 ]
assert [ "$(cut -f1 "$WORK/night" | sed -E 's/^llm-([a-z]+)-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$/\1/' | xargs)" = "health reviewers workers" ]
rid=$(awk -F'\t' '$1 ~ /^llm-reviewers-/ {print $1}' "$WORK/night")
wid=$(awk -F'\t' '$1 ~ /^llm-workers-/ {print $1}' "$WORK/night")
hid=$(awk -F'\t' '$1 ~ /^llm-health-/ {print $1}' "$WORK/night")
WT="$L/.claude/worktrees/night-n1-$rid"
assert [ "$(grep "^$rid" "$WORK/night")" = "$rid	$RUNS/$rid.brief.md	$WT" ]
assert [ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "night/n1/$rid" ]
assert grep -qxF '.claude/worktrees/' "$L/.git/info/exclude"
assert [ -z "$(git -C "$L" status --porcelain)" ]
RR=$(record "$rid")
assert jqe --arg w "$WT" --arg b "night/n1/$rid" '.night == "n1" and .area == "reviewers" and .branch == $b and .worktrees == [$w]
  and .launched_at != null and .failed_at == null and .account == null and .judge_at_launch == "base-llm"
  and ([.problems[].id] == ["R9", "machinery:anchors"])' "$RR"
assert jqe --arg f "$WORK/projects/proj/README" '.problems[0].component.files == [$f]
  and .problems[0].component.what == "reviewers block · owner «RB chat»"
  and (.problems[0].component.rule_at | startswith("bin/llm-doctor:"))
  and .problems[1].component.what == "review-bench doctor class anchors · reviewers block · owner «RB chat»"' "$RR"
assert jqe '[.problems[].id] == ["debt-gap:x"]' "$(record "$hid")"
# The brief is complete: the procedure, the close line with a run-local document, and the packet.
B="$RUNS/$rid.brief.md"
assert grep -qF "docs/doctor-fix.md\`: sections 0-6, \"Night\" and \"LLM doctor\" only." "$B"
assert grep -qF "cd $WT && bin/llm-doctor --json >$RUNS/$rid.d/latest.json" "$B"
assert grep -qF "bin/doctor-fix close $rid --decisions $RUNS/$rid.d/decisions.tsv --doc $RUNS/$rid.d/latest.json" "$B"
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
assert grep -qxF "night n1 · branch night/n1/$rid · worktrees $WT" "$WORK/show"
# One open run per (doctor, area): a second launch of the same night makes nothing.
before=$(ls "$RUNS"/*.json | wc -l)
fix launch llm --night n1 >"$WORK/night2" 2>"$WORK/err" || fail "a held night relaunch failed"
assert [ ! -s "$WORK/night2" ]
assert grep -qF "run $rid of the llm doctor is still open" "$WORK/err"
assert [ "$(ls "$RUNS"/*.json | wc -l)" = "$before" ]
assert_fails fix launch llm 2>/dev/null

# A night close needs a run-local document, and every purpose must touch its component.
printf 'R9\tfixed\tproj@%s\tproj/README fixed; tests/x\nmachinery:anchors\thandoff\tproj/README\tdocs/handoffs/2026-09-30-r9.md\n' "$hash" >"$WORK/nd"
assert_fails fix close "$rid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qF "run $rid is a night run: close it with --doc" "$WORK/err"
assert_fails fix close "$rid" --decisions "$WORK/nd" --doc "$WORK/llm/latest.json" "x" 2>"$WORK/err"
assert grep -qF 'names the shared llm document' "$WORK/err"
mkdir -p "$RUNS/$rid.d"
jq -n --argjson s $(($(now) + 5)) '{contract: 1, doctor: "harness", as_of_s: $s, judge: "base-llm"}' >"$RUNS/$rid.d/latest.json"
assert_fails fix close "$rid" --decisions "$WORK/nd" --doc "$RUNS/$rid.d/latest.json" "x" 2>"$WORK/err"
assert grep -qF 'is no contract-1 llm doctor document' "$WORK/err"
jq -n --argjson s $(($(now) + 5)) '{contract: 1, doctor: "llm", as_of_s: $s, judge: "base-llm"}' >"$RUNS/$rid.d/latest.json"
sed "s#^R9\tfixed\tproj@$hash#R9\tfixed\tproj@$other#" "$WORK/nd" >"$WORK/nd-other"
assert_fails fix close "$rid" --decisions "$WORK/nd-other" --doc "$RUNS/$rid.d/latest.json" "x" 2>"$WORK/err"
assert grep -qF "line 1 (R9): purpose 'proj@$other' does not touch the component" "$WORK/err"
sed 's#^R9\tfixed\tproj@[0-9a-f]*#R9\tfixed\tdocs/doctors-contract.md#' "$WORK/nd" >"$WORK/nd-path"
assert_fails fix close "$rid" --decisions "$WORK/nd-path" --doc "$RUNS/$rid.d/latest.json" "x" 2>"$WORK/err"
assert grep -qF "line 1 (R9): purpose 'docs/doctors-contract.md' does not touch the component" "$WORK/err"
jq '.judge = "loosened"' "$RUNS/$rid.d/latest.json" >"$WORK/j" && mv "$WORK/j" "$RUNS/$rid.d/latest.json"
assert_fails fix close "$rid" --decisions "$WORK/nd" --doc "$RUNS/$rid.d/latest.json" "x" 2>"$WORK/err"
assert grep -qF "judge changed since launch (base-llm -> loosened)" "$WORK/err"
jq '.judge = "base-llm"' "$RUNS/$rid.d/latest.json" >"$WORK/j" && mv "$WORK/j" "$RUNS/$rid.d/latest.json"
fix close "$rid" --decisions "$WORK/nd" --doc "$RUNS/$rid.d/latest.json" "R9 fixed" >"$WORK/out" || fail "night close failed: $(cat "$WORK/err")"
assert grep -qxF "run $rid closed: 2 decisions" "$WORK/out"
assert jqe '.closed_at != null and .judge_at_close == "base-llm"' "$RR"

# abandon: the deadline's verb. An abandoned run closes no more; a closed one cannot be abandoned.
fix abandon "$wid" --reason "deadline passed" >"$WORK/out" || fail "abandon failed"
assert grep -qxF "run $wid abandoned" "$WORK/out"
assert jqe '.abandoned_at != null and .closed_at == null and .note == "deadline passed"' "$(record "$wid")"
assert_fails fix close "$wid" --decisions "$WORK/nd" --doc "$RUNS/$rid.d/latest.json" "x" 2>"$WORK/err"
assert grep -qF "run $wid was abandoned" "$WORK/err"
assert_fails fix abandon "$rid" 2>"$WORK/err"
assert grep -qF "run $rid is already closed" "$WORK/err"
assert_fails fix abandon "$wid" --bogus 2>/dev/null
fix abandon "$hid" >/dev/null || fail "abandon without a reason failed"

# A worktree that cannot be made fails its run: failed_at and a note, never left pending.
mkdir -p "$WORK/projects/broken/.claude"
git -C "$WORK/projects/broken" init -q
git -C "$WORK/projects/broken" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
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
    {id: "load:host", rule: "load", state: "new", fact: "busy", value: 9, exposure: 9},
    {id: "collector:run", rule: "collector", state: "new", fact: "slow collector"},
    {id: "floor:tool", rule: "floor", state: "watch", fact: "floor", value: 100, exposure: 100},
    {id: "load:quiet", rule: "load", state: "watch", fact: "quiet", value: 1000, exposure: 1000}]
    + [range(10) | {id: "hook_p50:w\(.)", rule: "hook_p50", state: "watch", fact: "w", value: ., exposure: 10}])}' \
  >"$WORK/harness/latest.json"
for n in 1 2 3 4; do bash "$FIX" launch harness --night n3 >"$DATA/h-$n" 2>/dev/null & done
wait
assert [ "$(cat "$DATA"/h-* | cut -f1 | sed -E 's/^harness-([a-z-]+)-[0-9]{8}.*/\1/' | sort | xargs)" = "hook-waits hooks load self" ]
assert [ "$(ls "$RUNS"/harness-*-*-*.json | grep -c -- '-hooks-')" = 1 ]
hk=$(cat "$DATA"/h-* | awk -F'\t' '$1 ~ /^harness-hooks-/ {print $1}')
assert jqe '[.problems[].id] == ["hook_every_call:gate.sh", "hook_p50:w9", "hook_p50:w8", "hook_p50:w7", "hook_p50:w6",
  "hook_p50:w5", "hook_p50:w4", "hook_p50:w3"] and .judge_at_launch == "base-harness"' "$(record "$hk")"
assert jqe --arg f "$WORK/projects/claude-setup/hooks/gate.sh" '.problems[0].component.files == [$f]
  and (.problems[0].component.rule_at | startswith("bin/harness-doctor:"))' "$(record "$hk")"
assert jqe '[.problems[].id] == ["floor:tool"]' "$(cat "$DATA"/h-* | awk -F'\t' '$1 ~ /^harness-hook-waits-/ {print $1".json"}' | sed "s#^#$RUNS/#")"
assert grep -qF 'sections 0-6, "Night" and "Harness doctor" only.' "$RUNS/$hk.brief.md"

# Updater: its own machinery is one area; vendor release events are vendor-fingerprint's. Nothing to do prints nothing.
jq -n --argjson s "$(now)" '{contract: 1, doctor: "updater", as_of_s: $s, judge: "u1", status: "problems", problem_count: 1,
  problems: [{id: "event-waiting:grok-1", rule: "event-waiting", state: "new", fact: "waiting"},
    {id: "foreign-client:codex", rule: "foreign-client", state: "watch", fact: "foreign"}]}' >"$WORK/updater/latest.json"
fix launch updater --night n4 >"$WORK/out" 2>&1 || fail "an empty updater night failed"
assert [ ! -s "$WORK/out" ]
jq --argjson s "$(now)" '.problems += [{id: "pass-stale", rule: "pass-stale", state: "new", fact: "stale pass"}] | .as_of_s = $s' \
  "$WORK/updater/latest.json" >"$WORK/u" && mv "$WORK/u" "$WORK/updater/latest.json"
fix launch updater --night n4 >"$WORK/out" || fail "updater night failed"
uid=$(cut -f1 "$WORK/out")
assert grep -qE '^updater-machinery-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$' <<<"$uid"
assert jqe '[.problems[].id] == ["pass-stale"] and .judge_at_launch == "base-updater"' "$(record "$uid")"
assert_fails fix close "$uid" --decisions "$WORK/nd" "x" 2>"$WORK/err"
assert grep -qF "run $uid is a night run" "$WORK/err"
assert_fails fix launch llm --night 'bad night' 2>/dev/null

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

echo "PASS: $asserts asserts; launch refusals (no or foreign or stale document, nothing to fix, open run under 12 h), an old run abandoned, the snapshot without watch/fixed-pending, the chat through the shared opener, the record fields, a failed opener, close refusals (doctor not rerun, undecided id, missing path, missing commit, a directory, no evidence, bad verdict, judge changed without its line), a clean close, show, runs, updater records and launch, parallel ids, night launch (areas, worktrees, branches, briefs, the packet, one open run per area), night close (run-local document, purpose touching its component, judge), abandon, a failed worktree, harness sections and top watch rows under parallel launch, updater machinery"
