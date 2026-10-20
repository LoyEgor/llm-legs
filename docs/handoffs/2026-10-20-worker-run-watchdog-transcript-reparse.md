# Hand-off: worker-run's watchdog re-parses the whole transcript every hop

Status: open
To: «Workers и review bench унификация отображения» (owner of `bin/worker-run`)
From: system doctor fixer run system-system-20261020T113826Z-7b45, stopped by Egor mid-problem; ledger row
`cohort:llm-legs/bin/worker-run` in `share/system-ledger.json` (status open) holds the same facts.

## Problem

System doctor: `bin/worker-run` costs B 3.0 a day, ~2.6k cpu-s a day, steady outside suite ticks (10-18 and
10-19 ~1.9k cpu-s each; 1-20 s per tick over 674 ticks). Likely dominant term, not yet measured in isolation:
every watchdog hop (<= 30 s) on a transcript that moved runs `activity_fingerprint` -> `compute_transcript_files`:

- `transcript_files`: two full jq passes over the whole transcript (78 ms on a 2.4 MB one);
- `transcript_wrote_through_shell`: one more jq pass plus a python3 classifier — yet the watchdog reads only
  `RUN_FILES_LIST`, so these outputs go unused there.

Estimate ~4.6k cpu-s a day over 154 claudeb runs (76 h) in 2 days; it likely overstates.

## Ready levers, output-equivalent

1. Skip `transcript_wrote_through_shell` on the watchdog path (its outputs are unread there).
2. One jq instead of two in `transcript_files` (reduce inputs into bad ids and `[id, path]` hits, non-string
   ids `tojson`): byte-identical lists on 138 real transcripts, subagents and a since cut included. Not applied.
3. Next: parse only the bytes appended since the last hop.

Prove each by identical `RUN_FILES_LIST` / run-files output on real transcripts, then close the ledger row as
fixed-pending (`bin/system-doctor check llm-legs/bin/worker-run` proves it against the 7 days before).
