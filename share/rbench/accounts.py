import contextlib
import fcntl
import json
import os
import re
import math
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import store as _store
from . import catalog as _catalog
from . import raters as _raters

# Matched exactly by run_rater_task, which is what turns this into another lap of the pool
# loop: the account walled while this cell queued, so the cell rotates instead of dying.
GATE_WALL_STDERR = "the OpenCode plan walled off while this cell waited for a gate slot"
# A usage wall is that account's own billing window, not weather: the honest response is to retire
# it for the rest of the run rather than send one doomed request per remaining cell, which is how
# a wall gets deeper instead of waited out.
WALL_STATE_FILE = "walls.jsonl"
OPENCODE_SEEN_DIR = "opencode-seen"
WALL_RECORD_FIELDS = ("side", "account", "bucket", "detected_at", "reset_at", "window")
WALL_LOCK_FILE = ".walls.lock"
WALL_COMPACT_BYTES = 4096
# A provider that names its own reset horizon is believed over the flat TTL, but only so far:
# a garbled far-future date would retire an account until someone notices by hand. A named
# window sets its own ceiling, since the flat cap turns a monthly reset into a date that has
# already passed by the time the wall really lifts.
WALL_MAX_TTL_S = 7 * 24 * 3600
WALL_WINDOW_MAX_TTL_S = {
    "5-hour": 6 * 3600,
    "weekly": 8 * 24 * 3600,
    "monthly": 32 * 24 * 3600,
}
WALL_LABEL_WEEKDAY_MAX_S = 6 * 24 * 3600


@contextlib.contextmanager
def wall_file_lock(path, lock_name=WALL_LOCK_FILE):
    """Serialise a state file's readers and writers, across processes as well as threads.

    Yields whether the lock was actually taken, because the callers want opposite things from a
    failure: a wall append must still happen (losing a wall is worse than racing one), while a
    compaction that rewrites the file unlocked is the very race it exists to prevent, and skips
    instead.
    """
    lock_path = path.with_name(lock_name)
    handle = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        handle = open(lock_path, "w")
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    except OSError:
        if handle is not None:
            handle.close()
            handle = None
    try:
        yield handle is not None
    finally:
        if handle is not None:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            handle.close()


def wall_bucket(rater):
    """Claude bills fable against its own quota and Gemini bills per model, so a wall on one
    must not retire the account for the cells that still have theirs."""
    if rater["side"] == "agy":
        return rater["model"]
    return "fable" if rater["model"] == "fable" else "general"


def wall_record(**values):
    """One walls.jsonl row, built from the field list the menubar reader is pinned against.

    Optional fields are left out rather than written null, so the schema WALL_RECORD_FIELDS
    names is the only shape either reader has to know.
    """
    return {
        field: values.get(field) for field in WALL_RECORD_FIELDS
        if values.get(field) is not None
    }


def mark_walled(side, account, bucket="general", reset_at=None, window=None):
    detected_at = time.time()
    path = _store.state_dir() / WALL_STATE_FILE
    entry = wall_record(
        side=side, account=account, bucket=bucket, detected_at=detected_at,
        reset_at=clamped_reset_at(detected_at, reset_at, window)
        if reset_at is not None else None,
        window=window,
    )
    try:
        payload = (json.dumps(entry, separators=(",", ":")) + "\n").encode()
        with wall_file_lock(path):  # an unlocked append still beats a lost wall
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                os.write(fd, payload)
            finally:
                os.close(fd)
    except (OSError, TypeError, ValueError) as exc:
        # The file is the only record, so this wall is lost and its account will be tried
        # again. Saying so beats a silent retry loop nobody can explain afterwards.
        print(f"review-bench: could not record the {side} wall on {account}: {exc}",
              file=sys.stderr)


def wall_ttl_s():
    try:
        ttl = float(os.environ.get("REVIEW_BENCH_WALL_TTL_S", "3600"))
    except (TypeError, ValueError):
        return 3600
    return max(0, ttl) if math.isfinite(ttl) else 3600


def clamped_reset_at(detected_at, reset_at, window=None):
    try:
        reset_at = float(reset_at)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(reset_at):
        return None
    return min(reset_at, detected_at + WALL_WINDOW_MAX_TTL_S.get(window, WALL_MAX_TTL_S))


def recorded_reset_at(reset_at):
    """A stored horizon as it was written down.

    The ceiling belongs to the writer alone: a reader applying it again would shorten a wall
    recorded under a window ceiling this row no longer carries, back into a date the wall
    outlives.
    """
    try:
        reset_at = float(reset_at)
    except (TypeError, ValueError):
        return None
    return reset_at if math.isfinite(reset_at) else None


def wall_expiry(detected_at, reset_at, ttl=None):
    """When this wall stops standing.

    The flat TTL is a guess about a window nobody reported. Applying it to a wall whose
    reset the provider stated re-probes a weekly limit hourly, and every probe is a cell
    that dies for nothing.
    """
    if reset_at is not None:
        return reset_at
    return detected_at + (wall_ttl_s() if ttl is None else ttl)


def wall_still_standing(detected_at, reset_at, now=None, ttl=None):
    return (time.time() if now is None else now) <= wall_expiry(detected_at, reset_at, ttl)


def compact_walls(path):
    """Rewrite the file with only the walls that still stand.

    The rows are re-read here rather than taken from the caller: between that read and
    this rename another process may have appended a wall, and replacing the file with a
    stale snapshot is how a live wall silently disappears.
    """
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    compacted = None
    try:
        with wall_file_lock(path) as locked:
            # Rewriting the file unlocked is exactly the race this lock exists to prevent,
            # so an unavailable lock means leaving the rows alone, not compacting anyway.
            if not locked:
                return None
            # An append whose own lock attempt failed goes ahead unlocked, because losing a wall
            # is worse than racing one. Such a row can land while the rows below are being read,
            # and replacing the file would drop it: the account would walk back into the pool
            # with its plan spent. Measured before the read so the check spans it, and deferring
            # to the writer costs nothing, since compaction is only housekeeping.
            try:
                size_before = path.stat().st_size
            except OSError:
                return None
            walls = read_wall_rows(path)
            if walls is None:
                return None
            # OpenCode rows are never retired by the clock: llm-limits.sh reads them against the
            # account's served stamp, and a lapsed day-granular reset retires nothing — dropping
            # one here would show a still-refusing plan as open on every surface. Compaction only
            # collapses superseded duplicates: one row per account and window, carrying the
            # newest detection and the longest horizon, so neither reader loses its answer.
            opencode = {}
            served = {}
            try:
                with path.open(encoding="utf-8", errors="replace") as stream:
                    raw_rows = stream.readlines()
            except OSError:
                return None
            for raw in raw_rows:
                try:
                    row = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(row, dict) or row.get("side") != "opencode":
                    continue
                account, bucket = row.get("account"), row.get("bucket")
                detected_at = row.get("detected_at")
                if not isinstance(account, str) or not isinstance(bucket, str):
                    continue
                if not isinstance(detected_at, (int, float)) or not math.isfinite(detected_at):
                    continue
                window = row.get("window")
                if not isinstance(window, str) or not window:
                    window = None
                reset_at = recorded_reset_at(row.get("reset_at"))
                if account not in served:
                    served[account] = opencode_served_at(path, account)
                stamp = served[account]
                # The served stamp splits the rows into two records that must never merge: a
                # refusal the plan has already served past would otherwise lend its far horizon
                # to a detection recorded after that completion, and the wall both readers
                # retired stands again on every surface. Each side keeps its own row, since
                # retiring one is the reader's question and compaction drops no account.
                retired = stamp is not None and detected_at < stamp
                kept = opencode.get((account, bucket, window, retired))
                if kept is not None:
                    detected_at = max(kept[0], detected_at)
                    reset_at = max(
                        (value for value in (kept[1], reset_at) if value is not None),
                        default=None,
                    )
                opencode[(account, bucket, window, retired)] = (detected_at, reset_at)
            with tmp.open("w", encoding="utf-8") as stream:
                for (side, account, bucket), wall in sorted(walls.items()):
                    if side == "opencode":
                        continue
                    detected_at, reset_at = wall[:2]
                    row = wall_record(
                        side=side, account=account, bucket=bucket, detected_at=detected_at,
                        reset_at=reset_at, window=wall[2] if len(wall) > 2 else None,
                    )
                    stream.write(json.dumps(row, separators=(",", ":")) + "\n")
                for (account, bucket, window, _retired), (detected_at, reset_at) in sorted(
                    opencode.items(),
                    key=lambda item: (item[0][0], item[0][1], item[0][2] or "", item[0][3]),
                ):
                    row = wall_record(
                        side="opencode", account=account, bucket=bucket,
                        detected_at=detected_at, reset_at=reset_at, window=window,
                    )
                    stream.write(json.dumps(row, separators=(",", ":")) + "\n")
            os.chmod(tmp, 0o600)
            try:
                if path.stat().st_size != size_before:
                    return None
            except OSError:
                return None
            os.replace(tmp, path)
            tmp = None
            compacted = walls
    except OSError:
        pass
    finally:
        if tmp is not None:
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass
    return compacted


def opencode_served_at(path, account):
    """When the plan last SERVED this account, from the stamp beside the wall record.

    Digits only, exactly as llm-limits.sh reads the same file (`tr -dc '0-9'`): a stamp that is
    missing, unreadable or garbled is no evidence of a completion, and only evidence retires a
    wall. The account name comes out of a file every process appends to, so it must not be able
    to steer this read out of the stamp directory.
    """
    if not account or "/" in account or account.startswith("."):
        return None
    try:
        raw = (path.parent / OPENCODE_SEEN_DIR / account).read_text(
            encoding="utf-8", errors="replace"
        )
    except OSError:
        return None
    digits = "".join(char for char in raw if char in "0123456789")
    return float(digits) if digits else None


def read_wall_rows(path):
    """Standing walls as {key: (detected_at, reset_at, window)}, or None when unreadable.

    None and {} have to stay distinguishable: an empty file means every account is clear,
    while an unreadable one is no evidence at all and must not clear anything.
    """
    walls = {}
    try:
        with path.open(encoding="utf-8", errors="replace") as stream:
            rows = stream.readlines()
    except FileNotFoundError:
        return {}
    except (OSError, UnicodeError):
        return None
    for raw in rows:
        try:
            row = json.loads(raw)
            side = row["side"]
            account = row["account"]
            bucket = row["bucket"]
            detected_at = float(row["detected_at"])
            if not all(isinstance(value, str) for value in (side, account, bucket)):
                raise ValueError("invalid wall key")
            if not math.isfinite(detected_at):
                raise ValueError("invalid wall timestamp")
        except (ValueError, KeyError, TypeError):
            continue
        window = row.get("window")
        if not isinstance(window, str) or not window:
            window = None
        reset_at = recorded_reset_at(row.get("reset_at"))
        walls.setdefault((side, account, bucket), []).append((detected_at, reset_at, window))
    standing = {}
    served = {}
    for key, rows in walls.items():
        side, account, _bucket = key
        if side == "opencode":
            # llm-limits.sh answers this from the same two files, and the two readers disagreeing
            # is a whole leg refused for a day on an account the menubar shows clean. A completion
            # served AFTER a refusal retires it; a tie keeps the wall, since only a standing wall
            # is ever probed again. The rows go first, before the windows are aggregated, or a
            # stale long-horizon row outranks the 429 recorded after that completion.
            if account not in served:
                served[account] = opencode_served_at(path, account)
            stamp = served[account]
            if stamp is not None:
                rows = [row for row in rows if row[0] >= stamp]
        wall = standing_wall(rows)
        if wall is not None:
            standing[key] = wall
    return standing


def standing_wall(rows):
    """The row that still describes this account's window, or None when it is open again.

    A horizon the provider stated supersedes every guess made before it reopens, in both
    directions: a plain wall recorded an hour after a weekly one must not shorten it to the
    flat hour, and the flat hour must not sit on top of a reset the provider put a minute
    away. Once that horizon passes the account is open, and only what was recorded after it
    can close it again — an older flat guess outliving a reset the provider already gave is
    how a healthy account keeps being skipped.
    """
    dated = [row for row in rows if row[1] is not None]
    # The longest of the stated horizons, not the most recently recorded one: two cells can hit
    # the same account seconds apart and be told different things, and a weekly limit does not
    # stop being spent because a shorter refusal was written down after it.
    longest_dated = max(dated, key=lambda row: wall_expiry(row[0], row[1])) if dated else None
    if longest_dated is not None:
        if wall_still_standing(longest_dated[0], longest_dated[1]):
            return longest_dated
        rows = [row for row in rows if row[0] > wall_expiry(
            longest_dated[0], longest_dated[1]
        )]
    standing = [row for row in rows if wall_still_standing(row[0], row[1])]
    return max(standing, key=lambda row: wall_expiry(row[0], row[1])) if standing else None


def persisted_walls(path):
    walls = read_wall_rows(path)
    if walls is None:
        # This cache is advisory; any persistence failure must leave accounts usable.
        return None
    try:
        stat = path.stat()
        oversized = stat.st_size > WALL_COMPACT_BYTES
    except OSError:
        oversized = False
    if oversized:
        # Rows are one line each, so a file this size holding few standing walls is mostly
        # expired rows.
        try:
            with path.open(encoding="utf-8", errors="replace") as stream:
                entries = sum(1 for line in stream if line.strip())
        except (OSError, UnicodeError):
            entries = 0
        if entries - len(walls) > entries / 2:
            # Compaction re-reads under its lock, so its result is the fresher snapshot:
            # it can hold a wall appended after the read above.
            compacted = compact_walls(path)
            if compacted is not None:
                walls = compacted
    return walls


def walled_accounts(side, bucket="general"):
    """The side's retired accounts for this bucket, in one read of the record.

    Callers filtering a whole roster ask here rather than per account: the file is read on every
    question by design, and asking it once per candidate turns one answer into as many reads.
    """
    walls = persisted_walls(_store.state_dir() / WALL_STATE_FILE) or {}
    return {
        row_account for row_side, row_account, row_bucket in walls
        if row_side == side and row_bucket == bucket
    }


def is_walled(side, account, bucket="general"):
    """Whether this account's window is still shut, answered from the file every time.

    Other processes append to that file, so any copy in memory has to be revalidated against
    it on every call anyway; at a handful of rows and tens of calls per run the read costs
    nothing, while keeping the two in step cost eight of the twenty-one defects found in this
    code. An unreadable file leaves accounts usable: the record is advisory, and refusing to
    run on a failed read would empty the pool over a transient error.
    """
    walls = persisted_walls(_store.state_dir() / WALL_STATE_FILE)
    return (side, account, bucket) in (walls or {})


def opencode_usage_wall(stderr):
    """A spent subscription, told apart from the status code both of its causes share.

    Retiring an account needs the gateway to have said the plan is out; a bare 429 is equally
    the provider throttling the model behind it, and treating that as the account's own window
    is what empties the pool of accounts with their whole quota intact. The unnamed case is
    retried as transient instead, which costs one lap and cannot lose an account.
    """
    return bool(OPENCODE_PLAN_WALL_RE.search(stderr or ""))


# The gateway answers 429 for two unrelated things: the subscription's own window is spent
# (days away from resetting), and the provider behind it is throttling a burst (seconds).
# Retiring an account for the second is how a healthy account disappears mid-run.
OPENCODE_PLAN_WALL_RE = re.compile(
    r"GoUsageLimitError|\blimitName\b|usage limit|out of credits|insufficient balance",
    re.IGNORECASE,
)
OPENCODE_LIMIT_NAME_RE = re.compile(
    r'''["']?limitName["']?\s*[:=]\s*["']?([A-Za-z0-9_.-]+)''', re.IGNORECASE
)
OPENCODE_TRANSIENT_RE = re.compile(
    r"provider rate limit|rate limit exceeded|too many requests"
    r"|\b(?:429|500|502|503|529)\b|overloaded|at capacity|temporarily unavailable",
    re.IGNORECASE,
)
CODEX_TRANSIENT_RE = re.compile(
    r"at capacity|temporarily unavailable|\b(?:429|500|502|503|529)\b|overloaded"
    r"|rate[ _-]limit|too many requests"
    r"|stream (?:disconnected|closed) before completion",
    re.IGNORECASE,
)
# Spelled alike in bin/opencode-go's stated_in (shared-invariants row ai). The gateway states most
# resets abbreviated and compounded — "Resets in 9hr 30min" — so the components are summed rather
# than read down to the first, and the unit alternation ends on a word boundary so that "3 mins"
# and "3 minutes" are each consumed whole.
WALL_RESET_UNIT = r"(second|sec|minute|min|hour|hr|day|week)s?\b"
WALL_RESET_RE = re.compile(
    r"resets? in\s+((?:[0-9]+(?:\.[0-9]+)?\s*" + WALL_RESET_UNIT + r"[\s,]*)+)", re.IGNORECASE
)
WALL_RESET_COMPONENT_RE = re.compile(
    r"([0-9]+(?:\.[0-9]+)?)\s*" + WALL_RESET_UNIT, re.IGNORECASE
)
WALL_RESET_UNITS = {
    "second": 1, "sec": 1, "minute": 60, "min": 60,
    "hour": 3600, "hr": 3600, "day": 86400, "week": 604800,
}


# Matched exactly by opencode_transient_failure, which is what makes another lap reachable:
# a run that stopped before reviewing is the model's hiccup, not an answer to record.
OPENCODE_STUB_STDERR = "opencode stopped before reviewing"
# Recorded stubs run 51 to 192 characters; the shortest recorded real non-review is over 2000.
OPENCODE_STUB_MAX_CHARS = 400


OPENCODE_BURST_RE = re.compile(
    r"provider_rate_limit_exceeded|rate_limit_error|provider rate limit"
    r"|rate limit exceeded|too many requests",
    re.IGNORECASE,
)


def opencode_burst_throttle(stderr):
    """Being refused for asking too fast, as opposed to a spent subscription.

    Matched on the wording as well as the machine-readable code, because the gateway sends
    both shapes: keying only on the code leaves the plain-text throttle to be retried and
    then mistaken for the account's own window. The bench is usually the burst itself, so
    this can outlast any retry budget, and retiring the account for it would empty the pool
    of accounts that still have their whole quota.
    """
    text = stderr or ""
    if OPENCODE_PLAN_WALL_RE.search(text):
        return False
    return bool(OPENCODE_BURST_RE.search(text))


def opencode_transient_failure(stderr):
    text = stderr or ""
    if OPENCODE_PLAN_WALL_RE.search(text):
        return False
    if OPENCODE_STUB_STDERR in text:
        return True
    return bool(OPENCODE_TRANSIENT_RE.search(text))


# What opencode-go prints once its own retries are spent on a provider that is down: the final
# status line, the gateway's routing error, or a stream that carried an error instead of an
# answer.
OPENCODE_PROVIDER_OUTAGE_RE = re.compile(
    r"Router\.Unavailable|failover_exhausted|inference_recovery_timeout"
    r"|provider error inside stream|stream response carried no SSE data chunks"
    r"|HTTP (?:5[0-9][0-9]|000)\b",
    re.IGNORECASE,
)


def opencode_provider_unavailable(stderr):
    """The provider behind one model is down, as opposed to the account being spent.

    Not the same reading as opencode_transient_failure: that one decides whether to try the
    identical request again, this one decides whether to ask a different model. A 429 is
    excluded on purpose — opencode_burst_throttle already owns it.
    """
    text = stderr or ""
    if OPENCODE_PLAN_WALL_RE.search(text):
        return False
    return bool(OPENCODE_PROVIDER_OUTAGE_RE.search(text))


def codex_transient_failure(events, stderr):
    # The error events, not the whole stream: it also carries the review, and a cell reviewing
    # this file would classify itself off the status codes its own answer discusses.
    text = f"{stderr or ''}\n{codex_failure_reason(events)}"
    if codex_usage_wall(events, stderr):
        return False
    return bool(CODEX_TRANSIENT_RE.search(text))


def wall_reset_source(side, stderr, wall_text):
    """The text a reset horizon may be read out of: what the gateway said, never the review.

    wall_text is the rater's own answer, and a model reviewing code about reset windows writes
    "resets in N days" in prose that would become this account's horizon and retire a healthy
    account for up to a week. Codex states its wall in the event stream, but that stream is its
    whole stdout and carries the review too — the file this run recorded holds the model's text
    and the string 429 alike — so the gateway's channel there is the error events alone.
    """
    return f"{stderr or ''}\n{codex_failure_reason(wall_text) if side == 'codex' else ''}"


def wall_reset_at(text):
    """Epoch the provider says the window reopens, or None when it did not say."""
    match = WALL_RESET_RE.search(text or "")
    if not match:
        return None
    return time.time() + sum(
        float(value) * WALL_RESET_UNITS[unit.lower()]
        for value, unit in WALL_RESET_COMPONENT_RE.findall(match.group(1))
    )


def opencode_wall_window(text):
    match = OPENCODE_LIMIT_NAME_RE.search(text or "")
    if not match:
        return None
    normalized = re.sub(r"[^a-z0-9]", "", match.group(1).lower())
    if "weekly" in normalized or normalized == "week":
        return "weekly"
    if "monthly" in normalized or normalized == "month":
        return "monthly"
    if normalized in ("5h", "5hour", "fivehour"):
        return "5-hour"
    return None


def opencode_profiles():
    # The same override llm-limits.sh and bin/opencode-go read: a roster only two of the three
    # honour is a pool running cells on accounts the surfaces neither render nor probe.
    override = os.environ.get("OPENCODE_GO_PROFILES")
    path = Path(override) if override else (
        Path(os.environ.get("HOME") or Path.home()) / ".config/opencode-go/profiles"
    )
    if not path.exists():
        return ["-"]
    return [
        line for raw in path.read_text().splitlines()
        if (line := raw.strip()) and not line.startswith("#")
    ]


def opencode_account(profile):
    return "opencode-go" if profile == "-" else f"opencode-go-{profile}"


LIMITS_STALE_AGE_S = 600
def validate_review_tiers():
    for tier_name, tier in _catalog.REVIEW_TIERS.items():
        for composition in ("cells", "cells_max"):
            if composition not in tier:
                raise RuntimeError(f"{tier_name} is missing {composition}")
            for cell in tier[composition]:
                try:
                    raters = _raters.parse_raters(cell)
                except ValueError as exc:
                    raise RuntimeError(
                        f"{tier_name} {composition} contains invalid rater {cell!r}"
                    ) from exc
                for rater in raters:
                    reason = (
                        _catalog.EXCLUDED_CELLS.get(_raters.normalize_legacy_rater(rater["spec"]))
                        or measured_worthless(rater)
                        or measured_skill_only(rater)
                    )
                    if reason:
                        raise RuntimeError(
                            f"{tier_name} {composition} contains retired rater {cell!r}: {reason}"
                        )


def opencode_pool_free():
    """Whether the OpenCode pool still has an account to run on, walls and exclusions applied."""
    return pool_account("opencode", ()) is not None


def affordability():
    """Which sides the pool will staff right now, and the Claude account it named.

    One machine query per vendor rather than a read of the human table: the pool toggle, the
    wall and the session reserve are all worker-pick's to decide (docs/routing-contract.md),
    and any threshold kept here would be a second copy of a policy the bench does not own.
    """
    picked = {side: worker_pick_answer(side, ())[0] for side in SIDE_POOL_VENDOR}
    return {
        "codex": picked["codex"] is not None,
        "claude": picked["claude"] is not None,
        "agy": picked["agy"] is not None,
        # No vendor routes OpenCode, so its own roster answers for it: a bare True here launched
        # every OpenCode cell of every panel into a pool with nothing left to run on, for three
        # days of cells that died on `no_account_left` (Egor, 2026-08-04..10).
        "opencode": opencode_pool_free(),
        # Fable bills a bucket of its own, and the contract keeps its exhaustion from touching
        # ordinary work: one answer cannot stand for both, so the fable bucket is asked for
        # separately and only cells that spend it are gated on it.
        "claude_fable": worker_pick_answer("claude", (), fable=True)[0] is not None,
        "claude_account": picked["claude"],
    }


# A spent plan says when it is back: SIDE_WALL recognises the wording and mark_walled records the
# reset, hours or days away. A gateway that is merely DOWN says nothing of the sort — it answers
# with a server error, and every panel since has paid for the same cell twice more before recording
# it as errored. Only that case is a wait this tool has to invent, and it EXPIRES on its own: a cell
# held out until proof it recovered would never be asked for that proof, and a measured failure rate
# is a number with no clock in it (Egor, 2026-08-08).
GATEWAY_SIDES = ("opencode",)
GATEWAY_COOLDOWN_MIN = 45
GATEWAY_COOLDOWN_LOCK = ".gateway-cooldown.lock"


def gateway_cooldown_path():
    return _store.state_dir() / "gateway-cooldown.json"


def read_gateway_cooldowns(now=None):
    """Which cell families are cooling at `now`: family -> (until, reason). An entry whose moment
    has passed is simply not cooling — the expiry IS the retry schedule, so nothing sweeps this.
    """
    now = now or _store.utc_now()
    try:
        document = json.loads(gateway_cooldown_path().read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(document, dict):
        return {}
    cooling = {}
    for family, entry in document.items():
        until = _store.parse_iso_timestamp(entry.get("until")) if isinstance(entry, dict) else None
        if until and until > now:
            cooling[family] = (until, str(entry.get("reason") or "a failed run"))
    return cooling


def no_account_left_head(side):
    """The part of the refusal that says nothing about the walls behind it.

    Read back by gateway_outage against stderr captured earlier in the run: the labels below
    are live, so a wall recorded or lapsed by another cell in between would make the full text
    stop matching and classify a dry pool as a gateway outage — the 45-minute canary a spent
    plan must never reach.
    """
    return f"the pool has no {side} account left"


def no_account_left(side, note=""):
    # The note goes on the head line: appended after the labels it would glue itself to the
    # last one, and a reader counts one wall as two.
    message = f"{no_account_left_head(side)} to run on{note}"
    if side == "opencode":
        labels = active_wall_labels(side)
        if labels:
            message += "\n" + "\n".join(labels)
    return message


def wall_account_name(side, account):
    if side != "opencode":
        return account
    if account == "opencode-go":
        return "default"
    return account.removeprefix("opencode-go-")


def standing_side_walls(side):
    """This side's standing walls as (account name, window, reset), one record per account."""
    walls = persisted_walls(_store.state_dir() / WALL_STATE_FILE) or {}
    return [
        (wall_account_name(side, account), wall[2] if len(wall) > 2 else None, wall[1])
        for (row_side, account, _bucket), wall in sorted(walls.items())
        if row_side == side
    ]


def active_wall_labels(side):
    labels = []
    for name, window, reset_at in standing_side_walls(side):
        kind = f"{window} wall" if window else "plan wall"
        reset = ""
        if reset_at is not None:
            # A weekday name is a date only inside the week it names: a monthly wall three weeks
            # out reads as "Tue 09:00", i.e. tomorrow, to the reader deciding whether to wait.
            near = reset_at - time.time() < WALL_LABEL_WEEKDAY_MAX_S
            moment = datetime.fromtimestamp(reset_at)
            reset = f", resets {moment.strftime('%a %H:%M' if near else '%b %-d')}"
        labels.append(f"{side} {name}: {kind}{reset}")
    return labels


def gateway_outage(side, rc, stderr):
    """Whether a failed gateway attempt is the gateway being down, as opposed to the plan being
    spent. A spent plan is already recorded with its own reset horizon, days away for OpenCode, and
    a canary fired into it every 45 minutes is exactly the retry DIAGNOSTICS forbids — while a
    45-minute expiry would then report the side as recovered with the window still spent.
    """
    text = stderr or ""
    if SIDE_WALL[side](rc, "", text):
        return False
    return no_account_left_head(side) not in text


def note_gateway_outcome(raters, errored, outages, now=None):
    """What this run learned about the gateway: a family whose every attempt failed on the gateway
    itself starts cooling, and one that answered is not cooling at all — the canary answering is
    what ends the wait. A family whose failures were something else (a wall, a review that came
    back as prose) is left alone: neither says anything about whether the gateway is up.
    """
    now = now or _store.utc_now()
    families = {}
    for rater in raters:
        if rater["side"] in GATEWAY_SIDES:
            families.setdefault(_raters.rater_family(rater["spec"]), []).append(
                (rater["spec"] in errored, rater["spec"] in outages)
            )
    if not families:
        return
    path = gateway_cooldown_path()
    with wall_file_lock(path, GATEWAY_COOLDOWN_LOCK):
        try:
            stored = json.loads(path.read_text())
        except (OSError, ValueError):
            stored = {}
        if not isinstance(stored, dict):
            stored = {}
        updated = dict(stored)
        for family, attempts in families.items():
            if not all(failed for failed, _ in attempts):
                updated.pop(family, None)
                continue
            if not all(down for _, down in attempts):
                continue
            previous = updated.get(family)
            since = previous.get("since") if isinstance(previous, dict) else None
            updated[family] = {
                "until": (now + timedelta(minutes=GATEWAY_COOLDOWN_MIN)).isoformat(),
                # The moment the outage STARTED, kept across every extension: a wait that restamps
                # its own beginning reads as a fresh outage however long the gateway has been down.
                "since": since or now.isoformat(),
                "reason": f"{len(attempts)} attempt(s) failed",
            }
        if updated == stored:
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        scratch = path.with_name(f".{path.name}.{os.getpid()}")
        scratch.write_text(json.dumps(updated, indent=2, sort_keys=True) + "\n")
        os.replace(scratch, path)


def apply_gateway_cooldown(raters, now=None):
    """One attempt of each cooling family runs and the rest are skipped — the canary. Holding the
    family out whole is how a tool stops learning that the gateway came back; running every repeat
    of a family that just failed is how a report fills with dead cells and a rerun line offers
    them again.
    """
    cooling = read_gateway_cooldowns(now)
    if not cooling:
        return list(raters), []
    kept, skipped, sent = [], [], set()
    for rater in raters:
        family = _raters.rater_family(rater["spec"]) if rater["side"] in GATEWAY_SIDES else None
        entry = cooling.get(family) if family else None
        if entry is None or family not in sent:
            if entry is not None:
                sent.add(family)
            kept.append(rater)
            continue
        until, reason = entry
        skipped.append((
            rater["spec"],
            f"cooling until {until.strftime('%H:%MZ')} after {reason}; one canary attempt of "
            "this cell is running",
        ))
    return kept, skipped


def cell_available(available, rater):
    """Whether the pool can staff this cell, asked about the bucket the cell will spend."""
    if wall_bucket(rater) == "fable":
        return bool(available.get("claude_fable"))
    return bool(available.get(rater["side"]))


def unaffordable_reason(side):
    """Why the pool cannot staff this side, in the words the skipped line carries.

    Whether to wait for an OpenCode window or to add an account is a question only the reset date
    answers, and it is spelled as a date rather than as the weekday `active_wall_labels` prints:
    that one describes a run that just failed, while a monthly wall lands weeks out.
    """
    # A pool the caller emptied reads exactly like one nobody staffed, and the reader goes looking
    # for accounts to add instead of at the variable that took the working ones away.
    note = baseline_exclusion_note(side)
    # A closed switch reads exactly like spent quota, and the reader goes hunting for limits that
    # are fine instead of flipping the switch back.
    if reviewers_role_off(side):
        return f"{SIDE_POOL_VENDOR[side]} is switched off for reviewers{note}"
    if side == "opencode":
        labels = [
            f"{name} {window or 'plan'}" + (
                f" resets {datetime.fromtimestamp(reset_at).strftime('%b %-d')}"
                if reset_at is not None else ""
            )
            for name, window, reset_at in standing_side_walls(side)
        ]
        if labels:
            return "opencode pool walled: " + ", ".join(labels) + note
    return f"{side} side is unaffordable{note}"


def skip_state(side):
    """The one word the report's leg row carries for a side the panel could not launch: a switch
    somebody closed, or quota nobody has left. They read alike in a reason sentence and send the
    reader at opposite things — one is flipped back, the other waited out.
    """
    return "off" if reviewers_role_off(side) else "walled"


def measured_skill_only(rater):
    """Sonnet answers almost nothing without the review skill, and nothing of its own.

    Measured 2026-07-26 on 2ecc0bd and fabcae4, both variants at low/medium/high: bare sonnet
    produced 5 claims to skill's 34, and on each commit the single defect it found was one the
    skill cells also found — zero unique across both. Opus is the opposite and keeps both
    variants: about a quarter of its defects on each commit came only from the bare cell.
    """
    if rater["model"] == "sonnet" and not rater["skill"]:
        return ("sonnet reviews only through the skill: bare sonnet found 5 claims to skill's 34 "
                "over two commits and not one defect the skill cells missed")
    return None


def measured_worthless(rater):
    """Cells the adjudicated corpus has already answered, so nobody spends quota re-asking.

    Every entry is a count over recorded runs, not an opinion, and the reason is printed with the
    refusal — this is the whole of the old prose anti-list, enforced instead of described.
    """
    if rater["model"] == "haiku":
        return "caught 0 defects across 11 recorded runs while producing 11 false claims"
    return _catalog.WORTHLESS_CELLS.get(_raters.normalize_legacy_rater(rater["spec"]))


def refuse_retired_cells(raters, lens=None):
    # run_agy has no diff-only mode left to reach, so a skill-less agy spec would quietly run the
    # skill and record the findings under a name claiming otherwise.
    retired = [rater["spec"] for rater in raters if rater["side"] == "agy" and not rater["skill"]]
    skill_only = [(rater["spec"], measured_skill_only(rater)) for rater in raters
                  if measured_skill_only(rater)]
    if retired or skill_only:
        if lens:
            specs = ", ".join(retired + [spec for spec, _ in skill_only])
            raise RuntimeError(
                f"these cells are unreachable under lens {lens['name']}: {specs} require the "
                "review skill the lens replaces; choose a different cell"
            )
        asked = ", ".join(f"{spec}-skill" for spec in retired + [s for s, _ in skill_only])
        why = "; ".join(reason for _, reason in skill_only)
        raise RuntimeError(
            f"these cells run the review skill; ask for {asked}" + (f" — {why}" if why else "")
        )
    excluded = [
        (rater["spec"], _catalog.EXCLUDED_CELLS.get(_raters.normalize_legacy_rater(rater["spec"])))
        for rater in raters
        if _catalog.EXCLUDED_CELLS.get(_raters.normalize_legacy_rater(rater["spec"]))
    ]
    if excluded:
        raise RuntimeError(
            "these cells are excluded: "
            + "; ".join(f"{spec} ({reason})" for spec, reason in excluded)
        )
    worthless = [(rater["spec"], measured_worthless(rater)) for rater in raters
                 if measured_worthless(rater)]
    if worthless:
        raise RuntimeError(
            "these cells are retired by measurement: "
            + "; ".join(f"{spec} ({reason})" for spec, reason in worthless)
        )


def codex_failure_reason(events):
    """What the run actually failed on, for a CLI that says so only in its event stream.

    Codex exits non-zero with an empty stderr, so a failure recorded from stderr alone reads as
    a silent death and cannot be classified afterwards: 31 of the runs on record are exactly
    that, and every one of them turned out to be the same recoverable capacity refusal.

    Every such message, not the last one. The named cause usually arrives first and a generic
    turn.failed follows it, so keeping only the last is how "model is at capacity" — the whole
    reason this exists — stops reaching the retry classifier that reads nothing else.
    """
    reasons = []
    for raw in (events or "").splitlines():
        try:
            event = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            continue
        if not isinstance(event, dict) or event.get("type") not in ("error", "turn.failed"):
            continue
        error = event.get("error")
        message = event.get("message") or (error.get("message") if isinstance(error, dict) else None)
        if isinstance(message, str) and message.strip() and message.strip() not in reasons:
            reasons.append(message.strip())
    return "\n".join(reasons)


def codex_usage_wall(events, stderr):
    # Neither a bare 429 nor rate-limit wording, for the reason opencode_usage_wall gives: both
    # are what a throttled provider answers as much as a spent plan, and only one of them is the
    # account's own window. "provider rate limit exceeded" is the throttle's own phrase upstream.
    # What names the plan still retires the account; the rest is retried as transient.
    pattern = r"\busage[ _-]limit(?:[ _-]exceeded)?\b|\bquota[ _-]exceeded\b"
    if re.search(pattern, stderr or "", re.IGNORECASE):
        return True
    for raw in (events or "").splitlines():
        try:
            event = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") not in ("error", "turn.failed"):
            continue
        if re.search(pattern, json.dumps(event), re.IGNORECASE):
            return True
    return False


def is_429_error(result_json_text):
    """Detect 429 only from structured error signals, not from findings text."""
    try:
        result = json.loads(result_json_text)
        if isinstance(result, dict):
            if result.get("is_error") and result.get("api_error_status") == 429:
                return True
            errors = result.get("errors", [])
            if isinstance(errors, list):
                for err in errors:
                    if isinstance(err, str) and "hit your session limit" in err:
                        return True
    except (json.JSONDecodeError, ValueError):
        pass
    return False


def check_limits_staleness(account):
    command = [_store.command_path("REVIEW_BENCH_LIMITS_BIN", "llm-limits"), "--json", "--no-write"]
    try:
        proc = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return False
    if proc.returncode != 0:
        return False
    try:
        data = json.loads(proc.stdout)
        vendors = data.get("vendors", {})
        claude_data = vendors.get("claude", {})
        accounts_data = claude_data.get("accounts", [])
        for account_obj in accounts_data:
            if account_obj.get("account") == account:
                as_of = account_obj.get("as_of")
                if as_of:
                    epoch = _store.iso_to_epoch(as_of)
                    if epoch is not None:
                        age = time.time() - epoch
                        return age > LIMITS_STALE_AGE_S
                break
    except (json.JSONDecodeError, KeyError, TypeError, ValueError):
        pass
    return False


def refresh_limits(account):
    command = [
        _store.command_path("REVIEW_BENCH_LIMITS_BIN", "llm-limits"),
        "--refresh-account", f"claude/{account}"
    ]
    try:
        proc = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        pass


# Each vendor announces an exhausted account in its own words, and only its own words are
# trusted: a rater that merely failed must not retire an account that still has quota.
SIDE_WALL = {
    "claude": lambda rc, text, stderr: is_429_error(text),
    "codex": lambda rc, events, stderr: codex_usage_wall(events, stderr),
    # Gemini words a per-model exhaustion differently from an account-wide one, and a cell that
    # fails instead of rotating is the whole point of asking the pool for another account.
    "agy": lambda rc, text, stderr: bool(
        re.search(r"Individual quota reached|RESOURCE_EXHAUSTED"
                  r"|exhausted your capacity on this model", stderr or "", re.IGNORECASE)),
    "opencode": lambda rc, text, stderr: opencode_usage_wall(stderr),
}
def _never_transient(rc, text, stderr):
    return False


# Only the sides whose gateways are measured to answer this way: a side listed here without
# a matching classifier would turn every ordinary failure into a retry and triple the run.
SIDE_TRANSIENT = {
    "opencode": lambda rc, text, stderr: opencode_transient_failure(stderr),
    "codex": lambda rc, events, stderr: codex_transient_failure(events, stderr),
}


def transient_backoffs():
    """Waits between retries of a transient failure, shortest first."""
    raw = os.environ.get("REVIEW_BENCH_TRANSIENT_BACKOFF_S", "15,30")
    delays = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            delay = float(part)
        except ValueError:
            continue
        if math.isfinite(delay) and delay >= 0:
            delays.append(delay)
    return delays


# The pool is asked rather than reproduced: worker-pick's prose output is not a contract, and a
# second copy of the selection here is the per-tool mechanism the pool exists to replace.
SIDE_POOL_VENDOR = {"claude": "claudeb", "codex": "codex", "agy": "gemini"}


def reviewers_role_off(side):
    """Whether the worker-model switch has this side's vendor closed for reviewers.

    Read out of worker-pick's own config file, so the two can never disagree, and read on every
    ask. It decides nothing — worker-pick still refuses the account — but it keys the roster
    cache and words the refusal: a roster cached behind a flipped switch would go on staffing
    cells on a vendor that was just closed.
    """
    vendor = SIDE_POOL_VENDOR.get(side)
    if not vendor:
        return False
    path = os.environ.get("WORKER_PICK_CONFIG_FILE") or os.path.expanduser("~/.claude/worker-model")
    prefix = f"{vendor}_reviewers="
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if line.startswith(prefix):
                    return line[len(prefix):].strip() == "off"
    except OSError:
        return False
    return False


def role_closed_note(side):
    """The clause naming a closed reviewers switch, empty while the vendor is open."""
    if not reviewers_role_off(side):
        return ""
    return f"; {SIDE_POOL_VENDOR[side]} is switched off for reviewers"


def baseline_exclusions(side):
    """Accounts the caller has taken off the table for this side before the pool is asked.

    Steering a measurement onto one account is narrowing what the pool may choose from, not
    choosing instead of it: the pool toggle and the walls all still apply.
    """
    names = [side]
    vendor = SIDE_POOL_VENDOR.get(side)
    if vendor and vendor != side:
        # `agy` is the internal side name and `gemini` is what worker-pick and the user call it;
        # accepting only one of them makes a reasonable spelling fail silently.
        names.append(vendor)
    excluded = set()
    for name in names:
        raw = os.environ.get(f"REVIEW_BENCH_EXCLUDE_{name.upper()}", "")
        excluded |= {part.strip() for part in raw.split(",") if part.strip()}
    return excluded


def baseline_exclusion_note(side):
    """The reason clause naming what the caller took off the table, empty when nothing was."""
    excluded = baseline_exclusions(side)
    if not excluded:
        return ""
    return (f"; excluded by REVIEW_BENCH_EXCLUDE_{side.upper()}: "
            f"{', '.join(sorted(excluded))}")


def worker_pick_answer(side, excluded, fable=False):
    """The pool's account for this side, and whether it came as the session reserve.

    `fable` names the bucket the caller will spend rather than a model: only `--account
    claudeb` has a second bucket, and worker-pick refuses the flag anywhere else.
    """
    command = [_store.command_path("REVIEW_BENCH_WORKER_PICK_BIN", "worker-pick"),
               "--account", SIDE_POOL_VENDOR[side], "--role", "reviewers"]
    if excluded:
        command += ["--exclude", ",".join(sorted(excluded))]
    if fable and side == "claude":
        command.append("--fable")
    try:
        proc = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"worker-pick --account {SIDE_POOL_VENDOR[side]} failed: {exc}") from exc
    # 3 is the pool's own "nothing selectable", which is an answer rather than a breakage.
    if proc.returncode == 3:
        return (None, False)
    if proc.returncode != 0:
        raise RuntimeError(
            f"worker-pick --account {SIDE_POOL_VENDOR[side]}: "
            f"{proc.stderr.strip() or proc.returncode}"
        )
    account = proc.stdout.strip() or None
    return (account, bool(account) and "SESSION RESERVE" in proc.stderr)


_SIDE_ROSTER = {}
_SIDE_ROSTER_LOCK = threading.Lock()
# One gate per roster, not one for all of them: enumeration spawns a worker-pick per account
# and a slow pool would otherwise hold every other side out of its own answer for the duration.
# _SIDE_ROSTER_LOCK guards only the two dict lookups and is never held across a subprocess.
_SIDE_ROSTER_GATES = {}
ROSTER_MAX = 8
# Long enough that a run's cells share one enumeration, short enough that a floor crossed
# mid-run is noticed while the run is still going.
ROSTER_TTL_S = 60


def side_roster(side, baseline, fable=False):
    """Every account the pool will offer this side for this bucket, in the pool's own order.

    Enumerated by asking again with the previous answers excluded, rather than reading the
    limits table here: the ranking, the walls and the session-reserve rule stay the pool's
    to decide. Cached briefly because a per-cell enumeration would spawn one worker-pick per
    account per cell for an answer the run already has.

    Briefly, and never when it came out empty: the answer is a live verdict about walls that
    the run itself keeps invalidating, so holding it for the process would both keep feeding
    cells to an account that has since walled and freeze one empty moment into a
    side with nothing to offer for good. Enumerated under the lock, because every cell of a
    side misses the cache at once and would otherwise enumerate in parallel — the per-cell
    fan-out of worker-pick processes this cache exists to prevent.
    """
    # The bucket is part of the key: a fable roster and an ordinary one rank different numbers
    # and sharing a cache entry would hand fable cells the weekly bucket's answer.
    # The reviewers switch is part of the key too: a cached roster cannot outlive the flip that
    # closed its vendor, so the next cell re-asks the pool and is refused there.
    key = (side, tuple(sorted(baseline)), fable, reviewers_role_off(side))
    with _SIDE_ROSTER_LOCK:
        fresh = cached_roster(key)
        if fresh is not None:
            return fresh
        gate = _SIDE_ROSTER_GATES.setdefault(key, threading.Lock())
    with gate:
        with _SIDE_ROSTER_LOCK:
            fresh = cached_roster(key)
        if fresh is not None:
            return fresh
        roster = []
        seen = set(baseline)
        while len(roster) < ROSTER_MAX:
            account, reserve = worker_pick_answer(side, seen, fable)
            # A repeated answer means the pool ignored the exclusion, which would otherwise spin.
            if account is None or account in seen:
                break
            if reserve:
                # The session account is offered only once nothing else is selectable, so it
                # is the tail of every enumeration by construction. Appending it would turn a
                # last resort into an ordinary roster slot the spread hands cells to.
                if not roster:
                    roster.append(account)
                    print(f"{side} pool is empty; staffing on the session account "
                          f"{account} (SESSION RESERVE)")
                break
            roster.append(account)
            seen.add(account)
        with _SIDE_ROSTER_LOCK:
            if roster:
                _SIDE_ROSTER[key] = (time.monotonic(), roster)
        return roster


def cached_roster(key):
    cached = _SIDE_ROSTER.get(key)
    if cached is None or time.monotonic() - cached[0] >= ROSTER_TTL_S:
        return None
    return cached[1]


def spread_accounts():
    return os.environ.get("REVIEW_BENCH_SPREAD_ACCOUNTS", "1").strip() not in ("0", "no", "off")


def pool_account(side, excluded, slot=0, bucket="general"):
    """The pool's account for this cell, or None when it has nothing left to offer.

    Cells of one side start at different points in the roster instead of all taking its head:
    the pool ranks accounts but does not know how many cells are about to ask, so one answer
    handed to every cell puts a whole run's concurrency on a single account and leaves the
    rest of the roster idle.
    """
    excluded = set(excluded) | baseline_exclusions(side)
    spread = spread_accounts()
    fable = side == "claude" and bucket == "fable"
    if side == "opencode":
        profiles = [opencode_account(profile) for profile in opencode_profiles()]
        return first_free_account(side, profiles, excluded, slot if spread else 0, bucket)
    if not spread:
        return worker_pick_answer(side, excluded, fable)[0]
    roster = side_roster(side, baseline_exclusions(side), fable)
    if not roster:
        return None
    return first_free_account(side, roster, excluded, slot, bucket)


def first_free_account(side, roster, excluded, slot, bucket="general"):
    """This cell's share of the accounts that can actually take work.

    Retired accounts are dropped before the slot is applied, not skipped after it: a roster
    position that cannot run would otherwise hand its cells to whichever account follows it
    and load that one twice over while the rest of the pool sits idle.

    The cell's own bucket decides what counts as retired. Gemini walls per model and Claude
    bills fable separately, so asking about the general bucket answers about a quota this
    cell does not spend: for those sides the filter would drop nobody at all.
    """
    walled = walled_accounts(side, bucket)
    usable = [
        account for account in roster
        if account and account not in excluded and account not in walled
    ]
    if not usable:
        return None
    return usable[slot % len(usable)]


