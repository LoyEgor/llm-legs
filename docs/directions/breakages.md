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

Baseline: not computed yet.

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

Each class was fixed as an instance, then came back somewhere else.

| class | fixed | back in |
|---|---|---|
| a gate blocks a legitimate command by matching its text | 10-09 ×2, 10-10, 10-14 | log audit 10-14 |
| parallel fixers conflict on one shared JSON ledger or handoff | 10-08 ×2, 10-13 | log audit 10-14 |
| a run dies at the 10- or 25-min Bash cap and is redone | 10-07 ×2, 10-14 | log audit 10-14, ≈500 min est. |
| every fixer on one account hits its session wall and the night stalls | 10-08, 10-12, open | log audit 10-14, ≈715 min est. |
| worker-run orphans (caffeinate, forked shells) | 6 fixes | |
| a trivial Bash call waits on the heavy hooks | 4 fixes; each new hook broke the fast path again | |

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

- The metric's baseline over the last 7+7 days.
- The class list from the ledgers, ranked by how often each class returns.
