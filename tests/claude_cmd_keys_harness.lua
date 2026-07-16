local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local env = setmetatable({}, { __index = _G })
env._G = env
local chunk, err = loadfile(root .. "/hammerspoon/claude_cmd_keys.lua", "t", env)
assert(chunk, err)
local module = chunk()

local native = [[
Ss   -zsh
S+   claude --resume 11111111-1111-1111-1111-111111111111
S+   node /tmp/codex mcp-server
]]
assert(module.isClaudeForeground(native), "native claude process was not detected")
assert(module.isClaudeForeground("S+ /opt/tools/claude --debug\n"),
  "claude basename was not detected")
assert(module.isClaudeForeground("S+ /opt/claude/versions/2.1.7/node --debug\n"),
  "versioned claude path was not detected")
assert(module.isClaudeForeground("S+ node /opt/lib/node_modules/@anthropic-ai/claude-code/cli.js\n"),
  "node Claude Code process was not detected")
assert(module.isClaudeForeground("S+ bun /opt/claude-code/cli.js\n"),
  "bun Claude Code process was not detected")
assert(not module.isClaudeForeground("S    claude\n"), "background claude process was accepted")
assert(not module.isClaudeForeground("S+ grep claude\n"), "grep process was accepted")
assert(not module.isClaudeForeground("S+ grep /tmp/claude fixture\n"), "Claude-like grep argument was accepted")
assert(not module.isClaudeForeground("S+ claude-chat-switch\n"), "similar command was accepted")
assert(not module.isClaudeForeground(nil), "missing ps output was accepted")

assert(module.containsImageType({ "public.utf8-plain-text", "public.png" }),
  "PNG pasteboard type was not detected")
assert(module.containsImageType({ "public.tiff" }), "TIFF pasteboard type was not detected")
assert(module.containsImageType({ "com.compuserve.gif" }), "GIF pasteboard type was not detected")
assert(not module.containsImageType({ "public.utf8-plain-text" }), "text was classified as an image")
assert(not module.containsImageType(nil), "missing pasteboard types were classified as an image")

assert(module.decide("com.apple.Terminal", native, nil, "c") == "copy",
  "Cmd+C did not choose copy")
assert(module.decide("com.apple.Terminal", native, { "public.png" }, "v") == "image-paste",
  "image Cmd+V did not choose image paste")
assert(module.decide("com.apple.Terminal", native, { "public.utf8-plain-text" }, "v") == "pass",
  "text Cmd+V was not passed through")
assert(module.decide("com.apple.Terminal", "S+ zsh\n", { "public.png" }, "v") == "pass",
  "non-Claude Terminal process was intercepted")
assert(module.decide("com.apple.Safari", native, { "public.png" }, "v") == "pass",
  "non-Terminal app was intercepted")
assert(module.decide(nil, native, nil, "c") == "pass", "unknown app was intercepted")
assert(module.decide("com.apple.Terminal", native, nil, "x") == "pass", "unhandled key was intercepted")

local observed = {
  bundleID = "com.apple.Terminal",
  windowID = 42,
  windowTitle = "Claude",
  tabIndex = 3,
}
local cached = {
  bundleID = "com.apple.Terminal",
  windowID = 42,
  windowTitle = "Claude",
  tabIndex = 3,
  checkedAt = 10,
  claude = true,
}
assert(module.decideCached(observed, cached, nil, "c", 10.1) == "copy",
  "hot cached Claude context did not choose copy")
assert(module.decideCached(observed, cached, { "public.png" }, "v", 10.1) == "image-paste",
  "cached image Cmd+V did not choose image paste")
assert(module.decideCached(observed, cached, { "public.utf8-plain-text" }, "v", 10.1) == "pass",
  "cached text Cmd+V was not passed through")
assert(module.decideCached(observed, nil, nil, "c", 10.1) == "pass",
  "cold cache was intercepted")
assert(module.decideCached(observed, cached, nil, "c", 11) == "pass",
  "stale cache was intercepted")
assert(module.decideCached(observed, nil, { "public.png" }, "v", 10.1) == "pass",
  "cold image Cmd+V cache was intercepted")
assert(module.decideCached(observed, cached, { "public.png" }, "v", 11) == "pass",
  "stale image Cmd+V cache was intercepted")
local switched = {
  bundleID = "com.apple.Terminal",
  windowID = 42,
  windowTitle = "Shell",
  tabIndex = 4,
}
assert(module.decideCached(switched, cached, nil, "c", 10.1) == "pass",
  "changed Terminal tab was intercepted")
local sameTitleSwitched = {
  bundleID = "com.apple.Terminal",
  windowID = 42,
  windowTitle = "Claude",
  tabIndex = 4,
}
assert(module.decideCached(sameTitleSwitched, cached, nil, "c", 10.1) == "pass",
  "same-title Terminal tab switch was intercepted")

local copy = module.copyChordPlan()
assert(#copy == 2, "copy chord length changed")
assert(module.planBytes(copy) == string.char(24, 25), "copy bytes changed")
local paste = module.imagePastePlan()
assert(#paste == 1, "image paste chord length changed")
assert(module.planBytes(paste) == string.char(22), "image paste byte changed")

return "PASS: Claude Cmd key decisions"
