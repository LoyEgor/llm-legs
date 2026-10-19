# Directions

The harness is improved one direction at a time (Egor, 2026-10-15). Each direction has one metric and one file
here. The directions run in a queue, one goal at a time, each proven on its own number (2026-10-16); the night works
them all together only after each direction's metric has moved.

Blocks, in queue order (Egor 2026-10-20; the numbers are how he and the chats name them):

| # | Block | Metric | State |
|---|---|---|---|
| 0 | Always on | none: the prep every night runs (vendor CLIs installed, log audit, doctors) and the monthly directions refresh | runs |
| 1 | [Breakages](breakages.md) | new distinct problems (doctor snapshots) per 100 units of work, 7 days against the 7 before; repeats 0 | active |
| 2 | [Tests and lost time](lost-time.md) | Lost time index | queued; tests' whole scope being added |
| 3 | [System](system.md) | own background CPU-min/day, hooks included; SSD and swap written watched | queued |
| 4 | [Spend](spend.md) | Fee index of workers, reviewers and background; Doctors' share watched | queued |
| 5 | [Legacy](legacy.md) | legacy lines standing in the four sweep repositories, code only; net lines watched | queued |
| 6 | Vendors | being set: a vendor change (version, model, plan) studied and integrated | being prepared |
| 7 | Doctors | being set: doctors' Fix rows, and what no doctor shows | being prepared |
| 8 | Leftovers | being set: handoffs and unlanded branches | being prepared |
| 9 | Monthly research | vendor news, repeated ad-hoc scripts become tools | postponed (Egor 2026-10-20) |
| 10 | [Debt](debt.md) | review debt closed: a bugs read of settled code only (Egor 2026-10-06) | paused, last |

Every block, upkeep ones too, keeps one rule (Egor 2026-10-20): it is judged by a metric that converges, never by
work done. A goal removes a class's root cause, and its proof shows the class stops coming back and the block's
number moves (more reliable, faster tests, fewer tokens), with net lines shown; code that moves no number is reverted.

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
- The queue: `bin/night-run` PILOT lists the ready directions in order. Every new night is their pilot and works
  only the `### goal <slug>:` sections under each file's `## Goals`, one at a time, a direction's goals once the one
  before has none left; the rest of the night waits (The whole night, below), so a goal is judged alone on its metric
  and its spend. A direction's metric is read 7 days after its last goal lands, while the next one works. An empty
  PILOT brings back the full night.
- Ready: a direction joins PILOT once its file holds a baseline computed before any pilot night changed the harness,
  its recurring classes ranked from the ledgers and the log audit, and goals, each one class fix with its proof fixed
  before the work. A fresh model that did not write it (another vendor when the worker toggles let one work) has
  checked that the numbers reproduce from the sources, that each goal fixes a class rather than an instance, and
  that each proof is measurable.
- Freshness: a model that finds a file contradicting the code or a ledger fixes the file in the same change.
  Monthly, the night's `directions-refresh` job (`share/briefs/directions-refresh.md`) re-checks every file against
  its sources by md-compact's rules; a pilot night runs it after its last goal.

## The whole night

The night's purpose (Egor 2026-10-19): a singularity, automation that keeps the whole harness directly or indirectly
with as little manual work as possible; he launches it and it does everything. It digs deeper than the doctors: a
doctor is a helper that gives hints, never the scope. The pilot narrows a night to one thing at a time to test it;
it drops nothing. Each section below comes back in its block's turn (#, the block that judges it) and is tested
like a goal: does the night cope, if not why, can it do the same for fewer tokens. A section is dropped only by an explicit
decision with Egor, written here.

| # | Section | What it does | In a pilot night |
|---|---|---|---|
| 0 | Prep, directions refresh | vendor CLIs installed, log audit, LLM, harness and Updater doctors; monthly, the direction files re-checked | runs |
| 1–5 | Direction goals | one class fix at a time, with its proof | runs |
| 2 | Failed suites | suites the last full run left red | waits |
| 6 | Vendor events | a new CLI version, model or plan studied and integrated (`vendor-fingerprint`) | waits |
| 7 | Doctor fixes | every doctor's Fix row (`doctor-fix launch`) | waits |
| 7 | Deep search | after its goals the night looks for what no doctor shows, the next goal's candidates | waits |
| 8 | Handoffs, owner chats | each open handoff done, or handed to its owner chat | waits |
| 8 | Leftovers | unlanded branches landed | waits |
| 9 | Monthly research | vendor news (`vendor-watch`), repeated ad-hoc scripts become tools (`tool-ideas`) | waits |
| 10 | Review debt | bugs and fit rounds, the debt pass ([Debt](debt.md)) | paused (Egor 2026-10-14) |
