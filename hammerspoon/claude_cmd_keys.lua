local M = {}

local terminalBundleID = "com.apple.Terminal"
local cacheTtl = 0.6
local refreshInterval = 0.1
local refreshAfter = 0.35
local ttyRefreshAfter = 1.0
local watchdogInterval = 5
local refreshSoonDelay = 0.01
local pendingDeadline = 0.28
local cutScrapeDelay = 0.15
local replayMarker = 1128483673
-- ANSI keycodes keep Cmd+C/V stable when the active input source has no Latin letters.
local keyForCode = { [8] = "c", [9] = "v", [6] = "z", [7] = "x", [0] = "a" }
-- Keys whose action needs no clipboard inspection; Cmd+V is decided from its types.
local actionForKey = { c = "copy", z = "undo", x = "cut", a = "selectAll" }
local dragStepMicros = 4000

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

-- Bare DEL: selection:copy would clear the selection before DEL could consume it,
-- and copyOnSelect is off, so performCut recovers the removed text by diffing the
-- input box around this byte instead of copying it first.
function M.cutPlan()
  return { 127 }
end

-- The fullscreen renderer draws the input between two full-width `─` rules and
-- separates its `❯` prompt from the draft with U+00A0, not a space; the classic
-- renderer draws a `│ > … │` rounded box. Whichever border comes LAST wins: the
-- fullscreen welcome banner is itself a rounded box sitting above the input.
local promptPrefixes = { "❯\194\160", "❯ ", "❯", ">\194\160", "> ", ">" }

local function trimEdges(text)
  return (text:gsub("^%s*(.-)%s*$", "%1"))
end

local function ruleWidth(line)
  local remainder, count = line:gsub("─", "")
  if trimEdges(remainder) ~= "" then
    return 0
  end
  return count
end

local wideRanges = {
  { 0x1100, 0x115F },
  { 0x2E80, 0x303E },
  { 0x3041, 0x33FF },
  { 0x3400, 0x4DBF },
  { 0x4E00, 0x9FFF },
  { 0xA000, 0xA4CF },
  { 0xAC00, 0xD7A3 },
  { 0xF900, 0xFAFF },
  { 0xFE30, 0xFE4F },
  { 0xFF00, 0xFF60 },
  { 0xFFE0, 0xFFE6 },
  { 0x1F300, 0x1FAFF },
  { 0x20000, 0x3FFFD },
}

local zeroWidthRanges = {
  { 0x0300, 0x036F },
  { 0x1AB0, 0x1AFF },
  { 0x1DC0, 0x1DFF },
  { 0x200D, 0x200D },
  { 0x20D0, 0x20FF },
  { 0xFE00, 0xFE0F },
}

local function inRanges(ranges, code)
  for _, range in ipairs(ranges) do
    if code >= range[1] and code <= range[2] then
      return true
    end
  end
  return false
end

local function characterLength(text)
  local count = utf8 and utf8.len and utf8.len(text)
  return type(count) == "number" and count or #text
end

-- One keypress deletes one grapheme, and a grapheme can be several codepoints (an emoji
-- joined by ZWJ, a skin tone, a combining mark, the two regional indicators of a flag).
-- The no-selection guard in performCut has to read those as one character, or a bare DEL
-- through an emoji reads as a real cut.
local function isSingleCharacter(text)
  if not (utf8 and utf8.codes and utf8.len and utf8.len(text)) then
    return #text == 1
  end
  local characters = 0
  local afterJoiner = false
  local openRegional = false
  for _, code in utf8.codes(text) do
    local regional = code >= 0x1F1E6 and code <= 0x1F1FF
    local continues = afterJoiner or (regional and openRegional)
      or inRanges(zeroWidthRanges, code)
      or (code >= 0x1F3FB and code <= 0x1F3FF)
    afterJoiner = code == 0x200D
    openRegional = regional and not openRegional
    if not continues then
      characters = characters + 1
      if characters > 1 then
        return false
      end
    end
  end
  return characters == 1
end

-- The terminal draws CJK and emoji two cells wide and joiners/marks not at all, and a
-- codepoint count would make every Cmd+A drag stop short of them. Only unambiguously
-- wide ranges count double: the ambiguous-width glyphs (❯ │ ─ ⏵ ✓ ·) are what the live
-- borders and statusline are made of, and they measure one cell there.
local function cellLength(text)
  local count = utf8 and utf8.len and utf8.len(text)
  if type(count) ~= "number" then
    return #text
  end
  for _, code in utf8.codes(text) do
    if code >= 0x0300 then
      if inRanges(zeroWidthRanges, code) then
        count = count - 1
      elseif inRanges(wideRanges, code) then
        count = count + 1
      end
    end
  end
  return count
end

-- Also reports how many cells were stripped off the left, so a caller can map a
-- draft character back to the column it occupies on the real screen.
local function stripBorders(line, style)
  local lead = 0
  if style == "rounded" then
    local border, inner = line:match("^(%s*│)(.*)│%s*$")
    if inner then
      local trimmed, removed = inner:gsub("^ ", "")
      lead = cellLength(border) + removed
      line = trimmed
    end
  end
  return (line:gsub("%s+$", "")), lead
end

function M.parseInputBox(screenText)
  if type(screenText) ~= "string" then
    return nil
  end
  local lines = {}
  -- The live scrape ends with "\n" (measured: 59 rows, 60 split lines); a blind
  -- append would count a phantom row and shift every drag point one cell up.
  if screenText:sub(-1) ~= "\n" then
    screenText = screenText .. "\n"
  end
  for line in screenText:gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local bottom, style
  for index = #lines, 1, -1 do
    if ruleWidth(lines[index]) >= 4 then
      bottom, style = index, "rule"
      break
    elseif lines[index]:find("^%s*╰") then
      bottom, style = index, "rounded"
      break
    end
  end
  if not bottom then
    return nil
  end

  local top
  for index = bottom - 1, 1, -1 do
    local isTop = style == "rule" and ruleWidth(lines[index]) >= 4
      or style == "rounded" and lines[index]:find("^%s*╭") ~= nil
    if isTop then
      top = index
      break
    end
  end
  if not top then
    return nil
  end

  local layout = { columns = 0 }
  for _, line in ipairs(lines) do
    local width = cellLength(line)
    if width > layout.columns then
      layout.columns = width
    end
  end

  local content = {}
  for index = top + 1, bottom - 1 do
    local line, lead = stripBorders(lines[index], style)
    if index == top + 1 then
      for _, prefix in ipairs(promptPrefixes) do
        if line:sub(1, #prefix) == prefix then
          line = line:sub(#prefix + 1)
          lead = lead + cellLength(prefix)
          break
        end
      end
    else
      local trimmed, removed = line:gsub("^  ", "")
      line, lead = trimmed, lead + removed * 2
    end
    content[#content + 1] = line
    -- Every box row counts, even blank ones: Cmd+A must sweep leading/trailing
    -- empty lines too, or a later DEL leaves them behind.
    if not layout.firstRow then
      layout.firstRow = index
      layout.firstColumn = lead + 1
    end
    layout.lastRow = index
    layout.lastColumn = math.max(lead + cellLength(line), lead + 1)
    if line ~= "" then
      layout.hasText = true
    end
  end
  -- Rows join with a space, never "\n": a deletion reflows the wrap point, and a
  -- wrap-swallowed inter-word space has to canonicalize to the same byte as the
  -- inline space it becomes, or the common suffix breaks at the moved row edge.
  return table.concat(content, " "), top, #lines, layout
end

-- Anchored to the window's BOTTOM edge, where the input box is always drawn: the
-- title bar makes cellHeight off by about one row, and measuring down from the
-- top would spread that error across the whole transcript.
function M.inputBorderY(frame, totalLines, topBorderIndex)
  if type(frame) ~= "table" or type(frame.y) ~= "number" or type(frame.h) ~= "number"
      or type(totalLines) ~= "number" or totalLines <= 0
      or type(topBorderIndex) ~= "number" then
    return nil
  end
  return frame.y + frame.h - (totalLines - topBorderIndex) * (frame.h / totalLines)
end

local function isContinuationByte(byte)
  return byte ~= nil and byte >= 128 and byte < 192
end

-- Prefix/suffix are matched byte-wise, then walked back to a UTF-8 boundary:
-- two Cyrillic letters share a lead byte, so an unsnapped split writes mojibake.
function M.cutDiff(before, after)
  if type(before) ~= "string" or type(after) ~= "string" or #after >= #before then
    return nil
  end
  local limit = #after
  local prefix = 0
  while prefix < limit and before:byte(prefix + 1) == after:byte(prefix + 1) do
    prefix = prefix + 1
  end
  while prefix > 0 and isContinuationByte(before:byte(prefix + 1)) do
    prefix = prefix - 1
  end
  local suffix = 0
  while suffix < limit - prefix
      and before:byte(#before - suffix) == after:byte(#after - suffix) do
    suffix = suffix + 1
  end
  -- One removed run tiles `after` exactly; a shortfall means the box changed some
  -- other way — a wrap that reflowed, a repaint, another tab — and the slice below
  -- would be text nobody cut.
  if prefix + suffix < limit then
    return nil
  end
  while suffix > 0 and isContinuationByte(before:byte(#before - suffix + 1)) do
    suffix = suffix - 1
  end
  local removed = before:sub(prefix + 1, #before - suffix)
  if removed == "" then
    return nil
  end
  return removed
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
  if actionForKey[key] then
    return actionForKey[key]
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
      action = actionForKey[item.key]
        or (item.convertPath and "convert" or "image-paste")
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
    if event.key ~= "v" and not actionForKey[event.key] then
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
local cutTimer
local cutInFlight = false
local selectAllInFlight = false
-- Claude's TUI creates a selection only on a left drag and drops it on a plain
-- click, so a cut fired with selectionLikely false deletes unselected draft text.
local selectionLikely = false
local selectionPoint
local dragSeen = false
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

local function clearSelectionState()
  selectionLikely = false
  selectionPoint = nil
end

local ttyScript = [[
tell application "Terminal"
  if (count of windows) is 0 then return ""
  return tty of selected tab of front window as text
end tell
]]

local scrapeScript = [[
tell application "Terminal"
  if (count of windows) is 0 then return ""
  return contents of selected tab of front window as text
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
    -- hs.task holds the callback ref until the userdata is finalized, so a callback
    -- that still references `task` when it returns pins the task forever (registry ->
    -- callback -> userdata cycle; hs.reload then spins in quadratic task_gc teardown).
    -- Clear the shared upvalue on every exit path, here and in refreshTty.
    local self = task
    task = nil
    if psTask == self then
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
    task = nil
  end
end

local function refreshTty(observed)
  if ttyTask or psTask or not started then
    return
  end

  local taskGeneration = generation
  local task
  task = hs.task.new("/usr/bin/osascript", function(exitCode, stdOut)
    local self = task
    task = nil
    if ttyTask == self then
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
    task = nil
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

local function emit(plan, app)
  if runtimeHooks and runtimeHooks.emit then
    runtimeHooks.emit(plan)
    return
  end
  hs.eventtap.keyStrokes(M.planBytes(plan), app)
end

local function foregroundVerdict(observed)
  if runtimeHooks and runtimeHooks.verdict then
    return runtimeHooks.verdict()
  end
  return M.cachedVerdict(observed or observeFrontmost(), cachedContext, now())
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

local function showAlert(message)
  if runtimeHooks and runtimeHooks.alert then
    runtimeHooks.alert(message)
  else
    hs.alert.show(message)
  end
end

local function showConvertAlert(message)
  local at = now()
  if lastAlertAt and at - lastAlertAt < alertThrottle then
    return
  end
  lastAlertAt = at
  showAlert(message)
end

local function defaultFileExists(path)
  local attributes = hs.fs.attributes(path)
  return attributes ~= nil and attributes.mode == "file"
end

local function writeImagePixels(path)
  local loadImage = runtimeHooks and runtimeHooks.loadImage or hs.image.imageFromPath
  local image = loadImage(path)
  if not image then
    return false
  end
  if runtimeHooks and runtimeHooks.writeImage then
    runtimeHooks.writeImage(image)
  else
    hs.pasteboard.writeObjects(image)
  end
  return true
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
    if not writeImagePixels(path) then
      postOriginal(original)
      showConvertAlert("Cmd+V: can't read image file — check Hammerspoon disk access")
      return
    end
    emit(M.imagePastePlan())
  end)
end

local function scrapeScreen(callback)
  if runtimeHooks and runtimeHooks.scrape then
    runtimeHooks.scrape(callback)
    return
  end
  local ok, res = hs.osascript.applescript(scrapeScript)
  callback(ok and tostring(res or "") or nil)
end

local function setPasteboardText(text)
  if runtimeHooks and runtimeHooks.writeText then
    runtimeHooks.writeText(text)
  else
    hs.pasteboard.setContents(text)
  end
end

local function targetWindowFrame(windowID)
  if runtimeHooks then
    return runtimeHooks.windowFrame and runtimeHooks.windowFrame(windowID) or nil
  end
  local window = windowID and hs.window.get(windowID) or nil
  return window and window:frame() or nil
end

-- Every unclear case (no frame, no drag point, a drag that ended on the border)
-- answers false: a transcript read as input costs one DEL the 1-char undo puts
-- back, while input read as transcript would leave the draft undeleted.
local function draggedInTranscript(original, topBorderIndex, totalLines)
  if not selectionPoint then
    return false
  end
  local frame = targetWindowFrame(original.observed and original.observed.windowID)
  local borderY = M.inputBorderY(frame, totalLines, topBorderIndex)
  return borderY ~= nil and type(selectionPoint.y) == "number"
    and selectionPoint.y < borderY
end

-- Once DEL is out the text is gone, so every later step fails silent rather than
-- putting a guess on the pasteboard; only a target that moved before the DEL
-- suppresses the deletion itself.
local function performCut(original)
  if not selectionLikely or cutInFlight then
    return
  end
  cutInFlight = true
  local function cutOnce()
    scrapeScreen(function(beforeScreen)
      if not currentTargetMatches(original, observeFrontmost()) then
        cutInFlight = false
        return
      end
      local before, topBorderIndex, totalLines = M.parseInputBox(beforeScreen)
      if before and draggedInTranscript(original, topBorderIndex, totalLines) then
        emit(M.copyChordPlan())
        clearSelectionState()
        cutInFlight = false
        return
      end
      if not before then
        -- The removed text is only recoverable by diffing this screen against the next
        -- one, so with no before-image the DEL stays unsent: a cut nobody could read
        -- back is worse than a Cmd+X that did nothing.
        if not beforeScreen then
          -- A scrape Terminal never answered stays broken for every later Cmd+X too,
          -- and unannounced it reads as the key having silently stopped working.
          showAlert("✂ cut: screen unreadable")
        end
        cutInFlight = false
        return
      end
      emit(M.cutPlan())
      clearSelectionState()
      local after = runtimeHooks and runtimeHooks.after or hs.timer.doAfter
      local attempts = 0
      local scrapeAfterScreen
      local function readAfterScreen()
        scrapeScreen(function(afterScreen)
          -- The pre-DEL check cannot cover this one: the tab may have changed
          -- during the delay, and the front window is whatever the scraper read.
          if not currentTargetMatches(original, observeFrontmost()) then
            cutInFlight = false
            return
          end
          local afterDraft = M.parseInputBox(afterScreen)
          local removed = M.cutDiff(before, afterDraft)
          if not removed then
            attempts = attempts + 1
            -- A box still reading as it did before the DEL has not repainted yet;
            -- streaming output on a loaded machine outruns a single delay.
            if attempts < 2 and afterDraft == before then
              scrapeAfterScreen()
            else
              cutInFlight = false
            end
            return
          end
          if isSingleCharacter(removed) then
            -- A single missing character is a no-selection backspace far more
            -- often than a deliberate 1-char cut: put it back and stay silent.
            -- chat:undo is a multi-level stack, safe only right after our DEL.
            emit(M.undoPlan())
            cutInFlight = false
            return
          end
          setPasteboardText(removed)
          cutInFlight = false
          showAlert("✂ cut " .. characterLength(removed) .. " chars")
        end)
      end
      scrapeAfterScreen = function()
        -- Kept in an upvalue: an unreferenced hs.timer is collectable before it fires.
        cutTimer = after(cutScrapeDelay, function()
          cutTimer = nil
          if not pcall(readAfterScreen) then
            cutInFlight = false
          end
        end)
      end
      scrapeAfterScreen()
    end)
  end
  -- The scrape is synchronous and costs ~40ms, so it runs a tick later: an
  -- event-tap callback that overruns its timeout gets the tap disabled.
  deferAsync(function()
    -- cutInFlight has to fall on every path: an error that leaves it set kills
    -- every later Cmd+X until Hammerspoon reloads.
    if not pcall(cutOnce) then
      cutInFlight = false
    end
  end)
end

local function postMouseEvent(kind, point)
  if runtimeHooks and runtimeHooks.mouse then
    runtimeHooks.mouse(kind, point)
    return
  end
  local types = hs.eventtap.event.types
  local eventType = kind == "down" and types.leftMouseDown
    or kind == "up" and types.leftMouseUp
    or types.leftMouseDragged
  hs.eventtap.event.newMouseEvent(eventType, point):post()
end

-- The whole drag has to stay inside roughly one frame: slower steps drew a
-- visible animation across the input box.
local function pauseBetweenDragSteps()
  if runtimeHooks and runtimeHooks.usleep then
    runtimeHooks.usleep(dragStepMicros)
    return
  end
  hs.timer.usleep(dragStepMicros)
end

local function draftDragPoints(frame, totalLines, layout)
  if type(layout) ~= "table" or not layout.hasText
      or type(layout.firstRow) ~= "number"
      or type(layout.columns) ~= "number" or layout.columns <= 0
      or type(frame) ~= "table" or type(frame.x) ~= "number"
      or type(frame.w) ~= "number" then
    return nil
  end
  local firstBottom = M.inputBorderY(frame, totalLines, layout.firstRow)
  local lastBottom = M.inputBorderY(frame, totalLines, layout.lastRow)
  if not firstBottom or not lastBottom then
    return nil
  end
  local halfRow = frame.h / totalLines / 2
  local cellWidth = frame.w / layout.columns
  local function center(column, rowBottom)
    return { x = frame.x + (column - 0.5) * cellWidth, y = rowBottom - halfRow }
  end
  -- Ending on the cell center left the last character out of the selection
  -- (seen live); aim near the cell's right edge instead.
  local endPoint = center(layout.lastColumn, lastBottom)
  endPoint.x = endPoint.x + 0.4 * cellWidth
  return center(layout.firstColumn, firstBottom), endPoint
end

-- Claude's TUI has no select-all key and renders a selection only for a real
-- drag, so Cmd+A finds the draft on the scraped screen and drags across it.
local function performSelectAll(original)
  if selectAllInFlight then
    return
  end
  selectAllInFlight = true
  local function selectOnce()
    scrapeScreen(function(screenText)
      if not currentTargetMatches(original, observeFrontmost()) then
        selectAllInFlight = false
        return
      end
      local _, _, totalLines, layout = M.parseInputBox(screenText)
      local frame = targetWindowFrame(original.observed and original.observed.windowID)
      local startPoint, endPoint = draftDragPoints(frame, totalLines, layout)
      if not startPoint then
        -- No drag happened, so an earlier drag's selection must not stay armed
        -- for Cmd+X: the user just asked for "everything", not that old sliver.
        clearSelectionState()
        selectAllInFlight = false
        return
      end
      -- Posted drag events move the physical pointer; put it back afterwards.
      local restoreMouse = not (runtimeHooks and runtimeHooks.mouse)
        and hs.mouse.absolutePosition() or nil
      postMouseEvent("down", startPoint)
      pauseBetweenDragSteps()
      postMouseEvent("dragged", {
        x = (startPoint.x + endPoint.x) / 2,
        y = (startPoint.y + endPoint.y) / 2,
      })
      pauseBetweenDragSteps()
      postMouseEvent("dragged", endPoint)
      pauseBetweenDragSteps()
      postMouseEvent("up", endPoint)
      if restoreMouse then
        -- The warp must not overtake the queued up event, or the selection
        -- stretches from the draft to wherever the pointer came from.
        pauseBetweenDragSteps()
        hs.mouse.absolutePosition(restoreMouse)
      end
      -- The tap need not see our own synthetic events for Cmd+X to work.
      selectionLikely = true
      selectionPoint = endPoint
      selectAllInFlight = false
    end)
  end
  -- Each pass blocks on a ~40ms scrape and then a posted drag, so a second one landing
  -- mid-flight would stall the event loop and interleave its drag with this one's.
  deferAsync(function()
    if not pcall(selectOnce) then
      selectAllInFlight = false
    end
  end)
end

-- Menu-driven entry points: the automation menu (iPad) reuses the same plans
-- instead of synthesizing modifier chords, which can drop on first press when
-- posted to an app; raw control bytes take the exact path the physical-key
-- flow above already proved out. menuPaste returns false when the clipboard
-- is textual - the caller then pastes natively (Cmd+V).
function M.menuCopy(app)
  emit(M.copyChordPlan(), app)
  clearSelectionState()
end

function M.menuPaste(app)
  local contentTypes = runtimeHooks and runtimeHooks.contentTypes
    or hs.pasteboard.contentTypes
  local ok, types = pcall(contentTypes)
  if not ok then
    return false
  end
  if M.containsImageType(types) then
    emit(M.imagePastePlan(), app)
    return true
  end
  local path = resolveFileImagePath(types)
  if path then
    if not writeImagePixels(path) then
      showConvertAlert("Paste: can't read image file — check Hammerspoon disk access")
      return false
    end
    emit(M.imagePastePlan(), app)
    return true
  end
  return false
end

-- Shared by the immediate path and the deferred queue, so both run the same six
-- actions the same way. Returns false for anything else (replay, policy-drop).
local function runAction(action, original, path)
  if action == "copy" then
    emit(M.copyChordPlan())
    clearSelectionState()
  elseif action == "undo" then
    emit(M.undoPlan())
    -- Undo, like any draft mutation, drops the TUI selection; a stale
    -- selectionLikely would send the next Cmd+X down the bare-DEL path.
    clearSelectionState()
  elseif action == "cut" then
    performCut(original)
  elseif action == "selectAll" then
    performSelectAll(original)
  elseif action == "image-paste" then
    emit(M.imagePastePlan())
    clearSelectionState()
  elseif action == "convert" then
    performConvert(path, original)
    clearSelectionState()
  else
    return false
  end
  return true
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
    if item.action == "replay" then
      postOriginal(original)
    elseif item.action == "policy-drop" then
      if runtimeHooks and runtimeHooks.drop then
        runtimeHooks.drop(original.event)
      end
    elseif not runAction(item.action, original, item.path) then
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
  local types = hs.eventtap.event.types
  local eventType = event:getType()
  if eventType ~= types.keyDown then
    if eventType == types.leftMouseDragged then
      -- Drags arrive at high frequency; invalidating the context here would put a
      -- ps/osascript round trip behind every pixel of a selection.
      dragSeen = true
      selectionPoint = event:location()
      return false
    end
    if eventType == types.leftMouseUp then
      -- Double- and triple-clicks select a word or a line without ever dragging.
      local clickState = event:getProperty(hs.eventtap.event.properties.mouseEventClickState)
      local selected = dragSeen or (type(clickState) == "number" and clickState >= 2)
      if not selected then
        clearSelectionState()
        return false
      end
      -- A selection made outside Claude must not survive into the next Cmd+X, or the
      -- DEL lands on an unselected draft; an unresolved verdict still arms, since the
      -- cut path re-checks the target before deleting. The AX round trip waits until
      -- there is a selection to arm: plain clicks are every click in every app.
      local observed = observeFrontmost()
      if observed.bundleID == terminalBundleID
          and foregroundVerdict(observed) ~= "not-claude" then
        selectionLikely = true
        if not dragSeen then
          selectionPoint = event:location()
        end
      else
        clearSelectionState()
      end
      return false
    end
    if eventType == types.leftMouseDown then
      dragSeen = false
    end
    invalidateAndRefresh()
    return false
  end

  local flags = event:getFlags()
  local key = flags:containExactly({ "cmd" }) and keyForCode[keyCode] or nil
  if not key then
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

  -- Convert is the only immediate action that can still replay its own event a
  -- tick later, so it alone pays for the copy and the pasteboard read here.
  local original = { observed = observed }
  if action == "convert" then
    original.event = event:copy()
    original.changeCount = pasteboardChangeCount()
  end
  runAction(action, original, convertPath)
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
  if cutTimer and cutTimer.stop then cutTimer:stop() end
  cutTimer = nil
  pendingState = idlePendingState()
  pendingOriginals = {}
  pendingNextID = 0
  pendingStartedAt = nil
  cachedContext = nil
  resolvedTty = nil
  resolvedObserved = nil
  repeatDecisions = {}
  lastAlertAt = nil
  cutInFlight = false
  selectAllInFlight = false
  dragSeen = false
  clearSelectionState()
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
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.leftMouseUp,
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
    local key = keyForCode[keyCode]
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
  if cutTimer and cutTimer.stop then cutTimer:stop() end
  cutTimer = nil
  cutInFlight = false
  selectAllInFlight = false
  dragSeen = false
  clearSelectionState()
  pendingState = nil
  pendingOriginals = {}
  pendingStartedAt = nil
  repeatDecisions = {}
  if rawget(_G, "hs") and hs.shutdownCallback == shutdownCallback then
    hs.shutdownCallback = previousShutdownCallback
  end
end

-- "claude" | "not-claude" | "uncertain" for the frontmost Terminal tab.
-- SendActions gates its copy chord on this so ctrl+x ctrl+y never reaches a
-- plain shell; "uncertain" there means fall back to a native Cmd+C.
function M.foregroundVerdict()
  return foregroundVerdict()
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
