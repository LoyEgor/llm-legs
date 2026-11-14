#!/usr/bin/env python3
"""The chats' tmux server, the one way every caller reaches it (the Chats app, Hammerspoon through the CLI, the
scripts that open chats).

One private server on its own socket (~/.local/state/chats/tmux.sock, CHAT_TMUX_SOCKET in a test) with
share/chats.tmux.conf; one detached session per chat, `c-<first 8 of its session id>`, its pane a login shell
running the chat's line that stays a shell after the chat ends, as a Terminal tab does. A chat's tty stays its key:
`panes()` maps every pane's tty to its pane. Nothing here ever runs kill-server: every chat lives in that server.

CLI (the first word picks; a target is a pane id %N, a tty /dev/ttysN or a session name):
  chat_tmux.py open FILE|--line LINE [--name NAME] [--cwd DIR]  -> "<session> <pane> <tty>"
               ... --view                                       -> "<session> <pane> <tty> opened" (its view up too)
  chat_tmux.py ls                                               -> "<session> <pane> <tty> <pid> <WxH> <attached>"
  chat_tmux.py pane TTY                                         -> "<pane>" (exit 1: no pane on it)
  chat_tmux.py capture TARGET [--history LINES]                 -> the screen (with that much scrollback)
  chat_tmux.py paste TARGET [--no-enter] <TEXT on stdin>        -> a bracketed paste, then Enter
  chat_tmux.py keys TARGET KEY...                               -> tmux key names (Escape, Enter, Up, C-u, S-Enter)
  chat_tmux.py keys TARGET --literal TEXT                       -> TEXT typed as is
  chat_tmux.py end TARGET                                       -> its session ends
  chat_tmux.py attach SESSION                                   -> exec's a client on it (a Terminal window's command)
  chat_tmux.py client TTY                                       -> "<pane> <pane tty>" a client on TTY shows (exit 1: none)
  chat_tmux.py view TARGET                                      -> its chat on the Mac: "front" (a viewer's tab raised)
                                                                   or "opened" (a new Terminal window attached)
  chat_tmux.py unview TARGET                                    -> its viewers detached, their windows closed: "<n>"
  chat_tmux.py closed SESSION                                   -> a viewer left it (the hook): its chat ends unless hidden
  chat_tmux.py closed --client TTY                              -> the same for the session that client showed
  chat_tmux.py hook                                             -> sets that hook on the running server
  chat_tmux.py size COLSxROWS                                   -> every session no viewer shows at that size from
                                                                   now on: "<n resized>" (FIXED)
  chat_tmux.py mirror [on|off]                                  -> "on"|"off" (with on/off: "<state> <windows>")
"""

import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONF = os.path.join(HERE, "chats.tmux.conf")
SOCKET = os.environ.get("CHAT_TMUX_SOCKET") or os.path.expanduser("~/.local/state/chats/tmux.sock")
# A launchd starter's PATH has no Homebrew: the tmux binary is looked for there too.
TMUX = os.environ.get("CHAT_TMUX_BIN") or shutil.which("tmux") or "/opt/homebrew/bin/tmux"
BASE_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# paste-buffer -p turns each LF into CR unless -r is given. Claude Code 2.1.319 takes both inside a bracketed paste
# as one message with a new line (a real chat, 2026-11-09: "a\nform cr" and "a\nform lf" alike in its transcript).
PASTE_RAW = False
NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
SID_IN_LINE = re.compile(r"--(?:session-id|resume)[= ]['\"]?([0-9a-fA-F]{8})-[0-9a-fA-F-]{27}")
PANE_FIELDS = "#{pane_tty}\t#{pane_id}\t#{session_name}\t#{pane_pid}\t#{window_width}x#{window_height}\t" \
              "#{session_attached}"


class TmuxError(Exception):
    pass


# What a Terminal tab's login shell starts from (launchd's user session) is all a tmux client passes on: the client
# that starts the server gives it its environment, every pane inherits that, and a caller's own would leak into each
# chat (a server started from inside a chat registered the next one as sdk-cli, a worker; its CLAUDE_CONFIG_DIR
# would pick another profile). The login shell builds the rest as in a tab. TERM: an attaching client draws with it
# (a pane's own is default-terminal).
KEPT_ENV = ("HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "ZDOTDIR",
            "LANG", "LC_ALL", "LC_CTYPE", "TERM")


def env():
    """The tmux client's environment: KEPT_ENV only, Homebrew on PATH (a launchd starter has none), UTF-8."""
    out = {key: os.environ[key] for key in KEPT_ENV if os.environ.get(key)}
    out["PATH"] = BASE_PATH
    if "UTF-8" not in (out.get("LC_ALL") or out.get("LC_CTYPE") or out.get("LANG") or ""):
        out["LANG"] = "en_US.UTF-8"
    return out


def argv(*args):
    return [TMUX, "-S", SOCKET, "-f", CONF, "-u"] + list(args)


def tmux(*args, data=None, timeout=5):
    """One tmux command (a `;` word chains more) -> its stdout; TmuxError with tmux's own words on failure."""
    os.makedirs(os.path.dirname(SOCKET), mode=0o700, exist_ok=True)
    try:
        done = subprocess.run(argv(*args), input=data, capture_output=True, timeout=timeout, env=env(),
                              stdin=None if data is not None else subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise TmuxError(str(error)[:200])
    if done.returncode != 0:
        raise TmuxError((done.stderr or done.stdout).decode("utf-8", "replace").strip()[:200] or
                        "tmux exit %d" % done.returncode)
    return done.stdout.decode("utf-8", "replace")


def running():
    """Whether the server's socket is there: with none, no chat runs in tmux and nothing is asked."""
    return os.path.exists(SOCKET)


def panes():
    """tty -> {pane, session, pid, size, attached} of every pane; {} with no server."""
    if not running():
        return {}
    try:
        out = tmux("list-panes", "-a", "-F", PANE_FIELDS)
    except TmuxError as error:  # no server, or one with no session left
        if any(word in str(error) for word in ("no server running", "error connecting", "no current target")):
            return {}
        raise
    found = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 6 and parts[0].startswith("/dev/"):
            found[parts[0]] = {"pane": parts[1], "session": parts[2], "pid": int(parts[3] or 0), "size": parts[4],
                               "attached": int(parts[5] or 0)}
    return found


def pane_of(tty):
    """The pane id running on `tty`, or None (a Terminal tab's tty, or no server)."""
    hit = panes().get(tty)
    return hit["pane"] if hit else None


def target(word):
    """A pane id, a tty or a session name -> a pane target (`=` pins a session name exactly, `:` its active pane)."""
    if word.startswith("%"):
        return word
    if word.startswith("/dev/"):
        pane = pane_of(word)
        if not pane:
            raise TmuxError("no tmux pane on %s" % word)
        return pane
    return "=" + word + ":"


def session_name(line):
    """The session a chat's line gets: c-<the first 8 of the session it names>, else c-<8 random hex>."""
    m = SID_IN_LINE.search(line or "")
    return "c-" + (m.group(1).lower() if m else secrets.token_hex(4))


def start(line, name=None, cwd=None, size=None):
    """A detached session whose pane runs `line` in a login shell (as Terminal's tab has: .zprofile and .zshrc),
    then stays a shell -> {session, pane, tty}. A name taken (a branch beside its live parent) gets -2, -3...
    size (cols, rows): the server's FIXED size from now on (a server this start brings up has none), its own too."""
    taken = {p["session"] for p in panes().values()}
    base = name or session_name(line)
    if not NAME_RE.match(base):
        raise TmuxError("bad session name %r" % base)
    pick, n = base, 1
    while pick in taken:
        n += 1
        pick = "%s-%d" % (base, n)
    command = "zsh -lic %s" % shlex.quote(line + "; exec zsh -l")
    # The server keeps the argv of the client that started it: started by a new-session, it would show this chat's
    # --session-id for good, and `pgrep -f -- '--session-id <sid>'` (night-run's liveness) would never see it end.
    tmux("start-server", *(fixing(*size) if size else ()))
    hook()
    out = tmux("new-session", "-d", "-s", pick, "-c", cwd or os.path.expanduser("~"), "-P", "-F",
               "#{pane_id} #{pane_tty}", command)
    pane, _, tty = out.strip().partition(" ")
    return {"session": pick, "pane": pane, "tty": tty}


def paste(pane, text, enter=True, clear=0):
    """`text` into the pane as one bracketed paste (the pane's app asked for them: Claude Code's prompt does),
    after `clear` input lines are emptied (Ctrl+U, Backspace each), then Enter: one tmux call, no pasteboard."""
    buf = "chat-%d-%s" % (os.getpid(), secrets.token_hex(3))
    args = []
    if clear:
        args += ["send-keys", "-t", pane, "-N", str(clear), "C-u", "BSpace", ";"]
    args += ["load-buffer", "-b", buf, "-", ";", "paste-buffer", "-p", "-d"] + (["-r"] if PASTE_RAW else []) + \
            ["-b", buf, "-t", pane]
    if enter:
        args += [";", "send-keys", "-t", pane, "Enter"]
    tmux(*args, data=text.encode("utf-8"))


def keys(pane, *names, literal=False, repeat=1):
    """tmux key names into the pane (Escape alone is one key: nothing is appended); literal: text typed as is."""
    tmux("send-keys", "-t", pane, *(["-N", str(repeat)] if repeat > 1 else []), *(["-l"] if literal else []),
         *names)


def capture(pane, history=0):
    """The pane's screen as plain text, with up to `history` lines of scrollback above it."""
    return tmux("capture-pane", "-p", "-t", pane, *(["-S", str(-history)] if history else []))


# Claude Code's own children, not a chat's work: a working turn's sleep guard and the hooks' helpers (the Chats app's
# OWN_KID, chats-app share/pages/app.py, is the same rule). RULE: its prompt box's frame (the app's RULE_RE).
OWN_KID = re.compile(r"^(\S*/)?caffeinate\s|/\.claude[^/\s]*/hooks/|/claude-setup/hooks/")
# A renamed chat's name sits in the top rule: in a narrow pane a long one leaves few dashes before it (5 at 42 columns)
# or none (38: the name cut, one dash after it).
RULE = re.compile(r"^\s*(?:─{8,}|(?:─+ )?\S.* ─+)\s*$")


def prompt_box(screen):
    """The text in a Claude Code screen's prompt box ('' when empty), or None when the screen shows none (a question
    or a menu on it): the chats-app input_box rule."""
    lines = (screen or "").splitlines()
    rules = [k for k, line in enumerate(lines) if RULE.match(line)]
    for low, high in zip(reversed(rules[:-1]), reversed(rules[1:])):
        if high - low < 40 and re.match(r"^\s*❯", lines[low + 1]):
            return re.sub(r"^❯\s*", "", " ".join(line.strip() for line in lines[low + 1:high])).strip()
    return None


def end(word):
    """The session `word` (a name, or a pane's / tty's session) ends. Only after its chat exited: a live claude
    killed by SIGHUP never runs /exit. Its viewers' windows close rather than stay on "[exited]" (close_ended)."""
    if word.startswith(("%", "/dev/")):
        pane = target(word)
        word = tmux("display-message", "-p", "-t", pane, "#{session_name}").strip()
    ttys = tmux("list-clients", "-t", "=" + word, "-F", "#{client_tty}").split()
    windows = viewer_windows(ttys) if ttys else []
    tmux("kill-session", "-t", "=" + word)
    if windows:
        close_ended(windows)


# A viewer (`view`'s window, one tab) of a session that ends (the app's close or move) would stay on "[exited]". Its
# window is found while its tab still shows the client, and closed once that tab's shell has ended (the .command's
# exit): a tab whose shell runs on (`chats` attached in a tab of his) is never closed.
VIEWER_WINDOWS = """on run argv
set found to ""
tell application id "com.apple.Terminal"
repeat with w in windows
try
if (count of tabs of w) is 1 and argv contains (tty of tab 1 of w as text) then set found to found & (id of w) & " "
end try
end repeat
end tell
return found
end run"""
# A one-tab window with nothing left in it: a viewer whose client ended without its window closing (the tmux server
# crashed under it, 2026-11-13 22:43: an attach that fails exits non-zero, which Terminal's "close if the shell exited
# cleanly" keeps on screen). Nothing runs there, so nothing is lost when mirror off closes it.
DEAD_WINDOWS = """on run argv
set dead to ""
tell application id "com.apple.Terminal"
repeat with w in windows
try
if (count of tabs of w) is 1 and (count of (processes of tab 1 of w)) is 0 then set dead to dead & (id of w) & " "
end try
end repeat
end tell
return dead
end run"""
CLOSE_ENDED = """on run argv
tell application id "com.apple.Terminal"
repeat 12 times
set waiting to 0
repeat with i in argv
try
set w to window id ((contents of i) as integer)
if (count of (processes of tab 1 of w)) is 0 then
close w
else
set waiting to waiting + 1
end if
end try
end repeat
if waiting is 0 then return
delay 0.25
end repeat
end tell
end run"""


def viewer_windows(ttys):
    """Terminal's one-tab windows on these client ttys -> their window ids."""
    try:
        done = subprocess.run([OSASCRIPT, "-e", VIEWER_WINDOWS, *ttys], capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [w for w in done.stdout.decode("utf-8", "replace").split() if w.isdigit()]


def close_ended(windows):
    """Those windows close once their shells have ended, within 3 s, without holding the caller up."""
    try:
        subprocess.Popen([OSASCRIPT, "-e", CLOSE_ENDED, *windows], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def attach_argv(session):
    """The command a Terminal window runs to look at a chat; closing it ends the chat (closed())."""
    return argv("attach-session", "-t", "=" + session)


def client(tty):
    """A tmux client on `tty` (a Terminal tab looking at a chat) -> (the pane it shows, that pane's tty), or None:
    Better Terminal reads the chat's foreground there, claude-chat-switch --front types there."""
    if not running():
        return None
    try:
        out = tmux("list-clients", "-F", "#{client_tty}\t#{pane_id}\t#{pane_tty}")
    except TmuxError:
        return None
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0] == tty:
            return parts[1], parts[2]
    return None


# A tab is selected by its tty with Terminal's AppleScript (Automation, granted to Hammerspoon, pagesd and Terminal
# itself); a new window is a .command opened by Launch Services, which needs no grant.
FRONT_TAB = """on run argv
tell application id "com.apple.Terminal"
repeat with w in windows
repeat with t in tabs of w
if (tty of t as text) is (item 1 of argv) then
try
set miniaturized of w to false
end try
set selected of t to true
set index of w to 1
activate
return "front"
end if
end repeat
end repeat
end tell
return ""
end run"""
OSASCRIPT = os.environ.get("CHAT_TMUX_OSASCRIPT") or "/usr/bin/osascript"
OPEN = os.environ.get("CHAT_TMUX_OPEN") or "/usr/bin/open"


def view(word):
    """Its chat on the Mac (Open on Mac, the menubar, the `chats` picker): the Terminal tab of a client already on
    `word`'s session comes to the front, else a new Terminal window attaches to it -> "front" | "opened". Closing
    that window ends the chat (closed(), the hook)."""
    session = tmux("display-message", "-p", "-t", target(word), "#{session_name}").strip()
    hook()
    for tty in tmux("list-clients", "-t", "=" + session, "-F", "#{client_tty}").split():
        try:
            done = subprocess.run([OSASCRIPT, "-e", FRONT_TAB, tty], capture_output=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if done.returncode == 0 and done.stdout.strip() == b"front":
            return "front"
    folder = os.path.join(os.path.dirname(SOCKET), "view")
    os.makedirs(folder, mode=0o700, exist_ok=True)
    path = os.path.join(folder, session + ".command")
    with open(path, "w", encoding="utf-8") as handle:
        # No exec, and exit 0: however the client ends (a detach, the server gone), the shell exits cleanly and
        # Terminal closes the window instead of leaving a dead one behind.
        handle.write("#!/bin/sh\n%s -B %s attach %s\nexit 0\n" % (
            shlex.quote(sys.executable or "/usr/bin/python3"), shlex.quote(os.path.abspath(__file__)),
            shlex.quote(session)))
    os.chmod(path, 0o700)
    try:
        done = subprocess.run([OPEN, "-a", "Terminal", path], capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise TmuxError("open: %s" % str(error)[:200])
    if done.returncode != 0:
        raise TmuxError("open: %s" % (done.stderr.decode("utf-8", "replace").strip()[:200] or done.returncode))
    return "opened"


# Terminal windows for every chat (Egor 2026-11-09: while the apps are debugged he wants the chats in Terminal too, to
# compare; else none, the apps alone, nothing redrawn twice): a flag file beside the socket, read by the Chats app's
# server (a chat it starts gets its window when on) and set from either app.
MIRROR = os.path.join(os.path.dirname(SOCKET), "mirror")


def mirrored():
    return os.path.exists(MIRROR)


# A window he closes on the Mac ends its chat (Egor 2026-11-11: «красная кнопка — значит прям удалить»); hiding and
# showing windows is the apps' (unview, mirror off), which mark the session first. Terminal quitting or crashing
# takes every viewer at once and ends no chat: closed() waits CLOSE_GRACE and asks whether Terminal still runs.
HIDDEN = "@hidden"  # session option: when unview last detached its viewers (epoch s)
HIDDEN_FOR = 15
CLOSE_GRACE = float(os.environ.get("CHAT_TMUX_CLOSE_GRACE") or 3)
APP = os.environ.get("CHAT_TMUX_APP") or "http://127.0.0.1:4791"
PGREP = os.environ.get("CHAT_TMUX_PGREP") or "/usr/bin/pgrep"


VIEWER = "@viewer_"  # global option per client tty (its basename): the session that client last showed


def hook():
    """The server runs `closed --client <tty>` each time a client leaves (set again on every start and view: the live
    server predates the hook). Which session the client showed is read from VIEWER, written by the attach hooks: a
    client that died (the window closed) leaves #{hook_session_name} empty, and #{session_name} then names whichever
    session tmux finds best, often another chat (tmux 3.7b). Its socket and stubs ride in the command, as the
    server's env has none. Every answer goes nowhere: run-shell shows a command's output (and a failing exit) in view
    mode over the current pane, which blanked a live chat's window and took his keys."""
    pinned = " ".join("%s=%s" % (k, shlex.quote(os.environ[k])) for k in
                      ("CHAT_TMUX_APP", "CHAT_TMUX_PGREP", "CHAT_TMUX_CLOSE_GRACE") if os.environ.get(k))
    quiet = " >/dev/null 2>&1 || true"
    line = "%s CHAT_TMUX_SOCKET=%s %s %s closed --client '#{hook_client}'" % (
        pinned, shlex.quote(SOCKET), shlex.quote(sys.executable), shlex.quote(os.path.abspath(__file__)))
    saw = "%s -S %s set-option -g %s#{b:client_tty} '#{session_name}'" % (
        shlex.quote(TMUX), shlex.quote(SOCKET), VIEWER)
    for name in ("client-attached", "client-session-changed"):
        tmux("set-hook", "-g", name, "run-shell -b %s" % shlex.quote(saw + quiet))
    try:  # viewers from before it; a server with no session yet has none (tmux: "no current target")
        viewers = tmux("list-clients", "-F", "#{client_tty}\t#{session_name}").splitlines()
    except TmuxError:
        viewers = []
    for row in viewers:
        tty, _, session = row.partition("\t")
        if tty and session:
            tmux("set-option", "-g", VIEWER + os.path.basename(tty), session)
    tmux("set-hook", "-g", "client-detached", "run-shell -b %s" % shlex.quote(line.strip() + quiet))


def viewed_by(tty):
    """The session the client on `tty` showed (VIEWER), forgotten as it is read; "" when none was written."""
    name = VIEWER + os.path.basename(tty)
    try:
        session = tmux("show-options", "-gqv", name).strip()
        if session:
            tmux("set-option", "-gu", name)
    except TmuxError:
        return ""
    return session


def closed(session):
    """A client left `session` -> what became of its chat: "gone" (the session ended first: the app's close, a
    move), "hidden" (unview's), "viewed" (another viewer on it), "kept" (Terminal itself went), "unknown" (no live
    chat the app knows on its pane), else the app's close answer: "closed" or "refused <code>". The close is the
    app's End with force: a working chat's turn is interrupted, then /exit, then the session and its window go."""
    def state():
        hidden = tmux("show-options", "-qv", "-t", "=" + session + ":", HIDDEN).strip()
        if hidden.isdigit() and time.time() - int(hidden) < HIDDEN_FOR:
            return "hidden"
        return "viewed" if tmux("list-clients", "-t", "=" + session, "-F", "#{client_tty}").split() else None
    try:
        seen = state()
        if seen:
            return seen
        time.sleep(CLOSE_GRACE)
        if subprocess.run([PGREP, "-qx", "Terminal"]).returncode != 0:
            return "kept"
        seen = state()
        if seen:
            return seen
        tty = tmux("display-message", "-p", "-t", "=" + session + ":", "#{pane_tty}").strip()
    except TmuxError:
        return "gone"
    try:
        with urllib.request.urlopen(APP + "/api/chats", timeout=10) as answer:
            rows = json.load(answer).get("chats") or []
        sid = next((r.get("sid") for r in rows if r.get("tty") == tty and r.get("sid")), None)
        if not sid:
            return "unknown"
        ask = urllib.request.Request(APP + "/api/chat/%s/close" % sid, data=b'{"force": true}', method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(ask, timeout=120) as answer:
            return "closed" if answer.status == 200 else "refused %d" % answer.status
    except urllib.error.HTTPError as error:
        return "refused %d" % error.code
    except (OSError, ValueError):
        return "unknown"


def unview(word):
    """`word`'s session loses its viewers: each tmux client on it detaches, and a one-tab Terminal window it ran in
    closes once its shell has ended (close_ended; a tab whose shell runs on stays). The chat runs on -> clients."""
    session = tmux("display-message", "-p", "-t", target(word), "#{session_name}").strip()
    ttys = tmux("list-clients", "-t", "=" + session, "-F", "#{client_tty}").split()
    if not ttys:
        return 0
    windows = viewer_windows(ttys)
    tmux("set-option", "-t", "=" + session + ":", HIDDEN, str(int(time.time())))  # closed() leaves this chat running
    tmux("detach-client", "-s", "=" + session)
    fit(session)
    if windows:
        close_ended(windows)
    return len(ttys)


# A chat no viewer shows keeps one size (Egor 2026-11-14: "if I am not at the computer and the display of the tmux
# terminal windows is off, give them some fixed width, so that in the chat UI it looks normal and does not go now
# wide, now narrow ... If the display of terminals is on, do not change the real terminals"). FIXED, set by whoever
# owns the number (the Chats app, from its tokens' behaviour.term), is that size and the server's default-size (a new
# detached session's); with none set nothing is resized and a window keeps its last viewer's size. Applied at events
# only: a start, unview, a viewer leaving (closed), the owner's own start (fixed_size). A window a client shows, or
# one at that size already, is never resized (a resize makes Claude Code redraw), and a viewer that attaches sizes
# the window to its own at once (window-size latest: no `manual` is left behind).
FIXED = "@fixed_size"


def fixing(cols, rows):
    """The tmux words, to chain after a command, that make cols x rows FIXED and the new sessions' size."""
    cols, rows = int(cols), int(rows)
    if cols < 1 or rows < 1:
        raise TmuxError("bad size %sx%s" % (cols, rows))
    size = "%dx%d" % (cols, rows)
    return (";", "set-option", "-g", "default-size", size, ";", "set-option", "-g", FIXED, size)


def resize(session, size):
    """`session`'s window to `size` ("COLSxROWS") in one step of the server: a client that attached since the caller
    looked keeps its window's size. The resize's window-size `manual` is unset at once: the next viewer sizes it."""
    cols, _, rows = size.partition("x")
    if not (cols.isdigit() and rows.isdigit()):
        return False
    win = "=%s:" % session
    tmux("if-shell", "-F", "-t", win,
         "#{&&:#{==:#{session_attached},0},#{!=:#{window_width}x#{window_height},%s}}" % size,
         "resize-window -t %s -x %s -y %s ; set-option -wu -t %s window-size" % (win, cols, rows, win))
    return True


def fit(session):
    """`session`'s window to FIXED when no client shows it and its size is another -> whether it asked a resize (one
    look, nothing more when it is viewed, already that size, gone, or no size is set)."""
    try:
        seen = tmux("display-message", "-p", "-t", "=" + session + ":",
                    "#{session_attached} #{window_width}x#{window_height} #{%s}" % FIXED).split()
        return len(seen) == 3 and seen[0] == "0" and seen[1] != seen[2] and resize(session, seen[2])
    except TmuxError:
        return False


def fixed_size(cols, rows):
    """cols x rows FIXED from now on, and every session no viewer shows at it now -> how many it resized; with no
    server running, 0 and nothing started (the owner's next start() sets it)."""
    found = panes()
    if not found:
        return 0
    words = fixing(cols, rows)
    tmux(*words[1:])
    want = words[-1]
    done = 0
    for session in sorted({p["session"] for p in found.values() if not p["attached"] and p["size"] != want}):
        try:
            done += resize(session, want)
        except TmuxError:  # gone since the look: the rest still go
            continue
    return done


def mirror(on):
    """Terminal windows for every chat on (each session with no viewer gets a window now) or off (every viewer's
    window closes, and so does every window a viewer left with nothing in it) -> how many windows it opened or closed. A session that fails is skipped: the rest still go."""
    if on:
        os.makedirs(os.path.dirname(MIRROR), mode=0o700, exist_ok=True)
        with open(MIRROR, "a", encoding="utf-8"):
            pass
    elif mirrored():
        os.remove(MIRROR)
    sessions = {}
    for p in panes().values():
        sessions[p["session"]] = sessions.get(p["session"], 0) + p["attached"]
    done = 0
    for session, attached in sorted(sessions.items()):
        try:
            if on and not attached:
                done += view(session) == "opened"
            elif not on and attached:
                done += unview(session)
        except TmuxError:
            continue
    if not on:
        try:
            listed = subprocess.run([OSASCRIPT, "-e", DEAD_WINDOWS], capture_output=True, timeout=10)
            dead = [w for w in listed.stdout.decode("utf-8", "replace").split() if w.isdigit()]
        except (OSError, subprocess.TimeoutExpired):
            dead = []
        if dead:
            close_ended(dead)
        done += len(dead)
    return done


def main(args):
    if not args:
        print(__doc__.split("CLI")[1].strip(), file=sys.stderr)
        return 2
    verb, rest = args[0], args[1:]
    opt = lambda flag: rest[rest.index(flag) + 1] if flag in rest[:-1] else None
    try:
        if verb == "open":
            line = opt("--line")
            if line is None:
                if not rest or not os.path.isfile(rest[0]):
                    raise TmuxError("open FILE: no such file")
                with open(rest[0], encoding="utf-8", errors="replace") as handle:
                    named = session_name(handle.read(1 << 16))
                line, name = shlex.quote(os.path.abspath(rest[0])), opt("--name") or named
            else:
                name = opt("--name")
            got = start(line, name, opt("--cwd"))
            if "--view" not in rest:
                print(got["session"], got["pane"], got["tty"])
                return 0
            try:
                shown = view(got["pane"])
            except TmuxError as error:  # the chat runs all the same; its view can be asked for again
                print("chat_tmux: view: %s" % error, file=sys.stderr)
                shown = "unshown"
            print(got["session"], got["pane"], got["tty"], shown)
        elif verb == "ls":
            for tty, p in sorted(panes().items(), key=lambda kv: kv[1]["session"]):
                print(p["session"], p["pane"], tty, p["pid"], p["size"], p["attached"])
        elif verb == "pane":
            pane = pane_of(rest[0]) if rest else None
            if not pane:
                return 1
            print(pane)
        elif verb == "capture":
            sys.stdout.write(capture(target(rest[0]), int(opt("--history") or 0)))
        elif verb == "paste":
            paste(target(rest[0]), sys.stdin.read(), enter="--no-enter" not in rest)
        elif verb == "keys":
            literal = rest[1:2] == ["--literal"]
            keys(target(rest[0]), *rest[2 if literal else 1:], literal=literal)
        elif verb == "end":
            end(rest[0])
        elif verb == "attach":
            os.execvpe(TMUX, attach_argv(rest[0]), env())
        elif verb == "client":
            shown = client(rest[0])
            if not shown:
                return 1
            print(*shown)
        elif verb == "view":
            print(view(rest[0]))
        elif verb == "unview":
            print(unview(rest[0]))
        elif verb == "closed":
            session = viewed_by(rest[1]) if rest[0] == "--client" else rest[0]
            became = closed(session) if session else "unknown"
            if session and became not in ("gone", "closed", "viewed"):
                fit(session)  # left with no viewer: its fixed size
            print(became)
        elif verb == "size":
            cols, _, rows = rest[0].partition("x")
            print(fixed_size(cols, rows))
        elif verb == "hook":
            hook()
        elif verb == "mirror":
            if rest and rest[0] not in ("on", "off"):
                raise TmuxError("mirror on|off")
            if rest:
                print(rest[0], mirror(rest[0] == "on"))
            else:
                print("on" if mirrored() else "off")
        else:
            raise TmuxError("unknown verb %s" % verb)
    except (TmuxError, IndexError, ValueError) as error:
        print("chat_tmux: %s" % (error or "missing argument"), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
