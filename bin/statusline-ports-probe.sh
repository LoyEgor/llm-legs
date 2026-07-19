#!/usr/bin/env bash
set -u

session_id="${1:-}"
start_pid="${2:-$PPID}"
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
  { ppid[$1]=$2; line=$0; sub(/^[0-9]+[ \t]+[0-9]+[ \t]+/,"",line); cmd[$1]=line }
  END {
    pid=start; depth=0
    while (pid != "" && pid+0 > 1 && depth < 30) {
      n=split(cmd[pid], a, /[ \t]/); m=split(a[1], b, "/"); base=b[m]
      if (base == "claude") { print pid; exit }
      pid=ppid[pid]; depth++
    }
  }')
if [ -z "$root" ]; then write_cache ""; exit 0; fi

descendants=$(printf '%s\n' "$snapshot" | awk -v root="$root" '
  { ppid[$1]=$2; pids[NR]=$1 }
  END {
    desc[root]=1; changed=1
    while (changed) {
      changed=0
      for (i=1;i<=NR;i++) { p=pids[i]; if (!(p in desc) && (ppid[p] in desc)) { desc[p]=1; changed=1 } }
    }
    for (i=1;i<=NR;i++) { p=pids[i]; if ((p in desc) && p != root) print p }
  }')
if [ -z "$descendants" ]; then write_cache ""; exit 0; fi

# lsof caps its argv; chunk the pid list.
lsof_out=""
chunk=""; n=0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  chunk="${chunk:+$chunk,}$pid"; n=$((n + 1))
  if [ "$n" -ge 40 ]; then
    lsof_out="$lsof_out
$("$LSOF_CMD" -a -iTCP -sTCP:LISTEN -nP -p "$chunk" 2>/dev/null)"
    chunk=""; n=0
  fi
done <<< "$descendants"
if [ -n "$chunk" ]; then
  lsof_out="$lsof_out
$("$LSOF_CMD" -a -iTCP -sTCP:LISTEN -nP -p "$chunk" 2>/dev/null)"
fi

# Passed as files, not awk -v: -v rejects the newlines a multi-line lsof dump would carry.
ports=$(awk '
  FNR==NR { line=$0; sub(/^[0-9]+[ \t]+[0-9]+[ \t]+/,"",line); cmd[$1]=tolower(line); next }
  {
    if ($0 == "" || $0 ~ /^COMMAND/) next
    if (!match($0, /:[0-9]+ \(LISTEN\)/)) next
    port=substr($0, RSTART+1, RLENGTH-1); sub(/ .*/,"",port)
    pid=""
    for (j=1;j<=NF;j++) if ($j ~ /^[0-9]+$/) { pid=$j; break }
    c=cmd[pid]
    if (c ~ /mcp|figma|codex|chrome-devtools|chrome_crashpad/) next
    m=split(c, t, /[ \t]/); q=split(t[1], u, "/"); base=u[q]
    if (base == "claude") next
    if (!(port in seen)) { seen[port]=1; order[++k]=port }
  }
  END {
    out=""
    for (i=1;i<=k;i++) out=(out=="" ? order[i] : out " " order[i])
    print out
  }
' <(printf '%s\n' "$snapshot") <(printf '%s\n' "$lsof_out"))

write_cache "$ports"

marker="$cache_dir/.ports-prune"
now=$(date +%s 2>/dev/null)
if [[ "${now:-}" =~ ^[0-9]+$ ]]; then
  m=$(file_mtime "$marker" 2>/dev/null || printf '0')
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  if [ "$((now - m))" -gt 3600 ]; then
    find "$cache_dir" -type f -name 'ports-*' -mtime +7 -delete 2>/dev/null
    touch "$marker" 2>/dev/null
  fi
fi
exit 0
