-- Install with: require("llm-limits") from ~/.hammerspoon/init.lua.
local COLLECTOR = "/Volumes/Work/Projects/llm-legs/llm-limits.sh"

local module = {}
local menubar = hs.menubar.new()

local function vendorTitle(initial, vendor)
  if not vendor or not vendor.available then return initial .. "?/?" end
  return string.format("%s%s/%s", initial, vendor.five_hour.used_pct, vendor.weekly.used_pct)
end

local function detail(name, vendor)
  if not vendor.available then
    local wall = vendor.last_wall and ("; последний лимит: " .. vendor.last_wall) or ""
    return name .. ": " .. (vendor.status or "неизвестно") .. wall
  end
  return string.format("%s: %s%% / %s%%; сбросы %s / %s; данные %s сек. назад",
    name, vendor.five_hour.used_pct, vendor.weekly.used_pct,
    vendor.five_hour.resets_at, vendor.weekly.resets_at, vendor.stale_seconds)
end

local function render()
  local data = hs.json.read(os.getenv("HOME") .. "/.llm-limits.json")
  if not data or not data.vendors then
    menubar:setTitle("LLM ?")
    menubar:setTooltip("Данные лимитов недоступны")
    return
  end
  local v = data.vendors
  local warning = false
  for _, vendor in pairs(v) do
    if vendor.available and (vendor.five_hour.used_pct >= 80 or vendor.weekly.used_pct >= 80) then
      warning = true
    end
  end
  local title = vendorTitle("C", v.claude) .. " " .. vendorTitle("X", v.codex)
  menubar:setTitle((warning and "⚠ " or "") .. title)
  local lines = {detail("Claude", v.claude), detail("Codex", v.codex), detail("Gemini", v.gemini)}
  menubar:setTooltip(table.concat(lines, "\n"))
  menubar:setMenu({
    {title = lines[1], disabled = true},
    {title = lines[2], disabled = true},
    {title = lines[3], disabled = true},
    {title = "Обновить", fn = module.refresh},
  })
end

function module.refresh()
  hs.task.new(COLLECTOR, function() render() end, {"--json"}):start()
end

module.refresh()
if module.timer then module.timer:stop() end
module.timer = hs.timer.doEvery(300, module.refresh)
module.menubar = menubar
return module
