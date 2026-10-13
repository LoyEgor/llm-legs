# Tokenmap: detectors for spend that buys nothing

Status: open (the item-9 sub-items with no Done mark, added 2026-10-12; the 2026-10-10 ones settled 20261012T005404Z-e2f7) — To: «Token spending tracking and optimization»

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
   - Auto-memory prompt section: carved into `CLAUDE.md + memory index` from `prompt_snapshot`. — Done in token-map 1869303.
   - Stop re-answers: the forced turn bills the hook only while it keeps to the procedure; its waits' wakes bill it too. — Done in token-map 1869303.
   - Quiet since a fix (re-audit 2026-10-12, worker-run-backstop.sh): 0 blocks since 10-10T02:13Z, yet the row reads ×42 `worse` until the window rolls (10-17); a per-row last-block date would show it.
   - Review waits and retired relays: `procedure` row (worker-run by vendor, review-bench, wakes); Spend `turns:<step>`. — Done in token-map 7a24c2d, llm-legs 503e604e.
   - Gate time (spend audit `hook:worker-launch-gate.sh`, 2026-10-12): cost is hook time (749 floor events in 10 days), not tokens.
   - Re-write causes: `MCP tool load`; a post-compaction request that cached nothing is no baseline. — Done in token-map e2c86b4.
   - Denied spawns: Startup `Denied spawns, by agent`. — Done in token-map ad0f177.
   - Deferred tool list: schemas by who loaded them; cut-at-source entries apart from Never used. — Done in token-map 2131945.
   - Deny-forced reads (spend audit `hook:instruction-write-gate.sh`, 2026-10-12): 10 of the 24 true shell-write denials in 7 d were followed by a full Read of the denied file (the Edit route needs it), priced as `tool call: Read`; charge a Read that follows a deny and names its path to the hook.
   - Skill forks (spend audit `spawn:subagent`, 2026-10-12): `subagent` is the fallback for a sidechain with no `attributionAgent`; all 49 of the 7 d are Claude Code's forked `/code-review` in review-bench skill cells: label them by the parent's Skill name. Pre-10-09 forks sit in `raw-events` rows with `agent_type` NULL, which `SUB_CLAUDE` drops, so the row reads `Δ new` on old load.
   - Gate wall time (spend audit `hook:review-flow-gate.sh`, 2026-10-12): its token price is refusals only (see its ledger row); its cost now is the PreToolUse wait on every Bash call, which only Speed's hook floors see.
   - Guard workarounds (spend audit `hook:worker-git-guard.sh`, 2026-10-12): a block prices the denied call alone; the cp + `git show HEAD:<f> >` restore a worker runs next (53 blocks in 52 sessions, 7 d) books as plain Bash; charge it to the hook as Hook-asked calls do.
   - Per-run delegation (spend audit `turns:worker-run codex`, 2026-10-13): Δ ×17 is ×8 runs (128 vs 16) plus relay waits turned main-thread wakes; a per-run cell (~6.0k) would show the unit Δ.
   - Rows past their cut (spend audit `hook:worker-relay-hold.sh`, `spawn:grok-worker`, 2026-10-13): both removed at source 2026-10-09 (llm-legs ee185fa8) yet still due for audit while the 7d window holds pre-cut days; a component whose source is gone should read `cut at source`, not rank.

## Done when
- Each detector is in `tracking.json` with its own tests.
- The Token tracking submenu shows it.
- `docs/shared-invariants.md` row db still agrees.
