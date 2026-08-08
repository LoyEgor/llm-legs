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
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types

loader = importlib.machinery.SourceFileLoader("review_bench", sys.argv[1])
spec = importlib.util.spec_from_loader("review_bench", loader)
rb = importlib.util.module_from_spec(spec)
loader.exec_module(rb)
# The frame is the contract, not a marker string: a header of the word centered in '=' to exactly
# 50 characters, a footer of 50 of them, and both parseable by the shapes every consumer keys on.
assert rb.REPORT_BEGIN == "=" * 21 + " review " + "=" * 21, rb.REPORT_BEGIN
assert rb.REPORT_END == "=" * 50, rb.REPORT_END
assert len(rb.REPORT_BEGIN) == 50 and len(rb.REPORT_END) == 50
assert re.fullmatch(r"=+ [a-z]+ =+", rb.REPORT_BEGIN), rb.REPORT_BEGIN
assert re.fullmatch(r"={10,}", rb.REPORT_END), rb.REPORT_END
# The footer shape must not swallow the header: a consumer that reads the block by its end would
# close it on the line that opens it.
assert not re.fullmatch(r"={10,}", rb.REPORT_BEGIN)
# An odd remainder goes to the right, and the total stays exactly 50 whatever the word costs.
for frame_word, frame_left in (("review", 21), ("notes", 21), ("comments", 20)):
    frame_header = rb.report_frame_header(frame_word)
    assert len(frame_header) == 50, frame_header
    assert frame_header == "=" * frame_left + f" {frame_word} " + "=" * (
        50 - frame_left - len(frame_word) - 2
    ), frame_header
# A word with no room left widens the line rather than spending its padding: a header ending on
# the word is no longer the shape its consumers find the block by, so it opens nothing.
for long_word in ("a" * 48, "a" * 60):
    long_header = rb.report_frame_header(long_word)
    assert re.fullmatch(r"=+ [a-z]+ =+", long_header), long_header
    assert len(long_header) > 50, long_header
rb.REPORT_BEGIN = "FIXTURE-REVIEW-REPORT-BEGIN"
rb.REPORT_END = "FIXTURE-REVIEW-REPORT-END"
assert rb.TRIAGE_PENDING == "REVIEW-TRIAGE-PENDING"
rb.TRIAGE_PENDING = "FIXTURE-REVIEW-TRIAGE-PENDING"
fixtures = pathlib.Path(sys.argv[2])
repo = pathlib.Path(sys.argv[3])
work = pathlib.Path(sys.argv[4])
live_shell_pid = int(sys.argv[5])
fixture_home = work / "home"
fixture_home.mkdir()
os.environ["HOME"] = str(fixture_home)
# The launching chat's id lands in every receipt and progress document, and those are asserted
# whole here: whether the suite runs inside a chat must not decide what the fixtures contain.
os.environ.pop("CLAUDE_CODE_SESSION_ID", None)


def clear_walls():
    (rb.state_dir() / rb.WALL_STATE_FILE).unlink(missing_ok=True)


def grant_owner_panels(*panels, age=0.0):
    """The markers review-owner-gate.sh touches when Egor names a panel, in the store the current
    environment points at — the owner-only panels are refused without them.
    """
    directory = rb.owner_grant_dir()
    directory.mkdir(parents=True, exist_ok=True)
    for panel in panels:
        path = directory / panel
        path.touch()
        os.utime(path, (time.time() - age,) * 2)
    return directory


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
# One spelling for every surface a human reads: the tiers table and the report frames render the
# same cell through the same function, so a name learned on one is the name on the other. Each
# name carries only what the pool needs to tell it apart — nothing here is a hand-kept list, so a
# second variant entering a tier renames its family without anyone editing a table.
assert rb.short_cell_name(rb.parse_rater("oc-kimik3")) == "kimi"
assert rb.short_cell_name(rb.parse_rater("oc-dsv4flash")) == "deepseek"
# One effort in the pool, so naming it separates nothing — and one version of the family, so the
# digits stay off even though the machine spec carries them.
assert rb.short_cell_name(rb.parse_rater("oc-grok45-low")) == "grok"
# Both Flash models run, so the digits are what tells them apart; both efforts of each run, so
# the effort is too. Neither is spelled anywhere but in this derivation.
assert rb.short_cell_name(rb.parse_rater("agy-flash36-medium-skill")) == "gem-flash36-med"
assert rb.short_cell_name(rb.parse_rater("agy-flash36-high-skill")) == "gem-flash36-high"
assert rb.short_cell_name(rb.parse_rater("agy-flash35-medium-skill")) == "gem-flash35-med"
assert rb.short_cell_name(rb.parse_rater("agy-flash35-high-skill")) == "gem-flash35-high"
# Only pro-high remains in a tier, so the pool needs nothing to tell it from a sibling. A bench
# run that also holds pro-low still separates them, and separates them the way a report must:
# the cell the pool can launch keeps the spelling it has everywhere else, and the one no tier
# can launch is the one that gains a mark.
assert rb.short_cell_name(rb.parse_rater("agy-pro-high-skill")) == "gem-pro"
assert [
    rb.short_cell_name(rater, rb.report_name_scheme(
        ["agy-pro-high-skill", "agy-pro-low-skill"]))
    for rater in (rb.parse_rater("agy-pro-high-skill"), rb.parse_rater("agy-pro-low-skill"))
] == ["gem-pro", "gem-pro-low"]
# The word never reaches a rendered name: every agy cell runs the skill, so there is nothing for
# a mark to separate.
assert "skill" not in rb.short_cell_name(rb.parse_rater("agy-pro-high-skill"))
# Claude and Codex effort is a launch parameter — the same cell runs at another effort next
# round — so it is spelled even where this pool holds one of them.
assert rb.short_cell_name(rb.parse_rater("opus-medium")) == "opus-med"
assert rb.short_cell_name(rb.parse_rater("sonnet-xhigh")) == "sonnet-xhigh"
# Codex runs the review skill unless `-bare` opts out, and both kinds are in the pool: the
# skill-less one carries the mark, the skilled one is unmarked — including at an effort whose
# only cell is bare, where dropping it would read as the skilled run beside it.
assert rb.short_cell_name(rb.parse_rater("sol-low")) == "sol-low"
assert rb.short_cell_name(rb.parse_rater("sol-low-bare")) == "sol-low-bare"
assert rb.short_cell_name(rb.parse_rater("sol-medium-bare")) == "sol-med-bare"
assert rb.short_cell_name(rb.parse_rater("oc-grok45-low-google")) == "grok-google"
# The whole pool at once, because the property is that no two cells collide and no name says
# more than it must.
pool_names = [rb.short_cell_name(rater) for rater in rb.review_pool_raters()]
assert sorted(set(pool_names)) == [
    "deepseek", "gem-flash35-high", "gem-flash35-med", "gem-flash36-high", "gem-flash36-med",
    "gem-pro", "grok", "kimi", "opus-high", "opus-low", "opus-med", "sol-high",
    "sol-high-bare", "sol-low", "sol-low-bare", "sol-max", "sol-max-bare", "sol-med-bare",
    "sol-xhigh", "sol-xhigh-bare",
], sorted(set(pool_names))
assert len(set(pool_names)) == len(
    {rb.rater_family(rater["spec"]) for rater in rb.review_pool_raters()}
), sorted(set(pool_names))
# A second version of a single-version family renames it the moment it joins THE POOL — the
# digits are derived from the tiers, never declared.
stored_pool_raters = rb._REVIEW_POOL_RATERS
try:
    rb._REVIEW_POOL_RATERS = list(rb.review_pool_raters()) + [rb.parse_rater("oc-kimik27code")]
    kimi_two_versions = rb.name_scheme()
finally:
    rb._REVIEW_POOL_RATERS = stored_pool_raters
assert rb.short_cell_name(rb.parse_rater("oc-kimik3"), kimi_two_versions) == "kimik3"
assert rb.short_cell_name(rb.parse_rater("oc-kimik27code"), kimi_two_versions) == "kimik27code"
# A cell only a stored run holds is named against the pool, never over it. Reading one report
# cannot respell a pool cell, or the same model would be `grok` in the tiers table and `grok45`
# in the report a chat reads beside it.
assert rb.human_cell_name("agy-flash35-low-skill") == "gem-flash35-low"
retired_scheme = rb.report_name_scheme(["agy-flash36-medium-skill", "agy-flash36-low-skill"])
assert rb.human_cell_name("agy-flash36-medium-skill", retired_scheme) == "gem-flash36-med"
assert rb.human_cell_name("agy-flash36-low-skill", retired_scheme) == "gem-flash36-low"
# xAI's own grok next to the pool's: the newcomer takes the effort that separates them, and the
# pool cell keeps the name it has on every other surface.
xai_scheme = rb.report_name_scheme(["oc-grok45-low", "grok-low"])
assert rb.human_cell_name("oc-grok45-low", xai_scheme) == "grok"
assert rb.human_cell_name("grok-low", xai_scheme) == "grok-low"
# Same on the skill axis, where the pool cell is the unskilled one: the mark goes on the arrival,
# not on the cell whose name predates it.
skilled_opus_scheme = rb.report_name_scheme(["opus-medium", "opus-medium-skill"])
assert rb.human_cell_name("opus-medium", skilled_opus_scheme) == "opus-med"
assert rb.human_cell_name("opus-medium-skill", skilled_opus_scheme) == "opus-med-skill"
# And the table that teaches those names is the same bytes after such a report as before it: the
# scheme every surface shares is memoized, so a report reading its own cells into it would leave
# the tiers table renamed for the rest of the process.
def rendered_tiers_table():
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        rb.cmd_tiers_table()
    return buffer.getvalue()

tiers_table_before = rendered_tiers_table()
newcomer_rows = [
    {"rater": spec, "side": rb.parse_rater(spec)["side"], "duration_ms": 1000,
     "findings": 0, "exit_code": 0}
    for spec in ("grok-low", "opus-medium-skill", "oc-grok45-low", "opus-medium")
]
newcomer_dir = work / "newcomer-report"
newcomer_dir.mkdir()
newcomer_report = rb.report_lines(newcomer_dir, {
    "run_id": "newcomer", "raters": [row["rater"] for row in newcomer_rows],
    "rater_runs": newcomer_rows,
    "started": "2026-07-30T00:00:00+00:00", "finished": "2026-07-30T00:00:01+00:00",
})
newcomer_cells = [line for line in newcomer_report if line.startswith("cells:")][0]
assert "grok 0" in newcomer_cells and "grok-low 0" in newcomer_cells, newcomer_cells
assert "opus-med 0" in newcomer_cells and "opus-med-skill 0" in newcomer_cells, newcomer_cells
assert rendered_tiers_table() == tiers_table_before
# The report frames read the same table through the spec they store.
assert rb.human_cell_name("oc-kimik3#2") == "kimi"
assert rb.human_cell_name("sol-high-bare") == "sol-high-bare"
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
assert rb.report_lines(max_tier_dir, max_tier_meta)[0].startswith(
    "review-bench panel · T3 max · "
), rb.report_lines(max_tier_dir, max_tier_meta)[0]
# Every cell that completed, the empty-handed ones included: a row listing only the cells that
# found something reads exactly like a run where the rest never started.
max_tier_cells = [
    line for line in rb.report_lines(max_tier_dir, max_tier_meta)
    if line.startswith("cells:")
]
assert len(max_tier_cells) == 1, rb.report_lines(max_tier_dir, max_tier_meta)
# Under the same names every other row of the block uses: a reader comparing the cell row against
# the errored one below it would otherwise be matching slugs against model names by hand.
assert max_tier_cells[0].split(":", 1)[1].strip() == " · ".join(
    f"{rb.human_cell_name(row['rater'])} 0" for row in max_tier_rows
), max_tier_cells[0]
assert "oc-kimik3" not in max_tier_cells[0], max_tier_cells[0]
# A summary written before the count was stored costs its own cell a number, and nothing else:
# reading the key outright takes the whole block down, errored rows and all, on the one run whose
# failures the reader most needs.
legacy_cells_meta = {
    "run_id": "legacy-cells",
    "raters": ["opus-medium", "sol-high"],
    "rater_runs": [
        {"rater": "opus-medium", "side": "claude", "duration_ms": 1000, "exit_code": 0},
        {"rater": "sol-high", "side": "codex", "duration_ms": 1000, "exit_code": 2,
         "errored": True, "stderr": "boom"},
    ],
    "started": "2026-07-30T00:00:00+00:00",
    "finished": "2026-07-30T00:00:01+00:00",
}
legacy_cells_dir = work / "legacy-cells-report"
legacy_cells_dir.mkdir()
legacy_cells_summary = rb.bench_summary(legacy_cells_dir, legacy_cells_meta)
for cell in legacy_cells_summary["cells"]:
    cell.pop("findings")
stored_bench_summary = rb.bench_summary
rb.bench_summary = lambda *summary_args, **summary_kwargs: legacy_cells_summary
try:
    legacy_cells_report = rb.report_lines(legacy_cells_dir, legacy_cells_meta)
finally:
    rb.bench_summary = stored_bench_summary
legacy_cells_row = [line for line in legacy_cells_report if line.startswith("cells:")]
assert len(legacy_cells_row) == 1, legacy_cells_report
assert legacy_cells_row[0].split(":", 1)[1].strip() == "opus-med 0", legacy_cells_row[0]
assert any(line.startswith("errored:") for line in legacy_cells_report), legacy_cells_report
pending_report = io.StringIO()
with contextlib.redirect_stdout(pending_report):
    rb.emit_report(max_tier_dir, max_tier_meta)
# An untriaged run gets no markers: they are what the report hook keys on, and a run of cells
# carrying them is exactly the empty report that used to reach the reader.
assert rb.REPORT_BEGIN not in pending_report.getvalue()
assert rb.REPORT_END not in pending_report.getvalue()
pending_report_lines = pending_report.getvalue().splitlines()
assert pending_report_lines[0] == (
    f"{rb.TRIAGE_PENDING} max-tier-report · 0 finding(s) to triage"
)
assert pending_report_lines[1] == (
    "report with: review-bench record max-tier-report --no-corpus"
)
marked_report = io.StringIO()
with contextlib.redirect_stdout(marked_report):
    rb.emit_report(max_tier_dir, max_tier_meta, [])
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
assert "slowest completed: sol-low 1 sec" in duration_header
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
    line.startswith("not run:") and line.endswith("sol-low")
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
assert "sol-low (throttled)" in reason_report, reason_report
# Nothing recognisable in the text leaves the exit code as the only fact left to print, and a
# cell that said nothing at all is the same case: naming the silence discards that last fact.
assert "kimi (exit 3)" in reason_report, reason_report
silent_meta = dict(
    duration_meta,
    raters=["sol-low"],
    rater_runs=[{"rater": "sol-low", "exit_code": 5, "errored": True, "stderr": ""}],
)
assert "sol-low (exit 5)" in "\n".join(rb.report_lines(duration_dir, silent_meta))

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
assert "verifier:     kimi 3 · qwen37plus 2 — 5 checked, 3 rejected" in chain_report, \
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
assert "verifier:     kimi — 0 checked, 0 rejected, 2 kept unchecked" in walled_report, \
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
assert "verifier:     kimi — 4 rejected" in legacy_verifier_report, legacy_verifier_report
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
assert "verifier:     kimi — 0 rejected" in legacy_kept_all_report.splitlines(), \
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
assert "verifier:     kimi — 1 rejected, 3 kept unchecked" in legacy_walled_report, \
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
assert "verifier:     kimi — 0 rejected, 2 kept unchecked" in legacy_wall_only_report, \
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
assert "verifier:     kimi — nothing to check" in nothing_report, nothing_report
empty_off_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    raters=["oc-kimik3"],
    rater_runs=[{"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 0}],
)))
assert "verifier:     off — nothing to check" in empty_off_report, empty_off_report
off_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    raters=["oc-kimik3"],
    rater_runs=[{"rater": "oc-kimik3", "side": "opencode", "exit_code": 0, "findings": 3}],
)))
assert "verifier:     off — 3 finding(s) unchecked" in off_report, off_report
agy_off_report = "\n".join(rb.report_lines(duration_dir, dict(
    duration_meta,
    raters=["agy-pro-high-skill"],
    rater_runs=[{"rater": "agy-pro-high-skill", "side": "agy", "exit_code": 0, "findings": 2}],
)))
assert "verifier:     off — 2 finding(s) unchecked" in agy_off_report, agy_off_report
# The verifier reaches OpenCode and agy findings only, so a panel without either is not a run
# whose verifier stayed off — nothing was its to touch, and the line would mislead.
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
assert "sol-high 1/1 100% throttled 1" in health_text, health_text
# A cell that never failed has no place in a list of the worst ones.
assert "sol-low" not in health_text, health_text
assert rb.health_lines([]) == ["no recorded runs"]
# A cell retired since the run was recorded must not make the whole run unreadable.
retired_dir = write_health_run("20260103T000000Z-ccc", [
    {"rater": "oc-dsv4flash-medium", "side": "opencode", "account": "prod", "exit_code": 0,
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
assert rb.rater_side("oc-dsv4flash-medium") is None and rb.rater_side("") is None

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
expected_oc_floor = ["oc-kimik3 x2", "oc-grok45-low x2", "oc-dsv4flash x2"]
expected_oc_floor_max = ["oc-kimik3 x3", "oc-grok45-low x3", "oc-dsv4flash x3"]
# The Gemini block is a per-tier ladder because it is billed per run against a subscription
# window: a panel's Gemini price is the sum of its cells, so a shared composition would spend
# T3's quota on a T0 review. Pro is the priciest cell per defect it finds, so it enters only where
# the tier has quota to spare.
expected_agy = {
    "T0": [
        "agy-flash35-medium-skill x3", "agy-flash35-high-skill",
        "agy-flash36-medium-skill", "agy-flash36-high-skill",
    ],
    "T1": [
        "agy-flash35-medium-skill x2", "agy-flash35-high-skill",
        "agy-flash36-medium-skill", "agy-flash36-high-skill x2", "agy-pro-high-skill",
    ],
}
expected_agy["T2"] = expected_agy["T1"]
expected_agy["T3"] = [
    "agy-flash35-medium-skill x3", "agy-flash35-high-skill",
    "agy-flash36-medium-skill", "agy-flash36-high-skill x2", "agy-pro-high-skill",
]
expected_agy_max = {
    "T0": expected_agy["T0"],
    # Equal to T3's default panel today, spelled out anyway: borrowing it would let an edit to
    # T3's eco panel move the T1 ceiling this line exists to pin.
    "T1": [
        "agy-flash35-medium-skill x3", "agy-flash35-high-skill",
        "agy-flash36-medium-skill", "agy-flash36-high-skill x2", "agy-pro-high-skill",
    ],
    "T2": [
        "agy-flash35-medium-skill x3", "agy-flash35-high-skill x2",
        "agy-flash36-medium-skill", "agy-flash36-high-skill x2", "agy-pro-high-skill",
    ],
}
expected_agy_max["T3"] = expected_agy_max["T2"]
expected_floor = {tier: expected_oc_floor + cells for tier, cells in expected_agy.items()}
expected_floor_max = {
    tier: expected_oc_floor_max + cells for tier, cells in expected_agy_max.items()
}
expected_tier_cells = {
    "T0": expected_floor["T0"] + [
        "opus-low", "sol-low", "sol-low-bare",
    ],
    "T1": expected_floor["T1"] + [
        "opus-medium", "sol-low", "sol-low-bare", "sol-medium-bare",
    ],
    "T2": expected_floor["T2"] + [
        "opus-high", "opus-medium", "opus-low", "sol-high", "sol-high-bare x2",
    ],
    "T3": expected_floor["T3"] + [
        "opus-high", "opus-medium", "sol-high", "sol-high-bare", "sol-max-bare",
    ],
}
expected_tier_max_cells = {
    "T0": expected_floor_max["T0"] + [
        "opus-low", "sol-low", "sol-low-bare",
    ],
    "T1": expected_floor_max["T1"] + [
        "opus-low", "opus-medium", "sol-low", "sol-low-bare", "sol-medium-bare",
    ],
    "T2": expected_floor_max["T2"] + [
        "opus-high", "opus-medium", "opus-low", "sol-high", "sol-high-bare x2",
        "sol-xhigh", "sol-xhigh-bare",
    ],
    "T3": expected_floor_max["T3"] + [
        "opus-high", "opus-medium", "sol-high", "sol-max x2", "sol-max-bare",
        "sol-xhigh-bare",
    ],
}
expected_coverage_pct = {
    "T0": {"eco": 41.9, "max": 46.1},
    "T1": {"eco": 48.9, "max": 55.1},
    "T2": {"eco": 59.2, "max": 67.4},
    "T3": {"eco": 70.3, "max": 77.0},
}
oc_counts = Counter({"oc-kimik3": 2, "oc-grok45-low": 2, "oc-dsv4flash": 2})
oc_counts_max = Counter({"oc-kimik3": 3, "oc-grok45-low": 3, "oc-dsv4flash": 3})
agy_counts = {
    "T0": Counter({
        "agy-flash35-high-skill": 1, "agy-flash35-medium-skill": 3,
        "agy-flash36-high-skill": 1, "agy-flash36-medium-skill": 1,
    }),
    "T1": Counter({
        "agy-flash35-high-skill": 1, "agy-flash35-medium-skill": 2,
        "agy-flash36-high-skill": 2, "agy-flash36-medium-skill": 1,
        "agy-pro-high-skill": 1,
    }),
    "T3": Counter({
        "agy-flash35-high-skill": 1, "agy-flash35-medium-skill": 3,
        "agy-flash36-high-skill": 2, "agy-flash36-medium-skill": 1,
        "agy-pro-high-skill": 1,
    }),
}
agy_counts["T2"] = agy_counts["T1"]
agy_counts_max = {
    "T0": agy_counts["T0"],
    # Equal to T3's default panel today, spelled out anyway: mirroring the aliasing the module
    # used to carry would leave the two free to drift together unnoticed.
    "T1": Counter({
        "agy-flash35-high-skill": 1, "agy-flash35-medium-skill": 3,
        "agy-flash36-high-skill": 2, "agy-flash36-medium-skill": 1,
        "agy-pro-high-skill": 1,
    }),
    "T2": Counter({
        "agy-flash35-high-skill": 2, "agy-flash35-medium-skill": 3,
        "agy-flash36-high-skill": 2, "agy-flash36-medium-skill": 1,
        "agy-pro-high-skill": 1,
    }),
}
agy_counts_max["T3"] = agy_counts_max["T2"]
expected_tier_multisets = {
    "T0": oc_counts + agy_counts["T0"] + Counter({
        "opus-low": 1, "sol-low": 1, "sol-low-bare": 1,
    }),
    "T1": oc_counts + agy_counts["T1"] + Counter({
        "opus-medium": 1, "sol-low": 1, "sol-low-bare": 1,
        "sol-medium-bare": 1,
    }),
    "T2": oc_counts + agy_counts["T2"] + Counter({
        "opus-low": 1, "opus-medium": 1, "opus-high": 1, "sol-high": 1,
        "sol-high-bare": 2,
    }),
    "T3": oc_counts + agy_counts["T3"] + Counter({
        "opus-high": 1, "opus-medium": 1, "sol-high": 1, "sol-high-bare": 1,
        "sol-max-bare": 1,
    }),
}
expected_tier_max_multisets = {
    "T0": oc_counts_max + agy_counts_max["T0"] + Counter({
        "opus-low": 1, "sol-low": 1, "sol-low-bare": 1,
    }),
    "T1": oc_counts_max + agy_counts_max["T1"] + Counter({
        "opus-low": 1, "opus-medium": 1, "sol-low": 1, "sol-low-bare": 1,
        "sol-medium-bare": 1,
    }),
    "T2": oc_counts_max + agy_counts_max["T2"] + Counter({
        "opus-high": 1, "opus-medium": 1, "opus-low": 1, "sol-high": 1,
        "sol-high-bare": 2, "sol-xhigh": 1, "sol-xhigh-bare": 1,
    }),
    "T3": oc_counts_max + agy_counts_max["T3"] + Counter({
        "opus-high": 1, "opus-medium": 1, "sol-high": 1, "sol-max": 2,
        "sol-max-bare": 1, "sol-xhigh-bare": 1,
    }),
}
assert rb.REVIEW_TIER_FLOOR == expected_floor
assert rb.REVIEW_TIER_FLOOR_MAX == expected_floor_max
# T0 never runs Pro, at either variant (owner rule): a tier for twenty changed lines has nothing
# to spend the panel's dearest cell on.
assert not any(
    "agy-pro" in cell for cell in
    rb.REVIEW_TIER_FLOOR["T0"] + rb.REVIEW_TIER_FLOOR_MAX["T0"]
)
# The panel runs its cells at once, so a cell past the roster wraps onto an account another cell
# already holds and bills it twice. Staying inside the enumerated roster is all a composition can
# do about that — walled accounts are dropped before the wrap, so no width guarantees distinct
# accounts — and --max may spend one cell over it.
for tier_name in rb.REVIEW_TIER_AGY:
    assert len(rb.parse_raters(",".join(rb.REVIEW_TIER_AGY[tier_name]))) <= rb.ROSTER_MAX, tier_name
    assert len(rb.parse_raters(",".join(rb.REVIEW_TIER_AGY_MAX[tier_name]))) <= rb.ROSTER_MAX + 1, tier_name
# Escalating to --max may never run fewer attempts of a cell than the default panel does, or a
# defect the eco repeats catch is lost by asking for more scrutiny. Only within a tier: across
# tiers the panels answer different diffs, so containment there would buy nothing and cost real
# quota.
def agy_multiset(cells):
    return Counter(rater["spec"].split("#")[0] for rater in rb.parse_raters(",".join(cells)))
for tier_name in rb.REVIEW_TIER_AGY:
    assert not agy_multiset(rb.REVIEW_TIER_AGY[tier_name]) - agy_multiset(
        rb.REVIEW_TIER_AGY_MAX[tier_name]), tier_name
# The eco floor's OpenCode block IS the recommended leg, so --leg and a tier cannot drift apart.
assert list(rb.OPENCODE_REVIEW_LEG) == expected_oc_floor
assert list(rb.OPENCODE_REVIEW_LEG_MAX) == expected_oc_floor_max
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
for composition, expected_cells, expected_multisets, composition_floor in (
    ("cells", expected_tier_cells, expected_tier_multisets, expected_floor),
    ("cells_max", expected_tier_max_cells, expected_tier_max_multisets, expected_floor_max),
):
    for tier_name, tier in rb.REVIEW_TIERS.items():
        tier_floor = composition_floor[tier_name]
        expanded_floor = Counter(
            rb.normalize_legacy_rater(rater["spec"])
            for rater in rb.parse_raters(",".join(tier_floor))
        )
        prefix = tier[composition][:len(tier_floor)]
        assert [
            rb.parse_raters(cell)[0]["spec"] for cell in prefix
        ] == [
            rb.parse_raters(cell)[0]["spec"] for cell in tier_floor
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
assert rb.collapse_rater_attempts(
    rater["spec"] for rater in rb.parse_raters(",".join(rb.OPENCODE_REVIEW_LEG))
) == list(rb.OPENCODE_REVIEW_LEG)
assert rb.collapse_rater_attempts(
    rater["spec"] for rater in rb.parse_raters(",".join(rb.OPENCODE_REVIEW_LEG_MAX))
) == list(rb.OPENCODE_REVIEW_LEG_MAX)
assert not set(rb.OPENCODE_SCREENED_MODELS) & set(rb.OPENCODE_MODEL_IDS.values()), (
    "a screened model with a cell belongs in the facts table, not the screening list"
)
assert all(
    rater["side"] == "opencode"
    for spec in (*rb.OPENCODE_REVIEW_LEG, *rb.OPENCODE_REVIEW_LEG_MAX)
    for rater in rb.parse_raters(spec)
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
# Nothing is refused outright since deepseek-v4-flash was revived, and a loop over an empty
# set passes without testing the refusal it exists to test. One member is injected so the
# path stays covered until a measurement puts a real model back in the set.
real_unusable = rb.OPENCODE_UNUSABLE_MODELS
rb.OPENCODE_UNUSABLE_MODELS = real_unusable or {"oc-mimo25"}
for unusable in sorted(rb.OPENCODE_UNUSABLE_MODELS):
    for spec in (unusable, f"{unusable}-low"):
        try:
            rb.parse_rater(spec)
        except ValueError as exc:
            assert "measured unusable" in str(exc), exc
        else:
            raise AssertionError(f"{spec} is measured unusable and must be refused")
rb.OPENCODE_UNUSABLE_MODELS = real_unusable
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

# --- lenses: a registered methodology in place of the rater's own ----------------------------
lens_registry = work / "lenses"
lens_registry.mkdir()
os.environ["REVIEW_BENCH_LENS_DIR"] = str(lens_registry)
lens_body = (
    "EDGE CASE METHODOLOGY BODY\n\n"
    "Report a crash as P1, a wrong result as P2 and a rough edge as P3.\n"
)
lens_source = work / "lens-origin-skill.md"
lens_source.write_text("ORIGIN SKILL TEXT\n")
lens_source_digest = hashlib.sha256(lens_source.read_bytes()).hexdigest()


def write_lens(filename, frontmatter, body=lens_body):
    path = lens_registry / filename
    path.write_text(f"---\n{frontmatter}\n---\n{body}")
    return path


def lens_refusal(call, *call_args):
    try:
        call(*call_args)
    except (RuntimeError, ValueError) as exc:
        return str(exc)
    raise AssertionError(f"the lens registry accepted {call_args!r}")


write_lens("edge-cases.md", "\n".join([
    "name: edge-cases",
    f"source: {lens_source}",
    f"source_hash: {lens_source_digest}",
    "aliases: [edgecases, edge]",
]))
write_lens("repeat-lens.md", "name: repeat-lens\nrepeats: 2")
edge_lens = rb.resolve_lens("edge-cases")
assert edge_lens["body"].startswith("EDGE CASE METHODOLOGY BODY"), edge_lens["body"]
assert edge_lens["repeats"] is None and edge_lens["aliases"] == ["edgecases", "edge"]
assert edge_lens["hash"] == hashlib.sha256(
    (lens_registry / "edge-cases.md").read_bytes()
).hexdigest()
# A former slug keeps resolving to the one record, so a rename does not split a lens's stats.
for alias in ("edgecases", "edge"):
    assert rb.resolve_lens(alias)["name"] == "edge-cases", alias
assert rb.resolve_lens("repeat-lens")["repeats"] == 2
assert sorted(rb.load_lenses()) == ["edge-cases", "repeat-lens"]
assert "unknown lens" in lens_refusal(rb.resolve_lens, "nosuch")
broken_lens = lens_registry / "broken.md"
for frontmatter, body, reason in (
    (f"source: {lens_source}", lens_body, "frontmatter `name`"),
    ("name: Edge Cases", lens_body, "frontmatter `name`"),
    ("name: ok-lens\nrepeats: many", lens_body, "repeats must be an integer"),
    ("name: ok-lens\nrepeats: 0", lens_body, "repeats must be at least 1"),
    ("name: ok-lens\nflavour: bold", lens_body, "unknown frontmatter key"),
    ("name: ok-lens\naliases: [Edge]", lens_body, "not a lowercase slug"),
    # A body that never says where its findings land leaves the severities to the rater, and
    # the run is then scored on a vocabulary the lens never claimed.
    ("name: ok-lens", "Report every defect you find.\n", "never maps P1, P2, P3"),
    ("name: ok-lens", "Crashes are P1, everything else P2.\n", "never maps P3"),
    ("name: ok-lens\naliases: keeper\n- extra", lens_body, "both a value and list items"),
    # A list where a path or a digest belongs reaches Path() and a hash comparison intact, and
    # fails there — far from the file that wrote it.
    (f"name: ok-lens\nsource: [{lens_source}, other.md]", lens_body,
     "source must be a single value"),
    ("name: ok-lens\nsource_hash: [abc]", lens_body, "source_hash must be a single value"),
    ("name: edge-cases", lens_body, "claimed by both"),
    ("name: ok-lens\naliases: [edge]", lens_body, "claimed by both"),
):
    broken_lens.write_text(f"---\n{frontmatter}\n---\n{body}")
    assert reason in lens_refusal(rb.load_lenses), (frontmatter, reason)
broken_lens.write_text("no frontmatter at all\n" + lens_body)
assert "no `---` frontmatter block" in lens_refusal(rb.load_lenses)
broken_lens.write_text("---\nname edge\n---\n" + lens_body)
assert "not `key: value`" in lens_refusal(rb.load_lenses)
# A lens whose own bytes are not text has no body to give a rater, and read_bytes is what says
# so — read_text() would raise past every refusal this registry makes.
broken_lens.write_bytes(b"---\nname: ok-lens\n---\nP1 P2 P3 \xff\n")
assert "not valid UTF-8" in lens_refusal(rb.load_lenses)
broken_lens.unlink()
# The documented block-list form: the key on its own line, its values under it.
write_lens("block-list.md", "name: block-list\naliases:\n  - blocklist\n  - bl")
assert rb.resolve_lens("bl")["name"] == "block-list"
assert rb.resolve_lens("block-list")["aliases"] == ["blocklist", "bl"]
(lens_registry / "block-list.md").unlink()
# A file repeating a slug of its own claims nothing against itself; only another file does.
write_lens("self-alias.md", "name: self-alias\naliases: [self-alias, sa, sa]")
assert rb.resolve_lens("sa")["name"] == "self-alias"
assert rb.resolve_lens("self-alias")["aliases"] == ["sa"]
(lens_registry / "self-alias.md").unlink()
# The digest is over the file's bytes, so it is the one shasum prints; hashing decoded text
# would translate CRLF away and disagree with every other reader of the same file.
crlf_lens = lens_registry / "crlf-lens.md"
crlf_lens.write_bytes(
    f"---\nname: crlf-lens\n---\n{lens_body}".replace("\n", "\r\n").encode()
)
assert rb.resolve_lens("crlf-lens")["hash"] == hashlib.sha256(
    crlf_lens.read_bytes()
).hexdigest()
assert rb.resolve_lens("crlf-lens")["body"].startswith("EDGE CASE METHODOLOGY BODY")
crlf_lens.unlink()
lens_prompt = rb.review_prompt("deadbee", "", lens=edge_lens)
assert "EDGE CASE METHODOLOGY BODY" in lens_prompt, lens_prompt
assert rb.CLEAN_REVIEW_MARKER in lens_prompt and "one JSON object per line" in lens_prompt
assert "only the commit diff below" in lens_prompt, lens_prompt
os.environ["REVIEW_BENCH_PROFILE_DIR"] = str(profile_dir)
# A lens replaces the vendor methodology rather than stacking on it: a prompt carrying both
# measures neither.
stacked = rb.review_prompt("deadbee", "line 7", "google", lens=edge_lens)
assert "GOOGLE METHODOLOGY BODY" not in stacked, stacked
assert "EDGE CASE METHODOLOGY BODY" in stacked and "line 7" in stacked, stacked
del os.environ["REVIEW_BENCH_PROFILE_DIR"]
skill_redacted = ["claudeb", "profile", "acct", "-p", "brief", "--output-format", "json"]
skill_cell = rb.parse_rater("opus-medium-skill")
assert rb.uses_skill_brief(skill_cell)
assert "<worker-brief>" in rb.redact_command(skill_cell, skill_redacted)
# The -skill path hands the cell the vendor's own /code-review, which is the one methodology a
# lens run must not let it reach.
skill_cell["lens"] = edge_lens
assert not rb.uses_skill_brief(skill_cell)
assert "<review-prompt-and-diff>" in rb.redact_command(skill_cell, skill_redacted)
lens_mixed = rb.parse_raters("opus-medium,sol-low,oc-kimik3,agy-pro-high-skill")
lens_kept, lens_dropped = rb.lens_panel(lens_mixed, edge_lens)
assert [rater["spec"] for rater in lens_kept] == ["opus-medium", "sol-low"], lens_mixed
# A cell the panel drops is a cell the run has to name: silently, the tier still reads as run
# whole and nobody can tell the panel from the composition it was asked for.
assert [spec for spec, _ in lens_dropped] == ["oc-kimik3", "agy-pro-high-skill"], lens_dropped
assert all("out of a lens's reach" in reason for _, reason in lens_dropped), lens_dropped
assert "no cell to run" in lens_refusal(
    rb.lens_panel, rb.parse_raters("oc-kimik3,agy-pro-high-skill"), edge_lens
)
# --- lens empty after skill-only drops --------------------------------------------------------
assert "no cell to run" in lens_refusal(
    rb.lens_panel, rb.parse_raters("sonnet-medium-skill"), edge_lens
)
repeat_kept, repeat_dropped = rb.lens_panel(
    rb.parse_raters("sol-low x4,opus-medium x2"), rb.resolve_lens("repeat-lens")
)
assert [rater["spec"] for rater in repeat_kept] == [
    "sol-low", "sol-low#2", "opus-medium", "opus-medium#2"]
assert [spec for spec, _ in repeat_dropped] == ["sol-low#3", "sol-low#4"], repeat_dropped
assert all("repeats=2" in reason for _, reason in repeat_dropped), repeat_dropped
# --- lens repeat drops retain requested specs ------------------------------------------------
skill_repeat_kept, skill_repeat_dropped = rb.lens_panel(
    rb.parse_raters("opus-medium-skill x3"), rb.resolve_lens("repeat-lens")
)
assert [rater["spec"] for rater in skill_repeat_kept] == ["opus-medium", "opus-medium#2"]
assert [spec for spec, _ in skill_repeat_dropped] == ["opus-medium-skill#3"]
assert len(rb.lens_panel(rb.parse_raters("sol-low x4"), edge_lens)[0]) == 4
# --- lens skill stripping is suffix-only -----------------------------------------------------
third_skill_attempt = rb.parse_raters("opus-medium-skill x3")[2]
assert rb.lens_plain_cell(third_skill_attempt)["spec"] == "opus-medium#3"
mid_name_skill = dict(third_skill_attempt, spec="opus-skill-medium#3")
assert rb.lens_plain_cell(mid_name_skill)["spec"] == "opus-skill-medium#3"
# Under a lens the -skill cell takes the plain prompt, so it is the plain cell: kept as its own
# spec it would be paid for twice and recorded as a skill run that never happened.
skill_kept, skill_dropped = rb.lens_panel(
    rb.parse_raters("opus-medium-skill,opus-medium,opus-high-skill"), edge_lens
)
assert [rater["spec"] for rater in skill_kept] == ["opus-medium", "opus-high"], skill_kept
assert not any(rater["skill"] for rater in skill_kept), skill_kept
assert [spec for spec, _ in skill_dropped] == ["opus-medium"], skill_dropped
assert "already on the panel" in skill_dropped[0][1], skill_dropped
# A cell measured usable only through the skill has nothing left to run once a lens takes the
# skill away, and saying so here is the only place that does not read as "ask for what you asked".
sonnet_kept, sonnet_dropped = rb.lens_panel(
    rb.parse_raters("sonnet-medium-skill,opus-medium"), edge_lens
)
assert [rater["spec"] for rater in sonnet_kept] == ["opus-medium"], sonnet_kept
assert "only through the skill" in sonnet_dropped[0][1], sonnet_dropped
assert rb.lens_source_status(edge_lens) == "current"
assert rb.lens_source_status(rb.resolve_lens("repeat-lens")) == "no source recorded"
lens_source.write_text("ORIGIN SKILL TEXT, EDITED\n")
assert rb.lens_source_status(rb.resolve_lens("edge-cases")).startswith("drifted from ")
lens_source.write_text("ORIGIN SKILL TEXT\n")
assert rb.lens_source_status(rb.resolve_lens("edge-cases")) == "current"

# --- lens retired-cell refusal offers reachable advice --------------------------------------
lens_retired = lens_refusal(
    rb.refuse_retired_cells, [rb.parse_rater("sonnet-medium")], edge_lens
)
assert "unreachable under lens edge-cases" in lens_retired, lens_retired
assert "choose a different cell" in lens_retired and "ask for" not in lens_retired, lens_retired
write_lens("gone-source.md", "name: gone-source\nsource: /nonexistent/skill.md")
assert rb.lens_source_status(rb.resolve_lens("gone-source")).startswith("source missing at ")
write_lens("no-hash.md", f"name: no-hash\nsource: {lens_source}")
assert rb.lens_source_status(rb.resolve_lens("no-hash")) == "source hash not recorded"
# A source is any file the lens was distilled from, so drift is a question about its bytes: a
# source that does not decode is a status this reports, never a crash of `lens check`.
binary_source = work / "lens-binary-source.bin"
binary_source.write_bytes(b"\xff\xfe not text at all\n")
binary_digest = hashlib.sha256(binary_source.read_bytes()).hexdigest()
write_lens("binary-source.md", "\n".join([
    "name: binary-source",
    f"source: {binary_source}",
    f"source_hash: {binary_digest}",
]))
assert rb.lens_source_status(rb.resolve_lens("binary-source")) == "current"
assert binary_digest in "\n".join(rb.lens_check_lines("binary-source"))
binary_source.unlink()
assert rb.lens_source_status(
    rb.resolve_lens("binary-source")
).startswith("source missing at ")
assert "(unreadable)" in "\n".join(rb.lens_check_lines("binary-source"))
(lens_registry / "binary-source.md").unlink()
lens_listing = rb.lens_list_lines()
assert any(
    line.startswith("edge-cases") and "repeats=tier" in line and line.endswith("current")
    for line in lens_listing
), lens_listing
assert any(
    line.startswith("repeat-lens") and "repeats=2" in line for line in lens_listing
), lens_listing
lens_checked = "\n".join(rb.lens_check_lines("edge"))
assert lens_checked.startswith("edge-cases ") and lens_source_digest in lens_checked
assert "aliases:  edgecases, edge" in lens_checked, lens_checked
assert "status:   current" in lens_checked, lens_checked
(lens_registry / "gone-source.md").unlink()
(lens_registry / "no-hash.md").unlink()

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

# Affordability is the pool's answer rather than a reading of its table: one machine query per
# vendor, and a side is affordable exactly when worker-pick names an account for it.
previous_pick = os.environ.get("REVIEW_BENCH_WORKER_PICK_BIN")
os.environ["REVIEW_BENCH_WORKER_PICK_BIN"] = str(fixtures / "fake-worker-pick.sh")
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "worker session"
os.environ["WORKER_PICK_FAKE_SESSION"] = "session"
pick = rb.affordability()
assert pick["codex"] is True
assert pick["agy"] is True
assert pick["opencode"] is True
assert pick["claude"] is True
assert pick["claude_account"] == "worker"
# docs/routing-contract.md leaves the bench no thresholds and no table of its own, so neither
# a cap nor the pool's prose may come back out of here for something else to key on.
assert "claude_cap" not in pick and "worker_pick" not in pick, pick

walled_pick = work / "walled-worker-pick.sh"
walled_pick.write_text("#!/bin/sh\necho 'worker-pick: no selectable account' >&2\nexit 3\n")
walled_pick.chmod(0o755)
os.environ["REVIEW_BENCH_WORKER_PICK_BIN"] = str(walled_pick)
walled_available = rb.affordability()
assert walled_available["claude"] is False, walled_available
assert walled_available["codex"] is False and walled_available["agy"] is False
assert walled_available["claude_account"] is None
# The sides the pool does not route are unaffected: a walled vendor is not a walled bench.
assert walled_available["opencode"] is True and walled_available["grok"] is True

# Each vendor is asked for itself: a vendor with nothing selectable must not read as available
# on another vendor's answer, which is how a fully walled Gemini used to pass for affordable.
split_pick = work / "split-worker-pick.sh"
split_pick.write_text(
    "#!/bin/sh\n"
    '[ "$1" = "--account" ] || exit 2\n'
    'if [ "$2" = codex ]; then echo cx; exit 0; fi\n'
    "echo 'worker-pick: no selectable account' >&2\n"
    "exit 3\n"
)
split_pick.chmod(0o755)
os.environ["REVIEW_BENCH_WORKER_PICK_BIN"] = str(split_pick)
mixed_available = rb.affordability()
assert mixed_available["codex"] is True, mixed_available
assert mixed_available["agy"] is False, mixed_available
assert mixed_available["claude"] is False, mixed_available

# The session account is the pool's reserve, offered only once nothing else is selectable. The
# pool toggle is the only gate, so it may staff a side that has nothing else — but a roster it
# joined at the tail would hand it ordinary cells beside accounts that are not the reserve.
os.environ["REVIEW_BENCH_WORKER_PICK_BIN"] = str(fixtures / "fake-worker-pick.sh")
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "s1 s2 session"
rb._SIDE_ROSTER.clear()
assert rb.side_roster("claude", frozenset()) == ["s1", "s2"], rb.side_roster("claude", frozenset())
rb._SIDE_ROSTER.clear()
assert rb.side_roster("claude", frozenset({"s1", "s2"})) == ["session"]
rb._SIDE_ROSTER.clear()
assert [rb.pool_account("claude", set(), slot) for slot in range(3)] == ["s1", "s2", "s1"]
os.environ["REVIEW_BENCH_EXCLUDE_CLAUDE"] = "s1,s2"
rb._SIDE_ROSTER.clear()
assert rb.pool_account("claude", set()) == "session"
del os.environ["REVIEW_BENCH_EXCLUDE_CLAUDE"]
rb._SIDE_ROSTER.clear()

# Only claudeb has a session account, so only claudeb can answer with the reserve: a fixture
# marking every vendor would test Gemini and Codex against behaviour the pool never produces.
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "session"
assert rb.worker_pick_answer("claude", ()) == ("session", True)
assert rb.worker_pick_answer("agy", ()) == ("session", False)
assert rb.worker_pick_answer("codex", ()) == ("session", False)
del os.environ["WORKER_PICK_FAKE_SESSION"]

# Fable bills a bucket of its own, so a fable cell has to be routed against that bucket. Asked
# about the weekly one it would be handed an account whose fable window is already spent.
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "wk1 wk2"
os.environ["WORKER_PICK_FAKE_FABLE_ACCOUNTS"] = "fb1"
fable_bucket = rb.wall_bucket(rb.parse_rater("fable-high"))
assert fable_bucket == "fable"
rb._SIDE_ROSTER.clear()
assert rb.pool_account("claude", set(), 0, fable_bucket) == "fb1"
# Keyed apart: one cache entry for both buckets would serve whichever cell asked first.
assert rb.pool_account("claude", set(), 0) == "wk1"
assert rb.side_roster("claude", frozenset(), True) == ["fb1"]
assert rb.side_roster("claude", frozenset()) == ["wk1", "wk2"]

# An exhausted fable bucket takes fable cells off the panel and leaves ordinary Claude work
# alone, which the contract keeps independent of it.
os.environ["WORKER_PICK_FAKE_FABLE_ACCOUNTS"] = ""
rb._SIDE_ROSTER.clear()
spent_fable = rb.affordability()
assert spent_fable["claude"] is True and spent_fable["claude_fable"] is False, spent_fable
assert rb.cell_available(spent_fable, rb.parse_rater("fable-high")) is False
assert rb.cell_available(spent_fable, rb.parse_rater("opus-high")) is True
del os.environ["WORKER_PICK_FAKE_FABLE_ACCOUNTS"]

rb._SIDE_ROSTER.clear()
del os.environ["WORKER_PICK_FAKE_ACCOUNTS"]
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

# --- lens auto shortfall names reach, not affordability --------------------------------------
try:
    rb.auto_pick(
        len(rb.AUTO_RATERS), reviews, {"codex": True, "claude": True, "agy": True},
        {side: f"{side} side is out of a lens's reach" for side in rb.LENS_EXCLUDED_SIDES},
    )
except RuntimeError as exc:
    assert "within the lens's reach" in str(exc), exc
    assert "OpenCode and Antigravity cells are excluded" in str(exc), exc
    assert "affordable" not in str(exc), exc
else:
    raise AssertionError("lens-constrained --auto shortfall was accepted")

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
assert command[:11] == [
    str(fixtures / "fake-geminib.sh"), "profile", "work",
    "--model", "gemini-3.6-flash-low",
    "--mode", "plan",
    "--new-project", "--dangerously-skip-permissions",
    "--print-timeout", "10m",
]
assert (work / "geminib-profile").read_text() == "work"
assert command[11] == "--log-file"
assert pathlib.Path(command[12]) == transport_run / "agy-agy-flash36-low-skill.log"
assert command[13:] == ["--print", "/code-review"]
usage = json.loads((transport_run / "usage-agy-flash36-low-skill.jsonl").read_text())
assert usage["model"] == "gemini-3.6-flash-low"
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
assert skill_command[:7] == [
    str(fixtures / "fake-geminib.sh"), "profile", "work",
    "--model", "gemini-3.6-flash-low",
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
assert rb.agy_model_id(rb.parse_rater("agy-pro-low-skill")) == "gemini-3.1-pro-low"
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

# The pool's ranking is a live verdict about walls that a long run keeps invalidating, so the
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
real_worker_pick_answer = rb.worker_pick_answer


def counting_worker_pick(side, excluded, fable=False):
    roster_picks.append(side)
    return real_worker_pick_answer(side, excluded, fable)


rb.worker_pick_answer = counting_worker_pick
try:
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as roster_pool:
        rosters = list(roster_pool.map(
            lambda _: rb.side_roster("agy", frozenset()), range(4)
        ))
finally:
    rb.worker_pick_answer = real_worker_pick_answer
assert all(roster == ["f1", "f2"] for roster in rosters), rosters
# Two answers and the one that ends the walk, once for the side rather than once per cell.
assert len(roster_picks) == 3, roster_picks

# The gate is per roster: enumeration spawns a worker-pick per account, and one slow pool must
# not hold every other side out of its own answer for as long as that takes.
rb._SIDE_ROSTER.clear()
rb._SIDE_ROSTER_GATES.clear()
slow_side_entered = threading.Event()
slow_side_release = threading.Event()


def blocking_worker_pick(side, excluded, fable=False):
    if side == "codex":
        slow_side_entered.set()
        slow_side_release.wait(10)
    return real_worker_pick_answer(side, excluded, fable)


rb.worker_pick_answer = blocking_worker_pick
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
    rb.worker_pick_answer = real_worker_pick_answer
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
# The verifier answers a verdict object, not findings, and it reaches the same transport: without
# its own shape an announce-only reply stops on the first strategy and the claim is kept unchecked,
# which reads exactly like a verified one.
verify_args = (work / "opencode-args").read_text().splitlines()
assert verify_args[verify_args.index("--answer-must-match") + 1] == rb.OPENCODE_VERDICT_SHAPE, \
    verify_args
assert rb.OPENCODE_VERDICT_SHAPE != rb.OPENCODE_ANSWER_SHAPE

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
# The gate that blocks a commit opens the cycle; every `review --worktree` below is a panel that
# flow asked for, so each fixture repository carries the file the gate would have left.
def cycle_path(repo, session=""):
    gitdir = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--absolute-git-dir"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return pathlib.Path(gitdir) / ("review-cycle" + (f"-{session}" if session else ""))


def arm_review_cycle(repo, stage="armed1", session="", entries=()):
    path = cycle_path(repo, session)
    # The gate's own four fields: stage, the run id in the receipt when the stage was written, the
    # tree that run read and the UTC second the cycle opened, then one `<blob> <path>` entry per
    # path the pending commit carries. Written here, never rewritten: the file is the gate's.
    fields = [stage.encode(), b"", b"", b"2026-08-07T00:00:00"]
    fields += [entry.encode() if isinstance(entry, str) else entry for entry in entries]
    path.write_bytes(b"\0".join(fields) + b"\0")
    return path


arm_review_cycle(snapshot_clean)
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
max_grant = grant_owner_panels("max")
max_clean_review = subprocess.run(
    [sys.argv[1], "review", "--worktree", "--repo", str(snapshot_clean),
     "--tier", "T2", "--max", "--foreground"],
    capture_output=True, text=True,
)
assert max_clean_review.returncode != 0
assert "review-bench review HEAD --tier T2 --max --foreground --repo" in max_clean_review.stderr, \
    max_clean_review.stderr
# The same command with no grant behind it never reaches any of that: --max and T3 are the
# owner's, and the refusal is the tool's own, not an instruction a caller may skip.
(rb.owner_grant_dir() / "max").unlink()
ungranted_max = subprocess.run(
    [sys.argv[1], "review", "--worktree", "--repo", str(snapshot_clean),
     "--tier", "T2", "--max", "--foreground"],
    capture_output=True, text=True, stdin=subprocess.DEVNULL,
)
assert ungranted_max.returncode != 0
assert "--max is the owner's to start" in ungranted_max.stderr, ungranted_max.stderr
ungranted_t3 = subprocess.run(
    [sys.argv[1], "review", "--worktree", "--repo", str(snapshot_clean),
     "--tier", "T3", "--foreground"],
    capture_output=True, text=True, stdin=subprocess.DEVNULL,
)
assert ungranted_t3.returncode != 0
assert "T3 is the owner's to start" in ungranted_t3.stderr, ungranted_t3.stderr
grant_owner_panels("t3", age=rb.OWNER_GRANT_TTL_S + 60)
stale_grant_t3 = subprocess.run(
    [sys.argv[1], "review", "--worktree", "--repo", str(snapshot_clean),
     "--tier", "T3", "--foreground"],
    capture_output=True, text=True, stdin=subprocess.DEVNULL,
)
assert stale_grant_t3.returncode != 0
assert "T3 is the owner's to start" in stale_grant_t3.stderr, stale_grant_t3.stderr
(rb.owner_grant_dir() / "t3").unlink()
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
    # A range is a third way to name the target, so it conflicts with the other two the same way,
    # and the refusal says which two were given rather than restating the rule alone.
    [sys.argv[1], "review", "--range", "HEAD~1..HEAD", "--worktree",
     "--repo", str(snapshot_clean), "--tier", "T0"],
    [sys.argv[1], "review", "HEAD", "--range", "HEAD~1..HEAD",
     "--repo", str(snapshot_clean), "--tier", "T0"],
):
    conflict = subprocess.run(command, capture_output=True, text=True)
    assert conflict.returncode != 0
    assert "exactly one of commitish, --range and --worktree" in conflict.stderr, conflict.stderr
    if "--range" in command:
        assert "--range" in conflict.stderr.split("got")[-1], conflict.stderr

# A panel is something a commit asks for. The gate that blocks the commit opens a cycle, and that
# file is the whole authorization: without one, `review --worktree` is the mid-work review a chat
# talked itself into.
cycle_repo = work / "cycle-repo"
cycle_repo.mkdir()
subprocess.run(["git", "-C", str(cycle_repo), "init", "-q"], check=True)
(cycle_repo / "clean.txt").write_text("clean\n")
subprocess.run(["git", "-C", str(cycle_repo), "add", "clean.txt"], check=True)
subprocess.run(
    ["git", "-C", str(cycle_repo), "-c", "user.name=Fixture",
     "-c", "user.email=fixture@example.com", "commit", "-qm", "clean"],
    check=True,
)


# The bypass is an environment variable the suite must not inherit by accident: a REVIEW_ASKED
# already set in the shell that ran these tests would open every door below.
CYCLE_ENV = {key: value for key, value in os.environ.items() if key != "REVIEW_ASKED"}


def review_worktree(*repos, extra=(), env=None):
    repo_args = []
    for repo in repos:
        repo_args += ["--repo", str(repo)]
    return subprocess.run(
        [sys.argv[1], "review", "--worktree", *repo_args, "--tier", "T0", *extra],
        capture_output=True, text=True, env=CYCLE_ENV if env is None else env,
    )


CYCLE_REFUSAL = "reviews are commit-triggered"
unarmed = review_worktree(cycle_repo)
assert unarmed.returncode == 2, unarmed
assert CYCLE_REFUSAL in unarmed.stderr, unarmed.stderr
assert "attempt the `git commit`" in unarmed.stderr, unarmed.stderr
# The refusal has to name the other way in, or a chat holding Egor's own ask has nothing to do
# with it but argue with the tool.
assert "REVIEW_ASKED=1" in unarmed.stderr, unarmed.stderr
# The ticket stage is a cycle whose review already happened and was triaged — the round is over,
# and the next panel belongs to the next commit that asks for one.
arm_review_cycle(cycle_repo, "ticket")
spent = review_worktree(cycle_repo)
assert spent.returncode == 2, spent
assert CYCLE_REFUSAL in spent.stderr, spent.stderr
# Both armed stages open it — armed2 is the second round a P1 tally earned, and refusing there
# would demand a commit that is already blocked on the very review being refused. An authorized
# launch then dies on its own next refusal, which here is the clean tree.
for stage in ("armed1", "armed2"):
    arm_review_cycle(cycle_repo, stage)
    armed = review_worktree(cycle_repo)
    assert armed.returncode != 0, (stage, armed)
    assert CYCLE_REFUSAL not in armed.stderr, (stage, armed.stderr)
    assert "working tree matches HEAD" in armed.stderr, (stage, armed.stderr)
# Read and left alone: the gate spends this file at the commit it opened it for, and a peek that
# consumed it would leave that commit blocked on a round nothing can authorize.
assert cycle_path(cycle_repo).read_bytes() == b"armed2\0\0\0" + b"2026-08-07T00:00:00\0"
# Egor asking for a review by name is the other door, and it is the prefix the flow gate already
# verifies against the transcript — taken at face value here, since a flag of this tool's own would
# be one the caller grants itself unchecked.
cycle_path(cycle_repo).unlink()
asked = review_worktree(cycle_repo, env={**CYCLE_ENV, "REVIEW_ASKED": "1"})
assert asked.returncode != 0, asked
assert CYCLE_REFUSAL not in asked.stderr, asked.stderr
assert "working tree matches HEAD" in asked.stderr, asked.stderr
# The token is that one value: a variable merely present is not the prefix the gate checks.
for value in ("", "0", "yes"):
    not_asked = review_worktree(cycle_repo, env={**CYCLE_ENV, "REVIEW_ASKED": value})
    assert not_asked.returncode == 2, (value, not_asked)
    assert CYCLE_REFUSAL in not_asked.stderr, (value, not_asked.stderr)
# Outside a chat nothing names a session, and the gate keys its file on the checkout alone there.
sessionless_env = {
    key: value for key, value in CYCLE_ENV.items() if key != "CLAUDE_CODE_SESSION_ID"
}
arm_review_cycle(cycle_repo, "armed1", session="")
sessionless = review_worktree(cycle_repo, env=sessionless_env)
assert sessionless.returncode != 0, sessionless
assert CYCLE_REFUSAL not in sessionless.stderr, sessionless.stderr
cycle_path(cycle_repo, "").unlink()
# The authorization belongs to the checkout, not to a chat: the session that runs the review the
# checkout owes is routinely not the one whose commit the gate blocked — an orchestrator's block,
# a worker's panel — so ANY session's armed file opens this door.
foreign_cycle_path = arm_review_cycle(cycle_repo, "armed1", session="chat-2")
foreign_cycle = review_worktree(
    cycle_repo, env={**CYCLE_ENV, "CLAUDE_CODE_SESSION_ID": "chat-1"},
)
assert foreign_cycle.returncode != 0, foreign_cycle
assert CYCLE_REFUSAL not in foreign_cycle.stderr, foreign_cycle.stderr
foreign_cycle_path.unlink()
# A file this build cannot parse is no authorization: the format is the gate's, and guessing at an
# unknown shape is how a wall turns into an open door.
unreadable_cycle = cycle_path(cycle_repo, "chat-3")
unreadable_cycle.write_bytes(b"")
unparsed = review_worktree(cycle_repo)
assert unparsed.returncode == 2, unparsed
assert CYCLE_REFUSAL in unparsed.stderr, unparsed.stderr
unreadable_cycle.unlink()
# No file at all, and the refusal is the same one.
nothing_armed = review_worktree(cycle_repo, env=sessionless_env)
assert nothing_armed.returncode == 2, nothing_armed
assert CYCLE_REFUSAL in nothing_armed.stderr, nothing_armed.stderr
# A merged panel is authorized by ANY repository it names: a cycle is opened by a blocked commit,
# one commit is blocked in one repository, and demanding a cycle in every named repository would
# leave the merged review unlaunchable by the flow that asks for it.
cycle_second = work / "cycle-repo-2"
cycle_second.mkdir()
subprocess.run(["git", "-C", str(cycle_second), "init", "-q"], check=True)
(cycle_second / "second.txt").write_text("second\n")
subprocess.run(["git", "-C", str(cycle_second), "add", "second.txt"], check=True)
subprocess.run(
    ["git", "-C", str(cycle_second), "-c", "user.name=Fixture",
     "-c", "user.email=fixture@example.com", "commit", "-qm", "second"],
    check=True,
)
merged_unarmed = review_worktree(cycle_repo, cycle_second)
assert merged_unarmed.returncode == 2, merged_unarmed
assert CYCLE_REFUSAL in merged_unarmed.stderr, merged_unarmed.stderr
arm_review_cycle(cycle_second)
merged_armed = review_worktree(cycle_repo, cycle_second)
assert merged_armed.returncode != 0, merged_armed
assert CYCLE_REFUSAL not in merged_armed.stderr, merged_armed.stderr
# The corpus side is untouched: `run` is the benchmark's own launcher and no commit ever asks for
# one, so a cycle it could not have is not a door it has to come through.
cycle_run = subprocess.run(
    [sys.argv[1], "run", "--worktree", "--repo", str(cycle_repo), "--raters", "oc-kimik3"],
    capture_output=True, text=True,
)
assert cycle_run.returncode != 0
assert CYCLE_REFUSAL not in cycle_run.stderr, cycle_run.stderr
assert "working tree matches HEAD" in cycle_run.stderr, cycle_run.stderr

# `reviewed --ticket` is the stamp hook's whole judgement: the gate's ticket names the content it
# let a commit carry, and that content reachable in HEAD over a clean tree is the cycle's end.
ticket_repo = work / "ticket-stamp"
ticket_repo.mkdir()
subprocess.run(["git", "-C", str(ticket_repo), "init", "-q"], check=True)
(ticket_repo / "a.txt").write_text("reviewed\n")
subprocess.run(["git", "-C", str(ticket_repo), "add", "a.txt"], check=True)
subprocess.run(
    ["git", "-C", str(ticket_repo), "-c", "user.name=Fixture",
     "-c", "user.email=fixture@example.com", "commit", "-qm", "landed"],
    check=True,
)
ticket_state = work / "ticket-stamp-state"
ticket_env = {**CYCLE_ENV, "WORKER_STATS_DIR": str(ticket_state)}


def stamp_ticket():
    return subprocess.run(
        [sys.argv[1], "reviewed", "--repo", str(ticket_repo), "--ticket"],
        capture_output=True, text=True, env=ticket_env,
    )


def ticket_receipt_run():
    proc = subprocess.run(
        [sys.argv[1], "receipt", "--repo", str(ticket_repo)],
        capture_output=True, text=True, env=ticket_env,
    )
    return json.loads(proc.stdout)["run_id"] if proc.returncode == 0 else None


ticket_blob = subprocess.run(
    ["git", "-C", str(ticket_repo), "rev-parse", "HEAD:a.txt"],
    check=True, capture_output=True, text=True,
).stdout.strip()
no_ticket = stamp_ticket()
assert no_ticket.returncode == 3, no_ticket
assert ticket_receipt_run() is None
# A ticket whose content is nowhere in HEAD is a commit that never landed — rejected message,
# abandoned attempt — and the round it was granted for is still owed.
unlanded_ticket = arm_review_cycle(
    ticket_repo, "ticket", session="chat-unlanded", entries=[f"{'0' * 40} a.txt"],
)
assert stamp_ticket().returncode == 3
assert unlanded_ticket.exists()
landed_ticket = arm_review_cycle(
    ticket_repo, "ticket", session="chat-landed", entries=[f"{ticket_blob} a.txt"],
)
# The stamp covers the whole tree, so anything left uncommitted would be marked reviewed with it —
# and the ticket is spent all the same, its job having ended with the commit that landed its
# content. Left standing, it would stamp some later clean-tree commit no gate ever priced.
(ticket_repo / "leftover.txt").write_text("dirty\n")
dirty_stamp = stamp_ticket()
assert dirty_stamp.returncode == 3, dirty_stamp
assert not landed_ticket.exists()
assert unlanded_ticket.exists()
assert ticket_receipt_run() is None
(ticket_repo / "leftover.txt").unlink()
landed_ticket = arm_review_cycle(
    ticket_repo, "ticket", session="chat-landed", entries=[f"{ticket_blob} a.txt"],
)
# An armed cycle is a review still owed; the stamp has no business spending one.
armed_kept = arm_review_cycle(ticket_repo, "armed1", session="chat-armed")
unreadable_ticket = cycle_path(ticket_repo, "chat-unreadable")
unreadable_ticket.write_bytes(b"")
stamped_ticket = stamp_ticket()
assert stamped_ticket.returncode == 0, stamped_ticket
assert ticket_receipt_run().startswith("stamped-")
assert not landed_ticket.exists()
assert unlanded_ticket.exists()
assert armed_kept.exists()
assert unreadable_ticket.exists()
# And the ticket is gone with it: a spent one left behind would stamp the NEXT commit, one no gate
# ever priced, as reviewed.
(ticket_repo / "b.txt").write_text("new work\n")
subprocess.run(["git", "-C", str(ticket_repo), "add", "b.txt"], check=True)
subprocess.run(
    ["git", "-C", str(ticket_repo), "-c", "user.name=Fixture",
     "-c", "user.email=fixture@example.com", "commit", "-qm", "unpriced"],
    check=True,
)
stamped_run = ticket_receipt_run()
assert stamp_ticket().returncode == 3
assert ticket_receipt_run() == stamped_run
# A deletion hashes to nothing, so the gate records `gone` and the path's ABSENCE from HEAD is
# what pays: while it is still there, the commit that removes it has not happened yet.
(ticket_repo / "doomed.txt").write_text("doomed\n")
subprocess.run(["git", "-C", str(ticket_repo), "add", "doomed.txt"], check=True)
subprocess.run(
    ["git", "-C", str(ticket_repo), "-c", "user.name=Fixture",
     "-c", "user.email=fixture@example.com", "commit", "-qm", "doomed"],
    check=True,
)
gone_ticket = arm_review_cycle(
    ticket_repo, "ticket", session="chat-gone", entries=["gone doomed.txt"],
)
assert stamp_ticket().returncode == 3
assert gone_ticket.exists()
subprocess.run(["git", "-C", str(ticket_repo), "rm", "-q", "doomed.txt"], check=True)
subprocess.run(
    ["git", "-C", str(ticket_repo), "-c", "user.name=Fixture",
     "-c", "user.email=fixture@example.com", "commit", "-qm", "the deletion"],
    check=True,
)
gone_stamp = stamp_ticket()
assert gone_stamp.returncode == 0, gone_stamp
# Never compared against the previous run id: stamp ids carry seconds, and two stamps inside one
# second read equal. The receipt tree moving to the deletion's HEAD is what proves a fresh stamp.
gone_receipt = subprocess.run(
    [sys.argv[1], "receipt", "--repo", str(ticket_repo)],
    capture_output=True, text=True, env=ticket_env,
)
assert gone_receipt.returncode == 0, gone_receipt
gone_head_tree = subprocess.run(
    ["git", "-C", str(ticket_repo), "rev-parse", "HEAD^{tree}"],
    capture_output=True, text=True, check=True,
).stdout.strip()
assert json.loads(gone_receipt.stdout)["tree"] == gone_head_tree
assert not gone_ticket.exists()
assert unlanded_ticket.exists()
unlanded_ticket.unlink()
armed_kept.unlink()
unreadable_ticket.unlink()

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

# The native review command writes its own prompt, so the developer instructions are the only
# channel a lens has into a non-bare Sol cell; without them the cell runs the stock review and
# is still recorded under the lens's slug.
codex_lens_run = work / "codex-lens-run"
codex_lens_run.mkdir()
codex_lens_cell = rb.parse_rater("sol-medium")
codex_lens_cell["lens"] = rb.resolve_lens("edge-cases")
rc, _, _, stderr, codex_lens_command = rb.run_codex(
    codex_lens_cell, pin_repo, pin_sha, "", codex_lens_run, "", "main"
)
assert rc == 0 and not stderr
codex_lens_instruction = next(
    arg for arg in codex_lens_command if arg.startswith("developer_instructions=")
)
assert "EDGE CASE METHODOLOGY BODY" in codex_lens_instruction, codex_lens_instruction
assert rb.CLEAN_REVIEW_MARKER in codex_lens_instruction, codex_lens_instruction
# This cell has the repository, so the diff-only clause the prompt paths carry would be a lie.
assert "only the commit diff below" not in codex_lens_instruction, codex_lens_instruction
codex_lens_bare_run = work / "codex-lens-bare-run"
codex_lens_bare_run.mkdir()
codex_lens_bare = rb.parse_rater("sol-low-bare")
codex_lens_bare["lens"] = rb.resolve_lens("edge-cases")
rc, _, _, stderr, _ = rb.run_codex(
    codex_lens_bare, pin_repo, pin_sha, "", codex_lens_bare_run, bare_diff, "main"
)
assert rc == 0 and not stderr
codex_lens_stdin = (work / "rater-stdin").read_text()
assert "EDGE CASE METHODOLOGY BODY" in codex_lens_stdin, codex_lens_stdin
assert "only the commit diff below" in codex_lens_stdin, codex_lens_stdin

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
# The transport negotiates reasoning off but cannot know what a review looks like, so the
# contract travels with the call: without it a cell that answered inside its reasoning field
# leaves a non-empty announce and the negotiation stops on a strategy that produced nothing.
shape = command[command.index("--answer-must-match") + 1]
assert shape == rb.OPENCODE_ANSWER_SHAPE, shape
import re as _re
assert _re.search(shape, '{"severity":"P2"}', _re.IGNORECASE), shape
assert _re.search(shape, rb.CLEAN_REVIEW_MARKER, _re.IGNORECASE), shape
assert not _re.search(shape, "Checking how cmd_review emits reports.", _re.IGNORECASE), shape
# A bare brace is not the contract: an announce that quotes the requested format carries one, and
# taking that for an answer stops the negotiation on the strategy that produced no review.
assert not _re.search(
    shape, "I will return findings as {severity, file, line, summary}.", _re.IGNORECASE
), shape
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

# ...and neither is one that answered badly after surviving its own 5xx retries: the status
# lines its client left on stderr are not an outage.
noisy_models = []


def noisy_answer_fixture(command, **kwargs):
    noisy_models.append(command[command.index("run") + 1])
    return subprocess.CompletedProcess(command, 0, json.dumps({"choices": [{"message": {
        "content": "I could not tell."
    }}]}), "HTTP 503 from provider (attempt 1/2), retrying in 15s")


subprocess.run = noisy_answer_fixture
try:
    rb.verify_one(
        0, {"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "claim"},
        repo, sha, "oc-kimik3", ["line one"],
    )
finally:
    subprocess.run = real_run
assert noisy_models == [rb.OPENCODE_MODEL_IDS["oc-kimik3"]], noisy_models
clear_walls()

# A dead provider belongs to the model, not to the account: on 2026-08-04 grok-4.5's provider
# was down for a whole run and every one of its 85 claims filed unverified because only a
# throttle advanced the chain.
assert rb.opencode_provider_unavailable('HTTP 500\n{"error":{"type":"Router.Unavailable"}}')
assert rb.opencode_provider_unavailable("HTTP 503 failover_exhausted")
assert rb.opencode_provider_unavailable("provider error inside stream: {\"code\":1}")
assert rb.opencode_provider_unavailable("stream response carried no SSE data chunks")
assert rb.opencode_provider_unavailable("curl exit 28 after 300s (HTTP 000)")
assert not rb.opencode_provider_unavailable("HTTP 429 too many requests")
assert not rb.opencode_provider_unavailable(
    'HTTP 429 {"error":{"type":"GoUsageLimitError","message":"Weekly usage limit reached"}}'
)
assert not rb.opencode_provider_unavailable("opencode returned malformed JSON envelope")

# Each chain candidate is asked in the wording it was measured on, so the prompt file is
# rebuilt per model rather than written once per finding.
assert rb.verify_prompt_style(rb.OPENCODE_VERIFIER) == "shapes"
assert rb.verify_prompt_style("oc-kimik3") == "dual"
assert rb.verify_prompt_style("oc-qwen37plus") == "stock"
evidence_half = verify_text.split("Decide from the shown code alone:")[0]
shapes_text = rb.verify_prompt(verify_finding, "deadbee", "bin/review-bench",
                               ["alpha", "beta", "gamma"], style="shapes")
dual_text = rb.verify_prompt(verify_finding, "deadbee", "bin/review-bench",
                             ["alpha", "beta", "gamma"], style="dual")
assert shapes_text.startswith(evidence_half) and dual_text.startswith(evidence_half)
assert "narration: it restates what the diff does" in shapes_text
assert "Undecidable on the shown lines means false." in shapes_text
assert shapes_text.endswith(answer_instruction), shapes_text
assert "Before deciding, write both cases from the shown code:" in dual_text
assert dual_text.endswith(
    'Answer with exactly one JSON object and nothing else:\n'
    '{"against": "<max 20 words>", "for": "<max 20 words>", '
    '"code_matches": true|false, "is_defect": true|false, "why": "<max 12 words>"}'
), dual_text
assert known_failures not in shapes_text and known_failures not in dual_text
# The dual answer puts two keys before the verdict; the transport's shape check and the parser
# both have to accept it, or the wording kimi-k3 scores best on files every claim unverified.
dual_answer = json.dumps({"against": "line 3 guards it", "for": "none",
                          "code_matches": False, "is_defect": False, "why": "guarded"})
assert re.search(rb.OPENCODE_VERDICT_SHAPE, dual_answer), dual_answer
assert rb.parse_verify_answer(dual_answer)["code_matches"] is False

style_prompts = []


def style_fixture(command, **kwargs):
    model = command[command.index("run") + 1]
    style_prompts.append(
        pathlib.Path(command[command.index("--prompt-file") + 1]).read_text()
    )
    if model == rb.OPENCODE_MODEL_IDS["oc-dsv4flash"]:
        return subprocess.CompletedProcess(command, 1, "", (
            'HTTP 500\n{"error":{"type":"Router.Unavailable"}}'
        ))
    return subprocess.CompletedProcess(command, 0, json.dumps({"choices": [{"message": {
        "content": dual_answer.replace('"code_matches": false', '"code_matches": true')
                              .replace('"is_defect": false', '"is_defect": true')
    }}]}), "")


subprocess.run = style_fixture
try:
    style_row = rb.verify_one(
        0, {"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "claim"},
        repo, sha, "oc-dsv4flash", ["line one"],
    )
finally:
    subprocess.run = real_run
assert len(style_prompts) == 2, style_prompts
assert "narration: it restates what the diff does" in style_prompts[0]
assert "Before deciding, write both cases from the shown code:" in style_prompts[1]
assert style_row["kept"] is True and style_row["verifier"] == "oc-kimik3", style_row
assert "verified by oc-kimik3" in style_row["why"], style_row
clear_walls()

# The whole chain speaks through one gateway, so an outage on it retires every link at once —
# twice on 2026-08-04. An agy finding gets that side's own transport second; an opencode finding
# has no second transport to be handed to and never sees it.
assert rb.verifier_chain("oc-dsv4flash", "agy") == [
    "oc-dsv4flash", rb.GEMINI_VERIFIER, "oc-kimik3", "oc-qwen37plus", "oc-mmm3"
], rb.verifier_chain("oc-dsv4flash", "agy")
assert rb.GEMINI_VERIFIER not in rb.verifier_chain("oc-dsv4flash")
# Measured on the stock wording, not the one deepseek-v4-flash scores best on.
assert rb.verify_prompt_style(rb.GEMINI_VERIFIER) == "stock"
# The link is named in the report beside cell names, and it carries no effort to parse as one.
# The verifier runs flash36 at medium, and a tier cell runs the same model at the same effort,
# so one report must not print them as two models: the verifier row is named through its own
# effort rather than off the bare family the constant spells.
assert rb.human_cell_name(rb.GEMINI_VERIFIER) == "gem-flash36-med", rb.GEMINI_VERIFIER
assert rb.human_cell_name(rb.GEMINI_VERIFIER) == rb.short_cell_name(
    rb.parse_rater("agy-flash36-medium-skill"))
# That effort-qualified spelling is itself a legal skill-less cell, so a run holding THAT cell
# earns it a name of its own — which the verifier, named against the pool, must not inherit.
_verifier_scheme = rb.report_name_scheme(["agy-flash36-medium-skill", "agy-flash36-medium"])
assert rb.human_cell_name("agy-flash36-medium", _verifier_scheme) == "gem-flash36-med-bare"
assert rb.human_cell_name(rb.GEMINI_VERIFIER, _verifier_scheme) == "gem-flash36-med"
# geminib enforces the print timeout itself; the outer deadline is its teardown grace, the same
# relationship the rater path keeps, and it stays inside the configured verifier's own budget.
assert rb.GEMINI_VERIFY_PRINT_TIMEOUT == "3m", rb.GEMINI_VERIFY_PRINT_TIMEOUT
assert rb.GEMINI_VERIFY_TIMEOUT_S == rb.GEMINI_VERIFY_PRINT_TIMEOUT_S + rb.AGY_TIMEOUT_GRACE_S
assert rb.GEMINI_VERIFY_TIMEOUT_S <= rb.VERIFY_TIMEOUT_S, rb.GEMINI_VERIFY_TIMEOUT_S
geminib_bin = str(fixtures / "fake-geminib.sh")
worker_pick_bin = str(fixtures / "fake-worker-pick.sh")
gemini_verdict = (
    "The excerpt shows the loop dropping the account.\n\n```json\n"
    + json.dumps({"code_matches": True, "is_defect": True, "why": "drops the account"})
    + "\n```\n"
)
router_down = 'HTTP 500\n{"error":{"type":"Router.Unavailable"}}'
os.environ["REVIEW_BENCH_WORKER_PICK_BIN"] = worker_pick_bin
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "gem1 gem2"
rb._SIDE_ROSTER.clear()
agy_claim ={"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "claim"}
outage_calls = []


def gemini_link_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    outage_calls.append(command)
    if command[0] == geminib_bin:
        return subprocess.CompletedProcess(command, 0, gemini_verdict, "")
    return subprocess.CompletedProcess(command, 1, "", router_down)


subprocess.run = gemini_link_fixture
try:
    outage_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
    outage_kept, outage_audit = rb.verify_findings(
        [agy_claim], repo, sha, "oc-dsv4flash", tree, "agy"
    )
finally:
    subprocess.run = real_run
assert outage_row["kept"] is True and outage_row["verifier"] == rb.GEMINI_VERIFIER, outage_row
assert f"verified by {rb.GEMINI_VERIFIER}" in outage_row["why"], outage_row
assert outage_row.get("walled") is None, outage_row
assert outage_kept == [agy_claim], outage_kept
assert outage_audit[0]["verifier"] == rb.GEMINI_VERIFIER, outage_audit
gemini_calls = [command for command in outage_calls if command[0] == geminib_bin]
# The first link is still asked first: the fallback is a fallback, not a second default.
assert len(outage_calls) == 4 and len(gemini_calls) == 2, outage_calls
# Effort rides in the slug and agy takes no --effort flag (docs/shared-invariants.md row h);
# a slug agy cannot resolve is served as another model without an error, which is why the
# link asks for a log and reads the served label out of it.
assert gemini_calls[0][:11] == [
    geminib_bin, "profile", "gem1",
    "--model", "gemini-3.6-flash-medium",
    "--mode", "plan", "--new-project", "--dangerously-skip-permissions",
    "--print-timeout", "3m",
], gemini_calls[0]
assert "--effort" not in gemini_calls[0], gemini_calls[0]
assert gemini_calls[0][11] == "--log-file" and gemini_calls[0][13] == "--print"
gemini_prompt = gemini_calls[0][14]
assert "Known failure modes of the reviewer" in gemini_prompt
assert "narration: it restates what the diff does" not in gemini_prompt
clear_walls()

# The verdict of a model agy substituted is not the model the drop rate was measured on, so the
# link fails closed on it exactly as a rater cell does and the claim carries on down the chain.
mismatch_calls = []


def gemini_mismatch_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    mismatch_calls.append(command)
    if command[0] == geminib_bin:
        pathlib.Path(command[command.index("--log-file") + 1]).write_text(
            'Propagating selected model override to backend: label="Gemini 3.5 Flash (Low)"\n'
        )
        return subprocess.CompletedProcess(command, 0, gemini_verdict, "")
    if command[command.index("run") + 1] == rb.OPENCODE_MODEL_IDS["oc-dsv4flash"]:
        return subprocess.CompletedProcess(command, 1, "", router_down)
    return subprocess.CompletedProcess(command, 0, json.dumps({"choices": [{"message": {
        "content": json.dumps({"code_matches": True, "is_defect": False, "why": "guarded"})
    }}]}), "")


subprocess.run = gemini_mismatch_fixture
try:
    mismatch_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert mismatch_row["verifier"] == "oc-kimik3", mismatch_row
assert len([command for command in mismatch_calls if command[0] == geminib_bin]) == 1
assert not rb.is_walled("agy", "gem1", rb.GEMINI_VERIFIER), "a substitution retired an account"
clear_walls()

# The gateway's words retire an account, never the verifier's own: this link is asked to judge
# claims about 429 handling, and reading a wall off that prose would retire the account the agy
# raters share for the wall TTL.
prose_calls = []
gemini_prose = "The claim is about a 429 rate limit and the usage limit wording.\n"


def gemini_prose_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    prose_calls.append(command)
    if command[0] == geminib_bin:
        return subprocess.CompletedProcess(command, 0, gemini_prose, "")
    if command[command.index("run") + 1] == rb.OPENCODE_MODEL_IDS["oc-dsv4flash"]:
        return subprocess.CompletedProcess(command, 1, "", router_down)
    return subprocess.CompletedProcess(command, 0, json.dumps({"choices": [{"message": {
        "content": json.dumps({"code_matches": True, "is_defect": False, "why": "guarded"})
    }}]}), "")


subprocess.run = gemini_prose_fixture
try:
    prose_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert len([command for command in prose_calls if command[0] == geminib_bin]) == 1, prose_calls
assert not rb.is_walled("agy", "gem1", rb.GEMINI_VERIFIER), "the verifier's prose walled gem1"
assert prose_row["verifier"] == "oc-kimik3", prose_row
clear_walls()

# The second transport is there for the case the first one is spent, so an OpenCode wall hands
# the claim on instead of filing it unverified — and the answer it gets outranks that wall.
wall_handoff_calls = []
wall_on_record = []


def gemini_handoff_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    wall_handoff_calls.append(command)
    if command[0] == geminib_bin:
        wall_on_record.append(rb.is_walled("opencode", "opencode-go"))
        return subprocess.CompletedProcess(command, 0, gemini_verdict, "")
    return subprocess.CompletedProcess(command, 1, "", "HTTP 429 usage limit reached")


subprocess.run = gemini_handoff_fixture
try:
    handoff_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert handoff_row["kept"] is True and handoff_row["verifier"] == rb.GEMINI_VERIFIER, handoff_row
assert handoff_row.get("walled") is None, handoff_row
# The wall itself is still recorded, and the links behind it are not asked to prove it again.
assert [command for command in wall_handoff_calls if command[0] != geminib_bin] == [
    wall_handoff_calls[0]
], wall_handoff_calls
# On record before the gate slot is handed over, or a verifier taking that slot passes its
# post-gate check against an account this thread already knows is spent.
assert wall_on_record == [True], wall_on_record
clear_walls()

# A gateway that hangs is the outage the second transport exists for, so the timeout hands the
# claim on instead of ending the chain on the link that stalled.
stall_calls = []


def gemini_stall_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    stall_calls.append(command)
    if command[0] == geminib_bin:
        return subprocess.CompletedProcess(command, 0, gemini_verdict, "")
    raise subprocess.TimeoutExpired(command, kwargs["timeout"], stderr=b"")


subprocess.run = gemini_stall_fixture
try:
    stall_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert stall_row["kept"] is True and stall_row["verifier"] == rb.GEMINI_VERIFIER, stall_row
assert [command[0] for command in stall_calls][1:] == [geminib_bin], stall_calls
clear_walls()

# Only a run that finished speaks for the model: geminib prints what it had when its own
# deadline cut it off, and that text is not the verdict this drop rate was measured on.
cutoff_calls = []


def gemini_cutoff_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    cutoff_calls.append(command)
    if command[0] == geminib_bin:
        return subprocess.CompletedProcess(command, 1, gemini_verdict, "print timeout reached")
    if command[command.index("run") + 1] == rb.OPENCODE_MODEL_IDS["oc-dsv4flash"]:
        return subprocess.CompletedProcess(command, 1, "", router_down)
    return subprocess.CompletedProcess(command, 0, json.dumps({"choices": [{"message": {
        "content": json.dumps({"code_matches": True, "is_defect": False, "why": "guarded"})
    }}]}), "")


subprocess.run = gemini_cutoff_fixture
try:
    cutoff_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert cutoff_row["verifier"] == "oc-kimik3", cutoff_row
assert not rb.is_walled("agy", "gem1", rb.GEMINI_VERIFIER), "a cut-off run retired an account"
clear_walls()

# Both transports spent is a wall, not a verifier that answered badly: the row a reader counts
# as unchecked is the only honest one when nothing was left to ask.
spent_calls = []


def gemini_spent_fixture(command, **kwargs):
    if command and command[0] == worker_pick_bin:
        return real_run(command, **kwargs)
    spent_calls.append(command)
    return subprocess.CompletedProcess(
        command, 1, "", "Individual quota reached for this account"
    )


for opencode_profile in rb.opencode_profiles():
    rb.mark_walled("opencode", rb.opencode_account(opencode_profile))
subprocess.run = gemini_spent_fixture
try:
    spent_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert [command[2] for command in spent_calls] == ["gem1", "gem2"], spent_calls
assert spent_row["walled"] is True and spent_row["code_matches"] is None, spent_row
assert spent_row["why"] == "verifier hit the plan's usage wall; finding kept unverified", spent_row
clear_walls()

# A transport that never started asked nobody, so the claim reads as unchecked rather than as
# one a verifier answered badly.
missing_calls = []


def gemini_missing_fixture(command, **kwargs):
    if command and command[0] == worker_pick_bin:
        return real_run(command, **kwargs)
    missing_calls.append(command)
    raise OSError(2, "No such file or directory", command[0])


for opencode_profile in rb.opencode_profiles():
    rb.mark_walled("opencode", rb.opencode_account(opencode_profile))
subprocess.run = gemini_missing_fixture
try:
    missing_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert [command[0] for command in missing_calls] == [geminib_bin], missing_calls
assert missing_row["walled"] is True and missing_row["code_matches"] is None, missing_row
assert missing_row["why"] == (
    "verifier walled off while queued; finding kept unverified"
), missing_row
clear_walls()

# A claim nothing was ever asked about reads differently from one a verifier answered badly.
unusable_calls = []


def gemini_unusable_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    unusable_calls.append(command)
    return subprocess.CompletedProcess(command, 0, "no verdict here", "")


for opencode_profile in rb.opencode_profiles():
    rb.mark_walled("opencode", rb.opencode_account(opencode_profile))
subprocess.run = gemini_unusable_fixture
try:
    unusable_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert [command[0] for command in unusable_calls] == [geminib_bin], unusable_calls
assert unusable_row["code_matches"] is None and unusable_row.get("walled") is None, unusable_row
assert unusable_row["why"] == "verifier gave no usable answer; finding kept", unusable_row
clear_walls()

# A walled Gemini account is retired and the pool asked again, exactly as an agy rater rotates;
# with the side out of accounts the claim carries on down the rest of the chain.
walled_calls = []


def gemini_walled_fixture(command, **kwargs):
    if command and command[0] == worker_pick_bin:
        return real_run(command, **kwargs)
    walled_calls.append(command)
    if command[0] == geminib_bin:
        return subprocess.CompletedProcess(
            command, 1, "", "Individual quota reached for this account"
        )
    if command[command.index("run") + 1] == rb.OPENCODE_MODEL_IDS["oc-dsv4flash"]:
        return subprocess.CompletedProcess(command, 1, "", router_down)
    return subprocess.CompletedProcess(command, 0, json.dumps({"choices": [{"message": {
        "content": json.dumps({"code_matches": True, "is_defect": False, "why": "guarded"})
    }}]}), "")


subprocess.run = gemini_walled_fixture
try:
    walled_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert [command[2] for command in walled_calls if command[0] == geminib_bin] == [
    "gem1", "gem2"
], walled_calls
assert rb.is_walled("agy", "gem1", rb.GEMINI_VERIFIER)
assert rb.is_walled("agy", "gem2", rb.GEMINI_VERIFIER)
# A walled judge is never a crash, and the claim is still filtered by whoever answers next.
assert walled_row["kept"] is False and walled_row["verifier"] == "oc-kimik3", walled_row
assert walled_row.get("walled") is None, walled_row
clear_walls()

# An opencode finding keeps today's chain: the gemini link is not asked even when every
# opencode model in it is refused.
opencode_side_calls = []


def opencode_only_fixture(command, **kwargs):
    if command and command[0] == worker_pick_bin:
        return real_run(command, **kwargs)
    opencode_side_calls.append(command)
    return subprocess.CompletedProcess(command, 1, "", router_down)


subprocess.run = opencode_only_fixture
try:
    opencode_side_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"],
    )
finally:
    subprocess.run = real_run
assert not [command for command in opencode_side_calls if command[0] == geminib_bin]
assert len(opencode_side_calls) == 4, opencode_side_calls
assert opencode_side_row["kept"] is True and opencode_side_row["code_matches"] is None
del os.environ["WORKER_PICK_FAKE_ACCOUNTS"], os.environ["REVIEW_BENCH_WORKER_PICK_BIN"]
rb._SIDE_ROSTER.clear()
clear_walls()

# One claim restated at the same place is one question, asked once — and every original claim
# still gets its own audit row carrying the shared verdict.
dedup_calls = []
real_verify_one = rb.verify_one


def counting_verify_one(index, finding, *args, **kwargs):
    dedup_calls.append(index)
    row = rb.verify_row(index, finding)
    row.update(kept=False, code_matches=True, is_defect=False, why="not a defect",
               verifier="oc-dsv4flash")
    return row


dedup_input = [
    {"severity": "P2", "file": "a.py", "line": 3, "summary": "first claim"},
    {"severity": "P1", "file": "a.py", "line": 3, "summary": "First claim."},
    {"severity": "P1", "file": "a.py", "line": 3, "summary": "a different defect, same line"},
    {"severity": "P3", "file": "a.py", "line": 9, "summary": "elsewhere"},
    {"severity": "P3", "file": "", "line": None, "summary": "uncited"},
    {"severity": "P3", "file": "", "line": None, "summary": "also uncited"},
]
rb.verify_one = counting_verify_one
try:
    dedup_kept, dedup_audit = rb.verify_findings(dedup_input, repo, sha, "oc-dsv4flash", tree)
finally:
    rb.verify_one = real_verify_one
# Two different claims about one line are two questions: the verdict is rendered on one claim's
# text, so sharing it would settle the claim the verifier never saw. An uncited claim is nobody's
# neighbour either.
assert sorted(dedup_calls) == [0, 2, 3, 4, 5], dedup_calls
assert [row["idx"] for row in dedup_audit] == [0, 1, 2, 3, 4, 5], dedup_audit
assert [row["summary"] for row in dedup_audit] == [
    finding["summary"] for finding in dedup_input
], dedup_audit
assert [row["severity"] for row in dedup_audit] == [
    finding["severity"] for finding in dedup_input
], dedup_audit
assert all(
    row["kept"] is False and row["code_matches"] is True and row["is_defect"] is False
    and row["why"] == "not a defect" and row["verifier"] == "oc-dsv4flash"
    for row in dedup_audit
), dedup_audit
assert dedup_kept == []
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
# Patched sleep catches everyone's naps: subprocess.run(timeout=...) polls its child with
# sub-millisecond sleeps under load, and those are not the backoff being measured.
assert [s for s in throttle_slept if s >= 1] == [7], throttle_slept
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
verifier_real_unusable = rb.OPENCODE_UNUSABLE_MODELS
rb.OPENCODE_UNUSABLE_MODELS = verifier_real_unusable or {"oc-mimo25"}
for refused in sorted(rb.OPENCODE_UNUSABLE_MODELS):
    try:
        rb.verifier_model(refused)
    except ValueError as exc:
        assert "measured unusable" in str(exc), exc
    else:
        raise AssertionError(f"{refused} is measured unusable and cannot verify")
    assert refused not in rb.verifier_choices()
rb.OPENCODE_UNUSABLE_MODELS = verifier_real_unusable
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
# A review owes a triage, not a report: the marked block belongs to the verdicts, so a run that
# has none prints the line the hooks turn into the missing pass.
assert rb.REPORT_BEGIN not in review_stdout.getvalue()
assert rb.REPORT_END not in review_stdout.getvalue()
assert review_stdout.getvalue().count(rb.TRIAGE_PENDING) == 1
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
assert review_meta["verifier"] == rb.OPENCODE_VERIFIER == "oc-dsv4flash", \
    f"tier review verifier: {review_meta['verifier']!r}"
review_log_rows = [
    json.loads(line)
    for line in (review_store / "worker-stats" / "review-log.jsonl").read_text().splitlines()
]
assert len(review_log_rows) == 1, review_log_rows
review_log_event = review_log_rows[0]
assert review_log_event["event"] == "run" and review_log_event["tier"] == "T1"
assert review_log_event["run_id"] == review_meta["run_id"]
assert review_log_event["findings"] == 6
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
) == len(opencode_specs) == 6
assert all(rb.read_jsonl(filtered_run / f"findings-{rater}.jsonl") == []
           for rater in opencode_specs)
assert all(
    len(rb.read_jsonl(filtered_run / f"verified-{rater}.jsonl")) == 1
    and rb.read_jsonl(filtered_run / f"verified-{rater}.jsonl")[0]["kept"] is False
    for rater in opencode_specs
)
filtered_output = filtered_stdout.getvalue()
assert rb.REPORT_BEGIN not in filtered_output and rb.REPORT_END not in filtered_output
assert filtered_output.count(rb.TRIAGE_PENDING) == 1
assert all(
    row["verifier_by_model"] == {rb.OPENCODE_VERIFIER: 1} and row["verifier_audited"] == 1
    for row in filtered_meta["rater_runs"] if row["side"] == "opencode"
), filtered_meta["rater_runs"]
# Who judged, not just how many were dropped: the chain advances per finding, so a report
# naming no model leaves the reader unable to tell which verifier produced the rejections.
filtered_report = "\n".join(rb.report_lines(filtered_run, filtered_meta, []))
assert "verifier:     deepseek — 6 checked, 6 rejected" in filtered_report, \
    filtered_report
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
grant_owner_panels("max")
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
# A commit-point review is handed the reporting command and nothing else. The corpus form used to
# print beside it, and that is the one a chat copied: the round then went to the corpus and to the
# two-judge adjudication contract that belongs to a benchmark.
assert (
    f"Record exactly with: review-bench record {worktree_meta['run_id']} --no-corpus "
    f"--verdicts /tmp/review-bench-{worktree_meta['run_id']}-verdicts.jsonl"
) in worktree_stdout.getvalue(), worktree_stdout.getvalue()
assert f"record {worktree_meta['run_id']} --verdicts" not in worktree_stdout.getvalue(), \
    worktree_stdout.getvalue()
assert "Merge and deduplicate the findings blind." in worktree_stdout.getvalue()
# The durable side is untouched: a commit the corpus can be judged on keeps the corpus command.
plain_handoff = io.StringIO()
with contextlib.redirect_stdout(plain_handoff):
    rb.handoff("plain-run", ["/fixture/findings-sol-high.jsonl"])
assert (
    "Record exactly with: review-bench record plain-run "
    "--verdicts /tmp/review-bench-plain-run-verdicts.jsonl"
) in plain_handoff.getvalue(), plain_handoff.getvalue()
assert "--no-corpus" not in plain_handoff.getvalue(), plain_handoff.getvalue()
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
# A rerun by sha of a snapshot is the same commit-point review, so it is handed the same command.
assert (
    f"Record exactly with: review-bench record {snapshot_rerun_meta['run_id']} --no-corpus "
    f"--verdicts /tmp/review-bench-{snapshot_rerun_meta['run_id']}-verdicts.jsonl"
) in snapshot_rerun_stdout.getvalue(), snapshot_rerun_stdout.getvalue()
# The panel decides the verifier default, so a rerun of one cell that omits the flag filters
# findings the run it completes reported raw — while a rerun the verifier cannot reach is refused
# outright if the flag is passed, so the reproduce line carries it only where it applies.
assert "--verify" not in snapshot_rerun_stdout.getvalue().split("rerun:")[1].splitlines()[0]


def oc_rerun_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    return 1, 1, "", "fixture rater failure", []


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = oc_rerun_runner
for oc_rerun_name, oc_rerun_flag, oc_rerun_no_verify in (
    ("default", f"--verify {rb.OPENCODE_VERIFIER}", False),
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

# --- scoped worktree runs ---------------------------------------------------------------------
# A review of part of the working tree is not a review of the repository. Its snapshot must hold
# only the paths it was given, and its receipt must never be the one `suggest` and the statusline
# read — or the rest of the tree comes out already reviewed without a panel ever having read it.
scope_repo = work / "scoped-worktree"
scope_repo.mkdir()
subprocess.run(["git", "init", "-q", str(scope_repo)], check=True)
subprocess.run(["git", "-C", str(scope_repo), "config", "user.email", "bench@example.test"],
               check=True)
subprocess.run(["git", "-C", str(scope_repo), "config", "user.name", "Review Bench"], check=True)
for scope_name in ("alpha.txt", "beta.txt", "gamma.txt"):
    (scope_repo / scope_name).write_text("base\n")
(scope_repo / "sub").mkdir()
(scope_repo / "sub" / "inner.txt").write_text("base\n")
subprocess.run(["git", "-C", str(scope_repo), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(scope_repo), "commit", "-qm", "initial"], check=True)
scope_head = subprocess.run(
    ["git", "-C", str(scope_repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True,
).stdout.strip()
scope_head_tree = subprocess.run(
    ["git", "-C", str(scope_repo), "rev-parse", "HEAD^{tree}"],
    check=True, capture_output=True, text=True,
).stdout.strip()
for scope_name in ("alpha.txt", "beta.txt"):
    (scope_repo / scope_name).write_text("changed\n")

# One spelling of a path, whatever the caller typed: two callers naming the same files must land
# on the same snapshot and the same receipt.
assert rb.normalize_scope_paths(
    scope_repo, ["./beta.txt", "alpha.txt", "beta.txt/", "alpha.txt"]
) == ["alpha.txt", "beta.txt"]
assert rb.normalize_scope_paths(scope_repo, [str(scope_repo / "alpha.txt")]) == ["alpha.txt"]
# `..` collapses lexically, so one file spelled two ways is one scope: a receipt slug that moved
# with the spelling would let the same change be reviewed twice and stamped as two.
assert rb.normalize_scope_paths(scope_repo, ["sub/../alpha.txt"]) == ["alpha.txt"]
assert rb.receipt_file_name(
    scope_repo, scope=rb.normalize_scope_paths(scope_repo, ["./sub/../alpha.txt"])
) == rb.receipt_file_name(scope_repo, scope=["alpha.txt"])
# Glob pathspecs are git's to expand; canonicalization must reach them literally.
assert rb.normalize_scope_paths(scope_repo, ["sub/*.txt"]) == ["sub/*.txt"]
scope_normalize_errors = []
for scope_bad in ([""], ["   "], ["with\nnewline"], [str(work / "outside.txt")],
                  ["../outside.txt"], ["a/../../outside.txt"], ["sub/.."]):
    try:
        rb.normalize_scope_paths(scope_repo, scope_bad)
        scope_normalize_errors.append("")
    except ValueError as exc:
        scope_normalize_errors.append(str(exc))
assert all(scope_normalize_errors), scope_normalize_errors
# Canonicalized before the boundary is checked, or a `..` walks out of the repository and reaches
# git as a pathspec nobody meant to review.
for scope_escape in (3, 4, 5):
    assert "outside the repository" in scope_normalize_errors[scope_escape], scope_normalize_errors
assert "names no path" in scope_normalize_errors[6], scope_normalize_errors

# A relative pathspec means what the caller's shell means by it: standing in sub/, `inner.txt` is
# the file beside them, not a root-level one that may not even exist.
scope_cwd = os.getcwd()
try:
    os.chdir(scope_repo / "sub")
    assert rb.normalize_scope_paths(scope_repo, ["inner.txt"]) == ["sub/inner.txt"]
    assert rb.normalize_scope_paths(scope_repo, ["../alpha.txt"]) == ["alpha.txt"]
    try:
        rb.normalize_scope_paths(scope_repo, ["../../outside.txt"])
        scope_cwd_escape = ""
    except ValueError as exc:
        scope_cwd_escape = str(exc)
    assert "outside the repository" in scope_cwd_escape, scope_cwd_escape
finally:
    os.chdir(scope_cwd)
# A caller standing outside the repository has no such meaning to offer, so the root is the base.
assert rb.normalize_scope_paths(scope_repo, ["sub/inner.txt"]) == ["sub/inner.txt"]

scope_only_sha = rb.worktree_snapshot_commit(scope_repo, paths=["alpha.txt"])
scope_only_names = subprocess.run(
    ["git", "-C", str(scope_repo), "show", "--name-only", "--format=", scope_only_sha],
    check=True, capture_output=True, text=True,
).stdout.split()
assert scope_only_names == ["alpha.txt"], scope_only_names
# Same tree, same paths, same sha: a rerun is pinned to this sha, and a snapshot that moved under
# it would review something the first panel never saw.
assert rb.worktree_snapshot_commit(scope_repo, paths=["alpha.txt"]) == scope_only_sha
scope_both_sha = rb.worktree_snapshot_commit(scope_repo, paths=["alpha.txt", "beta.txt"])
assert scope_both_sha != scope_only_sha
assert sorted(subprocess.run(
    ["git", "-C", str(scope_repo), "show", "--name-only", "--format=", scope_both_sha],
    check=True, capture_output=True, text=True,
).stdout.split()) == ["alpha.txt", "beta.txt"]
scope_full_sha = rb.worktree_snapshot_commit(scope_repo)
assert rb.snapshot_scope_paths(scope_repo, scope_only_sha) == ["alpha.txt"]
assert rb.snapshot_scope_paths(scope_repo, scope_both_sha) == ["alpha.txt", "beta.txt"]
assert rb.snapshot_scope_paths(scope_repo, scope_full_sha) == []
assert rb.snapshot_scope_paths(scope_repo, scope_head) == []
assert rb.is_worktree_snapshot(scope_repo, scope_only_sha)
assert rb.worktree_snapshot_commit(
    scope_repo, paths=rb.normalize_scope_paths(scope_repo, ["./sub/../alpha.txt"])
) == scope_only_sha
# Fail closed on an unreadable message: an empty scope and an unscoped snapshot look alike from
# here, and guessing the second widens a rerun to the whole tree and stamps the flat receipt.
try:
    rb.snapshot_scope_paths(scope_repo, "f" * 40)
    scope_unreadable = ""
except RuntimeError as exc:
    scope_unreadable = str(exc)
assert scope_unreadable, "an unreadable snapshot message was read as an unscoped one"

scope_refusals = {}
for scope_label, scope_paths in (("missing", ["nowhere.txt"]), ("unchanged", ["gamma.txt"])):
    try:
        rb.worktree_snapshot_commit(scope_repo, paths=scope_paths)
        scope_refusals[scope_label] = ""
    except ValueError as exc:
        scope_refusals[scope_label] = str(exc)
assert "--paths matched nothing" in scope_refusals["missing"], scope_refusals
# Its own refusal: a scope holding no change is not a clean working tree, and telling the caller
# to review the commit instead answers a question nobody asked.
assert "no changes under the given paths" in scope_refusals["unchanged"], scope_refusals
assert "working tree matches HEAD" not in scope_refusals["unchanged"], scope_refusals

scope_store = work / "scope-run-claudeb"
os.environ["CLAUDEB_DIR"] = str(scope_store)
scope_flat_name = rb.receipt_file_name(scope_repo)
scope_receipt_name = rb.receipt_file_name(scope_repo, scope=["alpha.txt"])
assert scope_receipt_name == "{}__scope-{}.json".format(
    scope_flat_name[:-len(".json")], hashlib.sha1(b"alpha.txt").hexdigest()[:8]
), scope_receipt_name
assert rb.receipt_file_name(scope_repo, scope=["alpha.txt", "beta.txt"]) == "{}__scope-{}.json".format(
    scope_flat_name[:-len(".json")], hashlib.sha1(b"alpha.txt\0beta.txt").hexdigest()[:8]
)
assert rb.receipt_file_name(scope_repo, scope=["alpha.txt", "beta.txt"]) != scope_receipt_name
scope_lens_name = rb.receipt_file_name(scope_repo, "edge-cases", ["beta.txt"])
assert scope_lens_name == "{}__lens-edge-cases__scope-{}.json".format(
    scope_flat_name[:-len(".json")], hashlib.sha1(b"beta.txt").hexdigest()[:8]
), scope_lens_name
assert rb.receipt_file_name(scope_repo, "edge-cases", ["beta.txt"]) == scope_lens_name
# One selector each: a scoped lens run answers for neither the lens's whole tree nor the scope
# read by the tool's own methodology, so it must collide with neither receipt.
assert scope_lens_name != rb.receipt_file_name(scope_repo, "edge-cases")
assert scope_lens_name != rb.receipt_file_name(scope_repo, scope=["beta.txt"])
assert rb.receipt_file_name(scope_repo, "edge-cases", ["alpha.txt"]) != scope_lens_name

scope_stdout = io.StringIO()
with contextlib.redirect_stdout(scope_stdout):
    scope_rc = rb.cmd_run(argparse.Namespace(
        repo=str(scope_repo), commitish=None, worktree=True, paths=["alpha.txt"],
        raters="sol-medium", leg=False, verify=None, auto=None, focus=None,
    ))
assert scope_rc == 0, scope_stdout.getvalue()
scope_receipt_dir = scope_store / "worker-stats" / rb.RECEIPT_DIR
assert sorted(path.name for path in scope_receipt_dir.iterdir()) == [scope_receipt_name], \
    sorted(path.name for path in scope_receipt_dir.iterdir())
scope_run_meta = json.loads(
    (next((scope_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert scope_run_meta["worktree"] is True and scope_run_meta["scope"] == ["alpha.txt"], \
    scope_run_meta
assert scope_run_meta["commit"] == scope_only_sha, scope_run_meta
scope_receipt_doc = json.loads((scope_receipt_dir / scope_receipt_name).read_text())
assert scope_receipt_doc["scope"] == ["alpha.txt"], scope_receipt_doc
assert scope_receipt_doc["commit"] == scope_only_sha, scope_receipt_doc
assert rb.review_receipt(scope_repo) is None, "a scoped run wrote the repository's own receipt"
assert rb.review_receipt(scope_repo, None, ["alpha.txt"])["scope"] == ["alpha.txt"]
# The rerun line names the snapshot and no flags, so the scope has to come back out of the commit.
scope_rerun_store = work / "scope-rerun-claudeb"
os.environ["CLAUDEB_DIR"] = str(scope_rerun_store)
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(scope_repo), commitish=scope_only_sha, raters="sol-medium",
        leg=False, verify=None, auto=None, focus=None,
    )) == 0
scope_rerun_receipts = sorted(
    path.name for path in (scope_rerun_store / "worker-stats" / rb.RECEIPT_DIR).iterdir()
)
assert scope_rerun_receipts == [scope_receipt_name], scope_rerun_receipts
scope_rerun_meta = json.loads(
    (next((scope_rerun_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert scope_rerun_meta["scope"] == ["alpha.txt"], scope_rerun_meta

# A repository already carrying a full review keeps it byte for byte: a scoped run advancing that
# receipt would declare beta.txt reviewed by a panel that was never shown it.
scope_guard_store = work / "scope-guard-claudeb"
os.environ["CLAUDEB_DIR"] = str(scope_guard_store)
rb.persist_review_receipt(scope_repo, scope_head_tree, scope_head, "prior-full-run", 0)
scope_flat_path = scope_guard_store / "worker-stats" / rb.RECEIPT_DIR / scope_flat_name
scope_flat_before = scope_flat_path.read_bytes()
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(scope_repo), commitish=None, worktree=True, paths=["alpha.txt"],
        raters="sol-medium", leg=False, verify=None, auto=None, focus=None,
    )) == 0
assert scope_flat_path.read_bytes() == scope_flat_before, "a scoped run rewrote the flat receipt"
assert sorted(path.name for path in scope_flat_path.parent.iterdir()) == sorted(
    [scope_flat_name, scope_receipt_name]
)
scope_suggest_stdout = io.StringIO()
with contextlib.redirect_stdout(scope_suggest_stdout):
    rb.cmd_suggest(argparse.Namespace(repo=str(scope_repo), range=None))
# Both files, not one: the baseline is the full review, and the scoped run left it where it was.
assert "changed files: 2" in scope_suggest_stdout.getvalue(), scope_suggest_stdout.getvalue()

def scope_commit_objects():
    listed = subprocess.run(
        ["git", "-C", str(scope_repo), "cat-file", "--batch-all-objects",
         "--batch-check=%(objectname) %(objecttype)"],
        check=True, capture_output=True, text=True,
    )
    return {line.split()[0] for line in listed.stdout.splitlines() if line.endswith(" commit")}


scope_objects_before = scope_commit_objects()
scope_reject = {}
for scope_label, scope_kwargs in (
    ("commitish", {"commitish": scope_head, "worktree": False, "paths": ["alpha.txt"]}),
):
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rb.cmd_run(argparse.Namespace(
                repo=str(scope_repo), raters="sol-medium",
                leg=False, verify=None, auto=None, focus=None, **scope_kwargs,
            ))
        scope_reject[scope_label] = ""
    except ValueError as exc:
        scope_reject[scope_label] = str(exc)
assert "cannot narrow a commit" in scope_reject["commitish"], scope_reject
# The refusal comes before the snapshot: a run that cannot start must leave no commit behind.
assert scope_commit_objects() == scope_objects_before, "a refused scoped run wrote a commit"
scope_beta_sha = rb.worktree_snapshot_commit(scope_repo, paths=["beta.txt"])
assert scope_beta_sha not in scope_objects_before, scope_beta_sha

# --- a lens narrowed by --paths ---------------------------------------------------------------
# The two selectors are independent questions about the same tree, and a run carrying both has to
# name a receipt that answers for the pair — never the lens's, the scope's, or the repository's.
scope_lens_store = work / "scope-lens-claudeb"
os.environ["CLAUDEB_DIR"] = str(scope_lens_store)
rb.persist_review_receipt(scope_repo, scope_head_tree, scope_head, "prior-full-run", 0)
rb.persist_review_receipt(scope_repo, scope_head_tree, scope_head, "prior-lens-run", 0,
                          lens="edge-cases")
rb.persist_review_receipt(scope_repo, scope_head_tree, scope_head, "prior-scope-run", 0,
                          scope=["beta.txt"])
scope_lens_dir = scope_lens_store / "worker-stats" / rb.RECEIPT_DIR
scope_lens_untouched = {
    path.name: path.read_bytes() for path in scope_lens_dir.iterdir()
}
scope_lens_stdout = io.StringIO()
with contextlib.redirect_stdout(scope_lens_stdout):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(scope_repo), commitish=None, worktree=True, lens="edge-cases",
        paths=["beta.txt"], raters="sol-medium", leg=False, verify=None, auto=None, focus=None,
    )) == 0, scope_lens_stdout.getvalue()
assert sorted(path.name for path in scope_lens_dir.iterdir()) == sorted(
    list(scope_lens_untouched) + [scope_lens_name]
), sorted(path.name for path in scope_lens_dir.iterdir())
for scope_lens_kept, scope_lens_bytes in scope_lens_untouched.items():
    assert (scope_lens_dir / scope_lens_kept).read_bytes() == scope_lens_bytes, scope_lens_kept
scope_lens_doc = json.loads((scope_lens_dir / scope_lens_name).read_text())
assert scope_lens_doc["lens"] == "edge-cases", scope_lens_doc
assert scope_lens_doc["scope"] == ["beta.txt"], scope_lens_doc
assert scope_lens_doc["commit"] == scope_beta_sha, scope_lens_doc
assert rb.review_receipt(scope_repo, "edge-cases", ["beta.txt"])["run_id"] \
    == scope_lens_doc["run_id"]
scope_lens_meta = json.loads(
    (next((scope_lens_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert scope_lens_meta["lens"] == "edge-cases" and scope_lens_meta["scope"] == ["beta.txt"], \
    scope_lens_meta

# The rerun line names the snapshot and carries only --lens, so the scope has to come back out of
# the commit or the rerun would write the lens's whole-tree receipt.
scope_lens_rerun_store = work / "scope-lens-rerun-claudeb"
os.environ["CLAUDEB_DIR"] = str(scope_lens_rerun_store)
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(scope_repo), commitish=scope_beta_sha, lens="edge-cases", raters="sol-medium",
        leg=False, verify=None, auto=None, focus=None,
    )) == 0
scope_lens_rerun_dir = scope_lens_rerun_store / "worker-stats" / rb.RECEIPT_DIR
assert sorted(path.name for path in scope_lens_rerun_dir.iterdir()) == [scope_lens_name], \
    sorted(path.name for path in scope_lens_rerun_dir.iterdir())
scope_lens_rerun_meta = json.loads(
    (next((scope_lens_rerun_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert scope_lens_rerun_meta["lens"] == "edge-cases", scope_lens_rerun_meta
assert scope_lens_rerun_meta["scope"] == ["beta.txt"], scope_lens_rerun_meta

# --- root commits: a repository whose only commit has no parent -------------------------------
# Every diff review-bench takes is against a parent, and a day-one repository has none. Read as an
# unmeasurable diff it reviewed an empty change; the base a root commit really has is the empty
# tree, because its whole content is what it introduced.
root_repo = work / "root-commit-repo"
root_repo.mkdir()
subprocess.run(["git", "init", "-q", str(root_repo)], check=True)
subprocess.run(["git", "-C", str(root_repo), "config", "user.email", "bench@example.test"],
               check=True)
subprocess.run(["git", "-C", str(root_repo), "config", "user.name", "Review Bench"], check=True)
(root_repo / "day-one.txt").write_text("".join(f"line {n}\n" for n in range(1, 401)))
(root_repo / "nested").mkdir()
(root_repo / "nested" / "deep.txt").write_text("only\n")
subprocess.run(["git", "-C", str(root_repo), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(root_repo), "commit", "-qm", "day one"], check=True)
root_sha = subprocess.run(
    ["git", "-C", str(root_repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True,
).stdout.strip()
assert subprocess.run(
    ["git", "-C", str(root_repo), "rev-parse", "--verify", "--quiet", "HEAD^"],
    capture_output=True,
).returncode != 0, "the fixture's only commit must have no parent"
root_empty_tree = rb.empty_tree_hash(root_repo)
assert root_empty_tree == hashlib.sha1(b"tree 0\0").hexdigest(), root_empty_tree
assert rb.diff_base(root_repo, root_sha) == root_empty_tree
# The sites that already handled a root commit, pinned so they keep doing it.
assert "day one" in rb.commit_diff(root_repo, root_sha)
root_clone = rb.seal_overlay_clone(root_repo, root_sha)
try:
    assert subprocess.run(
        ["git", "-C", root_clone, "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip() == root_sha
    # The vendor skill reads origin/HEAD..HEAD, so it needs a base commit that exists; built in
    # the sealed clone and never in the repository under review.
    rb.prepare_agy_skill_clone(root_clone)
    root_origin = subprocess.run(
        ["git", "-C", root_clone, "rev-parse", "refs/remotes/origin/HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    assert subprocess.run(
        ["git", "-C", root_clone, "cat-file", "-t", root_origin],
        check=True, capture_output=True, text=True,
    ).stdout.strip() == "commit"
    assert subprocess.run(
        ["git", "-C", root_clone, "rev-parse", f"{root_origin}^{{tree}}"],
        check=True, capture_output=True, text=True,
    ).stdout.strip() == rb.empty_tree_hash(root_clone)
    assert sorted(subprocess.run(
        ["git", "-C", root_clone, "diff", "refs/remotes/origin/HEAD", "HEAD", "--name-only"],
        check=True, capture_output=True, text=True,
    ).stdout.split()) == ["day-one.txt", "nested/deep.txt"]
finally:
    shutil.rmtree(root_clone, ignore_errors=True)
root_clone_again = rb.seal_overlay_clone(root_repo, root_sha)
try:
    rb.prepare_agy_skill_clone(root_clone_again)
    assert subprocess.run(
        ["git", "-C", root_clone_again, "rev-parse", "refs/remotes/origin/HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip() == root_origin, "the empty base commit is not deterministic"
finally:
    shutil.rmtree(root_clone_again, ignore_errors=True)

assert rb.reviewed_diff_lines(root_repo, root_sha) == 401
assert rb.reviewed_diff_paths(root_repo, root_sha) == {"day-one.txt", "nested/deep.txt"}

root_store = work / "root-commit-claudeb"
os.environ["CLAUDEB_DIR"] = str(root_store)
root_stdout = io.StringIO()
with contextlib.redirect_stdout(root_stdout):
    root_rc = rb.cmd_run(argparse.Namespace(
        repo=str(root_repo), commitish=root_sha, raters="sol-medium",
        leg=False, verify=None, auto=None, focus=None,
    ))
assert root_rc == 0, root_stdout.getvalue()
root_receipt = rb.review_receipt(root_repo)
assert root_receipt and root_receipt["commit"] == root_sha, root_receipt
root_run_meta = json.loads(
    (next((root_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert root_run_meta["commit"] == root_sha and "worktree" not in root_run_meta, root_run_meta

# A correction inside a root commit's own just-reviewed content is sized like any other change:
# 200 lines in one file is the T2 the ladder prices it at, receipt or no receipt.
(root_repo / "day-one.txt").write_text(
    "".join(f"line {n} corrected\n" for n in range(1, 201))
    + "".join(f"line {n}\n" for n in range(201, 401))
)
root_suggest = io.StringIO()
with contextlib.redirect_stdout(root_suggest):
    rb.cmd_suggest(argparse.Namespace(repo=str(root_repo), range=None))
assert "changed files: 1" in root_suggest.getvalue(), root_suggest.getvalue()
assert "work over review" not in root_suggest.getvalue(), root_suggest.getvalue()
assert "tier: T2" in root_suggest.getvalue(), root_suggest.getvalue()
subprocess.run(["git", "-C", str(root_repo), "checkout", "--", "day-one.txt"], check=True)

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
# The chat that launched the run, for a statusline holding only the document, and absent rather
# than empty when the harness named none.
assert "session" not in progress, progress
os.environ["CLAUDE_CODE_SESSION_ID"] = "sess-abc-123"
try:
    stamped_progress = rb.review_progress_document(
        pin_repo, "20260727T120000Z-2ecc0bd", "T2", "2ecc0bd", ["oc-kimik3"], pid=12345,
    )
    os.environ["CLAUDE_CODE_SESSION_ID"] = ""
    blank_progress = rb.review_progress_document(
        pin_repo, "20260727T120000Z-2ecc0bd", "T2", "2ecc0bd", ["oc-kimik3"], pid=12345,
    )
finally:
    os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
assert stamped_progress["session"] == "sess-abc-123", stamped_progress
assert "session" not in blank_progress, blank_progress
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
# The commit gate prices its next round off this same command rather than reaching into the state
# directory it has no way to find: absent while the run is untriaged, which is the gate's "no
# review has answered yet", and the report block's own tally once the triage is recorded.
assert "reported" not in receipt_json, receipt_json
gate_price_dir = stamp_store / "benches" / stamp_receipt["run_id"]
gate_price_dir.mkdir(parents=True)
rb.write_jsonl(gate_price_dir / "findings-sol-low.jsonl", [
    {"file": "a.py", "line": 1, "severity": "P1", "summary": "one"},
    {"file": "a.py", "line": 2, "severity": "P1", "summary": "two"},
    {"file": "a.py", "line": 3, "severity": "P2", "summary": "three"},
    {"file": "a.py", "line": 4, "severity": "P1", "summary": "not confirmed"},
])
gate_price_rows = [
    {"rater": "sol-low", "idx": 0, "verdict": "confirmed"},
    {"rater": "sol-low", "idx": 1, "verdict": "confirmed"},
    {"rater": "sol-low", "idx": 2, "verdict": "confirmed"},
    {"rater": "sol-low", "idx": 3, "verdict": "false_positive"},
]
rb.write_report_receipt(gate_price_dir, gate_price_rows, {"P1": 2, "P2": 1})
gate_price_receipt = json.loads(subprocess.run(
    [sys.argv[1], "receipt", "--repo", str(stamp_repo)],
    check=True, capture_output=True, text=True, env=stamp_env,
).stdout)
assert gate_price_receipt["reported"] == {"P1": 2, "P2": 1, "P3": 0}
# The round this receipt belongs to, counted whole, rides beside the repository's own share: what
# earns a second review is a property of the ROUND, and a run that read one repository is a round
# whose two answers are the same one.
assert gate_price_receipt["reported_round"] == gate_price_receipt["reported"], gate_price_receipt
# And a findings file half-written by the run still holding it is a tally that cannot be computed,
# never an exception out of the command every receipt reader shells out to.
(gate_price_dir / "findings-sol-low.jsonl").write_bytes(b'{"file": "a.py\x00\xff not json\n')
corrupt_receipt_proc = subprocess.run(
    [sys.argv[1], "receipt", "--repo", str(stamp_repo)],
    capture_output=True, text=True, env=stamp_env,
)
assert corrupt_receipt_proc.returncode == 0, corrupt_receipt_proc.stderr
assert "reported" not in json.loads(corrupt_receipt_proc.stdout), corrupt_receipt_proc.stdout
shutil.rmtree(gate_price_dir)
assert subprocess.run(
    [sys.argv[1], "receipt", "--repo", str(pin_repo)],
    capture_output=True, text=True, env=dict(os.environ, WORKER_STATS_DIR=str(work / "empty-store")),
).returncode == 1

# --- `receipt --paths`: the scoped review a commit's own pathspec answers for -------------------
# A scoped run writes only its own receipt, so in a shared checkout — where a review is always
# narrowed to the paths being committed — the gate asking for the plain repository receipt reads a
# neighbour's whole-tree run and re-blocks a commit whose own review was triaged.
covering_repo = work / "receipt-covering"
(covering_repo / "bin").mkdir(parents=True)
(covering_repo / "tests").mkdir()
subprocess.run(["git", "-C", str(covering_repo), "init", "-q", "-b", "main"], check=True)
for covering_name in ("bin/tool", "tests/test_tool.sh", "docs.md"):
    (covering_repo / covering_name).write_text("base\n")
subprocess.run(["git", "-C", str(covering_repo), "add", "-A"], check=True)
subprocess.run(
    ["git", "-C", str(covering_repo), "-c", "user.name=Fixture",
     "-c", "user.email=fixture@example.com", "commit", "-qm", "initial"],
    check=True,
)
covering_head, covering_tree = (subprocess.run(
    ["git", "-C", str(covering_repo), "rev-parse", covering_rev],
    check=True, capture_output=True, text=True,
).stdout.strip() for covering_rev in ("HEAD", "HEAD^{tree}"))
covering_store = work / "receipt-covering-store"
covering_env = dict(os.environ, WORKER_STATS_DIR=str(covering_store))
covering_saved_stats = os.environ.get("WORKER_STATS_DIR")
os.environ["WORKER_STATS_DIR"] = str(covering_store)
for covering_run, covering_ts, covering_scope in (
    ("covering-older", "2026-08-06T22:00:00+00:00", ["bin/tool"]),
    ("covering-newer", "2026-08-06T23:00:00+00:00", ["bin/tool", "tests/test_tool.sh"]),
    ("covering-outside", "2026-08-07T00:00:00+00:00", ["bin/tool", "docs.md"]),
):
    rb.persist_review_receipt(covering_repo, covering_tree, covering_head, covering_run, 0,
                              timestamp=covering_ts, scope=covering_scope)
# A lens read the same paths by a methodology the tool did not write, so its receipt is not one of
# these however well its scope fits — and it is the newest of them all, which is the only way a
# search by recency could pick it up by accident.
rb.persist_review_receipt(covering_repo, covering_tree, covering_head, "covering-lens", 0,
                          timestamp="2026-08-07T01:00:00+00:00", lens="edge-cases",
                          scope=["bin/tool"])
if covering_saved_stats is None:
    os.environ.pop("WORKER_STATS_DIR")
else:
    os.environ["WORKER_STATS_DIR"] = covering_saved_stats


def covering_receipt(*covering_args):
    proc = subprocess.run(
        [sys.argv[1], "receipt", "--repo", str(covering_repo), *covering_args],
        capture_output=True, text=True, env=covering_env,
    )
    return proc.returncode, (json.loads(proc.stdout) if proc.stdout.strip() else None), proc.stderr


# Exactly the reviewed scope, and the newest review that read no more than it: the older run read
# a subset of the same paths and is still a review of this commit, just not the freshest one.
covering_rc, covering_json, _ = covering_receipt("--paths", "bin/tool", "tests/test_tool.sh")
assert covering_rc == 0 and covering_json["run_id"] == "covering-newer", (covering_rc,
                                                                          covering_json)
assert covering_json["scope"] == ["bin/tool", "tests/test_tool.sh"], covering_json
# A path in the commit the panel never saw does not disqualify the review — that is drift the gate
# prices — but a path the REVIEW read and the commit does not carry answers a different question.
assert covering_receipt(
    "--paths", "bin/tool", "tests/test_tool.sh", "never-reviewed.txt"
)[1]["run_id"] == "covering-newer"
assert covering_receipt("--paths", "bin/tool")[1]["run_id"] == "covering-older", \
    covering_receipt("--paths", "bin/tool")
assert covering_receipt("--paths", "docs.md")[0] == 1, covering_receipt("--paths", "docs.md")
assert covering_receipt("--paths", "tests/test_tool.sh")[0] == 1
# One spelling, the one the receipts are named after: the caller hands over a commit pathspec, not
# a canonical scope, and a receipt found only for `bin/tool` is a receipt the gate cannot use.
assert covering_receipt(
    "--paths", "./bin/tool", "tests/../tests/test_tool.sh", str(covering_repo / "bin" / "tool")
)[1]["run_id"] == "covering-newer"
assert covering_receipt("--paths", str(work / "outside.txt"))[0] == 2
# A commit pathspec names directories where a review scope names files: `git commit -- bin tests`
# covers every reviewed file under them, and the containment is by path segment, so a directory
# whose name merely starts the same never vouches for a neighbour.
assert covering_receipt("--paths", "bin", "tests")[1]["run_id"] == "covering-newer", \
    covering_receipt("--paths", "bin", "tests")
assert covering_receipt("--paths", "bin")[1]["run_id"] == "covering-older"
assert covering_receipt("--paths", "bin/to")[0] == 1, covering_receipt("--paths", "bin/to")
# `git commit -- .` carries everything, so it is covered by the newest scoped review of any set —
# the same root-is-everything spelling the suggest side reads.
assert covering_receipt("--paths", ".")[1]["run_id"] == "covering-outside", \
    covering_receipt("--paths", ".")
# The plain receipt is untouched by all of it: scoped runs never answered for the repository, and
# a search that leaked into that answer would stamp the whole tree as reviewed.
assert covering_receipt()[0] == 1, covering_receipt()
assert covering_receipt("--scope", "bin/tool")[1]["run_id"] == "covering-older"
assert covering_receipt("--scope", "bin/tool", "--paths", "bin/tool")[0] == 2
assert covering_receipt("--paths", "bin/tool", "--lens", "edge-cases")[0] == 2
# And the answer is the whole receipt the gate reads, tally included: absent until the run behind
# it is triaged, which is the gate's "no review has answered yet".
assert "reported" not in covering_receipt("--paths", "bin/tool", "tests/test_tool.sh")[1]
covering_price_dir = covering_store / "benches" / "covering-newer"
covering_price_dir.mkdir(parents=True)
rb.write_jsonl(covering_price_dir / "findings-sol-low.jsonl", [
    {"file": "bin/tool", "line": 1, "severity": "P1", "summary": "one"},
    {"file": "bin/tool", "line": 2, "severity": "P3", "summary": "two"},
    {"file": "bin/tool", "line": 3, "severity": "P1", "summary": "not confirmed"},
])
rb.write_report_receipt(covering_price_dir, [
    {"rater": "sol-low", "idx": 0, "verdict": "confirmed"},
    {"rater": "sol-low", "idx": 1, "verdict": "confirmed"},
    {"rater": "sol-low", "idx": 2, "verdict": "false_positive"},
], {"P1": 1, "P3": 1})
assert covering_receipt("--paths", "bin/tool", "tests/test_tool.sh")[1]["reported"] == \
    {"P1": 1, "P2": 0, "P3": 1}, covering_receipt("--paths", "bin/tool", "tests/test_tool.sh")

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
# whose composition happens to have no cell the verifier reaches.
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

# The agy leg's claims are filtered by the same verifier as an OpenCode cell's: measured on the
# leg's own adjudicated findings — 6 real and 24 false — the verifier dropped 11 of the 24.
agy_verify_spec = "agy-flash36-medium-skill"
agy_verify_ambient_stdout = os.environ["OPENCODE_FIXTURE_STDOUT"]


def agy_verify_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    return 0, 1, json.dumps({
        "severity": "P2", "file": "pinned.txt", "line": 1,
        "summary": f"{rater['spec']} fixture finding",
    }), "", []


rb.SIDE_RUNNERS["agy"] = agy_verify_runner


def run_agy_verify(store_name, fixture, **overrides):
    os.environ["CLAUDEB_DIR"] = str(work / store_name)
    os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / fixture)
    stdout = io.StringIO()
    with contextlib.redirect_stdout(stdout):
        rc = rb.cmd_run(argparse.Namespace(**dict(
            dict(repo=str(pin_repo), commitish=pin_sha, raters=agy_verify_spec,
                 leg=False, verify=None, no_verify=False, auto=None, focus=None),
            **overrides,
        )))
    run_dir = next((work / store_name / "worker-stats" / "benches").iterdir())
    return rc, run_dir, json.loads((run_dir / "meta.json").read_text()), stdout.getvalue()


agy_kept_rc, agy_kept_run, agy_kept_meta, agy_kept_out = run_agy_verify(
    "agy-verify-keep-claudeb", "opencode-verify-keep.json"
)
assert agy_kept_rc == 0, agy_kept_meta
assert agy_kept_meta["verifier"] == rb.OPENCODE_VERIFIER, agy_kept_meta["verifier"]
assert len(rb.read_jsonl(agy_kept_run / f"findings-{agy_verify_spec}.jsonl")) == 1
agy_kept_audit = rb.read_jsonl(agy_kept_run / f"verified-{agy_verify_spec}.jsonl")
assert len(agy_kept_audit) == 1 and agy_kept_audit[0]["kept"] is True, agy_kept_audit
assert f"{agy_verify_spec}: verifier kept 1 of 1 finding(s)" in agy_kept_out, agy_kept_out
agy_kept_entry = agy_kept_meta["rater_runs"][0]
assert agy_kept_entry["findings"] == 1 and agy_kept_entry["verifier_dropped"] == 0
assert agy_kept_entry["verifier_audited"] == 1 and agy_kept_entry["verifier_unverified"] == 0
assert agy_kept_entry["verifier_by_model"] == {rb.OPENCODE_VERIFIER: 1}, agy_kept_entry
assert type(agy_kept_entry.get("verify_ms")) is int, agy_kept_entry

agy_dropped_rc, agy_dropped_run, agy_dropped_meta, agy_dropped_out = run_agy_verify(
    "agy-verify-drop-claudeb", "opencode-verify-drop.json"
)
assert agy_dropped_rc == 0, agy_dropped_meta
assert rb.read_jsonl(agy_dropped_run / f"findings-{agy_verify_spec}.jsonl") == []
agy_dropped_audit = rb.read_jsonl(agy_dropped_run / f"verified-{agy_verify_spec}.jsonl")
assert len(agy_dropped_audit) == 1 and agy_dropped_audit[0]["kept"] is False, agy_dropped_audit
assert agy_dropped_meta["rater_runs"][0]["verifier_dropped"] == 1, agy_dropped_meta
assert f"{agy_verify_spec}: verifier kept 0 of 1 finding(s)" in agy_dropped_out, agy_dropped_out

# A walled verifier costs the run its filtering, never the agy findings the raters already paid
# for: the quota this leg spends is the one thing a rerun cannot get back.
os.environ["OPENCODE_FIXTURE_RC"] = "1"
os.environ["OPENCODE_FIXTURE_STDERR"] = "HTTP 429 usage limit reached"
agy_walled_rc, agy_walled_run, agy_walled_meta, agy_walled_out = run_agy_verify(
    "agy-verify-wall-claudeb", "opencode-happy.json"
)
del os.environ["OPENCODE_FIXTURE_RC"]
del os.environ["OPENCODE_FIXTURE_STDERR"]
clear_walls()
assert agy_walled_rc == 0, agy_walled_meta
assert len(rb.read_jsonl(agy_walled_run / f"findings-{agy_verify_spec}.jsonl")) == 1
agy_walled_audit = rb.read_jsonl(agy_walled_run / f"verified-{agy_verify_spec}.jsonl")
assert agy_walled_audit[0]["kept"] is True and agy_walled_audit[0]["walled"], agy_walled_audit
assert agy_walled_meta["rater_runs"][0]["verifier_unverified"] == 1, agy_walled_meta
assert "went unverified" in agy_walled_out, agy_walled_out

agy_raw_rc, agy_raw_run, agy_raw_meta, _ = run_agy_verify(
    "agy-verify-raw-claudeb", "opencode-verify-drop.json", no_verify=True
)
assert agy_raw_rc == 0, agy_raw_meta
assert agy_raw_meta["verifier"] == "", agy_raw_meta["verifier"]
assert len(rb.read_jsonl(agy_raw_run / f"findings-{agy_verify_spec}.jsonl")) == 1
assert not list(agy_raw_run.glob("verified-*.jsonl")), "a refused verifier checked agy findings"
rb.SIDE_RUNNERS["agy"] = tier_runner
os.environ["OPENCODE_FIXTURE_STDOUT"] = agy_verify_ambient_stdout

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
# The plain command is closed to every commit-point review: recording one stores a fix round's own
# triage as the run's adjudication, and that state belongs to the two sealed judges the corpus is
# built on. The refusal has to describe the flag it offers instead — no worktree run has ever
# reached the corpus, with --bench or without it, so a refusal promising one sends the reader
# looking for a row that will never appear.
try:
    rb.cmd_record(argparse.Namespace(
        run_id="worktree-record-fixture", verdicts=str(empty_verdicts),
    ))
except ValueError as exc:
    assert "a commit-point review never enters the corpus" in str(exc), exc
    assert "--no-corpus" in str(exc) and "--bench" in str(exc), exc
    assert "no corpus row is written either way" in str(exc), exc
    assert "verdicts.jsonl" in str(exc), exc
else:
    raise AssertionError("a worktree run was recorded into the corpus without --bench")
worktree_record_stdout = io.StringIO()
with contextlib.redirect_stdout(worktree_record_stdout):
    assert rb.cmd_record(argparse.Namespace(
        run_id="worktree-record-fixture", verdicts=str(empty_verdicts), bench=True,
    )) == 0
assert "corpus skipped" in worktree_record_stdout.getvalue()
assert worktree_record_stdout.getvalue().count(rb.REPORT_BEGIN) == 1
assert worktree_record_stdout.getvalue().count(rb.REPORT_END) == 1
assert not (worktree_record_dir / "defects.jsonl").exists()
assert (worktree_record_dir / "verdicts.jsonl").read_text() == ""
# The flag exists only because a worktree run has no other way to keep its verdicts. On a durable
# run it names a behaviour the plain command already has, and the help it was read in promises no
# corpus row — so accepting it there quietly writes the one thing the reader was told not to
# expect.
durable_bench_dir = repeat_store / "worker-stats" / "benches" / "durable-bench-fixture"
durable_bench_dir.mkdir()
(durable_bench_dir / "meta.json").write_text(json.dumps({
    "run_id": "durable-bench-fixture",
    "commit": snapshot_sha,
    "repo": str(pin_repo),
    "raters": [],
}) + "\n")
try:
    rb.cmd_record(argparse.Namespace(
        run_id="durable-bench-fixture", verdicts=str(empty_verdicts), bench=True,
    ))
except ValueError as exc:
    assert "--bench" in str(exc) and "worktree run" in str(exc), exc
    assert "durable run" in str(exc), exc
else:
    raise AssertionError("--bench was accepted on a durable run")
assert not (durable_bench_dir / "verdicts.jsonl").exists()
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
# The receipt carries the severity tally of exactly those verdicts — the same numbers the block
# above printed — because with no verdict file left behind it is the only record that this run was
# triaged at all, and the commit gate prices its next round on it.
no_corpus_receipt = json.loads((no_corpus_dir / rb.REPORT_RECEIPT).read_text())
assert no_corpus_receipt["confirmed_by_severity"] == {"P1": 1, "P2": 0, "P3": 0}, no_corpus_receipt
assert no_corpus_receipt["confirmed"] == 1, no_corpus_receipt
no_corpus_ref = {"run_id": "no-corpus-fixture", "commit": pin_sha}
assert rb.reported_severities(no_corpus_ref) == {"P1": 1, "P2": 0, "P3": 0}
# A run nobody triaged has priced nothing, and neither has one that does not exist.
assert rb.reported_severities({"run_id": "no-such-run", "commit": pin_sha}) is None
# Everything behind this is somebody else's file mid-write. A findings or verdict file that cannot
# be parsed is a tally that cannot be computed, and the readers of a receipt have a commit to let
# through: they must be told there is no tally, not handed an exception through `receipt`.
(no_corpus_dir / "verdicts.jsonl").write_bytes(b'{"rater": "sol-med\x00\xff not json\n')
assert rb.reported_severities(no_corpus_ref) is None
# The stored verdicts are the freshest adjudication there is, and the report receipt beside them
# is whatever an earlier round happened to print: a run re-adjudicated the durable way after a
# `--no-corpus` report would otherwise price the gate's escalation on superseded counts forever.
rb.write_jsonl(no_corpus_dir / "verdicts.jsonl", [
    {"rater": "sol-medium", "idx": 0, "verdict": "false_positive"},
    {"rater": "sol-medium", "idx": 1, "verdict": "confirmed"},
])
assert rb.reported_severities(no_corpus_ref) == {"P1": 0, "P2": 0, "P3": 1}
(no_corpus_dir / "verdicts.jsonl").unlink()
assert rb.reported_severities(no_corpus_ref) == {"P1": 1, "P2": 0, "P3": 0}
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
# A run adjudicated the durable way is as triaged as one reported with --no-corpus, and a receipt
# written by an older build carries no tally at all: both are read back off the stored verdicts.
assert rb.reported_severities(
    {"run_id": "recorded-no-corpus-fixture", "commit": pin_sha}
) == {"P1": 0, "P2": 1, "P3": 0}
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
    assert "no cell the verifier reaches" in str(exc), exc
else:
    raise AssertionError("--verify accepted a run with no cell the verifier reaches")
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
assert rerun_output.count(rb.TRIAGE_PENDING) == 1
assert rb.REPORT_BEGIN not in rerun_output and rb.REPORT_END not in rerun_output
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
# Every receipt says which change the panel read, a review of committed work included. Carried by
# worktree receipts alone, a review of the commit in front of the reader — «заревьюй то, что ты
# сделал» — left the commit gate unable to see what that panel had covered, so it demanded a second
# one over the very code the first had just read (seen live 2026-08-08).
committed_receipt = json.loads(subprocess.run(
    [sys.argv[1], "receipt", "--repo", str(pin_repo)],
    check=True, capture_output=True, text=True,
    env=dict(os.environ, CLAUDEB_DIR=str(model_store)),
).stdout)
assert committed_receipt["base"] == rb.diff_base(pin_repo, pin_descendant_sha), committed_receipt
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
    """Make the corpus say what a run found. A review vouches for a commit only once it found
    something, so a fixture asserting the vouch has to be explicit about it: an adjudicated confirmed
    count for a commit review, findings files for a worktree one, which the corpus refuses.
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


def suggest(path, *extra, cwd=None):
    proc = subprocess.run(
        [sys.argv[1], "suggest", "--repo", str(path), *extra],
        check=True, capture_output=True, text=True, env=suggest_env, cwd=cwd,
    )
    return proc.stdout.splitlines()


def assert_suggestion(lines, files, changed_lines, tier, committed=False, receipt=None,
                      worktree_receipt=None, runs=None):
    runs = runs or tier
    # `tier:` names the panel that runs, never the ladder's own answer: the statusline reads this
    # line, and a number nothing is going to launch is a number the reader acts on wrongly. The
    # ladder's answer survives as prose below, for a reader deciding whether to ask for more.
    assert lines[:3] == [
        f"changed files: {files}",
        f"changed lines: {changed_lines}",
        f"tier: {runs}",
    ], lines
    offset = 3
    if runs != tier:
        assert lines[offset] == (
            f"the ladder sizes this at {tier}, which is the owner's to start, so the panel is {runs}"
        ), lines
        offset += 1
    else:
        assert not any("is the owner's to start" in line for line in lines), lines
    # A receipt never moves the tier any more: the flow gate's per-commit ticket is what carries
    # post-review work, so suggest prices every delta by the size ladder alone.
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
    background = rb.REVIEW_TIERS[runs]["budget_min"] >= 10
    assert lines[offset] == (
        f"spawn: Bash run_in_background={'true' if background else 'false'}; "
        "preserve the complete final stdout"
    ), lines
    offset += 1
    prefix = "command: review-bench review " if committed else (
        "command: review-bench review --worktree "
    )
    assert lines[offset].startswith(prefix), lines
    assert f"--tier {runs}" in lines[offset], lines
    assert "--max" not in lines[offset], lines
    # The invariant the statusline depends on, asserted against the two lines themselves rather
    # than against what this helper was told: one tier is named, and it is the one that launches.
    named = [line.split(": ", 1)[1] for line in lines if line.startswith("tier: ")]
    assert named == re.findall(r"--tier (\S+)", lines[offset]), lines
    offset += 1
    # The one line that tells a reader --paths exists. This output is the whole of what the skill
    # says to obey, so a run in a tree holding someone else's work has no other way to learn it can
    # be narrowed; a commit is not the working tree and cannot be.
    scoped = [line for line in lines if line.startswith("scoped: ")]
    assert len(scoped) == (0 if committed else 1), lines
    if not committed:
        assert lines[offset] == scoped[0], lines
        assert "--paths <path> ..." in scoped[0], lines
        offset += 1
    # The one line that tells a reader lenses exist, printed for commits and worktrees alike:
    # exactly the registered slugs, so a lens absent from the registry is absent here too.
    registered = sorted(rb.load_lenses())
    if registered:
        assert lines[offset] == (
            "lenses: " + ", ".join(registered)
            + " — repeat the command with --lens <slug> to review by that methodology "
              "instead of the raters' own (all cells except OpenCode/agy"
            + ("" if committed else "; combinable with --paths") + ")"
        ), lines
        offset += 1
    # Everything heavier than the followed command is printed as the owner's to reach for, and
    # named as such on its own line.
    owner_only = [
        line.split(": ", 1)[1] for line in lines[offset:]
        if line.startswith("owner-only, run only if Egor asked for it by name: ")
    ]
    assert len(owner_only) == len(lines[offset:]), lines
    # The owner's tier is offered at every size, so his "run T3" needs no command assembled by hand.
    for owner_only_tier in rb.OWNER_TIERS:
        assert any(
            f"--tier {owner_only_tier}" in line and "--max" not in line for line in owner_only
        ) == (owner_only_tier != runs), lines
    wider = rb.REVIEW_TIERS[runs]["cells"] != rb.REVIEW_TIERS[runs]["cells_max"]
    assert any(f"--tier {runs} --max" in line for line in owner_only) == wider, lines
    if committed:
        return
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

# T3 is the owner's to start, so what the ladder answers and what an agent may run part ways
# here: the tier line stays truthful (the statusline reads it), the command drops to the ceiling.
t3_suggest = make_suggest_repo("suggest-t3")
(t3_suggest / "huge.txt").write_text("line\n" * 601)
assert_suggestion(suggest(t3_suggest), 1, 601, "T3", runs=rb.AUTO_TIER_CEILING)

# A named panel unblocks the gate and changes nothing here: what this prints is the same with a
# marker as without one, which is what keeps a passing mention of T3 from becoming what runs.
grant_owner_panels("t3", "max")
assert_suggestion(suggest(t3_suggest), 1, 601, "T3", runs=rb.AUTO_TIER_CEILING)
assert rb.owner_named("t3") and not rb.owner_named("nothing")
grant_owner_panels("t3", age=rb.OWNER_GRANT_TTL_S + 60)
assert not rb.owner_named("t3")
# A marker stamped ahead of this clock is fresh by any reading: refusing it would deny the panel
# Egor just named because two clocks disagree by a millisecond.
grant_owner_panels("t3", age=-30)
assert rb.owner_named("t3")
for marker in ("t3", "max"):
    (rb.owner_grant_dir() / marker).unlink()
# The keyboard exemption is Egor's shell, not any terminal: Claude Code marks every command it
# runs, so a pseudo-terminal an agent opens for itself is not him.
_ttys = types.SimpleNamespace(isatty=lambda: True)
_saved_streams, _saved_env = (sys.stdin, sys.stdout), os.environ.get("CLAUDECODE")
sys.stdin = sys.stdout = _ttys
try:
    os.environ.pop("CLAUDECODE", None)
    os.environ.pop("CLAUDE_CODE_ENTRYPOINT", None)
    assert rb.owner_at_keyboard()
    os.environ["CLAUDECODE"] = "1"
    assert not rb.owner_at_keyboard()
finally:
    sys.stdin, sys.stdout = _saved_streams
    if _saved_env is None:
        os.environ.pop("CLAUDECODE", None)
    else:
        os.environ["CLAUDECODE"] = _saved_env

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

# A bare repository has no working tree, and a `--range` suggestion never needed one: it reads two
# committed trees out of the object database. Keying repositories on `--show-toplevel` for the sake
# of telling linked worktrees apart refused these outright until the fallback was added back.
bare_source = make_suggest_repo("suggest-bare-source")
(bare_source / "wide.txt").write_text("line\n" * 151)
subprocess.run(["git", "-C", str(bare_source), "add", "wide.txt"], check=True, env=suggest_env)
subprocess.run(["git", "-C", str(bare_source), "commit", "-qm", "wide"],
               check=True, env=suggest_env)
bare_clone = bare_source.parent / "suggest-bare.git"
subprocess.run(["git", "clone", "-q", "--bare", str(bare_source), str(bare_clone)],
               check=True, env=suggest_env)
assert_suggestion(
    suggest(bare_clone, "--range", "HEAD~1..HEAD"), 1, 151, "T2", committed=True,
)
# A stamp declares a working tree reviewed, so it is the one caller that must still refuse one.
bare_stamp = subprocess.run(
    [sys.argv[1], "reviewed", "--repo", str(bare_clone)],
    capture_output=True, text=True, env=suggest_env,
)
assert bare_stamp.returncode != 0, bare_stamp.stdout
assert "working tree" in bare_stamp.stderr, bare_stamp.stderr

# `Path("").is_dir()` is True and `subprocess(cwd="")` raises, so an empty --repo used to reach git
# as a cwd and die there instead of being read as the directory the caller is standing in.
empty_repo_arg = subprocess.run(
    [sys.argv[1], "suggest", "--repo", ""],
    capture_output=True, text=True, cwd=str(bare_source), env=suggest_env,
)
assert empty_repo_arg.returncode == 0, empty_repo_arg.stderr
assert "FileNotFoundError" not in empty_repo_arg.stderr, empty_repo_arg.stderr

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
# The reviewed commit was rewound with its content left staged: what the receipt names is no longer
# HEAD, and the delta is measured against the tree the panel read rather than against HEAD.
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
)

# Work inside just-reviewed code, over a review that found something and while HEAD still stands
# where the panel stood: the shape that used to be priced by a tolerance of its own, and is now the
# size ladder's like anything else — one line inside a core measurement script is the T2 that
# script's own floor prices it at, not the T0 a receipt beside it used to buy.
fix_core_suggest = make_suggest_repo("suggest-fix-core", ("bin/review-bench",))
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
    suggest(fix_core_suggest), 1, 1, "T2", receipt="fix-core-fixture",
)

# And a large delta over the same shape of receipt is the T2 its 250 lines earn.
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
    suggest(fix_big_suggest), 1, 250, "T2", receipt="fix-big-fixture",
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
)

# A scoped review answers for a staged commit in a shared checkout. The commit contains the index
# and nothing else, so another agent's unstaged work is not what this one is asking to commit —
# without this, a fully reviewed, fully staged change stayed blocked forever by files nobody staged.
scoped_suggest = make_suggest_repo("suggest-scoped", ("mine.txt", "theirs.txt"))
(scoped_suggest / "mine.txt").write_text("reviewed\n" * 12)
scoped_sha = rb.worktree_snapshot_commit(scoped_suggest, paths=["mine.txt"])
scoped_tree = subprocess.run(
    ["git", "-C", str(scoped_suggest), "rev-parse", f"{scoped_sha}^{{tree}}"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
scoped_receipt_path = rb.persist_review_receipt(
    scoped_suggest, scoped_tree, scoped_sha, "scoped-fixture", 0, scope=["mine.txt"]
)
assert scoped_receipt_path.parent == receipt_dir, scoped_receipt_path
assert rb.review_receipt(scoped_suggest) is None, "a scoped receipt answered as the repository's"
subprocess.run(["git", "-C", str(scoped_suggest), "add", "mine.txt"], check=True, env=suggest_env)
scoped_lines = suggest(scoped_suggest)
assert "work over review scoped-fixture, which read every staged path (scoped to mine.txt)" \
    in scoped_lines, scoped_lines

# Someone else's unstaged edit and untracked file size the suggestion and still do not block: they
# are not going into this commit, and no review of them is owed by the agent making it.
(scoped_suggest / "theirs.txt").write_text("theirs\n" * 2)
(scoped_suggest / "theirs-new.txt").write_text("new\n" * 10)
scoped_foreign_lines = suggest(scoped_suggest)
assert scoped_foreign_lines[0] == "changed files: 3", scoped_foreign_lines
assert any(line.startswith("work over review scoped-fixture,") for line in scoped_foreign_lines), \
    scoped_foreign_lines

# A fix on top of the reviewed scope is still covered by that review — but only once the panel
# behind it is known to have found something.
(scoped_suggest / "mine.txt").write_text("reviewed\n" * 12 + "fix\n")
subprocess.run(["git", "-C", str(scoped_suggest), "add", "mine.txt"], check=True, env=suggest_env)
assert not any(line.startswith("work over review ") for line in suggest(scoped_suggest)), \
    suggest(scoped_suggest)
review_found("scoped-fixture", findings=2)
assert any(line.startswith("work over review scoped-fixture,") for line in suggest(scoped_suggest))

# Fail closed on a receipt that cannot be read: an unreadable scoped review is no review at all,
# and guessing its coverage is the one mistake that would wave a commit through unreviewed.
scoped_receipt_bytes = scoped_receipt_path.read_bytes()
scoped_receipt_path.write_bytes(b"{not json")
assert not any(line.startswith("work over review ") for line in suggest(scoped_suggest)), \
    suggest(scoped_suggest)
scoped_receipt_path.write_bytes(scoped_receipt_bytes)

# A staged path the scoped panel was never shown IS part of this commit, so it blocks — and a
# second scoped receipt covering exactly that path does not rescue it: two half-fresh reviews may
# not vouch together for a tree neither of them read.
subprocess.run(["git", "-C", str(scoped_suggest), "add", "theirs.txt"], check=True, env=suggest_env)
assert not any(line.startswith("work over review ") for line in suggest(scoped_suggest)), \
    suggest(scoped_suggest)
rb.persist_review_receipt(
    scoped_suggest, scoped_tree, scoped_sha, "scoped-theirs-fixture", 0, scope=["theirs.txt"]
)
assert not any(line.startswith("work over review ") for line in suggest(scoped_suggest)), \
    suggest(scoped_suggest)

# The scope is a pathspec, and matching one is not the same as having been read: a directory scope
# goes on matching files written after the panel ran, and those are precisely the unreviewed ones.
dir_scope_suggest = make_suggest_repo("suggest-scoped-dir", ("src/a.txt", "other.txt"))
(dir_scope_suggest / "src" / "a.txt").write_text("reviewed\n" * 12)
dir_scope_sha = rb.worktree_snapshot_commit(dir_scope_suggest, paths=["src"])
dir_scope_tree = subprocess.run(
    ["git", "-C", str(dir_scope_suggest), "rev-parse", f"{dir_scope_sha}^{{tree}}"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
rb.persist_review_receipt(
    dir_scope_suggest, dir_scope_tree, dir_scope_sha, "dir-scope-fixture", 0, scope=["src"]
)
review_found("dir-scope-fixture", findings=2)
subprocess.run(["git", "-C", str(dir_scope_suggest), "add", "src/a.txt"],
               check=True, env=suggest_env)
assert any(line.startswith("work over review dir-scope-fixture,")
           for line in suggest(dir_scope_suggest)), suggest(dir_scope_suggest)

# An unreadable receipt store must not take `suggest` down with it: the commit gate reads a failed
# suggest as no review check at all and lets the commit through.
receipt_dir.chmod(0o000)
try:
    unreadable_store_lines = suggest(dir_scope_suggest)
finally:
    receipt_dir.chmod(0o755)
assert unreadable_store_lines[0] == "changed files: 1", unreadable_store_lines

(dir_scope_suggest / "src" / "new.txt").write_text("new\n" * 3)
subprocess.run(["git", "-C", str(dir_scope_suggest), "add", "src/new.txt"],
               check=True, env=suggest_env)
assert not any(line.startswith("work over review ") for line in suggest(dir_scope_suggest)), \
    suggest(dir_scope_suggest)

# Staging the reviewed content back after HEAD has moved inside the scope is a revert of whoever
# moved it, and that diff reached no panel — an exact match with the reviewed tree is not a review.
moved_head_suggest = make_suggest_repo("suggest-scoped-moved", ("mine.txt", "other.txt"))
(moved_head_suggest / "mine.txt").write_text("reviewed\n" * 12)
moved_head_sha = rb.worktree_snapshot_commit(moved_head_suggest, paths=["mine.txt"])
moved_head_tree = subprocess.run(
    ["git", "-C", str(moved_head_suggest), "rev-parse", f"{moved_head_sha}^{{tree}}"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
rb.persist_review_receipt(
    moved_head_suggest, moved_head_tree, moved_head_sha, "moved-head-fixture", 0,
    scope=["mine.txt"]
)
(moved_head_suggest / "mine.txt").write_text("theirs\n" * 5)
subprocess.run(["git", "-C", str(moved_head_suggest), "add", "mine.txt"],
               check=True, env=suggest_env)
subprocess.run(["git", "-C", str(moved_head_suggest), "commit", "-qm", "their work"],
               check=True, env=suggest_env)
(moved_head_suggest / "mine.txt").write_text("reviewed\n" * 12)
subprocess.run(["git", "-C", str(moved_head_suggest), "add", "mine.txt"],
               check=True, env=suggest_env)
assert not any(line.startswith("work over review ") for line in suggest(moved_head_suggest)), \
    suggest(moved_head_suggest)

# `git commit -- <paths>` and `git commit -a` commit working-tree content, so the index outside
# those paths never reaches the commit: in a shared checkout another agent's staged file left the
# whole index unvouchable, and no receipt could ever cover it.
form_suggest = make_suggest_repo("suggest-commit-form", ("mine.txt", "theirs.txt"))
(form_suggest / "mine.txt").write_text("reviewed\n" * 12)
form_sha = rb.worktree_snapshot_commit(form_suggest, paths=["mine.txt"])
form_tree = subprocess.run(
    ["git", "-C", str(form_suggest), "rev-parse", f"{form_sha}^{{tree}}"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
rb.persist_review_receipt(
    form_suggest, form_tree, form_sha, "commit-form-fixture", 0, scope=["mine.txt"]
)
(form_suggest / "theirs.txt").write_text("theirs\n" * 3)
subprocess.run(["git", "-C", str(form_suggest), "add", "theirs.txt"], check=True, env=suggest_env)
assert not any(line.startswith("work over review ") for line in suggest(form_suggest)), \
    suggest(form_suggest)
form_paths_lines = suggest(form_suggest, "--commit-paths", "mine.txt")
assert ("work over review commit-form-fixture, which read every path this commit's pathspec "
        "carries (scoped to mine.txt)") in form_paths_lines, form_paths_lines

# A pathspec reaching past what the panel read is not covered by it, whatever else is in the index.
assert not any(line.startswith("work over review ")
               for line in suggest(form_suggest, "--commit-paths", "mine.txt", "theirs.txt")), \
    suggest(form_suggest, "--commit-paths", "mine.txt", "theirs.txt")

# `-a` carries the whole tracked delta, so the unreviewed working-tree edit it would sweep in
# blocks — and with that edit reverted the same receipt answers for the commit.
assert not any(line.startswith("work over review ")
               for line in suggest(form_suggest, "--commit-all")), \
    suggest(form_suggest, "--commit-all")
(form_suggest / "theirs.txt").write_text("base\n")
form_all_lines = suggest(form_suggest, "--commit-all")
assert ("work over review commit-form-fixture, which read every tracked change `git commit -a` "
        "carries (scoped to mine.txt)") in form_all_lines, form_all_lines

# A pathspec matching no change is a commit git itself refuses, and the tree's other work is not
# what it would carry: there is nothing to review, whatever the whole-tree sizing above says.
(form_suggest / "theirs.txt").write_text("theirs\n" * 9)
assert suggest(form_suggest, "--commit-paths", "unchanged.txt") == ["nothing to review"], \
    suggest(form_suggest, "--commit-paths", "unchanged.txt")
form_empty_all = make_suggest_repo("suggest-commit-form-clean")
assert suggest(form_empty_all, "--commit-all") == ["nothing to review"], \
    suggest(form_empty_all, "--commit-all")

# Untracked content is in neither commit form, so it can neither be vouched for nor block one.
(form_suggest / "untracked.txt").write_text("new\n" * 4)
assert ("work over review commit-form-fixture, which read every path this commit's pathspec "
        "carries (scoped to mine.txt)") in suggest(form_suggest, "--commit-paths", "mine.txt"), \
    suggest(form_suggest, "--commit-paths", "mine.txt")

# A commit pathspec is read where git reads it — beside the caller: taken as typed at the repository
# root, a name from a subdirectory matched the root's file or none at all.
nested_suggest = make_suggest_repo("suggest-commit-nested", ("sub/mine.txt", "mine.txt"))
(nested_suggest / "sub" / "mine.txt").write_text("nested\n" * 6)
nested_sha = rb.worktree_snapshot_commit(nested_suggest, paths=["sub/mine.txt"])
nested_tree = subprocess.run(
    ["git", "-C", str(nested_suggest), "rev-parse", f"{nested_sha}^{{tree}}"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
rb.persist_review_receipt(
    nested_suggest, nested_tree, nested_sha, "nested-form-fixture", 0, scope=["sub/mine.txt"]
)
(nested_suggest / "mine.txt").write_text("unreviewed\n" * 4)
nested_vouched = ("work over review nested-form-fixture, which read every path this commit's "
                 "pathspec carries (scoped to sub/mine.txt)")
for nested_spec in ("mine.txt", "."):
    nested_lines = suggest(nested_suggest, "--commit-paths", nested_spec,
                           cwd=nested_suggest / "sub")
    assert nested_vouched in nested_lines, (nested_spec, nested_lines)
# The same directory naming the root's unreviewed file means that file, not the one beside it.
assert not any(line.startswith("work over review ") for line in
               suggest(nested_suggest, "--commit-paths", "../mine.txt",
                       cwd=nested_suggest / "sub")), \
    suggest(nested_suggest, "--commit-paths", "../mine.txt", cwd=nested_suggest / "sub")

# `git commit -- .` at the top carries every tracked change rather than nothing, and an empty commit
# form is the gate's allow signal.
form_dot_lines = suggest(form_suggest, "--commit-paths", ".")
assert form_dot_lines != ["nothing to review"], form_dot_lines
assert not any(line.startswith("work over review ") for line in form_dot_lines), form_dot_lines

# A review that read the whole tree covers a commit as surely as a scope naming its paths, and was
# the one receipt a commit could not lean on: only scoped receipts were ever asked, so the stronger
# review vouched for less than the narrower one.
whole_suggest = make_suggest_repo("suggest-commit-whole-tree", ("mine.txt", "theirs.txt"))
(whole_suggest / "mine.txt").write_text("reviewed\n" * 7)
whole_sha = rb.worktree_snapshot_commit(whole_suggest)
whole_tree = subprocess.run(
    ["git", "-C", str(whole_suggest), "rev-parse", f"{whole_sha}^{{tree}}"],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip()
rb.persist_review_receipt(whole_suggest, whole_tree, whole_sha, "whole-tree-fixture", 0)
(whole_suggest / "theirs.txt").write_text("theirs\n" * 5)
assert rb.scoped_review_vouching(whole_suggest, ["mine.txt"], False)["run_id"] == \
    "whole-tree-fixture", rb.scoped_review_vouching(whole_suggest, ["mine.txt"], False)
# Asked through the pathspec it was handed, suggest answers that before the vouching rules get a
# word: what this commit would carry IS the reviewed tree, so the paths hold nothing for a panel to
# read, and the work outside them is somebody else's. Either line is the gate's allow signal.
whole_lines = suggest(whole_suggest, "--commit-paths", "mine.txt")
assert whole_lines == ["nothing to review; tree matches review whole-tree-fixture"], whole_lines
# Nothing staged is nothing to vouch for, and the working tree the pathspec form reads is not the
# question a plain commit asks.
assert not any(line.startswith("work over review ") for line in suggest(whole_suggest)), \
    suggest(whole_suggest)
subprocess.run(["git", "-C", str(whole_suggest), "add", "mine.txt"], check=True, env=suggest_env)
assert ("work over review whole-tree-fixture, which read every staged path"
        in suggest(whole_suggest)), suggest(whole_suggest)

# A range answers about two commits that already exist, so a commit form asked beside it was
# narrowing nothing and was dropped without a word.
for range_form in (["--commit-paths", "mine.txt"], ["--commit-all"]):
    range_refused = subprocess.run(
        [sys.argv[1], "suggest", "--repo", str(form_suggest), "--range", "HEAD~1..HEAD",
         *range_form],
        capture_output=True, text=True, env=suggest_env,
    )
    assert range_refused.returncode == 2, (range_form, range_refused)
    assert "not allowed with" in range_refused.stderr, (range_form, range_refused.stderr)

# The commit gate hands suggest the pathspec the commit will carry, and the reader acts on the one
# command printed: sized against the whole tree, a one-line fix beside another agent's large work
# priced a panel that reads none of it, and leaving the reader to name --paths itself cost three
# extra rounds. So the command carries the scope already, and the tier is that scope's own delta.
scoped_size_suggest = make_suggest_repo(
    "suggest-commit-scoped-size", ("mine.txt", "theirs a.txt")
)
(scoped_size_suggest / "mine.txt").write_text("base\nfix\n")
(scoped_size_suggest / "theirs a.txt").write_text("line\n" * 400)
(scoped_size_suggest / "untracked-theirs.txt").write_text("line\n" * 60)
assert_suggestion(suggest(scoped_size_suggest), 3, 462, "T2")


def suggest_command(lines):
    named = [line[len("command: "):] for line in lines if line.startswith("command: ")]
    assert len(named) == 1, lines
    return named[0]


scoped_size_lines = suggest(scoped_size_suggest, "--commit-paths", "mine.txt")
assert scoped_size_lines[:3] == [
    "changed files: 1", "changed lines: 1", "tier: T0",
], scoped_size_lines
scoped_size_command = suggest_command(scoped_size_lines)
assert "--worktree --tier T0 " in scoped_size_command, scoped_size_command
# Last on the line: --paths takes every argument after it.
assert scoped_size_command.endswith(" --paths mine.txt"), scoped_size_command
assert "sized to this commit's paths: mine.txt; the rest of the tree is somebody else's to review" \
    in scoped_size_lines, scoped_size_lines
# The sentence telling a reader to name --paths itself is what the filled-in command replaces.
assert not any(line.startswith("scoped: ") for line in scoped_size_lines), scoped_size_lines
# The pathspec reaches the command as a pathspec, not as a shell word: a path with a space in it
# would otherwise arrive as two.
spaced_lines = suggest(scoped_size_suggest, "--commit-paths", "mine.txt", "theirs a.txt")
assert suggest_command(spaced_lines).endswith(" --paths mine.txt 'theirs a.txt'"), spaced_lines
assert spaced_lines[:3] == ["changed files: 2", "changed lines: 402", "tier: T2"], spaced_lines
# Every heavier panel offered beside it reviews the same commit, so it carries the same scope.
for scoped_owner_line in scoped_size_lines:
    if scoped_owner_line.startswith("owner-only, "):
        assert scoped_owner_line.endswith(" --paths mine.txt"), scoped_owner_line
# `-a` and `git commit -- .` carry the whole tracked tree, so they are sized and printed as before.
for whole_form in (["--commit-all"], ["--commit-paths", "."]):
    whole_form_lines = suggest(scoped_size_suggest, *whole_form)
    assert whole_form_lines[:3] == [
        "changed files: 3", "changed lines: 462", "tier: T2",
    ], (whole_form, whole_form_lines)
    assert "--paths" not in suggest_command(whole_form_lines), (whole_form, whole_form_lines)
    assert any(line.startswith("scoped: ") for line in whole_form_lines), \
        (whole_form, whole_form_lines)
    assert not any(line.startswith("sized to this commit's paths: ") for line in whole_form_lines), \
        (whole_form, whole_form_lines)

scope_spelling_probe = r"""
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("review_bench_probe", sys.argv[1])
spec = importlib.util.spec_from_loader("review_bench_probe", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
print("\0".join(module.normalize_scope_paths(sys.argv[2], sys.argv[3:])))
"""


def scope_read_from(cwd, repo, paths):
    """What `review --paths` makes of a pathspec, read where the reader of the command stands: the
    other half of the invariant that a printed command survives being copied verbatim.
    """
    proc = subprocess.run(
        [sys.executable, "-c", scope_spelling_probe, sys.argv[1], str(repo), *paths],
        check=True, capture_output=True, text=True, cwd=str(cwd), env=suggest_env,
    )
    return proc.stdout.strip().split("\0")


def printed_scope_of(lines):
    named = re.search(r" --paths (.+)$", suggest_command(lines))
    assert named, lines
    return shlex.split(named.group(1))


# `review --paths` reads its pathspec beside the caller, so a command carrying repository-relative
# paths asked for sub/sub/mine.txt once copied out of sub/ and reviewed nothing.
nested_command_suggest = make_suggest_repo(
    "suggest-commit-nested-command", ("sub/mine.txt", "outside.txt")
)
(nested_command_suggest / "sub" / "mine.txt").write_text("base\nfix\n")
(nested_command_suggest / "outside.txt").write_text("line\n" * 300)
nested_sub = nested_command_suggest / "sub"
nested_command_lines = suggest(
    nested_command_suggest, "--commit-paths", "mine.txt", cwd=nested_sub
)
assert nested_command_lines[:3] == [
    "changed files: 1", "changed lines: 1", "tier: T0",
], nested_command_lines
assert printed_scope_of(nested_command_lines) == ["mine.txt"], nested_command_lines
assert scope_read_from(nested_sub, nested_command_suggest,
                       printed_scope_of(nested_command_lines)) == ["sub/mine.txt"], \
    nested_command_lines
# One spelling per output: a reader handed two would correct the command into the broken one.
assert any(line.startswith("sized to this commit's paths: mine.txt; ")
           for line in nested_command_lines), nested_command_lines
# A scope that is the caller's own directory has no relative spelling `--paths` accepts — `.` is
# refused — so it goes absolute, which normalize_scope_paths reads back to the same scope.
dir_scope_lines = suggest(nested_command_suggest, "--commit-paths", "../sub", cwd=nested_sub)
dir_scope_printed = printed_scope_of(dir_scope_lines)
assert dir_scope_printed and all(path.startswith("/") for path in dir_scope_printed), dir_scope_lines
assert scope_read_from(nested_sub, nested_command_suggest, dir_scope_printed) == ["sub"], \
    dir_scope_lines
assert any(line.startswith(f"sized to this commit's paths: {shlex.join(dir_scope_printed)}; ")
           for line in dir_scope_lines), dir_scope_lines
# Standing at the top, the two spellings are the same one, and a caller outside the repository has
# no directory to spell against.
top_scope_lines = suggest(nested_command_suggest, "--commit-paths", "sub",
                          cwd=nested_command_suggest)
assert printed_scope_of(top_scope_lines) == ["sub"], top_scope_lines
assert scope_read_from(nested_command_suggest, nested_command_suggest,
                       printed_scope_of(top_scope_lines)) == ["sub"], top_scope_lines
outside_scope_lines = suggest(nested_command_suggest, "--commit-paths", "sub", cwd=work)
assert printed_scope_of(outside_scope_lines) == ["sub"], outside_scope_lines

# Untracked content under the scope is in the diff the printed command would be shown, however
# little of it any commit form would carry.
scoped_untracked_suggest = make_suggest_repo("suggest-commit-scoped-untracked", ("src/mine.txt",))
(scoped_untracked_suggest / "src" / "mine.txt").write_text("base\nfix\n")
(scoped_untracked_suggest / "src" / "fresh.txt").write_text("line\n" * 40)
(scoped_untracked_suggest / "outside.txt").write_text("line\n" * 900)
scoped_untracked_lines = suggest(scoped_untracked_suggest, "--commit-paths", "src")
assert scoped_untracked_lines[:3] == [
    "changed files: 2", "changed lines: 41", "tier: T1",
], scoped_untracked_lines
assert suggest_command(scoped_untracked_lines).endswith(" --paths src"), scoped_untracked_lines

# The launching chat is stamped into the receipt for a reader holding only that file, and stays
# absent when the harness named none rather than landing there empty.
session_suggest = make_suggest_repo("suggest-session-receipt")
session_sha, session_tree = (subprocess.run(
    ["git", "-C", str(session_suggest), "rev-parse", ref],
    check=True, capture_output=True, text=True, env=suggest_env,
).stdout.strip() for ref in ("HEAD", "HEAD^{tree}"))
os.environ["CLAUDE_CODE_SESSION_ID"] = "sess-receipt-9"
try:
    session_receipt = json.loads(rb.persist_review_receipt(
        session_suggest, session_tree, session_sha, "session-receipt-fixture", 0
    ).read_text())
    os.environ["CLAUDE_CODE_SESSION_ID"] = ""
    blank_session_receipt = json.loads(rb.persist_review_receipt(
        session_suggest, session_tree, session_sha, "session-receipt-fixture", 0
    ).read_text())
finally:
    os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
unset_session_receipt = json.loads(rb.persist_review_receipt(
    session_suggest, session_tree, session_sha, "session-receipt-fixture", 0
).read_text())
assert session_receipt["session"] == "sess-receipt-9", session_receipt
assert "session" not in blank_session_receipt, blank_session_receipt
assert "session" not in unset_session_receipt, unset_session_receipt

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
# The panel must be sent to the range that was measured here, not to the commit at its right end:
# those are different changes, and the printed command was the only place that ever said which one
# the reader would get.
assert f"--range {range_base}..{range_head}" in range_lines[4], range_lines

# A range of commits is a review target of its own. Committed work was reviewable one commit at a
# time only, so «заревьюй то, что ты сделал» over a branch cost one panel per commit, and work
# already pushed could reach a panel only through a working tree it was no longer in (Egor,
# 2026-08-07).
sealed_repo = work / "range-seal"
sealed_repo.mkdir()
subprocess.run(["git", "init", "-q", "-b", "main", str(sealed_repo)], check=True)


def sealed_commit(name, text):
    (sealed_repo / name).write_text(text)
    subprocess.run(["git", "-C", str(sealed_repo), "add", name], check=True)
    subprocess.run(["git", "-C", str(sealed_repo), "-c", "user.email=t@example.test",
                    "-c", "user.name=t", "commit", "-q", "-m", name], check=True)
    return subprocess.run(["git", "-C", str(sealed_repo), "rev-parse", "HEAD"],
                          check=True, capture_output=True, text=True).stdout.strip()


sealed_base = sealed_commit("first.txt", "one\n")
sealed_second = sealed_commit("second.txt", "two\n")
sealed_head = sealed_commit("third.txt", "three\n")
sealed_sha = rb.range_snapshot_commit(sealed_repo, f"{sealed_base}..{sealed_head}")
# The left end is its parent, so every reader that derives what a sha is a change against reads the
# whole range without being taught anything about ranges.
assert rb.diff_base(sealed_repo, sealed_sha) == sealed_base
assert sorted(subprocess.run(
    ["git", "-C", str(sealed_repo), "show", "--name-only", "--format=", sealed_sha],
    check=True, capture_output=True, text=True,
).stdout.split()) == ["second.txt", "third.txt"]
# Pinned to its content: a rerun of an errored cell names the sha and nothing else.
assert rb.range_snapshot_commit(sealed_repo, f"{sealed_base}..{sealed_head}") == sealed_sha
# Sealed like a worktree snapshot, so nothing counts it as a real commit of the repository.
assert rb.is_worktree_snapshot(sealed_repo, sealed_sha)
# One range, however it is spelled: the seal names what it sealed, so naming the same two commits
# symbolically and by sha is one snapshot with one rerun and one receipt, not two.
assert rb.range_snapshot_commit(sealed_repo, "HEAD~2..HEAD") == sealed_sha
assert rb.is_range_snapshot(sealed_repo, sealed_sha)
assert not rb.is_range_snapshot(sealed_repo, sealed_head)
assert rb.range_snapshot_ends(sealed_repo, sealed_sha) == (sealed_base, sealed_head)
assert rb.range_snapshot_ends(sealed_repo, sealed_head) is None

# The target line names the range's own right end, never the commit it was sealed into — that sha
# is the tool's own and answers a question nobody asked.
labelled = io.StringIO()
with contextlib.redirect_stderr(labelled):
    rb.announce_review_target(sealed_repo, sealed_sha, head_label=sealed_head)
assert f"{sealed_base[:7]}..{sealed_head[:7]}" in labelled.getvalue(), labelled.getvalue()
assert f"sealed as {sealed_sha[:7]}" in labelled.getvalue(), labelled.getvalue()

# And a range is not a review of the current state, however it is sealed: a run over old or pushed
# commits stamping the repository's receipt would leave every later suggestion measuring against a
# tree nobody is standing on (found by panel, 2026-08-07).
historical = rb.range_snapshot_commit(sealed_repo, f"{sealed_base}..{sealed_second}")
assert rb.write_review_receipt(sealed_repo, historical, "run-historical", 0, worktree=False) is None
# The same guard passes a range that ends at the tip, which is the flow this feature exists for.
assert rb.write_review_receipt(sealed_repo, sealed_sha, "run-tip", 0, worktree=False) is not None

sealed_refusals = {}
for sealed_label, sealed_spec in (("shape", "HEAD"), ("empty", f"{sealed_head}..{sealed_head}")):
    try:
        rb.range_snapshot_commit(sealed_repo, sealed_spec)
        sealed_refusals[sealed_label] = ""
    except ValueError as exc:
        sealed_refusals[sealed_label] = str(exc)
assert "--range must be A..B" in sealed_refusals["shape"], sealed_refusals
assert "changes nothing" in sealed_refusals["empty"], sealed_refusals

# What the panel is about to read, said before it reads it: the target was implied by the flags and
# printed nowhere, so a run pointed at the working tree's leftovers instead of the commits the
# caller meant came back confirming nothing — which reads exactly like a clean review.
announced = io.StringIO()
with contextlib.redirect_stderr(announced):
    rb.announce_review_target(sealed_repo, sealed_sha)
assert f"{sealed_base[:7]}..{sealed_sha[:7]}" in announced.getvalue(), announced.getvalue()
assert "2 file(s)" in announced.getvalue(), announced.getvalue()
subprocess.run(["git", "-C", str(sealed_repo), "-c", "user.email=t@example.test",
                "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "empty"], check=True)
sealed_empty = subprocess.run(["git", "-C", str(sealed_repo), "rev-parse", "HEAD"],
                             check=True, capture_output=True, text=True).stdout.strip()
try:
    rb.announce_review_target(sealed_repo, sealed_empty)
    sealed_empty_refusal = ""
except ValueError as exc:
    sealed_empty_refusal = str(exc)
assert "target is empty" in sealed_empty_refusal, sealed_empty_refusal

# What a range run leaves behind is decided where it is launched, not in the helpers: the receipt
# it may not stamp, the target it names, and the label the progress view shows while it runs. Every
# one of those was reachable only through cmd_run, so a regression there passed the suite while the
# helpers stayed green (found by panel, 2026-08-07).
range_run_seen = {}


def range_run_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    progress_path = rb.state_dir() / rb.PROGRESS_DIR / rb.progress_file_name(sealed_repo)
    range_run_seen["target"] = json.loads(progress_path.read_text())["target"]
    return 0, 1, "NO FINDINGS", "", []


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = range_run_runner
rb.pool_account = lambda side, excluded, slot=0, bucket="general": "fixture"
rb.affordability = lambda: {
    "claude": True, "codex": True, "agy": True, "grok": True, "opencode": True,
    "claude_account": "fixture",
}
os.environ.pop("WORKER_STATS_DIR", None)


def sealed_run(store_name, **fields):
    os.environ["CLAUDEB_DIR"] = str(work / store_name)
    stream = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stream):
        rc = rb.cmd_run(argparse.Namespace(
            repo=str(sealed_repo), raters="opus-medium", leg=False, verify=None,
            auto=None, focus=None, **fields,
        ))
    receipt = (work / store_name / "worker-stats" / rb.RECEIPT_DIR
               / rb.receipt_file_name(sealed_repo))
    return rc, stream.getvalue(), receipt


# A range of old commits reviews old code: stamping the repository's receipt with it would leave
# every later suggestion measuring the working tree against a tree nobody is standing on.
range_rc, range_err, range_receipt = sealed_run(
    "range-run-claudeb", commitish=None, range=f"{sealed_base}..{sealed_second}")
assert range_rc == 0, range_err
assert not range_receipt.exists(), "a historical range stamped the repository's receipt"
assert range_run_seen["target"] == "range", range_run_seen

# A rerun arrives as the sealed sha and no flags at all, and has to be the same kind of run as the
# one that made it — down to naming the commits the caller asked about rather than the tool's own.
rerun_rc, rerun_err, rerun_receipt = sealed_run(
    "range-rerun-claudeb", commitish=historical)
assert rerun_rc == 0, rerun_err
assert not rerun_receipt.exists(), "the rerun of a historical range stamped the receipt"
assert range_run_seen["target"] == "range", range_run_seen
assert f"{sealed_base[:7]}..{sealed_second[:7]}" in rerun_err, rerun_err
assert f"sealed as {historical[:7]}" in rerun_err, rerun_err

# And the range this feature exists for — one ending at the tree in front of the reader — does
# stamp it, or a review of a whole branch would leave the commit gate none the wiser.
tip_rc, tip_err, tip_receipt = sealed_run(
    "range-tip-claudeb", commitish=None, range=f"{sealed_base}..{sealed_head}")
assert tip_rc == 0, tip_err
assert tip_receipt.exists(), tip_err

# --- lenses: a run launched and recorded under the methodology it was given -------------------
lens_store = work / "lens-claudeb"
os.environ["CLAUDEB_DIR"] = str(lens_store)
os.environ.pop("WORKER_STATS_DIR", None)
lens_seen = {}
lens_launch_meta = []


def lens_run_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    lens_seen[rater["spec"]] = (rater.get("lens") or {}).get("name", "")
    lens_launch_meta.append(json.loads((run_dir / "meta.json").read_text()))
    return 0, 1, "NO FINDINGS", "", []


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = lens_run_runner
rb.pool_account = lambda side, excluded, slot=0, bucket="general": "fixture"
rb.affordability = lambda: {
    "claude": True, "codex": True, "agy": True, "grok": True, "opencode": True,
    "claude_account": "fixture",
}
with contextlib.redirect_stdout(io.StringIO()) as lens_tier_out:
    lens_tier_rc = rb.cmd_review(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, tier="T1",
        verify=None, focus=None, lens="edge",
    ))
assert lens_tier_rc == 0
assert "out of a lens's reach" in lens_tier_out.getvalue(), lens_tier_out.getvalue()
lens_run_dir = next((lens_store / "worker-stats" / "benches").iterdir())
lens_meta = json.loads((lens_run_dir / "meta.json").read_text())
# An alias was asked for; the canonical slug is what the run has to carry.
assert lens_meta["lens"] == "edge-cases", lens_meta
assert lens_meta["lens_hash"] == rb.resolve_lens("edge-cases")["hash"], lens_meta
assert lens_meta["lens_source_status"] == "current", lens_meta
assert lens_meta["tier"] == "T1"
assert lens_meta["raters"] and not any(
    spec.startswith(("oc-", "agy-")) for spec in lens_meta["raters"]
), lens_meta["raters"]
# The tier the run records names a composition wider than the panel it launched, so the cells
# the lens took out are recorded beside it.
assert lens_meta["lens_panel_dropped"] and all(
    spec.startswith(("oc-", "agy-")) for spec in lens_meta["lens_panel_dropped"]
), lens_meta
assert set(lens_seen.values()) == {"edge-cases"}, lens_seen
assert lens_seen.keys() == set(lens_meta["raters"]), lens_seen
# A run reading its own meta while the cells are still out — a progress view, or an abort —
# has to find the lens there too, not only in what the finished run wrote.
assert all(
    launched["lens"] == "edge-cases" and launched["lens_hash"] == lens_meta["lens_hash"]
    and launched["lens_source_status"] == "current"
    for launched in lens_launch_meta
), lens_launch_meta
# The verifier reaches OpenCode and agy findings only, and a lens panel drops both sides.
assert lens_meta["verifier"] == "", lens_meta

repeat_lens_store = work / "lens-repeat-claudeb"
os.environ["CLAUDEB_DIR"] = str(repeat_lens_store)
with contextlib.redirect_stdout(io.StringIO()) as repeat_lens_out:
    lens_repeat_rc = rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters="opus-medium-skill x3,oc-kimik3",
        leg=False, verify=None, auto=None, focus=None, lens="repeat-lens",
    ))
assert lens_repeat_rc == 0
repeat_lens_meta = json.loads(
    (next((repeat_lens_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert repeat_lens_meta["raters"] == ["opus-medium", "opus-medium#2"], repeat_lens_meta
assert repeat_lens_meta["lens"] == "repeat-lens", repeat_lens_meta
assert repeat_lens_meta["lens_panel_dropped"] == [
    "oc-kimik3", "opus-medium-skill#3",
], repeat_lens_meta
assert "skipped opus-medium-skill#3:" in repeat_lens_out.getvalue(), repeat_lens_out.getvalue()

# --auto picks from the cells a lens can actually reach: picking first and filtering after left
# the run short of the number asked for while eligible cells sat unpicked.
auto_lens_store = work / "lens-auto-claudeb"
os.environ["CLAUDEB_DIR"] = str(auto_lens_store)
rb.state_dir().mkdir(parents=True, exist_ok=True)
rb.write_jsonl(rb.state_dir() / "reviews.jsonl", [
    {"run_id": "seed", "commit": pin_sha, "rater": spec}
    for spec in rb.AUTO_RATERS if not spec.startswith("agy-")
])
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters="", leg=False,
        verify=None, auto=3, focus=None, lens="edge-cases",
    )) == 0
auto_lens_meta = json.loads(
    (next((auto_lens_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert len(auto_lens_meta["raters"]) == 3, auto_lens_meta
assert not any(spec.startswith(("oc-", "agy-")) for spec in auto_lens_meta["raters"]), \
    auto_lens_meta
assert auto_lens_meta["lens_panel_dropped"] == [], auto_lens_meta

# A -skill cell runs the plain prompt under a lens, and the spec it is recorded under says so.
skill_lens_store = work / "lens-skill-claudeb"
os.environ["CLAUDEB_DIR"] = str(skill_lens_store)
lens_seen.clear()
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters="opus-medium-skill,opus-medium",
        leg=False, verify=None, auto=None, focus=None, lens="edge-cases",
    )) == 0
skill_lens_meta = json.loads(
    (next((skill_lens_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert skill_lens_meta["raters"] == ["opus-medium"], skill_lens_meta
assert skill_lens_meta["lens_panel_dropped"] == ["opus-medium"], skill_lens_meta
assert lens_seen == {"opus-medium": "edge-cases"}, lens_seen
empty_lens_store = work / "lens-empty-claudeb"
os.environ["CLAUDEB_DIR"] = str(empty_lens_store)
try:
    rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters="sonnet-medium-skill",
        leg=False, verify=None, auto=None, focus=None, lens="edge-cases",
    ))
except RuntimeError as exc:
    assert "no cell to run" in str(exc), exc
else:
    raise AssertionError("a lens run emptied by skill-only drops was accepted")
assert not (empty_lens_store / "worker-stats" / "benches").exists()
try:
    rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters="oc-kimik3,agy-pro-high-skill",
        leg=False, verify=None, auto=None, focus=None, lens="edge-cases",
    ))
except RuntimeError as exc:
    assert "no cell to run" in str(exc), exc
else:
    raise AssertionError("a lens run of cells no lens can reach must be refused")
plain_lens_store = work / "lens-absent-claudeb"
os.environ["CLAUDEB_DIR"] = str(plain_lens_store)
lens_seen.clear()
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_review(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, tier="T1", verify=None, focus=None,
    )) == 0
plain_lens_meta = json.loads(
    (next((plain_lens_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert "lens" not in plain_lens_meta and "lens_hash" not in plain_lens_meta, plain_lens_meta
assert any(spec.startswith("oc-") for spec in plain_lens_meta["raters"]), plain_lens_meta
assert set(lens_seen.values()) == {""}, lens_seen

# The corpus row is where a lens run stops being indistinguishable from an ordinary one, and
# an absent field rather than a null is what every reader below keys on.
lens_empty_verdicts = work / "lens-empty-verdicts.jsonl"
lens_empty_verdicts.write_text("")
plain_lens_run_dir = next((plain_lens_store / "worker-stats" / "benches").iterdir())
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_record(argparse.Namespace(
        run_id=plain_lens_meta["run_id"], verdicts=str(lens_empty_verdicts),
    )) == 0
plain_lens_corpus = rb.read_jsonl(plain_lens_store / "worker-stats" / "reviews.jsonl")
assert plain_lens_corpus and not any(
    "lens" in row or "lens_hash" in row for row in plain_lens_corpus
), plain_lens_corpus
os.environ["CLAUDEB_DIR"] = str(lens_store)
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_record(argparse.Namespace(
        run_id=lens_meta["run_id"], verdicts=str(lens_empty_verdicts),
    )) == 0
lens_corpus = rb.read_jsonl(lens_store / "worker-stats" / "reviews.jsonl")
assert lens_corpus and all(
    row["lens"] == "edge-cases" and row["lens_hash"] == lens_meta["lens_hash"]
    for row in lens_corpus
), lens_corpus
# The tier alone names a panel, and these severities were awarded by another methodology.
lens_report_head = rb.report_lines(lens_run_dir, lens_meta)[0]
assert lens_report_head.startswith(
    "review-bench panel · T1 · lens edge-cases"
), lens_report_head
# The panel is narrower than the tier beside it, and the report is the surface that says so.
assert f"−{len(lens_meta['lens_panel_dropped'])} cell(s)" in lens_report_head, lens_report_head
assert "lens" not in rb.report_lines(plain_lens_run_dir, plain_lens_meta)[0], \
    rb.report_lines(plain_lens_run_dir, plain_lens_meta)

# A lens receipt sits beside the repository's own and never as it: the receipt is what decides
# whether the working tree counts as reviewed, and the statusline reads only the plain name.
os.environ["CLAUDEB_DIR"] = str(work / "lens-receipt-claudeb")
lens_receipt_name = rb.receipt_file_name(pin_repo, "edge-cases")
plain_receipt_name = rb.receipt_file_name(pin_repo)
assert lens_receipt_name != plain_receipt_name, lens_receipt_name
assert lens_receipt_name == f"{plain_receipt_name[:-len('.json')]}__lens-edge-cases.json", \
    lens_receipt_name
rb.persist_review_receipt(pin_repo, snapshot_tree, pin_sha, "lens-run", 0, lens="edge-cases")
assert rb.review_receipt(pin_repo) is None, "a lens run wrote the repository's own receipt"
assert rb.review_receipt(pin_repo, "edge-cases")["lens"] == "edge-cases"
rb.persist_review_receipt(pin_repo, snapshot_tree, pin_sha, "plain-run", 0)
rb.write_jsonl(rb.state_dir() / "reviews.jsonl", [
    {"run_id": "plain-run", "commit": pin_sha, "rater": "sol-low", "confirmed": 1},
    {"run_id": "lens-run", "commit": pin_sha, "rater": "sol-low", "confirmed": 9,
     "lens": "edge-cases"},
])
# Aggregated per commit, so without the filter the lens run's nine would price the next change
# as work provoked by a review that never ran under the tool's own methodology.
assert rb.review_outcome(pin_repo, rb.review_receipt(pin_repo))[1] == 1
assert rb.review_outcome(pin_repo, rb.review_receipt(pin_repo, "edge-cases"))[1] == 9

# Nothing a lens run adjudicated may reach the canonical defect list or the frontier built on
# it: a lens adjudication moving a tier composition is the one thing lens runs must not do.
os.environ["CLAUDEB_DIR"] = str(work / "lens-frontier-claudeb")
lens_frontier_sd = rb.state_dir()
lens_frontier_commit = "c" * 40
for run_name, lens_fields in (("plain-run", {}), ("lens-run", {"lens": "edge-cases"})):
    directory = lens_frontier_sd / "benches" / run_name
    directory.mkdir(parents=True)
    (directory / "meta.json").write_text(json.dumps({
        "run_id": run_name, "commit": lens_frontier_commit, "repo": str(pin_repo),
        "raters": ["sol-low"],
        "rater_runs": [{"rater": "sol-low", "duration_ms": 60_000, "exit_code": 0}],
        "durations": {"sol-low": 60_000},
        "started": "2026-08-01T00:00:00+00:00", "finished": "2026-08-01T00:00:01+00:00",
        **lens_fields,
    }))
    rb.write_jsonl(directory / "defects.jsonl", [{
        "defect_id": f"{run_name}#1", "file": "a.py", "line": 1, "severity": "P1",
        "summary": run_name, "canonical_rater": "sol-low", "canonical_idx": 0,
        "caught_by": ["sol-low"],
    }])
lens_defect_rows, _, _ = rb.commit_defect_rows(lens_frontier_sd, lens_frontier_commit[:7])
assert [row["run_id"] for row in lens_defect_rows] == ["plain-run"], lens_defect_rows
(lens_frontier_sd / "defects").mkdir(parents=True, exist_ok=True)
rb.write_jsonl(lens_frontier_sd / "defects" / "fixture__ccccccc.jsonl", [{
    "defect_id": "fixture@ccccccc#1", "repo": "fixture", "commit": lens_frontier_commit,
    "file": "a.py", "line": 1, "severity": "P1", "summary": "one",
    "caught_by": ["sol-low"],
    "catches": [{"run_id": "plain-run", "rater": "sol-low"},
                {"run_id": "lens-run", "rater": "sol-low"}],
}])
(lens_by_commit, lens_cells, _, _, lens_run_counts, _,
 lens_counted) = rb.frontier_inputs(lens_frontier_sd)
assert lens_cells == ["sol-low"], lens_cells
assert lens_run_counts[("ccccccc", "sol-low")] == 1, lens_run_counts
assert lens_counted["ccccccc"] == {("plain-run", "sol-low")}, lens_counted
# The lens run's catch has no denominator and is dropped whole; counting it would put the cell
# at twice the rate one fresh ordinary run of it actually delivers.
assert rb.hit_rates(lens_by_commit, lens_run_counts, lens_counted) == {
    "fixture@ccccccc#1": {"sol-low": 1.0}
}, rb.hit_rates(lens_by_commit, lens_run_counts, lens_counted)

# --- merged reviews: one panel over several repositories -----------------------------------------
# A change that spans a producer and its consumer in two checkouts used to be two runs, each blind
# to the half of the contract the other read. One run reads both, and the price of that is that
# every repository it read must end up with exactly the receipt a solo run would have left: a
# merged review that stamps one of them and forgets the other leaves the forgotten one's commit
# gate blocking on a review that already covered it.
merged_repos = {}
for merged_name, merged_files in (
    ("producer", {"rates.json": '{"read": 1}\n', "emit.sh": "emit\n"}),
    ("consumer", {"read.sh": "read\n"}),
):
    merged_repo = work / merged_name
    merged_repo.mkdir()
    subprocess.run(["git", "init", "-q", str(merged_repo)], check=True)
    subprocess.run(["git", "-C", str(merged_repo), "config", "user.email", "bench@example.test"],
                   check=True)
    subprocess.run(["git", "-C", str(merged_repo), "config", "user.name", "Review Bench"],
                   check=True)
    for merged_file, merged_body in merged_files.items():
        (merged_repo / merged_file).write_text(merged_body)
    subprocess.run(["git", "-C", str(merged_repo), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(merged_repo), "commit", "-qm", "initial"], check=True)
    merged_repos[merged_name] = merged_repo
(merged_repos["producer"] / "rates.json").write_text('{"read": 1, "write": 2}\n')
(merged_repos["producer"] / "emit.sh").write_text("emit\nemit write\n")
(merged_repos["consumer"] / "read.sh").write_text("read\nread write\n")
merged_pair = [merged_repos["producer"], merged_repos["consumer"]]
# What the run records is the working tree git itself resolves the argument to, which on macOS is
# not the path the fixture typed.
merged_tops = [rb.resolve_repo_arg(str(path)) for path in merged_pair]
merged_heads = {
    name: subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"],
                         check=True, capture_output=True, text=True).stdout.strip()
    for name, path in merged_repos.items()
}

# The prefix is the basename, because a rater reads it instead of a path; two checkouts sharing one
# are numbered rather than merged into a single prefix that would hide which repository a finding
# is about.
assert rb.merged_repo_labels(merged_pair) == ["producer", "consumer"]
for merged_dup in ("dup-left", "dup-right"):
    (work / merged_dup / "same").mkdir(parents=True)
assert rb.merged_repo_labels(
    [work / "dup-left" / "same", work / "dup-right" / "same"]
) == ["same", "same-2"]
assert rb.repo_arg_paths(argparse.Namespace(repo=None)) == ["."]
assert rb.repo_arg_paths(argparse.Namespace(repo=".")) == ["."]
assert rb.repo_arg_paths(argparse.Namespace(repo=["/a", "/b"])) == ["/a", "/b"]

# A scope is spelled the way the findings answering it will be — with the repository's own prefix —
# and an absolute path is taken too. A repository nobody names keeps its whole working tree,
# because narrowing one half of a contract is the ordinary case.
merged_pairs = list(zip(["producer", "consumer"], merged_pair))
assert rb.split_merged_scope(merged_pairs, ["producer/rates.json"]) == {
    "producer": ["rates.json"], "consumer": [],
}
assert rb.split_merged_scope(
    merged_pairs, [str(merged_repos["consumer"] / "read.sh"), "producer/emit.sh"]
) == {"producer": ["emit.sh"], "consumer": ["read.sh"]}
merged_scope_errors = {}
for merged_label, merged_bad in (
    ("unknown", ["nowhere/x.txt"]),
    ("bare", ["producer"]),
    ("empty", ["producer/"]),
    ("outside", [str(work / "outside.txt")]),
):
    try:
        rb.split_merged_scope(merged_pairs, merged_bad)
        merged_scope_errors[merged_label] = ""
    except ValueError as exc:
        merged_scope_errors[merged_label] = str(exc)
assert "producer/, consumer/" in merged_scope_errors["unknown"], merged_scope_errors
assert "producer/, consumer/" in merged_scope_errors["bare"], merged_scope_errors
assert "producer/, consumer/" in merged_scope_errors["empty"], merged_scope_errors
assert "outside every repository" in merged_scope_errors["outside"], merged_scope_errors

merged_store = work / "merged-claudeb"
os.environ["CLAUDEB_DIR"] = str(merged_store)
merged_state = merged_store / "worker-stats"
merged_seen = {"diffs": [], "repos": [], "progress": []}


def merged_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    merged_seen["diffs"].append(diff)
    merged_seen["repos"].append(str(repo_path))
    progress_dir = merged_state / rb.PROGRESS_DIR
    merged_seen["progress"].append(sorted(
        json.loads(path.read_text())["repo"] for path in progress_dir.iterdir()
    ) if progress_dir.is_dir() else [])
    # One cell per half of the contract, so a member's own outcome cannot be read off the other's.
    cited = "producer/rates.json" if rater["side"] == "codex" else "consumer/read.sh"
    return 0, 1, json.dumps({
        "severity": "P2", "file": cited, "line": 1,
        "summary": f"{rater['spec']} cross-repository finding",
    }), "", []


for merged_side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[merged_side] = merged_runner
merged_stdout = io.StringIO()
with contextlib.redirect_stdout(merged_stdout):
    merged_rc = rb.cmd_run(argparse.Namespace(
        repo=[str(path) for path in merged_pair], commitish=None, worktree=True, paths=None,
        raters="sol-medium-bare,opus-medium", leg=False, verify=None, auto=None, focus=None,
    ))
assert merged_rc == 0, merged_stdout.getvalue()
merged_run_dir = next((merged_state / "benches").iterdir())
merged_meta = json.loads((merged_run_dir / "meta.json").read_text())
merged_sha = merged_meta["commit"]
merged_workspace = pathlib.Path(merged_meta["repo"])

# One pool, one diff, and it holds both halves of the contract with the repositories told apart by
# a directory prefix — that is the whole point of the merged run.
assert len(merged_seen["diffs"]) == 2, merged_seen["diffs"]
for merged_diff in merged_seen["diffs"]:
    assert "producer/rates.json" in merged_diff, merged_diff
    assert "consumer/read.sh" in merged_diff, merged_diff
    assert "separate checkouts" in merged_diff, merged_diff
assert set(merged_seen["repos"]) == {str(merged_workspace)}, merged_seen["repos"]
assert merged_workspace.parent == merged_state / rb.MERGED_DIR, merged_workspace
assert rb.is_worktree_snapshot(merged_workspace, merged_sha)
assert merged_meta["worktree"] is True and "scope" not in merged_meta, merged_meta
merged_members = merged_meta["repos"]
assert [member["label"] for member in merged_members] == ["producer", "consumer"], merged_members
assert [member["repo"] for member in merged_members] == [
    str(path) for path in merged_tops
], merged_members
assert all(member["scope"] == [] for member in merged_members), merged_members
assert [member["base"] for member in merged_members] == [
    merged_heads["producer"], merged_heads["consumer"]
], merged_members

# Every finding names the repository it belongs to, and the handoff says how to read it: the
# adjudicator merges rows from cells that each saw the whole contract.
merged_findings = {
    path.name[len("findings-"):-len(".jsonl")]: rb.read_jsonl(path)
    for path in sorted(merged_run_dir.glob("findings-*.jsonl"))
}
assert sorted(merged_findings) == ["opus-medium", "sol-medium-bare"], merged_findings
assert merged_findings["sol-medium-bare"][0]["repo"] == "producer", merged_findings
assert merged_findings["sol-medium-bare"][0]["file"] == "producer/rates.json", merged_findings
assert merged_findings["opus-medium"][0]["repo"] == "consumer", merged_findings
for merged_label, merged_path in zip(("producer", "consumer"), merged_tops):
    assert f"  {merged_label}/ = {merged_path}" in merged_stdout.getvalue(), \
        merged_stdout.getvalue()
# The verdict contract is untouched: the same per-rater files, the same {rater, idx, verdict}.
assert "one verdict per zero-based finding index as {rater, idx, verdict}" \
    in merged_stdout.getvalue()

# The receipt of each repository, against its own snapshot: this is what its own commit gate reads,
# and a merged review that left one of them unwritten would block that repository's commit.
merged_receipt_dir = merged_state / rb.RECEIPT_DIR
assert sorted(path.name for path in merged_receipt_dir.iterdir()) == sorted(
    rb.receipt_file_name(path) for path in merged_pair
), sorted(path.name for path in merged_receipt_dir.iterdir())
for member in merged_members:
    merged_receipt = rb.review_receipt(pathlib.Path(member["repo"]))
    assert merged_receipt is not None, member
    assert merged_receipt["commit"] == member["commit"], (merged_receipt, member)
    assert merged_receipt["run_id"] == merged_meta["run_id"], merged_receipt
    assert merged_receipt["repo"] == member["repo"], merged_receipt
    assert "scope" not in merged_receipt, merged_receipt
    # A member's snapshot is a snapshot of that repository, so the stamp hook reads it the way it
    # reads a solo worktree review's: an uncommitted tree, findings, and the base it sat on.
    merged_outcome = rb.review_outcome(pathlib.Path(member["repo"]), merged_receipt)
    assert merged_outcome == (True, 0, 1), (member["label"], merged_outcome)

# One panel reads several repositories, and each of them holds a receipt naming that one run: the
# confirmed P1s a member earned must price that member's commit and no other's, or repo A's gate
# escalates on repo B's defects. In a store of its own — a run dropped into the live merged state
# would answer the triage-owed lookups made further down instead of the run they are about.
merged_tally_state = work / "merged-tally-state"
merged_tally_dir = merged_tally_state / "benches" / "merged-tally"
merged_tally_dir.mkdir(parents=True)
(merged_tally_dir / "meta.json").write_text(json.dumps({
    "run_id": "merged-tally", "worktree": True, "tier": "T1",
    "raters": ["sol-medium-bare"], "completed_raters": ["sol-medium-bare"],
    "rater_runs": [{"rater": "sol-medium-bare", "exit_code": 0, "findings": 3}],
    "repos": [dict(member) for member in merged_members],
}) + "\n")
rb.write_jsonl(merged_tally_dir / "findings-sol-medium-bare.jsonl", [
    {"file": "producer/rates.json", "line": 1, "severity": "P2", "summary": "producer only"},
    {"file": "consumer/read.sh", "line": 1, "severity": "P1", "summary": "consumer one"},
    {"file": "consumer/read.sh", "line": 2, "severity": "P1", "summary": "consumer two"},
])
merged_tally_verdicts = [
    {"rater": "sol-medium-bare", "idx": index, "verdict": "confirmed"} for index in range(3)
]
merged_tally_saved = os.environ.get("WORKER_STATS_DIR")
os.environ["WORKER_STATS_DIR"] = str(merged_tally_state)
try:
    for merged_tally_source in ("verdicts", "report receipt"):
        if merged_tally_source == "verdicts":
            rb.write_jsonl(merged_tally_dir / "verdicts.jsonl", merged_tally_verdicts)
        else:
            # The --no-corpus path stores no verdicts, so the rows it reported are all a member
            # has to be counted out of the panel's findings by.
            (merged_tally_dir / "verdicts.jsonl").unlink()
            rb.write_report_receipt(merged_tally_dir, merged_tally_verdicts, {"P1": 2, "P2": 1})
        merged_tally = {
            member["label"]: rb.reported_severities(
                {"run_id": "merged-tally", "commit": member["commit"]}
            )
            for member in merged_members
        }
        assert merged_tally["producer"] == {"P1": 0, "P2": 1, "P3": 0}, \
            (merged_tally_source, merged_tally)
        assert merged_tally["consumer"] == {"P1": 2, "P2": 0, "P3": 0}, \
            (merged_tally_source, merged_tally)
        # And the round counted whole, which is the same number for every member: one panel over
        # two checkouts is one review of one body of work, and what that round earned cannot be
        # cheaper because the work was spread over two repositories (Egor, 2026-08-08).
        merged_round = {
            member["label"]: rb.reported_severities(
                {"run_id": "merged-tally", "commit": member["commit"]}, scoped=False
            )
            for member in merged_members
        }
        assert merged_round["producer"] == {"P1": 2, "P2": 1, "P3": 0}, \
            (merged_tally_source, merged_round)
        assert merged_round["consumer"] == merged_round["producer"], \
            (merged_tally_source, merged_round)
finally:
    if merged_tally_saved is None:
        os.environ.pop("WORKER_STATS_DIR", None)
    else:
        os.environ["WORKER_STATS_DIR"] = merged_tally_saved
# One document per repository while the run is in flight, or the review is invisible in every
# surface but one repository's.
assert merged_seen["progress"] == [
    sorted(str(path) for path in merged_tops)
] * 2, merged_seen["progress"]
assert not list((merged_state / rb.PROGRESS_DIR).iterdir())

# The gate each repository holds is `suggest`, and after the merged run neither has anything left
# to review: that is requirement three seen from the side that enforces it.
for merged_path in merged_pair:
    merged_suggest = io.StringIO()
    with contextlib.redirect_stdout(merged_suggest):
        assert rb.cmd_suggest(argparse.Namespace(repo=str(merged_path), range=None)) == 0
    assert f"nothing to review; tree matches review {merged_meta['run_id']}" \
        in merged_suggest.getvalue(), merged_suggest.getvalue()

# The verifier reads a finding's path in the merged repository, so a prefixed citation resolves to
# the file it names without any repository bookkeeping of its own.
merged_lines, merged_ref = rb.file_at_commit(
    merged_workspace, merged_sha, "consumer/read.sh"
)
assert merged_lines == ["read", "read write"], merged_lines
assert merged_ref == merged_sha, merged_ref

# Adjudication is one pass over the merged run, and it leaves both receipts exactly where the run
# put them.
merged_receipts_before = {
    path.name: path.read_bytes() for path in merged_receipt_dir.iterdir()
}
merged_verdicts = work / "merged-verdicts.jsonl"
rb.write_jsonl(merged_verdicts, [
    {"rater": "sol-medium-bare", "idx": 0, "verdict": "confirmed"},
    {"rater": "opus-medium", "idx": 0, "verdict": "confirmed"},
])
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_record(argparse.Namespace(
        run_id=merged_run_dir.name, verdicts=str(merged_verdicts), no_corpus=False, bench=True,
    )) == 0
assert {path.name: path.read_bytes() for path in merged_receipt_dir.iterdir()} \
    == merged_receipts_before
# One panel over several repositories is a different reading of the same numbers, and the line
# that names the run is where the reader is told which one they are holding.
merged_report_meta = json.loads((merged_run_dir / "meta.json").read_text())
merged_report_head = rb.report_lines(merged_run_dir, merged_report_meta)[0]
assert merged_report_head.startswith(
    f"review-bench merged panel · {len(merged_report_meta['repos'])} repos · "
), merged_report_head
assert len(merged_report_meta["repos"]) == 2, merged_report_meta["repos"]
# A merged snapshot is no more a durable corpus commit than a single-repository one.
assert not (merged_state / "reviews.jsonl").exists()

# A rerun of an errored cell is pinned to the merged commit, which lives in the workspace and
# nowhere else — and the workspace is what says which repositories it still owes receipts to.
merged_rerun_store = work / "merged-rerun-claudeb"
os.environ["CLAUDEB_DIR"] = str(merged_rerun_store)
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(merged_workspace), commitish=merged_sha, raters="sol-medium-bare",
        leg=False, verify=None, auto=None, focus=None,
    )) == 0
merged_rerun_state = merged_rerun_store / "worker-stats"
assert sorted(path.name for path in (merged_rerun_state / rb.RECEIPT_DIR).iterdir()) == sorted(
    rb.receipt_file_name(path) for path in merged_pair
), sorted(path.name for path in (merged_rerun_state / rb.RECEIPT_DIR).iterdir())
merged_rerun_meta = json.loads(
    (next((merged_rerun_state / "benches").iterdir()) / "meta.json").read_text()
)
assert merged_rerun_meta["worktree"] is True, merged_rerun_meta
assert [member["label"] for member in merged_rerun_meta["repos"]] == ["producer", "consumer"], \
    merged_rerun_meta
os.environ["CLAUDEB_DIR"] = str(merged_store)

# The report a merged run owes is owed in every repository it read, whichever one the turn happens
# to be in; scoped to one repository still means: not somebody else's review.
merged_pending_dir = merged_state / "benches" / "merged-pending"
merged_pending_dir.mkdir(parents=True)
(merged_pending_dir / "meta.json").write_text(json.dumps({
    "run_id": "merged-pending", "commit": merged_sha, "repo": str(merged_workspace),
    "worktree": True, "repos": [dict(member) for member in merged_members],
    "raters": ["sol-medium-bare"], "rater_runs": [], "durations": {},
    "started": rb.iso_now(), "finished": rb.iso_now(),
}))
for merged_path in merged_pair:
    assert rb.triage_pending_run(str(merged_path))[0] == merged_pending_dir, merged_path
assert rb.triage_pending_run(str(work / "scoped-worktree")) is None
shutil.rmtree(merged_pending_dir)

# A scope narrows the repository whose prefix it carries and leaves the other whole, and each
# repository's receipt says which of the two it is: a scoped member must not answer for its
# whole tree.
merged_scope_store = work / "merged-scope-claudeb"
os.environ["CLAUDEB_DIR"] = str(merged_scope_store)
merged_scope_stdout = io.StringIO()
with contextlib.redirect_stdout(merged_scope_stdout):
    assert rb.cmd_run(argparse.Namespace(
        repo=[str(path) for path in merged_pair], commitish=None, worktree=True,
        paths=["producer/rates.json"], raters="sol-medium-bare", leg=False, verify=None,
        auto=None, focus=None,
    )) == 0, merged_scope_stdout.getvalue()
merged_scope_state = merged_scope_store / "worker-stats"
assert sorted(path.name for path in (merged_scope_state / rb.RECEIPT_DIR).iterdir()) == sorted([
    rb.receipt_file_name(merged_repos["producer"], scope=["rates.json"]),
    rb.receipt_file_name(merged_repos["consumer"]),
]), sorted(path.name for path in (merged_scope_state / rb.RECEIPT_DIR).iterdir())
assert rb.review_receipt(merged_repos["producer"]) is None, \
    "a scoped member wrote the repository's own receipt"
assert rb.review_receipt(merged_repos["producer"], scope=["rates.json"])["scope"] \
    == ["rates.json"]
merged_scope_meta = json.loads(
    (next((merged_scope_state / "benches").iterdir()) / "meta.json").read_text()
)
assert [member["scope"] for member in merged_scope_meta["repos"]] == [["rates.json"], []], \
    merged_scope_meta
merged_scope_names = subprocess.run(
    ["git", "-C", str(merged_scope_meta["repo"]), "show", "--name-only", "--format=",
     merged_scope_meta["commit"]],
    check=True, capture_output=True, text=True,
).stdout.split()
assert sorted(merged_scope_names) == ["consumer/read.sh", "producer/rates.json"], \
    merged_scope_names
os.environ["CLAUDEB_DIR"] = str(merged_store)

# What a merged review refuses, all of it before anything is sealed.
merged_clean = work / "merged-clean"
merged_clean.mkdir()
subprocess.run(["git", "init", "-q", str(merged_clean)], check=True)
subprocess.run(["git", "-C", str(merged_clean), "config", "user.email", "bench@example.test"],
               check=True)
subprocess.run(["git", "-C", str(merged_clean), "config", "user.name", "Review Bench"],
               check=True)
(merged_clean / "still.txt").write_text("still\n")
subprocess.run(["git", "-C", str(merged_clean), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(merged_clean), "commit", "-qm", "initial"], check=True)
merged_refusals = {}
for merged_label, merged_kwargs in (
    ("commitish", {"repo": [str(path) for path in merged_pair],
                   "commitish": merged_heads["producer"], "worktree": False, "paths": None}),
    ("twice", {"repo": [str(merged_repos["producer"])] * 2, "commitish": None,
               "worktree": True, "paths": None}),
    ("workspace", {"repo": str(merged_workspace), "commitish": None, "worktree": True,
                   "paths": None}),
    ("clean", {"repo": [str(merged_repos["producer"]), str(merged_clean)], "commitish": None,
               "worktree": True, "paths": None}),
    ("missing", {"repo": [str(merged_repos["producer"]), str(work / "not-a-repo")],
                 "commitish": None, "worktree": True, "paths": None}),
):
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rb.cmd_run(argparse.Namespace(
                raters="sol-medium-bare", leg=False, verify=None, auto=None, focus=None,
                **merged_kwargs,
            ))
        merged_refusals[merged_label] = ""
    except ValueError as exc:
        merged_refusals[merged_label] = str(exc)
assert "more than one repository" in merged_refusals["commitish"], merged_refusals
assert "names one repository twice" in merged_refusals["twice"], merged_refusals
assert "no working tree to seal" in merged_refusals["workspace"], merged_refusals
assert "nothing for a merged review to read" in merged_refusals["clean"], merged_refusals
assert "not a git repository" in merged_refusals["missing"], merged_refusals

# The workspace holds the reviewed code itself. A member repository that is gone — pruned, moved,
# deleted — must not take the diff the panel read with it, or a rerun reviews nothing.
merged_sealed = {}
for merged_name in ("sealed-left", "sealed-right"):
    merged_path = work / merged_name
    merged_path.mkdir()
    subprocess.run(["git", "init", "-q", str(merged_path)], check=True)
    subprocess.run(["git", "-C", str(merged_path), "config", "user.email", "bench@example.test"],
                   check=True)
    subprocess.run(["git", "-C", str(merged_path), "config", "user.name", "Review Bench"],
                   check=True)
    (merged_path / "f.txt").write_text("base\n")
    subprocess.run(["git", "-C", str(merged_path), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(merged_path), "commit", "-qm", "initial"], check=True)
    (merged_path / "f.txt").write_text(f"changed in {merged_name}\n")
    merged_sealed[merged_name] = merged_path
merged_sealed_members = rb.merged_members(list(merged_sealed.values()))
merged_sealed_workspace, merged_sealed_sha = rb.merged_snapshot_workspace(merged_sealed_members)
assert not (merged_sealed_workspace / ".git" / "objects" / "info" / "alternates").exists()
# Deterministic: the same trees, prefixes, bases and scopes are the same commit, so a rerun finds
# the workspace it is pinned to already on disk.
assert rb.merged_snapshot_workspace(merged_sealed_members) == (
    merged_sealed_workspace, merged_sealed_sha
)
assert rb.merged_manifest(merged_sealed_workspace)["merged"] == merged_sealed_sha
shutil.rmtree(merged_sealed["sealed-right"])
merged_sealed_show = subprocess.run(
    ["git", "-C", str(merged_sealed_workspace), "show", "--format=", merged_sealed_sha],
    check=True, capture_output=True, text=True,
).stdout
assert "sealed-right/f.txt" in merged_sealed_show, merged_sealed_show
assert "changed in sealed-right" in merged_sealed_show, merged_sealed_show

# The workspaces are scaffolding: they live as long as the run can still be rerun, and no longer.
merged_stale = merged_state / rb.MERGED_DIR / ("0" * rb.MERGED_HOME_HEX)
merged_stale.mkdir(parents=True)
os.utime(merged_stale, (time.time() - (rb.TRIAGE_GATE_HOURS + 1) * 3600,) * 2)
rb.prune_merged_workspaces()
assert not merged_stale.exists()
assert merged_workspace.is_dir(), "a live merged workspace was pruned"

# The clean-tree hint of a merged run names every repository it was given, or the command it
# prints reviews one of them.
assert rb.commit_mode_command(argparse.Namespace(
    repo=[str(path) for path in merged_pair], tier="T1", max=False, foreground=False,
    raters=None, auto=None, leg=False, focus="", lens="", verify=None, no_verify=False,
)) == shlex.join([
    "review-bench", "review", "HEAD", "--tier", "T1",
    *("--repo", str(merged_tops[0])), *("--repo", str(merged_tops[1])),
])

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
report_frame_header='===================== review ====================='
report_frame_footer='=================================================='
expected_report="$report_frame_header"$'\nreview-bench panel · T2 · 5.5 min wall · slowest completed: sol-high 2 min\nconfirmed 1:  P1 1\nrejected:     1 duplicate  ~400 tok\n              2 false      ~3k tok\nfalse by:     kimi ×1 · sol-high ×1\nverifier:     off — 2 finding(s) unchecked\ncells:        sol-high 2 · kimi 2\nerrored:      opus-med (exit 2)\ntimeout:      gem-flash36-med\nmismatch:     gem-flash35-low\n'"$report_frame_footer"
assert test "$report_output" = "$expected_report"
# The frame is what the reader and every consumer of this block see first: a word centered in '='
# to exactly 50 characters, and a footer of exactly 50 more.
assert test "${#report_frame_header}" -eq 50
assert test "${#report_frame_footer}" -eq 50
assert grep -qE '^=+ [a-z]+ =+$' <<<"$(head -1 <<<"$report_output")"
assert grep -qE '^={10,}$' <<<"$(tail -1 <<<"$report_output")"
# The header must not read as the footer, or a consumer closing the block on its end shape closes
# it on the line that opens it.
assert test "$(grep -cE '^={10,}$' <<<"$report_output")" = "1"
assert contains "$report_output" $'rejected:     1 duplicate  ~400 tok\n              2 false      ~3k tok'
assert contains "$report_output" $'false by:     kimi ×1 · sol-high ×1\nverifier:     off — 2 finding(s) unchecked\ncells:        sol-high 2 · kimi 2\nerrored:      opus-med (exit 2)\ntimeout:      gem-flash36-med\nmismatch:     gem-flash35-low'
last_report=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" report --last) \
  || fail "last report failed"
assert test "$last_report" = "$expected_report"
worktree_report=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" report report-worktree) \
  || fail "worktree report failed"
expected_worktree_report=$'REVIEW-TRIAGE-PENDING report-worktree · 3 finding(s) to triage · 1 cell(s) did not complete\nreport with: review-bench record report-worktree --no-corpus --verdicts /tmp/review-bench-report-worktree-verdicts.jsonl'
assert test "$worktree_report" = "$expected_worktree_report"
# Every commit-point review is a worktree run, and the plain command is shut to all of them: the
# corpus is a benchmark instrument with a two-judge contract, and a fix round's own triage is not
# what it measures. The refusal happens before anything is written.
worktree_refused_rc=0
worktree_refused=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" record report-worktree \
  --verdicts "$WORK/report-worktree-verdicts.jsonl" 2>&1) || worktree_refused_rc=$?
assert test "$worktree_refused_rc" -eq 2
assert contains "$worktree_refused" "a commit-point review never enters the corpus"
assert contains "$worktree_refused" "review-bench record report-worktree --no-corpus"
assert contains "$worktree_refused" "--bench"
# No worktree run reaches the corpus with --bench either — the flag buys stored verdicts. A
# refusal offering a corpus row sends the reader hunting for one that is never written.
assert contains "$worktree_refused" "no corpus row is written either way"
assert contains "$worktree_refused" "verdicts.jsonl"
assert test ! -e "$REPORT_SD/benches/report-worktree/verdicts.jsonl"
# And --bench is that opt-in and nothing else: on a durable run it would buy the plain command's
# own behaviour while the help it was read in promises no corpus row.
durable_bench_rc=0
durable_bench=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" record report-adjudicated --bench \
  --verdicts "$WORK/report-worktree-verdicts.jsonl" 2>&1) || durable_bench_rc=$?
assert test "$durable_bench_rc" -eq 2
assert contains "$durable_bench" "worktree run"
assert contains "$durable_bench" "durable run"
assert test ! -e "$REPORT_SD/reviews.jsonl"
# The same promise on --help, which is where a reader meets the flag before any refusal.
bench_help=$("$SCRIPT" record --help) || fail "record --help failed"
assert contains "$bench_help" "verdicts.jsonl"
assert contains "$bench_help" "no corpus row either way"
# The benchmark opt-in, named on purpose: behind it a worktree run stores its verdicts and still
# writes no corpus row.
worktree_recorded=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" record report-worktree --bench \
  --verdicts "$WORK/report-worktree-verdicts.jsonl") || fail "worktree record failed"
assert contains "$worktree_recorded" "corpus skipped"
assert test -e "$REPORT_SD/benches/report-worktree/verdicts.jsonl"
assert contains "$worktree_recorded" "$report_frame_header"
assert contains "$worktree_recorded" "$report_frame_footer"
assert test ! -e "$REPORT_SD/reviews.jsonl"
worktree_recorded_again=$(WORKER_STATS_DIR="$REPORT_SD" "$SCRIPT" record report-worktree --bench \
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

# Lens rows are a leaderboard of their own: mixed into the default one they would score cells
# on a methodology nobody chose them for, and split by lens_hash every edit of the lens file
# would start the count again.
LENS_STATS_SD="$WORK/lens-stats"
mkdir -p "$LENS_STATS_SD"
cat >"$LENS_STATS_SD/reviews.jsonl" <<'JSONL'
{"run_id":"r1","rater":"sol-low","rater_model":"sol","rater_effort":"low","findings":2,"confirmed":1,"false_positive":1,"duplicate":0,"unique_catches":1,"misses":0,"p1":1,"p2":0,"p3":0}
{"run_id":"r2","rater":"sol-low","rater_model":"sol","rater_effort":"low","findings":2,"confirmed":2,"false_positive":0,"duplicate":0,"unique_catches":2,"misses":0,"p1":2,"p2":0,"p3":0,"lens":"edge-cases","lens_hash":"aaa"}
{"run_id":"r3","rater":"opus-medium","rater_model":"opus","rater_effort":"medium","findings":1,"confirmed":1,"false_positive":0,"duplicate":0,"unique_catches":1,"misses":0,"p1":0,"p2":1,"p3":0,"lens":"edge-cases","lens_hash":"bbb"}
JSONL
lens_stats_json=$(WORKER_STATS_DIR="$LENS_STATS_SD" "$STATS" --json) \
  || fail "worker-stats lens JSON failed"
python3 - "$lens_stats_json" <<'PY'
import json
import sys

reviews = json.loads(sys.argv[1])["reviews"]
assert [row["rater"] for row in reviews["rows"]] == ["sol-low"], reviews["rows"]
assert reviews["rows"][0]["benches"] == 1, reviews["rows"]
assert reviews["rater_rows"] == 1, reviews
lens = reviews["lenses"]["edge-cases"]
assert {row["rater"]: row["benches"] for row in lens} == {
    "sol-low": 1, "opus-medium": 1
}, lens
print("worker-stats-lens-ok")
PY
assert test "$?" -eq 0
lens_table=$(WORKER_STATS_DIR="$LENS_STATS_SD" "$STATS") || fail "worker-stats lens view failed"
assert contains "$lens_table" 'Review benchmark leaderboard — lens edge-cases'
assert contains "$lens_table" 'opus/medium'

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
assert contains "$run_help" "--lens"
assert contains "$review_help" "--lens"
# The one escape from the commit-flow door is the prefix the flow gate verifies, never a flag of
# this tool's own: a flag would be one the caller grants itself, checked by nobody.
assert test "$(grep -c 'egor-asked' <<<"$review_help")" -eq 0
assert test "$(grep -c 'egor.asked' "$SCRIPT")" -eq 0

# --- lens CLI: the registry as the reader sees it ---------------------------------------------
LENS_CLI_DIR="$WORK/lens-cli"
LENS_CLI_STATE="$WORK/lens-cli-state"
mkdir -p "$LENS_CLI_DIR" "$LENS_CLI_STATE"
LENS_CLI_SOURCE="$WORK/lens-cli-source.md"
printf 'ORIGIN SKILL\n' >"$LENS_CLI_SOURCE"
LENS_CLI_HASH="$(shasum -a 256 "$LENS_CLI_SOURCE" | cut -d' ' -f1)"
cat >"$LENS_CLI_DIR/edge-cases.md" <<EOF
---
name: edge-cases
source: $LENS_CLI_SOURCE
source_hash: $LENS_CLI_HASH
repeats: 2
aliases: [edge]
---
Hunt edge cases: a crash is P1, a wrong result P2, a rough edge P3.
EOF
lens_cli() {
  REVIEW_BENCH_LENS_DIR="$LENS_CLI_DIR" WORKER_STATS_DIR="$LENS_CLI_STATE" \
    CLAUDEB_DIR="$LENS_CLI_STATE" "$SCRIPT" lens "$@"
}
lens_listing="$(lens_cli list)" || fail "lens list failed"
assert contains "$lens_listing" "edge-cases"
assert contains "$lens_listing" "repeats=2"
assert contains "$lens_listing" "current"
lens_checked="$(lens_cli check edge)" || fail "lens check failed on an alias"
assert contains "$lens_checked" "$LENS_CLI_HASH"
assert contains "$lens_checked" "status:   current"
printf 'ORIGIN SKILL, EDITED\n' >"$LENS_CLI_SOURCE"
lens_drifted="$(lens_cli check edge-cases)"
# Drift says the lens is older than the skill it was distilled from, which is a thing to read
# and not a reason to refuse the lens: a run under it still measures a known text.
assert test "$?" -eq 0
assert contains "$lens_drifted" "drifted from"
assert contains "$lens_drifted" "$LENS_CLI_HASH"
rm -f "$LENS_CLI_SOURCE"
lens_gone="$(lens_cli check edge-cases)"
assert test "$?" -eq 0
assert contains "$lens_gone" "source missing at"
lens_cli check nosuch >/dev/null 2>&1
assert test "$?" -eq 2
lens_cli check >/dev/null 2>&1
assert test "$?" -eq 2
lens_empty="$(REVIEW_BENCH_LENS_DIR="$WORK/lens-cli-none" WORKER_STATS_DIR="$LENS_CLI_STATE" \
  "$SCRIPT" lens list)" || fail "lens list failed on an empty registry"
assert contains "$lens_empty" "no lenses registered"
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
for cell in "oc-kimik3 x2" "oc-kimik3 x3" "oc-grok45-low x2" "oc-grok45-low x3" \
  "oc-dsv4flash x2" "oc-dsv4flash x3" agy-pro-high-skill \
  "agy-flash35-medium-skill x2" "agy-flash35-medium-skill x3" "agy-flash35-high-skill x2" \
  "agy-flash36-high-skill x2" \
  agy-flash35-high-skill agy-flash36-medium-skill agy-flash36-high-skill \
  opus-low sol-low sol-low-bare \
  opus-medium sol-medium-bare opus-high sol-high "sol-high-bare x2" sol-xhigh \
  sol-xhigh-bare sol-high-bare "sol-max x2" sol-max-bare; do
  assert contains "$tiers_table" "$cell"
done
assert contains "$tiers_table" \
  "agy-flash35-low-skill: server serves Medium for the low model id (model_mismatch, 2026-07)"
assert test "$(grep -Ec '^  (eco \\(default\\)|max):.*agy-flash35-low-skill' <<<"$tiers_table")" -eq 0
owner_table="$("$SCRIPT" tiers --table 2>&1)"
assert contains "$owner_table" "T1 max"
assert contains "$owner_table" "kimi x2, grok x2, deepseek x2"
assert contains "$owner_table" "kimi x3, grok x3, deepseek x3"
assert contains "$owner_table" "gem-flash35-med x2, gem-flash35-high, gem-flash36-med, gem-flash36-high x2, gem-pro"
assert contains "$owner_table" "gem-flash36-high x2, gem-pro"
assert contains "$owner_table" "sol-low, sol-low-bare"
assert contains "$owner_table" "opus-med"
assert contains "$owner_table" "cover"
assert contains "$owner_table" "agy-flash35-low-skill:"
# T0's --max buys three extra OpenCode passes over its eco, so the owner-facing table owes a
# row for it; a tier whose two compositions are identical still gets one row.
assert test "$(grep -c '^T0 max' <<<"$owner_table")" -eq 1
assert contains "$(WORKER_STATS_DIR="$SD" "$SCRIPT" oc-models 2>&1)" \
  "--raters 'oc-kimik3 x2,oc-grok45-low x2,oc-dsv4flash x2' --verify oc-dsv4flash"
max_without_tier="$("$SCRIPT" run HEAD --max 2>&1 || true)"
assert contains "$max_without_tier" "--max requires --tier"
tier_guard="$("$SCRIPT" run HEAD --tier T2 2>&1 || true)"
assert contains "$tier_guard" "T2 runs ~10 min"
assert contains "$tier_guard" "run_in_background"

# The report is owed, not offered: a worktree run keeps owing one until its own triage is
# reported, and every part of that is the tool's answer so the hooks stay wrappers.
GATE_SD="$WORK/gate-state"
GATE_REPO="$WORK/gate-repo"
GATE_OTHER_REPO="$WORK/gate-other-repo"
git init -q "$GATE_REPO"
git init -q "$GATE_OTHER_REPO"
export GATE_REPO
gate_run() {
  mkdir -p "$GATE_SD/benches/$1"
  python3 - "$GATE_SD/benches/$1" "$1" "$2" "$3" <<'GATEPY'
import json
import os
import pathlib
import sys
from datetime import datetime, timedelta, timezone

run = pathlib.Path(sys.argv[1])
finished = datetime.now(timezone.utc) - timedelta(hours=float(sys.argv[3]))
findings = int(sys.argv[4])
meta = {
    "run_id": sys.argv[2], "worktree": True, "tier": "T1", "raters": ["oc-kimik3"],
    "repo": os.environ.get("GATE_REPO", ""),
    "rater_runs": [{
        "rater": "oc-kimik3", "side": "opencode", "exit_code": 0,
        "findings": findings, "duration_ms": 1000,
    }],
    "started": finished.isoformat(), "finished": finished.isoformat(),
}
if os.environ.get("GATE_SESSION"):
    meta["session"] = os.environ["GATE_SESSION"]
(run / "meta.json").write_text(json.dumps(meta) + "\n")
if findings:
    (run / "findings-oc-kimik3.jsonl").write_text("\n".join(
        json.dumps({"severity": "P2", "file": "a.py", "line": index + 1,
                    "summary": f"claim {index}"})
        for index in range(findings)
    ) + "\n")
GATEPY
}
gate_run 20260731T000000Z-gatefresh 0 0
gate_pending=$(WORKER_STATS_DIR="$GATE_SD" "$SCRIPT" pending-report --repo "$GATE_REPO") \
  || fail "pending-report missed an untriaged worktree run"
assert contains "$gate_pending" "20260731T000000Z-gatefresh 0"
assert contains "$gate_pending" "record 20260731T000000Z-gatefresh --no-corpus"
# A run nobody found anything in still owes a report, and an empty verdict file for it was the
# friction that got the pass skipped outright.
gate_reported=$(WORKER_STATS_DIR="$GATE_SD" "$SCRIPT" record 20260731T000000Z-gatefresh \
  --no-corpus) || fail "no-corpus record without verdicts failed"
assert contains "$gate_reported" "$report_frame_header"
assert contains "$gate_reported" "confirmed 0:"
assert test -e "$GATE_SD/benches/20260731T000000Z-gatefresh/reported.json"
# --no-corpus still leaves the run pending to `list`: only the receipt the gate reads is written.
assert test ! -e "$GATE_SD/benches/20260731T000000Z-gatefresh/verdicts.jsonl"
gate_after=$(WORKER_STATS_DIR="$GATE_SD" "$SCRIPT" pending-report --repo "$GATE_REPO" || true)
assert test -z "$gate_after"
# Findings without verdicts is the one case the shortcut must refuse.
gate_run 20260731T010000Z-gatefindings 0 2
gate_refused=$(WORKER_STATS_DIR="$GATE_SD" "$SCRIPT" record 20260731T010000Z-gatefindings \
  --no-corpus 2>&1 || true)
assert contains "$gate_refused" "--verdicts is required: 2 finding(s) to judge"
# Asked a bounded number of times, not once: a stop hook fires on an interrupted turn too, and a
# single ask was spent there instead of at the end of the turn it was meant to gate. And not
# forever: a triage that cannot be done must not wedge every stop that follows.
for gate_ask in 1 2 3; do
  gate_marked=$(WORKER_STATS_DIR="$GATE_SD" "$SCRIPT" pending-report --repo "$GATE_REPO" --mark) \
    || fail "pending-report --mark gave up after $gate_ask ask(s)"
  assert contains "$gate_marked" "20260731T010000Z-gatefindings 2"
done
gate_marked_again=$(WORKER_STATS_DIR="$GATE_SD" "$SCRIPT" pending-report --repo "$GATE_REPO" --mark || true)
assert test -z "$gate_marked_again"
# Every ask is its own appended line, so two stop hooks firing at once cannot lose an increment
# the way a read-incremented number does, and a marker left by an older build counts as an ask
# rather than a fresh allowance.
assert test "$(grep -c . "$GATE_SD/benches/20260731T010000Z-gatefindings/report-nudged")" = "3"
# A marker the gate cannot read leaves it blind, and blind means quiet: blocking a stop it can
# never release is the one failure worse than a missing report.
mkdir -p "$GATE_SD/benches/20260731T040000Z-gateunreadable"
GATE_SD="$GATE_SD" gate_run 20260731T040000Z-gateunreadable 0 0
mkdir -p "$GATE_SD/benches/20260731T040000Z-gateunreadable/report-nudged"
gate_unreadable=$(WORKER_STATS_DIR="$GATE_SD" "$SCRIPT" pending-report --repo "$GATE_REPO" --mark 2>/dev/null || true)
assert test -z "$gate_unreadable"
# The bench state is shared by every chat: a session in another repository must not be handed
# this run, spend its asks, and leave the session that owes the report unasked.
OTHER_SD="$WORK/gate-other"
GATE_SD="$OTHER_SD" GATE_REPO="$GATE_OTHER_REPO" gate_run 20260731T050000Z-gateother 0 0
gate_other=$(WORKER_STATS_DIR="$OTHER_SD" "$SCRIPT" pending-report --repo "$GATE_REPO" --mark \
  || true)
assert test -z "$gate_other"
gate_own=$(WORKER_STATS_DIR="$OTHER_SD" "$SCRIPT" pending-report --repo "$GATE_OTHER_REPO") \
  || fail "pending-report missed the run of its own repository"
assert contains "$gate_own" "20260731T050000Z-gateother 0"
# One repository is shared by co-tenant chats too: a run another chat launched is that chat's to
# report, and asking this one spent the run's three asks where they could do nothing.
SESS_SD="$WORK/gate-session"
SESS_REPO="$WORK/gate-session-repo"
git init -q "$SESS_REPO"
GATE_SD="$SESS_SD" GATE_REPO="$SESS_REPO" GATE_SESSION=sess-theirs \
  gate_run 20260731T060000Z-gatetheirs 0 0
# Refused at the newest run, never skipped past it: walking on handed this chat an OLDER run of the
# same repository — a diff that has since moved, which is the one thing the newest-only rule refuses.
GATE_SD="$SESS_SD" GATE_REPO="$SESS_REPO" GATE_SESSION=sess-mine \
  gate_run 20260731T055900Z-gatemineolder 0 0
sess_foreign=$(WORKER_STATS_DIR="$SESS_SD" "$SCRIPT" pending-report --repo "$SESS_REPO" \
  --session sess-mine --mark || true)
assert test -z "$sess_foreign"
sess_owner=$(WORKER_STATS_DIR="$SESS_SD" "$SCRIPT" pending-report --repo "$SESS_REPO" \
  --session sess-theirs) || fail "pending-report hid a run from the chat that launched it"
assert contains "$sess_owner" "20260731T060000Z-gatetheirs 0"
# No flag, no filter: the hook adopts --session separately, and until it does nothing may change.
sess_unfiltered=$(WORKER_STATS_DIR="$SESS_SD" "$SCRIPT" pending-report --repo "$SESS_REPO") \
  || fail "pending-report answered differently without --session"
assert contains "$sess_unfiltered" "20260731T060000Z-gatetheirs 0"
# The foreign ask must not have been spent either, and neither may the older run's: it was never
# this chat's to spend, and the run it belongs to was not the one being asked about.
assert test ! -e "$SESS_SD/benches/20260731T060000Z-gatetheirs/report-nudged"
assert test ! -e "$SESS_SD/benches/20260731T055900Z-gatemineolder/report-nudged"
# The older run is a valid untriaged one of this chat's own: it is the newest-first rule that hides
# it, not the fixture.
rm -rf "$SESS_SD/benches/20260731T060000Z-gatetheirs"
sess_older=$(WORKER_STATS_DIR="$SESS_SD" "$SCRIPT" pending-report --repo "$SESS_REPO" \
  --session sess-mine) || fail "pending-report missed this chat's own untriaged run"
assert contains "$sess_older" "20260731T055900Z-gatemineolder 0"
# A run naming no launching chat is owed to whoever is here — a daemon launch, an older build.
# Invisible, it would be triaged by nobody, which is worse than one ask in the wrong chat.
UNOWNED_SD="$WORK/gate-unowned"
GATE_SD="$UNOWNED_SD" GATE_REPO="$SESS_REPO" gate_run 20260731T070000Z-gateunowned 0 0
sess_unowned=$(WORKER_STATS_DIR="$UNOWNED_SD" "$SCRIPT" pending-report --repo "$SESS_REPO" \
  --session sess-mine) || fail "pending-report hid a run that records no launching chat"
assert contains "$sess_unowned" "20260731T070000Z-gateunowned 0"

# An old run reviewed a diff that has since moved; asking for its triage now is noise.
STALE_SD="$WORK/gate-stale"
GATE_SD="$STALE_SD" gate_run 20260730T000000Z-gatestale 48 1
gate_stale=$(WORKER_STATS_DIR="$STALE_SD" "$SCRIPT" pending-report --repo "$GATE_REPO" || true)
assert test -z "$gate_stale"

# A review of part of the tree never answers for the repository: `receipt` with no selector finds
# nothing, and a commit no gate priced carries no ticket either, so the stamp hook writes no
# whole-repo receipt over it. The scope's own receipt is readable only when asked for by name.
SCOPE_REPO="$WORK/scoped-worktree"
SCOPE_SD="$WORK/scope-run-claudeb/worker-stats"
scope_receipt_rc=0
WORKER_STATS_DIR="$SCOPE_SD" "$SCRIPT" receipt --repo "$SCOPE_REPO" >/dev/null 2>&1 \
  || scope_receipt_rc=$?
assert test "$scope_receipt_rc" -eq 1
scope_named_receipt=$(WORKER_STATS_DIR="$SCOPE_SD" "$SCRIPT" receipt --repo "$SCOPE_REPO" \
  --scope alpha.txt) || fail "the scope's own receipt is unreadable"
assert test "$(jq -r '.scope | join(",")' <<<"$scope_named_receipt")" = "alpha.txt"
assert test "$(jq -r '.worktree' <<<"$scope_named_receipt")" = "true"
STAMP_HOOK="$ROOT/bin/review-stamp-hook.sh"
jq -nc --arg cwd "$SCOPE_REPO" \
  '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$cwd,
    tool_input:{command:"git commit -m fixes"}}' \
  | WORKER_STATS_DIR="$SCOPE_SD" REVIEW_STAMP_HOOK_BENCH="$SCRIPT" "$STAMP_HOOK" >/dev/null 2>&1
scope_receipt_files=$(ls "$SCOPE_SD/receipts")
assert test "$(wc -l <<<"$scope_receipt_files" | tr -d ' ')" -eq 1
assert contains "$scope_receipt_files" '__scope-'

# A day-one repository must be able to FINISH a review, not only start one: its first commit has
# no parent, and every stamp shape that reasoned backwards from HEAD stalled there. A ticket names
# content rather than a position in the history, so the root commit answers it like any other.
root_hook_receipt_path() { # top statedir
  printf '%s/receipts/%s__%s.json' "$2" "$(basename "$1")" \
    "$(printf '%s' "$1" | shasum -a 1 | awk '{print substr($1, 1, 8)}')"
}
root_hook_fire() { # repo statedir
  jq -nc --arg cwd "$1" '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$cwd,
    tool_input:{command:"git commit -m fixes"}}' \
    | WORKER_STATS_DIR="$2" REVIEW_STAMP_HOOK_BENCH="$SCRIPT" "$STAMP_HOOK" >/dev/null 2>&1
}
ROOT_COMMIT_REPO="$WORK/root-hook-commit"
ROOT_COMMIT_SD="$WORK/root-hook-commit-state"
mkdir -p "$ROOT_COMMIT_REPO" "$ROOT_COMMIT_SD/receipts"
git -C "$ROOT_COMMIT_REPO" init -q -b main
printf 'day one\n' >"$ROOT_COMMIT_REPO/a.txt"
root_commit_gitdir=$(git -C "$ROOT_COMMIT_REPO" rev-parse --absolute-git-dir)
printf '%s\0' ticket '' '' '2026-08-07T00:00:00' \
  "$(git -C "$ROOT_COMMIT_REPO" hash-object a.txt) a.txt" \
  >"$root_commit_gitdir/review-cycle-day-one"
git -C "$ROOT_COMMIT_REPO" add -A
git -C "$ROOT_COMMIT_REPO" -c user.name=Fixture -c user.email=fixture@example.com commit -qm root
root_hook_fire "$ROOT_COMMIT_REPO" "$ROOT_COMMIT_SD"
root_commit_receipt=$(root_hook_receipt_path \
  "$(cd "$ROOT_COMMIT_REPO" && pwd -P)" "$ROOT_COMMIT_SD")
assert grep -q '^stamped-' <<<"$(jq -r '.run_id' "$root_commit_receipt")"
assert test ! -f "$root_commit_gitdir/review-cycle-day-one"

TRIAGE_HOOK="${REVIEW_TRIAGE_HOOK:-"$ROOT/../claude-setup/hooks/review-triage-nudge.sh"}"
if test -x "$TRIAGE_HOOK"; then
  triage_hook_output="$(jq -nc \
    --arg output $'run id: x\nREVIEW-TRIAGE-PENDING x · 1 finding(s) to triage\nreport with: y' \
    '{tool_name:"Bash",tool_response:{stdout:$output}}' | "$TRIAGE_HOOK")"
  assert contains "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$triage_hook_output")" \
    "not a report"
  # The suite's own fixture marker is prefixed, and a hook firing on it would nudge on every
  # test run that prints one.
  triage_hook_fixture="$(jq -nc \
    --arg output $'FIXTURE-REVIEW-TRIAGE-PENDING x · 0 finding(s) to triage' \
    '{tool_name:"Bash",tool_response:{stdout:$output}}' | "$TRIAGE_HOOK")"
  assert test -z "$triage_hook_fixture"
  triage_hook_report="$(jq -nc \
    --arg output "$report_frame_header"$'\nconfirmed 0:\n'"$report_frame_footer" \
    '{tool_name:"Bash",tool_response:{stdout:$output}}' | "$TRIAGE_HOOK")"
  assert test -z "$triage_hook_report"
else
  printf 'SKIP: review triage hook behavior (%s is unavailable)\n' "$TRIAGE_HOOK"
fi

GATE_HOOK="${REVIEW_REPORT_GATE:-"$ROOT/../claude-setup/hooks/review-report-gate.sh"}"
if test -x "$GATE_HOOK"; then
  GATE_HOOK_SD="$WORK/gate-hook-state"
  GATE_SD="$GATE_HOOK_SD" gate_run 20260731T020000Z-gatehook 0 0
  gate_hook_payload=$(jq -nc --arg cwd "$GATE_REPO" '{stop_hook_active:false,cwd:$cwd}')
  gate_hook_out="$(printf '%s' "$gate_hook_payload" \
    | PATH="$ROOT/bin:$PATH" WORKER_STATS_DIR="$GATE_HOOK_SD" "$GATE_HOOK")"
  assert test "$(jq -r '.decision' <<<"$gate_hook_out")" = "block"
  assert contains "$(jq -r '.reason' <<<"$gate_hook_out")" "20260731T020000Z-gatehook"
  assert contains "$(jq -r '.reason' <<<"$gate_hook_out")" "--no-corpus"
  # Bounded by the tool's ask allowance, so a stop it could not unblock stops being blocked.
  for gate_hook_ask in 2 3; do
    gate_hook_again="$(printf '%s' "$gate_hook_payload" \
      | PATH="$ROOT/bin:$PATH" WORKER_STATS_DIR="$GATE_HOOK_SD" "$GATE_HOOK")"
    assert test "$(jq -r '.decision' <<<"$gate_hook_again")" = "block"
  done
  gate_hook_spent="$(printf '%s' "$gate_hook_payload" \
    | PATH="$ROOT/bin:$PATH" WORKER_STATS_DIR="$GATE_HOOK_SD" "$GATE_HOOK")"
  assert test -z "$gate_hook_spent"
  GATE_SD="$GATE_HOOK_SD" gate_run 20260731T030000Z-gateloop 0 0
  # The harness says a stop hook already ran; blocking again from inside that is the loop.
  gate_hook_loop="$(printf '%s' "$(jq -nc --arg cwd "$GATE_REPO" '{stop_hook_active:true,cwd:$cwd}')" \
    | PATH="$ROOT/bin:$PATH" WORKER_STATS_DIR="$GATE_HOOK_SD" "$GATE_HOOK")"
  assert test -z "$gate_hook_loop"
  # The hook hands its own session id to the tool, so a run another chat launched neither blocks
  # this chat's stop nor spends the run's asks here — while the launching chat is still blocked.
  GATE_HOOK_SESS_SD="$WORK/gate-hook-session"
  GATE_SD="$GATE_HOOK_SESS_SD" GATE_SESSION=hook-theirs gate_run 20260731T080000Z-gatehooksess 0 0
  gate_hook_foreign="$(printf '%s' "$(jq -nc --arg cwd "$GATE_REPO" \
    '{stop_hook_active:false,cwd:$cwd,session_id:"hook-mine"}')" \
    | PATH="$ROOT/bin:$PATH" WORKER_STATS_DIR="$GATE_HOOK_SESS_SD" "$GATE_HOOK")"
  assert test -z "$gate_hook_foreign"
  assert test ! -e "$GATE_HOOK_SESS_SD/benches/20260731T080000Z-gatehooksess/report-nudged"
  gate_hook_owner="$(printf '%s' "$(jq -nc --arg cwd "$GATE_REPO" \
    '{stop_hook_active:false,cwd:$cwd,session_id:"hook-theirs"}')" \
    | PATH="$ROOT/bin:$PATH" WORKER_STATS_DIR="$GATE_HOOK_SESS_SD" "$GATE_HOOK")"
  assert test "$(jq -r '.decision' <<<"$gate_hook_owner")" = "block"
else
  printf 'SKIP: review report gate behavior (%s is unavailable)\n' "$GATE_HOOK"
fi

REPORT_HOOK="${REVIEW_REPORT_HOOK:-"$ROOT/../claude-setup/hooks/review-report-nudge.sh"}"
if test -x "$REPORT_HOOK"; then
  for hook_tool in Bash Read; do
    hook_output="$(jq -nc --arg tool "$hook_tool" \
      --arg output $'before\n'"$report_frame_header"$'\nT1 report\n'"$report_frame_footer"$'\nafter' \
      '{tool_name:$tool,tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
    assert contains "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$hook_output")" \
      "verbatim as a fenced code block"
  done
  # A run read back with `head -N` can stop short of the closing rule, and the header alone still
  # owes the nudge: the report is in that output either way.
  hook_truncated="$(jq -nc \
    --arg output "$report_frame_header"$'\nT1 report\nfindings: none' \
    '{tool_name:"Bash",tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
  assert contains "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$hook_truncated")" \
    "re-read the block"
  # The other side of the same key: a window that cut the header is silent, because the closing
  # rule alone belongs to every framed report and to any `====` divider a Read scrolls past. That
  # miss costs one nudge on output the model still holds; the alternative fired on all of them.
  hook_headerless="$(jq -nc \
    --arg output $'T1 report\nfindings: none\n'"$report_frame_footer" \
    '{tool_name:"Bash",tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
  assert test -z "$hook_headerless"
  # The header has to be the whole line: a report is not what a sentence mentioning one is.
  hook_inline="$(jq -nc --arg output "talking about $report_frame_header in passing" \
    '{tool_name:"Bash",tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
  assert test -z "$hook_inline"
  hook_without_output="$(jq -n --rawfile source "$SCRIPT" \
    '{tool_name:"Read",tool_response:{content:$source}}' | "$REPORT_HOOK")"
  assert test -z "$hook_without_output"
else
  printf 'SKIP: review report hook behavior (%s is unavailable)\n' "$REPORT_HOOK"
fi

printf 'PASS: %s assertions; canonical review tiers over one shared OpenCode floor and a per-tier Gemini panel that never runs Pro at T0, stays inside the account roster and contains its own tier'"'"'s default panel when escalated, with no retired cell in any of them, cells retired by measurement refused with their counts, tier CLI and fixture-backed tier execution, review receipts and receipt-relative suggestions with missing-object fallback, fixture diff suggestions across all sizes and escalations, rater grammar (incl. agy and OpenCode families), CLI option surface, worker-pick affordability, gap-driven auto-pick, Codex/Claude normalization, fixture-driven agy and OpenCode fail-closed handling, usage artifacts, resolved-model metadata, SHA-pinned prompt and verifier content, prompt-file transport and max-token fallback, agy sealed clones with no descendant-history leak and /code-review Markdown adaptation, persisted verdict/defect attribution written before the corpus row, re-adjudication replacing the rows of a run instead of silently keeping the old ones, recovered-verdict provenance, a clean-review marker recognised inside Claude and Codex envelopes, the Gemini per-model wall reaching SIDE_WALL from the log, a verifier wall recorded before the gate is released, tiered path resolution with the parent tree as fallback, the repository a run reviewed stamped into the corpus or reported untraceable, cross-run defect reconciliation with severity taken from the members and every incomplete or repository-spanning grouping refused, the session account schedulable only as the pool'"'"'s reserve and never as a roster tail, and a per-side account exclusion honoured for pooled and fixed sides alike, the frontier engine scoring one fresh run per named cell with legacy specs normalised and a repeat priced as an independent run, record aggregation/dedupe, unique catches, misses, weighted review score, run listing, 429-detection (fixed), per-side account ordering with Gemini rotation onto a second account after a usage wall, errored-rater exclusion, cross-side parallelism result assembly, review lenses registered with a declared slug and their own P1/P2/P3 mapping, resolved through former slugs, replacing the vendor methodology on every side a lens can reach and refused where none can, trimmed to the lens'"'"'s own repeat count and recorded with their hash and source-drift state in both the launch and the finished meta, carried from there into the corpus row, the report header and a receipt of the lens'"'"'s own while every lens row stays out of the canonical defect list, the frontier denominators, the composition corpus and the default leaderboard, worktree runs narrowed to named paths whose snapshot holds only those paths, is deterministic per path set, spelled against the directory the caller stands in and lexically canonicalized so a `..` can neither walk out of the repository nor split one file into two scopes, carries its scope as commit trailers a failed read refuses rather than widens, so a rerun by sha stays inside it, refuses a commitish, a pathspec matching nothing and a scope holding no change — the refusal before any snapshot object is written — and writes only a receipt of its own — leaving the repository'"'"'s receipt untouched byte for byte, the suggest baseline whole and the stamp hook with nothing to read, a lens narrowed by the same paths naming a combined receipt of its own that leaves the plain, pure-lens and pure-scope receipts byte for byte and survives a rerun by sha with both selectors intact, a day-one repository reviewed end to end — its root commit sealed and cloned, given a deterministic empty base commit inside that clone so the vendor skill diffs its whole content, measured in lines and paths against the empty tree rather than as an unmeasurable diff, so a correction inside it prices by the size ladder like any other change — no receipt moves a tier, and closed by the real stamp hook in both shapes while never-reviewed code riding along still refuses it, and the report a worktree run owes: no markers before its triage, a receipt after it, a bounded ask allowance counted one appended line per ask, the lookup scoped to the repository so another chat cannot answer for it, both review hooks keyed so exactly one fires, and that receipt carrying the confirmed-severity tally of the very verdicts it reported — recomputed from stored verdicts where a run was adjudicated the durable way, absent where nobody triaged it, and printed on the repository receipt the commit gate prices its next round on — taken from the stored verdicts wherever a run has them so a re-adjudication cannot be priced on superseded counts, scoped to the member a merged panel'"'"'s receipt belongs to so one repository never escalates on another'"'"'s defects, carried beside a second tally of that whole round so what the round earned is not split — and made cheaper — by the panel having read two repositories at once, and every receipt naming the change its own run read so a review of committed work can pay the commit that carries it, and answered as no tally at all rather than as an exception when the files behind it cannot be read, and that same receipt reachable by the paths a commit will carry — a search over the scoped receipts alone, answering with the newest whose own scope lies inside those paths, tolerating a path the panel never saw as the drift its reader prices while a reviewed path outside them disqualifies, spelled through the one scope canonicalization, refusing to be asked alongside a named scope or a lens, and leaving the repository receipt'"'"'s own answer untouched, and a merged review of several repositories read by one panel out of a single workspace holding each repository under its own prefix — deterministic, self-contained once built and pruned with the run it belongs to — whose findings and adjudication handoff name the repository each belongs to, whose scopes and progress are per repository, and which stamps EVERY repository it read with that repository'"'"'s own receipt so none of their commit gates blocks on a review that covered it, while refusing a commitish, a repository named twice, a clean tree, a missing repository and its own workspace as a tree to seal, and a range of commits reviewed as one target — sealed into a single commit carrying its right end'"'"'s tree over its left end as the parent, so every reader keyed on one sha reads the whole range, named by the commits it sealed rather than by how the caller spelled them so one range is one snapshot with one rerun, announced by its own ends with the seal named beside them, read back out of that seal by a rerun carrying no flags at all, refused when it names no shape or no change, shown as a range while it runs, and kept out of the repository'"'"'s receipt wherever its right end is not the tree standing in front of the reader, and the corpus closed to every commit-point review — the plain record command refused outright with the reporting one named in its place, the refusal and the flag'"'"'s own help promising only what --bench delivers (this run'"'"'s verdicts stored, never a corpus row), that flag refused in turn on a durable run it would buy the plain command'"'"'s own behaviour on, and the handoff printing that one command alone — with the block those reviews are read in framed to a fixed width no over-long word can flatten, opened by a line naming the panel that produced it, and carrying a cell row that counts every completed cell under the same names its neighbouring rows use — the ones that found nothing included, and a count missing from an older summary costing its own cell a number rather than the whole block, every one of those names and the tiers table'"'"'s own rendered by one derivation over the pool of cells the tiers can launch — version digits, effort and the bare mark each appearing only where two pool cells would otherwise collide, Claude and Codex effort always spelled because it is a launch parameter, the word skill never rendered at all, a family gaining a second variant IN THE POOL renaming itself with no list to edit, a cell only a stored run holds named against that pool and never over it — the arrival carrying whatever separates it, its report leaving the tiers table byte for byte — and the machine specs commands are spelled in left untouched\n' "$asserts"
