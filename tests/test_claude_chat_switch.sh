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

# Stub hs: record the raw args (script always calls `hs -c "<lua>"`) and answer the
# way a real arm does — a module console line first, the sentinel last.
cat >"$FAKE_BIN/hs" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HS_CAPTURE"
printf '[claude-chat-switch]\tarmed\tprofile=x\narmed\n'
exit 0
EOF
# Stub ps so find_claude_pid returns immediately: any comm query answers "claude".
# The tty query is --self's, and it lands on the resolved claude pid — the only point
# where the fixture learns that pid, so the sessions-registry entry a live chat would
# have is written there, with the procStart lstart= reports back.
STUB_LSTART="Sat Aug  1 11:11:04 2026"
export STUB_LSTART
cat >"$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do pid=$arg; done
case "$*" in
  *comm=*) echo "claude" ;;
  *ppid=*) echo "1" ;;
  *tty=*)
    if [ -z "${STUB_NO_REGISTRY:-}" ]; then
      reg="$HOME/.claude/sessions/$pid.json"
      mkdir -p "${reg%/*}"
      printf '{"pid":%s,"sessionId":"stub-session-0001","cwd":"/tmp","procStart":"%s","status":"idle"}\n' \
        "$pid" "$STUB_LSTART" > "$reg"
    fi
    echo "ttys009"
    ;;
  *lstart=*) echo "$STUB_LSTART" ;;
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
# third arg is the resolved claude pid — a bare integer; passive mode has no tty
assert grep -Eq ', [0-9]+, nil, \{cwd="' <<<"$PAYLOAD"
# the arm is confirmed by the returned sentinel, not by scanning the console output
assert grep -q "and 'armed' or 'refused'" <<<"$PAYLOAD"
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

# --- --self: own tab, own tty, cwd + registry opts -------------------------
# The tab handover path: the target session lives in another project, so the resume
# has to carry its cwd or claude would look for the transcript under the wrong slug.
FOREIGN="$WORK/foreign"; mkdir -p "$FOREIGN"
# the script normalizes --cwd through `pwd -P`, and $TMPDIR is a /var symlink
FOREIGN_REAL=$(cd "$FOREIGN" && pwd -P)
FSLUG=$(slug_of "$FOREIGN")
mkdir -p "$HOME/.claude/projects/$FSLUG"
FSID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
touch "$HOME/.claude/projects/$FSLUG/$FSID.jsonl"

run_switch -- --self --cwd "$FOREIGN" olx "$FSID"
assert test "$RC" -eq 0
assert grep -q "ClaudeChatSwitch.switchChat(\"olx\", \"$FSID\", " <<<"$PAYLOAD"
assert grep -q '"/dev/ttys009", {cwd="' <<<"$PAYLOAD"
assert grep -q "cwd=\"$FOREIGN_REAL\", registry=\"$HOME/.claude/sessions/" <<<"$PAYLOAD"
assert grep -q "cd '$FOREIGN_REAL' && claudeb profile olx --resume $FSID" <<<"$OUT"

# --- passive mode carries --cwd too ----------------------------------------
# He exits the chat himself, so nothing is typed until then — but the resume still
# has to land in the target's project or claude cannot find that transcript.
run_switch -- --cwd "$FOREIGN" olx "$FSID"
assert test "$RC" -eq 0
assert grep -q "cwd=\"$FOREIGN_REAL\"" <<<"$PAYLOAD"
assert grep -q "cd '$FOREIGN_REAL' && claudeb profile olx --resume $FSID" <<<"$OUT"

# --- --cwd picks the newest chat of the TARGET project ---------------------
touch -t 202601010900 "$HOME/.claude/projects/$FSLUG/older-one.jsonl"
touch -t 202601010905 "$HOME/.claude/projects/$FSLUG/$FSID.jsonl"
run_switch -- --cwd "$FOREIGN" olx
assert test "$RC" -eq 0
assert grep -q "\"$FSID\"" <<<"$PAYLOAD"

# --- --cwd without the target's transcript -> error ------------------------
run_switch -- --self --cwd "$WORK" olx "$FSID"
assert test "$RC" -eq 1
assert grep -q "no transcript under" <<<"$OUT"
assert test -z "$PAYLOAD"

# --- flag validation -------------------------------------------------------
run_switch -- --front --self olx "$FSID"
assert test "$RC" -eq 1
assert grep -q "mutually exclusive" <<<"$OUT"

run_switch -- --bogus olx "$FSID"
assert test "$RC" -eq 2
assert grep -q "usage: claude-chat-switch" <<<"$OUT"

run_switch -- --cwd
assert test "$RC" -eq 2

# --- --self refuses without a live registry --------------------------------
# It exits the chat that armed it, usually mid-turn: no registry, no idle signal.
run_switch STUB_NO_REGISTRY=1 -- --self --cwd "$FOREIGN" olx "$FSID"
assert test "$RC" -eq 1
assert grep -q "no live sessions-registry entry" <<<"$OUT"
assert test -z "$PAYLOAD"

# --- a path the error sentinel used to trip over ---------------------------
# The armed console line echoes the cwd back, so "error" in a directory name must
# not read as a failed arm.
TRAP="$WORK/error not found"; mkdir -p "$TRAP"
TRAP_REAL=$(cd "$TRAP" && pwd -P)
TSLUG=$(slug_of "$TRAP"); mkdir -p "$HOME/.claude/projects/$TSLUG"
touch "$HOME/.claude/projects/$TSLUG/$FSID.jsonl"
run_switch -- --cwd "$TRAP" olx "$FSID"
assert test "$RC" -eq 0
assert grep -q "cwd=\"$TRAP_REAL\"" <<<"$PAYLOAD"

# --- hs missing on PATH -> error ------------------------------------------
NOHS="$WORK/nohs"; mkdir -p "$NOHS"
cp "$FAKE_BIN/ps" "$NOHS/ps"; chmod +x "$NOHS/ps"
OUT=$(env -u CLAUDE_CODE_SESSION_ID PATH="$NOHS:/usr/bin:/bin" \
      "$SCRIPT" olx sid-1234 2>&1); RC=$?
assert test "$RC" -eq 1
assert grep -qi "Hammerspoon CLI" <<<"$OUT"

echo "PASS: claude-chat-switch ($asserts assertions)"
