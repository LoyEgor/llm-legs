#!/usr/bin/env bash

exec >/dev/null 2>&1

input=$(cat) || exit 0
parsed=$(printf '%s' "$input" | jq -r '
  def value: if . == null then "" else tostring end;
  def bash_path:
    "\\\"(?:\\\\.|[^\\\"])*\\\"|\\x27[^\\x27]*\\x27|[^[:space:];&|]+" as $tok
    | (.tool_input.command // "")
    | [match("(^|[;&|\\n])[[:space:]]*((cd|pushd)[[:space:]]+(?<cd>" + $tok + ")|git[[:space:]]+-C[[:space:]]+(?<dir>" + $tok + ")([[:space:]]+(?<sub>[A-Za-z][A-Za-z-]*))?)"; "g")]
    | map(
        ([.captures[] | select(.name == "cd" and .string != null) | .string][0] // "") as $cd
        | ([.captures[] | select(.name == "dir" and .string != null) | .string][0] // "") as $dir
        | ([.captures[] | select(.name == "sub" and .string != null) | .string][0] // "") as $sub
        | if $cd != "" then $cd
          elif $dir != "" and (["worktree","checkout","switch","commit","merge","rebase","cherry-pick","revert","restore","stash","am","reset","pull"] | index($sub) != null) then $dir
          else "" end)
    | map(select(. != ""))
    | (last // "");
  def worktree_path:
    (.tool_response // "")
    | (if type == "string" then . elif type == "object" then ([.. | strings] | join("\n")) else "" end)
    | ([capture("worktree at (?<wt>/[^\\n]+)")] | (.[0].wt // ""))
    | gsub("[[:space:]]+$"; "");
  [(.hook_event_name | value), (.tool_name | value), (.session_id | value | gsub("[^A-Za-z0-9_-]"; "")),
   (.cwd | value),
   (if (.agent_id | value) != "" or (.agent_type | value) != "" then "1" else "" end),
   (if .tool_name == "Edit" or .tool_name == "Write" then (.tool_input.file_path | value)
    elif .tool_name == "NotebookEdit" then (.tool_input.notebook_path | value)
    elif .tool_name == "Bash" then bash_path
    elif .tool_name == "EnterWorktree" then worktree_path
    else "" end),
   (.source | value)]
  | join("")
' 2>/dev/null) || exit 0

IFS=$'\x1f' read -r hook_event tool_name session_id base_dir agent_flag candidate start_source <<< "$parsed"
[ -n "$session_id" ] || exit 0

cache_dir="$HOME/.cache/claude-statusline"
state_file="$cache_dir/workdir-$session_id"

# Before the agent filter on purpose: SessionStart's agent_type means a
# top-level `claude --agent` session, not a subagent.
if [ "$hook_event" = SessionStart ]; then
  # Cleared AND re-seeded from the session's starting cwd: with no state, the
  # first cd/edit anywhere adopts THAT dir as home (a one-off cd into a sibling
  # worktree retargets the ports segment), and the worktree stickiness below can
  # only protect a home that already exists. compact keeps the shell and its
  # cwd, so its state stays valid and is left alone.
  case "$start_source" in
    startup|resume|clear)
      rm -f "$state_file" "$state_file.gone"
      seed=$(git -C "${base_dir:-.}" rev-parse --show-toplevel 2>/dev/null) &&
        seed=$(cd "$seed" 2>/dev/null && pwd -P) && [ -n "$seed" ] && {
          umask 077
          mkdir -p "$cache_dir" 2>/dev/null &&
            printf '%s\n' "$seed" > "$state_file.tmp.$$" 2>/dev/null &&
            mv -f "$state_file.tmp.$$" "$state_file" 2>/dev/null ||
            rm -f "$state_file.tmp.$$" 2>/dev/null
        }
      ;;
  esac
  exit 0
fi

[ "$hook_event" = PostToolUse ] || exit 0
# Subagent tool events carry the PARENT session_id: letting them through
# would retarget the parent's statusline to wherever a worker happened to cd.
[ -z "$agent_flag" ] || exit 0

case "$tool_name" in
  ExitWorktree)
    rm -f "$state_file" "$state_file.gone"
    exit 0
    ;;
  EnterWorktree)
    [ -n "$candidate" ] || exit 0
    ;;
  Edit|Write|NotebookEdit)
    [ -n "$candidate" ] || exit 0
    candidate=$(dirname -- "$candidate") || exit 0
    ;;
  Bash)
    [ -n "$candidate" ] || exit 0
    case "$candidate" in
      \"*\")
        candidate=${candidate:1:${#candidate}-2}
        candidate=${candidate//\\\"/\"}
        candidate=${candidate//\\\\/\\}
        ;;
      \'*\') candidate=${candidate:1:${#candidate}-2} ;;
    esac
    # `cd "-"` in the resolution subshell lands on the hook's own OLDPWD, not the session's.
    case "$candidate" in
      -*) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac

case "$candidate" in
  '$HOME') candidate=$HOME ;;
  '$HOME/'*) candidate="$HOME/${candidate:6}" ;;
  '${HOME}') candidate=$HOME ;;
  '${HOME}/'*) candidate="$HOME/${candidate:8}" ;;
  '~') candidate=$HOME ;;
  '~/'*) candidate="$HOME/${candidate#\~/}" ;;
esac

# Checked on the logical path too, not only on $resolved below: ~/.claude/hooks
# is a symlink into the claude-setup checkout, so after pwd -P the exclusion no
# longer matches and a hook-file write retargets the statusline to that repo.
case "$candidate" in
  "$HOME"/.cache|"$HOME"/.cache/*|"$HOME"/.claude*) exit 0 ;;
esac

[ -n "$base_dir" ] || base_dir=.
if [[ "$candidate" = /* ]]; then
  resolved=$(cd "$candidate" 2>/dev/null && pwd -P) || exit 0
else
  resolved=$(cd "$base_dir" 2>/dev/null && cd "$candidate" 2>/dev/null && pwd -P) || exit 0
fi

tmp_root=${TMPDIR:-}
tmp_root=${tmp_root%/}
case "$resolved" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|"$HOME"/.cache|"$HOME"/.cache/*|"$HOME"/.claude*) exit 0 ;;
esac
if [ -n "$tmp_root" ] && { [ "$resolved" = "$tmp_root" ] || [[ "$resolved" == "$tmp_root/"* ]]; }; then
  exit 0
fi
case "$resolved/" in
  */node_modules/*) exit 0 ;;
esac

toplevel=$(git -C "$resolved" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -d "$toplevel" ] || exit 0
toplevel=$(cd "$toplevel" 2>/dev/null && pwd -P) || exit 0

# A worktree home is absolutely sticky: it is a deliberate, harness-created
# context, and a cd/edit anywhere else — sibling worktree, main checkout, or a
# different repository entirely (test runs, config surgery) — is one-off work
# that used to retarget the statusline (and its ports segment) to another
# workspace. Only EnterWorktree moves such a home; ExitWorktree clears it and
# SessionStart re-seeds it above. Non-worktree homes still follow every cd.
if [ "$tool_name" != EnterWorktree ] && [ -f "$state_file" ]; then
  IFS= read -r prev_home < "$state_file" || :
  case "$prev_home" in
    */.claude/worktrees/*) [ "$toplevel" = "$prev_home" ] || exit 0 ;;
  esac
fi

mkdir -p "$cache_dir" || exit 0
umask 077
tmp_file="$state_file.tmp.$$"
trap 'rm -f "$tmp_file" 2>/dev/null; exit 0' EXIT
printf '%s\n' "$toplevel" > "$tmp_file" && mv -f "$tmp_file" "$state_file" &&
  rm -f "$state_file.gone"

marker="$cache_dir/.workdir-prune"
now=$(date +%s 2>/dev/null)
marker_mtime=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || printf '0')
if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$marker_mtime" =~ ^[0-9]+$ ]] && [ "$((now - marker_mtime))" -gt 3600 ]; then
  find "$cache_dir" -type f -name 'workdir-*' -mtime +7 -delete
  touch "$marker"
fi

exit 0
