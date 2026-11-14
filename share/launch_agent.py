"""A LaunchAgent of one llm-legs tool: a wrapper named after the tool in ~/.local/libexec (Login Items show its name;
a checkout moved away makes it exit 0, not fail every tick) and the plist that runs it, loaded through launchctl;
and their removal. bin/system-doctor's and bin/tmux-upgrade's agents."""

import os
import plistlib
import shlex
import subprocess
import time


def write_wrapper(path, script):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w") as handle:
        handle.write("#!/usr/bin/env bash\nscript=%s\n[ -r \"$script\" ] || exit 0\nexec \"$script\" \"$@\"\n"
                     % shlex.quote(script))
    os.chmod(temporary, 0o755)
    os.replace(temporary, path)


def install(plist_path, plist, wrapper, script, launchctl="/bin/launchctl"):
    """The wrapper and the plist written, the job booted out and bootstrapped again -> None, or launchctl's error.
    A bootstrap racing the bootout's teardown fails ("Input/output error"): retried after a pause."""
    write_wrapper(wrapper, script)
    os.makedirs(os.path.dirname(plist_path), exist_ok=True)
    with open(plist_path, "wb") as handle:
        plistlib.dump(plist, handle)
    domain = "gui/%d" % os.getuid()
    subprocess.run([launchctl, "bootout", domain, plist_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for wait in (0, 0.5, 1, 2):
        time.sleep(wait)
        loaded = subprocess.run([launchctl, "bootstrap", domain, plist_path], stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True)
        if loaded.returncode == 0:
            return None
    return loaded.stderr.strip() or "launchctl bootstrap exit %d" % loaded.returncode


def uninstall(label, plist_path, wrapper, launchctl="/bin/launchctl", unload=True):
    """The plist and the wrapper removed, then the job booted out (`unload`): last, as a job removing itself is
    ended by its own bootout."""
    for path in (plist_path, wrapper):
        try:
            os.remove(path)
        except OSError:
            pass
    if unload:
        subprocess.run([launchctl, "bootout", "gui/%d/%s" % (os.getuid(), label)], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
