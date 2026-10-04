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

export HOME="$WORK/home" DOCTORS_DIR="$WORK/doctors" NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" CHAT_NAMES_CACHE="$WORK/names.json"
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

printf '#!/usr/bin/env bash\nprintf "%%s\\n" "test_a.sh  PASS        1  ok" "test_b.sh  FAIL 1      2  boom" "" "2 suites · 1 PASS · 1 FAIL · 3s wall (3s serial)"\nexit 1\n' \
  >"$WORK/repo/tests/run-all"
chmod +x "$WORK/repo/tests/run-all"
night suites N1 --wait || fail "suites failed"
assert jqe --arg r "$WORK/repo" --arg l "$NIGHTS/N1.suites.repo.log" \
  '.suites.finished_at != null and .suites.repos == [{repo: $r, exit: 1, log: $l, passed: 1, failed: ["test_b.sh"]}]' "$NIGHTS/N1.json"
assert grep -qxF 'suites · repo · 1 PASS · 1 FAIL: test_b.sh' <(night report N1 2>/dev/null)
rm "$NIGHTS/N1.suites.repo.log"
night suites N1 | grep -q '^night N1: full suites run in the background, pid [0-9]*$' || fail "suites did not detach"
for i in $(seq 1 100); do [ -s "$NIGHTS/N1.suites.repo.log" ] && jqe '.suites.finished_at != null' "$NIGHTS/N1.json" && break; sleep 0.1; done
assert jqe '.suites.repos[0].failed == ["test_b.sh"]' "$NIGHTS/N1.json"

printf 'PASS: test_night_carry.sh (%s asserts)\n' "$asserts"
