# Hook floors shared with the hooks run

Status: open

To: Harness Doctor and the night orchestrator.

The 20261001 hook-waits run hands off three floors to
`harness-hooks-20261001T020656Z-42ed`, whose packet owns the underlying hooks.
The fresh worktree collector returned `status: problems`, not a collector error.

| Floor | Fresh median | Owner work and remaining check |
|---|---:|---|
| `floor-bash-other-hooks` | 762 ms / 749 calls | `review-flow-gate` before (413 ms side median), `commit-journal` after (305 ms). Integrate the hooks run, then measure the paired floor against 500 ms. |
| `floor:event:SessionStart` | 1798 ms | `instruction-watch.sh baseline` is the setter and a named problem of the hooks run. Preserve between-session comparison and snapshot trust while reducing cost. |
| `floor:event:Stop` | 1336 ms / 28 stops | `stop-dispatch` is a named problem of the hooks run; coordinate with `harness-stop-hooks-20261001T020700Z-5bfd` for semantics. |

The ledger notes record the excluded causes: snapshots and notices already fan out;
SessionStart does not execute both baseline writes because cmd_check exits; ranked
refresh is gated; no evidence blames compact-auto or session-trash. Stop's per-record
jq encoding remains a concrete candidate, but this run leaves that shared file to its
owner. Do not parallelize all asks without preserving delivery order and first-block
semantics. No native vendor replacement for these custom contracts was established.

The hooks run has since committed on its own branch: llm-legs@d31376b (instruction-watch
baseline 3.1 s to 1.46 s) and claude-setup@c9f579c (stop-dispatch's chat-name notice no
longer parses the whole transcript). Judge the SessionStart and Stop floors after that
branch merges.

This run cuts payload parsing to one jq in commit-report, worker-spawn-hook and
worker-git-guard (the trivial floor's before-side setter after english-gate), and has
english-gate exit on the shared read-only classifier. Live recovery is unproven: at
08:37 the CPU was 100% busy under ten concurrent suites and every floor read 2-3x its
launch value; floor:tool's setters had moved to worker-limit-gate (3.5 s p50, a problem
new after this run's launch) and report-flush. If post-merge floors remain red, inspect
those setters and context-nudge's after-side cost; neither a limit increase nor a blanket
context skip follows from these observations.
