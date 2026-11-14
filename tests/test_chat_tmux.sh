#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/chat_tmux.py on a private socket (CHAT_TMUX_SOCKET): what bytes a pane's program gets from a paste, keys and
# a clear, the screen read back, session names, the server's environment under a launchd-like start, and the size a
# window keeps after its viewer detaches. The real server's socket is never touched.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/share/chat_tmux.py"
WORK="$(mktemp -d /tmp/chat-tmux-test.XXXXXX)"
export CHAT_TMUX_SOCKET="$WORK/s/t.sock"
# A viewer that leaves runs closed() through the hook: no test reaches the live app or asks the real Terminal.
export CHAT_TMUX_APP="http://127.0.0.1:9" CHAT_TMUX_PGREP="$WORK/pgrep" CHAT_TMUX_CLOSE_GRACE=0.2
printf '#!/bin/sh\nexit 1\n' >"$WORK/pgrep"; chmod +x "$WORK/pgrep"
OUTER="$WORK/outer.sock"
TMUX_BIN=$(command -v tmux) || { printf 'SKIP: no tmux\n'; exit 0; }
t() { "$TMUX_BIN" -S "$CHAT_TMUX_SOCKET" "$@"; }
outer() { "$TMUX_BIN" -S "$OUTER" "$@"; }
cleanup() {
  [ -n "${app_pid:-}" ] && kill "$app_pid" 2>/dev/null
  outer kill-server 2>/dev/null
  t kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
# A launchd start: no locale, a short PATH, no rc files of his (an empty ZDOTDIR); and a starter inside a chat,
# whose Claude Code variables must reach no pane.
{ unset LANG LC_ALL LC_CTYPE TMUX; } 2>/dev/null
export CHAT_TMUX_BIN="$TMUX_BIN" PATH=/usr/bin:/bin ZDOTDIR="$WORK/zdot" CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=sdk-cli \
  CLAUDE_CONFIG_DIR="$WORK/profile"
mkdir -p "$ZDOTDIR"

asserts=0
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
refute() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }
helper() { python3 -B "$HELPER" "$@"; }
matches() { [[ $1 =~ $2 ]]; }
# Waits up to 5 s for a command to succeed.
until_ok() { local i; for i in $(seq 50); do "$@" && return 0; perl -e 'select(undef,undef,undef,0.1)'; done; return 1; }
bytes() { od -An -c "$1" | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'; }
has() { [ -s "$1" ] && grep -Fq -- "$2" "$1"; }

# No server: nothing to find and no socket made by a look.
assert [ "$(python3 -B -c "import sys; sys.path.insert(0, '$ROOT/share'); import chat_tmux; print(chat_tmux.panes())")" = "{}" ]
refute helper pane /dev/ttys999
assert [ ! -e "$CHAT_TMUX_SOCKET" ]

# A stub TUI: asks for bracketed paste, then records every byte it gets.
STUB="printf '\\033[?2004h'; stty raw -echo; exec cat >$WORK/bytes"
read -r session pane tty < <(helper open --line "$STUB" --name stub)
assert [ "$session" = stub ]
assert matches "$pane" '^%[0-9]+$'
assert matches "$tty" '^/dev/ttys[0-9]+$'
assert [ "$(helper pane "$tty")" = "$pane" ]
assert grep -q "^stub $pane $tty [0-9]* 110x60 0$" <(helper ls)
until_ok [ -e "$WORK/bytes" ] || fail "the stub did not start"
# The server's own command line names no chat (pgrep -f on a session id must not find the server).
refute grep -q 2004h <(ps -o command= -p "$(t display -p '#{pid}')")
perl -e 'select(undef,undef,undef,0.3)'

# Two cleared lines, a bracketed paste of two lines (LF goes as CR, Terminal's paste form), Enter; then a lone Escape.
printf 'a\nб' | helper paste "$tty"
python3 -B -c "import sys; sys.path.insert(0, '$ROOT/share'); import chat_tmux as c; c.paste('$pane', 'x', enter=False, clear=2)"
helper keys "$pane" Escape
want='033 [ 2 0 0 ~ a \r 320 261 033 [ 2 0 1 ~ \r 025 177 025 177 033 [ 2 0 0 ~ x 033 [ 2 0 1 ~ 033'
got_all() { [ "$(bytes "$WORK/bytes")" = "$want" ]; }
until_ok got_all || fail "pane bytes: $(bytes "$WORK/bytes")"
asserts=$((asserts + 1))
assert [ -z "$(t list-buffers)" ]   # every paste deletes its buffer

# keys --literal types its text as is: "C-u" is three characters, not Ctrl+U.
helper open --line "stty raw -echo; exec cat >$WORK/lit" --name lit >/dev/null
until_ok [ -e "$WORK/lit" ] || fail "the literal stub did not start"
perl -e 'select(undef,undef,undef,0.3)'
helper keys lit --literal C-u
got_lit() { [ "$(bytes "$WORK/lit")" = "C - u" ]; }
until_ok got_lit || fail "literal bytes: $(bytes "$WORK/lit")"
asserts=$((asserts + 1))
helper end lit

# The server's environment, from a launchd-like start: UTF-8, tmux's TERM, Homebrew on PATH, no Claude Code variable.
helper open --line "printf '%s|%s|%s|%s|%s|' \"\$TERM\" \"\$LANG\" \"\$TERM_PROGRAM\" \"\$COLORTERM\" \"\$CLAUDECODE\$CLAUDE_CODE_ENTRYPOINT\$CLAUDE_CONFIG_DIR\" >$WORK/env; command -v tmux >>$WORK/env" --name env >/dev/null
until_ok has "$WORK/env" tmux || fail "env: $(cat "$WORK/env" 2>/dev/null)"
assert grep -q '^tmux-256color|en_US.UTF-8|tmux|truecolor||/' "$WORK/env"
assert [ "$(t show -gv prefix)" = C-] ]
assert [ "$(t show -gv mouse)" = on ]

# The screen and its scrollback; after the line, the pane is a shell again.
helper open --line "seq 1 200" --name scr >/dev/null
until_ok grep -qx 200 <(helper capture scr) || fail "screen: $(helper capture scr)"
refute grep -qx 1 <(helper capture scr)
assert grep -qx 1 <(helper capture scr --history 300)
scr_shell() { t list-panes -a -F '#{session_name} #{pane_current_command}' | grep -qx 'scr -\{0,1\}zsh'; }
assert until_ok scr_shell

# Names: from the session id a line or a .command file holds; a second chat on one name gets -2.
sid=0123abcd-1111-2222-3333-444455556666
assert [ "$(helper open --line "sleep 30 --session-id $sid" | cut -d' ' -f1)" = c-0123abcd ]
printf '#!/bin/bash\nexec sleep 30 --resume %s\n' "$sid" >"$WORK/chat.command"
chmod 755 "$WORK/chat.command"
assert [ "$(helper open "$WORK/chat.command" | cut -d' ' -f1)" = c-0123abcd-2 ]
assert matches "$(helper open --line 'sleep 30' | cut -d' ' -f1)" '^c-[0-9a-f]{8}$'

# A viewer 90x40 sets the size (window-size latest); detached, the window keeps it.
printf 'set -g status off\n' >"$WORK/outer.conf"
outer -f "$WORK/outer.conf" new-session -d -x 90 -y 40 \
  "env -u TMUX python3 -B $HELPER attach scr"
seen() { [ "$(t display -p -t =scr: '#{session_attached} #{window_width}x#{window_height}')" = "$1" ]; }
until_ok seen "1 90x40" || fail "attached: $(t display -p -t =scr: '#{session_attached} #{window_width}x#{window_height}')"
asserts=$((asserts + 1))
# The viewer's tty (a Terminal tab's, at the Mac) leads to the pane it shows; view raises that tab (osascript stub:
# "front" for the viewer's tty only) and opens nothing.
viewer=$(outer display -p '#{pane_tty}')
assert [ "$(helper client "$viewer")" = "$(t display -p -t =scr: '#{pane_id} #{pane_tty}')" ]
refute helper client /dev/ttys999
printf '#!/bin/sh\n[ "$3" = "%s" ] && echo front\nexit 0\n' "$viewer" >"$WORK/osascript"
printf '#!/bin/sh\necho "$@" >>%s/opened\n' "$WORK" >"$WORK/open"
chmod 755 "$WORK/osascript" "$WORK/open"
export CHAT_TMUX_OSASCRIPT="$WORK/osascript" CHAT_TMUX_OPEN="$WORK/open"
assert [ "$(helper view scr)" = front ]
assert [ ! -e "$WORK/opened" ]
outer kill-server
until_ok seen "0 90x40" || fail "detached: $(t display -p -t =scr: '#{session_attached} #{window_width}x#{window_height}')"
asserts=$((asserts + 1))
assert [ "$(helper ls | grep -c '^scr ')" = 1 ]   # its viewer gone, the session stays
# No viewer: a new Terminal window gets a .command that attaches (stubbed open records it).
assert [ "$(helper view scr)" = opened ]
assert grep -qxF -- "-a Terminal $WORK/s/view/scr.command" "$WORK/opened"
assert grep -q " attach scr\$" "$WORK/s/view/scr.command"
assert [ -x "$WORK/s/view/scr.command" ]
# open --view (the menubar's reopen, tmux phase 5): the chat starts detached and its view comes up at once.
assert [ "$(helper open --line 'sleep 30' --name opv --view | cut -d' ' -f1,4)" = "opv opened" ]
assert grep -qxF -- "-a Terminal $WORK/s/view/opv.command" "$WORK/opened"
# Its end (the app's close or move) with a viewer on it: the viewer's window (osascript stub: id 42 for the client's
# tty) is found before the session goes and handed to the closer, which closes it once its shell has ended.
outer -f "$WORK/outer.conf" new-session -d -x 90 -y 40 "env -u TMUX python3 -B $HELPER attach opv"
watched() { [ "$(t display -p -t =opv: '#{session_attached}')" = 1 ]; }
until_ok watched || fail "opv not attached"
viewer=$(outer display -p '#{pane_tty}')
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%s/osa\ncase "$2" in *"set found"*) [ "$3" = "%s" ] && echo 42;; esac\nexit 0\n' \
  "$WORK" "$viewer" >"$WORK/osascript"
helper end opv
refute grep -q '^opv ' <(helper ls)
assert grep -qxF "end run $viewer" "$WORK/osa"
closed() { grep -qxF "end run 42" "$WORK/osa"; }
until_ok closed || fail "no close of window 42: $(tail -3 "$WORK/osa")"
asserts=$((asserts + 1))
# Terminal windows for every chat (the apps' switch): on, each session with no viewer gets a window and the flag file
# is there; off, a viewer's client detaches and its window (id 42) closes, the chat runs on, the flag is gone.
assert [ "$(helper mirror)" = off ]
: >"$WORK/opened"
read -r state n < <(helper mirror on)
assert [ "$state" = on ] && assert [ "$n" -ge 1 ]
assert [ "$(grep -c -- '-a Terminal ' "$WORK/opened")" = "$n" ]
assert grep -qxF -- "-a Terminal $WORK/s/view/scr.command" "$WORK/opened"
assert [ "$(helper mirror)" = on ] && assert [ -e "$WORK/s/mirror" ]
outer -f "$WORK/outer.conf" new-session -d -x 90 -y 40 "env -u TMUX python3 -B $HELPER attach scr"
until_ok seen "1 90x40" || fail "scr not attached for the mirror"
viewer=$(outer display -p '#{pane_tty}')
: >"$WORK/osa"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%s/osa\ncase "$2" in *"set found"*) [ "$3" = "%s" ] && echo 42;; esac\nexit 0\n' \
  "$WORK" "$viewer" >"$WORK/osascript"
assert [ "$(helper mirror off)" = "off 1" ]
until_ok seen "0 90x40" || fail "the viewer stayed attached after mirror off"
asserts=$((asserts + 1))
until_ok closed || fail "no close of the viewer's window 42: $(tail -3 "$WORK/osa")"
asserts=$((asserts + 1))
assert grep -q '^scr ' <(helper ls)
assert [ "$(helper mirror)" = off ] && assert [ ! -e "$WORK/s/mirror" ]
assert [ "$(helper unview scr)" = 0 ]
# A window he closes on the Mac ends its chat (Egor 2026-11-11): closed() asks the app (a stub) for the chat on the
# session's pane and closes it, forced; not while another viewer looks, not within HIDDEN_FOR of unview (the apps
# hide windows), not when Terminal itself is gone (pgrep stub), and the hook runs it when a viewer's client goes.
cat >"$WORK/app.py" <<'APP'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"chats": [{"sid": "abc12345", "tty": open(sys.argv[2]).read().strip()}]}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        with open(sys.argv[3], "a") as f: f.write("%s %s\n" % (self.path, self.rfile.read(n).decode()))
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
s = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
APP
t display -p -t =scr: '#{pane_tty}' >"$WORK/app.tty"
python3 -B "$WORK/app.py" "$WORK/app.port" "$WORK/app.tty" "$WORK/app.posts" >/dev/null 2>&1 &
app_pid=$!
has_port() { [ -s "$WORK/app.port" ]; }
until_ok has_port || fail "the stub app did not start"
export CHAT_TMUX_APP="http://127.0.0.1:$(cat "$WORK/app.port")"
t set-option -t =scr: @hidden 1   # mirror off just hid it
assert [ "$(helper closed scr)" = kept ]   # pgrep: no Terminal
printf '#!/bin/sh\nexit 0\n' >"$WORK/pgrep"
t set-option -t =scr: @hidden "$(date +%s)"
assert [ "$(helper closed scr)" = hidden ]
t set-option -t =scr: @hidden 1
assert [ "$(helper closed scr)" = closed ]
assert grep -qxF '/api/chat/abc12345/close {"force": true}' "$WORK/app.posts"
assert [ "$(helper closed nosuch)" = gone ]
: >"$WORK/app.posts"
# The hook names a client, not a session: the session it showed is what the attach hooks wrote for its tty.
assert [ "$(helper closed --client /dev/ttys999)" = unknown ]   # nothing written for it: nothing ends
t set-option -g @viewer_ttys998 scr
assert [ "$(helper closed --client /dev/ttys998)" = closed ]
assert [ -z "$(t show-options -gqv @viewer_ttys998)" ]   # read once
: >"$WORK/app.posts"
helper hook   # the hook now carries this stub app's address
# Windows of other sessions close while scr has none: for a dead client tmux's #{session_name} names whichever session
# it finds best, often another chat (2026-11-11: a closed window would have ended a chat nobody was looking at).
for o in oa ob; do
  t new-session -d -s "$o" 'sleep 60'
  outer -f "$WORK/outer.conf" new-session -d -s "v$o" -x 90 -y 40 "env -u TMUX python3 -B $HELPER attach $o"
done
both() { [ "$(t list-clients -F '#{session_name}' | sort | tr '\n' ' ')" = "oa ob " ]; }
until_ok both || fail "oa and ob not attached: $(t list-clients -F '#{session_name}')"
asserts=$((asserts + 1))
outer kill-session -t =voa; sleep 0.5; outer kill-session -t =vob
gone_oa() { [ -z "$(t show-options -gq | grep '^@viewer_')" ]; }
until_ok gone_oa || fail "the hook read no viewer: $(t show-options -gq | grep '^@viewer_')"
asserts=$((asserts + 1))
sleep 1
assert [ ! -s "$WORK/app.posts" ]   # no chat ended for them
t kill-session -t =oa; t kill-session -t =ob
outer -f "$WORK/outer.conf" new-session -d -x 90 -y 40 "env -u TMUX python3 -B $HELPER attach scr"
until_ok seen "1 90x40" || fail "scr not attached for the hook"
assert [ "$(helper closed scr)" = viewed ]
outer kill-server   # his red button: the viewer's client goes
posted() { grep -qxF '/api/chat/abc12345/close {"force": true}' "$WORK/app.posts"; }
until_ok posted || fail "the hook closed nothing: $(cat "$WORK/app.posts")"
asserts=$((asserts + 1))
sleep 1   # the hook's command has ended: its answer must not cover a pane in view mode (a blank window, keys taken)
assert [ -z "$(t list-panes -a -F '#{pane_in_mode}' | grep -v '^0$')" ]
kill "$app_pid"; app_pid=
export CHAT_TMUX_APP="http://127.0.0.1:9"
unset CHAT_TMUX_OSASCRIPT CHAT_TMUX_OPEN

# End: by tty, by name; the server stays for the next chat.
helper end "$tty"
refute helper pane "$tty"
helper end scr
refute grep -q '^scr ' <(helper ls)
refute helper end scr 2>/dev/null
assert t list-sessions >/dev/null
for s in $(t list-sessions -F '#{session_name}'); do helper end "$s"; done
assert [ -z "$(helper ls)" ]   # a server with no session left lists nothing, no error
assert [ "$(python3 -B -c "import sys; sys.path.insert(0, '$ROOT/share'); import chat_tmux as c; print(' '.join(c.attach_argv('x')[1:3] + c.attach_argv('x')[-2:]))")" = "-S $CHAT_TMUX_SOCKET -t =x" ]
# The prompt box of a narrow pane (42 columns, a long chat name in its top rule: five dashes before it) is still read.
assert [ "$(python3 -B -c "import sys; sys.path.insert(0, '$ROOT/share'); import chat_tmux as c; print(repr(c.prompt_box('⏺ ok\n\n───── Rental project career requirements ─\n❯ hi\n' + '─' * 42 + '\n  status')))")" = "'hi'" ]

printf 'PASS: %s asserts; chat_tmux starts a chat line detached in a login shell on its own socket (UTF-8, tmux-256color, Homebrew PATH from a launchd-like start), finds its pane by tty, pastes bracketed with LF as CR and clears, sends a lone Escape, types literal text, maps a viewer'\''s tty to its pane and raises it or opens a new view, mirrors every chat in Terminal and back (a window per unviewed session; viewers detached and closed), reads the screen and its scrollback, names sessions c-<sid8> (-2 on a clash), keeps a detached viewer'\''s size, and ends one session leaving the server\n' "$asserts"
