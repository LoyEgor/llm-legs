import os, pty, select, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
out, sent = b"", False
while select.select([fd], [], [], 10)[0]:
    try:
        data = os.read(fd, 1024)
    except OSError:
        break
    if not data:
        break
    out += data
    if not sent and b"[y/N]" in out:
        os.write(fd, sys.argv[1].encode() + b"\n")
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(status))
