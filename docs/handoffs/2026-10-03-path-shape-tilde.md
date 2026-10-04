# Path-shape check spends a user lookup per path; claude-setup symlinks write llm-legs main

Status: done 2026-10-04 (item 2: shell writes guarded; Edit/Write left to the doctor by Egor's decision)

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

Item 2, claude-setup `hooks/worker-edit-guard.sh` (already on Bash for worker sessions): a worker's shell
write (`sed -i`, a redirect, `cp`) whose path crosses a symlink under its tree into another checkout is
denied with "work in its own repository's worktree, or have the run granted that repository with an
`ADD-DIR:` line"; a grant in the run's `meta.json` lets it through. A link within the tree, reading through a
link and moving the link itself pass. `tests/test_worker_edit_guard.sh`, red without the check.

Edit/Write stay unguarded by Egor's decision (2026-10-04): a hook on every Edit/Write of every session costs
about 40 ms per edit for one escape ever seen, and covers only claudeb workers (codex, gemini and grok edit
with their own tools). The LLM doctor's escape check (W5) still catches such a write after the fact. If it
recurs, remove the door instead: keep the 16 links out of git and create them in the main checkout only.
