# TEMP-HAIKU-TRIAL(report): the whole file; EXPERIMENTS.json entry `haiku-review-cells` removes it.
"""One line per fit, legacy or speed review round of a night that staffed a Haiku cell, printed by `night-run report`:
the judge's state, panel findings, judge-confirmed, confirmed/found per cell family, and the round's fixes (fixed rows of
its fixer runs, those on Haiku findings) that landed and were reverted or never landed.

A fixer row's `finding` is the position of its judge row in the round's verdicts.jsonl, not a rater's idx.
"""

import calendar
import collections
import glob
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import night_spend  # noqa: E402
import sonnet_trial  # noqa: E402
from spend import read_json  # noqa: E402

LENS = re.compile(r"^(fit|legacy(-.*)?|speed)$")


def family(spec):
    return str(spec).split("#")[0]


def is_haiku(spec):
    return family(spec).startswith("haiku")


def round_cells(meta):
    specs = [r.get("spec") for r in meta.get("panel_raters") or () if isinstance(r, dict)]
    return [s for s in specs + list(meta.get("completed_raters") or ()) if isinstance(s, str)]


def night_rounds(started, finished):
    for bench in sorted(glob.glob(f"{night_spend.BENCHES}/*")):
        try:
            began = calendar.timegm(time.strptime(os.path.basename(bench)[:16], "%Y%m%dT%H%M%SZ"))
        except ValueError:
            continue
        if not started <= began <= finished:
            continue
        meta = read_json(f"{bench}/meta.json", {})
        if isinstance(meta, dict) and LENS.match(str(meta.get("lens") or "")) and any(map(is_haiku, round_cells(meta))):
            yield bench, meta


def fixer_runs(round_id, started):
    for directory in glob.glob(f"{night_spend.RUNS}/*-*"):
        parts = os.path.basename(directory).split("-")
        if len(parts) > 1 and parts[1].isdigit() and int(parts[1]) >= started - 86400:
            meta = read_json(f"{directory}/meta.json", {})
            if isinstance(meta, dict) and meta.get("review_round") == round_id:
                yield directory, meta, int(parts[1])


def round_line(bench, meta, started):
    judge = meta.get("judge") if isinstance(meta.get("judge"), dict) else {}
    state = judge.get("state") or "none"
    found, confirmed = collections.Counter(), collections.Counter()
    cells = sorted({family(s) for s in round_cells(meta)}, key=lambda f: (not is_haiku(f), f))
    for spec in set(round_cells(meta)):
        found[family(spec)] += sum(1 for _ in night_spend.rows(f"{bench}/findings-{spec}.jsonl"))
    judged = [r for r in night_spend.rows(f"{bench}/verdicts.jsonl")
              if r.get("kind") != "fixer" and r.get("rater") and r.get("verdict")]
    for row in judged:
        if row["verdict"] == "confirmed":
            confirmed[family(row["rater"])] += 1
    fixes = collections.Counter()
    for directory, run_meta, began in fixer_runs(os.path.basename(bench), started):
        fixed = sonnet_trial.fixed_findings(directory)
        if not fixed:
            continue
        record = sonnet_trial.directory_fix(directory, run_meta, began, len(fixed))
        haiku = sum(1 for i in fixed if isinstance(i, int) and 0 <= i < len(judged) and is_haiku(judged[i]["rater"]))
        outcome = "reverted" if record["reverted"] else "landed" if record["landed"] else "unlanded"
        fixes["fixed"] += len(fixed)
        fixes["haiku"] += haiku
        fixes[outcome] += len(fixed)
        fixes["haiku " + outcome] += haiku
    verdict = f"{sum(confirmed.values())} confirmed · " + " · ".join(f"{c} {confirmed[c]}/{found[c]}" for c in cells)
    return (f"haiku trial · {meta.get('lens')} · {os.path.basename(bench)} · judge {state}"
            + (f" ({judge['reason']})" if state != "ran" and judge.get("reason") else "")
            + f" · {sum(found.values())} found · {verdict}"
            f" · fixes {fixes['fixed']} (haiku {fixes['haiku']}) · reverted {fixes['reverted']} (haiku {fixes['haiku reverted']})"
            f" · unlanded {fixes['unlanded']} (haiku {fixes['haiku unlanded']})")


def main(argv):
    night = read_json(argv[0], {})
    if not isinstance(night, dict) or not night.get("started_at"):
        return 0
    started = night_spend.epoch(night["started_at"])
    finished = night_spend.epoch(night["finished_at"]) if night.get("finished_at") else time.time()
    for bench, meta in night_rounds(started, finished):
        print(round_line(bench, meta, started))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
