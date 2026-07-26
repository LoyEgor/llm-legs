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

local jumpUserProcessCommand = [[/usr/bin/pgrep -fl JumpConnect | /usr/bin/awk '$2 == "/Applications/Jump" && $3 == "Desktop" && $4 == "Connect.app/Contents/MacOS/JumpConnect" && $0 !~ /--service/ { found=1 } END { exit(found ? 0 : 1) }']]
local pending = {}
local nextPendingId = 0
local actionGeneration = 0
local appActionTasks = {}

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

local function displayStateLine()
    local screenNames = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        screenNames[#screenNames + 1] = screen:name() or ""
    end
    return "Screens: " .. table.concat(screenNames, ", ")
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
            notify(title, table.concat(lines, "\n") .. "\n" .. displayStateLine(), { priority = "high" })
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
                .. "\nVirtual display: " .. virtualStatus
                .. "\n" .. displayStateLine(),
                { priority = "high" })
        end
    end)
end

local function cancelAppActionTasks()
    local tasks = {}
    for task in pairs(appActionTasks) do
        tasks[#tasks + 1] = task
    end
    appActionTasks = {}
    for _, task in ipairs(tasks) do
        if task:isRunning() then
            task:terminate()
        end
    end
end

local function runAppTasks(specs, expectRunning, title, delay)
    cancelAppActionTasks()
    local generation = actionGeneration
    local remaining = #specs

    local function finishTask(task, exitCode)
        if task then
            appActionTasks[task] = nil
        end
        if generation ~= actionGeneration then
            return
        end
        if exitCode ~= 0 then
            print("WARNING: iPad app action failed:", title, exitCode)
        end
        remaining = remaining - 1
        if remaining == 0 then
            verifyApps(expectRunning, title, delay)
        end
    end

    for _, spec in ipairs(specs) do
        local task
        task = hs.task.new(spec.path, function(exitCode)
            finishTask(task, exitCode)
        end, spec.args)
        if task then
            appActionTasks[task] = true
        end
        if not task or not task:start() then
            finishTask(task, -1)
        end
    end
end

local function enableDummy()
    actionGeneration = actionGeneration + 1
    print("ACTION: ENABLE_DUMMY")
    if _G.HandoffGuard and _G.HandoffGuard.forceEnable then
        _G.HandoffGuard.forceEnable()
    end
    runAppTasks({
        { path = "/usr/bin/open", args = { "-a", "BetterDisplay" } },
        { path = "/usr/bin/open", args = { "-a", "Jump Desktop Connect" } },
    }, true, "iPad connected", 10)
    showAutomationMenu()
end

local function disableDummy()
    actionGeneration = actionGeneration + 1
    print("ACTION: DISABLE_DUMMY")
    runAppTasks({
        { path = "/usr/bin/osascript", args = { "-e", 'quit app "BetterDisplay"' } },
        { path = "/usr/bin/osascript", args = { "-e", 'quit app "Jump Desktop Connect"' } },
    }, false, "iPad disconnected", 8)
end

local function sidecarPresent(screens)
    for _, screen in ipairs(screens) do
        local name = screen:name() or ""
        if name:find("Sidecar", 1, true) or name:find("iPad", 1, true) then
            return true
        end
    end
    return false
end

local inputDeviceRetryDelays = { 2, 5, 10 }
local inputDeviceRetryTimer = nil
local inputDeviceGeneration = 0

local function switchInputDevice(device)
    inputDeviceGeneration = inputDeviceGeneration + 1
    local generation = inputDeviceGeneration
    if inputDeviceRetryTimer then
        inputDeviceRetryTimer:stop()
        inputDeviceRetryTimer = nil
    end

    local attempt
    attempt = function(attemptNumber)
        if generation ~= inputDeviceGeneration then
            return
        end

        local function scheduleRetry()
            if generation ~= inputDeviceGeneration or inputDeviceRetryTimer then
                return
            end
            local delay = inputDeviceRetryDelays[attemptNumber]
            if not delay then
                print("WARNING: transcription input-device retries exhausted:", device)
                return
            end
            inputDeviceRetryTimer = hs.timer.doAfter(delay, function()
                inputDeviceRetryTimer = nil
                attempt(attemptNumber + 1)
            end)
        end

        if not (_G.GptVoice and _G.GptVoice.sendCommand) then
            print("WARNING: transcription input-device command unavailable")
            scheduleRetry()
            return
        end

        local started = _G.GptVoice.sendCommand("input-device " .. device, function(reply)
            if generation ~= inputDeviceGeneration then
                return
            end
            reply = tostring(reply)
            if reply == "offline" then
                print("WARNING: transcription input-device connection failed")
                scheduleRetry()
            elseif reply:match("^err%s") then
                print("WARNING: transcription input-device failed:", reply)
            elseif not reply:match("^ok") then
                print("WARNING: transcription input-device unexpected reply:", reply)
            end
        end)
        if not started then
            scheduleRetry()
        end
    end

    attempt(1)
end

local function ipadConnected()
    enableDummy()
    hs.execute([[open "sonobus://aoo.sonobus.net:10998/?g=egor-mic"]])
    if _G.IpadOverlay then
        _G.IpadOverlay.show()
    end
    switchInputDevice("BlackHole 2ch")
end

local function ipadDisconnected()
    switchInputDevice("default")
    local sonoBus = hs.application.get("SonoBus")
    if sonoBus then
        sonoBus:kill()
    end
    disableDummy()
    if _G.IpadOverlay then
        _G.IpadOverlay.hide()
    end
end

local function evaluateIpadPresence()
    if _G.IpadMode then
        _G.IpadMode.recompute("Sidecar display signal", sidecarPresent(hs.screen.allScreens()))
    end
end

local screenDebounceTimer = nil

local function scheduleScreenEvaluation()
    if screenDebounceTimer then
        screenDebounceTimer:stop()
    end
    screenDebounceTimer = hs.timer.doAfter(2, function()
        screenDebounceTimer = nil
        evaluateIpadPresence()
    end)
end

local watcher = hs.screen.watcher.new(scheduleScreenEvaluation)

_G.IpadAutomation = {
    screenWatcher = watcher,
    pending = pending,
    ipadConnected = ipadConnected,
    ipadDisconnected = ipadDisconnected,
}

watcher:start()
evaluateIpadPresence()

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

local sidecarConnectOk, sidecarConnectError = pcall(function()
    dofile(hs.configdir .. "/sidecar_connect.lua")
end)

if not sidecarConnectOk then
    print("ERROR: Sidecar connect failed to load:", sidecarConnectError)
    hs.alert.show("Sidecar connect error")
end

local ipadModeOk, ipadModeError = pcall(function()
    dofile(hs.configdir .. "/ipad_mode.lua")
end)

if not ipadModeOk then
    print("ERROR: iPad mode failed to load:", ipadModeError)
    hs.alert.show("iPad mode error")
end

local sidecarPresenceOk, sidecarPresenceError = pcall(function()
    dofile(hs.configdir .. "/sidecar_presence.lua")
end)

if not sidecarPresenceOk then
    print("ERROR: Sidecar presence logger failed to load:", sidecarPresenceError)
    hs.alert.show("Sidecar presence error")
end

local sendActionsOk, sendActionsError = pcall(function()
    dofile(hs.configdir .. "/send_actions.lua")
end)

if not sendActionsOk then
    print("ERROR: Send actions failed to load:", sendActionsError)
    hs.alert.show("Send actions error")
end

local ipadOverlayOk, ipadOverlayError = pcall(function()
    dofile(hs.configdir .. "/ipad_overlay.lua")
end)

if not ipadOverlayOk then
    print("ERROR: iPad overlay failed to load:", ipadOverlayError)
    hs.alert.show("iPad overlay error")
end

local menuOk, menuError = pcall(function()
    dofile(hs.configdir .. "/automation_menu.lua")
end)

if not menuOk then
    print("ERROR: Automation menu failed to load:", menuError)
    hs.alert.show("Automation menu error")
end

local tokenUpkeepOk, tokenUpkeepError = pcall(function()
    dofile(hs.configdir .. "/token_upkeep.lua")
end)

if not tokenUpkeepOk then
    print("ERROR: Token upkeep failed to load:", tokenUpkeepError)
    hs.alert.show("Token upkeep error")
end

local spotlightLayoutOk, spotlightLayoutError = pcall(function()
    dofile(hs.configdir .. "/spotlight_layout.lua")
end)

if not spotlightLayoutOk then
    print("ERROR: Spotlight layout failed to load:", spotlightLayoutError)
    hs.alert.show("Spotlight layout error")
end
