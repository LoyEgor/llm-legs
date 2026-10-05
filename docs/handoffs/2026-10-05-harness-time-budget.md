# Hand-off: one time budget showing how much the harness slows Claude Code

Status: in progress — branch feat/harness-time-budget — To: Harness Doctor

## Why (Egor, 2026-10-05)
Egor cannot tell how heavy his harness is or where. The doctors report per-call milliseconds against limits: a
hook floor at 1 025 ms against 500 ms, or a slot wait. He has no scale between them. The hook-floor trade asked him
to choose a dispatcher over a cost that turned out to be about 5 % of turn time. On the same night, fixers sat in
suite-slot queues for up to 6 h. He wants to see the whole picture in broad strokes, with no obligation to fix any
of it: how fast plain Claude Code would run without his harness, and what each layer of the harness adds.

## Want
1. A time budget over a window (a day, a night): total wall time of chats and workers, split into
   - plain Claude Code: model turns (API time) and tool execution itself;
   - each class the harness adds: hooks by event and tool (Bash, Edit/Write, SessionStart, Stop, …), gates and
     refusals, test suites run by workers, slot and queue waits, locks, review rounds, retries and relaunches,
     anything else the journals already hold.
   Each class gets minutes and its share of the total. A small "other / unmeasured" remainder keeps it honest.
2. One headline: "without the harness ≈ X % faster", the sum of the harness classes over the total.
3. Shown where Egor reads state (the menubar, as the Speed block or a Harness area) in plain words, and in the
   night report. Rough is fine; precision is not the point, proportions are.
4. A short list of levers that could speed up plain Claude Code itself (caching, fewer process starts, prompt-cache
   hits, parallel tools), measured where the data exists and marked as ideas where it does not.

5. Holes, not just totals. Night 20261004T003925Z-4646 measured after the fact: 30 worker runs, 112.4 h wall =
   50.8 h queued for one of 5 night-worker slots + 46.9 h blocked on their own suites + ≤ 9.8 h model activity.
   Nothing showed it; Egor learned it only because he woke up. Each class is judged against a floor, not its own
   history (a baseline lets a bad number stay bad forever): plain Claude Code for hooks and gates, a suite-time
   budget for tests, model activity ≥ ~70 % of a worker's wall, zero queue wait. The gap to the floor in minutes per
   day ranks Speed's improvement queue, and the night takes its top lever even when nothing regressed; an empty pick
   while recoverable minutes exist is a named weak spot. Model activity under ~30 % of a worker's wall is a named row
   ("workers worked 9 % of their time; 45 % went to their own tests"), never buried in a total. The 7-day band only
   flags sudden regressions.
6. Honest night ledger, one line per night plus a trend over the last 7 nights: duration; worker wall vs active;
   lines added/removed by the night's jobs and by runs outside its job list; rewrites of week-old lines; problems
   before → after, proved, regressed, touched again without proof; spend and spend deferred (a skipped debt pass
   counts as deferred, not saved). `night-run report`'s churn block already holds most of it; the trend and the
   time split are missing. Purpose: Egor sees whether nights move forward or tread water. Plus an ROI line per
   improvement job: weighted spend, lines changed, minutes per day saved once the change has run 1–2 days; per
   night spend vs minutes gained and the cumulative return. An improvement with no measured gain shows as spend
   without result: a measurement, never a revert or a gate.
7. Test time as its own budget: hours per day in suites (workers' covering runs, the Close full run), per-suite
   duration ranking (top 10 slowest), and the share that is slot wait vs running. The 2026-10-05 Close full run had
   done ~12 % of the suites after 1 h on a machine the protected benchmark holds at load 130–340.

Known measurement bugs to fix on the way: the slot wait overwrites a run's `started_at` (the night report showed
61.6 h of worker wall instead of 112.4 h); time blocked on suites is not journaled; the wait journal only exists
since 2026-10-04 21:09. Display: visual first (one number in minutes per day, a 7-day bar, the floor), full
detail in an "LLM details" submenu — see the menu proposal handoff `2026-10-05-doctors-menu-for-humans.md`.

## Inputs that already exist
Hook timings (the Harness doctor floor rows: `value`, `exposure` per hour), the wait journal (`wait_note`, Wait
classes area), `~/.cache/doctors/collector-runs.jsonl`, worker-run records (wall clock, served model), run-suites
journal, and session transcripts (turn timestamps → API vs tool time).

## Not
No new guard, no hot-path cost. Reading the existing journals is the job; a missing measurement becomes a cheap
journal row, never a per-call probe.
