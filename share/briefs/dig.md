## Dig — weekly, structural waste no number shows

Numbers show what is already measured (Egor 2026-10-29, `docs/directions/README.md` Rules, Dig); this job reads the
harness where none points. Finding is free-form. The dig changes no code; it is time-bounded: 90 minutes, then write
what you have. Speed first: an estimate is waited minutes a day (he or a worker waits), else a spend share.

1. Read the four sweep repositories (`~/.claude/sweep-repos`) and the caches below through these seed lenses, each
   with its cheap measure; they are examples, never the limit:
   - a hot module in a large file: per test-covered file over 1,500 lines, `git log --since=30.days -L` or
     `git log -p` hunks bucketed by region, × the wall of its covering suite (`~/.cache/run-suites/runs.jsonl`,
     `.suites[name].secs`; `tests/affected <file>` names it) = suite minutes a day the region's edits rerun;
   - work done serially that could run at once (media tiles, review cells, a landing queue): the per-item wall
     in its log against the sum;
   - something closed and reopened mid-job (a browser, a session): opens per job in its log × the open's cost;
   - memory pressure the harness could relieve itself: `share/slots.sh` holds and waits, `system-doctor` ticks;
   - the same work done twice across tools: one input read or computed by two tools in the same run.
2. Skip what a row already holds: the open rows of `share/harness-ledger.json` and `share/spend-ledger.json`, the
   `### goal` sections of `docs/directions/*.md`. Under 5 waited min/day or 1 % spend share is no candidate.
3. Each candidate is one open row appended to `share/harness-ledger.json`:
   `{"id": "dig-<slug>", "title": "<the waste in one line>", "match": {"rule": "dig", "ident": "dig/<slug>"},
   "status": "open", "expected_min_day": <n, 0 for a spend-only one>, "fixes": [], "same_cause": [],
   "last_reviewed": "<today>", "reviewed_by": "night dig <night>", "note": "<estimate and its source: the
   command, the counts; spend share when it is spend; the proof a fix would use, fixed now>", "handoff": null}`.
4. The top candidates by waited minutes (spend after) become `### goal <slug>:` sections under `## Goals` of the
   direction file whose metric they move (README Rules): the class, the measured gain with its source, First step
   (the check that stops the goal when it does not hold), Proof (old against new, fixed before the work), Files.
   These sections are the job's output and pass the net-zero markdown rule; nothing else in the file grows.
5. Run the suites `tests/affected share/harness-ledger.json` names in one `tests/run-all` call, then commit.
6. Report, outcome first, ≤ 200 words: each row's id with its estimate and source, which became goals, the lenses
   you could not measure and why.
