# Tokenmap: detectors for spend that buys nothing

Status: open — the 2026-10-13 items (per-run delegation, rows past their cut) remain; the 2026-10-12 sub-items are in token-map b75220a (deny-forced reads, guard restores, skill-fork labels, quiet date); both gate-time items are Speed's per-hook floors

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
   - Quiet since a fix (worker-run-backstop.sh): ×42 `worse` with 0 blocks since 10-10. — Done in token-map b75220a (`quiet <date>` Δ after 24 h).
   - Review waits and retired relays: `procedure` row (worker-run by vendor, review-bench, wakes); Spend `turns:<step>`. — Done in token-map 7a24c2d, llm-legs 503e604e.
   - Gate time (`hook:worker-launch-gate.sh`): hook time, not tokens. — Speed's per-hook floors (speed-doctor-design C2).
   - Re-write causes: `MCP tool load`; a post-compaction request that cached nothing is no baseline. — Done in token-map e2c86b4.
   - Denied spawns: Startup `Denied spawns, by agent`. — Done in token-map ad0f177.
   - Deferred tool list: schemas by who loaded them; cut-at-source entries apart from Never used. — Done in token-map 2131945.
   - Deny-forced reads (`hook:instruction-write-gate.sh`): a Read of the denied path. — Done in token-map b75220a.
   - Skill forks (`spawn:subagent`): label by the parent's Skill, stream rows too. — Done in token-map b75220a (`skill:<name>`).
   - Gate wall time (`hook:review-flow-gate.sh`): the PreToolUse wait. — Speed's per-hook floors.
   - Guard workarounds (`hook:worker-git-guard.sh`): the cp + `git show` restore. — Done in token-map b75220a.
   - Per-run delegation (spend audit `turns:worker-run codex`, 2026-10-13): Δ ×17 is ×8 runs (128 vs 16) plus relay waits turned main-thread wakes; a per-run cell (~6.0k) would show the unit Δ.
   - Rows past their cut (spend audit `hook:worker-relay-hold.sh`, `spawn:grok-worker`, 2026-10-13): both removed at source 2026-10-09 (llm-legs ee185fa8) yet still due for audit while the 7d window holds pre-cut days; a component whose source is gone should read `cut at source`, not rank.

## Done when
- Each detector is in `tracking.json` with its own tests.
- The Token tracking submenu shows it.
- `docs/shared-invariants.md` row db still agrees.
