local IpadOverlay = {}

local HELPER_PATH = "/Volumes/Work/Projects/llm-legs/hammerspoon/ipad_overlay_app/overlay_app.py"
local PYTHON_PATH = "/Volumes/Work/Projects/transcriptions-gpt/.venv/bin/python"
local SOCK_PATH = os.getenv("HOME") .. "/.local/state/ipad-overlay/control.sock"

local task = nil
local attachedHelper = false
local visible = false
local relaunch_backoff = 0.5
local relaunch_max_backoff = 2.0
local relaunch_attempts = 0
local max_relaunch_attempts = 3
local relaunch_timer = nil
local backoff_reset_timer = nil
local onChangeHooks = {}
-- Sockets and timers held here so the GC can't collect them mid-flight.
local pendingSockets = {}
local retryTimers = {}
local retrySeq = 0
local commandGeneration = 0

-- hs.task stdin delivers EOF to the child immediately, so commands go over
-- the helper's unix socket. Delivery is ack-based: connecting to a stale
-- socket file of a dead helper "succeeds" but never answers, so only a
-- reply counts and anything else retries (also covers the startup window).
local sendCommand
sendCommand = function(cmd, attempt, generation, callback)
    attempt = attempt or 1
    generation = generation or commandGeneration
    if generation ~= commandGeneration then
        return
    end
    local finished = false
    local sock
    local timeoutKey

    local function finish(delivered, reply)
        if finished then
            return
        end
        finished = true
        if timeoutKey then
            local timer = retryTimers[timeoutKey]
            if timer then
                timer:stop()
                retryTimers[timeoutKey] = nil
            end
            timeoutKey = nil
        end
        if sock then
            pcall(function() sock:disconnect() end)
            pendingSockets[sock] = nil
        end
        local willRetry = not delivered and attempt < 8 and generation == commandGeneration
        if callback and (delivered or not willRetry) then
            pcall(callback, delivered and reply or nil)
        end
        if willRetry then
            retrySeq = retrySeq + 1
            local key = "retry" .. retrySeq
            retryTimers[key] = hs.timer.doAfter(0.35 * attempt, function()
                retryTimers[key] = nil
                sendCommand(cmd, attempt + 1, generation, callback)
            end)
        end
    end

    local ok = pcall(function()
        sock = hs.socket.new(function(data)
            local reply = tostring(data or ""):gsub("%s+$", "")
            finish(reply ~= "", reply)
        end)
        pendingSockets[sock] = true
        retrySeq = retrySeq + 1
        timeoutKey = "timeout" .. retrySeq
        retryTimers[timeoutKey] = hs.timer.doAfter(1.2, function()
            if timeoutKey then
                retryTimers[timeoutKey] = nil
            end
            timeoutKey = nil
            finish(false)
        end)
        local connected = sock:connect(SOCK_PATH, function()
            if generation ~= commandGeneration then
                finish(true)
                return
            end
            pcall(function()
                sock:write(cmd .. "\n")
                sock:read("\n")
            end)
        end)
        if not connected then
            error("connect failed")
        end
    end)
    if not ok then
        finish(false)
    end
end
IpadOverlay._sendCommand = sendCommand

local function advanceCommandGeneration()
    commandGeneration = commandGeneration + 1
    for key, timer in pairs(retryTimers) do
        timer:stop()
        retryTimers[key] = nil
    end
    for sock in pairs(pendingSockets) do
        pcall(function() sock:disconnect() end)
        pendingSockets[sock] = nil
    end
    return commandGeneration
end

local function helperPresent()
    return task ~= nil or attachedHelper
end

-- Visibility follows iPad connection automatically (connect shows,
-- disconnect hides), but the menu toggle is a manual override in both
-- directions: force-show without an iPad, force-hide with one.
local idleQuitTimer = nil

function IpadOverlay.show()
    local generation = advanceCommandGeneration()
    if idleQuitTimer then
        idleQuitTimer:stop()
        idleQuitTimer = nil
    end
    if relaunch_timer then
        relaunch_timer:stop()
        relaunch_timer = nil
    end
    -- A show is fresh intent: restore the full crash-relaunch budget even if
    -- an earlier crash loop exhausted it.
    relaunch_attempts = 0
    visible = true

    if not helperPresent() then
        IpadOverlay._launch_helper()
    else
        sendCommand("show", 1, generation, function(reply)
            if not reply and generation == commandGeneration and visible and attachedHelper and not task then
                attachedHelper = false
                IpadOverlay._launch_helper()
            end
        end)
    end
end

function IpadOverlay.hide()
    local generation = advanceCommandGeneration()
    visible = false
    -- A relaunch pending from a crash-while-visible would otherwise respawn
    -- a hidden helper with no idle-quit armed.
    if relaunch_timer then
        relaunch_timer:stop()
        relaunch_timer = nil
    end
    if helperPresent() then
        sendCommand("hide", 1, generation)
        -- The helper must cost nothing while the overlay stays hidden (no
        -- iPad connected): quit it entirely after a grace period; show()
        -- respawns it.
        if idleQuitTimer then
            idleQuitTimer:stop()
        end
        idleQuitTimer = hs.timer.doAfter(60, function()
            idleQuitTimer = nil
            if not visible and generation == commandGeneration and helperPresent() then
                -- Single attempt (attempt=8 disables retries): a retry left
                -- in flight could kill a helper that show() just respawned;
                -- a lost quit merely leaves the helper idle until next time.
                sendCommand("quit", 8, generation)
                -- Drop the handle now: a show() landing before the helper
                -- finishes dying must respawn, not talk to a corpse (the
                -- pre-spawn stray sweep reaps it if the quit got lost).
                task = nil
                attachedHelper = false
            end
        end)
    end
end

function IpadOverlay.isShown()
    return visible
end

function IpadOverlay.toggle()
    if visible then
        IpadOverlay.hide()
    else
        IpadOverlay.show()
    end
    IpadOverlay._notifyChange()
end

function IpadOverlay.onChange(callback)
    if type(callback) == "function" then
        table.insert(onChangeHooks, callback)
    end
end

function IpadOverlay._launch_helper()
    attachedHelper = false
    local command = '/usr/bin/nohup "' .. PYTHON_PATH .. '" "' .. HELPER_PATH
        .. '" --parent-pid ' .. tostring(hs.processInfo.processID) .. ' >/dev/null 2>&1 &'
    local taskObj
    taskObj = hs.task.new("/bin/sh", function(exitCode)
        if task == taskObj then
            task = nil
        end
        if exitCode ~= 0 then
            attachedHelper = false
            IpadOverlay._on_helper_exit(exitCode)
        end
    end, { "-c", command })

    if taskObj then
        task = taskObj
    end
    if taskObj and taskObj:start() then
        attachedHelper = true
        -- Reset the crash-loop counter only after the helper proves stable;
        -- resetting at launch would make the retry cap unreachable.
        if backoff_reset_timer then
            backoff_reset_timer:stop()
        end
        backoff_reset_timer = hs.timer.doAfter(10, function()
            relaunch_attempts = 0
        end)
        if visible then
            sendCommand("show", 1, commandGeneration)
        end
    else
        task = nil
        IpadOverlay._on_helper_exit(-1)
    end
end

function IpadOverlay._on_helper_exit(exit_code)
    if task then
        task = nil
    end
    attachedHelper = false

    if visible and relaunch_attempts < max_relaunch_attempts then
        relaunch_attempts = relaunch_attempts + 1
        if relaunch_timer then
            relaunch_timer:stop()
        end

        local backoff = math.min(relaunch_backoff * (2 ^ (relaunch_attempts - 1)), relaunch_max_backoff)
        relaunch_timer = hs.timer.doAfter(backoff, function()
            relaunch_timer = nil
            if visible then
                IpadOverlay._launch_helper()
            end
        end)
    elseif visible then
        -- Giving up: leaving visible=true would make isShown()/the menu
        -- checkmark lie and turn the next toggle() into a no-op hide.
        visible = false
        IpadOverlay._notifyChange()
    end
end

function IpadOverlay._notifyChange()
    for _, fn in ipairs(onChangeHooks) do
        pcall(fn)
    end
end

local function attachExistingHelper()
    local generation = commandGeneration
    sendCommand("status", 8, generation, function(reply)
        if generation ~= commandGeneration then
            return
        end
        if reply == "visible" or reply == "hidden" then
            attachedHelper = true
            visible = reply == "visible"
        end
    end)
end

function IpadOverlay.init()
    attachExistingHelper()
end

_G.IpadOverlay = IpadOverlay
IpadOverlay.init()

return IpadOverlay
