# Worker routing policy

Which ACCOUNT to use is not a judgment call — `worker-pick` answers it under
`docs/routing-contract.md`, and the `ACCOUNT:` line under its ranked `NEXT` rows is the answer. The rows
below it are the top five ACCOUNTS across every vendor, several of one vendor included, so the
fallback after row 1 is read off the table rather than guessed. Which VENDOR is not a judgment call
either: in `auto` a usable workers pin leads, then `[five-hour deferral, fresh claim, late auth, −budget, name]` across all vendors, and Egor's
menu toggles are the only other say. What is left here is the part no table decides — how much
effort a task deserves, and the vendor shapes a brief has to know.

- Use Codex effort `medium` for ordinary tasks and `high` for genuinely complex work.
- Gemini/Antigravity is a full implementation worker selectable with `worker=gemini`; its base profile is `main`, and named profiles are isolated by `geminib`.
- The LIGHT class (Egor, 2026-09-06): work whose error is cheap and whose result is verified by the caller — today only read-only research, fan-out search and file-spanning lookups — goes to the light model, currently Gemini 3.8 Flash through the native `gemini-research` agent (role `research`, independent of the worker toggle and the workers/reviewers switches). It is not a worker and edits nothing. The Agent gate enforces it: on a Fable session an `Explore`/`general-purpose` spawn is rewritten into `gemini-research` (`bin/worker-limit-gate.sh`), so the class is not a choice the model makes. Everything else — implementation, review triage, gates, anything whose mistake later burns other models' tokens — stays with the strong models; saving is rational only where a mistake is cheap. The light model is named in ONE place, `bin/gemini-research` (`--model`), and changes there.
- Grok/SuperGrok is a full implementation worker selectable with `worker=grok`; every account is a named profile isolated by `grokb`, and there is no usable base profile — the real `~/.grok` carries no login. It spends one weekly pool shared with Chat and Imagine, so a long run costs Egor more than the percentage suggests.
- **A worker runs the one model Egor named for its vendor, and nothing else.** claudeb `opus`, codex `gpt-6-astra`, gemini `flash38` (Gemini 3.8 Flash, his call of 2026-09-04 — the review cells keep Pro, the worker does not), grok `auto` (`grok-4.6`, the one model it has). No sonnet, haiku or fable; no Terra or Luna; no other flash family. A worker is dispatched to spend another account's quota on real work, and a run that comes back needing redoing costs more than the cheap model saved. `share/worker-model.sh` holds the list, `worker-run` refuses anything else with `OUTCOME: MODEL_REFUSED` before an account is spent, and the `/worker` toggle refuses to store one — so a `MODEL:` line in a brief can only ever repeat what the vendor already runs, and belongs nowhere. If a task really seems to want another model, that is a question for Egor.
- Use the account and effort exactly as the first `NEXT` row prints them; a per-task `EFFORT:` override belongs in the brief. The canonical knob-to-agy mapping lives in `worker-run`.
- Code reviews: the chat picks the tier itself (task importance first, then diff complexity; T0 is the floor) and cell composition comes from `review-bench tiers`, never from prose; the human-side rules live in `~/.claude/docs/review-tiers.md`.

## Brief sizing and test loop

Every run past an hour spent 54–75% of its wall clock re-running full suites serially, and the two
that hit the old deadline died mid-work with nothing handed back (`scratchpad/long-runs/report.md`,
2026-09-04). Two rules follow, and only the first belongs in a brief:

- Cap a worker at **~8 findings or ~6 files**. Split a bigger fix pass by file cluster, one worker
  per cluster, parallel where the clusters do not touch each other — slices in the 15–25 min band
  beat one run that never returns.
- Each worker runs only the suites covering ITS cluster; one cheap worker runs every full suite once
  at the end (`tests/run-all`).
- Do NOT repeat the loop rule in the brief: `worker-run` appends it to every launched brief
  (`BRIEF_PREAMBLE`), so a brief that spells it again only makes itself longer.
- A relay worker never writes an always-loaded instruction file (global/project `CLAUDE.md`, `~/.claude/agents|commands|docs|skills|instructions|rules/*.md`): both instruction gates refuse it with no retry and the tripwire puts back what a shell write grew; the worker returns the exact proposed text and its byte delta under `MD-PROPOSAL`, with the cut that pays for it, and the orchestrating chat audits and edits.
