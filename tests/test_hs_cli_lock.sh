#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# Hammerspoon runs one `hs` client at a time. A client queued behind another suite's harness outlives
# its -t (or a kill bound) and exits, and Hammerspoon then sends the result to the dead client's port
# and dies with SIGTRAP in CFMessagePortSendRequest (crashes 2026-10-02, 10-03, 10-08). So every live
# `hs` call in this repository's tests waits outside Hammerspoon, under one machine-wide lock that the
# hammerspoon repository's tests take too: /usr/bin/lockf -k -t <wait> /tmp/hs-cli.lock hs -t <s> ...
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CALL='(^|\$\(|[[:space:]])(hs|"\$HS_BIN")( +-[A-Za-z]+( +[0-9]+)?)* +-[ct]( |$)|\["hs",|\[sys\.argv\[1\], "-t"'

unlocked() { grep -nE "$CALL" "$@" | grep -v '/tmp/hs-cli\.lock' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'; }

probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
printf '%s\n' 'out=$(hs -q -t 120 -c "return 1")' '  hs -c '"'" \
  '    result = subprocess.run(["hs", "-c", "x"], timeout=20)' > "$probe/bare.sh"
[ "$(unlocked "$probe/bare.sh" | wc -l | tr -d ' ')" = 3 ] || { echo "FAIL: the call pattern misses a bare hs call"; exit 1; }

found=$(unlocked $(ls "$ROOT"/tests/*.sh | grep -v /test_hs_cli_lock.sh))
[ -z "$found" ] || { printf 'FAIL: hs calls outside /tmp/hs-cli.lock:\n%s\n' "$found"; exit 1; }
echo "PASS: every live hs call in tests holds /tmp/hs-cli.lock"
