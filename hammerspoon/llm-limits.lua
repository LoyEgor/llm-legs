local M = {
  cachePath = os.getenv("HOME") .. "/.llm-limits.json",
  collectorPath = "/Volumes/Work/Projects/llm-legs/llm-limits.sh",
}

local menubar = nil
local timer = nil

local function infoTitle(text)
  return hs.styledtext.new(text, { font = { name = "Menlo", size = 13 } })
end

local function parseIsoTime(value)
  if type(value) ~= "string" then
    return nil
  end

  local year, month, day, hour, minute, second =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  local zone = value:match("Z$")
  local offsetHour, offsetMinute
  local sign, oh, om = value:match("([+-])(%d%d):?(%d%d)$")
  if sign then
    offsetHour = (sign == "-" and -1 or 1) * tonumber(oh)
    offsetMinute = (sign == "-" and -1 or 1) * tonumber(om)
  end

  if not year then
    return nil
  end

  local localEpoch = os.time({
    year = tonumber(year), month = tonumber(month), day = tonumber(day),
    hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second),
    isdst = nil,
  })

  if not localEpoch then
    return nil
  end

  if zone == "Z" or offsetHour ~= nil then
    local localOffset = os.difftime(
      os.time(os.date("*t", localEpoch)),
      os.time(os.date("!*t", localEpoch))
    )
    local sourceOffset = (offsetHour or 0) * 3600 + (offsetMinute or 0) * 60
    return localEpoch + localOffset - sourceOffset
  end

  return localEpoch
end

local function formatAge(value)
  local timestamp = parseIsoTime(value)
  if not timestamp then
    return "unknown"
  end

  local seconds = math.max(0, os.time() - timestamp)
  if seconds < 60 then
    return "just now"
  end

  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return string.format("%dm ago", minutes)
  end

  return string.format("%dh %dm ago", math.floor(minutes / 60), minutes % 60)
end

local function formatResetTime(value)
  local timestamp = parseIsoTime(value)
  if not timestamp then
    return "unknown"
  end

  if os.date("%Y-%m-%d", timestamp) == os.date("%Y-%m-%d") then
    return os.date("%H:%M", timestamp)
  end

  return os.date("%a %H:%M", timestamp)
end

local function readLlmLimits()
  local ok, result = pcall(function()
    local file = io.open(M.cachePath, "r")
    if not file then
      return nil
    end

    local contents = file:read("*a")
    file:close()
    local decoded = hs.json.decode(contents)
    if type(decoded) ~= "table" or decoded.schema ~= 1 then
      return nil
    end

    return decoded
  end)

  if ok then
    return result
  end

  return nil
end

local function getLlmLimitsData()
  local task = hs.task.new(M.collectorPath, function(exitCode, _, stdErr)
    if exitCode == 0 then
      hs.alert.show("LLM limits updated")
    else
      local message = stdErr and stdErr:match("^%s*(.-)%s*$") or ""
      hs.alert.show(message ~= "" and ("LLM limits error: " .. message) or "LLM limits error")
    end
  end)

  if not task or not task:start() then
    hs.alert.show("LLM limits error: could not start collector")
  end
end

function M.menuItems()
  local menu = {}
  local limits = readLlmLimits()
  if limits and type(limits.vendors) == "table" then
    local vendors = {
      { key = "claude", label = "Claude" },
      { key = "codex", label = "Codex" },
      { key = "gemini", label = "Gemini" },
    }

    for _, entry in ipairs(vendors) do
      local vendor = limits.vendors[entry.key]
      if type(vendor) ~= "table" or vendor.available ~= true then
        local detail = type(vendor) == "table" and vendor.status or "unknown"
        table.insert(menu, {
          title = infoTitle(string.format("%-6s    no data (%s)", entry.label, detail or "unknown")),
          disabled = true,
        })
      else
        local fiveHour = vendor.five_hour or {}
        local weekly = vendor.weekly or {}
        local warning = (tonumber(fiveHour.used_pct) or 0) >= 80
          or (tonumber(weekly.used_pct) or 0) >= 80
        local marker = warning and "⚠" or ""
        local fiveHourPct = math.floor((tonumber(fiveHour.used_pct) or 0) + 0.5)
        local weeklyPct = math.floor((tonumber(weekly.used_pct) or 0) + 0.5)
        table.insert(menu, {
          title = infoTitle(string.format("%-6s %-2s 5h %3d%%  → %s", entry.label, marker,
            fiveHourPct, formatResetTime(fiveHour.resets_at))),
          disabled = true,
        })
        table.insert(menu, {
          title = infoTitle(string.format("%-6s %-2s wk %3d%%  → %s", entry.label, marker,
            weeklyPct, formatResetTime(weekly.resets_at))),
          disabled = true,
        })

        local staleSeconds = tonumber(vendor.stale_seconds)
        if not staleSeconds and vendor.as_of then
          local asOf = parseIsoTime(vendor.as_of)
          staleSeconds = asOf and math.max(0, os.time() - asOf) or nil
        end
        if staleSeconds and staleSeconds > 600 then
          table.insert(menu, {
            title = infoTitle("         updated " .. formatAge(vendor.as_of)),
            disabled = true,
          })
        end
      end
    end

    table.insert(menu, { title = "-" })
    table.insert(menu, {
      title = infoTitle("Data fetched: " .. formatAge(limits.fetched_at)),
      disabled = true,
    })
    table.insert(menu, { title = "Get Data", fn = getLlmLimitsData })
  else
    table.insert(menu, {
      title = infoTitle("no data — press Get Data"),
      disabled = true,
    })
    table.insert(menu, { title = "Get Data", fn = getLlmLimitsData })
  end

  return menu
end

local function vendorTitle(initial, vendor)
  if not vendor or not vendor.available then
    return initial .. "?/?"
  end
  return string.format("%s%s/%s", initial, vendor.five_hour.used_pct, vendor.weekly.used_pct)
end

local function detail(name, vendor)
  if not vendor or not vendor.available then
    local wall = vendor and vendor.last_wall and ("; last limit: " .. vendor.last_wall) or ""
    return name .. ": " .. (vendor and vendor.status or "unknown") .. wall
  end
  return string.format("%s: %s%% / %s%%; resets %s / %s; data %s sec ago",
    name, vendor.five_hour.used_pct, vendor.weekly.used_pct,
    vendor.five_hour.resets_at, vendor.weekly.resets_at, vendor.stale_seconds)
end

local function renderMenubar()
  if not menubar then
    return
  end

  local data = readLlmLimits()
  if not data or not data.vendors then
    menubar:setTitle("LLM ?")
    menubar:setTooltip("Limit data unavailable")
    return
  end

  local vendors = data.vendors
  local warning = false
  for _, vendor in pairs(vendors) do
    if vendor.available and (vendor.five_hour.used_pct >= 80 or vendor.weekly.used_pct >= 80) then
      warning = true
    end
  end

  local title = vendorTitle("C", vendors.claude) .. " " .. vendorTitle("X", vendors.codex)
  local lines = {
    detail("Claude", vendors.claude),
    detail("Codex", vendors.codex),
    detail("Gemini", vendors.gemini),
  }
  menubar:setTitle((warning and "⚠ " or "") .. title)
  menubar:setTooltip(table.concat(lines, "\n"))
  menubar:setMenu({
    { title = lines[1], disabled = true },
    { title = lines[2], disabled = true },
    { title = lines[3], disabled = true },
    { title = "Refresh", fn = M.refresh },
  })
end

function M.refresh()
  local task = hs.task.new(M.collectorPath, function()
    renderMenubar()
  end, { "--json" })
  if task then
    task:start()
  end
end

function M.startMenubar()
  if menubar then
    return menubar
  end

  menubar = hs.menubar.new()
  M.refresh()
  if timer then
    timer:stop()
  end
  timer = hs.timer.doEvery(300, M.refresh)
  M.menubar = menubar
  M.timer = timer
  return menubar
end

function M.stopMenubar()
  if timer then
    timer:stop()
    timer = nil
  end
  if menubar then
    menubar:delete()
    menubar = nil
  end
  M.timer = nil
  M.menubar = nil
end

return M
