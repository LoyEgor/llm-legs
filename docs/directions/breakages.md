# Breakages (direction 1)

Whatever breaks and has to be reacted to: the harness's gates, hooks, worker-run, the night and the doctors
themselves; the legs (image, video, workers, reviewers); vendor CLI updates; what the nightly transcript read
finds; every row fixed more than once.

## Metric

New distinct problems per 100 units of work, 7 days against the 7 before.
- Source: the doctor snapshots `bin/night-run` writes at every night's start and close, pilot or not
  (`~/.cache/doctors/nights/<id>.json`, `doctor_problems_before`/`_after`: id → state; Harness, LLM, Updater). Not
  ledger rows: only a fixer files one (`docs/doctor-fix.md`) and a pilot night launches none.
- A new problem: an id first shown `new` (no ledger row yet), on its snapshot's local day, counted once.
- The sum keeps the rules the doctors had on 10-02 (`git log -S` of the rule's name in its doctor); later rules go
  on their own line. Out of it: log_audit (classes, below), test_*, suites_at_once, the audits, Speed's rules
  (floor, hook_*, statusline, menu_build, collector, wait_*, worker_orphans, load, opportunity, regression),
  time_floor, tool_idea, growth-* (installs), store_size, debt-*, ledger faults, Updater `event-waiting` (per event).
- Units: `strata.chat.units + strata.workers.units` of `~/.cache/harness-doctor/budget-days/<day>.json`, as Lost
  time; they start 10-03, so the prior window is 5 days.
- Repeats, the second number (target 0): ledger rows a snapshot shows `regressed`, distinct per window, with the
  sum's exclusions (log_audit's aside, below; Speed's, test_*, time_floor and growth-* rows out too).

### Baseline (computed 2026-10-16)

| per 100 units | 10-03…07 (855 units) | 10-08…14 (1,952 units) |
|---|---:|---:|
| Harness | 1.05 (9) | 0.20 (4) |
| LLM doctor (legs) | 1.29 (11) | 0.10 (2) |
| Updater | 0.35 (3) | 0 |
| **total** | **2.69** | **0.31** |
| ids of a rule born after 10-02 (own line) | 3 | 4 |
| repeats | 8 | 6 |

- Snapshots start 10-04, so the first window also holds what was open then; 9 of its 11 LLM ids are the image legs
  after the 10-03 media launch. The second misses 10-11.
- The log audit gives exactly 15 findings a night (its merge cap), so it is measured by classes.

## Sources

- Harness doctor (`latest.json`) minus `suite_audit`, `test_*` (Lost time), `cpu_audit` (System), `spend_audit` (Spend).
- LLM doctor (the legs); Updater doctor (`share/updater-ledger.json` is empty: its problems live in the snapshots).
- Log audit (`bin/log-audit`, nightly since 10-07): Haiku reads the day's transcripts in chunks (55 on 10-14), Sonnet
  merges them into 15 Harness problems.
  Kept: the only reader of the night's own waste.
- Ledgers: `share/harness-ledger.json`, `share/doctor-ledger.json` (LLM).

## Recurring classes

Each was fixed as an instance, then came back elsewhere. Ranked 10-15 by hand from the 105 log-audit rows of
10-07…14 and the doctors' rows; "nights": the rows' distinct first commits.

| class | rows | nights | instances fixed |
|---|---:|---:|---:|
| a gate refuses a legitimate command (text matching, brief-format refusals, a commit gate on the wrong repository) | 13 | 7/7 | 12 |
| parallel night fixers collide: one ledger row or handoff, landing races, the same component fixed twice | 10 | 5/7 | 6 |
| a suite run dies with its caller at the 10- or 25-min Bash cap and runs again (all calls: goal bash-cap) | 9 | 6/7 | 4 |
| fan-out into a walled account, then the night idles (≈715 min est.) | 8 | 5/7 | 1 |
| a Stop hook outruns its 5 s cap (Harness `hook-error`) | 7 | 6 days | 6 |
| a reviewer's output takes a shape its reader did not expect (R1: empty findings, agy Markdown, the coverage floor) | 1 | | 7 fixes |
| night load breaks timing tests | 5 | 3/7 | 4 |
| a worker writes a repository its brief never granted (W3, W5, W7, W8, W9) | 5 | 3 days | 11 |
| shell environment: bash 3.2, zsh word-splitting, a launchd PATH | 3 | 3/7 | 2 (1 open) |
| the LLM doctor files one cause again as a new row each day (callers' argument errors refused before spend, all not-a-bug) | 4 | 4 days | 0 |
| model behavior: re-asked decisions, unverified claims, unrequested mechanisms (not mechanics, so no fixer) | ≈25 | 7/7 | |

The collision, walled-account and timing-test rows (23) are the night's own fan-out, stopped only while PILOT is
set, so they stay open; fixers collide on a row, a handoff or a component, not the file.

One fix per class, an existing tool before our own: CLI sandboxes for workers' writes, CLI schemas for reviewers'
output, fixers spread over accounts by room.

## Why rows come back (2026-10-15 audit)

48 harness rows were fixed 2+ times: 22 Speed `opportunity`, 8 noise under load, the rest real returns. Audits
reopened on any source edit (139 of 252 suites due 10-15, none slower); `audit_verdicts` stamps quotes with the
read's time, so a fix landed before it reads regressed; doctors miss each other's verdicts; a repeat had no cheap
exit until the pilot's `repeat:`; parallel fixers (load 100–240) make their own flakes.

## Goals

Worked in order, one at a time (`bin/night-run` PILOT, carry); a landed goal moves to Done with its commit and
proof, a failed one stays with one line on what blocked it. Reads after landing are journals the load also moves.

### goal image-lease: image-fanout never launches a unit onto a locked account while another is idle

Class: fan-out into a busy account. `bin/image-fanout` launches a unit onto a held account, waits 5 s on its lock
(`lock_wait`), exits 5 and cools down 30 s. `~/.cache/image-legs/legs.jsonl` 10-10…23: 6,547 busy exits, 3,741 with
another pool account idle (a ceiling: walled accounts may count as idle, unconfirmed); 798 attempt-min per 14 days
(545 by the 5 s wait floor), and units waited 1,980 min to start.
- Change: `bin/image-fanout` checks the account's lock before launch and takes an idle pool account instead.
- First step: build the replay of `legs.jsonl` 10-10…23, walled accounts not idle; if few busy exits had an idle
  account left, stop.
- Proof, fixed in advance: that replay under the new pick, busy exits 6,547 → ≤ 2,806; a `test_image_fanout`
  held-lock case, red on the old code.
- Must not get worse: successful takes; the Flow daily budget.

### goal metric-source: the Metric reads the doctors' own state, not night snapshots

Metric fault, no class: the newest night snapshot is `20261014T013750Z-8004`, so 10-15…23 has no source and no
goal here can be read.
- Change: new problems and repeats come from the Harness, LLM and Updater doctors' own state, the same ids, days and
  exclusions.
- First step: from today's doctor state, 10-15…23 by hand: of the LLM doctor's 24 recent ids, 14 image-leg failures
  (unconfirmed); 5 Harness ids count; 11 newer `limit_hit` ids on their own line. A state that cannot date an id's
  first showing stops the goal.
- Proof, fixed in advance: the new reader gives the Baseline's 2.69 and 0.31 (10-03…07, 10-08…14) exactly, then a
  value for 10-16…22.
- Must not get worse: the 10-02 rule set and the exclusions; the night report's snapshots.

## Done

- gates (claude-setup 5e3cc12, llm-legs 0daf801d, review-bench 7f36bb6, b936d23, 10-23): 9 gates decide on
  `hooks/lib/argv.sh`; `test_gate_replay` refused old → new: target 9/37 → 2, out 15 → 15, rightly 23 → 23; hook wall
  280 → 149 ms/call. Left: instruction-files.sh, text cases, worker-edit-guard 33 → 70 ms/call. Read: target 0.
- stop-hooks (claude-setup a0fe49a, 10-23): stops waited on process starts, not work: 44 → 34 starts idle; fixture
  stop idle 6.9 → 4.4 s, busy 4.75 → 3.65 s. Read, 7 days: ≥5 s and kills per 1,000 under 13.2 and 3.7; not worse:
  asks, holds, notices, CPU p50 0.29 s.
- pilot-hold (llm-legs 04b8e272, 10-23): an unlanded goal holds its direction and those after;
  `test_night_carry`, first goal left: second starts 1 → 0, why on stderr; landed: 1 → 1.
- bash-cap (llm-legs 35d604a3, 10-23): workers no longer export `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, so a
  Bash call at its cap moves to the background. Proof at a 60 s cap: old 2 of 2 killed, new 2 of 2 moved. Read: killed worker calls, `sleep` excluded,
  207 (10-09…23) → 0 per 14 days; not worse: final responses with a task unread, `worker_orphans`.

## Decisions

- 2026-10-16: the directions run in a queue: the next direction's goals start once these goals have landed, and
  this metric is read 7 days after the last of them. It replaces 10-15's "direction 1 runs alone until its metric
  moves". Parallel directions were declined: two at once collide (bash-cap is also Lost time's) and blur the proof.
  («Updater doctor»)
- 2026-10-15: the pilot plan approved: goals gates → bash-cap → stop-hooks, one at a time; Egor launches the night.
  («Updater doctor»)
- 2026-10-15: `doctor-fix close` takes `ruled-out` with evidence `repeat: <what was fixed before>` on a row whose
  ledger row carries a fix, unmeasured: approved with the pilot plan as the one exception to 10-13's
  measured-evidence rule (P1/P2 Speed and test rows, outside this metric).
- 2026-10-15: no new hooks. Mechanics only where obvious, such as a tool replacing a script models keep rewriting.
  («Updater doctor»)
- 2026-10-15: a goal's worker may leave a goal its own diagnosis shows has little to gain, saying why, and the
  night moves to the next one; no second model re-checks that exit. («Updater doctor»)
- 2026-10-13: fixers have no count cap: rows editing the same files share one fixer, batch size comes from the
  measured cost per closed row, concurrency from `slot_room`. Never "too many" or "too few" as a fixed number.
  («Updater doctor»)
- 2026-10-13: ruled-out on a P1/P2 Speed or test row needs measured evidence.
- 2026-10-12: every cut made by one of our own caps or thresholds is logged where the doctors read it, so the night
  can tell normal from a fault. («Token spending tracking and optimization»)
- 2026-10-05: load is weather: a fix makes the harness hold under load (timing tests, hooks, measurements), never
  asks for a quieter machine or pauses other load. («Updater doctor»)
- 2026-09-29: a gate never makes a model redo work over a formality: a deny must prevent more than the redo costs,
  cosmetic cases pass, rewriting the input or adding a notice beats a deny; destructive-action guards and Egor's
  permission words stay. A gate that fires often means prevention is missing upstream. («Token map хуки оптимизация»)
- 2026-09-29: every hook or gate change gets a worker's adversarial edge-case critique (missed cases, false
  refusals, interactions with other hooks) before it counts as done. («Token map хуки оптимизация»)

## Open

- stop-hooks: the backstop still runs alone (44 % of held seconds) as `words_span_live` syncs the words store;
  on `words_span_on` beside the notices it saves ≈5 starts a stop, but a hold may miss a mid-turn span word.
