# Hand-off: the keystroke-ownership guard lives outside the repository it guards

Status: open — To: next night (claude-setup, hammerspoon)

claude-setup `tests/test_chat_keystroke_ownership.sh` globs `$HS_ROOT` (default `~/.hammerspoon`, the
hammerspoon MAIN checkout): no hammerspoon change selects it, and a hammerspoon worktree's new
key press is unseen until it lands (a `keyStroke` appended to `claude_compact.lua` in a copy: red).
Cost: move the file to hammerspoon `tests/` with `HS_ROOT` defaulting to the repository, delete it in claude-setup.
Loss: a module typing past `chat_gate` lands and is caught only by claude-setup's next run.
Recommendation: move it.
