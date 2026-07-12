local M = {
  cachePath = os.getenv("HOME") .. "/.llm-limits.json",
  collectorPath = "/Volumes/Work/Projects/llm-legs/llm-limits.sh",
  claudebCmd = "claudeb",
  wallsLog = nil,
  onRefreshStart = function() end,
  onRefreshDone = function() end,
}

local grayColor = { red = 0.55, green = 0.55, blue = 0.55 }

local function infoTitle(text, warning, gray)
  local attributes = { font = { name = "Menlo", size = 13 } }
  if gray then
    attributes.color = grayColor
  elseif warning then
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

local function parseTime(value)
  if type(value) == "number" then
    return value
  end
  return parseIsoTime(value)
end

local function formatAgeShort(value)
  local timestamp = parseIsoTime(value)
  if not timestamp then
    return "?"
  end

  local seconds = math.max(0, os.time() - timestamp)
  if seconds < 60 then
    return "now"
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return string.format("%dm", minutes)
  end
  local hours = math.floor(minutes / 60)
  if hours < 24 then
    return string.format("%dh", hours)
  end
  return string.format("%dd", math.floor(hours / 24))
end

local function formatAge(value)
  local age = formatAgeShort(value)
  if age == "now" then
    return "just now"
  end
  if age == "?" then
    return "unknown"
  end
  return age .. " ago"
end

-- Staleness contract: trust explicit `stale` booleans (bucket, then account, then
-- vendor); only when absent fall back to as_of/stale_seconds age vs the per-bucket
-- threshold (1800s five_hour, 21600s weekly/fable).
local function isStale(threshold, ...)
  local nodes = { ... }
  for _, node in ipairs(nodes) do
    if type(node) == "table" and type(node.stale) == "boolean" then
      return node.stale
    end
  end
  for _, node in ipairs(nodes) do
    if type(node) == "table" then
      local timestamp = parseTime(node.as_of)
      if timestamp then
        return (os.time() - timestamp) > threshold
      end
      local seconds = tonumber(node.stale_seconds)
      if seconds then
        return seconds > threshold
      end
    end
  end
  return false
end

local function formatResetTime(value)
  local timestamp = parseIsoTime(value)
  if not timestamp then
    return "unknown"
  end

  local delta = timestamp - os.time()
  if delta < 86400 then
    return os.date("%H:%M", timestamp)
  end
  if delta < 604800 then
    local weekdays = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
    return weekdays[tonumber(os.date("%w", timestamp)) + 1] .. os.date(" %H:%M", timestamp)
  end
  return os.date("%m-%d %H:%M", timestamp)
end

local function readLlmLimits()
  local ok, result, reason = pcall(function()
    local file = io.open(M.cachePath, "r")
    if not file then
      return nil, "cache file not found: " .. M.cachePath
    end

    local contents = file:read("*a")
    file:close()
    local decoded = hs.json.decode(contents)
    if type(decoded) ~= "table" then
      return nil, "cache file is not valid JSON: " .. M.cachePath
    end
    if decoded.schema ~= 1 then
      return nil, "unexpected cache schema " .. tostring(decoded.schema) .. ": " .. M.cachePath
    end

    return decoded, nil
  end)

  if ok then
    return result, reason
  end

  return nil, "error reading cache: " .. tostring(result)
end

local function baseEnvironment()
  return {
    HOME = os.getenv("HOME"),
    PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" .. os.getenv("HOME") .. "/.local/bin:/usr/sbin",
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

local lastCollectEpoch = 0
local lastRefreshOutcome = nil

local function recordRefreshOutcome(exitCode)
  local failures = {}
  local limits = readLlmLimits()
  local vendors = limits and limits.vendors
  if type(vendors) == "table" then
    for _, name in ipairs({ "claude", "codex", "gemini" }) do
      local vendor = vendors[name]
      if type(vendor) == "table" and type(vendor.refresh_error) == "string"
          and vendor.refresh_error ~= "" then
        table.insert(failures, name)
      end
    end
  end
  if exitCode ~= 0 and #failures == 0 then
    table.insert(failures, "collector")
  end
  lastRefreshOutcome = { failures = failures, timestamp = os.time() }
  return failures
end

local function shQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Menu-open refresh: a no-args collect is local-only (~0.4s measured), so it runs
-- synchronously and the menu opens already fresh. `timeout` keeps a wedged collect
-- from freezing the Hammerspoon UI; the throttle keeps rapid reopens instant.
local function collectOnOpen()
  local now = os.time()
  if now - lastCollectEpoch < 5 then
    return
  end
  lastCollectEpoch = now

  local environment = baseEnvironment()
  local command = "export PATH=" .. shQuote(environment.PATH) .. ";"
  if M.wallsLog then
    command = command .. " export LLM_LIMITS_WALLS_LOG=" .. shQuote(M.wallsLog) .. ";"
  end
  command = command .. " timeout 3 " .. shQuote(M.collectorPath) .. " >/dev/null 2>&1"
  pcall(hs.execute, command)
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

local function runClaudeb(args, failMessage)
  local ok = pcall(function()
    pcall(M.onRefreshStart)
    local task = hs.task.new(resolveClaudeb(), function(exitCode)
      if exitCode == 0 then
        -- Token-free re-read (no --refresh): recompute current/enabled state from the changed store.
        local reread = newCollectorTask(function()
          pcall(M.onRefreshDone, true)
        end, {})
        if not reread or not reread:start() then
          pcall(M.onRefreshDone, true)
        end
      else
        pcall(M.onRefreshDone, false, failMessage)
      end
    end, args)
    if task then
      task:setEnvironment(baseEnvironment())
    end
    if not task or not task:start() then
      error("could not start claudeb")
    end
  end)
  if not ok then
    pcall(M.onRefreshDone, false, failMessage)
  end
end

function M.switchAccount(name)
  runClaudeb({ "use", name }, "switch failed")
end

function M.toggleAccount(name, currentlyEnabled)
  runClaudeb({ currentlyEnabled and "disable" or "enable", name }, "toggle failed")
end

local function refreshData(args)
  local ok, err = pcall(function()
    local task = newCollectorTask(function(exitCode, _, stdErr)
      local failures = recordRefreshOutcome(exitCode)
      local message = stdErr and stdErr:match("^%s*(.-)%s*$") or ""
      pcall(M.onRefreshDone, exitCode == 0 and #failures == 0,
        message ~= "" and message or nil, failures)
    end, args)

    pcall(M.onRefreshStart)
    if not task or not task:start() then
      error("could not start collector")
    end
  end)

  if not ok then
    local failures = recordRefreshOutcome(1)
    pcall(M.onRefreshDone, false, tostring(err), failures)
  end
end

local function refreshItems(menu)
  table.insert(menu, {
    title = "Refresh",
    fn = function() refreshData({ "--refresh" }) end,
  })
  table.insert(menu, {
    title = "Refresh + Start Windows",
    fn = function() refreshData({ "--refresh", "--start-windows" }) end,
  })
end

function M.menuItems()
  collectOnOpen()

  local menu = {}
  local limits, readErrorReason = readLlmLimits()
  if limits and type(limits.vendors) == "table" then
    local vendors = {
      { key = "claude", label = "Claude" },
      { key = "codex", label = "Codex" },
      { key = "gemini", label = "Gemini" },
    }

    local ages = {}
    for _, entry in ipairs(vendors) do
      local vendor = limits.vendors[entry.key]
      if type(vendor) == "table" and vendor.available == true then
        table.insert(ages, string.format("%s %s", entry.key, formatAgeShort(vendor.as_of)))
      end

      if type(vendor) ~= "table" or vendor.available ~= true then
        table.insert(menu, {
          title = infoTitle(string.format("%-6s  no live data", entry.label)),
          disabled = true,
        })
      else
        local blocks = entry.key == "claude" and vendor.accounts or nil
        local isClaudeAccounts = entry.key == "claude" and type(blocks) == "table" and #blocks > 0
        local hasAccountControls = isClaudeAccounts and vendor.source == "claudeb-store"
        if type(blocks) ~= "table" or #blocks == 0 then
          blocks = {{ account = entry.label, five_hour = vendor.five_hour,
            weekly = vendor.weekly, fable = vendor.fable, is_current = false }}
        end
        if isClaudeAccounts then
          table.insert(menu, { title = infoTitle("Claude B"), disabled = true })
        end
        for _, block in ipairs(blocks) do
          local fiveHour = block.five_hour or {}
          local weekly = block.weekly
          local fiveHourPct = tonumber(fiveHour.used_pct)
          local fiveHourText = fiveHourPct and string.format("%d%%", math.floor(fiveHourPct + 0.5)) or "-"
          local fiveHourReset = fiveHourPct and formatResetTime(fiveHour.resets_at) or "—"
          local marker = block.is_current and "  ●" or ""
          local acct = block.account or entry.label
          local enabled = block.enabled ~= false
          local auth = block.auth
          if type(auth) == "table" then
            auth = auth.status
          end
          local blockGray = auth == "expired"
          local accountAge = ""
          local accountEpoch = parseTime(block.as_of)
          local vendorEpoch = parseTime(vendor.as_of)
          if accountEpoch and vendorEpoch and accountEpoch < vendorEpoch then
            accountAge = "  " .. formatAgeShort(block.as_of)
          end
          local fiveGray = blockGray or fiveHour.expired == true
            or isStale(1800, fiveHour, block, vendor)
          local fiveRow = {
            title = infoTitle(string.format("%-6s  5h  %4s  → %s%s%s", acct,
              fiveHourText, fiveHourReset, marker, accountAge),
              fiveHourPct ~= nil and fiveHourPct >= 80, fiveGray),
            disabled = true,
          }
          if hasAccountControls then
            fiveRow.disabled = nil
            fiveRow.checked = enabled
            fiveRow.menu = {
              { title = "In rotation", checked = enabled,
                fn = function() M.toggleAccount(acct, enabled) end },
              { title = "Make current", disabled = block.is_current,
                fn = function() M.switchAccount(acct) end },
            }
          end
          table.insert(menu, fiveRow)
          local function tailRow(label, bucket)
            if type(bucket) == "table" then
              local pct = math.floor((tonumber(bucket.used_pct) or 0) + 0.5)
              local gray = blockGray or bucket.expired == true
                or isStale(21600, bucket, block, vendor)
              return infoTitle(string.format("%-6s  %s  %3d%%  → %s%s", "",
                label, pct, formatResetTime(bucket.resets_at), marker),
                pct >= 80, gray)
            end
            return infoTitle(string.format("%-6s  %s    -   → —%s", "", label, marker),
              false, blockGray)
          end
          table.insert(menu, { title = tailRow("wk", weekly), disabled = true })
          if type(block.fable) == "table" then
            table.insert(menu, { title = tailRow("fb", block.fable), disabled = true })
          end
        end
        if isClaudeAccounts then
          table.insert(menu, { title = "-" })
        end
      end
    end

    table.insert(menu, { title = "-" })
    table.insert(menu, {
      title = infoTitle(#ages > 0 and table.concat(ages, " · ")
        or "no vendor data · fetched " .. formatAge(limits.fetched_at)),
      disabled = true,
    })
    if lastRefreshOutcome and #lastRefreshOutcome.failures > 0 then
      table.insert(menu, {
        title = infoTitle("refresh failed: " .. table.concat(lastRefreshOutcome.failures, ", "), true),
        disabled = true,
      })
    end
    refreshItems(menu)
  else
    table.insert(menu, {
      title = infoTitle("no data — press Refresh"),
      disabled = true,
    })
    if readErrorReason then
      table.insert(menu, {
        title = infoTitle(readErrorReason, true),
        disabled = true,
      })
    end
    if lastRefreshOutcome and #lastRefreshOutcome.failures > 0 then
      table.insert(menu, {
        title = infoTitle("refresh failed: " .. table.concat(lastRefreshOutcome.failures, ", "), true),
        disabled = true,
      })
    end
    refreshItems(menu)
  end

  return menu
end

return M
