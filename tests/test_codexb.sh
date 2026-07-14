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
        if [ "$(cat "$HOME/auth-$account" 2>/dev/null)" != ok ]; then
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

printf '{"primary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":%s},"secondary":null,"planType":"plus"}\n' "$week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = alpha

printf '{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"primary":null,"secondary":null,"planType":"plus"}\n' >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = main

printf '{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":2}}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":0}}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = alpha
printf '{"primary":{"usedPercent":60,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-beta.json"
assert test "$(bash "$SCRIPT" pick)" = main
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

echo "PASS: $asserts asserts; add and shared-link trap, list/status, quota-aware authenticated pick, reset credits, auth-needed cache markers, exact run environments/arguments, multi-account cache compatibility"
