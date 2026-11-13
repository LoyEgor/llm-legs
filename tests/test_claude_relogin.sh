#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/claude-relogin and its bin/llm-refresh trigger, on stubs only: no real login, Chrome, worker-run or claudeb, and
# the claudeb store is a CLAUDEB_DIR fixture.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/bin/claude-relogin"
WORK="$(mktemp -d)"
holders=()
cleanup() {
  local pid
  for pid in ${holders[@]+"${holders[@]}"}; do kill "$pid" 2>/dev/null; done
  [ ! -s "$WORK/stub/login.pid" ] || kill "$(cat "$WORK/stub/login.pid")" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "assert $asserts: expected [$1], got [$2]${3:+ ($3)}"; }

export HOME="$WORK/home" CLAUDEB_DIR="$WORK/claudeb" STUB="$WORK/stub"
export CLAUDE_RELOGIN_PROFILES_ROOT="$WORK/profiles" CLAUDE_RELOGIN_CLAUDE="$WORK/bin/claude"
export CLAUDE_RELOGIN_WORKER_RUN="$WORK/bin/worker-run" CLAUDE_RELOGIN_CLAUDEB="$WORK/bin/claudeb"
export CLAUDE_RELOGIN_BRIEF="$WORK/brief.md" CLAUDE_RELOGIN_URL_WAIT_S=10 CLAUDE_RELOGIN_LOGIN_WAIT_S=10
unset CLAUDE_RELOGIN_LOCK CLAUDE_RELOGIN_STATE CLAUDE_RELOGIN_COOLDOWN_S
mkdir -p "$HOME" "$CLAUDEB_DIR/limits" "$WORK/bin" "$STUB"
STATE="$CLAUDEB_DIR/claude-relogin.json"
JOURNAL="$CLAUDEB_DIR/token-attempts.jsonl"

# claude: `auth status` answers from $STUB/logged-<profile>; `auth login` hands its URL to $BROWSER, then waits for
# the callback the worker-run stub fakes and logs in as the email that callback carries.
cat >"$WORK/bin/claude" <<'EOF'
#!/usr/bin/env bash
profile=${CLAUDE_CONFIG_DIR##*/}
case "$1 $2" in
  'auth status')
    if [ -s "$STUB/logged-$profile" ]; then printf '{"loggedIn":true,"email":"%s"}\n' "$(cat "$STUB/logged-$profile")"
    else printf '{"loggedIn":false}\n'; fi ;;
  'auth logout') rm -f "$STUB/logged-$profile" ;;
  'auth login')
    printf '%s\n' "$$" >"$STUB/login.pid"
    printf '%s\n' "$*" >>"$STUB/login.args"
    "$BROWSER" 'https://claude.ai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=s'
    for _ in $(seq 1 300); do
      if [ -s "$STUB/callback" ]; then
        cat "$STUB/callback" >"$STUB/logged-$profile"
        echo 'Login successful.'
        exit 0
      fi
      sleep 0.1
    done
    exit 1 ;;
  *) exit 2 ;;
esac
EOF
# worker-run: the registry, the window and the Computer Use run, each as $STUB_RUN says.
cat >"$WORK/bin/worker-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB/worker-run.log"
case "$1 ${2:-}" in
  'browse --json') cat "$STUB/registry.json" ;;
  'browse --window') printf 'WINDOW: %s Profile 9\n' "$3" ;;
  'run auto')
    cp "$4" "$STUB/brief.seen"
    printf 'RUN: r1\n'
    case "${STUB_RUN:-ok}" in
      ok) printf '%s\n' "${STUB_CALLBACK_EMAIL:-alpha@example.com}" >"$STUB/callback"
          printf 'STATUS: done\nRESULT:\nclicked Authorize\nOUTCOME: COMPUTER_OK authorized=alpha@example.com\n' ;;
      wall) printf 'STATUS: done\nRESULT:\na password field\nOUTCOME: COMPUTER_UNAVAILABLE reason=password\n' ;;
      weather) printf 'OUTCOME: CODEX_USAGE_LIMIT\n'; exit 3 ;;
    esac ;;
esac
EOF
# claudeb: revive clears the flag the way the real usage merge does.
cat >"$WORK/bin/claudeb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB/claudeb.log"
if [ "$1" = revive ] && [ "${STUB_REVIVE_RC:-0}" = 0 ]; then
  jq 'del(.auth_needed)' "$CLAUDEB_DIR/limits/$2.json" >"$CLAUDEB_DIR/limits/$2.json.tmp" &&
    mv "$CLAUDEB_DIR/limits/$2.json.tmp" "$CLAUDEB_DIR/limits/$2.json"
fi
exit "${STUB_REVIVE_RC:-0}"
EOF
chmod +x "$WORK/bin/"*
cat >"$CLAUDE_RELOGIN_BRIEF" <<'EOF'
# fixture brief
```
COMPUTER: yes
EFFORT: low
<account> <email> <profile dir> <url file> <port>
```
EOF

reset() { # account... -> logged out, flagged, enrolled; no stamps, logs or lock
  local a
  rm -rf "$STUB" "$STATE" "$JOURNAL" "$CLAUDEB_DIR/claude-relogin.lock" "$CLAUDEB_DIR/limits"
  mkdir -p "$STUB" "$CLAUDEB_DIR/limits"
  printf '{}\n' >"$STUB/registry.json"
  for a in "$@"; do
    mkdir -p "$CLAUDE_RELOGIN_PROFILES_ROOT/$a"
    printf '{"auth_needed":true,"auth_cause":"no keychain credentials"}\n' >"$CLAUDEB_DIR/limits/$a.json"
    jq --arg a "$a" '. + {($a): {email: ($a + "@example.com"), chrome_profile: "Profile 9", status: "ok"}}' \
      "$STUB/registry.json" >"$STUB/r.tmp" && mv "$STUB/r.tmp" "$STUB/registry.json"
  done
}
relogin() { rc=0; out=$("$TOOL" "$@" 2>"$WORK/err") || rc=$?; }
journal_outcomes() { jq -r 'select(.kind == "relogin") | .outcome' "$JOURNAL" 2>/dev/null | paste -sd' ' -; }
runs() { cat "$STUB/worker-run.log" 2>/dev/null | grep -c '^run auto'; }
login_dead() { local pid; pid=$(cat "$STUB/login.pid" 2>/dev/null) && [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; }

# Success: the four steps in order, logged in as the registry email, revive called and the flag cleared.
reset alpha
relogin alpha
assert_eq 0 "$rc" "success exit: $out $(cat "$WORK/err")"
assert_eq 'RELOGIN: alpha logged in as alpha@example.com; revived' "$out"
assert_eq alpha@example.com "$(cat "$STUB/logged-alpha")" "claude auth status email"
assert_eq 'auth login --claudeai' "$(cat "$STUB/login.args")" "login runs with --claudeai and no --email"
assert_eq 'browse --json|browse --window|run auto' "$(cut -d' ' -f1-2 "$STUB/worker-run.log" | paste -sd'|' -)"
assert grep -qx 'browse --window alpha' "$STUB/worker-run.log"
assert grep -q -- '--brief .* --workdir ' "$STUB/worker-run.log"
assert_eq 'revive alpha' "$(cat "$STUB/claudeb.log")"
assert_eq false "$(jq '.auth_needed // false' "$CLAUDEB_DIR/limits/alpha.json")" "revive cleared login needed"
assert_eq success "$(journal_outcomes)"
assert_eq null "$(jq -c '.alpha // null' "$STATE")" "a success leaves no cool-down"
assert [ ! -e "$CLAUDEB_DIR/claude-relogin.lock" ]
# The brief: every placeholder filled, the URL behind the file and the callback port read off it.
assert grep -q 'alpha alpha@example.com Profile 9 .*/authorize-url 54545$' "$STUB/brief.seen"
assert grep -qx 'COMPUTER: yes' "$STUB/brief.seen"
assert_eq 0 "$(grep -c 'fixture brief' "$STUB/brief.seen")" "only the fenced brief is launched"

# Already logged in: refused before any login or run; the stale flag goes through revive.
reset alpha
printf 'alpha@example.com\n' >"$STUB/logged-alpha"
relogin alpha
assert_eq 3 "$rc"
assert_eq 'REASON: already-logged-in' "${out%% — *}"
assert [ ! -e "$STUB/login.pid" ]
assert_eq 0 "$(runs)"
assert_eq 'revive alpha' "$(cat "$STUB/claudeb.log")"
assert_eq already-logged-in "$(journal_outcomes)"

# No enrolled Chrome profile: refused, no login started; the heartbeat's stamp says so, the tool's cool-down ignores it.
reset alpha
printf '{}\n' >"$STUB/registry.json"
relogin alpha
assert_eq 4 "$rc"
assert_eq 'REASON: no-profile' "${out%% — *}"
assert [ ! -e "$STUB/login.pid" ]
assert_eq no-profile "$(jq -r '.alpha.verdict' "$STATE")"
assert_eq no-profile "$(journal_outcomes)"
( . "$ROOT/share/claude-relogin.sh"; claude_relogin_cooling alpha "$(date +%s)" any ) ||
  fail "a no-profile refusal must hold the heartbeat off for the cool-down"
! ( . "$ROOT/share/claude-relogin.sh"; claude_relogin_cooling alpha "$(date +%s)" attempt ) ||
  fail "a no-profile refusal must not count as a real attempt"
asserts=$((asserts + 2))

# A wall: the run stops, the waiting login dies, login needed stays, no revive; the attempt stamp refuses a second.
reset alpha
STUB_RUN=wall relogin alpha
assert_eq 8 "$rc" "wall exit: $out"
assert_eq 'REASON: failed:wall' "${out%% — *}"
assert login_dead
assert_eq true "$(jq '.auth_needed' "$CLAUDEB_DIR/limits/alpha.json")" "login needed stays after a failure"
assert [ ! -e "$STUB/claudeb.log" ]
assert_eq attempt "$(jq -r '.alpha.verdict' "$STATE")"
STUB_RUN=ok relogin alpha
assert_eq 6 "$rc" "cool-down exit: $out"
assert_eq 'REASON: cooldown' "${out%% — *}"
assert_eq 1 "$(runs)" "the cool-down started no second run"
assert_eq 'failed:wall cooldown' "$(journal_outcomes)"
# Past the cool-down the account is served again.
sleep 1
CLAUDE_RELOGIN_COOLDOWN_S=1 STUB_RUN=ok relogin alpha
assert_eq 0 "$rc" "after the cool-down: $out"

# Weather: no codex account for Computer Use leaves no attempt stamp (an older one comes back) and kills the login.
reset alpha
STUB_RUN=weather relogin alpha
assert_eq 7 "$rc" "weather exit: $out"
assert_eq 'REASON: weather' "${out%% — *}"
assert_eq null "$(jq -c '.alpha // null' "$STATE")" "weather left an attempt stamp"
assert login_dead
assert_eq weather "$(journal_outcomes)"
printf '{"alpha":{"at":1000,"verdict":"attempt"}}\n' >"$STATE"
STUB_RUN=weather relogin alpha
assert_eq '{"at":1000,"verdict":"attempt"}' "$(jq -c '.alpha' "$STATE")" "weather restores the earlier stamp"

# Another relogin live: the lock refuses, whatever the account.
reset alpha
sleep 30 & holder=$!; holders+=("$holder")
mkdir -p "$CLAUDEB_DIR/claude-relogin.lock" && printf '%s\n' "$holder" >"$CLAUDEB_DIR/claude-relogin.lock/pid"
relogin alpha
assert_eq 5 "$rc"
assert_eq 'REASON: busy' "${out%% — *}"
assert_eq "$holder" "$(cat "$CLAUDEB_DIR/claude-relogin.lock/pid")" "the refused run left the holder's lock"
# A dead holder's lock is no relogin.
printf '999999\n' >"$CLAUDEB_DIR/claude-relogin.lock/pid"
relogin alpha
assert_eq 0 "$rc" "a dead holder's lock blocked: $out"

# Wrong email after Authorize: logged out again, a failure.
reset alpha
STUB_CALLBACK_EMAIL=other@example.com relogin alpha
assert_eq 8 "$rc"
assert_eq 'REASON: failed:wrong-email' "${out%% — *}"
assert [ ! -e "$STUB/logged-alpha" ]

# Revive failing after a good login is its own code.
reset alpha
STUB_REVIVE_RC=5 relogin alpha
assert_eq 9 "$rc"
assert_eq 'REASON: revive-failed' "${out%% — *}"

# --dry-run: the refusals and the plan, nothing started, stamped or journaled.
reset alpha
relogin alpha --dry-run
assert_eq 0 "$rc"
assert_eq 'DRY-RUN: would log alpha in as alpha@example.com through Chrome profile Profile 9' "$out"
assert [ ! -e "$STUB/login.pid" ]
assert [ ! -e "$STATE" ]
assert [ ! -e "$JOURNAL" ]
relogin
assert_eq 2 "$rc"
relogin nobody
assert_eq 2 "$rc"

# The llm-refresh trigger: a Claude tick with a logged-out account starts claude-relogin once, detached; not while
# one is live; not for an account in its cool-down.
RELOGIN_STUB="$WORK/bin/relogin-stub"
cat >"$RELOGIN_STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "$*" "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" >>"$STUB/relogin.log"
EOF
cat >"$WORK/bin/collector" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$RELOGIN_STUB" "$WORK/bin/collector"
mkdir -p "$HOME/.claude"
printf 'codex_paused=on\ngemini_paused=on\ngrok_paused=on\nopencode_paused=on\n' >"$HOME/.claude/worker-model"
tick() { # store accounts...
  local now
  now=$(date +%s)
  jq -n --argjson now "$now" '{vendors: {claude: {accounts: [$ARGS.positional[] |
    {account: ., auth_needed: true, five_hour: {as_of: $now}, weekly: {as_of: $now}}]}}}' --args "$@" >"$WORK/store.json"
  rm -f "$WORK/refresh.state"
  env WORKER_PICK_CONFIG_FILE="$HOME/.claude/worker-model" LLM_REFRESH_COLLECTOR="$WORK/bin/collector" \
    LLM_LIMITS_CACHE="$WORK/store.json" LLM_REFRESH_STATE="$WORK/refresh.state" LLM_REFRESH_JOURNAL="$WORK/refresh.jsonl" \
    LLM_REFRESH_NOW="$now" SPEED_DOCTOR_DIR="$WORK/speed" WORKER_SLOTS_DIR="$WORK/slots" \
    LLM_LIMITS_REFRESH_CLAUDEB="$WORK/bin/claudeb" LLM_LIMITS_REFRESH_RELOGIN="$RELOGIN_STUB" \
    LLM_LIMITS_REFRESH_RELOGIN_LOG="$WORK/relogin-daemon.log" bash "$ROOT/bin/llm-refresh" run
}
started() { # n -> the stub log reaches n lines within 5 s
  for _ in $(seq 1 50); do [ "$(wc -l <"$STUB/relogin.log" 2>/dev/null || echo 0)" -ge "$1" ] && return 0; sleep 0.1; done
  return 1
}
reset alpha beta
tick alpha beta
assert started 1
sleep 0.5
assert_eq 1 "$(wc -l <"$STUB/relogin.log" | tr -d ' ')" "one relogin a tick"
assert_eq alpha "$(cut -d' ' -f1 "$STUB/relogin.log")"
# Detached: it leads a process group of its own, so launchd's end of the tick's job group never reaches it.
assert_eq "$(cut -d' ' -f2 "$STUB/relogin.log")" "$(cut -d' ' -f3 "$STUB/relogin.log")" "the relogin leads its own group"
assert_eq claude "$(jq -r '.vendor' "$WORK/refresh.jsonl" | paste -sd' ' -)" "the tick itself ran"
# Live: the lock's holder runs, so the next tick starts nothing.
sleep 30 & holder=$!; holders+=("$holder")
mkdir -p "$CLAUDEB_DIR/claude-relogin.lock" && printf '%s\n' "$holder" >"$CLAUDEB_DIR/claude-relogin.lock/pid"
tick alpha beta
sleep 1
assert_eq 1 "$(wc -l <"$STUB/relogin.log" | tr -d ' ')" "a relogin started while one was live"
# Cooling accounts are passed over: alpha's attempt stamp hands the tick to beta.
rm -rf "$CLAUDEB_DIR/claude-relogin.lock"
printf '{"alpha":{"at":%s,"verdict":"attempt"}}\n' "$(date +%s)" >"$STATE"
tick alpha beta
assert started 2
assert_eq beta "$(sed -n 2p "$STUB/relogin.log" | cut -d' ' -f1)"
# No logged-out account, no relogin.
reset alpha
printf '{}\n' >"$CLAUDEB_DIR/limits/alpha.json"
tick
sleep 1
assert [ ! -e "$STUB/relogin.log" ]
# A stubbed claudeb with no relogin named never reaches the real tool.
reset alpha
( unset LLM_LIMITS_REFRESH_RELOGIN
  now=$(date +%s)
  jq -n --argjson now "$now" '{vendors: {claude: {accounts: [{account: "alpha", auth_needed: true,
    five_hour: {as_of: $now}, weekly: {as_of: $now}}]}}}' >"$WORK/store.json"
  rm -f "$WORK/refresh.state"
  env WORKER_PICK_CONFIG_FILE="$HOME/.claude/worker-model" LLM_REFRESH_COLLECTOR="$WORK/bin/collector" \
    LLM_LIMITS_CACHE="$WORK/store.json" LLM_REFRESH_STATE="$WORK/refresh.state" LLM_REFRESH_JOURNAL="$WORK/refresh.jsonl" \
    LLM_REFRESH_NOW="$now" SPEED_DOCTOR_DIR="$WORK/speed" WORKER_SLOTS_DIR="$WORK/slots" \
    LLM_LIMITS_REFRESH_CLAUDEB="$WORK/bin/claudeb" LLM_LIMITS_REFRESH_RELOGIN_LOG="$WORK/relogin-daemon.log" \
    bash "$ROOT/bin/llm-refresh" run )
sleep 1
assert [ ! -e "$CLAUDEB_DIR/claude-relogin.lock" ]
assert [ ! -s "$WORK/relogin-daemon.log" ]

printf 'PASS: %s claude-relogin tests\n' "$asserts"
