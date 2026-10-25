# Breakages (direction 1)

Whatever breaks and has to be reacted to: the harness's gates, hooks, worker-run, the night and the doctors
themselves; the legs (image, video, workers, reviewers); vendor CLI updates; what the nightly transcript read
finds; every row fixed more than once.

## Metric

New distinct problems per 100 units of work, 7 days against the 7 before.
- Source: the doctors' own day journal, read by `python3 share/breakages.py [--ids] [FROM TO]...`: each Harness,
  LLM and Updater persist adds the ids it shows `new` or `regressed` to `~/.cache/doctors/problem-ids/<day>.json`
  (`share/collector_runs.py` `problem_ids`, 35 days). Not ledger rows: only a fixer files one (`docs/doctor-fix.md`)
  and a pilot night launches none. 10-04…14 are seeded from the night snapshots, 10-15…24 backfilled from Harness
  `seen`, LLM `daily/` and the latest documents (each file's `_source`; `limiter_hold*` left out, `seen` keeps no
  state).
- A new problem: an id first shown `new` (no ledger row yet), on its local day, counted once.
- The sum keeps the rules the doctors had on 10-02 (`git log -S` of the rule's name in its doctor); later rules go
  on their own line. Out of it: log_audit (classes, below), test_*, suites_at_once, the audits, Speed's rules
  (floor, hook_*, statusline, menu_build, collector, wait*, worker_orphans, load, opportunity, regression),
  time_floor, tool_idea, growth-* (installs), store_size, debt-*, ledger faults, Updater `event-waiting` (per event).
- Units: `strata.chat.units + strata.workers.units` of `~/.cache/harness-doctor/budget-days/<day>.json`, as Lost
  time, from 10-03.
- Repeats, the second number (target 0): ledger rows the journal shows `regressed`, distinct per window, with the
  sum's exclusions.

### Baseline (computed 2026-10-16)

| per 100 units | 10-03…07 (855 units) | 10-08…14 (1,952 units) |
|---|---:|---:|
| Harness | 1.05 (9) | 0.20 (4) |
| LLM doctor (legs) | 1.29 (11) | 0.10 (2) |
| Updater | 0.35 (3) | 0 |
| **total** | **2.69** | **0.31** |
| ids of a rule born after 10-02 (own line) | 3 | 4 |
| repeats | 8 | 6 |

- Snapshots start 10-04, so the first window holds what was open then (9 of 11 LLM ids: image legs). The second
  misses 10-11. The log audit gives 15 findings a night (its cap), so it is measured by classes.
- Snapshots sampled twice a night, the journal every persist: Harness `seen` holds up to 4 and 2 more counted ids
  in the two windows (state unknown), so a journal week reads a little higher than these.

## Sources

- Harness doctor minus `suite_audit`, `test_*` (Lost time), `cpu_audit` (System), `spend_audit` (Spend); LLM doctor
  (the legs); Updater doctor (its problems live in the snapshots).
- Log audit (`bin/log-audit`, nightly): Haiku reads the day's transcripts, Sonnet merges 15 Harness problems; the
  only reader of the night's own waste.
- Ledgers: `share/harness-ledger.json`, `share/doctor-ledger.json` (LLM).

## Recurring classes

Fixed as instances, then back elsewhere: ranked 10-15 by hand from 105 log-audit rows of 10-07…14 and the doctors'
rows; "nights": the rows' distinct first commits.

| class | rows | nights | instances fixed |
|---|---:|---:|---:|
| a gate refuses a legitimate command (text matching, brief format, a commit gate on the wrong repository) | 13 | 7/7 | 12 |
| parallel night fixers collide: one ledger row or handoff, landing races, one component fixed twice | 10 | 5/7 | 6 |
| a suite run dies with its caller at the Bash cap and runs again (goal bash-cap) | 9 | 6/7 | 4 |
| fan-out into a walled account, then the night idles (≈715 min est.) | 8 | 5/7 | 1 |
| a Stop hook outruns its 5 s cap (Harness `hook-error`) | 7 | 6 days | 6 |
| a reviewer's output takes a shape its reader did not expect (R1) | 1 | | 7 fixes |
| night load breaks timing tests | 5 | 3/7 | 4 |
| a worker writes a repository its brief never granted (W3, W5, W7, W8, W9) | 5 | 3 days | 11 |
| shell environment: bash 3.2, zsh word-splitting, a launchd PATH | 3 | 3/7 | 2 (1 open) |
| the LLM doctor files one cause again as a new row each day (callers' argument errors, not-a-bug) | 4 | 4 days | 0 |
| model behavior: re-asked decisions, unverified claims, unrequested mechanisms (no fixer) | ≈25 | 7/7 | |

The collision, walled-account and timing-test rows (23) are the night's own fan-out, stopped only while PILOT is
set.

One fix per class, an existing tool before our own: CLI sandboxes for workers' writes, CLI schemas for reviewers'
output, fixers spread over accounts by room.

## Goals

Worked in order, one at a time (`bin/night-run` PILOT, carry); a landed goal moves to Done with its commit and
proof, a failed one stays with one line on what blocked it. Reads after landing are journals the load also moves.

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

### goal hook-map: one place shows what every hook does and whether it still earns its keep

Class: a gate refuses a legitimate command. 30 days to 10-25 (hook attachments by uuid, `refusal-scan.json`,
`hooks/*.tsv`): settings register 55 hooks, one a deleted file; 7 gates or nudges never denied, rewrote or noticed
(workflow-burn, jira-mention, demo-link, connections, slash-collision, pr-auto-reviewers, eod-sorted); of 636
denials, 202 passed within 5 calls (same program, half the tokens; 9 after his message), 230 by similarity ≥ 0.7,
184 both. On `gate-corpus` labels, flagged ones are false refusals at the base rate (12/39 vs 38/122): the flag
marks a deny a rewrite could replace.
- Change: `harness-doctor` section `hook_map` and `harness-doctor hooks`, from settings and journals, in the Doctors
  menu. Per hook: event, matcher, what it does, why it exists (commit and incident, `git log`), last fired, 30-day
  allow/deny/rewrite/notice/error; flags never fired in 30 days, denied then bypassed, missing file. A removal or
  deny → notice candidate names its pain and shows it no longer occurs.
- First step: attribute notices with no `command` (UserPromptSubmit, SessionStart); confirm the 7 in `hooks/*.tsv`.
- Proof, fixed in advance: on a fixture copy of the 10-25 journals the map gives 55, 7, 202; a hook dropped from
  fixture settings leaves the map.
- Must not get worse: Harness doctor pass time, `menu_build`; no hook added or changed.

## Done

- gates (claude-setup 5e3cc12, llm-legs 0daf801d, review-bench 7f36bb6, b936d23, 10-23): 9 gates decide on
  `hooks/lib/argv.sh`; `test_gate_replay` refused old → new: target 9/37 → 2, out 15 → 15, rightly 23 → 23; hook wall
  280 → 149 ms/call. Left: instruction-files.sh, text cases, worker-edit-guard 33 → 70 ms/call. Read: target 0.
- stop-hooks (claude-setup a0fe49a, 10-23): 44 → 34 process starts idle; fixture stop idle 6.9 → 4.4 s, busy 4.75
  → 3.65 s. Read, 7 days: ≥5 s and kills per 1,000 under 13.2 and 3.7; not worse: asks, holds, notices, CPU p50 0.29 s.
- pilot-hold (llm-legs 04b8e272, 10-23): an unlanded goal holds its direction and those after; `test_night_carry`.
- bash-cap (llm-legs 35d604a3, 10-23): a worker's Bash call at its cap moves to the background (old 2 of 2 killed,
  new 2 of 2 moved). Read: killed worker calls, `sleep` excluded, 207 (10-09…23) → 0 per 14 days; not worse: final
  responses with a task unread, `worker_orphans`.
- image-lease (llm-legs d8cf1275, 10-25): `bin/image-fanout` probes the lock files the rosters name (one perl
  flock per vendor) before a launch; a held pool pick goes to an idle account, a pinned one waits unlaunched.
  Replay of `legs.jsonl` 10-10…23 (walls from `hits.jsonl`): of 6,569 busy exits 3,742 had a lock-free account,
  1,578 one not walled; busy exits 6,569 → 289 left as probe races (316 counting holders the log lacks), target
  ≤ 2,806; `test_image_fanout` held-lock cases red on old. Not worse: takes (giveup 15 min kept), Flow budget (a
  probe sends nothing). Read: rc 5 legs with a `fanout-` job per 14 days.

## Decisions

- 2026-10-16: the directions run in a queue: the next direction's goals start once these goals have landed, and
  this metric is read 7 days after the last of them. Parallel directions collide and blur the proof. («Updater
  doctor»)
- 2026-10-15: goals run one at a time; Egor launches the night. `doctor-fix close` takes `ruled-out` with evidence
  `repeat: <what was fixed before>` on a row whose ledger row carries a fix, the one exception to 10-13's
  measured-evidence rule. («Updater doctor»)
- 2026-10-15: no new hooks. Mechanics only where obvious, such as a tool replacing a script models keep rewriting.
  («Updater doctor»)
- 2026-10-15: a goal's worker may leave a goal its own diagnosis shows has little to gain, saying why, and the
  night moves to the next one; no second model re-checks that exit. («Updater doctor»)
- 2026-10-13: fixers have no count cap: rows editing the same files share one fixer, batch size comes from the
  measured cost per closed row, concurrency from `slot_room`. («Updater doctor»)
- 2026-10-13: ruled-out on a P1/P2 Speed or test row needs measured evidence.
- 2026-10-12: every cut made by one of our own caps or thresholds is logged where the doctors read it, so the night
  can tell normal from a fault. («Token spending tracking and optimization»)
- 2026-10-05: load is weather: a fix makes the harness hold under load, never asks for a quieter machine or pauses
  other load. («Updater doctor»)
- 2026-09-29: a gate never makes a model redo work over a formality: a deny must prevent more than the redo costs,
  cosmetic cases pass, rewriting the input or adding a notice beats a deny; destructive-action guards and Egor's
  permission words stay. A gate that fires often means prevention is missing upstream. («Token map хуки оптимизация»)
  Hook-map's "denied, then bypassed" list is where a gate moves from deny to rewrite or notice.
- 2026-09-29: every hook or gate change gets a worker's adversarial edge-case critique before it counts as done.
  («Token map хуки оптимизация»)

## Open

- stop-hooks: the backstop still runs alone (44 % of held seconds) as `words_span_live` syncs the words store;
  on `words_span_on` beside the notices it saves ≈5 starts a stop, but a hold may miss a mid-turn span word.
