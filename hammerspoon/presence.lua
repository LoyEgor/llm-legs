local M = {}

-- Away mark: once HID input has been idle AWAY_S, presence/away holds "<last input epoch>\t<written epoch>",
-- rewritten each minute; a WATCH_S watch drops it the moment input returns and kicks a limits refresh.
-- Readers (share/presence.sh, M.away) take a mark left unwritten for minutes as present. Egor's switch
-- (Auto ▸ Away Mode) is presence/away-off: while it exists no mark is written, so every consumer runs as present.
-- presence/last-away keeps "<left epoch>\t<back epoch>" of the last span a mark covered: the menu shows it as proof.
local AWAY_S, WATCH_S = 600, 2
local REFRESH_KICK = 'exec /bin/launchctl kickstart "gui/$(/usr/bin/id -u)/com.llm-refresh"'

local timer, watch, lastMinute
local listeners = {}

local function presenceDir()
  local base = os.getenv("SPEED_DOCTOR_DIR") or (os.getenv("HOME") .. "/.cache/speed-doctor")
  return base, base .. "/presence"
end

local function markPath()
  local _, dir = presenceDir()
  return dir .. "/away"
end

local function offPath()
  local _, dir = presenceDir()
  return dir .. "/away-off"
end

local function lastPath()
  local _, dir = presenceDir()
  return dir .. "/last-away"
end

local function notify()
  for _, fn in ipairs(listeners) do pcall(fn) end
end

-- fn() runs on every change of M.away() or M.enabled(): the menubar's ☾ follows it at once.
function M.subscribe(fn)
  listeners[#listeners + 1] = fn
end

function M.away()
  return watch ~= nil
end

function M.enabled()
  local handle = io.open(offPath())
  if handle then handle:close() end
  return handle == nil
end

-- M.lastAway(): left, back epochs of the last finished away span; nil before the first one.
function M.lastAway()
  local handle = io.open(lastPath())
  if not handle then return nil end
  local left, back = (handle:read("l") or ""):match("^(%d+)\t(%d+)$")
  handle:close()
  if left then return tonumber(left), tonumber(back) end
end

function M.back()
  local was = watch ~= nil
  if watch then watch:stop() end
  watch = nil
  local handle = io.open(markPath())
  local left = handle and (handle:read("l") or ""):match("^(%d+)\t")
  if handle then handle:close() end
  local removed = os.remove(markPath())
  if removed then
    local span = left and io.open(lastPath(), "w")
    if span then
      span:write(string.format("%s\t%d\n", left, math.floor(hs.timer.secondsSinceEpoch())))
      span:close()
    end
    local task = hs.task.new("/bin/sh", nil, { "-c", REFRESH_KICK })
    if task then task:start() end
  end
  if was or removed then notify() end
end

function M.setEnabled(on)
  if on then
    os.remove(offPath())
  else
    local base, dir = presenceDir()
    hs.fs.mkdir(base)
    hs.fs.mkdir(dir)
    local handle = io.open(offPath(), "w")
    if handle then handle:close() end
    M.back()
  end
  notify()
end

local function markAway(now, idle)
  local path = markPath()
  local handle = io.open(path .. ".tmp", "w")
  if not handle then return end
  handle:write(string.format("%d\t%d\n", math.floor(now - idle), math.floor(now)))
  handle:close()
  os.rename(path .. ".tmp", path)
  if not watch then
    watch = hs.timer.doEvery(WATCH_S, function()
      local ok, seconds = pcall(hs.host.idleTime)
      if ok and seconds and seconds < AWAY_S then M.back() end
    end)
    notify()
  end
end

function M.tick()
  local ok, err = pcall(function()
    local now = hs.timer.secondsSinceEpoch()
    local minute = math.floor(now / 60) * 60
    if minute == lastMinute then return end
    lastMinute = minute
    local idle = math.floor(hs.host.idleTime() or 0)
    local app = hs.application.frontmostApplication()
    local bundle = app and app:bundleID() or "-"
    local base, dir = presenceDir()
    local day = os.date("%Y-%m-%d", minute)
    local handle = io.open(dir .. "/" .. day .. ".tsv", "a")
    if not handle then
      hs.fs.mkdir(base)
      hs.fs.mkdir(dir)
      handle = io.open(dir .. "/" .. day .. ".tsv", "a")
    end
    if handle then
      handle:write(string.format("%d\t%d\t%s\n", minute, idle, bundle))
      handle:close()
    end
    if idle >= AWAY_S and M.enabled() then markAway(now, idle) else M.back() end
  end)
  if not ok then print("presence: tick failed: " .. tostring(err)) end
end

local function schedule()
  local now = hs.timer.secondsSinceEpoch()
  timer = hs.timer.doAfter(60 - now % 60 + 0.05, function()
    M.tick()
    schedule()
  end)
end

function M.start()
  M.stop()
  schedule()
  return M
end

function M.stop()
  if timer then timer:stop() end
  if watch then watch:stop() end
  timer, watch = nil, nil
end

return M
