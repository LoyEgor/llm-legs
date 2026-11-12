"""Unprivileged machine probes the Harness and System doctors share. Each command resolves through
SYSTEM_DOCTOR_<NAME> first, so a test replaces it with a fixture; SYSTEM_DOCTOR_HOST_TICKS names a file
holding the four host CPU tick counters (user system idle nice) in place of host_statistics, SYSTEM_DOCTOR_PROCS
a JSON {frames: [[pid...]...], procs: {pid: [ppid, uid, start, args]}} in place of libproc's process table and
SYSTEM_DOCTOR_RUSAGE a JSON {pid: [footprint, read, written, idle wakeups[, reaped children's CPU s]]} in place of
proc_pid_rusage and SYSTEM_DOCTOR_COALITIONS a JSON {id: [cpu s, tasks started, bytes written]} in place of
coalition_info_resource_usage."""

import ctypes
import json
import os
import signal
import subprocess
import threading

import limit_hit

COMMANDS = {"ps": "/bin/ps", "vm_stat": "/usr/bin/vm_stat", "sysctl": "/usr/sbin/sysctl", "ioreg": "/usr/sbin/ioreg",
            "df": "/bin/df", "last": "/usr/bin/last", "du": "/usr/bin/du", "diskutil": "/usr/sbin/diskutil",
            "launchctl": "/bin/launchctl", "log": "/usr/bin/log", "lsof": "/usr/sbin/lsof"}


def command(name):
    return os.environ.get("SYSTEM_DOCTOR_" + name.upper()) or COMMANDS[name]


def spawn(name, args, timeout=10):
    """(pid, stdout) of one probe run; the pid is the system's newest at that moment, the births counter.
    close_fds=False lets Python start it with posix_spawn, one task where fork + exec are two (the minute tick's
    probes were 12 of its 20); every descriptor Python opens is close-on-exec, so the probe inherits none."""
    try:
        process = subprocess.Popen([command(name)] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   stdin=subprocess.DEVNULL, text=True, env=dict(os.environ, LC_ALL="C"),
                                   close_fds=False)
    except OSError:
        return None, ""
    try:
        out, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        limit_hit.hit("machine-probe.timeout", timeout, "s", "kill", "the system doctor's %s probe: its value is missing" % name,
                      "share/machine_probe.py:def spawn(name, args, timeout=10)")
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
    lib.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
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


def child_pids(pid):
    """The pids of one process's children (proc_listchildpids: one call, where `ps -A` reads every process), [] when
    it has none or is gone."""
    fixture = _fixture("SYSTEM_DOCTOR_PROCS")
    if fixture is not None:
        return sorted(int(p) for p, found in (fixture.get("procs") or {}).items() if found and found[0] == pid)
    lib = _lib()
    if lib is None:
        return []
    kids = (ctypes.c_int * 2048)()
    count = lib.proc_listchildpids(pid, kids, ctypes.sizeof(kids))
    return list(kids[:max(count, 0)])


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


def proc_path(pid):
    """The executable of one live process (proc_pidpath), or None."""
    fixture = _fixture("SYSTEM_DOCTOR_PROCS")
    if fixture is not None:
        return (fixture.get("path") or {}).get(str(pid))
    lib = _lib()
    if lib is None:
        return None
    path = ctypes.create_string_buffer(4096)
    return path.value.decode(errors="replace") if lib.proc_pidpath(pid, path, 4096) > 0 else None


def window_counts():
    """{pid: windows} WindowServer holds per owner, hidden ones included (CGWindowListCopyWindowInfo, no titles)."""
    fixture = _fixture("SYSTEM_DOCTOR_WINDOWS")
    if fixture is not None:
        return {int(pid): n for pid, n in fixture.items()}
    try:
        cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError:
        return {}
    cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cf.CFArrayGetCount.restype = ctypes.c_long
    cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
    cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
    cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
    cf.CFDictionaryGetValue.restype = ctypes.c_void_p
    cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    key = ctypes.c_void_p.in_dll(cg, "kCGWindowOwnerPID")
    windows = cg.CGWindowListCopyWindowInfo(0, 0)
    if not windows:
        return {}
    counts, pid = {}, ctypes.c_int32()
    try:
        for index in range(cf.CFArrayGetCount(windows)):
            number = cf.CFDictionaryGetValue(cf.CFArrayGetValueAtIndex(windows, index), key)
            if number and cf.CFNumberGetValue(number, 3, ctypes.byref(pid)):
                counts[pid.value] = counts.get(pid.value, 0) + 1
    finally:
        cf.CFRelease(windows)
    return counts


def coalition_usage(ids):
    """{id: [cpu s, tasks started, bytes written]} of resource coalitions since each began: the kernel's totals over
    every process that ever ran in it, short-lived ones included (launchd gives each job its own). A gone id is left
    out. The CPU counter is in mach time units."""
    fixture = _fixture("SYSTEM_DOCTOR_COALITIONS")
    if fixture is not None:
        return {int(cid): usage for cid, usage in fixture.items() if int(cid) in set(ids)}
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        base = (ctypes.c_uint32 * 2)()
        lib.mach_timebase_info(base)
    except (OSError, AttributeError):
        return {}
    usage, out = (ctypes.c_uint64 * 128)(), {}
    for cid in ids:
        # struct coalition_resource_usage opens with tasks_started, tasks_exited, time_nonempty, cpu_time,
        # interrupt_wakeups, platform_idle_wakeups, bytesread, byteswritten
        if lib.coalition_info_resource_usage(ctypes.c_uint64(cid), usage, ctypes.c_size_t(ctypes.sizeof(usage))) == 0:
            out[cid] = [round(usage[3] * base[0] / base[1] / 1e9, 3), usage[0], usage[7]]
    return out


def _procargs(pid, size=65536):
    """(argv, env strings) of one own process off KERN_PROCARGS2, or None. argv is argc strings after the exec path,
    empty ones kept; a process that rewrote its title (next-server, setproctitle) leaves its title and then empty
    strings there, and `ps -E`, which stops at the first empty string, shows no environment for it although every
    variable is still in the buffer: env is every non-empty string after argv (Apple's `key=value` tail included)."""
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(size)
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
        return None
    return split_procargs(buffer.raw[:size.value])


def split_procargs(raw):
    """(argv, env strings) of one KERN_PROCARGS2 buffer, as _procargs reads it (bin/chat-load reads its own buffer)."""
    argc = int.from_bytes(raw[:4], "little")
    parts = raw[4:].partition(b"\0")[2].lstrip(b"\0").split(b"\0")
    return parts[:argc], [part for part in parts[argc:] if part]


def _argv(pid):
    found = _procargs(pid)
    return [part.decode(errors="replace") for part in found[0]] if found else []


def proc_env(pid):
    """{name: value} of the environment one own process started with, or None (another user's, gone, or an Apple
    binary the kernel hides it for: /bin/sleep shows none, /bin/bash does)."""
    fixture = _fixture("SYSTEM_DOCTOR_PROCS")
    if fixture is not None:
        found = (fixture.get("env") or {}).get(str(pid))
        return dict(found) if isinstance(found, dict) else None
    found = _procargs(pid, 1 << 18)
    if not found:
        return None
    env = {}
    for part in found[1]:
        name, sign, value = part.decode(errors="replace").partition("=")
        if sign and name and name not in env:
            env[name] = value
    return env or None


def env_holders(name, value):
    """`h <pid>` for each own process whose environment sets name=value, `o <pid>` for each setting name otherwise."""
    lines = []
    for pid in sorted(all_pids()):
        found = proc_env(pid) if pid > 1 else None
        if found and name in found:
            lines.append("%s %d" % ("h" if found[name] == value else "o", pid))
    return lines


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 4 and sys.argv[1] == "env-holders":
        for line in env_holders(sys.argv[2], sys.argv[3]):
            print(line)
    else:
        sys.exit("usage: machine_probe.py env-holders NAME VALUE")


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_TICK_S = []


def _tick_s():
    """Seconds per mach absolute time unit, the unit of rusage CPU times (1e-9 on Intel, 1/24e6 on Apple silicon)."""
    if not _TICK_S:
        base = _Timebase()
        try:
            ctypes.CDLL("/usr/lib/libSystem.dylib").mach_timebase_info(ctypes.byref(base))
        except (OSError, AttributeError):
            pass
        _TICK_S.append(base.numer / base.denom / 1e9 if base.denom else 1e-9)
    return _TICK_S[0]


def proc_cpu(pid):
    """CPU seconds (user + system) one own process has used so far, or None once it is gone."""
    fixture = _fixture("SYSTEM_DOCTOR_RUSAGE")
    if fixture is not None:
        found = fixture.get(str(pid))
        return found[5] if found and len(found) > 5 else None
    lib = _lib()
    if lib is None:
        return None
    usage = _RusageV2()
    if lib.proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0:
        return None
    return (usage.values[0] + usage.values[1]) * _tick_s()


def proc_rusage(pid):
    """(phys footprint, disk bytes read, disk bytes written, package idle wakeups, reaped children's CPU s) of one own
    process, or None. The children's CPU is every waited-for descendant's user + system time (a reaped child's own
    reaped children included): the CPU of processes too short-lived for any tick to see."""
    fixture = _fixture("SYSTEM_DOCTOR_RUSAGE")
    if fixture is not None:
        found = fixture.get(str(pid))
        return (tuple(found) + (None,))[:5] if found else None
    lib = _lib()
    if lib is None:
        return None
    usage = _RusageV2()
    if lib.proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0:
        return None
    values = usage.values
    return values[7], values[16], values[17], values[2], (values[10] + values[11]) * _tick_s()
