"""The hook-time journal and the hook owner map, shared by bin/harness-doctor (its Hooks section and floors) and
share/time_budget.py (Lost time's hooks row). Every settings hook sources claude-setup `hooks/lib/hook-time.sh`, which
appends `start_us end_us key exit ppid cpu_us` to `<HARNESS_DOCTOR_DIR>/hooks/<epoch day>.tsv` (bash 3.2 runs through
`hooks/spool/`, folded by the doctor into `hooks/folded/`). A run's key is its script's base name and first word
(`hook_key`); its ppid is the Claude process that ran it, which `join_calls` maps to a session."""

import bisect
import glob
import json
import os
import pickle
import re
import sys

SYNC_EVENTS = ("PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop", "SubagentStop", "SessionStart",
               "PreCompact", "SessionEnd")
TOOL_EVENTS = ("PreToolUse", "PostToolUse")
# A Stop hook's seconds are its turn's `stop` part, and a SessionEnd one blocks no model: neither is a blocking run.
UNBLOCKING_EVENTS = ("Stop", "SubagentStop", "SessionEnd")
STOP_EVENTS = ("Stop", "SubagentStop")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
OTHER_TOOL = "(other)"
STOP_PART = "stop.d/"
RUNS_V = 2
BATCH_SPAN_S = 1.0
PRE_JOIN_S = (-0.05, 0.5)
POST_JOIN_S = (-0.05, 3.0)


def base_home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def state_dir():
    return os.environ.get("HARNESS_DOCTOR_DIR") or os.path.join(base_home(), ".cache", "harness-doctor")


def settings_path():
    return os.environ.get("HARNESS_SETTINGS") or os.path.join(base_home(), ".claude", "settings.json")


def settings_hooks():
    try:
        with open(settings_path()) as handle:
            settings = json.load(handle)
    except (OSError, ValueError):
        settings = {}
    out = []
    for event, groups in ((settings.get("hooks") if isinstance(settings, dict) else None) or {}).items():
        for group in groups or []:
            matcher = str(group.get("matcher") or "")
            for hook in group.get("hooks") or []:
                if hook.get("type", "command") != "command":
                    continue
                out.append({"event": event, "matcher": matcher, "command": str(hook.get("command") or ""),
                            "timeout": hook.get("timeout"), "async": bool(hook.get("async")),
                            "status": str(hook.get("statusMessage") or "")})
    return out


def hook_script(command):
    word = (command or "").split()[0] if (command or "").split() else ""
    if word.startswith("~/"):
        word = os.path.join(base_home(), word[2:])
    return word if word.startswith("/") and os.path.isfile(word) else ""


def hook_key(command):
    words = (command or "").split()
    if not hook_script(command):
        return command or ""
    return os.path.basename(words[0]) + (" " + words[1] if len(words) > 1 else "")


def matches(matcher, tool):
    if matcher in ("", "*"):
        return True
    try:
        return re.fullmatch(matcher, tool) is not None
    except re.error:
        return matcher == tool


# ---------------------------------------------------------------- the journal


def run_row(fields):
    start, end = int(fields[0]) / 1e6, int(fields[1]) / 1e6
    cpu = fields[5] if len(fields) > 5 else ""
    return (end, sys.intern(fields[2]), (end - start) * 1000.0, fields[3] != "0", start,
            sys.intern(fields[4]) if len(fields) > 4 else "", int(cpu) / 1000.0 if cpu.isdigit() else None)


def cached_runs(path, cache, write):
    """One journal file's rows: the cache's pickled chunks `(RUNS_V, ino, head, from, to, first, rows)` up to its
    last offset, plus the bytes after it; a changed inode or head, or a shorter file, reads it again from 0."""
    try:
        info = os.stat(path)
        with open(path, "rb") as handle:
            head = handle.read(64)
            off, first, rows, reset = 0, None, [], False
            try:
                with open(cache, "rb") as stored:
                    while True:
                        try:
                            version, ino, was, start, stop, low, part = pickle.load(stored)
                        except EOFError:
                            break
                        if version != RUNS_V or ino != info.st_ino or not head.startswith(was):
                            raise ValueError(cache)
                        if start == off:
                            off = stop
                            rows.extend(part)
                            first = low if first is None or (low is not None and low < first) else first
            except FileNotFoundError:
                pass
            except Exception:
                off, first, rows, reset = 0, None, [], True
            if info.st_size < off:
                off, first, rows, reset = 0, None, [], True
            handle.seek(off)
            data = handle.read()
    except OSError:
        return [], None
    end = data.rfind(b"\n") + 1
    new = []
    for text in data[:end].decode("utf-8", "replace").splitlines():
        try:
            new.append(run_row(text.split("\t")))
        except (ValueError, IndexError):
            pass
    low = min((r[4] for r in new), default=None)
    if write and (end or reset):
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        with open(cache, "wb" if reset or not off else "ab") as stored:
            pickle.dump((RUNS_V, info.st_ino, head, off, off + end, low, new), stored,
                        protocol=pickle.HIGHEST_PROTOCOL)
    first = low if first is None or (low is not None and low < first) else first
    return rows + new, first


def journal_runs(since, extra=(), write=False):
    """`(end, key, ms, failed, start, ppid, cpu_ms)` of every journal line ending after `since`, and the earliest start;
    hook-runs/ caches each file's parsed lines, so a pass parses only new bytes (a reader that does not write still
    reads the cache). `extra` are spool runs a non-persisting run folded but did not write to hooks/folded."""
    runs, first, names = [], None, set()
    folder = os.path.join(state_dir(), "hook-runs")
    for sub in ("hooks", "hooks/folded"):
        for path in sorted(glob.glob(os.path.join(state_dir(), sub, "*.tsv"))):
            name = sub.replace("/", "-") + "-" + os.path.basename(path)[:-4] + ".pickle"
            names.add(name)
            rows, low = cached_runs(path, os.path.join(folder, name), write)
            runs += [r for r in rows if r[0] > since]
            first = low if first is None or (low is not None and low < first) else first
    for run in extra:
        row = run_row([str(field) for field in run])
        first = row[4] if first is None else min(first, row[4])
        if row[0] > since:
            runs.append(row)
    if write:
        for path in glob.glob(os.path.join(folder, "*.pickle")):
            if os.path.basename(path) not in names:
                try:
                    os.remove(path)
                except OSError:
                    pass
    return runs, first


# ---------------------------------------------------------------- batches and their owners


def hook_slots(hooks, tools):
    """Every (event, tool) a synchronous hook key can run for; the tool is "" off the tool events."""
    slots = {}
    for hook in hooks:
        if hook["async"] or hook["event"] not in SYNC_EVENTS:
            continue
        mine = slots.setdefault(hook_key(hook["command"]), set())
        if hook["event"] in TOOL_EVENTS:
            mine.update((hook["event"], tool) for tool in tools if matches(hook["matcher"], tool))
        else:
            mine.add((hook["event"], ""))
    return {key: value for key, value in slots.items() if value}


def call_slots(hooks, calls):
    """`hook_slots` over the tools the calls used plus the usual ones."""
    return hook_slots(hooks, {c[3] for c in calls} | {"Bash", "Read", OTHER_TOOL} | EDIT_TOOLS)


def blocking_slots(slots):
    """The slots of the keys whose runs block a model: a settings hook that is not async (`hook_slots`), on some event
    but Stop and SessionEnd. A detached child (`<mode>-bg`, `__<mode>`) or a stop.d part is no settings key, so it is
    never one; a new hook is one the day its settings entry sources hook-time.sh."""
    return {key: slot for key, slot in slots.items() if any(event not in UNBLOCKING_EVENTS for event, _ in slot)}


def family_slots(calls):
    """{family: {key: slots}} of the settings keys Lost time counts: `hooks` the blocking ones (`blocking_slots`),
    `stop` the rest that run when a turn stops (Stop, SubagentStop), whose seconds are their turn's `stop` part."""
    slots = call_slots(settings_hooks(), calls)
    blocking = blocking_slots(slots)
    return {"hooks": blocking, "stop": {key: slot for key, slot in slots.items() if key not in blocking
                                        and any(event in STOP_EVENTS for event, _ in slot)}}


def family_runs(runs, calls, lo, hi, family):
    """The runs of one family's keys (`family_slots`) ending in [lo, hi), by their end: the runs `blocking_runs`
    batches, with no owner to find."""
    keys = family_slots(calls)[family]
    return sorted((r for r in runs if lo <= r[0] < hi and r[1] in keys and not r[1].startswith(STOP_PART)),
                  key=lambda r: r[0])


def hook_batches(runs, slots, now):
    """Hooks of one event run together: runs of one Claude process (ppid) that start within BATCH_SPAN_S
    of the batch's first run, no key twice, and share at least one (event, tool) they could all run for."""
    by_ppid = {}
    for run in runs:
        if run[1] in slots and run[0] <= now and not run[1].startswith(STOP_PART):
            by_ppid.setdefault(run[5], []).append(run)
    batches = []
    for ppid, items in by_ppid.items():
        items.sort(key=lambda r: r[4])
        live = []
        for run in items:
            live = [b for b in live if run[4] - b["t0"] <= BATCH_SPAN_S]
            for batch in live:
                both = batch["slots"] & slots[run[1]]
                if run[1] not in batch["runs"] and both:
                    batch["runs"][run[1]] = run
                    batch["slots"] = both
                    break
            else:
                batch = {"t0": run[4], "ppid": ppid, "runs": {run[1]: run}, "slots": set(slots[run[1]])}
                live.append(batch)
                batches.append(batch)
    # Its setter is the run whose removal shortens it most, the first to start or the last to end: a trivial hook
    # spawned last ends last without holding the batch.
    for batch in batches:
        runs = batch["runs"]
        last = max(runs.values(), key=lambda r: r[0])
        first = min(runs.values(), key=lambda r: r[4])
        by = first[1] if span_without(runs, first[1]) < span_without(runs, last[1]) else last[1]
        batch.update(end=last[0], by=by, ms=(last[0] - batch["t0"]) * 1000.0)
    return batches


def span_without(runs, key):
    others = [r for k, r in runs.items() if k != key]
    return (max(r[0] for r in others) - min(r[4] for r in others)) * 1000.0 if others else 0.0


def join_calls(batches, calls):
    """Pins a batch to its tool call: a PreToolUse batch starts just after the call's tool_use, a
    PostToolUse one ends just before its tool_result. A ppid's session comes from its unambiguous
    Pre joins and then rules out other chats' calls."""
    by_start = sorted(calls, key=lambda c: c[1])
    starts = [c[1] for c in by_start]
    by_end = sorted(calls, key=lambda c: c[1] + c[5])
    ends = [c[1] + c[5] for c in by_end]

    def pre_candidates(batch):
        low = bisect.bisect_left(starts, batch["t0"] - PRE_JOIN_S[1])
        high = bisect.bisect_right(starts, batch["t0"] - PRE_JOIN_S[0])
        return [c for c in by_start[low:high] if ("PreToolUse", c[3]) in batch["slots"]]

    votes = {}
    for batch in batches:
        found = pre_candidates(batch)
        if len(found) == 1 and len(found[0]) > 8:
            tally = votes.setdefault(batch["ppid"], {})
            tally[found[0][8]] = tally.get(found[0][8], 0) + 1
    owner = {}
    for ppid, tally in votes.items():
        best = max(sorted(tally), key=tally.get)
        if tally[best] >= 2 and tally[best] >= 0.6 * sum(tally.values()):
            owner[ppid] = best

    def fits(batch, call):
        mine = owner.get(batch["ppid"])
        return not mine or len(call) <= 8 or call[8] == mine

    ordered = sorted(batches, key=lambda b: b["t0"])
    taken = set()
    for batch in ordered:
        found = [c for c in pre_candidates(batch) if fits(batch, c) and ("pre", c[7]) not in taken]
        if found:
            call = min(found, key=lambda c: abs(batch["t0"] - c[1]))
            batch.update(call=call, event="PreToolUse")
            taken.add(("pre", call[7]))
    for batch in ordered:
        if "call" in batch or not any(s[0] == "PostToolUse" for s in batch["slots"]):
            continue
        low = bisect.bisect_left(ends, batch["end"] + POST_JOIN_S[0])
        high = bisect.bisect_right(ends, batch["end"] + POST_JOIN_S[1])
        found = [c for c in by_end[low:high] if c[1] <= batch["t0"] and ("PostToolUse", c[3]) in batch["slots"]
                 and fits(batch, c) and ("post", c[7]) not in taken]
        if found:
            call = min(found, key=lambda c: c[1] + c[5] - batch["end"])
            batch.update(call=call, event="PostToolUse")
            taken.add(("post", call[7]))
    return owner


def blocking_runs(runs, calls, lo, hi):
    """`(run, session, family)` of every journal run of a `family_slots` key overlapping [lo, hi): its session the one
    of the call its batch joined, else its ppid's (`join_calls`), else None (no owner). A Stop key shares no slot with
    a blocking one, so its runs batch apart and never move a blocking run's owner."""
    found = family_slots(calls)
    family = {key: name for name, keys in found.items() for key in keys}
    batches = hook_batches([r for r in runs if r[0] > lo and r[4] < hi], dict(found["hooks"], **found["stop"]),
                           float("inf"))
    owner = join_calls(batches, calls)
    out = []
    for batch in batches:
        call = batch.get("call")
        session = call[8] if call is not None and len(call) > 8 else owner.get(batch["ppid"])
        out += [(run, session, family[run[1]]) for run in batch["runs"].values()]
    return out
