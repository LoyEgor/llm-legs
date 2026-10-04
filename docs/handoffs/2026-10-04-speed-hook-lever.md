# Hand-off: the Speed hook lever (`opportunity:chat/hooks`)

Status: open

For the chat «Harness Doctor» (`share/harness-ledger.json` `owner`). Written 2026-10-04 by night
fixer run `harness-speed-20261004T013952Z-0ff5`, ledger row `speed-hook-lever-review-flow-gate`.

## Measured

`review-flow-gate` still sets the non-trivial Bash before-floor: 1 687 ms p50 over the last hour,
and `hook-sync-review-flow-gate` reads 599 ms a run. Both were taken at night load ~129.

## Not done here, and why

- The hook lives in claude-setup. `doctor-fix` named no file for this lever, so the run got no
  claude-setup worktree. Fixed in llm-legs@1337956b: `SPEED_HOOKS` now maps `chat/hooks` to
  `review-flow-gate.sh`, so the next speed night gets that worktree.
- The lever as worded saves less than Speed prices it. A payload with none of the gated-step words
  can skip the door (`rj_segments` and the family tests). It still needs `rj_snapshot_content`,
  because commit-journal compares against that snapshot, and the snapshot needs the library. The
  floor that stays is the snapshot: the `hook-sync-review-flow-gate` note and the blind spot
  `snapshot-cost-per-repo`. The split between door and snapshot is unmeasured.

## Yours

1. Measure the door against the snapshot on ≥ 200 replayed write calls before a night takes this
   lever again. If the door is the small share, reword the `chat/hooks` entry of `bin/speed-doctor`
   `LEVERS` to point at the snapshot. The cut for that is in `2026-10-03-hook-cost-rows.md` §2.
   This changes the judge, so it is yours.
2. The static `chat/hooks` lever skips `hook_changed_day`, so the whole 7-day window charges it.
   That includes the cost from before claude-setup@9171da1 and @b42c61b (both 2026-10-03). Whether
   it should count only the days after the hook's last commit, as the moved hook rows do, is a
   rule change, so it is yours too.
