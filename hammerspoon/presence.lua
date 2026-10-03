local M = {}

local timer, lastMinute

local function presenceDir()
  local base = os.getenv("SPEED_DOCTOR_DIR") or (os.getenv("HOME") .. "/.cache/speed-doctor")
  return base, base .. "/presence"
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
  timer = nil
end

return M
