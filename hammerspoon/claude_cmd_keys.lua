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
M.replayMarker = replayMarker
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

-- The string family a native Cmd+V would actually paste. An empty or unknown
-- pasteboard must not read as text: the replace flow would DEL the selection and
-- then put nothing back.
local textPasteTypes = {
  ["NSStringPboardType"] = true,
  ["public.plain-text"] = true,
  ["public.rtf"] = true,
  ["public.text"] = true,
  ["public.utf16-external-plain-text"] = true,
  ["public.utf16-plain-text"] = true,
  ["public.utf8-plain-text"] = true,
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

function M.containsTextType(types)
  if type(types) ~= "table" then
    return false
  end
  for _, contentType in ipairs(types) do
    if textPasteTypes[contentType] then
      return true
    end
  end
  return false
end

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

  local layout = { columns = 0, rows = {} }
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
    layout.rows[#layout.rows + 1] = { text = line, lead = lead, index = index }
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

-- Anchored to the frame's BOTTOM edge, where the input box is always drawn, so a
-- frame that still carries window chrome (see targetWindowFrame) degrades to a
-- drift that grows upward instead of misplacing the input box itself.
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

-- One keystroke per character, not per byte: the gesture's sentinel is a single
-- three-byte glyph and three separate key events would type three broken ones.
function M.planCharacters(plan)
  local text = M.planBytes(plan)
  local characters = {}
  local count = utf8 and utf8.len and utf8.offset and utf8.len(text)
  if not count then
    for index = 1, #text do
      characters[index] = text:sub(index, index)
    end
    return characters
  end
  for index = 1, count do
    local from = utf8.offset(text, index)
    local after = utf8.offset(text, index + 1) or #text + 1
    characters[index] = text:sub(from, after - 1)
  end
  return characters
end

-- A replace carries no shortcut key when the user typed a character, so it is
-- decided last: an image or convertible clipboard still owns Cmd+V.
local function decideAction(bundleID, claude, pasteboardTypes, key, convertPath, replace)
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
  if replace then
    return "replace"
  end
  return "pass"
end

function M.decide(bundleID, psOutput, pasteboardTypes, key, convertPath, replace)
  return decideAction(bundleID, M.isClaudeForeground(psOutput), pasteboardTypes, key,
    convertPath, replace)
end

local function contextIdentityMatches(observed, cached)
  return observed.bundleID == terminalBundleID
    and observed.tabElement ~= nil
    and cached.bundleID == observed.bundleID
    and cached.windowID == observed.windowID
    and cached.tabIndex == observed.tabIndex
    and cached.tabElement == observed.tabElement
end

function M.decideCached(observed, cached, pasteboardTypes, key, timestamp, convertPath, replace)
  local verdict = M.cachedVerdict(observed, cached, timestamp)
  if verdict == "uncertain" then
    return "pass"
  end
  return decideAction(observed.bundleID, verdict == "claude", pasteboardTypes, key,
    convertPath, replace)
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
      -- Copy is safe wherever it ends up; everything else would mutate a draft that
      -- is no longer the one the user aimed at — a replay of a held paste or of the
      -- key behind it types into whatever is in front now.
      action = item.key == "c" and "replay" or "policy-drop"
    elseif verdict == "claude" then
      action = actionForKey[item.key]
        or (item.convertPath and "convert")
        or (item.replace and "replace")
        or (item.hold and "replay")
        or "image-paste"
    else
      action = "replay"
    end
    actions[#actions + 1] = {
      id = item.id,
      key = item.key,
      action = action,
      path = item.convertPath,
      replace = item.replace,
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
    -- A typed replace has no shortcut key at all, and a hold is any key at all: both
    -- earn their place in the queue from the flow they are waiting behind.
    if not event.replace and not event.hold then
      if event.key ~= "v" and not actionForKey[event.key] then
        return state, { consume = false }
      end
      if event.key == "v" and event.image ~= true then
        return state, { consume = false }
      end
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
    queue[#queue + 1] = {
      id = event.id,
      key = event.key,
      convertPath = event.convertPath,
      replace = event.replace,
      hold = event.hold,
    }
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
local afterCutQueue = {}
local replaceTimer
local replaceInFlight = false
local replaceOriginal
local replaceContext
local replaceQueue = {}
local replaceContinuation
local cutContinuation
local selectAllInFlight = false
local gestureInFlight = false
-- Set by anything that reaches the draft between the gesture's sentinel and the DEL
-- that owes its removal: that DEL would take the newcomer instead. Declared with the
-- flag it belongs to, not with the gesture code, since runAction reads it from above.
local gestureDraftTouched = false
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
local skipRepeatCache = false
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

-- One table, not one local per field: this chunk sits at Lua's 200-local ceiling, the
-- same reason axGrid exists.
local shared = {
  latencyDropped = 0,
  -- Pixels the pointer may sit away from where our own last event left it and still
  -- count as ours rather than as a hand on the trackpad.
  pointerDriftLimit = 3,
  gestureWatchdogDelay = 2.5,
  -- Bumped once per gesture and captured by every closure that gesture arms. A scrape
  -- Terminal answers late belongs to the flight that asked for it and to no other: read
  -- against the flag alone it would post its DEL into the next gesture's draft and tear
  -- down a flight that is still holding one.
  gestureFlight = 0,
}

-- The word gesture's cache describes a selection this flag stands for, so the two
-- die together: any key or mouse activity that drops one has ended the gesture.
local wordGestureState

local function clearSelectionState()
  selectionLikely = false
  selectionPoint = nil
  wordGestureState = nil
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

-- Input-latency instrumentation. Everything the tap callback does per event is a
-- handful of arithmetic on numbers already in registers plus six writes into these
-- preallocated arrays: no table, string or timer may ever be created here, since the
-- cost of measuring the delay would otherwise become part of the delay.
local latencyCapacity = 4096
local latencyColdGapNs = 2000000000
-- A gap wider than this is a clock mismatch, not a delay: synthetic events carry a
-- zero timestamp, so their "delay" is the whole uptime. Recorded as missing and
-- counted. Deliberately far above any delay worth measuring: a ceiling near the
-- stalls this instrument exists to catch would silently discard exactly those.
local latencyQueueCeilingNs = 30000000000
local latencyMissing = 0 / 0
local commandFlagMask = 1 << 20
local alternateFlagMask = 1 << 19
local latencyQueueNs = {}
local latencyProcessNs = {}
local latencyClassCodes = {}
local latencyGapNs = {}
local latencyWrites = 0
local latencyPreviousAt = 0

for slot = 1, latencyCapacity do
  latencyQueueNs[slot] = 0
  latencyProcessNs[slot] = 0
  latencyClassCodes[slot] = 0
  latencyGapNs[slot] = 0
end

local function latencyClassCode(eventType, rawFlags, marker)
  local chord = ((rawFlags or 0) & (commandFlagMask | alternateFlagMask)) ~= 0 and 2 or 0
  local replayed = marker == replayMarker and 1 or 0
  return (eventType or 0) * 4 + chord + replayed
end

local function latencyRecord(enteredAt, exitedAt, stamp, classCode)
  local slot = latencyWrites % latencyCapacity + 1
  -- A synthetic event carries no timestamp at all, so subtracting it would measure the
  -- uptime: within the first half-minute after a boot that lands under the ceiling and
  -- reads as a real stall. Missing is missing, whatever the clock happens to be.
  local queued = stamp and stamp ~= 0 and enteredAt - stamp or nil
  if queued and queued >= 0 and queued < latencyQueueCeilingNs then
    latencyQueueNs[slot] = queued
  else
    latencyQueueNs[slot] = latencyMissing
    shared.latencyDropped = shared.latencyDropped + 1
  end
  latencyProcessNs[slot] = exitedAt - enteredAt
  latencyClassCodes[slot] = classCode
  -- Zero previous stamp yields an uptime-sized gap, which is exactly the cold bucket
  -- the very first event belongs in — the branch that would say so is not worth paying.
  latencyGapNs[slot] = enteredAt - latencyPreviousAt
  latencyPreviousAt = enteredAt
  latencyWrites = latencyWrites + 1
end

local function latencyObserve(event, enteredAt, exitedAt)
  latencyRecord(enteredAt, exitedAt, event:timestamp(),
    latencyClassCode(event:getType(), event:rawFlags(),
      replayProperty and event:getProperty(replayProperty)))
end

local function latencyTypeNames()
  local names = {}
  local types = rawget(_G, "hs") and hs.eventtap and hs.eventtap.event
    and hs.eventtap.event.types or {}
  for name, value in pairs(types) do
    if type(value) == "number" then names[value] = name end
  end
  return names
end

local function latencyPercentile(sorted, fraction)
  local count = #sorted
  if count == 0 then return nil end
  local rank = math.ceil(fraction * count)
  if rank < 1 then rank = 1 end
  if rank > count then rank = count end
  return sorted[rank] / 1000000
end

local function latencySummary(samples)
  table.sort(samples)
  return {
    count = #samples,
    p50 = latencyPercentile(samples, 0.5),
    p90 = latencyPercentile(samples, 0.9),
    p99 = latencyPercentile(samples, 0.99),
    max = latencyPercentile(samples, 1),
  }
end

function M.latencyReset()
  latencyWrites = 0
  latencyPreviousAt = 0
  shared.latencyDropped = 0
end

-- Rows of { class, cold, count, queue, process }, all times already in ms. The
-- sorting and the percentiles live here, never in the recorder.
function M.latencyRows()
  local recorded = latencyWrites < latencyCapacity and latencyWrites or latencyCapacity
  local names = latencyTypeNames()
  local groups = {}
  local order = {}
  local totals = {}
  local function group(store, key, label, cold)
    local entry = store[key]
    if not entry then
      entry = { label = label, cold = cold, queue = {}, process = {} }
      store[key] = entry
      order[#order + 1] = entry
    end
    return entry
  end
  for slot = 1, recorded do
    local code = latencyClassCodes[slot]
    local gap = latencyGapNs[slot]
    -- Written as a negation so a missing gap (no previous event) reads as cold.
    local cold = not (gap <= latencyColdGapNs)
    local eventType = code // 4
    local label = (names[eventType] or ("type-" .. eventType))
      .. ((code & 2) ~= 0 and "+chord" or "")
      .. ((code & 1) ~= 0 and "+replay" or "")
    local entry = group(groups, code * 2 + (cold and 1 or 0), label, cold)
    local total = group(totals, cold and 1 or 0, "ALL", cold)
    local queued = latencyQueueNs[slot]
    local processed = latencyProcessNs[slot]
    if queued == queued then
      entry.queue[#entry.queue + 1] = queued
      total.queue[#total.queue + 1] = queued
    end
    entry.process[#entry.process + 1] = processed
    total.process[#total.process + 1] = processed
  end
  local rows = {}
  for _, entry in ipairs(order) do
    rows[#rows + 1] = {
      class = entry.label,
      cold = entry.cold,
      count = #entry.process,
      queue = latencySummary(entry.queue),
      process = latencySummary(entry.process),
    }
  end
  table.sort(rows, function(left, right)
    local leftAll = left.class == "ALL" and 1 or 0
    local rightAll = right.class == "ALL" and 1 or 0
    if leftAll ~= rightAll then return leftAll < rightAll end
    if left.class ~= right.class then return left.class < right.class end
    return (left.cold and 0 or 1) < (right.cold and 0 or 1)
  end)
  return rows
end

local function latencyCell(value)
  if value == nil then return "       -" end
  return string.format("%8.2f", value)
end

function M.latencyReport()
  local rows = M.latencyRows()
  local window = latencyWrites < latencyCapacity and latencyWrites or latencyCapacity
  local lines = {
    string.format("claude_cmd_keys input latency: %d events in window, %d recorded since reset (ring %d)",
      window, latencyWrites, latencyCapacity),
    "hot path per event: 2 clock reads, 4 event field reads, ~12 arithmetic ops, 6 writes, no allocation (~0.8us measured)",
    string.format("queue = tap entry minus event timestamp; proc = time inside the tap callback; ms, cold = first event after a gap > %.2fs",
      latencyColdGapNs / 1000000000),
  }
  if shared.latencyDropped > 0 then
    lines[#lines + 1] = string.format(
      "dropped: %d queue readings outside [0, %.0fs) — synthetic zero timestamps and clock mismatches",
      shared.latencyDropped, latencyQueueCeilingNs / 1000000000)
  end
  if #rows == 0 then
    lines[#lines + 1] = "no events recorded"
    return table.concat(lines, "\n")
  end
  lines[#lines + 1] = string.format("%-22s %-4s %6s %6s  %8s %8s %8s %8s  %8s %8s %8s %8s",
    "class", "warm", "n", "qn", "q p50", "q p90", "q p99", "q max",
    "t p50", "t p90", "t p99", "t max")
  for _, row in ipairs(rows) do
    lines[#lines + 1] = string.format("%-22s %-4s %6d %6d  %s %s %s %s  %s %s %s %s",
      row.class, row.cold and "cold" or "warm", row.count, row.queue.count,
      latencyCell(row.queue.p50), latencyCell(row.queue.p90),
      latencyCell(row.queue.p99), latencyCell(row.queue.max),
      latencyCell(row.process.p50), latencyCell(row.process.p90),
      latencyCell(row.process.p99), latencyCell(row.process.max))
  end
  return table.concat(lines, "\n")
end

M.latencyCapacity = latencyCapacity
M.latencyClassCode = latencyClassCode
M.latencyRecord = latencyRecord
M.latencyObserve = latencyObserve
-- Storage length, so a test can prove the ring overwrites instead of growing.
function M.latencyLength()
  return #latencyProcessNs
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

-- Marked like our mouse events and replays, and for the same reason: hs.eventtap
-- posts through the very tap this module installed, so an unmarked keystroke of ours
-- comes back indistinguishable from the user's. The cut and replace flight windows
-- would then hold our own DEL as a key typed behind them, and the gesture would read
-- its own sentinel as a draft the user typed into.
local function emit(plan, app)
  if runtimeHooks and runtimeHooks.emit then
    runtimeHooks.emit(plan)
    return
  end
  for _, character in ipairs(M.planCharacters(plan)) do
    for _, isDown in ipairs({ true, false }) do
      local event = hs.eventtap.event.newKeyEvent(0, isDown)
      event:setUnicodeString(character)
      if replayProperty then
        event:setProperty(replayProperty, replayMarker)
      end
      event:post(app)
    end
  end
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

-- A replay runs up to ~350ms after the press, by which time the real keyUp has
-- long since gone through on its own: the copy would arrive as a key that is
-- pressed and never released, carrying a timestamp older than the DEL and undo
-- posted ahead of it. Restamping it and pairing it with its own keyUp is the only
-- difference left between this and a physical press.
local function postOriginal(original)
  if runtimeHooks and runtimeHooks.post then
    runtimeHooks.post(original.event)
    return
  end
  local event = original.event
  event:setProperty(replayProperty, replayMarker)
  event:timestamp(hs.timer.absoluteTime())
  event:post()
  local release = event:copy()
  release:setType(hs.eventtap.event.types.keyUp)
  release:post()
end

-- Consuming a press caches "consume" for its keycode, so every path that lets the
-- press go without running its action has to drop that cache too or the autorepeats
-- of a key the user is still holding are eaten with it.
local function forgetRepeat(original)
  if original and original.keyCode then
    repeatDecisions[original.keyCode] = nil
  end
end

-- Keys the cut flow made wait: posting them mid-cut would put text between the two
-- scrapes the DEL is measured against, and cutDiff would read it as deleted draft.
local function flushAfterCut()
  local held = afterCutQueue
  afterCutQueue = {}
  local observed
  for _, item in ipairs(held) do
    forgetRepeat(item)
    observed = observed or observeFrontmost()
    if currentTargetMatches(item, observed) then
      postOriginal(item)
    elseif runtimeHooks and runtimeHooks.drop then
      runtimeHooks.drop(item.event)
    end
  end
end

local function endCut()
  cutInFlight = false
  flushAfterCut()
  local continuation = cutContinuation
  cutContinuation = nil
  if continuation then
    continuation()
  end
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

-- One table, not one local per helper: this chunk sits at Lua's 200-local ceiling.
local axGrid = {
  cellHeight = { 8, 30 },
  cellWidth = { 3, 20 },
  bottomSlackRows = 2,
  edgeSlack = 1,
  lineWalk = 4,
  anchorTtl = 2,
  slowAnchor = 0.25,
  breakerSeconds = 60,
}

function axGrid.descendant(root, role)
  local queue, visited = { root }, 0
  while #queue > 0 and visited < 256 do
    local node = table.remove(queue, 1)
    visited = visited + 1
    if node.attributeValue then
      if node:attributeValue("AXRole") == role then
        return node
      end
      for _, child in ipairs(node:attributeValue("AXChildren") or {}) do
        queue[#queue + 1] = child
      end
    end
  end
  return nil
end

-- Terminal's AXScrollArea is the cell grid alone; the window frame adds ~68px of
-- title and tab chrome above it, which row math would spread over every row.
function axGrid.scrollArea(window)
  local root = window and axuielement and axuielement.windowElement(window) or nil
  return root and axGrid.descendant(root, "AXScrollArea") or nil
end

function M.gridFrame(axFrame, windowFrame)
  if type(axFrame) == "table" and type(axFrame.w) == "number" and axFrame.w > 0
      and type(axFrame.h) == "number" and axFrame.h > 0
      and type(axFrame.x) == "number" and type(axFrame.y) == "number" then
    return axFrame
  end
  return windowFrame
end

-- The scroll area's height over its row count overestimates the cell, because the
-- grid sits inside it with pads (measured: 14.185 against a real 14.0), so every row
-- drifts down — by a whole row at the bottom, where the input box is. One character's
-- AX bounds carry the true cell and the anchor line's row pins the grid top: together
-- they make a virtual frame that turns the unchanged row math exact.
function M.anchoredGridFrame(bounds, linesBelowAnchor, totalLines, columns, fallback)
  if type(bounds) ~= "table" or type(bounds.x) ~= "number" or type(bounds.y) ~= "number"
      or type(bounds.w) ~= "number" or type(bounds.h) ~= "number"
      or type(linesBelowAnchor) ~= "number" or linesBelowAnchor < 0
      or type(totalLines) ~= "number" or totalLines <= 0 then
    return nil
  end
  if bounds.h < axGrid.cellHeight[1] or bounds.h > axGrid.cellHeight[2]
      or bounds.w < axGrid.cellWidth[1] or bounds.w > axGrid.cellWidth[2] then
    return nil
  end
  local anchorRow = totalLines - linesBelowAnchor
  if anchorRow < 1 then
    return nil
  end
  local usableFallback = type(fallback) == "table" and type(fallback.x) == "number"
    and type(fallback.y) == "number" and type(fallback.w) == "number"
    and type(fallback.h) == "number"
  local frame = {
    x = usableFallback and fallback.x or nil,
    y = bounds.y + bounds.h - anchorRow * bounds.h,
    w = usableFallback and fallback.w or nil,
    h = totalLines * bounds.h,
  }
  -- Column-blind callers only read y; keeping the fallback's x/w beats inventing a
  -- width from a count nobody passed.
  if type(columns) == "number" and columns > 0 then
    frame.x, frame.w = bounds.x, columns * bounds.w
  end
  if type(frame.x) ~= "number" or type(frame.w) ~= "number" then
    return nil
  end
  if usableFallback then
    -- An anchor read from another tab, or a scrape whose line count no longer matches
    -- the grid, puts the cell or the frame somewhere the grid cannot be; the caller's
    -- ladder is merely imprecise, while a bad anchor clicks at random.
    if bounds.x < fallback.x - axGrid.edgeSlack
        or bounds.y < fallback.y - axGrid.edgeSlack
        or bounds.x + bounds.w > fallback.x + fallback.w + axGrid.edgeSlack
        or bounds.y + bounds.h > fallback.y + fallback.h + axGrid.edgeSlack then
      return nil
    end
    if math.abs((frame.y + frame.h) - (fallback.y + fallback.h))
        > axGrid.bottomSlackRows * bounds.h then
      return nil
    end
  end
  return frame
end

-- The buffer's last line always renders on the last grid row, so a line L sits on
-- row totalLines - (Llast - L). A trailing empty line has no character to measure,
-- and the walk up whole lines keeps that offset in step with what it measured.
function axGrid.cellBounds(textArea)
  if not textArea then
    return nil
  end
  local characters = textArea:attributeValue("AXNumberOfCharacters")
  if type(characters) ~= "number" or characters < 1 then
    return nil
  end
  local lastLine = textArea:parameterizedAttributeValue("AXLineForIndex", characters - 1)
  if type(lastLine) ~= "number" then
    return nil
  end
  for offset = 0, axGrid.lineWalk do
    local line = lastLine - offset
    if line < 0 then
      break
    end
    local range = textArea:parameterizedAttributeValue("AXRangeForLine", line)
    local location = type(range) == "table" and range.location or nil
    local length = type(range) == "table" and range.length or nil
    if type(location) == "number" and type(length) == "number" and length >= 1 then
      local bounds = textArea:parameterizedAttributeValue("AXBoundsForRange",
        { location = location, length = 1 })
      if type(bounds) == "table" and type(bounds.w) == "number" and bounds.w > 0
          and type(bounds.h) == "number" and bounds.h > 0 then
        return bounds, offset
      end
    end
  end
  return nil
end

-- AXBoundsForRange and the two lookups ahead of it are synchronous, and a Terminal
-- busy with a stream can take hundreds of milliseconds to answer them: the runloop
-- that waits is the one carrying the user's next keystroke. So a burst of gestures
-- walks AX once, and a walk that did stall stands the whole AX path down for a
-- minute — the caller's fallback ladder is merely imprecise, never late.
-- The bounds are absolute screen pixels, so where the window sits is part of what was
-- measured: a window dragged inside the TTL keeps the same id, row count and columns,
-- and the cached anchor would then place every click at its old position.
function axGrid.anchor(windowID, totalLines, columns, origin, walk, clock)
  local at = clock()
  local originX = type(origin) == "table" and origin.x or nil
  local originY = type(origin) == "table" and origin.y or nil
  local cache = axGrid.cache
  local age = cache and at - cache.at or nil
  if cache and cache.windowID == windowID and cache.totalLines == totalLines
      and cache.columns == columns and cache.originX == originX
      and cache.originY == originY and age >= 0 and age < axGrid.anchorTtl then
    return cache.bounds, cache.linesBelowAnchor
  end
  if axGrid.breakerUntil and at < axGrid.breakerUntil then
    return nil
  end
  axGrid.breakerUntil = nil
  local bounds, linesBelowAnchor = walk()
  local spent = clock() - at
  if spent > axGrid.slowAnchor then
    -- Answered, so this reading is still used; it is the NEXT gesture that must not
    -- pay the same wait, and a cached stall would only postpone the same decision.
    axGrid.cache = nil
    axGrid.breakerUntil = at + spent + axGrid.breakerSeconds
  elseif bounds then
    axGrid.cache = { windowID = windowID, totalLines = totalLines, columns = columns,
      originX = originX, originY = originY,
      bounds = bounds, linesBelowAnchor = linesBelowAnchor, at = at }
  end
  return bounds, linesBelowAnchor
end

-- The BFS that finds the scroll area, and the AXFrame read behind it, are the same
-- synchronous AX the anchor walk is fenced behind — and they ran per gesture whatever
-- that fence said, so a burst still paid a full walk each and an open breaker still
-- stalled the runloop here. Same cache, same breaker: the resolved area is pinned to
-- the window box it was read for, because an area kept across a move or a resize would
-- place the grid where the window no longer is.
function axGrid.scroll(windowID, origin, resolve, clock)
  local at = clock()
  local box = type(origin) == "table" and origin or {}
  local cache = axGrid.scrollCache
  local age = cache and at - cache.at or nil
  if cache and cache.windowID == windowID and age >= 0 and age < axGrid.anchorTtl
      and cache.x == box.x and cache.y == box.y
      and cache.w == box.w and cache.h == box.h then
    return cache.element, cache.frame
  end
  if axGrid.breakerUntil and at < axGrid.breakerUntil then
    return nil
  end
  axGrid.breakerUntil = nil
  local element, frame = resolve()
  local spent = clock() - at
  if spent > axGrid.slowAnchor then
    axGrid.scrollCache = nil
    axGrid.breakerUntil = at + spent + axGrid.breakerSeconds
  else
    -- A window with no scroll area at all is cached too: re-walking 256 nodes per
    -- gesture to be told "none" again is the cost this fence exists to remove.
    axGrid.scrollCache = { windowID = windowID, x = box.x, y = box.y, w = box.w, h = box.h,
      element = element, frame = frame, at = at }
  end
  return element, frame
end

M.axAnchor = axGrid.anchor
M.axScroll = axGrid.scroll

function M.axAnchorReset()
  axGrid.cache = nil
  axGrid.scrollCache = nil
  axGrid.breakerUntil = nil
end

local function targetWindowFrame(windowID, totalLines, columns)
  if runtimeHooks then
    return runtimeHooks.windowFrame
      and runtimeHooks.windowFrame(windowID, totalLines, columns) or nil
  end
  local window = windowID and hs.window.get(windowID) or nil
  if not window then
    return nil
  end
  -- The window box is the one reading not behind the fence: with the breaker open it
  -- is the whole fallback, which keeps that path merely imprecise instead of late.
  local windowFrame = window:frame()
  local scrollArea, scrollFrame = axGrid.scroll(windowID, windowFrame, function()
    local area = axGrid.scrollArea(window)
    return area, area and area:attributeValue("AXFrame") or nil
  end, now)
  local fallback = M.gridFrame(scrollFrame, windowFrame)
  local bounds, linesBelowAnchor = axGrid.anchor(windowID, totalLines, columns, fallback,
    function()
      return axGrid.cellBounds(scrollArea and axGrid.descendant(scrollArea, "AXTextArea") or nil)
    end, now)
  return M.anchoredGridFrame(bounds, linesBelowAnchor, totalLines, columns, fallback)
    or fallback
end

-- Every unclear case (no frame, no drag point, a drag that ended on the border)
-- answers false: a transcript read as input costs one DEL the 1-char undo puts
-- back, while input read as transcript would leave the draft undeleted.
-- The columns come from the caller's own parse: keyed without them, this lookup misses
-- the entry every gesture caches and overwrites it, so alternating Cmd+X with a chord
-- would pay a fresh AX walk on each.
local function draggedInTranscript(original, topBorderIndex, totalLines, columns)
  if not selectionPoint then
    return false
  end
  local frame = targetWindowFrame(original.observed and original.observed.windowID, totalLines,
    columns)
  local borderY = M.inputBorderY(frame, totalLines, topBorderIndex)
  return borderY ~= nil and type(selectionPoint.y) == "number"
    and selectionPoint.y < borderY
end

-- Once DEL is out the text is gone, so every later step fails silent rather than
-- putting a guess on the pasteboard; only a target that moved before the DEL
-- suppresses the deletion itself.
local function performCut(original)
  -- Both flows own the same DEL-then-diff window; interleaved, each would read
  -- the other's deletion as its own.
  if not selectionLikely or cutInFlight or replaceInFlight then
    return
  end
  cutInFlight = true
  local function cutOnce()
    scrapeScreen(function(beforeScreen)
      if not currentTargetMatches(original, observeFrontmost()) then
        endCut()
        return
      end
      local before, topBorderIndex, totalLines, layout = M.parseInputBox(beforeScreen)
      if before and draggedInTranscript(original, topBorderIndex, totalLines,
          layout and layout.columns) then
        emit(M.copyChordPlan())
        clearSelectionState()
        endCut()
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
        endCut()
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
            endCut()
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
              endCut()
            end
            return
          end
          if isSingleCharacter(removed) then
            -- A single missing character is a no-selection backspace far more
            -- often than a deliberate 1-char cut: put it back and stay silent.
            -- chat:undo is a multi-level stack, safe only right after our DEL.
            emit(M.undoPlan())
            endCut()
            return
          end
          setPasteboardText(removed)
          endCut()
        end)
      end
      scrapeAfterScreen = function()
        -- Kept in an upvalue: an unreferenced hs.timer is collectable before it fires.
        cutTimer = after(cutScrapeDelay, function()
          cutTimer = nil
          if not pcall(readAfterScreen) then
            endCut()
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
      endCut()
    end
  end)
end

local replaceQueueLimit = 32

local function stopReplaceTimer()
  if replaceTimer and replaceTimer.stop then replaceTimer:stop() end
  replaceTimer = nil
end

-- Actions from the same resolution that had to wait out the flow: a cut dispatched
-- alongside a replace would otherwise read the replace's own DEL as its selection.
local function runReplaceContinuation()
  local continuation = replaceContinuation
  replaceContinuation = nil
  if continuation then
    continuation()
  end
end

-- The tab moved out from under the DEL, and every key this flow is holding was
-- typed at the draft that is no longer in front.
local function abandonReplace()
  stopReplaceTimer()
  forgetRepeat(replaceOriginal)
  for _, item in ipairs(replaceQueue) do
    forgetRepeat(item)
    if item.mergedPending and runtimeHooks and runtimeHooks.drop then
      runtimeHooks.drop(item.event)
    end
  end
  replaceOriginal = nil
  replaceContext = nil
  replaceQueue = {}
  replaceInFlight = false
  clearSelectionState()
  runReplaceContinuation()
end

-- The held key goes out first and everything typed behind it follows in order,
-- optional trigger last, so the draft reads the way it was typed even though the
-- first key waited ~350ms.
local function finishReplace(trigger)
  stopReplaceTimer()
  local sequence = {}
  if replaceOriginal then
    sequence[#sequence + 1] = replaceOriginal
  end
  for _, item in ipairs(replaceQueue) do
    sequence[#sequence + 1] = item
  end
  if trigger then
    sequence[#sequence + 1] = trigger
  end
  local context = replaceContext
  replaceOriginal = nil
  replaceContext = nil
  replaceQueue = {}
  replaceInFlight = false
  for _, item in ipairs(sequence) do
    forgetRepeat(item)
  end
  -- The flow's own target checks cannot cover the moment of the replay itself, and
  -- posting into whatever is in front now would type the user's keys at another app.
  local observed = context and observeFrontmost() or nil
  if context and not sameObserved(context, observed) then
    clearSelectionState()
  end
  for _, item in ipairs(sequence) do
    if currentTargetMatches(item, observed) then
      postOriginal(item)
    elseif runtimeHooks and runtimeHooks.drop then
      runtimeHooks.drop(item.event)
    end
  end
  runReplaceContinuation()
end

-- The TUI has no replace-selection edit, so the selection is deleted and the key
-- the user actually pressed — a character or their own Cmd+V — is replayed into
-- the hole. DEL on a live selection leaves the cursor at the deletion point
-- (measured with the cursor before, inside and after it), which is what makes the
-- replay a true replace. Nothing here writes the pasteboard, and only a tab that
-- moved loses the keystroke.
local function performReplace(original)
  if replaceInFlight then
    -- One pending resolve can turn several consumed keys into replaces at once;
    -- the later ones join the running flow's queue instead of vanishing with it.
    if sameObserved(replaceContext, original.observed)
        and #replaceQueue < replaceQueueLimit then
      replaceQueue[#replaceQueue + 1] = original
    end
    return
  end
  if not selectionLikely or cutInFlight then
    -- The keystroke is already consumed, so it has to leave as itself: a plain
    -- native keypress beats silently eating what the user typed.
    forgetRepeat(original)
    if cutInFlight then
      afterCutQueue[#afterCutQueue + 1] = original
    else
      postOriginal(original)
    end
    clearSelectionState()
    return
  end
  replaceInFlight = true
  replaceOriginal = original
  replaceContext = original.observed
  local function replaceOnce()
    scrapeScreen(function(beforeScreen)
      if not replaceInFlight then
        return
      end
      if not currentTargetMatches(original, observeFrontmost()) then
        abandonReplace()
        return
      end
      local before, topBorderIndex, totalLines, layout = M.parseInputBox(beforeScreen)
      -- A transcript selection is not draft text, and an unreadable screen gives
      -- nothing to verify a DEL against; both fall back to the bare keystroke the
      -- key would have delivered on its own, so nothing is silently broken.
      if not before or draggedInTranscript(original, topBorderIndex, totalLines,
          layout and layout.columns) then
        clearSelectionState()
        finishReplace()
        return
      end
      emit(M.cutPlan())
      clearSelectionState()
      local after = runtimeHooks and runtimeHooks.after or hs.timer.doAfter
      local attempts = 0
      local scrapeAfterScreen
      local function readAfterScreen()
        scrapeScreen(function(afterScreen)
          if not replaceInFlight then
            return
          end
          if not currentTargetMatches(original, observeFrontmost()) then
            abandonReplace()
            return
          end
          local afterDraft = M.parseInputBox(afterScreen)
          local removed = M.cutDiff(before, afterDraft)
          if not removed and attempts < 1 and afterDraft == before then
            attempts = attempts + 1
            scrapeAfterScreen()
            return
          end
          -- No 1-char undo guard here, unlike the cut: selecting a single character
          -- and typing over it is ordinary, and resurrecting it would corrupt every
          -- such replace. Selection state now dies with each keystroke, so the stale
          -- flag this would have caught costs one character in a rare corner instead.
          finishReplace()
        end)
      end
      scrapeAfterScreen = function()
        replaceTimer = after(cutScrapeDelay, function()
          replaceTimer = nil
          -- A key that released the flow early already posted everything it held.
          if not replaceInFlight then
            return
          end
          if not pcall(readAfterScreen) then
            finishReplace()
          end
        end)
      end
      scrapeAfterScreen()
    end)
  end
  deferAsync(function()
    if not pcall(replaceOnce) then
      finishReplace()
    end
  end)
end

local function postMouseEvent(kind, point, clickState)
  if runtimeHooks and runtimeHooks.mouse then
    runtimeHooks.mouse(kind, point, clickState)
    return
  end
  local types = hs.eventtap.event.types
  local eventType = kind == "down" and types.leftMouseDown
    or kind == "up" and types.leftMouseUp
    or types.leftMouseDragged
  local mouseEvent = hs.eventtap.event.newMouseEvent(eventType, point)
  if clickState then
    mouseEvent:setProperty(hs.eventtap.event.properties.mouseEventClickState, clickState)
  end
  -- Marked like our replayed keystrokes: the opening click of a double-click looks
  -- like a plain click to the tap, which would clear the selection state the very
  -- same synthesis is about to arm.
  if replayProperty then
    mouseEvent:setProperty(replayProperty, replayMarker)
  end
  mouseEvent:post()
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

-- Both choreographies warp the pointer back where they found it, and a burst of
-- gestures runs them back to back: saving one home each would take the previous
-- choreography's click point for home and strand the pointer in the draft. During a
-- burst both hands are on the chord and the physical mouse cannot move, so one home
-- serves the whole burst and is dropped once the burst goes quiet or the user takes
-- the mouse back.
local pointerSettleDelay = 0.15
local pointerHomeIdle = 0.5
local pointerHome
local pointerSettleTimer
local pointerClearTimer

local function stopPointerTimer(timer)
  if timer and timer.stop then timer:stop() end
  return nil
end

local function clearPointerHome()
  pointerSettleTimer = stopPointerTimer(pointerSettleTimer)
  pointerClearTimer = stopPointerTimer(pointerClearTimer)
  pointerHome = nil
end

local function takePointerHome()
  if runtimeHooks then
    if not runtimeHooks.pointer then
      return nil
    end
    pointerHome = pointerHome or runtimeHooks.pointer()
    return pointerHome
  end
  pointerHome = pointerHome or hs.mouse.absolutePosition()
  return pointerHome
end

-- Where the pointer is against where our own choreography left it. Euclidean, so a
-- diagonal nudge counts like a straight one; an unknown endpoint is not drift, which
-- keeps the warp on its old unconditional behaviour.
function M.pointerDrifted(current, expected)
  if type(current) ~= "table" or type(expected) ~= "table"
      or type(current.x) ~= "number" or type(current.y) ~= "number"
      or type(expected.x) ~= "number" or type(expected.y) ~= "number" then
    return false
  end
  local dx, dy = current.x - expected.x, current.y - expected.y
  return dx * dx + dy * dy > shared.pointerDriftLimit * shared.pointerDriftLimit
end

-- The clicks we post are handled by the window server after this runloop turn, so a
-- warp issued here is overtaken by its own up event and the pointer stays on the word
-- that was double-clicked; no sleep makes that safe. The warp waits for a quiet gap
-- instead: a burst re-arms this timer per choreography and pays one warp at its end,
-- and home outlives the warp by an idle window so the next press of a burst never
-- re-reads a pointer with a warp still in flight.
local function schedulePointerReturn()
  local after = runtimeHooks and runtimeHooks.after or hs.timer.doAfter
  pointerClearTimer = stopPointerTimer(pointerClearTimer)
  pointerSettleTimer = stopPointerTimer(pointerSettleTimer)
  pointerSettleTimer = after(pointerSettleDelay, function()
    pointerSettleTimer = nil
    local home = pointerHome
    if not home then
      return
    end
    local readPointer = runtimeHooks and runtimeHooks.pointer
      or (not runtimeHooks and hs.mouse.absolutePosition) or nil
    -- A pointer no longer where our own last event left it was moved by hand inside
    -- the settle window. There is no click to drop the home for us there, and warping
    -- now would take the mouse away from the user mid-move.
    if readPointer and M.pointerDrifted(readPointer(), shared.pointerPosted) then
      clearPointerHome()
      return
    end
    if runtimeHooks and runtimeHooks.pointer then
      runtimeHooks.pointer(home)
    else
      hs.mouse.absolutePosition(home)
    end
    pointerClearTimer = after(pointerHomeIdle, function()
      pointerClearTimer = nil
      pointerHome = nil
    end)
  end)
end

local function cellCenters(frame, totalLines, columns)
  -- Every one of these divides below: a screen with no input box reports zero lines,
  -- and the infinities that follow would be posted as a click somewhere.
  if type(columns) ~= "number" or columns <= 0
      or type(totalLines) ~= "number" or totalLines <= 0
      or type(frame) ~= "table" or type(frame.x) ~= "number"
      or type(frame.w) ~= "number" or type(frame.h) ~= "number" then
    return nil
  end
  local halfRow = frame.h / totalLines / 2
  local cellWidth = frame.w / columns
  return function(column, rowIndex)
    local rowBottom = M.inputBorderY(frame, totalLines, rowIndex)
    if not rowBottom then
      return nil
    end
    return { x = frame.x + (column - 0.5) * cellWidth, y = rowBottom - halfRow }, cellWidth
  end
end

local function draftDragPoints(frame, totalLines, layout)
  if type(layout) ~= "table" or not layout.hasText
      or type(layout.firstRow) ~= "number" then
    return nil
  end
  local center = cellCenters(frame, totalLines, layout.columns)
  if not center then
    return nil
  end
  local startPoint = center(layout.firstColumn, layout.firstRow)
  local endPoint, cellWidth = center(layout.lastColumn, layout.lastRow)
  if not startPoint or not endPoint then
    return nil
  end
  -- Ending on the cell center left the last character out of the selection
  -- (seen live); aim near the cell's right edge instead.
  endPoint.x = endPoint.x + 0.4 * cellWidth
  return startPoint, endPoint
end

-- One motion event is enough: Claude anchors at the down point and takes the last
-- SGR motion as the endpoint, so the selection paints in a single repaint instead
-- of growing across intermediate steps.
local function dragBetween(startPoint, endPoint)
  -- Posted drag events move the physical pointer; put it back afterwards.
  local restoreMouse = takePointerHome()
  postMouseEvent("down", startPoint)
  pauseBetweenDragSteps()
  postMouseEvent("dragged", endPoint)
  pauseBetweenDragSteps()
  postMouseEvent("up", endPoint)
  shared.pointerPosted = endPoint
  if restoreMouse then
    schedulePointerReturn()
  end
  -- Our own events carry the replay marker the tap skips, so nothing else will arm
  -- the selection they just painted.
  selectionLikely = true
  selectionPoint = endPoint
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
      local frame = targetWindowFrame(original.observed and original.observed.windowID,
        totalLines, layout and layout.columns)
      local startPoint, endPoint = draftDragPoints(frame, totalLines, layout)
      if not startPoint then
        -- No drag happened, so an earlier drag's selection must not stay armed
        -- for Cmd+X: the user just asked for "everything", not that old sliver.
        clearSelectionState()
        selectAllInFlight = false
        return
      end
      dragBetween(startPoint, endPoint)
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

-- Shared by the immediate path and the deferred queue, so both run every action
-- the same way. Returns false for anything else (replay, policy-drop).
local function runAction(action, original, path)
  -- The gesture's sentinel DEL is still pending, and every one of these rewrites the
  -- same draft: interleaved, a whole-draft select-all plus that DEL wipes it, and an
  -- undo or a convert leaves the DEL eating their last character instead of the
  -- sentinel. The key is consumed and dropped rather than queued — the window is tens
  -- of milliseconds and a re-press costs less than a flow waiting on someone else's
  -- scrape. Copy is absent on purpose: the copy chord rewrites nothing.
  if gestureInFlight and (action == "cut" or action == "selectAll"
      or action == "undo" or action == "convert" or action == "image-paste") then
    return true
  end
  -- A replace is not a chord that costs a re-press: it carries the character the user
  -- typed, and consuming it here loses it. It leaves as itself instead — the sentinel
  -- DEL is the one that stands down, which is the same trade every other key typed
  -- inside this window already makes.
  if gestureInFlight and action == "replace" then
    gestureDraftTouched = true
    clearSelectionState()
    return false
  end
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
  elseif action == "replace" then
    performReplace(original)
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

-- One resolution can hold a replace and the keys pressed behind it. The replace runs
-- across two scrapes and a timer, so everything after it waits for that flow to end:
-- dispatched now, a cut would diff against the replace's own DEL and a replay would
-- reach the draft ahead of the key it followed.
local function dispatchPendingActions(items, from)
  local observed = from <= #items and observeFrontmost() or nil
  for index = from, #items do
    local item = items[index]
    local original = pendingOriginals[item.id]
    if replaceInFlight or cutInFlight then
      local holdQueue = replaceInFlight and replaceQueue or afterCutQueue
      if item.action == "policy-drop" then
        pendingOriginals[item.id] = nil
        if item.replace then clearSelectionState() end
        forgetRepeat(original)
        if runtimeHooks and runtimeHooks.drop then
          runtimeHooks.drop(original.event)
        end
      elseif item.action == "replay" and #holdQueue < replaceQueueLimit then
        pendingOriginals[item.id] = nil
        if item.replace then clearSelectionState() end
        original.mergedPending = true
        holdQueue[#holdQueue + 1] = original
      else
        if replaceInFlight then
          replaceContinuation = function() dispatchPendingActions(items, index) end
        else
          cutContinuation = function() dispatchPendingActions(items, index) end
        end
        return
      end
    else
      pendingOriginals[item.id] = nil
      -- A replace that resolved into anything else never ran its DEL, so the flag it
      -- was armed on must not survive the resolution either.
      if item.replace and item.action ~= "replace" then
        clearSelectionState()
      end
      if original and not currentTargetMatches(original, observed) then
        forgetRepeat(original)
        if item.action == "replay" and item.key == "c" then
          postOriginal(original)
        elseif runtimeHooks and runtimeHooks.drop then
          runtimeHooks.drop(original.event)
        end
      elseif item.action == "replay" then
        forgetRepeat(original)
        postOriginal(original)
      elseif item.action == "policy-drop" then
        forgetRepeat(original)
        if runtimeHooks and runtimeHooks.drop then
          runtimeHooks.drop(original.event)
        end
      elseif not runAction(item.action, original, item.path) then
        -- Only a replace refuses, and only mid-gesture. The press was consumed on its
        -- way in, so "pass it through" here means posting it back as itself.
        if item.action ~= "replace" then
          error("unknown pending action")
        end
        forgetRepeat(original)
        postOriginal(original)
      end
    end
  end
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
  dispatchPendingActions(effect.actions, 1)
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

local function pendingHoldsItems()
  return pendingState ~= nil and pendingState.status == "pending"
    and #pendingState.queue > 0
end

local function pendingHoldsReplace()
  if not pendingState or pendingState.status ~= "pending" then
    return false
  end
  for _, item in ipairs(pendingState.queue) do
    if item.replace then
      return true
    end
  end
  return false
end

local function deferEvent(event, observed, key, isRepeat, convertPath, replace, hold)
  pendingNextID = pendingNextID + 1
  local nextState, effect = M.pendingTransition(pendingState, {
    type = "press",
    id = pendingNextID,
    key = key,
    image = key == "v",
    convertPath = convertPath,
    replace = replace,
    hold = hold,
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
    keyCode = event:getKeyCode(),
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

-- Cocoa maps arrows, function and editing keys into the private-use area, so "one
-- printable codepoint" is exactly the set of keys that inserts text — in every
-- layout, without a keycode table that only ever knew ANSI.
local function printableText(text)
  if type(text) ~= "string" or text == "" then
    return false
  end
  if not (utf8 and utf8.len and utf8.codepoint) then
    return #text == 1 and text:byte(1) >= 0x20 and text:byte(1) ~= 0x7F
  end
  if utf8.len(text) ~= 1 then
    return false
  end
  local code = utf8.codepoint(text)
  return code >= 0x20 and code ~= 0x7F
    and not (code >= 0xF700 and code <= 0xF8FF)
end

local function eventCharacters(event, clean)
  local ok, text = pcall(event.getCharacters, event, clean)
  return ok and text or nil
end

local function insertsCharacter(event, flags)
  if flags.cmd or flags.ctrl or flags.fn or not event.getCharacters then
    return false
  end
  -- Option composes a dead key on some layouts and types { } @ \ on others. Only the
  -- characters as modified tell them apart: a press still composing an accent reports
  -- nothing, while an Option-printable already knows the character it will insert.
  if flags.alt and not printableText(eventCharacters(event, false)) then
    return false
  end
  return printableText(eventCharacters(event, true))
end

-- Types, the convert path, and which of "image" | "convert" | "text" Cmd+V would
-- act on. A nil kind is a pasteboard nobody here handles — unreadable, empty, or
-- some type a native paste would ignore too.
local function readPasteClipboard()
  local contentTypes = runtimeHooks and runtimeHooks.contentTypes
    or hs.pasteboard.contentTypes
  local ok, types = pcall(contentTypes)
  if not ok or types == nil then
    return nil
  end
  if M.containsImageType(types) then
    return types, nil, "image"
  end
  local path = resolveFileImagePath(types)
  if path then
    return types, path, "convert"
  end
  return types, nil, M.containsTextType(types) and "text" or nil
end

local function queueBehindReplace(event, observed, keyCode)
  if not replaceInFlight or not sameObserved(replaceContext, observed)
      or #replaceQueue >= replaceQueueLimit then
    return false
  end
  replaceQueue[#replaceQueue + 1] = {
    event = event:copy(),
    observed = observed,
    keyCode = keyCode,
  }
  return true
end

-- Option+Shift+Left/Right selects the word beside the cursor: the TUI has no
-- word-selection key, so the word is found on the scraped screen and painted by
-- synthesizing the double-click the TUI already word-snaps. The cursor is invisible
-- to a scrape, so it is made visible: U+237C is a single-cell glyph no real draft
-- carries, so exactly one match on the screen is the cursor and anything else is a
-- draft that already held it or a repaint that raced us.
local sentinelChar = "\226\141\188"
local gestureScrapeDelay = 0.02
local gestureSettleDelay = 0.05
local gestureScrapeAttempts = 3
local gestureTimer

function M.sentinelPlan()
  local bytes = {}
  for index = 1, #sentinelChar do
    bytes[index] = sentinelChar:byte(index)
  end
  return bytes
end

-- U+00A0 counts as a space: Terminal draws the block cursor with one, a pasted draft
-- can carry one anywhere, and every %s test misses it. Classed by width alone it
-- would read as a word character and wordSpan would merge the words on either side.
-- General punctuation (U+2000–U+206F) is the same trap with a wider mouth: the em and
-- en dashes and the curly quotes an LLM answer is full of are all multibyte, and one
-- of them between two words would make the press select both.
local function isSpaceCell(cell)
  if cell.text == "\194\160" or cell.text:match("^%s$") ~= nil then
    return true
  end
  -- utf8.codepoint throws on a byte sequence that does not decode, and a scrape can
  -- hand us one; utf8.len answers 1 only for a single well-formed character.
  local code = #cell.text > 1 and utf8 and utf8.len and utf8.len(cell.text) == 1
    and utf8.codepoint(cell.text) or nil
  return code ~= nil and code >= 0x2000 and code <= 0x206F
end

-- The TUI's own word class, read off a live draft: it keeps a path or a hyphenated
-- name whole and cuts at quotes, brackets, commas and colons. Ours has to agree,
-- or a press hands the TUI a word it will not select the same way.
local function isWordCell(cell)
  return cell.text:match("^[%w_%.%-/~%+]$") ~= nil
    or (#cell.text > 1 and not isSpaceCell(cell))
end

local function draftCells(layout)
  local cells = {}
  for _, row in ipairs(layout and layout.rows or {}) do
    -- A row that does not decode has no cells to measure, and utf8.codes would throw
    -- on it: an unreadable draft the gesture gives up on beats a mis-measured one.
    if not (utf8 and utf8.len and utf8.len(row.text)) then
      return {}
    end
    local positions = {}
    for position in utf8.codes(row.text) do
      positions[#positions + 1] = position
    end
    positions[#positions + 1] = #row.text + 1
    local column = row.lead + 1
    for index = 1, #positions - 1 do
      local text = row.text:sub(positions[index], positions[index + 1] - 1)
      local width = cellLength(text)
      cells[#cells + 1] = { text = text, row = row.index, column = column, width = width }
      column = column + width
    end
  end
  return cells
end

-- Everything a later press has to find unchanged: the cells, where they sit, and
-- the geometry that turned them into pixels.
local function cellsSignature(cells, totalLines, columns)
  local parts = { tostring(totalLines), tostring(columns) }
  for _, cell in ipairs(cells) do
    parts[#parts + 1] = cell.row .. ":" .. cell.column .. ":" .. cell.text
  end
  return table.concat(parts, "\1")
end

local function sentinelIndex(cells)
  local found, count = nil, 0
  for index, cell in ipairs(cells) do
    if cell.text == sentinelChar then
      count = count + 1
      found = found or index
    end
  end
  return found, count
end

-- Terminal draws the block cursor sitting past the draft as a trailing space on some
-- scrapes and trims the genuine one on others, so the last row's trailing spaces
-- flicker between two reads of a draft nobody touched — measured live in both
-- directions. Dropped from every list before it is compared or signed; only the last
-- row is touched, so a space anywhere else still counts as a difference. Cells are
-- only ever dropped off the end, which leaves every surviving index unmoved.
local function withoutTrailingSpace(cells)
  local last = #cells
  if last == 0 then
    return cells
  end
  local lastRow = cells[last].row
  while last > 0 and cells[last].row == lastRow and isSpaceCell(cells[last]) do
    last = last - 1
  end
  if last == #cells then
    return cells
  end
  local result = {}
  for index = 1, last do
    result[index] = cells[index]
  end
  return result
end

-- Positions are deliberately not compared: taking the sentinel back out can reflow
-- the box (a wrap it caused unwinds), and the draft is still the same draft.
local function sameCellText(cells, expected)
  if #cells ~= #expected then
    return false
  end
  for index, cell in ipairs(cells) do
    if cell.text ~= expected[index].text then
      return false
    end
  end
  return true
end

-- The sentinel took a cell of its own, so it comes back out before any column is
-- used: everything right of it on that row is drawn one cell too far.
local function withoutSentinel(cells, index)
  local sentinel = cells[index]
  local result = {}
  for position, cell in ipairs(cells) do
    if position ~= index then
      local column = cell.column
      if position > index and cell.row == sentinel.row then
        column = column - sentinel.width
      end
      result[#result + 1] =
        { text = cell.text, row = cell.row, column = column, width = cell.width }
    end
  end
  return result
end

-- A word never crosses a row: a soft wrap splits it into two the user selects
-- one press at a time.
local function wordSpan(cells, index)
  if not isWordCell(cells[index]) then
    return index, index
  end
  local row = cells[index].row
  local first, last = index, index
  while cells[first - 1] and cells[first - 1].row == row and isWordCell(cells[first - 1]) do
    first = first - 1
  end
  while cells[last + 1] and cells[last + 1].row == row and isWordCell(cells[last + 1]) do
    last = last + 1
  end
  return first, last
end

local function extendedHead(cells, head, direction)
  local index = head + direction
  while cells[index] and isSpaceCell(cells[index]) do
    index = index + direction
  end
  if not cells[index] then
    return nil
  end
  local first, last = wordSpan(cells, index)
  return direction < 0 and first or last
end

-- The middle of the span, in whole and fractional columns alike: a click anywhere
-- inside a word selects all of it, so the middle is the farthest a press can be from
-- either boundary.
local function spanCenter(center, cells, first, last)
  local column = (cells[first].column + cells[last].column + cells[last].width - 1) / 2
  return center(column, cells[first].row), column
end

-- Measured off a live TUI: it counts a press landing within one cell of the press
-- before it as the next click of the same series if the two are less than half a
-- second apart, and the third click of a series selects the whole row. Releases,
-- including the one that ends a word drag, never count. So a press may never repeat
-- a cell: an extension presses its new head word, which has moved by at least two
-- cells, and drags back to the anchor it keeps releasing on.
local breakerOffset = 8
local lastPressCell

local function breakerColumn(pressColumn, row, columns)
  local candidates = {}
  for _, column in ipairs({ pressColumn - breakerOffset, pressColumn + breakerOffset }) do
    column = math.min(math.max(column, 1), columns)
    if math.abs(column - pressColumn) >= 2 then
      candidates[#candidates + 1] = column
    end
  end
  if #candidates == 0 then
    return nil
  end
  if #candidates == 2 and lastPressCell and lastPressCell.row == row
      and math.abs(candidates[1] - lastPressCell.column)
        < math.abs(candidates[2] - lastPressCell.column) then
    return candidates[2]
  end
  return candidates[1]
end

-- Word-wise selection the way the TUI itself does it: a double-click snaps to the
-- word under it, and holding the second press turns the drag into a word-wise
-- extension, so both ends land on whole words however far the pixel math is off.
local function gestureClickPoints(frame, totalLines, columns, cells, span, dragSpan, breaking)
  local center = cellCenters(frame, totalLines, columns)
  if not center then
    return nil
  end
  local pressPoint, pressColumn = spanCenter(center, cells, span[1], span[2])
  if not pressPoint then
    return nil
  end
  local points = { press = pressPoint, column = pressColumn, row = cells[span[1]].row }
  if dragSpan then
    points.drag = spanCenter(center, cells, dragSpan[1], dragSpan[2])
    if not points.drag then
      return nil
    end
  end
  -- A start can land on the word a press already took, its own or the user's, and an
  -- extension onto a neighbouring single-cell word (")" beside ")") moves too little
  -- to leave the series it is continuing. Either way this press, on the side away from
  -- the last one, opens a series of its own.
  local crowded = lastPressCell and lastPressCell.row == points.row
    and math.abs(pressColumn - lastPressCell.column) < 2
  if breaking or crowded then
    local column = breakerColumn(pressColumn, points.row, columns)
    points.breaker = column and center(column, points.row)
    if not points.breaker then
      return nil
    end
  end
  return points
end

local function clickWord(points)
  local pressPoint, endPoint = points.press, points.drag
  -- Posted clicks move the physical pointer; put it back afterwards.
  local restoreMouse = takePointerHome()
  if points.breaker then
    postMouseEvent("down", points.breaker, 1)
    pauseBetweenDragSteps()
    postMouseEvent("up", points.breaker, 1)
    pauseBetweenDragSteps()
  end
  postMouseEvent("down", pressPoint, 1)
  pauseBetweenDragSteps()
  postMouseEvent("up", pressPoint, 1)
  pauseBetweenDragSteps()
  postMouseEvent("down", pressPoint, 2)
  pauseBetweenDragSteps()
  if endPoint then
    postMouseEvent("dragged", endPoint, 2)
    pauseBetweenDragSteps()
  end
  local releasePoint = endPoint or pressPoint
  postMouseEvent("up", releasePoint, 2)
  shared.pointerPosted = releasePoint
  if restoreMouse then
    schedulePointerReturn()
  end
  selectionLikely = true
  selectionPoint = releasePoint
  lastPressCell = { column = points.column, row = points.row }
end

local function armGesture(direction, anchor, head, signature, points)
  clickWord(points)
  wordGestureState = {
    direction = direction,
    anchor = anchor,
    head = head,
    signature = signature,
    selectionPoint = points.drag or points.press,
  }
end

local function afterGestureDelay(delay, step, onError)
  local after = runtimeHooks and runtimeHooks.after or hs.timer.doAfter
  gestureTimer = after(delay, function()
    gestureTimer = nil
    if not pcall(step) then
      onError()
    end
  end)
end

-- True only for the flight that is still the current one. A nil id means "whoever is
-- flying now", which is what a teardown from outside the gesture code means.
function shared.gestureFlies(flight)
  return gestureInFlight and (flight == nil or shared.gestureFlight == flight)
end

function shared.endGestureFlight(flight)
  if flight ~= nil and shared.gestureFlight ~= flight then
    return
  end
  gestureInFlight = false
  -- The removal belongs to the flight that typed the sentinel: left behind, the next
  -- teardown would run it against a draft this one no longer owns.
  shared.sentinelCleanup = nil
  if shared.gestureWatchdog and shared.gestureWatchdog.stop then
    shared.gestureWatchdog:stop()
  end
  shared.gestureWatchdog = nil
end

-- A scrape Terminal never answers back would leave the gesture in flight for good,
-- and the guards reading that flag then eat every chord until Hammerspoon reloads. So
-- the flight ends on a deadline as well, and each step re-reads the flag it was armed
-- under: a callback arriving after the deadline finds it down and does nothing.
function shared.armGestureWatchdog(flight)
  local after = runtimeHooks and runtimeHooks.after or hs.timer.doAfter
  shared.gestureWatchdog = after(shared.gestureWatchdogDelay, function()
    -- Read before the handle is dropped: a deadline that fires just as its own flight
    -- ends arrives with the next gesture's watchdog already sitting in that slot.
    if not shared.gestureFlies(flight) then
      return
    end
    shared.gestureWatchdog = nil
    if gestureTimer and gestureTimer.stop then gestureTimer:stop() end
    gestureTimer = nil
    local cleanup = shared.sentinelCleanup
    shared.endGestureFlight(flight)
    if cleanup then pcall(cleanup) end
  end)
end

-- Terminal answers a scrape from the screen it holds now, and for a few milliseconds
-- that is still the one from before our own keystrokes reached the TUI: a screen that
-- has not caught up is worth another look before the draft is called unreadable.
-- `read` returns true once the scrape has settled the gesture, either way.
local function scrapeDraft(flight, original, delay, read, giveUp)
  local attempts = 0
  local function attempt()
    if not shared.gestureFlies(flight) then
      return
    end
    scrapeScreen(function(screenText)
      -- Nothing above this callback catches: an error thrown here would leave the
      -- gesture in flight for good, and every later press with it.
      local ok = pcall(function()
        -- The watchdog may have ended this flight already, or a later gesture may own
        -- the draft by now: the click below would paint over whatever it holds, and
        -- giving up here would post this flight's DEL into the other one's sentinel.
        if not shared.gestureFlies(flight) then
          return
        end
        if not currentTargetMatches(original, observeFrontmost()) then
          giveUp()
          return
        end
        local _, _, totalLines, layout = M.parseInputBox(screenText)
        if read(draftCells(layout), totalLines, layout) then
          return
        end
        attempts = attempts + 1
        if attempts < gestureScrapeAttempts then
          afterGestureDelay(delay, attempt, giveUp)
        else
          giveUp()
        end
      end)
      if not ok then
        giveUp()
      end
    end)
  end
  afterGestureDelay(delay, attempt, giveUp)
end

local function runGestureStart(original, direction, flight)
  if not currentTargetMatches(original, observeFrontmost()) then
    shared.endGestureFlight(flight)
    return
  end
  gestureDraftTouched = false
  local sentinelSettled = false
  local sentinelGone = false
  -- Answers whether the sentinel is out of the draft, not merely whether the removal
  -- was attempted: a caller that must not submit a draft carrying it needs the
  -- difference, and the branch below leaves the character in place on purpose.
  local function removeSentinel()
    if not sentinelSettled then
      sentinelSettled = true
      -- The cut plan is the DEL byte: whatever the scrape said, the character we
      -- typed into the user's draft leaves again — unless a keystroke of the user's
      -- got there first, in which case the DEL would take theirs.
      if not gestureDraftTouched then
        emit(M.cutPlan())
        sentinelGone = true
      end
    end
    return sentinelGone
  end
  local function abandon()
    -- Giving up usually means the target is gone, and the DEL would then land in
    -- whatever window took its place: a sentinel left in the user's draft is the
    -- cheaper damage.
    if currentTargetMatches(original, observeFrontmost()) then
      removeSentinel()
    end
    shared.endGestureFlight(flight)
  end
  -- Armed BEFORE the emit below, not after: everything from that keystroke onwards can
  -- throw, and an error path that finds no cleanup to call leaves the sentinel sitting
  -- in the draft with nothing left that would ever take it out. Reachable by name,
  -- idempotent through sentinelSettled, silent unless this flight is still the one
  -- flying and the draft it was typed into is still in front; answers whether the
  -- sentinel is gone from that draft.
  shared.sentinelCleanup = function()
    if shared.gestureFlight ~= flight
        or not currentTargetMatches(original, observeFrontmost()) then
      return false
    end
    return removeSentinel()
  end
  emit(M.sentinelPlan())
  local function stop()
    shared.endGestureFlight(flight)
    return true
  end

  -- The DEL has to repaint before the click: it can unwrap a row and move every cell
  -- the sentinel screen measured.
  local function armWhenRepainted(expected, neighbour)
    scrapeDraft(flight, original, gestureSettleDelay, function(scraped, totalLines, layout)
      local cells = withoutTrailingSpace(scraped)
      if not sameCellText(cells, expected) then
        return false
      end
      shared.endGestureFlight(flight)
      -- The span is measured here, not on the sentinel screen: a sentinel that
      -- pushed a word over the wrap made it two words that are one again now.
      local first, last = wordSpan(cells, neighbour)
      local anchor = direction < 0 and last or first
      local dragSpan
      -- A double-clicked space paints nothing at all in the TUI (the selection is
      -- real, and a Cmd+X does cut it), so a press with only a space to take would
      -- look dead: it takes the word past the space and drags back over it.
      if isSpaceCell(cells[neighbour]) then
        local beyond = extendedHead(cells, neighbour, direction)
        if beyond and cells[beyond].row == cells[neighbour].row then
          first, last = wordSpan(cells, beyond)
          anchor, dragSpan = neighbour, { neighbour, neighbour }
        end
      end
      local frame = targetWindowFrame(original.observed and original.observed.windowID,
        totalLines, layout.columns)
      local points = gestureClickPoints(frame, totalLines, layout.columns, cells,
        { first, last }, dragSpan, true)
      if points then
        armGesture(direction, anchor, direction < 0 and first or last,
          cellsSignature(cells, totalLines, layout.columns), points)
      end
      return true
    end, stop)
  end

  scrapeDraft(flight, original, gestureScrapeDelay, function(cells)
    local index, count = sentinelIndex(cells)
    if count == 0 then
      return false
    end
    removeSentinel()
    if count > 1 then
      return stop()
    end
    local remaining = withoutTrailingSpace(withoutSentinel(cells, index))
    -- Left reads the cell before the sentinel; right reads the one the sentinel
    -- pushed aside, which took its index once the sentinel was dropped.
    local neighbour = direction < 0 and index - 1 or index
    -- The neighbour was a trailing space this scrape drew and the next one may not:
    -- to the left the word it would have reached over is the last real cell, to the
    -- right there is nothing past it at all.
    if neighbour > #remaining and direction < 0 then
      neighbour = #remaining
    end
    if not remaining[neighbour] then
      return stop()
    end
    armWhenRepainted(remaining, neighbour)
    return true
  end, abandon)
end

local function runGestureExtend(original, cache, flight)
  if not currentTargetMatches(original, observeFrontmost()) then
    shared.endGestureFlight(flight)
    return
  end
  scrapeScreen(function(screenText)
    if not shared.gestureFlies(flight) then
      return
    end
    shared.endGestureFlight(flight)
    if not currentTargetMatches(original, observeFrontmost()) then
      return
    end
    -- The user clicked or typed while this scrape was out: the click choreography
    -- below would paint over what they just did. No keepSelection either — their
    -- action is what cleared the selection the cache describes.
    if gestureDraftTouched then
      return
    end
    local _, _, totalLines, layout = M.parseInputBox(screenText)
    local cells = withoutTrailingSpace(draftCells(layout))
    -- Streaming output repaints the box under the selection, and the cached cell
    -- indices would then point at another draft's characters.
    if #cells == 0
        or cellsSignature(cells, totalLines, layout.columns) ~= cache.signature then
      return
    end
    -- The draft is the one the cache was built on and nothing was clicked, so the
    -- selection this keypress cleared our state for is still painted: it has to come
    -- back, or the next Cmd+X takes the bare-DEL path over a live selection.
    local function keepSelection()
      selectionLikely = true
      selectionPoint = cache.selectionPoint
      wordGestureState = cache
    end
    local head = extendedHead(cells, cache.head, cache.direction)
    if not head or head == cache.head then
      return keepSelection()
    end
    -- Measured live: the TUI paints a selection inside one row only, clamping a drag
    -- that ends on another row to the row it was pressed on. An extension over the
    -- wrap would trade everything selected so far for the single word it presses, so
    -- the selection stops at the row it started on.
    if cells[head].row ~= cells[cache.anchor].row then
      return keepSelection()
    end
    local frame = targetWindowFrame(original.observed and original.observed.windowID,
      totalLines, layout.columns)
    local points = gestureClickPoints(frame, totalLines, layout.columns, cells,
      { wordSpan(cells, head) }, { wordSpan(cells, cache.anchor) })
    if not points then
      -- The same bail as the two above it: nothing was clicked, so the selection is
      -- still painted and the state has to come back with it.
      return keepSelection()
    end
    armGesture(cache.direction, cache.anchor, head, cache.signature, points)
  end)
end

local function startWordGesture(keyCode, observed, cache)
  -- The draft-rewriting flows own the screen this gesture would scrape, and a
  -- pending queue may still turn into one; the press is consumed either way.
  -- The state this keypress cleared on its way in has to come back with every bail
  -- that leaves the draft alone: the TUI selection is still painted, and dropping the
  -- cache would restart the next chord from the cursor instead of extending.
  local function keepSelection()
    if not cache then
      return
    end
    selectionLikely = true
    selectionPoint = cache.selectionPoint
    wordGestureState = cache
  end
  if gestureInFlight or cutInFlight or replaceInFlight or selectAllInFlight
      or pendingHoldsItems() then
    return keepSelection()
  end
  local direction = keyCode == 123 and -1 or 1
  if cache and cache.direction ~= direction then
    -- The opposite direction neither shrinks nor flips a live selection.
    return keepSelection()
  end
  local original = { observed = observed }
  gestureInFlight = true
  shared.gestureFlight = shared.gestureFlight + 1
  local flight = shared.gestureFlight
  shared.armGestureWatchdog(flight)
  deferAsync(function()
    local ok
    if cache then
      ok = pcall(runGestureExtend, original, cache, flight)
    else
      ok = pcall(runGestureStart, original, direction, flight)
    end
    if not ok then
      -- The throw may have come from anywhere past the sentinel keystroke, so the
      -- removal is owed here too: ending the flight alone would leave that character
      -- in the draft for good.
      local cleanup = shared.sentinelCleanup
      shared.endGestureFlight(flight)
      if cleanup then pcall(cleanup) end
    end
  end)
end

local function handleEvent(event, keyCode, isRepeat)
  local types = hs.eventtap.event.types
  local eventType = event:getType()
  if eventType ~= types.keyDown then
    -- Ours carry the replay marker and never reach here, so this is the user's hand:
    -- a click moves the caret and a drag paints a selection, and the DEL still owed
    -- for the sentinel would take that instead of the character we typed.
    if gestureInFlight then
      gestureDraftTouched = true
    end
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
        -- The user selected by hand, so the cached gesture anchor belongs to a
        -- selection that is gone; kept, the next same-direction chord would extend
        -- from it and repaint over what was just selected. Our own choreography's
        -- clicks carry the replay marker and never reach here.
        wordGestureState = nil
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
      -- Ours carry the replay marker and never reach here, so this is the user's hand
      -- on the mouse: the saved home is wherever they left it, and warping back to it
      -- would undo the move they just made.
      clearPointerHome()
    end
    invalidateAndRefresh()
    return false
  end

  local flags = event:getFlags()
  local key = flags:containExactly({ "cmd" }) and keyForCode[keyCode] or nil
  local typed = not key and insertsCharacter(event, flags)

  if replaceInFlight then
    local observed = observeFrontmost()
    if not sameObserved(replaceContext, observed) then
      -- The flow's keys belong to a context that is gone, while this one belongs to
      -- the new one with nothing queued ahead of it: it passes through untouched.
      abandonReplace()
    elseif isRepeat then
      -- Autorepeats would eat the queue's cap; the key is still held, so native
      -- repeat picks up again the moment the flow releases it.
      return true
    else
      -- Nothing may pass natively while the flow holds keys: the physical event is
      -- already ahead of anything we post, so a key let through here would reach the
      -- terminal before them. Text joins the queue, everything else ends the flow as
      -- its last event.
      local textPaste = key == "v" and select(3, readPasteClipboard()) == "text"
      if (typed or textPaste) and queueBehindReplace(event, observed, keyCode) then
        return true
      end
      if not key then
        finishReplace({ event = event:copy(), observed = observed, keyCode = keyCode })
        skipRepeatCache = true
        return true
      end
      -- A replay carries the marker this tap skips, so one of our own chords posted
      -- back would reach Terminal as the literal Cmd+X the TUI has no handler for.
      -- Flushed first, then decided from scratch below: it keeps its own action.
      finishReplace()
    end
  end

  -- A stale flag costs a spurious DEL, so the AX round trip and the scrape are
  -- only worth paying for while a selection is actually armed.
  local typedReplace = typed and selectionLikely and not isRepeat and not cutInFlight
  if not key and not typedReplace then
    -- The queue-behind protection above only starts once the flow is running; a key
    -- arriving while the first one still waits for the foreground verdict would pass
    -- natively and land ahead of it — a Return submitting the draft the held key was
    -- meant to go into. Held here, it is replayed in the order it was typed.
    if pendingHoldsReplace() and not isRepeat then
      local held = deferEvent(event, observeFrontmost(), nil, false, nil, nil, true)
      if held then
        return true
      end
    end
    -- 76 is the keypad's own Enter: it submits the draft exactly as 36 does, so every
    -- rule written for Return has to name both or the keypad silently bypasses it.
    if flags.cmd or flags.ctrl or keyCode == 36 or keyCode == 76 then
      invalidateAndRefresh()
    end
    -- Every keystroke the terminal receives either deletes the TUI selection or
    -- moves the cursor out of it, so our flag must not outlive it. Shift+arrow
    -- keeps a real selection alive and still lands here: disarming only costs a
    -- Cmd+X that no-ops or a Cmd+V that pastes natively.
    -- Read before the line below drops it: an extension press is only told apart
    -- from a fresh gesture by the cache its own arrival clears.
    local gestureCache = wordGestureState
    clearSelectionState()
    -- Every other key mid-flight merely stands the sentinel DEL down and leaves the
    -- character in the draft, where the next Backspace reaches it. Return does not: it
    -- SUBMITS that draft, sentinel and all, and no key can take it back out of a sent
    -- message. Passing it natively cannot work either — the physical event is already
    -- ahead of anything we post — so it is consumed, the removal goes out first, and
    -- the Return follows it as a keystroke of our own.
    if gestureInFlight and (keyCode == 36 or keyCode == 76) and shared.sentinelCleanup then
      local removal = shared.sentinelCleanup
      local held = { event = event:copy(), keyCode = keyCode }
      shared.endGestureFlight()
      local ok, sentinelGone = pcall(removal)
      if ok and sentinelGone then
        postOriginal(held)
      elseif runtimeHooks and runtimeHooks.drop then
        -- Either the draft this Return was typed into is gone — posted now it would
        -- submit whatever took its place — or the sentinel is still in that draft
        -- because the user's own keystroke got there first and the DEL stood down.
        -- A stray character the next Backspace reaches beats a sent message holding it.
        runtimeHooks.drop(held.event)
      end
      return true
    end
    if gestureInFlight and not (flags.alt and flags.shift and keyCode >= 123 and keyCode <= 126) then
      -- This key passes natively and lands in the draft ahead of the DEL that takes
      -- the sentinel back out, so that DEL would delete the user's character instead:
      -- the sentinel stays in the draft as the cheaper damage.
      gestureDraftTouched = true
    end
    if flags.alt and flags.shift and keyCode >= 123 and keyCode <= 126 then
      -- Claude renders the Option+Shift+arrow escape sequence as a bare Esc and
      -- offers to clear the whole input, so the chord never reaches it: left and
      -- right run the word gesture instead, up and down are swallowed bare. A plain
      -- shell tab has no such prompt to protect, so only a draft that may be
      -- Claude's is worth eating it.
      local frontmost = observeFrontmost()
      local frontVerdict = foregroundVerdict(frontmost)
      if frontmost.bundleID == terminalBundleID and frontVerdict ~= "not-claude" then
        -- Swallowing the chord is safe wherever the tab may be Claude's, but the
        -- gesture types a sentinel into the draft: on an unresolved verdict that
        -- character lands in whatever else is reading the tty. The context refreshes
        -- every 0.1s, so it is the next press that runs, not none.
        if frontVerdict == "claude" and (keyCode == 123 or keyCode == 124) then
          startWordGesture(keyCode, frontmost, gestureCache)
        elseif gestureCache then
          -- Swallowed without running a gesture, so the draft is untouched and the TUI
          -- selection is still painted: the state this press cleared on its way in has
          -- to come back, exactly as every bail inside startWordGesture restores it.
          selectionLikely = true
          selectionPoint = gestureCache.selectionPoint
          wordGestureState = gestureCache
        end
        return true
      end
    end
    if cutInFlight then
      if isRepeat then
        return true
      end
      if #afterCutQueue < replaceQueueLimit then
        afterCutQueue[#afterCutQueue + 1] = {
          event = event:copy(),
          observed = observeFrontmost(),
          keyCode = keyCode,
        }
        return true
      end
    end
    return false
  end

  if isRepeat and key and pendingState and pendingState.status == "pending" then
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
      clearSelectionState()
      return false
    end
    observed = observeFrontmost(app)
  end
  if observed.bundleID ~= terminalBundleID then
    clearSelectionState()
    return false
  end

  local pasteboardTypes
  local convertPath
  local replace = typedReplace or nil
  if key == "v" then
    local types, path, kind = readPasteClipboard()
    -- Nothing we act on must reach the deferred queue: an unhandled Cmd+V resolves
    -- there into an image paste.
    if not kind then
      clearSelectionState()
      return false
    end
    pasteboardTypes, convertPath = types, path
    if kind == "text" then
      -- Native is exactly the problem while the gesture holds the draft: the clipboard
      -- would land ahead of the sentinel DEL, which then eats its last character. The
      -- other draft rewrites are dropped in runAction; this one never reaches it.
      if gestureInFlight then
        return true
      end
      -- A text paste is already native, so only an armed selection is worth
      -- intercepting for; read at press time because the DEL that follows clears
      -- the flag. A cut owns the same DEL window, so during one the paste waits
      -- until its scrape diff finishes.
      if cutInFlight then
        if isRepeat then
          return true
        end
        if #afterCutQueue < replaceQueueLimit then
          afterCutQueue[#afterCutQueue + 1] = {
            event = event:copy(),
            observed = observed,
            keyCode = keyCode,
          }
          return true
        end
        return false
      end
      if not selectionLikely then
        return false
      end
      replace = true
    end
  end

  local verdict = M.cachedVerdict(observed, cachedContext, now())
  if verdict == "uncertain" then
    local consumed = deferEvent(event, observed, key, isRepeat, convertPath, replace)
    if not consumed then clearSelectionState() end
    return consumed
  end
  local action = decideAction(observed.bundleID, verdict == "claude", pasteboardTypes, key,
    convertPath, replace)
  if action == "pass" then
    clearSelectionState()
    return false
  end

  -- Convert and replace are the immediate actions that can still replay their own
  -- event a tick later, so they alone pay for the copy and the pasteboard read here.
  local original = { observed = observed, keyCode = keyCode }
  if action == "convert" or action == "replace" then
    original.event = event:copy()
    original.changeCount = pasteboardChangeCount()
  end
  -- Every action but a replace refused mid-gesture consumes the press it ran for.
  return runAction(action, original, convertPath)
end

local function healEventTap()
  if eventTap and not eventTap:isEnabled() then
    eventTap:start()
  end
end

-- Once per session: a tap that throws throws on every event of the same shape, and a
-- line printed per keystroke would become the stall it is reporting.
function M.logTapError(err)
  if shared.tapErrorLogged then
    return
  end
  shared.tapErrorLogged = true
  if runtimeHooks and runtimeHooks.log then
    runtimeHooks.log(err)
  elseif rawget(_G, "hs") and hs.printf then
    hs.printf("claude_cmd_keys: handleEvent error: %s", tostring(err))
  end
end

function M.setTestHooks(hooks)
  runtimeHooks = hooks
  if pendingTimer then pendingTimer:stop() end
  pendingTimer = nil
  if cutTimer and cutTimer.stop then cutTimer:stop() end
  cutTimer = nil
  if gestureTimer and gestureTimer.stop then gestureTimer:stop() end
  gestureTimer = nil
  shared.sentinelCleanup = nil
  shared.pointerPosted = nil
  M.axAnchorReset()
  if replaceTimer and replaceTimer.stop then replaceTimer:stop() end
  replaceTimer = nil
  replaceOriginal = nil
  replaceContext = nil
  replaceQueue = {}
  replaceContinuation = nil
  cutContinuation = nil
  afterCutQueue = {}
  pendingState = idlePendingState()
  pendingOriginals = {}
  pendingNextID = 0
  pendingStartedAt = nil
  cachedContext = nil
  resolvedTty = nil
  resolvedObserved = nil
  repeatDecisions = {}
  skipRepeatCache = false
  lastAlertAt = nil
  cutInFlight = false
  replaceInFlight = false
  selectAllInFlight = false
  shared.endGestureFlight()
  lastPressCell = nil
  gestureDraftTouched = false
  dragSeen = false
  clearPointerHome()
  clearSelectionState()
  replayProperty = hooks and hooks.replayProperty or replayProperty
end

function M.start()
  started = true
  -- claude-keys off, hours pass, on again: the first event's gap belongs to no
  -- previous event at all, and measured against the pre-stop one it reads as warm.
  latencyPreviousAt = 0
  -- The once-per-session latch outlives the session it was set in otherwise, and
  -- `claude-keys off; on` — pressed precisely to see the failure again — then reports
  -- nothing at all.
  shared.tapErrorLogged = nil
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
    local enteredAt = absoluteTime()
    -- An error thrown out of here is the one sample worth having and the one the
    -- system counts towards disabling the tap: caught, the event still passes to the
    -- terminal untouched and the reading is still taken.
    local ok, consume = pcall(M.handleEvent, event)
    latencyObserve(event, enteredAt, absoluteTime())
    if not ok then
      M.logTapError(consume)
      return false
    end
    return consume
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
    if key then
      for _, item in ipairs(pendingState and pendingState.queue or {}) do
        if item.key == key then
          keyIsPending = true
          break
        end
      end
    end
    -- A held key whose first press the replace flow consumed has to keep going
    -- through the queue, or its repeats leak out ahead of the key being held.
    if not keyIsPending and not replaceInFlight then
      return repeatDecisions[keyCode] == true
    end

    local callbackStarted = absoluteTime()
    local consume = handleEvent(event, keyCode, true)
    lastCallbackMs = (absoluteTime() - callbackStarted) / 1000000
    return consume
  end
  if isKeyDown then repeatDecisions[keyCode] = false end

  local callbackStarted = absoluteTime()
  local consume = handleEvent(event, keyCode, isRepeat)
  lastCallbackMs = (absoluteTime() - callbackStarted) / 1000000
  if isKeyDown then
    repeatDecisions[keyCode] = consume == true and not skipRepeatCache
  end
  skipRepeatCache = false
  return consume
end

function M.stop()
  -- Stopping between the sentinel and the scrape that owes its DEL would leave the
  -- character we typed sitting in the user's draft; the cleanup posts it if and only
  -- if that draft is still the one in front. It runs first, so the keys the flows
  -- below are holding still reach the draft in the order they were typed.
  if shared.sentinelCleanup then
    pcall(shared.sentinelCleanup)
    shared.sentinelCleanup = nil
  end
  completePending("stop")
  -- Actions saved for a flow that will never finish belong to the session being torn
  -- down; the keys both flows are holding still have to leave as themselves.
  replaceContinuation = nil
  cutContinuation = nil
  -- A flow torn down mid-flight must not eat the keys it is holding.
  finishReplace()
  flushAfterCut()
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
  if gestureTimer and gestureTimer.stop then gestureTimer:stop() end
  gestureTimer = nil
  cutInFlight = false
  selectAllInFlight = false
  shared.endGestureFlight()
  -- A breaker left by a slow walk would outlive the restart and stand the anchored
  -- grid down for a minute of it, which is the one thing `claude-keys off; on` is
  -- pressed to rule out.
  M.axAnchorReset()
  shared.pointerPosted = nil
  lastPressCell = nil
  gestureDraftTouched = false
  dragSeen = false
  clearPointerHome()
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
