# cd-guard is replaced by Claude Code's own cwd reset

Status: open — To: Harness Doctor

From night 20261010T031219Z-4c4e run harness-speed-time-hooks; ledger row `speed-time-hooks-commit-report-owned-walk`.
cd-guard (claude-setup `hooks/cd-guard.sh`, PreToolUse Bash) runs on every Bash call (11.6k/day, 99 ms wall,
36 ms CPU mean at load ~200) and is charged 8.5 min/day of hook time for the calls it rewrites. Claude Code
2.1.296 does the same natively: with `CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR=1` every Bash call returns the
shell to the session's original directory, silently (the binary's reset skips its "Shell cwd was reset"
note when the flag is set). No hook, no subshell rewrite, no deny for forks or review launches.

Steps, in order (a relay worker may not write `~/.claude/settings.json`):
1. `~/.claude/settings.json`: add `"CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR": "1"` under `env` and drop the
   `~/.claude/hooks/cd-guard.sh` entry from PreToolUse Bash.
2. One live check: a Bash call `cd /tmp`, then `pwd` in the next call prints the project directory.
3. Then, in claude-setup: delete `hooks/cd-guard.sh` and `tests/test_cd_guard.sh`, and the cd-guard
   mentions in `hooks/comment-gate.sh` and `hooks/lib/review-journal.sh`; `tests/test_hook_time.sh` copies
   its `hook-time.sh` line out of `hooks/cd-guard.sh`, so point it at another hook that sources it.
   `~/.cache/claude-cd-guard` unlock files go with it. In llm-legs, reword the cd-guard clause of the
   `share/statusline-workdir.jq` comment (a `(cd /path && cmd)` call stays input it must parse). The
   cd-guard rows in `tests/test_speed_doctor.sh`, `tests/test_time_budget.sh` and
   `tests/fixtures/harness-calibration/` are recorded data under a hook name, not callers: they stay.
   Step 2 also checks that EnterWorktree still moves a session into its worktree.

Step 3 before step 1 makes every Bash call report a missing hook.
