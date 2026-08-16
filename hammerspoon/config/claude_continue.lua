local ClaudeContinue = {}

local ax = require("hs.axuielement")
local gptVoiceKeys = require("gpt_voice_keys")
local ChatGate = require("chat_gate")

local appName = "Claude"
local terminalAppName = "Terminal"
local kimiAppName = "Kimi"
local kimiBundleId = "com.moonshot.kimichat"
local message = "продолжай"
local promptClickXRatio = 0.35
local axSearchMaxDepth = 70
local axSearchMaxNodes = 2500
local sendGapDelay = 1.0

local launchDelay = 0.8
local focusDelay = 0.3
local clickDelay = 0.2
local pasteDelay = 0.2
local clipboardSettleDelay = 0.1
local restoreClipboardDelay = 0.5
local maxDeliveryAttempts = 3
-- A delivery that wedges must not sit on the chat for the gate's default two hours:
-- nothing here waits on a person, and the timer path's own watchdog gives up at two
-- minutes.
local deliveryHorizon = 300

local timerIntervalSeconds = nil
local timerMode = nil
local selectedStartDelayMinutes = nil

local destinationDefinitions = {}

local destinationEnabled = {
    app = false,
    terminal = false,
    kimi = false,
}

-- Independent per-destination resume timers, separate from the combined timer/repeat
-- system above. Each destination has at most one armed timer; arming replaces it.
local destinationTimers = {}

local statePath = hs.configdir .. "/claude_continue_state.json"
local logPath = hs.configdir .. "/claude_continue.log"

-- Forward declarations: the persistence/delivery/retry machinery is defined lower
-- (after runDestination/fireDestinationTimer) but referenced by callers above it.
local persistState, restoreState, deliverOrDefer, retryDeliver
local startRetry, stopRetry, ensureLockWatcher
local lockWatcher = nil
local deliveryBusy = false

local function log(...)
    print("[claude-continue]", ...)
end

local function logLine(event, id, detail)
    local stamp = os.date("%Y-%m-%d %H:%M:%S")
    local compactDetail = tostring(detail or ""):gsub("[\r\n]+", " ")
    local line = string.format("%s  %-16s %-9s %s", stamp, event, tostring(id or "-"), compactDetail)
    local f = io.open(logPath, "a")
    if f then
        f:write(line, "\n")
        f:close()
    end
end

local function trimLog()
    local f = io.open(logPath, "r")
    if not f then
        return
    end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    if #lines <= 500 then
        return
    end
    local out = io.open(logPath, "w")
    if not out then
        return
    end
    for i = #lines - 499, #lines do
        out:write(lines[i], "\n")
    end
    out:close()
end

local function stopWithAlert(messageText, onComplete)
    log(messageText)
    hs.alert.show(messageText)

    if onComplete then
        onComplete()
    end
end

local function frontmostIsClaude()
    local front = hs.application.frontmostApplication()
    return front and front:name() == appName
end

local function frontmostIsTerminal()
    local front = hs.application.frontmostApplication()
    return front and front:name() == terminalAppName
end

local function frontmostIsKimi()
    local front = hs.application.frontmostApplication()
    return front and front:bundleID() == kimiBundleId
end

local function destinationDefinition(id)
    for _, destination in ipairs(destinationDefinitions) do
        if destination.id == id then
            return destination
        end
    end

    return nil
end

local function enabledDestinationIds()
    local ids = {}

    for _, destination in ipairs(destinationDefinitions) do
        if destinationEnabled[destination.id] then
            table.insert(ids, destination.id)
        end
    end

    return ids
end

local function destinationLabel()
    local labels = {}

    for _, destination in ipairs(destinationDefinitions) do
        if destinationEnabled[destination.id] then
            table.insert(labels, destination.label)
        end
    end

    if #labels == 0 then
        return "No destination"
    end

    return table.concat(labels, " + ")
end

local function restoreClipboard(snapshot)
    if not snapshot then
        return false
    end

    local ok, result = pcall(hs.pasteboard.writeAllData, snapshot)
    if not ok or result == false then
        log("Could not restore clipboard")
        return false
    end

    return true
end

local function formatInterval(seconds)
    local minutes = math.floor(seconds / 60)

    if minutes % 60 == 0 then
        local hours = minutes / 60
        if hours == 1 then
            return "1 h"
        end
        return tostring(hours) .. " h"
    end

    return tostring(minutes) .. " min"
end

local function formatClock(timestamp)
    if not timestamp then
        return nil
    end

    return os.date("%H:%M", timestamp)
end

local function formatRemainingMinutes(totalMinutes)
    if totalMinutes < 60 then
        return totalMinutes .. "m"
    end

    local hours = math.floor(totalMinutes / 60)
    local minutes = totalMinutes % 60

    if minutes == 0 then
        return hours .. "h"
    end

    return hours .. "h " .. minutes .. "m"
end

local function notifyStatusChanged()
    if _G.AutomationMenu and _G.AutomationMenu.refresh then
        _G.AutomationMenu.refresh()
    end
end

local function axAttribute(element, attribute)
    if not element then
        return nil
    end

    local ok, value = pcall(function()
        return element:attributeValue(attribute)
    end)

    if ok then
        return value
    end

    return nil
end

local function valueContains(value, needle)
    if type(value) == "string" then
        return value:lower():find(needle:lower(), 1, true) ~= nil
    end

    if type(value) == "table" then
        for _, item in pairs(value) do
            if valueContains(item, needle) then
                return true
            end
        end
    end

    return false
end

local function isPromptTextArea(element)
    if axAttribute(element, "AXRole") ~= "AXTextArea" then
        return false
    end

    local description = axAttribute(element, "AXDescription")
    if description == "Prompt" then
        return true
    end

    local classList = axAttribute(element, "AXDOMClassList")
    return valueContains(classList, "ProseMirror") and valueContains(classList, "tiptap")
end

local function isTextInputElement(element)
    local role = axAttribute(element, "AXRole")
    return role == "AXTextArea" or role == "AXTextField"
end

local function elementFrame(element)
    local position = axAttribute(element, "AXPosition")
    local size = axAttribute(element, "AXSize")

    if type(position) ~= "table" or type(size) ~= "table"
        or type(position.x) ~= "number" or type(position.y) ~= "number"
        or type(size.w) ~= "number" or type(size.h) ~= "number"
        or size.w <= 0 or size.h <= 0 then
        return nil
    end

    return {
        x = position.x,
        y = position.y,
        w = size.w,
        h = size.h,
    }
end

local function frameIntersectsWindow(frame, windowFrame)
    if not windowFrame then
        return true
    end

    return frame.x < windowFrame.x + windowFrame.w
        and frame.x + frame.w > windowFrame.x
        and frame.y < windowFrame.y + windowFrame.h
        and frame.y + frame.h > windowFrame.y
end

local function findPromptTextArea(rootElement, windowFrame, matcher)
    matcher = matcher or isPromptTextArea
    local queue = { { element = rootElement, depth = 0 } }
    local index = 1
    local visited = 0
    local bestPrompt = nil
    local bestFrame = nil

    while queue[index] and visited < axSearchMaxNodes do
        local item = queue[index]
        index = index + 1
        visited = visited + 1

        local element = item.element
        if matcher(element) then
            local frame = elementFrame(element)
            local hidden = axAttribute(element, "AXHidden")
            local enabled = axAttribute(element, "AXEnabled")

            if frame and hidden ~= true and enabled ~= false and frameIntersectsWindow(frame, windowFrame) then
                if not bestFrame or frame.y > bestFrame.y
                    or (frame.y == bestFrame.y and frame.w * frame.h > bestFrame.w * bestFrame.h) then
                    bestPrompt = element
                    bestFrame = frame
                end
            end
        end

        if item.depth < axSearchMaxDepth then
            local children = axAttribute(element, "AXChildren")
            if type(children) == "table" then
                for _, child in ipairs(children) do
                    table.insert(queue, { element = child, depth = item.depth + 1 })
                end
            end
        end
    end

    return bestPrompt, visited
end

local function focusedElementIsPrompt(appElement, matcher)
    return (matcher or isPromptTextArea)(axAttribute(appElement, "AXFocusedUIElement"))
end

local function waitForPromptFocus(appElement, matcher)
    pcall(hs.timer.usleep, 60000)
    return focusedElementIsPrompt(appElement, matcher)
end

local function clickPromptElement(prompt)
    local frame = elementFrame(prompt)
    if not frame then
        return false
    end

    local point = {
        x = frame.x + frame.w * promptClickXRatio,
        y = frame.y + frame.h / 2,
    }

    log("Click prompt Accessibility frame", point.x, point.y)
    hs.eventtap.leftClick(point)
    return true
end

local function focusPromptWithAccessibility(app, win, matcher)
    if not ax or not ax.applicationElement then
        return false, "Accessibility module is unavailable"
    end

    local appElement = ax.applicationElement(app)
    if not appElement then
        return false, "Accessibility app element is unavailable"
    end

    local prompt, visited = findPromptTextArea(appElement, win and win:frame(), matcher)
    if not prompt then
        return false, "Prompt text area not found after " .. tostring(visited) .. " nodes"
    end

    local setFocusedOk, setFocusedResult = pcall(function()
        return prompt:setAttributeValue("AXFocused", true)
    end)

    if setFocusedOk and setFocusedResult ~= false and waitForPromptFocus(appElement, matcher) then
        return true, "Prompt focused via AXFocused after " .. tostring(visited) .. " nodes"
    end

    local pressOk, pressResult = pcall(function()
        return prompt:performAction("AXPress")
    end)

    if pressOk and pressResult ~= false and waitForPromptFocus(appElement, matcher) then
        return true, "Prompt focused via AXPress after " .. tostring(visited) .. " nodes"
    end

    if clickPromptElement(prompt) and waitForPromptFocus(appElement, matcher) then
        return true, "Prompt focused via Accessibility frame after " .. tostring(visited) .. " nodes"
    end

    return false, "Prompt focus was not confirmed"
end

local function ensureClaudePromptFocused(app, win)
    local promptFocused, focusMessage = focusPromptWithAccessibility(app, win)
    log(focusMessage)
    return promptFocused
end

local function ensureKimiPromptFocused(app, win)
    local promptFocused, focusMessage = focusPromptWithAccessibility(app, win, isTextInputElement)
    log(focusMessage)
    return promptFocused
end

local function frontmostAppName()
    local front = hs.application.frontmostApplication()
    return front and front:name() or "none"
end

local function appleScriptString(value)
    return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function runAppleScript(id, script)
    local callOk, ok, result, descriptor = pcall(hs.osascript.applescript, script)
    if callOk and ok then
        return result
    end

    local detail = callOk and (result or descriptor) or ok
    if type(detail) == "table" then
        detail = hs.inspect(detail)
    end
    logLine("applescript-error", id, detail or "unknown error")
    return nil
end

-- Looks, never selects: raising a window is a focus move, and no focus moves
-- before the lock is held. The gate selects the tab once it grants.
local function terminalTtyExists(id, targetTty)
    local script = [[
tell application "Terminal"
    repeat with terminalWindow in windows
        repeat with terminalTab in tabs of terminalWindow
            set matchedTty to tty of terminalTab as text
            if matchedTty is ]] .. appleScriptString(targetTty) .. [[ then
                return matchedTty
            end if
        end repeat
    end repeat
    return ""
end tell
]]
    local result = runAppleScript(id, script)
    return type(result) == "string" and result ~= "" and result or nil
end

local function selectedTerminalTty(id)
    local result = runAppleScript(id, [[
tell application "Terminal"
    if (count of windows) is 0 then return ""
    return tty of selected tab of front window as text
end tell
]])
    return type(result) == "string" and result ~= "" and result or nil
end

local function terminalContents(id, targetTty)
    local script
    if targetTty then
        script = [[
tell application "Terminal"
    repeat with windowIndex from 1 to count of windows
        repeat with tabIndex from 1 to count of tabs of window windowIndex
            if (tty of tab tabIndex of window windowIndex as text) is ]] .. appleScriptString(targetTty) .. [[ then
                return contents of tab tabIndex of window windowIndex
            end if
        end repeat
    end repeat
    return false
end tell
]]
    else
        script = [[
tell application "Terminal"
    if (count of windows) is 0 then return ""
    return contents of selected tab of front window as text
end tell
]]
    end

    local result = runAppleScript(id, script)
    return type(result) == "string" and result or nil
end

local function verificationNeedle(text)
    local firstLine = text:match("^[^\r\n]*") or ""
    if firstLine == "" then
        return nil
    end

    if utf8 and utf8.offset then
        local nextByte = utf8.offset(firstLine, 25)
        if nextByte then
            return firstLine:sub(1, nextByte - 1)
        end
        return firstLine
    end

    return firstLine:sub(1, 24)
end

local function countPlainOccurrences(contents, needle)
    local count = 0
    local position = 1
    while true do
        local startIndex, endIndex = contents:find(needle, position, true)
        if not startIndex then
            return count
        end
        count = count + 1
        position = endIndex + 1
    end
end

local function finishDelivery(id, onComplete, success, reason, clipboardSnapshot, clipboardCaptured)
    local function finish()
        deliveryBusy = false
        if not success then
            logLine("deliver-failed", id, reason)
            hs.alert.show("Delivery failed: " .. reason)
        end
        trimLog()
        if onComplete then
            onComplete(success, reason)
        end
    end

    if clipboardCaptured ~= nil then
        hs.timer.doAfter(restoreClipboardDelay, function()
            if not clipboardCaptured or not restoreClipboard(clipboardSnapshot) then
                logLine("clipboard-restore-fail", id, clipboardCaptured and "write failed" or "snapshot unavailable")
            end
            finish()
        end)
    else
        finish()
    end
end

local function setClipboardText(text)
    local ok, result = pcall(hs.pasteboard.setContents, text)
    return ok and result ~= false
end

local function runClaudeApp(pressReturnAfterPaste, onComplete, msgText, opts)
    deliveryBusy = true
    opts = opts or {}
    local id = opts.id or "app"
    local attempt = opts.attempt or 1
    local text = msgText or message
    logLine("deliver-start", id, "attempt=" .. attempt .. " claude-app")
    log("Start Claude App")
    hs.application.launchOrFocus(appName)

    hs.timer.doAfter(launchDelay, function()
        local app = hs.application.find(appName)
        if not app then
            logLine("focus-fail", id, "app=" .. frontmostAppName() .. " reason=not-found")
            finishDelivery(id, onComplete, false, "Claude not found")
            return
        end

        local win = app:mainWindow()
        if not win then
            logLine("focus-fail", id, "app=" .. frontmostAppName() .. " reason=no-window")
            finishDelivery(id, onComplete, false, "No Claude window")
            return
        end

        win:focus()

        hs.timer.doAfter(focusDelay, function()
            if not frontmostIsClaude() then
                logLine("focus-fail", id, "app=" .. frontmostAppName())
                finishDelivery(id, onComplete, false, "Claude is not focused")
                return
            end
            logLine("focus-ok", id, "app=Claude")

            ensureClaudePromptFocused(app, win)

            hs.timer.doAfter(clickDelay, function()
                if not frontmostIsClaude() then
                    logLine("focus-fail", id, "app=" .. frontmostAppName() .. " before-paste")
                    finishDelivery(id, onComplete, false, "Claude lost focus before paste")
                    return
                end

                if not ensureClaudePromptFocused(app, win) then
                    logLine("focus-fail", id, "app=Claude reason=prompt")
                    finishDelivery(id, onComplete, false, "Claude prompt is not focused")
                    return
                end

                local snapshotOk, clipboardSnapshot = pcall(hs.pasteboard.readAllData)
                if not setClipboardText(text) then
                    finishDelivery(id, onComplete, false, "clipboard set failed", clipboardSnapshot, snapshotOk)
                    return
                end

                hs.timer.doAfter(clipboardSettleDelay, function()
                    hs.eventtap.keyStroke({"cmd"}, "v")
                    hs.timer.doAfter(pasteDelay, function()
                        logLine("paste-unverified", id, "attempt=1 claude-app")
                        if pressReturnAfterPaste then
                            gptVoiceKeys.returnKey()
                            logLine("return-sent", id, "app=Claude")
                            log("Claude App message sent")
                        else
                            log("Claude App text pasted, Return disabled")
                            hs.alert.show("Claude App: text pasted, Return is disabled")
                        end
                        finishDelivery(id, onComplete, true, nil, clipboardSnapshot, snapshotOk)
                    end)
                end)
            end)
        end)
    end)
end

local function runKimi(pressReturnAfterPaste, onComplete, msgText, opts)
    deliveryBusy = true
    opts = opts or {}
    local id = opts.id or "kimi"
    local attempt = opts.attempt or 1
    local text = msgText or message
    logLine("deliver-start", id, "attempt=" .. attempt .. " kimi-app")
    log("Start Kimi")
    hs.application.launchOrFocus(kimiAppName)

    hs.timer.doAfter(launchDelay, function()
        local app = hs.application.get(kimiBundleId) or hs.application.find(kimiAppName)
        if not app then
            logLine("focus-fail", id, "app=" .. frontmostAppName() .. " reason=not-found")
            finishDelivery(id, onComplete, false, "Kimi not found")
            return
        end

        local win = app:mainWindow()
        if not win then
            logLine("focus-fail", id, "app=" .. frontmostAppName() .. " reason=no-window")
            finishDelivery(id, onComplete, false, "No Kimi window")
            return
        end

        win:focus()

        hs.timer.doAfter(focusDelay, function()
            if not frontmostIsKimi() then
                logLine("focus-fail", id, "app=" .. frontmostAppName())
                finishDelivery(id, onComplete, false, "Kimi is not focused")
                return
            end
            logLine("focus-ok", id, "app=Kimi")

            ensureKimiPromptFocused(app, win)

            hs.timer.doAfter(clickDelay, function()
                if not frontmostIsKimi() then
                    logLine("focus-fail", id, "app=" .. frontmostAppName() .. " before-paste")
                    finishDelivery(id, onComplete, false, "Kimi lost focus before paste")
                    return
                end

                if not ensureKimiPromptFocused(app, win) then
                    logLine("focus-fail", id, "app=Kimi reason=prompt")
                    finishDelivery(id, onComplete, false, "Kimi prompt is not focused")
                    return
                end

                local snapshotOk, clipboardSnapshot = pcall(hs.pasteboard.readAllData)
                if not setClipboardText(text) then
                    finishDelivery(id, onComplete, false, "clipboard set failed", clipboardSnapshot, snapshotOk)
                    return
                end

                hs.timer.doAfter(clipboardSettleDelay, function()
                    hs.eventtap.keyStroke({"cmd"}, "v")
                    hs.timer.doAfter(pasteDelay, function()
                        logLine("paste-unverified", id, "attempt=1 kimi-app")
                        if pressReturnAfterPaste then
                            gptVoiceKeys.returnKey()
                            logLine("return-sent", id, "app=Kimi")
                            log("Kimi message sent")
                        else
                            log("Kimi text pasted, Return disabled")
                            hs.alert.show("Kimi: text pasted, Return is disabled")
                        end
                        finishDelivery(id, onComplete, true, nil, clipboardSnapshot, snapshotOk)
                    end)
                end)
            end)
        end)
    end)
end

-- The terminal destination hands the keyboard to chat_gate: the burst slot, the
-- screen check, the tab, the dictation gate and the clipboard are its answers to
-- give, and a resume typed while a compaction is mid-switch is the interleaving that
-- slot exists to stop. What stays here is the one thing the gate has no view of --
-- reading the tab back to prove the paste landed before Return is pressed.
local function runTerminal(pressReturnAfterPaste, onComplete, msgText, opts)
    opts = opts or {}
    local id = opts.id or "terminal"
    local attempt = opts.attempt or 1
    local targetTty = opts.targetTty
    local text = msgText or message
    log("Start Terminal")

    local app = hs.application.find(terminalAppName)
    if not app then
        logLine("deliver-start", id, "attempt=" .. attempt .. " terminal-not-found")
        logLine("focus-fail", id, "app=" .. frontmostAppName() .. " reason=not-found")
        finishDelivery(id, onComplete, false, "Terminal not found")
        return
    end

    -- Explicit tty (LLM-armed timers) never falls back: with several live claude
    -- sessions open, "some other window" delivery would inject the message into the
    -- wrong session. No tty (menu sends) targets the active window only.
    local expectedTty = nil

    if type(targetTty) == "string" and targetTty ~= "" then
        logLine("deliver-start", id, "attempt=" .. attempt .. " tty=" .. targetTty)
        expectedTty = terminalTtyExists(id, targetTty)
        if not expectedTty then
            logLine("tty-missing", id, targetTty)
            finishDelivery(id, onComplete, false, "target tty not found")
            return
        end
    elseif frontmostIsTerminal() then
        -- The tab is pinned NOW, while the send is still the user's own gesture:
        -- behind another owner the delivery can be minutes away, and by then
        -- "frontmost" is wherever he has moved since.
        expectedTty = selectedTerminalTty(id)
        logLine("deliver-start", id, "attempt=" .. attempt
            .. " frontmost-tab tty=" .. tostring(expectedTty))
    else
        logLine("deliver-start", id, "attempt=" .. attempt .. " main-window")
    end

    local win = app:mainWindow()
    if not win then
        logLine("focus-fail", id, "app=" .. frontmostAppName() .. " reason=no-window")
        finishDelivery(id, onComplete, false, "No Terminal window")
        return
    end

    local needle = verificationNeedle(text)
    if not needle then
        finishDelivery(id, onComplete, false, "empty verification needle")
        return
    end
    local contentsTty = targetTty and expectedTty or nil

    local gateLog = function(event, detail) logLine(event, id, detail or "") end

    -- One answer per delivery: the gate reports its own give-ups through onEnd
    -- while this path reports the reads it does itself, and both funnel here.
    local settled = false
    local job = nil
    local function settle(success, reason)
        if settled then return end
        settled = true
        -- The job goes first: it hands the keyboard and the clipboard back, and
        -- whatever onComplete arms next finds this destination free.
        if job then
            if success then
                job:finish(reason or "delivered")
            else
                job:fail("deliver-failed", reason or "unknown")
            end
        end
        finishDelivery(id, onComplete, success, reason)
    end

    -- Without a tty the target is "whatever Terminal window is frontmost when the
    -- burst runs". With the keyboard free that is still the window this send came
    -- from; behind someone else's burst it is wherever the user has moved since.
    if not expectedTty then
        local gate = ChatGate.overview()
        if gate.slot ~= nil or gate.queue > 0 then
            logLine("no-target", id, "no tty and the keyboard is taken; dropped rather than typing into the frontmost window")
            ChatGate.refuse({ kind = "continue", key = id, log = gateLog,
                reason = "no-target", detail = "no tty while the keyboard was busy" })
            settle(false, "no target tab")
            return
        end
    end

    local started = false
    local function pasteAttempt(pasteAttemptNumber)
        -- The wait holds nothing and the burst is the world re-check: a resume can
        -- stand in line behind a whole compaction, and everything this delivery was
        -- told before it asked for the keyboard turns over while it waits.
        job:waitForIdle({ label = "resume", skipRegistry = true }, function()
            job:burst({
                label = "resume",
                tabAlert = "Continue: target tab not found",
                focusAlert = "Continue: target tab did not come frontmost",
                legacyAlert = "Continue: nothing typed - Terminal not frontmost",
                voiceAlert = "Continue: dictation running; nothing typed",
                -- No tty means no tab to select, so the window is asked for here -
                -- inside the slot, because raising Terminal is itself a focus move
                -- and doing it while another burst types is what the slot forbids.
                check = function()
                    if not expectedTty then
                        app:activate(true)
                        win:focus()
                    end
                    return true
                end,
            }, function(burst)
                deliveryBusy = true
                -- The delivery starts HERE, not when it was armed: everything before
                -- this was waiting for a turn.
                if not started then
                    started = true
                    if type(opts.onStarted) == "function" then opts.onStarted() end
                end
                -- Clearing the composer comes FIRST and the baseline after it: a
                -- retry follows a paste that half-landed, and counting the leftover
                -- Ctrl+U is about to erase makes the re-paste look like it changed
                -- nothing.
                local function withBaseline()
                    local beforeContents = terminalContents(id, contentsTty)
                    if not beforeContents then
                        settle(false, "could not read terminal contents before paste")
                        return
                    end
                    local countBefore = countPlainOccurrences(beforeContents, needle)
                    job:runBurst("resume", {
                        { kind = "paste", value = text, detail = needle, delayAfter = pasteDelay },
                    }, "Continue: focus moved while pasting", function()
                        local afterContents = terminalContents(id, contentsTty)
                        local countAfter = afterContents and countPlainOccurrences(afterContents, needle) or -1
                        if countAfter <= countBefore then
                            logLine("paste-missing", id, "attempt=" .. pasteAttemptNumber
                                .. " before=" .. countBefore .. " after=" .. countAfter)
                            if pasteAttemptNumber < 2 then
                                -- The keyboard goes back between the tries: a burst
                                -- that is done with it can never type again, so the
                                -- retry asks for a slot of its own.
                                burst:done("the paste did not land")
                                pasteAttempt(pasteAttemptNumber + 1)
                            else
                                settle(false, "paste verification failed")
                            end
                            return
                        end

                        logLine("paste-verified", id, "attempt=" .. pasteAttemptNumber
                            .. " before=" .. countBefore .. " after=" .. countAfter)

                        if not pressReturnAfterPaste then
                            log("Terminal text pasted, Return disabled")
                            hs.alert.show("Terminal: text pasted, Return is disabled")
                            settle(true)
                            return
                        end

                        job:runBurst("resume return", {
                            { kind = "key", modifiers = {}, key = "return", detail = "return" },
                        }, "Continue: focus lost before Return", function()
                            logLine("return-sent", id, "tty=" .. tostring(expectedTty))
                            log("Terminal message sent")
                            settle(true)
                        end)
                    end)
                end

                if pasteAttemptNumber > 1 or attempt > 1 then
                    job:runBurst("resume clear", {
                        { kind = "key", modifiers = {"ctrl"}, key = "u", detail = "Ctrl+U",
                            delayAfter = clipboardSettleDelay },
                    }, "Continue: focus moved while clearing the line", withBaseline)
                else
                    withBaseline()
                end
            end)
        end)
    end

    local why
    job, why = ChatGate.startJob({
        kind = "continue",
        -- Keyed by destination, not by tab: one destination delivers one message at
        -- a time, so a re-arm is refused rather than queued behind the delivery it
        -- supersedes - and the watchdog below can name exactly the entry whose
        -- attempt it just gave up on.
        key = id,
        log = gateLog,
        horizon = deliveryHorizon,
        detail = "resume armed",
        -- The resume is the point of the window it lands in: handing focus back
        -- would hide the chat that was just told to carry on.
        keepFocus = true,
        target = { ttyPath = expectedTty, termProgram = "Apple_Terminal" },
        onEnd = function(state, reason, detail, alertText)
            if state == "done" then return end
            logLine(reason or "gate", id, detail or "")
            settle(false, alertText or detail or reason)
        end,
    })
    if job == nil then
        settle(false, "the gate has this destination: " .. tostring(why))
        return
    end
    pasteAttempt(1)
end

destinationDefinitions = {
    {
        id = "app",
        label = "Claude App",
        run = runClaudeApp,
    },
    {
        id = "terminal",
        label = "Claude Terminal",
        run = runTerminal,
    },
    {
        id = "kimi",
        label = "Kimi",
        run = runKimi,
    },
}

-- Which destinations get the gate wrapped around them here rather than taking it
-- themselves.
local gateMutexed = { app = true, kimi = true }

local function runDestination(id, pressReturnAfterPaste, onComplete, msgText, opts)
    local destination = destinationDefinition(id)
    if not destination or not destination.run then
        stopWithAlert("Send To: unknown destination", onComplete)
        return
    end

    opts = opts or {}
    opts.id = id

    local function invocationFailed(event, reason)
        logLine(event, id, reason)
        hs.alert.show("Delivery failed: " .. reason)
        trimLog()
        if onComplete then
            onComplete(false, reason)
        end
    end

    local settled = false
    local function invokeNow(done)
        local ok, err = pcall(destination.run, pressReturnAfterPaste, function(success, reason)
            done(success, reason)
            if settled then return end
            settled = true
            if onComplete then
                onComplete(success, reason)
            end
        end, msgText, opts)
        if not ok then
            deliveryBusy = false
            done(false, tostring(err))
            if not settled then
                settled = true
                invocationFailed("run-error", tostring(err))
            end
        end
    end

    local function invoke(retried)
        if deliveryBusy then
            if not retried then
                hs.timer.doAfter(3, function()
                    invoke(true)
                end)
            else
                invocationFailed("deliver-failed", "another delivery in flight")
            end
            return
        end

        -- The terminal destination takes the gate itself, with its tab and its
        -- guards. The app destinations have no terminal to guard, but they activate
        -- a window and paste into it, and doing that inside another module's burst
        -- moves the focus that burst's guard is checking - so they hold the keyboard
        -- through a burst of their own, as a plain mutex.
        if not gateMutexed[id] then
            invokeNow(function() end)
            return
        end

        local job, why = ChatGate.startJob({
            kind = "continue",
            key = id,
            log = function(event, detail) logLine(event, id, detail or "") end,
            horizon = deliveryHorizon,
            detail = id .. " delivery",
            target = {},
            onEnd = function(state, reason, detail, alertText)
                if state == "done" then return end
                logLine(reason or "gate", id, detail or "")
                -- The gate gave up on this delivery, and nothing else will report
                -- it: without this deliveryBusy stays set and every later send is
                -- refused as "another delivery in flight".
                deliveryBusy = false
                if settled then return end
                settled = true
                invocationFailed("gate-gave-up", alertText or detail or reason)
            end,
        })
        if job == nil then
            if settled then return end
            settled = true
            invocationFailed("gate-refused", "the gate has this destination: " .. tostring(why))
            return
        end
        job:burst({
            label = id,
            budget = deliveryHorizon,
            -- These destinations focus their own app window and type through their
            -- own timer chain, so the burst guards nothing and only keeps the
            -- keyboard: no tab to select, and a dictation must not cancel a delivery
            -- that never asked the gate for one.
            focus = false,
            voiceMaxWait = 0.5,
            voiceDeadline = "proceed",
        }, function(burst)
            if type(opts.onStarted) == "function" then opts.onStarted() end
            -- The keyboard is let go only once the chain reports back: it never
            -- consults the burst, so there is no way to stop it mid-paste, and
            -- letting go early would hand the next burst a keyboard to type over it.
            invokeNow(function(success, reason)
                burst:done(success and "delivered" or "failed")
                -- Ended as done either way: the delivery's own failure has already
                -- been reported through onComplete, and failing the job here would
                -- report it a second time as a give-up by the gate.
                job:finish(success and "delivered"
                    or ("failed: " .. tostring(reason or "unknown")))
            end)
        end)
    end

    invoke(false)
end

local function runDestinationsSequentially(ids, index, pressReturnAfterPaste)
    local id = ids[index]
    if not id then
        return
    end

    runDestination(id, pressReturnAfterPaste, function()
        if ids[index + 1] then
            hs.timer.doAfter(sendGapDelay, function()
                runDestinationsSequentially(ids, index + 1, pressReturnAfterPaste)
            end)
        end
    end, nil, { attempt = 1 })
end

local function runSelectedDestinations(pressReturnAfterPaste)
    local ids = enabledDestinationIds()

    if #ids == 0 then
        hs.alert.show("Send To: no destination selected")
        return
    end

    runDestinationsSequentially(ids, 1, pressReturnAfterPaste)
end

local function destinationTimerStatus(id)
    local entry = destinationTimers[id]
    if not entry then
        return { armed = false }
    end

    local remainingSeconds = entry.firesAt - os.time()
    if remainingSeconds < 0 then
        remainingSeconds = 0
    end
    local remainingMinutes = math.ceil(remainingSeconds / 60)

    return {
        armed = true,
        overdue = entry.overdue == true,
        attempts = entry.attempts or 0,
        targetTty = entry.targetTty,
        firesAt = entry.firesAt,
        firesAtText = formatClock(entry.firesAt),
        remainingMinutes = remainingMinutes,
        remainingText = formatRemainingMinutes(remainingMinutes),
    }
end

local function fireDestinationTimer(id)
    local entry = destinationTimers[id]
    if not entry then
        return
    end
    entry.timer = nil
    logLine("fired", id, entry.message)
    deliverOrDefer(id)
end

persistState = function()
    local data = { timers = {} }
    local any = false
    for id, entry in pairs(destinationTimers) do
        data.timers[id] = {
            firesAt = entry.firesAt,
            message = entry.message,
            overdue = entry.overdue == true,
            repeating = entry.repeating == true,
            firedOnce = entry.firedOnce == true,
            targetTty = entry.targetTty,
            attempts = entry.attempts or 0,
        }
        any = true
    end

    if not any then
        os.remove(statePath)
        return
    end

    local ok, encoded = pcall(hs.json.encode, data)
    if not ok then
        log("persistState: encode failed")
        return
    end

    local f = io.open(statePath, "w")
    if not f then
        log("persistState: could not open " .. statePath)
        return
    end
    f:write(encoded)
    f:close()
end

ensureLockWatcher = function()
    if lockWatcher then
        return
    end
    lockWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake
            or event == hs.caffeinate.watcher.screensDidWake
            or event == hs.caffeinate.watcher.screensDidUnlock
            or event == hs.caffeinate.watcher.sessionDidBecomeActive then
            for id, entry in pairs(destinationTimers) do
                if entry.overdue then
                    retryDeliver(id)
                end
            end
        end
    end)
    lockWatcher:start()
    logLine("watcher-armed", "-", "caffeinate wake/unlock watcher started")
end

stopRetry = function(id)
    local entry = destinationTimers[id]
    if entry and entry.retryTimer then
        entry.retryTimer:stop()
        entry.retryTimer = nil
    end
end

startRetry = function(id)
    local entry = destinationTimers[id]
    if not entry then
        return
    end
    ensureLockWatcher()
    if entry.retryTimer then
        return
    end
    entry.retryTimer = hs.timer.doEvery(300, function()
        retryDeliver(id)
    end)
end

-- Delivers now if the screen is unlocked; otherwise marks the timer overdue and leaves
-- it to the 5-minute retry loop and the wake/unlock watcher. A locked screen swallows
-- keystrokes, so typing into it would silently lose the message (the original incident).
deliverOrDefer = function(id)
    local entry = destinationTimers[id]
    if not entry or entry.delivering then
        return
    end

    if ChatGate.screenIsLocked() then
        entry.overdue = true
        entry.timer = nil
        logLine("locked-deferred", id, "screen locked; will retry every 5 min / on wake")
        startRetry(id)
        persistState()
        notifyStatusChanged()
        return
    end

    pcall(hs.caffeinate.userActivity, true)

    local msg = entry.message
    local repeating = entry.repeating == true
    local targetTty = entry.targetTty
    entry.overdue = false
    entry.delivering = true
    entry.started = false
    stopRetry(id)
    persistState()

    -- Waiting for the keyboard is not an attempt. Deliveries queue behind a
    -- compaction or a chat switch, which legitimately hold the lock for minutes,
    -- and counting that as a failed try burned all three inside a quarter of an
    -- hour and then DELETED the armed resume - the silent loss this whole
    -- retry/defer machinery exists to prevent. The count and this deadline both
    -- start when the delivery actually gets the keyboard.
    local function armWatchdog()
        if entry.watchdog then entry.watchdog:stop() end
        entry.watchdog = hs.timer.doAfter(120, function()
            if destinationTimers[id] ~= entry or not entry.delivering then
                return
            end

            entry.watchdog = nil
            entry.delivering = false
            entry.overdue = true
            entry.timer = nil
            deliveryBusy = false
            -- Whatever is still waiting for the keyboard is this attempt's, and this
            -- attempt is over: left in the queue it would be granted later and type a
            -- resume the retry loop has already replaced.
            ChatGate.cancel(id, "the delivery timed out")
            if entry.started then
                logLine("watchdog", id, "attempt=" .. entry.attempts .. " delivery timed out")
            else
                logLine("watchdog", id, "never got the keyboard in 120s; retrying, no attempt spent")
            end
            startRetry(id)
            persistState()
            notifyStatusChanged()
            trimLog()
        end)
    end
    armWatchdog()

    runDestination(id, true, function(success, reason)
        if entry.watchdog then
            entry.watchdog:stop()
            entry.watchdog = nil
        end

        if destinationTimers[id] ~= entry then
            return
        end

        entry.delivering = false
        if not success then
            entry.overdue = true
            entry.timer = nil
            if entry.attempts >= maxDeliveryAttempts then
                stopRetry(id)
                destinationTimers[id] = nil
                logLine("deliver-failed", id, "attempt=" .. entry.attempts .. " final reason="
                    .. tostring(reason or "unknown"))
                hs.alert.show("Delivery failed after " .. entry.attempts .. " attempts")
            else
                logLine("retry-armed", id, "attempt=" .. entry.attempts .. " next=5m")
                startRetry(id)
            end

            persistState()
            notifyStatusChanged()
            trimLog()
            return
        end

        stopRetry(id)
        destinationTimers[id] = nil

        if repeating and timerIntervalSeconds then
            local firesAt = os.time() + timerIntervalSeconds
            destinationTimers[id] = {
                timer = hs.timer.doAfter(timerIntervalSeconds, function()
                    fireDestinationTimer(id)
                end),
                firesAt = firesAt,
                message = msg,
                overdue = false,
                repeating = true,
                firedOnce = true,
                targetTty = targetTty,
                attempts = 0,
            }
            logLine("delivered", id, msg .. " (repeat, next " .. (formatClock(firesAt) or "?") .. ")")
        else
            if repeating then
                -- Combined repeat cycle ends here: no interval configured anymore.
                timerMode = nil
                selectedStartDelayMinutes = nil
            end
            logLine("delivered", id, msg)
        end

        persistState()
        notifyStatusChanged()
        trimLog()
    end, msg, {
        attempt = (entry.attempts or 0) + 1,
        targetTty = targetTty,
        onStarted = function()
            if destinationTimers[id] ~= entry or entry.started then return end
            entry.started = true
            entry.attempts = (entry.attempts or 0) + 1
            armWatchdog()
            persistState()
        end,
    })
end

retryDeliver = function(id)
    local entry = destinationTimers[id]
    if not entry or not entry.overdue then
        stopRetry(id)
        return
    end
    if ChatGate.screenIsLocked() then
        logLine("retry", id, "still locked")
        return
    end
    logLine("retry", id, "screen unlocked; delivering")
    deliverOrDefer(id)
end

-- Combined ("Send To" / First Run / Repeat) arm path: arms the same per-destination
-- slots used by startTimerFor/stopTimerFor, replacing whatever was there. index-based
-- stagger keeps two destinations armed for the same instant from pasting at once while
-- firesAt (the displayed/persisted time) stays identical across them.
local function armCombinedSlot(id, delaySeconds, index, firedOnce)
    stopRetry(id)
    if destinationTimers[id] and destinationTimers[id].timer then
        destinationTimers[id].timer:stop()
    end

    local stagger = (index - 1) * sendGapDelay
    local firesAt = os.time() + delaySeconds

    destinationTimers[id] = {
        timer = hs.timer.doAfter(delaySeconds + stagger, function()
            fireDestinationTimer(id)
        end),
        firesAt = firesAt,
        message = message,
        overdue = false,
        repeating = true,
        firedOnce = firedOnce == true,
        attempts = 0,
    }

    logLine("armed", id, "fires " .. (formatClock(firesAt) or "?") .. " msg=" .. message
        .. (firedOnce and " (repeat)" or ""))
    persistState()
end

local function hasPendingCombinedSlot()
    for _, entry in pairs(destinationTimers) do
        if entry.repeating and not entry.firedOnce then
            return true
        end
    end
    return false
end

local function hasAnyCombinedSlot()
    for _, entry in pairs(destinationTimers) do
        if entry.repeating then
            return true
        end
    end
    return false
end

local function combinedNextRunAt()
    local earliest = nil
    for _, entry in pairs(destinationTimers) do
        if entry.repeating and (not earliest or entry.firesAt < earliest) then
            earliest = entry.firesAt
        end
    end
    return earliest
end

restoreState = function()
    trimLog()

    local f = io.open(statePath, "r")
    if not f then
        return
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return
    end

    local ok, data = pcall(hs.json.decode, content)
    if not ok or type(data) ~= "table" or type(data.timers) ~= "table" then
        logLine("restore-error", "-", "could not parse " .. statePath)
        return
    end

    local now = os.time()
    for id, saved in pairs(data.timers) do
        if destinationDefinition(id) and type(saved) == "table" and type(saved.firesAt) == "number" then
            local msgText = type(saved.message) == "string" and saved.message or message

            local repeating = saved.repeating == true
            local firedOnce = saved.firedOnce == true
            local targetTty = type(saved.targetTty) == "string" and saved.targetTty or nil
            local attempts = math.max(0, tonumber(saved.attempts) or 0)

            if saved.firesAt > now then
                local delaySeconds = saved.firesAt - now
                destinationTimers[id] = {
                    timer = hs.timer.doAfter(delaySeconds, function()
                        fireDestinationTimer(id)
                    end),
                    firesAt = saved.firesAt,
                    message = msgText,
                    overdue = false,
                    repeating = repeating,
                    firedOnce = firedOnce,
                    targetTty = targetTty,
                    attempts = attempts,
                }
                logLine("restored", id, "fires " .. (formatClock(saved.firesAt) or "?"))
            else
                destinationTimers[id] = {
                    firesAt = saved.firesAt,
                    message = msgText,
                    overdue = true,
                    repeating = repeating,
                    firedOnce = firedOnce,
                    targetTty = targetTty,
                    attempts = attempts,
                }
                logLine("restored-overdue", id, "fireAt in past; entering delivery mode")
                startRetry(id)
                hs.timer.doAfter(2, function()
                    deliverOrDefer(id)
                end)
            end
        end
    end

    notifyStatusChanged()
end

-- One-shot slot arm (LLM/CLI path, not repeating): shares the same per-destination
-- slot as the combined arm path, so either one replaces whatever the other left there.
-- Never touches destinationEnabled or the other destination's slot.
function ClaudeContinue.startTimerFor(id, minutes, customMessage, targetTty)
    local destination = destinationDefinition(id)
    if not destination then
        hs.alert.show("Timer: unknown destination")
        return
    end

    minutes = tonumber(minutes) or 0
    if minutes < 0 then
        minutes = 0
    end

    local msgText = (type(customMessage) == "string" and customMessage ~= "") and customMessage or message
    targetTty = (type(targetTty) == "string" and targetTty ~= "") and targetTty or nil

    local replaced = destinationTimers[id] ~= nil
    if replaced then
        stopRetry(id)
        if destinationTimers[id].timer then
            destinationTimers[id].timer:stop()
        end
        destinationTimers[id] = nil
    end

    if minutes == 0 then
        destinationTimers[id] = {
            firesAt = os.time(),
            message = msgText,
            overdue = false,
            targetTty = targetTty,
            attempts = 0,
        }
        logLine("armed", id, "immediate (+0m) msg=" .. msgText
            .. (targetTty and " tty=" .. targetTty or ""))
        persistState()
        notifyStatusChanged()
        fireDestinationTimer(id)
        hs.alert.show(destination.label .. ": sending now" .. (replaced and " (replaced previous timer)" or ""))
        return
    end

    local delaySeconds = minutes * 60
    local firesAt = os.time() + delaySeconds

    destinationTimers[id] = {
        timer = hs.timer.doAfter(delaySeconds, function()
            fireDestinationTimer(id)
        end),
        firesAt = firesAt,
        message = msgText,
        overdue = false,
        targetTty = targetTty,
        attempts = 0,
    }

    logLine("armed", id, "fires " .. (formatClock(firesAt) or "?") .. " msg=" .. msgText
        .. (targetTty and " tty=" .. targetTty or ""))
    persistState()
    notifyStatusChanged()
    hs.alert.show(destination.label .. ": fires at " .. (formatClock(firesAt) or "?")
        .. (replaced and " (replaced previous timer)" or ""))
end

function ClaudeContinue.stopTimerFor(id)
    local destination = destinationDefinition(id)
    if not destination then
        hs.alert.show("Timer: unknown destination")
        return
    end

    local existed = destinationTimers[id] ~= nil
    if existed then
        stopRetry(id)
        if destinationTimers[id].timer then
            destinationTimers[id].timer:stop()
        end
        destinationTimers[id] = nil
        -- A delivery can be sitting in the gate queue for as long as another burst
        -- holds the keyboard; left there it would be granted later and type into
        -- the session he just told it not to.
        ChatGate.cancel(id, "its timer was stopped")
        logLine("cancelled", id, "timer stopped")
        persistState()
    end

    notifyStatusChanged()

    if existed then
        hs.alert.show(destination.label .. ": timer stopped")
    end
end

local function timerStatusText()
    local next = combinedNextRunAt()
    if not next then
        return destinationLabel() .. ": timer is off"
    end

    local nextTime = formatClock(next) or "unknown"

    if timerIntervalSeconds then
        return destinationLabel() .. ": next " .. nextTime .. ", then every " .. formatInterval(timerIntervalSeconds)
    end

    return destinationLabel() .. ": next " .. nextTime .. ", no repeat"
end

function ClaudeContinue.paste()
    runSelectedDestinations(false)
end

function ClaudeContinue.send()
    runSelectedDestinations(true)
end

function ClaudeContinue.toggleDestination(id)
    local destination = destinationDefinition(id)
    if not destination then
        hs.alert.show("Send To: unknown destination")
        return
    end

    destinationEnabled[id] = not destinationEnabled[id]
    notifyStatusChanged()
    hs.alert.show("Send To: " .. destinationLabel())
end

function ClaudeContinue.setDestinationEnabled(id, enabled)
    local destination = destinationDefinition(id)
    if not destination then
        hs.alert.show("Send To: unknown destination")
        return
    end

    destinationEnabled[id] = enabled and true or false
    notifyStatusChanged()
end

function ClaudeContinue.setIntervalMinutes(minutes)
    if minutes == nil then
        timerIntervalSeconds = nil

        local stoppedAny = false
        for id, entry in pairs(destinationTimers) do
            if entry.repeating and entry.firedOnce then
                stopRetry(id)
                if entry.timer then
                    entry.timer:stop()
                end
                destinationTimers[id] = nil
                stoppedAny = true
                logLine("cancelled", id, "repeat interval cleared")
            end
        end

        if stoppedAny then
            timerMode = nil
            selectedStartDelayMinutes = nil
            persistState()
        end

        notifyStatusChanged()

        if hasPendingCombinedSlot() then
            hs.alert.show(timerStatusText())
        else
            hs.alert.show(destinationLabel() .. ": no repeat")
        end

        return
    end

    timerIntervalSeconds = minutes * 60

    for id, entry in pairs(destinationTimers) do
        if entry.repeating and entry.firedOnce then
            stopRetry(id)
            if entry.timer then
                entry.timer:stop()
            end

            local firesAt = os.time() + timerIntervalSeconds
            destinationTimers[id] = {
                timer = hs.timer.doAfter(timerIntervalSeconds, function()
                    fireDestinationTimer(id)
                end),
                firesAt = firesAt,
                message = entry.message,
                overdue = false,
                repeating = true,
                firedOnce = true,
                targetTty = entry.targetTty,
                attempts = 0,
            }
            logLine("armed", id, "fires " .. (formatClock(firesAt) or "?") .. " msg=" .. entry.message
                .. " (repeat interval changed)")
        end
    end

    persistState()
    notifyStatusChanged()

    if hasAnyCombinedSlot() then
        hs.alert.show(timerStatusText())
    else
        hs.alert.show(destinationLabel() .. ": repeat " .. formatInterval(timerIntervalSeconds))
    end
end

-- Combined arm path: replaces the enabled destinations' slots (whatever startTimerFor
-- may have armed there) with slots driven by the global First Run delay / Repeat interval.
function ClaudeContinue.startTimerAfterMinutes(minutes)
    local ids = enabledDestinationIds()
    if #ids == 0 then
        hs.alert.show("Send To: no destination selected")
        return
    end

    selectedStartDelayMinutes = minutes
    timerMode = minutes == 0 and "now" or ("in " .. formatInterval(minutes * 60))

    if minutes == 0 then
        local immediateNoRepeat = timerIntervalSeconds == nil

        runSelectedDestinations(true)

        if timerIntervalSeconds then
            for index, id in ipairs(ids) do
                armCombinedSlot(id, timerIntervalSeconds, index, true)
            end
        else
            timerMode = nil
            selectedStartDelayMinutes = nil
        end

        notifyStatusChanged()

        if immediateNoRepeat then
            hs.alert.show(destinationLabel() .. ": sent, no repeat")
            return
        end
    else
        local delaySeconds = minutes * 60

        for index, id in ipairs(ids) do
            armCombinedSlot(id, delaySeconds, index, false)
        end

        notifyStatusChanged()
    end

    hs.alert.show(timerStatusText())
end

function ClaudeContinue.startTimerNow()
    ClaudeContinue.startTimerAfterMinutes(0)
end

-- Stops every armed slot (used by the "Stop Both" menu action and as the general
-- stop-everything entry point). Per-destination stop stays on stopTimerFor.
function ClaudeContinue.stopTimer()
    local any = false

    for _, destination in ipairs(destinationDefinitions) do
        local id = destination.id
        if destinationTimers[id] then
            stopRetry(id)
            if destinationTimers[id].timer then
                destinationTimers[id].timer:stop()
            end
            destinationTimers[id] = nil
            logLine("cancelled", id, "timer stopped")
            any = true
        end
    end

    timerMode = nil
    selectedStartDelayMinutes = nil

    if any then
        persistState()
    end
    notifyStatusChanged()

    if any then
        hs.alert.show("Timers stopped")
    end
end

function ClaudeContinue.showStatus()
    hs.alert.show(timerStatusText())
end

function ClaudeContinue.getStatus()
    local destinations = {}
    local timers = {}
    local anyArmed = false
    local earliestFiresAt = nil
    local anyPendingCombined = false
    local anyPeriodicCombined = false

    for _, destination in ipairs(destinationDefinitions) do
        local timerStatus = destinationTimerStatus(destination.id)
        table.insert(destinations, {
            id = destination.id,
            label = destination.label,
            enabled = destinationEnabled[destination.id] == true,
            timer = timerStatus,
        })
        timers[destination.id] = timerStatus

        local entry = destinationTimers[destination.id]
        if entry then
            anyArmed = true
            if not earliestFiresAt or entry.firesAt < earliestFiresAt then
                earliestFiresAt = entry.firesAt
            end
            if entry.repeating then
                if entry.firedOnce then
                    anyPeriodicCombined = true
                else
                    anyPendingCombined = true
                end
            end
        end
    end

    return {
        timers = timers,
        appName = appName,
        terminalAppName = terminalAppName,
        message = message,
        destinations = destinations,
        destinationText = destinationLabel(),
        timerRunning = anyArmed,
        firstRunPending = anyPendingCombined,
        repeating = anyPeriodicCombined,
        repeatEnabled = timerIntervalSeconds ~= nil,
        timerIntervalSeconds = timerIntervalSeconds,
        timerIntervalText = timerIntervalSeconds and formatInterval(timerIntervalSeconds) or "do not repeat",
        nextRunAt = earliestFiresAt,
        nextRunAtText = formatClock(earliestFiresAt),
        timerMode = timerMode,
        selectedStartDelayMinutes = selectedStartDelayMinutes,
    }
end

ClaudeContinue.hotkey = hs.hotkey.bind({"ctrl", "alt", "cmd"}, "C", ClaudeContinue.paste)

_G.ClaudeContinue = ClaudeContinue

-- Restore timers persisted before the last Hammerspoon reload/restart. A fireAt already
-- in the past re-enters delivery mode immediately (overdue), so a reload during an armed
-- window no longer silently drops the resume.
local restoreOk, restoreErr = pcall(restoreState)
if not restoreOk then
    logLine("restore-error", "-", tostring(restoreErr))
end

return ClaudeContinue
