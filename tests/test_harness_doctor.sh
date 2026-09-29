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
trap 'rm -rf "$WORK"' EXIT
export TZ=UTC HOME="$WORK/home"
export CLAUDE_PROJECTS_DIR="$HOME/.claude/projects" HARNESS_SETTINGS="$HOME/.claude/settings.json"
export STATUSLINE_CACHE_DIR="$WORK/statusline" MEMLOGD_DIR="$WORK/memlogd" INSTRUCTION_WATCH_STATE="$WORK/watch"
export CLAUDEB_DIR="$WORK/claudeb" HARNESS_WATCH_ROOTS="$HOME/hooks" HARNESS_DOCTOR_DIR="$WORK/state"
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
born = os.stat(spool).st_birthtime
os.utime(spool, (born + 0.6, born + 0.6))
with open(os.path.join(journal, "statusline", time.strftime("%Y-%m-%d", time.localtime(T)) + ".tsv"), "w") as handle:
    handle.write("".join("%d\t%d\ts1\n" % ((T - 600 + i) * 1000000, (T - 600 + i) * 1000000 + 80000)
                         for i in range(3)))
os.makedirs(os.path.join(journal, "days"))
with open(os.path.join(journal, "days", time.strftime("%Y-%m-%d", time.gmtime(T - 9 * 86400)) + ".json"), "w") as handle:
    json.dump({"v": 2, "slow_s": 0, "waits": {"bash:alpha": [30, 15000, 500, 500, 0, 0, [0] * 11 + [30]]}}, handle)
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
assert_eq '[["1.2","0.1"],[2]]' "$(doc "$(rowq Hooks "post-fast") | [.cells[2:4], .red]")" \
  "journal rows give every run's median and the day's total, and a slow median over the hour is red"
hooknav() { printf '.sections[] | select(.name == "Hooks") | .nav[0].menu.rows[] | select(.cells[0] == "%s")' "$1"; }
assert_eq '"0.6"' "$(doc "$(hooknav post-edit) | .cells[2]")" \
  "a /bin/bash run's spool file is timed by its birth and change times"
assert_eq '["each render","0.1"]' "$(doc "$(hooknav "statusline (not a hook)") | .cells[1:3]")" \
  "the statusline render journal is read"
assert_eq 'true' "$(doc '.extras[2].menu.rows[0].cells[0] | startswith("hook time of ")')" \
  "hooks that do not source the timing lib are a blind spot"
assert_eq '0' "$(find "$HARNESS_DOCTOR_DIR/hooks/spool" -type f | wc -l | tr -d ' ')" "a folded spool file is removed"
assert_eq '"3"' "$(doc "$(rowq Hooks "post-slow") | .cells[4]")" "a Post cut goes to the hook whose limit the call reached"
assert_eq '[4]' "$(doc "$(rowq Hooks "post-slow") | .red")" "three cuts in the hour make the hook red"
assert_eq '"1"' "$(doc "$(rowq Hooks "(which hook") | .cells[4]")" \
  "a cut from before the settings changed is not blamed on today's timeouts"
assert_eq '["2.5",[2]]' "$(doc "$(rowq Hooks "pre-slow") | [.cells[2], .red]")" \
  "printed hook durations make a p50 over the limit red"
assert_eq '["none","niced"]' "$(doc ".sections[] | select(.name == \"Hooks\") | .nav[] | select(.cells[0] | startswith(\"2 hooks can hold\")) | .menu.rows[] | select(.cells[0] == \"prompt-nice\") | .cells[2:4]")" \
  "a hook with no limit that renices itself is marked among the hooks a chat can wait on"
assert_eq '[[],false]' "$(doc "$(rowq Load "CPU busy") | [.red, .dim]")" "a busy share above the note limit is shown, not red"
assert_eq '[4]' "$(doc "$(rowq Tests "suites · alpha") | .red")" "a run twice its usual time is red on its last cell"
assert_eq '"suites at once today: 6"' \
  "$(doc '.sections[] | select(.name == "Tests") | .lead[] | select(.key == "tests:overlap") | .cells[0]')" \
  "overlapping suite runs are counted across repos"
assert_eq "[[$((T - 3000)),$((T - 888))]]" "$(doc .local_slow)" \
  "local_slow spans the first slow call to the end of the last one while a Waits call row was red"
assert_eq '["problem",true]' \
  "$(doc '.sections[] | select(.name == "Waits") | [.state, (.lead[0].cells[0] | startswith("started before "))]')" \
  "an area red since the first run claims no cause"
assert_eq "$(doc '[.sections[] | select(.state == "problem")] | length')" "$(doc .red)" \
  "the title counts the areas in trouble, not their rows"
assert_eq '"a Bash call in alpha waits 8.0 s, fine under 3.0 s"' \
  "$(doc '.sections[] | select(.name == "Waits") | .fact')" "the Waits verdict states its worst row in words and units"
YESTERDAY=$(date -u -r $((T - 86400)) +%Y-%m-%d)
assert_eq '[2,20]' "$(jq -c '[.v, .waits["bash:alpha"][0]]' "$HARNESS_DOCTOR_DIR/days/$YESTERDAY.json")" \
  "a finished day is summarized as histograms per waiter"
assert_eq '6' "$(jq --arg d "$(date -u -r "$T" +%Y-%m-%d)" '.journal.days[$d]["post-fast.sh"][0]' "$HARNESS_DOCTOR_DIR/state.json")" \
  "journal runs also add up per day, for the day summary"
assert_eq '["7 days vs prev 7 · 1 worse",["Bash wait s","1.9","0.5","+275%"],[3]]' \
  "$(doc '.extras[0] | [.cells[0], .menu.rows[0].cells, .menu.rows[0].red]')" \
  "the week comparison marks a material rise red against the stored summary of the week before"

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
assert_eq "$(jq -r .red "$HARNESS_DOCTOR_DIR/latest.json")" "$(head -1 "$HARNESS_DOCTOR_DIR/menu.txt" | cut -f2)" \
  "menu.txt carries the document's red count"

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
entry, cur = module.weeks_section(summaries, [], T, [])
rows = {r["cells"][0]: r for r in entry["menu"]["rows"]}
assert entry["cells"][0] == "7 days vs prev 7 · 1 worse, 1 better", entry["cells"]
assert [p[1] for p in entry["parts"]] == ["", "r", "g"], entry["parts"]
assert rows["Bash wait s"]["cells"][1:] == ["1.0", "5.0", "-80%"] and rows["Bash wait s"]["green"] == [3], rows["Bash wait s"]
assert rows["Edit wait s"]["cells"][3] == "+400%" and rows["Edit wait s"]["red"] == [3], rows["Edit wait s"]
by_week = entry["menu"]["nav"][0]["menu"]
assert len(by_week["columns"]) == 1 + module.BY_WEEKS and by_week["columns"][0] == "week (Mon–Sun)", by_week["columns"]
assert module.delta(1.05, 1.0) == ("+5%", "") and module.delta(12.0, 1.0) == ("×12", "worse"), module.delta(12.0, 1.0)
EOF
asserts=$((asserts + 1))

# The hooks write their timings into hooks/spool with builtins alone; a fresh install's first run makes it.
HARNESS_DOCTOR_DIR="$WORK/fresh" HARNESS_DOCTOR_NOW=$((T + 900)) HARNESS_DOCTOR_FAKE_SAMPLE="" "$DOCTOR" --quiet ||
  fail "a fresh run failed"
assert_eq yes "$([ -d "$WORK/fresh/hooks/spool" ] && echo yes)" "a fresh run makes the hooks' spool"

printf 'PASS: %s asserts; harness-doctor reads waits, cuts, hooks, load, tests and causes off fixtures, incrementally and under its lock, and compares weeks off its day summaries\n' "$asserts"
