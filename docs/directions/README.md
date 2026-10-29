# Directions

The harness is improved one direction at a time (Egor, 2026-10-15). Each direction has one metric and one file
here. Directions run in a queue, one goal at a time, each proven on its own number (2026-10-16), no block building
on one whose number has not passed its read (2026-10-25); the night works them all together once each metric moved.

Blocks (the numbers are names, 2026-10-20; the order is State):

| # | Block | Metric | State |
|---|---|---|---|
| 0 | Always on | none: nightly prep (vendor CLIs, log audit, doctors), monthly directions refresh | runs |
| 1 | [Breakages](breakages.md) | new distinct problems (doctors' day journal) per 100 units of work, 7 days against the 7 before; repeats 0 | landed 10-25; read 11-05, 7 d after Doctors lands |
| 2 | [Tests and lost time](lost-time.md) | Lost time index; test legacy lines watched | after 1's read |
| 3 | [System](system.md) | own background CPU-min/day, hooks included; SSD and swap written watched | after 1's read |
| 4 | [Spend](spend.md) | Fee index of workers, reviewers and background; Doctors' share watched | after 1's read |
| 5 | [Legacy](legacy.md) | legacy lines standing in the four sweep repositories, code only; net lines watched | independent |
| 6 | [Vendors](vendors.md) | integration lag: mean days from a vendor event to its close; changes found outside the fingerprint 0 | independent |
| 7 | [Doctors](doctors.md) | false-alarm share of decided Fix rows; outside-found share (what no doctor shows) | landed 10-29; read 11-05 (1–4 read through it) |
| 8 | [Leftovers](leftovers.md) | handoffs and branches that outlive a night, plus returns, per night; target 0 | after 2–4 |
| 9 | Monthly research | vendor news, repeated ad-hoc scripts become tools | postponed (Egor 2026-10-20) |
| 10 | [Debt](debt.md) | review debt closed: a bugs read of settled code only (Egor 2026-10-06) | paused, last |

Every block, upkeep ones too, is judged in three layers (Egor 2026-10-20), never by work done:
- Its number is a compass: whether the block gets healthier over weeks. One that does not converge sends the block
  back to re-research its diagnosis, never to more code.
- A goal removes a class's root cause and is judged by the promise it writes before the work: a number when one
  exists, else a checkable fact. A promise that did not hold is reverted.
- Harm is reverted: another number worse, red tests, code added with no stated gain. A missing number never is;
  net lines are always shown, and deleting what nothing needs needs no number.

## Rules

- A problem belongs to the direction whose metric it moves: test CPU is Lost time even though System shows it, a
  hook's latency is Breakages or Lost time, its CPU is System.
- A fix works only its direction's part and never makes another direction's number worse (worse → revert). A gain
  on another metric from the same change is a bonus, never the goal: one change is proven on one metric.
- Workers, hub chats and the night read these files instead of the chats; briefs are built from them. A chat that
  settles something with Egor writes it into that file's Decisions before it stops.
- Done, kept and open live in the ledgers each file names. The file holds what the ledgers cannot: classes, the
  metric's baseline, why rows come back, Egor's decisions.
- Proof: the check is fixed before the work; old against new, interleaved, on the same machine; verdict better,
  worse or unclear, and unclear is kept and settled by the next days' data. A direction may stop a goal once its
  diagnosis shows little to gain.
- The queue: `bin/night-run` PILOT lists, in order, the blocks a night may work: the next dependent one and the
  independent ones. A pilot night works only their `### goal <slug>:` sections, one at a time in PILOT order; the
  rest of the night waits (The whole night), so a goal is judged alone on its metric and spend. Per block: goals →
  its metric read 7 days after its last goal lands, while an independent block works → a cost pass (the same effect
  for fewer minutes and tokens, proven equal) → the next dependent block joins PILOT. An empty PILOT brings back the
  full night.
- Ready: a direction joins PILOT once its file holds a baseline computed before any pilot night changed the harness,
  its recurring classes ranked from the ledgers and the log audit, and goals, each one class fix with its proof fixed
  before the work. A model that did not write it (another vendor when the toggles allow) has checked that the
  numbers reproduce, each goal fixes a class, not an instance, and each proof is measurable.
- Freshness: a model that finds a file contradicting the code or a ledger fixes the file in the same change.
  Monthly, the night's `directions-refresh` job re-checks every file against
  its sources by md-compact's rules; a pilot night runs it after its last goal.

## The whole night

The night's purpose (Egor 2026-10-19): a singularity, automation that keeps the whole harness directly or indirectly
with as little manual work as possible; he launches it and it does everything. It digs deeper than the doctors: a
doctor is a helper that gives hints, never the scope. The pilot narrows a night to one thing at a time to test it;
it drops nothing. Each section below returns in its block's turn (#) and is tested like a goal: does the night
cope, if not why, can it do the same for fewer tokens. Dropping a section takes his decision, written here.

| # | Section | What it does | In a pilot night |
|---|---|---|---|
| 0 | Prep, directions refresh | vendor CLIs installed, log audit, LLM, harness and Updater doctors; monthly, the direction files re-checked | runs |
| 1–5 | Direction goals | one class fix at a time, with its proof | runs |
| 2 | Failed suites | suites the last full run left red | waits |
| 6 | Vendor events | a new CLI version, model or plan studied and integrated (`vendor-fingerprint`) | after the goals, once none is left before block 6 |
| 7 | Doctor fixes | `doctor-fix launch --night` on a full night | waits |
| 7 | Deep search | after its goals the night looks for what no doctor shows, the next goal's candidates | waits |
| 8 | Handoffs, owner chats | each open handoff done, or handed to its owner chat | waits |
| 8 | Leftovers | unlanded branches landed | waits |
| 9 | Monthly research | vendor news (`vendor-watch`), repeated ad-hoc scripts become tools (`tool-ideas`) | waits |
| 10 | Review debt | bugs and fit rounds, the debt pass ([Debt](debt.md)) | paused (Egor 2026-10-14) |
