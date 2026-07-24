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

python3 - "$SCRIPT" "$ROOT/tests/fixtures/review-bench" "$ROOT" "$WORK" <<'PY'
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import subprocess
import sys

loader = importlib.machinery.SourceFileLoader("review_bench", sys.argv[1])
spec = importlib.util.spec_from_loader("review_bench", loader)
rb = importlib.util.module_from_spec(spec)
loader.exec_module(rb)
fixtures = pathlib.Path(sys.argv[2])
repo = pathlib.Path(sys.argv[3])
work = pathlib.Path(sys.argv[4])

assert rb.parse_rater("sol-medium") == {
    "spec": "sol-medium", "model": "sol", "effort": "medium", "side": "codex",
    "skill": False
}
assert rb.parse_rater("opus-xhigh")["side"] == "claude"
assert rb.parse_rater("opus-xhigh")["skill"] is False
assert rb.parse_rater("fable-medium")["model"] == "fable"
assert rb.parse_rater("opus-medium-skill") == {
    "spec": "opus-medium-skill", "model": "opus", "effort": "medium",
    "side": "claude", "skill": True
}
assert rb.parse_rater("sonnet-high-skill")["skill"] is True
assert rb.parse_rater("haiku-medium-skill")["side"] == "claude"
assert rb.parse_rater("agy-pro-low") == {
    "spec": "agy-pro-low", "model": "agy-pro", "effort": "low",
    "side": "agy", "skill": False
}
assert rb.parse_rater("agy-pro-high-skill")["skill"] is True
assert rb.parse_rater("agy-flash-medium")["side"] == "agy"
for effort in ("low", "medium", "high"):
    for suffix, skill in (("", False), ("-skill", True)):
        rater = rb.parse_rater(f"agy-flash35-{effort}{suffix}")
        assert rater == {
            "spec": f"agy-flash35-{effort}{suffix}",
            "model": "agy-flash35",
            "effort": effort,
            "side": "agy",
            "skill": skill,
        }
for invalid in ("gpt-medium", "sol", "opus-ultra", "sol-mega", "",
                "sol-medium-skill", "opus-skill", "opus-medium-turbo"):
    try:
        rb.parse_rater(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError(f"accepted invalid rater: {invalid}")
for invalid, message in (
    ("agy-pro-medium", "agy-pro supports only low or high effort"),
    ("agy-flash-xhigh", "agy-flash supports only low, medium, or high effort"),
    ("agy-flash35-xhigh", "agy-flash35 supports only low, medium, or high effort"),
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
assert pick["claude"] is True
assert pick["claude_account"] == "worker"
assert pick["session_account"] == "session"

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
    elif rater == "haiku-medium":
        count = 1
    for index in range(count):
        reviews.append({"run_id": f"{rater}-{index}", "rater_model": model,
                        "rater_effort": effort})
availability = {"codex": True, "claude": True, "agy": True}
picked, counts, skipped = rb.auto_pick(2, reviews, availability)
assert [row["spec"] for row in picked] == ["sol-medium", "haiku-medium"]
assert [counts[row["spec"]] for row in picked] == [0, 1]
assert not skipped

availability["claude"] = False
availability["agy"] = False
picked, counts, skipped = rb.auto_pick(2, reviews, availability)
assert all(row["side"] == "codex" for row in picked)
assert any(spec.startswith("haiku-") for spec, _ in skipped)
assert any(spec.startswith("agy-") for spec, _ in skipped)

agy_gap_reviews = [
    {"rater": spec}
    for spec in rb.AUTO_RATERS
    if spec != "agy-flash-low"
]
picked, _, _ = rb.auto_pick(
    1, agy_gap_reviews, {"codex": True, "claude": True, "agy": True}
)
assert picked[0]["spec"] == "agy-flash-low"

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

agy_bare = rb.normalize_agy_output(
    (fixtures / "agy-bare-preamble.txt").read_text(), "agy-flash-low"
)
assert "I reviewed" not in agy_bare
assert [(row["severity"], row["file"], row["line"]) for row in
        rb.normalize_findings(agy_bare, "agy-flash-low")] == [
    ("P1", "src/auth.py", 41),
    ("P3", "src/cache.py", 18),
]
valid_finding = {
    "severity": "P2", "file": "src/auth.py", "line": 12,
    "summary": "Preserve the complete review",
}
invalid_finding = {
    "severity": "P2", "file": "src/auth.py",
    "summary": "This object is missing its line number",
}
for malformed in (
    json.dumps({"findings": [valid_finding, invalid_finding]}),
    "\n".join((json.dumps(valid_finding), json.dumps(invalid_finding))),
):
    try:
        rb.normalize_agy_output(malformed, "agy-flash-low")
    except ValueError as exc:
        assert "invalid finding object" in str(exc)
    else:
        raise AssertionError("accepted a partial agy review")
line_zero = rb.normalize_agy_output(
    json.dumps({
        "severity": "P3", "file": "src/generated.py", "line": 0,
        "line_number": 99, "summary": "Keep the zero line sentinel",
    }),
    "agy-flash-low",
)
assert rb.normalize_findings(line_zero, "agy-flash-low")[0]["line"] == 0
finding_with_error = rb.normalize_agy_output(
    json.dumps({
        "severity": "P2", "file": "src/parser.py", "line": 8,
        "summary": "Retain the finding", "error": "describes the error path",
    }),
    "agy-flash-low",
)
assert rb.normalize_findings(finding_with_error, "agy-flash-low")[0]["summary"] == \
    "Retain the finding"
for malformed in ("", (fixtures / "agy-bare-malformed.txt").read_text()):
    try:
        rb.normalize_agy_output(malformed, "agy-flash-low")
    except ValueError as exc:
        assert "malformed JSON envelope" in str(exc)
    else:
        raise AssertionError("accepted malformed agy output")
agy_clean = rb.normalize_agy_output(
    (fixtures / "agy-bare-clean.json").read_text(), "agy-flash-low"
)
assert rb.normalize_findings(agy_clean, "agy-flash-low") == []
try:
    rb.normalize_agy_output(
        (fixtures / "agy-bare-error.json").read_text(), "agy-flash-low"
    )
except ValueError as exc:
    assert "agy returned an error envelope" in str(exc)
else:
    raise AssertionError("accepted agy error envelope")

agy_skill = rb.normalize_agy_skill_output(
    (fixtures / "agy-skill-output.md").read_text(), "agy-flash-low-skill"
)
skill_rows = rb.normalize_findings(agy_skill, "agy-flash-low-skill")
assert [(row["severity"], row["file"], row["line"]) for row in skill_rows] == [
    ("P1", "src/auth.py", 41),
    ("P3", "src/cache.py", 18),
]
assert "anonymous request" in skill_rows[0]["summary"]
agy_skill_clean = rb.normalize_agy_skill_output(
    (fixtures / "agy-skill-clean.md").read_text(), "agy-flash-low-skill"
)
assert rb.normalize_findings(agy_skill_clean, "agy-flash-low-skill") == []
try:
    rb.normalize_agy_skill_output(
        (fixtures / "agy-skill-no-repo.md").read_text(), "agy-flash-low-skill"
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
os.environ.update({
    "REVIEW_BENCH_AGY_BIN": str(fixtures / "fake-agy.sh"),
    "AGY_FIXTURE_LOG": str(fixtures / "agy-log.txt"),
    "AGY_CAPTURE_PROMPT": str(work / "agy-prompt"),
    "AGY_CAPTURE_CWD": str(work / "agy-cwd"),
    "AGY_CAPTURE_HEAD": str(work / "agy-head"),
    "AGY_CAPTURE_ORIGIN_HEAD": str(work / "agy-origin-head"),
})

bare_run = work / "agy-bare-run"
bare_run.mkdir()
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-bare-preamble.txt")
bare_rater = rb.parse_rater("agy-flash-low")
rc, duration, text, stderr, command = rb.run_agy(
    bare_rater, repo, sha, "", bare_run, "fixture commit diff"
)
assert rc == 0 and duration >= 0 and not stderr
assert len(rb.normalize_findings(text, bare_rater["spec"])) == 2
assert (work / "agy-head").read_text().strip() == sha
assert pathlib.Path((work / "agy-cwd").read_text().strip()) != repo
assert (work / "agy-prompt").read_text() == rb.AGY_PRINT_INSTRUCTION
assert command[:10] == [
    str(fixtures / "fake-agy.sh"),
    "--model", "gemini-3.6-flash",
    "--effort", "low",
    "--mode", "plan",
    "--sandbox",
    "--print-timeout", "10m",
]
assert command[10] == "--log-file"
assert pathlib.Path(command[11]) == bare_run / "agy-agy-flash-low.log"
assert command[12:] == ["--print", rb.AGY_PRINT_INSTRUCTION]
usage = json.loads((bare_run / "usage-agy-flash-low.jsonl").read_text())
assert usage["model"] == "gemini-3.6-flash"
assert usage["duration_ms"] == duration
assert usage["prompt_tokens"] == 120
assert usage["output_tokens"] == 30
assert usage["total_tokens"] == 150
assert usage["stream_generate_requests"] == 1
assert usage["stream_completions"] == 1

large_run = work / "agy-large-run"
large_run.mkdir()
large_diff = "fixture large diff\n" + ("x" * 1000000)
kept_clones = []
original_seal = rb.seal_overlay_clone
original_rmtree = rb.shutil.rmtree
def keep_sealed_clone(*args):
    clone = original_seal(*args)
    kept_clones.append(pathlib.Path(clone))
    return clone
rb.seal_overlay_clone = keep_sealed_clone
rb.shutil.rmtree = lambda *args, **kwargs: None
try:
    rc, _, text, stderr, large_command = rb.run_agy(
        bare_rater, repo, sha, "", large_run, large_diff
    )
    assert rc == 0 and text and not stderr
    input_text = (kept_clones[-1] / rb.AGY_REVIEW_INPUT).read_text()
    assert large_diff in input_text
    assert '{"findings":[]}' in input_text
    assert "without using tools or commands" in input_text
    assert large_command[-2:] == ["--print", rb.AGY_PRINT_INSTRUCTION]
    assert max(map(len, large_command)) < 4096
finally:
    rb.seal_overlay_clone = original_seal
    rb.shutil.rmtree = original_rmtree
    for clone in kept_clones:
        original_rmtree(clone, ignore_errors=True)

usage_run = work / "agy-usage-run"
usage_run.mkdir()
repeated_log = (fixtures / "agy-log.txt").read_text() + """
I0724 01:11:42.000000 usage.go:10] promptTokenCount=100 candidatesTokenCount=20 totalTokenCount=120
I0724 01:11:43.000000 usage.go:10] promptTokenCount=240 candidatesTokenCount=60 totalTokenCount=300 cachedContentTokenCount=40 thoughtsTokenCount=25
"""
rb.write_agy_usage(usage_run, bare_rater, 12, repeated_log)
repeated_usage = json.loads(
    (usage_run / "usage-agy-flash-low.jsonl").read_text()
)
assert repeated_usage["prompt_tokens"] == 240
assert repeated_usage["output_tokens"] == 60
assert repeated_usage["total_tokens"] == 300
assert repeated_usage["cached_tokens"] == 40
assert repeated_usage["reasoning_tokens"] == 25

flash35_run = work / "agy-flash35-run"
flash35_run.mkdir()
flash35_rater = rb.parse_rater("agy-flash35-medium")
rc, _, text, stderr, flash35_command = rb.run_agy(
    flash35_rater, repo, sha, "", flash35_run, "fixture commit diff"
)
assert rc == 0 and not stderr
assert len(rb.normalize_findings(text, flash35_rater["spec"])) == 2
assert flash35_command[1:3] == ["--model", "gemini-3.5-flash-medium"]
assert "--effort" not in flash35_command
flash35_usage = json.loads(
    (flash35_run / "usage-agy-flash35-medium.jsonl").read_text()
)
assert flash35_usage["model"] == "gemini-3.5-flash-medium"
assert flash35_usage["effort"] == "medium"

malformed_run = work / "agy-malformed-run"
malformed_run.mkdir()
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-bare-malformed.txt")
rc, _, text, stderr, _ = rb.run_agy(
    bare_rater, repo, sha, "", malformed_run, "fixture commit diff"
)
assert rc == 1 and not text
assert "agy returned malformed JSON envelope" in stderr

denied_run = work / "agy-denied-run"
denied_run.mkdir()
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-empty.txt")
os.environ["AGY_FIXTURE_STDERR"] = str(fixtures / "agy-headless-denied.txt")
skill_rater = rb.parse_rater("agy-flash-low-skill")
rc, _, text, stderr, denied_command = rb.run_agy(
    skill_rater, repo, sha, "", denied_run, "ignored fixture diff"
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
    skill_rater, repo, sha, "", no_repo_run, "ignored fixture diff"
)
assert rc == 1 and not text
assert "did not enter the sealed git repository" in stderr

skill_run = work / "agy-skill-run"
skill_run.mkdir()
os.environ["AGY_FIXTURE_STDOUT"] = str(fixtures / "agy-skill-output.md")
rc, _, text, stderr, skill_command = rb.run_agy(
    skill_rater, repo, sha, "Check cancellation handling",
    skill_run, "ignored fixture diff"
)
assert rc == 0 and not stderr
assert len(rb.normalize_findings(text, skill_rater["spec"])) == 2
assert (work / "agy-prompt").read_text() == \
    "/code-review\nAdditional review focus: Check cancellation handling"
assert (work / "agy-origin-head").read_text().strip() == parent
assert skill_command[:7] == [
    str(fixtures / "fake-agy.sh"),
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
    flash35_skill_rater, repo, sha, "", flash35_skill_run, "ignored fixture diff"
)
assert rc == 0 and not stderr
assert len(rb.normalize_findings(text, flash35_skill_rater["spec"])) == 2
assert flash35_skill_command[1:3] == ["--model", "gemini-3.5-flash-high"]
assert "--effort" not in flash35_skill_command
assert "--new-project" in flash35_skill_command
assert "--dangerously-skip-permissions" in flash35_skill_command
print("review-bench-unit-ok")
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
            {"rater":"opus-medium","model":"opus","effort":"medium","side":"claude","exit_code":0},
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

python3 - "$SD/reviews.jsonl" <<'PY'
import json
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
print("record-math-ok")
PY
assert test "$?" -eq 0

again=$(WORKER_STATS_DIR="$SD" "$SCRIPT" record run-fixture --verdicts "$VERDICTS") || fail "record dedupe failed"
assert contains "$again" 'recorded 0 rater row(s)'
assert test "$(wc -l <"$SD/reviews.jsonl")" -eq 2

python3 - "$SD/benches/run-fixture/meta.json" <<'PY'
import json
import sys

meta = json.loads(open(sys.argv[1]).read())
assert isinstance(meta.get("rater_runs"), list)
for run in meta["rater_runs"]:
    if run.get("errored"):
        assert run["rater"] not in meta["raters"], \
            f"errored rater {run['rater']} should not be in meta['raters']"
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

table=$(WORKER_STATS_DIR="$SD" "$STATS") || fail "worker-stats static view failed"
assert contains "$table" 'Fable-rework leaderboard'
assert contains "$table" 'Review benchmark leaderboard'
assert contains "$table" 'sol/medium'

listing=$(WORKER_STATS_DIR="$SD" "$SCRIPT" list) || fail "list failed"
assert contains "$listing" 'run-fixture'
assert contains "$listing" 'adjudicated'

printf 'PASS: %s assertions; rater grammar (incl. agy family effort gates and -skill mode), worker-pick affordability, gap-driven auto-pick, Codex/Claude normalization, fixture-driven agy JSONL/preamble/malformed-envelope handling, agy usage artifacts and sealed clone, agy /code-review Markdown adaptation, record aggregation/dedupe, unique catches, misses, weighted review score, run listing, 429-detection (fixed), errored-rater exclusion, and cross-side parallelism result assembly\n' "$asserts"
