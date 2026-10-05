# A worktree a run creates after launch reads as an escape

Status: open

To: `share/doctor-ledger.json` `owners.workers`.

Purpose: `bin/worker-run` grants a run what it may write (`brief_add_dirs`, `brief_worktree_roots`,
`resumed_add_dirs`); `bin/llm-doctor` reads a write outside the grants as `escaped` (ledger W3, W5, W7).

`claudeb-1791165484-91389-3bc4` (2026-10-05 04:58 +03:00, llm-legs `feat-suite-speed-gate-claudeb`),
told "work in your worktree only", ran `git worktree add .claude/worktrees/tmp-suite-speed-baseline-claudeb`
from the main checkout to time suites at HEAD, edited `tests/test_instruction_gate.sh` there and removed
it. W3 read regressed; its own causes (a prose-named task worktree, a resumed grant) did not recur.

The 2026-10-04 settlement kept a worktree created after launch ungranted by design, so every such leg
reads W3 regressed and W3 cannot prove. Decide: keep that (true escape; narrow W3 or give the class its
own row), or grant it. A grant tested at night 20261005T060033Z-052f, not landed: the floor lists
`git worktree list` of the workdir and each `ADD-DIR:`; at the end a transcript-named path under
`<listed checkout>/.claude/worktrees/<name>` whose worktree was not listed joins `meta.add_dirs`
(~15 lines in `persist_run_files`, one case in `tests/test_worker_run_attribution.sh`). Its risk: a
write into a worktree another chat created mid-run is hidden as well.
