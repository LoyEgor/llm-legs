# hs_bounded <lock-wait-s> <hs args...>: one Hammerspoon CLI call at a time, killed if it hangs.
hs_bounded() {
  python3 - "$@" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        ["/usr/bin/lockf", "-k", "-t", sys.argv[1], "/tmp/hs-cli.lock", "hs", "-t", "30", *sys.argv[2:]],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=int(sys.argv[1]) + 40,
    )
except (FileNotFoundError, subprocess.TimeoutExpired):
    raise SystemExit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
PY
}
