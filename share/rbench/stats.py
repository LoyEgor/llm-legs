import json
import re
import shlex
import itertools
import math
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path

from . import store as _store
from . import catalog as _catalog
from . import raters as _raters
from . import panel as _panel
from . import prompts as _prompts
from . import report as _report

def commit_defect_rows(sd, commitish):
    """Every run-level canonical defect recorded for one commit, and the repositories seen.

    Runs of the same commit each number their defects from one, so a defect id identifies a
    defect only inside its own run. Comparing two cells that ran in different runs is
    impossible until those per-run lists are reconciled, and this is the whole input the
    reconciliation has to work from.
    """
    repo_by_run = {row["run_id"]: row["repo"] for row in _store.read_jsonl(sd / "reviews.jsonl")
                   if row.get("repo") and row.get("run_id")}
    rows, repos, shas = [], set(), set()
    benches = sd / "benches"
    for path in sorted(benches.iterdir()) if benches.exists() else []:
        meta_path = path / "meta.json"
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text())
        except json.JSONDecodeError:
            continue
        sha = str(meta.get("commit") or "")
        if not sha.startswith(commitish):
            continue
        # A lens run judged this commit by a methodology of its own, so its defects are not
        # part of the canonical list the tool's cells are scored against — and the frontier
        # this list feeds is what decides tier compositions.
        if meta.get("lens"):
            continue
        run_id = meta.get("run_id") or path.name
        # A run of this commit whose adjudication never landed leaves the canonical list
        # incomplete, and an incomplete list is indistinguishable from a complete one later.
        if not (path / "defects.jsonl").exists():
            raise ValueError(
                f"{run_id} reviewed {sha[:7]} and has no defects.jsonl; adjudicate it with "
                "`record` first, or the canonical list will silently omit what it found"
            )
        repo = _store.repo_identity(meta.get("repo")) or repo_by_run.get(run_id)
        # Recorded per matching run rather than per defect: a run that confirmed nothing still
        # says which commit and repository it reviewed, and skipping it is how an ambiguous
        # prefix or a second repository slips past the refusals below.
        shas.add(sha)
        if repo:
            repos.add(repo)
        for defect in _store.read_jsonl(path / "defects.jsonl"):
            rows.append(dict(defect, run_id=run_id))
    return rows, repos, shas


def cmd_cluster(args):
    """Reconcile per-run defect lists for one commit into a single canonical list.

    The grouping decision comes from a judge that read the sealed code, the same way
    `record` takes its verdicts: which run-level defects are the same defect is a judgement
    about code, and text similarity was measured to split one defect into several.
    """
    sd = _store.state_dir()
    defects, repos, shas = commit_defect_rows(sd, args.commit)
    if not defects:
        raise ValueError(f"no adjudicated defects recorded for {args.commit}")
    if len(repos) != 1:
        raise ValueError(
            f"{args.commit} resolves to {len(repos)} repositories ({', '.join(sorted(repos)) or 'none'}); "
            "a commit-level defect list cannot span repositories"
        )
    if len(shas) != 1:
        raise ValueError(f"{args.commit} is ambiguous across {len(shas)} commits: {', '.join(sorted(shas))}")
    repo = repos.pop()
    sha = shas.pop()
    by_id = {defect["defect_id"]: defect for defect in defects}
    if len(by_id) != len(defects):
        raise ValueError("run-level defect ids collide; the runs cannot be reconciled")

    groups = _store.read_jsonl(Path(args.groups))
    placed = {}
    for number, group in enumerate(groups, 1):
        members = group.get("members")
        if not isinstance(members, list) or not members:
            raise ValueError(f"group {number} lists no members")
        if not isinstance(group.get("file"), str) or not group["file"].strip():
            raise ValueError(f"group {number} names no file")
        # Only members that actually cite a file can contradict the group: several early runs
        # left the field empty and put the path in the summary, and an empty citation is not a
        # disagreement — it is the absence of one.
        member_files = {by_id[member].get("file") for member in members if member in by_id}
        member_files = {name for name in member_files if isinstance(name, str) and name.strip()}
        if member_files and group["file"] not in member_files:
            raise ValueError(
                f"group {number} claims {group['file']}, which none of its members cite "
                f"({', '.join(sorted(str(name) for name in member_files))})"
            )
        if not isinstance(group.get("summary"), str) or not group["summary"].strip():
            raise ValueError(f"group {number} has no summary")
        for member in members:
            if member not in by_id:
                raise ValueError(f"group {number} names a defect this commit never recorded: {member}")
            if member in placed:
                raise ValueError(f"{member} is in both group {placed[member]} and group {number}")
            placed[member] = number
    unplaced = sorted(set(by_id) - set(placed))
    if unplaced:
        raise ValueError(f"these defects were left out of every group: {', '.join(unplaced)}")

    rows = []
    for number, group in enumerate(groups, 1):
        members = group["members"]
        catches = sorted(
            ({"run_id": by_id[member]["run_id"], "rater": rater}
             for member in members for rater in by_id[member].get("caught_by", [])),
            key=lambda catch: (catch["run_id"], catch["rater"]),
        )
        # The judge is asked for the most severe reading, and it is taken here rather than
        # trusted: a group whose severity disagrees with its own members is silent bad data.
        severities = [by_id[member].get("severity") for member in members]
        severity = next((name for name in ("P1", "P2", "P3") if name in severities),
                        group.get("severity"))
        rows.append({
            "defect_id": f"{repo}@{sha[:7]}#{number}",
            "repo": repo, "commit": sha,
            "file": group.get("file"), "line": group.get("line"),
            "severity": severity, "summary": group.get("summary"),
            "caught_by": sorted({catch["rater"] for catch in catches}),
            "catches": catches,
            "members": sorted(members),
        })
    target = sd / "defects"
    target.mkdir(parents=True, exist_ok=True)
    path = target / f"{repo}__{sha[:7]}.jsonl"
    _store.write_jsonl(path, rows)
    merged = sum(1 for row in rows if len(row["members"]) > 1)
    print(f"{path}: {len(defects)} run-level defect(s) -> {len(rows)} canonical "
          f"({merged} merged from more than one run)")
    return 0


def frontier_inputs(sd, commits=None):
    """Per-commit canonical defects and per-cell durations, over cells comparable across them.

    A cell that never ran on a commit found nothing there, which is indistinguishable from
    finding nothing — so only cells present on every selected commit may be compared, and the
    rest are reported as excluded rather than silently scored as weak.
    """
    defect_dir = sd / "defects"
    loaded = []
    repositories = defaultdict(set)
    for path in sorted(defect_dir.glob("*.jsonl")) if defect_dir.exists() else []:
        rows = _store.read_jsonl(path)
        if not rows:
            continue
        loaded.append((path, rows))
        for row in rows:
            repositories[str(row.get("repo") or "<unknown>")].add(
                str(row.get("commit") or "")[:7]
            )
    if commits is None and len(repositories) > 1:
        details = "; ".join(
            f"{repo} [{', '.join(sorted(shas))}]" for repo, shas in sorted(repositories.items())
        )
        raise ValueError(
            f"default frontier corpus spans multiple repositories: {details}; pass --commits "
            "to select the intended corpus"
        )
    available, source = {}, {}
    for path, rows in loaded:
        key = rows[0]["commit"][:7]
        # Two repositories sharing a seven-character prefix would otherwise merge into one
        # denominator, and the merge would look exactly like a cell that ran on both.
        if key in available:
            raise ValueError(
                f"{path.name} and {source[key]} both resolve to commit {key}; "
                "name the commits explicitly with --commits to disambiguate"
            )
        available[key], source[key] = rows, path.name
    if commits:
        missing = [commit for commit in commits if commit not in available]
        if missing:
            raise ValueError(
                f"no canonical defect list for {', '.join(missing)}; run `cluster` on them first"
            )
        available = {commit: available[commit] for commit in commits}
    if not available:
        raise ValueError("no canonical defect lists recorded; run `cluster` first")

    ran = defaultdict(set)
    durations = defaultdict(list)
    counted_runs = defaultdict(set)
    # Attempts, not successes. A cell that errored produced no corpus row, so counting rows
    # scores a cell that failed two of three attempts as having found things every time —
    # which is precisely how an unreliable cell would look strongest.
    run_counts = Counter()
    errors = Counter()
    benches = sd / "benches"
    for path in sorted(benches.iterdir()) if benches.exists() else []:
        meta_path = path / "meta.json"
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text())
        except json.JSONDecodeError as exc:
            # Skipping it silently removes attempts from the denominator while their catches
            # stay in the numerator, which is how a rate of 900% and a negative coverage arise.
            raise ValueError(f"{meta_path} is unreadable ({exc.msg}); repair or remove that run")
        commit = str(meta.get("commit") or "")[:7]
        if commit not in available:
            continue
        # Cluster leaves a lens run out of the canonical defects, so counting its attempts
        # here would put a denominator under a numerator that can never exist.
        if meta.get("lens"):
            continue
        run_id = meta.get("run_id") or path.name
        # `raters` holds the cells that answered; `rater_runs` holds every attempt, errored ones
        # included. An attempt that failed found nothing, which is the outcome a composition
        # actually delivers, so it belongs in the denominator — but an in-run retry is ONE
        # delivery, so the cell is read at its last row and priced at what the whole chain cost.
        rows, superseded = _panel.cell_attempt_rows(
            [row for row in meta.get("rater_runs", ()) if isinstance(row, dict)]
        )
        for entry in rows:
            rater = entry.get("rater")
            if not rater:
                continue
            attempts = superseded.get(rater) or ()
            # Two specs in one run may normalise to the same cell, so an attempt is identified
            # by the name it ran under: collapsing them would count two attempts and one catch.
            counted_runs[commit].add((run_id, rater))
            rater = _raters.normalize_legacy_rater(rater)
            ran[commit].add(rater)
            run_counts[(commit, rater)] += 1
            if entry.get("errored"):
                errors[(commit, rater)] += 1
            chain_ms = _report.report_ms(entry.get("duration_ms")) + sum(
                _report.report_ms(row.get("duration_ms")) for row in attempts
            )
            if chain_ms:
                durations[rater].append(chain_ms / 60000)
    comparable = set.intersection(*ran.values()) if ran else set()
    comparable = {rater for rater in comparable if durations.get(rater)}
    excluded = sorted(set().union(*ran.values()) - comparable) if ran else []
    minutes = {rater: statistics.median(durations[rater]) for rater in comparable}
    return (available, sorted(comparable), minutes, excluded, dict(run_counts),
            dict(errors), {key: set(value) for key, value in counted_runs.items()})


def hit_rates(defects_by_commit, run_counts, counted_runs=None):
    """Per defect and cell, the share of that cell's runs on that commit which found it.

    The union of everything a cell ever found is not what one run of it finds, and cells in
    this corpus were run between five and fifteen times: scoring them by that union ranks a
    cheap cell that ran fifteen times above a strong one that ran five. A rate is what
    survives the difference in how often each cell happened to be sampled.
    """
    rates = {}
    for commit, rows in defects_by_commit.items():
        for row in rows:
            attempted = counted_runs.get(commit) if counted_runs is not None else None
            runs_with = defaultdict(set)
            for catch in row.get("catches", ()):
                key = (catch["run_id"], catch["rater"])
                # Only catches from attempts the denominator counted: one from a run the
                # denominator never saw is a numerator without a denominator, and the rate it
                # produces can exceed one and drive coverage negative.
                if attempted is not None and key not in attempted:
                    continue
                # The corpus counts runs under the current rater name, and `catches` preserves
                # whatever name the run recorded: an unnormalised key misses its denominator
                # and silently drops that cell's catch instead of crediting it.
                runs_with[_raters.normalize_legacy_rater(catch["rater"])].add(key)
            rates[row["defect_id"]] = {
                rater: len(found) / run_counts[(commit, rater)]
                for rater, found in runs_with.items()
                if run_counts.get((commit, rater))
            }
    return rates


def composition_coverage(defects_by_commit, rates, cells):
    """Defects the composition is expected to find, counting one fresh run per named cell.

    A cell named twice is two independent runs of it, which is the only honest way to price
    "run this one again" against "add a different one".
    """
    counted = Counter(cells)
    expected = total = 0.0
    for rows in defects_by_commit.values():
        for row in rows:
            total += 1
            missed = 1.0
            per_defect = rates.get(row["defect_id"], {})
            for cell, times in counted.items():
                missed *= (1 - per_defect.get(cell, 0.0)) ** times
            expected += 1 - missed
    return expected, total


EXHAUSTIVE_COMPOSITIONS = 200_000


def best_composition(defects_by_commit, rates, cells, minutes, budget, limit):
    """The best composition that fits the budget, and whether it is proven best.

    Cells run at once, so a composition costs the slowest of them, and a cell may be named more
    than once: running one twice competes with adding another on equal terms. Every multiset is
    enumerated while that is cheap; beyond that greedy plus single swaps returns a lower bound,
    and the caller is told which of the two it got — greedy demonstrably misses combinations
    that only pay off together, so reporting its answer as the optimum would be a lie.

    Returns (composition, coverage, proven).
    """
    affordable = sorted(cell for cell in cells if minutes[cell] <= budget)
    if not affordable:
        return [], 0.0, True
    defect_count = sum(len(rows) for rows in defects_by_commit.values()) or 1
    total_multisets = math.comb(len(affordable) + limit, limit) if limit else 1
    # Each candidate is scored against every defect, so the count alone understates the work.
    if total_multisets * defect_count <= EXHAUSTIVE_COMPOSITIONS:
        best = ([], 0.0)
        for size in range(1, limit + 1):
            for candidate in itertools.combinations_with_replacement(affordable, size):
                found, _ = composition_coverage(defects_by_commit, rates, candidate)
                if found > best[1] + 1e-9:
                    best = (sorted(candidate), found)
        return best[0], best[1], True
    chosen = []
    covered = 0.0
    while len(chosen) < limit:
        best = None
        for cell in affordable:
            found, _ = composition_coverage(defects_by_commit, rates, chosen + [cell])
            if found > covered + 1e-9 and (best is None or found > best[0]):
                best = (found, cell)
        if not best:
            break
        covered, cell = best
        chosen.append(cell)
    improved = True
    while improved:
        improved = False
        for index in range(len(chosen)):
            for cell in affordable:
                candidate = list(chosen)
                if candidate[index] == cell:
                    continue
                candidate[index] = cell
                found, _ = composition_coverage(defects_by_commit, rates, candidate)
                if found > covered + 1e-9:
                    chosen, covered, improved = candidate, found, True
                    break
            if improved:
                break
    return sorted(chosen), covered, False


def cmd_frontier(args):
    commits = [part.strip() for part in args.commits.split(",") if part.strip()] if args.commits else None
    budgets = [float(part) for part in args.budgets.split(",") if part.strip()]
    sd = _store.state_dir()
    (defects_by_commit, cells, minutes, excluded, run_counts, errors,
     counted_runs) = frontier_inputs(sd, commits)
    rates = hit_rates(defects_by_commit, run_counts, counted_runs)
    total = sum(len(rows) for rows in defects_by_commit.values())
    print(f"commits: {', '.join(sorted(defects_by_commit))} ({total} canonical defect(s))")
    print(f"comparable cells: {len(cells)}; coverage is what one fresh run of each is expected to find")
    if excluded:
        print(f"excluded (did not run on every commit): {len(excluded)} cell(s)")
    print()
    for budget in budgets:
        chosen, covered, proven = best_composition(
            defects_by_commit, rates, cells, minutes, budget, args.max_cells
        )
        if not chosen:
            fits = [cell for cell in cells if minutes[cell] <= budget]
            reason = ("no cell finishes this fast" if not fits
                      else f"{len(fits)} cell(s) fit, and none of them found anything")
            print(f"{budget:g} min: {reason}")
            continue
        slowest = max(minutes[cell] for cell in chosen)
        quality = "best" if proven else "best found (not proven optimal)"
        print(f"{budget:g} min: {covered:.1f}/{total} ({covered / total * 100:.0f}%) "
              f"in {slowest:.1f} min with {len(chosen)} run(s) — {quality}")
        for cell, times in sorted(Counter(chosen).items()):
            alone, _ = composition_coverage(defects_by_commit, rates, [cell])
            label = f"{cell} x{times}" if times > 1 else cell
            attempts = sum(count for (_, rater), count in run_counts.items() if rater == cell)
            failed = sum(count for (_, rater), count in errors.items() if rater == cell)
            flaky = f"  errored {failed}/{attempts}" if failed else ""
            print(f"    {label:30s} {minutes[cell]:5.1f} min  one run finds {alone:5.1f}{flaky}")
    return 0


def opencode_health():
    """Per-model success rate and latency from every recorded bench run.

    The point is that the tool's knowledge of a flaky gateway stays measured: a model
    that starts failing shows up here without anyone editing a table.
    """
    health = {}
    benches = _store.state_dir() / "benches"
    if not benches.exists():
        return health
    for path in sorted(benches.iterdir()):
        meta_path = path / "meta.json"
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text())
        except json.JSONDecodeError:
            continue
        rows, superseded = _panel.cell_attempt_rows(
            [row for row in meta.get("rater_runs", ()) if isinstance(row, dict)]
        )
        for row in rows:
            if row.get("side") != "opencode":
                continue
            # Keyed by cell, not model: the whole point is that the configuration
            # decides whether a model works, so folding grok45 and grok45-low
            # together would hide exactly the effect worth watching.
            rater = _raters.normalize_legacy_rater(row.get("rater") or "")
            entry = health.setdefault(rater, {
                "runs": 0, "errors": 0, "seconds": [], "findings": [], "last_error": "",
            })
            entry["runs"] += 1
            if row.get("errored"):
                entry["errors"] += 1
                detail = " ".join((row.get("stderr") or "").split())
                entry["last_error"] = f"{meta.get('run_id', '?')}: {detail[-90:]}"
            else:
                duration_ms = _report.report_ms(row.get("duration_ms")) + sum(
                    _report.report_ms(attempt.get("duration_ms"))
                    for attempt in superseded.get(row.get("rater"), ())
                )
                if duration_ms:
                    entry["seconds"].append(round(duration_ms / 1000))
                entry["findings"].append(row.get("findings") or 0)
    return health


def cmd_oc_models(args):
    health = opencode_health()
    print(f"recommended leg: --raters {shlex.quote(','.join(_catalog.OPENCODE_REVIEW_LEG))}")
    print("  proven on 143fc2f, fabcae4, 8448a35 and 8553616; one pass is a dice roll, so"
          " three passes union ~1.7x the true findings of one")
    print("  run the leg BARE: on 143fc2f the bare cells found 8 distinct real defects against"
          " 6 with the google profile and 1 with anthropic, which also broke grok-4.5 in 2 of 3 passes")
    print("\nmeasured capability (probe 2026-07-25, n=2 per mode; see docs/DIAGNOSTICS.md)")
    print(f"{'cell':16} {'model':18} {'reasoning-off':>13} {'effort scales':>13} "
          f"{'review s':>9}  note")
    for model, facts in sorted(_catalog.OPENCODE_MODEL_FACTS.items()):
        seconds = facts.get("off_s") or facts.get("low_s")
        print(f"{model:16} {_catalog.OPENCODE_MODEL_IDS[model]:18} "
              f"{('works' if facts['off'] else 'IGNORED'):>13} "
              f"{('yes' if facts['scales'] else 'no'):>13} "
              f"{(str(seconds) if seconds else '?'):>9}  {facts['note']}")
    print("\nplan models screened once and not adopted as cells (no true finding each)")
    for model, note in sorted(_catalog.OPENCODE_SCREENED_MODELS.items()):
        print(f"{'':16} {model:18} {note}")
    print("\nrecorded health (every bench run in this state dir)")
    if not health:
        print("  no recorded OpenCode runs yet")
        return 0
    print(f"{'cell':22} {'runs':>4} {'failed':>6} {'median s':>8} {'median findings':>15}  "
          f"last failure")
    for model, entry in sorted(health.items(), key=lambda kv: -kv[1]["errors"]):
        print(f"{model:22} {entry['runs']:>4} {entry['errors']:>6} "
              f"{str(_store.median(entry['seconds']) or '-'):>8} "
              f"{str(_store.median(entry['findings']) if entry['findings'] else '-'):>15}  "
              f"{entry['last_error'][:70]}")
    return 0


BOARD_REPEAT_RE = re.compile(r"#\d+$")
BOARD_TIER_ORDER = (*_catalog.REVIEW_TIERS, "OVER", "?")
BOARD_COLUMNS = (
    "cell", "runs/cmt", "raw+", "anch", "catch", "hit%", "medFP", "medWall", "cov*",
    "ktok", "out-ktok", "cost", "value",
)
# Under either of these a cell's coverage is one panel's opinion, which is the same artifact
# anchoring was introduced to kill, one step further in.
BOARD_MIN_ANCHORED_RUNS = 3
BOARD_MIN_ANCHORED_DEFECTS = 5
BOARD_EMPTY = "·"
BOARD_FOOTER = (
    "cov* is anchored-only coverage; solo/family-only runs are excluded from it by design "
    "(docs/research/opencode-raters-2026-08.md §26b), and a trailing ? marks a cell scored on "
    f"fewer than {BOARD_MIN_ANCHORED_RUNS} anchored runs or "
    f"{BOARD_MIN_ANCHORED_DEFECTS} anchored defects",
    "cost is two units that do NOT compare: an OpenCode cell is priced as its share of the Go "
    "plan's 5h request grant, every other cell as an API-price proxy over its mean tokens "
    "relative to its OWN vendor's cheapest tier, so value (cov*/cost) ranks a priced cell only "
    "against cells of the same vendor",
    "raw+ is bench runs of that cell nobody adjudicated, counted only over benches that "
    "finished, so they are in no other column here; a row that is "
    f"{BOARD_EMPTY} everywhere else is a cell only raw runs have ever measured",
)
HANDSCORED_SOURCE = "docs/research/opencode-raters-2026-08.md"
HANDSCORED_COLUMNS = ("cell", "runs", "catch", "FP", "wall", "note", "source")
# Paths measured by hand and never recorded as corpus runs. They are the only evidence these
# models were tried at all, and every one of them is a decision the board would otherwise invite
# an owner to take twice.
HANDSCORED = (
    {"cell": "gpt-5.6-luna chat", "runs": "11", "catch": "2", "fp": "0", "wall": "29s med",
     "note": "hardcoded effort medium via /chat/completions"},
    {"cell": "gpt-5.6-luna /responses high", "runs": "3", "catch": "2", "fp": "0", "wall": "186s",
     "note": "needs a /responses client in bin/opencode-go"},
    {"cell": "qwen3.8-max medium", "runs": "2", "catch": "0-2", "fp": "0", "wall": "483-503s",
     "note": "manual 2026-08-11 on pinned commits; verdict: not a reviewer"},
    {"cell": "oc-kimik3 medium (manual)", "runs": "", "catch": "3", "fp": "0", "wall": "158-223s",
     "note": "3 catches on 143fc2f, but 22.6-28.6 min on a 2462-line diff; viable only behind a "
             "diff-size gate"},
    {"cell": "oc-dsv4flash low (manual)", "runs": "", "catch": "<=1", "fp": "", "wall": "70-108s",
     "note": "loses to its own free reasoning-off cell"},
)


def board_cell_name(rater):
    return BOARD_REPEAT_RE.sub("", rater or "")


def board_usage(sd, run_id, rater):
    path = sd / "benches" / str(run_id) / f"usage-{rater}.json"
    try:
        usage = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(usage, dict):
        return None
    # Two vendor spellings of one number reach this store — the Go gateway writes the OpenAI
    # names, the Anthropic-shaped legs write theirs — so a column keyed on either alone reads
    # as "no output tokens" for half the board.
    output = usage.get("output_tokens")
    if output is None:
        output = usage.get("completion_tokens")
    return usage.get("total_tokens"), output


def board_price_weight(model):
    for weights in _catalog.PRICE_WEIGHTS.values():
        if model in weights:
            return weights[model]
    if model.startswith("agy-flash"):
        return _catalog.PRICE_WEIGHTS["google"]["flash"]
    if model == "agy-pro":
        return _catalog.PRICE_WEIGHTS["google"]["pro"]
    return None


def board_cost(cell, model, mean_total_tokens):
    if cell.startswith("oc-"):
        plan_model = _catalog.OPENCODE_MODEL_IDS.get(model)
        granted = _catalog.GO_REQUESTS_5H.get(plan_model)
        if not granted:
            return None, None
        return (_catalog.BOARD_COST_SCALE / (granted / _catalog.GO_USAGE_WEIGHT.get(plan_model, 1)),
                "go-request")
    weight = board_price_weight(model)
    if weight is None or mean_total_tokens is None:
        return None, None
    return weight * mean_total_tokens / 1e6, "price-proxy"


def board_raw_name(rater, known):
    name = board_cell_name(rater)
    if name in known:
        return name
    return board_cell_name(_raters.normalize_legacy_rater(rater))


def board_raw_counts(sd, known):
    """Bench runs that no corpus row ever adjudicated, per cell.

    A rater a run launched is in `rater_runs` whether or not anyone judged it later, so the gap
    against the corpus is the measured-but-unscored volume — the only column here that says how
    much evidence is sitting unused. A run still in flight has a meta.json too, and counting it
    would sell work in progress as evidence, so the same finish stamp `list` reads to tell an
    aborted run from a real one gates this. A cell its run recorded as errored measured nothing
    either, and counting it would sell a failure as evidence waiting to be read.
    """
    adjudicated = {
        (row.get("run_id"), row.get("rater")) for row in _store.read_jsonl(sd / "reviews.jsonl")
    }
    counts = Counter()
    benches = sd / "benches"
    for path in sorted(benches.iterdir()) if benches.exists() else ():
        try:
            meta = json.loads((path / "meta.json").read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if _store.parse_iso_timestamp(meta.get("finished") or meta.get("finished_at")) is None:
            continue
        run_id = meta.get("run_id") or path.name
        for entry in meta.get("rater_runs", []):
            if entry.get("errored"):
                continue
            rater = entry.get("rater") or ""
            if (run_id, rater) not in adjudicated:
                counts[board_raw_name(rater, known)] += 1
    return counts


BOARD_LEGS = {"opencode": "opencode", "claude": "claude", "codex": "openai", "agy": "gemini"}


def board_leg(cell):
    # A cell retired since its runs were written no longer parses, and the rest of the board
    # still bills it by its prefix — the cost column and the family filters both read that.
    if cell.startswith("oc-"):
        return "opencode"
    try:
        return BOARD_LEGS[_raters.parse_rater(cell)["side"]]
    except (ValueError, KeyError):
        return "other"


@lru_cache(maxsize=None)
def board_panel_cells():
    """Every cell some tier's default panel launches today, keyed the way the corpus keys one.

    Membership belongs to the pool, not to a row's measured wall clock: a cell whose only runs
    are unadjudicated is in the panel it is in, and bucketing it by tier first hides that.
    """
    return frozenset(
        board_cell_name(rater["spec"])
        for tier in _catalog.REVIEW_TIERS.values()
        for cell in tier["cells"]
        for rater in _raters.parse_raters(cell)
    )


def board_parses(cell):
    try:
        _raters.parse_rater(cell)
    except ValueError:
        return False
    return True


def board_scheme(rows):
    """One naming scheme over every cell the board prints, read the way a report reads its own:
    the pool spells itself, and a cell no tier can launch is named against it. Under the pool
    alone three retired efforts of one family all answer to the family's name.
    """
    return _raters.report_name_scheme(sorted(row["cell"] for row in rows))


def board_tiers_block(scheme):
    blocks = {}
    for name, tier in _catalog.REVIEW_TIERS.items():
        panel = []
        for cell in tier["cells"]:
            for rater in _raters.parse_raters(cell):
                key = board_cell_name(rater["spec"])
                if key not in panel:
                    panel.append(key)
        blocks[name] = {
            "budget_min": tier["budget_min"],
            "panel": [_raters.human_cell_name(key, scheme) for key in panel],
        }
    return blocks


def board_constants():
    """Every number the board's own renderers would otherwise each spell for themselves."""
    return {
        "price_weights": _catalog.PRICE_WEIGHTS,
        "go_requests_5h": _catalog.GO_REQUESTS_5H,
        "go_usage_weight": _catalog.GO_USAGE_WEIGHT,
        "cost_scale": _catalog.BOARD_COST_SCALE,
        "min_anchored_runs": BOARD_MIN_ANCHORED_RUNS,
        "min_anchored_defects": BOARD_MIN_ANCHORED_DEFECTS,
    }


def board_tier(wall_s):
    if wall_s is None:
        return "?"
    for tier_name, tier in _catalog.REVIEW_TIERS.items():
        if wall_s <= tier["budget_min"] * 60:
            return tier_name
    return "OVER"


def board_cells(sd):
    """Per-cell comparison rows over the whole corpus, coverage counted on anchored runs only.

    A run's `misses` are adjudicated against that run's own panel, so a cell that ran solo or
    beside its own family alone is scored against nothing but its own catches. Only a panel
    holding another model that is not an OpenCode cell makes the coverage of the runs in it
    comparable with anything (docs/research/opencode-raters-2026-08.md §26b).
    """
    by_run = defaultdict(list)
    for row in _store.read_jsonl(sd / "reviews.jsonl"):
        by_run[row.get("run_id")].append(row)
    cells = {}
    for run_id, run_rows in by_run.items():
        for row in run_rows:
            rater = row.get("rater") or ""
            # The same normalization the raw counts key on: under two spellings of one cell the
            # legacy one parses as no side at all, so the row splits off with leg "other".
            name = board_cell_name(_raters.normalize_legacy_rater(rater))
            model = row.get("rater_model") or ""
            entry = cells.setdefault(name, {
                "cell": name, "models": Counter(), "commits": set(), "confirmed": [],
                "false_positive": [], "wall_s": [], "n_anchored": 0,
                "anchored_confirmed": 0, "anchored_misses": 0, "total_tokens": [],
                "output_tokens": [],
            })
            entry["models"][model] += 1
            if row.get("commit"):
                entry["commits"].add(row["commit"])
            entry["confirmed"].append(row.get("confirmed") or 0)
            entry["false_positive"].append(row.get("false_positive") or 0)
            if row.get("duration_ms"):
                entry["wall_s"].append(row["duration_ms"] / 1000)
            if any(
                board_cell_name(other.get("rater")) != name
                and (other.get("rater_model") or "") != model
                and not (other.get("rater") or "").startswith("oc-")
                for other in run_rows
            ):
                entry["n_anchored"] += 1
                entry["anchored_confirmed"] += row.get("confirmed") or 0
                entry["anchored_misses"] += row.get("misses") or 0
            usage = board_usage(sd, run_id, rater)
            if usage:
                if usage[0] is not None:
                    entry["total_tokens"].append(usage[0])
                if usage[1] is not None:
                    entry["output_tokens"].append(usage[1])
    raw_counts = board_raw_counts(sd, set(cells))
    rows = [board_row(entry, raw_counts[name]) for name, entry in cells.items()]
    rows.extend(board_raw_row(name, count) for name, count in raw_counts.items()
                if name not in cells)
    scheme = board_scheme(rows)
    panel = board_panel_cells()
    taken = set()
    # A spec no side parses any more is named off its family alone, which can land on the name of
    # a cell that still runs. The board answers that the way the scheme itself does — with the
    # machine key, unambiguous by construction — and never at the live cell's expense.
    for row in sorted(rows, key=lambda row: (not board_parses(row["cell"]), row["cell"])):
        display = _raters.human_cell_name(row["cell"], scheme)
        row["display"] = row["cell"] if display in taken else display
        taken.add(row["display"])
        row["leg"] = board_leg(row["cell"])
        row["in_panel"] = row["cell"] in panel
    return rows


def board_raw_row(name, n_raw):
    """A cell only unadjudicated bench runs have ever measured.

    Every corpus-derived key is None rather than absent, so nothing downstream has to special-case
    the shape of the row that says unscored evidence exists.
    """
    return {
        "cell": name,
        "model": None, "n_runs": None, "n_commits": None, "n_raw": n_raw,
        "n_anchored": None, "med_confirmed": None, "mean_confirmed": None, "hit_pct": None,
        "med_false_positive": None, "med_wall_s": None, "tier": board_tier(None),
        "cov_anch": None, "anchored_denominator": None, "low_evidence": True,
        "mean_total_tokens": None, "mean_output_tokens": None, "cost_units": None,
        "cost_unit": None, "value": None,
    }


def board_row(entry, n_raw):
    confirmed = entry["confirmed"]
    wall_s = statistics.median(entry["wall_s"]) if entry["wall_s"] else None
    tier = board_tier(wall_s)
    denominator = entry["anchored_confirmed"] + entry["anchored_misses"]
    model = entry["models"].most_common(1)[0][0]
    mean_total_tokens = (statistics.fmean(entry["total_tokens"])
                         if entry["total_tokens"] else None)
    cost_units, cost_unit = board_cost(entry["cell"], model, mean_total_tokens)
    row = {
        "cell": entry["cell"],
        "model": model,
        "n_runs": len(confirmed),
        "n_commits": len(entry["commits"]),
        "n_raw": n_raw,
        "n_anchored": entry["n_anchored"],
        "med_confirmed": statistics.median(confirmed),
        "mean_confirmed": statistics.fmean(confirmed),
        "hit_pct": 100 * sum(1 for value in confirmed if value > 0) / len(confirmed),
        "med_false_positive": statistics.median(entry["false_positive"]),
        "med_wall_s": wall_s,
        "tier": tier,
        "cov_anch": 100 * entry["anchored_confirmed"] / denominator if denominator else None,
        "anchored_denominator": denominator,
        "low_evidence": (entry["n_anchored"] < BOARD_MIN_ANCHORED_RUNS
                         or denominator < BOARD_MIN_ANCHORED_DEFECTS),
        "mean_total_tokens": mean_total_tokens,
        "mean_output_tokens": statistics.fmean(entry["output_tokens"])
                              if entry["output_tokens"] else None,
        "cost_units": cost_units,
        "cost_unit": cost_unit,
    }
    row["value"] = (row["cov_anch"] / cost_units
                    if row["cov_anch"] is not None and cost_units else None)
    return row


def board_sort_key(row):
    # Raw-only rows are equal under every corpus key, and an unordered block of them reshuffles
    # between runs of the same board.
    return (row["cov_anch"] is None, -(row["cov_anch"] or 0), -(row["mean_confirmed"] or 0),
            -(row["n_raw"] or 0), row["cell"])


def board_values(row):
    def number(value, spec, scale=1):
        return format(value / scale, spec) if value is not None else ""

    if row["n_runs"] is None:
        return [row["display"], BOARD_EMPTY, str(row["n_raw"]),
                *[BOARD_EMPTY] * (len(BOARD_COLUMNS) - 3)]
    coverage = number(row["cov_anch"], ".1f")
    if coverage and row["low_evidence"]:
        coverage += "?"
    return [
        row["display"],
        f"{row['n_runs']}/{row['n_commits']}",
        str(row["n_raw"]),
        str(row["n_anchored"]),
        f"{row['med_confirmed']:g}/{row['mean_confirmed']:.1f}",
        f"{row['hit_pct']:.0f}",
        f"{row['med_false_positive']:g}",
        number(row["med_wall_s"], ".0f"),
        coverage,
        number(row["mean_total_tokens"], ".0f", 1000),
        number(row["mean_output_tokens"], ".1f", 1000),
        number(row["cost_units"], ".2f"),
        number(row["value"], ".1f"),
    ]


def board_lines(rows):
    rendered = {tier: [] for tier in BOARD_TIER_ORDER}
    for row in sorted(rows, key=board_sort_key):
        rendered[row["tier"]].append(board_values(row))
    printable = [values for tier in BOARD_TIER_ORDER for values in rendered[tier]]
    widths = [
        max(len(header), *(len(values[index]) for values in printable))
        for index, header in enumerate(BOARD_COLUMNS)
    ]

    def line(values):
        return "  ".join(
            value.ljust(widths[index]) if index == 0 else value.rjust(widths[index])
            for index, value in enumerate(values)
        ).rstrip()

    lines = []
    for tier in BOARD_TIER_ORDER:
        if not rendered[tier]:
            continue
        budget = _catalog.REVIEW_TIERS.get(tier)
        label = f"{tier} (<= {budget['budget_min']} min)" if budget else {
            "OVER": "OVER (past every tier budget)", "?": "? (no recorded wall clock)",
        }[tier]
        lines.extend(["", label, line(BOARD_COLUMNS), "  ".join("-" * width for width in widths)])
        lines.extend(line(values) for values in rendered[tier])
    lines.append("")
    lines.extend(BOARD_FOOTER)
    return lines


def handscored_values(row):
    return [row["cell"], row["runs"], row["catch"], row["fp"], row["wall"], row["note"],
            HANDSCORED_SOURCE]


def handscored_lines():
    rows = [handscored_values(row) for row in HANDSCORED]
    # Only the fixed-width head is padded: the note is a sentence, and padding every row out to
    # the longest one turns a five-row block into a wall.
    head = len(HANDSCORED_COLUMNS) - 2
    widths = [
        max(len(header), *(len(values[index]) for values in rows))
        for index, header in enumerate(HANDSCORED_COLUMNS[:head])
    ]
    lines = ["", "hand-scored (out of corpus)"]
    for values in (list(HANDSCORED_COLUMNS), *rows):
        padded = [
            value.ljust(widths[index]) if index == 0 else value.rjust(widths[index])
            for index, value in enumerate(values[:head])
        ]
        lines.append("  ".join((*padded, *values[head:])).rstrip())
    return lines


def cmd_board(args):
    rows = board_cells(_store.state_dir())
    # Built before any filter: a name is a property of the whole board, not of the slice asked for.
    scheme = board_scheme(rows)
    if args.tier:
        rows = [row for row in rows if row["tier"] == args.tier]
    if args.no_oc:
        rows = [row for row in rows if not row["cell"].startswith("oc-")]
    if args.oc_only:
        rows = [row for row in rows if row["cell"].startswith("oc-")]
    rows = sorted(rows, key=board_sort_key)
    hand = [dict(row, source=HANDSCORED_SOURCE) for row in HANDSCORED]
    if args.json:
        document = {"cells": rows, "hand_scored": hand, "tiers": board_tiers_block(scheme),
                    "constants": board_constants()}
        print(json.dumps(document if args.hand else rows, indent=2))
        return 0
    if args.tsv:
        # The raw corpus key, not the display name: this format is read by machines, and the key
        # is the only spelling guaranteed unique and stable across a naming-scheme change.
        print("\t".join(("tier", *BOARD_COLUMNS)))
        for row in rows:
            # The dim placeholder is a reading aid; a machine reader takes it for a value.
            values = ["" if value == BOARD_EMPTY else value for value in board_values(row)[1:]]
            print("\t".join((row["tier"], row["cell"], *values)))
        if args.hand:
            print()
            print("\t".join(HANDSCORED_COLUMNS))
            for row in HANDSCORED:
                print("\t".join(handscored_values(row)))
        return 0
    for text in (board_lines(rows) if rows else ["no recorded runs match"]):
        print(text)
    for text in handscored_lines():
        print(text)
    return 0


def cmd_list(args):
    benches = _store.state_dir() / "benches"
    reviews = _store.read_jsonl(_store.state_dir() / "reviews.jsonl")
    recorded = Counter(row.get("run_id") for row in reviews)
    entries = []
    if benches.exists():
        for path in benches.iterdir():
            meta_path = path / "meta.json"
            if not meta_path.exists():
                continue
            try:
                meta = json.loads(meta_path.read_text())
            except json.JSONDecodeError:
                continue
            entries.append((meta, path))
    entries.sort(
        key=lambda item: (
            _store.parse_iso_timestamp(item[0].get("started") or item[0].get("started_at"))
            or datetime.min.replace(tzinfo=timezone.utc),
            item[1].name,
        ),
        reverse=True,
    )
    if not entries:
        print("no benchmark runs")
        return 0
    print(f"{'run id':<33} {'commit':<10} {'raters':>6} {'adjudicated':>12}  status")
    for meta, run_dir in entries[: args.limit]:
        total = len(_panel.completed_raters_from_meta(meta))
        if meta.get("worktree") is True and (run_dir / "verdicts.jsonl").exists():
            done = total
        else:
            done = min(recorded[meta.get("run_id")], total)
        # A run where every cell errored has nothing to adjudicate and can never leave
        # `pending`, so calling it that buries the runs that genuinely await a verdict.
        if _store.parse_iso_timestamp(meta.get("finished") or meta.get("finished_at")) is None:
            status = "aborted"
        elif not total:
            status = "no raters (every cell errored)"
        else:
            status = "adjudicated" if done == total else "pending"
        print(f"{meta.get('run_id', '?'):<33} {meta.get('commit', '?')[:9]:<10} "
              f"{total:>6} {f'{done}/{total}':>12}  {status}")
    return 0


def lens_list_lines():
    lenses = _prompts.load_lenses()
    if not lenses:
        return [f"no lenses registered in {_prompts.lens_dir()}"]
    lines = []
    for name, lens in sorted(lenses.items()):
        lines.append(
            f"{name:<20} {lens['path']}  repeats={lens['repeats'] or 'tier'}  "
            f"{_prompts.lens_source_status(lens)}"
        )
        # The listing is how a model that never heard of a lens decides whether to take it, so
        # a lens that does not say when is named here rather than skipped.
        lines.append(f"  when: {lens['when'] or '(not recorded — the lens file should say)'}")
    return lines


def lens_check_lines(slug, lens=None):
    lens = lens or _prompts.resolve_lens(slug)
    path = _prompts.lens_source_path(lens)
    current = (_prompts.lens_source_digest(path) or "") if path else ""
    lines = [f"{lens['name']}  {lens['path']}"]
    lines.append(f"  when:     {lens['when'] or '(not recorded — the lens file should say)'}")
    if lens["aliases"]:
        lines.append(f"  aliases:  {', '.join(lens['aliases'])}")
    lines.append(f"  source:   {path or '(none recorded)'}")
    lines.append(f"  recorded: {lens['source_hash'] or '(none recorded)'}")
    lines.append(f"  current:  {current or '(unreadable)'}")
    lines.append(f"  status:   {_prompts.lens_source_status(lens)}")
    return lines


def cmd_lens(args):
    if args.action != "check":
        for line in lens_list_lines():
            print(line)
        return 0
    if not args.slug:
        raise ValueError("review-bench lens check needs a lens slug")
    lens = _prompts.resolve_lens(args.slug)
    for line in lens_check_lines(args.slug, lens):
        print(line)
    # Enforced here and not in `read_lens`, which every reader of an already-registered lens goes
    # through: a run mid-flight must not die over prose, while the check that registers one is
    # exactly where a lens nobody can tell when to take has to fail.
    if not lens["when"]:
        print(
            "  FAILED: no `when:` in the frontmatter — a lens whose file does not say when to "
            "take it is one nobody takes."
        )
        return 1
    return 0


