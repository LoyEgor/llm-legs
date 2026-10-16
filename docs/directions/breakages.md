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

## Goals

The pilot night works these goals in order, one at a time (`bin/night-run` PILOT, carry). A goal that lands
moves to Done with its commit and proof. A goal that fails stays here with one line on what blocked it.

### goal gates: every Bash gate parses the command instead of matching its text

Class: a gate refuses a legitimate command because a word it looks for sits in a quoted argument, a heredoc, a
commit message, a path or a probe. The log audit found 14 such rows on 7 of 7 nights; 13 were fixed one gate at a
time.
- The gates are the PreToolUse Bash hooks of `~/.claude/settings.json`, 17 on 10-15, in claude-setup `hooks/`
  and llm-legs `bin/`. Seven use `hooks/lib/readonly-command.sh` or `hooks/lib/heredoc-cut.sh`; the rest grep the
  raw text.
- One parser in claude-setup `hooks/lib/` turns a command into its simple commands: program and arguments, split at
  pipes, `&&`, `;`, subshells and `bash -c` bodies. Quoted text, heredoc bodies and comments are data. Every gate
  decides on its output, never on the raw string. The two current libs fold into it.
- Corpus: every denial of the last 14 days in `~/.cache/harness-doctor/refusal-scan.json` (transcript,
  tool_use_id, gate). Each command is read from its transcript and labelled legitimate or rightly refused, plus the
  quotes of this class's log-audit rows in `share/harness-ledger.json`. It becomes a fixture every gate's suite
  replays.
- Proof, old → new on the corpus: legitimate refusals fall to 0; every rightly refused command is still refused;
  each gate's own suite stays green.
- After landing: the denials a day in `refusal-scan.json` that a model then re-ran in another form, 7 days before
  against 7 after.

### goal bash-cap: a long run outlives the caller's Bash cap instead of dying and running again

Class: a suite run, `run-all` or a probe started in the foreground dies at the 10- or 25-minute Bash cap and runs
again. 9 rows on 6 of 7 nights, ≈500 min est.
- The priced idea is `tool-idea-run-all-attach` in `share/harness-ledger.json`. When its caller is killed,
  `run-suites` keeps running detached, and the next `tests/run-all --attach <run>` waits on it instead of starting
  over.
- Proof: suite runs killed at the cap per week, from `~/.cache/run-suites/runs.jsonl` and the transcripts. It was
  61 a week before the tests-once rule. Before against after, with no suite result lost.

### goal stop-hooks: every Stop hook finishes inside its cap on a loaded machine

Class: a Stop hook in claude-setup `hooks/stop.d/` outruns its 5 s slice, and each case was fixed alone. Harness
`hook-error` found 7 rows on 5 days: worker-run-backstop, notice-chat-names, ask-span-drill, ask-word-reading,
ask-run-unfinished, notice-connections, and stop-dispatch with no timeout binary on a launchd PATH.
- A hook's work at a stop is bounded by design: incremental reads, a cache keyed on what it reads, nothing that
  grows with the transcript or the tag cache. stop-dispatch caps every hook on any PATH.
- Proof: Harness `hook-error` rows and the Stop timeouts in its hook journal, 7 days before against 7 after, under
  the night's load.

## Mechanics (2026-10-15)

- The pilot: one goal at a time, no row fixers, no debt pass, no owner chats. It removes the fan-out classes by
  construction.
- `doctor-fix close` takes `ruled-out` with evidence `repeat: <what was fixed before>` on a row whose ledger row
  carries a fix, with no measurement. Those rows are the next goals' candidates.
- The night report's facts table has a `repeats` row: the ledger rows re-fixed during the night.
- Not done: a row reopening only on its own number. It belongs to Lost time, System and Spend, whose audits make
  those reopens.

## Decisions

- 2026-10-15: the pilot plan approved: goals gates → bash-cap → stop-hooks, one at a time; Egor launches the night.
- 2026-10-16: the directions run in a queue: the next direction's goals start once these goals have landed, and
  this metric is read 7 days after the last of them. It replaces 10-15's "direction 1 runs alone until its metric
  moves". Parallel directions were declined: two at once collide (bash-cap is also Lost time's) and blur the proof.
- 2026-10-15: no new hooks. Mechanics only where obvious, such as a tool replacing a script models keep rewriting.
- 2026-10-13: ruled-out on a P1/P2 Speed or test row needs measured evidence.

## Open

- The first pilot night: Egor launches it. The proof is read 7 nights later against the baseline above.
