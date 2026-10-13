local M = {}

-- Away mark: once HID input has been idle AWAY_S, presence/away holds "<last input epoch>\t<written epoch>",
-- rewritten each minute; a WATCH_S watch drops it the moment input returns and kicks a limits refresh.
-- Readers (share/presence.sh, M.away) take a mark left unwritten for minutes as present.
local AWAY_S, WATCH_S = 600, 2
local REFRESH_KICK = 'exec /bin/launchctl kickstart "gui/$(/usr/bin/id -u)/com.llm-refresh"'

local timer, watch, lastMinute

local function presenceDir()
  local base = os.getenv("SPEED_DOCTOR_DIR") or (os.getenv("HOME") .. "/.cache/speed-doctor")
  return base, base .. "/presence"
end

local function markPath()
  local _, dir = presenceDir()
  return dir .. "/away"
end

function M.away()
  return watch ~= nil
end

function M.back()
  if watch then watch:stop() end
  watch = nil
  if os.remove(markPath()) then
    local task = hs.task.new("/bin/sh", nil, { "-c", REFRESH_KICK })
    if task then task:start() end
  end
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
    if idle >= AWAY_S then markAway(now, idle) else M.back() end
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
