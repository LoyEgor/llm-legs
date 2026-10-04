# Path-shape check spends a user lookup per path; claude-setup symlinks write llm-legs main

Status: done 2026-10-04 (item 2 on the branch; it acts after one post-land settings step)

To: `share/doctor-ledger.json` `owners.workers` and the claude-setup owner (`share/harness-ledger.json` `owner`).

Purpose: `bin/worker-run` `workdir_dirty_paths` lists the launch floor in the caller's foreground
before the supervisor detaches; `start` must return in seconds (ledger W6).

1. The `/*|~*|-*)` arm of llm-legs `bin/worker-run` `path_shape_ok` and claude-setup
   `hooks/lib/review-journal.sh` `rj_path_shape_ok` is tilde-expanded as user `*`: one directory-services
   lookup per call. 20k paths: 14.8 s, quoted (`/*|\~*|-*)`) 0.33 s, same verdicts (`~/x`, `~`,
   `~root/x` refused, `a~b` passes). logo-vectorizer-bench holds 33.6k untracked paths and a launch lists
   them twice, so `start` sat ~100 s and both 2026-10-02 23:44 gemini starts were interrupted mid-floor
   (`no exit: supervisor gone`). `tests/test_consistency.sh` pins the two arms equal, so the one-character
   change lands in both repositories at once; the night fixer had no claude-setup worktree.
2. claude-setup tracks 16 absolute symlinks into other repositories' main checkouts (for example
   `hooks/worker-run-backstop.sh` -> `/Volumes/Work/Projects/llm-legs/bin/…`). An edit through one in a
   claude-setup worktree writes llm-legs main: run `claudeb-1790933546-39728-1632` (night fixer
   harness-hooks-5607) did so for ten minutes and reverted it itself; the doctor counted it escaped (W5),
   correctly.

Acceptance: both arms quoted together and `test_consistency` green; a worktree edit cannot reach
another repository's main checkout through a tracked symlink.

## Settled 2026-10-04 («LLM Doctor меню refactoring», night sweep 20261004T003925Z-4646)

Item 2, claude-setup `hooks/worker-edit-guard.sh` (branch `fix/llm-doctor-handoffs-20261004`): a worker session's Edit, Write, MultiEdit,
NotebookEdit or shell write (`sed -i`, a redirect, `cp`) whose path crosses a symlink under its tree into
another checkout is denied with "work in its own repository's worktree, or have the run granted that
repository with an `ADD-DIR:` line"; a grant in the run's `meta.json` lets it through. A link within the tree,
a link loop, reading through a link, moving the link itself and interactive sessions pass; an edit that meets
no link forks no git. `tests/test_worker_edit_guard.sh`: 14 new checks red on the old hook; dropping the
escape check or the grant read turns them red again.

Post-land step (the live `~/.claude/settings.json` is not in the repository): add to `PreToolUse`
`{"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"~/.claude/hooks/worker-edit-guard.sh","timeout":5}]}`.
Its four wiring checks in `test_worker_edit_guard.sh` stay red until then; registering it before the branch
lands would run main's hook, which reads only Bash payloads.
