#!/usr/bin/env bash

exec >/dev/null 2>&1

input=$(cat) || exit 0
parsed=$(printf '%s' "$input" | jq -r '
  def value: if . == null then "" else tostring end;
  # `(` is a separator and is barred from unquoted tokens: the cd-guard hook
  # steers persistent `cd` into `(cd /path && cmd)`, where the path token
  # would otherwise swallow the closing paren. That separator is reported
  # because such a cd dies with the command — see the away run below.
  def tok: "\\\"(?:\\\\.|[^\\\"])*\\\"|\\x27[^\\x27]*\\x27|[^[:space:];&|()]+";
  def bash_hit:
    tok as $tok
    | (.tool_input.command // "")
    | [match("(^|[;&|(\\n])[[:space:]]*((cd|pushd)[[:space:]]+(?<cd>" + $tok + ")|git([[:space:]]+-C[[:space:]]+(?<wt_dir>" + $tok + "))?[[:space:]]+worktree[[:space:]]+add(?<wt_args>([ \\t]+(" + $tok + "))+)|git[[:space:]]+-C[[:space:]]+(?<dir>" + $tok + ")([[:space:]]+(?<sub>[A-Za-z][A-Za-z-]*))?)"; "g")]
    | map(
        ([.captures[] | select(.name == "cd" and .string != null) | .string][0] // "") as $cd
        | ([.captures[] | select(.name == "wt_dir" and .string != null) | .string][0] // "") as $wt_dir
        | ([.captures[] | select(.name == "wt_args" and .string != null) | .string][0] // "") as $wt_args
        | ([.captures[] | select(.name == "dir" and .string != null) | .string][0] // "") as $dir
        | ([.captures[] | select(.name == "sub" and .string != null) | .string][0] // "") as $sub
        | (.captures[0].string // "") as $sep
        | if $wt_args != "" then
            ([$wt_args | match($tok; "g").string]
             | reduce .[] as $arg ({path: "", option_arg: false};
                 if .path != "" then .
                 elif .option_arg then .option_arg = false
                 elif (["-b", "-B", "--reason"] | index($arg) != null) then .option_arg = true
                 elif ($arg | startswith("-")) then .
                 else .path = $arg end)
             | {path: .path, sep: "", worktree_add: "1", worktree_base: $wt_dir})
          elif $cd != "" then {path: $cd, sep: $sep, cd_hit: "1", worktree_add: "", worktree_base: ""}
          elif $dir != "" and (["worktree","checkout","switch","commit","merge","rebase","cherry-pick","revert","restore","stash","am","reset","pull"] | index($sub) != null) then {path: $dir, sep: "", worktree_add: "", worktree_base: ""}
          else empty end)
    | . as $hits
    | (last // {path: "", sep: "", worktree_add: "", worktree_base: ""}) as $last
    | if $last.worktree_add == "1" and $last.worktree_base == "" then
        $last + {worktree_base: ([$hits[] | select(.cd_hit == "1") | .path] | last // "")}
      else $last end;
  def read_tools: ["cd","pushd","popd","cat","head","tail","less","ls","wc","grep","rg","find","stat","file","du","df","jq","awk","cut","sort","uniq","tr","basename","dirname","realpath","pwd","echo","printf","test","[","which","type","date","diff","cmp","tree","nl","column","git"];
  def read_git_subs: ["log","show","status","diff","blame","shortlog","describe","rev-parse","rev-list","ls-files","ls-tree","grep","reflog","cat-file"];
  def git_read($t):
    if any($t[]; startswith("--output")) then false
    elif ($t | length) == 0 then false
    else $t[0] as $head
      | if $head == "-C" or $head == "-c" then git_read($t[2:])
        elif ($head | startswith("-")) then git_read($t[1:])
        else (read_git_subs | index($head)) != null
        end
    end;
  def drop_env($t):
    if ($t | length) > 0 and ($t[0] | test("^[A-Za-z_][A-Za-z0-9_]*=")) then drop_env($t[1:]) else $t end;
  def segment_read_only:
    drop_env([splits("[[:space:]]+")] | map(select(. != ""))) as $t
    | if ($t | length) == 0 then true
      else ($t[0] | sub(".*/"; "")) as $cmd
        | if (read_tools | index($cmd)) == null then false
          elif $cmd == "git" then git_read($t[1:])
          elif $cmd == "sort" then all($t[1:][]; test("^-[A-Za-z]*o|^--output") | not)
          elif $cmd == "find" then all($t[1:][]; . as $arg | (["-delete","-exec","-execdir","-ok","-okdir","-fprint","-fprint0","-fprintf","-fls"] | index($arg)) == null)
          else true
          end
      end;
  # Redirects that only discard output are neutralised first, so any surviving `>`
  # condemns the command: that is what catches a write performed BY a reading tool
  # (`awk "{print > \"f\"}"`, `git log > out`) without parsing either language.
  # Splitting on separators over-splits quoted text, which can only call a read
  # "work" — never the reverse. A backtick hides a command the splitter cannot
  # see, so its mere presence is work.
  def command_read_only:
    if test("`") then false
    else
      gsub("[0-9]*>>?[[:space:]]*/dev/null(?=[[:space:];&|()]|$)"; " ")
      | gsub("[0-9]*>&[0-9]+"; " ")
      | if test(">") then false
        else all(splits("[;&|()\\n]+"); segment_read_only)
        end
    end;
  def worktree_path:
    (.tool_response // "")
    | (if type == "string" then . elif type == "object" then ([.. | strings] | join("\n")) else "" end)
    | ([capture("worktree at (?<wt>/[^\\n]+)")] | (.[0].wt // ""))
    | gsub("[[:space:]]+$"; "");
  def dispatch_paths:
    # Every absolute-looking token of the brief, in order: the resolver below
    # takes the first that is a real repository, because a brief names the
    # checkout the worker runs in before anything else. Capped so a brief
    # listing dozens of files does not turn one dispatch into dozens of
    # git calls.
    [(.tool_input.prompt // ""), (.tool_input.description // "")]
    | map(if type == "string" then . else "" end)
    | join("\n")
    | [match("/[A-Za-z0-9._~@+/-]+"; "g") | .string]
    | map(sub("[\"\\x27`,.:)]+$"; ""))
    | map(select(. != "" and . != "/"))
    | .[0:10]
    | join("");
  (if .tool_name == "Bash" then bash_hit else {path: "", sep: "", worktree_add: "", worktree_base: ""} end) as $bash
  | [(.hook_event_name | value), (.tool_name | value), (.session_id | value | gsub("[^A-Za-z0-9_-]"; "")),
   (.cwd | value),
   (if (.agent_id | value) != "" or (.agent_type | value) != "" then "1" else "" end),
   (if .tool_name == "Edit" or .tool_name == "Write" or .tool_name == "Read" then (.tool_input.file_path | value)
    elif .tool_name == "NotebookEdit" then (.tool_input.notebook_path | value)
    elif .tool_name == "Bash" then $bash.path
    elif .tool_name == "EnterWorktree" then worktree_path
    else "" end),
   (.source | value),
   (if $bash.sep == "(" then "1" else "" end),
   (if .tool_name == "Bash" and ((.tool_input.command // "") | command_read_only) then "1" else "" end),
   ($bash.worktree_add // ""),
   ($bash.worktree_base // ""),
   (if .tool_name == "Task" or .tool_name == "Agent" then dispatch_paths else "" end)]
  | join("")
' 2>/dev/null) || exit 0

IFS=$'\x1f' read -r hook_event tool_name session_id base_dir agent_flag candidate start_source bash_subshell bash_read_only bash_worktree_add bash_worktree_base dispatch <<< "$parsed"
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
  # cwd, so its state stays valid and is left alone. resume keeps any live home:
  # the event's cwd is the dir the chat was LAUNCHED in (often the main
  # checkout), not where the work lives — reseeding from it would retarget the
  # strip and ports to the wrong workspace on every resume of a long chat.
  case "$start_source" in
    startup|resume|clear)
      if [ "$start_source" = resume ] && [ -f "$state_file" ]; then
        IFS= read -r prev_home < "$state_file" || :
        # Its own toplevel, not merely a surviving directory: a worktree that
        # lost its `.git` link still sits inside the parent checkout, so git
        # discovery ascends and the kept home would report that checkout's
        # branch as the workspace.
        if [ -n "$prev_home" ]; then
          prev_top=$(git -C "$prev_home" rev-parse --show-toplevel 2>/dev/null) &&
            prev_top=$(cd "$prev_top" 2>/dev/null && pwd -P) &&
            [ "$prev_top" = "$(cd "$prev_home" 2>/dev/null && pwd -P)" ] && {
              rm -f "$away_file"
              exit 0
            }
        fi
      fi
      rm -f "$state_file" "$away_file"
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

case "$tool_name" in
  # A dispatch is heard when the worker is LAUNCHED, and only then: the same
  # brief arrives again at PostToolUse, and counting it twice would let one
  # dispatch fill two thirds of the away run below.
  Task|Agent) [ "$hook_event" = PreToolUse ] || exit 0 ;;
  *) [ "$hook_event" = PostToolUse ] || exit 0 ;;
esac
# Subagent tool events carry the PARENT session_id, so a worker's stray `cd`
# would retarget the parent's statusline: only its WRITES are heard, and only as
# sustained work (the away run below), never its cds, reads or dispatches.
# Dropping them wholesale left the statusline behind in orchestrator mode, where
# every substantive edit is made by a subagent. Its reads are noise of another
# kind: an Explore agent reads across every repo it can reach.
if [ -n "$agent_flag" ]; then
  case "$tool_name" in
    Edit|Write|NotebookEdit) ;;
    *) exit 0 ;;
  esac
fi

case "$tool_name" in
  ExitWorktree)
    rm -f "$state_file" "$away_file"
    exit 0
    ;;
  EnterWorktree|Task|Agent)
    [ -n "$candidate$dispatch" ] || exit 0
    ;;
  Edit|Write|NotebookEdit)
    [ -n "$candidate" ] || exit 0
    candidate=$(dirname -- "$candidate") || exit 0
    ;;
  Read)
    # A read is too weak to establish anything, so with no home yet it is not
    # heard at all: the home comes from SessionStart or from a write.
    [ -n "$candidate" ] && [ -f "$state_file" ] || exit 0
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
    case "$bash_worktree_base" in
      \"*\")
        bash_worktree_base=${bash_worktree_base:1:${#bash_worktree_base}-2}
        bash_worktree_base=${bash_worktree_base//\\\"/\"}
        bash_worktree_base=${bash_worktree_base//\\\\/\\}
        ;;
      \'*\') bash_worktree_base=${bash_worktree_base:1:${#bash_worktree_base}-2} ;;
    esac
    ;;
  *) exit 0 ;;
esac

[ -n "$base_dir" ] || base_dir=.

resolve_dir() {
  local candidate=$1 resolved tmp_root
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
    "$HOME"/.cache|"$HOME"/.cache/*|"$HOME"/.claude*) return 1 ;;
  esac

  if [[ "$candidate" = /* ]]; then
    resolved=$(cd "$candidate" 2>/dev/null && pwd -P) || return 1
  else
    resolved=$(cd "$base_dir" 2>/dev/null && cd "$candidate" 2>/dev/null && pwd -P) || return 1
  fi

  tmp_root=${TMPDIR:-}
  tmp_root=${tmp_root%/}
  case "$resolved" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*|"$HOME"/.cache|"$HOME"/.cache/*|"$HOME"/.claude*) return 1 ;;
  esac
  if [ -n "$tmp_root" ] && { [ "$resolved" = "$tmp_root" ] || [[ "$resolved" == "$tmp_root/"* ]]; }; then
    return 1
  fi
  case "$resolved/" in
    */node_modules/*) return 1 ;;
  esac
  printf '%s\n' "$resolved"
}

resolve_toplevel() {
  local resolved top
  resolved=$(resolve_dir "$1") || return 1
  top=$(git -C "$resolved" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -d "$top" ] || return 1
  (cd "$top" 2>/dev/null && pwd -P)
}

if [ -n "$bash_worktree_base" ] && [[ "$candidate" != /* ]]; then
  base_dir=$(resolve_dir "$bash_worktree_base") || exit 0
fi

case "$tool_name" in
  Task|Agent)
    toplevel=""
    IFS=$'\x1e' read -r -a dispatch_candidates <<< "$dispatch"
    for dispatch_candidate in "${dispatch_candidates[@]}"; do
      [ -n "$dispatch_candidate" ] || continue
      [ -n "$toplevel" ] || toplevel=$(resolve_toplevel "$dispatch_candidate") || toplevel=""
    done
    ;;
  *)
    if [ -n "$bash_worktree_add" ]; then
      # PostToolUse has no reliable success field: requiring the candidate to
      # be its own toplevel rejects both a missing path and an existing subdir.
      resolved_candidate=$(resolve_dir "$candidate") || exit 0
      toplevel=$(resolve_toplevel "$resolved_candidate") || exit 0
      [ "$resolved_candidate" = "$toplevel" ] || exit 0
    else
      toplevel=$(resolve_toplevel "$candidate") || exit 0
    fi
    ;;
esac
[ -n "$toplevel" ] || exit 0

# A worktree home is sticky: it is a deliberate context, and a cd/edit anywhere
# else — sibling worktree, main checkout, or a different repository entirely
# (test runs, config surgery) — is one-off work that used to retarget the
# statusline (and its ports segment) to another workspace. EnterWorktree moves
# such a home outright; ExitWorktree clears it and SessionStart re-seeds it
# above. Non-worktree homes still follow every cd, every write and every worker
# dispatch.
#
# Sticky is not permanent, though: a worktree made by hand (`git worktree add`,
# not the harness tool) will never see an ExitWorktree, so a session that
# finishes there and moves on used to be pinned for its whole life — naming a
# branch and a clean tree that were not the ones being edited. Three WORK events
# in a row into the same other toplevel are sustained work, not an excursion, and
# break the pin. Bash cds never break it, however many — running tests elsewhere
# is exactly the noise stickiness exists to absorb.
#
# The same proof is demanded in ANY home, worktree or not, of the evidence that
# is weak on its own: a subagent write (a worker is dispatched at a path the
# parent never visited, so one write there proves nothing) and a subshell cd
# running work (`(cd /other && make)` cannot outlive the command, so the session
# never moved).
read_grade=
case "$tool_name" in
  Read) read_grade=1 ;;
  # Only a SUBSHELL cd is demoted by its command being read-only: a persistent
  # `cd` is the session itself moving, and `cd` alone is read-only.
  Bash) [ -n "$bash_subshell" ] && [ -n "$bash_read_only" ] && read_grade=1 ;;
esac
# A lookup cannot ESTABLISH a home either: with none yet it comes from
# SessionStart or from a write.
if [ -n "$read_grade" ] && [ ! -f "$state_file" ]; then
  exit 0
fi
if [ "$tool_name" != EnterWorktree ] && [ -z "$bash_worktree_add" ] && [ -f "$state_file" ]; then
  IFS= read -r prev_home < "$state_file" || :
  if [ "$toplevel" = "$prev_home" ]; then
    # Work at home rewrites the home and clears the run. A read is not work, so
    # it does neither — but it does INTERRUPT the run, which is consecutive
    # evidence. Appended, not cleared, for the same concurrency reason as the run
    # itself, and only onto an existing run, so the hottest tool in the harness
    # creates no state; the last-line check keeps a long stay at home from
    # growing the file.
    if [ -n "$read_grade" ]; then
      [ -f "$away_file" ] && [ "$(tail -n 1 "$away_file" 2>/dev/null)" != "$toplevel" ] &&
        printf '%s\n' "$toplevel" >> "$away_file" 2>/dev/null
      exit 0
    fi
  else
    # Before every rule below, the sticky pin included: reading elsewhere leaves
    # no trace to accumulate, so no quantity of it moves anything.
    [ -n "$read_grade" ] && exit 0
    sustained=
    case "$tool_name" in
      Edit|Write|NotebookEdit) [ -n "$agent_flag" ] && sustained=1 ;;
    esac
    case "$prev_home" in
      */.claude/worktrees/*)
        case "$tool_name" in
          Bash) exit 0 ;;
          *) sustained=1 ;;
        esac
        ;;
    esac
    [ -n "$bash_subshell" ] && sustained=1
    if [ -n "$sustained" ]; then
      # The run is APPENDED, one line per event, and read back from the tail —
      # never incremented in place. A turn that edits several files
      # issues them as one parallel batch, which is precisely the burst this
      # rule is meant to catch, and those hooks run concurrently: a
      # read-modify-write counter had all three of them read the same value and
      # write 1, so a batch of three never reached the threshold at all and the
      # pin held forever. Single short appends do not interleave.
      mkdir -p "$cache_dir" || exit 0
      umask 077
      printf '%s\n' "$toplevel" >> "$away_file" 2>/dev/null || exit 0
      run=$(tail -n 3 "$away_file" 2>/dev/null | grep -cxF "$toplevel")
      if [ "${run:-0}" -lt 3 ]; then
        # Events that keep alternating between two foreign repos never reach the
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
fi

mkdir -p "$cache_dir" || exit 0
umask 077
tmp_file="$state_file.tmp.$$"
trap 'rm -f "$tmp_file" 2>/dev/null; exit 0' EXIT
printf '%s\n' "$toplevel" > "$tmp_file" && mv -f "$tmp_file" "$state_file" &&
  rm -f "$away_file"

marker="$cache_dir/.workdir-prune"
now=$(date +%s 2>/dev/null)
marker_mtime=$(stat -f %m "$marker" 2>/dev/null || stat -c %Y "$marker" 2>/dev/null || printf '0')
if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$marker_mtime" =~ ^[0-9]+$ ]] && [ "$((now - marker_mtime))" -gt 3600 ]; then
  # `review-tier-*` is keyed on the path set a chat would commit, so it gains a file every time
  # that set changes — a prune that only knew the per-session names would let it grow forever.
  find "$cache_dir" -type f \
    \( -name 'workdir-*' -o -name 'touched-*' -o -name 'review-tier-*' -o -name 'review-class-*' \) \
    -mtime +7 -delete
  touch "$marker"
fi

exit 0
