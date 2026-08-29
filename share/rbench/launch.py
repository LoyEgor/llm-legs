import atexit
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from collections import Counter, defaultdict
from pathlib import Path

from . import store as _store
from . import catalog as _catalog
from . import accounts as _accounts
from . import scope as _scope
from . import panel as _panel
from . import prompts as _prompts

class PriorityGate:
    """Concurrency limiter that admits the longest expected job first.

    One shared subscription gateway serves every OpenCode rater, so the bench
    throttles itself instead of fanning out one request per selected cell. The
    gateway itself parallelises fine; the makespan is decided by whether a slow
    cell waits behind fast ones, hence priority instead of a plain semaphore.
    """

    def __init__(self, limit):
        self.limit = limit
        self.active = 0
        self.waiting = []
        self.seq = 0
        self.cv = threading.Condition()

    def acquire(self, priority=0):
        with self.cv:
            self.seq += 1
            entry = (-priority, self.seq)
            self.waiting.append(entry)
            self.waiting.sort()
            try:
                while self.active >= self.limit or self.waiting[0] != entry:
                    self.cv.wait()
            finally:
                # Waiters block on being the head as much as on a free slot, so an abandoned
                # entry freezes the gate and leaving the queue is itself the news. Both are
                # unconditional and in the finally, because an async exception can land after
                # the loop exits: an acquire that got in and never returned would otherwise
                # take the freed head away in silence. One notify covers the increment below
                # too — nobody can act on it until this releases the lock.
                self.waiting.remove(entry)
                self.cv.notify_all()
            self.active += 1

    def release(self):
        with self.cv:
            self.active -= 1
            self.cv.notify_all()


OPENCODE_MAX_CONCURRENCY = max(1, int(os.environ.get("REVIEW_BENCH_OPENCODE_CONCURRENCY", "5")))
OPENCODE_GATE = PriorityGate(OPENCODE_MAX_CONCURRENCY)


def cap_opencode_panel(raters):
    """Never select more OpenCode cells than the gate admits at once.

    An overflow cell cannot start until one of the first five releases a slot, so it only
    stretches the panel by its own duration: 406 recorded runs selected 6-7 OpenCode cells
    against a gate of 5, and the 6th cell was hostage to the rest of the leg every time.
    Returns (kept, skipped) with the overflow as (spec, reason) rows for the run's record.
    """
    kept, skipped, opencode_kept = [], [], 0
    for rater in raters:
        if rater["side"] == "opencode" and opencode_kept >= OPENCODE_MAX_CONCURRENCY:
            skipped.append((
                rater["spec"],
                f"the OpenCode gate admits {OPENCODE_MAX_CONCURRENCY} concurrent cells; "
                "an overflow cell only waits for the others",
            ))
            continue
        if rater["side"] == "opencode":
            opencode_kept += 1
        kept.append(rater)
    return kept, skipped


def opencode_env(account, **values):
    env = dict(os.environ, **values)
    if account == "opencode-go":
        env.pop("OPENCODE_GO_PROFILE", None)
    else:
        env["OPENCODE_GO_PROFILE"] = account.removeprefix("opencode-go-")
    return env


def resolved_model_from_envelope(path):
    try:
        envelope = json.loads(path.read_text())
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(envelope, dict):
        return None
    usage = envelope.get("modelUsage")
    if not isinstance(usage, dict) or not usage:
        return None
    models = set()
    for key, details in usage.items():
        if not isinstance(key, str) or not key or key == "canonicalModel":
            continue
        # The key can be the alias the cell was launched with, so canonicalModel wins where
        # both exist: recording `claude-opus-5[1m]` beside `claude-opus-5` splits one model
        # into two names, which is the ambiguity this field exists to remove.
        canonical = details.get("canonicalModel") if isinstance(details, dict) else None
        models.add(canonical if isinstance(canonical, str) and canonical else key)
    if not models:
        canonical = usage.get("canonicalModel")
        if isinstance(canonical, str) and canonical:
            return canonical
    return "+".join(sorted(models)) if models else None


def prepare_agy_skill_clone(clone):
    proc = subprocess.run(
        ["git", "-C", clone, "rev-parse", "--verify", "--quiet", "HEAD^"],
        capture_output=True, text=True, timeout=30
    )
    base = proc.stdout.strip()
    if not base:
        # The skill reads origin/HEAD..HEAD, and a root commit has nothing to point that at. An
        # empty commit built in the sealed clone — never in the repository under review — makes
        # the diff the root commit's whole content, which is exactly what it introduced.
        empty = subprocess.run(
            ["git", "-C", clone, "commit-tree", _store.empty_tree_hash(clone),
             "-m", "review-bench empty base"],
            env=dict(os.environ, **_store.FIXED_COMMIT_IDENTITY), stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30,
        )
        base = empty.stdout.strip()
        if empty.returncode != 0 or not base:
            raise RuntimeError(
                f"agy -skill could not build a root-commit base: "
                f"{empty.stderr.strip() or empty.returncode}"
            )
    proc = subprocess.run(
        ["git", "-C", clone, "update-ref", "refs/remotes/origin/HEAD", base],
        capture_output=True, text=True, timeout=30
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"agy -skill could not prepare origin/HEAD: "
            f"{proc.stderr.strip() or proc.returncode}"
        )


def codex_environment(account):
    env = os.environ.copy()
    if account == "main":
        env.pop("CODEX_HOME", None)
    else:
        env["CODEX_HOME"] = str(Path.home() / ".codex-profiles" / account)
    return env


# The project's own toolchain is not a review tool: a clone cell that ran `pnpm test` inside an nx
# monorepo fanned out 88 processes and 6.3 GB in 90 seconds and took the machine down with it
# (2026-08-28, Egor lost work). Shims answer for those commands in every cell whose cwd is the
# sealed clone, uniformly across the sides — a measured T1 run under them cut peak tree RSS
# 4.12 -> 2.86 GB with no finding lost (research handoff 2026-08-26 section 7.5). The interpreters
# `node` and `python`/`python3` are deliberately absent: the vendors' own CLIs run on them.
TOOLCHAIN_SHIMS = (
    "npm", "npx", "pnpm", "yarn", "corepack", "nx", "jest", "vitest", "eslint", "tsc",
    "playwright", "bun", "cargo", "make", "mvn", "gradle", "go",
    "pip", "pip3", "poetry", "uv", "pytest", "tox",
)
TOOLCHAIN_SHIM_DIR = "toolchain-shims"
TOOLCHAIN_SHIM_MESSAGE = (
    "the project toolchain is disabled during review — read the code instead of running it"
)
NO_SHIMS_ENV = "REVIEW_BENCH_NO_SHIMS"
_SHIM_BUILD_LOCK = threading.Lock()


def shims_disabled():
    """The escape hatch, read here and nowhere else: a measurement run that needs the real
    toolchain back sets REVIEW_BENCH_NO_SHIMS=1 and no cell of any side is shimmed."""
    return os.environ.get(NO_SHIMS_ENV) == "1"


def active_shim_names():
    """What the run records about itself, so a later corpus comparison can tell a shimmed run
    from a pre-shim one instead of guessing at its date."""
    return [] if shims_disabled() else list(TOOLCHAIN_SHIMS)


def toolchain_shim_dir(run_dir):
    """This run's shim directory, built once and shared by every cell of every side."""
    path = Path(run_dir) / TOOLCHAIN_SHIM_DIR
    with _SHIM_BUILD_LOCK:
        path.mkdir(parents=True, exist_ok=True)
        for name in TOOLCHAIN_SHIMS:
            shim = path / name
            if shim.exists():
                continue
            # Exit 0, and never a refusal code: an agentic CLI reads a failing command as one to
            # fix and run again — reinstalling the package manager, reaching for another runner —
            # which is the fan-out the shim exists to prevent. An answered command is dropped.
            shim.write_text(
                "#!/bin/sh\n"
                f'echo "{name}: {TOOLCHAIN_SHIM_MESSAGE}"\n'
                "exit 0\n"
            )
            shim.chmod(0o755)
    return path


def clone_cell_env(run_dir, base=None):
    """The environment of a launch whose cwd is the sealed clone. Every such launch — agy,
    claude, codex — takes its env from here, so the shim rule has one implementation and a
    diff-fed cell, which has no clone to run anything in, never reaches it."""
    env = dict(os.environ if base is None else base)
    if shims_disabled():
        return env
    shim_path = str(toolchain_shim_dir(run_dir))
    base_path = env.get("PATH", "")
    # An EMPTY PATH entry is the current directory on POSIX, and the current directory here is the
    # sealed clone: a base with no PATH of its own must leave no separator behind, or the shims
    # would be followed by the reviewed tree itself as a search path.
    env["PATH"] = f"{shim_path}{os.pathsep}{base_path}" if base_path else shim_path
    return env


class RaterStalled(Exception):
    """A cell killed by the stall watch: alive by the clock, silent past its pair's own cap."""

    def __init__(self, quiet_s, stall_s, stdout, stderr):
        super().__init__(f"no output activity for {round(quiet_s)}s (stall cap {stall_s}s)")
        self.quiet_s = quiet_s
        self.stall_s = stall_s
        self.stdout = stdout
        self.stderr = stderr


def rater_stalled(exc, rater, started, command, extra_stdout=""):
    """A stall kill's result row: the kill's exit code so every status reader calls it a timeout,
    told apart from a duration breach by its wording here and by `stalled_s` on the meta row."""
    rater["stalled_s"] = exc.stall_s
    rater["killed"] = "stall"
    rater["killed_cap_s"] = exc.stall_s
    rater["max_quiet_ms"] = round(exc.quiet_s * 1000)
    duration = round((time.monotonic() - started) * 1000)
    stdout = "\n".join(
        part for part in (exc.stdout.rstrip(), extra_stdout.rstrip()) if part
    )
    stderr = f"rater stalled: {exc}"
    if exc.stderr.rstrip():
        stderr += f"\n{exc.stderr.rstrip()}"
    return 124, duration, stdout, stderr, command


LIVE_CELL_GROUPS = set()
_reaper_atexit = False
_reaper_sigterm = False


def reap_live_groups():
    for pid in list(LIVE_CELL_GROUPS):
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            pass


def install_cell_reaper():
    """Kill every still-live cell group when review-bench itself dies: start_new_session detaches
    the cells from the terminal's group, so a Ctrl-C or a kill of an interrupted review would
    otherwise leave every rater CLI running detached, spending its account with nobody to reap it.
    The SIGTERM half can only install from the main thread; cells launch from workers, so the
    launch path keeps asking until a main-thread caller (the panel launch) has claimed it.
    """
    global _reaper_atexit, _reaper_sigterm
    if not _reaper_atexit:
        _reaper_atexit = True
        atexit.register(reap_live_groups)
    if _reaper_sigterm:
        return
    try:
        previous = signal.getsignal(signal.SIGTERM)

        def on_term(signo, frame):
            reap_live_groups()
            if callable(previous):
                previous(signo, frame)
            else:
                raise SystemExit(128 + signo)

        signal.signal(signal.SIGTERM, on_term)
        _reaper_sigterm = True
    except (ValueError, OSError):
        pass


def kill_process_group(proc):
    """The whole group, because the visible child is a launcher (claudeb, geminib, codex) and the
    hang lives in its descendant, which killing the launcher alone would leave hanging around."""
    for kill_signal in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, kill_signal)
        except (ProcessLookupError, PermissionError, OSError):
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.wait(timeout=5)
            return
        except subprocess.TimeoutExpired:
            continue


def run_streamed(command, *, timeout_s, stall_s=None, watch_paths=(), cwd=None, env=None,
                 input_text=None, stdout_path=None):
    """subprocess.run with the duration cap every cell always had, plus an activity watch: any
    byte on stdout or stderr, and any growth of a watch path (a side's own stream file), counts
    as life. With a stall cap, a cell silent past it is killed and raised as RaterStalled; without
    one — the pair's history has not earned it — only the duration cap can kill.

    Timeouts keep subprocess.run's contract (TimeoutExpired with the output so far), so the
    callers' timeout handling does not change shape.
    """
    stdout_file = open(stdout_path, "wb") if stdout_path else None
    try:
        proc = subprocess.Popen(
            command, cwd=cwd, env=env,
            stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
            stdout=stdout_file if stdout_file else subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except Exception:
        if stdout_file:
            stdout_file.close()
        raise
    install_cell_reaper()
    LIVE_CELL_GROUPS.add(proc.pid)
    activity = [time.monotonic()]
    collected = {"stdout": [], "stderr": []}

    def pump(stream, name):
        fd = stream.fileno()
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            collected[name].append(chunk)
            activity[0] = time.monotonic()

    readers = []
    for name in ("stdout", "stderr"):
        stream = getattr(proc, name)
        if stream is not None:
            thread = threading.Thread(target=pump, args=(stream, name), daemon=True)
            thread.start()
            readers.append(thread)
    if input_text is not None:
        def feed():
            try:
                proc.stdin.write(input_text.encode("utf-8", errors="replace"))
                proc.stdin.close()
            except (OSError, ValueError):
                pass
        threading.Thread(target=feed, daemon=True).start()

    def drained(name):
        # The pumps must be done first: read mid-pump, the tail flushed while the process died is
        # still in flight and the exception carries a truncated transcript.
        for thread in readers:
            thread.join(timeout=5)
        return b"".join(collected[name]).decode("utf-8", errors="replace")

    watched = [str(path) for path in watch_paths]
    if stdout_path:
        watched.append(str(stdout_path))
    sizes = {}
    started = activity[0]
    max_quiet = 0.0
    try:
        while True:
            returncode = proc.poll()
            now = time.monotonic()
            for path in watched:
                try:
                    size = os.stat(path).st_size
                except OSError:
                    continue
                if sizes.get(path) != size:
                    sizes[path] = size
                    activity[0] = now
            quiet = now - activity[0]
            max_quiet = max(max_quiet, quiet)
            if returncode is not None:
                break
            if now - started > timeout_s:
                kill_process_group(proc)
                expired = subprocess.TimeoutExpired(
                    command, timeout_s, output=drained("stdout"), stderr=drained("stderr")
                )
                expired.max_quiet_ms = round(max_quiet * 1000)
                raise expired
            if stall_s and quiet > stall_s:
                kill_process_group(proc)
                raise RaterStalled(quiet, stall_s, drained("stdout"), drained("stderr"))
            time.sleep(_catalog.STALL_POLL_S)
    except (subprocess.TimeoutExpired, RaterStalled):
        raise
    except BaseException:
        # start_new_session detaches the cell from the terminal's group, so a Ctrl-C here no
        # longer reaches it: without this kill an interrupted review leaves every rater CLI
        # running detached, spending its account with nobody left to reap it.
        kill_process_group(proc)
        raise
    finally:
        LIVE_CELL_GROUPS.discard(proc.pid)
        for thread in readers:
            thread.join(timeout=5)
        if stdout_file:
            stdout_file.close()
    result = subprocess.CompletedProcess(
        command, proc.returncode, stdout=drained("stdout"), stderr=drained("stderr")
    )
    result.max_quiet_ms = round(max_quiet * 1000)
    return result


def run_codex(rater, repo, sha, focus, run_dir, diff, account):
    deadline = rater.get("timeout_s") or _catalog.RATER_TIMEOUT_S
    raw_final = tempfile.NamedTemporaryFile(
        dir=run_dir, prefix=f"raw-final-{_scope.cell_artifact(rater)}-", delete=False
    )
    raw_final.close()
    raw_events = run_dir / f"raw-events-{_scope.cell_artifact(rater)}.jsonl"
    command = [_store.command_path("REVIEW_BENCH_CODEX_BIN", "codex"), "exec"]
    prompt_input = None
    lens = rater.get("lens")
    if rater["bare"]:
        prompt_input = (
            _prompts.review_prompt(sha, focus, lens=lens)
            + _prompts.clone_state_note(sha, _scope.cell_chunk_paths(rater))
            + "\n\nCommit diff:\n" + diff
        )
        command += [
            "-m", "gpt-5.6-sol", "-c",
            f"model_reasoning_effort={rater['effort']}",
            "-",
        ]
    else:
        command += [
            "review", "--commit", sha, "-m", "gpt-5.6-sol", "-c",
            f"model_reasoning_effort={rater['effort']}",
        ]
        # The native review command carries no output contract of its own, so a clean review
        # comes back as prose — in whichever language the account's config answers in — and the
        # cell is recorded as a failure instead of an empty result: 27 of 226 non-bare cells on
        # record against 0 of 136 bare ones, which get this sentence from review_prompt.
        instruction = (
            f"{_prompts.READ_ONLY_REVIEW_INSTRUCTION} Reply with exactly {_prompts.CLEAN_REVIEW_MARKER} and "
            "nothing else when the commit has no findings."
            + _prompts.chunk_instruction(sha, _scope.cell_chunk_paths(rater))
        )
        if focus:
            instruction += f" Additional review focus: {focus}"
        # The native review command builds its own prompt, so the developer instructions are
        # the only channel a lens has into this cell; without this the cell would run the
        # vendor's stock review and be recorded under the lens's slug.
        if lens:
            instruction = (
                f"Review with the following methodology.\n\n{lens['body']}\n\n"
                f"{_prompts.methodology_adaptation(False)}\n\n{instruction}"
            )
        command += ["-c", f"developer_instructions={json.dumps(instruction)}"]
    command += ["--json", "-o", raw_final.name]
    clone = None
    started = time.monotonic()
    try:
        clone = _prompts.seal_overlay_clone(repo, sha)
        try:
            # The event stream is the side's own heartbeat: it goes to raw_events, and its growth
            # is what the stall watch reads. raw_final only appears at the end, so it is not one.
            proc = run_streamed(
                command, cwd=clone, env=clone_cell_env(run_dir, codex_environment(account)),
                timeout_s=deadline, stall_s=rater.get("stall_s"),
                input_text=prompt_input, stdout_path=raw_events,
            )
        except (subprocess.TimeoutExpired, RaterStalled) as exc:
            output_tail = "\n".join(
                part for part in (
                    _store.text_file_tail(raw_final.name), _store.text_file_tail(raw_events)
                ) if part
            )
            if isinstance(exc, RaterStalled):
                return rater_stalled(
                    exc, rater, started, command, extra_stdout=output_tail
                )
            return _store.rater_timeout(
                exc, rater, started, deadline, command, extra_stdout=output_tail
            )
        rater["max_quiet_ms"] = proc.max_quiet_ms
        duration = round((time.monotonic() - started) * 1000)
        text = Path(raw_final.name).read_text(errors="replace")
        events = raw_events.read_text(errors="replace") if raw_events.exists() else ""
        if events:
            text += "\n" + events
        stderr = proc.stderr
        if proc.returncode != 0 and not (stderr or "").strip():
            stderr = _accounts.codex_failure_reason(events) or stderr
        return proc.returncode, duration, text, stderr, command
    finally:
        if clone:
            shutil.rmtree(clone, ignore_errors=True)


def claude_stream_result(events_text):
    """The final answer of a `--output-format stream-json` run: its `result` event, which is the
    same object `--output-format json` prints alone. None where the stream never reached one."""
    result = None
    for line in events_text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and event.get("type") == "result":
            result = line
    return result


def run_claude(rater, repo, sha, focus, run_dir, diff, account):
    deadline = rater.get("timeout_s") or _catalog.RATER_TIMEOUT_S
    raw_output = run_dir / f"raw-{_scope.cell_artifact(rater)}.json"
    raw_output.unlink(missing_ok=True)
    raw_events = run_dir / f"raw-events-{_scope.cell_artifact(rater)}.jsonl"
    clone = _prompts.seal_overlay_clone(repo, sha)
    if _prompts.uses_skill_brief(rater):
        prompt = _prompts.skill_brief(sha, focus, clone, _scope.cell_chunk_paths(rater))
    else:
        prompt = (
            _prompts.review_prompt(sha, focus, lens=rater.get("lens"))
            + _prompts.clone_state_note(sha, _scope.cell_chunk_paths(rater))
            + "\n\nCommit diff:\n" + diff
        )
    cwd = clone
    command = [
        _store.command_path("REVIEW_BENCH_CLAUDEB_BIN", "claudeb"), "profile", account,
        "-p", prompt, "--output-format", "stream-json", "--verbose",
        "--model", _catalog.CLAUDE_MODEL_IDS.get(rater["model"], rater["model"]),
        "--effort", rater["effort"],
    ]
    started = time.monotonic()
    try:
        try:
            # The event stream is this side's heartbeat — one line per turn, growing in
            # raw_events, which is what the stall watch reads. The answer is the stream's final
            # `result` event alone: every earlier event is machine chatter finding extraction
            # would read as findings.
            proc = run_streamed(command, cwd=cwd, env=clone_cell_env(run_dir),
                                timeout_s=deadline,
                                stall_s=rater.get("stall_s"), stdout_path=raw_events)
        except subprocess.TimeoutExpired as exc:
            return _store.rater_timeout(
                exc, rater, started, deadline, command,
                extra_stdout=_store.text_file_tail(raw_events),
            )
        except RaterStalled as exc:
            return rater_stalled(
                exc, rater, started, command, extra_stdout=_store.text_file_tail(raw_events)
            )
        rater["max_quiet_ms"] = proc.max_quiet_ms
        duration = round((time.monotonic() - started) * 1000)
        events = raw_events.read_text(errors="replace") if raw_events.exists() else ""
        text = claude_stream_result(events)
        if text is None:
            # A stream that never reached its result event is unusable output whatever the exit
            # code — the one answer asked for once more — and the tail is kept for the wall
            # predicate.
            stderr = "\n".join(part for part in (
                "no result event in the claude stream", (proc.stderr or "").rstrip(),
            ) if part)
            return proc.returncode or 1, duration, _store.text_file_tail(raw_events), stderr, command
        raw_output.write_text(text)
        return proc.returncode, duration, text, proc.stderr, command
    finally:
        if clone:
            shutil.rmtree(clone, ignore_errors=True)


# A weak model asked to review a large diff sometimes summarises it instead: one
# low-severity bullet per hunk, each phrased as a change description. Those parse
# as findings and make the cell look productive, so they would otherwise consume a
# whole adjudication round. Both signals are required, since a real review mixes
# severities and states defects rather than changes.
DIFF_NARRATION_RE = re.compile(
    r"^(new file|added|adds|updated|updates|modified|modifies|extended|extends"
    r"|refactored|refactors|renamed|renames|introduced|introduces|documented"
    r"|documents|implemented|implements|removed|removes)\b",
    re.IGNORECASE,
)
DIFF_NARRATION_MIN_ROWS = 5


def is_diff_narration(findings):
    if len(findings) < DIFF_NARRATION_MIN_ROWS:
        return False
    if any(row.get("severity") != "P3" for row in findings):
        return False
    return all(
        DIFF_NARRATION_RE.match((row.get("summary") or "").strip(" \t*_`#>-")) for row in findings
    )


def opencode_max_tokens_error(stderr):
    return bool(re.search(r"max(?:imum)?[_ -]?tokens?|token.{0,30}(?:limit|maximum)", stderr,
                          re.IGNORECASE))


def opencode_expected_s(rater):
    """Measured cost of one review call, used to order gate admission and scale the
    cell's deadline. A slow cell that starts last stretches the whole run by its own
    duration, so the longest jobs are admitted first."""
    facts = _catalog.OPENCODE_MODEL_FACTS.get(rater["model"], {})
    if rater["effort"]:
        measured = facts.get("low_s") if rater["effort"] == "low" else None
        return measured or _catalog.OPENCODE_EFFORT_EXPECTED_S
    return facts.get("off_s") or _catalog.OPENCODE_EXPECTED_DEFAULT_S


def gate_admission_key(rater):
    """Sort key that starts the gated cells that take longest first.

    Only OpenCode cells share a gate; every other side has its own account and its
    own thread, so their submission order does not affect anything.
    """
    if rater["side"] != "opencode":
        return (1, 0, rater["spec"])
    return (0, -opencode_expected_s(rater), rater["spec"])


def run_opencode(rater, repo, sha, focus, run_dir, diff, account):
    raw_output = run_dir / f"raw-{_scope.cell_artifact(rater)}.json"
    prompt = _prompts.review_prompt(sha, focus, rater["profile"]) + "\n\nCommit diff:\n" + diff
    prompt_file = tempfile.NamedTemporaryFile(
        mode="w", prefix=f"review-bench-{rater['spec']}-", suffix=".txt", delete=False
    )
    prompt_file.write(prompt)
    prompt_file.close()
    # Acquired before the clock starts so a queued rater reports its own
    # request latency, not the time it spent waiting for a gate slot.
    OPENCODE_GATE.acquire(opencode_expected_s(rater))
    started = time.monotonic()
    command = []
    try:
        # Re-checked after the gate: cells already queued when the wall was set would each
        # send one more doomed request, deepening the wall by the queue's depth.
        if _accounts.is_walled("opencode", account):
            return (1, 0, "", _accounts.GATE_WALL_STDERR, command)
        for max_tokens in _catalog.OPENCODE_MAX_TOKENS_BY_MODEL.get(rater["model"], _catalog.OPENCODE_MAX_TOKENS):
            command = [
                _store.command_path("REVIEW_BENCH_OPENCODE_BIN", "opencode-go"),
                "run", _catalog.OPENCODE_MODEL_IDS[rater["model"]],
                "--prompt-file", prompt_file.name,
                "--json", "--max-tokens", str(max_tokens),
                "--answer-must-match", _prompts.OPENCODE_ANSWER_SHAPE,
                # One request per gate hold: the client's own 5xx retries sleep 15-45s INSIDE
                # the slot this cell occupies, while run_rater_task already retries the same
                # transient failure with the gate released. The buffered->stream escalation
                # survives this — opencode-go makes it reachable at --retries 1 by design.
                "--retries", "1",
            ]
            if rater["effort"]:
                command += ["--effort", rater["effort"]]
            if rater["model"] in _catalog.OPENCODE_STREAM_MODELS:
                command.append("--stream")
            # An explicit effort is a request for reasoning; suppressing it would
            # make every effort cell a silent duplicate of the effortless one.
            if not rater["effort"]:
                command.append("--no-reasoning")
            if rater["model"] in _catalog.OPENCODE_PREFILL_MODELS:
                command += ["--prefill", "</think>"]
            # The watchdog's cap and nothing beside it: a second, lower deadline of this side's own
            # killed cells before the cap the run records, so the report named a limit the cell
            # never reached.
            deadline = rater.get("timeout_s") or _catalog.RATER_TIMEOUT_S
            # The client's own buffered wall-clock cap must not fire before the cell's
            # deadline, or a legitimately slow generation dies with nothing received
            # while the cell still had time left.
            env = opencode_env(account, OPENCODE_GO_MAX_WAIT_S=str(deadline))
            try:
                proc = run_streamed(command, timeout_s=deadline,
                                    stall_s=rater.get("stall_s"), env=env)
            except subprocess.TimeoutExpired as exc:
                return _store.rater_timeout(exc, rater, started, deadline, command)
            except RaterStalled as exc:
                return rater_stalled(exc, rater, started, command)
            rater["max_quiet_ms"] = proc.max_quiet_ms
            duration = round((time.monotonic() - started) * 1000)
            raw_output.write_text(proc.stdout)
            if proc.returncode == 0 or not opencode_max_tokens_error(proc.stderr):
                break
        if proc.returncode != 0:
            return proc.returncode, duration, proc.stdout, proc.stderr, command
        try:
            envelope = json.loads(proc.stdout)
        except (json.JSONDecodeError, ValueError) as exc:
            detail = f"opencode returned malformed JSON envelope: {exc}"
            stderr = f"{proc.stderr.rstrip()}\n{detail}".lstrip()
            return 1, duration, "", stderr, command
        if not isinstance(envelope, dict):
            detail = "opencode returned malformed JSON envelope: expected an object"
            stderr = f"{proc.stderr.rstrip()}\n{detail}".lstrip()
            return 1, duration, "", stderr, command
        usage = envelope.get("usage")
        if usage is not None:
            (run_dir / f"usage-{rater['spec']}.json").write_text(
                json.dumps(usage, ensure_ascii=False) + "\n"
            )
        choices = envelope.get("choices")
        if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
            detail = "opencode returned malformed JSON envelope: missing choices[0]"
            stderr = f"{proc.stderr.rstrip()}\n{detail}".lstrip()
            return 1, duration, "", stderr, command
        choice = choices[0]
        message = choice.get("message")
        answer = message.get("content") if isinstance(message, dict) else None
        if not isinstance(answer, str) or not answer.strip():
            finish_reason = choice.get("finish_reason")
            detail = f"opencode returned empty content (finish_reason={finish_reason!r})"
            stderr = f"{proc.stderr.rstrip()}\n{detail}".lstrip()
            return 1, duration, "", stderr, command
        # The MiniMax family streams its reasoning inside the content itself.
        answer = re.sub(r"<think>.*?</think>", "", answer, flags=re.DOTALL | re.IGNORECASE)
        answer = re.sub(r"^\s*<think>.*", "", answer, flags=re.DOTALL | re.IGNORECASE)
        normalized = _prompts.normalize_json_objects(answer)
        parsed = _prompts.normalize_findings(normalized, rater["spec"])
        if is_diff_narration(parsed):
            detail = (
                f"opencode summarised the diff instead of reviewing it ({len(parsed)} "
                "low-severity change descriptions): "
                + " ".join((parsed[0].get("summary") or "").split())[:120]
            )
            stderr = f"{proc.stderr.rstrip()}\n{detail}".lstrip()
            return 1, duration, "", stderr, command
        # An agentic-tuned model with no tools tends to answer with a bare preamble
        # and stop; without this, such a non-review is recorded as a clean review.
        if not parsed and not _prompts.clean_review_declared(answer):
            body = " ".join(answer.split())
            # Told apart because only one of the two is worth another lap. Thirteen of the
            # fourteen recorded OpenCode parse failures are grok-4.5 stopping one line in
            # ("Examining the commit diff for bugs.", ten completion tokens, finish_reason
            # "stop") on a model that succeeded 136 other times, so nothing is wrong with the
            # account and there is no review to salvage. A model that wrote at length and
            # still parsed to nothing has answered, just not with findings, and asking again
            # buys a second full review of the same prose.
            stub = len(body) <= _accounts.OPENCODE_STUB_MAX_CHARS
            detail = (
                f"{_accounts.OPENCODE_STUB_STDERR}: {body[:200]}" if stub else
                "opencode returned no parseable findings and no explicit no-issues result: "
                + body[:200]
            )
            stderr = f"{proc.stderr.rstrip()}\n{detail}".lstrip()
            return 1, duration, "", stderr, command
        return 0, duration, normalized, proc.stderr, command
    finally:
        OPENCODE_GATE.release()
        Path(prompt_file.name).unlink(missing_ok=True)


# A cheap in-plan model reviewing a large diff mostly produces claims about code
# that is not there: of 59 adjudicated OpenCode findings on 143fc2f only 8 were real.
# Handing that to an expensive reviewer costs more than the cheap review saves, so
# every finding is checked back against the file it cites by another cheap call.
# Measured with kimi-k3 on the same corpus: 46 of 51 false positives dropped, 6 of 8
# real findings kept, 59 rows to adjudicate down to 15. The check fails open — an
# unusable verifier answer keeps the finding, because losing a real defect to
# infrastructure is worse than one more row to read.
VERIFY_MAX_TOKENS = 2000
VERIFY_WINDOW_LINES = 120
VERIFY_WHOLE_FILE_LINES = 600
VERIFY_TIMEOUT_S = 300
GEMINI_VERIFY_PRINT_TIMEOUT_S = 180
GEMINI_VERIFY_PRINT_TIMEOUT = f"{GEMINI_VERIFY_PRINT_TIMEOUT_S // 60}m"
def agy_failure_detail(stderr, log_text):
    combined = "\n".join(part for part in (stderr.strip(), log_text) if part)
    patterns = (
        r"jetski: no output produced[^\n]*",
        r"Individual quota reached[^\n]*",
        r"RESOURCE_EXHAUSTED[^\n]*",
        # Antigravity reports a per-model exhaustion only in its log, and SIDE_WALL reads the
        # stderr this detail becomes: unrecognised here, the wall never retires the account.
        r"exhausted your capacity on this model[^\n]*",
        r"You are not logged into Antigravity[^\n]*",
        r"tool required the .command. permission[^\n]*",
    )
    for pattern in patterns:
        match = re.search(pattern, combined, re.IGNORECASE)
        if match:
            return " ".join(match.group(0).split())
    return stderr.strip() or "agy returned empty output without an error detail"


def agy_model_id(rater):
    model = _catalog.AGY_MODEL_IDS[rater["model"]]
    if rater["model"] == "agy-pro" and rater["effort"] == "high":
        return "Gemini 3.1 Pro (High)"
    return f"{model}-{rater['effort']}"


def agy_served_labels(log_text):
    return re.findall(r'Propagating selected model override.*?label="([^"]+)"', log_text)


def agy_model_mismatch(labels, rater):
    """The models agy served that are not the one asked for.

    A spelling agy cannot resolve is served as another model without any error, and one run can
    switch models mid-flight, so every propagated label has to match, not just the last.
    """
    return [label for label in dict.fromkeys(labels) if label != agy_expected_label(rater)]


def agy_expected_label(rater):
    if rater["model"] == "agy-pro":
        return f"Gemini 3.1 Pro ({rater['effort'].capitalize()})"
    version = _catalog.AGY_MODEL_IDS[rater["model"]].split("-")[1]
    return f"Gemini {version} Flash ({rater['effort'].capitalize()})"


def write_agy_usage(run_dir, rater, duration, log_text):
    usage = {
        "duration_ms": duration,
        "model": agy_model_id(rater),
        "effort": rater["effort"],
    }
    labels = agy_served_labels(log_text)
    if labels:
        usage["resolved_model_label"] = labels[-1]
        served = agy_model_mismatch(labels, rater)
        if served:
            usage["model_mismatch"] = served
    requests = len(re.findall(r"\bstreamGenerateContent\b", log_text))
    completions = len(re.findall(r"\bStream completed\b", log_text))
    if requests:
        usage["stream_generate_requests"] = requests
    if completions:
        usage["stream_completions"] = completions
    token_keys = {
        "promptTokenCount": "prompt_tokens",
        "candidatesTokenCount": "output_tokens",
        "totalTokenCount": "total_tokens",
        "cachedContentTokenCount": "cached_tokens",
        "thoughtsTokenCount": "reasoning_tokens",
    }
    for log_key, usage_key in token_keys.items():
        matches = re.findall(
            rf'(?i)\b{log_key}\b["\s:=]+(\d+)', log_text
        )
        if matches:
            usage[usage_key] = max(map(int, matches))
    path = run_dir / f"usage-{_scope.cell_artifact(rater)}.jsonl"
    path.write_text(json.dumps(usage, ensure_ascii=False) + "\n")
    return usage


def run_agy(rater, repo, sha, focus, run_dir, diff, account):
    raw_output = run_dir / f"raw-{_scope.cell_artifact(rater)}.md"
    log_file = run_dir / f"agy-{_scope.cell_artifact(rater)}.log"
    model = agy_model_id(rater)
    timeout_s = rater.get("timeout_s") or _catalog.AGY_TIMEOUT_MAX_S
    print_timeout = f"{timeout_s // 60}m" if timeout_s % 60 == 0 else f"{timeout_s}s"
    prompt = ("/code-review"
              + _prompts.chunk_instruction(sha, _scope.cell_chunk_paths(rater))
              + (f"\nAdditional review focus: {focus}" if focus else ""))
    # agy resolves its Google account from HOME and takes no account flag, so the profile has to be
    # selected by launching it through geminib rather than by an argument.
    command = [_store.command_path("REVIEW_BENCH_GEMINIB_BIN", "geminib"), "profile", account]
    command += [
        "--model", model,
    ]
    command += [
        "--mode", "plan",
        "--new-project", "--dangerously-skip-permissions",
        "--print-timeout", print_timeout,
        "--log-file", str(log_file),
    ]
    transport = command + ["--print", prompt]
    displayed_command = list(transport)
    clone = None
    started = time.monotonic()
    try:
        clone = _prompts.seal_overlay_clone(repo, sha)
        prepare_agy_skill_clone(clone)
        try:
            # The CLI's own log is this side's heartbeat: a working cell appends to it steadily,
            # and the hung one — the mode this watch exists for — goes silent there first.
            proc = run_streamed(
                transport, cwd=clone, env=clone_cell_env(run_dir),
                timeout_s=timeout_s + _catalog.AGY_TIMEOUT_GRACE_S,
                stall_s=rater.get("stall_s"), watch_paths=[log_file],
            )
        except (subprocess.TimeoutExpired, RaterStalled) as exc:
            if isinstance(exc, RaterStalled):
                result = rater_stalled(exc, rater, started, displayed_command)
            else:
                result = _store.rater_timeout(exc, rater, started, timeout_s, displayed_command)
            duration = result[1]
            log_text = log_file.read_text(errors="replace") if log_file.exists() else ""
            write_agy_usage(run_dir, rater, duration, log_text)
            return result
        rater["max_quiet_ms"] = proc.max_quiet_ms
        duration = round((time.monotonic() - started) * 1000)
        raw_output.write_text(proc.stdout)
        log_text = log_file.read_text(errors="replace") if log_file.exists() else ""
        usage = write_agy_usage(run_dir, rater, duration, log_text)
        # Fail closed like every other unusable answer: findings produced by a model the cell did
        # not ask for are a false measurement, which is worse for a benchmark than a missing one.
        if usage.get("model_mismatch"):
            served = ", ".join(usage["model_mismatch"])
            return (
                1, duration, "",
                f"agy served {served} instead of {agy_expected_label(rater)}",
                displayed_command,
            )
        if proc.returncode != 0:
            # geminib enforces the cap itself (`--print-timeout`), so OUR budget firing on this
            # side arrives as the client's own nonzero exit, not exit 124: a failure at or past
            # the cap is the cap. Unlabeled, it read exactly like the model dying on its own.
            if duration >= timeout_s * 1000:
                rater["killed"] = "watchdog"
                rater["killed_cap_s"] = timeout_s
            return proc.returncode, duration, proc.stdout, proc.stderr, displayed_command
        if not proc.stdout.strip():
            detail = agy_failure_detail(proc.stderr, log_text)
            return 1, duration, "", f"agy returned empty output: {detail}", displayed_command
        try:
            normalized = _prompts.normalize_agy_skill_output(proc.stdout, rater["spec"])
        except ValueError as exc:
            stderr = f"{proc.stderr.rstrip()}\n{exc}".lstrip()
            return 1, duration, "", stderr, displayed_command
        return 0, duration, normalized, proc.stderr, displayed_command
    finally:
        if clone:
            shutil.rmtree(clone, ignore_errors=True)


SIDE_RUNNERS = {
    "claude": run_claude,
    "codex": run_codex,
    "agy": run_agy,
    "opencode": run_opencode,
}
# The two answers worth asking one more time whatever they cost: a cell that produced nothing
# readable and a provider that answered with its own fault.
CELL_RETRY_CAUSES = ("bad output", "server error")
# And below this, any nonzero exit is worth one more too, whatever named it. Measured over 665
# stored runs (2026-08-27): almost every death on a big diff is instant — "no output", "pool
# empty", "unclassified", "bad command" at dur/cap 0.00-0.03 — so the second attempt costs the
# panel seconds, while the cell it saves is a whole rater's coverage. A cell that ran for real
# and then died is a different answer and keeps the old rule.
CELL_FAST_DEATH_S = 30
# Except these. Two classes with one answer: an account that refused for ITSELF is answered by the
# pool's next account and never by asking it again (or, for `pool empty`, by nothing at all), and a
# cap or stall kill ENDS the cell — 0 of 9 cap-kill retries on record ever produced a confirmed
# finding, at a median 7.2 minutes of panel wall each. The kill is usually the `killed` marker, and
# named here as well because a row carrying its wording without the marker is the same cell.
CELL_FAST_DEATH_EXCLUDED = (
    "pool empty", "walled", "throttled", "bare 429", "permission", "auth", "timeout", "stalled",
)
# Launches one pass may spend on the same answer — transient waits and retry causes together, a
# wall spending none; a chunked cell has one budget per chunk. Past it the answer stands: one agy
# cell walked the pool seven times for a 45-minute cell, and 35 such cells burned 280 wall minutes.
CELL_ATTEMPTS_MAX = 2


def cell_retry_cause(rc, text, stderr, rater, duration_ms=None):
    """Why this attempt is worth one more, or None where its answer is the cell's answer."""
    if rater.get("killed"):
        return None
    if rc != 0:
        reason = _panel.failure_reason(stderr)
    elif text and _accounts.is_429_error(text):
        reason = None
    else:
        reason = "bad output" if _prompts.unusable_review(
            text, _prompts.normalize_findings(text, rater["spec"])
        ) else None
    if reason in CELL_RETRY_CAUSES:
        return reason
    if rc == 0 or reason in CELL_FAST_DEATH_EXCLUDED:
        return None
    # An unmeasured attempt is not a fast one: nothing here may turn a cell that ran for its whole
    # cap into a retry because its duration went unrecorded.
    if duration_ms is None or duration_ms >= CELL_FAST_DEATH_S * 1000:
        return None
    return reason


def superseded_attempt(rater, account, result):
    """The rater_run row a retried attempt leaves behind.

    Recorded rather than dropped: what it cost is part of the cell's own stretch of the wall clock.
    Every surface that counts CELLS reads the LAST row of a spec, so this one is never counted as
    a cell of its own — see `cell_attempt_rows`.
    """
    rc, duration, _text, stderr, command = result
    row = {
        "rater": rater["spec"], "model": rater["model"], "effort": rater["effort"],
        "side": rater["side"], "account": account, "duration_ms": duration,
        "findings": 0, "exit_code": rc, "stderr": (stderr or "")[-2000:],
        "command": redact_command(rater, command), "errored": True,
        "timeout_s": rater.get("timeout_s"),
        "started_at": rater.get("started_at"), "finished_at": rater.get("finished_at"),
    }
    for key in ("stalled_s", "max_quiet_ms", "killed", "killed_cap_s"):
        if rater.get(key) is not None:
            row[key] = rater[key]
    return row


def run_rater_task(rater, repo, sha, focus, run_dir, diff):
    """Run one rater, asking the pool for another account each time one walls off."""
    side = rater["side"]
    bucket = _accounts.wall_bucket(rater)
    walled = set()
    result = None
    account = None
    # Per account, and remembered for every account this cell visits: a budget spent waiting
    # out one account's throttle would leave the next account with no retries and wall it on
    # its first hiccup, while re-creating it whenever the pool comes back to an account it
    # already tried would let the two refill each other and spin the cell forever.
    budgets = defaultdict(lambda: list(_accounts.transient_backoffs()))
    rater["attempts"] = 0
    while True:
        try:
            candidate = _accounts.pool_account(side, walled, rater.get("slot", 0), bucket)
        except Exception as exc:
            return (rater, account, (1, 0, "", f"{side} account lookup failed: {exc}", []))
        # A repeated candidate means the pool ignored the exclusion, which would otherwise spin.
        if candidate is None or candidate in walled:
            break
        # Another rater may have retired this account since the pool last measured anything, so
        # it is excluded and the pool asked again rather than the rater giving up on the side.
        if _accounts.is_walled(side, candidate, bucket):
            walled.add(candidate)
            continue
        account = candidate
        # Per attempt, never carried over: a stall marker or gap left by a killed attempt must
        # not be reported as the retry's.
        rater.pop("stalled_s", None)
        rater.pop("max_quiet_ms", None)
        rater.pop("killed", None)
        rater.pop("killed_cap_s", None)
        attempt_started = _store.utc_now()
        try:
            result = SIDE_RUNNERS[side](rater, repo, sha, focus, run_dir, diff, candidate)
        except Exception as exc:
            return (rater, candidate, (1, 0, "", f"rater task crashed: {exc}", []))
        # Stamped per attempt and overwritten by the retry: the report reads them to price what
        # each cell's slot held, and a queue the run spent on the attempt nobody kept is not this
        # cell's own wait.
        rater["started_at"] = attempt_started.isoformat()
        rater["finished_at"] = _store.iso_now()
        rc, duration_ms, text, stderr, _ = result
        # The account walled while this cell sat in the gate queue. Nothing was sent, so this
        # is not evidence against the account, and the side may still have other accounts.
        if side == "opencode" and stderr == _accounts.GATE_WALL_STDERR:
            walled.add(candidate)
            continue
        # Every launch that reached the provider is one attempt of this pass; a wall hands it
        # back below, since the account answered for itself and not for the cell.
        rater["attempts"] = rater.get("attempts", 0) + 1
        wall_text = (
            _store.text_file_tail(run_dir / f"raw-events-{_scope.cell_artifact(rater)}.jsonl")
            if side == "codex" else text
        )
        # A server-side hiccup, a burst throttle and a spent subscription arrive as the same
        # status code. Retiring an account for either of the first two empties the pool of
        # accounts that were never out of quota, so they are waited out here and only the
        # wall predicate below, which insists on the plan wording, can retire anything.
        # A kill of ours is never asked again, whatever its partial stderr says: a 503 in the
        # tail of a hung cell is not a server error to wait out. The wall predicate still reads
        # it, since an account that walled mid-hang is walled.
        may_retry = rater["attempts"] < CELL_ATTEMPTS_MAX and not rater.get("killed")
        if may_retry and rc != 0 and budgets[candidate] and _accounts.SIDE_TRANSIENT.get(
            side, _accounts._never_transient
        )(rc, wall_text, stderr):
            delay = budgets[candidate].pop(0)
            print(f"{rater['spec']}: {side} account {candidate} answered with a transient "
                  f"failure ({_panel.failure_reason(stderr)}); retrying in {delay:g}s")
            if delay:
                time.sleep(delay)
            continue
        # Asked BEFORE any retry, because on claude and codex the plan wording lives in the
        # answer rather than in stderr: classified off stderr alone such an attempt reads as
        # "unclassified", takes the fast-death retry, and the account is never retired — so the
        # spent plan eats the second attempt and the next account inherits none.
        walled_off = _accounts.SIDE_WALL[side](rc, wall_text, stderr)
        retry_cause = (
            cell_retry_cause(rc, text, stderr, rater, duration_ms)
            if may_retry and not walled_off else None
        )
        if retry_cause:
            rater.setdefault("superseded", []).append(
                superseded_attempt(rater, candidate, result)
            )
            rater["retry_of"] = retry_cause
            print(f"{rater['spec']}: {retry_cause}; retrying once")
            continue
        if not walled_off:
            return (rater, candidate, result)
        wall_source = _accounts.wall_reset_source(side, stderr, wall_text)
        _accounts.mark_walled(side, candidate, bucket, _accounts.wall_reset_at(wall_source),
                    _accounts.opencode_wall_window(wall_source) if side == "opencode" else None)
        walled.add(candidate)
        print(f"{rater['spec']}: {side} account {candidate} hit its usage wall")
        # A run can succeed while its output already carries the wall wording: the review is
        # kept and only the account is retired. A killed one is retired the same way and ends
        # here: relaunched on the next account, the kill would be hidden and the cell would run
        # past its hard stop.
        if rc == 0 or rater.get("killed"):
            return (rater, candidate, result)
        rater["attempts"] -= 1
    if result is None:
        return (rater, None, (1, 0, "",
                              _accounts.no_account_left(side, _accounts.baseline_exclusion_note(side)
                                              + _accounts.role_closed_note(side)), []))
    return (rater, account, result)


def chunk_pass_failure(spec, rc, text, stderr):
    """Why this chunk's pass is not one the run may attest, or "" where it came back.

    The exit code is not what a cell is judged by anywhere else: an answer of prose, an empty one
    or a 429 in the text is unusable output. Counted as read it is invisible — the cell's answer is
    its chunks joined, so another chunk's findings or clean marker carry it — and the paths of a
    chunk nobody reviewed are attested as read.
    """
    if rc != 0:
        return (((stderr or text or "").strip() or "no output"))[-400:]
    if text and _accounts.is_429_error(text):
        return "the account answered 429"
    return _prompts.unusable_review(text, _prompts.normalize_findings(text, spec))[:400]


def run_rater_chunks(rater, repo, sha, focus, run_dir, diff, chunks):
    """One cell, reading its chunks one after another under a single rater name.

    Chunking splits the DIFF and never the panel: a cell per (rater, chunk) turned a 13-cell tier
    over a 25-chunk commit into 325 concurrent cells and hundreds of processes (live, 2026-08-22),
    so the panel keeps exactly the cells its tier asked for whatever the diff's size. The passes
    that came back are named in `chunks_read`, which is what the receipt attests: a cell that lost
    one chunk keeps the findings of the others and leaves that chunk's paths in debt, rather than
    paying for one dead pass with everything the cell did read.

    `passes` is how many invocations the recorded duration is the sum of. Every reader of that
    number — the watchdog cap, the duration median, the late line — prices ONE invocation, and a
    cell's total handed to them reads as a rater that suddenly got N times slower.
    """
    if not chunks:
        rater["chunks_read"] = []
        return run_rater_task(rater, repo, sha, focus, run_dir, diff)
    read = []
    texts = []
    notes = []
    elapsed = 0
    account = None
    last = None
    # Every pass clears the kill markers of the one before it (`run_rater_task`), so without this
    # a watchdog or stall kill in an early chunk reaches neither the run's record nor `timed_out`,
    # and the cap that fired learns nothing from the hang it fired at.
    marks = {}
    # Every pass overwrites `started_at` too, and the cell's `duration_ms` is the SUM of them all:
    # left at the last chunk's stamp, the cell reads as having sat in a queue for everything the
    # chunks before it took, and the header names a leg that never held it.
    cell_started = None
    passes = 0
    for chunk in chunks:
        rater["chunk"] = chunk
        _, account, last = run_rater_task(
            rater, repo, sha, focus, run_dir, chunk["diff"]
        )
        passes += 1
        cell_started = cell_started or rater.get("started_at")
        rc, duration, text, stderr, _ = last
        elapsed += duration
        for key in ("stalled_s", "killed", "killed_cap_s"):
            if rater.get(key) is not None and key not in marks:
                marks[key] = rater[key]
        quiet = rater.get("max_quiet_ms")
        if quiet is not None:
            marks["max_quiet_ms"] = max(quiet, marks.get("max_quiet_ms", quiet))
        failure = chunk_pass_failure(rater["spec"], rc, text, stderr)
        if failure:
            notes.append(f"chunk {chunk['index']}: exit {rc}: {failure}")
        else:
            read.append(chunk["index"])
            texts.append(text or "")
        print(f"{rater['spec']}: chunk {chunk['index'] + 1}/{len(chunks)}, "
              f"{duration} ms, exit {rc}")
        # A kill ends the whole cell: the chunks after it are not read, and are left in debt.
        if rater.get("killed"):
            break
    rater.pop("chunk", None)
    rater.update(marks)
    if cell_started:
        rater["started_at"] = cell_started
    rater["chunks_read"] = read
    rater["passes"] = passes
    if not read:
        rc, _, text, stderr, command = last
        return (rater, account, (rc or 1, elapsed, text, stderr, command))
    return (rater, account, (0, elapsed, "\n\n".join(texts), "\n".join(notes), last[4]))


def redact_command(rater, command):
    if not command:
        return ""
    if rater["side"] == "codex":
        return shlex.join(command)
    if rater["side"] == "opencode":
        redacted = list(command)
        prompt_index = redacted.index("--prompt-file") + 1
        redacted[prompt_index] = "<review-prompt-file>"
        return shlex.join(redacted)
    if rater["side"] == "agy":
        return shlex.join(command)
    placeholder = "<worker-brief>" if _prompts.uses_skill_brief(rater) else "<review-prompt-and-diff>"
    return shlex.join(command[:4] + [placeholder] + command[5:])


