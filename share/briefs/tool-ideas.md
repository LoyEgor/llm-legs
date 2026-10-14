## Tool ideas — monthly, harness direction

Propose tools that would make the LLMs' work here cheaper or faster, beyond what the frequency counts find:
a missing helper the chats rebuild by hand, a vendor feature or open-source tool that replaces a slow
procedure, a cheaper route to the same output. Speed never trades intelligence: no idea lowers a model,
effort or thinking.

1. Read, all of it from the last 30 days:
   - the tool-mining clusters, from `~/.cache/speed-doctor/tool-mining.json` (`share/tool_mining.py`'s `cache_path()`); missing or
     empty: say so and go on;
   - the improvement pool: `python3 share/time_budget.py pool`, the open rows of `share/harness-ledger.json`
     and `share/spend-ledger.json`, so no idea repeats a row;
   - a sample of transcripts: ten worker runs (`~/.cache/claude-worker-runs/*/`) and ten chats
     (`bin/chat-find --recent --json --days 30 --limit 50` lists them), the longest by wall time first; look for repeated
     multi-step procedures, retries, and waits.
2. Per idea, price it: expected minutes a day it saves, from the counts you read (calls a day × minutes a
   call), never a guess without a count. Under 1 min/day is no row.
3. Each idea is one open row appended to `share/harness-ledger.json` in your worktree:
   `{"id": "tool-idea-<slug>", "title": "<the tool in one line>", "match": {"rule": "tool_idea", "ident":
   "tool-idea/<slug>"}, "status": "open", "expected_min_day": <n>, "fixes": [], "same_cause": [],
   "last_reviewed": "<today>", "reviewed_by": "night tool-ideas <night>", "note": "<evidence: the counts and
   where they come from; the build: files, reuse, its proof>", "handoff": null}`.
   The Harness fixer takes an open row as a known quiet row (`bin/doctor-fix`). Run the
   suites `tests/affected share/harness-ledger.json` names in one `tests/run-all` call, then commit the ledger.
4. Report, outcome first, ≤ 200 words: each row's id and min/day, the inputs you could not read.
