## Deep search — the doctors learn what they do not log

Egor 2026-10-13: when the night finds what a doctor does not log, the doctor learns to log it. Fixers only record
blind spots; this job builds them.

1. `bin/doctor-fix blind-spots` prints the queue: every open `blind_spots` row of the ledgers, costliest first by the
   minutes of the outside finds naming it. Work from the top as far as the night's time bound allows, no count cap.
2. Per row, either build its `would_catch_if` as that doctor's rule (its code, a test red on the old code), the id
   leaving `blind_spots` in that commit; or, when nothing can measure it, set `unmeasurable` to the why and keep the
   row. Never drop a row without one of the two.
3. A built meter raises a real row (`fixed`, `handoff`, `blind-spot`) within 14 days or is reverted: name in the
   commit the row it should raise. The doctor's CPU a run must not grow.
4. Commit on your branch. Report, outcome first, ≤ 150 words: per row built or unmeasurable, its commit; open count
   before → after.
