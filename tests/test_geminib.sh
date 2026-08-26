#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/geminib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then
    fail "assert $asserts unexpectedly succeeded: $*"
  else
    status=$?
    [ "$status" -ne 127 ] || fail "assert $asserts command not found: $*"
  fi
}

HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
AGY_CALLS="$WORK/agy-calls"
export HOME AGY_CALLS
mkdir -p "$HOME/.gemini/antigravity-cli" "$HOME/.gemini/config" "$HOME/.gemini/extensions" "$FAKE_BIN" \
  "$HOME/Library/Keychains" "$HOME/Library/Caches/ms-playwright-go" "$HOME/Library/Caches/ms-playwright"
printf 'instructions\n' >"$HOME/.gemini/GEMINI.md"
printf '{}\n' >"$HOME/.gemini/settings.json"
printf '{}\n' >"$HOME/.gemini/antigravity-cli/settings.json"
printf 'config\n' >"$HOME/.gemini/config/value"
BASE_MCP="$HOME/.gemini/config/mcp_config.json"
cat >"$BASE_MCP" <<'EOF'
{
  "mcpServers": {
    "figma-dev-mode-mcp-server": {
      "command": "npx",
      "args": ["mcp-remote", "http://127.0.0.1:3845/sse"]
    },
    "already-off": {
      "command": "noop",
      "disabled": true
    }
  }
}
EOF
BASE_MCP_SUM="$(shasum "$BASE_MCP" | cut -d' ' -f1)"
printf 'extension\n' >"$HOME/.gemini/extensions/value"

cat >"$FAKE_BIN/agy" <<'EOF'
#!/usr/bin/env bash
{
  printf 'CALL home=%s argc=%s\n' "$HOME" "$#"
  for argument in "$@"; do printf 'ARG=%q\n' "$argument"; done
} >>"$AGY_CALLS"
EOF
chmod +x "$FAKE_BIN/agy"

SECURITY_CALLS="$WORK/security-calls"
GEMINIB_SECURITY_CMD="$FAKE_BIN/security"
export SECURITY_CALLS GEMINIB_SECURITY_CMD
# Writes the password it was given into the keychain file, so a test can prove the stored password
# belongs to the keychain that survived a race, and refuses an unlock that presents another one —
# the difference the real security draws between a keychain geminib can open and one it must
# replace. HOME is logged because pinning it on every call is what keeps profile keychains out of
# the session's own search list.
cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
printf 'CALL home=%s %s\n' "$HOME" "$*" >>"$SECURITY_CALLS"
case "${1:-}" in
  create-keychain) printf '%s' "$3" >"$4" ;;
  unlock-keychain) [ "$(cat "$4" 2>/dev/null)" = "$3" ] || exit 51 ;;
esac
EOF
chmod +x "$FAKE_BIN/security"
AGY_BIN="$FAKE_BIN/agy"
export AGY_BIN

ANNOUNCE_LOG="$WORK/announce-log"
LLM_LIMITS_ANNOUNCE_CMD="$WORK/fake-announce"
export ANNOUNCE_LOG LLM_LIMITS_ANNOUNCE_CMD
cat >"$LLM_LIMITS_ANNOUNCE_CMD" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ANNOUNCE_LOG"
EOF
chmod +x "$LLM_LIMITS_ANNOUNCE_CMD"
# The announce hook is detached; give it a beat before reading the log.
wait_announce() {
  local expected="$1" tries=0
  while [ "$tries" -lt 50 ]; do
    grep -qxF -- "$expected" "$ANNOUNCE_LOG" 2>/dev/null && return 0
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}

cat >"$WORK/fake-quota" <<'EOF'
#!/usr/bin/env bash
account=main
case "$HOME" in */.gemini-profiles/*) account=$(basename "$HOME") ;; esac
if [ -n "${GEMINI_PROBE_LOG:-}" ]; then
  printf 'START %s\n' "$account" >>"$GEMINI_PROBE_LOG"
  sleep 1
  printf 'END %s\n' "$account" >>"$GEMINI_PROBE_LOG"
fi
if [ "$(cat "${GEMINI_AUTH_DIR:?}/$account" 2>/dev/null)" != ok ]; then
  printf '{"auth_needed":true,"detail":"login screen"}\n'
  exit 2
fi
cat "${GEMINI_QUOTA_DIR:?}/$account.json"
EOF
chmod +x "$WORK/fake-quota"
GEMINIB_QUOTA_CMD="$WORK/fake-quota"
GEMINI_AUTH_DIR="$WORK/auth"
GEMINI_QUOTA_DIR="$WORK/quota"
export GEMINIB_QUOTA_CMD GEMINI_AUTH_DIR GEMINI_QUOTA_DIR
mkdir -p "$GEMINI_AUTH_DIR" "$GEMINI_QUOTA_DIR"

future='2026-07-25T12:00:00Z'
week='2026-07-30T12:00:00Z'
quota() {
  printf '{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h","remainingFraction":%s,"resetTime":"%s"},{"window":"weekly","remainingFraction":%s,"resetTime":"%s"}]}]}\n' \
    "$2" "$future" "$3" "$week" >"$GEMINI_QUOTA_DIR/$1.json"
}
printf 'ok\n' >"$GEMINI_AUTH_DIR/main"
quota main 0.7 0.8

add_output=$(bash "$SCRIPT" add alpha) || fail "add alpha failed"
assert wait_announce '--refresh-account gemini/alpha'
assert grep -qx "HOME=$HOME/.gemini-profiles/alpha agy" <<<"$add_output"
assert grep -qx 'alpha: Not logged in' <<<"$add_output"
assert test -d "$HOME/.gemini-profiles/alpha/.gemini/antigravity-cli"
for item in GEMINI.md extensions settings.json; do
  assert test -L "$HOME/.gemini-profiles/alpha/.gemini/$item"
done
assert test -L "$HOME/.gemini-profiles/alpha/.gemini/antigravity-cli/settings.json"
assert test "$(readlink "$HOME/.gemini-profiles/alpha/Library/Caches/ms-playwright-go")" \
  = "$HOME/Library/Caches/ms-playwright-go"
assert test "$(readlink "$HOME/.gemini-profiles/alpha/Library/Caches/ms-playwright")" \
  = "$HOME/Library/Caches/ms-playwright"
assert test ! -L "$HOME/.gemini-profiles/alpha/Library/Keychains"
assert test -f "$HOME/.gemini-profiles/alpha/Library/Keychains/gemini.keychain-db"
assert test "$(readlink "$HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db")" \
  = gemini.keychain-db
assert test "$(stat -f %Lp "$HOME/.gemini-profiles/alpha/.keychain-password")" = 600
# The unlock is the whole fix, and it only works when it names the real file rather than the
# symlink agy opens; a call under the base HOME would put the profile keychain in the real
# session's search list.
assert grep -q "unlock-keychain -p .* $HOME/.gemini-profiles/alpha/Library/Keychains/gemini.keychain-db" \
  "$SECURITY_CALLS"
assert grep -q "list-keychains -d user -s $HOME/.gemini-profiles/alpha/Library/Keychains/login.keychain-db" \
  "$SECURITY_CALLS"
assert_fails grep -q "CALL home=$HOME " "$SECURITY_CALLS"

# Antigravity starts every enabled MCP server on every launch, so a leg that reads main's server
# list spawns one process per leg per server. Legs get their own copy, forced fully disabled.
ALPHA_CONFIG="$HOME/.gemini-profiles/alpha/.gemini/config"
ALPHA_MCP="$ALPHA_CONFIG/mcp_config.json"
assert test ! -L "$ALPHA_CONFIG"
assert test -d "$ALPHA_CONFIG"
assert test "$(readlink "$ALPHA_CONFIG/value")" = "$HOME/.gemini/config/value"
assert test ! -L "$ALPHA_MCP"
assert test "$(jq -c '[.mcpServers[].disabled]' "$ALPHA_MCP")" = '[true,true]'
assert test "$(jq -r '.mcpServers | keys | join(",")' "$ALPHA_MCP")" = 'already-off,figma-dev-mode-mcp-server'
assert test "$(jq -r '.mcpServers["figma-dev-mode-mcp-server"].args[0]' "$ALPHA_MCP")" = mcp-remote
# main is the interactive profile Egor may enable a server in; enforcement must never reach it.
assert test "$(shasum "$BASE_MCP" | cut -d' ' -f1)" = "$BASE_MCP_SUM"

alpha_sum="$(shasum "$ALPHA_MCP" | cut -d' ' -f1)"
alpha_stamp="$(stat -f %Fm "$ALPHA_MCP")"
bash "$SCRIPT" list >/dev/null
assert test "$(shasum "$ALPHA_MCP" | cut -d' ' -f1)" = "$alpha_sum"
assert test "$(stat -f %Fm "$ALPHA_MCP")" = "$alpha_stamp"

mkdir -p "$HOME/.gemini-profiles/legacy/.gemini"
ln -s "$HOME/.gemini/config" "$HOME/.gemini-profiles/legacy/.gemini/config"
# The same legacy link spelled some other way. Recognised by string, it survives, every write below
# then lands THROUGH it, and disabling that leg's servers disables main's — Egor's interactive
# profile, the one place a server is his to enable.
mkdir -p "$HOME/.gemini-profiles/relative/.gemini"
ln -s ../../../.gemini/config "$HOME/.gemini-profiles/relative/.gemini/config"
mkdir -p "$HOME/.gemini-profiles/ownconf/.gemini/config"
printf '{"mcpServers":{"local":{"command":"noop"}}}\n' >"$HOME/.gemini-profiles/ownconf/.gemini/config/mcp_config.json"
printf 'mine\n' >"$HOME/.gemini-profiles/ownconf/.gemini/config/value"
mkdir -p "$HOME/.gemini-profiles/emptyconf/.gemini/config"
: >"$HOME/.gemini-profiles/emptyconf/.gemini/config/mcp_config.json"
# A compliant file needs no rewrite, so nothing else would ever break a link into a shared config:
# leave one and the next `mcp enable` outside the leg re-arms every leg at once.
mkdir -p "$HOME/.gemini-profiles/linkedconf/.gemini/config"
printf '{"mcpServers":{"shared":{"command":"noop","disabled":true}}}\n' >"$WORK/shared-mcp.json"
SHARED_MCP_SUM="$(shasum "$WORK/shared-mcp.json" | cut -d' ' -f1)"
ln -s "$WORK/shared-mcp.json" "$HOME/.gemini-profiles/linkedconf/.gemini/config/mcp_config.json"
bash "$SCRIPT" list >/dev/null
assert test ! -L "$HOME/.gemini-profiles/linkedconf/.gemini/config/mcp_config.json"
assert test "$(jq -r '.mcpServers.shared.command' "$HOME/.gemini-profiles/linkedconf/.gemini/config/mcp_config.json")" = noop
assert test "$(shasum "$WORK/shared-mcp.json" | cut -d' ' -f1)" = "$SHARED_MCP_SUM"
assert test ! -L "$HOME/.gemini-profiles/legacy/.gemini/config"
assert test "$(jq -c '[.mcpServers[].disabled]' "$HOME/.gemini-profiles/legacy/.gemini/config/mcp_config.json")" = '[true,true]'
assert test ! -L "$HOME/.gemini-profiles/relative/.gemini/config"
assert test "$(jq -c '[.mcpServers[].disabled]' "$HOME/.gemini-profiles/relative/.gemini/config/mcp_config.json")" = '[true,true]'
assert test "$(shasum "$BASE_MCP" | cut -d' ' -f1)" = "$BASE_MCP_SUM"
assert grep -qx mine "$HOME/.gemini-profiles/ownconf/.gemini/config/value"
assert test "$(jq -r '.mcpServers.local.disabled' "$HOME/.gemini-profiles/ownconf/.gemini/config/mcp_config.json")" = true
# An empty file is what a fresh Antigravity profile leaves behind; it lists nothing to disable.
assert test ! -s "$HOME/.gemini-profiles/emptyconf/.gemini/config/mcp_config.json"
rm -rf "$HOME/.gemini-profiles/legacy" "$HOME/.gemini-profiles/ownconf" \
  "$HOME/.gemini-profiles/emptyconf" "$HOME/.gemini-profiles/linkedconf" \
  "$HOME/.gemini-profiles/relative"

# A config DIRECTORY linked anywhere other than main's is shared just the same: left standing, the
# rewrite lands in that external config and an `mcp enable` on the far side re-arms the leg. It is
# privatized by copy — the leg's own files under it survive — and the far side is never written.
SHARED_CONFIG="$WORK/shared-config"
mkdir -p "$SHARED_CONFIG" "$HOME/.gemini-profiles/sharedconf/.gemini"
printf '{"mcpServers":{"outside":{"command":"noop"}}}\n' >"$SHARED_CONFIG/mcp_config.json"
printf 'private\n' >"$SHARED_CONFIG/own-file"
SHARED_CONFIG_SUM="$(shasum "$SHARED_CONFIG/mcp_config.json" | cut -d' ' -f1)"
ln -s "$SHARED_CONFIG" "$HOME/.gemini-profiles/sharedconf/.gemini/config"
bash "$SCRIPT" list >/dev/null
assert test ! -L "$HOME/.gemini-profiles/sharedconf/.gemini/config"
assert test -d "$HOME/.gemini-profiles/sharedconf/.gemini/config"
assert test "$(shasum "$SHARED_CONFIG/mcp_config.json" | cut -d' ' -f1)" = "$SHARED_CONFIG_SUM"
assert grep -qx private "$HOME/.gemini-profiles/sharedconf/.gemini/config/own-file"
assert test "$(jq -r '.mcpServers.outside.disabled' \
  "$HOME/.gemini-profiles/sharedconf/.gemini/config/mcp_config.json")" = true
shopt -s nullglob
sharedconf_aside=("$HOME/.gemini-profiles/sharedconf/.gemini/.config."*)
shopt -u nullglob
assert test "${#sharedconf_aside[@]}" -eq 0
rm -rf "$HOME/.gemini-profiles/sharedconf"

# A source jq cannot parse — a JSONC comment, plausible for a VS Code-derived product, or a partial
# write — must leave a fresh leg with NO mcp_config.json and say so, never with a verbatim copy of
# main's ENABLED server list.
BASE_MCP_GOOD="$WORK/base-mcp-good.json"
cp "$BASE_MCP" "$BASE_MCP_GOOD"
cat >"$BASE_MCP" <<'EOF'
{
  // figma
  "mcpServers": {"figma": {"command": "npx", "args": ["mcp-remote"]}}
}
EOF
mkdir -p "$HOME/.gemini-profiles/badbase"
unparsable_warning=$(bash "$SCRIPT" list 2>&1 >/dev/null)
assert grep -q 'is unparsable' <<<"$unparsable_warning"
assert test ! -e "$HOME/.gemini-profiles/badbase/.gemini/config/mcp_config.json"
cp "$BASE_MCP_GOOD" "$BASE_MCP"
bash "$SCRIPT" list >/dev/null
assert test "$(jq -c '[.mcpServers[].disabled]' \
  "$HOME/.gemini-profiles/badbase/.gemini/config/mcp_config.json")" = '[true,true]'
rm -rf "$HOME/.gemini-profiles/badbase"
assert test "$(shasum "$BASE_MCP" | cut -d' ' -f1)" = "$BASE_MCP_SUM"

# A DANGLING config link — what the legacy absolute one becomes the moment ~/.gemini/config is
# renamed. `mkdir -p` on it fails, and under `set -e` that took `list` down with it: every healthy
# account vanished from the output and worker-run read the whole leg as unavailable.
mkdir -p "$HOME/.gemini-profiles/dangling/.gemini"
ln -s "$HOME/.gemini/config-was-renamed" "$HOME/.gemini-profiles/dangling/.gemini/config"
DANGLING_LIST="$(bash "$SCRIPT" list)" || fail "a dangling leg config link took list down"
assert test ! -L "$HOME/.gemini-profiles/dangling/.gemini/config"
assert test -d "$HOME/.gemini-profiles/dangling/.gemini/config"
assert test "$(jq -c '[.mcpServers[].disabled]' \
  "$HOME/.gemini-profiles/dangling/.gemini/config/mcp_config.json")" = '[true,true]'
assert grep -q alpha <<<"$DANGLING_LIST"
rm -rf "$HOME/.gemini-profiles/dangling"

# main's config directory unreadable: `resolved_path` returned the status of the subshell that
# could not enter it, and the standalone assignment reading it aborted `list` under `set -e` —
# every healthy account vanished from the output and worker-run read the whole vendor as gone.
chmod 000 "$HOME/.gemini/config"
UNREADABLE_RC=0
UNREADABLE_LIST="$(bash "$SCRIPT" list)" || UNREADABLE_RC=$?
# Restored before the verdict: exiting at 000 leaves a directory the EXIT trap cannot descend into,
# so a failure here also leaks the whole temp tree.
chmod 755 "$HOME/.gemini/config"
[ "$UNREADABLE_RC" = 0 ] || fail "an unreadable main config took list down"
assert grep -q '^alpha:' <<<"$UNREADABLE_LIST"
bash "$SCRIPT" list >/dev/null

# The per-entry links are main's config mirrored, so they are refreshed on every pass: created
# once, a file Antigravity or Egor adds to main afterwards reached no existing leg at all — the
# regression against the whole-directory link this shape replaced.
printf 'added later\n' >"$HOME/.gemini/config/added.json"
bash "$SCRIPT" list >/dev/null
assert test "$(readlink "$ALPHA_CONFIG/added.json")" = "$HOME/.gemini/config/added.json"
# And a link to a file main no longer has is no part of that mirror.
rm -f "$HOME/.gemini/config/added.json"
bash "$SCRIPT" list >/dev/null
assert test ! -L "$ALPHA_CONFIG/added.json"
assert test "$(readlink "$ALPHA_CONFIG/value")" = "$HOME/.gemini/config/value"
assert test "$(shasum "$BASE_MCP" | cut -d' ' -f1)" = "$BASE_MCP_SUM"

# Healing every account is what `list` and `status` are FOR; every other command touches only the
# account it names. Run before dispatch it relinked and keychain-migrated every leg on a `use`
# that only prints a pin — and on a headless run the worker pool was about to refuse.
mkdir -p "$HOME/.gemini-profiles/untouched/.gemini"
ln -s "$HOME/.gemini/config" "$HOME/.gemini-profiles/untouched/.gemini/config"
bash "$SCRIPT" use >/dev/null
assert test -L "$HOME/.gemini-profiles/untouched/.gemini/config"
bash "$SCRIPT" list >/dev/null
assert test ! -L "$HOME/.gemini-profiles/untouched/.gemini/config"
rm -rf "$HOME/.gemini-profiles/untouched"

mkdir -p "$HOME/.gemini-profiles/trap/.gemini/config" "$HOME/.gemini-profiles/trap/Library/Keychains"
mkdir -p "$HOME/.gemini-profiles/trap/Library/Caches/ms-playwright-go"
printf 'keep\n' >"$HOME/.gemini-profiles/trap/.gemini/config/value"
printf 'own\n' >"$HOME/.gemini-profiles/trap/Library/Caches/ms-playwright-go/marker"
printf 'own\n' >"$HOME/.gemini-profiles/trap/Library/Keychains/login.keychain-db"
(umask 077; printf 'own\n' >"$HOME/.gemini-profiles/trap/.keychain-password")
bash "$SCRIPT" list >/dev/null
assert test ! -L "$HOME/.gemini-profiles/trap/.gemini/config"
assert grep -qx keep "$HOME/.gemini-profiles/trap/.gemini/config/value"
assert test ! -L "$HOME/.gemini-profiles/trap/Library/Caches/ms-playwright-go"
assert grep -qx own "$HOME/.gemini-profiles/trap/Library/Caches/ms-playwright-go/marker"
assert test ! -L "$HOME/.gemini-profiles/trap/Library/Keychains"
# An openable keychain is migrated under the addressable name, never rebuilt: rebuilding one that
# still has its password would throw away a working profile for nothing.
assert grep -qx own "$HOME/.gemini-profiles/trap/Library/Keychains/gemini.keychain-db"
assert test "$(readlink "$HOME/.gemini-profiles/trap/Library/Keychains/login.keychain-db")" \
  = gemini.keychain-db

gemini_base_home="$HOME"
gemini_profiles_dir="$HOME/.gemini-profiles"
. "$ROOT/share/gemini-accounts.sh"
rm -rf "$HOME/.gemini-profiles/alpha/Library/Keychains" "$HOME/.gemini-profiles/alpha/.keychain-password"
ln -sfn "$HOME/Library/Keychains" "$HOME/.gemini-profiles/alpha/Library/Keychains"
warning=$(gemini_ensure_keychain "$HOME/.gemini-profiles/alpha" 2>&1 >/dev/null)
assert test ! -L "$HOME/.gemini-profiles/alpha/Library/Keychains"
assert test -f "$HOME/.gemini-profiles/alpha/Library/Keychains/gemini.keychain-db"
assert grep -q 'sign it in again' <<<"$warning"
assert test ! -e "$HOME/Library/Keychains/Keychains"
assert test ! -e "$HOME/Library/Keychains/login.keychain-db"
assert test ! -e "$HOME/Library/Keychains/gemini.keychain-db"

ALPHA_KC="$HOME/.gemini-profiles/alpha/Library/Keychains"
# agy recreates login.keychain-db as a real file whenever it is missing, so the next run has to
# adopt that file rather than leave agy writing to something nothing can unlock.
rm -f "$ALPHA_KC/login.keychain-db" "$ALPHA_KC/gemini.keychain-db"
printf 'adopted\n' >"$ALPHA_KC/login.keychain-db"
(umask 077; printf 'adopted\n' >"$HOME/.gemini-profiles/alpha/.keychain-password")
gemini_ensure_keychain "$HOME/.gemini-profiles/alpha"
assert grep -qx adopted "$ALPHA_KC/gemini.keychain-db"
assert test "$(readlink "$ALPHA_KC/login.keychain-db")" = gemini.keychain-db

# A symlink left pointing anywhere else is the shared-account bug in file form.
ln -sfn "$HOME/Library/Keychains/login.keychain-db" "$ALPHA_KC/login.keychain-db"
gemini_ensure_keychain "$HOME/.gemini-profiles/alpha"
assert test "$(readlink "$ALPHA_KC/login.keychain-db")" = gemini.keychain-db
assert grep -qx adopted "$ALPHA_KC/gemini.keychain-db"

# Every launch unlocks again, because the keychain is locked by the next boot.
: >"$SECURITY_CALLS"
gemini_ensure_keychain "$HOME/.gemini-profiles/alpha"
assert grep -q "unlock-keychain -p adopted $ALPHA_KC/gemini.keychain-db" "$SECURITY_CALLS"

gemini_ensure_keychain "$HOME/.gemini-profiles/vanished"
assert test ! -e "$HOME/.gemini-profiles/vanished"
gemini_ensure_keychain "$HOME"
assert test ! -e "$HOME/Library/Keychains/login.keychain-db"

# A keychain whose password is gone can never be unlocked, so it is replaced rather than left to
# prompt forever; the same for one whose stored password no longer opens it.
rm -f "$HOME/.gemini-profiles/alpha/.keychain-password"
gemini_ensure_keychain "$HOME/.gemini-profiles/alpha"
assert test -s "$HOME/.gemini-profiles/alpha/.keychain-password"
assert test "$(cat "$ALPHA_KC/gemini.keychain-db")" \
  = "$(cat "$HOME/.gemini-profiles/alpha/.keychain-password")"
assert test "$(stat -f %Lp "$HOME/.gemini-profiles/alpha/.keychain-password")" = 600
printf 'stale\n' >"$ALPHA_KC/gemini.keychain-db"
gemini_ensure_keychain "$HOME/.gemini-profiles/alpha"
assert_fails grep -qx stale "$ALPHA_KC/gemini.keychain-db"
assert test "$(cat "$ALPHA_KC/gemini.keychain-db")" \
  = "$(cat "$HOME/.gemini-profiles/alpha/.keychain-password")"

# A password file left behind with loose permissions is rewritten, not truncated in place.
chmod 644 "$HOME/.gemini-profiles/alpha/.keychain-password"
printf 'wrong\n' >"$HOME/.gemini-profiles/alpha/.keychain-password"
gemini_ensure_keychain "$HOME/.gemini-profiles/alpha"
assert test "$(stat -f %Lp "$HOME/.gemini-profiles/alpha/.keychain-password")" = 600
assert test "$(cat "$ALPHA_KC/gemini.keychain-db")" \
  = "$(cat "$HOME/.gemini-profiles/alpha/.keychain-password")"

# A directory squatting on either path is repaired instead of failing every future run.
rm -rf "$ALPHA_KC"; mkdir -p "$ALPHA_KC/gemini.keychain-db"
gemini_ensure_keychain "$HOME/.gemini-profiles/alpha"
assert test -f "$ALPHA_KC/gemini.keychain-db"
assert test "$(readlink "$ALPHA_KC/login.keychain-db")" = gemini.keychain-db

rm -rf "$ALPHA_KC"
saved_password=$(cat "$HOME/.gemini-profiles/alpha/.keychain-password")
warning=$(GEMINIB_SECURITY_CMD=/usr/bin/false gemini_ensure_keychain "$HOME/.gemini-profiles/alpha" 2>&1 >/dev/null)
assert test ! -e "$ALPHA_KC/gemini.keychain-db"
assert grep -q 'could not create a keychain' <<<"$warning"
# A keychain that cannot be built is a warning, never a reason to refuse the account: callers run
# under `set -e`, and a nonzero return here would take geminib and the limits refresh down with it.
GEMINIB_SECURITY_CMD=/usr/bin/false gemini_ensure_keychain "$HOME/.gemini-profiles/alpha" 2>/dev/null
assert test "$?" = 0
assert test ! -e "$HOME/.gemini-profiles/alpha/.keychain-password.new"
assert grep -qx "$saved_password" "$HOME/.gemini-profiles/alpha/.keychain-password"

# A run killed mid-repair leaves a bare directory or a stray real file; the next one must still
# converge, and forty at once must agree on one keychain.
rm -rf "$ALPHA_KC"; mkdir -p "$ALPHA_KC"
printf 'crashed\n' >"$ALPHA_KC/gemini.keychain-db"
for _ in $(seq 1 40); do gemini_ensure_keychain "$HOME/.gemini-profiles/alpha" & done
wait
assert test "$(readlink "$ALPHA_KC/login.keychain-db")" = gemini.keychain-db
assert test -f "$ALPHA_KC/gemini.keychain-db"
assert test "$(cat "$ALPHA_KC/gemini.keychain-db")" \
  = "$(cat "$HOME/.gemini-profiles/alpha/.keychain-password")"
assert test "$(stat -f %Lp "$HOME/.gemini-profiles/alpha/.keychain-password")" = 600
assert_fails bash "$SCRIPT" add main >/dev/null 2>&1
assert_fails bash "$SCRIPT" add Bad >/dev/null 2>&1
assert_fails bash "$SCRIPT" add alpha >/dev/null 2>&1

custom_profiles="$WORK/custom-profiles"
custom_output=$(GEMINIB_PROFILES_DIR="$custom_profiles" bash "$SCRIPT" add override) \
  || fail "add with profiles override failed"
assert grep -qx "HOME=$custom_profiles/override agy" <<<"$custom_output"

bash "$SCRIPT" add beta >/dev/null || fail "add beta failed"
printf 'ok\n' >"$GEMINI_AUTH_DIR/alpha"
quota alpha 0.4 0.55
list_output=$(bash "$SCRIPT" list) || fail "list failed"
assert test "$(sed -n '1p' <<<"$list_output")" = 'main: Logged in'
assert grep -qx 'alpha: Logged in' <<<"$list_output"
assert grep -qx 'beta: Not logged in' <<<"$list_output"

GEMINI_PROBE_LOG="$WORK/list-probes"
export GEMINI_PROBE_LOG
bash "$SCRIPT" list >/dev/null || fail "parallel list failed"
assert test "$(awk '/^END / {print NR; exit}' "$GEMINI_PROBE_LOG")" -gt 4
unset GEMINI_PROBE_LOG

status_output=$(bash "$SCRIPT" status) || fail "status failed"
assert grep -Eq '^main: Logged in \| 5H 30% reset .+ \| WEEKLY 20% reset .+$' <<<"$status_output"
assert grep -Eq '^alpha: Logged in \| 5H 60% reset .+ \| WEEKLY 45% reset .+$' <<<"$status_output"
assert grep -Eq '^beta: Not logged in \| 5H - reset unknown \| WEEKLY - reset unknown$' <<<"$status_output"

GEMINI_PROBE_LOG="$WORK/status-probes"
export GEMINI_PROBE_LOG
bash "$SCRIPT" status >/dev/null || fail "parallel status failed"
assert test "$(awk '/^END / {print NR; exit}' "$GEMINI_PROBE_LOG")" -gt 4
unset GEMINI_PROBE_LOG

: >"$AGY_CALLS"
bash "$SCRIPT" run main --flag 'two words' '*' '' || fail "main run failed"
assert grep -qx "CALL home=$HOME argc=4" "$AGY_CALLS"
assert grep -qx 'ARG=two\\ words' "$AGY_CALLS"
assert grep -qx 'ARG=\\\*' "$AGY_CALLS"
assert grep -qx "ARG=''" "$AGY_CALLS"

: >"$AGY_CALLS"
bash "$SCRIPT" alpha exec --json 'two words' || fail "profile shorthand failed"
assert grep -qx "CALL home=$HOME/.gemini-profiles/alpha argc=2" "$AGY_CALLS"
assert test "$(sed -n '2p' "$AGY_CALLS")" = 'ARG=--json'
assert test "$(sed -n '3p' "$AGY_CALLS")" = 'ARG=two\ words'

: >"$AGY_CALLS"
fresh_output=$(bash "$SCRIPT" profile fresh 2>&1) || fail "profile fresh failed"
assert test -d "$HOME/.gemini-profiles/fresh"
assert grep -q "new profile 'fresh' created" <<<"$fresh_output"
assert grep -qx "CALL home=$HOME/.gemini-profiles/fresh argc=0" "$AGY_CALLS"
assert wait_announce '--refresh-account gemini/fresh'

: >"$AGY_CALLS"
reopen_output=$(bash "$SCRIPT" p alpha 2>&1) || fail "reopen alpha failed"
if grep -q "new profile" <<<"$reopen_output"; then fail "reopen reprinted the created note"; fi
sleep 0.3
assert test "$(grep -cxF -- '--refresh-account gemini/alpha' "$ANNOUNCE_LOG")" = 1

for reserved in profile p run add remove list status pick help login; do
  assert_fails bash "$SCRIPT" profile "$reserved" </dev/null >/dev/null 2>&1
  assert_fails bash "$SCRIPT" add "$reserved" </dev/null >/dev/null 2>&1
done
assert test ! -d "$HOME/.gemini-profiles/status"
reserved_err=$(bash "$SCRIPT" profile add </dev/null 2>&1); reserved_rc=$?
assert test "$reserved_rc" -eq 2
assert grep -qx "geminib: invalid profile name 'add'" <<<"$reserved_err"
assert_fails bash "$SCRIPT" profile Bad </dev/null >/dev/null 2>&1
assert_fails bash "$SCRIPT" add -h </dev/null >/dev/null 2>&1
assert_fails bash "$SCRIPT" profile -dash </dev/null >/dev/null 2>&1
mkdir -p "$HOME/.gemini-profiles/-existing"
assert_fails bash "$SCRIPT" -existing exec </dev/null >/dev/null 2>&1
assert test ! -e "$HOME/.gemini-profiles/-h"
assert test ! -e "$HOME/.gemini-profiles/-dash"

mkdir -p "$HOME/.gemini-profiles/pick"
for route in profile p run; do
  : >"$AGY_CALLS"
  bash "$SCRIPT" "$route" pick --reserved >/dev/null 2>&1 || fail "$route pick failed"
  assert grep -qx "CALL home=$HOME/.gemini-profiles/pick argc=1" "$AGY_CALLS"
done
: >"$AGY_CALLS"
bash "$SCRIPT" pick exec --reserved >/dev/null 2>&1 || fail "pick exec failed"
assert grep -qx "CALL home=$HOME/.gemini-profiles/pick argc=1" "$AGY_CALLS"
assert bash "$SCRIPT" remove pick
assert test ! -e "$HOME/.gemini-profiles/pick"

: >"$AGY_CALLS"
exec_err=$(bash "$SCRIPT" wrok exec --json </dev/null 2>&1); exec_rc=$?
assert test "$exec_rc" -eq 2
assert grep -qx 'geminib: unknown account: wrok' <<<"$exec_err"
assert test ! -d "$HOME/.gemini-profiles/wrok"
assert test ! -s "$AGY_CALLS"

for flag in -h --help; do
  help_out=$(bash "$SCRIPT" profile "$flag" </dev/null) || fail "profile $flag failed"
  assert grep -q 'geminib profile <name>' <<<"$help_out"
  assert test ! -d "$HOME/.gemini-profiles/$flag"
done

# --- worker pool: the same "don't burn this one" state claudeb and codexb have ---
# Output goes to a file rather than redirecting the assert itself: a redirected `assert` swallows
# its own FAIL line and the suite then dies silently with no output at all.
POOL_OUT="$WORK/pool.out"
gb() { bash "$SCRIPT" "$@" >"$POOL_OUT" 2>&1; }
assert gb disable alpha
assert grep -qx alpha "$HOME/.gemini-profiles/.geminib/disabled"
# Exclusion IS unreachability for a headless run — `--print` is agy asked by a program — while an
# interactive session is the user and passes, and the vendor pin is the one override.
: >"$AGY_CALLS"
assert_fails gb profile alpha --print hello
assert grep -q 'alpha is out of the worker pool' "$POOL_OUT"
assert_fails grep -q "home=$HOME/.gemini-profiles/alpha" "$AGY_CALLS"
assert gb profile alpha --mode plan
assert grep -q "home=$HOME/.gemini-profiles/alpha" "$AGY_CALLS"
GEMINI_PIN_CONFIG="$WORK/worker-model-pin"
printf 'gemini_profile=alpha\n' >"$GEMINI_PIN_CONFIG"
: >"$AGY_CALLS"
assert env WORKER_PICK_CONFIG_FILE="$GEMINI_PIN_CONFIG" bash "$SCRIPT" profile alpha --print hello
assert grep -q "home=$HOME/.gemini-profiles/alpha" "$AGY_CALLS"
# The pool file lives beside the profiles and must never be read back as one.
mkdir -p "$HOME/.gemini-profiles/.junk"
assert gb list
assert_fails grep -q '^\.geminib:' "$POOL_OUT"
assert_fails grep -q '^\.junk:' "$POOL_OUT"
assert grep -q 'alpha: .*(out of pool)' "$POOL_OUT"
assert_fails grep -q 'main: .*(out of pool)' "$POOL_OUT"
assert gb status
assert_fails grep -q '^\.geminib:' "$POOL_OUT"
assert_fails grep -q '^\.junk:' "$POOL_OUT"
assert grep -q 'alpha: .*(out of pool) | 5H' "$POOL_OUT"
gemini_names=$(gemini_profiles_dir="$HOME/.gemini-profiles" gemini_base_home="$HOME" bash -c '. "'"$ROOT"'/share/gemini-accounts.sh" && gemini_account_names')
assert_fails grep -q '^\.geminib$' <<<"$gemini_names"
assert_fails grep -q '^\.junk$' <<<"$gemini_names"
assert gb disable alpha
assert grep -q 'already disabled' "$POOL_OUT"
assert gb enable alpha
assert_fails grep -qx alpha "$HOME/.gemini-profiles/.geminib/disabled"
assert gb enable alpha
assert grep -q 'already enabled' "$POOL_OUT"
assert_fails gb disable ghost-account
assert_fails gb enable ghost-account
assert_fails gb disable
# --all is the menu's whole-vendor switch: every account this tool knows, main included, and
# idempotent — running it twice is not an error and changes nothing the second time.
gemini_all_names=$(gemini_profiles_dir="$HOME/.gemini-profiles" gemini_base_home="$HOME" \
  bash -c '. "'"$ROOT"'/share/gemini-accounts.sh" && gemini_account_names' | LC_ALL=C sort)
assert gb disable --all
assert test "$(LC_ALL=C sort "$HOME/.gemini-profiles/.geminib/disabled")" = "$gemini_all_names"
assert gb disable --all
assert test "$(LC_ALL=C sort "$HOME/.gemini-profiles/.geminib/disabled")" = "$gemini_all_names"
assert gb enable --all
assert test ! -s "$HOME/.gemini-profiles/.geminib/disabled"
assert gb enable --all
assert test ! -s "$HOME/.gemini-profiles/.geminib/disabled"
# One account already in the requested state must not block the rest.
assert gb disable alpha
assert gb disable --all
assert test "$(LC_ALL=C sort "$HOME/.gemini-profiles/.geminib/disabled")" = "$gemini_all_names"
assert gb enable --all
# An empty pool is a legitimate state: it says no worker may run, not that nobody may work.
for pool_profile in "$HOME/.gemini-profiles"/*/; do
  pool_profile=$(basename "$pool_profile")
  case "$pool_profile" in .*) continue ;; esac
  gb disable "$pool_profile" || true
done
assert gb disable main
assert grep -qx main "$HOME/.gemini-profiles/.geminib/disabled"
# The re-enable loop below walks profile directories only, and `main` is not one of them.
assert gb enable main
for pool_profile in "$HOME/.gemini-profiles"/*/; do
  pool_profile=$(basename "$pool_profile")
  case "$pool_profile" in .*) continue ;; esac
  gb enable "$pool_profile" || true
done

cache_dir="$HOME/.llm-limits-gemini"
mkdir -p "$cache_dir"
printf '{}\n' >"$cache_dir/alpha.json"
printf 'removed\n' >"$cache_dir/alpha.json.removed"
assert bash "$SCRIPT" remove alpha
assert test ! -e "$HOME/.gemini-profiles/alpha"
assert test ! -e "$cache_dir/alpha.json"
assert test -e "$cache_dir/alpha.json.removed"
# Removal announces a passive collect (no args) so the menu row drops without a
# manual refresh.
assert wait_announce ''
assert_fails bash "$SCRIPT" remove ../outside
assert_fails bash "$SCRIPT" remove never-existed

assert bash "$SCRIPT" add pinacct >/dev/null
PIN_CONFIG="$WORK/worker-model-use"
printf 'worker=auto\nclaudeb_profile=claude-a\ncodex_profile=codex-a\n' >"$PIN_CONFIG"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use main
assert grep -qx 'gemini_profile=main' "$PIN_CONFIG"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use pinacct
assert grep -qx 'gemini_profile=pinacct' "$PIN_CONFIG"
assert test "$(grep -c '^gemini_profile=' "$PIN_CONFIG")" = 1
assert grep -qx 'worker=auto' "$PIN_CONFIG"
assert grep -qx 'claudeb_profile=claude-a' "$PIN_CONFIG"
assert grep -qx 'codex_profile=codex-a' "$PIN_CONFIG"
pin_output=$(env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use)
assert grep -qx 'geminib: workers are pinned to pinacct' <<<"$pin_output"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use --clear
assert_fails grep -q '^gemini_profile=' "$PIN_CONFIG"
assert grep -qx 'worker=auto' "$PIN_CONFIG"
pin_rc=0
env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use missing >/dev/null 2>&1 || pin_rc=$?
assert test "$pin_rc" -eq 2
pin_rc=0
env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use ../pinacct >/dev/null 2>&1 || pin_rc=$?
assert test "$pin_rc" -eq 2
assert_fails grep -q '^gemini_profile=' "$PIN_CONFIG"
UNREADABLE_PIN="$WORK/worker-model-unreadable"
printf 'worker=auto\ngemini_profile=pinacct\n' >"$UNREADABLE_PIN"
chmod 000 "$UNREADABLE_PIN"
if [ -r "$UNREADABLE_PIN" ]; then
  printf 'SKIP: unreadable-pin case (running with read-everything privileges)\n'
else
  pin_rc=0
  env WORKER_PICK_CONFIG_FILE="$UNREADABLE_PIN" bash "$SCRIPT" use --clear \
    >"$WORK/unreadable-pin.out" 2>&1 || pin_rc=$?
  assert test "$pin_rc" -eq 2
  assert grep -q 'exists but cannot be read' "$WORK/unreadable-pin.out"
  chmod 600 "$UNREADABLE_PIN"
  assert grep -qx 'worker=auto' "$UNREADABLE_PIN"
  assert grep -qx 'gemini_profile=pinacct' "$UNREADABLE_PIN"
fi
chmod 600 "$UNREADABLE_PIN"

IMAGE_SCRIPT="$ROOT/bin/gemini-image"
IMAGE_BIN="$WORK/image-bin"
IMAGE_CALLS="$WORK/image-calls"
IMAGE_PROMPT="$WORK/image-prompt"
IMAGE_PICK_CALLS="$WORK/image-pick-calls"
IMAGE_MAGICK_CALLS="$WORK/image-magick-calls"
IMAGE_SIPS_CALLS="$WORK/image-sips-calls"
IMAGE_REPLY="$WORK/generated.jpg"
export IMAGE_CALLS IMAGE_PROMPT IMAGE_PICK_CALLS IMAGE_MAGICK_CALLS IMAGE_SIPS_CALLS IMAGE_REPLY
mkdir -p "$IMAGE_BIN" "$WORK/image-output" "$HOME/.claude"
mkdir -p "$HOME/.gemini-profiles/explicit" "$HOME/.gemini-profiles/poolacct" \
  "$HOME/.gemini-profiles/pinacct" "$HOME/.gemini-profiles/rescue"
: >"$IMAGE_PICK_CALLS"
: >"$IMAGE_MAGICK_CALLS"
: >"$IMAGE_SIPS_CALLS"

cat >"$IMAGE_BIN/geminib" <<'EOF'
#!/usr/bin/env bash
previous=''
before_previous=''
for argument in "$@"; do
  before_previous=$previous
  previous=$argument
done
printf 'account=%s\nprint_flag=%s\n' "$2" "$before_previous" >>"$IMAGE_CALLS"
timeout_next=false
for argument in "$@"; do
  if [ "$timeout_next" = true ]; then printf 'print_timeout=%s\n' "$argument" >>"$IMAGE_CALLS"; timeout_next=false; fi
  [ "$argument" = --print-timeout ] && timeout_next=true
done
printf '%s' "$previous" >"$IMAGE_PROMPT"
case "${IMAGE_MODE:-reply}" in
  limit)
    printf 'RESOURCE_EXHAUSTED\n'
    exit 1
    ;;
  quota)
    printf 'status\nQUOTA\n'
    exit 1
    ;;
  rescue)
    # The real tool names the file after the instruction's ImageName; the rescue
    # search keys on that, so the fake must honor it too.
    image_name=$(printf '%s' "$previous" | sed -n 's/^ImageName: //p')
    mkdir -p "$(dirname "$IMAGE_RESCUE_FILE")"
    printf 'rescued\n' >"$(dirname "$IMAGE_RESCUE_FILE")/${image_name:-rescued}.jpg"
    printf 'status\n/nonexistent/generated.jpg\n'
    ;;
  *)
    printf 'generated:%s\n' "$2" >"$IMAGE_REPLY"
    printf 'status\n%s\n' "$IMAGE_REPLY"
    ;;
esac
EOF
chmod +x "$IMAGE_BIN/geminib"

cat >"$IMAGE_BIN/worker-pick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$IMAGE_PICK_CALLS"
case "${IMAGE_PICK_MODE:-ok}" in
  ok) printf '%s\n' "${IMAGE_PICK_ACCOUNT:-picked}" ;;
  limit) exit 3 ;;
  fail) exit 7 ;;
esac
EOF
chmod +x "$IMAGE_BIN/worker-pick"

cat >"$IMAGE_BIN/magick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$IMAGE_MAGICK_CALLS"
case "$*" in
  *-format*info:) printf 'srgb(7,246,5)'; exit 0 ;;
esac
for output in "$@"; do :; done
output=${output#PNG:}
printf 'converted\n' >"$output"
EOF
chmod +x "$IMAGE_BIN/magick"

cat >"$IMAGE_BIN/sips" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$IMAGE_SIPS_CALLS"
printf '  pixelWidth: 1024\n  pixelHeight: 768\n  format: jpeg\n'
EOF
chmod +x "$IMAGE_BIN/sips"

IMAGE_PATH="$IMAGE_BIN:/usr/bin:/bin"
IMAGE_OUT="$WORK/image.out"
IMAGE_ERR="$WORK/image.err"
image_run() {
  env PATH="$IMAGE_PATH" IMAGE_MODE="${IMAGE_MODE:-reply}" \
    IMAGE_PICK_MODE="${IMAGE_PICK_MODE:-ok}" IMAGE_PICK_ACCOUNT="${IMAGE_PICK_ACCOUNT:-picked}" \
    IMAGE_RESCUE_FILE="${IMAGE_RESCUE_FILE:-}" WORKER_PICK_CONFIG_FILE="$HOME/.claude/worker-model" \
    bash "$IMAGE_SCRIPT" "$@" >"$IMAGE_OUT" 2>"$IMAGE_ERR"
}

image_rc=0
image_run --dest "$WORK/image-output/bad.jpg" --prompt badge --aspect 5:4 || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q '^usage: gemini-image ' "$IMAGE_ERR"

# An extensionless destination names no format for the conversion below to write, and `magick`
# cannot infer one from it.
image_rc=0
image_run --dest "$WORK/image-output/noext" --prompt badge || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q '^usage: gemini-image ' "$IMAGE_ERR"
# A bare trailing dot is that same nameless format, and it reads as an extension to a pattern.
image_rc=0
image_run --dest "$WORK/image-output/trailing." --prompt badge || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q '^usage: gemini-image ' "$IMAGE_ERR"

# `geminib profile` CREATES an unknown name, keychain and all, so a typo or a stale pin would
# launch a logged-out ghost profile and leave it in the roster every limits surface reads.
: >"$IMAGE_CALLS"
image_rc=0
image_run --dest "$WORK/image-output/ghost.jpg" --prompt badge --account ghostacct || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'unknown account: ghostacct' "$IMAGE_ERR"
assert test ! -d "$HOME/.gemini-profiles/ghostacct"
assert test ! -s "$IMAGE_CALLS"

# A generation is billed the moment it is sent, so everything the destination alone can refuse is
# refused before it goes out.
mv "$IMAGE_BIN/magick" "$WORK/magick-away"
: >"$IMAGE_CALLS"
image_rc=0
image_run --dest "$WORK/image-output/nomagick.png" --prompt badge --account main || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'magick is required' "$IMAGE_ERR"
assert test ! -s "$IMAGE_CALLS"
: >"$IMAGE_CALLS"
image_rc=0
image_run --dest "$WORK/image-output/nomagick.jpg" --prompt badge --account main --transparent \
  || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'requires a .png destination' "$IMAGE_ERR"
# A non-png destination needs it too the moment the model answers in another format, which nothing
# here can know before the generation is spent.
: >"$IMAGE_CALLS"
image_rc=0
image_run --dest "$WORK/image-output/nomagick.jpg" --prompt badge --account main || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'magick is required' "$IMAGE_ERR"
assert test ! -s "$IMAGE_CALLS"
mv "$WORK/magick-away" "$IMAGE_BIN/magick"

printf 'reference\n' >"$WORK/reference.jpg"
: >"$IMAGE_PICK_CALLS"
image_rc=0
image_run --dest "$WORK/image-output/alpha.jpg" --prompt 'simple badge' --transparent || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'requires a .png destination' "$IMAGE_ERR"
assert image_run --dest "$WORK/image-output/alpha.png" --prompt 'simple badge' \
  --aspect 16:9 --ref "$WORK/reference.jpg" --transparent --account explicit
assert grep -q '#00FF00' "$IMAGE_PROMPT"
assert_fails grep -qi transparent "$IMAGE_PROMPT"
assert grep -q 'generate_image' "$IMAGE_PROMPT"
assert grep -q 'exactly once' "$IMAGE_PROMPT"
assert test "$(grep -o 'generate_image' "$IMAGE_PROMPT" | wc -l | tr -d ' ')" = 1
assert grep -q 'AspectRatio: 16:9' "$IMAGE_PROMPT"
assert grep -q -- "- $WORK/reference.jpg" "$IMAGE_PROMPT"
assert grep -qx 'account=explicit' "$IMAGE_CALLS"
assert grep -qx 'print_flag=--print' "$IMAGE_CALLS"
assert test ! -s "$IMAGE_PICK_CALLS"
assert grep -qF -- "-format %[pixel:p{2,2}] info:" "$IMAGE_MAGICK_CALLS"
assert grep -q -- "-fuzz 12% -transparent srgb(7,246,5) .*/keyed.png" "$IMAGE_MAGICK_CALLS"
assert grep -q -- "-alpha extract -morphology EdgeIn Octagon:2 .*/edge.png" "$IMAGE_MAGICK_CALLS"
assert grep -qF -- "-channel G -fx min(g,max(r,b)) +channel" "$IMAGE_MAGICK_CALLS"
assert grep -q -- "despilled.png .*/edge.png -composite PNG:$WORK/image-output/alpha.png" "$IMAGE_MAGICK_CALLS"
assert grep -qx "dest=$WORK/image-output/alpha.png" "$IMAGE_OUT"
assert grep -qx 'size=1024x768' "$IMAGE_OUT"
assert grep -qx 'account=explicit' "$IMAGE_OUT"
assert grep -q "$WORK/image-output/alpha.png" "$IMAGE_SIPS_CALLS"

image_rc=0
image_run --dest "$WORK/image-output/refs.jpg" --prompt badge \
  --ref "$WORK/reference.jpg" --ref "$WORK/reference.jpg" \
  --ref "$WORK/reference.jpg" --ref "$WORK/reference.jpg" || image_rc=$?
assert test "$image_rc" -eq 2

: >"$IMAGE_CALLS"
: >"$IMAGE_MAGICK_CALLS"
IMAGE_PICK_MODE=ok
IMAGE_PICK_ACCOUNT=poolacct
export IMAGE_PICK_MODE IMAGE_PICK_ACCOUNT
assert image_run --dest "$WORK/image-output/picked.jpg" --prompt landscape
assert grep -qx 'account=poolacct' "$IMAGE_OUT"
assert grep -qx -- '--account gemini' "$IMAGE_PICK_CALLS"
assert grep -qx 'generated:poolacct' "$WORK/image-output/picked.jpg"
assert test ! -s "$IMAGE_MAGICK_CALLS"

printf 'gemini_profile=pinacct\n' >"$HOME/.claude/worker-model"
IMAGE_PICK_MODE=fail
export IMAGE_PICK_MODE
assert image_run --dest "$WORK/image-output/pin.jpg" --prompt portrait
assert grep -qx 'account=pinacct' "$IMAGE_OUT"
assert grep -q 'falling back to account pinacct' "$IMAGE_ERR"

printf 'worker=gemini\n' >"$HOME/.claude/worker-model"
assert image_run --dest "$WORK/image-output/main.jpg" --prompt portrait
assert grep -qx 'account=main' "$IMAGE_OUT"
assert grep -q 'falling back to account main' "$IMAGE_ERR"

IMAGE_PICK_MODE=limit
export IMAGE_PICK_MODE
image_rc=0
image_run --dest "$WORK/image-output/limit.jpg" --prompt portrait || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx GEMINI_USAGE_LIMIT "$IMAGE_ERR"

IMAGE_PICK_MODE=ok
IMAGE_MODE=limit
export IMAGE_PICK_MODE IMAGE_MODE
image_rc=0
image_run --dest "$WORK/image-output/generation-limit.jpg" --prompt portrait \
  --account main || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx GEMINI_USAGE_LIMIT "$IMAGE_ERR"

IMAGE_MODE=quota
export IMAGE_MODE
image_rc=0
image_run --dest "$WORK/image-output/image-quota.jpg" --prompt portrait \
  --account main || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx GEMINI_USAGE_LIMIT "$IMAGE_ERR"
assert grep -q 'reply with the single word QUOTA' "$IMAGE_PROMPT"
assert grep -qx 'print_timeout=180s' "$IMAGE_CALLS"
assert_fails grep -qiE 'RESOURCE_EXHAUSTED|quota exceeded|rate limit|usage limit' "$IMAGE_PROMPT"

IMAGE_MODE=rescue
IMAGE_RESCUE_FILE="$HOME/.gemini-profiles/rescue/.gemini/antigravity-cli/brain/conversation/rescued.jpg"
export IMAGE_PICK_MODE IMAGE_MODE IMAGE_RESCUE_FILE
assert image_run --dest "$WORK/image-output/rescued.jpg" --prompt landscape --account rescue
assert grep -qx rescued "$WORK/image-output/rescued.jpg"

IMAGE_MODE=reply
export IMAGE_MODE
: >"$IMAGE_MAGICK_CALLS"
assert image_run --dest "$WORK/image-output/converted.png" --prompt landscape --account main
assert grep -q "$IMAGE_REPLY $WORK/image-output/converted.png" "$IMAGE_MAGICK_CALLS"
assert grep -qx converted "$WORK/image-output/converted.png"

# main has no profile directory to delete, so `remove` hides it by marker alone: the real HOME
# keeps its Antigravity login, and every enumerator must behave as though main never existed. The
# marker path is llm-limits.sh's — the menubar's `--gemini-remove` writes exactly this file, and a
# spelling of geminib's own would make the two tools disagree about whether main is there.
MAIN_MARKER="$HOME/.llm-limits-gemini.json.removed"
assert test ! -e "$MAIN_MARKER"
: >"$AGY_CALLS"
: >"$ANNOUNCE_LOG"
remove_main_output=$(bash "$SCRIPT" remove main) || fail "remove main failed"
assert grep -qx 'geminib: removed main' <<<"$remove_main_output"
assert grep -qF "$MAIN_MARKER" <<<"$remove_main_output"
assert test -e "$MAIN_MARKER"
assert test ! -e "$HOME/.llm-limits-gemini/main.json.removed"
assert test -f "$HOME/.gemini/settings.json"
assert test -f "$HOME/.gemini/antigravity-cli/settings.json"
assert wait_announce ''
assert_fails bash "$SCRIPT" run main
assert_fails bash "$SCRIPT" profile main
assert_fails bash "$SCRIPT" main exec
assert test ! -s "$AGY_CALLS"
assert_fails bash "$SCRIPT" remove main
assert_fails bash "$SCRIPT" add main
assert_fails bash "$SCRIPT" enable main
assert_fails bash "$SCRIPT" disable main
main_list=$(bash "$SCRIPT" list) || fail "list after remove main failed"
assert_fails grep -q '^main:' <<<"$main_list"
main_status=$(bash "$SCRIPT" status) || fail "status after remove main failed"
assert_fails grep -q '^main:' <<<"$main_status"
main_names=$(gemini_profiles_dir="$HOME/.gemini-profiles" gemini_base_home="$HOME" \
  bash -c '. "'"$ROOT"'/share/gemini-accounts.sh" && gemini_account_names')
assert_fails grep -qx main <<<"$main_names"
printf 'worker=auto\n' >"$PIN_CONFIG"
assert_fails env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use main
assert_fails grep -q '^gemini_profile=' "$PIN_CONFIG"
# Deleting the marker is the whole undo.
rm -f "$MAIN_MARKER"
assert bash "$SCRIPT" run main
assert grep -qx "CALL home=$HOME argc=0" "$AGY_CALLS"

# main removable makes an EMPTY roster reachable for the first time, and macOS system bash (3.2 —
# what a launchd or Hammerspoon PATH resolves `#!/usr/bin/env bash` to) aborts on a bare
# "${pids[@]}" of an empty array under `set -u`.
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME/.gemini/config"
: >"$EMPTY_HOME/.llm-limits-gemini.json.removed"
empty_roster=$(HOME="$EMPTY_HOME" GEMINIB_PROFILES_DIR="$EMPTY_HOME/.gemini-profiles" \
  /bin/bash "$SCRIPT" list 2>&1) || fail "an empty Gemini roster took list down"
assert test -z "$empty_roster"
empty_roster_status=$(HOME="$EMPTY_HOME" GEMINIB_PROFILES_DIR="$EMPTY_HOME/.gemini-profiles" \
  /bin/bash "$SCRIPT" status 2>&1) || fail "an empty Gemini roster took status down"
assert test -z "$empty_roster_status"

echo "PASS: $asserts asserts; base and isolated HOME routing, worker-pool exclusion (own file beside the profiles, headless runs refused, interactive and pinned runs pass, the last member goes out too, visible in list/status), shared configuration and Playwright caches, a private MCP config per leg with every server forced disabled (main untouched, compliant files not rewritten), per-profile keychain kept unlockable behind a login.keychain-db symlink, parallel ordered list/status probes, one-step creation, strict launch names, exec delimiter stripping, override-aware login hints, persistent remove markers, a base profile removed by marker alone (hidden from list/status/pin/launch, the real HOME untouched, undone by deleting the marker), use pin set/show/clear/refusal parity, and one-image generation routing, refused unknown accounts, destination checks made before a generation is spent, prompt, rescue, and conversion"
