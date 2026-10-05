import os, pty, select, signal, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
# Silence is load, never the end: reading stopped on it left a late prompt unanswered and both sides
# waiting forever (a suite slot held 4 h, 2026-10-05). Only the child's exit ends the read.
out, sent, status, deadline = b"", False, None, time.monotonic() + 600


def read_some():
    global out, sent
    try:
        data = os.read(fd, 1024)
    except OSError:
        return False
    out += data
    if not sent and b"[y/N]" in out:
        os.write(fd, sys.argv[1].encode() + b"\n")
        sent = True
    return bool(data)


while status is None:
    if select.select([fd], [], [], 1)[0]:
        if not read_some():
            break
        continue
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
        while select.select([fd], [], [], 0)[0] and read_some():
            pass
    elif time.monotonic() > deadline:
        sys.stderr.write("answer-pty: %s still running after 600 s, killed\n" % sys.argv[2])
        os.kill(pid, signal.SIGKILL)
if status is None:
    _, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(status))
