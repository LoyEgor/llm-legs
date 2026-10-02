# Hand-off: the Bash floor needs both setters cut and the hook fan-out shrunk

Status: open

For the chat «Harness Doctor» (`share/harness-ledger.json` `owner`). Written 2026-10-02 by the
night fixer run harness-hook-waits-20261002T093035Z-0dca (night 20261002T092633Z-e367), ledger row
`floor-bash-other-hooks`. Supersedes the Bash rows of `2026-09-30-floor-bash-other-hooks.md` and
`2026-10-01-hook-waits-shared-components.md`; their other rows stay theirs.

## Measured

24 h before 2026-10-02 13:55, non-trivial Bash calls, from the doctor's own joined batches (a probe
wrapping `hook_batches`, so the same joins the floor rule uses). "Without" recomputes a batch from
the remaining hooks' start and end times, i.e. the side's wait had that hook cost nothing.

| side | batches | p50 ms | without review-flow-gate | without commit-journal | without instruction-watch check |
|---|---:|---:|---:|---:|---:|
| before | 7131 | 411 | 276 | – | – |
| after | 6885 | 352 | – | 235 | 341 |

Per hour (paired p50 / paired p50 with both setters removed): day hours 605-961 / 448-727 ms; night
hours under load average 46-65 (this night's own parallel workers) 1092-1406 / 457-1043 ms. With both
setters at zero the paired floor still sits around 460-510 ms at day load: the rest of the ~15
parallel bash hooks per side.

Setter cost by session repositories (doctor `split`): review-flow-gate 381 ms with up to 2
repositories (5532 runs), 459 ms with 5+ (1064); commit-journal 316 / 451 ms. The 4ca8de1 snapshot
fan-out is not the main driver: most calls are in sessions of 1-2 repositories.

Isolated, in a sandbox HOME on this worktree (clean tree, one repository, load average ~50):
review-flow-gate 330 ms, commit-journal 170-310 ms. An xtrace of review-flow-gate puts ~130 of 412
traced ms in `rj_snapshot_repos` (`hooks/lib/review-journal.sh` ~2296-2350: rev-parse, git status,
path stamps and hashes, written then hard-linked), ~38 ms in `rj_command_words`, ~20 ms in
`rj_segments`, the rest spread over the jq parse, sourcing the 2.4k-line review-journal library
(~17 ms in commit-journal) and the family detectors. No single fat line.

## Ruled out

- `instruction-watch check` (llm-legs `bin/instruction-watch.sh`): removing it moves the after side
  11 ms at p50; it becomes the after setter only once commit-journal drops. Not touched.
- The session repository fan-out of 4ca8de1: see the split above.
- A fixer limit change: the judge is the owner's.

## Yours (claude-setup, outside a hook-waits run's repositories)

1. The content snapshot pair is the shared cost of both setters (taken in review-flow-gate, read
   back in commit-journal). Decide whether every non-readonly Bash call must pay a full
   `git status` + hash per repository on both sides, or whether a cheaper trigger (an index/mtime
   stamp check before `git status`, or skipping commands the segmenter proves write no repository
   path) keeps the attribution contract.
2. Even with both setters at zero the paired floor is ~500 ms: the per-side fan-out of separate bash
   hooks (each paying startup, jq and a library source) is the structural cause. A per-side
   dispatcher, as stop-dispatch did for Stop, is the change that moves it under 500 ms; a limit
   change instead is a loosening and yours alone.
3. A night run's 1 h window reads its own load (load average 50-65 here): night readings of this
   floor are 2x day readings. Whether the floor rule should be judged on calls outside night-run
   load is a judge question for you.

Probe: `/tmp/hd-probe-0dca.py` pattern — load `bin/harness-doctor` with `SourceFileLoader`, wrap
`hook_batches`, run `collect(False, now)`, then group `b["call"]` per `tool_use` id.
