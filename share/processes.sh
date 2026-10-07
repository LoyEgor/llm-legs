#!/usr/bin/env bash

process_tree() { # pid -> the pid and every descendant, one line each, parents first
  process_listing | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END { queue[n = 1] = root
          for (i = 1; i <= n; i++) { print queue[i]; m = split(kids[queue[i]], k, " "); for (j = 1; j <= m; j++) queue[++n] = k[j] } }'
}

# Stopped twice before the TERM, so a child forked while the first listing ran is caught by the second.
process_tree_end() { # pid grace-seconds -> TERM to the whole tree, KILL to what still lives after the grace
  local pids pass
  kill -STOP "$1" 2>/dev/null || return 0
  for pass in 1 2; do
    pids=$(process_tree "$1")
    kill -STOP $pids 2>/dev/null
  done
  pids_end "$2" $pids
}

# TERM before CONT: continued first, a process stopped by a tty read reads again and stops again
# with the TERM still to come.
pids_end() { # grace-seconds pid... -> TERM and CONT to each, KILL to what still lives after the grace
  local grace=$1 waited=0
  shift
  [ "$#" -gt 0 ] || return 0
  kill -TERM "$@" 2>/dev/null
  kill -CONT "$@" 2>/dev/null
  while [ "$waited" -lt "$grace" ] && kill -0 "$@" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
  kill -KILL "$@" 2>/dev/null
  return 0
}

# One `ps -E` listing. The environment trails the command with no delimiter, so a hit is confirmed
# against the plain command, or a process naming the id only in its arguments would match. macOS
# shows no environment for Apple's own binaries (/bin/sleep, /bin/bash, /usr/bin/python3), so a
# confirmed holder's descendants count too, short of one showing another WORKER_RUN_ID. The caller's
# ancestors and everything under the highest of them carrying the id are its own.
run_env_holders() { # run-id -> "<pid>\t<etime>\t<command>" per other process of the run, by WORKER_RUN_ID=<run-id>
  local listing pids
  listing=$(ps -E -ww -A -o pid=,ppid=,etime=,command= 2>/dev/null) || return 0
  pids=$(awk -v self="$$" -v token=" WORKER_RUN_ID=$1" '
    { parent[$1] = $2; kids[$2] = kids[$2] " " $1
      if (index($0 " ", token " ")) has[$1] = 1; else if (index($0, " WORKER_RUN_ID=")) other[$1] = 1 }
    END {
      top = self
      for (p = self; p > 1 && (p in parent); p = parent[p]) { skip[p] = 1; if (p in has) top = p }
      queue[n = 1] = top; skip[top] = 1
      for (i = 1; i <= n; i++) { m = split(kids[queue[i]], k, " "); for (j = 1; j <= m; j++) { skip[k[j]] = 1; queue[++n] = k[j] } }
      n = 0
      for (p in has) if (!(p in skip)) { queue[++n] = p; seen[p] = 1 }
      for (i = 1; i <= n; i++) { print queue[i]; m = split(kids[queue[i]], k, " ")
        for (j = 1; j <= m; j++) if (!(k[j] in seen) && !(k[j] in skip) && !(k[j] in other)) { seen[k[j]] = 1; queue[++n] = k[j] } }
    }' < <(printf '%s\n' "$listing"))
  [ -n "$pids" ] || return 0
  awk -v token=" WORKER_RUN_ID=$1" '
    FNR == NR { pid = $1; sub(/^ *[0-9]+ /, ""); plain[pid] = $0; next }
    ($1 in plain) {
      kids[$2] = kids[$2] " " $1; etime[$1] = $3; line = $0; sub(/^ *[0-9]+ +[0-9]+ +[-0-9:]+ /, "", line)
      if (index(line, plain[$1]) == 1 && index(substr(line, length(plain[$1]) + 1) " ", token " ")) queue[++n] = $1
    }
    END {
      for (i = 1; i <= n; i++) seen[queue[i]] = 1
      for (i = 1; i <= n; i++) { printf "%s\t%s\t%s\n", queue[i], etime[queue[i]], plain[queue[i]]; m = split(kids[queue[i]], k, " ")
        for (j = 1; j <= m; j++) if (!(k[j] in seen)) { seen[k[j]] = 1; queue[++n] = k[j] } }
    }' <(ps -ww -o pid=,command= -p "$(printf '%s\n' $pids | paste -sd, -)" 2>/dev/null) <(printf '%s\n' "$listing")
}

cwd_listing() { lsof -d cwd -Fpn 2>/dev/null; }
process_listing() { ps -A -o pid=,ppid= 2>/dev/null; }
args_listing() { ps -A -o pid=,args= 2>/dev/null; }

# The caller's own session never holds: everything under the highest of its ancestors standing inside
# the directory, so a chat landing the worktree it works in is not held by its own shell or servers.
# A worker launched with --add-dir <worktree> from a cwd elsewhere edits that worktree too, so it holds it.
cwd_holders() { # dir -> "<pid> <command>" per process whose working directory or --add-dir is dir or below it; 2 when unlisted
  local dir given=${1%/} listing tree args pids
  dir=$(cd -P "$1" 2>/dev/null && pwd -P) || return 0
  listing=$(cwd_listing) tree=$(process_listing) args=$(args_listing)
  [ -n "$listing" ] && [ -n "$tree" ] || return 2
  pids=$(awk -v self="$$" -v dir="$dir" -v given="$given" '
    function within(path) { sub(/\/+$/, "", path); return path == dir || index(path, dir "/") == 1 || path == given || index(path, given "/") == 1 }
    FNR == 1 { file++ }
    file == 1 { parent[$1] = $2; kids[$2] = kids[$2] " " $1; next }
    file == 3 {
      for (i = 2; i <= NF; i++)
        if (($i == "--add-dir" && i < NF && within($(i + 1))) || (index($i, "--add-dir=") == 1 && within(substr($i, 11)))) inside[$1] = 1
      next
    }
    /^p/ { pid = substr($0, 2); next }
    /^n/ { path = substr($0, 2); if (within(path)) inside[pid] = 1 }
    END {
      top = self
      for (p = self; p > 1 && (p in parent); p = parent[p]) if (p in inside) top = p
      queue[n = 1] = top; skip[top] = 1
      for (i = 1; i <= n; i++) { m = split(kids[queue[i]], k, " "); for (j = 1; j <= m; j++) { skip[k[j]] = 1; queue[++n] = k[j] } }
      for (p in inside) if (!(p in skip)) print p
    }' <(printf '%s\n' "$tree") <(printf '%s\n' "$listing") <(printf '%s\n' "${args:- }"))
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
