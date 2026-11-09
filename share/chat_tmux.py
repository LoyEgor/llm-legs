#!/usr/bin/env python3
"""The chats' tmux server, the one way every caller reaches it (the Chats app, Hammerspoon through the CLI, the
scripts that open chats).

One private server on its own socket (~/.local/state/chats/tmux.sock, CHAT_TMUX_SOCKET in a test) with
share/chats.tmux.conf; one detached session per chat, `c-<first 8 of its session id>`, its pane a login shell
running the chat's line that stays a shell after the chat ends, as a Terminal tab does. A chat's tty stays its key:
`panes()` maps every pane's tty to its pane. Nothing here ever runs kill-server: every chat lives in that server.

CLI (the first word picks; a target is a pane id %N, a tty /dev/ttysN or a session name):
  chat_tmux.py open FILE|--line LINE [--name NAME] [--cwd DIR]  -> "<session> <pane> <tty>"
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
"""

import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys

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


def start(line, name=None, cwd=None):
    """A detached session whose pane runs `line` in a login shell (as Terminal's tab has: .zprofile and .zshrc),
    then stays a shell -> {session, pane, tty}. A name taken (a branch beside its live parent) gets -2, -3..."""
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
    tmux("start-server")
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


def end(word):
    """The session `word` (a name, or a pane's / tty's session) ends. Only after its chat exited: a live claude
    killed by SIGHUP never runs /exit."""
    if word.startswith(("%", "/dev/")):
        pane = target(word)
        word = tmux("display-message", "-p", "-t", pane, "#{session_name}").strip()
    tmux("kill-session", "-t", "=" + word)


def attach_argv(session):
    """The command a Terminal window runs to look at a chat; closing it only detaches."""
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
    that window only detaches: the chat runs on."""
    session = tmux("display-message", "-p", "-t", target(word), "#{session_name}").strip()
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
        handle.write("#!/bin/sh\nexec %s -B %s attach %s\n" % (
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
            print(got["session"], got["pane"], got["tty"])
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
        else:
            raise TmuxError("unknown verb %s" % verb)
    except (TmuxError, IndexError, ValueError) as error:
        print("chat_tmux: %s" % (error or "missing argument"), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
