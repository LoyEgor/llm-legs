"""The shape contract of share/harness-ledger.json, one source for the suite's ledger guard, Harness Doctor's
`ledger:` faults and so `doctor-fix close`, which refuses a harness run whose rerun doctor reports one: a fixer sees
the break in its own `harness-doctor --json`, never first at landing. Read on the tracked file's own bytes, before
the settled overlay fills it."""
import json
import re

from fix_commit import FIX_KEYS

EVIDENCE_KEYS = ("compared", "data", "result")
OWNER = "Harness Doctor"
ROW_KEYS = frozenset({"id", "title", "match", "status", "fixes", "same_cause", "last_reviewed", "reviewed_by", "note",
                      "handoff"})
ROW_OPTIONAL = frozenset({"ruled_at", "expected_min_day"})
BLIND_KEYS = frozenset({"id", "what", "reason", "since", "would_catch_if"})
FIX_FILE_RE = re.compile(r"[\w.-]+/.+")


def equivalent(fix):
    proof = fix.get("equivalence") if isinstance(fix, dict) else None
    return isinstance(proof, dict) and all(str(proof.get(k) or "").strip() for k in EVIDENCE_KEYS)


def key_fault(what, have, want, optional=frozenset()):
    lacks, extra = sorted(want - set(have)), sorted(set(have) - want - optional)
    if not lacks and not extra:
        return []
    return ["%s fields are {%s}:%s%s" % (what, ", ".join(sorted(want)), " lacks %s" % ", ".join(lacks) if lacks else "",
                                         " has %s" % ", ".join(extra) if extra else "")]


def row_faults(row, ids):
    faults = key_fault("a row's", row, ROW_KEYS, ROW_OPTIONAL)
    if not isinstance(row.get("expected_min_day", 0), (int, float)):
        faults.append("expected_min_day is a number")
    same = row.get("same_cause")
    if not isinstance(same, list) or any(s not in ids for s in same):
        faults.append("same_cause lists row ids: %s" % json.dumps(same))
    fixes = row.get("fixes")
    if not isinstance(fixes, list):
        return faults + ["fixes is a list"]
    if row.get("status") in ("fixed", "fixed-pending") and not fixes:
        faults.append("a %s row names its fix" % row["status"])
    match = row.get("match") if isinstance(row.get("match"), dict) else {}
    adhoc = match.get("rule") == "opportunity" and str(match.get("ident") or "").startswith("adhoc/")
    for i, fix in enumerate(fixes):
        if not isinstance(fix, dict):
            faults.append("fixes[%d] is an object" % i)
            continue
        faults += key_fault("fixes[%d]" % i, fix, FIX_KEYS, frozenset({"equivalence"} | ({"bench"} if adhoc else set())))
        files = fix.get("files")
        if not isinstance(files, list) or not files:
            faults.append("fixes[%d] names its files" % i)
        elif not all(isinstance(f, str) and FIX_FILE_RE.fullmatch(f) for f in files):
            faults.append("fixes[%d] files are repo/path: %s" % (i, json.dumps(files)))
        if "equivalence" in fix and not equivalent(fix):
            faults.append("fixes[%d] equivalence carries {%s}" % (i, ", ".join(EVIDENCE_KEYS)))
    if fixes and isinstance(fixes[-1], dict) and (fixes[-1].get("in") is None) != (row.get("status") == "fixed-pending"):
        faults.append("the last fix has in: null exactly while the status is fixed-pending (status %s, in %s)"
                      % (json.dumps(row.get("status")), json.dumps(fixes[-1].get("in"))))
    return faults


def faults(ledger):
    """`(where, fault)` of every break: a row id (`#<index>` for a row with none), `ledger` or `blind_spots`."""
    if not isinstance(ledger, dict):
        return [("ledger", "is a JSON object")]
    out = [] if ledger.get("owner") == OWNER else [("ledger", "owner is %s" % OWNER)]
    rows = ledger.get("rows")
    if not isinstance(rows, list):
        out.append(("ledger", "rows is a list"))
        rows = []
    ids = [r.get("id") for r in rows if isinstance(r, dict)]
    for i, row in enumerate(rows):
        where = row["id"] if isinstance(row, dict) and isinstance(row.get("id"), str) and row["id"] else "#%d" % i
        out += [(where, f) for f in (row_faults(row, ids) if isinstance(row, dict) else ["a row is an object"])]
    spots = ledger.get("blind_spots")
    if not isinstance(spots, list):
        return out + [("blind_spots", "blind_spots is a list")]
    for i, spot in enumerate(spots):
        if not isinstance(spot, dict):
            out.append(("blind_spots", "blind_spots[%d] is an object" % i))
            continue
        out += [("blind_spots", f) for f in key_fault("blind_spots[%d]" % i, spot, BLIND_KEYS, frozenset({"unmeasurable"}))]
        unmeasurable = spot.get("unmeasurable", "x")
        if not isinstance(unmeasurable, str) or not unmeasurable.strip():
            out.append(("blind_spots", "blind_spots[%d] unmeasurable is a non-empty string" % i))
    return out
