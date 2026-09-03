#!/usr/bin/env bash
# Fixture-based tests for the Fable-rework leaderboard.
#   bin/worker-stats     — aggregation math (fault/infra/retry/patch/dur/complexity),
#                          killed-exclusion, outlier guard, sanity markers, collect.
#   bin/worker-corpus     — outcome parsing, retry linkage, model-shape validation.
# The real LLM rater and worker-corpus extraction are mocked — no network, no claudeb.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/worker-stats"
CORPUS="$ROOT/bin/worker-corpus"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
contains() { grep -Fq -- "$2" <<<"$1"; }
not_contains() { ! grep -Fq -- "$2" <<<"$1"; }

export SCRIPT CORPUS

# --- part 1: leaderboard aggregation math ------------------------------------
SD="$WORK/state"
mkdir -p "$SD"

# Ledger (followups). complexity present on two gpt/high A rows -> medCplx 3.0.
# Global median over non-outlier A costs 100,200,300,500,1000 = 300.
# Duplicate tool_use_id in ledger (dedup test): a1 appears twice, keep last
cat >"$SD/ledger.jsonl" <<'JSONL'
{"tool_use_id":"a1","ts":"2026-07-15T01:00:00Z","worker":"codex-worker","model":"gpt","effort":"high","class":"B","fable_tokens_cycle":50,"complexity":1,"rater":"t"}
{"tool_use_id":"a1","ts":"2026-07-15T01:30:00Z","worker":"codex-worker","model":"gpt","effort":"high","class":"A","fable_tokens_cycle":100,"complexity":2,"rater":"t"}
{"tool_use_id":"a2","ts":"2026-07-15T02:00:00Z","worker":"codex-worker","model":"gpt","effort":"high","class":"A","fable_tokens_cycle":200,"complexity":4,"rater":"t"}
{"tool_use_id":"a3","ts":"2026-07-15T03:00:00Z","worker":"codex-worker","model":"gpt","effort":"high","class":"A","fable_tokens_cycle":300,"complexity":null,"rater":"t"}
{"tool_use_id":"b1","ts":"2026-07-15T04:00:00Z","worker":"codex-worker","model":"gpt","effort":"high","class":"B","fable_tokens_cycle":null,"complexity":null,"rater":"t"}
{"tool_use_id":"c1","ts":"2026-07-15T05:00:00Z","worker":"claudeb-worker","model":"opus","effort":"high","class":"A","fable_tokens_cycle":1000,"complexity":null,"rater":"t"}
{"tool_use_id":"e1","ts":"2026-07-15T07:00:00Z","worker":"codex-worker","model":"ghost","effort":"high","class":"A","fable_tokens_cycle":500,"complexity":null,"rater":"t"}
{"tool_use_id":"o1","ts":"2026-07-15T08:00:00Z","worker":"codex-worker","model":"out","effort":"high","class":"A","fable_tokens_cycle":60000,"complexity":null,"rater":"t"}
{"tool_use_id":"i1","ts":"2026-07-15T09:00:00Z","worker":"codex-worker","model":"inc","effort":"high","class":"B","fable_tokens_cycle":null,"complexity":null,"rater":"t"}
{"tool_use_id":"i2","ts":"2026-07-15T10:00:00Z","worker":"codex-worker","model":"inc","effort":"high","class":"B","fable_tokens_cycle":null,"complexity":null,"rater":"t"}
{"tool_use_id":"i3","ts":"2026-07-15T11:00:00Z","worker":"codex-worker","model":"inc","effort":"high","class":"B","fable_tokens_cycle":null,"complexity":null,"rater":"t"}
{"tool_use_id":"i4","ts":"2026-07-15T12:00:00Z","worker":"codex-worker","model":"inc","effort":"high","class":"B","fable_tokens_cycle":null,"complexity":null,"rater":"t"}
JSONL

# Delegations snapshot, generated for exact per-column math:
#   codex/gpt/high : 10 fresh (2 failed + 1 usage_limit -> infra 30%, 2 patched -> orchP 20%,
#                    all dur 90000 -> medDur 1.5m) + 1 killed (excluded from n) -> n=10
#   codex/gpt/low  : 1 fresh dispatch whose retry_of points into gpt/high -> gpt/high retry=1
#   claudeb/opus/high: 5 fresh -> n=5 (n<10)
#   codex/out/high : 4 fresh -> n=4
#   codex/inc/high : 3 fresh -> classified(4)>n(3) -> "!"
#   codex/ghost/high: 0 delegations (fault in ledger only) -> n=0
python3 - "$SD/delegations.jsonl" <<'PY'
import json,sys
rows=[]
def d(tid,model,effort,**kw):
    r={"tool_use_id":tid,"timestamp":"2026-07-15T00:00:00Z","subagent_type":"codex-worker",
       "model":model,"effort":effort,"is_resume":False,"outcome":"ok","duration_ms":90000,
       "retry_of":None,"worker_tokens":None,"orchestrator_patch":False}
    r.update(kw); rows.append(r)
for k in range(10):
    oc="ok"; patch=False
    if k<2: oc="failed"
    elif k==2: oc="usage_limit"
    if k in (3,4): patch=True
    d(f"g{k}","gpt","high",outcome=oc,orchestrator_patch=patch)
d("gk","gpt","high",outcome="killed",duration_ms=5000)   # killed -> excluded from n
d("R1","gpt","low",retry_of="g0")                        # retry pointing into gpt/high
for k in range(5): d(f"op{k}","opus","high",subagent_type="claudeb-worker")
for k in range(4): d(f"ou{k}","out","high")
for k in range(3): d(f"in{k}","inc","high")
# subagent_type must equal worker for claudeb rows
for r in rows:
    if r["model"]=="opus": r["subagent_type"]="claudeb-worker"
with open(sys.argv[1],"w") as f:
    for r in rows: f.write(json.dumps(r)+"\n")
PY

py() { WORKER_STATS_DIR="$SD" python3 - "$@" <<'PY'
import json,sys,subprocess,os
data=json.loads(subprocess.check_output([os.environ["SCRIPT"],"--json"]))
rows={f"{r['worker']}/{r['model']}/{r['effort']}":r for r in data["rows"]}
v=rows[sys.argv[1]][sys.argv[2]]
print("None" if v is None else (round(v,3) if isinstance(v,float) else v))
PY
}
out=$(WORKER_STATS_DIR="$SD" "$SCRIPT" --json) || fail "worker-stats --json failed"

# core fault math
assert test "$(py codex-worker/gpt/high n_delegations)" = 10   # killed excluded
assert test "$(py codex-worker/gpt/high fault)" = 3
assert test "$(py codex-worker/gpt/high planned)" = 1
assert test "$(py codex-worker/gpt/high fault_rate)" = 0.3
assert test "$(py codex-worker/gpt/high median_fault_cost)" = 200
assert test "$(py codex-worker/gpt/high expected_overhead)" = 60.0
assert test "$(py codex-worker/gpt/high low_confidence)" = False
# new columns
assert test "$(py codex-worker/gpt/high infra_rate)" = 0.3       # (2 failed + 1 usage_limit)/10
assert test "$(py codex-worker/gpt/high orch_patch_rate)" = 0.2
assert test "$(py codex-worker/gpt/high median_duration_ms)" = 90000.0
assert test "$(py codex-worker/gpt/high median_complexity)" = 3.0
assert test "$(py codex-worker/gpt/high retries)" = 1            # R1's retry_of lands here
# n<10 + expected overhead for a small row
assert test "$(py claudeb-worker/opus/high low_confidence)" = True
assert test "$(py claudeb-worker/opus/high expected_overhead)" = 200.0
# outlier guard: 60000 excluded from median (global fallback 300), still counted as fault
assert test "$(py codex-worker/out/high fault)" = 1
assert test "$(py codex-worker/out/high median_from_global)" = True
assert test "$(py codex-worker/out/high expected_overhead)" = 75.0
assert test "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cost_outliers_excluded"])')" = 1
# n=0 row with a fault: prints, fault_rate null, infra/orch null, EO 0
assert test "$(py codex-worker/ghost/high n_delegations)" = 0
assert test "$(py codex-worker/ghost/high fault_rate)" = None
assert test "$(py codex-worker/ghost/high infra_rate)" = None
assert test "$(py codex-worker/ghost/high expected_overhead)" = 0.0
# classified > n -> inconsistent
assert test "$(py codex-worker/inc/high inconsistent)" = True
assert test "$(py codex-worker/gpt/high inconsistent)" = False

# sorting: opus 200 > out 75 > gpt 60 > zeros; n=0 row last
order=$(WORKER_STATS_DIR="$SD" python3 - <<'PY'
import json,subprocess,os
data=json.loads(subprocess.check_output([os.environ["SCRIPT"],"--json"]))
print(" ".join(f"{r['worker']}/{r['model']}/{r['effort']}" for r in data["rows"]))
PY
)
assert test "$(awk '{print $1}' <<<"$order")" = "claudeb-worker/opus/high"
assert test "$(awk '{print $2}' <<<"$order")" = "codex-worker/out/high"
assert test "$(awk '{print $3}' <<<"$order")" = "codex-worker/gpt/high"
assert test "$(awk '{print $NF}' <<<"$order")" = "codex-worker/ghost/high"

# table: legend, footnote, humanized duration, — and ! markers, width <=120
table=$(WORKER_STATS_DIR="$SD" "$SCRIPT")
assert contains "$table" 'footnote: 1 cost samples excluded as outliers >50k'
assert contains "$table" '1.5m'
assert contains "$table" '—'
assert contains "$(grep 'codex-worker/inc/high' <<<"$table")" '!'
assert test "$(sed -n '2p' <<<"$table" | awk '{print length}')" -le 120

# --- part 2: staleness hint --------------------------------------------------
touch -t "$(date -v-5d +%Y%m%d%H%M 2>/dev/null || date -d '5 days ago' +%Y%m%d%H%M)" "$SD/ledger.jsonl"
assert contains "$(WORKER_STATS_DIR="$SD" "$SCRIPT")" 'hint: ledger is'
touch "$SD/ledger.jsonl"
assert not_contains "$(WORKER_STATS_DIR="$SD" "$SCRIPT")" 'hint: ledger is'

# --- part 3: collect subcommand (mocked corpus + rater) ----------------------
MOCK_CORPUS="$WORK/mock-corpus"
cat >"$MOCK_CORPUS" <<'PY'
#!/usr/bin/env python3
import sys,json
out=None
a=sys.argv
for i,x in enumerate(a):
    if x=="--out": out=a[i+1]
def deleg(tid):
    return {"type":"delegation","tool_use_id":tid,"timestamp":"2026-07-15T01:00:00Z",
            "subagent_type":"codex-worker","model":"gpt-5.6-sol","effort":"high","is_resume":False,
            "outcome":"ok","duration_ms":1000,"retry_of":None,"worker_tokens":10,"orchestrator_patch":False,
            "prompt_head":"build the thing","result_head":"OUTCOME: done"}
def fu(tid,pid,brief):
    return {"type":"followup","tool_use_id":tid,"timestamp":"2026-07-16T01:00:00Z",
            "subagent_type":"codex-worker","parent_tool_use_id":pid,"model":None,"effort":None,
            "account":None,"is_resume":True,"fable_tokens_cycle":5000,
            "brief_text_masked":brief,"parent_brief_head_masked":"build a thing"}
recs=[deleg("p1"),deleg("p2"),
      fu("f1","p1","please fix the broken build now"),
      fu("f2","p2","again, fix the broken build")]
with open(out,"w") as f:
    for r in recs: f.write(json.dumps(r)+"\n")
PY
chmod +x "$MOCK_CORPUS"

MOCK_CLAUDEB="$WORK/mock-claudeb"
cat >"$MOCK_CLAUDEB" <<'PY'
#!/usr/bin/env python3
import os,json
mode=os.environ.get("MOCK_MODE","valid")
if mode=="badquote":
    inner={"class":"A","quote":"NOT PRESENT IN ANY BRIEF","reason":"x","complexity":3}
elif mode=="badcplx":
    inner={"class":"A","quote":"fix the broken build","reason":"x","complexity":9}
elif mode=="shortquote":
    inner={"class":"A","quote":"fix","reason":"x","complexity":3}
elif mode=="infra":
    exit(1)
else:
    inner={"class":"A","quote":"fix the broken build","reason":"broken build","complexity":3}
print(json.dumps({"result":json.dumps(inner),"session_id":"mock-sess-123","type":"result"}))
PY
chmod +x "$MOCK_CLAUDEB"

run_collect() {
  WORKER_STATS_DIR="$CSD" WORKER_CORPUS_BIN="$MOCK_CORPUS" CLAUDEB_BIN="$MOCK_CLAUDEB" \
    MOCK_MODE="${1:-valid}" "$SCRIPT" collect --since 2026-07-14 --until 2026-07-17
}

# valid: verbatim (null) config, complexity captured, snapshot written
CSD="$WORK/collect-valid"
preview=$(run_collect valid)
assert contains "$preview" '2 new followups to classify'
assert contains "$preview" 'paid by claudeb rotation'
assert test "$(wc -l <"$CSD/ledger.jsonl")" -eq 2
first=$(head -n1 "$CSD/ledger.jsonl")
assert contains "$first" '"class": "A"'
assert contains "$first" '"model": null'          # VERBATIM followup field, not parent gpt-5.6-sol
assert not_contains "$first" 'gpt-5.6-sol'
assert contains "$first" '"complexity": 3'
assert test -f "$CSD/delegations.jsonl"
assert test "$(wc -l <"$CSD/delegations.jsonl")" -eq 2
# auditability fields carried verbatim into the snapshot
assert contains "$(head -n1 "$CSD/delegations.jsonl")" '"prompt_head": "build the thing"'
assert contains "$(head -n1 "$CSD/delegations.jsonl")" '"result_head": "OUTCOME: done"'

# idempotent round-trip: re-collect adds 0 followups, snapshot deduped
again=$(run_collect valid)
assert contains "$again" '0 new followups to classify'
assert test "$(wc -l <"$CSD/ledger.jsonl")" -eq 2
assert test "$(wc -l <"$CSD/delegations.jsonl")" -eq 2

# quote-validation fallback -> C/rater-invalid, complexity null
CSD="$WORK/collect-badquote"
run_collect badquote >/dev/null
assert contains "$(head -n1 "$CSD/ledger.jsonl")" '"class": "C"'
assert contains "$(head -n1 "$CSD/ledger.jsonl")" '"reason": "rater-invalid"'
assert contains "$(head -n1 "$CSD/ledger.jsonl")" '"complexity": null'

# short quote (<15 chars) -> C/rater-invalid
CSD="$WORK/collect-shortquote"
run_collect shortquote >/dev/null
assert contains "$(head -n1 "$CSD/ledger.jsonl")" '"class": "C"'
assert contains "$(head -n1 "$CSD/ledger.jsonl")" '"reason": "rater-invalid"'

# complexity out of 1-5 range -> null, but a valid class is kept
CSD="$WORK/collect-badcplx"
run_collect badcplx >/dev/null
assert contains "$(head -n1 "$CSD/ledger.jsonl")" '"class": "A"'
assert contains "$(head -n1 "$CSD/ledger.jsonl")" '"complexity": null'

# infra failure (rater exits non-zero) -> don't write, don't mark as seen
CSD="$WORK/collect-infra"
infra_out=$(run_collect infra)
assert contains "$infra_out" '2 new followups to classify'
assert contains "$infra_out" 'appended 0 followups'
assert test ! -f "$CSD/ledger.jsonl"

# atomic write: no .tmp left on success
CSD="$WORK/collect-atomic"
run_collect valid >/dev/null
assert test ! -f "$CSD/delegations.jsonl.tmp"
assert test -f "$CSD/delegations.jsonl"

# arg parsing: --account names payer; --dry-run writes nothing
CSD="$WORK/collect-args"
args_out=$(WORKER_STATS_DIR="$CSD" WORKER_CORPUS_BIN="$MOCK_CORPUS" CLAUDEB_BIN="$MOCK_CLAUDEB" \
  "$SCRIPT" collect --since 2026-07-01 --until 2026-07-02 --account alona --dry-run)
assert contains "$args_out" 'window 2026-07-01..2026-07-02'
assert contains "$args_out" 'paid by alona'
assert contains "$args_out" 'nothing written'
assert test ! -f "$CSD/ledger.jsonl"

# --- part 4: worker-corpus extraction unit tests + timestamp handling ---------
WORKER_STATS_DIR="$SD" python3 - "$CORPUS" <<'PY'
import importlib.util,importlib.machinery,sys
loader=importlib.machinery.SourceFileLoader("wc",sys.argv[1])
spec=importlib.util.spec_from_loader("wc",loader)
wc=importlib.util.module_from_spec(spec); loader.exec_module(wc)

def check(cond,msg):
    if not cond: print("SUBFAIL:",msg); sys.exit(1)

# timestamp-less event does not crash parse_ts or compute_fable_tokens_cycle
check(wc.parse_ts(None) is None, "parse_ts(None)")
check(wc.parse_ts("") is None, "parse_ts(empty)")
check(wc.parse_ts("2026-07-15T01:00:00Z") is not None, "parse_ts valid")
try:
    followups=[{"session_id":"s","timestamp":"","parent_tool_use_id":"p"}]
    delegations=[]
    wc.compute_fable_tokens_cycle(followups, delegations, [])
    check(True, "compute_fable_tokens_cycle handles empty timestamp")
except ValueError:
    check(False, "compute_fable_tokens_cycle crashed on empty timestamp")

# outcome parsing
check(wc.classify_outcome({"status":"completed","result_text":"all good"},None)=="ok","ok")
check(wc.classify_outcome({"status":"completed","result_text":"x OUTCOME: CODEX_USAGE_LIMIT y"},None)=="usage_limit","codex limit")
check(wc.classify_outcome({"status":"completed","result_text":"x OUTCOME: GROK_USAGE_LIMIT y"},None)=="usage_limit","grok limit")
check(wc.classify_outcome({"status":"completed","result_text":"x OUTCOME: GEMINI_USAGE_LIMIT y"},None)=="usage_limit","gemini limit")
check(wc.classify_outcome({"status":"killed","result_text":""},None)=="killed","killed")
check(wc.classify_outcome({"status":"stopped","result_text":""},None)=="killed","stopped->killed")
check(wc.classify_outcome({"status":"failed","result_text":""},None)=="failed","failed status")
check(wc.classify_outcome({"status":"completed","result_text":"OUTCOME: FAILED boom"},None)=="failed","failed sig")
check(wc.classify_outcome({"status":"completed","result_text":"OUTCOME: ❌ FAILED: build broken"},None)=="failed","emoji failed verdict")
# tightened: benign lines containing fail/error/traceback words are NOT failures
check(wc.classify_outcome({"status":"completed","result_text":"OUTCOME: done. All green, 0 errors"},None)=="ok","0 errors is ok")
check(wc.classify_outcome({"status":"completed","result_text":"OUTCOME: partially failed (real issues found, not a run failure)"},None)=="ok","review-found issues is ok")
check(wc.classify_outcome({"status":"completed","result_text":"we discussed the Traceback (most recent call last) we already fixed"},None)=="ok","traceback prose is ok")
check(wc.classify_outcome(None,"Async agent launched successfully. agentId: x")is None,"async stub -> None")
check(wc.classify_outcome(None,"OUTCOME: CLAUDEB_USAGE_LIMIT")=="usage_limit","sync usage limit")
check(wc.classify_outcome(None,"plain sync ok")=="ok","sync ok")

# model-shape validation
check(wc.valid_model("gpt-5.6-sol")=="gpt-5.6-sol","gpt ok")
check(wc.valid_model("opus")=="opus","opus ok")
check(wc.valid_model("sonnet")=="sonnet","sonnet ok")
# grok's served model is the id its `end` event reports, which is not the id the launch asked for.
check(wc.valid_model("grok-4.6-build")=="grok-4.6-build","grok served model ok")
check(wc.valid_model("grok-4.5")=="grok-4.5","grok model ok")
check("grok-worker" in wc.WORKER_TYPES,"grok-worker is a corpus worker type")
check("gemini-worker" in wc.WORKER_TYPES,"gemini-worker is a corpus worker type")
# A blind rater may not read which vendor produced the work it is grading.
masked=wc.mask_worker_names("grok-worker ran Grok on the grok pool")
check("grok" not in masked.lower(),f"grok survived masking: {masked}")
masked_g=wc.mask_worker_names("gemini-worker ran Gemini on the gemini pool")
check("gemini" not in masked_g.lower(),f"gemini survived masking: {masked_g}")
stats=wc.recover_sidechain_config([
    {"subagent_type":"grok-worker","session_id":"s","brief_text":"x","model":None,"effort":None,"account":None},
    {"subagent_type":"codex-worker","session_id":"s","brief_text":"x","model":None,"effort":None,"account":None},
    {"subagent_type":"gemini-worker","session_id":"s","brief_text":"x","model":None,"effort":None,"account":None},
], [])
for vendor in ("grok","gemini","codex","claudeb"):
    check(vendor in stats, f"recovery_stats missing {vendor}")
# The native Sonnet subagent is retired: implementation runs on a relay worker's account only. The
# corpus still READS its rows — a `--since` reaching back before the cut would otherwise lose that
# history without saying so — and only stops offering it as something to dispatch to.
check("sonnet-worker" not in wc.DISPATCH_WORKER_TYPES,"sonnet-worker is still a dispatch target")
check("sonnet-worker" in wc.WORKER_TYPES,"sonnet-worker rows are no longer read as history")
check(wc.DISPATCH_WORKER_TYPES < wc.WORKER_TYPES,"the dispatch set is not a subset of the read set")
check("WORKER" == wc.mask_worker_names("sonnet-worker"),"a retired type survives blind-rater masking")
sonnet_stats=wc.recover_sidechain_config([
    {"subagent_type":"sonnet-worker","session_id":"s","brief_text":"x","model":None,"effort":None,"account":None},
], [])
check(sonnet_stats["sonnet"]["total"]==1,"a retired worker's historical row was dropped from recovery stats")
check(stats["grok"]["total"]==1 and stats["codex"]["total"]==1 and stats["gemini"]["total"]==1,
      "grok/codex/gemini delegations were not counted in their own buckets")
check(stats["claudeb"]["total"]==0,"non-claudeb workers were folded into claudeb recovery")
import io
from contextlib import redirect_stdout
buf=io.StringIO()
try:
    with redirect_stdout(buf):
        wc.output_records([], [], None)
        print("still-open")
    check("still-open" in buf.getvalue(),"output_records closed stdout")
except ValueError as exc:
    check(False, f"output_records closed stdout: {exc}")
for junk in ("py_compile","pytest","transcriber.ctl","http.server","3"):
    check(wc.valid_model(junk)is None,f"junk {junk}")

# retry linkage: near-duplicate fresh dispatch after a failed one -> retry_of set
def dl(tid,brief,outcome="ok",resume=False,attach=False,attached_run=None,reported_runs=()):
    return {"tool_use_id":tid,"session_id":"s","timestamp":tid,"subagent_type":"codex-worker",
            "is_resume":resume,"is_attach":attach,"brief_text":brief,"outcome":outcome,
            "retry_of":None,"attached_run":attached_run,"_reported_runs":list(reported_runs)}
brief="Fix the login bug in the auth module and add regression tests for it."
ds=[dl("1",brief,outcome="failed"),
    dl("2",brief+" (again)"),
    dl("3","Completely unrelated: write a haiku about clouds and rivers.")]
wc.link_retries(ds)
check(ds[1]["retry_of"]=="1","retry links to earlier failed twin")
check(ds[2]["retry_of"]is None,"dissimilar brief not a retry")
# an earlier delegation with outcome ok is not a retry source
ds2=[dl("1",brief,outcome="ok"),dl("2",brief+" (again)")]
wc.link_retries(ds2)
check(ds2[1]["retry_of"]is None,"ok outcome is not an infra retry source")
# An ATTACH re-attaches to a run already in flight: it launches nothing, so it is neither a fresh
# dispatch nor a retry of the run it is waiting on — it is that dispatch's followup.
ds3=[dl("1",brief,outcome="failed"),
     dl("2","ATTACH cb-1788280367-68398-037f: keep waiting and report.",attach=True)]
wc.link_retries(ds3)
check(ds3[1]["retry_of"]is None,"an ATTACH re-attach was counted as a silent retry")
for d in ds3:
    d.setdefault("_reported_sessions",[])
    d["resumed_session"]=None
fu=wc.link_followups(ds3)
check(len(fu)==1 and fu[0]["tool_use_id"]=="2" and fu[0]["parent_tool_use_id"]=="1",
      f"an ATTACH did not become a followup of the dispatch it re-attaches to: {fu}")
# And it belongs to the run it NAMES, not to whichever dispatch happens to be nearest: a relay
# reports its run id, so an attach reaching back past a newer run of the same worker still lands on
# the dispatch that started the one it is waiting on.
old_run="cb-1788280367-68398-037f"
new_run="cb-1788280999-68398-0a0a"
check(wc.RUN_ID_RE.findall(f"STATUS: running RUN: {old_run} ELAPSED: 9m")==[old_run],
      "RUN_ID_RE did not read a run id out of a relay's own status report")
ds4=[dl("1",brief,reported_runs=[old_run]),
     dl("2","Another task entirely.",reported_runs=[new_run]),
     dl("3",f"ATTACH {old_run}: keep waiting and report.",attach=True,attached_run=old_run)]
for d in ds4:
    d.setdefault("_reported_sessions",[])
    d["resumed_session"]=None
fu4=wc.link_followups(ds4)
check(len(fu4)==1 and fu4[0]["parent_tool_use_id"]=="1",
      f"an ATTACH was attributed to the nearest dispatch instead of the run it names: {fu4}")
# Nothing reported that run id: the nearest earlier dispatch is still the best answer there is.
ds5=[dl("1",brief),
     dl("2",f"ATTACH {old_run}: keep waiting and report.",attach=True,attached_run=old_run)]
for d in ds5:
    d.setdefault("_reported_sessions",[])
    d["resumed_session"]=None
fu5=wc.link_followups(ds5)
check(len(fu5)==1 and fu5[0]["parent_tool_use_id"]=="1",
      f"an unreported run id lost the nearest-dispatch fallback: {fu5}")
print("corpus-unit-ok")
PY
assert test "$?" -eq 0

# worker-stats helper units
python3 - "$SCRIPT" <<'PY'
import importlib.util,importlib.machinery,sys
loader=importlib.machinery.SourceFileLoader("ws",sys.argv[1])
spec=importlib.util.spec_from_loader("ws",loader)
ws=importlib.util.module_from_spec(spec); loader.exec_module(ws)
assert ws.valid_complexity(3)==3
assert ws.valid_complexity(1)==1 and ws.valid_complexity(5)==5
assert ws.valid_complexity(0) is None and ws.valid_complexity(9) is None
assert ws.valid_complexity("x") is None and ws.valid_complexity(None) is None
assert ws.humanize_ms(None)=="-"
assert ws.humanize_ms(90000)=="1.5m"
assert ws.humanize_ms(850)=="850ms"
assert ws.humanize_ms(2500)=="2.5s"
print("ws-unit-ok")
PY
assert test "$?" -eq 0

printf 'PASS: %s assertions; leaderboard aggregation (fault/infra/retry/orchP/medDur/medCplx/n<10/sort/killed-excl/outlier/!/dedup), staleness hint, collect (verbatim/complexity/dedupe/fallback/args/infra-unseen/atomic-write/shortquote), worker-corpus outcome+retry+model-shape+timestamp units, a read set that keeps retired workers as history while the dispatch set drops them, and an ATTACH re-attach linked as a followup of the dispatch that started the RUN IT NAMES — nearest-dispatch only where nothing reported that run id — instead of counted as a fresh dispatch\n' "$asserts"
