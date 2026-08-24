local envGuardOk, envGuardError = pcall(function()
    dofile(hs.configdir .. "/env_guard.lua")
end)
if not envGuardOk then
    print("ERROR: HOME env guard failed:", envGuardError)
end

local consolePrint = print

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

-- hs.ipc's printReplacement (HS 1.1.1, Hammerspoon issue #3872, fix unmerged)
-- recurses to a stack overflow when an `hs` client's reply port dies mid-eval:
-- its reentrancy guard reports via log.w, which itself prints, and a send
-- failure leaves the guard counter stuck so every later print loops forever.
-- Same fan-out, but reentrancy is dropped silently and the guard always exits.
if ipcOk then
    local ipc = require("hs.ipc")
    if ipc.__registeredCLIInstances and ipc.print_enter and ipc.print_exit and ipc.print_inside then
        print = function(...)
            consolePrint(...)
            -- format before print_enter: a throwing __tostring must not strand the guard
            local parts = table.pack(...)
            local line = (parts.n > 0) and tostring(parts[1]) or ""
            for i = 2, parts.n do
                line = line .. "\t" .. tostring(parts[i])
            end
            for id, v in pairs(ipc.__registeredCLIInstances) do
                local cli = v._cli
                if cli and cli.console and cli.remote and not cli.quietMode
                    and not ipc.print_inside(id) then
                    ipc.print_enter(id)
                    -- the closure keeps every evaluation (incl. the sendMessage
                    -- index on a torn-down remote) inside pcall, so exit always runs
                    pcall(function() cli.remote:sendMessage(line .. "\n", 3) end)
                    ipc.print_exit(id)
                end
            end
        end
    else
        consolePrint("WARN: hs.ipc internals changed; print shim NOT applied, stock printReplacement (issue #3872) is live")
    end
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
local serviceLogDir = "/Library/Logs/Jump Desktop/"
local enforceSettingKey = "IpadAutomation.enforce"
local pending = {}
local nextPendingId = 0
local actionGeneration = 0
local appActionTasks = {}
local teardownGeneration = 0
local teardownTasks = {}
local teardownTimers = {}
local serviceLogOffsets = {}
local serviceLogInodes = {}
local serviceLogPartialLines = {}
local serviceLogWatcher = nil
local serviceLogPollingTimer = nil
local screenDebounceTimer = nil
local focusRestoreTimer = nil
local audioInputWatcher = nil
local audioInputMirrorTimer = nil
local sendInputDeviceCommand
local ipadMicRefreshScript = "/Volumes/Work/Projects/transcriptions-gpt/ipad-mic/refresh.sh"
local ipadMicRefreshSettingKey = "IpadAutomation.micRefreshAt"
local ipadMicRefreshInterval = 30 * 60
local ipadMicRefreshTask = nil

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

-- Master "Enforce iPad mode" gate: display mirroring is the only thing left
-- that re-asserts state while the iPad is connected. Off = freeze, never revert.
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

-- Only what came out differently than the action intended: a connect or
-- disconnect that fully worked notifies nothing.
local function mismatchLines(expectRunning, betterDisplayRunning, jumpRunning, virtualRunning)
    local wrong = expectRunning and "✗ not running" or "✗ still running"
    local lines = {}
    if betterDisplayRunning ~= expectRunning then
        lines[#lines + 1] = "BetterDisplay: " .. wrong
    end
    if jumpRunning ~= nil and jumpRunning ~= expectRunning then
        lines[#lines + 1] = "Jump Desktop Connect: " .. wrong
    end
    if virtualRunning ~= expectRunning then
        lines[#lines + 1] = "Virtual display: "
            .. (expectRunning and "✗ not present" or "✗ still present")
    end
    return lines
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

            local lines = mismatchLines(expectRunning, betterDisplayRunning,
                exitCode == 0, virtualDisplayPresent())
            if #lines > 0 then
                notify(title, table.concat(lines, "\n") .. "\n" .. displayStateLine(),
                    { priority = "high" })
            end
        end, { "-c", jumpUserProcessCommand })
        if not entry.task or not entry.task:start() then
            pending[pendingId] = nil
            if generation ~= actionGeneration then
                return
            end

            local lines = mismatchLines(expectRunning, betterDisplayRunning, nil,
                virtualDisplayPresent())
            lines[#lines + 1] = "Jump Desktop Connect: ✗ check failed"
            notify(title, table.concat(lines, "\n") .. "\n" .. displayStateLine(),
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
    if focusRestoreTimer then
        focusRestoreTimer:stop()
        focusRestoreTimer = nil
    end
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

local function runAppTasks(specs, expectRunning, title, delay, quiet)
    cancelAppActionTasks()
    local generation = actionGeneration
    local remaining = #specs

    if remaining == 0 then
        if not quiet then
            verifyApps(expectRunning, title, delay)
        end
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
        if remaining == 0 and not quiet then
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
        -- polite terminate that a modal quit-confirmation dialog ignores.
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
    return #jumpUserPids() > 0
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

local function enableDummy(quiet)
    cancelTeardown()
    cancelPendingWork()
    actionGeneration = actionGeneration + 1
    print("ACTION: ENABLE_DUMMY")
    local frontAtStart = hs.window.frontmostWindow()
    runAppTasks({
        { path = "/usr/bin/open", args = { "-g", "-a", "BetterDisplay" } },
        -- -j -g: Jump Connect's status window pops on every plain launch; it is never used here.
        { path = "/usr/bin/open", args = { "-j", "-g", "-a", "Jump Desktop Connect" } },
    }, true, "iPad connect incomplete", 10, quiet)
    local generation = actionGeneration

    local function tidyConnectWindows()
        local jump = hs.application.get("Jump Desktop Connect")
        local better = hs.application.get("BetterDisplay")
        local function ownedBy(window)
            local app = window and window:application()
            local pid = app and app:pid()
            return pid ~= nil
                and ((jump ~= nil and pid == jump:pid())
                    or (better ~= nil and pid == better:pid()))
        end
        local front = hs.window.frontmostWindow()
        local focusStolen = ownedBy(front)
        -- The user may have switched windows since enableDummy; track the
        -- freshest window that is theirs, not ours, as the restore target.
        if front and not focusStolen then
            frontAtStart = front
        end
        if jump then
            -- Close the standard windows (matches the X button; Jump keeps
            -- serving), then hide as a fallback for any non-standard one; the
            -- focus restore below compensates if Jump held focus.
            for _, window in ipairs(jump:allWindows() or {}) do
                if window:isStandard() then
                    pcall(window.close, window)
                end
            end
            jump:hide()
        end
        -- ownedBy(frontAtStart): restoring a Jump window would re-front
        -- what was just hidden.
        if focusStolen and frontAtStart and not ownedBy(frontAtStart) then
            if focusRestoreTimer then
                focusRestoreTimer:stop()
            end
            focusRestoreTimer = hs.timer.doAfter(0.4, function()
                focusRestoreTimer = nil
                pcall(frontAtStart.focus, frontAtStart)
            end)
        end
    end
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
            specs[#specs + 1] = { path = "/usr/bin/open", args = { "-g", "-a", "BetterDisplay" } }
        end
        if #jumpUserPids() == 0 then
            print("WARNING: iPad connect re-launching Jump Desktop Connect")
            specs[#specs + 1] = { path = "/usr/bin/open", args = { "-j", "-g", "-a", "Jump Desktop Connect" } }
        end
        tidyConnectWindows()
        if #specs > 0 then
            runAppTasks(specs, true, "iPad connect retry incomplete", 3, quiet)
            -- Apps relaunched by the retry are not up yet on this tick; sweep
            -- their windows again once they are.
            nextPendingId = nextPendingId + 1
            local retryPendingId = nextPendingId
            local retryEntry = {}
            pending[retryPendingId] = retryEntry
            retryEntry.timer = hs.timer.doAfter(6, function()
                retryEntry.timer = nil
                pending[retryPendingId] = nil
                if generation == actionGeneration then
                    tidyConnectWindows()
                end
            end)
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
    runTeardownStep("hide overlay", function()
        if _G.IpadOverlay and not (baseline and _G.IpadOverlay.hasStoredVisibility()) then
            _G.IpadOverlay.hide()
        end
    end)

    local remaining = 2
    local function stopped()
        remaining = remaining - 1
        if remaining == 0 then
            local lines = mismatchLines(false, hs.application.get("BetterDisplay") ~= nil,
                #jumpUserPids() > 0, virtualDisplayPresent())
            if #lines > 0 then
                notify("iPad teardown incomplete",
                    table.concat(lines, "\n") .. "\n" .. displayStateLine(),
                    { priority = "high" })
            end
        end
    end
    local generation = teardownGeneration
    runTeardownStep("stop BetterDisplay", function()
        stopAppReliably("BetterDisplay", generation, stopped)
    end)
    runTeardownStep("stop Jump Desktop Connect", function()
        stopJumpUserReliably(generation, stopped)
    end)
    scheduleTeardown(generation, 7, function()
        local stragglerPids = {}
        for _, appName in ipairs({ "BetterDisplay" }) do
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

local inputDeviceRetryDelays = { 2, 5, 10 }
local inputDeviceRetryTimer = nil
local inputDeviceGeneration = 0

sendInputDeviceCommand = function(command)
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
                print("WARNING: transcription input-device retries exhausted:", command)
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

        local started = _G.GptVoice.sendCommand(command, function(reply)
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

-- input-device-mirror, not input-device: the daemon follows the system input
-- without recording an explicit choice, which would outrank its iPad takeover.
-- Plain "default" is no substitute - PortAudio freezes its default at init, so
-- only the name reaches a device that appeared later.
local function scheduleAudioInputMirror()
    if audioInputMirrorTimer then
        audioInputMirrorTimer:stop()
    end
    audioInputMirrorTimer = hs.timer.doAfter(0.75, function()
        audioInputMirrorTimer = nil
        local nameOk, name = pcall(function()
            local device = hs.audiodevice.defaultInputDevice()
            return device and device:name()
        end)
        if nameOk and name and name ~= "" and sendInputDeviceCommand then
            sendInputDeviceCommand("input-device-mirror " .. name)
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

local function setEnforce(value)
    local active = storeEnforce(value)
    if _G.DisplayMirror then
        _G.DisplayMirror.reconcile("enforcement changed")
    end
    refreshAutomationMenu()
    return active
end

local function ipadConnected(baseline)
    pcall(function() if _G.bt and _G.bt.setProfile then _G.bt.setProfile("ipad") end end)
    if not baseline then
        storeEnforce(true)
        refreshAutomationMenu()
    end
    enableDummy(baseline)
    if _G.DisplayMirror then
        _G.DisplayMirror.reconcile("iPad connected")
    end
    -- On a baseline replay the overlay has already restored the visibility the
    -- user last chose (ipad_overlay.lua); showing here would switch an overlay
    -- they hid back on every hs.reload.
    if _G.IpadOverlay and not (baseline and _G.IpadOverlay.hasStoredVisibility()) then
        _G.IpadOverlay.show()
    end
    -- The iPad mic reaches the daemon over the network, not through CoreAudio:
    -- clearing any stale explicit input lets the daemon's own takeover pick the
    -- iPad up as soon as its app streams. Not on a baseline replay, which runs
    -- on every hs.reload and would throw away a pin just set by hand.
    -- The mirror right after is what names the input the daemon falls back to
    -- while the iPad app is closed: "default" alone leaves it on the one
    -- PortAudio froze at init, and a connect that changes no audio device
    -- produces no CoreAudio event to trigger the mirror on its own.
    if sendInputDeviceCommand and not baseline then
        sendInputDeviceCommand("input-device default")
        scheduleAudioInputMirror()
    end
end

local function ipadDisconnected(baseline)
    pcall(function() if _G.bt and _G.bt.setProfile then _G.bt.setProfile("desktop") end end)
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

-- The app's free signing dies after 7 days and reinstalling needs the iPad
-- unlocked on the same Wi-Fi, which a connect from it guarantees; refresh.sh
-- itself decides whether the build is old enough to be worth rebuilding.
local function kickIpadMicRefresh()
    if ipadMicRefreshTask and ipadMicRefreshTask:isRunning() then
        return
    end
    local now = os.time()
    local ok, lastRun = pcall(hs.settings.get, ipadMicRefreshSettingKey)
    if ok and tonumber(lastRun) and now - tonumber(lastRun) < ipadMicRefreshInterval then
        return
    end
    -- Checked here, not at registration: the script lives on an external
    -- volume that may not be mounted when Hammerspoon loads.
    if not hs.fs.attributes(ipadMicRefreshScript) then
        return
    end
    local logDir = os.getenv("HOME") .. "/.transcriptions-gpt"
    local logPath = logDir .. "/ipad-mic-refresh.log"
    -- Hammerspoon inherits launchd's PATH, which has no Homebrew; the build
    -- shells out to xcodegen there, like the refresh job's own plist does.
    local command = "mkdir -p '" .. logDir .. "' && "
        .. "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH exec '"
        .. ipadMicRefreshScript .. "' >>'" .. logPath .. "' 2>&1"
    ipadMicRefreshTask = hs.task.new("/bin/sh", nil, { "-c", command })
    if not ipadMicRefreshTask or not ipadMicRefreshTask:start() then
        ipadMicRefreshTask = nil
        print("ERROR: iPad mic refresh failed to start")
        return
    end
    pcall(hs.settings.set, ipadMicRefreshSettingKey, now)
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
        _G.IpadMode.onTurnedOn(kickIpadMicRefresh)
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

local handoffOk, handoffError = pcall(function()
    dofile(hs.configdir .. "/handoff.lua")
end)

if not handoffOk then
    print("ERROR: Handoff guard failed to load:", handoffError)
    hs.alert.show("Handoff guard error")
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

local betterTerminalOk, betterTerminalError = pcall(function()
    package.path = package.path
        .. ";/Volumes/Work/Projects/better-terminal/hammerspoon/?.lua"
        .. ";/Volumes/Work/Projects/better-terminal/hammerspoon/?/init.lua"
    require("bt")
    _G.bt.setProfile(_G.IpadMode and _G.IpadMode.isOn and _G.IpadMode.isOn() and "ipad" or "desktop")
end)

if not betterTerminalOk then
    print("ERROR: Better Terminal failed to load:", betterTerminalError)
end
