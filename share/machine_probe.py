"""Unprivileged machine probes the Harness and System doctors share. Each command resolves through
SYSTEM_DOCTOR_<NAME> first, so a test replaces it with a fixture; SYSTEM_DOCTOR_HOST_TICKS names a file
holding the four host CPU tick counters (user system idle nice) in place of host_statistics."""

import ctypes
import os
import subprocess

COMMANDS = {"ps": "/bin/ps", "vm_stat": "/usr/bin/vm_stat", "sysctl": "/usr/sbin/sysctl", "ioreg": "/usr/sbin/ioreg",
            "df": "/bin/df", "last": "/usr/bin/last", "du": "/usr/bin/du", "diskutil": "/usr/sbin/diskutil",
            "launchctl": "/bin/launchctl"}


def command(name):
    return os.environ.get("SYSTEM_DOCTOR_" + name.upper()) or COMMANDS[name]


def spawn(name, args, timeout=10):
    """(pid, stdout) of one probe run; the pid is the system's newest at that moment, the births counter."""
    try:
        process = subprocess.Popen([command(name)] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   stdin=subprocess.DEVNULL, text=True, env=dict(os.environ, LC_ALL="C"))
    except OSError:
        return None, ""
    try:
        out, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        return process.pid, ""
    return process.pid, out or ""


def run(name, args, timeout=10):
    return spawn(name, args, timeout)[1]


def sysctl(*names):
    out = run("sysctl", ["-n"] + list(names), timeout=5).splitlines()
    return (out + [""] * len(names))[:len(names)]


def spawn_pid():
    process = subprocess.Popen(["/usr/bin/true"])
    process.wait()
    return process.pid


def host_ticks():
    fixture = os.environ.get("SYSTEM_DOCTOR_HOST_TICKS")
    if fixture:
        try:
            with open(fixture) as handle:
                return [int(word) for word in handle.read().split()[:4]]
        except (OSError, ValueError):
            return None
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.dylib")
        lib.mach_host_self.restype = ctypes.c_uint
        values = (ctypes.c_uint * 4)()
        count = ctypes.c_uint(4)
        if lib.host_statistics(lib.mach_host_self(), 3, ctypes.byref(values), ctypes.byref(count)):
            return None
        return list(values)
    except (OSError, AttributeError):
        return None
