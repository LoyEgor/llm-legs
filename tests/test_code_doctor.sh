#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/code-doctor over the calibration corpus (tests/fixtures/code-doctor): the six labelled cases, a
# healthy repository with zero problems, clustering, reachability, protected roots, the durable rollup,
# the judge budget, the structural verdict digest, the fixer's safety gate and the ledger's recurrence.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/code-doctor"
CD="$ROOT/bin/code-doctor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts unexpectedly succeeded: $*"; }
jqe() { jq -e "$@" >/dev/null; }
commit() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"; }
iso_ago() { date -u -r $(($(date +%s) - $1)) +%Y-%m-%dT%H:%M:%SZ; }

lay_out() { # fixture dest -> the fixture copied, its env exported
  mkdir -p "$2"
  cp -R "$1/." "$2/"
  REPOS="$2/repos"
  [ ! -f "$2/home/.claude/settings.json.in" ] ||
    sed "s#@REPOS@#$REPOS#g" "$2/home/.claude/settings.json.in" >"$2/home/.claude/settings.json"
  mkdir -p "$2/home/.local/bin" "$2/state" "$2/harness" "$2/sl"
  : >"$2/judged.tsv"
  printf '#!/bin/sh\necho "$*" >>"%s/launchctl.log"\n' "$2" >"$2/launchctl" && chmod +x "$2/launchctl"
  export HOME="$2/home" CODE_DOCTOR_DIR="$2/state" CODE_DOCTOR_LEDGER="$2/ledger.json" CODE_DOCTOR_LAUNCHCTL="$2/launchctl" \
    CODE_DOCTOR_MECHANISMS="$2/mechanisms.json" HARNESS_DOCTOR_DIR="$2/harness" STATUSLINE_CACHE_DIR="$2/sl" \
    CODE_DOCTOR_WORKER_RUN="$FIX/fake-worker-run" CODE_DOCTOR_FAKE_LOG="$2/judged.tsv" \
    CODE_DOCTOR_FAKE_VERDICTS="$2/verdicts.json" CODE_DOCTOR_REPOS="$(printf '%s:' "$REPOS"/*)"
}

init_repos() {
  local repo
  for repo in "$REPOS"/*; do
    git -C "$repo" init -q -b main && git -C "$repo" add -A && commit "$repo" base || fail "cannot init $repo"
  done
}

judged() { wc -l <"$CODE_DOCTOR_FAKE_LOG" | tr -d ' '; }

# A healthy repository: every file reached from an entry point, nothing to say.
lay_out "$FIX/healthy" "$WORK/healthy"
ln -s "$REPOS/good/bin/good-tool" "$HOME/.local/bin/good-tool"
init_repos
"$CD" refresh --quiet || fail "refresh failed on the healthy repository"
assert jqe '.status == "ok" and .problem_count == 0 and .candidates.total == 0 and .doctor == "code" and .contract == 1' \
  "$CODE_DOCTOR_DIR/latest.json"

# The corpus.
C="$WORK/corpus"
lay_out "$FIX/corpus" "$C"
A="$REPOS/alpha"
ln -s "$REPOS/beta/lib" "$A/vendor"
ln -s "$A/bin/alpha-run" "$HOME/.local/bin/alpha-run"
init_repos
now=$(date +%s)
for secs in 300 310 290; do
  printf '{"end":%s,"secs":%s,"who":"chat","repo":"alpha","label":"test_isolation"}\n' "$now" "$secs"
done >"$C/sl/test-history.jsonl"
"$CD" index >"$WORK/index.out" || fail "index failed"
assert grep -q '^alpha: [0-9]* files' "$WORK/index.out"
"$CD" index >"$WORK/index2.out"
assert grep -q '^alpha: [0-9]* files · 0 parsed' "$WORK/index2.out"
"$CD" refresh --quiet || fail "refresh failed on the corpus"
LATEST="$CODE_DOCTOR_DIR/latest.json"
assert jqe '.candidates.waiting == 3 and .candidates.protected == 0 and .problem_count == 1 and .groups.dead == 1' "$LATEST"
assert jqe '[.problems[] | select(.needs_egor and (.fact | startswith("needs Egor: Cost: settings.json is in no repository")) and (.trade | contains("Recommendation: remove it"))
  and (.proofs | any(contains("never tracked"))) and (.steps[0] | contains("settings.json")))] | length == 1' "$LATEST"
assert jqe '[.blind_spots[].id] | index("rollup:none") != null' "$LATEST"

# The judge's budget: with no session history the estimate carries the worker's base context, so a cap under it
# launches nothing; a token stop before the next launch would cross it (estimated from the recorded session), a wall
# stop, then the rest in one batched session whose tokens split evenly over its candidates.
"$CD" judge --night n00 --max-tokens 60000 >"$WORK/judge.out"
assert grep -q 'stop tokens' "$WORK/judge.out"
assert test "$(judged)" = 0
CODE_DOCTOR_FAKE_COST=90000 "$CD" judge --night n0 --max-tokens 100000 --batch 1 >"$WORK/judge.out"
assert grep -q 'stop tokens' "$WORK/judge.out"
assert test "$(judged)" = 1
"$CD" judge --night n0 --max-wall 0 >"$WORK/judge.out"
assert grep -q 'stop wall' "$WORK/judge.out"
assert test "$(judged)" = 1
assert jqe 'select(.night == "n0" and .stop == "tokens" and .tokens == 90000)' "$CODE_DOCTOR_DIR/judge-runs.jsonl"
"$CD" judge --night n1 >"$WORK/judge.out"
assert grep -q 'stop done' "$WORK/judge.out"
assert test "$(awk 'FNR == 1' "$CODE_DOCTOR_DIR"/judge/n1/batch-*.md | sort -u)" = "ROUND: none"
assert test "$(judged)" = 3
assert test "$(tail -2 "$CODE_DOCTOR_FAKE_LOG" | cut -f1 | sort -u | wc -l | tr -d ' ')" = 1
assert jqe -s '[.[] | select(.night == "n1" and .stage == "judge") | .tokens] | (add == 1000 and length == 2 and min >= 500)' \
  "$CODE_DOCTOR_DIR/accounting.jsonl"
"$CD" judge --night n1 >/dev/null
assert test "$(judged)" = 3

# The six labelled cases.
python3 - "$FIX/labels.json" "$CODE_DOCTOR_DIR" >"$WORK/calibration" <<'PY'
import json, sys

labels, state = json.load(open(sys.argv[1])), sys.argv[2]
candidates = [json.loads(line) for line in open(state + "/candidates.jsonl")]
problems = {p["id"]: p for p in json.load(open(state + "/latest.json"))["problems"]}
by_id = {c["id"]: c for c in candidates}
units = {s["unit"] for c in candidates for s in c["units"]} | {s["file"] for c in candidates for s in c["units"]}
failed = 0
for case in labels["cases"]:
    expect = case["expect"]
    if expect == "problem":
        problem, candidate = problems.get(case["cause"]), by_id.get(case["cause"])
        ok = bool(problem and candidate) and problem["group"] == case["group"] and problem["state"] == "new" \
            and sorted(s["unit"] for s in candidate["units"]) == sorted(case["units"]) \
            and not set(case.get("files_absent") or ()) & units
    elif expect == "protected":
        candidate = by_id.get(case["cause"])
        ok = bool(candidate and candidate.get("protected")) and case["cause"] not in problems
    else:
        ok = not set(case["files"]) & units
    failed += not ok
    print("%s: %s" % ("PASS" if ok else "FAIL", case["case"]))
sys.exit(1 if failed else 0)
PY
calibration=$?
cat "$WORK/calibration"
assert test "$calibration" = 0
assert jqe '.problem_count == 4 and .groups == {dead: 3, heavy: 0, duplicate: 1, promise: 0}
  and ([.groups[]] | add) == .problem_count and .status == "problems"' "$LATEST"
assert jqe '.cost.tokens == 91000 and .cost_per_cause["cause:alpha/bin/old-sync"].judge.tokens > 0' "$LATEST"

# The rollup outlives the journal's prune and claims no silence past its window.
day=$((now / 86400 - 2))
mkdir -p "$C/harness/hooks"
printf '%s000000\t%s500000\tguard.sh\t0\t111\n' "$((day * 86400))" "$((day * 86400))" >"$C/harness/hooks/$day.tsv"
printf '%s000000\t%s900000\tguard.sh\t0\t112\n' "$((day * 86400 + 60))" "$((day * 86400 + 60))" >>"$C/harness/hooks/$day.tsv"
printf '%s000000\t%s900000\t \t0\t113\n' "$((day * 86400 + 90))" "$((day * 86400 + 90))" >>"$C/harness/hooks/$day.tsv"
date_of_day=$(date -u -r $((day * 86400)) +%F)
mkdir -p "$C/harness/statusline"
printf '1\t2\ts-a\n3\t4\ts-b\n5\t6\ts-a\n' >"$C/harness/statusline/$date_of_day.tsv"
assert "$CD" rollup >/dev/null
assert jqe '.sources.hooks.hits["hook:guard.sh"] == 2 and .sources.hooks.sessions == null
  and .sources.statusline.sessions == 2 and .complete' "$CODE_DOCTOR_DIR/rollup/$date_of_day.json"
rm "$C/harness/hooks/$day.tsv" "$C/harness/statusline/$date_of_day.tsv"
"$CD" rollup >/dev/null
assert jqe '.sources.hooks.hits["hook:guard.sh"] == 2' "$CODE_DOCTOR_DIR/rollup/$date_of_day.json"
"$CD" >/dev/null
assert jqe '[.blind_spots[] | select(.id == "rollup:short" and (.what | contains("1 covered days")))] | length == 1' "$LATEST"

# The fixer's snapshot: top-K by value, revalidated, active work out.
"$CD" snapshot "$LATEST" --night n1 >"$WORK/snap.json"
assert jqe 'map(.id) == ["cause:alpha/bin/old-sync", "cause:alpha/lib/drive_a.py#load_drivers", "cause:alpha/lib/refresh.sh#robot_curl_refresh"]' \
  "$WORK/snap.json"
printf '# local edit\n' >>"$A/bin/old-sync"
"$CD" snapshot "$LATEST" >"$WORK/snap.json"
assert jqe 'map(.id) | index("cause:alpha/bin/old-sync") == null' "$WORK/snap.json"
git -C "$A" checkout -q -- bin/old-sync
assert jqe '.["cause:alpha/bin/old-sync"].digest != null' "$CODE_DOCTOR_DIR/verdicts.json"

# The safety gate over a night run that deleted the dead cycle.
git -C "$A" update-ref refs/night/n1/base HEAD
WT="$C/wt"
git -C "$A" worktree add -q -b night/n1/code-x "$WT" refs/night/n1/base || fail "worktree add"
git -C "$WT" rm -q bin/old-sync lib/old_sync_lib.sh tests/test_old_sync.sh
commit "$WT" "drop old-sync"
jq -n --arg w "$WT" --arg t "$(iso_ago 60)" '{id: "code-code-x", doctor: "code", area: "code", night: "n1",
  branch: "night/n1/code-x", worktrees: [$w], launched_at: $t, problems: [{id: "cause:alpha/bin/old-sync", state: "new"}]}' \
  >"$C/record.json"
assert "$CD" check "$C/record.json" --base refs/night/n1/base
"$CD" check "$C/record.json" --base refs/night/n1/base --landing >"$WORK/check.out"
assert test $? = 1
assert grep -q 'green suites not confirmed' "$WORK/check.out"
assert "$CD" check "$C/record.json" --base refs/night/n1/base --landing --suites-passed
# Landed without a rebase (main had not moved): the deleted units are gone from main, which is no change.
pre_land=$(git -C "$A" rev-parse HEAD)
git -C "$A" merge -q --ff-only night/n1/code-x
assert "$CD" check "$C/record.json" --base refs/night/n1/base --landing --suites-passed
git -C "$A" reset -q --hard "$pre_land"
rm "$WT/lib/manual_helpers.sh"
"$CD" check "$C/record.json" --base refs/night/n1/base >"$WORK/check.out"
assert grep -q 'alpha/lib/manual_helpers.sh: deleted, but no judged problem of this run names it' "$WORK/check.out"
git -C "$WT" checkout -q -- lib/manual_helpers.sh
printf '# through the link\n' >>"$WT/vendor/vendor.sh"
"$CD" check "$C/record.json" --base refs/night/n1/base >"$WORK/check.out"
assert grep -q 'edited through the symlink vendor into' "$WORK/check.out"
git -C "$REPOS/beta" checkout -q -- lib/vendor.sh
printf '# live work\n' >>"$A/lib/old_sync_lib.sh"
"$CD" check "$C/record.json" --base refs/night/n1/base --landing --suites-passed >"$WORK/check.out"
assert grep -q 'alpha/lib/old_sync_lib.sh: in active work (uncommitted in' "$WORK/check.out"
git -C "$A" checkout -q -- lib/old_sync_lib.sh
"$CD" candidates >/dev/null
assert "$CD" check "$C/record.json" --base refs/night/n1/base --landing --suites-passed
mkdir -p "$C/anchors-bin"
cat >"$C/anchors-bin/review-anchors" <<'EOF'
#!/usr/bin/env bash
[ "$1 $4" = "list --json" ] || exit 2
echo '{"claims": {"lib/old_sync_lib.sh": {"session": "s-9", "round": "r1", "until": 4102444800},
  "bin/old-sync": {"session": "s-8", "round": "r0", "until": 1}}}'
EOF
chmod +x "$C/anchors-bin/review-anchors"
PATH="$C/anchors-bin:$PATH" "$CD" check "$C/record.json" --base refs/night/n1/base --landing --suites-passed >"$WORK/check.out"
assert grep -q 'alpha/lib/old_sync_lib.sh: in active work (under an open review claim of s-9)' "$WORK/check.out"
assert test "$(grep -c 'open review claim' "$WORK/check.out")" = 1

# The structural digest: a rollup change re-judges nothing, a new caller re-judges its cause.
printf '{"day": "%s", "complete": true, "sources": {"hooks": {"hits": {"hook:old-sync": 5}, "ms": {}, "sessions": 1}}}\n' \
  "$(date -u -r $((now - 3 * 86400)) +%F)" >"$CODE_DOCTOR_DIR/rollup/extra.json"
"$CD" candidates >/dev/null
assert jqe 'select(.id == "cause:alpha/bin/old-sync") | .runtime_hits["hook:old-sync"] == 5' "$CODE_DOCTOR_DIR/candidates.jsonl"
"$CD" judge >/dev/null
assert test "$(judged)" = 3
rm "$CODE_DOCTOR_DIR/rollup/extra.json"
printf 'from drive_a import load_drivers\n\nprint(load_drivers("/dev/null"))\n' >"$A/lib/extra.py"
"$CD" refresh --quiet
"$CD" judge >/dev/null
assert grep -qF "$(printf '\tcause:alpha/lib/drive_a.py#load_drivers')" <(tail -n +4 "$CODE_DOCTOR_FAKE_LOG")
assert test "$(grep -c 'drive_a.py#load_drivers' "$CODE_DOCTOR_FAKE_LOG")" = 2
rm "$A/lib/extra.py"
"$CD" refresh --quiet
"$CD" judge >/dev/null

# Revalidation: the unit changed on main since the night base sends its verdict back to the judge.
sed -i '' 's/int(fields\[1\] or 0)/int(fields[1] or 1)/' "$A/lib/drive_b.py"
git -C "$A" add lib/drive_b.py && commit "$A" "seats default"
jq '.problems = [{id: "cause:alpha/lib/drive_a.py#load_drivers", state: "new"}] | .worktrees = []' "$C/record.json" >"$C/record2.json"
"$CD" check "$C/record2.json" --base refs/night/n1/base --landing --suites-passed >"$WORK/check.out"
assert grep -q 'alpha/lib/drive_b.py#load_drivers changed since the judgment' "$WORK/check.out"
assert jqe '.["cause:alpha/lib/drive_a.py#load_drivers"] | .digest == null and (.sent_back.why | length > 0)' \
  "$CODE_DOCTOR_DIR/verdicts.json"

# Recurrence: a landed cleanup goes fixed-pending, names its canonical mechanism, and a re-appearance regresses.
"$CD" record-fix 'cause:alpha/lib/refresh.sh#robot_curl_refresh' --by code-code-x --files alpha/lib/refresh.sh \
  --lines-removed 6 --mechanism 'curl refresh' --canonical 'alpha/lib/refresh.sh#user_curl_refresh' \
  --replaced 'alpha/lib/refresh.sh#robot_curl_refresh' >/dev/null
assert jqe '.mechanisms[0] | .mechanism == "curl refresh" and .canonical == "alpha/lib/refresh.sh#user_curl_refresh"' \
  "$C/mechanisms.json"
"$CD" >/dev/null
assert jqe '(.problems[] | select(.id == "cause:alpha/lib/refresh.sh#robot_curl_refresh") | .state) == "fixed-pending"
  and .yield.lines_removed == 6 and .groups.dead == 2' "$LATEST"
jq '.rows[0].status = "fixed" | .rows += [{id: "loose", title: "a row with no narrowing match", match: {}, status: "not-a-bug"}]' \
  "$CODE_DOCTOR_LEDGER" >"$C/ledger.tmp" && mv "$C/ledger.tmp" "$CODE_DOCTOR_LEDGER"
"$CD" >/dev/null
assert jqe '(.problems[] | select(.id == "cause:alpha/lib/refresh.sh#robot_curl_refresh") | .state) == "regressed"' "$LATEST"
assert jqe '.groups.ledger == 1 and ([.groups[]] | add) == .problem_count
  and ([.problems[] | select(.id == "ledger:loose")] | length) == 1' "$LATEST"

# Instruction weight is tokenmap's measured reads, never a guess that every session reads a doc.
printf '# alpha\nBefore debugging, read `docs/old-sync.md`.\n' >"$A/CLAUDE.md"
jq -n --arg c "$A/CLAUDE.md" --arg d "$A/docs/old-sync.md" '{paths: {entries: {
  ($c): {mode: "always_on", monthly: {loads: 900, read_tokens: 0}},
  ($d): {mode: "on_demand", monthly: {loads: 40, read_tokens: 18000000}}}}}' >"$C/read-rates.json"
TOKENMAP_RATES="$C/read-rates.json" "$CD" refresh --quiet
assert grep -qF 'alpha/docs/old-sync.md is ~' "$CODE_DOCTOR_DIR/candidates.jsonl"
assert grep -qF '~600000 a day, measured on-demand by tokenmap over 30 d' "$CODE_DOCTOR_DIR/candidates.jsonl"
assert test "$(grep -c 'alpha/CLAUDE.md is ~' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
jq 'del(.paths.entries[] | select(.mode == "on_demand"))' "$C/read-rates.json" >"$C/rates.tmp"
TOKENMAP_RATES="$C/rates.tmp" "$CD" refresh --quiet
assert test "$(grep -c 'old-sync.md is ~' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
rm "$A/CLAUDE.md"

# A hook registered through a ~/.claude/hooks link roots the link's target, not a same-named file elsewhere.
printf '#!/bin/bash\nexit 0\n' >"$REPOS/beta/lib/owner-gate.sh"
printf '#!/bin/bash\nexit 1\n' >"$A/hooks/owner-gate.sh"
chmod +x "$REPOS/beta/lib/owner-gate.sh" "$A/hooks/owner-gate.sh"
mkdir -p "$HOME/.claude/hooks"
ln -s "$REPOS/beta/lib/owner-gate.sh" "$HOME/.claude/hooks/owner-gate.sh"
cp "$HOME/.claude/settings.json" "$C/settings.saved"
jq '.hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: "~/.claude/hooks/owner-gate.sh bash"}]}]' \
  "$C/settings.saved" >"$HOME/.claude/settings.json"
"$CD" refresh --quiet
assert test "$(grep -c '"cause:beta/lib/owner-gate.sh"' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
assert grep -qF '"cause:alpha/hooks/owner-gate.sh"' "$CODE_DOCTOR_DIR/candidates.jsonl"
cp "$A/lib/drive_a.py" "$C/drive_a.saved"
printf '\n\nclass Overlay:\n    def mouseUp_(self, event):\n        self.event = event\n        return event\n\n    def lonely_helper(self):\n        value = 1\n        return value\n' >>"$A/lib/drive_a.py"
"$CD" refresh --quiet
assert grep -qF 'alpha/lib/drive_a.py#lonely_helper is defined and never called' "$CODE_DOCTOR_DIR/candidates.jsonl"
assert test "$(grep -c 'mouseUp_' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
mv "$C/drive_a.saved" "$A/lib/drive_a.py"
mkdir -p "$REPOS/beta/tests"
printf '#!/bin/bash\n. "$(dirname "$0")/../lib/owner-gate.sh"\n' >"$REPOS/beta/tests/test_owner_gate.sh"
"$CD" refresh --quiet
assert test "$(grep -c 'beta/tests/test_owner_gate.sh' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
rm "$REPOS/beta/tests/test_owner_gate.sh"
mv "$C/settings.saved" "$HOME/.claude/settings.json"
rm "$HOME/.claude/hooks/owner-gate.sh" "$REPOS/beta/lib/owner-gate.sh" "$A/hooks/owner-gate.sh"

# Liveness the deletion proof rests on: a cross-repo link roots its target, hooks of settings.local.json and of a
# repository's .claude/settings.json are entry points, a string-built path reaches every file it can name.
printf '#!/bin/bash\nexit 0\n' >"$A/lib/linked_gate.sh"
mkdir -p "$REPOS/beta/hooks"
ln -s "$A/lib/linked_gate.sh" "$REPOS/beta/hooks/linked-gate.sh"
cp "$HOME/.claude/settings.json" "$C/settings.saved"
jq --arg c "$REPOS/beta/hooks/linked-gate.sh" '.hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]' \
  "$C/settings.saved" >"$HOME/.claude/settings.json"
printf '#!/bin/bash\n. "$(dirname "$0")/../lib/${KIND:-fast}-plugin.sh"\n' >"$A/hooks/local-only.sh"
printf 'plugin_run() {\n  echo fast\n  return 0\n}\n' >"$A/lib/fast-plugin.sh"
jq -n --arg c "$A/hooks/local-only.sh" '{hooks: {Stop: [{hooks: [{type: "command", command: $c}]}]}}' >"$HOME/.claude/settings.local.json"
mkdir -p "$REPOS/beta/.claude"
printf '#!/bin/bash\nexit 0\n' >"$REPOS/beta/lib/project-hook.sh"
jq -n '{hooks: {Stop: [{hooks: [{type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/lib/project-hook.sh"}]}]}}' \
  >"$REPOS/beta/.claude/settings.json"
"$CD" refresh --quiet
assert test "$(grep -c '"cause:alpha/lib/linked_gate.sh"' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
assert test "$(grep -c '"cause:alpha/hooks/local-only.sh"' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
assert test "$(grep -c '"cause:beta/lib/project-hook.sh"' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
assert test "$(grep -c '"cause:alpha/lib/fast-plugin.sh"' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
mv "$C/settings.saved" "$HOME/.claude/settings.json"
rm -r "$HOME/.claude/settings.local.json" "$REPOS/beta/.claude" "$REPOS/beta/hooks" "$REPOS/beta/lib/project-hook.sh" \
  "$A/lib/linked_gate.sh" "$A/hooks/local-only.sh" "$A/lib/fast-plugin.sh"
"$CD" refresh --quiet

# Edits through a link the gate must see: a link with a non-ASCII name, a link out of every repository.
mkdir -p "$REPOS/beta/extra" "$C/outside-dir"
printf 'echo extra\n' >"$REPOS/beta/extra/tool.sh"
printf 'echo outside\n' >"$C/outside-dir/x.sh"
git -C "$REPOS/beta" add extra && commit "$REPOS/beta" "extra"
ln -s "$REPOS/beta/extra" "$WT/lïnk"
ln -s "$C/outside-dir" "$WT/outside"
git -C "$WT" add lïnk outside
printf 'echo edited\n' >>"$WT/lïnk/tool.sh"
printf 'echo edited\n' >>"$WT/outside/x.sh"
"$CD" check "$C/record.json" --base refs/night/n1/base >"$WORK/check.out"
assert grep -qF 'edited through the symlink lïnk into' "$WORK/check.out"
assert grep -qF "$C/outside-dir/x.sh: edited through the symlink outside into $C/outside-dir" "$WORK/check.out"
git -C "$WT" rm -q --cached lïnk outside && rm "$WT/lïnk" "$WT/outside"
git -C "$REPOS/beta" checkout -q -- extra
assert "$CD" check "$C/record.json" --base refs/night/n1/base

# Landing after other night jobs: the run is its commits on top of the rebase onto, never the jobs it was rebased over.
main_before=$(git -C "$A" rev-parse HEAD) wt_before=$(git -C "$WT" rev-parse HEAD)
git -C "$A" rm -q lib/manual_helpers.sh && commit "$A" "another night job"
git -C "$WT" -c user.name=t -c user.email=t@t rebase -q --onto main refs/night/n1/base || fail "rebase onto main"
git -C "$A" merge -q --ff-only night/n1/code-x || fail "ff-merge"
"$CD" check "$C/record.json" --base refs/night/n1/base --landing --suites-passed >"$WORK/check.out"
assert test "$(grep -c 'manual_helpers.sh\|changed since the judgment' "$WORK/check.out")" = 0
git -C "$A" reset -q --hard "$main_before" && git -C "$WT" reset -q --hard "$wt_before"
assert "$CD" check "$C/record.json" --base refs/night/n1/base

# Active work on a repository whose default branch is not main.
git -C "$A" branch -m main master
git -C "$A" worktree add -q -b live-x "$C/live" master || fail "worktree add live-x"
printf '# live branch\n' >>"$C/live/lib/old_sync_lib.sh"
git -C "$C/live" add lib/old_sync_lib.sh && commit "$C/live" "live work"
"$CD" check "$C/record.json" --base refs/night/n1/base --landing --suites-passed >"$WORK/check.out"
assert grep -qF 'alpha/lib/old_sync_lib.sh: in active work (changed on live branch live-x)' "$WORK/check.out"
git -C "$A" worktree remove --force "$C/live" && git -C "$A" branch -q -D live-x && git -C "$A" branch -m master main

# A function removed from a kept file needs a judged problem of the run naming it, like a deleted file.
cp "$WT/lib/refresh.sh" "$C/refresh.saved"
printf 'other() {\n  :\n}\n' >"$WT/lib/refresh.sh"
"$CD" check "$C/record.json" --base refs/night/n1/base >"$WORK/check.out"
assert grep -qF 'alpha/lib/refresh.sh#user_curl_refresh: deleted, but no judged problem of this run names it' "$WORK/check.out"
jq '.id = "code-code-y" | .problems += [{id: "cause:alpha/lib/refresh.sh#robot_curl_refresh", state: "regressed"}]' \
  "$C/record.json" >"$C/record-y.json"
"$CD" check "$C/record-y.json" --base refs/night/n1/base >"$WORK/check.out"
assert test "$(grep -c 'robot_curl_refresh: deleted, but no judged problem' "$WORK/check.out")" = 0
cp "$C/refresh.saved" "$WT/lib/refresh.sh"

# Close re-checks: a cause recorded fixed by the run whose every unit still reads as judged is refused.
"$CD" record-fix 'cause:alpha/lib/refresh.sh#robot_curl_refresh' --by code-code-y --files alpha/lib/refresh.sh >/dev/null
"$CD" check "$C/record-y.json" --base refs/night/n1/base >"$WORK/check.out"
assert grep -qF 'cause:alpha/lib/refresh.sh#robot_curl_refresh: recorded fixed by this run, but the re-check reads every unit as judged' \
  "$WORK/check.out"
printf 'user_curl_refresh() {\n  curl -fsS "https://example.invalid/refresh" -o /tmp/alpha-refresh.json\n  echo "refreshed on request"\n}\n' \
  >"$WT/lib/refresh.sh"
"$CD" check "$C/record-y.json" --base refs/night/n1/base >"$WORK/check.out"
assert test "$(grep -c 'recorded fixed by this run' "$WORK/check.out")" = 0
cp "$C/refresh.saved" "$WT/lib/refresh.sh"

# A run whose worktree is gone proves nothing; a day run (no worktree) is checked in the main checkouts since its launch.
jq --arg w "$C/no-such-worktree" '.worktrees = [$w]' "$C/record.json" >"$C/record-gone.json"
"$CD" check "$C/record-gone.json" --base refs/night/n1/base >"$WORK/check.out"
assert grep -qF "$C/no-such-worktree: the run's worktree is gone" "$WORK/check.out"
printf 'echo day\n' >"$REPOS/beta/lib/day-extra.sh"
git -C "$REPOS/beta" add lib/day-extra.sh && commit "$REPOS/beta" "day extra"
sleep 1
jq -n --arg t "$(iso_ago 0)" '{id: "code-day", doctor: "code", area: "code", launched_at: $t, problems: []}' \
  >"$C/record-day.json"
sleep 1
assert "$CD" check "$C/record-day.json"
git -C "$REPOS/beta" rm -q lib/day-extra.sh && commit "$REPOS/beta" "day fixer deletes"
"$CD" check "$C/record-day.json" >"$WORK/check.out"
assert grep -qF 'beta/lib/day-extra.sh: deleted, but no judged problem of this run names it' "$WORK/check.out"

# The run is bound to the units its snapshot handed the fixer, never to what the live document reads since.
jq --slurpfile d "$LATEST" '.problems = [$d[0].problems[] | select(.id == "cause:alpha/bin/old-sync")
  | .units |= map(select(.unit == "alpha/bin/old-sync"))]' "$C/record.json" >"$C/record-snap.json"
"$CD" check "$C/record-snap.json" --base refs/night/n1/base >"$WORK/check.out"
assert grep -qF 'alpha/lib/old_sync_lib.sh: deleted, but no judged problem of this run names it' "$WORK/check.out"
jq --slurpfile d "$LATEST" '.problems = [$d[0].problems[] | select(.id == "cause:alpha/bin/old-sync") | .cause = .id | .id = "row-x"]' \
  "$C/record.json" >"$C/record-row.json"
assert "$CD" check "$C/record-row.json" --base refs/night/n1/base
jq 'del(.launched_at)' "$C/record-day.json" >"$C/record-nolaunch.json"
"$CD" check "$C/record-nolaunch.json" >"$WORK/check.out"
assert grep -qF 'the run records no launch time' "$WORK/check.out"

# The snapshot never hands a needs-Egor problem to the fixer, whatever its value.
jq -n '{problems: [{id: "cause:registration:/gone", state: "new", needs_egor: true, value: 99, units: [], files: []}]}' \
  >"$C/egor-doc.json"
assert test "$("$CD" snapshot "$C/egor-doc.json")" = '[]'

# A symlink to an indexed file is that file: it never pairs with its own target as a duplicate.
ln -s "$A/lib/drive_a.py" "$REPOS/beta/lib/drive_link.py"
"$CD" refresh --quiet
assert grep -qF '"cause:alpha/lib/drive_a.py#load_drivers"' "$CODE_DOCTOR_DIR/candidates.jsonl"
assert test "$(jq -r '.units[].unit' "$CODE_DOCTOR_DIR/candidates.jsonl" | grep -c 'drive_link.py')" = 0
rm "$REPOS/beta/lib/drive_link.py"

# A ~/.local/bin link to an existing file the index skips (binary) is a working registration, never a dangling one.
printf 'x\0y' >"$REPOS/beta/lib/blob.bin"
ln -s "$REPOS/beta/lib/blob.bin" "$HOME/.local/bin/blob"
"$CD" refresh --quiet
assert test "$(grep -c 'blob.bin' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
rm "$HOME/.local/bin/blob" "$REPOS/beta/lib/blob.bin"

# Index and revalidation units: identical bytes keep each path's own kind, a link follows its target's edits,
# whole-file digests hash raw bytes, a same-named symbol resolves to its own span, a pre-history day base diffs.
U="$WORK/units"
mkdir -p "$U/repo/bin" "$U/repo/tests/fixtures" "$U/state"
printf '#!/bin/bash\necho same\n' >"$U/repo/bin/same.sh"
cp "$U/repo/bin/same.sh" "$U/repo/tests/fixtures/same.sh"
printf 'echo one\n' >"$U/repo/bin/real.sh"
ln -s real.sh "$U/repo/bin/link.sh"
printf 'line one\r\nbad \xff byte\r\n' >"$U/repo/bin/crlf.txt"
printf 'class A:\n    def run(self):\n        return 1\n\n\nclass B:\n    def run(self):\n        return 2\n' >"$U/repo/bin/two.py"
git -C "$U/repo" init -q -b main && git -C "$U/repo" add -A && commit "$U/repo" base
printf 'x\n' >"$U/repo/bin/gone.sh" && git -C "$U/repo" add -A && commit "$U/repo" gone
git -C "$U/repo" rm -q bin/gone.sh && commit "$U/repo" "gone goes"
CODE_DOCTOR_DIR="$U/state" python3 - "$CD" "$U/repo" >"$WORK/units.out" 2>&1 <<'PY'
import importlib.machinery, os, sys

cd = importlib.machinery.SourceFileLoader("code_doctor", sys.argv[1]).load_module()
top = sys.argv[2]
doc, _, _ = cd.index_repo(top, {})
files = doc["files"]
assert files["bin/same.sh"]["kind"] != files["tests/fixtures/same.sh"]["kind"], "identical bytes shared one kind"
with open(os.path.join(top, "bin/real.sh"), "a") as handle:
    handle.write("echo two\n" * 20)
doc, _, _ = cd.index_repo(top, {})
assert doc["files"]["bin/link.sh"]["digest"] == doc["files"]["bin/real.sh"]["digest"], "the link kept its stale record"
fid = "repo/bin/crlf.txt"
span = cd.unit_span(fid, doc["files"]["bin/crlf.txt"])
assert cd.unit_digest_at(top, None, span) == span["digest"], "whole-file digest differs from the index on CRLF bytes"
assert cd.unit_digest_at(top, "HEAD", span) == span["digest"], "whole-file digest at a ref differs from the index"
second = [s for s in doc["files"]["bin/two.py"]["symbols"] if s["name"] == "run"][1]
span = cd.unit_span("repo/bin/two.py", doc["files"]["bin/two.py"], second)
assert cd.unit_digest_at(top, None, span) == second["digest"], "the second same-named symbol read as the first"
lua = 'local function a(f)\n    if type(f) == "function" then f() end -- then do\n    print("a--b", \'end\')\nend\n\nlocal function b()\nend\n'
assert [(s["name"], s["end"]) for s in cd.symbols_of(lua, "lua")] == [("a", 4), ("b", 7)], "a keyword in a Lua string or comment moved a span end"
assert cd.diff_entries(top, cd.EMPTY_TREE), "a diff from the empty tree listed nothing"
real_git = cd.git
class Graph:
    tops = {"repo": top}
gone = {"kind": "path", "source": "/nonexistent/link", "target": top + "/bin/gone.sh"}
assert cd.registration_research(gone, Graph)["commit"], "the deleting commit went unfound"
for failing in ("log", "show"):
    cd.git = lambda folder, *args, **kw: None if args[0] == failing else real_git(folder, *args, **kw)
    assert cd.registration_research(gone, Graph) is None, "a failed git %s settled the registration" % failing
cd.git = real_git
class Writers:
    files = {"r/bin/a": {"kind": "code", "refs": {"code": ["state/runs.jsonl", "runs.jsonl", "x/runs.jsonl", "y/runs.jsonl",
                                                          "z/runs.jsonl"]}}}
    canonical = staticmethod(lambda fid: fid)
    resolve = staticmethod(lambda word, repo: [])
writers = cd.data_writers(Writers)
assert cd.claim_binding(Writers, {}, "r/README.md", ["runs.jsonl"], writers)[0] == ["r/bin/a"], \
    "one file naming a data file under several tokens counted as several writers: %s" % writers
print("ok")
PY
assert grep -qx ok "$WORK/units.out"

# A failed launch records worker-run's code and output; the recorded session history, not the base fallback, sizes the
# next session; a batch answer missing or mangling a candidate's block leaves that candidate waiting, never invents
# its verdict.
lay_out "$FIX/corpus" "$WORK/batch"
init_repos
"$CD" refresh --quiet
ids=$(jq -r 'select(.protected == null and .rules != ["registration"]) | .id' "$CODE_DOCTOR_DIR/candidates.jsonl")
first=$(sed -n 1p <<<"$ids")
second=$(sed -n 2p <<<"$ids")
CODE_DOCTOR_FAKE_LAUNCH_FAIL='no account has quota' "$CD" judge --night b0 >"$WORK/judge.out"
assert grep -q 'stop launch-failed' "$WORK/judge.out"
assert jqe 'select(.night == "b0") | .error | test("^worker-run start rc 3: .*no account has quota")' \
  "$CODE_DOCTOR_DIR/judge-runs.jsonl"
assert jqe -s '[.[] | select(.night == "b0" and .stage == "judge")] | length == 1 and (.[0].note | contains("no account has quota"))' \
  "$CODE_DOCTOR_DIR/accounting.jsonl"
printf '{"stage": "judge", "night": "seed", "cause": "seed", "tokens": 20000, "run": "seed-run"}\n' \
  >>"$CODE_DOCTOR_DIR/accounting.jsonl"
CODE_DOCTOR_FAKE_DROP="$first" CODE_DOCTOR_FAKE_MANGLE="$second" "$CD" judge --night b1 --max-tokens 30000 >"$WORK/judge.out"
assert grep -qF "judge: $(($(wc -l <<<"$ids") - 2)) judged · 2 waiting" "$WORK/judge.out"
assert grep -q 'stop done' "$WORK/judge.out"
assert jqe --arg a "$first" --arg b "$second" 'has($a) or has($b) | not' "$CODE_DOCTOR_DIR/verdicts.json"
"$CD" judge --night b2 >"$WORK/judge.out"
assert grep -qF 'judge: 2 judged · 0 waiting' "$WORK/judge.out"

# A dangling registration is researched, never asked: the commit that deleted or renamed its target and the
# tracked non-markdown files outside docs/ still naming it. Only the night judge of the sweep scope settles a link.
lay_out "$FIX/healthy" "$WORK/reg"
echo '{}' >"$CODE_DOCTOR_FAKE_VERDICTS"
init_repos
G="$REPOS/good"
LB="$HOME/.local/bin"
printf '#!/usr/bin/env bash\necho old\n' >"$G/bin/old-tool"
printf '#!/usr/bin/env bash\necho a\n' >"$G/bin/tool-a"
git -C "$G" add bin && commit "$G" "old-tool and tool-a land"
git -C "$G" rm -q bin/old-tool && commit "$G" "old-tool folds into good-tool --old"
gone=$(git -C "$G" rev-parse --short HEAD)
git -C "$G" mv bin/tool-a bin/tool-b && commit "$G" "tool-a becomes tool-b"
moved=$(git -C "$G" rev-parse --short HEAD)
mkdir -p "$G/docs" && printf 'old-tool\n' >"$G/docs/old.txt" && printf 'old-tool\n' >>"$G/README.md"
git -C "$G" add -A && commit "$G" "docs name old-tool"
ln -s "$G/bin/old-tool" "$LB/old-tool"
ln -s "$G/bin/tool-a" "$LB/tool-a"
ln -s "$G/bin/good-tool" "$LB/good-tool"
mv "$G/bin/good-tool" "$WORK/reg/good-tool"
"$CD" refresh --quiet
P="$CODE_DOCTOR_DIR/latest.json"
assert jqe --arg id "cause:registration:$G/bin/old-tool" --arg h "good@$gone" --arg l "$LB/old-tool" \
  '[.problems[] | select(.id == $id)] | length == 1 and (.[0] | .needs_egor == false and .steps == ["rm " + $l]
    and (.fact | contains($h) and contains("«old-tool folds into good-tool --old»") and contains("nothing references old-tool"))
    and (.proofs | any(contains($h))))' "$P"
assert jqe --arg id "cause:registration:$G/bin/tool-a" --arg h "good@$moved" --arg l "$LB/tool-a" --arg n "$G/bin/tool-b" \
  '[.problems[] | select(.id == $id)] | length == 1 and (.[0] | .needs_egor == false and .steps == ["ln -sfn " + $n + " " + $l]
    and (.fact | contains("renamed to bin/tool-b by " + $h)))' "$P"
assert test "$(grep -cF "\"cause:registration:$G/bin/good-tool\"" "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
mv "$WORK/reg/good-tool" "$G/bin/good-tool"
cp "$G/tests/test_greet.sh" "$WORK/reg/test_greet.sh"
printf 'command -v old-tool >/dev/null || true\n' >>"$G/tests/test_greet.sh"
git -C "$G" add -A && commit "$G" "a test still calls old-tool"
"$CD" refresh --quiet
assert jqe --arg id "cause:registration:$G/bin/old-tool" --arg s "migrate good/tests/test_greet.sh off old-tool as good@$gone says, then rm $LB/old-tool" \
  '[.problems[] | select(.id == $id)] | length == 1 and (.[0] | .needs_egor == false and .steps == [$s]
    and (.fact | contains("referenced by good/tests/test_greet.sh") and (contains("docs/") or contains("README")) == false))' "$P"
"$CD" judge --night r1 >/dev/null
assert test -L "$LB/old-tool"
assert test "$(readlink "$LB/tool-a")" = "$G/bin/tool-b"
ln -sfn "$G/bin/tool-a" "$LB/tool-a"
cp "$WORK/reg/test_greet.sh" "$G/tests/test_greet.sh"
# A settings file inside a repository is the code fixer's edit; a LaunchAgent whose program is gone the night
# judge boots out, its plist kept in the state dir; one whose argument is gone is a trade for Egor.
mkdir -p "$G/hooks" "$G/data" "$G/.claude" "$HOME/Library/LaunchAgents"
printf 'x\n' >"$G/hooks/gone-hook.sh" && printf 'x\n' >"$G/bin/old-job" && printf 'x\n' >"$G/data/feed.txt"
printf 'x\n' >"$G/bin/runner-a"
printf '#!/bin/bash\n. "$HOME/.claude/hooks/lib/hook-time.sh"\n' >"$G/hooks/quiet.sh"
git -C "$G" add -A && commit "$G" "hooks, job and feed land"
git -C "$G" rm -q hooks/gone-hook.sh bin/old-job data/feed.txt && commit "$G" "gone-hook, old-job and feed retire"
git -C "$G" mv bin/runner-a bin/runner-b && commit "$G" "runner-a becomes runner-b"
printf 'settings.json holds the hooks\n' >>"$HOME/.claude/CLAUDE.md"
jq -n --arg c "$G/hooks/gone-hook.sh" --arg q "$G/hooks/quiet.sh" \
  '{hooks: {Stop: [{hooks: [{type: "command", command: $c}, {type: "command", command: $q}]}]}}' >"$G/.claude/settings.json"
mkdir -p "$CODE_DOCTOR_DIR/rollup"
for d in $(seq 1 15); do
  printf '{"day": "%s", "complete": true, "sources": {"hooks": {"hits": {}, "ms": {}, "sessions": 1}}}\n' \
    "$(date -u -r $(($(date +%s) - d * 86400)) +%F)" >"$CODE_DOCTOR_DIR/rollup/quiet-$d.json"
done
agent() { # label program args... -> a LaunchAgent plist in the fixture HOME
  local label=$1 arg
  shift
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>%s</string>' "$label"
    printf '<key>ProgramArguments</key><array>'
    for arg in "$@"; do printf '<string>%s</string>' "$arg"; done
    printf '</array></dict></plist>\n'; } >"$HOME/Library/LaunchAgents/$label.plist"
}
agent com.test.oldjob /bin/bash "$G/bin/old-job"
agent com.test.feed /bin/cat "$G/data/feed.txt"
agent com.test.runner /bin/bash "$G/bin/runner-a"
agent com.test.behind /bin/bash "$G/bin/new-job"
printf '#!/usr/bin/env bash\necho a\n' >"$G/bin/spare-a" && printf '#!/usr/bin/env bash\necho b\n' >"$G/bin/spare-b"
git -C "$G" add -A && commit "$G" "the test no longer calls old-tool"
jq -n '{"cause:good/bin/spare-a": {verdict: "problem", fact: "spare-a is dead", plan: "rm bin/spare-a", proofs: [],
    needs_egor: true, trade: "Cost: a; Loss: b; Recommendation: c"},
  "cause:good/bin/spare-b": {verdict: "problem", fact: "spare-b is dead", plan: "rm bin/spare-b", proofs: [], needs_egor: true}}' \
  >"$CODE_DOCTOR_FAKE_VERDICTS"
"$CD" refresh --quiet
assert jqe --arg id "cause:registration:$G/hooks/gone-hook.sh" \
  '[.problems[] | select(.id == $id)] | length == 1 and (.[0] | .needs_egor == false and .files == ["good/.claude/settings.json"]
    and .repos == ["good"] and (.fact | contains("nothing references gone-hook.sh")))' "$P"
assert jqe 'select(.rules | index("silent")) | .needs_egor == false and .units[0].unit == "good/hooks/quiet.sh"' \
  "$CODE_DOCTOR_DIR/candidates.jsonl"
assert jqe --arg id "cause:registration:$G/bin/old-job" '[.problems[] | select(.id == $id)] | length == 1 and .[0].needs_egor == false' "$P"
assert jqe --arg id "cause:registration:$G/data/feed.txt" '[.problems[] | select(.id == $id)] | length == 1
  and (.[0] | .needs_egor and (.fact | startswith("needs Egor: Cost: ") and contains("Recommendation: boot it out")))' "$P"
assert jqe --arg id "cause:registration:$G/bin/runner-a" '[.problems[] | select(.id == $id)] | length == 1
  and (.[0] | .needs_egor and (.fact | contains("now bin/runner-b") and contains("Recommendation: point it at the new path")))' "$P"
assert jqe --arg id "cause:registration:$G/hooks/gone-hook.sh" 'select(.id == $id) | .registrations | any(startswith("{") | not)' \
  "$CODE_DOCTOR_DIR/candidates.jsonl"
"$CD" judge >/dev/null
assert grep -qF 'find why it exists (`git log -S<its name>`' "$CODE_DOCTOR_DIR"/judge/day/batch-*.md
assert grep -qF 'Egor decides only what research cannot settle, and only as a trade' "$CODE_DOCTOR_DIR"/judge/day/batch-*.md
assert jqe '[.problems[] | select(.id == "cause:good/bin/spare-a")] | length == 1
  and (.[0] | .needs_egor and .fact == "needs Egor: Cost: a; Loss: b; Recommendation: c")' "$P"
assert jqe '[.problems[] | select(.id == "cause:good/bin/spare-b")] | length == 1 and (.[0] | .needs_egor == false and .fact == "spare-b is dead")' "$P"
"$CD" judge --repo "$G" --night r2 >/dev/null
assert test -L "$LB/old-tool"
assert test "$(readlink "$LB/tool-a")" = "$G/bin/tool-a"
assert test -f "$HOME/Library/LaunchAgents/com.test.oldjob.plist" -a ! -e "$WORK/reg/launchctl.log"
assert jqe --arg id "cause:registration:$G/bin/new-job" 'select(.id == $id) | .research.never_tracked' "$CODE_DOCTOR_DIR/candidates.jsonl"
# The program landed on origin/main after the candidate was built and the checkout is behind: never retired.
git -C "$G" checkout -q -b ahead && printf 'x\n' >"$G/bin/new-job" && git -C "$G" add bin/new-job && commit "$G" "new-job lands"
git -C "$G" update-ref refs/remotes/origin/main HEAD && git -C "$G" checkout -q main && git -C "$G" branch -qD ahead
"$CD" judge --night r3 >"$WORK/judge.out"
assert test -f "$HOME/Library/LaunchAgents/com.test.behind.plist" -a ! -e "$G/bin/new-job"
assert grep -qxF "registration: unlinked $LB/old-tool -> $G/bin/old-tool" "$WORK/judge.out"
assert test ! -e "$LB/old-tool" -a ! -L "$LB/old-tool"
assert test "$(readlink "$LB/tool-a")" = "$G/bin/tool-b"
assert jqe -s --arg l "$LB/old-tool" --arg t "$G/bin/old-tool" \
  'map(select(.night == "r3" and .stage == "fix" and .link == $l and .readlink == $t)) | length == 1' "$CODE_DOCTOR_DIR/accounting.jsonl"
assert test "$(cat "$WORK/reg/launchctl.log")" = "bootout gui/$(id -u)/com.test.oldjob"
assert test ! -e "$HOME/Library/LaunchAgents/com.test.oldjob.plist" -a -f "$CODE_DOCTOR_DIR/retired-launchagents/com.test.oldjob.plist"
assert test -f "$HOME/Library/LaunchAgents/com.test.feed.plist" -a -f "$HOME/Library/LaunchAgents/com.test.runner.plist"
assert jqe -s --arg p "$HOME/Library/LaunchAgents/com.test.oldjob.plist" --arg m "$CODE_DOCTOR_DIR/retired-launchagents/com.test.oldjob.plist" \
  'map(select(.night == "r3" and .stage == "fix" and .plist == $p and .moved_to == $m and .label == "com.test.oldjob")) | length == 1' \
  "$CODE_DOCTOR_DIR/accounting.jsonl"
rm "$G/.claude/settings.json" "$HOME/Library/LaunchAgents/com.test.feed.plist" "$HOME/Library/LaunchAgents/com.test.runner.plist"
"$CD" refresh --quiet
assert jqe '[.problems[] | select(.rule == "registration")] == []' "$P"

# Any repository through --repo: its own state under scopes/, generic entry points and JS/TS imports, no runtime
# journal claimed, and report-only: judged problems show, but no snapshot and no check hands them to a fixer.
lay_out "$FIX/node" "$WORK/node"
init_repos
NODE="$REPOS/node-app"
export CODE_DOCTOR_REPOS="$WORK/healthy/repos/good"
"$CD" refresh --quiet
base_sum=$(shasum "$CODE_DOCTOR_DIR/latest.json")
assert jqe '.scope.report_only == null and .scope.foreign == []' "$CODE_DOCTOR_DIR/latest.json"
"$CD" refresh --quiet --repo "$NODE/src" || fail "scoped refresh failed"
SCOPED=$(ls -d "$CODE_DOCTOR_DIR"/scopes/node-app-*)
assert test "$(shasum "$CODE_DOCTOR_DIR/latest.json")" = "$base_sum"
assert jqe -s 'map({id, group, units: [.units[].unit]}) | sort_by(.id) == [
  {id: "cause:node-app/src/lib/helpers/index.ts#formatElapsed", group: "duplicate",
   units: ["node-app/src/lib/helpers/index.ts#formatElapsed", "node-app/src/lib/live.ts#formatDuration"]},
  {id: "cause:node-app/src/lib/orphan.ts", group: "dead", units: ["node-app/src/lib/orphan.ts"]}]' "$SCOPED/candidates.jsonl"
assert jqe '([.blind_spots[].id] | index("runtime:no-journal") != null and index("tests:untimed") != null
  and index("rollup:none") == null) and (.scope.report_only | contains("not a sweep repository"))' "$SCOPED/latest.json"
"$CD" refresh --quiet --repo "$WORK/healthy/repos/good"
assert test "$(ls "$CODE_DOCTOR_DIR/scopes" | wc -l | tr -d ' ')" = 1
"$CD" judge --repo "$NODE" --night s1 >/dev/null
assert jqe '.problem_count == 2 and .groups.dead == 1 and .groups.duplicate == 1' "$SCOPED/latest.json"
assert test "$("$CD" snapshot --repo "$NODE" "$SCOPED/latest.json")" = '[]'
jq -n '{id: "code-s", doctor: "code", worktrees: [], launched_at: "2026-01-01T00:00:00Z", problems: []}' >"$WORK/node/record.json"
"$CD" check --repo "$NODE" "$WORK/node/record.json" >"$WORK/check.out"
assert grep -qF "report-only scope: $NODE is not a sweep repository" "$WORK/check.out"

lay_out "$FIX/generic" "$WORK/generic"
mkdir -p "$REPOS/gen/tests" && printf '#!/usr/bin/env bash\nsleep 200\n' >"$REPOS/gen/tests/test_big.sh"
printf '{"end":%s,"secs":200,"who":"chat","repo":"gen","label":"test_big"}\n' "$now" "$now" "$now" >"$WORK/generic/sl/test-history.jsonl"
init_repos
export CODE_DOCTOR_REPOS="$WORK/healthy/repos/good"
"$CD" refresh --quiet --repo "$REPOS/gen"
jq -r '.units[].unit' "$CODE_DOCTOR_DIR"/scopes/gen-*/candidates.jsonl >"$WORK/generic.units"
assert grep -qx 'gen/src/gen_pkg/unused.py' "$WORK/generic.units"
for live in src/gen_pkg/__init__.py src/gen_pkg/cli.py src/gen_pkg/plugin.py src/gen_pkg/legacy.py src/gen_pkg/web.py \
  src/gen_pkg/formats/__init__.py src/gen_pkg/formats/table.py src/gen_pkg/formats/grid.py tools/lint.sh src/gen_pkg/checks.py server/serve.py ci/verify.sh \
  web/app/page.tsx web/src/ui/card.tsx web/next.config.mjs web/widget.spec.ts src/pages/index.tsx routes/health.py api/ping.ts; do
  assert test "$(grep -c "^gen/$live\$" "$WORK/generic.units")" = 0
done
assert jqe -s '[.[] | select(.id == "cause:gen/tests/test_big.sh") | .rules | index("test") != null] == [true]' \
  "$CODE_DOCTOR_DIR"/scopes/gen-*/candidates.jsonl

# Collector runs journal one row each, the subcommand in the trigger; the fixer's tools journal none.
RUNS="$WORK/doctors-runs"
unset DOCTOR_TRIGGER
DOCTORS_DIR="$RUNS" DOCTOR_TRIGGER=night "$CD" --json </dev/null >/dev/null || true
DOCTORS_DIR="$RUNS" "$CD" rollup </dev/null >/dev/null
DOCTORS_DIR="$RUNS" "$CD" check "$WORK/no-record.json" </dev/null >/dev/null || true
assert jqe -s 'length == 2 and all(.[]; (keys == ["cpu_s", "doctor", "start", "trigger", "wall_s"]) and .doctor == "code")
  and .[0].trigger == "night" and .[1].trigger == "background:rollup"' "$RUNS/collector-runs.jsonl"

# Reuse: one label spelled in bash, Python and a third place is ONE concept cause; a literal of common words or one
# spread over many files, and a link to a site, are none; a layout section beside a renderer is a prose candidate, a
# section that only mentions a report is not; fresh code matches an existing helper below the clone floor and is judged
# first; a pair of test cases weighs less than a pair of helpers the suites could source.
lay_out "$FIX/reuse" "$WORK/reuse"
R2="$REPOS/alpha2"
for i in $(seq 1 120); do
  {
    printf '#!/usr/bin/env bash\nf%s() {\n  local done now a=$1 b=$2 step=%s\n' "$i" "$i"
    [ "$i" -gt 10 ] || printf '  printf "%%s\\n" "$a ◆ $b"\n'
    [ "$i" -gt 2 ] || printf '  echo "$step done now"\n'
    printf '  echo "$done $now"\n}\n'
  } >"$R2/lib/f$i.sh"
done
mkdir -p "$R2/skills/report" "$R2/skills/mention" "$R2/tests"
cat >"$R2/skills/report/SKILL.md" <<'MD'
# Report

## Final report

At the end print the final report. Per repository one line `<name> · debt N lines · K dirty`, then
one line per worktree, indented: `<branch> · +ahead/-behind · take|keep`. Close with
`total · debt N lines`.

## Notes

The report is information only: print it and go on.
MD
printf '# Mention\n\n## Notes\n\nWhen the work is done, send the report to the owner chat and print a short answer.\n' \
  >"$R2/skills/mention/SKILL.md"
for t in one two; do
  printf 'def test_parse_rows():\n    rows = [("a", 1), ("b", 2), ("c", 3)]\n    total = 0\n    for name, value in rows:\n        assert name\n        total += value\n    assert total == 6\n    assert len(rows) == 3\n    assert rows[0][0] == "a"\n' \
    >"$R2/tests/test_$t.py"
  printf '#!/usr/bin/env bash\nwait_for() {\n  local tries=0\n  while [ "$tries" -lt 50 ]; do\n    [ -e "$1" ] && return 0\n    tries=$((tries + 1))\n    sleep 0.1\n  done\n  echo "timed out waiting for $1" >&2\n  return 1\n}\n' \
    >"$R2/tests/test_$t.sh"
done
ln -s "$R2/hooks/commit-report.sh" "$REPOS/beta2/share/linked-report.sh"
init_repos
"$CD" refresh --quiet || fail "refresh failed on the reuse fixture"
CJ="$CODE_DOCTOR_DIR/candidates.jsonl"
assert jqe -s '[.[] | select(.rules | index("concept")) | select([.units[].unit] | index("alpha2/hooks/commit-report.sh#project_name") != null
  and index("beta2/share/rbench/report.py#report_repo_identity") != null and index("alpha2/bin/dirline.sh#fit_dir_part") != null)
  | select(.group == "duplicate" and (.detail | contains("«⧉» (3 of")))] | length == 1' "$CJ"
assert jqe -s '[.[] | select([.units[].unit] | index("alpha2/hooks/commit-report.sh#project_name") != null)] | length == 1' "$CJ"
assert test "$(grep -c '◆\|done now' "$CJ")" = 0
assert test "$(jq -r '.units[].unit' "$CJ" | grep -c 'linked-report')" = 0
assert jqe -s '[.[] | select(.rules | index("prose-layout")) | select(.id == "cause:alpha2/skills/report/SKILL.md"
  and (.detail | contains("§Final report") and (contains("§Notes") | not)) and .reuse == ["beta2/share/report_frame.py"])] | length == 1' "$CJ"
assert jqe -s '[.[] | select(.rules | index("prose-layout")) | .units[].unit | select(contains("mention"))] == []' "$CJ"
assert jqe -s '([.[] | select(.units[0].unit == "alpha2/tests/test_one.py#test_parse_rows") | .value] == [2])
  and ([.[] | select(.units[0].unit == "alpha2/tests/test_one.sh#wait_for") | .value] == [10])' "$CJ"
printf '\ncut_label() {\n  local text=$1 width=$2\n  [ "${#text}" -le "$width" ] && { printf '"'"'%%s\\n'"'"' "$text"; return; }\n  printf '"'"'%%s~\\n'"'"' "${text:0:$((width - 1))}"\n}\n' \
  >>"$R2/bin/dirline.sh"
"$CD" refresh --quiet
assert jqe -s '[.[] | select(.id == "cause:alpha2/bin/dirline.sh#cut_label" and .new and .fresh and (.rules | index("reuse"))
  and ([.units[].unit] == ["alpha2/bin/dirline.sh#cut_label", "alpha2/lib/labels.sh#trim_label"]))] | length == 1' "$CJ"
jq -n '{"cause:alpha2/bin/dirline.sh#cut_label": {verdict: "problem", fact: "re-does trim_label", plan: "call trim_label"}}' \
  >"$CODE_DOCTOR_FAKE_VERDICTS"
"$CD" judge --night f1 --limit 1 --batch 1 >/dev/null
assert test "$(head -1 "$CODE_DOCTOR_FAKE_LOG" | cut -f2)" = "cause:alpha2/bin/dirline.sh#cut_label"
for later in 8 16; do
  CODE_DOCTOR_NOW=$(($(date +%s) + later * 86400)) "$CD" refresh --quiet
done
assert jqe -s '[.[] | select(.id == "cause:alpha2/bin/dirline.sh#cut_label" and (.fresh | not) and (.rules | index("reuse")))]
  | length == 1' "$CJ"
assert jqe '[.problems[] | select(.id == "cause:alpha2/bin/dirline.sh#cut_label")] | length == 1' "$CODE_DOCTOR_DIR/latest.json"

# Promise: the worker-message case. An agent says a SendMessage note reaches the worker mid-run while worker-run has no
# input channel: a claim bound to the code its name resolves to. A chat's «передал» right after a queued result is one
# overclaim cause on the mechanism, sighted through the Harness reader, its words never persisted. Broken verdicts are
# problems with the proof obligation; kept and untested-outside-the-risk-classes are not; a changed claim goes first.
lay_out "$FIX/promise/broken" "$WORK/promise"
init_repos
RELAY="$REPOS/relay"
mkdir -p "$WORK/promise/projects/-relay"
python3 - "$WORK/promise/projects/-relay/0b3c9e41-7d55-4f7e-9a51-5c1f00d2a7aa.jsonl" "$RELAY" <<'PY'
import json, sys, time
path, cwd = sys.argv[1], sys.argv[2]
now = time.time() - 600

def line(i, kind, content):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now + i))
    return json.dumps({"type": kind, "timestamp": stamp, "cwd": cwd, "entrypoint": "cli",
                       "message": {"role": kind, "content": content}}, ensure_ascii=False)

def say(i, tid, text):
    return line(i, "assistant", [{"type": "tool_use", "id": tid, "name": "Bash",
                                  "input": {"command": "cd %s && worker-run say run-1 '%s'" % (cwd, text)}}])

rows = [line(0, "user", "передай воркеру: используй кэш"), say(1, "toolu_1", "use the cache"),
        line(2, "user", [{"type": "tool_result", "tool_use_id": "toolu_1",
                          "content": "queued for delivery to the worker at its next tool round"}]),
        line(3, "assistant", [{"type": "text", "text": "Готово, передал воркеру."}]),
        line(4, "user", "и ещё: без сети"), say(5, "toolu_2", "no network"),
        line(6, "user", [{"type": "tool_result", "tool_use_id": "toolu_2", "content": "delivered at 12:00:01"}]),
        line(7, "assistant", [{"type": "text", "text": "Передал."}]),
        line(8, "assistant", [{"type": "tool_use", "id": "toolu_3", "name": "Bash", "input": {"command": "grep -rn queued ."}}]),
        line(9, "user", [{"type": "tool_result", "tool_use_id": "toolu_3", "content": "notes.md:1: queued"}]),
        line(10, "assistant", [{"type": "text", "text": "Отправил."}]),
        line(11, "assistant", [{"type": "tool_use", "id": "toolu_4", "name": "Bash", "input": {"command": "worker-run report run-1"}}]),
        line(12, "user", [{"type": "tool_result", "tool_use_id": "toolu_4",
                           "content": "STATUS: done\nEXIT: 0\nSESSION: s-1\nBRIEF: notes queued in the background arrive later"}]),
        line(13, "assistant", [{"type": "text", "text": "Отправил."}])]
open(path, "w").write("\n".join(rows) + "\n")
PY
CLAUDE_PROJECTS_DIR="$WORK/promise/projects" HARNESS_DOCTOR_BOOTS= python3 - "$ROOT/bin/harness-doctor" <<'PY'
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1])
doctor = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(doctor)
events = []
doctor.scan_transcripts({}, time.time(), events, {})
doctor.append_events(events)
PY
assert test "$(cat "$HARNESS_DOCTOR_DIR"/events/*.jsonl | grep -c '^\["o"')" = 1
"$CD" refresh --quiet || fail "refresh failed on the promise fixture"
CJ="$CODE_DOCTOR_DIR/candidates.jsonl"
assert jqe -s '[.[] | select(.group == "promise" and .rules == ["claim"] and .risk == "delivery"
  and (.id | startswith("cause:relay/agents/claudeb-worker.md#promise:")) and .files == ["relay/agents/claudeb-worker.md", "relay/bin/worker-run"]
  and (.detail | contains("SendMessage reaches the worker mid-run")))] | length == 1' "$CJ"
assert jqe -s '[.[] | select(.group == "promise" and .rules == ["claim"])] | map(.risk) | sort == ["data", "delivery", "other"]' "$CJ"
assert jqe -s '[.[] | select(.rules == ["overclaim"])] | length == 1 and all(.id == "cause:overclaim:worker-run say" and .group == "promise"
  and ([.units[].unit] == ["relay/bin/worker-run"]) and (.detail | startswith("1 times")) and (.detail | contains("said queued"))
  and .sightings == ["0b3c9e41-7d55-4f7e-9a51-5c1f00d2a7aa line 4"])' "$CJ"
assert jqe -s 'map(select(.group == "promise")) | length == 4' "$CJ"
assert test "$(grep -rl 'передал\|use the cache' "$CODE_DOCTOR_DIR" "$HARNESS_DOCTOR_DIR" | wc -l | tr -d ' ')" = 0
EV=$(ls "$HARNESS_DOCTOR_DIR"/events/*.jsonl | head -1)
cp "$EV" "$WORK/events.bak"
printf '["o", "half-writ\n' >>"$EV"
"$CD" rollup >/dev/null
assert jqe '.sources.overclaims.hits == {"overclaim:worker-run say": 1}' "$CODE_DOCTOR_DIR/rollup/$(basename "$EV" .jsonl).json"
mv "$WORK/events.bak" "$EV"
jq -s 'map(select(.group == "promise") | {key: .id, value: (
    if .rules == ["overclaim"] then {verdict: "problem", kind: "broken", fix: "code", fact: "queued read as done", plan: "print a receipt"}
    elif .risk == "delivery" then {verdict: "problem", kind: "broken", fix: "code", fact: "no input channel", plan: "add an inbox"}
    elif .risk == "data" then {verdict: "kept", kept_by: "relay/bin/worker-run:7", test: "none", fact: "kept"}
    else {verdict: "problem", kind: "untested", fact: "no retry test", plan: "test it"} end)}) | from_entries' "$CJ" \
  >"$CODE_DOCTOR_FAKE_VERDICTS"
"$CD" judge --night p1 >/dev/null
assert test "$(cut -f2 "$CODE_DOCTOR_FAKE_LOG" | head -2 | tr '\n' ' ')" = "cause:overclaim:worker-run say $(jq -r 'select(.risk == "delivery" and .rules == ["claim"]) | .id' "$CJ") "
P="$CODE_DOCTOR_DIR/latest.json"
assert jqe '.groups.promise == 2 and .problem_count == ([.groups[]] | add) and .candidates.waiting == 0
  and ([.problems[] | select(.group == "promise") | select(.kind == "broken" and .fix == "code"
       and (.proofs | any(contains("red without the fix"))))] | length == 2)' "$P"
assert jqe '.coverage.judge.promise == {total: 4, waiting: 0} and .coverage.judge.nights_to_cover == 0' "$P"
assert jqe '[to_entries[] | select(.value.verdict == "not-now" and (.value.reason | startswith("untested outside the risk classes")))] | length == 1' \
  "$CODE_DOCTOR_DIR/verdicts.json"
"$CD" judge --night p2 >/dev/null
assert test "$(judged)" = 4
printf '\nThe `worker-run start` launch notifies the chat when the run ends.\n' >>"$RELAY/agents/claudeb-worker.md"
"$CD" refresh --quiet
"$CD" judge --night p3 --limit 1 --batch 1 >/dev/null
assert jqe --arg id "$(tail -1 "$CODE_DOCTOR_FAKE_LOG" | cut -f2)" -s '[.[] | select(.id == $id and .fresh and .risk == "delivery"
  and (.detail | contains("notifies the chat")))] | length == 1' "$CJ"

lay_out "$FIX/promise/kept" "$WORK/promise-kept"
init_repos
"$CD" refresh --quiet
assert jqe -s 'map(select(.group == "promise")) | length == 1 and .[0].risk == "delivery"' "$CODE_DOCTOR_DIR/candidates.jsonl"
jq -s 'map(select(.group == "promise") | {key: .id, value: {verdict: "kept", fact: "kept"}}) | from_entries' "$CODE_DOCTOR_DIR/candidates.jsonl" >"$CODE_DOCTOR_FAKE_VERDICTS"
"$CD" judge >/dev/null
assert jqe '.candidates.waiting_by_group.promise == 1' "$CODE_DOCTOR_DIR/latest.json"
jq -s 'map(select(.group == "promise") | {key: .id, value: {verdict: "kept", kept_by: "inbox/bin/worker-run:8", test: "inbox/tests/test_inbox.sh:9", fact: "kept"}})
  | from_entries' "$CODE_DOCTOR_DIR/candidates.jsonl" >"$CODE_DOCTOR_FAKE_VERDICTS"
"$CD" judge >/dev/null
assert jqe '.candidates.waiting_by_group.promise == 0 and .groups.promise == 0
  and ([.problems[] | select(.group == "promise")] == [])' "$CODE_DOCTOR_DIR/latest.json"
"$CD" judge >/dev/null
assert test "$(grep -c '#promise:' "$CODE_DOCTOR_FAKE_LOG")" = 2

# critical: unjudged review-debt paths go to the fixture judge with their fan-in hint, and its verdicts
# go back to review-debt keyed by blob; judged and stable paths are never sent.
CR="$WORK/critical"
mkdir -p "$CR/repo"
cat >"$CR/review-debt" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *' --record-critical '*) cat >>"$CR_RECORDED"; [ -z "${CR_RECORD_RC:-}" ] || { echo locked >&2; exit "$CR_RECORD_RC"; } ;;
  *) [ -z "${CR_LIST_RC:-}" ] || exit "$CR_LIST_RC"
     printf 'lib.sh\t200\tnew\tunjudged\tb1\t7\nleaf.sh\t9\tnew\tunjudged\tb2\t0\nold.sh\t5\tnew\tstable\tb3\t0\n'
     printf 'done.sh\t4\tnew\tfresh\tb4\t1\nLINES=218 FILES=4 DUE_LINES=5 DUE_FILES=1\n' ;;
esac
STUB
chmod +x "$CR/review-debt"
printf '{"lib.sh": {"critical": true, "reason": "every hook sources it"}, "leaf.sh": {"critical": false}}\n' \
  >"$CR/verdicts.json"
: >"$CR/judged.tsv"
CODE_DOCTOR_REVIEW_DEBT="$CR/review-debt" CR_RECORDED="$CR/recorded" CODE_DOCTOR_FAKE_LOG="$CR/judged.tsv" \
  CODE_DOCTOR_FAKE_VERDICTS="$CR/verdicts.json" "$CD" critical --repo "$CR/repo" --night n1 >"$CR/out" ||
  fail "code-doctor critical failed: $(cat "$CR/out")"
assert grep -q '^critical: 2 judged · 0 waiting · 1000 tokens · ' "$CR/out"
assert test "$(cut -f2 "$CR/judged.tsv" | tr '\n' ' ')" = "lib.sh leaf.sh "
assert grep -qx 'fan-in hint: 7' "$CODE_DOCTOR_DIR"/scopes/*/critical/n1/repo-1.md
assert jqe -s '. == [{path: "lib.sh", blob: "b1", critical: true, reason: "every hook sources it"},
  {path: "leaf.sh", blob: "b2", critical: false, reason: ""}]' "$CR/recorded"
: >"$CR/recorded"
CODE_DOCTOR_REVIEW_DEBT="$CR/review-debt" CR_RECORDED="$CR/recorded" CR_RECORD_RC=1 CODE_DOCTOR_FAKE_LOG="$CR/judged.tsv" \
  CODE_DOCTOR_FAKE_VERDICTS="$CR/verdicts.json" "$CD" critical --repo "$CR/repo" --night n2 >"$CR/out" 2>"$CR/err" &&
  fail "code-doctor critical passed though review-debt refused the verdicts"
assert grep -q '^critical: 0 judged · 2 waiting · 1000 tokens · .* stop record-failed$' "$CR/out"
assert grep -q 'record-critical rc 1: locked' "$CR/err"
CODE_DOCTOR_REVIEW_DEBT="$CR/missing" "$CD" critical --repo "$CR/repo" --night n3 >"$CR/out" 2>"$CR/err" &&
  fail "code-doctor critical passed without review-debt"
assert grep -q 'stop list-failed$' "$CR/out"
assert grep -q '^critical: review-debt --list: ' "$CR/err"
CR_LIST_RC=2 CODE_DOCTOR_REVIEW_DEBT="$CR/review-debt" "$CD" critical --repo "$CR/repo" --night n4 >"$CR/out" 2>"$CR/err" &&
  fail "code-doctor critical passed though review-debt --list failed"
assert grep -q '^critical: 0 judged · 0 waiting · 0 tokens · .* stop list-failed$' "$CR/out"
CODE_DOCTOR_DIR="$WORK/critical-k" python3 - "$CD" <<'PY' || fail "critical spend shrank the fix queue"
import importlib.machinery, sys

cd = importlib.machinery.SourceFileLoader("code_doctor", sys.argv[1]).load_module()
cd.os.makedirs(cd.state_dir(), exist_ok=True)
cd.account("n1", "critical:repo", "critical", tokens=400000)
assert cd.queue_k(cd.accounting_summary({})) == cd.TOP_K
cd.account("n1", "x", "fix", tokens=400000)
assert cd.queue_k(cd.accounting_summary({})) == cd.TOP_K_LOW_YIELD
PY

echo "PASS: $asserts asserts; calibration $(grep -c '^PASS' "$WORK/calibration")/5 cases, a healthy repository with 0 problems, the incremental index, the needs-Egor registration with its research, a dangling registration researched (deleting or renaming commit, live references, an uncommitted deletion no problem) and settled only by the sweep-scope night judge, the judge's batched sessions with their token, wall and launch-failure stops, the durable rollup and its coverage blind spot, the top-K snapshot with active work out, the safety gate (suites, a deletion no problem names, an edit through a cross-repo symlink, active work), the structural digest (rollup no, caller yes), revalidation against the night base, the ledger's fixed-pending, regressed and faulty rows, the canonical mechanisms, review claims through review-anchors, tokenmap-measured instruction weight, a hook rooted through its ~/.claude link, a runner-less test of live code, PyObjC selectors, a symlink never pairing with its target, per-path kinds for identical bytes, link-target edits, raw-byte and same-named-symbol digests, ledger-renamed causes, launch-less day runs, a --repo scope (its own state dir, the Node/TS calibration, generic entry points, no runtime journal claimed, report-only snapshot and check), heavy tests judged only in a --repo scope (a sweep repository's are the Harness Speed block's), collector runs journalled, one concept spelled in bash, Python and a third place as one cause (common literals and links out), a prose layout beside the renderer, fresh code matched against helpers and judged first, test-case boilerplate weighed down, the worker-message promise (a claim bound to its code, a chat overclaim on the mechanism with no words kept, broken problems with their proof, kept and untested-outside-risk out, a changed claim first)"
