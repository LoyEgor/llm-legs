#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/spend.py, the Spend block of the Harness doctor, off a fixture tracking.json: tokenmap's harness_index as the
# headline, the menus check and every Fee index source as components, stale or no index -> nodata, the due rules, the night's ranked queue, the
# restate a night close reads, the audit record and its proof, the roi line, the day backfill and the Harness menu.
# Fixture directories only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

asserts=$(python3 - "$ROOT" "$WORK" <<'EOF'
import datetime, importlib.machinery, importlib.util, json, os, subprocess, sys, time

root, work = sys.argv[1], sys.argv[2]
count = [0]
os.environ["WORKER_STATS_DIR"] = os.path.join(work, "worker-stats")
os.environ["CLAUDE_KEEPALIVE_DIR"] = os.path.join(work, "keepalive")
os.environ["TOKENMAP_DB"] = os.path.join(work, "no-tokenmap.sqlite3")


def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)


sys.path.insert(0, os.path.join(root, "share"))
import spend

repos = os.path.join(work, "repos")
menu_files = [os.path.join(repos, p) for p in ("token-map/tokenmap/tracking.py", "llm-legs/hammerspoon/doctors.lua",
                                                "llm-legs/bin/harness-doctor", "llm-legs/bin/system-doctor")]
for path in menu_files + [os.path.join(repos, "llm-legs", "bin", "worker-run")]:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write("menu\n")
NOW = time.time()


def stamp(t):
    return datetime.datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def payload(made=NOW - 3600, hook_price=300.0, index=True, value=0.4612, definition="d1"):
    harness = {"definition": definition, "value": value, "change": "-54%", "tone": "better", "coverage": 0.113,
               "claude": 4e6, "sources": [
                   {"group": "Workers", "source": "Delegation", "plain": [400e3, 300e3], "charged": 300e3},
                   {"group": "Tests & checks", "source": "Hooks", "plain": [100e3, 50e3], "charged": 100e3},
                   {"group": "Scripts", "source": "Advisor", "plain": [500e3, 0], "charged": 25e3}],
               "cells": [
        {"consumer": "Chat", "leaf": "Hooks", "source": "Hooks", "units": [100, 50], "price": [hook_price, 200.0],
         "points": -0.1},
        {"consumer": "Chat", "leaf": "prefix: CLAUDE.md + memory", "source": "CLAUDE.md & memory", "units": [100, 50],
         "price": [60.0, 50.0], "points": 0.1},
        {"consumer": "Workers", "leaf": "Delegation", "source": "Delegation", "units": [40, 20], "price": [50.0, 50.0],
         "points": 0.0}]}
    return {"generated_at": stamp(made), "data_through": stamp(NOW), "stale_after_hours": 26,
            **({"harness_index": harness} if index else {}), "rows": [{"key": "spend", "cur": 1e6, "prev": 5e5}]}


found = spend.components(payload(), repos)
check(found[0]["key"] == "menus" and found[0]["sources"] == sorted(menu_files) and found[0]["share"] == 0.0,
      "the menus check comes first, its sources the Token tracking and Doctors menu code, never another bin/ "
      "program: %s" % found[0])
found = {c["key"]: c for c in found}
check([k for k in found][1:] == ["fee:Delegation", "fee:Hooks", "fee:Advisor"]
      and found["fee:Delegation"]["share"] == 7.5 and found["fee:Delegation"]["basis"] == 0.075
      and found["fee:Delegation"]["label"] == "Delegation (Workers)" and found["fee:Delegation"]["delta"] == "+33%"
      and found["fee:Advisor"]["share"] == 0.625 and found["fee:Advisor"]["delta"] == "new",
      "every Fee source of tokenmap's index is a component, largest charge first: its share of Claude spend as the "
      "menu shows it and as the basis, the plain Δ: %s" % found)
check([c["key"] for c in spend.components(payload(index=False), repos)] == ["menus"],
      "no Fee index, no Fee components")
leaky = payload()
leaky["harness_index"]["loaded"] = [{"source": "Browser check", "runs": 38, "last": "2026-10-13T13:47:49Z",
                                     "tokens": 50e3}]
leak = spend.components(leaky, repos)[1]
check(leak["key"] == "loaded:Browser check" and leak["share"] == 1.25 and leak["basis"] == 0.0125
      and spend.named(leak) == "1.2 % of Claude spend · Browser check loaded the harness configuration · 38 runs, last "
                                "2026-10-13T13:47:49Z"
      and spend.due(leak, None, {}) == "never audited"
      and spend.due(leak, {"verdict": "cut", "audited_at": "2026-10-13T12:00:00+00:00", "share": 0.0125}, {})
      == "still loading after the cut"
      and spend.due(leak, {"verdict": "cut", "audited_at": "2026-10-13T14:00:00+00:00", "share": 0.0125}, {}) is None
      and spend.due(leak, {"verdict": "kept", "audited_at": "2026-10-13T12:00:00+00:00", "share": 0.0125}, {}) is None,
      "a harness job whose latest run loaded the configuration follows the menus check, its share of plain Fee; "
      "a run after a cut makes it due again: %s" % leak)

os.makedirs(os.environ["WORKER_STATS_DIR"])
with open(os.path.join(os.environ["WORKER_STATS_DIR"], "runs.jsonl"), "w") as handle:
    for ended, flag in ((100, None), (200, True), (300, False), (400, True)):
        handle.write(json.dumps({"run": "r%d" % ended, "ended_at": 1791900000 + ended, "user_md_loaded": flag}) + "\n")
workers = spend.components(payload(), repos)[1]
check(workers["key"] == "loaded:Workers" and workers["delta"].startswith("2 of 3 runs, last ")
      and spend.due(workers, {"verdict": "cut", "audited_at": "2026-10-13T12:00:00+00:00", "share": 0.0}, {})
      == "still loading after the cut",
      "a claudeb worker whose latest checked run loaded the user CLAUDE.md is a loaded: component, due again after a "
      "cut: %s" % workers)
with open(os.path.join(os.environ["WORKER_STATS_DIR"], "runs.jsonl"), "a") as handle:
    handle.write(json.dumps({"run": "r500", "ended_at": 1791900500, "user_md_loaded": False}) + "\n")
check("loaded:Workers" not in [c["key"] for c in spend.components(payload(), repos)],
      "a clean latest worker run clears the Workers component")
os.remove(os.path.join(os.environ["WORKER_STATS_DIR"], "runs.jsonl"))

import keepalive

pings_dir = os.environ["CLAUDE_KEEPALIVE_DIR"]
os.makedirs(pings_dir)


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def said(t, text, origin=None):
    entry = {"type": "user", "timestamp": iso(t), "message": {"role": "user", "content": text}}
    return {**entry, "origin": origin} if origin else entry


def answered(t, mid, read, wrote, out=3):
    return {"type": "assistant", "timestamp": iso(t), "message": {"id": mid, "usage": {
        "input_tokens": 1, "cache_read_input_tokens": read, "cache_creation_input_tokens": wrote, "output_tokens": out}}}


PING = said(0, "<task-notification>\n<summary>cache keepalive</summary>\n</task-notification>",
            {"kind": "task-notification"})
T0 = NOW - 3 * 86400
returns = {"saved": [said(T0 + 1800, "next"), answered(T0 + 1801, "r", 200000, 500)],
           "no return": [said(T0 + 3700, "next"), answered(T0 + 3701, "r", 0, 200000)],
           "warm anyway": [said(T0 + 60, "next"), answered(T0 + 61, "r", 200000, 500)],
           "cold": [said(T0 + 1800, "next"), answered(T0 + 1801, "r", 1000, 199000)],
           "compacted": [{"type": "system", "subtype": "compact_boundary", "timestamp": iso(T0 + 3240)},
                         {"type": "user", "isCompactSummary": True, "timestamp": iso(T0 + 3240),
                          "message": {"content": "x" * 90}},
                         said(T0 + 3500, "next"), answered(T0 + 3501, "r", 30000, 500)],
           "unread": None}
journal = []
for kind, back in returns.items():
    path = os.path.join(pings_dir, kind.replace(" ", "-") + ".jsonl")
    with open(path, "w") as handle:
        handle.write(json.dumps(dict(PING, timestamp=iso(T0 - 7200))) + "\n")  # an older ping, before the offset
        offset = handle.tell()
        if back is not None:
            for entry in [dict(PING, timestamp=iso(T0 + 1)), answered(T0 + 2, "p", 200000, 100),
                          answered(T0 + 2, "p", 200000, 100), *back]:
                handle.write(json.dumps(entry) + "\n")
    journal.append({"ts": iso(T0), "session": kind, "decision": "ping", "since": 3480, "context": 200000,
                    "transcript": path, "offset": offset})
journal.append({"ts": iso(NOW - 8 * 86400), "session": "old", "decision": "ping", "since": 3480,
                "transcript": os.path.join(pings_dir, "saved.jsonl"), "offset": 0})
journal.append({"ts": iso(T0), "session": "x", "decision": "silent", "reason": "late"})
ping_cost = 1 + 0.1 * 200000 + 2.0 * 100 + 5.0 * 3
grown = 1 + 200000 + 100 + 3 - 200000  # the ping turn's tokens, left in the chat
warm_growth, cold_growth = 0.1 * grown, 2.0 * grown
compaction = 0.1 * 200000 + 5.0 * len(json.dumps("x" * 90)) / 3
compacted_value = 2.0 * 200000 - (1 + 0.1 * 30000 + 2.0 * 500 + 5.0 * 3)
check([keepalive.outcome(r)["kind"] for r in journal[:6]] == list(returns)
      and [round(keepalive.outcome(r)["cost"], 6) for r in journal[:6]] == [round(c, 6) for c in [
          ping_cost + warm_growth, ping_cost + cold_growth, ping_cost + warm_growth, ping_cost + cold_growth,
          ping_cost + compaction + warm_growth, 0.0]]
      and [keepalive.outcome(r)["value"] for r in journal[:6]] == [1.9 * 200000, 0, 0, 0, compacted_value, 0],
      "a ping's outcome reads the transcript from its offset: its own turn priced once per request id, its tokens "
      "read by each later request (written by a cold one), then the next real turn: warm past the hour saved, none "
      "within the hour, back before the hour, re-read cold, an idle compaction first (its read and summary a cost, "
      "the full cold re-read it spared the value), no ping turn: %s" % [keepalive.outcome(r) for r in journal[:6]])
recap = os.path.join(pings_dir, "recap.jsonl")
with open(recap, "w") as handle:
    handle.writelines(json.dumps(e) + "\n" for e in [
        dict(PING, timestamp=iso(T0 + 1)), answered(T0 + 2, "p", 200000, 100),
        {"type": "system", "subtype": "away_summary", "timestamp": iso(T0 + 200), "content": "y" * 30},
        said(T0 + 7300, "next"), answered(T0 + 7301, "r", 0, 200300)])
away = keepalive.outcome({"ts": iso(T0), "since": 3480, "context": 200000, "transcript": recap, "offset": 0}, NOW)
check(dict(away, cost=round(away["cost"], 6)) == {
          "cost": round(ping_cost + 0.1 * 200000 + 300 + 5.0 * 30 / 3 + cold_growth, 6), "value": 0.0, "kind": "no return"},
      "the away recap a ping's turn set off is its cost: the whole context read, its prompt, its text: %s" % away)
pending = os.path.join(pings_dir, "pending.jsonl")
with open(pending, "w") as handle:
    handle.writelines(json.dumps(e) + "\n" for e in [dict(PING, timestamp=iso(NOW - 600)),
                                                      answered(NOW - 599, "p", 200000, 100)])
fresh = {"ts": iso(NOW - 600), "session": "pending", "decision": "ping", "since": 3480, "transcript": pending,
         "offset": 0}
check(keepalive.outcome(fresh, NOW)["kind"] == "pending" and keepalive.outcome(fresh, NOW + 3700)["kind"] == "no return",
      "a ping whose hour still runs is pending, not a no return: %s" % keepalive.outcome(fresh, NOW))
chain = os.path.join(pings_dir, "chain.jsonl")
with open(chain, "w") as handle:
    handle.writelines(json.dumps(e) + "\n" for e in [dict(PING, timestamp=iso(T0 + 1)), answered(T0 + 2, "p1", 200000, 100)])
    second = handle.tell()
    handle.writelines(json.dumps(e) + "\n" for e in [dict(PING, timestamp=iso(T0 + 3481)), answered(T0 + 3482, "p2", 200000, 100),
                                                      said(T0 + 3500, "next"), answered(T0 + 3501, "r", 200000, 500)])
links = [keepalive.outcome({"ts": iso(T0), "since": 3480, "context": 200000, "transcript": chain, "offset": 0}, NOW),
         keepalive.outcome({"ts": iso(T0 + 3480), "since": 6960, "context": 200000, "transcript": chain,
                            "offset": second}, NOW)]
check([dict(o, cost=round(o["cost"], 6)) for o in links] == [
          {"cost": round(ping_cost + 2 * warm_growth, 6), "value": 0.0, "kind": "no return"},
          {"cost": round(ping_cost + warm_growth, 6), "value": 1.9 * 200000, "kind": "saved"}],
      "a chain of pings prices each turn once: the first ends at the second, the return is the last one's: %s" % links)


def journaled(rows):
    with open(keepalive.journal_path(), "w") as handle:
        handle.writelines(json.dumps(r) + "\n" for r in rows)


journaled(journal)
week = keepalive.summary(NOW)
check(week["pings"] == 6 and week["kinds"] == {k: 1 for k in returns} and week["ratio"] == round(
          (1.9 * 200000 + compacted_value) / (5 * ping_cost + 3 * warm_growth + 2 * cold_growth + compaction), 1)
      and keepalive.components(NOW) == [] and week["missed"] == []
      and keepalive.menu_line(NOW) == "cache keepalive · 7 days · 6 pings · 1 warm returns · 1 no return · saves "
                                      "×%.1f its cost · 0 missed" % week["ratio"],
      "the week's pings, the 8-day-old one and silent sleepers left out, saved more than they cost: a menu line, no "
      "component: %s %s" % (week, keepalive.menu_line(NOW)))
journaled([r for r in journal if r["session"] not in ("saved", "compacted")] + [dict(journal[1], session="again")])
lost = keepalive.components(NOW)
check(len(lost) == 1 and lost[0]["key"] == "keepalive"
      and lost[0]["delta"].startswith("5 pings · 0 warm returns · 2 no return")
      and lost[0]["last"] == iso(T0) and spend.due(lost[0], None, {}) == "never audited"
      and "keepalive" in [c["key"] for c in spend.components(payload(), repos)],
      "5 pings that saved nothing make the keepalive a Spend component, due as never audited: %s" % lost)
journaled([r for r in journal if r["session"] not in ("saved", "cold")])
check(keepalive.components(NOW) == [], "under 5 pings settle nothing")
os.remove(keepalive.journal_path())
check(keepalive.menu_line(NOW) is None and keepalive.components(NOW) == [], "no journal, no line")

# Misses: tokenmap's cold re-reads of interactive chats the journal does not explain.
import sqlite3
os.environ["TOKENMAP_DB"] = os.path.join(work, "tokenmap.sqlite3")
keepalive.ACTIVE_SINCE = iso(NOW - 6 * 86400)
ka_db = sqlite3.connect(os.environ["TOKENMAP_DB"])
ka_db.execute("CREATE TABLE sessions (session_id TEXT, kind TEXT, entrypoint TEXT)")
ka_db.execute("CREATE TABLE requests (session_id TEXT, root_session TEXT, ts TEXT, day TEXT, gap_seconds REAL, "
           "waste_cause TEXT, vendor TEXT, is_sidechain INT, agent_id TEXT, prev_ctx INT)")
ka_colds = {"closed": ("chat", 200000, 7200, {"decision": "closed"}), "silent": ("chat", 200000, 7200, None),
         "late": ("chat", 200000, 7200, {"decision": "silent", "reason": "late"}),
         "capped": ("chat", 200000, 7200, {"decision": "skip", "reason": "cap"}),
         "worker": ("worker", 200000, 7200, None), "small": ("chat", 90000, 7200, None),
         "before": ("chat", 200000, 4 * 86400, None), "headless": ("chat", 200000, 7200, None)}
ka_rows = []
for n, (session, (kind, context, gap, line)) in enumerate(ka_colds.items()):
    at = T0 + 600 * n
    ka_db.execute("INSERT INTO sessions VALUES (?, ?, ?)", (session, kind, "sdk-cli" if session == "headless" else "cli"))
    ka_db.execute("INSERT INTO requests VALUES (?, ?, ?, ?, ?, 'expired (1h+ idle)', 'claude', 0, NULL, ?)",
               (session, session, iso(at), time.strftime("%Y-%m-%d", time.gmtime(at)), gap, context))
    if line:
        ka_rows.append({"ts": iso(at - gap / 2), "session": session, **line})
ka_db.commit()
ka_db.close()
journaled(ka_rows)
week = keepalive.summary(NOW)
flagged = keepalive.components(NOW)
check([m["session"] for m in week["missed"]] == ["silent", "late"]
      and [m["why"] for m in week["missed"]] == ["no journal line", "silent:late"]
      and keepalive.menu_line(NOW).endswith("0 pings · 0 warm returns · 0 no return · saves – its cost · 2 missed")
      and [c["key"] for c in flagged] == ["keepalive:missed"]
      and flagged[0]["delta"].startswith("2 missed: 1 no journal line, 1 silent:late · last late ")
      and spend.due(flagged[0], None, {}) == "never audited",
      "a cold re-read of a big interactive chat with no ping, skip, close or compaction journaled in its idle stretch "
      "is a miss, two make a Spend component; workers, headless runs, small chats and stretches before the hook went "
      "live are not misses: %s %s" % (week["missed"], flagged))
journaled([r for r in ka_rows if r["session"] != "late"] + [{"ts": iso(T0 + 1200 - 3600), "session": "late",
                                                          "decision": "ping"}])
check(keepalive.components(NOW) == [] and len(keepalive.summary(NOW)["missed"]) == 1,
      "a ping in the stretch explains its cold return; one miss alone is no component")
os.remove(keepalive.journal_path())
os.environ["TOKENMAP_DB"] = os.path.join(work, "no-tokenmap.sqlite3")

ledger = os.path.join(work, "spend-ledger.json")
os.environ["SPEND_LEDGER"] = ledger
os.environ["SPEND_TRACKING"] = os.path.join(work, "tracking.json")
with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": []}, handle)


def collect(made=NOW - 3600, state=None, write=False, **fixture):
    with open(os.environ["SPEND_TRACKING"], "w") as handle:
        json.dump(payload(made, **fixture), handle)
    return spend.collect(NOW, state if state is not None else {}, write, os.path.join(work, "home"), repos, root, lambda t: time.strftime("%Y-%m-%d", time.localtime(t)))


out = collect()
ids = [p["id"] for p in out["problems"]]
check(out["status"] == "watch" and out["index"] == 0.46 and out["change"] == "-54%" and "tone" not in out
      and out["head"] == "Fee index 0.46 (-54%%) · Fee 11.3 %% of spend · %d audits due" % len(ids)
      and ids == ["spend:menus", "spend:fee:Delegation", "spend:fee:Hooks", "spend:fee:Advisor"]
      and all(p["rule"] == "spend_audit" and p["state"] == "watch" and p["fact"].endswith("audit due: never audited")
              for p in out["problems"])
      and out["problems"][1]["fact"] == "7.5 % of Claude spend · Delegation (Workers) · Δ +33% · audit due: never audited",
      "the headline is tokenmap's harness index; the menus check and every Fee source never audited are due, the "
      "menus first, then by share of Claude spend: %s %s" % (out["head"], ids))
check(out["selection"] == ids and out["issues"][0] == [7.5, "Delegation (Workers)"],
      "the night's queue is every due audit, largest first; bin/doctor-fix takes its slot share: %s" % out["selection"])
stale_keys = [(r["id"], z) for r in json.load(open(os.path.join(root, "share", "spend-ledger.json")))["rows"]
              for z in r.get("prices") or {} if " · " not in z]
check(not stale_keys, "every recorded audit price is keyed the way part_prices keys it, or proof() never reads it: %s"
      % stale_keys)
check("`spend.selection` lists every due\n  audit" in open(os.path.join(root, "docs", "doctors-contract.md")).read(),
      "docs/doctors-contract.md describes spend.selection as the whole queue the code writes")
stale = collect(made=NOW - 27 * 3600)
check(stale["status"] == "nodata" and stale["index"] is None and stale["problems"] == [] and stale["selection"] == []
      and stale["head"].startswith("tracking.json stale since"),
      "a tracking.json past its stale_after_hours is nodata, never an old index as current: %s" % stale["head"])
missing = collect(index=False)
check(missing["status"] == "nodata" and missing["index"] is None and missing["problems"] == []
      and missing["head"] == "no harness_index in tracking.json",
      "a tracking.json without harness_index is nodata: %s" % missing["head"])
thin = collect(value=None)
check(thin["index"] is None and thin["head"].startswith("Fee index: too little use · ") and thin["problems"],
      "a null index has no value while its audits stay due: %s" % thin["head"])

menus, hooks = found["menus"], found["fee:Hooks"]
source = menu_files[0]
key = spend.repo_path(source, repos)
blob = spend.blobs([source])[source]
held = {spend.repo_path(s, repos): h for s, h in spend.blobs(menus["sources"]).items()}
row = {"id": "menus", "sources": dict(held), "share": 0.0}
check(key == "token-map/tokenmap/tracking.py" and spend.due(menus, None, held) == "never audited"
      and spend.due(menus, row, held) is None
      and spend.due(menus, row, dict(held, **{key: "0" * 40})) == "source changed"
      and spend.due(hooks, {"sources": {}, "share": hooks["basis"] / 1.5}, {}) == "share ×1.5 since audit"
      and spend.due(hooks, {"sources": {}, "share": hooks["basis"] / 1.4}, {}) is None
      and spend.due(hooks, {"sources": {}, "share": hooks["basis"]}, {}) is None,
      "due: never audited, a source blob moved, a share of Claude spend at 1.5x its audit share; unchanged is not "
      "due, and a Fee source, with no source file, is due only by its share")
check(spend.due(hooks, {"sources": {}, "share": 0.0}, {}) is None,
      "an audit recorded at share 0 is never due by share, not ×inf forever")
path = os.environ["PATH"]
os.environ["PATH"] = os.path.join(work, "no-git")
unhashed = spend.blobs([source])
os.environ["PATH"] = path
check(unhashed is None and spend.due(menus, row, None) is None
      and spend.due(hooks, {"sources": {key: None}, "share": hooks["basis"]}, {}) is None
      and spend.due(hooks, {"sources": {key: None}, "share": hooks["basis"]}, {key: blob}) == "source changed",
      "a git that cannot hash leaves every source unmoved, never all due at once; a source recorded absent (a cut "
      "deleted it) and still absent has not moved, one back has")

with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": [row, {"id": "fee:Hooks", "sources": {},
                                                       "share": hooks["basis"] / 2}]}, handle)
due_ids = {p["id"]: p["spend"]["due"] for p in collect()["problems"]}
check("spend:menus" not in due_ids and due_ids.get("spend:fee:Hooks") == "share ×2.0 since audit",
      "the collector reads its ledger: the checked unchanged menus leave the list, the risen share returns: %s" % due_ids)
with open(os.path.join(repos, "llm-legs", "bin", "code-doctor"), "w") as handle:
    handle.write("menu\n")
check({p["id"]: p["spend"]["due"] for p in collect()["problems"]}.get("spend:menus") == "source changed",
      "a new doctor is a menu change: the menus check is due again")
os.remove(os.path.join(repos, "llm-legs", "bin", "code-doctor"))
with open(source, "a") as handle:
    handle.write("# changed\n")
check({p["id"]: p["spend"]["due"] for p in collect()["problems"]}.get("spend:menus") == "source changed",
      "a changed menu file makes the menus check due again")

measured = out["problems"][0]
audited = {measured["spend"]["component"]: {"audited_at": stamp(spend.epoch(measured["last_seen"]) + 60)}}
check(spend.restate([measured], audited) == [] and spend.restate([measured], {}) == [measured]
      and spend.restate([measured], {measured["spend"]["component"]: {"audited_at": stamp(NOW - 7200)}}) == [measured],
      "a component audited after Spend measured it is settled for a night close; an older audit is not")

with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": []}, handle)
recorded = spend.record(root, os.path.join(work, "home"), repos, "fee:Hooks", "kept",
                        "fires rarely, every block changed the call", "removal saves 0.4 %; loses every block", "night-x", [])
checked = spend.record(root, os.path.join(work, "home"), repos, "menus", "kept", "every new row reaches a doctor",
                       "removal saves 0; loses the night's view of new menu rows", "night-x", [])
stored = json.load(open(ledger))["rows"]
index = json.load(open(os.environ["SPEND_TRACKING"]))["harness_index"]
check(stored == [recorded, checked] and recorded["verdict"] == "kept" and recorded["share"] == hooks["basis"]
      and recorded["zero"] == "removal saves 0.4 %; loses every block" and recorded["sources"] == {}
      and recorded["by"] == "night-x" and recorded["prices"] == {"Chat · Hooks": 300.0}
      and checked["sources"] == {spend.repo_path(s, repos): h for s, h in spend.blobs(menus["sources"]).items()}
      and checked["prices"] == {}
      and spend.part_prices(index, "fee:Delegation") == {"Workers · Delegation": [40.0, 50.0]},
      "the audit record holds the share at audit on the Claude-spend basis, the prices of the index cells the source "
      "is made of, by consumer and leaf, and for the menus check each menu file's blob: %s %s" % (recorded, checked))
try:
    spend.record(root, os.path.join(work, "home"), repos, "fee:Hooks", "maybe", "", "removal saves all", "", [])
    refused = False
except SystemExit:
    refused = True
check(refused, "a verdict other than cut, kept or trade is refused")
os.environ["SPEND_LEDGER"] = os.path.join(work, "bare-ledger.json")
bare = spend.record(root, os.path.join(work, "home"), repos, "loaded:Gone job", "cut", "its next run was bare",
                    "removal saves its share; loses nothing", "night-x", [])
try:
    spend.record(root, os.path.join(work, "home"), repos, "loaded:Gone job", "kept", "", "removal saves all", "", [])
    refused = False
except SystemExit:
    refused = True
os.environ["SPEND_LEDGER"] = ledger
check(bare["verdict"] == "cut" and bare["share"] == 0.0 and bare["sources"] == {} and refused,
      "a cut on a harness job whose next run was bare, and so left the index, is recorded; any other verdict "
      "on a component the index no longer holds is refused: %s" % bare)
import datetime
os.environ["SPEND_LEDGER"] = os.path.join(work, "dated-ledger.json")
dated = spend.record(root, os.path.join(work, "home"), repos, "fee:Hooks", "kept", "fires rarely",
                     "removal saves 0.4 %; loses every block", "night-x", [], depends_on="hooks stay under 0.5 %")
os.environ["SPEND_LEDGER"] = ledger
check(dated["depends_on"] == "hooks stay under 0.5 %" and "depends_on" not in bare and "reread_by" not in bare
      and dated["reread_by"] == (datetime.date.today() + datetime.timedelta(days=56)).isoformat(),
      "a kept audit says what it depends on and is re-read 8 weeks on, a cut neither: %s" % dated)
before_zero = open(ledger).read()
try:
    spend.record(root, os.path.join(work, "home"), repos, "fee:Hooks", "kept", "", " ", "", [])
    refused = False
except SystemExit:
    refused = True
check(refused and open(ledger).read() == before_zero,
      "an audit with no zero option (what removing the component saves and loses) is refused, nothing stored")
before_git = open(ledger).read()
os.environ["PATH"] = os.path.join(work, "no-git")
try:
    spend.record(root, os.path.join(work, "home"), repos, "menus", "kept", "", "removal saves all", "", [])
    refused = False
except SystemExit:
    refused = True
os.environ["PATH"] = path
check(refused and open(ledger).read() == before_git,
      "a git that cannot hash the sources refuses the record, never stores them absent (a cut) and due at once")
with open(ledger) as handle:
    kept = handle.read()
with open(ledger, "w") as handle:
    handle.write(kept.replace('"rows": [', '"rows": [\n<<<<<<< ours', 1))
broken = open(ledger).read()
try:
    spend.save_row(root, {"id": "fee:Hooks", "verdict": "kept"})
    refused = False
except SystemExit:
    refused = True
check(refused and open(ledger).read() == broken,
      "a ledger that is no JSON (merge conflict markers) refuses the record and keeps its rows, never overwritten")
with open(ledger, "w") as handle:
    handle.write(kept)
before = collect()
later = time.time() + 60
same, cheaper = (collect(made=later, hook_price=price)["proofs"].get("fee:Hooks") for price in (300.0, 150.0))
check(before["proofs"] == {} and any(l[3].endswith("· kept %s · not measured since" % recorded["audited_at"][:10])
                                     for l in before["menu"])
      and same == {"share": 1.0, "price": 1.0, "proven": False, "verdict": "kept", "audited_at": recorded["audited_at"]}
      and cheaper and cheaper["price"] == 0.5 and cheaper["share"] == 1.0 and cheaper["proven"],
      "an audit is proven once a measurement after it shows its share or its part's price lower: %s %s" % (same, cheaper))

sys.path.insert(0, os.path.join(root, "share"))
import time_budget
os.environ["HARNESS_DOCTOR_DIR"] = os.path.join(work, "harness")
os.makedirs(os.environ["HARNESS_DOCTOR_DIR"])
with open(os.path.join(work, "harness", "latest.json"), "w") as handle:
    json.dump({"speed": {"spend": {"proofs": {"fee:Hooks": cheaper}}}}, handle)
item = {"ref": "night-x", "class": time_budget.improvement_class("spend_audit", "spend:fee:Hooks"), "spend_m": 1.5,
        "lines": [3, 9], "merged": True}
check("spend_audit" in time_budget.IMPROVEMENT_RULES
      and time_budget.roi_lines([{"started": NOW - 86400, "hours": 2.0, "improvements": [item]}], NOW)
      == ["roi · night-x · fee:Hooks · 1.5M · +3/-9 lines · share ×1.0 · price ×0.5 of audit · proven"],
      "a night's Spend audit reads its proof in the roi lines, out of the minute totals")

fake = os.path.join(work, "tokenmap")
with open(os.path.join(work, "day.json"), "w") as handle:
    json.dump(payload(value=0.7), handle)
with open(fake, "w") as handle:
    handle.write('#!/bin/sh\necho "$*" >> %s/tokenmap.calls\ncat %s/day.json\n' % (work, work))
os.chmod(fake, 0o755)
day = lambda t: time.strftime("%Y-%m-%d", time.localtime(t))
shift = lambda d, n: (datetime.date.fromisoformat(d) + datetime.timedelta(days=n)).isoformat()
state = {}
collect(state=state, write=True)
check(state == {"index_by_day": {day(NOW - 3600): 0.46}, "index_definition": "d1", "index_closed": []}
      and not os.path.exists(os.path.join(work, "tokenmap.calls")),
      "a run stores the reading's index under its day; a fixture tracking.json with "
      "no fixture tokenmap never reaches the live index: %s" % state)
os.environ["SPEND_TOKENMAP"] = fake
first = collect(state=state, write=True)
missing_day = day(NOW - 86400)
calls = open(os.path.join(work, "tokenmap.calls")).read().splitlines()
check(state["index_by_day"] == {day(NOW - 3600): 0.46, missing_day: 0.7} and first["index_by_day"] == state["index_by_day"]
      and state["index_closed"] == [missing_day]
      and calls == ["tracking --since %s --until %s --json" % (shift(missing_day, -6), shift(missing_day, 1))],
      "one missing completed day a run from tokenmap's 7-day window ending it, stored as its index: %s %s"
      % (state["index_by_day"], calls))
collect(state=state, write=True)
check(len(state["index_closed"]) == 2 and len(open(os.path.join(work, "tokenmap.calls")).read().splitlines()) == 2,
      "the next run takes the next missing day: %s" % state["index_by_day"])
collect(state=state, write=False)
check(len(state["index_closed"]) == 2, "a read-only run backfills nothing")
failing = os.path.join(work, "tokenmap-failing")
with open(failing, "w") as handle:
    handle.write("#!/bin/sh\nexit 1\n")
os.chmod(failing, 0o755)
os.environ["SPEND_TOKENMAP"] = failing
collect(state=state, write=True)
os.environ["SPEND_TOKENMAP"] = fake
held_days = len(state["index_closed"])
collect(state=state, write=True)
check(held_days == 2 and len(state["index_closed"]) == 3 and None not in state["index_by_day"].values(),
      "a failed tokenmap run stores no day, so the next run retries it instead of a permanent gap: %s"
      % state["index_by_day"])

provisional = {"index_by_day": {missing_day: 0.46}, "index_definition": "d1"}
collect(state=provisional, write=True)
check(provisional["index_by_day"][missing_day] == 0.7 and provisional["index_closed"] == [missing_day],
      "a day read intraday is provisional: once it closes, the backfill replaces it with the closed day's value: %s"
      % provisional)

redefined = {"index_by_day": dict(state["index_by_day"]), "index_definition": "d1",
             "index_closed": list(state["index_closed"])}
collect(state=redefined, write=False, definition="d2")
check(redefined == {"index_by_day": {}, "index_definition": "d2", "index_closed": []},
      "history recorded under another index definition is dropped, never charted beside the new one: %s" % redefined)

with open(ledger, "w") as handle:
    json.dump({"owner": "Harness Doctor", "rows": []}, handle)
loader = importlib.machinery.SourceFileLoader("harness_doctor", os.path.join(root, "bin", "harness-doctor"))
h = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(h)
section = collect()
problems = section.pop("problems")
document = {"problem_count": 0, "status": "ok", "as_of_s": int(NOW), "title": "Harness doctor: ok", "problems": [],
            "sections": [], "footer": "as of now"}
h.apply_speed(document, {"problems": problems, "spend": section, "menu": [], "head": "x"}, {"rows": []})
lines = h.menu_text(document).splitlines()
header = json.loads(lines[1][2:])
spent = [p for p in document["problems"] if p["rule"] == "spend_audit"]
check(document["problem_count"] == 0 and spent and all(p["group"] == "Spend" and p["speed"] for p in spent)
      and lines[2].startswith("0\t\t\tLost time: ok")
      and "0\t\t\tSpend: watch · Fee index 0.46 (-54%%) · Fee 11.3 %% of spend · %d audits due" % len(spent) in lines
      and "1\t\t\tToken tracking and Doctors menus against what the night reads · audit due: never audited" in lines
      and "1\t\t\t7.5 % of Claude spend · Delegation (Workers) · Δ +33% · audit due: never audited" in lines
      and header["spend"] == {k: section[k] for k in ("as_of_s", "status", "index", "index_by_day", "change",
                                                      "issues")},
      "Harness lays Spend beside Lost time: watch rows counted nowhere, its block and its header: %s" % lines[:6])
print(count[0])
EOF
) || { printf 'FAIL: the Spend block misjudged its fixture\n' >&2; exit 1; }
# launchd and harness-doctor fall back to /usr/bin/python3, whose fromisoformat predates the Z suffix.
if [ -x /usr/bin/python3 ]; then
  /usr/bin/python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import spend
assert spend.epoch("2026-10-13T13:47:49Z") == spend.epoch("2026-10-13T13:47:49+00:00") is not None' "$ROOT/share" ||
    { printf 'FAIL: a Z-suffixed stamp reads as no time on /usr/bin/python3\n' >&2; exit 1; }
  asserts=$((asserts + 1))
fi

printf 'PASS: %s asserts; Spend heads with tokenmap'"'"'s harness index, audits the menus check and every Fee index source off tracking.json, reads stale or no index as nodata, judges audits due by never/source blob/1.5x share, selects one, settles an audited one for a night close, records audits with their proof and roi line and backfills one day a run\n' "$asserts"
