#!/usr/bin/env bash
set -u

# End-to-end check of the REAL user-facing llm-limits surfaces on this Mac: the live
# Hammerspoon menubar module, the llm-limits CLI, and claudeb status. It touches the
# live store read-only plus free (zero-model-spend) --refresh calls; --start-windows and
# --heal are never invoked. Each check prints PASS or a specific FAIL and exits non-zero
# on the first failure.
#
# SINGLETON SAFETY (hard rule after a past incident): every `hs -c` snippet only READS
# the live module (package.loaded["llm-limits"]) and CALLS its read path (menuItems).
# It never assigns to any module field (cachePath, timers, callbacks). Mutating the live
# singleton would silently break the user's real menubar while console checks stay green.

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

STORE="$HOME/.llm-limits.json"

command -v hs >/dev/null 2>&1 || fail "hs CLI not on PATH"
command -v llm-limits >/dev/null 2>&1 || fail "llm-limits not on PATH"
command -v claudeb >/dev/null 2>&1 || fail "claudeb not on PATH"
command -v jq >/dev/null 2>&1 || fail "jq not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH (needed to parse ISO timestamps)"

iso2epoch() {
  python3 -c 'import sys,datetime; value=sys.argv[1]; print(int(float(value)) if value.replace(".", "", 1).isdigit() else int(datetime.datetime.fromisoformat(value.replace("Z","+00:00")).timestamp()))' "$1"
}

# Read-only serialization of the LIVE menubar module. Guards that the live singleton
# still points at the real store (a scratch cachePath = the past-incident regression),
# then flattens menuItems() titles (including account submenus) to plain text. Any
# problem is reported as an "HS_ERR ..." line the caller treats as a failure.
HS_SERIALIZE='
local m = package.loaded["llm-limits"]
if type(m) ~= "table" then print("HS_ERR module-not-loaded") return end
if m.cachePath ~= os.getenv("HOME") .. "/.llm-limits.json" then
  print("HS_ERR cachePath-not-real-store:" .. tostring(m.cachePath)) return
end
if type(m.menuItems) ~= "function" then print("HS_ERR no-menuItems") return end
local ok, menu = pcall(m.menuItems)
if not ok then print("HS_ERR menuItems-threw:" .. tostring(menu)) return end
if type(menu) ~= "table" then print("HS_ERR menu-not-table") return end
local function s(t)
  if type(t) == "string" then return t
  elseif type(t) == "userdata" and t.getString then return t:getString()
  else return tostring(t) end
end
local out = {}
for _, it in ipairs(menu) do
  table.insert(out, s(it.title))
  -- Routing holds worker-pick output verbatim; its middots are not renderer-authored prose,
  -- and the aggregate-age ban below must keep guarding only what the renderer words itself.
  if type(it.menu) == "table" and s(it.title) ~= "Routing" then
    for _, sub in ipairs(it.menu) do table.insert(out, "  " .. s(sub.title)) end
  end
end
print(table.concat(out, "\n"))
'

hs_menu() {
  local out
  out=$(hs -c "$HS_SERIALIZE" 2>/dev/null)
  case "$out" in
    HS_ERR*) fail "live menu read path: ${out#HS_ERR }" ;;
  esac
  [ -n "$out" ] || fail "live menu read path returned empty output"
  printf '%s\n' "$out"
}

hs_alona_five_style() {
  hs -c '
local m = package.loaded["llm-limits"]
local menu = m and m.menuItems()
local seen = false
for _, item in ipairs(menu or {}) do
  local title = item.title
  local text = type(title) == "userdata" and title.getString and title:getString() or tostring(title)
  if seen and text:find("5h", 1, true) then
    local data = title:asTable()
    local color = data[2] and data[2].attributes and data[2].attributes.color
    -- Dim is the menu label colour at 55% alpha, so the tone follows the appearance; a check
    -- pinned to one fixed gray passes only in whichever appearance it was written for.
    if color and math.abs((color.alpha or 1) - 0.55) < 0.01
        and math.abs(color.red - color.green) < 0.01
        and math.abs(color.green - color.blue) < 0.01 then return "DIM\t" .. text end
    return "NOT_DIM\t" .. text
  end
  if text == "alona" or text:match("^alona%s") then seen = true end
end
return "MISSING"
' 2>/dev/null
}

assert_codex_account_rows() {
  local menu="$1" json="$2" count account auth credits needs_entry row
  count=$(jq '.vendors.codex.accounts | length' <<<"$json")
  while IFS= read -r account; do
    auth=$(jq -r --arg account "$account" '.vendors.codex.accounts[] | select(.account == $account) | .auth_needed == true' <<<"$json")
    credits=$(jq -r --arg account "$account" '.vendors.codex.accounts[] | select(.account == $account) | .reset_credits // 0' <<<"$json")
    if [ "$auth" = true ]; then
      needs_entry=$(jq -r --arg account "$account" '.vendors.codex.accounts[] |
        select(.account == $account) | .needs_user_entry == true' <<<"$json")
      row=$(awk -v account="$account" '$1 == account {print; exit}' <<<"$menu")
      [ -n "$row" ] || fail "Codex auth-needed row missing: $account"
      [[ "$row" == *"login needed" ]] || fail "Codex auth-needed row lost login needed: $row"
      if [ "$needs_entry" = true ]; then
        [[ "$row" == *"!"* ]] || fail "Codex auth-needed row lacks the user-entry marker: $row"
      else
        [ "$row" = "$account  login needed" ] \
          || fail "Codex auth-needed row is not name plus login needed: $row"
      fi
    else
      row=$(awk -v account="$account" '$1 == account {print; exit}' <<<"$menu")
      [ -n "$row" ] || fail "Codex account row missing: $account"
      if [ "$credits" -gt 0 ]; then
        grep -Fq "$account  ↻$credits" <<<"$row" || fail "Codex reset-credit count missing for $account"
      else
        [[ "$row" != *↻* ]] || fail "Codex zero/absent reset credits rendered for $account"
      fi
    fi
  done < <(jq -r '.vendors.codex.accounts[]?.account' <<<"$json")
}

age_short() {
  local timestamp="$1" now delta minutes hours
  [ -n "$timestamp" ] || return
  now=$(date +%s)
  delta=$((now - $(iso2epoch "$timestamp")))
  [ "$delta" -gt 300 ] || return
  minutes=$((delta / 60))
  if [ "$minutes" -lt 60 ]; then printf '%sm' "$minutes"; return; fi
  hours=$((minutes / 60))
  if [ "$hours" -lt 24 ]; then printf '%sh' "$hours"; return; fi
  printf '%sd' "$((hours / 24))"
}

# Account names repeat across vendors (`main` exists for both Codex and Gemini), so a
# row must be located inside its own vendor's section — a bare first-match lookup
# silently compares one vendor's age against another's.
vendor_section() {
  local menu="$1" label="$2"
  awk -v label="$label" '
    index($0, label) == 1 { inside = 1; next }
    inside && /^(Claude|Codex|Gemini)/ { inside = 0 }
    inside { print }' <<<"$menu"
}

assert_account_ages() {
  local menu="$1" json="$2" vendor account auth asof expected row actual section label
  for vendor in claude codex gemini; do
    if [ "$vendor" = gemini ] &&
       [ "$(jq -r '(.vendors.gemini.accounts | type) == "array" and
          (.vendors.gemini.accounts | length) > 1' <<<"$json")" != true ]; then
      continue
    fi
    case "$vendor" in
      claude) label=Claude ;;
      codex) label=Codex ;;
      gemini) label=Gemini ;;
    esac
    section=$(vendor_section "$menu" "$label")
    while IFS=$'\t' read -r account auth asof; do
      [ -n "$account" ] || continue
      row=$(awk -v account="$account" '$1 == account {print; exit}' <<<"$section")
      [ -n "$row" ] || fail "$vendor account row missing for age check: $account"
      [ "$auth" != true ] || continue
      expected=$(age_short "$asof")
      # A pinned account carries a trailing ● after the age; the age is still the fact under test.
      actual=$(sed -E 's/([[:space:]]+(●|!))+$//' <<<"$row" | awk '{print $NF}')
      if [ -n "$expected" ]; then
        [ "$actual" = "$expected" ] || fail "$vendor/$account age mismatch: expected $expected, row=$row"
      elif [[ "$actual" =~ ^[0-9]+[mhd]$ ]]; then
        fail "$vendor/$account is at most 5m old but displays age: $row"
      fi
    done < <(jq -r --arg vendor "$vendor" '.vendors[$vendor].accounts[]? |
      [.account, (.auth_needed == true), (.as_of // "")] | @tsv' <<<"$json")
  done
  if [ "$(jq -r '.vendors.gemini.available == true and
      ((.vendors.gemini.accounts | type) != "array" or (.vendors.gemini.accounts | length) <= 1)' <<<"$json")" = true ]; then
    row=$(awk '$1 == "Gemini" {print; exit}' <<<"$menu")
    [ -n "$row" ] || fail "Gemini vendor row missing for age check"
    expected=$(age_short "$(jq -r '.vendors.gemini.as_of // ""' <<<"$json")")
    actual=$(sed -E 's/([[:space:]]+(●|!))+$//' <<<"$row" | awk '{print $NF}')
    if [ -n "$expected" ]; then
      [ "$actual" = "$expected" ] || fail "Gemini age mismatch: expected $expected, row=$row"
    elif [[ "$actual" =~ ^[0-9]+[mhd]$ ]]; then
      fail "Gemini is at most 5m old but displays age: $row"
    fi
  fi
}

# The whole OpenCode chain in one fixture: bin/opencode-go writes a wall record against a stubbed
# gateway, llm-limits.sh turns that record and its neighbours into vendor rows, and the menubar
# renders those rows. Whether a wall still stands is decided once, in the collector, and this is
# what proves the menu is not deciding it again. Prints "<epoch><TAB><.vendors.opencode>".
opencode_vendor_fixture() {
  local sandbox stub body now walls repo
  repo=$(cd "$(dirname "$0")/.." && pwd)
  sandbox=$(mktemp -d)
  stub="$sandbox/bin"
  walls="$sandbox/worker-stats/walls.jsonl"
  mkdir -p "$stub" "$sandbox/worker-stats/opencode-seen"
  body='{"type":"error","error":{"type":"GoUsageLimitError","message":"Weekly usage limit reached. Resets in 3 days."},"metadata":{"limitName":"weekly"}}'
  cat >"$stub/curl" <<'STUB'
#!/usr/bin/env bash
out= url=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -o) out=${args[i + 1]} ;;
    http*) url=${args[i]} ;;
  esac
done
if [[ $url == */models ]]; then
  if [ -n "$out" ]; then printf '%s' "$MODELS" >"$out"; printf '200'; else printf '%s' "$MODELS"; fi
  exit 0
fi
cat >/dev/null
printf '%s' "$WALL_BODY" >"$out"
printf '429'
STUB
  chmod +x "$stub/curl"
  now=$(date +%s)
  PATH="$stub:$PATH" TMPDIR="$sandbox" WORKER_STATS_DIR="$sandbox/worker-stats" \
    OPENCODE_GO_PROFILE=evyoxqy OPENCODE_GO_KEY=fixture-key WALL_BODY="$body" \
    MODELS='{"data":[{"id":"glm-5.2"}]}' \
    bash "$repo/bin/opencode-go" run glm-5.2 ping >/dev/null 2>&1
  grep -q '"account":"opencode-go-evyoxqy"' "$walls" ||
    fail "bin/opencode-go recorded no wall for a plan 429: [$(cat "$walls" 2>/dev/null)]"
  # The neighbours are written straight to the record: they are the shapes a live 429 cannot be
  # made to produce on demand — a lapsed horizon, a legacy row with no window, two windows at once.
  # review-bench writes fractional epochs; integer fixtures would hide the os.date crash.
  jq -cn --argjson now "$now" '
    def row($account; $detected; $reset; $window):
      {side:"opencode",account:$account,bucket:"general",detected_at:($detected + 0.25)} +
      (if $reset == null then {} else {reset_at:($reset + 0.25)} end) +
      (if $window == null then {} else {window:$window} end);
    row("opencode-go"; $now - 10; $now + 86400; null),
    row("opencode-go-alt"; $now - 10; $now + 2 * 86400; "weekly"),
    row("opencode-go-alt"; $now - 20; $now + 4 * 3600; "5-hour"),
    row("opencode-go-alt"; $now - 30; $now + 86400; null),
    row("opencode-go-clear"; $now - 7200; $now - 60; "monthly"),
    row("opencode-go-far"; $now - 10; $now + 19 * 86400; "monthly"),
    row("opencode-go-fresh"; $now - 7200; $now - 3600; "weekly"),
    row("opencode-go-fresh"; $now - 600; null; "weekly"),
    {side:"opencode",account:"opencode-go-tied",bucket:"general",
     detected_at:($now - 900),reset_at:($now + 86400),window:"weekly"}' >>"$walls"
  printf '%s\n' "$((now - 3600))" >"$sandbox/worker-stats/opencode-seen/opencode-go-served"
  # The one thing that ends a wall: a completion the plan served after the refusal was filed.
  printf '%s\n' "$((now - 1800))" >"$sandbox/worker-stats/opencode-seen/opencode-go-clear"
  # A refusal in the very second of the served stamp: the tie must keep the wall, because only a
  # standing wall is ever probed again — read as served, the account would freeze clean forever.
  printf '%s\n' "$((now - 900))" >"$sandbox/worker-stats/opencode-seen/opencode-go-tied"
  printf '# roster\n-\nalt\nclear\nfar\nevyoxqy\nfresh\nserved\ntied\n' >"$sandbox/profiles"
  local rows
  rows=$(HOME="$sandbox/home" WORKER_STATS_DIR="$sandbox/worker-stats" \
    OPENCODE_GO_PROFILES="$sandbox/profiles" LLM_LIMITS_CACHE="$sandbox/cache.json" \
    LLM_LIMITS_NOW="$now" bash "$repo/llm-limits.sh" --json 2>/dev/null |
    jq -c '.vendors.opencode')
  # The evyoxqy horizon as it was actually recorded: opencode-go stamps its own clock inside the
  # run above, so an expectation derived from $now flakes whenever the run crosses a minute mark.
  printf '%s\t%s\t%s\n' "$now" \
    "$(jq -r 'first(.accounts[] | select(.account == "evyoxqy") | .windows[0].resets_at | fromdateiso8601)' <<<"$rows")" \
    "$rows"
  rm -rf "$sandbox"
}

assert_isolated_menu_contracts() {
  local output opencode_fixture opencode_now opencode_evyoxqy_reset opencode_rows
  opencode_fixture=$(opencode_vendor_fixture)
  opencode_now=${opencode_fixture%%	*}
  opencode_rows=${opencode_fixture#*	}
  opencode_evyoxqy_reset=${opencode_rows%%	*}
  opencode_rows=${opencode_rows#*	}
  [ -n "$opencode_rows" ] || fail "llm-limits.sh emitted no OpenCode rows for the menu fixture"
  output=$(hs -c '
local path = "/Volumes/Work/Projects/llm-legs/hammerspoon/llm-limits.lua"
local realJsonDecode = hs.json.decode
local function styled(text, attributes)
  local value = { text = text, attributes = attributes }
  return setmetatable(value, {
    __concat = function(left, right)
      local l = type(left) == "table" and left.text or tostring(left)
      local r = type(right) == "table" and right.text or tostring(right)
      return styled(l .. r, type(left) == "table" and left.attributes or right.attributes)
    end,
  })
end
local function loadModule(fixture, state)
  state.now = state.now or os.time()
  local mock = {
    alert = { show = function(message) table.insert(state.alerts, message) end },
    execute = function() return true end,
    fs = { attributes = function() return nil end },
    json = { decode = function(contents)
      if contents == "fixture" then return fixture end
      return realJsonDecode(contents)
    end },
    styledtext = { new = styled },
    task = {},
  }
  mock.task.new = function(command, callback, args)
    local task = { command = command, callback = callback, args = args or {} }
    function task:setEnvironment(environment)
      self.environment = environment or {}
      return self
    end
    function task:start()
      self.running = true
      table.insert(state.starts, self)
      return true
    end
    function task:isRunning() return self.running == true end
    return task
  end
  local fakeIo = setmetatable({
    open = function(filePath)
      local contents = "fixture"
      if contents == nil then return nil end
      return {
        read = function() return contents end,
        lines = function() return tostring(contents):gmatch("[^\r\n]+") end,
        close = function() end,
      }
    end,
  }, { __index = io })
  local fakeOs = setmetatable({
    time = function(value)
      if value then return os.time(value) end
      return state.now
    end,
    getenv = function(name)
      if name == "HOME" then return "/fixture-home" end
      if name == "WORKER_STATS_DIR" or name == "CLAUDEB_DIR" then return nil end
      return os.getenv(name)
    end,
  }, { __index = os })
  local env = setmetatable({ hs = mock, io = fakeIo, os = fakeOs }, { __index = _G })
  env._G = env
  local chunk, err = loadfile(path, "t", env)
  if not chunk then error(err) end
  return chunk()
end
local function title(item) return type(item.title) == "table" and item.title.text or item.title end
local now = os.time()
local expiredState = { starts = {}, alerts = {} }
local expired = loadModule({ schema = 1, vendors = {
  claude = { available = true, source = "claudeb-store", accounts = {{
    account = "alona", enabled = true, five_hour = {
      effective_pct = 100, resets_at = nil, stale = false, expired = true,
    },
  }}},
  codex = { available = false }, gemini = { available = false },
}}, expiredState)
local expiredMenu = expired.menuItems()
local expiredRow
for i, item in ipairs(expiredMenu) do
  if title(item) == "alona" then expiredRow = expiredMenu[i + 1] break end
end
if not expiredRow or not title(expiredRow):match("%s–%s*$") then error("null reset did not render dash") end
local color = expiredRow.title.attributes.color
if not color or color.red ~= 0.9 or color.green ~= 0.25 or color.blue ~= 0.2
    or color.alpha ~= 0.55 then
  error("expired at-limit row was not dim red")
end
local entryState = { starts = {}, alerts = {} }
local entryCause = "alona: not refreshed (needs-relogin)"
local entry = loadModule({ schema = 1, vendors = {
  claude = {
    available = true,
    source = "claudeb-store",
    refresh_error = { cause = entryCause, at = now - 600, needs_user_entry = true },
    accounts = {{
      account = "alona",
      enabled = true,
      as_of = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 600),
      needs_user_entry = true,
      five_hour = { effective_pct = 10, resets_at = now + 3600, stale = true },
    }},
  },
  codex = { available = false }, gemini = { available = false },
}}, entryState)
if entry.refreshState().prefix ~= "" then error("entry-only cause lit the global warning") end
local entryRow, entryError
for _, item in ipairs(entry.menuItems()) do
  local text = title(item)
  if text:match("^alona%s") then entryRow = text end
  if text:find("refresh failed", 1, true) then entryError = text end
end
if not entryRow or not entryRow:find("10m", 1, true) or not entryRow:find("!", 1, true) then
  error("entry-only account row lacks age-adjacent ! marker: " .. tostring(entryRow))
end
if not entryError or not entryError:find("needs-relogin", 1, true) then
  error("entry-only error text disappeared")
end
local fallbackState = { starts = {}, alerts = {} }
local fallback = loadModule({ schema = 1, vendors = {
  claude = { available = true, current_account = "com", five_hour = { effective_pct = 1, resets_at = now + 60 } },
  codex = { available = true, current_account = "main", five_hour = { effective_pct = 2, resets_at = now + 60 } },
  gemini = { available = true, five_hour = { effective_pct = 3, resets_at = now + 60 } },
}}, fallbackState)
local changes = 0
fallback.onRefreshStateChanged = function() changes = changes + 1 end
for _, item in ipairs(fallback.menuItems()) do
  local name = title(item)
  if (name == "Claude" or name == "Codex" or name == "Gemini") and item.menu then
    for _, sub in ipairs(item.menu) do
      if title(sub) == "Hard refresh" then sub.fn() end
    end
  end
end
if #fallbackState.starts ~= 4 then error("menu collect and fallback actions did not start four tasks") end
local passive, a, b, c = fallbackState.starts[1], fallbackState.starts[2], fallbackState.starts[3], fallbackState.starts[4]
if passive.command ~= "/Volumes/Work/Projects/llm-legs/llm-limits.sh" or #passive.args ~= 0 then
  error("menu-open collector was not a direct argument-free task")
end
passive.running = false
local beforeCompletion = changes
passive.callback(0, "", "")
if changes ~= beforeCompletion + 1 then error("menu-open collector completion did not trigger a re-render") end
if a.args[1] ~= "--refresh-account" or a.args[2] ~= "claude/com" then error("Claude fallback dispatch mismatch") end
if b.args[1] ~= "--refresh-account" or b.args[2] ~= "codex/main" then error("Codex fallback dispatch mismatch") end
if c.args[1] ~= "--refresh-account" or c.args[2] ~= "gemini/main" then error("Gemini fallback dispatch mismatch") end
if a.environment.CLAUDEB_WARM_USER_EXPLICIT ~= "true"
    or b.environment.CLAUDEB_WARM_USER_EXPLICIT ~= "true"
    or c.environment.CLAUDEB_WARM_USER_EXPLICIT ~= "true" then
  error("Hard refresh did not carry the user-explicit warm signal")
end
local globalState = { starts = {}, alerts = {} }
local global = loadModule({ schema = 1, vendors = {} }, globalState)
local globalMenu = global.menuItems()
for _, item in ipairs(globalMenu) do
  if title(item) == "Refresh" or title(item) == "Refresh + Start Windows" then item.fn() end
end
if #globalState.starts ~= 3 then error("global refresh actions did not start two collector tasks") end
if globalState.starts[1].environment.CLAUDEB_WARM_USER_EXPLICIT ~= nil then
  error("passive menu collect inherited the user-explicit warm signal")
end
for index = 2, 3 do
  if globalState.starts[index].environment.CLAUDEB_WARM_USER_EXPLICIT ~= "true" then
    error("global refresh action omitted the user-explicit warm signal")
  end
end
local guardState = { starts = {}, alerts = {} }
local guarded = loadModule({ schema = 1, vendors = {} }, guardState)
guarded.hardRefreshClaude("com")
guarded.hardRefreshClaude("com")
if #guardState.starts ~= 1 then error("duplicate hard refresh started another task") end
if #guardState.alerts ~= 0 then error("duplicate hard refresh emitted an alert") end
local openState = { starts = {}, alerts = {} }
local openGuard = loadModule({ schema = 1, vendors = {} }, openState)
openGuard.menuItems()
openGuard.menuItems()
if #openState.starts ~= 1 then error("running menu-open collector did not suppress the next open") end
openState.starts[1].running = false
openState.now = openState.now + 5
openGuard.menuItems()
if #openState.starts ~= 2 then error("exited menu-open collector blocked the next open") end
local ocNow = '"$opencode_now"'
local ocEvyoxqyReset = '"$opencode_evyoxqy_reset"'
local wallState = { starts = {}, alerts = {}, now = ocNow }
-- Rows llm-limits.sh computed this very run from a record bin/opencode-go wrote: the menu decides
-- nothing about them beyond how they look.
local wallFixture = { schema = 1, vendors = { opencode = realJsonDecode([==['"$opencode_rows"']==]) } }
local wallMenu = loadModule(wallFixture, wallState).menuItems()
local wallTitles = {}
for _, item in ipairs(wallMenu) do table.insert(wallTitles, title(item)) end
local wallText = table.concat(wallTitles, "\n")
if not wallText:find("OpenCode Go", 1, true) then error("OpenCode Go section missing") end
local openCodeAt
for index, text in ipairs(wallTitles) do
  if text == "OpenCode Go" then openCodeAt = index break end
end
-- An account is a name line plus the bucket rows indented under it, exactly like the vendors above.
-- The search starts at the section header because a menu separator renders as a bare "-", which is
-- also the name of the default OpenCode profile.
local function wallBlock(name)
  local block, collecting = {}, false
  for index = openCodeAt + 1, #wallTitles do
    local text = (wallTitles[index]:gsub("%s+$", ""))
    if collecting then
      if not text:match("^%s") then break end
      table.insert(block, text)
    elseif text == name or text:match("^" .. name:gsub("%W", "%%%0") .. "%s") then
      collecting = true
      table.insert(block, text)
    end
  end
  return table.concat(block, "\n")
end
local weekdays = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local function resetColumn(stamp)
  local text
  if stamp - ocNow >= 604800 then
    text = os.date("%b %d", stamp)
  elseif os.date("%Y-%m-%d", stamp) ~= os.date("%Y-%m-%d", ocNow) then
    text = weekdays[tonumber(os.date("%w", stamp)) + 1] .. os.date(" %H:%M", stamp)
  else
    text = os.date("%H:%M", stamp)
  end
  return string.format("%9s", text)
end
local expectedBlocks = {
  { "-", "-\n        ?   ▓▓▓▓▓        " .. resetColumn(ocNow + 86400) },
  -- Two windows walled at once are two rows, in window order rather than in record order;
  -- alt also carries an active legacy no-window record, which a named wall must silence.
  { "alt", "alt\n        5h  ▓▓▓▓▓        " .. resetColumn(ocNow + 4 * 3600)
    .. "\n        wk  ▓▓▓▓▓        " .. resetColumn(ocNow + 2 * 86400) },
  -- The only thing that opens a walled account: a completion the plan served after the refusal.
  -- The age is that same served call — the wall is older and says nothing about being alive.
  { "clear", "clear  30m\n            ░░░░░" },
  -- The only other thing the Go plan tells an unwalled account about itself is when it was served.
  { "served", "served  1h\n            ░░░░░" },
  -- The collector takes the recorded reset as its writer capped it, however far out it reaches.
  { "far", "far\n        mo  ▓▓▓▓▓        " .. resetColumn(ocNow + 19 * 86400) },
  -- Written by bin/opencode-go itself, from a 429 the stubbed gateway answered this run.
  { "evyoxqy", "evyoxqy\n        wk  ▓▓▓▓▓        " .. resetColumn(ocEvyoxqyReset) },
  -- The gateway dates its resets to the day, so a horizon an hour past retires nothing: the wall
  -- still stands, it prints the horizon as recorded, and an account that only ever refused has no age.
  { "fresh", "fresh\n        wk  ▓▓▓▓▓        " .. resetColumn(ocNow - 3600) },
  -- A refusal in the very second of the served stamp: the tie keeps the wall standing.
  { "tied", "tied  15m\n        wk  ▓▓▓▓▓        " .. resetColumn(ocNow + 86400) },
}
for _, case in ipairs(expectedBlocks) do
  local rendered = wallBlock(case[1])
  if rendered ~= case[2] then
    error("OpenCode block " .. case[1] .. " rendered [" .. rendered .. "] not [" .. case[2] .. "]")
  end
end
for _, case in ipairs(expectedBlocks) do
  if wallBlock(case[1]):find("%%") then
    error("OpenCode rows printed a usage percentage nobody measured: " .. wallText)
  end
end
-- Refreshing this leg means sending real completions, so it is ONE action for the whole leg in the
-- section header, and which accounts it spends on is read out of the rows by opencode-go, not by a click.
local function openCodeRow(name)
  for index = openCodeAt + 1, #wallMenu do
    local text = title(wallMenu[index])
    if text == name or text:match("^" .. name:gsub("%W", "%%%0") .. "%s") then
      return wallMenu[index]
    end
  end
end
for _, name in ipairs({ "evyoxqy", "served", "-" }) do
  local row = openCodeRow(name)
  if not row or row.menu ~= nil or row.disabled ~= true then
    error("OpenCode account " .. name .. " carries a per-account action")
  end
end
local legHeader = wallMenu[openCodeAt]
if type(legHeader.menu) ~= "table" or #legHeader.menu ~= 1
    or title(legHeader.menu[1]) ~= "Hard refresh" or type(legHeader.menu[1].fn) ~= "function" then
  error("the OpenCode section header does not carry one Hard refresh for the leg")
end
legHeader.menu[1].fn()
local wallCheck = wallState.starts[#wallState.starts]
if not wallCheck or wallCheck.command ~= "/fixture-home/.local/bin/opencode-go"
    or wallCheck.args[1] ~= "wall-check" or wallCheck.args[2] ~= "--all" or #wallCheck.args ~= 2 then
  error("the leg refresh did not launch opencode-go wall-check --all")
end
if wallCheck.environment.OPENCODE_GO_PROFILE ~= nil then
  error("the leg refresh named a single profile")
end
-- One profile failing must not hide what the same run retired on the others: a leg-wide
-- refresh recollects even on a nonzero exit, so the rows follow what was recorded.
wallCheck.running = false
local startsBefore = #wallState.starts
wallCheck.callback(1, "", "one profile answered nothing")
local recollect = wallState.starts[#wallState.starts]
if #wallState.starts ~= startsBefore + 1
    or recollect.command ~= "/Volumes/Work/Projects/llm-legs/llm-limits.sh" then
  error("a failed leg refresh did not recollect")
end
return "OK open-guard running=1->1 exited=1->2"
' 2>/dev/null) || fail "isolated Hammerspoon contract checks threw"
  [ "$output" = "OK open-guard running=1->1 exited=1->2" ] \
    || fail "isolated Hammerspoon contract checks: $output"
}

# 1. hs CLI reachable and Hammerspoon responding.
[ "$(hs -c 'return "ok"' 2>/dev/null)" = "ok" ] || fail "Hammerspoon not responding to hs -c"
pass "hs CLI reachable, Hammerspoon responding"
assert_isolated_menu_contracts
pass "isolated menu contracts: open-collect guard running 1->1, exited 1->2; completion re-rendered"
if [ "${LLM_LIMITS_E2E_ISOLATED_ONLY:-0}" = 1 ]; then
  pass "e2e isolated-only mode: live singleton and stores skipped"
  exit 0
fi
# 2. Live module loaded and its data-read path (menuItems -> readLlmLimits) works.
MENU_TXT=$(hs_menu)
if grep -q '5h' <<<"$MENU_TXT"; then
  pass "live llm-limits module loaded; read path returned parsed data"
elif grep -q 'no data — press Refresh' <<<"$MENU_TXT"; then
  reason=$(grep -v 'no data — press Refresh' <<<"$MENU_TXT" | grep -m1 . || true)
  pass "live module loaded; read path reported a specific no-data reason: ${reason:-<none shown>}"
else
  fail "live read path returned neither parsed data nor a specific reason: $(head -3 <<<"$MENU_TXT" | tr '\n' '|')"
fi

if [ "${LLM_LIMITS_E2E_FIXTURE_ONLY:-0}" = 1 ]; then
  pass "e2e fixture-only mode: collector, cache, and refresh paths skipped"
  exit 0
fi

# 3. Menu construction: per-account ages, per-account hard refresh, no aggregate age line.
JSON=$(llm-limits 2>/dev/null) || fail "bare llm-limits failed"
AVAIL=$(jq -r '.vendors | to_entries[] | select(.value.available == true) | .key' <<<"$JSON")
[ -n "$AVAIL" ] || fail "no available vendor in store; cannot assert menu rows"
# A refresh-failure row legitimately joins cause and age with the same separator, so it is
# excluded rather than widening the ban to any middot.
grep -v 'refresh failed' <<<"$MENU_TXT" | grep -q ' · ' \
  && fail "banned aggregate vendor age line is still present"
grep -q '5h' <<<"$MENU_TXT" || fail "menu has no five-hour vendor rows"
grep -Fxq 'Refresh' <<<"$MENU_TXT" || fail "menu missing 'Refresh' action item"
grep -Fxq 'Refresh + Start Windows' <<<"$MENU_TXT" || fail "menu missing 'Refresh + Start Windows' action item"
assert_codex_account_rows "$MENU_TXT" "$JSON"
# Same-generation pair for age comparison: MENU_TXT predates the fresh collection
# above, so its ages lag the store whenever data moved in between (live flake).
STORE_NOW=$(cat "$STORE") || fail "cannot read store for age check"
MENU_NOW=$(hs_menu)
assert_account_ages "$MENU_NOW" "$STORE_NOW"
if jq -e '.vendors.claude.accounts[]? | select(.account == "alona") |
    .five_hour.expired == true and .five_hour.stale == false' <<<"$JSON" >/dev/null; then
  alona_style=$(hs_alona_five_style)
  [[ "$alona_style" == $'DIM\t'* ]] || fail "alona expired stale=false five-hour row is not dimmed: $alona_style"
fi
ancient_count=0
while IFS= read -r reset; do
  [ -n "$reset" ] || continue
  reset_epoch=$(iso2epoch "$reset") || fail "cannot parse live reset timestamp: $reset"
  [ "$reset_epoch" -ge "$(($(date +%s) - 86400))" ] || ancient_count=$((ancient_count + 1))
# A login-needed account (auth_needed, or a non-ok auth.status) renders a unified
# login row with no 5h line at all, so its reset can never produce a dash row.
done < <(jq -r 'def loginish: (.auth_needed == true) or ((.auth.status? | type) == "string" and .auth.status != "ok");
  .vendors[] | if ((.accounts? // []) | length) > 0 then
  (.accounts[]? | select(loginish | not) | .five_hour.resets_at?)
  else (select(loginish | not) | .five_hour.resets_at?) end | select(. != null)' <<<"$JSON")
if [ "$ancient_count" -gt 0 ]; then
  dash_count=$(grep -Ec '5h .* -$' <<<"$MENU_TXT")
  [ "$dash_count" -ge "$ancient_count" ] \
    || fail "live menu has $ancient_count ancient five-hour reset(s) but only $dash_count dash row(s)"
fi
claude_hard=$(jq 'if .vendors.claude.source == "claudeb-store" then (.vendors.claude.accounts | length) else 0 end' <<<"$JSON")
codex_hard=$(jq 'if .vendors.codex.available == true then (.vendors.codex.accounts | length) else 0 end' <<<"$JSON")
gemini_hard=$(jq 'if (.vendors.gemini.accounts | type) == "array" and
    (.vendors.gemini.accounts | length) > 1
  then [.vendors.gemini.accounts[] | select(.removed != true)] | length else 1 end' <<<"$JSON")
hard_count=$(grep -Fxc '  Hard refresh' <<<"$MENU_TXT")
[ "$hard_count" -eq "$((claude_hard + codex_hard + gemini_hard))" ] \
  || fail "Hard refresh submenu count mismatch: expected $((claude_hard + codex_hard + gemini_hard)), got $hard_count"
pass "menu build: per-account ages and Hard refresh present; aggregate vendor age line absent"

# 4. CLI surface: --table exits 0 with rows; bare output is valid JSON with schema fields.
TABLE=$(llm-limits --table 2>/dev/null) || fail "llm-limits --table exited non-zero"
grep -qE '^claude/[^ ]+ ' <<<"$TABLE" || fail "--table has no claude account rows"
grep -qE '^codex(/| |$)' <<<"$TABLE" || fail "--table missing codex row"
grep -qE '^gemini(/| |$)' <<<"$TABLE" || fail "--table missing gemini row"
jq -e '.schema == 1 and (.vendors.claude.accounts | type == "array")
  and (.vendors.claude.accounts[0].five_hour | has("as_of"))
  and (.vendors.codex | has("five_hour")) and (.vendors.gemini | has("five_hour"))' \
  <<<"$JSON" >/dev/null || fail "bare llm-limits JSON is missing schema/vendor fields"
pass "CLI surface: --table rows for claude/codex/gemini, bare JSON schema fields present"

# 5. Consistency: claudeb status cells must equal the canonical rendering of the store —
# the shared limits-view defs applied to the merged cache (shared-invariants row y). Any
# surface re-deriving its own pct/marker semantics diverges from this text and fails here.
# --refresh re-syncs the store; claudeb status --cached reads the same underlying
# snapshots without re-probing. A concurrent refresh (or a bucket crossing a staleness /
# expiry boundary between the two reads) can shift a cell, so a mismatch retries on a
# fresh sync; a persistent disagreement fails loudly.
E2E_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$E2E_ROOT/share/limits-view.sh"
consistency_attempt() {
  local json status hasfab a row expected cells
  timeout 120 llm-limits --refresh >/dev/null 2>&1 || { MISMATCH="refresh exited non-zero"; return 1; }
  json=$(cat "$STORE") || { MISMATCH="cannot read $STORE"; return 1; }
  status=$(claudeb status --cached --plain 2>/dev/null) || { MISMATCH="claudeb status --cached failed"; return 1; }
  hasfab=$(grep -q 'FABLE' <<<"$status" && echo 1 || echo 0)
  for a in $(jq -r '.vendors.claude.accounts[].account' <<<"$json"); do
    row=$(awk -v n="$a" '$1 == n {print; exit}' <<<"$status")
    [ -n "$row" ] || { MISMATCH="account $a in store but absent from claudeb status"; return 1; }
    # Staleness is recomputed at now from the numeric as_of so both sides share the
    # same clock; the expired flag and effective value come from the collector's mark.
    expected=$(jq -r --arg a "$a" --argjson now "$(date +%s)" \
      --argjson thr5 "$LIMITS_STALE_FIVE_HOUR" --argjson thrw "$LIMITS_STALE_WEEKLY" \
      --argjson thrf "$LIMITS_STALE_FABLE" "$LIMITS_VIEW_JQ"'
      .vendors.claude.accounts[] | select(.account == $a) |
      ((.auth.status? // "") == "expired") as $ax |
      def cell($b; $thr):
        (if ($b | type) == "object" then $b else {} end) as $b |
        limits_pct_text($b.effective_pct;
          limits_bucket_stale($now; $thr; $ax; ($b.origin // ""); ($b.as_of // 0));
          ($b.expired == true));
      [cell(.five_hour; $thr5), cell(.weekly; $thrw), cell(.fable; $thrf)] | join(" ")' <<<"$json")
    if [ "$hasfab" = 1 ]; then
      cells=$(awk -v n="$a" '$1 == n {print $2, $3, $4; exit}' <<<"$status")
    else
      cells=$(awk -v n="$a" '$1 == n {print $2, $3; exit}' <<<"$status")
      expected=${expected% *}
    fi
    [ "$cells" = "$expected" ] || { MISMATCH="$a cells: canonical='$expected' claudeb='$cells'"; return 1; }
  done
  return 0
}
MISMATCH=""
consistency_ok=0
for attempt in 1 2 3; do
  if consistency_attempt; then consistency_ok=1; break; fi
done
[ "$consistency_ok" = 1 ] || fail "claudeb status disagrees with the canonical store rendering after 3 syncs ($MISMATCH)"
pass "store consistency: claudeb status cells equal the shared limits-view rendering of ~/.llm-limits.json for all claude accounts"

# 6. Free refresh round-trip: fetched_at must advance, no vendor may fail invisibly, and
# the live module must re-read the new store. A vendor that neither advanced its as_of nor
# exposed a refresh_error would be a SILENT failure -> test failure.
BEFORE=$(cat "$STORE") || fail "cannot read store before refresh"
before_fetched=$(jq -r '.fetched_at' <<<"$BEFORE")
before_epoch=$(iso2epoch "$before_fetched")
declare -A before_err before_asof
for v in claude codex gemini; do
  before_err[$v]=$(jq -r --arg v "$v" '.vendors[$v].refresh_error.cause // ""' <<<"$BEFORE")
  before_asof[$v]=$(jq -r --arg v "$v" '.vendors[$v].as_of // ""' <<<"$BEFORE")
done

timeout 120 llm-limits --refresh >/dev/null 2>&1 || fail "llm-limits --refresh exited non-zero"

AFTER=$(cat "$STORE") || fail "cannot read store after refresh"
after_fetched=$(jq -r '.fetched_at' <<<"$AFTER")
after_epoch=$(iso2epoch "$after_fetched")
[ "$after_epoch" -ge "$before_epoch" ] \
  || fail "fetched_at went backwards ($before_fetched -> $after_fetched)"

visible_failures=""
for v in claude codex gemini; do
  present=$(jq -r --arg v "$v" 'has("vendors") and (.vendors | has($v))' <<<"$AFTER")
  [ "$present" = true ] || continue
  aerr=$(jq -r --arg v "$v" '.vendors[$v].refresh_error.cause // ""' <<<"$AFTER")
  aasof=$(jq -r --arg v "$v" '.vendors[$v].as_of // ""' <<<"$AFTER")
  advanced=0
  if [ -n "$aasof" ] && [ -n "${before_asof[$v]}" ]; then
    aep=$(iso2epoch "$aasof"); bep=$(iso2epoch "${before_asof[$v]}")
    [ "$aep" -ge "$bep" ] && advanced=1
  fi
  if [ "$advanced" != 1 ] && [ -z "$aerr" ]; then
    fail "vendor $v neither advanced its as_of nor exposed a refresh_error (silent failure)"
  fi
  [ -n "$aerr" ] && visible_failures="$visible_failures $v:$aerr"
done

MENU2=$(hs_menu)
assert_codex_account_rows "$MENU2" "$AFTER"
assert_account_ages "$MENU2" "$AFTER"
grep -v 'refresh failed' <<<"$MENU2" | grep -q ' · ' \
  && fail "aggregate vendor age line reappeared after refresh"
if [ -n "$visible_failures" ]; then
  pass "free refresh: fetched_at advanced, no invisible failures; visible refresh_error(s):$visible_failures"
else
  pass "free refresh: fetched_at advanced, all vendors refreshed with no failures"
fi

echo "PASS: e2e surfaces (hs live module, menu build, CLI table, store consistency, visible refresh outcome)"
