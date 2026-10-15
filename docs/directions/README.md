# Directions

The harness is improved one direction at a time (Egor, 2026-10-15). Each direction has one metric and one file
here, and proves it improves on its own before the next one is switched on; the night works them all together
only after each has shown that.

| # | Direction | Metric | State |
|---|---|---|---|
| 1 | [Breakages](breakages.md) | new distinct problems per 100 units of work, 7 days against the 7 before; repeats 0 | active |
| 2 | [Lost time](lost-time.md) | Lost time index | next |
| 3 | [System](system.md) | own background CPU-min/day; SSD GB written a day | later |
| 4 | [Spend](spend.md) | Fee index; Doctors' share of 7-day usage | later |
| 5 | [Legacy](legacy.md) | net lines in the four sweep repositories, code and tests apart | later |
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
- Freshness: a model that finds a file contradicting the code or a ledger fixes the file in the same change.
  Monthly, a periodic night job re-checks every file against its sources by md-compact's rules (to be added to
  `bin/night-run` PERIODIC beside vendor-watch and tool-ideas, with the direction 1 pilot).
