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
- The LIGHT class (Egor, 2026-09-06; vendor-neutral since 2026-09-17), in two roles: Research — the `light-research` agent, a tracked read-only `worker-run` (role `research`); Edit — the `light-worker` relay (`worker-run start light`, picker role `light`). ADMISSION RULE, all three or it is not Light: the instruction fits one line without this chat's context; success is a mechanical predicate (a suite's exit code, a scoped diff, a grep count, resolvable citations); a stronger model could not do it visibly better. Git chores — commit, push, status, branches, worktrees — stay direct, and over a large dirty tree Light may only PROPOSE a path→group plan. Never Light: complex functions, gates and hooks, routing math, test assertions, money arithmetic. A Light edit writes straight into its workdir like any worker: no fence, no verify, no landing step — so unpausing Light Edit needs a new design first. Tried and closed, land-on-green (2026-09-19..2026-10-03, retired 2026-10-04): the brief's `SCOPE:` globs and `VERIFY:` command, a throwaway worktree `light-<run-id>`, and worker-run applying its diff to the shared checkout only when green. Verdict: it did not make a cheap model's edit trustworthy unread. The fence diffed git state inside the worktree while the worker could write anywhere (the shared checkout, `~/.claude`), so it kept growing — a sandbox-exec profile, a re-fence after VERIFY, base-commit tracking, launch refusals; six judge-confirmed findings on day two (docs/handoffs/2026-09-20-review-findings-light-and-worker-run.md) — and while Light was on (09-19..09-23, paused by Egor) most edits never landed: the report lines in 42 chat transcripts read roughly LANDED yes 42 / no 130 / conflict 52, VERIFY pass 46 / fail 34 / none 43, SCOPE escaped 70 (lines may repeat a run; the run dirs that held exact verdicts were pruned after 7 days). A retry must journal every verdict durably from the first run, fence writes at the OS level from launch instead of diffing afterwards, and fix the run count that decides it. Neither role is closed by `<vendor>_workers=off`; pool membership, pause, walls and claims still apply. Each role's vendor and model live in ONE place, the `light_research` / `light_edit` rows of the worker-model toggle (`<vendor>[:<model>]`, set on Egor's ask; absent = the first gemini row of `worker_model_table`), read through `worker_light_vendor` / `worker_light_model` in `share/worker-model.sh`. Egor's menu switch LLM Limits -> Light (`light_paused=on`) turns the whole class off as if it had never been built: a Light spawn is refused with the way around it (the regular worker relay `worker-pick` names), `worker-run start light` and `light-research` answer `OUTCOME: LIGHT_OFF`, a `--role research` run is a plain run on the vendor's own default model, and `worker-pick` prints `light:   off`.
- Grok/SuperGrok is a full implementation worker selectable with `worker=grok`; every account is a named profile isolated by `grokb`, and there is no usable base profile — the real `~/.grok` carries no login. It spends one weekly pool shared with Chat and Imagine, so a long run costs Egor more than the percentage suggests.
- Web search is ONE capability with one table (`share/web-search.sh`): a `--role research` run has it on for every vendor, a worker stays off until its brief's header block carries `WEB: on` (case-insensitive, one header line at the very TOP of the brief — anywhere else it is refused, not dropped — or the `--web-search` flag; `WEB: off` / `--no-web-search` turns a research run off, and a flag against the header refuses the launch). A vendor that cannot reach the state asked for refuses the launch naming those that can, instead of answering from memory or searching anyway; `worker-run start` and `worker-run report` name the resolved state as `WEB: on|off`.
- Code reviews: the tier and who fixes what are `~/.claude/docs/review-tiers.md`'s; cell composition comes from `review-bench tiers`, never from prose.

## Model and effort table

Source: `share/worker-model.sh` (`worker_model_table`); first model per vendor is the default.

| Vendor / model | Default effort | Brief efforts | Efforts requiring Egor's word | Model requires Egor's word |
| --- | --- | --- | --- | --- |
| claudeb / opus | high | high, xhigh | low, medium, max | no |
| claudeb / fable | low | low, medium, high | xhigh, max | yes |
| codex / astra (newest slug of the family `codexb models` lists) | low | low, medium, high | xhigh | no |
| codex / sol (likewise) | medium | medium, high | low, xhigh | yes |
| gemini / each Flash slug `geminib families` prints | high | high | — | no |
| gemini / pro | high | high | — | yes |
| grok / auto (the CLI's own default) | high | high, xhigh (those its default slug lists) | — | no |
| grok / each slug `grokb models` prints | high | high, xhigh (only those its `efforts` column lists) | — | no |

Use the first `NEXT` row's account. Effort defaults to `<vendor>_effort` in
`~/.claude/worker-model`, else the resolved model's table default. Write `EFFORT:` only to move
off that default within Brief efforts. Word efforts and word-only models (`fable`,
codex `sol`) require Egor's ask in this chat; the brief never quotes it. A codex `MODEL:` names the
family word (codex `astra`, `sol`), which launches the newest slug `codexb models` lists; a full
slug is a deliberate pin and launches as written.
His cues «не парься / задача простая / не жги» lower effort within Brief efforts;
«подумай как следует / сложное» raise it there. Anything in the word columns, models included, needs his
explicit word; otherwise no `MODEL:` line. Neither Codex model allows `max`.
`worker-run` mechanically enforces the union of both effort columns (`OUTCOME: EFFORT_REFUSED`)
and the model list (`OUTCOME: MODEL_REFUSED`) before spending an account; `/worker` refuses to
store values outside them. Word requirements are orchestrator policy.
A brief that writes a second repository names it in its header, one `ADD-DIR: <absolute dir>` line
each: `worker-run` grants it as `--add-dir` and baselines it. It also grants, unasked, every
existing task worktree (`<repo>/.claude/worktrees/<name>`) the brief or a `*.md` it names gives by
path or as that template beside a named repository, and
every grant and repository workdir of the session a `RESUME <sid>:` first line continues (read
without `--resume`); a main checkout or other directory named only in the prose is ungranted, and the
run's writes there count as escaped. A writing run is refused in `$HOME`, where nothing is tracked.
A browser brief (`BROWSER: yes`) may pin the Dia profile with a header `DIA-PROFILE: <dir or name>`
(`Profile 7`, `home dia`); without it `worker-run start --browser` takes the profile whose device
its `ACCOUNT:` sees, then the first healthy one from Dia's `last_used`.
The canonical knob-to-agy mapping lives in `worker-run`.

## Brief sizing and test loop

Every run past an hour spent 54–75% of its wall clock re-running full suites serially, and the two
that hit the old deadline died mid-work with nothing handed back (`scratchpad/long-runs/report.md`,
2026-09-04). Two rules follow, and only the first belongs in a brief:

- Cap a worker at **~8 findings or ~6 files**. Split a bigger fix pass by file cluster, one worker
  per cluster, parallel where the clusters do not touch each other — slices in the 15–25 min band
  beat one run that never returns.
- Each worker runs only the suites covering ITS change (`tests/affected <file>...`) plus the one red on
  the old code, never `tests/run-all`: workers queued 2–3 h for a full-run slot (night 2026-10-04).
  Inside a worker `tests/affected` drops the slow layer (`tests/slow-suites`) unless the worker edited
  that suite; the landing and the night's full run run it.
  The full run is the night's one background run at Close (`docs/night-run.md`).
- Do NOT repeat the loop rule in the brief: `worker-run` appends it to every launched brief
  (`BRIEF_PREAMBLE`), so a brief that spells it again only makes itself longer.
- A relay worker never writes an always-loaded instruction file (global/project `CLAUDE.md`, `~/.claude/agents|commands|docs|skills|instructions|rules/*.md`): both instruction gates refuse it with no retry and the tripwire puts back what a shell write grew; the worker returns the exact proposed text and its byte delta under `MD-PROPOSAL`, with the cut that pays for it, and the orchestrating chat audits and edits.
