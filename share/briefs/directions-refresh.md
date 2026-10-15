## Directions refresh — monthly

`docs/directions/*.md` are the knowledge the night and the hub chat brief workers from. Keep them true and short.

1. For each direction file, check every number, commit and decision against its source: the ledgers it names, `git log`,
   the doctors' `latest.json`, `share/time_budget.py day --json`. A fact the source contradicts is corrected; a stale
   number gets the current one with its date; a Done row older than 60 days whose result is settled shrinks to one
   line or goes.
2. Search the last 30 days of chats for Egor's decisions on a direction (`bin/chat-find --recent --json --days 30`,
   his words in the transcripts) that its Decisions list lacks, and add each with its date.
3. Compact as md-compact does: one fact once, no restated doctrine, no prose a table already says. Net bytes of the
   directory never grow, unless step 2 added decisions.
4. Commit on your branch. Report, outcome first, ≤ 150 words: per file the facts corrected and the bytes before → after.
