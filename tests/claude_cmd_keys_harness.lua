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

assert(module.containsFileURLType({ "public.file-url" }), "file-url type was not detected")
assert(module.containsFileURLType({ "public.png", "public.file-url" }), "file-url type was missed alongside others")
assert(not module.containsFileURLType({ "public.png" }), "image type was misread as file-url")
assert(not module.containsFileURLType(nil), "missing types were misread as file-url")

assert(module.isImagePath("/tmp/a.png"), "png path was not recognized")
assert(module.isImagePath("/x/telegram-cloud-photo.JPG"), "uppercase jpg path was not recognized")
assert(module.isImagePath("/x/y.HEIC") and module.isImagePath("/x/y.tif") and module.isImagePath("/x/y.webp"),
  "an image extension was not recognized")
assert(not module.isImagePath("/tmp/a.pdf"), "pdf path was recognized as an image")
assert(not module.isImagePath("/tmp/noext"), "extensionless path was recognized as an image")
assert(not module.isImagePath(nil), "nil path was recognized as an image")

assert(module.fileURLToPath("file:///tmp/a.png") == "/tmp/a.png", "file URL was not converted to a path")
assert(module.fileURLToPath("file://localhost/tmp/a.png") == "/tmp/a.png", "host file URL was not converted")
assert(module.fileURLToPath("file:///tmp/a%20b.png") == "/tmp/a b.png", "percent-encoded file URL was not decoded")
assert(module.fileURLToPath("https://example.com/a.png") == nil, "non-file URL was converted to a path")
assert(module.fileURLToPath({ url = "file:///tmp/a.png" }) == "/tmp/a.png", "table-form URL was not converted")
assert(module.fileURLToPath(nil) == nil, "nil URL produced a path")

assert(module.decide("com.apple.Terminal", native, nil, "c") == "copy",
  "Cmd+C did not choose copy")
assert(module.decide("com.apple.Terminal", native, { "public.png" }, "v") == "image-paste",
  "image Cmd+V did not choose image paste")
assert(module.decide("com.apple.Terminal", native, { "public.utf8-plain-text" }, "v") == "pass",
  "text Cmd+V was not passed through")
assert(module.decide("com.apple.Terminal", native, { "public.file-url" }, "v", "/tmp/a.png") == "convert",
  "file-url Cmd+V with a resolved path did not choose convert")
assert(module.decide("com.apple.Terminal", native, { "public.file-url" }, "v") == "pass",
  "file-url Cmd+V without a resolved path was intercepted")
assert(module.decide("com.apple.Terminal", native, { "public.png" }, "v", "/tmp/a.png") == "image-paste",
  "image UTI lost priority over a convert path")
assert(module.decide("com.apple.Terminal", native, { "public.utf8-plain-text" }, "v", nil, true)
    == "replace",
  "text Cmd+V over an armed selection did not choose replace")
assert(module.decide("com.apple.Terminal", native, { "public.png" }, "v", nil, true) == "image-paste",
  "an armed selection outranked an image clipboard")
assert(module.decide("com.apple.Terminal", native, { "public.file-url" }, "v", "/tmp/a.png", true)
    == "convert",
  "an armed selection outranked a convert path")
assert(module.decide("com.apple.Terminal", "S+ zsh\n", { "public.utf8-plain-text" }, "v", nil, true)
    == "pass",
  "non-Claude text Cmd+V over an armed selection was intercepted")
assert(module.decide("com.apple.Terminal", "S+ zsh\n", { "public.png" }, "v") == "pass",
  "non-Claude Terminal process was intercepted")
assert(module.decide("com.apple.Safari", native, { "public.png" }, "v") == "pass",
  "non-Terminal app was intercepted")
assert(module.decide(nil, native, nil, "c") == "pass", "unknown app was intercepted")
assert(module.decide("com.apple.Terminal", native, nil, "x") == "cut",
  "Cmd+X did not choose cut")
assert(module.decide("com.apple.Terminal", "S+ zsh\n", nil, "x") == "pass",
  "non-Claude Cmd+X was intercepted")
assert(module.decide("com.apple.Safari", native, nil, "x") == "pass",
  "non-Terminal Cmd+X was intercepted")
assert(module.decide("com.apple.Terminal", native, nil, "z") == "undo",
  "Cmd+Z did not choose undo")
assert(module.decide("com.apple.Terminal", "S+ zsh\n", nil, "z") == "pass",
  "non-Claude Cmd+Z was intercepted")
assert(module.decide("com.apple.Safari", native, nil, "z") == "pass",
  "non-Terminal Cmd+Z was intercepted")
assert(module.decide("com.apple.Terminal", native, nil, "a") == "selectAll",
  "Cmd+A did not choose select-all")
assert(module.decide("com.apple.Terminal", "S+ zsh\n", nil, "a") == "pass",
  "non-Claude Cmd+A was intercepted")
assert(module.decide("com.apple.Safari", native, nil, "a") == "pass",
  "non-Terminal Cmd+A was intercepted")

local observed = {
  bundleID = "com.apple.Terminal",
  windowID = 42,
  windowTitle = "Claude",
  tabIndex = 3,
  tabElement = "tab-a",
}
local cached = {
  bundleID = "com.apple.Terminal",
  windowID = 42,
  windowTitle = "Claude",
  tabIndex = 3,
  tabElement = "tab-a",
  checkedAt = 10,
  claude = true,
}
assert(module.decideCached(observed, cached, nil, "c", 10.1) == "copy",
  "hot cached Claude context did not choose copy")
assert(module.decideCached(observed, cached, { "public.png" }, "v", 10.1) == "image-paste",
  "cached image Cmd+V did not choose image paste")
assert(module.decideCached(observed, cached, { "public.utf8-plain-text" }, "v", 10.1) == "pass",
  "cached text Cmd+V was not passed through")
assert(module.decideCached(observed, cached, nil, "z", 10.1) == "undo",
  "hot cached Claude context did not choose undo")
assert(module.decideCached(observed, cached, nil, "z", 11) == "pass",
  "stale Cmd+Z cache was intercepted")
assert(module.decideCached(observed, cached, nil, "x", 10.1) == "cut",
  "hot cached Claude context did not choose cut")
assert(module.decideCached(observed, cached, nil, "x", 11) == "pass",
  "stale Cmd+X cache was intercepted")
assert(module.decideCached(observed, cached, nil, "a", 10.1) == "selectAll",
  "hot cached Claude context did not choose select-all")
assert(module.decideCached(observed, cached, nil, "a", 11) == "pass",
  "stale Cmd+A cache was intercepted")
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
  tabElement = "tab-b",
}
assert(module.decideCached(switched, cached, nil, "c", 10.1) == "pass",
  "changed Terminal tab was intercepted")
local sameTitleSwitched = {
  bundleID = "com.apple.Terminal",
  windowID = 42,
  windowTitle = "Claude",
  tabIndex = 4,
  tabElement = "tab-b",
}
assert(module.decideCached(sameTitleSwitched, cached, nil, "c", 10.1) == "pass",
  "same-title Terminal tab switch was intercepted")
local replacedAtSameIndex = {
  bundleID = "com.apple.Terminal",
  windowID = 42,
  tabIndex = 3,
  tabElement = "replacement-tab",
}
assert(module.decideCached(replacedAtSameIndex, cached, nil, "c", 10.1) == "pass",
  "replacement Terminal tab at the same index was intercepted")
assert(module.decideCached(observed, cached, { "public.file-url" }, "v", 10.1, "/tmp/a.png") == "convert",
  "cached file-url Cmd+V did not choose convert")
assert(module.decideCached(observed, cached, { "public.file-url" }, "v", 11, "/tmp/a.png") == "pass",
  "stale file-url Cmd+V cache was intercepted")
assert(module.decideCached(observed, cached, { "public.utf8-plain-text" }, "v", 10.1, nil, true)
    == "replace",
  "cached text Cmd+V over an armed selection did not choose replace")
assert(module.decideCached(observed, cached, { "public.utf8-plain-text" }, "v", 11, nil, true) == "pass",
  "stale paste-replace cache was intercepted")

local pending, effect = module.pendingTransition(nil, {
  type = "press", id = 1, key = "c", now = 1, timeout = 0.28,
})
assert(pending.status == "pending" and effect.consume and effect.startResolve,
  "cold Cmd+C did not start a pending resolve")
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "claude",
})
assert(pending.status == "idle" and #effect.actions == 1
    and effect.actions[1].action == "copy", "cold Claude verdict did not copy")

pending = module.pendingTransition(nil, {
  type = "press", id = 2, key = "c", now = 2, timeout = 0.28,
})
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "not-claude",
})
assert(effect.actions[1].action == "replay",
  "cold non-Claude verdict did not replay")
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "claude",
})
assert(effect.actions == nil, "completed decision ran twice")

pending, effect = module.pendingTransition(nil, {
  type = "press", id = 30, key = "z", now = 2.5, timeout = 0.28,
})
assert(pending.status == "pending" and effect.consume and effect.startResolve,
  "cold Cmd+Z did not start a pending resolve")
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "claude",
})
assert(effect.actions[1].action == "undo", "cold Claude verdict did not undo")
pending = module.pendingTransition(nil, {
  type = "press", id = 31, key = "z", now = 2.6, timeout = 0.28,
})
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "not-claude",
})
assert(effect.actions[1].action == "replay", "non-Claude Cmd+Z did not replay")
pending, effect = module.pendingTransition(nil, {
  type = "press", id = 34, key = "x", now = 2.65, timeout = 0.28,
})
assert(pending.status == "pending" and effect.consume and effect.startResolve,
  "cold Cmd+X did not start a pending resolve")
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "claude",
})
assert(effect.actions[1].action == "cut", "cold Claude verdict did not cut")
pending = module.pendingTransition(nil, {
  type = "press", id = 35, key = "x", now = 2.66, timeout = 0.28,
})
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "not-claude",
})
assert(effect.actions[1].action == "replay", "non-Claude Cmd+X did not replay")
pending, effect = module.pendingTransition(nil, {
  type = "press", id = 36, key = "a", now = 2.67, timeout = 0.28,
})
assert(pending.status == "pending" and effect.consume and effect.startResolve,
  "cold Cmd+A did not start a pending resolve")
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "claude",
})
assert(effect.actions[1].action == "selectAll", "cold Claude verdict did not arm select-all")
pending = module.pendingTransition(nil, {
  type = "press", id = 37, key = "a", now = 2.68, timeout = 0.28,
})
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "not-claude",
})
assert(effect.actions[1].action == "replay",
  "non-Claude Cmd+A did not replay into Terminal's own select-all")
pending = module.pendingTransition(nil, {
  type = "press", id = 38, key = "a", now = 2.69, timeout = 0.28,
})
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "claude", targetMatches = { [38] = false },
})
assert(effect.actions[1].action == "policy-drop",
  "target-mismatched Cmd+A did not policy-drop")
pending = module.pendingTransition(nil, {
  type = "press", id = 32, key = "z", now = 2.7, timeout = 0.28,
})
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "claude", targetMatches = { [32] = false },
})
assert(effect.actions[1].action == "policy-drop",
  "target-mismatched Cmd+Z did not policy-drop")
pending = module.pendingTransition(nil, {
  type = "press", id = 33, key = "z", now = 2.8, timeout = 0.28,
})
pending, effect = module.pendingTransition(pending, { type = "stop" })
assert(effect.actions[1].action == "policy-drop", "stopped Cmd+Z did not policy-drop")

pending = module.pendingTransition(nil, {
  type = "press", id = 3, key = "c", now = 3, timeout = 0.28,
})
local waiting
pending, waiting = module.pendingTransition(pending, { type = "tick", now = 3.27 })
assert(pending.status == "pending" and waiting.actions == nil,
  "pending decision timed out early")
pending, effect = module.pendingTransition(pending, { type = "tick", now = 3.29 })
assert(effect.verdict == "timeout" and effect.actions[1].action == "replay",
  "pending timeout did not replay")

pending = module.pendingTransition(nil, {
  type = "press", id = 4, key = "c", now = 4, timeout = 0.28,
})
pending, effect = module.pendingTransition(pending, {
  type = "press", id = 5, key = "v", image = true, now = 4.1, timeout = 0.28,
})
assert(effect.consume and not effect.startResolve and #pending.queue == 2,
  "repeat during pending was not coalesced")
pending, effect = module.pendingTransition(pending, {
  type = "resolve", verdict = "claude",
})
assert(effect.actions[1].action == "copy"
    and effect.actions[2].action == "image-paste", "coalesced actions lost order")

pending, effect = module.pendingTransition(nil, {
  type = "press", id = 6, key = "v", image = false, now = 5, timeout = 0.28,
})
assert(pending.status == "idle" and not effect.consume,
  "text clipboard entered the pending path")
pending, effect = module.pendingTransition(nil, {
  type = "press", selfPosted = true,
})
assert(pending.status == "idle" and effect.ignored and not effect.consume,
  "self-posted event was not ignored")

local function convertPending(id)
  return module.pendingTransition(nil, {
    type = "press", id = id, key = "v", image = true, convertPath = "/tmp/a.png",
    now = 1, timeout = 0.28,
  })
end
local cvt, cvtEffect
cvt = convertPending(20)
cvt, cvtEffect = module.pendingTransition(cvt, { type = "resolve", verdict = "claude" })
assert(cvtEffect.actions[1].action == "convert" and cvtEffect.actions[1].path == "/tmp/a.png",
  "convert verdict lost its action or path")
cvt = convertPending(21)
cvt, cvtEffect = module.pendingTransition(cvt, { type = "resolve", verdict = "not-claude" })
assert(cvtEffect.actions[1].action == "replay", "non-Claude convert did not replay")
cvt = convertPending(22)
cvt, cvtEffect = module.pendingTransition(cvt, { type = "stop" })
assert(cvtEffect.actions[1].action == "policy-drop", "stopped convert did not policy-drop")
cvt = convertPending(23)
cvt, cvtEffect = module.pendingTransition(cvt, {
  type = "resolve", verdict = "claude", targetMatches = { [23] = false },
})
assert(cvtEffect.actions[1].action == "policy-drop", "target-mismatched convert did not policy-drop")
cvt = convertPending(24)
cvt, cvtEffect = module.pendingTransition(cvt, { type = "tick", now = 1.29 })
assert(cvtEffect.actions[1].action == "replay", "timed-out convert did not replay")

-- A text clipboard carries no image type, so paste-replace is the only thing that
-- lets Cmd+V through the queue guard at all.
local function pastePending(id)
  return module.pendingTransition(nil, {
    type = "press", id = id, key = "v", replace = true, now = 6, timeout = 0.28,
  })
end
local pst, pstEffect
pst, pstEffect = pastePending(40)
assert(pst.status == "pending" and pstEffect.consume and pstEffect.startResolve,
  "a paste-replace press did not start a pending resolve")
pst, pstEffect = module.pendingTransition(pst, { type = "resolve", verdict = "claude" })
assert(pstEffect.actions[1].action == "replace",
  "a resolved paste-replace lost its action")
pst = pastePending(41)
pst, pstEffect = module.pendingTransition(pst, {
  type = "resolve", verdict = "claude", targetMatches = { [41] = false },
})
assert(pstEffect.actions[1].action == "policy-drop",
  "a target-mismatched paste-replace was replayed into the tab that took its place")
pst = pastePending(42)
pst, pstEffect = module.pendingTransition(pst, { type = "stop" })
assert(pstEffect.actions[1].action == "policy-drop",
  "a stopped paste-replace was replayed instead of dropped")
pst = pastePending(43)
pst, pstEffect = module.pendingTransition(pst, { type = "resolve", verdict = "not-claude" })
assert(pstEffect.actions[1].action == "replay", "a non-Claude paste-replace was not replayed")
pst = pastePending(44)
pst, pstEffect = module.pendingTransition(pst, { type = "tick", now = 6.29 })
assert(pstEffect.actions[1].action == "replay", "a timed-out paste-replace was not replayed")

-- Captured from a real Claude Code 2.1.220 session (tmux 120x32, tui=fullscreen)
-- rather than hand-written: the prompt separator is U+00A0, not a space, and the
-- welcome banner is a rounded box sitting ABOVE the rules-drawn input box.
local screenDraft = [[

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ hello brave new world
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Fable 5 high cb:notcom │ cmdx-fixtures │ w:auto cx✓work4·sol·med cb~rawilimo·opus·hi gx✓mish·pro·hi
  ctx ? ? │ 5h 55% 00:30 │ wk 18% Sun 08:00 │ fb 17% Sun 07:59 │ $0.00
  ⏵⏵ bypass permissions on (shift+tab to cycle)
]]

local screenShorter = [[
                                                                                           Ctrl+Y to paste deleted text
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ hello new world
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Fable 5 high cb:notcom │ cmdx-fixtures │ w:auto cx✓work4·sol·med cb~rawilimo·opus·hi gx✓mish·pro·hi
  ctx ? ? │ 5h 55% 00:30 │ wk 18% Sun 08:00 │ fb 17% Sun 07:59 │ $0.00
  ⏵⏵ bypass permissions on (shift+tab to cycle)
]]

local screenOneChar = [[
                                                                                           Ctrl+Y to paste deleted text
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ hello brave new worl
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Fable 5 high cb:notcom │ cmdx-fixtures │ w:auto cx✓work4·sol·med cb~rawilimo·opus·hi gx✓mish·pro·hi
  ctx ? ? │ 5h 55% 00:30 │ wk 18% Sun 08:00 │ fb 17% Sun 07:59 │ $0.00
  ⏵⏵ bypass permissions on (shift+tab to cycle)
]]

local screenTwoLine = [[
                                                                                              ctrl+g to edit in VS Code
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ first line here
  second line there
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Fable 5 high cb:notcom │ cmdx-fixtures │ w:auto cx✓work4·sol·med cb~rawilimo·opus·hi gx✓mish·pro·hi
  ctx ? ? │ 5h 55% 00:30 │ wk 18% Sun 08:00 │ fb 17% Sun 07:59 │ $0.00
  ⏵⏵ bypass permissions on (shift+tab to cycle)
]]

local screenEmptyInput = [[
│             /…/scratchpad/cmdx-fixtures            │                                                                 │
╰──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯


────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Fable 5 high cb:notcom │ cmdx-fixtures │ w:auto cx✓work4·sol·med cb~rawilimo·opus·hi gx✓mish·pro·hi
  ctx ? ? │ 5h 62% 00:30 │ wk 20% Sun 08:00 │ fb 30% Sun 08:00 │ $0.00
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent


]]

-- Captured around a real 7-character deletion in a draft that wraps across two
-- visual rows: it pulled "sings" up from row 2, so the row edge moved. Joining
-- rows with "\n" made the common suffix break there and cutDiff claimed
-- "sleepy cat watches from the warm windowsill and the parrot\nsings " instead.
local screenWrapped = [[
                   tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf and reattach for focus tracking
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ the quick brown fox jumps over the lazy dog while the sleepy cat watches from the warm windowsill and the parrot
  sings loudly today
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Opus 5 (1M context) high cb:notcom │ wrapbug │ w:auto cx✗·sol·med cb~rawilimo·opus·hi gx✓egbor·pro·hi
  ctx ? ? │ 5h 94% 00:30 │ wk 23% Sun 08:00 │ fb 30% Sun 08:00 │ $0.00
  ⏵⏵ bypass permissions on (shift+tab to cycle)
]]

local screenReflowed = [[
                      tmux detected · scroll with PgUp/PgDn · or add 'set -g mouse on' to ~/.tmux.conf for wheel scroll
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ the quick brown fox jumps over the lazy dog while the cat watches from the warm windowsill and the parrot sings
  loudly today
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Opus 5 (1M context) high cb:notcom │ wrapbug │ w:auto cx✗·sol·med cb~rawilimo·opus·hi gx✓egbor·pro·hi
  ctx ? ? │ 5h 95% 00:30 │ wk 23% Sun 08:00 │ fb 30% Sun 08:00 │ $0.00
  ⏵⏵ bypass permissions on (shift+tab to cycle)
]]

-- An editor that "helpfully" normalizes the invisible U+00A0 above would leave
-- every parse assertion passing against a fixture that no longer matches Claude.
local nbspPrompt = "\226\157\175\194\160"
for name, fixture in pairs({
  screenDraft = screenDraft,
  screenShorter = screenShorter,
  screenTwoLine = screenTwoLine,
  screenEmptyInput = screenEmptyInput,
  screenWrapped = screenWrapped,
  screenReflowed = screenReflowed,
}) do
  assert(fixture:find(nbspPrompt, 1, true),
    name .. " lost the captured U+00A0 prompt separator")
end

assert(module.parseInputBox(screenDraft) == "hello brave new world",
  "single-line draft was not parsed out of the fullscreen input box")
assert(module.parseInputBox(screenShorter) == "hello new world",
  "shortened draft was not parsed out of the fullscreen input box")
assert(module.parseInputBox(screenTwoLine) == "first line here second line there",
  "two-row draft did not join with a space")
assert(module.parseInputBox(screenEmptyInput) == "",
  "empty input box below a rounded banner was not parsed as empty")
do
local titledDraft = "Keep account switching simple."
local titledScreen = table.concat({
  "✻ Cogitating…",
  string.rep("─", 91) .. " make account switching rule more simple ──",
  "❯\194\160" .. titledDraft,
  string.rep("─", 134),
  "  Opus 5 high cb:notcom │ account-rules │ w:auto cx✓work4·sol·med",
  "  ctx ? ? │ 5h 55% 00:30 │ wk 18% Sun 08:00 │ fb 17% Sun 07:59 │ $0.00",
  "  ⏵⏵ bypass permissions on (shift+tab to cycle)",
  "",
}, "\n")
local titledText, titledTop, titledLines, titledLayout = module.parseInputBox(titledScreen)
assert(titledText == titledDraft and titledTop == 2 and titledLines == 7,
  "a titled fullscreen border did not produce the draft at the captured rows")
assert(titledLayout.columns == 134 and titledLayout.firstRow == 3
    and titledLayout.firstColumn == 3 and titledLayout.lastColumn == 32,
  "a titled fullscreen border changed the draft geometry")
assert(module.parseInputBox(
    "Release notes use ─ dashes ─ in prose\n❯\194\160wrong\n" .. string.rep("─", 80) .. "\n") == nil,
  "a prose line containing dashes became an input border")
-- The titled border closes with `──`; a transcript separator closes as wide as it opens,
-- and reading one as the input border would put every drag point in the transcript.
local separator = string.rep("─", 4) .. " snip " .. string.rep("─", 4)
assert(module.parseInputBox(separator .. "\n❯\194\160wrong\n" .. separator .. "\n") == nil,
  "a transcript separator became an input border")
assert(module.parseInputBox("  " .. string.rep("─", 91) .. " titled and indented ──\n❯\194\160"
    .. titledDraft .. "\n  " .. string.rep("─", 91) .. "\n") == titledDraft,
  "an indented titled border was not read as the input border")
end
-- screenDraft ends with "\n" like the live scrape and counts as 7 rows with the
-- input box opening on line 2, so in a 700px-tall window each row is 100px and
-- the top border lands at y=200.
local draftText, draftTopIndex, draftLines, draftLayout = module.parseInputBox(screenDraft)
assert(draftText == "hello brave new world", "the draft lost its first return value")
assert(draftTopIndex == 2 and draftLines == 7,
  "the input box border index or screen line count was not reported")
-- The draft starts in column 3: the prompt glyph and its U+00A0 take two cells.
assert(draftLayout.firstRow == 3 and draftLayout.lastRow == 3
    and draftLayout.firstColumn == 3 and draftLayout.lastColumn == 23
    and draftLayout.columns == 120,
  "the draft text extents were not reported for a single-row box")
local _, _, twoLineTotal, twoLineLayout = module.parseInputBox(screenTwoLine)
assert(twoLineTotal == 8 and twoLineLayout.firstRow == 3 and twoLineLayout.lastRow == 4
    and twoLineLayout.firstColumn == 3 and twoLineLayout.lastColumn == 19,
  "a two-row draft did not span both of its rows")
local _, _, _, roundedLayout = module.parseInputBox(
  "╭────────────────────╮\n│ > hi there         │\n╰────────────────────╯\n")
assert(roundedLayout.firstColumn == 5 and roundedLayout.lastColumn == 12,
  "the rounded box border and prompt were not counted as leading cells")
local _, _, _, emptyLayout = module.parseInputBox(screenEmptyInput)
assert(not emptyLayout.hasText, "an empty input box claimed draft text")
local _, _, _, paddedLayout = module.parseInputBox(
  "──────\n❯ \n  hi\n\n──────\n")
assert(paddedLayout.hasText and paddedLayout.firstRow == 2 and paddedLayout.lastRow == 4,
  "blank leading/trailing draft rows were not included in the drag extents")
-- Wide glyphs take two terminal cells: measured as one, the drag stops short of
-- the last character. The box rules and the `❯` prompt stay one cell wide.
local _, _, _, cjkLayout = module.parseInputBox("──────\n❯ 中a\n──────\n")
assert(cjkLayout.firstColumn == 3 and cjkLayout.lastColumn == 5,
  "a CJK draft character was not measured as two cells")
local _, _, _, emojiLayout = module.parseInputBox("──────\n❯ 🎉a\n──────\n")
assert(emojiLayout.lastColumn == 5,
  "an emoji draft character was not measured as two cells")
-- Joiners and combining marks draw nothing: the family is three wide glyphs, `é` is one cell.
local _, _, _, familyLayout = module.parseInputBox("──────\n❯ 👨\u{200D}👩\u{200D}👧a\n──────\n")
assert(familyLayout.lastColumn == 9,
  "the zero-width joiners of a family emoji were measured as cells")
local _, _, _, markLayout = module.parseInputBox("──────\n❯ e\u{0301}\n──────\n")
assert(markLayout.lastColumn == 3, "a combining mark was measured as its own cell")
local terminalFrame = { x = 0, y = 0, w = 800, h = 700 }
assert(module.inputBorderY(terminalFrame, draftLines, draftTopIndex) == 200,
  "the input box border was not placed by rows above the window bottom")
assert(module.inputBorderY(terminalFrame, 8, 4) == 350,
  "a lower input box did not move the border down")
assert(module.inputBorderY(nil, 8, 2) == nil, "a missing window frame produced a border")
assert(module.inputBorderY(terminalFrame, 0, 2) == nil, "a zero-row screen produced a border")

local gridOnly = { x = 0, y = 68, w = 800, h = 632 }
assert(module.gridFrame(gridOnly, terminalFrame) == gridOnly,
  "a usable scroll-area frame was not preferred over the window frame")
assert(module.gridFrame(nil, terminalFrame) == terminalFrame,
  "a missing scroll-area frame did not fall back to the window frame")
assert(module.gridFrame({ x = 0, y = 68, w = 0, h = 0 }, terminalFrame) == terminalFrame,
  "a zero-size scroll-area frame did not fall back to the window frame")
assert(module.gridFrame({ x = 0, y = 68, w = 800 }, terminalFrame) == terminalFrame,
  "a scroll-area frame without a height did not fall back to the window frame")
assert(module.gridFrame(nil, nil) == nil, "a missing frame pair produced a frame")

-- Live-measured 34-row window: a 7x14 cell, the grid drawn from y=539 to y=1015,
-- and the scroll area's pads around it. Dividing that scroll area by 34 rows put
-- the input box border 8px low, and a whole row low on a tall window.
local anchorScroll = { x = 0, y = 532, w = 690, h = 490 }
local anchorCell = { x = 10, y = 1001, w = 7, h = 14 }
local anchored = module.anchoredGridFrame(anchorCell, 0, 34, 96, anchorScroll)
assert(anchored and anchored.y == 539 and anchored.h == 476,
  "the anchored grid frame missed the measured grid top")
assert(anchored.x == 10 and anchored.w == 672,
  "the anchored grid frame did not take x and width from the measured cell")
assert(module.inputBorderY(anchored, 34, 30) == 959,
  "the anchored frame missed the measured bottom of row 30")
assert(module.inputBorderY(anchorScroll, 34, 30) ~= 959,
  "the scroll-area frame already matched the measured row, so the fixture proves nothing")
-- An empty last buffer line is measured one line up; the row arithmetic moves with it.
local walked = module.anchoredGridFrame({ x = 10, y = 987, w = 7, h = 14 }, 1, 34, 96, anchorScroll)
assert(walked and walked.y == 539 and walked.h == 476,
  "measuring the anchor one line up moved the grid top")
local columnBlind = module.anchoredGridFrame(anchorCell, 0, 34, nil, anchorScroll)
assert(columnBlind and columnBlind.y == 539
    and columnBlind.x == anchorScroll.x and columnBlind.w == anchorScroll.w,
  "a caller without a column count lost the fallback frame's x and width")
assert(module.anchoredGridFrame(anchorCell, 0, 34, nil, nil) == nil,
  "an anchor with neither columns nor a fallback frame produced a width")
assert(module.anchoredGridFrame(nil, 0, 34, 96, anchorScroll) == nil,
  "a missing cell measurement produced an anchored frame")
assert(module.anchoredGridFrame(anchorCell, 0, 0, 96, anchorScroll) == nil,
  "a zero-row screen produced an anchored frame")
assert(module.anchoredGridFrame(anchorCell, 40, 34, 96, anchorScroll) == nil,
  "an anchor line above the first grid row produced a frame")
assert(module.anchoredGridFrame({ x = 10, y = 1001, w = 7, h = 30 }, 0, 34, 96),
  "a 30px cell was rejected inside the accepted height range")
assert(module.anchoredGridFrame({ x = 10, y = 1001, w = 7, h = 31 }, 0, 34, 96) == nil,
  "an oversized cell height was trusted")
assert(module.anchoredGridFrame({ x = 10, y = 1001, w = 7, h = 7.9 }, 0, 34, 96) == nil,
  "an undersized cell height was trusted")
assert(module.anchoredGridFrame({ x = 10, y = 1001, w = 20.1, h = 14 }, 0, 34, 96) == nil,
  "an oversized cell width was trusted")
assert(module.anchoredGridFrame({ x = 10, y = 1001, w = 2.9, h = 14 }, 0, 34, 96) == nil,
  "an undersized cell width was trusted")
-- Horizontally out of the scroll area on purpose: a vertical miss moves the frame's
-- bottom too, and the bottom check below would take the blame for it.
assert(module.anchoredGridFrame({ x = 700, y = 1001, w = 7, h = 14 }, 0, 34, 96, anchorScroll) == nil,
  "a cell measured past the scroll area's right edge was trusted")
assert(module.anchoredGridFrame({ x = -10, y = 1001, w = 7, h = 14 }, 0, 34, 96, anchorScroll) == nil,
  "a cell measured left of the scroll area was trusted")
assert(module.anchoredGridFrame(anchorCell, 5, 34, 96, anchorScroll) == nil,
  "an anchor five rows clear of the grid bottom was trusted")

-- The AX walk behind that anchor is synchronous, and Terminal under load answers it in
-- hundreds of milliseconds: a burst of gestures may pay for it once, and a walk that
-- did stall may not be repeated for a minute. The walk is faked, its clock injected.
-- Scoped: this chunk sits at the same 200-local ceiling the module does.
do
local anchorClock = 100
local anchorWalks = 0
local function anchorTick() return anchorClock end
local function anchorWalk()
  anchorWalks = anchorWalks + 1
  return anchorCell, 1
end
local function slowAnchorWalk()
  anchorWalks = anchorWalks + 1
  anchorClock = anchorClock + 0.3
  return anchorCell, 1
end

local anchorHome = { x = 0, y = 0, w = 1200, h = 800 }

module.axAnchorReset()
local anchorBounds, anchorBelow = module.axAnchor(7, 34, 96, anchorHome, anchorWalk, anchorTick)
assert(anchorBounds == anchorCell and anchorBelow == 1 and anchorWalks == 1,
  "the first anchor resolution did not walk AX")
assert(select(2, module.axAnchor(7, 34, 96, anchorHome, anchorWalk, anchorTick)) == 1
    and anchorWalks == 1,
  "a second gesture in the same burst walked AX again")
anchorClock = 101.99
module.axAnchor(7, 34, 96, anchorHome, anchorWalk, anchorTick)
assert(anchorWalks == 1, "the anchor cache expired inside its TTL")
anchorClock = 102.01
assert(module.axAnchor(7, 34, 96, anchorHome, anchorWalk, anchorTick) == anchorCell
    and anchorWalks == 2,
  "the anchor cache outlived its TTL")
-- Cached against the inputs the anchor was measured for: another window, a screen that
-- gained a row or a resized grid all put the same bounds somewhere they cannot be.
module.axAnchor(8, 34, 96, anchorHome, anchorWalk, anchorTick)
assert(anchorWalks == 3, "a second window read the first one's cached anchor")
module.axAnchor(8, 35, 96, anchorHome, anchorWalk, anchorTick)
assert(anchorWalks == 4, "a changed line count read the cached anchor")
module.axAnchor(8, 35, 120, anchorHome, anchorWalk, anchorTick)
assert(anchorWalks == 5, "a changed column count read the cached anchor")

-- The bounds are absolute screen pixels, so a window dragged inside the TTL keeps its
-- id, its rows and its columns while every one of them moves: reused, the anchor puts
-- each click a whole window offset away from the cell it names.
module.axAnchorReset()
anchorWalks = 0
anchorClock = 150
module.axAnchor(7, 34, 96, anchorHome, anchorWalk, anchorTick)
assert(anchorWalks == 1, "the position-keyed anchor did not walk AX at all")
module.axAnchor(7, 34, 96, { x = 0, y = 0, w = 1200, h = 800 }, anchorWalk, anchorTick)
assert(anchorWalks == 1, "an unmoved window with an equal frame table walked AX again")
module.axAnchor(7, 34, 96, { x = 40, y = 0, w = 1200, h = 800 }, anchorWalk, anchorTick)
assert(anchorWalks == 2, "a window dragged sideways reused the anchor from its old position")
module.axAnchor(7, 34, 96, { x = 40, y = 25, w = 1200, h = 800 }, anchorWalk, anchorTick)
assert(anchorWalks == 3, "a window dragged down reused the anchor from its old position")
module.axAnchor(7, 34, 96, { x = 40, y = 25, w = 1200, h = 800 }, anchorWalk, anchorTick)
assert(anchorWalks == 3, "the moved window did not cache the anchor at its new position")
-- No frame to fingerprint is the caller's fallback ladder failing, not a move: the
-- cache still has to work, or every gesture there pays the synchronous AX walk.
module.axAnchor(7, 34, 96, nil, anchorWalk, anchorTick)
assert(anchorWalks == 4, "an absent frame silently reused the positioned anchor")
module.axAnchor(7, 34, 96, nil, anchorWalk, anchorTick)
assert(anchorWalks == 4, "two gestures without a frame each walked AX")

module.axAnchorReset()
anchorWalks = 0
anchorClock = 200
assert(module.axAnchor(7, 34, 96, anchorHome, slowAnchorWalk, anchorTick) == anchorCell
    and anchorWalks == 1,
  "a slow walk threw away the measurement it had already paid for")
anchorClock = anchorClock + 5
assert(module.axAnchor(7, 34, 96, anchorHome, anchorWalk, anchorTick) == nil and anchorWalks == 1,
  "the AX path kept walking after a stall")
anchorClock = anchorClock + 50
assert(module.axAnchor(7, 34, 96, anchorHome, anchorWalk, anchorTick) == nil and anchorWalks == 1,
  "the circuit breaker reopened early")
anchorClock = anchorClock + 6
assert(module.axAnchor(7, 34, 96, anchorHome, anchorWalk, anchorTick) == anchorCell
    and anchorWalks == 2,
  "the circuit breaker never reopened")
-- A walk that found nothing is not cached: the next gesture has to look again.
module.axAnchorReset()
anchorWalks = 0
local function emptyWalk()
  anchorWalks = anchorWalks + 1
  return nil
end
assert(module.axAnchor(7, 34, 96, anchorHome, emptyWalk, anchorTick) == nil,
  "an empty walk produced bounds")
module.axAnchor(7, 34, 96, anchorHome, emptyWalk, anchorTick)
assert(anchorWalks == 2, "a failed resolution was cached")
module.axAnchorReset()
end

-- The scroll-area BFS is synchronous AX exactly as the anchor walk is, and it ran per
-- gesture outside both the cache and the breaker: a burst paid a full 256-node walk
-- each time, and an open breaker still stalled the runloop carrying the next keystroke.
do
local scrollClock = 400
local scrollWalks = 0
local scrollArea, scrollFrame = { "area" }, { x = 40, y = 25, w = 1180, h = 700 }
local scrollHome = { x = 0, y = 0, w = 1200, h = 800 }
local function scrollTick() return scrollClock end
local function scrollWalk()
  scrollWalks = scrollWalks + 1
  return scrollArea, scrollFrame
end
local function slowScrollWalk()
  scrollWalks = scrollWalks + 1
  scrollClock = scrollClock + 0.3
  return scrollArea, scrollFrame
end
local function emptyScrollWalk()
  scrollWalks = scrollWalks + 1
  return nil, nil
end
local function anchorWalk() return anchorCell, 1 end

module.axAnchorReset()
local resolved, resolvedFrame = module.axScroll(7, scrollHome, scrollWalk, scrollTick)
assert(resolved == scrollArea and resolvedFrame == scrollFrame and scrollWalks == 1,
  "the first scroll-area resolution did not walk AX")
assert(module.axScroll(7, scrollHome, scrollWalk, scrollTick) == scrollArea and scrollWalks == 1,
  "a second gesture in the same burst walked the scroll area again")
scrollClock = 401.99
module.axScroll(7, scrollHome, scrollWalk, scrollTick)
assert(scrollWalks == 1, "the scroll-area cache expired inside its TTL")
scrollClock = 402.01
module.axScroll(7, scrollHome, scrollWalk, scrollTick)
assert(scrollWalks == 2, "the scroll-area cache outlived its TTL")
module.axScroll(8, scrollHome, scrollWalk, scrollTick)
assert(scrollWalks == 3, "a second window read the first one's cached scroll area")
-- The AXFrame is absolute screen pixels, so a window that moved or resized carries its
-- grid with it: the cached area would place every row where the window no longer is.
module.axScroll(8, { x = 40, y = 0, w = 1200, h = 800 }, scrollWalk, scrollTick)
assert(scrollWalks == 4, "a dragged window reused the scroll area from its old position")
module.axScroll(8, { x = 40, y = 0, w = 900, h = 800 }, scrollWalk, scrollTick)
assert(scrollWalks == 5, "a resized window reused the scroll area from its old size")
module.axScroll(8, { x = 40, y = 0, w = 900, h = 800 }, scrollWalk, scrollTick)
assert(scrollWalks == 5, "the moved window did not cache its scroll area at the new box")

-- A window with no scroll area at all is the one answer worth caching hardest: without
-- it every gesture there re-walks 256 nodes to be told the same thing.
module.axAnchorReset()
scrollWalks = 0
module.axScroll(7, scrollHome, emptyScrollWalk, scrollTick)
module.axScroll(7, scrollHome, emptyScrollWalk, scrollTick)
assert(scrollWalks == 1, "a window without a scroll area was walked again per gesture")

-- One breaker over both walks: a stall in either stands the whole AX path down, and
-- the caller falls back to the window box alone rather than waiting on it.
module.axAnchorReset()
scrollWalks = 0
scrollClock = 500
module.axScroll(7, scrollHome, slowScrollWalk, scrollTick)
assert(scrollWalks == 1, "the slow scroll walk fixture did not run")
scrollClock = scrollClock + 5
assert(module.axScroll(7, { x = 1, y = 1, w = 900, h = 800 }, scrollWalk, scrollTick) == nil
    and scrollWalks == 1,
  "the scroll-area walk kept running after its own stall")
assert(module.axAnchor(7, 34, 96, scrollHome, anchorWalk, scrollTick) == nil,
  "a stalled scroll walk left the anchor walk running")
scrollClock = scrollClock + 56
assert(module.axScroll(7, { x = 1, y = 1, w = 900, h = 800 }, scrollWalk, scrollTick) == scrollArea
    and scrollWalks == 2,
  "the circuit breaker never reopened for the scroll-area walk")

-- The other direction: a stall the anchor walk paid for fences the scroll walk too.
module.axAnchorReset()
scrollWalks = 0
scrollClock = 700
module.axAnchor(7, 34, 96, scrollHome, function()
  scrollClock = scrollClock + 0.3
  return anchorCell, 1
end, scrollTick)
scrollClock = scrollClock + 5
assert(module.axScroll(7, scrollHome, scrollWalk, scrollTick) == nil and scrollWalks == 0,
  "a stalled anchor walk left the scroll-area walk running")
module.axAnchorReset()
end

assert(module.parseInputBox("plain text\nwith no box at all\n") == nil,
  "a screen without an input box produced a draft")
assert(module.parseInputBox("") == nil, "empty screen produced a draft")
assert(module.parseInputBox(nil) == nil, "missing screen text produced a draft")

local wrappedDraft = module.parseInputBox(screenWrapped)
local reflowedDraft = module.parseInputBox(screenReflowed)
assert(wrappedDraft:find("parrot sings loudly today", 1, true),
  "a wrapped row join did not canonicalize to a plain space")
assert(#wrappedDraft - #reflowedDraft == 7,
  "the captured reflow pair does not differ by the seven deleted characters")
assert(module.cutDiff(wrappedDraft, reflowedDraft) == "sleepy ",
  "a deletion that moved the wrap point did not diff to the deleted run")

-- Synthetic: the classic renderer's rounded input box. Egor's live setting is
-- tui=fullscreen, so this shape could not be captured without rewriting it.
local roundedInputBox = [[
some transcript output above
╭──────────────────────────────────────╮
│ > hello brave new world              │
╰──────────────────────────────────────╯
]]
assert(module.parseInputBox(roundedInputBox) == "hello brave new world",
  "rounded input box draft was not parsed")

assert(module.cutDiff(module.parseInputBox(screenDraft),
    module.parseInputBox(screenShorter)) == "brave ",
  "captured before/after screens did not diff to the deleted word")
assert(module.cutDiff("abc", "abc") == nil, "unchanged text produced a cut")
assert(module.cutDiff("abc", "abcd") == nil, "grown text produced a cut")
assert(module.cutDiff("ab", "axc") == nil, "text that grew while typing produced a cut")
assert(module.cutDiff("abc", "axc") == nil, "text replaced in place produced a cut")
assert(module.cutDiff("hello world", "world") == "hello ",
  "deletion at the start was not recovered")
assert(module.cutDiff("hello world", "hello") == " world",
  "deletion at the end was not recovered")
assert(module.cutDiff("hello brave world", "hello world") == "brave ",
  "deletion in the middle was not recovered")
assert(module.cutDiff("аабв", "абв") == "а",
  "byte-wise diff split a UTF-8 character")
assert(module.cutDiff(nil, "abc") == nil, "missing before text produced a cut")
assert(module.cutDiff("abc", nil) == nil, "missing after text produced a cut")
-- Anything but one removed run is a screen that changed for another reason, and
-- the prefix/suffix slice across it is text nobody cut.
assert(module.cutDiff("hello world", "xyz") == nil,
  "an unrelated shorter screen produced a cut")
-- A wrapped draft reflows when a word goes: the newline moves, so the change is
-- no longer one run and the old diff handed over "bbb cccc dddd eeee\nffff ".
assert(module.cutDiff("aaaa bbb cccc dddd eeee\nffff gggg",
    "aaaa cccc dddd eeee ffff\ngggg") == nil,
  "a reflowed wrap produced a cut")

env.hs = {
  eventtap = {
    event = {
      types = {
        leftMouseDown = 1,
        leftMouseUp = 2,
        rightMouseDown = 3,
        leftMouseDragged = 6,
        keyDown = 10,
        otherMouseDown = 25,
      },
      properties = {
        eventSourceUserData = 91,
        keyboardEventAutorepeat = 92,
        mouseEventClickState = 93,
      },
    },
  },
}

local function eventFlags(names)
  local flags = {}
  for _, name in ipairs(names) do flags[name] = true end
  function flags:containExactly(expected)
    local count = 0
    for name, value in pairs(self) do
      if value == true then count = count + 1 end
    end
    if count ~= #expected then return false end
    for _, name in ipairs(expected) do
      if self[name] ~= true then return false end
    end
    return true
  end
  return flags
end

local function keyEvent(keyCode, modifiers, isRepeat, label, characters, modified)
  local event = {
    keyCode = keyCode,
    flags = eventFlags(modifiers),
    properties = { [92] = isRepeat and 1 or 0 },
    label = label,
  }
  function event:getType() return 10 end
  function event:getKeyCode() return self.keyCode end
  function event:getFlags() return self.flags end
  function event:getProperty(property) return self.properties[property] or 0 end
  -- Only keys that insert text carry characters, exactly as NSEvent reports them:
  -- clean ignores the modifiers, the other reports what the press actually types.
  function event:getCharacters(clean)
    if clean == false then
      return modified ~= nil and modified or characters
    end
    return characters
  end
  function event:copy()
    return keyEvent(self.keyCode, modifiers, isRepeat, self.label, characters, modified)
  end
  return event
end

-- hs.eventtap posts our own keystrokes through the very tap this module installs, so
-- every emitted plan comes straight back into handleEvent. Only the replay marker
-- tells it from the user's typing, and a flow that mistakes one for a user key holds
-- its own DEL: the mock that skipped this loop is why a dead live build stayed green.
local function selfPostedKeyEvent(character, isDown)
  local event = keyEvent(0, {}, false, "self", character)
  event.properties[91] = module.replayMarker
  function event:getType() return isDown and 10 or 11 end
  return event
end

local mouseEvent
mouseEvent = function(eventType, point, clickState)
  local event = { properties = { [92] = 0, [93] = clickState or 1 } }
  function event:getType() return eventType end
  function event:getKeyCode() return 0 end
  function event:getFlags() return eventFlags({}) end
  function event:getProperty(property) return self.properties[property] or 0 end
  function event:location() return point or { x = 0, y = 0 } end
  function event:copy() return mouseEvent(eventType, point, clickState) end
  return event
end

local function simulateDrag(y)
  module.handleEvent(mouseEvent(1))
  module.handleEvent(mouseEvent(6, { x = 120, y = y or 340 }))
  module.handleEvent(mouseEvent(2))
end

local function simulateClick()
  module.handleEvent(mouseEvent(1))
  module.handleEvent(mouseEvent(2))
end

-- A word/line selection: the TUI selects on the click itself, no drag arrives.
local function simulateMultiClick(clickState, y)
  module.handleEvent(mouseEvent(1))
  module.handleEvent(mouseEvent(2, { x = 120, y = y or 340 }, clickState))
end

local function integrationContext(types, opts)
  opts = opts or {}
  local clock = 20
  local observedNow = {
    bundleID = "com.apple.Terminal",
    windowID = 7,
    tabIndex = 1,
    tabElement = "tab-a",
  }
  local resolver
  local timeout
  local cutTimeout
  local gestureTimeout
  local gestureWatchdogTimeout
  local pointerSettleTimeout
  local pointerClearTimeout
  local pointer = opts.pointer and { x = opts.pointer.x, y = opts.pointer.y } or nil
  local pointerWarps = {}
  local pointerReads = 0
  local settleReads = 0
  local inPointerSettle = false
  local timeoutCount = 0
  local deferred
  local actions = {}
  local changeCount = 1
  local alertCount = 0
  local scrapeCallback
  local scrapeObserved
  local writtenText
  local mouseEvents = {}
  local observeCount = 0
  local focusedCount = 0
  local afterObserve
  local replays = {}
  local frameGone = false
  local frameLookupColumns
  local logCount = 0
  local caretPoint = opts.caret
  local caretCalibrationNeeded = opts.caretCalibrationNeeded == true
  local caretReads = 0
  module.setTestHooks({
    mouse = function(kind, point, clickState)
      mouseEvents[#mouseEvents + 1] =
        { kind = kind, x = point.x, y = point.y, clickState = clickState }
      -- A posted click drags the physical pointer with it, which is the whole reason
      -- a home saved per choreography ends up being the last one's click point.
      if pointer then pointer = { x = point.x, y = point.y } end
    end,
    usleep = function() end,
    replayProperty = 91,
    now = function() return clock end,
    absoluteTime = function() return clock * 1000000000 end,
    observe = function()
      observeCount = observeCount + 1
      local observed = observedNow
      local callback = afterObserve
      afterObserve = nil
      if callback then callback() end
      return observed
    end,
    focused = function()
      focusedCount = focusedCount + 1
      return observedNow.bundleID == "com.apple.Terminal" and observedNow.windowID or nil
    end,
    contentTypes = function() return types or {} end,
    readURL = function() return opts.url end,
    verdict = opts.verdict and function() return opts.verdict end or nil,
    fileExists = function() return opts.fileExists ~= false end,
    windowFrame = opts.windowFrame and function(windowID, _, columns)
      assert(windowID == 7, "the window frame was looked up for another window")
      frameLookupColumns = columns
      return not frameGone and opts.windowFrame or nil
    end or nil,
    log = function() logCount = logCount + 1 end,
    -- Installed for every context, answering nothing unless the case asked for a caret:
    -- the seam being present is what a gesture without one has to survive.
    caret = function(observed)
      caretReads = caretReads + 1
      assert(not observed or observed.windowID == 7,
        "the caret was read for another window than the gesture's")
      return caretPoint
    end,
    caretCalibrationNeeded = function(observed)
      assert(not observed or observed.windowID == 7,
        "the calibration state was read for another window than the gesture's")
      return caretCalibrationNeeded
    end,
    -- Only contexts that opt in stand for a real pointer; the rest keep the mouse hook
    -- alone, which is the module's "no physical pointer to move" case.
    pointer = opts.pointer and function(point)
      if not point then
        -- Counted, not just compared: live, a second save reads the pointer while the
        -- posted clicks still hold it, so reading twice per burst is the bug itself.
        -- The settle timer reads it too, to see whether the user moved it; that read
        -- is counted apart so the home reads above stay countable on their own.
        if inPointerSettle then
          settleReads = settleReads + 1
        else
          pointerReads = pointerReads + 1
        end
        return { x = pointer.x, y = pointer.y }
      end
      pointer = { x = point.x, y = point.y }
      pointerWarps[#pointerWarps + 1] = pointer
    end or nil,
    changeCount = function() return changeCount end,
    alert = function()
      alertCount = alertCount + 1
    end,
    scrape = function(callback, observed)
      actions[#actions + 1] = "scrape"
      if opts.scrapeThrows then error("scrape blew up") end
      scrapeObserved = observed
      scrapeCallback = callback
    end,
    writeText = function(text)
      actions[#actions + 1] = "write-text"
      writtenText = text
    end,
    loadImage = function()
      if opts.loadFails then return nil end
      return opts.image or {}
    end,
    writeImage = function() actions[#actions + 1] = "write-image" end,
    defer = function(fn) deferred = fn end,
    resolve = function(callback) resolver = callback end,
    after = function(delay, callback)
      -- Arming a timer is the cheapest place to make a step throw where a real one can:
      -- past the sentinel keystroke and still inside the call the press pcall'd.
      if opts.afterThrows == delay then
        error("timer arming blew up")
      end
      -- Only the re-scrape timers: the 0.28 pending deadline shares this hook.
      if delay == 0.15 then
        timeoutCount = timeoutCount + 1
      end
      timeout = { delay = delay, callback = callback, stopped = false }
      function timeout:stop() self.stopped = true end
      if delay == 0.15 then cutTimeout = timeout end
      -- A key pressed inside the gesture window arms the pending deadline over the
      -- same slot, which would leave the gesture's own timer unreachable from a test.
      if delay == 0.02 or delay == 0.05 then gestureTimeout = timeout end
      if delay == 2.5 then gestureWatchdogTimeout = timeout end
      if delay == 0.15 then pointerSettleTimeout = timeout end
      if delay == 0.5 then pointerClearTimeout = timeout end
      return timeout
    end,
    emit = function(plan)
      local bytes = module.planBytes(plan)
      if bytes == string.char(24, 25) then
        actions[#actions + 1] = "copy"
      elseif bytes == string.char(31) then
        actions[#actions + 1] = "undo"
      elseif bytes == module.planBytes(module.cutPlan()) then
        actions[#actions + 1] = "cut"
      elseif bytes == module.planBytes(module.sentinelPlan()) then
        actions[#actions + 1] = "sentinel"
      elseif bytes == module.planBytes(module.docStartPlan()) then
        actions[#actions + 1] = "doc-start"
      elseif bytes == module.planBytes(module.docEndPlan()) then
        actions[#actions + 1] = "doc-end"
      else
        actions[#actions + 1] = "image-paste"
      end
      -- Mirrors emit's own split: an atomic plan reaches the tty as one keystroke, and
      -- replaying it per character here would hide a module that forgot to.
      local characters = plan.atomic and { bytes } or module.planCharacters(plan)
      for _, character in ipairs(characters) do
        module.handleEvent(selfPostedKeyEvent(character, true))
        module.handleEvent(selfPostedKeyEvent(character, false))
      end
    end,
    chord = function(modifiers, key)
      actions[#actions + 1] = "chord:" .. table.concat(modifiers, "+") .. "+" .. key
    end,
    post = function(event)
      actions[#actions + 1] = "replay"
      replays[#replays + 1] = event and event.label or "?"
    end,
    drop = function() actions[#actions + 1] = "policy-drop" end,
  })
  return {
    actions = actions,
    advance = function(delta) clock = clock + delta end,
    changeTarget = function()
      observedNow = {
        bundleID = "com.apple.Terminal",
        windowID = 7,
        tabIndex = 2,
        tabElement = "tab-b",
      }
    end,
    switchWindow = function(windowID)
      observedNow = { bundleID = "com.apple.Terminal", windowID = windowID,
        tabIndex = 1, tabElement = "tab-a" }
    end,
    switchApp = function(bundleID)
      observedNow = bundleID and { bundleID = bundleID }
        or { bundleID = "com.apple.Terminal", windowID = 7, tabIndex = 1, tabElement = "tab-a" }
    end,
    bumpClipboard = function() changeCount = changeCount + 1 end,
    alerts = function() return alertCount end,
    mouseEvents = function() return mouseEvents end,
    observations = function() return observeCount end,
    windowLookups = function() return focusedCount end,
    changeTargetAfterNextObservation = function()
      afterObserve = function()
        observedNow = {
          bundleID = "com.apple.Terminal",
          windowID = 7,
          tabIndex = 3,
          tabElement = "tab-c",
        }
      end
    end,
    wrote = function() return writtenText end,
    replayed = function() return table.concat(replays, ",") end,
    lastDelay = function() return timeout and timeout.delay end,
    cutTimerStopped = function() return cutTimeout ~= nil and cutTimeout.stopped end,
    timeouts = function() return timeoutCount end,
    scrapeContext = function() return scrapeObserved end,
    deliverScrape = function(screenText, backend)
      local callback = scrapeCallback
      scrapeCallback = nil
      assert(callback, "no scrape was awaiting a screen")
      if caretCalibrationNeeded then
        caretPoint = opts.caretAfterScrape
        caretCalibrationNeeded = false
      end
      callback(screenText, backend)
    end,
    -- Terminal answers whoever asked, in its own time: a callback taken here can be
    -- delivered after a later gesture has already asked for one of its own.
    takeScrape = function()
      local callback = scrapeCallback
      scrapeCallback = nil
      assert(callback, "no scrape was awaiting a screen")
      return callback
    end,
    dropWindowFrame = function() frameGone = true end,
    setCaret = function(point) caretPoint = point end,
    caretReads = function() return caretReads end,
    frameColumns = function() return frameLookupColumns end,
    logged = function() return logCount end,
    resolve = function(verdict) resolver(verdict) end,
    timeout = function() timeout.callback() end,
    fireTimer = function(delay)
      local function usable(candidate)
        return candidate and not candidate.stopped
          and not (delay and candidate.delay ~= delay)
      end
      local pending = usable(timeout) and timeout or (usable(gestureTimeout) and gestureTimeout)
      if not pending then
        return false
      end
      if pending == timeout then timeout = nil end
      if pending == gestureTimeout then gestureTimeout = nil end
      pending.callback()
      return true
    end,
    fireCutTimer = function() cutTimeout.callback() end,
    -- A deadline already queued in the runloop when its flight ended: stopping the
    -- timer no longer unqueues it, so the callback is kept and fired by hand later.
    takeGestureWatchdog = function()
      local armed = gestureWatchdogTimeout
      assert(armed and not armed.stopped, "no watchdog was armed for the gesture")
      gestureWatchdogTimeout = nil
      return armed.callback
    end,
    fireGestureWatchdog = function()
      if not gestureWatchdogTimeout or gestureWatchdogTimeout.stopped then
        return false
      end
      local fired = gestureWatchdogTimeout
      gestureWatchdogTimeout = nil
      fired.callback()
      return true
    end,
    pointerAt = function() return pointer end,
    movePointer = function(point) pointer = { x = point.x, y = point.y } end,
    pointerWarps = function() return pointerWarps end,
    pointerReads = function() return pointerReads end,
    settleReads = function() return settleReads end,
    firePointerSettle = function()
      if not pointerSettleTimeout or pointerSettleTimeout.stopped then
        return false
      end
      local fired = pointerSettleTimeout
      pointerSettleTimeout = nil
      inPointerSettle = true
      local ok, err = pcall(fired.callback)
      inPointerSettle = false
      assert(ok, err)
      return true
    end,
    firePointerClear = function()
      if not pointerClearTimeout or pointerClearTimeout.stopped then
        return false
      end
      local fired = pointerClearTimeout
      pointerClearTimeout = nil
      fired.callback()
      return true
    end,
    runDeferred = function()
      local fn = deferred
      deferred = nil
      if fn then fn() end
    end,
  }
end

local cPress = function(repeatDown)
  return keyEvent(8, { "cmd" }, repeatDown, "c")
end
local vPress = function(repeatDown)
  return keyEvent(9, { "cmd" }, repeatDown, "v")
end
local zPress = function(repeatDown)
  return keyEvent(6, { "cmd" }, repeatDown, "z")
end
local xPress = function(repeatDown)
  return keyEvent(7, { "cmd" }, repeatDown, "x")
end
local aPress = function(repeatDown)
  return keyEvent(0, { "cmd" }, repeatDown, "a")
end

-- Press Cmd+X, land the Claude verdict, then run the deferred tick that owns the
-- blocking before-scrape; dragThenCut adds the selection the cut path requires.
local function pressCut(context)
  module.handleEvent(xPress(false))
  context.resolve("claude")
  context.runDeferred()
end

local function dragThenCut(context, dragY)
  simulateDrag(dragY)
  pressCut(context)
end

local integration = integrationContext()
assert(module.handleEvent(cPress(false)), "cold integration Cmd+C was not consumed")
integration.advance(0.29)
integration.timeout()
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "replay",
  "late verdict duplicated a timed-out action")

integration = integrationContext()
assert(module.handleEvent(cPress(false)), "inverse-race Cmd+C was not consumed")
integration.resolve("claude")
integration.advance(0.29)
integration.timeout()
assert(#integration.actions == 1 and integration.actions[1] == "copy",
  "late timeout duplicated a resolved action")

integration = integrationContext()
module.handleEvent(cPress(false))
integration.changeTarget()
integration.changeTargetAfterNextObservation()
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "replay",
  "target-mismatched Cmd+C was not replayed after a second tab change")

integration = integrationContext()
module.handleEvent(zPress(false))
integration.changeTargetAfterNextObservation()
integration.resolve("not-claude")
assert(#integration.actions == 1 and integration.actions[1] == "policy-drop",
  "a target-mismatched non-copy replay was not policy-dropped")

integration = integrationContext({ "public.png" })
module.handleEvent(vPress(false))
integration.changeTarget()
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "policy-drop",
  "target-mismatched image Cmd+V was not policy-dropped")

integration = integrationContext()
assert(module.handleEvent(zPress(false)), "cold integration Cmd+Z was not consumed")
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "undo",
  "cold Claude Cmd+Z did not emit undo")

integration = integrationContext()
simulateDrag()
assert(module.handleEvent(xPress(false)), "cold integration Cmd+X was not consumed")
integration.resolve("claude")
assert(#integration.actions == 0, "the blocking screen scrape ran before the deferred tick")
integration.runDeferred()
assert(#integration.actions == 1 and integration.actions[1] == "scrape",
  "Cmd+X deleted before snapshotting the input box")
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "cut",
  "Cmd+X did not emit the cut plan once the before-screen arrived")
assert(integration.lastDelay() == 0.15, "cut re-scrape delay changed")
integration.timeout()
assert(#integration.actions == 3 and integration.actions[3] == "scrape",
  "Cmd+X did not re-scrape after the delay")
integration.deliverScrape(screenShorter)
assert(#integration.actions == 4 and integration.actions[4] == "write-text",
  "Cmd+X did not write the deleted text to the pasteboard")
assert(integration.wrote() == "brave ", "Cmd+X wrote the wrong text to the pasteboard")
assert(integration.alerts() == 0, "a successful cut raised an alert")

integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenOneChar)
assert(integration.actions[#integration.actions] == "undo",
  "a 1-char removal was not undone")
assert(integration.wrote() == nil, "a 1-char removal reached the pasteboard")
assert(integration.alerts() == 0, "a 1-char removal raised the cut alert")

integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenDraft)
assert(#integration.actions == 3 and integration.actions[2] == "cut",
  "an unchanged input box still wrote to the pasteboard")
assert(integration.wrote() == nil and integration.alerts() == 0,
  "an unchanged input box wrote text or alerted")

integration = integrationContext()
dragThenCut(integration)
integration.changeTarget()
integration.deliverScrape(screenDraft)
assert(#integration.actions == 1 and integration.actions[1] == "scrape",
  "Cmd+X sent DEL into a context that moved while scraping")
assert(integration.alerts() == 0, "suppressed Cmd+X raised an alert")

-- Without a before-image the removed text is unrecoverable, so the DEL never goes out
-- and the selection survives for the retry.
integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape("a screen with no input box")
assert(#integration.actions == 1, "an unparseable before-screen still deleted the draft")
assert(integration.wrote() == nil and integration.alerts() == 0,
  "an unparseable before-screen wrote text or alerted")
pressCut(integration)
assert(#integration.actions == 2 and integration.actions[2] == "scrape",
  "an unparseable before-screen dropped the selection or stranded the cut path")

integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(nil)
assert(integration.wrote() == nil and integration.alerts() == 0,
  "a failed after-scrape wrote text or alerted")

-- Automation denied: nothing happens at all, so the one thing left is to say so.
integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(nil)
assert(#integration.actions == 1, "an unreadable before-screen still deleted the draft")
assert(integration.wrote() == nil and integration.alerts() == 1,
  "an unreadable before-screen passed unannounced")

-- The tab can move during the delay; the after-screen then belongs to a draft
-- the DEL never touched.
integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.changeTarget()
integration.deliverScrape(screenShorter)
assert(integration.wrote() == nil and integration.alerts() == 0,
  "a cut wrote a draft scraped from a tab that moved")

-- A box that has not repainted within the delay is retried once, and the count
-- reports the cut, not the two attempts.
integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenShorter)
assert(integration.wrote() == "brave ", "a late repaint was not picked up by the retry")
assert(integration.alerts() == 0, "the retried cut raised an alert")

integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenDraft)
assert(integration.timeouts() == 2, "an unrepainted box was not retried")
integration.timeout()
integration.deliverScrape(screenDraft)
assert(integration.timeouts() == 2, "an unrepainted box kept rescraping past one retry")

local function roundedScreen(draft)
  return "╭──────────────────────────╮\n│ > " .. draft .. " │\n╰──────────────────────────╯\n"
end
integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(roundedScreen("привет мир"))
integration.timeout()
integration.deliverScrape(roundedScreen("привет"))
assert(integration.wrote() == " мир", "a Cyrillic cut did not reach the pasteboard intact")

-- Without a drag there is nothing selected, and DEL would be a plain backspace.
integration = integrationContext()
simulateClick()
assert(module.handleEvent(xPress(false)), "click-only Cmd+X was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == 0, "Cmd+X without a selection scraped or deleted")

integration = integrationContext()
simulateMultiClick(2)
pressCut(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenShorter)
assert(integration.wrote() == "brave ", "a double-click word selection did not cut")

integration = integrationContext()
simulateMultiClick(3)
pressCut(integration)
assert(#integration.actions == 1 and integration.actions[1] == "scrape",
  "a triple-click line selection did not enter the cut flow")

-- A scrape that raises must not strand cutInFlight: the next Cmd+X still runs.
integration = integrationContext(nil, { scrapeThrows = true })
dragThenCut(integration)
dragThenCut(integration)
assert(#integration.actions == 2, "a failed cut left the cut path stuck in flight")

integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
local stranded = integration
integration = integrationContext()
assert(stranded.cutTimerStopped(),
  "setTestHooks left the previous cut re-scrape timer armed")

-- A selection left behind by a plain shell must not arm the next Cmd+X.
integration = integrationContext(nil, { verdict = "not-claude" })
simulateDrag()
pressCut(integration)
assert(#integration.actions == 0, "a not-claude mouse-up armed the cut")
integration = integrationContext(nil, { verdict = "not-claude" })
simulateMultiClick(2)
pressCut(integration)
assert(#integration.actions == 0, "a not-claude double-click armed the cut")

-- A press on a window that is not the focused one is spent bringing it forward, and
-- Terminal keeps that click rather than passing it down: the TUI painted no selection
-- however far the press was dragged, so the next character must not send a DEL after it.
integration = integrationContext()
integration.switchWindow(8)
module.handleEvent(mouseEvent(1))
integration.switchWindow(7)
module.handleEvent(mouseEvent(6, { x = 120, y = 340 }))
module.handleEvent(mouseEvent(2, { x = 120, y = 340 }))
pressCut(integration)
assert(#integration.actions == 0, "a press that brought its own window forward armed the cut")

-- A hand drags a click by a pixel or two on its way off the button; the TUI selects
-- nothing inside one character, and arming for it costs the next keystroke a character.
integration = integrationContext()
module.handleEvent(mouseEvent(1, { x = 118, y = 339 }))
module.handleEvent(mouseEvent(6, { x = 120, y = 340 }))
module.handleEvent(mouseEvent(2, { x = 120, y = 340 }))
pressCut(integration)
assert(#integration.actions == 0, "a click jiggled by two pixels armed the cut")

integration = integrationContext()
module.handleEvent(mouseEvent(1, { x = 100, y = 340 }))
module.handleEvent(mouseEvent(6, { x = 120, y = 340 }))
module.handleEvent(mouseEvent(2, { x = 120, y = 340 }))
pressCut(integration)
assert(#integration.actions == 1 and integration.actions[1] == "scrape",
  "a drag across characters no longer armed the cut")

-- A plain click selects nothing, so it must not pay for the walk over the tab list. The
-- press pays one window lookup and the release none: that lookup is the whole reason the
-- release can tell a selection from a click that only brought its window forward.
integration = integrationContext()
module.handleEvent(mouseEvent(1))
local beforeUp = integration.observations()
assert(integration.windowLookups() == 1, "a press did not read the window it landed in")
module.handleEvent(mouseEvent(2))
assert(integration.observations() == beforeUp,
  "a plain mouse-up looked up the frontmost app with nothing to arm")
assert(integration.windowLookups() == 1, "a mouse-up paid for a window lookup of its own")

-- A key pressed with the button still down drops selectionPoint; the drag it belongs to
-- still has to release as a drag, or a live selection goes unarmed.
integration = integrationContext()
module.handleEvent(mouseEvent(1, { x = 100, y = 340 }))
module.handleEvent(mouseEvent(6, { x = 130, y = 340 }))
module.handleEvent(keyEvent(4, {}, false, "q", "q"))
module.handleEvent(mouseEvent(2, { x = 130, y = 340 }))
pressCut(integration)
assert(#integration.actions > 0, "a key typed mid-drag disarmed the selection the drag made")

-- Unknown at the press and unknown at the release is not the same window.
integration = integrationContext()
integration.switchApp("com.apple.Safari")
module.handleEvent(mouseEvent(1))
integration.switchWindow(nil)
module.handleEvent(mouseEvent(6, { x = 120, y = 340 }))
module.handleEvent(mouseEvent(2, { x = 120, y = 340 }))
pressCut(integration)
assert(#integration.actions == 0, "two unknown window ids armed the cut as a match")

-- A drag that ended while another app was frontmost never selected Claude's draft.
integration = integrationContext()
integration.switchApp("com.apple.Safari")
simulateDrag()
integration.switchApp(nil)
pressCut(integration)
assert(#integration.actions == 0, "a drag in another app armed the cut")

-- A bare DEL through an emoji removes one grapheme, not one codepoint.
integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(roundedScreen("hi 👨‍👩‍👧 there"))
integration.timeout()
integration.deliverScrape(roundedScreen("hi  there"))
assert(integration.actions[#integration.actions] == "undo",
  "a one-grapheme emoji removal was not read as a no-selection backspace")
assert(integration.wrote() == nil, "a one-grapheme emoji removal reached the pasteboard")

-- A flag is one grapheme built from two regional indicators.
integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(roundedScreen("hi 🇯🇵 there"))
integration.timeout()
integration.deliverScrape(roundedScreen("hi  there"))
assert(integration.actions[#integration.actions] == "undo",
  "a flag emoji removal was not read as a no-selection backspace")

integration = integrationContext()
dragThenCut(integration)
assert(#integration.actions == 1 and integration.actions[1] == "scrape",
  "a dragged selection did not enter the cut flow")

integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenShorter)
local afterFirstCut = #integration.actions
pressCut(integration)
assert(#integration.actions == afterFirstCut,
  "a second Cmd+X cut again without a new selection")

integration = integrationContext()
simulateDrag()
module.handleEvent(cPress(false))
integration.resolve("claude")
pressCut(integration)
assert(#integration.actions == 1 and integration.actions[1] == "copy",
  "Cmd+C did not clear the selection it consumed")

integration = integrationContext()
simulateDrag()
module.menuCopy()
pressCut(integration)
assert(#integration.actions == 1 and integration.actions[1] == "copy",
  "menuCopy did not clear the selection it consumed")

integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "cut",
  "the first cut did not reach its DEL")
dragThenCut(integration)
assert(#integration.actions == 2, "a Cmd+X mid-flight started a second cut")
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(integration.wrote() == "brave ", "the in-flight cut did not finish")

-- A drag that ended above the input box selected transcript, not draft: Claude's
-- own copy chord takes it, and nothing is deleted.
integration = integrationContext(nil, { windowFrame = terminalFrame })
dragThenCut(integration, 100)
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "copy",
  "a transcript selection was deleted instead of copied")
assert(integration.timeouts() == 0 and integration.alerts() == 0,
  "a transcript copy scheduled the cut re-scrape or alerted")
pressCut(integration)
assert(#integration.actions == 2, "a transcript copy left the selection state set")

integration = integrationContext(nil, { windowFrame = terminalFrame })
dragThenCut(integration, 200)
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "cut",
  "a drag ending exactly on the border did not fall back to the cut path")

integration = integrationContext(nil, { windowFrame = terminalFrame })
dragThenCut(integration)
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "cut",
  "a drag inside the input box did not cut")

-- The transcript check asks for the same frame the word gesture does. Keyed without
-- the columns its parse already carries, that lookup misses the anchor the gesture
-- cached and overwrites it, so alternating Cmd+X with a chord pays a fresh AX walk
-- on every press.
do
local draftColumns = select(4, module.parseInputBox(screenDraft)).columns
assert(type(draftColumns) == "number" and draftColumns > 0,
  "the draft fixture reports no column count to pass down")
integration = integrationContext(nil, { windowFrame = terminalFrame })
dragThenCut(integration, 100)
integration.deliverScrape(screenDraft)
assert(integration.frameColumns() == draftColumns,
  "the transcript check looked the window frame up without its column count")
end

integration = integrationContext()
dragThenCut(integration, 10)
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "cut",
  "an unavailable window frame did not fall back to the cut path")

local function cellLen(text)
  local count = utf8 and utf8.len and utf8.len(text)
  return type(count) == "number" and count or #text
end

local function selectAll(context, screenText)
  assert(module.handleEvent(aPress(false)), "Cmd+A was not consumed")
  context.resolve("claude")
  context.runDeferred()
  context.deliverScrape(screenText)
end

-- Expected drag geometry, rebuilt from the fixture rather than snapshotted: the
-- draft occupies the single row below the top border, starting after the two
-- prompt cells, and the screen is as wide as its widest scraped line.
local screenColumns = 0
for line in (screenDraft .. "\n"):gmatch("([^\n]*)\n") do
  screenColumns = math.max(screenColumns, cellLen(line))
end
local draftRow = draftTopIndex + 1
local cellHeight = terminalFrame.h / draftLines
local cellWidth = terminalFrame.w / screenColumns
local draftRowBottom = terminalFrame.y + terminalFrame.h - (draftLines - draftRow) * cellHeight
local expectedY = draftRowBottom - cellHeight / 2
local promptCells = cellLen("❯\194\160")
local expectedStartX = (promptCells + 1 - 0.5) * cellWidth
local expectedEndX = (promptCells + cellLen("hello brave new world") - 0.1) * cellWidth

integration = integrationContext(nil, { windowFrame = terminalFrame })
selectAll(integration, screenDraft)
local drag = integration.mouseEvents()
assert(#drag == 3 and drag[1].kind == "down" and drag[2].kind == "dragged"
    and drag[3].kind == "up",
  "Cmd+A did not post a down/drag/up sequence")
for _, event in ipairs(drag) do
  assert(event.y > draftRowBottom - cellHeight and event.y < draftRowBottom,
    "a Cmd+A drag point left the draft text row")
  assert(math.abs(event.y - expectedY) < 0.001, "a Cmd+A drag point missed the row center")
end
assert(math.abs(drag[1].x - expectedStartX) < 0.001,
  "the drag did not start at the first draft character cell")
assert(math.abs(drag[3].x - expectedEndX) < 0.001,
  "the drag did not end at the last draft character cell")
assert(#integration.actions == 1 and integration.actions[1] == "scrape",
  "Cmd+A emitted a key plan")
assert(integration.alerts() == 0, "Cmd+A raised an alert")

integration = integrationContext(nil, { windowFrame = terminalFrame })
assert(module.handleEvent(aPress(false)), "Cmd+A on an empty input was not consumed")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenEmptyInput)
assert(#integration.mouseEvents() == 0, "Cmd+A dragged across an empty input box")
assert(integration.alerts() == 0, "Cmd+A on an empty input raised an alert")

-- A second pass landing mid-flight would interleave its drag with this one's.
integration = integrationContext(nil, { windowFrame = terminalFrame })
assert(module.handleEvent(aPress(false)), "Cmd+A was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(module.handleEvent(aPress(false)), "a second Cmd+A was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == 1, "a second Cmd+A scraped while the first was in flight")
integration.deliverScrape(screenDraft)
assert(#integration.mouseEvents() == 3, "the in-flight Cmd+A did not drag once")
selectAll(integration, screenDraft)
assert(#integration.mouseEvents() == 6, "the guard outlived the completed Cmd+A pass")

-- Without a window frame there is no way to turn rows and columns into pixels.
integration = integrationContext()
selectAll(integration, screenDraft)
assert(#integration.mouseEvents() == 0, "Cmd+A dragged without a window frame")

integration = integrationContext(nil, { windowFrame = terminalFrame })
selectAll(integration, screenDraft)
assert(module.handleEvent(xPress(false)), "Cmd+X after Cmd+A was not consumed")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenDraft)
assert(integration.actions[#integration.actions] == "cut",
  "the synthetic drag did not leave a selection for Cmd+X")

-- The AppleScript scrape is 21-80ms of blocked runloop per screen; the window's AXTextArea
-- answers in a fraction of one, but its value is the whole scrollback with the visible
-- screen at the end, and only a scrape's own line count says how much of that value the
-- screen is. Scoped: this chunk sits at the same 200-local ceiling the module does.
do
local screen = "first row\nsecond row\nthird row\n"
local buffered = "old line one\nold line two\nfirst row\nsecond row\nthird row\n"

assert(module.axTextTail(buffered, 3) == screen, "the tail of the buffer was not the screen")
assert(module.axTextTail(buffered, 5) == buffered, "a tail as long as the buffer was cut short")
assert(module.axTextTail("only one line\n", 3) == nil,
  "a buffer with fewer lines than the screen produced a tail")
assert(module.axTextTail(nil, 3) == nil and module.axTextTail(buffered, 0) == nil,
  "a missing value or row count produced a tail")
-- An AX value can arrive without its final newline; the screen handed to parseInputBox
-- always has one, exactly as the AppleScript scrape does.
assert(module.axTextTail("old\nfirst row\nsecond row\nthird row", 3) == screen,
  "an unterminated AX value did not produce a terminated screen")

assert(module.axTextMatches(screen, buffered, 3),
  "an equal tail was not calibrated as AX-capable")
assert(module.axTextMatches("first row  \nsecond row\nthird row\t\n", buffered, 3),
  "trailing padding alone failed the calibration")
assert(not module.axTextMatches("first row\nSECOND row\nthird row\n", buffered, 3),
  "a differing line was calibrated as AX-capable")
assert(not module.axTextMatches(screen, buffered, 4),
  "a tail shifted by one row was calibrated as AX-capable")
assert(not module.axTextMatches(screen, "one\ntwo\n", 3),
  "a buffer shorter than the screen was calibrated as AX-capable")
assert(not module.axTextMatches(nil, buffered, 3), "a missing scrape calibrated anything")

assert(module.axTextRead(100, 65536).full == true, "a small buffer asked for a ranged read")
local ranged = module.axTextRead(70000, 65536)
assert(ranged and not ranged.full and ranged.location == 4464 and ranged.length == 65536,
  "the ranged read did not ask for the last cap characters")
assert(module.axTextRead(0, 65536) == nil and module.axTextRead(nil, 65536) == nil,
  "an empty buffer produced a read")
assert(module.axText.cap == 65536, "the tail cap moved away from the read plan tested here")

module.axAnchorReset()
local box = { windowID = 7, tab = "tab-a", tabIndex = 1, x = 0, y = 0, w = 1200, h = 800 }
local element = { "text-area" }
local walks = 0
local function walk()
  walks = walks + 1
  return element, buffered
end
local entry = module.axTextCalibrate(screen, box, walk)
assert(entry and entry.capable and entry.rows == 3 and entry.element == element and walks == 1,
  "the first scrape did not calibrate the window against its own AX tail")
assert(module.axTextFresh(box) == entry, "the calibration was not cached for its own box")
local secondBox = { windowID = 8, tab = "tab-b", tabIndex = 2,
  x = 40, y = 0, w = 1000, h = 700 }
local secondEntry = module.axTextCalibrate(screen, secondBox, walk)
assert(module.axTextFresh(box) == entry and module.axTextFresh(secondBox) == secondEntry,
  "alternating windows evicted each other's calibration")

-- hs.axuielement hands out a fresh wrapper per observation and compares by the AX element
-- behind it: keyed by the wrapper, every action would miss the calibration of its own tab.
local tabMeta = { __eq = function(left, right) return left.id == right.id end }
local function tabWrapper(id) return setmetatable({ id = id }, tabMeta) end
local wrapped = { windowID = 11, tab = tabWrapper("front"), tabIndex = 1,
  x = 0, y = 0, w = 1200, h = 800 }
local wrappedEntry = module.axTextCalibrate(screen, wrapped, walk)
local reobserved = { windowID = 11, tab = tabWrapper("front"), tabIndex = 1,
  x = 0, y = 0, w = 1200, h = 800 }
assert(tostring(wrapped.tab) ~= tostring(reobserved.tab),
  "the tab wrappers stringified alike, so this fixture cannot see what the key is built from")
assert(module.axTextFresh(reobserved) == wrappedEntry,
  "the next action's tab wrapper missed the calibration of the tab it names")
reobserved.tab = tabWrapper("replaced")
assert(module.axTextFresh(reobserved) == nil,
  "a tab replaced at the same index read the calibration of the tab before it")
-- The row count the tail is cut to is exactly what a resize changes, and another tab of
-- the same window has its own text area: the cached element would answer with a screen
-- that is not the one in front.
assert(module.axTextFresh({ windowID = 7, tab = "tab-a", tabIndex = 1, x = 0, y = 0,
  w = 1200, h = 700 }) == nil, "a resized window reused the calibration from its old box")
assert(module.axTextFresh({ windowID = 7, tab = "tab-a", tabIndex = 1, x = 40, y = 0,
  w = 1200, h = 800 }) == nil, "a dragged window reused the calibration from its old box")
assert(module.axTextFresh({ windowID = 8, tab = "tab-a", tabIndex = 1, x = 0, y = 0,
  w = 1200, h = 800 }) == nil, "a second window read the first one's calibration")
assert(module.axTextFresh({ windowID = 7, tab = "tab-b", tabIndex = 2, x = 0, y = 0,
  w = 1200, h = 800 }) == nil, "another tab of the same window read its calibration")
assert(module.axTextFresh(nil) == nil, "an absent window box matched a calibration")

module.axTextReset()
local evictionBoxes = {}
for index = 1, module.axText.limit + 1 do
  integration.advance(1)
  local evictionBox = { windowID = 100 + index, tab = "tab-" .. index, tabIndex = index,
    x = index, y = 0, w = 1200, h = 800 }
  evictionBoxes[index] = evictionBox
  module.axTextCalibrate(screen, evictionBox, walk)
end
assert(module.axTextFresh(evictionBoxes[1]) == nil,
  "the oldest calibration survived past the cache bound")
for index = 2, #evictionBoxes do
  assert(module.axTextFresh(evictionBoxes[index]),
    "eviction removed a newer calibration before the oldest one")
end
assert(module.axText.limit == 8, "the calibration cache bound moved away from eight entries")

-- Eviction goes by last use: the window being worked in is calibrated once and read from
-- then on, so by calibration age it would be the first entry thrown away.
module.axTextReset()
local hotBox = { windowID = 300, tab = "tab-hot", tabIndex = 1, x = 0, y = 0, w = 1200, h = 800 }
local idleBox = { windowID = 301, tab = "tab-idle", tabIndex = 1, x = 0, y = 0, w = 1200, h = 800 }
module.axTextCalibrate(screen, hotBox, walk)
integration.advance(1)
module.axTextCalibrate(screen, idleBox, walk)
integration.advance(1)
assert(module.axTextFresh(hotBox), "the hot calibration was gone before anything was evicted")
for index = 3, module.axText.limit + 1 do
  integration.advance(1)
  module.axTextCalibrate(screen, { windowID = 300 + index, tab = "tab-" .. index,
    tabIndex = 1, x = 0, y = 0, w = 1200, h = 800 }, walk)
end
assert(module.axTextFresh(hotBox), "the most recently used calibration was evicted first")
assert(module.axTextFresh(idleBox) == nil,
  "the least recently used calibration survived the cache bound")

-- A mismatch is cached as a mismatch: that window stays AppleScript-only until something
-- invalidates the calibration, instead of paying an AX probe per scrape to be told again.
module.axTextReset()
local mismatched = module.axTextCalibrate("first row\nSECOND row\nthird row\n", box, walk)
assert(mismatched and mismatched.capable == false, "a mismatched tail stayed AX-capable")
assert(module.axTextFresh(box) == mismatched, "the AppleScript-only verdict was not cached")
-- A walk that answered nothing is not that verdict: the breaker it opens lasts a minute,
-- while an entry stored for it would hold this window off AX for the whole TTL.
assert(module.axTextCalibrate(screen, box, function() return nil, nil end) == nil
    and module.axTextFresh(box) == nil,
  "a walk that found no text area was stored as an AppleScript-only verdict")
assert(module.axTextCalibrate(screen, nil, walk) == nil
    and module.axTextCalibrate("", box, walk) == nil
    and module.axTextFresh(box) == nil,
  "calibration without a window box or without a screen left an entry behind")
-- One unmeasurable window must not cost every other window its calibration.
module.axTextCalibrate(screen, box, walk)
assert(module.axTextCalibrate(screen, nil, walk) == nil and module.axTextFresh(box),
  "a calibration without a box cleared the whole cache")

-- The breaker is what a stalled walk leaves behind, and calibration behind an open one
-- has nothing to store: the next scrape re-measures instead of reading a stale verdict.
module.axTextReset()
module.axTextCalibrate(screen, box, function()
  integration.advance(1)
  return element, buffered
end)
local blockedWalks = walks
assert(module.axTextCalibrate(screen, box, walk) == nil and module.axTextFresh(box) == nil
    and walks == blockedWalks,
  "a calibration behind an open breaker stored a verdict it never measured")
integration.advance(62)
assert((module.axTextCalibrate(screen, box, walk) or {}).capable == true,
  "the calibration stayed blocked after the breaker closed")
module.axTextReset()

module.axTextCalibrate(screen, box, walk)
module.axTextReset()
assert(module.axTextFresh(box) == nil, "the scrape-calibration reset left it in place")
module.axTextCalibrate(screen, box, walk)
module.axAnchorReset()
assert(module.axTextFresh(box) == nil, "the AX reset spared the scrape calibration")

-- hs.window.get walks every window of every application (28-85ms live) where Terminal's
-- own focused window answers in 0.05ms, and both the scrape and the grid math wanted the
-- same object.
module.axTextReset()
local lookups = 0
local function lookup(windowID)
  lookups = lookups + 1
  return { id = function() return windowID end, walked = true }
end
local front = { id = function() return 7 end }
local other = { id = function() return 9 end }
assert(module.axWindow(7, front, lookup) == front and lookups == 0,
  "the focused window was not preferred over the window walk")
assert(module.axWindow(7, other, lookup) == front and lookups == 0,
  "a window already resolved was resolved again")
module.axTextReset()
local walked = module.axWindow(7, other, lookup)
assert(walked and walked.walked and lookups == 1,
  "a focused window with another id did not fall back to the walk")
assert(module.axWindow(7, other, lookup) == walked and lookups == 1,
  "the walked window was not held for the next call")
module.axAnchorReset()
module.axWindow(7, other, lookup)
assert(lookups == 2, "the AX reset spared the resolved-window cache")
assert(module.axWindow(nil, front, lookup) == nil and lookups == 2,
  "a missing window id produced a window")
-- A window that resolves to nothing is not cached as one: the id outlives the object it
-- named, and the answer next time may be a live window again.
module.axTextReset()
assert(module.axWindow(7, false, function() return nil end) == nil,
  "an unresolvable window id produced a window")
assert(module.axWindow(7, front, lookup) == front,
  "a failed resolution was cached as the window")
module.axTextReset()
end

-- The caret AX answers with is what lets a gesture skip typing a sentinel to find it.
-- Scoped: this chunk sits at the same 200-local ceiling the module does.
do
integration = integrationContext()
local box = { windowID = 7, tab = "tab-a", tabIndex = 1, x = 0, y = 0, w = 1200, h = 800 }
local screen = "one row\n"
local range = { location = 12, length = 0 }
-- The box of a caret at the end of a line: its width is the rest of the row, and the
-- cell it stands for is only ever its left edge.
local bounds = { x = 217, y = 604, w = 483, h = 14 }
local asked
local slow = false
local element = {
  attributeValue = function(_, name)
    return name == "AXSelectedTextRange" and range or nil
  end,
  parameterizedAttributeValue = function(_, name, parameter)
    if name ~= "AXBoundsForRange" then
      return nil
    end
    asked = parameter
    if slow then integration.advance(0.3) end
    return bounds
  end,
}
local function calibrate()
  module.axTextReset()
  return module.axTextCalibrate(screen, box, function() return element, screen end)
end
assert(calibrate().capable, "the caret fixture was not calibrated AX-capable")
local point = module.axCaretPoint(box)
assert(point and point.x == 217 and point.y == 604 and point.w == nil and point.h == nil,
  "the caret cell was not read as the left edge of its box alone")
assert(asked and asked.location == 12 and asked.length == 1,
  "the caret cell was not asked for as the one character at the caret's own offset")

module.axTextReset()
assert(module.axCaretPoint(box) == nil, "a window with no calibration produced a caret")
assert(module.axCaretPoint(nil) == nil, "an absent window box produced a caret")
module.axTextCalibrate("another screen\n", box, function() return element, screen end)
assert(module.axCaretPoint(box) == nil, "an AppleScript-only window produced a caret")

calibrate()
range = nil
assert(module.axCaretPoint(box) == nil, "a text area with no selection produced a caret")
range = { length = 0 }
assert(module.axCaretPoint(box) == nil, "a range without a location produced a caret")
range = { location = 12, length = 0 }
bounds = nil
assert(module.axCaretPoint(box) == nil, "a caret with no bounds produced a point")
bounds = { y = 604 }
assert(module.axCaretPoint(box) == nil, "a box without an x produced a caret point")

-- The read that stalled is still used; it is the next gesture that must not wait for
-- another one, and with the calibration gone that gesture is the sentinel's.
bounds = { x = 217, y = 604, w = 7, h = 14 }
calibrate()
local secondBox = { windowID = 8, tab = "tab-b", tabIndex = 2,
  x = 0, y = 0, w = 1200, h = 800 }
module.axTextCalibrate(screen, secondBox, function() return element, screen end)
slow = true
assert(module.axCaretPoint(box), "a slow caret read threw away the answer it did get")
assert(module.axCaretPoint(box) == nil, "a stalled caret read left its window AX-capable")
assert(module.axTextFresh(secondBox) == nil,
  "the AX breaker left another window's calibration cached")
module.axTextReset()
end

-- Pixels back to a cell: the caret box has to name the same (row, column) the scraped
-- cells carry, or the press lands on the word beside the one the user meant. Scoped:
-- this chunk sits at the same 200-local ceiling the module does.
do
local frame = { x = 100, y = 50, w = 960, h = 700 }
local rows, columns = 35, 96
local rowHeight, cellWidth = frame.h / rows, frame.w / columns
local function cellTopLeft(row, column)
  return { x = frame.x + (column - 1) * cellWidth,
    y = module.inputBorderY(frame, rows, row) - rowHeight }
end
local function assertCell(point, row, column, message)
  local gotRow, gotColumn = module.gridCell(frame, rows, columns, point)
  assert(gotRow == row and gotColumn == column,
    message .. ": read as " .. tostring(gotRow) .. "," .. tostring(gotColumn))
end
assertCell(cellTopLeft(1, 1), 1, 1, "the first cell of the grid")
assertCell(cellTopLeft(12, 47), 12, 47, "a cell on a later row, past the single digits")
assertCell(cellTopLeft(rows, columns), rows, columns, "the last cell of the grid")
-- The forward direction's own output: a centre and a top-left corner of the same cell
-- have to invert to that cell, or the two mappings disagree about where a row starts.
assertCell({ x = frame.x + (47 - 0.5) * cellWidth,
  y = module.inputBorderY(frame, rows, 12) - rowHeight / 2 }, 12, 47,
  "the centre of a cell did not invert to the cell it is the centre of")

assert(module.gridCell(frame, rows, columns, { x = frame.x - 1, y = frame.y }) == nil,
  "a point left of the grid produced a column")
assert(module.gridCell(frame, rows, columns,
  { x = frame.x + frame.w + 1, y = frame.y }) == nil,
  "a point right of the grid produced a column")
assert(module.gridCell(frame, rows, columns, { x = frame.x, y = frame.y - rowHeight }) == nil,
  "a point above the grid produced a row")
assert(module.gridCell(frame, rows, columns,
  { x = frame.x, y = frame.y + frame.h + rowHeight }) == nil,
  "a point below the grid produced a row")
assert(module.gridCell(nil, rows, columns, cellTopLeft(1, 1)) == nil
    and module.gridCell(frame, rows, 0, cellTopLeft(1, 1)) == nil
    and module.gridCell(frame, 0, columns, cellTopLeft(1, 1)) == nil
    and module.gridCell(frame, rows, columns, nil) == nil
    and module.gridCell(frame, rows, columns, { x = 1 }) == nil,
  "a cell was read out of a frame or a point that cannot describe one")
end

-- The tab-group walk behind an observation is 3-9ms, and the pass used to pay it twice:
-- once for the target check, once inside the scrape. Scoped: this chunk sits at the same
-- 200-local ceiling the module does.
do
integration = integrationContext(nil, { windowFrame = terminalFrame })
assert(module.handleEvent(aPress(false)), "the threaded Cmd+A was not consumed")
integration.resolve("claude")
local observedBefore = integration.observations()
integration.runDeferred()
assert(integration.observations() - observedBefore == 1,
  "the Cmd+A pass observed the front tab more than once")
assert(integration.scrapeContext() and integration.scrapeContext().windowID == 7,
  "the scrape did not receive the observation the target check had already made")
integration.deliverScrape(screenDraft, "ax")
assert(integration.observations() - observedBefore == 1,
  "the delivered screen observed the front tab again")
assert(#integration.mouseEvents() == 3, "the threaded Cmd+A did not drag")

-- Asked before the scrape now, so a pass whose tab is already gone never reads a screen
-- nobody will use — and it still has to release the in-flight guard behind it.
integration = integrationContext(nil, { windowFrame = terminalFrame })
assert(module.handleEvent(aPress(false)), "the retargeted Cmd+A was not consumed")
integration.resolve("claude")
integration.changeTarget()
integration.runDeferred()
assert(#integration.actions == 0, "Cmd+A scraped a screen whose target was already gone")
assert(#integration.mouseEvents() == 0, "Cmd+A dragged in a tab that was not its target")
selectAll(integration, screenDraft)
assert(#integration.mouseEvents() == 3, "the bailed pass left the select-all guard armed")
end

-- The AppleScript backend holds the runloop for 21-80ms after that single check, wide enough
-- for the user to switch tabs; the drag it feeds posts real mouse events, so that backend
-- asks again once the screen is in hand. Scoped: this chunk sits at the same 200-local
-- ceiling the module does.
do
module.latencyReset()
integration = integrationContext(nil, { windowFrame = terminalFrame })
assert(module.handleEvent(aPress(false)), "the slow-scraped Cmd+A was not consumed")
integration.resolve("claude")
-- The tab goes between the pre-scrape check and the screen coming back.
integration.changeTargetAfterNextObservation()
integration.runDeferred()
integration.deliverScrape(screenDraft, "as")
assert(#integration.mouseEvents() == 0,
  "Cmd+A dragged in the tab that replaced its target during the AppleScript scrape")
assert(module.selectAllRow() == nil,
  "the abandoned pass was timed as a completed select-all action")
selectAll(integration, screenDraft)
assert(#integration.mouseEvents() == 3, "the abandoned pass left the select-all guard armed")

-- The AX read closes that window in a fraction of a millisecond, so there the pre-scrape
-- check is the whole check: a second 3-9ms observation per pass is what the fast path is for.
integration = integrationContext(nil, { windowFrame = terminalFrame })
assert(module.handleEvent(aPress(false)), "the AX-scraped Cmd+A was not consumed")
integration.resolve("claude")
local observedBefore = integration.observations()
integration.runDeferred()
integration.changeTarget()
integration.deliverScrape(screenDraft, "ax")
assert(integration.observations() - observedBefore == 1,
  "the AX-scraped pass observed the front tab again after its screen arrived")
assert(#integration.mouseEvents() == 3, "the AX-scraped pass did not drag")
module.latencyReset()
end

-- Every resolved chord and gesture invalidates the tty context, and the scrape calibration
-- used to go with it: cut and the word gestures then re-calibrated on every press and never
-- reached the AX path at all. The fingerprint and the TTL already cover the tab it describes.
do
integration = integrationContext()
local box = { windowID = 7, tab = "tab-a", tabIndex = 1, x = 0, y = 0, w = 1200, h = 800 }
local screen = "one row\n"
local calibrated = module.axTextCalibrate(screen, box, function()
  return { "text-area" }, screen
end)
assert(calibrated and calibrated.capable, "the fixture calibration was not AX-capable")
assert(module.handleEvent(cPress(false)), "the chord before the calibration check was eaten")
assert(module.axTextFresh(box) == calibrated,
  "a resolved chord dropped the scrape calibration of the tab it was measured for")
integration.resolve("claude")
module.stop()
assert(module.axTextFresh(box) == nil, "the stopped module kept its scrape calibration")
end

-- What the AX path is for is a number the user feels, and the input-latency ring cannot
-- see any of it: the scrape and the drag run in a deferred tick of their own.
do
module.latencyReset()
assert(module.selectAllRow() == nil, "a reset ledger reported rows")
assert(module.selectAllReport():match("none recorded"), "an empty ledger did not say so")

integration = integrationContext(nil, { windowFrame = terminalFrame })
assert(module.handleEvent(aPress(false)), "the timed Cmd+A was not consumed")
integration.resolve("claude")
integration.runDeferred()
integration.advance(0.01)
integration.deliverScrape(screenDraft, "ax")
local row = module.selectAllRow()
assert(row and row.count == 1 and row.ax == 1 and row.as == 0,
  "the AX-served Cmd+A was not counted against its backend")
assert(row.scrape.p50 == 10 and row.total.p50 == 10 and row.geometry.p50 == 0
    and row.drag.p50 == 0,
  "the Cmd+A stages were not measured")
selectAll(integration, screenDraft)
row = module.selectAllRow()
assert(row.count == 2 and row.ax == 1 and row.as == 1,
  "a scrape that fell back to AppleScript was counted as an AX read")

-- A pass that never dragged has no drag to time, and counting it would report a whole
-- action nobody performed.
integration = integrationContext(nil, { windowFrame = terminalFrame })
selectAll(integration, screenEmptyInput)
assert(module.selectAllRow().count == 2, "Cmd+A over an empty input recorded an action")

module.latencyReset()
assert(module.selectAllRow() == nil, "the reset left the selectAll ledger populated")
module.selectAllRecord(1000000, 2000000, 3000000, 6000000, "ax")
local rendered = module.latencyReport()
assert(rendered:match("selectAll actions: n=1, backend ax 1 / as 0"),
  "the report lost the selectAll counts")
assert(rendered:match("total p50 6%.00 max 6%.00") and rendered:match("scrape p50 1%.00")
    and rendered:match("frame p50 2%.00") and rendered:match("drag p50 3%.00")
    and rendered:match("ring 64"),
  "the report lost a selectAll stage or its ring size")

module.latencyReset()
for index = 1, 70 do
  module.selectAllRecord(index * 1000000, 0, 0, index * 1000000,
    index % 2 == 0 and "ax" or "as")
end
local wrapped = module.selectAllRow()
assert(wrapped.count == 64 and wrapped.total.max == 70 and wrapped.total.p50 == 38
    and wrapped.ax == 32,
  "the selectAll ring kept the wrong window of actions")
module.latencyReset()
end

integration = integrationContext()
module.handleEvent(zPress(false))
integration.resolve("not-claude")
assert(#integration.actions == 1 and integration.actions[1] == "replay",
  "non-Claude Cmd+Z was not replayed")

integration = integrationContext()
module.handleEvent(zPress(false))
integration.changeTarget()
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "policy-drop",
  "target-mismatched Cmd+Z was not policy-dropped")

integration = integrationContext()
module.handleEvent(zPress(false))
assert(module.handleEvent(zPress(true)), "pending Cmd+Z autorepeat was not consumed")
assert(module.status().pendingCount == 1, "pending Cmd+Z autorepeat created another action")
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "undo",
  "pending Cmd+Z autorepeat emitted more than one undo")

integration = integrationContext()
module.handleEvent(cPress(false))
assert(module.handleEvent(cPress(true)), "pending autorepeat was not consumed")
assert(module.status().pendingCount == 1, "pending autorepeat created another action")
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "copy",
  "pending autorepeat emitted more than one action")
assert(not module.handleEvent(keyEvent(7, { "ctrl" }, false, "real-ctrl-x")),
  "real keypress after synthesis was swallowed")

integration = integrationContext({ "public.png" })
module.handleEvent(cPress(false))
module.handleEvent(vPress(false))
module.stop()
assert(#integration.actions == 2 and integration.actions[1] == "replay"
    and integration.actions[2] == "policy-drop",
  "stop did not apply replay/drop policy to pending actions")
integration.resolve("claude")
assert(#integration.actions == 2, "post-stop verdict duplicated an action")

integration = integrationContext({ "public.png" })
module.handleEvent(cPress(false))
integration.resolve("claude")
module.handleEvent(vPress(false))
assert(module.handleEvent(cPress(true)) and module.handleEvent(cPress(true)),
  "Cmd+C autorepeat leaked while Cmd+V was pending")
integration.resolve("claude")
assert(module.handleEvent(cPress(true)),
  "Cmd+C autorepeat decision was lost after Cmd+V resolved")
assert(#integration.actions == 2 and integration.actions[1] == "copy"
    and integration.actions[2] == "image-paste",
  "cross-key Cmd+C autorepeat emitted an action")

integration = integrationContext({ "public.png" })
module.handleEvent(vPress(false))
integration.resolve("claude")
module.handleEvent(cPress(false))
assert(module.handleEvent(vPress(true)) and module.handleEvent(vPress(true)),
  "Cmd+V autorepeat leaked while Cmd+C was pending")
integration.resolve("claude")
assert(module.handleEvent(vPress(true)),
  "Cmd+V autorepeat decision was lost after Cmd+C resolved")
assert(#integration.actions == 2 and integration.actions[1] == "image-paste"
    and integration.actions[2] == "copy",
  "cross-key Cmd+V autorepeat emitted an action")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/pic.png" })
assert(module.handleEvent(vPress(false)), "cold file-url Cmd+V was not consumed")
assert(#integration.actions == 0, "file-url conversion ran inside the tap callback")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == 2 and integration.actions[1] == "write-image"
    and integration.actions[2] == "image-paste",
  "file-url convert did not write image pixels then paste")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/photo.JPG" })
assert(module.handleEvent(vPress(false)), "uppercase-extension file-url Cmd+V was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[1] == "write-image",
  "uppercase image extension was not treated as an image")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/pic.png", loadFails = true })
assert(module.handleEvent(vPress(false)), "load-failure file-url Cmd+V was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == 1 and integration.actions[1] == "replay",
  "image load failure did not replay the original event")
assert(integration.alerts() == 1, "unreadable image (TCC) did not raise an alert")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/doc.pdf" })
assert(not module.handleEvent(vPress(false)), "non-image file-url Cmd+V was not passed through")
assert(#integration.actions == 0, "non-image file-url produced an action")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/gone.png", fileExists = false })
assert(not module.handleEvent(vPress(false)), "missing-file file-url Cmd+V was not passed through")
assert(#integration.actions == 0, "missing file-url produced an action")

integration = integrationContext({ "public.utf8-plain-text" })
assert(not module.handleEvent(vPress(false)), "text Cmd+V entered the intercept path")
assert(#integration.actions == 0, "text Cmd+V produced an action")

local textTypes = { "public.utf8-plain-text" }

local function pressPaste(context)
  assert(module.handleEvent(vPress(false)),
    "text Cmd+V over a selection was not consumed")
  context.resolve("claude")
  context.runDeferred()
end

local function dragThenPaste(context, dragY)
  simulateDrag(dragY)
  pressPaste(context)
end

integration = integrationContext(textTypes)
dragThenPaste(integration)
assert(#integration.actions == 1 and integration.actions[1] == "scrape",
  "text Cmd+V over a selection did not snapshot the input box first")
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "cut",
  "text Cmd+V over a selection did not delete it before pasting")
assert(integration.lastDelay() == 0.15, "paste-replace re-scrape delay changed")
integration.timeout()
assert(#integration.actions == 3 and integration.actions[3] == "scrape",
  "paste-replace did not re-scrape after the delay")
integration.deliverScrape(screenShorter)
assert(#integration.actions == 4 and integration.actions[4] == "replay",
  "paste-replace did not replay the paste once the deletion was confirmed")
assert(integration.wrote() == nil, "paste-replace put the deleted text on the pasteboard")
assert(integration.alerts() == 0, "paste-replace raised an alert")
pressCut(integration)
assert(#integration.actions == 4, "paste-replace left the selection armed for Cmd+X")

integration = integrationContext(textTypes)
simulateClick()
assert(not module.handleEvent(vPress(false)),
  "text Cmd+V without a selection entered the intercept path")
assert(#integration.actions == 0, "text Cmd+V without a selection produced an action")

integration = integrationContext(textTypes)
dragThenPaste(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenOneChar)
-- Selecting one character and replacing it is ordinary, so the cut path's undo
-- guard has no place here: the diff is trusted and only the paste goes out.
assert(#integration.actions == 4 and integration.actions[4] == "replay",
  "a 1-char selection was not replaced by the paste alone")
assert(integration.wrote() == nil, "a 1-char paste-replace reached the pasteboard")
assert(integration.alerts() == 0, "a 1-char paste-replace raised an alert")

integration = integrationContext(textTypes, { windowFrame = terminalFrame })
dragThenPaste(integration, 100)
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "replay",
  "a transcript selection was deleted instead of just pasted")
assert(integration.timeouts() == 0, "a transcript paste scheduled the re-scrape")
pressCut(integration)
assert(#integration.actions == 2, "a transcript paste left the selection state set")

-- Unlike a cut, a paste that skips the DEL still gives the user what they pressed,
-- so these two screens stay silent where the cut path alerts.
integration = integrationContext(textTypes)
dragThenPaste(integration)
integration.deliverScrape("a screen with no input box")
assert(#integration.actions == 2 and integration.actions[2] == "replay",
  "an unparseable before-screen deleted the draft or swallowed the paste")
assert(integration.alerts() == 0, "an unparseable before-screen alerted on the paste path")

integration = integrationContext(textTypes)
dragThenPaste(integration)
integration.deliverScrape(nil)
assert(#integration.actions == 2 and integration.actions[2] == "replay",
  "an unreadable before-screen did not fall back to a plain paste")
assert(integration.alerts() == 0, "an unreadable before-screen alerted on the paste path")

integration = integrationContext(textTypes)
dragThenPaste(integration)
integration.changeTarget()
integration.deliverScrape(screenDraft)
assert(#integration.actions == 1,
  "text Cmd+V deleted or pasted into a context that moved while scraping")

integration = integrationContext(textTypes)
dragThenPaste(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.changeTarget()
integration.deliverScrape(screenShorter)
assert(#integration.actions == 3, "a paste landed in a tab that moved after the deletion")
assert(integration.alerts() == 0, "a dropped paste raised an alert")

-- The DEL is already out, so a box that never repaints must not cost the paste too.
integration = integrationContext(textTypes)
dragThenPaste(integration)
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenDraft)
assert(integration.timeouts() == 2, "an unrepainted box was not retried on the paste path")
integration.timeout()
integration.deliverScrape(screenDraft)
assert(integration.timeouts() == 2, "an unrepainted box kept rescraping past one retry")
assert(integration.actions[#integration.actions] == "replay",
  "an unrepainted box swallowed the paste")

-- A second Cmd+V mid-flight queues behind the first instead of opening its own
-- DEL window; both pastes still land, in the order they were pressed.
integration = integrationContext(textTypes)
dragThenPaste(integration)
integration.deliverScrape(screenDraft)
simulateDrag()
assert(module.handleEvent(vPress(false)), "a Cmd+V mid-flight was not queued")
assert(#integration.actions == 2, "a Cmd+V mid-flight started a second replace")
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "v,v", "the in-flight replace did not finish in order")

integration = integrationContext(textTypes)
dragThenCut(integration)
integration.deliverScrape(screenDraft)
simulateDrag()
assert(module.handleEvent(vPress(false)), "a Cmd+V mid-cut was not consumed")
assert(#integration.actions == 2, "a Cmd+V mid-cut started a replace")
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(integration.wrote() == "brave ", "the queued paste poisoned the cut's diff")
assert(integration.replayed() == "v", "the queued paste was not replayed after the cut")

-- Cmd+X mid-replace closes the flow, but a replay of our own chord is invisible to
-- the tap: it goes back through the decide path and still runs a real cut.
integration = integrationContext(textTypes)
dragThenPaste(integration)
integration.deliverScrape(screenDraft)
simulateDrag()
assert(module.handleEvent(xPress(false)), "Cmd+X mid-replace was not consumed")
assert(integration.replayed() == "v", "Cmd+X was replayed as a literal chord")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[#integration.actions] == "scrape",
  "Cmd+X mid-replace lost its cut")

integration = integrationContext(textTypes)
dragThenPaste(integration)
integration.deliverScrape(screenDraft)
stranded = integration
integration = integrationContext()
assert(stranded.cutTimerStopped(),
  "setTestHooks left the previous paste-replace re-scrape timer armed")

integration = integrationContext(textTypes, { scrapeThrows = true })
dragThenPaste(integration)
dragThenPaste(integration)
assert(integration.replayed() == "v,v",
  "a failed replace stranded the flow or swallowed the paste")

integration = integrationContext({ "public.png" })
simulateDrag()
assert(module.handleEvent(vPress(false)), "image Cmd+V over a selection was not consumed")
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "image-paste",
  "an armed selection changed the image paste path")
pressCut(integration)
assert(#integration.actions == 1, "image paste left the selection armed for Cmd+X")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/pic.png" })
simulateDrag()
assert(module.handleEvent(vPress(false)), "file-url Cmd+V over a selection was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == 2 and integration.actions[1] == "write-image"
    and integration.actions[2] == "image-paste",
  "an armed selection changed the convert paste path")

local function charPress(character, keyCode, repeatDown)
  return keyEvent(keyCode or 4, {}, repeatDown, character, character)
end
local function returnPress() return keyEvent(36, {}, false, "return", "\r") end
-- The keypad's own Enter submits the draft exactly as 36 does, and it is a keyCode of
-- its own: a rule written for Return alone lets it through untouched.
local function keypadReturnPress() return keyEvent(76, {}, false, "keypad-return", "\r") end
local function backspacePress() return keyEvent(51, {}, false, "backspace", "\127") end
local function escapePress() return keyEvent(53, {}, false, "escape", "\27") end
local function tabPress() return keyEvent(48, {}, false, "tab", "\t") end
local function arrowPress() return keyEvent(124, {}, false, "right", "\u{F703}") end
local function shiftArrowPress()
  return keyEvent(124, { "shift" }, false, "shift-right", "\u{F703}")
end
local function functionKeyPress() return keyEvent(122, {}, false, "f1", "\u{F704}") end
local function cmdShiftPress() return keyEvent(0, { "cmd", "shift" }, false, "cmd-shift-a", "a") end

local function dragThenType(context, character, keyCode)
  simulateDrag()
  assert(module.handleEvent(charPress(character, keyCode)),
    "a character typed over a selection was not consumed")
  context.resolve("claude")
  context.runDeferred()
end

integration = integrationContext(textTypes)
dragThenCut(integration)
integration.deliverScrape(screenDraft)
assert(module.handleEvent(charPress("h")), "a character mid-cut was not consumed")
assert(integration.replayed() == "", "a character reached the terminal during the cut")
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(integration.wrote() == "brave ", "a queued character polluted the cut's diff")
assert(integration.replayed() == "h", "a queued character was not replayed after the cut")

integration = integrationContext(textTypes)
dragThenCut(integration)
integration.deliverScrape(screenDraft)
assert(module.handleEvent(charPress("q", 12)), "a character mid-cut was not queued")
assert(module.handleEvent(charPress("q", 12, true)), "an autorepeat mid-cut was not consumed")
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "q", "an autorepeat mid-cut joined the replay queue")
assert(not module.handleEvent(charPress("q", 12, true)),
  "autorepeat stayed consumed after the cut replayed its held key")

integration = integrationContext(textTypes)
dragThenCut(integration)
integration.deliverScrape(screenDraft)
for _ = 1, 32 do
  assert(module.handleEvent(charPress("q", 12)), "a key within the cut queue cap was not consumed")
end
assert(not module.handleEvent(charPress("q", 12)), "a key beyond the cut queue cap was consumed")
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(select(2, integration.replayed():gsub("q", "")) == 32,
  "the cut queue did not replay exactly its 32 capped keys")

-- The live repro: Backspace already deleted the selection natively, so the flag it
-- left behind must not send a DEL through an unselected draft.
integration = integrationContext(textTypes)
simulateDrag()
assert(not module.handleEvent(backspacePress()), "a pass-through Backspace was consumed")
assert(not module.handleEvent(vPress(false)),
  "Cmd+V replaced over a selection a keystroke had already deleted")
assert(#integration.actions == 0, "the stale-selection Cmd+V produced an action")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
assert(#integration.actions == 1 and integration.actions[1] == "scrape",
  "typing over a selection did not snapshot the input box first")
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "cut",
  "typing over a selection did not delete it first")
assert(integration.lastDelay() == 0.15, "the typed re-scrape delay changed")
integration.timeout()
integration.deliverScrape(screenShorter)
assert(#integration.actions == 4 and integration.actions[4] == "replay",
  "typing over a selection did not replay the character")
assert(integration.replayed() == "h", "the replayed keystroke was not the typed character")
assert(integration.wrote() == nil, "typing over a selection touched the pasteboard")
assert(integration.alerts() == 0, "typing over a selection raised an alert")
pressCut(integration)
assert(#integration.actions == 4, "a typed replace left the selection armed for Cmd+X")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
assert(module.handleEvent(backspacePress()), "Backspace did not finish the replace")
assert(integration.replayed() == "h,backspace", "Backspace was not the replace trigger")
assert(not module.handleEvent(keyEvent(51, {}, true, "backspace", "\127")),
  "held Backspace autorepeat stayed consumed after finishing the replace")

-- Layout-independent: the character comes from the event, never from a keycode table.
for _, character in ipairs({ "и", "7", " ", ",", "Ж" }) do
  integration = integrationContext(textTypes)
  dragThenType(integration, character)
  integration.deliverScrape(screenDraft)
  integration.timeout()
  integration.deliverScrape(screenShorter)
  assert(integration.replayed() == character,
    "a printable character was not replaced over the selection")
end

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenOneChar)
assert(#integration.actions == 4 and integration.actions[4] == "replay",
  "a 1-char selection was not replaced by the typed character alone")
assert(integration.replayed() == "h", "a 1-char selection lost the typed character")
assert(integration.wrote() == nil, "a 1-char typed replace reached the pasteboard")

integration = integrationContext(textTypes, { windowFrame = terminalFrame })
simulateDrag(100)
assert(module.handleEvent(charPress("h")), "a character over a transcript drag was not consumed")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenDraft)
assert(#integration.actions == 2 and integration.actions[2] == "replay",
  "a transcript selection was deleted instead of typed over")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape("a screen with no input box")
assert(#integration.actions == 2 and integration.actions[2] == "replay",
  "an unparseable before-screen deleted the draft or swallowed the character")
assert(integration.alerts() == 0, "an unparseable before-screen alerted on the typed path")

-- Everything that does not insert text passes straight through, and each of them
-- invalidates the TUI selection, so none may leave the flag armed behind it.
for _, press in ipairs({
  returnPress, backspacePress, escapePress, tabPress, arrowPress,
  functionKeyPress, cmdShiftPress,
}) do
  integration = integrationContext(textTypes)
  simulateDrag()
  assert(not module.handleEvent(press()), "a key that inserts no text was consumed")
  assert(#integration.actions == 0, "a key that inserts no text produced an action")
  pressCut(integration)
  assert(#integration.actions == 0, "a key that inserts no text left the selection armed")
end

-- Shift+Left/Right is the exception: the TUI extends the selection it already paints, so
-- the key passes natively and the flag has to survive it or the next Cmd+X takes the
-- bare-DEL path over a live selection.
integration = integrationContext(textTypes)
simulateDrag()
assert(not module.handleEvent(shiftArrowPress()),
  "Shift+arrow over a live selection was consumed")
assert(#integration.actions == 0, "Shift+arrow over a live selection produced an action")
pressCut(integration)
assert(#integration.actions > 0, "Shift+arrow disarmed the selection it was extending")

integration = integrationContext(textTypes, { verdict = "not-claude" })
simulateDrag()
assert(not module.handleEvent(shiftArrowPress()), "Shift+arrow at a plain shell was consumed")
pressCut(integration)
assert(#integration.actions == 0, "Shift+arrow at a plain shell left the selection armed")

integration = integrationContext(textTypes)
simulateDrag()
assert(not module.handleEvent(charPress("h", 4, true)), "an autorepeated character was consumed")
assert(#integration.actions == 0, "an autorepeated character started a replace")

integration = integrationContext(textTypes)
simulateClick()
assert(not module.handleEvent(charPress("h")),
  "a character typed without a selection entered the replace path")
assert(#integration.actions == 0, "a character typed without a selection produced an action")

integration = integrationContext(textTypes, { verdict = "not-claude" })
simulateDrag()
assert(not module.handleEvent(charPress("h")),
  "a character typed at a plain shell was consumed")

-- A fast typist's later keys would otherwise land ahead of the key still being held.
integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
assert(module.handleEvent(charPress("i", 34)), "a character typed mid-replace was not queued")
assert(module.handleEvent(charPress("!", 18)), "a second character typed mid-replace was not queued")
assert(#integration.actions == 2, "a queued character started a replace of its own")
integration.timeout()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "h,i,!",
  "the queued characters did not follow the held key in the order they were typed")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
assert(module.handleEvent(vPress(false)), "a text Cmd+V typed mid-replace was not queued")
integration.timeout()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "h,v", "the queued paste did not follow the held character")

-- Return submits the draft, so letting it through natively would land it ahead of
-- the keys still being held: it is consumed and replayed as the sequence's last event.
integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
module.handleEvent(charPress("i", 34))
assert(module.handleEvent(returnPress()), "Return mid-replace was not consumed")
assert(integration.replayed() == "h,i,return",
  "Return did not arrive after the keys the flow was holding")
local releasedActions = #integration.actions
integration.timeout()
assert(#integration.actions == releasedActions and integration.replayed() == "h,i,return",
  "the released flow kept running and replayed its keys twice")

for _, press in ipairs({ escapePress, arrowPress, cmdShiftPress }) do
  integration = integrationContext(textTypes)
  dragThenType(integration, "h")
  integration.deliverScrape(screenDraft)
  assert(module.handleEvent(press()), "a non-queueable key mid-replace was not consumed")
  assert(integration.replayed() == "h," .. press().label,
    "a non-queueable key did not arrive after the held key")
end

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
for _ = 1, 32 do
  assert(module.handleEvent(charPress("q", 12)), "a character within the queue cap was not queued")
end
assert(module.handleEvent(charPress("q", 12)), "the character that overran the cap was dropped")
assert(select(2, integration.replayed():gsub(",", "")) == 33,
  "the capped queue did not release the held key, all 32 queued ones and the overflow")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
module.handleEvent(charPress("i", 34))
module.stop()
assert(integration.replayed() == "h,i", "stop swallowed the keys the replace flow was holding")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
module.handleEvent(charPress("i", 34))
integration.timeout()
integration.changeTarget()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "", "a moved tab still received the held keystrokes")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
assert(module.handleEvent(xPress(false)), "Cmd+X mid-replace was not consumed")
assert(integration.replayed() == "h",
  "the key the flow was holding did not go out before the trigger was decided")
local flushedActions = #integration.actions
integration.resolve("claude")
assert(#integration.actions == flushedActions,
  "Cmd+X cut a selection the replace had already deleted")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/pic.png" })
module.handleEvent(vPress(false))
integration.changeTarget()
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "policy-drop",
  "target-mismatched file-url Cmd+V was not policy-dropped")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/pic.png" })
module.handleEvent(vPress(false))
module.stop()
assert(#integration.actions == 1 and integration.actions[1] == "policy-drop",
  "stop did not policy-drop a pending file-url Cmd+V")

-- App switch AFTER the convert is scheduled but before the deferred tick runs.
integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/pic.png" })
module.handleEvent(vPress(false))
integration.resolve("claude")
integration.changeTarget()
integration.runDeferred()
assert(#integration.actions == 1 and integration.actions[1] == "policy-drop",
  "convert into a switched context was not policy-dropped")
assert(integration.alerts() == 0, "silent context drop raised an alert")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/pic.png" })
module.handleEvent(vPress(false))
integration.resolve("claude")
integration.bumpClipboard()
integration.runDeferred()
assert(#integration.actions == 1 and integration.actions[1] == "policy-drop",
  "convert with a changed pasteboard was not policy-dropped")
assert(integration.alerts() == 0, "silent pasteboard drop raised an alert")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/pic.png" })
module.handleEvent(vPress(false))
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == 2 and integration.actions[1] == "write-image"
    and integration.actions[2] == "image-paste",
  "unchanged context did not convert after the deferred re-check")

integration = integrationContext({ "public.file-url" }, { url = "file:///tmp/pic.png", loadFails = true })
module.handleEvent(vPress(false)); integration.resolve("claude"); integration.runDeferred()
assert(integration.alerts() == 1, "first TCC failure did not alert")
module.handleEvent(vPress(false)); integration.resolve("claude"); integration.runDeferred()
assert(integration.alerts() == 1, "repeat TCC failure alert was not throttled")
integration.advance(11)
module.handleEvent(vPress(false)); integration.resolve("claude"); integration.runDeferred()
assert(integration.alerts() == 2, "TCC alert did not re-fire after the throttle window")

-- foregroundVerdict wires observeFrontmost + the live cache into cachedVerdict.
-- With no resolved cache, and for any non-Terminal frontmost, it must report
-- "uncertain" so SendActions falls back to a plain Cmd+C.
module.setTestHooks({
  now = function() return 100 end,
  observe = function()
    return { bundleID = "com.apple.Terminal", windowID = 7, tabIndex = 1, tabElement = "tab-a" }
  end,
})
assert(module.foregroundVerdict() == "uncertain",
  "foreground verdict with no resolved cache was not uncertain")
module.setTestHooks({
  now = function() return 100 end,
  observe = function() return { bundleID = "com.apple.Safari" } end,
})
assert(module.foregroundVerdict() == "uncertain",
  "foreground verdict for a non-Terminal app was not uncertain")

assert(module.containsTextType({ "public.utf8-plain-text" }), "utf8 text type was not detected")
assert(module.containsTextType({ "public.file-url", "public.utf8-plain-text" }),
  "a text type was missed alongside a file url")
assert(module.containsTextType({ "NSStringPboardType" }), "the legacy string type was not detected")
assert(not module.containsTextType({ "public.png" }), "an image type was read as text")
assert(not module.containsTextType({}), "an empty pasteboard was read as text")
assert(not module.containsTextType(nil), "missing types were read as text")

-- One resolve can turn several consumed keys into replaces; all but the first find
-- the flow already running and have to join its queue rather than vanish.
integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(charPress("h")), "the first pending character was not consumed")
assert(module.handleEvent(charPress("i", 34)), "the second pending character was not consumed")
assert(module.status().pendingCount == 2, "the second pending character was folded away")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "h,i",
  "a character resolved into an already running replace was swallowed")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
integration.switchApp("com.apple.Safari")
assert(not module.handleEvent(charPress("i", 34)),
  "a key typed after the context moved was consumed by the dead flow")
assert(integration.replayed() == "", "the held key was posted into another app")

-- Abandoning before the DEL is the one exit that still holds an armed selection.
integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(vPress(false)), "text Cmd+V over a selection was not consumed")
integration.resolve("claude")
integration.runDeferred()
integration.changeTarget()
integration.deliverScrape(screenDraft)
assert(#integration.actions == 1, "a paste-replace deleted in a tab that had moved")
integration.switchApp(nil)
assert(not module.handleEvent(vPress(false)),
  "an abandoned before-scrape left the selection armed")
assert(#integration.actions == 1, "the stale selection of an abandoned flow was replaced over")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
integration.timeout()
integration.switchApp("com.apple.Safari")
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "", "the flow replayed into another app after the switch")
local abandonedActions = #integration.actions
integration.switchApp(nil)
assert(not module.handleEvent(vPress(false)),
  "an abandoned flow left the selection armed")
assert(#integration.actions == abandonedActions,
  "an abandoned flow replaced over its stale selection")
assert(not module.handleEvent(charPress("h", 4, true)),
  "autorepeat stayed consumed after the flow holding the key was abandoned")

-- The scrape blows up before any target check runs, so the only thing standing
-- between the held key and the app that is now in front is the replay's own check.
integration = integrationContext(textTypes, { scrapeThrows = true })
simulateDrag()
assert(module.handleEvent(vPress(false)), "text Cmd+V over a selection was not consumed")
integration.resolve("claude")
integration.switchApp("com.apple.Safari")
integration.runDeferred()
assert(integration.replayed() == "", "a stranded flow posted the paste into another app")

-- The consumed first press caches a consume decision for its keycode; left set, it
-- swallows every autorepeat of a key the user is still holding.
integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenShorter)
assert(not module.handleEvent(charPress("h", 4, true)),
  "autorepeat stayed consumed after the replace finished")

integration = integrationContext(textTypes)
dragThenType(integration, "h")
integration.deliverScrape(screenDraft)
for _ = 1, 5 do
  assert(module.handleEvent(charPress("h", 4, true)),
    "an autorepeat mid-replace was not consumed")
end
integration.timeout()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "h", "autorepeats mid-replace joined the queue")

integration = integrationContext(textTypes)
simulateDrag()
assert(not module.handleEvent(keyEvent(14, { "alt" }, false, "alt-e", "e", "")),
  "an Option dead-key press armed a replace")
assert(#integration.actions == 0, "an Option dead-key press produced an action")
pressCut(integration)
assert(#integration.actions == 0, "an Option dead-key press left the selection armed")

-- Option types { } @ \ on German and Nordic layouts, where nothing else does.
integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(keyEvent(28, { "alt" }, false, "alt-8", "8", "{")),
  "an Option-printable character did not replace the selection")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[1] == "scrape",
  "an Option-printable character produced no replace")

-- Fn+letter drives system features and inserts nothing, so a DEL would delete the
-- selection with nothing to put back.
integration = integrationContext(textTypes)
simulateDrag()
assert(not module.handleEvent(keyEvent(4, { "fn" }, false, "fn-h", "h")),
  "an Fn-modified press armed a replace")
assert(#integration.actions == 0, "an Fn-modified press produced an action")

for _, types in ipairs({ {}, { "com.acme.private" }, { "public.file-url" } }) do
  integration = integrationContext(types)
  simulateDrag()
  assert(not module.handleEvent(vPress(false)),
    "Cmd+V over a pasteboard with no text entered the replace path")
  assert(#integration.actions == 0, "a pasteboard with no text produced an action")
end

-- A paste the cut's DEL window rejected has to wait it out: posted mid-cut it would
-- sit between the two scrapes cutDiff measures the deletion against.
integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(xPress(false)), "Cmd+X was not consumed")
assert(module.handleEvent(vPress(false)), "Cmd+V behind Cmd+X was not consumed")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenDraft)
assert(integration.replayed() == "", "the paste was posted into the cut's DEL window")
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(integration.wrote() == "brave ", "the held paste poisoned the cut's diff")
assert(integration.replayed() == "v", "the held paste was never posted after the cut")

-- Return in the pending window submits the draft the held character was typed into,
-- so it waits behind it instead of passing through.
integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(charPress("h")), "the pending character was not consumed")
assert(module.handleEvent(returnPress()), "Return was not held behind the pending replace")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "h,return",
  "Return overtook the character the pending replace was holding")

integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(charPress("h")), "the pending character was not consumed")
assert(module.handleEvent(returnPress()), "Return was not held behind the pending replace")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenDraft)
integration.timeout()
integration.changeTarget()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "", "a deferred Return replay leaked into the new tab")
assert(integration.actions[#integration.actions] == "policy-drop",
  "a deferred Return replay was not dropped after the tab changed")

integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(xPress(false)), "Cmd+X was not consumed")
assert(module.handleEvent(charPress("h")), "the pending character was not consumed")
assert(module.handleEvent(returnPress()), "Return was not held behind the pending character")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenDraft)
assert(integration.replayed() == "", "pending actions reached the terminal during the cut")
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(integration.wrote() == "brave ", "pending dispatch polluted the active cut")
assert(integration.replayed() == "h,return",
  "pending actions resumed after the cut in the wrong order")

integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(xPress(false)), "Cmd+X was not consumed")
integration.changeTarget()
assert(module.handleEvent(charPress("h")), "the mismatched replace was not consumed")
integration.switchApp(nil)
assert(module.handleEvent(keyEvent(36, {}, false, "a", "\r")),
  "the replay was not held behind the pending replace")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenDraft)
assert(module.handleEvent(charPress("j", 38)), "the live key was not queued mid-cut")
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "a,j",
  "a live mid-cut key overtook the older pending replay")

integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(charPress("h")), "the pending replace was not consumed")
assert(module.handleEvent(keyEvent(36, {}, false, "a", "\r")),
  "the replay was not held behind the pending replace")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(screenDraft)
assert(module.handleEvent(charPress("b", 11)), "the live key was not queued mid-replace")
assert(module.handleEvent(returnPress()), "Return did not finish the replace")
assert(integration.replayed() == "h,a,b,return",
  "a live mid-replace key overtook the older pending replay")

integration = integrationContext(textTypes)
simulateDrag()
module.handleEvent(charPress("h"))
integration.resolve("not-claude")
assert(integration.replayed() == "h", "a non-Claude character was not replayed")
pressCut(integration)
assert(#integration.actions == 1, "a replace that resolved away left the selection armed")

-- Claude renders the Option+Shift+arrow escape sequence as a bare Esc, so the
-- chord never reaches it: Left and Right run the word gesture, Up and Down are
-- swallowed bare, and everything passes anywhere else.
local function optionShiftPress(keyCode, repeatDown)
  local labels = { [123] = "alt-shift-left", [124] = "alt-shift-right",
    [125] = "alt-shift-down", [126] = "alt-shift-up" }
  return keyEvent(keyCode, { "alt", "shift" }, repeatDown, labels[keyCode])
end

local sentinel = "\226\141\188"
assert(module.planBytes(module.sentinelPlan()) == sentinel,
  "the cursor sentinel character changed")
assert(cellLen(sentinel) == 1 and #sentinel > 1,
  "the cursor sentinel is not a single non-ASCII cell")
local sentinelCharacters = module.planCharacters(module.sentinelPlan())
assert(#sentinelCharacters == 1 and sentinelCharacters[1] == sentinel,
  "the sentinel would be typed as three separate byte keystrokes")
assert(#module.planCharacters(module.copyChordPlan()) == 2,
  "a two-byte control plan was not split into its two keystrokes")

-- Captured from a live claude TUI at 120 columns: the draft opens on the row below
-- the top rule, wrapped rows are indented by two, and both leads measure two cells,
-- so a draft character N always sits in column N + 2.
local gestureRule = string.rep("─", 120)
local function gestureScreen(...)
  local rows = { ... }
  local lines = { "                                            ctrl+g to edit in VS Code", gestureRule }
  for index, row in ipairs(rows) do
    lines[#lines + 1] = (index == 1 and "❯\194\160" or "  ") .. row
  end
  lines[#lines + 1] = gestureRule
  lines[#lines + 1] = "  Fable 5 high cb:notcom │ cmdx-fixtures │ w:auto cx✓work4·sol·med"
  lines[#lines + 1] = "  ctx ? ? │ 5h 55% 00:30 │ wk 18% Sun 08:00 │ fb 17% Sun 07:59 │ $0.00"
  lines[#lines + 1] = "  ⏵⏵ bypass permissions on (shift+tab to cycle)"
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end
local function gestureTotalLines(rowCount) return rowCount + 6 end
local function gestureRowIndex(row) return row + 2 end

local _, gestureTop, gestureLines, gestureLayout = module.parseInputBox(gestureScreen("hello"))
assert(gestureTop == draftTopIndex and gestureLines == draftLines
    and gestureLayout.columns == screenColumns,
  "the gesture fixture does not share the select-all fixture's geometry")
assert(#gestureLayout.rows == 1 and gestureLayout.rows[1].text == "hello"
    and gestureLayout.rows[1].lead == promptCells
    and gestureLayout.rows[1].index == draftRow,
  "the input box rows were not reported with their leading cells")
local _, _, wrappedTotal, wrappedLayout = module.parseInputBox(gestureScreen("hello brave", "new world"))
assert(wrappedTotal == gestureTotalLines(2) and #wrappedLayout.rows == 2
    and wrappedLayout.rows[2].lead == promptCells
    and wrappedLayout.rows[2].index == gestureRowIndex(2),
  "a wrapped gesture fixture did not report its second draft row")

local function expectedPoint(rowCount, row, character, offset)
  local total = gestureTotalLines(rowCount)
  local rowHeight = terminalFrame.h / total
  local rowBottom = terminalFrame.y + terminalFrame.h
    - (total - gestureRowIndex(row)) * rowHeight
  return (promptCells + character + offset) * (terminalFrame.w / screenColumns),
    rowBottom - rowHeight / 2
end

local function pressGesture(context, keyCode)
  assert(module.handleEvent(optionShiftPress(keyCode)),
    "the Option+Shift word gesture was not consumed")
  -- Which end of its word a start is expected to release on, checked by assertWordClick
  -- below without every call site having to repeat the direction it just pressed.
  context.lastGestureKey = keyCode
  context.runDeferred()
end

-- Two scrapes per gesture: the first has to find the sentinel the TUI may not have
-- drawn yet, the second has to see the box repainted without it before the click.
local function runGesture(context, keyCode, sentinelScreen, cleanScreen)
  pressGesture(context, keyCode)
  context.fireTimer(0.02)
  context.deliverScrape(sentinelScreen)
  if cleanScreen and context.fireTimer(0.05) then
    context.deliverScrape(cleanScreen)
  end
end

local function extendGesture(context, keyCode, screenText)
  pressGesture(context, keyCode)
  context.deliverScrape(screenText)
end

-- A selection is one press dragged onto its head. The TUI counts a click series by time
-- and position, so the harness reads every press back: a second one within a cell of the
-- last is a word select and a third takes the whole row, neither of which any gesture
-- here may paint.
local cellWidth = terminalFrame.w / screenColumns

local function samePoint(one, other)
  return math.abs(one.x - other.x) < 0.001 and math.abs(one.y - other.y) < 0.001
end

local function gestureClicks(context)
  local events, index, clicks = context.mouseEvents(), 1, {}
  local previousPress
  local function pressAt(event, message)
    if previousPress and not samePoint(event, previousPress) then
      assert(math.abs(event.x - previousPress.x) > 2 * cellWidth - 0.001
          or math.abs(event.y - previousPress.y) > 0.001,
        message .. ": a press landed close enough to the one before it to count on")
    end
    previousPress = event
  end
  -- Up to two clicks lead a paint: the breaker that leaves the TUI's click series and
  -- the pre-click that parks its caret on the head, in that order.
  while index <= #events do
    local click = { leading = {} }
    while events[index + 1] and events[index + 1].kind == "up" do
      assert(samePoint(events[index], events[index + 1]),
        "a click leading a paint was released somewhere other than where it pressed")
      assert(events[index].clickState == 1 and events[index + 1].clickState == 1,
        "a click leading a paint did not present itself as a first click")
      click.leading[#click.leading + 1] = events[index]
      pressAt(events[index], "a click leading a paint")
      index = index + 2
    end
    local kinds = {}
    for offset = 0, 2 do
      kinds[#kinds + 1] = events[index + offset] and events[index + offset].kind or "none"
    end
    assert(table.concat(kinds, ",") == "down,dragged,up",
      "a selection was not painted by one press dragged onto its head")
    click.press, click.drag = events[index], events[index + 1]
    assert(samePoint(events[index + 2], click.drag),
      "the drag released somewhere other than where it ended")
    for offset = 0, 2 do
      assert(events[index + offset].clickState == 1,
        "a painted selection counted as a click series of its own")
    end
    pressAt(click.press, "the press")
    index = index + 3
    clicks[#clicks + 1] = click
  end
  return clicks
end

-- What one gesture paints: cells from..to, pressed on the end the anchor sits at and
-- released on the head, which is the end the direction ran towards. `over` is where a
-- one-cell span releases instead, having no second cell of its own to drag onto.
local function assertWordClick(context, nth, span, message)
  local clicks = gestureClicks(context)
  assert(#clicks == nth, message .. ": wrong number of selections")
  local click = clicks[nth]
  local rows, row = span.rows or 1, span.row or 1
  local left = context.lastGestureKey == 123
  local function assertOnCell(event, at, what)
    local x, y = expectedPoint(rows, span.dragRow or row, at, -0.5)
    assert(math.abs(event.x - x) < 0.001 and math.abs(event.y - y) < 0.001,
      message .. ": " .. what .. " missed cell " .. at)
  end
  local pressed = left and span.to or span.from
  assertOnCell(click.press, pressed, "the press")
  assertOnCell(click.drag, span.over or (left and span.from or span.to), "the drag")
  -- The head boundary the caret is parked on: the head cell itself running left, the cell
  -- past it running right. Beside the press there is no room for it.
  local pre = span.pre
  if pre == nil then
    local at = left and span.from or span.to + 1
    pre = math.abs(at - pressed) > 1 and { at = at } or false
  end
  -- `breaker` is the exception: only a press this module or the user made moments ago,
  -- close enough in cells to still be a click series, is worth breaking out of.
  assert(#click.leading == (span.breaker and 1 or 0) + (pre and 1 or 0),
    message .. ": wrong number of clicks led the paint")
  if span.breaker then
    local breaker = click.leading[1]
    assert(math.abs(breaker.x - click.press.x) > 1.5 * cellWidth,
      message .. ": the breaker press was close enough to count as another click")
    assert(math.abs(breaker.y - click.press.y) < 0.001,
      message .. ": the breaker press left the row it was breaking")
  end
  if pre then
    local x, y = expectedPoint(rows, pre.row or span.dragRow or row, pre.at, -0.5)
    local event = click.leading[#click.leading]
    assert(math.abs(event.x - x) < 0.001 and math.abs(event.y - y) < 0.001,
      message .. ": the pre-click missed the head the caret was to park on")
    -- The breaker takes the side of the press the pre-click is not on; beside it, it
    -- would cost the pre-click, which is dropped rather than risk the click series.
    if span.breaker then
      assert((click.leading[1].x - click.press.x) * (x - click.press.x) < 0,
        message .. ": the breaker took the pre-click's side of the press")
    end
  end
end

local function assertNoSelection(context, message)
  assert(#context.mouseEvents() == 0, message .. ": clicked")
  assert(context.alerts() == 0, message .. ": raised an alert")
  assert(table.concat(context.actions, ",") == "sentinel,scrape,cut",
    message .. ": did not type and remove exactly one sentinel")
end

local gestureOpts = { windowFrame = terminalFrame, verdict = "claude" }
local hello = "hello world"

-- The reported live bug: with the cursor at the end of the draft the first press
-- painted nothing. Terminal answered the scrape from the screen it still held, so
-- the sentinel was missing and the gesture gave up after the flicker.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello))
assert(#integration.mouseEvents() == 0, "a scrape that missed the sentinel still clicked")
assert(table.concat(integration.actions, ",") == "sentinel,scrape",
  "the gesture removed the sentinel before it had been found")
assert(integration.fireTimer(0.02), "the gesture did not re-scrape for the missing sentinel")
integration.deliverScrape(gestureScreen(hello .. sentinel))
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the retried gesture did not select the last word")
assert(table.concat(integration.actions, ",") == "sentinel,scrape,scrape,cut,scrape",
  "the retried gesture typed or removed the sentinel twice")

integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
for _ = 1, 3 do
  integration.fireTimer(0.02)
  integration.deliverScrape(gestureScreen(hello))
end
assert(#integration.mouseEvents() == 0, "a gesture that never saw its sentinel clicked")
assert(integration.actions[#integration.actions] == "cut",
  "a gesture that gave up left the sentinel in the draft")
assert(integration.alerts() == 0, "an abandoned gesture raised an alert")
assert(not integration.fireTimer(0.02), "the gesture kept re-scraping past its attempt cap")

-- A character typed into the sentinel window reaches the draft first, so the DEL that
-- would take the sentinel out would take that character instead.
integration = integrationContext(textTypes, gestureOpts)
pressGesture(integration, 123)
assert(not module.handleEvent(charPress("Z")), "a character typed mid-gesture was consumed")
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(table.concat(integration.actions, ",") == "sentinel,scrape",
  "a gesture whose draft was typed into deleted the character the user had typed")

-- Giving up because the target is gone: the DEL would be typed into whoever took the
-- foreground, so the sentinel stays in the draft instead.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.switchApp("com.apple.Safari")
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(table.concat(integration.actions, ",") == "sentinel,scrape",
  "a gesture that lost its target typed the DEL into the window that replaced it")
assert(#integration.mouseEvents() == 0, "a gesture that lost its target clicked")

-- The DEL repaints the box; a click posted against the sentinel screen would land on
-- cells that have moved.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel))
assert(#integration.mouseEvents() == 0, "the gesture clicked before the DEL had repainted")
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(#integration.mouseEvents() == 0, "the gesture clicked on a box still holding the sentinel")
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 }, "the gesture did not wait out the repaint")

integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel))
for _ = 1, 3 do
  integration.fireTimer(0.05)
  integration.deliverScrape(gestureScreen("hello brave world"))
end
assert(#integration.mouseEvents() == 0, "the gesture clicked over a draft that changed under it")
assert(not integration.fireTimer(0.05), "the repaint check kept re-scraping past its cap")

-- Cursor at the end, and the same press repeated.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "left at the draft end did not select the last word")
extendGesture(integration, 123, gestureScreen(hello))
assertWordClick(integration, 2, { from = 1, to = 11, breaker = true },
  "the repeated left gesture did not extend by one word")
assert(integration.alerts() == 0, "the word gesture raised an alert")

-- A burst of presses is where the TUI's click series bites: every press of the run
-- has to land on its own new head word, far enough from the press before it that the
-- series starts over instead of reaching the third click and taking the whole row.
local counted = "one two three four five six"
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(counted .. sentinel), gestureScreen(counted))
local heads = { 20, 15, 9, 5, 1 }
for index, head in ipairs(heads) do
  extendGesture(integration, 123, gestureScreen(counted))
  assertWordClick(integration, index + 1, { from = head, to = 27, breaker = true },
    "a burst extension did not take the next word")
end
extendGesture(integration, 123, gestureScreen(counted))
assert(#gestureClicks(integration) == #heads + 1,
  "a burst that ran out of words clicked in place")

-- Single-character words leave the least room between one press and the next.
local narrow = "a b c d e f"
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(narrow .. sentinel), gestureScreen(narrow))
for index, head in ipairs({ 9, 7, 5, 3, 1 }) do
  extendGesture(integration, 123, gestureScreen(narrow))
  assertWordClick(integration, index + 1, { from = head, to = 11, breaker = true },
    "a narrow burst extension did not take the next word")
end

-- Cursor at the start: nothing to the left, the first word to the right.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(sentinel .. hello), gestureScreen(hello))
assertNoSelection(integration, "left at the draft start")
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 124, gestureScreen(sentinel .. hello), gestureScreen(hello))
assertWordClick(integration, 1, { from = 1, to = 5 },
  "right at the draft start did not select the first word")
extendGesture(integration, 124, gestureScreen(hello))
assertWordClick(integration, 2, { from = 1, to = 11, breaker = true },
  "the repeated right gesture did not extend by one word")

-- Mid-draft, both directions: the word behind the cursor, and past the space in front of
-- it. A space paints nothing anyone can see, so the span reaches over it to that word.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("hello" .. sentinel .. " world"), gestureScreen(hello))
assertWordClick(integration, 1, { from = 1, to = 5 }, "left mid-draft did not select the whole word")
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 124, gestureScreen("hello" .. sentinel .. " world"), gestureScreen(hello))
assertWordClick(integration, 1, { from = 6, to = 11 },
  "right onto a space did not reach the word past it")


local spaced = "one two three"
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("one two " .. sentinel .. "three"),
  gestureScreen(spaced))
assertWordClick(integration, 1, { from = 5, to = 8 },
  "left onto a space did not reach the word before it")
extendGesture(integration, 123, gestureScreen(spaced))
assertWordClick(integration, 2, { from = 1, to = 8, breaker = true },
  "extending off a space-anchored selection did not take the next word")
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 124, gestureScreen("hello " .. sentinel .. "world"), gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "right after a space did not select the next word")

-- Only spaces past the space: there is no word to reach, so the space is the
-- selection, invisible in the TUI but real enough for the Cmd+X that follows.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(" " .. sentinel .. "hello"), gestureScreen(" hello"))
assertWordClick(integration, 1, { from = 1, to = 1, over = 0 },
  "a leading space with nothing behind it did not select itself")

-- Punctuation is worth exactly its own cell, and the word behind it is the next one.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("foo," .. sentinel .. " bar"), gestureScreen("foo, bar"))
assertWordClick(integration, 1, { from = 4, to = 4, over = 3 },
  "left onto punctuation did not select one cell")
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut,scrape,chord:shift+right",
  "the one-cell word gesture did not shrink its overshoot back")
extendGesture(integration, 123, gestureScreen("foo, bar"))
assertWordClick(integration, 2, { from = 1, to = 4, breaker = true },
  "extending off punctuation did not take the word behind it")

-- Two of them side by side are the one extension that barely moves: a press one cell
-- from the last is the same click series to the TUI, and its third click takes the row.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("hi))" .. sentinel), gestureScreen("hi))"))
assertWordClick(integration, 1, { from = 4, to = 4, over = 3 },
  "left onto a bracket did not select one cell")
extendGesture(integration, 123, gestureScreen("hi))"))
assertWordClick(integration, 2, { from = 3, to = 4, breaker = true },
  "an extension onto the neighbouring cell did not break the click series")

-- One word, one character, and an empty draft.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("hello" .. sentinel), gestureScreen("hello"))
assertWordClick(integration, 1, { from = 1, to = 5 }, "a single-word draft did not select its only word")
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 124, gestureScreen("hello" .. sentinel), gestureScreen("hello"))
assertNoSelection(integration, "right at the end of a single-word draft")
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("x" .. sentinel), gestureScreen("x"))
assertWordClick(integration, 1, { from = 1, to = 1, over = 0 },
  "a one-character draft did not select its only cell")
for _, keyCode in ipairs({ 123, 124 }) do
  integration = integrationContext(nil, gestureOpts)
  runGesture(integration, keyCode, gestureScreen(sentinel), gestureScreen(""))
  assertNoSelection(integration, "an empty draft")
end

-- A wrapped draft: the word at the first column of the second row. Measured live,
-- the TUI paints a selection inside one row only — it clamps a drag ending on another
-- row to the row it was pressed on — so the row boundary is where the gesture stops
-- instead of trading the whole selection for the one word past it.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("hello brave", "n" .. sentinel .. "ew world"),
  gestureScreen("hello brave", "new world"))
assertWordClick(integration, 1, { rows = 2, row = 2, from = 1, to = 3 },
  "a wrapped row's first word was not selected")
extendGesture(integration, 123, gestureScreen("hello brave", "new world"))
assert(#gestureClicks(integration) == 1, "the extension crossed the wrap onto another row")

integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("hello brave", "new world" .. sentinel),
  gestureScreen("hello brave", "new world"))
assertWordClick(integration, 1, { rows = 2, row = 2, from = 5, to = 9 },
  "the end of a wrapped draft did not select the last word")

-- The sentinel itself pushed the draft over the wrap: taking it out unwraps the box,
-- and the word is one word again.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("hello worl", "d" .. sentinel), gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "a word the sentinel had split across the wrap was not rejoined")

-- Terminal draws the block cursor past the draft as a no-break space on some scrapes
-- only, so two reads of an untouched draft can differ by one trailing cell.
local cursorCell = "\194\160"
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello .. cursorCell))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "a repaint that grew a phantom cursor cell was read as another draft")

integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. " " .. sentinel), gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "a repaint that trimmed the trailing space was read as another draft")

integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
extendGesture(integration, 123, gestureScreen(hello .. cursorCell))
assertWordClick(integration, 2, { from = 1, to = 11, breaker = true },
  "the signature of an unchanged draft failed over a phantom cursor cell")

-- Nothing may reach the draft between the sentinel and the click that follows it,
-- the next press of the chord least of all.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(module.handleEvent(optionShiftPress(123)), "a gesture press mid-flight was not consumed")
integration.runDeferred()
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut",
  "a gesture press mid-flight started a second pass")
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 }, "the settled gesture did not select the word")

-- A draft that already carried the sentinel cannot say where the cursor is.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("a" .. sentinel .. "b" .. sentinel))
assertNoSelection(integration, "a draft holding two sentinels")

-- A box that repainted under the selection: the cached cell indices no longer
-- describe the draft they were measured on.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
extendGesture(integration, 123, gestureScreen("hello brave world"))
assert(#gestureClicks(integration) == 1, "the gesture extended over a repainted box")
pressGesture(integration, 123)
assert(integration.fireTimer(0.02), "the mismatched re-scrape left the gesture cache in place")

-- The cached geometry describes a draft that is gone, so that bail has to stay
-- disarmed: a Cmd+X armed off it would DEL a selection nobody can locate.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
extendGesture(integration, 123, gestureScreen("hello brave world"))
local settled = #integration.actions
assert(module.handleEvent(xPress(false)), "Cmd+X after a repainted extension was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == settled, "a bail on the repainted box left Cmd+X armed")

-- A burst that runs past the draft start bails with the draft untouched, so the
-- selection it stopped extending is still painted and still has to cut.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
extendGesture(integration, 123, gestureScreen(hello))
for _ = 1, 2 do
  pressGesture(integration, 123)
  assert(integration.actions[#integration.actions] == "scrape",
    "an extension past the draft start restarted the gesture instead of extending it")
  integration.deliverScrape(gestureScreen(hello))
end
assert(#gestureClicks(integration) == 2, "an extension past the draft start clicked")
settled = #integration.actions
assert(module.handleEvent(xPress(false)), "Cmd+X after an exhausted burst was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == settled + 1,
  "an extension past the draft start disarmed the selection it had left painted")
integration.deliverScrape(gestureScreen(hello))
integration.fireCutTimer()
integration.deliverScrape(gestureScreen(""))
assert(integration.wrote() == "hello world",
  "Cmd+X did not cut the selection an exhausted burst had left painted")

-- The same bail at the wrap: the row-boundary clamp stops the extension without
-- changing anything the selection stands on.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("hello brave", "n" .. sentinel .. "ew world"),
  gestureScreen("hello brave", "new world"))
extendGesture(integration, 123, gestureScreen("hello brave", "new world"))
settled = #integration.actions
assert(module.handleEvent(xPress(false)), "Cmd+X after a wrap-clamped extension was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == settled + 1,
  "the wrap-clamped extension disarmed the selection it had left painted")

-- Opposite direction: consumed, and the gesture it interrupted still extends.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assert(module.handleEvent(optionShiftPress(124)), "the opposite direction was not consumed")
integration.runDeferred()
assert(#gestureClicks(integration) == 1 and #integration.actions == 4,
  "the opposite direction touched the live selection")
extendGesture(integration, 123, gestureScreen(hello))
assertWordClick(integration, 2, { from = 1, to = 11, breaker = true },
  "the opposite direction dropped the gesture it consumed")

-- The clicks we post come back through the tap, and a press of our own is a plain click
-- to everything reading it: taken at face value it would clear the selection state the
-- very same synthesis is arming.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
local ownClick = mouseEvent(2, { x = 120, y = 340 })
ownClick.properties[91] = module.replayMarker
assert(not module.handleEvent(ownClick), "a click we posted ourselves was consumed")
extendGesture(integration, 123, gestureScreen(hello))
assertWordClick(integration, 2, { from = 1, to = 11, breaker = true },
  "our own click ended the gesture it belonged to")

-- A click of the user's own is the user taking the selection back.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
simulateClick()
pressGesture(integration, 123)
assert(integration.actions[#integration.actions] == "sentinel",
  "a real click left the gesture cache in place")

-- A double-click selects without ever clearing the state, so the cache would survive
-- a selection of the user's own and the next chord would repaint over it from an
-- anchor they never set.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
simulateMultiClick(2)
pressGesture(integration, 123)
assert(integration.actions[#integration.actions] == "sentinel",
  "a mouse selection of the user's own left the gesture cache in place")

-- The cut owns the DEL-and-diff window the gesture would type into.
integration = integrationContext(nil, gestureOpts)
dragThenCut(integration)
assert(module.handleEvent(optionShiftPress(123)), "the mid-cut gesture was not consumed")
integration.runDeferred()
assert(table.concat(integration.actions, ",") == "scrape",
  "the gesture ran while a cut held the input box")
assert(#integration.mouseEvents() == 0, "the mid-cut gesture clicked")

-- The reverse window: the sentinel is in the draft and its DEL is still owed, so a
-- draft-rewriting flow starting here would interleave with it — worst case Cmd+A
-- selects the whole draft and that DEL wipes it. Dropped, not queued.
for _, press in ipairs({ aPress, xPress }) do
  integration = integrationContext(nil, gestureOpts)
  pressGesture(integration, 123)
  integration.fireTimer(0.02)
  integration.deliverScrape(gestureScreen(hello .. sentinel))
  -- The user's own drag inside the window is what arms the cut at all.
  simulateDrag()
  assert(module.handleEvent(press(false)), "a draft rewrite mid-gesture was not consumed")
  integration.resolve("claude")
  integration.runDeferred()
  assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut",
    "a draft rewrite ran while the gesture still owed its sentinel DEL")
  assert(#integration.mouseEvents() == 0, "a draft rewrite mid-gesture clicked")
  integration.fireTimer(0.05)
  integration.deliverScrape(gestureScreen(hello))
  assertWordClick(integration, 1, { from = 7, to = 11, breaker = true },
    "the gesture did not finish past a mid-flight draft rewrite")
end

-- A replace is the one draft rewrite carrying something a re-press cannot recover:
-- the character the user typed. It leaves as itself, and the sentinel DEL — which
-- would now take that character instead — is the one that stands down.
integration = integrationContext(textTypes, gestureOpts)
pressGesture(integration, 123)
simulateDrag()
assert(module.handleEvent(charPress("Z")), "the typed character was not consumed for the verdict")
integration.resolve("claude")
assert(integration.replayed() == "Z",
  "a character typed over a selection mid-gesture was dropped with the chords")
assert(table.concat(integration.actions, ",") == "sentinel,replay",
  "the character mid-gesture reached the draft through a flow of its own")
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(table.concat(integration.actions, ",") == "sentinel,replay,scrape",
  "the gesture DEL'd the character the user had typed over its sentinel")

-- Terminal can drop a scrape callback on the floor; with nothing to lower the flight
-- flag, every later chord is eaten for good.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.fireTimer(0.02)
assert(table.concat(integration.actions, ",") == "sentinel,scrape",
  "the gesture fixture did not reach its unanswered scrape")
assert(integration.fireGestureWatchdog(), "no watchdog was armed for the gesture")
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut",
  "the watchdog left its own sentinel in the draft")
assert(module.handleEvent(zPress(false)), "Cmd+Z after the watchdog was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[#integration.actions] == "undo",
  "a gesture the watchdog ended kept eating the chords its window swallows")
-- The abandoned scrape can still arrive: its click would paint over a draft nobody
-- is holding any more, and its DEL would be the second one.
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(#integration.mouseEvents() == 0, "a scrape arriving after the watchdog clicked")
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut,undo",
  "a scrape arriving after the watchdog ran the gesture anyway")

integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.fireTimer(0.02)
integration.changeTarget()
assert(integration.fireGestureWatchdog(), "no watchdog was armed for the gesture")
assert(table.concat(integration.actions, ",") == "sentinel,scrape",
  "the watchdog typed its DEL into the window that replaced the target")

integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assert(not integration.fireGestureWatchdog(), "a finished gesture left its watchdog armed")
extendGesture(integration, 123, gestureScreen(hello))
assert(not integration.fireGestureWatchdog(), "an extension left its watchdog armed")

-- A step that throws after the sentinel keystroke: the flight ends, and the removal is
-- owed by that error path too, or the character we typed stays in the draft with
-- nothing left in the world that would ever take it back out.
integration = integrationContext(nil,
  { windowFrame = terminalFrame, verdict = "claude", afterThrows = 0.02 })
pressGesture(integration, 123)
assert(table.concat(integration.actions, ",") == "sentinel,cut",
  "a gesture that threw past its own sentinel left it in the user's draft")
assert(module.handleEvent(zPress(false)), "Cmd+Z after the failed gesture was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[#integration.actions] == "undo",
  "a gesture that threw kept eating the chords its window swallows")

-- The same throw with the target already gone: the DEL would be typed into whatever
-- took the tab's place, so the sentinel stays where it is.
integration = integrationContext(nil,
  { windowFrame = terminalFrame, verdict = "claude", afterThrows = 0.02 })
assert(module.handleEvent(optionShiftPress(123)), "the gesture press was not consumed")
-- The tab goes between the check that let the sentinel out and the step that throws.
integration.changeTargetAfterNextObservation()
integration.runDeferred()
assert(table.concat(integration.actions, ",") == "sentinel",
  "a gesture that threw typed its DEL into the window that replaced the target")

-- Terminal answers whoever asked, whenever it likes. Flight A's answer arriving while
-- flight B holds the draft used to be read against a single in-flight flag: A's give-up
-- posted its DEL into B's sentinel and ended B's flight, so B's own answer then found
-- the flag down and B's sentinel stayed in the draft for good.
do
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.fireTimer(0.02)
local strayScrape = integration.takeScrape()
assert(integration.fireGestureWatchdog(), "no watchdog was armed for the first gesture")
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut",
  "the watchdog left the first gesture's sentinel in the draft")
pressGesture(integration, 123)
integration.fireTimer(0.02)
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut,sentinel,scrape",
  "the second gesture did not reach a scrape of its own")
strayScrape(gestureScreen(hello))
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut,sentinel,scrape",
  "an answer to the ended gesture acted inside the live one")
assert(not integration.fireTimer(0.02),
  "the ended gesture armed a re-scrape over the live one's timer")
integration.deliverScrape(gestureScreen(hello .. sentinel))
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the live gesture did not finish past the ended one's answer")
assert(table.concat(integration.actions, ",")
    == "sentinel,scrape,cut,sentinel,scrape,cut,scrape",
  "the live gesture's own sentinel was left in the draft")
end

-- The watchdog belongs to the flight that armed it: fired late it must not tear down
-- the gesture that took over, whose sentinel is the one in the draft now.
do
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.fireTimer(0.02)
local strayWatchdog = integration.takeGestureWatchdog()
integration.changeTarget()
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(table.concat(integration.actions, ",") == "sentinel,scrape",
  "the first gesture did not give up on the target that had gone")
pressGesture(integration, 123)
assert(table.concat(integration.actions, ",") == "sentinel,scrape,sentinel",
  "the second gesture did not type a sentinel of its own")
strayWatchdog()
assert(table.concat(integration.actions, ",") == "sentinel,scrape,sentinel",
  "the ended gesture's watchdog DEL'd the sentinel of the one that took over")
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the live gesture did not finish past the ended one's watchdog")
end

-- Stopping between the sentinel and the scrape that owes its DEL: the character we
-- typed is in the user's draft, and nothing else will ever take it back out.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
assert(table.concat(integration.actions, ",") == "sentinel",
  "the gesture fixture did not stop on its own sentinel")
module.stop()
assert(table.concat(integration.actions, ",") == "sentinel,cut",
  "M.stop left its own sentinel in the user's draft")

integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.changeTarget()
module.stop()
assert(table.concat(integration.actions, ",") == "sentinel",
  "M.stop typed the sentinel DEL into the window that replaced the target")

integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
module.stop()
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut,scrape",
  "M.stop sent a second DEL for a sentinel that was already gone")

-- The caret AX answers with names the very cell the sentinel used to occupy, so the
-- gesture can read it instead of typing one: no keystroke into the user's draft, no DEL
-- owed for it, one scrape instead of two. Any press AX cannot place lands back on the
-- sentinel path unchanged. Scoped: this chunk sits at the same 200-local ceiling the
-- module does.
do
-- The box AX hands back is the caret cell's top-left corner, and draft character N of a
-- row sits in column N + promptCells — the same column expectedPoint measures from.
local function caretAt(rowCount, row, character)
  local total = gestureTotalLines(rowCount)
  local rowHeight = terminalFrame.h / total
  return {
    x = terminalFrame.x + (promptCells + character - 1) * (terminalFrame.w / screenColumns),
    y = terminalFrame.y + terminalFrame.h
      - (total - gestureRowIndex(row)) * rowHeight - rowHeight,
  }
end
local function caretOpts(point)
  return { windowFrame = terminalFrame, verdict = "claude", caret = point }
end
local function runCaretGesture(point, keyCode, screen)
  integration = integrationContext(nil, caretOpts(point))
  pressGesture(integration, keyCode)
  integration.deliverScrape(screen)
  return integration
end
-- Compared point for point: one cell of drift between the paths is the whole bug this
-- parity is here to catch, and it selects the word beside the one the user asked for.
local function clickTrace(context)
  local parts = {}
  for _, event in ipairs(context.mouseEvents()) do
    parts[#parts + 1] = string.format("%s %.3f %.3f %d", event.kind, event.x, event.y,
      event.clickState or 0)
  end
  return table.concat(parts, ",")
end
local function assertParity(keyCode, sentinelScreen, cleanScreen, point, message)
  integration = integrationContext(nil, gestureOpts)
  runGesture(integration, keyCode, sentinelScreen, cleanScreen)
  local trace = clickTrace(integration)
  assert(trace ~= "", message .. ": the sentinel path selected nothing to compare against")
  local caretRun = runCaretGesture(point, keyCode, cleanScreen)
  assert(clickTrace(caretRun) == trace, message .. ": the two caret sources clicked apart")
  assert(table.concat(caretRun.actions, ",") == "scrape",
    message .. ": the caret path typed a sentinel or read a second screen")
end

assert(module.caretGestures(), "the AX caret source was not the default")
assertParity(123, gestureScreen("hello" .. sentinel .. " world"), gestureScreen(hello),
  caretAt(1, 1, 6), "left with the caret mid-draft")
assertParity(124, gestureScreen("hello" .. sentinel .. " world"), gestureScreen(hello),
  caretAt(1, 1, 6), "right over the space the caret sits on")
assertParity(124, gestureScreen(sentinel .. hello), gestureScreen(hello),
  caretAt(1, 1, 1), "right with the caret at the draft start")
assertParity(123, gestureScreen(hello .. sentinel), gestureScreen(hello .. cursorCell),
  caretAt(1, 1, 12), "left with the caret past the last character")
assertParity(123, gestureScreen("hello brave", "n" .. sentinel .. "ew world"),
  gestureScreen("hello brave", "new world"), caretAt(2, 2, 2),
  "left with the caret on a wrapped row")

-- The cache the AX press arms is the sentinel's: the next press of the chord extends it
-- the same way, without either path knowing which one started the selection.
integration = runCaretGesture(caretAt(1, 1, 12), 123, gestureScreen(hello .. cursorCell))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the AX caret at the draft end did not select the last word")
extendGesture(integration, 123, gestureScreen(hello .. cursorCell))
assertWordClick(integration, 2, { from = 1, to = 11, breaker = true },
  "an AX-started gesture did not extend by one word")

-- Nothing was typed, so there is nothing to take back out: a Return mid-flight passes as
-- itself instead of being held for a DEL that does not exist.
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 6)))
pressGesture(integration, 123)
assert(not module.handleEvent(keyEvent(36, {}, false, "return")),
  "the AX gesture held a Return for a sentinel it never typed")
integration.deliverScrape(gestureScreen(hello))
assert(#integration.mouseEvents() == 0, "the AX gesture clicked over a draft typed into")
assert(table.concat(integration.actions, ",") == "scrape",
  "the AX gesture emitted a keystroke of its own")

-- The flight bookkeeping is the sentinel path's, watchdog included: a scrape Terminal
-- never answers must still lower the flag every later chord is read against.
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 6)))
pressGesture(integration, 123)
assert(integration.fireGestureWatchdog(), "the AX gesture flew without a watchdog")
assert(table.concat(integration.actions, ",") == "scrape",
  "the watchdog DEL'd a sentinel the AX path never typed")
integration.deliverScrape(gestureScreen(hello))
assert(#integration.mouseEvents() == 0, "a scrape arriving after the watchdog clicked")
assert(module.handleEvent(zPress(false)), "the ended AX gesture kept eating chords")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[#integration.actions] == "undo",
  "the AX gesture left its in-flight guard armed")

integration = integrationContext(nil, caretOpts(caretAt(1, 1, 6)))
pressGesture(integration, 123)
integration.changeTarget()
integration.deliverScrape(gestureScreen(hello))
assert(#integration.mouseEvents() == 0 and table.concat(integration.actions, ",") == "scrape",
  "the AX gesture clicked in the tab that replaced its target")

integration = integrationContext(nil, {
  windowFrame = terminalFrame,
  verdict = "claude",
  caretCalibrationNeeded = true,
  caretAfterScrape = caretAt(1, 1, 12),
})
pressGesture(integration, 123)
assert(table.concat(integration.actions, ",") == "scrape",
  "a stale caret calibration typed the sentinel before recalibrating")
integration.deliverScrape(gestureScreen(hello .. cursorCell), "as")
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the recalibration scrape was not reused by the caret gesture")
assert(table.concat(integration.actions, ",") == "scrape",
  "the recalibrated caret path scraped twice or typed a sentinel")

integration = integrationContext(nil, {
  windowFrame = terminalFrame,
  verdict = "claude",
  caretCalibrationNeeded = true,
})
pressGesture(integration, 123)
integration.changeTarget()
integration.deliverScrape(gestureScreen(hello), "as")
assert(table.concat(integration.actions, ",") == "scrape",
  "a calibration callback typed a sentinel into the replacement tab")

-- Off from the console: the caret is not even asked for, and the sentinel does the work.
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 6)))
assert(module.caretGestures(false) == false, "the caret source did not report itself off")
pressGesture(integration, 123)
assert(integration.caretReads() == 0, "a gesture read the caret with the AX source off")
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen("hello" .. sentinel .. " world"))
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 1, to = 5 },
  "the sentinel path did not run with the AX source off")
assert(module.caretGestures(true), "the caret source did not come back on")

-- A window AX says nothing about: the seam was asked and answered nothing, and the
-- gesture is the sentinel's from the first keystroke.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
assert(integration.caretReads() == 1, "the gesture never asked for a caret")
assert(integration.actions[1] == "sentinel",
  "a gesture with no caret to read skipped the sentinel anyway")
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen("hello" .. sentinel .. " world"))
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 1, to = 5 },
  "the sentinel fallback did not select the word the caret would have")

-- A caret the screen cannot account for — the transcript above the box, or a column
-- past everything the draft row holds — is a caret describing a screen that has moved
-- on. The sentinel starts over, and its own scrape is the one that decides.
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 6)))
pressGesture(integration, 123)
integration.deliverScrape("screen without an input box")
assert(table.concat(integration.actions, ",") == "scrape,sentinel",
  "an unparseable caret scrape did not fall back to the sentinel")
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the sentinel fallback after an unparseable caret scrape did not select the word")

for _, point in ipairs({ caretAt(1, -1, 1), caretAt(1, 1, 30) }) do
  integration = integrationContext(nil, caretOpts(point))
  pressGesture(integration, 123)
  integration.deliverScrape(gestureScreen(hello))
  assert(table.concat(integration.actions, ",") == "scrape,sentinel",
    "a caret outside the draft did not fall back to the sentinel")
  integration.fireTimer(0.02)
  integration.deliverScrape(gestureScreen("hello" .. sentinel .. " world"))
  integration.fireTimer(0.05)
  integration.deliverScrape(gestureScreen(hello))
  assertWordClick(integration, 1, { from = 1, to = 5 },
    "the sentinel fallback of an unplaceable caret did not select the word")
  assert(table.concat(integration.actions, ",") == "scrape,sentinel,scrape,cut,scrape",
    "the fallback did not type and remove exactly one sentinel")
end

-- Cmd+Shift+arrow paints what the bare chord moves over: a press on the caret's own
-- cell dragged to the edge, no double click for the TUI to snap to a word.
local function spanPress(keyCode)
  return keyEvent(keyCode, { "cmd", "shift", "fn" }, false, "cmd-shift-arrow")
end
local function runSpan(point, keyCode, screen)
  integration = integrationContext(nil, caretOpts(point))
  assert(module.handleEvent(spanPress(keyCode)), "the Cmd+Shift span chord was not consumed")
  integration.runDeferred()
  integration.deliverScrape(screen)
  return integration
end
-- `pre` is the cell the caret is parked on before the paint: the drag's own cell running
-- left, the one past it running right, and none at all where that lands beside the press.
local function assertSpan(context, rows, press, drag, message, actions, pre)
  local events = context.mouseEvents()
  local down, dragged
  for _, event in ipairs(events) do
    if event.kind == "down" then down = event end
    if event.kind == "dragged" then dragged = event end
  end
  assert(down and dragged, message .. ": nothing was pressed and dragged")
  local function assertAt(event, at, what)
    local x, y = expectedPoint(rows, at[1], at[2], -0.5)
    assert(math.abs(event.x - x) < 0.001 and math.abs(event.y - y) < 0.001,
      message .. ": " .. what .. " missed its cell")
    assert(event.clickState == 1, message .. ": " .. what .. " counted as a double click")
  end
  if pre == nil then
    pre = (drag[1] < press[1] or (drag[1] == press[1] and drag[2] < press[2]))
      and drag or { drag[1], drag[2] + 1 }
    if pre[1] == press[1] and math.abs(pre[2] - press[2]) <= 1 then
      pre = false
    end
  end
  assert(#events == (pre and 2 or 0) + 3, message .. ": wrong number of clicks led the paint")
  if pre then
    assertAt(events[1], pre, "the pre-click")
  end
  assertAt(down, press, "the press")
  assertAt(dragged, drag, "the drag")
  assert(table.concat(context.actions, ",") == (actions or "scrape"),
    message .. ": the span did not emit exactly " .. (actions or "scrape"))
end

local oneRow = gestureScreen("hello world")
assertSpan(runSpan(caretAt(1, 1, 7), 123, oneRow), 1, { 1, 6 }, { 1, 1 },
  "Cmd+Shift+Left did not select from the caret back to the row start")
assertSpan(runSpan(caretAt(1, 1, 7), 124, oneRow), 1, { 1, 7 }, { 1, 11 },
  "Cmd+Shift+Right did not select from the caret to the row end")

-- Where the caret actually sits in a draft being typed: one past the last cell, on a
-- block cursor the measurement drops. Every chord below painted nothing until it did.
assertSpan(runSpan(caretAt(1, 1, 12), 123, gestureScreen(hello .. cursorCell)), 1,
  { 1, 11 }, { 1, 1 },
  "Cmd+Shift+Left painted nothing with the caret at the draft end")
assertSpan(runSpan(caretAt(1, 1, 7), 123, gestureScreen("hello " .. cursorCell)), 1,
  { 1, 6 }, { 1, 1 },
  "Cmd+Shift+Left dropped a real trailing space before the caret")

-- A wrapped draft: the row motions stay on the caret's own row, the document ones cross.
local twoRows = gestureScreen("hello brave", "new world")
-- One cell wide, so the drag has to leave it: released on the column beside the row's
-- first, which the TUI clamps back onto that row's edge.
assertSpan(runSpan(caretAt(2, 2, 2), 123, twoRows), 2, { 2, 1 }, { 2, 0 },
  "Cmd+Shift+Left reached past the wrapped row it started on")
assertSpan(runSpan(caretAt(2, 2, 2), 124, twoRows), 2, { 2, 2 }, { 2, 9 },
  "Cmd+Shift+Right did not stop at the end of the wrapped row")
-- The boundary past the last cell of a row that wraps is the next row's first cell, where
-- a click would park the caret a row below its selection: the free column beside the row's
-- own edge is the same buffer position and stays on the row.
assertSpan(runSpan(caretAt(2, 1, 6), 124, twoRows), 2, { 1, 6 }, { 1, 11 },
  "Cmd+Shift+Right did not select to the end of the wrapped row it started on",
  nil, { 1, 12 })
assertSpan(runSpan(caretAt(2, 2, 2), 126, twoRows), 2, { 2, 1 }, { 1, 1 },
  "Cmd+Shift+Up did not select back to the first draft cell")
assertSpan(runSpan(caretAt(2, 1, 6), 125, twoRows), 2, { 1, 6 }, { 2, 9 },
  "Cmd+Shift+Down did not select on to the last draft cell")

-- Bare Cmd+Left/Right place the caret with one click on the row edge, no drag and no
-- second press: the TUI's own Home/End move by buffer position, which on a wrapped row
-- renders a row away from where macOS puts the caret.
local function runCaretMove(point, keyCode, screen)
  integration = integrationContext(nil, caretOpts(point))
  assert(module.handleEvent(keyEvent(keyCode, { "cmd", "fn" }, false, "cmd-arrow")),
    "the bare Cmd+arrow was not consumed")
  integration.runDeferred()
  integration.deliverScrape(screen)
  return integration
end
local function assertCaretMove(context, rows, at, message)
  local events = context.mouseEvents()
  assert(#events == 2 and events[1].kind == "down" and events[2].kind == "up",
    message .. ": the caret move did not click exactly once")
  local x, y = expectedPoint(rows, at[1], at[2], -0.5)
  assert(math.abs(events[1].x - x) < 0.001 and math.abs(events[1].y - y) < 0.001,
    message .. ": the click missed its cell")
  assert(events[1].clickState == 1, message .. ": the click counted as a double click")
  assert(table.concat(context.actions, ",") == "scrape",
    message .. ": the caret move typed a keystroke of its own")
end

assertCaretMove(runCaretMove(caretAt(1, 1, 7), 123, oneRow), 1, { 1, 1 },
  "Cmd+Left did not click the first cell of the row")
assertCaretMove(runCaretMove(caretAt(1, 1, 7), 124, oneRow), 1, { 1, 12 },
  "Cmd+Right did not click past the last cell of the row")
assertCaretMove(runCaretMove(caretAt(1, 1, 12), 123, gestureScreen(hello .. cursorCell)), 1,
  { 1, 1 }, "Cmd+Left missed the row start with the caret at the draft end")
assertCaretMove(runCaretMove(caretAt(1, 1, 12), 123, oneRow), 1,
  { 1, 1 }, "Cmd+Left missed the row start from a bare past-edge caret")
assertCaretMove(runCaretMove(caretAt(1, 1, 7), 123, gestureScreen("hello " .. cursorCell)), 1,
  { 1, 1 }, "Cmd+Left missed the row start from behind a real trailing space")

-- Standing on the edge the chord reaches for: no click at all, or the user watches the
-- pointer jump onto the caret's own cell and back for nothing.
local standEnd = runCaretMove(caretAt(1, 1, 7), 124, gestureScreen("hello " .. cursorCell))
assert(#standEnd.mouseEvents() == 0,
  "Cmd+Right after a trailing space clicked instead of standing at the row end")
assert(table.concat(standEnd.actions, ",") == "scrape",
  "the standing Cmd+Right typed a keystroke of its own")
local standStart = runCaretMove(caretAt(1, 1, 1), 123, oneRow)
assert(#standStart.mouseEvents() == 0,
  "Cmd+Left at the row start clicked instead of standing")

-- A wrapped row filled to the box edge: "after the last character" is the next row's
-- first cell and the TUI renders a click there a row down, so the move clicks the last
-- cell instead and the caret keeps its row.
local edgeText = string.rep("a", screenColumns - promptCells - 2)
assertCaretMove(runCaretMove(caretAt(2, 1, 5), 124, gestureScreen(edgeText, "tail")), 2,
  { 1, screenColumns - promptCells - 2 },
  "Cmd+Right left an edge-filled wrapped row")
-- The free column beside that row's last cell is the box's own last column, which renders
-- a row down just the same: the span parks the caret on the last cell instead.
assertSpan(runSpan(caretAt(2, 1, 5), 124, gestureScreen(edgeText, "tail")), 2, { 1, 5 },
  { 1, screenColumns - promptCells - 2 },
  "Cmd+Shift+Right parked the caret off an edge-filled wrapped row", nil,
  { 1, screenColumns - promptCells - 2 })

-- A wrapped draft: neither direction may leave the caret's own row.
assertCaretMove(runCaretMove(caretAt(2, 2, 2), 123, twoRows), 2, { 2, 1 },
  "Cmd+Left crossed the wrap to the row above")
assertCaretMove(runCaretMove(caretAt(2, 2, 2), 124, twoRows), 2, { 2, 10 },
  "Cmd+Right did not stop at the end of the wrapped row")
assertCaretMove(runCaretMove(caretAt(2, 1, 6), 124, twoRows), 2, { 1, 12 },
  "Cmd+Right on a wrapped row reached past the row it started on")
assertCaretMove(runCaretMove(caretAt(2, 1, 12), 123, twoRows), 2, { 1, 1 },
  "Cmd+Left missed the wrapped-row start from a bare past-edge caret")

for _, case in ipairs({
  { caretAt(1, 1, 12), oneRow },
  { caretAt(2, 1, 12), twoRows },
}) do
  local edge = runSpan(case[1], 124, case[2])
  assert(#edge.mouseEvents() == 0,
    "Cmd+Shift+Right selected from a caret past the row edge")
  assert(table.concat(edge.actions, ",") == "scrape",
    "Cmd+Shift+Right from past the row edge emitted a keystroke")
end

integration = integrationContext(nil, {
  windowFrame = terminalFrame,
  verdict = "claude",
  caretCalibrationNeeded = true,
})
assert(module.handleEvent(keyEvent(123, { "cmd", "fn" }, false, "cmd-arrow")),
  "the unresolvable Cmd+Left was not consumed")
integration.runDeferred()
integration.deliverScrape(oneRow)
assert(#integration.mouseEvents() == 0 and table.concat(integration.actions, ",") == "scrape",
  "an unresolvable Cmd+Left emitted a sentinel or click")

for _, keyCode in ipairs({ 123, 124 }) do
  local emptySpan = runSpan(caretAt(2, 2, 1), keyCode,
    gestureScreen("hello", cursorCell))
  assert(#emptySpan.mouseEvents() == 0,
    "a row span from an empty final row clicked another row")
  assert(table.concat(emptySpan.actions, ",") == "scrape",
    "a row span from an empty final row was not consumed cleanly")

  local emptyMove = runCaretMove(caretAt(2, 2, 1), keyCode,
    gestureScreen("hello", cursorCell))
  assert(#emptyMove.mouseEvents() == 0,
    "a caret move from an empty final row clicked another row")
  assert(table.concat(emptyMove.actions, ",") == "scrape",
    "a caret move from an empty final row was not consumed cleanly")
end

-- Two presses that land on one cell (here: a caret point the first click did not move)
-- need a breaker press between them, or the TUI reads the pair as the double click that
-- selects a word.
local repeatContext = integrationContext(nil, caretOpts(caretAt(1, 1, 7)))
for _ = 1, 2 do
  assert(module.handleEvent(keyEvent(123, { "cmd", "fn" }, false, "cmd-arrow")),
    "the repeated Cmd+Left was not consumed")
  repeatContext.runDeferred()
  repeatContext.deliverScrape(oneRow)
end
local repeated = repeatContext.mouseEvents()
local targetX = expectedPoint(1, 1, 1, -0.5)
assert(#repeated == 6, "a repeated caret move let two presses land on one cell")
assert(math.abs(repeated[3].x - targetX) >= 0.001, "the breaker pressed the target cell")
assert(math.abs(repeated[5].x - targetX) < 0.001,
  "the press after the breaker missed the row start")

-- The series the breaker breaks is measured in time too: a second later the TUI has
-- forgotten the press, and a breaker would only park the visible caret off the target.
local coldContext = integrationContext(nil, caretOpts(caretAt(1, 1, 7)))
for index = 1, 2 do
  assert(module.handleEvent(keyEvent(123, { "cmd", "fn" }, false, "cmd-arrow")),
    "the repeated Cmd+Left was not consumed")
  coldContext.runDeferred()
  coldContext.deliverScrape(oneRow)
  if index == 1 then coldContext.advance(1) end
end
assert(#coldContext.mouseEvents() == 4,
  "a caret move a second on still broke a click series the TUI had dropped")

-- The user's own hand opens a series the same way, and a gesture landing in it inherits
-- the promotion — but only while it is still warm.
integration = integrationContext(nil, gestureOpts)
simulateClick()
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11, breaker = true },
  "a gesture on the heels of the user's own click did not break their series")
integration = integrationContext(nil, gestureOpts)
simulateClick()
integration.advance(1)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "a gesture a second after the user's click broke a series that had gone cold")

-- A caret move lands in that series too, and its one click would be the second on a cell
-- the user just pressed.
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 7)))
module.handleEvent(mouseEvent(1))
assert(module.handleEvent(keyEvent(123, { "cmd", "fn" }, false, "cmd-arrow")),
  "the bare Cmd+Left was not consumed")
integration.runDeferred()
integration.deliverScrape(oneRow)
assert(#integration.mouseEvents() == 4,
  "a caret move inside the user's own click series did not break it")
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 7)))
module.handleEvent(mouseEvent(1))
integration.advance(1)
assert(module.handleEvent(keyEvent(123, { "cmd", "fn" }, false, "cmd-arrow")),
  "the bare Cmd+Left was not consumed")
integration.runDeferred()
integration.deliverScrape(oneRow)
assert(#integration.mouseEvents() == 2,
  "a caret move broke a click series the user had let go cold")

-- Clamped against the box's left edge the breaker can land on the cell a click of ours
-- took a moment ago and count as its second: every press it could join comes before the
-- pre-click it is also kept away from.
local steerRow = gestureScreen("abcdefg hijk")
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 3)))
assert(module.handleEvent(keyEvent(123, { "cmd", "fn" }, false, "cmd-arrow")),
  "the bare Cmd+Left was not consumed")
integration.runDeferred()
integration.deliverScrape(steerRow)
integration.setCaret(caretAt(1, 1, 9))
module.handleEvent(mouseEvent(1))
pressGesture(integration, 124)
integration.deliverScrape(steerRow)
local steered = integration.mouseEvents()
assert(#steered == 9, "the gesture after the user's press did not lead its paint with two clicks")
for _, press in ipairs({ steered[1], steered[7] }) do
  assert(math.abs(steered[3].x - press.x) > 1.5 * cellWidth,
    "the breaker landed close enough to a press to join the series it was breaking")
end

-- A row filled to the last column has no free cell past it; the click clamps inside the
-- box rather than falling off it, and the caret lands on that buffer position.
local fullRow = string.rep("x", screenColumns - promptCells)
assertCaretMove(runCaretMove(caretAt(1, 1, 2), 124, gestureScreen(fullRow)), 1,
  { 1, screenColumns - promptCells }, "Cmd+Right on a hard-full row clicked outside the box")
-- No free column past that row's head, and the last ones render a row down anyway: the
-- caret parks on the head's own column, exactly where bare Cmd+Right leaves it.
assertSpan(runSpan(caretAt(1, 1, 4), 124, gestureScreen(fullRow)), 1, { 1, 4 },
  { 1, screenColumns - promptCells },
  "Cmd+Shift+Right on a hard-full row clicked outside the box", nil,
  { 1, screenColumns - promptCells })

-- The caret already sits on the edge it is asked to reach: a span of no cells would
-- paint the press's own cell instead of nothing.
for _, keyCode in ipairs({ 123, 126 }) do
  local edge = runSpan(caretAt(1, 1, 1), keyCode, oneRow)
  assert(#edge.mouseEvents() == 0, "a zero-length span clicked")
  assert(table.concat(edge.actions, ",") == "scrape", "a zero-length span acted")
end

-- Plain Shift+Left/Right: the TUI extends a selection it already paints but starts none
-- from a bare caret, so the first character is painted the way the spans above are.
-- Scoped so the locals below stay off this chunk's own 200-local ceiling.
do
local function charSpanPress(keyCode)
  return keyEvent(keyCode, { "shift", "fn" }, false, "shift-arrow")
end
local function runChar(point, keyCode, screen)
  integration = integrationContext(nil, caretOpts(point))
  assert(module.handleEvent(charSpanPress(keyCode)), "the Shift+arrow was not consumed")
  integration.runDeferred()
  integration.deliverScrape(screen)
  return integration
end

-- Two cells are painted and the TUI's own Shift+arrow takes the overshot one back: the
-- one cell that is left keeps the head on the side the chord ran towards.
local charLeft = runChar(caretAt(1, 1, 7), 123, oneRow)
assertSpan(charLeft, 1, { 1, 6 }, { 1, 5 },
  "Shift+Left did not select the cell behind the caret", "scrape,chord:shift+right")
assertSpan(runChar(caretAt(1, 1, 7), 124, oneRow), 1, { 1, 7 }, { 1, 8 },
  "Shift+Right did not select the cell the caret sits on", "scrape,chord:shift+left", false)

-- Against the row's own edge there is no cell to overshoot onto: the drag goes to the
-- column beside it, the TUI clamps it back to that edge, and nothing needs shrinking.
assertSpan(runChar(caretAt(1, 1, 2), 123, oneRow), 1, { 1, 1 }, { 1, 0 },
  "Shift+Left at the second cell overshot past the row start")
assertSpan(runChar(caretAt(1, 1, 11), 124, oneRow), 1, { 1, 11 }, { 1, 12 },
  "Shift+Right on the last cell overshot past the row end", nil, false)

-- Our own shrink keystroke comes back through the tap it was posted from; the replay
-- marker is what keeps it out of the branch that painted it.
local marked = charSpanPress(124)
marked.properties[91] = module.replayMarker
assert(not module.handleEvent(marked), "the marked shrink keystroke was answered as the user's")
assert(#charLeft.mouseEvents() == 3, "the marked shrink keystroke painted a span of its own")

-- The cell it painted is the TUI's own selection now: the next press is its to extend.
local painted = #charLeft.mouseEvents()
assert(not module.handleEvent(charSpanPress(123)),
  "the Shift+Left after a painted cell was consumed instead of extending it")
assert(#charLeft.mouseEvents() == painted,
  "the passed-through Shift+Left painted a cell of its own")

-- Nowhere to grow: the neighbouring index is off the draft, or across the wrap and on
-- another row, which a selection painted here may not cross.
for _, case in ipairs({
  { caretAt(1, 1, 1), 123, oneRow, "left at the draft start" },
  { caretAt(1, 1, 12), 124, gestureScreen(hello .. cursorCell), "right at the draft end" },
  { caretAt(2, 2, 1), 123, twoRows, "left at a wrapped row's start" },
  { caretAt(2, 1, 12), 124, twoRows, "right at a wrapped row's end" },
}) do
  local edge = runChar(case[1], case[2], case[3])
  assert(#edge.mouseEvents() == 0, "Shift+arrow " .. case[4] .. " clicked")
  assert(table.concat(edge.actions, ",") == "scrape",
    "Shift+arrow " .. case[4] .. " emitted a keystroke of its own")
end

-- A selection any of these chords armed is the TUI's to extend from here, and the flag
-- has to survive the press or the Cmd+X behind it takes the bare-DEL path.
local rowSpan = runSpan(caretAt(1, 1, 7), 123, oneRow)
local rowPainted = #rowSpan.mouseEvents()
assert(not module.handleEvent(charSpanPress(123)),
  "Shift+Left over an armed row span was consumed")
assert(#rowSpan.mouseEvents() == rowPainted, "Shift+Left repainted an armed row span")
assert(module.handleEvent(xPress(false)), "Cmd+X after the passed-through Shift+Left was dropped")
rowSpan.resolve("claude")
rowSpan.runDeferred()
assert(rowSpan.actions[#rowSpan.actions] == "scrape",
  "Shift+Left disarmed the selection the row span had painted")

-- A bare arrow collapses one of our selections onto the edge macOS collapses to, which
-- the TUI's own caret has no idea about: it never moved with the drag that painted it.
local function bareArrow(keyCode)
  return keyEvent(keyCode, { "fn" }, false, "arrow")
end
local function collapseClick(context, keyCode, screen, rows, at, message)
  local before = #context.mouseEvents()
  assert(module.handleEvent(bareArrow(keyCode)), message .. ": the bare arrow was not consumed")
  context.runDeferred()
  context.deliverScrape(screen)
  local events = context.mouseEvents()
  -- Two events, or four when the collapse lands where the paint's own press did and owes
  -- the breaker that keeps the TUI from reading the pair as a double click.
  assert(#events - before == 2 or #events - before == 4,
    message .. ": the collapse did not click exactly once")
  local press = events[#events - 1]
  assert(press.kind == "down" and events[#events].kind == "up" and press.clickState == 1,
    message .. ": the collapse was not a plain click")
  local x, y = expectedPoint(rows, at[1], at[2], -0.5)
  assert(math.abs(press.x - x) < 0.001 and math.abs(press.y - y) < 0.001,
    message .. ": the collapse click missed its cell")
end
local function assertNoCollapse(context, keyCode, message)
  local before = #context.mouseEvents()
  assert(not module.handleEvent(bareArrow(keyCode)), message .. ": the bare arrow was consumed")
  assert(#context.mouseEvents() == before, message .. ": the bare arrow clicked")
end

-- Shift+Left at |7 paints cell 6, so the ends are |6 and |7.
runChar(caretAt(1, 1, 7), 123, oneRow)
collapseClick(integration, 123, oneRow, 1, { 1, 6 }, "left after a one-cell paint")
runChar(caretAt(1, 1, 7), 123, oneRow)
collapseClick(integration, 124, oneRow, 1, { 1, 7 }, "right after a one-cell paint")
runChar(caretAt(1, 1, 7), 124, oneRow)
collapseClick(integration, 123, oneRow, 1, { 1, 7 }, "left after a paint to the right")
runChar(caretAt(1, 1, 7), 124, oneRow)
collapseClick(integration, 124, oneRow, 1, { 1, 8 }, "right after a paint to the right")

-- Every native Shift+arrow we pass through moves the head with it, and the collapse has
-- to follow it there; the far end stays where the press anchored it.
runChar(caretAt(1, 1, 7), 123, oneRow)
for _ = 1, 2 do
  assert(not module.handleEvent(charSpanPress(123)), "a native Shift+Left was consumed")
end
collapseClick(integration, 124, oneRow, 1, { 1, 7 }, "right after two native Shift+Lefts")
runChar(caretAt(1, 1, 7), 123, oneRow)
for _ = 1, 2 do
  assert(not module.handleEvent(charSpanPress(123)), "a native Shift+Left was consumed")
end
collapseClick(integration, 123, oneRow, 1, { 1, 4 }, "left after two native Shift+Lefts")

-- The head cannot walk off the draft either way: the first cell one side, the free
-- column past the last cell the other, which is where a click lands the caret at the end.
runChar(caretAt(1, 1, 7), 123, oneRow)
for _ = 1, 10 do
  assert(not module.handleEvent(charSpanPress(123)), "a native Shift+Left was consumed")
end
collapseClick(integration, 123, oneRow, 1, { 1, 1 }, "left with the head held at the draft start")
runChar(caretAt(1, 1, 7), 124, oneRow)
for _ = 1, 10 do
  assert(not module.handleEvent(charSpanPress(124)), "a native Shift+Right was consumed")
end
collapseClick(integration, 124, oneRow, 1, { 1, 12 }, "right with the head held past the draft")

-- A word gesture and its extension track the same way: the anchor is the far end of the
-- word the press took, the head the end the direction ran to.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
collapseClick(integration, 123, gestureScreen(hello), 1, { 1, 7 }, "left after a word gesture")
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
collapseClick(integration, 124, gestureScreen(hello), 1, { 1, 12 }, "right after a word gesture")
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
extendGesture(integration, 123, gestureScreen(hello))
collapseClick(integration, 123, gestureScreen(hello), 1, { 1, 1 },
  "left after a word gesture extended")

-- Only what this module painted is tracked closely enough to aim a click at: a hand on
-- the mouse and a selection key outside the model both hand the arrow back to the TUI.
runChar(caretAt(1, 1, 7), 123, oneRow)
module.handleEvent(mouseEvent(1))
assertNoCollapse(integration, 123, "with the user's hand still down on the mouse")
runChar(caretAt(1, 1, 7), 123, oneRow)
simulateDrag()
assertNoCollapse(integration, 123, "over a selection the user painted by hand")
runChar(caretAt(1, 1, 7), 123, oneRow)
assert(not module.handleEvent(keyEvent(126, { "shift", "fn" }, false, "shift-up")),
  "Shift+Up was consumed")
assertNoCollapse(integration, 123, "after Shift+Up moved the selection out of our model")
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 7)))
simulateDrag()
assertNoCollapse(integration, 124, "over a selection nobody tracked")

-- A last row's free column is a cell the caret can hold and the collapse takes it; where
-- the row wraps that column renders a row down, so the collapse clamps onto the last cell
-- of the row the boundary ends, never the next row's first.
local bandText = string.rep("a", screenColumns - promptCells - 2)
local bandScreen = gestureScreen(bandText)
runChar(caretAt(1, 1, #bandText), 124, bandScreen)
collapseClick(integration, 124, bandScreen, 1, { 1, #bandText + 1 },
  "the collapse past the last row's end")
local wrappedBand = gestureScreen(bandText, "tail")
runChar(caretAt(2, 1, #bandText), 124, wrappedBand)
collapseClick(integration, 124, wrappedBand, 2, { 1, #bandText },
  "the collapse past an edge-filled wrapped row")

-- The user's own press opens a click series any paint can land in, not just a word
-- gesture's: pressing the cell they just clicked would be read as a double click.
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 7)))
module.handleEvent(mouseEvent(1))
assert(module.handleEvent(charSpanPress(123)), "the Shift+arrow was not consumed")
integration.runDeferred()
integration.deliverScrape(oneRow)
assert(#integration.mouseEvents() == 5,
  "a char paint inside the user's own click series did not break it")
integration = integrationContext(nil, caretOpts(caretAt(1, 1, 7)))
module.handleEvent(mouseEvent(1))
integration.advance(1)
assert(module.handleEvent(charSpanPress(123)), "the Shift+arrow was not consumed")
integration.runDeferred()
integration.deliverScrape(oneRow)
assert(#integration.mouseEvents() == 3,
  "a char paint broke a click series the user had let go cold")

-- Shrunk back onto its anchor the selection is gone: the tracking goes with it, or the
-- next chord is passed to a caret that has nothing to extend.
runChar(caretAt(1, 1, 7), 123, oneRow)
assert(not module.handleEvent(charSpanPress(124)), "the native Shift+Right was consumed")
assert(module.handleEvent(charSpanPress(123)),
  "the chord after a selection shrank to nothing was passed on instead of painting")
integration.runDeferred()
integration.deliverScrape(oneRow)
assert(#integration.mouseEvents() == 8, "the chord after the shrink painted nothing")

-- A collapse that cannot read the screen clicks nothing, so the selection it was aimed at
-- is still painted: the tracking comes back and the next arrow tries again.
runChar(caretAt(1, 1, 7), 123, oneRow)
local painted = #integration.mouseEvents()
assert(module.handleEvent(bareArrow(123)), "the bare arrow was not consumed")
integration.runDeferred()
integration.deliverScrape("nothing to read here")
assert(#integration.mouseEvents() == painted, "the unreadable collapse clicked anyway")
collapseClick(integration, 123, oneRow, 1, { 1, 6 },
  "the collapse retried after an unreadable screen")

-- The user typed into the draft while that scrape was out: their key cleared the selection
-- the collapse was aimed at, so nothing comes back and the next arrow is the TUI's own.
runChar(caretAt(1, 1, 7), 123, oneRow)
assert(module.handleEvent(bareArrow(123)), "the bare arrow was not consumed")
integration.runDeferred()
assert(not module.handleEvent(charPress("Z")), "the character typed mid-collapse was consumed")
integration.deliverScrape(oneRow)
assertNoCollapse(integration, 123, "after the user typed into the draft mid-collapse")

-- An extension with no word left to take clicks nothing, so the selection it was arming
-- from is still painted and the arrow after it still has ends to collapse onto.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
extendGesture(integration, 123, gestureScreen(hello))
extendGesture(integration, 123, gestureScreen(hello))
collapseClick(integration, 123, gestureScreen(hello), 1, { 1, 1 },
  "left after an extension that ran out of words")

-- A native Shift+arrow moves the head the word cache still names, so the cache goes with
-- it: the next chord starts its own selection instead of reaching from an end that moved.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assert(not module.handleEvent(charSpanPress(124)), "the native Shift+Right was consumed")
local afterShift = #integration.actions
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assert(integration.actions[afterShift + 1] == "sentinel",
  "the word chord after a native Shift+arrow extended the cache that key had moved")
end

integration = integrationContext(textTypes, caretOpts(caretAt(1, 1, 30)))
pressGesture(integration, 123)
assert(not module.handleEvent(charPress("Z")),
  "a character typed during the caret scrape was consumed")
integration.deliverScrape(gestureScreen(hello))
assert(table.concat(integration.actions, ",") == "scrape",
  "a touched draft with an unplaceable caret typed a sentinel")
assert(#integration.mouseEvents() == 0,
  "a touched draft with an unplaceable caret clicked")
assert(not integration.fireGestureWatchdog(),
  "a touched draft with an unplaceable caret left its flight armed")
end

-- `claude-keys off` then `on` is what gets pressed when the anchored grid looks wrong,
-- so a breaker left by one slow walk must not survive it and keep that path down for
-- another minute of the session it was restarted to fix.
do
local restartClock = 900
local restartWalks = 0
local function restartTick() return restartClock end
local function restartSlowWalk()
  restartWalks = restartWalks + 1
  restartClock = restartClock + 0.3
  return anchorCell, 1
end
local function restartWalk()
  restartWalks = restartWalks + 1
  return anchorCell, 1
end
integration = integrationContext(nil, gestureOpts)
module.axAnchorReset()
module.axAnchor(7, 34, 96, nil, restartSlowWalk, restartTick)
assert(module.axAnchor(7, 34, 96, nil, restartWalk, restartTick) == nil and restartWalks == 1,
  "the fixture did not trip the AX circuit breaker")
module.stop()
assert(module.axAnchor(7, 34, 96, nil, restartWalk, restartTick) == anchorCell
    and restartWalks == 2,
  "a restart left the AX circuit breaker standing")

-- The scroll area lives under the same restart: an area cached from before the stop
-- describes a window the restart was pressed because nobody trusts any more.
local restartArea = { "area" }
local function restartScrollWalk()
  restartWalks = restartWalks + 1
  return restartArea, nil
end
module.axScroll(7, nil, restartScrollWalk, restartTick)
assert(restartWalks == 3, "the scroll-area fixture did not walk")
module.axScroll(7, nil, restartScrollWalk, restartTick)
assert(restartWalks == 3, "the scroll-area cache was not primed for the restart check")
module.stop()
module.axScroll(7, nil, restartScrollWalk, restartTick)
assert(restartWalks == 4, "a restart kept the scroll area cached from before it")
end

-- The user's own hand on the mouse inside the sentinel window moves the caret or
-- paints a selection, and the DEL still owed for the sentinel would take that.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
simulateDrag()
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(table.concat(integration.actions, ",") == "sentinel,scrape",
  "the sentinel DEL landed on the selection the user had painted over it")

-- Uncertain is not Claude: swallowing the chord is safe wherever the tab may be
-- Claude's, but the sentinel would be typed into whatever else reads that tty.
integration = integrationContext(nil, { windowFrame = terminalFrame })
assert(module.handleEvent(optionShiftPress(123)),
  "the chord was not swallowed while the verdict was unresolved")
integration.runDeferred()
assert(#integration.actions == 0,
  "an unresolved verdict typed the gesture's sentinel into the tab")

-- Every swallow that runs no gesture leaves the draft exactly as it was, so the TUI
-- selection is still painted: the state the press cleared on its way in has to come
-- back with it, or the next chord restarts from the cursor and the next Cmd+X no-ops.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assert(module.handleEvent(optionShiftPress(126)), "Option+Shift+Up was not swallowed")
integration.runDeferred()
assert(#gestureClicks(integration) == 1, "a vertical arrow ran a gesture")
settled = #integration.actions
assert(module.handleEvent(xPress(false)), "Cmd+X after a swallowed arrow was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == settled + 1,
  "a swallowed vertical arrow disarmed the selection it had left painted")
integration.deliverScrape(gestureScreen(hello))
integration.fireCutTimer()
integration.deliverScrape(gestureScreen(""))
assert(integration.wrote() == "hello world",
  "Cmd+X did not cut the selection a swallowed arrow had left painted")

integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assert(module.handleEvent(optionShiftPress(125)), "Option+Shift+Down was not swallowed")
integration.runDeferred()
pressGesture(integration, 123)
assert(integration.actions[#integration.actions] == "scrape",
  "a swallowed vertical arrow dropped the gesture cache")
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 2, { from = 1, to = 11, breaker = true },
  "the chord after a swallowed arrow did not extend the selection it had left painted")

-- The same swallow on an unresolved verdict: the chord is eaten to keep the escape
-- sequence off a tab that may be Claude's, and eating it must cost no more than that.
do
local shiftingOpts = { windowFrame = terminalFrame, verdict = "claude" }
integration = integrationContext(nil, shiftingOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
shiftingOpts.verdict = "uncertain"
assert(module.handleEvent(optionShiftPress(123)),
  "the chord was not swallowed while the verdict was unresolved")
integration.runDeferred()
assert(#gestureClicks(integration) == 1, "an unresolved verdict ran a gesture")
shiftingOpts.verdict = "claude"
pressGesture(integration, 123)
assert(integration.actions[#integration.actions] == "scrape",
  "a chord swallowed on an unresolved verdict dropped the gesture cache")
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 2, { from = 1, to = 11, breaker = true },
  "the chord after an unresolved verdict did not extend the selection it had left")
end

-- The extension found its word and could not place a click on it: nothing reached the
-- draft, so that bail owes the same restoration as the two beside it.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
integration.dropWindowFrame()
extendGesture(integration, 123, gestureScreen(hello))
assert(#gestureClicks(integration) == 1, "an extension with no usable frame clicked")
settled = #integration.actions
assert(module.handleEvent(xPress(false)),
  "Cmd+X after an unplaceable extension was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == settled + 1,
  "an extension that could not place its click disarmed the painted selection")

-- An extension owes no sentinel, but its scrape is still out: a click or a keystroke
-- of the user's arriving inside that window is what the choreography below would paint
-- over, and the cached selection it would otherwise restore died with their action.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
pressGesture(integration, 123)
simulateDrag()
integration.deliverScrape(gestureScreen(hello))
assert(#gestureClicks(integration) == 1,
  "an extension clicked over the selection the user had just painted")
pressGesture(integration, 123)
assert(integration.actions[#integration.actions] == "sentinel",
  "the bailed extension put its cached selection back over the user's own")

integration = integrationContext(textTypes, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
pressGesture(integration, 123)
assert(not module.handleEvent(charPress("Z")),
  "a character typed during an extension scrape was consumed")
integration.deliverScrape(gestureScreen(hello))
assert(#gestureClicks(integration) == 1,
  "an extension clicked over the character the user had just typed")

-- Return is the one key mid-flight that cannot be traded for a sentinel left in the
-- draft: it SUBMITS that draft, and no keystroke reaches a sent message. The physical
-- event would outrun any DEL we post, so it is consumed and re-posted behind one.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
assert(module.handleEvent(returnPress()), "Return mid-gesture was not consumed")
assert(table.concat(integration.actions, ",") == "sentinel,cut,replay",
  "Return submitted the draft with the gesture's sentinel still in it")
assert(integration.replayed() == "return", "the Return was not the key posted back")
assert(integration.fireTimer(0.02), "the gesture armed no scrape timer to begin with")
assert(table.concat(integration.actions, ",") == "sentinel,cut,replay",
  "the gesture kept scraping a draft that had already been submitted")
assert(#integration.mouseEvents() == 0, "the gesture clicked into a submitted draft")

-- The draft it was typed into is gone: posted now the Return would submit whatever
-- took its place, so it is consumed and dropped.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.changeTarget()
assert(module.handleEvent(returnPress()), "Return mid-gesture was not consumed")
assert(table.concat(integration.actions, ",") == "sentinel,policy-drop",
  "a Return whose draft had gone was posted into the window that replaced it")

-- The keypad's Enter submits the same draft through a keyCode of its own, so it owes
-- the same removal first — and the same drop when the draft it was typed into is gone.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
assert(module.handleEvent(keypadReturnPress()), "keypad Enter mid-gesture was not consumed")
assert(table.concat(integration.actions, ",") == "sentinel,cut,replay",
  "keypad Enter submitted the draft with the gesture's sentinel still in it")
assert(integration.replayed() == "keypad-return",
  "the keypad Enter was not the key posted back")

integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.changeTarget()
assert(module.handleEvent(keypadReturnPress()), "keypad Enter mid-gesture was not consumed")
assert(table.concat(integration.actions, ",") == "sentinel,policy-drop",
  "a keypad Enter whose draft had gone was posted into the window that replaced it")

-- The removal stands down when the user's own character reached the draft first, and
-- the sentinel then stays in it: reposting the Return here sends a message carrying a
-- character no keystroke can ever take back out.
for _, submit in ipairs({ returnPress, keypadReturnPress }) do
  integration = integrationContext(textTypes, gestureOpts)
  pressGesture(integration, 123)
  assert(not module.handleEvent(charPress("Z")), "a character typed mid-gesture was consumed")
  assert(module.handleEvent(submit()), "the submit key mid-gesture was not consumed")
  assert(table.concat(integration.actions, ",") == "sentinel,policy-drop",
    "a draft still holding the sentinel was submitted anyway")
end

-- Outside that window Return is the user's own key and reaches the terminal itself:
-- an extension owes no DEL, and neither does an idle tab.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assert(not module.handleEvent(returnPress()),
  "Return was consumed with no sentinel owed for it")
assert(not module.handleEvent(returnPress()), "a second Return was consumed as well")
assert(not module.handleEvent(keypadReturnPress()),
  "keypad Enter was consumed with no sentinel owed for it")

-- A pasted no-break space is a space wherever it lands, not a word character that
-- merely happens to be multibyte: classed by width, the words on either side of it
-- merge and one press selects both.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("foo\194\160bar" .. sentinel),
  gestureScreen("foo\194\160bar"))
assertWordClick(integration, 1, { from = 5, to = 7 },
  "a word gesture reached across a no-break space")
extendGesture(integration, 123, gestureScreen("foo\194\160bar"))
assertWordClick(integration, 2, { from = 1, to = 7, breaker = true },
  "the extension did not step over the no-break space to the word before it")

-- Every multibyte cell used to read as a word character, which makes an em dash — the
-- punctuation every LLM answer is full of — a letter joining the words it separates.
do
local emDash = "\226\128\148"
assert(cellLen(emDash) == 1 and #emDash > 1, "the em dash fixture is not one wide cell")
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("foo" .. emDash .. "bar" .. sentinel),
  gestureScreen("foo" .. emDash .. "bar"))
assertWordClick(integration, 1, { from = 5, to = 7 },
  "a word gesture reached across an em dash")
extendGesture(integration, 123, gestureScreen("foo" .. emDash .. "bar"))
assertWordClick(integration, 2, { from = 1, to = 7, breaker = true },
  "the extension did not step over the em dash to the word before it")
end

-- A curly quote is the same trap at the other end of the same block: it has to end the
-- word it hugs, exactly as the straight quote the TUI cuts at already does.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen("foo\226\128\153" .. sentinel),
  gestureScreen("foo\226\128\153"))
assertWordClick(integration, 1, { from = 1, to = 3 },
  "a word gesture swallowed the curly quote hugging its word")

-- The sentinel itself is multibyte and sits above this block: classing it as a space
-- would drop it off the end of every scrape before it could ever be found.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the sentinel stopped reading as a cell of its own")

-- The rest of the draft rewrites: an undo and a convert go out as their own
-- keystrokes, and a native text paste never reaches the action layer at all.
integration = integrationContext(nil, gestureOpts)
pressGesture(integration, 123)
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(module.handleEvent(zPress(false)), "Cmd+Z mid-gesture was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut",
  "Cmd+Z undid into the draft the gesture's sentinel DEL was aimed at")
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the gesture did not finish past a mid-flight Cmd+Z")

integration = integrationContext(nil, gestureOpts)
assert(module.handleEvent(zPress(false)), "Cmd+Z was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[#integration.actions] == "undo",
  "Cmd+Z outside the gesture window stopped undoing")

integration = integrationContext({ "public.file-url" },
  { windowFrame = terminalFrame, verdict = "claude", url = "file:///tmp/pic.png" })
pressGesture(integration, 123)
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(module.handleEvent(vPress(false)), "a convert mid-gesture was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut",
  "a convert rewrote the draft the gesture's sentinel DEL was aimed at")

integration = integrationContext(textTypes, gestureOpts)
pressGesture(integration, 123)
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(module.handleEvent(vPress(false)), "a native text paste mid-gesture was let through")
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut",
  "a native text paste mid-gesture reached the draft")

integration = integrationContext(textTypes, gestureOpts)
assert(not module.handleEvent(vPress(false)),
  "a native text paste outside the gesture window stopped passing to the terminal")

-- An image paste is a draft rewrite like the rest: its placeholder lands ahead of the
-- sentinel DEL, which then eats the placeholder's last character. A chord costs one
-- re-press, so it is dropped rather than queued.
integration = integrationContext({ "public.png" }, gestureOpts)
pressGesture(integration, 123)
integration.fireTimer(0.02)
integration.deliverScrape(gestureScreen(hello .. sentinel))
assert(module.handleEvent(vPress(false)), "an image paste mid-gesture was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut",
  "an image paste rewrote the draft the gesture's sentinel DEL was aimed at")
integration.fireTimer(0.05)
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the gesture did not finish past a mid-flight image paste")

integration = integrationContext({ "public.png" }, gestureOpts)
assert(module.handleEvent(vPress(false)), "an image paste was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[#integration.actions] == "image-paste",
  "an image paste outside the gesture window stopped pasting")

-- Our own clicks drag the physical pointer onto the word they press. The warp back is
-- debounced, never inline: the window server handles those clicks after this runloop
-- turn, so a warp posted here is overtaken by its own up event. A burst re-arms the
-- settle timer per choreography and pays one warp once the presses stop, and the home
-- it warps to is read once — a second read would land on the last click point.
local pointerOpts = { windowFrame = terminalFrame, verdict = "claude",
  pointer = { x = 900, y = 50 } }
integration = integrationContext(nil, pointerOpts)
runGesture(integration, 123, gestureScreen(counted .. sentinel), gestureScreen(counted))
extendGesture(integration, 123, gestureScreen(counted))
assert(#integration.pointerWarps() == 0, "a choreography warped the pointer inline")
assert(integration.pointerReads() == 1, "the burst took a fresh pointer home per choreography")
assert(integration.firePointerSettle(), "no settle timer was armed to put the pointer back")
local warps = integration.pointerWarps()
assert(#warps == 1, "the burst did not pay exactly one warp")
assert(warps[1].x == 900 and warps[1].y == 50, "the warp did not go to the original home")
assert(integration.pointerAt().x == 900 and integration.pointerAt().y == 50,
  "the burst left the pointer somewhere other than where it started")

-- Home outlives its warp by an idle window, so a press that lands inside it reuses
-- the home instead of reading a pointer the warp may still be moving.
extendGesture(integration, 123, gestureScreen(counted))
assert(integration.pointerReads() == 1, "a press inside the idle window re-read the pointer")
assert(not integration.firePointerClear(), "the idle timer outlived the next choreography")
assert(integration.firePointerSettle(), "the next choreography did not re-arm the settle timer")
assert(#integration.pointerWarps() == 2 and integration.pointerWarps()[2].x == 900,
  "the press inside the idle window warped somewhere other than home")

-- Burst over for good: the next one is entitled to a home of its own.
assert(integration.firePointerClear(), "no idle timer was armed to drop the pointer home")
integration.movePointer({ x = 400, y = 300 })
extendGesture(integration, 123, gestureScreen(counted))
assert(integration.pointerReads() == 2, "the burst after the idle window reused the old home")
assert(integration.firePointerSettle(), "the burst after the idle window armed no settle timer")
assert(integration.pointerAt().x == 400 and integration.pointerAt().y == 300,
  "a burst after the idle window warped back to the home of the one before it")

-- The user's own hand on the mouse takes the pointer for good: a warp still pending
-- would drag it back out from under them. Ours carry the marker and must not count.
integration = integrationContext(nil, pointerOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
local ownDown = mouseEvent(1)
ownDown.properties[91] = module.replayMarker
module.handleEvent(ownDown)
assert(integration.firePointerSettle(), "a click of our own cancelled the pending warp")
assert(integration.pointerWarps()[1].x == 900, "a click of our own moved the pointer home")

integration = integrationContext(nil, pointerOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
module.handleEvent(mouseEvent(1))
assert(not integration.firePointerSettle(), "the user's own click left a warp pending")
assert(#integration.pointerWarps() == 0, "a warp fired after the user took the mouse")
integration.movePointer({ x = 400, y = 300 })
extendGesture(integration, 123, gestureScreen(hello))
assert(integration.firePointerSettle(), "the gesture after the user's click armed no settle timer")
assert(integration.pointerAt().x == 400 and integration.pointerAt().y == 300,
  "a gesture after the user took the mouse warped back to the home it had saved")

-- The trackpad needs no click, so a hand moving the pointer during the settle window
-- is only told apart from our own posted endpoint by this tolerance; the warp then
-- carries the hand's displacement on top of home instead of yanking the cursor.
assert(not module.pointerDrifted({ x = 100, y = 100 }, { x = 103, y = 100 }),
  "a move of exactly the tolerance counted as drift")
assert(module.pointerDrifted({ x = 100, y = 100 }, { x = 104, y = 100 }),
  "a move past the tolerance did not count as drift")
assert(module.pointerDrifted({ x = 100, y = 100 }, { x = 103, y = 103 }),
  "a diagonal move past the tolerance did not count as drift")
assert(not module.pointerDrifted({ x = 100, y = 100 }, { x = 102, y = 102 }),
  "a diagonal nudge inside the tolerance counted as drift")
assert(not module.pointerDrifted({ x = 100, y = 100 }, nil),
  "an unknown endpoint counted as drift and would cancel every warp")
assert(not module.pointerDrifted(nil, { x = 100, y = 100 }),
  "an unreadable pointer counted as drift")

integration = integrationContext(nil, pointerOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
do
  local hijacked = integration.mouseEvents()[#integration.mouseEvents()]
  integration.movePointer({ x = hijacked.x + 40, y = hijacked.y + 30 })
  assert(integration.firePointerSettle(), "no settle timer was armed")
  assert(integration.settleReads() == 1, "the settle warp never looked at where the pointer was")
  local carried = integration.pointerWarps()
  assert(#carried == 1, "a hand moving in the settle window skipped the warp and stranded the motion")
  assert(carried[1].x == 940 and carried[1].y == 80,
    "the warp did not re-apply the hand's displacement on top of home")
  assert(integration.pointerAt().x == 940 and integration.pointerAt().y == 80,
    "the pointer did not continue its motion from home")
  -- The carried displacement must survive into the burst's next warp: home itself
  -- moves, or the follow-up choreography would undo the hand's motion.
  extendGesture(integration, 123, gestureScreen(hello))
  assert(integration.firePointerSettle(),
    "the choreography after a carried warp armed no settle timer")
  assert(integration.pointerAt().x == 940 and integration.pointerAt().y == 80,
    "the next warp in the burst went to the stale home and undid the hand's motion")
end

-- Far past the carry limit the hand went somewhere deliberate: no warp, home dies.
integration = integrationContext(nil, pointerOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
do
  local hijacked = integration.mouseEvents()[#integration.mouseEvents()]
  integration.movePointer({ x = hijacked.x + 500, y = hijacked.y })
  assert(integration.firePointerSettle(), "no settle timer was armed")
  assert(#integration.pointerWarps() == 0,
    "a move far past the carry limit was still warped")
  integration.movePointer({ x = 410, y = 310 })
  extendGesture(integration, 123, gestureScreen(hello))
  assert(integration.pointerReads() == 2,
    "the choreography after a far move reused the dead home")
  assert(integration.firePointerSettle(),
    "the choreography after a far move armed no settle timer")
  assert(integration.pointerAt().x == 410 and integration.pointerAt().y == 310,
    "the warp went to the home the hand had already left")
end

-- Within the tolerance it is our own pointer, jitter and all: the warp still runs.
integration = integrationContext(nil, pointerOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
integration.movePointer({ x = integration.pointerAt().x + 2, y = integration.pointerAt().y })
assert(integration.firePointerSettle(), "no settle timer was armed")
assert(#integration.pointerWarps() == 1 and integration.pointerAt().x == 900,
  "a pointer within the tolerance was read as the user's and left where it was")

-- A queue waiting on the foreground verdict can still turn into a draft rewrite.
integration = integrationContext(nil, gestureOpts)
assert(module.handleEvent(cPress(false)), "Cmd+C was not queued for the verdict")
assert(module.handleEvent(optionShiftPress(123)), "the gesture behind a queue was not consumed")
integration.runDeferred()
assert(#integration.actions == 0 and #integration.mouseEvents() == 0,
  "the gesture ran while a resolution still held keys")

-- That bail leaves the painted selection alone, so the state the press cleared on its
-- way in has to come back with it or the next chord restarts from the cursor.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assert(module.handleEvent(cPress(false)), "Cmd+C was not queued for the verdict")
assert(module.handleEvent(optionShiftPress(123)), "the chord behind a queue was not consumed")
integration.runDeferred()
assert(#gestureClicks(integration) == 1, "the chord behind a queue ran a gesture")
integration.resolve("not-claude")
pressGesture(integration, 123)
assert(integration.actions[#integration.actions] == "scrape",
  "a chord bailed on a busy flow dropped the gesture cache")
integration.deliverScrape(gestureScreen(hello))
assertWordClick(integration, 2, { from = 1, to = 11, breaker = true },
  "the chord after a busy bail did not extend the selection it had left painted")

-- A gesture selection is the same armed selection a real drag leaves behind, so
-- everything downstream has to work on it untouched.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 124, gestureScreen(sentinel .. hello), gestureScreen(hello))
assert(module.handleEvent(xPress(false)), "Cmd+X after a word gesture was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[#integration.actions] == "scrape",
  "the gesture selection did not arm Cmd+X")
integration.deliverScrape(gestureScreen(hello))
integration.fireCutTimer()
integration.deliverScrape(gestureScreen(" world"))
assert(integration.wrote() == "hello", "Cmd+X did not cut the word the gesture selected")

integration = integrationContext(textTypes, gestureOpts)
runGesture(integration, 124, gestureScreen(sentinel .. hello), gestureScreen(hello))
assert(module.handleEvent(charPress("Z")), "a character typed over a word gesture was not consumed")
integration.resolve("claude")
integration.runDeferred()
integration.deliverScrape(gestureScreen(hello))
integration.timeout()
integration.deliverScrape(gestureScreen(" world"))
assert(integration.replayed() == "Z", "the typed character did not replace the gesture selection")

integration = integrationContext(nil, gestureOpts)
assert(module.handleEvent(optionShiftPress(126)), "Option+Shift+Up was not swallowed")
assert(module.handleEvent(optionShiftPress(125)), "Option+Shift+Down was not swallowed")
integration.runDeferred()
assert(#integration.actions == 0 and #integration.mouseEvents() == 0,
  "a vertical Option+Shift arrow started a gesture")

integration = integrationContext()
assert(module.handleEvent(optionShiftPress(123)), "Option+Shift+Left was not consumed in Terminal")
assert(#integration.actions == 0, "the gesture ran inside the event-tap callback")
assert(not module.handleEvent(keyEvent(123, { "alt" }, false, "alt-left")),
  "plain Option+Left was intercepted")
integration.switchApp("com.apple.Safari")
assert(not module.handleEvent(optionShiftPress(123)),
  "Option+Shift+Left was swallowed outside Terminal")

-- A shell tab has no draft to protect, so there the chord is the user's own.
integration = integrationContext(nil, { verdict = "not-claude" })
for _, keyCode in ipairs({ 123, 124, 125, 126 }) do
  assert(not module.handleEvent(optionShiftPress(keyCode)),
    "an Option+Shift arrow was swallowed in a non-Claude tab")
end
integration.runDeferred()
assert(#integration.actions == 0, "a non-Claude Option+Shift arrow started a gesture")

-- Terminal hardcodes Cmd+arrow to its own tab switch: what it spent them on moves to
-- Option+Cmd+Shift+arrow, the bare chord becomes the caret motion macOS types
-- everywhere else, and Cmd+Shift+arrow the selection it paints. Real arrow keys arrive
-- with the fn flag set, so every press below carries it.
-- Scoped: this chunk sits at the same 200-local ceiling the module does.
do
local function commandArrow(keyCode, modifiers, repeatDown)
  local labels = { [123] = "cmd-left", [124] = "cmd-right",
    [125] = "cmd-down", [126] = "cmd-up" }
  return keyEvent(keyCode, modifiers, repeatDown, labels[keyCode])
end
local reposts = { [123] = "chord:ctrl+shift+tab", [124] = "chord:ctrl+tab",
  [125] = "chord:cmd+down", [126] = "chord:cmd+up" }

for keyCode, chord in pairs(reposts) do
  integration = integrationContext(nil, { verdict = "not-claude" })
  assert(module.handleEvent(commandArrow(keyCode, { "cmd", "shift", "alt", "fn" })),
    "an Option+Cmd+Shift arrow was not swallowed in Terminal")
  assert(table.concat(integration.actions, ",") == chord,
    "an Option+Cmd+Shift arrow did not repost what Terminal spends the chord on")
end

-- The word gesture is the chord without cmd, and it must not answer for the switch.
integration = integrationContext(nil, { verdict = "claude" })
assert(module.handleEvent(commandArrow(123, { "cmd", "shift", "alt", "fn" })),
  "Option+Cmd+Shift+Left was not swallowed")
assert(table.concat(integration.actions, ",") == "chord:ctrl+shift+tab",
  "Option+Cmd+Shift+Left ran the word gesture instead of the tab switch")
integration.runDeferred()
assert(#integration.mouseEvents() == 0, "the moved tab switch clicked a word selection")

-- The row motions place the caret by click; where that click lands is measured against
-- the cell grid beside the selection chords. Here: one gesture per press, no bytes.
integration = integrationContext(nil, { verdict = "claude" })
assert(module.handleEvent(commandArrow(124, { "cmd", "fn" })),
  "Cmd+Right was not swallowed in a Claude tab")
assert(module.handleEvent(commandArrow(124, { "cmd", "fn" }, true)),
  "a held Cmd+Right leaked a native tab switch")
integration.runDeferred()
assert(#integration.actions == 0,
  "Cmd+Right without a resolvable caret emitted a keystroke")

integration = integrationContext(nil, { verdict = "claude" })
assert(module.handleEvent(commandArrow(123, { "cmd", "fn" })),
  "Cmd+Left was not swallowed in a Claude tab")
integration.runDeferred()
assert(#integration.actions == 0,
  "Cmd+Left without a resolvable caret emitted a keystroke")

-- An unresolved verdict swallows bare: the click would land in whatever else is in
-- front, and the context refreshes within 0.1s for the next press.
integration = integrationContext()
assert(module.handleEvent(commandArrow(124, { "cmd", "fn" })),
  "Cmd+Right on an unresolved verdict was not swallowed")
integration.runDeferred()
assert(#integration.actions == 0,
  "an unresolved Cmd+Right reached into a tab that may not be Claude's")
assert(module.handleEvent(commandArrow(126, { "cmd", "shift", "fn" })),
  "the selection chord on an unresolved verdict was not swallowed")
assert(#integration.actions == 0,
  "an unresolved selection chord clicked into a tab that may not be Claude's")
assert(module.handleEvent(commandArrow(123, { "cmd", "shift", "alt", "fn" })),
  "Option+Cmd+Shift+Left waited for a verdict it does not need")
assert(table.concat(integration.actions, ",") == "chord:ctrl+shift+tab",
  "the tab switch did not post on an unresolved verdict")

-- The native tab switch is what a shell tab keeps.
integration = integrationContext(nil, { verdict = "not-claude" })
assert(not module.handleEvent(commandArrow(124, { "cmd", "fn" })),
  "Cmd+Right was intercepted in a non-Claude tab")
assert(not module.handleEvent(commandArrow(123, { "cmd", "fn" })),
  "Cmd+Left was intercepted in a non-Claude tab")
assert(#integration.actions == 0, "a non-Claude Cmd+arrow posted a key of its own")

integration = integrationContext(nil, { verdict = "claude" })
assert(not module.handleEvent(commandArrow(123, { "cmd", "alt", "fn" })),
  "Option+Cmd+Left was intercepted")
assert(not module.handleEvent(commandArrow(123, { "fn" })), "a plain arrow was intercepted")
integration.switchApp("com.apple.Safari")
assert(not module.handleEvent(commandArrow(124, { "cmd", "shift", "fn" })),
  "Cmd+Shift+Right was swallowed outside Terminal")
assert(not module.handleEvent(commandArrow(124, { "cmd", "fn" })),
  "Cmd+Right was swallowed outside Terminal")
assert(#integration.actions == 0, "an arrow outside the remap posted a key")

-- A caret move ends the selection the TUI painted, exactly as typing does: the Cmd+X
-- behind it finds nothing to cut and leaves the draft alone.
integration = integrationContext(nil, { verdict = "claude" })
simulateDrag()
assert(module.handleEvent(commandArrow(123, { "cmd", "fn" })),
  "Cmd+Left was not swallowed over a selection")
pressCut(integration)
assert(#integration.actions == 0,
  "a caret move left the selection armed for the next cut")

-- Cmd+Up/Down carry the document motion; the mark scroll Terminal answers the bare
-- Cmd+arrow with is reposted from the Option+Cmd+Shift chord, in any tab.
integration = integrationContext(nil, { verdict = "claude" })
assert(module.handleEvent(commandArrow(126, { "cmd", "fn" })),
  "Cmd+Up was not swallowed in a Claude tab")
assert(module.handleEvent(commandArrow(126, { "cmd", "fn" }, true)),
  "a held Cmd+Up leaked a native scroll")
assert(table.concat(integration.actions, ",") == "doc-start",
  "Cmd+Up did not move the caret to the document start exactly once")

integration = integrationContext(nil, { verdict = "claude" })
assert(module.handleEvent(commandArrow(125, { "cmd", "fn" })),
  "Cmd+Down was not swallowed in a Claude tab")
assert(table.concat(integration.actions, ",") == "doc-end",
  "Cmd+Down did not move the caret to the document end")

integration = integrationContext()
assert(module.handleEvent(commandArrow(126, { "cmd", "fn" })),
  "Cmd+Up on an unresolved verdict was not swallowed")
assert(module.handleEvent(commandArrow(125, { "cmd", "fn" })),
  "Cmd+Down on an unresolved verdict was not swallowed")
assert(#integration.actions == 0,
  "an unresolved Cmd+Up/Down typed into a tab that may not be Claude's")

integration = integrationContext(nil, { verdict = "not-claude" })
assert(not module.handleEvent(commandArrow(126, { "cmd", "fn" })),
  "Cmd+Up was intercepted in a non-Claude tab")
assert(not module.handleEvent(commandArrow(125, { "cmd", "fn" })),
  "Cmd+Down was intercepted in a non-Claude tab")
assert(#integration.actions == 0, "a non-Claude Cmd+Up/Down posted a key of its own")

-- The cut owns the DEL-and-diff window a caret move would land in the middle of, and
-- the tab switch would carry the front tab out from under it.
integration = integrationContext(nil, { verdict = "claude" })
dragThenCut(integration)
assert(module.handleEvent(commandArrow(126, { "cmd", "fn" })),
  "the mid-cut Cmd+Up was not swallowed")
assert(module.handleEvent(commandArrow(123, { "cmd", "shift", "fn" })),
  "the mid-cut Cmd+Shift+Left was not swallowed")
integration.runDeferred()
assert(table.concat(integration.actions, ",") == "scrape",
  "a Cmd+arrow acted inside the cut's own window")

-- The whole run has to reach the tty as one keystroke: an Up arriving at the top line
-- on its own recalls history over the draft instead of stopping there.
assert(module.docStartPlan().atomic and module.docEndPlan().atomic,
  "a document motion was left to emit one byte at a time")
assert(module.planBytes(module.docStartPlan()):sub(-1) == string.char(1)
  and module.planBytes(module.docStartPlan()):find("\27%[A"),
  "the document-start plan does not walk up and then to the line start")
assert(module.planBytes(module.docEndPlan()):sub(-1) == string.char(5)
  and module.planBytes(module.docEndPlan()):find("\27%[B"),
  "the document-end plan does not walk down and then to the line end")

-- Only the document motions travel as bytes; the row edges are reached by click.
assert(not module.lineStartPlan and not module.lineEndPlan,
  "a byte plan for the row motions outlived the click that replaced it")
end

-- Self-posted keystrokes come back through our own tap. Every flow below holds a
-- window open around its own DEL, and each one used to close that window on the DEL
-- itself; the marker is the only thing that tells it from the user's typing.
integration = integrationContext(nil, gestureOpts)
runGesture(integration, 123, gestureScreen(hello .. sentinel), gestureScreen(hello))
assert(table.concat(integration.actions, ",") == "sentinel,scrape,cut,scrape",
  "the gesture read its own sentinel keystroke as a draft the user had typed into")
assertWordClick(integration, 1, { from = 7, to = 11 },
  "the gesture did not finish with its own keystrokes looping back through the tap")

integration = integrationContext(textTypes)
dragThenType(integration, "x")
integration.deliverScrape(screenDraft)
assert(integration.actions[#integration.actions] == "cut",
  "the replace flow intercepted its own DEL instead of letting it reach the draft")
integration.timeout()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "x",
  "the replace flow ended on its own DEL and swallowed the key it was holding")

integration = integrationContext()
dragThenCut(integration)
integration.deliverScrape(screenDraft)
integration.fireCutTimer()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "", "the cut queued its own DEL and replayed it afterwards")
assert(integration.wrote() == "brave ", "the cut did not read back the text its own DEL removed")

-- The opposite face of the same marker: a selection armed for the DEL we are about to
-- post must survive that post, and still die on a key the user presses.
integration = integrationContext()
simulateDrag()
module.handleEvent(selfPostedKeyEvent("\127", true))
module.handleEvent(selfPostedKeyEvent("\127", false))
assert(module.handleEvent(xPress(false)), "Cmd+X after a self-posted key was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(integration.actions[#integration.actions] == "scrape",
  "a keystroke of our own disarmed the selection through the tap")

integration = integrationContext()
simulateDrag()
assert(not module.handleEvent(arrowPress()), "a plain arrow was consumed")
assert(module.handleEvent(xPress(false)), "Cmd+X after an arrow was not consumed")
integration.resolve("claude")
integration.runDeferred()
assert(#integration.actions == 0, "a keystroke of the user's left the selection armed")

-- A paste consumed for a tab that moved before the verdict landed has nowhere safe to
-- go: the clipboard would land in whatever took its place.
integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(vPress(false)), "text Cmd+V over a selection was not consumed")
integration.changeTarget()
integration.resolve("claude")
assert(integration.replayed() == "", "a target-mismatched paste was replayed")
assert(#integration.actions == 1 and integration.actions[1] == "policy-drop",
  "a target-mismatched paste was not policy-dropped")

-- The character was replayed, not replaced, so the key is still just a key: its
-- repeats have to reach the terminal on their own.
integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(charPress("h")), "the pending character was not consumed")
integration.resolve("not-claude")
assert(integration.replayed() == "h", "a non-Claude character was not replayed")
assert(not module.handleEvent(charPress("h", 4, true)),
  "autorepeat stayed consumed after the character was replayed")

integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(charPress("h")), "the pending character was not consumed")
integration.changeTarget()
integration.resolve("claude")
assert(not module.handleEvent(charPress("h", 4, true)),
  "autorepeat stayed consumed after the character was dropped")

-- A shortcut resolved alongside a replace has to wait for it: the replace runs across
-- two scrapes and a timer, so anything dispatched beside it acts on the older draft.
integration = integrationContext(textTypes)
simulateDrag()
assert(module.handleEvent(charPress("h")), "the pending character was not consumed")
assert(module.handleEvent(cPress(false)), "Cmd+C was not queued behind the pending replace")
integration.resolve("claude")
assert(#integration.actions == 0, "Cmd+C ran before the replace it was pressed after")
integration.runDeferred()
integration.deliverScrape(screenDraft)
integration.timeout()
integration.deliverScrape(screenShorter)
assert(integration.replayed() == "h", "the replace lost the key it was holding")
assert(integration.actions[#integration.actions] == "copy",
  "Cmd+C behind the replace never ran")

local copy = module.copyChordPlan()
assert(#copy == 2, "copy chord length changed")
assert(module.planBytes(copy) == string.char(24, 25), "copy bytes changed")
local paste = module.imagePastePlan()
assert(#paste == 1, "image paste chord length changed")
assert(module.planBytes(paste) == string.char(22), "image paste byte changed")
local undo = module.undoPlan()
assert(#undo == 1, "undo chord length changed")
assert(module.planBytes(undo) == string.char(31), "undo byte changed")
local cut = module.cutPlan()
assert(#cut == 1, "cut plan length changed")
assert(module.planBytes(cut) == string.char(127), "cut byte changed")

-- Latency instrumentation. The recorder takes plain nanosecond numbers, so the ring,
-- the cold/warm split and the percentiles are driven with synthetic clocks; the tap
-- wrapper's own extraction is covered through latencyObserve with fake events.
local millisecond = 1000000
local second = 1000000000

local function latencyRowFor(rows, class, cold)
  for _, row in ipairs(rows) do
    if row.class == class and row.cold == cold then return row end
  end
  return nil
end

local function latencyEvent(eventType, rawFlags, stamp, marker)
  local event = {}
  function event:getType() return eventType end
  function event:rawFlags() return rawFlags end
  function event:timestamp() return stamp end
  function event:getProperty(property)
    assert(property == 91, "the tap read a property other than the replay marker")
    return marker or 0
  end
  return event
end

assert(module.latencyClassCode(10, 0, 0) == 40, "plain keyDown class code changed")
assert(module.latencyClassCode(10, 1 << 20, 0) == 42, "a Cmd chord was not classed as one")
assert(module.latencyClassCode(10, 1 << 19, 0) == 42, "an Option chord was not classed as one")
-- Shift and Control ride along with ordinary typing; classing them as chords would
-- hide every capital letter from the plain-typing bucket.
assert(module.latencyClassCode(10, 1 << 17, 0) == 40, "Shift was classed as a chord")
assert(module.latencyClassCode(10, 1 << 18, 0) == 40, "Control was classed as a chord")
assert(module.latencyClassCode(10, 0, module.replayMarker) == 41,
  "a replayed event was not classed as a replay")
assert(module.latencyClassCode(11, 0, 0) == 44, "keyUp shares a class code with keyDown")

module.latencyReset()
local percentileBase = 100 * second
module.latencyRecord(percentileBase, percentileBase, percentileBase, 40)
for index = 1, 100 do
  local entered = percentileBase + index * 10 * millisecond
  module.latencyRecord(entered, entered + index * millisecond, entered - index * millisecond, 40)
end
local percentileRows = module.latencyRows()
local warmKeys = latencyRowFor(percentileRows, "keyDown", false)
assert(warmKeys and warmKeys.count == 100, "the warm bucket lost events")
assert(warmKeys.queue.count == 100, "a plausible event timestamp was rejected")
-- Nearest rank over 1..100 ms: floor-based or interpolating percentiles land elsewhere.
assert(warmKeys.queue.p50 == 50 and warmKeys.queue.p90 == 90
  and warmKeys.queue.p99 == 99 and warmKeys.queue.max == 100,
  "queue percentiles are not nearest-rank over a known distribution")
assert(warmKeys.process.p50 == 50 and warmKeys.process.p90 == 90
  and warmKeys.process.p99 == 99 and warmKeys.process.max == 100,
  "processing percentiles are not nearest-rank over a known distribution")
local coldKeys = latencyRowFor(percentileRows, "keyDown", true)
assert(coldKeys and coldKeys.count == 1, "the first recorded event was not cold")
assert(percentileRows[#percentileRows].class == "ALL", "the totals row is not last")
assert(latencyRowFor(percentileRows, "ALL", false).count == 100, "the warm total lost events")

-- Seven samples put every percentile on a fractional rank, where nearest-rank and a
-- truncating rank disagree: the round hundred above cannot tell them apart.
module.latencyReset()
local oddBase = 150 * second
module.latencyRecord(oddBase, oddBase, oddBase, 40)
for index = 1, 7 do
  local entered = oddBase + index * 10 * millisecond
  module.latencyRecord(entered, entered + index * millisecond, entered - index * millisecond, 40)
end
local oddWarm = latencyRowFor(module.latencyRows(), "keyDown", false)
assert(oddWarm.count == 7 and oddWarm.process.p50 == 4 and oddWarm.process.p90 == 7
  and oddWarm.process.p99 == 7 and oddWarm.process.max == 7,
  "percentiles over seven samples are not nearest-rank")
assert(oddWarm.queue.p50 == 4 and oddWarm.queue.p90 == 7,
  "queue percentiles over seven samples are not nearest-rank")

module.latencyReset()
local boundaryBase = 200 * second
local firstAt = boundaryBase
local warmAt = firstAt + 1500 * millisecond
local boundaryAt = warmAt + 2 * second
local coldAt = boundaryAt + 2 * second + 1
for _, entered in ipairs({ firstAt, warmAt, boundaryAt, coldAt }) do
  module.latencyRecord(entered, entered, entered, 40)
end
local boundaryRows = module.latencyRows()
local boundaryWarm = latencyRowFor(boundaryRows, "keyDown", false)
local boundaryCold = latencyRowFor(boundaryRows, "keyDown", true)
-- A gap of exactly 2s is still warm; one nanosecond more is the pause the user feels.
assert(boundaryWarm and boundaryWarm.count == 2,
  "the 2s gap boundary did not fall in the warm bucket")
assert(boundaryCold and boundaryCold.count == 2,
  "a gap past 2s did not fall in the cold bucket")

module.latencyReset()
local ringBase = 300 * second
for index = 1, 5000 do
  local entered = ringBase + index * 10 * millisecond
  module.latencyRecord(entered, entered + index * millisecond, entered, 40)
end
local ringRows = module.latencyRows()
local ringWarm = latencyRowFor(ringRows, "keyDown", false)
assert(ringWarm.count == module.latencyCapacity, "the ring did not cap at its capacity")
assert(#ringRows == 2, "events older than the ring survived into their own bucket")
-- The window is events 905..5000, so the median is 2952 ms and the oldest is gone.
assert(ringWarm.process.max == 5000 and ringWarm.process.p50 == 2952,
  "the ring kept the wrong window of events")
assert(module.latencyLength() == module.latencyCapacity,
  "the ring storage grew instead of overwriting")

module.latencyReset()
local observeBase = 400 * second
module.latencyObserve(latencyEvent(10, 0, observeBase - 3 * millisecond),
  observeBase, observeBase + 500000)
local chordAt = observeBase + 10 * millisecond
module.latencyObserve(latencyEvent(10, 1 << 20, 0), chordAt, chordAt + 500000)
local replayAt = observeBase + 20 * millisecond
module.latencyObserve(latencyEvent(10, 0, replayAt - millisecond, module.replayMarker),
  replayAt, replayAt + 200000)
local mouseAt = observeBase + 30 * millisecond
module.latencyObserve(latencyEvent(2, 0, mouseAt - 2 * millisecond), mouseAt, mouseAt + 100000)
local observeRows = module.latencyRows()
local firstKey = latencyRowFor(observeRows, "keyDown", true)
assert(firstKey and firstKey.queue.p50 == 3 and firstKey.process.p50 == 0.5,
  "the tap wrapper did not read the event's own timestamp")
local chordRow = latencyRowFor(observeRows, "keyDown+chord", false)
-- A zero timestamp costs only the queue delay: the processing time is still real.
assert(chordRow and chordRow.count == 1 and chordRow.queue.count == 0
  and chordRow.queue.p50 == nil and chordRow.process.p50 == 0.5,
  "a synthetic zero timestamp was recorded as a queue delay")
assert(latencyRowFor(observeRows, "keyDown+replay", false).queue.p50 == 1,
  "the replay marker did not reach the class")
assert(latencyRowFor(observeRows, "leftMouseUp", false).queue.p50 == 2,
  "the mouse event class was not named")
assert(latencyRowFor(observeRows, "ALL", false).count == 3, "the warm total lost events")

local report = module.latencyReport()
assert(report:match("ring " .. module.latencyCapacity), "the report hides the ring size")
assert(report:match("hot path per event"), "the report hides its own cost")
assert(report:match("keyDown%+chord%s+warm%s+1%s+0%s+%-"),
  "the report lost the chord row or its missing queue delay")
assert(report:match("keyDown%s+cold%s+1%s+1%s+3%.00%s+3%.00%s+3%.00%s+3%.00%s+0%.50"),
  "the report lost the two-decimal ms columns")
-- The zero-timestamp chord above is the one reading the ceiling threw away, and a
-- discard the report does not mention reads as a queue delay nobody ever had.
assert(report:match("dropped: 1 queue readings"),
  "the report hid the reading its own ceiling discarded")

-- The ceiling is there for clock mismatches, not for delays: a stall of seconds is
-- exactly what this instrument exists to catch, so it has to survive the filter that
-- used to sit at one second.
do
local stallBase = 450 * second
module.latencyReset()
module.latencyRecord(stallBase, stallBase, stallBase, 40)
local stalledAt = stallBase + 5 * second
module.latencyRecord(stalledAt, stalledAt, stalledAt - 5 * second, 40)
local stallRow = latencyRowFor(module.latencyRows(), "keyDown", true)
assert(stallRow and stallRow.queue.count == 2 and stallRow.queue.max == 5000,
  "a five-second queue delay was discarded instead of reported")
assert(not module.latencyReport():match("dropped:"),
  "a reading that was kept was counted as dropped")
local mismatchedAt = stalledAt + 31 * second
module.latencyRecord(mismatchedAt, mismatchedAt, mismatchedAt - 31 * second, 40)
assert(latencyRowFor(module.latencyRows(), "keyDown", true).queue.count == 2,
  "a reading past the ceiling was recorded as a queue delay")
assert(module.latencyReport():match("dropped: 1 queue readings"),
  "the reading past the ceiling was not counted")
end

-- A synthetic event carries no timestamp, so subtracting it measures the uptime. Within
-- the first half-minute of a boot that lands well inside the ceiling and used to be
-- recorded as a queue delay of seconds nobody ever waited.
do
module.latencyReset()
local bootBase = 5 * second
module.latencyRecord(bootBase, bootBase, 0, 40)
module.latencyRecord(bootBase + 3 * second, bootBase + 3 * second, nil, 40)
local bootRow = latencyRowFor(module.latencyRows(), "keyDown", true)
assert(bootRow and bootRow.count == 2 and bootRow.queue.count == 0,
  "a zero timestamp inside the ceiling was recorded as a queue delay")
assert(module.latencyReport():match("dropped: 2 queue readings"),
  "the readings with no timestamp behind them were not counted as dropped")
end

module.latencyReset()
assert(module.latencyReport():match("no events recorded"), "an empty ring reported rows")
assert(not module.latencyReport():match("dropped:"), "the reset kept the dropped count")

-- claude-keys off, hours pass, on again: the first event afterwards follows no
-- previous event at all, and measured against the one from before the stop it reads
-- as warm. M.start installs the real tap and its watchers, so it runs here against
-- stub Hammerspoon objects — the module reads every hs API through its environment.
do
local function stubHandle()
  return { start = function() end, stop = function() end, isEnabled = function() return true end,
    subscribe = function() end, unsubscribeAll = function() end }
end
local tapCallback
env.hs.axuielement = {}
env.hs.eventtap.new = function(_, callback)
  tapCallback = callback
  return stubHandle()
end
env.hs.timer = { doEvery = stubHandle, doAfter = stubHandle }
env.hs.application = { watcher = { new = stubHandle } }
env.hs.spaces = { watcher = { new = stubHandle } }
env.hs.caffeinate = { watcher = { new = stubHandle } }
env.hs.window = { filter = { new = stubHandle, windowFocused = 1, windowUnfocused = 2,
  windowCreated = 3, windowDestroyed = 4, windowTitleChanged = 5 } }
env.hs.task = { new = function()
  return { start = function() return false end, terminate = function() end }
end }

integration = integrationContext()
local restartBase = 600 * second
module.latencyReset()
module.latencyRecord(restartBase, restartBase, restartBase, 40)
local warmAfterFirst = restartBase + 10 * millisecond
module.latencyRecord(warmAfterFirst, warmAfterFirst, warmAfterFirst, 40)
assert(latencyRowFor(module.latencyRows(), "keyDown", false).count == 1,
  "the fixture's second event was not warm before the restart")
assert(module.start(), "the stubbed start did not report a running tap")
module.stop()
local afterRestart = warmAfterFirst + 10 * millisecond
module.latencyRecord(afterRestart, afterRestart, afterRestart, 40)
assert(latencyRowFor(module.latencyRows(), "keyDown", false).count == 1,
  "the first event after a restart was timed against the one from before the stop")
assert(latencyRowFor(module.latencyRows(), "keyDown", true).count == 2,
  "the first event after a restart was not cold")

-- The event whose handling throws is exactly the sample worth having, and a tap that
-- lets the error out is one the system eventually disables: it is caught, still
-- measured, reported once, and the event reaches the terminal as if we were not here.
assert(tapCallback, "M.start installed no tap callback")
local function tapEvent(explode)
  local event = {}
  function event:getType() return 10 end
  function event:rawFlags() return 0 end
  function event:timestamp() return 20 * second - 2 * millisecond end
  function event:getProperty() return 0 end
  function event:getKeyCode()
    if explode then error("handleEvent blew up") end
    return 0
  end
  function event:getFlags() return eventFlags({}) end
  function event:getCharacters() return nil end
  return event
end
module.latencyReset()
assert(tapCallback(tapEvent(true)) == false,
  "an event whose handling threw was consumed instead of passed to the terminal")
local tapRow = latencyRowFor(module.latencyRows(), "keyDown", true)
assert(tapRow and tapRow.count == 1 and tapRow.queue.p50 == 2,
  "the sample from a throwing callback was lost with the error")
assert(integration.logged() == 1, "a throwing callback was not reported")
assert(tapCallback(tapEvent(true)) == false, "the second throwing event was consumed")
assert(integration.logged() == 1, "the tap error was reported once per event it threw on")
assert(latencyRowFor(module.latencyRows(), "keyDown", false).count == 1,
  "the second throwing event was not measured either")
assert(tapCallback(tapEvent(false)) == false,
  "an ordinary event stopped passing through the wrapped callback")
assert(latencyRowFor(module.latencyRows(), "keyDown", false).count == 2,
  "an ordinary event through the wrapped callback was not measured")

-- Once per session, and `claude-keys off; on` IS the next session — it is what gets
-- pressed to make the failure happen again. A latch surviving the restart leaves the
-- rest of that session silent about the very throw it was restarted to see.
module.start()
module.stop()
assert(tapCallback(tapEvent(true)) == false,
  "the throwing event after a restart was consumed")
assert(integration.logged() == 2,
  "a restart kept the tap-error latch from the session before it")
end

-- The whole scrape, both backends, against a stub AXTextArea: M.start has run above, so the
-- module holds the axuielement its calibration walk reaches AX through, and that walk is
-- counted — a verdict re-probed per scrape costs exactly what the verdict exists to save.
-- Scoped: this chunk sits at the same 200-local ceiling the module does.
do
-- One table, because the chunk this runs in is already close to that ceiling.
local fx = {
  screen = "──────\n❯\194\160first draft\n──────\n",
  scrapes = 0,
  walks = 0,
  observed = { bundleID = "com.apple.Terminal", windowID = 7, tabIndex = 1,
    tabElement = "tab-a" },
  box = { windowID = 7, tab = "tab-a", tabIndex = 1, x = 0, y = 0, w = 1200, h = 800 },
  window = { id = function() return 7 end,
    frame = function() return { x = 0, y = 0, w = 1200, h = 800 } end },
}
fx.textArea = { attributeValue = function(_, name)
  if name == "AXRole" then return "AXTextArea" end
  if name == "AXNumberOfCharacters" then return #fx.value end
  if name == "AXValue" then return fx.value end
  return nil
end }
env.hs.osascript = { applescript = function()
  fx.scrapes = fx.scrapes + 1
  if fx.syncOnScrape then fx.value = fx.screen end
  return true, fx.screen
end }
env.hs.axuielement.windowElement = function()
  fx.walks = fx.walks + 1
  return { attributeValue = function(_, name)
    if name == "AXChildren" then return { fx.textArea } end
    return "AXWindow"
  end }
end
integration = integrationContext()
assert(module.axWindow(7, fx.window) == fx.window, "the fixture window was not resolved")

fx.value = "a scrollback that is not this screen\n"
local text, backend = module.axScreenText(fx.observed)
assert(text == fx.screen and backend == "as" and fx.scrapes == 1 and fx.walks == 1,
  "the first scrape of a window did not calibrate its AX tail against the screen")
assert((module.axTextFresh(fx.box) or {}).capable == false,
  "the tail that did not reproduce the screen was not cached as AppleScript-only")
text, backend = module.axScreenText(fx.observed)
assert(text == fx.screen and backend == "as" and fx.scrapes == 2 and fx.walks == 1,
  "an AppleScript-only window walked AX again instead of reading its own verdict")

-- Cmd+plus changes the row count without moving the window, so one AppleScript pass per
-- TTL re-measures what the frame fingerprint alone would hold forever.
integration.advance(module.axText.ttl + 1)
assert(module.axTextFresh(fx.box) == nil, "a calibration older than the TTL was still fresh")
fx.value = "old line\n" .. fx.screen
text, backend = module.axScreenText(fx.observed)
assert(text == fx.screen and backend == "as" and fx.scrapes == 3 and fx.walks == 2,
  "an expired calibration was not re-measured by the next scrape")
assert((module.axTextFresh(fx.box) or {}).capable == true,
  "the re-measured window did not become AX-capable")
text, backend = module.axScreenText(fx.observed)
assert(text == fx.screen and backend == "ax" and fx.scrapes == 3 and fx.walks == 2,
  "the calibrated window did not read its screen off AX")
assert(module.axText.ttl == 600, "the calibration TTL moved away from ten minutes")

fx.secondScreen = "──────\n❯\194\160second draft\n──────\n"
fx.secondObserved = { bundleID = "com.apple.Terminal", windowID = 8, tabIndex = 1,
  tabElement = "tab-b" }
fx.secondBox = { windowID = 8, tab = "tab-b", tabIndex = 1,
  x = 20, y = 10, w = 1000, h = 700 }
fx.secondWindow = { id = function() return 8 end,
  frame = function() return { x = 20, y = 10, w = 1000, h = 700 } end }
fx.secondValue = "old line\n" .. fx.secondScreen
fx.secondTextArea = { attributeValue = function(_, name)
  if name == "AXNumberOfCharacters" then return #fx.secondValue end
  if name == "AXValue" then return fx.secondValue end
  return nil
end }
assert(module.axWindow(8, fx.secondWindow) == fx.secondWindow,
  "the second fixture window was not held")
module.axTextCalibrate(fx.secondScreen, fx.secondBox,
  function() return fx.secondTextArea, fx.secondValue end)
text, backend = module.axScreenText(fx.observed)
assert(text == fx.screen and backend == "ax",
  "the first AX-capable window fell back while alternating")
text, backend = module.axScreenText(fx.secondObserved)
assert(text == fx.secondScreen and backend == "ax",
  "the second AX-capable window fell back while alternating")
text, backend = module.axScreenText(fx.observed)
assert(text == fx.screen and backend == "ax",
  "the first AX-capable window was evicted by the second")
text, backend = module.axScreenText(fx.secondObserved)
assert(text == fx.secondScreen and backend == "ax",
  "the second AX-capable window was evicted by the first")
assert(fx.scrapes == 3 and fx.walks == 2,
  "alternating AX-capable windows thrashed the calibration cache")

-- An element that outlived its tab answers short: that box has no verdict left to reuse, so
-- the scrape it falls back to measures it again inside the same TTL.
fx.value = "\n"
text, backend = module.axScreenText(fx.observed)
assert(text == fx.screen and backend == "as" and fx.scrapes == 4 and fx.walks == 3,
  "a fast path that came back short left its box uncalibrated")

-- A tail the parser rejects and the scrape disagrees with is a tail that no longer starts
-- where the screen does: that box is measured again from the scrape it just paid for.
fx.value = fx.screen
module.axTextCalibrate(fx.screen, fx.box, function() return fx.textArea, fx.value end)
fx.value = "transcript one\ntranscript two\ntranscript three\n"
fx.screen = "──────\n❯\194\160healed draft\n──────\n"
fx.syncOnScrape = true
fx.scrapesBefore, fx.walksBefore = fx.scrapes, fx.walks
text, backend = module.axScreenText(fx.observed)
assert(text == fx.screen and backend == "as"
    and fx.scrapes == fx.scrapesBefore + 1 and fx.walks == fx.walksBefore + 1,
  "an AX tail that disagreed with the scrape was not re-measured against it")
assert((module.axTextFresh(fx.box) or {}).capable == true,
  "the mismatching tail did not recalibrate the AX screen")

-- A screen with no parseable input box (an overlay, a pager, a redraw caught mid-flight)
-- is still this screen when the tail reproduces it: re-measuring per scrape would pay the
-- calibration walk for as long as that overlay stays up.
fx.unparseable = "plain one\nplain two\nplain three\n"
fx.value, fx.screen, fx.syncOnScrape = fx.unparseable, fx.unparseable, false
fx.scrapesBefore, fx.walksBefore = fx.scrapes, fx.walks
text, backend = module.axScreenText(fx.observed)
assert(text == fx.unparseable and backend == "as"
    and fx.scrapes == fx.scrapesBefore + 1 and fx.walks == fx.walksBefore,
  "a boxless screen the AX tail reproduced was re-measured instead of trusted")
assert((module.axTextFresh(fx.box) or {}).capable == true,
  "a faithful tail lost its calibration to a screen with no input box")
text, backend = module.axScreenText(fx.observed)
assert(text == fx.unparseable and backend == "as"
    and fx.scrapes == fx.scrapesBefore + 2 and fx.walks == fx.walksBefore,
  "a boxless screen walked AX again on the scrape after it")

assert(module.axTextFresh(fx.box), "the calibration was gone before the restart")
module.start()
assert(module.axTextFresh(fx.box) == nil,
  "a started module kept a calibration measured before it")
module.stop()

-- Without the runtime hooks the gesture caret reads the module's own calibration: the
-- second return is what decides whether one AppleScript pass could produce a caret at all.
module.setTestHooks(nil)
env.hs.timer.secondsSinceEpoch = function() return 0 end
assert(module.axWindow(7, fx.window) == fx.window, "the fixture window was not held again")
local caret, calibrate = module.gestureCaretPoint(fx.observed)
assert(caret == nil and calibrate == true,
  "an uncalibrated window did not ask for the one scrape that would calibrate it")
module.axWindow(42, { id = function() return 42 end, frame = function() return nil end })
caret, calibrate = module.gestureCaretPoint({ bundleID = "com.apple.Terminal", windowID = 42,
  tabIndex = 1, tabElement = "tab-a" })
assert(caret == nil and calibrate == false,
  "a window with no frame asked for a calibration scrape with nothing to measure")
end

return "PASS: Claude Cmd key decisions"
