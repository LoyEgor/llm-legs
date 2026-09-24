#!/usr/bin/env bash
# share/report_frame.py, the one renderer of every block Egor reads: frame, width, label column,
# fitting, number and time words, and the CLI report-bus and the claude-setup hooks call.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FRAME="$ROOT/share/report_frame.py"
asserts=0
assert() { asserts=$((asserts + 1)); "$@" || { printf 'FAIL: assert %s: %s\n' "$asserts" "$*" >&2; exit 1; }; }

out=$(FRAME_SHARE="$ROOT/share" python3 - <<'PY' 2>&1
import os
import sys

sys.path.insert(0, os.environ["FRAME_SHARE"])
import report_frame as f

T = f.THIN_SPACE
assert T == " "
assert f.WIDTH == 56 and f.LABEL_WIDTH == 14

assert f.header("commit") == "=" * 24 + " commit " + "=" * 24
assert f.end() == "=" * 56
for word in ("x", "review bugs · round 3", "review " + "edge-cases-" * 9 + " · round 2 · STALE"):
    line = f.header(word)
    assert len(line) == 56 and line[0] == "=" and line[-1] == "=", line
cut = f.header("review " + "x" * 80 + " · round 2 · STALE")
assert cut.endswith(" · round 2 · STALE =") and len(cut) == 56 and "…" in cut, cut

assert f.time_word(0) == "0s"
assert f.time_word(44.6) == "45s"
assert f.time_word(59.4) == "59s"
assert f.time_word(59.6) == "1.0m"
assert f.time_word(402) == "6.7m"
assert f.time_word(599) == "10m"
assert f.time_word(1620) == "27m"
for nothing in (None, -1, "12", True):
    assert f.time_word(nothing) == "–", nothing

assert f.count(999) == "999"
assert f.count(1234567) == f"1{T}234{T}567"
assert f.count(12.0) == "12"
assert f.count("n/a") == "n/a"

assert f.tallies([[3, 12, 0], [141, 5, 17]]) == ["  3/12/ 0", "141/ 5/17"]
assert f.tallies([]) == []

assert f.text_of({"seconds": 402}) == "6.7m"
assert f.text_of([3, " files · +", 1200, " −", 4]) == f"3 files · +1{T}200 −4"
assert f.text_of(None) == "" and f.text_of(-3) == "-3"
try:
    f.text_of({"ms": 3})
    raise SystemExit("a dict other than seconds must be refused")
except ValueError:
    pass

assert f.row_lines("files", "3") == ["files:        3"]
assert f.row_lines("files", "") == [] and f.row_lines("files", []) == []
assert f.row_lines("", ["a", "", "b"]) == [" " * 14 + "a", " " * 14 + "b"]
assert f.row_lines("files", "a\n\n  b") == ["files:        a", " " * 14 + "  b"]
assert f.row_lines("a-very-long-label", "v") == ["a-very-long-label:", " " * 14 + "v"]
paths = [f"src/{n}.py" for n in range(9)]
assert f.row_lines("paths", paths) == [f"{'paths:' if n == 0 else '':<14}src/{n}.py" for n in range(9)]

room = f.WIDTH - f.LABEL_WIDTH
path = "/Volumes/Work/Projects/review-bench/share/rbench/report.py"
fitted = f.fit(path, room)
assert fitted.startswith("…/") and fitted.endswith("/rbench/report.py") and len(fitted) <= room, fitted
prose = "the panel cut three chunks and two of them stalled under the duration cap"
fitted = f.fit(prose, room)
assert len(fitted) <= room and fitted.endswith("…") and not fitted.endswith(" …"), fitted
assert prose.startswith(fitted[:-1]), fitted
assert f.fit("a  b   c", room) == "a  b   c"
assert f.fit("x" * 60, room) == "x" * (room - 1) + "…"

block = f.block("worker", [("outcome", "done"), ("wall-clock", {"seconds": 45}), ("files", 2),
                           ("empty", ""), ("items", ["one " * 20, path])])
lines = block.split("\n")
assert lines[0] == f.header("worker") and lines[-1] == f.end()
assert all(len(line) <= 56 for line in lines), block
assert lines[1:4] == ["outcome:      done", "wall-clock:   45s", "files:        2"], lines
assert not any(line.startswith("empty:") for line in lines)
assert len(lines) == 7
print("ok")
PY
)
assert test "$out" = ok || { printf '%s\n' "$out" >&2; false; }

doc='{"word":"push","rows":[["repo","llm-legs"],["pushed",[[3," commits · ",{"seconds":78}]]]]}'
assert test "$(printf '%s' "$doc" | python3 "$FRAME" block)" = "$(printf '%s\n' \
  '========================= push =========================' \
  'repo:         llm-legs' \
  'pushed:       3 commits · 1.3m' \
  '========================================================')"
assert test "$(python3 "$FRAME" time 402)" = 6.7m
assert test "$(python3 "$FRAME" time soon)" = –
for bad in 'not json' '{"rows":[]}' '{"word":"","rows":[]}' '{"word":"x","rows":{}}' '{"word":"x","rows":[["a",{"ms":1}]]}'; do
  rc=0; err=$(printf '%s' "$bad" | python3 "$FRAME" block 2>&1 >/dev/null) || rc=$?
  assert test "$rc" -ne 0
done
rc=0; err=$(printf '%s' '{"word":"x","rows":[["a",{"ms":1}]]}' | python3 "$FRAME" block 2>&1 >/dev/null) || rc=$?
assert test "$rc" = 2
assert test "$err" = "report_frame: not a value: {'ms': 1}"
rc=0; python3 "$FRAME" >/dev/null 2>&1 || rc=$?
assert test "$rc" = 2

printf 'PASS: %s asserts; report frame width, label column, fitting, number and time words, CLI\n' "$asserts"
