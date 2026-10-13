# Handoff 2026-10-03: type_whisper.lua leftovers outside hammerspoon

Status: settled 2026-10-06: Egor deleted the BTT action; BetterTouchTool get_triggers holds no TypeWhisper trigger

Settled 20261005T060033Z-052f: the dead `type_whisper.lua` entry left claude-setup
`tests/test_chat_keystroke_ownership.sh` `NOT_A_CHAT`, which now fails on any exempted module missing from `HS_ROOT`.
