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

local function keyEvent(keyCode, modifiers, isRepeat, label)
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
  function event:copy()
    return keyEvent(self.keyCode, modifiers, isRepeat, self.label)
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
  local alertMessage
  local scrapeCallback
  local writtenText
  local mouseEvents = {}
  local observeCount = 0
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
      return observedNow
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
    alert = function(message)
      alertCount = alertCount + 1
      alertMessage = message
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
    post = function() actions[#actions + 1] = "replay" end,
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
    alertMessage = function() return alertMessage end,
    wrote = function() return writtenText end,
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
integration.resolve("claude")
assert(#integration.actions == 1 and integration.actions[1] == "replay",
  "target-mismatched Cmd+C was not replayed")

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
assert(integration.alerts() == 1 and integration.alertMessage():find("6", 1, true),
  "Cmd+X did not report the deleted character count")

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
assert(integration.alerts() == 1, "the retried cut alerted twice")

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
assert(integration.alertMessage():find("4", 1, true)
    and not integration.alertMessage():find("7", 1, true),
  "cut alert counted UTF-8 bytes instead of characters")

-- Convert alerts are throttled; cut feedback has to fire on every cut.
integration = integrationContext()
for _ = 1, 2 do
  dragThenCut(integration)
  integration.deliverScrape(screenDraft)
  integration.timeout()
  integration.deliverScrape(screenShorter)
end
assert(integration.alerts() == 2, "a second cut alert was throttled away")

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
assert(#drag == 4 and drag[1].kind == "down" and drag[2].kind == "dragged"
    and drag[3].kind == "dragged" and drag[4].kind == "up",
  "Cmd+A did not post a down/drag/up sequence")
for _, event in ipairs(drag) do
  assert(event.y > draftRowBottom - cellHeight and event.y < draftRowBottom,
    "a Cmd+A drag point left the draft text row")
  assert(math.abs(event.y - expectedY) < 0.001, "a Cmd+A drag point missed the row center")
end
assert(math.abs(drag[1].x - expectedStartX) < 0.001,
  "the drag did not start at the first draft character cell")
assert(math.abs(drag[4].x - expectedEndX) < 0.001,
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
assert(#integration.mouseEvents() == 4, "the in-flight Cmd+A did not drag once")
selectAll(integration, screenDraft)
assert(#integration.mouseEvents() == 8, "the guard outlived the completed Cmd+A pass")

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
