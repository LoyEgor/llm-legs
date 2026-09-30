# Hand-off: the five review machinery classes, triaged

Status: open

For the chat «Review-bench improvements phase 4» (`share/doctor-ledger.json` `owners.reviewers`),
which owns review-bench `share/rbench/debt.py` `DOCTOR_CHECKS`. Written 2026-09-30 by night fixer
run `llm-reviewers-20260930T001641Z-5fac` from the snapshot of 2026-09-29 22:47 local (`total` 400).
Nothing here was dismissed; every ledger row stays `open` (M5 is new, for `debt_line`).

## Fixed in this run

`closure_pending` (M2) counted rounds whose stored `closure` word was stale: 5 of the 35
(`20260916T233511Z-de8379a`, `20260925T005220Z-e7a8840`, `20260927T151347Z-ff2b386`,
`20260927T172301Z-99a590c`, `20260929T043901Z-3aa6fef`) have a fixer row for every confirmed
finding, but `closure` is written only by a fold (`review-anchors run-fold`, `record`), and rows a
chat appends to `<bench>/verdicts.jsonl` by hand never rewrite it. `doctor_pending_rows` now skips a
round whose fixer rows settle every confirmed finding (review-bench branch
`night/20260930T001419Z-8480/llm-reviewers-20260930T001641Z-5fac`, `share/rbench/debt.py`,
test `test_doctor_runs_its_checks`, red on the old code). Only the doctor read the stored word.

## Yours to decide

1. **M2 residue (30 rounds).** Real unfinished rounds: confirmed findings with no fixer row, the
   oldest from 2026-09-16. The class does what it says; whether they close `--nofix` is Egor's or a
   span's decision (`review-anchors-contract.md` table), and a fixed-pending row would hide them.
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
   hand-written fixer rows (item 0 above): a chat that fixes a round itself leaves no `fix:R:*`
   anchor. Decide whether the class measures a defect or the normal shape of a shared checkout.
5. **M4 `integrity` (8).** Two kinds: concurrent edits by other chats in the shared checkout
   (`docs/harness-doctor-design.md`, `bin/harness-doctor` in llm-legs), which the record itself
   calls an observation with actor `unknown`; and ignored files a tool writes on its own —
   `claude-setup/skills/synced/*/.last-complete-round` and `manifest.json` (the Claude app's skill
   sync, gitignored) and `.nx/workspace-data/d/daemon.log` (the Nx daemon). Proposal: leave ignored
   paths out of the class, or add those two to `DOCTOR_INTEGRITY_NOISE_RE`. That narrows the class,
   so it is yours.
