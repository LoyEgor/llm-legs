#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/codexb"
HELPER="$ROOT/codex-quota.py"
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
CODEX_CALLS="$WORK/codex-calls"
export HOME CODEX_CALLS
unset CODEX_HOME
mkdir -p "$HOME/.codex/skills" "$HOME/.codex/plugins" "$FAKE_BIN"
printf 'model = "fixture"\n' >"$HOME/.codex/config.toml"
printf 'fixture agents\n' >"$HOME/.codex/AGENTS.md"
printf 'skill\n' >"$HOME/.codex/skills/example"
printf 'plugin\n' >"$HOME/.codex/plugins/example"

cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
account=main
[ -z "${CODEX_HOME+x}" ] || account=$(basename "$CODEX_HOME")
{
  printf 'CALL account=%s home=%s argc=%s\n' "$account" "${CODEX_HOME-<unset>}" "$#"
  for argument in "$@"; do printf 'ARG=%q\n' "$argument"; done
} >>"$CODEX_CALLS"
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  if [ "$(cat "$HOME/auth-$account" 2>/dev/null)" = ok ]; then
    printf 'Logged in using ChatGPT\n'
    exit 0
  fi
  printf 'Not logged in\n'
  exit 1
fi
if [ "${1:-}" = app-server ]; then
  while IFS= read -r line; do
    case "$line" in
      *account/rateLimits/read*)
        if [ -r "$HOME/dead-$account" ]; then
          jq -cn --arg m "$(cat "$HOME/dead-$account")" \
            '{jsonrpc:"2.0",id:2,error:{code:-32603,message:$m}}'
        elif [ "$(cat "$HOME/auth-$account" 2>/dev/null)" != ok ]; then
          jq -cn '{jsonrpc:"2.0",id:2,error:{code:-32600,message:"codex account authentication required to read rate limits"}}'
        elif [ -r "$HOME/quota-$account.json" ]; then
          jq -cn --slurpfile quota "$HOME/quota-$account.json" \
            '$quota[0] as $q | {jsonrpc:"2.0",id:2,result:
              ({rateLimits:($q.rateLimits // $q)} +
               (if ($q.rateLimitResetCredits | type) == "object"
                then {rateLimitResetCredits:$q.rateLimitResetCredits} else {} end))}'
        else
          jq -cn --arg account "$account" \
            '{jsonrpc:"2.0",id:2,error:{code:-32000,message:("no quota for " + $account)}}'
        fi
        exit 0
        ;;
    esac
  done
fi
EOF
chmod +x "$FAKE_BIN/codex"
PATH="$FAKE_BIN:$PATH"
export PATH

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

printf 'ok\n' >"$HOME/auth-main"
add_output=$(bash "$SCRIPT" add alpha) || fail "add alpha failed"
assert wait_announce '--refresh-account codex/alpha'
assert grep -qx 'CODEX_HOME=~/.codex-profiles/alpha codex login' <<<"$add_output"
if grep -q -- --device-auth <<<"$add_output"; then fail "add still advertises the device-code flow"; fi
assert grep -qx 'alpha: Not logged in' <<<"$add_output"
assert test -d "$HOME/.codex-profiles/alpha"
for item in config.toml AGENTS.md skills plugins; do
  assert test -L "$HOME/.codex-profiles/alpha/$item"
  assert test "$(readlink "$HOME/.codex-profiles/alpha/$item")" = "$HOME/.codex/$item"
done

mkdir -p "$HOME/.codex-profiles/trap/config.toml"
printf 'keep\n' >"$HOME/.codex-profiles/trap/config.toml/value"
bash "$SCRIPT" list >/dev/null
assert test ! -L "$HOME/.codex-profiles/trap/config.toml"
assert grep -qx keep "$HOME/.codex-profiles/trap/config.toml/value"
assert_fails bash "$SCRIPT" add main >/dev/null 2>&1
assert_fails bash "$SCRIPT" add Bad >/dev/null 2>&1
assert_fails bash "$SCRIPT" add alpha >/dev/null 2>&1

bash "$SCRIPT" add beta >/dev/null || fail "add beta failed"
printf 'ok\n' >"$HOME/auth-alpha"
list_output=$(bash "$SCRIPT" list) || fail "list failed"
assert test "$(sed -n '1p' <<<"$list_output")" = 'main: Logged in using ChatGPT'
assert grep -qx 'alpha: Logged in using ChatGPT' <<<"$list_output"
assert grep -qx 'beta: Not logged in' <<<"$list_output"

now=$(date +%s)
future=$((now + 7200))
week=$((now + 172800))
past=$((now - 60))
printf '{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":2}}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":0}}\n' "$past" "$week" >"$HOME/quota-alpha.json"
printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-beta.json"
assert test "$(bash "$SCRIPT" pick)" = alpha

printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = alpha

printf '{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = main

printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = alpha

printf '{"primary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":%s},"secondary":null,"planType":"plus"}\n' "$week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = alpha

printf '{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"primary":null,"secondary":null,"planType":"plus"}\n' >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = alpha

printf '{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":2}}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":0}}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = alpha
printf '{"primary":{"usedPercent":60,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-beta.json"
assert test "$(bash "$SCRIPT" pick)" = alpha
printf '{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":0}}\n' "$future" "$week" >"$HOME/quota-alpha.json"
printf 'no\n' >"$HOME/auth-main"
printf 'no\n' >"$HOME/auth-alpha"
assert test "$(bash "$SCRIPT" pick)" = main
printf 'ok\n' >"$HOME/auth-main"
printf 'ok\n' >"$HOME/auth-alpha"

# --- worker pool: the same "don't burn this one" state claudeb has ---
# Output goes to a file rather than redirecting the assert itself: a redirected `assert` swallows
# its own FAIL line and the suite then dies silently with no output at all.
POOL_OUT="$WORK/pool.out"
cx() { bash "$SCRIPT" "$@" >"$POOL_OUT" 2>&1; }
# Exclusion speaks for automatic selection only, so `pick` must skip the account while a direct
# run still reaches it.
assert test "$(bash "$SCRIPT" pick)" = alpha
assert cx disable alpha
assert grep -qx alpha "$HOME/.codex-profiles/.codexb/disabled"
assert test "$(bash "$SCRIPT" pick)" = main
assert cx enable alpha
assert test "$(bash "$SCRIPT" pick)" = alpha
# The pool file lives beside the profiles and must never be read back as one.
assert cx list
assert_fails grep -q '^\.codexb:' "$POOL_OUT"
# Visible where the state is owned, so the menu is not the only place it can be seen.
assert cx disable alpha
assert cx list
assert grep -q 'alpha: .*(out of pool)' "$POOL_OUT"
assert_fails grep -q 'main: .*(out of pool)' "$POOL_OUT"
assert cx status
assert grep -q 'alpha: .*(out of pool) | 5H' "$POOL_OUT"
assert cx disable alpha
assert grep -q 'already disabled' "$POOL_OUT"
assert cx enable alpha
assert cx enable alpha
assert grep -q 'already enabled' "$POOL_OUT"
assert_fails cx disable ghost-account
assert_fails cx enable ghost-account
assert_fails cx disable
# An empty pool would leave `pick` nothing to answer and no way back except editing the file.
for pool_profile in "$HOME/.codex-profiles"/*/; do
  pool_profile=$(basename "$pool_profile")
  case "$pool_profile" in .*) continue ;; esac
  cx disable "$pool_profile" || true
done
assert_fails cx disable main
assert grep -q 'last enabled account' "$POOL_OUT"
assert test "$(bash "$SCRIPT" pick)" = main
# The last-resort fallback to `main` must not resurrect an account the user excluded by hand.
POOL_FILE="$HOME/.codex-profiles/.codexb/disabled"
cp "$POOL_FILE" "$WORK/pool-backup"
printf 'main\n' >>"$POOL_FILE"
assert_fails cx pick
assert grep -q 'no account in the worker pool is usable' "$POOL_OUT"
# A pool file that exists but cannot be read fails CLOSED: reading it as "no exclusions" would
# hand selection the very account the file exists to spare.
cp "$WORK/pool-backup" "$POOL_FILE"
chmod 000 "$POOL_FILE"
if [ -r "$POOL_FILE" ]; then
  printf 'SKIP: unreadable-pool case (running with read-everything privileges)\n'
else
  assert_fails cx pick
  assert grep -q 'cannot be read' "$POOL_OUT"
fi
chmod 600 "$POOL_FILE"
cp "$WORK/pool-backup" "$POOL_FILE"
# Rewriting a pool file we could not read would publish a file holding only the new change,
# silently dropping every exclusion already in it.
chmod 000 "$POOL_FILE"
if [ -r "$POOL_FILE" ]; then
  printf 'SKIP: unreadable-pool write case (running with read-everything privileges)\n'
else
  # `enable`, not `disable`: with the file unreadable every account already reads as excluded,
  # so only the un-exclude path reaches the write.
  assert_fails cx enable beta
  assert grep -q 'refusing to rewrite' "$POOL_OUT"
  chmod 600 "$POOL_FILE"
  assert test "$(cat "$POOL_FILE")" = "$(cat "$WORK/pool-backup")"
fi
chmod 600 "$POOL_FILE"
# Exclusion is not unreachability: a direct run must still reach an excluded account.
assert grep -qx alpha "$POOL_FILE"
: >"$CODEX_CALLS"
assert bash "$SCRIPT" alpha exec --pooled
assert grep -q 'CALL account=alpha' "$CODEX_CALLS"
# A pool entry must not outlive its account, or the last-member guard keeps counting a ghost
# and a future account created under that name is silently excluded.
bash "$SCRIPT" add poolghost >/dev/null || fail "add poolghost failed"
assert cx disable poolghost
assert grep -qx poolghost "$POOL_FILE"
assert cx remove poolghost
assert_fails grep -qx poolghost "$POOL_FILE"
for pool_profile in "$HOME/.codex-profiles"/*/; do
  pool_profile=$(basename "$pool_profile")
  case "$pool_profile" in .*) continue ;; esac
  cx enable "$pool_profile" || true
done
assert test "$(bash "$SCRIPT" pick)" = alpha

status_output=$(bash "$SCRIPT" status) || fail "status failed"
assert grep -Eq '^main: Logged in using ChatGPT \| 5H 10% reset .+ \| WEEKLY 50% reset .+$' <<<"$status_output"
assert grep -Eq '^alpha: Logged in using ChatGPT \| 5H 10% reset .+ \| WEEKLY 20% reset .+$' <<<"$status_output"
assert grep -Eq '^beta: Not logged in( \||$)' <<<"$status_output"

: >"$CODEX_CALLS"
CODEX_HOME=poison bash "$SCRIPT" run main --flag 'two words' '*' '' || fail "main run failed"
assert grep -qx 'CALL account=main home=<unset> argc=4' "$CODEX_CALLS"
assert grep -qx 'ARG=two\\ words' "$CODEX_CALLS"
assert grep -qx 'ARG=\\\*' "$CODEX_CALLS"
assert grep -qx "ARG=''" "$CODEX_CALLS"

: >"$CODEX_CALLS"
bash "$SCRIPT" alpha exec --json 'two words' || fail "profile shorthand failed"
assert grep -qx "CALL account=alpha home=$HOME/.codex-profiles/alpha argc=3" "$CODEX_CALLS"
assert test "$(sed -n '2p' "$CODEX_CALLS")" = 'ARG=exec'
assert test "$(sed -n '3p' "$CODEX_CALLS")" = 'ARG=--json'
assert test "$(sed -n '4p' "$CODEX_CALLS")" = 'ARG=two\ words'

# One-step profile: an unknown name is auto-created (mirrors claudeb profile) and codex launches.
: >"$CODEX_CALLS"
fresh_output=$(bash "$SCRIPT" profile fresh 2>&1) || fail "profile fresh failed"
assert test -d "$HOME/.codex-profiles/fresh"
assert grep -q "new profile 'fresh' created" <<<"$fresh_output"
assert wait_announce '--refresh-account codex/fresh'
assert grep -qx "CALL account=fresh home=$HOME/.codex-profiles/fresh argc=0" "$CODEX_CALLS"
for item in config.toml AGENTS.md skills plugins; do
  assert test -L "$HOME/.codex-profiles/fresh/$item"
done

: >"$CODEX_CALLS"
bash "$SCRIPT" run menulogin login >/dev/null 2>&1 || fail "menu login failed"
assert test -d "$HOME/.codex-profiles/menulogin"
assert grep -qx "CALL account=menulogin home=$HOME/.codex-profiles/menulogin argc=1" "$CODEX_CALLS"
assert grep -qx 'ARG=login' "$CODEX_CALLS"
assert grep -qF 'shellQuote(name) .. " login")' "$ROOT/hammerspoon/llm-limits.lua"
# Whole file minus Lua comments: a line-scoped grep would miss a flag spliced in via a variable.
if grep -v '^[[:space:]]*--' "$ROOT/hammerspoon/llm-limits.lua" | grep -q -- --device-auth; then
  fail "menu Codex login reverted to device-auth"
fi

# The flag itself stays a working manual fallback: codexb passes codex arguments through verbatim.
: >"$CODEX_CALLS"
bash "$SCRIPT" run devauth login --device-auth >/dev/null 2>&1 || fail "manual device-auth login failed"
assert grep -qx "CALL account=devauth home=$HOME/.codex-profiles/devauth argc=2" "$CODEX_CALLS"
assert grep -qx 'ARG=--device-auth' "$CODEX_CALLS"

# Relaunching an existing profile must not reprint the creation note.
: >"$CODEX_CALLS"
reopen_output=$(bash "$SCRIPT" p alpha 2>&1) || fail "reopen alpha failed"
if grep -q "new profile" <<<"$reopen_output"; then fail "reopen reprinted the created note"; fi
sleep 0.3
assert test "$(grep -cxF -- '--refresh-account codex/alpha' "$ANNOUNCE_LOG")" = 1

# Reserved words are rejected by BOTH the profile path and add, with parallel wording; no dir leaks.
for reserved in profile p run add remove list status pick help login; do
  assert_fails bash "$SCRIPT" profile "$reserved" </dev/null >/dev/null 2>&1
  assert_fails bash "$SCRIPT" add "$reserved" </dev/null >/dev/null 2>&1
done
assert test ! -d "$HOME/.codex-profiles/status"
reserved_err=$(bash "$SCRIPT" profile add </dev/null 2>&1); reserved_rc=$?
assert test "$reserved_rc" -eq 2
assert grep -qx "codexb: invalid profile name 'add'" <<<"$reserved_err"
# An invalid charset on creation is rejected before any dir is made.
assert_fails bash "$SCRIPT" profile Bad </dev/null >/dev/null 2>&1
assert test ! -d "$HOME/.codex-profiles/Bad"
assert_fails bash "$SCRIPT" add -h </dev/null >/dev/null 2>&1
assert_fails bash "$SCRIPT" profile -dash </dev/null >/dev/null 2>&1
assert test ! -e "$HOME/.codex-profiles/-h"
assert test ! -e "$HOME/.codex-profiles/-dash"

: >"$CODEX_CALLS"
missing_login_err=$(bash "$SCRIPT" run login </dev/null 2>&1); missing_login_rc=$?
assert test "$missing_login_rc" -eq 2
assert grep -qx "codexb: invalid profile name 'login'" <<<"$missing_login_err"
assert test ! -e "$HOME/.codex-profiles/login"
assert test ! -s "$CODEX_CALLS"

mkdir -p "$HOME/.codex-profiles/pick"
for route in profile p run; do
  : >"$CODEX_CALLS"
  bash "$SCRIPT" "$route" pick --reserved >/dev/null 2>&1 || fail "$route pick failed"
  assert grep -qx "CALL account=pick home=$HOME/.codex-profiles/pick argc=1" "$CODEX_CALLS"
  assert grep -qx 'ARG=--reserved' "$CODEX_CALLS"
done
: >"$CODEX_CALLS"
bash "$SCRIPT" pick exec --reserved >/dev/null 2>&1 || fail "pick exec failed"
assert grep -qx "CALL account=pick home=$HOME/.codex-profiles/pick argc=2" "$CODEX_CALLS"
assert test "$(sed -n '2p' "$CODEX_CALLS")" = 'ARG=exec'
assert test "$(sed -n '3p' "$CODEX_CALLS")" = 'ARG=--reserved'
assert bash "$SCRIPT" remove pick
assert test ! -e "$HOME/.codex-profiles/pick"
# Removal announces a passive collect (no args) so the menu row drops without a
# manual refresh.
assert wait_announce ''

# The bare `<name> exec` path never auto-creates: a typo'd account errors, makes no dir, execs nothing.
: >"$CODEX_CALLS"
exec_err=$(bash "$SCRIPT" wrok exec --json </dev/null 2>&1); exec_rc=$?
assert test "$exec_rc" -eq 2
assert grep -qx 'codexb: unknown account: wrok' <<<"$exec_err"
assert test ! -d "$HOME/.codex-profiles/wrok"
assert test ! -s "$CODEX_CALLS"

# `profile -h`/`--help` shows help (parity with claudeb) and creates nothing.
for flag in -h --help; do
  help_out=$(bash "$SCRIPT" profile "$flag" </dev/null) || fail "profile $flag failed"
  assert grep -q 'codexb profile <name>' <<<"$help_out"
  assert test ! -d "$HOME/.codex-profiles/$flag"
done

CACHE="$HOME/.llm-limits-codex.json"
printf 'ok\n' >"$HOME/auth-trap"
printf '{"primary":{"usedPercent":30,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-trap.json"
# codexb keeps its pool state in a dotted directory beside the accounts, and dotted names are
# reserved from being accounts for that reason: publishing one as an account tells the user to
# log in to a service directory.
mkdir -p "$HOME/.codex-profiles/.codexb" "$HOME/.codex-profiles/.junk"
CODEX_QUOTA_TIMEOUT=2 "$HELPER" --all-accounts >/dev/null || fail "all-account quota helper failed"
assert jq -e '([.accounts[].account] | index(".codexb")) == null' "$CACHE"
list_dots=$(bash "$SCRIPT" list) || fail "list with dotted dirs failed"
assert_fails grep -q '^\.codexb:' <<<"$list_dots"
assert_fails grep -q '^\.junk:' <<<"$list_dots"
status_dots=$(bash "$SCRIPT" status) || fail "status with dotted dirs failed"
assert_fails grep -q '^\.codexb:' <<<"$status_dots"
assert_fails grep -q '^\.junk:' <<<"$status_dots"
pick_dots=$(bash "$SCRIPT" pick) || fail "pick with dotted dirs failed"
assert test "$pick_dots" != ".codexb"
assert test "$pick_dots" != ".junk"
assert jq -e '.current == "main" and (.accounts | type) == "array" and
  ([.accounts[].account] | index("main") != null) and
  ([.accounts[].account] | index("alpha") != null) and
  .rateLimits.planType == "plus" and
  all(.accounts[]; has("account") and has("as_of") and
    (if .auth_needed == true then (has("five_hour") or has("weekly") | not)
     else has("plan_type") and has("five_hour") and has("weekly") end))' "$CACHE" >/dev/null
assert jq -e '.rateLimits.primary.usedPercent == 10 and
  ([.accounts[] | select(.account == "main")][0] | .five_hour.used_pct == 10 and .reset_credits == 2) and
  ([.accounts[] | select(.account == "alpha")][0].reset_credits == 0) and
  ([.accounts[] | select(.account == "trap")][0] | has("reset_credits") | not) and
  ([.accounts[] | select(.account == "beta")][0] |
    .auth_needed == true and (has("five_hour") or has("weekly") | not))' "$CACHE" >/dev/null
CODEX_QUOTA_TIMEOUT=2 "$HELPER" >/dev/null || fail "main quota helper failed"
assert jq -e '([.accounts[].account] | index("alpha") != null) and
  .rateLimits.primary.usedPercent == 10' "$CACHE" >/dev/null
profile_quota=$(CODEX_HOME="$HOME/.codex-profiles/alpha" CODEX_QUOTA_TIMEOUT=2 \
  "$HELPER" --no-cache) || fail "CODEX_HOME quota helper failed"
assert jq -e '.current == "alpha" and .rateLimits.primary.usedPercent == 10' <<<"$profile_quota" >/dev/null

printf 'no\n' >"$HOME/auth-main"
printf 'no\n' >"$HOME/auth-alpha"
printf 'no\n' >"$HOME/auth-trap"
CODEX_QUOTA_TIMEOUT=2 "$HELPER" --all-accounts >/dev/null 2>&1 || true
assert jq -e 'all(.accounts[]; .auth_needed == true and
  (has("five_hour") or has("weekly") or has("plan_type") | not))' "$CACHE" >/dev/null

# A live-but-invalidated token: `codex login status` still says "Logged in" locally, yet the
# rate-limits RPC 401s with token_invalidated. The helper must classify it auth-needed with a
# SHORT cause (never the raw RPC blob), and codexb list/status/pick must honor the marker over
# the lying local auth.json. Non-auth errors stay non-auth; a good probe clears the marker.
printf 'ok\n' >"$HOME/auth-main"
printf 'ok\n' >"$HOME/auth-alpha"
printf 'ok\n' >"$HOME/auth-beta"
blob='rateLimits/read failed: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; {"code": "token_invalidated", "message": "Your authentication token has been invalidated. Please try signing in again."}'
printf '%s\n' "$blob" >"$HOME/dead-beta"
CODEX_QUOTA_TIMEOUT=2 "$HELPER" --all-accounts >/dev/null 2>&1 || true
assert jq -e '[.accounts[] | select(.account == "beta")][0] |
  .auth_needed == true and .cause == "login needed: token invalidated" and
  (has("five_hour") or has("weekly") or has("error") | not)' "$CACHE" >/dev/null
assert test -z "$(jq -r '.. | strings | select(test("token_invalidated|Unauthorized|backend-api|wham/usage"))' "$CACHE")"
list_dead=$(bash "$SCRIPT" list) || fail "list (dead token) failed"
assert grep -qx 'beta: login needed' <<<"$list_dead"
assert grep -qx 'main: Logged in using ChatGPT' <<<"$list_dead"
status_dead=$(bash "$SCRIPT" status) || fail "status (dead token) failed"
assert grep -Eq '^beta: login needed( \||$)' <<<"$status_dead"
printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-main.json"
assert test "$(bash "$SCRIPT" pick)" != beta
# A transient NON-auth error (weather/network) must PRESERVE a definite auth-needed verdict:
# a 503 on the already-marked beta (while another account succeeds and triggers the merged
# write) does not clear its marker — only a genuine success does. status/pick keep honoring it.
printf 'rateLimits/read failed: {"code": -32000, "message": "503 Service Unavailable"}\n' >"$HOME/dead-beta"
CODEX_QUOTA_TIMEOUT=2 "$HELPER" --all-accounts >/dev/null 2>&1 || true
assert jq -e '[.accounts[] | select(.account == "beta")][0] |
  .auth_needed == true and .cause == "login needed: token invalidated"' "$CACHE" >/dev/null
assert grep -Eq '^beta: login needed( \||$)' <<<"$(bash "$SCRIPT" status)"
assert test "$(bash "$SCRIPT" pick)" != beta
# A fresh 503 on a never-marked account (alpha) must NOT be misclassified as auth-needed.
printf 'rateLimits/read failed: {"code": -32000, "message": "503 Service Unavailable"}\n' >"$HOME/dead-alpha"
CODEX_QUOTA_TIMEOUT=2 "$HELPER" --all-accounts >/dev/null 2>&1 || true
assert jq -e '[.accounts[] | select(.account == "alpha")][0] | .auth_needed != true' "$CACHE" >/dev/null
assert jq -e '[.accounts[] | select(.account == "beta")][0] | .auth_needed == true' "$CACHE" >/dev/null
# Recovery: only a genuinely successful probe of beta clears its marker.
rm -f "$HOME/dead-beta" "$HOME/dead-alpha"
printf '{"primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":5,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-beta.json"
CODEX_QUOTA_TIMEOUT=2 "$HELPER" --all-accounts >/dev/null 2>&1 || true
assert jq -e '[.accounts[] | select(.account == "beta")][0] |
  (.auth_needed | not) and .five_hour.used_pct == 5' "$CACHE" >/dev/null
assert grep -qx 'beta: Logged in using ChatGPT' <<<"$(bash "$SCRIPT" list)"

# Reset the mock to the fully-signed-out state the remove section below expects.
printf 'no\n' >"$HOME/auth-main"
printf 'no\n' >"$HOME/auth-alpha"
printf 'no\n' >"$HOME/auth-beta"

# remove: forgets the profile dir and prunes the codex cache entry; main is refused.
bash "$SCRIPT" add gone >/dev/null || fail "add gone failed"
assert test -d "$HOME/.codex-profiles/gone"
printf '{"current":"gone","accounts":[{"account":"gone"},{"account":"main"}]}\n' >"$CACHE"
assert bash "$SCRIPT" remove gone
assert test ! -e "$HOME/.codex-profiles/gone"
assert jq -e '([.accounts[].account] | index("gone") == null) and
  ([.accounts[].account] | index("main") != null) and .current == "main"' "$CACHE"
assert_fails bash "$SCRIPT" remove main
assert_fails bash "$SCRIPT" remove never-existed

# Path traversal: a name escaping the profiles dir is rejected before any rm -rf.
canary_dir="$HOME/codexb-traversal-canary"
mkdir -p "$canary_dir"
assert_fails bash "$SCRIPT" remove ../codexb-traversal-canary
assert_fails bash "$SCRIPT" remove ./x
assert_fails bash "$SCRIPT" remove a/b
assert test -d "$canary_dir"

bash "$SCRIPT" add livecx >/dev/null || fail "add livecx failed"
printf '{"tokens":{"access_token":"live","refresh_token":"r"}}\n' >"$HOME/.codex-profiles/livecx/auth.json"
assert_fails bash "$SCRIPT" remove livecx
assert test -d "$HOME/.codex-profiles/livecx"
assert bash "$SCRIPT" remove livecx --force
assert test ! -e "$HOME/.codex-profiles/livecx"

# An empty-token auth.json is not "alive": removable without --force.
bash "$SCRIPT" add deadcx >/dev/null || fail "add deadcx failed"
printf '{"tokens":{"access_token":"","refresh_token":""}}\n' >"$HOME/.codex-profiles/deadcx/auth.json"
assert bash "$SCRIPT" remove deadcx
assert test ! -e "$HOME/.codex-profiles/deadcx"

PIN_CONFIG="$WORK/worker-model-use"
printf 'worker=auto\nclaudeb_profile=claude-a\ngemini_profile=gemini-a\n' >"$PIN_CONFIG"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use main
assert grep -qx 'codex_profile=main' "$PIN_CONFIG"
assert test -f "$PIN_CONFIG.lock"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use alpha
assert grep -qx 'codex_profile=alpha' "$PIN_CONFIG"
assert test "$(grep -c '^codex_profile=' "$PIN_CONFIG")" = 1
assert grep -qx 'worker=auto' "$PIN_CONFIG"
assert grep -qx 'claudeb_profile=claude-a' "$PIN_CONFIG"
assert grep -qx 'gemini_profile=gemini-a' "$PIN_CONFIG"
pin_output=$(env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use)
assert grep -qx 'codexb: workers are pinned to alpha' <<<"$pin_output"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use --clear
assert_fails grep -q '^codex_profile=' "$PIN_CONFIG"
assert grep -qx 'worker=auto' "$PIN_CONFIG"
pin_rc=0
env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use missing >/dev/null 2>&1 || pin_rc=$?
assert test "$pin_rc" -eq 2
pin_rc=0
env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use ../alpha >/dev/null 2>&1 || pin_rc=$?
assert test "$pin_rc" -eq 2
assert_fails grep -q '^codex_profile=' "$PIN_CONFIG"
UNREADABLE_PIN="$WORK/worker-model-unreadable"
printf 'worker=auto\ncodex_profile=alpha\n' >"$UNREADABLE_PIN"
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
  assert grep -qx 'codex_profile=alpha' "$UNREADABLE_PIN"
fi
chmod 600 "$UNREADABLE_PIN"

echo "PASS: $asserts asserts; add and shared-link trap, worker-pool exclusion (pick skips it, direct run still reaches it, last member protected, visible in list/status), list/status, quota-aware authenticated pick with main-last priority, reset credits, auth-needed cache markers, dead-token classification (short cause, no raw RPC blob) with list/status/pick honoring the marker over lying local auth.json, a transient non-auth error preserving the definite auth verdict while fresh weather on a never-marked account stays non-auth, and marker recovery only on a genuinely good probe, exact run environments/arguments, one-step profile auto-create with shared links, browser-OAuth menu login passthrough with device-auth de-advertised everywhere yet still working manually, and missing-name guard, existing-profile relaunch stays quiet, creation-only reserved-name guards, leading-hyphen and charset rejection parity, multi-account cache compatibility, remove forgets profiles including reserved legacy names and prunes the cache entry (main refused), and use pin set/show/clear/refusal parity"
