local home = os.getenv("HOME")
local repoRoot = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]+/[^/]+$")
local limits = require("llm-limits")
local style = require("menu-style")
local infoTitle = limits.infoTitle

local M = { cacheSeconds = 2 }

local FIX_BUSY_S = 12 * 3600
local NIGHT_REFRESH_S = 60
local UPDATER_STALE_S = 2 * 86400
local SYSTEM_STALE_S = 3600
local ROW_CELLS = 64
local LAG_EVERY_S, LAG_MIN_S = 1, 0.05
local VERDICTS = { "fixed", "ruled-out", "weather", "blind-spot", "handoff" }
local LOUD = { new = true, open = true, regressed = true }
-- Egor's red (docs/doctors-contract.md "Menu layout"): a loud problem nothing acts on reads calm, while every document,
-- the night and doctor-fix keep it as it is. A vendor release waits for its integration; an unregistered store and
-- swap writes name no cause and no lever (`docs/system-doctor-design.md`).
local CALM_RULES = { updater = { ["event-waiting"] = true },
  system = { ["unregistered-store"] = true, ["swap-writes"] = true } }
-- The machine itself at risk (its disk filling, its swap exhausted): red whoever's cause.
local AT_RISK = { ["free-space"] = true, ["dir-growth"] = true, swap = true }
local held = {}
local RED_DAYS_KEEP = 8
local DOCTORS = {
  { key = "llm", env = "LLM_DOCTOR", ledger = "doctor-ledger.json" },
  { key = "harness", env = "HARNESS_DOCTOR", ledgerEnv = "HARNESS_LEDGER",
    ledger = "harness-ledger.json" },
  { key = "updater", env = "UPDATER_DOCTOR", ledger = "updater-ledger.json" },
  { key = "code", env = "CODE_DOCTOR", ledger = "code-ledger.json" },
  { key = "system", env = "SYSTEM_DOCTOR", ledger = "system-ledger.json" },
}
local CODE_GROUPS = { { key = "dead", name = "Dead" }, { key = "heavy", name = "Heavy" },
  { key = "duplicate", name = "Duplicate" }, { key = "promise", name = "Promise" }, { key = "ledger", name = "Ledger" } }
-- A donor doctor's group (and its level-0 row "<Group>: …") → the summary that shows it; speed = Lost time.
local SHOWN_BY = {
  harness = { ["Suite audits"] = "speed", ["Test flakes"] = "speed", ["Limiter holds"] = "speed", Speed = "speed",
    Tests = "speed", ["Wait classes"] = "speed", ["Hook waits"] = "speed", Hooks = "speed", Waits = "speed",
    ["Slow periods"] = "speed", Collector = "speed", ["CPU audits"] = "system", Load = "system",
    ["Memory guard"] = "system", Growth = "system" },
  llm = { debt = "harness" },
}
local OWN_DOCTOR_ROWS = { ["Lost time"] = true, Spend = true }

local fixTasks, jsonCache, built = {}, {}, nil
local night, nightTask = { at = 0 }, nil

local function clock()
  local timer = hs.timer
  return timer and timer.secondsSinceEpoch and timer.secondsSinceEpoch() or os.time()
end

local function dirFor(field, env, default)
  if M[field] then return M[field] end
  local override = os.getenv(env)
  if override and override ~= "" then return override end
  return home .. default
end

local function running(task)
  if not task then return false end
  local ok, alive = pcall(task.isRunning, task)
  return ok and alive == true
end

local function plural(count, word)
  return string.format("%d %s%s", count, word, count == 1 and "" or "s")
end

-- One styled title per text: the same object lets style.mono's settled cache hit on every later build.
-- The memo is per resolved tone: the dim colour follows the appearance.
local dimTitles, dimCount, dimTone = {}, 0, nil
local function dim(text)
  local color = limits.dimColor()
  local tone = type(color) == "table" and string.format("%s %s %s %s", color.red, color.green, color.blue, color.alpha)
    or tostring(color)
  if tone ~= dimTone then dimTitles, dimCount, dimTone = {}, 0, tone end
  local title = dimTitles[text]
  if not title then
    if dimCount >= 512 then dimTitles, dimCount = {}, 0 end
    title = infoTitle(text, false, true)
    dimTitles[text], dimCount = title, dimCount + 1
  end
  return { title = title, disabled = true }
end

local function plainText(title) return type(title) == "string" and title or title:getString() end
local function cells(text) return utf8.len(text) or #text end

local function wrap(text, width)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    while cells(word) > width do
      if line ~= "" then lines[#lines + 1], line = line, "" end
      local cut = utf8.offset(word, width + 1) or #word + 1
      lines[#lines + 1], word = word:sub(1, cut - 1), word:sub(cut)
    end
    if line == "" then
      line = word
    elseif cells(line) + 1 + cells(word) <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1], line = line, word
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

local function clipEnd(plain, width)
  local head = plain:sub(1, utf8.offset(plain, width) - 1)
  for _, mark in ipairs({ " · ", ": ", " " }) do
    local at, from = nil, 1
    while true do
      local found = head:find(mark, from, true)
      if not found then break end
      at, from = found, found + 1
    end
    if at and at > #head / 2 then return at - 1 end
  end
  return #head
end

local function detailRows(text)
  local rows = {}
  for _, line in ipairs(wrap(text, ROW_CELLS)) do rows[#rows + 1] = dim(line) end
  return rows
end

-- A macOS submenu is as wide as its widest row: one long row stretches every row beside it.
local function fitRowUnsafe(item)
  local plain = item.title and item.title ~= "-" and plainText(item.title)
  if not plain or cells(plain) <= ROW_CELLS then return item end
  local cut = clipEnd(plain, ROW_CELLS)
  local fitted = {}
  for key, value in pairs(item) do fitted[key] = value end
  if type(item.title) == "string" then
    fitted.title = plain:sub(1, cut) .. "…"
  else
    local last = utf8.offset(plain, utf8.len(plain:sub(1, cut)))
    fitted.title = item.title:sub(1, cut) .. item.title:sub(last, cut):setString("…")
  end
  if item.fn then return fitted end
  local menu = detailRows(plain)
  if type(item.menu) == "table" then
    menu[#menu + 1] = { title = "-" }
    for _, sub in ipairs(item.menu) do menu[#menu + 1] = sub end
  end
  fitted.menu, fitted.disabled = menu, nil
  return fitted
end

local function fitRow(item)
  local ok, fitted = pcall(fitRowUnsafe, item)
  return ok and fitted or item
end

local function readJson(path, format)
  local attrs = hs.fs.attributes(path)
  if not attrs then jsonCache[path] = nil return nil end
  local key = string.format("%s:%s:%s", attrs.ino or "", attrs.modification or "", attrs.size or "")
  local hit = jsonCache[path]
  if hit and hit.key == key then return hit.value end
  local ok, value = pcall(function()
    if not format then return limits.readJsonTable(path) end
    local handle = io.open(path)
    if not handle then return nil end
    local rows = {}
    for line in handle:lines() do
      if format == "header" and not line:match("^[TH]\t") then break end
      -- A line that is no whole object is skipped before hs.json.decode: LuaSkin logs every failed
      -- decode to the console as an ERROR, pcall or not.
      local payload = format == "header" and line:match("^H\t(.*)") or format == "days" and line:match("^{.*}$")
      if payload then
        local valid, row = pcall(hs.json.decode, payload)
        if valid and type(row) == "table" then
          if format == "header" then handle:close() return row end
          rows[#rows + 1] = row
        end
      end
    end
    handle:close()
    return format == "days" and rows or nil
  end)
  value = ok and type(value) == "table" and value or nil
  jsonCache[path] = { key = key, value = value }
  return value
end

-- Run ids are <doctor>-<area>-<stamp>-<hex>, so a name sort orders areas, not time. A new record moves
-- the directory's size; a record rewritten by rename does not, so the hit re-reads the newest file by name.
-- The five doctors rescan in the same build: one listing of the directory feeds all of them.
local RUNS_RESCAN_S, RUNS_SHARE_S = 60, 2
local runsCache, runsListing = {}, nil
local function runNames(runs, key)
  if runsListing and runsListing.key == key and clock() - runsListing.at < RUNS_SHARE_S then
    return runsListing.names
  end
  local ok, iter, state = pcall(hs.fs.dir, runs)
  if not ok or not iter then runsListing = nil return nil end
  local names = {}
  for name in iter, state do
    if name:match("%.json$") then names[#names + 1] = name end
  end
  runsListing = key and { key = key, at = clock(), names = names } or nil
  return names
end

local function latestRun(doctor)
  local runs = dirFor("doctorsDir", "DOCTORS_DIR", "/.cache/doctors") .. "/runs"
  local attrs = hs.fs.attributes(runs)
  local key = attrs and string.format("%s:%s:%s:%s", runs, attrs.ino or "", attrs.modification or "", attrs.size or "")
  local hit = runsCache[doctor]
  if hit and key and hit.key == key and clock() - hit.at < RUNS_RESCAN_S then
    return hit.name and readJson(runs .. "/" .. hit.name)
  end
  local names = runNames(runs, key)
  if not names then runsCache[doctor] = nil return nil end
  local prefix, newest, newestAt, newestName = doctor .. "-", nil, nil, nil
  for _, name in ipairs(names) do
    if name:sub(1, #prefix) == prefix then
      local run = readJson(runs .. "/" .. name)
      local at = run and (limits.parseTime(run.created_at) or limits.parseTime(run.launched_at)) or 0
      if run and (not newest or at > newestAt or at == newestAt and name > newestName) then
        newest, newestAt, newestName = run, at, name
      end
    end
  end
  runsCache[doctor] = key and { key = key, at = clock(), name = newestName } or nil
  return newest
end

local function runState(run)
  if type(run) ~= "table" then return nil end
  local closed, abandoned = limits.parseTime(run.closed_at), limits.parseTime(run.abandoned_at)
  local failed = limits.parseTime(run.failed_at)
  if closed then return "closed", closed end
  if failed then return "failed", failed end
  if abandoned then return "abandoned", abandoned end
  return "open", limits.parseTime(run.launched_at) or limits.parseTime(run.created_at)
end

-- Problem ids an open fixer run holds: a run launched within FIX_BUSY_S, neither closed, abandoned nor failed. The
-- stamp in its name skips the old records unread.
local function heldIds(now)
  local runs = dirFor("doctorsDir", "DOCTORS_DIR", "/.cache/doctors") .. "/runs"
  local attrs = hs.fs.attributes(runs)
  local key = attrs and string.format("%s:%s:%s:%s", runs, attrs.ino or "", attrs.modification or "", attrs.size or "")
  local ids = {}
  for _, name in ipairs(attrs and runNames(runs, key) or {}) do
    local y, mo, d, h, mi, s = name:match("%-(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z%-%x+%.json$")
    local at = y and limits.parseTime(string.format("%s-%s-%sT%s:%s:%sZ", y, mo, d, h, mi, s))
    if at and now - at < FIX_BUSY_S then
      local run = readJson(runs .. "/" .. name)
      if runState(run) == "open" then
        for _, problem in ipairs(type(run.problems) == "table" and run.problems or {}) do
          if type(problem) == "table" and problem.id ~= nil then ids[tostring(problem.id)] = true end
        end
      end
    end
  end
  return ids
end

-- Red: true now (new, open, regressed), something acts on it (not a calm rule; a System cause that is no fix target
-- is the doctor's own `report only`), and no open fixer run holds it.
local function isRed(key, problem)
  if type(problem) ~= "table" or not LOUD[problem.state] or held[tostring(problem.id)] then return false end
  if (CALM_RULES[key] or {})[problem.rule] then return false end
  local cause = problem.cause
  return not (key == "system" and type(cause) == "table" and cause.name ~= nil and not cause.fix_target
    and not AT_RISK[problem.rule])
end

local function verdictCounts(decisions)
  local counts = {}
  for _, decision in pairs(type(decisions) == "table" and decisions or {}) do
    local id = type(decision) == "table" and decision.id or type(decision) == "string" and decision:match("^([^\t]*)\t")
    local verdict = type(decision) == "table" and (decision.verdict or decision.decision)
      or type(decision) == "string" and (decision:match("^[^\t]*\t([^\t]+)") or decision)
    if type(verdict) == "string" and id ~= "judge" then counts[verdict] = (counts[verdict] or 0) + 1 end
  end
  local parts, known = {}, {}
  for _, verdict in ipairs(VERDICTS) do
    known[verdict] = true
    if counts[verdict] then parts[#parts + 1] = counts[verdict] .. " " .. verdict end
  end
  local rest = {}
  for verdict in pairs(counts) do
    if not known[verdict] then rest[#rest + 1] = verdict end
  end
  table.sort(rest)
  for _, verdict in ipairs(rest) do parts[#parts + 1] = counts[verdict] .. " " .. verdict end
  return parts
end

local function fixerRow(run, now)
  local state, at = runState(run)
  if not state then return dim("fixer: never ran") end
  if state == "open" then return dim(at and "fixer: running for " .. style.age(now - at) or "fixer: running") end
  if state == "abandoned" then return dim("fixer: abandoned " .. style.ago(now - at)) end
  if state == "failed" then
    local note = type(run.note) == "string" and run.note ~= "" and run.note or nil
    return { title = infoTitle("fixer: failed " .. style.ago(now - at), true), menu = note and { dim(note) },
      disabled = not note or nil }
  end
  local parts = { "fixer: ran " .. style.ago(now - at), "closed" }
  for _, part in ipairs(verdictCounts(run.decisions)) do parts[#parts + 1] = part end
  return dim(table.concat(parts, " · "))
end

local function lastLine(text)
  local last
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    if line:match("%S") then last = line end
  end
  return last
end

local function launch(key, path, args, label, launched, after)
  if running(fixTasks[key]) then return end
  local ok, task = pcall(hs.task.new, path, function(code, stdout, stderr)
    fixTasks[key], built = nil, nil
    if after then after() end
    local line = code == 0 and (lastLine(stdout) or lastLine(stderr))
      or (lastLine(stderr) or lastLine(stdout))
    if code == 0 then
      hs.alert.show(line or launched, 3)
    else
      hs.alert.show(label .. " failed (exit " .. tostring(code) .. "): " .. (line or "no output"), 5)
    end
  end, args)
  if not ok or not task then
    hs.alert.show(label .. " failed: could not start " .. tostring(path), 5)
    return
  end
  task:setEnvironment(limits.diagnosticsEnvironment())
  fixTasks[key], built = task, nil
  if not task:start() then
    fixTasks[key] = nil
    hs.alert.show(label .. " failed: could not start " .. tostring(path), 5)
  end
end

local function nightRunPath() return M.nightRunCmd or (repoRoot and repoRoot .. "/bin/night-run") end

local function startNight(label, question, text, button, args)
  if running(fixTasks.night) or night.running then return end
  if hs.dialog.blockAlert(question, text, "Cancel", button) ~= button then return end
  local argv = { "start" }
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  launch("night", nightRunPath(), argv, label, label .. " started", function() night.at = 0 end)
end

function M.runEverything()
  startNight("Run everything", "Run everything now?",
    "Every doctor fixer, every vendor update and the cleanup, in one orchestrator chat that works for hours.", "Run", {})
end

function M.cleanupNow()
  startNight("Land night branches", "Land night branches now?",
    "Lands the finished night branches, then one debt round, in one orchestrator chat. No fixers, no updates.", "Run",
    { "--cleanup" })
end

function M.resumeNight(ref)
  if not night.id then return end
  startNight("Continue", ref and "Continue this job?" or "Continue the unfinished night work?",
    (ref and "Job " .. ref or "Every unfinished job, then the cleanup,") .. " of night " .. night.id
      .. ", in its own worktree and branch, in one orchestrator chat.", "Continue",
    ref and { "--resume", night.id, "--job", ref } or { "--resume", night.id })
end

local function nightItem(title, fn)
  if running(fixTasks.night) then return dim(title:match("^(.-) now") .. " — opening…") end
  if night.running then return dim(title:match("^(.-) now") .. " — a night run is going") end
  return { title = infoTitle(title), fn = fn }
end

local refreshTasks = {}
style.busySource("Doctors", function()
  for _, task in pairs(refreshTasks) do
    if running(task) then return true end
  end
  return running(limits.llmDoctorTask) or running(limits.harnessDoctorTask) or running(limits.doctorRescanTask)
end)

local function refreshDoctor(key, args, title, documentPath)
  if running(refreshTasks[key]) then return end
  local name = key:sub(1, 1):upper() .. key:sub(2) .. " doctor"
  local path = M[key .. "DoctorCmd"] or (repoRoot and repoRoot .. "/bin/" .. key .. "-doctor")
  local ok, task = pcall(hs.task.new, path, function(code, stdout, stderr)
    refreshTasks[key], built = nil, nil
    style.busyChanged()
    if code ~= 0 then
      hs.alert.show(name .. " failed: " .. (lastLine(stderr) or lastLine(stdout) or ("exit " .. tostring(code))), 5)
    else
      hs.alert.show(title(readJson(documentPath())), 2.5)
    end
  end, args)
  if not ok or not task then
    hs.alert.show(name .. ": could not start " .. tostring(path), 5)
    return
  end
  local environment = limits.diagnosticsEnvironment()
  environment.DOCTOR_TRIGGER = "menu"
  task:setEnvironment(environment)
  refreshTasks[key], built = task, nil
  if not task:start() then
    refreshTasks[key] = nil
    hs.alert.show(name .. ": could not start " .. tostring(path), 5)
  end
  style.busyChanged()
end

local function refreshRows(items, key, refresh)
  items[#items + 1] = { title = "-" }
  items[#items + 1] = running(refreshTasks[key]) and dim("refreshing…") or { title = infoTitle("Refresh"), fn = refresh }
end

local function blindSpotsRow(document)
  local spots = {}
  for _, spot in ipairs(type(document.blind_spots) == "table" and document.blind_spots or {}) do
    if type(spot) == "table" then
      local detail = {}
      if type(spot.reason) == "string" then detail = detailRows("why: " .. spot.reason) end
      if type(spot.would_catch_if) == "string" then
        for _, row in ipairs(detailRows("would catch it: " .. spot.would_catch_if)) do detail[#detail + 1] = row end
      end
      spots[#spots + 1] = fitRow({ title = infoTitle(tostring(spot.what or spot.id or "?"), false, true),
        menu = #detail > 0 and detail or nil, disabled = #detail == 0 or nil })
    end
  end
  return #spots > 0 and { title = infoTitle("not measured", false, true), menu = spots } or nil
end

local function documentStatus(document)
  local count = document and tonumber(document.problem_count) or 0
  local status = not document and "nodata" or ({ ok = true, problems = true, blind = true, error = true })[document.status]
    and document.status or count > 0 and "problems" or "ok"
  return count, status, count > 0 or status == "error"
end

local function updaterPath()
  return dirFor("updaterDoctorDir", "UPDATER_DOCTOR_DIR", "/.cache/updater-doctor") .. "/latest.json"
end

local function updatesPending(document)
  local pending = 0
  for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
    if type(problem) == "table" and problem.rule == "cli-behind" and not LOUD[problem.state] then pending = pending + 1 end
  end
  return pending
end

local function updaterTitle(document)
  if not document then return "Updater doctor: no data yet" end
  local count = tonumber(document.problem_count) or 0
  local parts = {}
  if count > 0 then parts[#parts + 1] = plural(count, "problem") end
  local pending = updatesPending(document)
  if pending > 0 then parts[#parts + 1] = (pending == 1 and "update" or "updates") .. " pending" end
  if document.status == "blind" then parts[#parts + 1] = "blind" end
  if document.status == "error" then parts[#parts + 1] = "collector failed" end
  local title = "Updater doctor: " .. (#parts > 0 and table.concat(parts, " · ") or "ok")
  local asOf = tonumber(document.as_of_s)
  if asOf and os.time() - asOf >= UPDATER_STALE_S then
    title = title .. " · stale " .. style.age(os.time() - asOf)
  end
  return title
end

function M.refreshUpdater() refreshDoctor("updater", {}, updaterTitle, updaterPath) end

local HANDOFF_PHASES = { { "done", "✓", "done" }, { "queued", "→", "queued" }, { "egor", "!", "To: Egor" } }

local function handoffRows(handoffs)
  local groups, width, rows = {}, 1, {}
  for _, handoff in ipairs(handoffs) do
    groups[handoff.phase] = groups[handoff.phase] or {}
    table.insert(groups[handoff.phase], handoff)
    width = math.max(width, #tostring(#groups[handoff.phase]))
  end
  for _, phase in ipairs(HANDOFF_PHASES) do
    local group = groups[phase[1]]
    if group then
      local titles = {}
      for _, handoff in ipairs(group) do
        titles[#titles + 1] = fitRow({ title = infoTitle(handoff.title), menu = detailRows(handoff.path) })
      end
      rows[#rows + 1] = fitRow({ title = infoTitle(phase[2] .. string.format(" %" .. width .. "d  ", #group) .. phase[3],
        phase[1] == "egor", phase[1] == "done"), menu = titles })
    end
  end
  return rows
end

local JOB_STATES = { { "done", "✓" }, { "open", "→" }, { "alert", "!" } }

local function jobState(job) return job.red and "alert" or job.quiet and "done" or "open" end

-- A direction per row, its jobs one level down; a count column per state, blank where none.
local function directionRows(groups)
  local name, digits = 1, { done = 1, open = 1, alert = 1 }
  for _, group in ipairs(groups) do
    name = math.max(name, cells(group.way))
    for key in pairs(digits) do digits[key] = math.max(digits[key], #tostring(group[key])) end
  end
  table.sort(groups, function(a, b)
    if (a.alert > 0) ~= (b.alert > 0) then return a.alert > 0 end
    if (a.open > 0) ~= (b.open > 0) then return a.open > 0 end
    if #a.items ~= #b.items then return #a.items > #b.items end
    return a.way < b.way
  end)
  local rows = {}
  for _, group in ipairs(groups) do
    local text = string.format("%-" .. name .. "s", group.way)
    for _, state in ipairs(JOB_STATES) do
      local count, width = group[state[1]], digits[state[1]]
      text = text .. "  " .. (count > 0 and state[2] .. string.rep(" ", width + 1 - #tostring(count)) .. count
        or string.rep(" ", width + 2))
    end
    table.sort(group.items, function(a, b)
      if a.rank ~= b.rank then return a.rank < b.rank end
      return a.index < b.index
    end)
    local menu = {}
    for _, entry in ipairs(group.items) do menu[#menu + 1] = entry.item end
    rows[#rows + 1] = fitRow({ title = infoTitle(text:gsub("%s+$", ""), group.alert > 0,
      group.alert == 0 and group.open == 0), menu = menu })
  end
  return rows
end

local GREEN = style.tone(style.GREEN, false)
local TONES = { [style.RED] = "r", [style.DIM] = "m", [GREEN] = "g" }
local styledCache, styledCount = {}, 0

local function styled(segments)
  local key = {}
  for index, segment in ipairs(segments) do key[index] = (TONES[segment[2]] or "-") .. segment[1] end
  key = table.concat(key, "\0")
  if styledCache[key] then return styledCache[key] end
  local title
  for _, segment in ipairs(segments) do
    local text, tone = segment[1], segment[2]
    local piece = tone == GREEN and hs.styledtext.new(text, { font = style.MONO, color = tone })
      or infoTitle(text, tone == style.RED, tone == style.DIM)
    title = title and title .. piece or piece
  end
  if styledCount >= 256 then styledCache, styledCount = {}, 0 end
  styledCache[key], styledCount = title, styledCount + 1
  return title
end

-- The night's landed fixes as their proofs mature: min/day gained, ✓ proven, red ! measured slower, → still pending.
local function speedRow(speed)
  local segments = { { string.format("%+.1f min/day", speed.gain), speed.gain > 0 and GREEN or nil } }
  for _, part in ipairs({ { "✓", speed.proven }, { "!", speed.slower, style.RED }, { "→", speed.pending } }) do
    if part[2] > 0 then segments[#segments + 1] = { "  " .. part[1] .. " " .. part[2], part[3] } end
  end
  return fitRow({ title = styled(segments), disabled = true })
end

local function nightEntry()
  local jobs, groups, byWay, resumable, others = {}, {}, {}, 0, 0
  local idle = not night.running and not running(fixTasks.night)
  for index, job in ipairs(night.jobs) do
    local item = { title = infoTitle(job.text, job.red, job.quiet) }
    if job.detail ~= "" then item.menu = detailRows(job.detail) end
    if job.resumable and idle then
      resumable, others = resumable + 1, others + (job.kind == "debt" and 0 or 1)
      item.menu = item.menu or {}
      if #item.menu > 0 then item.menu[#item.menu + 1] = { title = "-" } end
      item.menu[#item.menu + 1] = { title = infoTitle("Continue this job"), fn = function() M.resumeNight(job.ref) end }
    end
    item.disabled = not item.menu or nil
    if job.way and job.way ~= "" then
      local group = byWay[job.way]
      if not group then
        group = { way = job.way, done = 0, open = 0, alert = 0, items = {} }
        byWay[job.way], groups[#groups + 1] = group, group
      end
      local state = jobState(job)
      group[state] = group[state] + 1
      group.items[#group.items + 1] = { item = fitRow(item), index = index,
        rank = state == "alert" and 1 or state == "open" and 2 or 3 }
    else
      jobs[#jobs + 1] = fitRow(item)
    end
  end
  for _, section in ipairs({ handoffRows(night.handoffs or {}), directionRows(groups) }) do
    if #section > 0 and #jobs > 0 then jobs[#jobs + 1] = { title = "-" } end
    for _, row in ipairs(section) do jobs[#jobs + 1] = row end
  end
  if resumable > 0 then
    jobs[#jobs + 1] = { title = "-" }
    jobs[#jobs + 1] = { title = infoTitle(others > 0 and "Continue unfinished (" .. plural(others, "job") .. ") + cleanup"
      or "Continue the unfinished cleanup"), fn = function() M.resumeNight(nil) end }
  end
  if night.speed then
    if #jobs > 0 then table.insert(jobs, 1, { title = "-" }) end
    table.insert(jobs, 1, speedRow(night.speed))
  end
  return { title = infoTitle(night.text, night.red, night.quiet), menu = #jobs > 0 and jobs or nil,
    disabled = #jobs == 0 or nil, problems = 0 }
end

local function parseNight(stdout)
  local lines = {}
  for line in stdout:gmatch("[^\n]+") do lines[#lines + 1] = line end
  local text, tone, busy, id = (lines[1] or ""):match("^([^\t]*)\t([012])\t?([01]?)\t?([^\t]*)")
  local jobs, handoffs, speed = {}, {}, nil
  for index = 2, #lines do
    local fields = {}
    for field in (lines[index] .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    if fields[1] == "speed" and #fields >= 5 and tonumber(fields[2]) then
      speed = { gain = tonumber(fields[2]), proven = tonumber(fields[3]) or 0, slower = tonumber(fields[4]) or 0,
        pending = tonumber(fields[5]) or 0 }
    elseif fields[1] == "handoff" and #fields >= 4 then
      handoffs[#handoffs + 1] = { phase = fields[2], title = fields[3], path = fields[4] }
    elseif fields[2] == "0" or fields[2] == "1" or fields[2] == "2" then
      jobs[#jobs + 1] = { text = fields[1], red = fields[2] == "1", quiet = fields[2] == "0", detail = fields[3] or "",
        ref = fields[4], kind = fields[5], resumable = fields[6] == "1" and fields[4] ~= nil and fields[4] ~= "",
        way = fields[7] }
    end
  end
  return { at = os.time(), text = text ~= "" and text or nil, red = tone == "1", quiet = tone == "0",
    running = busy == "1", jobs = jobs, handoffs = handoffs, speed = speed, id = id ~= "" and id or nil }
end

-- The last good reading outlives a reload and a failed refresh, so Last night never blinks out (Egor 2026-10-20).
local function nightCache() return dirFor("doctorsDir", "DOCTORS_DIR", "/.cache/doctors") .. "/night-latest.txt" end

function M.refreshNight()
  if running(nightTask) then return end
  if night.at == 0 and not night.text then
    local file = io.open(nightCache())
    if file then night = parseNight(file:read("a") or "") night.at = 0 file:close() end
  end
  local path = nightRunPath()
  local ok, task = pcall(hs.task.new, path, function(code, stdout)
    nightTask, built = nil, nil
    if code ~= 0 then night.at = os.time() return end
    night = parseNight(stdout or "")
    local file = io.open(nightCache(), "w")
    if file then file:write(stdout or "") file:close() end
  end, { "latest", "--menu" })
  if not ok or not task then night.at = os.time() return end
  task:setEnvironment(limits.diagnosticsEnvironment())
  nightTask = task
  if not task:start() then nightTask, night.at = nil, os.time() end
end

local function vendorMenu(vendor, now)
  local items = {}
  for _, model in ipairs(type(vendor.models) == "table" and vendor.models or {}) do
    local name = type(model) == "table" and (model.id or model.name or model.slug) or model
    items[#items + 1] = dim(tostring(name))
  end
  if #items == 0 then items[1] = dim("no models listed") end
  local events = {}
  for _, event in ipairs(type(vendor.events) == "table" and vendor.events or {}) do
    if type(event) == "table" then
      events[#events + 1] = { event = event, at = limits.parseTime(event.closed_at) or limits.parseTime(event.launched_at)
        or limits.parseTime(event.created_at) or 0 }
    end
  end
  table.sort(events, function(a, b) return a.at > b.at end)
  if #events > 0 then items[#items + 1] = { title = "-" } end
  for index = 1, math.min(#events, 5) do
    local event, at = events[index].event, events[index].at
    local parts = { tostring(event.id or "event"), tostring(event.status or "?") }
    if event.from or event.to then parts[#parts + 1] = tostring(event.from or "?") .. " → " .. tostring(event.to or "?") end
    if at > 0 then parts[#parts + 1] = style.ago(now - at) end
    local item = { title = infoTitle(table.concat(parts, " · "), false, not LOUD[event.status]) }
    local changed = {}
    for _, change in ipairs(type(event.changed) == "table" and event.changed or {}) do changed[#changed + 1] = dim(tostring(change)) end
    if #changed > 0 then item.menu = changed else item.disabled = true end
    items[#items + 1] = item
  end
  return items
end

local function updaterEntry(now)
  local document = readJson(updaterPath())
  local items = {}
  if not document then
    items[1] = dim("no data yet")
  else
    local failure = type(document.self) == "table" and document.self.error
    if document.status == "error" and type(failure) == "string" then
      items[#items + 1] = { title = infoTitle(failure, true), disabled = true }
    end
    for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
      if type(problem) == "table" then
        local loud = LOUD[problem.state] == true
        items[#items + 1] = { title = infoTitle(tostring(problem.fact or problem.id or "?"), loud, not loud), disabled = true }
      end
    end
    for _, vendor in ipairs(type(document.vendors) == "table" and document.vendors or {}) do
      if type(vendor) == "table" then
        local checked = limits.parseTime(vendor.checked_at)
        local native = type(vendor.native) == "string" and vendor.native ~= vendor.installed and vendor.native or nil
        local text = string.format("%s %s%s · %s", tostring(vendor.vendor or "?"), tostring(vendor.installed or "?"),
          native and (" · native " .. native) or "", checked and ("checked " .. style.ago(now - checked)) or "never checked")
        local behind = type(vendor.latest) == "string" and vendor.latest ~= ""
          and (vendor.latest ~= vendor.installed or native ~= nil and vendor.latest ~= native)
        if behind then text = text .. " · latest " .. tostring(vendor.latest) end
        items[#items + 1] = { title = infoTitle(text, false, not behind), menu = vendorMenu(vendor, now) }
      end
    end
    items[#items + 1] = blindSpotsRow(document)
  end
  refreshRows(items, "updater", M.refreshUpdater)
  local count, status, loud = documentStatus(document)
  local quiet = not loud and status ~= "blind" and not (document and updatesPending(document) > 0)
  return { title = infoTitle(updaterTitle(document), loud, quiet), menu = items,
    problems = count, status = status }
end

local function codePath()
  return dirFor("codeDoctorDir", "CODE_DOCTOR_DIR", "/.cache/code-doctor") .. "/latest.json"
end

local function codeTitle(document)
  if not document then return "Code doctor: no data yet" end
  local count = tonumber(document.problem_count) or 0
  local title = "Code doctor: " .. (count > 0 and plural(count, "problem") or "ok")
  if document.status == "blind" then title = title .. " · blind" end
  if document.status == "error" then title = title .. " · collector failed" end
  return title
end

function M.refreshCode() refreshDoctor("code", { "refresh", "--quiet" }, codeTitle, codePath) end

local function codeEntry()
  local document = readJson(codePath())
  local items = {}
  if not document then
    items[1] = dim("no data yet")
  else
    local failure = type(document.self) == "table" and document.self.error
    if document.status == "error" and type(failure) == "string" then
      items[#items + 1] = { title = infoTitle(failure, true), disabled = true }
    end
    local groups = type(document.groups) == "table" and document.groups or {}
    local listed = {}
    for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
      if type(problem) == "table" then
        local group = tostring(problem.group or "dead")
        listed[group] = listed[group] or {}
        local loud = LOUD[problem.state] == true
        local rows = type(problem.plan) == "string" and detailRows("plan: " .. problem.plan) or {}
        listed[group][#listed[group] + 1] = fitRow({ title = infoTitle(tostring(problem.fact or problem.id or "?"), loud,
          not loud), menu = #rows > 0 and rows or nil, disabled = #rows == 0 or nil })
      end
    end
    for _, group in ipairs(CODE_GROUPS) do
      local count = tonumber(groups[group.key]) or 0
      if group.key ~= "ledger" or count > 0 then
        items[#items + 1] = { title = infoTitle(group.name .. ": " .. plural(count, "problem"), count > 0, count == 0),
          menu = listed[group.key], disabled = not listed[group.key] or nil }
      end
    end
    local candidates = type(document.candidates) == "table" and document.candidates or {}
    local waiting = {}
    for _, candidate in ipairs(type(candidates.top) == "table" and candidates.top or {}) do
      if type(candidate) == "table" then
        waiting[#waiting + 1] = fitRow({ title = infoTitle(tostring(candidate.group or "?") .. " · " ..
          tostring(candidate.detail or candidate.id or "?"), false, true), disabled = true })
      end
    end
    items[#items + 1] = { title = infoTitle("candidates waiting: " .. tostring(tonumber(candidates.waiting) or 0), false, true),
      menu = #waiting > 0 and waiting or nil, disabled = #waiting == 0 or nil }
    local cost = type(document.cost) == "table" and document.cost or {}
    local gained = type(document.yield) == "table" and document.yield or {}
    items[#items + 1] = dim(string.format("cost %dk tokens · %d min · yield %d lines, %d causes closed",
      math.floor((tonumber(cost.tokens) or 0) / 1000), math.floor((tonumber(cost.wall_s) or 0) / 60),
      tonumber(gained.lines_removed) or 0, tonumber(gained.causes_closed) or 0))
    items[#items + 1] = blindSpotsRow(document)
  end
  refreshRows(items, "code", M.refreshCode)
  local count, status, loud = documentStatus(document)
  return { title = infoTitle(codeTitle(document), loud, not loud and status ~= "blind"), menu = items,
    problems = count, status = status }
end

local function systemPath()
  return dirFor("systemDoctorDir", "SYSTEM_DOCTOR_DIR", "/.cache/system-doctor") .. "/latest.json"
end

local function systemTitle(document)
  if not document then return "System doctor: no data yet" end
  local count = tonumber(document.problem_count) or 0
  local title = "System doctor: " .. (count > 0 and plural(count, "problem") or "ok")
  if document.status == "blind" then title = title .. " · blind" end
  if document.status == "error" then title = title .. " · collector failed" end
  local asOf = tonumber(document.as_of_s)
  if asOf and os.time() - asOf >= SYSTEM_STALE_S then title = title .. " · stale " .. style.age(os.time() - asOf) end
  return title
end

function M.refreshSystem() refreshDoctor("system", {}, systemTitle, systemPath) end

local function share(value) return value and string.format("%d %%", math.floor(value * 100 + 0.5)) or "–" end
local function number(value, format) return value and string.format(format, value) or "–" end

local function systemEntry(now)
  local document = readJson(systemPath())
  local items = {}
  if not document then
    items[1] = dim("no data yet")
  else
    local failure = type(document.self) == "table" and document.self.error
    if document.status == "error" and type(failure) == "string" then
      items[#items + 1] = { title = infoTitle(failure, true), disabled = true }
    end
    for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
      if type(problem) == "table" then
        local loud = LOUD[problem.state] == true
        local rows = {}
        for _, item in ipairs(type(problem.evidence) == "table" and problem.evidence or {}) do
          if type(item) == "table" and type(item.excerpt) == "string" then rows[#rows + 1] = dim(item.excerpt) end
        end
        items[#items + 1] = fitRow({ title = infoTitle(tostring(problem.fact or problem.id or "?"), loud, not loud),
          menu = #rows > 0 and rows or nil, disabled = #rows == 0 or nil })
      end
    end
    local m = type(document.measures) == "table" and document.measures or {}
    items[#items + 1] = dim(string.format("new processes %s/s · kernel %s of CPU · busy %s",
      number(m.births_s, "%.0f"), share(m.kernel), share(m.busy)))
    items[#items + 1] = dim(string.format("compressed %s of RAM · swap %s used · %s page-ins/s",
      share(m.comp_share), share(m.swap_share), number(m.pagein_s, "%.0f")))
    items[#items + 1] = dim(string.format("SSD writes %s GB/day · reads %s GB/day (%s days) · swap writes %s GiB/day",
      number(m.ssd_gb_day_7d, "%.0f"), number(m.ssd_read_gb_day_7d, "%.0f"), number(m.days_measured, "%.0f"),
      number(m.swap_gib_day, "%.1f")))
    local volumes = {}
    for name, gib in pairs(type(m.free_gib) == "table" and m.free_gib or {}) do
      volumes[#volumes + 1] = string.format("%s %.0f GiB", name, tonumber(gib) or 0)
    end
    table.sort(volumes)
    if #volumes > 0 then items[#items + 1] = dim("free " .. table.concat(volumes, " · ")) end
    local causes = type(document.causes) == "table" and document.causes or {}
    local born, cpu = {}, {}
    for _, row in ipairs(type(causes.births) == "table" and causes.births or {}) do
      born[#born + 1] = dim(string.format("%s %s · %s", tostring(row[1]), share(tonumber(row[2])), tostring(row[3])))
    end
    for _, row in ipairs(type(causes.cpu) == "table" and causes.cpu or {}) do
      cpu[#cpu + 1] = dim(string.format("%s %.2f cores · reaped %.2f · %s", tostring(row[1]), tonumber(row[2]) or 0,
        tonumber(row[3]) or 0, tostring(row[4])))
    end
    items[#items + 1] = { title = infoTitle("births by cause", false, true), menu = #born > 0 and born or nil,
      disabled = #born == 0 or nil }
    items[#items + 1] = { title = infoTitle("CPU by cause", false, true), menu = #cpu > 0 and cpu or nil,
      disabled = #cpu == 0 or nil }
    local night = type(document.nightly) == "table" and document.nightly or nil
    if night then
      local reports, parts = {}, {}
      for kind, count in pairs(type(night.reports) == "table" and night.reports or {}) do
        parts[#parts + 1] = kind .. " " .. tostring(count)
      end
      table.sort(parts)
      for _, row in ipairs(type(night.processes) == "table" and night.processes or {}) do
        reports[#reports + 1] = dim(string.format("%s %s ×%s · %s", tostring(row[1]), tostring(row[2]), tostring(row[3]),
          tostring(row[4])))
      end
      for _, row in ipairs(type(night.caches) == "table" and night.caches or {}) do
        reports[#reports + 1] = dim(string.format("cache %s %.1f GiB", tostring(row[1]), tonumber(row[2]) or 0))
      end
      local at = tonumber(night.as_of_s)
      items[#items + 1] = fitRow({ title = infoTitle("nightly " .. (at and style.ago(now - at) or "?") .. " · "
        .. (#parts > 0 and table.concat(parts, " · ") or "no reports"), false, true),
        menu = #reports > 0 and reports or nil, disabled = #reports == 0 or nil })
    end
    items[#items + 1] = blindSpotsRow(document)
  end
  refreshRows(items, "system", M.refreshSystem)
  local count, status, loud = documentStatus(document)
  return { title = infoTitle(systemTitle(document), loud, not loud and status ~= "blind"), menu = items,
    problems = count, status = status }
end

local function speedDir() return dirFor("speedDoctorDir", "SPEED_DOCTOR_DIR", "/.cache/speed-doctor") end

local function ledgerPath(doctor)
  local override = M[doctor.key .. "Ledger"] or os.getenv(doctor.ledgerEnv or doctor.env .. "_LEDGER")
  if override and override ~= "" then return override end
  return repoRoot and repoRoot .. "/share/" .. doctor.ledger
end

local function doctorDocument(doctor)
  local folder = dirFor(doctor.key .. "DoctorDir", doctor.env .. "_DIR", "/.cache/" .. doctor.key .. "-doctor")
  return readJson(folder .. (doctor.key == "harness" and "/menu.txt" or "/latest.json"),
    doctor.key == "harness" and "header" or nil)
end

-- The same set bin/doctor-fix snapshots as quiet: open ledger rows no problem of the document names.
local function quietRow(doctor)
  if doctor.key == "code" then return nil end
  local document = doctorDocument(doctor)
  local path = ledgerPath(doctor)
  local ledger = path and readJson(path)
  local unclassified = not document and doctor.key == "harness"
  if not ledger or not document and not unclassified or document and document.status == "error" then return nil end
  document = document or {}
  local seen = {}
  for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
    if type(problem) == "table" then
      if problem.ledger ~= nil then seen[tostring(problem.ledger)] = true end
      local id = tostring(problem.id or "")
      if id:sub(1, 7) == "ledger:" then seen[id:sub(8)] = true end
    end
  end
  local rows = {}
  for _, row in ipairs(type(ledger.rows) == "table" and ledger.rows or {}) do
    if type(row) == "table" and row.status == "open" and row.id ~= nil and not seen[tostring(row.id)] then
      rows[#rows + 1] = fitRow({ title = infoTitle(tostring(row.id) .. (type(row.title) == "string" and " · " .. row.title or ""),
        false, true), disabled = true })
    end
  end
  if #rows == 0 then return nil end
  return { title = infoTitle(unclassified and "known, awaiting snapshot" or "known, quiet", false, true), menu = rows }
end

local BUILDERS = {
  llm = function() return limits.llmDoctorEntry() end,
  harness = function() return limits.harnessDoctorEntry() end,
  updater = updaterEntry,
  code = codeEntry,
  system = systemEntry,
}
local NAMES = { llm = "LLM doctor", harness = "Harness doctor", updater = "Updater doctor", code = "Code doctor",
  system = "System doctor" }

local BARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local MISSING = "–"

local function rounded(value) return string.format("%d", math.floor(value + 0.5)) end
local function ratio(value)
  return value < 9.995 and string.format("%.2f", value) or value < 99.95 and string.format("%.1f", value) or rounded(value)
end
local function padded(text, width) return string.rep(" ", width - cells(text)) .. text end

-- `loud` marks the dates whose bar is the loud count (no red count kept that day): drawn, never in the median.
local function trend(history, now, loud)
  local days, prior, high = {}, {}, 0
  local date = os.date("*t", now)
  for index = 1, 7 do
    local day = os.date("%Y-%m-%d", os.time({ year = date.year, month = date.month, day = date.day - 7 + index,
      hour = 12 }))
    local amount = tonumber(history[day])
    if amount and amount >= 0 then
      days[index], high = amount, math.max(high, amount)
      if index < 7 and not (loud and loud[day]) then prior[#prior + 1] = amount end
    end
  end
  table.sort(prior)
  local median = #prior > 0 and (prior[math.floor((#prior + 1) / 2)] + prior[math.ceil((#prior + 1) / 2)]) / 2 or nil
  local bars = {}
  for index = 1, 7 do
    local amount = days[index]
    bars[index] = amount == nil and { " " }
      or { BARS[amount == 0 and 1 or math.max(2, math.ceil(amount / high * 8))], style.DIM }
  end
  return bars, median
end

local function summaryTitle(name, value, status, history, now, stale, indexed, loud)
  local bars, median = trend(history, now, loud)
  -- RED: act now; DIM: cannot tell (no data, stale, a blind collector); GREEN: nothing for Egor.
  local tone = (status == "error" or status == "problems") and not stale and style.RED
    or (stale or status == "nodata" or status == "blind") and style.DIM or GREEN
  local segments = { { string.format("%-9s", name), tone }, { " " },
    value and { padded((indexed and ratio or rounded)(value), 4) } or { padded(MISSING, 4), style.DIM }, { "  " } }
  for _, bar in ipairs(bars) do segments[#segments + 1] = bar end
  segments[#segments + 1] = { " " .. padded(median and (indexed and ratio or rounded)(median) or MISSING, 4), style.DIM }
  return styled(segments)
end

local SECTIONS = {
  { name = "Processor", rules = { "spawn", "kernel" }, blind = { "ticks", "census" } },
  { name = "Memory", rules = { "compressor", "swap", "swap-writes" }, blind = { "ticks", "footprints" } },
  { name = "Disk writes", rules = { "ssd-writes" }, blind = { "ticks", "footprints", "ssd-sampler" } },
  { name = "Disk space", rules = { "free-space", "dir-growth", "orphan-profile", "profile-size" }, blind = { "ticks", "nightly" } },
  { name = "Logs", rules = { "log-store", "log-growth", "unregistered-store", "log-unread" }, blind = { "logstores" } },
  { name = "Crashes", rules = { "hammerspoon-crash", "job-crash", "job-loop", "unclean-reboot" },
    blind = { "nightly", "dumpstate", "harvest" } },
  { name = "Background", rules = { "cohort" }, blind = { "ticks", "dumpstate" } },
}
-- A cohort term per day in the unit a row shows it: key, word, unit, factor.
local TERMS = { { "C", "cpu", "min/d", 1 / 60 }, { "S", "starts", "/s", 1 / 86400 }, { "D", "writes", "GB/d", 1e-9 },
  { "R", "reads", "GB/d", 1e-9 }, { "M", "memory", "MB", 1e-6 }, { "W", "wakeups", "/s", 1 / 86400 },
  { "L", "launches", "/d", 1 } }
-- Per day but no B term: a start's cost already lands in C, so starts show DIM with no share.
local UNSCORED = { S = true }
local MOVED_TO = { ["CPU audits"] = "Processor", Load = "Processor", ["Memory guard"] = "Memory", Growth = "Logs" }
local TAG_NAMES = { ["worker-run"] = "workers", ["(bash)"] = "shell", bash = "shell", zsh = "shell", sh = "shell",
  claude = "Claude", codex = "Codex", node = "node", ["Google Chrome"] = "Chrome", Browser = "Dia" }
local REPORT_NAMES = { crash = "app crashes", fault = "faults", jetsam = "memory kills", hang = "hangs",
  panic = "panics", shutdownStall = "slow shutdown", other = "other" }
local REPORT_ORDER = { "crash", "hang", "fault", "jetsam", "panic", "shutdownStall", "other" }
local GB_PER_GIB = 1.073741824

local function list(value) return type(value) == "table" and value or {} end

local function amount(value)
  if value == math.floor(value) then return string.format("%d", value) end
  return value < 9.95 and string.format("%.1f", value) or rounded(value)
end

local function keepWords(words)
  words = words:gsub("^last ", "")
  local mb = tonumber(words:match("^(%d+) MB$"))
  if mb and mb >= 1024 then return amount(mb / 1024) .. " GB" end
  return (words:gsub(" days?$", " d"))
end

local function human(tag)
  tag = tostring(tag)
  local repo = tag:match("^([%w._-]+)/.")
  local base = tag:match("([^/]+)$") or tag
  if base:match("^test_.+%.sh$") or base == "run-suites.sh" then
    return (repo and repo ~= "llm-legs") and repo .. " tests" or "tests"
  end
  if repo and repo ~= "llm-legs" then return repo end
  base = base:gsub("%.%a+$", ""):gsub(" Helper.*$", ""):gsub("^com%.apple%.", "")
  if TAG_NAMES[base] then return TAG_NAMES[base] end
  return repo and (base:gsub("[-_]", " ")) or base
end

local function pathName(path)
  path = tostring(path)
  for part in path:gmatch("[^/]+") do
    local app = part:match("^%l+%.[%w-]+%.([%w-]+)$")
    if app then return app end
  end
  return ((path:match("([^/]+)/*$") or path):gsub("^%.", ""))
end

local function byName(rows, nameOf, valueOf, countOf)
  local merged, order = {}, {}
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local name, value = nameOf(row), tonumber(valueOf(row)) or 0
      if not merged[name] then merged[name], order[#order + 1] = { name = name, value = 0, count = 0 }, name end
      merged[name].value = merged[name].value + value
      merged[name].count = merged[name].count + (countOf and tonumber(countOf(row)) or 1)
    end
  end
  local out = {}
  for _, name in ipairs(order) do out[#out + 1] = merged[name] end
  table.sort(out, function(a, b) return a.value > b.value end)
  return out
end

-- RED for a red problem; nil (the row's own tone) for any other.
local function problemTone(problem)
  return problem and isRed("system", problem) and style.RED or nil
end

local function louder(a, b)
  if a == style.RED or b == style.RED then return style.RED end
  return a or b
end

local function sized(menu)
  return #menu > 0 and menu or nil
end

local function row(segments, menu)
  return fitRow({ title = styled(segments), menu = sized(menu or {}), disabled = #(menu or {}) == 0 or nil })
end

local function measureRow(label, value, unit, tone, history, now, menu)
  local segments = { { string.format("%-13s", label), tone },
    value and { " " .. padded(amount(value), 5) } or { " " .. padded(MISSING, 5), style.DIM },
    { " " .. (history and string.format("%-7s", unit) or unit) } }
  if history then
    local bars, median = trend(history, now)
    segments[#segments + 1] = { " " }
    for _, bar in ipairs(bars) do segments[#segments + 1] = bar end
    segments[#segments + 1] = { " " .. padded(median and amount(median) or MISSING, 5), style.DIM }
  end
  return row(segments, menu)
end

local function listRow(value, unit, label, tone, menu)
  return row({ { padded(value, 5) }, { " " .. string.format("%-5s", unit) .. "  " }, { label, tone } }, menu)
end

local function keepRow(gb, keep, name, tone, menu)
  return row({ { padded(amount(gb), 5) }, { " GB  " }, { padded(keep, 7), style.DIM }, { "  " }, { name, tone } }, menu)
end

-- Disk space by hand. The emergency size is log_stores.emergency, measured by the daily collector and after a sweep,
-- never per tick; the review opens a chat (docs/disk-review.md) and nothing reminds of it.
function M.emergencyCleanup(gb)
  if running(fixTasks.emergency) then return end
  if hs.dialog.blockAlert("Emergency cleanup now?", (gb and "About " .. amount(gb) .. " GB: e" or "E")
      .. "very cache, and temp files untouched for 2 h, biggest first. Logins and live work stay.", "Cancel", "Run") ~= "Run" then
    return
  end
  launch("emergency", M.logSweepCmd or (repoRoot and repoRoot .. "/bin/log-sweep"), { "--emergency" },
    "Emergency cleanup", "Emergency cleanup done")
end

function M.reviewDisk()
  launch("diskreview", M.diskReviewCmd or (repoRoot and repoRoot .. "/bin/disk-review"), {}, "Disk review",
    "Disk review chat opened")
end

local function diskByHand(logs)
  local gb, emergency = tonumber(list(logs.emergency).gb), nil
  if running(fixTasks.emergency) then
    emergency = dim("Emergency cleanup — running…")
  elseif not gb then
    emergency = dim("Emergency cleanup — not measured yet")
  else
    emergency = row({ { "Emergency cleanup  " }, { "~" .. amount(gb) .. " GB" } })
    emergency.fn, emergency.disabled = function() M.emergencyCleanup(gb) end, nil
  end
  return { emergency, running(fixTasks.diskreview) and dim("Review disk with Claude — opening…")
    or { title = infoTitle("Review disk with Claude…"), fn = M.reviewDisk } }
end

local function retention(store, group)
  local words = type(store.keep_by_group) == "table" and store.keep_by_group[group] or store.keep
  if type(words) == "string" then return keepWords(words) end
  return store.cleaner == "keep" and "∞" or store.cleaner == "cap" and "app" or ""
end

local function keepSpan(parts)
  local seen, low, high = {}, math.huge, 0
  for _, part in ipairs(parts) do
    seen[part.keep] = true
    local days = tonumber(part.keep:match("^(%d+) d$"))
    low, high = days and low and math.min(low, days), math.max(high, days or 0)
  end
  if next(seen, next(seen)) == nil then return parts[1].keep end
  return low and string.format("%d–%d d", low, high) or ""
end

local function scaled(history, factor)
  local out = {}
  for day, value in pairs(list(history)) do
    if tonumber(value) then out[day] = tonumber(value) * factor end
  end
  return out
end

local function limitText(problem)
  local limit = tonumber(problem.limit)
  if not limit or problem.unit == "bytes" then return nil end
  if problem.unit == "share" then return string.format("limit %d %%", math.floor(limit * 100 + 0.5)) end
  return "limit " .. amount(limit) .. (problem.unit and " " .. tostring(problem.unit) or "")
end

local function problemMenu(problem, menu)
  menu = menu or {}
  if not problem then return menu end
  local rows = {}
  local limit = limitText(problem)
  if limit then rows[#rows + 1] = dim(limit) end
  local proof = type(problem.proof) == "table" and problem.proof.why
  if type(proof) == "string" then
    for _, line in ipairs(detailRows(proof)) do rows[#rows + 1] = line end
  end
  for _, item in ipairs(list(problem.evidence)) do
    if type(item) == "table" and type(item.excerpt) == "string" then rows[#rows + 1] = fitRow(dim(item.excerpt)) end
  end
  if #rows > 0 and #menu > 0 then menu[#menu + 1] = { title = "-" } end
  for _, line in ipairs(rows) do menu[#menu + 1] = line end
  return menu
end

local function problemValue(problem)
  local value = tonumber(problem.value)
  if not value then return MISSING, "" end
  if problem.unit == "bytes" then return amount(value / 1e9), "GB" end
  if problem.unit == "share" then return rounded(value * 100), "%" end
  local unit = tostring(problem.unit or "")
  return amount(value), unit:match("/day$") and "/day" or unit
end

local function problemName(problem)
  local cause = type(problem.cause) == "table" and problem.cause or {}
  local name = cause.label or cause.name
  if not name and type(problem.id) == "string" then name = problem.id:match("^[^:]+:(.+)$") end
  return name and human(name) or tostring(problem.label or problem.rule or problem.id)
end

local function movedRows(moved, incoming)
  local counts, bySection = {}, {}
  for _, issue in ipairs(incoming or {}) do counts[issue.what] = (counts[issue.what] or 0) + issue.count end
  for _, item in ipairs(moved or {}) do
    local plain = item.title ~= "-" and plainText(item.title) or ""
    local label, rest = plain:match("^([^:]+):%s*(.*)$")
    if label then
      local count = counts[label] or 0
      local tone = count > 0 and style.RED or nil
      local shown = listRow(count > 0 and tostring(count) or "", "", label, tone, item.menu)
      local section = MOVED_TO[label]
      bySection[section] = bySection[section] or {}
      table.insert(bySection[section], { row = shown, tone = tone })
    end
  end
  return bySection
end

local function systemSections(document, now, moved, incoming)
  local m, days = list(document.measures), list(document.days)
  local causes, footprints = list(document.causes), list(list(document.collectors).footprints)
  local nightly, logs = list(document.nightly), list(document.log_stores)
  local reports, processes = list(nightly.reports), list(nightly.processes)
  local cores = tonumber(m.cores)
  local blind = {}
  for _, name in ipairs(list(document.blind)) do blind[name] = true end
  local all, used = {}, {}
  for _, problem in ipairs(list(document.problems)) do
    if type(problem) == "table" then all[#all + 1] = problem end
  end
  local function pick(id)
    for _, problem in ipairs(all) do
      if problem.id == id and not used[problem] then used[problem] = true return problem end
    end
  end
  local function nightRows(kind, unit)
    local out = {}
    for _, item in ipairs(byName(processes, function(r) return human(r[2]) end,
        function(r) return r[1] == kind and r[3] or 0 end)) do
      if item.value > 0 then out[#out + 1] = listRow(rounded(item.value), unit, item.name) end
    end
    return out
  end
  local bySection = movedRows(moved, incoming)
  local build = {}

  build.Processor = function()
    local kernel, spawn = pick("kernel:machine"), pick("spawn:machine")
    local born = {}
    for _, item in ipairs(byName(list(causes.births), function(r) return human(r[1]) end, function(r) return r[2] end)) do
      born[#born + 1] = listRow(rounded(item.value * 100), "%", item.name)
    end
    local rows = {
      measureRow("kernel", cores and tonumber(m.kernel) and m.kernel * cores, "cores", problemTone(kernel),
        cores and scaled(days.kernel, cores) or {}, now, problemMenu(kernel)),
      measureRow("starts", tonumber(m.births_s), "/s", problemTone(spawn), list(days.births_s), now,
        problemMenu(spawn, born)),
      { title = "-" },
    }
    for _, item in ipairs(byName(list(causes.cpu), function(r) return human(r[1]) end, function(r) return r[2] end)) do
      rows[#rows + 1] = listRow(string.format("%.2f", item.value), "cores", item.name)
    end
    local reported = {}
    for _, kind in ipairs({ "cpu_resource", "wakeups" }) do
      for _, line in ipairs(nightRows(kind, "/8 d")) do reported[#reported + 1] = line end
    end
    if #reported > 0 then
      rows[#rows + 1] = { title = "-" }
      for _, line in ipairs(reported) do rows[#rows + 1] = line end
    end
    return rows, cores and tonumber(m.busy) and m.busy * cores, "cores", cores and scaled(days.busy, cores) or {}
  end

  build.Memory = function()
    local compressor, swap, writes = pick("compressor:machine"), pick("swap:machine"), pick("swap-writes:machine")
    local mem = tonumber(m.mem_gib)
    local rows = {
      measureRow("compressed", tonumber(m.comp_gib), "GB", problemTone(compressor),
        mem and scaled(days.comp_share_max, mem) or {}, now, problemMenu(compressor)),
      measureRow("swap", tonumber(m.swap_used_mb) and m.swap_used_mb / 1024, "GB", problemTone(swap), nil, now,
        problemMenu(swap)),
      measureRow("swap writes", tonumber(m.swap_gib_day), "GB/d", problemTone(writes), list(days.swap_gib_day), now,
        problemMenu(writes)),
      measureRow("processes", tonumber(footprints.rss_total) and footprints.rss_total / 2 ^ 30, "GB", nil, nil, now),
      { title = "-" },
    }
    for _, item in ipairs(byName(list(footprints.rss_top), function(r) return human(r[1]) end, function(r) return r[2] end,
        function(r) return r[3] end)) do
      rows[#rows + 1] = listRow(amount(item.value / 2 ^ 30), "GB", item.name .. (item.count > 1 and " ×" .. item.count or ""))
    end
    return rows, tonumber(m.comp_gib), "GB", mem and scaled(days.comp_share_max, mem) or {}
  end

  build["Disk writes"] = function()
    local ssd = pick("ssd-writes:internal")
    local today = tonumber(list(days.ssd_gb_day)[os.date("%Y-%m-%d", now)])
    local rows = {
      measureRow("week", tonumber(m.ssd_gb_day_7d), "GB/d", problemTone(ssd), nil, now, problemMenu(ssd)),
      measureRow("reads", tonumber(m.ssd_read_gb_day_7d), "GB/d", nil, nil, now),
      { title = "-" },
    }
    for _, item in ipairs(byName(list(footprints.io_top), function(r) return human(r[1]) end, function(r) return r[2] end)) do
      if item.value > 0 then rows[#rows + 1] = listRow(rounded(item.value / 1e6), "MB/h", item.name) end
    end
    local sampled, week = type(m.ssd_sampled) == "table" and m.ssd_sampled or nil, tonumber(m.ssd_gb_day_7d)
    if sampled and week then
      rows[#rows + 1] = { title = "-" }
      rows[#rows + 1] = { title = infoTitle(string.format("root samples  %s × %s min", tostring(sampled.samples),
        tostring(math.floor((tonumber(sampled.minutes) or 0) / math.max(1, tonumber(sampled.samples) or 1) + 0.5))),
        false, true), disabled = true }
      for _, item in ipairs(list(sampled.top)) do
        local share = type(item) == "table" and tonumber(item[3])
        if share and share * week >= 0.05 then
          rows[#rows + 1] = listRow(amount(share * week), "GB/d", tostring(item[1]) .. "  " .. tostring(item[2]))
        end
      end
      local rest = 1 - (tonumber(sampled.attributed) or 0)
      if rest * week >= 0.05 then rows[#rows + 1] = listRow(amount(rest * week), "GB/d", "unattributed", style.DIM) end
    end
    local reported = nightRows("diskwrites", "/8 d")
    if #reported > 0 then
      rows[#rows + 1] = { title = "-" }
      for _, line in ipairs(reported) do rows[#rows + 1] = line end
    end
    return rows, today, "GB/d", list(days.ssd_gb_day)
  end

  build["Disk space"] = function()
    local rows, volumes, least = {}, {}, nil
    for name in pairs(list(m.free_gib)) do volumes[#volumes + 1] = name end
    table.sort(volumes)
    for _, name in ipairs(volumes) do
      local gib = tonumber(m.free_gib[name])
      local free = pick("free-space:" .. name)
      local history = scaled(list(days.free_gib)[name], GB_PER_GIB)
      rows[#rows + 1] = measureRow(name, gib and gib * GB_PER_GIB, "GB", problemTone(free), history, now,
        problemMenu(free))
      if gib and (not least or gib < least.gib) then least = { gib = gib, history = history } end
    end
    rows[#rows + 1] = { title = "-" }
    for _, line in ipairs(diskByHand(logs)) do rows[#rows + 1] = line end
    local caches = {}
    for _, cache in ipairs(list(nightly.caches)) do
      if type(cache) == "table" and tonumber(cache[2]) then
        caches[#caches + 1] = listRow(amount(cache[2] * GB_PER_GIB), "GB", pathName(cache[1]))
      end
    end
    if #caches > 0 then
      rows[#rows + 1] = { title = "-" }
      for _, line in ipairs(caches) do rows[#rows + 1] = line end
    end
    local profiles, total, loud = {}, 0, nil
    for _, found in ipairs(list(logs.profiles)) do
      if type(found) == "table" and type(found.path) == "string" then profiles[#profiles + 1] = found end
    end
    local RANK, flagged = { off = 1, unknown = 2, home = 3, menu = 4 }, {}
    for _, found in ipairs(profiles) do
      flagged[found] = found.status == "off" and pick("orphan-profile:" .. found.path) or pick("profile-size:" .. found.path)
    end
    table.sort(profiles, function(a, b)
      local ra, rb = flagged[a] and 0 or RANK[a.status] or 5, flagged[b] and 0 or RANK[b.status] or 5
      if ra ~= rb then return ra < rb end
      if (tonumber(a.mb) or 0) ~= (tonumber(b.mb) or 0) then return (tonumber(a.mb) or 0) > (tonumber(b.mb) or 0) end
      return a.path < b.path
    end)
    local lines = {}
    for _, found in ipairs(profiles) do
      local mb, age = tonumber(found.mb), tonumber(found.age_d)
      total = total + (mb or 0)
      local problem = flagged[found]
      loud = loud or problem
      local name = found.label == "home" and found.path or tostring(found.label) .. "/" .. tostring(found.name)
      local mark = ({ unknown = "? ", home = "⌂ " })[found.status] or ""
      local tone = problem and problemTone(problem) or (found.status ~= "menu" or (age and age >= 30)) and style.DIM or nil
      lines[#lines + 1] = keepRow(mb and mb / 1000 or 0, age and (age < 1 and "<1 d" or string.format("%d d", math.floor(age))) or "",
        mark .. name, tone, problem and problemMenu(problem) or nil)
    end
    local gone = {}
    for _, found in ipairs(list(logs.tidied)) do
      if type(found) == "table" and type(found.path) == "string" then
        local mb, age = tonumber(found.mb), tonumber(found.age_d)
        gone[#gone + 1] = keepRow(mb and mb / 1000 or 0, age and (age < 1 and "<1 d" or string.format("%d d", math.floor(age))) or "",
          "🗑 " .. found.path, style.DIM)
      end
    end
    if #gone > 0 then
      if #lines > 0 then lines[#lines + 1] = { title = "-" } end
      for _, line in ipairs(gone) do lines[#lines + 1] = line end
    end
    if #lines > 0 then
      rows[#rows + 1] = { title = "-" }
      rows[#rows + 1] = listRow(amount(total / 1000), "GB", "LLM profiles", loud and problemTone(loud) or nil, lines)
    end
    if type(nightly.smart) == "string" and nightly.smart ~= "Verified" then
      rows[#rows + 1] = row({ { "SMART  " .. nightly.smart, style.RED } })
    end
    return rows, least and least.gib * GB_PER_GIB, "GB", least and least.history or {}
  end

  build.Logs = function()
    local growth = pick("log-growth:total")
    local rows = { measureRow("growth", tonumber(logs.growth_gb_day_7d), "GB/d", problemTone(growth), nil, now,
      problemMenu(growth)), { title = "-" } }
    for _, group in ipairs(list(logs.groups)) do
      if type(group) == "table" then
        local labels, order, tone = {}, {}, nil
        for _, store in ipairs(list(logs.stores)) do
          local parts = type(store) == "table" and type(store.parts) == "table" and store.parts or {}
          local gb = tonumber(parts[group[1]]) or next(parts) == nil and store.group == group[1] and tonumber(store.gb)
          if gb then
            local label = tostring(store.label or store.name)
            if not labels[label] then labels[label], order[#order + 1] = { gb = 0, parts = {} }, label end
            local entry = labels[label]
            local part = { name = tostring(store.part or label), gb = gb, keep = retention(store, group[1]), problems = {} }
            for _, rule in ipairs({ "log-store", "log-unread" }) do
              local problem = pick(rule .. ":" .. tostring(store.name))
              if problem then
                part.problems[#part.problems + 1] = problem
                part.tone = louder(part.tone, problemTone(problem))
              end
            end
            entry.gb, entry.tone = entry.gb + gb, louder(entry.tone, part.tone)
            entry.parts[#entry.parts + 1] = part
          end
        end
        table.sort(order, function(a, b) return labels[a].gb > labels[b].gb end)
        local menu = {}
        for _, label in ipairs(order) do
          local entry = labels[label]
          table.sort(entry.parts, function(a, b) return a.gb > b.gb end)
          local sub = {}
          for _, part in ipairs(entry.parts) do
            local problems = {}
            for _, problem in ipairs(part.problems) do problemMenu(problem, problems) end
            if #entry.parts > 1 then
              sub[#sub + 1] = keepRow(part.gb, part.keep, part.name, part.tone, problems)
            else
              sub = problems
            end
          end
          menu[#menu + 1] = keepRow(entry.gb, keepSpan(entry.parts), label, entry.tone, sub)
          tone = louder(tone, entry.tone)
        end
        local change = tonumber(group[3])
        rows[#rows + 1] = row({ { padded(amount(tonumber(group[2]) or 0), 5) }, { " GB" },
          change and { padded((change >= 0 and "+" or "") .. amount(change), 6), style.DIM } or { padded("", 6) },
          { "  " }, { tostring(group[1]), tone } }, menu)
      end
    end
    local unknown, unknownMenu, unknownTone = 0, {}, nil
    for _, dir in ipairs(list(logs.unregistered)) do
      if type(dir) == "table" then
        local problem = pick("unregistered-store:" .. tostring(dir.path))
        local mb = tonumber(dir.residual_mb or dir.mb) or 0
        unknown = unknown + mb
        unknownTone = louder(unknownTone, problemTone(problem))
        unknownMenu[#unknownMenu + 1] = listRow(amount(mb / 1000), "GB", pathName(dir.path), problemTone(problem),
          problemMenu(problem, { dim(tostring(dir.path)) }))
      end
    end
    if #unknownMenu > 0 then
      rows[#rows + 1] = row({ { padded(amount(unknown / 1000), 5) }, { " GB" }, { padded("", 6) },
        { "  " }, { "unknown", unknownTone } }, unknownMenu)
    end
    local sweep = list(logs.sweep)
    if tonumber(sweep.bytes) then
      rows[#rows + 1] = { title = "-" }
      rows[#rows + 1] = listRow(amount(sweep.bytes / 1e9), "GB", "swept",
        (tonumber(sweep.errors) or 0) > 0 and style.RED or nil)
    end
    return rows, tonumber(logs.total_gb), "GB", list(days.logs_gb)
  end

  build.Crashes = function()
    local reboot = pick("unclean-reboot:machine")
    local rows = { measureRow("reboots", tonumber(nightly.unclean_reboots_7d), "/7 d", problemTone(reboot), nil, now,
      problemMenu(reboot)) }
    for _, kind in ipairs(REPORT_ORDER) do
      local count = tonumber(reports[kind])
      if count then
        rows[#rows + 1] = measureRow(REPORT_NAMES[kind], count, "/8 d", nil, nil, now, nightRows(kind, "/8 d"))
      end
    end
    return rows, tonumber(reports.crash), "/8 d", nil
  end

  build.Background = function()
    local flagged, rows, over = {}, {}, 0
    for _, problem in ipairs(all) do
      local cause = type(problem.cause) == "table" and problem.cause or {}
      if problem.rule == "cohort" and cause.name and not used[problem] then
        flagged[cause.name] = flagged[cause.name] or {}
        table.insert(flagged[cause.name], problem)
      end
    end
    local function times(value) return value == 0 and "0" or ratio(value) end
    local function details(item, problem)
      local menu, job = {}, type(item.job) == "table" and item.job or nil
      if type(item.about) == "string" then
        for _, line in ipairs(detailRows(item.about)) do menu[#menu + 1] = line end
      end
      if type(item.place) == "string" then menu[#menu + 1] = fitRow(dim(item.place)) end
      if job then
        local words = { tostring(job.label), tostring(job.schedule) }
        words[#words + 1] = job.missing and "file gone" or job.loaded == false and "not loaded" or nil
        menu[#menu + 1] = fitRow(dim(table.concat(words, " · ")))
      end
      if #menu > 0 then menu[#menu + 1] = { title = "-" } end
      local unknown, blindTerms = {}, {}
      for _, key in ipairs(list(item.unknown)) do unknown[key] = true end
      for _, term in ipairs(TERMS) do
        local per, share = tonumber(list(item.per_day)[term[1]]), tonumber(list(item.terms)[term[1]])
        if UNSCORED[term[1]] then
          if per and per * term[4] >= 0.01 then
            menu[#menu + 1] = row({ { padded(amount(per * term[4]), 5), style.DIM },
              { " " .. string.format("%-5s", term[3]) .. "  ", style.DIM }, { term[2], style.DIM } })
          end
        elseif per and (share or 0) >= 0.01 then
          menu[#menu + 1] = row({ { padded(amount(per * term[4]), 5) }, { " " .. string.format("%-5s", term[3]) .. "  " },
            { string.format("%-9s", term[2]) }, { padded(times(share or 0) .. "×", 6),
              (share or 0) >= 1 and problemTone(problem) or (share or 0) < 1 and style.DIM or nil } })
        elseif unknown[term[1]] then
          blindTerms[#blindTerms + 1] = term[2]
        end
      end
      if #blindTerms > 0 then
        menu[#menu + 1] = row({ { padded(MISSING, 5), style.DIM }, { "         " }, { table.concat(blindTerms, " "), style.DIM } })
      end
      if #menu > 0 and menu[#menu].title == "-" then menu[#menu] = nil end
      return menu
    end
    for _, group in ipairs(list(document.background and document.background.groups)) do
      local lines, loud, items = {}, nil, list(group.items)
      for _, item in ipairs(items) do
        local value, problem = tonumber(item.B), nil
        for _, found in ipairs(flagged[item.name] or {}) do
          used[found], problem = true, problem and problemTone(problem) == style.RED and problem or found
        end
        flagged[item.name] = nil
        local top, high = nil, 0
        for key, share in pairs(list(item.terms)) do
          if tonumber(share) and share > high and not UNSCORED[key] then top, high = key, share end
        end
        local word = ""
        for _, term in ipairs(TERMS) do
          if term[1] == top then word = term[2] end
        end
        local name = tostring(item.name)
        if group.name ~= "harness" and name:sub(1, #tostring(group.name) + 1) == group.name .. "/" then
          name = name:sub(#group.name + 2)
        end
        local job = type(item.job) == "table" and item.job or {}
        name = (job.missing and "✗ " or job.loaded == false and (value or 0) == 0 and "○ " or "") .. name
        local tone = problem and problemTone(problem) or not (value and value >= 1) and style.DIM or nil
        loud = louder(loud, problem and problemTone(problem))
        lines[#lines + 1] = row({ { padded(value and times(value) or MISSING, 5) }, { " ×  " },
          { string.format("%-9s", word), style.DIM }, { name, tone } }, details(item, problem))
      end
      local value = tonumber(group.B)
      if value and value >= 1 then over = over + 1 end
      rows[#rows + 1] = row({ { padded(value and times(value) or MISSING, 5) }, { " ×  " },
        { tostring(group.name), loud or not (value and value >= 1) and style.DIM or nil },
        { "  " .. #items, style.DIM } }, lines)
    end
    return rows, document.background and over or nil, "over", nil
  end

  local out = {}
  for _, section in ipairs(SECTIONS) do
    local rows, value, unit, history = build[section.name]()
    local tone, extra = nil, {}
    for _, problem in ipairs(all) do
      for _, rule in ipairs(section.rules) do
        if problem.rule == rule then
          tone = louder(tone, problemTone(problem))
          if not used[problem] then
            used[problem] = true
            local shown, shownUnit = problemValue(problem)
            extra[#extra + 1] = listRow(shown, shownUnit, problemName(problem), problemTone(problem) or style.DIM,
              problemMenu(problem))
          end
        end
      end
    end
    if #extra > 0 then
      rows[#rows + 1] = { title = "-" }
      for _, line in ipairs(extra) do rows[#rows + 1] = line end
    end
    for index, item in ipairs(bySection[section.name] or {}) do
      if index == 1 and rows[#rows].title ~= "-" then rows[#rows + 1] = { title = "-" } end
      rows[#rows + 1] = item.row
      tone = louder(tone, item.tone)
    end
    for _, name in ipairs(section.blind) do
      if blind[name] and tone ~= style.RED then tone = style.DIM end
    end
    local tidy = {}
    for _, line in ipairs(rows) do
      if line.title ~= "-" or #tidy > 0 and tidy[#tidy].title ~= "-" then tidy[#tidy + 1] = line end
    end
    if #tidy > 0 and tidy[#tidy].title == "-" then tidy[#tidy] = nil end
    local header = measureRow(section.name, value, unit, tone or GREEN, history, now, tidy)
    out[#out + 1] = header
  end
  for _, problem in ipairs(all) do
    if not used[problem] and problemTone(problem) == style.RED then
      local shown, shownUnit = problemValue(problem)
      out[#out + 1] = listRow(shown, shownUnit, tostring(problem.label or problem.rule or problem.id),
        problemTone(problem), problemMenu(problem))
    end
  end
  return out
end

local function issueRow(amount, unit, what, format, tone)
  return fitRow({ title = styled({ { padded(format and string.format(format, amount) or rounded(amount), 4), (tone == nil and style.RED) or tone or nil },
    { (unit and " " .. unit or "") .. "  " .. what } }), disabled = true })
end

-- A doctor's red problems: their count, per group, the first one's fact per group, and their ids.
local function redView(doctor, document)
  local view = { count = 0, groups = {}, facts = {}, ids = {} }
  if not document or document.status == "error" then return view end
  for _, problem in ipairs(type(document.problems) == "table" and document.problems or {}) do
    if isRed(doctor.key, problem) then
      view.count, view.ids[tostring(problem.id)] = view.count + 1, true
      if problem.group ~= nil then
        local group = tostring(problem.group)
        view.groups[group] = (view.groups[group] or 0) + 1
        if not view.facts[group] and type(problem.fact) == "string" then view.facts[group] = problem.fact end
      end
    end
  end
  return view
end

-- What a red row says: its group and, in the doctor's own words, the first red problem in it.
local function issueWhat(what, fact)
  return fact and fact ~= what and what .. " · " .. fact or what
end

local function issueList(doctor, document, view)
  local issues = {}
  if not document then return issues end
  local routes = SHOWN_BY[doctor.key] or {}
  local function add(count, what, group, fact)
    if count > 0 and not (group and routes[group]) then issues[#issues + 1] = { count = count, what = what, fact = fact } end
  end
  if doctor.key == "harness" then
    for group, count in pairs(view.groups) do add(count, group, group, view.facts[group]) end
  elseif doctor.key == "llm" then
    for _, block in ipairs(document.blocks or {}) do
      for _, problem in ipairs(block.problems or {}) do
        if problem.kind == "bug" and view.ids[tostring(problem.id)] then
          add(tonumber(problem.count) or 1, block.block .. " " .. (problem.label or problem.id))
        end
      end
      for _, issue in ipairs((block.machinery or {}).classes or {}) do
        if LOUD[issue.status] and (view.groups.machinery or 0) > 0 then
          add(tonumber(issue.count) or 0, "review " .. (tostring(issue.class):gsub("_", " ")))
        end
      end
    end
    for _, health in ipairs(document.health or {}) do
      local group = tostring(health.name)
      if health.status == "problem" and (view.groups[group] or 0) > 0 then
        add(tonumber(health.count) or 1, group, group, view.facts[group])
      end
    end
  elseif doctor.key == "code" then
    for _, group in ipairs(CODE_GROUPS) do add(view.groups[group.key] or 0, group.name, nil, view.facts[group.key]) end
  elseif doctor.key == "system" then
    for _, problem in ipairs(document.problems or {}) do
      if isRed("system", problem) then add(1, tostring(problem.label or problem.rule or problem.id)) end
    end
  end
  if #issues == 0 then
    for _, problem in ipairs(document.problems or {}) do
      if isRed(doctor.key, problem) then add(1, tostring(problem.fact or problem.id), problem.group) end
    end
  end
  return issues
end

local function issueRows(issues, incoming)
  for _, issue in ipairs(incoming or {}) do issues[#issues + 1] = issue end
  table.sort(issues, function(a, b) return a.count > b.count or a.count == b.count and a.what < b.what end)
  local rows = {}
  for index = 1, math.min(3, #issues) do
    rows[index] = issueRow(issues[index].count, nil, issueWhat(issues[index].what, issues[index].fact))
  end
  return rows
end

-- nil: the row stays; false: dropped, its own doctor shows it; else the summary it moves to.
local function rowTarget(donor, item)
  if item.title == "-" then return nil end
  local plain = plainText(item.title)
  if donor == "harness" and (plain:match("^%d+ [hd] vs prev ") or plain:match("^window: ")) then return "speed" end
  local label = plain:match("^([^:]+):")
  if not label then return nil end
  if donor == "harness" and OWN_DOCTOR_ROWS[label] then return false end
  local routes = SHOWN_BY[donor] or {}
  return routes[label] or routes[label:lower()]
end

local function placeRows(details, rows, keep)
  if not rows or #rows == 0 then return details end
  local at = #details - (keep or 0) + 1
  table.insert(details, at, { title = "-" })
  for index, row in ipairs(rows) do table.insert(details, at + index, row) end
  return details
end

-- Moves the donor's per-group red counts; capped at its count so the Doctors total never changes.
local function routeCounts(donor, view, shift, incoming)
  local routes = SHOWN_BY[donor]
  if not routes then return end
  local names, count = {}, view.count
  for group in pairs(view.groups) do if routes[group] then names[#names + 1] = group end end
  table.sort(names)
  for _, group in ipairs(names) do
    local take = math.min(math.max(math.floor(view.groups[group]), 0), count)
    if take > 0 then
      local target = routes[group]
      count = count - take
      shift[donor], shift[target] = (shift[donor] or 0) - take, (shift[target] or 0) + take
      incoming[target][#incoming[target] + 1] = { count = take, what = group, fact = view.facts[group] }
    end
  end
end

local function firstRows(doctor, document, view, now, moved, incoming)
  if doctor.key == "system" and document then
    local ok, rows = pcall(systemSections, document, now, moved.system, incoming.system)
    if ok then return rows end
    local fallback = issueRows(issueList(doctor, document, view), incoming.system)
    table.insert(fallback, 1, fitRow({ title = infoTitle(tostring(rows), true), disabled = true }))
    return fallback
  end
  return issueRows(issueList(doctor, document, view), incoming[doctor.key])
end

local function egorLayer(rows, menu, details)
  rows[#rows + 1] = menu[#menu]
  rows[#rows + 1] = { title = "-" }
  rows[#rows + 1] = { title = infoTitle("LLM details"), menu = details }
  return rows
end

local function harnessSection(entryMenu, prefix, issues, unit, format)
  local details, rows = {}, {}
  for _, item in ipairs(entryMenu or {}) do
    if item.title ~= "-" and plainText(item.title):match("^" .. prefix .. ":") then details = item.menu or {} break end
  end
  for _, issue in ipairs(type(issues) == "table" and issues or {}) do
    if tonumber(issue[1]) then
      rows[#rows + 1] = issueRow(tonumber(issue[1]), tostring(issue[3] or unit), tostring(issue[2]), format, style.DIM)
    end
  end
  return details, rows
end

local function levelRows(levels)
  local out = {}
  for _, r in ipairs(type(levels) == "table" and levels or {}) do
    local v = type(r) == "table" and tonumber(r[1])
    out[#out + 1] = fitRow({ title = styled({ { padded(v and (v < 9.95 and string.format("%.1f", v) or rounded(v)) or MISSING, 4) },
      { " " .. tostring(r[2]) } }), disabled = true })
  end
  return out
end

-- A built tool's min/day beside its job's residual scripts; a glyph or MISSING where a column has no number.
local function pairCell(value, width)
  local n = tonumber(value)
  if not n then return { padded(tostring(value), width), style.DIM } end
  return { padded(n == 0 and "0" or n < 9.95 and string.format("%.1f", n) or rounded(n), width) }
end

local function lostRows(rows)
  local out = {}
  for _, r in ipairs(type(rows) == "table" and rows or {}) do
    if r == "-" then
      out[#out + 1] = { title = "-" }
    elseif type(r) == "table" and r[4] ~= nil and type(r[4]) ~= "table" then
      out[#out + 1] = fitRow({ title = styled({ pairCell(r[1], 4), pairCell(r[4], 5),
        { " min/day  " .. tostring(r[2]) } }), disabled = true })
    elseif type(r) == "table" and type(r[4]) == "table" and r[4].count and tonumber(r[1]) then
      local row = issueRow(tonumber(r[1]), nil, tostring(r[2]), nil, false)
      local sub = lostRows(r[3])
      if #sub > 0 then row.menu, row.disabled = sub, nil end
      out[#out + 1] = row
    elseif type(r) == "table" and tonumber(r[1]) then
      local row = type(r[4]) == "table" and r[4].dim
        and fitRow({ title = styled({ { padded(rounded(tonumber(r[1])), 4), style.DIM },
          { " min/day  " .. tostring(r[2]), style.DIM } }), disabled = true })
        or issueRow(tonumber(r[1]), "min/day", tostring(r[2]), nil, false)
      local sub = lostRows(r[3])
      if #sub > 0 then row.menu, row.disabled = sub, nil end
      out[#out + 1] = row
    end
  end
  return out
end

-- The day's highest red count per summary (contract row `rd`): the bars and the usual beside a count read the same
-- red count, while problem-days.jsonl keeps every problem for the time budget. Written only when a day's max rises.
-- A date with no red count (before the menu kept them, or a doctor with no count that day) draws problem-days.jsonl's
-- loud max: red is a subset of loud, so a loud 0 is an exact red 0, and any other loud day is marked, out of the usual.
local function redDays(now, counts)
  local folder = dirFor("doctorsDir", "DOCTORS_DIR", "/.cache/doctors")
  local path = folder .. "/red-days.jsonl"
  local day, keep = os.date("%Y-%m-%d", now), os.date("%Y-%m-%d", now - RED_DAYS_KEEP * 86400)
  local histories, rows, changed = {}, {}, false
  for _, row in ipairs(readJson(path, "days") or {}) do
    if type(row.doctor) == "string" and type(row.day) == "string" and tonumber(row.max) and row.day >= keep then
      histories[row.doctor] = histories[row.doctor] or {}
      histories[row.doctor][row.day] = math.max(histories[row.doctor][row.day] or 0, tonumber(row.max))
    end
  end
  for doctor, count in pairs(counts) do
    histories[doctor] = histories[doctor] or {}
    if count > (histories[doctor][day] or -1) then histories[doctor][day], changed = count, true end
  end
  if changed then
    pcall(function()
      for doctor, days in pairs(histories) do
        for at, max in pairs(days) do rows[#rows + 1] = hs.json.encode({ day = at, doctor = doctor, max = max }) end
      end
      table.sort(rows)
      local handle = io.open(path .. ".tmp", "w")
      if not handle then return end
      handle:write(table.concat(rows, "\n") .. "\n")
      handle:close()
      os.rename(path .. ".tmp", path)
    end)
  end
  local shown, loud = {}, {}
  for doctor, days in pairs(histories) do
    shown[doctor] = {}
    for at, max in pairs(days) do shown[doctor][at] = max end
  end
  for _, row in ipairs(readJson(folder .. "/problem-days.jsonl", "days") or {}) do
    local max = tonumber(row.max)
    if type(row.doctor) == "string" and type(row.day) == "string" and max and row.day >= keep
      and (histories[row.doctor] or {})[row.day] == nil then
      shown[row.doctor], loud[row.doctor] = shown[row.doctor] or {}, loud[row.doctor] or {}
      shown[row.doctor][row.day] = math.max(shown[row.doctor][row.day] or 0, max)
      loud[row.doctor][row.day] = shown[row.doctor][row.day] > 0 or nil
    end
  end
  return shown, loud
end

local function compute()
  local now = os.time()
  local entries, speed, spend, machine = {}, nil, nil, nil
  held = heldIds(now)
  local built, lostDetails = {}, {}
  local moved, shift, incoming = { harness = {}, speed = {}, system = {} }, {}, { harness = {}, speed = {}, system = {} }
  for _, doctor in ipairs(DOCTORS) do
    local ok, entry = pcall(BUILDERS[doctor.key], now)
    if not ok or type(entry) ~= "table" then
      entry = { title = infoTitle(NAMES[doctor.key] .. ": failed to render", true),
        menu = { { title = infoTitle(tostring(entry), true), disabled = true }, { title = "-" } }, problems = 0,
        status = "error" }
    end
    local own = {}
    for _, item in ipairs(entry.menu or {}) do
      local target = rowTarget(doctor.key, item)
      if target then table.insert(moved[target], item) elseif target == nil then own[#own + 1] = item end
    end
    if doctor.key == "harness" then
      for _, item in ipairs((harnessSection(entry.menu, "Lost time"))) do
        local target = rowTarget(doctor.key, item)
        if target and target ~= "speed" then table.insert(moved[target], item) else lostDetails[#lostDetails + 1] = item end
      end
    end
    local document = doctorDocument(doctor)
    local view = redView(doctor, document)
    routeCounts(doctor.key, view, shift, incoming)
    built[#built + 1] = { doctor = doctor, entry = entry, own = own, document = document, view = view }
  end
  local counts = {}
  for _, done in ipairs(built) do
    local key = done.doctor.key
    if done.entry.status ~= "nodata" and done.entry.status ~= "error" then counts[key] = done.view.count + (shift[key] or 0) end
  end
  local histories, louds = redDays(now, counts)
  for _, done in ipairs(built) do
    local doctor, entry, document, view = done.doctor, done.entry, done.document, done.view
    local own = placeRows(done.own, moved[doctor.key], 2)
    local run = latestRun(doctor.key)
    local menu = {}
    local oldTitle = plainText(entry.title)
    local count = tonumber(entry.problems) or 0
    if oldTitle ~= NAMES[doctor.key] .. ": " .. (count > 0 and plural(count, "problem") or "ok")
      and entry.status ~= "nodata" then
      menu[#menu + 1] = dim(oldTitle)
    end
    for _, item in ipairs(own) do menu[#menu + 1] = fitRow(item) end
    local ok, quiet = pcall(quietRow, doctor)
    if ok and quiet then menu[#menu + 1] = quiet end
    menu[#menu + 1] = fixerRow(run, now)
    local stale = oldTitle:find("stale", 1, true) ~= nil
    local shown = view.count + (shift[doctor.key] or 0)
    local status = (entry.status == "nodata" or entry.status == "error") and entry.status
      or shown > 0 and "problems" or entry.status == "blind" and "blind" or "ok"
    local summary = { title = summaryTitle((NAMES[doctor.key]:gsub(" doctor$", "")),
      entry.status ~= "nodata" and entry.status ~= "error" and shown or nil, status, histories[doctor.key] or {}, now, stale,
      nil, louds[doctor.key]),
      menu = egorLayer(firstRows(doctor, document, view, now, moved, incoming), menu, menu),
      problems = entry.status ~= "nodata" and entry.status ~= "error" and shown or 0, status = entry.status }
    if doctor.key == "system" then machine = summary else entries[#entries + 1] = summary end
    if doctor.key == "harness" then
      local metrics = document and type(document.speed) == "table" and document.speed or {}
      local byDay = type(metrics.index_by_day) == "table" and metrics.index_by_day or {}
      local speedRows = issueRows({}, incoming.speed)
      for _, row in ipairs(levelRows(metrics.levels)) do speedRows[#speedRows + 1] = row end
      for _, row in ipairs(lostRows(metrics.rows)) do speedRows[#speedRows + 1] = row end
      for _, item in ipairs(lostDetails) do
        local text = item.title ~= "-" and plainText(item.title) or ""
        if text:match("^Needs Egor") and text ~= "Needs Egor: nothing" then speedRows[#speedRows + 1] = item end
      end
      local lost = tonumber(metrics.index)
      speed = { title = summaryTitle("Lost time", lost, not lost and "nodata" or (shift.speed or 0) > 0 and "problems" or "ok",
        byDay, now,
        stale or not byDay[os.date("%Y-%m-%d", now)], true),
        menu = egorLayer(speedRows, menu, placeRows(lostDetails, moved.speed, 0)), problems = shift.speed or 0 }
      local cost = document and type(document.spend) == "table" and document.spend or {}
      local spendMenu, spendRows = harnessSection(entry.menu, "Spend", cost.issues, "%", "%.1f")
      local index = cost.status ~= "nodata" and tonumber(cost.index) or nil
      -- Spend's audits only watch (share/spend.py): the summary stays green and its rows DIM.
      local spendStatus = not index and "nodata" or "ok"
      spend = { title = summaryTitle("Spend", index, spendStatus,
        type(cost.index_by_day) == "table" and cost.index_by_day or {}, now, stale, true),
        menu = egorLayer(spendRows, menu, spendMenu), problems = 0 }
    end
  end
  entries[#entries + 1] = speed
  entries[#entries + 1] = spend
  entries[#entries + 1] = machine
  if now - night.at >= NIGHT_REFRESH_S then M.refreshNight() end
  if night.text then entries[#entries + 1] = nightEntry() end
  entries[#entries + 1] = { title = "-", problems = 0 }
  for _, item in ipairs({ nightItem("Land night branches now", M.cleanupNow),
      nightItem("Run everything now", M.runEverything) }) do
    item.problems = 0
    entries[#entries + 1] = item
  end
  return style.mono(entries, infoTitle)
end

-- Contract row `ea`: one `start_us<TAB>end_us<TAB>name` line per background build or main-thread lag;
-- bin/speed-doctor prunes the days.
local journalDay = nil
local function hsJournal(name, startedAt, endedAt)
  pcall(function()
    local base = speedDir()
    local folder = base .. "/hs"
    local day = os.date("%Y-%m-%d", math.floor(endedAt))
    if day ~= journalDay then
      journalDay = day
      hs.fs.mkdir(base)
      hs.fs.mkdir(folder)
    end
    limits.journalLine(folder, name, startedAt, endedAt)
  end)
end

local function entries()
  local now = clock()
  if built and now - built.at < M.cacheSeconds then return built.entries end
  local background = limits.inBackground()
  local list = limits.timedMenu("doctors", compute)
  if background then hsJournal("doctors:bg", now, clock()) end
  built = { at = now, entries = list }
  return list
end

-- The gap is measured on mach absolute time, which stops while the Mac sleeps: a wall-clock gap would
-- journal every night's sleep (or a clock jump) as main-thread lag.
local function uptime()
  local timer = hs.timer
  return timer and timer.absoluteTime and timer.absoluteTime() / 1e9 or nil
end

local lagLast, lagUp = nil, nil
function M.lagTick()
  local at, up = clock(), uptime()
  local gap = up and lagUp and up - lagUp or lagLast and at - lagLast
  if gap and gap - LAG_EVERY_S > LAG_MIN_S then hsJournal("hs-lag", at - gap + LAG_EVERY_S, at) end
  lagLast, lagUp = at, up
end
M.lagTimer = hs.timer.doEvery(LAG_EVERY_S, M.lagTick)

-- Counts the red problems only: a blind collector or a watch reads DIM in its summary, never in the title.
function M.title()
  local problems, failed = 0, false
  for _, entry in ipairs(entries()) do
    problems = problems + entry.problems
    failed = failed or entry.status == "error"
  end
  local parts = {}
  if problems > 0 then parts[#parts + 1] = plural(problems, "problem") end
  if failed then parts[#parts + 1] = "failed" end
  if #parts == 0 then return "Doctors" end
  return hs.styledtext.new("Doctors: " .. table.concat(parts, " · "), { color = style.RED, font = (hs.styledtext.defaultFonts or {}).menu })
end

function M.menuItems()
  local items = {}
  for index, entry in ipairs(entries()) do
    items[index] = { title = entry.title, menu = entry.menu, disabled = entry.disabled, fn = entry.fn }
  end
  return items
end

return M
