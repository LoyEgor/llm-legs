#!/usr/bin/env bash
# Exit-code contract of the two Hammerspoon wrappers. No Hammerspoon: a fake `hs` on
# PATH replays what the live module would have printed, and the scripts' own exit codes
# are what is under test — a wrapper that answers 0 for "module not loaded" or for a
# start that never came up sends the reader looking somewhere else entirely.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS="$ROOT/bin/claude-keys"
LATENCY="$ROOT/bin/claude-latency"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

FAKE_BIN="$WORK/bin"
SNIPPET="$WORK/snippet"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/hs" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${2:-}" >"$SNIPPET"
[ -n "${HS_OUT:-}" ] && printf '%s\n' "$HS_OUT"
[ -n "${HS_ERR:-}" ] && printf '%s\n' "$HS_ERR" >&2
exit "${HS_EXIT:-0}"
EOF
chmod +x "$FAKE_BIN/hs"

# Every run answers with one canned line and one canned status, exactly as a single
# `hs -c` does.
OUT=""
STATUS=0
run() {
  local out exit_code hs_out="$1" hs_exit="$2"
  shift 2
  : >"$SNIPPET"
  out=$(PATH="$FAKE_BIN:$PATH" SNIPPET="$SNIPPET" HS_OUT="$hs_out" HS_EXIT="$hs_exit" \
    "$@" 2>/dev/null) && exit_code=0 || exit_code=$?
  OUT="$out"
  STATUS=$exit_code
}

# A subcommand nobody implements is a caller error, not a module state: 2, and no
# round trip to Hammerspoon at all.
run "" 0 "$KEYS" bogus
[ "$STATUS" -eq 2 ] || fail "claude-keys rejected an unknown subcommand with $STATUS, not 2"
[ ! -s "$SNIPPET" ] || fail "claude-keys called hs for an unknown subcommand"
run "" 0 "$LATENCY" bogus
[ "$STATUS" -eq 2 ] || fail "claude-latency rejected an unknown subcommand with $STATUS, not 2"
[ ! -s "$SNIPPET" ] || fail "claude-latency called hs for an unknown subcommand"

# The module is not loaded. The snippet itself ran fine, so `hs -c` exits 0 and only
# what was printed can tell the wrapper otherwise.
for command in off on status; do
  run "!module not loaded" 0 "$KEYS" "$command"
  [ "$STATUS" -ne 0 ] || fail "claude-keys $command reported success with the module unloaded"
  [ "$OUT" = "module not loaded" ] \
    || fail "claude-keys $command printed '$OUT' instead of the plain not-loaded line"
done
for command in report reset; do
  run "!module not loaded" 0 "$LATENCY" "$command"
  [ "$STATUS" -ne 0 ] || fail "claude-latency $command reported success with the module unloaded"
  [ "$OUT" = "module not loaded" ] \
    || fail "claude-latency $command printed '$OUT' instead of the plain not-loaded line"
done

# The default subcommands take the same path as the named ones.
run "!module not loaded" 0 "$KEYS"
[ "$STATUS" -ne 0 ] || fail "bare claude-keys reported success with the module unloaded"
run "!module not loaded" 0 "$LATENCY"
[ "$STATUS" -ne 0 ] || fail "bare claude-latency reported success with the module unloaded"

# The module answered: exit 0, and the line reaches stdout unchanged.
run "ClaudeCmdKeys: stopped (typing bypasses the tap)" 0 "$KEYS" off
[ "$STATUS" -eq 0 ] || fail "a successful claude-keys off exited $STATUS"
[ "$OUT" = "ClaudeCmdKeys: stopped (typing bypasses the tap)" ] \
  || fail "claude-keys off rewrote the module's own line"
run "ClaudeCmdKeys: started" 0 "$KEYS" on
[ "$STATUS" -eq 0 ] || fail "a successful claude-keys on exited $STATUS"
run "running · lastCallback 0.31ms · tty /dev/ttys004" 0 "$KEYS" status
[ "$STATUS" -eq 0 ] || fail "a successful claude-keys status exited $STATUS"
[ "$OUT" = "running · lastCallback 0.31ms · tty /dev/ttys004" ] \
  || fail "claude-keys status rewrote the module's own line"
run "keyDown queue p50 0.4ms proc p50 0.9ms" 0 "$LATENCY" report
[ "$STATUS" -eq 0 ] || fail "a successful claude-latency report exited $STATUS"
[ "$OUT" = "keyDown queue p50 0.4ms proc p50 0.9ms" ] \
  || fail "claude-latency report rewrote the ledger's own line"
run "latency ledger reset" 0 "$LATENCY" reset
[ "$STATUS" -eq 0 ] || fail "a successful claude-latency reset exited $STATUS"

# `on` is pressed to bring the tap back; a start the system refused is exactly what it
# is run to rule out, so the reported state comes from the module, not from the call
# having returned.
run "!ClaudeCmdKeys: start failed (the eventtap is not running)" 0 "$KEYS" on
[ "$STATUS" -ne 0 ] || fail "claude-keys on reported success for a tap that never came up"
[ "$OUT" = "ClaudeCmdKeys: start failed (the eventtap is not running)" ] \
  || fail "claude-keys on hid why the start failed: '$OUT'"
run "ClaudeCmdKeys: started" 0 "$KEYS" on
grep -q 'status()' "$SNIPPET" || fail "claude-keys on never reads the module's status back"
grep -q 's.running' "$SNIPPET" || fail "claude-keys on does not check the running flag"

# Hammerspoon unreachable, and a snippet that threw: the CLI answers nonzero itself
# (measured: 65 for a Lua error), and neither may read as a working toggle.
for script in "$KEYS" "$LATENCY"; do
  run "" 1 "$script"
  [ "$STATUS" -ne 0 ] || fail "$(basename "$script") reported success with Hammerspoon unreachable"
  run "" 65 "$script"
  [ "$STATUS" -ne 0 ] || fail "$(basename "$script") reported success after a Lua error"
done

echo "PASS: claude-keys and claude-latency exit-code contract"
