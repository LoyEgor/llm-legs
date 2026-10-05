#!/usr/bin/env bash

process_tree() { # pid -> the pid and every descendant, one line each, parents first
  ps -A -o pid=,ppid= 2>/dev/null | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END { queue[n = 1] = root
          for (i = 1; i <= n; i++) { print queue[i]; m = split(kids[queue[i]], k, " "); for (j = 1; j <= m; j++) queue[++n] = k[j] } }'
}

# Stopped twice before the TERM, so a child forked while the first listing ran is caught by the second.
process_tree_end() { # pid grace-seconds -> TERM to the whole tree, KILL to what still lives after the grace
  local pids pass waited=0
  kill -STOP "$1" 2>/dev/null || return 0
  for pass in 1 2; do
    pids=$(process_tree "$1")
    kill -STOP $pids 2>/dev/null
  done
  kill -TERM $pids 2>/dev/null
  kill -CONT $pids 2>/dev/null
  while [ "$waited" -lt "$2" ] && kill -0 $pids 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
  kill -KILL $pids 2>/dev/null
  return 0
}

# The caller's own session never holds: everything under the highest of its ancestors standing inside
# the directory, so a chat landing the worktree it works in is not held by its own shell or servers.
cwd_holders() { # dir -> "<pid> <command>" per process whose working directory is dir or below it; 2 when unlisted
  local dir listing tree pids
  dir=$(cd -P "$1" 2>/dev/null && pwd -P) || return 0
  listing=$(lsof -d cwd -Fpn 2>/dev/null)
  tree=$(ps -A -o pid=,ppid= 2>/dev/null)
  [ -n "$listing" ] && [ -n "$tree" ] || return 2
  pids=$(awk -v self="$$" -v dir="$dir" '
    FNR == NR { parent[$1] = $2; kids[$2] = kids[$2] " " $1; next }
    /^p/ { pid = substr($0, 2); next }
    /^n/ { path = substr($0, 2); if (path == dir || index(path, dir "/") == 1) inside[pid] = 1 }
    END {
      top = self
      for (p = self; p > 1 && (p in parent); p = parent[p]) if (p in inside) top = p
      queue[n = 1] = top; skip[top] = 1
      for (i = 1; i <= n; i++) { m = split(kids[queue[i]], k, " "); for (j = 1; j <= m; j++) { skip[k[j]] = 1; queue[++n] = k[j] } }
      for (p in inside) if (!(p in skip)) print p
    }' <(printf '%s\n' "$tree") <(printf '%s\n' "$listing"))
  [ -n "$pids" ] || return 0
  ps -o pid=,command= -p "$(printf '%s\n' $pids | paste -sd, -)" 2>/dev/null | sed -E 's/^ +//' | cut -c1-80
}

cwd_held() { # dir -> status 0 and why when a process stands inside dir or the processes cannot be listed
  local holders rc=0
  holders=$(cwd_holders "$1") || rc=$?
  [ "$rc" = 0 ] || { printf 'the processes inside cannot be listed'; return 0; }
  [ -n "$holders" ] || return 1
  printf 'processes inside: %s' "$(printf '%s\n' "$holders" | awk 'NR > 1 { printf "; " } { printf "%s", $0 }')"
}
