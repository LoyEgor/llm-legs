local DisplayMirror = {}

local CLI_PATH = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
local RESOLUTION_SETTING = "DisplayMirror.virtualResolution"
local CLI_TIMEOUT_SECONDS = 10
local VIRTUAL_CONNECT_MAX_ATTEMPTS = 6

local activeTask = nil
local activeWatchdog = nil
local reconcileGeneration = 0
local screenGeneration = 0
local screenTimer = nil
local virtualConnectAttempts = 0
local virtualConnectRetryTimer = nil
local completionQueue = {}
local pendingReason = nil
local beginReconcile

local state = {
    currentMirrored = nil,
    currentMain = nil,
    currentResolution = nil,
    busy = false,
    lastReason = nil,
    lastAction = nil,
    lastError = nil,
    lastCommand = nil,
    updatedAt = nil,
}

local function enforceEnabled()
    local automation = _G.IpadAutomation
    if not automation or type(automation.enforceEnabled) ~= "function" then
        return true
    end
    local ok, active = pcall(automation.enforceEnabled)
    return not ok or active ~= false
end

local function ipadConnected()
    local mode = _G.IpadMode
    if not mode or type(mode.isOn) ~= "function" then
        return false
    end
    local ok, connected = pcall(mode.isOn)
    return ok and connected == true
end

local function topology()
    local result = {
        screenNames = {},
        virtualName = nil,
        physicalName = nil,
    }
    for _, screen in ipairs(hs.screen.allScreens()) do
        local name = screen:name() or ""
        result.screenNames[#result.screenNames + 1] = name
        if name:sub(1, 7) == "Virtual" then
            result.virtualName = result.virtualName or name
        elseif name ~= "" then
            result.physicalName = result.physicalName or name
        end
    end
    result.enforceEnabled = enforceEnabled()
    result.ipadConnected = ipadConnected()
    result.physicalPresent = result.physicalName ~= nil
    return result
end

local function desiredMirrored(current, mirrored)
    return current.enforceEnabled
        and current.ipadConnected
        and (current.physicalPresent or mirrored == true)
end

local function resetVirtualConnectRetries()
    virtualConnectAttempts = 0
    if virtualConnectRetryTimer then
        virtualConnectRetryTimer:stop()
        virtualConnectRetryTimer = nil
    end
end

local function scheduleVirtualConnectRetry()
    if virtualConnectAttempts >= VIRTUAL_CONNECT_MAX_ATTEMPTS
        or virtualConnectRetryTimer then
        return
    end
    virtualConnectRetryTimer = hs.timer.doAfter(5, function()
        virtualConnectRetryTimer = nil
        local current = topology()
        if current.virtualName or not desiredMirrored(current, false) then
            resetVirtualConnectRetries()
            return
        end
        if virtualConnectAttempts >= VIRTUAL_CONNECT_MAX_ATTEMPTS then
            return
        end
        DisplayMirror.reconcile("virtual display connect retry")
    end)
end

local function commandText(args)
    local parts = { CLI_PATH }
    for _, arg in ipairs(args) do
        if arg:find(" ", 1, true) then
            parts[#parts + 1] = string.format("%q", arg)
        else
            parts[#parts + 1] = arg
        end
    end
    return table.concat(parts, " ")
end

local function firstLine(text)
    return tostring(text or ""):match("^%s*([^\r\n]+)")
end

local function commandError(exitCode, stdOut, stdErr)
    return firstLine(stdErr) or firstLine(stdOut) or ("exit " .. tostring(exitCode))
end

local function parseBool(text)
    local value = tostring(text or ""):lower():match("^%s*(.-)%s*$")
    if value == "on" or value == "true" or value == "1" then
        return true
    end
    if value == "off" or value == "false" or value == "0" then
        return false
    end
    return nil
end

local function parseResolution(text)
    return tostring(text or ""):match("^%s*(%d+x%d+)%s*$")
end

local function storedResolution()
    local ok, value = pcall(hs.settings.get, RESOLUTION_SETTING)
    if not ok or type(value) ~= "string" then
        return nil
    end
    return value:match("^(%d+x%d+)$")
end

-- The watchdog owns completion because a SIGTERM-immune CLI would otherwise pin activeTask forever.
local function runCli(args, generation, completion)
    state.lastCommand = commandText(args)

    local task
    local watchdog
    task = hs.task.new(CLI_PATH, function(exitCode, stdOut, stdErr)
        local self = task
        task = nil
        if activeTask == self then
            activeTask = nil
        end
        local timer = watchdog
        watchdog = nil
        if timer then
            timer:stop()
        end
        if activeWatchdog == timer then
            activeWatchdog = nil
        end
        local callback = completion
        completion = nil
        if not callback then
            return
        end
        if generation ~= reconcileGeneration then
            beginReconcile()
            return
        end
        callback(exitCode, stdOut, stdErr)
    end, args)
    activeTask = task
    local ok, started = false, false
    if task then
        ok, started = pcall(task.start, task)
    end
    if ok and started then
        watchdog = hs.timer.doAfter(CLI_TIMEOUT_SECONDS, function()
            local timer = watchdog
            watchdog = nil
            if activeWatchdog == timer then
                activeWatchdog = nil
            end
            local callback = completion
            completion = nil
            if not callback then
                return
            end
            local runningTask = task
            task = nil
            if activeTask == runningTask then
                activeTask = nil
            end
            if runningTask then
                local pidOk, pid = pcall(function()
                    return runningTask:pid()
                end)
                local runningOk, isRunning = pcall(function()
                    return runningTask:isRunning()
                end)
                if runningOk and isRunning then
                    pcall(function()
                        runningTask:terminate()
                    end)
                    pid = pidOk and tonumber(pid) or nil
                    if pid and pid > 0 then
                        hs.execute("/bin/kill -KILL " .. tostring(math.floor(pid)) .. " 2>/dev/null")
                    end
                end
            end
            if generation ~= reconcileGeneration then
                beginReconcile()
                return
            end
            callback(124, "", "BetterDisplay CLI timed out")
        end)
        activeWatchdog = watchdog
        return true
    end

    local self = task
    task = nil
    if activeTask == self then
        activeTask = nil
    end
    local callback = completion
    completion = nil
    if callback then
        callback(-1, "", "could not start BetterDisplay CLI")
    end
    return false
end

local function statusSnapshot()
    local current = topology()
    return {
        enforceEnabled = current.enforceEnabled,
        ipadConnected = current.ipadConnected,
        screenNames = current.screenNames,
        virtualName = current.virtualName,
        physicalPresent = current.physicalPresent,
        physicalName = current.physicalName,
        desiredMirrored = desiredMirrored(current, state.currentMirrored),
        virtualConnectAttempts = virtualConnectAttempts,
        currentMirrored = state.currentMirrored,
        currentMain = state.currentMain,
        storedResolution = storedResolution(),
        currentResolution = state.currentResolution,
        busy = state.busy,
        lastReason = state.lastReason,
        lastAction = state.lastAction,
        lastError = state.lastError,
        lastCommand = state.lastCommand,
        updatedAt = state.updatedAt,
    }
end

local function finishReconcile(generation, action, err)
    if generation ~= reconcileGeneration then
        beginReconcile()
        return
    end

    state.busy = false
    state.lastAction = action
    state.lastError = err
    state.updatedAt = os.time()
    if err then
        print("[display-mirror] ERROR:", err)
    else
        print("[display-mirror]", action, "(" .. tostring(state.lastReason) .. ")")
    end

    local callbacks = completionQueue
    completionQueue = {}
    local snapshot = statusSnapshot()
    for _, entry in ipairs(callbacks) do
        if entry.generation <= generation then
            pcall(entry.callback, err == nil, snapshot)
        else
            completionQueue[#completionQueue + 1] = entry
        end
    end
end

local function setMain(generation, virtualName, completion)
    runCli({ "set", "-name=" .. virtualName, "-main=on" }, generation,
        function(exitCode, stdOut, stdErr)
            if exitCode ~= 0 then
                completion(false, commandError(exitCode, stdOut, stdErr))
                return
            end
            state.currentMain = true
            completion(true)
        end)
end

local function setMirrored(generation, virtualName, physicalName, value, completion)
    local args = {
        "set",
        "-name=" .. virtualName,
        "-mirror=" .. (value and "on" or "off"),
    }
    if value then
        args[#args + 1] = "-targetName=" .. physicalName
    end
    runCli(args, generation, function(exitCode, stdOut, stdErr)
        if exitCode ~= 0 then
            completion(false, commandError(exitCode, stdOut, stdErr))
            return
        end
        state.currentMirrored = value
        completion(true)
    end)
end

local function ensureMain(generation, current, completion)
    runCli({ "get", "-name=" .. current.virtualName, "-main" }, generation,
        function(exitCode, stdOut, stdErr)
            if exitCode ~= 0 then
                completion(false, nil, commandError(exitCode, stdOut, stdErr))
                return
            end
            local isMain = parseBool(stdOut)
            if isMain == nil then
                completion(false, nil,
                    "unexpected main-state response: " .. tostring(firstLine(stdOut) or "empty"))
                return
            end
            state.currentMain = isMain
            if isMain then
                completion(true, false)
                return
            end
            setMain(generation, current.virtualName, function(ok, err)
                completion(ok, ok, err)
            end)
        end)
end

local function readResolution(generation, virtualName, completion)
    runCli({ "get", "-name=" .. virtualName, "-resolution" }, generation,
        function(exitCode, stdOut, stdErr)
            if exitCode ~= 0 then
                completion(nil, commandError(exitCode, stdOut, stdErr))
                return
            end
            local resolution = parseResolution(stdOut)
            if not resolution then
                completion(nil,
                    "unexpected resolution response: " .. tostring(firstLine(stdOut) or "empty"))
                return
            end
            state.currentResolution = resolution
            completion(resolution)
        end)
end

local function captureResolution(generation, current)
    readResolution(generation, current.virtualName, function(resolution, err)
        if not resolution then
            finishReconcile(generation, "virtual resolution capture failed", err)
            return
        end
        local ok, settingsError = pcall(hs.settings.set, RESOLUTION_SETTING, resolution)
        if not ok then
            finishReconcile(generation, "virtual resolution capture failed", tostring(settingsError))
            return
        end
        finishReconcile(generation, "captured virtual resolution")
    end)
end

local function assertResolution(generation, current, settledAction)
    local expected = storedResolution()
    if not expected then
        finishReconcile(generation, settledAction)
        return
    end
    readResolution(generation, current.virtualName, function(resolution, err)
        if not resolution then
            finishReconcile(generation, "virtual resolution query failed", err)
            return
        end
        if resolution == expected then
            finishReconcile(generation, settledAction)
            return
        end
        runCli({
            "set",
            "-name=" .. current.virtualName,
            "-resolution=" .. expected,
            "-hiDPI=on",
            "-refreshRate=60",
        }, generation, function(exitCode, stdOut, stdErr)
            if exitCode ~= 0 then
                finishReconcile(generation, "virtual resolution restore failed",
                    commandError(exitCode, stdOut, stdErr))
                return
            end
            state.currentResolution = expected
            finishReconcile(generation, "restored virtual resolution")
        end)
    end)
end

local function finishVirtualConnect(generation, action, err, retry)
    if retry then
        scheduleVirtualConnectRetry()
    end
    finishReconcile(generation, action, err)
end

local function virtualDisplayName(generation, completion)
    runCli({ "get", "-identifiers" }, generation, function(exitCode, stdOut, stdErr)
        if exitCode ~= 0 then
            completion(nil, commandError(exitCode, stdOut, stdErr))
            return
        end
        if not hs.json or type(hs.json.decode) ~= "function" then
            completion(nil, "hs.json.decode is unavailable")
            return
        end
        local ok, entries = pcall(hs.json.decode, "[" .. tostring(stdOut or "") .. "]")
        if not ok or type(entries) ~= "table" then
            completion(nil, "could not decode BetterDisplay identifiers")
            return
        end
        for _, entry in ipairs(entries) do
            if type(entry) == "table"
                and entry.deviceType == "VirtualScreen"
                and type(entry.name) == "string"
                and entry.name ~= "" then
                completion(entry.name)
                return
            end
        end
        completion(nil, "BetterDisplay identifiers contain no VirtualScreen")
    end)
end

local function connectVirtualDisplay(generation, current)
    if virtualConnectAttempts >= VIRTUAL_CONNECT_MAX_ATTEMPTS then
        finishVirtualConnect(generation, "virtual display connect failed",
            "virtual display connect retry limit reached", false)
        return
    end
    if hs.application.get("BetterDisplay") == nil then
        finishVirtualConnect(generation, "waiting for BetterDisplay",
            "BetterDisplay is not running", true)
        return
    end
    virtualConnectAttempts = virtualConnectAttempts + 1
    virtualDisplayName(generation, function(virtualName, err)
        if not virtualName then
            finishVirtualConnect(generation, "virtual display connect failed", err, true)
            return
        end
        runCli({
            "set",
            "-name=" .. virtualName,
            "-connected=on",
        }, generation, function(exitCode, stdOut, stdErr)
            if exitCode ~= 0 then
                finishVirtualConnect(generation, "virtual display connect failed",
                    commandError(exitCode, stdOut, stdErr), true)
                return
            end
            finishVirtualConnect(generation, "connecting virtual display", nil, true)
        end)
    end)
end

beginReconcile = function()
    if activeTask then
        return
    end

    local generation = reconcileGeneration
    local current = topology()
    state.busy = true
    state.lastReason = pendingReason
    state.lastError = nil

    if not current.enforceEnabled then
        resetVirtualConnectRetries()
        finishReconcile(generation, "enforcement paused")
        return
    end

    if current.virtualName or not desiredMirrored(current, false) then
        resetVirtualConnectRetries()
    end

    if not current.virtualName then
        state.currentMirrored = nil
        state.currentMain = nil
        if desiredMirrored(current, false) then
            connectVirtualDisplay(generation, current)
        else
            finishReconcile(generation, "no virtual display")
        end
        return
    end

    runCli({ "get", "-name=" .. current.virtualName, "-mirror" }, generation,
        function(exitCode, stdOut, stdErr)
            if exitCode ~= 0 then
                finishReconcile(generation, "query failed", commandError(exitCode, stdOut, stdErr))
                return
            end

            local mirrored = parseBool(stdOut)
            if mirrored == nil then
                finishReconcile(generation, "query failed",
                    "unexpected mirror-state response: " .. tostring(firstLine(stdOut) or "empty"))
                return
            end
            state.currentMirrored = mirrored

            if not desiredMirrored(current, mirrored) then
                if not mirrored then
                    if not current.physicalPresent then
                        captureResolution(generation, current)
                    else
                        finishReconcile(generation, "already unmirrored")
                    end
                    return
                end
                setMirrored(generation, current.virtualName, nil, false, function(ok, err)
                    finishReconcile(generation, ok and "unmirrored" or "unmirror failed", err)
                end)
                return
            end

            ensureMain(generation, current, function(mainOk, mainChanged, mainError)
                if not mainOk then
                    finishReconcile(generation, "main-display update failed", mainError)
                    return
                end
                if mirrored then
                    assertResolution(generation, current,
                        mainChanged and "made virtual display main" or "already mirrored")
                    return
                end
                setMirrored(generation, current.virtualName, current.physicalName, true, function(ok, err)
                    if not ok then
                        finishReconcile(generation, "mirror failed", err)
                        return
                    end
                    assertResolution(generation, current, "mirrored")
                end)
            end)
        end)
end

function DisplayMirror.reconcile(reason, callback)
    reconcileGeneration = reconcileGeneration + 1
    pendingReason = reason or "requested"
    if type(callback) == "function" then
        completionQueue[#completionQueue + 1] = {
            generation = reconcileGeneration,
            callback = callback,
        }
    end
    beginReconcile()
    return reconcileGeneration
end

function DisplayMirror.prepareDisconnect(callback)
    if not enforceEnabled() then
        local generation = DisplayMirror.reconcile("iPad disconnected")
        if type(callback) == "function" then
            pcall(callback, true, statusSnapshot())
        end
        return generation
    end
    return DisplayMirror.reconcile("iPad disconnected", callback)
end

function DisplayMirror.status()
    return statusSnapshot()
end

local function scheduleScreenReconcile()
    screenGeneration = screenGeneration + 1
    local generation = screenGeneration
    if screenTimer then
        screenTimer:stop()
        screenTimer = nil
    end
    screenTimer = hs.timer.doAfter(2, function()
        if generation ~= screenGeneration then
            return
        end
        screenTimer = nil
        DisplayMirror.reconcile("screen configuration changed")
    end)
end

DisplayMirror.screenWatcher = hs.screen.watcher.new(scheduleScreenReconcile)
DisplayMirror.screenWatcher:start()

_G.DisplayMirror = DisplayMirror
DisplayMirror.reconcile("module init")

return DisplayMirror
