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

local function integrationContext(types)
  local clock = 20
  local observedNow = {
    bundleID = "com.apple.Terminal",
    windowID = 7,
    tabIndex = 1,
    tabElement = "tab-a",
  }
  local resolver
  local timeout
  local actions = {}
  module.setTestHooks({
    replayProperty = 91,
    now = function() return clock end,
    absoluteTime = function() return clock * 1000000000 end,
    observe = function() return observedNow end,
    contentTypes = function() return types or {} end,
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
    resolve = function(verdict) resolver(verdict) end,
    timeout = function() timeout.callback() end,
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

local copy = module.copyChordPlan()
assert(#copy == 2, "copy chord length changed")
assert(module.planBytes(copy) == string.char(24, 25), "copy bytes changed")
local paste = module.imagePastePlan()
assert(#paste == 1, "image paste chord length changed")
assert(module.planBytes(paste) == string.char(22), "image paste byte changed")

return "PASS: Claude Cmd key decisions"
