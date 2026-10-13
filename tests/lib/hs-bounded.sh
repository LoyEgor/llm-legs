# hs_bounded <lock-wait-s> <hs args...>: one Hammerspoon CLI call at a time, killed if it hangs.
# HS_BOUNDED_IPC_S (default 30) is the hs -t; the kill bound is lock-wait + that + 10. HS_BOUNDED_BIN names the hs binary.
# The alarm sits inside lockf: lockf re-arms the process alarm for its own -t, and reports a signal-killed child as 70.
hs_bounded() {
  local ipc=${HS_BOUNDED_IPC_S:-30} rc=0
  /usr/bin/lockf -k -t "$1" /tmp/hs-cli.lock perl -e 'alarm shift; exec @ARGV or exit 127' "$(( ipc + 10 ))" \
    "${HS_BOUNDED_BIN:-hs}" -t "$ipc" "${@:2}" </dev/null || rc=$?
  [ "$rc" -ne 70 ] || rc=124
  return "$rc"
}
