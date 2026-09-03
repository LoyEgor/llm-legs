# Hammerspoon config, llm-legs side

Only the account-side modules live here: `env_guard.lua` (poisoned-HOME guard,
dofile'd first by init.lua); `~/.hammerspoon` symlinks it.
`../llm-limits.lua` (the menubar) is required from `~/.hammerspoon` via package.path.
Everything else — init, automation menu, chat gate, typing, iPad, voice — lives in
the hammerspoon repo (`/Volumes/Work/Projects/hammerspoon` = `~/.hammerspoon`).
User-facing notification strings are intentionally Russian; code and comments English.
