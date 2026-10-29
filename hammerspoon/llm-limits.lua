local home = os.getenv("HOME")
-- The shell helper is this repo's, so it is found beside this file: an absolute path survives a
-- moved checkout by pointing at the old one.
local repoRoot = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]+/[^/]+$")

local M = {
  cachePath = home .. "/.llm-limits.json",
  collectorPath = "/Volumes/Work/Projects/llm-legs/llm-limits.sh",
  claudebCmd = "claudeb",
  codexbCmd = "codexb",
  geminibCmd = "geminib",
  grokbCmd = "grokb",
  workerModelPath = home .. "/.claude/worker-model",
  workerModelShPath = repoRoot and repoRoot .. "/share/worker-model.sh" or nil,
  workerPickPath = home .. "/.local/bin/worker-pick",
  opencodeGoCmd = "opencode-go",
  routingFailed = false,
  onRefreshStateChanged = function() end,
}

local style = require("menu-style")
local redColor, dimRedColor, menuFont = style.RED, style.DIM_RED, style.MONO
local dimColorName = style.DIM

-- Measured off a real popup menu: macOS paints a disabled row's text at tertiaryLabelColor, and
-- every percentage row here is a disabled row, so that colour IS the menu's own dim. Any literal
-- alpha of ours is a second, darker gray sitting right beside it — a flat 0.55 black measured
-- 112/255 against the system's 184/255. The name stays unresolved: AppKit resolves it when it draws
-- the row, in the menu's own appearance. Resolving it here (hs.drawing.color.asRGB) used the main
-- thread's current drawing appearance, which stays whatever theme Hammerspoon launched in: after a
-- 03:40 relaunch under the auto theme's dark night it still said DarkAqua by day (NSApp Aqua) and
-- gave white at 0.25, invisible on a white backdrop (measured 2026-10-14: 247 on 244, the disabled
-- rows beside it 182).
local function dimColor() return dimColorName end

-- The pool mark of an account row: the check is derived from the pool membership and the vendor's
-- role switches, never stored, so switching a role back on brings it back by itself.
local function applyPoolMark(row, inPool, unused)
  row.checked = (inPool and not unused) == true
end

-- Everything trailing an account name that is not the pin: age, "!", "login needed".
local function metaTitle(text, alarm, dim)
  local color = dimColor()
  if alarm then color = dim and dimRedColor or redColor end
  return hs.styledtext.new(text, { font = menuFont, color = color })
end

-- The pin carries no colour of its own, which is what makes it read exactly as strong as the rest
-- of the row in either appearance. It stays that way even where the router will not honour it: an
-- ignored pin always sits on a row that says so itself (red at-limit name, "!", "login needed"),
-- so nothing is lost by making the mark unmissable.
local function pinTitle()
  return hs.styledtext.new("  ●", { font = menuFont })
end

-- A palette-coloured title is the same object on every build, so a disabled row hits style.mono's
-- settled cache instead of walking its runs again. The dim tone is not memoised: it resolves a
-- system colour that follows the appearance.
local paletteTitles, paletteCount = {}, 0

local function infoTitle(text, warning, dim, atLimit)
  local attributes = { font = menuFont }
  local memoKey
  if atLimit then
    attributes.color = dim and dimRedColor or redColor
    memoKey = (dim and "d" or "r") .. text
  elseif dim then
    attributes.color = dimColor()
  elseif warning then
    attributes.color = redColor
    memoKey = "w" .. text
  end
  local hit = memoKey and paletteTitles[memoKey]
  if hit then return hit end
  local title = hs.styledtext.new(text, attributes)
  if memoKey then
    if paletteCount >= 256 then paletteTitles, paletteCount = {}, 0 end
    paletteTitles[memoKey], paletteCount = title, paletteCount + 1
  end
  return title
end

local function loginNeededTitle(account, pinned, age, needsUserEntry, dim, ageAlarm)
  local title = infoTitle(account, false, dim == true)
  if pinned then title = title .. pinTitle() end
  if age then title = title .. metaTitle("  " .. age, ageAlarm, dim == true) end
  if needsUserEntry then title = title .. metaTitle("  !") end
  return title .. metaTitle("  login needed")
end

-- Keep logged-out vendor actions in one constructor so their UX cannot drift; a pin action is
-- clear-only because logged-out accounts must never become newly pinnable.
local function loginNeededRow(label, loginFn, hardRefreshFn, removeFn, clearPinFn, age,
    needsUserEntry, dim, ageAlarm)
  local menu = {
    { title = "Log in…", fn = loginFn },
    { title = "Hard refresh", fn = hardRefreshFn },
  }
  if clearPinFn then
    table.insert(menu, { title = "Pin for workers", checked = true, fn = clearPinFn })
  end
  -- A non-removable account (e.g. grok `main`, whose `remove` always refuses)
  -- passes removeFn=nil so the row never offers a dead Remove action.
  if removeFn then
    table.insert(menu, { title = "Remove " .. label, fn = removeFn })
  end
  return {
    title = loginNeededTitle(label, clearPinFn ~= nil, age, needsUserEntry, dim, ageAlarm),
    menu = menu,
  }
end

local function geminiLoginNeededRow(label, account, pinned, age, needsUserEntry, dim, ageAlarm)
  local clearPinFn
  if pinned then clearPinFn = function() M.pinGemini(account, true) end end
  return loginNeededRow(label,
    function() M.loginGemini(account) end,
    function() M.hardRefreshGemini(account) end,
    function() M.removeGemini(account) end,
    clearPinFn, age, needsUserEntry, dim, ageAlarm)
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
    return "never"
  end

  local seconds = math.max(0, os.time() - timestamp)
  if seconds <= 300 then
    return nil
  end
  return style.ago(seconds)
end

-- The pin goes straight after the name, ahead of the age and the warnings: it says which account
-- the workers are held to, and reading that must not mean scanning past everything else on the row.
local function accountTitle(text, age, atLimit, needsUserEntry, pinned, suffix, dim, ageAlarm)
  local title = infoTitle(text, false, dim == true, atLimit)
  if pinned then
    title = title .. pinTitle()
  end
  -- The reset-credit suffix belongs to the account, but the pin comes first: folding the suffix
  -- into `text` put it between the name and the pin.
  if suffix and suffix ~= "" then
    title = title .. infoTitle(suffix, false, dim == true, atLimit)
  end
  if age then
    title = title .. metaTitle("  " .. age, ageAlarm, dim == true)
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
  return style.day(timestamp)
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

-- `columns` overrides the number and the reset a bucket would print, for a vendor that states
-- neither: an empty column reads as "not measured", while "-" and "–" read as a reading taken.
local function rowTitle(account, label, bucket, dim, atLimit, barWarning, columns)
  bucket = type(bucket) == "table" and bucket or {}
  columns = columns or {}
  dim = dim or columns.untrusted == true or bucket.expired == true or resetIsPast(bucket.resets_at)
  local pct = tonumber(bucket.effective_pct)
  local pctText = columns.pct or (pct and string.format("%d%%", math.floor(pct + 0.5)) or "-")
  local reset = columns.reset or formatResetTime(bucket.resets_at)
  local prefix = string.format("%-6s  %-2s  ", account or "", label)
  local bar = usageBar(pct)
  -- The detail trails the fixed columns: set between them it pushes the reset right on the one row
  -- that carries it, so a single Grok build figure would misalign the whole menu.
  local suffix = string.format("  %4s  %9s%s", pctText, reset, columns.detail or "")
  if columns.untrusted and pctText ~= "-" and pctText ~= "" then
    suffix = string.format("  %5s %9s%s", pctText .. "~", reset, columns.detail or "")
  end
  if barWarning and not atLimit then
    return infoTitle(prefix, false, dim, false)
      .. infoTitle(bar, true, false, false)
      .. infoTitle(suffix, false, dim, false)
  end
  return infoTitle(prefix .. bar .. suffix, false, dim, atLimit)
end

-- Labels: fv Flow video credits, fm Flow Music credits, gm the Gemini app's music. A standing wall
-- is the pool's limit hit, drawn like any walled window; a pool without a known total is unmeasured.
-- Without a renewal date the reset column carries the balance left, so the menu grows no column.
-- fm exists only once Flow Music has seen the account signed in; a Flow video wall leaves fm and gm alone,
-- because music runs on other sites and never honours it.
local function geminiMediaRows(media)
  local rows = {}
  if not media then return rows end
  local function row(label, left, total, renewsAt, wall, bound, takes)
    local title
    local balance = left and ((takes and (takes .. "/") or "") .. tostring(left))
    if wall then
      title = rowTitle("", label, { effective_pct = 100, resets_at = wall }, false, true, false, { pct = "" })
    elseif left and total and total > 0 then
      local used = math.max(0, total - left)
      title = rowTitle("", label, { effective_pct = used / total * 100, resets_at = renewsAt }, false, used >= total,
        false, { reset = not renewsAt and balance or nil })
    elseif left or bound then
      title = rowTitle("", label, nil, false, false, false, { pct = "", reset = balance or "" })
    else
      return
    end
    rows[#rows + 1] = { title = title, disabled = true }
  end
  row("fv", media.credits, media.creditsTotal, media.creditsRenewsAt, media.videoWall, media.bound, media.takesLeft)
  if media.musicSignedIn then
    row("fm", media.musicCredits, media.musicCreditsTotal, media.musicCreditsRenewsAt, media.flowMusicWall, true)
  end
  row("gm", nil, nil, nil, media.musicWall)
  return rows
end

local vendorRefreshErrors, refreshErrorItem, appendRefreshErrorRows

local function lateAge(age, late)
  if not late then return age end
  return age and (age .. " ⧖") or "⧖"
end

-- The threshold travels in the store, but the age is taken here: a collector starved past its
-- timeout writes nothing, so a verdict it stamped would freeze at "fresh".
local function staleSeconds(asOf, staleAfter)
  local timestamp = parseTime(asOf)
  if not timestamp or type(staleAfter) ~= "number" then return nil end
  local seconds = os.time() - timestamp
  if seconds > staleAfter then return seconds end
  return nil
end

local function accountAgeText(asOf, late, staleAfter, alarm)
  local seconds = staleSeconds(asOf, staleAfter)
  if seconds then return "stale " .. style.age(seconds), true, true end
  return lateAge(formatAccountAge(asOf), late), alarm, false
end

local function blockAuthNeeded(vendorKey, block)
  local authStatus = type(block.auth) == "table" and block.auth.status or nil
  if vendorKey == "grok" then
    return authStatus == "needs_login" or (block.auth_needed == true and authStatus ~= "expired")
  end
  return block.auth_needed == true
end

-- Parked is read from worker-model and never from the store: the collector writes no entry for a
-- parked vendor, so the store cannot tell "paused" from "not installed".
local function pausedRow(vendorKey, label)
  return {
    title = infoTitle(label .. ": paused"),
    menu = {{ title = "Resume", fn = function() M.resumeVendor(vendorKey) end }},
  }
end

local function appendOpenCode(menu, limits, paused)
  if paused and paused.opencode then
    table.insert(menu, pausedRow("opencode", "OpenCode Go"))
    return
  end
  local vendor = limits and type(limits.vendors) == "table" and limits.vendors.opencode
  local accounts = (type(vendor) == "table" and type(vendor.accounts) == "table")
    and vendor.accounts or {}
  -- One refresh for the leg, in the section header every other vendor carries its own in. Per
  -- account there is nothing to offer: a check is one real completion, and the leg is refreshed
  -- whole or not at all, never one row at a time.
  local vendorErrs, late = vendorRefreshErrors("opencode", vendor)
  -- An empty roster is still a section when the leg reported an error: opencode lights the ⚠ in
  -- the title, and a warning with no row under it explaining it is unreachable.
  if #accounts == 0 and #vendorErrs == 0 and not late[""] then return end
  local headerTitle = infoTitle("OpenCode Go")
  if late[""] then headerTitle = headerTitle .. metaTitle("  ⧖") end
  table.insert(menu, {
    title = headerTitle,
    menu = {
      { title = "Hard refresh", fn = M.hardRefreshOpenCode },
      { title = "Pause", fn = function() M.setWorkerPaused("opencode", true) end },
    },
  })
  local rostered = {}
  for _, account in ipairs(accounts) do rostered[account.account] = true end
  appendRefreshErrorRows(menu, vendorErrs, "opencode", nil, rostered)
  for _, account in ipairs(accounts) do
    local walled = account.walled == true
    local windows = type(account.windows) == "table" and account.windows or {}
    table.insert(menu, {
      title = accountTitle(account.account,
        lateAge(formatAccountAge(account.as_of), late[account.account]), walled,
        nil, nil, nil, nil, account.age_alarm == true),
      disabled = true,
    })
    if walled and #windows > 0 then
      for _, window in ipairs(windows) do
        table.insert(menu, {
          title = rowTitle("", window.window,
            { effective_pct = 100, resets_at = window.resets_at },
            false, true, false, { pct = "" }),
          disabled = true,
        })
      end
    else
      table.insert(menu, {
        title = rowTitle("", "", nil, false, false, false, { pct = "", reset = "" }),
        disabled = true,
      })
    end
    appendRefreshErrorRows(menu, vendorErrs, "opencode", account.account)
  end
end

-- The reserve is the key owner's floor: only limit - reserve is ours, so the bar fills over that share.
local function appendElevenLabs(menu, limits)
  local block = limits and type(limits.elevenlabs) == "table" and limits.elevenlabs
  local accounts = block and type(block.accounts) == "table" and block.accounts or {}
  if #accounts == 0 then return end
  table.insert(menu, { title = infoTitle("ElevenLabs") })
  local age = formatAccountAge(block.as_of)
  for _, account in ipairs(accounts) do
    local used, limit = tonumber(account.used), tonumber(account.limit)
    local share = limit and limit - (tonumber(account.reserve) or 0)
    local pct = used and share and (share > 0 and math.min(100, used / share * 100) or 100)
    local atLimit = pct ~= nil and pct >= 100
    table.insert(menu, { title = accountTitle(account.name or account.account, age, atLimit) })
    table.insert(menu, {
      title = rowTitle("", "mo", { effective_pct = pct, resets_at = account.resets_at }, false, atLimit),
      disabled = true,
    })
  end
  table.insert(menu, { title = "-" })
end

local function windowAbsent(bucket)
  return bucket == nil or (type(bucket) == "table"
    and bucket.used_pct == nil and bucket.used_percentage == nil and bucket.resets_at == nil
    and not (bucket.stale == true and bucket.origin == nil))
end

local function observedWall(block, now)
  local wall = block.worker_wall
  if type(wall) ~= "table" or block.removed == true or (tonumber(wall.resets_at) or 0) <= now then return nil end
  local measured, read = false, true
  for _, key in ipairs({ "five_hour", "weekly" }) do
    local bucket = block[key]
    if type(bucket) == "table" and not windowAbsent(bucket) then
      measured = true
      local pct = bucket.effective_pct or bucket.used_pct
      if bucket.origin == "cached" or (parseTime(bucket.as_of) or 0) <= (tonumber(wall.recorded_at) or 0)
        or type(pct) ~= "number" or math.ceil(pct) >= 100 then read = false end
    end
  end
  if measured and read then return nil end
  return wall
end

-- Mirrors limits_wall_view in share/limits-view.sh.
local function wallView(block, now)
  local wall = observedWall(block, now)
  if not wall then return nil end
  local windows = {}
  for _, key in ipairs({ "five_hour", "weekly" }) do
    local bucket = block[key]
    if type(bucket) == "table" and not windowAbsent(bucket) then
      local reset = parseTime(bucket.resets_at)
      local used = tonumber(bucket.used_pct)
      local eff = -1
      if used then
        if reset and reset <= now then eff = 0 else eff = tonumber(bucket.effective_pct) or used end
      end
      windows[#windows + 1] = { window = key, eff = eff, reset = reset and reset > now and reset or nil }
    end
  end
  if #windows == 0 then windows = { { window = "weekly", eff = -1 } } end
  local mostUsed = windows[1]
  for _, w in ipairs(windows) do
    if w.eff > mostUsed.eff then mostUsed = w end
  end
  if wall.guessed == true then return { window = mostUsed.window, resets_at = mostUsed.reset } end
  local target, nearest = tonumber(wall.resets_at), nil
  for _, w in ipairs(windows) do
    if w.reset and (not nearest or math.abs(w.reset - target) < math.abs(nearest.reset - target)) then
      nearest = w
    end
  end
  return { window = (nearest or mostUsed).window, resets_at = target }
end

local function bucketAtLimit(bucket)
  return type(bucket) == "table" and (tonumber(bucket.effective_pct) or 0) >= 100
end

-- Keyed by path, inode, mtime and size, since the stores are replaced by rename. A file modified in
-- the current second is never kept: a same-size in-place rewrite inside one mtime tick would read
-- as unchanged. Callers must not mutate what it returns.
local statCache = {}

local function statCached(path, load)
  local attrs = hs.fs.attributes(path)
  if not attrs then statCache[path] = nil return load() end
  local key = string.format("%s:%s:%s", attrs.ino or "", attrs.modification or "", attrs.size or "")
  local hit = statCache[path]
  if hit and hit.key == key then return table.unpack(hit.values, 1, hit.values.n) end
  local values = table.pack(load())
  local settled = type(attrs.modification) == "number" and os.time() > attrs.modification
  statCache[path] = settled and { key = key, values = values } or nil
  return table.unpack(values, 1, values.n)
end

-- The bench's own store, spelled the way bin/review-bench spells it: a menu reading a different
-- one would report on records nobody is writing. Class names are the snapshot's own keys.
local DOCTOR_STALE_S = 24 * 3600

local function doctorSnapshotPath()
  if M.doctorSnapshotPath then return M.doctorSnapshotPath end
  local override = os.getenv("WORKER_STATS_DIR")
  if override and override ~= "" then return override .. "/doctor-snapshot.json" end
  local base = os.getenv("CLAUDEB_DIR")
  if not base or base == "" then base = home .. "/.claude-profiles/.claudeb" end
  return base .. "/worker-stats/doctor-snapshot.json"
end

local function readDoctorSnapshot()
  local path = doctorSnapshotPath()
  local ok, decoded = pcall(statCached, path, function()
    local file = io.open(path, "r")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return hs.json.decode(contents)
  end)
  if not ok or type(decoded) ~= "table" or type(decoded.anomalies) ~= "table" then return nil end
  return decoded
end

-- A collector that stopped running is itself the finding: the counts below would go on reading
-- clean off a document nothing has rewritten since.
local function doctorStaleSuffix(asOf)
  local stamp = tonumber(asOf)
  if not stamp then return "" end
  local age = os.time() - stamp
  if age < DOCTOR_STALE_S then return "" end
  return " · stale · scanned " .. style.ago(age)
end

local function readLlmLimits()
  local ok, result, reason = pcall(statCached, M.cachePath, function()
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

-- The menu speaks the collector's vendor keys; the worker-model file spells Claude "claudeb".
local WORKER_MODEL_PREFIX = {
  claude = "claudeb", codex = "codex", gemini = "gemini", grok = "grok",
}
local WORKER_ROLES = { "workers", "reviewers" }

-- OpenCode has no roles, no pin and no worker-pick leg, but review-bench staffs it, so it is
-- parkable like any other vendor and needs its own prefix table.
local PAUSE_VENDOR_PREFIX = {
  claude = "claudeb", codex = "codex", gemini = "gemini", grok = "grok", opencode = "opencode",
  light = "light",
}

-- Section order of the vendor rows, read by the store-backed render and by the no-data one alike:
-- a parked vendor's row is a switch Egor set, not a reading, so it must not depend on the store.
local MENU_VENDORS = {
  { key = "claude", label = "Claude" },
  { key = "codex", label = "Codex" },
  { key = "grok", label = "Grok" },
  { key = "gemini", label = "Gemini" },
}

local function defaultWorkerRoles()
  local roles = {}
  for vendor in pairs(WORKER_MODEL_PREFIX) do
    roles[vendor] = { workers = true, reviewers = true }
  end
  return roles
end

local function parseWorkerModel()
  local pins, roles, paused, vendorPins = {}, defaultWorkerRoles(), {}, {}
  pcall(function()
    local file = io.open(M.workerModelPath, "r")
    if not file then return end
    local contents = file:read("*a")
    file:close()
    -- First line wins, because every shell reader of this file stops at the first match; a
    -- hand-edited duplicate must not point the menu at one value and the routers at another.
    local seen = {}
    for line in tostring(contents):gmatch("[^\r\n]+") do
      local key, value = line:match("^([%w_]+)=(.*)$")
      if key and not seen[key] then
        seen[key] = true
        for vendor, prefix in pairs(PAUSE_VENDOR_PREFIX) do
          -- Inverted from the role keys: this one names the parked state, so `on` is its veto.
          if key == prefix .. "_paused" then paused[vendor] = value == "on" end
        end
        for vendor, prefix in pairs(WORKER_MODEL_PREFIX) do
          if key == prefix .. "_profile" then
            local trimmed = (value or ""):match("^%s*(.-)%s*$") or ""
            -- `*` pins the vendor, not an account named star; leftover rows would invent a `*` row.
            if trimmed == "*" then
              vendorPins[vendor] = true
            else
              local set = {}
              for name in string.gmatch(value, "[^,]+") do
                name = name:match("^%s*(.-)%s*$")
                if name ~= "" and name ~= "*" then set[name] = true end
              end
              pins[vendor] = set
            end
          else
            for _, role in ipairs(WORKER_ROLES) do
              -- Only the literal "off" is a veto, which is what worker-pick and review-bench read.
              if key == prefix .. "_" .. role then roles[vendor][role] = value ~= "off" end
            end
          end
        end
      end
    end
  end)
  return pins, roles, paused, vendorPins
end

local function readWorkerModel()
  return statCached(M.workerModelPath, parseWorkerModel)
end

local function baseEnvironment()
  local environment = {
    HOME = os.getenv("HOME"),
    PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" .. os.getenv("HOME") .. "/.local/bin:/usr/sbin",
  }
  -- Everything launched from here reads or writes the store this menu just rendered. A Hammerspoon
  -- started with these set would otherwise send a wall probe to one store and read another —
  -- LLM_LIMITS_CACHE included, since opencode-go picks its probe targets out of that cache.
  for _, name in ipairs({ "WORKER_STATS_DIR", "CLAUDEB_DIR", "LLM_LIMITS_CACHE", "CODEXB_PROFILES_DIR" }) do
    local value = os.getenv(name)
    if value and value ~= "" then environment[name] = value end
  end
  return environment
end

local function newCollectorTask(callback, args, envExtra)
  local task = hs.task.new(M.collectorPath, callback, args or {})
  if task then
    local environment = baseEnvironment()
    if type(envExtra) == "table" then
      for k, v in pairs(envExtra) do environment[k] = v end
    end
    task:setEnvironment(environment)
  end
  return task
end

-- LLM_LIMITS_ACTION_LOG is a harness's: one loading this module inside the live Hammerspoon hands it
-- through its own os.getenv, so fixture actions never reach the log every later diagnosis reads.
M.actionLogPath = os.getenv("LLM_LIMITS_ACTION_LOG") or os.getenv("HOME") .. "/.hammerspoon/llm_limits_actions.log"

-- Every vendor command the menu launches, with its exit code and the exit code of the collect
-- that follows it. Without this the only trace an action left was the mtime of the pool file,
-- which records effective changes and says nothing about a click that did nothing.
local function logAction(event, detail)
  local ok = pcall(function()
    local file = io.open(M.actionLogPath, "a")
    if not file then return end
    file:write(string.format("%s  %-18s %s\n", os.date("%Y-%m-%d %H:%M:%S"), event,
      tostring(detail or "")))
    file:close()
  end)
  return ok
end

-- What the menu shows for "in the pool" comes from the collector cache, so between a
-- successful toggle and the collect that follows it the rebuilt menu still showed the old state —
-- and clicking again, which is the natural response, produced the same command, which the
-- in-flight guard in runAccountCommand then swallowed in silence. The value the command just
-- established wins until a collect confirms it, and never longer than this TTL, so a command that
-- silently changed nothing cannot keep the menu lying.
local poolOverrides = {}
local poolOverrideTtl = 30
local removalOverrides = {}

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

local function setRemovalOverride(vendor, account, pending)
  local key = poolOverrideKey(vendor, account)
  removalOverrides[key] = pending and { at = os.time() } or nil
end

local function removalPending(vendor, account)
  local key = poolOverrideKey(vendor, account)
  local override = removalOverrides[key]
  if not override then return false end
  if os.time() - override.at > poolOverrideTtl then
    removalOverrides[key] = nil
    return false
  end
  return true
end

local taskRegistry = {}
local nextTaskId = 0
local lastCollectEpoch = 0
local runtimeGlobalError = nil

local function errorState(value)
  if type(value) == "table" and type(value.cause) == "string" then
    local class = value.class
    if type(class) ~= "string" or class == "" then class = nil end
    return {
      cause = value.cause,
      at = tonumber(value.at),
      class = class,
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
  logAction("routing-launch", "worker-pick")
  local task = hs.task.new("/usr/bin/nice", function(exitCode, stdOut)
    routingTask = nil
    if exitCode == 0 and type(stdOut) == "string" and stdOut ~= "" then
      M.routingCache = { text = stdOut, at = os.time() }
      M.routingFailed = false
      logAction("routing-done", "worker-pick exit=0")
    else
      M.routingFailed = true
      logAction("routing-failed", "worker-pick exit=" .. tostring(exitCode))
    end
    notifyRefreshState()
    if routingRefreshPending then
      routingRefreshPending = false
      M.refreshRouting()
    end
  end, { "-n", "10", M.workerPickPath, "--menu" })
  if not task then
    M.routingFailed = true
    logAction("routing-failed", "worker-pick could not start")
    notifyRefreshState()
    return
  end
  task:setEnvironment(baseEnvironment())
  routingTask = task
  local ok, started = pcall(task.start, task)
  if not ok or not started then
    routingTask = nil
    M.routingFailed = true
    logAction("routing-failed", "worker-pick start failed")
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

local readChats, stuckQueues

local function busyNow()
  purgeTasks()
  for _, entry in pairs(taskRegistry) do
    if entry.kind ~= "passive" and taskAlive(entry.task) then return true end
  end
  return false
end
style.busySource("LLM limits", busyNow)

function M.refreshState()
  local busy = busyNow()
  local limits, readError = readLlmLimits()
  local globalError = errorState(limits and limits.refresh_error) or runtimeGlobalError
  if not globalError and not limits and readError then
    globalError = { cause = readError, at = os.time() }
  end
  local vendorErrors = {}
  -- One account's failed refresh retries next cycle and shows as its own ⚠ row, so only a store
  -- nobody can read warns the menubar. A parked vendor renders no error rows at all.
  local heartbeat = limits and type(limits.refresh_heartbeat) == "table" and limits.refresh_heartbeat
  local stalledSince = heartbeat and heartbeat.stalled == true and tonumber(heartbeat.last_tick_at) or nil
  local pausedVendors = select(3, readWorkerModel())
  local staleCount, staleOldest = 0, nil
  local staleAfter = limits and tonumber(limits.account_stale_after_s)
  if staleAfter and type(limits.vendors) == "table" then
    for _, entry in ipairs(MENU_VENDORS) do
      local vendor = limits.vendors[entry.key]
      if not pausedVendors[entry.key] and type(vendor) == "table" then
        local rows = { vendor }
        for _, block in ipairs(type(vendor.accounts) == "table" and vendor.accounts or {}) do
          rows[#rows + 1] = block
        end
        for _, block in ipairs(rows) do
          if type(block) == "table" and block.stale_watch == true
              and not (block.account and removalPending(entry.key, block.account)) then
            local seconds = staleSeconds(block.as_of, staleAfter)
            if seconds then
              staleCount = staleCount + 1
              staleOldest = math.max(staleOldest or 0, seconds)
            end
          end
        end
      end
    end
  end
  local warning = globalError ~= nil or stalledSince ~= nil or staleCount > 0
  if limits and type(limits.vendors) == "table" then
    for _, name in ipairs({ "claude", "codex", "gemini", "grok", "opencode" }) do
      local vendor = limits.vendors[name]
      if pausedVendors[name] then vendor = nil end
      local entries = vendorRefreshErrors(name, vendor)
      if #entries > 0 then vendorErrors[name] = entries end
    end
  end
  local holds = stuckQueues()
  return {
    busy = busy,
    warning = warning or #holds > 0,
    refreshWarning = warning,
    holds = holds,
    holdText = holds[1] and holds[1].text,
    prefix = #holds > 0 and "⚠ " or busy and style.BUSY or (warning and "⚠ " or ""),
    globalError = globalError,
    stalledSince = stalledSince,
    staleCount = staleCount,
    staleOldest = staleOldest,
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

local function resolveGrokb()
  return resolveCommand(M.grokbCmd or "grokb")
end

local function taskRunning(task)
  if not task then return false end
  local ok, running = pcall(task.isRunning, task)
  return ok and running == true
end

function M.diagnosticsEnvironment()
  local environment = baseEnvironment()
  for _, name in ipairs({ "LLM_DOCTOR_DIR", "LLM_DOCTOR_LEDGER", "WORKER_STATS_DIR", "WORKER_RUN_DIR", "IMAGE_LEG_LOG",
      "HARNESS_DOCTOR_DIR", "UPDATER_DOCTOR_DIR", "DOCTORS_DIR" }) do
    local override = os.getenv(name)
    if override and override ~= "" then environment[name] = override end
  end
  return environment
end

local function startDiagnosticsTask(field, path, args, onExit)
  if taskRunning(M[field]) then return end
  local task = hs.task.new(path, function(exitCode, _, stdErr)
    M[field] = nil
    style.busyChanged()
    logAction("diagnostics-exit", path .. " exit=" .. tostring(exitCode)
      .. (exitCode ~= 0 and stdErr and stdErr ~= "" and (" " .. stdErr:gsub("%s+$", "")) or ""))
    if onExit then onExit(exitCode) end
  end, args)
  if not task then return end
  task:setEnvironment(M.diagnosticsEnvironment())
  M[field] = task
  logAction("diagnostics-start", path .. " " .. table.concat(args, " "))
  task:start()
  style.busyChanged()
end

function M.rescanDoctor()
  startDiagnosticsTask("doctorRescanTask", resolveCommand(M.reviewBenchCmd or "review-bench"),
    { "doctor", "--snapshot" }, function(exitCode)
      local snapshot = exitCode == 0 and readDoctorSnapshot() or nil
      local total = snapshot and tonumber(snapshot.total) or nil
      hs.alert.show(total and string.format("Review machinery: %d", total) or "Review machinery: rescan failed", 2.5)
    end)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", [['\'']]) .. "'"
end

local function readTextFile(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  return contents
end

-- Flow credits and the media walls (shared-invariants row `de`) are only ever read here: the one
-- way to refresh them launches Chrome, so the row states the reading's age instead.
-- share/gemini_web.py's Flow budget: takes per account in a rolling day, unless the meta overrides it.
local FLOW_DAY_TAKES, FLOW_DAY_S = 10, 24 * 3600

local function geminiWebDir()
  local override = os.getenv("GEMINI_WEB_DIR")
  if override and override ~= "" then return override end
  return home .. "/.gemini-web"
end

local function readJsonTable(path)
  local decoded = statCached(path, function()
    local contents = readTextFile(path)
    if not contents then return nil end
    local ok, value = pcall(hs.json.decode, contents)
    return ok and type(value) == "table" and value or nil
  end)
  return decoded
end
M.readJsonTable = readJsonTable

-- A gemini-web profile matching no roster name, even by its email's local part, gets no row: the
-- store's roster is the only roster.
-- The profile names with an account file in the gemini-web store, sorted; none without a store.
local function geminiWebAccounts(dir)
  local ok, names = pcall(function()
    local found = {}
    for file in hs.fs.dir(dir .. "/accounts") do
      local name = file:match("^(.+)%.json$")
      if name then found[#found + 1] = name end
    end
    table.sort(found)
    return found
  end)
  return ok and names or {}
end

-- Owner actions: what only Egor can do. A web route stopped on a code 4 (signed out, a one-time Agree, a
-- captcha) leaves owner_actions in its account file (share/gemini_web.py note_owner_action), and a profile
-- without cookies was never signed in. Each is a red row under its account plus the account's "!", and
-- M.ownerActionCount() puts "!" on the menubar from these same reads.
-- One table, not file locals: the chunk sits at Lua's 200-local limit.
local owner = { routeLabels = { ["chatgpt-web"] = "im", flow = "fv", ["flow-music"] = "fm",
  ["gemini-app"] = "gm", aistudio = "as", suno = "su" } }

function owner.fileExists(path)
  local handle = io.open(path, "r")
  if handle then handle:close() end
  return handle ~= nil
end

function owner.needRows(needs)
  local rows = {}
  for _, need in ipairs(needs or {}) do
    rows[#rows + 1] = { disabled = true,
      title = infoTitle(string.format("%-6s  %-2s  %s", "", need.label, need.text), false, false, true) }
  end
  return rows
end

-- `only` keeps one route (Suno's own section), `skip` leaves one out (drawn in that section instead).
function owner.webNeeds(meta, signedIn, loginLabel, only, skip)
  local needs, seen = {}, {}
  if not signedIn then
    needs[1], seen[loginLabel] = { label = loginLabel, text = "login needed" }, true
  end
  local actions = type(meta.owner_actions) == "table" and meta.owner_actions or {}
  local routes = {}
  for route in pairs(actions) do
    if route ~= skip and (not only or route == only) then routes[#routes + 1] = route end
  end
  table.sort(routes)
  for _, route in ipairs(routes) do
    local label = owner.routeLabels[route] or route:sub(1, 2)
    local reason = type(actions[route]) == "table" and tostring(actions[route].reason or "") or ""
    if not seen[label] then
      seen[label] = true
      needs[#needs + 1] = { label = label,
        text = (reason:find("signed[^;]*out") or reason:find("no browser login")) and "login needed" or "needs you" }
    end
  end
  return needs
end

function owner.chatgptWebDir()
  local override = os.getenv("CHATGPT_WEB_DIR")
  if override and override ~= "" then return override end
  return home .. "/.chatgpt-web"
end

-- The browse registry worker-run keeps (share/worker-run-browse.sh): a Claude account whose Chrome
-- profile lost its claude.ai login, or has none, waits for Egor's sign-in and `worker-run browse --enroll`.
function owner.browseNeeds(acct)
  local runs = os.getenv("WORKER_RUN_DIR")
  runs = runs and runs ~= "" and runs or home .. "/.cache/claude-worker-runs"
  local entry = (readJsonTable(runs .. "/browse/accounts.json") or {})[acct]
  local status = type(entry) == "table" and entry.status or nil
  if status == "needs-login" or status == "no-profile" then return {{ label = "br", text = "login needed" }} end
  return {}
end

-- Only once tg-read is set up (its api.txt): a lost session or the marker its refused run leaves.
function owner.telegramLoginNeeded()
  local dir = os.getenv("TG_READ_CONFIG")
  dir = dir and dir ~= "" and dir or home .. "/.config/telegram"
  return owner.fileExists(dir .. "/api.txt")
    and (not owner.fileExists(dir .. "/session.session") or owner.fileExists(dir .. "/login-needed"))
end

local function geminiMediaState(roster, now)
  local dir, state = geminiWebDir(), {}
  local names = geminiWebAccounts(dir)
  local videoWalls = readJsonTable(dir .. "/walls.json") or {}
  local musicWalls = readJsonTable(dir .. "/music-walls.json") or {}
  local flowMusicWalls = readJsonTable(dir .. "/flow-music-walls.json") or {}
  local function standing(walls, name)
    local untilEpoch = tonumber(walls[name])
    return untilEpoch and untilEpoch > now and untilEpoch or nil
  end
  for _, name in ipairs(names) do
    local meta = readJsonTable(dir .. "/accounts/" .. name .. ".json") or {}
    local acct = name
    if not roster[acct] then
      acct = type(meta.email) == "string" and meta.email:lower():match("^([^@]+)@") or nil
    end
    if acct and roster[acct] and not state[acct] then
      local cookies = type(meta.email) == "string" and io.open(dir .. "/profiles/" .. name .. "/Default/Cookies", "r")
      if cookies then cookies:close() end
      local takes = 0
      for _, stamp in ipairs(type(meta.flow_takes) == "table" and meta.flow_takes or {}) do
        if tonumber(stamp) and now - tonumber(stamp) < FLOW_DAY_S then takes = takes + 1 end
      end
      state[acct] = {
        bound = cookies and true or false,
        takesLeft = meta.flow_uncapped ~= true
          and math.max(0, (tonumber(meta.flow_day_takes) or FLOW_DAY_TAKES) - takes) or nil,
        credits = tonumber(meta.credits),
        creditsTotal = tonumber(meta.credits_total), creditsRenewsAt = tonumber(meta.credits_renews_at),
        musicSignedIn = meta.music_signed_in == true,
        musicCredits = tonumber(meta.music_credits),
        musicCreditsTotal = tonumber(meta.music_credits_total),
        musicCreditsRenewsAt = tonumber(meta.music_credits_renews_at),
        videoWall = standing(videoWalls, name), musicWall = standing(musicWalls, name),
        flowMusicWall = standing(flowMusicWalls, name),
        needs = owner.webNeeds(meta, cookies and true or false, "fv", nil, "suno"),
      }
    end
  end
  return state
end

-- Only an account with a file in the web store: none means Egor declined the web route at `add`.
function owner.accountNeeds(vendorKey, acct, geminiMedia)
  if vendorKey == "claude" then return owner.browseNeeds(acct) end
  if vendorKey == "codex" then
    local dir = owner.chatgptWebDir()
    local meta = readJsonTable(dir .. "/accounts/" .. acct .. ".json")
    return meta and owner.webNeeds(meta, owner.fileExists(dir .. "/profiles/" .. acct .. "/Default/Cookies"), "im")
      or {}
  end
  local media = vendorKey == "gemini" and geminiMedia[acct]
  return media and media.needs or {}
end

-- Suno, after ElevenLabs: one 1d row per account suno-music has seen signed in, read from the same
-- gemini-web account files; one it has seen signed out keeps its row, with "!" and "su  login needed". Free credits renew daily on a UTC clock the files do not carry, so the reset
-- column holds the credits left. Download unlocks are not shown: with none left a song is recorded as it
-- plays (2026-10-23), so they no longer decide whether a file comes. Red when the account cannot make a song:
-- a standing wall or credits under one generation.
local SUNO_GENERATION_CREDITS = 10

local function appendSuno(menu, now)
  local dir, accounts = geminiWebDir(), {}
  for _, name in ipairs(geminiWebAccounts(dir)) do
    local meta = readJsonTable(dir .. "/accounts/" .. name .. ".json") or {}
    if meta.suno_signed_in ~= nil then accounts[#accounts + 1] = { name = name, meta = meta } end
  end
  if #accounts == 0 then return end
  local walls = readJsonTable(dir .. "/suno-walls.json") or {}
  table.insert(menu, { title = infoTitle("Suno") })
  for _, account in ipairs(accounts) do
    local meta = account.meta
    local left, total = tonumber(meta.suno_credits), tonumber(meta.suno_credits_limit)
    local wall = tonumber(walls[account.name])
    wall = wall and wall > now and wall or nil
    local atLimit = wall ~= nil or (left ~= nil and left < SUNO_GENERATION_CREDITS)
    local title
    if wall then
      title = rowTitle("", "1d", { effective_pct = 100, resets_at = wall }, false, true, false,
        { pct = "" })
    elseif left and total and total > 0 then
      title = rowTitle("", "1d", { effective_pct = math.max(0, total - left) / total * 100 }, false, atLimit, false,
        { reset = tostring(left) })
    else
      title = rowTitle("", "1d", nil, false, atLimit, false, { pct = "", reset = left and tostring(left) or "" })
    end
    local needs = owner.webNeeds(meta, meta.suno_signed_in ~= false, "su", "suno")
    local name = account.name
    table.insert(menu, { title = accountTitle(name, formatAccountAge(meta.suno_at), atLimit, #needs > 0),
      menu = #needs > 0 and {{ title = "Log in to Suno…", fn = function() M.loginSuno(name) end }} or nil })
    if meta.suno_signed_in ~= false then table.insert(menu, { title = title, disabled = true }) end
    for _, row in ipairs(owner.needRows(needs)) do table.insert(menu, row) end
  end
  table.insert(menu, { title = "-" })
end

-- How many rows carry "!": the same reads the menu draws them from, for the menubar title's own "!".
-- Cached a minute, since the title updates far more often than any login changes.
function M.ownerActionCount()
  local now = os.time()
  if owner.countCache and now - owner.countCache.at < 60 then return owner.countCache.count end
  local count, limits = 0, readLlmLimits()
  local paused = select(3, readWorkerModel()) or {}
  local vendors = type(limits) == "table" and type(limits.vendors) == "table" and limits.vendors or {}
  for _, entry in ipairs(MENU_VENDORS) do
    local vendor = vendors[entry.key]
    if type(vendor) == "table" and not paused[entry.key] then
      local blocks, roster = {}, {}
      for _, block in ipairs(type(vendor.accounts) == "table" and vendor.accounts or {}) do
        if type(block) == "table" and type(block.account) == "string" and block.removed ~= true
            and not removalPending(entry.key, block.account) then
          blocks[#blocks + 1], roster[block.account] = block, true
        end
      end
      if #blocks == 0 then
        if vendor.auth_needed == true then count = count + 1 end
      else
        local media = entry.key == "gemini" and geminiMediaState(roster, now) or {}
        for _, block in ipairs(blocks) do
          if blockAuthNeeded(entry.key, block) or block.needs_user_entry == true
              or #owner.accountNeeds(entry.key, block.account, media) > 0 then
            count = count + 1
          end
        end
      end
    end
  end
  local dir = geminiWebDir()
  for _, name in ipairs(geminiWebAccounts(dir)) do
    local meta = readJsonTable(dir .. "/accounts/" .. name .. ".json") or {}
    if meta.suno_signed_in ~= nil and #owner.webNeeds(meta, meta.suno_signed_in ~= false, "su", "suno") > 0 then
      count = count + 1
    end
  end
  if owner.telegramLoginNeeded() then count = count + 1 end
  owner.countCache = { at = now, count = count }
  return count
end

local DOCTOR_REPO_WIDTH, DOCTOR_CHAT_WIDTH = 20, 24

local function cells(text) return utf8.len(text) or #text end
local function padCells(text, width, right)
  local spaces = string.rep(" ", math.max(0, width - cells(text)))
  return right and (spaces .. text) or (text .. spaces)
end
local function clipHead(text, width)
  if cells(text) <= width then return text end
  return text:sub(1, utf8.offset(text, width) - 1) .. "…"
end
local function clipTail(text, width)
  if cells(text) <= width then return text end
  return "…" .. text:sub(utf8.offset(text, -(width - 1)))
end

-- The folder is the project; a merged review workspace is named by its kind, its hash being noise.
local function projectName(path)
  path = tostring(path or ""):gsub("/+$", "")
  local base = path:match("([^/]+)$") or ""
  local parent = path:match("([^/]+)/[^/]+$") or ""
  if parent == "merged" and base:match("^%x+$") then return "merged" end
  return base
end

local function doctorDetailRows(rows)
  local lines, widths = {}, { 0, 0, 0 }
  for _, row in ipairs(rows) do
    local where = tostring(row.where or "")
    local repo, chat = where:match("^(.-) · (.*)$")
    if not repo then
      if where:sub(1, 1) == "/" or where:sub(1, 1) == "~" then repo, chat = where, "" else repo, chat = "", where end
    end
    local line = {
      tostring(row.age or ""),
      clipTail(projectName(repo), DOCTOR_REPO_WIDTH),
      clipHead(chat, DOCTOR_CHAT_WIDTH),
      tostring(row.label or ""),
    }
    for c = 1, 3 do widths[c] = math.max(widths[c], cells(line[c])) end
    lines[#lines + 1] = line
  end
  local titles = {}
  for _, line in ipairs(lines) do
    local title = infoTitle("  " .. padCells(line[1], widths[1], true), false, true)
    if widths[2] > 0 then title = title .. infoTitle("  " .. padCells(line[2], widths[2])) end
    if widths[3] > 0 then title = title .. infoTitle("  " .. padCells(line[3], widths[3])) end
    if line[4] ~= "" then title = title .. infoTitle("  " .. line[4], false, true) end
    titles[#titles + 1] = title
  end
  return titles
end

-- The click hands the chat over the way Instruction file changes does: bin/chats prints the terminal
-- command that reopens it under the account worker-pick names. A row with no chat copies its run
-- id, the one handle review-bench report understands.
local function copyChatCommand(row)
  local session = tostring(row.session or "")
  local path = M.chatsCmd or (repoRoot and repoRoot .. "/bin/chats")
  if session == "" or not path then
    local id = tostring(row.id or "")
    if id ~= "" then
      hs.pasteboard.setContents(id)
      hs.alert.show("copied " .. id, 1.5)
    end
    return
  end
  local task
  task = hs.task.new(path, function(code, stdout, stderr)
    task = nil
    local command = code == 0 and (stdout or ""):match("^[^\r\n]+") or nil
    if not command then
      hs.alert.show("no command: " .. ((stderr or ""):match("[^\r\n]+") or "unknown error"), 3)
      return
    end
    hs.pasteboard.setContents(command)
    hs.alert.show("copied: open chat in a terminal", 1.5)
  end, { "--open-command", session })
  if not task or not task:start() then
    task = nil
    hs.alert.show("could not start chats", 3)
  end
end

-- A closed chat's leftovers, or an orphan nothing runs any more, end through bin/chat-load stop, which
-- works the processes out again from the live table; its one line is the answer.
local function stopChatRow(key)
  local path = M.chatLoadCmd or (repoRoot and repoRoot .. "/bin/chat-load")
  if not path then return end
  local task
  task = hs.task.new(path, function(_, stdout, stderr)
    task = nil
    hs.alert.show((stdout or ""):match("[^\r\n]+") or (stderr or ""):match("[^\r\n]+") or "stop: no answer", 3)
  end, { "stop", key })
  if not task or not task:start() then
    task = nil
    hs.alert.show("could not start chat-load", 3)
  end
end

-- A live chat's Terminal tab comes to the front; a closed chat, or one with no terminal (a
-- headless worker), copies its reopen command instead.
local function focusChat(row)
  local pid = math.tointeger(tonumber(row.pid))
  local gate = M.chatGate or package.loaded["chat_gate"]
  if not pid or type(gate) ~= "table" or type(gate.selectTabByTty) ~= "function" then
    copyChatCommand(row)
    return
  end
  local task
  task = hs.task.new("/bin/ps", function(_, stdout)
    task = nil
    local tty = (stdout or ""):match("(ttys%d+)")
    if not (tty and gate.selectTabByTty("/dev/" .. tty)) then copyChatCommand(row) end
  end, { "-o", "tty=", "-p", tostring(pid) })
  if not task or not task:start() then
    task = nil
    copyChatCommand(row)
  end
end

local LLM_DOCTOR_FRESH_S = 300
local DOCTOR_DEFAULT_H = 24
local DOCTOR_WINDOWS = {
  { hours = 3, label = "3h" }, { hours = 6, label = "6h" }, { hours = 12, label = "12h" }, { hours = 24, label = "24h" },
  { hours = 72, label = "3d" }, { hours = 168, label = "7d" },
}
local DOCTOR_BLOCK_NAMES = { reviewers = "Reviewers", workers = "Workers", light = "Light", image = "Image" }
-- The collector's own column words, in its order; blank for zero so a class keeps its column.
local DOCTOR_MODEL_COLUMNS = { "walled", "off", "cap", "stalled", "failed", "theirs", "slow", "escaped", "retried" }
local DOCTOR_COUNTED = { new = true, open = true, regressed = true }
local lastLlmDoctorKick = 0

local function plural(count, word)
  return string.format("%d %s%s", count, word, count == 1 and "" or "s")
end

local function doctorWindowLabel(hours)
  for _, choice in ipairs(DOCTOR_WINDOWS) do
    if choice.hours == hours then return choice.label end
  end
  return style.age(hours * 3600)
end

local function doctorWindowItem(suffix, onChoose)
  local selected = M.doctorWindowH or DOCTOR_DEFAULT_H
  local choices = {}
  for _, choice in ipairs(DOCTOR_WINDOWS) do
    choices[#choices + 1] = { title = choice.label, checked = selected == choice.hours, fn = function()
      M.doctorWindowH = choice.hours
      if onChoose then onChoose() end
    end }
  end
  return { title = infoTitle("window: " .. doctorWindowLabel(selected) .. (suffix or "")), menu = choices }
end

local function llmDoctorPath()
  if M.llmDoctorPath then return M.llmDoctorPath end
  local override = os.getenv("LLM_DOCTOR_DIR")
  if override and override ~= "" then return override .. "/latest.json" end
  return home .. "/.cache/llm-doctor/latest.json"
end

local function readLlmDoctor()
  local decoded = readJsonTable(llmDoctorPath())
  if type(decoded) ~= "table" or type(decoded.blocks) ~= "table" then return nil end
  return decoded
end

local function llmDoctorSummary(document, total)
  local parts = {}
  local status = document and document.status
  local problems = document and tonumber(document.problem_count)
  if status == "error" then
    parts[#parts + 1] = "collector failed"
  elseif problems then
    if problems > 0 then parts[#parts + 1] = plural(problems, "problem") end
    if status == "blind" then parts[#parts + 1] = "blind" end
  elseif total > 0 then
    parts[#parts + 1] = plural(total, "problem")
  end
  return parts
end

local function kickLlmDoctor(document, force, stale)
  local now = os.time()
  local asOf = type(document) == "table" and (tonumber(document.as_of_s) or tonumber(document.as_of)) or 0
  local selected = M.doctorWindowH or DOCTOR_DEFAULT_H
  local cachedWindow = type(document) == "table" and tonumber(document.window_h) or selected
  local fresh = now - asOf < LLM_DOCTOR_FRESH_S or now - lastLlmDoctorKick < LLM_DOCTOR_FRESH_S
  if not force and not stale and cachedWindow == selected and fresh then return end
  -- A cache over another window is stale whatever its age, but a collector that keeps failing
  -- must not be relaunched on every menu open.
  if not force and (stale or cachedWindow ~= selected) and now - lastLlmDoctorKick < 60 then return end
  if taskRunning(M.llmDoctorTask) then return end
  local path = M.llmDoctorCmd or (repoRoot and repoRoot .. "/bin/llm-doctor")
  if not path then return end
  lastLlmDoctorKick = now
  startDiagnosticsTask("llmDoctorTask", path, { "--window", tostring(selected), "--quiet" }, force and function(exitCode)
    local latest = readLlmDoctor()
    local parts = llmDoctorSummary(latest, 0)
    hs.alert.show("LLM doctor: " .. (exitCode ~= 0 and "refresh failed" or not latest and "no data yet"
      or #parts > 0 and table.concat(parts, " · ") or "ok"), 2.5)
  end or nil)
end

local function doctorTableTitles(rows, right, styles)
  local widths = {}
  for _, row in ipairs(rows) do
    for c, text in ipairs(row) do widths[c] = math.max(widths[c] or 0, cells(text)) end
  end
  local titles = {}
  for index, row in ipairs(rows) do
    local last = 0
    for c = 1, #row do if row[c] ~= "" then last = c end end
    local title
    for c = 1, last do
      if widths[c] > 0 then
        local text = c == last and not right[c] and row[c] or padCells(row[c], widths[c], right[c])
        local style = styles(index, c)
        local piece = infoTitle((title and "  " or "") .. text, style == "warn", style == "dim")
        title = title and (title .. piece) or piece
      end
    end
    titles[index] = title or infoTitle("")
  end
  return titles
end

local function incidentRows(problem)
  local rows = {}
  for _, incident in ipairs(type(problem.incidents) == "table" and problem.incidents or {}) do
    if type(incident) == "table" then
      local detail = tostring(incident.detail or "")
      local surface = tostring(incident.surface or "")
      if surface == "judge" or surface == "panel" or surface == "video" then detail = surface .. ": " .. detail end
      if incident.attempt and incident.attempt ~= "final" then detail = detail .. " · " .. tostring(incident.attempt) end
      rows[#rows + 1] = { tostring(incident.age or ""), tostring(incident.model or ""),
        tostring(incident.project or ""), tostring(incident.tier or ""),
        clipHead(type(incident.chat) == "string" and incident.chat or "", 28), detail }
    end
  end
  return rows
end

local function problemBrief(problem, block, windowLabel)
  local ledger = type(problem.ledger) == "table" and problem.ledger or nil
  local lines = { string.format("LLM doctor, %s block, last %s: %s — %s on %s, %s%s.",
    DOCTOR_BLOCK_NAMES[block] or block, windowLabel, tostring(problem.label or ""),
    plural(tonumber(problem.count) or 0, "leg"),
    table.concat(type(problem.models) == "table" and problem.models or {}, ", "),
    tostring(problem.status_text ~= "" and problem.status_text or problem.kind or ""),
    ledger and string.format("; ledger %s: %s", tostring(ledger.id), tostring(ledger.title or "")) or "") }
  lines[#lines + 1] = "Incidents, newest first:"
  for _, incident in ipairs(type(problem.incidents) == "table" and problem.incidents or {}) do
    if type(incident) == "table" then
      lines[#lines + 1] = string.format("- %s ago · %s · %s · %s%s · %s · run %s", tostring(incident.age or ""),
        tostring(incident.surface or ""), tostring(incident.model or ""), tostring(incident.project or ""),
        (incident.tier or "") ~= "" and (" · " .. tostring(incident.tier)) or "", tostring(incident.detail or ""),
        tostring(incident.ref or ""))
    end
  end
  local root = repoRoot or "llm-legs"
  lines[#lines + 1] = string.format("Find the cause in the code, fix it or rule it out, and record the verdict as a row"
    .. " in %s/share/doctor-ledger.json (status open, fixed-pending with a fixes[] entry {at, by, files, in: null} the"
    .. " doctor completes once the sweep commits, not-a-bug or weather; docs/doctor-fix.md has the rules)."
    .. " `%s/bin/llm-doctor --block %s --json` prints every field.", root, root, block)
  return table.concat(lines, "\n")
end

local function ownerBrief(entry, windowLabel, hours)
  local root = repoRoot or "llm-legs"
  local block = tostring(entry.block)
  local owner = tostring(entry.owner or "")
  return string.format("You own the %s block of LLM doctor%s. Run `%s/bin/llm-doctor --block %s --window %d`"
    .. " (add --json for every field and each run's ref) and triage its regressed, new and open bugs one by one:"
    .. " find each cause in the code, fix it or rule it out, and record the verdict in %s/share/doctor-ledger.json —"
    .. " one row per cause with status open, fixed-pending (append a fixes[] entry {at, by, files, in: null}; the"
    .. " doctor fills in once the sweep commits), not-a-bug or weather, plus last_reviewed and reviewed_by (docs/doctor-fix.md)."
    .. " Weather (walled, cap, stalled, failed · theirs, slow, retried)"
    .. " is not a bug, and caps are caps: never propose dropping a cell or a vendor or raising a cap."
    .. " Last %s: %s (%d new, %d regressed), %d weather%s.",
    DOCTOR_BLOCK_NAMES[block] or block, owner ~= "" and (" (owner: " .. owner .. ")") or "", root, block, hours,
    root, windowLabel, plural(tonumber(entry.bugs) or 0, "bug"), tonumber(entry.new) or 0,
    tonumber(entry.regressed) or 0, tonumber(entry.weather) or 0,
    (entry.top or "") ~= "" and ("; top: " .. tostring(entry.top)) or "")
end

local function copyText(text, label)
  hs.pasteboard.setContents(text)
  hs.alert.show("copied: " .. label, 1.5)
end

local function problemMenu(problem, block, windowLabel)
  local items = {}
  local ledger = type(problem.ledger) == "table" and problem.ledger or nil
  if ledger then
    items[#items + 1] = { title = infoTitle(tostring(ledger.title or "")), disabled = true }
    local facts = { tostring(ledger.status or "") }
    local fix = type(ledger.fixes) == "table" and ledger.fixes[#ledger.fixes] or nil
    if type(fix) == "table" then
      facts[#facts + 1] = type(fix["in"]) == "string" and ("fixed in " .. fix["in"]) or "fix pending commit"
      if #ledger.fixes > 1 then facts[#facts + 1] = "fixed " .. #ledger.fixes .. "×" end
    end
    if (problem.looked or "") ~= "" then facts[#facts + 1] = tostring(problem.looked) end
    if (ledger.reviewed_by or "") ~= "" then facts[#facts + 1] = "by " .. tostring(ledger.reviewed_by) end
    items[#items + 1] = { title = infoTitle(table.concat(facts, " · "), false, true), disabled = true }
    if (ledger.note or "") ~= "" then
      items[#items + 1] = { title = infoTitle(clipHead(tostring(ledger.note), 110), false, true), disabled = true }
    end
    items[#items + 1] = { title = "-" }
  end
  local rows = incidentRows(problem)
  for _, title in ipairs(doctorTableTitles(rows, { true }, function(_, c)
    return (c == 1 or c == 4) and "dim" or nil
  end)) do
    items[#items + 1] = { title = title, disabled = true }
  end
  if #rows == 0 then items[#items + 1] = { title = infoTitle("no incidents", false, true), disabled = true } end
  local total = tonumber(problem.incidents_total) or #rows
  if total > #rows and #rows > 0 then
    items[#items + 1] = { title = infoTitle(string.format("latest %d of %d", #rows, total), false, true), disabled = true }
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = infoTitle("Copy for an LLM"), fn = function()
    copyText(problemBrief(problem, block, windowLabel), "problem for an LLM")
  end }
  return items
end

local function modelTableMenu(models)
  local rows = { { "model", "legs", "bugs" } }
  for _, name in ipairs(DOCTOR_MODEL_COLUMNS) do rows[1][#rows[1] + 1] = name end
  for _, model in ipairs(models) do
    if type(model) == "table" and type(model.model) == "string" then
      local columns = type(model.columns) == "table" and model.columns or {}
      local bugs = tonumber(model.bugs) or 0
      local row = { model.model, tostring(tonumber(model.legs) or 0), bugs > 0 and tostring(bugs) or "" }
      for _, name in ipairs(DOCTOR_MODEL_COLUMNS) do
        local count = tonumber(columns[name]) or 0
        row[#row + 1] = count > 0 and tostring(count) or ""
      end
      rows[#rows + 1] = row
    end
  end
  local right = {}
  for c = 2, #rows[1] do right[c] = true end
  local items = {}
  for index, title in ipairs(doctorTableTitles(rows, right, function(row, c)
    if row == 1 or c == 2 then return "dim" end
    if c == 3 then return "warn" end
    return nil
  end)) do
    items[#items + 1] = { title = title, disabled = true }
  end
  return items
end

local function blockMenu(entry, windowLabel, hours)
  local block = tostring(entry.block)
  local items = {}
  local owner = tostring(entry.owner or "")
  items[#items + 1] = { title = infoTitle("owner: " .. (owner ~= "" and owner or "unset") .. " · "
    .. plural(tonumber(entry.legs) or 0, "leg") .. " in " .. windowLabel, false, true), disabled = true }
  local bugRows, weatherRows, bugProblems, weatherProblems = {}, {}, {}, {}
  for _, problem in ipairs(type(entry.problems) == "table" and entry.problems or {}) do
    if type(problem) == "table" then
      local row = { tostring(problem.label or ""), tostring(tonumber(problem.count) or 0),
        tostring(problem.spark or ""), tostring(problem.last_seen or ""),
        tostring(problem.status_text or ""),
        table.concat(type(problem.models) == "table" and problem.models or {}, ", ") }
      if problem.kind == "weather" then
        weatherRows[#weatherRows + 1] = row
        weatherProblems[#weatherProblems + 1] = problem
      else
        bugRows[#bugRows + 1] = row
        bugProblems[#bugProblems + 1] = problem
      end
    end
  end
  local all = {}
  for _, row in ipairs(bugRows) do all[#all + 1] = row end
  for _, row in ipairs(weatherRows) do all[#all + 1] = row end
  local problems = {}
  for _, problem in ipairs(bugProblems) do problems[#problems + 1] = problem end
  for _, problem in ipairs(weatherProblems) do problems[#problems + 1] = problem end
  local titles = doctorTableTitles(all, { [2] = true, [4] = true }, function(index, c)
    local problem = problems[index]
    local loud = problem.status == "new" or problem.status == "regressed"
    if problem.kind ~= "bug" then return "dim" end
    if c == 1 or c == 5 then return loud and "warn" or nil end
    return "dim"
  end)
  for index, problem in ipairs(problems) do
    if index == #bugRows + 1 and #bugRows > 0 then items[#items + 1] = { title = "-" } end
    items[#items + 1] = { title = titles[index], menu = problemMenu(problem, block, windowLabel) }
  end
  if #problems == 0 then
    items[#items + 1] = { title = infoTitle("no legs failed in the window", false, true), disabled = true }
  end
  if (entry.top or "") ~= "" then
    items[#items + 1] = { title = infoTitle("top: " .. tostring(entry.top), entry.top_kind == "bug", entry.top_kind ~= "bug"),
      disabled = true }
  end
  items[#items + 1] = { title = "-" }
  local models = type(entry.models) == "table" and entry.models or {}
  if #models > 0 then items[#items + 1] = { title = infoTitle("By model"), menu = modelTableMenu(models) } end
  items[#items + 1] = { title = infoTitle("Copy brief for the owner"), fn = function()
    copyText(ownerBrief(entry, windowLabel, hours), DOCTOR_BLOCK_NAMES[block] .. " brief")
  end }
  return items
end

-- readLlmDoctor returns the same decoded tables until the file changes, so a block's submenu is built
-- once per document; the returned rows are shared by every later build and must not be mutated.
local blockMenus = setmetatable({}, { __mode = "k" })
local function cachedBlockMenu(entry, windowLabel, hours)
  local key = windowLabel .. "\0" .. tostring(hours)
  local hit = blockMenus[entry]
  if hit and hit.key == key then return hit.items end
  local items = blockMenu(entry, windowLabel, hours)
  blockMenus[entry] = { key = key, items = items }
  return items
end

local function machineryStatuses(document)
  for _, entry in ipairs(document and document.blocks or {}) do
    if type(entry) == "table" and entry.block == "reviewers" and type(entry.machinery) == "table" then
      local statuses = {}
      for _, item in ipairs(type(entry.machinery.classes) == "table" and entry.machinery.classes or {}) do
        if type(item) == "table" and type(item.class) == "string" then statuses[item.class] = item end
      end
      return statuses
    end
  end
  return nil
end

-- review-bench doctor's classes as one group row. A class the ledger does not know is new — also
-- every class while llm-doctor has no document, when the row counts the snapshot's own classes.
local function buildMachineryRow(snapshot, statuses, counted)
  local items = {}
  local found = 0
  if snapshot then
    local names, clean = {}, {}
    for name in pairs(snapshot.anomalies) do
      if type(name) == "string" then table.insert(names, name) end
    end
    table.sort(names)
    local rows = type(snapshot.rows) == "table" and snapshot.rows or {}
    for _, name in ipairs(names) do
      local count = tonumber(snapshot.anomalies[name]) or 0
      if count > 0 then
        local known = statuses and statuses[name] or nil
        local status = known and tostring(known.status or "") or "new"
        local loud = status == "new" or status == "regressed"
        if loud or status == "open" then found = found + 1 end
        items[#items + 1] = { title = infoTitle(string.format("%s: %d · %s", name, count, status), loud, not loud),
          disabled = true }
        local detail = {}
        for _, row in ipairs(type(rows[name]) == "table" and rows[name] or {}) do
          if type(row) == "table" then table.insert(detail, row) end
        end
        for index, title in ipairs(doctorDetailRows(detail)) do
          local row = detail[index]
          items[#items + 1] = { title = title, fn = function() copyChatCommand(row) end }
        end
        if count > #detail then
          items[#items + 1] = { title = infoTitle(string.format("  … %d more", count - #detail), false, true),
            disabled = true }
        end
      else
        table.insert(clean, name)
      end
    end
    if #clean > 0 then
      items[#items + 1] = { title = infoTitle("ok: " .. table.concat(clean, ", "), false, true), disabled = true }
    end
  else
    items[#items + 1] = { title = infoTitle("no data yet", false, true), disabled = true }
  end
  items[#items + 1] = { title = "-" }
  if taskRunning(M.doctorRescanTask) then
    items[#items + 1] = { title = infoTitle("rescanning…", false, true), disabled = true }
  else
    items[#items + 1] = { title = infoTitle("Refresh"), fn = function() M.rescanDoctor() end }
  end
  local count = counted or found
  local text = count > 0 and plural(count, "problem") or not snapshot and "no data yet" or "ok"
  return { title = infoTitle("Review machinery: " .. text, count > 0, count == 0), menu = items }, count
end

-- The snapshot and document tables are the cached decodes, so the row is rebuilt only when either
-- file changed, the counted figure moved or the rescan started or ended.
local machineryMemo = {}
local function machineryRow(snapshot, document, counted)
  local rescanning = taskRunning(M.doctorRescanTask)
  local memo = machineryMemo
  if memo.row and memo.snapshot == snapshot and memo.document == document and memo.counted == counted
    and memo.rescanning == rescanning then
    return memo.row, memo.count
  end
  local row, count = buildMachineryRow(snapshot, machineryStatuses(document), counted)
  machineryMemo = { snapshot = snapshot, document = document, counted = counted, rescanning = rescanning,
    row = row, count = count }
  return row, count
end

-- One row per group of the document; each counts the problems the collector filed under it (never
-- legs or events), so the rows sum to problem_count. Returns that sum.
local function appendDoctorBlocks(items, snapshot)
  local document = readLlmDoctor()
  local groups = document and type(document.groups) == "table" and document.groups or {}
  local machinery, total = machineryRow(snapshot, document, document and (tonumber(groups.machinery) or 0) or nil)
  local shown = { machinery = true }
  local judged
  for _, entry in ipairs(document and document.blocks or {}) do
    if type(entry) == "table" and entry.block == "reviewers" and type(entry.machinery) == "table" then
      judged = tonumber(entry.machinery.as_of)
    end
  end
  -- Statuses judged off an older snapshot than the one shown (a rescan just ran) are re-judged.
  kickLlmDoctor(document, false, snapshot and document and tonumber(snapshot.as_of) ~= nil
    and tonumber(snapshot.as_of) ~= judged)
  local selected = M.doctorWindowH or DOCTOR_DEFAULT_H
  local hours = document and tonumber(document.window_h) or selected
  local windowLabel = doctorWindowLabel(hours)
  if not document then
    items[#items + 1] = machinery
    items[#items + 1] = { title = infoTitle("Blocks: no data yet", false, true), disabled = true }
  end
  for _, entry in ipairs(document and document.blocks or {}) do
    if type(entry) == "table" and DOCTOR_BLOCK_NAMES[entry.block] and not shown[entry.block] then
      shown[entry.block] = true
      local count = tonumber(groups[entry.block]) or 0
      total = total + count
      local text = count > 0 and plural(count, "problem") or (tonumber(entry.legs) or 0) == 0 and "no legs" or "ok"
      items[#items + 1] = { title = infoTitle(DOCTOR_BLOCK_NAMES[entry.block] .. ": " .. text, count > 0, count == 0),
        menu = cachedBlockMenu(entry, windowLabel, hours) }
      if entry.block == "reviewers" then items[#items + 1] = machinery end
    end
  end
  if document and not shown.reviewers then items[#items + 1] = machinery end
  for _, row in ipairs(document and type(document.health) == "table" and document.health or {}) do
    if type(row) == "table" and type(row.name) == "string" and not shown[row.name] then
      shown[row.name] = true
      local count = tonumber(groups[row.name]) or 0
      local sub = {}
      for _, item in ipairs(type(row.items) == "table" and row.items or {}) do
        if type(item) == "table" then
          local age = math.max(0, os.time() - (tonumber(item.last) or 0))
          local lines = tonumber(item.lines) or 0
          local repeats = tonumber(item.repeats) or 0
          local chat = type(item.chat) == "string" and item.chat ~= "" and (item.chat .. " · ") or ""
          sub[#sub + 1] = { title = infoTitle(string.format("%d · %s · %s%s%s%s", tonumber(item.count) or 0,
            style.ago(age), chat,
            tostring(item.label or ""), lines > 0 and (" · " .. lines .. " lines") or "",
            repeats > (tonumber(item.count) or 0) and (" · seen " .. repeats .. "×") or "")), disabled = true }
        end
      end
      for _, note in ipairs(type(row.notes) == "table" and row.notes or {}) do
        sub[#sub + 1] = { title = infoTitle(tostring(note), false, true), disabled = true }
      end
      if #sub == 0 then sub[1] = { title = infoTitle("nothing in the window", false, true), disabled = true } end
      local name = row.name:sub(1, 1):upper() .. row.name:sub(2)
      items[#items + 1] = { title = infoTitle(name .. ": " .. (count > 0 and plural(count, "problem") or "ok"),
        count > 0, count == 0), menu = sub }
      total = total + count
    end
  end
  local rest = {}
  for group, value in pairs(groups) do
    if type(group) == "string" and not shown[group] and (tonumber(value) or 0) > 0 then rest[#rest + 1] = group end
  end
  table.sort(rest)
  for _, group in ipairs(rest) do
    local count = tonumber(groups[group])
    local sub = {}
    for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
      if type(problem) == "table" and problem.group == group and DOCTOR_COUNTED[problem.state] then
        sub[#sub + 1] = { title = infoTitle(clipHead(tostring(problem.fact or problem.id or ""), 110)), disabled = true }
      end
    end
    items[#items + 1] = { title = infoTitle(group:sub(1, 1):upper() .. group:sub(2) .. ": " .. plural(count, "problem"),
      true), menu = sub }
    total = total + count
  end
  if document and type(document.not_measurable) == "table" and #document.not_measurable > 0 then
    items[#items + 1] = { title = infoTitle("not measurable yet: " .. table.concat(document.not_measurable, ", "),
      false, true), disabled = true }
  end
  local age = document and (os.time() - (tonumber(document.as_of_s) or tonumber(document.as_of) or 0)) or 0
  items[#items + 1] = doctorWindowItem(document and age >= 86400 and (" · stale · ran " .. style.ago(age)),
    function() kickLlmDoctor(readLlmDoctor(), true) end)
  items[#items + 1] = { title = "-" }
  if taskRunning(M.llmDoctorTask) then
    items[#items + 1] = { title = infoTitle("refreshing…", false, true), disabled = true }
  else
    items[#items + 1] = { title = infoTitle("Refresh"), fn = function() kickLlmDoctor(readLlmDoctor(), true) end }
  end
  return total, document
end

local DOCTOR_STATUSES = { ok = true, problems = true, blind = true, error = true }

-- LLM doctor's groups, for the Doctors entry.
function M.llmDoctorEntry()
  local snapshot = readDoctorSnapshot()
  local items = {}
  local total, document = appendDoctorBlocks(items, snapshot)

  local parts = llmDoctorSummary(document, total)
  local status = document and document.status
  local problems = document and tonumber(document.problem_count)
  if not snapshot then parts[#parts + 1] = "no data yet" end
  local doctorText = "LLM doctor: " .. (#parts > 0 and table.concat(parts, " · ") or "ok")
  local title = doctorText .. (snapshot and doctorStaleSuffix(snapshot.as_of) or "")
    .. (taskRunning(M.doctorRescanTask) and " · rescanning" or "")
  local count = problems or total
  local quiet = count == 0 and status ~= "error" and status ~= "blind"
  local state = DOCTOR_STATUSES[status] and status or not document and count == 0 and "nodata"
    or count > 0 and "problems" or "ok"
  return { title = infoTitle(title, count > 0 or status == "error", quiet), menu = style.mono(items, infoTitle),
    problems = count,
    status = state }
end

local HARNESS_STALE_S = 1800

local function harnessDoctorDir()
  if M.harnessDoctorDir then return M.harnessDoctorDir end
  local override = os.getenv("HARNESS_DOCTOR_DIR")
  if override and override ~= "" then return override end
  return home .. "/.cache/harness-doctor"
end

-- bin/chat-load judges a limiter queue stuck (no held job started for 30 min) and its snapshot is
-- what lights the title's ⚠; a queue that moves stays inside the Chats/other submenu.
readChats = function()
  return readJsonTable(home .. "/Library/Logs/memlogd/chats.json")
end

stuckQueues = function()
  local snapshot, out = readChats(), {}
  if not snapshot or os.time() - (tonumber(snapshot.as_of) or 0) > 120 or type(snapshot.queues) ~= "table" then
    return out
  end
  local seen = {}
  for _, queue in ipairs(snapshot.queues) do
    if type(queue) == "table" and queue.stuck == true then
      local limiter = tostring(queue.limiter or queue.text)
      if not seen[limiter] then
        seen[limiter] = true
        out[#out + 1] = { text = tostring(queue.text or queue.limiter), red = true }
      end
    end
  end
  return out
end

local function harnessLine(flags, spans, text)
  if flags:find("s", 1, true) then return { title = "-" } end
  local dim = flags:find("d", 1, true) ~= nil
  local title, at = nil, 1
  local function add(piece, red, pieceDim, green)
    if piece == "" then return end
    local styled = green and hs.styledtext.new(piece, { font = menuFont, color = style.tone(style.GREEN, false) })
      or infoTitle(piece, red, pieceDim and not red)
    title = title and (title .. styled) or styled
  end
  for kind, start, length in spans:gmatch("(%a):(%d+):(%d+)") do
    start, length = tonumber(start) + 1, tonumber(length)
    if start >= at then
      add(text:sub(at, start - 1), false, dim)
      add(text:sub(start, start + length - 1), kind == "r", false, kind == "g")
      at = start + length
    end
  end
  add(text:sub(at), false, dim)
  return { title = title or infoTitle(text, false, dim) }
end

-- A row's action is an argv, never a shell string: /usr/bin/open as is, or a bare name that exists in
-- this repository's bin/. Anything else leaves the row disabled.
local function harnessAction(packed)
  local argv = {}
  for word in (packed .. "\31"):gmatch("([^\31]*)\31") do argv[#argv + 1] = word end
  local head = argv[1] or ""
  local path
  if head == "/usr/bin/open" then
    path = head
  elseif repoRoot and head:match("^[%w][%w%.%-_]*$") then
    path = repoRoot .. "/bin/" .. head
    local attrs = hs.fs.attributes(path)
    if not attrs or attrs.mode ~= "file" then path = nil end
  end
  if not path then return nil end
  return path, { table.unpack(argv, 2) }
end

-- menu.txt is laid out by bin/harness-doctor; decoding its JSON here cost ~40 ms per menu open.
-- The collector replaces the file by rename, so a new inode is a new document; callers must not
-- mutate the cached items (harnessDoctorEntry copies before adding Refresh).
local harnessCache = {}

local function readHarnessMenu()
  local path = harnessDoctorDir() .. "/menu.txt"
  local attrs = hs.fs.attributes(path)
  local window = M.doctorWindowH or DOCTOR_DEFAULT_H
  local key = attrs and string.format("%s:%s:%s:%s:%d", path, attrs.ino or "", attrs.modification or "",
    attrs.size or "", window)
  if key and harnessCache.key == key then return harnessCache.document end
  local contents = readTextFile(path)
  if not contents then return nil end
  local red, asOf, title = contents:match("^T\t(%d+)\t(%d+)\t([^\n]*)")
  if not title then return nil end
  local root, stack = {}, {}
  stack[0] = root
  for depth, flags, spans, text in contents:gmatch("\n(%d+)\t(%w*)\t([^\t\n]*)\t([^\n]*)") do
    depth = tonumber(depth)
    local parent = stack[depth]
    local tag = tonumber(flags:match("w(%d+)$"))
    if tag and tag ~= window then
      for deeper = depth + 1, #stack do stack[deeper] = nil end
    elseif parent then
      local actionPath, actionArgs
      if flags:find("a", 1, true) then
        local shown, packed = text:match("^(.-)\t([^\t]*)$")
        if shown then
          text = shown
          actionPath, actionArgs = harnessAction(packed)
        end
      end
      local item = harnessLine(flags, spans, text)
      if item.title ~= "-" then
        if actionPath then
          item.fn = function() startDiagnosticsTask("harnessActionTask", actionPath, actionArgs) end
        else
          item.disabled = true
        end
      end
      parent[#parent + 1] = item
      local children = {}
      stack[depth + 1] = children
      item.children = children
      for deeper = depth + 2, #stack do stack[deeper] = nil end
    end
  end
  local function settle(items)
    for _, item in ipairs(items) do
      if item.children and #item.children > 0 then
        item.menu, item.disabled = settle(item.children), nil
      end
      item.children = nil
    end
    return items
  end
  local document = { red = tonumber(red), as_of = tonumber(asOf), title = title, items = settle(root) }
  if key then harnessCache.key, harnessCache.document = key, document end
  return document
end

-- The LaunchAgent (com.egor.harness-doctor) runs the collector every 5 minutes; the menu only
-- runs it on Refresh.
local function runHarnessDoctor()
  local path = M.harnessDoctorCmd or (repoRoot and repoRoot .. "/bin/harness-doctor")
  if not path then return end
  startDiagnosticsTask("harnessDoctorTask", path, { "--quiet" }, function(exitCode)
    local latest = readHarnessMenu()
    hs.alert.show(exitCode ~= 0 and "Harness doctor: refresh failed" or latest and latest.title
      or "Harness doctor: no data yet", 2.5)
  end)
end

-- Harness doctor (docs/harness-doctor-design.md): what is not the model and makes a chat or a
-- worker wait, or slows the machine. bin/harness-doctor writes the rows; nothing here names one.
function M.harnessDoctorEntry()
  local document = readHarnessMenu()
  local items = {}
  for index, item in ipairs(document and document.items or {
    { title = infoTitle("no data yet", false, true), disabled = true } }) do
    items[index] = item
  end
  items[#items + 1] = doctorWindowItem()
  items[#items + 1] = { title = "-" }
  if taskRunning(M.harnessDoctorTask) then
    items[#items + 1] = { title = infoTitle("refreshing…", false, true), disabled = true }
  else
    items[#items + 1] = { title = infoTitle("Refresh"), fn = runHarnessDoctor }
  end
  local red = document and document.red or 0
  local title = document and document.title or "Harness doctor: no data yet"
  local age = document and os.time() - document.as_of or 0
  if document and age > HARNESS_STALE_S then title = title .. " · stale · ran " .. style.ago(age) end
  -- menu.txt's count is problem_count, or 1 for a failed collector whose problem_count is 0.
  local failed = document and document.title:match("^Harness doctor: error") ~= nil
  local status = not document and "nodata" or failed and "error" or red > 0 and "problems"
    or document.title:find("blind", 1, true) and "blind" or "ok"
  return { title = infoTitle(title, red > 0, red == 0), menu = style.mono(items, infoTitle),
    problems = failed and 0 or red, status = status }
end

-- Show Chrome answers for every automation Chrome (docs/browser-runs.md; shared-invariants row en), read
-- from the processes so no producer can forget to say so: the real Chrome whenever it runs, hidden or not
-- (it quits once idle; the canary, enrolment and --window drive it outside any run: hiding it during the
-- canary took the item away, 2026-10-19), and the media tools' clone (share/gemini_web.py) whenever one runs.
-- The clone is LSBackgroundOnly, which macOS never hides: its windows move on and off screen over AX,
-- and windows-shown beside the clone tells park_window to leave a page opened meanwhile where it is.
local CHROME_CLONE_ID = "com.google.Chrome.gemini-web"

local function cloneWindows()
  local apps, windows = hs.application.applicationsForBundleID(CHROME_CLONE_ID) or {}, {}
  for _, app in ipairs(apps) do
    for _, window in ipairs(app:allWindows() or {}) do
      if window:isStandard() then windows[#windows + 1] = window end
    end
  end
  return apps, windows
end

-- A parked window keeps a 40 px sliver on screen, so a window is shown when its centre is on one.
local function windowOnScreen(window)
  local frame = window:frame()
  local x, y = frame.x + frame.w / 2, frame.y + frame.h / 2
  for _, screen in ipairs(hs.screen.allScreens() or {}) do
    local area = screen:fullFrame()
    if x >= area.x and x < area.x + area.w and y >= area.y and y < area.y + area.h then return true end
  end
  return false
end

local function setCloneWindowsShown(show)
  local flag = geminiWebDir() .. "/windows-shown"
  local _, windows = cloneWindows()
  if not show then
    os.remove(flag)
    for _, window in ipairs(windows) do window:setTopLeft({ x = -30000, y = -30000 }) end
    return
  end
  local file = io.open(flag, "w")
  if file then file:close() end
  local area = hs.screen.mainScreen():frame()
  for index, window in ipairs(windows) do
    local frame = window:frame()
    local w, h = math.min(frame.w, area.w), math.min(frame.h, area.h)
    local step = 30 * (index - 1)
    window:setFrame({ x = area.x + math.min(step, area.w - w), y = area.y + math.min(step, area.h - h),
      w = w, h = h }, 0)
  end
end

-- Built on every click of the Auto menu: hs.application.get walks every running app over LaunchServices
-- (0.4-1.7 s a click under load, 2026-10-20), the bundle lookup reads the process list in 0 ms.
function M.chromeToggleItem()
  local chrome = (hs.application.applicationsForBundleID("com.google.Chrome") or {})[1]
  local path, args = harnessAction("worker-run\31browse\31--toggle")
  local real = path and chrome or nil
  local clones, windows = cloneWindows()
  if not real and #clones == 0 then return nil end
  local shown = real ~= nil and not real:isHidden()
  for _, window in ipairs(windows) do shown = shown or windowOnScreen(window) end
  -- A click is Egor's choice for the automation Chromes running now: it sets both records one way, nothing else
  -- ever shows one (Egor 2026-10-23: off unless he turned it on), and a Chrome launched with none of its kind
  -- running clears its record (Egor 2026-10-24: not remembered).
  return { title = "Show Chrome", checked = shown, fn = function()
    if path then startDiagnosticsTask("harnessActionTask", path, { args[1], shown and "--hide" or "--show" }) end
    setCloneWindowsShown(not shown)
  end }
end

local function appendChats(menu)
  local snapshot = readChats()
  if not snapshot then
    table.insert(menu, { title = infoTitle("Chats: no data yet", false, true), disabled = true })
    return
  end
  local items = {}
  for _, row in ipairs(snapshot.rows or {}) do
    if row == "-" then
      items[#items + 1] = { title = "-" }
    elseif type(row) == "table" then
      local item = { title = infoTitle(tostring(row.text or ""), row.alarm == true, row.dim == true) }
      if row.stop then
        local key = tostring(row.stop)
        item.menu = { { title = infoTitle(string.format("Stop · %.1f GB", tonumber(row.gb) or 0)),
          fn = function() stopChatRow(key) end } }
        if row.session then
          table.insert(item.menu, { title = infoTitle("Copy reopen command"),
            fn = function() copyChatCommand({ session = row.session }) end })
        end
      elseif row.session then
        item.fn = function() focusChat({ session = row.session, pid = row.pid }) end
      else
        item.disabled = true
      end
      items[#items + 1] = item
    end
  end
  local failure = tostring(snapshot.error or "")
  if failure ~= "" then items[#items + 1] = { title = infoTitle(failure, true), disabled = true } end
  local stale = os.time() - (tonumber(snapshot.as_of) or 0) > 120
  local alarm = snapshot.alarm == true or failure ~= ""
  local title = (alarm and "⚠ " or "") .. tostring(snapshot.title or "Chats") .. (stale and " · stale" or "")
  table.insert(menu, { title = infoTitle(title, alarm or stale), menu = items })
end

-- Runs a vendor account command (claudeb/codexb/geminib) then re-collects so the row it
-- changed disappears/updates immediately. Shared by the toggle/switch/remove wiring.
local function runAccountCommand(launchPath, args, failMessage, onSuccess, options)
  options = options or {}
  local label = (launchPath:match("[^/]+$") or launchPath) .. " " .. table.concat(args, " ")
  local key = "account-action:" .. launchPath .. "\0" .. table.concat(args, "\0")
  -- Saying nothing here is what made a repeated click look like a dead menu.
  if taskForKey(key) then
    logAction("already-running", label)
    if not options.silentIfRunning then
      hs.alert.show("llm-limits: " .. label .. " is still running")
    end
    return
  end
  logAction("launch", label)
  local id = reserveTask("account-action", 360, key)
  local task = hs.task.new(launchPath, function(exitCode, stdOut, stdErr)
    local failed = exitCode ~= 0
    if failed then
      if options.onFailure then
        options.onFailure(taskCause(stdOut, stdErr, exitCode, failMessage))
      end
      logAction("failed", string.format("%s exit=%s %s", label, tostring(exitCode),
        tostring((stdErr or stdOut or ""):gsub("%s+", " "):sub(1, 160))))
      -- A leg-wide command can fail on one account after changing another (the leg's Hard refresh
      -- spends a completion on EVERY roster account, clear ones included), so its caller asks for
      -- the recollect even on a nonzero exit: the rows must follow what was recorded, and the
      -- failure still reaches the alert below.
      if not options.recollectOnFailure then
        finishTask(id, exitCode, stdOut, stdErr, failMessage)
        return
      end
    else
      logAction("done", label .. " exit=0")
      if onSuccess then onSuccess() end
      if args[1] == "enable" or args[1] == "disable" or args[1] == "use" then
        M.routingCache = nil
        M.refreshRouting()
      end
    end
    if options.skipRecollect then
      finishTask(id, exitCode, stdOut, stdErr, failMessage)
      return
    end
    local reread = newCollectorTask(function(collectExit, collectOut, collectErr)
      logAction("collect", label .. " collect_exit=" .. tostring(collectExit))
      if failed then
        finishTask(id, exitCode, stdOut, stdErr, failMessage)
      else
        finishTask(id, collectExit, collectOut, collectErr, "collect failed")
      end
    end, {})
    startTask(id, reread, "collect could not start")
  end, args)
  if task then task:setEnvironment(options.environment or baseEnvironment()) end
  if not startTask(id, task, failMessage) and options.onFailure then
    options.onFailure(failMessage or "command could not start")
  end
end

local function runClaudeb(args, failMessage, onSuccess, options)
  runAccountCommand(resolveClaudeb(), args, failMessage, onSuccess, options)
end

local function runCodexb(args, failMessage, onSuccess, options)
  runAccountCommand(resolveCodexb(), args, failMessage, onSuccess, options)
end

local function runGeminib(args, failMessage, onSuccess, options)
  runAccountCommand(resolveGeminib(), args, failMessage, onSuccess, options)
end

local function runGrokb(args, failMessage, onSuccess, options)
  runAccountCommand(resolveGrokb(), args, failMessage, onSuccess, options)
end

-- The scheduled refresh asks only the accounts the store marks walled, where the answer is free.
-- This click is the other half of that split: --probe-clear spends one small completion on every
-- clear account too, because an account's age is the stamp of the last completion the plan served
-- it and nothing else moves it — which is the current truth every other vendor's Hard refresh
-- hands back.
function M.hardRefreshOpenCode()
  runAccountCommand(resolveCommand(M.opencodeGoCmd or "opencode-go"),
    { "wall-check", "--all", "--probe-clear" },
    "OpenCode wall refresh failed", nil, { recollectOnFailure = true })
end

-- Arms a Hammerspoon one-shot for the chat in the frontmost Terminal tab; the
-- arm itself is silent — claude_chat_switch.lua alerts on the outcome later.
-- `gateway` says the name came from a Codex row, so it is a claudegpt account and
-- not the claudeb profile that may carry the same name.
function M.switchChatTo(name, gateway)
  local arguments = gateway and { "--front", "--gateway", name } or { "--front", name }
  local ok = pcall(function()
    local task = hs.task.new(os.getenv("HOME") .. "/.local/bin/claude-chat-switch",
      function(exitCode, stdOut, stdErr)
        if exitCode ~= 0 then
          local line = tostring(stdErr or ""):match("[^\r\n]+")
            or tostring(stdOut or ""):match("[^\r\n]+")
            or ("exit " .. tostring(exitCode))
          hs.alert.show("Chat switch failed: " .. line)
        end
      end, arguments)
    if task then
      task:setEnvironment(baseEnvironment())
    end
    if not task or not task:start() then
      error("could not start claude-chat-switch")
    end
  end)
  if not ok then
    hs.alert.show("Chat switch failed (mode=unknown): could not start claude-chat-switch")
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

function M.toggleGrokAccount(name, currentlyEnabled)
  runGrokb({ currentlyEnabled and "disable" or "enable", name }, "toggle failed",
    function() setPoolOverride("grok", name, not currentlyEnabled) end)
end

function M.pinClaude(name, currentlyPinned)
  if currentlyPinned then
    runClaudeb({ "use", "--clear" }, "pin failed")
  else
    runClaudeb({ "use", name }, "pin failed")
  end
end

local function readFastMarker(envName, profilesDir, tool, name)
  if type(name) ~= "string" or name == "" then return nil end
  local profiles = os.getenv(envName)
  if not profiles or profiles == "" then profiles = home .. profilesDir end
  local marker = io.open(profiles .. "/" .. tool .. "/fast-mode/" .. name, "r")
  local tier
  if marker then
    tier = marker:read("*l")
    marker:close()
  else
    return false
  end
  if tier == "fast" or tier == "priority" then return true end
  if tier == "default" then return false end
  return nil
end

function M.codexFastMode(name)
  return readFastMarker("CODEXB_PROFILES_DIR", "/.codex-profiles", ".codexb", name)
end

function M.grokFastMode(name)
  return readFastMarker("GROKB_PROFILES_DIR", "/.grok-profiles", ".grokb", name)
end

-- Grok's fast variant is a model of its own: offered while the account's catalog lists a `-fast` slug.
function M.grokFastOffered(name)
  if type(name) ~= "string" or name == "" then return nil end
  local path
  if name == "main" then
    path = home .. "/.grok/models_cache.json"
  else
    local profiles = os.getenv("GROKB_PROFILES_DIR")
    if not profiles or profiles == "" then profiles = home .. "/.grok-profiles" end
    path = profiles .. "/" .. name .. "/models_cache.json"
  end
  local decoded = readJsonTable(path)
  if type(decoded) ~= "table" or type(decoded.models) ~= "table" or next(decoded.models) == nil then
    return nil
  end
  for slug in pairs(decoded.models) do
    if type(slug) == "string" and slug:match("%-fast$") then return true end
  end
  return false
end

-- A worker launch runs the default codex family's newest slug; the family is the first codex row of
-- share/worker-model.sh's table, the one place it is spelled.
local function codexDefaultFamily()
  local path = M.workerModelShPath
  if not path then return nil end
  return (statCached(path, function()
    local file = io.open(path, "r")
    if not file then return nil end
    local family
    for line in file:lines() do
      family = line:match("^codex (%S+) ")
      if family then break end
    end
    file:close()
    return family
  end))
end

local function versionNewer(a, b)
  local x, y = {}, {}
  for part in tostring(a):gmatch("%d+") do x[#x + 1] = tonumber(part) end
  for part in tostring(b):gmatch("%d+") do y[#y + 1] = tonumber(part) end
  for i = 1, math.max(#x, #y) do
    if (x[i] or 0) ~= (y[i] or 0) then return (x[i] or 0) > (y[i] or 0) end
  end
  return false
end

-- OpenAI switches Fast per account in the catalog the CLI fetches; worker-run then launches standard
-- (codex_tier_args), so a switched-on row must not claim ⚡. nil = no readable catalog.
function M.codexFastOffered(name)
  if type(name) ~= "string" or name == "" then return nil end
  local path
  if name == "main" then
    path = home .. "/.codex/models_cache.json"
  else
    local profiles = os.getenv("CODEXB_PROFILES_DIR")
    if not profiles or profiles == "" then profiles = home .. "/.codex-profiles" end
    path = profiles .. "/" .. name .. "/models_cache.json"
  end
  local decoded = readJsonTable(path)
  if type(decoded) ~= "table" or type(decoded.models) ~= "table" or #decoded.models == 0 then
    return nil
  end
  local function priority(model)
    if type(model.service_tiers) ~= "table" then return false end
    for _, tier in ipairs(model.service_tiers) do
      if type(tier) == "table" and tier.id == "priority" then return true end
    end
    return false
  end
  local family, launched, launchedVersion = codexDefaultFamily(), nil, nil
  for _, model in ipairs(decoded.models) do
    if family and type(model) == "table" and model.visibility ~= "hide" and type(model.slug) == "string" then
      local version, word = model.slug:match("^gpt%-([%d%.]+)%-(.+)$")
      if word == family and (not launched or versionNewer(version, launchedVersion)) then
        launched, launchedVersion = model, version
      end
    end
  end
  if launched then return priority(launched) end
  for _, model in ipairs(decoded.models) do
    if type(model) == "table" and model.visibility ~= "hide" and priority(model) then return true end
  end
  return false
end

function M.toggleCodexFastMode(name, enabled)
  runCodexb({ "fast-mode", name, enabled and "off" or "on" }, "Fast Mode toggle failed", function()
    M.refreshRouting()
  end, { skipRecollect = true })
end

function M.toggleGrokFastMode(name, enabled)
  runGrokb({ "fast-mode", name, enabled and "off" or "on" }, "Fast Mode toggle failed", function()
    M.refreshRouting()
  end, { skipRecollect = true })
end

-- One Fast Mode row shape for every vendor that has one; looked up through M so a test can stub it.
local fastModeApi = {
  codex = { mode = "codexFastMode", offered = "codexFastOffered", toggle = "toggleCodexFastMode", vendor = "OpenAI",
            label = "Fast Mode (workers)" },
  grok = { mode = "grokFastMode", offered = "grokFastOffered", toggle = "toggleGrokFastMode", vendor = "xAI",
           label = "Fast Mode (workers + reviewers)" },
}

function M.pinCodex(name, currentlyPinned)
  if currentlyPinned then
    runCodexb({ "use", "--clear" }, "pin failed")
  else
    runCodexb({ "use", name }, "pin failed")
  end
end

function M.pinGemini(name, currentlyPinned)
  if currentlyPinned then
    runGeminib({ "use", "--clear" }, "pin failed")
  else
    runGeminib({ "use", name }, "pin failed")
  end
end

function M.pinGrok(name, currentlyPinned)
  if currentlyPinned then
    runGrokb({ "use", "--clear" }, "pin failed")
  else
    runGrokb({ "use", name }, "pin failed")
  end
end

local function pinVendor(vendor, currentlyPinned)
  if vendor == "claude" then
    M.pinClaude("*", currentlyPinned)
  elseif vendor == "codex" then
    M.pinCodex("*", currentlyPinned)
  elseif vendor == "gemini" then
    M.pinGemini("*", currentlyPinned)
  elseif vendor == "grok" then
    M.pinGrok("*", currentlyPinned)
  end
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
function M.hardRefreshGrok(name) hardRefresh("grok/" .. name) end

-- The whole per-vendor difference: who has a redeem RPC. Wording and layout are shared, so the
-- item still renders for a vendor without one, disabled and saying why, rather than vanishing.
local RESET_REDEEM_VENDORS = { grok = true, codex = true, claude = true }

-- Spends a real one-per-period consumable on the account, so it fires on a click and a
-- confirmation and on nothing else. The script does the targeted refresh itself; the recollect
-- here is what moves the number in the menu.
function M.redeemReset(vendor, account)
  local target = vendor .. "/" .. account
  -- Cancel is the first button, so Return and Escape both back out: the spend is irreversible and
  -- must cost a deliberate click, never a keystroke aimed at whatever dialog was expected.
  local choice = hs.dialog.blockAlert("Redeem the usage reset for " .. target .. "?",
    "This spends that account's one-per-period reset now and cannot be undone.",
    "Cancel", "Redeem")
  if choice ~= "Redeem" then return end
  local key = "reset-redeem:" .. target
  if taskForKey(key) then
    logAction("already-running", "redeem " .. target)
    hs.alert.show("llm-limits: redeem " .. target .. " is still running")
    return
  end
  logAction("launch", "redeem " .. target)
  local id = reserveTask("reset-redeem", 360, key)
  local task = hs.task.new(resolveCommand(M.resetRedeemCmd or "llm-reset-redeem"),
    function(exitCode, stdOut, stdErr)
      local line = tostring(stdOut or ""):match("[^\r\n]+")
        or tostring(stdErr or ""):match("[^\r\n]+")
        or ("exit " .. tostring(exitCode))
      hs.alert.show(line)
      if exitCode ~= 0 then
        logAction("failed", string.format("redeem %s exit=%s %s", target, tostring(exitCode), line))
        finishTask(id, exitCode, stdOut, stdErr, "redeem failed")
        return
      end
      logAction("done", "redeem " .. target .. " exit=0")
      local reread = newCollectorTask(function(collectExit, collectOut, collectErr)
        finishTask(id, collectExit, collectOut, collectErr, "collect failed")
      end, {})
      startTask(id, reread, "collect could not start")
    end, { target })
  if task then task:setEnvironment(baseEnvironment()) end
  startTask(id, task, "redeem could not start")
end

local function redeemResetItem(vendor, account, block)
  local credits = tonumber(block.reset_credits)
  if not credits or credits < 1 or block.reset_credits_stale == true then return nil end
  local title = "Redeem usage reset"
  if parseTime(block.reset_credits_expires_at) then
    title = title .. " · " .. formatResetTime(block.reset_credits_expires_at)
  end
  if not RESET_REDEEM_VENDORS[vendor] then
    return { title = title .. " — no redeem API", disabled = true }
  end
  return { title = title, fn = function() M.redeemReset(vendor, account) end }
end

-- A bare vendor name refreshes every account of that vendor and no other vendor, free.
function M.refreshVendor(vendor)
  userRefreshData({ "--refresh-account", vendor }, "vendor-refresh", 360, "vendor-refresh:" .. vendor)
end

-- The write itself belongs to share/worker-model.sh, which holds the lock every other writer of
-- this file holds; rewriting it from here would resurrect a pin worker-pick had just cleared.
-- Arguments travel as environment, so no path or value is ever parsed as shell.
local WORKER_ROLE_SCRIPT =
  '. "$WORKER_MODEL_SH" && worker_model_set_role "$WM_VENDOR" "$WM_ROLE" "$WM_STATE"'

local WORKER_PAUSE_SCRIPT =
  '. "$WORKER_MODEL_SH" && worker_model_set_paused "$WM_VENDOR" "$WM_STATE"'

function M.setWorkerPaused(vendor, pause, onDone)
  local prefix = PAUSE_VENDOR_PREFIX[vendor]
  if not prefix then return end
  local state = pause and "on" or "off"
  local label = string.format("worker-model %s_paused=%s", prefix, state)
  local key = "worker-paused:" .. prefix
  if taskForKey(key) then
    logAction("already-running", label)
    hs.alert.show("llm-limits: " .. label .. " is still running")
    return
  end
  logAction("launch", label)
  local id = reserveTask("worker-paused", 60, key)
  local task = hs.task.new("/bin/bash", function(exitCode, stdOut, stdErr)
    if exitCode ~= 0 then
      logAction("failed", string.format("%s exit=%s %s", label, tostring(exitCode),
        tostring((stdErr or stdOut or ""):gsub("%s+", " "):sub(1, 160))))
      hs.alert.show("llm-limits: " .. label .. " failed")
    else
      logAction("done", label .. " exit=0")
      M.routingCache = nil
      M.refreshRouting()
      if onDone then onDone() end
    end
    finishTask(id, exitCode, stdOut, stdErr, "pause toggle failed")
  end, { "-c", WORKER_PAUSE_SCRIPT })
  if task then
    local environment = baseEnvironment()
    environment.WORKER_MODEL_SH = M.workerModelShPath
    environment.WORKER_PICK_CONFIG_FILE = M.workerModelPath
    environment.WM_VENDOR = prefix
    environment.WM_STATE = state
    task:setEnvironment(environment)
  end
  startTask(id, task, "pause toggle failed")
end

-- The refresh is chained onto the write, not fired beside it: a collector that starts before the
-- line is gone reads the vendor as still parked and leaves the section empty for another poll.
function M.resumeVendor(vendor)
  M.setWorkerPaused(vendor, false, function()
    if vendor == "opencode" then M.hardRefreshOpenCode() else M.refreshVendor(vendor) end
  end)
end

function M.setWorkerRole(vendor, role, enable)
  local prefix = WORKER_MODEL_PREFIX[vendor]
  local known = false
  for _, name in ipairs(WORKER_ROLES) do known = known or name == role end
  if not prefix or not known then return end
  local state = enable and "on" or "off"
  local label = string.format("worker-model %s_%s=%s", prefix, role, state)
  local key = "worker-role:" .. prefix .. "\0" .. role
  if taskForKey(key) then
    logAction("already-running", label)
    hs.alert.show("llm-limits: " .. label .. " is still running")
    return
  end
  logAction("launch", label)
  local id = reserveTask("worker-role", 60, key)
  local task = hs.task.new("/bin/bash", function(exitCode, stdOut, stdErr)
    if exitCode ~= 0 then
      logAction("failed", string.format("%s exit=%s %s", label, tostring(exitCode),
        tostring((stdErr or stdOut or ""):gsub("%s+", " "):sub(1, 160))))
      hs.alert.show("llm-limits: " .. label .. " failed")
    else
      logAction("done", label .. " exit=0")
      M.routingCache = nil
      M.refreshRouting()
    end
    finishTask(id, exitCode, stdOut, stdErr, "role toggle failed")
  end, { "-c", WORKER_ROLE_SCRIPT })
  if task then
    local environment = baseEnvironment()
    environment.WORKER_MODEL_SH = M.workerModelShPath
    environment.WORKER_PICK_CONFIG_FILE = M.workerModelPath
    environment.WM_VENDOR = prefix
    environment.WM_ROLE = role
    environment.WM_STATE = state
    task:setEnvironment(environment)
  end
  startTask(id, task, "role toggle failed")
end

-- --force is mandatory here, not a convenience: both CLIs' alive-guards only test that a
-- token STRING is present, so a revoked login (exactly the state a login-needed row renders) can
-- never satisfy them and the unforced remove refuses forever. A healthy row's Remove goes through
-- confirmRemove, the guard's stand-in.
local function removalOptions(vendor, name)
  setRemovalOverride(vendor, name, true)
  notifyRefreshState()
  return {
    silentIfRunning = true,
    onFailure = function(cause)
      setRemovalOverride(vendor, name, false)
      notifyRefreshState()
      hs.alert.show("Remove " .. name .. " failed: " .. cause)
    end,
  }
end

function M.removeClaude(name)
  runClaudeb({ "remove", name, "--force" }, "remove failed", nil,
    removalOptions("claude", name))
end
function M.removeCodex(name)
  if not name or name == "main" then
    refreshData({ "--codex-remove" }, "codex-remove", 360, "codex-remove")
  else
    runCodexb({ "remove", name, "--force" }, "remove failed", nil,
      removalOptions("codex", name))
  end
end
function M.removeGemini(name)
  if not name or name == "main" then
    refreshData({ "--gemini-remove" }, "gemini-remove", 360, "gemini-remove")
  else
    runGeminib({ "remove", name }, "remove failed", nil, removalOptions("gemini", name))
  end
end
function M.removeGrok(name)
  runGrokb({ "remove", name, "--force" }, "remove failed", nil,
    removalOptions("grok", name))
end

-- A healthy account (a Codex plan lapsed to free) is still signed in, so its Remove deletes a working
-- login: Cancel is the first button, as on the reset redeem.
function M.confirmRemove(vendor, name)
  local choice = hs.dialog.blockAlert("Remove " .. vendor .. "/" .. name .. "?",
    "This deletes the account's profile and login on this Mac; adding it back needs a new login.",
    "Cancel", "Remove")
  if choice ~= "Remove" then return end
  local remove = { claude = M.removeClaude, codex = M.removeCodex, gemini = M.removeGemini, grok = M.removeGrok }
  remove[vendor](name)
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
-- Flow and Flow Music in the account's hidden-Chrome profile; `geminib web` then reads the balances.
function M.loginFlow(name)
  openLoginTerminal((M.geminibCmd or "geminib") .. " web " .. shellQuote(name))
end
function M.loginChatgptWeb(name)
  openLoginTerminal((M.codexbCmd or "codexb") .. " web " .. shellQuote(name))
end
function M.loginSuno(name)
  openLoginTerminal("suno-music login --account " .. shellQuote(name))
end
function M.enrollBrowser(name)
  openLoginTerminal("worker-run browse --enroll " .. shellQuote(name))
end
function M.loginTelegram()
  openLoginTerminal("tg-read login")
end
function M.loginGrok(name)
  openLoginTerminal((M.grokbCmd or "grokb") .. " profile " .. shellQuote(name)
    .. " login --device-auth")
end

local function refreshItems(menu)
  local busy = busyNow()
  table.insert(menu, {
    title = "Refresh",
    disabled = busy,
    fn = function()
      userRefreshData({ "--refresh" }, "refresh", 360, "refresh")
    end,
  })
  table.insert(menu, {
    title = "Refresh + start windows",
    disabled = busy,
    fn = function()
      userRefreshData({ "--refresh", "--start-windows" }, "start-windows", 1200, "start-windows")
    end,
  })
end

local function refreshErrorAge(at)
  if type(at) ~= "number" then return "unknown" end
  local seconds = math.max(0, os.time() - at)
  if seconds < 60 then return "now" end
  return style.ago(seconds)
end

local function rosterSet(vendor)
  local set = {}
  if type(vendor) == "table" and type(vendor.accounts) == "table" then
    for _, row in ipairs(vendor.accounts) do
      if type(row) == "table" and type(row.account) == "string"
          and row.account ~= "" and row.removed ~= true then
        set[row.account] = true
      end
    end
  end
  return set
end

local function causeLines(cause, width)
  width = width or 88
  local raw = tostring(cause or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  local function push(line)
    if line == "" then return end
    local i = 1
    local n = #line
    while i <= n do
      -- A cause carries the middot, curly quotes and whatever the vendor wrote: cut on the byte
      -- and a UTF-8 sequence splits, so the wrap backs off to the last byte that starts one.
      local stop = math.min(i + width - 1, n)
      local cut = stop
      while cut > i and line:byte(cut + 1) and line:byte(cut + 1) >= 0x80
          and line:byte(cut + 1) < 0xC0 do
        cut = cut - 1
      end
      if cut > i then stop = cut end
      lines[#lines + 1] = line:sub(i, stop)
      i = stop + 1
    end
  end
  if raw:find("\n", 1, true) then
    for line in (raw .. "\n"):gmatch("(.-)\n") do push(line) end
  else
    push(raw)
  end
  if #lines == 0 and tostring(cause or "") ~= "" then
    lines[1] = truncateText(tostring(cause), width)
  end
  return lines
end

local function classifyLegacyAccount(cause, roster)
  local who = cause:match("^([^:]+): ")
  if who and roster[who] then return who end
  who = cause:match("^(.+) auth")
  if who and roster[who] then return who end
  return nil
end

vendorRefreshErrors = function(vendorKey, vendor)
  if type(vendor) ~= "table" then return {}, {} end
  local roster = rosterSet(vendor)
  -- No roster is not an empty roster: a vendor that publishes no `accounts` (a sole-account leg,
  -- opencode before its first collector run) has nothing to check an error against, and checking
  -- anyway drops every error it reports. An empty roster keeps its errors for the same reason.
  local hasRoster = next(roster) ~= nil
  local raw = vendor.refresh_errors
  if type(raw) ~= "table" then
    local err = errorState(vendor.refresh_error)
    if err then
      raw = {{
        account = classifyLegacyAccount(err.cause, roster),
        class = err.class,
        cause = err.cause,
        at = err.at,
        needs_user_entry = err.needsUserEntry,
      }}
    else
      raw = {}
    end
  end
  local out = {}
  local late = {}
  local seen = {}
  local function add(account, class, cause, at, needsUserEntry)
    if type(cause) ~= "string" or cause == "" then return end
    if account ~= nil and hasRoster and not roster[account] then return end
    -- A row a pending removal hides has nowhere to carry its errors: counted anyway they light
    -- the warning in the title with nothing under it until the override expires.
    if account ~= nil and vendorKey and removalPending(vendorKey, account) then return end
    if type(class) ~= "string" or class == "" then class = "refresh failed" end
    if class == "timeout" then
      late[account or ""] = true
      return
    end
    local key = tostring(account or "") .. "\0" .. cause
    if seen[key] then return end
    seen[key] = true
    out[#out + 1] = {
      account = account,
      class = class,
      cause = cause,
      at = at,
      needsUserEntry = needsUserEntry == true or class == "login needed",
    }
  end
  for _, item in ipairs(raw) do
    if type(item) == "table" then
      local account = item.account
      if type(account) ~= "string" or account == "" then account = nil end
      add(account, item.class, item.cause, tonumber(item.at), item.needs_user_entry == true)
    end
  end
  if type(vendor.accounts) == "table" then
    for _, row in ipairs(vendor.accounts) do
      if type(row) == "table" and row.removed ~= true then
        local accErr = errorState(row.refresh_error)
        if accErr then
          local dup = false
          for _, e in ipairs(out) do
            if e.account == row.account and e.cause:find(accErr.cause, 1, true) then
              dup = true
              break
            end
          end
          if not dup then
            add(row.account, accErr.class, accErr.cause, accErr.at, accErr.needsUserEntry)
          end
        end
      end
    end
  end
  return out, late
end

refreshErrorItem = function(err, fallbackWho, warning)
  local who = err.account or fallbackWho
  local class = err.class or "refresh failed"
  local title
  if who and who ~= "" then
    title = string.format("⚠ %s: %s · %s", who, class, refreshErrorAge(err.at))
  else
    title = string.format("⚠ %s · %s", class, refreshErrorAge(err.at))
  end
  local sub = {}
  for _, line in ipairs(causeLines(err.cause, 88)) do
    sub[#sub + 1] = { title = infoTitle(line, false, true), disabled = true }
  end
  local item = {
    title = infoTitle(title, warning == true, warning ~= true),
  }
  if #sub > 0 then
    item.menu = sub
  else
    item.disabled = true
  end
  return item
end

-- `rendered` names the accounts that get a row of their own below; an error belonging to any
-- other account has nowhere else to go and is rendered here, or it warns from the title with
-- nothing in the menu naming it.
appendRefreshErrorRows = function(menu, entries, fallbackWho, onlyAccount, rendered)
  for _, err in ipairs(entries) do
    if onlyAccount == nil then
      if err.account == nil or (rendered ~= nil and not rendered[err.account]) then
        table.insert(menu, refreshErrorItem(err, fallbackWho))
      end
    elseif err.account == onlyAccount then
      table.insert(menu, refreshErrorItem(err, onlyAccount))
    end
  end
end

local function workerSwitchItems(vendorKey)
  local _, roles, _, vendorPins = readWorkerModel()
  local items = {}
  for _, role in ipairs(WORKER_ROLES) do
    local on = roles[vendorKey][role]
    table.insert(items, {
      title = role == "workers" and "For workers" or "For reviewers",
      checked = on,
      fn = function() M.setWorkerRole(vendorKey, role, not on) end,
    })
  end
  local vendorPinned = vendorPins[vendorKey] == true
  table.insert(items, {
    title = "Pin vendor for workers",
    checked = vendorPinned,
    fn = function() pinVendor(vendorKey, vendorPinned) end,
  })
  table.insert(items, {
    title = "Pause",
    fn = function() M.setWorkerPaused(vendorKey, true) end,
  })
  return items
end

local function lightSwitch(title, dim)
  local lightOff = select(3, readWorkerModel()).light == true
  return {
    title = infoTitle(title or ("light: " .. (lightOff and "off" or "on")), false, dim),
    checked = not lightOff,
    fn = function() M.setWorkerPaused("light", not lightOff) end,
  }
end

-- worker-pick --menu answers in rows already aligned in the menu font: the rows are shown as it
-- printed them, so Egor reads what a chat reads, and the switches ride on the rows they govern.
local function routingSubmenu()
  local cache = M.routingCache
  local unavailable = function()
    local text = M.routingFailed == true and "⚠ routing refresh failed" or "routing unavailable"
    return {
      { title = infoTitle(text, M.routingFailed == true, M.routingFailed ~= true), disabled = true },
      lightSwitch(),
    }, "Routing"
  end
  if type(cache) ~= "table" or type(cache.text) ~= "string"
      or type(cache.at) ~= "number" then
    return unavailable()
  end
  local store = hs.fs.attributes(M.cachePath)
  local dim = M.routingFailed == true
    or (type(store) == "table" and type(store.modification) == "number"
      and cache.at < store.modification)
  local lines = {}
  local normalized = cache.text:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (normalized .. "\n"):gmatch("(.-)\n") do
    if line == "# Worker routing policy" then break end
    if not line:match("^START:") then table.insert(lines, line) end
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  if #lines == 0 then
    return unavailable()
  end
  local menu = {{
    title = infoTitle("as of " .. style.clock(cache.at, os.time()) .. " · outside any chat", false, true),
    disabled = true,
  }}
  if M.routingFailed == true then
    table.insert(menu, { title = infoTitle("⚠ routing refresh failed", true, false), disabled = true })
  end
  local pick, lightShown = nil, false
  for index, line in ipairs(lines) do
    local label, state = line:match("^(%a+):%s+(.-)%s*$")
    local header = index == 1 and line:match("^NEXT%s") ~= nil
    pick = pick or line:match("^ACCOUNT:%s+(%S+)")
    local item
    if label and WORKER_MODEL_PREFIX[label] then
      item = { title = infoTitle(line, false, dim), menu = state == "paused"
        and {{ title = "Resume", fn = function() M.resumeVendor(label) end }}
        or workerSwitchItems(label) }
    elseif label == "light" then
      item, lightShown = lightSwitch(line, dim), true
    else
      item = { title = infoTitle(header and line:lower() or line, false, dim or header), disabled = true }
    end
    table.insert(menu, item)
  end
  -- worker-pick's fail-safe answer prints no `light:` row, and the switch must not go with it.
  if not lightShown then table.insert(menu, lightSwitch(nil, dim)) end
  return menu, pick and ("Routing: next " .. pick) or "Routing"
end

local function buildMenuItems()
  local menu = {}
  local state = M.refreshState()
  if state.globalError then
    table.insert(menu, refreshErrorItem({
      class = state.globalError.class or "refresh failed",
      cause = state.globalError.cause,
      at = state.globalError.at,
    }, nil, true))
  end
  if state.stalledSince then
    table.insert(menu, {
      title = infoTitle("⚠ refresh stalled " .. style.age(os.time() - state.stalledSince)
        .. " — last tick " .. style.clock(state.stalledSince), true),
      disabled = true,
    })
  end
  if state.staleCount > 0 then
    table.insert(menu, {
      title = infoTitle("⚠ stale data: " .. plural(state.staleCount, "account")
        .. ", up to " .. style.age(state.staleOldest) .. " old — numbers not trusted", true),
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
  appendChats(menu)
  table.insert(menu, { title = "-" })
  local routing, routingTitle = routingSubmenu()
  table.insert(menu, { title = infoTitle(routingTitle), menu = routing })
  table.insert(menu, { title = "-" })
  if limits and type(limits.vendors) == "table" then
    local pins, roles, paused, vendorPins = readWorkerModel()
    local staleAfter = tonumber(limits.account_stale_after_s)
    local roleItems = workerSwitchItems
    -- With a role off the list row already shows it; the submenu item stays plain and its click
    -- restores the off roles instead of dropping an account out of a pool nobody closed.
    local function poolItem(vendorKey, checked, toggleFn)
      local off = {}
      for _, role in ipairs(WORKER_ROLES) do
        if not roles[vendorKey][role] then table.insert(off, role) end
      end
      if #off == 0 then
        return { title = "In pool", checked = checked, fn = toggleFn }
      end
      return {
        title = "In pool",
        checked = checked,
        fn = function()
          for _, role in ipairs(off) do M.setWorkerRole(vendorKey, role, true) end
        end,
      }
    end
    for _, entry in ipairs(MENU_VENDORS) do
      local vendor = limits.vendors[entry.key]
      -- Absent from the store means the leg is not installed: every vendor skips,
      -- rather than rendering a "no live data" wall that does not exist.
      if paused[entry.key] then
        table.insert(menu, pausedRow(entry.key, entry.label))
      elseif vendor ~= nil then
      local pinSet = pins[entry.key] or {}
      -- A vendor no role may use is still fully operable; its rows only stop claiming attention.
      local unused = not roles[entry.key].workers and not roles[entry.key].reviewers
      local roleOff = not roles[entry.key].workers or not roles[entry.key].reviewers
      local renderedPins = {}
      local renderedAccountRows = false
      -- A sole-account vendor has no section header to carry the role switches, so its own row
      -- does — logged out included, which is when parking the vendor is the point.
      local function appendRoleItems(row)
        if type(row.menu) ~= "table" then return end
        for _, item in ipairs(roleItems(entry.key)) do table.insert(row.menu, item) end
      end
      -- One row is enough: the flat shape belongs to a store holding nothing but the base
      -- profile, and that profile is deletable.
      local hasGeminiAccounts = entry.key == "gemini" and type(vendor) == "table"
        and type(vendor.accounts) == "table" and #vendor.accounts > 0
      local hasGrokAccounts = entry.key == "grok" and type(vendor) == "table"
        and type(vendor.accounts) == "table" and #vendor.accounts > 0
      local vendorErrs, late = vendorRefreshErrors(entry.key, vendor)
      local anyLate = next(late) ~= nil
      -- Removing gemini's main empties the roster, and the collector states that emptiness as
      -- `removed` on the vendor: without it a removed Gemini rendered a "no live data" row with a
      -- Refresh submenu, which is the opposite of removed.
      if type(vendor) == "table" and vendor.removed == true then
        vendor = nil
      elseif type(vendor) ~= "table"
          or (vendor.available ~= true and not hasGeminiAccounts and not hasGrokAccounts) then
        local authNeeded = type(vendor) == "table" and vendor.auth_needed == true
        local unavailableRow
        if entry.key == "gemini" and authNeeded then
          local age = lateAge(formatAccountAge(vendor.as_of), anyLate)
          local needsEntry = vendor.needs_user_entry == true
          unavailableRow = geminiLoginNeededRow(entry.label, "main", pinSet["main"] == true,
            age, needsEntry, roleOff, vendor.age_alarm == true)
          if pinSet["main"] then renderedPins["main"] = true end
          if vendorPins[entry.key] then
            unavailableRow.title = loginNeededTitle(entry.label, true, age, needsEntry, roleOff,
              vendor.age_alarm == true)
          end
        else
          local unavailableTitle
          if authNeeded then
            unavailableTitle = loginNeededTitle(entry.label, vendorPins[entry.key] == true,
              lateAge(formatAccountAge(vendor.as_of), anyLate), vendor.needs_user_entry == true, roleOff,
              vendor.age_alarm == true)
          else
            unavailableTitle = infoTitle(string.format("%-6s  no live data", entry.label))
            if anyLate then unavailableTitle = unavailableTitle .. metaTitle("  ⧖") end
            if vendorPins[entry.key] then unavailableTitle = unavailableTitle .. pinTitle() end
          end
          unavailableRow = {
            title = unavailableTitle,
            disabled = true,
          }
          if entry.key == "gemini" or entry.key == "grok" then
            -- Vendor-wide: a Gemini or Grok with no live data may have no accounts left to name.
            unavailableRow.disabled = nil
            unavailableRow.menu = {{
              title = "Refresh", fn = function() M.refreshVendor(entry.key) end,
            }}
          end
        end
        if type(unavailableRow.menu) ~= "table" then
          unavailableRow.disabled = nil
          unavailableRow.menu = {}
        end
        appendRoleItems(unavailableRow)
        table.insert(menu, unavailableRow)
        for _, err in ipairs(vendorErrs) do
          table.insert(menu, refreshErrorItem(err, err.account or entry.key))
        end
      else
        local blocks = (entry.key == "claude" or entry.key == "codex" or entry.key == "gemini"
          or entry.key == "grok")
          and vendor.accounts or nil
        local isClaudeAccounts = entry.key == "claude" and type(blocks) == "table" and #blocks > 0
        local isCodexAccounts = entry.key == "codex" and type(blocks) == "table" and #blocks > 0
        local isGeminiAccounts = entry.key == "gemini" and type(blocks) == "table" and #blocks > 0
        local isGrokAccounts = entry.key == "grok" and type(blocks) == "table" and #blocks > 0
        local isAccountRows = isClaudeAccounts or isCodexAccounts or isGeminiAccounts
          or isGrokAccounts
        renderedAccountRows = isAccountRows
        local hasAccountControls = isClaudeAccounts and vendor.source == "claudeb-store"
        if isAccountRows then
          local visible = {}
          for _, block in ipairs(blocks) do
            if block.removed ~= true and not removalPending(entry.key, block.account) then
              table.insert(visible, block)
            end
          end
          blocks = visible
        end
        local geminiMedia, mediaNow = {}, os.time()
        if isGeminiAccounts then
          local roster = {}
          for _, block in ipairs(blocks) do
            if type(block.account) == "string" then roster[block.account] = true end
          end
          geminiMedia = geminiMediaState(roster, mediaNow)
        end
        if not isAccountRows then
          blocks = {{ account = entry.label, five_hour = vendor.five_hour,
            weekly = vendor.weekly, fable = vendor.fable, as_of = vendor.as_of,
            age_alarm = vendor.age_alarm, worker_wall = vendor.worker_wall, is_current = false }}
        end
        if isAccountRows then
          local sectionMenu = {}
          for _, item in ipairs(roleItems(entry.key)) do table.insert(sectionMenu, item) end
          table.insert(sectionMenu, { title = "Refresh",
            fn = function() M.refreshVendor(entry.key) end })
          local headerTitle = infoTitle(entry.label)
          if vendorPins[entry.key] then headerTitle = headerTitle .. pinTitle() end
          if late[""] then headerTitle = headerTitle .. metaTitle("  ⧖") end
          table.insert(menu, { title = headerTitle, menu = sectionMenu })
          appendRefreshErrorRows(menu, vendorErrs, entry.key)
        else
          -- Gemini's pin has to be known before the row is built now that the mark lives inside
          -- the title instead of being appended behind the age.
          local geminiPinned = entry.key == "gemini" and pinSet["main"] == true
          local fallbackAge, fallbackAlarm = accountAgeText(vendor.as_of, anyLate, staleAfter,
            vendor.age_alarm == true)
          local fallbackRow = {
            title = accountTitle(entry.label, fallbackAge, false,
              vendor.needs_user_entry == true,
              geminiPinned or vendorPins[entry.key] == true, nil, roleOff,
              fallbackAlarm),
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
            if pinExists then renderedPins["main"] = true end
            -- The sole account carries the pool checkbox like every other row: an empty pool is a
            -- legitimate state (it says no worker may run), so nothing here is immutable.
            local soleEnabled = poolStateFor("gemini", "main", vendor.enabled ~= false)
            fallbackRow.disabled = nil
            applyPoolMark(fallbackRow, soleEnabled, unused)
            fallbackRow.menu = {
              poolItem("gemini", soleEnabled,
                function() M.toggleGeminiAccount("main", soleEnabled) end),
              {
                title = "Pin for workers",
                checked = pinExists,
                fn = function() M.pinGemini("main", pinExists) end,
              },
              { title = "Hard refresh", fn = refresh },
            }
            appendRoleItems(fallbackRow)
          end
          table.insert(menu, fallbackRow)
          for _, err in ipairs(vendorErrs) do
            table.insert(menu, refreshErrorItem(err, err.account or entry.key))
          end
        end
        for _, block in ipairs(blocks) do
          local fiveHour = type(block.five_hour) == "table" and block.five_hour or nil
          local weekly = block.weekly
          local acct = block.account or entry.label
          local enabled = poolStateFor(entry.key, acct, block.enabled ~= false)
          local authStatus = type(block.auth) == "table" and block.auth.status or nil
          local authNeeded = blockAuthNeeded(entry.key, block)
          local ownerNeeds = isAccountRows and owner.accountNeeds(entry.key, acct, geminiMedia) or {}
          local userEntry = block.needs_user_entry == true or #ownerNeeds > 0
          local accountAge, accountAgeAlarm, untrusted = accountAgeText(block.as_of,
            isAccountRows and late[acct], not authNeeded and staleAfter or nil,
            block.age_alarm == true and not (entry.key == "grok" and authStatus == "expired"))
          local wall = wallView(block, os.time())
          local generalAtLimit = wall ~= nil or bucketAtLimit(fiveHour) or bucketAtLimit(weekly)
          local pinExists = pinSet[acct] == true
          local pinFn
          if entry.key == "claude" then
            pinFn = function(pinned) M.pinClaude(acct, pinned) end
          elseif entry.key == "codex" then
            pinFn = function(pinned) M.pinCodex(acct, pinned) end
          elseif entry.key == "gemini" then
            pinFn = function(pinned) M.pinGemini(acct, pinned) end
          else
            pinFn = function(pinned) M.pinGrok(acct, pinned) end
          end
          if isAccountRows then
            if pinExists then renderedPins[acct] = true end
            local resetCredits = tonumber(block.reset_credits)
            -- The row carries the count and nothing else; the expiry only matters when the user is
            -- about to spend the reset, so it lives on the action instead of crowding out the age.
            local resetSuffix = resetCredits and resetCredits > 0
              and string.format("  ↻%d", math.floor(resetCredits)) or ""
            local fastApi = fastModeApi[entry.key]
            local fastMode = fastApi ~= nil and M[fastApi.mode](acct) == true
            local fastWithdrawn = fastMode and M[fastApi.offered](acct) == false
            if fastMode and not fastWithdrawn then resetSuffix = "  ⚡" .. resetSuffix end
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
                removeFn = function() M.removeCodex(acct) end
              elseif entry.key == "gemini" then
                accountRow = geminiLoginNeededRow(acct, acct, pinExists,
                  accountAge, userEntry, roleOff, accountAgeAlarm)
              else
                loginFn = function() M.loginGrok(acct) end
                hardRefreshFn = function() M.hardRefreshGrok(acct) end
                -- grokb refuses to remove `main` (the real ~/.grok); no Remove item.
                if acct ~= "main" then removeFn = function() M.removeGrok(acct) end end
              end
              if not accountRow then
                local clearPinFn
                if pinExists then clearPinFn = function() pinFn(true) end end
                accountRow = loginNeededRow(acct, loginFn, hardRefreshFn, removeFn, clearPinFn,
                  accountAge, userEntry, roleOff, accountAgeAlarm)
              end
            else
              local title = accountTitle(acct, accountAge, generalAtLimit,
                userEntry, pinExists, resetSuffix, roleOff, accountAgeAlarm)
              accountRow = {
                title = title,
                disabled = true,
              }
              if hasAccountControls then
                accountRow.disabled = nil
                applyPoolMark(accountRow, enabled, unused)
                accountRow.menu = {
                  poolItem(entry.key, enabled, function() M.toggleAccount(acct, enabled) end),
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
                applyPoolMark(accountRow, enabled, unused)
                accountRow.menu = {
                  poolItem(entry.key, enabled,
                    function() M.toggleCodexAccount(acct, enabled) end),
                  { title = "Hard refresh",
                    fn = function() M.hardRefreshCodex(acct) end },
                  -- The same item the Claude rows carry: every Codex account is a usable
                  -- gateway target, because share/gateway_auth.py serves the launch from
                  -- that account's own codexb login when it has no gateway login of its own.
                  { title = "Switch chat to this",
                    fn = function() M.switchChatTo(acct, true) end },
                }
              elseif isGeminiAccounts then
                accountRow.disabled = nil
                applyPoolMark(accountRow, enabled, unused)
                accountRow.menu = {
                  poolItem(entry.key, enabled,
                    function() M.toggleGeminiAccount(acct, enabled) end),
                  { title = "Hard refresh",
                    fn = function() M.hardRefreshGemini(acct) end },
                }
                local media = geminiMedia[acct]
                if not (media and media.bound and media.musicSignedIn) or #ownerNeeds > 0 then
                  table.insert(accountRow.menu, { title = "Log in to Flow…", fn = function() M.loginFlow(acct) end })
                end
              elseif isGrokAccounts then
                accountRow.disabled = nil
                applyPoolMark(accountRow, enabled, unused)
                accountRow.menu = {
                  poolItem(entry.key, enabled,
                    function() M.toggleGrokAccount(acct, enabled) end),
                  { title = "Hard refresh",
                    fn = function() M.hardRefreshGrok(acct) end },
                }
              end
              if accountRow.menu and (block.removed ~= true or pinExists) then
                table.insert(accountRow.menu, 2, {
                  title = "Pin for workers",
                  checked = pinExists,
                  fn = function() pinFn(pinExists) end,
                })
              end
              -- First, as the step the "!" asks for; Gemini's Log in to Flow… already stands in its menu.
              local ownerLogin = #ownerNeeds > 0 and accountRow.menu
                and ({ codex = { title = "Log in to ChatGPT web…", fn = function() M.loginChatgptWeb(acct) end },
                  claude = { title = "Enroll browser…", fn = function() M.enrollBrowser(acct) end } })[entry.key]
              if ownerLogin then table.insert(accountRow.menu, 1, ownerLogin) end
              if accountRow.menu then
                local redeem = redeemResetItem(entry.key, acct, block)
                if redeem then table.insert(accountRow.menu, redeem) end
              end
            end
            if fastApi and accountRow.menu then
              -- A logged-out row's submenu is one constructor's fixed three items, and an account
              -- that cannot launch has nothing to launch fast: the mark still shows, the toggle
              -- waits for the login.
              if authNeeded then
                if fastMode and not fastWithdrawn then accountRow.title = accountRow.title .. metaTitle("  ⚡") end
              else
                table.insert(accountRow.menu, {
                  title = fastWithdrawn and fastApi.label .. " · " .. fastApi.vendor .. ": off now" or fastApi.label,
                  checked = fastMode,
                  fn = function() M[fastApi.toggle](acct, fastMode) end,
                })
              end
            end
            if accountRow.menu and not authNeeded and acct ~= "main" and block.removed ~= true then
              table.insert(accountRow.menu, { title = "Remove " .. acct,
                fn = function() M.confirmRemove(entry.key, acct) end })
            end
            table.insert(menu, accountRow)
          end
          if not authNeeded then
            local wallBucket = wall and { effective_pct = 100, resets_at = wall.resets_at }
            if wall and wall.window == "five_hour" then
              table.insert(menu, { title = rowTitle("", "5h", wallBucket, false, true), disabled = true })
            elseif type(fiveHour) == "table" and not windowAbsent(fiveHour) then
              local fiveRow = {
                title = rowTitle("", "5h", fiveHour, isStale(fiveHour),
                  bucketAtLimit(fiveHour), false, { untrusted = untrusted }),
                disabled = true,
              }
              table.insert(menu, fiveRow)
            end
            local function tailRow(label, bucket, barWarning, columns)
              columns = columns or {}
              columns.untrusted = untrusted
              if type(bucket) == "table" then
                return rowTitle("", label, bucket, isStale(bucket), bucketAtLimit(bucket),
                  barWarning, columns)
              end
              return rowTitle("", label, nil, false, false, barWarning, columns)
            end
            local weeklyLabel = "wk"
            if isGrokAccounts and type(block.period) == "string" then
              local period = block.period:gsub("^USAGE_PERIOD_TYPE_", ""):lower()
              if period == "monthly" then weeklyLabel = "mo"
              elseif period == "daily" then weeklyLabel = "d"
              end
            end
            local weeklyColumns
            local buildPct = isGrokAccounts and tonumber(block.build_pct) or nil
            local weeklyPct = type(weekly) == "table" and tonumber(weekly.effective_pct) or nil
            if buildPct and (not weeklyPct or math.abs(buildPct - weeklyPct) >= 0.05) then
              weeklyColumns = { detail = string.format("  build %d%%", math.floor(buildPct + 0.5)) }
            end
            local weeklyTitle
            if wall and wall.window == "weekly" then
              weeklyTitle = rowTitle("", weeklyLabel, wallBucket, false, true, false, weeklyColumns)
            else
              weeklyTitle = tailRow(weeklyLabel, weekly, false, weeklyColumns)
            end
            table.insert(menu, { title = weeklyTitle, disabled = true })
            if type(block.fable) == "table" then
              local fableWarning = (tonumber(block.fable.effective_pct) or 0) >= 80
              table.insert(menu, { title = tailRow("fb", block.fable, fableWarning), disabled = true })
            end
            if type(block.families) == "table" then
              local slugs = {}
              for slug, family in pairs(block.families) do
                if type(family) == "table" and type(family.weekly) == "table" then table.insert(slugs, slug) end
              end
              table.sort(slugs)
              for _, slug in ipairs(slugs) do
                local familyWeekly = block.families[slug].weekly
                -- fb is fable's 1st and 3rd letter; a family's label follows it (argon -> ag)
                table.insert(menu, { title = tailRow(slug:sub(1, 1) .. slug:sub(3, 3), familyWeekly,
                  (tonumber(familyWeekly.effective_pct) or 0) >= 80), disabled = true })
              end
            end
          end
          if isGeminiAccounts then
            for _, mediaRow in ipairs(geminiMediaRows(geminiMedia[acct])) do
              table.insert(menu, mediaRow)
            end
          end
          for _, needRow in ipairs(owner.needRows(ownerNeeds)) do table.insert(menu, needRow) end
          if isAccountRows then
            appendRefreshErrorRows(menu, vendorErrs, entry.key, acct)
          end
        end
      end
      local leftover = {}
      for name in pairs(pinSet) do
        if not renderedPins[name] then table.insert(leftover, name) end
      end
      table.sort(leftover)
      for _, leftoverName in ipairs(leftover) do
        local name = leftoverName
        local clearPin
        if entry.key == "claude" then
          clearPin = function() M.pinClaude(name, true) end
        elseif entry.key == "codex" then
          clearPin = function() M.pinCodex(name, true) end
        elseif entry.key == "gemini" then
          clearPin = function() M.pinGemini(name, true) end
        else
          clearPin = function() M.pinGrok(name, true) end
        end
        table.insert(menu, {
          title = metaTitle(name) .. pinTitle(),
          menu = {{ title = "Pin for workers", checked = true, fn = clearPin }},
        })
      end
      if renderedAccountRows then
        table.insert(menu, { title = "-" })
      end
      end
    end

    appendElevenLabs(menu, limits)
    appendSuno(menu, os.time())
    if owner.telegramLoginNeeded() then
      table.insert(menu, { title = accountTitle("Telegram", nil, false, true),
        menu = {{ title = "Log in…", fn = function() M.loginTelegram() end }} })
      for _, row in ipairs(owner.needRows({{ label = "tg", text = "login needed" }})) do table.insert(menu, row) end
      table.insert(menu, { title = "-" })
    end
    appendOpenCode(menu, limits, paused)
    table.insert(menu, { title = "-" })
    refreshItems(menu)
  else
    table.insert(menu, {
      title = infoTitle("no data yet"),
      disabled = true,
    })
    if readErrorReason then
      table.insert(menu, {
        title = infoTitle(readErrorReason, true),
        disabled = true,
      })
    end
    local pausedVendors = select(3, readWorkerModel())
    for _, entry in ipairs(MENU_VENDORS) do
      if pausedVendors[entry.key] then
        table.insert(menu, pausedRow(entry.key, entry.label))
      end
    end
    appendOpenCode(menu, limits, pausedVendors)
    table.insert(menu, { title = "-" })
    refreshItems(menu)
  end

  return menu
end

local function epochNow()
  return hs.timer and hs.timer.secondsSinceEpoch and hs.timer.secondsSinceEpoch()
end

-- Contract row `da`: bin/harness-doctor reads menu/<YYYY-MM-DD>.tsv and makes the folder; a
-- missing folder or any error drops the line, never the menu.
function M.journalLine(folder, name, startedAt, endedAt)
  pcall(function()
    if not startedAt or not endedAt then return end
    local file = io.open(folder .. "/" .. os.date("%Y-%m-%d", math.floor(endedAt)) .. ".tsv", "a")
    if not file then return end
    file:write(string.format("%d\t%d\t%s\n", math.floor(startedAt * 1e6), math.floor(endedAt * 1e6), name))
    file:close()
  end)
end

function M.menuJournal(name, startedAt)
  pcall(function() M.journalLine(harnessDoctorDir() .. "/menu", name, startedAt, epochNow()) end)
end

local backgroundDepth = 0

function M.inBackground()
  return backgroundDepth > 0
end

-- The journal is the time a click waits: a build off the click path runs here and writes no line.
function M.backgroundMenu(build, ...)
  backgroundDepth = backgroundDepth + 1
  local results = table.pack(pcall(build, ...))
  backgroundDepth = backgroundDepth - 1
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end

function M.timedMenu(name, build, ...)
  if M.inBackground() then return build(...) end
  local _, startedAt = pcall(epochNow)
  local menu = build(...)
  M.menuJournal(name, startedAt)
  return menu
end

function M.menuItems()
  return M.timedMenu("llm-limits", function() return style.mono(buildMenuItems(), infoTitle) end)
end

function M.title()
  local state = M.refreshState()
  local parts, red = {}, 0
  for _, hold in ipairs(state.holds) do
    if hold.red then red = red + 1 end
  end
  if red > 0 then parts[#parts + 1] = plural(red, "stuck queue") end
  if state.globalError then
    parts[#parts + 1] = state.globalError.class or "refresh failed"
  end
  if state.staleCount > 0 then
    parts[#parts + 1] = "stale " .. style.age(state.staleOldest)
  end
  if state.stalledSince then
    parts[#parts + 1] = "refresh stalled " .. style.age(os.time() - state.stalledSince)
  end
  if #parts == 0 then return "LLM Limits" end
  return hs.styledtext.new("LLM Limits: " .. table.concat(parts, " · "),
    { font = (hs.styledtext.defaultFonts or {}).menu, color = redColor })
end

M.infoTitle, M.dimColor, M.parseTime = infoTitle, dimColor, parseTime

-- The store is written by the collector and now every session's
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
-- A suppressed change still schedules one trailing re-render, or the burst's last write is lost.
-- While Egor is away (presence.lua) nobody reads the menu: a change only marks the routing table stale,
-- and his return refreshes it once. The Auto menu hands Presence in (M.presence) and reports its changes
-- (M.presenceChanged), so a harness that loads this module never reads or joins the live one.
local routingStaleWhileAway = false

local function awayNow()
  local presence = M.presence
  return presence and presence.away and presence.away() or false
end

-- worker-pick --menu reads the store: one launch per store state (ino:mtime:size), not per watcher event.
local lastRoutingStoreKey = nil

local function storeKey()
  local attrs = hs.fs and hs.fs.attributes and hs.fs.attributes(M.cachePath)
  if not attrs then return nil end
  return string.format("%s:%s:%s", attrs.ino or "", attrs.modification or "", attrs.size or "")
end

local function refreshRoutingIfStoreMoved()
  local key = storeKey()
  if key and key == lastRoutingStoreKey then return end
  lastRoutingStoreKey = key
  M.refreshRouting()
end

local function onStoreChanged()
  if awayNow() then
    routingStaleWhileAway = true
    return
  end
  local now = os.time()
  if not M.shouldRerenderOnStoreChange(now, lastStoreRenderEpoch) then
    if not M.storeRerenderTimer and hs.timer and hs.timer.doAfter then
      M.storeRerenderTimer = hs.timer.doAfter(STORE_RERENDER_THROTTLE, function()
        M.storeRerenderTimer = nil
        onStoreChanged()
      end)
    end
    return
  end
  if M.storeRerenderTimer then
    M.storeRerenderTimer:stop()
    M.storeRerenderTimer = nil
  end
  lastStoreRenderEpoch = now
  refreshRoutingIfStoreMoved()
  notifyRefreshState()
end

local function onWorkerModelChanged()
  if awayNow() then
    routingStaleWhileAway = true
    return
  end
  M.refreshRouting()
  notifyRefreshState()
end

function M.presenceChanged()
  if routingStaleWhileAway and not awayNow() then
    routingStaleWhileAway = false
    M.refreshRouting()
    notifyRefreshState()
  end
end

-- A local pathwatcher is garbage-collected and silently stops firing; hold the
-- reference at module scope so garbage collection cannot stop it. Guarded
-- so the headless renderer harness (no hs.pathwatcher) still loads.
if hs.pathwatcher then
  M.storeWatcher = hs.pathwatcher.new(M.cachePath, onStoreChanged)
  if M.storeWatcher then M.storeWatcher:start() end
  M.workerModelWatcher = hs.pathwatcher.new(M.workerModelPath, onWorkerModelChanged)
  if M.workerModelWatcher then M.workerModelWatcher:start() end
  lastRoutingStoreKey = storeKey()
  M.refreshRouting()
end

return M
