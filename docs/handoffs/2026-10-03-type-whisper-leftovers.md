# Handoff 2026-10-03: type_whisper.lua leftovers outside hammerspoon

Status: trade for Egor
Cost: one BTT UI edit by Egor: delete the `hs -c 'TypeWhisper.toggle()'` action (Z_PK 2804) of the uuid-less Cmd+Shift+keyCode 50 gesture (Z_PK 2672), keep its Page Up.
Loss: each press spawns an `hs -c` that errors on nil `TypeWhisper`; Page Up still toggles the TypeWhisper app, nothing else breaks.
Recommendation: delete the action at his next BTT visit; no night can, the trigger has no uuid for the BTT script API.

Settled 20261005T060033Z-052f: the dead `type_whisper.lua` entry left claude-setup
`tests/test_chat_keystroke_ownership.sh` `NOT_A_CHAT`, which now fails on any exempted module missing from `HS_ROOT`.
