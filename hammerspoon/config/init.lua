-- `open -a Hammerspoon` inherits the caller's env: a relaunch from a profile
-- shell (HOME=~/.gemini-profiles/*) silently poisons every $HOME-derived path
-- (limits cache, worker-pick) while the menu still looks alive. Relaunch clean
-- once; a fresh marker file means the relaunch didn't fix it — stop looping.
local envGuardOk, envGuardError = pcall(function()
    local realHome = hs.execute([[dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p']]):gsub("%s+$", "")
    if realHome == "" then return end
    local marker = realHome .. "/.hammerspoon-env-relaunch"
    if os.getenv("HOME") == realHome then
        os.remove(marker)
        return
    end
    local markerAttr = hs.fs.attributes(marker)
    if markerAttr and (os.time() - markerAttr.modification) < 120 then
        print("ERROR: HOME poisoned (" .. tostring(os.getenv("HOME")) .. ") and clean relaunch already failed; running degraded")
        hs.alert.show("Hammerspoon HOME poisoned — relaunch failed", 10)
        return
    end
    local markerFile = io.open(marker, "w")
    if not markerFile then
        print("ERROR: HOME poisoned (" .. tostring(os.getenv("HOME")) .. ") but marker " .. marker .. " is unwritable; running degraded to avoid a relaunch loop")
        hs.alert.show("Hammerspoon HOME poisoned — marker unwritable", 10)
        return
    end
    markerFile:close()
    print("WARNING: HOME poisoned (" .. tostring(os.getenv("HOME")) .. "); relaunching with clean env")
    local _, launchdOwns = hs.execute([[launchctl print "gui/$(id -u)/com.egor.hammerspoon" >/dev/null 2>&1]])
    if not launchdOwns then
        -- Standalone install only: under the launchd agent (KeepAlive) exiting
        -- is the whole relaunch, and a parallel `open -a` would race it.
        local shellHome = realHome:gsub('[\\"$`]', "\\%0")
        hs.execute('nohup sh -c \'sleep 3; /usr/bin/env -i HOME="' .. shellHome ..
            '" USER="$(id -un)" LOGNAME="$(id -un)" PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -a Hammerspoon\' >/dev/null 2>&1 &')
    end
    os.exit()
end)
if not envGuardOk then
    print("ERROR: HOME env guard failed:", envGuardError)
end

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
local jumpUserPidCommand = [[/usr/bin/pgrep -fl JumpConnect | /usr/bin/awk '$2 == "/Applications/Jump" && $3 == "Desktop" && $4 == "Connect.app/Contents/MacOS/JumpConnect" && $0 !~ /--service/ { print $1 }']]
local sonobusGroupUrl = "sonobus://aoo.sonobus.net:10998/?g=egor-mic"
local serviceLogDir = "/Library/Logs/Jump Desktop/"
local enforceSettingKey = "IpadAutomation.enforce"
local pending = {}
local nextPendingId = 0
local actionGeneration = 0
local appActionTasks = {}
local teardownGeneration = 0
local teardownTasks = {}
local teardownTimers = {}
local savedDefaultInputDevice = nil
local serviceLogOffsets = {}
local serviceLogInodes = {}
local serviceLogPartialLines = {}
local serviceLogWatcher = nil
local serviceLogPollingTimer = nil
local screenDebounceTimer = nil
local audioInputWatcher = nil
local audioInputMirrorTimer = nil
local sendInputDeviceCommand
local restoreSystemInputDevice

local function showAutomationMenu()
    if _G.AutomationMenu and _G.AutomationMenu.show then
        _G.AutomationMenu.show()
    end
end

local function refreshAutomationMenu()
    if _G.AutomationMenu and _G.AutomationMenu.refresh then
        _G.AutomationMenu.refresh()
    end
end

-- Master "Enforce iPad mode" gate: every watcher/timer that re-asserts system
-- state while the iPad is connected must check this. Off = freeze, never revert.
local function enforceEnabled()
    local ok, stored = pcall(hs.settings.get, enforceSettingKey)
    if not ok or stored == nil then
        return true
    end
    return stored == true
end

local function storeEnforce(value)
    local ok, err = pcall(hs.settings.set, enforceSettingKey, value == true)
    if not ok then
        print("WARNING: could not store iPad enforcement setting:", err)
    end
    return enforceEnabled()
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
            local expected = expectRunning and "✓ running" or "✓ stopped"
            local unexpected = expectRunning and "✗ not running" or "✗ still running"
            local virtualExpected = expectRunning and "✓ present" or "✗ still present"
            local virtualUnexpected = expectRunning and "✗ not present" or "✓ absent"
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
                virtualStatus = virtualRunning and "✓ present" or "✗ not present"
            else
                virtualStatus = virtualRunning and "✗ still present" or "✓ absent"
            end
            notify(title, "BetterDisplay: " .. (betterDisplayRunning and "✓ running" or "✗ not running")
                .. "\nJump Desktop Connect: ✗ check failed"
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

local function cancelPendingWork()
    actionGeneration = actionGeneration + 1
    for id, entry in pairs(pending) do
        if entry.timer then
            entry.timer:stop()
        end
        if entry.task and entry.task:isRunning() then
            entry.task:terminate()
        end
        pending[id] = nil
    end
    cancelAppActionTasks()
end

local function cancelTeardown()
    teardownGeneration = teardownGeneration + 1
    for timer in pairs(teardownTimers) do
        timer:stop()
    end
    teardownTimers = {}
    for task in pairs(teardownTasks) do
        if task:isRunning() then
            task:terminate()
        end
        teardownTasks[task] = nil
    end
end

local function runAppTasks(specs, expectRunning, title, delay)
    cancelAppActionTasks()
    local generation = actionGeneration
    local remaining = #specs

    if remaining == 0 then
        verifyApps(expectRunning, title, delay)
        return
    end

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

local function scheduleTeardown(generation, delay, callback)
    local timer
    timer = hs.timer.doAfter(delay, function()
        teardownTimers[timer] = nil
        if generation == teardownGeneration then
            callback()
        end
    end)
    teardownTimers[timer] = true
end

local function stopAppReliably(appName, generation, onDone)
    local gracePolls = 6
    local killPolls = 4
    local termSent = false

    local function isRunning()
        local ok, app = pcall(hs.application.get, appName)
        return ok and app ~= nil, app
    end

    local function finish()
        if generation == teardownGeneration then
            onDone()
        end
    end

    local function poll()
        if generation ~= teardownGeneration then
            return
        end
        local running, app = isRunning()
        if not running then
            finish()
            return
        end
        if not termSent and gracePolls > 0 then
            gracePolls = gracePolls - 1
            scheduleTeardown(generation, 0.5, poll)
            return
        end
        -- Real signals by pid: NSRunningApplication-style app:kill() is a
        -- polite terminate that a modal dialog (SonoBus quit confirm) ignores.
        local pid = app and app:pid()
        if not termSent then
            termSent = true
            if pid then
                hs.execute("/bin/kill -TERM " .. pid)
            end
        end
        if killPolls > 0 then
            killPolls = killPolls - 1
            scheduleTeardown(generation, 0.5, poll)
            return
        end
        if pid then
            hs.execute("/bin/kill -KILL " .. pid)
        end
        scheduleTeardown(generation, 0.5, function()
            if isRunning() then
                print("WARNING: could not stop application:", appName)
            end
            finish()
        end)
    end

    local task
    task = hs.task.new("/usr/bin/osascript", function()
        teardownTasks[task] = nil
    end, { "-e", 'quit app "' .. appName .. '"' })
    if task then
        teardownTasks[task] = true
    end
    if task and task:start() then
        scheduleTeardown(generation, 0, poll)
    else
        if task then
            teardownTasks[task] = nil
        end
        scheduleTeardown(generation, 0, poll)
    end
end

local function stopSonoBusReliably(generation, onDone)
    if generation ~= teardownGeneration then
        return
    end
    local ok, app = pcall(hs.application.get, "SonoBus")
    local disconnected = false
    if ok and app then
        local selectOk, selected = pcall(app.selectMenuItem, app, { "Connect", "Disconnect" })
        disconnected = selectOk and selected and true or false
    end
    if disconnected then
        scheduleTeardown(generation, 0.7, function()
            stopAppReliably("SonoBus", generation, onDone)
        end)
    else
        stopAppReliably("SonoBus", generation, onDone)
    end
end

local function jumpUserPids()
    local output, ok = hs.execute(jumpUserPidCommand)
    if not ok then
        return {}
    end
    local pids = {}
    for pid in tostring(output):gmatch("%d+") do
        pids[#pids + 1] = pid
    end
    return pids
end

local function ipadJunkPresent()
    return hs.application.get("SonoBus") ~= nil
        or #jumpUserPids() > 0
        or virtualDisplayPresent()
end

local function stopJumpUserReliably(generation, onDone)
    local gracePolls = 6
    local killPolls = 4
    local killSent = false

    local function poll()
        if generation ~= teardownGeneration then
            return
        end
        local pids = jumpUserPids()
        if #pids == 0 then
            onDone()
            return
        end
        if not killSent and gracePolls > 0 then
            gracePolls = gracePolls - 1
            scheduleTeardown(generation, 0.5, poll)
            return
        end
        if not killSent then
            killSent = true
            for _, pid in ipairs(pids) do
                hs.execute("/bin/kill -TERM " .. pid)
            end
        end
        if killPolls > 0 then
            killPolls = killPolls - 1
            scheduleTeardown(generation, 0.5, poll)
            return
        end
        for _, pid in ipairs(pids) do
            hs.execute("/bin/kill -KILL " .. pid)
        end
        scheduleTeardown(generation, 0.5, function()
            if #jumpUserPids() > 0 then
                print("WARNING: Jump Desktop Connect user agent is still running")
            end
            onDone()
        end)
    end

    local task
    task = hs.task.new("/usr/bin/osascript", function()
        teardownTasks[task] = nil
    end, { "-e", 'quit app "Jump Desktop Connect"' })
    if task then
        teardownTasks[task] = true
    end
    if task and task:start() then
        scheduleTeardown(generation, 0, poll)
    else
        if task then
            teardownTasks[task] = nil
        end
        scheduleTeardown(generation, 0, poll)
    end
end

local function enableDummy()
    cancelTeardown()
    cancelPendingWork()
    actionGeneration = actionGeneration + 1
    print("ACTION: ENABLE_DUMMY")
    runAppTasks({
        { path = "/usr/bin/open", args = { "-a", "BetterDisplay" } },
        -- -j -g: Jump Connect's status window pops on every plain launch; it is never used here.
        { path = "/usr/bin/open", args = { "-j", "-g", "-a", "Jump Desktop Connect" } },
    }, true, "iPad connected", 10)
    local generation = actionGeneration
    nextPendingId = nextPendingId + 1
    local pendingId = nextPendingId
    local entry = {}
    pending[pendingId] = entry
    entry.timer = hs.timer.doAfter(7, function()
        entry.timer = nil
        pending[pendingId] = nil
        if generation ~= actionGeneration then
            return
        end
        local specs = {}
        if hs.application.get("BetterDisplay") == nil then
            print("WARNING: iPad connect re-launching BetterDisplay")
            specs[#specs + 1] = { path = "/usr/bin/open", args = { "-a", "BetterDisplay" } }
        end
        if #jumpUserPids() == 0 then
            print("WARNING: iPad connect re-launching Jump Desktop Connect")
            specs[#specs + 1] = { path = "/usr/bin/open", args = { "-j", "-g", "-a", "Jump Desktop Connect" } }
        end
        if hs.application.get("SonoBus") == nil then
            print("WARNING: iPad connect re-launching SonoBus")
            specs[#specs + 1] = { path = "/usr/bin/open", args = { sonobusGroupUrl } }
        end
        if #specs > 0 then
            runAppTasks(specs, true, "iPad connected retry", 3)
        end
        local jump = hs.application.get("Jump Desktop Connect")
        if jump then
            jump:hide()
        end
    end)
    showAutomationMenu()
end

local function runTeardownStep(label, callback)
    local ok, err = pcall(callback)
    if not ok then
        print("WARNING: teardown step failed:", label, err)
    end
end

local function disableDummy(baseline)
    cancelTeardown()
    cancelPendingWork()
    actionGeneration = actionGeneration + 1
    print("ACTION: DISABLE_DUMMY")
    if screenDebounceTimer then
        screenDebounceTimer:stop()
        screenDebounceTimer = nil
    end
    runTeardownStep("restore input device", restoreSystemInputDevice)
    runTeardownStep("hide overlay", function()
        if _G.IpadOverlay and not (baseline and _G.IpadOverlay.hasStoredVisibility()) then
            _G.IpadOverlay.hide()
        end
    end)

    local remaining = 3
    local function stopped()
        remaining = remaining - 1
        if remaining == 0 then
            notify("iPad disconnected",
                "SonoBus: " .. (hs.application.get("SonoBus") and "✗ still running" or "✓ stopped")
                .. "\nBetterDisplay: " .. (hs.application.get("BetterDisplay") and "✗ still running" or "✓ stopped")
                .. "\nVirtual display: " .. (virtualDisplayPresent() and "✗ still present" or "✓ absent")
                .. "\nJump Desktop Connect: " .. (#jumpUserPids() == 0 and "✓ stopped" or "✗ still running")
                .. "\n" .. displayStateLine(),
                { priority = "high" })
        end
    end
    local generation = teardownGeneration
    runTeardownStep("stop SonoBus", function()
        stopSonoBusReliably(generation, stopped)
    end)
    runTeardownStep("stop BetterDisplay", function()
        stopAppReliably("BetterDisplay", generation, stopped)
    end)
    runTeardownStep("stop Jump Desktop Connect", function()
        stopJumpUserReliably(generation, stopped)
    end)
    scheduleTeardown(generation, 7, function()
        local stragglerPids = {}
        for _, appName in ipairs({ "SonoBus", "BetterDisplay" }) do
            local app = hs.application.get(appName)
            local pid = app and app:pid()
            if pid then
                stragglerPids[#stragglerPids + 1] = pid
                hs.execute("/bin/kill -TERM " .. pid)
            end
        end
        for _, pid in ipairs(jumpUserPids()) do
            stragglerPids[#stragglerPids + 1] = pid
            hs.execute("/bin/kill -TERM " .. pid)
        end
        scheduleTeardown(generation, 1, function()
            for _, pid in ipairs(stragglerPids) do
                hs.execute("/bin/kill -KILL " .. pid .. " 2>/dev/null")
            end
        end)
    end)
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

local function listServiceLogs()
    local files = {}
    local ok, iterator, directory = pcall(hs.fs.dir, serviceLogDir)
    if ok and iterator then
        for name in iterator, directory do
            if name:match("^Service_.*%.log$") then
                files[#files + 1] = name
            end
        end
    end
    if #files == 0 then
        files[1] = "Service_" .. os.date("%Y_%m_%d") .. ".log"
        files[2] = "Service_" .. os.date("%Y_%m_%d", os.time() - 86400) .. ".log"
    end
    table.sort(files)
    return files
end

local function wakeOnJumpAttempt(line)
    if line:find("[rtc_server] Launching new proxy server", 1, true)
        and _G.IpadMode and _G.IpadMode.wakeOnAttempt then
        _G.IpadMode.wakeOnAttempt()
    end
end

local function readServiceLogAppended(fileName)
    local path = serviceLogDir .. fileName
    local size = hs.fs.attributes(path, "size")
    local inode = hs.fs.attributes(path, "ino")
    if not size then
        return
    end
    local offset = serviceLogOffsets[fileName] or 0
    if size < offset or (serviceLogInodes[fileName] and inode ~= serviceLogInodes[fileName]) then
        offset = 0
        serviceLogPartialLines[fileName] = nil
    end
    serviceLogInodes[fileName] = inode
    if size == offset then
        return
    end
    local file = io.open(path, "rb")
    if not file then
        return
    end
    file:seek("set", offset)
    local appended = file:read("*a") or ""
    file:close()
    serviceLogOffsets[fileName] = offset + #appended

    local content = (serviceLogPartialLines[fileName] or "") .. appended
    local startAt = 1
    while true do
        local newlineAt = content:find("\n", startAt, true)
        if not newlineAt then
            serviceLogPartialLines[fileName] = content:sub(startAt)
            break
        end
        wakeOnJumpAttempt(content:sub(startAt, newlineAt - 1):gsub("\r$", ""))
        startAt = newlineAt + 1
    end
end

local function scanServiceLogs()
    for _, fileName in ipairs(listServiceLogs()) do
        readServiceLogAppended(fileName)
    end
end

local function baselineServiceLogs()
    for _, fileName in ipairs(listServiceLogs()) do
        local path = serviceLogDir .. fileName
        local size = hs.fs.attributes(path, "size")
        if size then
            serviceLogOffsets[fileName] = size
            serviceLogInodes[fileName] = hs.fs.attributes(path, "ino")
        end
    end
end

local function startJumpAttemptWatcher()
    baselineServiceLogs()
    local ok, watcher = pcall(hs.pathwatcher.new, serviceLogDir, scanServiceLogs)
    if ok and watcher then
        local startOk, startResult = pcall(function()
            return watcher:start()
        end)
        if startOk and startResult ~= false then
            serviceLogWatcher = watcher
        end
    end
    serviceLogPollingTimer = hs.timer.doEvery(4, scanServiceLogs)
    if _G.IpadAutomation then
        _G.IpadAutomation.serviceLogWatcher = serviceLogWatcher
        _G.IpadAutomation.serviceLogPollingTimer = serviceLogPollingTimer
    end
end

local function switchSystemInputDevice(deviceName)
    if not savedDefaultInputDevice then
        local ok, current = pcall(function()
            return hs.audiodevice.defaultInputDevice()
        end)
        if ok then
            local nameOk, currentName = pcall(function()
                return current and current:name()
            end)
            if nameOk and currentName and not currentName:find("BlackHole", 1, true) then
                savedDefaultInputDevice = current
            end
        else
            print("WARNING: could not save the default input device:", current)
        end
    end

    local ok, target = pcall(function()
        return hs.audiodevice.findInputByName(deviceName)
    end)
    if not ok or not target then
        print("WARNING: audio input device not found:", deviceName)
        return
    end

    local setOk, result = pcall(function()
        return target:setDefaultInputDevice()
    end)
    if not setOk or result == false then
        print("WARNING: could not set the default input device:", deviceName)
    end
end

restoreSystemInputDevice = function()
    local ok, current = pcall(function()
        return hs.audiodevice.defaultInputDevice()
    end)
    if not ok then
        savedDefaultInputDevice = nil
        print("WARNING: could not inspect the current default input device")
        return
    end

    local currentName = current and current:name() or nil
    if not currentName or not currentName:find("BlackHole", 1, true) then
        savedDefaultInputDevice = nil
        return
    end

    local candidates = {}
    if savedDefaultInputDevice then
        candidates[#candidates + 1] = savedDefaultInputDevice
    end
    local allInputsOk, allInputs = pcall(function()
        return hs.audiodevice.allInputDevices()
    end)
    if allInputsOk then
        for _, device in ipairs(allInputs) do
            local nameOk, name = pcall(function()
                return device:name()
            end)
            if nameOk and name and not name:find("BlackHole", 1, true) then
                candidates[#candidates + 1] = device
            end
        end
    end

    local restored = false
    for _, device in ipairs(candidates) do
        local setOk, result = pcall(function()
            return device:setDefaultInputDevice()
        end)
        if setOk and result ~= false then
            restored = true
            break
        end
    end
    if not restored then
        print("WARNING: previous default input device is unavailable; leaving the system default untouched")
    end
    savedDefaultInputDevice = nil
    if sendInputDeviceCommand then
        sendInputDeviceCommand("default")
    end
end

local inputDeviceRetryDelays = { 2, 5, 10 }
local inputDeviceRetryTimer = nil
local inputDeviceGeneration = 0

sendInputDeviceCommand = function(device)
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

local function scheduleAudioInputMirror()
    if audioInputMirrorTimer then
        audioInputMirrorTimer:stop()
    end
    audioInputMirrorTimer = hs.timer.doAfter(0.75, function()
        audioInputMirrorTimer = nil
        local ok, device = pcall(function()
            return hs.audiodevice.defaultInputDevice()
        end)
        if not ok or not device then
            return
        end
        local nameOk, name = pcall(function()
            return device:name()
        end)
        if not nameOk or not name then
            return
        end
        if enforceEnabled()
            and _G.IpadMode and _G.IpadMode.isOn()
            and not name:find("BlackHole", 1, true) then
            local targetOk, target = pcall(function()
                return hs.audiodevice.findInputByName("BlackHole 2ch")
            end)
            if targetOk and target then
                print("audio mirror: re-asserting BlackHole (stolen by " .. name .. ")")
                local setOk, result = pcall(function()
                    return target:setDefaultInputDevice()
                end)
                if not setOk or result == false then
                    print("WARNING: audio mirror could not re-assert BlackHole")
                end
                return
            end
        end
        -- A reboot mid-iPad-session skips the disconnect handler, leaving
        -- BlackHole as the system default with no iPad behind it. Connect
        -- always stores enforce=true, so the gate stays open for that path.
        if enforceEnabled()
            and name:find("BlackHole", 1, true)
            and not (_G.IpadMode and _G.IpadMode.isOn()) then
            print("audio mirror: no iPad, restoring the default input away from BlackHole")
            restoreSystemInputDevice()
            return
        end
        if sendInputDeviceCommand then
            sendInputDeviceCommand(name)
        end
    end)
end

local function audioInputWatcherCallback(event)
    if event == "dIn " then
        scheduleAudioInputMirror()
    end
end

local function startAudioInputMirror()
    local watcher = hs.audiodevice.watcher
    pcall(watcher.stop)
    watcher.setCallback(audioInputWatcherCallback)
    watcher.start()
    audioInputWatcher = watcher
    if _G.IpadAutomation then
        _G.IpadAutomation.audioInputWatcher = watcher
    end
    scheduleAudioInputMirror()
end

-- BlackHole stores its volume persistently; a stray 39% once attenuated the
-- whole mic chain by ~40dB (write x read) and silenced dictation.
local function assertBlackHoleVolume()
    local outOk, out = pcall(hs.audiodevice.findOutputByName, "BlackHole 2ch")
    if outOk and out then
        pcall(function() out:setVolume(100) end)
    end
    local inOk, input = pcall(hs.audiodevice.findInputByName, "BlackHole 2ch")
    if inOk and input then
        pcall(function() input:setInputVolume(100) end)
    end
end

local function enforceAudio()
    assertBlackHoleVolume()
    switchSystemInputDevice("BlackHole 2ch")
end

local function setEnforce(value)
    local active = storeEnforce(value)
    if _G.DisplayMirror then
        _G.DisplayMirror.reconcile("enforcement changed")
    end
    if active and _G.IpadMode and _G.IpadMode.isOn() then
        enforceAudio()
    end
    refreshAutomationMenu()
    return active
end

local rejoinSonoBusTimer = nil

-- Both SonoBus ends go stale after the iPad app dies mid-session; rejoining
-- the group on the Mac side is half of the recovery (the iPad app restart is
-- the other half).
local function rejoinSonoBus()
    local app = hs.application.get("SonoBus")
    if app then
        pcall(app.selectMenuItem, app, { "Connect", "Disconnect" })
    end
    if rejoinSonoBusTimer then
        rejoinSonoBusTimer:stop()
    end
    rejoinSonoBusTimer = hs.timer.doAfter(app and 2 or 0, function()
        rejoinSonoBusTimer = nil
        hs.execute([[/usr/bin/open "]] .. sonobusGroupUrl .. [["]])
    end)
end

local function ipadConnected(baseline)
    if not baseline then
        storeEnforce(true)
        refreshAutomationMenu()
    end
    enableDummy()
    if _G.DisplayMirror then
        _G.DisplayMirror.reconcile("iPad connected")
    end
    if baseline then
        -- A baseline replay must not bounce a live SonoBus connection; joining
        -- the current group again is a no-op.
        hs.execute([[/usr/bin/open "]] .. sonobusGroupUrl .. [["]])
    else
        rejoinSonoBus()
    end
    -- On a baseline replay the overlay has already restored the visibility the
    -- user last chose (ipad_overlay.lua); showing here would switch an overlay
    -- they hid back on every hs.reload.
    if _G.IpadOverlay and not (baseline and _G.IpadOverlay.hasStoredVisibility()) then
        _G.IpadOverlay.show()
    end
    if enforceEnabled() then
        enforceAudio()
    end
end

local function ipadDisconnected(baseline)
    if _G.DisplayMirror and _G.DisplayMirror.prepareDisconnect then
        -- BetterDisplay must finish unmirroring before the disconnect teardown can quit it.
        _G.DisplayMirror.prepareDisconnect(function()
            if not (_G.IpadMode and _G.IpadMode.isOn()) then
                disableDummy(baseline)
            end
        end)
    else
        disableDummy(baseline)
    end
end

local function evaluateIpadPresence()
    if _G.IpadMode and _G.IpadAutomation and _G.IpadAutomation.getSidecarPresent then
        _G.IpadMode.recompute("Sidecar display signal", _G.IpadAutomation.getSidecarPresent())
    end
end

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
    enforceEnabled = enforceEnabled,
    setEnforce = setEnforce,
    ipadConnected = ipadConnected,
    ipadDisconnected = ipadDisconnected,
    ipadJunkPresent = ipadJunkPresent,
    getSidecarPresent = function()
        return sidecarPresent(hs.screen.allScreens())
    end,
}

watcher:start()

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

local ipadModeOk, ipadModeError = pcall(function()
    dofile(hs.configdir .. "/ipad_mode.lua")
end)

if not ipadModeOk then
    print("ERROR: iPad mode failed to load:", ipadModeError)
    hs.alert.show("iPad mode error")
end

local displayMirrorOk, displayMirrorError = pcall(function()
    dofile(hs.configdir .. "/display_mirror.lua")
end)

if not displayMirrorOk then
    print("ERROR: Display mirror failed to load:", displayMirrorError)
    hs.alert.show("Display mirror error")
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

if ipadModeOk then
    local reconcileOk, reconcileError = pcall(_G.IpadMode.reconcileBaseline)
    if not reconcileOk then
        print("ERROR: iPad baseline reconciliation failed:", reconcileError)
        hs.alert.show("iPad baseline reconciliation error")
    else
        startJumpAttemptWatcher()
        startAudioInputMirror()
    end
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

-- require, not dofile: compact-auto.sh reaches the module through require, and a
-- second copy would keep its pending operation in its own private state
local compactResumeOk, compactResumeError = pcall(function()
    local compact = require("claude_compact")
    -- global on purpose: an unreferenced hs.timer can be GC'd before it fires,
    -- and the init chunk's locals die when the chunk returns
    CompactResumeTimer = hs.timer.doAfter(5, function()
        local ok, err = pcall(compact.resumePending)
        if not ok then
            print("ERROR: Claude compact resume failed:", err)
            hs.alert.show("Claude compact resume error")
        end
    end)
end)

if not compactResumeOk then
    print("ERROR: Claude compact resume failed to load:", compactResumeError)
    hs.alert.show("Claude compact resume error")
end
