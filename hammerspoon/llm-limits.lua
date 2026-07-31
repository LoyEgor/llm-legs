local M = {
  cachePath = os.getenv("HOME") .. "/.llm-limits.json",
  collectorPath = "/Volumes/Work/Projects/llm-legs/llm-limits.sh",
  claudebCmd = "claudeb",
  codexbCmd = "codexb",
  geminibCmd = "geminib",
  workerModelPath = os.getenv("HOME") .. "/.claude/worker-model",
  workerPickPath = os.getenv("HOME") .. "/.local/bin/worker-pick",
  routingFailed = false,
  wallsLog = nil,
  onRefreshStateChanged = function() end,
}

local grayColor = { red = 0.55, green = 0.55, blue = 0.55 }
local redColor = { red = 0.9, green = 0.25, blue = 0.2 }
local dimRedColor = { red = 0.9, green = 0.25, blue = 0.2, alpha = 0.55 }
local menuFont = { name = "Menlo", size = 13 }

-- A fixed 0.55 gray washed out against the menu, and NSColor's own secondaryLabelColor is worse
-- here: hs.styledtext resolves it once, and it came back as dark-mode white while the system was
-- light, which would paint the age white on a light menu. So the dim tone is the menu's own text
-- colour at 55%, derived per render from the appearance the menu is about to be drawn in.
local function dimColor()
  -- hs.host is absent from the isolated loaders the surface tests build, and a menu that throws
  -- while rendering a row is worse than one rendered for the light appearance.
  local host = hs.host
  local dark = type(host) == "table" and type(host.interfaceStyle) == "function"
    and host.interfaceStyle() == "Dark"
  local level = dark and 1 or 0
  return { red = level, green = level, blue = level, alpha = 0.55 }
end

-- Everything trailing an account name that is not the pin: age, "!", "login needed".
local function metaTitle(text)
  return hs.styledtext.new(text, { font = menuFont, color = dimColor() })
end

-- The pin carries no colour of its own, which is what makes it read exactly as strong as the rest
-- of the row in either appearance. It stays that way even where the router will not honour it: an
-- ignored pin always sits on a row that says so itself (red at-limit name, "!", "login needed"),
-- so nothing is lost by making the mark unmissable.
local function pinTitle()
  return hs.styledtext.new("  ●", { font = menuFont })
end

local function infoTitle(text, warning, gray, atLimit)
  local attributes = { font = menuFont }
  if atLimit then
    attributes.color = gray and dimRedColor or redColor
  elseif gray then
    attributes.color = grayColor
  elseif warning then
    attributes.color = redColor
  end
  return hs.styledtext.new(text, attributes)
end

local function loginNeededTitle(account, pinned, age, needsUserEntry)
  local title = infoTitle(account)
  if pinned then title = title .. pinTitle() end
  if age then title = title .. metaTitle("  " .. age) end
  if needsUserEntry then title = title .. metaTitle("  !") end
  return title .. metaTitle("  login needed")
end

-- Keep logged-out vendor actions in one constructor so their UX cannot drift; a pin action is
-- clear-only because logged-out accounts must never become newly pinnable.
local function loginNeededRow(label, loginFn, hardRefreshFn, removeFn, clearPinFn, age, needsUserEntry)
  local menu = {
    { title = "Log in…", fn = loginFn },
    { title = "Hard refresh", fn = hardRefreshFn },
  }
  if clearPinFn then
    table.insert(menu, { title = "Pin for workers", checked = true, fn = clearPinFn })
  end
  -- A non-removable account (e.g. codex `main`, whose `remove` always refuses)
  -- passes removeFn=nil so the row never offers a dead Remove action.
  if removeFn then
    table.insert(menu, { title = "Remove…", menu = {
      { title = "Confirm remove " .. label, fn = removeFn },
    } })
  end
  return {
    title = loginNeededTitle(label, clearPinFn ~= nil, age, needsUserEntry),
    menu = menu,
  }
end

local function geminiLoginNeededRow(label, account, pinned, age, needsUserEntry)
  local clearPinFn
  if pinned then clearPinFn = function() M.pinGemini(account, true) end end
  return loginNeededRow(label,
    function() M.loginGemini(account) end,
    function() M.hardRefreshGemini(account) end,
    function() M.removeGemini(account) end,
    clearPinFn, age, needsUserEntry)
end

local function truncateText(text, maxLength)
  if #text <= maxLength then
    return text
  end
  return text:sub(1, maxLength - 3):gsub("%s+$", "") .. "..."
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

local function formatAccountAge(value)
  local timestamp = parseTime(value)
  if not timestamp then
    return nil
  end

  local seconds = math.max(0, os.time() - timestamp)
  if seconds <= 300 then
    return nil
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

-- The pin goes straight after the name, ahead of the age and the warnings: it says which account
-- the workers are held to, and reading that must not mean scanning past everything else on the row.
local function accountTitle(text, age, atLimit, needsUserEntry, pinned, suffix)
  local title = infoTitle(text, false, false, atLimit)
  if pinned then
    title = title .. pinTitle()
  end
  -- The reset-credit suffix belongs to the account, but the pin comes first: folding the suffix
  -- into `text` put it between the name and the pin.
  if suffix and suffix ~= "" then
    title = title .. infoTitle(suffix, false, false, atLimit)
  end
  if age then
    title = title .. metaTitle("  " .. age)
  end
  if needsUserEntry then
    title = title .. metaTitle("  !")
  end
  return title
end

local function isStale(bucket)
  return type(bucket) == "table" and bucket.stale == true
end

local function formatResetTime(value)
  if value == nil then
    return "–"
  end
  local timestamp = parseTime(value)
  if not timestamp then
    return "unknown"
  end

  local now = os.time()
  local delta = timestamp - now
  if delta < 604800 then
    if os.date("%Y-%m-%d", timestamp) ~= os.date("%Y-%m-%d", now) then
      local weekdays = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
      return weekdays[tonumber(os.date("%w", timestamp)) + 1] .. os.date(" %H:%M", timestamp)
    end
    return os.date("%H:%M", timestamp)
  end
  return os.date("%b %d", timestamp)
end

local function resetIsPast(resetsAt)
  local timestamp = parseTime(resetsAt)
  if not timestamp then
    return false
  end
  return timestamp < os.time() - 60
end

local function usageBar(value)
  local pct = math.max(0, math.min(100, tonumber(value) or 0))
  local filled = math.floor(pct / 20 + 0.5)
  return string.rep("▓", filled) .. string.rep("░", 5 - filled)
end

local function rowTitle(account, label, bucket, gray, atLimit, barWarning)
  bucket = type(bucket) == "table" and bucket or {}
  gray = gray or bucket.expired == true or resetIsPast(bucket.resets_at)
  local pct = tonumber(bucket.effective_pct)
  local pctText = pct and string.format("%d%%", math.floor(pct + 0.5)) or "-"
  local reset = formatResetTime(bucket.resets_at)
  local prefix = string.format("%-6s  %-2s  ", account or "", label)
  local bar = usageBar(pct)
  local suffix = string.format("  %4s  %9s", pctText, reset)
  if barWarning and not atLimit then
    return infoTitle(prefix, false, gray, false)
      .. infoTitle(bar, true, false, false)
      .. infoTitle(suffix, false, gray, false)
  end
  return infoTitle(prefix .. bar .. suffix, false, gray, atLimit)
end

local function bucketAtLimit(bucket)
  return type(bucket) == "table" and (tonumber(bucket.effective_pct) or 0) >= 100
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

local function readWorkerPins()
  local ok, pins = pcall(function()
    local result = {}
    local file = io.open(M.workerModelPath, "r")
    if not file then return result end
    local contents = file:read("*a")
    file:close()
    for line in tostring(contents):gmatch("[^\r\n]+") do
      local key, value = line:match("^([%w_]+)=(.*)$")
      if key == "claudeb_profile" then
        result.claude = value
      elseif key == "codex_profile" then
        result.codex = value
      elseif key == "gemini_profile" then
        result.gemini = value
      end
    end
    return result
  end)
  return ok and pins or {}
end

local function baseEnvironment()
  return {
    HOME = os.getenv("HOME"),
    PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" .. os.getenv("HOME") .. "/.local/bin:/usr/sbin",
  }
end

local function newCollectorTask(callback, args, envExtra)
  local task = hs.task.new(M.collectorPath, callback, args or {})
  if task then
    local environment = baseEnvironment()
    if M.wallsLog then
      environment.LLM_LIMITS_WALLS_LOG = M.wallsLog
    end
    if type(envExtra) == "table" then
      for k, v in pairs(envExtra) do environment[k] = v end
    end
    task:setEnvironment(environment)
  end
  return task
end

local actionLogPath = os.getenv("HOME") .. "/.hammerspoon/llm_limits_actions.log"

-- Every vendor command the menu launches, with its exit code and the exit code of the collect
-- that follows it. Without this the only trace an action left was the mtime of the pool file,
-- which records effective changes and says nothing about a click that did nothing.
local function logAction(event, detail)
  local ok = pcall(function()
    local file = io.open(actionLogPath, "a")
    if not file then return end
    file:write(string.format("%s  %-18s %s\n", os.date("%Y-%m-%d %H:%M:%S"), event,
      tostring(detail or "")))
    file:close()
  end)
  return ok
end

-- What the menu shows for "in the worker pool" comes from the collector cache, so between a
-- successful toggle and the collect that follows it the rebuilt menu still showed the old state —
-- and clicking again, which is the natural response, produced the same command, which the
-- in-flight guard in runAccountCommand then swallowed in silence. The value the command just
-- established wins until a collect confirms it, and never longer than this TTL, so a command that
-- silently changed nothing cannot keep the menu lying.
local poolOverrides = {}
local poolOverrideTtl = 30

local function poolOverrideKey(vendor, account)
  return tostring(vendor) .. "\0" .. tostring(account)
end

local function setPoolOverride(vendor, account, enabled)
  poolOverrides[poolOverrideKey(vendor, account)] = { enabled = enabled, at = os.time() }
end

local function poolStateFor(vendor, account, cached)
  local key = poolOverrideKey(vendor, account)
  local override = poolOverrides[key]
  if not override then return cached end
  if override.enabled == cached or os.time() - override.at > poolOverrideTtl then
    poolOverrides[key] = nil
    return cached
  end
  return override.enabled
end

local taskRegistry = {}
local nextTaskId = 0
local lastCollectEpoch = 0
local runtimeGlobalError = nil

local function errorState(value)
  if type(value) == "table" and type(value.cause) == "string" then
    return {
      cause = value.cause,
      at = tonumber(value.at),
      needsUserEntry = value.needs_user_entry == true,
    }
  end
  if type(value) == "string" and value ~= "" then
    return { cause = value }
  end
  return nil
end

local function taskCause(stdOut, stdErr, exitCode, fallback)
  local text = tostring(stdErr or "")
  if text:match("^%s*$") then text = tostring(stdOut or "") end
  local cause
  for line in text:gmatch("[^\r\n]+") do
    if not line:match("^%s*$") then cause = line:match("^%s*(.-)%s*$") end
  end
  return truncateText(cause or fallback or ("exit " .. tostring(exitCode)), 160)
end

local function taskLiveness(task)
  if not task then return true, false end
  local ok, running = pcall(task.isRunning, task)
  return ok, ok and running == true
end

local function taskAlive(task)
  local verified, running = taskLiveness(task)
  return verified and running
end

local function purgeTasks()
  local now = os.time()
  for id, entry in pairs(taskRegistry) do
    if now - entry.started > entry.budget then
      local verified, running = taskLiveness(entry.task)
      if verified and not running then taskRegistry[id] = nil end
    end
  end
end

local function notifyRefreshState()
  pcall(M.onRefreshStateChanged)
end

local routingTask = nil
local routingRefreshPending = false

function M.refreshRouting()
  if routingTask then
    routingRefreshPending = true
    return
  end
  local task = hs.task.new(M.workerPickPath, function(exitCode, stdOut)
    routingTask = nil
    if exitCode == 0 and type(stdOut) == "string" and stdOut ~= "" then
      M.routingCache = { text = stdOut, at = os.time() }
      M.routingFailed = false
    else
      M.routingFailed = true
    end
    notifyRefreshState()
    if routingRefreshPending then
      routingRefreshPending = false
      M.refreshRouting()
    end
  end, {})
  if not task then
    M.routingFailed = true
    notifyRefreshState()
    return
  end
  local environment = baseEnvironment()
  environment.WORKER_PICK_CACHE_DIR = "/dev/null"
  task:setEnvironment(environment)
  routingTask = task
  local ok, started = pcall(task.start, task)
  if not ok or not started then
    routingTask = nil
    M.routingFailed = true
    notifyRefreshState()
  end
end

local function reserveTask(kind, budget, key)
  nextTaskId = nextTaskId + 1
  taskRegistry[nextTaskId] = {
    kind = kind, started = os.time(), budget = budget, key = key,
  }
  return nextTaskId
end

local function finishTask(id, exitCode, stdOut, stdErr, fallback)
  local entry = taskRegistry[id]
  taskRegistry[id] = nil
  local limits = readLlmLimits()
  local cacheGlobalError = errorState(limits and limits.refresh_error)
  if cacheGlobalError or (exitCode == 0 and limits) then
    runtimeGlobalError = nil
  elseif entry and entry.kind ~= "passive" and exitCode ~= 0 then
    runtimeGlobalError = {
      cause = taskCause(stdOut, stdErr, exitCode, fallback),
      at = os.time(),
    }
  end
  notifyRefreshState()
end

local function registryEntryForKey(key)
  for id, entry in pairs(taskRegistry) do
    if entry.key == key then
      local verified, running = taskLiveness(entry.task)
      if running or not verified then return entry end
      taskRegistry[id] = nil
    end
  end
  return nil
end

local function startTask(id, task, fallback)
  local entry = taskRegistry[id]
  if not entry or not task then
    finishTask(id, 1, nil, nil, fallback or "task could not start")
    return false
  end
  entry.task = task
  local ok, started = pcall(task.start, task)
  if not ok or not started then
    finishTask(id, 1, nil, nil, fallback or "task could not start")
    return false
  end
  notifyRefreshState()
  return true
end

local function taskForKey(key)
  purgeTasks()
  return registryEntryForKey(key)
end

function M.refreshState()
  purgeTasks()
  local busy = false
  for _, entry in pairs(taskRegistry) do
    if entry.kind ~= "passive" and taskAlive(entry.task) then
      busy = true
      break
    end
  end
  local limits, readError = readLlmLimits()
  local globalError = errorState(limits and limits.refresh_error) or runtimeGlobalError
  if not globalError and not limits and readError then
    globalError = { cause = readError, at = os.time() }
  end
  local vendorErrors = {}
  if limits and type(limits.vendors) == "table" then
    for _, name in ipairs({ "claude", "codex", "gemini" }) do
      local vendor = limits.vendors[name]
      local err = errorState(type(vendor) == "table" and vendor.refresh_error or nil)
      if err then vendorErrors[name] = err end
    end
  end
  local warning = globalError ~= nil
  if not warning then
    for _, err in pairs(vendorErrors) do
      if not err.needsUserEntry then
        warning = true
        break
      end
    end
  end
  return {
    busy = busy,
    warning = warning,
    prefix = busy and "⟳ " or (warning and "⚠ " or ""),
    globalError = globalError,
    vendorErrors = vendorErrors,
  }
end

local function collectOnOpen()
  local now = os.time()
  if taskForKey("passive") or now - lastCollectEpoch < 5 then return end
  lastCollectEpoch = now
  local id = reserveTask("passive", 360, "passive")
  local task = newCollectorTask(function(exitCode, stdOut, stdErr)
    finishTask(id, exitCode, stdOut, stdErr)
  end, {})
  startTask(id, task)
end

-- hs.task.new needs a launch path, not a PATH-resolved name; a bare command is taken from ~/.local/bin
-- (where claudeb lives). The env PATH below still covers claudeb's own child processes.
local function resolveCommand(cmd)
  if cmd:sub(1, 1) == "/" then
    return cmd
  end
  return os.getenv("HOME") .. "/.local/bin/" .. cmd
end

local function resolveClaudeb()
  return resolveCommand(M.claudebCmd or "claudeb")
end

local function resolveCodexb()
  return resolveCommand(M.codexbCmd or "codexb")
end

local function resolveGeminib()
  return resolveCommand(M.geminibCmd or "geminib")
end

-- Runs a vendor account command (claudeb/codexb/geminib) then re-collects so the row it
-- changed disappears/updates immediately. Shared by the toggle/switch/remove wiring.
local function runAccountCommand(launchPath, args, failMessage, onSuccess)
  local label = (launchPath:match("[^/]+$") or launchPath) .. " " .. table.concat(args, " ")
  local key = "account-action:" .. launchPath .. "\0" .. table.concat(args, "\0")
  -- Saying nothing here is what made a repeated click look like a dead menu.
  if taskForKey(key) then
    logAction("already-running", label)
    hs.alert.show("llm-limits: " .. label .. " is still running")
    return
  end
  logAction("launch", label)
  local id = reserveTask("account-action", 360, key)
  local task = hs.task.new(launchPath, function(exitCode, stdOut, stdErr)
    if exitCode ~= 0 then
      logAction("failed", string.format("%s exit=%s %s", label, tostring(exitCode),
        tostring((stdErr or stdOut or ""):gsub("%s+", " "):sub(1, 160))))
      finishTask(id, exitCode, stdOut, stdErr, failMessage)
      return
    end
    logAction("done", label .. " exit=0")
    if onSuccess then onSuccess() end
    local reread = newCollectorTask(function(collectExit, collectOut, collectErr)
      logAction("collect", label .. " collect_exit=" .. tostring(collectExit))
      finishTask(id, collectExit, collectOut, collectErr, "collect failed")
    end, {})
    startTask(id, reread, "collect could not start")
  end, args)
  if task then task:setEnvironment(baseEnvironment()) end
  startTask(id, task, failMessage)
end

local function runClaudeb(args, failMessage, onSuccess)
  runAccountCommand(resolveClaudeb(), args, failMessage, onSuccess)
end

local function runCodexb(args, failMessage, onSuccess)
  runAccountCommand(resolveCodexb(), args, failMessage, onSuccess)
end

local function runGeminib(args, failMessage, onSuccess)
  runAccountCommand(resolveGeminib(), args, failMessage, onSuccess)
end

-- Arms a Hammerspoon one-shot for the chat in the frontmost Terminal tab; the
-- arm itself is silent — claude_chat_switch.lua alerts on the outcome later.
function M.switchChatTo(name)
  local ok = pcall(function()
    local task = hs.task.new(os.getenv("HOME") .. "/.local/bin/claude-chat-switch",
      function(exitCode, stdOut, stdErr)
        if exitCode ~= 0 then
          local line = tostring(stdErr or ""):match("[^\r\n]+")
            or tostring(stdOut or ""):match("[^\r\n]+")
            or ("exit " .. tostring(exitCode))
          hs.alert.show("Chat switch failed: " .. line)
        end
      end, { "--front", name })
    if task then
      task:setEnvironment(baseEnvironment())
    end
    if not task or not task:start() then
      error("could not start claude-chat-switch")
    end
  end)
  if not ok then
    hs.alert.show("Chat switch failed: could not start claude-chat-switch")
  end
end

function M.cancelPendingSwitch()
  if _G.ClaudeChatSwitch and _G.ClaudeChatSwitch.cancel
      and _G.ClaudeChatSwitch.cancel() then
    hs.alert.show("Chat switch cancelled")
  end
end

function M.toggleAccount(name, currentlyEnabled)
  runClaudeb({ currentlyEnabled and "disable" or "enable", name }, "toggle failed",
    function() setPoolOverride("claude", name, not currentlyEnabled) end)
end

function M.toggleCodexAccount(name, currentlyEnabled)
  runCodexb({ currentlyEnabled and "disable" or "enable", name }, "toggle failed",
    function() setPoolOverride("codex", name, not currentlyEnabled) end)
end

function M.toggleGeminiAccount(name, currentlyEnabled)
  runGeminib({ currentlyEnabled and "disable" or "enable", name }, "toggle failed",
    function() setPoolOverride("gemini", name, not currentlyEnabled) end)
end

function M.pinClaude(name, currentlyPinned)
  runClaudeb({ "use", currentlyPinned and "--clear" or name }, "pin failed")
end

function M.pinCodex(name, currentlyPinned)
  runCodexb({ "use", currentlyPinned and "--clear" or name }, "pin failed")
end

function M.pinGemini(name, currentlyPinned)
  runGeminib({ "use", currentlyPinned and "--clear" or name }, "pin failed")
end

local function refreshData(args, kind, budget, key, envExtra)
  if taskForKey(key) then return end
  local id = reserveTask(kind, budget, key)
  local task = newCollectorTask(function(exitCode, stdOut, stdErr)
    finishTask(id, exitCode, stdOut, stdErr)
  end, args, envExtra)
  startTask(id, task, "collector could not start")
end

local function userRefreshData(args, kind, budget, key)
  refreshData(args, kind, budget, key, { CLAUDEB_WARM_USER_EXPLICIT = "true" })
end

local function hardRefresh(target, startWindows)
  local args = { "--refresh-account", target }
  if startWindows then table.insert(args, "--start-windows") end
  userRefreshData(args, "hard-refresh", 360, "hard:" .. target)
end

-- Hard = full truth at any cost: opens the account's expired 5h window (tiny paid ping).
function M.hardRefreshClaude(name) hardRefresh("claude/" .. name, true) end
function M.hardRefreshCodex(name) hardRefresh("codex/" .. name) end
function M.hardRefreshGemini(name) hardRefresh("gemini/" .. (name or "main")) end

function M.removeClaude(name) runClaudeb({ "remove", name }, "remove failed") end
function M.removeCodex(name) runCodexb({ "remove", name }, "remove failed") end
function M.removeGemini(name)
  if not name or name == "main" then
    refreshData({ "--gemini-remove" }, "gemini-remove", 360, "gemini-remove")
  else
    runGeminib({ "remove", name }, "remove failed")
  end
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", [['\'']]) .. "'"
end

-- Two quoting layers: the account name is shell-quoted inside the command, then
-- the whole command becomes an AppleScript string literal for `do script`.
local function openLoginTerminal(command)
  local literal = '"' .. command:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
  local script = 'tell application "Terminal"\ndo script ' .. literal
    .. '\nactivate\nend tell'
  local ok = pcall(function() return hs.osascript.applescript(script) end)
  if not ok then
    hs.alert.show("Login could not open Terminal")
  end
end

function M.loginClaude(name)
  openLoginTerminal((M.claudebCmd or "claudeb") .. " profile " .. shellQuote(name))
end
-- Never `--device-auth` here: that flow needs a per-account ChatGPT Security toggle,
-- so a menu click on a fresh account would dead-end in the web UI.
function M.loginCodex(name)
  openLoginTerminal("codexb run " .. shellQuote(name) .. " login")
end
function M.loginGemini(name)
  openLoginTerminal((M.geminibCmd or "geminib") .. " profile " .. shellQuote(name or "main"))
end

local function refreshItems(menu)
  table.insert(menu, {
    title = "Refresh",
    disabled = M.refreshState().busy,
    fn = function()
      userRefreshData({ "--refresh" }, "refresh", 360, "refresh")
    end,
  })
  table.insert(menu, {
    title = "Refresh + Start Windows",
    disabled = M.refreshState().busy,
    fn = function()
      userRefreshData({ "--refresh", "--start-windows" }, "start-windows", 1200, "start-windows")
    end,
  })
end

local function reportItem(menu)
  local project = "/Volumes/Work/Projects/usage-ai-report"
  local item
  local lock = hs.fs.attributes(project .. "/.run-report.lock")
  if hs.fs.attributes(project, "mode") ~= "directory" then
    item = { title = "Report: volume not mounted", disabled = true }
  -- 10800s matches run_report.sh's stale-lock rule; a crashed run must not pin this item forever
  elseif lock and os.time() - (lock.modification or 0) <= 10800 then
    item = { title = "Report: running…", disabled = true }
  else
    local report = project .. "/repo/LoyEgor/" .. os.date("%Y-%m-%d") .. ".md"
    item = {
      title = hs.fs.attributes(report) and "Update today's report" or "Create today's report",
      fn = function()
        hs.task.new("/bin/bash", nil, { "-c", "REPORT_INTERACTIVE=1 exec bash '" .. project .. "/run_report.sh' --today" }):start()
        hs.alert.show("Report started")
      end,
    }
  end
  table.insert(menu, { title = "-" })
  table.insert(menu, item)
end

local function refreshErrorAge(at)
  if type(at) ~= "number" then return "unknown" end
  local seconds = math.max(0, os.time() - at)
  if seconds < 60 then return "now" end
  if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
  if seconds < 86400 then return string.format("%dh", math.floor(seconds / 3600)) end
  return string.format("%dd", math.floor(seconds / 86400))
end

local function refreshErrorTitle(err)
  return truncateText("refresh failed " .. err.cause .. " · " .. refreshErrorAge(err.at), 88)
end

local function splitCauseEntries(cause)
  local parts, start, sep = {}, 1, "; "
  while true do
    local s, e = cause:find(sep, start, true)
    if not s then parts[#parts + 1] = cause:sub(start); break end
    parts[#parts + 1] = cause:sub(start, s - 1)
    start = e + 1
  end
  return parts
end

local function splitLiteral(text, separator)
  local parts, start = {}, 1
  while true do
    local first, last = text:find(separator, start, true)
    if not first then
      parts[#parts + 1] = text:sub(start)
      return parts
    end
    parts[#parts + 1] = text:sub(start, first - 1)
    start = last + 1
  end
end

local function routingDisplayLines(lines)
  local result = {}
  for _, line in ipairs(lines) do
    if line:sub(1, 6) == "NEXT: " then
      local parts = splitLiteral(line:sub(7), "  |  ")
      result[#result + 1] = "NEXT:"
      for _, part in ipairs(parts) do result[#result + 1] = "  " .. part end
    else
      local vendor, accounts = line:match("^(%a+): (.*)$")
      if vendor == "codex" or vendor == "gemini" or vendor == "claude" then
        local footnote
        if vendor == "claude" then
          local marker = "   (* = this session account"
          local footnoteStart = accounts:find(marker, 1, true)
          if footnoteStart then
            footnote = accounts:sub(footnoteStart + 3)
            accounts = accounts:sub(1, footnoteStart - 1)
          end
        end
        result[#result + 1] = vendor .. ":"
        for _, account in ipairs(splitLiteral(accounts, " | ")) do
          result[#result + 1] = "  " .. account
        end
        if footnote then result[#result + 1] = "  " .. footnote end
      else
        result[#result + 1] = line
      end
    end
  end
  return result
end

local function routingSubmenu()
  local cache = M.routingCache
  if type(cache) ~= "table" or type(cache.text) ~= "string"
      or type(cache.at) ~= "number" then
    return {{ title = infoTitle("routing unavailable", false, true), disabled = true }}
  end
  local store = hs.fs.attributes(M.cachePath)
  local gray = M.routingFailed == true
    or (type(store) == "table" and type(store.modification) == "number"
      and cache.at < store.modification)
  local lines = {}
  local normalized = cache.text:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (normalized .. "\n"):gmatch("(.-)\n") do
    if line == "# Worker routing policy" then break end
    table.insert(lines, line)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  if #lines == 0 then
    return {{ title = infoTitle("routing unavailable", false, true), disabled = true }}
  end
  local menu = {{
    title = infoTitle("as of " .. os.date("%H:%M", cache.at), false, gray),
    disabled = true,
  }}
  for _, line in ipairs(routingDisplayLines(lines)) do
    table.insert(menu, { title = infoTitle(line, false, gray), disabled = true })
  end
  return menu
end

function M.menuItems()
  collectOnOpen()

  local menu = {}
  local state = M.refreshState()
  if state.globalError then
    table.insert(menu, {
      title = infoTitle(refreshErrorTitle(state.globalError), true),
      disabled = true,
    })
  end
  local pendingOk, pending = pcall(function()
    return _G.ClaudeChatSwitch and _G.ClaudeChatSwitch.pending
      and _G.ClaudeChatSwitch.pending()
  end)
  if pendingOk and pending then
    table.insert(menu, {
      title = "Cancel pending switch",
      fn = M.cancelPendingSwitch,
    })
    table.insert(menu, { title = "-" })
  end
  local limits, readErrorReason = readLlmLimits()
  -- Lines come from the collector: this renderer never reads the registry itself.
  if limits and type(limits.experiments) == "table" then
    local announced = false
    for _, line in ipairs(limits.experiments) do
      if type(line) == "string" and line ~= "" then
        table.insert(menu, { title = infoTitle(line, true), disabled = true })
        announced = true
      end
    end
    if announced then table.insert(menu, { title = "-" }) end
  end
  table.insert(menu, {
    title = infoTitle("Routing"),
    menu = routingSubmenu(),
  })
  table.insert(menu, { title = "-" })
  if limits and type(limits.vendors) == "table" then
    local pins = readWorkerPins()
    local vendors = {
      { key = "claude", label = "Claude" },
      { key = "codex", label = "Codex" },
      { key = "gemini", label = "Gemini" },
    }

    for _, entry in ipairs(vendors) do
      local vendor = limits.vendors[entry.key]
      local pinnedAccount = pins[entry.key]
      local renderedPin = false
      local renderedAccountRows = false
      local hasGeminiAccounts = entry.key == "gemini" and type(vendor) == "table"
        and type(vendor.accounts) == "table" and #vendor.accounts > 1
      -- A removed single-account vendor (gemini marker) is skipped entirely until its
      -- creds are valid again; llm-limits.sh clears the marker on that recovery.
      if type(vendor) == "table" and vendor.removed == true then
        vendor = nil
      elseif type(vendor) ~= "table" or (vendor.available ~= true and not hasGeminiAccounts) then
        local authNeeded = type(vendor) == "table" and vendor.auth_needed == true
        local unavailableRow
        if entry.key == "gemini" and authNeeded then
          unavailableRow = geminiLoginNeededRow(entry.label, "main", pinnedAccount == "main",
            formatAccountAge(vendor.as_of), vendor.needs_user_entry == true)
          renderedPin = pinnedAccount == "main"
        else
          unavailableRow = {
            title = authNeeded and loginNeededTitle(entry.label, false,
              formatAccountAge(vendor.as_of), vendor.needs_user_entry == true)
              or infoTitle(string.format("%-6s  no live data", entry.label)),
            disabled = true,
          }
          if entry.key == "gemini" then
            unavailableRow.disabled = nil
            unavailableRow.menu = {{
              title = "Hard refresh", fn = function() M.hardRefreshGemini("main") end,
            }}
          end
        end
        table.insert(menu, unavailableRow)
      else
        local blocks = (entry.key == "claude" or entry.key == "codex" or entry.key == "gemini")
          and vendor.accounts or nil
        local isClaudeAccounts = entry.key == "claude" and type(blocks) == "table" and #blocks > 0
        local isCodexAccounts = entry.key == "codex" and type(blocks) == "table" and #blocks > 0
        local isGeminiAccounts = entry.key == "gemini" and type(blocks) == "table" and #blocks > 1
        local isAccountRows = isClaudeAccounts or isCodexAccounts or isGeminiAccounts
        renderedAccountRows = isAccountRows
        local hasAccountControls = isClaudeAccounts and vendor.source == "claudeb-store"
        if isGeminiAccounts then
          local visible = {}
          for _, block in ipairs(blocks) do
            if block.removed ~= true then table.insert(visible, block) end
          end
          blocks = visible
        end
        if not isAccountRows then
          blocks = {{ account = entry.label, five_hour = vendor.five_hour,
            weekly = vendor.weekly, fable = vendor.fable, as_of = vendor.as_of,
            is_current = false }}
        end
        if isAccountRows then
          table.insert(menu, {
            title = infoTitle(isClaudeAccounts and "Claude B" or entry.label),
            disabled = true,
          })
        else
          -- Gemini's pin has to be known before the row is built now that the mark lives inside
          -- the title instead of being appended behind the age.
          local geminiPinned = entry.key == "gemini" and pinnedAccount == "main"
          local fallbackRow = {
            title = accountTitle(entry.label, formatAccountAge(vendor.as_of), false,
              vendor.needs_user_entry == true, geminiPinned),
            disabled = true,
          }
          local account = vendor.current_account or vendor.account
          local refresh
          if entry.key == "claude" and type(account) == "string" and account ~= "" then
            refresh = function() M.hardRefreshClaude(account) end
          elseif entry.key == "codex" and type(account) == "string" and account ~= "" then
            refresh = function() M.hardRefreshCodex(account) end
          elseif entry.key == "gemini" then
            refresh = function() M.hardRefreshGemini("main") end
          end
          if refresh then
            fallbackRow.disabled = nil
            fallbackRow.menu = {{ title = "Hard refresh", fn = refresh }}
          end
          if entry.key == "gemini" then
            local pinExists = geminiPinned
            if pinExists then renderedPin = true end
            fallbackRow.disabled = nil
            fallbackRow.menu = {
              {
                title = "Pin for workers",
                checked = pinExists,
                fn = function() M.pinGemini("main", pinExists) end,
              },
              { title = "Hard refresh", fn = refresh },
            }
          end
          table.insert(menu, fallbackRow)
        end
        for _, block in ipairs(blocks) do
          local fiveHour = block.five_hour or {}
          local weekly = block.weekly
          local acct = block.account or entry.label
          local enabled = poolStateFor(entry.key, acct, block.enabled ~= false)
          local authNeeded = block.auth_needed == true
          local accountAge = formatAccountAge(block.as_of)
          local generalAtLimit = bucketAtLimit(fiveHour) or bucketAtLimit(weekly)
          local pinExists = pins[entry.key] == acct
          local pinFn
          if entry.key == "claude" then
            pinFn = function(pinned) M.pinClaude(acct, pinned) end
          elseif entry.key == "codex" then
            pinFn = function(pinned) M.pinCodex(acct, pinned) end
          else
            pinFn = function(pinned) M.pinGemini(acct, pinned) end
          end
          if isAccountRows then
            if pinExists then renderedPin = true end
            local resetCredits = tonumber(block.reset_credits)
            local resetSuffix = resetCredits and resetCredits > 0
              and string.format("  ↻%d", math.floor(resetCredits)) or ""
            local accountRow
            if authNeeded then
              local loginFn, hardRefreshFn, removeFn
              if entry.key == "claude" then
                loginFn = function() M.loginClaude(acct) end
                hardRefreshFn = function() M.hardRefreshClaude(acct) end
                removeFn = function() M.removeClaude(acct) end
              elseif entry.key == "codex" then
                loginFn = function() M.loginCodex(acct) end
                hardRefreshFn = function() M.hardRefreshCodex(acct) end
                -- codexb refuses to remove `main` (the real ~/.codex); no Remove item.
                if acct ~= "main" then removeFn = function() M.removeCodex(acct) end end
              else
                accountRow = geminiLoginNeededRow(acct, acct, pinExists,
                  accountAge, block.needs_user_entry == true)
              end
              if not accountRow then
                local clearPinFn
                if pinExists then clearPinFn = function() pinFn(true) end end
                accountRow = loginNeededRow(acct, loginFn, hardRefreshFn, removeFn, clearPinFn,
                  accountAge, block.needs_user_entry == true)
              end
            else
              local title = accountTitle(acct, accountAge, generalAtLimit,
                block.needs_user_entry == true, pinExists, resetSuffix)
              accountRow = {
                title = title,
                disabled = true,
              }
              if hasAccountControls then
                accountRow.disabled = nil
                accountRow.checked = enabled
                accountRow.menu = {
                  { title = "In worker pool", checked = enabled,
                    fn = function() M.toggleAccount(acct, enabled) end },
                  { title = "Hard refresh",
                    fn = function() M.hardRefreshClaude(acct) end },
                }
                -- "main" is ~/.claude itself, not a claudeb profile dir — no chat switch.
                if acct ~= "main" then
                  table.insert(accountRow.menu, {
                    title = "Switch chat to this",
                    fn = function() M.switchChatTo(acct) end,
                  })
                end
              elseif isCodexAccounts then
                accountRow.disabled = nil
                accountRow.checked = enabled
                accountRow.menu = {
                  { title = "In worker pool", checked = enabled,
                    fn = function() M.toggleCodexAccount(acct, enabled) end },
                  { title = "Hard refresh",
                    fn = function() M.hardRefreshCodex(acct) end },
                }
              elseif isGeminiAccounts then
                accountRow.disabled = nil
                accountRow.checked = enabled
                accountRow.menu = {
                  { title = "In worker pool", checked = enabled,
                    fn = function() M.toggleGeminiAccount(acct, enabled) end },
                  { title = "Hard refresh",
                    fn = function() M.hardRefreshGemini(acct) end },
                }
              end
              if accountRow.menu and (block.removed ~= true or pinExists) then
                table.insert(accountRow.menu, 2, {
                  title = "Pin for workers",
                  checked = pinExists,
                  fn = function() pinFn(pinExists) end,
                })
              end
            end
            table.insert(menu, accountRow)
          end
          if not authNeeded then
            local fiveGray = isStale(fiveHour)
            local fiveRow = {
              title = rowTitle("", "5h", fiveHour, fiveGray, bucketAtLimit(fiveHour)),
              disabled = true,
            }
            table.insert(menu, fiveRow)
            local function tailRow(label, bucket, barWarning)
              if type(bucket) == "table" then
                local gray = isStale(bucket)
                return rowTitle("", label, bucket, gray, bucketAtLimit(bucket), barWarning)
              end
              return rowTitle("", label, nil, false, false, barWarning)
            end
            table.insert(menu, { title = tailRow("wk", weekly), disabled = true })
            if type(block.fable) == "table" then
              local fableWarning = (tonumber(block.fable.effective_pct) or 0) >= 80
              table.insert(menu, { title = tailRow("fb", block.fable, fableWarning), disabled = true })
            end
          end
          if isGeminiAccounts and not authNeeded then
            local accountError = errorState(block.refresh_error)
            if accountError then
              table.insert(menu, {
                title = infoTitle(refreshErrorTitle(accountError), false, true),
                disabled = true,
              })
            end
          end
        end
      end
      if type(pinnedAccount) == "string" and pinnedAccount ~= "" and not renderedPin then
        local clearPin
        if entry.key == "claude" then
          clearPin = function() M.pinClaude(pinnedAccount, true) end
        elseif entry.key == "codex" then
          clearPin = function() M.pinCodex(pinnedAccount, true) end
        else
          clearPin = function() M.pinGemini(pinnedAccount, true) end
        end
        table.insert(menu, {
          title = metaTitle(pinnedAccount) .. pinTitle(),
          menu = {{ title = "Pin for workers", checked = true, fn = clearPin }},
        })
      end
      if renderedAccountRows then
        table.insert(menu, { title = "-" })
      end
      local refreshError = not hasGeminiAccounts
        and errorState(type(vendor) == "table" and vendor.refresh_error or nil) or nil
      if refreshError then
        local entries = splitCauseEntries(refreshError.cause or "")
        if #entries > 1 then
          for _, entry in ipairs(entries) do
            table.insert(menu, {
              title = infoTitle(refreshErrorTitle({ cause = entry, at = refreshError.at }), false, true),
              disabled = true,
            })
          end
        else
          table.insert(menu, {
            title = infoTitle(refreshErrorTitle(refreshError), false, true),
            disabled = true,
          })
        end
      end
    end

    table.insert(menu, { title = "-" })
    refreshItems(menu)
    reportItem(menu)
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
    refreshItems(menu)
    reportItem(menu)
  end

  return menu
end

-- The store is written by the collector, llm-limitsd, and now every session's
-- statusline merge-kick; watch it so the menubar reflects fresh data without a
-- menu open. Bursty atomic rewrites are collapsed by the throttle below.
local STORE_RERENDER_THROTTLE = 2
local lastStoreRenderEpoch = 0

-- Pure epoch guard so the throttle is testable without hs or a live clock.
function M.shouldRerenderOnStoreChange(now, last)
  return type(now) == "number" and (now - (last or 0)) >= STORE_RERENDER_THROTTLE
end

-- Re-render ONLY (title via onRefreshStateChanged; the menu itself rebuilds on
-- open). It must never start a collector: the collector writes the store, which
-- would re-fire this watcher forever.
local function onStoreChanged()
  local now = os.time()
  if not M.shouldRerenderOnStoreChange(now, lastStoreRenderEpoch) then return end
  lastStoreRenderEpoch = now
  M.refreshRouting()
  notifyRefreshState()
end

local function onWorkerModelChanged()
  M.refreshRouting()
  notifyRefreshState()
end

-- A local pathwatcher is garbage-collected and silently stops firing; hold the
-- reference at module scope (same trap as token_upkeep's wakeWatcher). Guarded
-- so the headless renderer harness (no hs.pathwatcher) still loads.
if hs.pathwatcher then
  M.storeWatcher = hs.pathwatcher.new(M.cachePath, onStoreChanged)
  if M.storeWatcher then M.storeWatcher:start() end
  M.workerModelWatcher = hs.pathwatcher.new(M.workerModelPath, onWorkerModelChanged)
  if M.workerModelWatcher then M.workerModelWatcher:start() end
  M.refreshRouting()
end

return M
