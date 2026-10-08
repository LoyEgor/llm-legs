# Tokenmap: detectors for spend that buys nothing

Status: done (token-map b044500, 93c2a59, cf68b86, 03057cb, 3f597e7; every row carries `candidate_count` and `candidates` with file, session, line) — To: «Token spending tracking and optimization»

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

1. **Duplicate reads.** Done in token-map b044500 (`Repeated reads`).
2. **Hook-forced repeats.** After a hook block, a forced Stop re-answer or an injected note, the next output repeats what was already said. Example: english-gate made models rewrite a finished Russian reply in English.
   - An exact or near-exact repeat is mechanical.
   - A paraphrase or a language switch is a candidate.
   - Done in token-map cf68b86 (`Hook-forced repeats`, Stop and SubagentStop re-answers classed exact, near, language switch or paraphrase; each candidate says whether it is mechanical). The subagent English gate made 139 near and 61 exact repeats since 2026-09-20; 0.1M this week.
3. **Cold restarts on one topic.** A new context, or a worker resume past the cache TTL, whose brief names the same files or task as a context that ended shortly before. — Done in token-map 93c2a59 (`Cold restarts on one topic`: a new chat or worker within 60 min of another context in the project ending that re-reads 3+ of its files; 1.3M a week; a resume of the same session stays under `Worker cold resumes`).
4. **Chunking that does not pay.** A fan-out (log-audit chunks, review cells, image takes) whose startup per chunk is larger than the chunk's own work. — Done in token-map 93c2a59 (`Chunks that do not pay`, with a per-chunk startup/work table by fan-out; 8.7M a week, the claudeb-worker relay wrapper 4.8M of it).
5. **Delegation that retells.** A worker brief whose size is close to the delegated work, while the delegating chat's account had room to do the work itself. — Done in token-map cf68b86 (`Delegation that retells`: a brief at least half of what the subagent and its worker spent beyond startup; 2 of 1,612 this week. Each candidate names the account; whether it had room is the audit's).
6. **Outputs nobody reads.** Scheduled LLM jobs (launchd wrappers in `~/.local/libexec`, reports, digests): the cost per run, and whether any model or menu reads the output afterwards. — Done in token-map cf68b86 (`Scheduled outputs nobody reads`: find-truth advisor, red team, end-report and daily note, 1.7M a week. All four only print, so whether a menu or Egor reads them is the audit's; transcripts show only that no model read a file they wrote).
7. **Startup that is never used.** Done in token-map b044500 (`Unused startup`, read by Spend's startup audits).
8. **Frontier model on a small task.** Model and size per task. This one is shown only, never a cut: model choice is Egor's. — Done in token-map 93c2a59 (`Frontier model, small task`: opus or fable contexts that ended within 5 requests, never toned; 4.0M a week).

9. **Export which causes are avoidable.** Harness `share/spend.py` (llm-legs 90cae246) copies tokenmap's unavoidable cache re-write causes (`expired (1h+ idle)` and the others from FINDINGS §26). Put an `avoidable` flag on each cause row in `tracking.json`, so the doctor reads it rather than keeping a copy. — Done in token-map 3e3b078; the Spend side is in `2026-10-07-harness-index.md`.
   - Resumes (llm-legs night 20261007T213650Z-7b98): `Worker cold resumes` counts sidechain 5-min re-writes inside a running worker (115 of 151 events in the 7 days to 2026-10-07, image-gen, gone since claude-setup 01f7357) as resumes; count main contexts only, and flag a cold resume compacted within 10 requests (8 of 36, 2.7M). — Done in token-map 03057cb (main contexts only; compacted-soon resumes are candidates).
   - Relay spawns (spend audit spawn:claudeb-worker, 2026-10-08): `Subagent spawns, by agent` prices only a relay's startup; its turns outside the procedure (poll loops, `ps`, `ls`, `llm-limits` beside `worker-run wait`) go unseen: 1444 of 10819 relay tool calls in 301 of 1177 relays, 7 days to 2026-10-07. — Done in token-map 3f597e7 (`Relay turns off procedure`; a Bash call that runs worker-run or review-bench anywhere is a step, so is a git check).
   - Instructions by agent type (spend audit `startup:CLAUDE.md + memory index`, 2026-10-08): `Unused startup` never prices the instruction files, so the 44% of that row (11.7M of 26.7M in the 7 days to 2026-10-07) loaded into relay subagents that only launch and wait showed nowhere until a hand join of `parts` with `requests.agent_type`; split the row by agent type and flag a subagent type that runs with them but never acts on them. — Done in token-map 03057cb (Startup `CLAUDE.md + memory index, by agent`); which type never acts on them stays the audit's call.
   - Startup parts (llm-legs feat/spend-audit-nested-claude-md): Spend splits the main-context startup by `Per context that loads it (avg)`, an average over carriers only, so `nested CLAUDE.md files` (6 of 1881 contexts, 59k of 948M limit tokens, 0.006 %) read 0.889 % and took 8.4M from the others; export each part's total (`comps`, already summed in `startup()`) as a section and let `share/spend.py` read it instead of scaling averages. — Done in token-map 03057cb (Startup `Main contexts, total by part`); `share/spend.py` splits by it since fix/debt-spend.
   - Listings (llm-legs feat/spend-audit-listings): `Unused startup` counts a slash command Egor typed as use, yet only a model `Skill` call needs the listing line — `skillOverrides: user-invocable-only` hides a slash-only entry for free (`loop`: one `/loop`, zero model calls since 2026-07-09); split slash-only from model use. — Done in token-map 3f597e7 (Unused startup `Typed only: user-invocable-only would hide them`, kind `skill (typed only)`).

## Done when
- Each detector is in `tracking.json` with its own tests.
- The Token tracking submenu shows it.
- `docs/shared-invariants.md` row db still agrees.
