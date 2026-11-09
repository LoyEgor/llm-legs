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
OUTER="$WORK/outer.sock"
TMUX_BIN=$(command -v tmux) || { printf 'SKIP: no tmux\n'; exit 0; }
t() { "$TMUX_BIN" -S "$CHAT_TMUX_SOCKET" "$@"; }
outer() { "$TMUX_BIN" -S "$OUTER" "$@"; }
cleanup() {
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
helper end opv
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

printf 'PASS: %s asserts; chat_tmux starts a chat line detached in a login shell on its own socket (UTF-8, tmux-256color, Homebrew PATH from a launchd-like start), finds its pane by tty, pastes bracketed with LF as CR and clears, sends a lone Escape, types literal text, maps a viewer'\''s tty to its pane and raises it or opens a new view, reads the screen and its scrollback, names sessions c-<sid8> (-2 on a clash), keeps a detached viewer'\''s size, and ends one session leaving the server\n' "$asserts"
