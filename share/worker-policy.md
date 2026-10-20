# Worker routing policy

Which ACCOUNT to use is not a judgment call — `worker-pick` answers it under
`docs/routing-contract.md`, and the `ACCOUNT:` line under its ranked `NEXT` rows is the answer. The rows
below it are the top five ACCOUNTS across every vendor, several of one vendor included, so the
fallback after row 1 is read off the table rather than guessed. Which VENDOR is not a judgment call
either: in `auto` worker-pick ranks all vendors, and Egor's menu toggles are the only other say. What is left here is the part no table decides — how much
effort a task deserves, and the vendor shapes a brief has to know.

Delegating is the chat's own Bash, never a subagent: brief via Write, then ONE `worker-run run auto --brief <file> --workdir <dir>` with `run_in_background`: it picks as worker-pick ranks, starts, waits and prints the report its completion wakes the chat to read. `worker-run say <run-id> "<text>"` adds a mid-run note; a run with no live wait gets `worker-run wait <run-id> --report` in the background. Reviews: `review-bench wait <run-id>` in the background after the launch.

- Gemini/Antigravity (Flash) is Light only (Egor 2026-10-06): complex briefs and research go to a strong worker even if ranked first; `worker=gemini` selects it; base profile `main`, named ones isolated by `geminib`. A non-Flash slug (`argon`) runs on Egor's word only, where the account's list carries it, even under `gemini_workers=off`.
- The LIGHT class (Egor, 2026-09-06; vendor-neutral since 2026-09-17), in two roles: Research — `light-research` as a background Bash, a tracked read-only `worker-run` (role `research`); Edit — `worker-run start light` (picker role `light`). ADMISSION RULE, all three or it is not Light: the instruction fits one line without this chat's context; success is a mechanical predicate (a suite's exit code, a scoped diff, a grep count, resolvable citations); a stronger model could not do it visibly better. Git chores — commit, push, status, branches, worktrees — stay direct, and over a large dirty tree Light may only PROPOSE a path→group plan. Never Light: complex functions, gates and hooks, routing math, test assertions, money arithmetic. A Light edit writes straight into its workdir like any worker: no fence, no verify, no landing step — so unpausing Light Edit needs a new design first. Land-on-green is retired (2026-10-04; docs/handoffs/2026-09-20-review-findings-light-and-worker-run.md): a retry must journal every verdict durably from the first run, fence writes at the OS level from launch instead of diffing afterwards, and fix the run count that decides it. Neither role is closed by `<vendor>_workers=off`; pool membership, pause, walls and claims still apply. Each role's vendor and model live in ONE place, the `light_research` / `light_edit` rows of the worker-model toggle (`<vendor>[:<model>]`, set on Egor's ask; absent = the first gemini row of `worker_model_table`). With Light off (Egor's menu switch, `light_paused=on`), use the regular worker `worker-pick` names.
- Grok/SuperGrok is a full implementation worker selectable with `worker=grok`. It spends one weekly pool shared with Chat and Imagine, so a long run costs Egor more than the percentage suggests.
- Research runs search; a worker needs a `WEB: on` line at the very top of the brief (or `--web-search`); `WEB: off` turns research off.
- Code reviews: the tier and who fixes what are `~/.claude/docs/review-tiers.md`'s; cell composition comes from `review-bench tiers`, never from prose.

## Model and effort table

Source: `share/worker-model.sh` (`worker_model_table`); first model per vendor is the default.

| Vendor / model | Default effort | Brief efforts | Efforts requiring Egor's word | Model requires Egor's word |
| --- | --- | --- | --- | --- |
| claudeb / opus | high | high, xhigh | low, medium, max | no |
| claudeb / fable | low | low, medium, high | xhigh, max | yes |
| codex / astra | low | low, medium, high | xhigh | no |
| codex / sol | medium | medium, high | low, xhigh | yes |
| claudeb / sonnet | high | low, medium, high | — | no |
| claudeb / haiku | high | low, medium, high | — | yes |
| codex / luna, terra | medium | low, medium, high | — | no |
| gemini / each Flash slug of `geminib families --union` | high | high | — | no |
| gemini / each other slug | high | high | — | yes |
| grok / auto (the CLI's own default) | high | high, xhigh (those its default slug lists) | — | no |
| grok / each slug `grokb models` prints | high | high, xhigh (only those its `efforts` column lists) | — | no |

Effort defaults to `<vendor>_effort` in
`~/.claude/worker-model`, else the resolved model's table default. Write `EFFORT:` only to move
off that default within Brief efforts. Word efforts and word-only models (`fable`,
`sol`, `haiku`, `argon`) require Egor's ask in this chat; the brief never quotes it. A codex `MODEL:` names the
family word (codex `astra`, `sol`), which launches the newest slug `codexb models` lists; a full
slug is a deliberate pin and launches as written.
His cues «не парься / задача простая / не жги» lower effort within Brief efforts;
«подумай как следует / сложное» raise it there. A cheap model (sonnet, luna, terra) is a
`MODEL:` line for a simple task only; otherwise no `MODEL:` line. `worker-run` refuses anything outside both effort columns and the model
list (`EFFORT_REFUSED`, `MODEL_REFUSED`) before spending an account.
A brief that writes a second repository names it in its header, one `ADD-DIR: <absolute dir>` line
each: `worker-run` grants it as `--add-dir` and baselines it. It also grants, unasked, every
existing task worktree (`<repo>/.claude/worktrees/<name>`) the brief or a `*.md` it names gives by
path or as that template beside a named repository, and
every grant and repository workdir of the session a `RESUME <sid>:` first line continues (read
without `--resume`, a run id resolving to its session); from a main-checkout workdir, every
repository root the prose gives by absolute or `~/` path too. Anything else named only in prose is ungranted: writes there count as escaped. A writing run is refused in `$HOME`, where nothing is tracked.
A browser brief carries `BROWSER: chrome` (the account's own Chrome profile, the default) or
`BROWSER: yes` (Egor's Dia, never launched); `worker-run start` reads it itself — never repeat it as flags.
Its account comes from `worker-pick --role browser` (claude or codex, `<vendor>_workers=off` and the pin
never apply): copy its `ACCOUNT:` and run its `START:` line.
The canonical knob-to-agy mapping lives in `worker-run`.

## Brief sizing and test loop

- Cap a worker at **~8 findings or ~6 files**. Split a bigger fix pass by file cluster, one worker
  per cluster, parallel where the clusters do not touch each other — slices in the 15–25 min band
  beat one run that never returns.
- The test rule (when a worker runs which suites, when it adds a test) lives only in `worker-run`'s
  `BRIEF_PREAMBLE`, appended to every launched brief; a brief never repeats it. A worker never runs the
  full `tests/run-all`: the full run is the night's one background run at Close (`docs/night-run.md`).
- A worker never writes an always-loaded instruction file (global/project `CLAUDE.md`, `~/.claude/agents|commands|docs|skills|instructions|rules/*.md`): it returns `MD-PROPOSAL` and the chat audits and edits.
