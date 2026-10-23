#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# The Hammerspoon renderer: hammerspoon/llm-limits.lua's source lint and the projection contract in
# tests/llm_limits_renderer_harness.lua. automation_menu.lua comes from the hammerspoon repository
# beside this one (HS_ROOT overrides), never from the owner's deployed ~/.hammerspoon.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/share/test-scope.sh"
. "$ROOT/tests/lib/hs-bounded.sh"
HS_ROOT="${HS_ROOT:-$(git_projects "$ROOT")/hammerspoon}"
[ -r "$HS_ROOT/automation_menu.lua" ] || fail "$HS_ROOT/automation_menu.lua is unreadable (set HS_ROOT)"

# Egor reads ONE gray in this menu: the system's own, the tone macOS already paints the disabled
# percentage rows with. A gray spelled out here is a second one beside them whatever its numbers
# say, so the renderer may hold no gray literal at all and no alpha of its own outside the alarm
# tone — the dim comes from dimColor(), the system colour's name AppKit resolves as it draws. Runs whether
# or not Hammerspoon is available: the evidence is the source text.
gray_hits=$(awk '
  /grayColor/ { printf "line %d: %s\n", NR, $0 }
  /red *=/ && /green *=/ && /blue *=/ {
    r = $0; sub(/.*red *= */, "", r); sub(/[ ,}].*/, "", r)
    g = $0; sub(/.*green *= */, "", g); sub(/[ ,}].*/, "", g)
    b = $0; sub(/.*blue *= */, "", b); sub(/[ ,}].*/, "", b)
    if (r == g && g == b) printf "line %d: %s\n", NR, $0
  }' "$ROOT/hammerspoon/llm-limits.lua")
[ -z "$gray_hits" ] || fail "a gray of our own is a second tone beside the system-dimmed percentage rows — style dim text with dimColor() instead: $gray_hits"

alpha_hits=$(awk '/alpha *=/ && !/dimRedColor/ { printf "line %d: %s\n", NR, $0 }' \
  "$ROOT/hammerspoon/llm-limits.lua")
[ -z "$alpha_hits" ] || fail "only the alarm tone dimRedColor may carry a literal alpha; every other dim is the system colour dimColor() resolves: $alpha_hits"

# One machine-wide lock wait when hs answers; the availability probe runs only after a failed call.
renderer_output='' renderer_rc=1
command -v hs >/dev/null 2>&1 && {
  renderer_output=$(hs_bounded 600 -c "_G.HS_ROOT = [[$HS_ROOT]]; return dofile([[$ROOT/tests/lib/live_log_guard.lua]])(function()
    return dofile([[$ROOT/tests/llm_limits_renderer_harness.lua]]) end)" 2>/dev/null)
  renderer_rc=$?
}
if [ "$renderer_rc" = 0 ] || { command -v hs >/dev/null 2>&1 && [ "$(hs_bounded 600 -c 'return "ok"' 2>/dev/null)" = ok ]; }; then
  [ "$renderer_rc" = 0 ] || fail "Hammerspoon renderer contract checks threw"
  [ "$renderer_output" = "PASS: Hammerspoon projection contract" ] \
    || fail "Hammerspoon renderer contract checks: $renderer_output"
  echo "PASS: renderer source lint (gray, alpha), Hammerspoon projection contract"
else
  echo "SKIP (hs unavailable): Hammerspoon projection contract"
  echo "PASS: renderer source lint (gray, alpha)"
fi
