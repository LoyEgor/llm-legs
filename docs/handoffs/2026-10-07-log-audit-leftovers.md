# Log audit leftovers (night 20261006T233611Z-7777, run harness-doctor-20261006T234242Z-1fa6)

Status: open — To: next night (Harness Doctor owner); each item names its repository and its ledger row `log_audit:<id>`.

The quotes were confirmed in `~/.cache/doctors/log-audit/runs/day-20261007T002540/chunk-*.md`.

1. **launch-gate-refusals-first-attempt** (claude-setup `agents/{claudeb,codex,gemini,grok}-worker.md`). 9 of 15 refusals:
   "the brief says `ACCOUNT: locomthebest`, so the launch passes `--account locomthebest`". The orchestrator
   puts `ACCOUNT:` in the relay's prompt next to `Brief file: <path>`, and the file it copies (`cat`/`cp` into
   `$BRIEF`) has no such line. The gate is right (worker-run reads only the file). The agent text "never rebuild
   them as flags" is wrong in that case. Fix: "pass `--account`/`--model` exactly as your prompt's `ACCOUNT:`/`MODEL:`
   lines say, and never one your prompt lacks". The gate accepts an equal flag, and worker-run only refuses a
   contradicting flag. The other 4 refusals were flags with no header line, which the same sentence covers.
2. **sleep-poll-loops-waiting** (claude-setup settings env + llm-legs `bin/worker-launch-gate.sh` `WAIT_CEILING=540`,
   `HARNESS_TIMEOUT_MAX`, agents' `--max 540`). Relays poll in 9-minute rounds because the chat's Bash cap is
   10 min. Claude Code honours `BASH_MAX_TIMEOUT_MS`, which worker-run now sets for claudeb workers (68e107ba).
   Set it in the chats' settings env and derive the gate's ceiling from it. That way one round covers most runs.
   Separately, logo-vectorizer-bench's throttle printed "all busy, 4 of 8 slots open": that repo should check this.
3. **wip-owner-misattribution** (claude-setup `hooks/edit-conflict-notice.sh`). The chat reported that "the edit
   hook had named them as the owner because they had been quiet for 44 minutes". The real owner's writes came
   from a worker in its own worktree. `bin/land`'s attribution was right; the second wrong claim came from a
   chat's ad-hoc journal query. Confirm the guess path and key it by the checkout the write landed in.
4. **worker-on-exhausted-account** (llm-legs `bin/worker-pick`, `bin/worker-run`). This works as specified:
   selection allowed below 100 %, one reroute, and a resumed session stays on its account. Parallel lanes pinned
   to one `ACCOUNT:` all hit the wall together. Proposal: worker-pick also counts each account's live runs when
   it ranks, so N lanes are not spent from one 93 % window.
5. **night-debt-passes-not-capped** (llm-legs `bin/night-run`, review-bench). `docs/night-run.md` step 5 says one
   fit round and one bugs round per debt job; the orchestrator ran more. Also, a resume adds `debt-<n>` whenever
   none is pending (`resume_night`). Proposal: review-bench refuses a second debt round of the same kind for one
   night job unless the first one ended with no findings file.
6. **shared-ledger-landing-conflicts** (llm-legs `share/harness-ledger.json`,
   `tests/test_harness_doctor.sh` PINNED). Every fixer appends rows and repins the calibration list. Proposal: a
   row-wise merge driver (`.gitattributes` + `share/`) for the ledgers, and a PINNED list derived per row, not
   one hand-kept line.
7. **limit-reset-no-auto-resume** (chat «Updater doctor», 2026-10-06 10:40-13:21). The wake-up fired before
   that chat's own reset. Check the resume timer (claude-setup `hooks/resume-timer-guard.sh`) and
   `llm-reset-redeem` against the account's `resets_at`.
8. **browser-worker-launch-failures**. This is the work of the chat «Оптимизация работы с браузерами DIA и Chrome.».
   Its fixes (a4e0b030, f877336c, 36cf6f25, f1a98bde) and the leftover branches `fix/browser-*` land tonight.
   No probe launch confirmed them. Proof is one `worker-run browse` probe per target after landing.
9. Ruled out as harness bugs, dismissal proposed to the owner. These were model conduct with no component:
   **overbuilt-before-asking**, **reports-jargon-and-unverified-claims**. Also **memory-guard-lane-pause**:
   the guard killed a logo-bench lane as designed, and its 192-minute pause was that lane's resume under load
   164.
