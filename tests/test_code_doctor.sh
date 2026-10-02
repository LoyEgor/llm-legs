#!/usr/bin/env bash
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
  export HOME="$2/home" CODE_DOCTOR_DIR="$2/state" CODE_DOCTOR_LEDGER="$2/ledger.json" \
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
  printf '{"end":%s,"secs":200,"who":"chat","repo":"alpha","label":"test_slow"}\n' "$now"
done >"$C/sl/test-history.jsonl"
"$CD" index >"$WORK/index.out" || fail "index failed"
assert grep -q '^alpha: [0-9]* files' "$WORK/index.out"
"$CD" index >"$WORK/index2.out"
assert grep -q '^alpha: [0-9]* files · 0 parsed' "$WORK/index2.out"
"$CD" refresh --quiet || fail "refresh failed on the corpus"
LATEST="$CODE_DOCTOR_DIR/latest.json"
assert jqe '.candidates.waiting == 4 and .candidates.protected == 1 and .problem_count == 1 and .groups.dead == 1' "$LATEST"
assert jqe '[.problems[] | select(.needs_egor and (.fact | startswith("needs Egor: ")) and (.steps[0] | contains("settings.json")))] | length == 1' "$LATEST"
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
assert test "$(judged)" = 4
assert test "$(tail -3 "$CODE_DOCTOR_FAKE_LOG" | cut -f1 | sort -u | wc -l | tr -d ' ')" = 1
assert jqe -s '[.[] | select(.night == "n1" and .stage == "judge") | .tokens] | (add == 1000 and length == 3 and min >= 333)' \
  "$CODE_DOCTOR_DIR/accounting.jsonl"
"$CD" judge --night n1 >/dev/null
assert test "$(judged)" = 4

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
assert jqe '.problem_count == 5 and .groups == {dead: 3, heavy: 1, duplicate: 1}
  and ([.groups[]] | add) == .problem_count and .status == "problems"' "$LATEST"
assert jqe '.cost.tokens == 91000 and .cost_per_cause["cause:alpha/bin/old-sync"].judge.tokens > 0' "$LATEST"

# The rollup outlives the journal's prune and claims no silence past its window.
day=$((now / 86400 - 2))
mkdir -p "$C/harness/hooks"
printf '%s000000\t%s500000\tguard.sh\t0\t111\n' "$((day * 86400))" "$((day * 86400))" >"$C/harness/hooks/$day.tsv"
printf '%s000000\t%s900000\tguard.sh\t0\t112\n' "$((day * 86400 + 60))" "$((day * 86400 + 60))" >>"$C/harness/hooks/$day.tsv"
date_of_day=$(date -u -r $((day * 86400)) +%F)
mkdir -p "$C/harness/statusline"
printf '1\t2\ts-a\n3\t4\ts-b\n5\t6\ts-a\n' >"$C/harness/statusline/$date_of_day.tsv"
"$CD" rollup >/dev/null
assert jqe '.sources.hooks.hits["hook:guard.sh"] == 2 and .sources.hooks.sessions == null
  and .sources.statusline.sessions == 2 and .complete' "$CODE_DOCTOR_DIR/rollup/$date_of_day.json"
rm "$C/harness/hooks/$day.tsv" "$C/harness/statusline/$date_of_day.tsv"
"$CD" rollup >/dev/null
assert jqe '.sources.hooks.hits["hook:guard.sh"] == 2' "$CODE_DOCTOR_DIR/rollup/$date_of_day.json"
"$CD" >/dev/null
assert jqe '[.blind_spots[] | select(.id == "rollup:short" and (.what | contains("1 covered days")))] | length == 1' "$LATEST"

# The fixer's snapshot: top-K by value, revalidated, active work out.
"$CD" snapshot "$LATEST" --night n1 >"$WORK/snap.json"
assert jqe 'map(.id) == ["cause:alpha/tests/test_slow.sh", "cause:alpha/bin/old-sync", "cause:alpha/lib/drive_a.py#load_drivers"]' \
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
assert test "$(judged)" = 4
rm "$CODE_DOCTOR_DIR/rollup/extra.json"
printf 'from drive_a import load_drivers\n\nprint(load_drivers("/dev/null"))\n' >"$A/lib/extra.py"
"$CD" refresh --quiet
"$CD" judge >/dev/null
assert grep -qF "$(printf '\tcause:alpha/lib/drive_a.py#load_drivers')" <(tail -n +5 "$CODE_DOCTOR_FAKE_LOG")
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

# Hot runtime counts only rollup days after the hook's last commit, and waits for enough of them.
day0=$((now / 86400))
for name in tuned busy fresh; do printf '#!/bin/bash\necho %s\n' "$name" >"$A/hooks/$name.sh"; done
git -C "$A" add hooks/tuned.sh hooks/busy.sh
GIT_AUTHOR_DATE="$((now - 6 * 86400)) +0000" GIT_COMMITTER_DATE="$((now - 6 * 86400)) +0000" commit "$A" "tuned and busy"
git -C "$A" add hooks/fresh.sh
GIT_AUTHOR_DATE="$((now - 2 * 86400)) +0000" GIT_COMMITTER_DATE="$((now - 2 * 86400)) +0000" commit "$A" "fresh"
for ago in 9 8 5 4 3 1; do
  case $ago in 9 | 8) tuned=900000 busy=0 ;; 1) tuned=0 busy=0 ;; *) tuned=1000 busy=900000 ;; esac
  jq -n --arg d "$(date -u -r $(((day0 - ago) * 86400)) +%F)" --argjson t "$tuned" --argjson b "$busy" '{day: $d, complete: true,
    sources: {hooks: {hits: {"hook:tuned.sh": 10, "hook:busy.sh": 10, "hook:fresh.sh": 10},
    ms: {"hook:tuned.sh": $t, "hook:busy.sh": $b, "hook:fresh.sh": 900000}, sessions: null}}}' \
    >"$CODE_DOCTOR_DIR/rollup/hot-$ago.json"
done
"$CD" refresh --quiet
assert grep -qF 'busy.sh costs 540s a day' "$CODE_DOCTOR_DIR/candidates.jsonl"
assert test "$(grep -c 'tuned.sh costs' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
assert test "$(grep -c 'fresh.sh costs' "$CODE_DOCTOR_DIR/candidates.jsonl")" = 0
rm "$CODE_DOCTOR_DIR"/rollup/hot-*.json

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

echo "PASS: $asserts asserts; calibration $(grep -c '^PASS' "$WORK/calibration")/6 cases, a healthy repository with 0 problems, the incremental index, the needs-Egor registration, the judge's batched sessions with their token, wall and launch-failure stops, the durable rollup and its coverage blind spot, the top-K snapshot with active work out, the safety gate (suites, a deletion no problem names, an edit through a cross-repo symlink, active work), the structural digest (rollup no, caller yes), revalidation against the night base, the ledger's fixed-pending, regressed and faulty rows, the canonical mechanisms, review claims through review-anchors, tokenmap-measured instruction weight, a hook rooted through its ~/.claude link, a runner-less test of live code, PyObjC selectors, a symlink never pairing with its target, hot cost only from days after the last commit"
