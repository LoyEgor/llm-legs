#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/llm_limits_harness.sh" || exit 1
. "$ROOT/tests/lib/hs-bounded.sh"
unset CLAUDE_CONFIG_DIR CLAUDE_LIMITS_ACCOUNT CLAUDEGPT_ACCOUNT
export HOME="$HOME_FIXTURE" CLAUDEB_DIR="$WORK/claudeb"
export LLM_LIMITS_FILE="$CACHE" LLM_LIMITS_CACHE="$CACHE"
export STATUSLINE_CACHE_DIR="$WORK/statusline" STATUSLINE_PS=true STATUSLINE_LSOF=true
export STATUSLINE_STORE_MERGE_CMD=/usr/bin/true STATUSLINE_CODEX_REFRESH_CMD=/usr/bin/true
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
. "$ROOT/share/worker-walls.sh"
. "$ROOT/share/limits-view.sh"
mkdir -p "$CLAUDEB_DIR" "$HOME/.codex-profiles/main"
bash "$SCRIPT" --json >/dev/null || fail 'baseline collection'
failures=0 checks=0
check() {
  checks=$((checks + 1))
  if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); fi
}
absent() { [ "${2#*"$1"}" = "$2" ]; }
present() { ! absent "$@"; }
reset=$((now + 1800))
label=$(date -r "$reset" +%H:%M)
at=$((now + 5))
menu_cases="$WORK/menu-cases.lua"
printf 'return {\n' >"$menu_cases"

# Every surface for one account: statusline, worker-pick, llm-limits JSON/table/plain, and the menu
# (collected here, rendered in one Hammerspoon call at the end).
# A wall paints its window row (5h|wk) at 100 % with the shown reset ($5; empty: none known) and
# never prints $7, a guessed time; the table/plain STATUS re-collects, so it takes its own label $6.
surfaces() { # name vendor walled [window shown-label status-label guess-label]
  local name=$1 vendor=$2 walled=$3 window=${4:-} shown=${5-$label} status_label=${6-${5-$label}} guess=${7:-}
  local status picked rendered format line2
  picked=$(WORKER_PICK_NOW="$now" bash "$ROOT/bin/worker-pick" 2>/dev/null | grep "^$vendor:")
  if [ "$vendor" = codex ]; then
    status=$(printf '%s' '{"model":{"display_name":"GPT"},"context_window":{"used_percentage":1}}' |
      CLAUDEGPT_ACCOUNT=main STATUSLINE_NOW="$now" COLUMNS= bash "$ROOT/bin/statusline.sh")
  else
    status=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":1}}' |
      STATUSLINE_NOW="$now" COLUMNS= bash "$ROOT/bin/statusline.sh")
  fi
  line2=$(sed -n '2p' <<<"$status" | sed $'s/\033\[[0-9;]*m//g')
  check absent walled "$status"
  if [ "$walled" = true ]; then
    check present "$window 100%" "$line2"
    if [ "$window" = 5h ] && [ -n "$shown" ]; then check present "5h 100% $shown" "$line2"
    elif [ "$window" = 5h ]; then check grep -Eq '5h 100% (│|$)' <<<"$line2"; fi
    check present WALLED "$picked"
    if [ -n "$shown" ]; then check present "↺ $shown" "$picked"; else check absent "↺" "$picked"; fi
  else
    check absent WALLED "$picked"
  fi
  if [ -n "$guess" ]; then
    check absent "$guess" "$line2"
    check absent "$guess" "$picked"
  fi
  for format in json table plain; do
    rendered=$(bash "$SCRIPT" --"$format" --no-write) || fail "$name: render $format"
    [ "$format" = json ] || rendered=$(grep "^$vendor" <<<"$rendered")
    if [ "$format" = json ]; then
      check jq -e --arg v "$vendor" --argjson walled "$walled" --argjson now "$now" \
        '(.vendors[$v].accounts[0].worker_wall | . != null and .resets_at > $now) == $walled' <<<"$rendered" >/dev/null
    elif [ "$walled" = true ]; then
      check present "walled→$status_label" "$rendered"
      check present "100%" "$rendered"
      [ -z "$guess" ] || check absent "$guess" "$rendered"
    else
      check absent walled→ "$rendered"
    fi
  done
  # Epoch resets: the renderer harness pins os.time, which turns every ISO time it parses into now.
  lua_str() { if [ -n "$1" ]; then printf '"%s"' "$1"; else printf nil; fi; }
  printf '{name="%s",account="main",now=%s,walled=%s,window=%s,label=%s,guess=%s,store=hs.json.decode([==[%s]==])},\n' \
    "$name" "$now" "$walled" "$(lua_str "$window")" "$(lua_str "$shown")" "$(lua_str "$guess")" \
    "$(jq -c --arg v "$vendor" "$LIMITS_VIEW_JQ"'
      def epochs: (.five_hour, .weekly) |= (if type == "object" then .resets_at |= limits_store_epoch else . end);
      .vendors |= {($v): .[$v]} | .vendors[$v] |= (epochs | .accounts[]? |= epochs)' \
      "$CACHE")" >>"$menu_cases"
}
numbers() {
  check jq -e '.vendors.codex.accounts[0] | .five_hour.used_pct == 74 and .weekly.used_pct == 31' "$CACHE" >/dev/null
  check jq -e '.vendors.claude.accounts[0] | .five_hour.used_pct == 12 and .weekly.used_pct == 40' "$CACHE" >/dev/null
}

surfaces codex-none codex false
surfaces claude-none claude false

# The write: onto the existing row (and the vendor block it is current on), numbers untouched.
worker_walls_record codex main "$reset" "$at" || fail 'record codex wall'
worker_walls_record claudeb main "$reset" "$at" || fail 'record claude wall'
check jq -e --argjson r "$reset" --argjson at "$at" '.vendors.codex |
  .accounts[0].worker_wall == {resets_at:$r,recorded_at:$at} and .worker_wall == .accounts[0].worker_wall' "$CACHE" >/dev/null
numbers
# The vendor time paints the window whose own reset is nearest it: codex wk (+2000 s against 5h's
# +1000 s), claude 5h (+2400 s against wk's +8400 s).
surfaces codex-walled codex true wk
surfaces claude-walled claude true 5h

# An older record never replaces a newer one; an account the store does not list gets no row.
before=$(cat "$CACHE")
worker_walls_record codex main "$((reset + 600))" "$((at - 1))" || fail 'older record'
worker_walls_record codex ghost "$reset" "$at" || fail 'unknown account record'
check test "$(cat "$CACHE")" = "$before"

# The collector carries a standing wall across its refresh.
bash "$SCRIPT" --json >/dev/null || fail 'collection with wall'
check jq -e '.vendors.codex.accounts[0].worker_wall != null and .vendors.claude.accounts[0].worker_wall != null' "$CACHE" >/dev/null
numbers
surfaces codex-carried codex true wk

# A real reading newer than the wall and open supersedes it everywhere, and the collector drops it.
jq --argjson t "$((at + 5))" '.vendors.codex.accounts |= map(.five_hour.as_of = $t | .weekly.as_of = $t)' \
  "$CACHE" >"$WORK/next" && mv "$WORK/next" "$CACHE"
surfaces codex-read codex false
bash "$SCRIPT" --json >/dev/null || fail 'collection after reading'
check jq -e '.vendors.codex.accounts[0] | has("worker_wall") | not' "$CACHE" >/dev/null

# A lapsed wall shows nowhere, and the collector drops it.
worker_walls_record claudeb main "$((now - 1))" "$((at + 1))" || fail 'record lapsed wall'
surfaces claude-lapsed claude false
bash "$SCRIPT" --json >/dev/null || fail 'collection after lapse'
check jq -e '.vendors.claude.accounts[0] | has("worker_wall") | not' "$CACHE" >/dev/null

# No vendor time (codex's `out of credits`): the parser invents none, and the record takes the
# most-used window's own future reset (codex 5h at 74 %) — no guess anywhere.
check test -z "$(worker_walls_parse_reset '')"
check test -z "$(worker_walls_parse_reset 'resets soon')"
at2=$((at + 20))
worker_walls_record codex main "" "$at2" || fail 'record timeless wall'
reset5=$(jq -r "$LIMITS_VIEW_JQ"'.vendors.codex.accounts[0].five_hour.resets_at | limits_store_epoch' "$CACHE")
check jq -e --argjson r "$reset5" --argjson at "$at2" \
  '.vendors.codex.accounts[0].worker_wall == {resets_at:$r,recorded_at:$at}' "$CACHE" >/dev/null
label5=$(date -r "$reset5" +%H:%M)
surfaces codex-timeless codex true 5h "$label5" "$label5" "$(date -r "$((at2 + 3600))" +%H:%M)"

# With no future reset known either, the record marks its retry time a guess, and no surface
# prints it: the store-read ones show the window at 100 % with no time; the re-collecting
# table/plain show the window's own reset the collection found.
jq '.vendors.codex.accounts[0] |= (.five_hour.resets_at = null | .weekly.resets_at = null)' \
  "$CACHE" >"$WORK/next" && mv "$WORK/next" "$CACHE"
at3=$((at + 30))
worker_walls_record codex main "" "$at3" || fail 'record guessed wall'
check jq -e --argjson at "$at3" \
  '.vendors.codex.accounts[0].worker_wall == {resets_at:($at + 3600),recorded_at:$at,guessed:true}' "$CACHE" >/dev/null
surfaces codex-guessed codex true 5h "" "$label5" "$(date -r "$((at3 + 3600))" +%H:%M)"

printf '}\n' >>"$menu_cases"
if command -v hs >/dev/null 2>&1 && [ "$(hs_bounded 3 -c 'return "ok"' 2>/dev/null)" = ok ]; then
  checks=$((checks + 1))
  menu_out=$(hs_bounded 600 -c "return assert(loadfile([[$ROOT/tests/llm_limits_renderer_harness.lua]]))([[$menu_cases]])" 2>&1)
  [ "$menu_out" = 'PASS: wall store menu' ] || { printf 'FAIL: menu: %s\n' "$menu_out" >&2; failures=$((failures + 1)); }
else
  echo "SKIP (hs unavailable): wall store menu"
fi
[ "$failures" -eq 0 ] || exit 1
printf 'PASS: %s wall-store assertions (store, menu, statusline, worker-pick, JSON/table/plain)\n' "$checks"
