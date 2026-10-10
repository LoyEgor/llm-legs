# Tokenmap: detectors for spend that buys nothing

Status: open (the last two lines of 9; done: token-map b044500, 93c2a59, cf68b86, 03057cb, 3f597e7; every row carries `candidate_count` and `candidates` with file, session, line) — To: «Token spending tracking and optimization»
Status: open (account switch on resume, last item; the rest done in token-map b044500, 93c2a59, cf68b86, 03057cb, 3f597e7) — To: «Token spending tracking and optimization»

From «Updater doctor», 2026-10-07.
Status: open (Auto-memory prompt and Denied spawns pending; the rest done in token-map b044500, 93c2a59, cf68b86, 03057cb, 3f597e7) — To: «Token spending tracking and optimization»

## Context
- **Why:** Egor wants every token the harness spends without need to be found and cut.
- **What qualifies:** only the same result for less. Raw growth is load, never a defect (that week had +86% contexts), and model, effort and thinking are his alone.
- **What qualifies:** only the same result for less. Raw growth is load, never a defect, and model, effort and thinking are his alone.
- **What reads your output:** the Harness doctor's Spend block. It reads `tracking.json` and audits one priced component per night: purpose → price → effect → a cheaper rewrite proven by replay.
- **What reads your output:** the Harness doctor's new Spend block. It reads `tracking.json` and audits one priced component per night: purpose → price → effect → a cheaper rewrite proven by replay.
- **The split:**
  - tokenmap measures and flags candidates;
  - the audit decides;
  - an exact repeat is mechanical;
  - a paraphrase or a language switch is only a candidate, which a Sonnet judge reads on a sample.
- **Night access:** token-map is a night helper repository, so the night may extend it too.

## Detectors wanted
Each detector is a `tracking.json` section with a share of Claude spend, the Δ, a candidate count and a sample of candidates (file, session, line).

1. **Duplicate reads.** Done in token-map b044500 (`Repeated reads`).
2. **Hook-forced repeats.** After a hook block, a forced Stop re-answer or an injected note, the next output repeats what was already said.
   — Done in token-map cf68b86 (`Hook-forced repeats`: exact, near, language switch or paraphrase).
2. **Hook-forced repeats.** After a hook block, a forced Stop re-answer or an injected note, the next output repeats what was already said. — Done in token-map cf68b86 (`Hook-forced repeats`: exact, near, language switch or paraphrase).
3. **Cold restarts on one topic.** A new context, or a worker resume past the cache TTL, whose brief names the same files or task as a context that ended shortly before. — Done in token-map 93c2a59 (`Cold restarts on one topic`).
4. **Chunking that does not pay.** A fan-out (log-audit chunks, review cells, image takes) whose startup per chunk is larger than the chunk's own work. — Done in token-map 93c2a59 (`Chunks that do not pay`).
5. **Delegation that retells.** A worker brief whose size is close to the delegated work, while the delegating chat's account had room to do the work itself. — Done in token-map cf68b86 (`Delegation that retells`; whether the account had room is the audit's).
6. **Outputs nobody reads.** Scheduled LLM jobs (launchd wrappers in `~/.local/libexec`, reports, digests): the cost per run, and whether any model or menu reads the output afterwards. — Done in token-map cf68b86 (`Scheduled outputs nobody reads`; whether a menu or Egor reads them is the audit's).
2. **Hook-forced repeats.** Done in token-map cf68b86 (`Hook-forced repeats`: exact, near, language switch or paraphrase).
3. **Cold restarts on one topic.** Done in token-map 93c2a59 (`Cold restarts on one topic`).
4. **Chunking that does not pay.** Done in token-map 93c2a59 (`Chunks that do not pay`).
5. **Delegation that retells.** Done in token-map cf68b86 (`Delegation that retells`; whether the account had room is the audit's).
6. **Outputs nobody reads.** Done in token-map cf68b86 (`Scheduled outputs nobody reads`; whether a menu or Egor reads them is the audit's).
7. **Startup that is never used.** Done in token-map b044500 (`Unused startup`, read by Spend's startup audits).
8. **Frontier model on a small task.** Model and size per task. This one is shown only, never a cut: model choice is Egor's. — Done in token-map 93c2a59 (`Frontier model, small task`: opus or fable contexts that ended within 5 requests, never toned).

9. **Export which causes are avoidable.** Harness `share/spend.py` (llm-legs 90cae246) copies tokenmap's unavoidable cache re-write causes (`expired (1h+ idle)` and the others from FINDINGS §26). Put an `avoidable` flag on each cause row in `tracking.json`, so the doctor reads it rather than keeping a copy. — Done in token-map 3e3b078; the Spend side is in `2026-10-07-harness-index.md`.
   - Account switch on resume (spend audit `rewrites:idle 5-60min`, 2026-10-10): prompt cache is per org, so a resume on another account reads only the cross-org system prefix (8-25k) and re-writes the rest, filed as `idle 5-60min` or `unexplained`. All 6 such re-writes over 1k in the 7 days to 10-10 (1.86M) follow a `credential_org` attachment naming a new org; same-org resumes in that window kept the cache. Track the org per context (the `credential_org` attachment) and file it as an avoidable `account switch` cause ahead of the idle ones.
9. **Export which causes are avoidable.** Harness `share/spend.py` (llm-legs 90cae246) copies tokenmap's unavoidable cache re-write causes (`expired (1h+ idle)` and the others from FINDINGS §26). Put an `avoidable` flag on each cause row in `tracking.json`, so the doctor reads it rather than keeping a copy. — Done in token-map 3e3b078.
   - Resumes: count main contexts only; flag a cold resume compacted within 10 requests. — Done in token-map 03057cb (main contexts only; compacted-soon resumes are candidates).
   - Relay turns outside the procedure. — Done in token-map 3f597e7 (`Relay turns off procedure`).
   - Instructions by agent type. — Done in token-map 03057cb (Startup `CLAUDE.md + memory index, by agent`); which type never acts on them stays the audit's call.
   - Startup part totals. — Done in token-map 03057cb (Startup `Main contexts, total by part`); `share/spend.py` splits by it since fix/debt-spend.
   - Listings: slash-only vs model use. — Done in token-map 3f597e7 (Unused startup `Typed only`).
   - Auto-memory prompt (spend audit `startup:CLAUDE.md + memory index`, 2026-10-09): the memory system-prompt section (~2.3k chars a context, there only while auto-memory is on) is priced inside `system + tools (not in total)`; attribute it to this part.
   - Stop re-answers (spend audit `hook:worker-run-backstop.sh`, 2026-10-10): every request of the forced turn bills the hook, so a turn that goes on to other work is over-priced (264k of its 527k was one turn fixing the hook); the wakes of the waits a block starts are billed nowhere.
   - Review waits (spend audit `spawn:review-waiter`, 2026-10-10): the relay is gone (llm-legs ee185fa8); a background `review-bench wait`'s completion wakes the chat as a main-thread turn no row attributes to review waits.
   - Skill listing per entry (spend audit 2026-10-10): `skills()` prices entries from the most common listing only, so account-only synced entries (com workers' `anthropic-skills:*`, `cowork-plugin-management:*`) are missing there; split per listing hash.
   - Hook-asked calls (spend audit `hook:context-nudge.sh`, 2026-10-10): the focus-file Write a nudge asks for (~1.4k/week) is priced as `tool call: Write`; charge a call that follows a hook's note and touches the path it names to that hook.
   - Retired relays (spend audit `spawn:codex-worker`, 2026-10-10): their successor, the chat's own `worker-run` start/wait/report turns, shows only in Bash `worker-run`, never per vendor.
   - No-op cd rewrites (spend audit `hook:cd-guard.sh`, 2026-10-10): 26% of cd calls cd into the cwd itself; split their cd-guard note out of `Injected text` so the owner can price allowing them untouched.

## Done when
- Each detector is in `tracking.json` with its own tests.
- The Token tracking submenu shows it.
- `docs/shared-invariants.md` row db still agrees.
   - Re-write causes (spend audit `rewrites:unexplained`, 2026-10-10): 73 of 76 turn-2 `unexplained` re-writes (1.73M of 1.91M in 7 d) follow a turn-1 ToolSearch load of `claude-in-chrome` tools (Claude Code re-writes the messages after it; built-in WebSearch loads never do): give them a cause of their own. A first post-compaction request that cached nothing still sets the next one's `prev_ctx`, so its first write books as a re-write (2026-10-09 night fixer, 55k).
   - Denied spawns (spend audit `spawn:gemini-worker`, 2026-10-10): an Agent call `worker-spawn-hook.sh` denies is no spawn, yet costs the parent its prompt and the re-issued brief; count denied Agent calls by type.
   - Deferred tool list (spend audit 2026-10-10): `surfacedNames` schemas Claude Code loads itself share the leaf with ToolSearch loads; a listing cut at source (Claude Docs, 10-05) still rides resumed contexts as live `Never used` spend; split both.
