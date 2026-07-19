#!/usr/bin/env bash
# Claude Code status line: model | dir/branch/lines | ports | worker | topic ‖ ctx % | 5h/weekly/fable limits | cost.
# rate_limits is absent from some renders and idle sessions re-send their last
# copy forever; every path renders from a stamped merged cache (statusline-cache-rl
# for main, limits/<acct>.json for claudeb accounts — ~/.claude-profiles/README.md),
# never from raw headers alone. CLAUDE_LIMITS_ACCOUNT="-" (rotating proxy session)
# never writes caches; it renders the daemon's current pick read-only.
# Runs every 5s even while idle: GIT_OPTIONAL_LOCKS=0 keeps renders off index.lock.
export GIT_OPTIONAL_LOCKS=0

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
claudeb_dir="${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}"
account_cache_dir="$claudeb_dir/limits"
account_cache="$account_cache_dir/$acct.json"
limits_file="${LLM_LIMITS_FILE:-$HOME/.llm-limits.json}"

file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

snapshot_lock_acquire() {
  local lock="$1" now mtime
  mkdir "$lock" 2>/dev/null && return 0
  now=$(date +%s 2>/dev/null) || return 1
  mtime=$(file_mtime "$lock" 2>/dev/null) || return 1
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  [ "$((now - mtime))" -gt 120 ] || return 1
  rmdir "$lock" 2>/dev/null || return 1
  mkdir "$lock" 2>/dev/null
}

CYAN=$'\033[36m'; BLUE=$'\033[34m'; DIM=$'\033[2m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; MAGENTA=$'\033[35m'; RESET=$'\033[0m'

# Third arg overrides the green→yellow threshold (default 50); red stays ≥80.
pct_colored() {
  local v="$1" dim_flag="${2:-}" warn="${3:-50}"
  if [ -z "$v" ]; then printf '%s?%s' "$DIM" "$RESET"; return; fi
  if [ -n "$dim_flag" ]; then printf '%s%s%%%s' "$DIM" "$v" "$RESET"; return; fi
  local color
  if [ "$v" -lt "$warn" ]; then color="$GREEN"
  elif [ "$v" -lt 80 ]; then color="$YELLOW"
  else color="$RED"
  fi
  printf '%s%s%%%s' "$color" "$v" "$RESET"
}

# \x1f (unit separator) instead of tab: bash `read` collapses consecutive tab
# delimiters (tab is IFS-whitespace), which misaligns fields whenever a middle
# one (e.g. fast_mode, commonly empty) is blank.
IFS=$'\x1f' read -r model model_id effort fast_mode ctx_size dir_path current_dir session_id ctx_pct ctx_tokens cost_raw lines_added lines_removed rl_json < <(printf '%s' "$input" | jq -r '
  def num0: if . == null then "" else (.+0|round|tostring) end;
  def str0: if . == null then "" else tostring end;
  [ (.model.display_name // "?"),
    (.model.id // ""),
    (.effort.level // ""),
    (if .fast_mode == true then "1" else "" end),
    (.context_window.context_window_size | num0),
    (.workspace.project_dir // .workspace.current_dir // .cwd // "."),
    (.workspace.current_dir // .cwd // "."),
    ((.session_id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "")),
    (.context_window.used_percentage | num0),
    ((.context_window.current_usage // null) | if . == null then "" else
      (((.input_tokens//0)+(.cache_creation_input_tokens//0)+(.cache_read_input_tokens//0))|tostring) end),
    (.cost.total_cost_usd | str0),
    (.cost.total_lines_added | num0),
    (.cost.total_lines_removed | num0),
    ((.rate_limits // null) | if . == null then "" else tojson end)
  ] | join("")')

cb_current=""
if [ "$acct" = "-" ]; then
  cb_state="$claudeb_dir/.claudeb-state"
  case "$model_id" in
    claude-fable*) [ -s "$claudeb_dir/.claudeb-state-fable" ] && cb_state="$claudeb_dir/.claudeb-state-fable" ;;
  esac
  cb_current=$(head -n1 "$cb_state" 2>/dev/null | tr -d '[:space:]')
fi

rl_merge() {
  # An empty/invalid existing file must degrade to {}: feeding it to --argjson
  # makes jq fail every render and the corrupt file would never self-heal.
  old_rl=$(jq -c 'select(type == "object")' "$1" 2>/dev/null) || old_rl=''
  [ -n "$old_rl" ] || old_rl='{}'
  # An idle session re-renders its last known rate_limits forever; accepting
  # such rewrites would keep re-freshening stale data over live probe merges.
  # Only a strictly newer window (or higher pct in the same window) is taken.
  merged_rl=$(jq -cn --argjson old "$old_rl" --argjson fresh "$rl_json" --argjson now "$(date +%s)" '
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
  ' 2>/dev/null) || merged_rl=""
}

rl_from_cache=""
rl_mtime=""
if [ "$acct" = "-" ]; then
  rl_json=""
  if [ -n "$cb_current" ]; then
    pick_cache="$account_cache_dir/$cb_current.json"
    rl_json=$(cat "$pick_cache" 2>/dev/null)
    rl_from_cache=1
    rl_mtime=$(file_mtime "$pick_cache")
  fi
elif [ -n "$rl_json" ]; then
  rl_target="$cache_rl"
  if [ "$acct" != main ]; then
    # main is not a claudeb account: never create limits/main.json.
    mkdir -p "$account_cache_dir"
    rl_target="$account_cache"
  fi
  rl_mtime=$(file_mtime "$rl_target")
  snapshot_lock="$rl_target.lock"
  # The cache read must sit under the same lock as the write: a concurrent
  # claudeb merge landing between them would be clobbered by this render.
  if snapshot_lock_acquire "$snapshot_lock"; then
    rl_merge "$rl_target"
    # Skipping the no-op rewrite matters: readers fall back to file mtime for
    # staleness, and a fresh mtime would disguise old data as live.
    if [ -n "$merged_rl" ] && [ "$merged_rl" != "$old_rl" ]; then
      tmp_rl="$rl_target.tmp.$$"
      printf '%s' "$merged_rl" > "$tmp_rl" && mv "$tmp_rl" "$rl_target" || rm -f "$tmp_rl"
    fi
    rmdir "$snapshot_lock" 2>/dev/null
  else
    rl_merge "$rl_target"
  fi
  [ -n "$merged_rl" ] && rl_json="$merged_rl"
else
  rl_cache_file="$account_cache"
  [ "$acct" = main ] && rl_cache_file="$cache_rl"
  rl_json=$(cat "$rl_cache_file" 2>/dev/null)
  rl_from_cache=1
  rl_mtime=$(file_mtime "$rl_cache_file")
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
    ] | join("")' 2>/dev/null)
fi

now=$(date +%s)
h5_dim=""; wk_dim=""
if [ -n "$h5_reset" ] && [ "$h5_reset" -lt "$now" ] 2>/dev/null; then h5_dim=1; fi
if [ -n "$wk_reset" ] && [ "$wk_reset" -lt "$now" ] 2>/dev/null; then wk_dim=1; fi
if [ -n "$rl_json" ]; then
  [ "$auth_status" = expired ] && { h5_dim=1; wk_dim=1; }
  [ "$h5_origin" = cached ] && h5_dim=1
  [ "$wk_origin" = cached ] && wk_dim=1
  # Legacy raw-headers caches carry no as_of; the cache file's mtime is the
  # honest lower bound (captured before any rewrite this render did).
  [[ "$h5_as_of" =~ ^[0-9]+$ ]] || h5_as_of="$rl_mtime"
  [[ "$wk_as_of" =~ ^[0-9]+$ ]] || wk_as_of="$rl_mtime"
  [[ "$h5_as_of" =~ ^[0-9]+$ ]] && [ $((now - h5_as_of)) -gt 1800 ] && h5_dim=1
  [[ "$wk_as_of" =~ ^[0-9]+$ ]] && [ $((now - wk_as_of)) -gt 21600 ] && wk_dim=1
  stale_acct=""
  if [ -n "$rl_from_cache" ]; then
    if [ "$acct" = "-" ]; then
      stale_acct="$cb_current"
    elif [ "$acct" != main ]; then
      stale_acct="$acct"
    fi
  fi
  if [ -n "$stale_acct" ]; then
    IFS=$'\x1f' read -r h5_stale wk_stale < <(jq -r --arg account "$stale_acct" '
      [.vendors.claude.accounts[]? | select(.account == $account)][0] as $a |
      if $a == null then ["", ""]
      else [($a.five_hour.stale == true | tostring), ($a.weekly.stale == true | tostring)] end |
      join("")
    ' "$limits_file" 2>/dev/null)
    [ "$h5_stale" = true ] && h5_dim=1
    [ "$wk_stale" = true ] && wk_dim=1
  fi
fi

dir=$(basename "$dir_path")

model_suffix=""
[ -n "$effort" ] && model_suffix=" ${effort}"
fast_part=""
[ -n "$fast_mode" ] && fast_part=" ${YELLOW}⚡${RESET}"
onem_part=""
[ -n "$ctx_size" ] && [ "$ctx_size" -gt 200000 ] 2>/dev/null && onem_part=" ${DIM}1m${RESET}"

git_dir="$current_dir"
active_top=""
workdir_state="$HOME/.cache/claude-statusline/workdir-$session_id"
if [ -n "$session_id" ] && [ -f "$workdir_state" ]; then
  IFS= read -r active_dir < "$workdir_state"
  state_top=""
  [ -n "$active_dir" ] && state_top=$(git -C "$active_dir" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$state_top" ]; then
    git_dir="$active_dir"
    active_top="$state_top"
  else
    rm -f "$workdir_state"
  fi
fi
project_top=$(git -C "$dir_path" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$active_top" ]; then
  if [ "$git_dir" = "$dir_path" ]; then
    active_top="$project_top"
  else
    active_top=$(git -C "$git_dir" rev-parse --show-toplevel 2>/dev/null)
  fi
fi

dir_part="${BLUE}${dir}${RESET}"
if [ -n "$active_top" ] && [ "$active_top" != "$project_top" ]; then
  dir_part="${DIM}${dir}${RESET} ${MAGENTA}»${RESET} ${BLUE}$(basename "$active_top")${RESET}"
fi

branch_part=""
if [ -n "$active_top" ]; then
  branch=$(git -C "$git_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$branch" = HEAD ]; then
    short_sha=$(git -C "$git_dir" rev-parse --short HEAD 2>/dev/null)
    branch_part=" ${BLUE}⎇${RESET} ${RED}@${short_sha}${RESET}"
  elif [ -n "$branch" ]; then
    branch_color="$BLUE"
    case "$branch" in
      claude/*|worktree-*) branch_color="$RED" ;;
    esac
    branch_part=" ${branch_color}⎇ ${branch}${RESET}"
  fi
  if [ -n "$branch_part" ]; then
    status_count=$(git -C "$git_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$status_count" ] && [ "$status_count" -gt 0 ] 2>/dev/null && branch_part="${branch_part} ${YELLOW}✚${status_count}${RESET}"

    read -r behind ahead < <(git -C "$git_dir" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
    [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && branch_part="${branch_part} ${MAGENTA}↓${behind}${RESET}"
    [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null && branch_part="${branch_part} ${MAGENTA}↑${ahead}${RESET}"
  fi
fi

h5_arrow=""
if [ -n "$h5_reset" ]; then
  h5_time=$(TZ=Europe/Kyiv date -r "$h5_reset" +%H:%M 2>/dev/null)
  [ -n "$h5_time" ] && h5_arrow=" ${DIM}${h5_time}${RESET}"
fi

wk_arrow_txt=""
if [ -n "$wk_reset" ]; then
  rem=$(( wk_reset - now ))
  if [ "$rem" -gt 86400 ] || [ "$rem" -le 0 ]; then
    dow=$(TZ=Europe/Kyiv date -r "$wk_reset" +%u)
    wtime=$(TZ=Europe/Kyiv date -r "$wk_reset" +%H:%M)
    case "$dow" in
      1) dname=Mon ;; 2) dname=Tue ;; 3) dname=Wed ;; 4) dname=Thu ;;
      5) dname=Fri ;; 6) dname=Sat ;; 7) dname=Sun ;;
    esac
    wk_arrow_txt="${dname} ${wtime}"
  elif [ "$rem" -gt 3600 ]; then
    wk_arrow_txt="$(( (rem + 1800) / 3600 ))h"
  elif [ "$rem" -gt 0 ]; then
    wk_arrow_txt="$(( (rem + 30) / 60 ))m"
  fi
fi
wk_arrow=""
[ -n "$wk_arrow_txt" ] && wk_arrow=" ${DIM}${wk_arrow_txt}${RESET}"

sep="${DIM}│${RESET}"

fable_part=""
fable_account="$acct"
[ "$fable_account" = "-" ] && fable_account="$cb_current"
if [ -n "$fable_account" ] && [ "$fable_account" != main ]; then
  IFS='|' read -r fable_found fable_pct fable_reset fable_stale < <(jq -r --arg name "$fable_account" '
    .vendors.claude.accounts[]?
    | select(.account == $name)
    | .fable // empty
    | ["1", (if .used_pct == null then "" else (.used_pct | round | tostring) end), (.resets_at // ""), (.stale == true | tostring)]
    | join("|")
  ' "$limits_file" 2>/dev/null)
  if [ "$fable_found" = 1 ]; then
    fable_dim=""
    [ "$fable_stale" = true ] && fable_dim=1
    # Stale flags inside a frozen llm-limits.json never flip; the file's own
    # age is the backstop.
    limits_mtime=$(file_mtime "$limits_file")
    [[ "$limits_mtime" =~ ^[0-9]+$ ]] && [ $((now - limits_mtime)) -gt 21600 ] && fable_dim=1
    fable_reset_txt=""
    if [ -n "$fable_reset" ]; then
      case "$fable_reset" in
        *Z) fable_ts="${fable_reset%Z}+0000" ;;
        *)  fable_ts="${fable_reset%:*}${fable_reset##*:}" ;;
      esac
      fable_date=$(TZ=Europe/Kyiv date -j -f "%Y-%m-%dT%H:%M:%S%z" "$fable_ts" "+%s|%u|%H:%M" 2>/dev/null)
      IFS='|' read -r fable_reset_epoch fable_dow fable_time <<< "$fable_date"
      if [[ "$fable_reset_epoch" =~ ^[0-9]+$ ]]; then
        fable_rem=$(( fable_reset_epoch - now ))
        if [ "$fable_rem" -gt 86400 ] || [ "$fable_rem" -le 0 ]; then
          case "$fable_dow" in
            1) fable_dname=Mon ;; 2) fable_dname=Tue ;; 3) fable_dname=Wed ;; 4) fable_dname=Thu ;;
            5) fable_dname=Fri ;; 6) fable_dname=Sat ;; 7) fable_dname=Sun ;;
          esac
          [ -n "$fable_dname" ] && fable_reset_txt="${fable_dname} ${fable_time}"
        elif [ "$fable_rem" -gt 3600 ]; then
          fable_reset_txt="$(( (fable_rem + 1800) / 3600 ))h"
        elif [ "$fable_rem" -gt 0 ]; then
          fable_reset_txt="$(( (fable_rem + 30) / 60 ))m"
        fi
      fi
    fi
    fable_reset_part=""
    [ -n "$fable_reset_txt" ] && fable_reset_part=" ${DIM}${fable_reset_txt}${RESET}"
    fable_part=" ${sep} fb $(pct_colored "$fable_pct" "$fable_dim")${fable_reset_part}"
  fi
fi

ctx_tokens_part=""
if [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
  ctx_tokens_part=" ${DIM}$(( (ctx_tokens + 500) / 1000 ))k${RESET}"
fi

# claudeb account this session runs on: a real account name (pinned/profile
# entry, CLAUDE_LIMITS_ACCOUNT=<name>) shows as cb:<name>; a rotating proxy
# session (CLAUDE_LIMITS_ACCOUNT="-") shows the daemon's current pick with a ~
# to mark that it can rotate. The current pick comes from the local state file
# the daemon persists on every switch (.claudeb-state-fable for fable-model
# sessions when present) — no network, fail silent. Plain non-claudeb sessions
# (acct=main) get no segment.
cb_part=""
if [ "$acct" = "-" ]; then
  [ -n "$cb_current" ] && cb_part=" ${DIM}cb:${RESET}${MAGENTA}~${cb_current}${RESET}"
elif [ -n "$acct" ] && [ "$acct" != main ]; then
  cb_part=" ${DIM}cb:${RESET}${MAGENTA}${acct}${RESET}"
fi

worker=""; codex_effort=""; sonnet_effort=""; codex_profile=""; claudeb_profile=""
claudeb_model=""; claudeb_effort=""
worker_file="$HOME/.claude/worker-model"
if [ -f "$worker_file" ]; then
  while IFS='=' read -r wkey wval; do
    case "$wkey" in
      worker) worker=$wval ;;
      codex_effort) codex_effort=$wval ;;
      sonnet_effort) sonnet_effort=$wval ;;
      codex_profile) codex_profile=$wval ;;
      claudeb_profile) claudeb_profile=$wval ;;
      claudeb_model) claudeb_model=$wval ;;
      claudeb_effort) claudeb_effort=$wval ;;
    esac
  done < "$worker_file"
else
  worker=sonnet
fi
abbrev_tier() {
  case "$1" in
    medium) printf med ;; high) printf hi ;; xhigh) printf xh ;;
    *) printf '%s' "$1" ;;
  esac
}
abbrev_model() {
  case "$1" in
    sonnet) printf son ;; haiku) printf hai ;; fable) printf fab ;;
    *) printf '%s' "$1" ;;
  esac
}

# Local mirror of `codexb pick` — no codexb/network per render. Same ordering
# (expired reset -> 0, unknown after known, >=100 excluded, name tiebreak, main
# fallback); auth and account list come from the snapshot's auth_needed, not
# live `codex login status` (divergence documented in docs/DIAGNOSTICS.md —
# keep in sync when pick changes).
codex_local_pick() {
  jq -r --argjson now "$now" '
    def reset_epoch: (.resets_at? // null) |
      if type == "number" then .
      elif type == "string" then (try fromdateiso8601 catch null)
      else null end;
    def eff: . as $b | ($b | reset_epoch) as $r |
      if (($b.used_pct? // null) | type) != "number" then null
      elif $r != null and $r <= $now then 0
      else $b.used_pct end;
    if (.vendors.codex.accounts | type) != "array" then "?"
    else ([ .vendors.codex.accounts[]
            | select(.auth_needed != true)
            | ([(.five_hour | eff), (.weekly | eff)] | map(select(. != null))) as $known
            | select(($known | length) == 0 or ($known | max) < 100)
            | {account,
               unknown: (if ($known | length) == 0 then 1 else 0 end),
               pressure: (if ($known | length) == 0 then 0 else ($known | max) end)} ]
          | sort_by(.unknown, .pressure, .account)
          | (.[0].account // "main"))
    end
  ' "$limits_file" 2>/dev/null
}

wname=""; wtier=""; wpin=""; wsel=""
case "$worker" in
  codex)
    wname=codex
    wtier=$(abbrev_tier "${codex_effort:-medium}")
    if [ -n "$codex_profile" ]; then
      wpin=$codex_profile
    else
      wsel=$(codex_local_pick)
      [ -n "$wsel" ] || wsel="?"
    fi
    ;;
  claudeb)
    wname=cb
    wtier="$(abbrev_model "${claudeb_model:-opus}")·$(abbrev_tier "${claudeb_effort:-high}")"
    if [ -n "$claudeb_profile" ]; then
      wpin=$claudeb_profile
    else
      # Workers run sonnet/opus: general-scope rotation state, never the
      # .claudeb-state-fable file the cb: segment may use.
      wsel=$(head -n1 "$claudeb_dir/.claudeb-state" 2>/dev/null | tr -d '[:space:]')
      [ -n "$wsel" ] || wsel="?"
    fi
    ;;
  sonnet)
    wname=son
    wtier=$(abbrev_tier "$sonnet_effort")
    ;;
  auto)
    wname=auto
    # Predictive display: what worker-pick would route to right now (codex
    # state+account, recommended claudeb account·model·effort). The cache is
    # per own-account because routing excludes the session's own account.
    pick_acct=$acct
    { [ "$pick_acct" = "-" ] || [ -z "$pick_acct" ]; } && pick_acct=main
    pick_cache="$HOME/.cache/worker-pick.line.$pick_acct"
    pick_mtime=$(file_mtime "$pick_cache" 2>/dev/null)
    if ! [[ "$pick_mtime" =~ ^[0-9]+$ ]] || [ "$((now - pick_mtime))" -gt 90 ]; then
      ("$HOME/.local/bin/worker-pick" >/dev/null 2>&1 &)
    fi
    auto_line=""
    [ -r "$pick_cache" ] && IFS= read -r auto_line < "$pick_cache"
    ;;
  *) wname="?" ;;
esac

# A live tag (seeded by worker-tag-hook from the actual launch command) beats
# the static config guess while a worker is running in THIS session.
live_tag=""
if [ -n "$session_id" ]; then
  tags_dir="$HOME/.cache/claude-worker-tags/$session_id"
  newest=$(ls -t "$tags_dir" 2>/dev/null | head -n1)
  if [ -n "$newest" ]; then
    tag_mtime=$(file_mtime "$tags_dir/$newest")
    if [[ "$tag_mtime" =~ ^[0-9]+$ ]] && [ "$((now - tag_mtime))" -le 600 ]; then
      IFS= read -r live_tag < "$tags_dir/$newest" 2>/dev/null || live_tag=""
      live_tag=$(printf '%s' "$live_tag" | sed 's/ · /·/g; s/·sonnet/·son/; s/·haiku/·hai/; s/·fable/·fab/; s/·medium/·med/; s/·high/·hi/; s/·xhigh/·xh/')
    fi
  fi
fi

worker_part=" ${sep} ${DIM}w:${wname}${RESET}"
if [ -n "$live_tag" ]; then
  worker_part="${worker_part} ${MAGENTA}▶${live_tag}${RESET}"
elif [ "$wname" = auto ] && [ -n "${auto_line:-}" ]; then
  worker_part="${worker_part} ${MAGENTA}${auto_line}${RESET}"
else
  if [ -n "$wpin" ]; then
    worker_part="${worker_part} ${MAGENTA}@${wpin}${RESET}"
  elif [ -n "$wsel" ]; then
    worker_part="${worker_part} ${MAGENTA}~${wsel}${RESET}"
  fi
  [ "$wname" != "?" ] && [ -n "$wtier" ] && worker_part="${worker_part}${DIM}·${wtier}${RESET}"
fi

lines_part=""
if [ -n "$lines_added" ] && [ -n "$lines_removed" ] && [ $(( lines_added + lines_removed )) -ge 50 ]; then
  lines_part=" ${GREEN}+${lines_added}${RESET}/${RED}-${lines_removed}${RESET}"
fi

# Too slow for the render path: read the cache, fire the probe in the background
# when it's >15s stale, and hide the segment once it's >60s stale (probe presumed dead).
ports_part=""
if [ -n "$session_id" ]; then
  probe_self="$0"
  [ -L "$probe_self" ] && probe_self=$(readlink "$probe_self")
  case "$probe_self" in /*) ;; *) probe_self="$(dirname "$0")/$(basename "$probe_self")" ;; esac
  probe_bin="$(dirname "$probe_self")/statusline-ports-probe.sh"
  ports_cache="$HOME/.cache/claude-statusline/ports-$session_id"
  ports_mtime=$(file_mtime "$ports_cache" 2>/dev/null)
  if { ! [[ "$ports_mtime" =~ ^[0-9]+$ ]] || [ "$((now - ports_mtime))" -gt 15 ]; } && [ -x "$probe_bin" ]; then
    ( "$probe_bin" "$session_id" "$PPID" >/dev/null 2>&1 & ) 2>/dev/null
  fi
  if [[ "$ports_mtime" =~ ^[0-9]+$ ]] && [ "$((now - ports_mtime))" -le 60 ]; then
    # `read` still sets the var on a newline-less EOF; ignore the nonzero return.
    ports_line=""
    IFS= read -r ports_line < "$ports_cache" 2>/dev/null || :
    if [ -n "$ports_line" ]; then
      ports_render=""; ports_count=0
      for p in $ports_line; do
        [ "$ports_count" -ge 3 ] && break
        ports_render="${ports_render} ${GREEN}:${p}${RESET}"
        ports_count=$((ports_count + 1))
      done
      [ -n "$ports_render" ] && ports_part=" ${DIM}⇢${RESET}${ports_render}"
    fi
  fi
fi

topic_seg=""
if [ -n "$session_id" ]; then
  topic_file="$HOME/.cache/claude-statusline/topic-$session_id"
  if [ -s "$topic_file" ]; then
    IFS= read -r topic_txt < "$topic_file" 2>/dev/null || topic_txt=""
    if [ -n "$topic_txt" ]; then
      [ "${#topic_txt}" -gt 44 ] && topic_txt="${topic_txt:0:43}…"
      topic_seg=" ${sep} ${DIM}${topic_txt}${RESET}"
    fi
  fi
fi

# Two lines: identity/work (model, account, dir/branch, workers, topic) on top,
# usage (ctx, 5h, weekly, fable, cost) below.
line1="${CYAN}${model}${model_suffix}${RESET}${fast_part}${onem_part}${cb_part} ${sep} ${dir_part}${branch_part}${lines_part}${ports_part}${worker_part}${topic_seg}"

line2="ctx $(pct_colored "$ctx_pct" "" 40)${ctx_tokens_part} ${sep} 5h $(pct_colored "$h5_pct" "$h5_dim")${h5_arrow} ${sep} wk $(pct_colored "$wk_pct" "$wk_dim")${wk_arrow}${fable_part}"

if [ -n "$cost_raw" ]; then
  line2="${line2} ${sep} ${DIM}\$$(LC_ALL=C printf '%.2f' "$cost_raw")${RESET}"
fi

printf '%s\n%s' "$line1" "$line2"
