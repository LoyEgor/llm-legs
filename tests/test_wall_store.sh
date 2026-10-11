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
surfaces() { # name vendor walled
  local name=$1 vendor=$2 walled=$3 status picked rendered format
  picked=$(WORKER_PICK_NOW="$now" bash "$ROOT/bin/worker-pick" 2>/dev/null | grep "^$vendor:")
  if [ "$vendor" = codex ]; then
    status=$(printf '%s' '{"model":{"display_name":"GPT"},"context_window":{"used_percentage":1}}' |
      CLAUDEGPT_ACCOUNT=main STATUSLINE_NOW="$now" COLUMNS= bash "$ROOT/bin/statusline.sh")
  else
    status=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":1}}' |
      STATUSLINE_NOW="$now" COLUMNS= bash "$ROOT/bin/statusline.sh")
  fi
  if [ "$walled" = true ]; then
    check present "walled→$label" "$status"
    check present WALLED "$picked"
    check present "↺ $label" "$picked"
  else
    check absent walled→ "$status"
    check absent WALLED "$picked"
  fi
  for format in json table plain; do
    rendered=$(bash "$SCRIPT" --"$format" --no-write) || fail "$name: render $format"
    [ "$format" = json ] || rendered=$(grep "^$vendor" <<<"$rendered")
    if [ "$format" = json ]; then
      check jq -e --arg v "$vendor" --argjson walled "$walled" --argjson now "$now" \
        '(.vendors[$v].accounts[0].worker_wall | . != null and .resets_at > $now) == $walled' <<<"$rendered" >/dev/null
    elif [ "$walled" = true ]; then
      check present "walled→$label" "$rendered"
    else
      check absent walled→ "$rendered"
    fi
  done
  printf '{name="%s",account="main",walled=%s,now=%s,reset=%s,store=hs.json.decode([==[%s]==])},\n' \
    "$name" "$walled" "$now" "$reset" "$(jq -c --arg v "$vendor" '.vendors |= {($v): .[$v]}' "$CACHE")" >>"$menu_cases"
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
surfaces codex-walled codex true
surfaces claude-walled claude true

# An older record never replaces a newer one; an account the store does not list gets no row.
before=$(cat "$CACHE")
worker_walls_record codex main "$((reset + 600))" "$((at - 1))" || fail 'older record'
worker_walls_record codex ghost "$reset" "$at" || fail 'unknown account record'
check test "$(cat "$CACHE")" = "$before"

# The collector carries a standing wall across its refresh.
bash "$SCRIPT" --json >/dev/null || fail 'collection with wall'
check jq -e '.vendors.codex.accounts[0].worker_wall != null and .vendors.claude.accounts[0].worker_wall != null' "$CACHE" >/dev/null
numbers
surfaces codex-carried codex true

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
