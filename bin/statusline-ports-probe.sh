#!/usr/bin/env bash
set -u

session_id="${1:-}"
start_pid="${2:-$PPID}"
# The active repository root. A server backgrounded from a tool call outlives the shell that
# started it and is reparented to launchd the moment that call returns, so process ancestry alone
# loses almost every dev server a session ever starts; an orphan is claimed back by its own
# working directory sitting inside the repository the statusline is showing.
project_top="${3:-}"
session_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-')
[ -n "$session_id" ] || exit 0

cache_dir="$HOME/.cache/claude-statusline"
cache_file="$cache_dir/ports-$session_id"
lock="$cache_file.lock"

file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

mkdir -p "$cache_dir" 2>/dev/null || exit 0
# One probe per session at a time; reclaim a stale lock (a killed lsof).
if ! mkdir "$lock" 2>/dev/null; then
  now=$(date +%s 2>/dev/null); m=$(file_mtime "$lock" 2>/dev/null)
  if [[ "${now:-}" =~ ^[0-9]+$ ]] && [[ "${m:-}" =~ ^[0-9]+$ ]] && [ "$((now - m))" -gt 120 ]; then
    rmdir "$lock" 2>/dev/null && mkdir "$lock" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT

PS_CMD="${STATUSLINE_PS:-ps}"
LSOF_CMD="${STATUSLINE_LSOF:-lsof}"

write_cache() {
  # Trailing newline even on empty: a 1-byte file still reads back as "" (probed, no servers).
  local content="$1" tmp="$cache_file.tmp.$$"
  printf '%s\n' "$content" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

snapshot=$("$PS_CMD" -axo pid=,ppid=,command= 2>/dev/null)
if [ -z "$snapshot" ]; then write_cache ""; exit 0; fi

root=$(printf '%s\n' "$snapshot" | awk -v start="$start_pid" '
  { ppid[$1]=$2; line=$0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/,"",line); cmd[$1]=line }
  END {
    pid=start; depth=0
    while (pid != "" && pid+0 > 1 && depth < 30) {
      n=split(cmd[pid], a, /[ \t]/); m=split(a[1], b, "/"); base=b[m]
      if (base == "claude") { print pid; exit }
      pid=ppid[pid]; depth++
    }
  }')
if [ -z "$root" ]; then write_cache ""; exit 0; fi

# Every listener this user owns, in one call: the pid list can no longer be narrowed to the
# session's descendants beforehand, because the servers worth showing are exactly the ones that
# left that set when their shell returned. Ownership is decided below instead.
lsof_out=$("$LSOF_CMD" -a -u "$(id -u)" -iTCP -sTCP:LISTEN -nP 2>/dev/null)

# The working directory of each listening process, for the orphans among them. Asked for all of
# them rather than only for the orphans the ownership walk finds: one more lsof is cheaper than
# threading a second pass through this script. Chunked at 40 pids like the query this replaced,
# because the failure mode of an over-long -p list is a short answer, not an error — every orphan
# would silently lose its directory and vanish from the segment.
cwds=""
cwd_chunk=""; cwd_n=0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  cwd_chunk="${cwd_chunk:+$cwd_chunk,}$pid"; cwd_n=$((cwd_n + 1))
  if [ "$cwd_n" -ge 40 ]; then
    cwds="$cwds
$("$LSOF_CMD" -a -d cwd -Fn -p "$cwd_chunk" 2>/dev/null)"
    cwd_chunk=""; cwd_n=0
  fi
done <<< "$(printf '%s\n' "$lsof_out" | awk '
  $0 == "" || $1 == "COMMAND" { next }
  { for (j=2;j<=NF;j++) if ($j ~ /^[0-9]+$/) { print $j; break } }' | sort -u)"
if [ -n "$cwd_chunk" ]; then
  cwds="$cwds
$("$LSOF_CMD" -a -d cwd -Fn -p "$cwd_chunk" 2>/dev/null)"
fi

# Passed as files, not awk -v: -v rejects the newlines a multi-line lsof dump would carry. Each
# input is prefixed with one throwaway line so that an empty dump still counts as a file — the
# reader tells the three apart by their order, and a silent lsof would otherwise shift them.
ports=$(awk -v root="$root" -v top="$project_top" '
  # Anchored at argv[0] and matched on its last path segment: a bare substring would read
  # "legacy" as agy, and letting the match float would classify a dev server by its own
  # arguments — `node serve.js --dir /tmp/codex` is not codex. The cost of the anchor is a tool
  # whose own path carries a space, which is the same blind spot the claude check above has.
  function tool_cmd(pid) {
    return (cmd[pid] ~ /^([^ \t]*\/)?(agy|opencode|opencode-go|grok|codex)([ \t]|$)/)
  }
  function base_cmd(pid,   n, a, m, b) {
    n = split(cmd[pid], a, /[ \t]/); m = split(a[1], b, "/"); return b[m]
  }
  # Three answers, not two. "mine" is this session, by ancestry. "other" is another live chat, and
  # its servers are its own news. "orphan" is what a backgrounded server becomes, and only the
  # working directory can still place it.
  # A claude on the way up does not end the walk: a claudeb worker IS a claude process, running as
  # a child of the session that spawned it, and a dev server it starts belongs to that session.
  # Only a claude the walk passes without ever reaching root stands for somebody else.
  function owner(pid,   depth, saw_claude) {
    depth = 0; saw_claude = 0
    while (pid != "" && pid + 0 > 1 && depth < 30) {
      if (pid == root) return "mine"
      if (base_cmd(pid) == "claude") saw_claude = 1
      pid = ppid[pid]; depth++
    }
    return saw_claude ? "other" : "orphan"
  }
  # Prefix match on the directory boundary, so a sibling checkout named after this one is not read
  # as being inside it. Both paths come from git and lsof unresolved, so a repository reached
  # through a symlink is a blind spot here, the same one the receipt readers have.
  function within(path) {
    return (path != "" && top != "" && (path == top || index(path, top "/") == 1))
  }
  # The segment answers "where do I go to look at the work", so a port earns a place only if a
  # human can open it. The LLM tools a session drives each listen on localhost for their own RPC
  # and lead nowhere worth going. Their descendants are a different matter: a dev server a worker
  # started IS the work, so below a tool only ephemeral ports (49152+, where no dev server binds
  # and every RPC socket does) are dropped.
  function tool_owned(pid, port,   depth) {
    if (tool_cmd(pid)) return 1
    if (port + 0 < 49152) return 0
    pid = ppid[pid]; depth = 0
    while (pid != "" && pid + 0 > 1 && pid != root && depth < 30) {
      if (tool_cmd(pid)) return 1
      pid = ppid[pid]; depth++
    }
    return 0
  }
  FNR == 1 { file++ }
  file == 1 {
    line=$0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/,"",line); cmd[$1]=tolower(line); ppid[$1]=$2; next
  }
  # lsof -F emits one field per line, tagged by its first character: p<pid> then n<path>. The path
  # keeps its case — it is compared with a repository path, not with a command name.
  file == 2 {
    if (/^p/) cwd_pid=substr($0, 2)
    else if (/^n/ && cwd_pid != "") cwd[cwd_pid]=substr($0, 2)
    next
  }
  {
    # The header is the line whose first field IS the word, not one that merely starts with it: a
    # process named COMMANDER would otherwise have its ports skipped. The pid scan starts past the
    # command name for the mirror of that reason — an all-numeric command name is not a pid.
    if ($0 == "" || $1 == "COMMAND") next
    if (!match($0, /:[0-9]+ \(LISTEN\)/)) next
    port=substr($0, RSTART+1, RLENGTH-1); sub(/ .*/,"",port)
    pid=""
    for (j=2;j<=NF;j++) if ($j ~ /^[0-9]+$/) { pid=$j; break }
    c=cmd[pid]
    if (c ~ /mcp|figma|codex|chrome-devtools|chrome_crashpad/) next
    if (base_cmd(pid) == "claude") next
    if (tool_owned(pid, port)) next
    who=owner(pid)
    if (who == "other") next
    # A directory is weaker evidence than a parent: every language server, debug adapter and editor
    # RPC socket launched from the repository has its cwd there too, and three of those fill the
    # whole segment and push the dev server out of it. So the ephemeral range is dropped here for
    # the same reason it is dropped under a tool — no dev server binds above 49152, every RPC one
    # does — while a port a human could actually type is kept.
    if (who == "orphan" && (!within(cwd[pid]) || port + 0 >= 49152)) next
    if (!(port in seen)) { seen[port]=1; order[++k]=port }
  }
  END {
    out=""
    for (i=1;i<=k;i++) out=(out=="" ? order[i] : out " " order[i])
    print out
  }
' <(printf 'x\n%s\n' "$snapshot") <(printf 'x\n%s\n' "$cwds") \
   <(printf 'x\n%s\n' "$lsof_out"))

write_cache "$ports"

marker="$cache_dir/.ports-prune"
now=$(date +%s 2>/dev/null)
if [[ "${now:-}" =~ ^[0-9]+$ ]]; then
  m=$(file_mtime "$marker" 2>/dev/null || printf '0')
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  if [ "$((now - m))" -gt 3600 ]; then
    find "$cache_dir" -type f \( -name 'ports-*' -o -name 'title-*' -o -name 'cache-ttl-track-*' -o -name 'topic-*' \) -mtime +7 -delete 2>/dev/null
    find "$cache_dir" -type d -name 'topic-*.genlock' -mtime +1 -exec rmdir {} + 2>/dev/null
    touch "$marker" 2>/dev/null
  fi
fi
exit 0
