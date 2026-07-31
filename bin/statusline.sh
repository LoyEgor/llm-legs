#!/usr/bin/env bash
# Claude Code status line: model | dir/branch/uncommitted-diff | ports | worker ‖ ctx % | 5h/weekly/fable limits | cost.
# rate_limits is absent from some renders and idle sessions re-send their last
# copy forever; every path renders from a stamped merged cache (statusline-cache-rl
# for main, limits/<acct>.json for claudeb accounts — ~/.claude-profiles/README.md),
# never from raw headers alone.
# Runs every 5s even while idle: GIT_OPTIONAL_LOCKS=0 keeps renders off index.lock.
export GIT_OPTIONAL_LOCKS=0

input=$(cat)
statusline_cache_dir="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}"
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
worker_stats_dir="${WORKER_STATS_DIR:-$claudeb_dir/worker-stats}"
limits_file="${LLM_LIMITS_FILE:-$HOME/.llm-limits.json}"
RECEIPT_HASH_HEX=8

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

git_common_dir() {
  local repo="$1" common
  common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$repo/$common" ;;
  esac
  (cd "$common" 2>/dev/null && pwd -P)
}

repo_identity_name() {
  local common
  common=$(git_common_dir "$1") || return 1
  if [ "$(basename "$common")" = .git ]; then
    basename "$(dirname "$common")"
  else
    basename "$common"
  fi
}

# One git call per directory for everything the render needs about its repository:
# REPO_TOP (this working tree), REPO_COMMON (identity — shared by all worktrees of
# a repo), REPO_ROOT (the main checkout), REPO_NAME, REPO_IS_WT (this directory is
# a linked worktree). Fails on anything without a working tree, as the render's
# whole repository cluster does.
repo_dirs() {
  local out rest common gitdir resolved main_wt
  out=$(git -C "$1" rev-parse --show-toplevel --git-common-dir --absolute-git-dir 2>/dev/null) || return 1
  REPO_TOP=${out%%$'\n'*}
  rest=${out#*$'\n'}
  common=${rest%%$'\n'*}
  gitdir=${rest#*$'\n'}
  [ -n "$REPO_TOP" ] && [ -n "$common" ] && [ -n "$gitdir" ] || return 1
  # `--git-common-dir` comes back relative to the CWD whenever it sits inside the
  # tree (`.git` at the root, `../../.git` from a subdirectory).
  case "$common" in
    /*) ;;
    *) common="$1/$common" ;;
  esac
  # All three must be compared with each other (identity, worktree detection, the
  # `.claude/worktrees` prefix test), so all three are resolved the same way. One
  # subshell for the lot: the paths are absolute, so the `cd`s do not compound.
  resolved=$({ cd "$common" && pwd -P && cd "$gitdir" && pwd -P && cd "$REPO_TOP" && pwd -P; } 2>/dev/null)
  { IFS= read -r common; IFS= read -r gitdir; IFS= read -r REPO_TOP; } <<< "$resolved"
  [ -n "$common" ] && [ -n "$gitdir" ] && [ -n "$REPO_TOP" ] || return 1
  REPO_COMMON="$common"
  if [ "$common" != "$gitdir" ]; then
    REPO_IS_WT=1
    # The main checkout is NOT derivable from the common dir — `--separate-git-dir`
    # and a custom `GIT_DIR` both break `<root>/.git`. `worktree list` names it,
    # main worktree first.
    main_wt=$(git -C "$1" worktree list --porcelain 2>/dev/null |
      { IFS= read -r line; printf '%s' "${line#worktree }"; })
    REPO_ROOT=$({ cd "$main_wt" && pwd -P; } 2>/dev/null) || REPO_ROOT=""
    [ -n "$REPO_ROOT" ] || REPO_ROOT="$REPO_TOP"
  else
    REPO_IS_WT=0
    REPO_ROOT="$REPO_TOP"
  fi
  REPO_NAME="${REPO_ROOT##*/}"
}

# Does the branch name carry every word of the worktree directory name? Decides
# whether the branch is redundant with the directory label or a surprise worth
# printing (`WUT-254-portal-mobile` covered by `WUT-254_feat_portal-mobile`,
# not by `staging`).
name_covered_by_branch() {
  local words branch word
  words=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ')
  branch=" $(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ') "
  [ -n "${words// /}" ] || return 1
  for word in $words; do
    case "$branch" in
      *" $word "*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

receipt_file_name() {
  local repo="$1" repo_name repo_hash
  repo=$(cd "$repo" 2>/dev/null && pwd -P) || return 1
  repo_name=$(repo_identity_name "$repo") || return 1
  repo_hash=$(printf '%s' "$repo" | shasum -a 1 2>/dev/null |
    awk -v n="$RECEIPT_HASH_HEX" '{print substr($1, 1, n)}')
  [[ "$repo_hash" =~ ^[0-9a-f]{8}$ ]] || return 1
  printf '%s__%s.json' "$repo_name" "$repo_hash"
}

# ps reports elapsed time as [[dd-]hh:]mm:ss; the render needs the instant the process started.
process_start_epoch() {
  local pid="$1" now="$2" elapsed days=0 hours=0 mins secs field
  elapsed=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  case "$elapsed" in *:*) ;; *) return 1 ;; esac
  case "$elapsed" in *-*) days=${elapsed%%-*}; elapsed=${elapsed#*-} ;; esac
  case "$elapsed" in *:*:*) hours=${elapsed%%:*}; elapsed=${elapsed#*:} ;; esac
  mins=${elapsed%%:*}
  secs=${elapsed##*:}
  # Each field on its own: concatenating them lets an empty one hide behind its neighbours and
  # reach the arithmetic below as the bare prefix `10#`, which is a syntax error, not a failure.
  for field in "$days" "$hours" "$mins" "$secs"; do
    [[ "$field" =~ ^[0-9]+$ ]] || return 1
  done
  printf '%s' "$((now - (10#$days * 86400 + 10#$hours * 3600 + 10#$mins * 60 + 10#$secs)))"
}

worktree_matches_tree() {
  local repo="$1" tree="$2" path entry mode type object actual_mode actual_object
  local -a excludes=()
  while IFS= read -r -d '' path; do
    entry=$(git -C "$repo" ls-tree "$tree" -- "$path" 2>/dev/null) || return 1
    [ -n "$entry" ] || return 1
    entry=${entry%%$'\t'*}
    read -r mode type object <<< "$entry"
    case "$mode" in
      160000)
        actual_mode=160000
        actual_object=$(git -C "$repo/$path" rev-parse HEAD 2>/dev/null) || return 1
        ;;
      120000)
        [ -L "$repo/$path" ] || return 1
        actual_mode=120000
        actual_object=$(git -C "$repo" hash-object -- "$path" 2>/dev/null) || return 1
        ;;
      100*)
        [ -f "$repo/$path" ] && [ ! -L "$repo/$path" ] || return 1
        [ -x "$repo/$path" ] && actual_mode=100755 || actual_mode=100644
        actual_object=$(git -C "$repo" hash-object -- "$path" 2>/dev/null) || return 1
        ;;
      *) return 1 ;;
    esac
    [ "$actual_mode" = "$mode" ] && [ "$actual_object" = "$object" ] || return 1
    excludes+=(":(top,literal,exclude)$path")
  done < <(git -C "$repo" ls-files --others --exclude-standard -z 2>/dev/null)
  git -C "$repo" diff --quiet --no-ext-diff --no-renames "$tree" -- . "${excludes[@]}" \
    2>/dev/null
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
  kick_dir="$statusline_cache_dir"
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
IFS=$'\x1f' read -r model model_id effort fast_mode ctx_size dir_path current_dir session_id ctx_pct ctx_tokens cost_raw rl_json transcript_path < <(printf '%s' "$input" | jq -r '
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
    (.transcript_path // "")
  ] | join("")')

# The harness marks a 1M-context session by suffixing its model id
# (claude-opus-5[1m]) while the transcript records the bare id the server
# returned, so warmth attribution must compare the stripped form or every
# 1M session reads permanently cold.
case "$model_id" in *\[*\]) model_id="${model_id%\[*}" ;; esac

# The harness's used_percentage is denominator-blind on >200k windows (a 1m
# session at 248k reports 100%); raw usage over window size is the truth.
if [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ] 2>/dev/null && [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
  ctx_pct=$(( (ctx_tokens * 100 + ctx_size / 2) / ctx_size ))
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
    # A cached header-origin week is synthetic (shared-invariants n) and must not survive
    # the merge: newer() only replaces on a HIGHER pct within the same window, so a
    # leftover 100 would outlive every real reading until the weekly reset.
    ($old | if (.seven_day.origin? == "headers") then del(.seven_day) else . end) as $old |
    # `session`: measured readings from the harness payload, not header learning.
    def stamp: . + {as_of: $now, origin: "session"}
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
if [ -n "$rl_json" ]; then
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

# Rendering a header-origin week would print a percentage nobody measured — and one every
# other surface discards (shared-invariants n). Show `?` instead.
[ "$wk_origin" = headers ] && { wk_pct=""; wk_reset=""; }

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
    if [ "$acct" != main ]; then
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
project_top=""; project_common=""; project_root=""; project_name=""; project_is_wt=0
if repo_dirs "$dir_path"; then
  project_top="$REPO_TOP"; project_common="$REPO_COMMON"
  project_root="$REPO_ROOT"; project_name="$REPO_NAME"; project_is_wt="$REPO_IS_WT"
  # A chat launched inside a linked worktree would otherwise be labelled by the
  # worktree's own name, hiding which project it belongs to.
  [ "$project_is_wt" = 1 ] && [ -n "$project_name" ] && dir="$project_name"
fi

model_suffix=""
[ -n "$effort" ] && model_suffix=" ${effort}"
fast_part=""
[ -n "$fast_mode" ] && fast_part=" ${YELLOW}⚡${RESET}"

git_dir="$current_dir"
active_top=""; active_common=""; active_root=""; active_name=""; active_is_wt=0
lost_dir=""
adopt_repo_dirs() {
  active_top="$REPO_TOP"; active_common="$REPO_COMMON"
  active_root="$REPO_ROOT"; active_name="$REPO_NAME"; active_is_wt="$REPO_IS_WT"
}
adopt_project_dirs() {
  active_top="$project_top"; active_common="$project_common"
  active_root="$project_root"; active_name="$project_name"; active_is_wt="$project_is_wt"
}
workdir_state="$statusline_cache_dir/workdir-$session_id"
if [ -n "$session_id" ] && [ -f "$workdir_state" ]; then
  IFS= read -r active_dir < "$workdir_state"
  if [ -z "$active_dir" ]; then
    :
  elif [ "$active_dir" = "$dir_path" ] && [ -n "$project_top" ]; then
    git_dir="$active_dir"
    adopt_project_dirs
  elif repo_dirs "$active_dir"; then
    git_dir="$active_dir"
    adopt_repo_dirs
  fi
  if [ -z "$active_top" ]; then
    # The tracked directory stopped resolving — a removed worktree, usually.
    # Falling back to the project dir without a word made the strip report the
    # main checkout's branch as if work had moved there. Written once, and with
    # the hook's tmp+mv, so the 7-day prune can age it out and no reader sees a
    # half-written path.
    if [ -n "$active_dir" ] && [ ! -f "$workdir_state.gone" ]; then
      if printf '%s\n' "$active_dir" > "$workdir_state.gone.$$" 2>/dev/null; then
        mv -f "$workdir_state.gone.$$" "$workdir_state.gone" 2>/dev/null ||
          rm -f "$workdir_state.gone.$$" 2>/dev/null
      fi
    fi
    rm -f "$workdir_state"
  fi
fi
if [ -n "$session_id" ] && [ -z "$active_top" ] && [ -f "$workdir_state.gone" ]; then
  IFS= read -r lost_dir < "$workdir_state.gone"
fi
if [ -z "$active_top" ]; then
  if [ "$git_dir" = "$dir_path" ]; then
    adopt_project_dirs
  elif repo_dirs "$git_dir"; then
    adopt_repo_dirs
  fi
fi

dir_part="${BLUE}${dir}${RESET}"
wt_part=""
if [ -n "$active_top" ]; then
  # Repository identity, not toplevel: every worktree of the project shares its
  # common dir, so `»` fires on a genuinely foreign repository only.
  if [ "$active_common" != "$project_common" ]; then
    dir_part="${DIM}${dir}${RESET} ${MAGENTA}»${RESET} ${BLUE}${active_name}${RESET}"
  fi
  if [ "$active_is_wt" = 1 ]; then
    # Worktrees belong at <repo>/.claude/worktrees/<name>; a harness-made one or
    # a sibling of the repo sits somewhere Egor did not put it, and no other part
    # of the setup reports where a worktree physically lives. Two roots satisfy
    # the rule: the repository's own main checkout, and — for a worktree of the
    # project — the session's checkout, which git cannot always name itself
    # (`worktree list` reports the git dir, not the checkout, under
    # --separate-git-dir).
    wt_color="$RED"
    case "$active_top" in
      "$active_root"/.claude/worktrees/*) wt_color="$BLUE" ;;
    esac
    if [ "$wt_color" = "$RED" ] && [ -n "$project_root" ]; then
      case "$active_top" in
        "$project_root"/.claude/worktrees/*) wt_color="$BLUE" ;;
      esac
    fi
    wt_part=" ${wt_color}⧉ ${active_top##*/}${RESET}"
  fi
fi
# Never over the label of a worktree that IS live: the fallback directory can be
# one itself, and a breadcrumb must not rename it.
[ -n "$lost_dir" ] && [ "$active_is_wt" != 1 ] &&
  wt_part=" ${DIM}⧉ ${lost_dir##*/} ✗${RESET}"
dir_part="${dir_part}${wt_part}"

branch_part=""
head_known=0
git_status=""
git_status_rc=1
if [ -n "$active_top" ]; then
  git_status=$(git -C "$active_top" status --porcelain 2>/dev/null)
  git_status_rc=$?
  branch=$(git -C "$git_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$branch" = HEAD ]; then
    short_sha=$(git -C "$git_dir" rev-parse --short HEAD 2>/dev/null)
    branch_part=" ${BLUE}⎇${RESET} ${RED}@${short_sha}${RESET}"
    head_known=1
  elif [ -n "$branch" ]; then
    head_known=1
    branch_color="$BLUE"
    show_branch=1
    case "$branch" in
      claude/*|worktree-*) branch_color="$RED" ;;
      *)
        # In a worktree the directory label already names the work, so the
        # branch is printed only when it is not the one that label implies —
        # that is the case where commits land somewhere unexpected.
        if [ "$active_is_wt" = 1 ]; then
          if name_covered_by_branch "${active_top##*/}" "$branch"; then
            show_branch=0
          else
            branch_color="$YELLOW"
          fi
        fi
        ;;
    esac
    [ "$show_branch" = 1 ] && branch_part=" ${branch_color}⎇ ${branch}${RESET}"
  fi
  if [ "$head_known" = 1 ]; then
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

# User/tool activity and payload cache counters cannot prove server cache warmth.
assist_ts=0; assist_model="-"; assist_uuid="-"; fork_sid="-"; ttl_bucket=0
post_compact=0; ctx_stale=1; boundary_ts=0
ev_valid=0; ev_ts=0; ev_gap=0; ev_cr=0; ev_cc=0
fork_anchor_uuid="-"; fork_own_ts=0
latest_ts=0; latest_model="-"; latest_ttl=0; latest_uuid="-"; latest_fork="-"
learned_file="${STATUSLINE_CACHE_TTL_LEARNED:-$statusline_cache_dir/cache-ttl-learned}"
warm_acct="$acct"; track_acct=""; learned_upto=0
rec_ts=0; rec_acct=""; rec_ttl=0; rec_model="-"; rec_uuid="-"; rec_scan=262144
seen_upto=0; seen_acct=""; track_ready=0
track=""; t1=""; t2=""; t3=""; t4=""; t5=""; t6=""; t7=""; t8=""; t9=""; t10=""
if [ -n "$session_id" ]; then
  track="$statusline_cache_dir/cache-ttl-track-$session_id"
  [ -r "$track" ] && { read -r t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 < "$track" 2>/dev/null || :; }
  if [ "$t1" = v2 ]; then
    [[ "$t2" =~ ^[0-9]+$ ]] && rec_ts="$t2"
    rec_acct="$t3"
    [[ "$t4" =~ ^[0-9]+$ ]] && learned_upto="$t4"
    [[ "$t5" =~ ^[0-9]+$ ]] && rec_ttl="$t5"
    [ -n "$t6" ] && rec_model="$t6"
    [ -n "$t7" ] && rec_uuid="$t7"
    [[ "$t8" =~ ^[0-9]+$ ]] && rec_scan="$t8"
    [[ "$t9" =~ ^[0-9]+$ ]] && seen_upto="$t9"
    seen_acct="$t10"
  fi
fi

model_key=""
[ -n "$model_id" ] && model_key=${model_id//[^A-Za-z0-9_.-]/_}
model_track=""
model_rec_ts=0; model_rec_acct=""; model_rec_ttl=0; model_rec_uuid="-"; model_rec_scan=0
m1=""; m2=""; m3=""; m4=""; m5=""; m6=""
if [ -n "$track" ] && [ -n "$model_key" ]; then
  model_track="$track.model-${model_key:0:80}"
  [ -r "$model_track" ] && { read -r m1 m2 m3 m4 m5 m6 < "$model_track" 2>/dev/null || :; }
  if [ "$m1" = v1 ]; then
    [[ "$m2" =~ ^[0-9]+$ ]] && model_rec_ts="$m2"
    model_rec_acct="$m3"
    [[ "$m4" =~ ^[0-9]+$ ]] && model_rec_ttl="$m4"
    [ -n "$m5" ] && model_rec_uuid="$m5"
    [[ "$m6" =~ ^[0-9]+$ ]] && model_rec_scan="$m6"
  fi
fi

scan_found=0; scan_complete=0; scan_bytes=262144; saved_scan_bytes=262144
scan_max=8388608; transcript_size=0
if [ "$model_rec_scan" -ge 262144 ] 2>/dev/null && [ "$model_rec_scan" -le "$scan_max" ] 2>/dev/null; then
  saved_scan_bytes="$model_rec_scan"
elif [ "$rec_scan" -ge 262144 ] 2>/dev/null && [ "$rec_scan" -le "$scan_max" ] 2>/dev/null; then
  saved_scan_bytes="$rec_scan"
fi

file_size() {
  stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null
}

resolve_parent_transcript() {
  local sibling root candidate found=""
  sibling="$(dirname "$transcript_path")/$fork_sid.jsonl"
  if [ -r "$sibling" ]; then
    printf '%s\n' "$sibling"
    return 0
  fi
  case "$transcript_path" in
    */projects/*/*.jsonl) root="${transcript_path%%/projects/*}/projects" ;;
    *) root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" ;;
  esac
  [ -d "$root" ] || return 1
  for candidate in "$root"/*/"$fork_sid.jsonl"; do
    [ -r "$candidate" ] || continue
    [ -z "$found" ] || return 1
    found="$candidate"
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
  transcript_size=$(file_size "$transcript_path")
  [[ "$transcript_size" =~ ^[0-9]+$ ]] || transcript_size=0
  while :; do
    cache_scan=$(
      tail -c "$scan_bytes" "$transcript_path" 2>/dev/null |
        {
          [ "$scan_bytes" -ge "$transcript_size" ] || IFS= read -r _ || :
          cat
        } |
        jq -Rrn --arg model "$model_id" '
          def ep: try (sub("\\.[0-9]+Z$"; "Z") | fromdate) catch null;
          def num: if type == "number" then . else 0 end;
          def buckets:
            [((.cache_creation? // {}) | to_entries[]?
              | select((.value | num) > 0)
              | .key | capture("ephemeral_(?<n>[0-9]+)(?<u>[mh])_")?
              | ((.n | tonumber) * (if .u == "m" then 60 else 3600 end)))] as $v
            | {ttl: ($v | if length == 0 then 0 else min end)};
          reduce (inputs | fromjson? | select(type == "object" and .isSidechain != true)) as $x (
            {la:0, pm:"", pg:-1, pa:0, lb:0, ats:0, am:"-", au:"-", afk:"", bk:0,
             cgap:0, ccr:0, ccc:0, cets:0, cpm:"", cem:"", cpa:0, chas:0, own:0,
             sawf:0, fas:"", fau:"", fot:0, lts:0, lm:"-", lbk:0, lu:"-", lfk:""};
            (($x.forkedFrom?.sessionId? // "") | tostring) as $fs
            | (($x.forkedFrom?.messageUuid? // "") | tostring) as $fu
            | ((($x.timestamp? // "") | if type == "string" then ep else null end)) as $ts
            | (if $fs != "" then
                 .sawf = 1 | .fas = $fs | (if $fu != "" then .fau = $fu else . end)
               elif .sawf == 1 and .fot == 0 and $ts != null then .fot = $ts
               else . end)
            | if $ts == null then .
              elif $x.type == "system" and $x.subtype == "compact_boundary" then
                (if $ts > .lb then .lb = $ts else . end)
              elif $x.type == "user" and ($x.isCompactSummary? != true) then
                (if .la > 0 and .pg < 0 then .pg = ($ts - .la) | .pa = .la else . end)
                | (if $ts > .la then .la = $ts else . end)
              elif $x.type == "assistant" and (($x.message?.model? // "") != "<synthetic>") then
                ($x.message?.usage? // null) as $u
                | (($u.cache_read_input_tokens? // 0) | num) as $cr
                | (($u.cache_creation_input_tokens? // 0) | num) as $cc
                | ($u | buckets) as $bs
                | (($x.message?.model? // "") | tostring) as $xm
                | (($x.uuid? // "") | tostring) as $xu
                | if ($u | type) != "object" or ($cr + $cc) <= 0 or $xm == "" then .
                  else
                    (if .pg >= 0 then
                       .cgap = .pg | .ccr = $cr | .ccc = $cc | .cets = $ts
                       | .cpm = .pm | .cem = $xm | .cpa = .pa | .chas = 1 | .pg = -1
                     else . end)
                    | (if $ts >= .lts then
                         .lts = $ts | .lm = $xm | .lbk = $bs.ttl
                         | .lu = (if $xu == "" then "-" else $xu end) | .lfk = $fs
                       else . end)
                    | (if $model != "" and $xm == $model and $ts >= .ats then
                         .ats = $ts | .am = $xm | .au = (if $xu == "" then "-" else $xu end)
                         | .afk = $fs | .bk = $bs.ttl
                       else . end)
                    | (if $fs == "" and $ts > .own then .own = $ts else . end)
                    | .pm = $xm
                    | (if $ts > .la then .la = $ts else . end)
                  end
              else . end)
          | [ (if .ats > 0 then 1 else 0 end), .ats, .am, .au,
              (.afk | if . == "" then "-" else . end), .bk,
              (if .lb > 0 and .lb >= .ats then 1 else 0 end),
              (if .chas == 1 and .cgap > 0 and .cpm != "" and .cpm == .cem
                  and (.lb == 0 or .lb <= .cpa or .lb >= .cets) then 1 else 0 end),
              .cets, .cgap, .ccr, .ccc,
              (if .own == 0 or (.lb > 0 and .own <= .lb) then 1 else 0 end),
              .lb, (.fau | if . == "" then "-" else . end), .fot,
              .lts, .lm, .lbk, .lu, (.lfk | if . == "" then "-" else . end) ]
          | map(tostring) | join("")' 2>/dev/null
    )
    if [ -n "$cache_scan" ]; then
      IFS=$'\x1f' read -r scan_found assist_ts assist_model assist_uuid fork_sid ttl_bucket \
        post_compact ev_valid ev_ts ev_gap ev_cr ev_cc ctx_stale boundary_ts fork_anchor_uuid \
        fork_own_ts latest_ts latest_model latest_ttl latest_uuid latest_fork <<< "$cache_scan" || :
    fi
    [ "$scan_found" = 1 ] && break
    if [ "$scan_bytes" -ge "$transcript_size" ]; then scan_complete=1; break; fi
    [ "$boundary_ts" -gt 0 ] 2>/dev/null && { scan_complete=1; break; }
    [ "$scan_bytes" -ge "$scan_max" ] && break
    if [ "$scan_bytes" -eq 262144 ] && [ "$saved_scan_bytes" -gt "$scan_bytes" ]; then
      scan_bytes="$saved_scan_bytes"
    else
      scan_bytes=$((scan_bytes * 4))
    fi
    [ "$scan_bytes" -gt "$scan_max" ] && scan_bytes="$scan_max"
  done
fi

for scan_num in assist_ts ttl_bucket post_compact ev_valid ev_ts ev_gap ev_cr ev_cc \
  ctx_stale boundary_ts fork_own_ts latest_ts latest_ttl; do
  [[ "${!scan_num}" =~ ^[0-9]+$ ]] || printf -v "$scan_num" %s 0
done
[[ "$fork_sid" =~ ^[A-Za-z0-9_-]+$ ]] || fork_sid="-"
[[ "$latest_fork" =~ ^[A-Za-z0-9_-]+$ ]] || latest_fork="-"
ctx_dim=""
[ "$ctx_stale" = 1 ] && ctx_dim=1

if [ "$scan_found" = 1 ] && [ "$fork_sid" = "-" ]; then
  if [ "$model_rec_ts" -eq "$assist_ts" ] && [ "$model_rec_uuid" = "$assist_uuid" ] \
     && [ -n "$model_rec_acct" ] && [ "$model_rec_acct" != "?" ]; then
    track_acct="$model_rec_acct"
  elif [ "$rec_ts" -eq "$assist_ts" ] \
       && { [ "$rec_model" = "-" ] || [ "$rec_model" = "$assist_model" ]; } \
       && [ -n "$rec_acct" ] && [ "$rec_acct" != "?" ]; then
    track_acct="$rec_acct"
  elif [ "$seen_acct" = "$warm_acct" ] && [ "$assist_ts" -gt "$seen_upto" ] 2>/dev/null; then
    track_acct="$warm_acct"
  else
    track_acct="?"
  fi
fi

if [ -n "$track" ] && [ "$latest_ts" -gt 0 ] && [ "$latest_fork" = "-" ]; then
  latest_acct="?"
  if [ "$rec_ts" -eq "$latest_ts" ] \
     && { [ "$rec_model" = "-" ] || [ "$rec_model" = "$latest_model" ]; } \
     && [ -n "$rec_acct" ] && [ "$rec_acct" != "?" ]; then
    latest_acct="$rec_acct"
  elif [ "$latest_model" = "$assist_model" ] && [ "$latest_ts" -eq "$assist_ts" ] \
       && [ -n "$track_acct" ] && [ "$track_acct" != "?" ]; then
    latest_acct="$track_acct"
  elif [ "$seen_acct" = "$warm_acct" ] && [ "$latest_ts" -gt "$seen_upto" ] 2>/dev/null; then
    latest_acct="$warm_acct"
  fi
  rec_ts="$latest_ts"; rec_acct="$latest_acct"; rec_ttl="$latest_ttl"
  rec_model="$latest_model"; rec_uuid="$latest_uuid"; rec_scan="$scan_bytes"
  seen_upto="$latest_ts"; seen_acct="$warm_acct"; track_ready=1
  if [ "$latest_model" = "$model_id" ] && [ -n "$model_track" ]; then
    if [ "$model_rec_ts" -ne "$latest_ts" ] || [ "$model_rec_acct" != "$latest_acct" ] \
       || [ "$model_rec_ttl" -ne "$latest_ttl" ] || [ "$model_rec_uuid" != "$latest_uuid" ] \
       || [ "$model_rec_scan" -ne "$scan_bytes" ]; then
      mkdir -p "$(dirname "$model_track")" 2>/dev/null
      printf 'v1 %s %s %s %s %s\n' "$latest_ts" "$latest_acct" "$latest_ttl" "$latest_uuid" "$scan_bytes" \
        > "$model_track.tmp.$$" 2>/dev/null && mv "$model_track.tmp.$$" "$model_track" 2>/dev/null \
        || rm -f "$model_track.tmp.$$" 2>/dev/null
    fi
    track_acct="$latest_acct"
  fi
fi

if [ -n "$track" ] && [ "$scan_found" = 0 ] && [ "$scan_complete" = 1 ] \
   && [ "$latest_ts" -eq 0 ]; then
  rec_ts=0; rec_acct="$warm_acct"; rec_ttl=0; rec_model="-"; rec_uuid="-"; rec_scan="$scan_bytes"
  seen_upto=0; seen_acct="$warm_acct"; track_ready=1
fi

if [ "$scan_found" = 1 ] && [ "$fork_sid" = "-" ] && [ -n "$model_track" ] \
   && [ -n "$track_acct" ] && [ "$track_acct" != "?" ] \
   && { [ "$model_rec_ts" -ne "$assist_ts" ] || [ "$model_rec_acct" != "$track_acct" ] \
        || [ "$model_rec_ttl" -ne "$ttl_bucket" ] || [ "$model_rec_uuid" != "$assist_uuid" ] \
        || [ "$model_rec_scan" -ne "$scan_bytes" ]; }; then
  mkdir -p "$(dirname "$model_track")" 2>/dev/null
  printf 'v1 %s %s %s %s %s\n' "$assist_ts" "$track_acct" "$ttl_bucket" "$assist_uuid" "$scan_bytes" \
    > "$model_track.tmp.$$" 2>/dev/null && mv "$model_track.tmp.$$" "$model_track" 2>/dev/null \
    || rm -f "$model_track.tmp.$$" 2>/dev/null
fi

warm_ts="$assist_ts"; warm_ttl="$ttl_bucket"; fork_state=none
if [ "$scan_found" = 1 ] && [ "$fork_sid" != "-" ] && [ "$fork_sid" != "$session_id" ]; then
  fork_state=unknown
  parent_file=""; parent_size=0; parent_mtime=0; parent_boundary=0
  parent_assist_ts=0; parent_assist_uuid="-"; parent_assist_ttl=0; parent_anchor_ts=0
  fork_cache=""; fork_cache_valid=0
  [ -n "$track" ] && fork_cache="$track.fork"
  fc1=""; fc2=""; fc3=""; fc4=""; fc5=""; fc6=""; fc7=""; fc8=""; fc9=""
  fc10=""; fc11=""; fc12=""; fc13=""
  if [ -n "$fork_cache" ] && [ -r "$fork_cache" ]; then
    IFS=$'\x1f' read -r fc1 fc2 fc3 fc4 fc5 fc6 fc7 fc8 fc9 fc10 fc11 fc12 fc13 \
      < "$fork_cache" 2>/dev/null || :
    if [ "$fc1" = v2 ] && [ "$fc2" = "$fork_sid" ] && [ "$fc3" = "$fork_anchor_uuid" ] \
       && [ "$fc4" = "$fork_own_ts" ] && [ -r "$fc5" ]; then
      parent_size=$(file_size "$fc5")
      parent_mtime=$(file_mtime "$fc5")
      if [ "$parent_size" = "$fc6" ] && [ "$parent_mtime" = "$fc7" ]; then
        parent_file="$fc5"; fork_state="$fc8"; parent_boundary="$fc9"
        parent_assist_ts="$fc10"; parent_assist_uuid="$fc11"; parent_assist_ttl="$fc12"
        parent_anchor_ts="$fc13"
        fork_cache_valid=1
      fi
    fi
  fi
  if [ "$fork_cache_valid" = 0 ] && [ "$fork_anchor_uuid" != "-" ]; then
    parent_file=$(resolve_parent_transcript 2>/dev/null) || parent_file=""
    if [ -r "$parent_file" ]; then
      parent_size=$(file_size "$parent_file")
      parent_mtime=$(file_mtime "$parent_file")
      [[ "$parent_size" =~ ^[0-9]+$ ]] || parent_size=0
      [[ "$parent_mtime" =~ ^[0-9]+$ ]] || parent_mtime=0
      parent_bytes="$parent_size"
      [ "$parent_bytes" -gt "$scan_max" ] 2>/dev/null && parent_bytes="$scan_max"
      parent_tail=$(
        tail -c "$parent_bytes" "$parent_file" 2>/dev/null |
          {
            [ "$parent_bytes" -ge "$parent_size" ] || IFS= read -r _ || :
            cat
          } |
          jq -Rrn --arg anchor "$fork_anchor_uuid" --arg model "$model_id" \
            --argjson cutoff "$fork_own_ts" '
            def ep: try (sub("\\.[0-9]+Z$"; "Z") | fromdate) catch null;
            def num: if type == "number" then . else 0 end;
            def buckets:
              [((.cache_creation? // {}) | to_entries[]?
                | select((.value | num) > 0)
                | .key | capture("ephemeral_(?<n>[0-9]+)(?<u>[mh])_")?
                | ((.n | tonumber) * (if .u == "m" then 60 else 3600 end)))] as $v
              | ($v | if length == 0 then 0 else min end);
            reduce (inputs | fromjson? | select(type == "object" and .isSidechain != true)) as $x (
              {seen:0,last:"",boundary:0,ats:0,au:"-",ttl:0,anchor_ts:0};
              ((($x.timestamp? // "") | if type == "string" then ep else null end)) as $ts
              | (($x.uuid? // "") | tostring) as $uuid
              | (if $uuid == $anchor and $ts != null then .anchor_ts = $ts else . end)
              | (if $ts != null and $x.type == "system" and $x.subtype == "compact_boundary"
                   and $ts > .boundary then .boundary = $ts else . end)
              | (if $ts != null and $x.type == "assistant"
                   and (($x.message?.model? // "") == $model)
                   and (($x.message?.model? // "") != "<synthetic>") then
                   ($x.message?.usage? // null) as $u
                   | (($u.cache_read_input_tokens? // 0) | num) as $cr
                   | (($u.cache_creation_input_tokens? // 0) | num) as $cc
                   | if ($u | type) == "object" and ($cr + $cc) > 0 and $ts >= .ats then
                       .ats = $ts | .au = (if $uuid == "" then "-" else $uuid end)
                       | .ttl = ($u | buckets)
                     else . end
                 else . end)
              | if $uuid == "" or ($cutoff > 0 and $ts != null and $ts > $cutoff) then .
                else .last = $uuid | (if $uuid == $anchor then .seen = 1 else . end)
                end)
            | [.seen, .last, .boundary, .ats, .au, .ttl, .anchor_ts] | @tsv' 2>/dev/null
      )
      parent_seen=""; parent_last=""
      IFS=$'\t' read -r parent_seen parent_last parent_boundary parent_assist_ts \
        parent_assist_uuid parent_assist_ttl parent_anchor_ts <<< "$parent_tail" || :
      if [ "$parent_bytes" -ge "$parent_size" ] && [ "$parent_seen" = 1 ] \
         && [ "$parent_last" = "$fork_anchor_uuid" ]; then
        fork_state=tail
      elif [ "$parent_bytes" -ge "$parent_size" ]; then
        fork_state=mid
      else
        fork_state=unknown
      fi
      if [ -n "$fork_cache" ]; then
        mkdir -p "$(dirname "$fork_cache")" 2>/dev/null
        printf 'v2\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
          "$fork_sid" "$fork_anchor_uuid" "$fork_own_ts" "$parent_file" "$parent_size" \
          "$parent_mtime" "$fork_state" "$parent_boundary" "$parent_assist_ts" \
          "$parent_assist_uuid" "$parent_assist_ttl" "$parent_anchor_ts" \
          > "$fork_cache.tmp.$$" 2>/dev/null \
          && mv "$fork_cache.tmp.$$" "$fork_cache" 2>/dev/null || rm -f "$fork_cache.tmp.$$" 2>/dev/null
      fi
    fi
  fi
  for parent_num in parent_boundary parent_assist_ts parent_assist_ttl parent_anchor_ts; do
    [[ "${!parent_num}" =~ ^[0-9]+$ ]] || printf -v "$parent_num" %s 0
  done
  if [ "$fork_state" = tail ]; then
    ptrack="$statusline_cache_dir/cache-ttl-track-$fork_sid"
    pmodel_track="$ptrack.model-${model_key:0:80}"
    p1=""; p2=""; p3=""; p4=""; p5=""; p6=""; p7=""
    pm1=""; pm2=""; pm3=""; pm4=""; pm5=""; pm6=""
    [ -r "$ptrack" ] && { read -r p1 p2 p3 p4 p5 p6 p7 < "$ptrack" 2>/dev/null || :; }
    [ -r "$pmodel_track" ] && { read -r pm1 pm2 pm3 pm4 pm5 pm6 < "$pmodel_track" 2>/dev/null || :; }
    if [ "$pm1" = v1 ] && [ "$pm2" = "$parent_assist_ts" ] \
       && [ "$pm5" = "$parent_assist_uuid" ] && [ -n "$pm3" ] && [ "$pm3" != "?" ]; then
      track_acct="$pm3"
    elif [ "$p1" = v2 ] && [ "$p2" = "$parent_assist_ts" ] && [ "$p6" = "$model_id" ] \
         && [ "$p7" = "$parent_assist_uuid" ] && [ -n "$p3" ] && [ "$p3" != "?" ]; then
      track_acct="$p3"
    else
      track_acct="?"
    fi
    warm_ts="$parent_assist_ts"; warm_ttl="$parent_assist_ttl"
    if [ "$parent_anchor_ts" -le 0 ] 2>/dev/null; then
      track_acct="?"
    elif [ "$parent_boundary" -gt 0 ] 2>/dev/null \
       && [ "$parent_boundary" -ge "$parent_anchor_ts" ] 2>/dev/null; then
      post_compact=1
    fi
  else
    track_acct="?"
  fi
  if [ -n "$track" ]; then
    rec_ts="$latest_ts"; rec_acct="$track_acct"; rec_ttl="$latest_ttl"
    rec_model="$latest_model"; rec_uuid="$latest_uuid"; rec_scan="$scan_bytes"
    seen_upto="$latest_ts"; seen_acct="$warm_acct"; track_ready=1
  fi
fi

shared_bounds_lock="$learned_file.lock"
bounds_need_decay=""
if [ -r "$learned_file" ] && read -r learned_probe < "$learned_file" 2>/dev/null \
   && [[ "$learned_probe" =~ \"updated_at\":([0-9]+) ]] \
   && [ $((now - BASH_REMATCH[1])) -gt 604800 ]; then
  bounds_need_decay=1
fi
learn_event=""
if [ "$ev_valid" = 1 ] && [ "$ev_ts" -gt "$learned_upto" ] 2>/dev/null \
   && [ -n "$track_acct" ] && [ "$track_acct" != "?" ] && [ "$track_acct" = "$warm_acct" ]; then
  learn_event=1
fi
if [ -n "$learn_event" ] || [ -n "$bounds_need_decay" ]; then
  mkdir -p "$(dirname "$learned_file")" 2>/dev/null
  lock_tries=0
  while ! snapshot_lock_acquire "$shared_bounds_lock"; do
    lock_tries=$((lock_tries + 1))
    [ "$lock_tries" -lt 20 ] || break
    sleep 0.01
  done
  if [ -d "$shared_bounds_lock" ] && [ "$lock_tries" -lt 20 ]; then
    ttl_floor=0; ttl_ceiling=""; learned_at=""; bounds_changed=""
    if [ -r "$learned_file" ] && read -r learned_raw < "$learned_file" 2>/dev/null; then
      [[ "$learned_raw" =~ \"observed_floor_s\":([0-9]+) ]] && ttl_floor="${BASH_REMATCH[1]}"
      [[ "$learned_raw" =~ \"observed_ceiling_s\":([0-9]+) ]] && ttl_ceiling="${BASH_REMATCH[1]}"
      [[ "$learned_raw" =~ \"updated_at\":([0-9]+) ]] && learned_at="${BASH_REMATCH[1]}"
    fi
    if [[ "$learned_at" =~ ^[0-9]+$ ]] && [ $((now - learned_at)) -gt 604800 ]; then
      ttl_floor=0; ttl_ceiling=""; bounds_changed=1
    fi
    if [ -n "$learn_event" ]; then
      if [ "$ev_cr" -ge 1000 ] 2>/dev/null && [ "$ev_cr" -ge "$ev_cc" ] 2>/dev/null; then
        [ "$ev_gap" -gt "$ttl_floor" ] 2>/dev/null && { ttl_floor=$ev_gap; bounds_changed=1; }
        if [ -n "$ttl_ceiling" ] && [ "$ev_gap" -gt "$ttl_ceiling" ] 2>/dev/null; then ttl_ceiling=""; bounds_changed=1; fi
      elif [ "$ev_cr" -lt 1000 ] 2>/dev/null && [ "$ev_cc" -ge 20000 ] 2>/dev/null && [ "$ev_gap" -ge 120 ] 2>/dev/null; then
        if [ -z "$ttl_ceiling" ] || [ "$ev_gap" -lt "$ttl_ceiling" ] 2>/dev/null; then ttl_ceiling=$ev_gap; bounds_changed=1; fi
      fi
    fi
    if [ -n "$bounds_changed" ]; then
      ceil_json=null; [ -n "$ttl_ceiling" ] && ceil_json="$ttl_ceiling"
      printf '{"observed_floor_s":%s,"observed_ceiling_s":%s,"updated_at":%s}\n' \
        "$ttl_floor" "$ceil_json" "$now" > "$learned_file.tmp.$$" 2>/dev/null \
        && mv "$learned_file.tmp.$$" "$learned_file" 2>/dev/null || rm -f "$learned_file.tmp.$$" 2>/dev/null
    fi
    [ -n "$learn_event" ] && learned_upto="$ev_ts"
    rmdir "$shared_bounds_lock" 2>/dev/null
  fi
fi

if [ -n "$track" ] && [ "$track_ready" = 1 ] \
   && { [ "$t1" != v2 ] || [ "$rec_ts" != "${t2:-}" ] || [ "$rec_acct" != "${t3:-}" ] \
        || [ "$learned_upto" != "${t4:-}" ] || [ "$rec_ttl" != "${t5:-}" ] \
        || [ "$rec_model" != "${t6:-}" ] || [ "$rec_uuid" != "${t7:-}" ] \
        || [ "$rec_scan" != "${t8:-}" ] || [ "$seen_upto" != "${t9:-}" ] \
        || [ "$seen_acct" != "${t10:-}" ]; }; then
  mkdir -p "$(dirname "$track")" 2>/dev/null
  printf 'v2 %s %s %s %s %s %s %s %s %s\n' "$rec_ts" "${rec_acct:-?}" "$learned_upto" \
    "$rec_ttl" "$rec_model" "$rec_uuid" "$rec_scan" "$seen_upto" "$seen_acct" \
    > "$track.tmp.$$" 2>/dev/null && mv "$track.tmp.$$" "$track" 2>/dev/null \
    || rm -f "$track.tmp.$$" 2>/dev/null
fi

cache_state=unknown
if [ -z "$model_id" ]; then
  cache_state=unknown
elif [ "$scan_found" = 0 ]; then
  if [ "$scan_complete" = 1 ]; then cache_state=cold; fi
elif [ "$post_compact" = 1 ]; then
  cache_state=cold
elif [ "$warm_ttl" -le 0 ] 2>/dev/null; then
  cache_state=unknown
elif [ "$warm_ts" -le "$now" ] 2>/dev/null \
     && [ "$((now - warm_ts))" -ge "$warm_ttl" ] 2>/dev/null; then
  cache_state=cold
elif [ -z "$track_acct" ] || [ "$track_acct" = "?" ]; then
  cache_state=unknown
elif [ "$track_acct" != "$warm_acct" ]; then
  cache_state=cold
elif [ "$warm_ts" -le "$now" ] 2>/dev/null && [ "$((now - warm_ts))" -lt "$warm_ttl" ] 2>/dev/null; then
  cache_state=warm
else
  cache_state=cold
fi

ctx_tokens_part=""
if [ "$cache_state" = warm ]; then
  death_time=$(TZ=Europe/Kyiv date -r "$((warm_ts + warm_ttl))" +%H:%M 2>/dev/null)
  if [ -n "$death_time" ]; then
    ctx_tokens_part=" ${DIM}→${death_time}${RESET}"
    [ "$warm_ttl" -lt 3600 ] 2>/dev/null && ctx_tokens_part="${ctx_tokens_part}${YELLOW}↓5m${RESET}"
  fi
elif [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
  ctx_tokens_k=$(( (ctx_tokens + 500) / 1000 ))
  if [ "$ctx_tokens" -lt 90000 ]; then tok_color="$DIM"
  elif [ "$ctx_tokens" -lt 300000 ]; then tok_color="$YELLOW"
  else tok_color="$RED"
  fi
  if [ "$cache_state" = unknown ]; then
    ctx_tokens_part=" ${tok_color}? ${ctx_tokens_k}k${RESET}"
  else
    ctx_tokens_part=" ${tok_color}${ctx_tokens_k}k${RESET}"
  fi
elif [ "$cache_state" = unknown ]; then
  ctx_tokens_part=" ${DIM}?${RESET}"
fi
cb_part=""
if [ -n "$acct" ] && [ "$acct" != main ]; then
  cb_part=" ${DIM}cb:${RESET}${MAGENTA}${acct}${RESET}"
fi

worker=""; codex_effort=""; sonnet_effort=""; codex_profile=""; claudeb_profile=""; gemini_profile=""
claudeb_model=""; claudeb_effort=""; gemini_model=""; gemini_effort=""
worker_file="$HOME/.claude/worker-model"
if [ -f "$worker_file" ]; then
  while IFS='=' read -r wkey wval; do
    case "$wkey" in
      worker) worker=$wval ;;
      codex_effort) codex_effort=$wval ;;
      sonnet_effort) sonnet_effort=$wval ;;
      codex_profile) codex_profile=$wval ;;
      claudeb_profile) claudeb_profile=$wval ;;
      gemini_profile) gemini_profile=$wval ;;
      claudeb_model) claudeb_model=$wval ;;
      claudeb_effort) claudeb_effort=$wval ;;
      gemini_model) gemini_model=$wval ;;
      gemini_effort) gemini_effort=$wval ;;
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

# Derive codex model short label from ~/.codex/config.toml; fallback "sol" defined here.
codex_model_short_label() {
  local toml="${1:-$HOME/.codex/config.toml}" label=""
  [ -r "$toml" ] && label=$(grep -m1 '^model[[:space:]]*=' "$toml" 2>/dev/null \
    | sed 's/.*"\([^"]*\)".*/\1/; s/.*-//')
  [[ "$label" =~ ^[A-Za-z0-9]+$ ]] || label=sol
  printf '%s' "$label"
}

load_worker_pick_prediction() {
  local pick_acct=$acct pick_cache pick_mtime
  { [ "$pick_acct" = "-" ] || [ -z "$pick_acct" ]; } && pick_acct=main
  pick_cache="$HOME/.cache/worker-pick.line.$pick_acct"
  pick_mtime=$(file_mtime "$pick_cache" 2>/dev/null)
  if ! [[ "$pick_mtime" =~ ^[0-9]+$ ]] || [ "$((now - pick_mtime))" -gt 90 ]; then
    ("$HOME/.local/bin/worker-pick" >/dev/null 2>&1 &)
  fi
  worker_pick_prediction=""
  [ -r "$pick_cache" ] && IFS= read -r worker_pick_prediction <"$pick_cache"
}

case "$worker" in
  codex)
    wname=codex
    wtier="$(codex_model_short_label)·$(abbrev_tier "${codex_effort:-medium}")"
    if [ -n "$codex_profile" ]; then
      wpin=$codex_profile
    else
      load_worker_pick_prediction
      wsel=$(printf '%s\n' "$worker_pick_prediction" |
        sed -nE 's/^cx.([a-z0-9][a-z0-9-]*)·[^· ]+·[^· ]+( .*)?$/\1/p')
      [ -n "$wsel" ] || wsel="?"
    fi
    ;;
  claudeb)
    wname=cb
    wtier="$(abbrev_model "${claudeb_model:-opus}")·$(abbrev_tier "${claudeb_effort:-high}")"
    if [ -n "$claudeb_profile" ]; then
      wpin=$claudeb_profile
    else
      # The account a spawn will use is worker-pick's choice, not .claudeb-state (which
      # only records the last profile launched and would render a stale prediction).
      load_worker_pick_prediction
      wsel=$(printf '%s\n' "$worker_pick_prediction" |
        sed -nE 's/^(.* )?cb[~@]([A-Za-z0-9_][A-Za-z0-9._-]*)·[^·]+·[^·]+( .*)?$/\2/p')
      [ -n "$wsel" ] || wsel="?"
    fi
    ;;
  gemini)
    wname=gem
    if [ -n "$gemini_profile" ]; then
      wpin=$gemini_profile
    else
      load_worker_pick_prediction
      wsel=$(printf '%s\n' "$worker_pick_prediction" |
        sed -nE 's/^.* gx.(main|[a-z0-9][a-z0-9-]*)·[^·]+·[^·]+$/\1/p')
      [ -n "$wsel" ] || wsel="?"
    fi
    wtier="${gemini_model:-pro}·$(abbrev_tier "${gemini_effort:-high}")"
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
    load_worker_pick_prediction
    auto_line=$worker_pick_prediction
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
  ports_cache="$statusline_cache_dir/ports-$session_id"
  ports_mtime=$(file_mtime "$ports_cache" 2>/dev/null)
  if { ! [[ "$ports_mtime" =~ ^[0-9]+$ ]] || [ "$((now - ports_mtime))" -gt 15 ]; } && [ -x "$probe_bin" ]; then
    ( "$probe_bin" "$session_id" "$PPID" "$active_top" >/dev/null 2>&1 & ) 2>/dev/null
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

review_tier=""
if [ -n "$active_top" ]; then
  review_probe_self="$0"
  [ -L "$review_probe_self" ] && review_probe_self=$(readlink "$review_probe_self")
  case "$review_probe_self" in /*) ;; *) review_probe_self="$(dirname "$0")/$review_probe_self" ;; esac
  review_bench_bin="${STATUSLINE_REVIEW_BENCH_BIN:-$(dirname "$review_probe_self")/review-bench}"
  review_cache_dir="$statusline_cache_dir"
  # Keyed on the repository root, so prompting from two subdirectories of one repo shares the
  # cache instead of starting a second background refresh; the basename keeps a checksum
  # collision from showing one repository's tier under another's name.
  review_repo_key="$(basename "$active_top")-$(printf '%s' "$active_top" | cksum 2>/dev/null | awk '{print $1}')"
  if [ -x "$review_bench_bin" ] && [[ "$review_repo_key" =~ -[0-9]+$ ]]; then
    review_cache="$review_cache_dir/review-tier-$review_repo_key"
    review_lock="$review_cache.lock"
    review_mtime=$(file_mtime "$review_cache" 2>/dev/null)
    if { ! [[ "$review_mtime" =~ ^[0-9]+$ ]] || [ "$((now - review_mtime))" -gt 5 ]; }; then
      mkdir -p "$review_cache_dir" 2>/dev/null
      review_lock_mtime=$(file_mtime "$review_lock" 2>/dev/null)
      if [ ! -d "$review_lock" ] ||
        { [[ "$review_lock_mtime" =~ ^[0-9]+$ ]] && [ "$((now - review_lock_mtime))" -gt 120 ]; }; then
        (
          snapshot_lock_acquire "$review_lock" || exit 0
          trap 'rmdir "$review_lock" 2>/dev/null' EXIT
          timeout_bin=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
          suggestion=""
          if [ -n "$timeout_bin" ]; then
            suggestion=$("$timeout_bin" 3 "$review_bench_bin" suggest --repo "$active_top" 2>/dev/null) || suggestion=""
          else
            # No timeout binary on a stock macOS, and skipping the probe there would hide the
            # segment forever. Job control makes the probe its own process group, so the watchdog
            # can take its children with it — review-bench spawns git, and killing only the parent
            # leaves a hung grandchild for the next render to queue behind.
            set -m
            "$review_bench_bin" suggest --repo "$active_top" >"$review_cache.out" 2>/dev/null &
            review_probe_pid=$!
            set +m
            ( sleep 3; kill -TERM -"$review_probe_pid" 2>/dev/null ) >/dev/null 2>&1 &
            review_watchdog_pid=$!
            wait "$review_probe_pid" 2>/dev/null && suggestion=$(cat "$review_cache.out" 2>/dev/null)
            kill "$review_watchdog_pid" 2>/dev/null
            rm -f "$review_cache.out" 2>/dev/null
          fi
          tier=$(printf '%s\n' "$suggestion" | sed -nE 's/^tier: (T[0-3])$/\1/p' | tail -n1)
          tmp_review_cache="$review_cache.tmp.${BASHPID:-$$}"
          printf '%s\n' "$tier" > "$tmp_review_cache" 2>/dev/null &&
            mv -f "$tmp_review_cache" "$review_cache" 2>/dev/null ||
            rm -f "$tmp_review_cache" 2>/dev/null
        ) >/dev/null 2>&1 &
      fi
    fi
    if [[ "$review_mtime" =~ ^[0-9]+$ ]] && [ "$((now - review_mtime))" -le 15 ]; then
      IFS= read -r review_tier < "$review_cache" 2>/dev/null || review_tier=""
      case "$review_tier" in
        T[0-3]) ;;
        *) review_tier="" ;;
      esac
    fi
  fi
fi

review_part=""
if [ -n "$active_top" ]; then
  receipt_reviewed=""
  receipt_errored=0
  receipt_panel=""
  # Already resolved with the repository identity above in all but the odd case
  # where git_dir resolved and active_top did not come from it.
  [ -n "$active_common" ] || active_common=$(git_common_dir "$active_top" 2>/dev/null)
  receipt_name=$(receipt_file_name "$active_top" 2>/dev/null)
  # A run in flight owns the slot: review-bench writes one progress file per run, and while it
  # lives the label reports that panel instead of the receipt verdict. Liveness is derived here,
  # never declared by the writer — the file survives kill -9, a crash and a closed terminal, so
  # the pid must be alive AND the process holding it must have started no later than the file's
  # last write, which a pid reused after that run died cannot satisfy.
  progress_done=""
  progress_total=""
  progress_tier=""
  progress_max=""
  progress_late=""
  progress_newest=""
  progress_dir="$worker_stats_dir/progress"
  if [ -n "$active_common" ] && [ -d "$progress_dir" ]; then
    # Every file is read and matched on the repository recorded inside it, never on its name:
    # review-bench keys the name on the path it was handed, so a run started from a subdirectory
    # writes a name this render cannot predict. The second pattern covers a repository whose own
    # directory name begins with a dot; toggling dotglob instead would leave the option set for
    # the rest of the render if anything ever returns early from this loop.
    for progress_file in "$progress_dir"/*.json "$progress_dir"/.*.json; do
      [ -f "$progress_file" ] || continue
      progress_mtime=$(file_mtime "$progress_file" 2>/dev/null)
      [[ "$progress_mtime" =~ ^[0-9]+$ ]] || continue
      # A run whose slowest cell is still out writes nothing for as long as that cell takes,
      # so there is no tight staleness window here; this is only the wall that stops a wedged
      # process from holding the segment for a day.
      [ "$((now - progress_mtime))" -le 7200 ] || continue
      progress_values=$(jq -er --argjson now "$now" '
        select(type == "object"
          and (.repo | type) == "string"
          and (.pid | type) == "number"
          and (.pid | floor) == .pid
          and .pid > 0
          and (.cells | type) == "array"
          and (.done | type) == "array"
          and (.cells | length) > 0
          and (.done | length) <= (.cells | length)
          and (.started | type) == "string"
          and ((.tier | type) == "string" or .tier == null)
          and ((.max | type) == "boolean" or .max == null))
        | . as $run
        | (if (($run.started_epoch | type) == "number"
                   and ($run.started_epoch | floor) == $run.started_epoch
                   and $run.started_epoch > 0)
           then $run.started_epoch else null end) as $started_epoch
        | (if (($run.expected | type) == "object") then $run.expected else {} end) as $expected
        | ([
            $run.cells[] as $cell
            | select(($cell | type) == "string")
            | select(($run.done | index($cell)) == null)
            | $expected[$cell]
            | select(type == "number" and . >= 0) as $expected_ms
            | select($started_epoch != null
                and (($now - $started_epoch) * 1000
                     > ([3 * $expected_ms, 120000] | max)))
          ] | length > 0) as $late
        | [.repo, (.pid | tostring), (.tier // ""), (if .max then "max" else "" end),
           (.done | length | tostring), (.cells | length | tostring), .started,
           (if $late then "late" else "" end)]
        | join("\u001f")
      ' "$progress_file" 2>/dev/null) || continue
      IFS=$'\x1f' read -r progress_repo progress_pid progress_run_tier progress_run_max \
        progress_run_done progress_run_total progress_started progress_run_late \
        <<< "$progress_values"
      kill -0 "$progress_pid" 2>/dev/null || continue
      progress_start=$(process_start_epoch "$progress_pid" "$now") || continue
      # The slack absorbs ps's whole-second resolution, not a real gap: pids are handed out
      # sequentially and wrap near 100k, so a reuse this close to the last write cannot happen.
      [ "$progress_start" -le "$((progress_mtime + 5))" ] || continue
      [ "$(git_common_dir "$progress_repo" 2>/dev/null)" = "$active_common" ] || continue
      case "$progress_run_tier" in
        T[0-3]) ;;
        *) progress_run_tier="" ;;
      esac
      if [ -z "$progress_newest" ] || [[ "$progress_started" > "$progress_newest" ]]; then
        progress_newest=$progress_started
        progress_done=$progress_run_done
        progress_total=$progress_run_total
        progress_tier=$progress_run_tier
        progress_max=$progress_run_max
        progress_late=$progress_run_late
      fi
    done
  fi
  if [ -n "$progress_total" ]; then
    progress_label="review"
    # The max panel is a variant of a tier, never a run of its own: --max is refused without
    # --tier, so an untiered run carrying it is a corrupt file and its mark is dropped with the
    # tier rather than rendered as a panel size nothing names.
    if [ -n "$progress_tier" ]; then
      progress_label="${progress_label} ${progress_tier}"
      [ -n "$progress_max" ] && progress_label="${progress_label} ${progress_max}"
    fi
    progress_label="${progress_label} ${progress_done}/${progress_total}"
    if [ -n "$progress_late" ]; then
      review_part=" ${RED}│ ${progress_label}${RESET}"
    else
      review_part=" ${sep} ${progress_label}"
    fi
  fi
fi

if [ -n "$active_top" ] && [ -z "$progress_total" ]; then
  receipt_file="$worker_stats_dir/receipts/$receipt_name"
  receipt_values=$(jq -er '
    select(type == "object"
      and (.repo | type) == "string"
      and (.tree | type) == "string"
      and (.commit | type) == "string"
      and (.run_id | type) == "string"
      and (.ts | type) == "string"
      and (.errored | type) == "number"
      and .errored >= 0
      and (.errored | floor) == .errored)
    | [.repo,.tree,.commit,.run_id,.ts,(.errored | tostring),
       (if (.panel | type) == "number" and (.panel | floor) == .panel and .panel > 0
        then (.panel | tostring) else "" end)]
    | join("\u001f")
  ' "$receipt_file" 2>/dev/null)
  if [ -n "$receipt_values" ]; then
    IFS=$'\x1f' read -r receipt_repo receipt_tree receipt_commit receipt_run_id receipt_ts \
      receipt_errored receipt_panel <<< "$receipt_values"
    receipt_common=$(git_common_dir "$receipt_repo" 2>/dev/null)
    if [ -n "$active_common" ] && [ "$receipt_common" = "$active_common" ]; then
      head_tree=$(git -C "$active_top" rev-parse 'HEAD^{tree}' 2>/dev/null)
      if [ -n "$head_tree" ] &&
        { { [ "$receipt_tree" = "$head_tree" ] && [ "$git_status_rc" -eq 0 ] &&
            [ -z "$git_status" ]; } ||
          worktree_matches_tree "$active_top" "$receipt_tree"; }; then
        receipt_reviewed=1
      fi
    fi
  fi
  if [ -n "$receipt_reviewed" ]; then
    # A silent cell is a coverage loss worth a mark only when it took a real share of the panel
    # with it: one rater out of nine that mangled its own output format is noise, and a label
    # that answers "not everybody reported" to that is a label nobody can ever turn off.
    # A receipt from before the panel size was recorded keeps the old any-error behaviour.
    if [ "$receipt_errored" -gt 0 ] &&
      { [ -z "$receipt_panel" ] || [ "$((receipt_errored * 3))" -gt "$receipt_panel" ]; }; then
      review_part=" ${sep} ${DIM}review${RESET}"
    fi
  else
    review_part=" ${sep} review"
    [ -n "$review_tier" ] && review_part="${review_part} ${review_tier}"
  fi
fi

# Two lines: identity/work (model, account, dir/branch/diff, workers) on top,
# usage (ctx, 5h, weekly, fable, cost) below.
line1="${CYAN}${model}${model_suffix}${RESET}${fast_part}${cb_part} ${sep} ${dir_part}${branch_part}${ports_part}${review_part}${worker_part}"

line2="ctx $(pct_colored "$ctx_pct" "$ctx_dim" 40)${ctx_tokens_part} ${sep} 5h $(pct_colored "$h5_pct" "$h5_dim")${h5_arrow} ${sep} wk $(pct_colored "$wk_pct" "$wk_dim")${wk_arrow}${fable_part}"

if [ -n "$cost_raw" ]; then
  line2="${line2} ${sep} ${DIM}\$$(LC_ALL=C printf '%.2f' "$cost_raw")${RESET}"
fi

printf '%s\n%s' "$line1" "$line2"
