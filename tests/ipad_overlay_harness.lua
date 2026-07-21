local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local env = setmetatable({}, { __index = _G })
env._G = env

local task_launches = {}
local task_exit_callbacks = {}
local socket_writes = {}

env.hs = {
    timer = {
        -- Immediate execution keeps the harness synchronous; retry paths
        -- never trigger because the socket mock always connects.
        doAfter = function(delay, fn)
            fn()
            return { stop = function(self) end }
        end,
    },
    settings = {
        storage = {},
        get = function(key)
            return env.hs.settings.storage[key]
        end,
        set = function(key, value)
            env.hs.settings.storage[key] = value
        end,
    },
    task = {
        new = function(cmd, exit_callback, args)
            local t = {
                _cmd = cmd,
                _args = args,
                start = function(self)
                    table.insert(task_launches, { cmd = cmd, args = args })
                    table.insert(task_exit_callbacks, exit_callback)
                    return true
                end,
            }
            return t
        end,
    },
    socket = {
        new = function(readCallback)
            local sock = { _readCallback = readCallback }
            sock.connect = function(self, path, fn)
                sock._path = path
                fn()
                return true
            end
            sock.write = function(self, data)
                table.insert(socket_writes, data)
            end
            sock.read = function(self, delim)
                sock._readCallback("ok\n")
            end
            sock.disconnect = function(self) end
            return sock
        end,
    },
}

env._G.IpadMode = {
    _isOn = false,
    isOn = function() return env._G.IpadMode._isOn end,
    onChange = function(fn) env._G.IpadMode._hook = fn end,
}

local chunk, err = loadfile(root .. "/hammerspoon/config/ipad_overlay.lua", "t", env)
assert(chunk, err)
local module = chunk()

assert(module.show and module.hide and module.isEnabled and module.setEnabled
    and module.recompute and module.onChange, "module misses required functions")
print("✓ Module has required functions")

assert(module.isEnabled() == true, "isEnabled is the user flag, true by default")
assert(env.hs.settings.get("ipadOverlay.enabled") == true, "enabled flag persisted on first run")
print("✓ isEnabled defaults correct")

module.show()
assert(#task_launches == 0, "show must not spawn while IpadMode is off")
print("✓ show() is a no-op while IpadMode is off")

env._G.IpadMode._isOn = true
env._G.IpadMode._hook()
assert(#task_launches == 1, "iPad-mode change must spawn the helper")
assert(task_launches[1].cmd:match("python"), "helper runs under the venv python")
assert(socket_writes[#socket_writes] == "show\n", "spawn must be followed by a show command")
print("✓ iPad mode on spawns helper and shows")

local launches_before = #task_launches
socket_writes = {}
module.show()
assert(#task_launches == launches_before, "second show must not respawn")
assert(socket_writes[#socket_writes] == "show\n", "second show still sends the command")
print("✓ show() does not respawn on second call")

socket_writes = {}
module.hide()
assert(socket_writes[#socket_writes] == "hide\n", "hide must send hide command")
print("✓ hide() sends command correctly")

module.setEnabled(false)
assert(env.hs.settings.get("ipadOverlay.enabled") == false, "setEnabled persists the flag")
assert(module.isEnabled() == false, "isEnabled reflects setEnabled")
socket_writes = {}
module.show()
assert(socket_writes[#socket_writes] == nil, "show is a no-op while the user flag is off")
module.setEnabled(true)
assert(module.isEnabled() == true, "isEnabled reflects setEnabled back on")
print("✓ Settings persistence works")

local callback_called = false
module.onChange(function() callback_called = true end)
module.setEnabled(true)
assert(callback_called, "onChange callback should fire on setEnabled")
print("✓ onChange callbacks fire")

-- Unexpected death while visible: exit callback must relaunch (timers run
-- synchronously in this harness).
module.show()
local launches = #task_launches
socket_writes = {}
task_exit_callbacks[#task_exit_callbacks](1)
assert(#task_launches == launches + 1, "helper death while visible must relaunch")
assert(socket_writes[#socket_writes] == "show\n", "relaunch must re-show")
print("✓ helper death while visible respawns")

-- Death while hidden must NOT relaunch.
module.hide()
launches = #task_launches
task_exit_callbacks[#task_exit_callbacks](0)
assert(#task_launches == launches, "helper death while hidden must not relaunch")
print("✓ helper death while hidden stays down")

env._G.IpadMode._isOn = false
socket_writes = {}
module.recompute()
assert(socket_writes[#socket_writes] == nil or socket_writes[#socket_writes] == "hide\n",
    "recompute with mode off hides")
print("✓ recompute() respects IpadMode changes")

print("All iPad overlay tests passed")
