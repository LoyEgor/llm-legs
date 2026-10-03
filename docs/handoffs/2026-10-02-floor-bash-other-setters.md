# Hand-off: the Bash floor needs both setters cut and the hook fan-out shrunk

Status: open

For the chat «Harness Doctor» (`share/harness-ledger.json` `owner`) and the night orchestrator.
Written by the hook-waits runs 20261002T093035Z-0dca and 20261003T042542Z-1616, ledger row
`floor-bash-other-hooks`. Supersedes the Bash rows of `2026-09-30-floor-bash-other-hooks.md` and
`2026-10-01-hook-waits-shared-components.md`; their other rows stay theirs.

## Measured

Non-trivial Bash calls, the doctor's own joined batches (a probe wrapping `hook_batches`; "without"
recomputes a batch from the other hooks' start and end times):

| 24 h before | side | batches | p50 ms | without review-flow-gate | without commit-journal | without instruction-watch check |
|---|---|---:|---:|---:|---:|---:|
| 10-02 13:55 | before | 7131 | 411 | 276 | – | – |
| 10-02 13:55 | after | 6885 | 352 | – | 235 | 341 |
| 10-03 09:45 | before | 10918 | 462 | 338 | – | – |
| 10-03 09:45 | after | 10621 | 376 | – | 269 | 367 |

On 10-03 the paired p50 is over 500 ms in every one of 22 hours (558-1849), with both setters
removed 467-1010: CPU busy read 0.9-1.0 in 20 of them, and 12:00 (busy 0.57) still read 791. So it
is structural, not only night load. Next setters once both drop: worker-launch-gate before (302 ms
own p50), instruction-watch check after (271 ms own p50, the after side without commit-journal).

Isolated (sandbox HOME, one repository): an xtrace of review-flow-gate puts ~130 of 412 ms in
`rj_snapshot_repos` (`hooks/lib/review-journal.sh` ~2296-2350), ~38 ms `rj_command_words`, ~20 ms
`rj_segments`, the rest the jq parse, sourcing the 2.4k-line library and the family detectors.

## Ruled out

- The 4ca8de1 session repository fan-out: review-flow-gate 381 ms with up to 2 repositories,
  459 ms with 5+; most calls are in 1-2 repository sessions.
- A fixer limit change: the judge is the owner's.

## Yours

1. Night 20261003T042136Z-e9f1: every setter above (review-flow-gate, commit-journal,
   instruction-watch check, worker-launch-gate) is a named problem of
   `harness-hooks-20261003T042542Z-1344`, which holds the claude-setup worktree; the hook-waits run
   has none, so it changed no hook. Judge this floor after that branch lands.
2. The content snapshot pair is the shared cost of both setters (taken in review-flow-gate, read
   back in commit-journal). Decide whether every non-readonly Bash call must pay a full
   `git status` + hash per repository on both sides, or whether a cheaper trigger (an index/mtime
   stamp check, or skipping commands the segmenter proves write no repository path) keeps the
   attribution contract.
3. With both setters at zero the paired floor still reads ~470-1000 ms: the ~17 separate bash hooks
   per side (each paying startup, jq and a library source) on a saturated CPU. A per-side
   dispatcher, as stop-dispatch did for Stop, is the change that moves it under 500 ms; the
   registrations live in the untracked `~/.claude/settings.json`. A limit change instead is a
   loosening and yours alone.
