local root = debug.getinfo(1, "S").source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local failures, checks = {}, 0
local function check(ok, message)
  checks = checks + 1
  if not ok then failures[#failures + 1] = message end
end

local base = os.tmpname()
os.remove(base)
assert(hs.fs.mkdir(base))
local dir = base .. "/presence"

local clock = hs.timer.secondsSinceEpoch
local now, idle, bundle, envDir = 0, 0, nil, base
local windowTouched, appTouched, logged = {}, {}, {}

local function fakeApp()
  if not bundle then return nil end
  return setmetatable({ bundleID = function() return bundle end },
    { __index = function(_, key) appTouched[#appTouched + 1] = key end })
end

local fakeHs = {
  fs = hs.fs,
  timer = {
    secondsSinceEpoch = function() return now end,
  },
  host = { idleTime = function() return idle end },
  application = { frontmostApplication = fakeApp },
  window = setmetatable({}, { __index = function(_, key) windowTouched[#windowTouched + 1] = key end }),
}
local fakeOs = setmetatable({ getenv = function(name)
  if name == "SPEED_DOCTOR_DIR" then return envDir end
  return os.getenv(name)
end }, { __index = os })

local function load(hsTable)
  return assert(loadfile(root .. "/hammerspoon/presence.lua", "t", setmetatable({ hs = hsTable or fakeHs, os = fakeOs,
    print = function(...) logged[#logged + 1] = table.concat({ ... }, " ") end }, { __index = _G })))()
end
local function read(path)
  local handle = io.open(path)
  if not handle then return nil end
  local body = handle:read("a")
  handle:close()
  return body
end
local function day(epoch) return os.date("%Y-%m-%d", epoch) end

local t0 = os.time({ year = 2026, month = 10, day = 3, hour = 14, min = 7, sec = 0 })

-- Line shape and the nil frontmost app.
local presence = load()
now, idle, bundle = t0 + 42.7, 12.9, "com.apple.Terminal"
presence.tick()
now, idle, bundle = t0 + 60 + 3, 0.2, nil
presence.tick()
local body = read(dir .. "/" .. day(t0) .. ".tsv") or ""
check(body == string.format("%d\t12\tcom.apple.Terminal\n%d\t0\t-\n", t0, t0 + 60), "line shape: «" .. body .. "»")
now = t0 + 60 + 50
presence.tick()
check(read(dir .. "/" .. day(t0) .. ".tsv") == body, "a second tick in one minute wrote another line")
check(#windowTouched == 0, "hs.window was touched: " .. table.concat(windowTouched, ","))
check(#appTouched == 0, "the frontmost app was asked for more than its bundle id: " .. table.concat(appTouched, ","))

-- Minute alignment of the timer.
os.execute("rm -rf '" .. dir .. "'")
presence = load()
local armed = {}
fakeHs.timer.doAfter = function(delay, fn)
  armed[#armed + 1] = { delay = delay, fn = fn }
  return { stop = function() end }
end
now, idle, bundle = t0 + 40.3, 1, "com.apple.Terminal"
presence.start()
local first = armed[1] and armed[1].delay or -1
check(#armed == 1 and first > 0 and (now + first) % 60 < 0.5, "first delay off the minute: " .. first)
now = now + first
armed[1].fn()
local second = armed[2] and armed[2].delay or -1
check(second > 59 and (now + second) % 60 < 0.5, "re-armed delay off the minute: " .. second)
check(read(dir .. "/" .. day(t0) .. ".tsv") == string.format("%d\t1\tcom.apple.Terminal\n", t0 + 60),
  "the aligned tick did not write its minute")
presence.stop()

-- Pruning is bin/speed-doctor's prune_journals alone: the writer deletes nothing.
os.execute("rm -rf '" .. dir .. "'")
assert(hs.fs.mkdir(dir))
local function touch(name) local h = assert(io.open(dir .. "/" .. name, "w")); h:write("x\n"); h:close() end
local today = t0 + 12 * 3600
touch(day(today - 40 * 86400) .. ".tsv")
presence = load()
now, idle, bundle = today, 5, "com.apple.Safari"
presence.tick()
now = today + 86400
presence.tick()
check(read(dir .. "/" .. day(today - 40 * 86400) .. ".tsv") ~= nil, "the writer pruned a day file")

-- A write failure and a raising API never raise.
local blocker = base .. "/blocker"
touch("../blocker")
envDir = blocker
presence = load()
now = today + 2 * 86400
logged = {}
check(pcall(presence.tick), "a write failure raised")
check(#logged == 0, "a write failure was logged as a failed tick: " .. table.concat(logged, "; "))
check(read(blocker .. "/presence/" .. day(now) .. ".tsv") == nil, "a write landed under a file")
envDir = base
fakeHs.host.idleTime = function() error("no idle") end
presence = load()
now = now + 60
logged = {}
check(pcall(presence.tick), "a raising idleTime raised")
check(#logged == 1, "a failed tick was not logged once")
fakeHs.host.idleTime = function() return idle end

-- Away mark: written while idle >= 10 min, dropped by the 2 s watch on return with one refresh kick.
local every, kicks = {}, {}
fakeHs.timer.doEvery = function(delay, fn)
  local entry = { delay = delay, fn = fn, stopped = false }
  every[#every + 1] = entry
  return { stop = function() entry.stopped = true end }
end
fakeHs.task = { new = function(path, _, args)
  return { start = function() kicks[#kicks + 1] = path .. " " .. table.concat(args, " ") return true end }
end }
local mark = dir .. "/away"
presence = load()
now, idle = today + 5 * 86400, 900
presence.tick()
check(read(mark) == string.format("%d\t%d\n", now - 900, now), "away mark: «" .. tostring(read(mark)) .. "»")
check(presence.away() and #every == 1 and every[1].delay == 2, "no 2 s return watch armed")
now, idle = now + 60, 960
presence.tick()
check(read(mark) == string.format("%d\t%d\n", now - 960, now) and #every == 1,
  "the next away minute did not rewrite the mark alone")
idle = 3
every[1].fn()
check(read(mark) == nil and not presence.away() and every[1].stopped, "his return left the mark or the watch")
check(#kicks == 1 and kicks[1]:find("kickstart", 1, true) and kicks[1]:find("/com.llm-refresh", 1, true),
  "his return kicked: " .. table.concat(kicks, "; "))
local left, back = presence.lastAway()
check(left == now - 960 and back == now, "his return did not keep the span: " .. tostring(left) .. " " .. tostring(back))
now = now + 60
presence.tick()
check(#kicks == 1, "a present minute with no mark kicked a refresh")
-- A Hammerspoon reload while away keeps the mark; the first present minute drops it.
local held = assert(io.open(mark, "w"))
held:write("1\t2\n")
held:close()
presence = load()
now, idle = now + 60, 4
presence.tick()
check(read(mark) == nil and #kicks == 2, "a mark left over a reload outlived his return")

-- Egor's switch: off drops the mark at once and writes none; on lets the next away minute mark again.
-- Every change reaches a subscriber.
local changes = 0
presence.subscribe(function() changes = changes + 1 end)
now, idle = now + 60, 900
presence.tick()
check(presence.away() and changes == 1, "going away did not reach the subscriber once")
presence.setEnabled(false)
check(not presence.enabled() and not presence.away() and read(mark) == nil and read(dir .. "/away-off") ~= nil,
  "switching off left the mark or no switch file")
check(changes == 3, "switching off while away did not report the return and the switch: " .. changes)
now = now + 60
presence.tick()
check(read(mark) == nil and not presence.away(), "an away minute wrote a mark while switched off")
presence.setEnabled(true)
check(presence.enabled() and read(dir .. "/away-off") == nil, "switching on left the switch file")
now = now + 60
presence.tick()
check(presence.away() and read(mark) ~= nil and changes == 5, "switched on, the next away minute did not mark")
presence.back()

-- His click on Auto ▸ Away Mode: away at once; input in its first 30 s keeps it, input later ends it.
;(function()
  now, idle = now + 60, 0
  local clicked = now
  presence.goAway()
  check(presence.away() and read(mark) == string.format("%d\t%d\n", clicked, clicked),
    "a click did not mark away at once: «" .. tostring(read(mark)) .. "»")
  local returnWatch = every[#every]
  now, idle = clicked + 20, 5
  returnWatch.fn()
  check(presence.away(), "input inside the grace ended the click's away")
  now, idle = clicked + 60, 45
  presence.tick()
  check(presence.away() and read(mark) == string.format("%d\t%d\n", clicked, now),
    "the minute after a click dropped or moved the mark: «" .. tostring(read(mark)) .. "»")
  now, idle = clicked + 90, 1
  returnWatch.fn()
  check(not presence.away() and read(mark) == nil, "input after the grace kept the click's away")
  local left, back = presence.lastAway()
  check(left == clicked and back == now, "the click's span was not kept: " .. tostring(left) .. " " .. tostring(back))
  presence.setEnabled(false)
  presence.goAway()
  check(not presence.away() and read(mark) == nil, "a click marked away while the mode is off")
  presence.setEnabled(true)
end)()

-- Tick cost: fixture files, the real idle and frontmost APIs (read-only).
local realHs = { fs = hs.fs, host = hs.host, application = hs.application, window = fakeHs.window,
  task = fakeHs.task, timer = { secondsSinceEpoch = function() return now end, doEvery = fakeHs.timer.doEvery } }
presence = load(realHs)
local runs, worst, total, spent = 200, 0, 0, {}
for i = 1, runs do
  now = today + 3 * 86400 + i * 60
  local start = clock()
  presence.tick()
  spent[i] = (clock() - start) * 1000
  total, worst = total + spent[i], math.max(worst, spent[i])
end
table.sort(spent)
local p50 = spent[runs // 2]
check(p50 < 5, string.format("a tick's median took %.2f ms", p50))
check(#windowTouched == 0, "hs.window was touched by the real tick")

os.execute("rm -rf '" .. base .. "'")
local cost = string.format(" (tick p50 %.3f ms, mean %.3f ms, max %.3f ms over %d)", p50, total / runs, worst, runs)
if #failures > 0 then return "FAIL: " .. table.concat(failures, "; ") .. cost end
return "PASS: " .. checks .. " presence checks" .. cost
