# Worker routing policy

Which ACCOUNT to use is not a judgment call — `worker-pick` answers it under
`docs/routing-contract.md`, and the `ACCOUNT:` line under its ranked `NEXT` rows is the answer. The rows
below it are the top five ACCOUNTS across every vendor, several of one vendor included, so the
fallback after row 1 is read off the table rather than guessed. Which VENDOR is not a judgment call
either: in `auto` the workers pin tier leads, then `[five-hour deferral, fresh claim, late auth, −budget, name]` across all vendors, and Egor's
menu toggles are the only other say. What is left here is the part no table decides — how much
effort a task deserves, and the vendor shapes a brief has to know.

- Gemini/Antigravity is a full implementation worker selectable with `worker=gemini`; its base profile is `main`, and named profiles are isolated by `geminib`. Every Gemini leg — worker, research, review cell — runs at `high` and at nothing else: an `EFFORT:` line below it is raised, with one stderr note, rather than refused. The default model is the newest Flash family `geminib families` prints; the other names are the other slugs it prints, `pro` on Egor's word only.
- Capacity fallback, one mechanism for every Gemini consumer, in `bin/geminib`: on a 503 `No capacity available for model` the run relaunches one family down the Flash families `geminib families` prints, effort unchanged — marks the starved family for `GEMINIB_CAPACITY_HOLD_S` (default 600 s) so the next launch skips it and tries it again once the hold lapses, and names the served model on stderr as `geminib: model <slug>` (`GEMINIB_CAPACITY_FALLBACK=0` switches it off).
- A consumer that resolves the agy binary itself and runs it under its own sandbox HOME — a review-bench cell — reaches the same mechanism through `geminib agy-launch --agy <path> -- <agy args...>`, which sets no environment of its own and keeps its markers and default logs under `GEMINIB_CACHE_DIR`.
- The LIGHT class (Egor, 2026-09-06; vendor-neutral since 2026-09-17), in two roles: Research — the `light-research` agent, a tracked read-only `worker-run` (role `research`); Edit — the `light-worker` relay (`worker-run start light`, picker role `light`). ADMISSION RULE, all three or it is not Light: the instruction fits one line without this chat's context; success is a mechanical predicate (a suite's exit code, a scoped diff, a grep count, resolvable citations); a stronger model could not do it visibly better. Git chores — commit, push, status, branches, worktrees — stay direct, and over a large dirty tree Light may only PROPOSE a path→group plan. Never Light: complex functions, gates and hooks, routing math, test assertions, money arithmetic. A Light edit brief carries `SCOPE: <glob>...` and may carry `VERIFY: <command>`, which worker-run checks after the run before it lands the run's worktree diff on the shared checkout — `--recipe <name> --set k=v` composes both from `share/light-recipes/`. One repository and one round: `--add-dir` and `--resume` are refused at launch, the fence is the worktree's own git state against the commit it was cut from, and the diff lands only when the run ended green with every touched path inside SCOPE and VERIFY not red — a follow-up is a NEW Light edit, never a RESUME. Neither role is closed by `<vendor>_workers=off`; pool membership, pause, walls and claims still apply. Each role's vendor and model live in ONE place, the `light_research` / `light_edit` rows of the worker-model toggle (`<vendor>[:<model>]`, set via `/worker`; absent = the first gemini row of `worker_model_table`), read through `worker_light_vendor` / `worker_light_model` in `share/worker-model.sh`.
- Grok/SuperGrok is a full implementation worker selectable with `worker=grok`; every account is a named profile isolated by `grokb`, and there is no usable base profile — the real `~/.grok` carries no login. It spends one weekly pool shared with Chat and Imagine, so a long run costs Egor more than the percentage suggests.
- Web search is ONE capability with one table (`share/web-search.sh`): a `--role research` run has it on for every vendor, a worker stays off until its brief's header block carries `WEB: on` (`WEB: off` turns a research run off), and a vendor that cannot search refuses the launch instead of answering from memory.
- Code reviews: the chat picks the tier itself (task importance first, then diff complexity; T0 is the floor) and cell composition comes from `review-bench tiers`, never from prose; the human-side rules live in `~/.claude/docs/review-tiers.md`.

## Model and effort table

Source: `share/worker-model.sh` (`worker_model_table`); first model per vendor is the default.

| Vendor / model | Default effort | Brief efforts | Efforts requiring Egor's word | Model requires Egor's word |
| --- | --- | --- | --- | --- |
| claudeb / opus | high | high, xhigh | low, medium, max | no |
| claudeb / fable | low | low, medium, high | xhigh, max | yes |
| codex / gpt-6-astra | low | low, medium, high | xhigh | no |
| codex / gpt-5.6-sol | medium | medium, high | low, xhigh | yes |
| gemini / each Flash slug `geminib families` prints | high | high | — | no |
| gemini / pro | high | high | — | yes |
| grok / auto (the CLI's own default) | high | high, xhigh | — | no |
| grok / each slug `grokb models` prints | high | high, xhigh | — | no |

Use the first `NEXT` row's account. Effort defaults to `<vendor>_effort` in
`~/.claude/worker-model`, else the resolved model's table default. Write `EFFORT:` only to move
off that default within Brief efforts. Word efforts and word-only models (`fable`,
`gpt-5.6-sol`) require Egor's ask in this chat; quote nothing but his ask.
His cues «не парься / задача простая / не жги» lower effort within Brief efforts;
«подумай как следует / сложное» raise it there. Anything in the word columns, models included, needs his
explicit word; otherwise no `MODEL:` line. Neither Codex model allows `max`.
`worker-run` mechanically enforces the union of both effort columns (`OUTCOME: EFFORT_REFUSED`)
and the model list (`OUTCOME: MODEL_REFUSED`) before spending an account; `/worker` refuses to
store values outside them. Word requirements are orchestrator policy.
The canonical knob-to-agy mapping lives in `worker-run`.

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
