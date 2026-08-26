"""RAM telemetry written beside every review-bench run.

A T1 review exhausted the machine's memory on 2026-08-26 and has not reproduced since, so no
fix is possible until the next natural occurrence — and that one has to be attributable after
the reboot that ends it. Every process line therefore carries ppid AND etime: the suspected
shape is a SPAWN LOOP of large node processes, which only the parent chains and the ages tell
apart from one fat rater that grew.

Quiet sampling is filtered (fat processes and the review's own tool families) so an ordinary
run costs a couple of megabytes; once available memory crosses the incident threshold the
sampler switches to the full process table at 1 Hz, because a table filtered by the very
symptom under investigation is the one that would be missing the culprit.

Runs as its own script (`python3 memlog.py <run-dir> <parent-pid>`); it must stay importable
with nothing but the standard library, since it also runs detached from a dying panel.
"""

import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

MEMLOG_NAME = "memlog.txt"
SAMPLE_INTERVAL_S = 2.0
INCIDENT_INTERVAL_S = 1.0
POLL_INTERVAL_S = 0.25
INCIDENT_AVAILABLE_BYTES = 4 * 1024 ** 3
FAT_PROCESS_RSS_BYTES = 50 * 1024 ** 2
# pid, ppid, rss and etime all lead the line, so a truncated row still answers every question
# this log exists for; untruncated argv (1.8 KB on a live machine) quadruples a quiet run.
LINE_MAX_CHARS = 160
MAX_RUNTIME_S = 2 * 60 * 60
STOP_GRACE_S = 5.0
RETENTION_S = 14 * 24 * 60 * 60
INCIDENT_MARKER = "INCIDENT"
PS_ARGV = ["ps", "-axo", "pid,ppid,rss,etime,command"]
WATCHED_COMMAND_RE = re.compile(
    r"agy|claude|codex|opencode|node|npm|npx|pnpm|nx|jest|eslint|esbuild|mcp-remote"
)
SWAP_UNITS = {"": 1, "B": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}


def _note(message):
    print(message, file=sys.stderr, flush=True)


def _mb(value):
    return "?" if value is None else str(value // (1024 * 1024))


def _guard(call, errors, label):
    try:
        return call()
    except Exception as exc:
        errors.append(f"{label} {exc.__class__.__name__}: {exc}")
        return None


def _run(argv):
    return subprocess.run(
        argv, capture_output=True, text=True, timeout=20, check=True
    ).stdout


def available_bytes():
    text = _run(["vm_stat"])
    page_match = re.search(r"page size of (\d+) bytes", text)
    page = int(page_match.group(1)) if page_match else 4096
    pages = 0
    for key in ("Pages free", "Pages inactive", "Pages speculative"):
        match = re.search(rf"^{key}:\s+(\d+)", text, re.M)
        if match:
            pages += int(match.group(1))
    # No page counts read means vm_stat changed shape, not that the machine has nothing free:
    # zero would sit under every threshold and latch the incident for the rest of the run.
    if pages == 0:
        raise ValueError(f"unparseable vm_stat: {text.strip()[:200]!r}")
    return pages * page


def swap_used_bytes():
    text = _run(["sysctl", "-n", "vm.swapusage"])
    match = re.search(r"used\s*=\s*([\d.]+)\s*([BKMGT]?)", text)
    if not match:
        raise ValueError(f"unparseable vm.swapusage: {text.strip()!r}")
    return int(float(match.group(1)) * SWAP_UNITS[match.group(2).upper()])


def process_lines(dump_all):
    text = _run(PS_ARGV)
    kept = []
    for line in text.splitlines()[1:]:
        fields = line.split(None, 4)
        if len(fields) < 5:
            continue
        try:
            rss_bytes = int(fields[2]) * 1024
        except ValueError:
            continue
        if dump_all or rss_bytes >= FAT_PROCESS_RSS_BYTES or WATCHED_COMMAND_RE.search(fields[4]):
            kept.append(line.strip()[:LINE_MAX_CHARS])
    return kept


def sample(path, incident, final=False):
    stamp = int(time.time())
    errors = []
    available = _guard(available_bytes, errors, "vm_stat")
    swap = _guard(swap_used_bytes, errors, "swapusage")
    hot = available is not None and available < INCIDENT_AVAILABLE_BYTES
    lines = _guard(lambda: process_lines(hot), errors, "ps") or []
    block = []
    if hot and not incident:
        block.append(f"{INCIDENT_MARKER} {stamp}")
    header = (
        f"T {stamp} avail_mb={_mb(available)} swap_mb={_mb(swap)} "
        f"mode={'incident' if hot else 'quiet'} procs={len(lines)}"
    )
    if final:
        header += " final=1"
    block.append(header)
    block.extend(lines)
    block.extend(f"ERROR {stamp} {message}" for message in errors)
    written = True
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("\n".join(block) + "\n")
    except OSError as exc:
        _note(f"memlog: {path}: {exc}")
        written = False
    # The return value is "the incident is on record", not "the machine is hot": a marker that
    # never reached the file has to be written again, or rotation deletes the only evidence as a
    # quiet log. Pacing rides on the same value, and a failed write has nothing to pace.
    return hot and written


def process_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def has_incident(path):
    # Anchored like memlogd's rotate: a ps command line carrying the word is not the marker, and
    # the seeded newline is what makes the first line of the file count as a line start.
    marker = b"\n" + INCIDENT_MARKER.encode() + b" "
    try:
        with open(path, "rb") as handle:
            carry = b"\n"
            while True:
                chunk = handle.read(1 << 20)
                if not chunk:
                    return False
                if marker in carry + chunk:
                    return True
                carry = chunk[-len(marker):]
    except OSError:
        # Unreadable counts as an incident: rotation may never be the reason evidence is gone.
        return True


def rotate(benches_dir, now=None, keep_s=RETENTION_S):
    now = time.time() if now is None else now
    removed = []
    try:
        entries = sorted(Path(benches_dir).iterdir())
    except OSError:
        return removed
    for entry in entries:
        path = entry / MEMLOG_NAME
        try:
            if not path.is_file() or now - path.stat().st_mtime <= keep_s:
                continue
        except OSError:
            continue
        if has_incident(path):
            continue
        try:
            path.unlink()
        except OSError:
            continue
        removed.append(path)
    return removed


def sampler_main(run_dir, parent_pid):
    path = Path(run_dir) / MEMLOG_NAME
    stopping = []
    for signo in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(signo, lambda number, frame: stopping.append(number))
        except (ValueError, OSError):
            pass
    deadline = time.monotonic() + MAX_RUNTIME_S
    incident = False
    while True:
        final = bool(stopping) or time.monotonic() >= deadline or not process_alive(parent_pid)
        incident = sample(path, incident, final=final)
        if final:
            return 0
        waited = 0.0
        target = INCIDENT_INTERVAL_S if incident else SAMPLE_INTERVAL_S
        while waited < target and not stopping and process_alive(parent_pid):
            time.sleep(POLL_INTERVAL_S)
            waited += POLL_INTERVAL_S


class Handle:
    def __init__(self, process, path):
        self.process = process
        self.path = path


def start(run_dir):
    """Detach a sampler over `run_dir` and rotate what past runs left; never raises.

    Telemetry is worth nothing at the price of a review, so every failure here returns None and
    the panel runs on blind rather than dying for a diagnostic.
    """
    if os.environ.get("RBENCH_MEMLOG") == "0":
        return None
    run_dir = Path(run_dir)
    if not run_dir.is_dir():
        _note(f"memlog: {run_dir} is not a directory")
        return None
    try:
        rotate(run_dir.parent)
    except Exception as exc:
        _note(f"memlog: rotation skipped: {exc}")
    try:
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), str(run_dir), str(os.getpid())],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception as exc:
        _note(f"memlog: sampler did not start: {exc}")
        return None
    return Handle(process, run_dir / MEMLOG_NAME)


def stop(handle):
    if handle is None or handle.process is None or handle.process.poll() is not None:
        return
    process = handle.process
    try:
        process.terminate()
    except OSError:
        pass
    try:
        process.wait(timeout=STOP_GRACE_S)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        process.kill()
    except OSError:
        pass
    try:
        process.wait(timeout=STOP_GRACE_S)
    except subprocess.TimeoutExpired:
        pass


def main(argv):
    if len(argv) != 2:
        _note("usage: memlog.py <run-dir> <parent-pid>")
        return 2
    return sampler_main(argv[0], int(argv[1]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
