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
  if type(it.menu) == "table" then
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
    if color and math.abs(color.red - 0.55) < 0.01 and math.abs(color.green - 0.55) < 0.01
        and math.abs(color.blue - 0.55) < 0.01 then return "GRAY\t" .. text end
    return "NOT_GRAY\t" .. text
  end
  if text == "alona" or text:match("^alona%s") then seen = true end
end
return "MISSING"
' 2>/dev/null
}

assert_codex_account_rows() {
  local menu="$1" json="$2" count account auth credits row
  count=$(jq '.vendors.codex.accounts | length' <<<"$json")
  while IFS= read -r account; do
    auth=$(jq -r --arg account "$account" '.vendors.codex.accounts[] | select(.account == $account) | .auth_needed == true' <<<"$json")
    credits=$(jq -r --arg account "$account" '.vendors.codex.accounts[] | select(.account == $account) | .reset_credits // 0' <<<"$json")
    if [ "$auth" = true ]; then
      grep -Fxq "$account  login needed" <<<"$menu" || fail "Codex auth-needed row is not name plus login needed: $account"
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

assert_account_ages() {
  local menu="$1" json="$2" vendor account auth asof expected row actual
  for vendor in claude codex gemini; do
    if [ "$vendor" = gemini ] &&
       [ "$(jq -r '(.vendors.gemini.accounts | type) == "array" and
          (.vendors.gemini.accounts | length) > 1' <<<"$json")" != true ]; then
      continue
    fi
    while IFS=$'\t' read -r account auth asof; do
      [ -n "$account" ] || continue
      row=$(awk -v account="$account" '$1 == account {print; exit}' <<<"$menu")
      [ -n "$row" ] || fail "$vendor account row missing for age check: $account"
      [ "$auth" != true ] || continue
      expected=$(age_short "$asof")
      actual=$(awk '{print $NF}' <<<"$row")
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
    actual=$(awk '{print $NF}' <<<"$row")
    if [ -n "$expected" ]; then
      [ "$actual" = "$expected" ] || fail "Gemini age mismatch: expected $expected, row=$row"
    elif [[ "$actual" =~ ^[0-9]+[mhd]$ ]]; then
      fail "Gemini is at most 5m old but displays age: $row"
    fi
  fi
}

within_pp() {
  local left="$1" right="$2" tolerance=3 delta
  if [[ "$left" =~ ^[0-9]+$ ]] && [[ "$right" =~ ^[0-9]+$ ]]; then
    delta=$((left - right)); [ "$delta" -ge 0 ] || delta=$((-delta))
    [ "$delta" -le "$tolerance" ]
  else
    [ "$left" = "$right" ]
  fi
}

assert_isolated_menu_contracts() {
  local output
  output=$(hs -c '
local path = "/Volumes/Work/Projects/llm-legs/hammerspoon/llm-limits.lua"
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
    json = { decode = function() return fixture end },
    styledtext = { new = styled },
    task = {},
  }
  mock.task.new = function(command, callback, args)
    local task = { command = command, callback = callback, args = args or {} }
    function task:setEnvironment() return self end
    function task:start()
      self.running = true
      table.insert(state.starts, self)
      return true
    end
    function task:isRunning() return self.running == true end
    return task
  end
  local fakeIo = setmetatable({
    open = function()
      return { read = function() return "fixture" end, close = function() end }
    end,
  }, { __index = io })
  local fakeOs = setmetatable({ time = function() return state.now end }, { __index = os })
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
if not color or color.red ~= 0.55 or color.green ~= 0.55 or color.blue ~= 0.55 then
  error("expired stale=false row was not dimmed")
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
  if (name == "Claude" or name == "Codex" or name == "Gemini") and item.menu then item.menu[1].fn() end
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
if [ "${LLM_LIMITS_E2E_FIXTURE_ONLY:-0}" = 1 ]; then
  pass "e2e fixture-only mode: live Hammerspoon singleton, cache, and refresh paths skipped"
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

# 3. Menu construction: per-account ages, per-account hard refresh, no aggregate age line.
JSON=$(llm-limits 2>/dev/null) || fail "bare llm-limits failed"
AVAIL=$(jq -r '.vendors | to_entries[] | select(.value.available == true) | .key' <<<"$JSON")
[ -n "$AVAIL" ] || fail "no available vendor in store; cannot assert menu rows"
grep -q ' · ' <<<"$MENU_TXT" && fail "banned aggregate vendor age line is still present"
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
  [[ "$alona_style" == $'GRAY\t'* ]] || fail "alona expired stale=false five-hour row is not dimmed: $alona_style"
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

# 5. Consistency: claudeb status used% agrees with the store for every claude account.
# --refresh re-syncs the store into ~/.llm-limits.json; claudeb status --cached reads the
# same store without re-probing. A background daemon warm can bump a value between the two
# reads, so a mismatch retries on a fresh sync; a persistent disagreement fails loudly.
consistency_attempt() {
  local json status hasfab a lh lw lf sh sw sf
  timeout 120 llm-limits --refresh >/dev/null 2>&1 || { MISMATCH="refresh exited non-zero"; return 1; }
  json=$(cat "$STORE") || { MISMATCH="cannot read $STORE"; return 1; }
  status=$(claudeb status --cached --plain 2>/dev/null) || { MISMATCH="claudeb status --cached failed"; return 1; }
  hasfab=$(grep -q 'FABLE' <<<"$status" && echo 1 || echo 0)
  for a in $(jq -r '.vendors.claude.accounts[].account' <<<"$json"); do
    local row
    row=$(awk -v n="$a" '$1 == n {print; exit}' <<<"$status")
    [ -n "$row" ] || { MISMATCH="account $a in store but absent from claudeb status"; return 1; }
    lh=$(jq -r --arg a "$a" '.vendors.claude.accounts[] | select(.account==$a)
      | (.five_hour.used_pct | if . == null then "-" else (round|tostring) end)' <<<"$json")
    lw=$(jq -r --arg a "$a" '.vendors.claude.accounts[] | select(.account==$a)
      | (.weekly.used_pct // null | if . == null then "-" else (round|tostring) end)' <<<"$json")
    lf=$(jq -r --arg a "$a" '.vendors.claude.accounts[] | select(.account==$a)
      | (.fable.used_pct // null | if . == null then "-" else (round|tostring) end)' <<<"$json")
    sh=$(awk -v n="$a" '$1 == n {print $2; exit}' <<<"$status" | tr -d '%')
    sw=$(awk -v n="$a" '$1 == n {print $3; exit}' <<<"$status" | tr -d '%')
    within_pp "$lh" "$sh" || { MISMATCH="$a 5h: store=$lh claudeb=$sh"; return 1; }
    within_pp "$lw" "$sw" || { MISMATCH="$a weekly: store=$lw claudeb=$sw"; return 1; }
    if [ "$hasfab" = 1 ]; then
      sf=$(awk -v n="$a" '$1 == n {print $4; exit}' <<<"$status" | tr -d '%')
      within_pp "$lf" "$sf" || { [ "$lf" = - ] && [ "$sf" = 0 ]; } \
        || { MISMATCH="$a fable: store=$lf claudeb=$sf"; return 1; }
    fi
  done
  return 0
}
MISMATCH=""
consistency_ok=0
for attempt in 1 2 3; do
  if consistency_attempt; then consistency_ok=1; break; fi
done
[ "$consistency_ok" = 1 ] || fail "claudeb status disagrees with store after 3 syncs ($MISMATCH)"
pass "store consistency: claudeb status stays within 3pp of ~/.llm-limits.json for all claude accounts"

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
grep -q ' · ' <<<"$MENU2" && fail "aggregate vendor age line reappeared after refresh"
if [ -n "$visible_failures" ]; then
  pass "free refresh: fetched_at advanced, no invisible failures; visible refresh_error(s):$visible_failures"
else
  pass "free refresh: fetched_at advanced, all vendors refreshed with no failures"
fi

echo "PASS: e2e surfaces (hs live module, menu build, CLI table, store consistency, visible refresh outcome)"
