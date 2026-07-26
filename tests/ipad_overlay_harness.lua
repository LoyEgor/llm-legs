local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local function newHarness(helperStatus)
    local state = {
        execCalls = {},
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
            return "", true, "exit", 0
        end,
        processInfo = {
            processID = 123,
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
                        state.helperStatus = "hidden"
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
assert(#state.taskLaunches == 0 and #state.execCalls == 0)
assert(retryTimerCount(module) == 0)
print("✓ init has no lifecycle side effects")

module.toggle()
assert(module.isShown() == true)
assert(#state.taskLaunches == 1 and #state.execCalls == 0)
assert(state.taskLaunches[1].cmd == "/bin/sh")
assert(state.taskLaunches[1].args[2]:find("--parent-pid 123", 1, true))
assert(state.socketWrites[#state.socketWrites] == "show\n")
assert(retryTimerCount(module) == 0)
print("✓ manual show launches once without timer leaks")

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
assert(state.socketWrites[#state.socketWrites] == "show\n")
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

local attachedModule, attachedState = newHarness("visible")
assert(attachedModule.isShown() == true)
assert(#attachedState.taskLaunches == 0 and #attachedState.execCalls == 0)
assert(attachedState.socketWrites[1] == "status\n")
assert(retryTimerCount(attachedModule) == 0)
print("✓ init re-attaches to a visible helper without restart")

print("All iPad overlay tests passed")
