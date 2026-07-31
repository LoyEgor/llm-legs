#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/review-bench"
STATS="$ROOT/bin/worker-stats"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
contains() { grep -Fq -- "$2" <<<"$1"; }

python3 - "$SCRIPT" "$ROOT/tests/fixtures/review-bench" "$ROOT" "$WORK" "$$" <<'PY'
import concurrent.futures
import argparse
from collections import Counter
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time

loader = importlib.machinery.SourceFileLoader("review_bench", sys.argv[1])
spec = importlib.util.spec_from_loader("review_bench", loader)
rb = importlib.util.module_from_spec(spec)
loader.exec_module(rb)
assert rb.REPORT_BEGIN == "REVIEW-REPORT-BEGIN"
assert rb.REPORT_END == "REVIEW-REPORT-END"
rb.REPORT_BEGIN = "FIXTURE-REVIEW-REPORT-BEGIN"
rb.REPORT_END = "FIXTURE-REVIEW-REPORT-END"
fixtures = pathlib.Path(sys.argv[2])
repo = pathlib.Path(sys.argv[3])
work = pathlib.Path(sys.argv[4])
live_shell_pid = int(sys.argv[5])
fixture_home = work / "home"
fixture_home.mkdir()
os.environ["HOME"] = str(fixture_home)


def clear_walls():
    (rb.state_dir() / rb.WALL_STATE_FILE).unlink(missing_ok=True)


wall_probe = r"""
import importlib.machinery
import importlib.util
import os
import sys

loader = importlib.machinery.SourceFileLoader("review_bench_probe", sys.argv[1])
spec = importlib.util.spec_from_loader("review_bench_probe", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
side, account, bucket = sys.argv[3:6]
if sys.argv[2] == "mark":
    module.mark_walled(side, account, bucket)
elif sys.argv[2] == "reload":
    assert not module.is_walled(side, account, bucket)
    child = os.fork()
    if child == 0:
        module.mark_walled(side, account, bucket)
        os._exit(0)
    _, status = os.waitpid(child, 0)
    assert os.waitstatus_to_exitcode(status) == 0
elif sys.argv[2] == "delete":
    assert module.is_walled(side, account, bucket)
    (module.state_dir() / module.WALL_STATE_FILE).unlink()
elif sys.argv[2] == "truncate":
    assert module.is_walled(side, account, bucket)
    (module.state_dir() / module.WALL_STATE_FILE).write_text("")
elif sys.argv[2] == "recreate":
    # No file, then one this process creates, then none again: a cache that records the
    # first "no file here" compares equal to the last and never reloads.
    assert not module.is_walled(side, account, bucket)
    module.mark_walled(side, account, bucket)
    (module.state_dir() / module.WALL_STATE_FILE).unlink()
print(int(module.is_walled(side, account, bucket)))
"""


def probe_wall(state, action, side="agy", account="work", bucket="agy-pro", ttl=None):
    env = dict(os.environ, WORKER_STATS_DIR=str(state))
    env.pop("REVIEW_BENCH_WALL_TTL_S", None)
    if ttl is not None:
        env["REVIEW_BENCH_WALL_TTL_S"] = str(ttl)
    return subprocess.run(
        [sys.executable, "-c", wall_probe, sys.argv[1], action, side, account, bucket],
        check=True, capture_output=True, text=True, env=env,
    ).stdout.strip()


persisted_wall_state = work / "persisted-wall-state"
assert probe_wall(persisted_wall_state, "mark") == "1"
assert probe_wall(persisted_wall_state, "check") == "1"
persisted_row = json.loads(
    (persisted_wall_state / rb.WALL_STATE_FILE).read_text().splitlines()[-1]
)
assert persisted_row["side"] == "agy" and persisted_row["account"] == "work"
assert persisted_row["bucket"] == "agy-pro" and persisted_row["detected_at"] > 0

expired_wall_state = work / "expired-wall-state"
expired_wall_state.mkdir()
(expired_wall_state / rb.WALL_STATE_FILE).write_text(json.dumps({
    "side": "agy", "account": "work", "bucket": "agy-pro",
    "detected_at": time.time() - 10,
}) + "\n")
assert probe_wall(expired_wall_state, "check", ttl=1) == "0"

corrupt_wall_state = work / "corrupt-wall-state"
corrupt_wall_state.mkdir()
(corrupt_wall_state / rb.WALL_STATE_FILE).write_text("{not json\n")
assert probe_wall(corrupt_wall_state, "check") == "0"

mixed_wall_state = work / "mixed-wall-state"
mixed_wall_state.mkdir()
(mixed_wall_state / rb.WALL_STATE_FILE).write_text(
    "{not json\n" + json.dumps({
        "side": "agy", "account": "work", "bucket": "agy-pro",
        "detected_at": time.time(),
    }) + "\n"
)
assert probe_wall(mixed_wall_state, "check") == "1"

reloaded_wall_state = work / "reloaded-wall-state"
assert probe_wall(reloaded_wall_state, "reload", account="second") == "1"

deleted_wall_state = work / "deleted-wall-state"
assert probe_wall(deleted_wall_state, "mark") == "1"
assert probe_wall(deleted_wall_state, "delete") == "0"

compacted_wall_state = work / "compacted-wall-state"
compacted_wall_state.mkdir()
compacted_path = compacted_wall_state / rb.WALL_STATE_FILE
expired_rows = [
    {
        "side": "agy", "account": f"expired-{index}", "bucket": "agy-pro",
        "detected_at": time.time() - 7200,
    }
    for index in range(80)
]
live_row = {
    "side": "agy", "account": "live", "bucket": "agy-pro",
    "detected_at": time.time(),
}
compacted_path.write_text(
    "".join(json.dumps(row) + "\n" for row in expired_rows + [live_row])
)
assert compacted_path.stat().st_size > rb.WALL_COMPACT_BYTES
assert probe_wall(compacted_wall_state, "check", account="live") == "1"
assert [json.loads(line) for line in compacted_path.read_text().splitlines()] == [live_row]

# The row that stands longest wins the merge: a plain wall recorded after a dated one must not
# throw the provider's horizon away and put a weekly limit back in the pool an hour later.
horizon_wall_state = work / "horizon-wall-state"
horizon_wall_state.mkdir()
horizon_path = horizon_wall_state / rb.WALL_STATE_FILE
horizon_path.write_text(
    json.dumps({
        "side": "opencode", "account": "go", "bucket": "general",
        "detected_at": time.time() - 600, "reset_at": time.time() + 3 * 86400,
    }) + "\n" + json.dumps({
        "side": "opencode", "account": "go", "bucket": "general",
        "detected_at": time.time(),
    }) + "\n"
)
horizon_rows = rb.read_wall_rows(horizon_path)
assert horizon_rows[("opencode", "go", "general")][1] > time.time() + 2 * 86400, horizon_rows

# The record is advisory: a read that fails leaves accounts usable, because refusing to run on
# a transient error empties the pool of accounts that were never out of quota.
unreadable_state = work / "unreadable-wall-state"
unreadable_state.mkdir()
unreadable_path = unreadable_state / rb.WALL_STATE_FILE
unreadable_path.write_text("")
real_read_wall_rows = rb.read_wall_rows
rb.read_wall_rows = lambda path: None
os.environ["WORKER_STATS_DIR"] = str(unreadable_state)
try:
    assert not rb.is_walled("opencode", "go")
finally:
    rb.read_wall_rows = real_read_wall_rows
    del os.environ["WORKER_STATS_DIR"]

# Every answer comes from the file, so a wall another process appends is seen at once and one
# this process recorded is gone the moment the file is cleared.
live_state = work / "live-wall-state"
live_state.mkdir()
os.environ["WORKER_STATS_DIR"] = str(live_state)
try:
    assert not rb.is_walled("opencode", "shared")
    (live_state / rb.WALL_STATE_FILE).write_text(json.dumps({
        "side": "opencode", "account": "shared", "bucket": "general",
        "detected_at": time.time(),
    }) + "\n")
    assert rb.is_walled("opencode", "shared")
    (live_state / rb.WALL_STATE_FILE).unlink()
    assert not rb.is_walled("opencode", "shared")
finally:
    del os.environ["WORKER_STATS_DIR"]

# Compaction that cannot take the lock leaves the rows alone: rewriting the file unlocked is
# the very race the lock exists to prevent.
unlocked_state = work / "unlocked-wall-state"
unlocked_state.mkdir()
unlocked_path = unlocked_state / rb.WALL_STATE_FILE
unlocked_rows = "".join(json.dumps({
    "side": "agy", "account": f"expired-{index}", "bucket": "agy-pro",
    "detected_at": time.time() - 7200,
}) + "\n" for index in range(3))
unlocked_path.write_text(unlocked_rows)


@contextlib.contextmanager
def refuse_the_lock(path):
    yield False


real_wall_file_lock = rb.wall_file_lock
rb.wall_file_lock = refuse_the_lock
try:
    assert rb.compact_walls(unlocked_path) is None
finally:
    rb.wall_file_lock = real_wall_file_lock
assert unlocked_path.read_text() == unlocked_rows

# The provider's own horizon beats the flat guess in both directions: a plain wall recorded later
# must not shorten a dated one, and the flat hour must not sit on top of a reset a minute away.
rank_state = work / "wall-rank-state"
rank_state.mkdir()
rank_path = rank_state / rb.WALL_STATE_FILE
now = time.time()
rank_path.write_text(
    json.dumps({"side": "agy", "account": "a", "bucket": "agy-pro",
                "detected_at": now - 10, "reset_at": now + 30}) + "\n"
    + json.dumps({"side": "agy", "account": "a", "bucket": "agy-pro",
                  "detected_at": now}) + "\n"
    + json.dumps({"side": "agy", "account": "b", "bucket": "agy-pro",
                  "detected_at": now - 10, "reset_at": now + 3 * 86400}) + "\n"
    + json.dumps({"side": "agy", "account": "b", "bucket": "agy-pro",
                  "detected_at": now}) + "\n"
)
ranked = rb.read_wall_rows(rank_path)
assert ranked[("agy", "a", "agy-pro")][1] == now + 30, ranked
assert ranked[("agy", "b", "agy-pro")][1] == now + 3 * 86400, ranked
# Once the provider's horizon passes the account is open, and an older flat guess must not
# outlive it — that guess was made about a window the provider has since answered for.
assert rb.standing_wall([(now - 1800, None), (now - 600, now - 60)]) is None
# What was recorded after that reset is about the window that came next, so it still closes it.
assert rb.standing_wall(
    [(now - 1800, None), (now - 600, now - 60), (now - 30, None)]
) == (now - 30, None)
# And a plain wall recorded later than a dated one does not shorten it to the flat hour.
assert rb.standing_wall([(now - 600, now + 3 * 86400), (now, None)])[1] == now + 3 * 86400
# Two cells can be told different things seconds apart, and a weekly limit does not stop being
# spent because a shorter refusal was written down after it.
assert rb.standing_wall(
    [(now - 600, now + 3 * 86400), (now, now + 60)]
)[1] == now + 3 * 86400

# A horizon is read out of the gateway's channel only. The review this repo's own cells write
# quotes reset wording from the code under review, and taken as the provider's word it retires
# an account that never said anything of the kind.
review_prose = "the test asserts it resets in 3 days"
assert rb.wall_reset_at(rb.wall_reset_source("opencode", "HTTP 429", review_prose)) is None
assert rb.wall_reset_at(rb.wall_reset_source("agy", "", review_prose)) is None
assert rb.wall_reset_at(rb.wall_reset_source("opencode", "quota resets in 2 hours", "")) \
    is not None
# Codex says it in the events rather than on stderr, but that stream is its whole stdout: the
# gateway's channel is the error events, and the review travelling beside them is not.
codex_wall_event = json.dumps({"type": "turn.failed",
                               "error": {"message": "usage limit, resets in 2 hours"}})
codex_review_event = json.dumps({"type": "item.completed",
                                 "item": {"text": "the wall resets in 6 days"}})
assert rb.wall_reset_at(rb.wall_reset_source("codex", "", codex_wall_event)) is not None
assert rb.wall_reset_at(rb.wall_reset_source("codex", "", codex_review_event)) is None
# The same stream decides retries, and a review that discusses status codes is not a refusal.
assert not rb.codex_transient_failure(
    json.dumps({"type": "item.completed", "item": {"text": "handles HTTP 429 and 503"}}), ""
)
assert rb.codex_transient_failure(
    json.dumps({"type": "error", "message": "model is at capacity"}), ""
)
# Every error message, not the last: the named cause arrives first and a bare turn.failed
# follows it, so keeping one drops the very wording the retry classifier reads.
capacity_then_generic = "\n".join([
    json.dumps({"type": "error", "message": "model is at capacity"}),
    json.dumps({"type": "turn.failed", "error": {"message": "the turn failed"}}),
])
assert "at capacity" in rb.codex_failure_reason(capacity_then_generic)
assert rb.codex_transient_failure(capacity_then_generic, "")

# A wall the provider dated outlives the flat TTL, and a garbled date does not outlive the cap.
assert rb.wall_still_standing(time.time() - 7200, time.time() + 3600, ttl=1)
assert not rb.wall_still_standing(time.time() - 7200, None, ttl=1)
assert not rb.wall_still_standing(time.time() - 7200, time.time() - 60, ttl=86400)
assert rb.clamped_reset_at(1000.0, 1000.0 + 99 * 86400) == 1000.0 + rb.WALL_MAX_TTL_S
assert rb.clamped_reset_at(1000.0, "not a time") is None
assert rb.wall_reset_at("Weekly usage limit reached. Resets in 3 days.") > time.time() + 2 * 86400
assert rb.wall_reset_at("Resets in 45 minutes") < time.time() + 3600
assert rb.wall_reset_at("HTTP 429 rate limited") is None

dated_wall_state = work / "dated-wall-state"
dated_wall_state.mkdir()
(dated_wall_state / rb.WALL_STATE_FILE).write_text(json.dumps({
    "side": "agy", "account": "work", "bucket": "agy-pro",
    "detected_at": time.time() - 7200, "reset_at": time.time() + 3600,
}) + "\n")
assert probe_wall(dated_wall_state, "check", ttl=1) == "1"

# The file is the record: a wall cleared on disk must not survive in memory until the TTL.
truncated_wall_state = work / "truncated-wall-state"
assert probe_wall(truncated_wall_state, "mark") == "1"
assert probe_wall(truncated_wall_state, "truncate") == "0"
assert probe_wall(work / "recreated-wall-state", "recreate") == "0"

# An append that cannot reach disk says so rather than failing quietly: the file is the only
# record, so that wall is lost and its account will be tried again.
unwritten_state = work / "unwritten-wall-state"
unwritten_state.mkdir()
os.environ["WORKER_STATS_DIR"] = str(unwritten_state)
unwritten_warning = io.StringIO()
real_wall_file_lock_2 = rb.wall_file_lock


@contextlib.contextmanager
def unwritable_wall(path):
    raise OSError("read-only state dir")
    yield True


rb.wall_file_lock = unwritable_wall
try:
    with contextlib.redirect_stderr(unwritten_warning):
        rb.mark_walled("opencode", "unwritten")
finally:
    rb.wall_file_lock = real_wall_file_lock_2
    del os.environ["WORKER_STATS_DIR"]
assert "could not record" in unwritten_warning.getvalue(), unwritten_warning.getvalue()
clear_walls()

# Compaction re-reads under its lock, so a wall appended after any earlier snapshot survives it.
compact_race_state = work / "compact-race-state"
compact_race_state.mkdir()
race_path = compact_race_state / rb.WALL_STATE_FILE
race_path.write_text("".join(json.dumps({
    "side": "agy", "account": f"expired-{index}", "bucket": "agy-pro",
    "detected_at": time.time() - 7200,
}) + "\n" for index in range(80)))
assert race_path.stat().st_size > rb.WALL_COMPACT_BYTES
appended_row = {
    "side": "agy", "account": "appended", "bucket": "agy-pro", "detected_at": time.time(),
}
with race_path.open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(appended_row) + "\n")
rb.compact_walls(race_path)
assert [json.loads(line) for line in race_path.read_text().splitlines()] == [appended_row]

# An append whose own lock attempt failed goes ahead unlocked, so it can land after compaction
# has already read the rows. Replacing the file then drops a standing wall and puts a spent
# account back in the pool, so a file that moved under compaction defers to the writer.
late_race_state = work / "late-append-race-state"
late_race_state.mkdir()
late_path = late_race_state / rb.WALL_STATE_FILE
late_rows = "".join(json.dumps({
    "side": "agy", "account": f"expired-{index}", "bucket": "agy-pro",
    "detected_at": time.time() - 7200,
}) + "\n" for index in range(80))
late_path.write_text(late_rows)
late_wall = {
    "side": "agy", "account": "late", "bucket": "agy-pro", "detected_at": time.time(),
}
real_read_rows = rb.read_wall_rows


def append_while_reading(path):
    rows = real_read_rows(path)
    if path == late_path:
        with path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(late_wall) + "\n")
    return rows


rb.read_wall_rows = append_while_reading
try:
    assert rb.compact_walls(late_path) is None
finally:
    rb.read_wall_rows = real_read_rows
assert late_path.read_text() == late_rows + json.dumps(late_wall) + "\n"
assert rb.read_wall_rows(late_path) == {
    ("agy", "late", "agy-pro"): (late_wall["detected_at"], None)
}

# An interrupted waiter must take its queue entry with it; left behind it is the permanent head
# and every other waiter blocks on never being it.
interrupted_gate = rb.PriorityGate(1)
interrupted_gate.acquire(0)
real_wait = interrupted_gate.cv.wait


def refuse_to_wait(timeout=None):
    raise RuntimeError("interrupted while queued")


interrupted_gate.cv.wait = refuse_to_wait
try:
    interrupted_gate.acquire(5)
except RuntimeError:
    pass
else:
    raise AssertionError("the interrupted acquire should have propagated")
interrupted_gate.cv.wait = real_wait
assert interrupted_gate.waiting == [], interrupted_gate.waiting
interrupted_gate.release()
interrupted_gate.acquire(0)
interrupted_gate.release()

assert rb.parse_rater("sol-medium") == {
    "spec": "sol-medium", "model": "sol", "effort": "medium", "side": "codex",
    "skill": False, "bare": False, "profile": None
}
assert rb.parse_rater("sol-low-bare") == {
    "spec": "sol-low-bare", "model": "sol", "effort": "low", "side": "codex",
    "skill": False, "bare": True, "profile": None
}
assert rb.compact_tier_cell(rb.parse_rater("sol-low")) == "low"
assert rb.compact_tier_cell(rb.parse_rater("sol-low-bare")) == "low-bare"
assert rb.parse_rater("opus-xhigh")["side"] == "claude"
assert rb.parse_rater("opus-xhigh")["skill"] is False
assert rb.parse_rater("fable-medium")["model"] == "fable"
assert rb.parse_rater("opus-medium-skill") == {
    "spec": "opus-medium-skill", "model": "opus", "effort": "medium",
    "side": "claude", "skill": True, "bare": False, "profile": None
}
assert rb.parse_rater("sonnet-high-skill")["skill"] is True
assert rb.parse_rater("haiku-medium-skill")["side"] == "claude"
assert rb.parse_rater("agy-pro-low-skill") == {
    "spec": "agy-pro-low-skill", "model": "agy-pro", "effort": "low",
    "side": "agy", "skill": True, "bare": False, "profile": None
}
assert rb.parse_rater("agy-pro-high-skill")["skill"] is True
assert rb.parse_rater("agy-flash36-medium-skill")["side"] == "agy"
repeated = rb.parse_raters("sol-high x2")
assert [rater["spec"] for rater in repeated] == ["sol-high", "sol-high#2"], repeated
assert repeated[0]["model"] == repeated[1]["model"] == "sol"
assert repeated[0]["effort"] == repeated[1]["effort"] == "high"
duration_medians = rb.review_duration_medians([
    {"rater": "sol-high", "duration_ms": 1000},
    {"rater": "sol-high#2", "duration_ms": 9000},
    {"rater": "sol-high", "duration_ms": 2000},
    {"rater": "opus-medium", "duration_ms": 4000},
    {"rater": "opus-medium#2", "duration_ms": 8000},
    {"rater": "missing-duration"},
])
assert duration_medians == {"sol-high": 2000, "opus-medium": 6000}, duration_medians
expected_durations = rb.expected_review_durations(
    ["sol-high", "sol-high#2", "opus-medium", "no-history"], duration_medians
)
assert expected_durations == {
    "sol-high": 2000, "sol-high#2": 2000, "opus-medium": 6000,
}, expected_durations
assert "no-history" not in expected_durations
assert rb.adaptive_timeout_seconds(None) == 600
assert rb.adaptive_timeout_seconds(100_000) == 180
assert rb.adaptive_timeout_seconds(200_000) == 300
assert rb.adaptive_timeout_seconds(500_000) == 600
timeout_history = work / "agy-timeout-history"
for run_id, rows in {
    "one": [
        {"rater": "agy-flash36-medium-skill", "side": "agy", "duration_ms": 200_000,
         "findings": 0, "exit_code": 0},
        {"rater": "agy-flash36-low-skill", "side": "agy", "duration_ms": 35_000,
         "findings": 2, "exit_code": 0},
    ],
    "two": [
        {"rater": "agy-flash36-medium-skill#2", "side": "agy", "duration_ms": 254_715,
         "findings": 1, "exit_code": 0},
        {"rater": "agy-flash36-high-skill", "side": "agy", "duration_ms": 599_000,
         "findings": 0, "exit_code": 1},
        {"rater": "agy-pro-low-skill", "side": "agy", "duration_ms": 450_000,
         "findings": 0, "exit_code": 0, "errored": True},
        {"rater": "agy-pro-high-skill", "side": "agy", "duration_ms": 500_000,
         "exit_code": 0},
    ],
}.items():
    directory = timeout_history / run_id
    directory.mkdir(parents=True)
    (directory / "meta.json").write_text(json.dumps({"rater_runs": rows}))
timeout_maxima = rb.completed_agy_duration_maxima(timeout_history)
assert timeout_maxima == {
    "agy-flash36-medium-skill": 254_715,
    "agy-flash36-low-skill": 35_000,
}, timeout_maxima
adaptive_timeouts = rb.adaptive_agy_timeouts(timeout_history)
assert adaptive_timeouts["agy-flash36-medium-skill"] == 383
assert adaptive_timeouts["agy-flash36-low-skill"] == 180
assert adaptive_timeouts["agy-flash36-high-skill"] == 600
assert adaptive_timeouts["agy-pro-high-skill"] == 600
for run_id, timeout_s, expected in (
    ("x-three", 383, 575),
    ("y-four", 575, 600),
):
    directory = timeout_history / run_id
    directory.mkdir()
    (directory / "meta.json").write_text(json.dumps({"rater_runs": [{
        "rater": "agy-flash36-medium-skill", "side": "agy",
        "duration_ms": timeout_s * 1000, "timeout_s": timeout_s,
        "findings": 0, "exit_code": 124, "errored": True,
        "stderr": f"rater timed out after {timeout_s}s",
    }]}))
    assert rb.adaptive_agy_timeouts(timeout_history)[
        "agy-flash36-medium-skill"
    ] == expected
completion = timeout_history / "z-five"
completion.mkdir()
(completion / "meta.json").write_text(json.dumps({"rater_runs": [{
    "rater": "agy-flash36-medium-skill", "side": "agy",
    "duration_ms": 240_000, "findings": 1, "exit_code": 0,
}]}))
assert rb.adaptive_agy_timeouts(timeout_history)[
    "agy-flash36-medium-skill"
] == 383
for run_id, finished, row in (
    (
        "20260730T120000Z-zzzzzzz",
        "2026-07-30T12:00:01Z",
        {
            "rater": "agy-flash36-medium-skill", "side": "agy",
            "duration_ms": 240_000, "findings": 1, "exit_code": 0,
        },
    ),
    (
        "20260730T120000Z-aaaaaaa",
        "2026-07-30T12:00:02+00:00",
        {
            "rater": "agy-flash36-medium-skill", "side": "agy",
            "duration_ms": 383_000, "timeout_s": 383, "findings": 0,
            "exit_code": 124, "errored": True, "stderr": "timed out after 383s",
        },
    ),
):
    directory = timeout_history / run_id
    directory.mkdir()
    (directory / "meta.json").write_text(json.dumps({
        "started": "2026-07-30T12:00:00Z",
        "finished": finished,
        "rater_runs": [row],
    }))
assert rb.adaptive_agy_timeouts(timeout_history)[
    "agy-flash36-medium-skill"
] == 575
assert rb.human_cell_name("agy-flash35-medium-skill") == \
    "Gemini 3.5 Flash medium skill"
assert rb.human_cell_name("sol-high-bare") == "Sol high bare"
max_tier_rows = [
    {
        "rater": rater["spec"], "side": rater["side"], "duration_ms": 1000,
        "findings": 0, "exit_code": 0,
    }
    for rater in rb.parse_raters(",".join(rb.REVIEW_TIERS["T3"]["cells_max"]))
]
max_tier_meta = {
    "run_id": "max-tier", "tier": "T3", "max": True,
    "raters": [row["rater"] for row in max_tier_rows],
    "rater_runs": max_tier_rows,
    "started": "2026-07-30T00:00:00+00:00",
    "finished": "2026-07-30T00:00:01+00:00",
}
max_tier_dir = work / "max-tier-report"
max_tier_dir.mkdir()
assert rb.tier_from_meta(max_tier_meta) == "T3 max"
assert rb.review_log_event("run", max_tier_dir, max_tier_meta)["tier"] == "T3 max"
assert rb.report_lines(max_tier_dir, max_tier_meta)[0].startswith("T3 max · ")
marked_report = io.StringIO()
with contextlib.redirect_stdout(marked_report):
    rb.emit_report(max_tier_dir, max_tier_meta)
marked_lines = marked_report.getvalue().splitlines()
assert marked_lines[0] == rb.REPORT_BEGIN and marked_lines[-1] == rb.REPORT_END
partial_tier_meta = dict(max_tier_meta, rater_runs=max_tier_rows[:1])
assert rb.tier_from_meta(partial_tier_meta) == "T3 max"
legacy_t2_raters = [
    rater["spec"]
    for rater in rb.parse_raters(",".join(rb.REVIEW_TIERS["T2"]["cells"]))
]
assert rb.tier_from_meta({"raters": legacy_t2_raters}) == "T2"
assert rb.tier_from_meta({"raters": ["sol-low"]}) is None
newest_fixture = work / "newest-runs"
for name, started, finished in (
    ("older", "2026-07-30T12:00:00Z", "2026-07-30T12:01:00Z"),
    ("newer", "2026-07-30T13:00:00", "2026-07-30T13:01:00"),
    ("aborted", "2026-07-30T14:00:00Z", None),
):
    directory = newest_fixture / name
    directory.mkdir(parents=True)
    meta = {"run_id": name, "started": started}
    if finished:
        meta["finished"] = finished
    (directory / "meta.json").write_text(json.dumps(meta))
assert rb.newest_run_dir(newest_fixture).name == "newer"
duration_dir = work / "duration-report"
duration_dir.mkdir()
duration_meta = {
    "raters": ["sol-max", "sol-low"],
    "rater_runs": [
        {"rater": "sol-max", "exit_code": 0, "findings": 0},
        {"rater": "sol-low", "exit_code": 0, "findings": 0, "duration_ms": 1000},
    ],
    "started": "2026-07-30T00:00:00Z",
    "finished": "2026-07-30T00:00:02Z",
}
duration_header = rb.report_lines(duration_dir, duration_meta)[0]
assert "slowest completed: Sol low 1 sec" in duration_header
assert "0 sec" not in duration_header
unknown_duration_meta = dict(
    duration_meta,
    raters=["sol-max"],
    rater_runs=[{"rater": "sol-max", "exit_code": 0, "findings": 0}],
)
assert "completed durations unknown" in rb.report_lines(
    duration_dir, unknown_duration_meta
)[0]
not_run_meta = dict(
    duration_meta,
    raters=["sol-low"],
    completed_raters=[],
    rater_runs=[],
)
not_run_report = "\n".join(rb.report_lines(duration_dir, not_run_meta))
assert any(
    line.startswith("not run:") and line.endswith("Sol low")
    for line in not_run_report.splitlines()
)
assert "errored:" not in not_run_report
reason_meta = dict(
    duration_meta,
    raters=["sol-low", "oc-kimik3"],
    rater_runs=[
        {"rater": "sol-low", "exit_code": 1, "errored": True,
         "stderr": 'HTTP 429 {"error":{"code":"provider_rate_limit_exceeded"}}'},
        {"rater": "oc-kimik3", "exit_code": 3, "errored": True, "stderr": "boom"},
    ],
)
reason_report = "\n".join(rb.report_lines(duration_dir, reason_meta))
assert "Sol low (throttled)" in reason_report, reason_report
# Nothing recognisable in the text leaves the exit code as the only fact left to print, and a
# cell that said nothing at all is the same case: naming the silence discards that last fact.
assert "Kimi K3 (exit 3)" in reason_report, reason_report
silent_meta = dict(
    duration_meta,
    raters=["sol-low"],
    rater_runs=[{"rater": "sol-low", "exit_code": 5, "errored": True, "stderr": ""}],
)
assert "Sol low (exit 5)" in "\n".join(rb.report_lines(duration_dir, silent_meta))

# Counts come back out of a JSON file anyone can hand-edit, and `True` is an int in Python:
# a hand-written `"verifier_dropped": true` would otherwise report one rejected finding.
assert rb.counted_int(3) == 3
assert rb.counted_int(True) == rb.counted_int(-1) == rb.counted_int("3") == 0
assert rb.counted_int(None) == 0

# The verifier changes model per finding when the gateway throttles one, so the report names
# who actually judged rather than who was configured, and says so even when nobody answered.
chain_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    verifier="oc-kimik3",
    raters=["oc-kimik3", "oc-grok45-low"],
    rater_runs=[
        {"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 1,
         "verifier_dropped": 2, "verifier_audited": 3,
         "verifier_by_model": {"oc-kimik3": 3}},
        {"rater": "oc-grok45-low", "side": "opencode", "exit_code": 0, "findings": 1,
         "verifier_dropped": 1, "verifier_audited": 2,
         "verifier_by_model": {"oc-qwen37plus": 2}},
    ],
)))
assert "verifier:  Kimi K3 3 · oc-qwen37plus 2 — 5 checked, 3 rejected" in chain_report, \
    chain_report
walled_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    verifier="oc-kimik3",
    raters=["oc-kimik3"],
    rater_runs=[
        {"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 2,
         "verifier_dropped": 0, "verifier_audited": 2, "verifier_by_model": {}},
    ],
)))
assert "verifier:  Kimi K3 — 0 checked, 0 rejected, 2 kept unchecked" in walled_report, \
    walled_report
# A run recorded before the verifier logged its own counts keeps only the drop total, and a
# report that reads its absence as "nothing to check" would deny checks that did happen.
legacy_verifier_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    verifier="oc-kimik3",
    raters=["oc-kimik3"],
    rater_runs=[
        {"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 1,
         "verifier_dropped": 4},
    ],
)))
assert "verifier:  Kimi K3 — 4 rejected" in legacy_verifier_report, legacy_verifier_report
# 3 of the 205 runs on disk are that same legacy record with nothing rejected: reading the zero
# as "the verifier never ran" reports every finding it cleared as unchecked. verify_ms is what
# says it ran, and it has been recorded per cell since c011911.
legacy_kept_all_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    verifier="oc-kimik3",
    raters=["oc-kimik3"],
    rater_runs=[
        {"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 2,
         "verifier_dropped": 0, "verifier_unverified": 0, "verify_ms": 4000},
    ],
)))
assert "verifier:  Kimi K3 — 0 rejected" in legacy_kept_all_report.splitlines(), \
    legacy_kept_all_report
# 7 of those legacy runs walled the verifier partway. The wall total is the only unchecked count
# they kept, so a line that prints the drops alone reports a partial pass as a complete one.
legacy_walled_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    verifier="oc-kimik3",
    raters=["oc-kimik3"],
    rater_runs=[
        {"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 5,
         "verifier_dropped": 1, "verifier_unverified": 3, "verify_ms": 4000},
    ],
)))
assert "verifier:  Kimi K3 — 1 rejected, 3 kept unchecked" in legacy_walled_report, \
    legacy_walled_report
# A wall before the first rejection leaves the wall count as the only evidence the verifier ran,
# so a guard reading the drop total alone reports those findings as never offered to it.
legacy_wall_only_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    verifier="oc-kimik3",
    raters=["oc-kimik3"],
    rater_runs=[
        {"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 2,
         "verifier_dropped": 0, "verifier_unverified": 2},
    ],
)))
assert "verifier:  Kimi K3 — 0 rejected, 2 kept unchecked" in legacy_wall_only_report, \
    legacy_wall_only_report
# Every count is read back out of a file anyone can hand-edit, so each is sanitised where it is
# read, not only where it is summed: a bool reaching one cell field and not its neighbour is the
# inconsistency that makes the next edit trust the wrong one.
sanitised_cells = rb.bench_summary(duration_dir, dict(
    duration_meta,
    verifier="oc-kimik3",
    raters=["oc-kimik3"],
    rater_runs=[
        {"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 1,
         "verifier_dropped": True, "verifier_unverified": -2, "verifier_audited": True},
    ],
))["cells"]
assert sanitised_cells[0]["verifier_dropped"] == 0, sanitised_cells
assert sanitised_cells[0]["verifier_unverified"] == 0, sanitised_cells
assert sanitised_cells[0]["verifier_audited"] == 0, sanitised_cells
# Nothing was offered to it, so "unchecked" would name material that does not exist.
nothing_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    verifier="oc-kimik3",
    raters=["oc-kimik3"],
    rater_runs=[{"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 0}],
)))
assert "verifier:  Kimi K3 — nothing to check" in nothing_report, nothing_report
empty_off_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    raters=["oc-kimik3"],
    rater_runs=[{"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 0}],
)))
assert "verifier:  off — nothing to check" in empty_off_report, empty_off_report
off_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    raters=["oc-kimik3"],
    rater_runs=[{"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 3}],
)))
assert "verifier:  off — 3 OpenCode finding(s) unchecked" in off_report, off_report
# The verifier reaches OpenCode findings only, so a panel without one is not a run whose
# verifier stayed off — there was nothing it was allowed to touch, and the line would mislead.
assert "verifier:" not in "\n".join(rb.report_lines(duration_dir, duration_meta))

# --- findings: one entry per place, agreement first --------------------------------------
findings_dir = work / "findings-view"
findings_dir.mkdir()
(findings_dir / "meta.json").write_text(json.dumps({"rater_runs": []}))


def write_findings(cell, rows):
    (findings_dir / f"findings-{cell}.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in rows)
    )


write_findings("sol-low", [
    {"file": "z.py", "line": 10, "severity": "P2", "summary": "shared claim"},
    {"file": "a.py", "line": 1, "severity": "P1", "summary": "only sol saw this"},
])
write_findings("oc-kimik3", [
    {"file": "z.py", "line": 10, "severity": "P2", "summary": "shared claim, said again"},
])
# A repeat of the same cell is one cell agreeing with itself, not two cells agreeing.
write_findings("oc-kimik3#2", [
    {"file": "z.py", "line": 10, "severity": "P2", "summary": "shared claim once more"},
])
# A model writes the line as a number or as text as it pleases, and sorting the two kinds
# against each other raises rather than misorders.
write_findings("opus-medium", [
    {"file": "z.py", "line": "10", "severity": "P1", "summary": "worst claim at the place"},
])
findings_text = "\n".join(rb.findings_lines(findings_dir))
assert findings_text.startswith("5 findings from 3 cells at 2 places"), findings_text
# The worst severity claimed at a place, and the summary of whoever claimed it: taking the
# first entry hands both to whichever cell's filename sorted first.
assert "P1 ×3 (4 claims)  z.py:10" in findings_text, findings_text
assert "worst claim at the place" in findings_text, findings_text
# The place several cells reached independently comes first, whatever its severity: that is
# where a real defect usually is, and reading in file order buries it.
place_order = [line for line in findings_text.splitlines() if line.startswith("P")]
# z.py sorts last by name, so file order and agreement order disagree here on purpose.
assert place_order[0].startswith(
    "P1 ×3 (4 claims)  z.py:10  oc-kimik3, opus-medium, sol-low"), place_order
assert place_order[1].startswith("P1 ×1  a.py:1  sol-low"), place_order
# Only one summary is printed per place, so a cell that made a second claim there would vanish
# without the count; a place where every cell spoke once carries no count to read past.
assert "×1 (" not in findings_text, findings_text
assert rb.findings_lines(work / "findings-empty-run") == ["no findings recorded"]
# Corroboration is cells, not rows: one cell making three claims about a line is still one cell,
# and ranking by rows puts it above a place two cells reached independently.
order_dir = work / "findings-order"
order_dir.mkdir()
(order_dir / "findings-sol-low.jsonl").write_text("".join(
    json.dumps({"file": "m.py", "line": 5, "severity": "P2", "summary": f"claim {index}"}) + "\n"
    for index in range(3)
))
for order_cell in ("oc-kimik3", "opus-medium"):
    (order_dir / f"findings-{order_cell}.jsonl").write_text(
        json.dumps({"file": "n.py", "line": 7, "severity": "P2", "summary": "two cells"}) + "\n"
    )
order_places = [line for line in rb.findings_lines(order_dir) if line.startswith("P")]
assert order_places[0].startswith("P2 ×2  n.py:7"), order_places
# The group key holds the line as text so the two spellings of one line merge; ordering that
# text as text reads line 10 as earlier than line 2.
line_order_dir = work / "findings-line-order"
line_order_dir.mkdir()
(line_order_dir / "findings-sol-low.jsonl").write_text("".join(
    json.dumps({"file": "f.py", "line": line, "severity": "P2", "summary": f"at {line}"}) + "\n"
    for line in (10, 2, "9", None)
))
line_places = [line for line in rb.findings_lines(line_order_dir) if line.startswith("P")]
assert [place.split("  ")[1] for place in line_places] == [
    "f.py:2", "f.py:9", "f.py:10", "f.py:None"], line_places
assert order_places[1].startswith("P2 ×1 (3 claims)  m.py:5"), order_places

# --- health: why recorded cells failed -------------------------------------------------------
for text, expected in (
    ("review-bench: this run has no opencode account left", "pool empty"),
    # A pool-empty message quotes the error of the last account it tried, so the specific
    # wording has to win over the cause it carries.
    ("has no codex account left\nGoUsageLimitError: limitName=plan", "pool empty"),
    ("GoUsageLimitError limitName=opencode-plan", "plan wall"),
    (rb.GATE_WALL_STDERR, "plan wall"),
    ("Error: You have exhausted your capacity on this model. Resets in 0s.", "plan wall"),
    ("API error (status 402 Payment Required): Grok Build usage balance exhausted", "plan wall"),
    ('HTTP 429\n{"code":"provider_rate_limit_exceeded"}', "throttled"),
    # The named cause wins; on its own the status code says only that something refused.
    ("HTTP 429", "bare 429"),
    ("rater produced no parseable finding and did not declare a clean review: prose",
     "unparseable"),
    # Both numbers are in use across the sides, so the rule is the stem, not either message.
    ("no parseable finding here", "unparseable"),
    ("opencode returned no parseable findings", "unparseable"),
    ("agy -skill returned malformed Markdown: expected /code-review findings", "unparseable"),
    ("opencode returned empty content (finish_reason='length')", "unparseable"),
    ("opencode stopped before reviewing", "unparseable"),
    ("the model is at capacity", "capacity"),
    ("gateway said 503", "server error"),
    ("cannot review the root commit", "root commit"),
    ('a tool required the "command" permission that headless runs cannot grant', "permission"),
    ("error: the argument '--commit <SHA>' cannot be used with '[PROMPT]'", "bad command"),
    ("ERROR codex_core::session: failed to record rollout items", "crashed"),
    ("You are not logged into Antigravity", "auth"),
    ("", "no output"),
    ("   \n ", "no output"),
    ("something nobody has seen before", "unclassified"),
):
    assert rb.failure_reason(text) == expected, (text, rb.failure_reason(text))
# A status the report already assigns is not re-derived from the text behind it.
assert rb.cell_failure_reason({"status": "timed_out", "stderr": "HTTP 429"}) == "timeout"
assert rb.cell_failure_reason({"status": "model_mismatch", "stderr": ""}) == "mismatch"
assert rb.cell_failure_reason({"status": "not_run", "stderr": ""}) == "not run"
assert rb.cell_failure_reason({"status": "errored", "stderr": "HTTP 429"}) == "bare 429"
health_dir = work / "health-runs"
health_dir.mkdir()


def write_health_run(name, rows, raters=None):
    directory = health_dir / name
    directory.mkdir()
    meta = {"rater_runs": rows, "raters": raters if raters is not None else
            [row["rater"] for row in rows]}
    (directory / "meta.json").write_text(json.dumps(meta))
    return directory


health_first = write_health_run("20260101T000000Z-aaa", [
    {"rater": "sol-low", "side": "codex", "account": "work", "exit_code": 0, "findings": 1},
    {"rater": "sol-high", "side": "codex", "account": "work", "exit_code": 1,
     "errored": True, "stderr": 'HTTP 429 {"code":"provider_rate_limit_exceeded"}'},
])
health_second = write_health_run("20260102T000000Z-bbb", [
    {"rater": "oc-kimik3", "side": "opencode", "account": "prod", "exit_code": 1,
     "errored": True, "stderr": rb.GATE_WALL_STDERR},
    {"rater": "oc-kimik3", "side": "opencode", "account": "alt", "exit_code": 0, "findings": 0},
])
(health_dir / "not-a-run").mkdir()
health_all = rb.health_runs(health_dir, 0)
assert [name for name, _ in health_all] == [
    "20260101T000000Z-aaa", "20260102T000000Z-bbb"
], health_all
assert [name for name, _ in rb.health_runs(health_dir, 1)] == ["20260102T000000Z-bbb"]
assert rb.health_runs(work / "no-such-benches", 0) == []
assert rb.run_health(health_first, json.loads(
    (health_first / "meta.json").read_text()))["by_side"]["codex"] == {"ok": 1, "throttled": 1}
# Column widths are cosmetic and would make these assertions break on any new run name.
health_text = "\n".join(" ".join(line.split()) for line in rb.health_lines(health_all))
assert "20260101T000000Z-aaa 1/2 50% throttled 1" in health_text, health_text
assert "all runs 2/4 50% throttled 1 · plan wall 1" in health_text, health_text
assert "codex work 1/2" in health_text, health_text
# Both accounts show even though one of them never failed: a pool that stopped rotating is
# read off this section, and an account that vanishes when it works cannot show that.
assert "opencode alt 0/1 · prod 1/1" in health_text, health_text
assert "Sol high 1/1 100% throttled 1" in health_text, health_text
# A cell that never failed has no place in a list of the worst ones.
assert "Sol low" not in health_text, health_text
assert rb.health_lines([]) == ["no recorded runs"]
# A cell retired since the run was recorded must not make the whole run unreadable.
retired_dir = write_health_run("20260103T000000Z-ccc", [
    {"rater": "oc-dsv4flash", "side": "opencode", "account": "prod", "exit_code": 0,
     "findings": 0},
])
retired_meta = json.loads((retired_dir / "meta.json").read_text())
assert rb.tier_from_meta(retired_meta) is None
retired_cells = rb.bench_summary(retired_dir, retired_meta)["cells"]
assert retired_cells[0]["status"] == "completed"
assert retired_cells[0]["side"] == "opencode" and retired_cells[0]["account"] == "prod"
# The side is recoverable from the spec for rows recorded before it was written down.
legacy_side_dir = write_health_run("20260104T000000Z-ddd", [
    {"rater": "sol-low", "exit_code": 0, "findings": 0},
])
legacy_side_meta = json.loads((legacy_side_dir / "meta.json").read_text())
assert rb.bench_summary(legacy_side_dir, legacy_side_meta)["cells"][0]["side"] == "codex"
assert rb.rater_side("oc-dsv4flash") is None and rb.rater_side("") is None

real_append_review_log = rb.append_review_log
real_review_log_event = rb.review_log_event
for target in ("append", "event"):
    if target == "append":
        rb.append_review_log = lambda event: (_ for _ in ()).throw(OSError("fixture append"))
    else:
        rb.review_log_event = lambda *args: (_ for _ in ()).throw(ValueError("fixture event"))
    warning = io.StringIO()
    with contextlib.redirect_stderr(warning):
        rb.log_review_event("run", max_tier_dir, max_tier_meta)
    assert "warning: could not write review log:" in warning.getvalue()
    rb.append_review_log = real_append_review_log
    rb.review_log_event = real_review_log_event
late_report = io.StringIO()
with contextlib.redirect_stdout(late_report):
    assert rb.report_late_review("sol-high", 150001, 50000)
    assert rb.report_late_review("sol-high", 120001, 1000)
assert late_report.getvalue().splitlines() == [
    "LATE: sol-high took 150.001s against a 50s median",
    "LATE: sol-high took 120.001s against a 1s median",
]
on_time_report = io.StringIO()
with contextlib.redirect_stdout(on_time_report):
    assert rb.report_late_review("sol-high", 150000, 50000) is None
    assert rb.report_late_review("sol-high", 120000, 1000) is None
assert on_time_report.getvalue() == ""
for invalid in (
    "sol-high x1", "sol-high x0", "sol-high x10", "sol-high xno",
    "sol-high X2", "sol-high  x2",
):
    try:
        rb.parse_raters(invalid)
    except ValueError as exc:
        assert "invalid rater" in str(exc), (invalid, exc)
    else:
        raise AssertionError(f"accepted invalid repeat suffix: {invalid}")
for duplicate in ("sol-high,sol-high", "sol-high x2,sol-high", "sol-high x2,sol-high x2"):
    try:
        rb.parse_raters(duplicate)
    except ValueError as exc:
        assert "duplicates" in str(exc), (duplicate, exc)
    else:
        raise AssertionError(f"accepted duplicate rater: {duplicate}")
expected_floor = [
    "oc-kimik3 x4", "oc-grok45-low x3", "agy-pro-high-skill",
    "agy-flash35-medium-skill x2", "agy-flash35-high-skill",
    "agy-flash36-medium-skill",
]
expected_floor_slow = [
    "oc-kimik3 x4", "oc-grok45-low x3", "agy-pro-high-skill",
    "agy-flash35-medium-skill x3", "agy-flash35-high-skill",
    "agy-flash36-medium-skill", "agy-pro-low-skill",
]
expected_tier_cells = {
    "T0": expected_floor + [
        "opus-low", "sol-low", "sol-low-bare",
    ],
    "T1": expected_floor_slow + [
        "opus-medium", "sol-low", "sol-low-bare", "sol-medium-bare",
    ],
    "T2": expected_floor_slow + [
        "opus-medium", "sol-high", "sol-high-bare x2", "sol-xhigh",
        "sol-xhigh-bare",
    ],
    "T3": expected_floor_slow + [
        "opus-medium", "sol-high", "sol-high-bare", "sol-max x2", "sol-max-bare",
        "sol-xhigh-bare",
    ],
}
expected_tier_max_cells = {
    "T0": expected_floor + [
        "opus-low", "sol-low", "sol-low-bare",
    ],
    "T1": expected_floor_slow + [
        "opus-low", "opus-medium", "sol-low", "sol-low-bare", "sol-medium-bare",
    ],
    "T2": expected_floor_slow + [
        "opus-high", "opus-medium", "sol-high", "sol-high-bare x2", "sol-xhigh",
        "sol-xhigh-bare",
    ],
    "T3": expected_floor_slow + [
        "opus-high", "opus-medium", "sol-high", "sol-max x2", "sol-max-bare",
        "sol-xhigh-bare", "sol-xhigh",
    ],
}
expected_coverage_pct = {
    "T0": {"eco": 29.7, "max": 29.7},
    "T1": {"eco": 40.3, "max": 41.4},
    "T2": {"eco": 56.3, "max": 59.7},
    "T3": {"eco": 67.6, "max": 70.5},
}
floor_counts = Counter({
    "oc-kimik3": 4, "oc-grok45-low": 3, "agy-flash35-high-skill": 1,
    "agy-flash35-medium-skill": 2, "agy-flash36-medium-skill": 1,
    "agy-pro-high-skill": 1,
})
slow_counts = Counter({
    "oc-kimik3": 4, "oc-grok45-low": 3, "agy-flash35-high-skill": 1,
    "agy-flash35-medium-skill": 3, "agy-flash36-medium-skill": 1,
    "agy-pro-high-skill": 1, "agy-pro-low-skill": 1,
})
expected_tier_multisets = {
    "T0": floor_counts + Counter({
        "opus-low": 1, "sol-low": 1, "sol-low-bare": 1,
    }),
    "T1": slow_counts + Counter({
        "opus-medium": 1, "sol-low": 1, "sol-low-bare": 1,
        "sol-medium-bare": 1,
    }),
    "T2": slow_counts + Counter({
        "opus-medium": 1, "sol-high": 1, "sol-high-bare": 2, "sol-xhigh": 1,
        "sol-xhigh-bare": 1,
    }),
    "T3": slow_counts + Counter({
        "opus-medium": 1, "sol-high": 1, "sol-high-bare": 1, "sol-max": 2,
        "sol-max-bare": 1, "sol-xhigh-bare": 1,
    }),
}
expected_tier_max_multisets = {
    "T0": floor_counts + Counter({
        "opus-low": 1, "sol-low": 1, "sol-low-bare": 1,
    }),
    "T1": slow_counts + Counter({
        "opus-low": 1, "opus-medium": 1, "sol-low": 1, "sol-low-bare": 1,
        "sol-medium-bare": 1,
    }),
    "T2": slow_counts + Counter({
        "opus-high": 1, "opus-medium": 1, "sol-high": 1, "sol-high-bare": 2,
        "sol-xhigh": 1, "sol-xhigh-bare": 1,
    }),
    "T3": slow_counts + Counter({
        "opus-high": 1, "opus-medium": 1, "sol-high": 1, "sol-max": 2,
        "sol-max-bare": 1, "sol-xhigh-bare": 1, "sol-xhigh": 1,
    }),
}
assert rb.REVIEW_TIER_FLOOR == expected_floor
assert rb.REVIEW_TIER_FLOOR_SLOW == expected_floor_slow
assert list(rb.REVIEW_TIERS) == ["T0", "T1", "T2", "T3"]
assert [tier["budget_min"] for tier in rb.REVIEW_TIERS.values()] == [2, 6, 10, 20]
assert {
    tier_name: tier["cells"] for tier_name, tier in rb.REVIEW_TIERS.items()
} == expected_tier_cells
assert {
    tier_name: tier["cells_max"] for tier_name, tier in rb.REVIEW_TIERS.items()
} == expected_tier_max_cells
assert {
    tier_name: tier["coverage_pct"] for tier_name, tier in rb.REVIEW_TIERS.items()
} == expected_coverage_pct
assert all(
    set(tier["coverage_pct"]) == {"eco", "max"}
    for tier in rb.REVIEW_TIERS.values()
)
expanded_floor = Counter(
    rb.normalize_legacy_rater(rater["spec"])
    for rater in rb.parse_raters(",".join(expected_floor))
)
for composition, expected_cells, expected_multisets in (
    ("cells", expected_tier_cells, expected_tier_multisets),
    ("cells_max", expected_tier_max_cells, expected_tier_max_multisets),
):
    for tier_name, tier in rb.REVIEW_TIERS.items():
        prefix = tier[composition][:len(expected_floor)]
        assert [
            rb.parse_raters(cell)[0]["spec"] for cell in prefix
        ] == [
            rb.parse_raters(cell)[0]["spec"] for cell in expected_floor
        ], (tier_name, composition, prefix)
        expanded = Counter(
            rb.normalize_legacy_rater(rater["spec"])
            for rater in rb.parse_raters(",".join(tier[composition]))
        )
        assert expanded_floor <= expanded, (tier_name, composition, expanded_floor, expanded)
        assert expanded == expected_multisets[tier_name], (tier_name, composition, expanded)
rb.REVIEW_TIERS["TX"] = {
    "budget_min": 1, "when": "fixture", "cells": ["sol-medium x2"],
    "cells_max": ["sol-medium x2"],
}
try:
    rb.validate_review_tiers()
    for tier in rb.REVIEW_TIERS.values():
        assert tier["when"]
        for composition in ("cells", "cells_max"):
            for cell in tier[composition]:
                expanded = rb.parse_raters(cell)
                assert rb.collapse_rater_attempts(
                    rater["spec"] for rater in expanded
                ) == [cell], (composition, cell, expanded)
finally:
    del rb.REVIEW_TIERS["TX"]
print("rater-repeat-parse-tier-ok")
# Every resolved rater set passes this gate, so no --raters spelling and no --auto pick can run
# a skill-less agy cell; parsing one still works, or a stored bench run could never be recorded.
for bare in ("agy-pro-low", "agy-flash36-medium", "agy-flash35-high"):
    assert rb.parse_rater(bare)["skill"] is False
    try:
        rb.refuse_retired_cells([rb.parse_rater(bare)])
    except RuntimeError as exc:
        assert f"{bare}-skill" in str(exc), exc
    else:
        raise AssertionError(f"accepted a skill-less agy rater: {bare}")
# The corpus has already answered some cells, so asking for one is refused with the count that
# answered it — the prose anti-list, enforced instead of described.
# --auto must never offer a cell the run then refuses, so the whole list has to survive the gate
# as it stands: filtering it here first would assert nothing.
rb.refuse_retired_cells([rb.parse_rater(spec) for spec in rb.AUTO_RATERS])
assert "haiku-medium" not in rb.AUTO_RATERS and "haiku-max" not in rb.AUTO_RATERS
assert "agy-flash36-low-skill" not in rb.AUTO_RATERS
assert "agy-flash35-low-skill" not in rb.AUTO_RATERS
assert all(
    "agy-flash35-low-skill" not in {
        rb.rater_family(rater["spec"])
        for cell in tier[composition]
        for rater in rb.parse_raters(cell)
    }
    for tier in rb.REVIEW_TIERS.values()
    for composition in ("cells", "cells_max")
)
try:
    rb.refuse_retired_cells([rb.parse_rater("agy-flash35-low-skill")])
except RuntimeError as exc:
    assert rb.EXCLUDED_CELLS["agy-flash35-low-skill"] in str(exc), exc
else:
    raise AssertionError("accepted an explicitly excluded cell")
rb.WORTHLESS_CELLS["agy-flash35-low-skill"] = "fixture measurement reason"
try:
    rb.refuse_retired_cells([rb.parse_rater("agy-flash35-low-skill")])
except RuntimeError as exc:
    assert rb.EXCLUDED_CELLS["agy-flash35-low-skill"] in str(exc), exc
    assert "fixture measurement reason" not in str(exc), exc
else:
    raise AssertionError("measurement reason overrode an explicit exclusion")
finally:
    del rb.WORTHLESS_CELLS["agy-flash35-low-skill"]
assert [spec for spec in rb.AUTO_RATERS if spec.endswith("-bare")] == [
    "sol-low-bare", "sol-medium-bare", "sol-high-bare", "sol-xhigh-bare", "sol-max-bare",
]
for bare_sonnet in ("sonnet-low", "sonnet-medium", "sonnet-high", "sonnet-xhigh"):
    assert bare_sonnet not in rb.AUTO_RATERS, bare_sonnet
    try:
        rb.refuse_retired_cells([rb.parse_rater(bare_sonnet)])
    except RuntimeError as exc:
        assert f"{bare_sonnet}-skill" in str(exc), exc
    else:
        raise AssertionError(f"accepted a bare sonnet rater: {bare_sonnet}")
rb.refuse_retired_cells([rb.parse_rater(spec) for spec in ("opus-medium", "opus-high")])
standalone_grok_reason = (
    "the standalone grok account is disconnected; grok reviews run as OpenCode cells "
    "(oc-grok45-*); the plumbing stays for a future account"
)
try:
    rb.refuse_retired_cells([rb.parse_rater("grok-low")])
except RuntimeError as exc:
    assert str(exc) == standalone_grok_reason, exc
else:
    raise AssertionError("accepted a standalone grok rater")
rb.refuse_retired_cells([rb.parse_rater("oc-grok45-low")])
standalone_grok = subprocess.run(
    [sys.argv[1], "run", "HEAD", "--repo", str(repo), "--raters", "grok-low"],
    text=True,
    capture_output=True,
)
assert standalone_grok.returncode != 0, standalone_grok
assert standalone_grok_reason in standalone_grok.stderr, standalone_grok.stderr
# The cheapest way to run a refused model would be to ask for it as the verifier.
for dead_verifier in ("oc-glm52", "oc-kimik27code"):
    try:
        rb.verifier_model(dead_verifier)
    except RuntimeError as exc:
        assert dead_verifier in str(exc), exc
    else:
        raise AssertionError(f"accepted a retired verifier: {dead_verifier}")
assert rb.verifier_model(rb.OPENCODE_VERIFIER) == rb.OPENCODE_VERIFIER
for dead, needle in (
    ("haiku-medium", "0 defects"),
    ("oc-glm52", "3 true"),
    ("oc-grok45-medium", "one-line announce"),
    ("agy-flash36-low-skill", "0 true"),
):
    try:
        rb.refuse_retired_cells([rb.parse_rater(dead)])
    except RuntimeError as exc:
        assert dead in str(exc) and needle in str(exc), exc
    else:
        raise AssertionError(f"accepted a cell the corpus retired: {dead}")
retired_grok = subprocess.run(
    [
        sys.argv[1], "run", "HEAD", "--repo", str(repo),
        "--raters", "oc-grok45-medium",
    ],
    text=True,
    capture_output=True,
)
retired_grok_reason = (
    "answers with a one-line announce and stops (10-token completions, findings leak into "
    "reasoning_content); 0 parseable reviews in 3 runs on 2026-07-28"
)
assert retired_grok.returncode != 0, retired_grok
assert retired_grok_reason in retired_grok.stderr, retired_grok.stderr
assert rb.parse_rater("oc-glm52") == {
    "spec": "oc-glm52", "model": "oc-glm52", "effort": None,
    "side": "opencode", "skill": False, "bare": False, "profile": None
}
assert rb.parse_rater("oc-glm52-low")["effort"] == "low"
assert rb.parse_rater("oc-dsv4pro-high") == {
    "spec": "oc-dsv4pro-high", "model": "oc-dsv4pro", "effort": "high",
    "side": "opencode", "skill": False, "bare": False, "profile": None
}
assert rb.parse_rater("oc-grok45-low") == {
    "spec": "oc-grok45-low", "model": "oc-grok45", "effort": "low",
    "side": "opencode", "skill": False, "bare": False, "profile": None
}
assert rb.OPENCODE_MODEL_IDS["oc-grok45"] == "grok-4.5"
# The capability table is the module's own knowledge of a gateway whose models behave
# differently, so a new model cannot be offered before it is measured.
assert set(rb.OPENCODE_MODEL_FACTS) == set(rb.OPENCODE_MODEL_IDS), (
    set(rb.OPENCODE_MODEL_IDS) ^ set(rb.OPENCODE_MODEL_FACTS)
)
for cell, facts in rb.OPENCODE_MODEL_FACTS.items():
    assert set(facts) == {"off", "scales", "off_s", "low_s", "note"}, (cell, facts)
    assert isinstance(facts["off"], bool) and isinstance(facts["scales"], bool), cell
    assert facts["note"], cell
    for field in ("off_s", "low_s"):
        assert facts[field] is None or facts[field] > 0, (cell, field)
# Policy has to follow the measurement: a cell is only forced to carry a budget when
# the knob is ignored, and only refused when nothing ever worked.
assert rb.OPENCODE_EFFORT_REQUIRED_MODELS <= {
    cell for cell, facts in rb.OPENCODE_MODEL_FACTS.items() if not facts["off"]
}
assert rb.OPENCODE_UNUSABLE_MODELS <= {
    cell for cell, facts in rb.OPENCODE_MODEL_FACTS.items()
    if facts["off_s"] is None and facts["low_s"] is None
}
assert set(rb.OPENCODE_EFFORT_CEILING) <= set(rb.OPENCODE_MODEL_FACTS)
# --leg has to expand to the recorded composition, or the measurement lives only in a
# help string and every caller retypes it from memory.
assert rb.parse_raters(",".join(rb.OPENCODE_REVIEW_LEG)) == [
    rb.parse_rater(spec) for spec in rb.OPENCODE_REVIEW_LEG
]
assert not set(rb.OPENCODE_SCREENED_MODELS) & set(rb.OPENCODE_MODEL_IDS.values()), (
    "a screened model with a cell belongs in the facts table, not the screening list"
)
assert all(
    rb.parse_rater(spec)["side"] == "opencode" for spec in rb.OPENCODE_REVIEW_LEG
), rb.OPENCODE_REVIEW_LEG
assert rb.OPENCODE_VERIFIER in rb.OPENCODE_MODEL_IDS
# An effort a model never completed a review at must be refused, not merely priced:
# the cell would spend the subscription window and return nothing.
for cell, ceiling in rb.OPENCODE_EFFORT_CEILING.items():
    refused = [
        effort for effort in rb.OPENCODE_EFFORTS
        if ceiling is None or rb.OPENCODE_EFFORTS.index(effort) > rb.OPENCODE_EFFORTS.index(ceiling)
    ]
    assert refused, cell
    for effort in refused:
        try:
            rb.parse_rater(f"{cell}-{effort}")
        except ValueError as exc:
            assert "never finished a review" in str(exc), exc
        else:
            raise AssertionError(f"{cell}-{effort} never completed and must be refused")
    if ceiling:
        assert rb.parse_rater(f"{cell}-{ceiling}")["effort"] == ceiling
for unusable in sorted(rb.OPENCODE_UNUSABLE_MODELS):
    for spec in (unusable, f"{unusable}-low"):
        try:
            rb.parse_rater(spec)
        except ValueError as exc:
            assert "measured unusable" in str(exc), exc
        else:
            raise AssertionError(f"{spec} is measured unusable and must be refused")
# The expected cost has to come from the table, not a second copy of it.
assert rb.opencode_expected_s(rb.parse_rater("oc-glm52")) == \
    rb.OPENCODE_MODEL_FACTS["oc-glm52"]["off_s"]
assert rb.opencode_expected_s(rb.parse_rater("oc-glm52-low")) == \
    rb.OPENCODE_MODEL_FACTS["oc-glm52"]["low_s"]
assert rb.opencode_expected_s(rb.parse_rater("oc-hy3-high")) == rb.OPENCODE_EFFORT_EXPECTED_S
# A model that ignores every reasoning-off knob only stalls the gateway when it is
# asked for a review with no budget, so the effortless spec is refused outright.
for locked in sorted(rb.OPENCODE_EFFORT_REQUIRED_MODELS):
    try:
        rb.parse_rater(locked)
    except ValueError as exc:
        assert f"{locked}-low" in str(exc), exc
    else:
        raise AssertionError(f"{locked} without an effort must be rejected")
    assert rb.parse_rater(f"{locked}-low")["effort"] == "low"
# The low-budget cell of a reasoning-locked model is cheap, so it must not be
# ordered as if every effort cell were slow.
assert rb.opencode_expected_s(rb.parse_rater("oc-grok45-low")) < rb.OPENCODE_EFFORT_EXPECTED_S
assert rb.opencode_expected_s(rb.parse_rater("oc-grok45-high")) == rb.OPENCODE_EFFORT_EXPECTED_S
assert rb.parse_rater("oc-glm52-google") == {
    "spec": "oc-glm52-google", "model": "oc-glm52", "effort": None,
    "side": "opencode", "skill": False, "bare": False, "profile": "google"
}
assert rb.parse_rater("oc-glm52-high-anthropic")["profile"] == "anthropic"
for invalid in ("opus-low-google", "agy-pro-low-anthropic", "sol-medium-google"):
    try:
        rb.parse_rater(invalid)
    except ValueError as exc:
        assert "OpenCode-only" in str(exc)
    else:
        raise AssertionError(f"accepted non-OpenCode review profile: {invalid}")
profile_dir = work / "profiles"
profile_dir.mkdir()
(profile_dir / "google.md").write_text("GOOGLE METHODOLOGY BODY\n")
(profile_dir / "anthropic.md").write_text("")
os.environ["REVIEW_BENCH_PROFILE_DIR"] = str(profile_dir)
profiled = rb.review_prompt("deadbee", "", "google")
assert "GOOGLE METHODOLOGY BODY" in profiled
assert "score 80 or higher" in profiled and "one JSON object per line" in profiled
assert "GOOGLE" not in rb.review_prompt("deadbee", "")
for broken, reason in (("anthropic", "is empty"), ("missing", "unreadable")):
    try:
        rb.review_prompt("deadbee", "", broken)
    except (RuntimeError, KeyError) as exc:
        assert reason in str(exc) or isinstance(exc, KeyError)
    else:
        raise AssertionError(f"review profile {broken} did not fail closed")
del os.environ["REVIEW_BENCH_PROFILE_DIR"]
for effort in ("low", "medium", "high"):
    rater = rb.parse_rater(f"agy-flash35-{effort}-skill")
    assert rater == {
        "spec": f"agy-flash35-{effort}-skill",
        "model": "agy-flash35",
        "effort": effort,
        "side": "agy",
        "skill": True,
        "bare": False,
        "profile": None,
    }
for invalid in ("gpt-medium", "sol", "opus-ultra", "sol-mega", "",
                "sol-medium-skill", "opus-skill", "opus-medium-turbo",
                "oc-glm52-xhigh", "oc-glm52-high-skill",
                "opus-low-bare", "oc-kimik3-bare"):
    try:
        rb.parse_rater(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError(f"accepted invalid rater: {invalid}")
for invalid, message in (
    ("agy-pro-medium-skill", "agy-pro supports only low or high effort"),
    ("agy-flash36-xhigh-skill", "agy-flash36 supports only low, medium, or high effort"),
    ("agy-flash35-xhigh-skill", "agy-flash35 supports only low, medium, or high effort"),
):
    try:
        rb.parse_rater(invalid)
    except ValueError as exc:
        assert message in str(exc)
    else:
        raise AssertionError(f"accepted invalid rater: {invalid}")

pick = rb.parse_affordability("""NEXT: claudeb worker · opus · high — ACCOUNT: worker; pre-reset cap 22%  |  codex cx · medium — FRESH
codex: cx 10% runway 80%
gemini: main 25% runway 75% (5h→?, wk→?)
claude: worker($100) 5h 10% wk 20% fb 30% score 90 cap 22% | session($100)* 5h 0% wk 0% fb 0% score 100 cap 90% | low($20) 5h 85% wk 20% fb 20% score 10 cap 5%
""")
assert pick["codex"] is True
assert pick["agy"] is True
assert pick["opencode"] is True
assert pick["claude"] is True
assert pick["claude_account"] == "worker"
assert pick["session_account"] == "session"
assert "accounts" not in pick

# The session account has the best score and the most headroom in that fixture and is still
# refused, because a bench must not quietly spend the quota the user is talking to. The
# override exists for a measurement the user asked to run there, and only then.
session_pick_text = """NEXT: claudeb (rotating) — no eligible account
codex: unavailable
gemini: login needed
claude: session($100)* 5h 0% wk 8% fb 0% score 100 cap 82%
"""
assert rb.parse_affordability(session_pick_text)["claude"] is False
os.environ["REVIEW_BENCH_ALLOW_SESSION_ACCOUNT"] = "1"
allowed = rb.parse_affordability(session_pick_text)
assert allowed["claude"] is True
assert allowed["claude_account"] == "session"
os.environ["REVIEW_BENCH_ALLOW_SESSION_ACCOUNT"] = "0"
assert rb.parse_affordability(session_pick_text)["claude"] is False
del os.environ["REVIEW_BENCH_ALLOW_SESSION_ACCOUNT"]

# The permission to use the session account is not a permission to ignore the floor: when the
# parse says the side is unaffordable, no account may be handed out on its strength.
floored_pick = work / "floored-worker-pick.sh"
floored_pick.write_text(
    "#!/bin/sh\n"
    'if [ "$1" = "--account" ]; then echo stub-pool; exit 0; fi\n'
    "cat <<'OUT'\n"
    "NEXT: claudeb (rotating) — ALL FLOORED\n"
    "codex: unavailable\n"
    "gemini: login needed\n"
    "claude: session($100)* 5h 0% wk 8% fb 0% score 85 cap 82%\n"
    "OUT\n"
)
floored_pick.chmod(0o755)
previous_pick = os.environ.get("REVIEW_BENCH_WORKER_PICK_BIN")
os.environ["REVIEW_BENCH_WORKER_PICK_BIN"] = str(floored_pick)
os.environ["REVIEW_BENCH_ALLOW_SESSION_ACCOUNT"] = "1"
rb._PERMITTED_CLAUDE.clear()
assert rb.permitted_claude_account() is None
# Read once per process: a rater retrying after a wall must not re-run the pool for an answer
# the run already has.
assert rb.permitted_claude_account() is None
assert rb._PERMITTED_CLAUDE == [None], rb._PERMITTED_CLAUDE
# With the side unaffordable the decision falls back to the pool, which owns selection.
assert rb.pool_account("claude", set()) == "stub-pool"
rb._PERMITTED_CLAUDE.clear()
del os.environ["REVIEW_BENCH_ALLOW_SESSION_ACCOUNT"]
if previous_pick is None:
    del os.environ["REVIEW_BENCH_WORKER_PICK_BIN"]
else:
    os.environ["REVIEW_BENCH_WORKER_PICK_BIN"] = previous_pick

# `agy` is the internal side name while worker-pick and the user say `gemini`; both spellings
# have to reach the same exclusion or a reasonable one fails in silence.
os.environ["REVIEW_BENCH_EXCLUDE_GEMINI"] = "work"
assert rb.baseline_exclusions("agy") == {"work"}
os.environ["REVIEW_BENCH_EXCLUDE_AGY"] = "main"
assert rb.baseline_exclusions("agy") == {"main", "work"}
del os.environ["REVIEW_BENCH_EXCLUDE_GEMINI"], os.environ["REVIEW_BENCH_EXCLUDE_AGY"]
assert rb.baseline_exclusions("agy") == set()

mixed_next = rb.parse_affordability("""NEXT: gemini main · pro · high — ACCOUNT: main; pre-reset cap 9% — WALLED  |  codex cx · medium — FRESH
codex: cx 10% runway 80%
gemini: main 91% runway 9% FLOOR (5h→?, wk→?)
claude: unavailable
""")
assert mixed_next["codex"] is True
assert mixed_next["agy"] is False
login_needed = rb.parse_affordability("""NEXT: claudeb (rotating) — no eligible account  |  gemini unavailable
codex: unavailable
gemini: login needed
claude: unavailable
""")
assert login_needed["agy"] is False

assert rb.is_429_error('{"is_error": true, "api_error_status": 429}') is True
assert rb.is_429_error('{"is_error": false, "errors": ["hit your session limit"]}') is True
assert rb.is_429_error('{"is_error": false, "api_error_status": 200}') is False
assert rb.is_429_error('hit your session limit in the middle of text') is False

reviews = []
for rater in rb.AUTO_RATERS:
    model, effort = rater.split("-", 1)
    count = 3
    if rater == "sol-medium":
        count = 0
    elif rater == "opus-medium":
        count = 1
    for index in range(count):
        reviews.append({"run_id": f"{rater}-{index}", "rater_model": model,
                        "rater_effort": effort})
availability = {"codex": True, "claude": True, "agy": True}
picked, counts, skipped = rb.auto_pick(2, reviews, availability)
assert [row["spec"] for row in picked] == ["sol-medium", "opus-medium"]
assert [counts[row["spec"]] for row in picked] == [0, 1]
assert not skipped

availability["claude"] = False
availability["agy"] = False
picked, counts, skipped = rb.auto_pick(2, reviews, availability)
assert all(row["side"] == "codex" for row in picked)
assert any(spec.startswith("opus-") for spec, _ in skipped)
assert any(spec.startswith("agy-") for spec, _ in skipped)

agy_gap_reviews = [
    {"rater": spec}
    for spec in rb.AUTO_RATERS
    if spec != "agy-flash35-high-skill"
]
picked, _, _ = rb.auto_pick(
    1, agy_gap_reviews, {"codex": True, "claude": True, "agy": True}
)
assert picked[0]["spec"] == "agy-flash35-high-skill"

codex_stream = "\n".join([
    json.dumps({"type": "thread.started", "thread_id": "t"}),
    json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text":
        "- [P1] Reject empty tokens — `src/auth.py:41-43`"}}),
])
codex = rb.normalize_findings(codex_stream, "sol-medium")
assert [(row["severity"], row["file"], row["line"]) for row in codex] == [
    ("P1", "src/auth.py", 41)
]

claude_envelope = json.dumps({"type": "result", "result":
    '{"severity":"P3","file":"lib/task.py","line":17,"summary":"Handle cancellation"}\n'})
claude = rb.normalize_findings(claude_envelope, "opus-medium")
assert claude == [{"severity": "P3", "file": "lib/task.py", "line": 17,
                   "summary": "Handle cancellation", "rater": "opus-medium"}]


agy_skill = rb.normalize_agy_skill_output(
    (fixtures / "agy-skill-output.md").read_text(), "agy-flash36-low-skill"
)
skill_rows = rb.normalize_findings(agy_skill, "agy-flash36-low-skill")
assert [(row["severity"], row["file"], row["line"]) for row in skill_rows] == [
    ("P1", "src/auth.py", 41),
    ("P3", "src/cache.py", 18),
]
assert "anonymous request" in skill_rows[0]["summary"]
agy_skill_clean = rb.normalize_agy_skill_output(
    (fixtures / "agy-skill-clean.md").read_text(), "agy-flash36-low-skill"
)
assert rb.normalize_findings(agy_skill_clean, "agy-flash36-low-skill") == []
agy_empty_comments_answer = (fixtures / "agy-skill-empty-comments.md").read_text()
agy_empty_comments = rb.normalize_agy_skill_output(
    agy_empty_comments_answer, "agy-pro-high-skill"
)
assert rb.clean_review_declared(agy_empty_comments)
assert rb.normalize_findings(agy_empty_comments, "agy-pro-high-skill") == []
try:
    rb.normalize_agy_skill_output(
        agy_empty_comments_answer + "\nHowever, the change drops failed requests.",
        "agy-pro-high-skill",
    )
except ValueError as exc:
    assert "malformed Markdown" in str(exc)
else:
    raise AssertionError("accepted empty comments followed by defect prose as a clean review")
agy_linked_finding = rb.normalize_agy_skill_output(
    (fixtures / "agy-skill-linked-finding.md").read_text(),
    "agy-flash35-high-skill",
)
linked_rows = rb.normalize_findings(agy_linked_finding, "agy-flash35-high-skill")
assert len(linked_rows) == 1
assert linked_rows[0]["severity"] == "P2"
assert linked_rows[0]["line"] == 66
assert "/bin/statusline-ports-probe.sh" in linked_rows[0]["file"]
assert linked_rows[0]["summary"].startswith("Fallible PID parsing for numeric command names.")
try:
    rb.normalize_agy_skill_output(
        (fixtures / "agy-skill-no-repo.md").read_text(), "agy-flash36-low-skill"
    )
except ValueError as exc:
    assert "did not enter the sealed git repository" in str(exc)
else:
    raise AssertionError("accepted an agy -skill response produced outside the repository")

sha = subprocess.run(
    ["git", "-C", str(repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True
).stdout.strip()
parent = subprocess.run(
    ["git", "-C", str(repo), "rev-parse", "HEAD^"],
    check=True, capture_output=True, text=True
).stdout.strip()
sealed_parent = pathlib.Path(rb.seal_overlay_clone(repo, parent))
try:
    assert subprocess.run(
        ["git", "-C", str(sealed_parent), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True
    ).stdout.strip() == parent
    assert sha not in subprocess.run(
        ["git", "-C", str(sealed_parent), "rev-list", "--all"],
        check=True, capture_output=True, text=True
    ).stdout.splitlines()
    assert subprocess.run(
        ["git", "-C", str(sealed_parent), "cat-file", "-e", f"{sha}^{{commit}}"],
        capture_output=True, text=True
    ).returncode != 0
finally:
    rb.shutil.rmtree(sealed_parent, ignore_errors=True)
os.environ.update({
    "REVIEW_BENCH_GEMINIB_BIN": str(fixtures / "fake-geminib.sh"),
    "GEMINIB_CAPTURE_PROFILE": str(work / "geminib-profile"),
    "AGY_FIXTURE_LOG": str(fixtures / "agy-log.txt"),
    "AGY_CAPTURE_PROMPT": str(work / "agy-prompt"),
    "AGY_CAPTURE_CWD": str(work / "agy-cwd"),
    "AGY_CAPTURE_HEAD": str(work / "agy-head"),
    "AGY_CAPTURE_ORIGIN_HEAD": str(work / "agy-origin-head"),
})

transport_run = work / "agy-transport-run"
transport_run.mkdir()
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-skill-output.md")
transport_rater = rb.parse_rater("agy-flash36-low-skill")
rc, duration, text, stderr, command = rb.run_agy(
    transport_rater, repo, sha, "", transport_run, "ignored fixture diff", "work"
)
assert rc == 0 and duration >= 0 and not stderr
assert len(rb.normalize_findings(text, transport_rater["spec"])) == 2
assert (work / "agy-head").read_text().strip() == sha
assert pathlib.Path((work / "agy-cwd").read_text().strip()) != repo
assert (work / "agy-prompt").read_text() == "/code-review"
assert command[:13] == [
    str(fixtures / "fake-geminib.sh"), "profile", "work",
    "--model", "gemini-3.6-flash",
    "--effort", "low",
    "--mode", "plan",
    "--new-project", "--dangerously-skip-permissions",
    "--print-timeout", "10m",
]
assert (work / "geminib-profile").read_text() == "work"
assert command[13] == "--log-file"
assert pathlib.Path(command[14]) == transport_run / "agy-agy-flash36-low-skill.log"
assert command[15:] == ["--print", "/code-review"]
usage = json.loads((transport_run / "usage-agy-flash36-low-skill.jsonl").read_text())
assert usage["model"] == "gemini-3.6-flash"
assert usage["duration_ms"] == duration
assert usage["prompt_tokens"] == 120
assert usage["output_tokens"] == 30
assert usage["total_tokens"] == 150
assert usage["stream_generate_requests"] == 1
assert usage["stream_completions"] == 1

adaptive_run = work / "agy-adaptive-run"
adaptive_run.mkdir()
adaptive_rater = dict(transport_rater, timeout_s=383)
real_subprocess_run = rb.subprocess.run
agy_subprocess_timeouts = []


def capture_agy_timeout(command, *args, **kwargs):
    if command and command[0] == str(fixtures / "fake-geminib.sh"):
        agy_subprocess_timeouts.append(kwargs.get("timeout"))
    return real_subprocess_run(command, *args, **kwargs)


rb.subprocess.run = capture_agy_timeout
try:
    rc, _, _, stderr, adaptive_command = rb.run_agy(
        adaptive_rater, repo, sha, "", adaptive_run, "ignored fixture diff", "work"
    )
finally:
    rb.subprocess.run = real_subprocess_run
assert rc == 0 and not stderr
assert adaptive_command[adaptive_command.index("--print-timeout") + 1] == "383s"
assert agy_subprocess_timeouts == [413], agy_subprocess_timeouts

usage_run = work / "agy-usage-run"
usage_run.mkdir()
repeated_log = (fixtures / "agy-log.txt").read_text() + """
I0724 01:11:42.000000 usage.go:10] promptTokenCount=100 candidatesTokenCount=20 totalTokenCount=120
I0724 01:11:43.000000 usage.go:10] promptTokenCount=240 candidatesTokenCount=60 totalTokenCount=300 cachedContentTokenCount=40 thoughtsTokenCount=25
"""
rb.write_agy_usage(usage_run, transport_rater, 12, repeated_log)
repeated_usage = json.loads(
    (usage_run / "usage-agy-flash36-low-skill.jsonl").read_text()
)
assert repeated_usage["prompt_tokens"] == 240
assert repeated_usage["output_tokens"] == 60
assert repeated_usage["total_tokens"] == 300
assert repeated_usage["cached_tokens"] == 40
assert repeated_usage["reasoning_tokens"] == 25

malformed_run = work / "agy-malformed-run"
malformed_run.mkdir()
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-skill-malformed.txt")
rc, _, text, stderr, _ = rb.run_agy(
    transport_rater, repo, sha, "", malformed_run, "ignored fixture diff", "work"
)
assert rc == 1 and not text
assert "agy -skill returned malformed Markdown" in stderr

denied_run = work / "agy-denied-run"
denied_run.mkdir()
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-empty.txt")
os.environ["AGY_FIXTURE_STDERR"] = str(fixtures / "agy-headless-denied.txt")
skill_rater = rb.parse_rater("agy-flash36-low-skill")
rc, _, text, stderr, denied_command = rb.run_agy(
    skill_rater, repo, sha, "", denied_run, "ignored fixture diff", "work"
)
assert rc == 1 and not text
assert "agy returned empty output" in stderr
assert "headless mode cannot prompt" in stderr
assert "--mode" in denied_command and "plan" in denied_command
assert "--sandbox" not in denied_command
assert "--new-project" in denied_command
assert "--dangerously-skip-permissions" in denied_command
del os.environ["AGY_FIXTURE_STDERR"]

no_repo_run = work / "agy-no-repo-run"
no_repo_run.mkdir()
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-skill-no-repo.md")
rc, _, text, stderr, _ = rb.run_agy(
    skill_rater, repo, sha, "", no_repo_run, "ignored fixture diff", "work"
)
assert rc == 1 and not text
assert "did not enter the sealed git repository" in stderr

skill_run = work / "agy-skill-run"
skill_run.mkdir()
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-skill-output.md")
rc, _, text, stderr, skill_command = rb.run_agy(
    skill_rater, repo, sha, "Check cancellation handling",
    skill_run, "ignored fixture diff", "work"
)
assert rc == 0 and not stderr
assert len(rb.normalize_findings(text, skill_rater["spec"])) == 2
assert (work / "agy-prompt").read_text() == \
    "/code-review\nAdditional review focus: Check cancellation handling"
assert (work / "agy-origin-head").read_text().strip() == parent
assert skill_command[:9] == [
    str(fixtures / "fake-geminib.sh"), "profile", "work",
    "--model", "gemini-3.6-flash",
    "--effort", "low",
    "--mode", "plan",
]
assert "--sandbox" not in skill_command
assert "--new-project" in skill_command
assert "--dangerously-skip-permissions" in skill_command

flash35_skill_run = work / "agy-flash35-skill-run"
flash35_skill_run.mkdir()
flash35_skill_rater = rb.parse_rater("agy-flash35-high-skill")
rc, _, text, stderr, flash35_skill_command = rb.run_agy(
    flash35_skill_rater, repo, sha, "", flash35_skill_run, "ignored fixture diff", "work"
)
assert rc == 0 and not stderr
assert len(rb.normalize_findings(text, flash35_skill_rater["spec"])) == 2
assert flash35_skill_command[3:5] == ["--model", "gemini-3.5-flash-high"]
assert "--effort" not in flash35_skill_command
flash35_usage = json.loads(
    (flash35_skill_run / "usage-agy-flash35-high-skill.jsonl").read_text()
)
assert flash35_usage["model"] == "gemini-3.5-flash-high"
assert flash35_usage["effort"] == "high"
assert "--new-project" in flash35_skill_command
assert "--dangerously-skip-permissions" in flash35_skill_command

pro_skill_run = work / "agy-pro-skill-run"
pro_skill_run.mkdir()
pro_skill_rater = rb.parse_rater("agy-pro-high-skill")
rc, _, text, stderr, pro_skill_command = rb.run_agy(
    pro_skill_rater, repo, sha, "", pro_skill_run, "ignored fixture diff", "work"
)
assert rc == 0 and not stderr
assert pro_skill_command[3:5] == ["--model", "Gemini 3.1 Pro (High)"]
assert "--effort" not in pro_skill_command
pro_usage = json.loads((pro_skill_run / "usage-agy-pro-high-skill.jsonl").read_text())
assert pro_usage["resolved_model_label"] == "Gemini 3.1 Pro (High)"
assert "model_mismatch" not in pro_usage

substituted_run = work / "agy-substituted-run"
substituted_run.mkdir()
os.environ["AGY_FIXTURE_LABEL"] = "Gemini 3.6 Flash (High)"
rc, _, text, stderr, _ = rb.run_agy(
    pro_skill_rater, repo, sha, "", substituted_run, "ignored fixture diff", "work"
)
del os.environ["AGY_FIXTURE_LABEL"]
assert rc == 1 and not text
assert stderr == "agy served Gemini 3.6 Flash (High) instead of Gemini 3.1 Pro (High)"
substituted_usage = json.loads(
    (substituted_run / "usage-agy-pro-high-skill.jsonl").read_text()
)
assert substituted_usage["model_mismatch"] == ["Gemini 3.6 Flash (High)"]

os.environ["REVIEW_BENCH_WORKER_PICK_BIN"] = str(fixtures / "fake-worker-pick.sh")
os.environ["GEMINIB_EXHAUSTED_PROFILE"] = "work"
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-skill-output.md")
rotate_run = work / "agy-rotate-run"
rotate_run.mkdir()
(work / "geminib-profile").write_text("")
_, rotate_account, rotate_result = rb.run_rater_task(
    rb.parse_rater("agy-flash36-low-skill"), repo, sha, "", rotate_run, "ignored fixture diff"
)
assert rotate_account == "main", (rotate_account, rotate_result)
assert rotate_result[0] == 0, rotate_result
assert (work / "geminib-profile").read_text() == "workmain"
flash_bucket = rb.wall_bucket(rb.parse_rater("agy-flash36-low-skill"))
assert rb.is_walled("agy", "work", flash_bucket) and not rb.is_walled("agy", "main", flash_bucket)
# Gemini bills per model, so retiring flash on that account must leave its pro cell alone.
assert not rb.is_walled("agy", "work", rb.wall_bucket(rb.parse_rater("agy-pro-high-skill")))
clear_walls()

# The pool ranks accounts but cannot know how many cells are about to ask, so every cell taking
# its head puts a whole run's concurrency on one account while the rest of the roster idles.
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "a1 a2 a3"
rb._SIDE_ROSTER.clear()
assert rb.side_roster("agy", frozenset()) == ["a1", "a2", "a3"], rb.side_roster("agy", frozenset())
spread_picks = [rb.pool_account("agy", set(), slot) for slot in range(4)]
assert spread_picks == ["a1", "a2", "a3", "a1"], spread_picks
# Rotation is unchanged: a cell whose own slot is retired walks the rest of the roster.
rb.mark_walled("agy", "a1", "general")
assert rb.pool_account("agy", set(), 0) == "a2", rb.pool_account("agy", set(), 0)
assert rb.pool_account("agy", {"a2"}, 0) == "a3", rb.pool_account("agy", {"a2"}, 0)
assert rb.pool_account("agy", {"a2", "a3"}, 0) is None
clear_walls()
# The roster is enumerated once per process: a per-cell enumeration would spawn one worker-pick
# per account per cell for an answer the run already has.
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "b1 b2"
assert rb.pool_account("agy", set(), 0) == "a1", "roster re-enumerated mid-run"
rb._SIDE_ROSTER.clear()
assert rb.side_roster("agy", frozenset()) == ["b1", "b2"]
# Off, every cell gets the pool's head, which is what the measurement compares against.
# Saved rather than deleted: the caller may have set it, and a test that reads the ambient
# environment for a default it also asserts on passes or fails by accident.
spread_was = os.environ.get("REVIEW_BENCH_SPREAD_ACCOUNTS")
os.environ["REVIEW_BENCH_SPREAD_ACCOUNTS"] = "0"
flat_picks = [rb.pool_account("agy", set(), slot) for slot in range(3)]
assert flat_picks == ["b1", "b1", "b1"], flat_picks
if spread_was is None:
    del os.environ["REVIEW_BENCH_SPREAD_ACCOUNTS"]
else:
    os.environ["REVIEW_BENCH_SPREAD_ACCOUNTS"] = spread_was
rb._SIDE_ROSTER.clear()

# The cell's own bucket decides what counts as retired. Gemini walls per model, so a pro wall
# hides the account from a pro cell and must leave a flash cell its whole roster.
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "c1 c2"
rb._SIDE_ROSTER.clear()
bucket_pro = rb.wall_bucket(rb.parse_rater("agy-pro-high-skill"))
bucket_flash = rb.wall_bucket(rb.parse_rater("agy-flash36-low-skill"))
rb.mark_walled("agy", "c1", bucket_pro)
assert rb.pool_account("agy", set(), 0, bucket_pro) == "c2", rb.pool_account("agy", set(), 0, bucket_pro)
assert rb.pool_account("agy", set(), 0, bucket_flash) == "c1"
# The cell must ask for its own bucket, not settle for the loop noticing afterwards: rotation
# reaches the same account either way, so the pre-filter working is visible only as the pool
# being asked once instead of twice.
bucket_asks = []
real_pool_account = rb.pool_account


def counting_pool_account(side, excluded, slot=0, bucket="general"):
    bucket_asks.append(bucket)
    return real_pool_account(side, excluded, slot, bucket)


rb.pool_account = counting_pool_account
bucket_run = work / "agy-bucket-run"
bucket_run.mkdir()
try:
    _, bucket_account, _ = rb.run_rater_task(
        rb.parse_rater("agy-pro-high-skill"), repo, sha, "", bucket_run, "ignored fixture diff"
    )
finally:
    rb.pool_account = real_pool_account
assert bucket_account == "c2", bucket_account
assert bucket_asks == [bucket_pro], bucket_asks
clear_walls()

# An empty answer is the pool's momentary state, not a fact about the run: cached, it would
# turn one bad instant into a side that has nothing to offer for the rest of the process.
rb._SIDE_ROSTER.clear()
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "d1"
assert rb.side_roster("agy", frozenset({"d1"})) == []
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "d1 d2"
assert rb.side_roster("agy", frozenset({"d1"})) == ["d2"], "an empty roster was cached"

# The pool's ranking is a live verdict about floors that a long run keeps invalidating, so the
# cache holds it for a window rather than for the process.
rb._SIDE_ROSTER.clear()
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "e1"
assert rb.side_roster("agy", frozenset()) == ["e1"]
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "e2"
assert rb.side_roster("agy", frozenset()) == ["e1"], "re-asked inside its own window"
roster_ttl_was = rb.ROSTER_TTL_S
rb.ROSTER_TTL_S = 0
try:
    assert rb.side_roster("agy", frozenset()) == ["e2"], "the pool is never re-asked"
finally:
    rb.ROSTER_TTL_S = roster_ttl_was

# Every cell of a side starts at once and misses together, so the enumeration happens under the
# lock: beside it, each of them would spawn its own worker-pick per account.
rb._SIDE_ROSTER.clear()
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "f1 f2"
roster_picks = []
real_worker_pick_account = rb.worker_pick_account


def counting_worker_pick(side, excluded):
    roster_picks.append(side)
    return real_worker_pick_account(side, excluded)


rb.worker_pick_account = counting_worker_pick
try:
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as roster_pool:
        rosters = list(roster_pool.map(
            lambda _: rb.side_roster("agy", frozenset()), range(4)
        ))
finally:
    rb.worker_pick_account = real_worker_pick_account
assert all(roster == ["f1", "f2"] for roster in rosters), rosters
# Two answers and the one that ends the walk, once for the side rather than once per cell.
assert len(roster_picks) == 3, roster_picks

# The gate is per roster: enumeration spawns a worker-pick per account, and one slow pool must
# not hold every other side out of its own answer for as long as that takes.
rb._SIDE_ROSTER.clear()
rb._SIDE_ROSTER_GATES.clear()
slow_side_entered = threading.Event()
slow_side_release = threading.Event()


def blocking_worker_pick(side, excluded):
    if side == "codex":
        slow_side_entered.set()
        slow_side_release.wait(10)
    return real_worker_pick_account(side, excluded)


rb.worker_pick_account = blocking_worker_pick
gate_pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)
try:
    blocked = gate_pool.submit(rb.side_roster, "codex", frozenset())
    assert slow_side_entered.wait(10), "the slow side never started"
    # Waited on with a deadline rather than asserted directly: a shared gate does not answer
    # this call wrongly, it never answers it, and a test that hangs reports nothing.
    try:
        free_roster = gate_pool.submit(rb.side_roster, "agy", frozenset()).result(5)
    except concurrent.futures.TimeoutError:
        free_roster = "blocked"
finally:
    slow_side_release.set()
    rb.worker_pick_account = real_worker_pick_account
    gate_pool.shutdown(wait=True)
assert free_roster == ["f1", "f2"], "one side blocked another"
assert blocked.result(10) == ["f1", "f2"]

# The roster is filtered against one read of the record, not one read per candidate.
rb._SIDE_ROSTER.clear()
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "g1 g2 g3"
wall_reads = []
real_persisted_walls = rb.persisted_walls


def counting_persisted_walls(path):
    wall_reads.append(path)
    return real_persisted_walls(path)


rb.persisted_walls = counting_persisted_walls
try:
    assert rb.pool_account("agy", set(), 0) == "g1"
finally:
    rb.persisted_walls = real_persisted_walls
assert len(wall_reads) == 1, wall_reads
del os.environ["WORKER_PICK_FAKE_ACCOUNTS"]
rb._SIDE_ROSTER.clear()

# An account another rater already retired is excluded from the next request instead of ending
# the search, so a second usable account is still reached.
del os.environ["GEMINIB_EXHAUSTED_PROFILE"]
inherited_run = work / "agy-inherited-wall-run"
inherited_run.mkdir()
(work / "geminib-profile").write_text("")
rb.mark_walled("agy", "work", rb.wall_bucket(rb.parse_rater("agy-flash36-low-skill")))
_, inherited_account, inherited_result = rb.run_rater_task(
    rb.parse_rater("agy-flash36-low-skill"), repo, sha, "", inherited_run, "ignored fixture diff"
)
assert inherited_account == "main", (inherited_account, inherited_result)
assert inherited_result[0] == 0 and (work / "geminib-profile").read_text() == "main"
clear_walls()

# A cell that answered and still reported an exhausted account keeps its review; only the
# account is retired, so the next rater of that side does not spend it again.
spent_run = work / "agy-spent-but-answered-run"
spent_run.mkdir()
spent_stderr = work / "agy-spent-stderr"
spent_stderr.write_text("Individual quota reached for this account\n")
os.environ["AGY_FIXTURE_STDERR"] = str(spent_stderr)
_, spent_account, spent_result = rb.run_rater_task(
    rb.parse_rater("agy-flash36-low-skill"), repo, sha, "", spent_run, "ignored fixture diff"
)
assert spent_result[0] == 0 and spent_account == "work", (spent_account, spent_result)
assert len(rb.normalize_findings(spent_result[2], "agy-flash36-low-skill")) == 2
assert rb.is_walled("agy", "work", rb.wall_bucket(rb.parse_rater("agy-flash36-low-skill")))
clear_walls()
del os.environ["AGY_FIXTURE_STDERR"]

# Claude bills fable separately, so a wall in one bucket must leave the other bucket alone.
rb.mark_walled("claude", "com", "fable")
assert rb.is_walled("claude", "com", "fable")
assert not rb.is_walled("claude", "com")
assert rb.wall_bucket(rb.parse_rater("fable-medium")) == "fable"
assert rb.wall_bucket(rb.parse_rater("opus-medium")) == "general"
clear_walls()

assert rb.SIDE_WALL["grok"](1, "", "json parse error at char 4290") is False
assert rb.SIDE_WALL["grok"](1, "", "HTTP 429 rate limit") is True
codex_limit_content = json.dumps({
    "type": "item.completed",
    "item": {"type": "agent_message", "text": json.dumps([{
        "severity": "P1", "file": "src/limits.py", "line": 1,
        "summary": "Handle usage_limit_exceeded",
    }])},
})
codex_limit_error = json.dumps({
    "type": "error", "message": "usage_limit_exceeded",
})
codex_limit_code = json.dumps({
    "type": "error", "code": "usage_limit_exceeded",
})
codex_capacity_error = json.dumps({
    "type": "turn.failed",
    "error": {"message": "Selected model is at capacity. Please try a different model."},
})
assert rb.SIDE_WALL["codex"](0, codex_limit_content, "") is False
assert rb.SIDE_WALL["codex"](1, codex_limit_error, "") is True
assert rb.SIDE_WALL["codex"](1, codex_limit_code, "") is True
assert rb.SIDE_WALL["codex"](1, codex_capacity_error, "") is False
del os.environ["REVIEW_BENCH_WORKER_PICK_BIN"]

os.environ.update({
    "REVIEW_BENCH_OPENCODE_BIN": str(fixtures / "fake-opencode-go.sh"),
    "OPENCODE_CAPTURE_ARGS": str(work / "opencode-args"),
    "OPENCODE_CAPTURE_PROMPT": str(work / "opencode-prompt"),
    "OPENCODE_FIXTURE_STDOUT": str(fixtures / "opencode-happy.json"),
})
opencode_run = work / "opencode-run"
opencode_run.mkdir()
opencode_rater = rb.parse_rater("oc-glm52")
profiles_path = fixture_home / ".config/opencode-go/profiles"
default_profile_capture = work / "opencode-default-profile"
os.environ["OPENCODE_CAPTURE_PROFILE"] = str(default_profile_capture)
os.environ["OPENCODE_GO_PROFILE"] = "ambient"
rb.run_opencode(
    opencode_rater, repo, sha, "", opencode_run, "fixture commit diff",
    rb.pool_account("opencode", set()),
)
assert rb.opencode_profiles() == ["-"] and rb.pool_account("opencode", set()) == \
    "opencode-go" and default_profile_capture.read_text().strip() == "unset"
del os.environ["OPENCODE_GO_PROFILE"]

profiles_path.parent.mkdir(parents=True)
profiles_path.write_text("# preferred order\n\n-\n  # spare key\nsecond\n")
assert rb.opencode_profiles() == ["-", "second"]
failover_profile_capture = work / "opencode-failover-profiles"
os.environ["OPENCODE_CAPTURE_PROFILE"] = str(failover_profile_capture)
os.environ["OPENCODE_WALL_DEFAULT"] = "1"
failover_rater, failover_account, failover_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", opencode_run, "fixture commit diff"
)
assert failover_rater == opencode_rater and failover_account == "opencode-go-second" and \
    failover_result[0] == 0 and rb.is_walled("opencode", "opencode-go") and \
    failover_profile_capture.read_text().splitlines() == ["unset", "second"]
del os.environ["OPENCODE_WALL_DEFAULT"]

verifier_profile_capture = work / "opencode-verifier-profile"
os.environ["OPENCODE_CAPTURE_PROFILE"] = str(verifier_profile_capture)
verifier_profile_result = rb.verify_one(
    0, {"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "claim"},
    repo, sha, "oc-kimik3", ["line"],
)
assert not verifier_profile_result.get("walled") and \
    verifier_profile_capture.read_text().strip() == "second"

os.environ["OPENCODE_FIXTURE_RC"] = "1"
os.environ["OPENCODE_FIXTURE_STDERR"] = "HTTP 429 usage limit reached"
both_walled_rater, both_walled_account, both_walled_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", opencode_run, "fixture commit diff"
)
assert both_walled_rater == opencode_rater and both_walled_account == \
    "opencode-go-second" and rb.SIDE_WALL["opencode"](
        both_walled_result[0], both_walled_result[2], both_walled_result[3]
    ) and rb.is_walled("opencode", "opencode-go-second")
_, exhausted_account, exhausted_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", opencode_run, "fixture commit diff"
)
assert exhausted_account is None and "no opencode account left" in exhausted_result[3]
del os.environ["OPENCODE_FIXTURE_RC"]
del os.environ["OPENCODE_FIXTURE_STDERR"]
clear_walls()
profiles_path.unlink()
del os.environ["OPENCODE_CAPTURE_PROFILE"]

pin_repo = work / "sha-pinned-repo"
pin_repo.mkdir()
subprocess.run(["git", "init", "-q", str(pin_repo)], check=True)
subprocess.run(["git", "-C", str(pin_repo), "config", "user.email", "bench@example.test"],
               check=True)
subprocess.run(["git", "-C", str(pin_repo), "config", "user.name", "Review Bench"], check=True)
pin_file = pin_repo / "pinned.txt"
pin_file.write_text("initial marker\n")
subprocess.run(["git", "-C", str(pin_repo), "add", "pinned.txt"], check=True)
subprocess.run(["git", "-C", str(pin_repo), "commit", "-qm", "initial"], check=True)
pin_file.write_text("reviewed SHA marker\n")
subprocess.run(["git", "-C", str(pin_repo), "commit", "-qam", "reviewed"], check=True)
pin_sha = subprocess.run(
    ["git", "-C", str(pin_repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True
).stdout.strip()
pin_file.write_text("descendant fix marker\n")
subprocess.run(["git", "-C", str(pin_repo), "commit", "-qam", "fix"], check=True)
pin_descendant_sha = subprocess.run(
    ["git", "-C", str(pin_repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True
).stdout.strip()
pin_file.write_text("working tree marker\n")
pin_diff = rb.commit_diff(pin_repo, pin_sha)
snapshot_status = subprocess.run(
    ["git", "-C", str(pin_repo), "status", "--porcelain=v1", "-z"],
    check=True, capture_output=True,
).stdout
snapshot_tree = rb.working_tree_tree(pin_repo)
snapshot_sha = rb.worktree_snapshot_commit(pin_repo)
assert rb.worktree_snapshot_commit(pin_repo) == snapshot_sha
assert subprocess.run(
    ["git", "-C", str(pin_repo), "rev-parse", f"{snapshot_sha}^"],
    check=True, capture_output=True, text=True,
).stdout.strip() == pin_descendant_sha
assert subprocess.run(
    ["git", "-C", str(pin_repo), "rev-parse", f"{snapshot_sha}^{{tree}}"],
    check=True, capture_output=True, text=True,
).stdout.strip() == snapshot_tree
assert subprocess.run(
    ["git", "-C", str(pin_repo), "status", "--porcelain=v1", "-z"],
    check=True, capture_output=True,
).stdout == snapshot_status

snapshot_clean = work / "snapshot-clean"
snapshot_clean.mkdir()
subprocess.run(["git", "-C", str(snapshot_clean), "init", "-q"], check=True)
(snapshot_clean / "clean.txt").write_text("clean\n")
subprocess.run(["git", "-C", str(snapshot_clean), "add", "clean.txt"], check=True)
subprocess.run(
    ["git", "-C", str(snapshot_clean), "-c", "user.name=Fixture",
     "-c", "user.email=fixture@example.com", "commit", "-qm", "clean"],
    check=True,
)
clean_worktree = subprocess.run(
    [sys.argv[1], "run", "--worktree", "--repo", str(snapshot_clean),
     "--raters", "oc-kimik3"],
    capture_output=True, text=True,
)
assert clean_worktree.returncode != 0
assert "working tree matches HEAD" in clean_worktree.stderr, clean_worktree.stderr
assert "review-bench run HEAD --raters oc-kimik3 --repo" in clean_worktree.stderr, \
    clean_worktree.stderr
clean_review = subprocess.run(
    [sys.argv[1], "review", "--worktree", "--repo", str(snapshot_clean), "--tier", "T0"],
    capture_output=True, text=True,
)
assert clean_review.returncode != 0
assert "review-bench review HEAD --tier T0 --repo" in clean_review.stderr, clean_review.stderr
max_clean_review = subprocess.run(
    [sys.argv[1], "review", "--worktree", "--repo", str(snapshot_clean),
     "--tier", "T2", "--max", "--foreground"],
    capture_output=True, text=True,
)
assert max_clean_review.returncode != 0
assert "review-bench review HEAD --tier T2 --max --foreground --repo" in max_clean_review.stderr, \
    max_clean_review.stderr
foreground_clean_review = subprocess.run(
    [sys.argv[1], "review", "--worktree", "--repo", str(snapshot_clean),
     "--tier", "T2", "--foreground"],
    capture_output=True, text=True,
)
assert foreground_clean_review.returncode != 0
assert "working tree matches HEAD" in foreground_clean_review.stderr, \
    foreground_clean_review.stderr
assert "foreground harness commands are killed" not in foreground_clean_review.stderr
for command in (
    [sys.argv[1], "review", "HEAD", "--worktree", "--repo", str(snapshot_clean),
     "--tier", "T0"],
    [sys.argv[1], "review", "--repo", str(snapshot_clean), "--tier", "T0"],
):
    conflict = subprocess.run(command, capture_output=True, text=True)
    assert conflict.returncode != 0
    assert "exactly one of commitish and --worktree" in conflict.stderr, conflict.stderr

fake_codex = work / "fake-codex"
fake_codex.write_text("""#!/usr/bin/env bash
set -eu
printf '%s\n' "$PWD" >"$RATER_CAPTURE_CWD"
printf '%s\\0' "$@" >"$RATER_CAPTURE_ARGS"
cat >"$RATER_CAPTURE_STDIN"
git rev-parse HEAD >"$RATER_CAPTURE_HEAD"
git rev-list --all >"$RATER_CAPTURE_REFS"
cat pinned.txt >"$RATER_CAPTURE_CONTENT"
output=
while [[ $# -gt 0 ]]; do
  case $1 in
    -o) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
: >"$output"
printf '%s\n' '{"type":"thread.started","thread_id":"fixture"}'
# Codex reports a refusal in its event stream and leaves stderr empty, which is what makes
# such a run unclassifiable unless the reason is recovered.
if [[ -n ${CODEX_FIXTURE_TURN_FAILED:-} ]]; then
  printf '{"type":"turn.failed","error":{"message":"%s"}}\\n' "$CODEX_FIXTURE_TURN_FAILED"
  exit 1
fi
""")
fake_codex.chmod(0o755)
os.environ.update({
    "REVIEW_BENCH_CODEX_BIN": str(fake_codex),
    "RATER_CAPTURE_CWD": str(work / "rater-cwd"),
    "RATER_CAPTURE_ARGS": str(work / "rater-args"),
    "RATER_CAPTURE_STDIN": str(work / "rater-stdin"),
    "RATER_CAPTURE_HEAD": str(work / "rater-head"),
    "RATER_CAPTURE_REFS": str(work / "rater-refs"),
    "RATER_CAPTURE_CONTENT": str(work / "rater-content"),
})
codex_run = work / "codex-pin-run"
codex_run.mkdir()
rc, _, _, stderr, codex_command = rb.run_codex(
    rb.parse_rater("sol-medium"), pin_repo, pin_sha, "", codex_run, "", "main"
)
assert rc == 0 and not stderr
codex_cwd = pathlib.Path((work / "rater-cwd").read_text().strip())
assert (
    codex_cwd != pin_repo
    and not codex_cwd.exists()
    and (work / "rater-head").read_text().strip() == pin_sha
    and pin_descendant_sha not in (work / "rater-refs").read_text().splitlines()
    and (work / "rater-content").read_text() == "reviewed SHA marker\n"
)
assert any(
    arg.startswith("developer_instructions=")
    and rb.READ_ONLY_REVIEW_INSTRUCTION in arg
    for arg in codex_command
)
# Without the marker the native review command answers a clean review in prose, which the cell
# records as a failure and the corpus then never counts as an empty result.
codex_instruction = next(
    arg for arg in codex_command if arg.startswith("developer_instructions=")
)
assert rb.CLEAN_REVIEW_MARKER in codex_instruction, codex_instruction
assert rb.clean_review_declared(rb.CLEAN_REVIEW_MARKER), rb.CLEAN_REVIEW_MARKER
focus_run = work / "codex-focus-run"
focus_run.mkdir()
rc, _, _, stderr, focus_command = rb.run_codex(
    rb.parse_rater("sol-medium"), pin_repo, pin_sha, "line 7", focus_run, "", "main"
)
assert rc == 0 and not stderr
focus_instruction = next(
    arg for arg in focus_command if arg.startswith("developer_instructions=")
)
assert rb.CLEAN_REVIEW_MARKER in focus_instruction, focus_instruction
assert "line 7" in focus_instruction, focus_instruction
bare_run = work / "codex-bare-run"
bare_run.mkdir()
bare_diff = "diff --git a/pinned.txt b/pinned.txt\n"
rc, _, _, stderr, bare_command = rb.run_codex(
    rb.parse_rater("sol-low-bare"), pin_repo, pin_sha, "", bare_run, bare_diff, "main"
)
assert rc == 0 and not stderr
captured_args = (work / "rater-args").read_bytes().split(b"\0")[:-1]
captured_args = [arg.decode() for arg in captured_args]
assert "review" not in captured_args, captured_args
assert captured_args[0] == "exec", captured_args
assert "-" in captured_args, captured_args
assert not any(bare_diff in arg for arg in captured_args), captured_args
captured_stdin = (work / "rater-stdin").read_text()
assert "Review commit" in captured_stdin, captured_stdin
assert "Commit diff:" in captured_stdin, captured_stdin
assert bare_diff in captured_stdin, captured_stdin
assert not any("Commit diff:" in arg for arg in bare_command), bare_command
assert not any(arg.startswith("developer_instructions=") for arg in bare_command), bare_command

# A refusal Codex reported only in its event stream still reaches stderr, or the run is recorded
# as a silent death that no later classification can retry or even name.
os.environ["CODEX_FIXTURE_TURN_FAILED"] = "Selected model is at capacity. Please try a different model."
silent_run = work / "codex-silent-failure-run"
silent_run.mkdir()
silent_rc, _, _, silent_stderr, _ = rb.run_codex(
    rb.parse_rater("sol-medium"), pin_repo, pin_sha, "", silent_run, "", "main"
)
del os.environ["CODEX_FIXTURE_TURN_FAILED"]
assert silent_rc != 0, silent_rc
assert "at capacity" in silent_stderr, repr(silent_stderr)
assert rb.codex_transient_failure("", silent_stderr), silent_stderr

fake_claude = work / "fake-claudeb"
fake_claude.write_text("""#!/usr/bin/env bash
set -eu
printf '%s\n' "$PWD" >"$RATER_CAPTURE_CWD"
git rev-parse HEAD >"$RATER_CAPTURE_HEAD"
git rev-list --all >"$RATER_CAPTURE_REFS"
cat pinned.txt >"$RATER_CAPTURE_CONTENT"
printf '%s\n' '{"type":"result","result":""}'
""")
fake_claude.chmod(0o755)
os.environ["REVIEW_BENCH_CLAUDEB_BIN"] = str(fake_claude)
claude_run = work / "claude-pin-run"
claude_run.mkdir()
rc, _, _, stderr, claude_command = rb.run_claude(
    rb.parse_rater("opus-medium"), pin_repo, pin_sha, "", claude_run, pin_diff, "fixture"
)
assert rc == 0 and not stderr
claude_cwd = pathlib.Path((work / "rater-cwd").read_text().strip())
assert (
    claude_cwd != pin_repo
    and not claude_cwd.exists()
    and (work / "rater-head").read_text().strip() == pin_sha
    and pin_descendant_sha not in (work / "rater-refs").read_text().splitlines()
    and (work / "rater-content").read_text() == "reviewed SHA marker\n"
)
claude_prompt = claude_command[claude_command.index("-p") + 1]
assert (
    rb.READ_ONLY_REVIEW_INSTRUCTION in claude_prompt
    and rb.READ_ONLY_REVIEW_INSTRUCTION in rb.skill_brief(pin_sha, "", "/sealed")
)

pin_run = work / "opencode-pin-run"
pin_run.mkdir()
os.environ["OPENCODE_CAPTURE_PROMPT"] = str(work / "opencode-pin-prompt")
rc, _, _, stderr, _ = rb.run_opencode(
    opencode_rater, pin_repo, pin_sha, "", pin_run, pin_diff, "opencode-go"
)
assert rc == 0 and not stderr
pin_prompt = (work / "opencode-pin-prompt").read_text()
assert (
    "reviewed SHA marker" in pin_prompt
    and "descendant fix marker" not in pin_prompt
    and "working tree marker" not in pin_prompt
)

os.environ["OPENCODE_CAPTURE_PROMPT"] = str(work / "verify-pin-prompt")
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-verify-keep.json")
pin_finding = {
    "severity": "P2", "file": "pinned.txt", "line": 1, "summary": "pinned claim",
}
kept, audit = rb.verify_findings(
    [pin_finding], pin_repo, pin_sha, "oc-kimik3", ["pinned.txt"]
)
assert kept == [pin_finding] and audit[0]["kept"] is True
verify_pin_prompt = (work / "verify-pin-prompt").read_text()
assert (
    "reviewed SHA marker" in verify_pin_prompt
    and "descendant fix marker" not in verify_pin_prompt
    and "working tree marker" not in verify_pin_prompt
)

os.environ["OPENCODE_CAPTURE_PROMPT"] = str(work / "opencode-prompt")
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
large_diff = "fixture OpenCode diff\n" + ("x" * 1000000)
rc, duration, text, stderr, command = rb.run_opencode(
    opencode_rater, repo, sha, "", opencode_run, large_diff, "opencode-go"
)
assert rc == 0 and duration >= 0 and not stderr
assert rb.normalize_findings(text, opencode_rater["spec"]) == [{
    "severity": "P2", "file": "src/queue.py", "line": 27,
    "summary": "Keep the pending job until delivery succeeds", "rater": "oc-glm52",
}]
assert large_diff in (work / "opencode-prompt").read_text()
assert command[:3] == [
    str(fixtures / "fake-opencode-go.sh"), "run", "glm-5.2",
]
assert "--prompt-file" in command
assert "--json" in command
assert command[command.index("--max-tokens") + 1] == "32000"
assert "--effort" not in command
assert max(map(len, command)) < 4096
usage = json.loads((opencode_run / "usage-oc-glm52.json").read_text())
assert usage == {
    "prompt_tokens": 1200, "completion_tokens": 80, "total_tokens": 1280,
}

effort_run = work / "opencode-effort-run"
effort_run.mkdir()
effort_rater = rb.parse_rater("oc-dsv4pro-high")
rc, _, text, stderr, effort_command = rb.run_opencode(
    effort_rater, repo, sha, "", effort_run, "fixture commit diff", "work"
)
assert rc == 0 and text and not stderr
assert effort_command[effort_command.index("--effort") + 1] == "high"
# An effort cell asks for reasoning; suppressing it would silently make the cell a
# duplicate of the effortless one, and the client rejects the contradiction anyway.
assert "--no-reasoning" not in effort_command
glm_effort_run = work / "opencode-glm-effort-run"
glm_effort_run.mkdir()
_, _, _, _, glm_effort_command = rb.run_opencode(
    rb.parse_rater("oc-glm52-high"), repo, sha, "", glm_effort_run, "fixture commit diff", "opencode-go"
)
assert "--no-reasoning" not in glm_effort_command
assert glm_effort_command[glm_effort_command.index("--effort") + 1] == "high"
assert rb.opencode_expected_s(rb.parse_rater("oc-glm52-high")) > rb.opencode_expected_s(
    rb.parse_rater("oc-glm52")
)
# The client's buffered wall-clock cap is handed the cell's own deadline, so it can
# never kill a generation the cell was still willing to wait for.
wait_run = work / "opencode-wait-run"
wait_run.mkdir()
wait_env = work / "opencode-wait-env"
os.environ["OPENCODE_CAPTURE_ENV"] = str(wait_env)
rb.run_opencode(rb.parse_rater("oc-mmm3"), repo, sha, "", wait_run, "fixture commit diff", "opencode-go")
del os.environ["OPENCODE_CAPTURE_ENV"]
assert wait_env.read_text().strip() == str(
    rb.opencode_timeout_s(rb.parse_rater("oc-mmm3"))
), wait_env.read_text()

length_run = work / "opencode-length-run"
length_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-length.json")
rc, _, text, stderr, _ = rb.run_opencode(
    opencode_rater, repo, sha, "", length_run, "fixture commit diff", "opencode-go"
)
assert rc == 1 and not text
assert "empty content" in stderr and "finish_reason='length'" in stderr
length_usage = json.loads((length_run / "usage-oc-glm52.json").read_text())
assert length_usage["completion_tokens"] == 8192

think_run = work / "opencode-think-run"
think_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-think.json")
rc, _, text, stderr, _ = rb.run_opencode(
    opencode_rater, repo, sha, "", think_run, "fixture commit diff", "opencode-go"
)
assert rc == 0, stderr
think_rows = rb.normalize_findings(text, "oc-glm52")
assert [(row["file"], row["line"]) for row in think_rows] == [("bin/real.py", 42)], think_rows

stream_rater = rb.parse_rater("oc-dsv4pro-low")
stream_run = work / "opencode-stream-run"
stream_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
rc, _, _, _, stream_command = rb.run_opencode(
    stream_rater, repo, sha, "", stream_run, "fixture commit diff", "opencode-go"
)
assert rc == 0 and "--stream" in stream_command
assert "--no-reasoning" not in stream_command
_, _, _, _, buffered_command = rb.run_opencode(
    opencode_rater, repo, sha, "", stream_run, "fixture commit diff", "opencode-go"
)
assert "--stream" not in buffered_command
assert "--no-reasoning" in buffered_command
assert rb.OPENCODE_MAX_CONCURRENCY >= 3

preamble_run = work / "opencode-preamble-run"
preamble_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-preamble.json")
rc, _, text, stderr, _ = rb.run_opencode(
    opencode_rater, repo, sha, "", preamble_run, "fixture commit diff", "opencode-go"
)
assert rc == 1 and not text
# Stopping one line in is the model's hiccup on a cell that works the rest of the time, so the
# cell is worth another lap; recorded as a plain non-review it was written off after one try.
assert rb.OPENCODE_STUB_STDERR in stderr and "I'll review" in stderr
assert rb.opencode_transient_failure(stderr), stderr

# Answering at length and still parsing to nothing is an answer, just not one with findings:
# asking again buys a second full review of the same prose, so that one is not retried.
long_prose_run = work / "opencode-long-prose-run"
long_prose_run.mkdir()
long_prose = work / "opencode-long-prose.json"
long_prose.write_text(json.dumps({"choices": [{"message": {
    "content": "This change is broadly reasonable. " * 40
}}]}))
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(long_prose)
rc, _, text, long_stderr, _ = rb.run_opencode(
    opencode_rater, repo, sha, "", long_prose_run, "fixture commit diff", "opencode-go"
)
assert rc == 1 and not text
assert "no parseable findings" in long_stderr, long_stderr
assert not rb.opencode_transient_failure(long_stderr), long_stderr
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-preamble.json")

narration_run = work / "opencode-narration-run"
narration_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-narration.json")
rc, _, text, stderr, _ = rb.run_opencode(
    opencode_rater, repo, sha, "", narration_run, "fixture commit diff", "opencode-go"
)
assert rc == 1 and not text
assert "summarised the diff" in stderr, stderr
# A real review states defects and mixes severities, so it must survive the guard.
assert not rb.is_diff_narration([
    {"severity": "P1", "file": "a.sh", "line": 1, "summary": "Added guard drops the last account"},
    {"severity": "P3", "file": "a.sh", "line": 9, "summary": "Updated regex accepts a leading hyphen"},
])
assert not rb.is_diff_narration([
    {"severity": "P3", "file": "a.sh", "line": i, "summary": "Added a row"} for i in range(4)
])
# Bold or backticked narration is still narration; the leading markup must not hide it.
assert rb.is_diff_narration([
    {"severity": "P3", "file": "a.sh", "line": i, "summary": "**Added** a helper row"}
    for i in range(6)
])

# Findings cite files as markdown links, absolute paths and sealed-clone paths; those
# spellings read as different files, so both deduplication and the verifier's file
# lookup need one canonical repository-relative form.
tree = ["bin/geminib", "bin/statusline.sh", "docs/statusline-contract.md", "tests/run.sh"]
assert rb.canonical_finding_path("bin/geminib", tree) == "bin/geminib"
assert rb.canonical_finding_path("`bin/geminib`", tree) == "bin/geminib"
assert rb.canonical_finding_path(
    "[bin/geminib](file:///private/var/folders/x/review-bench-seal-ab12/bin/geminib)", tree
) == "bin/geminib"
assert rb.canonical_finding_path("/Volumes/Work/llm-legs/bin/statusline.sh", tree) == \
    "bin/statusline.sh"
assert rb.canonical_finding_path("/tmp/seal-1/tests/run.sh", tree) == "tests/run.sh"
assert rb.canonical_finding_path("statusline.sh", tree) == "bin/statusline.sh"
assert rb.canonical_finding_path("bin/absent.sh", tree) == "bin/absent.sh"
assert rb.canonical_finding_path("", tree) == ""
assert rb.canonical_finding_path(None, tree) == ""

# A link's text is prose as often as it is a path, so the target is the citation.
assert rb.canonical_finding_path("[Line 42](bin/geminib)", tree) == "bin/geminib"
assert rb.canonical_finding_path("[the gate](tests/run.sh#L42)", tree) == "tests/run.sh"
# ...and the text is the fallback when the target is not a repository path at all.
assert rb.canonical_finding_path(
    "[bin/statusline.sh](https://example.invalid/blob/main/x)", tree
) == "bin/statusline.sh"

assert rb.parse_verify_answer(
    '```json\n{"code_matches": true, "is_defect": false, "why": "style only"}\n```'
) == {"code_matches": True, "is_defect": False, "why": "style only"}
assert rb.parse_verify_answer('Sure!\n{"code_matches": false, "is_defect": true}')["is_defect"]
# A verifier that pretty-prints its verdict is answering correctly, not unusably.
assert rb.parse_verify_answer(
    '{\n  "code_matches": true,\n  "is_defect": true,\n  "why": "guard is missing"\n}'
) == {"code_matches": True, "is_defect": True, "why": "guard is missing"}
for unusable in ('{"code_matches": "yes", "is_defect": true}', "no verdict", "",
                 '{"is_defect": true}'):
    assert rb.parse_verify_answer(unusable) is None, unusable

verify_finding = {"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "claim"}
verify_text = rb.verify_prompt(verify_finding, "deadbee", "bin/review-bench",
                               ["alpha", "beta", "gamma"])
assert "3: gamma" in verify_text and "bin/review-bench:3 — claim" in verify_text
assert "code_matches" in verify_text and "is_defect" in verify_text
known_failures = """Known failure modes of the reviewer — check each:
1. Treat documented behavior or code with explicit explanatory comments as intended design, not a defect.
2. Rigorously re-check boolean logic, edge-case conditions, and sort/ordering direction against what the code actually computes, line by line.
3. Trace variable state through short-circuit branches and string filters to confirm the claimed failure can occur in practice.
4. Reject findings resting on speculative or highly unlikely environment states."""
answer_instruction = """Answer with exactly one JSON object and nothing else:
{"code_matches": true|false, "is_defect": true|false, "why": "<max 15 words>"}"""
assert verify_text.endswith(f"{known_failures}\n\n{answer_instruction}"), verify_text
(work / "prompt-v1-ok").touch()
missing_text = rb.verify_prompt(verify_finding, "deadbee", "bin/gone", None)
assert "does not exist in commit deadbee" in missing_text
# A line past the end of the file is the most obviously bogus claim there is, and an
# unclamped window hands the verifier an empty excerpt it cannot refute.
long_file = [f"line {n}" for n in range(1, 801)]
bogus = {"severity": "P2", "file": "bin/review-bench", "line": 9999, "summary": "claim"}
bogus_text = rb.verify_prompt(bogus, "deadbee", "bin/review-bench", long_file)
assert "lines 680-800 of 800" in bogus_text, bogus_text
assert "800: line 800" in bogus_text
# A commit that deletes a file is where a finding about that file belongs, so the
# verifier reads the parent rather than being told the file does not exist.
deleted_repo = work / "deleted-repo"
deleted_repo.mkdir()
git_env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")


def git(*argv):
    return subprocess.run(["git", "-C", str(deleted_repo), *argv], check=True,
                          capture_output=True, text=True, env=git_env).stdout.strip()


git("init", "-q", "-b", "main")
(deleted_repo / "gone.sh").write_text("alpha\nbeta\n")
git("add", "gone.sh")
git("commit", "-qm", "add")
(deleted_repo / "gone.sh").unlink()
git("add", "-A")
git("commit", "-qm", "remove")
deleted_sha = git("rev-parse", "HEAD")
lines, ref = rb.file_at_commit(deleted_repo, deleted_sha, "gone.sh")
assert lines == ["alpha", "beta"] and ref == f"{deleted_sha}^", (lines, ref)
deleted_prompt = rb.verify_prompt(
    {"severity": "P2", "file": "gone.sh", "line": 1, "summary": "claim"},
    deleted_sha, "gone.sh", lines, ref,
)
assert "which deletes it" in deleted_prompt and "1: alpha" in deleted_prompt
assert rb.file_at_commit(deleted_repo, deleted_sha, "never.sh") == (None, deleted_sha)
# ...and the citation has to survive canonicalisation to get that far: a file the commit
# deletes is absent from its own tree, so the parent's tree is part of the tree too.
deleted_tree = rb.repo_tree(deleted_repo, deleted_sha)
assert "gone.sh" in rb.tree_tiers(deleted_tree)[-1], deleted_tree
assert rb.canonical_finding_path(
    "/private/var/folders/x/review-bench-seal-ab12/gone.sh", deleted_tree
) == "gone.sh"

# The tiers stay ordered: a basename the reviewed commit introduces wins over the same
# basename the parent already had, which a merged tree resolved to neither.
ambiguous_tree = {"reviewed": ["new/foo.sh"], "parent": ["old/foo.sh"]}
assert rb.canonical_finding_path("foo.sh", ambiguous_tree) == "new/foo.sh"
assert rb.canonical_finding_path("old/foo.sh", ambiguous_tree) == "old/foo.sh"
# The looser the rule, the wider the ambiguity check has to be: a deeper citation the reviewed
# tree cannot place belongs to the parent's file, not to a same-named file in the reviewed one...
assert rb.canonical_finding_path(
    "sub/bar.py", {"reviewed": ["other/bar.py"], "parent": ["dir/sub/bar.py"]}
) == "dir/sub/bar.py"
# ...and a basename the reviewed tree itself cannot place uniquely stays unresolved rather than
# being answered from the parent.
assert rb.canonical_finding_path(
    "foo.sh", {"reviewed": ["dirA/foo.sh", "dirB/foo.sh"], "parent": ["old/foo.sh"]}
) == "foo.sh"
# The longest suffix is the most specific spelling of one file, so it outranks tier order: an
# absolute citation of the parent's file must not answer with a bare name the reviewed tree has.
suffix_tree = {"reviewed": ["foo.sh"], "parent": ["old/foo.sh"]}
assert rb.canonical_finding_path("/tmp/seal-1/old/foo.sh", suffix_tree) == "old/foo.sh"
assert rb.canonical_finding_path("/tmp/seal-1/foo.sh", suffix_tree) == "foo.sh"

verify_findings_input = [
    {"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "first claim"},
    {"severity": "P3", "file": "bin/review-bench", "line": 9, "summary": "second claim"},
]
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-verify-drop.json")
kept, audit = rb.verify_findings(verify_findings_input, repo, sha, "oc-kimik3", tree)
assert kept == [] and len(audit) == 2
assert [row["idx"] for row in audit] == [0, 1]
assert all(row["kept"] is False and row["code_matches"] is False for row in audit)
assert "not there" in audit[0]["why"]
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-verify-keep.json")
kept, audit = rb.verify_findings(verify_findings_input, repo, sha, "oc-kimik3", tree)
assert kept == verify_findings_input
assert all(row["kept"] is True and row["is_defect"] is True for row in audit)
# Losing a real defect to an unusable verifier answer is worse than one more row to
# read, so anything unparseable keeps the finding.
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-preamble.json")
kept, audit = rb.verify_findings(verify_findings_input, repo, sha, "oc-kimik3", tree)
assert kept == verify_findings_input
assert all(row["kept"] is True and row["code_matches"] is None for row in audit)
assert "no usable answer" in audit[0]["why"]
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
verify_args = (work / "opencode-args").read_text().split("\n")
assert "--no-reasoning" in verify_args and "run" == verify_args[0]

# A 429 is the subscription's own dollar window, so the run stops instead of sending
# one doomed request per remaining cell.
wall_run = work / "opencode-wall-run"
wall_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
os.environ["OPENCODE_FIXTURE_RC"] = "1"
os.environ["OPENCODE_FIXTURE_STDERR"] = "HTTP 429\n{\"error\":\"usage limit reached\"}"
rc, _, _, wall_stderr, _ = rb.run_opencode(
    opencode_rater, repo, sha, "", wall_run, "fixture commit diff", "opencode-go"
)
assert rc == 1 and rb.SIDE_WALL["opencode"](rc, "", wall_stderr), wall_stderr
walled_rater, walled_account, walled_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", wall_run, "fixture commit diff"
)
assert walled_account == "opencode-go" and rb.is_walled("opencode", "opencode-go")
_, skipped_account, skipped_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", wall_run, "fixture commit diff"
)
assert skipped_account is None and "no opencode account left" in skipped_result[3], skipped_result

# A verifier that walls has to record the wall before it lets the next one through the gate:
# released first, a queued verifier takes the slot, passes the post-gate check and sends one
# more doomed request.
clear_walls()
gate_saw = []
real_gate = rb.OPENCODE_GATE


class WallOrderGate:
    def acquire(self, *args):
        real_gate.acquire(*args)

    def release(self):
        gate_saw.append(rb.is_walled("opencode", "opencode-go"))
        real_gate.release()


rb.OPENCODE_GATE = WallOrderGate()
try:
    walled_verify = rb.verify_one(
        0, {"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "claim"},
        repo, sha, "oc-kimik3", ["line"],
    )
finally:
    rb.OPENCODE_GATE = real_gate
assert gate_saw == [True], gate_saw
assert walled_verify["walled"] and walled_verify["kept"], walled_verify

clear_walls()
del os.environ["OPENCODE_FIXTURE_RC"]
del os.environ["OPENCODE_FIXTURE_STDERR"]
assert rb.opencode_usage_wall("usage limit reached")
assert rb.opencode_usage_wall('{"type":"GoUsageLimitError","limitName":"weekly"}')
assert not rb.opencode_usage_wall("HTTP 503 failover_exhausted")
# A bare status code is as much the provider throttling the model as the plan running out, and
# only one of those readings can cost an account that still has its whole quota.
assert not rb.opencode_usage_wall("HTTP 429")
assert not rb.opencode_usage_wall("HTTP 429 too many requests")
assert rb.opencode_transient_failure("HTTP 429")

# The gateway answers 429 both for a spent subscription and for a burst throttle; only the
# first is the account's own window, and only it may retire the account.
assert rb.opencode_transient_failure(
    'HTTP 429 {"error":{"message":"Provider rate limit exceeded"}}'
)
assert not rb.opencode_transient_failure(
    'HTTP 429 {"error":{"type":"GoUsageLimitError","message":"Weekly usage limit reached"}}'
)
assert not rb.opencode_transient_failure("opencode returned malformed JSON envelope")
assert rb.codex_transient_failure("", "Selected model is at capacity")
assert not rb.codex_transient_failure("", "HTTP 429 usage limit exceeded")

# Codex exits non-zero with an empty stderr and says why only in its event stream, so a run
# recorded from stderr alone is unclassifiable afterwards. Both shapes are from recorded runs.
capacity = "Selected model is at capacity. Please try a different model."
assert rb.codex_failure_reason(
    '{"type":"item.completed","item":{"type":"error","message":"stream disconnected"}}\n'
    '{"type":"error","message":"%s"}\n'
    '{"type":"turn.failed","error":{"message":"%s"}}' % (capacity, capacity)
) == capacity
assert rb.codex_failure_reason(
    '{"type":"turn.failed","error":{"message":"%s"}}' % capacity
) == capacity
assert rb.codex_failure_reason('{"type":"item.completed","item":{}}') == ""
assert rb.codex_failure_reason('not json\n{"type":"turn.failed","error":"plain string"}') == ""
# Recovered onto stderr it reaches the classifier, which is what makes the retry reachable.
assert rb.codex_transient_failure("", rb.codex_failure_reason(
    '{"type":"turn.failed","error":{"message":"%s"}}' % capacity
))
# Codex answers the same status code for a spent plan and a throttled provider, so a bare 429
# retires nothing there either; the named wording still does.
assert not rb.codex_usage_wall("", "HTTP 429 from provider")
assert rb.codex_transient_failure("", "HTTP 429 from provider")
assert rb.codex_usage_wall("", "You have hit your usage limit")
assert not rb.codex_transient_failure("", "You have hit your usage limit")
# "rate limit" is the throttle's own phrase upstream, so it retires nothing here either.
assert not rb.codex_usage_wall("", "provider rate limit exceeded")
assert rb.codex_transient_failure("", "provider rate limit exceeded")
assert rb.transient_backoffs() == [15, 30]
os.environ["REVIEW_BENCH_TRANSIENT_BACKOFF_S"] = "0,0"
assert rb.transient_backoffs() == [0, 0]

# A named burst throttle is the bench asking too fast, not the account's window closing.
burst_stderr = ('HTTP 429 {"error":{"message":"Provider rate limit exceeded",'
                '"type":"rate_limit_error","code":"provider_rate_limit_exceeded"}}')
assert rb.opencode_burst_throttle(burst_stderr)

# A verifier the gateway is throttling is asked of the next model in the chain, because that
# refusal belongs to the model upstream, not to the account: on 2026-07-31 kimi-k3 was refused
# on a brand-new account while grok-4.5 answered on that same one. Every other kind of failure
# stops the chain, or one bad answer would cost three requests instead of one.
assert rb.verifier_chain("oc-kimik3") == ["oc-kimik3", "oc-qwen37plus", "oc-mmm3"]
assert rb.verifier_chain("oc-mimo25")[0] == "oc-mimo25", rb.verifier_chain("oc-mimo25")
assert len(rb.verifier_chain("oc-mimo25")) == 4
chain_models = []
real_run = subprocess.run


def chain_fixture(command, **kwargs):
    model = command[command.index("run") + 1]
    chain_models.append(model)
    if model == rb.OPENCODE_MODEL_IDS["oc-kimik3"]:
        return subprocess.CompletedProcess(command, 1, "", (
            'HTTP 429 {"error":{"code":"provider_rate_limit_exceeded"}}'
        ))
    return subprocess.CompletedProcess(command, 0, json.dumps({"choices": [{"message": {
        "content": json.dumps({"code_matches": True, "is_defect": False, "why": "not a defect"})
    }}]}), "")


subprocess.run = chain_fixture
try:
    chain_row = rb.verify_one(
        0, {"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "claim"},
        repo, sha, "oc-kimik3", ["line one"],
    )
finally:
    subprocess.run = real_run
assert chain_models == [rb.OPENCODE_MODEL_IDS["oc-kimik3"],
                        rb.OPENCODE_MODEL_IDS["oc-qwen37plus"]], chain_models
assert chain_row["kept"] is False, chain_row
assert "verified by oc-qwen37plus" in chain_row["why"], chain_row
assert chain_row["verifier"] == "oc-qwen37plus", chain_row
assert rb.verifier_tally([
    {"code_matches": True, "verifier": "oc-kimik3"},
    {"code_matches": False, "verifier": "oc-qwen37plus"},
    {"code_matches": True},
    {"code_matches": None, "walled": True, "verifier": "oc-kimik3"},
], "oc-kimik3") == {"oc-kimik3": 2, "oc-qwen37plus": 1}
clear_walls()

# A model that simply answered badly is not asked again of anyone else.
once_models = []


def once_fixture(command, **kwargs):
    once_models.append(command[command.index("run") + 1])
    return subprocess.CompletedProcess(command, 0, json.dumps({"choices": [{"message": {
        "content": "I could not tell."
    }}]}), "")


subprocess.run = once_fixture
try:
    rb.verify_one(
        0, {"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "claim"},
        repo, sha, "oc-kimik3", ["line one"],
    )
finally:
    subprocess.run = real_run
assert once_models == [rb.OPENCODE_MODEL_IDS["oc-kimik3"]], once_models
clear_walls()

# A refused cell waits on its own: making the other cells of the model wait too only pays if the
# run is the cause, and probing kimi-k3 at 5, 20 and 60 second gaps on 2026-07-30 refused all
# eighteen while grok-4.5 answered throughout, so the pressure was upstream and unshareable.
throttle_slept = []
real_sleep = time.sleep
time.sleep = throttle_slept.append
burst_backoff_run = work / "opencode-burst-backoff-run"
burst_backoff_run.mkdir()
backoff_was = os.environ.get("REVIEW_BENCH_TRANSIENT_BACKOFF_S")
os.environ["REVIEW_BENCH_TRANSIENT_BACKOFF_S"] = "7"
os.environ["OPENCODE_FIXTURE_RC"] = "1"
os.environ["OPENCODE_FIXTURE_STDERR"] = (
    'HTTP 429 {"error":{"code":"provider_rate_limit_exceeded"}}'
)
backoff_log = io.StringIO()
try:
    with contextlib.redirect_stdout(backoff_log):
        _, backoff_account, backoff_result = rb.run_rater_task(
            opencode_rater, repo, sha, "", burst_backoff_run, "fixture commit diff"
        )
finally:
    time.sleep = real_sleep
    if backoff_was is None:
        del os.environ["REVIEW_BENCH_TRANSIENT_BACKOFF_S"]
    else:
        os.environ["REVIEW_BENCH_TRANSIENT_BACKOFF_S"] = backoff_was
    del os.environ["OPENCODE_FIXTURE_RC"]
    del os.environ["OPENCODE_FIXTURE_STDERR"]
assert throttle_slept == [7], throttle_slept
# The retry names the cause, so a log of waits says which of them are worth acting on.
assert "transient failure (throttled); retrying in 7s" in backoff_log.getvalue(), \
    backoff_log.getvalue()
# The account keeps its place in the pool: a throttle is never evidence the plan is spent.
assert not rb.is_walled("opencode", backoff_account), backoff_account
assert backoff_result[0] == 1, backoff_result
clear_walls()

assert not rb.opencode_burst_throttle(
    'HTTP 429 {"error":{"type":"GoUsageLimitError","message":"Weekly usage limit reached"}}'
)
assert not rb.opencode_burst_throttle("HTTP 503 failover_exhausted")
clear_walls()
os.environ["OPENCODE_FIXTURE_RC"] = "1"
os.environ["OPENCODE_FIXTURE_STDERR"] = burst_stderr
burst_run = work / "opencode-burst-run"
burst_run.mkdir()
_, burst_account, burst_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", burst_run, "fixture commit diff"
)
assert burst_account == "opencode-go" and burst_result[0] == 1, burst_result
assert not rb.is_walled("opencode", "opencode-go")
del os.environ["OPENCODE_FIXTURE_RC"]
del os.environ["OPENCODE_FIXTURE_STDERR"]
clear_walls()

# A throttle that clears is waited out on the same account: retiring it would empty the pool
# of accounts that were never out of quota.
clear_walls()
transient_left = work / "opencode-transient-left"
transient_left.write_text("2\n")
os.environ["OPENCODE_TRANSIENT_LEFT_FILE"] = str(transient_left)
transient_run = work / "opencode-transient-run"
transient_run.mkdir()
_, transient_account, transient_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", transient_run, "fixture commit diff"
)
assert transient_account == "opencode-go" and transient_result[0] == 0, transient_result
assert not rb.is_walled("opencode", "opencode-go")
assert transient_left.read_text().strip() == "0"

# A throttle that never clears costs the cell, never the account: the run is asking too fast,
# which is no evidence at all about the subscription behind the account.
clear_walls()
transient_left.write_text("9\n")
persistent_run = work / "opencode-persistent-throttle"
persistent_run.mkdir()
_, persistent_account, persistent_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", persistent_run, "fixture commit diff"
)
assert persistent_account == "opencode-go" and persistent_result[0] == 1, persistent_result
assert not rb.is_walled("opencode", "opencode-go")
assert transient_left.read_text().strip() == "6", transient_left.read_text()
del os.environ["OPENCODE_TRANSIENT_LEFT_FILE"]
clear_walls()

# A server-side failure is retried on its own budget and, being no statement about quota
# either, leaves the account in the pool once the budget is spent.
server_error_capture = work / "opencode-server-error-profile"
os.environ["OPENCODE_CAPTURE_PROFILE"] = str(server_error_capture)
os.environ["OPENCODE_FIXTURE_RC"] = "1"
os.environ["OPENCODE_FIXTURE_STDERR"] = "HTTP 503 upstream unavailable"
server_error_run = work / "opencode-server-error-run"
server_error_run.mkdir()
_, server_error_account, server_error_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", server_error_run, "fixture commit diff"
)
assert server_error_account == "opencode-go" and server_error_result[0] == 1
assert not rb.is_walled("opencode", "opencode-go")
assert len(server_error_capture.read_text().splitlines()) == 3, \
    server_error_capture.read_text()
del os.environ["OPENCODE_FIXTURE_RC"]
del os.environ["OPENCODE_FIXTURE_STDERR"]
del os.environ["OPENCODE_CAPTURE_PROFILE"]
clear_walls()

# A spent plan is not retried, and the reset it names outlives the flat TTL.
dated_profile_capture = work / "opencode-dated-profile"
os.environ["OPENCODE_CAPTURE_PROFILE"] = str(dated_profile_capture)
os.environ["OPENCODE_FIXTURE_RC"] = "1"
os.environ["OPENCODE_FIXTURE_STDERR"] = (
    'HTTP 429 {"type":"error","error":{"type":"GoUsageLimitError",'
    '"message":"Weekly usage limit reached. Resets in 3 days."}}'
)
dated_run = work / "opencode-dated-run"
dated_run.mkdir()
rb.run_rater_task(opencode_rater, repo, sha, "", dated_run, "fixture commit diff")
assert dated_profile_capture.read_text().splitlines() == ["unset"], \
    dated_profile_capture.read_text()
assert rb.is_walled("opencode", "opencode-go")
dated_key = ("opencode", "opencode-go", "general")
dated_rows = rb.read_wall_rows(rb.state_dir() / rb.WALL_STATE_FILE)
assert dated_rows[dated_key][1] > time.time() + 2 * 86400, dated_rows
os.environ["REVIEW_BENCH_WALL_TTL_S"] = "1"
try:
    assert rb.is_walled("opencode", "opencode-go")
finally:
    del os.environ["REVIEW_BENCH_WALL_TTL_S"]
del os.environ["OPENCODE_FIXTURE_RC"]
del os.environ["OPENCODE_FIXTURE_STDERR"]
del os.environ["OPENCODE_CAPTURE_PROFILE"]
clear_walls()

# An account that walls while the cell sits in the gate queue costs the cell nothing: it was
# never sent, so the cell rotates onto another account instead of failing the side.
profiles_path.write_text("-\nsecond\n")
queued_gate_real = rb.OPENCODE_GATE


class WallWhileQueuedGate:
    def __init__(self):
        self.marked = False

    def acquire(self, *args):
        queued_gate_real.acquire(*args)
        if not self.marked:
            self.marked = True
            rb.mark_walled("opencode", "opencode-go", "general")

    def release(self):
        queued_gate_real.release()


rb.OPENCODE_GATE = WallWhileQueuedGate()
queued_run = work / "opencode-queued-wall"
queued_run.mkdir()
try:
    _, queued_account, queued_result = rb.run_rater_task(
        opencode_rater, repo, sha, "", queued_run, "fixture commit diff"
    )
finally:
    rb.OPENCODE_GATE = queued_gate_real
assert queued_account == "opencode-go-second" and queued_result[0] == 0, queued_result

# The retry budget belongs to the account, not the cell: the default profile spends a whole
# budget on transient answers and then walls, and the spare it rotates onto must still get
# retries of its own rather than being retired on its first hiccup.
clear_walls()
budget_dir = work / "opencode-budget-counters"
budget_dir.mkdir()
(budget_dir / "default").write_text("2\n")
(budget_dir / "second").write_text("2\n")
os.environ["OPENCODE_TRANSIENT_DIR"] = str(budget_dir)
os.environ["OPENCODE_WALL_DEFAULT"] = "1"
budget_run = work / "opencode-budget-run"
budget_run.mkdir()
_, budget_account, budget_result = rb.run_rater_task(
    opencode_rater, repo, sha, "", budget_run, "fixture commit diff"
)
assert budget_account == "opencode-go-second" and budget_result[0] == 0, budget_result
assert (budget_dir / "default").read_text().strip() == "0"
assert (budget_dir / "second").read_text().strip() == "0"
assert rb.is_walled("opencode", "opencode-go")
del os.environ["OPENCODE_WALL_DEFAULT"]
del os.environ["OPENCODE_TRANSIENT_DIR"]

profiles_path.unlink()
clear_walls()
del os.environ["REVIEW_BENCH_TRANSIENT_BACKOFF_S"]

real_subprocess_run = rb.subprocess.run
real_opencode_timeout_s = rb.opencode_timeout_s
timeout_stderr = b"HTTP 429 usage limit reached"


def timeout_run(command, **kwargs):
    raise subprocess.TimeoutExpired(
        command, kwargs["timeout"], output=b"partial output", stderr=timeout_stderr
    )


rb.subprocess.run = timeout_run
rb.opencode_timeout_s = lambda rater: 1
try:
    timeout_wall_run = work / "opencode-timeout-wall"
    timeout_wall_run.mkdir()
    _, timeout_account, timeout_result = rb.run_rater_task(
        opencode_rater, repo, sha, "", timeout_wall_run, "fixture commit diff"
    )
    assert timeout_account == "opencode-go" and timeout_result[0] == 124, timeout_result
    assert "rater timed out after 1s" in timeout_result[3], timeout_result
    assert rb.is_walled("opencode", "opencode-go")

    clear_walls()
    timeout_stderr = b"transport stalled without a response"
    timeout_plain_run = work / "opencode-timeout-plain"
    timeout_plain_run.mkdir()
    _, timeout_account, timeout_result = rb.run_rater_task(
        opencode_rater, repo, sha, "", timeout_plain_run, "fixture commit diff"
    )
    assert timeout_account == "opencode-go" and timeout_result[0] == 124, timeout_result
    assert not rb.is_walled("opencode", "opencode-go")
finally:
    rb.subprocess.run = real_subprocess_run
    rb.opencode_timeout_s = real_opencode_timeout_s
    clear_walls()

# Gemini bills per model and words a per-model exhaustion its own way, so that wording has to
# retire the model on that account and nothing more: a walled 3.1 Pro must leave flash alone.
assert rb.SIDE_WALL["agy"](1, "", "You have exhausted your capacity on this model")
assert rb.SIDE_WALL["agy"](1, "", "Individual quota reached")
assert not rb.SIDE_WALL["agy"](1, "", "jetski: no output produced")
# Antigravity reports that exhaustion only in its log, and the empty-output path turns
# agy_failure_detail into the stderr SIDE_WALL reads: unrecognised there, no rotation happens.
capacity_log = "some progress\nYou have exhausted your capacity on this model\nmore log\n"
assert rb.agy_failure_detail("", capacity_log) == "exhausted your capacity on this model"
assert rb.SIDE_WALL["agy"](
    1, "", f"agy returned empty output: {rb.agy_failure_detail('', capacity_log)}"
)
assert rb.wall_bucket(rb.parse_rater("agy-pro-high-skill")) == "agy-pro"
assert rb.wall_bucket(rb.parse_rater("agy-flash35-medium-skill")) == "agy-flash35"
assert rb.wall_bucket(rb.parse_rater("agy-pro-high-skill")) != \
    rb.wall_bucket(rb.parse_rater("agy-flash35-medium-skill"))
assert rb.wall_bucket(rb.parse_rater("fable-medium")) == "fable"
assert rb.wall_bucket(rb.parse_rater("opus-high")) == "general"
rb.mark_walled("agy", "work", rb.wall_bucket(rb.parse_rater("agy-pro-high-skill")))
assert rb.is_walled("agy", "work", rb.wall_bucket(rb.parse_rater("agy-pro-high-skill")))
assert not rb.is_walled("agy", "work", rb.wall_bucket(rb.parse_rater("agy-flash35-medium-skill")))
clear_walls()

# A run stored under the pre-rename agy id must stay adjudicable, or it is stranded forever.
assert rb.normalize_legacy_rater("agy-flash-low-skill") == "agy-flash36-low-skill"
assert rb.parse_rater(rb.normalize_legacy_rater("agy-flash-low-skill"))["model"] == "agy-flash36"
try:
    rb.parse_rater("agy-flash-low-skill")
except ValueError:
    pass
else:
    raise AssertionError("the legacy id must need normalising, or this guard proves nothing")

clean_run = work / "opencode-clean-run"
clean_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-clean.json")
rc, _, text, stderr, _ = rb.run_opencode(
    opencode_rater, repo, sha, "", clean_run, "fixture commit diff", "opencode-go"
)
assert rc == 0 and rb.normalize_findings(text, "oc-glm52") == []

gate_run = work / "opencode-gate-run"
gate_run.mkdir()
overlap_log = work / "opencode-overlap"
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
os.environ["OPENCODE_CAPTURE_OVERLAP"] = str(overlap_log)
with concurrent.futures.ThreadPoolExecutor(max_workers=5) as gate_pool:
    gate_results = list(gate_pool.map(
        lambda idx: rb.run_opencode(
            opencode_rater, repo, sha, "", gate_run, f"fixture diff {idx}", "opencode-go"
        )[0],
        range(5),
    ))
assert gate_results == [0] * 5
depth = peak = 0
for marker in overlap_log.read_text().split():
    depth += 1 if marker == "enter" else -1
    peak = max(peak, depth)
assert depth == 0 and peak > 0, f"unusable overlap trace: {overlap_log.read_text().split()}"
assert peak <= rb.OPENCODE_MAX_CONCURRENCY, (
    f"gate leaked: peak {peak}, cap {rb.OPENCODE_MAX_CONCURRENCY}, "
    f"seq {overlap_log.read_text().split()}"
)
del os.environ["OPENCODE_CAPTURE_OVERLAP"]

# The gate admits the longest expected job first: a slow cell that waits behind
# fast ones stretches the whole run by its own duration.
priority_gate = rb.PriorityGate(1)
priority_gate.acquire(0)
admitted = []


def claim_slot(priority):
    priority_gate.acquire(priority)
    admitted.append(priority)
    priority_gate.release()


claimants = [threading.Thread(target=claim_slot, args=(p,)) for p in (10, 300, 60)]
for claimant in claimants:
    claimant.start()
queued_by = time.monotonic() + 5
while len(priority_gate.waiting) < 3 and time.monotonic() < queued_by:
    time.sleep(0.01)
assert len(priority_gate.waiting) == 3, priority_gate.waiting
priority_gate.release()
for claimant in claimants:
    claimant.join(10)
assert admitted == [300, 60, 10], admitted
# Priority only orders cells already queued on the gate, so submission itself has to
# be slowest-first; ungated sides sort last because their order changes nothing.
submit_order = sorted(
    [rb.parse_rater(spec) for spec in ("oc-glm52", "oc-grok45-low", "sol-low", "oc-mmm3")],
    key=rb.gate_admission_key,
)
gated = [r for r in submit_order if r["side"] == "opencode"]
assert [r["spec"] for r in submit_order][-1] == "sol-low", submit_order
assert gated == sorted(gated, key=lambda r: -rb.opencode_expected_s(r)), (
    [(r["spec"], rb.opencode_expected_s(r)) for r in gated]
)
assert len(gated) == 3

rejected_run = work / "opencode-rejected-run"
rejected_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
os.environ["OPENCODE_REJECT_MODEL"] = "deepseek-v4-pro"
rc, _, text, stderr, _ = rb.run_opencode(
    effort_rater, repo, sha, "", rejected_run, "fixture commit diff", "opencode-go"
)
assert rc == 2 and not text
assert "not in the OpenCode Go plan" in stderr
del os.environ["OPENCODE_REJECT_MODEL"]

fallback_run = work / "opencode-fallback-run"
fallback_run.mkdir()
os.environ["OPENCODE_MAX_CEILING"] = "8192"
os.environ["OPENCODE_CAPTURE_MAX_TOKENS"] = str(work / "opencode-max-tokens")
rc, _, text, stderr, fallback_command = rb.run_opencode(
    opencode_rater, repo, sha, "", fallback_run, "fixture commit diff", "opencode-go"
)
assert rc == 0 and text and not stderr
assert (work / "opencode-max-tokens").read_text().splitlines() == [
    "32000", "16384", "8192",
]
assert fallback_command[fallback_command.index("--max-tokens") + 1] == "8192"
# A clean review and a rater that answered in prose or stopped mid-turn are the same empty
# findings file; without an explicit marker the second is recorded as the first.
assert rb.CLEAN_REVIEW_MARKER in rb.review_prompt("deadbee", "")
assert rb.CLEAN_REVIEW_MARKER in rb.skill_brief("deadbee", "", "/repo")
assert rb.unusable_review("NO FINDINGS", []) == ""
assert rb.unusable_review('{"findings": []}', []) == ""
assert rb.unusable_review('```json\n{"findings": []}\n```', []) == ""
assert rb.unusable_review("No issues found.", []) == ""
for paraphrase in (
    "I reviewed the diff and found no issues.",
    "No defects found in this commit.",
    "The targeted tests pass, and no actionable regression was identified.",
    "The changes are covered, and no functional regressions were found.",
    "\u0420\u0430\u0437\u0431\u0435\u0440\u0443 \u043a\u043e\u043c\u043c\u0438\u0442 "
    "\u0438 \u0441\u0432\u0435\u0440\u044e \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u044f "
    "\u0441 \u043e\u043a\u0440\u0443\u0436\u0430\u044e\u0449\u0438\u043c "
    "\u043a\u043e\u0434\u043e\u043c.No findings.",
    "Reviewing the commit diff for logic/correctness issues in the changed code.NO FINDINGS",
    "The added tests directly cover successful receipt lookup, confirmed-count aggregation, "
    "and the missing-receipt exit status. The targeted test suite passes, and the change "
    "introduces no functional regression.",
):
    assert rb.unusable_review(paraphrase, []) == "", paraphrase
assert rb.unusable_review("", [{"severity": "P1"}]) == ""
for stopped in ("", "Still waiting for the remaining agents before compiling final findings.",
                "The commit looks reasonable overall; I did not spot anything alarming."):
    assert rb.unusable_review(stopped, []), stopped
assert "(empty answer)" in rb.unusable_review("", [])
# The marker has to be the whole answer; matched anywhere it hands prose a free pass and
# undoes the very distinction it exists to draw.
for rambling in ("I checked the rotation and found no findings for it, but the gate looks wrong.",
                 "No issues found in run_opencode. The verifier, however, never re-checks.",
                 "I reviewed the diff and found no issues. The retry loop drops an account.",
                 "No issues except the retry loop drops an account.",
                 "One real defect was found. No findings.",
                 "Review complete: one finding reported, but no functional bugs found.",
                 "The retry loop drops the account on a single 429 without rescheduling it. "
                 "No other issues found.",
                 "verify_one ignores OPENCODE_WALL and keeps calling a walled account. "
                 "Otherwise no bugs found in this commit.",
                 "Severity P2: receipt path collides for same-named repos. No further findings.",
                 "I could not access the diff, so no findings.",
                 # T1 worktree review of this detector found each of these slipping through:
                 # a newline is a sentence boundary, "though" is a contrast, a praise token
                 # does not vouch for defect prose sharing its sentence.
                 "I found defects in the implementation\nNo findings",
                 "No security issues were found, though the retry logic could exhaust "
                 "resources under load.",
                 "The fix correctly handles X while silently dropping Y. No issues found.",
                 "The retry loop drops requests; no findings.",
                 "No issues found. Authentication handles invalid tokens incorrectly.",
                 "Checked bin/statusline.sh thoroughly.NO FINDINGS",
                 # Round-4 focused re-read: bare infinitive defect verbs, "has defects"
                 # assertions, and defect nouns inside praise sentences all slipped through.
                 "The fix can break requests. No findings",
                 "The implementation has defects. No findings",
                 "No findings. The implementation handles requests, defects remain.",
                 # Round 6: "successfully"/"consistent" are praise, but never vouch for a
                 # sentence carrying a path, a contrast, or a defect verb — and praise alone,
                 # with no negated-defect declaration anywhere, is not a clean review.
                 "No issues found. The write completes successfully. bin/review-bench:70 leaks handles.",
                 "No defects. Consistent naming, but the loop breaks retries.",
                 "The changes are internally consistent, cover the affected review lifecycle "
                 "and statusline behavior, and the relevant review-bench and statusline test "
                 "suites pass.",
                 # A defect noun as a leading label is a finding, not an announcement.
                 "Regression: the cap now misprices commits. No findings.",
                 "Bug: retries drop the account. No findings.",
                 # Round 7 (T2 fix-review adversarials): "while" is a contrast, loss/bypass/
                 # omit inflections are defect claims, and a defect noun in an announce
                 # preamble is a stated finding unless it names what was searched for.
                 "No findings. The retry completes successfully while losing requests.",
                 "No issues. The request successfully bypasses authentication.",
                 "Regression tests pass while omitting the failing case. No findings.",
                 "The migration risks data loss. No findings."):
    assert rb.unusable_review(rambling, []), rambling
assert rb.unusable_review("Checked for bugs and race conditions. No findings.", []) == ""
assert rb.unusable_review("No data loss. No findings.", []) == ""
assert rb.unusable_review("**No issues found.**", []) == ""
assert rb.unusable_review("No problems were found.", []) == ""
assert rb.unusable_review(
    "No actionable correctness issues were identified in the changed code. The relevant "
    "review-bench tests completed successfully, and the remaining changes are consistent "
    "with the documented behavior.", []) == ""
assert rb.unusable_review(
    "No actionable correctness defects were identified in the changed code. The primary "
    "review-bench tests completed successfully, and the remaining changes appear "
    "consistent with their added regression coverage.", []) == ""
# Claude hands over its whole envelope and Codex appends event JSON, so a clean review that
# arrives inside a JSON string still has to count as one.
for enveloped in ('{"type": "result", "subtype": "success", "result": "NO FINDINGS"}',
                  '{"result": "No issues found."}',
                  '{"msg": {"type": "agent_message", "message": "NO FINDINGS"}}',
                  'NO FINDINGS\n{"type":"token_count","info":{"total":10}}'):
    assert rb.unusable_review(enveloped, []) == "", enveloped
# ...while prose inside an envelope stays unusable, exactly as prose outside one does, and only
# the fields that carry the answer are read: a marker in some other field alongside a described
# defect is exactly the free pass the whole-answer rule exists to deny.
assert rb.unusable_review('{"result": "Found no findings there, but the gate looks wrong."}', [])
assert rb.unusable_review(
    '{"status": "NO FINDINGS", "detail": "run_opencode drops the wall before the gate"}', []
)

# Codex writes the location into the prose and leaves `file` empty, which leaves the claim
# with nothing to be read, deduplicated or verified against.
recovered = rb.normalize_findings(json.dumps({
    "severity": "P1", "file": "", "summary":
    "Keep API keys out of raw-request argv — "
    "/private/var/folders/x/review-bench-seal-ab12/bin/opencode-go:332-337",
}), "sol-high")
assert len(recovered) == 1, recovered
assert recovered[0]["file"].endswith("/bin/opencode-go"), recovered
assert recovered[0]["line"] == 332, recovered
assert rb.canonical_finding_path(recovered[0]["file"], ["bin/opencode-go"]) == "bin/opencode-go"
# An extensionless path is the common case in this repository, not the exotic one.
assert rb.normalize_findings("P2 bin/claudeb:88 warm path skips the mutex", "sol-high") == [{
    "severity": "P2", "file": "bin/claudeb", "line": 88,
    "summary": "warm path skips the mutex", "rater": "sol-high",
}]

# The measured refusals live in parse_rater, so a verifier goes through it too — otherwise
# a model refused as a rater is accepted here and sent once per finding.
for refused in sorted(rb.OPENCODE_UNUSABLE_MODELS):
    try:
        rb.verifier_model(refused)
    except ValueError as exc:
        assert "measured unusable" in str(exc), exc
    else:
        raise AssertionError(f"{refused} is measured unusable and cannot verify")
    assert refused not in rb.verifier_choices()
for locked in sorted(rb.OPENCODE_EFFORT_REQUIRED_MODELS):
    try:
        rb.verifier_model(locked)
    except ValueError as exc:
        assert f"{locked}-low" in str(exc), exc
    else:
        raise AssertionError(f"{locked} ignores reasoning suppression and cannot verify")
    assert locked not in rb.verifier_choices()
    try:
        rb.verifier_model(f"{locked}-low")
    except ValueError as exc:
        assert "cannot carry an effort" in str(exc), exc
    else:
        raise AssertionError("the verifier prompt suppresses reasoning; an effort is a lie")
assert rb.verifier_model(rb.OPENCODE_VERIFIER) == rb.OPENCODE_VERIFIER
assert rb.OPENCODE_VERIFIER in rb.verifier_choices()
# A rater runs once, a verifier runs once per finding against a far shorter deadline, so a
# model that cannot answer inside it would time out on every claim and fail them all open.
slow = []
for candidate in rb.OPENCODE_MODEL_IDS:
    try:
        parsed_candidate = rb.parse_rater(candidate)
    except ValueError:
        continue
    if rb.opencode_expected_s(parsed_candidate) > rb.VERIFY_TIMEOUT_S:
        slow.append(candidate)
assert slow, "no in-plan model is slower than the verifier deadline; this guard proves nothing"
for sluggish in slow:
    try:
        rb.verifier_model(sluggish)
    except ValueError as exc:
        assert "would time out" in str(exc), exc
    else:
        raise AssertionError(f"{sluggish} cannot answer inside the verifier deadline")
    assert sluggish not in rb.verifier_choices()
assert all(rb.opencode_expected_s(rb.parse_rater(m)) <= rb.VERIFY_TIMEOUT_S
           for m in rb.verifier_choices())

# The verifier spends the same subscription the cells do, so it obeys the same stop-the-run
# rule; otherwise a wall makes every claim fail open while the run reads as verified.
verify_wall_run = work / "verify-wall"
verify_wall_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
os.environ["OPENCODE_FIXTURE_RC"] = "1"
os.environ["OPENCODE_FIXTURE_STDERR"] = "HTTP 429 usage limit reached"
kept, audit = rb.verify_findings(verify_findings_input, repo, sha, "oc-kimik3", tree)
assert kept == verify_findings_input
assert all(row["kept"] is True and row.get("walled") for row in audit), audit
assert rb.is_walled("opencode", "opencode-go")
del os.environ["OPENCODE_FIXTURE_RC"]
del os.environ["OPENCODE_FIXTURE_STDERR"]
clear_walls()
# A verifier already queued on the gate when the wall is set must not send one more request
# either — the cells got that guard in this commit and the verifier was left without it.
os.environ["OPENCODE_CAPTURE_ARGS"] = str(work / "queued-verify-args")
for _ in range(rb.OPENCODE_MAX_CONCURRENCY):
    rb.OPENCODE_GATE.acquire(0)
queued = {}


def queued_verify():
    queued["row"] = rb.verify_one(0, verify_findings_input[0], repo, sha, "oc-kimik3", None)


verifier_thread = threading.Thread(target=queued_verify)
verifier_thread.start()
blocked_by = time.monotonic() + 5
while not rb.OPENCODE_GATE.waiting and time.monotonic() < blocked_by:
    time.sleep(0.001)
assert rb.OPENCODE_GATE.waiting, "the verifier never reached the gate"
rb.mark_walled("opencode", "opencode-go")
for _ in range(rb.OPENCODE_MAX_CONCURRENCY):
    rb.OPENCODE_GATE.release()
verifier_thread.join(10)
assert queued["row"]["walled"] is True and queued["row"]["kept"] is True, queued
assert "while queued" in queued["row"]["why"], queued
assert not (work / "queued-verify-args").exists(), "a walled verifier still called opencode"

clear_walls()
profiles_path.write_text("-\nsecond\n")
queued_profile_capture = work / "queued-verifier-profile"
os.environ["OPENCODE_CAPTURE_PROFILE"] = str(queued_profile_capture)
for _ in range(rb.OPENCODE_MAX_CONCURRENCY):
    rb.OPENCODE_GATE.acquire(0)
queued_failover = {}


def queued_failover_verify():
    queued_failover["row"] = rb.verify_one(
        0, verify_findings_input[0], repo, sha, "oc-kimik3", None
    )


failover_thread = threading.Thread(target=queued_failover_verify)
failover_thread.start()
blocked_by = time.monotonic() + 5
while not rb.OPENCODE_GATE.waiting and time.monotonic() < blocked_by:
    time.sleep(0.001)
assert rb.OPENCODE_GATE.waiting, "the failover verifier never reached the gate"
rb.mark_walled("opencode", "opencode-go")
for _ in range(rb.OPENCODE_MAX_CONCURRENCY):
    rb.OPENCODE_GATE.release()
failover_thread.join(10)
assert not queued_failover["row"].get("walled"), queued_failover
assert queued_profile_capture.read_text().strip() == "second"
profiles_path.unlink()
del os.environ["OPENCODE_CAPTURE_PROFILE"]
os.environ["OPENCODE_CAPTURE_ARGS"] = str(work / "opencode-args")
# A cell already queued on the gate when the wall was set must not send one more request.
gate_wall_run = work / "opencode-gate-wall"
gate_wall_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
os.environ["OPENCODE_CAPTURE_ARGS"] = str(work / "walled-args")
rc, _, _, walled_stderr, _ = rb.run_opencode(
    opencode_rater, repo, sha, "", gate_wall_run, "fixture commit diff", "opencode-go"
)
assert rc == 1 and "waited for a gate slot" in walled_stderr, walled_stderr
assert not (work / "walled-args").exists()
os.environ["OPENCODE_CAPTURE_ARGS"] = str(work / "opencode-args")
clear_walls()

# Taking a slot also changes who the queue head is, and a waiter blocks on being the head
# as much as on a free slot. A waiter that re-checked just before the head left has no
# wake-up pending, so the second slot sits idle for as long as the first cell runs. The
# interleaving is racy, so it is sampled rather than staged.
for trial in range(80):
    trial_gate = rb.PriorityGate(2)
    trial_gate.acquire(0)
    trial_gate.acquire(0)
    hold, slow_admitted, fast_admitted = threading.Event(), threading.Event(), threading.Event()

    def slow(gate=trial_gate, admitted=slow_admitted, release_when=hold):
        gate.acquire(5)
        admitted.set()
        release_when.wait(10)
        gate.release()

    def fast(gate=trial_gate, admitted=fast_admitted):
        gate.acquire(1)
        admitted.set()
        gate.release()

    racers = [threading.Thread(target=slow), threading.Thread(target=fast)]
    for racer in racers:
        racer.start()
    queued_by = time.monotonic() + 5
    while len(trial_gate.waiting) < 2 and time.monotonic() < queued_by:
        time.sleep(0.001)
    assert len(trial_gate.waiting) == 2, trial_gate.waiting
    trial_gate.release()
    trial_gate.release()
    assert slow_admitted.wait(5), f"trial {trial}: the high-priority cell never started"
    stranded = not fast_admitted.wait(0.5)
    hold.set()
    for racer in racers:
        racer.join(5)
    assert not stranded, f"trial {trial}: the second slot stayed idle while one cell ran"

model_store = work / "model-claudeb"
model_state = model_store / "worker-stats"
os.environ.pop("WORKER_STATS_DIR", None)
os.environ["CLAUDEB_DIR"] = str(model_store)

review_store = work / "review-tier-claudeb"
os.environ["CLAUDEB_DIR"] = str(review_store)
reviewed_cells = []
launch_meta_seen = []


def tier_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    launch_meta_seen.append(json.loads((run_dir / "meta.json").read_text()))
    reviewed_cells.append(rater["spec"])
    if rater["side"] == "opencode":
        return 0, 1, json.dumps({
            "severity": "P2", "file": "pinned.txt", "line": 1,
            "summary": f"{rater['spec']} fixture finding",
        }), "", []
    return 0, 1, "NO FINDINGS", "", []


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = tier_runner
rb.pool_account = lambda side, excluded, slot=0, bucket="general": "fixture"
rb.affordability = lambda: {
    "claude": True, "codex": True, "agy": True, "grok": True, "opencode": True,
    "claude_account": "fixture",
}
rb.check_limits_staleness = lambda account: False
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-verify-keep.json")
review_stdout = io.StringIO()
with contextlib.redirect_stdout(review_stdout):
    review_rc = rb.cmd_review(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_descendant_sha, tier="T1",
        verify=None, focus=None,
    ))
assert review_stdout.getvalue().count(rb.REPORT_BEGIN) == 1
assert review_stdout.getvalue().count(rb.REPORT_END) == 1
review_run_dir = next((review_store / "worker-stats" / "benches").iterdir())
review_meta_path = review_run_dir / "meta.json"
review_meta = json.loads(review_meta_path.read_text())
expected_t1_runs = [
    rater["spec"] for rater in rb.parse_raters(",".join(expected_tier_cells["T1"]))
]
assert review_rc == 0
assert review_meta["tier"] == "T1" and review_meta["max"] is False
assert review_meta["raters"] == expected_t1_runs, review_meta["raters"]
assert review_meta["completed_raters"] == expected_t1_runs
assert sorted(reviewed_cells) == sorted(expected_t1_runs), reviewed_cells
assert all(
    meta["tier"] == "T1"
    and meta["max"] is False
    and meta["raters"] == expected_t1_runs
    and meta["completed_raters"] == []
    and meta["rater_runs"] == []
    for meta in launch_meta_seen
), launch_meta_seen
assert review_meta["verifier"] == "oc-kimik3", \
    f"tier review verifier: {review_meta['verifier']!r}"
review_log_rows = [
    json.loads(line)
    for line in (review_store / "worker-stats" / "review-log.jsonl").read_text().splitlines()
]
assert len(review_log_rows) == 1, review_log_rows
review_log_event = review_log_rows[0]
assert review_log_event["event"] == "run" and review_log_event["tier"] == "T1"
assert review_log_event["run_id"] == review_meta["run_id"]
assert review_log_event["findings"] == 7
assert review_log_event["confirmed"] == review_log_event["duplicate"] == 0
assert review_log_event["false_positive"] == review_log_event["token_estimate"] == 0
assert all(cell["status"] == "completed" for cell in review_log_event["cells"])
for spec in expected_t1_runs:
    if rb.parse_rater(spec.split("#")[0])["side"] == "opencode":
        assert (review_run_dir / f"verified-{spec}.jsonl").exists(), spec
    else:
        assert not (review_run_dir / f"verified-{spec}.jsonl").exists(), spec
review_receipt_path = (
    review_store / "worker-stats" / rb.RECEIPT_DIR
    / rb.receipt_file_name(pin_repo)
)
review_receipt = json.loads(review_receipt_path.read_text())
pin_descendant_tree = subprocess.run(
    ["git", "-C", str(pin_repo), "rev-parse", f"{pin_descendant_sha}^{{tree}}"],
    check=True, capture_output=True, text=True,
).stdout.strip()
assert review_receipt == {
    "repo": str(pin_repo.resolve()), "tree": pin_descendant_tree,
    "commit": pin_descendant_sha,
    "run_id": review_meta["run_id"], "ts": review_receipt["ts"], "errored": 0,
    "panel": len(review_meta["raters"]),
}, review_receipt
assert review_receipt["ts"]

filtered_review_store = work / "filtered-review-claudeb"
os.environ["CLAUDEB_DIR"] = str(filtered_review_store)
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-verify-drop.json")
filtered_stdout = io.StringIO()
with contextlib.redirect_stdout(filtered_stdout):
    assert rb.cmd_review(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_descendant_sha, tier="T0",
        verify=None, focus=None,
    )) == 0
filtered_run = next((filtered_review_store / "worker-stats" / "benches").iterdir())
filtered_meta = json.loads((filtered_run / "meta.json").read_text())
opencode_specs = [
    row["rater"] for row in filtered_meta["rater_runs"]
    if row["side"] == "opencode"
]
assert filtered_meta["verifier"] == rb.OPENCODE_VERIFIER
assert sum(
    row.get("verifier_dropped", 0) for row in filtered_meta["rater_runs"]
) == len(opencode_specs) == 7
assert all(rb.read_jsonl(filtered_run / f"findings-{rater}.jsonl") == []
           for rater in opencode_specs)
assert all(
    len(rb.read_jsonl(filtered_run / f"verified-{rater}.jsonl")) == 1
    and rb.read_jsonl(filtered_run / f"verified-{rater}.jsonl")[0]["kept"] is False
    for rater in opencode_specs
)
filtered_output = filtered_stdout.getvalue()
assert filtered_output.count(rb.REPORT_BEGIN) == filtered_output.count(rb.REPORT_END) == 1
assert all(
    row["verifier_by_model"] == {rb.OPENCODE_VERIFIER: 1} and row["verifier_audited"] == 1
    for row in filtered_meta["rater_runs"] if row["side"] == "opencode"
), filtered_meta["rater_runs"]
# Who judged, not just how many were dropped: the chain advances per finding, so a report
# naming no model leaves the reader unable to tell which verifier produced the rejections.
assert "verifier:  Kimi K3 — 7 checked, 7 rejected" in filtered_output, filtered_output
assert "fixture finding" not in filtered_output
assert rb.bench_summary(filtered_run, filtered_meta)["findings"] == 0

progress_capture_store = work / "progress-capture-claudeb"
os.environ["CLAUDEB_DIR"] = str(progress_capture_store)
(progress_capture_store / "worker-stats").mkdir(parents=True)
(progress_capture_store / "worker-stats" / "reviews.jsonl").write_text(
    json.dumps({"rater": "sol-medium", "duration_ms": 3000}) + "\n"
    + json.dumps({"rater": "sol-medium#2", "duration_ms": 5000}) + "\n"
)
captured_progress = []


def progress_capture_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    progress_files = list(
        (progress_capture_store / "worker-stats" / rb.PROGRESS_DIR).glob("*.json")
    )
    assert len(progress_files) == 1, progress_files
    captured_progress.append(json.loads(progress_files[0].read_text()))
    return 0, 1, "NO FINDINGS", "", []


rb.SIDE_RUNNERS["codex"] = progress_capture_runner
rb.affordability = lambda: {
    "claude": False, "codex": True, "agy": True, "grok": True, "opencode": True,
    "claude_account": None,
}
# time.time() is shifted for this one call so the epoch's origin is provable: cmd_run's start
# datetime comes from datetime.now(), which the shift does not touch, so only a document built
# from a stray second clock read would carry the shifted value.
_real_time = time.time
time.time = lambda: _real_time() + 7200
try:
    assert rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters="sol-medium,opus-medium",
        leg=False, verify=None, auto=None, focus=None,
    )) == 0
finally:
    time.time = _real_time
assert captured_progress[0]["cells"] == ["sol-medium"], captured_progress
assert captured_progress[0]["tier"] is None
# A plain `run` Namespace carries neither attribute, and the progress document is written from
# both without them existing — the reader would drop the file if either came out non-boolean.
assert captured_progress[0]["max"] is False
assert captured_progress[0]["target"] == pin_sha[:7]
assert captured_progress[0]["done"] == [] and captured_progress[0]["failed"] == 0
assert captured_progress[0]["expected"] == {"sol-medium": 4000}, captured_progress[0]
assert isinstance(captured_progress[0]["started_epoch"], int)
# Both start fields must name the same clock read: an epoch stamped separately drifts from the
# ISO string by however long setup took, and the reader's late math inherits the drift. The
# wiring check above ran with time.time() shifted two hours, so a document built from a second
# clock read instead of cmd_run's own start would carry the shifted value and fail here.
import datetime as _dt
assert abs(captured_progress[0]["started_epoch"] - int(
    _dt.datetime.fromisoformat(captured_progress[0]["started"]).timestamp()
)) <= 2, captured_progress[0]
_past = "2026-01-01T00:00:00+00:00"
_past_doc = rb.review_progress_document(
    str(pin_repo), "epoch-rid", None, "t", [], started=_past,
    started_epoch=_dt.datetime.fromisoformat(_past).timestamp(),
)
assert _past_doc["started_epoch"] == int(
    _dt.datetime.fromisoformat(_past).timestamp()
), _past_doc
assert not list(
    (progress_capture_store / "worker-stats" / rb.PROGRESS_DIR).glob("*.json")
)
# cmd_review hands its own Namespace to cmd_run, so the variant it was asked for has to survive
# the trip: the statusline names it from this file and from nothing else.
assert rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, raters="sol-medium",
    leg=False, verify=None, auto=None, focus=None, tier="T2", max=True, foreground=True,
)) == 0
assert captured_progress[1]["tier"] == "T2" and captured_progress[1]["max"] is True, \
    captured_progress[1]
rb.SIDE_RUNNERS["codex"] = tier_runner
rb.affordability = lambda: {
    "claude": True, "codex": True, "agy": True, "grok": True, "opencode": True,
    "claude_account": "fixture",
}

worktree_run_store = work / "worktree-run-claudeb"
os.environ["CLAUDEB_DIR"] = str(worktree_run_store)
worktree_stdout = io.StringIO()
with contextlib.redirect_stdout(worktree_stdout):
    worktree_rc = rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=None, worktree=True, raters="sol-medium",
        leg=False, verify=None, auto=None, focus=None,
    ))
worktree_run_dir = next(
    (worktree_run_store / "worker-stats" / "benches").iterdir()
)
worktree_meta = json.loads((worktree_run_dir / "meta.json").read_text())
worktree_receipt = json.loads((
    worktree_run_store / "worker-stats" / rb.RECEIPT_DIR
    / rb.receipt_file_name(pin_repo)
).read_text())
assert worktree_rc == 0
assert worktree_meta["worktree"] is True
assert worktree_meta["commit"] == snapshot_sha
assert worktree_receipt["commit"] == snapshot_sha
assert worktree_receipt["tree"] == snapshot_tree
assert (
    f"Record exactly with: review-bench record {worktree_meta['run_id']} "
    f"--verdicts /tmp/review-bench-{worktree_meta['run_id']}-verdicts.jsonl"
) in worktree_stdout.getvalue()
assert "Merge and deduplicate the findings blind." in worktree_stdout.getvalue()
progress_run_dir = worktree_run_store / "worker-stats" / rb.PROGRESS_DIR
assert not list(progress_run_dir.glob("*.json")), list(progress_run_dir.glob("*.json"))

assert rb.is_worktree_snapshot(pin_repo, snapshot_sha)
assert not rb.is_worktree_snapshot(pin_repo, pin_sha)


def snapshot_rerun_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    if rater["spec"] == "sol-high":
        return 1, 1, "", "fixture rater failure", []
    return tier_runner(rater, repo_path, commit, focus, run_dir, diff, account)


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = snapshot_rerun_runner
snapshot_rerun_store = work / "snapshot-rerun-claudeb"
os.environ["CLAUDEB_DIR"] = str(snapshot_rerun_store)
snapshot_rerun_stdout = io.StringIO()
with contextlib.redirect_stdout(snapshot_rerun_stdout):
    snapshot_rerun_rc = rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=snapshot_sha, raters="sol-medium,sol-high",
        leg=False, verify=None, auto=None, focus=None,
    ))
snapshot_rerun_run_dir = next(
    (snapshot_rerun_store / "worker-stats" / "benches").iterdir()
)
snapshot_rerun_meta = json.loads((snapshot_rerun_run_dir / "meta.json").read_text())
assert snapshot_rerun_rc == 1
assert snapshot_rerun_meta["worktree"] is True, snapshot_rerun_meta
assert f"rerun: review-bench run {snapshot_sha} --raters sol-high" \
    in snapshot_rerun_stdout.getvalue(), snapshot_rerun_stdout.getvalue()
assert (
    f"Record exactly with: review-bench record {snapshot_rerun_meta['run_id']} "
    f"--verdicts /tmp/review-bench-{snapshot_rerun_meta['run_id']}-verdicts.jsonl"
) in snapshot_rerun_stdout.getvalue()
# The panel decides the verifier default, so a rerun of one cell that omits the flag filters
# findings the run it completes reported raw — while a rerun holding no OpenCode cell is refused
# outright if the flag is passed, so the reproduce line carries it only where it applies.
assert "--verify" not in snapshot_rerun_stdout.getvalue().split("rerun:")[1].splitlines()[0]


def oc_rerun_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    return 1, 1, "", "fixture rater failure", []


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = oc_rerun_runner
for oc_rerun_name, oc_rerun_flag, oc_rerun_no_verify in (
    ("default", "--verify oc-kimik3", False),
    ("raw", "--no-verify", True),
):
    oc_rerun_store = work / f"oc-rerun-{oc_rerun_name}-claudeb"
    os.environ["CLAUDEB_DIR"] = str(oc_rerun_store)
    oc_rerun_stdout = io.StringIO()
    with contextlib.redirect_stdout(oc_rerun_stdout):
        rb.cmd_run(argparse.Namespace(
            repo=str(pin_repo), commitish=pin_sha, raters="oc-kimik3,sol-medium",
            leg=False, verify=None, no_verify=oc_rerun_no_verify, auto=None, focus=None,
        ))
    assert f"rerun: review-bench run {pin_sha} --raters oc-kimik3,sol-medium " \
        f"{oc_rerun_flag}" in oc_rerun_stdout.getvalue(), oc_rerun_stdout.getvalue()
for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = tier_runner

collision_left = work / "receipt-collision-left" / "same-name"
collision_right = work / "receipt-collision-right" / "same-name"
for collision_repo in (collision_left, collision_right):
    collision_repo.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(collision_repo)], check=True)
collision_names = {
    rb.receipt_file_name(collision_left), rb.receipt_file_name(collision_right),
}
assert len(collision_names) == 2, collision_names
assert all(name.startswith("same-name__") and len(name) == len("same-name__.json") + 8
           for name in collision_names), collision_names

progress_name = rb.progress_file_name(pin_repo, 12345)
assert progress_name == rb.receipt_file_name(pin_repo)[:-5] + "-12345.json", progress_name
progress_epoch_min = int(time.time())
progress = rb.review_progress_document(
    pin_repo, "20260727T120000Z-2ecc0bd", "T2", "2ecc0bd",
    ["oc-kimik3", "sol-low"],
    started="2026-07-27T12:00:00+00:00", pid=12345,
    expected={"oc-kimik3": 23000},
)
progress_epoch_max = int(time.time())
assert progress == {
    "repo": str(pin_repo.resolve()),
    "pid": 12345,
    "run_id": "20260727T120000Z-2ecc0bd",
    "tier": "T2",
    "max": False,
    "target": "2ecc0bd",
    "cells": ["oc-kimik3", "sol-low"],
    "done": [],
    "expected": {"oc-kimik3": 23000},
    "failed": 0,
    "started": "2026-07-27T12:00:00+00:00",
    "started_epoch": progress["started_epoch"],
    "ts": "2026-07-27T12:00:00+00:00",
}, progress
assert progress_epoch_min <= progress["started_epoch"] <= progress_epoch_max
# The statusline reads this to tell a T2 max panel from a T2 one, and it validates the key as a
# boolean: a truthy flag object passed straight through would be dropped as a corrupt file.
max_progress = rb.review_progress_document(
    pin_repo, "20260727T120000Z-2ecc0bd", "T2", "2ecc0bd", ["oc-kimik3"],
    started="2026-07-27T12:00:00+00:00", pid=12345, max_panel="yes",
)
assert max_progress["max"] is True, max_progress
rb.complete_review_progress(
    progress, "sol-low", True, timestamp="2026-07-27T12:03:11+00:00",
)
assert progress["done"] == ["sol-low"] and progress["failed"] == 1
assert progress["ts"] == "2026-07-27T12:03:11+00:00"
progress_dir = work / "progress-helpers"
progress_path = progress_dir / progress_name
rb.persist_review_progress(
    progress_path, progress, timestamp="2026-07-27T12:04:00+00:00",
)
assert json.loads(progress_path.read_text())["ts"] == "2026-07-27T12:04:00+00:00"
dead_pid = 99999999
try:
    os.kill(dead_pid, 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError(f"fixture pid unexpectedly alive: {dead_pid}")
dead_progress = progress_dir / rb.progress_file_name(pin_repo, dead_pid)
live_progress = progress_dir / rb.progress_file_name(pin_repo, live_shell_pid)
dead_progress.write_text("{}\n")
live_progress.write_text("{}\n")
rb.prune_review_progress(pin_repo, progress_dir)
assert not dead_progress.exists()
assert live_progress.exists()

metachar_repo = work / "prune-meta[char]-repo"
metachar_repo.mkdir()
subprocess.run(["git", "init", "-q", str(metachar_repo)], check=True)
metachar_dir = work / "prune-metachar-progress"
metachar_dead = metachar_dir / rb.progress_file_name(metachar_repo, dead_pid)
metachar_dir.mkdir()
metachar_dead.write_text("{}\n")
rb.prune_review_progress(metachar_repo, metachar_dir)
assert not metachar_dead.exists()

stamp_repo = work / "reviewed-repo"
stamp_repo.mkdir()
subprocess.run(["git", "-C", str(stamp_repo), "init", "-q", "-b", "main"], check=True)
(stamp_repo / "tracked.txt").write_text("base\n")
subprocess.run(["git", "-C", str(stamp_repo), "add", "tracked.txt"], check=True)
subprocess.run(
    ["git", "-C", str(stamp_repo), "-c", "user.name=Fixture",
     "-c", "user.email=fixture@example.com", "commit", "-qm", "initial"],
    check=True,
)
(stamp_repo / "tracked.txt").write_text("dirty\n")
(stamp_repo / "untracked.txt").write_text("new\n")
stamp_store = work / "reviewed-store"
stamp_env = dict(os.environ, WORKER_STATS_DIR=str(stamp_store))
with tempfile.TemporaryDirectory(dir=work) as index_dir:
    expected_env = dict(stamp_env, GIT_INDEX_FILE=str(pathlib.Path(index_dir) / "index"))
    subprocess.run(
        ["git", "-C", str(stamp_repo), "read-tree", "HEAD"],
        check=True, env=expected_env,
    )
    subprocess.run(
        ["git", "-C", str(stamp_repo), "add", "-A"],
        check=True, env=expected_env,
    )
    expected_stamp_tree = subprocess.run(
        ["git", "-C", str(stamp_repo), "write-tree"],
        check=True, capture_output=True, text=True, env=expected_env,
    ).stdout.strip()
stamp_proc = subprocess.run(
    [sys.argv[1], "reviewed", "--repo", str(stamp_repo)],
    capture_output=True, text=True, env=stamp_env,
)
stamp_receipt_path = (
    stamp_store / rb.RECEIPT_DIR / rb.receipt_file_name(stamp_repo)
)
stamp_receipt = json.loads(stamp_receipt_path.read_text())
stamp_head = subprocess.run(
    ["git", "-C", str(stamp_repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True,
).stdout.strip()
assert stamp_proc.returncode == 0, stamp_proc.stderr
assert stamp_receipt == {
    "repo": str(stamp_repo.resolve()), "tree": expected_stamp_tree,
    "commit": stamp_head, "run_id": stamp_receipt["run_id"],
    "ts": stamp_receipt["ts"], "errored": 0,
}, stamp_receipt
assert re.fullmatch(r"stamped-\d{8}T\d{6}Z", stamp_receipt["run_id"])
assert str(stamp_receipt_path) in stamp_proc.stdout
assert expected_stamp_tree[:7] in stamp_proc.stdout
saved_stats_dir = os.environ.get("WORKER_STATS_DIR")
os.environ["WORKER_STATS_DIR"] = str(stamp_store)
assert rb.review_receipt(stamp_repo)["tree"] == expected_stamp_tree
if saved_stats_dir is None:
    os.environ.pop("WORKER_STATS_DIR")
else:
    os.environ["WORKER_STATS_DIR"] = saved_stats_dir

# The stamp hook reads the receipt through this command rather than deriving its path a third
# time, and it decides on the confirmed count the run was adjudicated to.
receipt_proc = subprocess.run(
    [sys.argv[1], "receipt", "--repo", str(stamp_repo)],
    capture_output=True, text=True, env=stamp_env,
)
assert receipt_proc.returncode == 0, receipt_proc.stderr
receipt_json = json.loads(receipt_proc.stdout)
assert receipt_json["tree"] == expected_stamp_tree
assert receipt_json["confirmed"] == 0, receipt_json
(stamp_store / "reviews.jsonl").write_text("\n".join(
    json.dumps({"run_id": stamp_receipt["run_id"], "rater": rater, "confirmed": count})
    for rater, count in (("sol-low", 2), ("oc-kimik3", 1))
) + "\n")
assert json.loads(subprocess.run(
    [sys.argv[1], "receipt", "--repo", str(stamp_repo)],
    check=True, capture_output=True, text=True, env=stamp_env,
).stdout)["confirmed"] == 3
assert subprocess.run(
    [sys.argv[1], "receipt", "--repo", str(pin_repo)],
    capture_output=True, text=True, env=dict(os.environ, WORKER_STATS_DIR=str(work / "empty-store")),
).returncode == 1

nonrepo = work / "reviewed-nonrepo"
nonrepo.mkdir()
nonrepo_store = work / "reviewed-nonrepo-store"
nonrepo_proc = subprocess.run(
    [sys.argv[1], "reviewed", "--repo", str(nonrepo)],
    capture_output=True, text=True,
    env=dict(os.environ, WORKER_STATS_DIR=str(nonrepo_store)),
)
assert nonrepo_proc.returncode != 0
assert "not a git repository" in nonrepo_proc.stderr
assert not nonrepo_store.exists(), list(nonrepo_store.rglob("*")) \
    if nonrepo_store.exists() else []

# The verifier is on unless refused: every one of its failure paths keeps the finding, so the
# cost of having it is a minute and the cost of not having it is unchecked claims read in full.
raw_opencode_store = work / "raw-opencode-claudeb"
os.environ["CLAUDEB_DIR"] = str(raw_opencode_store)
raw_opencode_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, raters="oc-kimik3,oc-grok45-low",
    leg=False, verify=None, no_verify=False, auto=None, focus=None,
))
raw_opencode_run = next((raw_opencode_store / "worker-stats" / "benches").iterdir())
raw_opencode_meta = json.loads((raw_opencode_run / "meta.json").read_text())
assert raw_opencode_rc == 0, raw_opencode_meta
assert raw_opencode_meta["verifier"] == rb.OPENCODE_VERIFIER, \
    f"raw run verifier: {raw_opencode_meta['verifier']!r}"

refused_verify_store = work / "refused-verify-claudeb"
os.environ["CLAUDEB_DIR"] = str(refused_verify_store)
refused_verify_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, raters="oc-kimik3,oc-grok45-low",
    leg=False, verify=None, no_verify=True, auto=None, focus=None,
))
refused_verify_run = next((refused_verify_store / "worker-stats" / "benches").iterdir())
refused_verify_meta = json.loads((refused_verify_run / "meta.json").read_text())
assert refused_verify_rc == 0, refused_verify_meta
assert refused_verify_meta["verifier"] == "", refused_verify_meta["verifier"]
assert not list(refused_verify_run.glob("verified-*.jsonl")), \
    "a refused verifier wrote verified artifacts"

# Asking for it where it cannot apply is an error; defaulting into that would refuse every run
# whose composition happens to have no OpenCode cell.
no_oc_store = work / "no-opencode-claudeb"
os.environ["CLAUDEB_DIR"] = str(no_oc_store)
no_oc_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, raters="sol-low",
    leg=False, verify=None, no_verify=False, auto=None, focus=None,
))
no_oc_meta = json.loads(
    (next((no_oc_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert no_oc_rc == 0, no_oc_meta
assert no_oc_meta["verifier"] == "", no_oc_meta["verifier"]

explicit_verify_store = work / "explicit-review-verify-claudeb"
os.environ["CLAUDEB_DIR"] = str(explicit_verify_store)
explicit_verify_rc = rb.cmd_review(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, tier="T0",
    verify="oc-mimo25", focus=None,
))
explicit_verify_run = next(
    (explicit_verify_store / "worker-stats" / "benches").iterdir()
)
explicit_verify_meta = json.loads((explicit_verify_run / "meta.json").read_text())
assert explicit_verify_rc == 0, explicit_verify_meta
assert explicit_verify_meta["verifier"] == "oc-mimo25", \
    f"explicit review verifier: {explicit_verify_meta['verifier']!r}"

repeat_store = work / "dispatcher-repeat-claudeb"
os.environ["CLAUDEB_DIR"] = str(repeat_store)
account_picks = []


def dispatcher_repeat_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    duration = 101 if rater["spec"] == "sol-medium" else 202
    envelope = {
        "type": "result",
        "result": json.dumps({"findings": [{
            "severity": "P3", "file": "pinned.txt", "line": 1,
            "summary": f"{rater['spec']} fixture finding",
        }]}),
        "attempt": rater["spec"],
    }
    text = json.dumps(envelope)
    (run_dir / f"raw-{rater['spec']}.json").write_text(text)
    return 0, duration, text, "", ["fake", rater["spec"]]


def dispatcher_repeat_account(side, excluded, slot=0, bucket="general"):
    account_picks.append((side, tuple(sorted(excluded))))
    return "fixture"


rb.SIDE_RUNNERS["codex"] = dispatcher_repeat_runner
rb.pool_account = dispatcher_repeat_account
rb.affordability = lambda: {
    "claude": False, "codex": True, "agy": True, "grok": True, "opencode": True,
    "claude_account": None,
}
repeat_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, raters="sol-medium x2",
    leg=False, verify=None, auto=None, focus=None,
))
repeat_run_dir = next((repeat_store / "worker-stats" / "benches").iterdir())
repeat_meta = json.loads((repeat_run_dir / "meta.json").read_text())
assert repeat_rc == 0
assert repeat_meta["raters"] == ["sol-medium", "sol-medium#2"], repeat_meta
assert [row["rater"] for row in repeat_meta["rater_runs"]] == [
    "sol-medium", "sol-medium#2",
], repeat_meta["rater_runs"]
assert repeat_meta["durations"] == {"sol-medium": 101, "sol-medium#2": 202}
assert len(account_picks) == 2, account_picks
for rater in ("sol-medium", "sol-medium#2"):
    raw = repeat_run_dir / f"raw-{rater}.json"
    findings = repeat_run_dir / f"findings-{rater}.jsonl"
    assert raw.exists() and findings.exists(), rater
    assert json.loads(raw.read_text())["attempt"] == rater
    rows = [json.loads(line) for line in findings.read_text().splitlines()]
    assert len(rows) == 1 and rows[0]["rater"] == rater, rows
assert (
    (repeat_run_dir / "raw-sol-medium.json").read_text()
    != (repeat_run_dir / "raw-sol-medium#2.json").read_text()
)
repeat_verdicts = work / "dispatcher-repeat-verdicts.jsonl"
repeat_verdicts.write_text(
    "\n".join(
        json.dumps({"rater": rater, "idx": 0, "verdict": "confirmed"})
        for rater in ("sol-medium", "sol-medium#2")
    ) + "\n"
)
repeat_record_stdout = io.StringIO()
with contextlib.redirect_stdout(repeat_record_stdout):
    assert rb.cmd_record(argparse.Namespace(
        run_id=repeat_meta["run_id"], verdicts=str(repeat_verdicts),
    )) == 0
assert "confirmed 2:" in repeat_record_stdout.getvalue()
assert "not adjudicated" not in repeat_record_stdout.getvalue()
repeat_corpus = rb.read_jsonl(repeat_store / "worker-stats" / "reviews.jsonl")
assert [row["rater"] for row in repeat_corpus] == ["sol-medium", "sol-medium#2"], repeat_corpus

worktree_record_dir = (
    repeat_store / "worker-stats" / "benches" / "worktree-record-fixture"
)
worktree_record_dir.mkdir()
(worktree_record_dir / "meta.json").write_text(json.dumps({
    "run_id": "worktree-record-fixture",
    "commit": snapshot_sha,
    "repo": str(pin_repo),
    "raters": [],
    "worktree": True,
}) + "\n")
empty_verdicts = work / "worktree-empty-verdicts.jsonl"
empty_verdicts.write_text("")
worktree_record_stdout = io.StringIO()
with contextlib.redirect_stdout(worktree_record_stdout):
    assert rb.cmd_record(argparse.Namespace(
        run_id="worktree-record-fixture", verdicts=str(empty_verdicts),
    )) == 0
assert "corpus skipped" in worktree_record_stdout.getvalue()
assert worktree_record_stdout.getvalue().count(rb.REPORT_BEGIN) == 1
assert worktree_record_stdout.getvalue().count(rb.REPORT_END) == 1
assert not (worktree_record_dir / "defects.jsonl").exists()
assert (worktree_record_dir / "verdicts.jsonl").read_text() == ""
assert [row["rater"] for row in rb.read_jsonl(
    repeat_store / "worker-stats" / "reviews.jsonl"
)] == ["sol-medium", "sol-medium#2"]

# A fix round's own triage is what makes the end-of-round report readable, and it is judged
# against a checkout that already holds the fixes — a different ruler from the two sealed judges
# reviews.jsonl is built on. So it is reported and dropped: every state between pending and
# adjudicated is read by something, and a verdict file with no corpus row is read as a review
# that found nothing by `list`, `cluster` and the receipt logic alike.
no_corpus_dir = repeat_store / "worker-stats" / "benches" / "no-corpus-fixture"
no_corpus_dir.mkdir()
(no_corpus_dir / "meta.json").write_text(json.dumps({
    "run_id": "no-corpus-fixture", "commit": pin_sha, "repo": str(pin_repo),
    "raters": ["sol-medium"], "completed_raters": ["sol-medium"],
    "rater_runs": [{"rater": "sol-medium", "exit_code": 0, "findings": 2}],
}) + "\n")
rb.write_jsonl(no_corpus_dir / "findings-sol-medium.jsonl", [
    {"file": "a.py", "line": 1, "severity": "P1", "summary": "real"},
    {"file": "b.py", "line": 2, "severity": "P3", "summary": "noise"},
])
no_corpus_verdicts = work / "no-corpus-verdicts.jsonl"
rb.write_jsonl(no_corpus_verdicts, [
    {"rater": "sol-medium", "idx": 0, "verdict": "confirmed"},
    {"rater": "sol-medium", "idx": 1, "verdict": "false_positive"},
])
no_corpus_stdout = io.StringIO()
with contextlib.redirect_stdout(no_corpus_stdout):
    assert rb.cmd_record(argparse.Namespace(
        run_id="no-corpus-fixture", verdicts=str(no_corpus_verdicts), no_corpus=True,
    )) == 0
# The verdicts reach the report without reaching the disk: printing the pre-adjudication shape
# here is what sent the reader back to a list of cells, which is why the flag exists.
assert "confirmed 1:  P1 1" in no_corpus_stdout.getvalue(), no_corpus_stdout.getvalue()
assert "recorded nothing; this run's stored state is unchanged" in \
    no_corpus_stdout.getvalue(), no_corpus_stdout.getvalue()
assert no_corpus_stdout.getvalue().count(rb.REPORT_BEGIN) == 1
assert not (no_corpus_dir / "verdicts.jsonl").exists(), "a verdict file was left behind"
# Handed-in rows go through the same schema filter as a file's: nothing stops a caller passing
# raw triage notes, and an unfiltered row would be counted under a verdict that does not exist.
assert rb.bench_summary(no_corpus_dir, json.loads(
    (no_corpus_dir / "meta.json").read_text()
), [
    {"rater": "sol-medium", "idx": 0, "verdict": "confirmed"},
    {"rater": "sol-medium", "idx": 1, "verdict": "maybe"},
    {"idx": 1, "verdict": "confirmed"},
])["confirmed"] == 1
assert not (no_corpus_dir / "defects.jsonl").exists(), "a defect file was left behind"
assert [row["rater"] for row in rb.read_jsonl(
    repeat_store / "worker-stats" / "reviews.jsonl"
)] == ["sol-medium", "sol-medium#2"]
# The reason is not interchangeable: a worktree run says why its snapshot cannot be a corpus row,
# and reading the flag's wording there would deny the durable-commit rule it actually followed.
assert "worktree snapshots are not durable corpus commits" in \
    worktree_record_stdout.getvalue(), worktree_record_stdout.getvalue()
# A run that was properly adjudicated keeps both its verdict file and its corpus rows when a
# later fix round reports over it: rewriting the file alone would leave the rows built from
# verdicts nobody can read, and the ordinary record that should replace them keys on the file
# having changed — it would find it already matching, so the stale rows would stand for good.
recorded_no_corpus_dir = (
    repeat_store / "worker-stats" / "benches" / "recorded-no-corpus-fixture"
)
recorded_no_corpus_dir.mkdir()
(recorded_no_corpus_dir / "meta.json").write_text(json.dumps({
    "run_id": "recorded-no-corpus-fixture", "commit": pin_sha, "repo": str(pin_repo),
    "raters": ["sol-medium"], "completed_raters": ["sol-medium"],
    "rater_runs": [{"rater": "sol-medium", "exit_code": 0, "findings": 1}],
}) + "\n")
rb.write_jsonl(recorded_no_corpus_dir / "findings-sol-medium.jsonl", [
    {"file": "a.py", "line": 1, "severity": "P2", "summary": "sealed judges called it true"},
])
rb.write_jsonl(recorded_no_corpus_dir / "verdicts.jsonl", [
    {"rater": "sol-medium", "idx": 0, "verdict": "confirmed"},
])
recorded_reviews = rb.read_jsonl(repeat_store / "worker-stats" / "reviews.jsonl")
rb.write_jsonl(repeat_store / "worker-stats" / "reviews.jsonl", recorded_reviews + [
    {"run_id": "recorded-no-corpus-fixture", "rater": "sol-medium", "confirmed": 1},
])
rb.write_jsonl(work / "recorded-no-corpus-verdicts.jsonl", [
    {"rater": "sol-medium", "idx": 0, "verdict": "false_positive"},
])
recorded_no_corpus_stdout = io.StringIO()
with contextlib.redirect_stdout(recorded_no_corpus_stdout):
    assert rb.cmd_record(argparse.Namespace(
        run_id="recorded-no-corpus-fixture",
        verdicts=str(work / "recorded-no-corpus-verdicts.jsonl"), no_corpus=True,
    )) == 0
# The report printed beside it is the handed-in triage, and none of it reaches the run.
assert "recorded nothing" in recorded_no_corpus_stdout.getvalue(), \
    recorded_no_corpus_stdout.getvalue()
assert rb.read_jsonl(recorded_no_corpus_dir / "verdicts.jsonl") == [
    {"rater": "sol-medium", "idx": 0, "verdict": "confirmed"}
], rb.read_jsonl(recorded_no_corpus_dir / "verdicts.jsonl")
assert [row.get("confirmed") for row in rb.read_jsonl(
    repeat_store / "worker-stats" / "reviews.jsonl"
) if row.get("run_id") == "recorded-no-corpus-fixture"] == [1]

verify_timing_store = work / "verify-timing-claudeb"
os.environ["CLAUDEB_DIR"] = str(verify_timing_store)
os.environ["OPENCODE_CAPTURE_ARGS"] = str(work / "verify-timing-args")
os.environ["OPENCODE_CAPTURE_PROMPT"] = str(work / "verify-timing-prompt")
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-verify-keep.json")
try:
    rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters="sol-medium",
        leg=False, verify="oc-kimik3", auto=None, focus=None,
    ))
except RuntimeError as exc:
    assert "no OpenCode cell" in str(exc), exc
else:
    raise AssertionError("--verify accepted a run with no OpenCode cell")
verify_timing_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, raters="oc-kimik3",
    leg=False, verify="oc-kimik3", auto=None, focus=None,
))
verify_timing_run = next((verify_timing_store / "worker-stats" / "benches").iterdir())
verify_timing_meta = json.loads((verify_timing_run / "meta.json").read_text())
verify_timing_entry = verify_timing_meta["rater_runs"][0]
assert verify_timing_rc == 0 and type(verify_timing_entry.get("verify_ms")) is int, \
    verify_timing_entry
verify_timing_verdicts = work / "verify-timing-verdicts.jsonl"
verify_timing_verdicts.write_text(json.dumps({
    "rater": "oc-kimik3", "idx": 0, "verdict": "confirmed",
}) + "\n")
assert rb.cmd_record(argparse.Namespace(
    run_id=verify_timing_meta["run_id"], verdicts=str(verify_timing_verdicts),
)) == 0
verify_timing_corpus = rb.read_jsonl(
    verify_timing_store / "worker-stats" / "reviews.jsonl"
)
assert verify_timing_corpus[0]["verify_ms"] == verify_timing_entry["verify_ms"], \
    verify_timing_corpus
(work / "verify-ms-ok").touch()

assert rb.collapse_rater_attempts(
    ["sol-high", "sol-high#2"]
) == ["sol-high x2"]
assert [rater["spec"] for rater in rb.parse_raters("sol-high x2")] == [
    "sol-high", "sol-high#2",
]


def dispatcher_rerun_runner(rater, *args, **kwargs):
    if rater["spec"] == "sol-high#2":
        return 1, 303, "", "fixture failure", ["fake", rater["spec"]]
    return dispatcher_repeat_runner(rater, *args, **kwargs)


rerun_store = work / "dispatcher-rerun-claudeb"
os.environ["CLAUDEB_DIR"] = str(rerun_store)
rb.SIDE_RUNNERS["codex"] = dispatcher_rerun_runner
rerun_stdout = io.StringIO()
with contextlib.redirect_stdout(rerun_stdout):
    rerun_rc = rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters="sol-high x2",
        leg=False, verify=None, auto=None, focus=None,
    ))
rerun_output = rerun_stdout.getvalue()
rerun_arg = next(
    line.split("--raters ", 1)[1]
    for line in rerun_output.splitlines()
    if line.startswith("rerun: review-bench run ")
)
rerun_values = shlex.split(rerun_arg)
assert rerun_rc == 1 and "ERRORED (not recorded): sol-high#2" in rerun_output, rerun_output
assert rerun_output.count(rb.REPORT_BEGIN) == rerun_output.count(rb.REPORT_END) == 1
assert len(rerun_values) == 1
assert [rater["spec"] for rater in rb.parse_raters(rerun_values[0])] == ["sol-high"]
print("dispatcher-rater-repeat-ok")

os.environ["CLAUDEB_DIR"] = str(model_store)


def model_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    if rater["model"] == "sonnet":
        return 1, 1, "", "fixture failure", ["fake"]
    envelope = {
        "type": "result",
        "result": json.dumps({"findings": [{
            "severity": "P3", "file": "pinned.txt", "line": 1,
            "summary": f"{rater['model']} fixture finding",
        }]}),
    }
    if rater["model"] == "opus":
        envelope["modelUsage"] = {
            "claude-opus-5": {"canonicalModel": "claude-opus-5"}
        }
    text = json.dumps(envelope)
    (run_dir / f"raw-{rater['spec']}.json").write_text(text)
    return 0, 1, text, "", ["fake"]

rb.SIDE_RUNNERS["claude"] = model_runner
rb.pool_account = lambda side, excluded, slot=0, bucket="general": "fixture"
rb.affordability = lambda: {
    "claude": True, "codex": False, "claude_account": "fixture",
}
rb.check_limits_staleness = lambda account: False
run_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_descendant_sha,
    raters="opus-medium,sonnet-medium-skill", leg=False, verify=None,
    auto=None, focus=None,
))
model_meta_path = next((model_state / "benches").glob("*/meta.json"))
model_meta = json.loads(model_meta_path.read_text())
model_runs = {
    row["rater"]: row
    for row in model_meta["rater_runs"]
}
assert (
    run_rc == 1
    and model_meta["raters"] == ["opus-medium", "sonnet-medium-skill"]
    and model_meta["completed_raters"] == ["opus-medium"]
    and model_runs["sonnet-medium-skill"].get("errored") is True
    and model_runs["opus-medium"].get("model_resolved") == "claude-opus-5"
    and "model_resolved" not in model_runs["sonnet-medium-skill"]
), model_runs

model_receipt_path = (
    model_store / "worker-stats" / rb.RECEIPT_DIR / rb.receipt_file_name(pin_repo)
)
model_receipt = json.loads(model_receipt_path.read_text())
assert model_receipt["errored"] == 1, \
    f"partial receipt errored: {model_receipt['errored']}"
successful_receipt_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_descendant_sha,
    raters="opus-medium", leg=False, verify=None,
    auto=None, focus=None,
))
successful_receipt = json.loads(model_receipt_path.read_text())
assert successful_receipt_rc == 0 and successful_receipt["errored"] == 0, \
    f"successful receipt: rc={successful_receipt_rc}, errored={successful_receipt['errored']}"
model_receipt_path.unlink()
time.sleep(1.1)
all_error_before = set((model_store / "worker-stats" / "benches").iterdir())
all_error_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_descendant_sha,
    raters="sonnet-medium-skill", leg=False, verify=None,
    auto=None, focus=None,
))
all_error_after = set((model_store / "worker-stats" / "benches").iterdir())
all_error_run_dir, = all_error_after - all_error_before
all_error_meta_path = all_error_run_dir / "meta.json"
all_error_meta = json.loads(all_error_meta_path.read_text())
assert (
    all_error_rc == 1
    and all_error_meta["raters"] == ["sonnet-medium-skill"]
    and all_error_meta["completed_raters"] == []
), all_error_meta
assert not model_receipt_path.exists(), "all-errored run rewrote receipt"

receipt_failure_store = work / "receipt-failure-claudeb"
os.environ["CLAUDEB_DIR"] = str(receipt_failure_store)
saved_mkdir = pathlib.Path.mkdir


def receipt_mkdir_failure(path, *args, **kwargs):
    if path.name == rb.RECEIPT_DIR:
        raise OSError("fixture ENOSPC")
    return saved_mkdir(path, *args, **kwargs)


pathlib.Path.mkdir = receipt_mkdir_failure
receipt_failure_stdout = io.StringIO()
receipt_failure_stderr = io.StringIO()
receipt_failure_exception = None
try:
    with contextlib.redirect_stdout(receipt_failure_stdout), \
            contextlib.redirect_stderr(receipt_failure_stderr):
        receipt_failure_rc = rb.cmd_run(argparse.Namespace(
            repo=str(pin_repo), commitish=pin_descendant_sha,
            raters="opus-medium", leg=False, verify=None,
            auto=None, focus=None,
        ))
except Exception as exc:
    receipt_failure_exception = exc
finally:
    pathlib.Path.mkdir = saved_mkdir
assert receipt_failure_exception is None, \
    f"receipt failure aborted run: {receipt_failure_exception}"
assert receipt_failure_rc == 0, receipt_failure_stderr.getvalue()
assert "warning: could not write review receipt: fixture ENOSPC" \
    in receipt_failure_stderr.getvalue(), receipt_failure_stderr.getvalue()
assert "run id:" in receipt_failure_stdout.getvalue() \
    and "ADJUDICATION HANDOFF" in receipt_failure_stdout.getvalue(), \
    receipt_failure_stdout.getvalue()

# A bench run of a historical commit (pin_sha has a descendant) must not move the
# repository's receipt backwards: no receipt file, an explanatory note instead.
receipt_history_store = work / "receipt-history-claudeb"
os.environ["CLAUDEB_DIR"] = str(receipt_history_store)
history_stderr = io.StringIO()
with contextlib.redirect_stdout(io.StringIO()), \
        contextlib.redirect_stderr(history_stderr):
    history_rc = rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha,
        raters="opus-medium", leg=False, verify=None,
        auto=None, focus=None,
    ))
assert history_rc == 0, history_stderr.getvalue()
assert "receipt not written" in history_stderr.getvalue(), history_stderr.getvalue()
assert not (receipt_history_store / "worker-stats" / rb.RECEIPT_DIR
            / rb.receipt_file_name(pin_repo)).exists(), \
    "historical bench run wrote a receipt"

alias_envelope = pin_repo / "alias-envelope.json"
alias_envelope.write_text(json.dumps({"modelUsage": {
    "claude-opus-5[1m]": {"canonicalModel": "claude-opus-5"},
}}))
pair_envelope = pin_repo / "pair-envelope.json"
pair_envelope.write_text(json.dumps({"modelUsage": {
    "claude-opus-5[1m]": {"canonicalModel": "claude-opus-5"},
    "claude-sonnet-5": {"inputTokens": 1},
}}))
assert rb.resolved_model_from_envelope(alias_envelope) == "claude-opus-5", "alias not canonicalised"
assert (
    rb.resolved_model_from_envelope(pair_envelope) == "claude-opus-5+claude-sonnet-5"
), rb.resolved_model_from_envelope(pair_envelope)

suggest_env = dict(
    os.environ,
    GIT_AUTHOR_NAME="t",
    GIT_AUTHOR_EMAIL="t@example.test",
    GIT_COMMITTER_NAME="t",
    GIT_COMMITTER_EMAIL="t@example.test",
)


def make_suggest_repo(name, tracked=("tracked.txt",)):
    path = work / name
    path.mkdir()
    subprocess.run(["git", "-C", str(path), "init", "-q", "-b", "main"],
                   check=True, env=suggest_env)
    for file_name in tracked:
        full_path = path / file_name
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text("base\n")
    subprocess.run(["git", "-C", str(path), "add", "."], check=True, env=suggest_env)
    subprocess.run(["git", "-C", str(path), "commit", "-qm", "base"],
                   check=True, env=suggest_env)
    return path


def review_found(run_id, confirmed=0, findings=0):
    """Make the corpus say what a run found. The tier cap only applies to work over a review that
    found something, so a fixture asserting the cap has to be explicit about it: an adjudicated
    confirmed count for a commit review, findings files for a worktree one, which the corpus refuses.
    """
    corpus = pathlib.Path(suggest_env["CLAUDEB_DIR"]) / "worker-stats" / "reviews.jsonl"
    if confirmed:
        corpus.parent.mkdir(parents=True, exist_ok=True)
        with corpus.open("a") as stream:
            stream.write(json.dumps(
                {"run_id": run_id, "rater": "sol-low", "confirmed": confirmed}
            ) + "\n")
    if findings:
        run_dir = pathlib.Path(suggest_env["CLAUDEB_DIR"]) / "worker-stats" / "benches" / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        (run_dir / "findings-sol-high.jsonl").write_text("".join(
            json.dumps({"severity": "P2", "file": "x", "line": n, "summary": "f"}) + "\n"
            for n in range(findings)
        ))


def suggest(path, *extra):
    proc = subprocess.run(
        [sys.argv[1], "suggest", "--repo", str(path), *extra],
        check=True, capture_output=True, text=True, env=suggest_env,
    )
    return proc.stdout.splitlines()


def assert_suggestion(lines, files, changed_lines, tier, committed=False, receipt=None,
                      worktree_receipt=None, fix_capped=False):
    assert lines[:3] == [
        f"changed files: {files}",
        f"changed lines: {changed_lines}",
        f"tier: {tier}",
    ], lines
    offset = 3
    if fix_capped:
        run = receipt or worktree_receipt
        assert lines[offset] == (
            f"work over review {run}, so {tier} regardless of what it touches"
        ), lines
        offset += 1
    else:
        assert not any(line.startswith("work over review ") for line in lines), lines
    if receipt:
        assert lines[offset] == (
            f"unreviewed delta vs review {receipt}; staged content is compared with the same "
            "reviewed tree"
        ), lines
        offset += 1
    elif worktree_receipt:
        assert lines[offset] == (
            f"unreviewed delta vs review {worktree_receipt}; the working tree is compared with the "
            "reviewed snapshot as one tree against another, so staged and untracked content is "
            "counted once"
        ), lines
        offset += 1
    background = rb.REVIEW_TIERS[tier]["budget_min"] >= 10
    assert lines[offset] == (
        f"spawn: Bash run_in_background={'true' if background else 'false'}; "
        "preserve the complete final stdout"
    ), lines
    offset += 1
    if committed:
        assert lines[offset].startswith("command: review-bench review "), lines
        assert f"--tier {tier}" in lines[offset], lines
        return
    assert lines[offset].startswith("command: review-bench review --worktree "), lines
    assert f"--tier {tier}" in lines[offset], lines
    assert not any("cannot be reviewed" in line for line in lines), lines


clean_suggest = make_suggest_repo("suggest-clean")
assert suggest(clean_suggest) == ["nothing to review"]

t0_suggest = make_suggest_repo("suggest-t0")
(t0_suggest / "new.txt").write_text("line\n" * 20)
assert_suggestion(suggest(t0_suggest), 1, 20, "T0")

t1_size_suggest = make_suggest_repo("suggest-t1-size")
(t1_size_suggest / "medium.txt").write_text("line\n" * 21)
assert_suggestion(suggest(t1_size_suggest), 1, 21, "T1")

t1_suggest = make_suggest_repo(
    "suggest-t1", ("staged.txt", "unstaged.txt"),
)
(t1_suggest / "staged.txt").write_text("base\nstaged\n")
subprocess.run(["git", "-C", str(t1_suggest), "add", "staged.txt"],
               check=True, env=suggest_env)
(t1_suggest / "unstaged.txt").write_text("base\nunstaged\n")
(t1_suggest / "untracked.txt").write_text("untracked\n")
assert_suggestion(suggest(t1_suggest), 3, 3, "T1")

t2_suggest = make_suggest_repo("suggest-t2")
(t2_suggest / "wide.txt").write_text("line\n" * 151)
assert_suggestion(suggest(t2_suggest), 1, 151, "T2")

t3_suggest = make_suggest_repo("suggest-t3")
(t3_suggest / "huge.txt").write_text("line\n" * 601)
assert_suggestion(suggest(t3_suggest), 1, 601, "T3")

tests_suggest = make_suggest_repo("suggest-tests")
(tests_suggest / "tests" / "new-test.sh").parent.mkdir()
(tests_suggest / "tests" / "new-test.sh").write_text("true\n")
assert_suggestion(suggest(tests_suggest), 1, 1, "T1")

# A moved file is one file and no lines: expanded into a delete plus an add it would read as a
# rewrite and pick a tier for work nobody did.
rename_suggest = make_suggest_repo("suggest-rename", tracked=("moved.txt",))
(rename_suggest / "moved.txt").write_text("line\n" * 400)
subprocess.run(["git", "-C", str(rename_suggest), "commit", "-qam", "fill"],
               check=True, env=suggest_env)
subprocess.run(["git", "-C", str(rename_suggest), "mv", "moved.txt", "elsewhere.txt"],
               check=True, env=suggest_env)
assert_suggestion(suggest(rename_suggest), 1, 0, "T0")

# An untracked binary has no lines to count, and counting its bytes would pick a tier from pixels.
binary_suggest = make_suggest_repo("suggest-binary")
(binary_suggest / "asset.png").write_bytes(b"\x89PNG\r\n\x1a\n" + bytes(4000))
assert_suggestion(suggest(binary_suggest), 1, 0, "T0")

# A staged change the working tree then reverted is what the next commit contains, however
# invisible it is to `git diff HEAD`.
staged_suggest = make_suggest_repo("suggest-staged")
(staged_suggest / "tracked.txt").write_text("edited\n")
subprocess.run(["git", "-C", str(staged_suggest), "add", "tracked.txt"],
               check=True, env=suggest_env)
(staged_suggest / "tracked.txt").write_text("base\n")
assert_suggestion(suggest(staged_suggest), 1, 2, "T0")

# Moving a file out of bin/ still touches bin/, so the escalation has to see the old name.
moved_suggest = make_suggest_repo("suggest-moved", tracked=("bin/tool",))
subprocess.run(["git", "-C", str(moved_suggest), "mv", "bin/tool", "tool"],
               check=True, env=suggest_env)
assert suggest(moved_suggest)[2] == "tier: T1", suggest(moved_suggest)

# An untracked nested repository is one listed path with nothing to count, not a read error.
nested_suggest = make_suggest_repo("suggest-nested")
(nested_suggest / "nested").mkdir()
subprocess.run(["git", "-C", str(nested_suggest / "nested"), "init", "-q"],
               check=True, env=suggest_env)
assert_suggestion(suggest(nested_suggest), 1, 0, "T0")

receipt_suggest = make_suggest_repo("suggest-receipt")
(receipt_suggest / "reviewed.txt").write_text("reviewed\n" * 80)
subprocess.run(["git", "-C", str(receipt_suggest), "add", "reviewed.txt"],
               check=True, env=suggest_env)
subprocess.run(["git", "-C", str(receipt_suggest), "commit", "-qm", "reviewed"],
               check=True, env=suggest_env)
receipt_sha = subprocess.run(
    ["git", "-C", str(receipt_suggest), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
receipt_tree = subprocess.run(
    ["git", "-C", str(receipt_suggest), "rev-parse", "HEAD^{tree}"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
receipt_dir = pathlib.Path(suggest_env["CLAUDEB_DIR"]) / "worker-stats" / rb.RECEIPT_DIR
receipt_dir.mkdir(parents=True, exist_ok=True)
receipt_run_id = "receipt-fixture"
(receipt_dir / rb.receipt_file_name(receipt_suggest)).write_text(json.dumps({
    "repo": str(receipt_suggest), "tree": receipt_tree, "commit": receipt_sha,
    "run_id": receipt_run_id, "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
review_found(receipt_run_id, confirmed=2)
subprocess.run(["git", "-C", str(receipt_suggest), "reset", "-q", "--soft", "HEAD^"],
               check=True, env=suggest_env)
(receipt_suggest / "tracked.txt").write_text("changed\n")
# The reviewed commit was rewound with its content left staged, so HEAD is no longer where the panel
# stood and this is not a follow-up delta: the cap does not apply and the ordinary rules price it.
assert_suggestion(
    suggest(receipt_suggest), 1, 2, "T0", receipt=receipt_run_id,
)

# A worktree review is stamped with a snapshot of uncommitted content, reachable from nothing. The
# index still holds the committed base, so asking it what it adds over that snapshot answers with
# the whole reviewed delta reversed — 21 already-reviewed lines across two files, which used to be
# added to the one line that is genuinely new and escalated the tier by the size of the review that
# had just finished.
wt_receipt_suggest = make_suggest_repo(
    "suggest-worktree-receipt", ("tracked.txt", "second.txt"),
)
(wt_receipt_suggest / "tracked.txt").write_text("line\n" * 20)
(wt_receipt_suggest / "second.txt").write_text("changed\n")
subprocess.run(["git", "-C", str(wt_receipt_suggest), "add", "."],
               check=True, env=suggest_env)
wt_snapshot_tree = subprocess.run(
    ["git", "-C", str(wt_receipt_suggest), "write-tree"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
wt_snapshot_sha = subprocess.run(
    ["git", "-C", str(wt_receipt_suggest), "commit-tree", wt_snapshot_tree,
     "-p", "HEAD", "-m", "review-bench worktree snapshot"],
    check=True, capture_output=True, text=True,
    env=dict(suggest_env, GIT_COMMITTER_NAME="review-bench",
             GIT_COMMITTER_EMAIL="review-bench@local"),
).stdout.strip()
subprocess.run(["git", "-C", str(wt_receipt_suggest), "reset", "-q", "HEAD"],
               check=True, env=suggest_env)
(receipt_dir / rb.receipt_file_name(wt_receipt_suggest)).write_text(json.dumps({
    "repo": str(wt_receipt_suggest), "tree": wt_snapshot_tree, "commit": wt_snapshot_sha,
    "run_id": "worktree-fixture", "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
review_found("worktree-fixture", findings=3)
worktree_run_dir = (
    pathlib.Path(suggest_env["CLAUDEB_DIR"]) / "worker-stats" / "benches" / "worktree-fixture"
)
(worktree_run_dir / "findings-sol-max.jsonl").write_text(
    json.dumps({"severity": "P1", "file": "x", "line": 1, "summary": "discarded"}) + "\n"
)
(worktree_run_dir / "meta.json").write_text(json.dumps({
    "rater_runs": [
        {"rater": "sol-high", "errored": False},
        {"rater": "sol-max", "errored": True},
    ],
}) + "\n")
assert rb.review_outcome(wt_receipt_suggest, {
    "commit": wt_snapshot_sha, "run_id": "worktree-fixture",
}) == (True, 0, 3)
# A row from another repository sharing seven hex characters is a different commit: full-sha
# equality only, or confirmed counts bleed between repos through the shared corpus.
with (pathlib.Path(suggest_env["CLAUDEB_DIR"]) / "worker-stats" / "reviews.jsonl").open("a") as stream:
    stream.write(json.dumps({
        "run_id": "prefix-collider", "rater": "sol-low", "confirmed": 9,
        "commit": wt_snapshot_sha[:7] + "f" * (len(wt_snapshot_sha) - 7),
    }) + "\n")
assert rb.review_outcome(wt_receipt_suggest, {
    "commit": wt_snapshot_sha, "run_id": "worktree-fixture",
}) == (True, 0, 3)
(wt_receipt_suggest / "tracked.txt").write_text("line\n" * 19 + "new\n")
# Staged after the review and then dropped from the working tree: not counted, and deliberately so.
# Both trees compared here are built from the working tree, exactly as review-bench builds the
# snapshot a panel reviews, so a path only the index still holds was never reviewed and no review of
# this repository can cover it — counting it would light a label nothing could clear.
(wt_receipt_suggest / "staged-after.txt").write_text("late\n")
subprocess.run(["git", "-C", str(wt_receipt_suggest), "add", "staged-after.txt"],
               check=True, env=suggest_env)
(wt_receipt_suggest / "staged-after.txt").unlink()
assert_suggestion(
    suggest(wt_receipt_suggest), 1, 2, "T0", worktree_receipt="worktree-fixture",
    fix_capped=True,
)

# The escalation that made one review become three: 30 lines inside a core measurement tool is a
# fresh T2 by the ordinary rules, and as this review's own fixes it is a T0.
fix_core_suggest = make_suggest_repo("suggest-fix-core", ("bin/review-bench",))
# The cap holds only while the delta is no larger than the diff the panel read, so the reviewed
# commit has to be one of this repository's own, with a parent and enough lines in it.
(fix_core_suggest / "bin" / "review-bench").write_text("reviewed\n" * 40)
subprocess.run(["git", "-C", str(fix_core_suggest), "commit", "-aqm", "reviewed"],
               check=True, env=suggest_env)
fix_core_sha, fix_core_tree = (subprocess.run(
    ["git", "-C", str(fix_core_suggest), "rev-parse", ref],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip() for ref in ("HEAD", "HEAD^{tree}"))
(receipt_dir / rb.receipt_file_name(fix_core_suggest)).write_text(json.dumps({
    "repo": str(fix_core_suggest), "tree": fix_core_tree, "commit": fix_core_sha,
    "run_id": "fix-core-fixture", "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
review_found("fix-core-fixture", confirmed=1)
(fix_core_suggest / "bin" / "review-bench").write_text("reviewed\n" * 40 + "fix\n")
assert_suggestion(
    suggest(fix_core_suggest), 1, 1, "T0", receipt="fix-core-fixture", fix_capped=True,
)

# A small new path immediately after a large reviewed commit is not evidence that the review
# provoked it. The receipt may cap only work that overlaps what the panel read.
unrelated_suggest = make_suggest_repo("suggest-unrelated-fix")
(unrelated_suggest / "tracked.txt").write_text("reviewed\n" * 250)
subprocess.run(["git", "-C", str(unrelated_suggest), "commit", "-aqm", "reviewed"],
               check=True, env=suggest_env)
unrelated_sha, unrelated_tree = (subprocess.run(
    ["git", "-C", str(unrelated_suggest), "rev-parse", ref],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip() for ref in ("HEAD", "HEAD^{tree}"))
(receipt_dir / rb.receipt_file_name(unrelated_suggest)).write_text(json.dumps({
    "repo": str(unrelated_suggest), "tree": unrelated_tree, "commit": unrelated_sha,
    "run_id": "unrelated-fixture", "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
review_found("unrelated-fixture", confirmed=1)
(unrelated_suggest / "tests").mkdir()
(unrelated_suggest / "tests" / "new.sh").write_text("new\n")
assert_suggestion(
    suggest(unrelated_suggest), 1, 1, "T1", receipt="unrelated-fixture",
)

# Nor is it follow-up once anything has been committed since: the panel stood on HEAD, and a receipt
# left behind must not cheapen later work — including work on another branch — just by sitting there.
subprocess.run(["git", "-C", str(fix_core_suggest), "commit", "-aqm", "moved on"],
               check=True, env=suggest_env)
(fix_core_suggest / "bin" / "review-bench").write_text("reviewed\n" * 40 + "fix\n" * 2)
assert_suggestion(
    suggest(fix_core_suggest), 1, 2, "T2", receipt="fix-core-fixture",
)
subprocess.run(["git", "-C", str(fix_core_suggest), "reset", "-q", "--hard", "HEAD^"],
               check=True, env=suggest_env)

# Once more has been written than the panel read, this is not that review's follow-up any more and
# the cap lets go — otherwise a receipt nothing ever restamps prices the whole repository forever.
(fix_core_suggest / "bin" / "review-bench").write_text("fresh\n" * 300)
assert_suggestion(
    suggest(fix_core_suggest), 1, 340, "T2", receipt="fix-core-fixture",
)

# A review that found nothing provokes no fixes and is never restamped, so capping work over it
# would put a ceiling on the repository that never lifts: 201 fresh lines in a measurement tool
# would come out T1 forever instead of the T2 they earn.
clean_review_suggest = make_suggest_repo("suggest-clean-review", ("bin/review-bench",))
clean_review_tree = subprocess.run(
    ["git", "-C", str(clean_review_suggest), "rev-parse", "HEAD^{tree}"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
(receipt_dir / rb.receipt_file_name(clean_review_suggest)).write_text(json.dumps({
    "repo": str(clean_review_suggest), "tree": clean_review_tree, "commit": receipt_sha,
    "run_id": "clean-review-fixture", "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
(clean_review_suggest / "bin" / "review-bench").write_text("line\n" * 200)
assert_suggestion(
    suggest(clean_review_suggest), 1, 201, "T2", receipt="clean-review-fixture",
)

# A manual stamp is a declaration that the tree was looked at, not a review that found things, so
# what lands after it is fresh work and earns its tier the ordinary way.
stamp_suggest = make_suggest_repo("suggest-after-stamp", ("bin/review-bench",))
stamp_tree = subprocess.run(
    ["git", "-C", str(stamp_suggest), "rev-parse", "HEAD^{tree}"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
(receipt_dir / rb.receipt_file_name(stamp_suggest)).write_text(json.dumps({
    "repo": str(stamp_suggest), "tree": stamp_tree, "commit": receipt_sha,
    "run_id": "stamped-20260728T000000Z", "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
(stamp_suggest / "bin" / "review-bench").write_text("line\n" * 30)
assert_suggestion(
    suggest(stamp_suggest), 1, 31, "T2", receipt="stamped-20260728T000000Z",
)

# A delta that outgrew what T1 covers still stays inside the two tiers a review's follow-up can
# reach: T1, never the T2 the ordinary rules would price 200 lines at.
fix_big_suggest = make_suggest_repo("suggest-fix-big")
(fix_big_suggest / "tracked.txt").write_text("reviewed\n" * 250)
subprocess.run(["git", "-C", str(fix_big_suggest), "commit", "-aqm", "reviewed"],
               check=True, env=suggest_env)
fix_big_sha, fix_big_tree = (subprocess.run(
    ["git", "-C", str(fix_big_suggest), "rev-parse", ref],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip() for ref in ("HEAD", "HEAD^{tree}"))
(receipt_dir / rb.receipt_file_name(fix_big_suggest)).write_text(json.dumps({
    "repo": str(fix_big_suggest), "tree": fix_big_tree, "commit": fix_big_sha,
    "run_id": "fix-big-fixture", "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
review_found("fix-big-fixture", confirmed=1)
(fix_big_suggest / "tracked.txt").write_text("reviewed\n" * 100 + "fix\n" * 100)
assert_suggestion(
    suggest(fix_big_suggest), 1, 250, "T1", receipt="fix-big-fixture", fix_capped=True,
)

# A snapshot holds untracked content too, because that is how review-bench builds one. Asking the
# index and the working tree about it separately answered with a phantom deletion of every untracked
# file and then added its line count back on top: with nothing changed since the panel ran, suggest
# claimed a whole tier of work.
wt_untracked_suggest = make_suggest_repo("suggest-worktree-untracked")
(wt_untracked_suggest / "extra.txt").write_text("line\n" * 40)
subprocess.run(["git", "-C", str(wt_untracked_suggest), "add", "."],
               check=True, env=suggest_env)
wt_untracked_tree = subprocess.run(
    ["git", "-C", str(wt_untracked_suggest), "write-tree"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
wt_untracked_sha = subprocess.run(
    ["git", "-C", str(wt_untracked_suggest), "commit-tree", wt_untracked_tree,
     "-p", "HEAD", "-m", "review-bench worktree snapshot"],
    check=True, capture_output=True, text=True,
    env=dict(suggest_env, GIT_COMMITTER_NAME="review-bench",
             GIT_COMMITTER_EMAIL="review-bench@local"),
).stdout.strip()
subprocess.run(["git", "-C", str(wt_untracked_suggest), "reset", "-q", "HEAD"],
               check=True, env=suggest_env)
(receipt_dir / rb.receipt_file_name(wt_untracked_suggest)).write_text(json.dumps({
    "repo": str(wt_untracked_suggest), "tree": wt_untracked_tree, "commit": wt_untracked_sha,
    "run_id": "untracked-fixture", "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
review_found("untracked-fixture", findings=2)
assert suggest(wt_untracked_suggest) == [
    "nothing to review; tree matches review untracked-fixture"
], suggest(wt_untracked_suggest)
# And one line written after that review is one line of work, not forty-one.
(wt_untracked_suggest / "extra.txt").write_text("line\n" * 40 + "new\n")
assert_suggestion(
    suggest(wt_untracked_suggest), 1, 1, "T0", worktree_receipt="untracked-fixture",
    fix_capped=True,
)

missing_tree_suggest = make_suggest_repo("suggest-missing-tree")
(missing_tree_suggest / "tracked.txt").write_text("changed\n")
(receipt_dir / rb.receipt_file_name(missing_tree_suggest)).write_text(json.dumps({
    "repo": str(missing_tree_suggest), "tree": "0" * len(receipt_tree),
    "commit": receipt_sha, "run_id": "missing-tree",
    "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
missing_tree_lines = suggest(missing_tree_suggest)
assert_suggestion(missing_tree_lines, 1, 2, "T0")
assert not any("unreviewed delta vs review" in line for line in missing_tree_lines)

vanished_repo_suggest = make_suggest_repo("suggest-vanished-repo")
(vanished_repo_suggest / "tracked.txt").write_text("changed\n")
(receipt_dir / rb.receipt_file_name(vanished_repo_suggest)).write_text(json.dumps({
    "repo": str(vanished_repo_suggest / "no-such-dir"), "tree": receipt_tree,
    "commit": receipt_sha, "run_id": "vanished-repo",
    "ts": "2026-07-27T00:00:00+00:00", "errored": 0,
}) + "\n")
vanished_repo_lines = suggest(vanished_repo_suggest)
assert_suggestion(vanished_repo_lines, 1, 2, "T0")
assert not any("unreviewed delta vs review" in line for line in vanished_repo_lines)

for index, core_path in enumerate((
    "bin/review-bench", "bin/opencode-go", "bin/claudeb", "bin/codexb",
    "bin/geminib", "llm-limits.sh",
)):
    core_suggest = make_suggest_repo(f"suggest-core-{index}")
    full_path = core_suggest / core_path
    full_path.parent.mkdir(parents=True, exist_ok=True)
    full_path.write_text("true\n")
    assert_suggestion(suggest(core_suggest), 1, 1, "T2")

range_suggest = make_suggest_repo("suggest-range")
range_base = subprocess.run(
    ["git", "-C", str(range_suggest), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
(range_suggest / "range.txt").write_text("line\n" * 151)
subprocess.run(["git", "-C", str(range_suggest), "add", "range.txt"],
               check=True, env=suggest_env)
subprocess.run(["git", "-C", str(range_suggest), "commit", "-qm", "range"],
               check=True, env=suggest_env)
range_head = subprocess.run(
    ["git", "-C", str(range_suggest), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
range_lines = suggest(range_suggest, "--range", f"{range_base}..{range_head}")
assert_suggestion(range_lines, 1, 151, "T2", committed=True)
assert range_head in range_lines[4], range_lines

print("review-bench-unit-ok")
PY
assert test "$?" -eq 0

REPORT_SD="$WORK/report-state"
mkdir -p "$REPORT_SD/benches/report-adjudicated" "$REPORT_SD/benches/report-worktree"
python3 - "$REPORT_SD" "$WORK/report-worktree-verdicts.jsonl" <<'PY'
import json
import pathlib
import sys

state = pathlib.Path(sys.argv[1])
adjudicated = state / "benches" / "report-adjudicated"
adjudicated_meta = {
    "run_id": "report-adjudicated", "commit": "a" * 40, "repo": "/fixture",
    "tier": "T2", "raters": ["sol-high", "oc-kimik3"],
    "rater_runs": [
        {"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
         "exit_code": 0},
        {"rater": "oc-kimik3", "model": "oc-kimik3", "effort": None, "side": "opencode",
         "duration_ms": 45_000, "findings": 2, "exit_code": 0},
        {"rater": "agy-flash36-medium-skill", "model": "agy-flash36", "effort": "medium",
         "side": "agy", "duration_ms": 240_000, "timeout_s": 240, "findings": 0,
         "exit_code": 124, "errored": True, "stderr": "rater timed out after 240s"},
        {"rater": "agy-flash35-low-skill", "model": "agy-flash35", "effort": "low",
         "side": "agy", "duration_ms": 30_000, "findings": 0, "exit_code": 1,
         "errored": True,
         "stderr": "agy served Gemini 3.5 Flash (Medium) instead of Gemini 3.5 Flash (Low)"},
        {"rater": "opus-medium", "model": "opus", "effort": "medium", "side": "claude",
         "duration_ms": 15_000, "findings": 0, "exit_code": 2, "errored": True,
         "stderr": "fixture failure"},
    ],
    "durations": {"sol-high": 120_000}, "started": "2026-07-30T00:00:00+00:00",
    "finished": "2026-07-30T00:05:30+00:00", "focus": "",
}
(adjudicated / "meta.json").write_text(json.dumps(adjudicated_meta))
findings = {
    "sol-high": [
        {"severity": "P1", "file": "a.py", "line": 1, "summary": "confirmed",
         "rater": "sol-high"},
        {"severity": "P3", "file": "a.py", "line": 2, "summary": "false",
         "rater": "sol-high"},
    ],
    "oc-kimik3": [
        {"severity": "P1", "file": "a.py", "line": 1, "summary": "duplicate",
         "rater": "oc-kimik3"},
        {"severity": "P2", "file": "b.py", "line": 3, "summary": "false",
         "rater": "oc-kimik3"},
    ],
}
for rater, rows in findings.items():
    (adjudicated / f"findings-{rater}.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in rows)
    )
verdicts = [
    {"rater": "sol-high", "idx": 0, "verdict": "confirmed"},
    {"rater": "sol-high", "idx": 1, "verdict": "false_positive"},
    {"rater": "oc-kimik3", "idx": 0, "verdict": "duplicate"},
    {"rater": "oc-kimik3", "idx": 1, "verdict": "false_positive"},
]
(adjudicated / "verdicts.jsonl").write_text(
    "".join(json.dumps(row) + "\n" for row in verdicts)
)

worktree = state / "benches" / "report-worktree"
worktree_meta = {
    "run_id": "report-worktree", "commit": "b" * 40, "repo": "/fixture",
    "tier": "T0", "worktree": True, "raters": ["oc-kimik3", "oc-kimik3#2"],
    "rater_runs": [
        {"rater": "oc-kimik3", "model": "oc-kimik3", "effort": None,
         "side": "opencode", "duration_ms": 10_000, "findings": 1, "exit_code": 0},
        {"rater": "oc-kimik3#2", "model": "oc-kimik3", "effort": None,
         "side": "opencode", "duration_ms": 20_000, "findings": 2, "exit_code": 0},
        {"rater": "agy-pro-high-skill", "model": "agy-pro", "effort": "high",
         "side": "agy", "duration_ms": 180_000, "timeout_s": 180, "findings": 0,
         "exit_code": 124, "errored": True, "stderr": "rater timed out after 180s"},
    ],
    "durations": {}, "started": "2026-07-29T00:00:00+00:00",
    "finished": "2026-07-29T00:00:30+00:00", "focus": "",
}
(worktree / "meta.json").write_text(json.dumps(worktree_meta))
for rater, count in (("oc-kimik3", 1), ("oc-kimik3#2", 2)):
    rows = [
        {"severity": "P2", "file": "w.py", "line": index + 1,
         "summary": f"finding {index}", "rater": rater}
        for index in range(count)
    ]
    (worktree / f"findings-{rater}.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in rows)
    )
pathlib.Path(sys.argv[2]).write_text("".join(
    json.dumps({"rater": rater, "idx": index, "verdict": "confirmed"}) + "\n"
    for rater, count in (("oc-kimik3", 1), ("oc-kimik3#2", 2))
    for index in range(count)
))

aborted = state / "benches" / "report-aborted"
aborted.mkdir()
(aborted / "meta.json").write_text(json.dumps({
    "run_id": "report-aborted", "commit": "c" * 40, "repo": "/fixture",
    "raters": ["sol-low"], "completed_raters": [], "rater_runs": [],
    "started": "2026-07-31T00:00:00Z",
}))
PY

report_output=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" report report-adjudicated) \
  || fail "adjudicated report failed"
expected_report=$'REVIEW-REPORT-BEGIN\nT2 · 5.5 min wall · slowest completed: Sol high 2 min\nconfirmed 1:  P1 1\nrejected:     1 duplicate  ~400 tok\n              2 false      ~3k tok\nfalse by:     Kimi K3 ×1 · Sol high ×1\nverifier:     off — 2 OpenCode finding(s) unchecked\nerrored:      Opus medium (exit 2)\ntimeout:      Gemini 3.6 Flash medium skill\nmismatch:     Gemini 3.5 Flash low skill\nREVIEW-REPORT-END'
assert test "$report_output" = "$expected_report"
assert contains "$report_output" $'rejected:     1 duplicate  ~400 tok\n              2 false      ~3k tok'
assert contains "$report_output" $'false by:     Kimi K3 ×1 · Sol high ×1\nverifier:     off — 2 OpenCode finding(s) unchecked\nerrored:      Opus medium (exit 2)\ntimeout:      Gemini 3.6 Flash medium skill\nmismatch:     Gemini 3.5 Flash low skill'
last_report=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" report --last) \
  || fail "last report failed"
assert test "$last_report" = "$expected_report"
worktree_report=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" report report-worktree) \
  || fail "worktree report failed"
expected_worktree_report=$'REVIEW-REPORT-BEGIN\nT0 · 30 sec wall · slowest completed: Kimi K3 20 sec\nfindings:  Kimi K3 ×2 3\nnote:      not adjudicated \u2014 optional, and keeps until the corpus is wanted\nverifier:  off — 3 OpenCode finding(s) unchecked\ntimeout:   Gemini 3.1 Pro high skill\nREVIEW-REPORT-END'
assert test "$worktree_report" = "$expected_worktree_report"
worktree_recorded=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" record report-worktree \
  --verdicts "$WORK/report-worktree-verdicts.jsonl") || fail "worktree record failed"
assert contains "$worktree_recorded" "corpus skipped"
assert contains "$worktree_recorded" "REVIEW-REPORT-BEGIN"
assert contains "$worktree_recorded" "REVIEW-REPORT-END"
assert test ! -e "$REPORT_SD/reviews.jsonl"
worktree_recorded_again=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" record report-worktree \
  --verdicts "$WORK/report-worktree-verdicts.jsonl") || fail "worktree record replay failed"
assert contains "$worktree_recorded_again" "corpus skipped"
worktree_listing=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" list)
worktree_listing_row=$(grep 'report-worktree' <<<"$worktree_listing")
assert contains "$worktree_listing_row" "2/2  adjudicated"
aborted_listing_row=$(grep 'report-aborted' <<<"$worktree_listing")
assert contains "$aborted_listing_row" "aborted"
python3 - "$REPORT_SD" <<'PY'
import json
import pathlib
import sys

state = pathlib.Path(sys.argv[1])
rows = [
    json.loads(line)
    for line in (state / "review-log.jsonl").read_text().splitlines()
]
assert len(rows) == 1, rows
event = rows[0]
assert event["event"] == "adjudicated" and event["run_id"] == "report-worktree"
assert event["tier"] == "T0"
assert (event["findings"], event["confirmed"], event["duplicate"],
        event["false_positive"], event["token_estimate"]) == (3, 3, 0, 0, 0)
assert [cell["status"] for cell in event["cells"]] == [
    "completed", "completed", "timed_out",
]
PY
assert test "$?" -eq 0

SD="$WORK/state"
RUN="$SD/benches/run-fixture"
mkdir -p "$RUN"
python3 - "$RUN" <<'PY'
import json
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
meta = {"run_id":"run-fixture","commit":"abcdef0123456789","repo":"/repo",
        "raters":["sol-medium","opus-medium"],
        "rater_runs":[
            {"rater":"sol-medium","model":"sol","effort":"medium","side":"codex","exit_code":0},
            {"rater":"opus-medium","model":"opus","model_resolved":"claude-opus-5",
             "effort":"medium","side":"claude","exit_code":0},
            {"rater":"sonnet-medium-skill","model":"sonnet","effort":"medium","side":"claude",
             "exit_code":1,"errored":True},
        ],
        "durations":{"sol-medium":1200,"opus-medium":2400},
        "started":"2026-07-21T00:00:00+00:00","finished":"2026-07-21T00:00:03+00:00","focus":""}
(run / "meta.json").write_text(json.dumps(meta))
findings = {
    "sol-medium": [
        {"severity":"P1","file":"src/a.py","line":10,"summary":"Shared bug","rater":"sol-medium"},
        {"severity":"P2","file":"src/b.py","line":20,"summary":"Sol-only bug","rater":"sol-medium"},
        {"severity":"P3","file":"src/no.py","line":30,"summary":"Not a bug","rater":"sol-medium"},
    ],
    "opus-medium": [
        {"severity":"P1","file":"src/a.py","line":10,"summary":"Same shared bug","rater":"opus-medium"},
        {"severity":"P3","file":"src/c.py","line":40,"summary":"Opus-only bug","rater":"opus-medium"},
    ],
}
for rater, rows in findings.items():
    with open(run / f"findings-{rater}.jsonl", "w") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")
PY

VERDICTS="$WORK/verdicts.jsonl"
python3 - "$VERDICTS" <<'PY'
import json
import sys
rows = [
    {"rater":"sol-medium","idx":0,"verdict":"confirmed"},
    {"rater":"sol-medium","idx":1,"verdict":"confirmed"},
    {"rater":"sol-medium","idx":2,"verdict":"false_positive"},
    {"rater":"opus-medium","idx":0,"verdict":"duplicate"},
    {"rater":"opus-medium","idx":1,"verdict":"confirmed"},
]
with open(sys.argv[1], "w") as handle:
    for row in rows:
        handle.write(json.dumps(row) + "\n")
PY

recorded=$(WORKER_STATS_DIR="$SD" "$SCRIPT" record run-fixture --verdicts "$VERDICTS") || fail "record failed"
assert contains "$recorded" 'recorded 2 rater row(s)'
assert test "$(wc -l <"$SD/reviews.jsonl")" -eq 2

python3 - "$SD/reviews.jsonl" "$RUN/verdicts.jsonl" "$RUN/defects.jsonl" \
  "$SD/review-log.jsonl" <<'PY'
import json
import pathlib
import sys
rows = {f"{r['rater_model']}-{r['rater_effort']}":r for r in map(json.loads, open(sys.argv[1]))}
sol = rows["sol-medium"]
opus = rows["opus-medium"]
assert (sol["findings"], sol["p1"], sol["p2"], sol["p3"]) == (3, 1, 1, 0)
assert (sol["confirmed"], sol["false_positive"], sol["duplicate"]) == (2, 1, 0)
assert (sol["unique_catches"], sol["misses"], sol["duration_ms"]) == (1, 1, 1200)
assert (opus["findings"], opus["p1"], opus["p2"], opus["p3"]) == (2, 0, 0, 1)
assert (opus["confirmed"], opus["false_positive"], opus["duplicate"]) == (1, 0, 1)
assert (opus["unique_catches"], opus["misses"], opus["duration_ms"]) == (1, 1, 2400)
verdict_path = pathlib.Path(sys.argv[2])
defect_path = pathlib.Path(sys.argv[3])
verdicts = list(map(json.loads, verdict_path.read_text().splitlines())) \
    if verdict_path.exists() else None
defects = list(map(json.loads, defect_path.read_text().splitlines())) \
    if defect_path.exists() else None
events = list(map(json.loads, pathlib.Path(sys.argv[4]).read_text().splitlines()))
assert (
    verdicts == [
        {"rater": "opus-medium", "idx": 0, "verdict": "duplicate"},
        {"rater": "opus-medium", "idx": 1, "verdict": "confirmed"},
        {"rater": "sol-medium", "idx": 0, "verdict": "confirmed"},
        {"rater": "sol-medium", "idx": 1, "verdict": "confirmed"},
        {"rater": "sol-medium", "idx": 2, "verdict": "false_positive"},
    ]
    and defects == [
        {
            "defect_id": "run-fixture#1", "file": "src/c.py", "line": 40,
            "severity": "P3", "summary": "Opus-only bug",
            "canonical_rater": "opus-medium", "canonical_idx": 1,
            "caught_by": ["opus-medium"],
        },
        {
            "defect_id": "run-fixture#2", "file": "src/a.py", "line": 10,
            "severity": "P1", "summary": "Shared bug",
            "canonical_rater": "sol-medium", "canonical_idx": 0,
            "caught_by": ["opus-medium", "sol-medium"],
        },
        {
            "defect_id": "run-fixture#3", "file": "src/b.py", "line": 20,
            "severity": "P2", "summary": "Sol-only bug",
            "canonical_rater": "sol-medium", "canonical_idx": 1,
            "caught_by": ["sol-medium"],
        },
    ]
    and opus.get("rater_model_resolved") == "claude-opus-5"
    and "rater_model_resolved" not in sol
    and len(events) == 1
    and events[0]["event"] == "adjudicated"
    and events[0]["run_id"] == "run-fixture"
    and (events[0]["findings"], events[0]["confirmed"], events[0]["duplicate"],
         events[0]["false_positive"], events[0]["token_estimate"]) == (5, 3, 1, 1, 1900)
), (verdicts, defects, rows)
print("record-math-ok")
PY
assert test "$?" -eq 0

record_artifacts_before="$(shasum "$RUN/verdicts.jsonl" "$RUN/defects.jsonl" 2>/dev/null || true)"
again=$(WORKER_STATS_DIR="$SD" "$SCRIPT" record run-fixture --verdicts "$VERDICTS") || fail "record dedupe failed"
assert contains "$again" 'recorded 0 rater row(s)'
assert test "$(wc -l <"$SD/reviews.jsonl")" -eq 2
assert test "$(wc -l <"$SD/review-log.jsonl")" -eq 1
record_artifacts_after="$(shasum "$RUN/verdicts.jsonl" "$RUN/defects.jsonl" 2>/dev/null || true)"
assert test -n "$record_artifacts_before" -a "$record_artifacts_after" = "$record_artifacts_before"

corpus_before="$(cat "$SD/reviews.jsonl")"
mv "$RUN/defects.jsonl" "$WORK/defects-kept.jsonl"
mkdir "$RUN/defects.jsonl"
WORKER_STATS_DIR="$SD" "$SCRIPT" record run-fixture --verdicts "$VERDICTS" >/dev/null 2>&1 \
  && fail "record succeeded although defects.jsonl could not be written"
assert test "$(cat "$SD/reviews.jsonl")" = "$corpus_before"
rmdir "$RUN/defects.jsonl"
mv "$WORK/defects-kept.jsonl" "$RUN/defects.jsonl"

python3 - "$VERDICTS" "$WORK/verdicts-corrected.jsonl" <<'PY'
import json
import sys
rows = [json.loads(line) for line in open(sys.argv[1])]
for row in rows:
    if row["rater"] == "sol-medium" and row["idx"] == 2:
        row["verdict"] = "confirmed"
with open(sys.argv[2], "w") as stream:
    for row in rows:
        stream.write(json.dumps(row) + "\n")
PY
corrected=$(WORKER_STATS_DIR="$SD" "$SCRIPT" record run-fixture \
  --verdicts "$WORK/verdicts-corrected.jsonl") || fail "re-adjudication failed"
assert contains "$corrected" 're-adjudicated: replaced 2 row(s)'
assert test "$(wc -l <"$SD/reviews.jsonl")" -eq 2
python3 - "$SD/reviews.jsonl" <<'PY'
import json
import sys
rows = {r["rater"]: r for r in map(json.loads, open(sys.argv[1]))}
sol = rows["sol-medium"]
assert (sol["confirmed"], sol["false_positive"]) == (3, 0), sol
PY
assert test "$?" -eq 0
WORKER_STATS_DIR="$SD" "$SCRIPT" record run-fixture --verdicts "$VERDICTS" >/dev/null \
  || fail "restoring the original adjudication failed"

# A run stored under the pre-rename agy id is otherwise stranded: review_counts credits it,
# record refuses it, and no adjudication of it is possible at all.
LEGACY_RUN="$SD/benches/legacy-fixture"
mkdir -p "$LEGACY_RUN"
python3 - "$LEGACY_RUN" "$WORK/legacy-verdicts.jsonl" <<'PY'
import json
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
(run / "meta.json").write_text(json.dumps({
    "run_id": "legacy-fixture", "commit": "abcdef0123456789", "repo": "/repo",
    "raters": ["agy-flash-low-skill"],
    "rater_runs": [{"rater": "agy-flash-low-skill", "model": "agy-flash36", "effort": "low",
                    "side": "agy", "exit_code": 0}],
    "durations": {"agy-flash-low-skill": 4200},
    "started": "2026-07-21T00:00:00+00:00", "finished": "2026-07-21T00:00:05+00:00", "focus": "",
}))
(run / "findings-agy-flash-low-skill.jsonl").write_text(json.dumps({
    "severity": "P2", "file": "src/a.py", "line": 10, "summary": "Legacy id bug",
    "rater": "agy-flash-low-skill",
}) + "\n")
pathlib.Path(sys.argv[2]).write_text(
    json.dumps({"_recovered_from": "review-notes.md", "_matched_by": "file-line-summary"})
    + "\n"
    + json.dumps({
        "rater": "agy-flash-low-skill", "idx": 0, "verdict": "confirmed"
    })
    + "\n"
)
PY
legacy=$(WORKER_STATS_DIR="$SD" "$SCRIPT" record legacy-fixture --verdicts "$WORK/legacy-verdicts.jsonl") \
  || fail "record refused a run stored under the legacy agy id"
assert contains "$legacy" 'recorded 1 rater row(s)'
assert test "$(jq -r 'select(.run_id=="legacy-fixture") | .rater_model' "$SD/reviews.jsonl")" = agy-flash36
assert test "$(wc -l <"$SD/reviews.jsonl")" -eq 3

# A defect id counts from one inside its own run, so two runs of one commit cannot be compared
# until a judge says which of their defects are the same defect. cluster is where that lands.
CSD="$WORK/cluster-stats"
CREPO="$WORK/cluster-repo"
mkdir -p "$CSD/benches/cl-one" "$CSD/benches/cl-two" "$CREPO"
git -C "$CREPO" init -q
git -C "$CREPO" config user.email t@example.com
git -C "$CREPO" config user.name Test
printf 'one\n' >"$CREPO/a.py"
git -C "$CREPO" add a.py
git -C "$CREPO" commit -qm "fixture"
CSHA=$(git -C "$CREPO" rev-parse HEAD)
python3 - "$CSD" "$CREPO" "$CSHA" <<'PY'
import json
import pathlib
import sys

stats, repo, sha = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
runs = {
    "cl-one": [
        {"defect_id": "cl-one#1", "file": "a.py", "line": 3, "severity": "P2",
         "summary": "shared bug", "caught_by": ["sol-low", "oc-kimik3"]},
        {"defect_id": "cl-one#2", "file": "a.py", "line": 9, "severity": "P3",
         "summary": "run one only", "caught_by": ["sol-low"]},
    ],
    "cl-two": [
        {"defect_id": "cl-two#1", "file": "a.py", "line": 4, "severity": "P1",
         "summary": "the same shared bug, worded differently", "caught_by": ["agy-pro-high-skill"]},
    ],
}
for run, defects in runs.items():
    directory = stats / "benches" / run
    raters = sorted({rater for defect in defects for rater in defect["caught_by"]})
    (directory / "meta.json").write_text(json.dumps({
        "run_id": run, "commit": sha, "repo": repo, "raters": raters,
        "rater_runs": [{"rater": rater, "duration_ms": 1000, "exit_code": 0} for rater in raters],
        "durations": {rater: 1000 for rater in raters},
        "started": "2026-07-26T00:00:00+00:00", "finished": "2026-07-26T00:00:01+00:00",
    }))
    with open(directory / "defects.jsonl", "w") as handle:
        for defect in defects:
            handle.write(json.dumps(defect) + "\n")
PY

printf '#!/bin/sh\necho "worker-pick must not run" >&2\nexit 1\n' >"$WORK/exploding-worker-pick.sh"
chmod +x "$WORK/exploding-worker-pick.sh"

CGROUPS="$WORK/cluster-groups.jsonl"
cat >"$CGROUPS" <<'JSON'
{"members":["cl-one#1","cl-two#1"],"file":"a.py","line":3,"severity":"P3","summary":"shared bug"}
{"members":["cl-one#2"],"file":"a.py","line":9,"severity":"P3","summary":"run one only"}
JSON
clustered=$(WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$CGROUPS") \
  || fail "cluster refused a well-formed grouping"
assert contains "$clustered" '3 run-level defect(s) -> 2 canonical (1 merged'
CNAME=$(basename "$CREPO")
python3 - "$CSD/defects/${CNAME}__${CSHA:0:7}.jsonl" "$CSHA" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[0 + 1])]
merged, single = rows
# The union across runs is the whole point: one cell ran in each run and neither list alone
# names all three cells that found this defect.
assert merged["caught_by"] == ["agy-pro-high-skill", "oc-kimik3", "sol-low"], merged
assert [c["run_id"] for c in merged["catches"]] == ["cl-one", "cl-one", "cl-two"], merged
# The judge wrote P3 while a member was adjudicated P1; the members decide.
assert merged["severity"] == "P1", merged
assert merged["commit"] == sys.argv[2], merged
assert single["caught_by"] == ["sol-low"], single
assert single["members"] == ["cl-one#2"], single
assert merged["defect_id"].endswith("#1") and single["defect_id"].endswith("#2"), rows
print("cluster-ok")
PY
assert test "$?" -eq 0

# Each of these leaves the canonical list silently wrong, so each is refused rather than merged.
printf '%s\n' '{"members":["cl-one#1","cl-two#1"],"file":"a.py","severity":"P2","summary":"x"}' >"$WORK/cl-missing.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$WORK/cl-missing.jsonl" >/dev/null 2>&1 \
  && fail "cluster accepted a grouping that left a defect out"
printf '%s\n%s\n' \
  '{"members":["cl-one#1","cl-two#1"],"file":"a.py","severity":"P2","summary":"x"}' \
  '{"members":["cl-one#1","cl-one#2"],"file":"a.py","severity":"P2","summary":"y"}' >"$WORK/cl-dup.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$WORK/cl-dup.jsonl" >/dev/null 2>&1 \
  && fail "cluster accepted a defect placed in two groups"
printf '%s\n' '{"members":["cl-one#1","cl-one#2","cl-two#1","cl-three#1"],"file":"a.py","severity":"P2","summary":"x"}' >"$WORK/cl-unknown.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$WORK/cl-unknown.jsonl" >/dev/null 2>&1 \
  && fail "cluster accepted a group naming a defect the commit never recorded"
# A group naming a file none of its members cite would place the canonical defect in code the
# raters never mentioned, which reads downstream exactly like a defect that is really there.
printf '%s\n%s\n' \
  '{"members":["cl-one#1","cl-two#1"],"file":"elsewhere.py","line":3,"severity":"P2","summary":"x"}' \
  '{"members":["cl-one#2"],"file":"a.py","line":9,"severity":"P3","summary":"y"}' >"$WORK/cl-wrongfile.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$WORK/cl-wrongfile.jsonl" >/dev/null 2>&1 \
  && fail "cluster accepted a group claiming a file none of its members cite"
# A member that cites no file cannot contradict the group's: early runs left the field empty and
# put the path in the summary, so refusing those would reject a correct grouping.
printf '%s\n' '{"defect_id":"cl-one#3","file":"","line":null,"severity":"P3","summary":"path only in text","caught_by":["sol-low"]}' >>"$CSD/benches/cl-one/defects.jsonl"
printf '%s\n%s\n%s\n' \
  '{"members":["cl-one#1","cl-two#1"],"file":"a.py","line":3,"severity":"P2","summary":"x"}' \
  '{"members":["cl-one#2"],"file":"a.py","line":9,"severity":"P3","summary":"y"}' \
  '{"members":["cl-one#3"],"file":"a.py","line":1,"severity":"P3","summary":"z"}' >"$WORK/cl-nofile.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$WORK/cl-nofile.jsonl" >/dev/null \
  || fail "cluster refused a group whose member cites no file at all"
rm -f "$CSD/defects/${CNAME}__${CSHA:0:7}.jsonl"
python3 - "$CSD/benches/cl-one/defects.jsonl" <<'PY'
import sys
path = sys.argv[1]
lines = [line for line in open(path) if '"cl-one#3"' not in line]
open(path, "w").writelines(lines)
PY

# Trailing junk means the judge's output was truncated or doubled, not that the last group won.
printf '%s\n%s\n' "$(cat "$CGROUPS")" 'not json at all' >"$WORK/cl-junk.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$WORK/cl-junk.jsonl" >/dev/null 2>&1 \
  && fail "cluster accepted a groups file with trailing junk"
# A run of this commit that was never adjudicated leaves the canonical list short, and short is
# indistinguishable from complete once it is written.
mv "$CSD/benches/cl-two/defects.jsonl" "$WORK/cl-two-defects.jsonl"
# The grouping must cover only what remains, or the refusal under test is masked by the
# unknown-member guard firing on cl-two's now-absent defect instead.
printf '%s\n%s\n' \
  '{"members":["cl-one#1"],"file":"a.py","line":3,"severity":"P2","summary":"x"}' \
  '{"members":["cl-one#2"],"file":"a.py","line":9,"severity":"P3","summary":"y"}' >"$WORK/cl-short.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$WORK/cl-short.jsonl" >/dev/null 2>&1 \
  && fail "cluster accepted a commit with an unadjudicated run"
mv "$WORK/cl-two-defects.jsonl" "$CSD/benches/cl-two/defects.jsonl"

# The same sha reachable from two repositories is the failure that made a whole night's
# analysis silently skip two commits; merging across them would repeat it.
mkdir -p "$CSD/benches/cl-three"
python3 - "$CSD/benches/cl-three" "$CSHA" <<'PY'
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
(directory / "meta.json").write_text(json.dumps({
    "run_id": "cl-three", "commit": sys.argv[2], "repo": "/nonexistent-repo", "raters": [],
    "rater_runs": [], "durations": {},
    "started": "2026-07-26T00:00:00+00:00", "finished": "2026-07-26T00:00:01+00:00",
}))
(directory / "defects.jsonl").write_text(json.dumps({
    "defect_id": "cl-three#1", "file": "a.py", "line": 1, "severity": "P2",
    "summary": "elsewhere", "caught_by": ["sol-low"],
}) + "\n")
PY
printf '%s\n' '{"run_id":"cl-three","rater":"sol-low","repo":"another-repo"}' >>"$CSD/reviews.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$CGROUPS" >/dev/null 2>&1 \
  && fail "cluster merged defects from two repositories under one commit"
# A run that confirmed nothing still names the commit and repository it reviewed, so it has to
# count towards the refusals: otherwise the foreign repository hides behind an empty list.
: >"$CSD/benches/cl-three/defects.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$CGROUPS" >/dev/null 2>&1 \
  && fail "cluster ignored a second repository whose run confirmed no defects"
rm -rf "$CSD/benches/cl-three"
: >"$CSD/reviews.jsonl"

# The repository a run actually reviewed wins over what the corpus remembers: the corpus is the
# fallback for a reviewed copy that is gone, not an override that hides a genuine move.
printf '%s\n%s\n' \
  '{"run_id":"cl-one","rater":"sol-low","repo":"stale-name"}' \
  '{"run_id":"cl-two","rater":"sol-low","repo":"stale-name"}' >"$CSD/reviews.jsonl"
# Cleared first: the happy path above already wrote this file, and finding it afterwards would
# hold whichever name the code chose.
rm -f "$CSD/defects/${CNAME}__${CSHA:0:7}.jsonl" "$CSD/defects/stale-name__${CSHA:0:7}.jsonl"
WORKER_STATS_DIR="$CSD" "$SCRIPT" cluster "$CSHA" --groups "$CGROUPS" >/dev/null \
  || fail "cluster refused a grouping whose runs still resolve"
assert test -f "$CSD/defects/${CNAME}__${CSHA:0:7}.jsonl"
assert test "$(jq -r -s '.[0].repo' "$CSD/defects/${CNAME}__${CSHA:0:7}.jsonl")" = "$CNAME"
assert test ! -f "$CSD/defects/stale-name__${CSHA:0:7}.jsonl"
: >"$CSD/reviews.jsonl"
rm -f "$CSD/defects/${CNAME}__${CSHA:0:7}.jsonl"

# The frontier engine decides which cells go into a review tier, so its arithmetic is asserted
# against numbers worked out by hand rather than against whatever it happens to print.
FSD="$WORK/frontier-stats"
mkdir -p "$FSD/defects"
python3 - "$FSD" <<'PY'
import json
import pathlib
import sys

stats = pathlib.Path(sys.argv[1])
# fast was attempted four times on each commit, slow once: the union of everything fast ever
# found would rank it above slow purely for having been sampled four times as often. One of
# fast's attempts on bbbbbbb errored, which is an attempt that found nothing, not a non-attempt.
attempts = []
for commit in ("aaaaaaa", "bbbbbbb"):
    for attempt in range(1, 5):
        errored = commit == "bbbbbbb" and attempt == 4
        attempts.append((f"{commit}-fast-{attempt}", commit, "oc-kimik3", 30_000, errored))
    attempts.append((f"{commit}-slow", commit, "sol-max", 600_000, False))
    # Recorded under the pre-rename spec, the way the real legacy runs did: the denominator
    # lands under the current name only because normalisation is applied to both sides.
    attempts.append((f"{commit}-mid", commit, "agy-flash-medium-skill", 120_000, False))
# Present on one commit only, so it may never be compared with the others.
attempts.append(("aaaaaaa-partial", "aaaaaaa", "sol-low", 60_000, False))

rows = []
for run_id, commit, rater, duration, errored in attempts:
    directory = stats / "benches" / run_id
    directory.mkdir(parents=True, exist_ok=True)
    # `raters` lists only the cells that answered, so an errored attempt survives solely in
    # `rater_runs` — reading `raters` for the denominator is how a failure becomes invisible.
    (directory / "meta.json").write_text(json.dumps({
        "run_id": run_id, "commit": commit, "repo": "/fixture",
        "raters": [] if errored else [rater],
        "rater_runs": [{"rater": rater, "duration_ms": duration, "exit_code": 1 if errored else 0,
                        **({"errored": True} if errored else {})}],
        "durations": {rater: duration},
        "started": "2026-07-26T00:00:00+00:00", "finished": "2026-07-26T00:00:01+00:00",
    }))
    (directory / "defects.jsonl").write_text("")
    if not errored:
        rows.append({"run_id": run_id, "commit": commit, "rater": rater,
                     "duration_ms": duration, "repo": "fixture"})
with open(stats / "reviews.jsonl", "w") as handle:
    for row in rows:
        handle.write(json.dumps(row) + "\n")

def catches(pairs):
    return [{"run_id": run, "rater": rater} for rater, run in pairs]

defects = {
    "aaaaaaa": [
        # fast found this in two of its four runs -> rate 1/2; slow in its only run -> rate 1.
        {"defect_id": "fixture@aaaaaaa#1", "repo": "fixture", "commit": "aaaaaaa",
         "file": "a.py", "line": 1, "severity": "P1", "summary": "both",
         "caught_by": ["oc-kimik3", "sol-max"],
         "catches": catches([("oc-kimik3", "aaaaaaa-fast-1"), ("oc-kimik3", "aaaaaaa-fast-3"),
                             ("sol-max", "aaaaaaa-slow")])},
        # Only the legacy-named agy cell found it, under the pre-rename spec.
        {"defect_id": "fixture@aaaaaaa#2", "repo": "fixture", "commit": "aaaaaaa",
         "file": "a.py", "line": 2, "severity": "P2", "summary": "legacy name",
         "caught_by": ["agy-flash-medium-skill"],
         "catches": catches([("agy-flash-medium-skill", "aaaaaaa-mid")])},
        # Nobody comparable found it: it must still count against the total.
        {"defect_id": "fixture@aaaaaaa#3", "repo": "fixture", "commit": "aaaaaaa",
         "file": "a.py", "line": 3, "severity": "P3", "summary": "missed by all",
         "caught_by": [], "catches": []},
    ],
    "bbbbbbb": [
        {"defect_id": "fixture@bbbbbbb#1", "repo": "fixture", "commit": "bbbbbbb",
         "file": "b.py", "line": 1, "severity": "P2", "summary": "slow only",
         "caught_by": ["sol-max"], "catches": catches([("sol-max", "bbbbbbb-slow")])},
    ],
}
for commit, rows in defects.items():
    with open(stats / "defects" / f"fixture__{commit}.jsonl", "w") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")
PY

HOME="$WORK/home" WORKER_STATS_DIR="$FSD" python3 - "$SCRIPT" "$FSD" <<'PY'
import importlib.machinery
import importlib.util
import json
import pathlib
import sys

spec = importlib.util.spec_from_loader(
    "rb", importlib.machinery.SourceFileLoader("rb", sys.argv[1])
)
rb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rb)
stats = pathlib.Path(sys.argv[2])

(by_commit, cells, minutes, excluded, run_counts, errors,
 counted_runs) = rb.frontier_inputs(stats)
# sol-low ran on one commit only and is therefore not comparable with the rest.
assert cells == ["agy-flash36-medium-skill", "oc-kimik3", "sol-max"], cells
assert excluded == ["sol-low"], excluded
# Four attempts on each commit, including the one on bbbbbbb that errored and left no row.
assert run_counts[("aaaaaaa", "oc-kimik3")] == 4, run_counts
assert run_counts[("bbbbbbb", "oc-kimik3")] == 4, run_counts
assert errors[("bbbbbbb", "oc-kimik3")] == 1, errors
assert minutes["oc-kimik3"] == 0.5 and minutes["sol-max"] == 10.0, minutes

rates = rb.hit_rates(by_commit, run_counts, counted_runs)
# Two of four runs found it, so one fresh run has an even chance — not the certainty the
# union of all four runs would imply.
assert rates["fixture@aaaaaaa#1"]["oc-kimik3"] == 0.5, rates["fixture@aaaaaaa#1"]
assert rates["fixture@aaaaaaa#1"]["sol-max"] == 1.0, rates["fixture@aaaaaaa#1"]
# The legacy spec in `catches` resolves to the name the corpus counts runs under.
assert rates["fixture@aaaaaaa#2"] == {"agy-flash36-medium-skill": 1.0}, rates["fixture@aaaaaaa#2"]
assert rates["fixture@aaaaaaa#3"] == {}, rates["fixture@aaaaaaa#3"]
# A catch naming a run the denominator never counted is a numerator with no denominator: it
# produced a rate of 900% and a negative coverage before it was dropped.
phantom = dict(by_commit)
phantom["aaaaaaa"] = list(by_commit["aaaaaaa"])
phantom["aaaaaaa"][0] = dict(
    phantom["aaaaaaa"][0],
    catches=phantom["aaaaaaa"][0]["catches"] + [{"run_id": "never-ran", "rater": "oc-kimik3"}],
)
phantom_rates = rb.hit_rates(phantom, run_counts, counted_runs)
assert phantom_rates["fixture@aaaaaaa#1"]["oc-kimik3"] == 0.5, phantom_rates["fixture@aaaaaaa#1"]
assert all(0.0 <= rate <= 1.0 for per in phantom_rates.values() for rate in per.values())
phantom_found, _ = rb.composition_coverage(phantom, phantom_rates, ["oc-kimik3"] * 2)
assert 0.0 <= phantom_found <= 4.0, phantom_found

repeat_stats = stats.parent / "frontier-repeat-stats"
(repeat_stats / "defects").mkdir(parents=True)
(repeat_stats / "benches" / "repeat-run").mkdir(parents=True)
repeat_defect = {
    "defect_id": "fixture@ccccccc#1", "repo": "fixture", "commit": "ccccccc",
    "file": "c.py", "line": 1, "severity": "P2", "summary": "one catch",
    "caught_by": ["sol-high"],
    "catches": [{"run_id": "repeat-run", "rater": "sol-high"}],
}
(repeat_stats / "defects" / "fixture__ccccccc.jsonl").write_text(
    json.dumps(repeat_defect) + "\n"
)
(repeat_stats / "benches" / "repeat-run" / "meta.json").write_text(json.dumps({
    "run_id": "repeat-run", "commit": "ccccccc", "repo": "/fixture",
    "raters": ["sol-high", "sol-high#2"],
    "rater_runs": [
        {"rater": "sol-high", "duration_ms": 1000, "exit_code": 0},
        {"rater": "sol-high#2", "duration_ms": 1200, "exit_code": 0},
    ],
    "durations": {"sol-high": 1000, "sol-high#2": 1200},
    "started": "2026-07-26T00:00:00+00:00",
    "finished": "2026-07-26T00:00:01+00:00",
}))
(repeat_by_commit, repeat_cells, _, _, repeat_counts, _,
 repeat_counted) = rb.frontier_inputs(repeat_stats)
assert repeat_cells == ["sol-high"], repeat_cells
assert repeat_counts[("ccccccc", "sol-high")] == 2, repeat_counts
assert repeat_counted["ccccccc"] == {
    ("repeat-run", "sol-high"), ("repeat-run", "sol-high#2"),
}, repeat_counted
repeat_rates = rb.hit_rates(repeat_by_commit, repeat_counts, repeat_counted)
assert repeat_rates["fixture@ccccccc#1"]["sol-high"] == 0.5, repeat_rates
print("frontier-rater-repeat-ok")

found, total = rb.composition_coverage(by_commit, rates, ["oc-kimik3"])
assert total == 4, total
assert abs(found - 0.5) < 1e-9, found
# Naming it twice is two independent runs: 1 - 0.5^2.
found_twice, _ = rb.composition_coverage(by_commit, rates, ["oc-kimik3", "oc-kimik3"])
assert abs(found_twice - 0.75) < 1e-9, found_twice
found_pair, _ = rb.composition_coverage(by_commit, rates, ["oc-kimik3", "sol-max"])
assert abs(found_pair - 2.0) < 1e-9, found_pair

# At half a minute only the fast cell fits, and repeating it is the only way to buy coverage.
chosen, covered, proven = rb.best_composition(by_commit, rates, cells, minutes, 0.5, 3)
assert chosen == ["oc-kimik3"] * 3, chosen
assert abs(covered - 0.875) < 1e-9, covered
assert proven is True, proven
# The cap is what stops it, not the data: one more run would still add coverage.
capped, capped_covered, _ = rb.best_composition(by_commit, rates, cells, minutes, 0.5, 1)
assert capped == ["oc-kimik3"] and abs(capped_covered - 0.5) < 1e-9, (capped, capped_covered)
# Nothing slower than the budget may appear, whatever it would have contributed. sol-max is
# the strongest cell in the fixture and takes ten minutes, so a budget under that must exclude
# it — asserting against a budget no cell exceeds would hold with the filter deleted.
tight, _, _ = rb.best_composition(by_commit, rates, cells, minutes, 2.5, 3)
assert tight and all(minutes[cell] <= 2.5 for cell in tight), tight
assert "sol-max" not in tight, tight
roomy, _, _ = rb.best_composition(by_commit, rates, cells, minutes, 10.0, 3)
assert "sol-max" in roomy, roomy
assert rb.best_composition(by_commit, rates, cells, minutes, 0.1, 3) == ([], 0.0, True)

# Greedy takes the cell with the largest immediate gain and cannot recover from it; the
# exhaustive path must, or the tool reports a heuristic as the answer. a+b cover three
# defects, c+d cover four, and greedy starts with a.
counter_rates = {
    "d1": {"a": 1.0, "b": 1.0, "d": 1.0},
    "d2": {"a": 1.0, "c": 1.0},
    "d3": {"b": 1.0, "c": 1.0},
    "d4": {"d": 1.0},
}
counter_defects = {"z": [{"defect_id": name} for name in ("d1", "d2", "d3", "d4")]}
counter_minutes = {name: 1.0 for name in "abcd"}
counter_best, counter_covered, counter_proven = rb.best_composition(
    counter_defects, counter_rates, list("abcd"), counter_minutes, 1.0, 2
)
assert abs(counter_covered - 4.0) < 1e-9, (counter_best, counter_covered)
assert counter_proven is True, counter_proven

# A side billed as one subscription has no pool to ask, and naming its pseudo-account is the
# only way to take that side off the table.
import os
assert rb.pool_account("opencode", set()) == "opencode-go"
os.environ["REVIEW_BENCH_EXCLUDE_OPENCODE"] = "opencode-go"
assert rb.pool_account("opencode", set()) is None
del os.environ["REVIEW_BENCH_EXCLUDE_OPENCODE"]
# The greedy fallback is what runs on the real corpus, where the candidate space is far past
# the exhaustive threshold, and no fixture would ever reach it: the threshold is lowered so the
# path is exercised, and it must return a real composition and admit it is not proven optimal.
exhaustive_limit = rb.EXHAUSTIVE_COMPOSITIONS
rb.EXHAUSTIVE_COMPOSITIONS = 1
greedy, greedy_covered, greedy_proven = rb.best_composition(
    by_commit, rates, cells, minutes, 10.0, 3
)
assert greedy and greedy_covered > 0, (greedy, greedy_covered)
assert greedy_proven is False, greedy_proven
rb.EXHAUSTIVE_COMPOSITIONS = exhaustive_limit
print("frontier-ok")
PY
assert test "$?" -eq 0

# The CLI is what a person runs, and it carries the honesty label and the error column that the
# functions underneath know nothing about.
frontier_out=$(WORKER_STATS_DIR="$FSD" "$SCRIPT" frontier --budgets 0.5,10 --max-cells 2) \
  || fail "frontier refused a fixture corpus"
assert contains "$frontier_out" '(4 canonical defect(s))'
assert contains "$frontier_out" 'excluded (did not run on every commit): 1 cell(s)'
assert contains "$frontier_out" '— best'
assert contains "$frontier_out" 'errored 1/8'
WORKER_STATS_DIR="$FSD" "$SCRIPT" frontier --commits nosuch >/dev/null 2>&1 \
  && fail "frontier accepted a commit with no canonical list"

sed 's/"repo": "fixture"/"repo": "foreign"/; s/"commit": "aaaaaaa"/"commit": "ccccccc"/' \
  "$FSD/defects/fixture__aaaaaaa.jsonl" >"$FSD/defects/foreign__ccccccc.jsonl"
frontier_multi=$(
  WORKER_STATS_DIR="$FSD" "$SCRIPT" frontier --budgets 10 2>&1
) && fail "frontier accepted a repository-spanning default corpus"
assert contains "$frontier_multi" 'fixture [aaaaaaa, bbbbbbb]'
assert contains "$frontier_multi" 'foreign [ccccccc]'
assert contains "$frontier_multi" 'pass --commits'
WORKER_STATS_DIR="$FSD" "$SCRIPT" frontier --commits aaaaaaa,bbbbbbb --budgets 10 \
  >/dev/null || fail "frontier refused an explicit single-repository corpus"
rm -f "$FSD/defects/foreign__ccccccc.jsonl"

# Two repositories whose sha7 collide would merge into one denominator, and the merge would look
# exactly like a cell that ran on both.
# An unreadable meta.json used to be skipped, taking its attempts out of the denominator while
# their catches stayed in the numerator — the state that produced a 900% rate.
mkdir -p "$FSD/benches/corrupt-run"
printf '{ not json' >"$FSD/benches/corrupt-run/meta.json"
WORKER_STATS_DIR="$FSD" "$SCRIPT" frontier --budgets 10 >/dev/null 2>&1 \
  && fail "frontier accepted a corpus containing an unreadable run"
rm -rf "$FSD/benches/corrupt-run"

cp "$FSD/defects/fixture__aaaaaaa.jsonl" "$FSD/defects/other__aaaaaaa.jsonl"
WORKER_STATS_DIR="$FSD" "$SCRIPT" frontier --budgets 10 >/dev/null 2>&1 \
  && fail "frontier merged two repositories sharing a commit prefix"
rm -f "$FSD/defects/other__aaaaaaa.jsonl"

# record stamps the repository a run reviewed, or says plainly that it cannot be traced.
REPO_RUN="$CSD/benches/repo-fixture"
mkdir -p "$REPO_RUN"
python3 - "$REPO_RUN" "$CREPO" "$CSHA" "$WORK/repo-verdicts.jsonl" <<'PY'
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
(directory / "meta.json").write_text(json.dumps({
    "run_id": "repo-fixture", "commit": sys.argv[3], "repo": sys.argv[2],
    "raters": ["sol-low"],
    "rater_runs": [{"rater": "sol-low", "model": "sol", "effort": "low", "side": "codex",
                    "exit_code": 0}],
    "durations": {"sol-low": 1000},
    "started": "2026-07-26T00:00:00+00:00", "finished": "2026-07-26T00:00:01+00:00", "focus": "",
}))
(directory / "findings-sol-low.jsonl").write_text(json.dumps({
    "severity": "P2", "file": "a.py", "line": 1, "summary": "traceable", "rater": "sol-low",
}) + "\n")
pathlib.Path(sys.argv[4]).write_text(
    json.dumps({"rater": "sol-low", "idx": 0, "verdict": "confirmed"}) + "\n"
)
PY
WORKER_STATS_DIR="$CSD" "$SCRIPT" record repo-fixture --verdicts "$WORK/repo-verdicts.jsonl" \
  >/dev/null || fail "record failed on a resolvable repository"
assert test "$(jq -r 'select(.run_id=="repo-fixture") | .repo' "$CSD/reviews.jsonl")" = "$CNAME"
python3 - "$REPO_RUN/meta.json" <<'PY'
import json
import sys

meta = json.loads(open(sys.argv[1]).read())
meta["repo"] = "/gone"
open(sys.argv[1], "w").write(json.dumps(meta))
PY
# A crash between writing the artifacts and appending to the corpus leaves rows with no verdict
# file; a later correction then has to replace them rather than write artifacts over stale rows.
rm -f "$REPO_RUN/verdicts.jsonl"
printf '%s\n' '{"rater":"sol-low","idx":0,"verdict":"duplicate"}' >"$WORK/repo-verdicts-3.jsonl"
orphaned=$(WORKER_STATS_DIR="$CSD" "$SCRIPT" record repo-fixture \
  --verdicts "$WORK/repo-verdicts-3.jsonl") || fail "record failed on rows with no verdict file"
assert contains "$orphaned" 're-adjudicated'
assert test "$(jq -r 'select(.run_id=="repo-fixture") | .duplicate' "$CSD/reviews.jsonl")" = 1
assert test "$(grep -c 'repo-fixture' "$CSD/reviews.jsonl")" -eq 1

# Re-adjudicating a run whose sealed copy has since been deleted rewrites its rows, and must
# keep the repository the corpus already knows: seven runs in the real corpus name a temporary
# clone that is long gone, so resolving to nothing here would strip what a migration filled in.
printf '%s\n' '{"rater":"sol-low","idx":0,"verdict":"false_positive"}' >"$WORK/repo-verdicts-2.jsonl"
readjudicated=$(WORKER_STATS_DIR="$CSD" "$SCRIPT" record repo-fixture \
  --verdicts "$WORK/repo-verdicts-2.jsonl") || fail "re-adjudication failed on a deleted sealed copy"
assert contains "$readjudicated" 're-adjudicated'
assert test "$(jq -r 'select(.run_id=="repo-fixture") | .repo' "$CSD/reviews.jsonl")" = "$CNAME"
: >"$CSD/reviews.jsonl"
untraceable=$(WORKER_STATS_DIR="$CSD" "$SCRIPT" record repo-fixture \
  --verdicts "$WORK/repo-verdicts.jsonl") || fail "record failed on an unresolvable repository"
assert contains "$untraceable" 'cannot be traced back to code'
assert test "$(jq -r 'select(.run_id=="repo-fixture") | has("repo")' "$CSD/reviews.jsonl")" = false

python3 - "$SD/benches/run-fixture/meta.json" <<'PY'
import json
import sys

meta = json.loads(open(sys.argv[1]).read())
assert isinstance(meta.get("rater_runs"), list)
for run in meta["rater_runs"]:
    if run.get("errored"):
        assert run["rater"] not in meta.get("completed_raters", meta["raters"]), \
            f"errored rater {run['rater']} should not be completed"
print("errored-rater-exclusion-ok")
PY
assert test "$?" -eq 0

stats_json=$(WORKER_STATS_DIR="$SD" "$STATS" --json) || fail "worker-stats review JSON failed"
python3 - "$stats_json" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
rows = {f"{r['rater_model']}-{r['rater_effort']}":r for r in data["reviews"]["rows"]}
sol = rows["sol-medium"]
opus = rows["opus-medium"]
assert round(sol["findings_per_bench"], 3) == 3
assert round(sol["confirmed_pct"], 3) == 0.667
assert round(sol["false_positive_pct"], 3) == 0.333
assert round(sol["unique_catch_rate"], 3) == 0.5
assert round(sol["miss_rate"], 3) == 0.333
assert sol["weighted_score"] == 7
assert opus["weighted_score"] == 1
print("worker-stats-review-math-ok")
PY
assert test "$?" -eq 0
assert test -f "$WORK/prompt-v1-ok"
assert test -f "$WORK/verify-ms-ok"

table=$(WORKER_STATS_DIR="$SD" "$STATS") || fail "worker-stats static view failed"
assert contains "$table" 'Fable-rework leaderboard'
assert contains "$table" 'Review benchmark leaderboard'
assert contains "$table" 'sol/medium'

listing=$(WORKER_STATS_DIR="$SD" "$SCRIPT" list) || fail "list failed"
assert contains "$listing" 'run-fixture'
assert contains "$listing" 'adjudicated'

# A run where every cell errored can never leave `pending`, and calling it that buries the
# runs that genuinely await a verdict.
mkdir -p "$SD/benches/empty-fixture"
python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"run_id":"empty-fixture","commit":"abcdef0123456789","raters":[],"rater_runs":[],"started":"2026-07-20T00:00:00+00:00","finished":"2026-07-20T00:01:00+00:00"}))' \
  "$SD/benches/empty-fixture/meta.json"
empty_listing=$(WORKER_STATS_DIR="$SD" "$SCRIPT" list) || fail "list failed on a rater-less run"
assert contains "$empty_listing" 'every cell errored'
assert test "$(grep -c 'pending' <<<"$empty_listing")" -eq 0


# Every option cmd_run reads must exist on the command line: a flag wired only into the
# code path crashes the whole run at the first cell.
run_help="$("$SCRIPT" run --help 2>&1)"
assert contains "$run_help" "--verify"
assert contains "$run_help" "--leg"
review_help="$("$SCRIPT" review --help 2>&1)"
assert contains "$review_help" "--tier"
assert contains "$review_help" "{T0,T1,T2,T3}"
leg_conflict="$("$SCRIPT" run 143fc2f --leg --raters oc-kimik3 2>&1 || true)"
assert contains "$leg_conflict" "not allowed with argument --leg"
OCSD="$WORK/oc-repeat-health"
mkdir -p "$OCSD/benches/repeat-fixture"
python3 - "$OCSD/benches/repeat-fixture/meta.json" <<'PY'
import json
import sys

rows = [
    {
        "rater": "oc-kimik3", "side": "opencode", "duration_ms": 1000,
        "findings": 2, "errored": False,
    },
    {
        "rater": "oc-kimik3#2", "side": "opencode", "duration_ms": 3000,
        "findings": 0, "errored": True, "stderr": "fixture failure",
    },
]
with open(sys.argv[1], "w") as handle:
    json.dump({"run_id": "repeat-fixture", "rater_runs": rows}, handle)
PY
oc_repeat_table="$(WORKER_STATS_DIR="$OCSD" CLAUDEB_DIR="$WORK/claudeb-fixture" \
  "$SCRIPT" oc-models 2>&1)"
assert test "$(grep -Ec '^oc-kimik3 +2 +1 ' <<<"$oc_repeat_table")" -eq 1
assert test "$(grep -c '^oc-kimik3#2 ' <<<"$oc_repeat_table")" -eq 0
oc_table="$(WORKER_STATS_DIR="$SD" CLAUDEB_DIR="$WORK/claudeb-fixture" "$SCRIPT" oc-models 2>&1)"
assert contains "$oc_table" "measured capability"
assert contains "$oc_table" "oc-grok45"
tiers_table="$("$SCRIPT" tiers 2>&1)"
for tier_budget in "T0 (2 min)" "T1 (6 min)" "T2 (10 min)" "T3 (20 min)"; do
  assert contains "$tiers_table" "$tier_budget"
done
assert contains "$tiers_table" "eco (default):"
assert contains "$tiers_table" "max:"
for cell in "oc-kimik3 x4" "oc-grok45-low x3" agy-pro-high-skill \
  "agy-flash35-medium-skill x2" "agy-flash35-medium-skill x3" \
  agy-flash35-high-skill agy-flash36-medium-skill \
  opus-low sol-low sol-low-bare agy-pro-low-skill \
  opus-medium sol-medium-bare opus-high sol-high "sol-high-bare x2" sol-xhigh \
  sol-xhigh-bare sol-high-bare "sol-max x2" sol-max-bare; do
  assert contains "$tiers_table" "$cell"
done
assert contains "$tiers_table" \
  "agy-flash35-low-skill: server serves Medium for the low model id (model_mismatch, 2026-07)"
assert test "$(grep -Ec '^  (eco \\(default\\)|max):.*agy-flash35-low-skill' <<<"$tiers_table")" -eq 0
owner_table="$("$SCRIPT" tiers --table 2>&1)"
assert contains "$owner_table" "T1 max"
assert contains "$owner_table" "kimi x4"
assert contains "$owner_table" "cover"
assert contains "$owner_table" "agy-flash35-low-skill:"
assert test "$(grep -c '^T0 max' <<<"$owner_table")" -eq 0
max_without_tier="$("$SCRIPT" run HEAD --max 2>&1 || true)"
assert contains "$max_without_tier" "--max requires --tier"
tier_guard="$("$SCRIPT" run HEAD --tier T2 2>&1 || true)"
assert contains "$tier_guard" "T2 runs ~10 min"
assert contains "$tier_guard" "run_in_background"

REPORT_HOOK="${REVIEW_REPORT_HOOK:-"$ROOT/../claude-setup/hooks/review-report-nudge.sh"}"
if test -x "$REPORT_HOOK"; then
  for hook_tool in Bash Read; do
    hook_output="$(jq -nc --arg tool "$hook_tool" \
      --arg output $'before\nREVIEW-REPORT-BEGIN\nT1 report\nREVIEW-REPORT-END\nafter' \
      '{tool_name:$tool,tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
    assert contains "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$hook_output")" \
      "verbatim as a fenced code block"
  done
  # A run read back with `tail -N` can land one line short of the opening marker, and a hook
  # keyed on the pair goes quiet on exactly the output that most needs the nudge.
  hook_truncated="$(jq -nc \
    --arg output $'T1 report\nfindings: none\nREVIEW-REPORT-END' \
    '{tool_name:"Bash",tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
  assert contains "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$hook_truncated")" \
    "re-read the block"
  # The marker has to be the whole line: a report is not what a sentence mentioning one is.
  hook_inline="$(jq -nc --arg output 'talking about REVIEW-REPORT-END in passing' \
    '{tool_name:"Bash",tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
  assert test -z "$hook_inline"
  hook_without_output="$(jq -n --rawfile source "$SCRIPT" \
    '{tool_name:"Read",tool_response:{content:$source}}' | "$REPORT_HOOK")"
  assert test -z "$hook_without_output"
else
  printf 'SKIP: review report hook behavior (%s is unavailable)\n' "$REPORT_HOOK"
fi

printf 'PASS: %s assertions; canonical review tiers sharing one OpenCode/Gemini floor with no retired cell in them, cells retired by measurement refused with their counts, tier CLI and fixture-backed tier execution, review receipts and receipt-relative suggestions with missing-object fallback, fixture diff suggestions across all sizes and escalations, rater grammar (incl. agy and OpenCode families), CLI option surface, worker-pick affordability, gap-driven auto-pick, Codex/Claude normalization, fixture-driven agy and OpenCode fail-closed handling, usage artifacts, resolved-model metadata, SHA-pinned prompt and verifier content, prompt-file transport and max-token fallback, agy sealed clones with no descendant-history leak and /code-review Markdown adaptation, persisted verdict/defect attribution written before the corpus row, re-adjudication replacing the rows of a run instead of silently keeping the old ones, recovered-verdict provenance, a clean-review marker recognised inside Claude and Codex envelopes, the Gemini per-model wall reaching SIDE_WALL from the log, a verifier wall recorded before the gate is released, tiered path resolution with the parent tree as fallback, the repository a run reviewed stamped into the corpus or reported untraceable, cross-run defect reconciliation with severity taken from the members and every incomplete or repository-spanning grouping refused, the session account usable only behind its opt-in and a per-side account exclusion honoured for pooled and fixed sides alike, the frontier engine scoring one fresh run per named cell with legacy specs normalised and a repeat priced as an independent run, record aggregation/dedupe, unique catches, misses, weighted review score, run listing, 429-detection (fixed), per-side account ordering with Gemini rotation onto a second account after a usage wall, errored-rater exclusion, and cross-side parallelism result assembly\n' "$asserts"
