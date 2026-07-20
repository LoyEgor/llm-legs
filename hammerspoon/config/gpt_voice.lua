local GptVoice = {}

local socketPath = os.getenv("HOME") .. "/.transcriptions-gpt/control.sock"
local pollInterval = 0.7
local offlinePollInterval = 3
local requestTimeout = 2
local pollTimer = nil
local pollTimerInterval = nil
local requests = {}
local offlineReported = false

GptVoice.state = "offline"

local function refreshMenu()
    pcall(function()
        if _G.AutomationMenu and _G.AutomationMenu.refresh then
            _G.AutomationMenu.refresh()
        end
    end)
end

local function setState(state)
    if GptVoice.state == state then
        return false
    end

    GptVoice.state = state
    refreshMenu()
    return true
end

local function markOffline()
    setState("offline")

    if not offlineReported then
        offlineReported = true
        print("ERROR: GPT Voice daemon unreachable")
    end
end

local function sendCommand(command, callback)
    local ok, err = pcall(function()
        local socket
        local timeoutTimer
        local finished = false

        local function finish(reply)
            if finished then
                return
            end

            finished = true

            if timeoutTimer then
                timeoutTimer:stop()
            end

            if socket then
                pcall(function()
                    socket:disconnect()
                end)
                requests[socket] = nil
            end

            if reply then
                offlineReported = false
                if callback then
                    pcall(callback, reply)
                end
            else
                markOffline()
                if callback then
                    pcall(callback, "offline")
                end
            end
        end

        socket = hs.socket.new(function(data)
            local reply = tostring(data or ""):gsub("%s+$", "")
            finish(reply ~= "" and reply or nil)
        end)
        requests[socket] = true

        timeoutTimer = hs.timer.doAfter(requestTimeout, function()
            finish(nil)
        end)

        local connected = socket:connect(socketPath, function()
            local writeOk = pcall(function()
                socket:write(command .. "\n")
                socket:read("\n")
            end)

            if not writeOk then
                finish(nil)
            end
        end)

        if not connected then
            finish(nil)
        end
    end)

    if not ok then
        markOffline()
        if callback then
            pcall(callback, "offline")
        end
        return false, err
    end

    return true
end

local function stopPoller()
    if pollTimer then
        pollTimer:stop()
        pollTimer = nil
        pollTimerInterval = nil
    end
end

local function startPoller()
    -- "idle" is the only healthy terminal state (user actions restart the
    -- poller). "offline" must NOT stop it: without a recovery poll the menu
    -- stays stuck offline forever after any transient daemon blip (e.g. a
    -- daemon restart rebinding the socket) and its items sit disabled with no
    -- way to re-probe. Keep a slow poll going so it self-heals.
    if GptVoice.state == "idle" then
        stopPoller()
        return
    end

    local interval = GptVoice.state == "offline" and offlinePollInterval or pollInterval
    if pollTimer and pollTimerInterval == interval then
        return
    end

    stopPoller()
    pollTimerInterval = interval
    pollTimer = hs.timer.doEvery(interval, function()
        pcall(function()
            GptVoice.refreshStatus()
        end)
    end)
end

function GptVoice.refreshStatus(callback)
    return sendCommand("status", function(reply)
        if reply == "idle" or reply == "recording" or reply == "processing" or reply == "transforming" then
            setState(reply)

            if reply == "idle" then
                stopPoller()
                refreshMenu()
            else
                startPoller()
            end
        else
            markOffline()
            startPoller()
        end

        if callback then
            pcall(callback, GptVoice.state)
        end
    end)
end

local function runAction(command, expectedState)
    pcall(function()
        sendCommand(command)
        setState(expectedState)
        refreshMenu()
        startPoller()
    end)
end

function GptVoice.start()
    runAction("start", "recording")
end

function GptVoice.stop()
    runAction("stop", "processing")
end

function GptVoice.cancel()
    runAction("cancel", "idle")
end

function GptVoice.transform()
    runAction("transform", "transforming")
end

GptVoice.refreshStatus()

_G.GptVoice = GptVoice

return GptVoice
