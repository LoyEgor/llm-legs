local M = {}

local terminalBundleID = "com.apple.Terminal"
local cacheTtl = 0.6
local refreshInterval = 0.1
local refreshAfter = 0.35
local ttyRefreshAfter = 1.0
local watchdogInterval = 5
local refreshSoonDelay = 0.01
local pendingDeadline = 0.28
local replayMarker = 1128483673
-- ANSI keycodes keep Cmd+C/V stable when the active input source has no Latin letters.
local cKeyCode = 8
local vKeyCode = 9
local zKeyCode = 6

local imageTypes = {
  ["com.compuserve.gif"] = true,
  ["org.webmproject.webp"] = true,
  ["public.heic"] = true,
  ["public.heif"] = true,
  ["public.image"] = true,
  ["public.jpeg"] = true,
  ["public.jpeg-2000"] = true,
  ["public.png"] = true,
  ["public.tiff"] = true,
  ["public.webp"] = true,
}

local function basename(path)
  return tostring(path or ""):match("([^/]+)$") or ""
end

local function commandIsClaude(command)
  command = tostring(command or ""):match("^%s*(.-)%s*$")
  local executable, arguments = command:match("^(%S+)%s+(.+)$")
  executable = executable or command
  arguments = arguments or ""
  if basename(executable) == "claude"
      or executable:find("/claude/versions/", 1, true) then
    return true
  end

  local runtime = basename(executable)
  if runtime ~= "node" and runtime ~= "bun" then
    return false
  end

  local script = arguments:match("^(%S+)") or ""
  return script:find("/@anthropic%-ai/claude%-code/", 1) ~= nil
    or script:find("/claude%-code/", 1) ~= nil
end

function M.isClaudeForeground(psOutput)
  if type(psOutput) ~= "string" then
    return false
  end

  for line in psOutput:gmatch("[^\r\n]+") do
    local stat, command = line:match("^%s*(%S+)%s+(.+)$")
    if stat and stat:find("+", 1, true) and commandIsClaude(command) then
      return true
    end
  end
  return false
end

function M.containsImageType(types)
  if type(types) ~= "table" then
    return false
  end
  for _, contentType in ipairs(types) do
    if imageTypes[contentType] then
      return true
    end
  end
  return false
end

local imageExtensions = {
  bmp = true,
  gif = true,
  heic = true,
  heif = true,
  jpeg = true,
  jpg = true,
  png = true,
  tif = true,
  tiff = true,
  webp = true,
}

function M.containsFileURLType(types)
  if type(types) ~= "table" then
    return false
  end
  for _, contentType in ipairs(types) do
    if contentType == "public.file-url" then
      return true
    end
  end
  return false
end

function M.fileURLToPath(url)
  if type(url) == "table" then
    url = url.url or url.filePath or url.path or url[1]
  end
  local path = tostring(url or ""):match("^file://[^/]*(/.*)$")
  if not path then
    return nil
  end
  return (path:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

function M.isImagePath(path)
  local ext = tostring(path or ""):match("%.([%a%d]+)$")
  return ext ~= nil and imageExtensions[ext:lower()] == true
end

function M.copyChordPlan()
  return { 24, 25 }
end

function M.imagePastePlan()
  return { 22 }
end

function M.undoPlan()
  return { 31 }
end

function M.planBytes(plan)
  local bytes = {}
  for _, byte in ipairs(plan or {}) do
    bytes[#bytes + 1] = string.char(byte)
  end
  return table.concat(bytes)
end

local function decideAction(bundleID, claude, pasteboardTypes, key, convertPath)
  if bundleID ~= terminalBundleID or not claude then
    return "pass"
  end
  key = tostring(key or ""):lower()
  if key == "c" then
    return "copy"
  end
  if key == "z" then
    return "undo"
  end
  if key == "v" then
    if M.containsImageType(pasteboardTypes) then
      return "image-paste"
    end
    if convertPath then
      return "convert"
    end
  end
  return "pass"
end

function M.decide(bundleID, psOutput, pasteboardTypes, key, convertPath)
  return decideAction(bundleID, M.isClaudeForeground(psOutput), pasteboardTypes, key, convertPath)
end

local function contextIdentityMatches(observed, cached)
  return observed.bundleID == terminalBundleID
    and observed.tabElement ~= nil
    and cached.bundleID == observed.bundleID
    and cached.windowID == observed.windowID
    and cached.tabIndex == observed.tabIndex
    and cached.tabElement == observed.tabElement
end

function M.decideCached(observed, cached, pasteboardTypes, key, timestamp, convertPath)
  local verdict = M.cachedVerdict(observed, cached, timestamp)
  if verdict == "uncertain" then
    return "pass"
  end
  return decideAction(observed.bundleID, verdict == "claude", pasteboardTypes, key, convertPath)
end

function M.cachedVerdict(observed, cached, timestamp)
  if type(observed) ~= "table" or type(cached) ~= "table"
      or not contextIdentityMatches(observed, cached)
      or type(cached.checkedAt) ~= "number"
      or type(timestamp) ~= "number"
      or timestamp < cached.checkedAt
      or timestamp - cached.checkedAt > cacheTtl then
    return "uncertain"
  end
  return cached.claude == true and "claude" or "not-claude"
end

local function idlePendingState()
  return { status = "idle", queue = {} }
end

local function finishPending(state, verdict, targetMatches)
  local actions = {}
  for _, item in ipairs(state.queue) do
    local targetMatchesItem = targetMatches == nil or targetMatches[item.id] == true
    local action
    if verdict == "stop" or not targetMatchesItem then
      action = item.key == "c" and "replay" or "policy-drop"
    elseif verdict == "claude" then
      if item.key == "c" then
        action = "copy"
      elseif item.key == "z" then
        action = "undo"
      elseif item.convertPath then
        action = "convert"
      else
        action = "image-paste"
      end
    else
      action = "replay"
    end
    actions[#actions + 1] = {
      id = item.id,
      action = action,
      path = item.convertPath,
    }
  end
  return idlePendingState(), { actions = actions, verdict = verdict }
end

function M.pendingTransition(state, event)
  state = type(state) == "table" and state or idlePendingState()
  event = type(event) == "table" and event or {}
  if event.type == "press" then
    if event.selfPosted then
      return state, { consume = false, ignored = true }
    end
    if event.key ~= "c" and event.key ~= "v" and event.key ~= "z" then
      return state, { consume = false }
    end
    if event.key == "v" and event.image ~= true then
      return state, { consume = false }
    end
    if event.isRepeat then
      if state.status == "pending" then
        for _, item in ipairs(state.queue) do
          if item.key == event.key then
            return state, { consume = true, folded = true }
          end
        end
      end
      return state, { consume = false, repeated = true }
    end
    local queue = {}
    if state.status == "pending" then
      for index, item in ipairs(state.queue) do
        queue[index] = item
      end
    end
    queue[#queue + 1] = { id = event.id, key = event.key, convertPath = event.convertPath }
    return {
      status = "pending",
      queue = queue,
      deadlineAt = state.status == "pending" and state.deadlineAt
        or event.now + event.timeout,
    }, {
      consume = true,
      startResolve = state.status ~= "pending",
    }
  end
  if state.status ~= "pending" then
    return state, {}
  end
  if event.type == "resolve"
      and (event.verdict == "claude" or event.verdict == "not-claude") then
    return finishPending(state, event.verdict, event.targetMatches)
  end
  if event.type == "tick" and event.now >= state.deadlineAt then
    return finishPending(state, "timeout", event.targetMatches)
  end
  if event.type == "stop" then
    return finishPending(state, "stop")
  end
  return state, {}
end

local eventTap
local refreshTimer
local watchdogTimer
local wakeWatcher
local appWatcher
local spaceWatcher
local terminalWindowFilter
local refreshSoonTimer
local ttyTask
local psTask
local cachedContext
local resolvedTty
local resolvedObserved
local lastTtyCheck = 0
local generation = 0
local started = false
local repeatDecisions = {}
local lastCallbackMs = 0
local axuielement
local replayProperty
local pendingState
local pendingOriginals = {}
local pendingTimer
local pendingNextID = 0
local pendingStartedAt
local lastDeferredMs
local lastDeferredVerdict
local completePending
local runtimeHooks
local previousShutdownCallback
local shutdownCallback

local ttyScript = [[
tell application "Terminal"
  if (count of windows) is 0 then return ""
  return tty of selected tab of front window as text
end tell
]]

local function observeFrontmost(app)
  if runtimeHooks and runtimeHooks.observe then
    return runtimeHooks.observe()
  end
  app = app or hs.application.frontmostApplication()
  local observed = { bundleID = app and app:bundleID() or nil }
  if observed.bundleID == terminalBundleID then
    local window = app:focusedWindow()
    observed.windowID = window and window:id() or nil
    local windowElement = window and axuielement and axuielement.windowElement(window) or nil
    local tabGroup = windowElement and windowElement:childrenWithRole("AXTabGroup")[1] or nil
    local selectedTab = tabGroup and tabGroup:attributeValue("AXValue") or nil
    observed.tabElement = selectedTab
    for index, tab in ipairs(tabGroup and tabGroup:attributeValue("AXTabs") or {}) do
      if tab == selectedTab then
        observed.tabIndex = index
        break
      end
    end
  end
  return observed
end

local function now()
  if runtimeHooks and runtimeHooks.now then
    return runtimeHooks.now()
  end
  return hs.timer.secondsSinceEpoch()
end

local function absoluteTime()
  if runtimeHooks and runtimeHooks.absoluteTime then
    return runtimeHooks.absoluteTime()
  end
  return hs.timer.absoluteTime()
end

local function sameObserved(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.bundleID == right.bundleID
    and left.windowID == right.windowID
    and left.tabIndex == right.tabIndex
    and left.tabElement == right.tabElement
end

local function invalidateContext()
  generation = generation + 1
  cachedContext = nil
  resolvedTty = nil
  resolvedObserved = nil
  lastTtyCheck = 0
end

local pollFrontTab

local function scheduleRefresh()
  if not started then
    return
  end
  if refreshSoonTimer then
    refreshSoonTimer:stop()
  end
  refreshSoonTimer = hs.timer.doAfter(refreshSoonDelay, function()
    refreshSoonTimer = nil
    pollFrontTab()
  end)
end

local function invalidateAndRefresh()
  invalidateContext()
  scheduleRefresh()
end

local function refreshProcess(tty, observed)
  if psTask or not started then
    return
  end
  if cachedContext and now() - cachedContext.checkedAt < refreshAfter then
    return
  end

  local taskGeneration = generation
  local task
  task = hs.task.new("/bin/ps", function(exitCode, stdOut)
    if psTask == task then
      psTask = nil
    end
    if not started or taskGeneration ~= generation
        or not sameObserved(observed, observeFrontmost())
        or tty ~= resolvedTty then
      return
    end
    local psOutput = exitCode == 0 and tostring(stdOut or "") or ""
    cachedContext = {
      bundleID = observed.bundleID,
      windowID = observed.windowID,
      tabIndex = observed.tabIndex,
      tabElement = observed.tabElement,
      tty = tty,
      checkedAt = now(),
      claude = M.isClaudeForeground(psOutput),
    }
    completePending("resolve", cachedContext.claude and "claude" or "not-claude")
  end, { "-t", tty:gsub("^/dev/", ""), "-o", "stat=,command=" })
  psTask = task
  if not task or not task:start() then
    psTask = nil
  end
end

local function refreshTty(observed)
  if ttyTask or psTask or not started then
    return
  end

  local taskGeneration = generation
  local task
  task = hs.task.new("/usr/bin/osascript", function(exitCode, stdOut)
    if ttyTask == task then
      ttyTask = nil
    end
    if not started or taskGeneration ~= generation
        or not sameObserved(observed, observeFrontmost()) then
      return
    end

    local tty = exitCode == 0 and tostring(stdOut or ""):match("^%s*(/dev/tty[%w._-]+)%s*$") or nil
    if not tty then
      invalidateContext()
      return
    end
    if resolvedTty and resolvedTty ~= tty then
      invalidateContext()
      observed = observeFrontmost()
    end
    resolvedTty = tty
    resolvedObserved = observed
    lastTtyCheck = now()
    refreshProcess(tty, observed)
  end, { "-e", ttyScript })
  ttyTask = task
  if not task or not task:start() then
    ttyTask = nil
  end
end

pollFrontTab = function()
  local observed = observeFrontmost()
  if observed.bundleID ~= terminalBundleID or not observed.windowID
      or not observed.tabElement then
    if cachedContext or resolvedTty then
      invalidateContext()
    end
    return
  end

  if resolvedObserved and not sameObserved(resolvedObserved, observed) then
    invalidateContext()
  end
  if not resolvedTty or now() - lastTtyCheck >= ttyRefreshAfter then
    refreshTty(observed)
    return
  end
  refreshProcess(resolvedTty, observed)
end

local function emit(plan)
  if runtimeHooks and runtimeHooks.emit then
    runtimeHooks.emit(plan)
    return
  end
  hs.eventtap.keyStrokes(M.planBytes(plan))
end

local function cancelResolveTasks()
  if ttyTask then ttyTask:terminate(); ttyTask = nil end
  if psTask then psTask:terminate(); psTask = nil end
end

local function currentTargetMatches(original, observed)
  return original and sameObserved(original.observed, observed)
end

local function postOriginal(original)
  if runtimeHooks and runtimeHooks.post then
    runtimeHooks.post(original.event)
    return
  end
  original.event:setProperty(replayProperty, replayMarker)
  original.event:post()
end

local function deferAsync(fn)
  if runtimeHooks and runtimeHooks.defer then
    runtimeHooks.defer(fn)
    return
  end
  hs.timer.doAfter(0, fn)
end

local function pasteboardChangeCount()
  if runtimeHooks and runtimeHooks.changeCount then
    return runtimeHooks.changeCount()
  end
  return hs.pasteboard.changeCount()
end

local alertThrottle = 10
local lastAlertAt

local function showConvertAlert(message)
  local at = now()
  if lastAlertAt and at - lastAlertAt < alertThrottle then
    return
  end
  lastAlertAt = at
  if runtimeHooks and runtimeHooks.alert then
    runtimeHooks.alert(message)
  else
    hs.alert.show(message)
  end
end

local function defaultFileExists(path)
  local attributes = hs.fs.attributes(path)
  return attributes ~= nil and attributes.mode == "file"
end

local function resolveFileImagePath(types)
  if not M.containsFileURLType(types) then
    return nil
  end
  local readURL = runtimeHooks and runtimeHooks.readURL or hs.pasteboard.readURL
  local ok, url = pcall(readURL)
  if not ok then
    return nil
  end
  local path = M.fileURLToPath(url)
  if not path or not M.isImagePath(path) then
    return nil
  end
  local fileExists = runtimeHooks and runtimeHooks.fileExists or defaultFileExists
  if not fileExists(path) then
    return nil
  end
  return path
end

-- The event is consumed at schedule time but the pixel load + write run a tick
-- later, so re-check both the target and the clipboard before acting: a switched
-- app or a changed pasteboard means silently drop (replay would paste the wrong
-- thing into the wrong place); an unreadable file replays and alerts (TCC block).
local function performConvert(path, original)
  local scheduledChangeCount = original.changeCount
  deferAsync(function()
    if not currentTargetMatches(original, observeFrontmost())
        or pasteboardChangeCount() ~= scheduledChangeCount then
      if runtimeHooks and runtimeHooks.drop then
        runtimeHooks.drop(original.event)
      end
      return
    end
    local loadImage = runtimeHooks and runtimeHooks.loadImage or hs.image.imageFromPath
    local image = loadImage(path)
    if not image then
      postOriginal(original)
      showConvertAlert("Cmd+V: can't read image file — check Hammerspoon disk access")
      return
    end
    if runtimeHooks and runtimeHooks.writeImage then
      runtimeHooks.writeImage(image)
    else
      hs.pasteboard.writeObjects(image)
    end
    emit(M.imagePastePlan())
  end)
end

-- Menu-driven entry points: the automation menu (iPad) reuses the same plans
-- instead of synthesizing modifier chords, which can drop on first press when
-- posted to an app; raw control bytes take the exact path the physical-key
-- flow above already proved out. menuPaste returns false when the clipboard
-- is textual - the caller then pastes natively (Cmd+V).
local function emitTo(plan, app)
  if runtimeHooks and runtimeHooks.emit then
    runtimeHooks.emit(plan)
    return
  end
  hs.eventtap.keyStrokes(M.planBytes(plan), app)
end

function M.menuCopy(app)
  emitTo(M.copyChordPlan(), app)
end

function M.menuPaste(app)
  local contentTypes = runtimeHooks and runtimeHooks.contentTypes
    or hs.pasteboard.contentTypes
  local ok, types = pcall(contentTypes)
  if not ok then
    return false
  end
  if M.containsImageType(types) then
    emitTo(M.imagePastePlan(), app)
    return true
  end
  local path = resolveFileImagePath(types)
  if path then
    local loadImage = runtimeHooks and runtimeHooks.loadImage or hs.image.imageFromPath
    local image = loadImage(path)
    if not image then
      showConvertAlert("Paste: can't read image file — check Hammerspoon disk access")
      return false
    end
    if runtimeHooks and runtimeHooks.writeImage then
      runtimeHooks.writeImage(image)
    else
      hs.pasteboard.writeObjects(image)
    end
    emitTo(M.imagePastePlan(), app)
    return true
  end
  return false
end

completePending = function(eventType, verdict)
  local targetMatches
  if eventType ~= "stop" and pendingState and pendingState.status == "pending" then
    targetMatches = {}
    local observed = observeFrontmost()
    for _, item in ipairs(pendingState.queue) do
      targetMatches[item.id] = currentTargetMatches(pendingOriginals[item.id], observed)
    end
  end
  local nextState, effect = M.pendingTransition(pendingState, {
    type = eventType,
    verdict = verdict,
    now = now(),
    targetMatches = targetMatches,
  })
  pendingState = nextState
  if not effect.actions then
    return false
  end
  if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
  lastDeferredMs = pendingStartedAt
    and (absoluteTime() - pendingStartedAt) / 1000000 or nil
  lastDeferredVerdict = effect.verdict
  pendingStartedAt = nil
  for _, item in ipairs(effect.actions) do
    local original = pendingOriginals[item.id]
    pendingOriginals[item.id] = nil
    if item.action == "copy" then
      emit(M.copyChordPlan())
    elseif item.action == "undo" then
      emit(M.undoPlan())
    elseif item.action == "image-paste" then
      emit(M.imagePastePlan())
    elseif item.action == "convert" then
      performConvert(item.path, original)
    elseif item.action == "replay" then
      postOriginal(original)
    elseif item.action == "policy-drop" then
      if runtimeHooks and runtimeHooks.drop then
        runtimeHooks.drop(original.event)
      end
    else
      error("unknown pending action")
    end
  end
  return true
end

local function armPendingTimeout(delay)
  local after = runtimeHooks and runtimeHooks.after or hs.timer.doAfter
  pendingTimer = after(delay, function()
    pendingTimer = nil
    if not completePending("tick")
        and pendingState and pendingState.status == "pending" then
      armPendingTimeout(math.max(0.001, pendingState.deadlineAt - now()))
    end
  end)
end

local function deferEvent(event, observed, key, isRepeat, convertPath)
  pendingNextID = pendingNextID + 1
  local nextState, effect = M.pendingTransition(pendingState, {
    type = "press",
    id = pendingNextID,
    key = key,
    image = key == "v",
    convertPath = convertPath,
    isRepeat = isRepeat,
    now = now(),
    timeout = pendingDeadline,
  })
  pendingState = nextState
  if not effect.consume then
    return false
  end
  if effect.folded then
    return true
  end
  pendingOriginals[pendingNextID] = {
    event = event:copy(),
    observed = observed,
    changeCount = pasteboardChangeCount(),
  }
  if effect.startResolve then
    pendingStartedAt = absoluteTime()
    armPendingTimeout(pendingDeadline)
    invalidateContext()
    cancelResolveTasks()
    if runtimeHooks and runtimeHooks.resolve then
      runtimeHooks.resolve(function(result)
        completePending("resolve", result)
      end)
    else
      pollFrontTab()
    end
  end
  return true
end

local function handleEvent(event, keyCode, isRepeat)
  if event:getType() ~= hs.eventtap.event.types.keyDown then
    invalidateAndRefresh()
    return false
  end

  local flags = event:getFlags()
  local key
  if flags:containExactly({ "cmd" }) and keyCode == cKeyCode then
    key = "c"
  elseif flags:containExactly({ "cmd" }) and keyCode == vKeyCode then
    key = "v"
  elseif flags:containExactly({ "cmd" }) and keyCode == zKeyCode then
    key = "z"
  else
    if flags.cmd or flags.ctrl or keyCode == 36 then
      invalidateAndRefresh()
    end
    return false
  end

  if isRepeat and pendingState and pendingState.status == "pending" then
    local nextState, effect = M.pendingTransition(pendingState, {
      type = "press",
      key = key,
      image = key == "v",
      isRepeat = true,
    })
    pendingState = nextState
    if effect.folded then return effect.consume end
  end

  local observed
  if runtimeHooks then
    observed = observeFrontmost()
  else
    local app = hs.application.frontmostApplication()
    if not app or app:bundleID() ~= terminalBundleID then
      return false
    end
    observed = observeFrontmost(app)
  end
  if observed.bundleID ~= terminalBundleID then return false end

  local pasteboardTypes
  local convertPath
  if key == "v" then
    local contentTypes = runtimeHooks and runtimeHooks.contentTypes
      or hs.pasteboard.contentTypes
    local ok, result = pcall(contentTypes)
    if not ok then
      return false
    end
    pasteboardTypes = result
    if not M.containsImageType(pasteboardTypes) then
      convertPath = resolveFileImagePath(pasteboardTypes)
      if not convertPath then
        return false
      end
    end
  end

  local verdict = M.cachedVerdict(observed, cachedContext, now())
  if verdict == "uncertain" then
    return deferEvent(event, observed, key, isRepeat, convertPath)
  end
  local action = decideAction(observed.bundleID, verdict == "claude", pasteboardTypes, key, convertPath)
  if action == "pass" then return false end

  if action == "copy" then
    emit(M.copyChordPlan())
  elseif action == "undo" then
    emit(M.undoPlan())
  elseif action == "convert" then
    performConvert(convertPath, {
      event = event:copy(),
      observed = observed,
      changeCount = pasteboardChangeCount(),
    })
  else
    emit(M.imagePastePlan())
  end
  return true
end

local function healEventTap()
  if eventTap and not eventTap:isEnabled() then
    eventTap:start()
  end
end

function M.setTestHooks(hooks)
  runtimeHooks = hooks
  if pendingTimer then pendingTimer:stop() end
  pendingTimer = nil
  pendingState = idlePendingState()
  pendingOriginals = {}
  pendingNextID = 0
  pendingStartedAt = nil
  cachedContext = nil
  resolvedTty = nil
  resolvedObserved = nil
  repeatDecisions = {}
  lastAlertAt = nil
  replayProperty = hooks and hooks.replayProperty or replayProperty
end

function M.start()
  started = true
  axuielement = hs.axuielement
  replayProperty = hs.eventtap.event.properties.eventSourceUserData
  pendingState = pendingState or M.pendingTransition(nil, {})
  if eventTap then
    healEventTap()
    return eventTap:isEnabled()
  end
  eventTap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.rightMouseDown,
    hs.eventtap.event.types.otherMouseDown,
  }, function(event)
    return M.handleEvent(event)
  end)
  eventTap:start()
  refreshTimer = hs.timer.doEvery(refreshInterval, pollFrontTab)
  watchdogTimer = hs.timer.doEvery(watchdogInterval, healEventTap)
  appWatcher = hs.application.watcher.new(function(_, event)
    if event == hs.application.watcher.activated
        or event == hs.application.watcher.deactivated
        or event == hs.application.watcher.hidden
        or event == hs.application.watcher.terminated then
      invalidateAndRefresh()
    end
  end)
  appWatcher:start()
  spaceWatcher = hs.spaces.watcher.new(invalidateAndRefresh)
  spaceWatcher:start()
  wakeWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
        or event == hs.caffeinate.watcher.screensDidWake
        or event == hs.caffeinate.watcher.screensDidUnlock
        or event == hs.caffeinate.watcher.sessionDidBecomeActive then
      invalidateAndRefresh()
      healEventTap()
    end
  end)
  wakeWatcher:start()
  terminalWindowFilter = hs.window.filter.new("Terminal")
  terminalWindowFilter:subscribe({
    hs.window.filter.windowFocused,
    hs.window.filter.windowUnfocused,
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
  }, invalidateAndRefresh)
  terminalWindowFilter:subscribe(hs.window.filter.windowTitleChanged, pollFrontTab)
  previousShutdownCallback = hs.shutdownCallback
  shutdownCallback = function()
    M.stop()
    if previousShutdownCallback then previousShutdownCallback() end
  end
  hs.shutdownCallback = shutdownCallback
  pollFrontTab()
  return eventTap:isEnabled()
end

function M.handleEvent(event)
  if replayProperty and event:getProperty(replayProperty) == replayMarker then
    local _, effect = M.pendingTransition(pendingState, {
      type = "press",
      selfPosted = true,
    })
    return effect.consume == true
  end
  local keyCode = event:getKeyCode()
  local isKeyDown = event:getType() == hs.eventtap.event.types.keyDown
  local repeatProperty = hs.eventtap.event.properties.keyboardEventAutorepeat
  local isRepeat = event:getProperty(repeatProperty) ~= 0
  if isRepeat then
    local key = keyCode == cKeyCode and "c" or keyCode == vKeyCode and "v"
      or keyCode == zKeyCode and "z" or nil
    local keyIsPending = false
    for _, item in ipairs(pendingState and pendingState.queue or {}) do
      if item.key == key then
        keyIsPending = true
        break
      end
    end
    if not keyIsPending then return repeatDecisions[keyCode] == true end

    local callbackStarted = absoluteTime()
    local consume = handleEvent(event, keyCode, true)
    lastCallbackMs = (absoluteTime() - callbackStarted) / 1000000
    return consume
  end
  if isKeyDown then repeatDecisions[keyCode] = false end

  local callbackStarted = absoluteTime()
  local consume = handleEvent(event, keyCode, isRepeat)
  lastCallbackMs = (absoluteTime() - callbackStarted) / 1000000
  if isKeyDown then repeatDecisions[keyCode] = consume == true end
  return consume
end

function M.stop()
  completePending("stop")
  started = false
  invalidateContext()
  if eventTap then eventTap:stop(); eventTap = nil end
  if refreshTimer then refreshTimer:stop(); refreshTimer = nil end
  if watchdogTimer then watchdogTimer:stop(); watchdogTimer = nil end
  if wakeWatcher then wakeWatcher:stop(); wakeWatcher = nil end
  if appWatcher then appWatcher:stop(); appWatcher = nil end
  if spaceWatcher then spaceWatcher:stop(); spaceWatcher = nil end
  if terminalWindowFilter then
    terminalWindowFilter:unsubscribeAll()
    terminalWindowFilter = nil
  end
  if refreshSoonTimer then refreshSoonTimer:stop(); refreshSoonTimer = nil end
  if pendingTimer then pendingTimer:stop(); pendingTimer = nil end
  if ttyTask then ttyTask:terminate(); ttyTask = nil end
  if psTask then psTask:terminate(); psTask = nil end
  pendingState = nil
  pendingOriginals = {}
  pendingStartedAt = nil
  repeatDecisions = {}
  if rawget(_G, "hs") and hs.shutdownCallback == shutdownCallback then
    hs.shutdownCallback = previousShutdownCallback
  end
end

-- Live Claude-vs-shell verdict for the frontmost Terminal tab, validated
-- against the current context rather than the last resolved value:
-- "claude" | "not-claude" | "uncertain". Reuses the same cache the physical
-- Cmd+C path reads, at the same per-tab granularity. SendActions gates its copy
-- chord on this so ctrl+x ctrl+y never reaches a plain shell.
function M.foregroundVerdict()
  return M.cachedVerdict(observeFrontmost(), cachedContext, now())
end

function M.status()
  return {
    running = started and eventTap ~= nil and eventTap:isEnabled() or false,
    tty = resolvedTty,
    claude = cachedContext and cachedContext.claude or false,
    cacheAge = cachedContext and now() - cachedContext.checkedAt or nil,
    lastCallbackMs = lastCallbackMs,
    pendingCount = pendingState and #pendingState.queue or 0,
    lastDeferredMs = lastDeferredMs,
    lastDeferredVerdict = lastDeferredVerdict,
  }
end

if rawget(_G, "hs") then
  _G.ClaudeCmdKeys = M
  M.start()
end

return M
