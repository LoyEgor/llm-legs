-- Wake/boot trigger for `claudeb token-upkeep`; the why lives on that subcommand.
local M = {}

local THROTTLE_SECONDS = 600
local WAKE_DELAY_SECONDS = 15
local lastRunAt = 0

-- Pure epoch guard so the throttle can be tested without a live clock or hs.
function M.shouldRun(now, last)
  return type(now) == "number" and (now - (last or 0)) >= THROTTLE_SECONDS
end

local function claudebPath()
  return os.getenv("HOME") .. "/.local/bin/claudeb"
end

local function baseEnvironment()
  local home = os.getenv("HOME")
  return {
    HOME = home,
    PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" .. home .. "/.local/bin:/usr/sbin",
  }
end

local function runUpkeep()
  local now = os.time()
  if not M.shouldRun(now, lastRunAt) then return end
  lastRunAt = now
  local task = hs.task.new(claudebPath(), nil, { "token-upkeep" })
  if not task then return end
  task:setEnvironment(baseEnvironment())
  task:start()
end

-- Network needs a moment to come back after wake, so defer the actual run.
local function scheduleUpkeep()
  M.pendingTimer = hs.timer.doAfter(WAKE_DELAY_SECONDS, runUpkeep)
end

-- A local watcher is garbage-collected and silently stops firing; keep the
-- reference at module scope.
M.wakeWatcher = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemDidWake then
    scheduleUpkeep()
  end
end)
if M.wakeWatcher then M.wakeWatcher:start() end

-- An always-on Mac never fires systemDidWake — without this, all tokens expire
-- overnight and the next refresh herds the token endpoint.
M.periodicTimer = hs.timer.doEvery(1800, runUpkeep)

scheduleUpkeep()

_G.TokenUpkeep = M
return M
