# Tokenmap: detectors for spend that buys nothing

Status: settled 20261014T013750Z-8004: per-run delegation, retry after a denial and the three gaps done in token-map e427b8b; rows past their cut closed, Spend components are Fee sources since llm-legs 5e55c09d, a removed source drops out of the index

From «Updater doctor», 2026-10-07.

## Context
- **Why:** Egor wants every token the harness spends without need to be found and cut.
- **What qualifies:** only the same result for less. Raw growth is load, never a defect (that week had +86% contexts), and model, effort and thinking are his alone.
- **What reads your output:** the Harness doctor's Spend block. It reads `tracking.json` and audits one priced component per night: purpose → price → effect → a cheaper rewrite proven by replay.
- **The split:** tokenmap measures and flags; the audit decides; an exact repeat is mechanical, a paraphrase or language switch only a candidate a Sonnet judge samples.

## Detectors wanted
Each detector is a `tracking.json` section with a share of Claude spend, the Δ, a candidate count and a sample of candidates (file, session, line).
1. **Duplicate reads.** Done in token-map b044500 (`Repeated reads`).
2. **Hook-forced repeats.** Done in token-map cf68b86.
3. **Cold restarts on one topic.** Done in token-map 93c2a59.
4. **Chunking that does not pay.** Done in token-map 93c2a59 (`Chunks that do not pay`).
5. **Delegation that retells.** Done in token-map cf68b86 (whether the account had room is the audit's).
6. **Outputs nobody reads.** Done in token-map cf68b86 (`Scheduled outputs nobody reads`; whether a menu or Egor reads them is the audit's).
7. **Startup that is never used.** Done in token-map b044500 (`Unused startup`, read by Spend's startup audits).
8. **Frontier model on a small task.** Shown only, never a cut. Done in token-map 93c2a59 (`Frontier model, small task`: opus or fable contexts that ended within 5 requests, never toned).
9. **Export which causes are avoidable.** Harness `share/spend.py` (llm-legs 90cae246) copies tokenmap's unavoidable cache re-write causes (`expired (1h+ idle)` and the others from FINDINGS §26). Put an `avoidable` flag on each cause row in `tracking.json`, so the doctor reads it rather than keeping a copy. — Done in token-map 3e3b078; the Spend side is in `2026-10-07-harness-index.md`.
   - Done or settled sub-items: `git log -p` of this file.
   - Gaps from 2026-10-13 on: `jq -r '.rows[] | select(.note | test("tokenmap gap:")) | .id' share/spend-ledger.json`; a done one gets `Done in token-map <sha>` in its row's note.

## Done when
- Each detector is in `tracking.json` with its own tests.
- The Token tracking submenu shows it.
- `docs/shared-invariants.md` row db still agrees.
