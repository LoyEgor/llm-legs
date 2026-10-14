# Hand-off: Speed owner trades nobody settled

Status: settled 20261014T013750Z-8004: all three closed, none stands
To: next night, a harness fixer

The Speed design's three owner trades of 2026-10-02, checked on 2026-10-14:

1. Settings steps: gone. The workdir hook's PostToolUse matcher has no Read in the shared
   `~/.claude/settings.json`; `claude mcp list` shows no server in com, notcom or locomthebest; zero
   `mcp__codex` calls in 4582 transcripts over 14 days.
2. Poll deny: 14-day replay of owner chats: 305 foreground sleep loops, 224 polls (overshoot ≈ 0.8
   min/day), 21 non-poll sampling loops denied, 60 more heredoc hits; a re-plan per poll (16/day × 5–10
   s) costs more than it saves; Claude Code already blocks a leading `sleep N` (32 times).
3. Debt round: since 0d9e7c3c branches land on the press-time commit and the debt pass runs after the
   last landing; on 4c4e, e2f7 and 3131 it blocked 0 landing minutes.
