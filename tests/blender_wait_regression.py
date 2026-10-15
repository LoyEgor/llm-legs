import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

if len(sys.argv) > 1:
    loader = importlib.machinery.SourceFileLoader('blender_render', str(ROOT / 'bin/blender-render'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    module.machine_probe.sysctl = lambda *args: ['1024']
    module.outside_blender = lambda: False
    code, text = module.blender('scene.py', [], sys.argv[1])
    print(text, flush=True)
    sys.exit(code != 0)

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    slot = work / 'state/slots/1'
    slot.mkdir(parents=True)
    (slot / 'pid').write_text(str(os.getpid()))
    blender = work / 'blender'
    blender.write_text('#!/bin/bash\nif { : >&3; } 2>/dev/null; then exit 42; fi\necho rendered\n')
    blender.chmod(0o755)
    env = dict(os.environ, BLENDER_BIN=str(blender), BLENDER_RENDER_DIR=str(work / 'state'),
               HARNESS_HOLDS_DIR=str(work / 'holds'), HARNESS_WAITS_DIR=str(work / 'waits'),
               SLOTS_POLL_S='0.05', SLOTS_ROOM_POLL_S='0.05')
    for action in ('term', 'kill', 'wrapper', 'render'):
        (slot / 'pid').write_text(str(os.getpid()))
        with (work / 'stderr').open('w+') as err:
            caller = subprocess.Popen(['bash', '-c', '"$@"; echo caller-survived', '_', sys.executable,
                                       __file__, str(work / 'render.log')], env=env, stdout=subprocess.PIPE,
                                      stderr=err, text=True, start_new_session=True)
            holder = None
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    holds = list((work / 'holds').glob('blender-*.json'))
                    if holds and 'waiting for a slot' in (work / 'stderr').read_text():
                        holder = json.loads(holds[0].read_text())['pid']
                        break
                    time.sleep(0.05)
                assert holder, (work / 'stderr').read_text()
                if action == 'wrapper':
                    parent = int(subprocess.check_output(['ps', '-o', 'ppid=', '-p', str(holder)]))
                    os.kill(parent, signal.SIGTERM)
                elif action != 'render':
                    os.killpg(os.getpgid(holder), signal.SIGKILL if action == 'kill' else signal.SIGTERM)
                else:
                    (slot / 'pid').unlink()
                    slot.rmdir()
                out, _ = caller.communicate(timeout=10)
                assert caller.returncode == 0 and 'caller-survived' in out, (caller.returncode, out)
                if action == 'render':
                    assert 'rendered' in out, out
                else:
                    assert 'rendered' not in out, out
                assert not list((work / 'holds').glob('blender-*.json'))
            finally:
                for pid in (holder, caller.pid):
                    if pid:
                        try:
                            os.killpg(os.getpgid(pid), signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                caller.wait(timeout=10)
        slot.mkdir(parents=True, exist_ok=True)
print('PASS: foreground wait, stderr, fd lifetime, group cancellation and hold cleanup')
