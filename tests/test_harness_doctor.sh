#!/usr/bin/env bash
# bin/harness-doctor over a fixture HOME: transcript waits, hook cut attribution, levels, the tests
# journal, steps against the change log, the local_slow windows LLM doctor reads, incremental
# reads, the lock and the laid-out menu lines.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DOCTOR="$ROOT/bin/harness-doctor"
# project_of names /private/tmp and /private/var paths "tmp", so the fixture repos must sit on the
# unresolved /var/folders path.
WORK=$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)hd.XXXXXX")
trap '[ -z "${reused_pid:-}" ] || kill "$reused_pid" 2>/dev/null; rm -rf "$WORK"' EXIT
export TZ=UTC HOME="$WORK/home"
export CLAUDE_PROJECTS_DIR="$HOME/.claude/projects" HARNESS_SETTINGS="$HOME/.claude/settings.json"
export STATUSLINE_CACHE_DIR="$WORK/statusline" MEMLOGD_DIR="$WORK/memlogd" INSTRUCTION_WATCH_STATE="$WORK/watch"
export CLAUDEB_DIR="$WORK/claudeb" HARNESS_WATCH_ROOTS="$HOME/hooks" HARNESS_DOCTOR_DIR="$WORK/state"
export HARNESS_LEDGER="$WORK/ledger.json" HARNESS_REPOS_DIR="$WORK"
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
    handle.write("post-edit.sh\t0\t77\n")
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
assert_eq 'post-edit.sh	0	77' "$(cut -f3- "$HARNESS_DOCTOR_DIR"/hooks/folded/*.tsv)" \
  "a folded spool run is kept per run for the batch join"
assert_eq '"3"' "$(doc "$(rowq Hooks "post-slow") | .cells[4]")" "a Post cut goes to the hook whose limit the call reached"
assert_eq '[4]' "$(doc "$(rowq Hooks "post-slow") | .red")" "three cuts in the hour make the hook red"
assert_eq '"1"' "$(doc "$(rowq Hooks "(which hook") | .cells[4]")" \
  "a cut from before the settings changed is not blamed on today's timeouts"
assert_eq '["2 500",[2]]' "$(doc "$(rowq Hooks "pre-slow") | [.cells[2], .red]")" \
  "printed hook durations make a p50 over the limit red"
assert_eq '["none","niced"]' "$(doc ".sections[] | select(.name == \"Hooks\") | .nav[] | select(.cells[0] | startswith(\"2 hooks can hold\")) | .menu.rows[] | select(.cells[0] == \"prompt-nice\") | .cells[2:4]")" \
  "a hook with no limit that renices itself is marked among the hooks a chat can wait on"
assert_eq '[[],false]' "$(doc "$(rowq Load "CPU busy") | [.red, .dim]")" "a busy share above the note limit is shown, not red"
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
assert_eq '[["count","evidence","exposure","fact","first_seen","id","last_seen","ledger","limit","near","rule","runs_red","state","unit","value","window_h"]]' \
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
assert_eq '["7 d vs prev 7 d · 1 worse",["Bash wait s","1.9","0.5","+275%"],[3]]' \
  "$(doc '.periods["168"] | [.cells[0], .menu.rows[0].cells, .menu.rows[0].red]')" \
  "the week comparison marks a material rise red against the stored summary of the week before"
assert_eq '["3 h vs prev 3 h · 1 better",[3],"7 d vs prev 7 d · 1 worse"]' \
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
assert_eq '[1]' "$(doc "$(rowq Load "CPU busy") | .red")" "the hour's mean busy share over the limit is red"
assert_eq '[1]' "$(doc "$(rowq Load "memory") | .red")" "the memory guard's alarm is red"
assert_eq 'edited' "$(doc '.sections[] | select(.name == "Load") | .lead[0].menu.rows[0].cells[1]' | tr -d '"')" \
  "an area that turned red lists the changes before it"
assert_eq 'true' "$(doc '.sections[] | select(.name == "Load") | .lead[0].cells[0] | test("^started [0-9]{2}:[0-9]{2} · [0-9]+ changes? before it$")')" \
  "the area's cause line counts the changes in the 6 h before"
assert_eq 'true' "$(doc '.sections[] | select(.name == "Load") | .fact | test(" · since [0-9]{2}:[0-9]{2}$")')" \
  "a problem that started after the first run carries its start on the verdict"

python3 - "$HARNESS_DOCTOR_DIR/menu.txt" <<'EOF' || fail "menu.txt spans do not point at the red cells"
import sys
lines = open(sys.argv[1], "rb").read().split(b"\n")
assert lines[0].startswith(b"T\t"), lines[0]
red = 0
for line in lines[1:]:
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
python3 - "$HARNESS_DOCTOR_DIR/menu.txt" <<'EOF' || fail "an area's top line is not 'Name: state · fact' in plain words"
import re, sys
areas = 0
for line in open(sys.argv[1]).read().split("\n")[1:]:
    depth, flags, spans, text = line.split("\t", 3)
    if depth != "0":
        continue
    if flags.startswith("s"):
        break
    areas += 1
    match = re.fullmatch(r"([A-Z][a-z]+(?: [a-z]+)*): (ok|watch|problem|blind)(?: · (.+))?", text)
    assert match, text
    assert not re.search(r"\(\+\d|×\d|\.sh\b|deferred|bg-task", text), text
    if match.group(2) == "problem":
        start = len(match.group(1)) + 2
        assert "r:%d:7" % start in spans.split(","), (spans, text)
assert areas >= 8, areas
EOF
asserts=$((asserts + 1))
python3 - "$HARNESS_DOCTOR_DIR/menu.txt" <<'EOF' || fail "menu.txt does not tag every line of a window block, and only those"
import re, sys
labels = {"3": "3 h", "6": "6 h", "12": "12 h", "24": "24 h", "72": "3 d", "168": "7 d"}
blocks, current, untagged = {}, None, 0
for line in filter(None, open(sys.argv[1], encoding="utf-8").read().split("\n")[1:]):
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
assert entry["cells"][0] == "7 d vs prev 7 d · 1 worse, 1 better", entry["cells"]
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
import importlib.machinery, importlib.util, json, os, sys
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
check([r[2:] for r in folded] == [("gate-a.sh verdict", "1", "4242")],
      "a spool file carrying a hook's stray output still folds to its key, exit and ppid")
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
for key, bad in (("busy", 0.95), ("kernel", 0.6), ("forks", 3000), ("visible", 1.0), ("guard", True),
                 ("swap_mb", 950)):
    extra = {key: bad, "busy": 0.95} if key == "visible" else {key: bad}
    red = [sample(T - 600, **extra), sample(T - 300, **extra)]
    check(state_of(m.load_section(red, T)) == "problem", "Load: %s over its limit is red" % key)
    check(state_of(m.load_section(red + [sample(T + 3000), sample(T + 3300)], T + 3600)) == "ok",
          "J Load: %s clears when the next hour is calm" % key)

suites = [test_row(r, "suites", T - 900, T - 100) for r in ("a", "b", "c", "d", "e")]
check(state_of(m.tests_section(suites, T)) == "problem", "Tests: 5 suites at once are red")
check(state_of(m.tests_section(suites, T + 7 * 3600)) == "ok", "J Tests: the suite peak clears after 6 h")
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
          "hook_p50_s": 1.0, "hook_min_samples": 5, "busy": 0.90, "busy_note": 0.70, "kernel": 0.50,
          "kernel_note": 0.30, "forks": 2500, "forks_note": 1000, "unseen_cores": 5.0, "unseen_note": 2.0,
          "swap_share": 0.90, "suites_at_once": 5, "suites_note": 3, "test_slow_ratio": 2.0, "test_slow_min_s": 600,
          "test_slow_fresh_s": 6 * 3600, "test_cost_window_s": 24 * 3600, "long_pole_share": 0.5,
          "long_pole_min_s": 300, "test_day_s": 2 * 3600, "test_day_note_s": 3600, "loose_note": 6700, "loose_red": 13400, "store_entries": 50000,
          "store_bytes": 1 << 30, "store_growth": 2.0, "impact_min_calls": 3, "floor_ms": 300, "floor_note_ms": 150,
          "floor_write_ms": 500, "floor_event_ms": 1000, "hook_note_ms": 150, "every_call_ms": 50,
          "full_work_ratio": 0.8, "full_work_min_ms": 10, "split_min_runs": 10, "history_ratio": 1.5,
          "history_min_ms": 20, "load_fail_suites": 3, "load_pass_within_s": 3600, "menu_ms": 300,
          "menu_note_ms": 100, "menu_min_builds": 3, "per_call_entries": 1000, "collector_s": 30.0,
          "stop_repeat_s": 1800, "ask_deferred_s": 7200, "silent_s": 21600, "growth_min_b": 120, "watch_tick_s": 120,
          "hold_note_s": 60, "hold_red_s": 300}
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

race, prior_ledger = os.path.join(work, "race-ledger.json"), os.environ["HARNESS_LEDGER"]
os.environ["HARNESS_LEDGER"] = race
put(os.path.join(repo, "f.sh"), "x\n")
stale = {"rows": [dict(pending["rows"][0], status="fixed-pending", fixes=[dict(pending["rows"][0]["fixes"][0], **{"in": None})])]}
put(race, m.json.dumps(stale))
loaded, _ = m.load_ledger()
m.settle_fixes(loaded)
landed = m.json.loads(open(race).read())
landed["rows"].append({"id": "landed-meanwhile", "status": "open", "fixes": []})
put(race, m.json.dumps(landed))
m.write_fix_fields(loaded)
after = m.json.loads(open(race).read())
check([r["id"] for r in after["rows"]] == ["p", "landed-meanwhile"] and after["rows"][0]["status"] == "fixed"
      and after["rows"][0]["fixes"][-1]["in"] == "fixrepo@" + head,
      "settling a fix re-reads the ledger, so a row landed during the run survives the write")
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
    os.path.dirname(os.path.dirname(os.path.dirname(sys.argv[1]))), "claude-setup"), "hooks", "lib", "words.sh")
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
denied = dict(passed, decision="denied")
check(judged(health(G, gates=[denied], events=[change(T - 600)])) == {("growth-denied", "~/.claude/CLAUDE.md"): "red"},
      "Guards: growth after a denial is red")
check(judged(health(G, gates=[denied], events=[change(T - 600, reverted=True)])) == {},
      "J Guards: a reverted change is quiet")
check(judged(health(G, events=[change(T - 600, kind="stamp-forged")])) == {("stamp-forged", "~/.claude/CLAUDE.md"): "red"}
      and judged(health(G, events=[change(T - 90000, kind="stamp-forged")])) == {},
      "Guards: a forged stamp is red and clears after 24 h")
for kind in ("changed-while-watcher-off", "baseline-missing", "dropped"):
    check(judged(health(G, events=[change(T - 600, kind=kind)])) == {(kind, "tripwire"): "red"}
          and judged(health(G, events=[change(T - 90000, kind=kind)])) == {},
          "Guards: %s is red and clears after 24 h" % kind)
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
run_held() {
  HARNESS_HOLDS_DIR="$holds" HARNESS_DOCTOR_DIR="$WORK/held" HARNESS_DOCTOR_NOW=$held_now HARNESS_DOCTOR_FAKE_SAMPLE="" \
    "$DOCTOR" --quiet
}
run_held || fail "a run over live and leaked holds failed"
kill "$reused_pid" 2>/dev/null
assert_eq "$(jq -cn --arg b "gone-$dead_pid.json" --arg d "reused-$reused_pid.json" \
  '[["limiter_hold:bench-throttle", "new", 3, "holds/bench-throttle-1.json", "bench-throttle holds 3 jobs, longest 7 min: memory pressure"],
    ["limiter_hold:suite-slots", "watch", 1, "holds/suite-slots-1.json", "suite-slots holds 1 job, longest 2 min: memory pressure"],
    ["limiter_hold_leak:gone", "watch", 1, "holds/\($b)", "gone left 1 hold file whose process is gone or unreadable: \($b)"],
    ["limiter_hold_leak:reused", "watch", 1, "holds/\($d)", "reused left 1 hold file whose process is gone or unreadable: \($d)"]]')" \
  "$(jq -c '[.problems[] | select(.rule | startswith("limiter_hold")) | [.id, .state, .count, .evidence[0].ref, .fact]] | sort' \
    "$WORK/held/latest.json")" \
  "a hold over 60 s is a watch, past 5 min red, one under 60 s nothing; a dead pid's file and one whose pid started after since a leak"
assert_eq 2 "$(grep -c 'holds [0-9]* jobs*, longest [0-9]* min: memory pressure' "$WORK/held/menu.txt")" \
  "the doctor's menu names each hold over 60 s, what it holds, for how long and why"
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
python3 - "$1" "$(dirname "$ROOT")" <<'LEDGER'
import json, os, re, subprocess, sys
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
        assert set(fix) == {"at", "by", "files", "in", "regressed_at"} and fix["files"], r["id"]
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
assert_eq '["floor:event:SessionStart=watch","hook-every-call-instruction-watch=watch","hook-sync-instruction-watch-check=watch","hook_every_call:statusline-workdir-hook.sh=watch","test_daily_cost-worker-run=open","test_daily_cost:llm-legs:test_instruction_gate=new","test_long_pole-worker-run=open","floor-trivial-bash-readonly-fastpath=fixed-pending","hook-every-call-context-nudge=fixed-pending","floor-edit-hooks=fixed-pending","guards-tripwire-rejournal=fixed-pending","ask-deferred-bg-task-hold-cap=fixed-pending","word-miss-deferred-reading-lost=fixed-pending","hook-grows-repos-commit-journal=fixed-pending","hook-grows-repos-review-flow-gate=fixed-pending","hook-grows-size-commit-journal=fixed-pending","hook-grows-size-review-flow-gate=fixed-pending","guards-growth-claude-skills-hyperframes=fixed-pending","guards-growth-claude-skills-hyperframes-animation=fixed-pending","guards-growth-claude-skills-hyperframes-audio=fixed-pending","guards-growth-claude-skills-hyperframes-cli=fixed-pending","guards-growth-claude-skills-hyperframes-core=fixed-pending","guards-growth-claude-skills-hyperframes-creative=fixed-pending","guards-growth-claude-skills-hyperframes-keyframes=fixed-pending","guards-growth-claude-skills-hyperframes-registry=fixed-pending","guards-growth-claude-skills-hyperframes-studio=fixed-pending","guards-growth-claude-skills-media-use=fixed-pending","floor:tool=fixed-pending","hook-p50-instruction-watch-baseline=fixed-pending","hook-p50-stop-dispatch=fixed-pending"]' \
  "$first_ids" "the 2026-09-29 18:27 calibration reads its known watches and every night fix as pending proof"
assert_eq '["test_daily_cost-worker-run 8714.0 24","test_daily_cost:llm-legs:test_instruction_gate 10377.0 38","test_long_pole-worker-run 0.957 1"]' \
  "$(jq -c '[.problems[] | select(.id | startswith("test_")) | "\(.id) \(.value) \(.exposure)"]' "$WORK/replay-1.json")" \
  "the calibration's 24 h of llm-legs tests: test_worker_run is the long pole, both suites cost over 2 h"

# A Background agent gets no CPU under a saturated machine: on 2026-09-30 a run starved for 48 min
# holding the lock, and the menu froze exactly when load was what it had to show.
assert_eq Standard "$(plutil -extract ProcessType raw "$ROOT/launchd/com.egor.harness-doctor.plist")" \
  "the doctor LaunchAgent runs in the Standard band, never Background"

printf 'PASS: %s asserts; harness-doctor reads waits, cuts, hooks, load, tests and causes off fixtures, incrementally and under its lock in a LaunchAgent that is never starved, and compares every picker window, days off its day summaries and hours off the raw rows\n' "$asserts"
