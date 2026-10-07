# Log audit of night 20261006T233611Z-7777 (run harness-doctor-20261007T214015Z-24b7)

Status: open — To: next night (Harness Doctor owner); each item names its repository and its ledger row `log_audit:<id>`.

Quotes confirmed in `~/.cache/doctors/log-audit/runs/20261006T233611Z-7777/chunk-*.md`. From tonight on, carry gives a handoff
job every sweep repository's worktree, so items 1-3 need no other chat.

1. **hook-awk-multibyte-failure** (claude-setup). Since llm-legs 05430753 landed (2026-10-07 04:39) every
   `towc: multibyte conversion failure` comes from `hooks/dia-not-chrome.sh`: 31 events, error source lines 12 and 24
   of its awk programs at lines 45 and 66. Run them under `LC_ALL=C` like 05430753 did, with a test that feeds a
   Cyrillic command holding `chrome` (red on the old hook). Also `ignored null byte` from `limits-triage-nudge.sh:39`,
   `worker-limit-gate.sh:37` and `cd-guard.sh`: drop NULs (`tr -d '\0'`) before the command substitution.
2. **relay-stop-leaves-worker-running** (claude-setup hook + llm-legs). `TaskStop` on a relay kills only the relay; the
   detached supervisor runs on by design (`ATTACH` re-adopts it). Add a PreToolUse `TaskStop` hook that maps the task id
   to the relay's tag file (`~/.cache/claude-worker-tags/<session>/<agent>`, `run=`) and runs `worker-run stop <run>`.
3. **debt-scope-double-count** (review-bench, llm-legs `bin/night-run`). The debt survey at 04:51 counted merged night
   worktrees: review-bench prices every checkout of a family (`share/rbench/debt.py` `repo_debt_rows`) and night-run
   removes landed worktrees only at `finish`, after the debt pass. Either skip checkouts whose branch is merged into
   main when pricing, or remove a job's worktree when it lands; pick by a test on a fixture family.
4. Ruled out as harness bugs, dismissal proposed to the owner:
   - **night-worker-queue-wait**: the `night-workers` wait class journals every slot wait, and slots are paced by
     load as settled in `2026-10-06-speed-floors.md`.
   - **detached-chain-dies-with-builder**: worker-run ends every process carrying the run's `WORKER_RUN_ID` at run end
     (8a5f5a80), as designed. For the chat «Vector Magic macOS ARM migration»: a builder brief starts a chain meant to
     outlive the builder as `env -u WORKER_RUN_ID nohup … &`.
