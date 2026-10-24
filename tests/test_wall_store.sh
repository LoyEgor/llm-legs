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
reset_label() { # epoch -> llm-limits' reset text: HH:MM on today's date, else the weekday first
  if [ "$(date -r "$1" +%F)" = "$(date +%F)" ]; then date -r "$1" +%H:%M; else LC_ALL=C date -r "$1" '+%a %H:%M'; fi
}
at=$((now + 5))
menu_cases="$WORK/menu-cases.lua"
printf 'return {\n' >"$menu_cases"

# Every surface for one account: statusline, worker-pick, llm-limits JSON/table/plain, and the menu
# (collected here, rendered in one Hammerspoon call at the end).
# A wall paints its window row (5h|wk) at 100 % with the shown reset ($5; empty: none known) and
# never prints $7, a guessed time; the table/plain STATUS re-collects, so it takes its own reset $6.
# The statusline and the menu print HH:MM; worker-pick and the table put the weekday first off today's date.
surfaces() { # name vendor walled [window shown-epoch status-epoch guess-label]
  local name=$1 vendor=$2 walled=$3 window=${4:-} shown_at=${5-$reset} status_label guess=${7:-}
  local shown='' pick_shown='' status picked rendered format line2 pids=()
  status_label=$(reset_label "${6-$reset}")
  [ -z "$shown_at" ] || { shown=$(date -r "$shown_at" +%H:%M); pick_shown=$(reset_label "$shown_at"); }
  if [ "$vendor" = codex ]; then
    status=$(printf '%s' '{"model":{"display_name":"GPT"},"context_window":{"used_percentage":1}}' |
      CLAUDEGPT_ACCOUNT=main STATUSLINE_NOW="$now" COLUMNS= bash "$ROOT/bin/statusline.sh")
  else
    status=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":1}}' |
      STATUSLINE_NOW="$now" COLUMNS= bash "$ROOT/bin/statusline.sh")
  fi
  line2=$(sed -n '2p' <<<"$status" | sed $'s/\033\[[0-9;]*m//g')
  WORKER_PICK_NOW="$now" bash "$ROOT/bin/worker-pick" --all 2>/dev/null >"$WORK/render.pick" &
  pids[${#pids[@]}]=$!
  for format in json table plain; do
    bash "$SCRIPT" --"$format" --no-write >"$WORK/render.$format" &
    pids[${#pids[@]}]=$!
  done
  check absent walled "$status"
  wait "${pids[0]}"
  pids=("${pids[@]:1}")
  for format in json table plain; do
    wait "${pids[0]}" || fail "$name: render $format"
    pids=("${pids[@]:1}")
  done
  picked=$(grep "^$vendor:" "$WORK/render.pick")
  if [ "$walled" = true ]; then
    check present "$window 100%" "$line2"
    if [ "$window" = 5h ] && [ -n "$shown" ]; then check present "5h 100% $shown" "$line2"
    elif [ "$window" = 5h ]; then check grep -Eq '5h 100% (│|$)' <<<"$line2"; fi
    check present WALLED "$picked"
    if [ -n "$pick_shown" ]; then check present "↺ $pick_shown" "$picked"; else check absent "↺" "$picked"; fi
  else
    check absent WALLED "$picked"
  fi
  if [ -n "$guess" ]; then
    check absent "$guess" "$line2"
    check absent "$guess" "$picked"
  fi
  for format in json table plain; do
    rendered=$(<"$WORK/render.$format")
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
surfaces codex-timeless codex true 5h "$reset5" "$reset5" "$(date -r "$((at2 + 3600))" +%H:%M)"

# With no future reset known either, the record marks its retry time a guess, and no surface
# prints it: the store-read ones show the window at 100 % with no time; the re-collecting
# table/plain show the window's own reset the collection found.
jq '.vendors.codex.accounts[0] |= (.five_hour.resets_at = null | .weekly.resets_at = null)' \
  "$CACHE" >"$WORK/next" && mv "$WORK/next" "$CACHE"
at3=$((at + 30))
worker_walls_record codex main "" "$at3" || fail 'record guessed wall'
check jq -e --argjson at "$at3" \
  '.vendors.codex.accounts[0].worker_wall == {resets_at:($at + 3600),recorded_at:$at,guessed:true}' "$CACHE" >/dev/null
surfaces codex-guessed codex true 5h "" "$reset5" "$(date -r "$((at3 + 3600))" +%H:%M)"

# Codex walls with a bare clock time and a trailing dot; read as now+1h, worker-pick freed the
# account hours before its real reset.
wall_now=$(date +%s)
reset_2341=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%F) 23:41:00" +%s)
[ "$reset_2341" -gt "$((wall_now - 300))" ] || reset_2341=$(date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$(date +%F) 23:41:00" +%s)
for text in 'try again at 11:41 PM.' '11:41PM' '23:41'; do
  check test "$(WORKER_WALLS_NOW=$wall_now worker_walls_parse_reset "$text")" = "$reset_2341"
done
passed=$(( (wall_now - 3600) / 60 * 60 ))
rolled=$(worker_walls_parse_reset "$(date -r "$passed" +%H:%M)")
check test "$rolled" -gt "$wall_now"
check test "$(( rolled - passed ))" -ge 82800
check test "$(( rolled - passed ))" -le 90000
this_minute=$(worker_walls_parse_reset "try again at $(date -r "$(( wall_now / 60 * 60 ))" '+%I:%M %p')")
check test "$this_minute" -le "$wall_now"
check test "$(worker_walls_kind codex "$this_minute")" = unknown

# Real wall wordings read as their reset, never now+1h: claude's zone suffix, comma and bare hour,
# codex's dated retry behind a transcript's `git reset --hard`, gemini's compound duration, ISO UTC.
wall_reset() { printf '%b\n' "$1" >"$WORK/wall.out"; WORKER_WALLS_NOW=$wall_now worker_walls_parse_reset "$(worker_walls_extract_reset "$WORK/wall.out")"; }
at() { date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
tomorrow=$(date -j -v+1d +%Y-%m-%d)
kiev_2240=$(TZ=Europe/Kiev date -j -f '%Y-%m-%d %H:%M:%S' "$(TZ=Europe/Kiev date +%F) 22:40:00" +%s)
[ "$kiev_2240" -gt "$((wall_now - 300))" ] ||
  kiev_2240=$(TZ=Europe/Kiev date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$(TZ=Europe/Kiev date +%F) 22:40:00" +%s)
check test "$(wall_reset '{"result":"You'\''ve hit your session limit · resets 10:40pm (Europe/Kiev)","is_error":true}')" = "$kiev_2240"
check test "$(wall_reset "You've hit your weekly limit · resets $(date -j -v+1d '+%b %e' | tr -s ' '), 9am")" = "$(at "$tomorrow 09:00:00")"
check test "$(wall_reset "\"result\":\"You've hit your weekly limit · resets $(date -j -v+1d '+%b %e' | tr -s ' ') at 10pm (Europe/Kiev)\"")" = \
  "$(TZ=Europe/Kiev date -j -f '%Y-%m-%d %H:%M:%S' "$(TZ=Europe/Kiev date -j -v+1d +%F) 22:00:00" +%s)"
three_pm=$(at "$(date +%F) 15:00:00")
[ "$three_pm" -gt "$((wall_now - 300))" ] || three_pm=$(at "$tomorrow 15:00:00")
check test "$(wall_reset 'resets 3pm')" = "$three_pm"
check test "$(wall_reset "run \`git reset --hard\` first\nor try again at $(date -j -v+2d '+%b %eth, %Y 3:52 AM' | tr -s ' ').")" = \
  "$(at "$(date -j -v+2d +%F) 03:52:00")"
gemini=$(wall_reset 'Individual quota reached. Resets in 1h40m8s.')
check test "$(( gemini - wall_now ))" -ge 6008
check test "$(( gemini - wall_now ))" -le 6068
iso=$(date -u -j -v+1d +%Y-%m-%dT15:00:00)
check test "$(wall_reset "resets ${iso}Z")" = "$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$iso" +%s)"
check test -z "$(printf 'Connection reset by peer\npreset: 5\nretry at most once\n' >"$WORK/wall.out"; worker_walls_extract_reset "$WORK/wall.out")"
dec31=$(at "$(date +%Y)-12-31 10:00:00")
check test "$(WORKER_WALLS_NOW=$dec31 worker_walls_parse_reset 'resets Jan 2 3:00 PM')" = "$(date -j -v+1y -f '%Y-%m-%d %H:%M:%S' "$(date +%Y)-01-02 15:00:00" +%s)"

printf '}\n' >>"$menu_cases"
if command -v hs >/dev/null 2>&1 && [ "$(hs_bounded 600 -c 'return "ok"' 2>/dev/null)" = ok ]; then
  checks=$((checks + 1))
  menu_out=$(hs_bounded 600 -c "return assert(loadfile([[$ROOT/tests/llm_limits_renderer_harness.lua]]))([[$menu_cases]])" 2>&1)
  [ "$menu_out" = 'PASS: wall store menu' ] || { printf 'FAIL: menu: %s\n' "$menu_out" >&2; failures=$((failures + 1)); }
else
  echo "SKIP (hs unavailable): wall store menu"
fi
[ "$failures" -eq 0 ] || exit 1
printf 'PASS: %s wall-store assertions (store, menu, statusline, worker-pick, JSON/table/plain, reset wordings)\n' "$checks"
