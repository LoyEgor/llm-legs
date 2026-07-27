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
import argparse
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
expected_tiers = {
    "T0": [
        "oc-kimik3", "oc-grok45-low", "agy-pro-high-skill",
        "agy-flash35-medium-skill", "sol-low",
    ],
    "T1": [
        "oc-kimik3", "oc-grok45-low", "agy-pro-high-skill",
        "agy-flash35-medium-skill", "sol-low", "sol-medium",
        "agy-flash36-medium-skill", "opus-medium-skill",
    ],
    "T2": [
        "oc-kimik3", "oc-grok45-low", "agy-pro-high-skill",
        "agy-flash35-medium-skill", "sol-low", "sol-medium",
        "agy-flash36-medium-skill", "opus-medium-skill", "sol-high",
        "opus-high-skill", "opus-medium", "sonnet-medium-skill",
    ],
    "T3": [
        "oc-kimik3", "oc-grok45-low", "agy-pro-high-skill",
        "agy-flash35-medium-skill", "sol-low", "sol-medium",
        "agy-flash36-medium-skill", "opus-medium-skill", "sol-high",
        "opus-high-skill", "sonnet-medium-skill", "opus-medium", "sol-xhigh",
        "sol-max", "opus-xhigh-skill", "opus-high", "sonnet-xhigh-skill",
    ],
}
assert list(rb.REVIEW_TIERS) == ["T0", "T1", "T2", "T3"]
assert [tier["budget_min"] for tier in rb.REVIEW_TIERS.values()] == [2, 6, 10, 20]
assert {
    tier_name: tier["cells"] for tier_name, tier in rb.REVIEW_TIERS.items()
} == expected_tiers
for tier in rb.REVIEW_TIERS.values():
    assert tier["when"]
    assert [rb.parse_rater(cell)["spec"] for cell in tier["cells"]] == tier["cells"]
for lower, upper in zip(("T0", "T1", "T2"), ("T1", "T2", "T3")):
    assert set(rb.REVIEW_TIERS[lower]["cells"]) < set(rb.REVIEW_TIERS[upper]["cells"])
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
for bare_sonnet in ("sonnet-low", "sonnet-medium", "sonnet-high", "sonnet-xhigh"):
    assert bare_sonnet not in rb.AUTO_RATERS, bare_sonnet
    try:
        rb.refuse_retired_cells([rb.parse_rater(bare_sonnet)])
    except RuntimeError as exc:
        assert f"{bare_sonnet}-skill" in str(exc), exc
    else:
        raise AssertionError(f"accepted a bare sonnet rater: {bare_sonnet}")
rb.refuse_retired_cells([rb.parse_rater(spec) for spec in ("opus-medium", "opus-high")])
assert "opus-medium" in rb.REVIEW_TIERS["T2"]["cells"]
assert "opus-high" in rb.REVIEW_TIERS["T3"]["cells"]
# The cheapest way to run a refused model would be to ask for it as the verifier.
for dead_verifier in ("oc-glm52", "oc-kimik27code"):
    try:
        rb.verifier_model(dead_verifier)
    except RuntimeError as exc:
        assert dead_verifier in str(exc), exc
    else:
        raise AssertionError(f"accepted a retired verifier: {dead_verifier}")
assert rb.verifier_model(rb.OPENCODE_VERIFIER) == rb.OPENCODE_VERIFIER
for dead, needle in (("haiku-medium", "0 defects"), ("oc-glm52", "3 true"),
                     ("agy-flash36-low-skill", "0 true")):
    try:
        rb.refuse_retired_cells([rb.parse_rater(dead)])
    except RuntimeError as exc:
        assert dead in str(exc) and needle in str(exc), exc
    else:
        raise AssertionError(f"accepted a cell the corpus retired: {dead}")
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
    if spec != "agy-flash35-low-skill"
]
picked, _, _ = rb.auto_pick(
    1, agy_gap_reviews, {"codex": True, "claude": True, "agy": True}
)
assert picked[0]["spec"] == "agy-flash35-low-skill"

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
rb.WALLED_ACCOUNTS.clear()

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
assert rb.is_walled("agy", "work", rb.wall_bucket(rb.parse_rater("agy-flash36-low-skill")))
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
# Two findings a rater deliberately reported apart stay apart: same_defect exists to collapse
# one defect worded twice across samples, not to second-guess a rater within one.
one_sample = rb.merge_samples([[
    {"file": "a", "line": 5, "summary": "the guard runs after the branch it protects"},
    {"file": "a", "line": 7, "summary": "the guard runs after the branch it releases"},
]])
assert len(one_sample) == 2, one_sample
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

# A verifier that walls has to record the wall before it lets the next one through the gate:
# released first, a queued verifier takes the slot, passes the post-gate check and sends one
# more doomed request.
rb.WALLED_ACCOUNTS.clear()
gate_saw = []
real_gate = rb.OPENCODE_GATE


class WallOrderGate:
    def acquire(self, *args):
        real_gate.acquire(*args)

    def release(self):
        gate_saw.append(rb.is_walled("opencode", rb.SIDE_FIXED_ACCOUNTS["opencode"]))
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

rb.WALLED_ACCOUNTS.clear()
del os.environ["OPENCODE_FIXTURE_RC"]
del os.environ["OPENCODE_FIXTURE_STDERR"]
assert rb.opencode_usage_wall("HTTP 429") and rb.opencode_usage_wall("usage limit reached")
assert not rb.opencode_usage_wall("HTTP 503 failover_exhausted")

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
rb.WALLED_ACCOUNTS.clear()

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
assert rb.unusable_review("", [{"severity": "P1"}]) == ""
for stopped in ("", "Still waiting for the remaining agents before compiling final findings.",
                "The commit looks reasonable overall; I did not spot anything alarming."):
    assert rb.unusable_review(stopped, []), stopped
assert "(empty answer)" in rb.unusable_review("", [])
# The marker has to be the whole answer; matched anywhere it hands prose a free pass and
# undoes the very distinction it exists to draw.
for rambling in ("I checked the rotation and found no findings for it, but the gate looks wrong.",
                 "No issues found in run_opencode. The verifier, however, never re-checks."):
    assert rb.unusable_review(rambling, []), rambling
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
rb.WALLED_ACCOUNTS.clear()
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
rb.WALLED_ACCOUNTS.clear()

# Every sample keeps its own artifacts, and what the cell returns is the merged union it
# reports — not one sample's raw text with a note claiming a merge happened.
repeat_run = work / "opencode-repeat-run"
repeat_run.mkdir()
rc, _, repeat_text, repeat_stderr, _ = rb.run_opencode_sampled(
    opencode_rater, repo, sha, "", repeat_run, "fixture commit diff", "opencode-go", 2
)
assert rc == 0 and "2/2 samples usable" in repeat_stderr, repeat_stderr
for sample in (1, 2):
    assert (repeat_run / f"raw-oc-glm52-s{sample}.json").exists()
    assert (repeat_run / f"usage-oc-glm52-s{sample}.json").exists()
repeat_rows = [json.loads(line) for line in repeat_text.splitlines()]
assert len(repeat_rows) == 1 and repeat_rows[0]["rater"] == "oc-glm52", repeat_rows
# A single sample takes the same path, or the cell's text and its note disagree.
single_run = work / "opencode-single-run"
single_run.mkdir()
_, _, single_text, _, _ = rb.run_opencode_sampled(
    opencode_rater, repo, sha, "", single_run, "fixture commit diff", "opencode-go", 1
)
assert [json.loads(line)["rater"] for line in single_text.splitlines()] == ["oc-glm52"]
assert (single_run / "raw-oc-glm52.json").exists()
# A union of clean samples is a clean review, not a cell that said nothing.
clean_sample_run = work / "opencode-clean-sample-run"
clean_sample_run.mkdir()
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-clean.json")
_, _, clean_sample_text, _, _ = rb.run_opencode_sampled(
    opencode_rater, repo, sha, "", clean_sample_run, "fixture commit diff", "opencode-go", 1
)
assert rb.unusable_review(clean_sample_text, []) == "", clean_sample_text
os.environ["OPENCODE_FIXTURE_STDOUT"] = str(fixtures / "opencode-happy.json")

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


def tier_runner(rater, repo_path, commit, focus, run_dir, diff, account, repeat=1):
    reviewed_cells.append(rater["spec"])
    return 0, 1, "NO FINDINGS", "", []


for side in rb.SIDE_RUNNERS:
    rb.SIDE_RUNNERS[side] = tier_runner
rb.pool_account = lambda side, excluded: "fixture"
rb.affordability = lambda: {
    "claude": True, "codex": True, "agy": True, "grok": True, "opencode": True,
    "claude_account": "fixture",
}
rb.check_limits_staleness = lambda account: False
review_rc = rb.cmd_review(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha, tier="T1",
    verify=None, focus=None, repeat=1,
))
review_meta_path = next((review_store / "worker-stats" / "benches").glob("*/meta.json"))
review_meta = json.loads(review_meta_path.read_text())
assert review_rc == 0
assert review_meta["raters"] == expected_tiers["T1"], review_meta["raters"]
assert sorted(reviewed_cells) == sorted(expected_tiers["T1"]), reviewed_cells

os.environ["CLAUDEB_DIR"] = str(model_store)


def model_runner(rater, repo_path, commit, focus, run_dir, diff, account, repeat=1):
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
rb.pool_account = lambda side, excluded: "fixture"
rb.affordability = lambda: {
    "claude": True, "codex": False, "claude_account": "fixture",
}
rb.check_limits_staleness = lambda account: False
run_rc = rb.cmd_run(argparse.Namespace(
    repo=str(pin_repo), commitish=pin_sha,
    raters="opus-medium,sonnet-medium-skill", leg=False, verify=None,
    auto=None, focus=None, repeat=1,
))
model_meta_path = next((model_state / "benches").glob("*/meta.json"))
model_meta = json.loads(model_meta_path.read_text())
model_runs = {
    row["rater"]: row
    for row in model_meta["rater_runs"]
}
assert (
    run_rc == 1
    and model_meta["raters"] == ["opus-medium"]
    and model_runs["sonnet-medium-skill"].get("errored") is True
    and model_runs["opus-medium"].get("model_resolved") == "claude-opus-5"
    and "model_resolved" not in model_runs["sonnet-medium-skill"]
), model_runs

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


def suggest(path, *extra):
    proc = subprocess.run(
        [sys.argv[1], "suggest", "--repo", str(path), *extra],
        check=True, capture_output=True, text=True, env=suggest_env,
    )
    return proc.stdout.splitlines()


def assert_suggestion(lines, files, changed_lines, tier, committed=False):
    assert lines[:3] == [
        f"changed files: {files}",
        f"changed lines: {changed_lines}",
        f"tier: {tier}",
    ], lines
    if committed:
        assert lines[3].startswith("command: review-bench review "), lines
        assert f"--tier {tier}" in lines[3], lines
        return
    # A rater reviews a sealed commit, so an uncommitted diff must not be handed a command that
    # would review the previous one and report this change as covered.
    assert lines[3].startswith("uncommitted: "), lines
    assert lines[4].startswith("next: commit it, then run ") and "<sha>" in lines[4], lines
    assert f"--tier {tier}" in lines[4], lines


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
assert range_head in range_lines[3], range_lines

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

python3 - "$SD/reviews.jsonl" "$RUN/verdicts.jsonl" "$RUN/defects.jsonl" <<'PY'
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
), (verdicts, defects, rows)
print("record-math-ok")
PY
assert test "$?" -eq 0

record_artifacts_before="$(shasum "$RUN/verdicts.jsonl" "$RUN/defects.jsonl" 2>/dev/null || true)"
again=$(WORKER_STATS_DIR="$SD" "$SCRIPT" record run-fixture --verdicts "$VERDICTS") || fail "record dedupe failed"
assert contains "$again" 'recorded 0 rater row(s)'
assert test "$(wc -l <"$SD/reviews.jsonl")" -eq 2
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

python3 - "$SCRIPT" "$FSD" <<'PY'
import importlib.machinery
import importlib.util
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

# --repeat is accepted by every runner and honoured by one, so asking for it elsewhere is refused
# rather than recording a single run as several agreeing ones. The refusal must land before any
# account is consulted: reaching the real worker-pick here would read the live account store.
repeat_refusal=$(WORKER_STATS_DIR="$CSD" CLAUDEB_DIR="$WORK/no-such-store" \
  REVIEW_BENCH_WORKER_PICK_BIN="$WORK/exploding-worker-pick.sh" \
  "$SCRIPT" review "$CSHA" --repo "$CREPO" --tier T0 --repeat 3 2>&1)
assert contains "$repeat_refusal" 'implemented for the OpenCode side only'
assert test "$(printf '%s' "$repeat_refusal" | grep -c 'worker-pick must not run')" -eq 0


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

# A run where every cell errored can never leave `pending`, and calling it that buries the
# runs that genuinely await a verdict.
mkdir -p "$SD/benches/empty-fixture"
python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"run_id":"empty-fixture","commit":"abcdef0123456789","raters":[],"rater_runs":[],"started":"2026-07-20T00:00:00+00:00"}))' \
  "$SD/benches/empty-fixture/meta.json"
empty_listing=$(WORKER_STATS_DIR="$SD" "$SCRIPT" list) || fail "list failed on a rater-less run"
assert contains "$empty_listing" 'every cell errored'
assert test "$(grep -c 'pending' <<<"$empty_listing")" -eq 0


# Every option cmd_run reads must exist on the command line: a flag wired only into the
# code path crashes the whole run at the first cell.
run_help="$("$SCRIPT" run --help 2>&1)"
assert contains "$run_help" "--repeat"
assert contains "$run_help" "--verify"
assert contains "$run_help" "--leg"
review_help="$("$SCRIPT" review --help 2>&1)"
assert contains "$review_help" "--tier"
assert contains "$review_help" "{T0,T1,T2,T3}"
leg_conflict="$("$SCRIPT" run 143fc2f --leg --raters oc-kimik3 2>&1 || true)"
assert contains "$leg_conflict" "not allowed with argument --leg"
oc_table="$(WORKER_STATS_DIR="$SD" CLAUDEB_DIR="$WORK/claudeb-fixture" "$SCRIPT" oc-models 2>&1)"
assert contains "$oc_table" "measured capability"
assert contains "$oc_table" "oc-grok45"
tiers_table="$("$SCRIPT" tiers 2>&1)"
for tier_budget in "T0 (2 min)" "T1 (6 min)" "T2 (10 min)" "T3 (20 min)"; do
  assert contains "$tiers_table" "$tier_budget"
done
for cell in oc-kimik3 oc-grok45-low agy-pro-high-skill agy-flash35-medium-skill \
  sol-low sol-medium agy-flash36-medium-skill opus-medium-skill sol-high \
  opus-high-skill sonnet-medium-skill sol-xhigh sol-max opus-xhigh-skill \
  sonnet-xhigh-skill; do
  assert contains "$tiers_table" "$cell"
done

printf 'PASS: %s assertions; canonical nested review tiers with no retired cell in them, cells retired by measurement refused with their counts, tier CLI and fixture-backed tier execution, fixture diff suggestions across all sizes and escalations, rater grammar (incl. agy and OpenCode families), CLI option surface, worker-pick affordability, gap-driven auto-pick, Codex/Claude normalization, fixture-driven agy and OpenCode fail-closed handling, usage artifacts, resolved-model metadata, SHA-pinned prompt and verifier content, prompt-file transport and max-token fallback, agy sealed clones with no descendant-history leak and /code-review Markdown adaptation, persisted verdict/defect attribution written before the corpus row, re-adjudication replacing the rows of a run instead of silently keeping the old ones, recovered-verdict provenance, a clean-review marker recognised inside Claude and Codex envelopes, the Gemini per-model wall reaching SIDE_WALL from the log, a verifier wall recorded before the gate is released, tiered path resolution with the parent tree as fallback, the repository a run reviewed stamped into the corpus or reported untraceable, cross-run defect reconciliation with severity taken from the members and every incomplete or repository-spanning grouping refused, --repeat refused for the sides that ignore it, the session account usable only behind its opt-in and a per-side account exclusion honoured for pooled and fixed sides alike, the frontier engine scoring one fresh run per named cell with legacy specs normalised and a repeat priced as an independent run, record aggregation/dedupe, unique catches, misses, weighted review score, run listing, 429-detection (fixed), per-side account ordering with Gemini rotation onto a second account after a usage wall, errored-rater exclusion, and cross-side parallelism result assembly\n' "$asserts"
