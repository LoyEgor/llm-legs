-- A Dia started by a link click while closed, or by a Sparkle update relaunch, runs without
-- --enable-applescript-javascript; on each Dia launch this hands the check and the relaunch to
-- `bin/dia-js --relaunch --auto`, which holds the off switch and the once-per-2-min guard.
local M = {}

local DIA_ID = "company.thebrowser.dia"
local watcher, pending, task
local logged = {}

local function diaJs()
  local source = debug.getinfo(1, "S").source:match("^@(.+)/hammerspoon/[^/]+$")
  return (os.getenv("DIA_JS_BIN") or (source and source .. "/bin/dia-js"))
end

function M.check()
  local path = diaJs()
  if not path or (task and task:isRunning()) then return end
  task = hs.task.new(path, function(code, out, err)
    local text = ((out or "") .. (err or "")):gsub("%s+$", "")
    if code ~= 0 or text ~= "" then
      logged[#logged + 1] = text
      print("dia-flag-watch: exit " .. tostring(code) .. (text ~= "" and (": " .. text) or ""))
    end
  end, { "--relaunch", "--auto" })
  task:start()
end

function M.onEvent(_, event, app)
  if event ~= hs.application.watcher.launched or not app or app:bundleID() ~= DIA_ID then return end
  if pending then pending:stop() end
  pending = hs.timer.doAfter(tonumber(os.getenv("DIA_FLAG_WATCH_DELAY_S") or "") or 3, function()
    pending = nil
    M.check()
  end)
end

function M.start()
  M.stop()
  watcher = hs.application.watcher.new(M.onEvent)
  watcher:start()
  return M
end

function M.stop()
  if watcher then watcher:stop() end
  if pending then pending:stop() end
  watcher, pending = nil, nil
end

function M.log() return logged end

return M
