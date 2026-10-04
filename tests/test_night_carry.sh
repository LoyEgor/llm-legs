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

printf 'PASS: test_night_carry.sh (%s asserts)\n' "$asserts"
