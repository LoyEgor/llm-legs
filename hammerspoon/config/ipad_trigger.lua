local IpadTrigger = {}

local port = 8765
local server = hs.httpserver.new(false, false)
local sidecarActive = false
local sidecarInFlight = false
local sidecarRunId = 0
local sidecarRunStartedAt = nil
local lastResult = "none"
local maxConnectAttempts = 2
local verificationTimeout = 18
local launcherTimeout = 25
local sidecarLauncherPath = "/Users/egorloy/.local/bin/SidecarLauncher"

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

local function logSidecar(event, detail)
    local file = io.open(hs.configdir .. "/ipad_trigger.log", "a")
    if not file then
        return
    end

    local text = tostring(detail or ""):gsub("[\r\n]+", " ")
    file:write(os.date("%Y-%m-%d %H:%M:%S"), " ", event, " ", text, "\n")
    file:close()
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

local function toggleIpadInDisplays(allowStaleDisconnect)
    local script = "property allowStaleDisconnect : " .. (allowStaleDisconnect and "true" or "false") .. [[
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
        set addButton to menu button "Add" of group 1 of group 3 of splitter group 1 of group 1 of displaysWindow
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
end

local function finishSidecarRun(runId, connected, message)
    if runId ~= sidecarRunId then
        return
    end

    cancelSidecarTimers()
    sidecarInFlight = false
    sidecarRunStartedAt = nil
    sidecarActive = connected
    lastResult = message

    if connected then
        logSidecar("verified", message)
        hs.alert.show("Sidecar: connected")
        notify("Sidecar OK", message, { priority = "high" })
    else
        logSidecar("failed", message)
        hs.alert.show("Sidecar failed")
        notify("Sidecar FAILED", message, { priority = "high" })
    end
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
        if finished then
            return
        end
        finished = true
        if watchdog and IpadTrigger.launcherWatchdogTimer == watchdog then
            watchdog:stop()
            IpadTrigger.launcherWatchdogTimer = nil
        end
        if IpadTrigger.launcherTask == task then
            IpadTrigger.launcherTask = nil
        end
        if runId == sidecarRunId then
            onExit(exitCode, stdOut or "", stdErr or "")
        end
    end, arguments)

    if not task or not task:start() then
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
        logSidecar("request", "already-connected")
        notify("Sidecar", "Sidecar is already connected.", { priority = "low" })
        return "already-connected"
    end

    if sidecarInFlight then
        local age = sidecarRunStartedAt and os.difftime(os.time(), sidecarRunStartedAt) or 0
        -- Duplicate requests share one run so display-control processes cannot overlap.
        if age <= 60 then
            logSidecar("request", "ignored-in-flight")
            notify("Sidecar", "Connection is already in progress.", { priority = "low" })
            return "in-progress"
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
    sidecarActive = false
    lastResult = "in progress"

    logSidecar("request", "new-run")
    notify("Sidecar", "Request received from iPad. Starting connection…", { priority = "low" })

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
        startLauncherConnection(runId)
    end

    if _G.HandoffGuard and _G.HandoffGuard.forceEnable then
        _G.HandoffGuard.forceEnable(beginConnection)
    else
        beginConnection(true)
    end
    return "started"
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
    local state = _G.MonitorAutomation and _G.MonitorAutomation.getState
        and _G.MonitorAutomation.getState() or "UNKNOWN"
    local recent = _G.Notify and _G.Notify.recent and _G.Notify.recent() or ""
    return table.concat({
        "state: " .. tostring(state),
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

        local started, outcome = pcall(function()
            return startSidecarRun()
        end)

        if not started then
            sidecarRunId = sidecarRunId + 1
            cancelSidecarTimers()
            sidecarInFlight = false
            sidecarRunStartedAt = nil
            lastResult = tostring(outcome)
            print("[ipad-trigger] sidecar start exception:", outcome)
            logSidecar("failed", tostring(outcome))
            notify("Sidecar FAILED", tostring(outcome), { priority = "high" })
            return response("failed\n", 500)
        end

        if outcome == "already-connected" then
            return response("already connected\n", 200)
        elseif outcome == "in-progress" then
            return response("in progress\n", 200)
        end

        hs.alert.show("Sidecar: reconnecting")
        return response("sidecar-on ok\n", 200)
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

function IpadTrigger.isInFlight()
    return sidecarInFlight
end

function IpadTrigger.resetSidecarActive()
    sidecarActive = false
end

IpadTrigger.server = server

_G.IpadTrigger = IpadTrigger

return IpadTrigger
