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

printf 'ok\n' >"$HOME/auth-main"
add_output=$(bash "$SCRIPT" add alpha) || fail "add alpha failed"
assert grep -qx 'CODEX_HOME=~/.codex-profiles/alpha codex login' <<<"$add_output"
assert grep -qx 'CODEX_HOME=~/.codex-profiles/alpha codex login --device-auth' <<<"$add_output"
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
assert grep -qx "CALL account=fresh home=$HOME/.codex-profiles/fresh argc=0" "$CODEX_CALLS"
for item in config.toml AGENTS.md skills plugins; do
  assert test -L "$HOME/.codex-profiles/fresh/$item"
done

# The device-auth login the menu fires auto-creates the profile then passes the flags through.
: >"$CODEX_CALLS"
bash "$SCRIPT" run devauth login --device-auth >/dev/null 2>&1 || fail "device-auth login failed"
assert test -d "$HOME/.codex-profiles/devauth"
assert grep -qx "CALL account=devauth home=$HOME/.codex-profiles/devauth argc=2" "$CODEX_CALLS"
assert grep -qx 'ARG=login' "$CODEX_CALLS"
assert grep -qx 'ARG=--device-auth' "$CODEX_CALLS"

# Relaunching an existing profile must not reprint the creation note.
: >"$CODEX_CALLS"
reopen_output=$(bash "$SCRIPT" p alpha 2>&1) || fail "reopen alpha failed"
if grep -q "new profile" <<<"$reopen_output"; then fail "reopen reprinted the created note"; fi

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
missing_login_err=$(bash "$SCRIPT" run login --device-auth </dev/null 2>&1); missing_login_rc=$?
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
CODEX_QUOTA_TIMEOUT=2 "$HELPER" --all-accounts >/dev/null || fail "all-account quota helper failed"
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

echo "PASS: $asserts asserts; add and shared-link trap, list/status, quota-aware authenticated pick with main-last priority, reset credits, auth-needed cache markers, dead-token classification (short cause, no raw RPC blob) with list/status/pick honoring the marker over lying local auth.json, a transient non-auth error preserving the definite auth verdict while fresh weather on a never-marked account stays non-auth, and marker recovery only on a genuinely good probe, exact run environments/arguments, one-step profile auto-create with shared links, device-auth login passthrough and missing-name guard, existing-profile relaunch stays quiet, creation-only reserved-name guards, leading-hyphen and charset rejection parity, multi-account cache compatibility, remove forgets profiles including reserved legacy names and prunes the cache entry (main refused)"
