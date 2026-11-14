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
  [ ! -s "$WORK/node/stub/login.pid" ] || kill "$(cat "$WORK/node/stub/login.pid")" 2>/dev/null
  for pid in "$WORK"/stub/forward-*.pid; do [ ! -s "$pid" ] || kill "$(cat "$pid")" 2>/dev/null; done
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

# claude: `auth status` answers from $STUB/logged-<profile>, exiting 1 when logged out as the real CLI does;
# `auth login` hands its URL to $BROWSER, then waits for the callback the worker-run stub fakes and logs in as the
# email that callback carries.
cat >"$WORK/bin/claude" <<'EOF'
#!/usr/bin/env bash
profile=${CLAUDE_CONFIG_DIR##*/}
case "$1 $2" in
  'auth status')
    if [ -s "$STUB/logged-$profile" ]; then printf '{"loggedIn":true,"email":"%s"}\n' "$(cat "$STUB/logged-$profile")"
    else printf '{"loggedIn":false}\n'; exit 1; fi ;;
  'auth logout') rm -f "$STUB/logged-$profile" ;;
  'auth login')
    printf '%s\n' "$$" >"$STUB/login.pid"
    printf '%s\n' "$*" >>"$STUB/login.args"
    "$BROWSER" "https://claude.ai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A${STUB_PORT:-54545}%2Fcallback&state=s"
    for _ in $(seq 1 300); do
      if [ -s "${STUB_CALLBACK:-$STUB/callback}" ]; then
        cat "${STUB_CALLBACK:-$STUB/callback}" >"$STUB/logged-$profile"
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
      refused) printf 'worker-run: `worker-run run` runs from the chat that owns the run, never inside a headless worker. Nothing was launched and no account was spent.\n' >&2; exit 4 ;;
    esac ;;
esac
EOF
# claudeb: revive writes the snapshot and clears the flag the way the real usage merge does.
cat >"$WORK/bin/claudeb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB/claudeb.log"
if [ "$1" = revive ] && [ "${STUB_REVIVE_RC:-0}" = 0 ]; then
  mkdir -p "$CLAUDEB_DIR/limits"
  [ -s "$CLAUDEB_DIR/limits/$2.json" ] || printf '{}\n' >"$CLAUDEB_DIR/limits/$2.json"
  jq 'del(.auth_needed)' "$CLAUDEB_DIR/limits/$2.json" >"$CLAUDEB_DIR/limits/$2.json.tmp" &&
    mv "$CLAUDEB_DIR/limits/$2.json.tmp" "$CLAUDEB_DIR/limits/$2.json"
fi
exit "${STUB_REVIVE_RC:-0}"
EOF
# ssh: node1 is this machine under $NODE (its own HOME, claudeb store and stub dir, whose claude waits for this side's
# callback); sudo and stat there stand in for the desktop session and the screen's user. A forward (-O forward -L p:…)
# is a listener on p that answers any request, as the node's waiting login does through a real one, until -O cancel or
# the master's -O exit. Every call writes the ControlPath it names to ssh-paths.log ("-" for none); the master's open
# (-N -f) logs "open <mode of the socket's dir>" and fails the first $STUB_BANNER times with a banner timeout.
export NODE="$WORK/node"
cat >"$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
forward='' verb='' path='' open=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) case "$2" in ControlPath=*) path=${2#ControlPath=} ;; esac; shift 2 ;;
    -O) verb=$2; shift 2 ;;
    -L) forward=${2%%:*}; shift 2 ;;
    -f) open=true; shift ;;
    -*) shift ;;
    *) break ;;
  esac
done
host=$1
shift
printf '%s\n' "${path:--}" >>"$STUB/ssh-paths.log"
[ "$host" = node1 ] || { printf 'ssh: Could not resolve hostname %s\n' "$host" >&2; exit 255; }
serve='import http.server as h, sys
h.HTTPServer(("127.0.0.1", int(sys.argv[1])), h.BaseHTTPRequestHandler).serve_forever()'
case "$verb" in
  forward)
    printf '%s forward %s\n' "$host" "$forward" >>"$STUB/ssh.log"
    python3 -c "$serve" "$forward" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$STUB/forward-$forward.pid"
    exit 0 ;;
  cancel|exit)
    printf '%s %s%s\n' "$host" "$verb" "${forward:+ $forward}" >>"$STUB/ssh.log"
    for f in "$STUB"/forward-${forward:-*}.pid; do [ ! -s "$f" ] || kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; done
    exit 0 ;;
esac
if $open; then
  printf '%s open %s\n' "$host" "$(stat -f %Lp "${path%/*}" 2>/dev/null)" >>"$STUB/ssh.log"
  n=$(($(cat "$STUB/banner" 2>/dev/null || echo 0) + 1))
  printf '%s\n' "$n" >"$STUB/banner"
  [ "$n" -gt "${STUB_BANNER:-0}" ] || { printf 'Connection timed out during banner exchange\n' >&2; exit 255; }
  exit 0
fi
printf '%s %s\n' "$host" "${*:-forward $forward}" >>"$STUB/ssh.log"
[ -z "$forward" ] || exec python3 -c "$serve" "$forward"
export STUB_CALLBACK="$STUB/callback" HOME="$NODE" CLAUDEB_DIR="$NODE/.claude-profiles/.claudeb" STUB="$NODE/stub" TMPDIR="$NODE/tmp"
exec /bin/sh -c "$*"
EOF
mkdir -p "$NODE/.local/bin"
cat >"$NODE/.local/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB/sudo.log"
[ "${STUB_SUDO:-ok}" = ok ] || exit 1
[ "$1" != -n ] || shift
case "$1" in
  true) exit 0 ;;
  launchctl) shift 3; exec "$@" ;;
  -u) shift 2; exec "$@" ;;
esac
EOF
cat >"$NODE/.local/bin/stat" <<'EOF'
#!/bin/sh
[ "$*" = '-f %Su /dev/console' ] || exec /usr/bin/stat "$@"
printf '%s\n' "${STUB_CONSOLE:-$(id -un)}"
EOF
chmod +x "$WORK/bin/"* "$NODE/.local/bin/"*
ln -s "$WORK/bin/claude" "$NODE/.local/bin/claude"
ln -s "$WORK/bin/claudeb" "$NODE/.local/bin/claudeb"
export CLAUDE_RELOGIN_SSH="$WORK/bin/ssh"
cat >"$CLAUDE_RELOGIN_BRIEF" <<'EOF'
# fixture brief
```
COMPUTER: yes
EFFORT: low
<account> <email> <profile dir> <url file> <port>
```
EOF

reset() { # account... -> logged out, flagged, enrolled; no stamps, logs or lock; the node empty
  local a
  rm -rf "$STUB" "$STATE" "$JOURNAL" "$CLAUDEB_DIR/claude-relogin.lock" "$CLAUDEB_DIR/limits" "$NODE/stub" "$NODE/.claude-profiles" "$NODE/tmp"
  mkdir -p "$STUB" "$CLAUDEB_DIR/limits" "$NODE/stub" "$NODE/tmp"
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
# worker-run refusing before launch (a headless worker's shell) clicked nothing: weather, with its own words, no stamp.
reset alpha
STUB_RUN=refused relogin alpha
assert_eq 7 "$rc" "refused exit: $out"
assert_eq 'REASON: weather — worker-run launched nothing: `worker-run run` runs from the chat that owns the run' "${out%%, never*}"
assert_eq null "$(jq -c '.alpha // null' "$STATE")" "a refused launch left an attempt stamp"
assert login_dead

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

# --on <node>: the node's own login. Steps 1 and 4 and the revive run there, in its desktop session; the window and
# the run stay here; the forward carries the callback port. This Mac's login and store are left alone.
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
answers() { [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://localhost:$1/" 2>/dev/null)" != 000 ]; }
reset alpha
port=$(free_port)
STUB_PORT=$port relogin alpha --on node1
assert_eq 0 "$rc" "node success: $out $(cat "$WORK/err")"
assert_eq 'RELOGIN: alpha logged in as alpha@example.com on node1; revived' "$out"
assert_eq alpha@example.com "$(cat "$NODE/stub/logged-alpha")" "the node's profile is logged in"
assert [ ! -e "$STUB/logged-alpha" ]
assert_eq 'revive alpha' "$(cat "$NODE/stub/claudeb.log")" "revive ran on the node"
assert [ ! -e "$STUB/claudeb.log" ]
assert_eq true "$(jq '.auth_needed' "$CLAUDEB_DIR/limits/alpha.json")" "this Mac's flag is not the node's"
assert_eq '{}' "$(jq -c . "$NODE/.claude-profiles/.claudeb/limits/alpha.json")" "the node's store got its snapshot"
assert grep -q '^-n launchctl asuser [0-9]* sudo -n -u .* auth login --claudeai' "$NODE/stub/sudo.log"
assert grep -q '^-n launchctl asuser [0-9]* sudo -n -u .* auth status --json$' "$NODE/stub/sudo.log"
assert grep -qx "node1 forward $port" "$STUB/ssh.log"
# One connection for the whole run: one master, opened in a private 0700 dir, every call over its socket, the
# forward cancelled with the login and the master closed at exit.
assert_eq 'node1 open 700' "$(grep ' open ' "$STUB/ssh.log")"
assert_eq 1 "$(sort -u "$STUB/ssh-paths.log" | wc -l | tr -d ' ')" "every ssh call names the one socket"
mux_path=$(head -n 1 "$STUB/ssh-paths.log")
assert [ "$mux_path" != - ]
assert grep -qx "node1 cancel $port" "$STUB/ssh.log"
assert_eq 'node1 exit' "$(tail -n 1 "$STUB/ssh.log")" "the master is the run's last ssh call"
assert [ ! -e "${mux_path%/*}" ]
assert grep -q "alpha alpha@example.com Profile 9 .*/authorize-url $port\$" "$STUB/brief.seen"
assert_eq 'browse --json|browse --window|run auto' "$(cut -d' ' -f1-2 "$STUB/worker-run.log" | paste -sd'|' -)"
assert_eq 'alpha@node1 success' "$(jq -r 'select(.kind == "relogin") | "\(.account) \(.outcome)"' "$JOURNAL")"
assert_eq '{}' "$(jq -c . "$STATE")" "a node success leaves no stamp"
! answers "$port" || fail "the forward of $port outlived the run"
pid=$(cat "$NODE/stub/login.pid") && ! kill -0 "$pid" 2>/dev/null || fail "the node's login outlived the run"
asserts=$((asserts + 2))
assert_eq '' "$(ls -A "$NODE/tmp")" "the node kept a scratch directory"
# Run again: nothing to do, nothing started.
: >"$STUB/worker-run.log"
relogin alpha --on node1
assert_eq 3 "$rc"
assert_eq 'REASON: already-logged-in — alpha is logged in as alpha@example.com on node1; nothing to do' "$out"
assert_eq '' "$(cat "$STUB/worker-run.log")"
assert_eq 'revive alpha' "$(cat "$NODE/stub/claudeb.log")" "a node with its snapshot is not revived again"
# Logged in there by hand, no snapshot yet: the revive writes it.
rm -f "$NODE/.claude-profiles/.claudeb/limits/alpha.json"
relogin alpha --on node1
assert_eq 3 "$rc"
assert_eq 'REASON: already-logged-in — alpha is logged in as alpha@example.com on node1; login needed cleared by claudeb revive (exit 0)' "$out"
# A node failure stamps <account>@<node>, which never cools this Mac's own relogin of the account.
reset alpha
STUB_PORT=$(free_port) STUB_RUN=wall relogin alpha --on node1
assert_eq 8 "$rc" "node wall: $out"
assert_eq attempt "$(jq -r '."alpha@node1".verdict' "$STATE")"
assert_eq null "$(jq -c '.alpha // null' "$STATE")"
pid=$(cat "$NODE/stub/login.pid") && ! kill -0 "$pid" 2>/dev/null || fail "a failed node attempt left its login waiting"
asserts=$((asserts + 1))
assert_eq '' "$(ls -A "$NODE/tmp")" "a failed node attempt kept its scratch directory"
# A node that cannot hold a login, and one that does not answer.
reset alpha
STUB_SUDO=no relogin alpha --on node1
assert_eq 10 "$rc"
assert_eq 'REASON: node-not-ready — node1: no passwordless sudo, so an ssh session cannot reach its keychain' "$out"
STUB_CONSOLE=somebody-else relogin alpha --on node1
assert_eq 10 "$rc"
relogin alpha --on node2
assert_eq 7 "$rc"
assert_eq 'REASON: weather' "${out%% — *}"
assert_eq 'node-not-ready node-not-ready weather' "$(journal_outcomes)"
assert [ ! -e "$STATE" ]
relogin alpha --on node1 --dry-run
assert_eq 0 "$rc"
assert_eq 'DRY-RUN: would log alpha in on node1 as alpha@example.com through Chrome profile Profile 9' "$out"
assert [ ! -e "$NODE/stub/login.pid" ]
# A banner timeout (sshd's MaxStartups dropping a fresh connection) is retried once; a second is weather.
reset alpha
STUB_BANNER=1 relogin alpha --on node1 --dry-run
assert_eq 0 "$rc" "one banner timeout: $out $(cat "$WORK/err")"
assert_eq 2 "$(grep -c ' open ' "$STUB/ssh.log")"
reset alpha
STUB_BANNER=2 relogin alpha --on node1
assert_eq 7 "$rc"
assert_eq 'REASON: weather — node1 did not answer over ssh (exit 255: Connection timed out during banner exchange); `machines wake node1` if it sleeps' "$out"
assert_eq 2 "$(grep -c ' open ' "$STUB/ssh.log")"
relogin alpha --on
assert_eq 2 "$rc"
relogin alpha --on 'a b'
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
