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

if ! grep -q '^worker_pool_shield_override()' "$ROOT/share/worker-pool.sh"; then
  BASH_ENV="$WORK/bash-env"
  export BASH_ENV
  cat >"$BASH_ENV" <<'EOF'
worker_pool_shield_override() {
  local vendor="$1" name="$2" dir marker epoch
  [ "$vendor" = codex ] || return 1
  dir="${CODEXB_PROFILES_DIR:-$HOME/.codex-profiles}/.codexb"
  marker="$dir/shielded/$name"
  [ -e "$marker" ] || return 0
  epoch=$(cat "$marker")
  mkdir -p "$dir/shield-override"
  printf '%s\n' "$epoch" >"$dir/shield-override/$name"
  rm -f "$marker"
}
EOF
fi

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
near_week=$((now + 86400))
far_week=$((now + 518400))
past=$((now - 60))
printf '{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":2}}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":0}}\n' "$past" "$week" >"$HOME/quota-alpha.json"
printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-beta.json"
assert test "$(bash "$SCRIPT" pick)" = alpha

printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$near_week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$far_week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = main

printf '{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = main

printf '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = main

printf '{"primary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":%s},"secondary":null,"planType":"plus"}\n' "$week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = alpha

printf '{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":90,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"}\n' "$future" "$week" >"$HOME/quota-main.json"
printf '{"primary":{"usedPercent":50,"windowDurationMins":300,"resetsAt":%s},"secondary":null,"planType":"plus"}\n' "$future" >"$HOME/quota-alpha.json"
assert test "$(bash "$SCRIPT" pick)" = alpha

credit_expiry=$((now + 950400))
credit_expiry_iso=$(date -u -r "$credit_expiry" +%Y-%m-%dT%H:%M:%SZ)
# The spent credit keeps an earlier `expiresAt`: only the ones still available may name the deadline.
printf '{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus"},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"RateLimitResetCredit_spent","status":"redeemed","expiresAt":%s},{"id":"RateLimitResetCredit_live","status":"available","expiresAt":%s}]}}\n' "$future" "$week" "$future" "$credit_expiry" >"$HOME/quota-main.json"
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

# --- worker pool: the same "don't burn this one" state claudeb has ---
# Output goes to a file rather than redirecting the assert itself: a redirected `assert` swallows
# its own FAIL line and the suite then dies silently with no output at all.
POOL_OUT="$WORK/pool.out"
cx() { bash "$SCRIPT" "$@" >"$POOL_OUT" 2>&1; }
# Exclusion walls the account off from `pick` AND from every headless run; an interactive
# session is the user and still reaches it.
assert test "$(bash "$SCRIPT" pick)" = alpha
assert cx disable alpha
assert grep -qx alpha "$HOME/.codex-profiles/.codexb/disabled"
assert test "$(bash "$SCRIPT" pick)" = main
# The wall: `exec` is a program calling codexb, and no naming of the account gets a worker in.
: >"$CODEX_CALLS"
assert_fails cx alpha exec -m fixture -
assert grep -q 'alpha is out of the worker pool' "$POOL_OUT"
assert_fails grep -q 'account=alpha' "$CODEX_CALLS"
# An interactive session is the user, never a worker, and is not gated at all.
assert cx profile alpha
assert grep -q 'account=alpha' "$CODEX_CALLS"
# The vendor pin is the one deliberate override.
PIN_CONFIG="$WORK/worker-model-pin"
printf 'codex_profile=alpha
' >"$PIN_CONFIG"
: >"$CODEX_CALLS"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" alpha exec -m fixture -
assert grep -q 'account=alpha' "$CODEX_CALLS"
SHIELD_DIR="$HOME/.codex-profiles/.codexb"
mkdir -p "$SHIELD_DIR/shielded"
printf '1777777777\n' >"$SHIELD_DIR/shielded/alpha"
assert cx enable alpha
assert test ! -e "$SHIELD_DIR/shielded/alpha"
assert grep -qx '1777777777' "$SHIELD_DIR/shield-override/alpha"
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
# --all is the menu's whole-vendor switch: every account this tool knows, main included, and
# idempotent — running it twice is not an error and changes nothing the second time.
codex_all_names=$({ printf 'main\n'
  for pool_profile in "$HOME/.codex-profiles"/*/; do
    pool_profile=$(basename "$pool_profile")
    case "$pool_profile" in .*) continue ;; esac
    printf '%s\n' "$pool_profile"
  done; } | LC_ALL=C sort)
assert cx disable --all
assert test "$(LC_ALL=C sort "$HOME/.codex-profiles/.codexb/disabled")" = "$codex_all_names"
assert cx disable --all
assert test "$(LC_ALL=C sort "$HOME/.codex-profiles/.codexb/disabled")" = "$codex_all_names"
assert cx enable --all
assert test ! -s "$HOME/.codex-profiles/.codexb/disabled"
assert cx enable --all
assert test ! -s "$HOME/.codex-profiles/.codexb/disabled"
# One account already in the requested state must not block the rest.
assert cx disable alpha
assert cx disable --all
assert test "$(LC_ALL=C sort "$HOME/.codex-profiles/.codexb/disabled")" = "$codex_all_names"
assert cx enable --all
# An empty pool is a legitimate state — it says no worker may run, not that nobody may work —
# so the last member goes out like any other.
for pool_profile in "$HOME/.codex-profiles"/*/; do
  pool_profile=$(basename "$pool_profile")
  case "$pool_profile" in .*) continue ;; esac
  cx disable "$pool_profile" || true
done
assert cx disable main
assert grep -qx main "$HOME/.codex-profiles/.codexb/disabled"
assert_fails cx pick
assert cx enable main
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
# Exclusion IS unreachability for a headless run, however the account is named.
assert grep -qx alpha "$POOL_FILE"
: >"$CODEX_CALLS"
assert_fails bash "$SCRIPT" alpha exec --pooled
assert_fails grep -q 'CALL account=alpha' "$CODEX_CALLS"
# A pool entry must not outlive its account, or a future account created under that name is
# silently excluded.
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

(
  export LLM_LIMITS_CACHE="$WORK/codex-tui.json" CODEXB_WORKER_PICK="$WORK/status-pick"
  export CODEXB_PROFILES_DIR="$HOME/.codex-profiles"
  # Enter on a status row opens Claude Code on that OpenAI account, never the Codex CLI.
  export CODEXB_CLAUDEGPT_CMD="$WORK/status-claudegpt" GPT_CALLS="$WORK/claudegpt-calls"
  printf '#!/usr/bin/env bash\nprintf "LAUNCH argc=%%s %%s\\n" "$#" "$*" >>"$GPT_CALLS"\n' >"$CODEXB_CLAUDEGPT_CMD"
  chmod +x "$CODEXB_CLAUDEGPT_CMD"
  # The Claude block shares the store; a codex picker that reads it would offer an Anthropic
  # account to a launcher that can only open an OpenAI one.
  jq -n --argjson now "$(date +%s)" '{vendors:{codex:{accounts:[
    {account:"alpha",five_hour:{used_pct:10,as_of:$now},weekly:{used_pct:20,as_of:$now}},
    {account:"beta",five_hour:{used_pct:30,as_of:$now},weekly:{used_pct:15,as_of:$now}},
    {account:"main",enabled:false,five_hour:{used_pct:90,as_of:$now}}]},
    claude:{accounts:[{account:"anthroponly",five_hour:{used_pct:5,as_of:$now},
      weekly:{used_pct:5,as_of:$now},fable:{used_pct:5,as_of:$now}}]}}}' >"$LLM_LIMITS_CACHE"
  printf '#!/usr/bin/env bash\n[ "$*" = "--account codex --role chat" ] || exit 2\n[ -z "${PICK_NONE:-}" ] || exit 3\nprintf beta\n' >"$CODEXB_WORKER_PICK"
  chmod +x "$CODEXB_WORKER_PICK"
  for spec in '0d beta' '1b5b410d alpha' '1b5b420d main' '1b5b431b5b440d beta' '71 none' '1b none'; do
    read -r keys expected <<<"$spec"
    : >"$CODEX_CALLS"
    : >"$GPT_CALLS"
    tty_out=$(python3 "$ROOT/tests/fixtures/account-status-pty.py" "$keys" "$SCRIPT") || fail "codexb TTY keys $keys failed"
    assert grep -qF $'\033[7m* beta' <<<"$tty_out"
    assert grep -qF '↑/↓ select  ⏎ launch  ←/→ sort  r refresh  q/Esc exit' <<<"$tty_out"
    assert_fails grep -qF FABLE <<<"$tty_out"
    assert_fails grep -qF anthroponly <<<"$tty_out"
    assert test ! -s "$CODEX_CALLS"
    if [ "$expected" = none ]; then assert test ! -s "$GPT_CALLS"
    else assert grep -qx "LAUNCH argc=4 p $expected --model astra" "$GPT_CALLS"; fi
  done
  : >"$CODEX_CALLS"
  : >"$GPT_CALLS"
  tty_out=$(PICK_NONE=1 python3 "$ROOT/tests/fixtures/account-status-pty.py" 0d "$SCRIPT") || fail "codexb TTY fallback failed"
  assert grep -qF $'\033[7m  alpha' <<<"$tty_out"
  assert grep -qx 'LAUNCH argc=4 p alpha --model astra' "$GPT_CALLS"
  assert test ! -s "$CODEX_CALLS"
  # No launcher is a refusal: falling back to `codex` would open the wrong tool on Enter.
  : >"$CODEX_CALLS"
  status_rc=0
  CODEXB_CLAUDEGPT_CMD="$WORK/absent-claudegpt" \
    python3 "$ROOT/tests/fixtures/account-status-pty.py" 0d "$SCRIPT" >"$WORK/no-launcher.out" 2>&1 || status_rc=$?
  assert test "$status_rc" = 2
  assert grep -qF 'claudegpt is not installed' "$WORK/no-launcher.out"
  assert test ! -s "$CODEX_CALLS"
  export LLM_LIMITS_CMD="$WORK/status-refresh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$LLM_LIMITS_CMD"
  chmod +x "$LLM_LIMITS_CMD"
  tty_out=$(python3 "$ROOT/tests/fixtures/account-status-pty.py" 7271 "$SCRIPT") || fail "codexb TTY refresh/quit failed"
  assert grep -qF '⟳ refreshing' <<<"$tty_out"
  assert test "$(bash "$SCRIPT" status)" = "$status_output"
) || exit 1

: >"$CODEX_CALLS"
CODEX_HOME=poison bash "$SCRIPT" run main --flag 'two words' '*' '' || fail "main run failed"
assert grep -qx 'CALL account=main home=<unset> argc=4' "$CODEX_CALLS"
assert grep -qx 'ARG=two\\ words' "$CODEX_CALLS"
assert grep -qx 'ARG=\\\*' "$CODEX_CALLS"
assert grep -qx "ARG=''" "$CODEX_CALLS"

: >"$CODEX_CALLS"
bash "$SCRIPT" alpha exec --json 'two words' || fail "profile shorthand failed"
assert grep -qx "CALL account=alpha home=$HOME/.codex-profiles/alpha argc=9" "$CODEX_CALLS"
assert test "$(sed -n '4p' "$CODEX_CALLS")" = 'ARG=exec'
assert test "$(sed -n '5p' "$CODEX_CALLS")" = 'ARG=--json'
assert test "$(sed -n '6p' "$CODEX_CALLS")" = 'ARG=two\ words'

assert test "$(sed -n '2p' "$CODEX_CALLS")" = 'ARG=-m'
assert test "$(sed -n '3p' "$CODEX_CALLS")" = 'ARG=gpt-6-astra'
assert test "$(sed -n '7p' "$CODEX_CALLS")" = 'ARG=--disable'
assert test "$(sed -n '8p' "$CODEX_CALLS")" = 'ARG=fast_mode'
assert test "$(sed -n '9p' "$CODEX_CALLS")" = 'ARG=--config'
assert test "$(sed -n '10p' "$CODEX_CALLS")" = 'ARG=service_tier=\"default\"'

: >"$CODEX_CALLS"
bash "$SCRIPT" profile alpha -- 'two words' || fail "terminated launch failed"
assert test "$(sed -n '4p' "$CODEX_CALLS")" = 'ARG=--disable'
assert test "$(sed -n '5p' "$CODEX_CALLS")" = 'ARG=fast_mode'
assert test "$(sed -n '7p' "$CODEX_CALLS")" = 'ARG=service_tier=\"default\"'
assert test "$(sed -n '8p' "$CODEX_CALLS")" = 'ARG=--'
assert test "$(sed -n '9p' "$CODEX_CALLS")" = 'ARG=two\ words'

for subcommand in mcp-server app-server completion cloud apply features help; do
  : >"$CODEX_CALLS"
  bash "$SCRIPT" profile alpha "$subcommand" || fail "$subcommand launch failed"
  assert_fails grep -qx 'ARG=fast_mode' "$CODEX_CALLS"
done

assert bash "$SCRIPT" fast-mode alpha on
: >"$CODEX_CALLS"
assert bash "$SCRIPT" profile alpha
assert grep -qx 'ARG=--disable' "$CODEX_CALLS"
assert grep -qx 'ARG=fast_mode' "$CODEX_CALLS"
assert grep -qx 'ARG=--config' "$CODEX_CALLS"
assert grep -Fqx 'ARG=service_tier=\"default\"' "$CODEX_CALLS"
FAST_TIER_PROFILES="$WORK/fast-tier-profiles"
mkdir -p "$FAST_TIER_PROFILES/alpha"
printf 'service_tier = "fast"\n' >"$FAST_TIER_PROFILES/alpha/config.toml"
fast_tier=$(CODEXB_PROFILES_DIR="$FAST_TIER_PROFILES" bash -c \
  '. "$1/share/codex-accounts.sh" && codex_fast_tier alpha' _ "$ROOT")
assert test "$fast_tier" = default
for model_flag in -m --model --model=gpt-5.6-sol; do
  : >"$CODEX_CALLS"
  if [ "$model_flag" = --model=gpt-5.6-sol ]; then
    bash "$SCRIPT" profile alpha "$model_flag" || fail "explicit model failed"
  else
    bash "$SCRIPT" profile alpha "$model_flag" gpt-5.6-sol || fail "explicit model failed"
  fi
  assert test "$(grep -Ec '^ARG=(-m|--model|--model=)' "$CODEX_CALLS")" -eq 1
  assert grep -q 'gpt-5.6-sol' "$CODEX_CALLS"
done
for command in login logout --version --help mcp; do
  : >"$CODEX_CALLS"
  bash "$SCRIPT" profile alpha "$command" || fail "$command passthrough failed"
  assert grep -qx "CALL account=alpha home=$HOME/.codex-profiles/alpha argc=1" "$CODEX_CALLS"
  assert grep -qx "ARG=$command" "$CODEX_CALLS"
done
: >"$CODEX_CALLS"
bash "$SCRIPT" profile alpha resume || fail "resume passthrough failed"
assert grep -qx "CALL account=alpha home=$HOME/.codex-profiles/alpha argc=5" "$CODEX_CALLS"
assert grep -qx 'ARG=resume' "$CODEX_CALLS"
assert grep -qx 'ARG=--disable' "$CODEX_CALLS"
assert grep -qx 'model = "fixture"' "$HOME/.codex/config.toml"

# One-step profile: an unknown name is auto-created (mirrors claudeb profile) and codex launches.
: >"$CODEX_CALLS"
fresh_output=$(bash "$SCRIPT" profile fresh 2>&1) || fail "profile fresh failed"
assert test -d "$HOME/.codex-profiles/fresh"
assert grep -q "new profile 'fresh' created" <<<"$fresh_output"
assert wait_announce '--refresh-account codex/fresh'
assert grep -qx "CALL account=fresh home=$HOME/.codex-profiles/fresh argc=6" "$CODEX_CALLS"
assert grep -qx 'ARG=-m' "$CODEX_CALLS"
assert grep -qx 'ARG=gpt-6-astra' "$CODEX_CALLS"
for item in config.toml AGENTS.md skills plugins; do
  assert test -L "$HOME/.codex-profiles/fresh/$item"
done

: >"$CODEX_CALLS"
bash "$SCRIPT" run menulogin login >/dev/null 2>&1 || fail "menu login failed"
assert test -d "$HOME/.codex-profiles/menulogin"
assert grep -qx "CALL account=menulogin home=$HOME/.codex-profiles/menulogin argc=1" "$CODEX_CALLS"
assert grep -qx 'ARG=login' "$CODEX_CALLS"
assert grep -qF 'shellQuote(name) .. " login")' "$ROOT/hammerspoon/llm-limits.lua"
# Codex's own resolver plus the shared Terminal helper, whole and minus Lua comments: a line-scoped
# grep would miss a flag spliced in via a variable, and a whole-file grep now reads Grok's resolver
# — where `--device-auth` is the only login flow there is — as Codex's.
codex_login_lua=$(awk '/^local function openLoginTerminal\(/,/^end$/' "$ROOT/hammerspoon/llm-limits.lua"
  awk '/^function M\.loginCodex\(/,/^end$/' "$ROOT/hammerspoon/llm-limits.lua")
assert grep -q 'openLoginTerminal("codexb run ' <<<"$codex_login_lua"
if grep -v '^[[:space:]]*--' <<<"$codex_login_lua" | grep -q -- --device-auth; then
  fail "menu Codex login reverted to device-auth"
fi
# The scoped read above cannot see a flag spliced in through a variable defined elsewhere in the
# module, so the whole file is read too: outside Grok's own login function, where the flag is the
# only flow there is, no live line may carry it.
device_auth_outside=$(awk '
  /^function M\.loginGrok\(/ { in_grok = 1 }
  in_grok { if ($0 == "end") in_grok = 0; next }
  /--device-auth/ && $0 !~ /^[[:space:]]*--[^-]/ { print FNR ": " $0 }
' "$ROOT/hammerspoon/llm-limits.lua")
[ -z "$device_auth_outside" ] || fail "a live --device-auth outside Grok login: $device_auth_outside"

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
  assert grep -qx "CALL account=pick home=$HOME/.codex-profiles/pick argc=7" "$CODEX_CALLS"
  assert grep -qx 'ARG=--reserved' "$CODEX_CALLS"
done
: >"$CODEX_CALLS"
bash "$SCRIPT" pick exec --reserved >/dev/null 2>&1 || fail "pick exec failed"
assert grep -qx "CALL account=pick home=$HOME/.codex-profiles/pick argc=8" "$CODEX_CALLS"
assert test "$(sed -n '4p' "$CODEX_CALLS")" = 'ARG=exec'
assert test "$(sed -n '5p' "$CODEX_CALLS")" = 'ARG=--reserved'
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
assert jq -e --arg expiry "$credit_expiry_iso" '.rateLimits.primary.usedPercent == 10 and
  ([.accounts[] | select(.account == "main")][0] | .five_hour.used_pct == 10 and .reset_credits == 2 and
    .reset_credits_expires_at == $expiry) and
  ([.accounts[] | select(.account == "alpha")][0] |
    .reset_credits == 0 and (has("reset_credits_expires_at") | not)) and
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

# remove: forgets the profile dir and prunes the codex cache entry. main is removable too, by
# marker rather than by deletion, and has its own section further down.
bash "$SCRIPT" add gone >/dev/null || fail "add gone failed"
assert test -d "$HOME/.codex-profiles/gone"
printf '{"current":"gone","accounts":[{"account":"gone"},{"account":"main"}]}\n' >"$CACHE"
assert bash "$SCRIPT" remove gone
assert test ! -e "$HOME/.codex-profiles/gone"
assert jq -e '([.accounts[].account] | index("gone") == null) and
  ([.accounts[].account] | index("main") != null) and .current == "main"' "$CACHE"
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

# main has no profile directory to delete, so `remove` hides it by marker alone: the real ~/.codex
# keeps its Codex login, and every enumerator must behave as though main never existed. The marker
# path is llm-limits.sh's — the menubar's `--codex-remove` writes exactly this file, and a spelling
# of codexb's own would make the two tools disagree about whether main is there.
MAIN_MARKER="$HOME/.llm-limits-codex.json.removed"
assert test ! -e "$MAIN_MARKER"
printf '{"current":"main","accounts":[{"account":"main"},{"account":"keeper"}]}\n' >"$CACHE"
: >"$CODEX_CALLS"
: >"$ANNOUNCE_LOG"
remove_main_output=$(bash "$SCRIPT" remove main) || fail "remove main failed"
assert grep -qx 'codexb: removed main' <<<"$remove_main_output"
assert grep -qF "$MAIN_MARKER" <<<"$remove_main_output"
assert test -e "$MAIN_MARKER"
assert test -f "$HOME/.codex/config.toml"
assert test -f "$HOME/.codex/AGENTS.md"
assert wait_announce ''
# The roster is what `.current` falls back to, so removing the account it named must land on the
# first one still there — never on a name no enumerator lists.
assert jq -e '([.accounts[].account] | index("main")) == null and .current == "keeper"' "$CACHE"
assert_fails bash "$SCRIPT" run main
assert_fails bash "$SCRIPT" profile main
assert_fails bash "$SCRIPT" main exec
assert test ! -s "$CODEX_CALLS"
assert_fails bash "$SCRIPT" remove main
assert_fails bash "$SCRIPT" add main
assert_fails bash "$SCRIPT" enable main
assert_fails bash "$SCRIPT" disable main
main_list=$(bash "$SCRIPT" list) || fail "list after remove main failed"
assert_fails grep -q '^main:' <<<"$main_list"
main_status=$(bash "$SCRIPT" status) || fail "status after remove main failed"
assert_fails grep -q '^main:' <<<"$main_status"
main_names=$(codex_base_home="$HOME" \
  bash -c '. "'"$ROOT"'/share/codex-accounts.sh" && codex_main_removed')
assert test -z "$main_names"
# `pick` answered main as the last resort; a removed main is no resort at all.
assert_fails bash "$SCRIPT" pick
REMOVED_PIN_CONFIG="$WORK/worker-model-removed-main"
printf 'worker=auto\n' >"$REMOVED_PIN_CONFIG"
assert_fails env WORKER_PICK_CONFIG_FILE="$REMOVED_PIN_CONFIG" bash "$SCRIPT" use main
assert_fails grep -q '^codex_profile=' "$REMOVED_PIN_CONFIG"
# Deleting the marker is the whole undo.
rm -f "$MAIN_MARKER"
assert grep -qx 'main: Not logged in' <<<"$(bash "$SCRIPT" list)"
assert test "$(bash "$SCRIPT" pick)" = main

PIN_CONFIG="$WORK/worker-model-use"
printf 'worker=auto\nclaudeb_profile=claude-a\ngemini_profile=gemini-a\n' >"$PIN_CONFIG"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use main
assert grep -qx 'codex_profile=main' "$PIN_CONFIG"
assert test -f "$PIN_CONFIG.lock"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use alpha
assert grep -qx 'codex_profile=main,alpha' "$PIN_CONFIG"
assert test "$(grep -c '^codex_profile=' "$PIN_CONFIG")" = 1
assert grep -qx 'worker=auto' "$PIN_CONFIG"
assert grep -qx 'claudeb_profile=claude-a' "$PIN_CONFIG"
assert grep -qx 'gemini_profile=gemini-a' "$PIN_CONFIG"
pin_output=$(env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use)
assert grep -qx 'codexb: workers are pinned to main,alpha' <<<"$pin_output"
assert env WORKER_PICK_CONFIG_FILE="$PIN_CONFIG" bash "$SCRIPT" use --unpin alpha
assert grep -qx 'codex_profile=main' "$PIN_CONFIG"
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

IMAGE_SCRIPT="$ROOT/bin/codex-image"
IMAGE_BIN="$WORK/image-bin"
IMAGE_CALLS="$WORK/image-calls"
IMAGE_PROMPT="$WORK/image-prompt"
IMAGE_PICK_CALLS="$WORK/image-pick-calls"
IMAGE_MAGICK_CALLS="$WORK/image-magick-calls"
export IMAGE_CALLS IMAGE_PROMPT IMAGE_PICK_CALLS IMAGE_MAGICK_CALLS
IMAGE_TMPDIR="$WORK/image-tmp"
IMAGE_CLAIMS="$WORK/image-claims"
mkdir -p "$IMAGE_BIN" "$WORK/image-output" "$WORK/image-profiles" "$IMAGE_TMPDIR" "$HOME/.claude" "$IMAGE_CLAIMS"
for image_account in explicit picked pinacct rescue; do
  mkdir -p "$WORK/image-profiles/$image_account"
done
: >"$IMAGE_PICK_CALLS"
: >"$IMAGE_MAGICK_CALLS"

cat >"$IMAGE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
# The caps check asks the live CLI for its version, and it must not be mistaken for a generation:
# recorded in IMAGE_CALLS it would answer the argv assertions below, and falling through to the
# generating branch it would block on a stdin nobody is writing.
if [ "${1-}" = --version ]; then
  printf 'codex-cli %s\n' "${IMAGE_CAPS_VERSION:-0.0.0}"
  exit 0
fi
account=main
[ -z "${CODEX_HOME+x}" ] || account=$(basename "$CODEX_HOME")
printf 'account=%s home=%s\n' "$account" "${CODEX_HOME-<unset>}" >>"$IMAGE_CALLS"
for argument in "$@"; do printf 'ARG=%q\n' "$argument" >>"$IMAGE_CALLS"; done
prompt=$(cat)
printf '%s' "$prompt" >"$IMAGE_PROMPT"
previous=''
output=''
for argument in "$@"; do
  if [ "$previous" = -o ]; then output=$argument; fi
  previous=$argument
done
case "${IMAGE_MODE:-reply}" in
  limit)
    printf 'Error: hit your usage limit\n' >&2
    exit 1
    ;;
  hang)
    exec sleep 30
    ;;
  rescue)
    if [ "$account" = main ]; then
      rescue_dir="$HOME/.codex/generated_images"
    else
      rescue_dir="$CODEX_HOME/generated_images"
    fi
    mkdir -p "$rescue_dir"
    printf 'rescued\n' >"$rescue_dir/rescued.jpg"
    printf 'status\n/nonexistent/generated.jpg\n' >"$output"
    ;;
  *)
    requested=$(printf '%s\n' "$prompt" | sed -n 's/^Copy the final image to \([^ ]*\) and reply.*/\1/p')
    printf 'generated:%s\n' "$account" >"$requested"
    printf 'status\n%s\n' "$requested" >"$output"
    ;;
esac
EOF
chmod +x "$IMAGE_BIN/codex"

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
  # No alpha channel, which is what the built-in tool answers whenever it cannot honour the
  # transparency request — the branch the chroma assertions below are about.
  'identify -format %A '*) printf 'Undefined'; exit 0 ;;
  *-format*info:) printf 'srgb(7,246,5)'; exit 0 ;;
esac
for output in "$@"; do :; done
output=${output#PNG:}
printf 'converted\n' >"$output"
EOF
chmod +x "$IMAGE_BIN/magick"

cat >"$IMAGE_BIN/sips" <<'EOF'
#!/usr/bin/env bash
# Bytes, not names: the default answers for a file that really is what it is called, and
# IMAGE_SIPS_FORMAT is the mislabelled answer the generator sometimes hands back.
for target in "$@"; do :; done
format=${IMAGE_SIPS_FORMAT:-}
if [ -z "$format" ]; then
  case "$target" in *.png) format=png ;; *) format=jpeg ;; esac
fi
printf '  pixelWidth: 1024\n  pixelHeight: 768\n  format: %s\n' "$format"
EOF
chmod +x "$IMAGE_BIN/sips"

IMAGE_PATH="$IMAGE_BIN:/usr/bin:/bin"
IMAGE_OUT="$WORK/image.out"
IMAGE_ERR="$WORK/image.err"
image_run() {
  env PATH="$IMAGE_PATH" TMPDIR="$IMAGE_TMPDIR" CODEX_IMAGE_CODEX="$IMAGE_BIN/codex" \
    CODEX_PROFILES_DIR="$WORK/image-profiles" IMAGE_MODE="${IMAGE_MODE:-reply}" \
    IMAGE_PICK_MODE="${IMAGE_PICK_MODE:-ok}" IMAGE_PICK_ACCOUNT="${IMAGE_PICK_ACCOUNT:-picked}" \
    WORKER_PICK_CONFIG_FILE="$HOME/.claude/worker-model" WORKER_CLAIMS_DIR="$IMAGE_CLAIMS" \
    bash "$IMAGE_SCRIPT" "$@" >"$IMAGE_OUT" 2>"$IMAGE_ERR"
}

image_rc=0
image_run --dest relative.jpg --prompt badge || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q '^usage: codex-image ' "$IMAGE_ERR"
image_rc=0
image_run --dest "$WORK/image-output/bad.jpg" --prompt badge --size 1024 || image_rc=$?
assert test "$image_rc" -eq 2
image_rc=0
image_run --dest "$WORK/image-output/bad.jpg" --prompt badge --transparent || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q 'requires a .png destination' "$IMAGE_ERR"

printf 'reference\n' >"$WORK/reference.jpg"
# One over the cap the manifest states, never a literal of this suite's own: the imagegen tool
# refuses the call itself, so the whole generation would be spent to be told so.
IMAGE_REF_MAX=$(jq -r '.refs.max' "$ROOT/share/image-caps/codex.json")
IMAGE_CAPS_VERSION=$(jq -r '.cli.version' "$ROOT/share/image-caps/codex.json")
export IMAGE_CAPS_VERSION
image_refs=()
for image_ref_index in $(seq 1 $((IMAGE_REF_MAX + 1))); do
  image_refs+=(--ref "$WORK/reference.jpg")
done
image_rc=0
image_run --dest "$WORK/image-output/refs.jpg" --prompt badge "${image_refs[@]}" || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q "references exceed the $IMAGE_REF_MAX" "$IMAGE_ERR"
: >"$IMAGE_CALLS"
: >"$IMAGE_PICK_CALLS"
assert image_run --dest "$WORK/image-output/explicit.jpg" --prompt 'simple badge' \
  --size 1536x1024 --ref "$WORK/reference.jpg" --account explicit
assert grep -qx "account=explicit home=$WORK/image-profiles/explicit" "$IMAGE_CALLS"
assert grep -qx 'ARG=exec' "$IMAGE_CALLS"
assert grep -qx 'ARG=--color' "$IMAGE_CALLS"
assert grep -qx 'ARG=never' "$IMAGE_CALLS"
assert grep -qx 'ARG=--skip-git-repo-check' "$IMAGE_CALLS"
assert grep -qx "ARG=-" "$IMAGE_CALLS"
assert_fails grep -qx 'ARG=-m' "$IMAGE_CALLS"
assert test ! -s "$IMAGE_PICK_CALLS"
assert grep -q 'built-in image_gen tool' "$IMAGE_PROMPT"
assert grep -q 'exact size 1536x1024' "$IMAGE_PROMPT"
assert_fails grep -q 'Use low quality' "$IMAGE_PROMPT"
assert grep -q -- "- $WORK/reference.jpg" "$IMAGE_PROMPT"
assert grep -qx 'generated:explicit' "$WORK/image-output/explicit.jpg"
assert grep -qx 'account=explicit' "$IMAGE_OUT"

# An answer already in the destination's own format is delivered byte for byte, png included: the
# generator is told to save under that extension, and re-encoding a matching answer changes pixels
# nobody asked to change. Same rule in gemini-image and grok-image.
: >"$IMAGE_MAGICK_CALLS"
assert image_run --dest "$WORK/image-output/asis.png" --prompt 'simple badge' --account explicit
assert grep -qx 'generated:explicit' "$WORK/image-output/asis.png"
assert test ! -s "$IMAGE_MAGICK_CALLS"

# The generator names its answer after the destination, so a JPEG saved as `.png` matches by name
# and only its bytes say otherwise: copied verbatim it lands as a `.png` that is not one.
: >"$IMAGE_MAGICK_CALLS"
IMAGE_SIPS_FORMAT=jpeg
export IMAGE_SIPS_FORMAT
assert image_run --dest "$WORK/image-output/mislabelled.png" --prompt 'simple badge' --account explicit
assert grep -q "$WORK/image-output/mislabelled.png" "$IMAGE_MAGICK_CALLS"
unset IMAGE_SIPS_FORMAT

: >"$IMAGE_MAGICK_CALLS"
assert image_run --dest "$WORK/image-output/alpha.png" \
  --prompt 'transparent badge with transparency effects' \
  --transparent --account explicit
assert grep -q '#00FF00' "$IMAGE_PROMPT"
assert grep -q 'transparency effects' "$IMAGE_PROMPT"
# Unlike the chroma-only legs, this one leaves the caller's wording alone: the built-in tool can
# return real alpha, and the word names the very thing it is being asked for. The green is the
# ORDERED fallback for the answer that comes back opaque anyway, which is this run.
assert grep -Eqi '(^|[^[:alnum:]_])transparent([^[:alnum:]_]|$)' "$IMAGE_PROMPT"
assert grep -q 'genuinely transparent background' "$IMAGE_PROMPT"
assert grep -qF -- "-format %[pixel:p{2,2}] info:" "$IMAGE_MAGICK_CALLS"
assert grep -q -- "-alpha extract -morphology EdgeIn Octagon:2 .*/edge.png" "$IMAGE_MAGICK_CALLS"
assert grep -qF -- "-channel G -fx min(g,max(r,b)) +channel" "$IMAGE_MAGICK_CALLS"
assert grep -q -- "despilled.png .*/edge.png -composite PNG:$WORK/image-output/alpha.png" "$IMAGE_MAGICK_CALLS"

IMAGE_PICK_MODE=ok
IMAGE_PICK_ACCOUNT=ghostpick
export IMAGE_PICK_MODE IMAGE_PICK_ACCOUNT
: >"$IMAGE_CALLS"
: >"$IMAGE_PICK_CALLS"
image_rc=0
image_run --dest "$WORK/image-output/ghost.jpg" --prompt landscape || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'account directory does not exist' "$IMAGE_ERR"
assert test ! -e "$IMAGE_CLAIMS/codex/ghostpick"
assert test ! -s "$IMAGE_CALLS"

: >"$IMAGE_CALLS"
: >"$IMAGE_PICK_CALLS"
IMAGE_PICK_MODE=ok
IMAGE_PICK_ACCOUNT=picked
export IMAGE_PICK_MODE IMAGE_PICK_ACCOUNT
assert image_run --dest "$WORK/image-output/picked.jpg" --prompt landscape
assert grep -qx -- '--account codex --role image' "$IMAGE_PICK_CALLS"
assert_fails grep -q -- '--claim' "$IMAGE_PICK_CALLS"
assert test -e "$IMAGE_CLAIMS/codex/picked"
assert grep -qx "account=picked home=$WORK/image-profiles/picked" "$IMAGE_CALLS"
assert grep -q 'Use low quality' "$IMAGE_PROMPT"

# codex-image runs codex headless past codexb, so the pool has to stop it there too — and the pin
# is the one thing that gets it through.
IMAGE_POOL_DIR="$HOME/.codex-profiles/.codexb"
mkdir -p "$IMAGE_POOL_DIR"
printf 'explicit\n' >"$IMAGE_POOL_DIR/disabled"
image_rc=0
image_run --dest "$WORK/image-output/walled.jpg" --prompt landscape --account explicit || image_rc=$?
assert test "$image_rc" -eq 4
assert grep -q 'codex: explicit is out of the worker pool' "$IMAGE_ERR"
assert test ! -e "$WORK/image-output/walled.jpg"
printf 'codex_profile=explicit\n' >"$HOME/.claude/worker-model"
assert image_run --dest "$WORK/image-output/pinned-through.jpg" --prompt landscape --account explicit
assert grep -qx 'generated:explicit' "$WORK/image-output/pinned-through.jpg"
rm -f "$IMAGE_POOL_DIR/disabled"

printf 'codex_profile=pinacct\n' >"$HOME/.claude/worker-model"
IMAGE_PICK_MODE=fail
export IMAGE_PICK_MODE
assert image_run --dest "$WORK/image-output/pin.jpg" --prompt portrait
assert grep -qx 'account=pinacct' "$IMAGE_OUT"
assert grep -q 'falling back to account pinacct' "$IMAGE_ERR"

printf 'worker=codex\n' >"$HOME/.claude/worker-model"
: >"$IMAGE_CALLS"
assert image_run --dest "$WORK/image-output/main.jpg" --prompt portrait
assert grep -qx 'account=main home=<unset>' "$IMAGE_CALLS"
assert grep -qx 'account=main' "$IMAGE_OUT"
assert grep -q 'falling back to account main' "$IMAGE_ERR"

IMAGE_PICK_MODE=limit
export IMAGE_PICK_MODE
image_rc=0
image_run --dest "$WORK/image-output/limit.jpg" --prompt portrait || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx CODEX_USAGE_LIMIT "$IMAGE_ERR"

IMAGE_PICK_MODE=ok
IMAGE_MODE=rescue
export IMAGE_PICK_MODE IMAGE_MODE
assert image_run --dest "$WORK/image-output/rescued.jpg" --prompt landscape --account rescue
assert grep -qx rescued "$WORK/image-output/rescued.jpg"

IMAGE_MODE=reply
export IMAGE_MODE
: >"$IMAGE_CALLS"
assert image_run --dest "$WORK/image-output/stdout.jpg" --prompt landscape --account main
assert grep -qx 'generated:main' "$WORK/image-output/stdout.jpg"
assert grep -qx "dest=$WORK/image-output/stdout.jpg" "$IMAGE_OUT"
assert grep -qx 'size=1024x768' "$IMAGE_OUT"
assert grep -qx 'format=jpeg' "$IMAGE_OUT"

stale_lock="$IMAGE_TMPDIR/codex-image.main.lock"
mkdir "$stale_lock"
touch -A -2100 "$stale_lock"
assert image_run --dest "$WORK/image-output/stale-lock.jpg" --prompt landscape --account main
assert test ! -e "$stale_lock"

IMAGE_MODE=limit
export IMAGE_MODE
image_rc=0
image_run --dest "$WORK/image-output/cli-limit.jpg" --prompt landscape --account main || image_rc=$?
assert test "$image_rc" -eq 3
assert grep -qx CODEX_USAGE_LIMIT "$IMAGE_ERR"

IMAGE_MODE=reply
export IMAGE_MODE
image_rc=0
image_run --dest "$WORK/image-output/noext" --prompt badge || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q '^usage: codex-image ' "$IMAGE_ERR"
# A bare trailing dot is that same nameless format, and it reads as an extension to a pattern.
image_rc=0
image_run --dest "$WORK/image-output/trailing." --prompt badge || image_rc=$?
assert test "$image_rc" -eq 2
assert grep -q '^usage: codex-image ' "$IMAGE_ERR"

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

IMAGE_MODE=hang
export IMAGE_MODE
image_rc=0
CODEX_IMAGE_DEADLINE=1 image_run --dest "$WORK/image-output/hang.jpg" --prompt landscape --account main || image_rc=$?
assert test "$image_rc" -eq 1
assert grep -q 'exceeded 1s deadline' "$IMAGE_ERR"
assert test ! -e "$IMAGE_TMPDIR/codex-image.main.lock"

IMAGE_MODE=reply
export IMAGE_MODE
assert env CODEX_IMAGE_DEADLINE=garbage PATH="$IMAGE_PATH" TMPDIR="$IMAGE_TMPDIR" \
  CODEX_IMAGE_CODEX="$IMAGE_BIN/codex" CODEX_PROFILES_DIR="$WORK/image-profiles" \
  IMAGE_MODE=reply IMAGE_PICK_MODE=ok IMAGE_PICK_ACCOUNT=picked \
  WORKER_PICK_CONFIG_FILE="$HOME/.claude/worker-model" \
  bash "$IMAGE_SCRIPT" --dest "$WORK/image-output/garbage-deadline.jpg" \
  --prompt landscape --account main >"$IMAGE_OUT" 2>"$IMAGE_ERR"
assert grep -qx 'account=main' "$IMAGE_OUT"

echo "PASS: $asserts asserts; add and shared-link trap, worker-pool exclusion and shield override (pick skips it, headless runs are refused however named, interactive and pinned runs pass, the last member goes out too, visible in list/status), list/status, quota-aware authenticated pick by descending daily budget, reset credits, auth-needed cache markers, dead-token classification (short cause, no raw RPC blob) with list/status/pick honoring the marker over lying local auth.json, a transient non-auth error preserving the definite auth verdict while fresh weather on a never-marked account stays non-auth, and marker recovery only on a genuinely good probe, exact run environments/arguments, one-step profile auto-create with shared links, browser-OAuth menu login passthrough with device-auth de-advertised everywhere yet still working manually, and missing-name guard, existing-profile relaunch stays quiet, creation-only reserved-name guards, leading-hyphen and charset rejection parity, multi-account cache compatibility, remove forgets profiles including reserved legacy names and prunes the cache entry, the base account removed by marker alone (hidden from list/status/pin/pick/launch, the real ~/.codex untouched, the cache's current falling to the first account left, undone by deleting the marker), use pin set/show/clear/refusal parity, and Codex image generation routing with claimed automatic picks, prompt, account environments, rescue, generation deadline with garbage-value fallback, destination checks made before a generation is spent, and limits"
