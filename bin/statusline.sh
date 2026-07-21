#!/usr/bin/env bash
# Claude Code status line: model | dir/branch/uncommitted-diff | ports | worker ‖ ctx % | 5h/weekly/fable limits | cost.
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

# Propagate just-merged headers to all surfaces via the zero-network collector
# (never --refresh); full contract: docs/statusline-contract.md "Store merge-kick".
# Every failure is silent — the statusline must never break because a nudge failed.
store_merge_kick() {
  local collector self kick_dir stamp now_ts age
  collector="${STATUSLINE_STORE_MERGE_CMD:-}"
  if [ -z "$collector" ]; then
    self="$0"
    [ -L "$self" ] && self=$(readlink "$self")
    case "$self" in /*) ;; *) self="$(dirname "$0")/$self" ;; esac
    collector="$(dirname "$self")/../llm-limits.sh"
  fi
  [ -x "$collector" ] || return 0
  kick_dir="$HOME/.cache/claude-statusline"
  stamp="$kick_dir/store-merge-kick"
  now_ts=$(date +%s 2>/dev/null) || return 0
  age=$(file_mtime "$stamp" 2>/dev/null)
  [[ "$age" =~ ^[0-9]+$ ]] && [ "$((now_ts - age))" -lt 60 ] && return 0
  mkdir -p "$kick_dir" 2>/dev/null || return 0
  # Grab the single-flight lock in the foreground and stamp synchronously, so the
  # next render sees the debounce immediately (a background stamp would race two
  # near-simultaneous renders into a double kick).
  snapshot_lock_acquire "$stamp.lock" || return 0
  age=$(file_mtime "$stamp" 2>/dev/null)
  if [[ "$age" =~ ^[0-9]+$ ]] && [ "$((now_ts - age))" -lt 60 ]; then
    rmdir "$stamp.lock" 2>/dev/null
    return 0
  fi
  : > "$stamp" 2>/dev/null
  # Orphaned double-fork with own fds so the collector never holds the render's
  # stdout open or adds latency (same detach idiom as the ports probe).
  ( (
    PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:/usr/sbin" \
      "$collector" >/dev/null 2>&1
    rmdir "$stamp.lock" 2>/dev/null
  ) & ) >/dev/null 2>&1
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
IFS=$'\x1f' read -r model model_id effort fast_mode ctx_size dir_path current_dir session_id ctx_pct ctx_tokens cost_raw rl_json cache_create cache_read transcript_path < <(printf '%s' "$input" | jq -r '
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
    ((.rate_limits // null) | if . == null then "" else tojson end),
    ((.context_window.current_usage // null) | if . == null then "0" else (.cache_creation_input_tokens//0|tostring) end),
    ((.context_window.current_usage // null) | if . == null then "0" else (.cache_read_input_tokens//0|tostring) end),
    (.transcript_path // "")
  ] | join("")')

# The harness's used_percentage is denominator-blind on >200k windows (a 1m
# session at 248k reports 100%); raw usage over window size is the truth.
if [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ] 2>/dev/null && [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
  ctx_pct=$(( (ctx_tokens * 100 + ctx_size / 2) / ctx_size ))
fi

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
  store_merge_kick
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
    # Uncommitted volume in the ACTIVE repo, whoever wrote it: staged+unstaged
    # vs HEAD plus untracked files. Lines: numstat + untracked text lines
    # (grep -cI yields 0 and BSD grep prints nothing for binaries; numstat "-"
    # skipped by the awk guards). Files: --summary create/delete + untracked
    # markers; the rest of the numstat entries are "modified" (renames incl.).
    # Marker rows carry an empty 3rd field + tag — a real numstat path is
    # never empty, so tracked files can't collide with them. Not the harness's
    # .cost.total_lines_* — that was a session-lifetime tool-edit counter
    # across all repos, useless for "how much is hanging uncommitted now".
    read -r udiff_add udiff_del f_new f_del f_mod < <({
        if git -C "$git_dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
          git -C "$git_dir" diff --numstat --summary HEAD -- 2>/dev/null
        else
          # Unborn HEAD (no commits yet): diff the worktree against the empty
          # tree — summing `--cached` + worktree diffs would double-count a
          # file that is staged and then modified again. hash-object computes
          # the repo's own empty-tree id (sha1 and sha256 repos differ).
          empty_tree=$(git -C "$git_dir" hash-object -t tree /dev/null 2>/dev/null)
          [ -n "$empty_tree" ] \
            && git -C "$git_dir" diff --numstat --summary "$empty_tree" -- 2>/dev/null
        fi
        # ls-files paths are repo-relative; grep must resolve them, and the
        # count must be repo-wide even when git_dir is a subdirectory.
        ( cd "$active_top" 2>/dev/null && {
            git ls-files --others --exclude-standard 2>/dev/null \
              | awk '{print "0\t0\t\tU"}'
            git ls-files --others --exclude-standard -z 2>/dev/null \
              | xargs -0 grep -cI '' 2>/dev/null | awk -F: '{print $NF "\t0\t\tL"}'
          } )
      } | awk -F'\t' '
        /^[0-9-]+\t/ {
          if ($1 != "-") a += $1; if ($2 != "-") d += $2
          if (NF == 4 && $3 == "" && $4 == "U") fu++
          else if (NF == 4 && $3 == "" && $4 == "L") { }
          else nt++
          next
        }
        /^ create mode / {fc++}
        /^ delete mode / {fd++}
        END {printf "%d %d %d %d %d\n", a, d, fc + fu, fd, nt - fc - fd}')
    fparts=""
    [ "$f_new" -gt 0 ] 2>/dev/null && fparts="+${f_new}"
    [ "$f_mod" -gt 0 ] 2>/dev/null && fparts="${fparts}~${f_mod}"
    [ "$f_del" -gt 0 ] 2>/dev/null && fparts="${fparts}-${f_del}"
    if [ "$udiff_add" -gt 0 ] 2>/dev/null || [ "$udiff_del" -gt 0 ] 2>/dev/null; then
      branch_part="${branch_part} ${GREEN}+${udiff_add}${RESET}/${RED}-${udiff_del}${RESET}${fparts:+ ${DIM}${fparts}f${RESET}}"
    elif [ -n "$fparts" ]; then
      # Dirty with zero countable lines (binary/mode/rename-only): files only.
      branch_part="${branch_part} ${DIM}${fparts}f${RESET}"
    fi

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

# Prompt-cache warmth. Anthropic's cache is scoped per ORGANIZATION and per
# MODEL, its TTL is not in the statusline payload, and the transcript file
# mtime lies (--resume touches it before any request). The only trustworthy
# evidence is the transcript entries themselves:
#   - a completed API response = a non-sidechain, non-<synthetic> assistant
#     entry (timestamp, message.model, message.usage);
#   - the usage cache_creation ephemeral_5m/1h split is the API's OWN TTL
#     declaration for the newest cache write — no guessing needed when present;
#   - /compact rewrites the prefix (cache dead until the next response) and
#     marks it with a system/compact_boundary entry; its injected summary is a
#     user entry (isCompactSummary) and its continuation user entry is
#     unmarked, which is why warmth anchors on ASSISTANT entries only.
# One jq pass over the tail extracts everything; any parse failure degrades to
# cold — never to a false warm. Emits: newest-response epoch + model + its
# forkedFrom session (branched chats copy the parent's entries), TTL bucket
# seconds, post-compact flag, and one TTL-learning evidence tuple (the newest
# turn's first response after idle gap G, pre-guarded in jq for "no boundary
# inside the gap" and "same model across the gap").
assist_ts=0; assist_model="-"; fork_sid="-"; ttl_bucket=0; post_compact=0
ev_valid=0; ev_ts=0; ev_gap=0; ev_cr=0; ev_cc=0
if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
  cache_scan=$(tail -c 262144 "$transcript_path" 2>/dev/null | jq -Rrn '
    def ep: try (sub("\\.[0-9]+Z$"; "Z") | fromdate) catch null;
    def bucket_secs:
      (((.cache_creation? // {}) | to_entries | map(select((.value? // 0) > 0))
        | max_by(.value) | (.key // "")
        | capture("ephemeral_(?<n>[0-9]+)(?<u>[mh])_")?
        | ((.n | tonumber) * (if .u == "m" then 60 else 3600 end))) // 0);
    reduce (inputs | fromjson? | select(type == "object" and .isSidechain != true)) as $x (
      {la: 0, pm: "", pg: -1, pa: 0, lb: 0, ats: 0, am: "-", afk: "", bk: 0,
       cgap: 0, ccr: 0, ccc: 0, cets: 0, cpm: "", cem: "", cpa: 0, chas: 0};
      ((($x.timestamp? // "") | if type == "string" then ep else null end)) as $ts
      | if $ts == null then .
        elif $x.type == "system" and $x.subtype == "compact_boundary" then
          (if $ts > .lb then .lb = $ts else . end)
        elif $x.type == "user" and ($x.isCompactSummary? != true) then
          (if .la > 0 and .pg < 0 then .pg = ($ts - .la) | .pa = .la else . end)
          | (if $ts > .la then .la = $ts else . end)
        elif $x.type == "assistant" and (($x.message?.model? // "") != "<synthetic>") then
          ($x.message?.usage? // {}) as $u
          | ($u | bucket_secs) as $bs
          | (if .pg >= 0 then
               .cgap = .pg | .ccr = ($u.cache_read_input_tokens? // 0)
               | .ccc = ($u.cache_creation_input_tokens? // 0)
               | .cets = $ts | .cpm = .pm | .cem = ($x.message?.model? // "")
               | .cpa = .pa | .chas = 1 | .pg = -1
             else . end)
          | (if $ts >= .ats then .ats = $ts
               | .am = (($x.message?.model? // "") | if . == "" then "-" else . end)
               | .afk = (($x.forkedFrom?.sessionId? // "") | tostring)
             else . end)
          | .pm = ($x.message?.model? // "")
          | (if $bs > 0 then .bk = $bs else . end)
          | (if $ts > .la then .la = $ts else . end)
        else . end)
    | [ .ats, .am, (.afk | if . == "" then "-" else . end), .bk,
        (if .lb > 0 and .lb >= .ats then 1 else 0 end),
        (if .chas == 1 and .cgap > 0 and .cpm != "" and .cpm == .cem
            and (.lb == 0 or .lb <= .cpa or .lb >= .cets) then 1 else 0 end),
        .cets, .cgap, .ccr, .ccc ]
    | map(tostring) | join(" ")' 2>/dev/null)
  if [ -n "$cache_scan" ]; then
    read -r assist_ts assist_model fork_sid ttl_bucket post_compact ev_valid ev_ts ev_gap ev_cr ev_cc <<< "$cache_scan" || :
    [[ "$assist_ts" =~ ^[0-9]+$ ]] || assist_ts=0
    [[ "$fork_sid" =~ ^[A-Za-z0-9_-]+$ ]] || fork_sid="-"
    [[ "$ttl_bucket" =~ ^[0-9]+$ ]] || ttl_bucket=0
    [[ "$ev_ts" =~ ^[0-9]+$ ]] || ev_ts=0
    [[ "$ev_gap" =~ ^[0-9]+$ ]] || ev_gap=0
    [[ "$ev_cr" =~ ^[0-9]+$ ]] || ev_cr=0
    [[ "$ev_cc" =~ ^[0-9]+$ ]] || ev_cc=0
  fi
fi
cache_ttl_seed=3600
seed_override=""
# `[ -r ]` guards the read: a `< missing-file` redirect prints its own error
# that `2>/dev/null` on the read cannot suppress.
seed_file="$HOME/.claude/statusline-cache-ttl"
[ -r "$seed_file" ] && { read -r seed_override < "$seed_file" 2>/dev/null || seed_override=""; }
[[ "$seed_override" =~ ^[0-9]+$ ]] && [ "$seed_override" -gt 0 ] && cache_ttl_seed="$seed_override"

learned_file="$HOME/.cache/claude-statusline/cache-ttl-learned"
ttl_floor=0; ttl_ceiling=""; learned_at=""
if [ -r "$learned_file" ] && read -r learned_raw < "$learned_file" 2>/dev/null; then
  [[ "$learned_raw" =~ \"observed_floor_s\":([0-9]+) ]] && ttl_floor="${BASH_REMATCH[1]}"
  [[ "$learned_raw" =~ \"observed_ceiling_s\":([0-9]+) ]] && ttl_ceiling="${BASH_REMATCH[1]}"
  [[ "$learned_raw" =~ \"updated_at\":([0-9]+) ]] && learned_at="${BASH_REMATCH[1]}"
fi
bounds_changed=""
# Anthropic can change the real TTL; bounds older than 7d are no longer trusted.
if [[ "$learned_at" =~ ^[0-9]+$ ]] && [ $((now - learned_at)) -gt 604800 ]; then
  ttl_floor=0; ttl_ceiling=""; bounds_changed=1
fi

# The transcript pins the model of the cache but not the ACCOUNT, so the
# account is stamped into cache-ttl-track-<sid> ("v2 <assist_ts> <acct>
# <learned_upto>") whenever a response lands during a live render. Attribution
# window 120s: renders run every few seconds while a session is alive, and the
# account cannot change without restarting the session (/exit), so a response
# older than that with no matching stamp is unattributable ("?") and renders
# cold — this is what makes a menu/rotation account switch (resume under a new
# profile, no stamp rewrite) reliably cold until the first new response.
# Legacy v1 track files (prompt_id-based) are treated as absent.
warm_acct="$acct"
[ "$acct" = "-" ] && warm_acct="$cb_current"
track_acct=""
if [ -n "$session_id" ] && [ "$assist_ts" -gt 0 ] 2>/dev/null; then
  track="$HOME/.cache/claude-statusline/cache-ttl-track-$session_id"
  t1=""; t2=""; t3=""; t4=""
  [ -r "$track" ] && { read -r t1 t2 t3 t4 < "$track" 2>/dev/null || :; }
  rec_ts=0; rec_acct=""; learned_upto=0
  if [ "$t1" = v2 ]; then
    [[ "$t2" =~ ^[0-9]+$ ]] && rec_ts="$t2"
    rec_acct="$t3"
    [[ "$t4" =~ ^[0-9]+$ ]] && learned_upto="$t4"
  fi
  # A branched chat copies the parent's history (entries keep the parent id in
  # forkedFrom.sessionId), so its own track starts empty. When the anchor
  # response is a copied one and the PARENT's stamp still points at that exact
  # response (the parent has not moved past the fork point), the fork shares
  # the parent's cached prefix — inherit the parent's account stamp and
  # learning cursor. Anything less exact stays "?" (cold): a fork from an
  # earlier message provably rebuilds all but the static prefix.
  if [ "$t1" != v2 ] && [ "$fork_sid" != "-" ] && [ "$fork_sid" != "$session_id" ]; then
    p1=""; p2=""; p3=""; p4=""
    ptrack="$HOME/.cache/claude-statusline/cache-ttl-track-$fork_sid"
    [ -r "$ptrack" ] && { read -r p1 p2 p3 p4 < "$ptrack" 2>/dev/null || :; }
    if [ "$p1" = v2 ] && [ "$p2" = "$assist_ts" ] && [ -n "$p3" ] && [ "$p3" != "?" ]; then
      rec_ts="$p2"; rec_acct="$p3"
      [[ "$p4" =~ ^[0-9]+$ ]] && learned_upto="$p4"
    fi
  fi
  track_acct="$rec_acct"
  if [ "$assist_ts" -gt "$rec_ts" ]; then
    # Self-attribution only for responses this session produced itself: a
    # copied (forked) anchor was produced by the parent — even a fresh one
    # must inherit, never stamp the current account.
    if [ $((now - assist_ts)) -le 120 ] && [ -n "$warm_acct" ] && [ "$fork_sid" = "-" ]; then
      track_acct="$warm_acct"
    else
      track_acct="?"
    fi
  fi
  [ -n "$track_acct" ] || track_acct="?"
  # TTL learning feeds the no-bucket fallback. Evidence (from the jq pass, which
  # already guarded same-model-across-gap and no-boundary-inside-gap): the
  # newest turn's first response after idle gap G. A large cache_read proves the
  # cache survived G (floor up; a survival past the believed ceiling disproves
  # it); a full rebuild after G >= 120s proves it died within G (ceiling down —
  # sub-2min rebuilds are prefix invalidations, not TTL expiry). An account
  # switch across the gap is not TTL evidence; each response is consumed once.
  if [ "$ev_valid" = 1 ] && [ "$ev_ts" -gt "$learned_upto" ] 2>/dev/null \
     && [ -n "$rec_acct" ] && [ "$rec_acct" != "?" ] && [ "$rec_acct" = "$warm_acct" ]; then
    if [ "$ev_cr" -ge 1000 ] 2>/dev/null && [ "$ev_cr" -ge "$ev_cc" ] 2>/dev/null; then
      [ "$ev_gap" -gt "$ttl_floor" ] 2>/dev/null && { ttl_floor=$ev_gap; bounds_changed=1; }
      if [ -n "$ttl_ceiling" ] && [ "$ev_gap" -gt "$ttl_ceiling" ] 2>/dev/null; then ttl_ceiling=""; bounds_changed=1; fi
    elif [ "$ev_cr" -lt 1000 ] 2>/dev/null && [ "$ev_cc" -ge 20000 ] 2>/dev/null && [ "$ev_gap" -ge 120 ] 2>/dev/null; then
      if [ -z "$ttl_ceiling" ] || [ "$ev_gap" -lt "$ttl_ceiling" ] 2>/dev/null; then ttl_ceiling=$ev_gap; bounds_changed=1; fi
    fi
  fi
  [ "$ev_ts" -gt "$learned_upto" ] 2>/dev/null && learned_upto="$ev_ts"
  if [ "$t1" != v2 ] || [ "$track_acct" != "$rec_acct" ] || [ "$assist_ts" -ne "$rec_ts" ] || [ "$learned_upto" != "${t4:-}" ]; then
    printf 'v2 %s %s %s\n' "$assist_ts" "$track_acct" "$learned_upto" > "$track.tmp.$$" 2>/dev/null \
      && mv "$track.tmp.$$" "$track" 2>/dev/null || rm -f "$track.tmp.$$" 2>/dev/null
  fi
fi

if [ -n "$bounds_changed" ]; then
  ceil_json=null; [ -n "$ttl_ceiling" ] && ceil_json="$ttl_ceiling"
  mkdir -p "$HOME/.cache/claude-statusline" 2>/dev/null
  printf '{"observed_floor_s":%s,"observed_ceiling_s":%s,"updated_at":%s}\n' "$ttl_floor" "$ceil_json" "$now" \
    > "$learned_file.tmp.$$" 2>/dev/null && mv "$learned_file.tmp.$$" "$learned_file" 2>/dev/null || rm -f "$learned_file.tmp.$$" 2>/dev/null
fi

# The API's own declaration wins: the newest response's cache_creation bucket
# (ephemeral_5m/1h field name) IS the TTL of the newest cache write, and reads
# refresh that same bucket. Seed + learned bounds are the fallback for tails
# whose entries carry no bucket.
if [ "$ttl_bucket" -gt 0 ] 2>/dev/null; then
  cache_ttl="$ttl_bucket"
else
  cache_ttl="$cache_ttl_seed"
  [ "$cache_ttl" -lt "$ttl_floor" ] 2>/dev/null && cache_ttl="$ttl_floor"
  [ -n "$ttl_ceiling" ] && [ "$cache_ttl" -gt "$ttl_ceiling" ] 2>/dev/null && cache_ttl="$ttl_ceiling"
fi

# Cache warm: token count and time both dim (time presence signals alive cache).
# Cache not warm: count colored by size — <90k dim, 90–299k yellow, >=300k red.
# Warm requires ALL of: a completed response visible in the tail, cache tokens
# in the payload, response within TTL, no compact boundary at/after it, same
# model (payload model.id vs the response entry's model — Anthropic caches are
# per-model), and a verified same-account stamp ("?" is cold, never warm).
ctx_tokens_part=""
if [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
  death_part=""
  cache_live=$(( ${cache_create:-0} + ${cache_read:-0} ))
  if [ "$cache_live" -gt 0 ] 2>/dev/null && [ "$assist_ts" -gt 0 ] 2>/dev/null \
     && [ "$post_compact" = 0 ] \
     && [ "$((now - assist_ts))" -le "$cache_ttl" ] 2>/dev/null \
     && [ -n "$track_acct" ] && [ "$track_acct" != "?" ] && [ "$track_acct" = "$warm_acct" ] \
     && { [ -z "$model_id" ] || [ "$assist_model" = "-" ] || [ "$assist_model" = "$model_id" ]; }; then
    tok_color="$DIM"
    death_time=$(TZ=Europe/Kyiv date -r "$((assist_ts + cache_ttl))" +%H:%M 2>/dev/null)
    [ -n "$death_time" ] && death_part="${DIM}→${death_time}${RESET}"
  else
    if [ "$ctx_tokens" -lt 90000 ]; then tok_color="$DIM"
    elif [ "$ctx_tokens" -lt 300000 ]; then tok_color="$YELLOW"
    else tok_color="$RED"
    fi
  fi
  ctx_tokens_part=" ${tok_color}$(( (ctx_tokens + 500) / 1000 ))k${RESET}${death_part}"
fi
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
# Derive codex model short label from ~/.codex/config.toml; fallback "sol" defined here.
codex_model_short_label() {
  local toml="${1:-$HOME/.codex/config.toml}" label=""
  [ -r "$toml" ] && label=$(grep -m1 '^model[[:space:]]*=' "$toml" 2>/dev/null \
    | sed 's/.*"\([^"]*\)".*/\1/; s/.*-//')
  [[ "$label" =~ ^[A-Za-z0-9]+$ ]] || label=sol
  printf '%s' "$label"
}

case "$worker" in
  codex)
    wname=codex
    wtier="$(codex_model_short_label)·$(abbrev_tier "${codex_effort:-medium}")"
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
      live_tag=$(printf '%s' "$live_tag" | sed 's/ · /·/g; s/·gpt-[0-9.-]*-/·/; s/·sonnet/·son/; s/·haiku/·hai/; s/·fable/·fab/; s/·medium/·med/; s/·high/·hi/; s/·xhigh/·xh/')
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

# Two lines: identity/work (model, account, dir/branch/diff, workers) on top,
# usage (ctx, 5h, weekly, fable, cost) below.
line1="${CYAN}${model}${model_suffix}${RESET}${fast_part}${cb_part} ${sep} ${dir_part}${branch_part}${ports_part}${worker_part}"

line2="ctx $(pct_colored "$ctx_pct" "" 40)${ctx_tokens_part} ${sep} 5h $(pct_colored "$h5_pct" "$h5_dim")${h5_arrow} ${sep} wk $(pct_colored "$wk_pct" "$wk_dim")${wk_arrow}${fable_part}"

if [ -n "$cost_raw" ]; then
  line2="${line2} ${sep} ${DIM}\$$(LC_ALL=C printf '%.2f' "$cost_raw")${RESET}"
fi

printf '%s\n%s' "$line1" "$line2"
