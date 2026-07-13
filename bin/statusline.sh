#!/usr/bin/env bash
# Claude Code status line: model | dir/branch/lines | ctx % | 5h/weekly rate limits | cost.
# rate_limits is absent from some renders; the last known object is cached in
# statusline-cache-rl and reused so usage % survives those gaps.
# Per-account snapshot writes below feed the claudeb multi-account system
# (~/.claude-profiles/README.md); CLAUDE_LIMITS_ACCOUNT="-" means skip writes.
input=$(cat)
cache_rl="$HOME/.claude/statusline-cache-rl"
acct="${CLAUDE_LIMITS_ACCOUNT:-}"
if [ -z "$acct" ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
    acct=$(basename "$CLAUDE_CONFIG_DIR")
  else
    acct=main
  fi
fi
account_cache_dir="${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/limits"
account_cache="$account_cache_dir/$acct.json"

CYAN=$'\033[36m'; BLUE=$'\033[34m'; DIM=$'\033[2m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; MAGENTA=$'\033[35m'; RESET=$'\033[0m'

pct_colored() {
  local v="$1" dim_flag="${2:-}"
  if [ -z "$v" ]; then printf '%s?%s' "$DIM" "$RESET"; return; fi
  if [ -n "$dim_flag" ]; then printf '%s%s%%%s' "$DIM" "$v" "$RESET"; return; fi
  local color
  if [ "$v" -lt 50 ]; then color="$GREEN"
  elif [ "$v" -lt 80 ]; then color="$YELLOW"
  else color="$RED"
  fi
  printf '%s%s%%%s' "$color" "$v" "$RESET"
}

# \x1f (unit separator) instead of tab: bash `read` collapses consecutive tab
# delimiters (tab is IFS-whitespace), which misaligns fields whenever a middle
# one (e.g. exceeds_200k, commonly empty) is blank.
IFS=$'\x1f' read -r model effort dir_path current_dir ctx_pct ctx_tokens cost_raw lines_added lines_removed rl_json < <(printf '%s' "$input" | jq -r '
  def num0: if . == null then "" else (.+0|round|tostring) end;
  def str0: if . == null then "" else tostring end;
  [ (.model.display_name // "?"),
    (.effort.level // ""),
    (.workspace.project_dir // .workspace.current_dir // .cwd // "."),
    (.workspace.current_dir // .cwd // "."),
    (.context_window.used_percentage | num0),
    ((.context_window.current_usage // null) | if . == null then "" else
      (((.input_tokens//0)+(.cache_creation_input_tokens//0)+(.cache_read_input_tokens//0))|tostring) end),
    (.cost.total_cost_usd | str0),
    (.cost.total_lines_added | num0),
    (.cost.total_lines_removed | num0),
    ((.rate_limits // null) | if . == null then "" else tojson end)
  ] | join("\u001f")')

rl_from_cache=""
rl_cache_file=""
if [ -n "$rl_json" ] && [ "$acct" != "-" ]; then
  if [ "$acct" = main ]; then
    # main is not a claudeb account: never create limits/main.json.
    printf '%s' "$rl_json" > "$cache_rl"
  else
    mkdir -p "$account_cache_dir"
    tmp_rl="$account_cache.tmp.$$"
    # An empty/invalid existing file must degrade to {}: feeding it to --argjson
    # makes jq fail every render and the corrupt file would never self-heal.
    old_rl=$(jq -c 'select(type == "object")' "$account_cache" 2>/dev/null) || old_rl=''
    [ -n "$old_rl" ] || old_rl='{}'
    # An idle session re-renders its last known rate_limits forever; accepting
    # such rewrites would keep re-freshening stale data over live probe merges.
    # Only a strictly newer window (or higher pct in the same window) is taken.
    new_rl=$(jq -cn --argjson old "$old_rl" --argjson fresh "$rl_json" --argjson now "$(date +%s)" '
      def stamp: . + {as_of: $now, origin: "headers"}
        | (if (.used_percentage | type) == "number" then .used_percentage = (.used_percentage | round) else . end);
      def newer($k): ($fresh[$k] // null) as $f | ($old[$k] // null) as $o |
        ($f != null) and (
          $o == null
          or (($f.resets_at? // 0) > ($o.resets_at? // 0))
          or ((($f.resets_at? // 0) == ($o.resets_at? // 0))
              and (((($f.used_percentage? // 0)) | round) > ((($o.used_percentage? // 0)) | round)))
        );
      $old
      + (if newer("five_hour") then {five_hour: ($fresh.five_hour | stamp)} else {} end)
      + (if newer("seven_day") then {seven_day: ($fresh.seven_day | stamp)} else {} end)
      + (if newer("five_hour") or newer("seven_day") then {auth: {status: "ok", checked_at: $now}} else {} end)
    ' 2>/dev/null) || new_rl=""
    # Skipping the no-op rewrite matters: readers fall back to file mtime for
    # staleness, and a fresh mtime would disguise old data as live.
    if [ -n "$new_rl" ] && [ "$new_rl" != "$old_rl" ]; then
      printf '%s' "$new_rl" > "$tmp_rl" && mv "$tmp_rl" "$account_cache" || rm -f "$tmp_rl"
    fi
  fi
else
  if [ "$acct" != "-" ]; then
    rl_json=$(cat "$account_cache" 2>/dev/null)
    rl_from_cache=1
    rl_cache_file="$account_cache"
    if [ -z "$rl_json" ] && [ "$acct" = main ]; then
      rl_json=$(cat "$cache_rl" 2>/dev/null)
      rl_cache_file="$cache_rl"
    fi
  fi
fi

h5_pct=""; h5_reset=""; wk_pct=""; wk_reset=""
h5_as_of=""; wk_as_of=""; h5_origin=""; wk_origin=""; auth_status=""
if [ -n "$rl_json" ]; then
  IFS=$'\x1f' read -r h5_pct h5_reset wk_pct wk_reset h5_as_of wk_as_of h5_origin wk_origin auth_status < <(printf '%s' "$rl_json" | jq -r '
    def num0: if . == null then "" else (.+0|round|tostring) end;
    def str0: if . == null then "" else tostring end;
    [ (.five_hour.used_percentage | num0),
      (.five_hour.resets_at | str0),
      (.seven_day.used_percentage | num0),
      (.seven_day.resets_at | str0),
      (.five_hour.as_of | str0),
      (.seven_day.as_of | str0),
      (.five_hour.origin // ""),
      (.seven_day.origin // ""),
      (.auth.status // "")
    ] | join("\u001f")' 2>/dev/null)
fi

now=$(date +%s)
h5_dim=""; wk_dim=""
if [ -n "$h5_reset" ] && [ "$h5_reset" -lt "$now" ] 2>/dev/null; then h5_dim=1; fi
if [ -n "$wk_reset" ] && [ "$wk_reset" -lt "$now" ] 2>/dev/null; then wk_dim=1; fi
if [ -n "$rl_from_cache" ] && [ -n "$rl_json" ]; then
  src_mtime=$(stat -f %m "$rl_cache_file" 2>/dev/null || stat -c %Y "$rl_cache_file" 2>/dev/null || printf '0')
  [ "$auth_status" = expired ] && { h5_dim=1; wk_dim=1; }
  [ "$h5_origin" = cached ] && h5_dim=1
  [ "$wk_origin" = cached ] && wk_dim=1
  [[ "$h5_as_of" =~ ^[0-9]+$ ]] || h5_as_of=$src_mtime
  [[ "$wk_as_of" =~ ^[0-9]+$ ]] || wk_as_of=$src_mtime
  [ $((now - h5_as_of)) -gt 1800 ] && h5_dim=1
  [ $((now - wk_as_of)) -gt 21600 ] && wk_dim=1
fi

dir=$(basename "$dir_path")

model_suffix=""
[ -n "$effort" ] && model_suffix=" ${effort}"

branch=$(git -C "$current_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
branch_part=""
if [ -n "$branch" ]; then
  branch_color="$BLUE"
  case "$branch" in
    claude/*|worktree-*) branch_color="$RED" ;;
  esac
  branch_part=" ${branch_color}⎇ ${branch}${RESET}"

  status_count=$(git -C "$current_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  [ -n "$status_count" ] && [ "$status_count" -gt 0 ] 2>/dev/null && branch_part="${branch_part} ${YELLOW}✚${status_count}${RESET}"

  read -r behind ahead < <(git -C "$current_dir" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
  [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && branch_part="${branch_part} ${MAGENTA}↓${behind}${RESET}"
  [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null && branch_part="${branch_part} ${MAGENTA}↑${ahead}${RESET}"
fi

h5_arrow=""
if [ -n "$h5_reset" ]; then
  h5_time=$(TZ=Europe/Kyiv date -r "$h5_reset" +%H:%M 2>/dev/null)
  [ -n "$h5_time" ] && h5_arrow=" ${DIM}→${h5_time}${RESET}"
fi

wk_arrow_txt=""
if [ -n "$wk_reset" ]; then
  now=$(date +%s)
  rem=$(( wk_reset - now ))
  if [ "$rem" -gt 86400 ] || [ "$rem" -le 0 ]; then
    dow=$(TZ=Europe/Kyiv date -r "$wk_reset" +%u)
    wtime=$(TZ=Europe/Kyiv date -r "$wk_reset" +%H:%M)
    case "$dow" in
      1) dname=Mon ;; 2) dname=Tue ;; 3) dname=Wed ;; 4) dname=Thu ;;
      5) dname=Fri ;; 6) dname=Sat ;; 7) dname=Sun ;;
    esac
    wk_arrow_txt="→${dname} ${wtime}"
  elif [ "$rem" -gt 3600 ]; then
    wk_arrow_txt="→$(( (rem + 1800) / 3600 ))h"
  elif [ "$rem" -gt 0 ]; then
    wk_arrow_txt="→$(( (rem + 30) / 60 ))m"
  fi
fi
wk_arrow=""
[ -n "$wk_arrow_txt" ] && wk_arrow=" ${DIM}${wk_arrow_txt}${RESET}"

ctx_tokens_part=""
if [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
  tk_color="$DIM"
  # 40%, not pct_colored's 80: a large context is expensive to keep (cache
  # re-reads bill every turn), so this is an early "time to /compact" nudge.
  [ -n "$ctx_pct" ] && [ "$ctx_pct" -ge 40 ] 2>/dev/null && tk_color="$RED"
  ctx_tokens_part=" ${tk_color}$(( (ctx_tokens + 500) / 1000 ))k${RESET}"
fi

sep="${DIM}│${RESET}"

# claudeb account this session runs on: a real account name (pinned/profile
# entry, CLAUDE_LIMITS_ACCOUNT=<name>) shows as cb:<name>; a rotating proxy
# session (CLAUDE_LIMITS_ACCOUNT="-") shows the daemon's current pick with a ~
# to mark that it can rotate. The current pick comes from the local state file
# the daemon persists on every switch — no network, fail silent. Plain
# non-claudeb sessions (acct=main) get no segment.
cb_part=""
if [ "$acct" = "-" ]; then
  cb_current=$(head -n1 "${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/.claudeb-state" 2>/dev/null | tr -d '[:space:]')
  [ -n "$cb_current" ] && cb_part=" ${DIM}cb:${RESET}${MAGENTA}~${cb_current}${RESET}"
elif [ -n "$acct" ] && [ "$acct" != main ]; then
  cb_part=" ${DIM}cb:${RESET}${MAGENTA}${acct}${RESET}"
fi

lines_part=""
if [ -n "$lines_added" ] && [ -n "$lines_removed" ] && [ $(( lines_added + lines_removed )) -ge 50 ]; then
  lines_part=" ${DIM}✎${RESET} ${GREEN}+${lines_added}${RESET}/${RED}-${lines_removed}${RESET}"
fi

out="${CYAN}${model}${model_suffix}${RESET}${cb_part} ${sep} ${BLUE}📁 ${dir}${RESET}${branch_part}${lines_part} ${sep} ctx $(pct_colored "$ctx_pct")${ctx_tokens_part}"

out="${out} ${sep} 5h $(pct_colored "$h5_pct" "$h5_dim")${h5_arrow} ${sep} wk $(pct_colored "$wk_pct" "$wk_dim")${wk_arrow}"

if [ -n "$cost_raw" ]; then
  out="${out} ${sep} ${DIM}\$$(printf '%.2f' "$cost_raw")${RESET}"
fi

printf '%s' "$out"
