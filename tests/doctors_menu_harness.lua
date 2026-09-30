local root = debug.getinfo(1, "S").source:match("^@(.+)/tests/[^/]+$")
assert(root, "harness path is unavailable")

local failures, checks = {}, 0
local function check(ok, message)
  checks = checks + 1
  if not ok then failures[#failures + 1] = message end
end
local function text(title) return type(title) == "string" and title or title:getString() end
local function color(title)
  if type(title) == "string" then return nil end
  local runs = title:asTable()
  return runs[2] and runs[2].attributes and runs[2].attributes.color
end
local function red(title)
  local c = color(title)
  return c ~= nil and (c.red or 0) > 0.8 and (c.green or 1) < 0.4
end
local function dimmed(title) return color(title) ~= nil and not red(title) end
local function fix(menu) return menu[#menu - 1] end
local function fixer(menu) return menu[#menu] end
local function refreshRow(menu) return menu[#menu - 2] end
local function allMenlo(menu)
  for _, item in ipairs(menu or {}) do
    if item.title ~= "-" then
      if type(item.title) == "string" then return false end
      local font = item.title:asTable()[2].attributes.font
      if not font or not font.name:find("^Menlo") then return false end
    end
    if item.menu and not allMenlo(item.menu) then return false end
  end
  return true
end
local function find(menu, prefix)
  for _, item in ipairs(menu or {}) do
    if item.title ~= "-" and text(item.title):sub(1, #prefix) == prefix then return item end
  end
end

local dir = os.tmpname()
os.remove(dir)
for _, sub in ipairs({ "", "/llm-doctor", "/harness-doctor", "/harness-doctor/menu", "/updater-doctor", "/doctors",
    "/doctors/runs" }) do
  assert(hs.fs.mkdir(dir .. sub))
end
-- Replaced by rename, as the collectors and bin/doctor-fix write: the readers key their caches on
-- the inode.
local function write(path, body)
  local handle = assert(io.open(dir .. path .. ".tmp", "w"))
  handle:write(type(body) == "table" and hs.json.encode(body) or body)
  handle:close()
  assert(os.rename(dir .. path .. ".tmp", dir .. path))
end
local function remove(path) os.remove(dir .. path) end
local function iso(epoch) return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch) end

-- Tasks and alerts never leave the harness; pathwatcher off keeps the loaded llm-limits copy from
-- watching or collecting anything.
local tasks, alerts = {}, {}
local fakeHs = setmetatable({
  pathwatcher = false,
  alert = { show = function(message) alerts[#alerts + 1] = message end },
  task = { new = function(path, callback, args)
    local task = { path = path, args = args, callback = callback, alive = false }
    function task:setEnvironment(env) self.env = env end
    function task:start() self.alive = true; return self end
    function task:isRunning() return self.alive end
    function task:finish(code, stdout, stderr) self.alive = false; self.callback(code, stdout or "", stderr or "") end
    tasks[#tasks + 1] = task
    return task
  end },
}, { __index = hs })

local limits = assert(loadfile(root .. "/hammerspoon/llm-limits.lua", "t",
  setmetatable({ hs = fakeHs }, { __index = _G })))()
limits.llmDoctorPath = dir .. "/llm-doctor/latest.json"
limits.harnessDoctorDir = dir .. "/harness-doctor"
limits.doctorSnapshotPath = dir .. "/snapshot.json"
limits.llmDoctorCmd = "/fixture/bin/llm-doctor"
limits.harnessDoctorCmd = "/fixture/bin/harness-doctor"

local function loadDoctors()
  local env = setmetatable({ hs = fakeHs, require = function(name)
    if name == "llm-limits" then return limits end
    return require(name)
  end }, { __index = _G })
  local doctors = assert(loadfile(root .. "/hammerspoon/doctors.lua", "t", env))()
  doctors.doctorsDir = dir .. "/doctors"
  doctors.updaterDoctorDir = dir .. "/updater-doctor"
  doctors.doctorFixCmd = "/fixture/bin/doctor-fix"
  doctors.updaterDoctorCmd = "/fixture/bin/updater-doctor"
  doctors.cacheSeconds = 0
  return doctors
end

local now = os.time()
local function llmDocument(status, count)
  return { contract = 1, doctor = "llm", as_of_s = now, status = status, problem_count = count, window_h = 24,
    bugs = 0, summary = "", not_measurable = {},
    -- Judged off the snapshot below: a machinery verdict older than it would kick a re-judge.
    blocks = { { block = "reviewers", machinery = { as_of = now } } } }
end
local function harnessMenu(count, title)
  return "T\t" .. count .. "\t" .. now .. "\t" .. title .. "\n0\td\t\tWaits  ok\n"
end
local updater = {
  contract = 1, doctor = "updater", as_of_s = now, status = "problems", problem_count = 1,
  problems = {
    { id = "codex:integrate", state = "new", fact = "codex 0.160.0 is out and not integrated" },
    { id = "claude:models", state = "watch", fact = "claude lists a model no leg uses" },
  },
  blind_spots = { { id = "grok-changelog", what = "grok has no changelog to read" } },
  vendors = {
    { vendor = "codex", installed = "0.159.0", latest = "0.160.0", checked_at = iso(now - 3 * 3600), result = "ok",
      models = { "gpt-6-astra", "gpt-6-mini" },
      events = {
        { id = "codex-0.158.0", status = "closed", from = "0.157.0", to = "0.158.0",
          created_at = iso(now - 5 * 86400), closed_at = iso(now - 4 * 86400), changed = { "worker-pick table" } },
        { id = "codex-0.159.0", status = "open", from = "0.158.0", to = "0.159.0",
          created_at = iso(now - 2 * 86400), launched_at = iso(now - 2 * 86400), changed = {} },
      } },
    { vendor = "claude", installed = "2.4.1", latest = "2.4.1", checked_at = iso(now - 3 * 3600), models = {},
      events = {} },
  },
}
write("/snapshot.json", { as_of = now, total = 0, anomalies = {} })

-- All quiet: the plain title the neighbouring entries use.
write("/llm-doctor/latest.json", llmDocument("ok", 0))
write("/harness-doctor/menu.txt", harnessMenu(0, "Harness doctor: OK"))
write("/updater-doctor/latest.json", { contract = 1, doctor = "updater", as_of_s = now, status = "ok",
  problem_count = 0, problems = {}, blind_spots = {}, vendors = {} })
local doctors = loadDoctors()
check(doctors.title() == "Doctors", "all ok: " .. text(doctors.title()))
local items = doctors.menuItems()
check(#items == 3 and text(items[1].title):match("^LLM doctor") and text(items[2].title):match("^Harness doctor")
  and text(items[3].title):match("^Updater doctor"), "the three doctors in order")
check(text(items[3].title) == "Updater doctor: ok" and dimmed(items[3].title), "a clean Updater doctor: " .. text(items[3].title))
check(text(fix(items[1].menu).title) == "Fix — open a fixer chat" and fix(items[1].menu).fn ~= nil, "LLM Fix button")
check(text(fix(items[2].menu).title) == "Fix — open a fixer chat", "Harness Fix button")
check(text(fix(items[3].menu).title) == "Fix — update and integrate all vendors", "Updater Fix button")
for _, item in ipairs(items) do
  check(text(fixer(item.menu).title) == "fixer: never ran" and fixer(item.menu).disabled and dimmed(fixer(item.menu).title),
    "no run record: " .. text(fixer(item.menu).title))
  check(text(refreshRow(item.menu).title) == "Refresh" and (item.menu[#item.menu - 3] or {}).title == "-",
    text(item.title) .. ": a separator, then Refresh, above Fix")
end
check(allMenlo(items), "every row under Doctors is Menlo 13")
check(text(items[2].menu[1].title) == "Waits  ok", "the Harness doctor's own rows come first")
local journal = io.open(dir .. "/harness-doctor/menu/" .. os.date("%Y-%m-%d") .. ".tsv")
local journalText = journal and journal:read("*a") or ""
if journal then journal:close() end
check(journalText:find("\tdoctors\n", 1, true) ~= nil, "the build is not timed into the menu journal")

-- N problems, blind, failed.
write("/llm-doctor/latest.json", llmDocument("problems", 2))
write("/harness-doctor/menu.txt", harnessMenu(3, "Harness doctor: 3 problems"))
write("/updater-doctor/latest.json", updater)
doctors = loadDoctors()
check(text(doctors.title()) == "Doctors: 6 problems" and red(doctors.title()), "N problems: " .. text(doctors.title()))
updater.status = "blind"
write("/updater-doctor/latest.json", updater)
check(text(doctors.title()) == "Doctors: 6 problems · blind", "blind: " .. text(doctors.title()))
write("/llm-doctor/latest.json", llmDocument("error", 0))
check(text(doctors.title()) == "Doctors: 4 problems · blind · failed", "failed: " .. text(doctors.title()))
updater.status = "problems"
write("/updater-doctor/latest.json", updater)
write("/llm-doctor/latest.json", llmDocument("ok", 0))
local harnessEntry = limits.harnessDoctorEntry
limits.harnessDoctorEntry = function() error("menu.txt exploded") end
check(text(doctors.title()) == "Doctors: 1 problem · failed", "a throwing builder: " .. text(doctors.title()))
local broken = doctors.menuItems()[2]
check(text(broken.title) == "Harness doctor: failed to render" and red(broken.title)
  and broken.menu[2].title == "-" and text(fix(broken.menu).title) == "Fix — open a fixer chat",
  "a throwing builder keeps its Fix row")
limits.harnessDoctorEntry = harnessEntry

-- The Updater doctor's rows.
items = doctors.menuItems()
local up = items[3]
check(text(up.title) == "Updater doctor: 1 problem" and red(up.title), "Updater title: " .. text(up.title))
check(text(up.menu[1].title) == "codex 0.160.0 is out and not integrated" and red(up.menu[1].title), "a new problem is red")
check(text(up.menu[2].title) == "claude lists a model no leg uses" and dimmed(up.menu[2].title), "a watch problem is dim")
local codex = find(up.menu, "codex 0.159.0")
check(codex and text(codex.title) == "codex 0.159.0 · checked 3h ago · latest 0.160.0", "vendor row: "
  .. (codex and text(codex.title) or "missing"))
local claude = find(up.menu, "claude 2.4.1")
check(claude and text(claude.title) == "claude 2.4.1 · checked 3h ago", "an up-to-date vendor names no latest")
local sub = {}
for _, item in ipairs(codex and codex.menu or {}) do sub[#sub + 1] = item.title == "-" and "-" or text(item.title) end
check(table.concat(sub, "|") == "gpt-6-astra|gpt-6-mini|-|codex-0.159.0 · open · 0.158.0 → 0.159.0 · 2d ago"
  .. "|codex-0.158.0 · closed · 0.157.0 → 0.158.0 · 4d ago", "vendor submenu: " .. table.concat(sub, "|"))
check(codex and codex.menu[5].menu and text(codex.menu[5].menu[1].title) == "worker-pick table", "an event lists what it changed")
check(find(up.menu, "blind: grok has no changelog to read") and dimmed(find(up.menu, "blind: ").title), "blind spots dim")
local refresh = refreshRow(up.menu)
check(text(refresh.title) == "Refresh" and refresh.fn and (up.menu[#up.menu - 3] or {}).title == "-",
  "the Updater doctor has Refresh after a separator")
tasks = {}
refresh.fn()
check(#tasks == 1 and tasks[1].path == "/fixture/bin/updater-doctor" and #tasks[1].args == 0, "Refresh runs bin/updater-doctor")
check(text(refreshRow(doctors.menuItems()[3].menu).title) == "refreshing…", "a running Refresh")
tasks[1]:finish(0)
updater.as_of_s = now - 3 * 86400
write("/updater-doctor/latest.json", updater)
check(text(doctors.menuItems()[3].title) == "Updater doctor: 1 problem · stale 3d", "stale: " .. text(doctors.menuItems()[3].title))
updater.status, updater.problem_count, updater.as_of_s = "error", 0, now
updater.self = { collector_s = 1, error = "vendor-fingerprint: no such file" }
write("/updater-doctor/latest.json", updater)
up = doctors.menuItems()[3]
check(text(up.title) == "Updater doctor: collector failed" and text(up.menu[1].title) == "vendor-fingerprint: no such file"
  and red(up.menu[1].title), "a failed collector names its error")

-- A missing document.
remove("/updater-doctor/latest.json")
up = doctors.menuItems()[3]
check(text(up.title) == "Updater doctor: no data yet" and text(up.menu[1].title) == "no data yet"
  and up.menu[2].title == "-" and text(up.menu[3].title) == "Refresh" and #up.menu == 5, "missing file: " .. text(up.title))

-- Fixer rows off the newest run record.
write("/doctors/runs/llm-20260101T000000Z.json", { doctor = "llm", launched_at = iso(now - 90 * 86400) })
write("/doctors/runs/llm-20260201T000000Z.json", { doctor = "llm", launched_at = iso(now - 3 * 86400),
  closed_at = iso(now - 2 * 86400), problems = { "a", "b", "c", "d" },
  decisions = { { id = "a", verdict = "fixed" }, { id = "b", verdict = "fixed" }, { id = "c", verdict = "handoff" },
    { id = "d", verdict = "fixed" }, { id = "judge", verdict = "judge-changed" } } })
write("/doctors/runs/harness-20260201T000000Z.json", { doctor = "harness", launched_at = iso(now - 2 * 3600 - 60) })
write("/doctors/runs/updater-20260201T000000Z.json", { doctor = "updater", launched_at = iso(now - 3 * 86400),
  abandoned_at = iso(now - 86400 - 60) })
items = doctors.menuItems()
check(text(fixer(items[1].menu).title) == "fixer: ran 2d ago · closed · 3 fixed · 1 handoff", "closed: " .. text(fixer(items[1].menu).title))
check(text(fix(items[1].menu).title) == "Fix — open a fixer chat" and fix(items[1].menu).fn, "a closed run leaves Fix on")
check(text(fixer(items[2].menu).title) == "fixer: running for 2h", "open: " .. text(fixer(items[2].menu).title))
check(text(fix(items[2].menu).title) == "Fix — fixer running for 2h" and fix(items[2].menu).disabled
  and not fix(items[2].menu).fn and dimmed(fix(items[2].menu).title), "Fix is off while a young run is open")
check(text(fixer(items[3].menu).title) == "fixer: abandoned 24h ago", "abandoned: " .. text(fixer(items[3].menu).title))
write("/doctors/runs/harness-20260201T000000Z.json", { doctor = "harness", launched_at = iso(now - 14 * 3600) })
items = doctors.menuItems()
check(text(fix(items[2].menu).title) == "Fix — open a fixer chat" and fix(items[2].menu).fn, "a run open 14 h no longer holds Fix")
check(text(fixer(items[2].menu).title) == "fixer: running for 14h", "old open run: " .. text(fixer(items[2].menu).title))

-- The Fix button's command line, its opening row and its alerts.
tasks, alerts = {}, {}
fix(items[3].menu).fn()
check(#tasks == 1 and tasks[1].path == "/fixture/bin/doctor-fix" and table.concat(tasks[1].args, " ") == "launch updater",
  "Fix runs bin/doctor-fix launch updater")
check(tasks[1] and tasks[1].env and tasks[1].env.HOME == os.getenv("HOME"), "the fix task lost HOME")
local opening = fix(doctors.menuItems()[3].menu)
check(text(opening.title) == "Fix — opening…" and opening.disabled, "a running launch reads opening")
fix(items[3].menu).fn()
check(#tasks == 1, "a second click launched a second fixer")
tasks[1]:finish(0, "starting\nopened fixer chat «Updater fix»\n")
check(alerts[1] == "opened fixer chat «Updater fix»", "the last output line: " .. tostring(alerts[1]))
check(text(fix(doctors.menuItems()[3].menu).title) == "Fix — update and integrate all vendors", "Fix is back after exit")
fix(doctors.menuItems()[1].menu).fn()
check(table.concat(tasks[2].args, " ") == "launch llm", "Fix on the LLM doctor launches llm")
tasks[2]:finish(3, "", "checking\nrefused: a run is already open\n")
check(alerts[2] and alerts[2]:find("exit 3", 1, true) and alerts[2]:find("refused: a run is already open", 1, true),
  "a failed launch shows its line: " .. tostring(alerts[2]))

os.execute("rm -rf '" .. dir .. "'")
if #failures > 0 then return "FAIL: " .. table.concat(failures, "; ") end
return "PASS: " .. checks .. " doctors menu checks"
