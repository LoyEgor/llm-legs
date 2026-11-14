#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/tmux-upgrade rehearsed end to end on a private tmux socket (lib/fake-chats.sh): two copies of the tmux binary
# stand in Cellar folders 3.7b and 3.8 (TMUX_UPGRADE_VERSION_FROM=path), a fake brew moves the link from one to
# the other. Not ready (present, dictation, a worker run, a busy chat, a pane running something) waits and touches
# nothing; brew failing does nothing else; ready: every chat recorded, brew, the old server ended, each chat resumed
# on the new server in its own session with its account and model, a chat that does not come back notified, the
# agent removed. The real server, registry, brew and chats are never touched.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/bin/tmux-upgrade"
. "$ROOT/tests/lib/fake-chats.sh" tmux-upgrade

REAL=$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TMUX_BIN")
for v in 3.7b 3.8; do
  mkdir -p "$WORK/Cellar/tmux/$v/bin"
  cp "$REAL" "$WORK/Cellar/tmux/$v/bin/tmux"
done
ln -s "$WORK/Cellar/tmux/3.7b/bin/tmux" "$WORK/bin/tmux"
export CHAT_TMUX_BIN="$WORK/bin/tmux" TMUX_UPGRADE_TMUX="$WORK/bin/tmux" TMUX_UPGRADE_VERSION_FROM=path
export TMUX_UPGRADE_BREW="$WORK/brew" TMUX_UPGRADE_LOG="$WORK/upgrade.log" TMUX_UPGRADE_DIR="$WORK/state"
export TMUX_UPGRADE_QUIET_S=0 TMUX_UPGRADE_WINDOW=0-24 TMUX_UPGRADE_VOICE_SOCK="$WORK/voice.sock" WORKER_RUN_DIR="$WORK/runs"
export TMUX_UPGRADE_NOTIFY="$WORK/notify" TMUX_UPGRADE_LAUNCHCTL="$WORK/launchctl" TMUX_UPGRADE_START_WAIT=20
export TMUX_UPGRADE_AGENT_DIR="$WORK/agents" TMUX_UPGRADE_LIBEXEC_DIR="$WORK/libexec" SPEED_DOCTOR_DIR="$WORK/sd"
mkdir -p "$WORK/runs" "$SPEED_DOCTOR_DIR/presence" "$HOME/.claude-profiles/broken"
cat >"$WORK/brew" <<EOF
#!/bin/bash
echo "\$*" >>"$WORK/brew.calls"
[ ! -e "$WORK/brew-fails" ] || { echo "Error: no network" >&2; exit 1; }
ln -sfn "$WORK/Cellar/tmux/3.8/bin/tmux" "$WORK/bin/tmux"
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >>"%s/notify.calls"\n' "$WORK" >"$WORK/notify"
printf '#!/bin/bash\necho "$*" >>"%s/launchctl.calls"\n' "$WORK" >"$WORK/launchctl"
chmod +x "$WORK/brew" "$WORK/notify" "$WORK/launchctl"
upgrade() { "$PY" -B "$TOOL" "$@"; }
fail() { printf 'FAIL: %s\n' "$*"; tail -30 "$WORK/upgrade.log" 2>/dev/null; exit 1; }
# The chat's live process: a chat the server's end killed leaves its registry record behind, as the real CLI does.
live_pid() { local f p; for f in $(grep -l "\"$1\"" "$HOME"/.claude/sessions/*.json); do p=${f##*/}; p=${p%.json}
  kill -0 "$p" 2>/dev/null && { echo "$p"; return; }; done; }
present() { rm -f "$SPEED_DOCTOR_DIR/presence/away"; }
gone_away() { printf '%s\t%s\n' "$(($(date +%s) - 900))" "$(date +%s)" >"$SPEED_DOCTOR_DIR/presence/away"; }
server_pid() { pgrep -f -- "-S $CHAT_TMUX_SOCKET .*start-server" | head -1; }
server_binary() { "$PY" -c 'import ctypes,sys
b=ctypes.create_string_buffer(4096); ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(int(sys.argv[1]),b,4096)
print(b.value.decode())' "$1"; }
session_of() { "$TMUX_BIN" -S "$CHAT_TMUX_SOCKET" list-panes -a -F '#{pane_tty} #{session_name}' | grep "^/dev/$(ps -o tty= -p "$1" | tr -d ' ') " | cut -d' ' -f2; }

ONE=11111111-1111-4111-8111-111111111111
TWO=22222222-2222-4222-8222-222222222222
EMPTY=99999999-9999-4999-8999-999999999999
read -r one_pane _ < <(open_chat $ONE)
read -r two_pane _ < <(open_chat $TWO)
open_chat $EMPTY bare >/dev/null
old_server=$(server_pid)
assert [ -n "$old_server" ]
assert grep -q '/3.7b/bin/tmux$' <<<"$(server_binary "$old_server")"
one_old=$(pid_of $ONE)
two_old=$(pid_of $TWO)
upgrade arm >/dev/null
assert [ -f "$WORK/agents/com.llm-legs.tmux-upgrade.plist" ]
assert grep -q '^bootstrap gui/' "$WORK/launchctl.calls"
assert [ -x "$WORK/libexec/tmux-upgrade" ]

# Not ready: each reason waits (a chat that spoke within QUIET_S too), and nothing is touched (no brew, the same server and chats).
present
out=$(upgrade check; echo "rc=$?")
assert grep -q '^Egor is at the Mac$' <<<"$out"
assert grep -q '^rc=1$' <<<"$out"
gone_away
"$PY" - "$WORK/voice.sock" <<'EOF' &
import os, socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(4)
for _ in range(2):
    c, _ = s.accept(); c.recv(64); c.sendall(b"recording\n"); c.close()
os.remove(sys.argv[1])
EOF
until_ok [ -S "$WORK/voice.sock" ] || fail "the fake dictation daemon did not listen"
assert grep -q '^dictation: recording$' <<<"$(upgrade check)"
upgrade tick
assert grep -q 'waits (tmux 3.7b, server 3.7b): dictation: recording' "$WORK/upgrade.log"
until_ok [ ! -e "$WORK/voice.sock" ] || fail "the fake dictation daemon did not end"
perl -e 'sleep 600' "$WORK/supervisor" &
sup=$!
run="$WORK/runs/claudeb-$(date +%s)-$sup-abcd"
mkdir -p "$run"
printf '{"pid": %d, "pid_started_at": %d}\n' "$sup" "$(date +%s)" >"$run/meta.json"
assert grep -q "^worker run claudeb-" <<<"$(upgrade check)"
printf '0\n' >"$run/exit_code"
set_field $TWO status '"busy"'
assert grep -q '^22222222: busy$' <<<"$(upgrade check)"
set_field $TWO status '"idle"'
assert grep -q '^11111111: spoke [0-9]* s ago$' <<<"$(TMUX_UPGRADE_QUIET_S=600 upgrade check)"
helper open --line "perl -e 'sleep 600' $WORK/job" >/dev/null
until_ok pgrep -f "$WORK/job" >/dev/null || fail "the pane job did not start"
assert grep -q "^pane c-[0-9a-f]* runs perl -e sleep 600 $WORK/job" <<<"$(upgrade check)"
pkill -f "$WORK/job"
until_ok [ "$(upgrade check)" = ready ] || fail "never ready: $(upgrade check)"
refute [ -e "$WORK/brew.calls" ]
assert [ "$(server_pid)" = "$old_server" ]
assert [ "$(pid_of $ONE)" = "$one_old" ]

# Outside the window a tick does nothing at all.
lines=$(wc -l <"$WORK/upgrade.log")
TMUX_UPGRADE_WINDOW=5-5 upgrade tick
assert [ "$(wc -l <"$WORK/upgrade.log")" -eq "$lines" ]

# Brew fails: nothing else happens, one notification, and no retry (nor a new record) within the hour.
touch "$WORK/brew-fails"
upgrade tick
assert grep -q 'FAILED: brew exit 1, tmux -V 3.7b (wanted 3.8); nothing else done' "$WORK/upgrade.log"
assert grep -q 'brew: Error: no network' "$WORK/upgrade.log"
assert grep -q "recorded 3 chats" "$WORK/upgrade.log"
assert grep -q "^brew upgrade tmux failed (exit 1, tmux 3.7b)" "$WORK/notify.calls"
assert [ "$(server_pid)" = "$old_server" ]
assert [ "$(pid_of $ONE)" = "$one_old" ]
assert kill -0 "$one_old"
upgrade tick
assert [ "$(wc -l <"$WORK/brew.calls")" -eq 1 ]
assert grep -q 'not tried again before' "$WORK/upgrade.log"
assert [ "$(grep -c 'recorded 3 chats' "$WORK/upgrade.log")" -eq 1 ]
rm -f "$WORK/brew-fails" "$WORK/state/brew-failed"

# Ready: recorded, brew, the old server ended, every chat back on the new server in its own session, with its
# account and model; a chat whose resume does not start is notified and logged LOST; the agent removes itself.
# TWO's next start fails: its account's launcher exits at once.
"$PY" - "$HOME/.claude/sessions/$(pid_of $TWO).json" <<'EOF'
import json, sys
path = sys.argv[1]; doc = json.load(open(path)); doc["cwd"] = doc["cwd"] + "/nowhere"; json.dump(doc, open(path, "w"))
EOF
upgrade tick
assert [ "$(wc -l <"$WORK/brew.calls")" -eq 2 ]
assert grep -q '^upgrade tmux$' "$WORK/brew.calls"
assert grep -q 'tmux -V: 3.8' "$WORK/upgrade.log"
refute kill -0 "$old_server" 2>/dev/null
refute kill -0 "$one_old" 2>/dev/null
new_server=$(server_pid)
assert [ -n "$new_server" ]
assert grep -q '/3.8/bin/tmux$' <<<"$(server_binary "$new_server")"
one_new=$(live_pid $ONE)
refute [ "$one_new" = "$one_old" ]
assert kill -0 "$one_new"
assert [ "$(session_of "$one_new")" = c-11111111 ]
last=$(grep "\"pid\": $one_new" "$HOME/argv.log")
assert [ "$("$PY" -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])["argv"]))' "$last")" = \
  "--resume $ONE --model opus --permission-mode bypassPermissions" ]
assert [ "$("$PY" -c 'import json,sys; print(json.loads(sys.argv[1])["config"])' "$last")" = "$HOME/.claude-profiles/acct1" ]
assert grep -q "back 11111111 in c-11111111" "$WORK/upgrade.log"
assert grep -q "LOST $TWO -: not live in c-22222222 after 20s: .*no such file or directory: $WORK/proj/nowhere" "$WORK/upgrade.log"
assert grep -q "^1 chat did not come back after the tmux upgrade: 22222222" "$WORK/notify.calls"
assert grep -q "99999999: nothing said yet, nothing to resume (dropped)" "$WORK/upgrade.log"
assert grep -q "$ONE - profile=acct1 mode=bypassPermissions cwd=$WORK/proj session=c-11111111" "$WORK/upgrade.log"
record=$(ls "$WORK/state"/record-*.json | tail -1)
assert [ "$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["chats"]), d["server_version"], d["installed"])' "$record")" = "3 3.7b 3.8" ]
assert grep -q 'done: tmux 3.8, 1 chats back, 1 lost' "$WORK/upgrade.log"
refute [ -e "$WORK/agents/com.llm-legs.tmux-upgrade.plist" ]
refute [ -e "$WORK/libexec/tmux-upgrade" ]
assert grep -q '^bootout gui/[0-9]*/com.llm-legs.tmux-upgrade$' "$WORK/launchctl.calls"

# Done is done: another tick brews nothing and touches nothing.
upgrade run
assert [ "$(wc -l <"$WORK/brew.calls")" -eq 2 ]
assert [ "$(server_pid)" = "$new_server" ]
assert [ "$(live_pid $ONE)" = "$one_new" ]
assert grep -q 'done: tmux 3.8, server 3.8' "$WORK/upgrade.log"

printf 'test_tmux_upgrade: %d asserts PASS\n' "$asserts"
