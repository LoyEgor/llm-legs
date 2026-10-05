#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
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
H="$WORK/repo/docs/handoffs"
printf '# A\n\nStatus: open\n\nFor the chat «Gone Chat». Needs a change in other too.\n' >"$H/2026-09-28-old.md"
printf '# B\n\nStatus: open (half done)\n\nTo: «Live Chat».\n\nMentions «Gone Chat» later.\n' >"$H/2026-10-03-live.md"
printf '# C\n\nStatus: settled 20261003T0000Z-0001: fixed\n' >"$H/2026-09-29-settled.md"
printf '{"pid": %s, "sessionId": "live-1"}\n' "$$" >"$HOME/.claude/sessions/1.json"
printf '{"type": "custom-title", "customTitle": "Live Chat", "sessionId": "live-1"}\n' >"$HOME/.claude/projects/p/live-1.jsonl"
for name in repo other; do git -C "$WORK/$name" add -A && git -C "$WORK/$name" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; done

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
assert grep -qxF "ADD-DIR: $WORK/other/.claude/worktrees/night-N1-handoff-2026-09-28-old" "$brief"
assert grep -qF "Settle the handoff \`$WORK/repo/docs/handoffs/2026-09-28-old.md\`" "$brief"
assert grep -qF 'Cost:`, `Loss:` and `Recommendation:`' "$brief"
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
printf '{"kind":"suites","pid":%s,"started_at":%s,"suites":{"test_a.sh":{"rc":0},"test_b.sh":{"rc":1}}}\n' "$$" "$(date +%s)" >>"$RUN_SUITES_JOURNAL"
printf '{"kind":"suites","pid":%s,"started_at":1,"suites":{"test_c.sh":{"rc":0},"test_d.sh":{"rc":0}}}\n' "$$" >>"$RUN_SUITES_JOURNAL"
printf '%s\n' "test_a.sh  PASS        1  ok" "test_x.sh  FAIL 1      2  boom" "" "2 suites · 9 PASS · 1 FAIL · 3s wall (3s serial)"
exit 1
RUNALL
chmod +x "$WORK/repo/tests/run-all"
night suites N1 --wait || fail "suites failed"
assert jqe --arg r "$WORK/repo" --arg l "$NIGHTS/N1.suites.repo.log" \
  '.suites.finished_at != null and .suites.repos == [{repo: $r, exit: 1, log: $l, passed: 1, failed: ["test_b.sh"]}]' "$NIGHTS/N1.json"
assert grep -qxF 'suites · repo · 1 PASS · 1 FAIL: test_b.sh' <(night report N1 2>/dev/null)
rm "$NIGHTS/N1.suites.repo.log"
night suites N1 | grep -q '^night N1: full suites run in the background, pid [0-9]*$' || fail "suites did not detach"
for i in $(seq 1 100); do [ -s "$NIGHTS/N1.suites.repo.log" ] && jqe '.suites.finished_at != null' "$NIGHTS/N1.json" && break; sleep 0.1; done
assert jqe '.suites.repos[0].failed == ["test_b.sh"]' "$NIGHTS/N1.json"

mkdir -p "$WORK/bin" "$WORK/repo/share" "$WORK/alpha-cwd"
export PATH="$WORK/bin:$PATH" NIGHT_RUN_OPENER="$WORK/bin/opener" NIGHT_RUN_WORKER_PICK="$WORK/bin/pick" NIGHT_RUN_OWNER_LOAD_K=1000
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
handoff_refs() { jq -c '[.jobs[] | select(.kind == "handoff") | .ref]' "$NIGHTS/$1.json"; }
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
assert grep -qxF '«Alpha Doctor» open · 2 handoffs' <(night report N2 2>/dev/null | grep -o '«Alpha Doctor».*handoffs')
night carry N2 >"$WORK/n2b.out" 2>/dev/null || fail "a second owner carry failed"
assert [ ! -s "$WORK/n2b.out" ]
assert [ "$(wc -l <"$WORK/opened" | tr -d ' ')" = 1 ]

new_night N3
NIGHT_RUN_OWNER_CHATS=1 night carry N3 >"$WORK/n3.out" 2>"$WORK/n3.err" || fail "capped carry failed"
assert [ "$(grep -c '^owner-chat-' "$WORK/n3.out")" = 1 ]
assert grep -qxF 'night-run: owner chat «Beta Chat» deferred (1 owner chats at work): its handoffs are night jobs' "$WORK/n3.err"
assert [ "$(handoff_refs N3)" = '["handoff-2026-09-25-b1","handoff-2026-09-26-c1","handoff-2026-09-27-d1","handoff-2026-09-28-d2","handoff-2026-09-28-old"]' ]

new_night N4
NIGHT_RUN_OWNER_LOAD_K=0 night carry N4 >"$WORK/n4.out" 2>"$WORK/n4.err" || fail "loaded carry failed"
assert [ "$(grep -c '^owner-chat-' "$WORK/n4.out")" = 0 ]
assert grep -qF 'night-run: owner chat «Alpha Doctor» deferred (load ' "$WORK/n4.err"
assert [ "$(handoff_refs N4)" = '["handoff-2026-09-20-a1","handoff-2026-09-25-b1","handoff-2026-09-26-c1","handoff-2026-09-27-d1","handoff-2026-09-28-d2","handoff-2026-09-28-old","handoff-2026-10-01-a2"]' ]

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
printf "# To\n\nStatus: open\n\nTo: «Phase Four».\n\nFix share/hooks.py.$decide" >"$O/docs/handoffs/2026-10-02-to.md"
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
assert grep -qxF '["Orchestrator",["edits"],true,"Editor",{"Orchestrator":0.83,"Editor":0.17},["2026-10-05-delegated.md"]]' "$WORK/own.batches"
assert grep -qxF '["Specialist",["edits"],true,"Generalist",{"Specialist":0.83,"Generalist":0.67},["2026-10-06-shared.md"]]' "$WORK/own.batches"
assert [ "$(wc -l <"$WORK/own.batches" | tr -d ' ')" = 6 ]
edits sess-b 2 bin/stall-tool
assert jqe 'select(.owner == "Beta Chat") | .doubt == true' <(NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-own" python3 -B "$ROOT/share/handoffs.py" --batches)
export NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-own" NIGHT_RUN_OWNER_CHATS=9
new_night N5
night carry N5 >"$WORK/n5.out" 2>"$WORK/n5.err" || fail "evidence carry failed"
assert grep -qxF "Owner check first: this batch was matched to you by edits and mentions of its files, not by a To: line («Debt Hardening» 0.8, «Phase Four» 0.2). If these handoffs are not yours, SendMessage the sweep chat running night N5 naming the better owner, touch nothing and stop." "$NIGHTS/N5.owner-chat-debt-hardening.prompt.md"
assert_fails grep -qF 'Owner check' "$NIGHTS/N5.owner-chat-phase-four.prompt.md"
assert [ "$(grep -c '^owner-chat-' "$WORK/n5.out")" = 6 ]

printf 'PASS: test_night_carry.sh (%s asserts)\n' "$asserts"
