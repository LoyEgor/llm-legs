#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# shards: 4
# night-run carry and suites: open handoffs and the previous night's failed suites become night jobs;
# the full run at Close records its result for the report.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts unexpectedly succeeded: $*"; }
jqe() { jq -e "$@" >/dev/null; }

export HOME="$WORK/home" RUN_SUITES_JOURNAL="$WORK/runs.jsonl" DOCTORS_DIR="$WORK/doctors" NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" CHAT_NAMES_CACHE="$WORK/names.json"
NIGHTS="$DOCTORS_DIR/nights"
night() { bash "$ROOT/bin/night-run" "$@"; }
mkdir -p "$NIGHTS" "$HOME/.claude/sessions" "$HOME/.claude/projects/p"
for name in repo other; do
  git init -q "$WORK/$name"
  mkdir -p "$WORK/$name/docs/handoffs" "$WORK/$name/tests"
  printf '%s\n' "$WORK/$name" >>"$WORK/sweep-repos"
done
git init -q "$WORK/foreign"
git init -q --bare -b main "$WORK/helper.git" && git init -q -b main "$WORK/helper"
printf 'v1\n' >"$WORK/helper/gate.py" && git -C "$WORK/helper" add gate.py &&
  git -C "$WORK/helper" -c user.name=t -c user.email=t@t commit -qm init &&
  git -C "$WORK/helper" remote add origin "$WORK/helper.git" && git -C "$WORK/helper" push -q origin main
git -C "$WORK/helper" branch -q egor-side
printf 'wip\n' >"$WORK/helper/wip.txt"
printf '%s\n' "$WORK/helper" >"$WORK/helper-repos"
export NIGHT_RUN_HELPER_REPOS="$WORK/helper-repos"
H="$WORK/repo/docs/handoffs"
printf '# A\n\nStatus: open\n\nFor the chat «Gone Chat». Needs a change in stop-dispatch.sh too, and in %s/foreign/hooks/gate.sh and %s/helper/gate.py.\n' "$WORK" "$WORK" >"$H/2026-09-28-old.md"
printf '# B\n\nStatus: open (half done)\n\nTo: «Live Chat».\n\nMentions «Gone Chat» later.\n' >"$H/2026-10-03-live.md"
printf '# C\n\nStatus: settled 20261003T0000Z-0001: fixed\n' >"$H/2026-09-29-settled.md"
printf '# D\n\nStatus: trade for Egor\nCost: one click.\nLoss: a stray error.\nRecommendation: click.\n' >"$WORK/other/docs/handoffs/2026-10-02-ask.md"
printf '{"pid": %s, "sessionId": "live-1"}\n' "$$" >"$HOME/.claude/sessions/1.json"
printf '{"type": "custom-title", "customTitle": "Live Chat", "sessionId": "live-1"}\n' >"$HOME/.claude/projects/p/live-1.jsonl"
for name in repo other; do git -C "$WORK/$name" add -A && git -C "$WORK/$name" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; done

if suite_shard_owns 1 nc-carry-and-suites; then
assert [ "$(python3 "$ROOT/share/handoffs.py" | jq -sc 'map([.slug, .to, .live])')" = \
  '[["2026-09-28-old",["Gone Chat"],[]],["2026-10-03-live",["Live Chat"],["Live Chat"]]]' ]

jq -n '{id: "N0", started_at: "2026-10-03T00:00:00Z", finished_at: "2026-10-03T03:00:00Z", jobs: [],
  suites: {started_at: "2026-10-03T03:00:00Z", finished_at: "2026-10-03T03:30:00Z",
    repos: [{repo: "'"$WORK/other"'", exit: 1, passed: 3, failed: ["test_x.sh"], log: "/l/other.log"}]}}' >"$NIGHTS/N0.json"
jq -n '{id: "N1", started_at: "2026-10-04T00:00:00Z", finished_at: null, jobs: []}' >"$NIGHTS/N1.json"
night base N1 >/dev/null || fail "night base failed"
night carry N1 >"$WORK/carry.out" || fail "carry failed"
wt="$WORK/repo/.claude/worktrees/night-N1-handoff-2026-09-28-old"
swt="$WORK/other/.claude/worktrees/night-N1-suite-other-test_x"
assert [ "$(cut -f1,3 "$WORK/carry.out")" = "handoff-2026-09-28-old	$wt
suite-other-test_x	$swt" ]
assert jqe '[.jobs[] | [.kind, .ref, .state, .branch]] == [["handoff", "handoff-2026-09-28-old", "pending", "night/N1/handoff-2026-09-28-old"],
  ["suite", "suite-other-test_x", "pending", "night/N1/suite-other-test_x"]]' "$NIGHTS/N1.json"
assert [ "$(git -C "$wt" symbolic-ref --short HEAD)" = night/N1/handoff-2026-09-28-old ]
brief=$(cut -f2 "$WORK/carry.out" | head -1)
# Every sweep repository gets its worktree, named in the handoff or not.
assert grep -qxF "ADD-DIR: $WORK/other/.claude/worktrees/night-N1-handoff-2026-09-28-old" "$brief"
assert grep -qF "Settle the handoff \`$WORK/repo/docs/handoffs/2026-09-28-old.md\`" "$brief"
assert grep -qF 'Cost:`, `Loss:` and `Recommendation:`' "$brief"
assert_fails grep -q '^MODEL:' "$brief"
assert grep -qF "Not the night's, so never a worktree, branch or commit there: \`$WORK/foreign\`. When the fix lies there" "$brief"
assert [ "$(grep -c "Not the night's" "$brief")" = 1 ]
# A helper repository is the night's to fix: based, an ADD-DIR worktree, no ban; it lands only the night's commits.
hwt="$WORK/helper/.claude/worktrees/night-N1-handoff-2026-09-28-old"
assert git -C "$WORK/helper" rev-parse -q --verify refs/night/N1/base >/dev/null
assert jqe '.bases.helper != null' "$NIGHTS/N1.json"
assert grep -qxF "ADD-DIR: $hwt" "$brief"
assert_fails grep -qF "\`$WORK/helper\`" "$brief"
printf 'v2\n' >"$hwt/gate.py" && git -C "$hwt" -c user.name=t -c user.email=t@t commit -qam fix &&
  git -C "$hwt" rebase -q --onto main refs/night/N1/base &&
  git -C "$WORK/helper" merge -q --ff-only night/N1/handoff-2026-09-28-old && git -C "$WORK/helper" push -q origin main ||
  fail "the helper's night branch did not land"
night job N1 set handoff-2026-09-28-old "commits=helper:$(git -C "$WORK/helper" rev-parse main)" pushed=true >/dev/null ||
  fail "a pushed helper night commit was refused"
assert [ "$(git -C "$WORK/helper" rev-list --count origin/main)" = 2 ]
assert_fails git -C "$WORK/helper" cat-file -e main:wip.txt 2>/dev/null
assert [ "$(cat "$WORK/helper/wip.txt")" = wip ]
night leftovers >"$WORK/helper-left" || fail "leftovers with a helper"
assert grep -qF "helper night/N1/handoff-2026-09-28-old · $hwt · landed · " "$WORK/helper-left"
assert_fails grep -qF "helper egor-side" "$WORK/helper-left"
assert grep -qF 'failed `test_x.sh` in '"$WORK/other"' (log `/l/other.log`)' "$(cut -f2 "$WORK/carry.out" | tail -1)"
night carry N1 >"$WORK/again.out" || fail "a second carry failed"
assert [ ! -s "$WORK/again.out" ]

assert_fails night job N1 set handoff-2026-09-28-old state=blocked-on-egor reason="needs his word" 2>"$WORK/err"
assert grep -qF 'needs its trade in reason= as Cost:, Loss: and Recommendation:' "$WORK/err"
night job N1 set handoff-2026-09-28-old state=blocked-on-egor \
  reason="Cost: an hour. Loss: a slow suite. Recommendation: fix it." >/dev/null || fail "a traded handoff job was refused"
night job N1 set suite-other-test_x state=blocked-on-egor reason="his word" >/dev/null || fail "a suite job needs no trade lines"

cat >"$WORK/repo/tests/run-all" <<'RUNALL'
#!/usr/bin/env bash
printf '%s|%s\n' "${CLAUDE_CODE_SESSION_ID-}" "${CLAUDE_LAUNCHER_SESSION-}" >"${SESSION_SEEN:-/dev/null}"
printf '{"kind":"suites","pid":%s,"started_at":%s,"suites":{"test_a.sh":{"rc":0},"test_b.sh":{"rc":1}}}\n' "$$" "$(date +%s)" >>"$RUN_SUITES_JOURNAL"
printf '{"kind":"suites","pid":%s,"started_at":1,"suites":{"test_c.sh":{"rc":0},"test_d.sh":{"rc":0}}}\n' "$$" >>"$RUN_SUITES_JOURNAL"
printf '%s\n' "test_a.sh  PASS        1  ok" "test_x.sh  FAIL 1      2  boom" "" "2 suites · 9 PASS · 1 FAIL · 3s wall (3s serial)"
exit 1
RUNALL
chmod +x "$WORK/repo/tests/run-all"
CLAUDE_CODE_SESSION_ID=chat-1 CLAUDE_LAUNCHER_SESSION=chat-1 SESSION_SEEN="$WORK/session-seen" night suites N1 --wait \
  || fail "suites failed"
# Nobody waits on the night's full run, so run-suites must not read it as the launching chat's own.
assert test "$(cat "$WORK/session-seen")" = "|"
assert jqe --arg r "$WORK/repo" --arg l "$NIGHTS/N1.suites.repo.log" \
  '.suites.finished_at != null and .suites.repos == [{repo: $r, exit: 1, log: $l, passed: 1, failed: ["test_b.sh"]}]' "$NIGHTS/N1.json"
assert grep -qxF 'suites · repo · 1 PASS · 1 FAIL: test_b.sh' <(night report N1 2>/dev/null)
rm "$NIGHTS/N1.suites.repo.log"
night suites N1 | grep -q '^night N1: full suites run in the background, pid [0-9]*$' || fail "suites did not detach"
for i in $(seq 1 100); do [ -s "$NIGHTS/N1.suites.repo.log" ] && jqe '.suites.finished_at != null' "$NIGHTS/N1.json" && break; sleep 0.1; done
assert jqe '.suites.repos[0].failed == ["test_b.sh"]' "$NIGHTS/N1.json"
# A run-all that dies before journaling still reads as failed, so the next night carries it.
jq -n '{id: "N1x", started_at: "2026-10-03T12:00:00Z", finished_at: null, jobs: []}' >"$NIGHTS/N1x.json"
mv "$WORK/repo/tests/run-all" "$WORK/run-all.kept"
printf '#!/usr/bin/env bash\nexit 3\n' >"$WORK/repo/tests/run-all"
chmod +x "$WORK/repo/tests/run-all"
night suites N1x --wait || fail "suites of a crashed run-all failed"
mv "$WORK/run-all.kept" "$WORK/repo/tests/run-all"
assert jqe '.suites.repos[0] | .exit == 3 and .passed == 0 and .failed == ["run-all"]' "$NIGHTS/N1x.json"
assert grep -qxF 'suites · repo · 0 PASS · 1 FAIL: run-all' <(night report N1x 2>/dev/null)
# The report waits out a live full run, so its FAIL reaches the morning message, and journals the wait.
jq -n '{id: "N1y", started_at: "2026-10-03T13:00:00Z", finished_at: null, jobs: []}' >"$NIGHTS/N1y.json"
mv "$WORK/repo/tests/run-all" "$WORK/run-all.kept"
printf '#!/usr/bin/env bash\nsleep 3\nexec "%s" "$@"\n' "$WORK/run-all.kept" >"$WORK/repo/tests/run-all"
chmod +x "$WORK/repo/tests/run-all"
night suites N1y >/dev/null || fail "suites did not detach"
for i in $(seq 1 50); do jqe '.suites.pid' "$NIGHTS/N1y.json" 2>/dev/null && break; sleep 0.1; done
HARNESS_WAITS_DIR="$WORK/waits" night report N1y >"$WORK/report-y" 2>/dev/null
mv "$WORK/run-all.kept" "$WORK/repo/tests/run-all"
assert grep -qxF 'suites · repo · 1 PASS · 1 FAIL: test_b.sh' "$WORK/report-y"
assert jqe -s 'length == 1 and .[0].class == "night-suites" and .[0].source == "night-run report N1y" and .[0].seconds > 1' \
  "$WORK"/waits/*.jsonl
jq -n '{id: "N1z", started_at: "2026-10-03T14:00:00Z", finished_at: null, jobs: [],
  suites: {started_at: "2026-10-03T14:00:00Z", finished_at: null, pid: 99999999, repos: []}}' >"$NIGHTS/N1z.json"
assert grep -qE '^suites · stopped unfinished since [0-9]{2}:[0-9]{2}$' <(night report N1z 2>/dev/null)
fi

mkdir -p "$WORK/bin" "$WORK/repo/share" "$WORK/alpha-cwd"
export PATH="$WORK/bin:$PATH" NIGHT_RUN_OPENER="$WORK/bin/opener" NIGHT_RUN_WORKER_PICK="$WORK/bin/pick"
# slot_room's machine reading, from one file: pressure level, load1, load15, free MB.
printf '#!/usr/bin/env bash\n[ "$*" = "-n kern.memorystatus_vm_pressure_level hw.ncpu vm.loadavg" ] || exec /usr/sbin/sysctl "$@"\nread -ra r <"%s/room"\nprintf "%%s\\n10\\n{ %%s 0.00 %%s }\\n" "${r[0]}" "${r[1]}" "${r[2]}"\n' "$WORK" >"$WORK/bin/sysctl"
printf '#!/usr/bin/env bash\nread -ra r <"%s/room"\nprintf "Mach Virtual Memory Statistics: (page size of 1048576 bytes)\\nPages free: %%s.\\n" "${r[3]}"\n' "$WORK" >"$WORK/bin/vm_stat"
printf '1 1.00 1.00 100000\n' >"$WORK/room"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >>"%s/opened"\n' "$WORK" >"$WORK/bin/opener"
printf '#!/usr/bin/env bash\necho acct-x\n' >"$WORK/bin/pick"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/bin/claudeb"
jq -n --arg cwd "$WORK/alpha-cwd" '[{name: "Beta Chat", session: "sess-b", cwd: "/b"}, {name: "Alpha Doctor", session: "sess-a", cwd: $cwd},
  {name: "Gamma Chat", session: "sess-c", cwd: "/c"}, {name: "Alpha Doctor", session: "sess-old", cwd: "/old"}]' >"$WORK/chats.json"
printf '#!/usr/bin/env bash\n[ "$*" = "--recent --json" ] && cat "%s/chats.json"\n' "$WORK" >"$WORK/bin/chat-find"
chmod +x "$WORK/bin/"*
printf '{"pid": %s, "sessionId": "sess-b"}\n' "$$" >"$HOME/.claude/sessions/2.json"
printf '{"type": "custom-title", "customTitle": "Beta Chat", "sessionId": "sess-b"}\n' >"$HOME/.claude/projects/p/sess-b.jsonl"
jq -n '{owner: "Beta Chat", owners: {alpha: "Alpha Doctor", gamma: "Gamma Chat", delta: "Delta Chat"}, rows: [
  {id: "A1", block: "alpha", handoff: "docs/handoffs/2026-09-20-a1.md"},
  {id: "A2", block: "alpha", note: "see docs/handoffs/2026-10-01-a2.md."},
  {id: "B1", handoff: "docs/handoffs/2026-09-25-b1.md"},
  {id: "C1", block: "gamma", handoff: "docs/handoffs/2026-09-26-c1.md"},
  {id: "D1", block: "delta", handoff: "docs/handoffs/2026-09-27-d1.md", fixes: [{note: "docs/handoffs/2026-09-28-d2.md"}]}]}' \
  >"$WORK/repo/share/doctor-ledger.json"
for slug in 2026-09-20-a1 2026-10-01-a2 2026-09-26-c1 2026-09-27-d1 2026-09-28-d2; do
  printf '# %s\n\nStatus: open\n\nTouches other.\n' "$slug" >"$H/$slug.md"
done
printf '# B1\n\nStatus: open\n\n## Yours to decide\n\nOne fork.\n' >"$H/2026-09-25-b1.md"

new_night() { jq -n --arg id "$1" '{id: $id, started_at: "2026-10-04T01:00:00Z", finished_at: null, session: null, jobs: []}' >"$NIGHTS/$1.json"
  night base "$1" >/dev/null || fail "night base $1 failed"; }
gt() { git -c user.name=t -c user.email=t@t "$@"; }
handoff_refs() { jq -c '[.jobs[] | select(.kind == "handoff") | .ref]' "$NIGHTS/$1.json"; }
if suite_shard_owns 2 nc-owner-chats; then
new_night N2
night carry N2 >"$WORK/n2.out" 2>"$WORK/n2.err" || fail "owner carry failed"
awt="$WORK/repo/.claude/worktrees/night-N2-owner-chat-alpha-doctor"
assert [ "$(grep '^owner-chat-' "$WORK/n2.out")" = "owner-chat-alpha-doctor	$NIGHTS/N2.owner-chat-alpha-doctor.prompt.md	opened acct-x sess-a
owner-chat-beta-chat	$NIGHTS/N2.owner-chat-beta-chat.prompt.md	message Beta Chat" ]
assert jqe --arg h "$H" '[.jobs[] | select(.kind == "owner-chat") | [.ref, .state, .branch, .owner, .session, .via, .account, .handoffs]]
  == [["owner-chat-alpha-doctor", "pending", "night/N2/owner-chat-alpha-doctor", "Alpha Doctor", "sess-a", "open", "acct-x",
       ["\($h)/2026-09-20-a1.md", "\($h)/2026-10-01-a2.md"]],
      ["owner-chat-beta-chat", "pending", "night/N2/owner-chat-beta-chat", "Beta Chat", "sess-b", "message", null,
       ["\($h)/2026-09-25-b1.md"]]]' "$NIGHTS/N2.json"
assert [ "$(handoff_refs N2)" = '["handoff-2026-09-26-c1","handoff-2026-09-27-d1","handoff-2026-09-28-d2","handoff-2026-09-28-old"]' ]
assert [ "$(cat "$WORK/opened")" = "$NIGHTS/N2.owner-chat-alpha-doctor.command" ]
cmd="$NIGHTS/N2.owner-chat-alpha-doctor.command"
assert grep -qxF "cd $WORK/alpha-cwd || exit 1" "$cmd"
assert grep -qF " profile acct-x --resume sess-a --permission-mode bypassPermissions " "$cmd"
assert_fails grep -qF -- '--model' "$cmd"
assert [ "$(git -C "$awt" symbolic-ref --short HEAD)" = night/N2/owner-chat-alpha-doctor ]
assert [ -d "$WORK/other/.claude/worktrees/night-N2-owner-chat-alpha-doctor" ]
prompt="$NIGHTS/N2.owner-chat-alpha-doctor.prompt.md"
assert grep -qxF -- "- \`$H/2026-09-20-a1.md\`" "$prompt"
assert grep -qF "Work on branch \`night/N2/owner-chat-alpha-doctor\` in its night worktrees: \`$awt\`" "$prompt"
assert grep -qF 'SendMessage the sweep chat running night N2' "$prompt"
# The orchestrator may change after carry (a wall failover): the owner resolves it when it reports.
assert grep -qF "\`$ROOT/bin/chat-name \"\$(jq -r .session $NIGHTS/N2.json)\"\` names the one now" "$prompt"
assert grep -qxF '«Alpha Doctor» open · 2 handoffs' <(night report N2 2>/dev/null | grep -o '«Alpha Doctor».*handoffs')
night carry N2 >"$WORK/n2b.out" 2>/dev/null || fail "a second owner carry failed"
assert [ ! -s "$WORK/n2b.out" ]
assert [ "$(wc -l <"$WORK/opened" | tr -d ' ')" = 1 ]

new_night N3
NIGHT_RUN_OWNER_CHATS=1 night carry N3 >"$WORK/n3.out" 2>"$WORK/n3.err" || fail "capped carry failed"
assert [ "$(grep -c '^owner-chat-' "$WORK/n3.out")" = 1 ]
assert grep -qxF 'night-run: owner chat «Beta Chat» deferred (1 owner chats at work): its handoffs are night jobs' "$WORK/n3.err"
assert [ "$(handoff_refs N3)" = '["handoff-2026-09-25-b1","handoff-2026-09-26-c1","handoff-2026-09-27-d1","handoff-2026-09-28-d2","handoff-2026-09-28-old"]' ]
fi

if suite_shard_owns 3 nc-owner-deferred; then
new_night N4
printf '2 1.00 1.00 100000\n' >"$WORK/room"
night carry N4 >"$WORK/n4.out" 2>"$WORK/n4.err" || fail "loaded carry failed"
printf '1 1.00 1.00 100000\n' >"$WORK/room"
assert [ "$(grep -c '^owner-chat-' "$WORK/n4.out")" = 0 ]
assert grep -qxF 'night-run: owner chat «Alpha Doctor» deferred (memory pressure level 2): its handoffs are night jobs' "$WORK/n4.err"
assert [ "$(handoff_refs N4)" = '["handoff-2026-09-20-a1","handoff-2026-09-25-b1","handoff-2026-09-26-c1","handoff-2026-09-27-d1","handoff-2026-09-28-d2","handoff-2026-09-28-old","handoff-2026-10-01-a2"]' ]
night carry N4 >"$WORK/n4b.out" 2>/dev/null || fail "a carry once the load fell failed"
assert [ ! -s "$WORK/n4b.out" ]
assert jqe '[.jobs[] | select(.kind == "owner-chat")] == []' "$NIGHTS/N4.json"

new_night N4p
mkdir "$NIGHTS/N4p.owner-chat-alpha-doctor.prompt.md"
night carry N4p >/dev/null 2>&1 || fail "carry with an unwritable prompt failed"
assert jqe '.jobs[] | select(.ref == "owner-chat-alpha-doctor") | .state == "failed-launch" and .reason == "not carried: prompt not written"' "$NIGHTS/N4p.json"
fi

if suite_shard_owns 4 nc-owner-evidence; then
O="$WORK/own"
git init -q "$O"
mkdir -p "$O/docs/handoffs" "$O/share" "$O/bin" "$HOME/.claude/projects/p/sess-dh/subagents" "$HOME/.cache/claude-worker-runs/r1"
printf '%s\n' "$O" >"$WORK/sweep-own"
touch "$O/share/hooks.py" "$O/bin/stall-tool" "$O/bin/old-tool" "$O/share/hook.sh" "$O/share/core.sh" "$O/bin/common" "$O/bin/shared"
git -C "$O" add -A && git -C "$O" -c user.name=t -c user.email=t@t commit -q -m init
jq -n --arg cwd "$WORK/alpha-cwd" '[{name: "Debt Hardening", session: "sess-dh", cwd: $cwd}, {name: "Phase Four", session: "sess-p4", cwd: $cwd},
  {name: "Beta Chat", session: "sess-b", cwd: "/b"}, {name: "Gamma Chat", session: "sess-c", cwd: $cwd}, {name: "Alpha Doctor", session: "sess-old", cwd: "/old"},
  {name: "Orchestrator", session: "sess-or", cwd: $cwd}, {name: "Editor", session: "sess-ed", cwd: $cwd}, {name: "Reader", session: "sess-rd", cwd: $cwd},
  {name: "Specialist", session: "sess-sp", cwd: $cwd}, {name: "Generalist", session: "sess-g", cwd: $cwd},
  {name: "Other One", session: "sess-o1", cwd: $cwd}, {name: "Other Two", session: "sess-o2", cwd: $cwd}, {name: "Other Three", session: "sess-o3", cwd: $cwd}]' >"$WORK/chats.json"
jq -n '{owners: {reviewers: "Phase Four", gamma: "Gamma Chat"}, rows: [
  {id: "R1", block: "reviewers", handoff: "docs/handoffs/2026-10-01-hooks.md"},
  {id: "G1", block: "gamma", handoff: "docs/handoffs/2026-10-02-to.md"},
  {id: "G2", block: "gamma", handoff: "docs/handoffs/2026-10-03-ledger.md"}]}' >"$O/share/doctor-ledger.json"
decide='\n\n## Yours to decide\n\nOne fork.\n'
printf "# Hooks\n\nStatus: open\n\nThe debt hooks in \`share/hooks.py\` misfire.$decide" >"$O/docs/handoffs/2026-10-01-hooks.md"
printf "# To\n\nStatus: open\n\nTo: «Phase Four».\n\nFix share/hooks.py and $WORK/foreign/x.sh.$decide" >"$O/docs/handoffs/2026-10-02-to.md"
printf "# Ledger\n\nStatus: open\n\nbin/old-tool breaks.$decide" >"$O/docs/handoffs/2026-10-03-ledger.md"
printf "# Tool\n\nStatus: open\n\n\`bin/stall-tool\` stalls; see docs/handoffs/2026-10-01-hooks.md.$decide" >"$O/docs/handoffs/2026-10-04-tool.md"
printf "# Delegated\n\nStatus: open\n\nshare/hook.sh drops rows.$decide" >"$O/docs/handoffs/2026-10-05-delegated.md"
printf "# Shared\n\nStatus: open\n\n\`share/core.sh\` with bin/common and bin/shared.$decide" >"$O/docs/handoffs/2026-10-06-shared.md"
printf "# Plain\n\nStatus: open — To: gamma chat (the one that built it)\n\nFix share/core.sh.$decide" >"$O/docs/handoffs/2026-10-07-plain-to.md"
line() { printf '%s\n' "$2" >>"$HOME/.claude/projects/p/$1.jsonl"; }
edit() { line "$1" "$(printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"%s","input":{"replace_all":false,"file_path":"%s","old_string":"a"}}]}}' "$2" "$3")"; }
edits() { for i in $(seq "$2"); do edit "$1" Edit "$O/$3"; done; }
edit sess-dh Edit "$O/share/hooks.py"
edit sess-dh Write "$O/.claude/worktrees/feat-x/share/hooks.py"
edit sess-dh/subagents/agent-1 Edit "$O/share/hooks.py"
edit sess-w Edit "$O/share/hooks.py"
edit sess-p4 MultiEdit "$O/share/hooks.py"
edit sess-p4 Edit "$O/docs/handoffs/2026-10-01-hooks.md"
edits sess-b 3 bin/stall-tool
edit sess-c Edit "$O/bin/stall-tool"
edit sess-c Write "$O/bin/stall-tool"
edits sess-old 3 bin/old-tool
touch -t 202501010000 "$HOME/.claude/projects/p/sess-old.jsonl"
line sess-or '{"type":"user","message":{"role":"user","content":"hook.sh loses rows, fix it"}}'
line sess-or '{"type":"assistant","message":{"content":[{"type":"text","text":"Delegating share/hook.sh."}]}}'
line sess-or '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Agent","input":{"prompt":"In share/hook.sh, keep rows; hook.sh tests: hook.sh"}}]}}'
edit sess-ed Edit "$O/share/hook.sh"
for i in 1 2; do line sess-rd '{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"hook.sh hook.sh hook.sh"}]}}'; done
line sess-rd '{"type":"attachment","attachment":{"type":"file","content":"hook.sh hook.sh"}}'
edits sess-sp 5 share/core.sh
edits sess-g 1 share/core.sh
for s in sess-g sess-o1 sess-o2 sess-o3; do edits $s 4 bin/common; edits $s 4 bin/shared; done
printf 'sess-dh\n' >"$HOME/.cache/claude-worker-runs/r1/launcher"
printf 'sess-w\n' >"$HOME/.cache/claude-worker-runs/r1/worker-session"
batches() { NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-own" python3 -B "$ROOT/share/handoffs.py" --batches |
  jq -c '[.owner, .by, .doubt, .runner_up, .scores, (.handoffs | map(split("/") | last))]'; }
batches >"$WORK/own.batches"
assert grep -qxF '["Debt Hardening",["edits"],true,"Phase Four",{"Debt Hardening":0.8,"Phase Four":0.2},["2026-10-01-hooks.md"]]' "$WORK/own.batches"
assert grep -qxF '["Phase Four",["to"],false,null,{},["2026-10-02-to.md"]]' "$WORK/own.batches"
assert grep -qxF '["Gamma Chat",["ledger","to"],false,null,{},["2026-10-03-ledger.md","2026-10-07-plain-to.md"]]' "$WORK/own.batches"
assert grep -qxF '["Beta Chat",["edits"],true,"Gamma Chat",{"Beta Chat":0.6,"Gamma Chat":0.4},["2026-10-04-tool.md"]]' "$WORK/own.batches"
assert grep -qxF '["Orchestrator",["edits"],false,null,{},["2026-10-05-delegated.md"]]' "$WORK/own.batches"
assert grep -qxF '["Specialist",["edits"],true,"Generalist",{"Specialist":0.83,"Generalist":0.67},["2026-10-06-shared.md"]]' "$WORK/own.batches"
assert [ "$(wc -l <"$WORK/own.batches" | tr -d ' ')" = 6 ]
edits sess-b 2 bin/stall-tool
assert jqe 'select(.owner == "Beta Chat") | .doubt == false and .runner_up == null' <(NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-own" python3 -B "$ROOT/share/handoffs.py" --batches)
assert python3 -B - "$ROOT" "$O" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "share"))
import handoffs as h

repo = sys.argv[2]
alone = h.pick_owner(None, None, {"Solo": 1.0})
assert not alone["doubt"] and alone["runner_up"] is None, alone
items = [{"path": f"{repo}/docs/handoffs/{n}.md", "repo": repo, "at": None, "to": []} for n in ("one", "two")]
h.owner_picks = lambda handoffs, repos, chats: [(items[0], None, alone, {}),
                                                (items[1], "Ledger Chat", h.pick_owner(None, "Ledger Chat", {"Solo": 1.0}), {})]
[batch] = h.owner_batches(items, repos=[repo], chats=[{"name": "Solo", "session": "sess-solo"}], live=set())
assert batch["doubt"] and batch["runner_up"] == "Ledger Chat" and batch["scores"] == {"Solo": 2.0, "Ledger Chat": 0}, batch
PY
# A lone handoff naming a repository outside the night's, where the night lands nothing, still goes to its owner chat.
assert python3 -B - "$ROOT" "$O" "$WORK/foreign" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "share"))
import handoffs as h

repo, foreign = sys.argv[2], sys.argv[3]
brew = os.path.join(os.path.dirname(foreign), "opt", "homebrew")
os.makedirs(os.path.join(brew, ".git"))
lone = os.path.join(repo, "docs", "handoffs", "lone.md")
with open(lone, "w") as handle:
    handle.write(f"# Lone\n\nStatus: open\n\nTo: «Solo».\n\nFix {foreign}/.claude/worktrees/x/hooks/gate.sh and {repo}/bin/x"
                 f" under {brew}/bin/bash.\n")
assert h.outside_repos(lone, [repo]) == [foreign], "a git checkout not beside the night's repositories is no repository: %s" % (
    h.outside_repos(lone, [repo]),)
assert h.outside_repos(lone, [repo, foreign]) == []
os.environ["NIGHT_RUN_HELPER_REPOS"] = os.path.join(os.path.dirname(foreign), "lone-helpers")
open(os.environ["NIGHT_RUN_HELPER_REPOS"], "w").write(foreign + "\n")
assert h.outside_repos(lone, [repo]) == [], "a helper repository is the night's"
del os.environ["NIGHT_RUN_HELPER_REPOS"]
os.environ["NIGHT_RUN_SWEEP_REPOS"] = "/nonexistent"
real_helpers = h.repo_list(os.path.join(os.path.dirname(h.__file__), "night-helper-repos"))
assert real_helpers and not set(real_helpers) & set(h.helper_repos()), "a faked sweep list never reaches the real helpers"
item = {"path": lone, "repo": repo, "at": None, "to": ["Solo"]}
h.owner_picks = lambda handoffs, repos, chats: [(item, None, h.pick_owner("Solo", None, {}), {})]
chats = [{"name": "Solo", "session": "sess-solo"}]
assert [b["handoffs"] for b in h.owner_batches([item], repos=[repo], chats=chats, live=set())] == [[lone]]
assert h.owner_batches([item], repos=[repo, foreign], chats=chats, live=set()) == []
os.remove(lone)
PY
assert python3 -B - "$ROOT" "$WORK" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "share"))
import chat_names
import handoffs as h

assert h.addressees(["To: «Zeta Chat», «Alpha Chat»\n"]) == ["Zeta Chat", "Alpha Chat"]
assert h.addressed({"to": ["Zeta Chat", "Alpha Chat"], "path": "/nonexistent"}, {"Alpha Chat", "Zeta Chat"}) == "Zeta Chat"
assert h.addressees(["For context, «Phase Four» built this.\n", "It reads «Other».\n"]) == []
assert h.addressees(["for «Phase Four» to settle\n"]) == []
assert h.addressees(["For «Phase Four» (owner of x), rows y.\n"]) == ["Phase Four"]
assert h.addressees(["For the chat «Harness Doctor», next night.\n"]) == ["Harness Doctor"]
assert h.addressees(["**To:** «Phase Four»\n"]) == ["Phase Four"]
folder = os.path.join(sys.argv[2], "scan")
os.makedirs(folder, exist_ok=True)
said = os.path.join(folder, "said.jsonl")
with open(said, "w") as handle:
    handle.write('{"type":"user","message":{"content":"fix score.sh and hardcore.sh, then core.sh;\\ncore.sh in `share/core.sh`, «core.sh» and\u00a0core.sh—core.sh"}}\n')
assert chat_names.searcher()[0][0] == "rg", chat_names.searcher()
rows = h.scan([said, os.path.join(folder, "gone.jsonl")], {"core.sh"})
assert rows == {said: {"edits": {}, "mentions": {"core.sh": 6}}}, "a name after a multibyte boundary counts: %s" % rows
longer = os.path.join(folder, "longer.jsonl")
with open(longer, "w") as handle:
    handle.write('{"type":"user","message":{"content":"core.sh.log core.shx core.sh-carry `core.sh.bak`, then core.sh. core.sh"}}\n')
rows = h.scan([longer], {"core.sh"})
assert rows == {longer: {"edits": {}, "mentions": {"core.sh": 2}}}, "a longer token is no mention: %s" % rows
PY
export NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-own" NIGHT_RUN_OWNER_CHATS=9
new_night N5
night carry N5 >"$WORK/n5.out" 2>"$WORK/n5.err" || fail "evidence carry failed"
assert grep -qxF "Owner check first: this batch was matched to you by edits and mentions of its files, not by a To: line («Debt Hardening» 0.8, «Phase Four» 0.2). If these handoffs are not yours, SendMessage the sweep chat running night N5 naming the better owner, touch nothing and stop." "$NIGHTS/N5.owner-chat-debt-hardening.prompt.md"
assert_fails grep -qF 'Owner check' "$NIGHTS/N5.owner-chat-phase-four.prompt.md"
assert grep -qxF "   Not the night's, so it lands none of your work there: \`$WORK/foreign\`. Fix those on their own branch and landing, as your day work." "$NIGHTS/N5.owner-chat-phase-four.prompt.md"
assert_fails grep -qF "Not the night's" "$NIGHTS/N5.owner-chat-debt-hardening.prompt.md"
assert [ "$(grep -c '^owner-chat-' "$WORK/n5.out")" = 6 ]
fi

if suite_shard_owns 1 nc-leftovers-lands; then
# A main checkout behind origin/main shows as a leftovers row with the WIP in the way; a branch
# already in origin/main is landed though local main lags.
L="$WORK/lands"
git init -q --bare -b main "$WORK/lands.git" && git init -q -b main "$L"
printf 'f\n' >"$L/f.txt" && gt -C "$L" add f.txt && gt -C "$L" commit -qm init &&
  gt -C "$L" remote add origin "$WORK/lands.git" && gt -C "$L" push -q origin main
git clone -q "$WORK/lands.git" "$WORK/lands-other" 2>/dev/null
printf 'g\n' >"$WORK/lands-other/f.txt" && gt -C "$WORK/lands-other" commit -qam other && gt -C "$WORK/lands-other" push -q origin main
gt -C "$L" fetch -q origin && gt -C "$L" branch -q --no-track done origin/main
printf 'wip\n' >>"$L/f.txt"
printf '%s\n' "$L" >"$WORK/sweep-lands"
NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-lands" night leftovers >"$WORK/lands.out" || fail "leftovers with a lagging checkout"
assert grep -qxF "checkout lands: behind 1, WIP in the way: f.txt" "$WORK/lands.out"
assert grep -qF "lands done · no worktree · landed · " "$WORK/lands.out"
printf 'h\n' >"$L/h.txt" && gt -C "$L" add h.txt && gt -C "$L" commit -qm local
NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-lands" night leftovers >"$WORK/lands.out" || fail "leftovers with a diverged checkout"
assert grep -qxF "checkout lands: diverged, WIP in the way: f.txt" "$WORK/lands.out"
fi

if suite_shard_owns 4 nc-dup-trade-suites; then
# One handoff file name open in two repositories is two jobs, each carried once.
for name in dupa dupb; do
  git init -q "$WORK/$name" && mkdir -p "$WORK/$name/docs/handoffs"
  printf '# Same\n\nStatus: open\n\nNo owner.\n' >"$WORK/$name/docs/handoffs/2026-10-09-same.md"
  gt -C "$WORK/$name" add -A && gt -C "$WORK/$name" commit -qm init
  printf '%s\n' "$WORK/$name" >>"$WORK/sweep-dup"
done
export NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-dup"
new_night N6
night carry N6 >/dev/null 2>&1 || fail "carry of same-named handoffs failed"
assert jqe --arg a "$WORK/dupa/docs/handoffs/2026-10-09-same.md" --arg b "$WORK/dupb/docs/handoffs/2026-10-09-same.md" \
  '[.jobs[] | select(.kind == "handoff") | [.ref, .path, .state]]
   == [["handoff-2026-10-09-same", $a, "pending"], ["handoff-dupb-2026-10-09-same", $b, "pending"]]' "$NIGHTS/N6.json"
assert [ -d "$WORK/dupb/.claude/worktrees/night-N6-handoff-dupb-2026-10-09-same" ]
night carry N6 >"$WORK/n6b.out" 2>/dev/null || fail "a second carry of same-named handoffs failed"
assert [ "$(handoff_refs N6)" = '["handoff-2026-10-09-same","handoff-dupb-2026-10-09-same"]' ]

# A trade job start carried in (Egor answered, not yet carried out) gets its worktree in the handoff's repository
# and a brief with the trade and his answer, once.
jq --arg p "$WORK/dupb/docs/handoffs/2026-10-09-same.md" '.jobs += [{kind: "trade", ref: "trade-t1", state: "pending", reason: null,
  branch: "night/N6/trade-t1", review: null, commits: [], pushed: false, answer: {words: "merge it", done: ["keep"]},
  from: {night: "N5", ref: "t1", kind: "handoff", trade: "Cost: c. Loss: l. Recommendation: merge.", path: $p}}]' \
  "$NIGHTS/N6.json" >"$WORK/n6.json" && mv "$WORK/n6.json" "$NIGHTS/N6.json"
night carry N6 >"$WORK/n6c.out" 2>/dev/null || fail "carry of a trade job failed"
twt="$WORK/dupb/.claude/worktrees/night-N6-trade-t1"
assert [ "$(grep '^trade-' "$WORK/n6c.out")" = "trade-t1	$NIGHTS/N6.trade-t1.brief.md	$twt" ]
assert [ "$(git -C "$twt" symbolic-ref --short HEAD)" = night/N6/trade-t1 ]
assert grep -qxF 'The trade: Cost: c. Loss: l. Recommendation: merge.' "$NIGHTS/N6.trade-t1.brief.md"
assert grep -qxF 'His answer: merge it' "$NIGHTS/N6.trade-t1.brief.md"
assert grep -qF "Its handoff: \`$WORK/dupb/docs/handoffs/2026-10-09-same.md\`" "$NIGHTS/N6.trade-t1.brief.md"
night carry N6 >"$WORK/n6d.out" 2>/dev/null || fail "a second carry of a trade job failed"
assert_fails grep -q '^trade-' "$WORK/n6d.out"

# A suite already green in the press-time tree closes with no worker; a red one gets a Sonnet brief.
git init -q "$WORK/suites" && mkdir -p "$WORK/suites/tests"
printf '#!/usr/bin/env bash\n[ "$*" = test_ok.sh ]\n' >"$WORK/suites/tests/run-all"
chmod +x "$WORK/suites/tests/run-all"
touch "$WORK/suites/tests/test_ok.sh" "$WORK/suites/tests/test_red.sh"
gt -C "$WORK/suites" add -A && gt -C "$WORK/suites" commit -qm init
printf '%s\n' "$WORK/suites" >"$WORK/sweep-suites"
export NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-suites"
jq -n --arg r "$WORK/suites" '{id: "N7p", started_at: "2026-10-05T00:00:00Z", finished_at: "2026-10-05T03:00:00Z", jobs: [],
  suites: {repos: [{repo: $r, exit: 1, passed: 0, failed: ["test_ok.sh", "test_red.sh"], log: "/l/suites.log"}]}}' >"$NIGHTS/N7p.json"
jq -n '{id: "N7", started_at: "2026-10-06T00:00:00Z", finished_at: null, session: null, jobs: []}' >"$NIGHTS/N7.json"
night base N7 >/dev/null || fail "night base N7 failed"
night carry N7 >"$WORK/n7.out" 2>"$WORK/n7.err" || fail "carry of suite jobs failed"
assert jqe '[.jobs[] | [.ref, .state, .reason]] == [["suite-suites-test_ok", "nothing-to-do", "test_ok.sh green at press time"],
  ["suite-suites-test_red", "pending", null]]' "$NIGHTS/N7.json"
assert grep -qxF 'night-run: test_ok.sh is green at press time: suite-suites-test_ok nothing-to-do' "$WORK/n7.err"
assert [ "$(cut -f1 "$WORK/n7.out")" = suite-suites-test_red ]
assert [ "$(sed -n 2p "$NIGHTS/N7.suite-suites-test_red.brief.md")" = 'MODEL: sonnet' ]
assert grep -qF 'end with `ESCALATE: <reason>`' "$NIGHTS/N7.suite-suites-test_red.brief.md"
assert [ ! -e "$NIGHTS/N7.suite-suites-test_ok.brief.md" ]
fi

printf 'PASS: test_night_carry.sh (%s asserts)\n' "$asserts"
