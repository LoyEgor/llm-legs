local ipcOk, ipcError = pcall(function()
    require("hs.ipc")
    local installed = hs.ipc.cliInstall("/opt/homebrew")
    if installed == false then
        print("ERROR: hs IPC CLI installation failed")
    end
end)
if not ipcOk then
    print("ERROR: hs IPC setup failed:", ipcError)
end

local notifyOk, notifyError = pcall(function()
    dofile(hs.configdir .. "/notify.lua")
end)

if not notifyOk then
    print("ERROR: Notification module failed to load:", notifyError)
end

local function notify(title, msg, opts)
    if _G.Notify and _G.Notify.send then
        _G.Notify.send(title, msg, opts)
    end
end

local currentState = nil
-- Init from reality: hs.reload wipes the flag while the apps keep running.
local jumpUserProcessCommand = [[/usr/bin/pgrep -fl JumpConnect | /usr/bin/awk '$2 == "/Applications/Jump" && $3 == "Desktop" && $4 == "Connect.app/Contents/MacOS/JumpConnect" && $0 !~ /--service/ { found=1 } END { exit(found ? 0 : 1) }']]
local _, jumpUserProcessRunning = hs.execute(jumpUserProcessCommand)
local dummyStarted = hs.application.get("BetterDisplay") ~= nil and jumpUserProcessRunning == true
local pending = {}
local nextPendingId = 0
local actionGeneration = 0
local unknownNotified = {}

local function showAutomationMenu()
    if _G.AutomationMenu and _G.AutomationMenu.show then
        _G.AutomationMenu.show()
    end
end

local function virtualDisplayPresent()
    for _, screen in ipairs(hs.screen.allScreens()) do
        if (screen:name() or ""):find("Virtual", 1, true) then
            return true
        end
    end
    return false
end

local function verifyApps(expectRunning, title, delay)
    nextPendingId = nextPendingId + 1
    local pendingId = nextPendingId
    local generation = actionGeneration
    local entry = {}
    pending[pendingId] = entry

    entry.timer = hs.timer.doAfter(delay, function()
        entry.timer = nil
        if generation ~= actionGeneration then
            pending[pendingId] = nil
            return
        end

        local betterDisplayRunning = hs.application.get("BetterDisplay") ~= nil
        -- Exclude Jump's always-running root service from the user-agent check.
        entry.task = hs.task.new("/bin/sh", function(exitCode)
            pending[pendingId] = nil
            if generation ~= actionGeneration then
                return
            end

            local jumpRunning = exitCode == 0
            local virtualRunning = virtualDisplayPresent()
            local expected = expectRunning and "✓ запущен" or "✓ завершён"
            local unexpected = expectRunning and "✗ не запущен" or "✗ всё ещё запущен"
            local virtualExpected = expectRunning and "✓ появился" or "✗ всё ещё активен"
            local virtualUnexpected = expectRunning and "✗ не появился" or "✓ выключен"
            local lines = {
                "BetterDisplay: " .. (betterDisplayRunning == expectRunning and expected or unexpected),
                "Jump Desktop Connect: " .. (jumpRunning == expectRunning and expected or unexpected),
                "Virtual display: " .. (virtualRunning and virtualExpected or virtualUnexpected),
            }
            notify(title, table.concat(lines, "\n"), { priority = "high" })
        end, { "-c", jumpUserProcessCommand })
        if not entry.task or not entry.task:start() then
            pending[pendingId] = nil
            if generation ~= actionGeneration then
                return
            end

            local virtualRunning = virtualDisplayPresent()
            local virtualStatus
            if expectRunning then
                virtualStatus = virtualRunning and "✓ появился" or "✗ не появился"
            else
                virtualStatus = virtualRunning and "✗ всё ещё активен" or "✓ выключен"
            end
            notify(title, "BetterDisplay: " .. (betterDisplayRunning and "✓ запущен" or "✗ не запущен")
                .. "\nJump Desktop Connect: ✗ проверка не выполнена"
                .. "\nVirtual display: " .. virtualStatus,
                { priority = "high" })
        end
    end)
end

local function enableDummy()
    actionGeneration = actionGeneration + 1
    dummyStarted = true
    print("ACTION: ENABLE_DUMMY")
    if _G.HandoffGuard and _G.HandoffGuard.forceEnable then
        _G.HandoffGuard.forceEnable()
    end
    os.execute('open -a BetterDisplay')
    os.execute('open -a "Jump Desktop Connect"')
    showAutomationMenu()
    verifyApps(true, "Monitor OFF action", 10)
end

local function disableDummy()
    actionGeneration = actionGeneration + 1
    dummyStarted = false
    print("ACTION: DISABLE_DUMMY")
    os.execute('osascript -e \'quit app "BetterDisplay"\'')
    os.execute('osascript -e \'quit app "Jump Desktop Connect"\'')
    verifyApps(false, "Monitor ON action", 8)
end

local function physicalMonitorPresent()
    for _, s in ipairs(hs.screen.allScreens()) do
        if s:name() == "PL3461WQ" then
            return true
        end
    end

    return false
end

local function screenStateSnapshot(screens)
    local hasPhysicalOn = false
    local hasPhysicalOff = false
    local hasSidecar = false

    for _, screen in ipairs(screens) do
        local name = screen:name()
        if name == "PL3461WQ" then
            hasPhysicalOn = true
        elseif name == "" then
            hasPhysicalOff = true
        elseif (name or ""):find("Sidecar", 1, true) or (name or ""):find("iPad", 1, true) then
            hasSidecar = true
        end
    end

    if hasPhysicalOn then
        return "MONITOR_ON", hasSidecar
    elseif hasPhysicalOff then
        return "MONITOR_OFF", hasSidecar
    end
    return "NO_PHYSICAL", hasSidecar
end

local function cancelDummyConfirmation()
    local monitor = _G.MonitorAutomation
    if monitor and monitor.dummyConfirmTimer then
        monitor.dummyConfirmTimer:stop()
        monitor.dummyConfirmTimer = nil
    end
end

local function armDummyConfirmation()
    local monitor = _G.MonitorAutomation
    if not monitor or monitor.dummyConfirmTimer then
        return
    end

    -- Confirm against a fresh screen snapshot after transient Sidecar handshakes settle.
    monitor.dummyConfirmTimer = hs.timer.doAfter(10, function()
        monitor.dummyConfirmTimer = nil
        local confirmedState, confirmedSidecar = screenStateSnapshot(hs.screen.allScreens())
        if confirmedState ~= "MONITOR_ON" and not confirmedSidecar and not dummyStarted then
            local sidecarInFlight = _G.IpadTrigger and _G.IpadTrigger.isInFlight
                and _G.IpadTrigger.isInFlight()
            if sidecarInFlight then
                armDummyConfirmation()
            else
                enableDummy()
            end
        end
    end)
end

local previousSidecar = nil

local function evaluateScreenState()
    local screens = hs.screen.allScreens()
    local newState, hasSidecar = screenStateSnapshot(screens)
    local stateChanged = newState ~= currentState
    local unknownPresent = {}

    for _, s in ipairs(screens) do
        local name = s:name()

        if name ~= "PL3461WQ" and name ~= "" and name ~= "Virtual 4:3"
            and not (name or ""):find("Sidecar", 1, true)
            and not (name or ""):find("iPad", 1, true) then
            print("STATE: UNKNOWN_SCREEN:", name)
            local unknownName = tostring(name)
            unknownPresent[unknownName] = true
            if not unknownNotified[unknownName] then
                unknownNotified[unknownName] = true
                notify("Unknown screen", "Неизвестный экран: " .. unknownName, { priority = "high" })
            end
        end
    end

    for name in pairs(unknownNotified) do
        if not unknownPresent[name] then
            unknownNotified[name] = nil
        end
    end

    if newState ~= currentState then
        local previousState = currentState
        currentState = newState
        print("STATE:", newState)

        if previousState == nil then
            notify("HS loaded", "Состояние монитора: " .. newState, { priority = "high" })
        else
            local bothHeadless = previousState ~= "MONITOR_ON" and newState ~= "MONITOR_ON"
            notify("Monitor state", previousState .. " → " .. newState,
                { priority = bothHeadless and "low" or "high" })
        end
    end

    if newState == "MONITOR_ON" and dummyStarted then
        cancelDummyConfirmation()
        disableDummy()
    elseif newState ~= "MONITOR_ON" and not hasSidecar and not dummyStarted then
        armDummyConfirmation()
    else
        cancelDummyConfirmation()
    end

    -- Dock policy: auto-hide everywhere except during a live Sidecar session.
    if _G.DockAutomation and previousSidecar ~= nil
        and (stateChanged or hasSidecar ~= previousSidecar) then
        _G.DockAutomation.setAutoHide(not hasSidecar)
    end
    previousSidecar = hasSidecar

    if _G.IpadMode then
        _G.IpadMode.recompute()
    end
end

local screenDebounceTimer = nil

local function scheduleScreenEvaluation()
    if screenDebounceTimer then
        screenDebounceTimer:stop()
    end
    screenDebounceTimer = hs.timer.doAfter(2, function()
        screenDebounceTimer = nil
        evaluateScreenState()
    end)
end

local function checkNow()
    if screenDebounceTimer then
        screenDebounceTimer:stop()
        screenDebounceTimer = nil
    end
    evaluateScreenState()
end

local watcher = hs.screen.watcher.new(scheduleScreenEvaluation)

_G.MonitorAutomation = {
    -- Anchor long-lived objects globally: local-only references can be GC'd and silently die.
    watcher = watcher,
    pending = pending,
    getState = function()
        return currentState
    end,
    physicalMonitorPresent = physicalMonitorPresent,
    isPhysicalOn = function()
        return currentState == "MONITOR_ON"
    end,
    runMonitorOffAction = function()
        enableDummy()
        hs.alert.show("Monitor: off action started")
    end,
    runMonitorOnAction = function()
        disableDummy()
        hs.alert.show("Monitor: on action started")
    end,
    checkNow = checkNow,
}

watcher:start()
evaluateScreenState()

local claudeOk, claudeError = pcall(function()
    dofile(hs.configdir .. "/claude_continue.lua")
end)

if not claudeOk then
    print("ERROR: Claude automation failed to load:", claudeError)
    hs.alert.show("Claude automation error")
end

local chatSwitchOk, chatSwitchError = pcall(function()
    dofile(hs.configdir .. "/claude_chat_switch.lua")
end)

if not chatSwitchOk then
    print("ERROR: Claude chat switch failed to load:", chatSwitchError)
    hs.alert.show("Claude chat switch error")
end

local cmdKeysOk, cmdKeysError = pcall(function()
    package.path = package.path .. ";/Volumes/Work/Projects/llm-legs/hammerspoon/?.lua"
    require("claude_cmd_keys")
end)

if not cmdKeysOk then
    print("ERROR: Claude Cmd keys failed to load:", cmdKeysError)
    hs.alert.show("Claude Cmd keys error")
end

local gptVoiceOk, gptVoiceError = pcall(function()
    dofile(hs.configdir .. "/gpt_voice.lua")
end)

if not gptVoiceOk then
    print("ERROR: GPT Voice automation failed to load:", gptVoiceError)
    hs.alert.show("GPT Voice automation error")
end

local handoffOk, handoffError = pcall(function()
    dofile(hs.configdir .. "/handoff.lua")
end)

if not handoffOk then
    print("ERROR: Handoff guard failed to load:", handoffError)
    hs.alert.show("Handoff guard error")
end

local ipadTriggerOk, ipadTriggerError = pcall(function()
    dofile(hs.configdir .. "/ipad_trigger.lua")
end)

if not ipadTriggerOk then
    print("ERROR: iPad trigger failed to load:", ipadTriggerError)
    hs.alert.show("iPad trigger error")
end

local ipadModeOk, ipadModeError = pcall(function()
    dofile(hs.configdir .. "/ipad_mode.lua")
end)

if not ipadModeOk then
    print("ERROR: iPad mode failed to load:", ipadModeError)
    hs.alert.show("iPad mode error")
end

local menuOk, menuError = pcall(function()
    dofile(hs.configdir .. "/automation_menu.lua")
end)

if not menuOk then
    print("ERROR: Automation menu failed to load:", menuError)
    hs.alert.show("Automation menu error")
end

if _G.DockAutomation then
    local _, sidecarNow = screenStateSnapshot(hs.screen.allScreens())
    _G.DockAutomation.setAutoHide(not sidecarNow)
end
