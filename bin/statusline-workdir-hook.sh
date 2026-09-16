#!/usr/bin/env bash
# Writes this chat's place journal (bin/statusline-place): one declared line per event that says
# where the chat's changes go. The statusline shows the last line's tree; nothing here decides it.
exec >/dev/null 2>&1

self=$(realpath "${BASH_SOURCE[0]}") || self=${BASH_SOURCE[0]}
bin_dir=$(dirname "$self")
place="$bin_dir/statusline-place"
input=$(cat) || exit 0
parsed=$(printf '%s' "$input" | jq -r -f "$bin_dir/../share/statusline-workdir.jq") || exit 0
IFS=$'\x1f' read -r hook_event tool_name session_id base_dir agent_flag candidate bash_subshell \
  bash_read_only bash_worktree bash_worktree_base bash_cd_hit tool_use_id dispatch bash_writes \
  transcript <<< "$parsed"
[ -n "$session_id" ] || exit 0

cache_dir="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}"
journal="$cache_dir/place-$session_id"
[ -n "$base_dir" ] || base_dir=.
add() { "$place" add --session "$session_id" --kind "$1" --path "$2"; }

unquote() {
  case "$1" in
    \"*\") local v=${1:1:${#1}-2}; v=${v//\\\"/\"}; printf '%s' "${v//\\\\/\\}" ;;
    \'*\') printf '%s' "${1:1:${#1}-2}" ;;
    *) printf '%s' "$1" ;;
  esac
}

resolve_dir() { # token [base] -> physical directory
  local c=$1
  case "$c" in
    '$HOME'|'${HOME}'|'~') c=$HOME ;;
    '$HOME/'*) c="$HOME/${c:6}" ;;
    '${HOME}/'*) c="$HOME/${c:8}" ;;
    '~/'*) c="$HOME/${c#\~/}" ;;
  esac
  [[ "$c" = /* ]] || c="${2:-$base_dir}/$c"
  (cd "$c" && pwd -P)
}

# SessionStart's agent_type is a top-level `claude --agent` session, not a subagent.
if [ "$hook_event" = SessionStart ]; then
  [ -s "$journal" ] && exit 0
  # A /branch fork is a new session id whose transcript opens with the parent it was forked from.
  parent=$([ -r "$transcript" ] && head -n 1 "$transcript" | jq -r '.forkedFrom.sessionId // empty')
  parent=${parent//[^A-Za-z0-9_-]/}
  if [ -n "$parent" ] && [ "$parent" != "$session_id" ] && [ -s "$cache_dir/place-$parent" ]; then
    umask 077
    cp "$cache_dir/place-$parent" "$journal.tmp.$$" && mv -f "$journal.tmp.$$" "$journal" && exit 0
    rm -f "$journal.tmp.$$"
  fi
  add seed "$base_dir"
  exit 0
fi
# Subagent events carry the PARENT session_id: only their edits are the chat's changes.
if [ -n "$agent_flag" ]; then
  case "$tool_name" in Edit|Write|NotebookEdit) ;; *) exit 0 ;; esac
fi

# A worktree add/move is heard twice: PreToolUse snapshots the worktree lists its PostToolUse
# diffs against, since `git -C $R worktree add $N` expands in the shell the hook never sees.
snap="$journal.snap${tool_use_id:+.$tool_use_id}"
bash_worktree_base=$(unquote "$bash_worktree_base")
worktree_union() {
  local repo dir last=
  last=$(tail -n 1 "$journal" 2>/dev/null | cut -f3)
  for repo in "$bash_worktree_base" "$base_dir" "$last"; do
    [ -n "$repo" ] && dir=$(resolve_dir "$repo") || continue
    git -C "$dir" worktree list --porcelain | sed -n 's/^worktree //p'
  done | sort -u
}

case "$hook_event:$tool_name" in
  PreToolUse:Bash)
    [ -n "$bash_worktree" ] || exit 0
    mkdir -p "$cache_dir" && umask 077 || exit 0
    # An empty snapshot is no baseline: no file is what sends PostToolUse to the parsed path.
    { worktree_union > "$snap.tmp.$$" && [ -s "$snap.tmp.$$" ] && mv -f "$snap.tmp.$$" "$snap"; } ||
      rm -f "$snap.tmp.$$" "$snap"
    ;;
  PreToolUse:Task|PreToolUse:Agent)
    IFS=$'\x1e' read -r -a dispatch_candidates <<< "$dispatch"
    for c in "${dispatch_candidates[@]}"; do
      [ -d "$c" ] && add dispatch "$c" && break
    done
    ;;
  PostToolUse:Edit|PostToolUse:Write|PostToolUse:NotebookEdit)
    [ -n "$candidate" ] && add edit "$candidate" ;;
  PostToolUse:EnterWorktree) [ -n "$candidate" ] && add enter-worktree "$candidate" ;;
  PostToolUse:ExitWorktree) add exit-worktree "${CLAUDE_PROJECT_DIR:-$base_dir}" ;;
  PostToolUse:Bash)
    candidate=$(unquote "$candidate")
    # `cd -` in the resolution subshell lands on the hook's own OLDPWD, not the session's.
    case "$candidate" in -*) exit 0 ;; esac
    if [ -n "$bash_worktree" ]; then
      new=""
      if [ -f "$snap" ]; then
        # Exactly one new worktree is the one this command made; none is a failed add, several a
        # concurrent one the diff cannot attribute — both leave the journal alone.
        new=$(worktree_union | comm -13 "$snap" -)
        rm -f "$snap"
        case "$new" in ''|*$'\n'*) exit 0 ;; esac
      fi
      if [ -n "$bash_worktree_base" ] && [[ "$candidate" != /* ]]; then
        base_dir=$(resolve_dir "$bash_worktree_base") || { [ -n "$new" ] || exit 0; candidate=$new; }
      fi
      if [ -n "$new" ]; then
        # A named directory that exists is the one it made; a `$` token is an unexpanded variable.
        case "$candidate" in
          *'$'*) ;;
          *) named=$(resolve_dir "$candidate") && [ "$named" != "$(resolve_dir "$new")" ] && exit 0 ;;
        esac
        candidate=$new
      fi
      [ -n "$candidate" ] || exit 0
      # With no snapshot the parsed path must be a worktree's own toplevel, never a subdir or a
      # directory the failed add left alone.
      dir=$(resolve_dir "$candidate") || exit 0
      top=$(git -C "$dir" rev-parse --show-toplevel) && [ "$(resolve_dir "$top")" = "$dir" ] || exit 0
      add enter-worktree "$dir"
    elif [ -n "$candidate" ] && [ -n "$bash_cd_hit" ] && [ -z "$bash_subshell" ]; then
      dir=$(resolve_dir "$candidate") && add cd "$dir"
    elif [ -n "$candidate" ] && [ -z "$bash_read_only" ]; then
      dir=$(resolve_dir "$candidate") && add git "$dir"
    elif [ -n "$bash_writes" ]; then
      IFS=$'\x1e' read -r -a write_paths <<< "$bash_writes"
      for p in "${write_paths[@]}"; do
        while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
        add edit "$p" && break
      done
    fi
    ;;
esac

marker="$cache_dir/.place-prune"
[ -d "$cache_dir" ] && [ -z "$(find "$marker" -mmin -60)" ] || exit 0
find "$cache_dir" -type f -name 'place-*' -mtime +7 -delete
# A denied command fires PreToolUse and never the PostToolUse that consumes its snapshot.
find "$cache_dir" -type f -name 'place-*.snap*' -mmin +60 -delete
touch "$marker"
