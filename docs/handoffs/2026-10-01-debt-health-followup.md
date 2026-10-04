# Debt health: open recording gaps and who settles them

Status: open

For the ledger owner «LLM Doctor меню refactoring» (`share/doctor-ledger.json`), routing hook work
to Debt hardening handoff (claude-setup recording hooks) and loss semantics to Review-bench
improvements phase 4. The ledger rows carry each row's full evidence. Until llm-legs doctor-fix
`LLM_ENTRIES["debt"]` (night fixer llm-debt-20261004T013729Z-1f3a) no debt run got a claude-setup or
review-bench worktree, so every hook-side item stayed a handoff; the next night's debt run gets both
and should fix the items below itself.

## Hook-side bugs (claude-setup `hooks/commit-journal.sh`, `review-flow-gate.sh`)

- H15 (and H5's 2026-09-25 `git -C … init` gap): a call from a non-repository cwd with no registered
  repository creates one. Pre writes no snapshot, so `PRE_AT` stays empty and `created_by_call`
  (commit-journal.sh:713) returns 1: always `pre-missing`. Ask: date such a call by its PreToolUse
  moment (a per-call stamp), with a fixture `git -C <new dir> init` from `$HOME`.
- H5: Pre snapshot timeouts in logo-vectorizer-bench, 2026-09-28 and again 2026-10-03 12:38 UTC
  (`hook_cancelled PreToolUse` at 30.8 s, `review-flow-gate.sh`'s 30 s budget). That gate takes the
  Pre snapshot, so Post found none.
- H6, H7: `commit-journal` PostToolUse cancelled at its 60 s timeout in the 65k-dirty-path tree
  (H6: six `worker-run wait … --max 540` calls from `/Users/egorloy` whose chat lists that tree).
  Ruled out: listing and stamping (`rj_snapshot_content` 1.2 s on the real tree). Unmeasured: the
  Post consume path (it writes the live anchors store) and machine load. Ask: time each Post step in
  a fixture and bound the slow one. Do not raise the timeouts and do not exempt the tree.
- H3: one 2026-09-25 sparse clone inside a `( cd … )` subshell (session with 17 registered repos, so
  not H15's cause). Needs a fixture.

## Proposed for the owner's decision

| Row | Proposal |
| --- | --- |
| H2 | The hash cap is working on research output (65,086 dirty paths on 2026-10-04). Either the project cleans that output, or the owner accepts the bound and dismisses the row. Never raise the cap. |
| H4 | Dismiss the two hand-run probe ids, `toolu_probe_timing` and `toolu_perf_big`. They are not model calls; such probes belong under a fixture `HOME`. |
| H14 | A family worktree removed mid-run (claude-setup speed-doctor, night-human-report) leaves a truthful `not a repository` gap. Dismiss these when the checkout's work landed, or keep them. |
| H1 | No fixer-missing gap has been open in 14 days. Close the row once the round owners confirm their September rounds were settled, not merely aged out. |

## Settled

- H11: fixed in worker-run 91858c3 (the unshaped `-` file).
- H13 (losses from family folds) is in `2026-10-02-debt-run-fold-skip-families.md`.
- Open runs left by worker runs that never completed are blind spot B7.
