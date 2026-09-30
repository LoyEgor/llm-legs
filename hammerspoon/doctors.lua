local home = os.getenv("HOME")
local repoRoot = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]+/[^/]+$")
local limits = require("llm-limits")
local style = require("menu-style")
local infoTitle = limits.infoTitle

local M = { cacheSeconds = 2 }

local FIX_BUSY_S = 12 * 3600
local UPDATER_STALE_S = 2 * 86400
local VERDICTS = { "fixed", "ruled-out", "weather", "blind-spot", "handoff" }
local LOUD = { new = true, open = true, regressed = true }
local DOCTORS = {
  { key = "llm", fix = "Fix — open a fixer chat" },
  { key = "harness", fix = "Fix — open a fixer chat" },
  { key = "updater", fix = "Fix — update and integrate all vendors" },
}

local fixTasks, jsonCache, built = {}, {}, nil

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

local function dim(text) return { title = infoTitle(text, false, true), disabled = true } end

local function readJson(path)
  local attrs = hs.fs.attributes(path)
  if not attrs then jsonCache[path] = nil return nil end
  local key = string.format("%s:%s:%s", attrs.ino or "", attrs.modification or "", attrs.size or "")
  local hit = jsonCache[path]
  if hit and hit.key == key then return hit.value end
  local ok, value = pcall(hs.json.read, path)
  value = ok and type(value) == "table" and value or nil
  jsonCache[path] = { key = key, value = value }
  return value
end

local function latestRun(doctor)
  local runs = dirFor("doctorsDir", "DOCTORS_DIR", "/.cache/doctors") .. "/runs"
  local ok, iter, state = pcall(hs.fs.dir, runs)
  if not ok or not iter then return nil end
  local prefix, newest = doctor .. "-", nil
  for name in iter, state do
    if name:sub(1, #prefix) == prefix and name:match("%.json$") and (not newest or name > newest) then newest = name end
  end
  return newest and readJson(runs .. "/" .. newest) or nil
end

local function runState(run)
  if type(run) ~= "table" then return nil end
  local closed, abandoned = limits.parseTime(run.closed_at), limits.parseTime(run.abandoned_at)
  if closed then return "closed", closed end
  if abandoned then return "abandoned", abandoned end
  return "open", limits.parseTime(run.launched_at) or limits.parseTime(run.created_at)
end

local function verdictCounts(decisions)
  local counts = {}
  for _, decision in pairs(type(decisions) == "table" and decisions or {}) do
    local verdict = type(decision) == "table" and (decision.verdict or decision.decision)
      or type(decision) == "string" and (decision:match("^[^\t]*\t([^\t]+)") or decision)
    if type(verdict) == "string" and verdict ~= "judge-changed" then counts[verdict] = (counts[verdict] or 0) + 1 end
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

function M.fix(doctor)
  if running(fixTasks[doctor]) then return end
  local path = M.doctorFixCmd or (repoRoot and repoRoot .. "/bin/doctor-fix")
  local ok, task = pcall(hs.task.new, path, function(code, stdout, stderr)
    fixTasks[doctor], built = nil, nil
    local line = code == 0 and (lastLine(stdout) or lastLine(stderr))
      or (lastLine(stderr) or lastLine(stdout))
    if code == 0 then
      hs.alert.show(line or ("doctor-fix launched the " .. doctor .. " fixer"), 3)
    else
      hs.alert.show("Fix failed (exit " .. tostring(code) .. "): " .. (line or "no output"), 5)
    end
  end, { "launch", doctor })
  if not ok or not task then
    hs.alert.show("Fix failed: could not start " .. tostring(path), 5)
    return
  end
  task:setEnvironment(limits.diagnosticsEnvironment())
  fixTasks[doctor], built = task, nil
  if not task:start() then
    fixTasks[doctor] = nil
    hs.alert.show("Fix failed: could not start " .. tostring(path), 5)
  end
end

local function fixItem(doctor, label, run, now)
  if running(fixTasks[doctor]) then return dim("Fix — opening…") end
  local state, at = runState(run)
  if state == "open" and at and now - at < FIX_BUSY_S then return dim("Fix — fixer running for " .. style.age(now - at)) end
  return { title = infoTitle(label), fn = function() M.fix(doctor) end }
end

local updaterTask = nil

local function updaterPath()
  return dirFor("updaterDoctorDir", "UPDATER_DOCTOR_DIR", "/.cache/updater-doctor") .. "/latest.json"
end

local function updaterTitle(document)
  if not document then return "Updater doctor: no data yet" end
  local count = tonumber(document.problem_count) or 0
  local parts = {}
  if count > 0 then parts[#parts + 1] = plural(count, "problem") end
  if document.status == "blind" then parts[#parts + 1] = "blind" end
  if document.status == "error" then parts[#parts + 1] = "collector failed" end
  local title = "Updater doctor: " .. (#parts > 0 and table.concat(parts, " · ") or "ok")
  local asOf = tonumber(document.as_of_s)
  if asOf and os.time() - asOf >= UPDATER_STALE_S then
    title = title .. " · stale " .. style.age(os.time() - asOf)
  end
  return title
end

function M.refreshUpdater()
  if running(updaterTask) then return end
  local path = M.updaterDoctorCmd or (repoRoot and repoRoot .. "/bin/updater-doctor")
  local ok, task = pcall(hs.task.new, path, function(code, stdout, stderr)
    updaterTask, built = nil, nil
    if code ~= 0 then
      hs.alert.show("Updater doctor failed: " .. (lastLine(stderr) or lastLine(stdout) or ("exit " .. tostring(code))), 5)
    else
      hs.alert.show(updaterTitle(readJson(updaterPath())), 2.5)
    end
  end, {})
  if not ok or not task then
    hs.alert.show("Updater doctor: could not start " .. tostring(path), 5)
    return
  end
  task:setEnvironment(limits.diagnosticsEnvironment())
  updaterTask, built = task, nil
  if not task:start() then
    updaterTask = nil
    hs.alert.show("Updater doctor: could not start " .. tostring(path), 5)
  end
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
        local text = string.format("%s %s · %s", tostring(vendor.vendor or "?"), tostring(vendor.installed or "?"),
          checked and ("checked " .. style.ago(now - checked)) or "never checked")
        local behind = vendor.latest ~= nil and vendor.latest ~= vendor.installed
        if behind then text = text .. " · latest " .. tostring(vendor.latest) end
        items[#items + 1] = { title = infoTitle(text, false, not behind), menu = vendorMenu(vendor, now) }
      end
    end
    for _, spot in ipairs(type(document.blind_spots) == "table" and document.blind_spots or {}) do
      if type(spot) == "table" then items[#items + 1] = dim("blind: " .. tostring(spot.what or spot.id or "?")) end
    end
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = running(updaterTask) and dim("refreshing…") or { title = infoTitle("Refresh"), fn = M.refreshUpdater }
  local count = document and tonumber(document.problem_count) or 0
  local status = not document and "nodata" or ({ ok = true, problems = true, blind = true, error = true })[document.status]
    and document.status or count > 0 and "problems" or "ok"
  local loud = count > 0 or status == "error"
  return { title = infoTitle(updaterTitle(document), loud, not loud and status ~= "blind"), menu = items,
    problems = count, status = status }
end

local BUILDERS = {
  llm = function() return limits.llmDoctorEntry() end,
  harness = function() return limits.harnessDoctorEntry() end,
  updater = updaterEntry,
}
local NAMES = { llm = "LLM doctor", harness = "Harness doctor", updater = "Updater doctor" }

local function compute()
  local now = os.time()
  local entries = {}
  for _, doctor in ipairs(DOCTORS) do
    local ok, entry = pcall(BUILDERS[doctor.key], now)
    if not ok or type(entry) ~= "table" then
      entry = { title = infoTitle(NAMES[doctor.key] .. ": failed to render", true),
        menu = { { title = infoTitle(tostring(entry), true), disabled = true }, { title = "-" } }, problems = 0,
        status = "error" }
    end
    local run = latestRun(doctor.key)
    local menu = {}
    for _, item in ipairs(entry.menu or {}) do menu[#menu + 1] = item end
    menu[#menu + 1] = fixItem(doctor.key, doctor.fix, run, now)
    menu[#menu + 1] = fixerRow(run, now)
    entries[#entries + 1] = { title = entry.title, menu = menu, problems = tonumber(entry.problems) or 0,
      status = entry.status }
  end
  return style.mono(entries, infoTitle)
end

local function entries()
  local now = clock()
  if built and now - built.at < M.cacheSeconds then return built.entries end
  local list = limits.timedMenu("doctors", compute)
  built = { at = now, entries = list }
  return list
end

function M.title()
  local problems, blind, failed = 0, false, false
  for _, entry in ipairs(entries()) do
    problems = problems + entry.problems
    blind = blind or entry.status == "blind"
    failed = failed or entry.status == "error"
  end
  local parts = {}
  if problems > 0 then parts[#parts + 1] = plural(problems, "problem") end
  if blind then parts[#parts + 1] = "blind" end
  if failed then parts[#parts + 1] = "failed" end
  if #parts == 0 then return "Doctors" end
  return hs.styledtext.new("Doctors: " .. table.concat(parts, " · "), { color = style.RED, font = (hs.styledtext.defaultFonts or {}).menu })
end

function M.menuItems()
  local items = {}
  for index, entry in ipairs(entries()) do items[index] = { title = entry.title, menu = entry.menu } end
  return items
end

return M
