"""Unprivileged machine probes the Harness and System doctors share. Each command resolves through
SYSTEM_DOCTOR_<NAME> first, so a test replaces it with a fixture; SYSTEM_DOCTOR_HOST_TICKS names a file
holding the four host CPU tick counters (user system idle nice) in place of host_statistics, SYSTEM_DOCTOR_PROCS
a JSON {frames: [[pid...]...], procs: {pid: [ppid, uid, start, args]}} in place of libproc's process table and
SYSTEM_DOCTOR_RUSAGE a JSON {pid: [footprint, read, written, idle wakeups]} in place of proc_pid_rusage."""

import ctypes
import json
import os
import signal
import subprocess
import threading

COMMANDS = {"ps": "/bin/ps", "vm_stat": "/usr/bin/vm_stat", "sysctl": "/usr/sbin/sysctl", "ioreg": "/usr/sbin/ioreg",
            "df": "/bin/df", "last": "/usr/bin/last", "du": "/usr/bin/du", "diskutil": "/usr/sbin/diskutil",
            "launchctl": "/bin/launchctl", "log": "/usr/bin/log"}


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


def stream(name, args, budget_s, max_lines, on_line):
    """Feeds each stdout line of one probe run to on_line, killing it past budget_s or max_lines; returns
    (lines read, None | 'time' | 'lines' | 'failed')."""
    try:
        process = subprocess.Popen([command(name)] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   stdin=subprocess.DEVNULL, text=True, errors="replace", env=dict(os.environ, LC_ALL="C"),
                                   start_new_session=True)
    except OSError:
        return 0, "failed"
    expired = threading.Event()

    def kill():
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass

    def expire():
        expired.set()
        kill()

    timer = threading.Timer(budget_s, expire)
    timer.start()
    count, cut = 0, None
    try:
        for line in process.stdout:
            if count >= max_lines:
                cut = "lines"
                kill()
                break
            count += 1
            on_line(line.rstrip("\n"))
    except BaseException:
        kill()
        raise
    finally:
        timer.cancel()
        process.stdout.close()
        process.wait()
    if expired.is_set():
        cut = "time"
    elif cut is None and process.returncode:
        cut = "failed"
    return count, cut


def low_priority():
    """Nice 10 at least and throttled disk I/O for this process and the probes it starts."""
    try:
        os.setpriority(os.PRIO_PROCESS, 0, max(10, os.getpriority(os.PRIO_PROCESS, 0)))
    except (OSError, AttributeError):
        pass
    try:
        ctypes.CDLL("/usr/lib/libSystem.dylib").setiopolicy_np(0, 0, 3)
    except (OSError, AttributeError):
        pass


def _fixture(name):
    path = os.environ.get(name)
    if not path:
        return None
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


_FRAME = [0]


def _libproc():
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    return lib


class _BsdInfo(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint32), ("status", ctypes.c_uint32), ("xstatus", ctypes.c_uint32),
                ("pid", ctypes.c_uint32), ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32), ("gid", ctypes.c_uint32),
                ("ruid", ctypes.c_uint32), ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32),
                ("svgid", ctypes.c_uint32), ("rfu", ctypes.c_uint32), ("comm", ctypes.c_char * 16),
                ("name", ctypes.c_char * 32), ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
                ("pjobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32), ("tpgid", ctypes.c_uint32),
                ("nice", ctypes.c_int32), ("start_s", ctypes.c_uint64), ("start_us", ctypes.c_uint64)]


class _ShortInfo(ctypes.Structure):
    _fields_ = [("pid", ctypes.c_uint32), ("ppid", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
                ("status", ctypes.c_uint32), ("comm", ctypes.c_char * 16), ("flags", ctypes.c_uint32),
                ("uid", ctypes.c_uint32), ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32), ("rgid", ctypes.c_uint32),
                ("svuid", ctypes.c_uint32), ("svgid", ctypes.c_uint32), ("rfu", ctypes.c_uint32)]


class _RusageV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 18)]


_LIB = []


def _lib():
    if not _LIB:
        try:
            _LIB.append(_libproc())
        except OSError:
            _LIB.append(None)
    return _LIB[0]


def all_pids():
    fixture = _fixture("SYSTEM_DOCTOR_PROCS")
    if fixture is not None:
        frames = fixture.get("frames") or [[]]
        frame = frames[min(_FRAME[0], len(frames) - 1)]
        _FRAME[0] += 1
        return set(frame)
    lib = _lib()
    if lib is None:
        return set()
    count = lib.proc_listallpids(None, 0)
    pids = (ctypes.c_int * (max(count, 0) + 512))()
    count = lib.proc_listallpids(pids, ctypes.sizeof(pids))
    return set(pids[:max(count, 0)])


def proc_info(pid):
    """(ppid, uid, start, args) of one live process, args as `argv0 … arg8` held in memory only (as
    `ps` shows own-uid processes; the executable path alone for others), or None once it is gone."""
    fixture = _fixture("SYSTEM_DOCTOR_PROCS")
    if fixture is not None:
        found = (fixture.get("procs") or {}).get(str(pid))
        return tuple(found) if found else None
    lib = _lib()
    if lib is None:
        return None
    info = _BsdInfo()
    if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        info = _ShortInfo()
        if lib.proc_pidinfo(pid, 13, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            return None
        info.start_s = info.start_us = 0
    path = ctypes.create_string_buffer(4096)
    exe = path.value.decode(errors="replace") if lib.proc_pidpath(pid, path, 4096) > 0 else \
        info.comm.decode(errors="replace")
    words = (_argv(pid)[:9] if info.uid == os.getuid() else []) or [exe]
    return info.ppid, info.uid, info.start_s + info.start_us / 1e6, " ".join(words)


def proc_cwd(pid):
    """The working directory of one own process (PROC_PIDVNODEPATHINFO), or None."""
    fixture = _fixture("SYSTEM_DOCTOR_PROCS")
    if fixture is not None:
        return (fixture.get("cwd") or {}).get(str(pid))
    lib = _lib()
    if lib is None:
        return None
    info = ctypes.create_string_buffer(2352)
    if lib.proc_pidinfo(pid, 9, 0, info, 2352) != 2352:
        return None
    return info.raw[152:1176].split(b"\0", 1)[0].decode(errors="replace") or None


def _argv(pid):
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(65536)
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
        return []
    raw = buffer.raw[:size.value]
    argc = int.from_bytes(raw[:4], "little")
    return [part.decode(errors="replace") for part in raw[4:].split(b"\0") if part][1:argc + 1]


def proc_rusage(pid):
    """(phys footprint, disk bytes read, disk bytes written, package idle wakeups) of one own process, or None."""
    fixture = _fixture("SYSTEM_DOCTOR_RUSAGE")
    if fixture is not None:
        found = fixture.get(str(pid))
        return tuple(found) if found else None
    lib = _lib()
    if lib is None:
        return None
    usage = _RusageV2()
    if lib.proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0:
        return None
    values = usage.values
    return values[7], values[16], values[17], values[2]
