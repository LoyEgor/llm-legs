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
  local timeoutCount = 0
  local deferred
  local actions = {}
  local changeCount = 1
  local alertCount = 0
  local scrapeCallback
  local writtenText
  local mouseEvents = {}
  local observeCount = 0
  local afterObserve
  local replays = {}
  module.setTestHooks({
    mouse = function(kind, point)
      mouseEvents[#mouseEvents + 1] = { kind = kind, x = point.x, y = point.y }
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
    contentTypes = function() return types or {} end,
    readURL = function() return opts.url end,
    verdict = opts.verdict and function() return opts.verdict end or nil,
    fileExists = function() return opts.fileExists ~= false end,
    windowFrame = opts.windowFrame and function(windowID)
      assert(windowID == 7, "the window frame was looked up for another window")
      return opts.windowFrame
    end or nil,
    changeCount = function() return changeCount end,
    alert = function()
      alertCount = alertCount + 1
    end,
    scrape = function(callback)
      actions[#actions + 1] = "scrape"
      if opts.scrapeThrows then error("scrape blew up") end
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
      -- Only the re-scrape timers: the 0.28 pending deadline shares this hook.
      if delay == 0.15 then
        timeoutCount = timeoutCount + 1
      end
      timeout = { delay = delay, callback = callback, stopped = false }
      function timeout:stop() self.stopped = true end
      if delay == 0.15 then cutTimeout = timeout end
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
      else
        actions[#actions + 1] = "image-paste"
      end
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
    switchApp = function(bundleID)
      observedNow = bundleID and { bundleID = bundleID }
        or { bundleID = "com.apple.Terminal", windowID = 7, tabIndex = 1, tabElement = "tab-a" }
    end,
    bumpClipboard = function() changeCount = changeCount + 1 end,
    alerts = function() return alertCount end,
    mouseEvents = function() return mouseEvents end,
    observations = function() return observeCount end,
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
    deliverScrape = function(screenText)
      local callback = scrapeCallback
      scrapeCallback = nil
      assert(callback, "no scrape was awaiting a screen")
      callback(screenText)
    end,
    resolve = function(verdict) resolver(verdict) end,
    timeout = function() timeout.callback() end,
    fireCutTimer = function() cutTimeout.callback() end,
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

-- A plain click selects nothing, so it must not pay for an AX round trip.
integration = integrationContext()
module.handleEvent(mouseEvent(1))
local beforeUp = integration.observations()
module.handleEvent(mouseEvent(2))
assert(integration.observations() == beforeUp,
  "a plain mouse-up looked up the frontmost app with nothing to arm")

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
  shiftArrowPress, functionKeyPress, cmdShiftPress,
}) do
  integration = integrationContext(textTypes)
  simulateDrag()
  assert(not module.handleEvent(press()), "a key that inserts no text was consumed")
  assert(#integration.actions == 0, "a key that inserts no text produced an action")
  pressCut(integration)
  assert(#integration.actions == 0, "a key that inserts no text left the selection armed")
end

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
-- chord is swallowed while Terminal is frontmost and passes anywhere else.
integration = integrationContext()
assert(module.handleEvent(keyEvent(123, { "alt", "shift" }, false, "alt-shift-left")),
  "Option+Shift+Left was not swallowed in Terminal")
assert(#integration.actions == 0, "swallowed Option+Shift+Left still ran an action")
assert(not module.handleEvent(keyEvent(123, { "alt" }, false, "alt-left")),
  "plain Option+Left was intercepted")
integration.switchApp("com.apple.Safari")
assert(not module.handleEvent(keyEvent(123, { "alt", "shift" }, false, "alt-shift-left")),
  "Option+Shift+Left was swallowed outside Terminal")

-- A shell tab has no draft to protect, so there the chord is the user's own.
integration = integrationContext(nil, { verdict = "not-claude" })
assert(not module.handleEvent(keyEvent(123, { "alt", "shift" }, false, "alt-shift-left")),
  "Option+Shift+Left was swallowed in a non-Claude tab")
integration = integrationContext(nil, { verdict = "claude" })
assert(module.handleEvent(keyEvent(126, { "alt", "shift" }, false, "alt-shift-up")),
  "Option+Shift+Up was not swallowed in a Claude tab")

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

return "PASS: Claude Cmd key decisions"
