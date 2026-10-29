"""The decisions the night re-reads (docs/directions/README.md, Rules, Decisions): a cut not made, a trade he
answered or a ruled-out row carries what it depends on and the date it is re-read; on that date the night re-checks
the dependency and either renews the date or brings Egor the changed trade. They are the decision rows of the
ledgers (ledger_contract.decision: kept and trade audit rows, ruled-out doctor rows, never weather or not-a-bug),
fields `depends_on` and `reread_by`, and each `## Decisions` entry of docs/directions/*.md that ends
`Depends on: <what>; re-read by YYYY-MM-DD.` (an entry without one is undated, never due).
`due <repo>` lists each one past its date as source<TAB>id<TAB>reread_by<TAB>depends_on;
`carry <repo>` prints night-run carry's line for one `reread` job per source holding a due one;
`brief <repo> <source>` prints that job's brief;
`renew <source> <id> <YYYY-MM-DD> <reason> [<depends_on>]` sets a ledger row of this checkout to its next re-read
date, the one-line reason in `reread_note`."""
import datetime
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger_contract  # noqa: E402

LEDGERS = ("share/spend-ledger.json", "share/harness-ledger.json", "share/doctor-ledger.json")
DIRECTIONS = "docs/directions"
ENTRY_RE = re.compile(r"Depends on:\s*(?P<on>.+?);\s*re-read by (?P<by>\d{4}-\d{2}-\d{2})", re.I | re.S)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_ledger(path):
    try:
        with open(path, encoding="utf-8") as handle:
            ledger = json.load(handle)
    except (OSError, ValueError):
        return None
    return ledger if isinstance(ledger, dict) and isinstance(ledger.get("rows"), list) else None


def entries(path):
    """(line, text) of each `- ` entry of the file's `## Decisions` section."""
    out, inside = [], False
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if line.startswith("## "):
                inside = line.startswith("## Decisions")
            elif inside and line.startswith("- "):
                out.append([number, line.strip()])
            elif inside and out and line.strip():
                out[-1][1] += " " + line.strip()
    return out


def decisions(repo):
    """{source: [{id, title, depends_on, reread_by, note}]} of every decision the repository holds."""
    found = {}
    for source in LEDGERS:
        ledger = read_ledger(os.path.join(repo, source))
        for row in ledger["rows"] if ledger else ():
            if isinstance(row, dict) and ledger_contract.decision(row):
                found.setdefault(source, []).append({
                    "id": row.get("id"), "title": row.get("title") or row.get("id"),
                    "depends_on": row.get("depends_on"), "reread_by": row.get("reread_by"),
                    "note": row.get("zero") or row.get("note") or ""})
    for path in sorted(glob.glob(os.path.join(repo, DIRECTIONS, "*.md"))):
        for number, text in entries(path):
            dated = ENTRY_RE.search(text)
            found.setdefault(os.path.relpath(path, repo), []).append({
                "id": "line %d" % number, "title": text[2:90], "depends_on": dated and dated.group("on"),
                "reread_by": dated and dated.group("by"), "note": ""})
    return found


def due(repo, today=None):
    """{source: [decision]} of those whose reread_by is today or earlier."""
    today = (today or datetime.date.today()).isoformat()
    out = {}
    for source, rows in decisions(repo).items():
        late = [r for r in rows if isinstance(r["reread_by"], str) and r["reread_by"] <= today]
        if late:
            out[source] = late
    return out


def brief(repo, source):
    rows = due(repo).get(source) or []
    ledger = source.endswith(".json")
    lines = [
        "Re-read the %d decision(s) of `%s` below: each is past its re-read date (`%s/docs/directions/README.md`, "
        "Rules, Decisions). Work in your worktree's copy of the file. For each:" % (len(rows), source, repo),
        "1. Check whether what it depends on still holds, on today's evidence: the code, the journals and the doctors' "
        "numbers it names (`git log -S`, its row's sources and note).",
        "2. It holds: renew it. %s A row reading `unrecorded`: state what it depends on as you renew it." % (
            "`python3 share/decision_reread.py renew %s <id> <YYYY-MM-DD> \"<one line: what you checked>\" "
            "[\"<what it depends on>\"]`, the date at most %d days out, sooner when the dependency is near its edge."
            % (source, ledger_contract.REREAD_DAYS) if ledger else
            "Edit the entry's `re-read by` date in place, at most %d days out; the one-line reason goes in the commit "
            "message." % ledger_contract.REREAD_DAYS),
        "3. It changed: the cut may now be possible or the trade reads differently. When research settles it (an "
        "obvious win, or keeping it as it is), act on it or renew it. Only when Egor's word must decide (a strategic "
        "change of course, or a serious downside against the gain) renew it naming the trade and report the trade "
        "under BLOCKED-ON-EGOR as `Cost:`, `Loss:` and `Recommendation:` lines: the night files it in Doctors "
        "«need you».",
        "4. Commit every renewal on the branch (one long line). Report per decision: renewed or traded, with its "
        "one-line reason, and the commits as repo@hash.",
        ""]
    for row in rows:
        lines.append("- %s · %s · re-read by %s · depends on: %s%s" % (
            row["id"], row["title"], row["reread_by"], row["depends_on"],
            " · its reasoning: %s" % " ".join(str(row["note"]).split())[:400] if row["note"] else ""))
    return "\n".join(lines) + "\n"


def renew(source, row_id, date, reason, depends_on=None, root=ROOT):
    if source not in LEDGERS:
        raise SystemExit("renew takes a ledger row (%s); a Decisions entry is edited in place" % ", ".join(LEDGERS))
    if not ledger_contract.DATE_RE.fullmatch(date) or date <= datetime.date.today().isoformat():
        raise SystemExit("the re-read date is a YYYY-MM-DD after today: %s" % date)
    if not str(reason or "").strip():
        raise SystemExit("renew needs its one-line reason")
    path = os.path.join(root, source)
    with open(path, encoding="utf-8") as handle:
        raw = handle.read()
    ledger = json.loads(raw)
    row = next((r for r in ledger["rows"] if isinstance(r, dict) and r.get("id") == row_id), None)
    if not row or not ledger_contract.decision(row):
        raise SystemExit("no decision row %s in %s" % (row_id, source))
    row.update(reread_by=date, reread_note="%s: %s" % (datetime.date.today().isoformat(), " ".join(reason.split())))
    if str(depends_on or "").strip():
        row["depends_on"] = " ".join(depends_on.split())
    with open(path + ".tmp", "w", encoding="utf-8") as handle:
        handle.write(json.dumps(ledger, ensure_ascii=False, indent=1 if raw.startswith('{\n "') else 2) + "\n")
    os.replace(path + ".tmp", path)
    return row


def main(argv):
    if argv[:1] == ["due"] and len(argv) == 2:
        for source, rows in sorted(due(argv[1]).items()):
            for row in rows:
                print("\t".join([source, str(row["id"]), row["reread_by"], " ".join(str(row["depends_on"]).split())]))
    elif argv[:1] == ["carry"] and len(argv) == 2:
        for source in sorted(due(argv[1])):
            stem = os.path.splitext(os.path.basename(source))[0]
            print("\t".join(["reread", "%s-%s" % (datetime.date.today().isoformat(), stem), argv[1], source, "-"]))
    elif argv[:1] == ["brief"] and len(argv) == 3:
        sys.stdout.write(brief(argv[1], argv[2]))
    elif argv[:1] == ["renew"] and len(argv) in (5, 6):
        print(json.dumps(renew(*argv[1:]), ensure_ascii=False))
    else:
        raise SystemExit(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
