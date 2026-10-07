#!/usr/bin/env bash
# Claude Code status line: model | dir/branch/uncommitted-diff | ports | pin ‖ ctx % | 5h/weekly/fable limits | cost.
# rate_limits is absent from some renders and idle sessions re-send their last
# copy forever; every path renders from a stamped merged cache (statusline-cache-rl
# for main, limits/<acct>.json for claudeb accounts — ~/.claude-profiles/README.md),
# never from raw headers alone.
# Runs every 5s even while idle: GIT_OPTIONAL_LOCKS=0 keeps renders off index.lock.
# `env bash` resolves to macOS bash 3.2 when PATH lists /bin before Homebrew; this script needs bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  for modern_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$modern_bash" ] && "$modern_bash" -c '[ "${BASH_VERSINFO[0]}" -ge 5 ]' && exec "$modern_bash" "$0" "$@"
  done
  echo "statusline: bash 5 required (found $BASH_VERSION)"
  exit 0
fi
{
statusline_start_us=${EPOCHREALTIME//[!0-9]/}
export GIT_OPTIONAL_LOCKS=0

IFS= read -r -d '' input || :
statusline_cache_dir="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}"
cache_rl="$HOME/.claude/statusline-cache-rl"
acct="${CLAUDE_LIMITS_ACCOUNT:-}"
if [ -z "$acct" ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
    acct=${CLAUDE_CONFIG_DIR%"${CLAUDE_CONFIG_DIR##*[!/]}"}
    acct=${acct##*/}; acct=${acct:-/}
  else
    acct=main
  fi
fi
claudeb_dir="${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}"
account_cache_dir="$claudeb_dir/limits"
account_cache="$account_cache_dir/$acct.json"
limits_file="${LLM_LIMITS_FILE:-$HOME/.llm-limits.json}"

# Never $0: `bash bin/statusline.sh` would double the directory, and the harness may invoke a
# symlink — realpath resolves both to the script's real home.
# rmdir and realpath loadables, never mkdir's: its -p chmods every existing parent and fails on /var.
statusline_loadables="${BASH%/bin/*}/lib/bash"
enable -f "$statusline_loadables/rmdir" rmdir 2>/dev/null
if ! { enable -f "$statusline_loadables/realpath" realpath 2>/dev/null &&
  realpath -a statusline_self "${BASH_SOURCE[0]}" >/dev/null 2>&1; }; then
  statusline_self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) || statusline_self="${BASH_SOURCE[0]}"
fi
statusline_dir=${statusline_self%/*}
. "$statusline_dir/../share/limits-view.sh"
. "$statusline_dir/../share/codex-accounts.sh"
. "$statusline_dir/../tests/lib/suite-journal.sh" --lib
. "$statusline_dir/../share/statusline-probe.sh"

statusline_parent_dir() {
  local path="$1"
  while [[ "$path" = */ && "$path" != / ]]; do path=${path%/}; done
  case "$path" in
    */*) path=${path%/*}
         while [[ "$path" = */ && "$path" != / ]]; do path=${path%/}; done
         statusline_parent=${path:-/} ;;
    *) statusline_parent=. ;;
  esac
}

# The loadable replaces a stat fork per call where this bash ships it; -L is lstat, as the stat(1)
# fallbacks are. Once enabled it shadows stat(1) for the whole script.
if enable -f "${BASH%/bin/*}/lib/bash/stat" stat 2>/dev/null; then
  file_stat_field() { local -A st; stat -L -A st "$2" 2>/dev/null && printf '%s' "${st[$1]}"; }
  file_mtime() { file_stat_field mtime "$1"; }
  file_inode() { file_stat_field inode "$1"; }
  file_size() { file_stat_field size "$1"; }
  file_stat_to() { # var field path
    local -A st
    stat -L -A st "$3" 2>/dev/null || { printf -v "$1" ''; return 1; }
    printf -v "$1" '%s' "${st[$2]}"
  }
else
  file_mtime() {
    [ -e "$1" ] || [ -L "$1" ] || return 1
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
  }
  file_inode() {
    stat -f %i "$1" 2>/dev/null || stat -c %i "$1" 2>/dev/null
  }
  file_size() {
    stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null
  }
  file_stat_to() { # var field path
    local value rc
    value=$("file_$2" "$3"); rc=$?
    printf -v "$1" '%s' "$value"
    return "$rc"
  }
fi
file_mtime_to() { file_stat_to "$1" mtime "$2"; }
file_size_to() { file_stat_to "$1" size "$2"; }
ensure_dir() { [ -d "$1" ] || mkdir -p "$1"; }

# Stock macOS ships neither `timeout` nor `gtimeout`, and a probe with no deadline outlives the 120s
# after which its lock counts as dead — so a second probe starts while the first still walks. An
# EMPTY STATUSLINE_TIMEOUT_BIN forces the watchdog branch; unset means "find one".
run_bounded() { # seconds command...
  local secs="$1" bin pid killer
  shift
  bin="${STATUSLINE_TIMEOUT_BIN-$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)}"
  if [ -n "$bin" ]; then
    "$bin" "$secs" "$@"
    return 0
  fi
  "$@" &
  pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid" 2>/dev/null
  kill "$killer" 2>/dev/null
  return 0
}

snapshot_lock_acquire() {
  local lock="$1" now mtime
  mkdir "$lock" 2>/dev/null && return 0
  now=$EPOCHSECONDS
  file_mtime_to mtime "$lock" || return 1
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  [ "$((now - mtime))" -gt 120 ] || return 1
  rmdir "$lock" 2>/dev/null || return 1
  mkdir "$lock" 2>/dev/null
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

# Where both review journals live: ONE directory per git FAMILY, the common git dir
# (docs/shared-invariants.md row `bd`). Resolved once for every cache key that watches a journal —
# keyed off a worktree's own git dir instead, a key goes blind to the edits a sibling checkout of
# the same project folds into the file the answer was actually read from.
journal_dir() { # var toplevel
  if [ "$2" = "$active_top" ]; then printf -v "$1" '%s' "$active_common"
  elif [ "$2" = "$project_top" ]; then printf -v "$1" '%s' "$project_common"
  else printf -v "$1" '%s' "$(git -C "$2" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; fi
}

# Keyed per TOP: follows the shown tree. Off the render path: pricing walks every diff of the family,
# so an answer whose key still holds waits 300s and a moved key at least 15s. The key carries the
# shown tree's HEAD and diff counters; a sibling checkout's edits reach it by the 300s only.
repo_debt_lines() { # var toplevel now tree-state
  local out="$1" top="$2" now="$3" state="$4"
  printf -v "$out" ''
  # The install path of the contract, never `command -v`: a PATH lookup makes the segment depend on
  # whatever shell started the harness, and makes every render of a test suite reach the real one.
  local debt="${STATUSLINE_REVIEW_DEBT:-$HOME/.local/bin/review-debt}"
  local cache lock key cached_key cached cache_mtime commondir journal_mtime lock_mtime top_key
  [ -n "$top" ] && [ -x "$debt" ] || return 0
  top_key=${top//%/%25}
  cache="$statusline_cache_dir/repo-debt-${top_key//\//%2F}"
  lock="$cache.lock"
  journal_dir commondir "$top"
  journal_mtime=""
  [ -n "$commondir" ] && file_mtime_to journal_mtime "$commondir/review-anchors.json"
  [[ "$journal_mtime" =~ ^[0-9]+$ ]] || journal_mtime=0
  key="$top|$journal_mtime|$state"
  file_mtime_to cache_mtime "$cache"
  cached_key=""
  cached=""
  if [[ "$cache_mtime" =~ ^[0-9]+$ ]]; then
    { IFS= read -r cached_key; IFS= read -r cached || :; } < "$cache" 2>/dev/null
  fi
  if [[ "$cache_mtime" =~ ^[0-9]+$ ]] && { [ "$((now - cache_mtime))" -le 15 ] ||
    { [ "$cached_key" = "$key" ] && [ "$((now - cache_mtime))" -le 300 ]; }; }; then
    :
  elif ensure_dir "$statusline_cache_dir" 2>/dev/null; then
    file_mtime_to lock_mtime "$lock"
    if [ ! -d "$lock" ] ||
      { [[ "$lock_mtime" =~ ^[0-9]+$ ]] && [ "$((now - lock_mtime))" -gt 120 ]; }; then
      (
        refresh_start_us=${EPOCHREALTIME//[!0-9]/}
        snapshot_lock_acquire "$lock" || exit 0
        # Only the lock this probe made: one reclaimed as dead while the walk ran belongs to the
        # probe that reclaimed it, and a blind rmdir here would let a third start beside it.
        lock_id="$(file_inode "$lock"):$(file_mtime "$lock")"
        trap '[ "$(file_inode "$lock"):$(file_mtime "$lock")" = "$lock_id" ] &&
          rmdir "$lock" 2>/dev/null' EXIT
        answer=$(run_bounded 60 "$debt" --repo "$top" 2>/dev/null | head -1)
        # Only a whole line this build understands becomes a number; anything else is no answer,
        # and no answer renders nothing — a folder debt is never worth a wrong digit.
        if [[ "$answer" =~ ^LINES=([0-9]+)[[:space:]]FILES=[0-9]+$ ]]; then
          answer=${BASH_REMATCH[1]}
        else
          answer=""
        fi
        tmp="$cache.tmp.${BASHPID:-$$}"
        printf '%s\n%s' "$key" "$answer" > "$tmp" 2>/dev/null &&
          mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
        probe_journal debt "$refresh_start_us"
      ) >/dev/null 2>&1 &
    fi
  fi
  [ "${cached_key%%|*}" = "$top" ] || cached=""
  if [ -n "$cached" ] && [[ "$cache_mtime" =~ ^[0-9]+$ ]] &&
    { [ "$((now - cache_mtime))" -le 120 ] || { [ "$cached_key" = "$key" ] && [ "$((now - cache_mtime))" -le 360 ]; }; }; then
    printf -v "$out" '%s' "$cached"
  fi
}

review_session_line() { # session now
  local out="$1" sid="$2" now="$3"
  printf -v "$out" ''
  local gate="${STATUSLINE_REVIEW_GATE:-$HOME/.claude/hooks/review-flow-gate.sh}"
  local cache="$statusline_cache_dir/review-autonomy-$sid"
  local lock="$cache.lock"
  local cached cache_mtime lock_mtime timeout_bin
  [ -n "$sid" ] && [ -x "$gate" ] || { printf -v "$out" '%s' 'no'; return 0; }
  file_mtime_to cache_mtime "$cache"
  cached=""
  [[ "$cache_mtime" =~ ^[0-9]+$ ]] && IFS= read -r cached < "$cache" 2>/dev/null
  if [ -n "$cached" ] && [[ "$cache_mtime" =~ ^[0-9]+$ ]] &&
    [ "$((now - cache_mtime))" -le 15 ]; then
    printf -v "$out" '%s' "$cached"
    return 0
  fi
  if ensure_dir "$statusline_cache_dir" 2>/dev/null; then
    file_mtime_to lock_mtime "$lock"
    if [ ! -d "$lock" ] ||
      { [[ "$lock_mtime" =~ ^[0-9]+$ ]] && [ "$((now - lock_mtime))" -gt 120 ]; }; then
      (
        refresh_start_us=${EPOCHREALTIME//[!0-9]/}
        snapshot_lock_acquire "$lock" || exit 0
        trap 'rmdir "$lock" 2>/dev/null' EXIT
        timeout_bin=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
        if [ -n "$timeout_bin" ]; then
          auto=$("$timeout_bin" 10 "$gate" autonomous "$sid" 2>/dev/null | head -1)
        else
          auto=$("$gate" autonomous "$sid" 2>/dev/null | head -1)
        fi
        [ "$auto" = yes ] || auto=no
        tmp="$cache.tmp.${BASHPID:-$$}"
        printf '%s' "$auto" > "$tmp" 2>/dev/null &&
          mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
        probe_journal autonomy "$refresh_start_us"
      ) >/dev/null 2>&1 &
    fi
  fi
  if [ -n "$cached" ] && [[ "$cache_mtime" =~ ^[0-9]+$ ]] &&
    [ "$((now - cache_mtime))" -le 120 ]; then
    printf -v "$out" '%s' "$cached"
  elif [ -n "$cached" ]; then
    printf -v "$out" '%s' 'no'
  else
    printf -v "$out" '%s' 'no'
  fi
}

# Whether this chat has a commit its branch's upstream does not contain. Prints `unpushed` or `off`.
#
# Whose the commit is is the GATE's answer (`unpushed`) and never this render's: the Stop ask that
# tells the chat to push reads the same subcommand, and a marker deriving ownership on its own would
# stand over commits that ask disowns. Cached off the render path — the gate forks git
# once per candidate commit, which is not a render-path cost — and keyed on everything cheap that
# can change the answer: the two shas, and the family's journals ownership is read from.
unpushed_marker() { # toplevel session now
  local out="$1" top="$2" sid="$3" now="$4"
  printf -v "$out" ''
  local gate="${STATUSLINE_REVIEW_GATE:-$HOME/.claude/hooks/review-flow-gate.sh}"
  local cache="$statusline_cache_dir/unpushed-${sid:-unknown}"
  local lock="$cache.lock"
  local key cached_key cached cache_mtime lock_mtime commondir head upstream commit_mtime debt_mtime
  local timeout_bin
  [ -n "$sid" ] && [ -n "$top" ] && [ -x "$gate" ] || { printf -v "$out" '%s' off; return 0; }
  # A branch with no upstream owes nothing here — nothing on this machine knows where it would go —
  # and one whose upstream is HEAD is a branch with nothing ahead at all. Both answer without the
  # gate, which is what keeps the marker off the render path for the repositories it never marks.
  # The render's own status already says which: no `branch.upstream`, or `branch.ab +0 -0`. An
  # upstream whose ref is missing prints no `branch.ab`, and rev-parse echoes `@{upstream}` for it.
  if [ "$git_status_rc" -eq 0 ] && [[ "$branch_oid" =~ ^[0-9a-f]+$ ]]; then
    [ -n "$branch_upstream" ] && [ "$branch_ab" != "+0 -0" ] || { printf -v "$out" '%s' off; return 0; }
    head=$branch_oid
  else
    head=$(git -C "$top" rev-parse HEAD 2>/dev/null)
  fi
  upstream=$(git -C "$top" rev-parse '@{upstream}' 2>/dev/null)
  [ -n "$head" ] && [ -n "$upstream" ] && [ "$head" != "$upstream" ] ||
    { printf -v "$out" '%s' off; return 0; }
  journal_dir commondir "$top"
  commit_mtime=""
  debt_mtime=""
  if [ -n "$commondir" ]; then
    file_mtime_to commit_mtime "$commondir/review-anchors.json"
    debt_mtime=$commit_mtime
  fi
  [[ "$commit_mtime" =~ ^[0-9]+$ ]] || commit_mtime=0
  [[ "$debt_mtime" =~ ^[0-9]+$ ]] || debt_mtime=0
  key="$top|$head|$upstream|$commit_mtime|$debt_mtime"
  file_mtime_to cache_mtime "$cache"
  cached_key=""
  cached=""
  if [[ "$cache_mtime" =~ ^[0-9]+$ ]]; then
    { IFS= read -r cached_key; IFS= read -r cached || :; } < "$cache" 2>/dev/null
  fi
  if [ "$cached_key" = "$key" ] && [[ "$cache_mtime" =~ ^[0-9]+$ ]] &&
    [ "$((now - cache_mtime))" -le 15 ]; then
    printf -v "$out" '%s' "${cached:-off}"
    return 0
  fi
  if ensure_dir "$statusline_cache_dir" 2>/dev/null; then
    file_mtime_to lock_mtime "$lock"
    if [ ! -d "$lock" ] ||
      { [[ "$lock_mtime" =~ ^[0-9]+$ ]] && [ "$((now - lock_mtime))" -gt 120 ]; }; then
      (
        refresh_start_us=${EPOCHREALTIME//[!0-9]/}
        snapshot_lock_acquire "$lock" || exit 0
        trap 'rmdir "$lock" 2>/dev/null' EXIT
        answer=off
        timeout_bin=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
        if [ -n "$timeout_bin" ]; then
          [ -n "$("$timeout_bin" 10 "$gate" unpushed "$top" "$sid" 2>/dev/null | head -1)" ] &&
            answer=unpushed
        else
          [ -n "$("$gate" unpushed "$top" "$sid" 2>/dev/null | head -1)" ] && answer=unpushed
        fi
        tmp="$cache.tmp.${BASHPID:-$$}"
        printf '%s\n%s' "$key" "$answer" > "$tmp" 2>/dev/null &&
          mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
        probe_journal unpushed "$refresh_start_us"
      ) >/dev/null 2>&1 &
    fi
  fi
  # Until that lands the last answer stands, and only while it still answers for this state: a
  # chat that moved tree keeps its cache file, and the key is what says the answer is about it.
  if [ "$cached" = unpushed ] && [ "$cached_key" = "$key" ] && [[ "$cache_mtime" =~ ^[0-9]+$ ]] &&
    [ "$((now - cache_mtime))" -le 120 ]; then
    printf -v "$out" '%s' unpushed
  else
    printf -v "$out" '%s' off
  fi
}

self_cpu_ms() {
  suite_journal_cpu_ms cpu_ms ''
  cpu_ms=${cpu_ms:--}
}

# Propagate just-merged headers to all surfaces via the zero-network collector
# (never --refresh); full contract: docs/statusline-contract.md "Store merge-kick".
# Every failure is silent — the statusline must never break because a nudge failed.
store_merge_kick() {
  local collector kick_dir stamp now_ts age
  collector="${STATUSLINE_STORE_MERGE_CMD:-}"
  if [ -z "$collector" ]; then
    collector="$statusline_dir/../llm-limits.sh"
  fi
  [ -x "$collector" ] || return 0
  kick_dir="$statusline_cache_dir"
  stamp="$kick_dir/store-merge-kick"
  now_ts=$EPOCHSECONDS
  file_mtime_to age "$stamp"
  [[ "$age" =~ ^[0-9]+$ ]] && [ "$((now_ts - age))" -lt 60 ] && return 0
  ensure_dir "$kick_dir" 2>/dev/null || return 0
  # Grab the single-flight lock in the foreground and stamp synchronously, so the
  # next render sees the debounce immediately (a background stamp would race two
  # near-simultaneous renders into a double kick).
  snapshot_lock_acquire "$stamp.lock" || return 0
  file_mtime_to age "$stamp"
  if [[ "$age" =~ ^[0-9]+$ ]] && [ "$((now_ts - age))" -lt 60 ]; then
    rmdir "$stamp.lock" 2>/dev/null
    return 0
  fi
  : > "$stamp" 2>/dev/null
  # Orphaned double-fork with own fds so the collector never holds the render's
  # stdout open or adds latency (same detach idiom as the ports probe). Unsetting the
  # session keeps its store-lock waits out of the chat's time budget: no chat waits on them.
  ( (
    unset WORKER_RUN_ID CLAUDE_CODE_SESSION_ID
    local start_us=${EPOCHREALTIME//[!0-9]/} end_us journal day
    PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:/usr/sbin" \
      "$collector" >/dev/null 2>&1
    end_us=${EPOCHREALTIME//[!0-9]/}
    rmdir "$stamp.lock" 2>/dev/null
    self_cpu_ms
    journal="${SPEED_DOCTOR_DIR:-$HOME/.cache/speed-doctor}/merge-kick"
    printf -v day '%(%Y-%m-%d)T' -1
    ensure_dir "$journal" 2>/dev/null &&
      printf '%s\t%s\t%s\n' "$start_us" "$(( (end_us - start_us) / 1000 ))" "$cpu_ms" \
        >> "$journal/$day.tsv" 2>/dev/null
  ) & ) >/dev/null 2>&1
}

# A gateway launch gets no `rate_limits` ride-along in the render payload, so nothing else keeps
# the Codex `5h`/`wk` cells inside their dim thresholds between heartbeat ticks; this fires the
# existing zero-spend per-account verb off the render path, silently, and never for an Anthropic
# session. Full contract: docs/statusline-contract.md "Codex quota kick".
codex_quota_kick() { # account now
  local account="$1" now_ts="$2" refresher codex_home stamp deadline tmp
  local ok_after=600 fail_after=1800
  # The name reaches a cache filename and a `codex/<name>` argument from an environment
  # variable this process does not own, so it is held to the launcher's own account pattern
  # instead of being trusted: a `/` in it would write outside the cache directory.
  [[ "$account" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || return 0
  [[ "$now_ts" =~ ^[0-9]+$ ]] || return 0
  refresher="${STATUSLINE_CODEX_REFRESH_CMD:-$statusline_dir/../llm-limits.sh}"
  [ -x "$refresher" ] || return 0
  # A gateway label need not name a Codex profile, and the collector only WARNS about a missing
  # one — it still exits 0, so the failure backoff below cannot see it. Such an account is
  # refused here or every deadline would spend an app-server launch that dies immediately.
  if [ "$account" = main ]; then
    # A removed main is not an account any more, and ~/.codex still being on disk is exactly why
    # the directory test below cannot see that.
    if codex_main_removed; then return 0; fi
    codex_home="$HOME/.codex"
  else
    codex_home="${CODEXB_PROFILES_DIR:-$HOME/.codex-profiles}/$account"
  fi
  [ -d "$codex_home" ] || return 0
  stamp="$statusline_cache_dir/codex-quota-kick-$account"
  # The stamp holds the epoch the next probe may fire at, not the last one's time: a refresher
  # that failed extends its own deadline, so pushback thins the cadence without a second file.
  deadline=""
  [ -r "$stamp" ] && read -r deadline < "$stamp" 2>/dev/null
  [[ "$deadline" =~ ^[0-9]+$ ]] && [ "$now_ts" -lt "$deadline" ] && return 0
  ensure_dir "$statusline_cache_dir" 2>/dev/null || return 0
  snapshot_lock_acquire "$stamp.lock" || return 0
  deadline=""
  [ -r "$stamp" ] && read -r deadline < "$stamp" 2>/dev/null
  if [[ "$deadline" =~ ^[0-9]+$ ]] && [ "$now_ts" -lt "$deadline" ]; then
    rmdir "$stamp.lock" 2>/dev/null
    return 0
  fi
  # Written in the foreground under the lock, so a near-simultaneous render on the same account
  # sees the deadline and skips rather than opening a second probe.
  printf '%s\n' "$((now_ts + ok_after))" > "$stamp" 2>/dev/null
  ( (
    unset WORKER_RUN_ID CLAUDE_CODE_SESSION_ID
    refresh_start_us=${EPOCHREALTIME//[!0-9]/}
    if ! PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:/usr/sbin" \
      "$refresher" --refresh-account "codex/$account" >/dev/null 2>&1; then
      tmp="$stamp.tmp.${BASHPID:-$$}"
      printf '%s\n' "$((now_ts + fail_after))" > "$tmp" 2>/dev/null &&
        mv -f "$tmp" "$stamp" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
    rmdir "$stamp.lock" 2>/dev/null
    probe_journal codex-kick "$refresh_start_us"
  ) & ) >/dev/null 2>&1
}

CYAN=$'\033[36m'; BLUE=$'\033[34m'; DIM=$'\033[2m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; MAGENTA=$'\033[35m'; RESET=$'\033[0m'

# Third arg overrides the green→yellow threshold (default 50); red stays ≥80.
# `YYYY-MM-DDTHH:MM:SS` + `Z` or `±HH:MM` to epoch seconds, by the civil-date formula.
iso_epoch_to() { # var timestamp
  printf -v "$1" ''
  [[ "$2" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|([+-])([0-9]{2}):([0-9]{2}))$ ]] ||
    return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  local h=$((10#${BASH_REMATCH[4]})) mi=$((10#${BASH_REMATCH[5]})) sec=$((10#${BASH_REMATCH[6]})) off=0
  local era yoe doy doe
  if [ "${BASH_REMATCH[7]}" != Z ]; then
    off=$((10#${BASH_REMATCH[9]} * 3600 + 10#${BASH_REMATCH[10]} * 60))
    [ "${BASH_REMATCH[8]}" = - ] && off=$((-off))
  fi
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] &&
    [ "$h" -le 23 ] && [ "$mi" -le 59 ] && [ "$sec" -le 60 ] || return 1
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$((y / 400)); yoe=$((y - era * 400))
  doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf -v "$1" '%s' $(( (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + sec - off ))
}

pct_colored() { # var pct dim warn
  local out="$1" v="$2" dim_flag="${3:-}" warn="${4:-50}"
  if [ -z "$v" ]; then printf -v "$out" '%s?%s' "$DIM" "$RESET"; return; fi
  if [ -n "$dim_flag" ]; then printf -v "$out" '%s%s%%%s' "$DIM" "$v" "$RESET"; return; fi
  local color
  if [ "$v" -lt "$warn" ]; then color="$GREEN"
  elif [ "$v" -lt 80 ]; then color="$YELLOW"
  else color="$RED"
  fi
  printf -v "$out" '%s%s%%%s' "$color" "$v" "$RESET"
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
# CCR keeps the launch alias's display_name after /model changes .id.
case "$model_id" in
  anthropic.ccr.sol) model=Sol ;;
  anthropic.ccr.astra) model=Astra ;;
esac

# The harness's used_percentage is denominator-blind on >200k windows (a 1m
# session at 248k reports 100%); raw usage over window size is the truth.
if [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ] 2>/dev/null && [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
  ctx_pct=$(( (ctx_tokens * 100 + ctx_size / 2) / ctx_size ))
fi

# The context-nudge hook only sees PostToolUse payloads, which carry no window
# size, and auto-compaction fires at a fraction of that window - so this render,
# which does get it, publishes it per session. Rewritten only on change: an
# unchanged file keeps its mtime, which is what makes a stale one identifiable.
if [ -n "$session_id" ] && [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ] 2>/dev/null; then
  nudge_dir="${CONTEXT_NUDGE_STATE_DIR:-$HOME/.cache/claude-context-nudge}"
  window_file="$nudge_dir/$session_id.window"
  window_seen=""
  [ -r "$window_file" ] && read -r window_seen < "$window_file" 2>/dev/null
  if [ "$window_seen" != "$ctx_size" ] && ensure_dir "$nudge_dir" 2>/dev/null; then
    # No sweep here: hooks/context-nudge.sh (claude-setup) sweeps this directory daily.
    window_tmp="$window_file.tmp.$$"
    printf '%s\n' "$ctx_size" > "$window_tmp" 2>/dev/null &&
      mv "$window_tmp" "$window_file" 2>/dev/null || rm -f "$window_tmp" 2>/dev/null
  fi
fi

rl_merge() {
  # An empty/invalid existing file must degrade to {}: feeding it to --argjson
  # makes jq fail every render and the corrupt file would never self-heal.
  local old_raw=/dev/null
  [ -r "$1" ] && old_raw=$1
  old_rl=""; merged_rl=""
  # An idle session re-renders its last known rate_limits forever; accepting
  # such rewrites would keep re-freshening stale data over live probe merges.
  # Only a strictly newer window (or higher pct in the same window) is taken —
  # unless this session has spent since its last accepted merge, which makes the
  # payload a live reading of a window that simply has not moved.
  { IFS= read -r old_rl; IFS= read -r merged_rl; } < <(jq -rcn --rawfile old_raw "$old_raw" \
    --argjson fresh "$rl_json" --argjson now "$EPOCHSECONDS" \
    --arg cost "$rl_cost_now" --arg prevcost "$rl_cost_prev" --argjson reset "$rl_reset_active" '
    ($old_raw | try fromjson catch null | if type == "object" then . else {} end) as $old
    | ($old | tojson), (
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
    # Liveness is spend that GREW since the last accepted merge; with no numeric previous cost
    # there is nothing to have grown from, so the first render of a session must not pass an
    # unmoved reading off as live.
    (((($prevcost | tonumber?) // null) as $p | (($cost | tonumber?) // null) as $c
      | $p != null and $c != null and $c > $p)) as $live |
    def unmoved($k): ($fresh[$k] // null) as $f | ($old[$k] // null) as $o |
      ($f != null) and ($o != null)
      and (($f.resets_at? // 0) == ($o.resets_at? // 0))
      and (((($f.used_percentage? // 0)) | round) == ((($o.used_percentage? // 0)) | round));
    # A usage reset lowers a window without moving its resets_at, so "higher in the same window is
    # newer" stops holding: until the marker lapses only a reading that followed new spend counts.
    def not_older($k): ($fresh[$k] // null) as $f | ($old[$k] // null) as $o |
      ($f != null) and ($o == null or (($f.resets_at? // 0) >= ($o.resets_at? // 0)));
    def accept($k): if $reset then ($live and not_older($k)) else newer($k) or ($live and unmoved($k)) end;
    ($old
    + (if accept("five_hour") then {five_hour: ($fresh.five_hour | stamp)} else {} end)
    + (if accept("seven_day") then {seven_day: ($fresh.seven_day | stamp)} else {} end)) as $out |
    # A live session on the account IS the login evidence, and nothing else clears the flag in
    # the background: while it stands every automated refresh skips the account as unrefreshable.
    # An idle session replays its last readings forever, so only a five-hour window that opened
    # after the logged-out verdict can speak — an older replay predates the credentials going.
    if accept("five_hour") and newer("five_hour") and (($fresh.five_hour.resets_at? // 0) > ($old.auth_checked_at? // 0))
    then ($out + {auth: {status: "ok", checked_at: $now}}
          | del(.auth_needed, .auth_cause, .auth_checked_at))
    else $out end
    )' 2>/dev/null)
  [ -n "$old_rl" ] || old_rl='{}'
}

rl_from_cache=""
rl_mtime=""
# The rate-limit cache is per ACCOUNT and shared by every chat on it, so the spend a merge was
# last accepted at is remembered per session instead — and a render with no session to remember
# through passes no cost at all, or it would claim liveness on every idle replay forever.
rl_cost_file=""
rl_cost_prev=""
rl_cost_now=""
rl_reset_at=""
rl_reset_active=false
if [ "$acct" != main ] && [ -r "$account_cache_dir/$acct.reset-at" ]; then
  read -r rl_reset_at < "$account_cache_dir/$acct.reset-at" 2>/dev/null
  case "$rl_reset_at" in
    ''|*[!0-9]*) ;;
    *) [ $((EPOCHSECONDS - rl_reset_at)) -lt 691200 ] && rl_reset_active=true ;;
  esac
fi
if [ -n "$session_id" ]; then
  rl_cost_file="$statusline_cache_dir/rl-cost-$session_id"
  [ -r "$rl_cost_file" ] && read -r rl_cost_prev < "$rl_cost_file" 2>/dev/null
  rl_cost_now="$cost_raw"
  # A session last heard before the reset replays pre-reset readings, and spend it made then
  # would pass for liveness: its spend is re-based to now, so only a call after the reset speaks.
  if [ "$rl_reset_active" = true ] && [ -n "$cost_raw" ]; then
    file_mtime_to rl_cost_mtime "$rl_cost_file" || rl_cost_mtime=0
    if [ "${rl_cost_mtime:-0}" -lt "$rl_reset_at" ] && ensure_dir "$statusline_cache_dir" 2>/dev/null; then
      tmp_cost="$rl_cost_file.tmp.$$"
      printf '%s\n' "$cost_raw" > "$tmp_cost" 2>/dev/null &&
        mv "$tmp_cost" "$rl_cost_file" 2>/dev/null || rm -f "$tmp_cost" 2>/dev/null
      rl_cost_prev="$cost_raw"
    fi
  fi
fi
if [ -n "${CLAUDEGPT_ACCOUNT:-}" ]; then
  rl_json=""
elif [ -n "$rl_json" ]; then
  rl_target="$cache_rl"
  if [ "$acct" != main ]; then
    # main is not a claudeb account: never create limits/main.json.
    ensure_dir "$account_cache_dir"
    rl_target="$account_cache"
  fi
  file_mtime_to rl_mtime "$rl_target"
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
      if [ -n "$rl_cost_file" ] && [ -n "$cost_raw" ] && [ "$cost_raw" != "$rl_cost_prev" ] &&
         ensure_dir "$statusline_cache_dir" 2>/dev/null; then
        tmp_cost="$rl_cost_file.tmp.$$"
        printf '%s\n' "$cost_raw" > "$tmp_cost" 2>/dev/null &&
          mv "$tmp_cost" "$rl_cost_file" 2>/dev/null || rm -f "$tmp_cost" 2>/dev/null
      fi
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
  rl_json=""
  if [ -r "$rl_cache_file" ]; then IFS= read -r -d '' rl_json < "$rl_cache_file" || :; fi
  rl_from_cache=1
  file_mtime_to rl_mtime "$rl_cache_file"
fi

now=$EPOCHSECONDS
h5_absent=false; h5_pct=""; h5_reset=""; h5_dim=""; wk_pct=""; wk_reset=""; wk_dim=""; wk_origin=""
if [ -n "$rl_json" ]; then
  # Legacy raw-headers caches carry no as_of; the cache file's mtime is the honest lower bound
  # (captured before any rewrite this render did), and a payload without either is as fresh as
  # this render.
  [[ "$rl_mtime" =~ ^[0-9]+$ ]] || rl_mtime="$now"
  IFS=$'\x1f' read -r h5_pct h5_reset h5_dim wk_pct wk_reset wk_dim wk_origin h5_absent < <(jq -r \
    --argjson now "$now" --argjson mtime "$rl_mtime" \
    --argjson thr5 "$LIMITS_STALE_FIVE_HOUR" --argjson thrw "$LIMITS_STALE_WEEKLY" "$LIMITS_VIEW_JQ"'
    (.auth.status == "expired") as $auth_expired
    | def bucket($b; $thr):
        if ($b | type) != "object" then ["", "", ""] else
          (if ($b.as_of | type) == "number" then $b.as_of else $mtime end) as $asof
          | (if ($b.resets_at | type) == "number" then $b.resets_at else null end) as $reset
          | limits_bucket_expired($now; $reset) as $expired
          | limits_bucket_stale($now; $thr; $auth_expired; ($b.origin // ""); $asof) as $stale
          | [ (limits_effective_pct($b.used_percentage; $expired)
               | if . == null then "" else (. + 0 | round | tostring) end),
              (if $reset == null or $reset < limits_reset_epoch_floor
                  or limits_reset_ancient($now; $reset) then "" else ($reset | tostring) end),
              (if $stale or $expired then "1" else "" end) ]
        end;
    bucket(.five_hour; $thr5) + bucket(.seven_day; $thrw) + [(.seven_day.origin // ""),
      (limits_window_absent(.five_hour //
        (if .auth_needed == true or (.auth.status | IN("failed", "expired"))
         then {stale:true} else null end)) | tostring)]
    | join("\u001f")' <<< "$rl_json" 2>/dev/null)
fi

# Rendering a header-origin week would print a percentage nobody measured — and one every
# other surface discards (shared-invariants n). Show `?` instead.
[ "$wk_origin" = headers ] && { wk_pct=""; wk_reset=""; }

h5_stale=""; wk_stale=""; fable_found=""; fable_pct=""; fable_reset=""; fable_dim=""; store_stale_txt=""
if [ -z "${CLAUDEGPT_ACCOUNT:-}" ] && [ -n "$acct" ] && [ "$acct" != main ]; then
  IFS=$'\x1f' read -r h5_stale wk_stale fable_found fable_pct fable_reset fable_dim store_stale_txt < <(jq -r \
    --arg account "$acct" --argjson now "$now" --argjson sthr "$LIMITS_STALE_ROUTING" "$LIMITS_VIEW_JQ"'
    (try ([.vendors.claude.accounts[]? | select(.account == $account)][0] as $a |
      if $a == null then ["", ""]
      else [($a.five_hour.stale == true | tostring), ($a.weekly.stale == true | tostring)] end
      | join("\u001f")) catch "\u001f")
    + "\u001f"
    + (try (first(.vendors.claude.accounts[]? | select(.account == $account) | .fable // empty
        | ["1", (if .effective_pct == null then "" else (.effective_pct | round | tostring) end),
           (.resets_at // ""), (if .stale == true or .expired == true then "1" else "" end)]
        | join("\u001f")) // "\u001f\u001f\u001f")
       catch "\u001f\u001f\u001f")
    + "\u001f"
    + (try (first(.vendors.claude.accounts[]? | select(.account == $account) | select(.fable != null)
        | limits_store_stale_text(.; $now; $sthr)) // "") catch "")
  ' "$limits_file" 2>/dev/null)
  if [ -n "$rl_json" ] && [ -n "$rl_from_cache" ]; then
    [ "$h5_stale" = true ] && h5_dim=1
    [ "$wk_stale" = true ] && wk_dim=1
  fi
fi


if [ -n "${CLAUDEGPT_ACCOUNT:-}" ]; then
  file_mtime_to limits_mtime "$limits_file"
  [[ "$limits_mtime" =~ ^[0-9]+$ ]] || limits_mtime=0
  IFS=$'\x1f' read -r h5_pct h5_reset h5_dim wk_pct wk_reset wk_dim h5_absent store_stale_txt < <(jq -r \
    --arg account "$CLAUDEGPT_ACCOUNT" --argjson now "$now" --argjson mtime "$limits_mtime" \
    --argjson thr5 "$LIMITS_STALE_FIVE_HOUR" --argjson thrw "$LIMITS_STALE_WEEKLY" \
    --argjson sthr "$LIMITS_STALE_ROUTING" "$LIMITS_VIEW_JQ"'
    [.vendors.codex.accounts[]? | select(.account == $account)][0] as $a
    | def bucket($b; $thr):
        if ($b | type) != "object" then ["", "", ""] else
          ($b.resets_at | limits_store_epoch) as $reset
          | limits_bucket_expired($now; $reset) as $expired
          | [ (limits_store_eff($b; $now) | if type == "number" then (round | tostring) else "" end),
              (if $reset == null or $reset < limits_reset_epoch_floor
                  or limits_reset_ancient($now; $reset) then "" else ($reset | tostring) end),
              (if $b.stale == true or $b.expired == true or $expired
                  or limits_bucket_stale($now; $thr; ($a.auth.status == "expired");
                       ($b.origin // ""); ($b.as_of // $mtime))
                  or ($now - $mtime) > $thr then "1" else "" end) ]
        end;
    bucket($a.five_hour; $thr5) + bucket($a.weekly; $thrw)
    + [($a != null and limits_window_absent($a.five_hour) | tostring)]
    + [limits_store_stale_text($a; $now; $sthr)] | join("\u001f")
  ' "$limits_file" 2>/dev/null)
  codex_quota_kick "$CLAUDEGPT_ACCOUNT" "$now"
fi

dir=${dir_path%"${dir_path##*[!/]}"}
dir=${dir##*/}; [ -z "$dir_path" ] || dir=${dir:-/}
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

git_dir="$dir_path"
active_top=""; active_common=""; active_root=""; active_name=""; active_is_wt=0
adopt_repo_dirs() {
  active_top="$REPO_TOP"; active_common="$REPO_COMMON"
  active_root="$REPO_ROOT"; active_name="$REPO_NAME"; active_is_wt="$REPO_IS_WT"
}
adopt_project_dirs() {
  active_top="$project_top"; active_common="$project_common"
  active_root="$project_root"; active_name="$project_name"; active_is_wt="$project_is_wt"
}
# The middle block — the dir cluster, the branch, the counters, the autonomy dot,
# `unpushed` — is ATOMIC: all of it renders ONE working tree, the tree of the LAST line of this chat's
# place journal (bin/statusline-place; docs/statusline-contract.md "Shown tree"). Nothing here
# ranks, holds or checks liveness: the writers declare, this reads the last line that still resolves.
shown_tree=""
place_journal="$statusline_cache_dir/place-$session_id"
if [ -n "$session_id" ] && [ -s "$place_journal" ]; then
  place_lines=()
  while IFS= read -r place_line; do place_lines+=("$place_line"); done < "$place_journal"
  place_last=$((${#place_lines[@]} - 1))
  for ((place_i = place_last; place_i >= 0; place_i--)); do
    IFS=$'\t' read -r _ _ place_tree _ <<< "${place_lines[$place_i]}"
    [ -n "$place_tree" ] && [ -d "$place_tree" ] && { shown_tree=$place_tree; break; }
  done
  if [ -z "$shown_tree" ] && [ "$place_last" -ge 0 ]; then
    IFS=$'\t' read -r _ _ _ place_main <<< "${place_lines[$place_last]}"
    [ -n "$place_main" ] && [ -d "$place_main" ] && shown_tree=$place_main
  fi
fi
if [ -n "$shown_tree" ] && [ "$shown_tree" != "$project_top" ] && repo_dirs "$shown_tree"; then
  git_dir="$shown_tree"
  adopt_repo_dirs
else
  adopt_project_dirs
fi

dir_foreign=0
wt_show=0
wt_name=""
wt_color=""
if [ -n "$active_top" ]; then
  # Repository identity, not toplevel: every worktree of the project shares its
  # common dir, so `»` fires on a genuinely foreign repository only.
  if [ "$active_common" != "$project_common" ]; then
    dir_foreign=1
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
    wt_show=1
    wt_name="${active_top##*/}"
  fi
fi

branch_show=0
branch_is_sha=0
branch_name=""
branch_sha=""
diff_show=""
udiff_add=0
udiff_del=0
fparts=""
behind=""
ahead=""
head_known=0
git_status_rc=1
branch_oid=""; branch_upstream=""; branch_ab=""; branch=""; has_untracked=0
if [ -n "$active_top" ]; then
  status_v2=$(git -C "$active_top" status --porcelain=v2 --branch --untracked-files=normal --ahead-behind 2>/dev/null)
  git_status_rc=$?
  while IFS= read -r status_line; do
    case "$status_line" in
      '# branch.oid '*) branch_oid=${status_line#\# branch.oid } ;;
      '# branch.head '*) branch=${status_line#\# branch.head } ;;
      '# branch.upstream '*) branch_upstream=${status_line#\# branch.upstream } ;;
      '# branch.ab '*)
        branch_ab=${status_line#\# branch.ab }
        status_rest=${branch_ab#+}
        ahead=${status_rest%% *}; behind=${status_rest#* -} ;;
      '? '*) has_untracked=1 ;;
    esac
  done <<< "$status_v2"
fi
if [ -n "$active_top" ]; then
  [ "$branch" != '(detached)' ] && [ "$branch_oid" != '(initial)' ] || branch=HEAD
  if [ "$git_status_rc" -ne 0 ]; then
    branch=$(git -C "$git_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    branch_oid=$(git -C "$git_dir" rev-parse -q --verify HEAD 2>/dev/null)
    branch_upstream=$(git -C "$git_dir" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null)
    has_untracked=1
    [ -n "$branch" ] &&
      read -r behind ahead < <(git -C "$git_dir" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
  fi
  # In a worktree the `⧉` label is the whole identity: no branch segment there,
  # whatever HEAD is. `head_known` still gates the diff counters below.
  if [ "$branch" = HEAD ]; then
    head_known=1
    if [ "$active_is_wt" != 1 ]; then
      branch_sha=$(git -C "$git_dir" rev-parse --short HEAD 2>/dev/null)
      branch_show=1
      branch_is_sha=1
    fi
  elif [ -n "$branch" ]; then
    head_known=1
    if [ "$active_is_wt" != 1 ]; then
      branch_show=1
      branch_name="$branch"
    fi
  fi
  if [ "$head_known" = 1 ]; then
    # Uncommitted volume in the ACTIVE repo, whoever wrote it: staged+unstaged
    # vs HEAD plus untracked files. Lines: numstat + untracked text lines
    # (grep -cI yields 0 and BSD grep prints nothing for binaries; numstat "-"
    # skipped by the numeric guards). Files: --summary create/delete + untracked
    # markers; the rest of the numstat entries are "modified" (renames incl.).
    # Marker rows carry an empty 3rd field + tag — a real numstat path is
    # never empty, so tracked files can't collide with them. Not the harness's
    # .cost.total_lines_* — that was a session-lifetime tool-edit counter
    # across all repos, useless for "how much is hanging uncommitted now".
    udiff_add=0; udiff_del=0; f_new=0; f_del=0; f_mod=0; diff_entries=0; diff_creates=0; diff_deletes=0
    while IFS= read -r diff_line; do
      case "$diff_line" in
        ' create mode '*) diff_creates=$((diff_creates + 1)) ;;
        ' delete mode '*) diff_deletes=$((diff_deletes + 1)) ;;
        [0-9-]*$'\t'*)
          IFS=$'\037' read -r -a diff_fields <<< "${diff_line//$'\t'/$'\037'}"
          [[ "${diff_fields[0]}" =~ ^[0-9-]+$ ]] || continue
          [[ "${diff_fields[0]}" =~ ^[0-9]+$ ]] && udiff_add=$((udiff_add + 10#${diff_fields[0]}))
          [[ "${diff_fields[1]}" =~ ^[0-9]+$ ]] && udiff_del=$((udiff_del + 10#${diff_fields[1]}))
          if [ "${#diff_fields[@]}" = 4 ] && [ -z "${diff_fields[2]}" ] && [[ "${diff_fields[3]}" =~ ^U([0-9]+)$ ]]; then
            f_new=$((f_new + 10#${BASH_REMATCH[1]}))
          elif ! { [ "${#diff_fields[@]}" = 4 ] && [ -z "${diff_fields[2]}" ] && [ "${diff_fields[3]}" = L ]; }; then
            diff_entries=$((diff_entries + 1))
          fi ;;
      esac
    done < <({
        if [ -n "$branch_oid" ] && [ "$branch_oid" != "(initial)" ]; then
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
        if [ "$has_untracked" = 1 ]; then
          mapfile -d '' untracked_names < <(git -C "$active_top" ls-files --others --exclude-standard -z 2>/dev/null)
          # python's start costs three greps: a short listing is cheaper counted afresh.
          if [ "${#untracked_names[@]}" -gt 32 ]; then
            printf '%s\0' "${untracked_names[@]}" |
              python3 -E -S "$statusline_dir/../share/statusline-untracked.py" "$active_top" "$statusline_cache_dir/untracked-lines"
          elif [ "${#untracked_names[@]}" -gt 0 ]; then
            printf '0\t0\t\tU%s\n' "${#untracked_names[@]}"
            printf '%s\0' "${untracked_names[@]}" | ( cd "$active_top" 2>/dev/null && xargs -0 grep -cI '' 2>/dev/null ) |
              while IFS= read -r untracked_count; do printf '%s\t0\t\tL\n' "${untracked_count##*:}"; done
          fi
        fi
      })
    f_new=$((f_new + diff_creates)); f_del=$diff_deletes; f_mod=$((diff_entries - diff_creates - diff_deletes))
    fparts=""
    [ "$f_new" -gt 0 ] 2>/dev/null && fparts="+${f_new}"
    [ "$f_mod" -gt 0 ] 2>/dev/null && fparts="${fparts}~${f_mod}"
    [ "$f_del" -gt 0 ] 2>/dev/null && fparts="${fparts}-${f_del}"
    if [ "$udiff_add" -gt 0 ] 2>/dev/null || [ "$udiff_del" -gt 0 ] 2>/dev/null; then
      diff_show=lines
    elif [ -n "$fparts" ]; then
      # Dirty with zero countable lines (binary/mode/rename-only): files only.
      diff_show=files
    fi
  fi
fi

h5_time=""
[[ "$h5_reset" =~ ^[0-9]+$ ]] && TZ=Europe/Kyiv printf -v h5_time '%(%H:%M)T' "$h5_reset" 2>/dev/null

wk_arrow_txt=""
if [ -n "$wk_reset" ]; then
  rem=$(( wk_reset - now ))
  if [ "$rem" -gt 86400 ] || [ "$rem" -le 0 ]; then
    TZ=Europe/Kyiv printf -v dow '%(%u)T' "$wk_reset"
    TZ=Europe/Kyiv printf -v wtime '%(%H:%M)T' "$wk_reset"
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

sep="${DIM}│${RESET}"

h5_pct_part=""
[ "$h5_absent" != true ] && pct_colored h5_pct_part "$h5_pct" "$h5_dim"
fable_pct_part=""
fable_reset_txt=""
fable_account="$acct"
if [ -z "${CLAUDEGPT_ACCOUNT:-}" ] && [ -n "$fable_account" ] && [ "$fable_account" != main ]; then
  if [ "$fable_found" = 1 ]; then
    # Stale flags inside a frozen llm-limits.json never flip; the file's own
    # age is the backstop.
    file_mtime_to limits_mtime "$limits_file"
    [[ "$limits_mtime" =~ ^[0-9]+$ ]] && [ $((now - limits_mtime)) -gt "$LIMITS_STALE_FABLE" ] && fable_dim=1
    if [ -n "$fable_reset" ]; then
      fable_reset_epoch=""; fable_dow=""; fable_time=""
      if iso_epoch_to fable_reset_epoch "$fable_reset"; then
        TZ=Europe/Kyiv printf -v fable_dow '%(%u)T' "$fable_reset_epoch"
        TZ=Europe/Kyiv printf -v fable_time '%(%H:%M)T' "$fable_reset_epoch"
      fi
      if [[ "$fable_reset_epoch" =~ ^[0-9]+$ ]]; then
        fable_rem=$(( fable_reset_epoch - now ))
        # A reset over a day past is dropped exactly as the menubar drops it — the shared
        # `limits_reset_ancient` answers, never a local threshold (shared-invariants row y).
        fable_ancient=""
        [ "$fable_rem" -le 0 ] && fable_ancient=$(jq -n --argjson now "$now" \
          --argjson reset "$fable_reset_epoch" \
          "$LIMITS_VIEW_JQ"'limits_reset_ancient($now; $reset)' 2>/dev/null)
        if [ "$fable_ancient" = true ]; then
          :
        elif [ "$fable_rem" -gt 86400 ] || [ "$fable_rem" -le 0 ]; then
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
    pct_colored fable_pct_part "$fable_pct" "$fable_dim"
  fi
fi

# User/tool activity and payload cache counters cannot prove server cache warmth.
assist_ts=0; assist_model="-"; assist_uuid="-"; fork_sid="-"; ttl_bucket=0
post_compact=0; ctx_stale=1; boundary_ts=0; fresh_ctx=0; oldest_ts=0
ev_valid=0; ev_ts=0; ev_gap=0; ev_cr=0; ev_cc=0
fork_anchor_uuid="-"; fork_own_ts=0
latest_ts=0; latest_model="-"; latest_ttl=0; latest_uuid="-"; latest_fork="-"
learned_file="${STATUSLINE_CACHE_TTL_LEARNED:-$statusline_cache_dir/cache-ttl-learned}"
warm_acct="${CLAUDEGPT_ACCOUNT:-$acct}"; track_acct=""; learned_upto=0
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

resolve_parent_transcript() {
  local sibling root candidate found=""
  statusline_parent_dir "$transcript_path"
  sibling="$statusline_parent/$fork_sid.jsonl"
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

# A compaction boundary scrolls out of the scan window once the re-emitted burst behind
# it outgrows the window, and the scan then stops at the first re-emitted assistant and
# reports its pre-compact total as live. The sidecar remembers the newest boundary across
# renders; the context-nudge hook writes the same file under the same rules.
boundary_seed=""
if [ -n "$session_id" ] && [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
  bnd_dir="${CONTEXT_NUDGE_STATE_DIR:-$HOME/.cache/claude-context-nudge}"
  bnd_file="$bnd_dir/$session_id.bnd"
  file_size_to bnd_size "$transcript_path"
  [[ "$bnd_size" =~ ^[0-9]+$ ]] || bnd_size=0
  bnd_scanned=0; bnd_seen=""
  if [ -r "$bnd_file" ]; then
    bnd_f1=""; bnd_f2=""
    read -r bnd_f1 bnd_f2 < "$bnd_file" 2>/dev/null || :
    if [[ "$bnd_f1" =~ ^[0-9]+$ ]] && { [ "$bnd_f2" = "-" ] || [[ "$bnd_f2" =~ ^[0-9T:.Z+-]+$ ]]; }; then
      bnd_scanned="$bnd_f1"
      [ "$bnd_f2" = "-" ] || bnd_seen="$bnd_f2"
    fi
  fi
  # A transcript smaller than what the sidecar claims to have scanned is a different
  # file (session rewrite, clear stub); its remembered boundary describes nothing here.
  if [ "$bnd_size" -lt "$bnd_scanned" ] 2>/dev/null; then bnd_scanned=0; bnd_seen=""; fi
  if [ "$bnd_size" -gt "$bnd_scanned" ] 2>/dev/null; then
    # The margin re-covers a boundary line the previous scan cut at its own EOF; grep is
    # only a prefilter, so chat content naming compact_boundary falls out at the select.
    if [ "$bnd_scanned" -gt 4096 ]; then bnd_from=$((bnd_scanned - 4096)); else bnd_from=0; fi
    bnd_seen=$(
      {
        [ -z "$bnd_seen" ] || printf '%s\n' "$bnd_seen"
        tail -c "+$((bnd_from + 1))" "$transcript_path" 2>/dev/null |
          grep -aF compact_boundary 2>/dev/null |
          jq -Rrn 'inputs | fromjson?
            | select(type == "object" and .type == "system" and .subtype == "compact_boundary")
            | .timestamp // empty' 2>/dev/null
      } | LC_ALL=C sort | tail -n 1
    ) || bnd_seen=""
    if ensure_dir "$bnd_dir" 2>/dev/null; then
      bnd_tmp="$bnd_file.tmp.$$"
      printf '%s %s\n' "$bnd_size" "${bnd_seen:--}" > "$bnd_tmp" 2>/dev/null &&
        mv "$bnd_tmp" "$bnd_file" 2>/dev/null || rm -f "$bnd_tmp" 2>/dev/null
    fi
  fi
  boundary_seed="$bnd_seen"
fi

scan_vars=(scan_found assist_ts assist_model assist_uuid fork_sid ttl_bucket post_compact ev_valid ev_ts
  ev_gap ev_cr ev_cc ctx_stale boundary_ts fork_anchor_uuid fork_own_ts latest_ts latest_model latest_ttl
  latest_uuid latest_fork fresh_ctx oldest_ts scan_complete scan_bytes transcript_size)
if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
  file_size_to transcript_size "$transcript_path"
  [[ "$transcript_size" =~ ^[0-9]+$ ]] || transcript_size=0
  # The scan reads nothing but the transcript and the inputs in this key, so an unchanged
  # transcript replays its last answer instead of re-reading up to 8 MiB.
  file_mtime_to scan_mtime "$transcript_path"
  file_stat_to scan_inode inode "$transcript_path"
  scan_key="v1|$transcript_path|$scan_inode|$transcript_size|$scan_mtime|$model_id|$boundary_seed|$saved_scan_bytes"
  scan_memo="$statusline_cache_dir/scan-$session_id"
  scan_memo_key=""; scan_memo_vals=""
  [ -n "$session_id" ] && [ -r "$scan_memo" ] &&
    { IFS= read -r scan_memo_key; IFS= read -r scan_memo_vals; } < "$scan_memo" 2>/dev/null
  if [ -n "$session_id" ] && [ "$scan_memo_key" = "$scan_key" ]; then
    IFS=$'\x1f' read -r "${scan_vars[@]}" <<< "$scan_memo_vals"
  else
    while :; do
      cache_scan=$(
        tail -c "$scan_bytes" "$transcript_path" 2>/dev/null |
          {
            [ "$scan_bytes" -ge "$transcript_size" ] || IFS= read -r _ || :
            cat
          } |
          jq -Rrn --arg model "$model_id" --arg seedb "$boundary_seed" '
            def ep: try (sub("\\.[0-9]+Z$"; "Z") | fromdate) catch null;
            def num: if type == "number" then . else 0 end;
            def buckets:
              [((.cache_creation? // {}) | to_entries[]?
                | select((.value | num) > 0)
                | .key | capture("ephemeral_(?<n>[0-9]+)(?<u>[mh])_")?
                | ((.n | tonumber) * (if .u == "m" then 60 else 3600 end)))] as $v
              | {ttl: ($v | if length == 0 then 0 else min end)};
            # The plain context-size core is claude-setup hooks/lib/context-size.jq; a fix there has to be re-checked against this superset.
            reduce (inputs | fromjson? | select(type == "object" and .isSidechain != true)) as $x (
              {la:0, pm:"", pg:-1, pa:0, lb:($seedb | ep // 0), ats:0, am:"-", au:"-", afk:"", bk:0,
               pbk:0, ots:0,
               cgap:0, ccr:0, ccc:0, cets:0, cpm:"", cem:"", cpa:0, chas:0, own:0,
               sawf:0, fas:"", fau:"", fot:0, lts:0, lm:"-", lbk:0, lu:"-", lfk:"",
               fc:0, fcts:0};
              (($x.forkedFrom?.sessionId? // "") | tostring) as $fs
              | (($x.forkedFrom?.messageUuid? // "") | tostring) as $fu
              | ((($x.timestamp? // "") | if type == "string" then ep else null end)) as $ts
              | (if $fs != "" then
                   .sawf = 1 | .fas = $fs | (if $fu != "" then .fau = $fu else . end)
                 elif .sawf == 1 and .fot == 0 and $ts != null then .fot = $ts
                 else . end)
              | (if $ts == null or (.ots > 0 and .ots <= $ts) then . else .ots = $ts end)
              | if $ts == null then .
                elif $x.type == "system" and $x.subtype == "compact_boundary" then
                  # Only a new-maximum boundary invalidates the size: re-emitted
                  # older boundaries trail the newest one in file order. A size
                  # already taken from a response newer than this boundary survives
                  # it - re-emission can put that response earlier in the file.
                  (if $ts > .lb then
                     .lb = $ts
                     | (if .fcts > $ts then . else .fc = 0 | .fcts = 0 end)
                   else . end)
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
                  | if ($u | type) != "object" then .
                    else
                      (if ($cr + $cc) <= 0 or $xm == "" then . else
                      (if .pg >= 0 then
                         .cgap = .pg | .ccr = $cr | .ccc = $cc | .cets = $ts
                         | .cpm = .pm | .cem = $xm | .cpa = .pa | .chas = 1 | .pg = -1
                       else . end)
                      | (if $ts >= .lts then
                           .lts = $ts | .lm = $xm | .lbk = $bs.ttl
                           | .lu = (if $xu == "" then "-" else $xu end) | .lfk = $fs
                         else . end)
                      | (if $model != "" and $xm == $model then
                           # A cache read refreshes the entry it hit, so a pure-read response
                           # proves warmth even though it creates no bucket - it inherits the
                           # TTL of the nearest older own response that did declare one.
                           (if $ts >= .ats then
                              .ats = $ts | .am = $xm | .au = (if $xu == "" then "-" else $xu end)
                              | .afk = $fs
                              | .bk = (if $bs.ttl > 0 then $bs.ttl
                                       elif $cr > 0 then .pbk else 0 end)
                            else . end)
                           | (if $bs.ttl > 0 then .pbk = $bs.ttl else . end)
                         else . end)
                      | (if $fs == "" and $ts > .own then .own = $ts else . end)
                      | .pm = $xm
                      | (if $ts > .la then .la = $ts else . end)
                      end)
                      # Entries re-emitted after a boundary keep their pre-compact usage
                      # totals, so only a response stamped after it sizes live context -
                      # strictly after, because ep drops sub-second precision and an
                      # auto-compact boundary shares its second with the last pre-compact
                      # response, whose total >= would resurrect. Not gated on cache
                      # tokens: an input-only response is a real post-boundary size.
                      | (if .lb == 0 or $ts > .lb then
                           ((($u.input_tokens? // 0) | num) + $cc + $cr) as $tc
                           | (if $tc > 0 then .fc = $tc | .fcts = $ts else . end)
                         else . end)
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
                .lts, .lm, .lbk, .lu, (.lfk | if . == "" then "-" else . end), .fc, .ots ]
            | map(tostring) | join("")' 2>/dev/null
      )
      if [ -n "$cache_scan" ]; then
        IFS=$'\x1f' read -r scan_found assist_ts assist_model assist_uuid fork_sid ttl_bucket \
          post_compact ev_valid ev_ts ev_gap ev_cr ev_cc ctx_stale boundary_ts fork_anchor_uuid \
          fork_own_ts latest_ts latest_model latest_ttl latest_uuid latest_fork fresh_ctx \
          oldest_ts <<< "$cache_scan" || :
      fi
      [ "$scan_found" = 1 ] && break
      if [ "$scan_bytes" -ge "$transcript_size" ]; then scan_complete=1; break; fi
      # A boundary ends the scan only once the window has read back past it: everything
      # deeper is then pre-compact and cannot change warmth or the live size. The boundary
      # may be known from the sidecar alone, i.e. from a file position outside this window,
      # and stopping there would hide a live response sitting deeper than the window.
      [ "$boundary_ts" -gt 0 ] 2>/dev/null && [ "$oldest_ts" -gt 0 ] 2>/dev/null \
        && [ "$oldest_ts" -le "$boundary_ts" ] 2>/dev/null && { scan_complete=1; break; }
      [ "$scan_bytes" -ge "$scan_max" ] && break
      if [ "$scan_bytes" -eq 262144 ] && [ "$saved_scan_bytes" -gt "$scan_bytes" ]; then
        scan_bytes="$saved_scan_bytes"
      else
        scan_bytes=$((scan_bytes * 4))
      fi
      [ "$scan_bytes" -gt "$scan_max" ] && scan_bytes="$scan_max"
    done
    if [ -n "$session_id" ] && ensure_dir "$statusline_cache_dir" 2>/dev/null; then
      scan_memo_line=""
      for scan_var in "${scan_vars[@]}"; do scan_memo_line+="${!scan_var}"$'\x1f'; done
      printf '%s\n%s\n' "$scan_key" "${scan_memo_line%$'\x1f'}" > "$scan_memo.tmp.$$" 2>/dev/null &&
        mv -f "$scan_memo.tmp.$$" "$scan_memo" 2>/dev/null || rm -f "$scan_memo.tmp.$$" 2>/dev/null
    fi
  fi
fi

for scan_num in assist_ts ttl_bucket post_compact ev_valid ev_ts ev_gap ev_cr ev_cc \
  ctx_stale boundary_ts fork_own_ts latest_ts latest_ttl fresh_ctx oldest_ts; do
  [[ "${!scan_num}" =~ ^[0-9]+$ ]] || printf -v "$scan_num" %s 0
done
[[ "$fork_sid" =~ ^[A-Za-z0-9_-]+$ ]] || fork_sid="-"
[[ "$latest_fork" =~ ^[A-Za-z0-9_-]+$ ]] || latest_fork="-"
ctx_dim=""
# Dim means the number is INHERITED rather than measured, and a fork-copied tail
# is not: /branch hands the whole history over, so the branch has no response of
# its own to prove freshness while the copies ARE its live context. What settles
# it is corroboration - a post-boundary measurement (fresh_ctx) that agrees with
# the payload within the same 10% the size override uses proves the payload is
# describing this context, not a discarded one. A compacted session has no such
# measurement until its first response, an unreadable tail yields none, a payload
# that disagrees with the transcript is the inherited case itself, and a payload
# carrying no size at all leaves its percentage with nothing to corroborate it -
# all four keep dimming.
if [ "$ctx_stale" = 1 ]; then
  ctx_dim=1
  if [ "$fresh_ctx" -gt 0 ] 2>/dev/null && [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
    ctx_fork_delta=$(( ctx_tokens > fresh_ctx ? ctx_tokens - fresh_ctx : fresh_ctx - ctx_tokens ))
    [ "$((ctx_fork_delta * 10))" -gt "$ctx_tokens" ] || ctx_dim=""
  fi
fi

# The harness keeps reporting the pre-reset usage until the first request of the
# new context completes, so a fresh /compact or /branch renders a full-looking
# context that no longer exists. The transcript knows better: after a boundary
# only a response stamped at/after it describes the live context, and until one
# exists the context is empty - 0, never the last-known number.
ctx_over=""
if [ "$boundary_ts" -gt 0 ] 2>/dev/null; then
  if [ "$fresh_ctx" -gt 0 ] 2>/dev/null; then
    if [ -z "$ctx_tokens" ] || [ "$ctx_tokens" -le 0 ] 2>/dev/null; then
      ctx_tokens="$fresh_ctx"; ctx_over=1
    else
      ctx_delta=$(( ctx_tokens > fresh_ctx ? ctx_tokens - fresh_ctx : fresh_ctx - ctx_tokens ))
      [ "$((ctx_delta * 10))" -gt "$ctx_tokens" ] && { ctx_tokens="$fresh_ctx"; ctx_over=1; }
    fi
  else
    ctx_tokens=0; ctx_over=1
  fi
  if [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ] 2>/dev/null; then
    ctx_pct=$(( (ctx_tokens * 100 + ctx_size / 2) / ctx_size ))
  elif [ -n "$ctx_over" ]; then
    # No window size to recompute against, and the payload's percentage describes
    # the usage this block just discarded.
    if [ "$ctx_tokens" -eq 0 ]; then ctx_pct=0; else ctx_pct=""; fi
  fi
fi

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
      statusline_parent_dir "$model_track"
      ensure_dir "$statusline_parent" 2>/dev/null
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
  statusline_parent_dir "$model_track"
  ensure_dir "$statusline_parent" 2>/dev/null
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
    if [ "$fc1" = v4 ] && [ "$fc2" = "$fork_sid" ] && [ "$fc3" = "$fork_anchor_uuid" ] \
       && [ "$fc4" = "$fork_own_ts" ] && [ -r "$fc5" ]; then
      file_size_to parent_size "$fc5"
      file_mtime_to parent_mtime "$fc5"
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
      file_size_to parent_size "$parent_file"
      file_mtime_to parent_mtime "$parent_file"
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
              # Only conversation entries extend the prefix the fork shares; the
              # bookkeeping Claude Code appends after a turn (stop_hook_summary,
              # turn_duration) carries a uuid too and must not read as "something after".
              | if $uuid == "" or ($cutoff > 0 and $ts != null and $ts > $cutoff) then .
                elif $uuid == $anchor then .last = $uuid | .seen = 1
                elif $x.type == "user" or $x.type == "assistant" then .last = $uuid
                else . end)
            | [.seen, .last, .boundary, .ats, .au, .ttl, .anchor_ts] | @tsv' 2>/dev/null
      )
      parent_seen=""; parent_last=""
      IFS=$'\t' read -r parent_seen parent_last parent_boundary parent_assist_ts \
        parent_assist_uuid parent_assist_ttl parent_anchor_ts <<< "$parent_tail" || :
      # An anchor inside the scanned tail settles the fork either way - anything the
      # parent added after it sits in that same tail. Only an unseen anchor needs the
      # whole file to tell "something after it" from "deeper than the window"; a
      # parent bigger than the window (63 MB transcripts exist) must not read as unknown.
      if [ "$parent_seen" = 1 ] && [ "$parent_last" = "$fork_anchor_uuid" ] \
         && { [ "$parent_bytes" -ge "$parent_size" ] || [ "$parent_assist_ts" -gt 0 ] 2>/dev/null; }; then
        fork_state=tail
      elif [ "$parent_seen" = 1 ] || [ "$parent_bytes" -ge "$parent_size" ]; then
        fork_state=mid
      else
        fork_state=unknown
      fi
      if [ -n "$fork_cache" ]; then
        statusline_parent_dir "$fork_cache"
        ensure_dir "$statusline_parent" 2>/dev/null
        printf 'v4\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
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
if [ -z "${CLAUDEGPT_ACCOUNT:-}" ] && { [ -n "$learn_event" ] || [ -n "$bounds_need_decay" ]; }; then
  statusline_parent_dir "$learned_file"
  ensure_dir "$statusline_parent" 2>/dev/null
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
  statusline_parent_dir "$track"
  ensure_dir "$statusline_parent" 2>/dev/null
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
ctx_warn_part=""
if [ "$cache_state" = warm ]; then
  TZ=Europe/Kyiv printf -v death_time '%(%H:%M)T' "$((warm_ts + warm_ttl))" 2>/dev/null
  if [ -n "$death_time" ]; then
    ctx_tokens_part=" ${DIM}→${death_time}${RESET}"
    [ "$warm_ttl" -lt 3600 ] 2>/dev/null && ctx_warn_part="${YELLOW}↓5m${RESET}"
  fi
elif [ -n "$ctx_tokens" ] && [ "$ctx_tokens" -ge 0 ] 2>/dev/null; then
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

cb_show=0
if [ -n "$acct" ] && [ "$acct" != main ]; then
  cb_show=1
fi

# Unified short forms for every model and effort this line prints: first letter plus the first
# consonant after it, uppercased, with the version digits glued on (Fable 5 → FB5, astra → AS). A
# name with no consonant to take has no short form and is printed whole.
abbrev_effort() { # var effort
  case "$2" in
    low) printf -v "$1" low ;; medium) printf -v "$1" med ;; high) printf -v "$1" hi ;;
    xhigh) printf -v "$1" xhi ;; max) printf -v "$1" max ;;
    *) printf -v "$1" '%s' "$2" ;;
  esac
}
abbrev_model() { # var display-name
  local out="$1" name="$2" letters version="" first second="" i c
  letters=${name%%[^A-Za-z]*}
  # Only the version that follows the name: a display name can carry digits further along
  # (`Opus 5 (1M context)`), and collecting all of them would print a version nobody released.
  [[ "${name#"$letters"}" =~ ^[[:space:]_-]*([0-9]+(\.[0-9]+)*) ]] && version="${BASH_REMATCH[1]}"
  first=${letters:0:1}
  i=1
  while [ "$i" -lt "${#letters}" ]; do
    c=${letters:$i:1}
    case "$c" in
      [AEIOUaeiou]) ;;
      *) second=$c; break ;;
    esac
    i=$((i + 1))
  done
  if [ -z "$first" ] || [ -z "$second" ]; then
    printf -v "$out" '%s' "$name"
    return
  fi
  printf -v "$out" '%s%s%s' "${first^^}" "${second^^}" "$version"
}

# Chat file only (global pin is the menu's); claudeb_profile=* renders `claude`.
pin_body=""
if [ -n "$session_id" ]; then
  pin_file="${CHAT_PINS_DIR:-$HOME/.cache/claude-chat-pins}/$session_id"
  if [ -s "$pin_file" ]; then
    IFS= read -r pin_line < "$pin_file" || :
    case "$pin_line" in
      open=all) pin_body="${MAGENTA}all${RESET}" ;;
      claudeb_profile=*|codex_profile=*|gemini_profile=*|grok_profile=*)
        pin_vendor=${pin_line%%_profile=*}
        pin_val=${pin_line#*_profile=}
        pin_label=$pin_val
        if [ "$pin_val" = '*' ]; then
          case "$pin_vendor" in
            claudeb) pin_label=claude ;;
            *) pin_label=$pin_vendor ;;
          esac
        fi
        if [ -n "$pin_label" ]; then
          # The pin's own second line, so it is read off the same file on the same tick.
          while IFS= read -r pin_setting || [ -n "$pin_setting" ]; do
            [ "$pin_setting" = "${pin_vendor}_fast=on" ] && { pin_label="${pin_label}⚡"; break; }
          done < "$pin_file"
          pin_body="${MAGENTA}${pin_label}${RESET}"
        fi
        ;;
    esac
  fi
fi

# Too slow for the render path: read the cache, fire the probe in the background
# when it's >15s stale, and hide the segment once it's >60s stale (probe presumed dead).
# The probe collects every tree of the session's own project and writes the tree beside each port;
# the COLOUR is what says whose tree it is, since a caption beside each one would widen the strip
# (Egor, 2026-09-04). The segment sits inside the atomic middle block, so it answers for the SHOWN
# tree: a worktree shows its own ports and nothing else, while the main checkout shows the whole
# project — its own ports bright, every worktree's dim, so the root is where everything that is up
# can be seen. A port no tree of the project holds (`-`) is one this session parents itself and has
# no tree to disagree with, so it stays bright in every view.
ports_part=""
if [ -n "$session_id" ]; then
  probe_bin="$statusline_dir/statusline-ports-probe.sh"
  ports_cache="$statusline_cache_dir/ports-$session_id"
  file_mtime_to ports_mtime "$ports_cache"
  if { ! [[ "$ports_mtime" =~ ^[0-9]+$ ]] || [ "$((now - ports_mtime))" -gt 15 ]; } && [ -x "$probe_bin" ]; then
    ( "$probe_bin" "$session_id" "$PPID" "${project_top:-$active_top}" >/dev/null 2>&1 & ) 2>/dev/null
  fi
  if [[ "$ports_mtime" =~ ^[0-9]+$ ]] && [ "$((now - ports_mtime))" -le 60 ]; then
    ports_own=""; ports_away=""
    # `read` still sets the vars on a newline-less EOF, so the last record counts on that return.
    while IFS=$'\t' read -r ports_port ports_tree || [ -n "$ports_port" ]; do
      [[ "$ports_port" =~ ^[0-9]+$ ]] || continue
      [ "$active_common" = "$project_common" ] || continue
      if [ -z "$ports_tree" ] || [ "$ports_tree" = - ] || [ "$ports_tree" = "$active_top" ]; then
        ports_own="${ports_own} ${ports_port}"
      elif [ "$active_is_wt" != 1 ]; then
        ports_away="${ports_away} ${ports_port}"
      fi
    done < "$ports_cache" 2>/dev/null
    ports_render=""; ports_count=0
    # Own tree first, so the three-port cap can never spend itself on siblings and hide the one
    # port Egor is here to open.
    for p in $ports_own; do
      [ "$ports_count" -ge 3 ] && break
      ports_render="${ports_render} ${GREEN}:${p}${RESET}"
      ports_count=$((ports_count + 1))
    done
    for p in $ports_away; do
      [ "$ports_count" -ge 3 ] && break
      ports_render="${ports_render} ${DIM}:${p}${RESET}"
      ports_count=$((ports_count + 1))
    done
    [ -n "$ports_render" ] && ports_part=" ${DIM}⇢${RESET}${ports_render}"
  fi
fi

repo_debt=""
[ -n "$active_top" ] && repo_debt_lines repo_debt "$active_top" "$now" "$branch_oid|$udiff_add|$udiff_del|$fparts"

review_autonomous=no
if [ -n "$session_id" ]; then
  review_session_line review_autonomous "$session_id" "$now"
fi

# Never dimmed: a commit of this chat that its upstream does not contain is this chat's own to act
# on, and the flow it belongs to ends at the push. Asked about the shown tree.
unpushed_show=0
if [ -n "$active_top" ]; then
  unpushed_marker unpushed_answer "$active_top" "$session_id" "$now"
  [ "$unpushed_answer" = unpushed ] && unpushed_show=1
fi

# Both lines are built to the terminal's width, not printed once: the harness exports COLUMNS and
# cuts a row at the right edge, a few cells before COLUMNS. Every shrinkable segment has full /
# short / off forms; the steps below are applied in a fixed order, re-measuring after each
# (docs/statusline-contract.md "Progressive fit"). The red alarm blocks and `↓N↑N` have no `off`
# form at all — a width small enough to need them gone is a width that keeps them.
STATUSLINE_FIT_MARGIN=${STATUSLINE_FIT_MARGIN:-3}
if [[ "$STATUSLINE_FIT_MARGIN" =~ ^[0-9]+$ ]]; then
  STATUSLINE_FIT_MARGIN=$((10#$STATUSLINE_FIT_MARGIN))
else
  STATUSLINE_FIT_MARGIN=3
fi
fit_repo_debt=1
fit_diff_sign=1
fit_branch_glyph=1
fit_branch_short=0
fit_dir_mode=full
fit_model_short=0
fit_pin=1
fit_unpushed_short=0
fit_dir_active_only=0
fit_dir_off=0
fit_acct_max=0
fit2_cost=1
fit2_pct=1
fit2_labels=full
fit2_sep=1

# Bash patterns have no quantifier — `*` after a bracket expression matches anything, not "more of
# the class" — so the escapes are removed as the literal color strings that produced them.
fit_width() {
  local s=$1
  s=${s//"$RESET"/}; s=${s//"$CYAN"/}; s=${s//"$BLUE"/}; s=${s//"$DIM"/}
  s=${s//"$GREEN"/}; s=${s//"$YELLOW"/}; s=${s//"$RED"/}; s=${s//"$MAGENTA"/}
  fit_len=${#s}
}

fit_trunc() {
  fit_out=$1
  [ "${#fit_out}" -le "$2" ] || fit_out=${fit_out:0:$2}
}

fit_dir_short_len=8

fit_initials() {
  local rest word out=""
  case "$1" in
    *-*|*_*)
      rest=${1//_/-}
      while [ -n "$rest" ]; do
        word=${rest%%-*}
        [ -n "$word" ] && out="${out}${word:0:1}"
        [ "$word" = "$rest" ] && break
        rest=${rest#*-}
      done
      ;;
  esac
  [ -n "$out" ] || out=${1:0:3}
  # Initials of a many-word name can be longer than step 4's cut, so this step would GROW the line
  # and cost the directory its place further down the ladder.
  fit_trunc "$1" "$fit_dir_short_len"
  [ "${#out}" -le "${#fit_out}" ] || out=$fit_out
  fit_out=$out
}

fit_dir_name() {
  # A worktree folder is `<TICKET>-junk` and the digits ARE its identity, so — as in
  # fit_branch_part — the ticket prefix is the floor: no cut into the digits, no initials.
  if [[ "$1" =~ ^([A-Za-z]+[-_][0-9]+) ]]; then
    case "$fit_dir_mode" in
      full) fit_out=$1 ;;
      short)
        fit_trunc "$1" "$fit_dir_short_len"
        [ "${#fit_out}" -ge "${#BASH_REMATCH[1]}" ] || fit_out="${BASH_REMATCH[1]}"
        ;;
      *) fit_out="${BASH_REMATCH[1]}" ;;
    esac
    return
  fi
  case "$fit_dir_mode" in
    initials) fit_initials "$1" ;;
    short) fit_trunc "$1" "$fit_dir_short_len" ;;
    *) fit_out=$1 ;;
  esac
}

fit_head_part() {
  local head
  if [ "$fit_model_short" = 1 ]; then
    head="$model_abbrev${effort_abbrev:+ $effort_abbrev}"
  else
    head="${model}${model_suffix}"
  fi
  head_part="${CYAN}${head}${RESET}"
}

fit_cb_part() {
  local name=$acct
  cb_part=""
  if [ -n "${CLAUDEGPT_ACCOUNT:-}" ]; then
    name=$CLAUDEGPT_ACCOUNT
  else
    [ "$cb_show" = 1 ] || return
  fi
  if [ "$fit_acct_max" -gt 0 ]; then
    fit_trunc "$name" "$fit_acct_max"
    name=$fit_out
  fi
  cb_part=" ${MAGENTA}${name}${RESET}"
}

fit_dir_part() {
  local left right gap=" "
  dir_part=""
  [ "$fit_dir_off" = 1 ] && return
  [ "$fit_dir_mode" = initials ] && gap=""
  fit_dir_name "$dir"
  left=$fit_out
  if [ "$dir_foreign" = 1 ]; then
    fit_dir_name "$active_name"
    right=$fit_out
    if [ "$fit_dir_active_only" = 1 ]; then
      dir_part="${BLUE}${right}${RESET}"
    else
      dir_part="${DIM}${left}${RESET}${gap}${MAGENTA}»${RESET}${gap}${BLUE}${right}${RESET}"
    fi
  else
    dir_part="${BLUE}${left}${RESET}"
  fi
  if [ "$wt_show" = 1 ]; then
    fit_dir_name "$wt_name"
    dir_part="${dir_part} ${wt_color}⧉ ${fit_out}${RESET}"
  fi
}

fit_branch_part() {
  local label
  branch_part=""
  if [ "$branch_show" = 1 ]; then
    if [ "$branch_is_sha" = 1 ]; then
      label="${RED}@${branch_sha}${RESET}"
      [ "$fit_branch_glyph" = 1 ] && label="${BLUE}⎇${RESET} ${label}"
    else
      label=$branch_name
      if [ "$fit_branch_short" = 1 ]; then
        if [[ "$label" =~ ^([A-Za-z]+-[0-9]+) ]]; then
          label="${BASH_REMATCH[1]}"
        else
          fit_trunc "$label" 7
          label=$fit_out
        fi
      fi
      if [ "$fit_branch_glyph" = 1 ]; then
        label="${BLUE}⎇ ${label}${RESET}"
      else
        label="${BLUE}${label}${RESET}"
      fi
    fi
    branch_part=" ${label}"
  fi
  if [ "$diff_show" = lines ]; then
    if [ "$fit_diff_sign" = 1 ]; then
      branch_part="${branch_part} ${GREEN}+${udiff_add}${RESET}/${RED}-${udiff_del}${RESET}"
    else
      branch_part="${branch_part} ${GREEN}${udiff_add}${RESET}/${RED}${udiff_del}${RESET}"
    fi
  elif [ "$diff_show" = files ]; then
    branch_part="${branch_part} ${DIM}${fparts}f${RESET}"
  fi
  if [ "$fit_repo_debt" = 1 ] && [ -n "$repo_debt" ] && [ "$repo_debt" -gt 0 ] 2>/dev/null; then
    branch_part="${branch_part} ${DIM}${repo_debt}${RESET}"
  fi
  [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null &&
    branch_part="${branch_part} ${MAGENTA}↓${behind}${RESET}"
  [ -n "$ahead" ] && [ "$ahead" -gt 0 ] 2>/dev/null &&
    branch_part="${branch_part} ${MAGENTA}↑${ahead}${RESET}"
}

fit_verdict_part() {
  verdict_part=""
  [ "$review_autonomous" = yes ] && verdict_part=" ${sep} ●"
}

fit_unpushed_part() {
  unpushed_part=""
  [ "$unpushed_show" = 1 ] || return
  if [ "$fit_unpushed_short" = 1 ]; then
    unpushed_part=" ${sep} ${RED}↑!${RESET}"
  else
    unpushed_part=" ${sep} unpushed"
  fi
}

fit_pin_part() {
  pin_part=""
  [ "$fit_pin" = 1 ] || return
  [ -n "$pin_body" ] || return
  pin_part=" ${sep} ${pin_body}"
}

# Two lines: identity/work (model, account, dir/branch/diff, pin) on top,
# usage (ctx, 5h, weekly, fable, cost) below.
fit_compose() {
  local work
  fit_head_part
  fit_cb_part
  fit_dir_part
  fit_branch_part
  fit_verdict_part
  fit_unpushed_part
  fit_pin_part
  work="${dir_part}${branch_part}${ports_part}"
  work=${work# }
  line1="${head_part}${cb_part}"
  [ -n "$work" ] && line1="${line1} ${sep} ${work}"
  line1="${line1}${verdict_part}${unpushed_part}${pin_part}"
}

fit_label() {
  fit_out=""
  [ -n "$1" ] || return
  case "$fit2_labels" in
    off) return ;;
    short)
      if [[ "$1" =~ ^([A-Z][a-z][a-z])\ [0-9][0-9]:[0-9][0-9]$ ]]; then
        fit_out=" ${DIM}${BASH_REMATCH[1]}${RESET}"
        return
      elif [[ "$1" =~ ^([0-9][0-9]):[0-9][0-9]$ ]]; then
        fit_out=" ${DIM}${BASH_REMATCH[1]}h${RESET}"
        return
      fi
      ;;
  esac
  fit_out=" ${DIM}${1}${RESET}"
}

fit_compose2() {
  local gap=" ${sep} "
  [ "$fit2_sep" = 1 ] || gap=" "
  line2="ctx"
  if [ "$fit2_pct" = 1 ] || [ -z "$ctx_tokens_part" ]; then line2="ctx ${ctx_pct_part}"; fi
  line2="${line2}${ctx_tokens_part}${ctx_warn_part}"
  if [ "$h5_absent" != true ]; then
    fit_label "$h5_time"
    line2="${line2}${gap}5h ${h5_pct_part}${fit_out}"
  fi
  fit_label "$wk_arrow_txt"
  line2="${line2}${gap}wk ${wk_pct_part}${fit_out}"
  if [ -n "$fable_pct_part" ]; then
    fit_label "$fable_reset_txt"
    line2="${line2}${gap}fb ${fable_pct_part}${fit_out}"
  fi
  [ -n "$store_stale_txt" ] && line2="${line2}${gap}${RED}stale ${store_stale_txt}${RESET}"
  [ "$fit2_cost" = 1 ] && [ -n "$cost_part" ] && line2="${line2}${gap}${cost_part}"
}

abbrev_model model_abbrev "$model"
effort_abbrev=""
[ -n "$effort" ] && abbrev_effort effort_abbrev "$effort"

fit_cols=${COLUMNS:-}
if [[ "$fit_cols" =~ ^[0-9]+$ ]] && [ "$fit_cols" -gt 0 ]; then
  fit_cols=$((fit_cols - STATUSLINE_FIT_MARGIN))
else
  fit_cols=""
fi
fit_compose
if [ -n "$fit_cols" ]; then
  for fit_step in 1 2 3 4 5 6 7 8 9 10 11; do
    fit_width "$line1"
    [ "$fit_len" -le "$fit_cols" ] && break
    case "$fit_step" in
      1) fit_diff_sign=0 ;;
      2) fit_branch_glyph=0 ;;
      3) fit_branch_short=1 ;;
      4)
        fit_acct_max=7
        fit_dir_short_len=${#dir}
        [ "$dir_foreign" = 1 ] && [ "${#active_name}" -gt "$fit_dir_short_len" ] &&
          fit_dir_short_len=${#active_name}
        [ "$wt_show" = 1 ] && [ "${#wt_name}" -gt "$fit_dir_short_len" ] &&
          fit_dir_short_len=${#wt_name}
        fit_dir_mode=short
        fit_compose
        fit_width "$line1"
        while [ "$fit_len" -gt "$fit_cols" ] && [ "$fit_dir_short_len" -gt 8 ]; do
          fit_dir_short_len=$((fit_dir_short_len - 1))
          fit_compose
          fit_width "$line1"
        done
        [ "$fit_dir_short_len" -ge 8 ] || fit_dir_short_len=8
        ;;
      5) fit_model_short=1 ;;
      6) fit_acct_max=4; fit_dir_mode=initials ;;
      7) fit_repo_debt=0 ;;
      8) fit_pin=0; fit_unpushed_short=1 ;;
      9) fit_dir_active_only=1 ;;
      10) fit_dir_off=1 ;;
      11) fit_acct_max=3 ;;
    esac
    fit_compose
  done
fi

pct_colored ctx_pct_part "$ctx_pct" "$ctx_dim" 40
pct_colored wk_pct_part "$wk_pct" "$wk_dim"
cost_part=""
if [ -n "$cost_raw" ]; then
  LC_ALL=C printf -v cost_fmt '%.2f' "$cost_raw" 2>/dev/null
  cost_part="${DIM}\$${cost_fmt}${RESET}"
fi
fit_compose2
if [ -n "$fit_cols" ]; then
  for fit_step in 1 2 3 4 5; do
    fit_width "$line2"
    [ "$fit_len" -le "$fit_cols" ] && break
    case "$fit_step" in
      1) fit2_cost=0 ;;
      2) fit2_labels=short ;;
      3) fit2_labels=off ;;
      4) fit2_sep=0 ;;
      5) fit2_pct=0 ;;
    esac
    fit_compose2
  done
fi

# Work lines (docs/statusline-contract.md, "Work lines"): the probe walks the process tree in the
# background; the render reads its cache only, and the elapsed time is recomputed here every render.
work_rows=()
if [ -n "$session_id" ]; then
  work_bin="$statusline_dir/statusline-work-probe.sh"
  work_cache="$statusline_cache_dir/work-$session_id"
  file_mtime_to work_mtime "$work_cache"
  if { ! [[ "$work_mtime" =~ ^[0-9]+$ ]] || [ "$((now - work_mtime))" -gt 4 ]; } && [ -x "$work_bin" ]; then
    ( "$work_bin" "$session_id" "$PPID" >/dev/null 2>&1 & ) 2>/dev/null
  fi
  work_more=0
  if [[ "$work_mtime" =~ ^[0-9]+$ ]] && [ "$((now - work_mtime))" -le 15 ]; then
    # Split on \037: tab is IFS whitespace, so `read` would fold an empty repo into the label.
    while IFS= read -r work_line || [ -n "$work_line" ]; do
      IFS=$'\037' read -r w_kind w_class w_start w_repo w_label w_done w_failed w_total _ <<<"${work_line//$'\t'/$'\037'}"
      [ "$w_kind" = main ] && [[ "$w_start" =~ ^[0-9]+$ ]] || continue
      if [ "${#work_rows[@]}" -ge 3 ]; then work_more=$((work_more + 1)); continue; fi
      w_secs=$((now - w_start))
      [ "$w_secs" -ge 0 ] || w_secs=0
      if [ "$w_secs" -lt 60 ]; then w_el="${w_secs}s"
      elif [ "$w_secs" -lt 3600 ]; then w_el="$((w_secs / 60))m $((w_secs % 60))s"
      else w_el="$((w_secs / 3600))h $(((w_secs % 3600) / 60))m"
      fi
      w_count="" w_count_color=""
      if [[ "$w_total" =~ ^[0-9]+$ ]] && [[ "$w_done" =~ ^[0-9]+$ ]]; then
        w_count="$w_done/$w_total" w_count_color="$w_done/$w_total"
        if [[ "$w_failed" =~ ^[1-9][0-9]*$ ]]; then
          w_count="$w_count ✗$w_failed" w_count_color="$w_count_color ${RESET}${RED}✗$w_failed${RESET}${DIM}"
        fi
      fi
      w_compose() {
        w_row="${MAGENTA}${w_class}${w_repo:+ · $w_repo}${RESET}"
        [ -z "$w_label$w_count" ] || w_row="$w_row ${DIM}· ${w_label}${w_label:+${w_count:+ }}${w_count_color}${RESET}"
        w_row="$w_row ${DIM}· ${w_el}${RESET}"
      }
      w_compose
      if [ -n "$fit_cols" ]; then
        fit_width "$w_row"
        [ "$fit_len" -le "$fit_cols" ] || [ "$w_class" = media ] || { w_repo=""; w_compose; fit_width "$w_row"; }
        if [ "$fit_len" -gt "$fit_cols" ] && [ -n "$w_label" ]; then
          w_keep=$(( ${#w_label} - (fit_len - fit_cols) - 1 ))
          if [ "$w_keep" -ge 1 ]; then w_label="${w_label:0:w_keep}…"; else w_label=""; fi
          w_compose
        fi
      fi
      work_rows+=("$w_row")
    done < "$work_cache"
    [ "$work_more" -eq 0 ] || work_rows[2]="${work_rows[2]} ${DIM}· +${work_more}${RESET}"
  fi
fi

printf '%s\n%s' "$line1" "$line2"
for w_row in ${work_rows[@]+"${work_rows[@]}"}; do printf '\n%s' "$w_row"; done
statusline_rc=$?

# Render timing for the Harness doctor, which prunes the files itself. One O_APPEND write per
# render keeps concurrent sessions' lines whole without a lock.
statusline_timing_dir="${HARNESS_DOCTOR_DIR:-$HOME/.cache/harness-doctor}/statusline"
printf -v statusline_day '%(%Y-%m-%d)T' -1
statusline_end_us=${EPOCHREALTIME//[!0-9]/}
self_cpu_ms
statusline_cpu_ms=$cpu_ms
printf '%s\t%s\t%s\t%s\n' "$statusline_start_us" "$statusline_end_us" "$session_id" "$statusline_cpu_ms" \
  2>/dev/null >> "$statusline_timing_dir/$statusline_day.tsv" ||
  { ensure_dir "$statusline_timing_dir" 2>/dev/null &&
    printf '%s\t%s\t%s\t%s\n' "$statusline_start_us" "$statusline_end_us" "$session_id" "$statusline_cpu_ms" \
      2>/dev/null >> "$statusline_timing_dir/$statusline_day.tsv"; }
exit "$statusline_rc"
exit; }
