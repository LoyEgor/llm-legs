# Hand-off: logo-vectorizer-bench's own commands for its repeated scripts

Status: open
To: «Vector Magic macOS ARM migration»

Egor (2026-10-14): a job concentrated in one project is that project's; its command and hint go into its repository
(its CLAUDE.md or a skill), never into the harness. Two Speed rows are this repository's,
`/Volumes/Work/Projects/logo-vectorizer-bench`:

- `speed-adhoc-logo-verdict` (`adhoc/logo-verdict`): judge workers write 491 ad-hoc calls a day in 41 sessions
  (2026-10-13), 15 worker-min/day, all launched by `results/lanes/coord/tools/judge.sh` with `mkbrief.py` briefs
  ("Append each row to its folder's verdicts.csv ...", return "judged N/M: A x, B y, tie z"): 373 are
  `echo >> verdicts.csv` plus a python3 or `cut|sort|uniq` tally, 118 `cat >>` heredocs. Lever: one command that
  appends a row and prints `judged N/M: A x, B y, tie z` (reuse `bench/judge_tally.py` or `coord/tools/majority.py`),
  named in `mkbrief.py`'s Output paragraph in place of the hand-written append and tally.
- `speed-adhoc-logo-bench` (`adhoc/logo-bench`): 772 calls in 66 sessions, 708 by workers here: lane research scripts
  over files each lane invents, plus 56 reads of verdicts.csv or key.json that `bench/judge_tally.py` and
  `coord/tools/majority.py` already tally. Lever: name those two in the briefs or this repository's CLAUDE.md; a
  command only for a read the lanes repeat.

Done when the next rounds' calls show the commands instead of the scripts; the Speed doctor reads it as each cluster's
residual falling (`share/tool_mining.py --calls`).
