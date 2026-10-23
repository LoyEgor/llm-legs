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
  decimal: tokenmap open `2026-10-07T21:19:06+03:00` (5.1 d) and `2026-10-14-logo-bench-own-tools` open
  `2026-10-14T21:14:26+03:00` (5.1 d).
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
- Of the 20 + 6 branches recorded at finish, 25 were not left: 7777's 11 merged or settled jobs' branches (their work
  landed in fea660fb before the finish; whether the refs stood at 7b98's start is unconfirmed), 7b98's 2 superseded
  tokenmap branches, 3131's merged job worktree with 1 dirty file (unconfirmed at 8004's start), and 11 chat branches
  their chats fast-forwarded 6–50 min after the finish (reflog). The one left:
  `night/…-7777/leftover-fix-browser-local-probe`, adopted again by 7b98, so also a return.
- Spend: token-map units per job are unconfirmed (worker-run dirs prune at 7 days; owner chats work in their own
  transcripts; `night-run report` splits no spend by job kind). Job spans are whole minutes, truncated: for each
  job, floor of (last `.events[].at` with that `.job` minus the first) / 60, then summed.
  10-06…12 handoff 21 jobs 5,336 min (3,580 of it three trades paused for Egor), leftover 17 jobs 3,292,
  owner-chat 4 jobs 317; 10-13…19 handoff 4 jobs 1,009, owner-chat 3 jobs 516.

## Sources

- The night records `~/.cache/doctors/nights/<id>.json`: `jobs` (kind, state, reason, `handoffs`, `adopted`),
  `events`, `leftovers` and `held` written by `finish`; 15 finished nights 09-30…10-14 (16 files; `20261014T010328Z-6468`, a jobless stale start closed 10-20, not counted).
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

Why they come back:
- C1: all six landed while a night ran, its fixers or audits appending an item to a settled doc of their topic
  (aa48e898, 701f21d9 hook-floors; b3b2c3db load-unseen-census; bafd0768 image-night-triage; 51ee5aa5
  speed-floor-measures; 9bac8bbb tokenmap-waste-detectors), though `docs/doctor-fix.md` names a new
  `docs/handoffs/<date>-<topic>.md`. None since 10-10 over three nights with 154 fixer jobs; no fix found that
  stopped it.
- C2: `night-run job set` checked reason= for `left` and `blocked-on-egor` but never a closing handoff job's doc
  (Done); the brief asks the worker to rewrite Status and nothing reads it (only `trade_settle` reads Status). usage-gate-hooks'
  fix lay outside the sweep repositories then; one-shot-instructions was settled next night as "kept as is", no code;
  tokenmap-waste-detectors' owner chat settled it on 10-14 after two merged jobs. hook-floors' f253 doc-night is C1's:
  its job settled the doc at 07:29 (6298ac54), pushed 07:31; fixer aa48e898 reopened it at 07:39.
- C3: answered trades stayed `trade for Egor` all day (7777). Since 10-08 an answer settles the trade
  (`trade_settle`, Decision below), and a trade is only a strategic change or a serious downside (10-07).
- C4: `carry_list` drops a handoff addressed to a live chat as that chat's, and `owner_batches` kept an owner only
  with 2+ handoffs, a decision section or an outside repository (Done). image-night-triage (To: «LLM Doctor меню
  refactoring») waited out 817e and 4c4e. The standing 2026-10-14-logo-bench-own-tools names an outside repository,
  so it batches (`handoffs.py --batches` on 10-20: `live`, via message).
- C5: 7777 closed both jobs merged while their branches could not land (elevenlabs-one-pool: a live chat's
  uncommitted work in the main checkout; browser-local-probe: superseded by fix/browser-enrollment); 7b98 adopted them.
- C6: `finish` snapshots once. A night branch landed by an integration commit or closed reads unlanded (the
  superseded rule, e35094e2 10-08, covers nothing-to-do and settled jobs, not merged), and chats landing their
  branches at that minute read as leftovers.
- C7: 31 docs written 09-09…09-25 (author date of the adding commit; no `^\**Status:?\**` in the first 20 lines)
  and `opencode-roster-pins` (written 10-01) have no Status line; 3 read free text:
  `harness-time-budget` "in progress" (its branch landed 10-05), review-bench `debt-redesign-anchors-and-touches`
  "DECIDED … not implemented" and `gemini-leg-waste-and-fixes` "fixes … UNCOMMITTED". Every doc since 10-06 opens
  with `Status: open`: the class stopped at its source.

## Goals

No open goal; C1, C6 and C7 are under Open.

## How the block runs at night

- It brings back README's section 8 rows, Handoffs and owner chats, and Leftovers. A pilot night leaves both out now:
  `PILOT_RULES` lists "no … leftovers", `cmd_carry` skips `carry_owner_chats` on `.pilot`, `carry_list` prints only
  `pilot_goal`.
- Pilot change: once the pilot reaches `leftovers` (every earlier
  direction's goals gone), carry adds the owner-chat batches and handoff lines after this direction's goal, and the
  prep runs `night-run leftovers` and `job add leftover` per row; `start` records `night-run leftovers --json` in the
  night file, so "still there at the next start" is read from records, not reflogs.
- The first night is judged at its finish and the next start: doc-nights outlived 0 (trades and holds apart),
  returns 0, branches recorded at finish still unlanded at the next start 0; handoff, owner-chat and leftover job
  minutes per doc settled or branch landed, against 10-06…12's spans; net lines of both goals shown.

## Done

- live-owner-single (C4, 2bd260a4): `owner_batches` keeps a live owner whatever the batch size. test_night_carry's
  lone handoff to a live chat: no job, no batch (red) → one `message` batch. Read on block 8's first full night: doc-
  nights of handoffs to a live chat 2 → 0, reverted unless 0.
- job-settles-its-doc (C2, 6455e151): `job set` refuses merged or nothing-to-do on a handoff or owner-chat job whose
  doc reads open, naming it. Replay at each close's last state event: the 4 C2 closes refused, the other 50 doc
  closes accepted; test_night_run hd case red → green. Read on block 8's first full night and the 7 days after:
  doc-nights after a closed job 4 → 0 (`left` jobs apart, all doc-nights a night ≤ 0.5), reverted unless 0.

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

- C1 reopens: none since 10-10 and nothing to move, so no goal. If they return when Doctor fixes come back (block
  7): `doctor-fix close` takes a `handoff` verdict only on a doc new in its run, rewriting the run's addition into a
  new dated doc rather than denying (Decision 2026-09-29, `breakages.md`).
- C6: the finish snapshot moves no number of this block (the metric reads the next start). Shown in the report, it
  names 25 leftovers that were not; a fix is the report's reading, not a goal here.
- C7: 35 docs no carry reads, 3 saying unfinished. Instances, not a class: one triage job on block 8's first night
  sets each Status with evidence (cost: one worker run); unconfirmed how many still hold work.
- Egor's 10-19 "no handoffs anywhere": `night-run latest --menu` printed 9 done and 1 queued handoff rows on 10-20,
  shown only inside the last night's block (`hammerspoon/doctors.lua` `handoffRows`); not checked in the live menu
  (read-only `menuItems()` not run). With no night since 10-14, that block is six days old.
- Checked: a night worker inside a night branch still reads `live` (`branch_row`, `cwd_held`); that is 10-01's
  exception (work going on now), not against 10-07. Handoffs outside the sweep repositories (`~/.cache/chat-handoffs/`,
  3 docs: `2026-10-13-system-doctor-ux`, `2026-10-19-md-compact-round-2`, `2026-10-20-worker-run-run`; other projects')
  go between chats by Egor's hand: out of scope.
- Spend per handoff, owner-chat and leftover job in token-map units: unconfirmed until the night records it per job.
