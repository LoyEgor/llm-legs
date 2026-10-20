#!/usr/bin/env python3
"""Apply Egor's ticks from the disk review page (docs/disk-review.md): lsof check, then the system Trash
(/usr/bin/trash) or copy to Work and Trash the source. Nothing is ever deleted for good.

  apply.py [--dry-run]

Reads the ticks from the open Dia tab and the items from the page's items.json. A path a non-passive process holds
open is skipped. A folder macOS guards (TCC) goes to the Trash through Hammerspoon, which holds Full Disk Access;
root-owned leftovers go in one Finder delete, so macOS asks for the password once. Every shown item lands in the
decisions ledger: ticked and gone → yes, unticked → keep (the next review lists it under "decided keep").
"""
import datetime
import json
import os
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import page  # noqa: E402
import scan  # noqa: E402

DRY = "--dry-run" in sys.argv
READ = ('JSON.stringify({done:document.body.classList.contains("done"),'
        'ids:[...document.querySelectorAll("input[type=checkbox]:checked")].map(b=>b.dataset.id)})')
# System agents that only index or preview files never count as users.
PASSIVE = ("mds", "mdworker", "Siri", "Notificat", "Spotlight", "fseventsd", "Finder", "Dock", "lsd", "iconservi",
           "corespotl", "QuickLook", "com.apple", "CleanMyMa")


def ticks():
    r = subprocess.run(["dia-js", "--url-contains", "disk-review.html"], input=READ, capture_output=True, text=True)
    raw = r.stdout.strip()
    try:
        got = json.loads(raw)
        return json.loads(got) if isinstance(got, str) else got
    except ValueError:
        sys.exit(f"no disk review tab in Dia ({(r.stderr or raw)[:200]})")


def open_files():
    held, cmd = {}, ""
    for line in subprocess.run(["lsof", "-nP", "-Fcn"], capture_output=True, text=True).stdout.splitlines():
        if line.startswith("c"):
            cmd = line[1:]
        elif line.startswith("n/") and not cmd.startswith(PASSIVE):
            held.setdefault(line[1:], cmd)
    return held


def busy(held, p):
    pre = p.rstrip("/") + "/"
    return sorted({c for o, c in held.items() if o == p or o.startswith(pre)})


def hs_trash(p):
    """Trash through Hammerspoon (Full Disk Access): an async hs.task, its exit code in a result file."""
    work = os.path.join(page.OUT, "hs")
    os.makedirs(work, exist_ok=True)
    tag = str(abs(hash(p)))
    res, sh = os.path.join(work, tag + ".rc"), os.path.join(work, tag + ".sh")
    if os.path.exists(res):
        os.remove(res)
    with open(sh, "w") as f:
        f.write(f"/usr/bin/trash {shlex.quote(p)}; rc=$?\n[ -e {shlex.quote(p)} ] && rc=99\necho $rc > {shlex.quote(res)}\n")
    lua = f"_G.__diskReviewTrash = hs.task.new('/bin/bash', nil, {{'{sh}'}}); _G.__diskReviewTrash:start()"
    subprocess.run(["timeout", "10", "hs", "-t", "8", "-c", lua], capture_output=True)
    for _ in range(120):
        if os.path.exists(res):
            with open(res) as f:
                return f.read().strip() == "0"
        time.sleep(1)
    return False


def trash(p):
    """'' when the path is gone, 'root' when only a password can move it, else the error."""
    r = subprocess.run(["/usr/bin/trash", p], capture_output=True, text=True)
    if not os.path.lexists(p):
        return ""
    if os.lstat(p).st_uid == 0:
        return "root"
    if "not permitted" in (r.stderr + r.stdout).lower() and hs_trash(p):
        return ""
    return (r.stderr or r.stdout or "still there").strip()[:200]


def main():
    try:
        with open(os.path.join(page.OUT, "items.json")) as f:
            data = json.load(f)
    except (OSError, ValueError):
        sys.exit("no page built yet: run page.py first")
    choice = ticks()
    ids = set(choice.get("ids", []))
    print(f"page done: {bool(choice.get('done'))} | ticked: {len(ids)}")
    held = open_files()
    log = {"trashed": [], "moved": [], "busy": [], "failed": [], "in_app": []}
    root, gone_kb = [], 0
    for i in data["items"]:
        if i["id"] not in ids:
            continue
        action = i.get("action", "trash")
        if action.startswith("ui:"):
            log["in_app"].append([i["id"], action[3:]])
            continue
        for p in i["paths"]:
            if not os.path.lexists(p):
                continue
            who = busy(held, p)
            if who:
                log["busy"].append([i["id"], p, who[:3]])
                continue
            kb = scan.size_kb(p)
            if action.startswith("move:"):
                dest = os.path.join(action[5:], os.path.basename(p))
                if os.path.lexists(dest):
                    log["failed"].append([i["id"], p, "destination exists"])
                    continue
                if DRY:
                    log["moved"].append([i["id"], p, dest])
                    continue
                os.makedirs(action[5:], exist_ok=True)
                r = subprocess.run(["ditto", p, dest], capture_output=True, text=True)
                if r.returncode or scan.size_kb(dest) < kb * 0.98:
                    log["failed"].append([i["id"], p, "copy short: " + r.stderr[:200]])
                    continue
                err = trash(p)
                (log["moved"] if not err else log["failed"]).append([i["id"], p, dest if not err else err])
                gone_kb += 0 if err else kb
                continue
            if DRY:
                log["trashed"].append([i["id"], p])
                continue
            err = trash(p)
            if err == "root":
                root.append([i["id"], p, kb])
            elif err:
                log["failed"].append([i["id"], p, err])
            else:
                log["trashed"].append([i["id"], p])
                gone_kb += kb
    if root:
        files = ", ".join(f'(POSIX file "{p}" as alias)' for _, p, _ in root)
        subprocess.run(["timeout", "180", "osascript", "-e", f'tell application "Finder" to delete {{{files}}}'],
                       capture_output=True, text=True)
        for iid, p, kb in root:
            if os.path.lexists(p):
                log["failed"].append([iid, p, "root-owned, password not given"])
            else:
                log["trashed"].append([iid, p])
                gone_kb += kb
    if not DRY:
        record(data["items"], ids, log)
    with open(os.path.join(page.OUT, "apply-log.json"), "w") as f:
        json.dump(log, f, ensure_ascii=False, indent=1)
    for k, v in log.items():
        print(f"{k}: {len(v)}")
        for x in v[:10] if k != "trashed" else []:
            print("   ", x)
    print(f"to Trash this run: {gone_kb / scan.GIB:.1f} GB (empty the Trash to free it)")
    return 0


def record(items, ids, log):
    """Ledger by path: gone → yes, shown but unticked → keep."""
    today = datetime.date.today().isoformat()
    gone = {p for k in ("trashed", "moved") for _, p, *_ in log[k]}
    book = page.ledger()
    for i in items:
        for p in i["paths"]:
            if i["id"] not in ids:
                book[p] = {"decision": "keep", "date": today, "title": i["title"], "gb": i["gb"]}
            elif p in gone:
                book[p] = {"decision": "yes", "date": today, "title": i["title"]}
    os.makedirs(os.path.dirname(page.LEDGER), exist_ok=True)
    with open(page.LEDGER + ".tmp", "w") as f:
        json.dump(book, f, ensure_ascii=False, indent=1)
    os.replace(page.LEDGER + ".tmp", page.LEDGER)


if __name__ == "__main__":
    sys.exit(main())
