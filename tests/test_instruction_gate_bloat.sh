#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/instruction_gate_harness.sh"

echo "== bloat gate: the measured multipliers reach the message"
msg=$(bloat "$CLAUDE_MD" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~15,000 times a month" "$msg"
assert_contains "tokens/week and " "$msg"
# The audit is the cheapest way out of the denial, so it stands first and is named as a step.
assert_contains "Protocol, fastest path first" "$msg"
assert_contains "(1) AUDIT" "$msg"

echo "== bloat gate: every name the global file answers to is the global file"
# Each profile directory carries its own symlink to it, and those spellings were being priced
# as a project file at a fifth of the real cost.
profile_link
msg=$(bloat "$HOME/.claude-profiles/com/CLAUDE.md" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~15,000 times a month" "$msg"
msg=$(bloat "$REAL_MD" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~15,000 times a month" "$msg"

echo "== bloat gate: a project file rides in one project's sessions, not in all of them"
# The global rate quoted for a project CLAUDE.md or memory index overstated it by five times.
msg=$(bloat "$REPO/CLAUDE.md" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~3,000 times a month" "$msg"
msg=$(bloat "$WORK/memory/MEMORY.md" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~3,000 times a month" "$msg"

echo "== bloat gate: the repo path behind the symlinked directory is the same file"
# ~/.claude/docs and ~/.claude/agents are symlinks into the config repository, and the repo
# path is the one anybody editing the repo actually types.
docs_link
assert_eq deny "$(bloat_decision "$HOME/.claude/docs/review-tiers.md")"
assert_eq deny "$(bloat_decision "$REPO_DOCS/review-tiers.md")"
assert_eq deny "$(bloat_decision "$REPO_DOCS/not-created-yet.md")"
# A Write may be creating the directory as well as the file, and a new subdirectory of docs/
# is still docs/.
assert_eq deny "$(bloat_decision "$REPO_DOCS/new-topic/doc.md")"
assert_eq pass "$(bloat_decision "$WORK/ordinary.md")"
assert_eq pass "$(bloat_decision "$WORK/no-such-dir/ordinary.md")"

echo "== bloat gate: one deny, then the identical edit passes"
rm -rf "$BLOAT_STAMPS"
assert_eq deny "$(bloat_decision "$CLAUDE_MD")"
fresh_stamps "$BLOAT_STAMPS"
assert_eq deny "$(bloat_decision "$CLAUDE_MD")"
age_stamps "$BLOAT_STAMPS"
assert_eq pass "$(bloat_decision "$CLAUDE_MD")"
assert_eq deny "$(bloat_decision "$CLAUDE_MD")"

echo "== bloat gate: another session does not inherit this one's approval"
rm -rf "$BLOAT_STAMPS"
bloat_sid() {
  local out
  out=$(jq -cn --arg p "$CLAUDE_MD" --arg n "$big" --arg s "$1" \
          '{tool_name:"Edit",cwd:"/tmp",session_id:$s,tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
        | bash "$BLOAT")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
assert_eq deny "$(bloat_sid session-one)"
age_stamps "$BLOAT_STAMPS"
assert_eq deny "$(bloat_sid session-two)"
assert_eq pass "$(bloat_sid session-one)"

echo "== bloat gate: an unusable stamp cache denies rather than waving the growth through"
assert_eq deny "$(INSTRUCTION_BLOAT_GATE_STAMPS=/dev/null/nope bloat_decision "$CLAUDE_MD")"

echo "== bloat gate: growth under the threshold is nobody's business"
small=$(jq -cn --arg p "$CLAUDE_MD" \
  '{tool_name:"Edit",cwd:"/tmp",tool_input:{file_path:$p,old_string:"x",new_string:"xy"}}' \
  | bash "$BLOAT")
assert_eq "" "$small"

echo "== bloat gate: the retry has to follow a re-read of the file"
# The denial asks for an audit of the whole file and the stamp is what makes the retry pass, so
# the transcript past the denial is what says the audit happened.
RETRY_STAMPS="$HOME/.cache/bloat-retry"
TRANSCRIPT="$WORK/transcript.jsonl"
: > "$TRANSCRIPT"
append_read() {
  jq -cn --arg p "$1" '{type:"assistant",timestamp:"2026-08-06T12:00:00Z",
    message:{role:"assistant",content:[{type:"tool_use",name:"Read",input:{file_path:$p}}]}}' \
    >> "$TRANSCRIPT"
}
append_ranged_read() {
  jq -cn --arg p "$1" '{type:"assistant",timestamp:"2026-08-06T12:00:00Z",
    message:{role:"assistant",content:[{type:"tool_use",name:"Read",
      input:{file_path:$p,offset:1,limit:20}}]}}' >> "$TRANSCRIPT"
}
# $4 is the transcript path, empty for a payload that carries no such field at all.
retry_payload() {
  jq -cn --arg p "$1" --arg n "$big" --arg s "$2" --arg tool "$3" --arg t "$4" '
    {tool_name:$tool, cwd:"/tmp", session_id:$s,
     tool_input: (if $tool == "Write" then {file_path:$p, content:$n}
                  else {file_path:$p, old_string:"x", new_string:$n} end)}
    + (if $t == "" then {} else {transcript_path:$t} end)'
}
retry_bloat() {
  local out rc
  out=$(retry_payload "$@" | INSTRUCTION_BLOAT_GATE_STAMPS="$RETRY_STAMPS" bash "$BLOAT")
  rc=$?
  [ ! -f "$4" ] || harness_deny "$4" "$out" "$3"
  [ -z "$out" ] || printf '%s\n' "$out"
  return "$rc"
}
retry_decision() {
  local out
  out=$(retry_bloat "$@")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
retry_reason() {
  retry_bloat "$@" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}
count_in() { find "$RETRY_STAMPS" -mindepth 1 -maxdepth 1 "$@" | wc -l | tr -d '[:space:]'; }

rm -rf "$RETRY_STAMPS"
# A read from before the denial is not the audit it asked for.
append_read "$CLAUDE_MD"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-one Edit "$TRANSCRIPT")"
age_stamps "$RETRY_STAMPS"
assert_contains "Gate retry requires re-reading" "$(retry_reason "$CLAUDE_MD" retry-one Edit "$TRANSCRIPT")"
# The refused retry must not spend the stamp the real retry is still waiting for.
assert_eq 1 "$(count_in -type d)"
append_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-one Edit "$TRANSCRIPT")"
# The stamp and the note it was denied with are both gone, so the next identical edit starts over.
assert_eq 0 "$(count_in)"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-one Edit "$TRANSCRIPT")"

echo "== bloat gate: a planted retry stamp is refused and recorded, not honoured"
FORGE="$WORK/learn-bloat"
retry_payload "$CLAUDE_MD" forge-one Edit "$TRANSCRIPT" \
  | INSTRUCTION_BLOAT_GATE_STAMPS="$FORGE/stamps" INSTRUCTION_WATCH_STATE="$FORGE/state" \
    bash "$BLOAT" >/dev/null 2>&1
hb=$(find "$FORGE/stamps" -mindepth 1 -maxdepth 1 -type d)
mkdir -p "$RETRY_STAMPS/${hb##*/}"
age_stamps "$RETRY_STAMPS"
append_read "$CLAUDE_MD"
out=$(retry_bloat "$CLAUDE_MD" forge-one Edit "$TRANSCRIPT" 2>&1; echo "rc=$?")
assert_contains "rc=2" "$out"
assert_eq forge-one "$(grep '"kind":"stamp-forged"' "$INSTRUCTION_WATCH_STATE/events.jsonl" | tail -1 | jq -r .sid)"
assert_eq deny "$(retry_decision "$CLAUDE_MD" forge-one Edit "$TRANSCRIPT")"

echo "== bloat gate: the read counts under either spelling of the file"
# ~/.claude/CLAUDE.md is a symlink into a config repository: the edit lands on one name and the
# read is as likely to carry the other.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$REAL_MD" retry-link Edit "$TRANSCRIPT")"
append_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$REAL_MD" retry-link Edit "$TRANSCRIPT")"
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-link-back Edit "$TRANSCRIPT")"
append_read "$REAL_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-link-back Edit "$TRANSCRIPT")"
# Reading a different file is not reading this one.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-other Edit "$TRANSCRIPT")"
append_read "$REPO_DOCS/review-tiers.md"
age_stamps "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-other Edit "$TRANSCRIPT")"

echo "== bloat gate: the tool's own spelling of the path is the one recorded"
# Read takes a tilde path and the transcript keeps it unexpanded, while realpath resolves it
# against the working directory: a real re-read was being thrown away.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-tilde Edit "$TRANSCRIPT")"
append_read '~/.claude/CLAUDE.md'
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-tilde Edit "$TRANSCRIPT")"

echo "== bloat gate: a ranged read is not the audit the denial asked for"
# The denial promises the check is mechanical, and the protocol asks for the WHOLE file; a read
# carrying an offset or a limit is recorded exactly like a full one.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-ranged Edit "$TRANSCRIPT")"
append_ranged_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-ranged Edit "$TRANSCRIPT")"
append_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-ranged Edit "$TRANSCRIPT")"

echo "== bloat gate: a file that does not exist yet has nothing to re-read"
rm -rf "$RETRY_STAMPS"
NEWDOC="$REPO_DOCS/retry-new.md"
assert_eq deny "$(retry_decision "$NEWDOC" retry-new Write "$TRANSCRIPT")"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$NEWDOC" retry-new Write "$TRANSCRIPT")"

echo "== bloat gate: a transcript it cannot read leaves the retry working"
# The gate does not own the transcript; a payload without one, or one naming a file that is not
# there, must behave exactly as it did before the read was ever required.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-blind Edit "")"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-blind Edit "")"
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-gone Edit "$WORK/no-such-transcript.jsonl")"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-gone Edit "$WORK/no-such-transcript.jsonl")"
# A transcript carrying lines that are not JSON at all is still readable for the ones that are.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-junk Edit "$TRANSCRIPT")"
printf 'not json at all\n' >> "$TRANSCRIPT"
append_read "$CLAUDE_MD"
printf '{"type":"user"}\n' >> "$TRANSCRIPT"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-junk Edit "$TRANSCRIPT")"

echo "== bloat gate: a transcript that shrank took the evidence with it"
# Truncated or rotated under the same name: the tail past the remembered byte is empty from then
# on, which would deny the retry forever instead of once.
rm -rf "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-cut Edit "$TRANSCRIPT")"
: > "$TRANSCRIPT"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-cut Edit "$TRANSCRIPT")"

echo "== bloat gate: each denial moves the byte the audit has to beat"
# The stamp is swept after a day and the note beside it is not: a note left from an old cycle
# would let a read from that cycle answer a denial issued today.
rm -rf "$RETRY_STAMPS"
append_read "$CLAUDE_MD"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-fresh Edit "$TRANSCRIPT")"
find "$RETRY_STAMPS" -mindepth 1 -maxdepth 1 -type d -exec rmdir {} + 2>/dev/null
assert_eq 1 "$(count_in -name '*.read')"
append_read "$CLAUDE_MD"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-fresh Edit "$TRANSCRIPT")"
age_stamps "$RETRY_STAMPS"
assert_eq deny "$(retry_decision "$CLAUDE_MD" retry-fresh Edit "$TRANSCRIPT")"
append_read "$CLAUDE_MD"
age_stamps "$RETRY_STAMPS"
assert_eq pass "$(retry_decision "$CLAUDE_MD" retry-fresh Edit "$TRANSCRIPT")"

echo "== note sweep: an aged note goes, a file that only borrowed its name stays"
# The stamp directory is env-overridable and a misconfigured one is somebody's real data, so the
# name alone is never enough of a reason to delete a file.
NOTE_SWEEP="$WORK/note-sweep"
mkdir -p "$NOTE_SWEEP"
printf '42\n%s\n' "$TRANSCRIPT" > "$NOTE_SWEEP/0123456789abcdef.read"
printf 'somebody real data\n' > "$NOTE_SWEEP/abcdef0123456789.read"
printf '42\nnot-an-absolute-path\n' > "$NOTE_SWEEP/deadbeefdeadbeef.read"
printf '42\n%s\nand a third line\n' "$TRANSCRIPT" > "$NOTE_SWEEP/feedfacefeedface.read"
touch -A -250000 "$NOTE_SWEEP"/*.read
# A note of the right shape that has not aged out belongs to a denial still waiting for its retry.
printf '42\n%s\n' "$TRANSCRIPT" > "$NOTE_SWEEP/8899aabbccddeeff.read"
assert_contains 'permissionDecision":"deny' \
  "$(retry_payload "$CLAUDE_MD" note-sweep Edit "$TRANSCRIPT" \
     | INSTRUCTION_BLOAT_GATE_STAMPS="$NOTE_SWEEP" bash "$BLOAT")"
assert [ ! -f "$NOTE_SWEEP/0123456789abcdef.read" ]
assert [ -f "$NOTE_SWEEP/abcdef0123456789.read" ]
assert [ -f "$NOTE_SWEEP/deadbeefdeadbeef.read" ]
assert [ -f "$NOTE_SWEEP/feedfacefeedface.read" ]
assert [ -f "$NOTE_SWEEP/8899aabbccddeeff.read" ]

echo "== bloat gate: the live rate from the local index is quoted instead of the frozen constant"
# The constants are one measured month that ages out; tokenmap exports what the last 30 days
# actually cost. The rate has to reach the arithmetic too, not only the prose, so the monthly
# figure is checked against the live number rather than against 15682.
RATES="$WORK/rates/read-rates.json"
MEM_SLUG="-Volumes-Work-Projects-token-map"
MEM_DIR="$WORK/profiles/com/projects/$MEM_SLUG/memory"
mkdir -p "$WORK/rates" "$WORK/liveproj" "$WORK/livereal" "$MEM_DIR"
export TOKENMAP_RATES="$RATES"
# The second project is keyed by the RESOLVED directory only: mktemp hands out the /var spelling
# and the export carries whichever one the sessions ran in.
LIVE_REAL=$(realpath "$WORK/livereal")
# BSD date on the machine this runs on, GNU date wherever the suite is run in CI or a container.
stamp_ago() {
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ
}
stamp_ahead() {
  date -u -v+"$1"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "+$1 hours" +%Y-%m-%dT%H:%M:%SZ
}
write_rates() {
  # $gdir is a decoy: the global file's own repo directory measured as a project. Identity has
  # to outrank spelling, or the write gate quotes 500 for the file both gates price at 20111.
  jq -n --arg gen "$1" --arg dir "$WORK/liveproj" --arg real "$LIVE_REAL" \
        --arg gdir "$REPO/global" --arg mem /Volumes/Work/Projects/token-map '{
    generated_at: $gen, window_days: 30,
    global: {reads: 20111.0, requests: 130000, sessions: 1900},
    projects: {
      ($dir): {reads: 812.4, requests: 8000, sessions: 60},
      ($real): {reads: 407.0, requests: 4000, sessions: 30},
      ($gdir): {reads: 500.0, requests: 4600, sessions: 32},
      ($mem): {reads: 641.0, requests: 6000, sessions: 44},
      ($mem + "/sub"): {reads: 400.0, requests: 3800, sessions: 28},
      ($mem + "-other"): {reads: 9000.0, requests: 80000, sessions: 600},
      "/tmp/tiny-project": {reads: 0.4, requests: 4, sessions: 1}
    }
  }' > "$RATES"
}
# Each pricing here carries a session of its own: the same file priced twice with the same payload
# would be spending its own retry the second time and pass, quoting nothing.
price_bloat() {
  jq -cn --arg p "$2" --arg n "$big" --arg s "live-$1" \
    '{tool_name:"Edit",cwd:"/tmp",session_id:$s,tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
    | bash "$BLOAT" | jq -r '.hookSpecificOutput.permissionDecisionReason'
}
FROZEN_WORDING="times a month — every token added is paid for that many times over (measured)."
LIVE_WORDING="measured by the local read index over its last 30-day window"
# 3.2 bytes per token, rounded the way jq rounds it rather than truncated.
live_tokens=$(( ((${#big} - 1) * 10 + 16) / 32 ))
write_rates "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
msg=$(price_bloat global-fresh "$CLAUDE_MD")
assert_contains "~20,000 times a month" "$msg"
assert_contains "$LIVE_WORDING" "$msg"
# The cost is the product of the two figures printed beside it, not of the measurement behind them:
# the message orders its reader to quote all three to Egor, so 125 tokens at the ~20,000 re-reads
# it shows has to come to the 2.5M it shows, and never to the 2,513,875 the raw 20,111 would give.
assert_eq 125 "$live_tokens"
assert_contains "~2.5M/month" "$msg"
# Every name the global file answers to resolves to the one the export keys it by.
assert_contains "~20,000 times a month" "$(price_bloat global-profile "$HOME/.claude-profiles/com/CLAUDE.md")"
assert_contains "~20,000 times a month" "$(price_bloat global-repo "$REAL_MD")"

echo "== bloat gate: a project the index measured is priced at that project's own rate"
assert_contains "~700 times a month" "$(price_bloat proj-literal "$WORK/liveproj/CLAUDE.md")"
assert_contains "~700 times a month" "$(price_bloat proj-local "$WORK/liveproj/CLAUDE.local.md")"
assert_contains "~500 times a month" "$(price_bloat proj-resolved "$WORK/livereal/CLAUDE.md")"
# A project nobody measured is not free, it is the class rate — and so is a memory index filed
# under a directory the export does not carry.
msg=$(price_bloat proj-unmeasured "$WORK/unmeasured/CLAUDE.md")
assert_contains "~3,000 times a month" "$msg"
assert_contains "$FROZEN_WORDING" "$msg"
assert_contains "~3,000 times a month" "$(price_bloat proj-memory "$WORK/liveproj/memory/MEMORY.md")"
# A project rate is the price of the instruction files that ride in that project's sessions, not
# of every file that shares their directory. Left unrestricted it priced ~/.claude/settings.json
# at the rate measured from its neighbours and denied it, quoting a re-read that never happens.
printf '{}\n' > "$WORK/liveproj/settings.json"
assert_eq pass "$(bloat_decision "$WORK/liveproj/settings.json")"
printf 'x\n' > "$WORK/liveproj/notes.txt"
assert_eq pass "$(bloat_decision "$WORK/liveproj/notes.txt")"

echo "== bloat gate: a memory index is priced by the project its path encodes"
# The index never sits in the directory tokenmap recorded — its parent is the memory/ subdirectory
# of a per-project transcript directory, whose name is the cwd with the non-alphanumerics dashed.
# The slug encodes a directory, and the sessions that read the index are the ones at or below it.
# Compared as encoded STRINGS the two are indistinguishable — /x/repo-other encodes exactly as
# /x/repo/other does — so a prefix test handed a busy neighbour the rate of this index.
# 641 for the root and 400 for the subdirectory come to the ~1,000 shown; the 9,000-read
# neighbour would carry it to ~10,000 the moment it were counted.
msg=$(price_bloat mem-slug "$MEM_DIR/MEMORY.md")
assert_contains "~1,000 times a month" "$msg"
assert_contains "$LIVE_WORDING" "$msg"
# A slug the export never measured is the class rate, not a match on a neighbouring project.
assert_contains "~3,000 times a month" \
  "$(price_bloat mem-unknown "$WORK/profiles/com/projects/-nowhere-at-all/memory/MEMORY.md")"

echo "== bloat gate: a memory file is priced by its class, whatever the index says"
# The recall that loads one names no path, so the index sees only the times it was opened by hand.
# Preferring that measurement — as every other class rightly does — prices a memory nobody opened
# all month as free, which is exactly the file the class constant exists to hold down.
mem_file="$MEM_DIR/one-fact.md"
printf -- '---\nmetadata:\n  pinned: true\n---\na fact\n' > "$mem_file"
assert_contains "~150 times a month" "$(price_bloat mem-file "$mem_file")"
measured_memory() {
  jq --arg p "$1" '.paths.entries[$p] = {mode: "on_demand",
    monthly: {reads: 3.6, limit_units: 3.6}, weekly: {reads: 0.8, limit_units: 0.8}}' \
    "$RATES" > "$RATES.tmp" && mv "$RATES.tmp" "$RATES"
}
measured_memory "$mem_file"
assert_contains "~150 times a month" "$(price_bloat mem-file-measured "$mem_file")"
write_rates "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The index of the set is not one of its entries: MEMORY.md is measured with the project it belongs
# to, and blinding it would throw away the one memory-shaped file the export does see.
assert_contains "~1,000 times a month" "$(price_bloat mem-index-still-live "$MEM_DIR/MEMORY.md")"

echo "== bloat gate: an unpinned memory entry is loaded only on recall, so its size is not gated"
unpinned="$MEM_DIR/recalled.md"
printf -- '---\nmetadata:\n  pinned: false\n---\na fact\n' > "$unpinned"
assert_eq pass "$(bloat_decision "$unpinned")"
new_entry=$(jq -cn --arg p "$MEM_DIR/brand-new.md" --arg n "$big" \
  '{tool_name:"Write",cwd:"/tmp",tool_input:{file_path:$p,content:$n}}' | bash "$BLOAT")
assert_eq "" "$new_entry"
# Pinning is what puts an entry in every session, so an edit that turns the pin on is priced.
pin_edit=$(jq -cn --arg p "$unpinned" --arg n "  pinned: true
$big" '{tool_name:"Edit",cwd:"/tmp",session_id:"pin-on",tool_input:{file_path:$p,old_string:"  pinned: false",new_string:$n}}' \
  | bash "$BLOAT" | jq -r '.hookSpecificOutput.permissionDecision // "pass"')
assert_eq deny "$pin_edit"
# Every YAML spelling of a true pin is a pin.
for pin_spelling in '  pinned: True' '  pinned: yes' '  pinned: "true"' "  pinned: 'on'" 'metadata: {pinned: true}' 'metadata: {"pinned": true}'; do
  pin_edit=$(jq -cn --arg p "$unpinned" --arg n "$pin_spelling
$big" '{tool_name:"Edit",cwd:"/tmp",session_id:"pin-on",tool_input:{file_path:$p,old_string:"  pinned: false",new_string:$n}}' \
    | bash "$BLOAT" | jq -r '.hookSpecificOutput.permissionDecision // "pass"')
  assert_eq deny "$pin_edit"
done

echo "== bloat gate: a slash command is a guarded class like the skill it sits beside"
CMD_DIR="$HOME/.claude/commands"
mkdir -p "$CMD_DIR"
printf 'do the thing\n' > "$CMD_DIR/spawn.md"
assert_contains "~100 times a month" "$(price_bloat command-file "$CMD_DIR/spawn.md")"

echo "== bloat gate: a rate under one read a month is not a free file"
# round() would print 0, and "~0 times a month" reads as permission rather than as a small cost.
msg=$(price_bloat tiny /tmp/tiny-project/CLAUDE.md)
assert_contains "~1 time a month" "$msg"
assert_contains "$LIVE_WORDING" "$msg"

echo "== bloat gate: a stamp from the future is a broken clock, not a fresher measurement"
write_rates "$(stamp_ahead 6)"
msg=$(price_bloat future "$CLAUDE_MD")
assert_contains "~15,000 times a month" "$msg"
assert_contains "$FROZEN_WORDING" "$msg"
# Skew of a couple of minutes is not that, and must not throw the reading away.
write_rates "$(stamp_ahead 0)"
assert_contains "~20,000 times a month" "$(price_bloat no-skew "$CLAUDE_MD")"

echo "== bloat gate: the two benign producer drifts still parse"
# fromdateiso8601 accepts one spelling; a fractional second or a +00:00 offset must degrade to the
# same reading rather than to a silent fallback nobody would notice.
jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%S.123456Z)" \
  '{generated_at:$gen,window_days:30,global:{reads:20111.0}}' > "$RATES"
assert_contains "~20,000 times a month" "$(price_bloat frac-seconds "$CLAUDE_MD")"
jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
  '{generated_at:$gen,window_days:30,global:{reads:20111.0}}' > "$RATES"
assert_contains "~20,000 times a month" "$(price_bloat utc-offset "$CLAUDE_MD")"

echo "== bloat gate: an export past its window is not a number anybody can reproduce"
write_rates "$(stamp_ago 20)"
msg=$(price_bloat stale "$CLAUDE_MD")
assert_contains "~15,000 times a month" "$msg"
assert_contains "$FROZEN_WORDING" "$msg"
assert_contains "~3,000 times a month" "$(price_bloat stale-proj "$WORK/liveproj/CLAUDE.md")"
# Just inside the window still counts.
write_rates "$(stamp_ago 13)"
assert_contains "~20,000 times a month" "$(price_bloat nearly-stale "$CLAUDE_MD")"

echo "== bloat gate: an export it cannot read leaves the constants standing"
rm -f "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat no-file "$CLAUDE_MD")"
printf 'not json at all\n' > "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat malformed "$CLAUDE_MD")"
printf '{"projects":{}}\n' > "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat no-timestamp "$CLAUDE_MD")"
jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{generated_at:$gen,projects:{}}' > "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat no-global-key "$CLAUDE_MD")"
jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{generated_at:$gen,global:{reads:"lots"}}' > "$RATES"
assert_contains "~15,000 times a month" "$(price_bloat unusable-rate "$CLAUDE_MD")"

echo "== bloat gate: the classes the export does not cover keep their own constants"
# docs, agents, skills and instructions are not in the export yet, and a live lookup that answers
# nothing for them must fall back rather than stop pricing them.
write_rates "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
msg=$(price_bloat class-docs "$HOME/.claude/docs/review-tiers.md")
assert_contains "~150 times a month" "$msg"
assert_contains "$FROZEN_WORDING" "$msg"
assert_contains "~3,000 times a month" "$(price_bloat class-agents "$HOME/.claude/agents/codex-worker.md")"
assert_contains "~100 times a month" "$(price_bloat class-skills "$HOME/.claude/skills/demo/SKILL.md")"
assert_eq pass "$(bloat_decision "$WORK/ordinary.md")"

echo "== write gate: the denial quotes the same live figure the bloat gate does"
# Two gates quoting different numbers for one file is what teaches a reader that neither is real.
assert_contains "~5,000 times a week, ~20,000 times a month" "$(price live-a "$CLAUDE_MD")"
assert_contains "~5,000 times a week, ~20,000 times a month" "$(price live-b "$REAL_MD")"
assert_contains "~200 times a week, ~700 times a month" "$(price live-c "$WORK/liveproj/CLAUDE.md")"
# A class the export does not carry, and a project it never measured, keep the constant.
assert_contains "~30 times a week, ~150 times a month" "$(price live-d "$HOME/.claude/docs/review-tiers.md")"
assert_contains "~700 times a week, ~3,000 times a month" "$(price live-e "$WORK/unmeasured/CLAUDE.md")"

echo "== bloat gate: current path rates price every Markdown file in weekly terms"
README="$WORK/liveproj/README.md"
CHEAP_MD="$WORK/liveproj/cheap.md"
ABSENT_MD="$WORK/liveproj/absent.md"
PROJECT_MEMORY="$WORK/liveproj/MEMORY.md"
printf 'readme\n' > "$README"
printf 'cheap\n' > "$CHEAP_MD"
printf 'memory\n' > "$PROJECT_MEMORY"
write_current_rates() {
  jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg global "$CLAUDE_MD" \
    --arg project "$WORK/liveproj" --arg readme "$README" --arg cheap "$CHEAP_MD" \
    --arg memory "$PROJECT_MEMORY" --arg project_claude "$WORK/liveproj/CLAUDE.md" '{
    generated_at: $gen, window_days: 30,
    global: {reads: 20111.0, limit_units: 9800.0, requests: 130000, contexts: 1900},
    projects: {($project): {reads: 812.4, limit_units: 400.0, requests: 8000, contexts: 60}},
    weekly: {window_days: 7, basis_days: 30,
      global: {reads: 6176.0, limit_units: 3000.0, requests: 40000, contexts: 600},
      projects: {($project): {reads: 302.0, limit_units: 150.0, requests: 2000, contexts: 20}}},
    paths: {
      criteria: {extensions: [".md", ".markdown"], min_monthly_reads: 1.0, limit: 500},
      entries: {
        ($global): {mode: "always",
          monthly: {reads: 20111.0, limit_units: 9800.0},
          weekly: {reads: 6176.0, limit_units: 3000.0}},
        ($readme): {mode: "on-demand",
          monthly: {reads: 4000.0, limit_units: 2000.0},
          weekly: {reads: 1000.0, limit_units: 500.0}},
        ($cheap): {mode: "on-demand",
          monthly: {reads: 3.0, limit_units: 2.0},
          weekly: {reads: 2.0, limit_units: 1.0}},
        ($memory): {mode: "always",
          monthly: {reads: 812.4, limit_units: 400.0},
          weekly: {reads: 302.0, limit_units: 150.0}},
        ($project_claude): {mode: "always",
          monthly: {reads: 812.4, limit_units: 400.0},
          weekly: {reads: 302.0, limit_units: 150.0}}
      }
    }
  }' > "$RATES"
}
growth_output() {
  jq -cn --arg p "$1" --arg n "$2" --arg s "$3" \
    '{tool_name:"Edit",cwd:"/tmp",session_id:$s,
      tool_input:{file_path:$p,old_string:"x",new_string:$n}}' | bash "$BLOAT"
}
growth_decision() {
  local out
  out=$(growth_output "$@")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"'
}
write_current_rates
readme_growth=$(python3 -c 'print("r" * 800)')
msg=$(growth_output "$README" "$readme_growth" path-readme \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')
# The limit-unit figure, not the dollar-priced `reads` beside it in the same entry: the gate
# guards the weekly usage limit, and that counter charges cache reads at about nothing.
assert_contains "~500 times a week" "$msg"
assert_contains "~2,000 times a month" "$msg"
assert_contains "tokens/week" "$msg"
assert_contains "tokenmap reads $README" "$msg"
memory_growth=$(python3 -c 'print("m" * 3000)')
msg=$(growth_output "$PROJECT_MEMORY" "$memory_growth" path-memory \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "~150 times a week" "$msg"
assert_contains "~500 times a month" "$msg"

echo "== number formatting: the figures are readable before they are anything else"
# Seven bare digits are read wrong more often than right, and these numbers exist to be acted on.
assert_eq "63"     "$(fmt instruction_format_tokens 63)"
assert_eq "1.5k"   "$(fmt instruction_format_tokens 1500)"
assert_eq "150k"   "$(fmt instruction_format_tokens 150000)"
assert_eq "2.5M"   "$(fmt instruction_format_tokens 2513875)"
assert_eq "12M"    "$(fmt instruction_format_tokens 12000000)"
assert_eq "515"    "$(fmt instruction_format_count 515)"
assert_eq "2,000"  "$(fmt instruction_format_count 2000)"
assert_eq "1,000,000" "$(fmt instruction_format_count 1000000)"
assert_eq "1.5"    "$(fmt instruction_format_count 1.5)"
assert_eq "1 time" "$(fmt instruction_times 1)"
assert_eq "20 times" "$(fmt instruction_times 20)"

echo "== bloat gate: a rate that drifts does not move the number Egor reads"
# The point of the ladder. Egor decides whether a file may grow from this figure, and a decision
# he cannot repeat tomorrow is no decision; the export's window slides every night, so the quoted
# price has to survive that drift without moving. It still moves when the rate really changes.
drifted_rates() {
  jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg readme "$README" --argjson w "$1" '{
    generated_at: $gen, window_days: 30,
    global: {reads: 20111.0, limit_units: 9800.0, requests: 130000, contexts: 1900},
    projects: {},
    paths: {
      criteria: {extensions: [".md", ".markdown"], min_monthly_reads: 1.0, limit: 500},
      entries: {($readme): {mode: "on-demand",
        monthly: {reads: ($w * 8), limit_units: ($w * 4)},
        weekly: {reads: ($w * 2), limit_units: $w}}}
    }
  }' > "$RATES"
}
drift_quote() {
  drifted_rates "$1"
  growth_output "$README" "$readme_growth" "drift-$1" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason' \
    | grep -o '~[0-9,.]* times\? a week'
}
assert_eq "~500 times a week" "$(drift_quote 460)"
assert_eq "~500 times a week" "$(drift_quote 540)"
assert_eq "~700 times a week" "$(drift_quote 720)"
write_current_rates

echo "== bloat gate: the weekly budget makes cheap files more permissive"
cheap_growth=$(python3 -c 'print("c" * 10000)')
assert_eq pass "$(growth_decision "$CHEAP_MD" "$cheap_growth" threshold-cheap)"

echo "== bloat gate: the weekly threshold is never stricter than 120 bytes"
exactly_120=$(python3 -c 'print("g" * 121)')
over_120=$(python3 -c 'print("g" * 122)')
assert_eq pass "$(growth_decision "$CLAUDE_MD" "$exactly_120" clamp-pass)"
assert_eq deny "$(growth_decision "$CLAUDE_MD" "$over_120" clamp-deny)"

echo "== bloat gate: a Markdown file the export proves cheap passes without a word"
# A note that says "not gated" changes nothing the model does, and it rode on every scratch file.
assert_eq "" "$(growth_output "$ABSENT_MD" "$cheap_growth" absent-fresh)"
assert_eq "" "$(growth_output "$WORK/liveproj/absent-two.md" "$cheap_growth" absent-fresh)"
assert_eq "" "$(growth_output "$ABSENT_MD" "$cheap_growth" absent-other-session)"
unavailable=$(jq -cn --arg p "$WORK/liveproj/unavailable.md" --arg n "$cheap_growth" \
  '{tool_name:"Edit",cwd:"/tmp",session_id:"absent-unavailable",
    tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
  | INSTRUCTION_BLOAT_GATE_STAMPS=/dev/null/nope bash "$BLOAT")
assert_eq "" "$unavailable"
jq --argjson n "$(jq '.paths.entries | length' "$RATES")" '.paths.criteria.limit = $n' "$RATES" \
  > "$RATES.capped" && mv "$RATES.capped" "$RATES"
assert_eq "" "$(growth_output "$ABSENT_MD" "$cheap_growth" absent-capped)"
write_current_rates

echo "== bloat gate: an always-on file the export never measured keeps its class price"
# Every instruction file is Markdown, so testing "absent Markdown is cheap" before the class
# lookup made that lookup unreachable for all of them: a project CLAUDE.md that no session ever
# Read explicitly — which is most of them, since they are auto-loaded rather than opened — was
# announced ungated at ~1 a month while its project was measured at 300 limit units.
UNMEASURED="$WORK/otherproj"
mkdir -p "$UNMEASURED/nested"
printf 'x\n' > "$UNMEASURED/CLAUDE.md"
printf 'x\n' > "$UNMEASURED/nested/CLAUDE.md"
jq --arg p "$UNMEASURED/nested" '.projects[$p] = {reads: 600.0, limit_units: 300.0}' "$RATES" \
  > "$RATES.sub" && mv "$RATES.sub" "$RATES"
msg=$(price_bloat unmeasured-project "$UNMEASURED/CLAUDE.md")
assert_contains "~300 times a month" "$msg"
# The project rate belongs to the instruction files, not to everything sharing their directory.
assert_eq "" "$(growth_output "$UNMEASURED/settings.json" "$cheap_growth" unmeasured-neighbour)"
# The sessions that pay for a CLAUDE.md are the ones at or below its directory, so a repository
# root file collects every subdirectory that ran sessions, not only the exact-key match.
jq --arg p "$UNMEASURED" '.projects[$p] = {reads: 400.0, limit_units: 200.0}' "$RATES" \
  > "$RATES.root" && mv "$RATES.root" "$RATES"
assert_contains "~500 times a month" "$(price_bloat unmeasured-sum "$UNMEASURED/CLAUDE.md")"
write_current_rates

echo "== write gate: current path rates use the same weekly-first figures"
msg=$(price current-global "$CLAUDE_MD")
assert_contains "re-read ~3,000 times a week" "$msg"
assert_contains "~10,000 times a month" "$msg"
assert_contains "tokenmap reads $CLAUDE_MD" "$msg"
msg=$(price current-project "$WORK/liveproj/CLAUDE.md")
assert_contains "re-read ~150 times a week" "$msg"
assert_contains "~500 times a month" "$msg"

write_rates "$(stamp_ago 20)"
assert_contains "~3,000 times a week, ~15,000 times a month" "$(price live-f "$CLAUDE_MD")"

# Every later section is about the constants, so the export stops being in effect here.
unset TOKENMAP_RATES

echo "== bloat gate: the global file's byte ceiling stands outside the retry ritual"
# The one always-on file has a size past which growth is refused rather than priced, and the
# audit-then-retry stamp must not be a way through it.
CEIL_STAMPS="$HOME/.cache/bloat-ceiling"
ceil() {
  local out
  out=$(jq -cn --arg p "$1" --arg o "$2" --arg n "$3" --arg s "ceil-$4" --arg t "$TRANSCRIPT" \
    '{tool_name:"Edit",cwd:"/tmp",session_id:$s,transcript_path:$t,
      tool_input:{file_path:$p,old_string:$o,new_string:$n}}' \
    | INSTRUCTION_BLOAT_GATE_STAMPS="$CEIL_STAMPS" bash "$BLOAT")
  harness_deny "$TRANSCRIPT" "$out" Edit
  [ -z "$out" ] || printf '%s\n' "$out"
}
ceil_decision() {
  local out
  out=$(ceil "$@")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
ceil_reason() { ceil "$@" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }
grow200=$(python3 -c 'print("z"*201, end="")')

rm -rf "$CEIL_STAMPS"
python3 -c 'print("g"*32899)' > "$REAL_MD"
assert_eq 32900 "$(wc -c <"$REAL_MD" | tr -d '[:space:]')"
assert_contains "past its 33000-byte ceiling" "$(ceil_reason "$CLAUDE_MD" x "$grow200" hard)"
# The stamp ritual never gets a say: the identical edit is denied again after a full re-read, which
# is exactly what would have passed it for ordinary growth.
append_read "$CLAUDE_MD"
age_stamps "$CEIL_STAMPS"
assert_contains "past its 33000-byte ceiling" "$(ceil_reason "$CLAUDE_MD" x "$grow200" hard)"
append_read "$CLAUDE_MD"
age_stamps "$CEIL_STAMPS"
assert_eq deny "$(ceil_decision "$CLAUDE_MD" x "$grow200" hard)"
# Identity, not spelling: the profile symlink and the repo path are the same file.
assert_eq deny "$(ceil_decision "$HOME/.claude-profiles/com/CLAUDE.md" x "$grow200" hard-profile)"
assert_eq deny "$(ceil_decision "$REAL_MD" x "$grow200" hard-repo)"
# A Write is sized by the content it would leave behind.
assert_contains "past its 33000-byte ceiling" \
  "$(jq -cn --arg p "$CLAUDE_MD" --arg n "$(python3 -c 'print("g"*34000, end="")')" \
       '{tool_name:"Write",cwd:"/tmp",session_id:"ceil-write",tool_input:{file_path:$p,content:$n}}' \
     | INSTRUCTION_BLOAT_GATE_STAMPS="$CEIL_STAMPS" bash "$BLOAT" \
     | jq -r '.hookSpecificOutput.permissionDecisionReason')"

echo "== bloat gate: shrinking an oversized global file is the way back down, not a violation"
# The cap is direction-aware. A gate that denied 34000 -> 33500 would leave the only edit that fixes
# the problem as the one it refuses.
python3 -c 'print("g"*33999)' > "$REAL_MD"
assert_eq "" "$(ceil "$CLAUDE_MD" "$grow200" x shrink)"
assert_eq pass "$(ceil_decision "$CLAUDE_MD" "$grow200" x shrink)"

echo "== bloat gate: the ceiling is not gated by the growth threshold"
# A byte over the cap is over the cap; the threshold below which growth goes unpriced says nothing
# about the size the file would reach.
python3 -c 'print("g"*32998)' > "$REAL_MD"
assert_eq 32999 "$(wc -c <"$REAL_MD" | tr -d '[:space:]')"
assert_eq deny "$(ceil_decision "$CLAUDE_MD" x xyz tiny-over)"
# Landing exactly on the cap is not past it — it is only worth a warning.
exact_out=$(ceil "$CLAUDE_MD" x xy tiny-exact)
assert_eq "" "$(printf '%s' "$exact_out" | jq -r '.hookSpecificOutput.permissionDecision // ""')"
assert_contains "would be 33000 bytes" \
  "$(printf '%s' "$exact_out" | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "== bloat gate: between the two bounds the warning rides along with the ordinary pricing"
rm -rf "$CEIL_STAMPS"
python3 -c 'print("g"*29899)' > "$REAL_MD"
msg=$(ceil_reason "$CLAUDE_MD" x "$big" warn-flow)
assert_contains "tokens/week and " "$msg"
assert_contains "would be 30299 bytes" "$msg"
append_read "$CLAUDE_MD"
age_stamps "$CEIL_STAMPS"
warn_out=$(ceil "$CLAUDE_MD" x "$big" warn-flow)
assert_eq "" "$(printf '%s' "$warn_out" | jq -r '.hookSpecificOutput.permissionDecision // ""')"
assert_contains "would be 30299 bytes" \
  "$(printf '%s' "$warn_out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
# Under the warning bound the size is nobody's business, so the ordinary denial says nothing about it.
python3 -c 'print("g"*999)' > "$REAL_MD"
rm -rf "$CEIL_STAMPS"
case "$(ceil_reason "$CLAUDE_MD" x "$big" quiet)" in
  *"would be"*) fail "a small global file was warned about its size" ;;
esac

echo "== bloat gate: the ceiling belongs to the global file alone"
# Every other guarded file is priced, however large it is: only the global one rides in every
# session of every project.
mkdir -p "$WORK/bigproj"
python3 -c 'print("g"*39999)' > "$WORK/bigproj/CLAUDE.md"
msg=$(ceil_reason "$WORK/bigproj/CLAUDE.md" x "$big" other-file)
assert_contains "tokens/week and " "$msg"
case "$msg" in *ceiling*) fail "a project file was held to the global file's ceiling" ;; esac
printf 'global rules\n' > "$REAL_MD"

echo "OK ($asserts assertions)"
