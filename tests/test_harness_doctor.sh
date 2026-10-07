#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/harness-doctor over a fixture HOME: transcript waits, hook cut attribution, levels, the tests
# journal, steps against the change log, the local_slow windows LLM doctor reads, incremental
# reads, the lock and the laid-out menu lines.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
. "$ROOT/share/test-scope.sh"
PROJECTS=$(git_projects "$ROOT")
DOCTOR="$ROOT/bin/harness-doctor"
# project_of names /private/tmp and /private/var paths "tmp", so the fixture repos must sit on the
# unresolved /var/folders path.
WORK=$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)hd.XXXXXX")
trap '[ -z "${reused_pid:-}" ] || kill "$reused_pid" 2>/dev/null; rm -rf "$WORK"' EXIT
unset RUN_SUITES_SLOTS_DIR XDG_CACHE_HOME
export TZ=UTC HOME="$WORK/home"
export CLAUDE_PROJECTS_DIR="$HOME/.claude/projects" HARNESS_SETTINGS="$HOME/.claude/settings.json"
export STATUSLINE_CACHE_DIR="$WORK/statusline" MEMLOGD_DIR="$WORK/memlogd" INSTRUCTION_WATCH_STATE="$WORK/watch"
export CLAUDEB_DIR="$WORK/claudeb" HARNESS_WATCH_ROOTS="$HOME/hooks" HARNESS_DOCTOR_DIR="$WORK/state"
export HARNESS_LEDGER="$WORK/ledger.json" HARNESS_REPOS_DIR="$WORK"
export DOCTORS_DIR="$WORK/doctors" HARNESS_DOCTOR_BOOTS= DOCTOR_TRIGGER=fixture
export WORKER_RUN_DIR="$WORK/runs" HARNESS_BROWSE_CMD="$WORK/browse-stub"
cat >"$HARNESS_BROWSE_CMD" <<EOF
#!/bin/sh
echo "\$@" >"$WORK/browse-calls"
touch "$WORK/runs/browse/canary.stamp"
EOF
chmod +x "$HARNESS_BROWSE_CMD"
cp "$ROOT/share/harness-ledger.json" "$HARNESS_LEDGER"
mkdir -p "$HOME/hooks" "$CLAUDE_PROJECTS_DIR" "$STATUSLINE_CACHE_DIR" "$MEMLOGD_DIR" "$CLAUDEB_DIR"
for repo in alpha beta gamma; do git init -q "$WORK/$repo"; done
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "assert $asserts ($3): expected '$1', got '$2'"; }

T=$(( $(date +%s) / 86400 * 86400 + 43200 ))
printf 'renice -n 10 $$\n' > "$HOME/hooks/prompt-nice.sh"
printf 'nice -n 5 true\n' > "$HOME/hooks/stop-niced.sh"
for name in post-slow post-fast post-edit pre-slow; do printf 'true\n' > "$HOME/hooks/$name.sh"; done
touch -d "$(date -u -r $((T - 30 * 86400)) +%Y-%m-%dT%H:%M:%S)" "$HOME"/hooks/*.sh
cat > "$HARNESS_SETTINGS" <<'EOF'
{"hooks": {
  "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/hooks/post-slow.sh", "timeout": 10},
                                                {"type": "command", "command": "~/hooks/post-fast.sh", "timeout": 60}]},
                  {"matcher": "Edit", "hooks": [{"type": "command", "command": "~/hooks/post-edit.sh", "timeout": 10}]}],
  "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/hooks/pre-slow.sh", "timeout": 5}]}],
  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/hooks/prompt-nice.sh"}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "~/hooks/stop-niced.sh", "timeout": 30}]}]
}}
EOF

python3 - "$WORK" "$T" <<'EOF'
import json, os, sys, time
work, T = sys.argv[1], int(sys.argv[2])
projects = os.path.join(work, "home", ".claude", "projects")

def stamp(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int(round((t % 1) * 1000))

class Session:
    def __init__(self, path, cwd, entry, mode):
        self.path, self.cwd, self.entry, self.lines, self.n = path, cwd, entry, [], 0
        if mode:
            self.lines.append({"type": "permission-mode", "permissionMode": mode})
    def base(self, t):
        return {"timestamp": stamp(t), "cwd": self.cwd, "entrypoint": self.entry, "version": "9.9.9"}
    def use(self, t, name, command=None):
        self.n += 1
        tid = "toolu_%s_%03d" % (os.path.basename(self.path)[:6], self.n)
        block = {"type": "tool_use", "id": tid, "name": name, "input": {"command": command} if command else {}}
        self.lines.append(dict(self.base(t), type="assistant", message={"content": [block]}))
        return tid
    def result(self, t, tid):
        self.lines.append(dict(self.base(t), type="user",
                               message={"content": [{"type": "tool_result", "tool_use_id": tid}]}))
    def call(self, t, secs, name="Bash", command="ls -la"):
        tid = self.use(t, name, command)
        self.result(t + secs, tid)
        return tid
    def hook(self, t, **attachment):
        self.lines.append(dict(self.base(t), type="attachment", attachment=attachment))
    def write(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "w") as handle:
            handle.write("".join(json.dumps(l) + "\n" for l in self.lines))

alpha = Session(os.path.join(projects, "-alpha", "s1.jsonl"), work + "/alpha/.claude/worktrees/feat", "cli",
                "bypassPermissions")
for i in range(20):
    alpha.call(T - 30 * 3600 + i * 60, 1.5)
for i in range(6):
    alpha.call(T - 3000 + i * 250, 8.0)
alpha.call(T - 2900, 40.0, command="make build")
alpha.call(T - 2800, 0.5, command="grep -r needle .")
for t in (T - 2000, T - 1500, T - 1200, T - 900):
    tid = alpha.call(t, 11.0, command="echo hi 2>/dev/null | wc -l")
    alpha.hook(t + 11, type="hook_cancelled", hookEvent="PostToolUse", hookName="PostToolUse:Bash", toolUseID=tid)
for i in range(5):
    t = T - 800 + i * 20
    tid = alpha.use(t, "Bash", "pwd")
    alpha.hook(t + 2.5, type="hook_success", hookEvent="PreToolUse", hookName="PreToolUse:Bash", toolUseID=tid,
               command="~/hooks/pre-slow.sh", durationMs=2500)
    alpha.result(t + 3, tid)
alpha.call(T - 600, 0.5, name="Edit", command=None)
alpha.call(T - 500, 0.5, name="Edit", command=None)
with open(os.path.join(work, "pending-tid"), "w") as handle:
    handle.write(alpha.use(T - 20, "Bash", "cat pending.txt"))
alpha.write()

beta = Session(os.path.join(projects, "-beta", "s2.jsonl"), work + "/beta", "cli", "default")
for i in range(6):
    beta.call(T - 3000 + i * 200, 30.0)
beta.write()

gamma = Session(os.path.join(projects, "-alpha", "s1", "subagents", "agent-1.jsonl"), work + "/gamma", "sdk-cli", None)
for i in range(5):
    gamma.call(T - 3000 + i * 200, 1.0)
gamma.write()

with open(os.path.join(work, "statusline", "test-history.jsonl"), "w") as handle:
    rows = [{"end": T - d * 86400, "secs": 300, "who": "chat", "repo": "alpha", "label": "suites"} for d in (3, 2, 1)]
    rows.append({"end": T - 100, "secs": 1500, "who": "chat", "repo": "alpha", "label": "suites"})
    rows += [{"end": T - 300, "secs": 100, "who": "worker", "repo": "gamma", "label": "suites"}] * 5
    rows += [{"end": T - d * 86400, "secs": 300, "who": "chat", "repo": "delta", "label": "test_gone"} for d in (3, 2, 1)]
    rows.append({"end": T - 7 * 3600, "secs": 1500, "who": "chat", "repo": "delta", "label": "test_gone"})
    handle.write("".join(json.dumps(r) + "\n" for r in rows) + "torn line\n")
os.utime(os.path.join(work, "home", ".claude", "settings.json"), (T - 1800, T - 1800))

journal = os.path.join(work, "state")
os.makedirs(os.path.join(journal, "hooks", "spool"))
os.makedirs(os.path.join(journal, "statusline"))
with open(os.path.join(journal, "hooks", "%d.tsv" % (T // 86400)), "w") as handle:
    for i in range(6):
        end = (T - 3000 + i * 300) * 1000000
        handle.write("%d\t%d\tpost-fast.sh\t0\t77\n" % (end - 1200000, end))
    handle.write("%d\t%d\tpost-fast.sh\t0" % (T * 1000000, T * 1000000))
spool = os.path.join(journal, "hooks", "spool", "1.1")
with open(spool, "w") as handle:
    handle.write("post-edit.sh\t0\t77\t4200\n")
# utime can only move a birth time back, so the spool run is pinned before today 00:00 UTC.
born = T - 43260
os.utime(spool, (born, born))
os.utime(spool, (born + 0.6, born + 0.6))
with open(os.path.join(journal, "statusline", time.strftime("%Y-%m-%d", time.localtime(T)) + ".tsv"), "w") as handle:
    handle.write("".join("%d\t%d\ts1\n" % ((T - 600 + i) * 1000000, (T - 600 + i) * 1000000 + 80000)
                         for i in range(3)))
os.makedirs(os.path.join(journal, "menu"))
with open(os.path.join(journal, "menu", time.strftime("%Y-%m-%d", time.localtime(T)) + ".tsv"), "w") as handle:
    handle.write("".join("%d\t%d\tllm-limits\n" % ((T - 900 + i) * 1000000, (T - 900 + i) * 1000000 + 40000)
                         for i in range(3)))
os.makedirs(os.path.join(journal, "days"))
with open(os.path.join(journal, "days", time.strftime("%Y-%m-%d", time.gmtime(T - 9 * 86400)) + ".json"), "w") as handle:
    json.dump({"v": 2, "slow_s": 0, "waits": {"bash:alpha": [30, 15000, 500, 500, 0, 0, [0] * 11 + [30]]}}, handle)
with open(os.path.join(journal, "days", time.strftime("%Y-%m-%d", time.gmtime(T - 4 * 86400)) + ".json"), "w") as handle:
    json.dump({"v": 2, "slow_s": 0, "waits": {"edit": [30, 30000, 1000, 1000, 0, 0, [0] * 13 + [30]]}}, handle)
with open(os.path.join(journal, "samples.jsonl"), "w") as handle:
    for t in range(T - 6 * 3600 + 300, T - 3600, 300):
        busy, visible = (0.95, 9) if t <= T - 3 * 3600 else (0.3, 2.5)
        handle.write(json.dumps({"t": t, "busy": busy, "kernel": 0.35, "forks": 500, "ncpu": 10,
                                 "visible": visible}) + "\n")
EOF

sample() { printf '{"busy":%s,"kernel":0.35,"forks":500,"ncpu":10,"visible":%s,"guard":%s,"tests":0,"swap_mb":100,"swap_total_mb":1000}' "$@"; }
doc() { jq -c "$1" "$HARNESS_DOCTOR_DIR/latest.json"; }
rowq() { printf '.sections[] | select(.name == "%s") | .rows[] | select(.cells[0] | startswith("%s"))' "$1" "$2"; }

HARNESS_DOCTOR_NOW=$T HARNESS_DOCTOR_FAKE_SAMPLE=$(sample 0.89 8 false) "$DOCTOR" --quiet || fail "first run failed"

assert_eq '[true,true,0]' \
  "$(doc '[(.timing.phases | has("transcripts") and has("hook_runs") and has("judge")), (.timing.cpu_s | type == "number"), .timing.sleep_s]')" \
  "the document times each collector phase, its CPU apart, and no sampler sleep on a fake sample"
assert_eq '["cpu_s","doctor","start","trigger","wall_s"] harness true fixture 1' \
  "$(jq -sr '.[-1] as $r | "\($r | keys | tojson) \($r.doctor) \($r.start > 1e9) \($r.trigger) \(length)"' \
     "$DOCTORS_DIR/collector-runs.jsonl")" \
  "a persisting run appends its C10 row to collector-runs.jsonl"
HARNESS_DOCTOR_NOW=$T HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --json >/dev/null
assert_eq 1 "$(wc -l < "$DOCTORS_DIR/collector-runs.jsonl" | tr -d ' ')" "a --json run persists no C10 row"

mkdir -p "$WORK/exec-cpu"
printf '#!/usr/bin/env python3\nimport sys, time\nsys.path.insert(0, %s)\nimport collector_runs\ncollector_runs.record("speed", time.time())\n' \
  "'$ROOT/share'" > "$WORK/exec-cpu/speed"
chmod +x "$WORK/exec-cpu/speed"
DOCTORS_DIR="$WORK/exec-cpu" SPEED_DOCTOR_DIR="$WORK/exec-cpu" SPEED_DOCTOR_CMD="$WORK/exec-cpu/speed" \
  python3 - "$DOCTOR" <<'EOF' || fail "the exec'd collector run could not be launched"
import importlib.machinery, importlib.util, os, sys, time
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(module)
pid = os.fork()
if pid == 0:
    end = time.process_time() + 0.6
    while time.process_time() < end:
        pass
    module.exec_speed()
    os._exit(9)
os.waitpid(pid, 0)
EOF
assert_eq true "$(jq -r '.cpu_s < 0.4' "$WORK/exec-cpu/collector-runs.jsonl")" \
  "a doctor exec'd by Harness journals its own CPU, not the Harness run's it inherited across execv"
mkdir -p "$WORK/fixture-home"
env -u DOCTORS_DIR HOME="$WORK/fixture-home" SPEED_DOCTOR_DIR="$WORK/exec-cpu" "$WORK/exec-cpu/speed"
assert_eq absent "$([ -e "$WORK/fixture-home/.cache/doctors/collector-runs.jsonl" ] && echo present || echo absent)" \
  "a doctor on a fixture state dir without its own DOCTORS_DIR never journals into the live collector runs"

assert_eq '["Bash · alpha","15","8.0","1.9","4"]' \
  "$(doc "$(rowq Waits "Bash · alpha") | .cells")" \
  "trivial Bash in a worktree folds into its repo; the 7-day median is read off the day histograms"
assert_eq '[2,4]' "$(doc "$(rowq Waits "Bash · alpha") | .red")" "slow and cut calls are red on the 1 h window"
assert_eq '' "$(doc "$(rowq Waits "Bash · beta") | .cells")" "a chat asking for permission never counts as a wait"
assert_eq '["Bash · gamma","5","1.0"]' "$(doc "$(rowq Waits "Bash · gamma") | .cells[0:3]")" \
  "a subagent of an sdk-cli worker is read"
assert_eq 'true' "$(doc "$(rowq Waits "Edit") | .dim")" "a fast edit row is quiet"
assert_eq '["post-slow","after Bash","–"]' "$(doc "$(rowq Hooks "post-slow") | [.cells[0], .cells[1], .cells[3]]")" \
  "the hook row names the script and when it runs, and a hook outside the journal has no total"
assert_eq '[["1 200","0.1"],[2]]' "$(doc "$(rowq Hooks "post-fast") | [.cells[2:4], .red]")" \
  "journal rows give every run's median in ms and the day's total, and a slow median over the hour is red"
hooknav() { printf '.sections[] | select(.name == "Hooks") | .nav[0].menu.rows[] | select(.cells[0] == "%s")' "$1"; }
assert_eq '"600"' "$(doc "$(hooknav post-edit) | .cells[2]")" \
  "a /bin/bash run's spool file is timed by its birth and change times"
assert_eq '["each render","80"]' "$(doc "$(hooknav "statusline (not a hook)") | .cells[1:3]")" \
  "the statusline render journal is read"
assert_eq '[["each open","40"],true]' "$(doc "$(hooknav "menu build: llm-limits") | [.cells[1:3], .dim]")" \
  "the menu build journal is read, and a 40 ms build is quiet"
assert_eq 'true' "$(doc '.extras[1].menu.rows[0].cells[0] | startswith("hook time of ")')" \
  "hooks that do not source the timing lib are a blind spot"
assert_eq '0' "$(find "$HARNESS_DOCTOR_DIR/hooks/spool" -type f | wc -l | tr -d ' ')" "a folded spool file is removed"
assert_eq 'post-edit.sh	0	77	4200' "$(cut -f3- "$HARNESS_DOCTOR_DIR"/hooks/folded/*.tsv)" \
  "a folded spool run is kept per run for the batch join, its CPU column carried"
assert_eq '"3"' "$(doc "$(rowq Hooks "post-slow") | .cells[4]")" "a Post cut goes to the hook whose limit the call reached"
assert_eq '[4]' "$(doc "$(rowq Hooks "post-slow") | .red")" "three cuts in the hour make the hook red"
assert_eq '"1"' "$(doc "$(rowq Hooks "(which hook") | .cells[4]")" \
  "a cut from before the settings changed is not blamed on today's timeouts"
assert_eq '["2 500",[2]]' "$(doc "$(rowq Hooks "pre-slow") | [.cells[2], .red]")" \
  "printed hook durations make a p50 over the limit red"
assert_eq '["none","niced"]' "$(doc ".sections[] | select(.name == \"Hooks\") | .nav[] | select(.cells[0] | startswith(\"2 hooks can hold\")) | .menu.rows[] | select(.cells[0] == \"prompt-nice\") | .cells[2:4]")" \
  "a hook with no limit that renices itself is marked among the hooks a chat can wait on"
assert_eq '[[],true]' "$(doc "$(rowq Load "CPU busy") | [.red, .dim]")" "a busy share is shown dim, never red"
assert_eq '[4]' "$(doc "$(rowq Tests "suites · alpha") | .red")" "a run twice its usual time is red on its last cell"
assert_eq '[]' "$(doc "$(rowq Tests "test_gone · delta") | .red")" "a slow run hours ago with none after it is no longer red"
assert_eq '"suites at once, 6 h: 6"' \
  "$(doc '.sections[] | select(.name == "Tests") | .lead[] | select(.key == "tests:overlap") | .cells[0]')" \
  "overlapping suite runs are counted across repos"
assert_eq "[[$((T - 3000)),$((T - 888))]]" "$(doc .local_slow)" \
  "local_slow spans the first slow call to the end of the last one while a Waits call row was red"
assert_eq '["problem",true]' \
  "$(doc '.sections[] | select(.name == "Waits") | [.state, (.lead[0].cells[0] | startswith("started before "))]')" \
  "an area red since the first run claims no cause"
assert_eq "$(doc '[.sections[] | select(.state == "problem")] | length')" "$(doc .red)" \
  "red counts the areas in trouble; the title counts problems"
assert_eq '[1,"harness",true,true,true,"number","array","array",["collector_s","error"]]' \
  "$(doc '[.contract, .doctor, (.as_of | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}$")),
           (.judge | test("^[0-9a-f]{64}$")), (.status | IN("ok", "problems", "blind", "error")),
           (.problem_count | type), (.problems | type), (.blind_spots | type), (.self | keys)]' | jq -c .)" \
  "the document carries every contract envelope key"
assert_eq '[["count","evidence","exposure","fact","first_seen","group","id","ident","last_seen","ledger","limit","near","rule","runs_red","state","unit","value","window_h"]]' \
  "$(doc '[.problems[] | keys] | unique' | jq -c .)" "every problem carries every contract field"
assert_eq "$(doc '[.problems[] | select(.state | IN("new", "open", "regressed"))] | length')" "$(doc .problem_count)" \
  "problem_count counts new, open and regressed problems"
assert_eq 'true' "$(doc '[.problems[].id] | (length == (unique | length)) and all(contains("…") | not)')" \
  "problem ids are unique and never a clipped label"
assert_eq '[]' "$(doc '[.blind_spots[] | select((keys | sort) != ["id","reason","since","what","would_catch_if"])]' | jq -c .)" \
  "every blind spot is a contract row"
assert_eq 'true' "$(doc '[.blind_spots[].id] | index("permission-mode-calls") != null')" \
  "calls outside bypassPermissions are a named blind spot"
assert_eq '["blind","blind",true]' \
  "$(doc '[(.sections[] | select(.name == "Stop hooks" or .name == "Guards") | .state),
           ([.blind_spots[].id] | index("words-journal") != null)]' | jq -c .)" \
  "with no stop journal, watch state or words journal, Stop hooks and Guards read blind and word misses are a blind spot"
assert_eq '"a Bash call in alpha waits 8.0 s, fine under 3.0 s"' \
  "$(doc '.sections[] | select(.name == "Waits") | .fact')" "the Waits verdict states its worst row in words and units"
YESTERDAY=$(date -u -r $((T - 86400)) +%Y-%m-%d)
assert_eq '[2,20]' "$(jq -c '[.v, .waits["bash:alpha"][0]]' "$HARNESS_DOCTOR_DIR/days/$YESTERDAY.json")" \
  "a finished day is summarized as histograms per waiter"
assert_eq '6' "$(jq --arg d "$(date -u -r "$T" +%Y-%m-%d)" '.journal.days[$d]["post-fast.sh"][0]' "$HARNESS_DOCTOR_DIR/state.json")" \
  "journal runs also add up per day, for the day summary"
assert_eq '["7 d vs prev 7 d · worse",["Bash wait s","1.9","0.5","+275%"],[3]]' \
  "$(doc '.periods["168"] | [.cells[0], .menu.rows[0].cells, .menu.rows[0].red]')" \
  "the week comparison marks a material rise red against the stored summary of the week before"
assert_eq '["3 h vs prev 3 h · better",[3],"7 d vs prev 7 d · worse"]' \
  "$(doc '[.periods["3"].cells[0], (.periods["3"].menu.rows[] | select(.cells[0] == "CPU busy %") | .green),
           .periods["168"].cells[0]]')" \
  "the last 3 h beat the 3 h before on CPU, green, while the week is worse"
assert_eq '[["Bash wait s","5.0","–",""],["Bash wait s","5.0","1.5","+233%"]]' \
  "$(doc '[.periods["3"].menu.rows[0].cells, .periods["24"].menu.rows[0].cells]')" \
  "an hour window reads raw events: none in the 3 h before, which today's summary would hold, and yesterday's at 24 h"
assert_eq '["Edit wait s","0.5","1.0","-50%"]' \
  "$(doc '.periods["72"].menu.rows[] | select(.cells[0] == "Edit wait s") | .cells')" \
  "3 d sets today and the 2 days before against the 3 before, the older side off a day summary with no events"

before=$(cat "$HARNESS_DOCTOR_DIR"/events/*.jsonl | jq -s 'map(select(.[0] == "c")) | length')
printf 'renice -n 10 $$\n# edited\n' > "$HOME/hooks/prompt-nice.sh"
touch -d "$(date -u -r $((T + 200)) +%Y-%m-%dT%H:%M:%S)" "$HOME/hooks/prompt-nice.sh"
python3 - "$WORK" "$T" "$(cat "$WORK/pending-tid")" <<'EOF'
import json, os, sys, time
work, T, pending = sys.argv[1], int(sys.argv[2]), sys.argv[3]
path = os.path.join(work, "home", ".claude", "projects", "-alpha", "s1.jsonl")
def stamp(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".000Z"
with open(path, "a") as handle:
    handle.write(json.dumps({"type": "user", "timestamp": stamp(T + 10), "cwd": work + "/alpha",
                             "message": {"content": [{"type": "tool_result", "tool_use_id": pending}]}}) + "\n")
    handle.write('{"type": "user", "timestamp": "torn')
EOF
HARNESS_DOCTOR_NOW=$((T + 300)) HARNESS_DOCTOR_FAKE_SAMPLE=$(sample 1.0 0 true) "$DOCTOR" --quiet || fail "second run failed"
assert_eq "$((before + 1))" "$(cat "$HARNESS_DOCTOR_DIR"/events/*.jsonl | jq -s 'map(select(.[0] == "c")) | length')" \
  "an appended read adds only the call it completed"
assert_eq '[30.0]' "$(cat "$HARNESS_DOCTOR_DIR"/events/*.jsonl | jq -sc 'map(select(.[0] == "c" and .[2] == "alpha" and .[5] > 20 and .[5] < 35) | .[5])')" \
  "a tool_use read in one run is closed by a result read in the next"
assert_eq "[[$((T - 3000)),$((T + 11))]]" "$(doc .local_slow)" \
  "a slow call read in the next run extends the kept local_slow window"
assert_eq '6' "$(jq '[.journal.slots[] | .["post-fast.sh"][0] // 0] | add' "$HARNESS_DOCTOR_DIR/state.json")" \
  "a second run reads only the journal lines appended since, and leaves a torn line for later"
assert_eq '[]' "$(doc "$(rowq Load "CPU busy") | .red")" "a full busy hour is weather, never red"
assert_eq '[1]' "$(doc "$(rowq "Memory guard" "memory") | .red")" "the memory guard's alarm is red, in a section of its own"
assert_eq 'edited' "$(doc '.sections[] | select(.name == "Memory guard") | .lead[0].menu.rows[0].cells[1]' | tr -d '"')" \
  "an area that turned red lists the changes before it"
assert_eq 'true' "$(doc '.sections[] | select(.name == "Memory guard") | .lead[0].cells[0] | test("^started [0-9]{2}:[0-9]{2} · [0-9]+ changes? before it$")')" \
  "the area's cause line counts the changes in the 6 h before"
assert_eq 'true' "$(doc '.sections[] | select(.name == "Memory guard") | .fact | test(" · since [0-9]{2}:[0-9]{2}$")')" \
  "a problem that started after the first run carries its start on the verdict"

python3 - "$HARNESS_DOCTOR_DIR/menu.txt" <<'EOF' || fail "menu.txt spans do not point at the red cells"
import json, sys
lines = open(sys.argv[1], "rb").read().split(b"\n")
assert lines[0].startswith(b"T\t"), lines[0]
assert lines[1].startswith(b"H\t"), lines[1]
header = json.loads(lines[1][2:])
assert set(header) == {"status", "problems", "issues", "speed"}, header
red = 0
for line in lines[2:]:
    if not line:
        continue
    depth, flags, spans, text = line.split(b"\t", 3)
    for span in filter(None, spans.split(b",")):
        style, start, length = span.split(b":")
        piece = text[int(start):int(start) + int(length)]
        assert piece and not piece.startswith(b" ") and not piece.endswith(b" "), (line, piece)
        red += style == b"r"
assert red >= 8, red
EOF
asserts=$((asserts + 1))
python3 - "$HARNESS_DOCTOR_DIR/menu.txt" <<'EOF' || fail "an area's top line is not 'Name: N problems|state · fact' in plain words, the menu does not open on Speed, or the areas do not sum to the title and to Speed's count"
import re, sys
lines = open(sys.argv[1]).read().split("\n")
areas, problems, top = 0, {"0": 0, "1": 0}, None
for line in lines[2:]:
    depth, flags, spans, text = line.split("\t", 3)
    if depth == "0" and flags.startswith("s"):
        break
    if depth not in ("0", "1") or depth == "1" and top != "Lost time":
        continue
    areas += 1
    match = re.fullmatch(r"([A-Z][a-z]+(?: [a-z]+)*): (ok|watch|blind|[1-9]\d* problems?)(?: · (.+))?", text)
    assert match, text
    assert not re.search(r"\(\+\d|×\d|\.sh\b|deferred|bg-task|\d+ more\b", text), text
    if depth == "0":
        top, speed = match.group(1), match.group(2)
    if match.group(2)[0].isdigit():
        problems[depth] += int(match.group(2).split()[0])
        start = len(match.group(1)) + 2
        assert "r:%d:%d" % (start, len(match.group(2))) in spans.split(","), (spans, text)
assert areas >= 8, areas
assert lines[2].split("\t")[3].startswith("Lost time: "), lines[1]
assert problems["0"] == int(lines[0].split("\t")[1]) > 0, (problems, lines[0])
assert problems["1"] == int(lines[2].split("\t")[3].split(": ")[1].split()[0].replace("ok", "0")), (problems, lines[1])
EOF
asserts=$((asserts + 1))
python3 - "$HARNESS_DOCTOR_DIR/menu.txt" <<'EOF' || fail "menu.txt does not tag every line of a window block, and only those"
import re, sys
labels = {"3": "3 h", "6": "6 h", "12": "12 h", "24": "24 h", "72": "3 d", "168": "7 d"}
blocks, current, untagged = {}, None, 0
for line in filter(None, open(sys.argv[1], encoding="utf-8").read().split("\n")[2:]):
    depth, flags, _, text = line.split("\t", 3)
    tag = re.fullmatch(r"[a-z]*?(?:w(\d+))?", flags).group(1)
    if depth == "0":
        current = tag
        if tag:
            blocks[tag] = text
        else:
            untagged += 1
    else:
        assert tag == current, line
assert list(blocks) == list(labels), blocks
for hours, text in blocks.items():
    assert text.startswith("%s vs prev %s" % (labels[hours], labels[hours])), text
assert untagged > 8, untagged
EOF
asserts=$((asserts + 1))
assert_eq "$(jq -r .problem_count "$HARNESS_DOCTOR_DIR/latest.json")" "$(head -1 "$HARNESS_DOCTOR_DIR/menu.txt" | cut -f2)" \
  "menu.txt carries the document's problem count"
assert_eq "$(jq -r '"Harness doctor: \(.problem_count) problems"' "$HARNESS_DOCTOR_DIR/latest.json")" \
  "$(head -1 "$HARNESS_DOCTOR_DIR/menu.txt" | cut -f4)" "the title's N is problem_count over problems, not areas"

rm "$HARNESS_DOCTOR_DIR/events/$YESTERDAY.jsonl" "$HARNESS_DOCTOR_DIR/days/$YESTERDAY.json"
jq '.rebuilt = 1' "$HARNESS_DOCTOR_DIR/state.json" > "$WORK/state.json" && mv "$WORK/state.json" "$HARNESS_DOCTOR_DIR/state.json"
HARNESS_DOCTOR_NOW=$((T + 450)) HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --quiet || fail "rebuild run failed"
assert_eq '[2,20,2]' "$(jq -c --slurpfile s "$HARNESS_DOCTOR_DIR/state.json" '[.v, .waits["bash:alpha"][0], $s[0].rebuilt]' \
  "$HARNESS_DOCTOR_DIR/days/$YESTERDAY.json")" "a summary format change rebuilds days whose events are pruned, once"

stamp_before=$(stat -f %m "$HARNESS_DOCTOR_DIR/latest.json")
python3 - "$HARNESS_DOCTOR_DIR/lock" "$DOCTOR" "$((T + 600))" <<'EOF' > "$WORK/locked.txt" 2>&1 || fail "a locked run did not exit 0"
import fcntl, os, subprocess, sys
with open(sys.argv[1], "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    env = dict(os.environ, HARNESS_DOCTOR_NOW=sys.argv[3], HARNESS_DOCTOR_FAKE_SAMPLE="")
    sys.exit(subprocess.run([sys.argv[2]], env=env).returncode)
EOF
assert_eq 'harness-doctor: another run holds the lock' "$(cat "$WORK/locked.txt")" "a second run yields to the lock"
assert_eq "$stamp_before" "$(stat -f %m "$HARNESS_DOCTOR_DIR/latest.json")" "a locked run wrote nothing"

python3 - "$DOCTOR" <<'EOF' || fail "trivial_bash misjudged a command"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(module)
for command, want in (("ls -la | grep x", True), ("cat f 2>/dev/null", True), ("jq . a.json | head -3", True),
                      ("grep -r x .", False), ("grep -rn x .", False), ("sed -i s/a/b/ f", False),
                      ("ls; rm x", False), ("echo $(date)", False), ("make", False), ("ls > out", False),
                      ("cat a || true", False), ("", False)):
    assert module.trivial_bash(command) is want, command
EOF
asserts=$((asserts + 1))

python3 - "$DOCTOR" "$T" <<'EOF' || fail "change impact or inventory caps misjudged"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(module)
T = int(sys.argv[2])
calls = [["c", T - 1800 + i, "alpha", "Bash", 1, 1.0, "c", "t%d" % i] for i in range(3)]
calls += [["c", T + 600 + i, "alpha", "Bash", 1, 4.0, "c", "u%d" % i] for i in range(3)]
calls += [["c", T + 700, "alpha", "Bash", 0, 99.0, "c", "long"], ["c", T + 710, "alpha", "Bash", 1, 99.0, "h", "held"]]
samples = [{"t": T - 900, "forks": 400}, {"t": T + 900, "forks": 1500}, {"t": T + 1200, "forks": 1700}]
impact = module.change_impact(calls, samples, T + 3000)
assert impact(T) == ["1.0→4.0", "400→1 600"], impact(T)
assert impact(T + 2000) == ["4.0→–", "1 200→–"], impact(T + 2000)
assert impact(T - 86400) == ["–", "–"], impact(T - 86400)
changes = [{"at": T - 60 * i, "kind": "hook", "what": "~/hooks/h%d.sh" % i} for i in range(3)]
table = module.change_table(changes[:2], impact)
assert table["columns"][3:] == ["short Bash s", "new proc/s"] and len(table["rows"]) == 2, table
tests = [{"label": "t%02d" % i, "repo": "/r", "end": T + i, "secs": 60.0 * (i + 1), "who": "c"} for i in range(25)]
nav = {n["cells"][0]: n for n in module.tests_section(tests, T + 100)["nav"]}
top = nav["top 20 of 25 tests today"]["menu"]
assert len(top["rows"]) == 20, len(top["rows"])
assert len(nav["latest 10"]["menu"]["rows"]) == 10
days = module.day_list(T, 14)
fast, slow = [30, 30000, 1000, 1000, 0, 0, [0] * 13 + [30]], [30, 150000, 5000, 5000, 0, 0, [0] * 17 + [30]]
summaries = {d: {"v": 2, "slow_s": 0, "waits": {"bash:a": fast if i < 7 else slow, "edit": slow if i < 7 else fast}}
             for i, d in enumerate(days)}
entries, cur = module.periods_section(summaries, {}, [], T, [])
entry = entries["168"]
rows = {r["cells"][0]: r for r in entry["menu"]["rows"]}
assert sorted(entries, key=int) == ["3", "6", "12", "24", "72", "168"], sorted(entries)
assert entry["cells"][0] == "7 d vs prev 7 d · worse, better", entry["cells"]
assert entry["menu"]["columns"] == ["", "7 d", "prev 7 d", "Δ"], entry["menu"]["columns"]
assert entries["72"]["cells"][0] == "3 d vs prev 3 d" and not entries["72"]["menu"]["nav"], entries["72"]
import os, re
lua = open(os.path.join(os.path.dirname(os.path.dirname(sys.argv[1])), "hammerspoon", "llm-limits.lua")).read()
picker = re.search(r"local DOCTOR_WINDOWS = \{(.*?)\n\}", lua, re.S).group(1)
assert tuple(int(h) for h in re.findall(r"hours = (\d+)", picker)) == module.DOCTOR_WINDOWS_H, picker
assert [p[1] for p in entry["parts"]] == ["", "r", "g"], entry["parts"]
assert rows["Bash wait s"]["cells"][1:] == ["1.0", "5.0", "-80%"] and rows["Bash wait s"]["green"] == [3], rows["Bash wait s"]
assert rows["Edit wait s"]["cells"][3] == "+400%" and rows["Edit wait s"]["red"] == [3], rows["Edit wait s"]
by_week = entry["menu"]["nav"][0]["menu"]
assert len(by_week["columns"]) == 1 + module.BY_WEEKS and by_week["columns"][0] == "week (Mon–Sun)", by_week["columns"]
assert module.delta(1.05, 1.0) == ("+5%", "") and module.delta(12.0, 1.0) == ("×12", "worse"), module.delta(12.0, 1.0)
EOF
asserts=$((asserts + 1))

checks=$(python3 - "$DOCTOR" "$T" "$WORK" <<'EOF'
import importlib.machinery, importlib.util, json, os, shutil, sys, time
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(m)
T, work = int(sys.argv[2]), sys.argv[3]
home = os.environ["HOME"]
count = [0]

def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)

def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)

LIB = '. "$(dirname "$0")/lib/readonly-command.sh" 2>/dev/null && rc_readonly_command "$c" && exit 0\n'
for name in ("gate-a", "gate-b", "watch", "nudge", "prompt"):
    put(os.path.join(home, "hk", name + ".sh"), "#!/bin/bash\n" + (LIB if name == "gate-a" else "true\n"))
GOOD = 'rc_readonly_command() { case $1 in rm*) return 1;; esac; return 0; }\n'
put(os.path.join(home, "hk", "lib", "readonly-command.sh"), GOOD)
hooks = [{"event": e, "matcher": mt, "command": c, "timeout": 10, "async": False} for e, mt, c in (
    ("PreToolUse", "Bash", "~/hk/gate-a.sh"), ("PreToolUse", "Bash", "~/hk/gate-b.sh"),
    ("PostToolUse", "Bash|Edit|Write", "~/hk/watch.sh check"), ("PostToolUse", "*", "~/hk/nudge.sh"),
    ("UserPromptSubmit", "", "~/hk/prompt.sh"))]

def traffic(pre_ms, post_ms, nudge_big_ms=None, prompt_ms=400.0, trivial_ms=None):
    runs, calls, n = [], [], 0
    for ppid, session, offset in (("11", "sessaaaa", 0.0), ("22", "sessbbbb", 0.2)):
        for i in range(24):
            n += 1
            use = T - 3000 + i * 100 + offset
            trivial = i % 2
            a, w = (trivial_ms, trivial_ms) if trivial and trivial_ms else (pre_ms, post_ms)
            kb = 100 if i < 12 else 20000
            pre = use + 0.03
            runs += [(pre + a / 1000.0, "gate-a.sh", a, False, pre, ppid),
                     (pre + 0.005 + a / 2000.0, "gate-b.sh", a / 2.0, False, pre + 0.005, ppid)]
            post = pre + a / 1000.0 + 0.05
            nudge = nudge_big_ms if nudge_big_ms and kb > 1024 else w / 2.0
            runs += [(post + w / 1000.0, "watch.sh check", w, False, post, ppid),
                     (post + 0.004 + nudge / 1000.0, "nudge.sh", nudge, False, post + 0.004, ppid)]
            result = max(post + w / 1000.0, post + 0.004 + nudge / 1000.0) + 0.1
            calls.append(["c", round(use, 3), "alpha", "Bash", trivial, round(result - use, 3), "c", "t%09d" % n,
                          session, kb])
    prompt = T - 600
    runs.append((prompt + prompt_ms / 1000.0, "prompt.sh", prompt_ms, False, prompt, "11"))
    return runs, calls

def timed(runs):
    out = {}
    for run in runs:
        m.hist_put(out.setdefault(run[1], m.hist_new()), run[2], run[3])
    return out

names = m.hook_names(hooks)
runs, calls = traffic(250, 200, nudge_big_ms=160)
view = m.hook_view(hooks, runs, calls, T)
check(view["joined"] == view["tool_batches"] == 96, "A: every batch of two interleaved chats joins its call")
part = m.floors_section(view, names, T)
rows = {r["cells"][0]: r for r in part["rows"]}
check(part["state"] == "problem" and rows["Bash · trivial"]["red"] == [2], "A: a trivial Bash floor over 300 ms is red")
check("waits 450 ms on hooks, limit 300 ms" in rows["Bash · trivial"]["say"]
      and "fine under 150 ms" in rows["Bash · other"]["say"], "A: a red row names its limit, a watch its note")
check(rows["Bash · trivial"]["cells"][2] == "450" and rows["Bash · trivial"]["cells"][4] == "gate-a · watch check",
      "A: the floor is Pre plus Post, first start to last end, and names the hook that set each side")
check(rows["Bash · other"]["red"] == [] and not rows["Bash · other"]["dim"],
      "A: a writing Bash call over the note but under its own red limit is a watch")
check(rows["message"]["cells"][2] == "400" and not rows["message"]["red"], "A: a turn event's floor is its batch")
drill = rows["Bash · trivial"]["menu"]["rows"]
check([r["cells"][0] for r in drill] == ["before the tool", "after the tool"] and drill[0]["cells"][4] == "gate-a 100 %",
      "A: the drill-down splits the floor into its Pre and Post side")
t24 = timed(runs)
hooks_part = m.hooks_section(hooks, calls, [], [], 0, t24, t24, T, view["split"], m.probe_fast_paths(hooks))
hrows = {r["cells"][0]: r for r in hooks_part["nav"][0]["menu"]["rows"]}
check("fine under 150 ms" in hrows["gate-a"]["say"], "E: a synchronous hook over 150 ms is a watch")
check("on every tool call" in hrows["nudge"]["say"], "B: a hook on every tool call over 50 ms is a watch")
size = hooks_part["nav"][-1]
check(size["cells"][0] == "by transcript size: 1 of 4 hooks grow" and [r["cells"][0] for r in size["menu"]["rows"]
      if not r["dim"]] == ["nudge"],
      "F: a hook slower in big transcripts is flagged in the size table")
full = [n for n in hooks_part["nav"] if n["cells"][0].startswith("full work on trivial Bash")][0]
check(full["cells"][0] == "full work on trivial Bash: 4 of 4 hooks", "C: hooks as slow on trivial calls as on the rest")
check(hooks_part["lead"][0]["cells"][0] == "fast paths: 1 quiet libraries load" and not hooks_part["lead"][0]["red"],
      "D: a quiet library that loads and answers its probe is dim")

runs, calls = traffic(30, 40, prompt_ms=80.0, trivial_ms=2.0)
view = m.hook_view(hooks, runs, calls, T + 3700)
view_now = m.hook_view(hooks, runs, calls, T)
check(m.floors_section(view_now, names, T)["state"] == "ok", "J A: fast hooks leave the area ok")
check(m.floors_section(view, names, T + 3700)["state"] == "ok", "J A: a red floor clears once its hour has passed")
t24 = timed(runs)
quiet = m.hooks_section(hooks, calls, [], [], 0, t24, t24, T, view_now["split"], m.probe_fast_paths(hooks))
check(all(r["dim"] for r in quiet["nav"][0]["menu"]["rows"]) and quiet["state"] == "ok",
      "J B/C/E/F: fast hooks clear every hook watch")

put(os.path.join(home, "hk", "lib", "readonly-command.sh"), 'rc_readonly_command() { return 0; }\n')
broken = m.hooks_section(hooks, calls, [], [], 0, t24, t24, T, {}, m.probe_fast_paths(hooks))
check(broken["state"] == "problem" and broken["lead"][0]["red"] and "fast path broken under /bin/bash" in broken["fact"],
      "D: a fast path that answers wrong is red")
put(os.path.join(home, "hk", "lib", "readonly-command.sh"), 'rc_readonly_command() {\n')
check(m.probe_fast_paths(hooks)[0]["state"] == "does not load", "D: a library that fails to parse does not load")
put(os.path.join(home, "hk", "lib", "readonly-command.sh"), GOOD)
check(m.hooks_section(hooks, calls, [], [], 0, t24, t24, T, {}, m.probe_fast_paths(hooks))["state"] == "ok",
      "J D: a repaired library clears the red")

def by_repos(registry):
    slow_b = [(r[4] + 0.12, r[1], 120.0, r[3], r[4], r[5]) if r[1] == "gate-b.sh" and r[5] == "22" else r for r in runs]
    split = m.hook_view(hooks, slow_b, calls, T, registry)["split"]
    part = m.hooks_section(hooks, calls, [], [], 0, timed(slow_b), timed(slow_b), T, split)
    nav = [n for n in part["nav"] if n["cells"][0].startswith("by repositories")]
    return part, nav[0] if nav else None
part, repo_nav = by_repos({"sessaaaa": [(T - 9999, 1)], "sessbbbb": [(T - 9999, 8)]})
check(repo_nav["cells"][0] == "by repositories in the chat: 1 of 4 hooks grow"
      and [r["cells"][0] for r in repo_nav["menu"]["rows"] if not r["dim"]] == ["gate-b"]
      and "in chats with 5+ repositories" in {r["cells"][0]: r for r in part["nav"][0]["menu"]["rows"]}["gate-b"]["say"],
      "F: a hook slower in chats with a long repository registry is flagged")
check(by_repos({"sessaaaa": [(T - 9999, 1)], "sessbbbb": [(T - 9999, 8), (T - 4000, 1)]})[1]["cells"][0]
      == "by repositories in the chat: 0 of 4 hooks grow", "J F: the count at the run's time decides")
registry = os.path.join(home, ".cache", "claude", "review-journal", "sessbbbb-0000-full-id.repos")
put(registry, "/r/one\n/r/two\n/r/three\n")
journal = {"repos": {"sessgone": [[T - 99999, 4]]}}
check(m.session_repos(journal, calls, T) == {"sessbbbb": [(T, 3)]}, "F: a chat's registry is counted by its session")
put(registry, "/r/one\n/r/two\n/r/three\n/r/four\n")
check(m.session_repos(journal, calls, T + 300)["sessbbbb"] == [(T, 3), (T + 300, 4)], "F: a registry's growth is kept")

old_runs, old_calls = traffic(250, 200)
old_runs = [(r[0] - 18000,) + r[1:4] + (r[4] - 18000, r[5]) for r in old_runs]
old_calls = [c[:1] + [c[1] - 18000] + c[2:7] + ["o" + c[7]] + c[8:] for c in old_calls]
new_runs, new_calls = traffic(30, 40, prompt_ms=80.0, trivial_ms=2.0)
def full_line(runs_all, calls_all, now):
    split = m.hook_view(hooks, runs_all, calls_all, now)["split"]
    part = m.hooks_section(hooks, calls_all, [], [], 0, timed(runs_all), timed(runs_all), now, split)
    return [n for n in part["nav"] if n["cells"][0].startswith("full work")][0]
check(full_line(old_runs, old_calls, T)["cells"][0] == "full work on trivial Bash: 4 of 4 hooks",
      "C: with no Bash call in the last hour the 24 h runs decide")
fixed = full_line(old_runs + new_runs, old_calls + new_calls, T)
check(fixed["cells"][0] == "full work on trivial Bash: 0 of 4 hooks" and fixed["menu"]["rows"][0]["cells"] == ["gate-a", "2.0", "30", "126", "140"],
      "J C: a fast path shows within the hour while the 24 h columns still carry the old runs")

menu_key = m.MENU_KEY + "llm-limits"
slow_menu = {menu_key: timed([(0, "k", 400.0, False)] * 4)["k"]}
fast_menu = {menu_key: timed([(0, "k", 40.0, False)] * 4)["k"]}
def menu_row(t24, t1):
    part = m.hooks_section(hooks, [], [], [], 0, t24, t1, T)
    return part["state"], {r["cells"][0]: r for r in part["nav"][0]["menu"]["rows"]}["menu build: llm-limits"]
state, entry = menu_row(slow_menu, slow_menu)
check(state == "problem" and entry["red"] == [2] and entry["key"] == "hook:menu:llm-limits"
      and entry["say"] == "4 menu opens waited 400 ms for the menu build: llm-limits in the last hour",
      "I: menu builds over 300 ms this hour are red")
check(menu_row(slow_menu, {})[0] == "watch", "J I: a slow build turns watch once its hour passes")
check(menu_row(fast_menu, fast_menu)[0] == "ok", "J I: fast builds are ok")

def test_row(repo, label, start, end, ok=None):
    out = {"end": end, "secs": end - start, "who": "chat", "repo": repo, "label": label}
    if ok is not None:
        out["ok"] = ok
    return out
S = T - 3 * 3600
history = [test_row(r, "suites", S, S + 1560) for r in ("claude-setup", "llm-legs", "review-bench")]
history += [test_row("llm-legs", "test_claudeb", S + 600, S + 900, False),
            test_row("llm-legs", "test_worker_run", S + 700, S + 1000, False),
            test_row("review-bench", "test_review_anchors", S + 600, S + 700),
            test_row("llm-legs", "test_claudeb", S + 1700, S + 1900, True),
            test_row("llm-legs", "test_worker_run", S + 1600, S + 2000, True)]
tests_part = m.tests_section(history, T)
loaded = [x for x in tests_part["lead"] if x.get("key") == "tests:load"][0]
check(tests_part["state"] == "problem" and loaded["cells"][0] == "failed under load, 6 h: 2" and loaded["red"],
      "H: tests that failed under 3 suites and passed alone within the hour are red")
check(len(loaded["menu"]["rows"]) == 2 and loaded["menu"]["rows"][0]["cells"][2] == "3", "H: the table counts the suites")
put(os.path.join(os.environ["MEMLOGD_DIR"], m.local_day(S) + ".log"),
    "SAMPLE x\nKILLED %d chat=c job_pgid=1 avail_mb=2000 job_rss_mb=2000 killed=1 notified=c\n" % (S + 650))
check([x for x in m.tests_section(history, T, m.guard_kills(S - 86400))["lead"] if x.get("key") == "tests:load"][0]
      ["cells"][0] == "failed under load, 6 h: 1", "H: a run the memory guard killed is not a load failure")
history[-1]["ok"] = False
check([x for x in m.tests_section(history, T)["lead"] if x.get("key") == "tests:load"][0]["cells"][0]
      == "failed under load, 6 h: 1", "H: a test that failed again alone is not a load failure")
check(not [x for x in m.tests_section(history, T + 7 * 3600)["lead"] if x.get("key") == "tests:load"][0]["red"],
      "J H: a load failure clears after 6 h")

growth = [{"t": T, "day": m.local_day(T), "stores": {"x": [1, 1]}}]
spool = m.growth_section(growth, T, (40, 2 * m.SPOOL_STALE_S + 60))
check(spool["state"] == "problem" and spool["rows"][0]["key"] == "growth:spool", "G: a spool that stopped draining is red")
check(m.growth_section(growth, T, (40, 120))["state"] == "ok", "J G: a draining spool is ok")
for sub in ("readonly", "inflight", "closed"):
    put(os.path.join(os.environ["INSTRUCTION_WATCH_STATE"], sub, "n"), "")
put(os.path.join(os.environ["INSTRUCTION_WATCH_STATE"], "session-x.tsv.123"), "x")
put(os.path.join(home, ".cache", "claude", "review-journal", "a.hashes"), "x")
put(os.path.join(home, ".cache", "claude-context-nudge", "s.bnd"), "x")
stores = m.growth_sample(T, set())["stores"]
check({"instruction-watch read-only notes", "instruction-watch inflight", "instruction-watch closed",
       "instruction-watch temp leftovers", "review journal", "review journal .hashes, .ref, .heads",
       "review journal .repos", "context-nudge state"} <= set(stores),
      "G: the stores left by skipped or aborted calls are sampled")
runaway = lambda before, now_count: [{"t": T - 86400, "day": "d", "stores": {"instruction-watch inflight": [before, 1]}},
                                     {"t": T, "day": m.local_day(T), "stores": {"instruction-watch inflight": [now_count, 1]}}]
part = m.growth_section(runaway(800, 2400), T)
check(part["state"] == "watch" and "doubled in a day" in part["rows"][0]["say"],
      "G: a per-call store that doubled in a day over 1 000 entries is a watch")
check(m.growth_section(runaway(2400, 40), T)["state"] == "ok", "J G: a store its cleanup emptied is ok")

os.environ["HARNESS_DOCTOR_DIR"] = os.path.join(work, "spool-fixture")
put(os.path.join(work, "spool-fixture", "hooks", "spool", "9.9"), "gate-a.sh verdict\tSTATUS=open LINES=4\n1\t4242\n")
folded = m.fold_spool(lambda *a: None, T + 9999, False)
check([r[2:] for r in folded] == [("gate-a.sh verdict", "1", "4242", "")],
      "a spool file carrying a hook's stray output still folds to its key, exit and ppid, with no CPU")
os.environ["HARNESS_DOCTOR_DIR"] = os.path.join(work, "state")

def state_of(part):
    return part["state"]

week = {"waits": {}}
slow = [["c", T - 1000 + i * 60, "alpha", "Bash", 1, 8.0, "c", "s%d" % i] for i in range(6)]
check(state_of(m.waits_section(slow, [], [], week, T)) == "problem", "Waits: slow calls are red")
check(state_of(m.waits_section(slow, [], [], week, T + 3600)) == "ok", "J Waits: slow calls clear after the hour")
cut_calls = [["c", T - 1000 + i * 60, "alpha", "Bash", 1, 1.0, "c", "k%d" % i] for i in range(6)]
cuts = [["x", c[1] + 1, "alpha", "PostToolUse", "", 10000, 10000, "Bash", c[7]] for c in cut_calls[:3]]
check(state_of(m.waits_section(cut_calls, cuts, [], week, T)) == "problem", "Waits: three cuts in the hour are red")
check(state_of(m.waits_section(cut_calls, cuts, [], week, T + 3600)) == "ok", "J Waits: cuts clear after the hour")
starts = [["h", T - 1000 + i * 60, "alpha", "SessionStart", "~/hk/prompt.sh", 7000, "", ""] for i in range(3)]
check(state_of(m.waits_section([], [], starts, week, T)) == "problem", "Waits: slow chat starts are red")
check(state_of(m.waits_section([], [], starts, week, T + 3600)) == "ok", "J Waits: slow chat starts clear")
check(state_of(m.slow_section([[T - 3000, T - 2000]], T)) == "watch", "Slow periods: a slow window is a watch")
check(state_of(m.slow_section([[T - 3000, T - 2000]], T + 86400)) == "ok", "J Slow periods: clears after 24 h")

slow_hook = {"prompt.sh": [6, 12000, 2000, 2000, 0, 0, [0] * 15 + [6]]}
check(state_of(m.hooks_section(hooks, [], [], [], 0, slow_hook, slow_hook, T)) == "problem",
      "Hooks: a p50 over 1 s this hour is red")
check(state_of(m.hooks_section(hooks, [], [], [], 0, slow_hook, {}, T)) == "watch",
      "J Hooks: a slow hook turns watch once its hour passes")
hook_cuts = [["x", T - 600 + i, "alpha", "UserPromptSubmit", "~/hk/prompt.sh", 10000, 10000, "", ""] for i in range(3)]
check(state_of(m.hooks_section(hooks, [], hook_cuts, [], 0, {}, {}, T)) == "problem", "Hooks: three cuts are red")
quiet_hook = {"prompt.sh": [6, 60, 10, 10, 0, 0, [6]]}
check(state_of(m.hooks_section(hooks, [], hook_cuts, [], 0, quiet_hook, quiet_hook, T + 3600)) == "ok",
      "J Hooks: cuts clear")
check(state_of(m.hooks_section(hooks, [], [], [], 0, {}, {}, T)) == "blind", "Hooks: an empty hook journal is blind")
lost = [["x", T - 600 + i, "alpha", "PostToolUse", "", 10000, 10000, "Bash", "u%d" % i] for i in range(3)]
check(state_of(m.hooks_section(hooks, [], lost, [], T, {}, {}, T)) == "problem", "Hooks: unknown cuts are red")
check(state_of(m.hooks_section(hooks, [], lost, [], T, quiet_hook, quiet_hook, T + 3600)) == "ok",
      "J Hooks: unknown cuts clear")

def sample(t, **kw):
    base = {"t": t, "busy": 0.3, "kernel": 0.1, "forks": 500, "ncpu": 10, "visible": 2.5, "guard": False,
            "swap_mb": 100, "swap_total_mb": 1000}
    base.update(kw)
    return base
red = [sample(T - 600, guard=True), sample(T - 300, guard=True)]
check(state_of(m.load_section(red, T)) == "problem", "Load: a memory guard alarm is red")
check(state_of(m.load_section(red + [sample(T + 3000), sample(T + 3300)], T + 3600)) == "ok",
      "J Load: the guard clears when the next hour is calm")
owned = m.load_section([sample(T - 600, kernel=0.9, forks=9000, swap_mb=990), sample(T - 300, kernel=0.9, forks=9000,
                                                                                    swap_mb=990)], T)
check(state_of(owned) == "ok" and not [r for r in owned["rows"] if r.get("key") in ("load:kernel", "load:forks", "load:swap")]
      and not [j for r in owned["rows"] for j in r.get("judge", []) if j["ident"] in ("kernel", "forks", "swap_share")],
      "Load raises no row the System doctor owns: the kernel share, new processes and swap are judged there alone")
kept = m.summarize_day(m.local_day(T), [], [sample(m.day_start(m.local_day(T)) + 60, kernel=0.6, forks=3000)], None, [])
check(kept["load"]["kernel"] == 0.6 and kept["load"]["forks"] == 3000
      and [n for n, _, _ in m.WEEK_METRICS if n in ("kernel %", "new proc/s")] == ["kernel %", "new proc/s"]
      and m.impact_measures("load:busy") == ("busy", "forks"),
      "Load keeps the kernel and fork samples its day summaries, week table and change impact read")
def load_levels(samples):
    return {j["ident"]: j["level"] for r in m.load_section(samples, T)["rows"] for j in r.get("judge", [])
            if j["ident"] in ("busy", "unseen")}
bench = [sample(T - 900 + 300 * i, busy=1.0, visible=1.0, held=0) for i in range(3)]
shown = {r["key"]: r["cells"][1] for r in m.load_section(bench, T)["rows"] if r.get("key") in ("load:busy", "load:unseen")}
check(load_levels(bench) == {"busy": None, "unseen": None} and state_of(m.load_section(bench, T)) == "ok"
      and shown == {"load:busy": m.fmt_pct(1.0), "load:unseen": "9.0 cores"},
      "Load shows busy and unaccounted CPU but never judges them: whole-machine load is the System doctor's weather")
slots = os.path.join(work, "held-slots")
put(os.path.join(slots, "suites", "1", "pid"), "%d\n" % os.getpid())
put(os.path.join(slots, "suites", "2", "pid"), "999999\n")
put(os.path.join(slots, "fixers", "1", "pid"), "%d\n" % os.getppid())
put(os.path.join(slots, "fixers", "2", "pid"), "junk\n")
os.environ.update(RUN_SUITES_SLOTS_DIR=os.path.join(slots, "suites"), NIGHT_FIXER_SLOTS_DIR=os.path.join(slots, "fixers"))
check(m.held_slots() == 2, "a slot counts as held only while the pid in it runs")
os.environ.pop("RUN_SUITES_SLOTS_DIR")
os.environ.pop("NIGHT_FIXER_SLOTS_DIR")

suites = [test_row(r, "suites", T - 900, T - 100) for r in ("a", "b", "c", "d", "e")]
check(state_of(m.tests_section(suites, T)) == "problem", "Tests: 5 suites at once are red")
check(state_of(m.tests_section(suites, T + 7 * 3600)) == "ok", "J Tests: the suite peak clears after 6 h")
unprobed = [{"kind": "suites", "repo_root": "/r/%s" % r, "started_at": T - 900, "ended_at": T - 100} for r in "abcde"]
check(state_of(m.tests_section(suites[:1], T, (), unprobed)) == "problem"
      and state_of(m.tests_section(suites[:1], T, (), [dict(r, kind="direct") for r in unprobed])) == "ok",
      "Tests: suite runs only run-suites' own journal saw count toward the peak")
runs_slow = [test_row("a", "t", T - d * 86400 - 300, T - d * 86400) for d in (3, 2, 1)] + [test_row("a", "t", T - 1600, T - 100)]
check(state_of(m.tests_section(runs_slow, T)) == "problem", "Tests: a run twice its usual is red")
check(state_of(m.tests_section(runs_slow, T + 7 * 3600)) == "ok", "J Tests: a slow run clears after 6 h")

loose = lambda n: [{"t": T, "day": m.local_day(T), "stores": {"loose git objects · r": [n, 1]}}]
check(state_of(m.growth_section(loose(20000), T)) == "problem", "Growth: loose objects over the limit are red")
check(state_of(m.growth_section(loose(100), T)) == "ok", "J Growth: a repacked repository clears")
big = lambda n: [{"t": T - 7 * 86400, "day": "w", "stores": {"s": [30000, 1]}},
                 {"t": T, "day": m.local_day(T), "stores": {"s": [n, 1]}}]
check(state_of(m.growth_section(big(70000), T)) == "problem", "Growth: a big store that doubled is red")
check(state_of(m.growth_section(big(20000), T)) == "ok", "J Growth: a pruned store clears")

path = os.path.join(work, "c1d2e3f4-aaaa.jsonl")
put(path, "".join(json.dumps(e) + "\n" for e in (
    {"timestamp": "2026-09-29T10:00:00Z", "message": {"content": [
        {"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "ls"}}]}},
    {"timestamp": "2026-09-29T10:00:01Z", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_1"}]}})))
events = []
m.read_transcript(path, {"off": 0}, events, {})
check([e[8:] for e in events] == [["c1d2e3f4", 0]], "a call row carries its session and the transcript size at the call")
merged = m.tool_floors({"floors": {"bash:trivial": timed([(0, "k", 400.0, False)])["k"],
                                   "event:Stop": timed([(0, "k", 9000.0, False)])["k"]}})
check(merged[0] == 1 and merged[2] == 400, "the period hook wait merges tool floors and leaves turn events out")

state = {"born": T - 7200}
part = m.floors_section(m.hook_view(hooks, *traffic(250, 200), now=T), names, T)
m.attach_causes(state, [part], [{"at": T - 900, "kind": "edited", "what": "x"}], lambda at: ["–", "–"], T)
check(part["lead"][0]["cells"][0] == "started before %s · cause unknown" % m.time.strftime("%H:%M", m.time.localtime(T - 7200)),
      "a rule seen for the first time claims no cause")
later = m.floors_section(m.hook_view(hooks, *traffic(30, 40, prompt_ms=80.0, trivial_ms=2.0), now=T + 4000), names, T + 4000)
m.attach_causes(state, [later], [], lambda at: ["–", "–"], T + 4000)
check(later["state"] == "ok" and not later["lead"] and "floor:bash:trivial" not in state["firstred"],
      "J: a cleared area drops its cause line and its first-red record")

PINNED = {"call_s": 5.0, "call_note_s": 3.0, "call_min_calls": 5, "cut_share": 0.01, "cut_min": 3, "event_s": 5.0,
          "hook_p50_s": 1.0, "hook_min_samples": 5,
          "suites_at_once": 5, "suites_note": 3, "test_slow_ratio": 2.0, "test_slow_min_s": 600,
          "test_slow_fresh_s": 6 * 3600, "test_cost_window_s": 24 * 3600, "long_pole_share": 0.5,
          "long_pole_min_s": 300, "test_day_s": 2 * 3600, "test_day_note_s": 3600, "loose_note": 6700, "loose_red": 13400, "store_entries": 50000,
          "store_bytes": 1 << 30, "store_growth": 2.0, "impact_min_calls": 3, "floor_ms": 300, "floor_note_ms": 150,
          "floor_write_ms": 500, "floor_event_ms": 1000, "hook_note_ms": 150, "every_call_ms": 50,
          "full_work_ratio": 0.8, "full_work_min_ms": 10, "split_min_runs": 10, "history_ratio": 1.5,
          "history_min_ms": 20, "load_fail_suites": 3, "load_pass_within_s": 3600, "menu_ms": 300,
          "menu_note_ms": 100, "menu_min_builds": 3, "per_call_entries": 1000, "collector_cpu_s": 20.0,
          "stop_repeat_s": 1800, "ask_deferred_s": 7200, "silent_s": 21600, "growth_min_b": 120, "watch_tick_s": 120,
          "hold_note_s": 60, "wait_red_s": 600, "wait_growth": 2.0, "wait_growth_days": 3,
          "worker_orphans": 3}
check(m.LIMITS == PINNED, "LIMITS match design §4; a fixer never loosens the judge, a change here goes through a handoff")
check((m.PROOF_MIN_EXPOSURE, m.SEEN_GAP_S, m.DISMISSED) == (20, 86400, ("not-a-bug", "weather")),
      "the proof minimum, the first_seen gap and the dismissal statuses are pinned")

empty = {"floors": [], "split": {}, "joined": 0, "tool_batches": 0}
check(state_of(m.floors_section(empty, {}, T)) == "blind", "Hook waits with no batch joined is blind, not ok")
check(state_of(m.load_section([], T)) == "blind", "Load with no sample is blind, not ok")

ledger0 = {"rows": []}
seen_state = {}
first_run = m.problems_from([m.waits_section(slow, [], [], week, T)], ledger0, seen_state, T)
wait_ids = [p for p in first_run if p["rule"] == "wait"]
check(len(wait_ids) == 1 and wait_ids[0]["state"] == "new" and wait_ids[0]["id"] == "wait:bash:alpha"
      and wait_ids[0]["value"] == 8.0 and wait_ids[0]["limit"] == 5.0 and wait_ids[0]["exposure"] == 6
      and len(wait_ids[0]["evidence"]) == 3 and wait_ids[0]["evidence"][0]["ref"].startswith("tool_use "),
      "a red Waits row is a problem with rule, value, limit, exposure and one event per evidence item")
m.problems_from([m.waits_section([], [], [], week, T + 3600)], ledger0, seen_state, T + 3600)
again = [s2[:1] + [s2[1] + 7200] + s2[2:] for s2 in slow]
later_run = m.problems_from([m.waits_section(again, [], [], week, T + 7200)], ledger0, seen_state, T + 7200)
check([p["first_seen"] for p in later_run if p["id"] == "wait:bash:alpha"] == [wait_ids[0]["first_seen"]],
      "a problem red two hours ago and again now keeps its first_seen")
mixed = [["c", T - 1000 + i * 60, "gamma", "Bash", 1, secs, "c", "m%d" % i] for i, secs in enumerate((8.0, 8.0, 8.0, 1.0, 1.0))]
runs_state = {}
for run in range(10):
    counted = [p for p in m.problems_from([m.waits_section(mixed, [], [], week, T + run * 60)], ledger0, runs_state,
                                          T + run * 60) if p["id"] == "wait:bash:gamma"]
check([(p["count"], p["runs_red"]) for p in counted] == [(3, 10)],
      "count is the calls the rule judged bad in its window; runs_red the collector runs that judged it")
long_a = [["c", T - 1000 + i * 60, "a-very-long-project-name-one", "Bash", 1, 8.0, "c", "la%d" % i] for i in range(6)]
long_b = [["c", T - 990 + i * 60, "a-very-long-project-name-two", "Bash", 1, 8.0, "c", "lb%d" % i] for i in range(6)]
ids = [p["id"] for p in m.problems_from([m.waits_section(long_a + long_b, [], [], week, T)], ledger0, {}, T)
       if p["rule"] == "wait"]
check(len(set(ids)) == 2 and not any("…" in i for i in ids), "problem ids come from identity, never a clipped label")

loose = m.hooks_section(hooks, [], [], [], 0, quiet_hook, quiet_hook, T, unjournaled=set())
flag = [x for x in loose["lead"] if x.get("key") == "hooks:unjournaled"]
check(loose["state"] == "problem" and flag and flag[0]["red"]
      and {j["rule"] for j in flag[0]["judge"]} == {"unjournaled"},
      "a settings hook with no hook-time line is a problem of its own")
idents = {m.hook_ident(h["command"]) for h in hooks}
check(not [x for x in m.hooks_section(hooks, [], [], [], 0, quiet_hook, quiet_hook, T, unjournaled=idents)["lead"]
           if x.get("key") == "hooks:unjournaled"], "a ledger dismissal by exact ident spares that hook")

fixed_at = T - 7200
fixed_row = {"id": "fix-a", "title": "a", "match": {"rule": "floor", "ident": "bash:trivial"}, "status": "fixed",
             "fixes": [{"at": m.iso_time(fixed_at), "by": "t", "files": [], "in": "r@abc", "regressed_at": None}]}
quiet_v = {"judge": [m.verdict("floor", "bash:trivial", 90, 300, "ms", 1, 25, None)], "cells": ["x"]}
proof = m.problems_from([{"rows": [quiet_v]}], {"rows": [fixed_row]}, {}, T)
check([(p["id"], p["state"], p["fact"].split(" · a")[0]) for p in proof]
      == [("fix-a", "fixed-pending", "fixed · 25 events since · 0 matched")],
      "a fix under its limit with enough exposure since reads fixed · E events since · 0 matched")
thin = {"judge": [m.verdict("floor", "bash:trivial", 90, 300, "ms", 1, 5, None)], "cells": ["x"]}
check(m.problems_from([{"rows": [thin]}], {"rows": [fixed_row]}, {}, T)[0]["fact"].startswith("unproven · 5 events"),
      "a fix with too little exposure reads unproven, never fixed")
back = {"judge": [m.verdict("floor", "bash:trivial", 400, 300, "ms", 1, 25, "red",
                            evidence=[m.evidence(T - 60, "tool_use x")])], "cells": ["x"]}
old_ev = {"judge": [m.verdict("floor", "bash:trivial", 400, 300, "ms", 1, 25, "red",
                              evidence=[m.evidence(fixed_at - 60, "tool_use y")])], "cells": ["x"]}
check([p["state"] for p in m.problems_from([{"rows": [back]}], {"rows": [fixed_row]}, {}, T)] == ["regressed"]
      and [p["state"] for p in m.problems_from([{"rows": [old_ev]}], {"rows": [fixed_row]}, {}, fixed_at + 600)]
      == ["fixed-pending"], "only an event that started after the fix regresses it")
selfp = m.problems_from([], ledger0, {}, T, [m.verdict("collector", "run", 45.0, 30.0, "s", 0, 1, "red")])
check([(p["id"], p["state"]) for p in selfp] == [("collector:run", "new")], "a slow collector run is a problem")
check(m.collector_verdict(cpu=25.0, wall=30.0, backfill=False)["level"] == "red"
      and m.collector_verdict(cpu=25.0, wall=30.0, backfill=True)["level"] is None
      and m.collector_verdict(cpu=10.0, wall=600.0, backfill=False)["level"] is None,
      "the collector is judged on its own CPU-s: a saturated machine's wall is context, never its fault")

subprocess = m.subprocess
repo = os.path.join(work, "fixrepo")
subprocess.run(["git", "init", "-q", repo], check=True)
put(os.path.join(repo, "f.sh"), "x\n")
subprocess.run(["git", "-C", repo, "add", "f.sh"], check=True)
subprocess.run(["git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x"], check=True)
os.environ["HARNESS_REPOS_DIR"] = work
pending = {"rows": [{"id": "p", "status": "fixed-pending", "match": {"rule": "floor", "ident": "edit"},
                     "fixes": [{"at": m.iso_time(m.time.time() - 3600), "files": ["fixrepo/f.sh"], "in": None}]}]}
head = subprocess.run(["git", "-C", repo, "log", "-1", "--format=%h"], capture_output=True, text=True).stdout.strip()
check(m.settle_fixes(pending) and pending["rows"][0]["status"] == "fixed"
      and pending["rows"][0]["fixes"][-1]["in"] == "fixrepo@" + head,
      "the doctor turns a fixed-pending row fixed once its files are committed")
put(os.path.join(repo, "f.sh"), "y\n")
dirty = {"rows": [dict(pending["rows"][0], status="fixed-pending",
                       fixes=[dict(pending["rows"][0]["fixes"][0], **{"in": None})])]}
check(not m.settle_fixes(dirty) and dirty["rows"][0]["status"] == "fixed-pending",
      "an uncommitted fix stays fixed-pending")
main = os.path.join(work, "projects", "llm-legs")
subprocess.run(["git", "init", "-q", main], check=True)
subprocess.run(["git", "-C", main, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"],
               check=True)
subprocess.run(["git", "-C", main, "worktree", "add", "-q", os.path.join(main, ".claude", "worktrees", "n")], check=True)
saved_root, saved_repos = m.ROOT_DIR, os.environ.pop("HARNESS_REPOS_DIR")
m.ROOT_DIR = os.path.join(main, ".claude", "worktrees", "n")
check(m.repos_dir() == os.path.realpath(os.path.join(work, "projects")),
      "run in a linked worktree, the doctor finds the repositories beside the main checkout: %s" % m.repos_dir())
m.ROOT_DIR = saved_root
os.environ["HARNESS_REPOS_DIR"] = saved_repos

race, prior_ledger = os.path.join(work, "race-ledger.json"), os.environ["HARNESS_LEDGER"]
os.environ["HARNESS_LEDGER"] = race
put(os.path.join(repo, "f.sh"), "x\n")
stale = {"rows": [dict(pending["rows"][0], status="fixed-pending", fixes=[dict(pending["rows"][0]["fixes"][0], **{"in": None})])]}
put(race, m.json.dumps(stale))
loaded, _ = m.load_ledger()
m.record_settled(m.settled_path(), m.settle_fixes(loaded))
landed = m.json.loads(open(race).read())
landed["rows"].append({"id": "landed-meanwhile", "status": "open", "fixes": []})
put(race, m.json.dumps(landed))
tracked = open(race).read()
after, _ = m.load_ledger()
check(open(race).read() == tracked and m.json.loads(tracked)["rows"][0]["status"] == "fixed-pending"
      and [r["id"] for r in after["rows"]] == ["p", "landed-meanwhile"] and after["rows"][0]["status"] == "fixed"
      and after["rows"][0]["fixes"][-1]["in"] == "fixrepo@" + head,
      "settling a fix writes only the overlay: the tracked ledger keeps its bytes, a row landed meanwhile survives, "
      "and every read merges the settled row")
committed = m.json.loads(tracked)
committed["rows"][0]["fixes"][-1]["in"] = "fixrepo@0000000"
put(race, m.json.dumps(committed))
after, _ = m.load_ledger()
check(after["rows"][0]["fixes"][-1]["in"] == "fixrepo@0000000" and after["rows"][0]["status"] == "fixed-pending",
      "a value the tracked ledger holds wins over the overlay")
os.environ["HARNESS_LEDGER"] = prior_ledger

subprocess.run(["git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty",
                "-m", "landed"], check=True, env=dict(os.environ, GIT_COMMITTER_DATE="@%d" % (T - 600)))
late_row = dict(fixed_row, fixes=[dict(fixed_row["fixes"][0], **{"in": "fixrepo@" + subprocess.run(
    ["git", "-C", repo, "log", "-1", "--format=%h"], capture_output=True, text=True).stdout.strip()})])
before_landing = {"judge": [m.verdict("floor", "bash:trivial", 400, 300, "ms", 1, 25, "red",
                                      evidence=[m.evidence(T - 3000, "tool_use z")])], "cells": ["x"]}
check([p["state"] for p in m.problems_from([{"rows": [before_landing]}], {"rows": [late_row]}, {}, T)]
      == ["fixed-pending"]
      and [p["state"] for p in m.problems_from([{"rows": [back]}], {"rows": [late_row]}, {}, T)] == ["regressed"],
      "a fix dates from when its commit landed, so an event between its at and the landing regresses nothing")
night = os.path.join(work, "nightrepo")
subprocess.run(["git", "init", "-q", night], check=True)
for name in ("a.sh", "b.sh", "c.sh"):
    put(os.path.join(night, name), "old\n")
def night_commit(at, *args):
    subprocess.run(["git", "-C", night, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q"] + list(args),
                   check=True, env=dict(os.environ, GIT_COMMITTER_DATE="@%d" % at, GIT_AUTHOR_DATE="@%d" % at))
subprocess.run(["git", "-C", night, "add", "."], check=True)
night_commit(T - 9000, "-m", "x")
put(os.path.join(night, "b.sh"), "fixed\n")
night_commit(T - 600, "-am", "land b")
put(os.path.join(night, "c.sh"), "poured\n")
pending_of = {name: dict(fixed_row, status="fixed-pending", fixes=[dict(fixed_row["fixes"][0], files=["nightrepo/" + name],
                                                                        **{"in": None})]) for name in ("a.sh", "b.sh", "c.sh")}
check([[p["state"] for p in m.problems_from([{"rows": [ev]}], {"rows": [pending_of[name]]}, {}, T)]
       for name in ("a.sh", "b.sh", "c.sh") for ev in (before_landing, back)]
      == [["fixed-pending"], ["fixed-pending"], ["fixed-pending"], ["regressed"], ["regressed"], ["regressed"]]
      and [p["id"] for p in m.problems_from([{"rows": [quiet_v]}], {"rows": [pending_of["a.sh"]]}, {}, T)] == [],
      "a fix with in null holds from its landing: absent from main (a night branch) nothing regresses or proves it, "
      "committed there it dates from that commit, poured uncommitted from its at")

roots = os.environ.pop("HARNESS_WATCH_ROOTS")
check(os.path.join(m.ROOT_DIR, "hammerspoon") in m.watch_roots(), "the change log watches hammerspoon/*.lua")
os.environ["HARNESS_WATCH_ROOTS"] = roots
logged = m.watch_changes({"watched": {}, "settings": {"statusLine.refreshInterval": "5"}}, T, {}, [])
check([c["what"] for c in logged if c["kind"] == "setting"] == ["statusLine.refreshInterval 5 → unset"],
      "a settings key change outside hooks is logged")
floor_row = {"key": "floor:edit", "say": "an Edit waits 600 ms · edit-conflict-notice before", "cells": ["Edit"]}
ranked = m.rank_changes([{"at": T - 60, "kind": "edited", "what": "~/hooks/other.sh"},
                         {"at": T - 3000, "kind": "edited", "what": "~/hooks/edit-conflict-notice.sh"}],
                        floor_row, T, m.change_impact([], [], T))
check(ranked[0]["what"].endswith("edit-conflict-notice.sh"), "the change naming the red row's hook ranks first")
check(m.change_table([], m.change_impact([], [], T), "load:busy")["columns"][3:] == ["CPU busy", "new proc/s"]
      and m.change_table([], m.change_impact([], [], T), "floor:edit")["columns"][3:]
      == ["hook wait ms", "short Bash s"], "the cause table shows the measures of the rule that went red")

two_cuts = [["x", c[1] + 1, "alpha", "PostToolUse", "", 10000, 10000, "Bash", c[7]] for c in cut_calls[:2]]
check(state_of(m.waits_section(cut_calls, two_cuts, [], week, T)) == "watch", "two cuts in the hour are a watch")
quick = [{"label": "t", "repo": "r", "end": T - 3600 * (5 - i), "secs": 60.0, "who": "c"} for i in range(4)]
quick.append({"label": "t", "repo": "r", "end": T - 60, "secs": 300.0, "who": "c"})
check(state_of(m.tests_section(quick, T)) == "watch", "a run five times its usual under 10 min is a watch")

def iso(t):
    return m.time.strftime("%Y-%m-%dT%H:%M:%SZ", m.time.gmtime(t))

def jl(path, rows):
    put(path, "".join(json.dumps(r) + "\n" for r in rows))

def scoped_history(last_secs, marked=True, last_partial=False):
    cache = os.path.join(work, "scope-%d-%d-%d" % (last_secs, marked, last_partial))
    fulls = [609, 1251, 1115, 944, 502, 433, 497, 575, 492]
    partials = [21, 45, 60, 88, 120, 150, 197, 33, 70, 110, 180, 95, 64, 140, 52, 170]
    rows, marks, at = [], [], T - 40 * 3600
    for i in range(len(partials)):
        start = at + i * 3600
        rows.append(test_row("/r/llm-legs", "test_worker_run", start, start + partials[i]))
        marks.append({"start": start + 2, "label": "test_worker_run", "scope": "partial", "pid": i})
        if i < len(fulls):
            rows.append(test_row("/r/llm-legs", "test_worker_run", start + 1800, start + 1800 + fulls[i]))
    rows.append(test_row("/r/llm-legs", "test_worker_run", T - 100 - last_secs, T - 100))
    if last_partial:
        marks.append({"start": T - 98 - last_secs, "label": "test_worker_run", "scope": "partial", "pid": 99})
    jl(os.path.join(cache, "test-history.jsonl"), rows)
    if marked:
        jl(os.path.join(cache, "test-scope.jsonl"), marks)
    os.environ["STATUSLINE_CACHE_DIR"], saved = cache, os.environ["STATUSLINE_CACHE_DIR"]
    try:
        return m.load_tests(T)
    finally:
        os.environ["STATUSLINE_CACHE_DIR"] = saved

def slow_level(tests):
    return [j["level"] for r in m.tests_section(tests, T)["rows"] for j in r.get("judge", []) if j["rule"] == "test_slow"]
loaded = scoped_history(614)
check([t.get("partial") for t in loaded].count(True) == 16 and [t.get("partial") for t in loaded].count(False) == 10,
      "B: a test-scope marker flags exactly the partial runs it started")
check(slow_level(loaded) == [None], "B: an ordinary full run among short partial ones is quiet")
check(slow_level(scoped_history(1900)) == ["red"], "B: a genuinely slow full run among partial ones stays red")
check(slow_level(scoped_history(614, marked=False)) == [None] and slow_level(scoped_history(1900, marked=False)) == ["red"],
      "B: with no marker the p75 of the runs before compares a full run with full runs")
check(slow_level(scoped_history(150, last_partial=True)) == [None], "B: a partial run is judged against partial runs")

def marked_history(name, rows, marks):
    cache = os.path.join(work, name)
    jl(os.path.join(cache, "test-history.jsonl"), rows)
    jl(os.path.join(cache, "test-scope.jsonl"), marks)
    os.environ["STATUSLINE_CACHE_DIR"], saved = cache, os.environ["STATUSLINE_CACHE_DIR"]
    try:
        return m.load_tests(T)
    finally:
        os.environ["STATUSLINE_CACHE_DIR"] = saved

def suites_mix(last_secs, last_scope="full"):
    rows, marks, at = [], [], T - 30 * 3600
    for i, (scope, secs) in enumerate([("full", 900)] * 2 + [("named", 40)] * 10 + [(last_scope, last_secs)]):
        start = at + i * 7200 if i < 12 else T - 100 - last_secs
        rows.append(dict(test_row("llm-legs", "suites", start, start + secs), repo_root="/r/llm-legs"))
        marks.append({"start": start + 1, "label": "suites", "scope": scope, "pid": i, "repo_root": "/r/llm-legs"})
    return marked_history("mix-%d-%s" % (last_secs, last_scope), rows, marks)
check(slow_level(suites_mix(950)) == [None], "a full suites run is compared with full runs, never with named-suite ones")
check(slow_level(suites_mix(2500)) == ["red"], "a genuinely slow full suites run among named ones stays red")
slow_mix = suites_mix(2500)
own = {"kind": "suites", "repo_root": "/r/llm-legs", "started_at": T - 2590, "ended_at": T - 110}
peer = {"kind": "suites", "repo_root": "/r/llm-legs", "started_at": T - 2000, "ended_at": T + 300}
crowded = [j["level"] for r in m.tests_section(slow_mix, T, (), [own, peer])["rows"] for j in r.get("judge", [])
           if j["rule"] == "test_slow"]
check(crowded == ["watch"], "a slow full suites run another full run of the same repo overlapped is a watch, not red")
check(slow_level(slow_mix) == ["red"] and [j["level"] for r in m.tests_section(slow_mix, T, (), [
          own, dict(peer, repo_root="/r/other"), dict(peer, kind="direct"), dict(peer, started_at=T - 90)])["rows"]
          for j in r.get("judge", []) if j["rule"] == "test_slow"] == ["red"],
      "J its own journal row, another repo's run, a direct run or one after it ends leaves the slow run red")
hang_root = os.path.join(work, "hang-repo")
def hang_run(kind, end, suites, **kw):
    return dict({"kind": kind, "pid": 4242, "started_at": end - 4000, "ended_at": end, "repo": hang_root,
                 "repo_root": hang_root, "worker_run": None, "session": None, "suites": suites}, **kw)
hang_logs = os.path.join(work, "hang-tmp")
for logdir, at, tail in (("run-suites.AAAAAA", T - 700, "run-suites: TIMEOUT after 3600 s, its process tree killed\n"),
                         ("run-suites.BBBBBB", T - 690, "ok 12\n"), ("run-suites.CCCCCC", T - 9000, "run-suites: TIMEOUT after 3600 s\n")):
    os.makedirs(os.path.join(hang_logs, logdir))
    hang_log = os.path.join(hang_logs, logdir, "test_tty.sh.log")
    with open(hang_log, "w") as handle:
        handle.write("waiting on the tty\n" + tail)
    os.utime(hang_log, (at, at))
hang_runs = [hang_run("suites", T - 600, {"test_tty.sh": {"rc": 124, "secs": 3601.2}, "test_ok.sh": {"rc": 0, "secs": 30},
                                          "test_red.sh": {"rc": 1, "secs": 4000}, "test_long.sh": {"rc": 0, "secs": 9000},
                                          "test_sig.sh": {"rc": 0, "secs": 30, "bound": 3600},
                                          "test_cut.sh": {"rc": 0, "secs": 30, "bound": 3600}},
                      worker_run="claudeb-1-2-ab"),
             hang_run("direct", T - 300, {"test_sig.sh": {"rc": 143, "secs": 3700}}, session="5e55a0ff-0000", signal=15),
             hang_run("direct", T - 200, {"test_cut.sh": {"rc": 143, "secs": 600}}, signal=15),
             hang_run("direct", T - 100, {"test_own.sh": {"rc": 124, "secs": 3700}}),
             hang_run("direct", T - 50, {"test_new.sh": {"rc": 137, "secs": 9000}}, signal=9)]
saved_tmp, os.environ["TMPDIR"] = os.environ.get("TMPDIR"), hang_logs
hang_part = m.tests_section(slow_mix, T, (), hang_runs)
os.environ["TMPDIR"] = saved_tmp
hang_v = {v["ident"]: v for v in m.all_verdicts([hang_part]) if v["rule"] == "test_hang"}
tty = hang_v.get("hang-repo:test_tty", {})
check(tty.get("level") == "red" and tty.get("value") == 1 and tty.get("bad") == 1 and tty.get("exposure") == 1
      and tty["evidence"][0]["ref"] == os.path.join(hang_logs, "run-suites.AAAAAA", "test_tty.sh.log")
      and tty["evidence"][0]["account"] == "claudeb-1-2-ab"
      and all(s in tty["fact"] for s in ("hung 1 time", "1 h 00 min wasted", "per-suite bound after 3601 s",
                                         "claudeb-1-2-ab", "run-suites.AAAAAA/test_tty.sh.log")),
      "a suite run-suites ended by its bound (rc 124) is a red test_hang from the first time, with count, wasted time, its log and the run that hit it: %s" % tty)
check([p["id"] for p in m.problems_from([hang_part], {"rows": []}, {}, T) if p["rule"] == "test_hang"]
      == ["test_hang:hang-repo:test_sig", "test_hang:hang-repo:test_tty"] and hang_part["state"] == "problem",
      "a hang is a Tests problem named test_hang:<repo>:<suite>")
check(hang_v.get("hang-repo:test_sig", {}).get("level") == "red" and "killed by signal 15" in hang_v["hang-repo:test_sig"]["fact"]
      and "session 5e55a0ff" in hang_v["hang-repo:test_sig"]["fact"],
      "a suite killed by a signal after running past its bound is a hang too, named by the session that ran it")
check([hang_v.get("hang-repo:" + s, {}).get("level") for s in ("test_ok", "test_red", "test_long", "test_cut", "test_own",
                                                                 "test_new")] == [None] * 6,
      "a plain FAIL, a slow pass, a signal under the bound, a direct run's own exit 124 and a signal on a suite "
      "run-suites never bounded are no hang")
check(slow_level(slow_mix) == ["red"] and [j["level"] for r in hang_part["rows"] for j in r.get("judge", [])
                                           if j["rule"] == "test_slow"] == ["red"],
      "a slow passing suite stays with test_slow beside the hang rule")
check(m.suite_bound([hang_run("suites", T - 10 * i, {"test_p.sh": {"rc": 0, "secs": 400, "bound": b}})
                     for i, b in enumerate((4500, 3600, 9000))], hang_root, "test_p.sh") == 4500
      and m.suite_bound([hang_run("suites", T, {"test_p.sh": {"rc": 0, "secs": 400}})], hang_root, "test_p.sh") is None
      and m.suite_bound([hang_run("suites", T, {"test_p.sh": {"rc": 0, "secs": 400, "bound": 4500}})], "/r/other",
                        "test_p.sh") is None,
      "the hang bound is the one run-suites last journaled for the suite in its repo, none before it bounded one")
check(slow_level(suites_mix(700, "named")) == ["red"]
      and [r["say"] for r in m.tests_section(suites_mix(700, "named"), T)["rows"]][0].endswith("for a named-suites run"),
      "a named-suites run is judged against named-suite runs and says so")
near = [dict(test_row("⧉ wt-two", "test_near", T - 700, T - 400), repo_root="/r/wt-family"),
        dict(test_row("llm-legs", "test_near", T - 698, T - 100), repo_root="/r/llm-legs")]
near_marks = [{"start": T - 699, "label": "test_near", "scope": "partial", "pid": 1, "repo_root": "/r/wt-family"},
              {"start": T - 697, "label": "test_near", "scope": "full", "pid": 2, "repo_root": "/r/llm-legs"}]
check([(t["repo"], t.get("partial")) for t in marked_history("near", near, near_marks)]
      == [("⧉ wt-two", True), ("llm-legs", False)],
      "a scope marker joins only runs of its own repo_root, never a full run starting within seconds elsewhere")
fold = [dict(test_row("llm-legs", "test_fold", T - d * 86400 - 300, T - d * 86400), repo_root="/r/llm-legs")
        for d in (3, 2, 1)]
fold.append(dict(test_row("⧉ wt-one", "test_fold", T - 1600, T - 100), repo_root="/r/llm-legs"))
check([r["key"] for r in m.tests_section(fold, T)["rows"] if "test_fold" in r.get("key", "")]
      == ["tests:llm-legs:test_fold"] and slow_level(fold) == ["red"],
      "a worktree's run folds into its repository's test row, usual and id once the row names its repo_root")
check(m.test_ident("⧉ wt-one", "test_fold") == "worktree:wt-one:test_fold",
      "a row with no repo_root keeps a worktree id that names its worktree")

def aged(path, at, text=""):
    put(path, text)
    os.utime(path, (at, at))

def judged(part):
    return {(j["rule"], j["ident"]): j["level"] for r in part["rows"] for j in r.get("judge", [])}

health_n = [0]
def health(fn, stop=None, words=None, gates=None, events=None, beat="roots=2\n", beat_at=T - 30, baseline_at=T - 60,
           transcript_at=None, watched=True):
    health_n[0] += 1
    d = os.path.join(work, "health", str(health_n[0]))
    os.environ.update(STOP_GATE_JOURNAL=os.path.join(d, "stop.jsonl"), WORDS_DIR=os.path.join(d, "words"),
                      INSTRUCTION_WATCH_STATE=os.path.join(d, "watch"), CLAUDE_PROJECTS_DIR=os.path.join(d, "projects"))
    if stop is not None:
        jl(os.environ["STOP_GATE_JOURNAL"], stop)
    if words is not None:
        jl(os.path.join(d, "words", "journal.jsonl"), words)
    if fn is m.guards_section and watched:
        jl(os.path.join(d, "watch", "gates.jsonl"), gates or [])
        jl(os.path.join(d, "watch", "events.jsonl"), events or [])
        if beat is not None:
            aged(os.path.join(d, "watch", "watcher", "heartbeat"), beat_at, beat)
        if baseline_at is not None:
            aged(os.path.join(d, "watch", "session-a.tsv"), baseline_at, "x")
    if transcript_at is not None:
        aged(os.path.join(d, "projects", "p", "t.jsonl"), transcript_at, "{}\n")
    return fn(T)
saved_env = {k: os.environ.get(k) for k in ("STOP_GATE_JOURNAL", "WORDS_DIR", "INSTRUCTION_WATCH_STATE",
                                            "CLAUDE_PROJECTS_DIR")}

def stop(at, *hooks, busy="", session="s1"):
    return {"ts": iso(at), "session": session, "busy": busy,
            "hooks": [dict(zip(("name", "outcome", "reason"), h)) for h in hooks]}
S = m.stop_hooks_section
check(health(S)["state"] == "blind", "Stop hooks with no stop journal is blind, not ok")
check(health(S, stop=[stop(T - 90000, ("stop-dispatch-x", "error", "boom"))])["state"] == "ok",
      "J Stop hooks: an error older than 24 h clears")
for rule, outcome, busy in (("hook-error", "error", ""), ("hook-held", "held", ""), ("ask-busy", "asked", "bg:1")):
    part = health(S, stop=[stop(T - 600, ("ask-x", outcome, "why"), busy=busy)])
    check(judged(part) == {(rule, "ask-x"): "red"} and part["state"] == "problem"
          and part["rows"][0]["key"] == "stophooks:%s:ask-x" % rule, "Stop hooks: %s is red, keyed by hook" % rule)
check(judged(health(S, stop=[stop(T - 600, ("ask-x", "ran", "")), stop(T - 500, ("ask-x", "asked", "why"))])) == {},
      "J Stop hooks: a hook that ran, and a first ask while idle, are quiet")
check(judged(health(S, stop=[stop(T - 1200, ("ask-x", "asked", "why")), stop(T - 600, ("ask-x", "asked", "why"))]))
      == {("ask-repeat", "ask-x"): "red"}, "Stop hooks: the same ask twice in 30 min is red")
check(judged(health(S, stop=[stop(T - 3600, ("ask-x", "asked", "why")), stop(T - 600, ("ask-x", "asked", "why"))]))
      == {}, "J Stop hooks: the same ask an hour apart is quiet")
busy_id = m.slug("busy bg-task")
deferred = [stop(T - t, ("ask-x", "skipped-busy", ""), busy="bg-task:7") for t in (9000, 5000, 1000)]
check(busy_id and judged(health(S, stop=deferred)) == {("ask-deferred", busy_id): "red"},
      "Stop hooks: asks deferred by one busy reason over 2 h are red, keyed by the reason")
check(judged(health(S, stop=deferred[1:])) == {("ask-deferred", busy_id): "watch"},
      "Stop hooks: asks deferred over half the limit are a watch")
said = health(S, stop=deferred)["fact"]
check(said == "end-of-turn checks held back over 2 h while a background task ran, 1 time in 24 h",
      "Stop hooks: the area's line says what was held back and why in plain words: " + said)
check(judged(health(S, stop=deferred[:1] + [stop(T - 6000, ("ask-x", "ran", ""))] + deferred[1:2])) == {},
      "J Stop hooks: an ask that ran ends the deferral")
check(judged(health(S, stop=[dict(stop(T - t, ("ask-x", "skipped-busy", ""), busy="bg-task:7"), pid=p)
                             for t, p in ((9000, 11), (8000, 11), (2000, 22), (1000, 22))])) == {},
      "J Stop hooks: a chat closed and resumed (a new pid on two stops in a row) starts a new deferral")
check(judged(health(S, stop=[dict(s, pid=p) for s, p in zip(deferred, (11, 22, 33))]))
      == {("ask-deferred", busy_id): "red"},
      "Stop hooks: a pid new on every stop (a per-call shell) keeps one deferral")
word = {"ts": T - 600, "session": "s1", "hook": "review", "match": False, "model": ["review"]}
check(judged(health(S, stop=[], words=[word])) == {("word-miss", "review"): "red"},
      "Stop hooks: a word notice with no reading line is red, keyed by the word hook")
check(judged(health(S, stop=[], words=[word, {"mark": "ok", "ref": "%s:s1" % (T - 600)}])) == {},
      "J Stop hooks: a word miss marked ok clears")
families = os.path.join(work, "word-families.json")
put(families, json.dumps({"verbs": [], "families": {
    "review": {"label": "review", "aliases": ["ревью"]}, "commit": {"label": "commit+push", "aliases": ["коммит"]},
    "panel": {"label": "panel", "panels": {"max": ["max", "макс"]}}}}))
os.environ["WORDS_FAMILIES"] = families
os.environ["WORDS_LIB"] = os.path.join(os.environ.get("CLAUDE_SETUP_ROOT") or os.path.join(
    m.siblings_dir(os.path.dirname(os.path.dirname(sys.argv[1]))), "claude-setup"), "hooks", "lib", "words.sh")
glyphs = [dict(word, hook="⚡ review  ⚡ commit+push"), dict(word, ts=T - 500, hook="⚡review ⚡   commit+push"),
          dict(word, ts=T - 400, hook="⚡ ревью · T2 · double ⚡ готово: коммит+пуш")]
check(judged(health(S, stop=[], words=glyphs)) == {("word-miss", "commit+review"): "red"},
      "Stop hooks: notices that differ only in glyphs, spacing, language or detail share one family id")
check(judged(health(S, stop=[], words=[dict(word, hook="⚡ макс · T3")])) == {("word-miss", "panel"): "red"},
      "Stop hooks: a notice keyed by a panel name gets the family the words module assigns it")
os.environ.pop("WORDS_FAMILIES")
os.environ.pop("WORDS_LIB")
reading = {"ts": T - 600, "session": "s1", "unprompted": True, "match": False, "model": ["commit"]}
check(judged(health(S, stop=[], words=[reading])) == {("reading-miss", "unprompted"): "red"},
      "Stop hooks: a reading with no notice is red")
check(judged(health(S, stop=[], words=[dict(reading, silent=True)])) == {}, "J Stop hooks: a silent reading is quiet")
check(judged(health(S, stop=[stop(T - 30000, ("ask-x", "ran", ""))], transcript_at=T - 100))
      == {("stop-silent", "stop-dispatch"): "red"}, "Stop hooks: no stop line for 6 h while chats ran is red")
check(judged(health(S, stop=[stop(T - 200, ("ask-x", "ran", ""))], transcript_at=T - 100)) == {},
      "J Stop hooks: a recent stop line clears the silence")

big = os.path.join(work, "big-stop.jsonl")
jl(big, [stop(T - 90000 + i, ("ask-x", "error", "old " + "x" * 200)) for i in range(3000)]
   + [{"mark": "ok", "ref": "r"}] + [stop(T - 600 + i, ("ask-x", "error", "new")) for i in range(5)])
tail = m.read_jsonl(big, T - 86400)
check([r["hooks"][0]["reason"] for r in tail if r.get("ts", "") >= iso(T - 86400)] == ["new"] * 5
      and len(tail) < 500 and len(m.read_jsonl(big)) == 3006,
      "the journal reader seeks to the window and still returns every row inside it")

G = m.guards_section
cmd =os.path.join(home, ".claude", "CLAUDE.md")
def change(at, path=cmd, delta=500, kind="change", **kw):
    return dict({"at": iso(at), "kind": kind, "files": [path], "bytes": [delta]}, **kw)
check(health(G, watched=False)["state"] == "blind", "Guards with no instruction-watch state is blind, not ok")
check(health(G, events=[])["state"] == "ok", "J Guards: a watched, quiet day is ok")
check(judged(health(G, gates=[{"at": T - 600, "decision": "fault", "gate": "write", "detail": "boom"}]))
      == {("gate-fault", "write"): "red"}, "Guards: a gate fault is red, keyed by gate")
check(judged(health(G, gates=[{"at": T - 600, "decision": "denied", "gate": "write"}])) == {},
      "J Guards: a gate decision is no fault")
check(judged(health(G, events=[change(T - 600)])) == {("growth-ungated", "~/.claude/CLAUDE.md"): "red"},
      "Guards: instruction growth no gate saw is red, keyed by the file under ~")
check(judged(health(G, events=[change(T - 600, delta=80)])) == {("growth-ungated", "~/.claude/CLAUDE.md"): "watch"}
      and judged(health(G, events=[change(T - 600, delta=40)])) == {},
      "Guards: growth near the limit is a watch, small growth is quiet")
check(judged(health(G, events=[change(T - 600, os.path.join(home, "p", ".claude", "worktrees", "b1", "AGENTS.md"))]))
      == {("growth-ungated", "~/p/AGENTS.md"): "red"}, "Guards: a worktree file is keyed by its repository path")
check(judged(health(G, events=[change(T - 600, os.path.join(work, "x", "CLAUDE.md"))])) == {},
      "J Guards: growth in a temporary fixture tree is not judged")
check(judged(health(G, events=[change(T - 600, os.path.join(home, ".claude", "hooks", "gate.sh")),
                               change(T - 500, os.path.join(home, ".claude", "settings.json"))])) == {},
      "J Guards: growth of a file no gate class speaks for is not judged")
check(judged(health(G, events=[change(T - 600, kind="changed-between-sessions")]))
      == {("growth-ungated", "between-sessions"): "red"}, "Guards: growth between sessions has its own id")
skill = os.path.join(home, ".claude", "skills", "tool")
refs = [os.path.join(skill, "references", "r%d.md" % i) for i in range(40)]
install = dict(change(T - 600), files=[os.path.join(skill, "SKILL.md")] + refs, bytes=[900] + [5000] * 40)
part = health(G, events=[install])
check(judged(part) == {("growth-ungated", "~/.claude/skills/tool"): "red"}
      and [(j["value"], j["bad"]) for r in part["rows"] for j in r["judge"]] == [(900, 1)],
      "Guards: one install of a skill is one problem keyed by the skill, its SKILL.md priced and its on-demand "
      "files out of scope")
put(os.path.join(skill, "SKILL.md"), "---\nname: tool\n---\n")
check(judged(health(G, events=[dict(install, files=refs, bytes=[5000] * 40)])) == {},
      "J Guards: growth only in an installed skill's on-demand files is not judged")
docs = [os.path.join(home, "p", "docs", n) for n in ("a.md", "sub/b.md", "c.md")]
part = health(G, events=[dict(change(T - 600), files=docs + [os.path.join(skill, "SKILL.md")], bytes=[50, 50, 50, 70])])
check(judged(part) == {("growth-ungated", "~/p/docs"): "red", ("growth-ungated", "~/.claude/skills/tool"): "watch"}
      and sorted((j["ident"], j["value"], j["bad"]) for r in part["rows"] for j in r["judge"])
      == [("~/.claude/skills/tool", 70, 1), ("~/p/docs", 150, 3)],
      "Guards: two roots in one change are two problems, a docs tree summing its files' bytes")
check(judged(health(G, gates=[{"at": T - 700, "decision": "denied", "gate": "write", "file": p} for p in docs],
                    events=[dict(change(T - 600), files=docs, bytes=[100] * 3)]))
      == {("growth-denied", "~/p/docs"): "red"}, "Guards: growth after denials in one tree is one problem")
passed ={"at": T - 700, "decision": "passed", "gate": "write", "file": cmd}
check(judged(health(G, gates=[passed], events=[change(T - 600)])) == {}, "J Guards: growth a gate passed is quiet")
small = dict(passed, gate="bloat", delta=10)
check(judged(health(G, gates=[small], events=[change(T - 600, delta=2000)])) == {("growth-ungated", "~/.claude/CLAUDE.md"): "red"}
      and judged(health(G, gates=[small, dict(small, at=T - 650, delta=490)], events=[change(T - 600)])) == {},
      "Guards: a priced pass covers only the bytes it priced, never a larger write beside it")
denied = dict(passed, decision="denied")
check(judged(health(G, gates=[denied], events=[change(T - 600)])) == {("growth-denied", "~/.claude/CLAUDE.md"): "red"},
      "Guards: growth after a denial is red")
check(judged(health(G, gates=[denied], events=[change(T - 600, reverted=True)])) == {},
      "J Guards: a reverted change is quiet")
check(judged(health(G, events=[change(T - 600, kind="stamp-forged")])) == {("stamp-forged", "~/.claude/CLAUDE.md"): "red"}
      and judged(health(G, events=[change(T - 90000, kind="stamp-forged")])) == {},
      "Guards: a forged stamp is red and clears after 24 h")
for kind in ("changed-while-watcher-off", "baseline-missing", "dropped"):
    check(judged(health(G, events=[change(T - 600, kind=kind, sid="t")], transcript_at=T - 100)) == {(kind, "tripwire"): "red"}
          and judged(health(G, events=[change(T - 90000, kind=kind, sid="t")], transcript_at=T - 100)) == {},
          "Guards: %s is red and clears after 24 h" % kind)
check(all(judged(health(G, events=[change(T - 600, kind="baseline-missing", sid=sid)], transcript_at=T - 100)) == {}
          for sid in ("hlprof-a", "t*", None)),
      "Guards: a lost baseline of a session id no chat transcript owns is not judged")
synced = [os.path.join(home, ".claude", "skills", "synced", "org_acct", "pptx", "SKILL.md"),
          os.path.join(home, ".claude", "plugins", "synced", "org_acct", "kit", "skills", "make", "SKILL.md")]
put(os.path.join(home, ".claude", "skills", "synced", "org_acct", "manifest.json"),
    json.dumps({"lastUpdated": (T - 500) * 1000, "skills": [{"name": "pptx"}]}))
put(os.path.join(home, ".claude", "plugins", "synced", "org_acct", "manifest.json"),
    json.dumps({"lastUpdated": (T - 600) * 1000, "plugins": [{"name": "kit"}]}))
put(os.path.join(home, ".claude", "skills", "synced", "org_old", "manifest.json"),
    json.dumps({"lastUpdated": (T - 90000) * 1000, "skills": [{"name": "pptx"}]}))
check(judged(health(G, events=[dict(change(T - 600), files=synced, bytes=[2282, 9698])])) == {},
      "Guards: Claude Code's org sync into skills/synced and plugins/synced, which no gate sees, is not judged")
check(judged(health(G, events=[change(T - 600, os.path.join(home, ".claude", "skills", "synced", "org_acct", "handmade", "SKILL.md"), 5000),
                               change(T - 600, os.path.join(home, ".claude", "skills", "synced", "org_old", "pptx", "SKILL.md"), 5000)]))
      == {("growth-ungated", "~/.claude/skills/synced/org_acct/handmade"): "red",
          ("growth-ungated", "~/.claude/skills/synced/org_old/pptx"): "red"},
      "Guards: synced-tree growth the bucket manifest does not show the sync landing is judged")
check(judged(health(G, events=[change(T - 20000, synced[0], 5000)]))
      == {("growth-ungated", "~/.claude/skills/synced/org_acct/pptx"): "red"},
      "Guards: growth hours before the sync's own landing is not the sync's")
late = os.path.join(home, ".claude", "skills", "synced", "org_late")
put(os.path.join(late, "manifest.json"), json.dumps({"lastUpdated": (T - 100) * 1000, "skills": [
    {"name": "gws", "updatedAt": iso(T - 2400)}, {"name": "pptx", "updatedAt": iso(T - 9000)}]}))
check(judged(health(G, events=[change(T - 2000, os.path.join(late, "gws", "SKILL.md"), 994),
                               change(T - 2000, os.path.join(late, "pptx", "SKILL.md"), 994)]))
      == {("growth-ungated", "~/.claude/skills/synced/org_late/pptx"): "red"},
      "Guards: a landing a later round's lastUpdated moved past is the sync's by its entry's own updatedAt, and only then")
tree, landing = os.path.join(home, "p", ".claude", "worktrees", "b1", "AGENTS.md"), os.path.join(home, "p", "AGENTS.md")
check(judged(health(G, gates=[dict(passed, file=tree, at=T - 80050)], events=[change(T - 80000, tree), change(T - 600, landing)]))
      == {}, "Guards: a merge or copy landing bytes a worktree already grew by, up to a day before, is not new growth")
check(judged(health(G, gates=[dict(passed, file=tree, at=T - 4050)], events=[change(T - 4000, tree, 100), change(T - 600, landing)]))
      == {("growth-ungated", "~/p/AGENTS.md"): "red"}, "J Guards: a landing larger than the worktree's growth is judged")
check(judged(health(G, gates=[dict(passed, file=tree, at=T - 4050)], events=[change(T - 4000, tree, 600),
                                                                          change(T - 2000, landing, 600), change(T - 600, landing, 600)]))
      == {("growth-ungated", "~/p/AGENTS.md"): "red"}, "Guards: one worktree growth excuses one landing of its bytes, never a second")
os.symlink(os.path.join(home, "p"), os.path.join(home, "lnk"))
linked, priced = os.path.join(home, "lnk", "AGENTS.md"), dict(passed, gate="bloat", file=tree, at=T - 4050, delta=500)
check(judged(health(G, gates=[dict(priced, decision="granted")], events=[change(T - 600, linked)])) == {}
      and judged(health(G, gates=[dict(priced, decision="denied")], events=[change(T - 600, linked)]))
      == {("growth-ungated", "~/lnk/AGENTS.md"): "red"},
      "Guards: bytes a gate priced in a worktree the watcher never journaled excuse their landing, through a symlinked "
      "spelling too; a denial there excuses nothing")
check(judged(health(G, gates=[priced], events=[change(T - 4000, tree), change(T - 2000, landing), change(T - 600, linked)]))
      == {("growth-ungated", "~/lnk/AGENTS.md"): "red"},
      "Guards: a worktree write both priced by a gate and journaled by the watcher is one credit, never two")
check(judged(health(G, gates=[dict(denied, file=synced[0])], events=[change(T - 600, synced[0], 2282)]))
      == {("growth-denied", "~/.claude/skills/synced/org_acct/pptx"): "red"},
      "J Guards: growth a gate denied in a synced tree stays red")
up = os.path.join(home, "up")
def up_git(*args, at=T - 90000):
    import subprocess
    subprocess.run(["git", "-C", up, "-c", "user.name=t", "-c", "user.email=t@t"] + list(args), check=True,
                   capture_output=True, env=dict(os.environ, GIT_COMMITTER_DATE="@%d +0000" % at,
                                                 GIT_AUTHOR_DATE="@%d +0000" % at))
os.makedirs(up)
up_git("init", "-q", "-b", "main")
put(os.path.join(up, "CLAUDE.md"), "rules\n")
up_git("add", ".")
up_git("commit", "-qm", "a")
up_git("checkout", "-qb", "release")
put(os.path.join(up, "CLAUDE.md"), "rules\n" + "upstream rule\n" * 100)
put(os.path.join(up, ".claude", "skills", "s", "SKILL.md"), "skill\n" * 100)
up_git("add", ".")
up_git("commit", "-qm", "b")
up_git("checkout", "-q", "main")
up_git("fetch", "-q", ".", "release:refs/remotes/origin/release", at=T - 800)
up_git("checkout", "-q", "release", at=T - 700)
delivered = [os.path.join(up, "CLAUDE.md"), os.path.join(up, ".claude", "skills", "s", "SKILL.md")]
part = health(G, events=[dict(change(T - 600), files=delivered, bytes=[1300, 600])])
check(judged(part) == {} and part["state"] == "ok"
      and [(r["cells"], r["dim"]) for r in part["rows"]] == [(["upstream instruction growth · ~/up · +1 900 B", "2",
                                                               m.clock(T - 600, T)], True)],
      "Guards: instruction growth a checkout delivered from a fetched commit is one dim count row per repository, "
      "no problem")
put(os.path.join(up, "CLAUDE.md"), "rules\n" + "upstream rule\n" * 100 + "local rule\n" * 50)
part = health(G, events=[dict(change(T - 600), files=delivered, bytes=[1800, 600])])
check(judged(part) == {("growth-ungated", "~/up/CLAUDE.md"): "red"}
      and part["rows"][-1]["cells"][0] == "upstream instruction growth · ~/up · +600 B",
      "Guards: an uncommitted local edit beside a checkout is still ungated growth")
up_git("checkout", "-qb", "work")
up_git("commit", "-qam", "local")
up_git("checkout", "-q", "release")
up_git("merge", "-q", "--ff-only", "work", at=T - 650)
check(judged(health(G, events=[dict(change(T - 600), files=delivered[:1], bytes=[1800])]))
      == {("growth-ungated", "~/up/CLAUDE.md"): "red"},
      "Guards: a merge of a local commit (a land) is no upstream delivery, its ungated growth stays red")
source_root = os.path.dirname(os.path.dirname(sys.argv[1]))
libexec, agents = os.path.join(work, "libexec"), os.path.join(home, "Library", "LaunchAgents")
os.environ.update(HARNESS_LIBEXEC_DIR=libexec, HARNESS_DEPLOY_SOURCE=source_root)
D = m.deploys_section
check(D(T)["state"] == "ok" and D(T)["rows"] == [], "J Deploys: nothing installed is nothing judged")
for _, copies in m.DEPLOYS[:2]:
    for where, name, kind, src in copies:
        target = os.path.join(libexec if where == "libexec" else agents, name)
        put(target, open(os.path.join(source_root, src)).read() if kind == "copy" else
            '#!/usr/bin/env bash\nexec %s "$@"\n' % os.path.join(source_root, src))
check(judged(D(T)) == {} and D(T)["state"] == "ok", "Deploys: deployed copies equal to their repo sources are no problem")
put(os.path.join(libexec, "memlogd"), open(os.path.join(source_root, "bin", "memlogd")).read().replace("machine_tick", "x"))
put(os.path.join(libexec, "llm-refresh-heartbeat"), '#!/usr/bin/env bash\nexec /gone/bin/llm-refresh "$@"\n')
part = D(T)
check(judged(part) == {("deploy-drift", os.path.join(libexec, "memlogd")): "red",
                       ("deploy-drift", os.path.join(libexec, "llm-refresh-heartbeat")): "red"}
      and sorted(r["cells"][1] for r in part["rows"]) == ["bin/llm-refresh install-agent", "bin/memlogd install-agent"],
      "Deploys: a drifted copy or a wrapper exec-ing another script is one problem naming the installer that fixes it")
for _, copies in m.DEPLOYS[:2]:
    for where, name, _, _ in copies:
        os.remove(os.path.join(libexec if where == "libexec" else agents, name))
os.environ.pop("HARNESS_LIBEXEC_DIR")
os.environ.pop("HARNESS_DEPLOY_SOURCE")
B = m.browser_section
m.browser_processes = lambda: []
m.browser_chrome_runs = lambda: []
runs = os.environ["WORKER_RUN_DIR"]
shutil.rmtree(os.path.join(runs, "browse"), ignore_errors=True)
check(B(T)["state"] == "blind" and judged(B(T)) == {}, "Browser: nothing enrolled is blind, nothing judged")
stamp = lambda at: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at))
put(os.path.join(runs, "browse", "accounts.json"), json.dumps({
    "com": {"email": "c@x", "chrome_profile": "Profile 1", "status": "ok", "proven_at": stamp(T - 3600)},
    "notcom": {"email": "n@x", "chrome_profile": "Profile 10", "status": "needs-login", "last_error": "BROWSER_NO_DEVICE"},
    "quiet": {"email": "q@x", "chrome_profile": "Profile 3", "status": "ok", "proven_at": stamp(T - 8 * 86400)},
    "gone": {"email": "g@x", "status": "no-profile"}}))
log = [{"ts": stamp(T - 600), "run": "r-ok", "account": "com", "target": "chrome", "outcome": "BROWSER_OK", "workaround": False},
       {"ts": stamp(T - 500), "run": "r-int", "account": "com", "target": "chrome", "outcome": "BROWSER_INTERRUPTED",
        "workaround": False},
       {"ts": stamp(T - 400), "run": "r-miss", "account": "com", "target": "chrome", "outcome": "missing", "workaround": False},
       {"ts": stamp(T - 300), "run": "r-wa", "account": "com", "target": "chrome", "outcome": "BROWSER_OK", "workaround": True},
       {"ts": stamp(T - 80 * 3600), "run": "r-old", "account": "com", "target": "chrome", "outcome": "HARNESS_NEEDS_REPAIR"}]
put(os.path.join(runs, "browse", "log.jsonl"), "".join(json.dumps(e) + "\n" for e in log) + "not json\n")
part = B(T)
cells = {r["cells"][0]: r["cells"][1:] for r in part["rows"]}
check(judged(part) == {("browser-account", "notcom"): "watch", ("browser-account", "quiet"): "watch",
                       ("browser-repair", "runs"): "red"} and part["state"] == "problem",
      "Browser: needs-login and a 7-day quiet account are watches, a workaround or missing outcome is red")
check(cells["com"][0] == "Profile 1 · ok · proven 1 h 00 min ago · 72 h: BROWSER_INTERRUPTED ×1 · missing ×1"
      and cells["com"][1] == "", "Browser: an account row names profile, status, proven age and 72 h failures by kind")
check(cells["notcom"][1] == "dispatch share/briefs/claude-ext-login.md", "Browser: needs-login points at the login brief")
check(cells["quiet"][1] == "worker-run browse --enroll quiet", "Browser: a quiet account is re-enrolled")
check(cells["gone"][0] == "no profile · no-profile" and ("browser-account", "gone") not in judged(part),
      "Browser: an account without a Chrome profile is shown, not judged")
check(cells["Runs"] == ["harness needs repair · missing ×1 · workaround ×1", "worker-run transcript r-wa"],
      "Browser: the repair row counts kinds in 72 h and names the newest run")
put(os.path.join(runs, "browse", "accounts.json"), json.dumps({
    "com": {"email": "c@x", "chrome_profile": "Profile 1", "status": "ok", "proven_at": T - 3600}}))
put(os.path.join(runs, "browse", "log.jsonl"), "".join(json.dumps(dict(e, ts=stamp(T - 60))) + "\n" for e in (
    {"run": "enroll-com-1", "account": "com", "outcome": "missing"},
    {"run": "enroll-com-2", "account": "com", "outcome": "HARNESS_NEEDS_REPAIR"})))
cells = {r["cells"][0]: r["cells"][1:] for r in B(T)["rows"]}
check(cells["com"][0].startswith("Profile 1 · ok · proven 1 h 00 min ago")
      and cells["Runs"][1] == "browse/last-session-com.json",
      "Browser: repairs in one second and an epoch proven_at do not crash; a proof session points at its own file")
m.browser_processes = lambda: ["/Applications/Dia.app/Contents/MacOS/Dia",
                               "/Applications/Dia.app/Contents/MacOS/Dia --type=renderer"]
part = B(T)
restart = "Restart Dia with AppleScript JS — unsaved input may be lost"
acts = {r["cells"][0]: r.get("action") for r in part["rows"]}
check(judged(part).get(("browser-applescript-js", "dia")) == "watch" and acts[restart] == ["dia-js", "--relaunch"]
      and acts["Runs"] is None, "Browser: Dia without its JS flag is a watch and adds the restart row")
menu = m.MenuLines(0, 0, "t")
menu.layout(part, 0)
line = [l for l in menu.lines if restart in l][0]
check(line.split("\t")[1] == "a" and line.endswith("\tdia-js\x1f--relaunch"),
      "Browser: the restart row is flagged a and carries its argv after a tab, \\x1f between words")
m.browser_processes = lambda: ["/Applications/Dia.app/Contents/MacOS/Dia --enable-applescript-javascript"]
part = B(T)
check(("browser-applescript-js", "dia") not in judged(part) and restart not in [r["cells"][0] for r in part["rows"]],
      "Browser: Dia with its JS flag is fine and offers no restart")
check(not any(r["cells"][0].startswith("Show Chrome") for r in part["rows"]), "Browser: no live Chrome run, no hide row")
m.browser_chrome_runs = lambda: ["r1", "r2"]
acts = {r["cells"][0]: r.get("action") for r in B(T)["rows"]}
check(acts.get("Show Chrome") == ["worker-run", "browse", "--toggle"],
      "Browser: live Chrome runs add the Show Chrome toggle")
m.browser_chrome_runs = lambda: ["r1"]
part = B(T)
menu = m.MenuLines(0, 0, "t")
menu.layout(part, 0)
line = [l for l in menu.lines if "Show Chrome" in l][0]
check(line.split("\t")[1] == "va" and line.endswith("\tworker-run\x1fbrowse\x1f--toggle"),
      "Browser: the Show Chrome row is flagged v (checked live by the menu) and a")
m.browser_chrome_runs = lambda: []
calls = os.path.join(work, "browse-calls")
if os.path.exists(calls):
    os.remove(calls)
B(T)
time.sleep(0.3)
check(not os.path.exists(calls), "Browser: a read-only run never starts the canary")
B(T, write=True)
for _ in range(50):
    if os.path.exists(calls):
        break
    time.sleep(0.1)
check(open(calls).read().split() == ["browse", "--canary"], "Browser: a writing run starts the canary when its stamp is stale")
os.remove(calls)
for _ in range(50):
    if os.path.exists(os.path.join(runs, "browse", "canary.stamp")):
        break
    time.sleep(0.1)
B(T, write=True)
time.sleep(0.3)
check(not os.path.exists(calls), "Browser: a fresh canary stamp holds the next start")
shutil.rmtree(runs)
for beat, beat_at, ident in ((None, T, "never-started"), ("roots=2\n", T - 1000, "stale"),
                             ("roots=2\nerror=fsevents gone\n", T - 30, "error"), ("roots=0\n", T - 30, "no-root")):
    check(judged(health(G, beat=beat, beat_at=beat_at)) == {("watcher-down", ident): "red"},
          "Guards: watcher-down %s is red" % ident)
# A transcript's birth time is the real clock (utime cannot set it), and the rule takes the earlier of birth and mtime.
born = min(T - 100, int(__import__("time").time()))
check(judged(health(G, transcript_at=T - 100, baseline_at=born - 30000)) == {("baseline-silent", "tripwire"): "red"}
      and judged(health(G, transcript_at=T - 100, baseline_at=T - 60)) == {},
      "Guards: no baseline for 6 h after a chat started is red; a fresh baseline clears it")
ids = {p["id"] for p in m.problems_from([health(S, stop=[stop(T - 600, ("ask-x", "error", "x"))]),
                                         health(G, events=[change(T - 600)])], {"rows": []}, {}, T)}
check(ids == {"hook-error:ask-x", "growth-ungated:~/.claude/CLAUDE.md"},
      "Stop hooks and Guards problems carry <rule>:<ident> ids")
def grown(t, n, size=1, name="context-nudge state"):
    return {"t": t, "day": m.local_day(t), "stores": {name: [n, size]}}
judged_growth = lambda part: [(j["rule"], j["value"], j["limit"], j["unit"]) for r in part["rows"]
                              for j in r.get("judge", []) if j["level"]]
check(judged_growth(m.growth_section([grown(T - 30 * 3600, 1500), grown(T - 21 * 3600, 3100)], T))
      == [("store_runaway", 3100, 1000, "entries")],
      "G: a per-call store that doubled since yesterday's sample is a watch when today's sample is already 21 h old")
check(judged_growth(m.growth_section([grown(T - 3600, 10, 2 << 30, "some store")], T))
      == [("store_size", 2 << 30, 1 << 30, "bytes")],
      "G: a store over the byte limit reports its bytes and the byte limit, not its entry count")

settings_file = os.path.join(work, "watched-settings.json")
def settings_at(value, at):
    put(settings_file, json.dumps(value))
    os.utime(settings_file, (at, at))
saved_settings, os.environ["HARNESS_SETTINGS"] = os.environ["HARNESS_SETTINGS"], settings_file
settings_at({"env": {"API_KEY": "sk-old-secret"}, "permissions": {"allow": ["Bash(x%03d)" % i for i in range(20)]}}, T - 7200)
watched = {"watched": {}, "settings": {}}
m.watch_changes(watched, T - 7000, {}, [])
settings_at({"env": {"API_KEY": "sk-new-secret"},
             "permissions": {"allow": ["Bash(x%03d)" % i for i in range(20)] + ["Bash(added)"]}}, T - 7200)
logged = [c for c in m.watch_changes(watched, T, {}, []) if c["kind"] == "setting"]
os.environ["HARNESS_SETTINGS"] = saved_settings
check(sorted(c["what"].split()[0] for c in logged) == ["env.API_KEY", "permissions.allow"],
      "a change past the first 120 characters of a long setting is logged")
check([c["at"] for c in logged] == [T - 7200] * 2, "a setting change is dated by the file's mtime, even over an hour old")
check("secret" not in json.dumps(logged) + json.dumps(watched["settings"]),
      "an env value never reaches the change log or the state")

near_pair = [dict(test_row("llm-legs", "test_pair", T - 700, T - 100), repo_root="/r/llm-legs")]
pair_marks = [{"start": T - 704, "label": "test_pair", "scope": "named", "pid": 1, "repo_root": "/r/llm-legs"},
              {"start": T - 700, "label": "test_pair", "scope": "full", "pid": 2, "repo_root": "/r/llm-legs"}]
check([t["scope"] for t in marked_history("pair", near_pair, pair_marks)] == ["full"],
      "a run takes the scope marker nearest its start, not the first within the join window")

scoped = [dict(t) for t in history[:-1]] + [dict(history[-1], ok=True)]
for t in scoped:
    if t["label"] in ("test_claudeb", "test_worker_run"):
        t["scope"] = "full" if t.get("ok") is False else "named"
check([x for x in m.tests_section(scoped, T)["lead"] if x.get("key") == "tests:load"][0]["cells"][0]
      == "failed under load, 6 h: 0", "H: a full run that failed under load is not cleared by a named-suite run passing")

slow_fold = [j for r in m.tests_section(fold, T)["rows"] for j in r.get("judge", []) if j["rule"] == "test_slow"
             and j["level"]]
check([(j["evidence"][0]["at"], j["exposure"]) for j in slow_fold] == [(m.iso_time(T - 1600), 1)],
      "a slow test's evidence is its start, and its exposure counts only the runs in its window")
fold_fixed = {"rows": [{"id": "fold-fix", "match": {"rule": "test_slow", "ident": "llm-legs:test_fold"},
                        "status": "fixed", "fixes": [{"at": m.iso_time(T - 1000), "in": None}]}]}
check([p["state"] for p in m.problems_from([m.tests_section(fold, T)], fold_fixed, {}, T) if p["id"] == "fold-fix"]
      == ["fixed-pending"], "a slow run that started before the fix and ended after it does not regress the fix")
load_mix = history[:-1] + [dict(history[-1], ok=True)]
load_evidence = [j["evidence"][0]["at"] for x in m.tests_section(load_mix, T)["lead"]
                 if x.get("key") == "tests:load" for j in x["judge"]]
check(load_evidence and set(load_evidence) <= {m.iso_time(t["end"] - t["secs"]) for t in load_mix if t.get("ok") is False},
      "a load failure's evidence is the failed run's start")

twins = [test_row("⧉ wt-%s" % w, "test_same", T - 3600 * (4 - i) - 100, T - 3600 * (4 - i)) for w in "ab" for i in range(3)]
check(sorted(r["key"] for r in m.tests_section(twins, T)["rows"] if "test_same" in r["key"])
      == ["tests:worktree:wt-a:test_same", "tests:worktree:wt-b:test_same"],
      "two worktrees with no repo_root running one label keep separate rows and idents")

runs, calls = traffic(250, 200, nudge_big_ms=160)
view = m.hook_view(hooks, runs, calls, T)
t24 = timed(runs)
sync_part = m.hooks_section(hooks, calls, [], [], 0, t24, t24, T, view["split"], m.probe_fast_paths(hooks))
check({p["id"]: p["state"] for p in m.problems_from([sync_part], {"rows": []}, {}, T)}.get("hook_sync:gate-a.sh")
      == "watch", "E: a synchronous hook over 150 ms reaches the problems as a watch")
recent = m.hook_view(hooks, runs, calls, T, since=T - 1800)
check(0 < recent["tool_batches"] < view["tool_batches"] and len(recent["floors"]) == len(view["floors"])
      and 0 < len(recent["split"]["gate-a.sh"]["trivial"]) < len(view["split"]["gate-a.sh"]["trivial"]),
      "the hook view counts batches and splits only since its window start, and keeps every floor")

put(os.path.join(home, "hk", "lib", "readonly-command.sh"), 'rc_readonly_command() { return 0; }\n')
fast_fixed = {"rows": [{"id": "fast-fix", "match": {"rule": "fastpath", "ident": "readonly-command\\.sh:bash"},
                        "status": "fixed", "fixes": [{"at": m.iso_time(T - 3600), "in": None}]}]}
fast_broken = m.hooks_section(hooks, calls, [], [], 0, t24, t24, T, {}, m.probe_fast_paths(hooks))
put(os.path.join(home, "hk", "lib", "readonly-command.sh"), GOOD)
check([p["state"] for p in m.problems_from([fast_broken], fast_fixed, {}, T) if p["id"] == "fast-fix"] == ["regressed"],
      "D: a fast path failing now regresses its fix at once")

keep_state = {"journal": {"slots": {str(int((T - 30 * 3600) // m.SLOT_S * m.SLOT_S)): {"k": m.hist_new()}}}}
os.environ["HARNESS_DOCTOR_DIR"], saved_dir = os.path.join(work, "keep"), os.environ["HARNESS_DOCTOR_DIR"]
m.read_journals(keep_state, T, False)
check(len(keep_state["journal"]["slots"]) == 1, "hook slots live long enough for the previous 24 h window")
yesterday = m.local_day(T - 86400)
one = m.hist_new()
m.hist_put(one, 200)
put(os.path.join(os.environ["HARNESS_DOCTOR_DIR"], "days", yesterday + ".json"),
    json.dumps({"v": m.SUMMARY_V, "waits": {}, "slow_s": 0, "floors": {"edit": one}}))
late = {"rebuilt": m.SUMMARY_V, "journal": {"days": {}, "floor_days": {yesterday: {"edit": json.loads(json.dumps(one))}}}}
merged = m.day_summaries(late, T, True, [], [], [])
on_disk = m.read_json(os.path.join(os.environ["HARNESS_DOCTOR_DIR"], "days", yesterday + ".json"), {})
os.environ["HARNESS_DOCTOR_DIR"] = saved_dir
check(merged[yesterday]["floors"]["edit"][0] == on_disk["floors"]["edit"][0] == 2
      and yesterday not in late["journal"]["floor_days"],
      "floors that settle after their day was summarized join that day's summary")

def full_run(end, secs, times, scope=None):
    out = dict(test_row("llm-legs", "suites", end - secs, end), repo_root="/r/llm-legs", suite_secs=times)
    if scope:
        out["scope"] = scope
    return out

def cost_judges(tests, key):
    part = m.tests_section(tests, T)
    lead = [x for x in part["lead"] if x.get("key") == key][0]
    return part, lead, {j["ident"]: j for r in (lead.get("menu") or {}).get("rows", []) for j in r.get("judge", [])}

poles = [full_run(T - 7200, 700, {"test_big.sh": 300, "test_mid.sh": 290}),
         full_run(T - 600, 700, {"test_big.sh": 650, "test_mid.sh": 200, "test_small.sh": 30}),
         full_run(T - 300, 700, {"test_mid.sh": 690}, scope="changed"),
         dict(full_run(T - 500, 200, {"test_a.sh": 150, "test_b.sh": 20}), repo_root="/r/claude-setup")]
part, lead, pole = cost_judges(poles, "tests:pole")
big = pole.get("llm-legs:test_big", {})
check((big.get("level"), round(big.get("value") or 0, 2), big.get("exposure"), big.get("limit")) == ("red", 0.93, 2, 0.5)
      and "450 s more than test_mid.sh" in big.get("fact", ""),
      "long pole: the suite over half of its repository's latest full run is red, with its lead over the next suite")
check(pole.get("claude-setup:test_a", {}).get("level") == "watch",
      "long pole: over half of a full run under 5 min is a watch, a split saves under 2.5 min")
check(lead["red"] and part["state"] == "problem" and lead in part["extra_red"] and "llm-legs:test_mid" not in pole,
      "long pole: a red pole makes Tests a problem, and a changed-suites run is no full run")
part, lead, pole = cost_judges([poles[1], full_run(T - 60, 700, {"test_big.sh": 300, "test_mid.sh": 290})], "tests:pole")
check(pole.get("llm-legs:test_big", {}).get("level") is None and pole["llm-legs:test_big"]["value"] is not None
      and not lead["red"], "long pole: only the latest full run is judged, and a balanced one stays a quiet value")
costs = ([dict(test_row("llm-legs", "test_big", T - 3600 * i - 1500, T - 3600 * i), repo_root="/r/llm-legs")
          for i in range(1, 6)]
         + [dict(test_row("llm-legs", "test_mid", T - 3600 * i - 1110, T - 3600 * i), repo_root="/r/llm-legs")
            for i in range(1, 4)]
         + [dict(test_row("llm-legs", "test_mid", T - 30 * 3600 - 9000, T - 30 * 3600), repo_root="/r/llm-legs"),
            full_run(T - 7200, 700, {"test_big.sh": 300, "test_mid.sh": 290}),
            dict(test_row("llm-legs", "suites", T - 4000, T - 1000), repo_root="/r/llm-legs")])
part, lead, cost = cost_judges(costs, "tests:cost")
check((cost["llm-legs:test_big"]["level"], cost["llm-legs:test_big"]["value"], cost["llm-legs:test_big"]["exposure"])
      == ("red", 7800, 6) and lead["red"] and lead in part["extra_red"],
      "daily cost: a suite over 2 h of wall clock in 24 h, run alone or inside full runs, is red")
check((cost["llm-legs:test_mid"]["level"], cost["llm-legs:test_mid"]["value"]) == ("watch", 3620),
      "daily cost: over 1 h is a watch counting the suite's share of full runs, and a run that ended before the window is left out")
check("llm-legs:suites" not in cost and lead["menu"]["rows"][-1]["cells"][:2] == ["suites runs without suite times", "1"],
      "daily cost: a suites run without suite times is shown unattributed, never judged as a suite")
for suite, head in (("test_tool.sh", '. "$(dirname "$0")/tool_harness.sh"'), ("test_tool_render.sh", '. "$(dirname "$0")/tool_harness.sh"'),
                    ("test_tool_extra.sh", "echo 'not sourced: tool_harness.sh'"), ("test_lone.sh", '. "$(dirname "$0")/lone_harness.sh"')):
    put(os.path.join(work, "split-repo", "tests", suite), "#!/usr/bin/env bash\n%s\n" % head)
split = [dict(full_run(T - 3600 * i, 2600, {"test_tool.sh": 1300, "test_tool_render.sh": 1300, "test_tool_extra.sh": 1300,
                                             "test_lone.sh": 1300}), repo_root="/r/split-repo") for i in (1, 2)]
part, lead, cost = cost_judges(split + [dict(test_row("split", "test_tool_render", T - 1500, T - 900), repo_root="/r/split-repo")],
                               "tests:cost")
check((cost.get("split-repo:test_tool", {}).get("value"), cost["split-repo:test_tool"]["level"]) == (5800, "watch")
      and "split-repo:test_tool_render" not in cost and cost["split-repo:test_tool_extra"]["value"] == 2600
      and cost["split-repo:test_lone"]["value"] == 2600,
      "daily cost: the parts sourcing one tests/<x>_harness.sh are one suite test_<x>, their wall clock summed")
journal_cache = os.path.join(work, "journal-merge")
c5 = os.path.join(journal_cache, "runs.jsonl")
jl(c5, [{"kind": "suites", "pid": 41, "repo": "/r/llm-legs/.claude/worktrees/wt", "repo_root": "/r/llm-legs", "scope": "named",
         "worker_run": "codex-1", "started_at": T - 3000, "ended_at": T - 600,
         "suites": {"test_big.sh": {"rc": 0, "secs": 2300}, "test_mid.sh": {"rc": 0, "secs": 900}}},
        {"kind": "direct", "pid": 42, "repo_root": "/r/llm-legs", "started_at": T - 9000, "ended_at": T - 3990,
         "suites": {"test_big.sh": {"rc": 0, "secs": 5000}}}])
written_live = [dict(test_row("llm-legs", "suites", T - 2998, T - 2998 + d), repo_root="/r/llm-legs/.claude/worktrees/wt",
                     suite_secs={"test_big.sh": d}) for d in (300, 900, 1500)]
killed_twice = [dict(test_row("other", "suites", T - 20000, T - 20000 + d), repo_root="/r/other", suite_secs=s)
                for d, s in ((600, {"test_x.sh": 590}), (1200, {"test_x.sh": 590, "test_y.sh": 1190}))]
jl(os.path.join(journal_cache, "test-history.jsonl"), written_live + killed_twice)
saved_cache = os.environ["STATUSLINE_CACHE_DIR"]
os.environ.update(STATUSLINE_CACHE_DIR=journal_cache, RUN_SUITES_JOURNAL=c5)
try:
    merged = m.load_tests(T)
finally:
    os.environ["STATUSLINE_CACHE_DIR"] = saved_cache
    os.environ.pop("RUN_SUITES_JOURNAL")
check(sorted((t["label"], t.get("repo_root"), t["secs"], t["who"]) for t in merged)
      == [("suites", "/r/llm-legs", 2400, "worker"), ("suites", "/r/other", 1200, "chat"), ("test_big", "/r/llm-legs", 5000, "chat")],
      "tests: run-suites' journal rows count, the rows the probe wrote while one ran are dropped, and an unjournaled run "
      "journaled twice counts once: %s" % merged)
part, lead, cost = cost_judges(merged, "tests:cost")
check((cost["llm-legs:test_big"]["value"], cost["llm-legs:test_big"]["evidence"][0]["ref"])
      == (7300, "runs.jsonl direct 42 test_big"),
      "daily cost: a journaled run-all's suite seconds and a journaled direct run add up, cited by the journal row")
for key, value in saved_env.items():
    if value is None:
        os.environ.pop(key, None)
    else:
        os.environ[key] = value
print(count[0])
EOF
) || fail "the detection classes or their clearing paths misjudged"
asserts=$((asserts + checks))

# The hooks write their timings into hooks/spool with builtins alone; a fresh install's first run makes it.
HARNESS_DOCTOR_DIR="$WORK/fresh" HARNESS_DOCTOR_NOW=$((T + 900)) HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --quiet ||
  fail "a fresh run failed"
assert_eq yes "$([ -d "$WORK/fresh/hooks/spool" ] && echo yes)" "a fresh run makes the hooks' spool"

dismiss_wait() {
  jq --arg ident "$1" '.rows += [{id: "wait-dismissed", title: "t", match: {rule: "wait", ident: $ident}, status: "not-a-bug",
    fixes: [], same_cause: [], last_reviewed: null, reviewed_by: null, note: null, handoff: null}]' \
    "$ROOT/share/harness-ledger.json" > "$WORK/dismiss.json"
  local dir
  dir=$(mktemp -d "$WORK/dismiss.XXXXXX")
  HARNESS_LEDGER="$WORK/dismiss.json" HARNESS_DOCTOR_DIR="$dir" HARNESS_DOCTOR_NOW=$((T + 900)) \
    HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --quiet || fail "a run over a dismissal ledger failed"
  jq -c '[any(.problems[]; .id == "wait:bash:alpha"), [.problems[] | select(.id == "ledger:wait-dismissed")
    | .rule, .state, (.fact | test("^ledger wait-dismissed dropped: .+")), .count]]' "$dir/latest.json"
}
assert_eq '[false,[]]' "$(dismiss_wait 'bash:alpha')" "a narrow not-a-bug row silences its one ident and is no fault"
for ident in '[^z]{2,}' '.*' ''; do
  assert_eq '[true,["ledger_fault","new",true,1]]' "$(dismiss_wait "$ident")" \
    "a catch-all dismissal /$ident/ is dropped before judging and reported as ledger:<row id>"
done
holds="$WORK/holds"
mkdir -p "$holds"
dead_pid=$(bash -c 'echo $$')
sleep 60 & reused_pid=$!
held_now=$(date +%s)
hold_file() { # limiter pid age what [key]; pid 1 started at boot, before any since here
  jq -cn --arg limiter "$1" --argjson pid "$2" --argjson since $((held_now - $3)) --arg what "$4" \
    '{limiter: $limiter, pid: $pid, held: {what: $what, session: "s1", cwd: "/w"}, since: $since, why: "memory pressure",
      until: null}' > "$holds/$1-$2${5:+-$5}.json"
}
hold_file bench-throttle 1 400 "bench job"; hold_file suite-slots 1 90 suite; hold_file quick 1 30 "a test"
hold_file bench-throttle 1 120 "bench job" 7001; hold_file bench-throttle 1 20 "bench job" 7002
hold_file gone "$dead_pid" 900 job; hold_file reused "$reused_pid" 7200 job
jq '.rows = []' "$ROOT/share/harness-ledger.json" > "$WORK/hold-ledger.json"
mkdir -p "$WORK/held-memlogd"
jq -n --argjson now "$held_now" '{as_of: $now, queue_stuck_s: 1800, queues: [
  {limiter: "bench-throttle", stuck: true}, {limiter: "suite-slots", stuck: false}]}' > "$WORK/held-memlogd/chats.json"
run_held() {
  HARNESS_LEDGER="$WORK/hold-ledger.json" RUN_SUITES_SLOTS_DIR="$WORK/no-slots" NIGHT_FIXER_SLOTS_DIR="$WORK/no-slots" \
    HARNESS_HOLDS_DIR="$holds" HARNESS_DOCTOR_DIR="$WORK/held" HARNESS_DOCTOR_NOW=$held_now HARNESS_DOCTOR_FAKE_SAMPLE="" \
    MEMLOGD_DIR="$WORK/held-memlogd" "$DOCTOR" --quiet
}
run_held || fail "a run over live and leaked holds failed"
kill "$reused_pid" 2>/dev/null
assert_eq "$(jq -cn --arg b "gone-$dead_pid.json" --arg d "reused-$reused_pid.json" \
  '[["limiter_hold:bench-throttle", "new", 3, "holds/bench-throttle-1.json", "bench-throttle holds 3 jobs, longest 7 min: memory pressure — the queue is stuck"],
    ["limiter_hold:suite-slots", "watch", 1, "holds/suite-slots-1.json", "suite-slots holds 1 job, longest 2 min: memory pressure"],
    ["limiter_hold_leak:gone", "watch", 1, "holds/\($b)", "gone left 1 hold file whose process is gone or unreadable: \($b)"],
    ["limiter_hold_leak:reused", "watch", 1, "holds/\($d)", "reused left 1 hold file whose process is gone or unreadable: \($d)"]]')" \
  "$(jq -c '[.problems[] | select(.rule | startswith("limiter_hold")) | [.id, .state, .count, .evidence[0].ref, .fact]] | sort' \
    "$WORK/held/latest.json")" \
  "a hold over 60 s is a watch, red only in a queue chat-load judged stuck, one under 60 s nothing; a dead pid's file and one whose pid started after since a leak"
assert_eq 2 "$(grep -c $'^[1-9][0-9]*\t.*holds [0-9]* jobs*, longest [0-9]* min: memory pressure' "$WORK/held/menu.txt")" \
  "the doctor's menu names each hold over 60 s, what it holds, for how long and why"
mkdir -p "$WORK/night-slots/1" && echo "$$" > "$WORK/night-slots/1/pid"
HARNESS_LEDGER="$WORK/hold-ledger.json" RUN_SUITES_SLOTS_DIR="$WORK/no-slots" NIGHT_FIXER_SLOTS_DIR="$WORK/night-slots" \
  HARNESS_HOLDS_DIR="$holds" MEMLOGD_DIR="$WORK/held-memlogd" \
  HARNESS_DOCTOR_DIR="$WORK/held-night" HARNESS_DOCTOR_NOW=$held_now HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --quiet ||
  fail "a run over holds under a night slot failed"
assert_eq '["watch","bench-throttle holds 3 jobs, longest 7 min: memory pressure — the queue is stuck while 1 suite or night-fixer slots ran"]' \
  "$(jq -c '[.problems[] | select(.id == "limiter_hold:bench-throttle") | .state, .fact]' "$WORK/held-night/latest.json")" \
  "a stuck queue while a suite or night-fixer slot runs is the night's own requested load: a watch, never red"
assert_eq "bench-throttle-1-7001.json bench-throttle-1-7002.json bench-throttle-1.json quick-1.json suite-slots-1.json" \
  "$(ls "$holds" | tr '\n' ' ' | sed 's/ $//')" "a run that reported a leak did not sweep its files, or swept a live hold"
run_held || fail "a second run over the swept holds failed"
assert_eq 0 "$(jq '[.problems[] | select(.rule == "limiter_hold_leak")] | length' "$WORK/held/latest.json")" \
  "a swept leak was reported again"
hold_file dry "$dead_pid" 90 job
HARNESS_HOLDS_DIR="$holds" HARNESS_DOCTOR_DIR="$WORK/held" HARNESS_DOCTOR_NOW=$held_now HARNESS_DOCTOR_FAKE_SAMPLE="" \
  "$DOCTOR" --json >/dev/null || fail "a --json run over a leaked hold failed"
assert_eq 1 "$(ls "$holds" | grep -c '^dry-')" "a --json run, which persists nothing, swept a hold file"
writer="$WORK/writer-holds"
assert_eq 'null None' "$(HARNESS_HOLDS_DIR="$writer" python3 -c 'import json, os, sys
sys.path.insert(0, sys.argv[1])
import limiter_hold as h
path = h.hold_raise("w", "job", "why", until=float("inf"), key=1)
os.environ["HARNESS_HOLDS_DIR"] = "/dev/null/holds"
print(json.dumps(json.load(open(path))["until"]), h.hold_raise("w", "job", "why"))' "$ROOT/share")" \
  "the Python writer wrote a non-finite until as other than null, or raised on an unwritable directory"
assert_eq 'ok: null' "$(HARNESS_HOLDS_DIR=/dev/null/holds bash -ec 'source "$1"; file=$(hold_raise w job why); hold_clear /dev/null/x
  HARNESS_HOLDS_DIR=$2; file=$(hold_raise w job why soon 2); echo "ok$(ls "$2" | grep -c "\.tmp$" | sed "s/^0$//"): $(jq -c .until "$file")"' \
  _ "$ROOT/share/limiter-hold.sh" "$writer" 2>&1)" \
  "the shell writer failed its set -e caller on an unwritable directory or a bad until, or left a .tmp"
assert_eq '[]' "$(python3 -c 'import importlib.machinery as l, json, sys
m = l.SourceFileLoader("hd", sys.argv[1]).load_module()
print(json.dumps(m.ledger_faults(json.load(open(sys.argv[2])))))' "$DOCTOR" "$ROOT/share/harness-ledger.json")" \
  "the committed ledger has no faulty row"

mkdir -p "$WORK/broken"
printf '{"hooks": ["not an object"]}' > "$WORK/broken-settings.json"
HARNESS_SETTINGS="$WORK/broken-settings.json" HARNESS_DOCTOR_DIR="$WORK/broken" HARNESS_DOCTOR_NOW=$((T + 900)) \
  HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --quiet 2>/dev/null
assert_eq '1' "$?" "a collector exception exits 1"
assert_eq '["error",true]' "$(jq -c '[.status, (.self.error | test("line [0-9]+"))]' "$WORK/broken/latest.json")" \
  "a collector exception writes status error with the line"
assert_eq '1	Harness doctor: error' "$(head -1 "$WORK/broken/menu.txt" | cut -f2,4 | cut -c1-23)" \
  "the menu shows the error, never the previous document's colour"

printf '{"local_slow": [[1, 2]]}' > "$WORK/broken/latest.json"
HARNESS_SETTINGS="$WORK/broken-settings.json" HARNESS_DOCTOR_DIR="$WORK/broken" HARNESS_DOCTOR_NOW=$((T + 900)) \
  HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --quiet 2>/dev/null
assert_eq '[null,[[1,2]]]' "$(jq -c '[.problem_count, .local_slow]' "$WORK/broken/latest.json")" \
  "a failed collector keeps the last local_slow windows and counts its problems as unknown"

printf '{"rows": [' > "$WORK/malformed-ledger.json"
assert_eq '["ledger:ledger",true]' "$(HARNESS_LEDGER="$WORK/malformed-ledger.json" HARNESS_DOCTOR_DIR="$WORK/malformed" \
  HARNESS_DOCTOR_NOW=$((T + 900)) HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --json |
  jq -c '[.problems[] | select(.rule == "ledger_fault") | .id, (.fact | test("not JSON"))]')" \
  "a ledger that is not JSON is a ledger fault, never an empty ledger"

catchup="$WORK/catchup"
gap=$((T - 55 * 3600))
mkdir -p "$catchup/hooks"
printf '%d\t%d\tprompt-nice.sh\t0\t77\n' $((gap * 1000000)) $((gap * 1000000 + 400000)) > "$catchup/hooks/$((gap / 86400)).tsv"
printf '{"journal": {"floor_upto": %d}}' $((T - 60 * 3600)) > "$catchup/state.json"
HARNESS_DOCTOR_DIR="$catchup" HARNESS_DOCTOR_NOW=$T HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --quiet || fail "a catch-up run failed"
assert_eq 1 "$(jq '.floors["event:UserPromptSubmit"][0]' "$catchup/days/$(date -u -r "$gap" +%F).json" 2>/dev/null)" \
  "a run after a gap longer than the raw reach still records the floors since its last run"

ledger_guard() {
python3 - "$1" "$PROJECTS" "$ROOT/share" "$ROOT/bin/speed-doctor" <<'LEDGER'
import importlib.machinery, json, os, re, subprocess, sys
sys.path.insert(0, sys.argv[3])
from fix_commit import FIX_KEYS
equivalent = importlib.machinery.SourceFileLoader("speed_doctor", sys.argv[4]).load_module().equivalent
ledger = json.load(open(sys.argv[1]))
assert ledger["owner"] == "Harness Doctor" and isinstance(ledger["rows"], list), "owner and rows"
fields = {"id", "title", "match", "status", "fixes", "same_cause", "last_reviewed", "reviewed_by", "note", "handoff"}
ids = [r["id"] for r in ledger["rows"]]
for r in ledger["rows"]:
    assert set(r) == fields, r["id"]
    assert set(r["same_cause"]) <= set(ids), r["id"]
    if r["status"] in ("fixed", "fixed-pending"):
        assert r["fixes"], "a fixed row names its fix: %s" % r["id"]
    for i, fix in enumerate(r["fixes"]):
        assert set(fix) - {"equivalence"} == FIX_KEYS and fix["files"], r["id"]
        assert "equivalence" not in fix or equivalent(fix), r["id"]
        assert all(re.fullmatch(r"[\w.-]+/.+", f) for f in fix["files"]), r["id"]
        assert i < len(r["fixes"]) - 1 or (fix["in"] is None) == (r["status"] == "fixed-pending"), r["id"]
        if fix["in"]:
            repo, commit = fix["in"].split("@")
            top = os.path.join(sys.argv[2], repo)
            if os.path.isdir(top):
                assert subprocess.run(["git", "-C", top, "cat-file", "-e", commit + "^{commit}"]).returncode == 0, fix
for b in ledger["blind_spots"]:
    assert set(b) == {"id", "what", "reason", "since", "would_catch_if"}, b
LEDGER
}
ledger_guard "$ROOT/share/harness-ledger.json" || fail "the ledger breaks a contract guard"
asserts=$((asserts + 1))
jq '.rows = [{id: "refixed", title: "t", match: {rule: "floor", ident: "bash:refixed"}, status: "fixed-pending",
  fixes: [{at: "2026-09-01T00:00:00+00:00", by: "c", files: ["llm-legs/bin/x"], in: "no-such-repo@abc1234",
           regressed_at: "2026-09-02T00:00:00+00:00"},
          {at: "2026-09-03T00:00:00+00:00", by: "c", files: ["llm-legs/bin/x"], in: null, regressed_at: null}],
  same_cause: [], last_reviewed: null, reviewed_by: null, note: null, handoff: null}]' \
  "$ROOT/share/harness-ledger.json" > "$WORK/refixed.json"
ledger_guard "$WORK/refixed.json" 2>/dev/null || fail "the ledger guard fails a row whose repeat fix is pending over a committed one"
asserts=$((asserts + 1))
jq '.rows[0].fixes[1].equivalence = {compared: "c", data: "d", result: "r"}' "$WORK/refixed.json" > "$WORK/proved.json"
ledger_guard "$WORK/proved.json" 2>/dev/null || fail "the ledger guard fails a Speed fix carrying its output-equivalence proof"
asserts=$((asserts + 1))
jq '.rows[0].fixes[1].equivalence = {compared: "c", data: "d"}' "$WORK/refixed.json" > "$WORK/unproved.json"
! ledger_guard "$WORK/unproved.json" 2>/dev/null || fail "the ledger guard takes an equivalence proof with no result"
asserts=$((asserts + 1))

FIXTURE="$ROOT/tests/fixtures/harness-calibration"
mkdir -p "$WORK/replay-home/hk"
for script in $(jq -r '.hooks[][].hooks[].command | split(" ")[0] | ltrimstr("~/hk/")' "$FIXTURE/settings.json" | sort -u); do
  printf '#!/bin/bash\n. ~/.claude/hooks/lib/hook-time.sh\n' > "$WORK/replay-home/hk/$script"
done
replay() {
  mkdir -p "$WORK/replay-$1/hooks" "$WORK/replay-$1/projects" "$WORK/replay-$1/statusline"
  cp "$FIXTURE/hooks/20725.tsv" "$WORK/replay-$1/hooks/"
  cp "$FIXTURE/statusline/test-history.jsonl" "$WORK/replay-$1/statusline/"
  HOME="$WORK/replay-home" HARNESS_SETTINGS="$FIXTURE/settings.json" HARNESS_DOCTOR_DIR="$WORK/replay-$1" \
    CLAUDE_PROJECTS_DIR="$WORK/replay-$1/projects" STATUSLINE_CACHE_DIR="$WORK/replay-$1/statusline" \
    MEMLOGD_DIR="$WORK/replay-$1/memlogd" INSTRUCTION_WATCH_STATE="$WORK/replay-$1/watch" \
    HARNESS_WATCH_ROOTS="" HARNESS_DOCTOR_NOW=1790695676 \
    HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --json > "$WORK/replay-$1.json"
  jq -c '[.problems[] | .id + "=" + .state]' "$WORK/replay-$1.json"
}
first_ids=$(replay 1)
assert_eq "$first_ids" "$(replay 2)" "the committed calibration fixture replays with the same problem ids"
assert_eq '["floor:event:SessionStart=watch","test_daily_cost-worker-run=fixed-pending","test_daily_cost:llm-legs:test_instruction_gate=new","test_long_pole-worker-run=fixed-pending","floor-trivial-bash-readonly-fastpath=fixed-pending","hook-every-call-context-nudge=fixed-pending","floor-edit-hooks=fixed-pending","floor-bash-other-hooks=fixed-pending","suites-llm-legs-concurrent-load=fixed-pending","load-unseen-suites-statusline=fixed-pending","load-busy-night-concurrency=fixed-pending","collector-run-cpu-starved=fixed-pending","guards-tripwire-rejournal=fixed-pending","guards-synced-skills-vendor-sync=fixed-pending","guards-baseline-missing-probe-sids=fixed-pending","ask-deferred-bg-task-hold-cap=fixed-pending","hook-error-notice-word-journal-timeout=fixed-pending","hook-error-ask-pr-mattermost-creation=fixed-pending","hook-error-worker-run-backstop-timeout=fixed-pending","ask-repeat-span-drill-scheduled-wakeup=fixed-pending","word-miss-deferred-reading-lost=fixed-pending","word-miss-first-idle-stop-no-checkpoint=fixed-pending","hook-grows-repos-commit-journal=fixed-pending","hook-grows-repos-review-flow-gate=fixed-pending","hook-grows-size-commit-journal=fixed-pending","hook-grows-size-review-flow-gate=fixed-pending","hook-every-call-commit-journal=fixed-pending","hook-sync-commit-journal=fixed-pending","hook-every-call-instruction-watch=fixed-pending","hook-grows-repos-report-flush=fixed-pending","guards-growth-film-08a95dd4=fixed-pending","guards-growth-film-a19f6d01=fixed-pending","guards-growth-volumes-work-projects-llm-legs-docs=fixed-pending","guards-growth-claude-agents-image-gen-md=fixed-pending","guards-growth-claude-plugins-marketplaces-claude-plugins-official-plugins-math-proof-readme-md=fixed-pending","guards-growth-claude-plugins-marketplaces-claude-plugins-official-plugins-math-proof-agents-math-proof-judge-md=fixed-pending","guards-growth-claude-plugins-marketplaces-claude-plugins-official-plugins-math-proof-agents-math-proof-worker-deep-md=fixed-pending","guards-growth-claude-plugins-marketplaces-claude-plugins-official-plugins-math-proof-agents-math-proof-worker-md=fixed-pending","guards-growth-claude-plugins-marketplaces-claude-plugins-official-plugins-math-proof-skills-siege=fixed-pending","guards-growth-claude-plugins-marketplaces-claude-plugins-official-plugins-math-proof-skills-solo=fixed-pending","guards-growth-claude-skills-hyperframes=fixed-pending","guards-growth-claude-skills-hyperframes-animation=fixed-pending","guards-growth-claude-skills-hyperframes-audio=fixed-pending","guards-growth-claude-skills-hyperframes-cli=fixed-pending","guards-growth-claude-skills-hyperframes-core=fixed-pending","guards-growth-claude-skills-hyperframes-creative=fixed-pending","guards-growth-claude-skills-hyperframes-keyframes=fixed-pending","guards-growth-claude-skills-hyperframes-registry=fixed-pending","guards-growth-claude-skills-hyperframes-studio=fixed-pending","guards-growth-claude-skills-media-use=fixed-pending","hook-p50-instruction-watch-baseline=fixed-pending","hook-sync-instruction-watch-check=fixed-pending","hook-sync-worker-launch-gate=fixed-pending","hook-sync-review-flow-gate=fixed-pending","test_long_pole-review-bench=fixed-pending","test_long_pole-review-bench-in-llm-legs=fixed-pending","loose-objects-logo-vectorizer-bench=fixed-pending","guards-growth-alpha-fixture-docs=fixed-pending","guards-growth-review-bench-docs=fixed-pending","guards-growth-video-r1-a-hf-claude-md=fixed-pending","guards-growth-video-r1-b-hf-claude-md=fixed-pending","guards-growth-claude-agents-claudeb-worker-md=fixed-pending","guards-growth-claude-agents-codex-worker-md=fixed-pending","guards-growth-claude-agents-gemini-worker-md=fixed-pending","guards-growth-claude-agents-grok-worker-md=fixed-pending","guards-growth-claude-agents-light-worker-md=fixed-pending","guards-growth-claude-setup-night-sweep-skill=fixed-pending","hook-sync-stop-dispatch=fixed-pending","hook-grows-repos-stop-dispatch=fixed-pending","hook-grows-size-stop-dispatch=fixed-pending","hook-sync-worker-limit-gate=fixed-pending","hook-grows-repos-worker-limit-gate=fixed-pending","hook-sync-worker-spawn-hook=fixed-pending","hook-sync-instruction-watch-baseline=fixed-pending","test_daily_cost-llm-limits=fixed-pending","test_daily_cost-review-flow-gate=fixed-pending","test_long_pole-commit-report=fixed-pending","guards-growth-claude-plugins-marketplaces-security-guidance-readme-md=fixed-pending","guards-synced-plugins-vendor-sync=fixed-pending","guards-denied-claude-skills-media=fixed-pending","guards-denied-claude-agents-image-gen-md=fixed-pending","speed-hook-lever-review-flow-gate=fixed-pending","limiter-hold-logo-bench-throttle=fixed-pending","speed-exec-background-qos=fixed-pending","hook-p50-commit-journal=fixed-pending","hook-p50-review-flow-gate=fixed-pending","hook-p50-worker-limit-gate=fixed-pending","guards-growth-claude-skills-media=fixed-pending","test_long_pole-light-research=fixed-pending","hook-every-call-statusline-workdir-hook=fixed-pending","hook-sync-statusline-workdir-hook=fixed-pending","hook-full-work-statusline-workdir-hook=fixed-pending","hook-error-ask-span-drill-budget=fixed-pending","hook-error-ask-word-reading-budget=fixed-pending","hook-held-backstop-nested-run=fixed-pending","wait-run-suites-slot-hogs=fixed-pending","test_slow-instruction-gate=fixed-pending","hook-error-notice-chat-names-timeout=fixed-pending","reading-miss-unprompted=fixed-pending","time_floor:suite_wait=fixed-pending","time_floor:retries=fixed-pending","time_floor:locks=fixed-pending","hook-grows-repos-worker-spawn-hook=fixed-pending","hook-every-call-english-gate=fixed-pending","hook-grows-repos-pr-ready-mattermost=fixed-pending","hook-every-call-report-flush=fixed-pending","hook-full-work-report-flush=fixed-pending","hook-full-work-eod-sorted-gate=fixed-pending","hook-full-work-worker-git-guard=fixed-pending","worker-orphans-detached-on-purpose=fixed-pending","hook-cut-eod-sorted-gate=fixed-pending","hook-full-work-resume-timer-guard=fixed-pending","hook-full-work-word-gate=fixed-pending","hook-full-work-chat-switch-link=fixed-pending","hook-full-work-dia-not-chrome=fixed-pending","hook-full-work-skill-install-scope-gate=fixed-pending","hook-full-work-worker-pin-gate-bash=fixed-pending","hook-full-work-context-nudge=fixed-pending","log_audit:affected-suite-list-handling=fixed-pending","log_audit:pretooluse-awk-multibyte-error=fixed-pending","log_audit:run-suites-journal-env-leak=fixed-pending","log_audit:foreground-run-all-10min-cap=fixed-pending","unjournaled-night-run-wall=fixed-pending","guards-ungated-claude-md-pathlib-assign=fixed-pending","guards-ungated-docs-worktree-shell-write=fixed-pending"]' \
  "$first_ids" "the 2026-09-29 18:27 calibration reads its known watches and every night fix as pending proof"
assert_eq '["test_daily_cost-worker-run 8577.0 23","test_daily_cost:llm-legs:test_instruction_gate 10377.0 38","test_long_pole-worker-run 0.957 1","test_long_pole-review-bench null 0","test_long_pole-review-bench-in-llm-legs null 0","test_daily_cost-llm-limits 314.0 0","test_daily_cost-review-flow-gate null 0","test_long_pole-commit-report null 0","test_long_pole-light-research null 0","test_slow-instruction-gate 344.0 0"]' \
  "$(jq -c '[.problems[] | select(.id | startswith("test_")) | "\(.id) \(.value) \(.exposure)"]' "$WORK/replay-1.json")" \
  "the calibration's 24 h of llm-legs tests: test_worker_run is the long pole, both suites cost over 2 h"

assert_eq '' "$(for f in "$ROOT"/tests/fixtures/speed-calibration/*.jsonl.gz; do gzip -dc "$f"; done |
  jq -r '.. | strings | select(length > 60 and (startswith("<task-notification>") | not))' | head -3)" \
  "the public calibration transcripts carry no chat text: peer bodies, prompts and tool inputs are stripped"

speed=$(python3 - "$ROOT" "$T" "$WORK" <<'EOF'
import gzip, glob, json, os, sys, time
root, T, work = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sys.path.insert(0, os.path.join(root, "tests", "lib"))
from speed_calibration import HI, LO, harness, scan
m = harness(root)
count = [0]

def check(cond, what):
    count[0] += 1
    if not cond:
        print("FAIL: %s" % what, file=sys.stderr)
        sys.exit(1)

os.environ["HARNESS_DOCTOR_DIR"] = os.path.join(work, "runs-state")
tsv = os.path.join(work, "runs-state", "hooks", "%d.tsv" % (T // 86400))
os.makedirs(os.path.dirname(tsv))
line = lambda n, key: "%d\t%d\t%s\t0\t77\n" % ((T - 100 + n) * 10 ** 6, (T - 99 + n) * 10 ** 6, key)

def keys(write=True):
    return [r[1] for r in sorted(m.journal_runs(T - 1000, (), write)[0], key=lambda r: r[4])]

with open(tsv, "w") as handle:
    handle.write(line(1, "k1") + line(2, "k2") + line(3, "k3"))
check(keys() == ["k1", "k2", "k3"], "journal runs: a first pass reads every line")
text = open(tsv).read()
with open(tsv, "r+") as handle:
    handle.seek(text.index("k3"))
    handle.write("z3")
with open(tsv, "a") as handle:
    handle.write(line(4, "k4"))
check(keys() == ["k1", "k2", "k3", "k4"], "journal runs: a pass reads only the bytes after its offset")
check(keys(False) == keys(), "journal runs: a non-persisting pass reads the same rows off the cache")
with open(tsv, "w") as handle:
    handle.write(line(1, "k1") + line(2, "k2"))
check(keys() == ["k1", "k2"], "journal runs: a file truncated below its offset, head kept, is read again from its start")
with open(tsv, "a") as handle:
    handle.write(line(5, "k5"))
check(keys() == ["k1", "k2", "k5"], "journal runs: a line appended after a truncation is read once")
with open(tsv + ".new", "w") as handle:
    handle.write(line(1, "k1") + line(2, "k2") + line(5, "q5"))
os.replace(tsv + ".new", tsv)
check(keys() == ["k1", "k2", "q5"],
      "journal runs: a rotated file (new inode, same head and size) is read again from its start")
cache = glob.glob(os.path.join(work, "runs-state", "hook-runs", "*.pickle"))
with open(cache[0], "wb") as handle:
    handle.write(b"garbage")
check(len(cache) == 1 and keys() == ["k1", "k2", "q5"], "journal runs: a broken cache is rebuilt off the journal")
os.remove(tsv)
check(keys() == [] and not glob.glob(os.path.join(work, "runs-state", "hook-runs", "*")),
      "journal runs: a pruned journal file drops its cache")

phases = m.Phases()
real_sleep, m.time.sleep = m.time.sleep, lambda secs: None
saved = os.environ.pop("HARNESS_DOCTOR_FAKE_SAMPLE", None)
m.take_sample({}, T, phases)
check(set(phases.secs) == {"sample", "sleep"}, "the sampler's sleep is timed apart from its work: %s" % phases.secs)
real_ticks, ncpu = m.host_ticks, os.cpu_count() or 1
m.host_ticks = lambda: [1000 + 90 * 1800 * ncpu, 0, 1000 + 10 * 1800 * ncpu, 0]
slow = m.take_sample({"ticks": [T - 1800, [1000, 0, 1000, 0]]}, T)
check(slow.get("busy") == 0.9, "busy is measured across a 30 min gap between slow doctor runs: %s" % slow.get("busy"))
m.host_ticks = lambda: [10, 0, 90, 0]
rebooted = m.take_sample({"ticks": [T - 1800, [5000, 0, 5000, 0]]}, T)
check("busy" not in rebooted, "counters reset by a reboot give no busy: %s" % rebooted.get("busy"))
m.host_ticks = real_ticks
m.time.sleep = real_sleep

def stamp(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int(round((t % 1) * 1000))

def rec(t, **kw):
    return dict(kw, timestamp=stamp(t))

def human(t, source="typed", text="go"):
    return rec(t, type="user", origin={"kind": "human"}, promptSource=source, message={"content": text})

def note(t, tid="", task=""):
    body = "<task-notification><task-id>%s</task-id><tool-use-id>%s</tool-use-id></task-notification>" % (task, tid)
    return rec(t, type="user", origin={"kind": "task-notification"}, promptSource="system", message={"content": body})

def say(t, rid="req_x", tools=(), out=1, model="claude-opus-5-5", effort="xhigh"):
    blocks = [{"type": "tool_use", "id": i, "name": n, "input": a} for i, n, a in tools]
    return rec(t, type="assistant", requestId=rid, effort=effort, message={
        "model": model, "content": blocks or [{"type": "text", "text": "x"}],
        "usage": {"output_tokens": out, "output_tokens_details": {"thinking_tokens": 40},
                  "cache_creation_input_tokens": 5, "cache_read_input_tokens": 7}})

def result(t, tid, **tur):
    return rec(t, type="user", toolUseResult=tur, message={"content": [{"type": "tool_result", "tool_use_id": tid}]})

def done(t, ms=20000):
    return rec(t, type="system", subtype="turn_duration", durationMs=ms)

def system(t, sub, **kw):
    return rec(t, type="system", subtype=sub, **kw)

def queue(t, op, content=""):
    return rec(t, type="queue-operation", operation=op, content=content)

projects = os.path.join(work, "c1-projects")
os.environ["CLAUDE_PROJECTS_DIR"] = projects

def chat(name, lines, boots=(), cut=None):
    path = os.path.join(projects, "p", name + ".jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [dict(lines[0], entrypoint="cli")] + lines[1:]
    text = "".join(json.dumps(l, ensure_ascii=False) + "\n" for l in lines)
    state, events = {"off": 0}, []
    for part in ([text[:cut], text] if cut else [text]):
        with open(path, "w") as handle:
            handle.write(part)
        m.read_transcript(path, state, events, {}, sorted([b, b] for b in boots))
        state = json.loads(json.dumps(state))
    m.c1_expire(state["c1"], events, T + 86400)
    return [e for e in events if e[0] in ("t", "d")]

def by(rows, kind, at):
    return next(r for r in rows if r[0] == kind and abs(r[1] - at) < 0.01)

def claims(texts, said="queued: will be delivered next round"):
    path = os.path.join(projects, "p", "claims.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [dict(say(B, tools=[("tu1", "SendMessage", {})]), entrypoint="sdk-cli"),
             rec(B + 1, type="user", message={"content": [{"type": "tool_result", "tool_use_id": "tu1", "content": said}]})]
    lines += [rec(B + 2 + i, type="assistant", message={"content": [{"type": "text", "text": x}]}) for i, x in enumerate(texts)]
    with open(path, "w") as handle:
        handle.write("".join(json.dumps(l, ensure_ascii=False) + "\n" for l in lines))
    events = []
    m.read_transcript(path, {"off": 0}, events, {})
    return [e[2] + ":" + e[5] for e in events if e[0] == "o"]

B = T - 40000
stale = chat("stale", [human(B), say(B + 10), done(B + 20), human(B + 18), say(B + 25), done(B + 130, ms=999999),
                       human(B + 200), say(B + 210), done(B + 220)])
second = by(stale, "t", B + 20)
check(second[3] == B + 130 and second[5] == [1, 1, 1],
      "C1 stale start: a turn starts at max(its prompt, the previous end); durationMs is never read: %s" % second)
check(by(stale, "t", B + 200)[5] == [0, 0, 0], "C1: a turn nobody answers expires with no R flag")

check([claims([x]) for x in ("Fixed.", "`Передал` воркеру", "Sent to the worker", "it was sent")]
      == [["SendMessage:queued"]] * 4,
      "a worker's overclaim is recorded whatever case its done-word starts with")
check([claims([x]) for x in ("It is queued and will be delivered on the next round.", "not sent yet",
                             "it will be sent next round", "будет доставлен в следующем раунде")] == [[]] * 4,
      "restating a queued result as future delivery is no overclaim")
Q = B + 1000
queued = chat("queue", [human(Q), say(Q + 5), queue(Q + 30, "enqueue"), say(Q + 40), done(Q + 60),
                        queue(Q + 60.1, "dequeue"), human(Q + 60.2, source="queued"), say(Q + 70), done(Q + 80),
                        human(Q + 500), say(Q + 505), done(Q + 510)])
first, dequeued = by(queued, "t", Q), by(queued, "t", Q + 60.2)
check(first[5] == [1, 1, 1] and first[7] == [Q, Q + 30],
      "C1 queued prompt: typed while busy, it answers the running turn and is stamped at enqueue: %s" % first)
check(dequeued[3] == Q + 80 and dequeued[5] == [0, 0, 1], "C1 queued prompt: its turn starts at dequeue")

N = B + 3000
agent = ("toolu_bg1", "Agent", {"subagent_type": "claudeb-worker", "run_in_background": True})
notes_lines = [human(N), say(N + 5, tools=[agent, ("toolu_bg2", "Bash", {"command": "sleep 100"})]),
               result(N + 6, "toolu_bg1", isAsync=True, agentId="ag1"), result(N + 6, "toolu_bg2", backgroundTaskId="bt2"),
               say(N + 10), done(N + 20),
               rec(N + 100, type="user", origin={"kind": "peer"}, promptSource="system", message={"content": "hi"}),
               say(N + 110),
               queue(N + 150, "enqueue", "<task-notification><task-id>bt2</task-id></task-notification>"),
               rec(N + 151, type="attachment", attachment={
                   "type": "queued_command", "origin": {"kind": "task-notification"},
                   "prompt": "<task-notification><task-id>bt2</task-id></task-notification>"}),
               say(N + 160), done(N + 200), human(N + 230), say(N + 240), done(N + 250),
               queue(N + 1000, "enqueue", "<task-notification><tool-use-id>toolu_bg1</tool-use-id></task-notification>"),
               queue(N + 1000.4, "dequeue"), note(N + 1000.5, task="ag1"), say(N + 1010), done(N + 1100),
               human(N + 1280)]
notes = chat("notes", notes_lines)
mid, cont = by(notes, "d", N + 5), [r for r in notes if r[0] == "d" and r[4] == "Agent:claudeb-worker"]
bash = [r for r in notes if r[0] == "d" and r[4] == "Bash"][0]
check(bash[3] == N + 200 and bash[7] == N + 150 and bash[9] == 0,
      "C1 notification mid-turn: consumed by the running turn, its delegation row is not an opened follow-up: %s" % bash)
check(len(cont) == 1 and cont[0][3] == N + 1100 and cont[0][7] == N + 1000 and cont[0][9] == 1 and cont[0][5] == [0, 1, 1],
      "C1 continuation: the notification opens its follow-up turn, answered after 3 min: %s" % cont)
check(by(notes, "t", N + 1000.5)[4] == "n", "C1 continuation: the turn a notification opens has origin n")
a_min, b_min = m.owner_minutes(notes, 1, N - 1, N + 5000)
check(abs(a_min * 60 - (20 + 100 + 99.5)) < 0.01 and abs(b_min * 60 - (1000 - 230)) < 0.01,
      "C1 B: an opened delegation adds from his last prompt to its notification, a mid-turn one nothing: %s %s"
      % (a_min * 60, b_min * 60))
two_pass = chat("notes2", notes_lines, cut=sum(len(json.dumps(l, ensure_ascii=False)) + 1 for l in notes_lines[:10]) + 20)
check([r[3:] for r in two_pass] == [r[3:] for r in notes],
      "C1: in-flight state carried across two passes gives the rows of one pass")

C = B + 6000
clip = chat("clip-a", [human(C), say(C + 10), done(C + 300), human(C + 320)]) + \
    chat("clip-b", [human(C + 250), say(C + 260), done(C + 270), human(C + 280)])
check(abs(m.owner_minutes(clip, 1, C - 1, C + 1000)[0] * 60 - 50) < 0.01,
      "C1 other-chat clip: a turn counts only after his last prompt in another chat")

D = B + 8000
gone = chat("away", [human(D), say(D + 10), done(D + 60), system(D + 90, "away_summary"), human(D + 120)])
check(by(gone, "t", D)[6] == 1 and m.owner_minutes(gone, 1, D - 1, D + 1000)[0] == 0,
      "C1 away_summary between a turn's end and his answer drops the turn")

E = B + 10000
boot = chat("boot", [human(E), say(E + 10, tools=[("tb", "Bash", {"command": "make"})]), result(E + 400, "tb"),
                     say(E + 410), done(E + 420), human(E + 430)], boots=[E + 100])
row = by(boot, "t", E)
check(row[8] == [[E + 10, E + 400]] and row[9].get("dark") == 390.0
      and abs(m.owner_minutes(boot, 1, E - 1, E + 1000)[0] * 60 - 30) < 0.01,
      "C1 a boot inside a turn drops only the dark slice around it: %s" % row)

F = B + 12000
usage = chat("usage", [human(F), say(F + 5, "req_1", out=100), say(F + 6, "req_1", out=100), say(F + 7, "req_1", out=100),
                       say(F + 9, "req_2", out=10, model="claude-fable-5-1", effort="high"), done(F + 30), human(F + 40)])
check(by(usage, "t", F)[10] == {"claude-opus-5-5/xhigh": [1, 100, 40, 5, 7], "claude-fable-5-1/high": [1, 10, 40, 5, 7]},
      "C1 usage repeats per block line and counts once per requestId, per model and effort: %s" % by(usage, "t", F)[10])

G = B + 14000
compact = chat("compact", [human(G), system(G + 50, "compact_boundary", compactMetadata={"durationMs": 30000}),
                           say(G + 60), done(G + 70), human(G + 80),
                           system(G + 150, "compact_boundary", compactMetadata="{'trigger': 'auto', 'durationMs': 30000}"),
                           say(G + 160), done(G + 170), human(G + 180)])
check(by(compact, "t", G)[9].get("compact") == 30.0 and by(compact, "t", G + 80)[9].get("compact") == 30.0,
      "C1 compactMetadata reads as a dict and as its Python-repr string")

H = B + 16000
asked = chat("ask", [human(H), say(H + 10, tools=[("tq", "AskUserQuestion", {}),
                                               ("ts", "Bash", {"command": "cd x && bash tests/run-all --all"})]),
                     result(H + 70, "tq"), result(H + 80, "ts"), say(H + 90), done(H + 100), human(H + 110)])
row = by(asked, "t", H)
check(row[8] == [[H + 10, H + 70]] and row[9].get("ask") == 60.0 and row[9].get("test") == 10.0 and H + 70 in row[7],
      "C1 an owner question is a hole and his answer a prompt; a suite run is its own partition layer: %s" % row)
check(not m.C1_SUITE.search("sed -n 1,9p tests/test_x.sh"), "C1 a test file read is no suite run")
check(chat("night", [human(H + 500, text="сделай чистку — night run 1"), say(H + 510), done(H + 520), human(H + 530)]) == [],
      "C1 machine-opened chats write no rows")

K = B + 18000
slept = chat("sleep", [human(K), say(K + 10, tools=[("tk", "Bash", {"command": "make"})]), result(K + 400, "tk"),
                       say(K + 410), done(K + 420), human(K + 430)], boots=[])
os.environ["HARNESS_DOCTOR_SLEEPS"] = "%d-%d" % (K + 100, K + 200)
dark = m.c1_boots({})
del os.environ["HARNESS_DOCTOR_SLEEPS"]
path = os.path.join(projects, "p", "sleep2.jsonl")
with open(path, "w") as handle:
    handle.write("".join(json.dumps(dict(l, entrypoint="cli") if i == 0 else l) + "\n" for i, l in enumerate(
        [human(K), say(K + 10, tools=[("tk", "Bash", {"command": "make"})]), result(K + 400, "tk"),
         say(K + 410), done(K + 420), human(K + 430)])))
rows = []
m.read_transcript(path, {"off": 0}, rows, {}, dark)
row = by(rows, "t", K)
check(dark == [[K + 100, K + 200]] and row[8] == [[K + 100, K + 200]] and row[9].get("dark") == 100.0
      and by(slept, "t", K)[8] == [],
      "C1 a sleep inside a turn darkens only its own span, not the whole line gap: %s" % row)

M = B + 20000
media = chat("media", [human(M), say(M + 10, tools=[("tm", "Bash", {"command": "codex-image --dest /x.png --prompt p"}),
                                                   ("ta", "Bash", {"command": "media-run image --vendor codex -- --dest /x.png"})]),
                       result(M + 70, "tm"), result(M + 90, "ta"), say(M + 95), done(M + 100), human(M + 110)])
check(by(media, "t", M)[9].get("media") == 80.0 and by(media, "t", M)[11] == [["tm", "media"], ["ta", "media"]],
      "C1 a media script and a media-run call are the media layer, and the row lists its calls")

P = B + 22000
killed = chat("killed", [human(P), say(P + 10), human(P + 300), say(P + 310), done(P + 320), human(P + 330)])
row = by(killed, "t", P)
check(row[3] == P + 10 and row[7] == [P] and row[5] == [0, 1, 1] and by(killed, "t", P + 300)[7] == [P + 300],
      "C1 a turn left open (no turn_duration) ends at its last entry, and the next prompt opens and answers it: %s" % row)

phases = os.path.join(projects, "p", "phase-s.jsonl")
with open(phases, "w") as handle:
    handle.write("".join(json.dumps(l) + "\n" for l in [
        say(M, tools=[("toolu_g0123456789", "Bash", {"command": "cd /x && media-run image --vendor gemini -- --dest a.png"})]),
        result(M + 60, "toolu_g0123456789"),
        say(M + 61, tools=[("g2", "Read", {"file_path": "/x/a.png"})]), result(M + 62, "g2")]))
rows = []
m.read_transcript(phases, {"off": 0}, rows, {})
check([r for r in rows if r[0] == "g"] == [["g", M, "phase-s", M + 60, "0123456789", "media-run"]],
      "C1 a media-run call is a media phase span keyed by its own tool id, and no other call is: %s" % rows)

row = ["t", 1000.0, "sess", 1100.0, "h", [1, 1, 1], 0, [], [], {"test": 30.0, "tool": 10.0, "gen": 5.0}, {},
       [["tid1", "test"], ["tid2", "tool"]]]
m.turn_layers([row], {"tid1": 2000.0, "tid2": 3000.0}, {"sess": [[1001.0, 1011.0], [2000.0, 2050.0]]})
check(row[9] == {"test": 18.0, "tool": 7.0, "gen": 5.0, "hook": 5.0, "queue": 10.0},
      "the hook-batch and suite-queue layers come out of a turn's tool layers in precedence: %s" % row[9])
row = ["t", 1000.0, "sess", 1100.0, "h", [1, 1, 1], 0, [], [], {"test": 5.0, "tool": 10.0}, {}, [["tid1", "test"]]]
m.turn_layers([row], {"tid1": 5000.0}, {"sess": [[1010.0, 1016.0]]})
check(row[9] == {"tool": 4.0, "hook": 5.0, "queue": 6.0},
      "queue seconds a hook-emptied layer cannot hold move on to the next tool layer: %s" % row[9])
load = m.section("Load", [{"key": "load:memory", "dim": True, "cells": ["memory"]}], ["", "a", "b"], [False, True, True],
                 blind="no load sample in the last hour")
guard = next(s for s in m.regroup([load]) if s["name"] == "Memory guard")
check(guard["state"] == "blind" and guard["fact"] == "no load sample in the last hour",
      "a section split out of a blind one is blind, never ok: %s" % guard)

os.environ["HARNESS_DOCTOR_DIR"] = sd = os.path.join(work, "speed-state")
runs = [m.run_row(f.split("\t")) for f in ("1000000000\t1003000000\tstop-dispatch.sh\t0\t9\t5000",
                                           "1000500000\t1002000000\tstop.d/a\t0\t9\t3000",
                                           "1000000000\t1001000000\tpre-a.sh\t0\t9")]
check(runs[0][6] == 5.0 and runs[2][6] is None, "C2 a row's sixth column is its CPU, absent on bash before 5.3")
batches = m.hook_batches(runs, {"stop-dispatch.sh": {("Stop", "")}, "stop.d/a": {("Stop", "")}}, 2000)
check([sorted(b["runs"]) for b in batches] == [["stop-dispatch.sh"]],
      "C2 stop.d parts are never batched with their dispatcher: %s" % [sorted(b["runs"]) for b in batches])
st = {}
for run in runs:
    m.hook_cpu(st, run[0], run[1], "" if run[6] is None else int(run[6] * 1000))
day = m.speed_day(st, 1000)
check(day["hook_cpu_us"] == {"stop-dispatch.sh": [1, 5000], "stop.d/a": [1, 3000]}
      and day["hook_cpu_us_total"] == [1, 5000],
      "C2 hook CPU per key, the dispatcher's total never summed with its parts: %s" % day)
batch = {"t0": 0.0, "ms": 3000.0, "runs": {"a": (1.0, "a", 1000.0, False, 0.0, "9"), "b": (3.0, "b", 3000.0, False, 0.0, "9")}}
check(m.batch_parts([batch]) == {"a": [1000.0, 3000.0], "b": [3000.0, 1000.0]},
      "C2 the counterfactual floor without a hook ends at the batch's other runs")

ticks = [[T - 10, 2.5]]
floor = {"t": T, "cls": "bash:other", "ms": 3000.0, "kb": 2048, "batches": [batch]}
m.speed_floor(st, floor, ticks)
m.speed_floor(st, dict(floor, t=T + 500), ticks)
m.speed_flush(st, T, True)
written = json.load(open(os.path.join(sd, "speed-days", m.local_day(T) + ".json")))
check(sorted(written["floors"]) == ["bash:other|2-4|1-10", "bash:other|?|1-10"]
      and [h[0] for h in written["floor_hooks"]["bash:other|2-4|1-10|b"]] == [1, 1, 1]
      and written["floor_hooks"]["bash:other|2-4|1-10|b"][1][1] == 1000,
      "C2 floors and per-hook (own, without, floor) histograms per (class, load, size) band reach the day file")
check(m.local_day(1000) not in st["speed"]["days"] and m.local_day(T) in st["speed"]["days"],
      "a day older than yesterday leaves the state once written")

mdir = os.path.join(work, "memlogd", "machine")
os.makedirs(mdir)
day_name = time.strftime("%Y-%m-%d", time.localtime(T))
with open(os.path.join(mdir, day_name + ".log"), "w") as handle:
    handle.write("%d load1=5.0 ncpu=10 swap_mb=900 swapin_pages_s=4 thermal=0 boot=1790882097 probe_ms=40\n" % (T - 30))
    handle.write("%d load1=30.0 ncpu=10 swap_mb=1200 swapin_pages_s=-1 thermal=2 boot=1790882097\n" % (T - 15))
    handle.write("%d load1=-1 ncpu=10 swap_mb=1200 swapin_pages_s=1 thermal=0 boot=1790999999 probe_ms=-1\n" % T)
st = {}
ticks = m.fold_machine(st, {}, T)
mach = st["speed"]["days"][day_name]["machine"]
check(ticks == [[T - 30, 0.5], [T - 15, 3.0]] and mach["band_s"] == {"<1": 15, "2-4": 15, "?": 15}
      and mach["probe_ms"]["<1"][0] == 1 and mach["swap_mb_max"] == 1200 and mach["thermal_ticks"] == 1
      and st["boots"] == [1790882097.0, 1790999999.0],
      "C6 memlogd machine lines fold into load bands, the probe per band, swap, thermal and boots: %s %s" % (ticks, mach))
journal = {}
m.fold_machine(st, journal, T)
m.fold_machine(st, journal, T)
check(st["speed"]["days"][day_name]["machine"]["band_s"]["<1"] == 30, "C6 machine lines are read once by offset")

st = {"files": {"/p/sess1234-x.jsonl": {"act": [[T - 100, T - 40]], "pend": {}},
                "/p/sess5678-x.jsonl": {"act": [], "pend": {"t1": [T - 20, "Bash", 0, 1]}}}}
m.statusline_fold(st, [(T - 50, "sess1234-full", "12"), (T - 10, "sess1234-full", "-"), (T - 10, "sess5678-full", "8"),
                       (T - 30, "sess5678-full", "3")], T)
line = m.speed_day(st, T)["statusline"]
check([line[k] for k in ("renders", "idle", "cpu_ms", "cpu_n", "idle_cpu_ms")] == [4, 2, 23, 3, 3]
      and len(line["session_hours"]) == len({"sess1234:%d" % ((T - 50) // 3600), "sess1234:%d" % ((T - 10) // 3600),
                                              "sess5678:%d" % ((T - 10) // 3600), "sess5678:%d" % ((T - 30) // 3600)}),
      "statusline renders fold with their CPU, session-hours, and idle when no line or open call is near: %s" % line)

os.environ["CLAUDEB_STARTS_LOG"] = starts = os.path.join(work, "claudeb-starts", "starts.tsv")
os.makedirs(os.path.dirname(starts))
with open(starts, "w") as handle:
    handle.write("%d.100000\t%d.150000\t4242\tlocomthebest\tchat\n" % (T - 900, T - 900))
    handle.write("%d.000000\t%d.050000\t4343\tnotcom\tworker\n" % (T - 1300, T - 1300))
    handle.write("%d.000000\t%d.020000\t4444\tnotcom\tchat\n" % (T - 60, T - 60))
st = {}
got = m.fold_starts(st, {}, [{"t": T - 897.0, "ms": 2500.0, "cls": "event:SessionStart", "ppid": "4242"},
                             {"t": T - 50.0, "ms": 100.0, "cls": "event:Stop", "ppid": "4444"}], T)
check([r[2:4] + r[6:] for r in got] == [["locomthebest", "chat", "4242"], ["notcom", "worker", "4343"]]
      and abs(got[0][1] - (T - 899.9)) < 1e-3 and [r[4] for r in got] == [0.05, 0.05] and got[0][5] == 5.4
      and got[1][5] is None and [p[2] for p in st["speed"]["starts"]] == ["4444"],
      "C11 a start joins its process's SessionStart batch, expires unjoined, or waits: %s" % got)

cache = os.path.join(work, "cli-cache", "-Volumes-x", "mcp-logs-codex")
os.makedirs(cache)
os.environ["CLAUDE_CLI_CACHE_DIR"] = os.path.dirname(os.path.dirname(cache))
def mcp_line(t, text):
    return json.dumps({"debug": text, "timestamp": stamp(t), "sessionId": "abcdef12-9", "cwd": "/x"}) + "\n"
log = os.path.join(cache, "a.jsonl")
with open(log, "w") as handle:
    handle.write(mcp_line(T - 5, "Starting connection with timeout of 30000ms")
                 + mcp_line(T - 4, "Successfully connected (transport: stdio) in 462ms")
                 + mcp_line(T - 3, "Connection failed after 3ms (ECONNREFUSED): x"))
st = {}
first = m.fold_mcp(st, T)
with open(log, "a") as handle:
    handle.write(mcp_line(T - 2, "Successfully connected (transport: stdio) in 90ms"))
for path in (log, cache):
    os.utime(path, (T - 2, T - 2))
check(first == [["m", T - 4, "abcdef12", "codex", 462, 1], ["m", T - 3, "abcdef12", "codex", 3, 0]]
      and m.fold_mcp(st, T + 1) == [["m", T - 2, "abcdef12", "codex", 90, 1]],
      "C11 MCP connect results fold once per line from the changed log directories: %s" % first)
other = os.path.join(os.path.dirname(cache), "mcp-logs-other")
os.makedirs(other)
fresh = os.path.join(other, "b.jsonl")
open(fresh, "w").close()
os.utime(fresh, (T + 2, T + 2))
os.utime(other, (T + 2, T + 2))
check(m.fold_mcp(st, T + 3) == [], "C11 an empty new log yields nothing yet")
for path, line in ((log, mcp_line(T + 100, "Successfully connected (transport: stdio) in 70ms")),
                   (fresh, mcp_line(T + 101, "Connection failed after 5ms (ECONNREFUSED): y"))):
    with open(path, "a") as handle:
        handle.write(line)
    os.utime(path, (T + 101, T + 101))
for path in (cache, other):
    os.utime(path, (T - 7200, T - 7200))
check(sorted(m.fold_mcp(st, T + 600)) == [["m", T + 100, "abcdef12", "codex", 70, 1], ["m", T + 101, "abcdef12", "other", 5, 0]],
      "C11 lines appended to logs already seen, an empty one included, fold although the directory's mtime stayed old")

os.environ["RUN_SUITES_JOURNAL"] = suites = os.path.join(work, "suites-journal.jsonl")
with open(suites, "w") as handle:
    handle.write(json.dumps({"session": "sessQQQQ-1", "queued_at": T - 50, "started_at": T - 20}) + "\n"
                 + json.dumps({"session": "sessQQQQ-1", "queued_at": T - 10, "started_at": T - 10}) + "\n"
                 + json.dumps({"session": None, "queued_at": T - 50, "started_at": T - 20}) + "\n")
check(m.fold_suites({}, {}, T) == {"sessQQQQ": [[T - 50, T - 20]]}, "C5 a chat's suite slot wait is its queue span")

check(m.etime_s("1-02:03:04.50") == 86400 + 7384.5 and m.etime_s("12:34,5") == 754.5, "ps CPU times parse")
fake_home = os.path.join(work, "label-home")
os.makedirs(os.path.join(fake_home, "Library", "LaunchAgents"))
os.makedirs(os.path.join(fake_home, ".local", "libexec"))
wrapper = os.path.join(fake_home, ".local", "libexec", "tool-runner")
with open(wrapper, "w") as handle:
    handle.write('#!/bin/bash\nscript=/opt/x/bin/tool\npython=/opt/homebrew/bin/python3\nexec "$python" "$script" --quiet\n')
import plistlib
for label, args in (("com.x.tool", [wrapper]), ("homebrew.redis", ["/opt/homebrew/bin/redis-server", "/etc/r.conf"]),
                    ("com.x.bash", ["/bin/bash", "/opt/y/job.sh"]), ("com.x.env", ["/usr/bin/env", "python3", "/opt/z/run.py"]),
                    ("com.x.inline", ["/bin/sh", "-c", "echo hi"])):
    with open(os.path.join(fake_home, "Library", "LaunchAgents", label + ".plist"), "wb") as handle:
        plistlib.dump({"Label": label, "ProgramArguments": args}, handle)
saved_home, os.environ["HOME"] = os.environ["HOME"], fake_home
labels = m.launchd_labels()
os.environ["HOME"] = saved_home
check(labels == [("com.x.bash", ["/opt/y/job.sh"]), ("com.x.env", ["/opt/z/run.py"]),
                 ("com.x.tool", sorted([wrapper, "/opt/x/bin/tool"])), ("homebrew.redis", ["/opt/homebrew/bin/redis-server"])],
      "C7 a LaunchAgent maps to its program (an interpreter's script) and its libexec wrapper's exec target, never the interpreter: %s" % labels)
early, late = "Sat Oct  3 01:00:00 2026", "Sat Oct  3 02:30:00 2026"
mark = time.mktime(time.strptime("Sat Oct  3 02:00:00 2026", "%a %b %d %H:%M:%S %Y"))
before = {"100": ("1", 5.0, early, "/opt/homebrew/bin/python3 /opt/x/bin/tool --quiet"), "1": ("0", 0.0, early, "launchd")}
after = dict(before, **{"101": ("100", 0.1, late, "/usr/bin/true"), "102": ("1", 0.3, late, "/usr/local/bin/other")})
last = dict(after, **{"100": ("1", 7.5, early, before["100"][3])})
st = {"speed": {"ps": {"100|" + early: 5.0}, "ps_t": mark}}
m.speed_census(st, [(T - 2, before), (T - 1, after), (T, last)], T, labels)
acc = m.speed_day(st, T)
check(acc["census"] == {"com.x.tool": 1, "unattributed": 1} and acc["census_s"] == 2
      and acc["label_cpu_s"] == {"com.x.tool": 2.6, "unattributed": 0.3},
      "C7 census forks and ps CPU deltas go to the launchd label of their ancestor chain: %s" % acc)
events = scan(m, root, os.path.join(work, "calibration"))
a_min, b_min = (x / ((HI - LO) / 86400.0) for x in m.owner_minutes(events, 1, LO, HI))
check(94 <= a_min <= 104 and 63 <= b_min <= 77,
      "C1 calibration 2026-09-29 00:00 to 10-02 21:50 +0300 at R = 5: A %.1f (99 ± 5), B +%.1f (70 ± 7) OM/d"
      % (a_min, b_min))
print(count[0])
EOF
) || fail "the transcript rows (C1) or the journal offsets misjudged"
asserts=$((asserts + speed))

# A Background agent gets no CPU under a saturated machine: on 2026-09-30 a run starved for 48 min
# holding the lock, and the menu froze exactly when load was what it had to show.
assert_eq Standard "$(plutil -extract ProcessType raw "$ROOT/launchd/com.egor.harness-doctor.plist")" \
  "the doctor LaunchAgent runs in the Standard band, never Background"
assert_eq '["/x/speed","--quiet"]' "$(SPEED_DOCTOR_DIR="$WORK/exec-cpu" SPEED_DOCTOR_CMD=/x/speed python3 - "$DOCTOR" <<'EOF'
import importlib.machinery, importlib.util, json, os, sys
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(module)
os.execv = lambda path, argv: print(json.dumps(argv, separators=(",", ":")))
module.exec_speed()
EOF
)" "Speed runs at its caller's priority: a night prep or menu waiting on Harness never waits on a taskpolicy -b band"

printf 'PASS: %s asserts; harness-doctor reads waits, cuts, hooks, load, tests and causes off fixtures, incrementally and under its lock in a LaunchAgent that is never starved, and compares every picker window, days off its day summaries and hours off the raw rows\n' "$asserts"
