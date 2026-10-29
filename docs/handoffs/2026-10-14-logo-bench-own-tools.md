# Hand-off: logo-vectorizer-bench's own commands for its repeated scripts

Status: open
To: «Vector Magic macOS ARM migration»

Egor (2026-10-14): a job concentrated in one project is that project's; its command and hint go into its repository
(CLAUDE.md or a skill), never the harness. Three Speed rows are `/Volumes/Work/Projects/logo-vectorizer-bench`'s:

- `speed-adhoc-logo-verdict` (`adhoc/logo-verdict`): judge workers write 491 ad-hoc calls a day in 41 sessions
  (2026-10-13), 15 worker-min/day, launched by `results/lanes/coord/tools/judge.sh` with `mkbrief.py` briefs
  (append each row to verdicts.csv, return "judged N/M: A x, B y, tie z"): 373 are `echo >> verdicts.csv` plus a
  python3 or `cut|sort|uniq` tally, 118 `cat >>` heredocs. Lever: one command that
  appends a row and prints `judged N/M: A x, B y, tie z` (reuse `bench/judge_tally.py` or `coord/tools/majority.py`),
  named in `mkbrief.py`'s Output paragraph in place of the hand-written append and tally.
- `speed-adhoc-logo-bench` (`adhoc/logo-bench`): 772 calls in 66 sessions, 708 by workers here: lane research scripts
  over files each lane invents, plus 56 reads of verdicts.csv or key.json that `bench/judge_tally.py` and
  `coord/tools/majority.py` already tally. Lever: name those two in the briefs or this repository's CLAUDE.md; a
  command only for a read the lanes repeat.
- `tracers/champ61/run.sh` (14.1 CPU-min/day), `champ52-hl/hairline.py` (12.8): each `champN/run.sh` runs `champ(N-1)/run.sh`,
  so a candidate re-traces champ46..60 per input while `out/champ60` holds the 96 parent SVGs. Lever: take the parent's SVG
  from `out/<parent>/` when present (PYTHONHASHSEED=0, 1 thread: deterministic; prove byte-equal `out/champ61`).

Also (row `log_audit:worker-env-pitfalls-python-zsh`): lane and judge workers keep trying bare `python3` (no PIL)
before `tracers/champ47-soft/.venv/bin/python`; name the lane interpreter in the brief templates or the README.

Done when the next rounds' calls show the commands instead of the scripts; the Speed doctor reads it as each cluster's
residual falling (`share/tool_mining.py --calls`).
