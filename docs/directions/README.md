# Directions

The harness is improved one direction at a time (Egor, 2026-10-15). Each direction has one metric and one file
here. The directions run in a queue, one goal at a time, each proven on its own number (2026-10-16); the night works
them all together only after each direction's metric has moved.

| # | Direction | Metric | State |
|---|---|---|---|
| 1 | [Breakages](breakages.md) | new distinct problems (doctor snapshots) per 100 units of work, 7 days against the 7 before; repeats 0 | active |
| 2 | [Lost time](lost-time.md) | Lost time index | queued |
| 3 | [System](system.md) | own background CPU-min/day, hooks included; SSD and swap written watched | queued |
| 4 | [Spend](spend.md) | Fee index of workers, reviewers and background; Doctors' share watched | queued |
| 5 | [Legacy](legacy.md) | legacy lines standing in the four sweep repositories, tests apart; net lines watched | queued |
| 6 | [Debt](debt.md) | review debt closed | paused |

## Rules

- A problem belongs to the direction whose metric it moves: test CPU is Lost time even though System shows it, a
  hook's latency is Breakages or Lost time, its CPU is System.
- A fix works only its direction's part and never makes another direction's number worse (worse → revert). A gain
  on another metric from the same change is a bonus, never the goal: one change is proven on one metric.
- This file set is what a worker, a hub chat or the night reads instead of the chats: a brief is built from the
  direction's file. A chat that settles something with Egor writes it into that file's Decisions before it stops.
- Done, kept and open live in the ledgers each file names. The file holds what the ledgers cannot: classes, the
  metric's baseline, why rows come back, Egor's decisions.
- Proof: the check is fixed before the work; old against new, interleaved, on the same machine; verdict better,
  worse or unclear, and unclear is kept and settled by the next days' data. A direction may stop a goal once its
  diagnosis shows little to gain.
- The queue: `bin/night-run` PILOT lists the ready directions in order. Every new night is their pilot: the whole
  night (doctor fixes, vendor events, leftovers, handoffs, suites, periodic jobs; Egor 2026-10-19: a night covers
  every section) plus the `### goal <slug>:` sections under each file's `## Goals`, one at a time, a direction's goals
  once the one before has none left; only review debt stays paused. A direction's metric is read 7 days after its
  last goal lands, while the next one works. An empty PILOT brings back the debt pass.
- Ready: a direction joins PILOT once its file holds a baseline computed before any pilot night changed the harness,
  its recurring classes ranked from the ledgers and the log audit, and goals, each one class fix with its proof fixed
  before the work. A fresh model that did not write it (another vendor when the worker toggles let one work) has
  checked that the numbers reproduce from the sources, that each goal fixes a class rather than an instance, and
  that each proof is measurable.
- Freshness: a model that finds a file contradicting the code or a ledger fixes the file in the same change.
  Monthly, the night's `directions-refresh` job (`share/briefs/directions-refresh.md`) re-checks every file against
  its sources by md-compact's rules; a pilot night runs it after its last goal.
