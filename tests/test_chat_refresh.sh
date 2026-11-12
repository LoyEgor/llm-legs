#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/chat-refresh on a private tmux socket (CHAT_TMUX_SOCKET) and a fixture HOME (its session registry): fake chats
# record their argv; a safe one is resumed in its own pane with its account and model, each other one is skipped
# with its word. The real server, registry and chats are never touched.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/bin/chat-refresh"
WORK="$(cd "$(mktemp -d /tmp/chat-refresh-test.XXXXXX)" && pwd -P)"
export HOME="$WORK/home" CHAT_TMUX_SOCKET="$WORK/s/t.sock" CHAT_REFRESH_BIN="$WORK/bin" CHAT_REFRESH_SETTLE=0.3
export CHAT_TMUX_APP="http://127.0.0.1:9" CHAT_TMUX_PGREP="$WORK/pgrep" CHAT_TMUX_CLOSE_GRACE=0.2
export CLAUDEGPT_HOME="$WORK/gpt" ZDOTDIR="$WORK/zdot" CHAT_NAMES_CACHE="$WORK/names.json"
TMUX_BIN=$(command -v tmux) || { printf 'SKIP: no tmux\n'; exit 0; }
PY=$(command -v python3)
export CHAT_TMUX_BIN="$TMUX_BIN"
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/proj" "$HOME/.claude/hooks" "$HOME/.claude-profiles/acct1" "$WORK/bin" "$WORK/proj" \
  "$ZDOTDIR" "$CLAUDEGPT_HOME"
printf '#!/bin/sh\nexit 1\n' >"$WORK/pgrep"; chmod +x "$WORK/pgrep"
cleanup() {
  "$TMUX_BIN" -S "$CHAT_TMUX_SOCKET" kill-server 2>/dev/null
  pkill -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
refute() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }
until_ok() { local i; for i in $(seq 100); do "$@" && return 0; perl -e 'select(undef,undef,undef,0.1)'; done; return 1; }

# A fake Claude Code: registers in the session registry as the real CLI does (procStart = its own start), draws an
# empty prompt box, logs every start's argv, account and tty, and reads lines: /exit ends it, `draft:T` redraws the
# box holding T, `ask` a question with no box, `spawn:CMD` starts CMD as its child; anything else was "sent".
cat >"$WORK/bin/claude" <<EOF
#!$PY
import json, os, subprocess, sys, time
argv = sys.argv[1:]
sid = argv[argv.index("--resume") + 1]
home = os.environ["HOME"]
start = subprocess.run(["ps", "-o", "lstart=", "-p", str(os.getpid())], capture_output=True, text=True,
                       env=dict(os.environ, LC_ALL="C", TZ="UTC")).stdout.strip()
reg = os.path.join(home, ".claude", "sessions", "%d.json" % os.getpid())
with open(reg, "w") as h:
    json.dump({"pid": os.getpid(), "sessionId": sid, "cwd": os.getcwd(), "startedAt": int(time.time() * 1000),
               "procStart": start, "kind": "interactive", "entrypoint": "cli", "status": "idle"}, h)
try:
    tty = os.ttyname(0)
except OSError:
    tty = ""
with open(os.path.join(home, "argv.log"), "a") as h:
    h.write(json.dumps({"argv": argv, "config": os.environ.get("CLAUDE_CONFIG_DIR", ""), "tty": tty,
                        "pid": os.getpid()}) + "\n")
def box(text=""):
    sys.stdout.write("\033[2J\033[H" + "─" * 30 + "\n❯ " + text + "\n" + "─" * 30 + "\n")
    sys.stdout.flush()
box()
for line in sys.stdin:
    line = line.strip()
    if line == "/exit":
        os.remove(reg)
        sys.exit(0)
    if line.startswith("draft:"):
        box(line[6:])
    elif line == "ask":
        sys.stdout.write("\033[2J\033[HDo you want to proceed?\n❯ 1. Yes\n  2. No\n")
        sys.stdout.flush()
    elif line.startswith("spawn:"):
        subprocess.Popen(line[6:], shell=True)
    else:
        with open(os.path.join(home, "typed.log"), "a") as h:
            h.write(sid + " " + line + "\n")
EOF
# A fake claudeb: `profile NAME ARGS` runs the fake claude under that profile's config dir.
cat >"$WORK/bin/claudeb" <<EOF
#!/bin/bash
[ "\$1" = profile ] || exit 2
export CLAUDE_CONFIG_DIR="\$HOME/.claude-profiles/\$2"
shift 2
exec "$WORK/bin/claude" "\$@"
EOF
# Sleepers name $WORK on their command lines, so the cleanup's pkill takes every one.
printf '#!/bin/bash\nperl -e "sleep 600" "$0"\n' >"$WORK/bin/worker-run"
printf '#!/bin/bash\nperl -e "sleep 600" "$0"\n' >"$HOME/.claude/hooks/keepalive.sh"
chmod +x "$WORK/bin/claude" "$WORK/bin/claudeb" "$WORK/bin/worker-run" "$HOME/.claude/hooks/keepalive.sh"

helper() { "$PY" -B "$ROOT/share/chat_tmux.py" "$@"; }
registered() { cat "$HOME"/.claude/sessions/*.json 2>/dev/null | grep -q "\"$1\""; }  # globbed on each try
# A chat in its own pane of the private server: "<pane> <tty>".
open_chat() {  # open_chat SID [bare]: bare, no transcript (a chat nothing was said in)
  local sid=$1 got
  [ "${2:-}" = bare ] || : >"$HOME/.claude/projects/proj/$sid.jsonl"
  got=$(helper open --cwd "$WORK/proj" --line "CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/acct1 $WORK/bin/claude --resume $sid --model opus --permission-mode bypassPermissions") ||
    fail "could not open $sid"
  until_ok registered "$sid" || fail "$sid did not register"
  until_ok grep -q '❯' <(helper capture "$(echo "$got" | cut -d' ' -f2)") || fail "$sid drew no prompt"
  echo "$got" | cut -d' ' -f2-
}
pid_of() { grep -l "\"$1\"" "$HOME"/.claude/sessions/*.json | head -1 | sed 's#.*/##; s#\.json$##'; }
set_field() {  # set_field SID KEY JSON-VALUE: the registry record of SID changes as the CLI would change it
  "$PY" - "$HOME/.claude/sessions/$(pid_of "$1").json" "$2" "$3" <<'EOF'
import json, sys
path, key, value = sys.argv[1:]
doc = json.load(open(path)); doc[key] = json.loads(value); json.dump(doc, open(path, "w"))
EOF
}
send() { printf '%s' "$2" | helper paste "$1"; }
refresh() { "$PY" -B "$TOOL" "$@"; }

SAFE=11111111-1111-4111-8111-111111111111
BUSY=22222222-2222-4222-8222-222222222222
WORKER=33333333-3333-4333-8333-333333333333
TASKS=44444444-4444-4444-8444-444444444444
DRAFT=55555555-5555-4555-8555-555555555555
ASK=66666666-6666-4666-8666-666666666666
TERM_ONLY=77777777-7777-4777-8777-777777777777
CLOSED=88888888-8888-4888-8888-888888888888
EMPTY=99999999-9999-4999-8999-999999999999

read -r safe_pane safe_tty < <(open_chat $SAFE)
read -r busy_pane _ < <(open_chat $BUSY)
read -r worker_pane _ < <(open_chat $WORKER)
read -r tasks_pane _ < <(open_chat $TASKS)
read -r draft_pane _ < <(open_chat $DRAFT)
read -r ask_pane _ < <(open_chat $ASK)
open_chat $EMPTY bare >/dev/null
# A Terminal-tab chat: no pane of the chats' tmux (closing its tab would end it).
(perl -e 'sleep 600' "$WORK/hold" | CLAUDE_CONFIG_DIR="$HOME/.claude-profiles/acct1" "$WORK/bin/claude" --resume $TERM_ONLY >/dev/null) 2>/dev/null &
disown
until_ok registered "$TERM_ONLY" || fail "the Terminal chat did not register"

set_field $BUSY status '"busy"'
send "$worker_pane" "spawn:bash $WORK/bin/worker-run wait run-1"
send "$tasks_pane" "spawn:perl -e 'sleep 600' $WORK/task"
send "$draft_pane" "draft:half a message"
send "$ask_pane" "ask"
# Claude Code's own helper (a hook's sleeper) holds nothing: the safe chat runs one.
send "$safe_pane" "spawn:$HOME/.claude/hooks/keepalive.sh"
until_ok pgrep -f "worker-run wait run-1" >/dev/null || fail "the worker wait did not start"
until_ok pgrep -f "keepalive.sh" >/dev/null || fail "the hook helper did not start"
until_ok grep -q 'half a message' <(helper capture "$draft_pane") || fail "the draft did not show"
until_ok grep -q 'proceed' <(helper capture "$ask_pane") || fail "the question did not show"
safe_old=$(pid_of $SAFE)

# A dry run says what it would do and touches nothing.
out=$(refresh --all --dry-run)
assert grep -q "^11111111  would refresh [0-9]* MB: cd '$WORK/proj' && $WORK/bin/claudeb profile acct1 --resume $SAFE --model opus --permission-mode bypassPermissions$" <<<"$out"
assert grep -q '^would refresh 1, skipped 7$' <<<"$out"
assert [ "$(pid_of $SAFE)" = "$safe_old" ]
assert [ "$(wc -l <"$HOME/argv.log")" -eq 8 ]

# Each chat that is not at rest is skipped with its word; a closed one too.
out=$(refresh --all)
assert grep -q '^22222222  skipped busy$' <<<"$out"
assert grep -q '^33333333  skipped worker$' <<<"$out"
assert grep -q '^44444444  skipped tasks$' <<<"$out"
assert grep -q '^55555555  skipped draft$' <<<"$out"
assert grep -q '^66666666  skipped asking$' <<<"$out"
assert grep -q '^77777777  skipped terminal$' <<<"$out"
assert grep -q '^99999999  skipped empty$' <<<"$out"
assert grep -q '^11111111  refreshed [0-9]* -> [0-9]* MB$' <<<"$out"
assert grep -qE '^refreshed 1, skipped 7, -?[0-9]+ MB freed$' <<<"$out"

# The safe chat: ended (/exit), resumed in the same pane and tty, on the same account, model and mode.
safe_new=$(pid_of $SAFE)
assert [ -n "$safe_new" ]
refute [ "$safe_new" = "$safe_old" ]
refute kill -0 "$safe_old" 2>/dev/null
last=$(grep "\"pid\": $safe_new" "$HOME/argv.log")
assert [ "$("$PY" -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])["argv"]))' "$last")" = \
  "--resume $SAFE --model opus --permission-mode bypassPermissions" ]
assert [ "$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1])["config"])' "$last")" = "$HOME/.claude-profiles/acct1" ]
assert [ "$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1])["tty"])' "$last")" = "$safe_tty" ]
assert [ "$(helper pane "$safe_tty")" = "$safe_pane" ]
# Nothing was typed into a live chat as a message (the resume line goes only to the pane's shell).
refute grep -qs -- '--resume' "$HOME/typed.log"
# The skipped chats run on as they were.
for sid in $BUSY $WORKER $TASKS $DRAFT $ASK $TERM_ONLY $EMPTY; do
  assert kill -0 "$(pid_of $sid)"
done
assert [ "$(grep -c "\"$BUSY\"" "$HOME/argv.log")" -eq 1 ]

# Named chats: a prefix picks one, an id that runs nowhere is closed; --night skips a chat under a day old and one
# under 400 MB.
out=$(refresh 22222222 $CLOSED)
assert grep -q '^22222222  skipped busy$' <<<"$out"
assert grep -q '^88888888  skipped closed$' <<<"$out"
assert grep -q '^refreshed 0, skipped 2$' <<<"$out"
set_field $BUSY status '"idle"'
out=$(refresh --night --dry-run)
assert grep -q '^22222222  skipped young$' <<<"$out"
set_field $BUSY startedAt "$(( ($(date +%s) - 2 * 86400) * 1000 ))"
out=$(refresh --night --dry-run)
assert grep -q '^22222222  skipped light$' <<<"$out"

# A second run while one holds the lock refreshes nothing.
perl -e 'use Fcntl ":flock"; open(my $f, ">", $ARGV[0]); flock($f, LOCK_EX); sleep 5' "$WORK/s/refresh.lock" &
locker=$!
perl -e 'select(undef,undef,undef,0.3)'
out=$(refresh --all; echo "rc=$?")
assert grep -q '^chat-refresh: another run is refreshing chats$' <<<"$out"
assert grep -q '^rc=1$' <<<"$out"
kill "$locker" 2>/dev/null

printf 'test_chat_refresh: %d asserts PASS\n' "$asserts"
