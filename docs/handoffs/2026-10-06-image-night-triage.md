# Image triage, 2026-10-05..07

Status: settled 20261006T233611Z-7777: I41/I44 not-a-bug and I43/I46 weather (bounded by `until`), I45 fixed (soft_outcome spares caller-asked skips), short-batch detail names its take error (I46 split into I55/I56), fanout.tsv gains a composite column; I3-I47 quiet rows stay open in the ledger

## Not covered by the settlement

Added by night image fixer llm-image-20261006T234227Z-326b before the settlement; the rows stay open in the ledger.

- Proposed not-a-bug: I48, I51 (callers' argument errors and landing probes refused before spend; `until` bounds each).
- rc 2 (refused before spend) reads `bad command` · ours, so I1, I23, I35, I41 and I48 each needed a dismissal row:
  read it `off` like a prelaunch MODEL_REFUSED?
- I54 (Google video generation integration chat): the test-beep check fails replies by +1/+2 beeps; the tail
  holds n beeps. Check the seam before landing.
