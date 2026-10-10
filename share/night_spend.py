"""The mechanical header of `night-run report`: duration, jobs, worker runs, review rounds and token
spend by kind and model in Opus-equivalent tokens, the total compared against the previous finished night.

A usage Counter maps a model label (Claude family or vendor) to Opus-eq tokens, priced by token-map's
`tokenmap/pricing.py` the way its menu weighs a model: one Opus input token is 1.

Read-only over the run, bench and transcript stores; every root follows the same environment
override its writer honours, so tests point it at fixtures.
"""

import __future__
import collections
import datetime as dt
import functools
import glob
import json
import os
import subprocess
import sys
import time
import types

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chat_names  # noqa: E402

UNIT = "Opus-eq"
OPUS = "claude-opus-5"
HOME = os.path.expanduser("~")
RUNS = os.environ.get("WORKER_RUN_DIR") or f"{HOME}/.cache/claude-worker-runs"
BENCHES = (os.environ.get("WORKER_STATS_DIR")
           or f"{os.environ.get('CLAUDEB_DIR') or HOME + '/.claude-profiles/.claudeb'}/worker-stats") + "/benches"


@functools.lru_cache(maxsize=None)
def pricing():
    checkout = os.path.dirname(os.path.dirname(os.path.abspath(__file__))).split(chat_names.WORKTREES)[0]
    root = os.environ.get("TOKENMAP_ROOT") or os.path.join(os.path.dirname(checkout), "token-map")
    path = os.path.join(root, "tokenmap", "pricing.py")
    if not os.path.isfile(path):
        sys.exit(f"night_spend: no token-map checkout at {root} (set TOKENMAP_ROOT); spend is priced by its pricing.py")
    # /usr/bin/python3 (3.9) runs this and pricing.py annotates `str | None`: only postponed annotations load it.
    table = types.ModuleType("tokenmap_pricing")
    table.__file__ = path
    sys.modules[table.__name__] = table
    with open(path) as handle:
        exec(compile(handle.read(), path, "exec", __future__.annotations.compiler_flag, dont_inherit=True),
             table.__dict__)
    return table


def opus_usd():
    return pricing().price_for(OPUS, dt.date.today().isoformat())[0] / 1e6


def claude_model(model):
    """A bare alias (`opus`) as the newest model of its family in token-map's price list."""
    if model and "-" not in model and not model.startswith("<"):
        return next((name for name in pricing().PRICES if name.startswith(f"claude-{model}-")), model)
    return model or "unknown"


def claude_eq(model, day, fresh=0, cache_read=0, cache_5m=0, cache_1h=0, out=0, fast=False):
    """{label: Opus-eq} of one Claude request; a routed model (claudegpt) prices as its vendor's."""
    model = claude_model(model)
    vendor = pricing().routed_vendor(model)
    if vendor:
        return vendor_eq(vendor, model, fresh, cache_read, cache_5m + cache_1h, out)
    usd = pricing().input_cost_usd(model, day, fresh=fresh, cache_read=cache_read, cache_5m=cache_5m,
                                   cache_1h=cache_1h, fast=fast) + pricing().output_cost_usd(model, day, out, fast)
    family = model.split("-")[1] if model.startswith("claude-") else "?"
    return collections.Counter({family: usd / opus_usd()}) if usd else collections.Counter()


def vendor_eq(vendor, model, fresh=0, cache_read=0, cache_write=0, out=0):
    _, cost_in, cost_out = pricing().vendor_costs(vendor, model, fresh=fresh, cache_read=cache_read,
                                                  cache_write=cache_write, output=out)
    return collections.Counter({vendor: (cost_in + cost_out) / opus_usd()}) if cost_in + cost_out else collections.Counter()


def epoch(stamp):
    return dt.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()


def rows(path):
    try:
        with open(path, errors="ignore") as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
                    yield row
    except OSError:
        return


def read(path):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def claude_paths(whole):
    return [whole] + sorted(glob.glob(whole[:-len(".jsonl")] + "/subagents/*.jsonl"))


def claude_usage(path, seen, window=None):
    total = collections.Counter()
    for transcript in claude_paths(os.path.realpath(path)):
        for row in rows(transcript):
            message = row.get("message") or {}
            usage = message.get("usage")
            if row.get("type") != "assistant" or not isinstance(usage, dict) or message.get("id") in seen:
                continue
            if window and not window[0] <= epoch(row.get("timestamp", "1970-01-01T00:00:00Z")[:19] + "Z") <= window[1]:
                continue
            seen.add(message.get("id"))
            written = usage.get("cache_creation_input_tokens") or 0
            hour = min((usage.get("cache_creation") or {}).get("ephemeral_1h_input_tokens") or 0, written)
            total += claude_eq(message.get("model"), row.get("timestamp", "")[:10], usage.get("input_tokens") or 0,
                               usage.get("cache_read_input_tokens") or 0, written - hour, hour,
                               usage.get("output_tokens") or 0, usage.get("speed") == "fast")
    return total


def codex_usage(path, model):
    last = {}
    for row in rows(path):
        payload = row.get("payload") or {}
        if payload.get("type") == "token_count":
            last = (payload.get("info") or {}).get("total_token_usage") or last
    cached = last.get("cached_input_tokens", 0)
    return vendor_eq("codex", model, max(last.get("input_tokens", 0) - cached, 0), cached,
                     last.get("cache_write_input_tokens", 0), last.get("output_tokens", 0))


def gemini_usage(path, model):
    fresh = cache_read = out = 0
    for row in rows(path):
        if "output_tokens" in row:
            cached = row.get("cache_read_tokens") or 0
            fresh += max((row.get("input_tokens") or 0) - cached, 0)
            cache_read += cached
            out += row.get("output_tokens") or 0
    return vendor_eq("gemini", model, fresh, cache_read, 0, out)


def grok_usage(path, model):
    try:
        with open(os.path.join(os.path.dirname(path), "usage.json")) as handle:
            session = json.load(handle).get("session") or {}
    except (OSError, ValueError):
        return None
    cached = session.get("cachedReadTokens", 0)
    return vendor_eq("grok", model, max(session.get("inputTokens", 0) - cached, 0), cached,
                     session.get("cacheCreationTokens", 0), session.get("outputTokens", 0))


def transcripts(worker_run, runs):
    """run -> the path `worker-run transcript <run>` prints, "" where it finds none; one process for all."""
    if not runs:
        return {}
    found = subprocess.run([worker_run, "transcript", *runs], capture_output=True, text=True)
    if len(runs) == 1:
        return {runs[0]: found.stdout.strip() if found.returncode == 0 else ""}
    lines = found.stdout.split("\n")
    return {run: lines[index].strip() if index < len(lines) else "" for index, run in enumerate(runs)}


def claude_files(whole):
    """(path, size, mtime) of a Claude transcript and its subagents, the files claude_usage reads."""
    stamps = []
    for path in claude_paths(whole):
        try:
            stat = os.stat(path)
        except OSError:
            continue
        stamps.append((path, stat.st_size, stat.st_mtime_ns))
    return ("claude-files", tuple(stamps))


def run_usage(worker_run, run, vendor, seen, found=None):
    transcript = read(f"{RUNS}/{run}/session-file")
    if not os.path.isfile(transcript):
        transcript = (found if found is not None and run in found else transcripts(worker_run, [run]))[run]
    if not os.path.isfile(transcript):
        return None
    # A RESUME shares its session's transcript, and these vendors' counts are the whole session's.
    whole = os.path.realpath(transcript)
    if vendor != "claudeb" and whole in seen:
        return collections.Counter()
    # Read unchanged, every message id in it is already in `seen`: a re-read adds nothing.
    files = claude_files(whole) if vendor == "claudeb" else None
    if files is not None and files in seen:
        return collections.Counter()
    try:
        with open(f"{RUNS}/{run}/meta.json") as handle:
            meta = json.load(handle)
    except (OSError, ValueError):
        meta = {}
    model = meta.get("served_model") or meta.get("model")
    usage = {"claudeb": lambda: claude_usage(transcript, seen), "codex": lambda: codex_usage(transcript, model),
             "gemini": lambda: gemini_usage(transcript, model), "grok": lambda: grok_usage(transcript, model)}.get(
        vendor, lambda: None)()
    if usage is not None:
        seen.add(whole)
        if files is not None:
            seen.add(files)
    return usage


def bench_usage(bench):
    by_id = {}
    for path in glob.glob(f"{bench}/claude-usage-*.jsonl"):
        for row in rows(path):
            by_id[row.get("id")] = row
    name = os.path.basename(bench)
    day = f"{name[:4]}-{name[4:6]}-{name[6:8]}"
    total = collections.Counter()
    for row in by_id.values():
        total += claude_eq(row.get("model"), (row.get("ts") or day)[:10], row.get("input", 0), row.get("cache_read", 0),
                           row.get("cache_5m", 0), row.get("cache_1h", 0), row.get("output", 0))
    batches = glob.glob(f"{bench}/usage-judge~*.jsonl")
    for path in batches or glob.glob(f"{bench}/usage-judge.jsonl"):
        label = os.path.basename(path)[len("usage-"):]
        if not os.path.exists(f"{bench}/claude-usage-{label}"):
            for row in rows(path):
                split = "prompt_tokens" in row
                total += claude_eq(row.get("model"), day, row.get("prompt_tokens" if split else "total_tokens", 0),
                                   out=row.get("output_tokens", 0) if split else 0)
    return total


def weighted(total):
    return sum(total.values())


def window(night):
    low = epoch(night["started_at"])
    high = epoch(night["finished_at"]) if night.get("finished_at") else time.time()
    sessions = {night.get("session")} | set(night.get("previous_sessions") or [])
    sessions.discard(None)
    return low, high, sessions


def night_runs(low, high, sessions):
    """(run, directory, meta, vendor) of each worker run the night's sessions launched in its window."""
    for directory in sorted(glob.glob(f"{RUNS}/*-*")):
        run = os.path.basename(directory)
        parts = run.split("-")
        if not (parts[1].isdigit() and low <= int(parts[1]) <= high) or read(f"{directory}/launcher") not in sessions:
            continue
        try:
            with open(f"{directory}/meta.json") as handle:
                meta = json.load(handle)
        except (OSError, ValueError):
            meta = {}
        yield run, directory, meta, meta.get("vendor") or parts[0]


def night_benches(low, high, sessions):
    """Each review round started in the window by one of the night's sessions, or by no recorded owner."""
    for bench in sorted(glob.glob(f"{BENCHES}/*")):
        try:
            started = dt.datetime.strptime(os.path.basename(bench)[:16], "%Y%m%dT%H%M%SZ").replace(
                tzinfo=dt.timezone.utc).timestamp()
        except ValueError:
            continue
        if not low <= started <= high:
            continue
        try:
            with open(f"{bench}/meta.json") as handle:
                owner = json.load(handle).get("session")
        except (OSError, ValueError):
            owner = None
        if owner is not None and owner not in sessions:
            continue
        yield bench


def spend(night, worker_run):
    low, high, sessions = window(night)
    kinds = {"fixers": collections.Counter(), "reviews": collections.Counter(),
             "orchestrator": collections.Counter()}
    models, hours, blind, seen = collections.Counter(), 0.0, 0, set()
    listed = list(night_runs(low, high, sessions))
    found = transcripts(worker_run, [run for run, *_ in listed
                                     if not os.path.isfile(read(f"{RUNS}/{run}/session-file"))])
    for run, _, meta, vendor in listed:
        models[f"{vendor}/{meta.get('served_model') or meta.get('model') or '?'}"] += 1
        start = meta.get("pid_started_at") or meta.get("started_at")
        if start and meta.get("ended_at"):
            hours += max(meta["ended_at"] - start, 0) / 3600
        usage = run_usage(worker_run, run, vendor, seen, found)
        if usage is None:
            blind += 1
        else:
            kinds["fixers"] += usage
    rounds = 0
    for bench in night_benches(low, high, sessions):
        rounds += 1
        kinds["reviews"] += bench_usage(bench)
    for session in sessions:
        path = chat_names.transcript_path(session)
        if path:
            kinds["orchestrator"] += claude_usage(str(path), seen, (low, high))
    return {"low": low, "high": high, "running": not night.get("finished_at"), "models": models,
            "hours": hours, "blind": blind, "rounds": rounds, "kinds": kinds,
            "total": sum(weighted(total) for total in kinds.values())}


def previous(path, night):
    older = []
    for other in glob.glob(os.path.join(os.path.dirname(path), "*.json")):
        try:
            with open(other) as handle:
                candidate = json.load(handle)
        except (OSError, ValueError):
            continue
        if candidate.get("finished_at") and (candidate.get("started_at", ""), candidate.get("id", "")) < (
                night["started_at"], night["id"]):
            older.append(candidate)
    return max(older, key=lambda n: (n["started_at"], n["id"])) if older else None


def mega(value):
    return f"{value / 1e6:.1f}M"


def by_model(total):
    shown = sorted(((value, label) for label, value in total.items() if round(value / 1e6, 1)), reverse=True)
    return " (" + " · ".join(f"{label} {mega(value)}" for value, label in shown) + ")" if shown else ""


def main():
    worker_run, path = sys.argv[1:3]
    pricing()
    with open(path) as handle:
        night = json.load(handle)
    now = spend(night, worker_run)
    clock = lambda t: time.strftime("%d %b %H:%M", time.localtime(t))
    print(f"duration · {clock(now['low'])} – {'not finished' if now['running'] else clock(now['high'])} · "
          f"{(now['high'] - now['low']) / 3600:.1f} h")
    states = collections.defaultdict(collections.Counter)
    for job in night.get("jobs", []):
        state = job.get("state") if job.get("state") in ("merged", "left") else "other"
        states[state][job.get("kind", "?")] += 1
    print("jobs · " + " · ".join(
        f"{'landed' if state == 'merged' else state} {sum(states[state].values())}"
        + (" (" + ", ".join(f"{kind} {n}" for kind, n in sorted(states[state].items())) + ")" if states[state] else "")
        for state in ("merged", "left", "other")))
    print(f"agents · {sum(now['models'].values())} worker runs"
          + (" (" + ", ".join(f"{n} {model}" for model, n in sorted(now["models"].items())) + ")" if now["models"] else "")
          + f" · {now['hours']:.1f} h wall-clock" + (f" · {now['blind']} without a transcript" if now["blind"] else ""))
    print(f"review rounds · {now['rounds']}")
    for kind, total in now["kinds"].items():
        print(f"spend {kind} · {mega(weighted(total))} {UNIT}{by_model(total)}")
    before = previous(path, night)
    ratio = ""
    if before:
        was = spend(before, worker_run)["total"]
        ratio = f" · {now['total'] / was:.2f}× night {before['id']} ({mega(was)})" if was else ""
    print(f"spend total · {mega(now['total'])} {UNIT}{ratio}")


if __name__ == "__main__":
    main()
