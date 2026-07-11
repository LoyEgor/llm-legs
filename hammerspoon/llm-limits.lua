local M = {
  cachePath = os.getenv("HOME") .. "/.llm-limits.json",
  collectorPath = "/Volumes/Work/Projects/llm-legs/llm-limits.sh",
  wallsLog = nil,
}

local function infoTitle(text, warning)
  local attributes = { font = { name = "Menlo", size = 13 } }
  if warning then
    attributes.color = { red = 0.9, green = 0.25, blue = 0.2 }
  end
  return hs.styledtext.new(text, attributes)
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
    -- os.date("!*t") drops the DST flag; without copying it back os.time()
    -- interprets the UTC table as standard time and the offset loses an hour.
    local localTable = os.date("*t", localEpoch)
    local utcTable = os.date("!*t", localEpoch)
    utcTable.isdst = localTable.isdst
    local localOffset = os.difftime(os.time(localTable), os.time(utcTable))
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

local function newCollectorTask(callback)
  local task = hs.task.new(M.collectorPath, callback, {})
  if task and M.wallsLog then
    task:setEnvironment({
      HOME = os.getenv("HOME"),
      LLM_LIMITS_WALLS_LOG = M.wallsLog,
      PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
    })
  end
  return task
end

local function getLlmLimitsData()
  local ok, err = pcall(function()
    local task = newCollectorTask(function(exitCode, _, stdErr)
      if exitCode == 0 then
        hs.alert.show("LLM limits updated")
      else
        local message = stdErr and stdErr:match("^%s*(.-)%s*$") or ""
        hs.alert.show(message ~= "" and ("LLM limits error: " .. message) or "LLM limits error")
      end
    end)

    if not task or not task:start() then
      error("could not start collector")
    end
    hs.alert.show("LLM limits: обновляю…", 1)
  end)

  if not ok then
    hs.alert.show("LLM limits error: " .. tostring(err))
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
        table.insert(menu, {
          title = infoTitle(string.format("%-6s  no live data", entry.label)),
          disabled = true,
        })
      else
        local fiveHour = vendor.five_hour or {}
        local weekly = vendor.weekly or {}
        local fiveHourPct = math.floor((tonumber(fiveHour.used_pct) or 0) + 0.5)
        local weeklyPct = math.floor((tonumber(weekly.used_pct) or 0) + 0.5)
        table.insert(menu, {
          title = infoTitle(string.format("%-6s  5h  %3d%%  → %s", entry.label,
            fiveHourPct, formatResetTime(fiveHour.resets_at)), fiveHourPct >= 80),
          disabled = true,
        })
        -- vendor label rendered once per block: the wk row keeps a blank
        -- label column so numbers stay aligned under the 5h row
        table.insert(menu, {
          title = infoTitle(string.format("%-6s  wk  %3d%%  → %s", "",
            weeklyPct, formatResetTime(weekly.resets_at)), weeklyPct >= 80),
          disabled = true,
        })
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

return M
