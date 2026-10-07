# Tokenmap: detectors for spend that buys nothing

Status: open — To: «Token spending tracking and optimization»

From «Updater doctor», 2026-10-07, after Egor agreed that work for tokenmap goes to tokenmap.

## Context
- **Why:** Egor wants every token the harness spends without need to be found and cut.
- **What qualifies:** only the same result for less. Raw growth is load, never a defect (that week had +86% contexts), and model, effort and thinking are his alone.
- **What reads your output:** the Harness doctor's new Spend block (llm-legs branch feat/spend-doctor, landing soon). It reads `tracking.json` and audits one priced component per night: purpose → price → effect → a cheaper rewrite proven by replay.
- **The split:**
  - tokenmap measures and flags candidates;
  - the audit decides;
  - an exact repeat is mechanical;
  - a paraphrase or a language switch is only a candidate, which a Sonnet judge reads on a sample.
- **Night access:** token-map is a night helper repository since llm-legs 22dfebdb, so the night may extend it too.

## Detectors wanted
Each detector is a `tracking.json` section with a share of Claude spend, the Δ, a candidate count and a sample of candidates (file, session, line).

1. **Duplicate reads.** The same file read again in one context while its content is unchanged, or the same command re-run with an identical output. This is fully mechanical: compare the hash of the result.
2. **Hook-forced repeats.** After a hook block, a forced Stop re-answer or an injected note, the next output repeats what was already said. Example: english-gate made models rewrite a finished Russian reply in English.
   - An exact or near-exact repeat is mechanical.
   - A paraphrase or a language switch is a candidate.
3. **Cold restarts on one topic.** A new context, or a worker resume past the cache TTL, whose brief names the same files or task as a context that ended shortly before.
4. **Chunking that does not pay.** A fan-out (log-audit chunks, review cells, image takes) whose startup per chunk is larger than the chunk's own work.
5. **Delegation that retells.** A worker brief whose size is close to the delegated work, while the delegating chat's account had room to do the work itself.
6. **Outputs nobody reads.** Scheduled LLM jobs (launchd wrappers in `~/.local/libexec`, reports, digests): the cost per run, and whether any model or menu reads the output afterwards.
7. **Startup that is never used.** For each skill, MCP server, connector and deferred tool in the listing: its startup cost × contexts, against its invocations over the last 30 days.
8. **Frontier model on a small task.** Model and size per task. This one is shown only, never a cut: model choice is Egor's.

9. **Export which causes are avoidable.** Harness `share/spend.py` (llm-legs 90cae246) copies tokenmap's unavoidable cache re-write causes (`expired (1h+ idle)` and the others from FINDINGS §26). Put an `avoidable` flag on each cause row in `tracking.json`, so the doctor reads it rather than keeping a copy.

## Done when
- Each detector is in `tracking.json` with its own tests.
- The Token tracking submenu shows it.
- `docs/shared-invariants.md` row db still agrees.
