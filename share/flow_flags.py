#!/usr/bin/env python3
"""Every Flow send (image or clip) with what came before it and whether Flow flagged the account
(PUBLIC_ERROR_UNUSUAL_ACTIVITY), rebuilt from gemini-web's job ledger: the evidence a rest, budget or rotation
scheme is built on, instead of guessed day counts.

  flow_flags.py [--days N] [--json]

Prints each flag with its context, then the flag rate per condition. A send is an image `queued` row (written
before the send), a clip's `queued` rows of one job, or a failed send's row; before queued rows existed, an image
job's saved takes. Flags come from the ledger's `flagged` rows, then from failure reports and each account's last
`flagged_at` for the ones the ledger missed (before 2026-10-16 no flag was ledgered; the reports are pruned)."""
from __future__ import annotations

import argparse
import calendar
import collections
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gemini_web as gw  # noqa: E402

DAY = 86400
NEAR_S = 600  # sends this close on other accounts ran in parallel; a flag this close is the same send's
FAILOVER_S = 300  # a send this soon after another account's flag on the same prompt is that flag's failover


def ledger_rows() -> list[dict]:
    return sorted((r for r in gw.job_rows() if isinstance(r, dict) and r.get("account") and r.get("ts")),
                  key=lambda r: r["ts"])


def is_clip(row: dict) -> bool:
    return row.get("kind") == "flow-video" or str(row.get("dest") or "").endswith(".mp4") and row.get("state")


def sends_of(rows: list[dict]) -> list[dict]:
    sends, clips, saved, queued_jobs = [], {}, collections.defaultdict(list), set()
    for r in rows:
        if r.get("kind") == "flow-image" and r.get("event") == "queued":
            queued_jobs.add((r["account"], r.get("job")))
            sends.append({"ts": r["ts"], "account": r["account"], "job": r.get("job"), "kind": r.get("op") or "image",
                          "model": r.get("model"), "takes": r.get("count") or 1, "refs": r.get("refs") or [],
                          "prompt": r.get("prompt"), "flagged": False})
        elif r.get("kind") == "flow-image" and r.get("event") == "saved":
            saved[(r["account"], r.get("job") or r["ts"] // 300)].append(r)
        elif is_clip(r) and r.get("state") == "queued":
            key = (r["account"], r.get("job") or r["ts"] // 300)
            if key in clips:
                clips[key]["takes"] += 1
            else:
                clips[key] = {"ts": r["ts"], "account": r["account"], "job": r.get("job"), "kind": "clip",
                              "model": r.get("model"), "takes": 1, "refs": r.get("refs") or [],
                              "prompt": r.get("prompt"), "flagged": False}
        elif r.get("event") == "failed" and r.get("kind") == "flow-video":
            sends.append({"ts": r["ts"], "account": r["account"], "job": r.get("job"), "kind": "clip",
                          "model": r.get("model"), "takes": r.get("count") or 1, "refs": r.get("refs") or [],
                          "prompt": r.get("prompt"), "flagged": bool(r.get("flagged")), "logged": True})
    sends += clips.values()
    for (account, job), takes in saved.items():
        if (account, job) not in queued_jobs:
            sends.append({"ts": takes[0]["ts"], "account": account, "job": job, "kind": "image",
                          "model": takes[0].get("model"), "takes": len(takes), "refs": [], "prompt": None,
                          "flagged": False})
    return sorted(sends, key=lambda s: s["ts"])


def flag_times(rows: list[dict]) -> list[tuple[float, str, str]]:
    """(ts, account, source) of every flag: ledger rows, then failure reports and meta the ledger lacks."""
    flags = [(r["ts"], r["account"], "ledger") for r in rows if r.get("flagged")]
    for report in sorted((gw.ROOT / "failures").glob("*.txt")):
        found = re.match(r"(\d{8}T\d{6})Z-([^-]+)-", report.name)
        if found and "UNUSUAL_ACTIVITY" in report.read_text(errors="ignore")[:400]:
            flags.append((calendar.timegm(time.strptime(found[1], "%Y%m%dT%H%M%S")), found[2], "report"))
    for account in sorted(gw.roster()):
        at = gw.read_meta(account).get("flagged_at")
        if at:
            flags.append((float(at), account, "meta"))
    kept = [f for f in flags if f[2] == "ledger"]
    for flag in sorted(f for f in flags if f[2] != "ledger"):
        if not any(f[1] == flag[1] and abs(f[0] - flag[0]) < gw.FLAG_BURST_S for f in kept):
            kept.append(flag)
    return sorted(kept)


def attach(sends: list[dict], flags: list[tuple[float, str, str]]) -> list[dict]:
    """Each flag marks the account's send just before it, or stands as a send of its own the ledger missed."""
    for ts, account, source in flags:
        before = [s for s in sends if s["account"] == account and ts - NEAR_S <= s["ts"] <= ts + 60]
        if before:
            before[-1].update(flagged=True, source=source)
        else:
            sends.append({"ts": ts, "account": account, "job": None, "kind": "?", "model": None, "takes": 1,
                          "refs": [], "prompt": None, "flagged": True, "source": source, "unlogged": True})
    return sorted(sends, key=lambda s: s["ts"])


def context(sends: list[dict], rows: list[dict]) -> list[dict]:
    hands = [(r["ts"], r["account"]) for r in rows if r.get("event") == "hand"]
    for i, s in enumerate(sends):
        mine = [p for p in sends[:i] if p["account"] == s["account"]]
        flags = [p["ts"] for p in mine if p["flagged"]]
        s["takes_24h"] = sum(p["takes"] for p in mine if s["ts"] - p["ts"] < DAY)
        s["takes_1h"] = sum(p["takes"] for p in mine if s["ts"] - p["ts"] < 3600)
        s["rest_h"] = round((s["ts"] - mine[-1]["ts"]) / 3600, 1) if mine else None
        s["days_since_flag"] = round((s["ts"] - flags[-1]) / DAY, 1) if flags else None
        s["after_flag"] = bool(flags) and flags[-1] == max(p["ts"] for p in mine)
        s["parallel"] = len({p["account"] for p in sends if abs(p["ts"] - s["ts"]) <= NEAR_S} - {s["account"]})
        s["failover"] = any(p["flagged"] and p["account"] != s["account"] and 0 <= s["ts"] - p["ts"] <= FAILOVER_S
                            and (p.get("job") == s.get("job") or p.get("prompt") and p["prompt"] == s.get("prompt"))
                            for p in sends[max(0, i - 50):i])
        others = {tag for p in sends[:i] if p["account"] != s["account"] and s["ts"] - p["ts"] < DAY
                  for tag in p["refs"]}
        s["shared_ref"] = bool(set(s["refs"]) & others)
        s["hand_24h"] = any(a == s["account"] and 0 <= s["ts"] - t < DAY for t, a in hands)
        s["hour"] = time.localtime(s["ts"]).tm_hour
    return sends


def bucket(value, edges: tuple, unit: str = "") -> str:
    if value is None:
        return "never"
    for low, high in zip(edges, edges[1:]):
        if low <= value < high:
            return f"{low}-{high - 1}{unit}" if high - low > 1 else f"{low}{unit}"
    return f"{edges[-1]}+{unit}"


CONDITIONS = {
    "takes in prior 24 h": lambda s: bucket(s["takes_24h"], (0, 1, 6, 11, 21, 31)),
    "takes in prior 1 h": lambda s: bucket(s["takes_1h"], (0, 1, 5, 9)),
    "days since own last flag": lambda s: bucket(s["days_since_flag"], (0, 3, 7, 14)),
    "first send after a flag": lambda s: str(s["after_flag"]),
    "rest before the send": lambda s: "first ever" if s["rest_h"] is None else bucket(s["rest_h"], (0, 1, 6, 24), " h"),
    "kind": lambda s: s["kind"],
    "takes in the send": lambda s: bucket(s["takes"], (1, 2, 4)),
    "refs": lambda s: "shared with another account" if s["shared_ref"] else bucket(len(s["refs"]), (0, 1, 3)),
    "other accounts within 10 min": lambda s: bucket(s["parallel"], (0, 1, 3, 6)),
    "failover after a flag": lambda s: str(s["failover"]),
    "hand session in prior 24 h": lambda s: str(s["hand_24h"]),
    "local hour": lambda s: bucket(s["hour"], (0, 6, 12, 18)),
}


def rates(sends: list[dict]) -> dict:
    out = {}
    for name, key in CONDITIONS.items():
        table = collections.defaultdict(lambda: [0, 0])
        for s in sends:
            if not s.get("unlogged"):
                table[key(s)][0] += 1
                table[key(s)][1] += s["flagged"]
        order = sorted(table, key=lambda k: (0, int(re.match(r"\d+", k)[0])) if k[:1].isdigit() else (1, k))
        out[name] = {k: {"sends": table[k][0], "flags": table[k][1]} for k in order}
    return out


def flag_line(s: dict) -> str:
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(s["ts"]))
    if s.get("unlogged"):
        return f"{when} {s['account']}: from {s['source']} only, the send is not in the ledger"
    since = "never before" if s["days_since_flag"] is None else f"{s['days_since_flag']} d since its last"
    rest = "its first send" if s["rest_h"] is None else f"rest {s['rest_h']} h"
    return (f"{when} {s['account']}: {s['kind']} {s['model']} x{s['takes']}, refs {len(s['refs'])}"
            f"{' (shared)' if s['shared_ref'] else ''} · {s['takes_24h']} takes in 24 h, {s['takes_1h']} in 1 h"
            f" · {rest} · flag {since} · {s['parallel']} accounts in parallel"
            f"{' · failover of a flag' if s['failover'] else ''}{' · hand session in 24 h' if s['hand_24h'] else ''}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--days", type=float, help="only sends of the last N days")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    rows = ledger_rows()
    sends = context(attach(sends_of(rows), flag_times(rows)), rows)
    if args.days:
        sends = [s for s in sends if s["ts"] >= time.time() - args.days * DAY]
    flagged = [s for s in sends if s["flagged"]]
    if args.json:
        print(json.dumps({"sends": len(sends), "flags": flagged, "rates": rates(sends)}, ensure_ascii=False))
        return 0
    first = time.strftime("%Y-%m-%d", time.localtime(sends[0]["ts"])) if sends else "-"
    print(f"{len(sends)} Flow sends since {first}, {len(flagged)} flagged")
    for s in flagged:
        print("  " + flag_line(s))
    for name, table in rates(sends).items():
        print(name)
        for value, n in table.items():
            share = f"{100.0 * n['flags'] / n['sends']:.1f} %" if n["sends"] else "-"
            print(f"  {value:<30} {n['sends']:>5} sends {n['flags']:>3} flags {share:>7}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
