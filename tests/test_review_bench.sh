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
import concurrent.futures
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import threading
import time

loader = importlib.machinery.SourceFileLoader("review_bench", sys.argv[1])
spec = importlib.util.spec_from_loader("review_bench", loader)
rb = importlib.util.module_from_spec(spec)
loader.exec_module(rb)
fixtures = pathlib.Path(sys.argv[2])
repo = pathlib.Path(sys.argv[3])
work = pathlib.Path(sys.argv[4])

assert rb.parse_rater("sol-medium") == {
    "spec": "sol-medium", "model": "sol", "effort": "medium", "side": "codex",
    "skill": False, "profile": None
}
assert rb.parse_rater("opus-xhigh")["side"] == "claude"
assert rb.parse_rater("opus-xhigh")["skill"] is False
assert rb.parse_rater("fable-medium")["model"] == "fable"
assert rb.parse_rater("opus-medium-skill") == {
    "spec": "opus-medium-skill", "model": "opus", "effort": "medium",
    "side": "claude", "skill": True, "profile": None
}
assert rb.parse_rater("sonnet-high-skill")["skill"] is True
assert rb.parse_rater("haiku-medium-skill")["side"] == "claude"
assert rb.parse_rater("agy-pro-low-skill") == {
    "spec": "agy-pro-low-skill", "model": "agy-pro", "effort": "low",
    "side": "agy", "skill": True, "profile": None
}
assert rb.parse_rater("agy-pro-high-skill")["skill"] is True
assert rb.parse_rater("agy-flash36-medium-skill")["side"] == "agy"
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
rb.refuse_retired_cells([rb.parse_rater(spec) for spec in rb.AUTO_RATERS])
assert rb.parse_rater("oc-glm52") == {
    "spec": "oc-glm52", "model": "oc-glm52", "effort": None,
    "side": "opencode", "skill": False, "profile": None
}
assert rb.parse_rater("oc-glm52-low")["effort"] == "low"
assert rb.parse_rater("oc-dsv4pro-high") == {
    "spec": "oc-dsv4pro-high", "model": "oc-dsv4pro", "effort": "high",
    "side": "opencode", "skill": False, "profile": None
}
assert rb.parse_rater("oc-grok45-low") == {
    "spec": "oc-grok45-low", "model": "oc-grok45", "effort": "low",
    "side": "opencode", "skill": False, "profile": None
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
    "side": "opencode", "skill": False, "profile": "google"
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
        "profile": None,
    }
for invalid in ("gpt-medium", "sol", "opus-ultra", "sol-mega", "",
                "sol-medium-skill", "opus-skill", "opus-medium-turbo",
                "oc-glm52-xhigh", "oc-glm52-high-skill"):
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
    if spec != "agy-flash36-low-skill"
]
picked, _, _ = rb.auto_pick(
    1, agy_gap_reviews, {"codex": True, "claude": True, "agy": True}
)
assert picked[0]["spec"] == "agy-flash36-low-skill"

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
assert rb.is_walled("agy", "work") and not rb.is_walled("agy", "main")
rb.WALLED_ACCOUNTS.clear()

# An account another rater already retired is excluded from the next request instead of ending
# the search, so a second usable account is still reached.
del os.environ["GEMINIB_EXHAUSTED_PROFILE"]
inherited_run = work / "agy-inherited-wall-run"
inherited_run.mkdir()
(work / "geminib-profile").write_text("")
rb.mark_walled("agy", "work")
_, inherited_account, inherited_result = rb.run_rater_task(
    rb.parse_rater("agy-flash36-low-skill"), repo, sha, "", inherited_run, "ignored fixture diff"
)
assert inherited_account == "main", (inherited_account, inherited_result)
assert inherited_result[0] == 0 and (work / "geminib-profile").read_text() == "main"
rb.WALLED_ACCOUNTS.clear()

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
assert rb.is_walled("agy", "work")
rb.WALLED_ACCOUNTS.clear()
del os.environ["AGY_FIXTURE_STDERR"]

# Claude bills fable separately, so a wall in one bucket must leave the other bucket alone.
rb.mark_walled("claude", "com", "fable")
assert rb.is_walled("claude", "com", "fable")
assert not rb.is_walled("claude", "com")
assert rb.wall_bucket(rb.parse_rater("fable-medium")) == "fable"
assert rb.wall_bucket(rb.parse_rater("opus-medium")) == "general"
rb.WALLED_ACCOUNTS.clear()

assert rb.SIDE_WALL["grok"](1, "", "json parse error at char 4290") is False
assert rb.SIDE_WALL["grok"](1, "", "HTTP 429 rate limit") is True
assert rb.SIDE_WALL["codex"](1, '{"type":"error","code":"usage_limit_exceeded"}', "") is True
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

fake_codex = work / "fake-codex"
fake_codex.write_text("""#!/usr/bin/env bash
set -eu
printf '%s\n' "$PWD" >"$RATER_CAPTURE_CWD"
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
""")
fake_codex.chmod(0o755)
os.environ.update({
    "REVIEW_BENCH_CODEX_BIN": str(fake_codex),
    "RATER_CAPTURE_CWD": str(work / "rater-cwd"),
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
assert "no parseable findings" in stderr and "I'll review" in stderr

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

assert rb.parse_verify_answer(
    '```json\n{"code_matches": true, "is_defect": false, "why": "style only"}\n```'
) == {"code_matches": True, "is_defect": False, "why": "style only"}
assert rb.parse_verify_answer('Sure!\n{"code_matches": false, "is_defect": true}')["is_defect"]
for unusable in ('{"code_matches": "yes", "is_defect": true}', "no verdict", "",
                 '{"is_defect": true}'):
    assert rb.parse_verify_answer(unusable) is None, unusable

verify_finding = {"severity": "P2", "file": "bin/review-bench", "line": 3, "summary": "claim"}
verify_text = rb.verify_prompt(verify_finding, "deadbee", "bin/review-bench",
                               ["alpha", "beta", "gamma"])
assert "3: gamma" in verify_text and "bin/review-bench:3 — claim" in verify_text
assert "code_matches" in verify_text and "is_defect" in verify_text
missing_text = rb.verify_prompt(verify_finding, "deadbee", "bin/gone", None)
assert "does not exist in commit deadbee" in missing_text

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

# Identical calls to one model differ by an order of magnitude, so a cell can be
# sampled and unioned; two wordings of the same defect must collapse to one row.
assert rb.same_defect(
    {"file": "bin/a.sh", "line": 751, "summary": "Unpinned worker=gemini always renders main"},
    {"file": "bin/a.sh", "line": 749, "summary": "worker=gemini without a pin always renders main"},
)
assert not rb.same_defect(
    {"file": "bin/a.sh", "line": 10, "summary": "regex accepts a leading hyphen"},
    {"file": "bin/b.sh", "line": 10, "summary": "regex accepts a leading hyphen"},
)
assert not rb.same_defect(
    {"file": "bin/a.sh", "line": 10, "summary": "regex accepts a leading hyphen"},
    {"file": "bin/a.sh", "line": 400, "summary": "quota probes run sequentially per profile"},
)
merged = rb.merge_samples([
    [{"file": "a", "line": 5, "summary": "guard runs after the branch"}],
    [{"file": "a", "line": 5, "summary": "the guard runs after the branch it protects"},
     {"file": "a", "line": 90, "summary": "usage totals are summed instead of maxed"}],
])
assert [row["line"] for row in merged] == [5, 90], merged
sample_run = work / "opencode-sample-run"
sample_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")
rc, _, sample_text, sample_stderr, _ = rb.run_opencode_sampled(
    opencode_rater, repo, sha, "", sample_run, "fixture commit diff", "opencode-go", 3
)
assert rc == 0 and "3/3 samples usable" in sample_stderr, sample_stderr
# Three identical samples are one defect, not three.
assert len(rb.normalize_findings(sample_text, "oc-glm52")) == \
    len(rb.normalize_findings(rb.run_opencode(
        opencode_rater, repo, sha, "", sample_run, "fixture commit diff",
        "opencode-go")[2], "oc-glm52"))

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
rb.WALLED_ACCOUNTS.clear()
del os.environ["OPENCODE_FIXTURE_RC"]
del os.environ["OPENCODE_FIXTURE_STDERR"]
assert rb.opencode_usage_wall("HTTP 429") and rb.opencode_usage_wall("usage limit reached")
assert not rb.opencode_usage_wall("HTTP 503 failover_exhausted")

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


# Every option cmd_run reads must exist on the command line: a flag wired only into the
# code path crashes the whole run at the first cell.
run_help="$("$SCRIPT" run --help 2>&1)"
assert contains "$run_help" "--repeat"
assert contains "$run_help" "--verify"
assert contains "$run_help" "--leg"
leg_conflict="$("$SCRIPT" run 143fc2f --leg --raters oc-kimik3 2>&1 || true)"
assert contains "$leg_conflict" "not allowed with argument --leg"
oc_table="$("$SCRIPT" oc-models 2>&1)"
assert contains "$oc_table" "measured capability"
assert contains "$oc_table" "oc-grok45"

printf 'PASS: %s assertions; rater grammar (incl. agy and OpenCode families), CLI option surface, worker-pick affordability, gap-driven auto-pick, Codex/Claude normalization, fixture-driven agy and OpenCode fail-closed handling, usage artifacts, SHA-pinned prompt and verifier content, prompt-file transport and max-token fallback, agy sealed clones with no descendant-history leak and /code-review Markdown adaptation, record aggregation/dedupe, unique catches, misses, weighted review score, run listing, 429-detection (fixed), per-side account ordering with Gemini rotation onto a second account after a usage wall, errored-rater exclusion, and cross-side parallelism result assembly\n' "$asserts"
