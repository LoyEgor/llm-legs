local IpadMode = {}

local defaultLogDir = os.getenv("HOME") .. "/Library/Logs/Jump Desktop/"
local disconnectCooldownSeconds = 90
local disconnectDebounceSeconds = 60
local logDir = defaultLogDir
local on = nil
local jumpConnected = false
local liveProxyPids = {}
local offsets = {}
local inodes = {}
local partialLines = {}
local previousSignals = nil
local manualOverride = nil
local disconnectDebounceTimer = nil
local disconnectCooldownUntil = nil
local cooldownExpiryTimer = nil
local wakeDeadlineTimer = nil
local wakeConfirmationSeconds = 90
local cooldownSettingKey = "IpadMode.cooldownUntil"
local scheduleCooldownExpiry
local scanAppends
local scanAppendsForDecision

do
    local ok, stored = pcall(function()
        return hs.settings.get(cooldownSettingKey)
    end)
    if ok and tonumber(stored) and tonumber(stored) > os.time() then
        disconnectCooldownUntil = tonumber(stored)
    elseif ok and stored ~= nil then
        pcall(hs.settings.clear, cooldownSettingKey)
    end
end

local function normalizeDir(path)
    return path:sub(-1) == "/" and path or (path .. "/")
end

local function logChange(value, reason)
    local line = "[ipad-mode] " .. (value and "on" or "off") .. " (" .. reason .. ")"
    print(line)
    if _G.Notify and _G.Notify.log then
        _G.Notify.log(line)
    end
end

local function cancelDisconnectDebounce()
    if disconnectDebounceTimer then
        disconnectDebounceTimer:stop()
        disconnectDebounceTimer = nil
    end
end

local function cancelWakeDeadline()
    if wakeDeadlineTimer then
        wakeDeadlineTimer:stop()
        wakeDeadlineTimer = nil
    end
end

local function cooldownActive()
    return disconnectCooldownUntil ~= nil and os.time() < disconnectCooldownUntil
end

local function armDisconnectCooldown(seconds)
    disconnectCooldownUntil = os.time() + (seconds or disconnectCooldownSeconds)
    pcall(hs.settings.set, cooldownSettingKey, disconnectCooldownUntil)
    if scheduleCooldownExpiry then
        scheduleCooldownExpiry()
    end
end

local function clearDisconnectCooldown()
    disconnectCooldownUntil = nil
    pcall(hs.settings.clear, cooldownSettingKey)
    if cooldownExpiryTimer then
        cooldownExpiryTimer:stop()
        cooldownExpiryTimer = nil
    end
end

local function runAction(value)
    if not _G.IpadAutomation then
        return
    end
    local handler = value and _G.IpadAutomation.ipadConnected or _G.IpadAutomation.ipadDisconnected
    if handler then
        local ok, err = pcall(handler)
        if not ok then
            print("ERROR: iPad transition action failed:", err)
        end
    end
end

local function apply(value, reason)
    value = value == true
    if on == value then
        return false
    end
    if value then
        cancelDisconnectDebounce()
    else
        cancelWakeDeadline()
    end
    on = value
    logChange(on, reason)
    runAction(on)
    return true
end

local function sidecarPresentNow()
    return _G.IpadAutomation ~= nil
        and _G.IpadAutomation.getSidecarPresent ~= nil
        and _G.IpadAutomation.getSidecarPresent() == true
end

local function signalSnapshot(sidecar)
    return {
        sidecar = sidecar == nil and sidecarPresentNow() or sidecar == true,
        jump = jumpConnected,
    }
end

local function signalsEqual(left, right)
    return left ~= nil
        and left.sidecar == right.sidecar
        and left.jump == right.jump
end

local function derivedOn(signals)
    return signals.sidecar or signals.jump
end

scheduleCooldownExpiry = function()
    if cooldownExpiryTimer then
        cooldownExpiryTimer:stop()
    end
    local delay = math.max(0, (disconnectCooldownUntil or os.time()) - os.time())
    cooldownExpiryTimer = hs.timer.doAfter(delay, function()
        cooldownExpiryTimer = nil
        if cooldownActive() then
            scheduleCooldownExpiry()
            return
        end
        disconnectCooldownUntil = nil
        pcall(hs.settings.clear, cooldownSettingKey)
        manualOverride = nil
        IpadMode.recompute("disconnect cooldown expired", nil, true)
    end)
end

local function debounceDisconnect(reason)
    if disconnectDebounceTimer or on ~= true then
        return
    end
    disconnectDebounceTimer = hs.timer.doAfter(disconnectDebounceSeconds, function()
        disconnectDebounceTimer = nil
        scanAppendsForDecision()
        IpadMode.recheckJumpLiveness(true)
        local signals = signalSnapshot()
        previousSignals = signals
        if derivedOn(signals) or manualOverride ~= nil or cooldownActive() then
            return
        end
        apply(false, reason)
    end)
end

local function parseLine(line)
    local pid = line:match("^%d%d%d%d%-%d%d%-%d%d%s+%d%d:%d%d:%d%d:%d+%s+(%d+):%d+%s+INFO%s+")
    if not pid then
        return
    end

    if line:find("[connect_app] Starting in Desktop proxy mode", 1, true) then
        liveProxyPids[pid] = true
        return
    end
    -- Agent-mode exits must not end a proxy session unless that pid entered proxy mode.

    if liveProxyPids[pid]
        and (line:find("Disconnected from server. Signaling finish", 1, true)
            or line:find("[connect_app] Exiting process", 1, true)) then
        liveProxyPids[pid] = nil
    end
end

local function listAgentLogs()
    local files = {}
    local ok, iterator, directory = pcall(hs.fs.dir, logDir)
    if not ok or not iterator then
        return files
    end
    for name in iterator, directory do
        if name:match("^Agent_.*%.log$") then
            table.insert(files, name)
        end
    end
    table.sort(files)
    return files
end

local function readAppended(fileName)
    local path = logDir .. fileName
    local size = hs.fs.attributes(path, "size")
    local inode = hs.fs.attributes(path, "ino")
    if not size then
        return
    end

    local offset = offsets[fileName] or 0
    if size < offset or (inodes[fileName] and inode ~= inodes[fileName]) then
        offset = 0
        partialLines[fileName] = nil
    end
    inodes[fileName] = inode
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
    offsets[fileName] = offset + #appended

    local content = (partialLines[fileName] or "") .. appended
    local startAt = 1
    while true do
        local newlineAt = content:find("\n", startAt, true)
        if not newlineAt then
            partialLines[fileName] = content:sub(startAt)
            break
        end
        parseLine(content:sub(startAt, newlineAt - 1):gsub("\r$", ""))
        startAt = newlineAt + 1
    end
end

local function updateJumpConnected(reason, suppressRecompute)
    local wasConnected = jumpConnected
    jumpConnected = next(liveProxyPids) ~= nil
    if jumpConnected ~= wasConnected and previousSignals ~= nil and not suppressRecompute then
        IpadMode.recompute(reason)
    end
end

local function ingestAppends(suppressRecompute)
    for _, fileName in ipairs(listAgentLogs()) do
        readAppended(fileName)
    end
    updateJumpConnected("Jump Desktop signal", suppressRecompute)
end

scanAppends = function()
    ingestAppends(false)
end

scanAppendsForDecision = function()
    ingestAppends(true)
end

local function pidAlive(pid)
    local _, ok = hs.execute("/bin/kill -0 " .. pid .. " >/dev/null 2>&1")
    return ok == true
end

local function recoverToday()
    liveProxyPids = {}
    offsets = {}
    inodes = {}
    partialLines = {}

    local todayFile = "Agent_" .. os.date("%Y_%m_%d") .. ".log"
    local yesterdayFile = "Agent_" .. os.date("%Y_%m_%d", os.time() - 86400) .. ".log"
    for _, fileName in ipairs(listAgentLogs()) do
        local size = hs.fs.attributes(logDir .. fileName, "size") or 0
        if fileName == todayFile or fileName == yesterdayFile then
            readAppended(fileName)
        else
            offsets[fileName] = size
            inodes[fileName] = hs.fs.attributes(logDir .. fileName, "ino")
        end
    end

    for pid in pairs(liveProxyPids) do
        if not pidAlive(pid) then
            liveProxyPids[pid] = nil
        end
    end
    updateJumpConnected("Jump Desktop recovery")
end

local function restartWatcher()
    if IpadMode.jumpWatcher then
        IpadMode.jumpWatcher:stop()
    end
    recoverToday()
    IpadMode.jumpWatcher = hs.pathwatcher.new(logDir, scanAppends)
    IpadMode.jumpWatcher:start()
end

function IpadMode.isOn()
    return on == true
end

function IpadMode.recompute(reason, sidecar, force)
    local signals = signalSnapshot(sidecar)
    local detected = derivedOn(signals)
    if detected then
        cancelWakeDeadline()
    end
    if previousSignals == nil then
        previousSignals = signals
        on = detected and not cooldownActive()
        logChange(on, reason or "initial signals")
        return on
    end
    if not force and signalsEqual(previousSignals, signals) then
        return on
    end
    previousSignals = signals
    if manualOverride ~= nil then
        if detected == manualOverride then
            manualOverride = nil
        end
        return on
    end
    if detected then
        cancelDisconnectDebounce()
        if cooldownActive() then
            return on
        end
        apply(true, reason or "automatic signal")
    elseif on then
        debounceDisconnect(reason or "automatic signal")
    end
    return on
end

local baselineReconciled = false

function IpadMode.reconcileBaseline()
    if baselineReconciled or not _G.IpadAutomation then
        return on
    end
    if previousSignals == nil then
        IpadMode.recompute("initial signals")
    end
    baselineReconciled = true
    if on then
        runAction(true)
    elseif _G.IpadAutomation.ipadJunkPresent
        and _G.IpadAutomation.ipadJunkPresent() then
        runAction(false)
    end
    return on
end

function IpadMode.setManual(value)
    value = value == true
    cancelDisconnectDebounce()
    cancelWakeDeadline()
    if value then
        clearDisconnectCooldown()
    else
        armDisconnectCooldown()
    end
    IpadMode.recheckJumpLiveness(true)
    local signals = signalSnapshot()
    previousSignals = signals
    manualOverride = derivedOn(signals) == value and nil or value
    if on ~= value then
        on = value
        logChange(on, "manual")
    end
    runAction(value)
    return on
end

function IpadMode.wakeOnAttempt()
    if on == true or cooldownActive() then
        return false
    end
    cancelDisconnectDebounce()
    manualOverride = nil
    IpadMode.recheckJumpLiveness(true)
    local signals = signalSnapshot()
    previousSignals = signals
    on = true
    logChange(on, "Jump connection attempt")
    runAction(true)
    if not derivedOn(signals) then
        wakeDeadlineTimer = hs.timer.doAfter(wakeConfirmationSeconds, function()
            wakeDeadlineTimer = nil
            scanAppendsForDecision()
            IpadMode.recheckJumpLiveness(true)
            local currentSignals = signalSnapshot()
            previousSignals = currentSignals
            if derivedOn(currentSignals) then
                return
            end
            manualOverride = nil
            apply(false, "Jump connection attempt unconfirmed")
        end)
    end
    return true
end

function IpadMode.getJumpConnected()
    return jumpConnected
end

function IpadMode.recheckJumpLiveness(suppressRecompute)
    for pid in pairs(liveProxyPids) do
        if not pidAlive(pid) then
            liveProxyPids[pid] = nil
        end
    end
    updateJumpConnected("Jump Desktop liveness", suppressRecompute == true)
    return jumpConnected
end

function IpadMode.isDisconnectCooldown()
    return cooldownActive()
end

function IpadMode.clearDisconnectCooldown()
    clearDisconnectCooldown()
end

function IpadMode._setLogDirForTest(path)
    logDir = normalizeDir(path or defaultLogDir)
    restartWatcher()
end

function IpadMode._getLogDirForTest()
    return logDir
end

_G.IpadMode = IpadMode

restartWatcher()
IpadMode.recompute("initial signals")
if disconnectCooldownUntil then
    scheduleCooldownExpiry()
end
IpadMode.jumpLivenessTimer = hs.timer.doEvery(60, IpadMode.recheckJumpLiveness)

return IpadMode
