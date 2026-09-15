#!/usr/bin/env bash
# `grokb export-token` for a confined run: what leaves the machine, and what the command does when
# the saved access token is shorter than the run that asked for it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/grokb"
FAKE_GROK="$ROOT/tests/fixtures/fake-grok.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }

export HOME="$WORK/home"
export GROKB_PROFILES_DIR="$WORK/profiles"
export GROKB_GROK_BIN="$FAKE_GROK"
export GROK_CALLS="$WORK/grok-calls"
export WORKER_PICK_CONFIG_FILE="$WORK/worker-toggle"
export GROKB_QUOTA_CMD="$ROOT/tests/fixtures/fake-grok-quota.sh"
export LLM_LIMITS_GROK_CACHE="$WORK/llm-limits-grok.json"
export ANNOUNCE_LOG="$WORK/announce-log"
export LLM_LIMITS_ANNOUNCE_CMD="$WORK/fake-announce"
printf '#!/usr/bin/env bash\nexit 0\n' >"$LLM_LIMITS_ANNOUNCE_CMD"
chmod +x "$LLM_LIMITS_ANNOUNCE_CMD"
mkdir -p "$HOME/.grok" "$GROKB_PROFILES_DIR/alpha"
: >"$GROK_CALLS"
unset GROK_WORKER GROK_HOME GROK_CLAUDE_MCPS_ENABLED GROK_CLAUDE_SKILLS_ENABLED GROK_DISABLE_AUTOUPDATER
unset FAKE_GROK_ROTATE_EXPIRES

iso_at() { # seconds from now
  local epoch=$(( $(date +%s) + $1 ))
  date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

write_session() { # expires_at
  printf '%s\n' "{\"issuer::client\":{\"email\":\"alpha@example.com\",\"expires_at\":\"$1\",\"key\":\"saved-key-sentinel\",\"refresh_token\":\"saved-refresh-sentinel\"}}" \
    >"$GROKB_PROFILES_DIR/alpha/auth.json"
}

live_field() { jq -r --arg field "$1" '.["issuer::client"][$field]' "$GROKB_PROFILES_DIR/alpha/auth.json"; }
exported_key() { jq -r '.["issuer::client"].key' "$1"; }
calls() { grep -c '^CALL ' "$GROK_CALLS"; }

export_token() { # target min-seconds
  : >"$GROK_CALLS"
  export_rc=0
  export_out=$(bash "$SCRIPT" export-token alpha --to "$1" --min-seconds "$2" 2>"$WORK/export.err") \
    || export_rc=$?
  export_err=$(cat "$WORK/export.err")
}

# --- a token that outlasts the run leaves as it is, and the CLI is never woken ------------------
long_expiry=$(iso_at 7200)
write_session "$long_expiry"
export_token "$WORK/long.json" 1717
assert test "$export_rc" -eq 0
assert test "$export_out" = "source=auth.json expires_at=$long_expiry"
assert test "$(calls)" -eq 0
assert test "$(exported_key "$WORK/long.json")" = saved-key-sentinel
assert_fails grep -q refresh "$WORK/long.json"
assert test "$(stat -f '%Lp' "$WORK/long.json" 2>/dev/null || stat -c '%a' "$WORK/long.json")" = 600

# --- short of the run: rotate the live session through the CLI, then export the fresh token -----
# review-bench asks for a cell's whole wall, so the last half hour of every token's life used to
# refuse a read-only export the account's own refresh token could have served.
write_session "$(iso_at 600)"
rotated_expiry=$(iso_at 7200)
FAKE_GROK_ROTATE_EXPIRES="$rotated_expiry" export_token "$WORK/rotated.json" 1717
assert test "$export_rc" -eq 0
assert test "$export_out" = "source=auth.json expires_at=$rotated_expiry"
assert grep -q 'touching the CLI to rotate it' <<<"$export_err"
# The heartbeat's touch, not a headless run: one authenticated subcommand, no worker mark.
assert test "$(calls)" -eq 1
assert grep -qx "CALL home=$GROKB_PROFILES_DIR/alpha mcps=0 skills=0 updater=1 worker=<unset> argc=1" "$GROK_CALLS"
assert grep -qx 'ARG=models' "$GROK_CALLS"
# The rotation is the CLI's own write to the live profile: the export reads it, never replaces it.
assert test "$(live_field expires_at)" = "$rotated_expiry"
assert test "$(live_field key)" = rotated-key-sentinel
assert test "$(live_field refresh_token)" = rotated-refresh-sentinel
assert test "$(exported_key "$WORK/rotated.json")" = rotated-key-sentinel
# What a confined runtime must never hold: any renewal credential, fresh or stale.
assert_fails grep -q refresh "$WORK/rotated.json"

# --- the rotation that changes nothing: one attempt, then a refusal naming the seconds left -----
write_session "$(iso_at 600)"
export_token "$WORK/refused.json" 1717
assert test "$export_rc" -eq 4
assert test "$(calls)" -eq 1
assert grep -qE "\((59[0-9]|600) seconds left after a refresh, 1717 needed\)" <<<"$export_err"
assert test ! -e "$WORK/refused.json"
assert test "$(live_field key)" = saved-key-sentinel

# --- a rotation that buys time, but not enough: still a refusal, still one attempt --------------
write_session "$(iso_at 600)"
FAKE_GROK_ROTATE_EXPIRES="$(iso_at 900)" export_token "$WORK/short.json" 1717
assert test "$export_rc" -eq 4
assert test "$(calls)" -eq 1
assert grep -qE "\((89[0-9]|900) seconds left after a refresh, 1717 needed\)" <<<"$export_err"
assert test ! -e "$WORK/short.json"

# --- an unreadable expiry is still too little of it; a logged-out profile wakes nothing ---------
write_session 'not-a-timestamp'
FAKE_GROK_ROTATE_EXPIRES="$(iso_at 7200)" export_token "$WORK/unreadable.json" 0
assert test "$export_rc" -eq 0
assert test "$(calls)" -eq 1
assert test "$(exported_key "$WORK/unreadable.json")" = rotated-key-sentinel
printf '%s\n' '{"issuer::client":{"email":"alpha@example.com"}}' >"$GROKB_PROFILES_DIR/alpha/auth.json"
export_token "$WORK/logged-out.json" 1717
assert test "$export_rc" -eq 3
assert test "$(calls)" -eq 0
assert grep -q 'is not signed in' <<<"$export_err"

# --- a numeric epoch is the other expiry shape llm-limits.sh reads, and a live session -----------
printf '%s\n' "{\"issuer::client\":{\"email\":\"alpha@example.com\",\"expires_at\":$(( $(date +%s) + 7200 )),\"key\":\"saved-key-sentinel\",\"refresh_token\":\"saved-refresh-sentinel\"}}" \
  >"$GROKB_PROFILES_DIR/alpha/auth.json"
epoch_expiry=$(live_field expires_at)
FAKE_GROK_ROTATE_EXPIRES="$(iso_at 7200)" export_token "$WORK/epoch.json" 1717
assert test "$export_rc" -eq 0
assert test "$(calls)" -eq 0
assert test "$export_out" = "source=auth.json expires_at=$epoch_expiry"
assert test "$(exported_key "$WORK/epoch.json")" = saved-key-sentinel

# --- a CLI that never returns is bounded, and the refusal says so rather than blaming the token ---
SLEEPER="$WORK/sleeping-grok"
printf '#!/usr/bin/env bash\nsleep 120\n' >"$SLEEPER"
chmod +x "$SLEEPER"
write_session "$(iso_at 600)"
started=$(date +%s)
: >"$GROK_CALLS"
hang_rc=0
hang_err=$(GROKB_GROK_BIN="$SLEEPER" LLM_LIMITS_GROK_TOUCH_TIMEOUT=2 \
  bash "$SCRIPT" export-token alpha --to "$WORK/hung.json" --min-seconds 1717 2>&1 >/dev/null) || hang_rc=$?
assert test "$hang_rc" -eq 4
assert test "$(( $(date +%s) - started ))" -lt 30
assert grep -q 'could not be rotated: the token touch timed out after 2s' <<<"$hang_err"
assert test ! -e "$WORK/hung.json"

# --- no CLI to rotate with is not "the token is too short": the refusal names the missing binary --
if [ -x /opt/homebrew/bin/grok ]; then
  printf 'skip: /opt/homebrew/bin/grok exists, the not-found case cannot be posed here\n' >&2
else
  mkdir -p "$WORK/bare-bin" "$WORK/empty-home"
  ln -sf "$(command -v jq)" "$WORK/bare-bin/jq"
  write_session "$(iso_at 600)"
  missing_rc=0
  missing_err=$( (unset GROKB_GROK_BIN
    env HOME="$WORK/empty-home" PATH="$WORK/bare-bin:/usr/bin:/bin" \
      bash "$SCRIPT" export-token alpha --to "$WORK/no-cli.json" --min-seconds 1717) 2>&1 >/dev/null) \
    || missing_rc=$?
  assert test "$missing_rc" -eq 4
  assert grep -q 'could not be rotated: grok CLI not found' <<<"$missing_err"
  assert_fails grep -q 'seconds left' <<<"$missing_err"
  assert test ! -e "$WORK/no-cli.json"
fi

write_session "$long_expiry"
assert_fails bash "$SCRIPT" export-token missing --to "$WORK/unknown.json" >/dev/null 2>&1
assert_fails bash "$SCRIPT" export-token alpha --to "$WORK/long.json" >/dev/null 2>&1
assert test "$(exported_key "$WORK/long.json")" = saved-key-sentinel

printf 'PASS: %s asserts; grokb export-token covers a token that outlasts the run, the CLI rotation that saves a short one, both refusals with the seconds named, renewal credentials never leaving, and the live profile keeping its own\n' "$asserts"
