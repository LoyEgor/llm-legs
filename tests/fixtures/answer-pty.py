import os, pty, select, signal, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
# Silence is load, never the end: reading stopped on it left a late prompt unanswered and both sides
# waiting forever (a suite slot held 4 h, 2026-10-05). Only the child's exit ends the read.
# The deadline holds in every state, a chatty child's and one that closed the pty but runs on included.
limit = float(os.environ.get("ANSWER_PTY_DEADLINE_S") or 600)
out, sent, status, eof, deadline = b"", False, None, False, time.monotonic() + limit


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
    if time.monotonic() > deadline:
        sys.stderr.write("answer-pty: %s still running after %d s, killed\n" % (sys.argv[2], limit))
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        break
    if eof:
        time.sleep(0.2)
    elif select.select([fd], [], [], 1)[0]:
        eof = not read_some()
        continue
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
        while not eof and select.select([fd], [], [], 0)[0] and read_some():
            pass
sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(status))
