#!/usr/bin/env bash
# Hermetic tests for bin/claude-chat-switch: fixture HOME/profiles/projects, a
# stub `hs` that captures the exact invocation payload, and a stub `ps` so the
# claude-ancestor walk resolves deterministically. Nothing touches the real
# Hammerspoon, profiles, or transcripts.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/claude-chat-switch"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
HS_CAPTURE="$WORK/hs_payload.txt"
export HOME HS_CAPTURE
mkdir -p "$HOME/.claude-profiles/com" "$HOME/.claude-profiles/olx" \
         "$HOME/.claude/projects" "$FAKE_BIN"

# Stub hs: record the raw args (script always calls `hs -c "<lua>"`).
cat >"$FAKE_BIN/hs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HS_CAPTURE"
exit 0
EOF
# Stub ps so find_claude_pid returns immediately: any comm query answers "claude".
cat >"$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *comm=*) echo "claude" ;;
  *ppid=*) echo "1" ;;
esac
EOF
chmod +x "$FAKE_BIN/hs" "$FAKE_BIN/ps"
PATH="$FAKE_BIN:$PATH"
export PATH

# run_switch <extra-env...> -- <args...> : sets stdout/stderr/rc globals and clears
# the hs payload capture first. Env before `--`, script args after.
run_switch() {
  local env_args=() ; while [ "$1" != "--" ]; do env_args+=("$1"); shift; done; shift
  : > "$HS_CAPTURE"
  OUT=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID "${env_args[@]}" \
        "$SCRIPT" "$@" 2>&1); RC=$?
  PAYLOAD=$(cat "$HS_CAPTURE" 2>/dev/null)
}

slug_of() { local r; r=$(cd "$1" && pwd -P); printf '%s' "$r" | sed 's/[^A-Za-z0-9]/-/g'; }

# --- profile validation ---------------------------------------------------
run_switch -- nope
assert test "$RC" -eq 1
assert grep -q "no profile 'nope'" <<<"$OUT"
assert grep -q "existing profiles:" <<<"$OUT"

run_switch -- main abc12345
assert test "$RC" -eq 1
assert grep -qi "not a valid profile name" <<<"$OUT"

run_switch -- status abc12345
assert test "$RC" -eq 1
assert grep -qi "not a valid profile name" <<<"$OUT"

# --- explicit session id wins ---------------------------------------------
run_switch -- olx 11111111-2222-3333-4444-555555555555
assert test "$RC" -eq 0
assert grep -q 'ClaudeChatSwitch.switchChat("olx", "11111111-2222-3333-4444-555555555555", ' <<<"$PAYLOAD"
# third arg is the resolved claude pid — a bare integer, closing the call
assert grep -Eq ', [0-9]+\)$' <<<"$PAYLOAD"
assert grep -q 'armed' <<<"$OUT"
assert grep -q 'claudeb profile olx --resume 11111111-2222-3333-4444-555555555555' <<<"$OUT"

# --- $CLAUDE_CODE_SESSION_ID fallback -------------------------------------
run_switch CLAUDE_CODE_SESSION_ID=env-sid-0001 -- com
assert test "$RC" -eq 0
assert grep -q 'ClaudeChatSwitch.switchChat("com", "env-sid-0001", ' <<<"$PAYLOAD"

# --- newest-transcript fallback (no env, no arg) --------------------------
SCRATCH="$WORK/proj"; mkdir -p "$SCRATCH"
SLUG=$(slug_of "$SCRATCH")
PROJ="$HOME/.claude/projects/$SLUG"; mkdir -p "$PROJ"
touch -t 202601010900 "$PROJ/old-session-aaaa.jsonl"
touch -t 202601010905 "$PROJ/new-session-bbbb.jsonl"
( cd "$SCRATCH" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    HS_CAPTURE="$WORK/hs2.txt" "$SCRIPT" olx >/dev/null 2>&1 )
assert grep -q '"new-session-bbbb"' "$WORK/hs2.txt"

# --- missing session id -> error ------------------------------------------
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
( cd "$EMPTY" && OUT=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    "$SCRIPT" olx 2>&1); rc=$?
  [ "$rc" -eq 1 ] || { echo "expected rc1 got $rc"; exit 3; }
  grep -q "could not determine a session id" <<<"$OUT" || { echo "missing msg: $OUT"; exit 3; } )
assert test $? -eq 0

# --- bad chars in explicit session id -> error ----------------------------
run_switch -- olx 'bad/../id'
assert test "$RC" -eq 1
assert grep -qi "unexpected characters" <<<"$OUT"

# --- hs missing on PATH -> error ------------------------------------------
NOHS="$WORK/nohs"; mkdir -p "$NOHS"
cp "$FAKE_BIN/ps" "$NOHS/ps"; chmod +x "$NOHS/ps"
OUT=$(env -u CLAUDE_CODE_SESSION_ID PATH="$NOHS:/usr/bin:/bin" \
      "$SCRIPT" olx sid-1234 2>&1); RC=$?
assert test "$RC" -eq 1
assert grep -qi "Hammerspoon CLI" <<<"$OUT"

echo "PASS: claude-chat-switch ($asserts assertions)"
