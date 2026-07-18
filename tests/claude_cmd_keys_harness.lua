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
assert(module.decide("com.apple.Terminal", native, nil, "x") == "pass", "unhandled key was intercepted")

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

env.hs = {
  eventtap = {
    event = {
      types = { keyDown = 10 },
      properties = {
        eventSourceUserData = 91,
        keyboardEventAutorepeat = 92,
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
  local deferred
  local actions = {}
  local changeCount = 1
  local alertCount = 0
  module.setTestHooks({
    replayProperty = 91,
    now = function() return clock end,
    absoluteTime = function() return clock * 1000000000 end,
    observe = function() return observedNow end,
    contentTypes = function() return types or {} end,
    readURL = function() return opts.url end,
    fileExists = function() return opts.fileExists ~= false end,
    changeCount = function() return changeCount end,
    alert = function() alertCount = alertCount + 1 end,
    loadImage = function()
      if opts.loadFails then return nil end
      return opts.image or {}
    end,
    writeImage = function() actions[#actions + 1] = "write-image" end,
    defer = function(fn) deferred = fn end,
    resolve = function(callback) resolver = callback end,
    after = function(_, callback)
      timeout = { callback = callback, stopped = false }
      function timeout:stop() self.stopped = true end
      return timeout
    end,
    emit = function(plan)
      local bytes = module.planBytes(plan)
      actions[#actions + 1] = bytes == string.char(24, 25) and "copy" or "image-paste"
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
    bumpClipboard = function() changeCount = changeCount + 1 end,
    alerts = function() return alertCount end,
    resolve = function(verdict) resolver(verdict) end,
    timeout = function() timeout.callback() end,
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

local copy = module.copyChordPlan()
assert(#copy == 2, "copy chord length changed")
assert(module.planBytes(copy) == string.char(24, 25), "copy bytes changed")
local paste = module.imagePastePlan()
assert(#paste == 1, "image paste chord length changed")
assert(module.planBytes(paste) == string.char(22), "image paste byte changed")

return "PASS: Claude Cmd key decisions"
