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
  python3 -c 'import sys,datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$1"
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

# 1. hs CLI reachable and Hammerspoon responding.
[ "$(hs -c 'return "ok"' 2>/dev/null)" = "ok" ] || fail "Hammerspoon not responding to hs -c"
pass "hs CLI reachable, Hammerspoon responding"

# 2. Live module loaded and its data-read path (menuItems -> readLlmLimits) works.
MENU_TXT=$(hs_menu)
if grep -qE '(^| )(claude|codex|gemini) (now|[0-9]+[mhd])' <<<"$MENU_TXT"; then
  pass "live llm-limits module loaded; read path returned parsed data"
elif grep -q 'no data — press Refresh' <<<"$MENU_TXT"; then
  reason=$(grep -v 'no data — press Refresh' <<<"$MENU_TXT" | grep -m1 . || true)
  pass "live module loaded; read path reported a specific no-data reason: ${reason:-<none shown>}"
else
  fail "live read path returned neither parsed data nor a specific reason: $(head -3 <<<"$MENU_TXT" | tr '\n' '|')"
fi

# 3. Menu construction: a row per available vendor, the per-vendor age line, both actions.
JSON=$(llm-limits 2>/dev/null) || fail "bare llm-limits failed"
AVAIL=$(jq -r '.vendors | to_entries[] | select(.value.available == true) | .key' <<<"$JSON")
[ -n "$AVAIL" ] || fail "no available vendor in store; cannot assert menu rows"
for v in $AVAIL; do
  grep -qE "(^| )$v (now|[0-9]+[mhd])" <<<"$MENU_TXT" \
    || fail "menu age line missing available vendor: $v"
done
grep -q '5h' <<<"$MENU_TXT" || fail "menu has no five-hour vendor rows"
grep -Fxq 'Refresh' <<<"$MENU_TXT" || fail "menu missing 'Refresh' action item"
grep -Fxq 'Refresh + Start Windows' <<<"$MENU_TXT" || fail "menu missing 'Refresh + Start Windows' action item"
pass "menu build: rows for [$(tr '\n' ' ' <<<"$AVAIL")], age line, Refresh + Refresh + Start Windows"

# 4. CLI surface: --table exits 0 with rows; bare output is valid JSON with schema fields.
TABLE=$(llm-limits --table 2>/dev/null) || fail "llm-limits --table exited non-zero"
grep -qE '^claude/[^ ]+ ' <<<"$TABLE" || fail "--table has no claude account rows"
grep -qE '^codex(/| |$)' <<<"$TABLE" || fail "--table missing codex row"
grep -qE '^gemini( |$)' <<<"$TABLE" || fail "--table missing gemini row"
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
    [ "$lh" = "$sh" ] || { MISMATCH="$a 5h: store=$lh claudeb=$sh"; return 1; }
    [ "$lw" = "$sw" ] || { MISMATCH="$a weekly: store=$lw claudeb=$sw"; return 1; }
    if [ "$hasfab" = 1 ]; then
      sf=$(awk -v n="$a" '$1 == n {print $4; exit}' <<<"$status" | tr -d '%')
      [ "$lf" = "$sf" ] || { MISMATCH="$a fable: store=$lf claudeb=$sf"; return 1; }
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
pass "store consistency: claudeb status used% matches ~/.llm-limits.json for all claude accounts"

# 6. Free refresh round-trip: fetched_at must advance, no vendor may fail invisibly, and
# the live module must re-read the new store. A vendor that neither advanced its as_of nor
# exposed a refresh_error would be a SILENT failure -> test failure.
BEFORE=$(cat "$STORE") || fail "cannot read store before refresh"
before_fetched=$(jq -r '.fetched_at' <<<"$BEFORE")
before_epoch=$(iso2epoch "$before_fetched")
declare -A before_err before_asof
for v in claude codex gemini; do
  before_err[$v]=$(jq -r --arg v "$v" '.vendors[$v].refresh_error // ""' <<<"$BEFORE")
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
  aerr=$(jq -r --arg v "$v" '.vendors[$v].refresh_error // ""' <<<"$AFTER")
  aasof=$(jq -r --arg v "$v" '.vendors[$v].as_of // ""' <<<"$AFTER")
  if [ -n "$aerr" ] && [ -z "${before_err[$v]}" ]; then
    fail "vendor $v gained a new refresh_error not present before: $aerr"
  fi
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
grep -qE '(^| )claude (now|[0-9]+m)' <<<"$MENU2" \
  || fail "live module did not reflect the fresh refresh (claude age not recent in rebuilt menu)"
if [ -n "$visible_failures" ]; then
  pass "free refresh: fetched_at advanced, no invisible failures; visible refresh_error(s):$visible_failures"
else
  pass "free refresh: fetched_at advanced, all vendors refreshed with no failures"
fi

echo "PASS: e2e surfaces (hs live module, menu build, CLI table, store consistency, visible refresh outcome)"
