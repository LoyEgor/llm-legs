# One ssh connection for a whole run against a node: a ControlMaster every later call of the run multiplexes over.
# sshd's MaxStartups drops fresh connections in a burst ("Connection timed out during banner exchange": mac-m1,
# 10:30:100, twice on 2026-11-14), so a run that opened one per step could trip it on its own.
#
# Sourced (bin/claude-relogin):
#   ssh_mux_open <ssh argv...> <host>   a private 0700 dir under /tmp, the master opened in it (a banner timeout is
#                                       retried once); sets SSH_MUX_DIR and SSH_MUX_OPTS, the options every later
#                                       call adds. 0, or ssh's code with its stderr in SSH_MUX_ERR.
#   ssh_mux_close <ssh argv...> <host>  the master ended (its sessions and forwards with it), the dir removed.
# Run (bin/node-install):  ssh-mux.sh open <ssh argv...> <host>   prints the dir, then one option per line
#                          ssh-mux.sh close <dir> <ssh argv...> <host>
# A call made while no master answers (it idled out after SSH_MUX_PERSIST_S, or the node dropped it) connects by
# itself and becomes the next master, so the options never make a call fail; a run killed before its close leaves a
# master that ends itself once idle that long.

SSH_MUX_PERSIST_S=${SSH_MUX_PERSIST_S:-300}

ssh_mux_open() {
  local n=$# try rc
  SSH_MUX_ERR=''
  SSH_MUX_DIR=$(mktemp -d /tmp/ssh-mux.XXXXXX) || { SSH_MUX_ERR='mktemp -d /tmp/ssh-mux.XXXXXX failed'; return 1; }
  SSH_MUX_OPTS=(-o ControlMaster=auto -o "ControlPath=$SSH_MUX_DIR/m" -o "ControlPersist=$SSH_MUX_PERSIST_S")
  for try in 1 2; do
    # The master stays in the background holding whatever it was given: no pipe of the caller's, or a reader waits
    # for its EOF until it ends.
    rc=0
    "${@:1:n-1}" "${SSH_MUX_OPTS[@]}" -N -f "${@:n}" </dev/null >/dev/null 2>"$SSH_MUX_DIR/err" || rc=$?
    [ "$rc" -ne 0 ] || { rm -f "$SSH_MUX_DIR/err"; return 0; }
    grep -q 'banner exchange' "$SSH_MUX_DIR/err" 2>/dev/null || break
  done
  SSH_MUX_ERR=$(cat "$SSH_MUX_DIR/err" 2>/dev/null)
  rm -f "$SSH_MUX_DIR/err"
  rmdir "$SSH_MUX_DIR" 2>/dev/null
  SSH_MUX_DIR='' SSH_MUX_OPTS=()
  return "$rc"
}

ssh_mux_close() {
  local n=$#
  [ -n "${SSH_MUX_DIR:-}" ] || return 0
  "${@:1:n-1}" -o "ControlPath=$SSH_MUX_DIR/m" -O exit "${@:n}" </dev/null >/dev/null 2>&1
  rm -f "$SSH_MUX_DIR/m"
  rmdir "$SSH_MUX_DIR" 2>/dev/null
  SSH_MUX_DIR='' SSH_MUX_OPTS=()
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    open) shift; ssh_mux_open "$@" || { rc=$?; printf '%s\n' "$SSH_MUX_ERR" >&2; exit "$rc"; }; printf '%s\n' "$SSH_MUX_DIR" "${SSH_MUX_OPTS[@]}" ;;
    close) shift; SSH_MUX_DIR=$1; shift; ssh_mux_close "$@" ;;
    *) printf 'usage: ssh-mux.sh open <ssh argv...> <host> | close <dir> <ssh argv...> <host>\n' >&2; exit 2 ;;
  esac
fi
