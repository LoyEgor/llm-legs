local IpadOverlay = {}

local HELPER_PATH = "/Volumes/Work/Projects/llm-legs/hammerspoon/ipad_overlay_app/overlay_app.py"
local PYTHON_PATH = "/Volumes/Work/Projects/transcriptions-gpt/.venv/bin/python"
local SOCK_PATH = os.getenv("HOME") .. "/.local/state/ipad-overlay/control.sock"

local task = nil
local visible = false
local enabled = true
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

-- hs.task stdin delivers EOF to the child immediately, so commands go over
-- the helper's unix socket. Delivery is ack-based: connecting to a stale
-- socket file of a dead helper "succeeds" but never answers, so only a
-- reply counts and anything else retries (also covers the startup window).
local sendCommand
sendCommand = function(cmd, attempt)
    attempt = attempt or 1
    local finished = false
    local sock

    local function finish(delivered)
        if finished then
            return
        end
        finished = true
        if sock then
            pcall(function() sock:disconnect() end)
            pendingSockets[sock] = nil
        end
        if not delivered and attempt < 8 then
            retrySeq = retrySeq + 1
            local key = "retry" .. retrySeq
            retryTimers[key] = hs.timer.doAfter(0.35 * attempt, function()
                retryTimers[key] = nil
                sendCommand(cmd, attempt + 1)
            end)
        end
    end

    local ok = pcall(function()
        sock = hs.socket.new(function(data)
            finish(data ~= nil and #tostring(data) > 0)
        end)
        pendingSockets[sock] = true
        local connected = sock:connect(SOCK_PATH, function()
            pcall(function()
                sock:write(cmd .. "\n")
                sock:read("\n")
            end)
        end)
        if not connected then
            error("connect failed")
        end
        retrySeq = retrySeq + 1
        local tkey = "timeout" .. retrySeq
        retryTimers[tkey] = hs.timer.doAfter(1.2, function()
            retryTimers[tkey] = nil
            finish(false)
        end)
    end)
    if not ok then
        finish(false)
    end
end
IpadOverlay._sendCommand = sendCommand

-- isEnabled is the user's preference alone; the panel is actually shown
-- only while an iPad is connected (IpadMode) on top of it.
local function shouldShow()
    return enabled and (_G.IpadMode and _G.IpadMode.isOn() or false)
end

function IpadOverlay.show()
    if not shouldShow() then
        return
    end

    if not task then
        IpadOverlay._launch_helper()
    end

    if task then
        visible = true
        sendCommand("show")
    end
end

function IpadOverlay.hide()
    visible = false
    if task then
        sendCommand("hide")
    end
end

function IpadOverlay.isEnabled()
    return enabled
end

function IpadOverlay.setEnabled(value)
    enabled = value
    hs.settings.set("ipadOverlay.enabled", value)
    IpadOverlay.recompute()
    IpadOverlay._notifyChange()
end

function IpadOverlay.recompute()
    if shouldShow() then
        IpadOverlay.show()
    else
        IpadOverlay.hide()
    end
end

function IpadOverlay.onChange(callback)
    if type(callback) == "function" then
        table.insert(onChangeHooks, callback)
    end
end

function IpadOverlay._launch_helper()
    local task_obj = hs.task.new(PYTHON_PATH, function(exit_code)
        IpadOverlay._on_helper_exit(exit_code)
    end, { HELPER_PATH })

    if task_obj:start() then
        task = task_obj
        -- Reset the crash-loop counter only after the helper proves stable;
        -- resetting at launch would make the retry cap unreachable.
        if backoff_reset_timer then
            backoff_reset_timer:stop()
        end
        backoff_reset_timer = hs.timer.doAfter(10, function()
            relaunch_attempts = 0
        end)
        if visible then
            sendCommand("show")
        end
    end
end

function IpadOverlay._on_helper_exit(exit_code)
    if task then
        task = nil
    end

    if visible and relaunch_attempts < max_relaunch_attempts then
        relaunch_attempts = relaunch_attempts + 1
        if relaunch_timer then
            relaunch_timer:stop()
        end

        local backoff = math.min(relaunch_backoff * (2 ^ (relaunch_attempts - 1)), relaunch_max_backoff)
        relaunch_timer = hs.timer.doAfter(backoff, function()
            IpadOverlay._launch_helper()
        end)
    end
end

function IpadOverlay._notifyChange()
    for _, fn in ipairs(onChangeHooks) do
        pcall(fn)
    end
end

function IpadOverlay._on_ipad_mode_change()
    IpadOverlay.recompute()
end

function IpadOverlay.init()
    enabled = hs.settings.get("ipadOverlay.enabled")
    if enabled == nil then
        enabled = true
        hs.settings.set("ipadOverlay.enabled", true)
    end

    if _G.IpadMode then
        _G.IpadMode.onChange(IpadOverlay._on_ipad_mode_change)
    end

    IpadOverlay.recompute()
end

_G.IpadOverlay = IpadOverlay
IpadOverlay.init()

return IpadOverlay
