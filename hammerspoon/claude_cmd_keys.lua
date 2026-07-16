local M = {}

local terminalBundleID = "com.apple.Terminal"
local cacheTtl = 0.6
local refreshInterval = 0.2
local refreshAfter = 0.35
local ttyRefreshAfter = 1.0
local watchdogInterval = 5
-- ANSI keycodes keep Cmd+C/V stable when the active input source has no Latin letters.
local cKeyCode = 8
local vKeyCode = 9

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

function M.copyChordPlan()
  return { 24, 25 }
end

function M.imagePastePlan()
  return { 22 }
end

function M.planBytes(plan)
  local bytes = {}
  for _, byte in ipairs(plan or {}) do
    bytes[#bytes + 1] = string.char(byte)
  end
  return table.concat(bytes)
end

local function decideAction(bundleID, claude, pasteboardTypes, key)
  if bundleID ~= terminalBundleID or not claude then
    return "pass"
  end
  key = tostring(key or ""):lower()
  if key == "c" then
    return "copy"
  end
  if key == "v" and M.containsImageType(pasteboardTypes) then
    return "image-paste"
  end
  return "pass"
end

function M.decide(bundleID, psOutput, pasteboardTypes, key)
  return decideAction(bundleID, M.isClaudeForeground(psOutput), pasteboardTypes, key)
end

local function contextIdentityMatches(observed, cached)
  return observed.bundleID == terminalBundleID
    and cached.bundleID == observed.bundleID
    and cached.windowID == observed.windowID
    and cached.windowTitle == observed.windowTitle
    and cached.tabIndex == observed.tabIndex
end

function M.decideCached(observed, cached, pasteboardTypes, key, timestamp)
  if type(observed) ~= "table" or type(cached) ~= "table"
      or not contextIdentityMatches(observed, cached)
      or type(cached.checkedAt) ~= "number"
      or type(timestamp) ~= "number"
      or timestamp < cached.checkedAt
      or timestamp - cached.checkedAt > cacheTtl then
    return "pass"
  end
  return decideAction(observed.bundleID, cached.claude == true, pasteboardTypes, key)
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

local ttyScript = [[
tell application "Terminal"
  if (count of windows) is 0 then return ""
  return tty of selected tab of front window as text
end tell
]]

local function observeFrontmost()
  local app = hs.application.frontmostApplication()
  local observed = { bundleID = app and app:bundleID() or nil }
  if observed.bundleID == terminalBundleID then
    local window = app:focusedWindow()
    observed.windowID = window and window:id() or nil
    observed.windowTitle = window and window:title() or nil
    local windowElement = window and axuielement and axuielement.windowElement(window) or nil
    local tabGroup = windowElement and windowElement:childrenWithRole("AXTabGroup")[1] or nil
    local selectedTab = tabGroup and tabGroup:attributeValue("AXValue") or nil
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
  return hs.timer.secondsSinceEpoch()
end

local function sameObserved(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.bundleID == right.bundleID
    and left.windowID == right.windowID
    and left.windowTitle == right.windowTitle
    and left.tabIndex == right.tabIndex
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
  refreshSoonTimer = hs.timer.doAfter(0.05, function()
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
      windowTitle = observed.windowTitle,
      tabIndex = observed.tabIndex,
      tty = tty,
      checkedAt = now(),
      claude = M.isClaudeForeground(psOutput),
    }
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
  if observed.bundleID ~= terminalBundleID or not observed.windowID then
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
  hs.eventtap.keyStrokes(M.planBytes(plan))
end

local function handleEvent(event, keyCode)
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
  else
    if flags.cmd or flags.ctrl or keyCode == 36 then
      invalidateAndRefresh()
    end
    return false
  end

  local observed = observeFrontmost()

  local pasteboardTypes
  if key == "v" then
    local ok, result = pcall(hs.pasteboard.contentTypes)
    if not ok then
      return false
    end
    pasteboardTypes = result
  end

  local action = M.decideCached(observed, cachedContext, pasteboardTypes, key, now())
  if action == "pass" then
    return false
  end

  if action == "copy" then
    emit(M.copyChordPlan())
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

function M.start()
  started = true
  axuielement = hs.axuielement
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
    hs.window.filter.windowTitleChanged,
    hs.window.filter.windowCreated,
    hs.window.filter.windowDestroyed,
  }, invalidateAndRefresh)
  pollFrontTab()
  return eventTap:isEnabled()
end

function M.handleEvent(event)
  local repeatProperty = hs.eventtap.event.properties.keyboardEventAutorepeat
  local isRepeat = event:getProperty(repeatProperty) ~= 0
  local keyCode = event:getKeyCode()
  if isRepeat then
    return repeatDecisions[keyCode] == true
  end
  repeatDecisions[keyCode] = false

  local started = hs.timer.absoluteTime()
  local consume = handleEvent(event, keyCode)
  lastCallbackMs = (hs.timer.absoluteTime() - started) / 1000000
  repeatDecisions[keyCode] = consume == true
  return consume
end

function M.stop()
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
  if ttyTask then ttyTask:terminate(); ttyTask = nil end
  if psTask then psTask:terminate(); psTask = nil end
  repeatDecisions = {}
end

function M.status()
  return {
    running = started and eventTap ~= nil and eventTap:isEnabled() or false,
    tty = resolvedTty,
    claude = cachedContext and cachedContext.claude or false,
    cacheAge = cachedContext and now() - cachedContext.checkedAt or nil,
    lastCallbackMs = lastCallbackMs,
  }
end

if rawget(_G, "hs") then
  _G.ClaudeCmdKeys = M
  M.start()
end

return M
