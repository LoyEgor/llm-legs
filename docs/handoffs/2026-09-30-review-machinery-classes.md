# Hand-off: the five review machinery classes, triaged

Status: open

For the chat «Review-bench improvements phase 4» (`share/doctor-ledger.json` `owners.reviewers`),
which owns review-bench `share/rbench/debt.py` `DOCTOR_CHECKS`. Written 2026-09-30 by night fixer
run `llm-reviewers-20260930T001641Z-5fac` from the snapshot of 2026-09-29 22:47 local (`total` 400).
Nothing here was dismissed; every ledger row stays `open` (M5 is new, for `debt_line`).

## Yours to decide

2. **M1 `anchors` (324).** 321 are `gap-stale` of ONE chat, «Vector Magic macOS ARM migration», in
   `logo-vectorizer-bench`: 299 `hash-cap` gaps (a bench tree with 164+ dirty result files; each
   Bash call records one gap with a different detail, so `doctor_check_row` keys each apart),
   13 `pre-missing`, 7 `touch-failed`. The other 3 are `claim-expired` claims of round
   `20260923T105514Z-950f26a`, which was never recorded, so `anchor_round` never released them.
   Proposal: key `gap-stale` rows per (session, kind, checkout) as `review-anchors gaps` groups
   them, so one cause is one row; and release a round's claims when it is abandoned. Both lower the
   count, so they are yours, not a fixer's.
3. **`debt_line` (3, new row M5).** The same gaps seen per session: «Vector Magic macOS ARM
   migration» (the hash-cap gaps above), «LLM Doctor меню refactoring» (`fixer-missing` for round
   `20260924T222306Z-8877b05`, finding 18 has no fixer row) and «Harness Doctor» (`pre-missing` for
   the synthetic `toolu_probe_timing`: a latency probe fed the live hook, which recorded a gap
   against the live store). No machinery bug found; the probe gap is settled by an amnesty anchor.
4. **M3 `debt_scope` (30).** `debt_round_suspect` flags a round when shared lines exceed half of it
   or any unanchored fix line exists. In a checkout many chats share, that is most debt rounds (for
   example the «Чистка» round at 20 824 lines, 99.9 % shared). Unanchored fix lines also follow from
   hand-written fixer rows: a chat that fixes a round itself leaves no `fix:R:*`
   anchor. Decide whether the class measures a defect or the normal shape of a shared checkout.
5. **M4 `integrity` (8).** Two kinds: concurrent edits by other chats in the shared checkout
   (`docs/harness-doctor-design.md`, `bin/harness-doctor` in llm-legs), which the record itself
   calls an observation with actor `unknown`; and ignored files a tool writes on its own —
   `claude-setup/skills/synced/*/.last-complete-round` and `manifest.json` (the Claude app's skill
   sync, gitignored) and `.nx/workspace-data/d/daemon.log` (the Nx daemon). Proposal: leave ignored
   paths out of the class, or add those two to `DOCTOR_INTEGRITY_NOISE_RE`. That narrows the class,
   so it is yours.

## 2026-10-01, night fixer run `llm-reviewers-20261001T020642Z-32c1`

The same five classes, no machinery bug found. Rows: M1 465, M2 32, M3 30, M4 11, M5 1 at launch;
12/12/12/11/1 in the 23:27 snapshot.

- **The «Vector Magic macOS ARM migration» chat dominates M1 and M5.** `logo-vectorizer-bench`
  tracks 12 files and leaves 14 107 bench outputs (`results/lanes`, `results/ab`, `tracers/*`)
  untracked and unignored. `review-debt <session>` for that chat reads LINES=1667946 FILES=14186
  WHY=gap and took 165 s (cached) and 106 s (`--no-cache`), past `doctor_debt_line_rows`' 60 s
  timeout, so M5 now shows it as `review-debt answered 'TimeoutExpired'`. The cure is an ignore list
  in that repository, which is that chat's work. Raising the timeout would hide it, so it stays.
- **M4 adds a third kind of ignored write:** a night fixer worktree under claude-setup
  `.claude/worktrees/` changed during a claude-setup review. It is covered by the item 5 proposal
  (leave ignored paths out of the class).

## 2026-10-02, night fixer run `llm-reviewers-20261002T093027Z-53a0`

Rows at launch: M1 788, M2 1, M3 27, M4 2, M5 1. Third night with no machinery bug; items 2-5
still wait for the owner.

- **M2 settled, not handed off.** Round `20261001T093742Z-64ee7b1` (llm-legs, «Чистка», chat dead):
  its one finding is resolved in main and was recorded fixed through `review-bench record`.
- **Item 2, claims half, done.** The 3 expired claims of `20260923T105514Z-950f26a` (llm-legs,
  no bench dir, chat dead) were released with `review-anchors release --round`. Releasing an
  abandoned round's claims automatically is still the owner's proposal.
- **Correction to item 3.** The `toolu_probe_timing` gap was never settled: the newest llm-legs
  amnesty is from 2026-09-16 and the gap from 2026-09-28. No amnesty was written, because one would
  settle every session's llm-legs gaps. The gap leaves `check` once its session has been dead for 7
  days (`GAP_DEAD_WINDOW`).
- **The logo-vectorizer-bench tree now spills over.** It is past 20 000 dirty paths. A live
  llm-legs cleanup chat («Сделай чистку») got a `hash-cap` gap (WHY=gap, M5) from one Bash call in
  that tree. 710 of the 788 M1 rows are `capped paths changed` gaps, one per Bash call, written by
  claude-setup `hooks/lib/review-journal.sh:583`. Proposal for the owner: record that gap once per
  (session, checkout) in the hook, not once per call. That change is in claude-setup and lowers a
  count, so it is yours.

## 2026-10-03, night fixer run `llm-reviewers-20261003T042533Z-1621`

Rows: M1 788 (all the logo-vectorizer-bench chat), M2 0, M3 27, M4 1, M5 3. No new machinery bug.

- **M5, new gap kind.** «Updater doctor» reads WHY=gap from one `run-fold` gap: worker run
  `claudeb-1790995896-49842-2cf6` snapshotted the chat's claude-setup worktree `speed-doctor` as a
  family, and the chat removed it mid-run. llm-legs `bin/worker-run` `fold_run_anchors` files the gap
  but, unlike its workdir-gone branch, never folds the run in that family's store, so the run stays
  `folded: null` in claude-setup's store (no pid file, so never `run-dead`). Harmless today.
- **R1 floor on edited docs (your call).** A clean docs chunk was refused at 12 KB read against a
  22.8 KB floor: `docs/shared-invariants.md` rows run to 17 KB, so 24 changed lines are 152 KB of
  diff. The cell did check the claims against code. Pricing edited `.md` or only changed lines would
  lower the floor, so it is yours.
