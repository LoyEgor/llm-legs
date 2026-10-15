# Breakages (direction 1)

Whatever breaks and has to be reacted to: the harness's gates, hooks, worker-run, the night and the doctors
themselves; the legs (image, video, workers, reviewers); vendor CLI updates; what the nightly transcript read
finds; every row fixed more than once.

## Metric

New distinct problems per 100 units of work, 7 days against the 7 before.
- Units: chat orders plus worker tasks, as Lost time counts them (`share/time_budget.py day --json`,
  `index_window`).
- Distinct problems, not firings: a row that fired 437 times in a day is one.
- Rows from a doctor rule added inside the window go on their own line, never into the sum.
- Second number: repeats, the ledger rows fixed twice or more in the window. Target 0.

### Baseline (computed 2026-10-15)

A row's first day comes from the git history of the ledger that holds it. Units come from
`~/.cache/harness-doctor/budget-days/`, with 10-14 taken from `time_budget.budget()`. The unit journals start on
10-03, so the prior window is 5 days.

| per 100 units | 10-03…07 (855 units) | 10-08…14 (1,952 units) |
|---|---:|---:|
| Harness breakage rules | 0.70 | 0.31 |
| LLM doctor (legs) | 5.15 | 0.36 |
| **doctors total** | **5.85** | **0.67** |
| rows of a rule born in the window (own line) | 19 | 6 |
| repeats: rows re-fixed in the window | 11 | 9 |

- The drop comes mostly from the image legs settling after the 10-03 media launch: 44 → 7 LLM rows.
- The log audit gives exactly 15 findings a night, its merge cap. The raw count before the merge (224 → 541) grows
  with the number of transcripts. Neither count can show a trend, so the log audit is measured by classes, below.

## Sources

- Harness doctor (`~/.cache/harness-doctor/latest.json`) minus the other directions' rows: `suite_audit` and
  `test_*` go to Lost time, `cpu_audit` to System, `spend_audit` to Spend.
- LLM doctor (the legs) and Updater doctor.
- Log audit (`bin/log-audit`, nightly since 2026-10-07):
  - Haiku reads every transcript of the day in chunks (55 on 10-14) and Sonnet merges them into 15 findings, which
    become Harness problems.
  - Cost: reading was ≈0.8 % of worker-run spend over the 7 days to 10-15.
  - Outcome: 105 ledger rows, of which 50 fixed, 18 open and 36 dismissed.
  - Keep it: it is the only reader of the night's own waste.
- Ledgers: `share/harness-ledger.json` (383 rows on 10-15: 284 fixed, 37 open, 31 ruled-out, 25 not-a-bug),
  `share/doctor-ledger.json` (LLM), `share/updater-ledger.json`.

## Recurring classes

Each class was fixed as an instance, then came back somewhere else. Ranked 2026-10-15 from the 105 log-audit rows
of 7 nights (10-07…10-14) and the doctors' rows. "Nights" counts the audits the class showed up in.

| class | rows | nights | instances fixed |
|---|---:|---:|---:|
| a gate refuses a legitimate command by matching its text (17 Bash gates; only 7 share a parser, `readonly-command.sh` or `heredoc-cut.sh`) | 14 | 7/7 | 13 |
| parallel night fixers collide: one ledger or handoff, landing races, the same component fixed twice | 10 | 5/7 | 6 |
| a run dies at the 10- or 25-min Bash cap and is redone (≈500 min est.) | 9 | 6/7 | 4 |
| fan-out into a walled account, then the night idles (≈715 min est.) | 8 | 5/7 | 1 |
| a Stop hook outruns its 5 s cap (Harness `hook-error`) | 7 | 5 days | 7 |
| night load breaks timing tests | 5 | 3/7 | 4 |
| a worker writes a repository its brief never granted | 5 | 4 days | |
| shell environment: bash 3.2, zsh word-splitting, a launchd PATH | 3 | 3/7 | |
| model behavior: re-asked decisions, unverified claims, unrequested mechanisms (not mechanics, so no fixer) | ≈25 | 7/7 | |

Rows 2, 4 and 6 (23 rows) are made by the night's own fan-out. Fewer fixers removes them by construction.

The goal is the class, by one fix that makes it impossible:
- a gate parses the command instead of grepping it;
- one file per ledger row instead of a shared JSON;
- long runs always detached from Bash;
- fixers spread over accounts by room.

The 2026-10-05 night worked that way: one shared cause fixed in several places.

## Why rows come back (2026-10-15 audit)

- **Re-fixes.** 48 harness-ledger rows were fixed 2+ times:
  - 22 are Speed `opportunity` rows (tests and hooks optimised again);
  - 8 were measured under machine load, so noise read as a regression;
  - the rest are real returns.
- **Audits reopen on edits.** The suite, CPU and spend audits reopen on any edit of a source (`spend.moved`, read
  by `share/suite_audit.py`, `share/cpu_audit.py`, `share/spend.py`). On 10-15, 139 of the 252 suites audited on
  10-13/14 were due again with no slower run.
- **Doctors miss each other's verdicts.** The statusline render was settled 10-06
  (`docs/handoffs/2026-10-05-hook-cuts-left.md`), then fixed again by the nights of 10-13 and 10-14.
- **A repeat has no cheap exit.** `doctor-fix close` refuses ruled-out on a P1/P2 Speed or test row without
  measured evidence (Egor 10-13, 997f1d1a), so changing something is the fixer's cheapest way out.
- **The night makes its own.** Parallel fixers load the machine (load 100–240), so tests flake and timings turn to
  noise.

## Planned (agreed in principle 2026-10-15, not landed)

1. A row reopens only on its own number: ×2 held 2 days, with a jump still reopening at once. A source edit alone
   never reopens it, so the source-changed reason goes from the three audits.
2. The night's goal is a class, not a row.
3. A row fixed before may exit as «repeat» with no measurement and goes to the next night's research as a class
   candidate. A fresh row keeps the measured-evidence rule.
4. The night report's facts table gets a repeats row.
5. Fewer parallel fixers (the pilot itself).

## Decisions

- 2026-10-15: direction 1 runs alone until its metric moves. Lost time, System, Spend and Legacy wait.
- 2026-10-15: no new hooks. Mechanics only where obvious, such as a tool replacing a script models keep rewriting.
- 2026-10-13: ruled-out on a P1/P2 Speed or test row needs measured evidence.

## Open

- The pilot plan: goals as classes, waiting for Egor's go.
- Planned item 1 belongs to Lost time, System and Spend, whose audits make those reopens. The block-1 pilot does
  not run those audits.
