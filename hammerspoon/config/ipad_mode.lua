local IpadMode = {}

local defaultLogDir = os.getenv("HOME") .. "/Library/Logs/Jump Desktop/"
local logDir = defaultLogDir
local on = false
local jumpConnected = false
local liveProxyPids = {}
local offsets = {}
local partialLines = {}
local previousSignals = nil

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

local function apply(value, reason)
    value = value == true
    if on == value then
        return false
    end
    on = value
    logChange(on, reason)
    return true
end

local function monitorOnNow()
    if _G.MonitorAutomation == nil then
        return true
    end
    return _G.MonitorAutomation.getState() == "MONITOR_ON"
end

local function sidecarPresentNow()
    return _G.IpadTrigger ~= nil
        and _G.IpadTrigger.getSidecarActive() == true
end

local function signalSnapshot()
    return {
        monitorOn = monitorOnNow(),
        sidecar = sidecarPresentNow(),
        jump = jumpConnected,
    }
end

local function signalsEqual(left, right)
    return left ~= nil
        and left.monitorOn == right.monitorOn
        and left.sidecar == right.sidecar
        and left.jump == right.jump
end

local function derivedOn(signals)
    return not signals.monitorOn or signals.sidecar or signals.jump
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
    if not size then
        return
    end

    local offset = offsets[fileName] or 0
    if size < offset then
        offset = 0
        partialLines[fileName] = nil
    end
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

local function updateJumpConnected(reason)
    local wasConnected = jumpConnected
    jumpConnected = next(liveProxyPids) ~= nil
    if jumpConnected ~= wasConnected and previousSignals ~= nil then
        if _G.DockAutomation then
            _G.DockAutomation.setAutoHide(not sidecarPresentNow())
        end
        IpadMode.recompute(reason)
    end
end

local function scanAppends()
    for _, fileName in ipairs(listAgentLogs()) do
        readAppended(fileName)
    end
    updateJumpConnected("Jump Desktop signal")
end

local function pidAlive(pid)
    local _, ok = hs.execute("/bin/kill -0 " .. pid .. " >/dev/null 2>&1")
    return ok == true
end

local function recoverToday()
    liveProxyPids = {}
    offsets = {}
    partialLines = {}

    local todayFile = "Agent_" .. os.date("%Y_%m_%d") .. ".log"
    local yesterdayFile = "Agent_" .. os.date("%Y_%m_%d", os.time() - 86400) .. ".log"
    for _, fileName in ipairs(listAgentLogs()) do
        local size = hs.fs.attributes(logDir .. fileName, "size") or 0
        if fileName == todayFile or fileName == yesterdayFile then
            readAppended(fileName)
        else
            offsets[fileName] = size
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
    return on
end

function IpadMode.set(value)
    apply(value, "manual")
end

function IpadMode.toggle()
    IpadMode.set(not on)
end

function IpadMode.recompute(reason)
    local signals = signalSnapshot()
    if signalsEqual(previousSignals, signals) then
        return on
    end
    previousSignals = signals
    apply(derivedOn(signals), reason or "automatic signal")
    return on
end

function IpadMode.getJumpConnected()
    return jumpConnected
end

function IpadMode.recheckJumpLiveness()
    if next(liveProxyPids) == nil then
        return jumpConnected
    end
    for pid in pairs(liveProxyPids) do
        if not pidAlive(pid) then
            liveProxyPids[pid] = nil
        end
    end
    updateJumpConnected("Jump Desktop liveness")
    return jumpConnected
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
IpadMode.jumpLivenessTimer = hs.timer.doEvery(60, IpadMode.recheckJumpLiveness)

return IpadMode
