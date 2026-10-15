# Spend (direction 4)

Tokens the harness itself costs: instructions, briefs, relays, hook text, review and doctor runs, worker startup,
and scripts models rewrite where one tool would do.

## Metric

- The Fee/Spend index per unit of work against the previous 7 days, from tokenmap
  (`~/.local/share/tokenmap/tracking.json`, `harness_index`).
- The Doctors' share of 7-day usage, goal ≈5 %.

## State (7 days to 10-15)

| share of usage | % |
|---|---:|
| Workers | 31.1 |
| Doctors | 25.5 |
| Reviewers | 22.6 |
| Chat | 17.1 |

Harness overhead nodes total ≈12 %: delegation 3.6, worker startup 3.4, project docs 2.2, CLAUDE.md+memory 1.5,
review startup 1.3. The week's total was −23 % against the week before.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-05/08 | settings cuts | skill listing per main context −48 % | |
| 10-08/09 | relays retired, delegation made relay-free | relay spend to 0; per worker task 64.5k → 11.7k | ee185fa8 |
| 10-13 | workers skip the user CLAUDE.md; Workflow and ListAgents off workers | | 063ad0c8, 863668df |
| 10-13 | lighter review cells | | review-bench 35f6562 |
| 10-13/14 | md-compact passes | global CLAUDE.md 7.6 → 5.6 KB; llm-legs CLAUDE.md 2.1 → 0.8 KB; DIAGNOSTICS 196 → 124 KB | |
| 10-14 | stale RESUME refused | cold resumes had been 2.2 % of spend: median 199k rewritten, against 31k for a fresh worker | 9864be9d |
| 10-14 | Agent tool off workers | worker startup per task 29.4k → 19.4k | 5d780fd1 |
| 10-14 | first mined tool, `doctor-fix problems` | net proof needs 7 scanned days (≈10-21) | 2580854c |

Records: the spend rows of `share/spend-ledger.json` (64 on 10-15: 17 cut, 47 kept).

## Verdict 2026-10-15

- The overhead nodes are audited and kept: no night pass on them.
- The lever is volume: how many fixers and review cells run. That is the direction 1 pilot.
- Review startup: re-measure ≈10-20, once the cells from before the cut leave the window.

## Decisions

- Model, effort and thinking are never the lever.
- The hook dispatcher was declined (10-05).
- Index doctrine (10-11): fee per unit of work against the previous 7 days; raw growth is load.
- Doctors ≈5 % of 7-day usage. The quality trade is decided only at the backlog plateau.
- Cold resumes were cut (10-14), over the 10-08 keep.
- A tool stays only if it net-saves. No tool for its own sake.
- md-compact has no quota.
