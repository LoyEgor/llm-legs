# Fake chats on a private tmux socket (CHAT_TMUX_SOCKET) and a fixture HOME (its session registry), shared by the
# suites of the tools that end and resume chats (test_chat_refresh.sh, test_tmux_upgrade.sh): `. lib/fake-chats.sh
# NAME` makes WORK (/tmp/NAME-test.*), the fake claude and claudeb, the cleanup and the asserts. The real server,
# registry and chats are never touched.
WORK="$(cd "$(mktemp -d "/tmp/$1-test.XXXXXX")" && pwd -P)"
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
