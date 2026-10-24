# Leftovers (direction 8)

What a night leaves for the next one: open handoffs (`docs/handoffs/*.md` of the sweep repositories, read by
`share/handoffs.py`, carried as night `handoff` jobs or `owner-chat` batches) and unlanded branches (`bin/night-run
leftovers`, night `leftover` jobs). Egor (2026-10-19) reads them as one thing (Decisions).

## Metric

Leftover events per night: a handoff doc or a branch a night started with and finished with (it outlived the
night), plus returns (a settled handoff reopened, a night's branch adopted again as a leftover), by the finishing
night's local day (UTC+3), 7 days against the 7 before. Target 0: nothing outlives a night, nothing returns.
- Health, not activity: writing more handoffs or running more jobs raises it only when something is left. Per night,
  since only a night that ran can be outlived (none ran 10-15…19).
- Out, on their own lines: a trade waiting for Egor (`Status: trade`, Cost/Loss/Recommendation) and a held branch
  («сделай холд», `nights/holds/`) are his to move.
- Watched: open handoffs standing at a window's end and the oldest; days from `Status: open` to the first other
  Status, for docs settled in the window.

### Baseline (computed 2026-10-20; the last night is 20261014T013750Z-8004)

| | 10-06…12 (6 nights) | 10-13…19 (2 nights) |
|---|---:|---:|
| handoff doc-nights outlived | 6 (5 docs) | 1 |
| trade doc-nights (own line) | 4 (4 docs) | 0 |
| branches outlived, still unlanded at the next night's start | 1 | 0 |
| returns: handoff reopened | 6 | 0 |
| returns: night branch adopted again (one is the branch above) | 2 | 0 |
| **total, per night** | **15, 2.5** | **1, 0.5** |
| watched: open at the window's end, oldest | 4, 5.1 d | 1, 5.1 d |
| watched: days open → settled, median / p90 / max (docs) | 0.8 / 1.8 / 4.2 (40) | 0.8 / 1.2 / 3.9 (14) |
| recorded under a night's `leftovers` at finish (own line) | 20 | 6 |

- Doc-nights, Status open or trade at the night's `started_at` and `finished_at` on main's first parent:
  ```
  for n in ~/.cache/doctors/nights/2026*.json; do jq -e .finished_at "$n" >/dev/null || continue
    s=$(jq -r .started_at "$n") f=$(jq -r .finished_at "$n")
    for r in $(cat ~/.claude/sweep-repos); do a=$(git -C $r rev-list -1 --first-parent --before="$s" main)
      b=$(git -C $r rev-list -1 --first-parent --before="$f" main)
      for p in $(git -C $r ls-tree --name-only $b docs/handoffs/ 2>/dev/null); do
        st() { git -C $r show $1:$p 2>/dev/null | head -20 | grep -m1 -iE '^\**Status:?\**' |
          sed -E 's/^\**[Ss]tatus:?\**[[:space:]]*//' | cut -c1-4 | tr A-Z a-z; }
        case "$(st $a)/$(st $b)" in open/open|open/trad|trad/open|trad/trad) echo "$f $(st $b) ${p##*/}";; esac
      done; done; done
  ```
  `trad` at finish is a trade doc-night; `usage-gate-hooks` counts open on 10-06 and trade on 10-07.
- Open at a window's end, and the oldest: 00:00 UTC+3 the morning after the window (2026-10-13, 2026-10-20).
  A doc counts when the first 20 lines of `main` just before that instant match `^\**Status:?\**` and the value
  starts with `open`. Age is days from the committer time of the first-parent commit that set that open, one
  decimal (tokenmap open 10-07 21:19:06, logo-bench-own-tools 10-14 21:14:26, both 5.1 d).
- Days open → settled: the same history. A spell runs from a commit that sets `Status:` to open until the next
  that sets a status that does not start with open; the close falls in `[window start, next window start)` local.
  Median is the mean of the two middle values when the count is even; p90 is linear at `0.9*(n-1)`; max; one decimal.
- Reopens, a Status line turning back to open (window bounds local):
  ```
  for r in $(cat ~/.claude/sweep-repos); do git -C $r log --first-parent main -p --since=2026-10-06 \
    --until=2026-10-13 --format='@%h %cd' --date=format:%m-%d -- docs/handoffs/ |
    awk -v r=${r##*/} -v o='status:?[*]*[ ]*open' '/^@[0-9a-f]+ /{c=$0} /^diff --git/{f=$NF; old=""}
    /^-\**Status:?\**/{old=tolower($0)} /^\+\**Status:?\**/{s=tolower($0); if (s ~ o && old != "" && old !~ o) print r, c, f; old=""}'; done
  ```
- Branches: `jq -r 'select(.finished_at) | .finished_at as $f | .leftovers[]? | [$f, .repo, .branch, .why] | @tsv'
  ~/.cache/doctors/nights/*.json`, each checked against `git -C <repo> reflog show main --date=iso | grep 'merge
  <branch>:'` and its night job's state. Re-adoptions: `jq -r 'select(.finished_at) | .finished_at as $f |
  .jobs[]? | select(.kind == "leftover" and (.ref | startswith("leftover-night-"))) | "\($f) \(.ref)"'
  ~/.cache/doctors/nights/*.json`.
- Of the 20 + 6 branches recorded at finish 25 were not left (C6): 7777's 11 merged or settled jobs' branches, 7b98's
  2 superseded tokenmap ones, 3131's merged worktree with 1 dirty file, 11 chat branches fast-forwarded 6–50 min
  after the finish. The one left, `night/…-7777/leftover-fix-browser-local-probe`, 7b98 adopted again: a return.
- Spend, tokenmap `requests` cost, nights finished 10-06…14: lone handoff jobs (cwd `night-<id>-handoff-*`)
  $68.54 for 24, owner-chat batches (owner session within the job's events ±2 min) $49.53 for 28 docs, $1.77 a
  doc. Job spans are whole minutes, truncated: per job, floor of (last `.events[].at` with that `.job` minus the
  first) / 60, then summed. 10-06…12 handoff 21 jobs 5,336 min (3,580 of it three trades paused for
  Egor), leftover 17 jobs 3,292, owner-chat 4 jobs 317; 10-13…19 handoff 4 jobs 1,009, owner-chat 3 jobs 516.

## Sources

- The night records `~/.cache/doctors/nights/<id>.json`: `jobs` (kind, state, reason, `handoffs`, `adopted`),
  `events`, `leftovers` and `held` written by `finish`; 15 finished nights 09-30…10-14
  (`…-6468`, a jobless stale start, not counted); none since.
- Git history of `docs/handoffs/` on main of llm-legs (39 docs now), claude-setup (7), review-bench (25); hammerspoon
  has none, nor do the helper repositories (`share/night-helper-repos`).
- `share/handoffs.py` (`open_handoffs`, `owner_batches`, `--status`, `--night` for the Doctors menu's
  `handoffRows`), `bin/night-run` (`carry_list`, `carry_owner_chats`, `branch_row`, `job set`).
- No ledger is the handoff list.

## Recurring classes

Ranked by events in 10-06…19, each with the job minutes it cost.

| class | 10-06…12 | 10-13…19 | cost |
|---|---:|---:|---|
| C1. a settled handoff reopens for a new item | 6 returns, 5 docs; 1 doc-night | 0 | hook-floors carried by 3 nights, tokenmap 4 |
| C2. a job closes merged, its doc still open | 3 doc-nights | 1 | re-carries 375 min, part of an 88-min batch |
| C3. a trade waits for Egor's word | 4 doc-nights | 0 | spans 958, 1,311, 1,311 min paused |
| C4. one plain handoff to a live chat: no job, no batch | 2 doc-nights | 0 | 2 nights skipped; then a 94-min batch |
| C5. a night's branch is adopted again | 2 returns | 0 | 1,335 + 18 and 1,325 + 8 min spans |
| C6. finish records landed or landing work as leftovers | 25 of 26 recorded | | none; the report and menu read them |
| C7. a doc with no readable Status is never carried | 35 docs | | unknown |
| C8. a handoff to a live chat waits for a night | 0 | 0 | both open docs (10-23); ≈ 5 min/day |

Why they come back:
- C1: all six landed while a night ran, its fixers or audits appending an item to a settled doc of their topic
  (hook-floors ×2, load-unseen-census, image-night-triage, speed-floor-measures, tokenmap-waste-detectors), though `docs/doctor-fix.md` names a new
  `docs/handoffs/<date>-<topic>.md`. None from fixers since 10-10 (154 fixer jobs); two by day doctor chats on
  10-20 (Open).
- C2: `job set` never read a closing handoff job's doc; settled by job-settles-its-doc (Done). hook-floors' f253
  doc-night is C1's.
- C3: answered trades stayed `trade for Egor` all day (7777); since 10-08 an answer settles one (`trade_settle`).
- C4: a lone handoff to a live chat got no job and no batch; settled by live-owner-single (Done).
- C5: 7777 closed both jobs merged while their branches could not land (a live chat's uncommitted work; superseded
  by fix/browser-enrollment); 7b98 adopted them. None since.
- C6: `finish` snapshots once: a night branch landed by an integration commit or merged-closed reads unlanded
  (superseded, e35094e2, covers only nothing-to-do and settled), and chats landing at that minute read as leftovers.
- C7: 31 docs written 09-09…09-25 (the adding commit's author date) and `opencode-roster-pins` (10-01) have no
  `^\**Status:?\**` in the first 20 lines; 3 read free text: `harness-time-budget` "in progress" (landed 10-05),
  review-bench `debt-redesign-anchors-and-touches` "DECIDED … not implemented", `gemini-leg-waste-and-fixes`
  "UNCOMMITTED". Doctor chats write `Status: open` (doctors-contract §5); the arbostar-logo chat, which no rule
  reaches, wrote 2 more: oversharp (10-21, integrated next day) and `video-glitch` (10-22), still "nothing built"
  though `bin/video-glitch` landed 1.7 h later (0c04b07c).

## Goals

C1, C6, C7: Open.

### goal live-owner-day: a handoff to a live chat reaches it the day it is written

Class C8: a doc to a live chat waits for a full night's `message` batch; nothing sends it in the day, and a pilot
night carries none. Both open docs: `2026-10-14-logo-bench-own-tools` (To «Vector Magic macOS ARM
migration», by a doctor chat 10-14 21:14), `2026-10-20-image-probe-arbostar-logo` (To «Логотип CRM для
арбористов», a day fixer's verdict committed 10-20 15:07). `share/handoffs.py` reads both owners `live` (both spoke
10-23); no SendMessage of 71 after 10-14 21:00 (deduped by tool_use id) names either, and neither owner read its
doc.
- Change, no code, in `docs/doctors-contract.md` §5 and `docs/fix-orchestrator.md`: the chat that writes a
  handoff, or closes a fixer's `handoff` verdict, sends its To chat, when `handoffs.py` reads it `live`, the doc's
  path by SendMessage the same turn, as the night sweep does a `message` batch (claude-setup night-sweep SKILL). Not live,
  or a name ListAgents lists twice: the night's. Workers never send.
- First step: ListAgents in a main chat lists each owner once by that name, else stop (at risk: transcripts' send
  targets are sockets, `local_` ids or `arbostar-logo-80`-style names, almost never titles); then send both.
- Proof, in a day: each doc leaves `open` (settled or `trade`) within 24 h of its send, 0 of them at the next
  night's start (2 a pilot night now). Then 14 days by the Metric's commands: docs with a live To chat open at a
  night's start 0; watched, days open → settled with a To chat, median 0.8 d (8 closed spells 10-09…22; by Status-line commits 5 spells, 0.97 d: method unconfirmed).
- Gain: about 5 min/day (2.7–7.8) of writing the two levers remove in the owners' projects (tool mining `write_min`,
  `logo-verdict` + `image-probe`, 24-h windows 10-19, 10-20, 10-22 and 10-23; the 7-day mean 9.4 rides on 10-17's
  13.4). Sure of the diagnosis, not the gain: an owner may decline.
- Must not get worse: night carry for owners not live (test_night_carry, unrechecked); the owner's spend a settled
  doc ≤ the night batches' $1.77 (Metric, unconfirmed); no relay by Egor (a send held for his approval counts as one).

## How the block runs at night

- It brings back README's section 8 rows, Handoffs and owner chats, and Leftovers, which a pilot night leaves out:
  `PILOT_RULES` "no … leftovers", `cmd_carry` skips `carry_owner_chats` on `.pilot`, `carry_list` prints `pilot_goal`.
- Pilot change: once the pilot reaches `leftovers` (every earlier direction's goals gone), carry adds the owner-
  chat batches and handoff lines after this direction's goal, and the prep runs `night-run leftovers` and `job add
  leftover` per row; `start` records `night-run leftovers --json`, so "still there at the next start" is read from
  records, not reflogs.
- The first night is judged at its finish and the next start: doc-nights outlived 0 (trades and holds apart),
  returns 0, branches recorded at finish still unlanded at the next start 0; handoff, owner-chat and leftover job
  minutes per doc settled or branch landed, against 10-06…12's spans; net lines of both goals shown.

## Done

- live-owner-single (C4, 2bd260a4): `owner_batches` keeps a live owner whatever the batch size; test_night_carry's
  lone handoff to a live chat: no job, no batch (red) → one `message` batch. Read on block 8's first full night:
  doc-nights to a live chat 2 → 0, reverted unless 0.
- job-settles-its-doc (C2, 6455e151): `job set` refuses merged or nothing-to-do on a handoff or owner-chat job whose
  doc reads open. Replay: the 4 C2 closes refused, the other 50 accepted; test_night_run hd red → green. Read on
  block 8's first full night and 7 days after: doc-nights after a closed job 4 → 0, reverted unless 0.

## Decisions

- 2026-10-19: he no longer sees handoffs anywhere («не вижу, где handoff»); he took leftover branches for Breakages'
  general cleanup, then: leftovers are «просто handoff-ы». Block 8 holds both (README, 10-20). («Updater doctor»)
- 2026-10-15: handoffs already worked keep coming back to be worked again: «у нас сломана механика». («Updater
  doctor»)
- 2026-10-14: own work lands in-session, never left for the night to land (memory finish-now-not-night). 10-13: the
  Handoffs view, done / queued / To: Egor as rows, not urgent but to be done (built d79fae63). («Updater doctor»)
- 2026-10-08: «нет, оставь ночи»: a night's branches are the night's to settle, never another chat's to delete
  («Token spending tracking and optimization»). An answered trade closes itself, by the night («Updater doctor»).
- 2026-10-07: only his hold («сделай холд») or the owner's freeze (a locked worktree) protects a branch; no activity
  window, and a process inside protects nothing. («Night run cleanup», memory same-day-apply)
- 2026-10-07: a trade is only a strategic change or a serious downside against the gain; an obvious win blocked by
  scope is done; once he answers, the answering chat sets `Status: settled` the same turn. («Night run cleanup»,
  «Updater doctor», memories asks-only-real-trades, research-before-asking)
- 2026-10-06: a hold by a long-finished chat is a bug: land was meant for chats to agree and became one more
  blocker; land was cut. Open asks live in the Doctors menu's red «need you», never re-asked. («Updater doctor»)
- 2026-10-05: the day's work is in main before the night, with no handover step; the owner chat is the chat that
  built the code, found by chat-find and transcript evidence, not a ledger area. («Updater doctor», «make land for
  multiple workers in one repository», memories same-day-apply, handoffs-go-to-owner-chats)
- 2026-10-04: handoffs addressed to sleeping chats are lost problems and must be worked; the night gives each owner
  chat its handoffs as one batch and supervises; trivial or ownerless ones stay night jobs; never a chat per
  handoff, not 25 open chats. («make land for multiple workers in one repository», memory handoffs-go-to-owner-chats)
- 2026-10-02: handoffs are their owners', never his questions; he gets only what research cannot settle, as a
  trade. («Updater doctor», memory research-before-asking)
- 2026-10-01: in the four sweep repositories an extra branch or worktree should not exist in almost any case; the one
  exception is work going on right now. Every unlanded branch is carried to main. («Updater doctor», repeated 10-08
  in «Token spending tracking and optimization»)

## Open

- C1 reopens: none by fixers since 10-10; two by day doctor chats on 10-20 followed their doctor rows (Breakages'
  repeats): ax-poll settled 10-14 on its lever landing, not its 92 CPU-min/day; commit-report a new cause. If
  fixers return (block 7): `doctor-fix close` takes a `handoff` verdict only on a doc new in its run, rewriting the
  run's addition into a new dated doc (Decision 2026-09-29, `breakages.md`).
- C6: the finish snapshot moves no number here (the metric reads the next start); its fix is the report's reading.
- C7: 37 docs no carry reads, 5 saying unfinished (with `relay-free-worker-rows` "open until the done-when week
  passes", past 10-16). One triage job on block 8's first night sets each Status with evidence (one worker run).
- Egor's 10-19 "no handoffs anywhere": handoff rows show only inside the last night's block
  (`hammerspoon/doctors.lua` `handoffRows`), 10-14's; the live menu not checked (read-only `menuItems()` not run).
- Checked: a night worker inside a night branch reads `live` (`branch_row`, `cwd_held`), 10-01's exception, not
  against 10-07. `~/.cache/chat-handoffs/` (3 docs, other projects') goes between chats by Egor's hand: out of scope.
- Dropped 10-23: owner-chat batches ($1.77 a doc vs $2.86 lone) lose nothing; 5 landed doctor-fix
  worktrees of 10-20 await a finish's prune at no cost since the commit-report debt probe went (10-21); C7 at
  source (any Status not a closed word reads open) would carry 3 done docs of 5; branches: 1 leftover job since
  10-08; `night-run leftovers` 10-23: only live work.
