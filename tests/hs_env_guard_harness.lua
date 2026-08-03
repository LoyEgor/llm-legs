local source = debug.getinfo(1, "S").source
local root = source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local guardFile = assert(io.open(root .. "/hammerspoon/config/env_guard.lua", "r"))
local guardSource = guardFile:read("a")
guardFile:close()

local NOW = 1700000000

-- opts: dscl, home, launchdOwns, markerAge (seconds; nil = no marker), logSize,
-- markerUnwritable.
local function run(opts)
  opts = opts or {}
  local dscl = opts.dscl or "/Users/tester\n"
  local realHome = dscl:gsub("%s+$", "")
  local marker = realHome .. "/.hammerspoon-env-relaunch"
  local launchdLog = realHome .. "/Library/Logs/com.egor.hammerspoon.log"

  local result = {
    realHome = realHome,
    marker = marker,
    launchdLog = launchdLog,
    exec = {},
    removed = {},
    alerts = {},
    prints = {},
    opened = {},
    closed = 0,
  }

  local env = {
    tostring = tostring,
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
      result.prints[#result.prints + 1] = table.concat(parts, "\t")
    end,
  }
  env.hs = {
    execute = function(command)
      result.exec[#result.exec + 1] = command
      if command:find("dscl", 1, true) then return dscl, true end
      if command:find("launchctl print", 1, true) then
        return "", opts.launchdOwns or nil
      end
      return "", true
    end,
    fs = {
      attributes = function(path)
        if path == marker and opts.markerAge then
          return { modification = NOW - opts.markerAge }
        end
        if path == launchdLog and opts.logSize then return { size = opts.logSize } end
        return nil
      end,
    },
    alert = {
      show = function(message, duration)
        result.alerts[#result.alerts + 1] = { message = message, duration = duration }
      end,
    },
  }
  env.os = {
    getenv = function(name) return name == "HOME" and opts.home or nil end,
    remove = function(path) result.removed[#result.removed + 1] = path; return true end,
    time = function() return NOW end,
    exit = function() error("EXIT_SENTINEL", 0) end,
  }
  env.io = {
    open = function(path, mode)
      result.opened[#result.opened + 1] = { path = path, mode = mode }
      if opts.markerUnwritable and path == marker then return nil end
      return { close = function() result.closed = result.closed + 1 end }
    end,
  }

  local chunk, err = load(guardSource, "@env_guard.lua", "t", env)
  assert(chunk, err)
  result.ok, result.err = pcall(chunk)
  return result
end

local function printed(result, needle)
  for _, line in ipairs(result.prints) do
    if line:find(needle, 1, true) then return line end
  end
  return nil
end

local function execMatching(result, needle)
  for _, command in ipairs(result.exec) do
    if command:find(needle, 1, true) then return command end
  end
  return nil
end

local function openedWith(result, path, mode)
  for _, call in ipairs(result.opened) do
    if call.path == path and call.mode == mode then return true end
  end
  return false
end

local function assertExited(result, label)
  assert(not result.ok, label .. ": the chunk returned instead of exiting")
  assert(tostring(result.err):find("EXIT_SENTINEL", 1, true),
    label .. ": exit did not raise the sentinel (" .. tostring(result.err) .. ")")
end

local function assertNoExit(result, label)
  assert(result.ok, label .. ": the chunk raised " .. tostring(result.err))
end

local noHome = run({ dscl = "\n", home = "/Users/tester" })
assertNoExit(noHome, "silent dscl")
assert(printed(noHome, "env guard disabled"), "a silent dscl did not warn that the guard is off")
assert(#noHome.exec == 1, "a silent dscl kept shelling out")
assert(#noHome.removed == 0 and #noHome.opened == 0 and #noHome.alerts == 0,
  "a silent dscl touched the marker, the log or the alert")

local clean = run({ home = "/Users/tester" })
assertNoExit(clean, "clean start")
assert(#clean.removed == 1 and clean.removed[1] == "/Users/tester/.hammerspoon-env-relaunch",
  "a clean start did not clear the relaunch marker")
assert(not clean.removed[1]:find("\n", 1, true), "the dscl trailing newline reached the marker path")
assert(#clean.exec == 1, "a clean start ran a relaunch or a launchctl probe")
assert(#clean.opened == 0, "a clean start truncated an absent log")

local bigLog = run({ home = "/Users/tester", logSize = 5 * 1024 * 1024 + 1 })
assertNoExit(bigLog, "oversized log")
assert(openedWith(bigLog, bigLog.launchdLog, "w"), "an oversized launchd log was not truncated")
assert(bigLog.closed == 1, "the truncated log handle was left open")
local atLimitLog = run({ home = "/Users/tester", logSize = 5 * 1024 * 1024 })
assertNoExit(atLimitLog, "log at the cap")
assert(#atLimitLog.opened == 0, "a log at the 5MB cap was truncated")

local looping = run({ home = "/Users/poison", markerAge = 5 })
assertNoExit(looping, "fresh marker")
assert(#looping.alerts == 1, "a failed relaunch did not alert")
assert(#looping.exec == 1, "a failed relaunch probed launchd or relaunched again")
assert(#looping.opened == 0, "a failed relaunch rewrote the marker")

local unwritable = run({ home = "/Users/poison", markerUnwritable = true })
assertNoExit(unwritable, "unwritable marker")
assert(#unwritable.alerts == 1, "an unwritable marker did not alert")
assert(#unwritable.exec == 1, "an unwritable marker relaunched anyway")

local launchd = run({ home = "/Users/poison", markerAge = 300, launchdOwns = true })
assertExited(launchd, "launchd-owned relaunch")
assert(openedWith(launchd, launchd.marker, "w"), "the relaunch marker was not written")
assert(execMatching(launchd, "launchctl print"), "launchd ownership was not probed")
assert(not execMatching(launchd, "nohup"), "a launchd-owned relaunch also spawned nohup")
assert(not execMatching(launchd, "open -a"), "a launchd-owned relaunch also spawned open -a")
assert(#launchd.alerts == 0, "a launchd-owned relaunch alerted")

local function shellCheck(command, label)
  local path = os.tmpname()
  local file = assert(io.open(path, "w"))
  file:write(command, "\n")
  file:close()
  local ok = os.execute("/bin/sh -n '" .. path .. "' >/dev/null 2>&1")
  os.remove(path)
  assert(ok, label .. ": the relaunch command is not valid shell: " .. command)
end

local function plainReplace(text, needle, replacement)
  local from, to = text:find(needle, 1, true)
  assert(from, "the relaunch command lost " .. needle)
  return text:sub(1, from - 1) .. replacement .. text:sub(to + 1)
end

-- `sh -n` accepts a mangled home that merely reparses (an unescaped quote pairs
-- with the next one), so run the command with the launch swapped for a probe and
-- read back the HOME the shell actually built.
local function relaunchHome(command, label)
  local probe = plainReplace(command, "/usr/bin/nohup ", "")
  probe = plainReplace(probe, "/bin/sleep 3; ", "")
  probe = plainReplace(probe, "/usr/bin/open -a Hammerspoon", "/usr/bin/printenv HOME")
  probe = plainReplace(probe, " >/dev/null 2>&1 &", "")
  assert(not probe:find("open -a", 1, true) and not probe:find("nohup", 1, true),
    label .. ": the probe would still launch Hammerspoon")
  local pipe = assert(io.popen(probe))
  local output = pipe:read("a") or ""
  pipe:close()
  local trimmed = output:gsub("%s+$", "")
  return trimmed
end

for _, case in ipairs({
  { label = "plain home", dscl = "/Users/tester\n" },
  { label = "single-quoted home", dscl = "/Users/o'brian\n" },
  { label = "double-quoted home with a space", dscl = "/Users/o\"b rian\n" },
}) do
  local standalone = run({ dscl = case.dscl, home = "/Users/poison" })
  assertExited(standalone, case.label)
  local relaunch = execMatching(standalone, "/usr/bin/nohup /bin/sh -c '")
  assert(relaunch, case.label .. ": no nohup relaunch was issued")
  assert(relaunch:find("/usr/bin/env -i HOME=", 1, true),
    case.label .. ": the relaunch did not scrub the environment")
  shellCheck(relaunch, case.label)
  assert(relaunchHome(relaunch, case.label) == standalone.realHome,
    case.label .. ": the relaunch would export a mangled HOME (" .. relaunch .. ")")
end

print("All Hammerspoon env guard tests passed")
