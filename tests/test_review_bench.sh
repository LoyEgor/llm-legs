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
# A round whose fixing pass STOPPED at the P1 threshold wears the same frame with a louder word,
# and it is the only second word there is: both of them keep the shape the hooks find blocks by,
# and a report that stops matching it is one Egor never sees. A round merely still owing an answer
# keeps the plain word — the loud one read off "no fixes recorded" is what put NOT FINISHED in
# front of Egor over a round whose fixes were landing.
assert rb.REPORT_BLOCKED_BEGIN == "=" * 13 + " review · NOT FINISHED " + "=" * 14, \
    rb.REPORT_BLOCKED_BEGIN
frame_shape = re.compile(r"=+ review(?: · NOT FINISHED)? =+")
for frame_line in (rb.REPORT_BEGIN, rb.REPORT_BLOCKED_BEGIN):
    assert len(frame_line) == 50, frame_line
    assert frame_shape.fullmatch(frame_line), frame_line
    assert not re.fullmatch(r"={10,}", frame_line), frame_line
assert rb.REPORT_BEGIN != rb.REPORT_BLOCKED_BEGIN
# No third word exists to be framed in or delivered under: the module builds exactly these two.
assert sorted(
    name for name in vars(rb) if name.startswith("REPORT_") and name.endswith("_BEGIN")
) == ["REPORT_BEGIN", "REPORT_BLOCKED_BEGIN"], sorted(vars(rb))
assert rb.DELIVERY_STATES == ("done", "blocked"), rb.DELIVERY_STATES
rb.REPORT_BEGIN = "FIXTURE-REVIEW-REPORT-BEGIN"
rb.REPORT_BLOCKED_BEGIN = "FIXTURE-REVIEW-REPORT-BLOCKED-BEGIN"
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

# OpenCode rows outlive their stated reset: only a served completion retires them (the collector's
# question, not this file's), so compaction may collapse duplicates — newest detection, longest
# horizon, one row per account and window — but never drop the account by the clock.
oc_wall_state = work / "opencode-wall-state"
oc_wall_state.mkdir()
oc_path = oc_wall_state / rb.WALL_STATE_FILE
oc_filler = [
    {
        "side": "agy", "account": f"expired-{index}", "bucket": "agy-pro",
        "detected_at": time.time() - 7200,
    }
    for index in range(80)
]
oc_lapsed = {
    "side": "opencode", "account": "opencode-go-x", "bucket": "general",
    "detected_at": time.time() - 7200, "reset_at": time.time() - 3600, "window": "weekly",
}
oc_newer = {
    "side": "opencode", "account": "opencode-go-x", "bucket": "general",
    "detected_at": time.time() - 60, "reset_at": time.time() - 7200, "window": "weekly",
}
oc_path.write_text(
    "".join(json.dumps(row) + "\n" for row in oc_filler + [oc_lapsed, oc_newer])
)
assert oc_path.stat().st_size > rb.WALL_COMPACT_BYTES
assert rb.compact_walls(oc_path) is not None
oc_kept = [json.loads(line) for line in oc_path.read_text().splitlines()]
assert len(oc_kept) == 1, oc_kept
assert oc_kept[0]["account"] == "opencode-go-x"
assert oc_kept[0]["window"] == "weekly"
assert oc_kept[0]["detected_at"] == oc_newer["detected_at"]
assert oc_kept[0]["reset_at"] == oc_lapsed["reset_at"]

# The served stamp is a wall between two records, not a filter compaction may apply: merged across
# it, a refusal the plan already served past lends its week-long horizon to a detection recorded
# after that completion, and an account both readers had retired is walled again on every surface.
split_wall_state = work / "served-compaction-state"
(split_wall_state / "opencode-seen").mkdir(parents=True)
split_path = split_wall_state / rb.WALL_STATE_FILE
split_now = float(int(time.time()))
split_pre = {
    "side": "opencode", "account": "opencode-go-split", "bucket": "general",
    "detected_at": split_now - 7200, "reset_at": split_now + 6 * 86400, "window": "weekly",
}
split_post = {
    "side": "opencode", "account": "opencode-go-split", "bucket": "general",
    "detected_at": split_now - 60, "reset_at": split_now - 30, "window": "weekly",
}
split_path.write_text(
    "".join(json.dumps(row) + "\n" for row in oc_filler + [split_pre, split_post])
)
(split_wall_state / "opencode-seen" / "opencode-go-split").write_text(
    f"{int(split_now) - 3600}\n"
)
split_before = rb.read_wall_rows(split_path)
assert split_path.stat().st_size > rb.WALL_COMPACT_BYTES
assert rb.compact_walls(split_path) is not None
split_kept = [json.loads(line) for line in split_path.read_text().splitlines()
              if json.loads(line)["side"] == "opencode"]
assert len(split_kept) == 2, split_kept
assert sorted(row["reset_at"] for row in split_kept) == sorted(
    [split_pre["reset_at"], split_post["reset_at"]]
), split_kept
# Compaction is housekeeping: the answer the pool reads out of the file may not change with it.
assert rb.read_wall_rows(split_path) == split_before, split_before

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

# One record, two readers. llm-limits.sh retires an OpenCode wall the moment the plan serves a
# completion after it, and the pool answering that question a second way is a whole leg refused
# for a day on an account the menubar shows clean (2026-08-15, opencode-go-dioqktn: a grok-4.5
# model wall recorded while the same plan kept completing on its other models).
served_state = work / "served-wall-state"
(served_state / "opencode-seen").mkdir(parents=True)
# Whole seconds on both sides: the stamp file holds epoch seconds, and a fractional wall row
# beside it can never tie with one.
served_now = float(int(time.time()))
served_account = "opencode-go-dioqktn"
served_key = ("opencode", served_account, "general")


def write_served_walls(detected_at):
    (served_state / rb.WALL_STATE_FILE).write_text(
        json.dumps({"side": "opencode", "account": served_account, "bucket": "general",
                    "detected_at": detected_at, "reset_at": detected_at + 86400,
                    "window": "weekly"}) + "\n"
        + json.dumps({"side": "agy", "account": served_account, "bucket": "agy-pro",
                      "detected_at": detected_at, "reset_at": detected_at + 86400}) + "\n"
    )


def write_served_stamp(text):
    stamp = served_state / "opencode-seen" / served_account
    if text is None:
        stamp.unlink(missing_ok=True)
    else:
        stamp.write_text(f"{text}\n")


os.environ["WORKER_STATS_DIR"] = str(served_state)
try:
    write_served_walls(served_now - 3600)
    # No stamp at all is no evidence of a completion, and that is what keeps an account nobody has
    # ever served out of the pool rather than walking it back in on a missing file.
    write_served_stamp(None)
    assert rb.is_walled("opencode", served_account)
    assert rb.walled_accounts("opencode") == {served_account}
    # Digits only, as llm-limits.sh strips the same file: a garbled stamp must not read as a serve.
    write_served_stamp("not-a-time")
    assert rb.is_walled("opencode", served_account)
    # A completion served after the refusal retires it, whatever horizon the row itself named.
    write_served_stamp(int(served_now) - 1800)
    assert not rb.is_walled("opencode", served_account)
    assert rb.walled_accounts("opencode") == set()
    assert served_key not in rb.read_wall_rows(served_state / rb.WALL_STATE_FILE)
    # A tie goes to the wall: read as served, an account that refused in the same second it last
    # completed would never be probed again and would freeze clean forever.
    write_served_walls(served_now - 1800)
    assert rb.is_walled("opencode", served_account)
    assert rb.walled_accounts("opencode") == {served_account}
    # The rows are dropped before the windows are aggregated, or a stale long-horizon row would
    # outrank the 429 recorded after the completion and answer for the account anyway.
    (served_state / rb.WALL_STATE_FILE).write_text(
        json.dumps({"side": "opencode", "account": served_account, "bucket": "general",
                    "detected_at": served_now - 7200, "reset_at": served_now + 7 * 86400,
                    "window": "weekly"}) + "\n"
    )
    write_served_stamp(int(served_now) - 3600)
    assert not rb.is_walled("opencode", served_account)
    # This evidence exists for OpenCode alone: a served stamp says nothing about the same name's
    # Antigravity quota, which is refused and billed somewhere else entirely.
    write_served_walls(served_now - 3600)
    write_served_stamp(int(served_now))
    assert rb.is_walled("agy", served_account, "agy-pro")
    assert rb.walled_accounts("agy", "agy-pro") == {served_account}
    assert not rb.is_walled("opencode", served_account)
finally:
    del os.environ["WORKER_STATS_DIR"]

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
# The cap belongs to the window the provider named: a flat week turns a monthly wall into a date
# that passes while the account is still walled, and stretches a 5-hour one over six days.
assert rb.clamped_reset_at(1000.0, 1000.0 + 19 * 86400, "monthly") == 1000.0 + 19 * 86400
assert rb.clamped_reset_at(1000.0, 1000.0 + 99 * 86400, "monthly") == 1000.0 + 32 * 86400
assert rb.clamped_reset_at(1000.0, 1000.0 + 99 * 86400, "weekly") == 1000.0 + 8 * 86400
assert rb.clamped_reset_at(1000.0, 1000.0 + 99 * 86400, "5-hour") == 1000.0 + 6 * 3600
assert rb.clamped_reset_at(1000.0, 1000.0 + 99 * 86400, "plan") == 1000.0 + rb.WALL_MAX_TTL_S
# The ceiling is applied once, where the record is written. A reader applying it again shortens a
# wall recorded under a window ceiling the row no longer names, back into a date it outlives.
unclamped_state = work / "unclamped-wall-state"
unclamped_state.mkdir()
unclamped_path = unclamped_state / rb.WALL_STATE_FILE
far_reset = time.time() + 20 * 86400
unclamped_path.write_text(json.dumps({
    "side": "opencode", "account": "opencode-go-far", "bucket": "general",
    "detected_at": time.time(), "reset_at": far_reset,
}) + "\n")
assert rb.read_wall_rows(unclamped_path)[
    ("opencode", "opencode-go-far", "general")
][1] == far_reset, "the reader re-clamped a recorded horizon"
assert rb.recorded_reset_at("not a time") is None
assert rb.recorded_reset_at(float("inf")) is None
# The record schema lives once: both writers build their rows from the field list the menubar
# reader is pinned against, and an absent optional field is absent rather than null.
assert tuple(rb.wall_record(
    side="opencode", account="a", bucket="general", detected_at=1.0,
    reset_at=2.0, window="weekly",
)) == rb.WALL_RECORD_FIELDS
assert rb.wall_record(side="opencode", account="a", bucket="general", detected_at=1.0) == {
    "side": "opencode", "account": "a", "bucket": "general", "detected_at": 1.0,
}

monthly_wall_state = work / "monthly-wall-state"
monthly_wall_state.mkdir()
os.environ["WORKER_STATS_DIR"] = str(monthly_wall_state)
monthly_reset = time.time() + 19 * 86400
rb.mark_walled("opencode", "opencode-go-far", reset_at=monthly_reset, window="monthly")
rb.mark_walled("agy", "work", "agy-pro", reset_at=monthly_reset)
monthly_row, windowless_row = [
    json.loads(line)
    for line in (monthly_wall_state / rb.WALL_STATE_FILE).read_text().splitlines()
]
del os.environ["WORKER_STATS_DIR"]
assert monthly_row["reset_at"] == monthly_reset, monthly_row
# A wall with no window keeps the flat cap exactly as it was, whichever side recorded it.
assert windowless_row["reset_at"] == windowless_row["detected_at"] + rb.WALL_MAX_TTL_S, \
    windowless_row
reread = rb.read_wall_rows(monthly_wall_state / rb.WALL_STATE_FILE)
assert reread[("opencode", "opencode-go-far", "general")][1] == monthly_reset, reread
assert rb.wall_reset_at("Weekly usage limit reached. Resets in 3 days.") > time.time() + 2 * 86400
assert rb.wall_reset_at("Resets in 45 minutes") < time.time() + 3600
assert rb.wall_reset_at("HTTP 429 rate limited") is None
# The wordings the gateway actually sends, recorded off real 429 bodies. Most of them abbreviate
# and compound the units, and reading only the first component of "9hr 30min" — or only the
# spelled-out spellings — left the majority of real refusals with no horizon at all.
for body, seconds in [
    ("Weekly usage limit reached. Resets in 9hr 30min. To continue using this model now, x", 34200),
    ("5-hour usage limit reached. Resets in 3hr 28min. x", 12480),
    ("5-hour usage limit reached. Resets in 3min. x", 180),
    ("Weekly usage limit reached. Resets in 42min. x", 2520),
    ("Weekly usage limit reached. Resets in 1 day. x", 86400),
    ("Weekly usage limit reached. Resets in 4 days. x", 345600),
    ("Monthly usage limit reached. Resets in 20 days. x", 1728000),
    ("Weekly usage limit reached. Resets in 1 hour. x", 3600),
]:
    stated = rb.wall_reset_at(body) - time.time()
    assert abs(stated - seconds) < 5, (body, stated, seconds)

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
    ("agy", "late", "agy-pro"): (late_wall["detected_at"], None, None)
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
assert rb.short_cell_name(rb.parse_rater("opus-medium")) == "opus-med-bare"
assert rb.short_cell_name(rb.parse_rater("sonnet-xhigh")) == "sonnet-xhigh"
# Claude joined the skill axis when the 2026-08-08 refit put opus-low-skill and opus-medium-skill
# in the tiers, so every opus cell now carries the mark — including opus-high, whose own skilled
# twin no tier launches. The mark is read off the family, not off the one effort.
assert rb.short_cell_name(rb.parse_rater("opus-low-skill")) == "opus-low"
assert rb.short_cell_name(rb.parse_rater("opus-high")) == "opus-high-bare"
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
    "gem-flash37-high", "gem-flash37-med",
    "gem-pro", "grok", "kimi", "opus-high-bare", "opus-low", "opus-low-bare", "opus-med",
    "opus-med-bare", "sol-high", "sol-high-bare", "sol-low", "sol-low-bare", "sol-max",
    "sol-max-bare", "sol-med-bare", "sol-xhigh", "sol-xhigh-bare",
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
# The standalone xAI cell a stored run still holds, beside the pool's own grok: the retired
# spelling no longer parses at all, and it must still name itself without respelling the pool cell.
xai_scheme = rb.report_name_scheme(["oc-grok45-low", "grok-low"])
assert rb.human_cell_name("oc-grok45-low", xai_scheme) == "grok"
assert rb.human_cell_name("grok-low", xai_scheme) == "grok-low"
# Same on the skill axis: opus-high-skill is in no tier, so a report holding it beside the pool's
# opus-high may not respell that pool cell. The arrival takes the unmarked name because the pool
# already spells every opus cell against the skill axis, and the bare one keeps its `-bare`.
skilled_opus_scheme = rb.report_name_scheme(["opus-high", "opus-high-skill"])
assert rb.human_cell_name("opus-high", skilled_opus_scheme) == "opus-high-bare"
assert rb.human_cell_name("opus-high-skill", skilled_opus_scheme) == "opus-high"
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
    {"rater": spec, "side": rb.rater_side(spec) or "grok", "duration_ms": 1000,
     "findings": 0, "exit_code": 0}
    for spec in ("grok-low", "opus-high-skill", "oc-grok45-low", "opus-high")
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
assert "opus-high 0" in newcomer_cells and "opus-high-bare 0" in newcomer_cells, newcomer_cells
assert rendered_tiers_table() == tiers_table_before
# The confirmed/found form keys on the triage having HAPPENED, not on anything surviving it: a run
# whose findings were all rejected must read 0/2, which is the opposite of an untriaged 2.
rejected_dir = work / "rejected-triage-report"
rejected_dir.mkdir()
(rejected_dir / "verdicts.jsonl").write_text("".join(
    json.dumps({"rater": "sol-high", "idx": idx, "verdict": "false_positive"}) + "\n"
    for idx in range(2)
))
rejected_report = rb.report_lines(rejected_dir, {
    "run_id": "rejected", "raters": ["sol-high"],
    "rater_runs": [{"rater": "sol-high", "side": "codex", "duration_ms": 1000,
                    "findings": 2, "exit_code": 0}],
    "started": "2026-07-30T00:00:00+00:00", "finished": "2026-07-30T00:00:01+00:00",
})
rejected_cells = [line for line in rejected_report if line.startswith("cells:")][0]
assert "sol-high 0/2" in rejected_cells, rejected_cells
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
# The watchdog's cap is per (model, effort) and applies to every panel: the longest that pair has
# ever completed in, plus room for a slow run of the same shape, never under the floor.
assert rb.WATCHDOG_GRACE_S == 180 and rb.WATCHDOG_FLOOR_S == 900
assert rb.watchdog_timeout_seconds(None) == 900
assert rb.watchdog_timeout_seconds(100_000) == 900
assert rb.watchdog_timeout_seconds(1_000_000) == 1180
# Rounded up, so a pair measured a hair over the floor still buys its whole grace.
assert rb.watchdog_timeout_seconds(720_001) == 901
watchdog_history = work / "watchdog-history"
for run_id, rows in {
    "one": [
        {"rater": "agy-flash36-medium-skill", "model": "agy-flash36", "effort": "medium",
         "side": "agy", "duration_ms": 200_000, "findings": 0, "exit_code": 0},
        {"rater": "agy-flash36-low-skill", "model": "agy-flash36", "effort": "low",
         "side": "agy", "duration_ms": 35_000, "findings": 2, "exit_code": 0},
    ],
    "two": [
        # A second spelling of one (model, effort) pair: the repeat suffix is not a cell of its own,
        # and keyed on the spec it would start from the floor again.
        {"rater": "agy-flash36-medium-skill#2", "model": "agy-flash36", "effort": "medium",
         "side": "agy", "duration_ms": 254_715, "findings": 1, "exit_code": 0},
        {"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
         "duration_ms": 1_200_000, "findings": 0, "exit_code": 0},
        # Neither a kill nor an errored cell says how long the work takes.
        {"rater": "agy-flash36-low-skill#2", "model": "agy-flash36", "effort": "low",
         "side": "agy", "duration_ms": 3_000_000, "timeout_s": 900, "findings": 0,
         "exit_code": 124, "errored": True, "stderr": "rater timed out after 900s"},
        {"rater": "opus-high", "model": "opus", "effort": "high", "side": "claude",
         "duration_ms": 2_000_000, "findings": 0, "exit_code": 0, "errored": True},
    ],
}.items():
    directory = watchdog_history / run_id
    directory.mkdir(parents=True)
    (directory / "meta.json").write_text(json.dumps({"rater_runs": rows}))
watchdog_maxima = rb.panel_duration_maxima(watchdog_history)
assert watchdog_maxima == {
    ("agy-flash36", "medium"): 254_715,
    ("agy-flash36", "low"): 35_000,
    ("sol", "high"): 1_200_000,
}, watchdog_maxima
watchdog_caps = rb.panel_watchdog_timeouts(watchdog_history)
assert watchdog_caps[("agy-flash36", "medium")] == 900, watchdog_caps
# A pair the watchdog has already killed gets one grace more than the cap it breached: a cell whose
# real runtime is past its cap completes nothing, so nothing else could ever raise it and it would
# be killed at the same limit on every run it is ever given.
assert watchdog_caps[("agy-flash36", "low")] == 1080, watchdog_caps
assert watchdog_caps[("sol", "high")] == 1380, watchdog_caps
assert ("opus", "high") not in watchdog_caps, watchdog_caps
# An agy cell is killed by the `--print-timeout` the watchdog handed geminib, which expires before
# any deadline of the tool's own and exits 1 with a timeout of its own wording. Read on exit 124
# alone that side records no breach at all and is killed at the floor on every run it ever gets.
agy_kill_history = work / "watchdog-agy-history"
(agy_kill_history / "one").mkdir(parents=True)
(agy_kill_history / "one" / "meta.json").write_text(json.dumps({"rater_runs": [
    {"rater": "agy-pro-high-skill", "model": "agy-pro", "effort": "high", "side": "agy",
     "duration_ms": 908_000, "timeout_s": 900, "findings": 0, "exit_code": 1,
     "errored": True, "stderr": "Error: timeout waiting for response"},
]}))
assert rb.panel_watchdog_timeouts(agy_kill_history) == {("agy-pro", "high"): 1080}, \
    rb.panel_watchdog_timeouts(agy_kill_history)
# A provider answering `gateway timeout` is an ordinary failed cell: it says nothing about the cap,
# so it neither raises one nor invents a pair that never ran under the watchdog.
gateway_history = work / "watchdog-gateway-history"
(gateway_history / "one").mkdir(parents=True)
(gateway_history / "one" / "meta.json").write_text(json.dumps({"rater_runs": [
    {"rater": "oc-kimik3", "model": "oc-kimik3", "effort": "", "side": "opencode",
     "duration_ms": 30_000, "timeout_s": 900, "findings": 0, "exit_code": 1,
     "errored": True, "stderr": "gateway timeout"},
]}))
assert rb.panel_watchdog_timeouts(gateway_history) == {}, rb.panel_watchdog_timeouts(gateway_history)

# Breach escalation is a probe with three strikes: only kills since the pair's last completion
# count, and the third in a row returns the pair to the cap its completions earn. Left unbounded,
# a genuinely dead cell bought one grace more on every run — 909→1087→1267→1447→1628s in one
# night — and every panel's wall walked with it (2026-08-16).
ratchet_history = work / "watchdog-ratchet-history"
def ratchet_run(run_id, *, kill_at=None, completed_ms=None):
    directory = ratchet_history / run_id
    directory.mkdir(parents=True)
    if kill_at is not None:
        row = {"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
               "duration_ms": kill_at * 1000 + 8_000, "timeout_s": kill_at, "findings": 0,
               "exit_code": 124, "errored": True,
               "stderr": f"rater timed out after {kill_at}s"}
    else:
        row = {"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
               "duration_ms": completed_ms, "findings": 0, "exit_code": 0}
    (directory / "meta.json").write_text(json.dumps({"rater_runs": [row]}))
ratchet_pair = ("sol", "high")
ratchet_run("20260101T000100Z-aaa", completed_ms=572_000)
ratchet_run("20260101T000200Z-bbb", kill_at=900)
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 1080, \
    rb.panel_watchdog_timeouts(ratchet_history)
ratchet_run("20260101T000300Z-ccc", kill_at=1080)
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 1260, \
    rb.panel_watchdog_timeouts(ratchet_history)
ratchet_run("20260101T000400Z-ddd", kill_at=1260)
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 900, \
    rb.panel_watchdog_timeouts(ratchet_history)
# A completion clears the kill record entirely — the 1260s breach behind it is no longer evidence,
# and the next kill starts a fresh probe rather than resuming the old climb.
ratchet_run("20260101T000500Z-eee", completed_ms=572_000)
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 900, \
    rb.panel_watchdog_timeouts(ratchet_history)
ratchet_run("20260101T000600Z-fff", kill_at=900)
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 1080, \
    rb.panel_watchdog_timeouts(ratchet_history)
assert rb.panel_cell_history(ratchet_history)[4][ratchet_pair] == 1, \
    rb.panel_cell_history(ratchet_history)[4]
# Strikes count RUNS, not rows: a T2 panel holds three cells of one pair, and one bad run must
# cost one strike, not the whole probe.
(ratchet_history / "20260101T000700Z-ggg").mkdir(parents=True)
(ratchet_history / "20260101T000700Z-ggg" / "meta.json").write_text(json.dumps({"rater_runs": [
    {"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
     "duration_ms": 1_088_000, "timeout_s": 1080, "findings": 0, "exit_code": 124,
     "errored": True, "stderr": "rater timed out after 1080s"},
    {"rater": "sol-high-bare", "model": "sol", "effort": "high", "side": "codex",
     "duration_ms": 1_088_000, "timeout_s": 1080, "findings": 0, "exit_code": 124,
     "errored": True, "stderr": "rater timed out after 1080s"},
]}))
assert rb.panel_cell_history(ratchet_history)[4][ratchet_pair] == 2, \
    rb.panel_cell_history(ratchet_history)[4]
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 1260, \
    rb.panel_watchdog_timeouts(ratchet_history)
# A pair that completed in the same run it was killed in proved it works — the record clears —
# and the completion clears it even when its duration lives only in the legacy top-level map.
(ratchet_history / "20260101T000800Z-hhh").mkdir(parents=True)
(ratchet_history / "20260101T000800Z-hhh" / "meta.json").write_text(json.dumps({"rater_runs": [
    {"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
     "duration_ms": 1_268_000, "timeout_s": 1260, "findings": 0, "exit_code": 124,
     "errored": True, "stderr": "rater timed out after 1260s"},
    {"rater": "sol-high-bare", "model": "sol", "effort": "high", "side": "codex",
     "findings": 0, "exit_code": 0},
]}))
assert ratchet_pair not in rb.panel_cell_history(ratchet_history)[4], \
    rb.panel_cell_history(ratchet_history)[4]
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 900, \
    rb.panel_watchdog_timeouts(ratchet_history)
# The third strike ends the EPISODE, not the pair's right to probe: pinned instead, a pair with no
# completion on file could never earn the completion that clears the record, and stayed at the
# floor for ever. The cycle re-probes every third run at one grace per run on average.
ratchet_run("20260101T000900Z-iii", kill_at=900)
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 1080, \
    rb.panel_watchdog_timeouts(ratchet_history)
ratchet_run("20260101T001000Z-jjj", kill_at=1080)
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 1260, \
    rb.panel_watchdog_timeouts(ratchet_history)
ratchet_run("20260101T001100Z-kkk", kill_at=1260)
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 900, \
    rb.panel_watchdog_timeouts(ratchet_history)
assert ratchet_pair not in rb.panel_cell_history(ratchet_history)[4], \
    rb.panel_cell_history(ratchet_history)[4]
ratchet_run("20260101T001200Z-lll", kill_at=900)
assert rb.panel_watchdog_timeouts(ratchet_history)[ratchet_pair] == 1080, \
    rb.panel_watchdog_timeouts(ratchet_history)

# The stall cap under the duration cap is earned per (model, effort) pair: the longest silent gap
# its completions ever showed, plus grace over a floor — and only where those gaps stay well under
# the pair's runtimes, which is the evidence it streams at all. A buffered pair that is quiet the
# way it always is gets no cap, and neither does one with no gap history.
stall_history = work / "stall-history"
(stall_history / "one").mkdir(parents=True)
(stall_history / "one" / "meta.json").write_text(json.dumps({"rater_runs": [
    {"rater": "agy-flash36-medium-skill", "model": "agy-flash36", "effort": "medium",
     "side": "agy", "duration_ms": 300_000, "max_quiet_ms": 40_000, "findings": 0,
     "exit_code": 0},
    {"rater": "agy-pro-high-skill", "model": "agy-pro", "effort": "high", "side": "agy",
     "duration_ms": 600_000, "max_quiet_ms": 200_000, "findings": 0, "exit_code": 0},
    {"rater": "opus-high", "model": "opus", "effort": "high", "side": "claude",
     "duration_ms": 300_000, "max_quiet_ms": 290_000, "findings": 0, "exit_code": 0},
    {"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
     "duration_ms": 300_000, "findings": 0, "exit_code": 0},
    # An errored cell's gap is not streaming evidence: it may have died mid-handshake, and a cap
    # earned from it would kill healthy cells of a pair whose completions never showed one.
    {"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
     "duration_ms": 90_000, "max_quiet_ms": 30_000, "findings": 0, "exit_code": 1,
     "errored": True, "stderr": "boom"},
]}))
assert rb.STALL_FLOOR_S == 240 and rb.STALL_GRACE_S == 120
stall_caps = rb.panel_stall_timeouts(stall_history)
assert stall_caps == {
    ("agy-flash36", "medium"): 240,
    ("agy-pro", "high"): 320,
}, stall_caps
# A stall kill is the only evidence a pair whose real silences are past its cap ever produces, so
# the next run gives it one grace more — and it is NOT a duration breach: sharing the watchdog's
# exit code, it must neither raise the pair's duration cap nor feed the agy kill reading.
(stall_history / "two").mkdir(parents=True)
(stall_history / "two" / "meta.json").write_text(json.dumps({"rater_runs": [
    {"rater": "agy-flash36-medium-skill", "model": "agy-flash36", "effort": "medium",
     "side": "agy", "duration_ms": 245_000, "timeout_s": 900, "stalled_s": 240,
     "findings": 0, "exit_code": 124, "errored": True,
     "stderr": "rater stalled: no output activity for 241s (stall cap 240s)"},
]}))
assert rb.panel_stall_timeouts(stall_history)[("agy-flash36", "medium")] == 360, \
    rb.panel_stall_timeouts(stall_history)
assert rb.panel_watchdog_timeouts(stall_history)[("agy-flash36", "medium")] == 900, \
    rb.panel_watchdog_timeouts(stall_history)
assert not rb.watchdog_killed({
    "model": "agy-flash36", "effort": "medium", "side": "agy", "stalled_s": 240,
    "exit_code": 124, "stderr": "rater stalled: no output activity for 241s (stall cap 240s)",
})
# A kill whose retry then COMPLETED leaves its trace on the completed row: the kill still
# escalates the stall cap, while the row itself stays a completion — its duration feeds the
# duration cap and its gap the stall evidence, and no duration breach is read into it.
(stall_history / "three").mkdir(parents=True)
(stall_history / "three" / "meta.json").write_text(json.dumps({"rater_runs": [
    {"rater": "agy-flash36-medium-skill", "model": "agy-flash36", "effort": "medium",
     "side": "agy", "duration_ms": 908_000, "max_quiet_ms": 40_000, "stalled_retry_s": 355,
     "findings": 1, "exit_code": 0},
]}))
assert rb.panel_stall_timeouts(stall_history)[("agy-flash36", "medium")] == 475, \
    rb.panel_stall_timeouts(stall_history)
assert rb.panel_watchdog_timeouts(stall_history)[("agy-flash36", "medium")] == 1088, \
    rb.panel_watchdog_timeouts(stall_history)
# The report tells a silent cell from a slow one: the reader deciding whether to trust the panel
# needs the difference.
assert rb.cell_failure_reason({"status": "timed_out", "stalled_s": 240, "stderr": ""}) == "stalled"
assert rb.failure_reason("rater stalled: no output activity for 241s") == "stalled"

# A cell that has failed every run for days is not the same news as one that failed today, and the
# report is the only place that difference is visible. Counted over the runs that HELD the cell:
# a panel it was never part of is no evidence it recovered there.
streak_history = work / "streak-history"
streak_runs = {
    "20260101T000100Z-aaa": [("agy-flash35-medium-skill", 0), ("opus-medium", 0)],
    "20260101T000200Z-bbb": [("agy-flash35-medium-skill", 1)],
    "20260101T000300Z-ccc": [("sol-high", 0)],
    "20260101T000400Z-ddd": [("agy-flash35-medium-skill", 1), ("opus-medium", 1)],
}
for streak_id, streak_rows in streak_runs.items():
    (streak_history / streak_id).mkdir(parents=True)
    (streak_history / streak_id / "meta.json").write_text(json.dumps({"rater_runs": [
        {"rater": rater, "duration_ms": 1000, "findings": 0, "exit_code": code,
         "errored": bool(code), "stderr": "boom" if code else ""}
        for rater, code in streak_rows
    ]}))
streaks = rb.cell_failure_streaks(
    streak_history, "20260101T000500Z-eee",
    ["agy-flash35-medium-skill", "opus-medium", "sol-high"],
)
assert streaks == {
    "agy-flash35-medium-skill": 3, "opus-medium": 2, "sol-high": 1,
}, streaks
# Only runs BEFORE this one count, and a store with no history at all answers with this run alone.
assert rb.cell_failure_streaks(
    streak_history, "20260101T000000Z-zzz", ["agy-flash35-medium-skill"],
) == {"agy-flash35-medium-skill": 1}
assert rb.cell_failure_streaks(work / "no-such-benches", "x", ["sol-high"]) == {}
assert rb.CHRONIC_FAILURE_STREAK == 3
# A cell with no completion anywhere never breaks the walk, so the walk is windowed: a report must
# not read a months-long history to price one chronic cell, and a streak past the window reads as
# the window (plus this run).
chronic_history = work / "chronic-streak-history"
for index in range(rb.CHRONIC_STREAK_WALK_RUNS + 5):
    directory = chronic_history / f"20260101T{index:04d}00Z-run"
    directory.mkdir(parents=True)
    (directory / "meta.json").write_text(json.dumps({"rater_runs": [
        {"rater": "sol-high", "duration_ms": 1000, "findings": 0, "exit_code": 1,
         "errored": True, "stderr": "boom"}
    ]}))
assert rb.cell_failure_streaks(
    chronic_history, "20260102T000000Z-next", ["sol-high"],
) == {"sol-high": rb.CHRONIC_STREAK_WALK_RUNS + 1}

# run_streamed: any byte on stdout or stderr, and any growth of a watch path, counts as life. A
# cell silent past its stall cap is killed — its whole process group, since the hang lives in the
# launcher's descendant — and raised as stalled; the duration cap keeps subprocess.run's contract.
streamer = work / "streamer.sh"
streamer.write_text("#!/bin/bash\necho first\nsleep 0.7\necho second\n")
streamer.chmod(0o755)
streamed = rb.run_streamed([str(streamer)], timeout_s=30, stall_s=20)
assert streamed.returncode == 0 and streamed.stdout == "first\nsecond\n", streamed
# The gap between the two writes must be visible in the recorded maximum; the bound is loose
# because quiet is sampled on poll ticks.
assert streamed.max_quiet_ms >= 200, streamed.max_quiet_ms

hanger = work / "hanger.sh"
hanger_child = work / "hanger-child"
hanger.write_text(
    "#!/bin/bash\necho started\nsleep 600 &\necho $! >" + str(hanger_child) + "\nwait\n"
)
hanger.chmod(0o755)
stall_poll_was = rb.STALL_POLL_S
rb.STALL_POLL_S = 0.05
try:
    stall_started_at = time.monotonic()
    try:
        rb.run_streamed([str(hanger)], timeout_s=30, stall_s=1)
    except rb.RaterStalled as exc:
        assert exc.quiet_s >= 1 and exc.stall_s == 1, exc
        assert exc.stdout == "started\n", exc.stdout
    else:
        raise AssertionError("a silent cell was not killed at its stall cap")
    assert time.monotonic() - stall_started_at < 10
    hanger_pid = int(hanger_child.read_text().strip())
    hanger_deadline = time.monotonic() + 5
    while time.monotonic() < hanger_deadline:
        try:
            os.kill(hanger_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        raise AssertionError("the stalled cell's descendant survived the group kill")

    watched_log = work / "watched.log"
    filewriter = work / "filewriter.sh"
    filewriter.write_text(
        "#!/bin/bash\nfor i in 1 2 3 4; do echo tick >>" + str(watched_log)
        + "; sleep 0.3; done\n"
    )
    filewriter.chmod(0o755)
    quiet_stdout = rb.run_streamed(
        [str(filewriter)], timeout_s=30, stall_s=1, watch_paths=[watched_log]
    )
    assert quiet_stdout.returncode == 0, quiet_stdout

    try:
        rb.run_streamed([str(hanger)], timeout_s=1, stall_s=None)
    except subprocess.TimeoutExpired as exc:
        assert "started" in (exc.output or ""), exc.output
        # The silence a killed cell died in is recorded nowhere else: the row it leaves is an
        # errored one, and only the exception carries what the watch measured before the kill.
        assert exc.max_quiet_ms >= 500, exc.max_quiet_ms
        killed_rater = {"spec": "agy-flash35-medium-skill"}
        rb.rater_timeout(exc, killed_rater, time.monotonic(), 900, ["fixture"])
        assert killed_rater["killed"] == "watchdog", killed_rater
        assert killed_rater["killed_cap_s"] == 900, killed_rater
        assert killed_rater["max_quiet_ms"] == exc.max_quiet_ms, killed_rater
    else:
        raise AssertionError("the duration cap did not fire without a stall cap")

    # A stall kill records its own cap and the gap it fired on, so the report can say the cell was
    # silent rather than slow without re-parsing the stderr sentence.
    stalled_rater = {"spec": "agy-pro-high-skill"}
    rb.rater_stalled(
        rb.RaterStalled(360, 240, "", ""), stalled_rater, time.monotonic(), ["fixture"]
    )
    assert stalled_rater["killed"] == "stall", stalled_rater
    assert stalled_rater["killed_cap_s"] == 240 and stalled_rater["stalled_s"] == 240
    assert stalled_rater["max_quiet_ms"] == 360_000, stalled_rater
    # A cell that ended itself claims neither key, which is the whole difference the report reads.
    assert rb.cell_kill_note({"exit_code": 1, "stderr": "Error: timeout waiting for response"}) \
        is None
    assert rb.cell_kill_note({"killed": "watchdog", "killed_cap_s": 1020}) \
        == "watchdog cap 17 min"
    assert rb.cell_kill_note({"killed": "stall", "killed_cap_s": 240,
                              "max_quiet_ms": 360_000}) == "stalled, quiet 6 min"
    # A stall kill recorded before `killed` existed is marked by `stalled_s` alone.
    assert rb.cell_kill_note({"stalled_s": 240}) == "stalled, cap 4 min"
    # A watchdog kill recorded before `killed` existed is marked by its shape, and the cap that
    # operated is the row's own `timeout_s` — while a provider's `gateway timeout` names no cap.
    assert rb.cell_kill_note({"exit_code": 124, "timeout_s": 1020, "side": "codex",
                              "stderr": "rater timed out after 1020s"}) == "watchdog cap 17 min"
    assert rb.cell_kill_note({"exit_code": 1, "timeout_s": 900, "side": "opencode",
                              "stderr": "gateway timeout"}) is None

    # The tail a dying cell flushes must reach the exception whole: taken mid-pump, the
    # transcript is cut exactly where the kill's own evidence would be. The marker comes from a
    # TERM-immune descendant that writes only AFTER the visible child is reaped — exactly when a
    # drain that does not wait for the pumps has already taken its snapshot.
    trapper = work / "trapper.sh"
    trapper.write_text(
        "#!/bin/bash\n"
        "( trap '' TERM\n"
        "  while kill -0 $$ 2>/dev/null; do sleep 0.05; done\n"
        "  echo dying-words ) &\n"
        "echo started\n"
        "while :; do sleep 0.05; done\n"
    )
    trapper.chmod(0o755)
    try:
        rb.run_streamed([str(trapper)], timeout_s=30, stall_s=1)
    except rb.RaterStalled as exc:
        assert "dying-words" in exc.stdout, exc.stdout
    else:
        raise AssertionError("the trapping cell was not stall-killed")

    # start_new_session detaches the cell from the terminal's group, so an interrupt no longer
    # reaches it by itself: run_streamed must kill the group on its way out, or an interrupted
    # review leaves every rater CLI running detached on Egor's quota.
    assert not rb.LIVE_CELL_GROUPS, rb.LIVE_CELL_GROUPS
    interrupt_sleep = time.sleep

    def interrupting_sleep(seconds):
        # Only once the descendant's pid is on disk, so the assertion below has a pid to watch.
        if seconds == rb.STALL_POLL_S and hanger_child.exists() \
                and hanger_child.read_text().strip():
            raise KeyboardInterrupt
        interrupt_sleep(seconds)

    hanger_child.unlink()
    time.sleep = interrupting_sleep
    try:
        try:
            rb.run_streamed([str(hanger)], timeout_s=30, stall_s=None)
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("the interrupt did not surface out of run_streamed")
    finally:
        time.sleep = interrupt_sleep
    assert not rb.LIVE_CELL_GROUPS, rb.LIVE_CELL_GROUPS
    interrupted_pid = int(hanger_child.read_text().strip())
    interrupted_deadline = time.monotonic() + 5
    while time.monotonic() < interrupted_deadline:
        try:
            os.kill(interrupted_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        raise AssertionError("an interrupted cell's descendant survived")

    # The reaper is the same promise at process death: whatever group is still registered when
    # review-bench itself dies is killed, not orphaned.
    # DEVNULL stdio, or an unreaped probe holds this suite's own output pipe open and turns a
    # failed assertion into a hang.
    probe = subprocess.Popen(["sleep", "600"], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rb.LIVE_CELL_GROUPS.add(probe.pid)
    try:
        rb.reap_live_groups()
        assert probe.wait(timeout=5) == -15, probe.returncode
    finally:
        if probe.poll() is None:
            probe.kill()
        rb.LIVE_CELL_GROUPS.discard(probe.pid)
finally:
    rb.STALL_POLL_S = stall_poll_was
assert rb.panel_cell_key({"model": "sol", "effort": "high"}) == ("sol", "high")
assert rb.panel_cell_key({"model": "oc-glm52", "effort": ""}) == ("oc-glm52", "")
assert rb.panel_cell_key({"effort": "high"}) is None
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
# the errored one below it would otherwise be matching slugs against model names by hand. Ordered
# by usefulness, which for a panel that all found nothing is the name.
assert max_tier_cells[0].split(":", 1)[1].strip() == " · ".join(
    f"{name} 0"
    for name in sorted(rb.human_cell_name(row["rater"]) for row in max_tier_rows)
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
assert legacy_cells_row[0].split(":", 1)[1].strip() == "opus-med-bare 0", legacy_cells_row[0]
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
# `record --no-corpus` leaves only the receipt behind, and its rows are the triage's one copy:
# a re-render of the run — the report hook recovering a capture whose closing rule the
# tool-output window cut — must produce the frame from them, never answer "pending".
rb.write_report_receipt(max_tier_dir, [
    {"rater": "opus-high", "idx": 0, "verdict": "confirmed"},
    {"rater": "opus-high", "idx": 1, "verdict": "duplicate"},
])
receipt_report = io.StringIO()
with contextlib.redirect_stdout(receipt_report):
    rb.emit_report(max_tier_dir, max_tier_meta)
receipt_lines = receipt_report.getvalue().splitlines()
# Framed in the PLAIN word: the receipt confirms a finding and nothing says it was fixed, which
# is a round still owing an answer — the model may read that block and no hook may deliver it.
assert receipt_lines[0] == rb.REPORT_BEGIN, receipt_lines
assert receipt_lines[-1] == rb.REPORT_END, receipt_lines
assert any(line.startswith("confirmed 1:") for line in receipt_lines), receipt_lines
assert any(line.startswith("fixes:") for line in receipt_lines), receipt_lines
# And age is no part of that answer: this fixture's triage is weeks behind the window a fixer
# could still be inside, and the same run stamped a second ago renders the same word. A round
# nobody answered for growing a louder frame with the clock is what re-delivered rounds Egor had
# already read, under a word their own receipt never said.
fresh_meta = dict(max_tier_meta, finished=rb.iso_now())
fresh_report = io.StringIO()
with contextlib.redirect_stdout(fresh_report):
    rb.emit_report(max_tier_dir, fresh_meta)
assert fresh_report.getvalue().splitlines()[0] == rb.REPORT_BEGIN, fresh_report.getvalue()
assert rb.round_state(max_tier_dir) == "pending"
# Named by no delivery line at either age: `pending` is the one state with no key of its own.
assert rb.delivery_state(max_tier_dir) is None
# Zero rows is a CLEAN triage, not a missing one: the clean review's re-render must frame too.
rb.write_report_receipt(max_tier_dir, [])
clean_receipt_report = io.StringIO()
with contextlib.redirect_stdout(clean_receipt_report):
    rb.emit_report(max_tier_dir, max_tier_meta)
clean_receipt_lines = clean_receipt_report.getvalue().splitlines()
assert clean_receipt_lines[0] == rb.REPORT_BEGIN, clean_receipt_lines
assert clean_receipt_lines[-1] == rb.REPORT_END, clean_receipt_lines
(max_tier_dir / rb.REPORT_RECEIPT).unlink()
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
wall_reset = time.time() + 2 * 86400
wall_label = "opencode alt: weekly wall, resets " + \
    rb.datetime.fromtimestamp(wall_reset).strftime("%a %H:%M")
pool_wall_meta = dict(
    duration_meta,
    raters=["oc-kimik3"],
    rater_runs=[{
        "rater": "oc-kimik3", "side": "opencode", "exit_code": 1, "errored": True,
        "stderr": "the pool has no opencode account left to run on\n" + wall_label,
    }],
)
pool_wall_report = "\n".join(rb.report_lines(duration_dir, pool_wall_meta))
assert "kimi (pool empty)" in pool_wall_report, pool_wall_report
assert any(
    line.startswith("walls:") and line.endswith(wall_label)
    for line in pool_wall_report.splitlines()
), pool_wall_report
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

# A value of several lines — the escalation fork is three arms — stays under the value column;
# flush left its later lines read as rows of their own whose label went missing.
wrapped_rows = rb.aligned_report_lines([("outcome:", "first\nsecond"), ("panel:", "one")])
assert wrapped_rows == ["outcome:  first", "          second", "panel:    one"], wrapped_rows

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
        "agy-flash35-medium-skill", "agy-flash35-high-skill",
        "agy-flash36-medium-skill", "agy-flash37-medium-skill", "agy-flash37-high-skill",
    ],
    "T1": [
        "agy-flash35-medium-skill", "agy-flash35-high-skill",
        "agy-flash36-medium-skill", "agy-flash36-high-skill x2",
        "agy-flash37-medium-skill", "agy-pro-high-skill",
    ],
}
expected_agy["T2"] = expected_agy["T1"]
expected_agy["T3"] = [
    "agy-flash35-medium-skill x2", "agy-flash35-high-skill",
    "agy-flash36-medium-skill", "agy-flash36-high-skill",
    "agy-flash37-medium-skill", "agy-pro-high-skill",
]
expected_agy_max = {
    "T0": expected_agy["T0"],
    "T1": [
        "agy-flash35-medium-skill x2", "agy-flash35-high-skill",
        "agy-flash36-medium-skill", "agy-flash36-high-skill x2",
        "agy-flash37-medium-skill", "agy-pro-high-skill",
    ],
    "T2": [
        "agy-flash35-medium-skill x2", "agy-flash35-high-skill",
        "agy-flash36-medium-skill x2", "agy-flash36-high-skill x2",
        "agy-flash37-medium-skill", "agy-pro-high-skill",
    ],
    "T3": [
        "agy-flash35-medium-skill x2", "agy-flash35-high-skill x2",
        "agy-flash36-medium-skill", "agy-flash36-high-skill",
        "agy-flash37-medium-skill", "agy-pro-high-skill",
    ],
}
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
        "opus-high", "opus-medium", "opus-low", "opus-low-skill", "sol-high",
        "sol-high-bare", "sol-max-bare",
    ],
}
expected_tier_max_cells = {
    "T0": expected_floor_max["T0"] + [
        "opus-low", "opus-low-skill", "sol-low", "sol-low-bare",
    ],
    "T1": expected_floor_max["T1"] + [
        "opus-low", "opus-low-skill", "opus-medium", "sol-low", "sol-low-bare",
        "sol-medium-bare",
    ],
    "T2": expected_floor_max["T2"] + [
        "opus-high", "opus-medium", "opus-low", "opus-low-skill", "sol-high",
        "sol-high-bare x2", "sol-xhigh", "sol-xhigh-bare",
    ],
    "T3": expected_floor_max["T3"] + [
        "opus-high", "opus-medium", "opus-medium-skill", "opus-low", "opus-low-skill",
        "sol-high", "sol-max x2", "sol-max-bare", "sol-xhigh-bare",
    ],
}
expected_coverage_pct = {
    "T0": {"eco": 40.5, "max": 46.3},
    "T1": {"eco": 47.9, "max": 55.6},
    "T2": {"eco": 58.2, "max": 67.3},
    "T3": {"eco": 70.1, "max": 78.5},
}
oc_counts = Counter({"oc-kimik3": 2, "oc-grok45-low": 2, "oc-dsv4flash": 2})
oc_counts_max = Counter({"oc-kimik3": 3, "oc-grok45-low": 3, "oc-dsv4flash": 3})
agy_counts = {
    "T0": Counter({
        "agy-flash35-high-skill": 1, "agy-flash35-medium-skill": 1,
        "agy-flash36-medium-skill": 1,
        "agy-flash37-medium-skill": 1, "agy-flash37-high-skill": 1,
    }),
    "T1": Counter({
        "agy-flash35-high-skill": 1, "agy-flash35-medium-skill": 1,
        "agy-flash36-high-skill": 2, "agy-flash36-medium-skill": 1,
        "agy-flash37-medium-skill": 1, "agy-pro-high-skill": 1,
    }),
    "T3": Counter({
        "agy-flash35-high-skill": 1, "agy-flash35-medium-skill": 2,
        "agy-flash36-high-skill": 1, "agy-flash36-medium-skill": 1,
        "agy-flash37-medium-skill": 1, "agy-pro-high-skill": 1,
    }),
}
agy_counts["T2"] = agy_counts["T1"]
agy_counts_max = {
    "T0": agy_counts["T0"],
    "T1": Counter({
        "agy-flash35-high-skill": 1, "agy-flash35-medium-skill": 2,
        "agy-flash36-high-skill": 2, "agy-flash36-medium-skill": 1,
        "agy-flash37-medium-skill": 1, "agy-pro-high-skill": 1,
    }),
    "T2": Counter({
        "agy-flash35-high-skill": 1, "agy-flash35-medium-skill": 2,
        "agy-flash36-high-skill": 2, "agy-flash36-medium-skill": 2,
        "agy-flash37-medium-skill": 1, "agy-pro-high-skill": 1,
    }),
    "T3": Counter({
        "agy-flash35-high-skill": 2, "agy-flash35-medium-skill": 2,
        "agy-flash36-high-skill": 1, "agy-flash36-medium-skill": 1,
        "agy-flash37-medium-skill": 1, "agy-pro-high-skill": 1,
    }),
}
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
        "opus-high": 1, "opus-medium": 1, "opus-low": 1, "opus-low-skill": 1,
        "sol-high": 1, "sol-high-bare": 1, "sol-max-bare": 1,
    }),
}
expected_tier_max_multisets = {
    "T0": oc_counts_max + agy_counts_max["T0"] + Counter({
        "opus-low": 1, "opus-low-skill": 1, "sol-low": 1, "sol-low-bare": 1,
    }),
    "T1": oc_counts_max + agy_counts_max["T1"] + Counter({
        "opus-low": 1, "opus-low-skill": 1, "opus-medium": 1, "sol-low": 1,
        "sol-low-bare": 1, "sol-medium-bare": 1,
    }),
    "T2": oc_counts_max + agy_counts_max["T2"] + Counter({
        "opus-high": 1, "opus-medium": 1, "opus-low": 1, "opus-low-skill": 1,
        "sol-high": 1, "sol-high-bare": 2, "sol-xhigh": 1, "sol-xhigh-bare": 1,
    }),
    "T3": oc_counts_max + agy_counts_max["T3"] + Counter({
        "opus-high": 1, "opus-medium": 1, "opus-medium-skill": 1, "opus-low": 1,
        "opus-low-skill": 1, "sol-high": 1, "sol-max": 2, "sol-max-bare": 1,
        "sol-xhigh-bare": 1,
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
assert [tier["budget_min"] for tier in rb.REVIEW_TIERS.values()] == [3, 6, 10, 20]
assert {
    tier_name: tier["cells"] for tier_name, tier in rb.REVIEW_TIERS.items()
} == expected_tier_cells
assert {
    tier_name: tier["cells_max"] for tier_name, tier in rb.REVIEW_TIERS.items()
} == expected_tier_max_cells
assert {
    tier_name: tier["coverage_pct"] for tier_name, tier in rb.REVIEW_TIERS.items()
} == expected_coverage_pct
# Both were broken until the 2026-08-08 Claude refit and neither is visible by reading one tier:
# T2 spent more Claude than T3, so the bigger diff bought less, and --max ran the same Claude
# panel as eco at T0, T2 and T3, so escalating bought nothing from the side that costs most.
def claude_multiset(cells):
    return Counter(
        rater["spec"].split("#")[0]
        for rater in rb.parse_raters(",".join(cells))
        if rater["side"] == "claude"
    )
for tier_name in rb.REVIEW_TIERS:
    eco = claude_multiset(rb.REVIEW_TIERS[tier_name]["cells"])
    ceiling = claude_multiset(rb.REVIEW_TIERS[tier_name]["cells_max"])
    assert not eco - ceiling, tier_name
    assert ceiling != eco, tier_name
    # The width the enumeration can staff at all, not one account per cell — the T3 ceiling
    # already doubles up on a four-profile pool and the preamble takes that trade on purpose.
    # Past ROSTER_MAX a panel is not trading spread for a cell, it is adding cells the roster
    # was never asked to reach.
    assert sum(ceiling.values()) <= rb.ROSTER_MAX, tier_name
# The bigger diff may never buy fewer Claude runs than the smaller one. Asserted as the count of
# Claude cells rather than through coverage_pct, which is a whole-panel figure recomputed by hand
# beside any tier edit: T2 outspent T3 for weeks with that figure green and monotonic.
claude_counts = [
    (sum(claude_multiset(tier["cells"]).values()),
     sum(claude_multiset(tier["cells_max"]).values()))
    for tier in rb.REVIEW_TIERS.values()
]
assert all(
    later[0] >= earlier[0] and later[1] >= earlier[1]
    for earlier, later in zip(claude_counts, claude_counts[1:])
), claude_counts
ladder = [tier["coverage_pct"] for tier in rb.REVIEW_TIERS.values()]
assert all(
    later["eco"] >= earlier["eco"] and later["max"] >= earlier["max"]
    for earlier, later in zip(ladder, ladder[1:])
), ladder
assert all(tier["max"] > tier["eco"] for tier in ladder), ladder
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
# The standalone grok account is gone for good, and with it the side: the spelling is refused by
# the grammar like any other unknown cell, with no bespoke message promising a return.
for standalone_grok_spec in ("grok-low", "grok-medium", "grok-high"):
    try:
        rb.parse_rater(standalone_grok_spec)
    except ValueError as exc:
        assert "invalid rater" in str(exc) and "standalone" not in str(exc), exc
    else:
        raise AssertionError(f"accepted a standalone grok rater: {standalone_grok_spec}")
rb.refuse_retired_cells([rb.parse_rater("oc-grok45-low")])
standalone_grok = subprocess.run(
    [sys.argv[1], "run", "HEAD", "--repo", str(repo), "--raters", "grok-low"],
    text=True,
    capture_output=True,
)
assert standalone_grok.returncode != 0, standalone_grok
assert "invalid rater 'grok-low'" in standalone_grok.stderr, standalone_grok.stderr
assert "grok" not in rb.SIDE_RUNNERS and "grok" not in rb.SIDE_WALL, rb.SIDE_RUNNERS
assert "grok" not in rb.GATEWAY_SIDES, rb.GATEWAY_SIDES
# The runs recorded while that side existed outlive it: their specs no longer parse, so every
# reader of the corpus has to answer leniently instead of refusing the row — a denominator that
# dropped them would reprice every cell measured beside them.
assert rb.rater_side("grok-low") is None
assert rb.rater_family("grok-low#2") == "grok-low"
assert rb.review_counts([{"rater": "grok-low"}, {"rater": "grok-low#2"}])["grok-low"] == 2
assert rb.rater_specs_counter(["grok-low", "opus-medium"])["grok-low"] == 1
assert rb.legacy_tier_match(rb.rater_specs_counter(["grok-low"])) is None
assert rb.collapse_rater_attempts(["grok-low", "grok-low#2"]) == ["grok-low x2"]
assert rb.human_cell_name("grok-low") == "grok-low"
# Recording is a reader too: the run is already on disk, and nothing about adjudicating it asks
# whether the cell could be launched again.
assert rb.recorded_rater("grok-low")["model"] == "grok"
assert rb.recorded_rater("grok-low")["effort"] == "low"
assert rb.recorded_rater("grok-low")["side"] is None
assert rb.recorded_rater("grok-low#2")["model"] == "grok"
assert rb.recorded_rater("agy-flash-medium-skill")["model"] == "agy-flash36"
# A spec that still parses keeps every field parse_rater gives it.
assert rb.recorded_rater("opus-medium") == rb.parse_rater("opus-medium")
# Leniency is for a retired cell, not for a string that is no cell name at all: that one gets
# parse_rater's own refusal, which names what a spec should look like.
for unnamed_rater in ("", "\n"):
    unnamed_refusal = None
    try:
        rb.recorded_rater(unnamed_rater)
    except ValueError as exc:
        unnamed_refusal = str(exc)
    assert unnamed_refusal, f"{unnamed_rater!r} was read as a cell"
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
    "when: THE NEARBY-STATE HUNT IS ASKED FOR",
    f"source: {lens_source}",
    f"source_hash: {lens_source_digest}",
    "aliases: [edgecases, edge]",
]))
write_lens("repeat-lens.md", "name: repeat-lens\nrepeats: 2")
edge_lens = rb.resolve_lens("edge-cases")
assert edge_lens["body"].startswith("EDGE CASE METHODOLOGY BODY"), edge_lens["body"]
assert edge_lens["when"] == "THE NEARBY-STATE HUNT IS ASKED FOR"
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
    ("name: ok-lens\nwhen: [always, never]", lens_body, "when must be a single value"),
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
# The listing is where a model that never heard of a lens decides whether to take it, so every
# lens says when — and one that does not is named as saying nothing, not skipped.
assert "  when: THE NEARBY-STATE HUNT IS ASKED FOR" in lens_listing, lens_listing
assert lens_listing.index("  when: THE NEARBY-STATE HUNT IS ASKED FOR") == 1 + next(
    index for index, line in enumerate(lens_listing) if line.startswith("edge-cases")
), lens_listing
assert "  when: (not recorded — the lens file should say)" in lens_listing, lens_listing
lens_checked = "\n".join(rb.lens_check_lines("edge"))
assert lens_checked.startswith("edge-cases ") and lens_source_digest in lens_checked
assert "when:     THE NEARBY-STATE HUNT IS ASKED FOR" in lens_checked, lens_checked
assert "aliases:  edgecases, edge" in lens_checked, lens_checked
assert "status:   current" in lens_checked, lens_checked
# `lens check` is registration, so a lens that never says when to take it fails there — while
# `read_lens` stays tolerant, since a run already under way must not die over missing prose.
lens_check_out = io.StringIO()
with contextlib.redirect_stdout(lens_check_out):
    lens_check_rc = rb.cmd_lens(argparse.Namespace(action="check", slug="edge"))
assert lens_check_rc == 0, lens_check_out.getvalue()
lens_check_out = io.StringIO()
with contextlib.redirect_stdout(lens_check_out):
    lens_check_rc = rb.cmd_lens(argparse.Namespace(action="check", slug="no-hash"))
assert lens_check_rc == 1, lens_check_out.getvalue()
assert "FAILED: no `when:`" in lens_check_out.getvalue(), lens_check_out.getvalue()
assert rb.resolve_lens("no-hash")["when"] == "", rb.resolve_lens("no-hash")
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
assert walled_available["opencode"] is True

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

# The reviewers switch closes a vendor for review work, and the roster cache holds its answer for
# a minute: read beside the cache instead of inside its key, a flip would go on staffing cells on
# a vendor the pool now refuses. The refusal says which switch, so the reader flips it back rather
# than going looking for quota that was never spent.
role_config = work / "worker-model-reviewers"
role_config.write_text("worker=auto\n")
os.environ["WORKER_PICK_CONFIG_FILE"] = str(role_config)
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "r1 r2"
rb._SIDE_ROSTER.clear()
assert rb.side_roster("claude", frozenset()) == ["r1", "r2"]
role_config.write_text("worker=auto\nclaudeb_reviewers=off\n")
assert rb.reviewers_role_off("claude") is True
assert rb.side_roster("claude", frozenset()) == [], rb.side_roster("claude", frozenset())
assert rb.affordability()["claude"] is False
assert rb.unaffordable_reason("claude") == "claudeb is switched off for reviewers"
assert "claudeb is switched off for reviewers" in rb.no_account_left("claude",
                                                                     rb.role_closed_note("claude"))
# The other vendors and the other role are untouched by it.
assert rb.reviewers_role_off("agy") is False
assert rb.affordability()["agy"] is True
role_config.write_text("worker=auto\nclaudeb_workers=off\n")
assert rb.reviewers_role_off("claude") is False
rb._SIDE_ROSTER.clear()
assert rb.side_roster("claude", frozenset()) == ["r1", "r2"]
assert rb.unaffordable_reason("claude") == "claude side is unaffordable"
del os.environ["WORKER_PICK_CONFIG_FILE"]

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
real_run_streamed = rb.run_streamed
agy_subprocess_timeouts = []


def capture_agy_timeout(command, **kwargs):
    if command and command[0] == str(fixtures / "fake-geminib.sh"):
        agy_subprocess_timeouts.append(kwargs.get("timeout_s"))
    return real_run_streamed(command, **kwargs)


rb.run_streamed = capture_agy_timeout
try:
    rc, _, _, stderr, adaptive_command = rb.run_agy(
        adaptive_rater, repo, sha, "", adaptive_run, "ignored fixture diff", "work"
    )
finally:
    rb.run_streamed = real_run_streamed
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
assert rb.agy_expected_label(rb.parse_rater("agy-flash37-low-skill")) == "Gemini 3.7 Flash (Low)"
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
fixture_wall_row = json.loads((rb.state_dir() / rb.WALL_STATE_FILE).read_text().splitlines()[-1])
assert fixture_wall_row["bucket"] == "general" and fixture_wall_row["window"] == "weekly"
assert fixture_wall_row["reset_at"] > time.time() + 2 * 86400, fixture_wall_row
assert rb.first_free_account("opencode", ["opencode-go"], set(), 0, "general") is None
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
assert "opencode default: weekly wall, resets " in exhausted_result[3], exhausted_result
assert "opencode second: plan wall" in exhausted_result[3], exhausted_result
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
# Every `review --worktree` down to the door's own tests is a panel Egor asked for by name, and
# those tests build an environment of their own with this stripped back out.
os.environ["REVIEW_ASKED"] = "1"
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
    assert "exactly one of commitish, --range, --worktree and --debt" in conflict.stderr, \
        conflict.stderr
    if "--range" in command:
        assert "--range" in conflict.stderr.split("got")[-1], conflict.stderr

# A repository whose first commit has not landed yet has no HEAD to read, and every worktree path
# that spelled one died on `Not a valid object name HEAD` — over a checkout that is nothing BUT
# unreviewed work. The snapshot is a root commit against the empty tree, exactly as diff_base
# already reads one.
fresh_repo = work / "no-commit-repo"
fresh_repo.mkdir()
subprocess.run(["git", "-C", str(fresh_repo), "init", "-q"], check=True)
(fresh_repo / "first.txt").write_text("first line\nsecond line\n")
fresh_empty = rb.empty_tree_hash(fresh_repo)
assert rb.head_tree_hash(fresh_repo) == fresh_empty
assert rb.working_tree_tree(fresh_repo) != fresh_empty
fresh_sha = rb.worktree_snapshot_commit(fresh_repo)
assert rb.diff_base(fresh_repo, fresh_sha) == fresh_empty
assert subprocess.run(
    ["git", "-C", str(fresh_repo), "rev-list", "--parents", "-n", "1", fresh_sha],
    check=True, capture_output=True, text=True,
).stdout.split() == [fresh_sha]
# The whole content reaches the panel: read as an unmeasurable diff it announces an empty target
# and refuses instead.
rb.announce_review_target(fresh_repo, fresh_sha)
# And down the CLI, which is where it died. `--paths` matching nothing is the first refusal PAST
# the tree resolution, so this stops before any panel is launched.
fresh_scoped = subprocess.run(
    [sys.argv[1], "review", "--worktree", "--repo", str(fresh_repo), "--tier", "T0",
     "--paths", "nothing-here.txt"],
    capture_output=True, text=True,
)
assert fresh_scoped.returncode != 0
assert "Not a valid object name" not in fresh_scoped.stderr, fresh_scoped.stderr
assert "matched nothing" in fresh_scoped.stderr, fresh_scoped.stderr

# A worktree panel is something Egor asked for by name: without that ask, `review --worktree` is
# the mid-work review a chat talked itself into.
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


# The door is an environment variable the suite must not inherit by accident: a REVIEW_ASKED
# already set — in the shell that ran these tests, or by the section above — would open every
# refusal below.
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
unasked = review_worktree(cycle_repo)
assert unasked.returncode == 2, unasked
assert CYCLE_REFUSAL in unasked.stderr, unasked.stderr
# The refusal has to name the way in, or a chat holding Egor's own ask has nothing to do with it
# but argue with the tool.
assert "REVIEW_ASKED=1" in unasked.stderr, unasked.stderr
# Egor asking for a review by name is the whole door, and it is the prefix the flow gate already
# verifies against the transcript — taken at face value here, since a flag of this tool's own would
# be one the caller grants itself unchecked. An authorized launch then dies on its own next
# refusal, which here is the clean tree.
asked = review_worktree(cycle_repo, env={**CYCLE_ENV, "REVIEW_ASKED": "1"})
assert asked.returncode != 0, asked
assert CYCLE_REFUSAL not in asked.stderr, asked.stderr
assert "working tree matches HEAD" in asked.stderr, asked.stderr
# The token is that one value: a variable merely present is not the prefix the gate checks.
for value in ("", "0", "yes"):
    not_asked = review_worktree(cycle_repo, env={**CYCLE_ENV, "REVIEW_ASKED": value})
    assert not_asked.returncode == 2, (value, not_asked)
    assert CYCLE_REFUSAL in not_asked.stderr, (value, not_asked.stderr)
# A merged panel comes through the same one door, and it is asked about before any repository
# argument is resolved: a guard that read the repositories first fell open on every spelling it
# could not resolve, and `PATH@BASE..HEAD` is no directory at all (found by panel, 2026-08-08).
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
merged_unasked = review_worktree(cycle_repo, cycle_second)
assert merged_unasked.returncode == 2, merged_unasked
assert CYCLE_REFUSAL in merged_unasked.stderr, merged_unasked.stderr
inline_unasked = review_worktree(cycle_repo, f"{cycle_second}@HEAD~0..HEAD")
assert inline_unasked.returncode == 2, inline_unasked
assert CYCLE_REFUSAL in inline_unasked.stderr, inline_unasked.stderr
merged_asked = review_worktree(
    cycle_repo, cycle_second, env={**CYCLE_ENV, "REVIEW_ASKED": "1"},
)
assert merged_asked.returncode != 0, merged_asked
assert CYCLE_REFUSAL not in merged_asked.stderr, merged_asked.stderr

# The corpus side is untouched: `run` is the benchmark's own launcher and Egor never asks for one
# by name, so this is not a door it has to come through.
cycle_run = subprocess.run(
    [sys.argv[1], "run", "--worktree", "--repo", str(cycle_repo), "--raters", "oc-kimik3"],
    capture_output=True, text=True,
)
assert cycle_run.returncode != 0
assert CYCLE_REFUSAL not in cycle_run.stderr, cycle_run.stderr
assert "working tree matches HEAD" in cycle_run.stderr, cycle_run.stderr

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
# The watchdog's cap and no second deadline of this side's own: a lower one killed the cell before
# the limit the run recorded, so the report named a cap the cell never reached.
wait_rater = rb.parse_rater("oc-mmm3")
wait_rater["timeout_s"] = 777
rb.run_opencode(wait_rater, repo, sha, "", wait_run, "fixture commit diff", "opencode-go")
del os.environ["OPENCODE_CAPTURE_ENV"]
assert wait_env.read_text().strip() == "777", wait_env.read_text()

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
assert rb.opencode_wall_window('{"metadata":{"limitName":"fiveHour"}}') == "5-hour"
assert rb.opencode_wall_window('{"metadata":{"limitName":"weekly"}}') == "weekly"
assert rb.opencode_wall_window('{"metadata":{"limitName":"monthly"}}') == "monthly"
assert rb.opencode_wall_window('{"metadata":{"limitName":"plan"}}') is None
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
# twice on 2026-08-04. An agy finding is judged on that side's own transport first and falls back
# to the gateway; an opencode finding has no second transport to be handed to and never sees it.
assert rb.verifier_chain("oc-dsv4flash", "agy") == [
    rb.GEMINI_VERIFIER, "oc-dsv4flash", "oc-kimik3", "oc-qwen37plus", "oc-mmm3"
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
# The prefix marks a chain that fell off its head, and on this side Gemini IS the head: marking
# every agy verdict with it would spend 24 of the why's 200 characters on what the side always
# does. The row still names the verifier in its own field.
assert "verified by" not in outage_row["why"], outage_row
assert outage_row.get("walled") is None, outage_row
assert outage_kept == [agy_claim], outage_kept
assert outage_audit[0]["verifier"] == rb.GEMINI_VERIFIER, outage_audit
gemini_calls = [command for command in outage_calls if command[0] == geminib_bin]
# The side judges its own findings on its own transport, so a gateway outage never reaches them.
assert len(outage_calls) == 2 and len(gemini_calls) == 2, outage_calls
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
# Leading on its own transport is only independence if the finding does not first queue for a
# gateway slot it will not use. With every slot taken by rater cells, an agy claim must still be
# judged; before this was lazy it blocked here until one of them finished.
gate_held = []
for _ in range(rb.OPENCODE_MAX_CONCURRENCY):
    rb.OPENCODE_GATE.acquire(0)
    gate_held.append(1)
gated_row, gated_error = [], []
def judge_while_gate_is_full():
    try:
        gated_row.append(rb.verify_one(
            0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
        ))
    except BaseException as exc:
        gated_error.append(exc)
subprocess.run = gemini_link_fixture
gate_thread = threading.Thread(target=judge_while_gate_is_full, daemon=True)
gate_thread.start()
gate_thread.join(20)
try:
    assert not gate_thread.is_alive(), "agy verification queued for an OpenCode gate slot"
    assert not gated_error, gated_error
    assert gated_row[0]["verifier"] == rb.GEMINI_VERIFIER, gated_row
finally:
    subprocess.run = real_run
    for _ in gate_held:
        rb.OPENCODE_GATE.release()
# An OpenCode finding still takes the slot before it calls, so the gateway stays rationed.
assert rb.OPENCODE_GATE.active == 0, rb.OPENCODE_GATE.active
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

# The gateway is the fallback now, so a wall it answers with lands on a claim the first link
# already declined — and it ends the chain there rather than asking the links behind it to
# prove the same wall again.
wall_handoff_calls = []


def gemini_handoff_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    wall_handoff_calls.append(command)
    if command[0] == geminib_bin:
        return subprocess.CompletedProcess(command, 0, "no verdict here", "")
    return subprocess.CompletedProcess(command, 1, "", "HTTP 429 usage limit reached")


subprocess.run = gemini_handoff_fixture
try:
    handoff_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert handoff_row["walled"] is True and handoff_row["code_matches"] is None, handoff_row
assert len(wall_handoff_calls) == 2 and wall_handoff_calls[0][0] == geminib_bin, wall_handoff_calls
assert rb.is_walled("opencode", "opencode-go"), "the gateway's wall went unrecorded"
clear_walls()

# A gateway that hangs takes the whole fallback with it — its links share the transport that
# stalled — so a claim its own side declined fails open rather than waiting out three more
# deadlines.
stall_calls = []


def gemini_stall_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    stall_calls.append(command)
    if command[0] == geminib_bin:
        return subprocess.CompletedProcess(command, 0, "no verdict here", "")
    raise subprocess.TimeoutExpired(command, kwargs["timeout"], stderr=b"")


subprocess.run = gemini_stall_fixture
try:
    stall_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
assert stall_row["kept"] is True and stall_row["code_matches"] is None, stall_row
assert stall_row["why"] == "verifier gave no usable answer; finding kept", stall_row
assert len(stall_calls) == 2 and stall_calls[0][0] == geminib_bin, stall_calls
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

# The agy side reads the wall on the far side of the gate, not before it: its own transport
# leads, so the slot is taken only once a claim falls through to the gateway, and everything
# that happened during that wait — including another thread retiring the account — is news.
# Checked once before the wait, every queued claim sends one more doomed request.
queued_wall_calls = []
queued_gate = rb.OPENCODE_GATE


class WallDuringWaitGate:
    def acquire(self, *args):
        queued_gate.acquire(*args)
        rb.mark_walled("opencode", "opencode-go")

    def release(self):
        queued_gate.release()


def gemini_declines_fixture(command, **kwargs):
    if command and command[0] in (worker_pick_bin, "git"):
        return real_run(command, **kwargs)
    queued_wall_calls.append(command)
    return subprocess.CompletedProcess(command, 0, "no verdict here", "")


subprocess.run = gemini_declines_fixture
rb.OPENCODE_GATE = WallDuringWaitGate()
try:
    queued_wall_row = rb.verify_one(
        0, agy_claim, repo, sha, "oc-dsv4flash", ["line one"], None, "agy",
    )
finally:
    subprocess.run = real_run
    rb.OPENCODE_GATE = queued_gate
assert [command[0] for command in queued_wall_calls] == [geminib_bin], queued_wall_calls
assert queued_wall_row["why"] == "verifier gave no usable answer; finding kept", queued_wall_row
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
    '"message":"Weekly usage limit reached. Resets in 3 days.",'
    '"metadata":{"limitName":"weekly"}}}'
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
assert dated_rows[dated_key][2] == "weekly", dated_rows
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

real_run_streamed = rb.run_streamed
timeout_stderr = b"HTTP 429 usage limit reached"


def timeout_run(command, **kwargs):
    raise subprocess.TimeoutExpired(
        command, kwargs["timeout_s"], output=b"partial output", stderr=timeout_stderr
    )


rb.run_streamed = timeout_run
opencode_rater["timeout_s"] = 1
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

    # A stall kill gets exactly one fresh attempt: a hang is usually the process's, not the
    # account's, so the retry may land on the same account — and its success is the cell's result,
    # with no stall marker left on it from the killed attempt.
    clear_walls()
    os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
    opencode_rater["timeout_s"] = 900
    opencode_rater["stall_s"] = 5
    stall_calls = []

    def stall_once(command, **kwargs):
        stall_calls.append(kwargs.get("stall_s"))
        if len(stall_calls) == 1:
            raise rb.RaterStalled(6, kwargs.get("stall_s"), "partial", "")
        return real_run_streamed(command, **kwargs)

    rb.run_streamed = stall_once
    stall_retry_run = work / "opencode-stall-retry"
    stall_retry_run.mkdir()
    stall_log = io.StringIO()
    with contextlib.redirect_stdout(stall_log):
        _, stall_account, stall_result = rb.run_rater_task(
            opencode_rater, repo, sha, "", stall_retry_run, "fixture commit diff"
        )
    assert stall_result[0] == 0, stall_result
    assert stall_calls == [5, 5], stall_calls
    assert "killed as stalled" in stall_log.getvalue(), stall_log.getvalue()
    assert not opencode_rater.get("stalled_s")
    assert not opencode_rater.get("killed"), opencode_rater
    assert opencode_rater.get("max_quiet_ms") is not None
    # The kill itself outlives the retry: without this trace a cap that is merely too tight
    # never escalates, and the pair burns one stall kill on every run for ever.
    assert opencode_rater.get("stalled_retry_s") == 5, opencode_rater
    opencode_rater.pop("stalled_retry_s", None)

    # A second stall in one cell is the cell's answer, not another lap.
    stall_always_calls = []

    def stall_always(command, **kwargs):
        stall_always_calls.append(1)
        raise rb.RaterStalled(6, kwargs.get("stall_s"), "", "")

    rb.run_streamed = stall_always
    stall_dead_run = work / "opencode-stall-dead"
    stall_dead_run.mkdir()
    with contextlib.redirect_stdout(io.StringIO()):
        _, _, stall_dead_result = rb.run_rater_task(
            opencode_rater, repo, sha, "", stall_dead_run, "fixture commit diff"
        )
    assert stall_dead_result[0] == 124, stall_dead_result
    assert stall_dead_result[3].startswith("rater stalled"), stall_dead_result
    assert opencode_rater.get("stalled_s") == 5
    assert opencode_rater.get("killed") == "stall", opencode_rater
    assert opencode_rater.get("killed_cap_s") == 5, opencode_rater
    assert len(stall_always_calls) == 2, stall_always_calls
    del os.environ["OPENCODE_FIXTURE_STDOUT"]
finally:
    rb.run_streamed = real_run_streamed
    for leftover in ("timeout_s", "stall_s", "stalled_s", "stalled_retry_s", "max_quiet_ms",
                     "killed", "killed_cap_s"):
        opencode_rater.pop(leftover, None)
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

# --- a fully walled OpenCode pool leaves the panel before its cells launch -----------------------
# A walled Claude or Codex pool takes its cells off the panel, while OpenCode's availability was a
# bare True: every OpenCode cell of every panel launched into a pool whose plans were all spent,
# died on `no_account_left` and was reported as errored — 269 of them over three days
# (Egor, 2026-08-04..10). The clock is frozen because a wall standing only until a real date would
# make this pass until that date and then stop.
import datetime as _wall_dt

walled_home = work / "opencode-walled-home"
(walled_home / ".config/opencode-go").mkdir(parents=True)
walled_profiles = walled_home / ".config/opencode-go/profiles"
walled_profiles.write_text("alt\nnew\n")
walled_store = work / "opencode-walled-claudeb"
walled_state = walled_store / "worker-stats"
walled_state.mkdir(parents=True)
walled_now = _wall_dt.datetime(2026, 8, 11, 12, 0).timestamp()
walled_resets = {"alt": _wall_dt.datetime(2026, 8, 29, 9, 0).timestamp(),
                 "new": _wall_dt.datetime(2026, 8, 31, 9, 0).timestamp()}
walled_labels = "opencode pool walled: alt monthly resets Aug 29, new monthly resets Aug 31"
walled_panel_cells = []


def write_opencode_walls(accounts, detected=None, resets=None):
    (walled_state / rb.WALL_STATE_FILE).write_text("".join(
        json.dumps({
            "side": "opencode", "account": f"opencode-go-{name}", "bucket": "general",
            "detected_at": walled_now - 3600 if detected is None else detected,
            "reset_at": (resets or walled_resets)[name], "window": "monthly",
        }) + "\n"
        for name in accounts
    ))


@contextlib.contextmanager
def fixture_tier(cells, name="TV"):
    """A tier of exactly the cells a case needs. The verifier runs under a tier and nowhere else,
    so every case about it that is not one of the four real compositions asks for one of these.
    """
    rb.REVIEW_TIERS[name] = {
        "budget_min": 1, "when": "fixture",
        "cells": list(cells), "cells_max": list(cells),
    }
    try:
        yield name
    finally:
        del rb.REVIEW_TIERS[name]


def walled_panel_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    walled_panel_cells.append((rater["spec"], account))
    return 0, 1, "NO FINDINGS", "", []


def walled_panel_run(raters, verify=None, tier=None):
    """The meta document of the run this call produced, whatever the store already held.

    A run is named for the second it started in, and these are fast enough to share one.
    """
    walled_run_offset[0] += 60
    seen = {path.name for path in (walled_state / "benches").iterdir()}
    with contextlib.redirect_stdout(io.StringIO()) as captured, \
            contextlib.redirect_stderr(io.StringIO()):
        rc = rb.cmd_run(argparse.Namespace(
            repo=str(pin_repo), commitish=pin_sha, raters=raters, tier=tier,
            leg=False, verify=verify, auto=None, focus=None,
        ))
    fresh = [path for path in (walled_state / "benches").iterdir() if path.name not in seen]
    assert rc == 0 and len(fresh) == 1, (rc, fresh)
    return json.loads((fresh[0] / "meta.json").read_text()), captured.getvalue()


walled_run_offset = [0]
walled_previous_home = os.environ["HOME"]
walled_previous_runners = dict(rb.SIDE_RUNNERS)
walled_previous_staleness = rb.check_limits_staleness
walled_real_utc_now = rb.utc_now
walled_real_time = time.time
rb.utc_now = lambda: walled_real_utc_now() + _wall_dt.timedelta(seconds=walled_run_offset[0])
os.environ["HOME"] = str(walled_home)
os.environ.pop("WORKER_STATS_DIR", None)
os.environ["CLAUDEB_DIR"] = str(walled_store)
os.environ["REVIEW_BENCH_WORKER_PICK_BIN"] = str(fixtures / "fake-worker-pick.sh")
os.environ["WORKER_PICK_FAKE_ACCOUNTS"] = "wk1 wk2"
for walled_side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[walled_side] = walled_panel_runner
rb.check_limits_staleness = lambda account: False
rb._SIDE_ROSTER.clear()
time.time = lambda: walled_now
try:
    (walled_state / "benches").mkdir()
    write_opencode_walls(("alt", "new"))
    assert rb.opencode_pool_free() is False
    assert rb.pool_account("opencode", set()) is None
    walled_affordable = rb.affordability()
    assert walled_affordable["opencode"] is False, walled_affordable
    assert walled_affordable["codex"] is True, walled_affordable
    assert rb.cell_available(walled_affordable, rb.parse_rater("oc-kimik3")) is False
    # Whether to wait or to add an account is a question only the reset date answers, so the
    # skipped line carries it; a side with no wall record keeps the pool's own wording.
    assert rb.unaffordable_reason("opencode") == walled_labels, rb.unaffordable_reason("opencode")
    assert rb.unaffordable_reason("claude") == "claude side is unaffordable"

    walled_mixed_meta, walled_mixed_output = walled_panel_run("oc-kimik3 x2,sol-low")
    assert f"skipped oc-kimik3: {walled_labels}" in walled_mixed_output, walled_mixed_output
    assert f"skipped oc-kimik3#2: {walled_labels}" in walled_mixed_output, walled_mixed_output
    # The hole the wall left is carried in the meta, or a panel that lost its whole OpenCode leg
    # reads as a complete run to every surface that reads one back.
    assert walled_mixed_meta["raters"] == ["sol-low", "oc-kimik3", "oc-kimik3#2"], \
        walled_mixed_meta
    assert walled_mixed_meta["completed_raters"] == ["sol-low"], walled_mixed_meta
    assert [row["rater"] for row in walled_mixed_meta["rater_runs"]] == ["sol-low"], \
        walled_mixed_meta["rater_runs"]
    assert [spec for spec, _ in walled_panel_cells] == ["sol-low"], walled_panel_cells
    walled_mixed_report = "\n".join(rb.report_lines(
        walled_state / "benches" / walled_mixed_meta["run_id"], walled_mixed_meta
    ))
    assert any(line.startswith("not run:") and "kimi" in line
               for line in walled_mixed_report.splitlines()), walled_mixed_report

    # A tier is a cell list handed to this same path by cmd_review, so a tier whose OpenCode cells
    # all drop runs the rest of itself rather than refusing whole.
    walled_panel_cells.clear()
    walled_tier_cells = ",".join(rb.REVIEW_TIERS["T1"]["cells"])
    walled_tier_expected = [
        rater["spec"] for rater in rb.parse_raters(walled_tier_cells)
        if rater["side"] != "opencode"
    ]
    walled_tier_dropped = [
        rater["spec"] for rater in rb.parse_raters(walled_tier_cells)
        if rater["side"] == "opencode"
    ]
    walled_tier_meta, _ = walled_panel_run(walled_tier_cells)
    assert walled_tier_expected and \
        walled_tier_meta["raters"] == walled_tier_expected + walled_tier_dropped, \
        walled_tier_meta
    assert walled_tier_meta["completed_raters"] == walled_tier_expected, walled_tier_meta

    # A panel of nothing but OpenCode cells has nowhere to run, and the refusal names the wall
    # rather than sending the reader looking for a fault in the request.
    walled_refusal = ""
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rb.cmd_run(argparse.Namespace(
                repo=str(pin_repo), commitish=pin_sha, raters="oc-kimik3 x2,oc-dsv4flash",
                leg=False, verify=None, auto=None, focus=None,
            ))
    except RuntimeError as exc:
        walled_refusal = str(exc)
    assert walled_refusal == f"no affordable requested raters: {walled_labels}", walled_refusal

    # The verifier is an OpenCode model: asked for where the pool cannot staff it and no agy cell
    # leads its chain off the gateway, the run says so instead of keeping every claim unchecked.
    walled_verify_refusal = ""
    with fixture_tier(["oc-kimik3", "sol-low"]) as walled_verify_tier:
        try:
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                rb.cmd_run(argparse.Namespace(
                    repo=str(pin_repo), commitish=pin_sha, raters=None,
                    tier=walled_verify_tier,
                    leg=False, verify="oc-dsv4flash", auto=None, focus=None,
                ))
        except RuntimeError as exc:
            walled_verify_refusal = str(exc)
        assert walled_verify_refusal.endswith(f"the verifier reaches — {walled_labels}"), \
            walled_verify_refusal
    # An agy cell's chain leads with Gemini's own transport, so the same walled pool leaves its
    # verifier configured — the side degrades onto that link exactly as it does mid-run.
    with fixture_tier(["agy-flash36-medium-skill"]) as walled_agy_tier:
        walled_agy_meta, _ = walled_panel_run(None, tier=walled_agy_tier)
        assert walled_agy_meta["verifier"] == rb.OPENCODE_VERIFIER, walled_agy_meta
        # Asked for by name over that same panel, it is configured rather than refused: a cell the
        # pool staffed is the account the verifier runs on, so there is no second reach to test.
        walled_agy_asked, _ = walled_panel_run(
            None, verify="oc-dsv4flash", tier=walled_agy_tier
        )
        assert walled_agy_asked["verifier"] == rb.verifier_model("oc-dsv4flash"), walled_agy_asked

    # A pool the caller emptied by hand reads exactly like one nobody ever staffed, and the
    # reader spends the wait adding accounts that were there all along.
    os.environ["REVIEW_BENCH_EXCLUDE_OPENCODE"] = "opencode-go-new"
    assert rb.unaffordable_reason("opencode") == \
        walled_labels + "; excluded by REVIEW_BENCH_EXCLUDE_OPENCODE: opencode-go-new", \
        rb.unaffordable_reason("opencode")
    assert rb.unaffordable_reason("claude") == "claude side is unaffordable"
    del os.environ["REVIEW_BENCH_EXCLUDE_OPENCODE"]

    # One account walled is not a walled pool: the cells run on what is left.
    walled_panel_cells.clear()
    write_opencode_walls(("alt",))
    assert rb.opencode_pool_free() is True
    walled_partial_meta, _ = walled_panel_run("oc-kimik3")
    assert walled_partial_meta["raters"] == ["oc-kimik3"], walled_partial_meta
    assert walled_panel_cells == [("oc-kimik3", "opencode-go-new")], walled_panel_cells

    # Recovery is passive: nothing sweeps the record, so a wall whose reset has passed must not
    # suppress the pool, and a fresh account restores it with the standing walls left in place.
    write_opencode_walls(
        ("alt", "new"), detected=walled_now - 40 * 86400,
        resets={"alt": walled_now - 86400, "new": walled_now - 86400},
    )
    assert rb.opencode_pool_free() is True
    assert rb.affordability()["opencode"] is True
    assert rb.unaffordable_reason("opencode") == "opencode side is unaffordable"
    write_opencode_walls(("alt", "new"))
    assert rb.opencode_pool_free() is False
    walled_profiles.write_text("alt\nnew\nevyoxqy\n")
    assert rb.opencode_pool_free() is True, "a fresh account left the pool reading as walled"
finally:
    time.time = walled_real_time
    rb.utc_now = walled_real_utc_now
    os.environ["HOME"] = walled_previous_home
    rb.SIDE_RUNNERS.update(walled_previous_runners)
    rb.check_limits_staleness = walled_previous_staleness
    del os.environ["WORKER_PICK_FAKE_ACCOUNTS"], os.environ["REVIEW_BENCH_WORKER_PICK_BIN"]
    rb._SIDE_ROSTER.clear()

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
    "claude": True, "codex": True, "agy": True, "opencode": True,
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
# The launching chat is resolved by walking this process's parents against the harness's pid
# registry, and the fixture one is empty: nothing in a suite may read the real ~/.claude/sessions,
# and a run whose launcher cannot be named must leave the key out rather than write a blank.
empty_session_registry = work / "sessions-empty"
empty_session_registry.mkdir()
os.environ[rb.SESSION_REGISTRY_DIR_ENV] = str(empty_session_registry)
rb.affordability = lambda: {
    "claude": False, "codex": True, "agy": True, "opencode": True,
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
assert "session" not in captured_progress[0], captured_progress[0]
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
# A registry entry for this very process is the first hop of the walk, which is the run's own
# launcher as far as the document is concerned: the statusline of the chat that started a review
# over ANOTHER repository has nothing but this key to recognise it by.
session_registry = work / "sessions-fixture"
session_registry.mkdir()
(session_registry / f"{os.getpid()}.json").write_text(
    json.dumps({"sessionId": "chat-launching-the-run"}) + "\n"
)
os.environ[rb.SESSION_REGISTRY_DIR_ENV] = str(session_registry)
assert rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, raters="sol-medium",
    leg=False, verify=None, auto=None, focus=None, tier="T2", max=True, foreground=True,
)) == 0
assert captured_progress[1]["tier"] == "T2" and captured_progress[1]["max"] is True, \
    captured_progress[1]
assert captured_progress[1]["session"] == "chat-launching-the-run", captured_progress[1]
# A malformed entry is no entry: the walk carries on up rather than recording a session id that
# is not a string.
(session_registry / f"{os.getpid()}.json").write_text(json.dumps({"sessionId": 7}) + "\n")
assert rb.walk_launching_session() is None
os.environ[rb.SESSION_REGISTRY_DIR_ENV] = str(empty_session_registry)
rb.SIDE_RUNNERS["codex"] = tier_runner
rb.affordability = lambda: {
    "claude": True, "codex": True, "agy": True, "opencode": True,
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
# The drift anchor, taken at LAUNCH because that is the tree the cells are handed: the runner
# captured the launch document before it answered, and the finished one carries the same blobs.
worktree_reviewed = worktree_meta["reviewed"]
assert set(worktree_reviewed) == {"pinned.txt"}, worktree_reviewed
assert launch_meta_seen[-1]["reviewed"] == worktree_reviewed, launch_meta_seen[-1]
assert subprocess.run(
    ["git", "-C", str(pin_repo), "cat-file", "blob", worktree_reviewed["pinned.txt"]],
    check=True, capture_output=True, text=True,
).stdout == "working tree marker\n"
assert "timed_out" not in worktree_meta, worktree_meta

# --- the watchdog: a breached cell marks the whole run ------------------------------------------
# One cap per (model, effort) reaches every side, and the run a killed cell belongs to is what the
# statusline goes loud on: nothing else on disk says a review hung.
timeout_caps_seen = []
stall_caps_seen = []


def timeout_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    timeout_caps_seen.append(rater["timeout_s"])
    stall_caps_seen.append(rater.get("stall_s"))
    return 124, 1, "", "rater timed out after 900s", []


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = timeout_runner
timeout_run_store = work / "timed-out-run-claudeb"
os.environ["CLAUDEB_DIR"] = str(timeout_run_store)
with contextlib.redirect_stdout(io.StringIO()):
    timeout_rc = rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=None, worktree=True, raters="sol-medium",
        leg=False, verify=None, auto=None, focus=None,
    ))
timeout_run_dir = next((timeout_run_store / "worker-stats" / "benches").iterdir())
timeout_meta = json.loads((timeout_run_dir / "meta.json").read_text())
assert timeout_rc == 1
assert timeout_caps_seen == [rb.WATCHDOG_FLOOR_S], timeout_caps_seen
# No gap history in a fresh store: no cell may carry a stall cap, only the duration one.
assert stall_caps_seen == [None], stall_caps_seen
assert timeout_meta["timed_out"] is True, timeout_meta
assert timeout_meta["rater_runs"][0]["timeout_s"] == rb.WATCHDOG_FLOOR_S, timeout_meta

# With gap history on record the launch hands the cell its stall cap — and only under the
# duration cap, so a cap the cell cannot reach is never reported as its limit.
# Named to sort before every real run id: history walks runs in name order, and a seeded
# completion that sorted as the newest run would clear the kill record it is meant to precede.
seeded = timeout_run_store / "worker-stats" / "benches" / "00000000T000000Z-seeded"
seeded.mkdir(parents=True)
(seeded / "meta.json").write_text(json.dumps({"rater_runs": [
    {"rater": "sol-medium", "model": "sol", "effort": "medium", "side": "codex",
     "duration_ms": 700_000, "max_quiet_ms": 60_000, "findings": 0, "exit_code": 0},
]}))
timeout_caps_seen.clear()
stall_caps_seen.clear()
# Run ids carry second resolution; back-to-back launches in one store collide on the run dir.
subprocess.run(["sleep", "1.1"], check=True)
with contextlib.redirect_stdout(io.StringIO()):
    stall_rc = rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=None, worktree=True, raters="sol-medium",
        leg=False, verify=None, auto=None, focus=None,
    ))
assert stall_rc == 1
# 1080 = the breached 900 cap plus one grace; 240 = the stall floor over gap 60s + grace 120s.
assert timeout_caps_seen == [1080], timeout_caps_seen
assert stall_caps_seen == [rb.STALL_FLOOR_S], stall_caps_seen

# A stall cap grown past the duration cap (breach escalation) must not reach the cell: the
# duration watchdog already fires first, and reporting the unreachable one as the cell's limit
# would name a cap that never operated.
(seeded / "meta.json").write_text(json.dumps({"rater_runs": [
    {"rater": "sol-medium", "model": "sol", "effort": "medium", "side": "codex",
     "duration_ms": 700_000, "max_quiet_ms": 60_000, "findings": 0, "exit_code": 0},
    {"rater": "sol-medium", "model": "sol", "effort": "medium", "side": "codex",
     "duration_ms": 2_000_000, "stalled_s": 2000, "exit_code": 124},
]}))
timeout_caps_seen.clear()
stall_caps_seen.clear()
subprocess.run(["sleep", "1.1"], check=True)
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=None, worktree=True, raters="sol-medium",
        leg=False, verify=None, auto=None, focus=None,
    )) == 1
assert timeout_caps_seen == [1260], timeout_caps_seen
assert stall_caps_seen == [None], stall_caps_seen

# A cell whose retry stalled too is the hung review the watchdog exists to announce, killed
# earlier: its run must read timed_out, or the statusline stays quiet on the one failure it is
# loud for. A retry that COMPLETED is not: its run passes, and the meta row keeps the killed
# attempt's trace so the next run's cap can grow.
stall_runner_calls = []


def stalling_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    stall_runner_calls.append(rater["spec"])
    rater["stalled_s"] = 7
    return 124, 1, "", "rater stalled: no output activity for 7s (stall cap 5s)", []


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = stalling_runner
subprocess.run(["sleep", "1.1"], check=True)
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=None, worktree=True, raters="sol-medium",
        leg=False, verify=None, auto=None, focus=None,
    )) == 1
stalled_run_dir = max(
    path for path in (timeout_run_store / "worker-stats" / "benches").iterdir()
    if path.name[:2] == "20"
)
stalled_meta = json.loads((stalled_run_dir / "meta.json").read_text())
assert stall_runner_calls == ["sol-medium", "sol-medium"], stall_runner_calls
assert stalled_meta["timed_out"] is True, stalled_meta
assert stalled_meta["rater_runs"][0]["stalled_s"] == 7, stalled_meta
assert stalled_meta["rater_runs"][0]["stalled_retry_s"] == 7, stalled_meta


def stall_then_complete(rater, repo_path, commit, focus, run_dir, diff, account):
    stall_runner_calls.append(rater["spec"])
    if len(stall_runner_calls) == 1:
        rater["stalled_s"] = 9
        return 124, 1, "", "rater stalled: no output activity for 9s (stall cap 5s)", []
    return 0, 1, "NO FINDINGS", "", []


stall_runner_calls.clear()
for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = stall_then_complete
subprocess.run(["sleep", "1.1"], check=True)
with contextlib.redirect_stdout(io.StringIO()):
    assert rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=None, worktree=True, raters="sol-medium",
        leg=False, verify=None, auto=None, focus=None,
    )) == 0
retried_run_dir = max(
    path for path in (timeout_run_store / "worker-stats" / "benches").iterdir()
    if path.name[:2] == "20"
)
retried_meta = json.loads((retried_run_dir / "meta.json").read_text())
assert stall_runner_calls == ["sol-medium", "sol-medium"], stall_runner_calls
assert "timed_out" not in retried_meta, retried_meta
retried_row = retried_meta["rater_runs"][0]
assert retried_row["exit_code"] == 0 and "stalled_s" not in retried_row, retried_row
assert retried_row["stalled_retry_s"] == 9, retried_row
for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = tier_runner

# --- debt: the one line the gate reads ----------------------------------------------------------
# Debt is per PATH and per CONTENT: the newest artifact holding a path — a triaged run's snapshot or
# a waiver — is what the working tree is compared against, and nothing here reads git history, so a
# commit neither creates debt nor settles it.
sr_repo = work / "session-review-repo"
sr_repo.mkdir()
subprocess.run(["git", "init", "-q", str(sr_repo)], check=True)
subprocess.run(["git", "-C", str(sr_repo), "config", "user.email", "bench@example.test"],
               check=True)
subprocess.run(["git", "-C", str(sr_repo), "config", "user.name", "Review Bench"], check=True)
(sr_repo / "src").mkdir()
(sr_repo / "docs").mkdir()
sr_source = sr_repo / "src" / "a.py"
sr_source.write_text("".join(f"line {n}\n" for n in range(1, 21)))
(sr_repo / "docs" / "b.md").write_text("doc\n")
(sr_repo / "docs" / "big.md").write_text("".join(f"para {n}\n" for n in range(1, 31)))
subprocess.run(["git", "-C", str(sr_repo), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(sr_repo), "commit", "-qm", "initial"], check=True)
sr_source.write_text("".join(f"line {n}\n" for n in range(1, 21)) + "added\n")
sr_binary = sr_repo / "src" / "blob.bin"
sr_binary.write_bytes(b"\x00\x01\x02\x03")
# A repo-wide snapshot is the change the sealed commit holds against its base: the clean tracked
# file was never shown to the panel, and the untracked text and binary beside it were.
sr_snapshot, _ = rb.sealed_target(sr_repo)
sr_blobs = rb.reviewed_blobs(sr_repo, [], sr_snapshot)
assert set(sr_blobs) == {"src/a.py", "src/blob.bin"}, sr_blobs
# A scope stages the whole subtree under its paths, binaries included.
sr_scoped_snapshot, _ = rb.sealed_target(sr_repo, scope=["src"])
sr_scoped_blobs = rb.reviewed_blobs(sr_repo, ["src"], sr_scoped_snapshot)
assert set(sr_scoped_blobs) == {"src/a.py", "src/blob.bin"}, sr_scoped_blobs
assert sr_scoped_blobs["src/a.py"] == sr_blobs["src/a.py"], sr_scoped_blobs
# The anchor is the commit the cells were handed and never the tree standing under them: a rerun
# pinned to an existing snapshot sha reads a checkout that has moved on since, and hashing that
# would vouch for bytes no rater ever saw.
sr_moved = sr_source.read_text()
sr_source.write_text("drifted\n")
assert rb.reviewed_blobs(sr_repo, [], sr_snapshot) == sr_blobs, sr_blobs
# Which paths those are is the commit's too. Listed against the checkout instead, a file a
# co-tenant restored between the seal and the record drops out of a review that read it, and the
# record stops answering for it for good.
sr_source.write_text("".join(f"line {n}\n" for n in range(1, 21)))
assert rb.reviewed_blobs(sr_repo, [], sr_snapshot) == sr_blobs, sr_blobs
sr_source.write_text(sr_moved)
# A deletion is a change the panel read and no blob can stand for it, so the snapshot records the
# path against nothing rather than dropping it — a review of one would otherwise hold no path at
# all and cover nothing it read.
(sr_repo / "docs" / "b.md").unlink()
sr_deletion_snapshot, _ = rb.sealed_target(sr_repo)
sr_deletion_blobs = rb.reviewed_blobs(sr_repo, [], sr_deletion_snapshot)
assert sr_deletion_blobs.get("docs/b.md") == "", sr_deletion_blobs
subprocess.run(["git", "-C", str(sr_repo), "checkout", "--", "docs/b.md"], check=True)
# A symlink is content the snapshot holds as its link text, which is what debt compares it by:
# reading through the link would answer for the file it points at instead.
(sr_repo / "src" / "link.py").symlink_to("a.py")
sr_link_snapshot, _ = rb.sealed_target(sr_repo, scope=["src"])
sr_link_blobs = rb.reviewed_blobs(sr_repo, ["src"], sr_link_snapshot)
assert rb.blob_bytes(sr_repo, sr_link_blobs["src/link.py"]) == b"a.py", sr_link_blobs
(sr_repo / "src" / "link.py").unlink()

sr_claudeb_before = os.environ["CLAUDEB_DIR"]
sr_session_before = os.environ.get("CLAUDE_CODE_SESSION_ID")
# A waiver carries the chat that recorded it, and the tool refuses to write one it cannot name a
# chat for, so these scenarios run as the chat the journals below name.
os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-1"
sr_worker_runs_before = os.environ.get("WORKER_RUN_DIR")
sr_worker_runs = work / "session-review-worker-runs"
sr_worker_runs.mkdir()
os.environ["WORKER_RUN_DIR"] = str(sr_worker_runs)


def sr_worker_run(run_id, launcher, lines, journaled=False, worker=None, dirty=None,
                  finished=False):
    """One run record the way `worker-run` writes it: the launching chat beside the file list its
    attempts produced, the worker's own session where the vendor named one, and the workdir dirt
    the run gained where its own list says it cannot be complete.
    """
    directory = sr_worker_runs / run_id
    directory.mkdir()
    if launcher is not None:
        (directory / "launcher").write_text(launcher + "\n")
    if lines is not None:
        (directory / "files").write_text("\n".join(lines) + "\n")
    if worker is not None:
        (directory / "worker-session").write_text(worker + "\n")
    if dirty is not None:
        (directory / "dirty").write_text("\n".join(dirty) + "\n")
    if finished:
        (directory / "exit_code").write_text("0\n")
    if journaled:
        (directory / "journaled").write_text("")
    return directory
sr_stores = 0


def sr_store():
    """A bench store of its own per scenario: the answer is about the NEWEST artifact holding a
    path, so two scenarios sharing one store would answer each other's question.
    """
    global sr_stores
    sr_stores += 1
    store = work / f"session-review-store-{sr_stores}"
    os.environ["CLAUDEB_DIR"] = str(store)
    directory = store / "worker-stats" / "benches"
    directory.mkdir(parents=True)
    return directory


def sr_run(benches, run_id, reviewed=None, session="chat-1", scope=None,
           triaged=True, timed_out=False, repo=None, report=None, sealed_at=None):
    directory = benches / run_id
    directory.mkdir()
    meta = {
        "run_id": run_id, "repo": str(repo or sr_repo), "session": session,
        "worktree": True, "reviewed": dict(reviewed or {}),
        # A real run always carries one, and the round budget needs it: two rounds of one piece of
        # work sit days apart, and a run of the same scope from another month is not the pass that
        # answers this one.
        "finished": rb.iso_now(),
    }
    if sealed_at is not None:
        meta["sealed_at"] = sealed_at
    if scope is not None:
        meta["scope"] = scope
    if timed_out:
        meta["timed_out"] = True
    (directory / "meta.json").write_text(json.dumps(meta))
    if report is not None:
        (directory / rb.REPORT_RECEIPT).write_text(json.dumps(report))
    elif triaged:
        (directory / "verdicts.jsonl").write_text("")
    return directory


def sr_answer(*paths, session="chat-1", repo=None, listing=False):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = rb.cmd_debt(argparse.Namespace(
            repo=str(repo or sr_repo), session=session, paths=list(paths), list=listing,
        ))
    assert rc == 0, rc
    return out.getvalue().strip()


def sr_waive(*paths, reason="not this round", repo=None):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = rb.cmd_waive(argparse.Namespace(
            repo=str(repo or sr_repo), reason=reason, paths=list(paths),
        ))
    return rc, out.getvalue().strip()


def sr_sha(path, repo=None):
    """What git itself calls this content, which is what the artifacts record — and, asserted
    against `path_blob_sha` below, that the tool hashes the same thing git does.
    """
    return subprocess.run(
        ["git", "-C", str(repo or sr_repo), "hash-object", "--", str((repo or sr_repo) / path)],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


sr_gitdir = pathlib.Path(subprocess.run(
    ["git", "-C", str(sr_repo), "rev-parse", "--absolute-git-dir"],
    check=True, capture_output=True, text=True,
).stdout.strip())


def sr_journal(name, session, path, epoch=1800000000):
    """One entry the way the gate writes it: NUL-terminated `session TAB epoch TAB path`.

    The default epoch postdates every artifact these fixtures record, the way a live gate's
    `date +%s` postdates the artifacts standing when it writes: a debt record older than its
    path's covering artifact is a settled episode's leftover and names no author.
    """
    with (sr_gitdir / name).open("ab") as handle:
        handle.write(f"{session}\t{epoch}\t{path}\0".encode())


def sr_clear_journals():
    for name in (rb.DEBT_JOURNAL, rb.COMMIT_JOURNAL):
        (sr_gitdir / name).unlink(missing_ok=True)


assert rb.path_blob_sha(sr_repo, "src/a.py") == sr_sha("src/a.py")
assert rb.path_blob_sha(sr_repo, "docs/gone.md") == ""

# Nothing has read this tree: a file standing in it is in debt whole, and a path that is not there
# is nobody's debt.
sr_empty = sr_store()
assert sr_answer("src/a.py") == "debt 1 other"
assert sr_answer("docs/gone.md") == "none"
assert sr_answer("src/a.py", "docs/big.md") == "debt 2 other"
# A triaged run holding the path settles it whoever launched it: debt is about content having been
# read, and which chat owes the review is the separate question the journals answer.
sr_run(sr_empty, "20260101T000100Z-aaaaaaa", sr_blobs, session="chat-2")
assert sr_answer("src/a.py") == "none"
# A run nobody triaged is a panel's raw output nobody has stood behind, and a run holding no
# snapshot read committed code: neither answers for anything in the working tree.
sr_untriaged = sr_store()
sr_run(sr_untriaged, "20260101T000100Z-aaaaaaa", sr_blobs, triaged=False)
assert sr_answer("src/a.py") == "debt 1 other"
sr_commit_run = sr_store()
sr_run(sr_commit_run, "20260101T000100Z-aaaaaaa", {})
assert sr_answer("src/a.py") == "debt 1 other"

sr_covered = sr_store()
sr_run(sr_covered, "20260101T000100Z-aaaaaaa", sr_blobs)
assert sr_answer("src/a.py") == "none"
# One line past what the panel read is debt: there is no budget to spend it out of, and no share of
# a corpus under which an unread change reads as reviewed.
sr_source.write_text("".join(f"line {n}\n" for n in range(1, 21)) + "added\nmore\n")
assert sr_answer("src/a.py") == "debt 1 other"
assert sr_answer("src/a.py", listing=True) == "src/a.py"
# A file born after the run is in debt too: a run that never read it holds no content to compare,
# so a repo-wide review cannot blanket what came after it.
(sr_repo / "src" / "born-after.py").write_text("new\n")
assert sr_answer("src/born-after.py") == "debt 1 other"
assert sr_answer("src/a.py", "src/born-after.py", listing=True) == "src/a.py\nsrc/born-after.py"
(sr_repo / "src" / "born-after.py").unlink()
# Whose debt it is comes out of the two journals the gate writes and out of nothing else: the commit
# journal for work still uncommitted, the debt journal for what a commit carried away.
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py")
assert sr_answer("src/a.py") == "debt 1 mine"
assert sr_answer("src/a.py", session="chat-2") == "debt 1 other"
sr_clear_journals()
sr_journal(rb.DEBT_JOURNAL, "chat-1", "src/a.py")
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()
# A debt record OLDER than the artifact covering its path is a settled episode's leftover the
# compaction has not swept yet: it holds no chat answerable for the debt standing there now.
sr_journal(rb.DEBT_JOURNAL, "chat-1", "src/a.py", epoch=1600000000)
sr_journal(rb.DEBT_JOURNAL, "chat-2", "src/a.py")
assert sr_answer("src/a.py", session="chat-1") == "debt 1 other"
assert sr_answer("src/a.py", session="chat-2") == "debt 1 mine"
sr_clear_journals()
# That floor CHOOSES among a path's records and never empties the set. A path back in debt through
# a channel no hook stamps — a merge, a rebase, an editor these hooks never see — leaves nothing but
# leftovers under it, and dropping them all answers `unknown` about a path whose author is written
# down, which is the disowning the rule above exists to prevent.
sr_journal(rb.DEBT_JOURNAL, "chat-1", "src/a.py", epoch=1600000000)
assert sr_answer("src/a.py", session="chat-1") == "debt 1 mine"
assert sr_answer("src/a.py", session="chat-2") == "debt 1 other"
sr_clear_journals()
# Asked about no path in particular, the question is the repository's — and its universe is what the
# artifacts hold plus what the journals name, never every file standing in the tree.
assert sr_answer() == "debt 1 other"
(sr_repo / "src" / "unnamed.py").write_text("nobody named me\n")
assert sr_answer() == "debt 1 other"
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/unnamed.py")
# One path of the two is this chat's: the word stays binary for every reader switching on it, and
# the count beside it is what keeps a chat from reading nine co-tenants' files as its own.
assert sr_answer() == "debt 2 mine 1"
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py")
assert sr_answer() == "debt 2 mine"
assert sr_answer(session="chat-2") == "debt 2 other"
# Nobody named a session, so nothing computed an ownership: `other` would assert one.
assert sr_answer(session="") == "debt 2 unknown"
sr_clear_journals()
(sr_repo / "src" / "unnamed.py").unlink()
# A binary is content like any other: what no line budget could price is a sha that either matches
# what the panel read or does not.
sr_binary.write_bytes(b"\x00\x09\x08\x07\x06\x05")
assert sr_answer("src/blob.bin") == "debt 1 other"
sr_binary.write_bytes(b"\x00\x01\x02\x03")
assert sr_answer("src/blob.bin") == "none"
# The path spelling is the journal's: repository-relative, and an absolute path names the same file.
assert sr_answer(str(sr_repo / "src" / "a.py")) == "debt 1 other"
# Down to its whitespace: a leading or trailing space is part of a filename, and trimming one asks
# about the path beside the one the journal named.
sr_spelled = rb.debt_query_paths(sr_repo, ["./src/a.py", "src/spaced .py ", "  "])
assert sr_spelled == ["src/a.py", "src/spaced .py "], sr_spelled

# A waiver is an artifact like a review: it records the bytes standing there and why nobody is
# reviewing them, and it settles exactly those bytes.
sr_waived = sr_store()
sr_run(sr_waived, "20260101T000100Z-aaaaaaa", sr_blobs)
assert sr_answer("src/a.py") == "debt 1 other"
assert sr_waive(reason="") == (1, "waive: --reason must say why this work is going unreviewed")
assert sr_waive(reason="   ")[0] == 1
sr_rc, sr_said = sr_waive("src/a.py", reason="one line of prose")
assert (sr_rc, sr_said) == (0, "waived 1 path(s): one line of prose"), (sr_rc, sr_said)
assert sr_answer("src/a.py") == "none"
sr_waivers = json.loads((rb.state_dir() / rb.WAIVER_DIR).glob("*.json").__next__().read_text())
assert sr_waivers["waivers"][0]["paths"] == {"src/a.py": sr_sha("src/a.py")}, sr_waivers
assert sr_waivers["waivers"][0]["reason"] == "one line of prose", sr_waivers
# Exactly those: the next edit is debt again, or a skipped review would keep covering whatever
# replaced the content nobody read.
sr_source.write_text("".join(f"line {n}\n" for n in range(1, 21)) + "added\nmore\nmore\n")
assert sr_answer("src/a.py") == "debt 1 other"
# Nothing in debt is nothing to waive.
assert sr_waive("src/blob.bin") == (1, "waive: nothing here is in debt")

# A round that came back badly is not a round a chat may waive away: the run holding the debt path
# carries its own tally, and the P1 threshold — the one the fixing pass stops at — locks it.
sr_locked = sr_store()
sr_run(sr_locked, "20260101T000100Z-aaaaaaa", sr_blobs,
       report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
assert sr_answer("src/a.py") == "debt 1 other locked"
sr_rc, sr_said = sr_waive("src/a.py", reason="not now")
assert sr_rc == 1 and sr_said.startswith("waive: refused"), (sr_rc, sr_said)
# The tally alone does NOT lock, however far past its own threshold it runs: that round is owed a
# second review in the fork's voice, and the waiver may still answer it — a waiver records its
# reason, so what is left is a judged skip and never a silent one.
sr_findings_only = sr_store()
sr_run(sr_findings_only, "20260101T000100Z-aaaaaaa", sr_blobs,
       report={"confirmed": 8, "confirmed_by_severity": {"P1": 0}})
assert sr_answer("src/a.py") == "debt 1 other"
assert sr_waive("src/a.py", reason="eight small ones, each judged")[0] == 0
# Under the threshold it is ordinary debt, waiver and all.
sr_soft = sr_store()
sr_run(sr_soft, "20260101T000100Z-aaaaaaa", sr_blobs,
       report={"confirmed": 1, "confirmed_by_severity": {"P1": 1}})
assert sr_answer("src/a.py") == "debt 1 other"
assert sr_waive("src/a.py", reason="tiny")[0] == 0
# The lock belongs to the run and not to the path: the follow-up review that reads the current
# content settles the debt outright, which is what the fork asks for — but only a review of the
# full original scope is that follow-up. A later run narrower than the locked one takes no path
# back from it, or a one-path rerun would discharge a second review by answering for a corner of
# it, and a waiver takes none at any width.
sr_cleared = sr_store()
sr_run(sr_cleared, "20260101T000100Z-aaaaaaa", sr_blobs,
       report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
assert sr_answer("src/a.py") == "debt 1 other locked"
sr_run(sr_cleared, "20260101T000200Z-bbbbbbb", {"src/a.py": sr_sha("src/a.py")})
assert sr_answer("src/a.py") == "debt 1 other locked"
# And the refusal names what is locked and which round has to answer for it: a caller told only
# that something is locked has nothing to act on.
sr_rc, sr_said = sr_waive("src/a.py", reason="the narrow rerun will do")
assert sr_rc == 1 and "src/a.py" in sr_said and "20260101T000100Z-aaaaaaa" in sr_said, sr_said
sr_run(sr_cleared, "20260101T000300Z-ccccccc", dict(sr_blobs, **{"src/a.py": sr_sha("src/a.py")}))
assert sr_answer("src/a.py") == "none"

# The round budget lets a lock go whole (row ap): the second round over a scope is offered no third
# pass, so a lock demanding one is a gate nothing opens — the waiver is refused for being locked and
# the review the refusal names is the pass the budget spent.
sr_spent = sr_store()
sr_first_round = sr_run(sr_spent, "20260101T000100Z-aaaaaaa", sr_blobs,
                        report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
(sr_first_round / rb.FIX_RECEIPT).write_text(json.dumps({"state": "done", "fixed": 2}))
sr_run(sr_spent, "20260101T000200Z-bbbbbbb", sr_blobs,
       report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
assert sr_answer("src/a.py") == "debt 1 other"
assert sr_waive("src/a.py", reason="the budget of two is spent")[0] == 0
# A round the first one never fixed still locks: only a `done` receipt spends the budget.
sr_stopped = sr_store()
sr_stopped_first = sr_run(sr_stopped, "20260101T000100Z-aaaaaaa", sr_blobs,
                          report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
(sr_stopped_first / rb.FIX_RECEIPT).write_text(
    json.dumps({"state": "blocked", "reason": "P1 threshold"}))
sr_run(sr_stopped, "20260101T000200Z-bbbbbbb", sr_blobs,
       report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
assert sr_answer("src/a.py") == "debt 1 other locked"

# A held path that is gone is debt: what the panel read is not standing there any more.
sr_deletions = sr_store()
sr_run(sr_deletions, "20260101T000100Z-aaaaaaa", dict(sr_blobs, **{"docs/b.md": sr_sha("docs/b.md")}))
(sr_repo / "docs" / "b.md").unlink()
assert sr_answer("docs/b.md") == "debt 1 other"
# And a deletion the run READ is settled by it: the snapshot records the path against nothing, and
# nothing is what stands there.
sr_read_deletion = sr_store()
sr_run(sr_read_deletion, "20260101T000200Z-bbbbbbb", dict(sr_blobs, **{"docs/b.md": ""}))
assert sr_answer("docs/b.md") == "none"
# Until something stands there again: the content that replaced it is nobody's review.
(sr_repo / "docs" / "b.md").write_text("back\n")
assert sr_answer("docs/b.md") == "debt 1 other"
subprocess.run(["git", "-C", str(sr_repo), "checkout", "--", "docs/b.md"], check=True)

# The watchdog wins over everything older: a chat waiting on a review that hung is told about the
# kill and not about the debt underneath it.
sr_source.write_text(sr_moved)
sr_timed = sr_store()
sr_run(sr_timed, "20260101T000100Z-aaaaaaa", sr_blobs)
sr_run(sr_timed, "20260101T000200Z-bbbbbbb", triaged=False, timed_out=True)
# Only over something owed: a kill standing above content every artifact already settles demands
# nothing, and reported anyway it is a red statusline no later artifact could ever clear.
assert sr_answer("src/a.py") == "none"
sr_source.write_text(sr_moved + "past the panel\n")
assert sr_answer("src/a.py") == "timed-out 20260101T000200Z-bbbbbbb"
# A hung run of another chat is not this one's answer.
assert sr_answer("src/a.py", session="chat-2") == "debt 1 other"
# A newer run of this chat that nobody judged says nothing, so it may not speak over the kill
# either; only a later triaged run ends it.
sr_run(sr_timed, "20260101T000250Z-eeeeeee", sr_blobs, triaged=False)
assert sr_answer("src/a.py") == "timed-out 20260101T000200Z-bbbbbbb"
sr_run(sr_timed, "20260101T000300Z-ccccccc", dict(sr_blobs, **{"src/a.py": sr_sha("src/a.py")}))
assert sr_answer("src/a.py") == "none"
# The kill masks the verdict, never the listing: a reader asking which paths are in debt is not
# asking what the chat is waiting on.
sr_masked = sr_store()
sr_source.write_text(sr_moved + "drift\n")
sr_run(sr_masked, "20260101T000100Z-aaaaaaa", sr_blobs)
sr_run(sr_masked, "20260101T000200Z-bbbbbbb", triaged=False, timed_out=True)
assert sr_answer("src/a.py") == "timed-out 20260101T000200Z-bbbbbbb"
assert sr_answer("src/a.py", listing=True) == "src/a.py"
# A kill the run's own triage answered is not hung: the findings were judged, nothing is left to
# wait on, and the debt underneath speaks again (seen live: a watchdog-killed cell marked a fully
# triaged and fixed run timed_out, and the statusline shouted timeout over a finished round).
sr_self_answered = sr_store()
sr_run(sr_self_answered, "20260101T000100Z-aaaaaaa", sr_blobs)
sr_run(sr_self_answered, "20260101T000200Z-bbbbbbb", sr_blobs, timed_out=True)
assert sr_answer("src/a.py") == "debt 1 other"
# While an untriaged kill in the same spot still shouts — the answer is the triage, not the age.
sr_untriaged_kill = sr_store()
sr_run(sr_untriaged_kill, "20260101T000100Z-aaaaaaa", sr_blobs)
sr_run(sr_untriaged_kill, "20260101T000200Z-bbbbbbb", triaged=False, timed_out=True)
assert sr_answer("src/a.py") == "timed-out 20260101T000200Z-bbbbbbb"

# Debt is the WORKING TREE's, never the repository behind it: linked worktrees share one git dir,
# and a sibling's paths are named alike while holding entirely different content.
sr_sibling = sr_store()
sr_worktree = work / "session-review-worktree"
subprocess.run(["git", "-C", str(sr_repo), "worktree", "add", "-q", "-b", "sibling",
                str(sr_worktree)], check=True)
sr_run(sr_sibling, "20260101T000100Z-aaaaaaa",
       {"src/a.py": sr_sha("src/a.py", repo=sr_worktree)}, repo=sr_worktree)
assert sr_answer("src/a.py", repo=sr_worktree) == "none"
assert sr_answer("src/a.py") == "debt 1 other"

# A link is its own text and never the file it points at: the run that read the link settles it,
# and a retarget after it is content nobody read.
sr_link_run = sr_store()
(sr_repo / "src" / "link.py").symlink_to("a.py")
assert rb.path_blob_sha(sr_repo, "src/link.py") == sr_link_blobs["src/link.py"]
sr_run(sr_link_run, "20260101T000200Z-bbbbbbb", sr_link_blobs)
assert sr_answer("src/link.py") == "none"
(sr_repo / "src" / "link.py").unlink()
(sr_repo / "src" / "link.py").symlink_to("blob.bin")
assert sr_answer("src/link.py") == "debt 1 other"
# A dangling link is still a link, priced by the text it holds rather than as an absent file.
(sr_repo / "src" / "link.py").unlink()
(sr_repo / "src" / "link.py").symlink_to("nowhere.py")
assert sr_answer("src/link.py") == "debt 1 other"
(sr_repo / "src" / "link.py").unlink()
sr_clear_journals()

# A waiver nobody signed stands over the work with no one to ask about it, so a chat the harness
# cannot name does not get to write one.
sr_unsigned = sr_store()
sr_source.write_text(sr_moved + "unsigned\n")
del os.environ["CLAUDE_CODE_SESSION_ID"]
sr_rc, sr_said = sr_waive("src/a.py", reason="nobody home")
assert sr_rc == 1 and "names the chat" in sr_said, (sr_rc, sr_said)
os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-1"
assert sr_waive("src/a.py", reason="nobody home")[0] == 0
sr_waivers = json.loads((rb.state_dir() / rb.WAIVER_DIR).glob("*.json").__next__().read_text())
assert sr_waivers["waivers"][0]["session"] == "chat-1", sr_waivers

# The gate prints a paste-ready waive command with a placeholder where the reason goes. Pasted
# unedited it records the question as the answer, so that one literal is the reason refused.
sr_placeholder = sr_store()
sr_rc, sr_said = sr_waive("src/a.py", reason=rb.WAIVE_PLACEHOLDER_REASON)
assert sr_rc == 1 and rb.WAIVE_PLACEHOLDER_REASON in sr_said, (sr_rc, sr_said)
sr_rc, sr_said = sr_waive("src/a.py", reason=f"{rb.WAIVE_PLACEHOLDER_REASON}, in one line: a doc typo")
assert (sr_rc, sr_said) == (0, "waived 1 path(s): WHY THIS GOES UNREVIEWED, in one line: a doc typo"), (sr_rc, sr_said)

# A waiver naming no path is the repository's question, and the repository is shared: it settles
# what the journals say is this chat's work and leaves every co-tenant's where it stands.
sr_pathless = sr_store()
sr_source.write_text(sr_moved + "mine\n")
(sr_repo / "docs" / "theirs.md").write_text("their work\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py")
sr_journal(rb.COMMIT_JOURNAL, "chat-2", "docs/theirs.md")
assert sr_answer() == "debt 2 mine 1"
assert sr_waive(reason="mine only") == (
    0, "waived 1 path(s): mine only [src/a.py]")
sr_waivers = json.loads((rb.state_dir() / rb.WAIVER_DIR).glob("*.json").__next__().read_text())
assert list(sr_waivers["waivers"][0]["paths"]) == ["src/a.py"], sr_waivers
assert sr_answer() == "debt 1 other"
# Spelling the co-tenant's path out does not make it this chat's to sign for, and the refusal names
# the path and the chat the journals hand it to.
sr_rc, sr_said = sr_waive("docs/theirs.md", reason="theirs, said out loud")
assert sr_rc == 1 and "docs/theirs.md" in sr_said and "chat-2" in sr_said, (sr_rc, sr_said)
assert sr_answer() == "debt 1 other"
# Their own chat says it, and it stands.
os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-2"
assert sr_waive("docs/theirs.md", reason="theirs, and theirs to say so")[0] == 0
os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-1"
assert sr_answer() == "none"
sr_clear_journals()

# A chat the journals never name owns none of this debt, and refusing is the only answer that does
# not sign somebody else's work away.
sr_stranger = sr_store()
sr_journal(rb.COMMIT_JOURNAL, "chat-2", "src/a.py")
os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-3"
sr_rc, sr_said = sr_waive(reason="not mine")
assert sr_rc == 1 and "--paths" in sr_said and "chat-3" in sr_said, (sr_rc, sr_said)
sr_rc, sr_said = sr_waive("src/a.py", reason="not mine, said out loud")
assert sr_rc == 1 and "src/a.py" in sr_said and "chat-2" in sr_said, (sr_rc, sr_said)
# The chat the journals name and the chat being refused both come back as names, and a chat with
# no name of its own stays the id there is nothing better than. A session id is the on-disk grammar
# and nothing Egor has ever seen: told his work belongs to `chat-2` he cannot tell which
# conversation to go back to, while the name Claude Code gave it stands in his tab title.
sr_named_chat = fixture_home / ".claude-profiles" / "com" / "projects" / "-tmp-proj"
sr_named_chat.mkdir(parents=True, exist_ok=True)
(sr_named_chat / "chat-2.jsonl").write_text(
    json.dumps({"type": "ai-title", "aiTitle": "the owner chat", "sessionId": "chat-2"}) + "\n"
)
(sr_named_chat / "chat-3.jsonl").write_text(
    json.dumps({"type": "ai-title", "aiTitle": "the asking chat", "sessionId": "chat-3"}) + "\n"
)
sr_rc, sr_said = sr_waive("src/a.py", reason="not mine, said out loud")
assert sr_rc == 1 and "the owner chat" in sr_said and "the asking chat" in sr_said, sr_said
sr_rc, sr_said = sr_waive(reason="not mine")
assert sr_rc == 1 and "the asking chat" in sr_said and "chat-3" not in sr_said, sr_said
(sr_named_chat / "chat-3.jsonl").unlink()
sr_rc, sr_said = sr_waive("src/a.py", reason="not mine, said out loud")
assert sr_rc == 1 and "this chat (chat-3)" in sr_said, sr_said
(sr_named_chat / "chat-2.jsonl").unlink()
# One foreign path refuses the whole waiver: a partial one records a decision the caller did not
# make about the paths it dropped.
sr_journal(rb.COMMIT_JOURNAL, "chat-3", "src/blob.bin")
sr_binary.write_bytes(b"\x00\x09")
sr_rc, sr_said = sr_waive("src/a.py", "src/blob.bin", reason="most of it is mine")
assert sr_rc == 1 and "src/blob.bin" not in sr_said, (sr_rc, sr_said)
assert sr_answer("src/blob.bin", session="chat-3") == "debt 1 mine"
sr_binary.write_bytes(b"\x00\x01\x02\x03")
os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-1"
sr_clear_journals()
(sr_repo / "docs" / "theirs.md").unlink()

# A run the watchdog killed was sealed with its whole scope and read part of it. Triaging what came
# back tells the chat that ran it what the panel found, and settles the content of no path for
# anybody — the same run the reader reports as a kill cannot cover the tree behind it.
sr_kill_cover = sr_store()
sr_source.write_text(sr_moved)
sr_run(sr_kill_cover, "20260101T000100Z-aaaaaaa", sr_blobs, timed_out=True)
assert sr_answer("src/a.py", session="chat-2") == "debt 1 other"
sr_run(sr_kill_cover, "20260101T000200Z-bbbbbbb", sr_blobs)
assert sr_answer("src/a.py", session="chat-2") == "none"

# A LOCKED round's artifact postdates every stamp there is: it was written after the work it read,
# so a floor that empties the set disowns exactly the chat that owes the second review.
sr_locked_floor = sr_store()
sr_source.write_text(sr_moved + "locked floor\n")
sr_run(sr_locked_floor, "20280101T000100Z-ccccccc", {"src/a.py": "stale-sha"},
       report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
sr_journal(rb.DEBT_JOURNAL, "chat-1", "src/a.py")
assert sr_answer("src/a.py", session="chat-1") == "debt 1 mine locked"
assert rb.debt_authors(sr_repo, [("src/a.py", {"epoch": 1830000000})]) == {"chat-1"}
sr_clear_journals()

# The journal's original format wrote a bare path and named no session: the path belongs to nobody
# and stays in the universe a repository-wide question asks about, rather than dropping out of it
# with the record it was written in.
sr_legacy = sr_store()
sr_source.write_text(sr_moved + "legacy\n")
with (sr_gitdir / rb.COMMIT_JOURNAL).open("ab") as handle:
    handle.write(b"src/a.py\0")
assert rb.journal_entries(sr_gitdir / rb.COMMIT_JOURNAL) == [("", None, "src/a.py")]
assert "src/a.py" in rb.journal_paths(sr_repo)
assert sr_answer() == "debt 1 other"
assert rb.debt_authors(sr_repo, [("src/a.py", None)]) == set()
# Owned by nobody is not owned by somebody else: a chat may take that debt on, spelled out or not.
assert sr_waive(reason="legacy")[0] == 0
sr_clear_journals()

# Deleting a file nobody reviewed is not how it stops needing a review: with no artifact holding
# it, an absent path hashes to the same nothing an unheld one does, and the journals naming it are
# what keep the removal in view.
sr_deleted_unread = sr_store()
(sr_repo / "docs" / "vanished.md").write_text("about to go\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "docs/vanished.md")
assert sr_answer("docs/vanished.md") == "debt 1 mine"
(sr_repo / "docs" / "vanished.md").unlink()
assert sr_answer("docs/vanished.md") == "debt 1 mine"
assert sr_answer(listing=True).splitlines().count("docs/vanished.md") == 1
# A path no journal names and no artifact holds is still nobody's debt.
assert sr_answer("docs/gone.md") == "none"
# And the run that READ the deletion settles it: the snapshot records the path against nothing,
# and nothing is what stands there.
sr_run(sr_deleted_unread, "20260101T000100Z-aaaaaaa", {"docs/vanished.md": ""})
assert sr_answer("docs/vanished.md") == "none"

# A session field left blank is the same record as one that was never written: the path stays in
# the universe and belongs to nobody, where dropping the row would take the path with it.
sr_blank_session = sr_store()
sr_clear_journals()
sr_source.write_text(sr_moved + "blank\n")
with (sr_gitdir / rb.COMMIT_JOURNAL).open("ab") as handle:
    handle.write(b"\t1750000000\tsrc/a.py\0")
assert rb.journal_entries(sr_gitdir / rb.COMMIT_JOURNAL) == [("", 1750000000, "src/a.py")]
assert "src/a.py" in rb.journal_paths(sr_repo)
assert rb.debt_authors(sr_repo, [("src/a.py", None)]) == set()
assert sr_answer() == "debt 1 other"
# A record holding no path at all is the one that is not a record.
with (sr_gitdir / rb.COMMIT_JOURNAL).open("ab") as handle:
    handle.write(b"chat-1\t1750000000\t\0")
assert rb.journal_entries(sr_gitdir / rb.COMMIT_JOURNAL) == [("", 1750000000, "src/a.py")]
sr_clear_journals()

# A round whose tally nobody can read is not a clean round: read as one it would release whatever
# lock it earned along with the file that failed to parse.
sr_untallied = sr_store()
sr_source.write_text(sr_moved + "untallied\n")
sr_untallied_dir = sr_run(sr_untallied, "20260101T000100Z-aaaaaaa", sr_blobs,
                          report={"confirmed": 0, "confirmed_by_severity": {"P1": 0}})
(sr_untallied_dir / rb.REPORT_RECEIPT).write_text("{ truncated")
assert rb.run_confirmed_counts(sr_untallied_dir) is None
assert sr_answer("src/a.py") == "debt 1 other locked"
sr_rc, sr_said = sr_waive("src/a.py", reason="cannot read its own tally")
assert sr_rc == 1 and "20260101T000100Z-aaaaaaa" in sr_said, (sr_rc, sr_said)
# The memo keeps answers and never that failure, so triaging the run again ends the lock inside the
# same process rather than after the next launch.
(sr_untallied_dir / rb.REPORT_RECEIPT).write_text(
    json.dumps({"confirmed": 1, "confirmed_by_severity": {"P1": 1}})
)
assert rb.run_confirmed_counts(sr_untallied_dir) == (1, 1)
assert sr_answer("src/a.py") == "debt 1 other"

# Fixing a round's findings routinely deletes a file it read, and no later run can ever hold a path
# that is gone: the second review owes the scope still standing, or the lock has no release at all.
sr_gone_scope = sr_store()
(sr_repo / "src" / "doomed.py").write_text("to be deleted\n")
sr_run(sr_gone_scope, "20260101T000100Z-aaaaaaa",
       dict(sr_blobs, **{"src/doomed.py": sr_sha("src/doomed.py")}),
       report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
sr_source.write_text(sr_moved + "fixed\n")
(sr_repo / "src" / "doomed.py").unlink()
assert sr_answer("src/a.py") == "debt 1 other locked"
sr_run(sr_gone_scope, "20260101T000200Z-bbbbbbb",
       {"src/a.py": sr_sha("src/a.py"), "src/blob.bin": sr_blobs["src/blob.bin"]})
assert sr_answer("src/a.py") == "none"
# A path that still stands is owed as it always was: dropping one of those from the rerun is the
# narrow round the lock exists to refuse.
sr_narrow = sr_store()
sr_source.write_text(sr_moved + "narrow\n")
sr_run(sr_narrow, "20260101T000100Z-aaaaaaa", sr_blobs,
       report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
sr_run(sr_narrow, "20260101T000200Z-bbbbbbb", {"src/a.py": sr_sha("src/a.py")})
assert sr_answer("src/a.py") == "debt 1 other locked"

# Paths named and every spelling rejected is not the repository's question: run as the pathless
# form, a waiver aimed at two files would settle everything this chat owns.
sr_rejected = sr_store()
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py")
sr_rc, sr_said = sr_waive("../outside.py", ".", "  ", reason="typo somewhere")
assert sr_rc == 1 and "../outside.py" in sr_said, (sr_rc, sr_said)
assert sr_answer("src/a.py") == "debt 1 mine"
(sr_repo / "src" / "doomed.py").unlink(missing_ok=True)

# A worker a chat spawned IS that chat. Between the worker writing its file list and the commit
# journal sweeping it, the run record is the only place that ownership exists — read as unowned,
# those files are a co-tenant's live work a waiver naming no path would sign away.
sr_claimed = sr_store()
sr_clear_journals()
sr_source.write_text(sr_moved + "a worker wrote this\n")
(sr_repo / "docs" / "worker.md").write_text("worker output\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "docs/worker.md")
sr_worker_run("20260101T0100Z-worker", "chat-2",
              [f"WORKDIR: {sr_repo}", "PARTIAL: shell commands went unrecorded", "src/a.py"])
assert rb.foreign_run_claims(sr_repo, "chat-1") == {
    "src/a.py": ("20260101T0100Z-worker", "chat-2")
}, rb.foreign_run_claims(sr_repo, "chat-1")
# The chat that launched it owns it, so nothing is foreign to that one.
assert rb.foreign_run_claims(sr_repo, "chat-2") == {}
sr_rc, sr_said = sr_waive("src/a.py", reason="not mine to skip")
assert sr_rc == 1 and "20260101T0100Z-worker" in sr_said and "chat-2" in sr_said, (sr_rc, sr_said)
# Naming no path, the claimed one is dropped the way a journal-foreign one is, and the line names
# what the waiver actually took.
assert sr_waive(reason="mine only") == (
    0, "waived 1 path(s): mine only [docs/worker.md]")
assert sr_answer("src/a.py") == "debt 1 other"
# Swept into the journals, the record is history: the journals answer for those files now, and a
# run claimed twice would leave them nobody's to waive at all.
sr_swept = sr_store()
(sr_worker_runs / "20260101T0100Z-worker" / "journaled").write_text("")
assert rb.foreign_run_claims(sr_repo, "chat-1") == {}
assert sr_waive("src/a.py", reason="nobody claims it now")[0] == 0
# What a record does not name it does not claim: a reason line is not a path, a relative path with
# no workdir has nothing to anchor it, and an absolute path outside this repository is another
# tree's. A record missing its launcher or its list claims nothing at all.
sr_worker_run("20260101T0200Z-noise", "chat-2",
              ["WORKDIR: /nowhere", "UNKNOWN: the vendor keeps no per-file record"])
sr_worker_run("20260101T0300Z-bare", "chat-2", ["src/a.py"])
sr_worker_run("20260101T0400Z-outside", "chat-2",
              [f"WORKDIR: {sr_repo}", "/etc/hosts", str(sr_repo / "docs" / "b.md")])
sr_worker_run("20260101T0500Z-nolauncher", None, [f"WORKDIR: {sr_repo}", "src/a.py"])
sr_worker_run("20260101T0600Z-nofiles", "chat-2", None)
assert rb.foreign_run_claims(sr_repo, "chat-1") == {
    "docs/b.md": ("20260101T0400Z-outside", "chat-2")
}, rb.foreign_run_claims(sr_repo, "chat-1")

# A path the journals hand to nobody is waivable, and the line says so out loud: a chat has to see
# that it just signed for work no record names as its own.
sr_unowned_line = sr_store()
sr_clear_journals()
sr_source.write_text(sr_moved + "nobody named it\n")
with (sr_gitdir / rb.COMMIT_JOURNAL).open("ab") as handle:
    handle.write(b"src/a.py\0")
assert sr_waive(reason="a legacy row, and mine now") == (
    0, "waived 1 path(s): a legacy row, and mine now [src/a.py (no journal author)]")
(sr_repo / "docs" / "worker.md").unlink()

# A round's fixes routinely delete a file it read, and no snapshot a later run writes can hold a
# path that is gone: left locked, that path outlives every review and every waiver a chat could
# answer it with, while the deletion is exactly what a reasoned waiver settles.
sr_deleted_lock = sr_store()
sr_clear_journals()
(sr_repo / "src" / "pair.py").write_text("the other path of the round\n")
sr_source.write_text(sr_moved + "the locked round read this\n")
sr_run(sr_deleted_lock, "20260101T000100Z-aaaaaaa",
       {"src/a.py": sr_sha("src/a.py"), "src/pair.py": sr_sha("src/pair.py")},
       report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
sr_source.write_text(sr_moved + "and then the fixes\n")
(sr_repo / "src" / "pair.py").unlink()
assert sr_answer("src/a.py") == "debt 1 other locked"
assert sr_answer("src/pair.py") == "debt 1 other"
assert sr_answer("src/a.py", "src/pair.py") == "debt 2 other locked"
assert sr_waive("src/pair.py", reason="the fixes deleted it")[0] == 0
assert sr_answer("src/pair.py") == "none"
# The path still standing is owed as it always was.
sr_rc, sr_said = sr_waive("src/a.py", reason="and this one along with it")
assert sr_rc == 1 and "20260101T000100Z-aaaaaaa" in sr_said, (sr_rc, sr_said)

# A worker THIS chat launched is this chat: until the commit journal sweeps its record, the
# journals name nobody for those files, and counted as nobody's they read to the chat that ordered
# the work like a co-tenant's.
sr_own_run = sr_store()
sr_clear_journals()
sr_source.write_text(sr_moved + "my own worker wrote this\n")
(sr_repo / "docs" / "co.md").write_text("a co-tenant's file\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-2", "docs/co.md")
sr_worker_run("20260101T0700Z-mine", "chat-1", [f"WORKDIR: {sr_repo}", "src/a.py"])
assert sr_answer("src/a.py") == "debt 1 mine"
assert sr_answer("src/a.py", "docs/co.md") == "debt 2 mine 1"
# Somebody else's run of the same file is somebody else's.
assert sr_answer("src/a.py", session="chat-3") == "debt 1 other"
# Swept, the record is history and the journals answer — which name nobody here.
(sr_worker_runs / "20260101T0700Z-mine" / "journaled").write_text("")
assert sr_answer("src/a.py") == "debt 1 other"
(sr_repo / "docs" / "co.md").unlink()

# Both commands answer one question. A path two chats' workers wrote is both chats' work, and a
# path the journals hand to a co-tenant while this chat's own worker also wrote it is this chat's
# too — read one way by the counter and another by the waiver, one command calls a path this chat's
# while the other refuses to sign for it.
sr_shared_claim = sr_store()
sr_clear_journals()
sr_source.write_text(sr_moved + "two workers wrote this\n")
sr_worker_run("20260101T0800Z-theirs", "chat-2", [f"WORKDIR: {sr_repo}", "src/a.py"])
sr_worker_run("20260101T0810Z-ours", "chat-1", [f"WORKDIR: {sr_repo}", "src/a.py"])
assert "src/a.py" not in rb.foreign_run_claims(sr_repo, "chat-1")
assert "src/a.py" not in rb.foreign_run_claims(sr_repo, "chat-2")
# To a third chat it is both of theirs, named by the first run that wrote it.
assert rb.foreign_run_claims(sr_repo, "chat-3")["src/a.py"] == ("20260101T0800Z-theirs", "chat-2")
assert sr_answer("src/a.py") == "debt 1 mine"
assert sr_waive("src/a.py", reason="ours as much as theirs")[0] == 0
# Pathless, it is not dropped as somebody else's either.
sr_pathless_claim = sr_store()
sr_run(sr_pathless_claim, "20260101T000100Z-aaaaaaa", sr_blobs)
assert sr_waive(reason="ours as much as theirs") == (
    0, "waived 1 path(s): ours as much as theirs [src/a.py (no journal author)]")

# The journals naming another chat is not the last word while this chat's own run is still unswept:
# the two stores are read together, or the counter and the waiver disagree about one path.
sr_journal_vs_run = sr_store()
sr_journal(rb.COMMIT_JOURNAL, "chat-2", "src/a.py")
assert sr_answer("src/a.py") == "debt 1 mine"
assert sr_waive("src/a.py", reason="my worker wrote it after theirs")[0] == 0
sr_clear_journals()

# And a path only a co-tenant's run wrote is still theirs, named by the run that wrote it.
sr_theirs_only = sr_store()
(sr_worker_runs / "20260101T0810Z-ours" / "journaled").write_text("")
assert sr_answer("src/a.py") == "debt 1 other"
sr_rc, sr_said = sr_waive("src/a.py", reason="not mine at all")
assert sr_rc == 1 and "20260101T0800Z-theirs" in sr_said and "chat-2" in sr_said, (sr_rc, sr_said)
# And a run record's launcher is named the same way (share/chat_names.py), never by its raw id.
(sr_named_chat / "chat-2.jsonl").write_text(
    json.dumps({"type": "ai-title", "aiTitle": "make review bench simpler", "sessionId": "chat-2"})
    + "\n"
)
sr_rc, sr_said = sr_waive("src/a.py", reason="not mine at all")
assert sr_rc == 1 and "make review bench simpler" in sr_said, (sr_rc, sr_said)
assert "chat-2" not in sr_said, sr_said
(sr_named_chat / "chat-2.jsonl").unlink()
(sr_worker_runs / "20260101T0800Z-theirs" / "journaled").write_text("")

# A worker that edited through the shell alone lists no file in its record, while its own hooks
# journaled every one of those edits under the WORKER's session — an id no chat here would
# otherwise recognise, so the launcher read its own worker's work as a co-tenant's (live case
# 2026-08-20). The run record is the only place the two ids stand together.
sr_worker_journal = sr_store()
sr_clear_journals()
sr_source.write_text(sr_moved + "the worker edited this through the shell\n")
sr_journal(rb.COMMIT_JOURNAL, "worker-sess-1", "src/a.py")
sr_worker_run("20260101T0900Z-shell", "chat-1",
              [f"WORKDIR: {sr_repo}", "PARTIAL: shell commands went unrecorded"],
              worker="worker-sess-1")
assert rb.worker_session_launchers()["worker-sess-1"] == "chat-1"
assert sr_answer("src/a.py") == "debt 1 mine"
# The worker's own session is an author too, never replaced by its launcher: the gate inside that
# worker asks this same question under that id, and answered `other` it would refuse the session a
# waiver over the work it just did.
assert sr_answer("src/a.py", session="worker-sess-1") == "debt 1 mine"
# To anyone else it is still somebody's, and the launcher is who they are told to ask.
assert sr_answer("src/a.py", session="chat-3") == "debt 1 other"
# Named, that owner is named ONCE: the worker and the chat that launched it are one conversation
# to go back to, and printed twice they read as two chats to ask.
(sr_named_chat / "chat-1.jsonl").write_text(
    json.dumps({"type": "ai-title", "aiTitle": "the launching chat", "sessionId": "chat-1"}) + "\n"
)
os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-3"
sr_rc, sr_said = sr_waive("src/a.py", reason="not mine")
assert sr_rc == 1 and sr_said.count("the launching chat") == 1, sr_said
os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-1"
(sr_named_chat / "chat-1.jsonl").unlink()
# And the launcher may waive it: refused a name of its own, the chat that ordered the work could
# neither review it nor sign for it — the run's listing names no path to fall back on.
assert sr_waive("src/a.py", reason="my own worker wrote it")[0] == 0
# The `journaled` marker retires the LISTING and nothing else: nothing ever renames what the
# worker's session journaled, so the mapping outlives the sweep.
sr_worker_swept = sr_store()
sr_source.write_text(sr_moved + "and swept\n")
(sr_worker_runs / "20260101T0900Z-shell" / "journaled").write_text("")
assert sr_answer("src/a.py") == "debt 1 mine"
# A record naming no launcher maps nothing: the worker session stays the only author there is.
sr_worker_nolauncher = sr_store()
sr_clear_journals()
sr_source.write_text(sr_moved + "nobody launched it\n")
sr_journal(rb.COMMIT_JOURNAL, "worker-sess-4", "src/a.py")
sr_worker_run("20260101T1000Z-anon", None, None, worker="worker-sess-4")
assert "worker-sess-4" not in rb.worker_session_launchers()
assert sr_answer("src/a.py") == "debt 1 other"
sr_clear_journals()

# A `--resume` run repeats one worker id across launches. Two CHATS resuming the same worker
# session share an id whose entries nothing here divides between them, and handed to both it gives
# each chat a waiver over the other chat's work — so the ambiguous id maps to nobody.
sr_worker_shared = sr_store()
sr_source.write_text(sr_moved + "two chats resumed one worker\n")
sr_journal(rb.COMMIT_JOURNAL, "worker-sess-5", "src/a.py")
sr_worker_run("20260101T1100Z-first", "chat-1",
              [f"WORKDIR: {sr_repo}", "PARTIAL: shell commands went unrecorded"],
              worker="worker-sess-5")
sr_worker_run("20260101T1110Z-second", "chat-2",
              [f"WORKDIR: {sr_repo}", "PARTIAL: shell commands went unrecorded"],
              worker="worker-sess-5")
assert "worker-sess-5" not in rb.worker_session_launchers()
assert sr_answer("src/a.py", session="chat-1") == "debt 1 other"
assert sr_answer("src/a.py", session="chat-2") == "debt 1 other"
assert sr_waive("src/a.py", reason="my worker wrote it")[0] == 1
# The same id resumed twice by ONE chat is not ambiguous, and stays that chat's own.
sr_worker_resumed = sr_store()
sr_clear_journals()
sr_source.write_text(sr_moved + "one chat resumed its own worker\n")
sr_journal(rb.COMMIT_JOURNAL, "worker-sess-6", "src/a.py")
sr_worker_run("20260101T1200Z-first", "chat-1", None, worker="worker-sess-6")
sr_worker_run("20260101T1210Z-again", "chat-1", None, worker="worker-sess-6")
assert rb.worker_session_launchers()["worker-sess-6"] == "chat-1"
assert sr_answer("src/a.py", session="chat-1") == "debt 1 mine"
sr_clear_journals()

# --- debt --split: the same debt in DIFF LINES, split by whose it is --------------------------
# What the statusline says. Per path the number is the diff between the content the artifact
# covering it recorded and the content standing there now — counted by the differ the review target
# header prints its `N file(s) · M line(s)` with, so the label and the header price one edit alike.
def sr_split(*paths, session="chat-1", repo=None):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = rb.cmd_debt(argparse.Namespace(
            repo=str(repo or sr_repo), session=session, paths=list(paths),
            list=False, split=True,
        ))
    assert rc == 0, rc
    return out.getvalue().strip()


# --- the work a shell edit leaves nowhere else ------------------------------------------------
# A worker working through the shell — `sed -i`, a redirect, a heredoc — writes no editor tool call
# into its transcript, so its files reach the run listing, the journals and the artifacts alike as
# nothing at all. Asked about such a path by name the tool priced it correctly the whole time;
# asked what this repository owes, it answered over a universe those files were in no store of, and
# a merged panel scoped straight past two rewritten files (live case 2026-08-21). The run's own
# workdir dirt is the only record that they changed.
sr_shell_dirt = sr_store()
sr_clear_journals()
(sr_repo / "src" / "shell-edited.py").write_text("one\ntwo\n")
assert sr_answer("src/shell-edited.py") == "debt 1 other"
assert "src/shell-edited.py" not in sr_answer(listing=True).splitlines()
sr_dirt_run = sr_worker_run(
    "20260101T1400Z-dirt", "chat-1",
    [f"WORKDIR: {sr_repo}", "PARTIAL: the run also ran shell commands"],
    dirty=[f"WORKDIR: {sr_repo}", "src/shell-edited.py"], finished=True,
)
assert "src/shell-edited.py" in sr_answer(listing=True).splitlines()
# The review a `--debt` round runs is over exactly that list, and a scope that cannot reach the
# path is the same silence one directory further on.
assert "src/shell-edited.py" in dict(rb.debt_review_scope(sr_repo)), rb.debt_review_scope(sr_repo)
# Owned by NOBODY, and that is the whole of what the snapshot may claim: `git status` answers for a
# shared checkout, so a name attached here would hand the launcher a waiver over whatever a
# co-tenant happened to have open. Anonymous debt is answerable by whoever looks at it;
# misattributed debt is answered by the wrong chat or by no one.
assert sr_split("src/shell-edited.py", session="chat-1") == "split 0 0 2"
assert sr_split("src/shell-edited.py", session="chat-2") == "split 0 0 2"
assert "src/shell-edited.py" not in rb.session_run_paths(sr_repo, "chat-1")
assert "src/shell-edited.py" not in rb.foreign_run_claims(sr_repo, "chat-2")
# A co-tenant's own dirt lands in the very same `git status`, and the store that names an owner for
# it outranks the snapshot that names none: reported as nobody's, work whose author is written down
# right there would go unasked for.
(sr_repo / "src" / "cotenant-dirt.py").write_text("co\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-2", "src/cotenant-dirt.py")
(sr_dirt_run / "dirty").write_text(
    f"WORKDIR: {sr_repo}\nsrc/shell-edited.py\nsrc/cotenant-dirt.py\n"
)
assert sr_split("src/cotenant-dirt.py", session="chat-1") == "split 0 1 0"
assert sr_split("src/cotenant-dirt.py", session="chat-2") == "split 1 0 0"
sr_clear_journals()
# A run still writing has a snapshot that is still moving, and priced now half a run's dirt reads
# as the whole of it. The exit code is the run's own statement that it is over — the same evidence
# every other reader of these records waits for.
(sr_dirt_run / "exit_code").unlink()
assert "src/shell-edited.py" not in sr_answer(listing=True).splitlines()
(sr_dirt_run / "exit_code").write_text("0\n")
# The `journaled` marker retires a run's LISTING and nothing else: no sweep will ever name a path
# the listing never held, so the snapshot outlives it exactly as the worker-session mapping does.
(sr_dirt_run / "journaled").write_text("")
assert "src/shell-edited.py" in sr_answer(listing=True).splitlines()

# The listing itself is a store of the same kind, and it was read for ownership while the universe
# was built without it: a path a worker named that no journal has swept yet and no artifact ever
# held was in no count, no `--list` and no `--debt` scope either.
(sr_repo / "src" / "listed-by-the-run.py").write_text("listed\n")
sr_worker_run("20260101T1500Z-listed", "chat-2",
              [f"WORKDIR: {sr_repo}", "src/listed-by-the-run.py"])
assert "src/listed-by-the-run.py" in sr_answer(listing=True).splitlines()
# And it carries an owner, so it is that chat's rather than nobody's.
assert sr_split("src/listed-by-the-run.py", session="chat-1") == "split 0 1 0"
assert sr_split("src/listed-by-the-run.py", session="chat-2") == "split 1 0 0"
shutil.rmtree(sr_worker_runs / "20260101T1500Z-listed")

# A workdir that is a checkout of its OWN inside this one — the in-repo worktree convention
# `<repo>/.claude/worktrees/<name>` — reads as this repository's by spelling alone. The journals
# never crossed a checkout to reach it, each holding the paths of one git dir, and folded in here
# another tree's files (which this repository's git does not track at all) are counted as this
# repository's debt and a `--debt` round is scoped over paths its panel can never read.
sr_nested = sr_repo / ".claude" / "worktrees" / "ticket-1"
(sr_nested / "src").mkdir(parents=True)
(sr_nested / ".git").write_text("gitdir: %s/.git/worktrees/ticket-1\n" % sr_repo)
(sr_nested / "src" / "another-tree.py").write_text("elsewhere\n")
sr_nested_run = sr_worker_run(
    "20260101T1600Z-nested", "chat-1",
    [f"WORKDIR: {sr_nested}", "PARTIAL: the run also ran shell commands",
     "src/named-in-another-tree.py"],
    dirty=[f"WORKDIR: {sr_nested}", "src/another-tree.py"], finished=True,
)
(sr_nested / "src" / "named-in-another-tree.py").write_text("elsewhere too\n")
sr_nested_listing = sr_answer(listing=True).splitlines()
for sr_nested_path in ("src/another-tree.py", "src/named-in-another-tree.py"):
    assert ".claude/worktrees/ticket-1/" + sr_nested_path not in sr_nested_listing, sr_nested_listing
shutil.rmtree(sr_nested_run)
shutil.rmtree(sr_repo / ".claude")
rb.nested_working_tree.cache_clear()

shutil.rmtree(sr_dirt_run)
for sr_dirt_path in ("src/shell-edited.py", "src/cotenant-dirt.py", "src/listed-by-the-run.py"):
    (sr_repo / sr_dirt_path).unlink()
sr_clear_journals()

sr_split_store = sr_store()
sr_clear_journals()
sr_source.write_text("".join(f"line {n}\n" for n in range(1, 21)))
sr_run(sr_split_store, "20260101T000100Z-aaaaaaa", {"src/a.py": sr_sha("src/a.py")})
# Nothing owed is one shape too: the translator switches on the counts, never on which line came.
assert sr_split("src/a.py") == "split 0 0 0"
# Three lines past what the run read is three lines of debt, whatever the size of the file holding
# them: the base is the artifact's content and never the whole file.
sr_source.write_text("".join(f"line {n}\n" for n in range(1, 21)) + "one\ntwo\nthree\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py")
assert sr_answer("src/a.py") == "debt 1 mine"
assert sr_split("src/a.py") == "split 3 0 0"
# The same debt read by the chat that did not write it, and by a reader who named no chat at all.
assert sr_split("src/a.py", session="chat-2") == "split 0 3 0"
assert sr_split("src/a.py", session="") == "split 0 3 0"
# A path no artifact holds has no recorded side to compare, so it is in debt WHOLE: its own line
# count, which is what a file nobody has ever read is worth reviewing as.
(sr_repo / "src" / "fresh.py").write_text("a\nb\nc\nd\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/fresh.py")
assert sr_split("src/a.py", "src/fresh.py") == "split 7 0 0"
# A held path that is gone counts the content it lost, on the same comparison read the other way.
# Recorded AND readable, because a live artifact's blobs are in the store: the snapshot commit that
# sealed the run wrote them, and comparing against one nothing can read is the case below instead.
def sr_written_sha(path, repo=None):
    return subprocess.run(
        ["git", "-C", str(repo or sr_repo), "hash-object", "-w", "--",
         str((repo or sr_repo) / path)],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


(sr_repo / "src" / "held.py").write_text("held one\nheld two\n")
sr_run(sr_split_store, "20260101T000200Z-bbbbbbb", {"src/held.py": sr_written_sha("src/held.py")})
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/held.py")
assert sr_split("src/held.py") == "split 0 0 0"
(sr_repo / "src" / "held.py").unlink()
assert sr_split("src/held.py") == "split 2 0 0"
# A recorded blob this store can no longer read is the unheld case: there is nothing to compare
# against, so the file counts whole, exactly as the debt snapshot drops such a path from its base.
(sr_repo / "src" / "held.py").write_text("held one\nheld two\nheld three\n")
sr_run(sr_split_store, "20260101T000300Z-ccccccc", {"src/held.py": "0" * 40})
assert sr_split("src/held.py") == "split 3 0 0"
(sr_repo / "src" / "held.py").unlink()
# Lines is what the unit means: a binary file's change has none, exactly as the review header
# prices it, and a repository owing nothing else says nothing in the statusline.
sr_binary.write_bytes(b"\x00\x09\x0a")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/blob.bin")
assert sr_answer("src/blob.bin") == "debt 1 mine"
assert sr_split("src/blob.bin") == "split 0 0 0"
sr_binary.write_bytes(b"\x00\x01\x02\x03")

# Debt no journal entry names and no run record claims belongs to NOBODY, and it is the reason
# this answer has a third number. Live 2026-08-20: `debt` said `mine` for a repository whose
# co-tenant work was journaled nowhere, so the chat read another chat's files as its own to answer
# for. The gate folds this into the foreign side; here it stays visible.
(sr_repo / "src" / "cotenant.py").write_text("co\ntenant\n")
assert sr_answer("src/a.py", "src/cotenant.py") == "debt 2 mine 1"
assert sr_split("src/a.py", "src/cotenant.py") == "split 3 0 2"
# Claimed by a co-tenant's unswept run it is that chat's, not nobody's: the run record is where
# that ownership lives until the journals sweep it (shared-invariants row `am`).
sr_worker_run("20260101T1300Z-cotenant", "chat-2",
              [f"WORKDIR: {sr_repo}", "src/cotenant.py"])
assert sr_split("src/a.py", "src/cotenant.py") == "split 3 2 0"
# And a run THIS chat launched makes it this chat's, as the verdict word already folds it.
assert sr_split("src/a.py", "src/cotenant.py", session="chat-2") == "split 2 3 0"
(sr_worker_runs / "20260101T1300Z-cotenant" / "journaled").write_text("")
assert sr_split("src/a.py", "src/cotenant.py") == "split 3 0 2"
# A journal entry naming the co-tenant does the same thing through the other store.
sr_journal(rb.COMMIT_JOURNAL, "chat-2", "src/cotenant.py")
assert sr_split("src/a.py", "src/cotenant.py") == "split 3 2 0"

# The counts are cached on the two contents that decide them and on nothing else — never on the run
# id, which moves while the content does not — or the statusline would diff every debt path on
# every render inside its ~3s budget.
sr_cache_file = rb.state_dir() / rb.DEBT_LINE_CACHE_FILE
sr_cache_key = "%s:%s" % (
    rb.covering_artifacts(sr_repo)["src/a.py"]["shas"]["src/a.py"],
    rb.path_blob_sha(sr_repo, "src/a.py"),
)
assert json.loads(sr_cache_file.read_text())[sr_cache_key] == 3, sr_cache_file.read_text()
# Read back rather than measured again: a planted count is what the answer follows.
sr_cache_file.write_text(json.dumps({sr_cache_key: 41}))
rb.DEBT_LINE_CACHE = None
assert sr_split("src/a.py") == "split 41 0 0"
# And it can never answer for a pair it was not measured on: the edit moves the working sha, which
# is half the key, so the planted entry is simply not this question's.
sr_source.write_text("".join(f"line {n}\n" for n in range(1, 21)) + "one\ntwo\nthree\nfour\n")
assert sr_split("src/a.py") == "split 4 0 0"
rb.DEBT_LINE_CACHE = None
assert json.loads(sr_cache_file.read_text())[sr_cache_key] == 41, sr_cache_file.read_text()
# A recorded blob this store cannot read is compared as an absence and KEYED as one. The cache file
# is one machine's while an object store is one checkout's, so an entry naming a blob this
# repository could not produce would hand the whole-file number to the checkout that still holds it.
(sr_repo / "src" / "ghost.py").write_text("g1\ng2\ng3\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/ghost.py")
sr_run(sr_split_store, "20260101T000400Z-ddddddd", {"src/ghost.py": "0" * 40})
assert sr_split("src/ghost.py") == "split 3 0 0"
sr_ghost_entries = json.loads(sr_cache_file.read_text())
assert sr_ghost_entries[":%s" % rb.path_blob_sha(sr_repo, "src/ghost.py")] == 3, sr_ghost_entries
assert not [key for key in sr_ghost_entries if key.startswith("0" * 40)], sr_ghost_entries
# A path that is GONE has no current side, and the key says so with the same empty string the
# lookup asks with. Hashed as an empty FILE instead, every deleted debt path files an entry nothing
# can ever ask for and is re-diffed on every render while that entry crowds the window.
(sr_repo / "src" / "gone.py").write_text("g1\ng2\ng3\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/gone.py")
sr_run(sr_split_store, "20260101T000500Z-eeeeeee",
       {"src/gone.py": sr_written_sha("src/gone.py")})
sr_gone_recorded = rb.covering_artifacts(sr_repo)["src/gone.py"]["shas"]["src/gone.py"]
(sr_repo / "src" / "gone.py").unlink()
assert sr_split("src/gone.py") == "split 3 0 0"
sr_gone_entries = json.loads(sr_cache_file.read_text())
assert sr_gone_entries["%s:" % sr_gone_recorded] == 3, sr_gone_entries
sr_cache_file.write_text(json.dumps({"%s:" % sr_gone_recorded: 44}))
rb.DEBT_LINE_CACHE = None
assert sr_split("src/gone.py") == "split 44 0 0"
# A recorded blob of zero length is a measurement like any other, and read back it looks exactly
# like the one thing that is not — a blob this store lost. Skipped, an emptied file's debt is
# measured again on every render.
(sr_repo / "src" / "empty.py").write_text("")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/empty.py")
sr_run(sr_split_store, "20260101T000600Z-fffffff",
       {"src/empty.py": sr_written_sha("src/empty.py")})
sr_empty_recorded = rb.covering_artifacts(sr_repo)["src/empty.py"]["shas"]["src/empty.py"]
(sr_repo / "src" / "empty.py").write_text("e1\ne2\n")
assert sr_split("src/empty.py") == "split 2 0 0"
sr_empty_key = "%s:%s" % (sr_empty_recorded, rb.path_blob_sha(sr_repo, "src/empty.py"))
assert json.loads(sr_cache_file.read_text())[sr_empty_key] == 2, sr_cache_file.read_text()
# And the loss it is told apart from: a store can drop the object between the reachability read and
# the read that measures, and the whole file counted against nothing must never be written down
# under the sha of the content it was not compared with.
(sr_repo / "src" / "lost.py").write_text("l1\nl2\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/lost.py")
sr_run(sr_split_store, "20260101T000700Z-ggggggg",
       {"src/lost.py": sr_written_sha("src/lost.py")})
sr_lost_recorded = rb.covering_artifacts(sr_repo)["src/lost.py"]["shas"]["src/lost.py"]
(sr_repo / "src" / "lost.py").write_text("l1\nl2\nl3\n")
sr_real_blob_bytes = rb.blob_bytes
rb.blob_bytes = lambda repo, sha: b""
assert sr_split("src/lost.py") == "split 3 0 0"
rb.blob_bytes = sr_real_blob_bytes
sr_lost_entries = json.loads(sr_cache_file.read_text())
assert not [key for key in sr_lost_entries if key.startswith(sr_lost_recorded)], sr_lost_entries
(sr_repo / "src" / "empty.py").unlink()
(sr_repo / "src" / "lost.py").unlink()
rb.DEBT_LINE_CACHE = None
# A path this repository's attributes take out of diffing is priced as the review target header
# prices it — no lines — and is the one answer here never written down: the comparison is of two
# files OUTSIDE the repository, which no `.gitattributes` pattern can name, and an attribute
# belongs to a checkout while the cache is shared by every checkout on the machine.
(sr_repo / ".gitattributes").write_text("src/bundle.js -diff\n")
(sr_repo / "src" / "bundle.js").write_text("b1\nb2\nb3\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/bundle.js")
assert sr_split("src/bundle.js") == "split 0 0 0"
sr_attr_entries = json.loads(sr_cache_file.read_text())
sr_bundle_sha = rb.path_blob_sha(sr_repo, "src/bundle.js")
assert not [key for key in sr_attr_entries if key.endswith(sr_bundle_sha)], sr_attr_entries
(sr_repo / ".gitattributes").unlink()
assert sr_split("src/bundle.js") == "split 3 0 0"
# An error is not a measurement. Written down it would answer for these two contents for as long
# as both of them stand, long after whatever failed here stopped failing.
sr_real_numstat = rb.diff_numstat


def sr_failing_numstat(*args, **kwargs):
    raise RuntimeError("git diff failed")


(sr_repo / "src" / "flaky.py").write_text("f1\nf2\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/flaky.py")
rb.diff_numstat = sr_failing_numstat
assert sr_split("src/flaky.py") == "split 0 0 0"
rb.diff_numstat = sr_real_numstat
rb.DEBT_LINE_CACHE = None
assert sr_split("src/flaky.py") == "split 2 0 0"
# Fresh measurements are persisted as they are made and not at the end alone: the gate asks this
# under a timeout, and a first pass over a cold cache killed before its last path would otherwise
# leave nothing behind and start again from zero on the render after it.
sr_batch_paths = [f"src/batch{n}.py" for n in range(3)]
for sr_index, sr_name in enumerate(sr_batch_paths):
    (sr_repo / sr_name).write_text("".join(f"b{sr_index} {n}\n" for n in range(sr_index + 1)))
    sr_journal(rb.COMMIT_JOURNAL, "chat-1", sr_name)
sr_measured = []


def sr_interrupted_numstat(*args, **kwargs):
    sr_measured.append(1)
    if len(sr_measured) > 1:
        raise KeyboardInterrupt
    return sr_real_numstat(*args, **kwargs)


sr_real_batch = rb.DEBT_LINE_CACHE_BATCH
rb.DEBT_LINE_CACHE_BATCH = 1
rb.diff_numstat = sr_interrupted_numstat
try:
    sr_split(*sr_batch_paths)
    raise AssertionError("the interrupted pass answered")
except KeyboardInterrupt:
    pass
rb.diff_numstat = sr_real_numstat
rb.DEBT_LINE_CACHE_BATCH = sr_real_batch
rb.DEBT_LINE_CACHE = None
assert json.loads(sr_cache_file.read_text()).get(
    ":%s" % rb.path_blob_sha(sr_repo, sr_batch_paths[0])
) == 1, sr_cache_file.read_text()
for sr_name in sr_batch_paths + ["src/ghost.py", "src/bundle.js", "src/flaky.py"]:
    (sr_repo / sr_name).unlink()

# A repository the reader cannot resolve owes nothing it can name, and it says so in the one shape.
assert sr_split(repo=work / "session-review-not-a-repo") == "split 0 0 0"
(sr_repo / "src" / "fresh.py").unlink()
(sr_repo / "src" / "cotenant.py").unlink()
sr_clear_journals()

# --- A clean round covers the bytes its own fixing pass wrote ---------------------------------
# A round that closed under both of the gate's dials earns no second review, so nothing will ever
# read its fixes: left in debt they are a waiver every chat after this one would have to know to
# write, over work the done receipt already answers for. Five guards keep that receipt off
# everybody else's bytes — the window, the session, the scope, a pass that fixed nothing, and a
# round the gate did not close.
sr_fix_gate = work / "session-review-flow-gate.sh"
# The two dials and the wording are the gate's alone (shared-invariants row af), so the round
# outcome is taken from a stub of it: what the live gate says today is not this suite's to depend on.
sr_fix_gate.write_text(
    "#!/bin/bash\n"
    '[ "$1" = escalation-verdict ] || exit 1\n'
    '[ "${2:-0}" -ge 3 ] || [ "${3:-0}" -gt 8 ] || exit 1\n'
    "printf 'stub fork. Pick one and carry it out:\\n'\n"
)
sr_fix_gate.chmod(0o755)
sr_gate_before = rb.ESCALATION_GATE
rb.ESCALATION_GATE = sr_fix_gate
sr_fix_worker_runs = work / "session-review-fix-worker-runs"
sr_fix_worker_runs.mkdir()
os.environ["WORKER_RUN_DIR"] = str(sr_fix_worker_runs)
sr_fix_sealed = int(time.time()) - 300
sr_fix_edit = sr_fix_sealed + 60
sr_big = (sr_repo / "docs" / "big.md").read_text()


def sr_stamp(epoch):
    return rb.datetime.fromtimestamp(epoch, rb.timezone.utc).isoformat()


def sr_fix_run(benches, reviewed=None, run_id="20260601T000000Z-fixcover", judged=("P2", 1),
               **kwargs):
    """A triaged round the gate closes, with a finding on record for its pass to have fixed: a
    receipt answering nobody covers nothing, so a scenario about coverage needs a real triage.
    """
    directory = sr_run(benches, run_id, reviewed or {"src/a.py": sr_blobs["src/a.py"]},
                       sealed_at=sr_stamp(sr_fix_sealed), **kwargs)
    if judged:
        sr_judged(directory, *judged)
    return directory


def sr_fixes(run_id="20260601T000000Z-fixcover", fixed=1, fp=0, blocked=None):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = rb.cmd_fixes(argparse.Namespace(
            run_id=run_id, blocked=blocked,
            **({"fixed": None, "fp": None} if blocked else {"fixed": fixed, "fp": fp}),
        ))
    return rc, out.getvalue().strip()


def sr_judged(run_dir, severity, count):
    """A triage of `count` confirmed findings at one severity, joined the way the gate's numbers
    are: the verdict rows alone carry no severity, so a tally is only readable through the
    findings beside them.
    """
    (run_dir / "findings-oc-kimik3.jsonl").write_text("".join(
        json.dumps({"file": "src/a.py", "line": n + 1, "severity": severity,
                    "summary": f"finding {n}"}) + "\n"
        for n in range(count)
    ))
    (run_dir / "verdicts.jsonl").write_text("".join(
        json.dumps({"rater": "oc-kimik3", "idx": n, "verdict": "confirmed"}) + "\n"
        for n in range(count)
    ))


sr_covered_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_covered_fixes)
assert sr_answer("src/a.py") == "none"
sr_source.write_text(sr_moved + "the fixing pass answered a finding\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
assert sr_answer("src/a.py") == "debt 1 mine"
sr_covered_rc, sr_covered_out = sr_fixes()
assert sr_covered_rc == 0 and "1 fixed path(s) covered" in sr_covered_out, sr_covered_out
assert sr_answer("src/a.py") == "none"
assert sr_answer() == "none"
# At the shas the fix left behind and no further, exactly as a waiver stands: the next edit over
# them is debt again, and the round that closed answers for none of it.
sr_source.write_text(sr_moved + "and then somebody kept typing\n")
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# The shas are taken BEFORE the journals, so a write landing between the two readings is outside
# the sha this receipt covers rather than inside it with no entry to disqualify it. Staged by
# writing the file from the journal reader itself: read in the other order, the co-tenant's bytes
# below would be the ones covered, and the path would come back settled.
sr_race_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_race_fixes)
sr_source.write_text(sr_moved + "the fixing pass answered a finding\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
sr_race_rows = rb.journal_rows


def sr_racing_journal_rows(repo):
    sr_source.write_text(sr_moved + "a co-tenant typed between the two readings\n")
    return sr_race_rows(repo)


rb.journal_rows = sr_racing_journal_rows
try:
    assert sr_fixes()[0] == 0
finally:
    rb.journal_rows = sr_race_rows
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# A worker this chat launched IS this chat (row am), so what it journaled under its own id is the
# fixing session's own bytes.
sr_worker_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_worker_fixes)
sr_source.write_text(sr_moved + "the worker this chat launched fixed it\n")
sr_journal(rb.COMMIT_JOURNAL, "worker-sess-fix", "src/a.py", epoch=sr_fix_edit)
sr_fix_launched = sr_fix_worker_runs / "20260601T0000Z-mine"
sr_fix_launched.mkdir()
(sr_fix_launched / "launcher").write_text("chat-1\n")
(sr_fix_launched / "worker-session").write_text("worker-sess-fix\n")
assert sr_fixes()[0] == 0
assert sr_answer("src/a.py") == "none"
sr_clear_journals()

# Another chat wrote the same file inside the window: the receipt answers for its own pass and for
# nothing standing beside it, so the path keeps its debt whoever else has to settle it.
sr_shadowed_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_shadowed_fixes)
sr_source.write_text(sr_moved + "two chats wrote this file\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
sr_journal(rb.COMMIT_JOURNAL, "chat-2", "src/a.py", epoch=sr_fix_edit + 5)
sr_shadowed_rc, sr_shadowed_out = sr_fixes()
assert sr_shadowed_rc == 0 and "covered" not in sr_shadowed_out, sr_shadowed_out
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# And a co-tenant's worker run the journals have not swept yet is that same parallel edit, in the
# one store where it exists at all while the run is still writing.
sr_foreign_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_foreign_fixes)
sr_source.write_text(sr_moved + "a co-tenant's worker is writing here too\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
sr_foreign_fix_run = sr_fix_worker_runs / "20260601T0100Z-theirs"
sr_foreign_fix_run.mkdir()
(sr_foreign_fix_run / "launcher").write_text("chat-2\n")
(sr_foreign_fix_run / "files").write_text(f"WORKDIR: {sr_repo}\nsrc/a.py\n")
assert "covered" not in sr_fixes()[1]
assert sr_answer("src/a.py") == "debt 1 mine"
# And it stays theirs when THIS chat's own run claims the path too. `foreign_run_claims` lets that
# pair through, because a launcher may waive its own output; the sha this receipt would settle
# still holds the co-tenant's bytes, so coverage asks the run records itself.
sr_own_fix_run = sr_fix_worker_runs / "20260601T0101Z-mine-as-well"
sr_own_fix_run.mkdir()
(sr_own_fix_run / "launcher").write_text("chat-1\n")
(sr_own_fix_run / "files").write_text(f"WORKDIR: {sr_repo}\nsrc/a.py\n")
assert rb.foreign_run_claims(str(sr_repo), "chat-1") == {}
assert "covered" not in sr_fixes()[1]
assert sr_answer("src/a.py") == "debt 1 mine"
shutil.rmtree(sr_foreign_fix_run)
shutil.rmtree(sr_own_fix_run)
sr_clear_journals()

# An entry stamped PAST the window's end is bytes the recorded sha holds and the window never
# checked: the receipt reads the tree after it stamps itself, and a co-tenant writing in between
# would otherwise be waived unexamined.
sr_after_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_after_fixes)
sr_source.write_text(sr_moved + "and a co-tenant kept typing past the stamp\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
sr_journal(rb.COMMIT_JOURNAL, "chat-2", "src/a.py", epoch=int(time.time()) + 600)
assert "covered" not in sr_fixes()[1]
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# A pass that fixed nothing wrote no fix bytes: an all-false-positive round answers its triage in
# full and leaves whatever the session typed meanwhile as the new work it is.
sr_nofix_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_nofix_fixes)
sr_source.write_text(sr_moved + "the finding was a false positive; this is other work\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
assert "covered" not in sr_fixes(fixed=0, fp=1)[1]
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# A run written before the seal instant was recorded covers nothing, rather than falling back to
# its launch: the launch is minutes EARLIER, and those minutes are time the panel could still read
# the file this window would then settle.
sr_unsealed_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_unsealed_dir = sr_fix_run(sr_unsealed_fixes)
sr_unsealed_meta = json.loads((sr_unsealed_dir / "meta.json").read_text())
del sr_unsealed_meta["sealed_at"]
sr_unsealed_meta["started"] = sr_stamp(sr_fix_sealed - 600)
(sr_unsealed_dir / "meta.json").write_text(json.dumps(sr_unsealed_meta))
sr_source.write_text(sr_moved + "written while the panel could still read it\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_sealed - 60)
assert "covered" not in sr_fixes()[1]
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# Coverage is a bonus the receipt carries, never a condition of writing one: a repository the run
# recorded and nobody can reach any more — a removed worktree, a pruned merged workspace — leaves
# the round closable, because losing the receipt would leave it impossible to close at all.
sr_gone_fixes = sr_store()
sr_gone_dir = sr_fix_run(sr_gone_fixes, repo=str(work / "session-review-repo-removed"))
assert rb.git_dir_path(str(work / "session-review-repo-removed")) is None
sr_gone_rc, sr_gone_out = sr_fixes()
assert sr_gone_rc == 0 and "covered" not in sr_gone_out, sr_gone_out
assert "covers" not in json.loads((sr_gone_dir / rb.FIX_RECEIPT).read_text())

# Nor is a triage nothing can read: the round prices at no number the gate would recognise, so it
# covers nothing and still records that its pass ran.
sr_unreadable_fixes = sr_store()
sr_unreadable_dir = sr_fix_run(sr_unreadable_fixes, judged=None, triaged=False)
(sr_unreadable_dir / rb.REPORT_RECEIPT).write_text("{ truncated mid-write")
assert rb.recorded_verdict_rows(sr_unreadable_dir) is None
assert rb.fix_coverage(sr_unreadable_dir, "chat-1", rb.utc_now(), None, 1) == []
sr_unreadable_rc, sr_unreadable_out = sr_fixes(fixed=0)
assert sr_unreadable_rc == 0 and "covered" not in sr_unreadable_out, sr_unreadable_out
assert (sr_unreadable_dir / rb.FIX_RECEIPT).exists()

# A re-adjudication takes the coverage back with it. `round_state` calls a round with nothing
# confirmed done whoever answered it, so the fingerprint the receipt recorded is what tells a
# retriaged round from the one this pass answered.
sr_retriage_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_retriage_dir = sr_fix_run(sr_retriage_fixes)
sr_source.write_text(sr_moved + "the fixing pass answered a finding\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
assert "1 fixed path(s) covered" in sr_fixes()[1]
assert sr_answer("src/a.py") == "none"
(sr_retriage_dir / "verdicts.jsonl").write_text(
    json.dumps({"rater": "oc-kimik3", "idx": 0, "verdict": "false_positive"}) + "\n"
)
assert rb.round_state(sr_retriage_dir) == "done"
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# A fix that touched a file the round never read is new work, not a fix: the panel holds no content
# for it, and a receipt covering it would settle bytes nobody reviewed.
sr_scope_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_scope_fixes)
sr_source.write_text(sr_moved + "in scope\n")
(sr_repo / "docs" / "big.md").write_text("a file the panel was never shown\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "docs/big.md", epoch=sr_fix_edit)
assert sr_fixes()[0] == 0
assert sr_answer("src/a.py") == "none"
assert sr_answer("docs/big.md") == "debt 1 mine"
(sr_repo / "docs" / "big.md").write_text(sr_big)
sr_clear_journals()

# Bytes journaled before the seal are not this pass's fixes: the panel could still read the tree
# then, and the entry says only that somebody wrote the file at some point before the round.
sr_window_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_window_fixes)
sr_source.write_text(sr_moved + "written while the panel could still read it\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_sealed - 60)
assert "covered" not in sr_fixes()[1]
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# An entry with no TAB is undatable and unowned: it may be anybody's, so the path it names holds
# bytes this pass cannot answer for.
sr_legacy_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_legacy_fixes)
sr_source.write_text(sr_moved + "an unattributable entry stands beside the fix\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
with (sr_gitdir / rb.COMMIT_JOURNAL).open("ab") as handle:
    handle.write(b"src/a.py\0")
assert "covered" not in sr_fixes()[1]
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# A pass that STOPPED fixed nothing to cover, and the fork it stopped for is what reads the tree
# next.
sr_blocked_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_fix_run(sr_blocked_fixes)
sr_source.write_text(sr_moved + "the pass stopped\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
assert sr_fixes(blocked="P1 threshold")[0] == 0
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# A round over the tally dial earned a second review, and that pass reads the fixes itself: covered
# here they would be settled before it ever ran.
sr_tally_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_judged(sr_fix_run(sr_tally_fixes), "P2", 9)
sr_source.write_text(sr_moved + "nine findings answered\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
assert "covered" not in sr_fixes(fixed=9)[1]
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

# And one over the P1 dial owes a MANDATORY one: its debt reads locked, which is the state a
# receipt that covered its own fixes would have hidden.
sr_p1_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_judged(sr_fix_run(sr_p1_fixes), "P1", 3)
sr_source.write_text(sr_moved + "three P1s answered anyway\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
assert "covered" not in sr_fixes(fixed=3)[1]
assert sr_answer("src/a.py") == "debt 1 mine locked"
sr_clear_journals()

# A killed panel was sealed with a scope its dead cells never reached, so its receipt covers
# nothing either — the same reason its snapshot is no artifact.
sr_killed_fixes = sr_store()
sr_source.write_text(sr_moved)
sr_killed_dir = sr_fix_run(sr_killed_fixes, timed_out=True)
sr_source.write_text(sr_moved + "a hung round's pass answered\n")
sr_journal(rb.COMMIT_JOURNAL, "chat-1", "src/a.py", epoch=sr_fix_edit)
assert sr_fixes()[0] == 0
assert "covers" not in json.loads((sr_killed_dir / rb.FIX_RECEIPT).read_text())
assert sr_answer("src/a.py") == "debt 1 mine"
sr_clear_journals()

rb.ESCALATION_GATE = sr_gate_before
os.environ["WORKER_RUN_DIR"] = str(sr_worker_runs)

sr_clear_journals()
if sr_session_before is None:
    os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
else:
    os.environ["CLAUDE_CODE_SESSION_ID"] = sr_session_before
if sr_worker_runs_before is None:
    os.environ.pop("WORKER_RUN_DIR", None)
else:
    os.environ["WORKER_RUN_DIR"] = sr_worker_runs_before
os.environ["CLAUDEB_DIR"] = sr_claudeb_before
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
# What deduplicating blind MEANS across raters, spelled out: without it 17 confirmed P1 rows that
# were ~7 distinct defects reached a fixer as 17 (live, 2026-08-20).
assert (
    "the same file plus the same function or defect is ONE defect"
) in worktree_stdout.getvalue(), worktree_stdout.getvalue()
assert (
    "mark every other rater's copy duplicate"
) in worktree_stdout.getvalue(), worktree_stdout.getvalue()
# The durable side is untouched: a commit the corpus can be judged on keeps the corpus command.
plain_handoff = io.StringIO()
with contextlib.redirect_stdout(plain_handoff):
    rb.handoff("plain-run", ["/fixture/findings-sol-high.jsonl"])
assert (
    "Record exactly with: review-bench record plain-run "
    "--verdicts /tmp/review-bench-plain-run-verdicts.jsonl"
) in plain_handoff.getvalue(), plain_handoff.getvalue()
assert "--no-corpus" not in plain_handoff.getvalue(), plain_handoff.getvalue()
# The handoff is a two-step brief, not a triage order: the pass that judges the findings is the
# pass that fixes them, and a worker sent home after step 1 leaves the round owing work nobody
# recorded. The threshold is where it stops instead — that call is Egor's, not a worker's.
handoff_text = plain_handoff.getvalue()
assert "STEP 1 — blind triage." in handoff_text, handoff_text
assert "STEP 2 — the same worker pass" in handoff_text, handoff_text
assert f"THRESHOLD STOP — {rb.HANDOFF_P1_STOP} or more confirmed P1s" in handoff_text, handoff_text
assert "review-bench fixes plain-run --done --fixed <N> --fp <M>" in handoff_text, handoff_text
assert "review-bench fixes plain-run --blocked 'P1 threshold'" in handoff_text, handoff_text
# The one line aimed past the worker: at the threshold a chat with nobody to ask decides for
# itself rather than stalling on a fork Egor is not there to take.
assert "maximum autonomy" in handoff_text, handoff_text
assert "FRESH worker session" in handoff_text, handoff_text
assert "Mutation-verify" in handoff_text, handoff_text
# Neither commit nor stage: read as an imperative and an object, "commit and stage nothing" told the
# worker to do the one thing the contract withholds until Egor asks for it.
assert "Neither commit nor stage anything" in handoff_text, handoff_text
# And a run whose snapshot the checkout has moved past — a historical commit, a range that ended
# before HEAD — is handed no fixing pass at all: its findings are about code nobody is standing on,
# so a step 2 over them edits whatever the current tree happens to keep at those paths.
durable_handoff = io.StringIO()
with contextlib.redirect_stdout(durable_handoff):
    rb.handoff("stale-run", ["/fixture/findings-sol-high.jsonl"], fixable=False)
durable_text = durable_handoff.getvalue()
assert "Record exactly with: review-bench record stale-run" in durable_text, durable_text
assert "STEP 2" not in durable_text, durable_text
assert "THRESHOLD STOP" not in durable_text, durable_text
assert "review-bench fixes stale-run" not in durable_text, durable_text
assert "Fix nothing and record no fix status." in durable_text, durable_text
# The threshold a merged panel stops at is one repository's, the way the gate that prices the round
# counts it: three findings spread over three repositories reached no member's threshold.
merged_handoff = io.StringIO()
with contextlib.redirect_stdout(merged_handoff):
    rb.handoff("merged-run", ["/fixture/findings-sol-high.jsonl"],
               members=[{"label": "a", "repo": "/tmp/a"}, {"label": "b", "repo": "/tmp/b"}])
assert "confirmed P1s in ANY ONE of the repositories above" in merged_handoff.getvalue(), \
    merged_handoff.getvalue()
assert "in ANY ONE of the repositories" not in handoff_text, handoff_text
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
assert "--verify" not in snapshot_rerun_stdout.getvalue().split("rerun:")[1].splitlines()[0]

# A rerun reads exactly the tree the seal it is pinned to froze, so the instant it is measured by
# is that seal's and never this pass's clock: stamped from now, every fixes receipt written since
# the snapshot reads as lineage this panel could have seen, and a rerun of the PRE-FIX snapshot
# spends the scope's round budget and opens its lock over cells that saw none of them. The seal's
# own commit cannot say it — one fixed clock stands behind every commit object review-bench writes.
seal_inherit_store = work / "seal-inherit-claudeb"
(seal_inherit_store / "worker-stats" / "benches").mkdir(parents=True)
shutil.copytree(worktree_run_dir,
                seal_inherit_store / "worker-stats" / "benches" / worktree_run_dir.name)
os.environ["CLAUDEB_DIR"] = str(seal_inherit_store)
with contextlib.redirect_stdout(io.StringIO()):
    rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=snapshot_sha, raters="sol-medium,sol-high",
        leg=False, verify=None, auto=None, focus=None,
    ))
seal_inherit_dir = next(
    directory for directory in (seal_inherit_store / "worker-stats" / "benches").iterdir()
    if directory.name != worktree_run_dir.name
)
seal_inherit_meta = json.loads((seal_inherit_dir / "meta.json").read_text())
assert seal_inherit_meta["commit"] == snapshot_sha, seal_inherit_meta
assert seal_inherit_meta["sealed_at"] == worktree_meta["sealed_at"], seal_inherit_meta
# And nothing on record for a sha is no seal to inherit: the rerun above ran in a store holding
# only its own panel, so it kept the clock.
assert snapshot_rerun_meta["sealed_at"] != worktree_meta["sealed_at"], snapshot_rerun_meta


def oc_rerun_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    return 1, 1, "", "fixture rater failure", []


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = oc_rerun_runner
# A rerun is a bench run and a bench run verifies nothing, so the line carries no verifier flag
# of either spelling — including out of a panel holding the cells the verifier reaches, and
# including out of one launched with the no-op `--no-verify` an older line spells.
for oc_rerun_name, oc_rerun_no_verify in (("default", False), ("raw", True)):
    oc_rerun_store = work / f"oc-rerun-{oc_rerun_name}-claudeb"
    os.environ["CLAUDEB_DIR"] = str(oc_rerun_store)
    oc_rerun_stdout = io.StringIO()
    with contextlib.redirect_stdout(oc_rerun_stdout):
        rb.cmd_run(argparse.Namespace(
            repo=str(pin_repo), commitish=pin_sha, raters="oc-kimik3,sol-medium",
            leg=False, verify=None, no_verify=oc_rerun_no_verify, auto=None, focus=None,
        ))
    oc_rerun_line = next(
        line for line in oc_rerun_stdout.getvalue().splitlines() if line.startswith("rerun: ")
    )
    assert oc_rerun_line == \
        f"rerun: review-bench run {pin_sha} --raters oc-kimik3,sol-medium", oc_rerun_line
for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = tier_runner

# --- --debt: the review that scopes itself ------------------------------------------------------
# The one review nobody hands a scope. It reads every path this repository owes an answer for,
# widened to what a locked round still holds, each from the content the artifact answering for it
# recorded — so work reviewed, then committed, then edited again reaches the panel as ONE diff
# across the commit, and the run settles exactly what it read.
debt_repo = work / "debt-review"
debt_repo.mkdir()
subprocess.run(["git", "init", "-q", str(debt_repo)], check=True)
for debt_key, debt_value in (("user.email", "bench@example.test"), ("user.name", "Review Bench")):
    subprocess.run(["git", "-C", str(debt_repo), "config", debt_key, debt_value], check=True)


def debt_git(*argv):
    return subprocess.run(["git", "-C", str(debt_repo), *argv], check=True,
                          capture_output=True, text=True).stdout.strip()


def debt_sha(path):
    return debt_git("hash-object", "--", str(debt_repo / path))


(debt_repo / "reviewed.py").write_text("one\ntwo\n")
(debt_repo / "pair.py").write_text("the other half\n")
(debt_repo / "settled.py").write_text("nothing has touched this\n")
debt_git("add", "-A")
debt_git("commit", "-qm", "initial")
debt_gitdir = pathlib.Path(debt_git("rev-parse", "--absolute-git-dir"))
debt_claudeb_before = os.environ["CLAUDEB_DIR"]
debt_first_sha = debt_sha("reviewed.py")
debt_pair_sha = debt_sha("pair.py")
debt_settled_sha = debt_sha("settled.py")
debt_stores = 0


def debt_store():
    """A bench store per scenario, for the reason sr_store has one: the answer is about the NEWEST
    artifact holding a path.
    """
    global debt_stores
    debt_stores += 1
    os.environ["CLAUDEB_DIR"] = str(work / f"debt-review-store-{debt_stores}")
    directory = rb.state_dir() / "benches"
    directory.mkdir(parents=True)
    return directory


def debt_artifact(benches, run_id, reviewed, report=None):
    directory = benches / run_id
    directory.mkdir()
    (directory / "meta.json").write_text(json.dumps({
        "run_id": run_id, "repo": str(debt_repo), "session": "chat-1", "worktree": True,
        "reviewed": dict(reviewed), "finished": rb.iso_now(),
    }))
    if report is None:
        (directory / "verdicts.jsonl").write_text("")
    else:
        (directory / rb.REPORT_RECEIPT).write_text(json.dumps(report))
    return directory


def debt_journal(path, name=None):
    with (debt_gitdir / (name or rb.COMMIT_JOURNAL)).open("ab") as handle:
        handle.write(f"chat-1\t1800000000\t{path}\0".encode())


debt_seen = []


def debt_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    debt_seen.append(diff)
    return 0, 1, "NO FINDINGS", "", []


for debt_side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[debt_side] = debt_runner


def debt_review(**fields):
    """One `review-bench review --debt`, panel and all, with the diff its cells were handed."""
    call = dict(repo=str(debt_repo), commitish=None, worktree=False, debt=True, range=None,
                paths=None, raters="sol-medium-bare", leg=False, verify=None, auto=None,
                focus=None)
    call.update(fields)
    del debt_seen[:]
    stdout = io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stdout):
        rc = rb.cmd_run(argparse.Namespace(**call))
    assert rc == 0, stdout.getvalue()
    run_id = next(line.split(": ", 1)[1] for line in stdout.getvalue().splitlines()
                  if line.startswith("run id: "))
    run_dir = rb.state_dir() / "benches" / run_id
    # Triaged by hand, the way every other debt fixture here is: what settles a path is a run
    # somebody stood behind, and cmd_run only produces the panel.
    (run_dir / "verdicts.jsonl").write_text("")
    meta = json.loads((run_dir / "meta.json").read_text())
    return meta, debt_seen[0], stdout.getvalue()


def debt_verdict():
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rb.cmd_debt(argparse.Namespace(
            repo=str(debt_repo), session="chat-1", paths=[], list=False,
        ))
    return out.getvalue().strip()


# A path this chat committed and nobody ever reviewed is in the scope of its own accord, and the
# run's receipt settles it: nobody named it, and nobody had to.
debt_never = debt_store()
(debt_repo / "born.py").write_text("committed, never read\n")
debt_git("add", "-A")
debt_git("commit", "-qm", "born")
debt_journal("born.py")
assert debt_verdict() == "debt 1 mine", debt_verdict()
debt_meta, debt_diff, _ = debt_review()
assert debt_meta["reviewed"] == {"born.py": debt_sha("born.py")}, debt_meta
assert "committed, never read" in debt_diff, debt_diff
# It is the repository's own question, so it stamps the repository's own receipt and its scope
# never reaches the round key — a scoped receipt here would leave the debt standing after the
# review, and a key made of these paths would make every round a scope of its own.
assert debt_meta["scope"] == ["born.py"] and debt_meta["debt"] is True, debt_meta
assert rb.review_receipt(debt_repo)["run_id"] == debt_meta["run_id"], "no plain receipt"
assert rb.review_receipt(debt_repo, scope=["born.py"]) is None, "a scoped receipt was written"
assert [key[1] for key in rb.run_scope_key(debt_meta)] == [()], rb.run_scope_key(debt_meta)
assert debt_verdict() == "none", debt_verdict()
# The journals are the debt universe for paths no artifact holds, and every scenario below asks
# about a fresh store: a name left in them would put this settled file back in the next answer.
for debt_name in (rb.DEBT_JOURNAL, rb.COMMIT_JOURNAL):
    (debt_gitdir / debt_name).unlink(missing_ok=True)

# Content reviewed at X, committed, then edited to Y: the panel reads X..Y as one diff, and the
# commit in between is invisible. Nothing else can show it — the review is against what was READ.
debt_drift = debt_store()
debt_artifact(debt_drift, "20260101T000100Z-aaaaaaa", {"reviewed.py": debt_first_sha})
(debt_repo / "reviewed.py").write_text("one\ntwo\ncommitted three\n")
debt_git("commit", "-aqm", "committed drift")
(debt_repo / "reviewed.py").write_text("one\ntwo\ncommitted three\nuncommitted four\n")
debt_meta, debt_diff, _ = debt_review()
assert "+committed three" in debt_diff and "+uncommitted four" in debt_diff, debt_diff
assert "committed drift" not in debt_diff, debt_diff
assert rb.snapshot_scope_paths(debt_repo, debt_meta["commit"]) == ["reviewed.py"], debt_meta
assert debt_meta["reviewed"] == {"reviewed.py": debt_sha("reviewed.py")}, debt_meta
assert debt_verdict() == "none", debt_verdict()
# And the base is a commit of the tool's own making, not one of this repository's: no commit here
# holds the mixture of contents the artifacts recorded.
debt_base = rb.diff_base(debt_repo, debt_meta["commit"])
assert debt_base not in debt_git("rev-list", "HEAD").split(), debt_base
assert debt_git("show", "-s", "--format=%s", debt_base) == "review-bench debt base", debt_base

# A locked round is discharged by the run this mode produces, and by nothing narrower: the lock is
# released only by a run holding every surviving path of that round, and a path standing at the sha
# the round recorded is NOT in debt — so a scope made of the debt alone can never answer it.
debt_locked_store = debt_store()
debt_artifact(debt_locked_store, "20260101T000100Z-aaaaaaa",
              {"reviewed.py": debt_sha("reviewed.py"), "pair.py": debt_pair_sha},
              report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
(debt_repo / "reviewed.py").write_text("one\ntwo\ncommitted three\nuncommitted four\nfixed\n")
assert debt_verdict() == "debt 1 other locked", debt_verdict()
assert [path for path, _ in rb.repo_debt(debt_repo)] == ["reviewed.py"], rb.repo_debt(debt_repo)
assert [path for path, _ in rb.debt_review_scope(debt_repo)] == ["pair.py", "reviewed.py"], \
    rb.debt_review_scope(debt_repo)
debt_meta, debt_diff, _ = debt_review()
# The survivor contributes no diff at all and is HELD anyway: a run that does not hold it
# discharges nothing, which is exactly what the debt-only scope beside it proves.
assert "diff --git a/pair.py" not in debt_diff, debt_diff
assert f"{rb.SCOPE_TRAILER}pair.py" in debt_diff, debt_diff
assert debt_meta["reviewed"] == {
    "reviewed.py": debt_sha("reviewed.py"), "pair.py": debt_pair_sha,
}, debt_meta
# And it answers for the paths it was WIDENED to rather than for the ones that happen to show in
# the snapshot: a path the base holds nothing for and the tree no longer carries is in neither
# listing, and left out of `reviewed` the run holds it nowhere and discharges no lock.
assert rb.reviewed_blobs(
    debt_repo, ["pair.py"], debt_meta["commit"], paths=["pair.py", "vanished.py"]
) == {"pair.py": debt_pair_sha, "vanished.py": ""}, rb.reviewed_blobs(
    debt_repo, ["pair.py"], debt_meta["commit"], paths=["pair.py", "vanished.py"]
)

# A debt path is a FILE and never a pathspec: a repository holding one honestly named
# `:(exclude)...` had that name reach git as MAGIC, and the snapshot then answered for the debt
# minus the very file the name excluded.
magic_repo = work / "debt-magic"
magic_repo.mkdir()
subprocess.run(["git", "init", "-q", str(magic_repo)], check=True)
for magic_key, magic_value in (("user.email", "bench@example.test"),
                               ("user.name", "Review Bench")):
    subprocess.run(["git", "-C", str(magic_repo), "config", magic_key, magic_value], check=True)
(magic_repo / "keep.py").write_text("one\n")
(magic_repo / ":(exclude)keep.py").write_text("two\n")
subprocess.run(["git", "-C", str(magic_repo), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(magic_repo), "commit", "-qm", "initial"], check=True)
(magic_repo / "keep.py").write_text("one\nedited\n")
magic_commit = rb.debt_snapshot_commit(
    magic_repo, [("keep.py", None), (":(exclude)keep.py", None)]
)
magic_held = subprocess.run(
    ["git", "-C", str(magic_repo), "ls-tree", "-r", "--name-only", magic_commit],
    check=True, capture_output=True, text=True,
).stdout.splitlines()
assert sorted(magic_held) == [":(exclude)keep.py", "keep.py"], magic_held
assert debt_verdict() == "none", debt_verdict()
debt_narrow = debt_store()
debt_artifact(debt_narrow, "20260101T000100Z-aaaaaaa",
              {"reviewed.py": debt_first_sha, "pair.py": debt_pair_sha},
              report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
debt_artifact(debt_narrow, "20260101T000200Z-bbbbbbb", {"reviewed.py": debt_sha("reviewed.py")})
rb.RUN_CONFIRMED_COUNTS.clear()
rb.ROUND_BUDGET_SPENT_CACHE.clear()
assert debt_verdict() == "debt 1 other locked", debt_verdict()

# A recorded sha this store can no longer read is no base at all: the path is dropped from it, and
# the panel is shown the file whole rather than a diff against an error.
debt_gone = debt_store()
debt_artifact(debt_gone, "20260101T000100Z-aaaaaaa", {"reviewed.py": "0" * 40})
debt_meta, debt_diff, _ = debt_review()
assert "new file mode" in debt_diff and "+one" in debt_diff, debt_diff
assert debt_meta["reviewed"] == {"reviewed.py": debt_sha("reviewed.py")}, debt_meta

# The mode computes its own target, so every flag that names one is refused rather than combined —
# and refused before anything is sealed.
debt_refusals = {}
for debt_label, debt_fields in (
    ("paths", {"paths": ["reviewed.py"]}),
    ("range", {"range": f"{debt_git('rev-parse', 'HEAD~1')}..HEAD"}),
    ("commitish", {"commitish": "HEAD"}),
    ("worktree", {"worktree": True}),
):
    try:
        debt_review(**debt_fields)
        debt_refusals[debt_label] = ""
    except ValueError as exc:
        debt_refusals[debt_label] = str(exc)
assert all("--debt computes its own target" in text for text in debt_refusals.values()), \
    debt_refusals
assert "--paths" in debt_refusals["paths"], debt_refusals
assert "--range" in debt_refusals["range"], debt_refusals
assert "a commitish" in debt_refusals["commitish"], debt_refusals
assert "--worktree" in debt_refusals["worktree"], debt_refusals
# And a repository owing nothing has no review to run: an empty panel would report that nobody
# found anything in nothing.
debt_store()
try:
    debt_review()
    debt_owes = ""
except ValueError as exc:
    debt_owes = str(exc)
assert "is in review debt" in debt_owes, debt_owes
# And it reads the working tree, so it is armed the way `--worktree` is: without Egor's ask by
# name it is exactly the mid-work panel that door exists to close.
debt_asked_before = os.environ.pop("REVIEW_ASKED", None)
try:
    rb.guard_review_armed(argparse.Namespace(worktree=False, debt=True))
    debt_armed = ""
except ValueError as exc:
    debt_armed = str(exc)
finally:
    if debt_asked_before is not None:
        os.environ["REVIEW_ASKED"] = debt_asked_before
assert "REVIEW_ASKED=1" in debt_armed, debt_armed

# The second review a locked round owes IS this command, and both the waiver's refusal and the
# adjudication handoff name it rather than asking the reader to widen a path list by hand.
debt_waive_store = debt_store()
debt_artifact(debt_waive_store, "20260101T000100Z-aaaaaaa",
              {"reviewed.py": debt_first_sha, "pair.py": debt_pair_sha},
              report={"confirmed": 3, "confirmed_by_severity": {"P1": 3}})
rb.RUN_CONFIRMED_COUNTS.clear()
rb.ROUND_BUDGET_SPENT_CACHE.clear()
debt_waive_out = io.StringIO()
os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-1"
try:
    with contextlib.redirect_stdout(debt_waive_out):
        debt_waive_rc = rb.cmd_waive(argparse.Namespace(
            repo=str(debt_repo), reason="the narrow rerun will do", paths=["reviewed.py"],
        ))
finally:
    os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
assert debt_waive_rc == 1, debt_waive_out.getvalue()
assert rb.DEBT_REVIEW_COMMAND in debt_waive_out.getvalue(), debt_waive_out.getvalue()
debt_handoff = io.StringIO()
with contextlib.redirect_stdout(debt_handoff):
    rb.handoff("debt-run", ["/tmp/findings.jsonl"])
assert rb.DEBT_REVIEW_COMMAND in debt_handoff.getvalue(), debt_handoff.getvalue()

for debt_side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[debt_side] = tier_runner
os.environ["CLAUDEB_DIR"] = debt_claudeb_before

# --- scoped worktree runs ---------------------------------------------------------------------
# A review of part of the working tree is not a review of the repository. Its snapshot must hold
# only the paths it was given, and its receipt must never be the one `coverage` and the statusline
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

# A repeated --paths widens the scope. argparse's default store kept only the last flag's list,
# so a review spelled one flag per file silently read one file of fifteen and reported itself
# exactly like a full run — the receipt was the only thing that knew.
repeated_paths = {}
repeated_real = {"review": rb.cmd_review, "run": rb.cmd_run}
rb.cmd_review = lambda args: repeated_paths.__setitem__("review", args.paths)
rb.cmd_run = lambda args: repeated_paths.__setitem__("run", args.paths)
repeated_argv = sys.argv
for repeated_cmd in ("review", "run"):
    sys.argv = ["review-bench", repeated_cmd, "--worktree", "--tier", "T0",
                "--paths", "alpha.txt", "beta.txt", "--paths", "gamma.txt"]
    rb.main()
    assert repeated_paths[repeated_cmd] == ["alpha.txt", "beta.txt", "gamma.txt"], repeated_paths
sys.argv = repeated_argv
rb.cmd_review, rb.cmd_run = repeated_real["review"], repeated_real["run"]

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
assert "a single commitish is already one fixed set of paths" in scope_reject["commitish"], \
    scope_reject
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
stamp_head = subprocess.run(
    ["git", "-C", str(stamp_repo), "rev-parse", "HEAD"],
    check=True, capture_output=True, text=True,
).stdout.strip()
saved_stats_dir = os.environ.get("WORKER_STATS_DIR")
os.environ["WORKER_STATS_DIR"] = str(stamp_store)
assert rb.working_tree_tree(stamp_repo) == expected_stamp_tree
stamp_receipt_path = pathlib.Path(rb.persist_review_receipt(
    stamp_repo.resolve(), expected_stamp_tree, stamp_head, "run-receipt", 0,
))
stamp_receipt = json.loads(stamp_receipt_path.read_text())
assert stamp_receipt_path == stamp_store / rb.RECEIPT_DIR / rb.receipt_file_name(stamp_repo)
assert stamp_receipt == {
    "repo": str(stamp_repo.resolve()), "tree": expected_stamp_tree,
    "commit": stamp_head, "run_id": "run-receipt",
    "ts": stamp_receipt["ts"], "errored": 0,
}, stamp_receipt
assert rb.review_receipt(stamp_repo)["tree"] == expected_stamp_tree
if saved_stats_dir is None:
    os.environ.pop("WORKER_STATS_DIR")
else:
    os.environ["WORKER_STATS_DIR"] = saved_stats_dir

# The receipt is read back through this command rather than by deriving its path a second time,
# and it decides on the confirmed count the run was adjudicated to.
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

nonrepo = work / "receipt-nonrepo"
nonrepo.mkdir()
nonrepo_store = work / "receipt-nonrepo-store"
nonrepo_proc = subprocess.run(
    [sys.argv[1], "receipt", "--repo", str(nonrepo)],
    capture_output=True, text=True,
    env=dict(os.environ, WORKER_STATS_DIR=str(nonrepo_store)),
)
assert nonrepo_proc.returncode != 0
assert not nonrepo_store.exists(), list(nonrepo_store.rglob("*")) \
    if nonrepo_store.exists() else []

# A bench run records what the rater said, verifiable cells and all: a row whose false positives
# the verifier already cut measures the pair, and the corpus compares it against rows nobody cut
# (Egor, 2026-08-14). The tier review is where the verifier lives, and it defaults on there.
raw_opencode_store = work / "raw-opencode-claudeb"
os.environ["CLAUDEB_DIR"] = str(raw_opencode_store)
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-verify-drop.json")
raw_opencode_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, raters="oc-kimik3,oc-grok45-low",
    leg=False, verify=None, no_verify=False, auto=None, focus=None,
))
raw_opencode_run = next((raw_opencode_store / "worker-stats" / "benches").iterdir())
raw_opencode_meta = json.loads((raw_opencode_run / "meta.json").read_text())
assert raw_opencode_rc == 0, raw_opencode_meta
assert raw_opencode_meta["verifier"] == "", \
    f"bench run verifier: {raw_opencode_meta['verifier']!r}"
assert not list(raw_opencode_run.glob("verified-*.jsonl")), "a bench run verified its findings"
# The verifier fixture in front of this run rejects everything it is asked about, so the raw
# findings surviving are the whole proof it was never asked.
assert all(
    len(rb.read_jsonl(raw_opencode_run / f"findings-{row['rater']}.jsonl")) == 1
    and row["verifier_dropped"] == 0 and "verify_ms" not in row
    for row in raw_opencode_meta["rater_runs"]
), raw_opencode_meta["rater_runs"]

# Asked for by name it is refused rather than quietly ignored: a bench row that came back raw
# while its caller believes it was checked is the seam this whole rule exists to close.
bench_verify_refusal = ""
try:
    rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters="oc-kimik3",
        leg=False, verify=rb.OPENCODE_VERIFIER, no_verify=False, auto=None, focus=None,
    ))
except ValueError as exc:
    bench_verify_refusal = str(exc)
assert "--verify is a tier review's flag" in bench_verify_refusal, bench_verify_refusal
assert "review-bench review <target> --tier <tier>" in bench_verify_refusal, \
    bench_verify_refusal

# `--no-verify` is what a reproduce line printed before this rule spells, so a bench run still
# takes it and does with it what it now does with every bench run: nothing.
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

# Asking for it where it cannot apply is an error; defaulting into that would refuse every tier
# whose composition happens to have no cell the verifier reaches.
no_oc_store = work / "no-opencode-claudeb"
os.environ["CLAUDEB_DIR"] = str(no_oc_store)
with fixture_tier(["sol-low"]) as no_oc_tier:
    no_oc_rc = rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters=None, tier=no_oc_tier,
        leg=False, verify=None, no_verify=False, auto=None, focus=None,
    ))
no_oc_meta = json.loads(
    (next((no_oc_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert no_oc_rc == 0, no_oc_meta
assert no_oc_meta["verifier"] == "", no_oc_meta["verifier"]

# The agy leg's claims are filtered by the same verifier as an OpenCode cell's, and under a tier
# for the same reason: measured on the leg's own adjudicated findings — 6 real and 24 false —
# the verifier dropped 11 of the 24.
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
    with contextlib.redirect_stdout(stdout), fixture_tier([agy_verify_spec]) as agy_tier:
        rc = rb.cmd_run(argparse.Namespace(**dict(
            dict(repo=str(pin_repo), commitish=pin_sha, raters=None, tier=agy_tier,
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
    "claude": False, "codex": True, "agy": True, "opencode": True,
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
assert no_corpus_stdout.getvalue().count(rb.REPORT_BEGIN) == 1, \
    no_corpus_stdout.getvalue()
assert "fixes:        NOT APPLIED — pending" in no_corpus_stdout.getvalue(), \
    no_corpus_stdout.getvalue()
assert not (no_corpus_dir / "verdicts.jsonl").exists(), "a verdict file was left behind"
# The receipt carries the severity tally of exactly those verdicts — the same numbers the block
# above printed — because with no verdict file left behind it is the only record that this run was
# triaged at all, and the commit gate prices its next round on it.
no_corpus_receipt = json.loads((no_corpus_dir / rb.REPORT_RECEIPT).read_text())
assert no_corpus_receipt["confirmed_by_severity"] == {"P1": 1, "P2": 0, "P3": 0}, no_corpus_receipt
assert no_corpus_receipt["confirmed"] == 1, no_corpus_receipt

# A run recorded while the standalone grok side still existed outlives it, and its spec no longer
# parses: refusing it here strands the whole run, findings and all, from ever being adjudicated.
retired_side_store = work / "retired-side-claudeb"
retired_side_dir = retired_side_store / "worker-stats" / "benches" / "retired-side-fixture"
retired_side_dir.mkdir(parents=True)
os.environ["CLAUDEB_DIR"] = str(retired_side_store)
(retired_side_dir / "meta.json").write_text(json.dumps({
    "run_id": "retired-side-fixture", "commit": pin_sha, "repo": str(pin_repo),
    "raters": ["grok-low"], "completed_raters": ["grok-low"],
    "rater_runs": [{"rater": "grok-low", "exit_code": 0, "findings": 1}],
}) + "\n")
rb.write_jsonl(retired_side_dir / "findings-grok-low.jsonl", [
    {"file": "a.py", "line": 1, "severity": "P2", "summary": "real"},
])
retired_side_verdicts = work / "retired-side-verdicts.jsonl"
rb.write_jsonl(retired_side_verdicts, [
    {"rater": "grok-low", "idx": 0, "verdict": "confirmed"},
])
retired_side_stdout = io.StringIO()
with contextlib.redirect_stdout(retired_side_stdout):
    assert rb.cmd_record(argparse.Namespace(
        run_id="retired-side-fixture", verdicts=str(retired_side_verdicts),
    )) == 0
retired_side_row = next(
    row for row in rb.read_jsonl(retired_side_store / "worker-stats" / "reviews.jsonl")
    if row["run_id"] == "retired-side-fixture"
)
assert (retired_side_row["rater_model"], retired_side_row["rater_effort"]) == ("grok", "low"), \
    retired_side_row
assert retired_side_row["confirmed"] == 1, retired_side_row
os.environ["CLAUDEB_DIR"] = str(repeat_store)
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
with fixture_tier(["sol-medium"]) as unreachable_tier:
    try:
        rb.cmd_run(argparse.Namespace(
            repo=str(pin_repo), commitish=pin_sha, raters=None, tier=unreachable_tier,
            leg=False, verify="oc-kimik3", auto=None, focus=None,
        ))
    except RuntimeError as exc:
        assert "no cell the verifier reaches" in str(exc), exc
    else:
        raise AssertionError("--verify accepted a run with no cell the verifier reaches")
with fixture_tier(["oc-kimik3"]) as verify_timing_tier:
    verify_timing_rc = rb.cmd_run(argparse.Namespace(
        repo=str(pin_repo), commitish=pin_sha, raters=None, tier=verify_timing_tier,
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
assert verify_timing_corpus[0]["verifier"] == verify_timing_meta["verifier"], \
    verify_timing_corpus
(work / "verify-ms-ok").touch()

# A tier review's rows keep their verifier, a bench run's stay raw, and the corpus says which is
# which per row: the date a rule changed is not something a reader of one row can apply.
verifier_stamp_store = work / "verifier-stamp-claudeb"
os.environ["CLAUDEB_DIR"] = str(verifier_stamp_store)
for stamp_id, stamp_commit, stamp_verifier, stamp_specs in (
    ("verifier-stamped", "abcdef0123456789", "oc-kimik3", ["oc-kimik3", "sol-medium"]),
    ("verifier-raw", "fedcba9876543210", "", ["oc-kimik3"]),
):
    stamp_run = verifier_stamp_store / "worker-stats" / "benches" / stamp_id
    stamp_run.mkdir(parents=True)
    (stamp_run / "meta.json").write_text(json.dumps({
        "run_id": stamp_id, "commit": stamp_commit, "repo": str(pin_repo),
        "raters": stamp_specs,
        "rater_runs": [{"rater": spec, "exit_code": 0} for spec in stamp_specs],
        "started": "2026-08-14T00:00:00+00:00", "finished": "2026-08-14T00:00:05+00:00",
        "focus": "", "verifier": stamp_verifier,
    }))
    for spec in stamp_specs:
        (stamp_run / f"findings-{spec}.jsonl").write_text(json.dumps({
            "severity": "P2", "file": "src/a.py", "line": 10, "summary": "Stamp fixture",
            "rater": spec,
        }) + "\n")
    stamp_verdicts = work / f"{stamp_id}-verdicts.jsonl"
    stamp_verdicts.write_text("".join(
        json.dumps({"rater": spec, "idx": 0, "verdict": "confirmed"}) + "\n"
        for spec in stamp_specs
    ))
    assert rb.cmd_record(argparse.Namespace(
        run_id=stamp_id, verdicts=str(stamp_verdicts),
    )) == 0
stamp_rows = {
    (row["run_id"], row["rater"]): row
    for row in rb.read_jsonl(verifier_stamp_store / "worker-stats" / "reviews.jsonl")
}
assert stamp_rows[("verifier-stamped", "oc-kimik3")].get("verifier") == "oc-kimik3", stamp_rows
assert "verifier" not in stamp_rows[("verifier-stamped", "sol-medium")], stamp_rows
assert "verifier" not in stamp_rows[("verifier-raw", "oc-kimik3")], stamp_rows

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
# commits stamping the repository's receipt would leave every later coverage answer measuring against a
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
    "claude": True, "codex": True, "agy": True, "opencode": True,
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
# every later coverage answer measuring the working tree against a tree nobody is standing on.
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
    "claude": True, "codex": True, "agy": True, "opencode": True,
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

# One document per repository while the run is in flight, or the review is invisible in every
# surface but one repository's.
assert merged_seen["progress"] == [
    sorted(str(path) for path in merged_tops)
] * 2, merged_seen["progress"]
assert not list((merged_state / rb.PROGRESS_DIR).iterdir())

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

# --- the gateway cooldown: a wait that expires, and a canary that ends it ------------------------
# A quota wall says when it lifts; a gateway server error says nothing at all, so the wait is the
# tool's own — and it has to expire by itself, because a cell held out until proof it recovered is
# never asked for that proof. Every panel today paid for grok three times over before recording it
# (Egor, 2026-08-08).
cooldown_store = work / "cooldown-claudeb"
os.environ["CLAUDEB_DIR"] = str(cooldown_store)
cooldown_state = cooldown_store / "worker-stats"
cooldown_state.mkdir(parents=True)
cooldown_raters = rb.parse_raters("oc-grok45-low x3,oc-kimik3 x2")
assert rb.apply_gateway_cooldown(cooldown_raters) == (cooldown_raters, [])

# Only the gateway being DOWN is this mechanism's business. A spent plan and a pool run dry behind
# one carry a reset of their own, and a canary fired into a dollar window every 45 minutes is the
# retry DIAGNOSTICS forbids — with an expiry that would then call the side recovered.
assert rb.gateway_outage("opencode", 1, "HTTP 503 Router.Unavailable")
assert not rb.gateway_outage("opencode", 1, "GoUsageLimitError: limitName=monthly")
assert not rb.gateway_outage("opencode", 1, rb.no_account_left("opencode"))
# The labels are live and the stderr was captured earlier: cells run side by side, so a wall
# another cell records in between must not turn a pool that merely ran dry into an outage.
label_state = work / "gateway-label-state"
label_state.mkdir()
os.environ["WORKER_STATS_DIR"] = str(label_state)
rb.mark_walled("opencode", "opencode-go", reset_at=time.time() + 3600, window="5-hour")
dry_pool_stderr = rb.no_account_left("opencode")
rb.mark_walled("opencode", "opencode-go-late", reset_at=time.time() + 7200, window="weekly")
assert rb.no_account_left("opencode") != dry_pool_stderr, "the fixture recorded no second wall"
assert not rb.gateway_outage("opencode", 1, dry_pool_stderr)
# And the exclusion note rides on the head line: appended after the labels it would take the last
# one out of the report's `walls:` row, which re-reads each label with a full match.
excluded_stderr = rb.no_account_left(
    "opencode", "; excluded by REVIEW_BENCH_EXCLUDE_OPENCODE: opencode-go-late"
)
assert excluded_stderr.splitlines()[0].endswith("opencode-go-late"), excluded_stderr
assert rb.active_wall_labels("opencode"), "the fixture recorded no wall to label"
assert rb.reported_wall_labels([{"stderr": excluded_stderr}]) == rb.active_wall_labels("opencode")
assert not rb.gateway_outage("opencode", 1, excluded_stderr)
# A weekday names a day only inside the week it belongs to: a monthly wall three weeks out spelled
# "Tue 09:00" reads as tomorrow to whoever decides whether to wait, so past that week the label
# carries a date — and the report's `walls:` row, which re-reads each label whole, takes both.
rb.mark_walled("opencode", "opencode-go-far", reset_at=time.time() + 25 * 86400, window="monthly")
far_wall_label = [line for line in rb.active_wall_labels("opencode") if " far:" in line]
assert far_wall_label and re.search(r", resets [A-Z][a-z]{2} \d{1,2}$", far_wall_label[0]), \
    far_wall_label
assert rb.reported_wall_labels([{"stderr": rb.no_account_left("opencode")}]) == \
    rb.active_wall_labels("opencode")
del os.environ["WORKER_STATS_DIR"]

# A run where every attempt of one family failed and the other answered: one starts cooling, the
# other is left alone — the wait is per cell, and grok being down never rests kimi.
cooldown_now = rb.parse_iso_timestamp("2026-08-08T12:00:00+00:00")
cooldown_errored = {"oc-grok45-low", "oc-grok45-low#2", "oc-grok45-low#3", "oc-kimik3#2"}
rb.note_gateway_outcome(cooldown_raters, cooldown_errored, cooldown_errored, now=cooldown_now)
cooldown_written = json.loads((cooldown_state / "gateway-cooldown.json").read_text())
assert list(cooldown_written) == ["oc-grok45-low"], cooldown_written
# Panels overlap by design (per-pid progress files), and read-modify-write is not made safe by an
# atomic replace: the later writer would resurrect a wait the other just cleared.
assert (cooldown_state / rb.GATEWAY_COOLDOWN_LOCK).exists(), "the cooldown was written unlocked"
assert cooldown_written["oc-grok45-low"]["until"] == "2026-08-08T12:45:00+00:00", cooldown_written

# Inside the wait, exactly one attempt of the cooling family goes — the canary — and the panel
# keeps every cell that is not cooling.
cooldown_kept, cooldown_skipped = rb.apply_gateway_cooldown(
    cooldown_raters, now=rb.parse_iso_timestamp("2026-08-08T12:30:00+00:00")
)
assert [rater["spec"] for rater in cooldown_kept] == [
    "oc-grok45-low", "oc-kimik3", "oc-kimik3#2"
], cooldown_kept
assert [spec for spec, _ in cooldown_skipped] == ["oc-grok45-low#2", "oc-grok45-low#3"], \
    cooldown_skipped
assert "cooling until 12:45Z" in cooldown_skipped[0][1], cooldown_skipped
assert "canary" in cooldown_skipped[0][1], cooldown_skipped

# Past the moment it names, the entry is not a wait at all: nothing sweeps the file, the clock does.
assert rb.apply_gateway_cooldown(
    cooldown_raters, now=rb.parse_iso_timestamp("2026-08-08T12:46:00+00:00")
) == (cooldown_raters, [])

# A family whose every attempt failed on something that is NOT the gateway — a wall, a review that
# came back as prose — is left exactly as it was: neither says the gateway is down, and a wait
# invented over a wall hides the reset the wall already carries.
rb.note_gateway_outcome(
    rb.parse_raters("oc-kimik3 x2"), {"oc-kimik3", "oc-kimik3#2"}, set(),
    now=rb.parse_iso_timestamp("2026-08-08T12:10:00+00:00"),
)
assert list(json.loads((cooldown_state / "gateway-cooldown.json").read_text())) == \
    ["oc-grok45-low"], "a wall was recorded as a gateway outage"

# The canary answering is what ends the wait, and its failing is what extends it — from the moment
# the outage started, which the extension keeps: a wait that restamps its own beginning reads as a
# fresh outage however long the gateway has been down.
rb.note_gateway_outcome(
    rb.parse_raters("oc-grok45-low"), set(), set(),
    now=rb.parse_iso_timestamp("2026-08-08T12:30:00+00:00"),
)
assert json.loads((cooldown_state / "gateway-cooldown.json").read_text()) == {}, "the canary's " \
    "answer left the cell cooling"
rb.note_gateway_outcome(
    cooldown_raters, cooldown_errored, cooldown_errored, now=cooldown_now
)
rb.note_gateway_outcome(
    rb.parse_raters("oc-grok45-low"), {"oc-grok45-low"}, {"oc-grok45-low"},
    now=rb.parse_iso_timestamp("2026-08-08T12:30:00+00:00"),
)
cooldown_extended = json.loads(
    (cooldown_state / "gateway-cooldown.json").read_text()
)["oc-grok45-low"]
assert cooldown_extended["until"] == "2026-08-08T13:15:00+00:00", cooldown_extended
assert cooldown_extended["since"] == "2026-08-08T12:00:00+00:00", cooldown_extended

# Nothing to record is nothing written: a run that changes no verdict must not rewrite the file
# other panels are reading and writing at the same moment.
cooldown_stamp = (cooldown_state / "gateway-cooldown.json").stat().st_mtime_ns
rb.note_gateway_outcome(
    rb.parse_raters("oc-grok45-low"), {"oc-grok45-low"}, {"oc-grok45-low"},
    now=rb.parse_iso_timestamp("2026-08-08T12:30:00+00:00"),
)
assert (cooldown_state / "gateway-cooldown.json").stat().st_mtime_ns == cooldown_stamp

# A cell of a side the pool DOES answer for is none of this mechanism's business: its wall carries
# its own reset, and worker-pick reads it.
assert rb.apply_gateway_cooldown(rb.parse_raters("agy-pro-high-skill,opus-medium")) == (
    rb.parse_raters("agy-pro-high-skill,opus-medium"), []
)
(cooldown_state / "gateway-cooldown.json").unlink()

# A named agy cell is asked of the pool like every other pool-staffed side. Its answer used to be
# overridden with a bare True here, so a panel launched every gemini cell the pool had already said
# it could not staff and reported the lot as errored, rerun line included (Egor, 2026-08-08).
agy_gate_repo = work / "agy-gate"
agy_gate_repo.mkdir()
subprocess.run(["git", "init", "-q", str(agy_gate_repo)], check=True)
subprocess.run(["git", "-C", str(agy_gate_repo), "config", "user.email", "bench@example.test"],
               check=True)
subprocess.run(["git", "-C", str(agy_gate_repo), "config", "user.name", "Review Bench"],
               check=True)
(agy_gate_repo / "a.txt").write_text("base\n")
subprocess.run(["git", "-C", str(agy_gate_repo), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(agy_gate_repo), "commit", "-qm", "initial"], check=True)
(agy_gate_repo / "a.txt").write_text("base\nchanged\n")
agy_gate_store = work / "agy-gate-claudeb"
os.environ["CLAUDEB_DIR"] = str(agy_gate_store)


def agy_gate_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    return 0, 1, json.dumps({
        "severity": "P3", "file": "a.txt", "line": 1, "summary": "a finding",
    }), "", []


for agy_gate_side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[agy_gate_side] = agy_gate_runner
agy_gate_real_afford = rb.affordability
rb.affordability = lambda: {
    "claude": True, "codex": True, "agy": False, "opencode": True,
    "claude_fable": True, "claude_account": "fixture",
}
agy_gate_stdout = io.StringIO()
try:
    with contextlib.redirect_stdout(agy_gate_stdout), contextlib.redirect_stderr(io.StringIO()):
        rb.cmd_run(argparse.Namespace(
            repo=str(agy_gate_repo), commitish=None, worktree=True, paths=None,
            raters="agy-pro-high-skill,sol-medium-bare", leg=False, verify=None, auto=None,
            focus=None,
        ))
finally:
    rb.affordability = agy_gate_real_afford
assert "skipped agy-pro-high-skill: agy side is unaffordable" in agy_gate_stdout.getvalue(), \
    agy_gate_stdout.getvalue()
agy_gate_meta = json.loads(
    (next((agy_gate_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert agy_gate_meta["raters"] == ["sol-medium-bare", "agy-pro-high-skill"], agy_gate_meta
assert not agy_gate_meta["rater_runs"] or all(
    row["rater"] != "agy-pro-high-skill" for row in agy_gate_meta["rater_runs"]
), agy_gate_meta

# The cooldown only pays off if a run consults it and records into it; a panel that computes the
# wait beside the launch and launches anyway is the behaviour this replaced.
cooldown_wiring_store = work / "cooldown-wiring-claudeb"
os.environ["CLAUDEB_DIR"] = str(cooldown_wiring_store)
cooldown_wiring_state = cooldown_wiring_store / "worker-stats"
cooldown_wiring_state.mkdir(parents=True)
(cooldown_wiring_state / "gateway-cooldown.json").write_text(json.dumps({
    "oc-grok45-low": {"until": "2099-01-01T00:00:00+00:00", "since": "2099-01-01T00:00:00+00:00",
                      "reason": "3 attempt(s) failed"},
}))
cooldown_wiring_stdout = io.StringIO()
with contextlib.redirect_stdout(cooldown_wiring_stdout), contextlib.redirect_stderr(io.StringIO()):
    rb.cmd_run(argparse.Namespace(
        repo=str(agy_gate_repo), commitish=None, worktree=True, paths=None,
        raters="oc-grok45-low x3", leg=False, verify=None, auto=None, focus=None,
    ))
assert "cooling until" in cooldown_wiring_stdout.getvalue(), cooldown_wiring_stdout.getvalue()
cooldown_wiring_meta = json.loads(
    (next((cooldown_wiring_store / "worker-stats" / "benches").iterdir()) / "meta.json").read_text()
)
assert cooldown_wiring_meta["raters"] == \
    ["oc-grok45-low", "oc-grok45-low#2", "oc-grok45-low#3"], cooldown_wiring_meta
assert cooldown_wiring_meta["completed_raters"] == ["oc-grok45-low"], cooldown_wiring_meta
assert json.loads((cooldown_wiring_state / "gateway-cooldown.json").read_text()) == {}, \
    "the canary answered and the run left the cell cooling anyway"


def cooldown_wiring_failing_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    return 1, 1, "", "gateway 502", []


for cooldown_wiring_side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[cooldown_wiring_side] = cooldown_wiring_failing_runner
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    rb.cmd_run(argparse.Namespace(
        repo=str(agy_gate_repo), commitish=None, worktree=True, paths=None,
        raters="oc-grok45-low x2", leg=False, verify=None, auto=None, focus=None,
    ))
assert list(json.loads((cooldown_wiring_state / "gateway-cooldown.json").read_text())) == \
    ["oc-grok45-low"], "a run whose every gateway attempt failed recorded no wait"
for cooldown_wiring_side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[cooldown_wiring_side] = agy_gate_runner

# --- multi-source reviews: each repository named the way its half actually exists ----------------
# Half of a cross-repository change is routinely already committed on a branch while the other half
# is still uncommitted, and a merged review that could only read working trees sent the committed
# half to a panel of its own — one change, two panels, two escalation tallies (Egor, 2026-08-08).
assert rb.parse_repo_source("/a/b") == ("/a/b", None)
assert rb.parse_repo_source("/a/b@main..feat") == ("/a/b", "main..feat")
# A checkout whose own path holds an @ is a path, not a range: the `..` is what marks the suffix.
assert rb.parse_repo_source("/srv/user@host/repo") == ("/srv/user@host/repo", None)
assert rb.parse_repo_source("/srv/a@b/repo@main..x") == ("/srv/a@b/repo", "main..x")
# And a directory holding both — `/srv/a@b/x..y/repo` is a path, not repository `/srv/a` over range
# `b/x..y/repo`, which is two things nobody named (found by panel, 2026-08-08).
multi_odd = work / "odd@dir" / "x..y" / "repo"
multi_odd.mkdir(parents=True)
assert rb.parse_repo_source(str(multi_odd)) == (str(multi_odd), None)
assert rb.parse_repo_source(f"{multi_odd}@main..feat") == (str(multi_odd), "main..feat")
multi_source_errors = {}
for multi_label, multi_bad in (("headless", "@main..feat"), ("shape", "/a/b@main..")):
    try:
        rb.parse_repo_source(multi_bad)
        multi_source_errors[multi_label] = ""
    except ValueError as exc:
        multi_source_errors[multi_label] = str(exc)
assert "names no repository before its range" in multi_source_errors["headless"], \
    multi_source_errors
assert "--range must be A..B" in multi_source_errors["shape"], multi_source_errors

multi_repos = {}
for multi_name in ("pushed", "live"):
    multi_path = work / f"multi-{multi_name}"
    multi_path.mkdir()
    subprocess.run(["git", "init", "-q", str(multi_path)], check=True)
    subprocess.run(["git", "-C", str(multi_path), "config", "user.email", "bench@example.test"],
                   check=True)
    subprocess.run(["git", "-C", str(multi_path), "config", "user.name", "Review Bench"],
                   check=True)
    (multi_path / f"{multi_name}.txt").write_text("base\n")
    subprocess.run(["git", "-C", str(multi_path), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(multi_path), "commit", "-qm", "initial"], check=True)
    multi_repos[multi_name] = multi_path
multi_base = subprocess.run(["git", "-C", str(multi_repos["pushed"]), "rev-parse", "HEAD"],
                            check=True, capture_output=True, text=True).stdout.strip()
for multi_step in ("one", "two"):
    (multi_repos["pushed"] / "pushed.txt").write_text(f"base\nthe committed half {multi_step}\n")
    subprocess.run(["git", "-C", str(multi_repos["pushed"]), "commit", "-aqm", multi_step],
                   check=True)
multi_head = subprocess.run(["git", "-C", str(multi_repos["pushed"]), "rev-parse", "HEAD"],
                            check=True, capture_output=True, text=True).stdout.strip()
(multi_repos["live"] / "live.txt").write_text("base\nthe uncommitted half\n")
multi_tops = {name: rb.resolve_repo_arg(str(path)) for name, path in multi_repos.items()}

# The two halves as one panel: the committed one by its own range, the uncommitted one by its tree.
multi_members = rb.merged_members(
    [(str(multi_repos["pushed"]), f"{multi_base}..{multi_head}"), str(multi_repos["live"])]
)
assert multi_members[0]["head"] == multi_head, multi_members
assert multi_members[0]["base"] == multi_base, multi_members
assert rb.range_snapshot_ends(multi_repos["pushed"], multi_members[0]["commit"]) == (
    multi_base, multi_head
), multi_members
assert "head" not in multi_members[1], multi_members
multi_message = rb.merged_snapshot_message(multi_members)
assert f"range {multi_base[:7]}..{multi_head[:7]}" in multi_message, multi_message
# The first thing every rater reads, so it says which kind of snapshot this is and says it in whole
# sentences: a line broken mid-clause is one they read as the end of the thought.
assert multi_message.splitlines()[0] == "review-bench merged worktree snapshot", multi_message
assert rb.merged_snapshot_message([
    dict(member, head=member.get("head") or member["commit"]) for member in multi_members
]).splitlines()[0] == "review-bench merged range snapshot"
assert min(len(line) for line in multi_message.splitlines()[2:6]) > 60, multi_message

multi_store = work / "multi-claudeb"
os.environ["CLAUDEB_DIR"] = str(multi_store)
multi_state = multi_store / "worker-stats"
multi_seen = []


def multi_runner(rater, repo_path, commit, focus, run_dir, diff, account):
    multi_seen.append(diff)
    return 0, 1, json.dumps({
        "severity": "P2", "file": "multi-pushed/pushed.txt", "line": 1,
        "summary": "cross-repository finding",
    }), "", []


for multi_side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[multi_side] = multi_runner


def multi_run(repo_args, **fields):
    call = dict(repo=repo_args, commitish=None, worktree=True, paths=None,
                raters="sol-medium-bare", leg=False, verify=None, auto=None, focus=None)
    call.update(fields)
    stdout = io.StringIO()
    # The target line is announced on stderr, and it is half of what these runs are checked for.
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stdout):
        rc = rb.cmd_run(argparse.Namespace(**call))
    return rc, stdout.getvalue()


def multi_meta_of(stdout):
    """The meta of the run that printed this output. Two runs of one second sort by their sha, so
    the newest directory is not reliably the newest run."""
    run_id = next(line.split(": ", 1)[1] for line in stdout.splitlines()
                  if line.startswith("run id: "))
    return json.loads((multi_state / "benches" / run_id / "meta.json").read_text())


multi_rc, multi_stdout = multi_run(
    [f"{multi_repos['pushed']}@{multi_base}..{multi_head}", str(multi_repos["live"])]
)
assert multi_rc == 0, multi_stdout
multi_first_stdout = multi_stdout
multi_meta = multi_meta_of(multi_stdout)
# One diff holding both halves, each under its own prefix — the committed lines included.
assert len(multi_seen) == 1, multi_seen
assert "the committed half two" in multi_seen[0], multi_seen[0]
assert "the uncommitted half" in multi_seen[0], multi_seen[0]
assert [member.get("head") for member in multi_meta["repos"]] == [multi_head, None], multi_meta
# Each half is stamped the way a review of it alone would stamp it: the committed half's range ends
# on the tree standing in the repository, so its receipt names the range the panel actually read.
multi_pushed_receipt = rb.review_receipt(multi_tops["pushed"])
assert multi_pushed_receipt["run_id"] == multi_meta["run_id"], multi_pushed_receipt
assert rb.diff_base(multi_tops["pushed"], multi_pushed_receipt["commit"]) == multi_base, \
    multi_pushed_receipt
assert rb.review_receipt(multi_tops["live"])["run_id"] == multi_meta["run_id"]

# A range ending anywhere but the tree in front of the reader answers for nothing: the same rule a
# single-repository range run follows, asked per member because one panel now holds both kinds.
multi_old = work / "multi-old"
shutil.copytree(multi_repos["pushed"], multi_old)
subprocess.run(["git", "-C", str(multi_old), "reset", "-q", "--hard", multi_head], check=True)
(multi_old / "pushed.txt").write_text("base\nthe committed half two\nand more after it\n")
subprocess.run(["git", "-C", str(multi_old), "commit", "-aqm", "after"], check=True)
multi_old_top = rb.resolve_repo_arg(str(multi_old))
(multi_repos["live"] / "live.txt").write_text("base\nthe uncommitted half, again\n")
multi_rc, multi_stdout = multi_run(
    [f"{multi_old}@{multi_base}..{multi_head}", str(multi_repos["live"])]
)
assert multi_rc == 0, multi_stdout
multi_second = multi_meta_of(multi_stdout)
assert rb.review_receipt(multi_old_top) is None, "a range of old commits stamped its repository"
assert rb.review_receipt(multi_tops["live"])["run_id"] == multi_second["run_id"]

# One repository named with a range is that repository's own range run — no workspace, and the
# rerun and receipt keep the plain shape a --range run leaves.
multi_rc, multi_stdout = multi_run([f"{multi_repos['pushed']}@{multi_base}..{multi_head}"],
                                   worktree=False)
assert multi_rc == 0, multi_stdout
multi_solo = multi_meta_of(multi_stdout)
assert "repos" not in multi_solo, multi_solo
assert multi_solo["repo"] == str(multi_tops["pushed"]), multi_solo
assert rb.range_snapshot_ends(multi_tops["pushed"], multi_solo["commit"]) == (
    multi_base, multi_head
), multi_solo
assert f"{multi_base[:7]}..{multi_head[:7]}" in multi_stdout, multi_stdout
# The merged run announces each member by its own ends too, so a range member is never named by
# the sha the tool sealed it into.
assert f"multi-pushed/ = {multi_tops['pushed']}: {multi_base[:7]}..{multi_head[:7]}" \
    in multi_first_stdout, multi_first_stdout

# What the inline form refuses. Every one of these before anything is sealed.
multi_refusals = {}
for multi_label, multi_args, multi_fields in (
    ("commitish", [f"{multi_repos['pushed']}@{multi_base}..{multi_head}"],
     {"commitish": multi_head, "worktree": False}),
    ("both-flags", [f"{multi_repos['pushed']}@{multi_base}..{multi_head}"], {"worktree": True}),
    ("mixed-bare", [f"{multi_repos['pushed']}@{multi_base}..{multi_head}",
                    str(multi_repos["live"])], {"worktree": False}),
    # A pathspec outside the range's own diff narrows the review to nothing, and a member sealed
    # over an empty scope is a half of the panel that reads as reviewed and was never shown.
    ("scoped-nothing", [f"{multi_repos['pushed']}@{multi_base}..{multi_head}",
                        str(multi_repos["live"])],
     {"paths": ["multi-pushed/never-here.txt"]}),
):
    try:
        multi_run(multi_args, **multi_fields)
        multi_refusals[multi_label] = ""
    except ValueError as exc:
        multi_refusals[multi_label] = str(exc)
assert "the run's target is already given" in multi_refusals["commitish"], multi_refusals
assert "drop --worktree" in multi_refusals["both-flags"], multi_refusals
assert "add --worktree" in multi_refusals["mixed-bare"], multi_refusals
assert "matched nothing" in multi_refusals["scoped-nothing"], multi_refusals

# ...and a pathspec the range DOES touch narrows that member the way --paths narrows a working
# tree: the member carries the scope, and its repository's own receipt stays where it was, because
# a narrowed review answers to a receipt of its own and never marks the repository reviewed.
multi_pushed_before = rb.review_receipt(multi_tops["pushed"])
multi_rc, multi_stdout = multi_run(
    [f"{multi_repos['pushed']}@{multi_base}..{multi_head}", str(multi_repos["live"])],
    paths=["multi-pushed/pushed.txt"],
)
assert multi_rc == 0, multi_stdout
multi_scoped = multi_meta_of(multi_stdout)
assert [member["scope"] for member in multi_scoped["repos"]] == [["pushed.txt"], []], multi_scoped
assert rb.review_receipt(multi_tops["pushed"]) == multi_pushed_before, "a scoped member stamped it"
assert rb.review_receipt(multi_tops["pushed"], scope=["pushed.txt"])["run_id"] == \
    multi_scoped["run_id"], "the scoped member wrote no receipt of its own"

os.environ["CLAUDEB_DIR"] = str(merged_store)

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
# Every report carries the verdict on its own tally, in the commit gate's words: a round is closed
# here or it owes another, and the block that says neither is the one a chat read as "done" while a
# second review was owed (2026-08-08).
expected_report="$report_frame_header"$'\nreview-bench panel · T2 · 5.5 min wall · slowest completed: sol-high 2 min\nconfirmed 1:    P1 1\nround:          closed — nothing more is owed before the commit\nfixes:          NOT APPLIED — pending\nrejected:       1 duplicate  ~400 tok\n                2 false      ~3k tok\nfalse by:       kimi ×1 · sol-high ×1\nverifier:       off — 2 finding(s) unchecked\ncells:          sol-high 1/2 · kimi 0/2\nerrored:        opus-med-bare 15 sec (exit 2)\ntimeout:        gem-flash36-med 4 min (watchdog cap 4 min)\nmismatch:       gem-flash35-low\nwall gated by:  gem-flash36-med 4 min (timeout)\n'"$report_frame_footer"
assert test "$report_output" = "$expected_report"
# The frame is what the reader and every consumer of this block see first: a word centered in '='
# to exactly 50 characters, and a footer of exactly 50 more.
assert test "${#report_frame_header}" -eq 50
# Counted in python: bash counts BYTES outside a UTF-8 locale, and the separator in this one made
# the pin fail under the LC_ALL=C a headless runner inherits.
assert test "$(python3 -c 'import sys; print(len(sys.argv[1]))' \
  "$report_frame_header")" -eq 50
assert test "${#report_frame_footer}" -eq 50
assert grep -qE '^=+ review( · NOT FINISHED)? =+$' <<<"$(head -1 <<<"$report_output")"
assert grep -qE '^={10,}$' <<<"$(tail -1 <<<"$report_output")"
# The header must not read as the footer, or a consumer closing the block on its end shape closes
# it on the line that opens it.
assert test "$(grep -cE '^={10,}$' <<<"$report_output")" = "1"
assert contains "$report_output" $'rejected:       1 duplicate  ~400 tok\n                2 false      ~3k tok'
assert contains "$report_output" $'false by:       kimi ×1 · sol-high ×1\nverifier:       off — 2 finding(s) unchecked\ncells:          sol-high 1/2 · kimi 0/2\nerrored:        opus-med-bare 15 sec (exit 2)\ntimeout:        gem-flash36-med 4 min (watchdog cap 4 min)\nmismatch:       gem-flash35-low\nwall gated by:  gem-flash36-med 4 min (timeout)'
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

# A dead cell's own numbers. The run this was written for held the panel 27.5 minutes while the
# block said "slowest completed: 16.8 min" and named the hung cell with nothing beside it — its
# duration, the budget that killed it and its failure streak were all on disk and none of them
# reachable by Egor (2026-08-16).
FAIL_SD="$WORK/failure-observability-state"
mkdir -p "$FAIL_SD/benches"
python3 - "$FAIL_SD/benches" <<'PY'
import json
import pathlib
import sys

benches = pathlib.Path(sys.argv[1])


def write_run(run_id, rows, verdicts=None, findings=None):
    run = benches / run_id
    run.mkdir(parents=True)
    (run / "meta.json").write_text(json.dumps({
        "run_id": run_id, "commit": "a" * 40, "repo": "/fixture", "tier": "T2",
        "raters": [row["rater"] for row in rows], "rater_runs": rows,
        "durations": {}, "started": "2026-01-01T00:00:00+00:00",
        "finished": "2026-01-01T00:27:30+00:00", "focus": "",
    }))
    for rater, rater_findings in (findings or {}).items():
        (run / f"findings-{rater}.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in rater_findings)
        )
    if verdicts is not None:
        (run / "verdicts.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in verdicts)
        )


flash35 = {"model": "agy-flash35", "effort": "medium", "side": "agy"}
# The shape the observability gap was found on: the CLI gave up on its own, so no cap of ours
# killed it and the row carries a duration and nothing else.
client_timeout = dict(
    flash35, rater="agy-flash35-medium-skill", findings=0, exit_code=1, errored=True,
    stderr="Error: timeout waiting for response", duration_ms=900_000,
)
opus_failure = {
    "rater": "opus-medium", "model": "opus", "effort": "medium", "side": "claude",
    "duration_ms": 15_000, "findings": 0, "exit_code": 2, "errored": True,
    "stderr": "fixture failure",
}
completed = lambda rater, **row: dict(
    {"rater": rater, "findings": 0, "exit_code": 0, "duration_ms": 1000}, **row
)

write_run("20260101T000100Z-aaaaaaa", [
    completed("agy-flash35-medium-skill", **flash35),
    completed("opus-medium", model="opus", effort="medium", side="claude"),
])
write_run("20260101T000200Z-bbbbbbb", [dict(client_timeout)])
# A run that never held the cell must not end its streak.
write_run("20260101T000300Z-ccccccc", [
    completed("sol-high", model="sol", effort="high", side="codex"),
])
write_run("20260101T000400Z-ddddddd", [dict(client_timeout), dict(opus_failure)])
write_run(
    "20260101T000500Z-eeeeeee",
    [
        completed("oc-kimik3", model="oc-kimik3", effort=None, side="opencode",
                  duration_ms=60_000, findings=3),
        completed("sol-high", model="sol", effort="high", side="codex",
                  duration_ms=90_000, findings=5),
        completed("oc-glm52", model="oc-glm52", effort=None, side="opencode",
                  duration_ms=30_000, findings=1),
        dict(client_timeout, duration_ms=1_627_857),
        dict(flash35, model="agy-flash36", rater="agy-flash36-medium-skill",
             duration_ms=1_200_000, timeout_s=1020, findings=0, exit_code=124, errored=True,
             stderr="rater timed out after 1020s", killed="watchdog", killed_cap_s=1020,
             max_quiet_ms=60_000),
        {"rater": "agy-pro-high-skill", "model": "agy-pro", "effort": "high", "side": "agy",
         "duration_ms": 400_000, "findings": 0, "exit_code": 124, "errored": True,
         "stderr": "rater stalled: no output activity for 360s (stall cap 240s)",
         "stalled_s": 240, "killed": "stall", "killed_cap_s": 240, "max_quiet_ms": 360_000},
        dict(opus_failure),
    ],
    verdicts=[
        {"rater": "oc-kimik3", "idx": 0, "verdict": "confirmed"},
        {"rater": "oc-kimik3", "idx": 1, "verdict": "confirmed"},
        {"rater": "oc-glm52", "idx": 0, "verdict": "confirmed"},
        {"rater": "sol-high", "idx": 0, "verdict": "duplicate"},
    ],
    findings={
        "oc-kimik3": [
            {"severity": "P1", "file": "a.py", "line": index, "summary": f"kimi {index}",
             "rater": "oc-kimik3"}
            for index in range(3)
        ],
        "sol-high": [
            {"severity": "P2", "file": "b.py", "line": index, "summary": f"sol {index}",
             "rater": "sol-high"}
            for index in range(5)
        ],
        "oc-glm52": [
            {"severity": "P2", "file": "c.py", "line": 1, "summary": "glm", "rater": "oc-glm52"},
        ],
    },
)
write_run("20260101T000600Z-fffffff", [
    completed("sol-high", model="sol", effort="high", side="codex", duration_ms=300_000),
    dict(opus_failure, duration_ms=5_000),
], verdicts=[])
PY
assert test "$?" -eq 0
fail_report=$(WORKER_STATS_DIR="$FAIL_SD" "$SCRIPT" report 20260101T000500Z-eeeeeee) \
  || fail "failure-observability report failed"
# Sorted by what survived triage, then by raw findings, then by name: the row answers which models
# earned their place in the next panel, which the launch order never said.
assert contains "$fail_report" 'cells:          kimi 2/3 · glm52 1/1 · sol-high 0/5'
# The budget that killed the cell, named apart from a client that gave up on its own — both arrive
# as the same status and the same "timed out" wording.
assert contains "$fail_report" 'gem-flash36-med 20 min (watchdog cap 17 min)'
assert contains "$fail_report" 'gem-pro 6.7 min (stalled, quiet 6 min)'
# Three runs in a row failing, counted over the runs that held the cell — the run between them
# that never launched it is passed over, not read as a recovery.
assert contains "$fail_report" 'gem-flash35-med 27.1 min (3 fails in a row)'
assert contains "$fail_report" 'errored:        opus-med-bare 15 sec (exit 2)'
# The hung cell held the panel for the whole wall while "slowest completed" priced 1.5 minutes of
# it: without this line the gate is invisible in the block Egor reads.
assert contains "$fail_report" 'wall gated by:  gem-flash35-med 27.1 min (timeout)'
# Two failures are a bad night, not a chronic cell.
assert test "$(grep -c 'fails in a row' <<<"$fail_report")" = "1"
# And the line is silent where the wall was the panel's own work: a completed cell gating it is
# what "slowest completed" already says.
fail_clean=$(WORKER_STATS_DIR="$FAIL_SD" "$SCRIPT" report 20260101T000600Z-fffffff) \
  || fail "failure-observability clean report failed"
assert test "$(grep -c 'wall gated by:' <<<"$fail_clean")" = "0"
assert contains "$fail_clean" 'errored:      opus-med-bare 5 sec (exit 2, 3 fails in a row)'
# A meta written before any of these keys existed still renders: the report shows what it has and
# claims no cause it was never told.
python3 - "$FAIL_SD/benches" <<'PY'
import json
import pathlib
import sys

benches = pathlib.Path(sys.argv[1])
run = benches / "20260101T000700Z-9999999"
run.mkdir(parents=True)
(run / "meta.json").write_text(json.dumps({
    "run_id": "20260101T000700Z-9999999", "commit": "a" * 40, "repo": "/fixture", "tier": "T2",
    "raters": ["sol-high", "agy-pro-high-skill", "oc-kimik3"],
    "rater_runs": [
        {"rater": "sol-high", "model": "sol", "effort": "high", "side": "codex",
         "exit_code": 0},
        {"rater": "agy-pro-high-skill", "model": "agy-pro", "effort": "high", "side": "agy",
         "duration_ms": 245_000, "findings": 0, "exit_code": 124, "errored": True,
         "stalled_s": 240,
         "stderr": "rater stalled: no output activity for 241s (stall cap 240s)"},
        {"rater": "oc-kimik3", "model": "oc-kimik3", "effort": None, "side": "opencode",
         "findings": 0, "exit_code": 2, "errored": True, "stderr": "fixture failure"},
    ],
    "durations": {}, "started": "2026-01-01T00:00:00+00:00",
    "finished": "2026-01-01T00:05:00+00:00", "focus": "",
}))
(run / "verdicts.jsonl").write_text("")
PY
assert test "$?" -eq 0
legacy_kill_report=$(WORKER_STATS_DIR="$FAIL_SD" "$SCRIPT" report 20260101T000700Z-9999999) \
  || fail "legacy-kill report failed"
assert contains "$legacy_kill_report" 'gem-pro 4.1 min (stalled, cap 4 min)'
assert contains "$legacy_kill_report" 'wall gated by:  gem-pro 4.1 min (stalled)'
# A cell whose duration was never recorded loses its own figure and nothing else.
assert contains "$legacy_kill_report" 'errored:        kimi (exit 2)'

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

# The board is a metric audit as much as a table. `misses` are adjudicated against one run's own
# panel, so a cell that ran solo — or beside its own family alone — is scored against nothing but
# its own catches, and the coverage column has to stay empty there rather than print the 100% that
# arithmetic implies (docs/research/opencode-raters-2026-08.md §26b).
BSD="$WORK/board-stats"
mkdir -p "$BSD"
python3 - "$BSD" <<'PY'
import json
import pathlib
import sys

stats = pathlib.Path(sys.argv[1])
# board-shared anchors oc-kimik3 and nothing else: sol-medium's only panel-mate is an oc cell,
# which is exactly the partner the rule refuses to count as a reference. The three board-panel
# runs are what carries sol-medium and opus-high past the low-evidence thresholds, so the same
# fixture proves the guard fires and that it stops firing.
rows = [
    ("board-shared", "sol-medium", "sol", "a" * 40, 3, 1, 1, 200_000),
    ("board-shared", "oc-kimik3", "oc-kimik3", "a" * 40, 1, 3, 0, 20_000),
    ("board-repeat", "oc-kimik3#2", "oc-kimik3", "b" * 40, 9, 0, 2, 40_000),
    ("board-solo", "oc-glm52", "oc-glm52", "b" * 40, 5, 0, 0, 700_000),
    # One family under three spellings, of which the pool launches the first alone. Named
    # against the pool alone all three are "grok", so the two the pool cannot launch would take
    # the live cell's own name away from it.
    ("board-grok", "oc-grok45-low", "oc-grok45", "f" * 40, 1, 0, 0, 100_000),
    ("board-grok", "oc-grok45-medium", "oc-grok45", "f" * 40, 1, 0, 0, 110_000),
    ("board-grok", "oc-grok45", "oc-grok45", "f" * 40, 1, 0, 0, 120_000),
    ("board-grok", "oc-dsv4flash-medium", "oc-dsv4flash", "f" * 40, 1, 0, 0, 130_000),
    # A corpus row under the retired spelling of a cell the pool still launches.
    ("board-legacy", "agy-flash-low-skill", "agy-flash36", "f" * 40, 2, 0, 0, 90_000),
]
for index, commit in enumerate(("c", "d", "e"), 1):
    rows.append((f"board-panel{index}", "sol-medium", "sol", commit * 40, 2, 1, 0, 200_000))
    rows.append((f"board-panel{index}", "opus-high", "opus", commit * 40, 1, 2, 0, 400_000))
(stats / "benches").mkdir(parents=True, exist_ok=True)
(stats / "reviews.jsonl").write_text("".join(
    json.dumps({
        "run_id": run_id, "rater": rater, "rater_model": model, "rater_effort": "medium",
        "commit": commit, "confirmed": confirmed, "misses": misses, "false_positive": fp,
        "duration_ms": duration, "repo": "fixture", "ts": "2026-08-17T00:00:00+00:00",
    }) + "\n"
    for run_id, rater, model, commit, confirmed, misses, fp, duration in rows
))
# Both vendor spellings of one usage record, under the repeat suffix the cell name drops and the
# file name keeps.
for run_id, rater, usage in (
    ("board-shared", "oc-kimik3",
     {"prompt_tokens": 60000, "completion_tokens": 2000, "total_tokens": 62000}),
    ("board-repeat", "oc-kimik3#2",
     {"input_tokens": 78000, "output_tokens": 4000, "total_tokens": 82000}),
    ("board-panel1", "opus-high",
     {"input_tokens": 900000, "output_tokens": 100000, "total_tokens": 1000000}),
):
    directory = stats / "benches" / run_id
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"usage-{rater}.json").write_text(json.dumps(usage))
# What a run launched, against what anyone ever judged, and whether it ever finished: board-raw
# was adjudicated by nobody, board-shared judged two of the three cells it ran, and board-running
# is a bench in flight — a meta.json exists for it the moment it starts, and its cells are work
# rather than evidence until the finish stamp lands. A cell the run marked errored finished the
# bench without measuring anything, so it is no reserve either.
for run_id, finished, raters in (
    ("board-shared", "2026-08-17T00:05:00+00:00",
     ("sol-medium", "oc-kimik3", "oc-kimik3#3")),
    ("board-raw", "2026-08-17T00:06:00+00:00",
     ("oc-kimik3", "oc-kimik3#2", "sol-medium", "raw-only-cell", "agy-flash-low-skill#2",
      "opus-low", "raw-volume-cell", "raw-volume-cell#2", "raw-volume-cell#3",
      {"rater": "errored-only-cell", "errored": True})),
    ("board-running", None, ("oc-kimik3#9", "never-finished-cell")),
):
    directory = stats / "benches" / run_id
    directory.mkdir(parents=True, exist_ok=True)
    meta = {"run_id": run_id, "rater_runs": [
        entry if isinstance(entry, dict) else {"rater": entry} for entry in raters]}
    if finished:
        meta["finished"] = finished
    (directory / "meta.json").write_text(json.dumps(meta))
PY
assert test "$?" -eq 0

board_json=$(WORKER_STATS_DIR="$BSD" "$SCRIPT" board --json) \
  || fail "board refused a fixture corpus"
board_has() { jq -e "$1" >/dev/null <<<"$board_json"; }
assert board_has '.[] | select(.cell == "oc-kimik3") | .cov_anch == 25'
assert board_has '.[] | select(.cell == "oc-kimik3")
  | .n_anchored == 1 and .n_runs == 2 and .n_commits == 2'
assert board_has '.[] | select(.cell == "oc-glm52") | .cov_anch == null and .n_anchored == 0'
# One anchored run behind a coverage number is the artifact anchoring exists to kill, one step in,
# so the number stays visible and says so; three runs over five defects is what clears it.
assert board_has '.[] | select(.cell == "oc-kimik3")
  | .low_evidence == true and .anchored_denominator == 4'
assert board_has '.[] | select(.cell == "sol-medium")
  | .low_evidence == false and .anchored_denominator == 9 and (.cov_anch * 10 | round) == 667'
assert board_has '.[] | select(.cell == "oc-glm52") | .low_evidence == true'
# oc-kimik3#9 is the in-flight run's, and a bench nobody has finished measures nothing yet.
assert board_has '.[] | select(.cell == "oc-kimik3") | .n_raw == 3'
assert board_has '.[] | select(.cell == "sol-medium") | .n_raw == 1'
assert board_has '.[] | select(.cell == "opus-high") | .n_raw == 0'
assert board_has '[.[] | select(.cell == "never-finished-cell")] == []'
# A model only bench runs have ever measured is the refinement reserve, and a board that drops it
# answers "nothing here" about a cell holding evidence. Same keys as any other row, all null.
assert board_has '.[] | select(.cell == "raw-only-cell")
  | .n_raw == 1 and .tier == "?" and .n_runs == null and .n_commits == null
    and .model == null and .cov_anch == null and .med_wall_s == null and .cost_units == null'
assert board_has '([.[] | select(.cell == "raw-only-cell") | keys] | first)
  == ([.[] | select(.cell == "oc-kimik3") | keys] | first)'
# A cell its own run recorded as errored measured nothing, and a raw+ reserve of failures is a
# reserve of nothing.
assert board_has '[.[] | select(.cell == "errored-only-cell")] == []'
# Named the way the corpus would name it today, not the way the bench that ran it spelled it —
# the corpus row and the raw count of one cell answer to one key, or the legacy half of it splits
# off as a cell no side parses.
assert board_has '.[] | select(.cell == "agy-flash36-low-skill")
  | .n_raw == 1 and .n_runs == 1 and .leg == "gemini"'
assert board_has '[.[] | select(.cell == "agy-flash-low-skill")] == []'
# One derivation names a cell everywhere a human reads it, and it is the pool that decides how
# much a name has to carry: kimi stands alone, while opus-high has a skilled twin in the pool and
# so has to say which of the two it is.
assert board_has '.[] | select(.cell == "oc-kimik3") | .display == "kimi"'
assert board_has '.[] | select(.cell == "sol-medium") | .display == "sol-med"'
assert board_has '.[] | select(.cell == "opus-high") | .display == "opus-high-bare"'
assert board_has '.[] | select(.cell == "raw-only-cell") | .display == "raw-only-cell"'
assert board_has '.[] | select(.cell == "agy-flash36-low-skill") | .display == "gem-flash36-low"'
assert board_has '.[] | select(.cell == "oc-kimik3") | .leg == "opencode"'
assert board_has '.[] | select(.cell == "sol-medium") | .leg == "openai"'
assert board_has '.[] | select(.cell == "opus-high") | .leg == "claude"'
assert board_has '.[] | select(.cell == "agy-flash36-low-skill") | .leg == "gemini"'
assert board_has '.[] | select(.cell == "raw-only-cell") | .leg == "other"'
# A retired spelling no side parses any more is still billed against the plan its prefix names,
# and the cost column and the family filters read that prefix — one cell, one leg.
assert board_has '.[] | select(.cell == "oc-dsv4flash-medium")
  | .leg == "opencode" and .cost_unit == "go-request"'
# Every row is named over the whole board rather than over the pool alone, so two cells one tier
# cannot launch never answer to the same name — nor take one away from the cell that still runs.
assert board_has '[.[] | .display] | length == (unique | length)'
assert board_has '.[] | select(.cell == "oc-grok45-low") | .display == "grok"'
assert board_has '.[] | select(.cell == "oc-grok45-medium") | .display != "grok"'
assert board_has '.[] | select(.cell == "oc-grok45") | .display == "oc-grok45"'
assert board_has '.[] | select(.cell == "oc-grok45-low") | .in_panel == true'
assert board_has '.[] | select(.cell == "oc-grok45-medium") | .in_panel == false'
# Against the panel of the cell's OWN tier: a cell measured at T0 answers for what T0 launches.
# A cell no one has adjudicated is still in the panel it is in: membership belongs to the pool,
# and reading it off a row's measured wall clock leaves every unmeasured cell out of every panel.
assert board_has '.[] | select(.cell == "opus-low")
  | .in_panel == true and .n_runs == null and .n_raw == 1'
assert board_has '.[] | select(.cell == "oc-kimik3") | .in_panel == true'
assert board_has '.[] | select(.cell == "opus-high") | .in_panel == true'
assert board_has '.[] | select(.cell == "sol-medium") | .in_panel == false'
assert board_has '.[] | select(.cell == "oc-glm52") | .in_panel == false'
assert board_has '.[] | select(.cell == "oc-kimik3")
  | .mean_total_tokens == 72000 and .mean_output_tokens == 3000'
assert board_has '.[] | select(.cell == "sol-medium") | .mean_total_tokens == null'
assert board_has '.[] | select(.cell == "oc-kimik3")
  | (.cost_units * 10000 | round) == 90909 and (.value * 100 | round) == 275'
assert board_has '.[] | select(.cell == "oc-glm52")
  | (.cost_units * 10000 | round) == 11364 and .value == null'
# The other side of the plan-request unit: a vendor billed per token is priced over its own mean
# usage, and a cell nobody has a usage artifact for is priced not at all rather than at zero.
assert board_has '.[] | select(.cell == "opus-high")
  | .cost_units == 5 and .cost_unit == "price-proxy" and (.value * 10 | round) == 67'
assert board_has '.[] | select(.cell == "oc-kimik3") | .cost_unit == "go-request"'
assert board_has '.[] | select(.cell == "sol-medium")
  | .cost_units == null and .cost_unit == null'
assert board_has '[.[] | select(.cell == "oc-kimik3") | .tier] == ["T0"]'
assert board_has '[.[] | select(.cell == "sol-medium") | .tier] == ["T1"]'
assert board_has '[.[] | select(.cell == "opus-high") | .tier] == ["T2"]'
assert board_has '[.[] | select(.cell == "oc-glm52") | .tier] == ["T3"]'
assert test -z "$(jq -r 'if type == "object" then "object" else empty end' <<<"$board_json")"
board_hand_json=$(WORKER_STATS_DIR="$BSD" "$SCRIPT" board --json --hand)
assert jq -e '.cells | length == 12' >/dev/null <<<"$board_hand_json"
assert jq -e '.tiers | keys == ["T0","T1","T2","T3"]' >/dev/null <<<"$board_hand_json"
assert jq -e '.tiers.T0.budget_min == 3 and (.tiers.T0.panel | index("kimi")) != null
  and (.tiers.T0.panel | index("oc-kimik3")) == null' >/dev/null <<<"$board_hand_json"
assert jq -e '.constants.min_anchored_runs == 3 and .constants.min_anchored_defects == 5
  and .constants.cost_scale == 1000 and .constants.price_weights.anthropic.opus == 5
  and .constants.price_weights.google.flash == 6
  and .constants.go_requests_5h["kimi-k3"] == 110
  and .constants.go_usage_weight["gpt-5.6-luna"] == 2' >/dev/null <<<"$board_hand_json"
assert jq -e '(.hand_scored | length) == 5
  and all(.hand_scored[]; .source == "docs/research/opencode-raters-2026-08.md")' \
  >/dev/null <<<"$board_hand_json"

board_out=$(WORKER_STATS_DIR="$BSD" "$SCRIPT" board)
# The static block names cells too, so every filter assertion below reads the tier tables alone.
board_tiers_only() { WORKER_STATS_DIR="$BSD" "$SCRIPT" board "$@" | sed '/^hand-scored/,$d'; }
assert contains "$board_out" 'T0 (<= 3 min)'
assert contains "$board_out" 'T3 (<= 20 min)'
assert contains "$board_out" 'cov* is anchored-only coverage'
assert contains "$board_out" 'solo/family-only runs are excluded from it by design'
assert contains "$board_out" 'cost is two units that do NOT compare'
assert contains "$board_out" '25.0?'
assert contains "$board_out" '66.7'
grep -q '66\.7?' <<<"$board_out" && fail "board flagged a cell that cleared both thresholds"
assert contains "$board_out" 'counted only over benches that finished'
board_raw_only=$(grep '^raw-only-cell' <<<"$board_out")
assert contains "$board_raw_only" '·'
assert test "$(awk '{print $3}' <<<"$board_raw_only")" = "1"
assert contains "$board_out" 'hand-scored (out of corpus)'
assert contains "$board_out" 'needs a /responses client in bin/opencode-go'
board_no_oc=$(board_tiers_only --no-oc)
assert contains "$board_no_oc" 'sol-med'
assert jq -e 'length > 0 and all(.[]; .cell | startswith("oc-") | not)' >/dev/null \
  <<<"$(WORKER_STATS_DIR="$BSD" "$SCRIPT" board --json --no-oc)"
board_oc_only=$(board_tiers_only --oc-only)
assert contains "$board_oc_only" 'kimi'
assert jq -e 'length > 0 and all(.[]; .cell | startswith("oc-"))' >/dev/null \
  <<<"$(WORKER_STATS_DIR="$BSD" "$SCRIPT" board --json --oc-only)"
WORKER_STATS_DIR="$BSD" "$SCRIPT" board --no-oc --oc-only >/dev/null 2>&1 \
  && fail "board accepted two contradictory family filters"
board_tier=$(board_tiers_only --tier T0)
assert contains "$board_tier" 'kimi'
grep -q 'sol-med' <<<"$board_tier" && fail "board --tier T0 kept a T1 cell"
# A blank cell drops a column silently, and nobody reads this format by eye to notice.
board_tsv=$(WORKER_STATS_DIR="$BSD" "$SCRIPT" board --tsv)
assert test "$(head -1 <<<"$board_tsv" | cut -f1)" = "tier"
assert test "$(awk -F'\t' '{print NF}' <<<"$board_tsv" | sort -u)" = "14"
assert test "$(awk -F'\t' '$2 == "oc-glm52" {print $1}' <<<"$board_tsv")" = "T3"
assert test "$(grep -c '' <<<"$board_tsv")" -eq 13
assert test -z "$(awk -F'\t' '$2 == "oc-glm52" {print $10}' <<<"$board_tsv")"
# The dim placeholder the eye reads as "nothing here" is a value to everything that parses this.
assert test -z "$(awk -F'\t' '$2 == "raw-only-cell" {print $3 $5 $6 $14}' <<<"$board_tsv")"
assert test "$(awk -F'\t' '$2 == "raw-only-cell" {print $4}' <<<"$board_tsv")" = "1"
# Rows the corpus cannot tell apart still have to come out in one order, and the volume behind
# them is the only thing that ranks them.
assert test "$(awk -F'\t' '$2 ~ /^raw-(volume|only)-cell$/ {print $2}' <<<"$board_tsv" \
  | head -1)" = "raw-volume-cell"
assert test "$(awk -F'\t' '$2 == "oc-kimik3" {print $10}' <<<"$board_tsv")" = "25.0?"
grep -q 'hand-scored' <<<"$board_tsv" && fail "board --tsv carried the hand-scored block unasked"
assert contains "$(WORKER_STATS_DIR="$BSD" "$SCRIPT" board --tsv --hand)" \
  'qwen3.8-max medium'

# The second renderer of the same board: it reads review-bench from its own directory and
# inherits the fixture store, so a broken template or a dropped column shows up here.
BOARD_HTML="$WORK/board.html"
WORKER_STATS_DIR="$BSD" "$ROOT/bin/review-board-html" "$BOARD_HTML" \
  || fail "review-board-html refused the fixture board"
board_html=$(cat "$BOARD_HTML")
assert contains "$board_html" 'raw-only-cell'
assert contains "$board_html" 'out-ktok'
grep -q '__DATA__\|__TIERS__\|__GENERATED__\|__NCELLS__\|__NRUNS__' "$BOARD_HTML" \
  && fail "review-board-html left a template placeholder unreplaced"
# Every number the page states about the board comes from the board, not from a second copy here.
assert contains "$board_html" '"min_anchored_runs": 3'
assert contains "$board_html" '"cost_scale": 1000'
assert contains "$board_html" '["T0", "up to 3 min"]'
grep -q 'меньше 3 якорных' "$BOARD_HTML" \
  && fail "review-board-html spelled a board threshold of its own"
# The page is a program, and its columns and its empty cells are decided at render time.
if command -v node >/dev/null 2>&1; then
  cat >"$WORK/board-html-render.js" <<'JS'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8").split("<script>")[1].split("</script>")[0];
const element = () => ({innerHTML: "", textContent: "", querySelectorAll: () => [],
  addEventListener: () => {}, appendChild: () => {}});
global.document = {getElementById: element, createElement: element, querySelectorAll: () => []};
const page = new Function(source + "\nreturn {cellRow, DATA, COLUMNS};")();
const cells = Object.fromEntries(page.DATA.cells.map(cell => [cell.cell, cell]));
const columns = name => page.cellRow(cells[name]).match(/<td[^>]*>[\s\S]*?<\/td>/g);
const fail = message => { console.error(message); process.exit(1); };
const dim = '<span class="dim">\u00b7</span>';
const rawOnly = columns("raw-only-cell");
if (rawOnly.length !== page.COLUMNS.length)
  fail(`${rawOnly.length} rendered columns against ${page.COLUMNS.length} headers`);
if (rawOnly[4] !== `<td>${dim}</td>`) fail(`catch of an unscored row: ${rawOnly[4]}`);
if (columns("opus-high")[2] !== "<td>0</td>")
  fail(`a measured zero raw+ rendered as ${columns("opus-high")[2]}`);
console.log("board-html-render-ok");
JS
  assert contains "$(node "$WORK/board-html-render.js" "$BOARD_HTML")" 'board-html-render-ok'
else
  printf 'SKIP: HTML board render checks (node is not installed)\n'
fi

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
# The verifier is the review product's, so the bench command parses the flag only to refuse it by
# name — and keeps taking the `--no-verify` an older reproduce line spells, now a no-op.
bench_verify="$(WORKER_STATS_DIR="$SD" "$SCRIPT" run 143fc2f --raters oc-kimik3 \
  --verify oc-dsv4flash 2>&1 || true)"
assert contains "$bench_verify" "--verify is a tier review's flag"
assert contains "$bench_verify" "review-bench review <target> --tier <tier>"
# A commit no repository holds, so the flag is accepted and the run dies at its target rather
# than launching a panel to prove the point.
bench_no_verify="$(WORKER_STATS_DIR="$SD" "$SCRIPT" run 0000000000000000000000000000000000000000 \
  --raters oc-kimik3 --no-verify 2>&1 || true)"
assert test "$(grep -c "tier review" <<<"$bench_no_verify")" -eq 0
assert test "$(grep -c 'unrecognized arguments' <<<"$bench_no_verify")" -eq 0
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
when: THE EDGE HUNT IS ASKED FOR
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
# Registration is where a lens that never says when to take it is refused: the listing would
# otherwise carry a line no reader can act on, and every run under it is a coin toss.
cat >"$LENS_CLI_DIR/when-less.md" <<EOF
---
name: when-less
---
Anything at all: a crash is P1, a wrong result P2, a rough edge P3.
EOF
lens_when_less="$(lens_cli check when-less)" && fail "lens check passed a lens with no when:"
assert contains "$lens_when_less" "FAILED: no \`when:\`"
rm -f "$LENS_CLI_DIR/when-less.md"
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
for tier_budget in "T0 (3 min)" "T1 (6 min)" "T2 (10 min)" "T3 (20 min)"; do
  assert contains "$tiers_table" "$tier_budget"
done
assert contains "$tiers_table" "eco (default):"
assert contains "$tiers_table" "max:"
for cell in "oc-kimik3 x2" "oc-kimik3 x3" "oc-grok45-low x2" "oc-grok45-low x3" \
  "oc-dsv4flash x2" "oc-dsv4flash x3" agy-pro-high-skill \
  "agy-flash35-medium-skill x2" "agy-flash35-high-skill x2" \
  "agy-flash36-medium-skill x2" "agy-flash36-high-skill x2" \
  agy-flash35-medium-skill agy-flash35-high-skill agy-flash36-medium-skill \
  agy-flash36-high-skill agy-flash37-medium-skill agy-flash37-high-skill \
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
assert contains "$owner_table" "gem-flash35-med, gem-flash35-high, gem-flash36-med, gem-flash36-high x2, gem-flash37-med, gem-pro"
assert contains "$owner_table" "gem-flash37-med, gem-pro"
assert contains "$owner_table" "sol-low, sol-low-bare"
assert contains "$owner_table" "opus-med"
assert contains "$owner_table" "cover"
assert contains "$owner_table" "agy-flash35-low-skill:"
# T0's --max buys three extra OpenCode passes over its eco, so the owner-facing table owes a
# row for it; a tier whose two compositions are identical still gets one row.
assert test "$(grep -c '^T0 max' <<<"$owner_table")" -eq 1
assert contains "$(WORKER_STATS_DIR="$SD" "$SCRIPT" oc-models 2>&1)" \
  "--raters 'oc-kimik3 x2,oc-grok45-low x2,oc-dsv4flash x2'"
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
if os.environ.get("GATE_REVIEWED"):
    meta["reviewed"] = {path: f"sha-{path}" for path in os.environ["GATE_REVIEWED"].split()}
if os.environ.get("GATE_MEMBERS"):
    meta["repos"] = json.loads(os.environ["GATE_MEMBERS"])
(run / "meta.json").write_text(json.dumps(meta) + "\n")
if findings:
    (run / "findings-oc-kimik3.jsonl").write_text("\n".join(
        json.dumps({"severity": "P2", "file": "a.py", "line": index + 1,
                    "summary": f"claim {index}"})
        for index in range(findings)
    ) + "\n")
GATEPY
}
# A fixes receipt is dated when it was written, and a fixture that backdates a run's clock has to
# backdate its receipt too: left at the real now, it reads as recorded after every backdated run.
fix_backdate() { # run-id hours-ago
  python3 - "$FIX_SD/benches/$1/fixes.json" "$2" <<'BACKPY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
record = json.loads(open(path).read())
record["recorded_at"] = (
    datetime.now(timezone.utc) - timedelta(hours=float(sys.argv[2]))
).isoformat()
open(path, "w").write(json.dumps(record, indent=2, sort_keys=True) + "\n")
BACKPY
}
# A panel seals its tree when it STARTS and answers hours later; the fixture spells one instant
# for both, so only this can ask which of the two a lineage receipt is measured against.
fix_stretch() { # run-id hours-before-finish
  python3 - "$FIX_SD/benches/$1/meta.json" "$2" <<'STRETCHPY'
import json
import sys
from datetime import datetime, timedelta

path = sys.argv[1]
meta = json.loads(open(path).read())
meta["started"] = (
    datetime.fromisoformat(meta["finished"]) - timedelta(hours=float(sys.argv[2]))
).isoformat()
open(path, "w").write(json.dumps(meta) + "\n")
STRETCHPY
}
# The seal instant the tool stamps for itself, which `started` is minutes later than: only a
# fixture spelling the two apart can ask which of them a lineage receipt is measured against.
fix_seal() { # run-id hours-before-finish
  python3 - "$FIX_SD/benches/$1/meta.json" "$2" <<'SEALPY'
import json
import sys
from datetime import datetime, timedelta

path = sys.argv[1]
meta = json.loads(open(path).read())
meta["sealed_at"] = (
    datetime.fromisoformat(meta["finished"]) - timedelta(hours=float(sys.argv[2]))
).isoformat()
open(path, "w").write(json.dumps(meta) + "\n")
SEALPY
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

# A triage a live worker is already doing is not one the chat owes: `worker-run` stamps the bench
# with its supervisor's pid, and the gate stays quiet for as long as that pid answers.
DELEG_SD="$WORK/gate-delegated"
DELEG_REPO="$WORK/gate-delegated-repo"
git init -q "$DELEG_REPO"
GATE_SD="$DELEG_SD" GATE_REPO="$DELEG_REPO" gate_run 20260731T080000Z-gatedelegated 0 1
deleg_before=$(WORKER_STATS_DIR="$DELEG_SD" "$SCRIPT" pending-report --repo "$DELEG_REPO") \
  || fail "pending-report missed the untriaged run before anybody took it"
assert contains "$deleg_before" "20260731T080000Z-gatedelegated 1"
DELEG_STAMP="$DELEG_SD/benches/20260731T080000Z-gatedelegated/delegated"
printf '%s\nsess-deleg\n' "$$" >"$DELEG_STAMP"
deleg_live=$(WORKER_STATS_DIR="$DELEG_SD" "$SCRIPT" pending-report --repo "$DELEG_REPO" --mark \
  || true)
assert test -z "$deleg_live"
# Quiet, and quiet for free: a silenced run must not spend the asks it will need if the worker dies.
assert test ! -e "$DELEG_SD/benches/20260731T080000Z-gatedelegated/report-nudged"
# A pid that is gone gives the run straight back — a worker that died mid-triage is exactly what
# the nag exists for, and a stamp that outlived it would bury the report instead.
deleg_dead_pid=$(bash -c 'echo $$')
printf '%s\n' "$deleg_dead_pid" >"$DELEG_STAMP"
deleg_dead=$(WORKER_STATS_DIR="$DELEG_SD" "$SCRIPT" pending-report --repo "$DELEG_REPO") \
  || fail "a dead worker's stamp silenced the run for good"
assert contains "$deleg_dead" "20260731T080000Z-gatedelegated 1"
# And a stamp naming no pid at all is no worker either.
printf 'not-a-pid\n' >"$DELEG_STAMP"
deleg_garbage=$(WORKER_STATS_DIR="$DELEG_SD" "$SCRIPT" pending-report --repo "$DELEG_REPO") \
  || fail "an unreadable stamp silenced the run"
assert contains "$deleg_garbage" "20260731T080000Z-gatedelegated 1"
# A LIVE pid stamped with a launch instant that pid never began at is a recycled number rather than
# the worker: pid reuse read on existence alone silences an untriaged run for as long as whatever
# inherited the number lives, which is the rule shared-invariants row ar binds every reader by.
deleg_pid_began() { # pid
  python3 - "$1" <<'DELEGPY'
import subprocess, sys, time
raw = subprocess.run(["ps", "-p", sys.argv[1], "-o", "etime="],
                     capture_output=True, text=True).stdout.strip()
fields = [int(part) for part in raw.replace("-", ":").split(":")]
elapsed = sum(value * scale for value, scale in zip(reversed(fields), (1, 60, 3600, 86400)))
print(int(time.time()) - elapsed)
DELEGPY
}
printf '%s 1000000000\nsess-deleg\n' "$$" >"$DELEG_STAMP"
deleg_recycled=$(WORKER_STATS_DIR="$DELEG_SD" "$SCRIPT" pending-report --repo "$DELEG_REPO") \
  || fail "a live pid stamped with somebody else's launch instant silenced the run"
assert contains "$deleg_recycled" "20260731T080000Z-gatedelegated 1"
printf '%s %s\nsess-deleg\n' "$$" "$(deleg_pid_began "$$")" >"$DELEG_STAMP"
deleg_matched=$(WORKER_STATS_DIR="$DELEG_SD" "$SCRIPT" pending-report --repo "$DELEG_REPO" || true)
assert test -z "$deleg_matched"
rm -f "$DELEG_STAMP"

# --- Fix status, the round budget and the delivery queue ----------------------
# A triaged round is not a finished one: the report says so in a line it always carries, and the
# frame word says it again louder, because a block shaped like every other one reads as finished.
FIX_SD="$WORK/fix-state"
FIX_REPO="$WORK/fix-repo"
FIX_QUIET_REPO="$WORK/fix-quiet-repo"
FIX_HOME="$WORK/fix-home"
git init -q "$FIX_REPO"
git init -q "$FIX_QUIET_REPO"
mkdir -p "$FIX_HOME/.claude/hooks"
# The fork's wording is the commit gate's alone (shared-invariants row af), so the round budget is
# measured against a stub of it: what the real gate says today is not this suite's to depend on.
cat >"$FIX_HOME/.claude/hooks/review-flow-gate.sh" <<'FLOWSTUB'
#!/bin/bash
[ "$1" = escalation-verdict ] || exit 1
[ "${3:-0}" -ge 1 ] || exit 1
printf 'stub fork. Pick one and carry it out:\n'
printf -- '- fix them and commit;\n'
printf -- '- re-review, over the FULL original scope plus the fixes.\n'
FLOWSTUB
chmod +x "$FIX_HOME/.claude/hooks/review-flow-gate.sh"
fix_blocked_header='============= review · NOT FINISHED =============='
for fix_frame in "$fix_blocked_header" "$report_frame_header"; do
  asserts=$((asserts + 1))
  test "$(python3 -c 'import sys; print(len(sys.argv[1]))' "$fix_frame")" = 50 ||
    fail "a frame this suite pins is not 50 chars wide: $fix_frame"
done
fix_row() { grep -E '^fixes: +' <<<"$1" | sed -E 's/^fixes: +//'; }
fix_bench() { HOME="$FIX_HOME" WORKER_STATS_DIR="$FIX_SD" "$SCRIPT" "$@"; }

GATE_SD="$FIX_SD" GATE_REPO="$FIX_REPO" GATE_SESSION=sess-fix \
  gate_run 20260801T000000Z-fixround1 0 2
printf '%s\n' '{"rater":"oc-kimik3","idx":0,"verdict":"confirmed"}' \
  '{"rater":"oc-kimik3","idx":1,"verdict":"false_positive"}' >"$WORK/fix-verdicts.jsonl"
fix_first=$(fix_bench record 20260801T000000Z-fixround1 --no-corpus \
  --verdicts "$WORK/fix-verdicts.jsonl") || fail "the first round refused its own triage"
# Nothing on record is pending, never applied: a report silent about the fixes reads as fixed.
# Framed in the PLAIN word: `record` seals the triage and the fixing pass starts right after it,
# so the loud word here is the one Egor read as "nothing was fixed" while the fixes were landing
# (2026-08-20). The row says the truth; the frame does not shout it.
assert test "$(fix_row "$fix_first")" = "NOT APPLIED — pending"
assert contains "$fix_first" "$report_frame_header"
assert test "$(grep -Fc -- "$fix_blocked_header" <<<"$fix_first")" -eq 0
# Nothing stopped, so there is no fork to take and no row claiming there is.
assert test "$(grep -Fc -- "stopped:" <<<"$fix_first")" -eq 0
# And what keeps that block out of Egor's chat is not its word, which it shares with a finished
# round, but that nothing ever queues it: the pass may still be running.
fix_first_delivery=$(fix_bench pending-delivery --session sess-fix) \
  || fail "pending-delivery refused a chat whose only round is mid-pass"
assert test "$(grep -Fc -- "20260801T000000Z-fixround1" <<<"$fix_first_delivery")" -eq 0
# Round one may still be offered the pass the gate priced.
assert contains "$fix_first" "re-review"

# The blocked form carries the reason into the block, so the chat reads why the work stopped
# rather than that it did.
fix_blocked=$(fix_bench fixes 20260801T000000Z-fixround1 --blocked 'P1 threshold, fork pending') \
  || fail "fixes --blocked refused a triaged run"
assert contains "$fix_blocked" "NOT APPLIED — P1 threshold, fork pending"
fix_blocked_report=$(fix_bench report 20260801T000000Z-fixround1) \
  || fail "the blocked round has no report"
assert test "$(fix_row "$fix_blocked_report")" = "NOT APPLIED — P1 threshold, fork pending"
# NOT FINISHED belongs to the blocked state alone, and the frame has to make the situation
# unmistakable: the reason on the row, and beneath it what stopped the round and whose the fork is.
assert contains "$fix_blocked_report" "$fix_blocked_header"
# And under no other word, at any age: the loud one is read off the RECEIPT, never off the clock.
# A blocked round re-framed by a rule of its own is what delivered a second copy of a report Egor
# had already read, saying a thing its receipt never said (2026-08-20).
assert test "$(grep -Fc -- "$report_frame_header" <<<"$fix_blocked_report")" -eq 0
assert contains "$fix_blocked_report" "stopped:"
assert contains "$fix_blocked_report" "the fixing pass stopped over the findings above, for the reason"
assert contains "$fix_blocked_report" "fixing them as they stand, reworking the code they cluster in,"
assert contains "$fix_blocked_report" "is Egor's decision and not the fixer's"
# `--blocked` takes whichever reason the pass actually had, and the fork under the loud word
# asserts none of its own: a round stopped by a walled worker read "stopped at the P1 threshold
# and fixed nothing" over a receipt that said neither.
fix_bench fixes 20260801T000000Z-fixround1 --blocked 'the worker was walled mid-pass' >/dev/null \
  || fail "fixes --blocked refused a reason that is not the threshold"
fix_walled_report=$(fix_bench report 20260801T000000Z-fixround1) \
  || fail "the walled round has no report"
assert test "$(fix_row "$fix_walled_report")" = "NOT APPLIED — the worker was walled mid-pass"
assert contains "$fix_walled_report" "$fix_blocked_header"
assert contains "$fix_walled_report" "the fixing pass stopped over the findings above, for the reason"
assert test "$(grep -Fc -- "stopped at the P1 threshold" <<<"$fix_walled_report")" -eq 0
# A blocked receipt answers for the triage it stopped over, exactly as a done one answers for the
# triage it fixed: re-adjudicated to different findings, the round owes an answer again rather than
# offering Egor a fork over a P1 list nobody stopped over.
printf '%s\n' '{"rater":"oc-kimik3","idx":0,"verdict":"false_positive"}' \
  '{"rater":"oc-kimik3","idx":1,"verdict":"confirmed"}' >"$WORK/fix-verdicts-blockswap.jsonl"
fix_blockswap=$(fix_bench record 20260801T000000Z-fixround1 --no-corpus \
  --verdicts "$WORK/fix-verdicts-blockswap.jsonl") || fail "re-adjudication of a blocked round refused"
assert test "$(fix_row "$fix_blockswap")" \
  = "NOT APPLIED — recorded against a different triage of the same 1 confirmed"
assert contains "$fix_blockswap" "$report_frame_header"
assert test "$(grep -Fc -- "stopped:" <<<"$fix_blockswap")" -eq 0
# And it is named by no delivery line while it owes that answer, whatever state its receipt holds.
fix_blockswap_delivery=$(fix_bench pending-delivery --session sess-fix) \
  || fail "pending-delivery refused a chat whose blocked round was re-adjudicated"
assert test "$(grep -Fc -- "20260801T000000Z-fixround1" <<<"$fix_blockswap_delivery")" -eq 0
# Back to the triage the stop was recorded against, and the fork stands again.
fix_bench record 20260801T000000Z-fixround1 --no-corpus \
  --verdicts "$WORK/fix-verdicts.jsonl" >/dev/null || fail "re-adjudication back refused"
fix_blocked_report=$(fix_bench report 20260801T000000Z-fixround1) \
  || fail "the restored blocked round has no report"
assert contains "$fix_blocked_report" "$fix_blocked_header"
fix_bench fixes 20260801T000000Z-fixround1 --blocked 'P1 threshold, fork pending' >/dev/null \
  || fail "fixes --blocked refused the restored round"
# The blocked round is delivered, and the pending one before it was not: the state the report is
# framed in and the state it is delivered under are one answer.
fix_blocked_delivery=$(fix_bench pending-delivery --session sess-fix) \
  || fail "pending-delivery refused the blocked round"
assert test "$(grep -c '^20260801T000000Z-fixround1 blocked$' <<<"$fix_blocked_delivery")" = 1

# And the done form retires the loud frame: the round the report is read with is over.
fix_done=$(fix_bench fixes 20260801T000000Z-fixround1 --done --fixed 1 --fp 1) \
  || fail "fixes --done refused a triaged run"
assert contains "$fix_done" "done — 1 fixed, 1 false positives"
fix_done_report=$(fix_bench report 20260801T000000Z-fixround1) \
  || fail "the fixed round has no report"
assert test "$(fix_row "$fix_done_report")" = "done — 1 fixed, 1 false positives"
assert contains "$fix_done_report" "$report_frame_header"
assert test "$(grep -Fc -- "$fix_blocked_header" <<<"$fix_done_report")" -eq 0
assert test "$(grep -Fc -- "stopped:" <<<"$fix_done_report")" -eq 0
assert test -e "$FIX_SD/benches/20260801T000000Z-fixround1/fixes.json"
assert test "$(jq -r .state "$FIX_SD/benches/20260801T000000Z-fixround1/fixes.json")" = done

# The two counts are the whole point of the done form, and a run nobody reviewed has no fixes.
fix_countless=$(fix_bench fixes 20260801T000000Z-fixround1 --done 2>&1 || true)
assert contains "$fix_countless" "--done needs --fixed N and --fp M"
fix_unknown=$(fix_bench fixes 20260801T999999Z-nosuchrun --blocked why 2>&1 || true)
assert contains "$fix_unknown" "unknown run id"

# Nothing confirmed is neither pending nor done: there is no work, and a report demanding fixes
# for it would send a worker looking for something to patch.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_QUIET_REPO" GATE_SESSION=sess-fix \
  gate_run 20260801T010000Z-fixquiet 0 0
fix_quiet=$(fix_bench record 20260801T010000Z-fixquiet --no-corpus) \
  || fail "the clean round refused its own triage"
assert test "$(fix_row "$fix_quiet")" = "nothing to fix"
assert contains "$fix_quiet" "$report_frame_header"
assert test "$(grep -Fc -- "$fix_blocked_header" <<<"$fix_quiet")" -eq 0

# Two rounds over one scope and no third. Derived from the runs on disk — an earlier run of the
# same scope with fix status recorded — so it holds for a caller who never heard of the budget.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_REPO" GATE_SESSION=sess-fix \
  gate_run 20260801T020000Z-fixround2 0 1
printf '%s\n' '{"rater":"oc-kimik3","idx":0,"verdict":"confirmed"}' >"$WORK/fix-verdicts2.jsonl"
fix_second=$(fix_bench record 20260801T020000Z-fixround2 --no-corpus \
  --verdicts "$WORK/fix-verdicts2.jsonl") || fail "the second round refused its own triage"
assert test "$(grep -Fc -- "re-review" <<<"$fix_second")" -eq 0
assert contains "$fix_second" "the budget of two is spent"
assert contains "$fix_second" "false-positive doctrine"
# A round of another scope is still its own first: the budget is per scope, not per repository
# the state directory happens to hold.
fix_other=$(fix_bench report 20260801T010000Z-fixquiet) || fail "the clean round lost its report"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_other")" -eq 0
# And a scope whose own findings earned the fork keeps it: the round on record belongs to another
# tree, so what spends the budget is the scope matching, never a fix receipt merely existing
# somewhere in a state directory every repository shares.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_QUIET_REPO" GATE_SESSION=sess-fix \
  gate_run 20260801T040000Z-fixotherfirst 0 1
printf '%s\n' '{"rater":"oc-kimik3","idx":0,"verdict":"confirmed"}' >"$WORK/fix-verdicts3.jsonl"
fix_other_first=$(fix_bench record 20260801T040000Z-fixotherfirst --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the other scope's round refused its own triage"
assert contains "$fix_other_first" "re-review"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_other_first")" -eq 0

# A receipt answers for confirmed findings, so a run nobody judged has none to answer for. Taken
# here it would spend the scope's budget over a pass that never happened.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_REPO" GATE_SESSION=sess-fix \
  gate_run 20260801T050000Z-fixuntriaged 0 1
fix_untriaged=$(fix_bench fixes 20260801T050000Z-fixuntriaged --done --fixed 1 --fp 0 2>&1 || true)
assert contains "$fix_untriaged" "has no triage on record"
assert test ! -e "$FIX_SD/benches/20260801T050000Z-fixuntriaged/fixes.json"

# The budget is spent by a round that was FIXED, never by one that stopped: the fork a blocked
# round stopped for is what the next round is, and pricing it as the second leaves that fork with
# nowhere to go.
FIX_BLOCKED_REPO="$WORK/fix-blocked-repo"
git init -q "$FIX_BLOCKED_REPO"
GATE_SD="$FIX_SD" GATE_REPO="$FIX_BLOCKED_REPO" GATE_SESSION=sess-fix \
  gate_run 20260801T060000Z-fixstopped 0 1
fix_bench record 20260801T060000Z-fixstopped --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the stopped round refused its triage"
fix_bench fixes 20260801T060000Z-fixstopped --blocked 'P1 threshold' >/dev/null \
  || fail "fixes --blocked refused a triaged run"
GATE_SD="$FIX_SD" GATE_REPO="$FIX_BLOCKED_REPO" GATE_SESSION=sess-fix \
  gate_run 20260801T070000Z-fixafterstop 0 1
fix_after_stop=$(fix_bench record 20260801T070000Z-fixafterstop --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the round after a stop refused its triage"
assert contains "$fix_after_stop" "re-review"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_after_stop")" -eq 0

# And the scope is a piece of work, not a checkout: an unrelated later review of the same
# repository must keep its own first round, or one fixed round costs that repository the
# escalation fork for good. The second round is the run that reads everything the first one read —
# the coverage that discharges the first round's lock.
FIX_LINEAGE_REPO="$WORK/fix-lineage-repo"
git init -q "$FIX_LINEAGE_REPO"
GATE_SD="$FIX_SD" GATE_REPO="$FIX_LINEAGE_REPO" GATE_SESSION=sess-fix GATE_REVIEWED="a.py b.py" \
  gate_run 20260801T080000Z-fixlineage1 0 2
fix_bench record 20260801T080000Z-fixlineage1 --no-corpus \
  --verdicts "$WORK/fix-verdicts.jsonl" >/dev/null || fail "the lineage round refused its triage"
fix_bench fixes 20260801T080000Z-fixlineage1 --done --fixed 1 --fp 1 >/dev/null \
  || fail "fixes --done refused the lineage round"
GATE_SD="$FIX_SD" GATE_REPO="$FIX_LINEAGE_REPO" GATE_SESSION=sess-fix GATE_REVIEWED="c.py" \
  gate_run 20260801T090000Z-fixelsewhere 0 1
fix_elsewhere=$(fix_bench record 20260801T090000Z-fixelsewhere --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the unrelated round refused its triage"
assert contains "$fix_elsewhere" "re-review"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_elsewhere")" -eq 0
GATE_SD="$FIX_SD" GATE_REPO="$FIX_LINEAGE_REPO" GATE_SESSION=sess-fix \
  GATE_REVIEWED="a.py b.py c.py" gate_run 20260801T100000Z-fixlineage2 0 1
fix_lineage2=$(fix_bench record 20260801T100000Z-fixlineage2 --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the second lineage round refused its triage"
assert contains "$fix_lineage2" "the budget of two is spent"
# And the earlier round's receipt is read exactly as its own REPORT reads it: a re-adjudication
# leaves the receipt standing over a triage it no longer answers, and taken at its raw word the
# round the report itself calls pending goes on spending the scope's budget of two.
printf '%s\n' '{"rater":"oc-kimik3","idx":0,"verdict":"confirmed"}' \
  '{"rater":"oc-kimik3","idx":1,"verdict":"confirmed"}' >"$WORK/fix-lineage-restale.jsonl"
fix_bench record 20260801T080000Z-fixlineage1 --no-corpus \
  --verdicts "$WORK/fix-lineage-restale.jsonl" >/dev/null || fail "re-adjudication refused"
fix_stale_lineage=$(fix_bench record 20260801T100000Z-fixlineage2 --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the second lineage round refused its triage"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_stale_lineage")" -eq 0
assert contains "$fix_stale_lineage" "re-review"
fix_bench record 20260801T080000Z-fixlineage1 --no-corpus \
  --verdicts "$WORK/fix-verdicts.jsonl" >/dev/null || fail "re-adjudication back refused"

# A merged panel's own repo is the workspace built for that one run, and the fixes give the next
# round a workspace of its own: keyed on it, the budget would never bind for a merged review at
# all. Its members are the scope.
FIX_MERGED_A="$WORK/fix-merged-a"
FIX_MERGED_B="$WORK/fix-merged-b"
git init -q "$FIX_MERGED_A"
git init -q "$FIX_MERGED_B"
fix_members="[{\"label\":\"a\",\"repo\":\"$FIX_MERGED_A\",\"scope\":[]},{\"label\":\"b\",\"repo\":\"$FIX_MERGED_B\",\"scope\":[]}]"
GATE_SD="$FIX_SD" GATE_REPO="$WORK/fix-merged-workspace-1" GATE_SESSION=sess-fix \
  GATE_MEMBERS="$fix_members" gate_run 20260801T110000Z-fixmerged1 0 1
fix_bench record 20260801T110000Z-fixmerged1 --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the merged round refused its triage"
fix_bench fixes 20260801T110000Z-fixmerged1 --done --fixed 1 --fp 0 >/dev/null \
  || fail "fixes --done refused the merged round"
GATE_SD="$FIX_SD" GATE_REPO="$WORK/fix-merged-workspace-2" GATE_SESSION=sess-fix \
  GATE_MEMBERS="$fix_members" gate_run 20260801T120000Z-fixmerged2 0 1
fix_merged2=$(fix_bench record 20260801T120000Z-fixmerged2 --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the second merged round refused its triage"
assert contains "$fix_merged2" "the budget of two is spent"

# And what a merged panel READ is its members' maps as much as the workspace's own: only the
# members' hold a debt review's zero-diff survivors, since the workspace map is that snapshot's
# diff and a path standing exactly where the locked round recorded it shows nothing in one. Read
# off the workspace alone every merged panel offers the empty set, and one fixed round answers for
# every later review of those repositories.
FIX_MEMBERS_A="$WORK/fix-members-a"
FIX_MEMBERS_B="$WORK/fix-members-b"
git init -q "$FIX_MEMBERS_A"
git init -q "$FIX_MEMBERS_B"
fix_members_read="[{\"label\":\"a\",\"repo\":\"$FIX_MEMBERS_A\",\"scope\":[],\"reviewed\":{\"a.py\":\"sha-a\"}},{\"label\":\"b\",\"repo\":\"$FIX_MEMBERS_B\",\"scope\":[],\"reviewed\":{\"b.py\":\"sha-b\"}}]"
fix_members_elsewhere="[{\"label\":\"a\",\"repo\":\"$FIX_MEMBERS_A\",\"scope\":[],\"reviewed\":{\"z.py\":\"sha-z\"}},{\"label\":\"b\",\"repo\":\"$FIX_MEMBERS_B\",\"scope\":[],\"reviewed\":{\"y.py\":\"sha-y\"}}]"
GATE_SD="$FIX_SD" GATE_REPO="$WORK/fix-members-workspace-1" GATE_SESSION=sess-fix \
  GATE_MEMBERS="$fix_members_read" gate_run 20260801T130000Z-fixmembers1 0 1
fix_bench record 20260801T130000Z-fixmembers1 --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the member-read round refused its triage"
fix_bench fixes 20260801T130000Z-fixmembers1 --done --fixed 1 --fp 0 >/dev/null \
  || fail "fixes --done refused the member-read round"
GATE_SD="$FIX_SD" GATE_REPO="$WORK/fix-members-workspace-2" GATE_SESSION=sess-fix \
  GATE_MEMBERS="$fix_members_elsewhere" gate_run 20260801T140000Z-fixmemberselse 0 1
fix_members_else=$(fix_bench record 20260801T140000Z-fixmemberselse --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the unrelated merged round refused its triage"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_members_else")" -eq 0
assert contains "$fix_members_else" "re-review"
GATE_SD="$FIX_SD" GATE_REPO="$WORK/fix-members-workspace-3" GATE_SESSION=sess-fix \
  GATE_MEMBERS="$fix_members_read" gate_run 20260801T150000Z-fixmembers2 0 1
fix_members2=$(fix_bench record 20260801T150000Z-fixmembers2 --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the answering merged round refused its triage"
assert contains "$fix_members2" "the budget of two is spent"

# A receipt answers for the triage it was written against. Re-adjudicating replaces the verdicts
# and leaves the receipt where it is, so a round that came back with more confirmed findings than
# anybody fixed would read as finished on the strength of the older pass.
printf '%s\n' '{"rater":"oc-kimik3","idx":0,"verdict":"confirmed"}' \
  '{"rater":"oc-kimik3","idx":1,"verdict":"confirmed"}' >"$WORK/fix-verdicts4.jsonl"
fix_restale=$(fix_bench record 20260801T000000Z-fixround1 --no-corpus \
  --verdicts "$WORK/fix-verdicts4.jsonl") || fail "re-adjudication refused"
assert contains "$fix_restale" "recorded against a triage of 1 confirmed, and this one has 2"
# A receipt that no longer answers the triage is a pass that has not answered: the plain word,
# since the fixer may be working through the new findings right now.
assert contains "$fix_restale" "$report_frame_header"
assert test "$(grep -Fc -- "$fix_blocked_header" <<<"$fix_restale")" -eq 0
fix_bench fixes 20260801T000000Z-fixround1 --done --fixed 2 --fp 0 >/dev/null \
  || fail "fixes --done refused the re-adjudicated round"
fix_resettled=$(fix_bench report 20260801T000000Z-fixround1) || fail "the round lost its report"
assert test "$(fix_row "$fix_resettled")" = "done — 2 fixed, 0 false positives"

# The delivery queue: a run this chat launched whose round has a state to deliver, which no command
# in this chat ever printed, because a headless worker recorded it in a process of its own. The
# STATE stands beside the id: the gate keys its ledger on it, so a round delivers one report per
# state it reaches rather than one per run.
fix_delivery=$(fix_bench pending-delivery --session sess-fix) \
  || fail "pending-delivery refused a recorded run"
assert test "$(grep -c '^20260801T000000Z-fixround1 done$' <<<"$fix_delivery")" = 1
# A round whose fixing pass stopped is delivered in the state it stopped in — that report is the
# fork Egor answers, and the finished one comes after he has.
assert test "$(grep -c '^20260801T060000Z-fixstopped blocked$' <<<"$fix_delivery")" = 1
# A round with nothing confirmed has no fixing pass to wait for: it is done at its triage, and a
# report held for a receipt nobody will ever write would never be delivered at all.
assert test "$(grep -c '^20260801T010000Z-fixquiet done$' <<<"$fix_delivery")" = 1
# One still mid-pass is not delivered at all: its report is about to change, and the copy sent now
# is the extra one this queue exists to stop printing.
assert test "$(grep -Fc -- "20260801T020000Z-fixround2" <<<"$fix_delivery")" -eq 0
# Another chat's runs are that chat's to be shown, and asking here would put its review in the
# wrong window.
fix_foreign=$(fix_bench pending-delivery --session sess-elsewhere) \
  || fail "pending-delivery failed for a chat with no runs"
assert test -z "$fix_foreign"
# An untriaged run has no report to deliver at all — that is the triage gate's question, not
# this one's.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_REPO" GATE_SESSION=sess-fix \
  gate_run 20260801T030000Z-fixraw 0 1
fix_raw=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260801T030000Z-fixraw" <<<"$fix_raw")" -eq 0
# And an old one reviewed a diff that has since moved, the same window `pending-report` closes.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_REPO" GATE_SESSION=sess-fix \
  gate_run 20260730T000000Z-fixstale 48 0
fix_bench record 20260730T000000Z-fixstale --no-corpus >/dev/null \
  || fail "the stale run refused its own triage"
fix_stale=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260730T000000Z-fixstale" <<<"$fix_stale")" -eq 0
# A round whose fixing pass never answered is named at NO age — not past the window, not just
# inside it, never. It has no delivery state, so nothing keys a ledger on it and nothing hands it
# to a Stop gate; the only way to read it is to ask for it. Promoting such a round past some age
# is what rendered 39 pre-receipt-mechanism rounds into a single message, live (2026-08-20).
GATE_SD="$FIX_SD" GATE_REPO="$FIX_QUIET_REPO" GATE_SESSION=sess-fix \
  gate_run 20260730T010000Z-fixabandoned 10 1
fix_bench record 20260730T010000Z-fixabandoned --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the abandoned round refused its triage"
fix_abandoned=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260730T010000Z-fixabandoned" <<<"$fix_abandoned")" -eq 0
fix_abandoned_report=$(fix_bench report 20260730T010000Z-fixabandoned) \
  || fail "the unanswered round has no report"
# And it wears the plain word while it waits: the report the model reads is the truthful one, and
# the `fixes:` row is what says the pass still owes an answer.
assert contains "$fix_abandoned_report" "$report_frame_header"
assert test "$(grep -Fc -- "$fix_blocked_header" <<<"$fix_abandoned_report")" -eq 0
assert test "$(fix_row "$fix_abandoned_report")" = "NOT APPLIED — pending"
# Fresh, the very same round says nothing either: the age was never the question.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_QUIET_REPO" GATE_SESSION=sess-fix \
  gate_run 20260802T010000Z-fixmidpass 0 1
fix_bench record 20260802T010000Z-fixmidpass --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the mid-pass round refused its triage"
fix_midpass=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260802T010000Z-fixmidpass" <<<"$fix_midpass")" -eq 0
# And the block it renders is the aged one's, word for word: one state, one frame, one rule.
fix_midpass_report=$(fix_bench report 20260802T010000Z-fixmidpass) \
  || fail "the mid-pass round has no report"
assert contains "$fix_midpass_report" "$report_frame_header"
assert test "$(grep -Fc -- "$fix_blocked_header" <<<"$fix_midpass_report")" -eq 0
# An ancient one is no different, and that is the point: no age promotes an unanswered round.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_QUIET_REPO" GATE_SESSION=sess-fix \
  gate_run 20260729T000000Z-fixancient 48 1
fix_bench record 20260729T000000Z-fixancient --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the ancient round refused its triage"
fix_ancient=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260729T000000Z-fixancient" <<<"$fix_ancient")" -eq 0
# Age never re-words a frame: a blocked round two days old is still NOT FINISHED and still says
# so on its own receipt's terms, even though the window has closed over its delivery. A rule that
# re-framed an old round by the clock delivered a second copy of a report Egor had already read,
# under a word its receipt never said (2026-08-20).
FIX_AGED_REPO="$WORK/fix-agedblocked-repo"
git init -q "$FIX_AGED_REPO"
GATE_SD="$FIX_SD" GATE_REPO="$FIX_AGED_REPO" GATE_SESSION=sess-fix \
  gate_run 20260729T020000Z-fixagedblocked 48 1
fix_bench record 20260729T020000Z-fixagedblocked --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the aged round refused its triage"
fix_bench fixes 20260729T020000Z-fixagedblocked --blocked 'P1 threshold, fork pending' >/dev/null \
  || fail "fixes --blocked refused the aged round"
fix_aged_report=$(fix_bench report 20260729T020000Z-fixagedblocked) \
  || fail "the aged blocked round has no report"
assert contains "$fix_aged_report" "$fix_blocked_header"
assert test "$(grep -Fc -- "$report_frame_header" <<<"$fix_aged_report")" -eq 0
assert contains "$fix_aged_report" "stopped:"
fix_aged_delivery=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260729T020000Z-fixagedblocked" <<<"$fix_aged_delivery")" -eq 0

# Including the hour that used to be the far end of a second window: there is no second window.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_QUIET_REPO" GATE_SESSION=sess-fix \
  gate_run 20260729T010000Z-fixlastcall 23 1
fix_bench record 20260729T010000Z-fixlastcall --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the last-call round refused its triage"
fix_lastcall=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260729T010000Z-fixlastcall" <<<"$fix_lastcall")" -eq 0

# Read-only: nothing about being listed may spend a run's asks or change what it owes.
assert test ! -e "$FIX_SD/benches/20260801T000000Z-fixround1/report-nudged"

# A pass DELEGATED to a worker that has since died is still nobody's to deliver: whoever owns the
# round decides what happens to it, and a queue that spoke for the dead worker was a second
# delivery path with a vocabulary of its own.
FIX_DEAD_REPO="$WORK/fix-dead-repo"
git init -q "$FIX_DEAD_REPO"
GATE_SD="$FIX_SD" GATE_REPO="$FIX_DEAD_REPO" GATE_SESSION=sess-fix \
  gate_run 20260802T020000Z-fixdeadworker 0 1
fix_bench record 20260802T020000Z-fixdeadworker --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the delegated round refused its triage"
fix_dead_stamp="$FIX_SD/benches/20260802T020000Z-fixdeadworker/delegated"
printf '%s\nsess-fix\n' "$(bash -c 'echo $$')" >"$fix_dead_stamp"
fix_dead=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260802T020000Z-fixdeadworker" <<<"$fix_dead")" -eq 0
fix_dead_report=$(fix_bench report 20260802T020000Z-fixdeadworker) \
  || fail "the abandoned round has no report"
assert contains "$fix_dead_report" "$report_frame_header"
# And the same round while that worker lives reads identically: nothing about the frame or the
# queue turns on a pid, so a stamp going stale can never change what Egor is handed.
printf '%s %s\nsess-fix\n' "$$" "$(deleg_pid_began "$$")" >"$fix_dead_stamp"
fix_live=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260802T020000Z-fixdeadworker" <<<"$fix_live")" -eq 0
fix_live_report=$(fix_bench report 20260802T020000Z-fixdeadworker) \
  || fail "the delegated round has no report"
assert test "$fix_live_report" = "$fix_dead_report"
rm -f "$fix_dead_stamp"

# A done receipt the report has already rejected is not a state to deliver: queued as `done` it
# spends the one ledger key the finished report is ever delivered under, and the round Egor is
# waiting on reaches him in neither state.
FIX_STALE_REPO="$WORK/fix-stalereceipt-repo"
git init -q "$FIX_STALE_REPO"
GATE_SD="$FIX_SD" GATE_REPO="$FIX_STALE_REPO" GATE_SESSION=sess-fix \
  gate_run 20260802T030000Z-fixstaledone 0 2
fix_bench record 20260802T030000Z-fixstaledone --no-corpus \
  --verdicts "$WORK/fix-verdicts.jsonl" >/dev/null || fail "the round refused its triage"
fix_bench fixes 20260802T030000Z-fixstaledone --done --fixed 1 --fp 1 >/dev/null \
  || fail "fixes --done refused the round"
fix_bench record 20260802T030000Z-fixstaledone --no-corpus \
  --verdicts "$WORK/fix-verdicts4.jsonl" >/dev/null || fail "re-adjudication refused"
fix_stale_state=$(fix_bench pending-delivery --session sess-fix) || fail "pending-delivery failed"
assert test "$(grep -Fc -- "20260802T030000Z-fixstaledone done" <<<"$fix_stale_state")" -eq 0

# A receipt answers for the findings it was written against and not merely for how many there were:
# a re-adjudication that confirms a different finding in place of the old one leaves the count alone.
FIX_SWAP_REPO="$WORK/fix-swap-repo"
git init -q "$FIX_SWAP_REPO"
GATE_SD="$FIX_SD" GATE_REPO="$FIX_SWAP_REPO" GATE_SESSION=sess-fix \
  gate_run 20260802T040000Z-fixswap 0 3
printf '%s\n' '{"rater":"oc-kimik3","idx":0,"verdict":"confirmed"}' \
  '{"rater":"oc-kimik3","idx":1,"verdict":"confirmed"}' \
  '{"rater":"oc-kimik3","idx":2,"verdict":"false_positive"}' >"$WORK/fix-swap-a.jsonl"
printf '%s\n' '{"rater":"oc-kimik3","idx":0,"verdict":"confirmed"}' \
  '{"rater":"oc-kimik3","idx":1,"verdict":"false_positive"}' \
  '{"rater":"oc-kimik3","idx":2,"verdict":"confirmed"}' >"$WORK/fix-swap-b.jsonl"
fix_bench record 20260802T040000Z-fixswap --no-corpus \
  --verdicts "$WORK/fix-swap-a.jsonl" >/dev/null || fail "the swap round refused its triage"
fix_bench fixes 20260802T040000Z-fixswap --done --fixed 2 --fp 1 >/dev/null \
  || fail "fixes --done refused the swap round"
fix_swap_same=$(fix_bench record 20260802T040000Z-fixswap --no-corpus \
  --verdicts "$WORK/fix-swap-a.jsonl") || fail "re-adjudication to the same triage refused"
assert test "$(fix_row "$fix_swap_same")" = "done — 2 fixed, 1 false positives"
fix_swapped=$(fix_bench record 20260802T040000Z-fixswap --no-corpus \
  --verdicts "$WORK/fix-swap-b.jsonl") || fail "re-adjudication to a swapped triage refused"
assert test "$(fix_row "$fix_swapped")" \
  = "NOT APPLIED — recorded against a different triage of the same 2 confirmed"
assert contains "$fix_swapped" "$report_frame_header"

# The two counts of a done receipt ARE the answer to the confirmed findings, so fewer between them
# than the triage confirmed is a pass that stopped — which has its own form. Unchecked, `--fixed 0
# --fp 0` retired the loud frame and spent the scope's round budget over work nobody did.
fix_shortfall=$(fix_bench fixes 20260802T040000Z-fixswap --done --fixed 0 --fp 0 2>&1 || true)
assert contains "$fix_shortfall" "answer for fewer findings than the 2 this triage confirmed"
assert test "$(jq -r .fixed "$FIX_SD/benches/20260802T040000Z-fixswap/fixes.json")" = 2
# And bounded from above by that same triage, or the shortfall check is the only thing between a
# typo and a round retired for good on a tally its own verdicts cannot account for: nothing is
# fixed that nobody confirmed, and no receipt answers for findings the panel never produced.
fix_overfixed=$(fix_bench fixes 20260802T040000Z-fixswap --done --fixed 9 --fp 0 2>&1 || true)
assert contains "$fix_overfixed" "names more findings than the 2 this triage confirmed"
fix_overtotal=$(fix_bench fixes 20260802T040000Z-fixswap --done --fixed 2 --fp 9 2>&1 || true)
assert contains "$fix_overtotal" "answer for more findings than the 3 this run has"
assert test "$(jq -r .fixed "$FIX_SD/benches/20260802T040000Z-fixswap/fixes.json")" = 2

# And the second round of a scope is a round of the same PIECE OF WORK. Held to the paths alone
# this was unbounded in time: a full-repository scope reads a superset of every earlier round of
# the same checkout, and a run carrying no `reviewed` map at all offers the empty set, so one fixed
# round priced every later review of that repository as its second — forever, escalation fork and
# waiver lock included.
FIX_AGED_REPO="$WORK/fix-aged-repo"
git init -q "$FIX_AGED_REPO"
GATE_SD="$FIX_SD" GATE_REPO="$FIX_AGED_REPO" GATE_SESSION=sess-fix \
  gate_run 20260701T000000Z-fixlongago 400 1
fix_bench record 20260701T000000Z-fixlongago --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl" >/dev/null || fail "the old round refused its triage"
fix_bench fixes 20260701T000000Z-fixlongago --done --fixed 1 --fp 0 >/dev/null \
  || fail "fixes --done refused the old round"
fix_backdate 20260701T000000Z-fixlongago 398
GATE_SD="$FIX_SD" GATE_REPO="$FIX_AGED_REPO" GATE_SESSION=sess-fix \
  gate_run 20260802T050000Z-fixmuchlater 0 1
fix_much_later=$(fix_bench record 20260802T050000Z-fixmuchlater --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the later round refused its triage"
assert contains "$fix_much_later" "re-review"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_much_later")" -eq 0
# Inside the lineage window the very same shape IS the second round: what the bound refuses is a
# stranger, not the pass that answers a fixed round.
GATE_SD="$FIX_SD" GATE_REPO="$FIX_AGED_REPO" GATE_SESSION=sess-fix \
  gate_run 20260802T060000Z-fixjustafter 396 1
fix_just_after=$(fix_bench record 20260802T060000Z-fixjustafter --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the answering round refused its triage"
assert contains "$fix_just_after" "the budget of two is spent"
# And a round is the second one over fixes it could actually READ: a receipt recorded after this
# run sealed its tree answers for work that landed later, and counted as lineage it spends the
# budget and releases the lock over a pass that saw none of it.
fix_backdate 20260701T000000Z-fixlongago 0
fix_late_receipt=$(fix_bench record 20260802T060000Z-fixjustafter --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the answering round refused its triage"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_late_receipt")" -eq 0
assert contains "$fix_late_receipt" "re-review"
fix_backdate 20260701T000000Z-fixlongago 398
# And "could read" is the tree it SEALED and never the hour it answered: a T2 panel runs for hours,
# and a receipt written while it ran names fixes its snapshot never held. Measured against the
# finish that receipt counted as lineage and released the lock over a pass that saw none of them.
fix_stretch 20260802T060000Z-fixjustafter 2
fix_backdate 20260701T000000Z-fixlongago 397
fix_mid_run_receipt=$(fix_bench record 20260802T060000Z-fixjustafter --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the answering round refused its triage"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_mid_run_receipt")" -eq 0
assert contains "$fix_mid_run_receipt" "re-review"
# The same receipt one hour the other side of the seal is the lineage it was always meant to be.
fix_backdate 20260701T000000Z-fixlongago 399
fix_sealed_after=$(fix_bench record 20260802T060000Z-fixjustafter --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the answering round refused its triage"
assert contains "$fix_sealed_after" "the budget of two is spent"
fix_backdate 20260701T000000Z-fixlongago 398
# And the run's own seal stamp outranks its launch stamp wherever it carries one: the tool seals
# the tree, then sweeps availability and may refresh limits before it writes `started`, so a
# receipt landing in that gap answers for work no cell of this panel could read.
fix_seal 20260802T060000Z-fixjustafter 3
fix_backdate 20260701T000000Z-fixlongago 398.5
fix_pre_seal=$(fix_bench record 20260802T060000Z-fixjustafter --no-corpus \
  --verdicts "$WORK/fix-verdicts3.jsonl") || fail "the answering round refused its triage"
assert test "$(grep -Fc -- "the budget of two is spent" <<<"$fix_pre_seal")" -eq 0
assert contains "$fix_pre_seal" "re-review"

# A review of part of the tree never answers for the repository: `receipt` with no selector finds
# nothing, and the scope's own receipt is readable only when asked for by name.
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
scope_receipt_files=$(ls "$SCOPE_SD/receipts")
assert test "$(wc -l <<<"$scope_receipt_files" | tr -d ' ')" -eq 1
assert contains "$scope_receipt_files" '__scope-'

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
  # The report is delivered BY the hook, so the block leaves as a systemMessage and the model is
  # told to add judgment instead of retyping it — a retyped block can be mistyped, and a gate
  # comparing the retyping against the reference then bought a second identical block.
  report_capture=$'before\n'"$report_frame_header"$'\nT1 report\n'"$report_frame_footer"$'\nafter'
  hook_output="$(jq -nc --arg output "$report_capture" \
    '{tool_name:"Bash",tool_input:{command:"review-bench record run --no-corpus"},
      tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
  assert contains "$(jq -r '.systemMessage' <<<"$hook_output")" "$report_frame_header"
  assert contains "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$hook_output")" \
    "Do NOT paste"
  # Only review-bench's own output is a report. Keying on the frame alone fired on any `====`
  # divider the model read, and a hook that PRINTS to Egor would push that at him as a review.
  for hook_case in '{"tool_name":"Read","tool_input":{"command":"review-bench report x"}}' \
                   '{"tool_name":"Bash","tool_input":{"command":"cat notes.txt"}}'; do
    hook_foreign="$(jq -nc --arg output "$report_capture" --argjson case "$hook_case" \
      '$case + {tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
    assert test -z "$hook_foreign"
  done
  # A run read back with `head -N` can stop short of the closing rule and hold no run id to
  # re-render from: the model is then the only one still holding the report.
  hook_truncated="$(jq -nc \
    --arg output "$report_frame_header"$'\nT1 report\nfindings: none' \
    '{tool_name:"Bash",tool_input:{command:"review-bench record run --no-corpus"},
      tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
  assert contains "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$hook_truncated")" \
    "sed -n"
  assert test -z "$(jq -r '.systemMessage // ""' <<<"$hook_truncated")"
  # The other side of the same key: a window that cut the header is silent, because the closing
  # rule alone belongs to every framed report and to any `====` divider that reaches this hook.
  hook_headerless="$(jq -nc \
    --arg output $'T1 report\nfindings: none\n'"$report_frame_footer" \
    '{tool_name:"Bash",tool_input:{command:"review-bench record run"},
      tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
  assert test -z "$hook_headerless"
  # The header has to be the whole line: a report is not what a sentence mentioning one is.
  hook_inline="$(jq -nc --arg output "talking about $report_frame_header in passing" \
    '{tool_name:"Bash",tool_input:{command:"review-bench review --tier T1"},
      tool_response:{stdout:$output}}' | "$REPORT_HOOK")"
  assert test -z "$hook_inline"
  hook_without_output="$(jq -n --rawfile source "$SCRIPT" \
    '{tool_name:"Bash",tool_input:{command:"review-bench report x"},
      tool_response:{stdout:$source}}' | "$REPORT_HOOK")"
  assert test -z "$hook_without_output"
else
  printf 'SKIP: review report hook behavior (%s is unavailable)\n' "$REPORT_HOOK"
fi


# The review system's own health, which is a different question from a vendor cell's: `doctor`
# reads the stores and names the records nothing moved on, and answers 0 whatever it finds — a
# diagnostic that exits nonzero becomes a wall somewhere.
DOC_CACHE="$WORK/doctor-cache"
DOC_REPO="$WORK/doctor-repo"
git init -q "$DOC_REPO"
doctor_json() { # state-dir [args...]
  WORKER_STATS_DIR="$1" XDG_CACHE_HOME="$DOC_CACHE" "$SCRIPT" doctor --json "${@:2}"
}
doctor_count() { # state-dir class
  doctor_json "$1" | jq -r ".anomalies.\"$2\""
}
doc_run() { # store run-id hours-ago findings
  GATE_SD="$1" GATE_REPO="$DOC_REPO" gate_run "$2" "$3" "$4"
}

# Nothing recorded is not the same as nothing asked: every class is named clean, so a reader can
# tell a quiet system from a scan that never ran.
DOC_EMPTY="$WORK/doctor-empty"
mkdir -p "$DOC_EMPTY/benches"
doc_empty=$(WORKER_STATS_DIR="$DOC_EMPTY" XDG_CACHE_HOME="$DOC_CACHE" "$SCRIPT" doctor) \
  || fail "doctor exited nonzero on an empty store"
assert test "$doc_empty" = "ok: untriaged, undelivered, stuck_fixes, eternal_lock, orphan_debt, kill_asymmetry"
assert test "$(doctor_json "$DOC_EMPTY" | jq -r '.total')" = "0"

# untriaged: the Stop gate's own question asked at the age nobody is going to answer it at. A run
# still inside that gate's window is not one it failed to ask about, and a commit-point panel
# nobody scored is a benchmark backlog rather than a review that went unanswered.
DOC_UNTRIAGED="$WORK/doctor-untriaged"
doc_run "$DOC_UNTRIAGED" 20260801T000000Z-docold 20 0
assert test "$(doctor_count "$DOC_UNTRIAGED" untriaged)" = "1"
doc_run "$DOC_UNTRIAGED" 20260801T010000Z-docnew 2 0
assert test "$(doctor_count "$DOC_UNTRIAGED" untriaged)" = "1"
doc_run "$DOC_UNTRIAGED" 20260801T020000Z-docdurable 20 0
python3 - "$DOC_UNTRIAGED/benches/20260801T020000Z-docdurable/meta.json" <<'DOCPY'
import json
import sys
meta = json.loads(open(sys.argv[1]).read())
del meta["worktree"]
open(sys.argv[1], "w").write(json.dumps(meta) + "\n")
DOCPY
assert test "$(doctor_count "$DOC_UNTRIAGED" untriaged)" = "1"
# A run past the window is history: nobody triages last month's panel, and a count that only grows
# says the same thing every time it is read.
doc_run "$DOC_UNTRIAGED" 20260801T030000Z-docancient 400 0
assert test "$(doctor_count "$DOC_UNTRIAGED" untriaged)" = "1"

# undelivered: a round in a deliverable state whose launching chat's ledger holds no key for it.
# The ledger is claude-setup's, read here and never written: a diagnostic that keyed a delivery
# would retire a report nobody has seen.
DOC_DELIVERY="$WORK/doctor-delivery"
GATE_SD="$DOC_DELIVERY" GATE_REPO="$DOC_REPO" GATE_SESSION=doc-chat \
  gate_run 20260801T000000Z-docdeliver 8 0
WORKER_STATS_DIR="$DOC_DELIVERY" "$SCRIPT" record 20260801T000000Z-docdeliver --no-corpus \
  >/dev/null || fail "the delivery round refused its triage"
assert test "$(doctor_count "$DOC_DELIVERY" undelivered)" = "1"
mkdir -p "$DOC_CACHE/claude/review-delivery"
printf 'run:20260801T000000Z-docdeliver:done\n' \
  >"$DOC_CACHE/claude/review-delivery/doc-chat.emitted"
assert test "$(doctor_count "$DOC_DELIVERY" undelivered)" = "0"
# The state is half the key: a ledger holding the run under any other state has not delivered this
# one, and the state-blind key the nudge writes for itself is no answer either.
printf 'run:20260801T000000Z-docdeliver\nrun:20260801T000000Z-docdeliver:blocked\n' \
  >"$DOC_CACHE/claude/review-delivery/doc-chat.emitted"
assert test "$(doctor_count "$DOC_DELIVERY" undelivered)" = "1"
rm -f "$DOC_CACHE/claude/review-delivery/doc-chat.emitted"
# A benchmark row is not a round: it owes Egor no report, so it can never sit in this count.
DOC_BENCH="$WORK/doctor-bench"
GATE_SD="$DOC_BENCH" GATE_REPO="$DOC_REPO" GATE_SESSION=doc-chat \
  gate_run 20260801T000000Z-docbench 8 0
printf '' >"$DOC_BENCH/benches/20260801T000000Z-docbench/verdicts.jsonl"
assert test "$(doctor_count "$DOC_BENCH" undelivered)" = "0"
assert test "$(doctor_count "$DOC_BENCH" stuck_fixes)" = "0"

# stuck_fixes: a triage standing with nothing from its fixing pass. Measured from when somebody
# stood behind the findings, not from when the panel ran — the pass starts at the triage.
DOC_FIXES="$WORK/doctor-fixes"
GATE_SD="$DOC_FIXES" GATE_REPO="$DOC_REPO" GATE_SESSION=doc-chat \
  gate_run 20260801T000000Z-docfixes 60 2
printf '%s\n' '{"rater":"oc-kimik3","idx":0,"verdict":"confirmed"}' \
  '{"rater":"oc-kimik3","idx":1,"verdict":"confirmed"}' >"$WORK/doctor-verdicts.jsonl"
WORKER_STATS_DIR="$DOC_FIXES" "$SCRIPT" record 20260801T000000Z-docfixes --no-corpus \
  --verdicts "$WORK/doctor-verdicts.jsonl" >/dev/null || fail "the stuck round refused its triage"
assert test "$(doctor_count "$DOC_FIXES" stuck_fixes)" = "0"
python3 - "$DOC_FIXES/benches/20260801T000000Z-docfixes/reported.json" <<'DOCPY'
import json
import sys
from datetime import datetime, timedelta, timezone
receipt = json.loads(open(sys.argv[1]).read())
receipt["reported_at"] = (datetime.now(timezone.utc) - timedelta(hours=50)).isoformat()
open(sys.argv[1], "w").write(json.dumps(receipt) + "\n")
DOCPY
assert test "$(doctor_count "$DOC_FIXES" stuck_fixes)" = "1"
WORKER_STATS_DIR="$DOC_FIXES" "$SCRIPT" fixes 20260801T000000Z-docfixes --done --fixed 2 --fp 0 \
  >/dev/null || fail "fixes --done refused the stuck round"
assert test "$(doctor_count "$DOC_FIXES" stuck_fixes)" = "0"

# eternal_lock: a round locked on the P1 count that no later run holds. The lock is the mechanical
# second round, so one nothing has answered in a week is a chat that walked away from it.
DOC_LOCK_REPO="$WORK/doctor-lock-repo"
git init -q "$DOC_LOCK_REPO"
printf 'locked\n' >"$DOC_LOCK_REPO/held.py"
doc_lock_sha=$(git -C "$DOC_LOCK_REPO" hash-object -w held.py)
DOC_LOCK="$WORK/doctor-lock"
doc_lock_artifact() { # store run-id p1s
  mkdir -p "$1/benches/$2"
  python3 - "$1/benches/$2" "$2" "$DOC_LOCK_REPO" "$doc_lock_sha" "$3" <<'DOCPY'
import json
import pathlib
import sys
from datetime import datetime, timedelta, timezone
run = pathlib.Path(sys.argv[1])
finished = datetime.now(timezone.utc) - timedelta(hours=1)
(run / "meta.json").write_text(json.dumps({
    "run_id": sys.argv[2], "worktree": True, "repo": sys.argv[3], "session": "doc-chat",
    "raters": ["oc-kimik3"], "completed_raters": ["oc-kimik3"], "rater_runs": [],
    "reviewed": {"held.py": sys.argv[4]},
    "started": finished.isoformat(), "finished": finished.isoformat(),
}) + "\n")
(run / "reported.json").write_text(json.dumps({
    "reported_at": finished.isoformat(), "verdicts": 0, "confirmed": int(sys.argv[5]),
    "confirmed_by_severity": {"P1": int(sys.argv[5]), "P2": 0, "P3": 0}, "rows": [],
}) + "\n")
DOCPY
}
doc_lock_artifact "$DOC_LOCK" 20260101T000000Z-doclock 3
assert test "$(doctor_count "$DOC_LOCK" eternal_lock)" = "1"
# Discharged by a later run holding every surviving path of it, which is exactly what
# `covering_artifacts` hands the path over to — nothing here re-derives that rule.
doc_lock_artifact "$DOC_LOCK" 20260102T000000Z-docdischarge 0
assert test "$(doctor_count "$DOC_LOCK" eternal_lock)" = "0"
# A lock earned this week is the second round working, not one standing for ever.
DOC_FRESH_LOCK="$WORK/doctor-fresh-lock"
doc_lock_artifact "$DOC_FRESH_LOCK" "$(date -u -v-2d '+%Y%m%dT%H%M%SZ' 2>/dev/null \
  || date -u -d '2 days ago' '+%Y%m%dT%H%M%SZ')-docfresh" 3
assert test "$(doctor_count "$DOC_FRESH_LOCK" eternal_lock)" = "0"

# orphan_debt: debt paths whose only journal record is the original bare-path format, so no chat
# is ever asked to review or waive them.
DOC_DEBT_REPO="$WORK/doctor-debt-repo"
git init -q "$DOC_DEBT_REPO"
printf 'unowned\n' >"$DOC_DEBT_REPO/orphan.py"
printf 'owned\n' >"$DOC_DEBT_REPO/owned.py"
DOC_DEBT="$WORK/doctor-debt"
mkdir -p "$DOC_DEBT/benches/20260801T000000Z-docdebt"
python3 - "$DOC_DEBT/benches/20260801T000000Z-docdebt" "$DOC_DEBT_REPO" <<'DOCPY'
import json
import pathlib
import sys
from datetime import datetime, timedelta, timezone
run = pathlib.Path(sys.argv[1])
finished = datetime.now(timezone.utc) - timedelta(hours=1)
(run / "meta.json").write_text(json.dumps({
    "run_id": run.name, "worktree": True, "repo": sys.argv[2], "session": "doc-chat",
    "raters": ["oc-kimik3"], "completed_raters": ["oc-kimik3"], "rater_runs": [],
    "started": finished.isoformat(), "finished": finished.isoformat(),
}) + "\n")
(run / "verdicts.jsonl").write_text("")
DOCPY
printf 'orphan.py\0' >>"$DOC_DEBT_REPO/.git/claude-commit-journal"
printf 'doc-chat\t1800000000\towned.py\0' >>"$DOC_DEBT_REPO/.git/claude-commit-journal"
assert test "$(doctor_count "$DOC_DEBT" orphan_debt)" = "1"
assert contains "$(doctor_json "$DOC_DEBT" | jq -r '.details.orphan_debt[].what')" "orphan.py"
printf 'doc-chat\t1800000000\torphan.py\0' >>"$DOC_DEBT_REPO/.git/claude-commit-journal"
assert test "$(doctor_count "$DOC_DEBT" orphan_debt)" = "0"

# The other channel the gate answers `mine` out of: between a worker writing its file list and the
# journal sweeping it, the run record is where that path's owner lives. Counted as nobody's, the
# doctor reports debt a chat is being asked about at the same moment.
printf 'claimed\n' >"$DOC_DEBT_REPO/claimed.py"
printf 'claimed.py\0' >>"$DOC_DEBT_REPO/.git/claude-commit-journal"
assert test "$(doctor_count "$DOC_DEBT" orphan_debt)" = "1"
DOC_RUNS="$WORK/doctor-worker-runs"
mkdir -p "$DOC_RUNS/doc-worker-run"
printf 'doc-chat\n' >"$DOC_RUNS/doc-worker-run/launcher"
printf 'WORKDIR: %s\nclaimed.py\n' "$DOC_DEBT_REPO" >"$DOC_RUNS/doc-worker-run/files"
assert test "$(WORKER_RUN_DIR="$DOC_RUNS" doctor_count "$DOC_DEBT" orphan_debt)" = "0"
rm -rf "$DOC_RUNS"
rm -f "$DOC_DEBT_REPO/claimed.py"

# A repository is a repository whatever became of the panel that named it. Discovered from
# FINISHED runs alone, the two tree-level classes answer clean for exactly the checkout whose runs
# all died at launch — the shape `kill_asymmetry` exists to count.
DOC_INFLIGHT_REPO="$WORK/doctor-inflight-repo"
git init -q "$DOC_INFLIGHT_REPO"
printf 'inflight\n' >"$DOC_INFLIGHT_REPO/inflight.py"
printf 'inflight.py\0' >>"$DOC_INFLIGHT_REPO/.git/claude-commit-journal"
DOC_UNFINISHED="$WORK/doctor-unfinished"
mkdir -p "$DOC_UNFINISHED/benches/20260801T000000Z-docinflight"
python3 - "$DOC_UNFINISHED/benches/20260801T000000Z-docinflight" "$DOC_INFLIGHT_REPO" <<'DOCPY'
import json
import pathlib
import sys
run = pathlib.Path(sys.argv[1])
(run / "meta.json").write_text(json.dumps({
    "run_id": run.name, "worktree": True, "repo": sys.argv[2], "session": "doc-chat",
    "raters": ["oc-kimik3"], "completed_raters": [], "rater_runs": [],
    "started": "2026-08-01T00:00:00+00:00",
}) + "\n")
DOCPY
assert test "$(doctor_count "$DOC_UNFINISHED" orphan_debt)" = "1"
assert contains "$(doctor_json "$DOC_UNFINISHED" | jq -r '.details.orphan_debt[].what')" \
  "inflight.py"

# The workspace a merged panel was built in is not a checkout of Egor's. The state dir routinely
# sits under a symlink — macOS `/tmp`, `/var/folders`, this very fixture — so the exclusion is
# asked of resolved paths on both sides or it excludes nothing at all.
DOC_MERGED="$WORK/doctor-merged"
DOC_MERGED_WS="$DOC_MERGED/merged/docmergedws"
mkdir -p "$DOC_MERGED_WS" "$DOC_MERGED/benches/20260801T000000Z-docmerged"
git init -q "$DOC_MERGED_WS"
printf 'copy\n' >"$DOC_MERGED_WS/copied.py"
printf 'copied.py\0' >>"$DOC_MERGED_WS/.git/claude-commit-journal"
python3 - "$DOC_MERGED/benches/20260801T000000Z-docmerged" "$DOC_MERGED_WS" <<'DOCPY'
import json
import pathlib
import sys
from datetime import datetime, timedelta, timezone
run = pathlib.Path(sys.argv[1])
finished = datetime.now(timezone.utc) - timedelta(hours=1)
(run / "meta.json").write_text(json.dumps({
    "run_id": run.name, "worktree": True, "repo": sys.argv[2], "session": "doc-chat",
    "raters": ["oc-kimik3"], "completed_raters": ["oc-kimik3"], "rater_runs": [],
    "started": finished.isoformat(), "finished": finished.isoformat(),
}) + "\n")
DOCPY
assert test "$(doctor_count "$DOC_MERGED" orphan_debt)" = "0"

# kill_asymmetry: the fast-error path that never marks the run it killed. Nothing downstream can
# tell such a run from a clean one, so the count is how often that path is taken.
DOC_KILL="$WORK/doctor-kill"
doc_run "$DOC_KILL" 20260801T000000Z-dockill 3 0
# A panel that completed nothing left no cell record either: the launch document's empty list is
# all there is, which is what makes the run indistinguishable from a clean one downstream.
python3 - "$DOC_KILL/benches/20260801T000000Z-dockill/meta.json" <<'DOCPY'
import json
import sys
meta = json.loads(open(sys.argv[1]).read())
meta["completed_raters"] = []
meta["rater_runs"] = []
open(sys.argv[1], "w").write(json.dumps(meta) + "\n")
DOCPY
assert test "$(doctor_count "$DOC_KILL" kill_asymmetry)" = "1"
python3 - "$DOC_KILL/benches/20260801T000000Z-dockill/meta.json" <<'DOCPY'
import json
import sys
meta = json.loads(open(sys.argv[1]).read())
meta["timed_out"] = True
open(sys.argv[1], "w").write(json.dumps(meta) + "\n")
DOCPY
assert test "$(doctor_count "$DOC_KILL" kill_asymmetry)" = "0"
python3 - "$DOC_KILL/benches/20260801T000000Z-dockill/meta.json" <<'DOCPY'
import json
import sys
meta = json.loads(open(sys.argv[1]).read())
del meta["timed_out"]
meta["completed_raters"] = ["oc-kimik3"]
open(sys.argv[1], "w").write(json.dumps(meta) + "\n")
DOCPY
assert test "$(doctor_count "$DOC_KILL" kill_asymmetry)" = "0"
# Read through the tool's own reader, or a record written before the field existed — whose cells
# every other surface reconstructs as completed — is counted as a panel that completed nothing.
python3 - "$DOC_KILL/benches/20260801T000000Z-dockill/meta.json" <<'DOCPY'
import json
import sys
meta = json.loads(open(sys.argv[1]).read())
del meta["completed_raters"]
meta["rater_runs"] = [{"rater": "oc-kimik3", "exit_code": 0, "findings": 0, "duration_ms": 1000}]
open(sys.argv[1], "w").write(json.dumps(meta) + "\n")
DOCPY
assert test "$(doctor_count "$DOC_KILL" kill_asymmetry)" = "0"
python3 - "$DOC_KILL/benches/20260801T000000Z-dockill/meta.json" <<'DOCPY'
import json
import sys
meta = json.loads(open(sys.argv[1]).read())
meta["completed_raters"] = ["oc-kimik3"]
open(sys.argv[1], "w").write(json.dumps(meta) + "\n")
DOCPY
# A launch document carries no finish stamp, and a panel in flight is nobody's failure to act.
python3 - "$DOC_KILL/benches/20260801T000000Z-dockill/meta.json" <<'DOCPY'
import json
import sys
meta = json.loads(open(sys.argv[1]).read())
meta["completed_raters"] = []
del meta["finished"]
open(sys.argv[1], "w").write(json.dumps(meta) + "\n")
DOCPY
assert test "$(doctor_json "$DOC_KILL" | jq -r '.total')" = "0"

# A found anomaly still exits 0, and prints the classes it found beside the ones it did not.
doc_found=$(WORKER_STATS_DIR="$DOC_KILL" XDG_CACHE_HOME="$DOC_CACHE" "$SCRIPT" doctor) \
  || fail "doctor exited nonzero"
assert contains "$doc_found" "ok: untriaged"

# --snapshot writes exactly the document the menubar reads: any other key, and the renderer has no
# way to learn a class name it was never given.
DOC_SNAP="$WORK/doctor-snapshot-store"
doc_run "$DOC_SNAP" 20260801T000000Z-docsnap 20 0
WORKER_STATS_DIR="$DOC_SNAP" XDG_CACHE_HOME="$DOC_CACHE" "$SCRIPT" doctor --snapshot >/dev/null \
  || fail "doctor --snapshot failed"
doc_snapshot="$DOC_SNAP/doctor-snapshot.json"
assert test -f "$doc_snapshot"
assert test "$(jq -r 'keys | join(",")' "$doc_snapshot")" = "anomalies,as_of,total"
assert test "$(jq -r '.anomalies | keys | sort | join(",")' "$doc_snapshot")" \
  = "eternal_lock,kill_asymmetry,orphan_debt,stuck_fixes,undelivered,untriaged"
assert test "$(jq -r '.as_of | type' "$doc_snapshot")" = "number"
assert test "$(jq -r '.total' "$doc_snapshot")" = "1"
assert test "$(jq -r '.anomalies.untriaged' "$doc_snapshot")" = "1"
# `--snapshot` only ALSO writes the document, so it composes with the machine-readable form: a
# collector wanting both would otherwise pay for the whole scan twice. Its notice goes to stderr —
# `--json` promises ONE object on stdout, and a caller that has to cut a line off first is reading
# something else.
doc_both=$(WORKER_STATS_DIR="$DOC_SNAP" XDG_CACHE_HOME="$DOC_CACHE" "$SCRIPT" doctor \
  --json --snapshot 2>"$WORK/doctor-both.err") || fail "doctor --json --snapshot was refused"
assert contains "$(cat "$WORK/doctor-both.err")" "snapshot: $doc_snapshot"
assert test "$(jq -r '.total' <<<"$doc_both")" = "1"
assert test "$(grep -Fc -- "snapshot: " <<<"$doc_both")" -eq 0

# The collector is a launchd agent whose visible program is a wrapper carrying a name Login Items
# can be read by — never a bare interpreter. Installed here against a fixture HOME: a test that
# bootstrapped the real one would put a job on Egor's machine.
DOC_HOME="$WORK/doctor-home"
mkdir -p "$DOC_HOME"
python3 - "$SCRIPT" "$DOC_HOME" <<'DOCPY'
import importlib.machinery
import importlib.util
import os
import pathlib
import stat
import sys

loader = importlib.machinery.SourceFileLoader("review_bench", sys.argv[1])
rb = importlib.util.module_from_spec(importlib.util.spec_from_loader("review_bench", loader))
loader.exec_module(rb)
home = pathlib.Path(sys.argv[2])
paths = rb.write_doctor_agent(home)
wrapper, plist = paths["wrapper"], paths["plist"]
assert wrapper == home / ".local" / "libexec" / "review-doctord", wrapper
assert plist == home / "Library" / "LaunchAgents" / "com.llm-legs.review-doctor.plist", plist
body = wrapper.read_text()
assert body.startswith("#!/usr/bin/env bash\n"), body
assert body.strip().endswith("doctor --snapshot"), body
assert str(pathlib.Path(sys.argv[1]).resolve()) in body, body
assert os.stat(wrapper).st_mode & stat.S_IXUSR, oct(os.stat(wrapper).st_mode)
document = plist.read_text()
# The wrapper and nothing else: a plist naming python3 or bash reaches Login Items unnamed.
assert f"<string>{wrapper}</string>" in document, document
for bare in ("<string>python3</string>", "<string>/bin/bash</string>", "<string>bash</string>"):
    assert bare not in document, document
assert f"<integer>{rb.DOCTOR_AGENT_INTERVAL_S}</integer>" in document, document
assert rb.DOCTOR_AGENT_INTERVAL_S == 6 * 3600, rb.DOCTOR_AGENT_INTERVAL_S
assert f"<string>{rb.DOCTOR_AGENT_LABEL}</string>" in document, document
rb.remove_doctor_agent(home)
assert not plist.exists(), plist
assert not wrapper.exists(), wrapper
# A wrapper of that name pointing anywhere else belongs to somebody else, and uninstall leaves it.
wrapper.parent.mkdir(parents=True, exist_ok=True)
wrapper.write_text("#!/usr/bin/env bash\nexec /somewhere/else\n")
rb.remove_doctor_agent(home)
assert wrapper.exists(), wrapper
# A report receipt that is valid JSON but not an object answers no triage instant, and reached
# through `.get` it is an AttributeError — which is the scan exiting nonzero on a diagnostic whose
# whole contract is that it never does.
broken = home / "broken-round"
broken.mkdir(parents=True, exist_ok=True)
(broken / rb.REPORT_RECEIPT).write_text("null\n")
assert rb.doctor_triage_instant(broken) is None
(broken / "verdicts.jsonl").write_text("{}\n")
assert rb.doctor_triage_instant(broken) is not None
# Every class the scan can answer has an entry in the snapshot, and every aged one has exactly one
# threshold, spelled in the one dict and nowhere else.
assert set(rb.DOCTOR_AGES_S) <= set(rb.DOCTOR_CLASSES), rb.DOCTOR_AGES_S
assert rb.DOCTOR_AGES_S == {
    "untriaged": 18 * 3600, "undelivered": 6 * 3600,
    "stuck_fixes": 48 * 3600, "eternal_lock": 7 * 24 * 3600,
}, rb.DOCTOR_AGES_S
DOCPY
# The heredoc's own exit status, the way every other block here is read: unasked, an AssertionError
# inside it prints a traceback the suite walks straight past and still ends in PASS.
assert test "$?" -eq 0

# launchd refusing the job is the whole of the failure, and the only surface that could say so:
# an absent snapshot renders no menu line by design, so an install printing success over a
# collector that will never run once leaves nothing anywhere to notice it by. Against a stub
# launchctl and a fixture HOME — the real one would put a job on Egor's machine.
DOC_STUB="$WORK/doctor-launchctl-stub"
DOC_FAIL_HOME="$WORK/doctor-refused-home"
mkdir -p "$DOC_STUB" "$DOC_FAIL_HOME"
cat >"$DOC_STUB/launchctl" <<'STUB'
#!/bin/bash
[ "$1" = bootout ] && exit 0
echo "Load failed: 5: Input/output error" >&2
exit 5
STUB
chmod +x "$DOC_STUB/launchctl"
doc_refused=$(HOME="$DOC_FAIL_HOME" PATH="$DOC_STUB:$PATH" WORKER_STATS_DIR="$DOC_SNAP" \
  XDG_CACHE_HOME="$DOC_CACHE" "$SCRIPT" doctor --install-agent 2>&1) \
  && fail "doctor --install-agent reported success over a launchd that refused the job"
assert contains "$doc_refused" "launchd refused to load it"
assert contains "$doc_refused" "Input/output error"
assert test "$(grep -Fc -- "Installed com.llm-legs.review-doctor" <<<"$doc_refused")" -eq 0
# And a job launchd took is the plain success it always was.
cat >"$DOC_STUB/launchctl" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$DOC_STUB/launchctl"
doc_loaded=$(HOME="$DOC_FAIL_HOME" PATH="$DOC_STUB:$PATH" WORKER_STATS_DIR="$DOC_SNAP" \
  XDG_CACHE_HOME="$DOC_CACHE" "$SCRIPT" doctor --install-agent) \
  || fail "doctor --install-agent failed over a launchd that loaded the job"
assert contains "$doc_loaded" "Installed com.llm-legs.review-doctor"

printf 'PASS: %s assertions; canonical review tiers over one shared OpenCode floor and a per-tier Gemini panel that never runs Pro at T0, stays inside the account roster and contains its own tier'"'"'s default panel when escalated, with no retired cell in any of them, cells retired by measurement refused with their counts, tier CLI and fixture-backed tier execution, review receipts, rater grammar (incl. agy and OpenCode families), CLI option surface, worker-pick affordability, gap-driven auto-pick, Codex/Claude normalization, fixture-driven agy and OpenCode fail-closed handling, usage artifacts, resolved-model metadata, SHA-pinned prompt and verifier content, prompt-file transport and max-token fallback, agy sealed clones with no descendant-history leak and /code-review Markdown adaptation, persisted verdict/defect attribution written before the corpus row, re-adjudication replacing the rows of a run instead of silently keeping the old ones, recovered-verdict provenance, a clean-review marker recognised inside Claude and Codex envelopes, the Gemini per-model wall reaching SIDE_WALL from the log, an agy finding judged on its own transport first and handed to the gateway only where that transport declined, tiered path resolution with the parent tree as fallback, the repository a run reviewed stamped into the corpus or reported untraceable, cross-run defect reconciliation with severity taken from the members and every incomplete or repository-spanning grouping refused, the session account schedulable only as the pool'"'"'s reserve and never as a roster tail, and a per-side account exclusion honoured for pooled and fixed sides alike, the frontier engine scoring one fresh run per named cell with legacy specs normalised and a repeat priced as an independent run, record aggregation/dedupe, unique catches, misses, weighted review score, run listing, 429-detection (fixed), per-side account ordering with Gemini rotation onto a second account after a usage wall, errored-rater exclusion, cross-side parallelism result assembly, review lenses registered with a declared slug and their own P1/P2/P3 mapping, resolved through former slugs, replacing the vendor methodology on every side a lens can reach and refused where none can, trimmed to the lens'"'"'s own repeat count and recorded with their hash and source-drift state in both the launch and the finished meta, carried from there into the corpus row, the report header and a receipt of the lens'"'"'s own while every lens row stays out of the canonical defect list, the frontier denominators, the composition corpus and the default leaderboard, worktree runs narrowed to named paths whose snapshot holds only those paths, is deterministic per path set, spelled against the directory the caller stands in and lexically canonicalized so a `..` can neither walk out of the repository nor split one file into two scopes, carries its scope as commit trailers a failed read refuses rather than widens, so a rerun by sha stays inside it, refuses a commitish, a pathspec matching nothing and a scope holding no change — the refusal before any snapshot object is written — and writes only a receipt of its own — leaving the repository'"'"'s receipt untouched byte for byte, a lens narrowed by the same paths naming a combined receipt of its own that leaves the plain, pure-lens and pure-scope receipts byte for byte and survives a rerun by sha with both selectors intact, a day-one repository reviewed end to end — its root commit sealed and cloned, given a deterministic empty base commit inside that clone so the vendor skill diffs its whole content, measured in lines and paths against the empty tree rather than as an unmeasurable diff, and the report a worktree run owes: no markers before its triage, a receipt after it, a bounded ask allowance counted one appended line per ask, the lookup scoped to the repository so another chat cannot answer for it, both review hooks keyed so exactly one fires, and the one line the gate reads: debt as content against the newest artifact holding a path — a triaged run'"'"'s snapshot whoever launched it, or a waiver — a path no artifact ever held and a held path now gone both in debt whole, a link — dangling included — priced by its own text rather than through its target, an untriaged run settling nothing, the debt owned by whoever the two journals name, a waiver covering exactly the shas it recorded and no edit after them, a round past the second-round thresholds locking that waiver until a later run answers for it, and the newest hung run outranking every older answer until a later triaged run of its own speaks — with the watchdog capping every cell at the longest duration recorded for its own model and effort plus three minutes over a fifteen-minute floor and marking the run it killed timed out, and a merged review of several repositories read by one panel out of a single workspace holding each repository under its own prefix — deterministic, self-contained once built and pruned with the run it belongs to — whose findings and adjudication handoff name the repository each belongs to, whose scopes and progress are per repository, and which stamps EVERY repository it read with that repository'"'"'s own receipt, while refusing a commitish, a repository named twice, a clean tree, a missing repository and its own workspace as a tree to seal, with the gateway being down priced as a wait that expires rather than a verdict — the family whose every attempt failed on the gateway ITSELF cooling for a fixed span while a spent plan, a pool run dry behind one and an unusable answer are left to the records that already carry them, one canary attempt of the cooling family running inside that span so the recovery can be noticed at all, its answer clearing the wait and its failure extending it from the moment the outage began, written under a lock and not written at all where nothing changed, and a side the pool answers for left to the pool, and each repository of one panel named the way its half actually exists — a working tree or a range of its own commits as `PATH@BASE..HEAD`, sealed and stamped per member so the committed half answers only where its right end is the tree in front of the reader, refusing a target flag it duplicates, a bare repository beside it with no --worktree and a scope aimed at a range, and a range of commits reviewed as one target — sealed into a single commit carrying its right end'"'"'s tree over its left end as the parent, so every reader keyed on one sha reads the whole range, named by the commits it sealed rather than by how the caller spelled them so one range is one snapshot with one rerun, announced by its own ends with the seal named beside them, read back out of that seal by a rerun carrying no flags at all, refused when it names no shape or no change, shown as a range while it runs, and kept out of the repository'"'"'s receipt wherever its right end is not the tree standing in front of the reader, and the corpus closed to every commit-point review — the plain record command refused outright with the reporting one named in its place, the refusal and the flag'"'"'s own help promising only what --bench delivers (this run'"'"'s verdicts stored, never a corpus row), that flag refused in turn on a durable run it would buy the plain command'"'"'s own behaviour on, and the handoff printing that one command alone — with the block those reviews are read in framed to a fixed width no over-long word can flatten, opened by a line naming the panel that produced it, and carrying a cell row that counts every completed cell under the same names its neighbouring rows use — the ones that found nothing included, and a count missing from an older summary costing its own cell a number rather than the whole block, every one of those names and the tiers table'"'"'s own rendered by one derivation over the pool of cells the tiers can launch — version digits, effort and the bare mark each appearing only where two pool cells would otherwise collide, Claude and Codex effort always spelled because it is a launch parameter, the word skill never rendered at all, a family gaining a second variant IN THE POOL renaming itself with no list to edit, a cell only a stored run holds named against that pool and never over it — the arrival carrying whatever separates it, its report leaving the tiers table byte for byte — a worktree panel refused outright unless Egor asked for it by name — the one door, checked before any repository argument is resolved so a spelling the tool cannot resolve cannot fall through it — and the machine specs commands are spelled in left untouched, and the durable per-cell board that prints coverage only where a run'"'"'s panel held another model that is not an OpenCode cell — a solo or family-only run scoring none at all rather than its own catches back — folding a repeat suffix into the cell it belongs to while the usage file it names keeps that suffix, reading either vendor spelling of the same token record, pricing an OpenCode cell against the Go plan'"'"'s request grant and every other side not at all, bucketing each cell by its median wall clock against the same budgets the tiers are spelled in, marking with a ? every coverage number too few anchored runs or defects stand behind, counting beside it the bench runs of that cell nobody ever adjudicated — over benches that carry a finish stamp alone, so a run still in flight is never sold as evidence, and with a cell only those runs have ever measured given a row of its own whose every corpus-derived key is null rather than missing, pricing the vendors billed per token over their own measured usage in a unit the footer refuses to compare with the plan-request one, and answering the family, tier, machine-format and hand-scored flags it offers over a static block the text table always carries, every one of its rows named by the same derivation the report block spells a cell with — read over the whole board rather than over the pool alone, so two cells no tier can launch never answer to one name and neither takes the name of a cell that still runs — tagged with the leg the same prefix its cost is priced by names, and with whether any tier'"'"'s default panel holds it today, measured or not, beside a tiers block naming those panels in that same spelling, and the fix status a triaged round owes — recorded done with its two counts or blocked with its reason, refused without either and refused for a run nobody launched, rendered into a `fixes:` row the report always carries in one of three values and into one of exactly TWO frame words — the plain review once the fixes are done, there was nothing to fix, or the pass has not answered yet whatever its age, and NOT FINISHED with the stopped-at-the-threshold rows beneath it only where a receipt says the pass stopped — so a round whose pass still owes an answer is readable by the model and named by no delivery line at all, a second round over one scope — derived from an earlier run of that scope having its fixes DONE on record, read whole by this one and recent enough to be the same piece of work, not from a flag or from a blocked stop — offering no third pass where the first one still may, locking no waiver it could not answer, keyed for a merged panel on its members rather than on the workspace built for one run, and a round of a scope nobody has fixed yet, or of work an earlier round never read, still offered its own first, with a done receipt bound by its ROWS and not by their count alone to the triage it answered, so a re-adjudication puts the round back to unanswered whether or not it changed the tally, refused outright where its two counts answer for fewer findings than the triage confirmed, and never taken at all by a run nobody judged, and the delivery queue naming this chat'"'"'s own recorded runs alone, never another chat'"'"'s, never an untriaged one, never one past the triage window, never one whose done receipt the report has already rejected, never one whose fixing pass has not answered — at any age, dead delegate or not — speaking only states the Stop net can read, and spending nothing by answering; and the adjudication handoff ending at `record` for a run whose snapshot the checkout has moved past, counting a merged panel'"'"'s threshold stop per repository the way the gate prices it, and telling the worker to neither commit nor stage\n' "$asserts"
