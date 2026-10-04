# Hand-off: logo-vectorizer-bench needs its outputs ignored

Status: open

For the chat «Vector Magic macOS ARM migration», which owns `/Volumes/Work/Projects/logo-vectorizer-bench`.
Written 2026-10-04 by «Review-bench improvements phase 4» while settling
`2026-09-30-review-machinery-classes.md` items 1 and 5 (ledger rows M1, M5).

The repository tracks 12 files, and `git status -uall` lists ~10 000 untracked, unignored bench
outputs (`results/lanes` 8 242, `results/ab*`, `tracers/<run>/`). Every Bash call there records them
as this chat's touches, so:

- claude-setup `hooks/lib/review-journal.sh` writes a `hash-cap` gap on each call (now one doctor
  row per tree, the gaps file still grows), and any other chat that runs a Bash call in the tree
  gets the same gap;
- `review-debt` for this chat prices 72 076 touched paths (LINES=16.7M, FILES=32 489): 790 s under
  load, past the doctor's 60 s, so its debt line reads `TimeoutExpired`.

Ask: add the output trees (`results/`, the generated `tracers/*/` subtrees) to `.gitignore`, or
commit what is meant to be kept. Ignored paths are never debt (`review-anchors ignored`), so the
gaps and the timeout stop on the next call. Done when `git -C /Volumes/Work/Projects/logo-vectorizer-bench
status --porcelain -uall | wc -l` is under 500 (`RJ_HASH_CAP`).
