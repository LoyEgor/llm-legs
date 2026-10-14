# Hook `if` filter: skip the spawn for commands a Bash hook ignores

Status: settled 20261014T013750Z-8004: kept as is: 1.7 CPU-min/day (0.2 % of the 774 own) and no wall, PreToolUse hooks run in parallel, against a gate silently narrowed where `if` splits a command unlike the hooks' own test; both cpu rows read kept

To: Egor. From night 20261012T233034Z-3131 run harness-speed-cpu-hook-dia-not-chrome-sh; rows `cpu:hook/chat-switch-link.sh`, `cpu:hook/skill-install-scope-gate.sh`.
Each Bash hook is spawned 7190 times a day and 0.9-1.0 CPU-min/day goes to bash startup plus a substring test that exits at once
(own work 0.6-1.5 ms of ~7 ms journaled). Claude Code 2.1.296 has a hook-entry field `if` (permission-rule syntax, "avoids spawning hooks
for non-matching commands"). `settings.json` registrations are Speed's Never list, so the step is yours.

Step in `~/.claude/settings.json`, PreToolUse `Bash`: add `"if": "Bash(*claude-chat-switch*)"` to the chat-switch-link entry;
for skill-install-scope-gate two entries of the same command, `"if": "Bash(*skills*)"` and `"if": "Bash(*hyperframes*init*)"`
(a command matching both runs it twice, harmless). Check: a `claude-chat-switch --self` call and a `hyperframes init` still reach the hook
(rows in `~/.cache/harness-doctor/hooks/<day>.tsv`), an `ls` adds none.
Not convertible: dia-not-chrome and eod-sorted-gate match through quote- and backslash-splicing (`Goo"gle Chr"ome`), which a glob cannot express.

Cost: 3 settings lines. Saves ~1.9 CPU-min/day and 14k spawns a day.
Loss: if `if` splits compound commands differently from the hooks' own substring test, a wrapped call skips the hook silently (the chat-switch resume line, a global skills install let through).
Recommendation: do it for these two and re-read the doctor's rows after a day; the saving is small, the filter is one line to revert.
