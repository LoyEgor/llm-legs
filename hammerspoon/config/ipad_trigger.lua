local IpadTrigger = {}

local port = 8765
local server = hs.httpserver.new(false, false)
local sidecarActive = false
local sidecarInFlight = false
local sidecarRunId = 0
local sidecarRunStartedAt = nil
local sidecarRunHealed = false
local lastResult = "none"
local logSubscribers = {}
local resultSubscribers = {}
local maxConnectAttempts = 2
local verificationTimeout = 18
local launcherTimeout = 25
local sidecarLauncherPath = "/Users/egorloy/.local/bin/SidecarLauncher"
local sidecarBin = "/Users/egorloy/.local/bin/sidecar"

local function notify(title, msg, opts)
    if _G.Notify and _G.Notify.send then
        _G.Notify.send(title, msg, opts)
    end
end

local function notifyLog(line)
    if _G.Notify and _G.Notify.log then
        _G.Notify.log(line)
    end
end

local function ipadPresenceSuffix()
    if _G.IpadMode and _G.IpadMode.isOn then
        local ok, present = pcall(_G.IpadMode.isOn)
        if ok then
            return "\niPad present: " .. tostring(present)
        end
    end
    return ""
end

-- Single source of truth for /sidecar-status: the trace/verdict of the current or last run,
-- populated regardless of entry point (menu via triggerConnect, or the /sidecar-on hook).
local runTrace = {}
local runVerdict = "none"

local function traceReset(verdict)
    runTrace = {}
    runVerdict = verdict
end

-- Dispatch over a snapshot so a subscriber that unsubscribes itself mid-dispatch cannot
-- shift the array and skip the next subscriber.
local function dispatch(subscribers, ...)
    local snapshot = {}
    for i = 1, #subscribers do
        snapshot[i] = subscribers[i]
    end
    for _, fn in ipairs(snapshot) do
        pcall(fn, ...)
    end
end

local function logSidecar(event, detail)
    local text = tostring(detail or ""):gsub("[\r\n]+", " ")
    local line = os.date("%Y-%m-%d %H:%M:%S") .. " " .. event .. " " .. text
    runTrace[#runTrace + 1] = line

    local file = io.open(hs.configdir .. "/ipad_trigger.log", "a")
    if file then
        file:write(line, "\n")
        file:close()
    end

    dispatch(logSubscribers, event, text)
end

-- Lets external callers (e.g. sidecar_connect.lua) observe this run's steps/outcome
-- without duplicating the single-flight state machine below. Returns an unsubscribe fn.
function IpadTrigger.onLogLine(fn)
    logSubscribers[#logSubscribers + 1] = fn
    return function()
        for i, f in ipairs(logSubscribers) do
            if f == fn then
                table.remove(logSubscribers, i)
                break
            end
        end
    end
end

function IpadTrigger.onResult(fn)
    resultSubscribers[#resultSubscribers + 1] = fn
    return function()
        for i, f in ipairs(resultSubscribers) do
            if f == fn then
                table.remove(resultSubscribers, i)
                break
            end
        end
    end
end

local function response(body, code)
    return body, code, {
        ["Content-Type"] = "text/plain; charset=utf-8",
        ["Cache-Control"] = "no-store",
    }
end

local function sidecarPresentNow()
    for _, screen in ipairs(hs.screen.allScreens()) do
        local name = screen:name() or ""
        if name:find("Sidecar", 1, true) or name:find("iPad", 1, true) then
            return true
        end
    end

    return false
end

local function openDisplaysSettings()
    os.execute('/usr/bin/open "x-apple.systempreferences:com.apple.preference.displays"')

    hs.timer.doAfter(0.5, function()
        os.execute('/usr/bin/open "/System/Library/PreferencePanes/Displays.prefPane"')
    end)
end

-- Locate the Displays "Add" menu button by walking the window for a menu/pop-up button
-- named or described "Add", instead of a hardcoded nested element path that breaks whenever
-- the Settings layout shifts.
local addBtnHelper = [[
using terms from application "System Events"
    on findAddBtn(el, dleft)
        if dleft < 0 then return missing value
        try
            if role of el is "AXMenuButton" or role of el is "AXPopUpButton" then
                set nm to ""
                try
                    if name of el is not missing value then set nm to name of el
                end try
                set dsc to ""
                try
                    if description of el is not missing value then set dsc to description of el
                end try
                if nm contains "Add" or dsc contains "Add" then return el
            end if
        end try
        try
            repeat with k in (UI elements of el)
                set f to my findAddBtn(k, dleft - 1)
                if f is not missing value then return f
            end repeat
        end try
        return missing value
    end findAddBtn
end using terms from
]]

local function toggleIpadInDisplays(allowStaleDisconnect)
    -- Lua strips the newline right after [[, so add it explicitly or the property line fuses with the tell line (-2740)
    local script = "property allowStaleDisconnect : " .. (allowStaleDisconnect and "true" or "false") .. "\n" .. addBtnHelper .. [[
tell application "System Settings"
    activate
end tell

tell application "System Events"
    tell process "System Settings"
        set frontmost to true

        repeat 20 times
            if exists window "Displays" then exit repeat
            delay 0.25
        end repeat

        if not (exists window "Displays") then
            return "FAIL: Displays window not found"
        end if

        set displaysWindow to window "Displays"
        set addButton to missing value
        repeat 12 times
            set addButton to my findAddBtn(displaysWindow, 16)
            if addButton is not missing value then exit repeat
            delay 0.4
        end repeat
        if addButton is missing value then
            return "FAIL: Displays Add button not found - Settings layout changed?"
        end if
        set selectedIpad to missing value

        repeat 8 times
            click addButton
            delay 1

            repeat with menuItem in menu items of menu 1 of addButton
                try
                    set itemName to name of menuItem
                    if itemName is not missing value then
                        if itemName contains "iPad" then
                            set selectedIpad to itemName
                            set itemChecked to false
                            try
                                set markChar to value of attribute "AXMenuItemMarkChar" of menuItem
                                if markChar is not missing value and (markChar as text) is not "" then
                                    set itemChecked to true
                                end if
                            on error
                                set itemChecked to false
                            end try

                            if not itemChecked then
                                click menuItem
                                return "OK_SELECTED: " & selectedIpad
                            end if

                            if not allowStaleDisconnect then
                                return "CHECKED: " & selectedIpad
                            end if

                            click menuItem
                            delay 2
                            set reconnectedIpad to missing value

                            repeat 8 times
                                click addButton
                                delay 1

                                repeat with reopenedItem in menu items of menu 1 of addButton
                                    try
                                        set reopenedName to name of reopenedItem
                                        if reopenedName is not missing value then
                                            if reopenedName contains "iPad" then
                                                set reconnectedIpad to reopenedName
                                                set reopenedChecked to false
                                                try
                                                    set reopenedMark to value of attribute "AXMenuItemMarkChar" of reopenedItem
                                                    if reopenedMark is not missing value and (reopenedMark as text) is not "" then
                                                        set reopenedChecked to true
                                                    end if
                                                on error
                                                    set reopenedChecked to false
                                                end try

                                                if not reopenedChecked then
                                                    delay 1.5
                                                    click reopenedItem
                                                    return "OK_RECONNECTED: " & reconnectedIpad
                                                end if
                                            end if
                                        end if
                                    end try
                                end repeat

                                try
                                    key code 53
                                on error
                                end try

                                delay 0.75
                            end repeat

                            return "FAIL: No iPad item found after clearing stale checkmark"
                        end if
                    end if
                end try
            end repeat

            if selectedIpad is not missing value then exit repeat

            try
                key code 53
            on error
            end try

            delay 0.75
        end repeat

        if selectedIpad is missing value then
            return "FAIL: No iPad item found"
        end if

        return "FAIL: iPad item was not handled"
    end tell
end tell
]]

    local ok, result, descriptor = hs.osascript.applescript(script)

    if ok then
        local resultText = type(result) == "string" and result or tostring(result)
        print("[ipad-trigger] sidecar toggle:", resultText)
        local checkedName = not allowStaleDisconnect and resultText:match("^CHECKED:%s*(.*)$")
        if checkedName then
            -- Never clear a checked item when the live Sidecar screen has appeared.
            if sidecarPresentNow() then
                return "OK_ALREADY_CONNECTED: " .. checkedName, nil
            end
        end
        return resultText, nil
    end

    local errorText = result
    if errorText == nil and descriptor ~= nil then
        errorText = hs.inspect(descriptor)
    end
    if errorText == nil then
        errorText = "unknown osascript error"
    end

    print("[ipad-trigger] sidecar toggle failed:", hs.inspect(result), hs.inspect(descriptor))
    return nil, tostring(errorText)
end

local runConnectionAttempt
local prepareAppleScriptAttempt

local function launcherAvailable()
    local attributes = hs.fs.attributes(sidecarLauncherPath)
    return attributes ~= nil
        and attributes.mode == "file"
        and type(attributes.permissions) == "string"
        and attributes.permissions:find("x", 1, true) ~= nil
end

local function cancelSidecarTimers()
    if IpadTrigger.sidecarTimer then
        IpadTrigger.sidecarTimer:stop()
        IpadTrigger.sidecarTimer = nil
    end
    if IpadTrigger.sidecarVerifyTimer then
        IpadTrigger.sidecarVerifyTimer:stop()
        IpadTrigger.sidecarVerifyTimer = nil
    end
    if IpadTrigger.launcherWatchdogTimer then
        IpadTrigger.launcherWatchdogTimer:stop()
        IpadTrigger.launcherWatchdogTimer = nil
    end
    if IpadTrigger.launcherTask then
        pcall(function()
            IpadTrigger.launcherTask:terminate()
        end)
        IpadTrigger.launcherTask = nil
    end
    if IpadTrigger.systemSettingsQuitTask then
        pcall(function()
            IpadTrigger.systemSettingsQuitTask:terminate()
        end)
        IpadTrigger.systemSettingsQuitTask = nil
    end
    if IpadTrigger.runWatchdogTimer then
        IpadTrigger.runWatchdogTimer:stop()
        IpadTrigger.runWatchdogTimer = nil
    end
end

-- Guarded so it never launches Settings just to quit it. Held in a field so the fire-and-
-- forget task is not GC-orphaned before it runs.
local function quitSystemSettingsAsync()
    local script = [[
tell application "System Events"
    if exists (application process "System Settings") then
        tell application "System Settings" to quit
    end if
end tell
]]
    local t = hs.task.new("/usr/bin/osascript", function() end, { "-e", script })
    if t then
        IpadTrigger.finalQuitTask = t
        t:start()
    end
end

local function finishSidecarRun(runId, connected, message)
    if runId ~= sidecarRunId then
        return
    end

    -- Invalidate the run BEFORE terminating tasks: cancelSidecarTimers() terminates
    -- launcherTask, whose exit callback checks runId == sidecarRunId. Bumping first means
    -- that late callback sees a stale id and cannot resume the fallback into a second verdict.
    sidecarRunId = sidecarRunId + 1

    cancelSidecarTimers()
    quitSystemSettingsAsync()
    sidecarInFlight = false
    sidecarRunStartedAt = nil
    sidecarActive = connected
    lastResult = message
    runVerdict = connected and "CONNECTED" or "FAILED"

    if connected then
        logSidecar("verified", message)
        hs.alert.show("Sidecar: connected")
        notify("Sidecar OK", message .. ipadPresenceSuffix(), { priority = "high" })
    else
        logSidecar("failed", message)
        hs.alert.show("Sidecar failed")
        notify("Sidecar FAILED", message .. ipadPresenceSuffix(), { priority = "high" })
    end

    dispatch(resultSubscribers, connected, message)
end

local function scheduleConnectionRetry(runId, attempt, reason)
    if runId ~= sidecarRunId then
        return
    end

    if attempt >= maxConnectAttempts then
        finishSidecarRun(runId, false, reason)
        return
    end

    logSidecar("retry", "attempt=" .. tostring(attempt + 1) .. " reason=" .. tostring(reason))
    notify("Sidecar", "Connection was not confirmed. Retrying…", { priority = "low" })
    prepareAppleScriptAttempt(runId, attempt + 1)
end

local function verifyConnection(runId, attempt, result)
    local startedAt = os.time()

    local function finishIfPresent()
        if sidecarPresentNow() then
            local reconnected = result:match("^OK_RECONNECTED:%s*(.*)$")
            local selected = result:match("^OK_SELECTED:%s*(.*)$")
            local already = result:match("^OK_ALREADY_CONNECTED:%s*(.*)$")
            local launched = result:match("^OK_LAUNCHER:%s*(.*)$")
            local deviceName = reconnected or selected or already or launched or "iPad"
            local message = reconnected and ("Reconnected: " .. deviceName)
                or already and ("Already connected: " .. deviceName)
                or ("Connected: " .. deviceName)
            finishSidecarRun(runId, true, message)
            return true
        end
        return false
    end

    local function poll()
        if runId ~= sidecarRunId then
            return
        end

        if finishIfPresent() then
            return
        end

        if os.difftime(os.time(), startedAt) >= verificationTimeout then
            if result:match("^OK_LAUNCHER:") then
                local graceStartedAt = os.time()
                local function gracePoll()
                    if runId ~= sidecarRunId then
                        return
                    end
                    if finishIfPresent() then
                        return
                    end
                    if os.difftime(os.time(), graceStartedAt) >= 10 then
                        scheduleConnectionRetry(runId, attempt, "Sidecar display did not appear")
                        return
                    end
                    IpadTrigger.sidecarVerifyTimer = hs.timer.doAfter(1, gracePoll)
                end
                IpadTrigger.sidecarVerifyTimer = hs.timer.doAfter(1, gracePoll)
                return
            end
            scheduleConnectionRetry(runId, attempt, "Sidecar display did not appear")
            return
        end

        IpadTrigger.sidecarVerifyTimer = hs.timer.doAfter(1, poll)
    end

    IpadTrigger.sidecarVerifyTimer = hs.timer.doAfter(2, poll)
end

runConnectionAttempt = function(runId, attempt, allowStaleDisconnect)
    if runId ~= sidecarRunId then
        return
    end

    IpadTrigger.sidecarTimer = nil
    if not allowStaleDisconnect then
        logSidecar("attempt", "number=" .. tostring(attempt))
    end

    local callOk, result, errorText = pcall(toggleIpadInDisplays, allowStaleDisconnect == true)
    if not callOk then
        scheduleConnectionRetry(runId, attempt, tostring(result))
        return
    end
    if not result then
        scheduleConnectionRetry(runId, attempt, errorText or "Unknown AppleScript error")
        return
    end

    logSidecar("ui-result", result)
    local checkedName = not allowStaleDisconnect and result:match("^CHECKED:%s*(.*)$")
    if checkedName then
        local checkedAt = os.time()
        local function pollCheckedItem()
            if runId ~= sidecarRunId then
                return
            end
            if sidecarPresentNow() then
                finishSidecarRun(runId, true, "Already connected: " .. checkedName)
                return
            end
            if os.difftime(os.time(), checkedAt) >= 5 then
                hs.osascript.applescript('tell application "System Events" to key code 53')
                runConnectionAttempt(runId, attempt, true)
                return
            end
            IpadTrigger.sidecarVerifyTimer = hs.timer.doAfter(1, pollCheckedItem)
        end
        IpadTrigger.sidecarVerifyTimer = hs.timer.doAfter(1, pollCheckedItem)
        return
    end
    if result:match("^OK_SELECTED:") or result:match("^OK_RECONNECTED:")
        or result:match("^OK_ALREADY_CONNECTED:") then
        verifyConnection(runId, attempt, result)
        return
    end

    scheduleConnectionRetry(runId, attempt, result)
end

prepareAppleScriptAttempt = function(runId, attempt)
    if runId ~= sidecarRunId then
        return
    end

    logSidecar("fallback", "attempt=" .. tostring(attempt))
    local quitTask = hs.task.new("/usr/bin/osascript", function()
        if runId ~= sidecarRunId then
            return
        end
        IpadTrigger.systemSettingsQuitTask = nil
        IpadTrigger.sidecarTimer = hs.timer.doAfter(1, function()
            IpadTrigger.sidecarTimer = nil
            if runId ~= sidecarRunId then
                return
            end
            openDisplaysSettings()
            IpadTrigger.sidecarTimer = hs.timer.doAfter(3, function()
                IpadTrigger.sidecarTimer = nil
                runConnectionAttempt(runId, attempt)
            end)
        end)
    end, { "-e", "quit app \"System Settings\"" })
    IpadTrigger.systemSettingsQuitTask = quitTask
    if not quitTask or not quitTask:start() then
        IpadTrigger.systemSettingsQuitTask = nil
        IpadTrigger.sidecarTimer = hs.timer.doAfter(1, function()
            IpadTrigger.sidecarTimer = nil
            if runId == sidecarRunId then
                openDisplaysSettings()
                IpadTrigger.sidecarTimer = hs.timer.doAfter(3, function()
                    IpadTrigger.sidecarTimer = nil
                    runConnectionAttempt(runId, attempt)
                end)
            end
        end)
    end
end

local function runLauncherTask(runId, arguments, onExit, onTimeout)
    local finished = false
    local task
    local watchdog
    task = hs.task.new(sidecarLauncherPath, function(exitCode, stdOut, stdErr)
        -- Clear the shared upvalue (also unpins the watchdog closure's view of it):
        -- a callback still referencing `task` pins the hs.task userdata forever.
        local self = task
        task = nil
        if finished then
            return
        end
        finished = true
        if watchdog and IpadTrigger.launcherWatchdogTimer == watchdog then
            watchdog:stop()
            IpadTrigger.launcherWatchdogTimer = nil
        end
        if IpadTrigger.launcherTask == self then
            IpadTrigger.launcherTask = nil
        end
        if runId == sidecarRunId then
            onExit(exitCode, stdOut or "", stdErr or "")
        end
    end, arguments)

    if not task or not task:start() then
        task = nil
        return false
    end

    IpadTrigger.launcherTask = task
    watchdog = hs.timer.doAfter(launcherTimeout, function()
        if finished or runId ~= sidecarRunId or IpadTrigger.launcherTask ~= task then
            return
        end
        finished = true
        IpadTrigger.launcherTask = nil
        IpadTrigger.launcherWatchdogTimer = nil
        pcall(function()
            task:terminate()
        end)
        onTimeout()
    end)
    IpadTrigger.launcherWatchdogTimer = watchdog
    return true
end

local function startAppleScriptFallback(runId, reason)
    if runId ~= sidecarRunId then
        return
    end
    lastResult = "launcher fallback: " .. tostring(reason)
    logSidecar("launcher-fallback", reason)
    prepareAppleScriptAttempt(runId, 1)
end

local function pickLauncherDevice(output)
    local firstLine
    for line in tostring(output):gmatch("[^\r\n]+") do
        local name = line:match("^%s*(.-)%s*$")
        if name ~= "" then
            firstLine = firstLine or name
            if name:find("iPad", 1, true) then
                return name
            end
        end
    end
    return firstLine
end

local function startLauncherConnection(runId)
    if not launcherAvailable() then
        startAppleScriptFallback(runId, "binary unavailable")
        return
    end

    logSidecar("attempt", "method=SidecarLauncher")
    local started = runLauncherTask(runId, { "devices" }, function(exitCode, stdOut, stdErr)
        local deviceName = exitCode == 0 and pickLauncherDevice(stdOut) or nil
        if not deviceName then
            startAppleScriptFallback(runId,
                "devices exit=" .. tostring(exitCode) .. " " .. tostring(stdErr):gsub("[\r\n]+", " "))
            return
        end

        logSidecar("launcher-device", deviceName)
        local connectStarted = runLauncherTask(runId, { "connect", deviceName }, function(connectExit, connectOut, connectErr)
            if connectExit == 0 then
                logSidecar("launcher-result", tostring(connectOut):gsub("[\r\n]+", " "))
                lastResult = "launcher connected; verifying"
                verifyConnection(runId, 0, "OK_LAUNCHER: " .. deviceName)
            else
                startAppleScriptFallback(runId,
                    "connect exit=" .. tostring(connectExit) .. " " .. tostring(connectErr):gsub("[\r\n]+", " "))
            end
        end, function()
            startAppleScriptFallback(runId, "connect timeout")
        end)
        if not connectStarted then
            startAppleScriptFallback(runId, "connect task failed to start")
        end
    end, function()
        startAppleScriptFallback(runId, "devices timeout")
    end)
    if not started then
        startAppleScriptFallback(runId, "devices task failed to start")
    end
end

local refreshTasks = {}

-- `sidecar refresh` can hang (esp. right after a daemon restart), so cap it at 15s and hold
-- the task in a set until it resolves — a bare local would be GC-orphaned and its callback
-- would never fire.
local function sidecarRefreshShowsIpad(cb)
    local done = false
    local t, watchdog
    local function finishOnce(found)
        if done then return end
        done = true
        if watchdog then
            watchdog:stop()
            watchdog = nil
        end
        if t then refreshTasks[t] = nil end
        cb(found)
    end
    t = hs.task.new(sidecarBin, function(_, out)
        finishOnce(tostring(out or ""):lower():find("ipad", 1, true) ~= nil)
    end, { "refresh" })
    if not t then
        finishOnce(false)
        return
    end
    refreshTasks[t] = true
    if not t:start() then
        refreshTasks[t] = nil
        finishOnce(false)
        return
    end
    watchdog = hs.timer.doAfter(15, function()
        pcall(function() t:terminate() end)
        finishOnce(false)
    end)
end

local function startSidecarRun()
    if sidecarPresentNow() then
        if sidecarInFlight then
            sidecarRunId = sidecarRunId + 1
            cancelSidecarTimers()
        end
        sidecarActive = true
        sidecarInFlight = false
        sidecarRunStartedAt = nil
        lastResult = "already connected"
        traceReset("CONNECTED")
        logSidecar("request", "already-connected")
        notify("Sidecar OK", "Already connected." .. ipadPresenceSuffix(), { priority = "high" })
        -- Resolve any observer still waiting on an earlier in-flight run so its attempt
        -- unsubscribes and cannot stay IN PROGRESS forever.
        dispatch(resultSubscribers, true, "already connected")
        return "already-connected", "ALREADY: Sidecar active"
    end

    if sidecarInFlight then
        local age = math.floor(sidecarRunStartedAt and os.difftime(os.time(), sidecarRunStartedAt) or 0)
        -- Duplicate requests share one run so display-control processes cannot overlap.
        if age <= 60 then
            logSidecar("request", "ignored-in-flight")
            notify("Sidecar", "Connection already in progress (" .. age .. "s).", { priority = "low" })
            return "in-progress", "BUSY: attempt already running (" .. age .. "s)"
        end
        logSidecar("request", "wedged-restart age=" .. tostring(age))
        sidecarRunId = sidecarRunId + 1
        cancelSidecarTimers()
        sidecarInFlight = false
    end

    sidecarRunId = sidecarRunId + 1
    local runId = sidecarRunId

    cancelSidecarTimers()
    sidecarInFlight = true
    sidecarRunStartedAt = os.time()
    sidecarRunHealed = false
    sidecarActive = false
    lastResult = "in progress"
    traceReset("IN PROGRESS")

    -- Hard cap: no run may sit in-flight forever. If the state machine stalls (a hung heal,
    -- a wedged AppleScript), reset single-flight so the button works again and the status
    -- stops reading IN PROGRESS.
    IpadTrigger.runWatchdogTimer = hs.timer.doAfter(180, function()
        if runId == sidecarRunId and sidecarInFlight then
            logSidecar("watchdog", "reset: run exceeded 180s")
            finishSidecarRun(runId, false, "watchdog reset: connection hung (>180s)")
        end
    end)

    logSidecar("request", "new-run")

    if _G.AutomationMenu and _G.AutomationMenu.show then
        _G.AutomationMenu.show()
    end

    local function beginConnection(handoffOk)
        if runId ~= sidecarRunId then
            return
        end
        if handoffOk == false then
            logSidecar("handoff-warning", "force-enable was not confirmed")
        end

        -- Pre-step: if the relay shows no iPad, run the Handoff heal cycle once before
        -- connecting. Bounded to once per run; other in-flight callers are gated by the
        -- single-flight state above and healCycle's own healInFlight guard.
        sidecarRefreshShowsIpad(function(hasIpad)
            if runId ~= sidecarRunId then
                return
            end
            if hasIpad or sidecarRunHealed
                or not (_G.HandoffGuard and _G.HandoffGuard.healCycle) then
                startLauncherConnection(runId)
                return
            end
            sidecarRunHealed = true
            logSidecar("heal", "no iPad in refresh; running Handoff healCycle")
            _G.HandoffGuard.healCycle(function(healed, variant)
                logSidecar("heal-done", "healed=" .. tostring(healed) .. " variant=" .. tostring(variant))
                if runId == sidecarRunId then
                    startLauncherConnection(runId)
                end
            end)
        end)
    end

    if _G.HandoffGuard and _G.HandoffGuard.forceEnable then
        _G.HandoffGuard.forceEnable(beginConnection)
    else
        beginConnection(true)
    end
    return "started", "OK: connecting iPad…"
end

local function appRunning(name, processPattern)
    if processPattern == "JumpConnect" then
        -- Exclude Jump's always-running root service from the user-agent check.
        local _, ok = hs.execute("/usr/bin/pgrep -fl JumpConnect | /usr/bin/awk '$2 == \"/Applications/Jump\" && $3 == \"Desktop\" && $4 == \"Connect.app/Contents/MacOS/JumpConnect\" && $0 !~ /--service/ { found=1 } END { exit(found ? 0 : 1) }'")
        return ok == true
    end
    if hs.application.get(name) ~= nil then
        return true
    end
    local _, ok = hs.execute('/usr/bin/pgrep -f "' .. processPattern .. '" >/dev/null 2>&1')
    return ok == true
end

local function statusText()
    local screenNames = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        screenNames[#screenNames + 1] = screen:name() or ""
    end
    local ipadPresent = _G.IpadMode and _G.IpadMode.isOn
        and _G.IpadMode.isOn() or false
    local recent = _G.Notify and _G.Notify.recent and _G.Notify.recent() or ""
    return table.concat({
        "ipadPresent: " .. tostring(ipadPresent),
        "screens: " .. table.concat(screenNames, ", "),
        "BetterDisplay: " .. (appRunning("BetterDisplay", "BetterDisplay.app") and "yes" or "no"),
        "Jump Desktop Connect: " .. (appRunning("Jump Desktop Connect", "JumpConnect") and "yes" or "no"),
        "SidecarLauncher: " .. (launcherAvailable() and "yes" or "no"),
        "sidecarPresent: " .. tostring(sidecarPresentNow()),
        "sidecarActiveMemory: " .. tostring(sidecarActive),
        "sidecarInFlight: " .. tostring(sidecarInFlight),
        "inFlight: " .. tostring(sidecarInFlight),
        "lastResult: " .. tostring(lastResult),
        "--- recent log ---",
        recent,
        "",
    }, "\n")
end

server:setPort(port)
server:setInterface(nil)
server:setCallback(function(method, path, headers, body)
    if path == "/ping" then
        local remote = headers["Remote-Addr"] or headers["remote-addr"] or "unknown"

        print("[ipad-trigger] ping", method, remote, body or "")
        hs.alert.show("iPad trigger received")
        notifyLog("iPad ping from " .. remote)

        return response("ok\n", 200)
    end

    if path == "/sidecar-on" then
        print("[ipad-trigger] sidecar-on", method, body or "")
        -- Receipt ack on EVERY hook, before any branch, so a tap that reaches HS is always
        -- acknowledged on the Mac even when the run itself is a no-op or throws.
        notify("Sidecar", "Connection request received from iPad", { priority = "high" })

        local started, outcome, humanMessage = pcall(function()
            return startSidecarRun()
        end)

        if not started then
            sidecarRunId = sidecarRunId + 1
            cancelSidecarTimers()
            sidecarInFlight = false
            sidecarRunStartedAt = nil
            lastResult = tostring(outcome)
            runVerdict = "FAILED"
            print("[ipad-trigger] sidecar start exception:", outcome)
            logSidecar("failed", tostring(outcome))
            notify("Sidecar FAILED", tostring(outcome) .. ipadPresenceSuffix(), { priority = "high" })
            return response("ERROR: " .. tostring(outcome) .. "\n", 500)
        end

        return response((humanMessage or "OK: request accepted") .. "\n", 200)
    end

    if path == "/sidecar-open-displays" then
        print("[ipad-trigger] sidecar-open-displays", method, body or "")

        openDisplaysSettings()
        hs.alert.show("Sidecar: opening Displays")

        return response("sidecar-open-displays ok\n", 200)
    end

    if path == "/status" and method == "GET" then
        return response(statusText(), 200)
    end

    if path == "/sidecar-status" and method == "GET" then
        return response(IpadTrigger.lastRunSlice(), 200)
    end

    if path == "/test-notify" then
        notify("Test", "Тестовое уведомление: " .. os.date("%H:%M:%S"))
        return response("sent\n", 200)
    end

    return response("not found\n", 404)
end)

local function startServer()
    local ok, result = pcall(function()
        return server:start()
    end)
    if not ok or result == nil or result == false then
        print("ERROR: iPad trigger server failed to start on port", port, result)
        notify("iPad trigger FAILED", "iPad trigger: сервер на порту 8765 не запустился", { priority = "high" })
        return false
    end
    return true
end

startServer()

function IpadTrigger.getPort()
    return port
end

function IpadTrigger.stop()
    sidecarRunId = sidecarRunId + 1
    cancelSidecarTimers()
    sidecarInFlight = false
    sidecarRunStartedAt = nil
    server:stop()
end

function IpadTrigger.start()
    return startServer()
end

function IpadTrigger.getSidecarActive()
    return sidecarPresentNow()
end

-- Trace/verdict of the current or last run, whatever entry point started it. Single source
-- of truth behind GET /sidecar-status.
function IpadTrigger.lastRunSlice()
    if runVerdict == "none" then
        return "no attempt recorded yet"
    end
    return "verdict: " .. runVerdict .. "\n" .. table.concat(runTrace, "\n")
end

-- Same entry point /sidecar-on uses; exposed so sidecar_connect.lua can drive it
-- in-process instead of re-implementing the single-flight run/retry/fallback logic.
function IpadTrigger.triggerConnect()
    return startSidecarRun()
end

function IpadTrigger.isInFlight()
    return sidecarInFlight
end

function IpadTrigger.resetSidecarActive()
    sidecarActive = false
end

IpadTrigger.server = server

_G.IpadTrigger = IpadTrigger

return IpadTrigger
