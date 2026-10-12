# hs_bounded <lock-wait-s> <hs args...>: one Hammerspoon CLI call at a time, killed if it hangs.
# HS_BOUNDED_IPC_S (default 30) is the hs -t; the kill bound is lock-wait + that + 10. HS_BOUNDED_BIN names the hs binary.
hs_bounded() {
  python3 - "$@" <<'PY'
import os
import subprocess
import sys

ipc = os.environ.get("HS_BOUNDED_IPC_S", "30")
try:
    result = subprocess.run(
        ["/usr/bin/lockf", "-k", "-t", sys.argv[1], "/tmp/hs-cli.lock", os.environ.get("HS_BOUNDED_BIN", "hs"), "-t", ipc, *sys.argv[2:]],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=int(sys.argv[1]) + int(ipc) + 10,
    )
except (FileNotFoundError, subprocess.TimeoutExpired):
    raise SystemExit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
PY
}
