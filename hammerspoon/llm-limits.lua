local M = {
  cachePath = os.getenv("HOME") .. "/.llm-limits.json",
  collectorPath = "/Volumes/Work/Projects/llm-legs/llm-limits.sh",
  claudebCmd = "claudeb",
  wallsLog = nil,
  onRefreshStart = function() end,
  onRefreshDone = function() end,
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

local function baseEnvironment()
  return {
    HOME = os.getenv("HOME"),
    PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" .. os.getenv("HOME") .. "/.local/bin",
  }
end

local function newCollectorTask(callback, args)
  local task = hs.task.new(M.collectorPath, callback, args or {})
  if task then
    local environment = baseEnvironment()
    if M.wallsLog then
      environment.LLM_LIMITS_WALLS_LOG = M.wallsLog
    end
    task:setEnvironment(environment)
  end
  return task
end

-- hs.task.new needs a launch path, not a PATH-resolved name; a bare command is taken from ~/.local/bin
-- (where claudeb lives). The env PATH below still covers claudeb's own child processes.
local function resolveClaudeb()
  local cmd = M.claudebCmd or "claudeb"
  if cmd:sub(1, 1) == "/" then
    return cmd
  end
  return os.getenv("HOME") .. "/.local/bin/" .. cmd
end

function M.switchAccount(name)
  local ok = pcall(function()
    pcall(M.onRefreshStart)
    local task = hs.task.new(resolveClaudeb(), function(exitCode)
      if exitCode == 0 then
        -- Token-free re-read (no --refresh): recompute current/is_current from the changed .claudeb-state.
        local reread = newCollectorTask(function()
          pcall(M.onRefreshDone, true)
        end, {})
        if not reread or not reread:start() then
          pcall(M.onRefreshDone, true)
        end
      else
        pcall(M.onRefreshDone, false, "switch failed")
      end
    end, { "use", name })
    if task then
      task:setEnvironment(baseEnvironment())
    end
    if not task or not task:start() then
      error("could not start claudeb")
    end
  end)
  if not ok then
    pcall(M.onRefreshDone, false, "switch failed")
  end
end

local function getLlmLimitsData()
  local ok, err = pcall(function()
    local task = newCollectorTask(function(exitCode, _, stdErr)
      local message = stdErr and stdErr:match("^%s*(.-)%s*$") or ""
      pcall(M.onRefreshDone, exitCode == 0, message ~= "" and message or nil)
    end, { "--refresh" })

    pcall(M.onRefreshStart)
    if not task or not task:start() then
      error("could not start collector")
    end
  end)

  if not ok then
    pcall(M.onRefreshDone, false, tostring(err))
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
        local blocks = entry.key == "claude" and vendor.accounts or nil
        local isClaudeAccounts = entry.key == "claude" and type(blocks) == "table" and #blocks > 0
        if type(blocks) ~= "table" or #blocks == 0 then
          blocks = {{ account = entry.label, five_hour = vendor.five_hour,
            weekly = vendor.weekly, is_current = false }}
        end
        for _, block in ipairs(blocks) do
          local fiveHour = block.five_hour or {}
          local weekly = block.weekly
          local fiveHourPct = math.floor((tonumber(fiveHour.used_pct) or 0) + 0.5)
          local marker = block.is_current and "  ●" or ""
          local acct = block.account or entry.label
          -- Only a NON-current real Claude account switches on click; the current one (● marker) is a no-op,
          -- and the Codex/Gemini + fallback single-account rows aren't switchable.
          local switchable = isClaudeAccounts and not block.is_current
          local function accountRow(title, warning)
            local row = { title = infoTitle(title, warning), disabled = true }
            if switchable then
              row.disabled = nil
              row.fn = function() M.switchAccount(acct) end
            end
            return row
          end
          -- "reset " and "%3d%%  " are both 6 chars, keeping the → column aligned.
          local fiveLabel = fiveHour.expired == true and "reset "
            or string.format("%3d%%  ", fiveHourPct)
          table.insert(menu, accountRow(string.format("%-6s  5h  %s→ %s%s", acct,
            fiveLabel, formatResetTime(fiveHour.resets_at), marker),
            fiveHour.expired ~= true and fiveHourPct >= 80))
          if type(weekly) == "table" then
            local weeklyPct = math.floor((tonumber(weekly.used_pct) or 0) + 0.5)
            local weeklyLabel = weekly.expired == true and "reset "
              or string.format("%3d%%  ", weeklyPct)
            table.insert(menu, accountRow(string.format("%-6s  wk  %s→ %s%s", "",
              weeklyLabel, formatResetTime(weekly.resets_at), marker),
              weekly.expired ~= true and weeklyPct >= 80))
          else
            table.insert(menu, accountRow(string.format("%-6s  wk    -   → —%s", "", marker)))
          end
        end
      end
    end

    table.insert(menu, { title = "-" })
    table.insert(menu, {
      title = infoTitle("Data fetched: " .. formatAge(limits.fetched_at)),
      disabled = true,
    })
    table.insert(menu, { title = "Get Data & Refresh", fn = getLlmLimitsData })
  else
    table.insert(menu, {
      title = infoTitle("no data — press Get Data & Refresh"),
      disabled = true,
    })
    table.insert(menu, { title = "Get Data & Refresh", fn = getLlmLimitsData })
  end

  return menu
end

return M
