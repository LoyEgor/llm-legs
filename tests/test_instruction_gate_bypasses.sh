#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/instruction_gate_harness.sh"
profile_link
docs_link
alert_rec_stub
chat_name_stub
mkdir -p "$PROJ"

echo "== bypasses: every shell spelling of a write onto a guarded file is refused, the neighbours pass"
mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/projects/p/memory" "$WORK/repo2/.claude/agents" \
         "$WORK/repo2/.claude/local" \
         "$WORK/repo2/skills/foo"
printf 'policy\n' > "$HOME/.claude/hooks/policy.md"
# The ordinary stash stays on top: the bare `stash pop` case below must land in notes.txt.
GL="$WORK/gitland"
mkdir -p "$GL"
git -C "$GL" init -q
printf 'rules\n' > "$GL/CLAUDE.md"
printf 'notes\n' > "$GL/notes.txt"
git -C "$GL" add CLAUDE.md notes.txt
git -C "$GL" -c user.name=t -c user.email=t@t commit -qm init
printf 'more rules\n' >> "$GL/CLAUDE.md"
git -C "$GL" -c user.name=t -c user.email=t@t stash -q
printf 'more notes\n' >> "$GL/notes.txt"
git -C "$GL" -c user.name=t -c user.email=t@t stash -q
printf -- '--- a/CLAUDE.md\n+++ b/CLAUDE.md\n@@ -1 +1,2 @@\n rules\n+more\n' > "$WORK/claude.patch"
printf -- '--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1,2 @@\n notes\n+more\n' > "$WORK/notes.patch"
while read -r want c; do
  [ -n "$c" ] || continue
  c=$(printf '%b' "$c")
  got=$(GATE_CWD="$WORK/repo2" gate "$c" 2>/dev/null; echo "rc=$?")
  case "$got" in *'"deny"'*) got=deny ;; *rc=2) got=refuse ;; *) got=pass ;; esac
  asserts=$((asserts + 1))
  [ "$want" = "$got" ] || fail "assert $asserts failed: expected $want, got $got for: $c"
done <<'CASES'
deny printf x >> ~/.claude/hooks/policy.md
deny printf x >> ./skills/foo/SKILL.md
deny echo x > .claude/agents/new.md
deny mv /tmp/x ~/.claude/review-debt-ignore
deny echo hi >& ~/.claude/CLAUDE.md
deny echo hi &> ~/.claude/CLAUDE.md
deny printf Z 1<> ~/.claude/CLAUDE.md
deny printf Z <> ~/.claude/CLAUDE.md
deny echo x > $'CLAUDE.md'
deny echo x > $'CLAUDE.m\\x64'
deny echo hi >> ~/.claude/claude.md
deny echo hi >> ~/.claude/Claude.MD
deny printf x >> ~/.claude/docs/Notes.MD
deny echo x > ~/.claude/agents/new.Markdown
deny python3 -c "import os; os.rename('/tmp/x', 'CLAUDE.md')"
deny python3 -c "import os; open('CLAUDE.md','w').write('x'); print(1)"
deny node -e "require('fs').renameSync('/tmp/x', 'CLAUDE.md')"
deny git checkout -- CLAUDE.md
deny bash <<'X'\nprintf x >> ~/.claude/CLAUDE.md\nX
deny cat <<'X' | bash\nprintf x >> ~/.claude/CLAUDE.md\nX
refuse printf x > "$HOME/.claude/docs/"$'bad\\nname.md'
refuse printf x > "$HOME/.claude/docs/"$'bad\\tname.md'
pass echo x >> ~/.claude/projects/p/memory/note.md
pass echo x > .claude/local/task.md
pass cp /tmp/x .claude/local/task.md
deny echo x > .claude/local/../agents/new.md
pass echo x > notes.txt
pass echo x > /tmp/scratch.md
pass echo x 2>&1
pass cat > /tmp/scratch <<'X'\nprintf x >> CLAUDE.md\nX
pass bash -n /tmp/x.sh && cat > /tmp/scratch <<'X'\nprintf x >> CLAUDE.md\nX
pass cp ~/.claude/CLAUDE.md /tmp/backup.md
pass git -C ../gitland stash pop
deny git -C ../gitland stash pop stash@{1}
deny cd ../gitland && git stash apply stash@{1}
deny git -C ../gitland apply ../claude.patch
deny git apply ../claude.patch
deny cat ../claude.patch | git apply --index
deny git apply <<'X'\n--- a/CLAUDE.md\n+++ b/CLAUDE.md\n@@ -1 +1,2 @@\n rules\n+more\nX
deny git apply -p0 <<'X'\n--- CLAUDE.md.orig\t2026-09-23 03:00:00\n+++ CLAUDE.md\t2026-09-23 03:01:00\n@@ -1 +1,2 @@\n rules\n+more\nX
deny git apply -p 2 <<'X'\n--- x/y/CLAUDE.md\n+++ x/y/CLAUDE.md\n@@ -1 +1,2 @@\n rules\n+more\nX
pass git apply -p0 <<'X'\n--- notes.txt\n+++ notes.txt\n@@ -1 +1,2 @@\n rules\n+more\nX
pass git -C ../gitland apply ../notes.patch
pass git apply --check ../claude.patch
deny bash -c "$(cat <<'EOF'\nprintf x >> ~/.claude/CLAUDE.md\nEOF\n)"
deny printf x >> CLAUDE.m\\d
deny printf x >> CLAUDE.m""d
pass python3 -c "x = 1; y = x >> ~/.claude/CLAUDE.md"
deny python3 -c "x = 1; y = 2"; printf x >> ~/.claude/CLAUDE.md
pass python3 -c "print(open('CLAUDE.md').read()); x = 1"
CASES

# A repository path holding sed's delimiter or `&` still names the files its stash lands.
GH="$WORK/R#&D"
mkdir -p "$GH"
git -C "$GH" init -q
printf 'rules\n' > "$GH/CLAUDE.md"
git -C "$GH" add CLAUDE.md
git -C "$GH" -c user.name=t -c user.email=t@t commit -qm init
printf 'more rules\n' >> "$GH/CLAUDE.md"
git -C "$GH" -c user.name=t -c user.email=t@t stash -q
assert_eq "$(cd "$GH" && pwd -P)/CLAUDE.md" "$(share_call 'instruction_git_landing "git stash pop" "$2"' "$GH")"
assert_eq deny "$(GATE_CWD="$GH" decision 'git stash pop')"

echo "== bypasses: the bloat gate prices every spelling and every edit tool"
mkdir -p "$HOME/.claude/rules" "$HOME/.claude/skills-on-demand/s"
printf 'x\n' > "$HOME/.claude/rules/r.md"
printf 'x\n' > "$HOME/.claude/skills-on-demand/s/s.md"
printf 'x\n' > "$WORK/repo2/notes.md"
bloat_tool() { # tool tool-input-json
  local out
  out=$(jq -cn --arg n "$1" --argjson ti "$2" '{tool_name:$n,session_id:"s",cwd:"/tmp",tool_input:$ti}' \
    | bash "$BLOAT" 2>/dev/null)
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"'
}
edit_json() { jq -cn --arg f "$1" --arg n "$2" '{file_path:$f,old_string:"x",new_string:$n}'; }
assert_eq deny "$(bloat_tool Edit "$(edit_json '~/.claude/docs/review-tiers.md' "$big")")"
assert_eq deny "$(bloat_tool Edit "$(edit_json "$HOME/.claude/rules/r.md" "$big")")"
assert_eq deny "$(bloat_tool Edit "$(edit_json "$HOME/.claude/skills-on-demand/s/s.md" "$big")")"
assert_eq deny "$(bloat_tool Edit "$(edit_json "$WORK/repo2/claude.MD" "$big")")"
assert_eq pass "$(bloat_tool Edit "$(edit_json "$WORK/repo2/notes.md" "$big")")"
half=${big:0:100}
assert_eq deny "$(bloat_tool MultiEdit "$(jq -cn --arg f "$HOME/.claude/rules/r.md" --arg n "$half" \
  '{file_path:$f,edits:[{old_string:"x",new_string:$n},{old_string:"y",new_string:$n}]}')")"
assert_eq pass "$(bloat_tool MultiEdit "$(jq -cn --arg f "$HOME/.claude/rules/r.md" \
  '{file_path:$f,edits:[{old_string:"x",new_string:"yy"}]}')")"

echo "== bypasses: a hook that cannot run refuses instead of passing"
mkdir -p "$WORK/nolib/bin" "$WORK/nojq"
cp "$WRITE_GATE" "$BLOAT" "$WATCH" "$WORK/nolib/bin/"
nojq_tools=()
for f in /usr/bin/* /bin/*; do
  [ "${f##*/}" = jq ] || nojq_tools+=("$f")
done
ln -sf "${nojq_tools[@]}" "$WORK/nojq/" 2>/dev/null
for h in instruction-write-gate.sh instruction-bloat-gate.sh instruction-watch.sh; do
  printf '{"tool_name":"Edit","tool_input":{}}' | /bin/bash "$WORK/nolib/bin/$h" check >/dev/null 2>&1
  assert_eq 2 "$?"
  printf 'not json' | /bin/bash "$ROOT/bin/$h" check >/dev/null 2>&1
  assert_eq 2 "$?"
  printf '{"tool_name":"Edit","tool_input":{}}' | PATH="$WORK/nojq" /bin/bash "$ROOT/bin/$h" check >/dev/null 2>&1
  assert_eq 2 "$?"
done

echo "== bypasses: a change the journal could not take is reported again, not absorbed"
span_base sid-jfail >/dev/null
printf 'journal failure\n' >> "$DOC"
mv "$J" "$J.saved" 2>/dev/null
mkdir -p "$J"
out=$(raw_check sid-jfail Bash command "$ANY_CALL" "$NOSPAN_T" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "could not be written" "$out"
rmdir "$J"
[ ! -f "$J.saved" ] || mv "$J.saved" "$J"
out=$(raw_check sid-jfail Bash command "$ANY_CALL" "$NOSPAN_T" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED $DOC" "$out"

echo "== bypasses: the same bytes written twice inside a day are two alerts"
span_base sid-flip >/dev/null
cp "$DOC" "$WORK/doc-a"
printf 'flip B\n' > "$DOC"
raw_check sid-flip Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
cp "$WORK/doc-a" "$DOC"
raw_check sid-flip Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
n0=$(grep -c . "$J")
printf 'flip B\n' > "$DOC"
raw_check sid-flip Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert_eq $((n0 + 1)) "$(grep -c . "$J")"

echo "== bypasses: bytes landing mid-check are reported, never vouched for"
mkdir -p "$WORK/shim"
printf '#!/bin/bash\ncase " $* " in *"%%.9Fm%%t%%N"*) ;; *" -L "*) [ -f "$IW_FLAG" ] || { : > "$IW_FLAG"; printf "landed during the rewrite\\n" >> "$IW_DOC"; } ;; esac\nexec /usr/bin/stat "$@"\n' \
  > "$WORK/shim/stat"
chmod +x "$WORK/shim/stat"
span_base sid-race >/dev/null
printf 'race start\n' >> "$DOC"
IW_FLAG="$WORK/race.flag" IW_DOC="$DOC" PATH="$WORK/shim:$PATH" \
  raw_check sid-race Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert [ -f "$WORK/race.flag" ]
out=$(raw_check sid-race Bash command "$ANY_CALL" "$NOSPAN_T" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "CHANGED $DOC" "$out"
printf '#!/bin/bash\nfor a in "$@"; do case "$a" in *review-tiers.md) rm -f "$a" ;; esac; done\nexec /usr/bin/shasum "$@"\n' \
  > "$WORK/shim/shasum"
chmod +x "$WORK/shim/shasum"
rm -f "$WORK/shim/stat"
cp "$DOC" "$WORK/doc-keep"
span_base sid-vanish >/dev/null
printf 'vanishing\n' >> "$DOC"
out=$(PATH="$WORK/shim:$PATH" raw_check sid-vanish Bash command "$ANY_CALL" "$NOSPAN_T" \
      | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "DELETED $DOC" "$out"
rm -f "$WORK/shim/shasum"
cp "$WORK/doc-keep" "$DOC"

echo "== bypasses: a session id that names no file gets a baseline of its own"
jq -cn '{hook_event_name:"SessionStart"}' | bash "$WATCH" baseline >/dev/null
assert [ ! -e "$INSTRUCTION_WATCH_STATE/session-unknown.tsv" ]
assert_contains "session-unknown-" "$(ls "$INSTRUCTION_WATCH_STATE")"
jq -cn '{hook_event_name:"SessionStart"}' | bash "$WATCH" baseline >/dev/null
assert [ "$(ls "$INSTRUCTION_WATCH_STATE" | grep -c '^session-unknown-')" = 1 ]

echo "== bypasses: the tripwire attributes a write by the clock, whatever the tool"
printf 'tier doc\n' > "$DOC"
span_base sid-spell >/dev/null
pre_call sid-spell Bash command "$grow_cmd" "$SPAN_T"
printf 'a line no human asked for\n' >> "$DOC"
assert_contains "REVERTED" "$(span_check sid-spell Bash command "$grow_cmd" "$SPAN_T")"
assert_eq "tier doc" "$(cat "$DOC")"
span_base sid-multi >/dev/null
pre_call sid-multi MultiEdit file_path "$DOC" "$SPAN_T"
printf 'a line no human asked for\n' >> "$DOC"
assert_contains "REVERTED" "$(span_check sid-multi MultiEdit file_path "$DOC" "$SPAN_T")"
assert_eq "tier doc" "$(cat "$DOC")"

echo "== gate journal: every decision on an instruction file outlives its retry stamp"
GJ="$INSTRUCTION_WATCH_STATE/gates.jsonl"
gj_last() { tail -1 "$GJ" | jq -r "$1"; }
rm -rf "$BLOAT_STAMPS"
assert_eq deny "$(bloat_decision "$CLAUDE_MD")"
assert_eq "bloat denied 399 cost $(realpath "$REAL_MD")" "$(gj_last '"\(.gate) \(.decision) \(.delta) \(.detail) \(.real)"')"
age_stamps "$BLOAT_STAMPS"
assert_eq pass "$(bloat_decision "$CLAUDE_MD")"
assert_eq "granted $CLAUDE_MD" "$(gj_last '"\(.decision) \(.file)"')"
assert_eq "" "$(jq -cn --arg p "$CLAUDE_MD" \
  '{tool_name:"Edit",cwd:"/tmp",tool_input:{file_path:$p,old_string:"x",new_string:"yy"}}' | bash "$BLOAT")"
assert_eq "passed 1 threshold 120" "$(gj_last '"\(.decision) \(.delta) \(.detail)"')"
n=$(wc -l <"$GJ")
assert_eq "" "$(jq -cn --arg p "$CLAUDE_MD" \
  '{tool_name:"Edit",cwd:"/tmp",tool_input:{file_path:$p,old_string:"xy",new_string:"z"}}' | bash "$BLOAT")"
assert_eq "$n" "$(wc -l <"$GJ")"
cmd="echo journaled >> $CLAUDE_MD"
assert_eq deny "$(decision "$cmd")"
assert_eq "write denied always" "$(gj_last '"\(.gate) \(.decision) \(.detail)"')"
age_stamps
append_write_user
assert_eq pass "$(decision "$cmd")"
assert_eq "write granted" "$(gj_last '"\(.gate) \(.decision)"')"

echo "== write gate: a leading cd is the directory a relative target resolves against"
assert_eq deny "$(decision "cd ~/.claude/docs && echo x >> review-tiers.md")"
assert_eq deny "$(decision 'cd $HOME/.claude && echo x >> CLAUDE.md')"
assert_eq "$HOME/.claude/CLAUDE.md" "$(gj_last .file)"
assert_eq pass "$(decision "cd $WORK && echo x >> review-tiers.md")"
echo "== write gate: every cd the command runs is a directory a relative target may resolve against"
assert_eq deny "$(decision "cd $WORK && cd ~/.claude/docs && echo x >> review-tiers.md")"
assert_eq deny "$(decision "cd ~/.claude/docs && echo x >> review-tiers.md && cd $WORK")"
assert_eq deny "$(decision "cd $WORK; ls; (cd ~/.claude/docs && echo x >> review-tiers.md)")"

echo "== bloat gate: a missing library denies and leaves a fault the doctor reads"
FG="$WORK/fault-gate"
mkdir -p "$FG/bin" "$FG/share"
cp "$BLOAT" "$FG/bin/"
cp "$ROOT/share/gate-journal.sh" "$FG/share/"
rc=0
jq -cn --arg p "$CLAUDE_MD" '{tool_name:"Edit",tool_input:{file_path:$p}}' \
  | bash "$FG/bin/instruction-bloat-gate.sh" >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc"
assert_eq "fault share/instruction-files.sh missing" "$(gj_last '"\(.decision) \(.detail)"')"

echo "== tripwire: a finished call's window still names its writer to a longer call beside it"
printf 'tier doc\n' > "$DOC"
span_base sid-cwa >/dev/null
span_base sid-cwb >/dev/null
pre_call sid-cwb Bash command "$ANY_CALL" "$SPAN_T"
tool_payload PreToolUse sid-cwa Bash command "$ANY_CALL" "$NOSPAN_T" | bash "$WRITE_GATE" >/dev/null 2>&1
printf 'a line chat A wrote\n' >> "$DOC"
span_check sid-cwa Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert [ -f "$INSTRUCTION_WATCH_STATE/closed/sid-cwa@tu-sid-cwa" ]
out=$(span_check sid-cwb Bash command "$ANY_CALL" "$SPAN_T")
case "$out" in *REVERTED*) fail "chat B reverted chat A's line: $out" ;; esac
assert_eq "tier doc
a line chat A wrote" "$(cat "$DOC")"
rm -rf "$INSTRUCTION_WATCH_STATE/closed"
printf 'tier doc\n' > "$DOC"

echo "== tripwire: this agent's mark a minute older than its call is a denied call, swept"
span_base sid-st >/dev/null
pre_call sid-st Bash command "$ANY_CALL" "$NOSPAN_T"
assert grep -Eq '^[0-9.]+ tu-sid-st Bash - ' "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-sid-st"
printf '%s.000000 tu-old Bash - /tmp\n' "$(( $(date +%s) - 120 ))" > "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-old"
printf '%s.000000 tu-sub Bash agent-a /tmp\n' "$(( $(date +%s) - 120 ))" > "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-sub"
raw_check sid-st Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert [ ! -e "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-old" ]
echo "== tripwire: a parallel subagent's older mark under the same session is its live call, kept"
assert [ -e "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-sub" ]
rm -f "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-sub"
TOOL_AGENT=agent-b pre_call sid-st Bash command "$ANY_CALL" "$NOSPAN_T"
assert grep -Eq '^[0-9.]+ tu-sid-st Bash agent-b ' "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-sid-st"
printf '%s.000000 tu-sub Bash agent-b /tmp\n' "$(( $(date +%s) - 120 ))" > "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-sub"
printf '%s.000000 tu-main Bash - /tmp\n' "$(( $(date +%s) - 120 ))" > "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-main"
TOOL_AGENT=agent-b raw_check sid-st Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
assert [ ! -e "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-sub" ]
assert [ -e "$INSTRUCTION_WATCH_STATE/inflight/sid-st@tu-main" ]
rm -f "$INSTRUCTION_WATCH_STATE"/inflight/*
rm -rf "$INSTRUCTION_WATCH_STATE/closed"

# The harness reads the FIRST journal line and the ranked cache; the tests above
# trimmed both. Leave a fresh collector record and the project file it lists.
printf 'project rules\n' > "$PROJ/CLAUDE.md"
printf '#1\n%s\n' "$PROJ/CLAUDE.md" > "$RANKED"
printf 'pre-hs\n' > "$DOC"
span_base sid-hs >/dev/null
pre_call sid-hs Bash command "$ANY_CALL" "$NOSPAN_T"
printf 'pre-hs and a line the harness will read\n' > "$DOC"
raw_check sid-hs Bash command "$ANY_CALL" "$NOSPAN_T" >/dev/null
tail -1 "$J" > "$J.one" && mv "$J.one" "$J"

echo "== Hammerspoon: the record the collector just wrote travels to the menu and the receipt"
hs_bounded() {
  python3 - "$@" <<'HSPY'
import subprocess
import sys

try:
    # The menu harness alone takes ~11s. -q: another client's print() lines otherwise reach this one.
    result = subprocess.run(["/usr/bin/lockf", "-k", "-t", "600", "/tmp/hs-cli.lock", "hs", "-q", "-t", "120", *sys.argv[1:]], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=730)
except (FileNotFoundError, subprocess.TimeoutExpired):
    raise SystemExit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
HSPY
}
assert [ -s "$INSTRUCTION_WATCH_STATE/events.jsonl" ]
WH="$WORK/watcher"
mkdir -p "$WH/home/.claude/docs" "$WH/repo" "$WH/state"
printf 'watched doc\n' > "$WH/home/.claude/docs/x.md"
printf '{"model":"opus","hooks":{}}\n' > "$WH/home/.claude/settings.json"
printf 'repo rules\n' > "$WH/repo/CLAUDE.md"
printf '#1\n%s\n' "$WH/repo/CLAUDE.md" > "$WH/state/ranked.txt"
if command -v hs >/dev/null 2>&1 && [ "$(hs_bounded -c 'return "ok"' 2>/dev/null)" = ok ]; then
  # Isolate require and globals: the harness otherwise replaces the live module and starts it.
  menu_lua=$(cat <<LUA
local env = setmetatable({}, { __index = _G })
env._G = { INSTRUCTION_WATCH_FIXTURE = [[$INSTRUCTION_WATCH_STATE]], INSTRUCTION_WATCHER_FIXTURE = {
    home = [[$WH/home]], state = [[$WH/state]], repo = [[$WH/repo]], watch = [[$WATCH]], gate = [[$WRITE_GATE]], path = [[$PATH]] } }
env.package = { path = package.path, loaded = {} }
env.os = setmetatable({ getenv = function(key)
    if key == "HOME" then return [[$HOME]] end
    if key == "INSTRUCTION_WATCH_STATE" then return [[$INSTRUCTION_WATCH_STATE]] end
    return os.getenv(key)
end }, { __index = os })
local inert = function() return { start = function() end, stop = function() end } end
env.hs = setmetatable({
    pathwatcher = { new = inert }, timer = { doEvery = inert },
    alert = { show = function() error("unexpected real alert attempt") end },
}, { __index = hs })
env.require = function(name)
    if name == "menu-style" then return assert(loadfile([[$ROOT/hammerspoon/menu-style.lua]], "t", env))() end
    assert(name == "instruction-watch", "unexpected module: " .. name)
    local module = assert(loadfile([[$ROOT/hammerspoon/instruction-watch.lua]], "t", env))()
    env.package.loaded[name] = module
    return module
end
env.dofile = function(path) return assert(loadfile(path, "t", env))() end
return env.dofile([[$ROOT/tests/instruction_watch_menu_harness.lua]])
LUA
)
  menu_out=$(hs_bounded -c "$menu_lua" 2>/dev/null) \
    || fail "the Hammerspoon menu harness threw"
  assert_eq "PASS: instruction-watch menu contract" "$(printf '%s\n' "$menu_out" | grep -v '^-- Loading extension: ')"
else
  echo "   (skipped: Hammerspoon is not reachable from this shell)"
fi

# The menubar's synchronous scan read always ends: the guard kills the scan's whole process group,
# a pipeline subshell still holding the pipe included, and the scan runs with a locale in its
# environment so bash never asks CoreFoundation for one.
scan_guard=$(awk '/^local SCAN_GUARD = \[\[/ { on = 1; sub(/^local SCAN_GUARD = \[\[/, "") } on { print } /\]\]$/ && on { exit }' \
  "$ROOT/hammerspoon/instruction-watch.lua" | sed '$ s/\]\]$//')
assert_eq "out rc=3" "$(/usr/bin/perl -e "$scan_guard" 5 bash -c 'printf out; exit 3'; echo " rc=$?")"
SECONDS=0
guard_out=$(/usr/bin/perl -e "$scan_guard" 1 bash -c 'echo early; sleep 60 | cat; echo late'; echo "rc=$?")
assert test "$SECONDS" -lt 5
assert_eq "early rc=124" "$(printf '%s' "$guard_out" | tr '\n' ' ')"
assert grep -q '"PATH=" .. WATCH_PATH .. ":$PATH; export PATH; LC_ALL=C; export LC_ALL; exec /usr/bin/perl -e",' \
  "$ROOT/hammerspoon/instruction-watch.lua"

# The watcher claims through the tripwire's own watch_claim: the same bytes under a new mtime are
# not journaled again, other bytes are.
watch_script=$(awk '/^local WATCH_SCRIPT = \[==\[/ { on = 1; next } /^\]==\]/ { exit } on { print }' \
  "$ROOT/hammerspoon/instruction-watch.lua")
claim_state="$WORK/claim-state"
claim() { bash -c "$watch_script" _ "$ROOT" "$HOME" "$claim_state" claim "$HOME/.claude/docs/x.md" "$1" 0; }
h1=$(printf a | shasum -a 256 | cut -c1-64); h2=$(printf b | shasum -a 256 | cut -c1-64)
assert_contains w "$(claim "$h1@1.5")"
assert_eq - "$(claim "$h1@2.5")"
assert_contains w "$(claim "$h2@3.5")"
assert_contains w "$(claim "$h1@4.5")"

echo "OK ($asserts assertions)"
