local root = debug.getinfo(1, "S").source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local failures, checks = {}, 0
local function check(ok, message)
  checks = checks + 1
  if not ok then failures[#failures + 1] = message end
end

local timers, tasks, watchers = {}, {}, {}
local running = false
local LAUNCHED, TERMINATED = 1, 2
local fakeHs = {
  application = { watcher = {
    launched = LAUNCHED, terminated = TERMINATED,
    new = function(fn)
      local w = { fn = fn, started = false }
      function w:start() self.started = true; return self end
      function w:stop() self.started = false end
      watchers[#watchers + 1] = w
      return w
    end,
  } },
  timer = { doAfter = function(seconds, fn)
    local t = { seconds = seconds, fn = fn, stopped = false }
    function t:stop() self.stopped = true end
    timers[#timers + 1] = t
    return t
  end },
  task = { new = function(path, callback, args)
    local t = { path = path, callback = callback, args = args, started = false }
    function t:start() self.started = true; running = true; return self end
    function t:isRunning() return running end
    tasks[#tasks + 1] = t
    return t
  end },
}
local env = {}
local fakeOs = setmetatable({ getenv = function(name) return env[name] end }, { __index = os })
local printed = {}
local M = assert(loadfile(root .. "/hammerspoon/dia-flag-watch.lua", "t", setmetatable({ hs = fakeHs, os = fakeOs,
  print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end }, { __index = _G })))()

local function app(bundle) return { bundleID = function() return bundle end } end
local function fire()
  for _, t in ipairs(timers) do
    if not t.stopped and not t.fired then t.fired = true; t.fn() end
  end
end

M.start()
check(#watchers == 1 and watchers[1].started, "start runs one application watcher")
M.onEvent("Telegram", LAUNCHED, app("ru.keepcoder.Telegram"))
M.onEvent("Dia", TERMINATED, app("company.thebrowser.dia"))
fire()
check(#tasks == 0, "other apps and a Dia quit start nothing")

M.onEvent("Dia", LAUNCHED, app("company.thebrowser.dia"))
M.onEvent("Dia", LAUNCHED, app("company.thebrowser.dia"))
check(#timers == 2 and timers[1].stopped and not timers[2].stopped, "a second launch replaces the pending check")
check(timers[2].seconds == 3, "the check waits for Dia's process to settle")
fire()
check(#tasks == 1 and tasks[1].started, "a Dia launch runs one check")
check(tasks[1].path == root .. "/bin/dia-js", "the check is this repository's bin/dia-js")
check(tasks[1].args[1] == "--relaunch" and tasks[1].args[2] == "--auto" and #tasks[1].args == 2,
  "the check runs dia-js --relaunch --auto")

M.check()
check(#tasks == 1, "no second check while one runs")
running = false
tasks[1].callback(0, "", "")
check(#printed == 0, "a silent check logs nothing")
tasks[1].callback(1, "", "dia-js: Dia did not quit within 30s\n")
check(printed[1] == "dia-flag-watch: exit 1: dia-js: Dia did not quit within 30s", "a failed check is logged")

env.DIA_JS_BIN = "/stub/dia-js"
M.check()
check(tasks[2] and tasks[2].path == "/stub/dia-js", "DIA_JS_BIN overrides the path")

M.stop()
check(not watchers[1].started, "stop stops the watcher")

if #failures == 0 then
  return string.format("PASS: %d dia-flag-watch checks", checks)
end
return "FAIL: " .. table.concat(failures, "; ")
