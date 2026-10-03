# Debt health: open recording gaps and who settles them

Status: open

For the ledger owner «LLM Doctor меню refactoring» (`share/doctor-ledger.json`), routing hook work
to Debt hardening handoff (claude-setup recording hooks) and loss semantics to Review-bench
improvements phase 4. Last updated by night fixer llm-debt-20261003T042526Z-2fc2; the ledger rows
carry each row's full evidence. No claude-setup ADD-DIR worktree was ever authorized, so every
hook-side item below is a handoff, not a local fix.

## Hook timeouts in logo-vectorizer-bench (H5, H6, H7) — for the hook owner

The transcripts show these are the settings timeouts. They are not teardown:

- H5: 2026-09-28 Pre snapshots (session c25416e4) logged `hook_cancelled PreToolUse` ~31.5 s after the
  call, past `review-flow-gate.sh`'s 30 s timeout. That gate takes the Pre snapshot, so Post found none.
- H6: six `worker-run wait … --max 540` calls of chat 2ddedf36's subagents (cwd `/Users/egorloy`)
  ran 611-626 s: the wait plus a cancelled PostToolUse at the 60 s `commit-journal.sh` timeout. The
  chat's `.repos` lists logo-vectorizer-bench, so its snapshot was consumed from a non-repository cwd.
  claude-setup 48bfc77 does not cover them, because `rc_readonly_command` classes `worker-run wait`
  as heavy.
- H7: 2026-10-03 01:16, toolu_013xec5vq812MjH26xwGK67g, a cp+sed call. PreToolUse ended 22:16:16.757Z;
  PostToolUse `commit-journal` was cancelled 62 s later.

Ruled out: listing and stamping cost. With a sandboxed HOME and `GIT_OPTIONAL_LOCKS=0`,
`rj_snapshot_content` takes 1.2 s on the real tree (33,642 dirty paths). On a 34k-path fixture it
takes 1.1 s, even with `RJ_STAMP_CAP` raised past the count. Still unmeasured: the Post consume path
(it writes the live anchors store) and machine load at those moments. Ask: reproduce the Post path in
a fixture with a timer per step, then make the step that is over budget bounded. Do not raise the
timeouts and do not exempt the tree.

## Proposed for the owner's decision

| Row | Proposal |
| --- | --- |
| H2 | The hash cap is working on research output (33,642 dirty paths). Either the project cleans that output, or the owner accepts the bound and dismisses the row. Never raise the cap. |
| H4 | Dismiss the two hand-run probe ids, `toolu_probe_timing` and `toolu_perf_big`. They are not model calls. |
| H14 | A family worktree that was landed (claude-setup 10ed01b) and then removed mid-run leaves a truthful `not a repository` gap. Dismiss these when the checkout's branch landed, or keep them. The run it left open is fixed in worker-run. |
| H1 | No fixer-missing gap has been open in 14 days. Close the row once the round owners confirm their September rounds were settled, not merely aged out. |
| H3 | One sparse clone on 2026-09-25. It needs a claude-setup fixture for a clone made inside a subshell. |

## Settled

- H11: fixed in worker-run 91858c3 (the unshaped `-` file). Its 2026-10-03 "regressed" came from the
  judge, not the fix: runs started before the landing were dated by their fold time. `debt_health`
  now dates a run gap by its run's start, the way leg rules already do.
- H13 (losses from family folds) is in `2026-10-02-debt-run-fold-skip-families.md`.
- Open runs left by worker runs that never completed are blind spot B7.
