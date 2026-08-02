#!/usr/bin/env bash

exec >/dev/null 2>&1

input=$(cat) || exit 0
parsed=$(printf '%s' "$input" | jq -r '
  def value: if . == null then "" else tostring end;
  def bash_hit:
    # `(` is a separator and is barred from unquoted tokens: the cd-guard hook
    # steers persistent `cd` into `(cd /path && cmd)`, where the path token
    # would otherwise swallow the closing paren. That separator is reported
    # because such a cd dies with the command — see the away run below.
    "\\\"(?:\\\\.|[^\\\"])*\\\"|\\x27[^\\x27]*\\x27|[^[:space:];&|()]+" as $tok
    | (.tool_input.command // "")
    | [match("(^|[;&|(\\n])[[:space:]]*((cd|pushd)[[:space:]]+(?<cd>" + $tok + ")|git[[:space:]]+-C[[:space:]]+(?<dir>" + $tok + ")([[:space:]]+(?<sub>[A-Za-z][A-Za-z-]*))?)"; "g")]
    | map(
        ([.captures[] | select(.name == "cd" and .string != null) | .string][0] // "") as $cd
        | ([.captures[] | select(.name == "dir" and .string != null) | .string][0] // "") as $dir
        | ([.captures[] | select(.name == "sub" and .string != null) | .string][0] // "") as $sub
        | (.captures[0].string // "") as $sep
        | if $cd != "" then {path: $cd, sep: $sep}
          elif $dir != "" and (["worktree","checkout","switch","commit","merge","rebase","cherry-pick","revert","restore","stash","am","reset","pull"] | index($sub) != null) then {path: $dir, sep: ""}
          else empty end)
    | (last // {path: "", sep: ""});
  def worktree_path:
    (.tool_response // "")
    | (if type == "string" then . elif type == "object" then ([.. | strings] | join("\n")) else "" end)
    | ([capture("worktree at (?<wt>/[^\\n]+)")] | (.[0].wt // ""))
    | gsub("[[:space:]]+$"; "");
  (if .tool_name == "Bash" then bash_hit else {path: "", sep: ""} end) as $bash
  | [(.hook_event_name | value), (.tool_name | value), (.session_id | value | gsub("[^A-Za-z0-9_-]"; "")),
   (.cwd | value),
   (if (.agent_id | value) != "" or (.agent_type | value) != "" then "1" else "" end),
   (if .tool_name == "Edit" or .tool_name == "Write" then (.tool_input.file_path | value)
    elif .tool_name == "NotebookEdit" then (.tool_input.notebook_path | value)
    elif .tool_name == "Bash" then $bash.path
    elif .tool_name == "EnterWorktree" then worktree_path
    else "" end),
   (.source | value),
   (if $bash.sep == "(" then "1" else "" end)]
  | join("")
' 2>/dev/null) || exit 0

IFS=$'\x1f' read -r hook_event tool_name session_id base_dir agent_flag candidate start_source bash_subshell <<< "$parsed"
[ -n "$session_id" ] || exit 0

cache_dir="$HOME/.cache/claude-statusline"
state_file="$cache_dir/workdir-$session_id"
away_file="$state_file.away"

# Before the agent filter on purpose: SessionStart's agent_type means a
# top-level `claude --agent` session, not a subagent.
if [ "$hook_event" = SessionStart ]; then
  # Cleared AND re-seeded from the session's starting cwd: with no state, the
  # first cd/edit anywhere adopts THAT dir as home (a one-off cd into a sibling
  # worktree retargets the ports segment), and the worktree stickiness below can
  # only protect a home that already exists. compact keeps the shell and its
  # cwd, so its state stays valid and is left alone. resume keeps a live
  # worktree home: the event's cwd is the dir the chat was LAUNCHED in (often
  # the main checkout), not where the work lives — reseeding from it would
  # retarget the strip and ports to the wrong workspace on every resume.
  case "$start_source" in
    startup|resume|clear)
      if [ "$start_source" = resume ] && [ -f "$state_file" ]; then
        IFS= read -r prev_home < "$state_file" || :
        case "$prev_home" in
          # Its own toplevel, not merely a surviving directory: a worktree that
          # lost its `.git` link still sits inside the parent checkout, so git
          # discovery ascends and the kept home would report that checkout's
          # branch as the workspace — no `⧉`, no `✗`, nothing dim. A kept home
          # drops the breadcrumb too: the render writes `.gone` once, so a
          # survivor would later be named as the dir that went away.
          */.claude/worktrees/*)
            prev_top=$(git -C "$prev_home" rev-parse --show-toplevel 2>/dev/null) &&
              prev_top=$(cd "$prev_top" 2>/dev/null && pwd -P) &&
              [ "$prev_top" = "$(cd "$prev_home" 2>/dev/null && pwd -P)" ] && {
                rm -f "$state_file.gone" "$away_file"
                exit 0
              }
            ;;
        esac
      fi
      rm -f "$state_file" "$state_file.gone" "$away_file"
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
# Subagent tool events carry the PARENT session_id, so a worker's stray `cd`
# would retarget the parent's statusline: only its WRITES are heard, and only as
# sustained work (the away run below), never its cds. Dropping them wholesale
# left the statusline behind in orchestrator mode, where every substantive edit
# is made by a subagent.
if [ -n "$agent_flag" ]; then
  case "$tool_name" in
    Edit|Write|NotebookEdit) ;;
    *) exit 0 ;;
  esac
fi

case "$tool_name" in
  ExitWorktree)
    rm -f "$state_file" "$state_file.gone" "$away_file"
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

# A worktree home is sticky: it is a deliberate context, and a cd/edit anywhere
# else — sibling worktree, main checkout, or a different repository entirely
# (test runs, config surgery) — is one-off work that used to retarget the
# statusline (and its ports segment) to another workspace. EnterWorktree moves
# such a home outright; ExitWorktree clears it and SessionStart re-seeds it
# above. Non-worktree homes still follow every cd.
#
# Sticky is not permanent, though: a worktree made by hand (`git worktree add`,
# not the harness tool) will never see an ExitWorktree, so a session that
# finishes there and moves on used to be pinned for its whole life — naming a
# branch and a clean tree that were not the ones being edited. WRITES, and only
# writes, break the pin: three edits in a row into the same other toplevel are
# sustained work, not an excursion. cds never break it, however
# many — reading and running tests elsewhere is exactly the noise stickiness
# exists to absorb.
#
# Subagent writes need the same proof in ANY home, worktree or not: a worker is
# dispatched at a path the parent never visited, so one write there is no
# evidence the session has moved. So does a subshell cd — `(cd /other && make)`
# cannot outlive the command, so the session's own cwd never moved at all.
if [ "$tool_name" != EnterWorktree ] && [ -f "$state_file" ]; then
  IFS= read -r prev_home < "$state_file" || :
  sustained=$agent_flag
  case "$prev_home" in
    */.claude/worktrees/*) sustained=1 ;;
  esac
  if { [ -n "$sustained" ] || [ -n "$bash_subshell" ]; } && [ "$toplevel" != "$prev_home" ]; then
    # Only the pin and the agent regimes are writes-only; the subshell case is a
    # Bash cd by construction and this filter would drop it.
    if [ -n "$sustained" ]; then
      case "$tool_name" in
        Edit|Write|NotebookEdit) ;;
        *) exit 0 ;;
      esac
    fi
    # The run is APPENDED, one line per write, and read back from the tail —
    # never incremented in place. A turn that edits several files issues them
    # as one parallel batch, which is precisely the burst this rule is meant
    # to catch, and those hooks run concurrently: a read-modify-write counter
    # had all three of them read the same value and write 1, so a batch of
    # three never reached the threshold at all and the pin held forever.
    # Single short appends do not interleave.
    mkdir -p "$cache_dir" || exit 0
    umask 077
    printf '%s\n' "$toplevel" >> "$away_file" 2>/dev/null || exit 0
    run=$(tail -n 3 "$away_file" 2>/dev/null | grep -cxF "$toplevel")
    if [ "${run:-0}" -lt 3 ]; then
      # Writes that keep alternating between two foreign repos never reach the
      # threshold, so without this the file grows for the life of the session.
      # Rare by construction, which is what keeps the rewrite off the hot path
      # where it would reintroduce the race it replaced.
      if [ "$(wc -l < "$away_file" 2>/dev/null || printf 0)" -gt 64 ]; then
        tail -n 3 "$away_file" > "$away_file.tmp.$$" 2>/dev/null &&
          mv -f "$away_file.tmp.$$" "$away_file" 2>/dev/null ||
          rm -f "$away_file.tmp.$$" 2>/dev/null
      fi
      exit 0
    fi
  fi
fi

mkdir -p "$cache_dir" || exit 0
umask 077
tmp_file="$state_file.tmp.$$"
trap 'rm -f "$tmp_file" 2>/dev/null; exit 0' EXIT
printf '%s\n' "$toplevel" > "$tmp_file" && mv -f "$tmp_file" "$state_file" &&
  rm -f "$state_file.gone" "$away_file"

marker="$cache_dir/.workdir-prune"
now=$(date +%s 2>/dev/null)
marker_mtime=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || printf '0')
if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$marker_mtime" =~ ^[0-9]+$ ]] && [ "$((now - marker_mtime))" -gt 3600 ]; then
  find "$cache_dir" -type f -name 'workdir-*' -mtime +7 -delete
  touch "$marker"
fi

exit 0
