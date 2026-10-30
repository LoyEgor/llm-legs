# Hand-off: pixel-forge's own command for its repeated probe scripts

Status: open
To: «Пайплайн пиксель-арта из AI-генерации» (owner of `/Volumes/Work/Projects/pixel-forge`)

Speed row `opportunity:adhoc/logo-bench` (ledger `speed-adhoc-logo-bench`), 24 h to 2026-10-29 07:30: 1402 of its
2266 ad-hoc calls are pixel-forge's, 1266 by workers in 77 sessions, median exec 2.2 s: inline
`.venv/bin/python -c`/heredocs importing `pixforge.color` (179), `pixforge.pipeline` (167), `pixforge.palette` (151),
`pixforge.grid` (85) and reading `experiments/<run>/` outputs. A job concentrated in one project is that project's
(Egor, 2026-10-14): if one read repeats (an experiment's per-image metrics, one image through the pipeline), make it one
`pixforge` subcommand or a `bench/` script, named in the worker briefs where the probe would start; if the probes are
each a new question, say so here and close it.

Also (row `log_audit:worker-env-pitfalls-python-zsh`): workers keep trying bare `python3` (no PIL/numpy) before
`.venv/bin/python`; no file a worker reads here names it. Name it in the README or a CLAUDE.md, or in the brief templates.

Done when `share/tool_mining.py --calls` shows the command in place of the scripts, or this file says none serves.

Also (log-audit 10-30): bench/judge.py sheets --n defaults to 12 and truncates silently (E75 judged 12 of 20); enhance.py pick-sheets splits windows by count, not cost; pf.py/t.py symbol tables overflow, region guard fires after the write, previews reuse names; judges share /tmp/judge-opus and hand-roll crop/diff loops: one aligned cell-diff/crop helper named in the judge brief, scratch per run.
