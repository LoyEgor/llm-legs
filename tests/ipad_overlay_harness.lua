local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

-- opts.settings carries an hs.settings store between harnesses, which is how a
-- reload looks to the module: fresh Lua state, same pid, same stored settings.
local function newHarness(helperStatus, opts)
    opts = opts or {}
    local state = {
        execCalls = {},
        settings = opts.settings or {},
        pid = opts.pid or 123,
        helperStatus = helperStatus,
        socketWrites = {},
        taskExitCallbacks = {},
        taskLaunches = {},
        timers = {},
        failConnects = 0,
    }
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.hs = {
        execute = function(cmd)
            state.execCalls[#state.execCalls + 1] = cmd
            -- The only exec the module makes is the helper-process pgrep, and
            -- a fake helper exists exactly while it has a status to report.
            local alive = state.helperStatus ~= nil
            return "", alive, "exit", alive and 0 or 1
        end,
        processInfo = {
            processID = state.pid,
        },
        settings = {
            set = function(key, value)
                state.settings[key] = value
            end,
            get = function(key)
                return state.settings[key]
            end,
        },
        timer = {
            doAfter = function(delay, fn)
                local timer = {
                    delay = delay,
                    fn = fn,
                    stopped = false,
                    stop = function(self)
                        self.stopped = true
                    end,
                }
                state.timers[#state.timers + 1] = timer
                return timer
            end,
        },
        task = {
            new = function(cmd, exitCallback, args)
                return {
                    start = function()
                        state.taskLaunches[#state.taskLaunches + 1] = { cmd = cmd, args = args }
                        state.taskExitCallbacks[#state.taskExitCallbacks + 1] = exitCallback
                        -- A launched helper replaces whatever ran before and
                        -- comes up already showing when argv says so.
                        state.helperStatus = args[2]:find("--show", 1, true)
                            and "visible" or "hidden"
                        return true
                    end,
                }
            end,
        },
        socket = {
            new = function(readCallback)
                local sock = {}
                sock.connect = function(_, _, callback)
                    if state.failConnects > 0 then
                        state.failConnects = state.failConnects - 1
                        return false
                    end
                    if state.helperStatus == nil then
                        return false
                    end
                    callback()
                    return true
                end
                sock.write = function(_, data)
                    sock.command = data:gsub("%s+$", "")
                    state.socketWrites[#state.socketWrites + 1] = data
                end
                sock.read = function()
                    if sock.command == "status" then
                        readCallback(state.helperStatus .. "\n")
                    elseif sock.command == "show" then
                        state.helperStatus = "visible"
                        readCallback("ok\n")
                    elseif sock.command == "hide" then
                        state.helperStatus = "hidden"
                        readCallback("ok\n")
                    elseif sock.command == "quit" then
                        state.helperStatus = nil
                        readCallback("ok\n")
                    end
                end
                sock.disconnect = function() end
                return sock
            end,
        },
    }

    local chunk, err = loadfile(root .. "/hammerspoon/config/ipad_overlay.lua", "t", env)
    assert(chunk, err)
    return chunk(), state
end

local function retryTimerCount(module)
    for index = 1, 20 do
        local name, value = debug.getupvalue(module._sendCommand, index)
        if name == "retryTimers" then
            local count = 0
            for _ in pairs(value) do
                count = count + 1
            end
            return count
        end
    end
    error("retryTimers upvalue not found")
end

local function nextTimer(state, predicate)
    for _, timer in ipairs(state.timers) do
        if not timer.stopped and not timer.fired and predicate(timer.delay) then
            return timer
        end
    end
    return nil
end

local function fire(timer)
    assert(timer, "timer unavailable")
    timer.fired = true
    timer.fn()
end

local module, state = newHarness(nil)
assert(module.show and module.hide and module.isShown and module.toggle and module.onChange)
assert(module.isShown() == false)
assert(#state.taskLaunches == 0 and #state.socketWrites == 0)
assert(#state.execCalls == 1 and state.execCalls[1]:find("pgrep", 1, true))
assert(retryTimerCount(module) == 0)
print("✓ init has no lifecycle side effects")

module.toggle()
assert(module.isShown() == true)
assert(#state.taskLaunches == 1 and #state.socketWrites == 0)
assert(state.taskLaunches[1].cmd == "/bin/sh")
assert(state.taskLaunches[1].args[2]:find("--parent-pid 123", 1, true))
assert(state.taskLaunches[1].args[2]:find("--show", 1, true))
assert(state.helperStatus == "visible")
assert(retryTimerCount(module) == 0)
print("✓ manual show launches once, already showing, without timer leaks")

local launchesBefore = #state.taskLaunches
module.show()
assert(#state.taskLaunches == launchesBefore)
assert(state.socketWrites[#state.socketWrites] == "show\n")
assert(retryTimerCount(module) == 0)
print("✓ repeated show reuses the helper")

module.hide()
assert(module.isShown() == false)
assert(state.socketWrites[#state.socketWrites] == "hide\n")
assert(retryTimerCount(module) == 0)
print("✓ hide succeeds without timer leaks")

state.failConnects = 1
local writesBefore = #state.socketWrites
module.show()
local staleRetry = nextTimer(state, function(delay)
    return delay == 0.35
end)
assert(staleRetry)
module.hide()
assert(staleRetry.stopped)
fire(staleRetry)
assert(#state.socketWrites == writesBefore + 1)
assert(state.socketWrites[#state.socketWrites] == "hide\n")
assert(module.isShown() == false)
print("✓ hide invalidates a deferred show retry")

local callbackCalled = false
module.onChange(function()
    callbackCalled = true
end)
module.toggle()
assert(callbackCalled)
print("✓ onChange callbacks fire")

state.helperStatus = nil
local launches = #state.taskLaunches
module._on_helper_exit(1)
fire(nextTimer(state, function(delay)
    return delay <= 2
end))
assert(#state.taskLaunches == launches + 1)
assert(state.taskLaunches[#state.taskLaunches].args[2]:find("--show", 1, true))
assert(state.helperStatus == "visible")
print("✓ visible helper death respawns")

module.hide()
launches = #state.taskLaunches
state.helperStatus = nil
module._on_helper_exit(0)
assert(nextTimer(state, function(delay)
    return delay <= 2
end) == nil)
assert(#state.taskLaunches == launches)
print("✓ hidden helper death stays down")

module.show()
for _ = 1, 4 do
    state.helperStatus = nil
    module._on_helper_exit(1)
    local timer = nextTimer(state, function(delay)
        return delay <= 2
    end)
    if timer then
        fire(timer)
    end
end
assert(module.isShown() == false)
print("✓ exhausted crash loop clears visible")

-- Every load replays the iPad-connected action, so the last explicit
-- visibility has to survive a reload in both directions — and the helper
-- itself must be reloaded, never adopted with the previous incarnation's code.
local shownStore = {}
local beforeShown, beforeShownState = newHarness(nil, { settings = shownStore })
beforeShown.show()
assert(beforeShownState.helperStatus == "visible")

local reloadedShown, reloadedShownState = newHarness("visible", { settings = shownStore })
assert(reloadedShown.isShown() == true)
assert(#reloadedShownState.taskLaunches == 1)
assert(reloadedShownState.taskLaunches[1].args[2]:find("--show", 1, true))
assert(#reloadedShownState.socketWrites == 0)
assert(reloadedShownState.helperStatus == "visible")
print("✓ reload relaunches the helper of a shown overlay, already showing")

local hiddenStore = {}
local beforeHidden, beforeHiddenState = newHarness(nil, { settings = hiddenStore })
beforeHidden.show()
beforeHidden.hide()
assert(beforeHiddenState.helperStatus == "hidden")

local reloadedHidden, reloadedHiddenState = newHarness("hidden", { settings = hiddenStore })
assert(reloadedHidden.hasStoredVisibility() == true)
assert(reloadedHidden.isShown() == false)
assert(#reloadedHiddenState.taskLaunches == 0)
assert(reloadedHiddenState.socketWrites[#reloadedHiddenState.socketWrites] == "quit\n")
assert(reloadedHiddenState.helperStatus == nil)
print("✓ reload keeps a hidden overlay hidden and shuts its helper down")

local coldStart, coldStartState = newHarness("visible", { settings = shownStore, pid = 999 })
assert(coldStart.hasStoredVisibility() == false)
assert(coldStart.isShown() == false)
assert(#coldStartState.taskLaunches == 0)
assert(coldStartState.helperStatus == nil)
print("✓ a fresh Hammerspoon ignores the previous process's visibility")

print("All iPad overlay tests passed")
