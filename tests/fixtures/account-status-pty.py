import errno
import os
import pty
import select
import signal
import sys
import time

keys = bytes.fromhex(sys.argv[1])
pid, master = pty.fork()
if pid == 0:
    os.environ['TERM'] = 'xterm-256color'
    os.execvp('bash', ['bash', sys.argv[2], 'status'])
output = bytearray()
sent = False
finished = False
try:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master], [], [], 0.1)
        if not readable:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            break
        if not chunk:
            break
        output.extend(chunk)
        if not sent and b'q/Esc exit' in output:
            os.write(master, keys)
            sent = True
    else:
        raise RuntimeError('account picker did not exit within 30 seconds')
    _, status = os.waitpid(pid, 0)
    finished = True
    sys.stdout.buffer.write(output)
    if not sent:
        raise RuntimeError('TTY status did not enter the shared picker')
    sys.exit(os.waitstatus_to_exitcode(status))
finally:
    if not finished:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
