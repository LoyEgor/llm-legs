#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/instruction_gate_harness.sh"
profile_link
docs_link
alert_log_stub

echo "== tripwire: growth this session's own call produced is put back inside the span"
# The gate ahead of this one can read a command's shape but never its result, so the bytes are
# this hook's to measure. Inside the span growth goes back rather than being reported: Egor is
# away, and the span's rule is the only arbiter left in the room.
# The bytes this case goes back to are its own: the machine-wide marker is named for the file and
# what it now holds, so a revert landing on content some earlier case already had Egor told about
# wins no claim and writes no journal entry — the put-back itself still happens and still reaches
# the model.
printf 'tier doc before the revert case\n' > "$DOC"
span_base sid-revert >/dev/null
pre_call sid-revert Bash command "$grow_cmd" "$SPAN_T"
assert [ -s "$INSTRUCTION_WATCH_STATE/inflight/sid-revert@tu-sid-revert" ]
printf 'a line no human asked for\n' >> "$DOC"
ctx=$(span_check sid-revert Bash command "$grow_cmd" "$SPAN_T")
assert [ ! -e "$INSTRUCTION_WATCH_STATE/inflight/sid-revert@tu-sid-revert" ]
assert_contains "REVERTED" "$ctx"
assert_contains "PUT BACK" "$ctx"
assert_eq 0 "$(tail -1 "$INSTRUCTION_WATCH_STATE/events.jsonl" | jq '.bytes[0]')"
assert_eq "tier doc before the revert case" "$(cat "$DOC")"
# Nothing this hook does may be unrecoverable: what it overwrote is parked, and the report says
# where.
parked=$(printf '%s' "$ctx" | sed -n 's/.*parked at \([^ )]*\).*/\1/p')
assert [ -s "$parked" ]
assert_contains "no human asked for" "$(cat "$parked")"
# One report, and the baseline moved on with it.
assert_eq "" "$(span_check sid-revert Bash command "echo x >> $DOC" "$SPAN_T")"

echo "== tripwire: an Edit says which file it wrote in its own payload"
AGENT_MD="$HOME/.claude/agents/codex-worker.md"
span_base sid-revert-edit >/dev/null
before=$(cat "$AGENT_MD")
pre_call sid-revert-edit Edit file_path "$AGENT_MD" "$SPAN_T"
printf 'a brief nobody approved\n' >> "$AGENT_MD"
ctx=$(span_check sid-revert-edit Edit file_path "$AGENT_MD" "$SPAN_T")
assert_contains "REVERTED" "$ctx"
assert_eq "$before" "$(cat "$AGENT_MD")"

echo "== tripwire: with the live span helper growth inside the span stays"
printf 'words_span_live() { return 1; }\n' > "$WORK/span-off-words.sh"
span_base sid-live-off >/dev/null
pre_call sid-live-off Bash command "$grow_cmd" "$SPAN_T"
printf 'grown while the helper says off\n' >> "$DOC"
ctx=$(WORDS_LIB="$WORK/span-off-words.sh" span_check sid-live-off Bash command "$grow_cmd" "$SPAN_T")
assert_contains "REVERTED" "$ctx"
span_base sid-live >/dev/null
pre_call sid-live Bash command "$grow_cmd" "$SPAN_T"
printf 'grown inside the live span\n' >> "$DOC"
ctx=$(live_span span_check sid-live Bash command "$grow_cmd" "$SPAN_T")
case "$ctx" in *REVERTED*) fail "growth inside the live span was put back" ;; esac
assert_contains "grown inside the live span" "$(cat "$DOC")"
printf 'tier doc before the revert case\n' > "$DOC"
span_base sid-live >/dev/null

echo "== tripwire: outside the span nothing is rolled back"
# Egor is here to arbiter, and the writer may be another chat sharing the checkout.
span_base sid-nospan >/dev/null
pre_call sid-nospan Bash command "$grow_cmd" "$NOSPAN_T"
printf 'grown out of the span\n' >> "$DOC"
ctx=$(span_check sid-nospan Bash command "$grow_cmd" "$NOSPAN_T")
assert_contains "CHANGED" "$ctx"
assert_contains "puts them back" "$ctx"
case "$ctx" in *REVERTED*) fail "the tripwire rolled back a change with Egor in the room" ;; esac
assert_contains "grown out of the span" "$(cat "$DOC")"
printf 'tier doc\n' > "$DOC"

echo "== tripwire: bytes that landed before this call started claim nothing"
# In a shared checkout the writer is as often another chat as this session, and a rollback decided
# on a guess eats that chat's live work.
span_base sid-foreign >/dev/null
printf 'grown by somebody else\n' >> "$DOC"
pre_call sid-foreign Bash command "touch $WORK/scratch/stamp" "$SPAN_T"
ctx=$(span_check sid-foreign Bash command "touch $WORK/scratch/stamp" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "the tripwire rolled back a change it could not attribute" ;; esac
assert_contains "grown by somebody else" "$(cat "$DOC")"
printf 'tier doc\n' > "$DOC"

echo "== tripwire: a call whose window missed the write is not its writer, whatever it names"
# The bytes have to land while the call is in flight: a command that names the file — `sed -n`,
# a redirect aimed elsewhere, a runtime reading it — started after another chat's growth and is not
# blamed for it.
aimed_case=0
for read_cmd in "sed -n '1,5p' $DOC > $WORK/scratch/head.md" "cat $DOC > $WORK/scratch/copy.md" \
                "python3 -c 'open(\"$DOC\").read()'" \
                "node -e 'fs.readFileSync(\"$DOC\")'"; do
  aimed_case=$((aimed_case + 1))
  span_base "sid-aimed-$aimed_case" >/dev/null
  printf 'grown by somebody else\n' >> "$DOC"
  pre_call "sid-aimed-$aimed_case" Bash command "$read_cmd" "$SPAN_T"
  ctx=$(span_check "sid-aimed-$aimed_case" Bash command "$read_cmd" "$SPAN_T")
  assert_contains "CHANGED" "$ctx"
  case "$ctx" in *REVERTED*) fail "a command that only read the file was blamed for its growth: $read_cmd" ;; esac
  assert_contains "grown by somebody else" "$(cat "$DOC")"
  printf 'tier doc\n' > "$DOC"
done

echo "== tripwire: a Bash call that provably writes nothing is neither marked nor checked"
# The same trade the matcher already makes for Read and Grep: a call that cannot write has no
# window to attribute and nothing to put back, so growth that lands meanwhile is reported by the
# next call that could have written, and never reverted by either.
span_base sid-ro >/dev/null
printf 'grown by somebody else\n' >> "$DOC"
pre_call sid-ro Bash command "sed -n '1,5p' $DOC | grep -c ." "$SPAN_T"
assert_fails [ -e "$INSTRUCTION_WATCH_STATE/inflight/sid-ro@tu-sid-ro" ]
assert [ -e "$INSTRUCTION_WATCH_STATE/readonly/sid-ro@tu-sid-ro" ]
assert_eq "" "$(span_check sid-ro Bash command "sed -n '1,5p' $DOC | grep -c ." "$SPAN_T")"
assert_fails [ -e "$INSTRUCTION_WATCH_STATE/readonly/sid-ro@tu-sid-ro" ]
pre_call sid-ro Bash command "touch $WORK/scratch/stamp" "$SPAN_T"
assert [ -s "$INSTRUCTION_WATCH_STATE/inflight/sid-ro@tu-sid-ro" ]
ctx=$(span_check sid-ro Bash command "touch $WORK/scratch/stamp" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "growth seen after a read-only call was blamed on the next call" ;; esac
assert_contains "grown by somebody else" "$(cat "$DOC")"
printf 'tier doc\n' > "$DOC"
# The tripwire reads no command: a read-only call the gate never saw, so left no note for, is checked,
# and a note another call of the session left vouches for that call alone.
span_base sid-unvouched >/dev/null
: > "$INSTRUCTION_WATCH_STATE/readonly/sid-unvouched@tu-elsewhere"
printf 'grown by somebody else\n' >> "$DOC"
ctx=$(span_check sid-unvouched Bash command "sed -n '1,5p' $DOC" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
assert [ -e "$INSTRUCTION_WATCH_STATE/readonly/sid-unvouched@tu-elsewhere" ]
printf 'tier doc\n' > "$DOC"
# A note nobody took (the call exited non-zero, so no PostToolUse) goes after a day, at session start.
touch -t 202601010000 "$INSTRUCTION_WATCH_STATE/readonly/sid-unvouched@tu-elsewhere"
: > "$INSTRUCTION_WATCH_STATE/readonly/sid-unvouched@tu-fresh"
span_base sid-note-sweep >/dev/null
assert_fails [ -e "$INSTRUCTION_WATCH_STATE/readonly/sid-unvouched@tu-elsewhere" ]
assert [ -e "$INSTRUCTION_WATCH_STATE/readonly/sid-unvouched@tu-fresh" ]
rm -f "$INSTRUCTION_WATCH_STATE/readonly/sid-unvouched@tu-fresh"
# Without the classifier library the gate falls back to marking every call, so every call is checked.
span_base sid-nolib >/dev/null
printf 'grown by somebody else\n' >> "$DOC"
READONLY_COMMAND_LIB=$WORK/absent.sh pre_call sid-nolib Bash command "grep -c . $DOC" "$SPAN_T"
assert [ -s "$INSTRUCTION_WATCH_STATE/inflight/sid-nolib@tu-sid-nolib" ]
ctx=$(READONLY_COMMAND_LIB=$WORK/absent.sh span_check sid-nolib Bash command "grep -c . $DOC" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
printf 'tier doc\n' > "$DOC"

echo "== in-flight stamps: seconds with a leading zero are decimal, a malformed stamp converts to nothing"
assert_eq 8500000000 "$(fmt instruction_ns 08.5)"
assert_fails fmt instruction_ns 1.x

echo "== tripwire: an interpreter READING the every-session file is not a write to it"
span_base sid-read-always >/dev/null
printf 'a line no human asked for\n' >> "$CLAUDE_MD"
pre_call sid-read-always Bash command "python3 -c 'open(\"$CLAUDE_MD\").read()'" "$SPAN_T"
ctx=$(span_check sid-read-always Bash command "python3 -c 'open(\"$CLAUDE_MD\").read()'" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "a python read of the global file was blamed for its growth" ;; esac
assert_contains "no human asked for" "$(cat "$CLAUDE_MD")"
printf 'global rules\n' > "$CLAUDE_MD"

echo "== one parse: both doors read the same destinations off a command"
# Two parses of one line was the defect these hooks were built with: the gate located a
# destination strictly while the tripwire re-derived it from a looser expression of its own, so a
# `.bak` sibling of a guarded name was a write to one half and not to the other, and a `mv` whose
# segment ended in whitespace was attributed to nobody. Four shapes, asked of the ONE parse both
# doors now call.
mkdir -p "$WORK/stage"
targets() { # command names-alternation → the destination names the parse finds
  share_call 'instruction_write_targets "$2" "$3" | cut -f4' "$1" "$2"
}
DOC_ERE=$(share_call 'instruction_ere_escape "$2"' "$DOC")
# A name a destination merely ENDS with is not that name.
assert_eq "" "$(targets "echo x > $DOC.bak" "$DOC_ERE")"
# Nor is it that name to the interpreter shapes: every branch closes the quote after the path, or
# a `.bak` sibling reads as the guarded file itself and the tripwire reverts a write it never made.
interp_writes() { # command → how many interpreter write constructs the shared shapes find
  share_call 'printf "%s" "$2" | grep -Eo "$(instruction_interp_write_re "$3")" | wc -l | tr -d " "' "$1" "$DOC_ERE"
}
for sibling in \
  "perl -e \"open(FH, '>', '$DOC.bak')\"" \
  "node -e \"fs.writeFileSync('$DOC.bak','x')\"" \
  "ruby -e \"File.write('$DOC.bak','x')\"" \
  "python3 -c \"import shutil; shutil.copy('/tmp/x','$DOC.bak')\"" \
  "python3 -c \"open('$DOC.bak','w')\""; do
  assert_eq 0 "$(interp_writes "$sibling")"
done
for real in \
  "perl -e \"open(FH, '>', '$DOC')\"" \
  "node -e \"fs.writeFileSync('$DOC','x')\"" \
  "ruby -e \"File.write('$DOC','x')\"" \
  "python3 -c \"import shutil; shutil.copy('/tmp/x','$DOC')\"" \
  "python3 -c \"open('$DOC','w')\""; do
  assert_eq 1 "$(interp_writes "$real")"
done
# The destination of a copy verb is its last operand, whatever stands after the command.
assert_eq "$DOC" "$(targets "mv $WORK/stage/tmp.md $DOC && true" "$DOC_ERE")"
# What a `<` names is what the command READS.
assert_eq "" "$(targets "cat < $DOC" "$DOC_ERE")"
# A copy into a DIRECTORY leaves its bytes in a file the operand never spells.
assert_eq "$DOC" "$(targets "cp $WORK/stage/review-tiers.md $HOME/.claude/docs" "$DOC_ERE")"
assert_contains "./review-tiers.md" \
  "$(targets 'cp /tmp/stage/review-tiers.md .' 'review-tiers\.md|\./review-tiers\.md')"
# A continuation is one command to the shell, and the tripwire hands over the RAW command: the
# join belongs to the parse, not to whichever caller remembers it.
assert_eq "$DOC" "$(targets "$(printf 'cp %s/stage/tmp.md \\\n%s\n' "$WORK" "$DOC")" "$DOC_ERE")"
# An in-place editor writes the file it is pointed at however the flag is spelled, GNU included.
assert_eq "$DOC" "$(targets "sed --in-place=.bak s/x/y/ $DOC" "$DOC_ERE")"
assert_eq "$DOC" "$(targets "gsed -i s/x/y/ $DOC" "$DOC_ERE")"
# `dd` names its destination in an operand of its own, and the by-name spelling the gate matches
# with is what makes the difference visible: emitted verbatim, `of=<path>` matches whole and the
# denial names a file that does not exist, while `if=` reports what dd READS as a write.
BY_NAME_ERE="([^[:space:];|&'\"]*/)?review-tiers\.md"
assert_eq "$DOC" "$(targets "dd if=$WORK/stage/tmp.md of=$DOC" "$BY_NAME_ERE")"
assert_eq "" "$(targets "dd if=$DOC of=$WORK/stage/tmp.md" "$BY_NAME_ERE")"
# `<<\EOF` quotes a heredoc the way `<<"EOF"` does: unrecognised, the body it holds is read as
# commands, and a rule it merely quotes reads as a write to the file the rule is about — a false
# denial at this door and, at the tripwire, a rollback of somebody else's growth.
assert_eq "" "$(targets "$(printf 'cat > %s/stage/scratch <<\\EOF\nsee > %s for the rule\nEOF\n' "$WORK" "$DOC")" "$DOC_ERE")"
assert_eq pass "$(in_span decision "$(printf 'cat > %s/stage/scratch <<\\EOF\nsee > %s for the rule\nEOF\n' "$WORK" "$DOC")")"
# Asked of the scan too, which is the pass that exists to take a body out: the raw fallback beside
# it can hide a body the scan kept, and then only one of the two doors reads that command right.
assert_eq 0 "$(share_call 'printf "%s" "$2" | instruction_shell_scan | grep -c review-tiers' \
  "$(printf 'cat > %s/stage/scratch <<\\EOF\nsee > %s for the rule\nEOF\n' "$WORK" "$DOC")")"
# `<<-` strips tabs and no spaces, so a space-indented word is not the terminator and the body
# after it is still the body.
assert_eq "" "$(targets "$(printf 'cat > %s/stage/scratch <<-EOF\n  EOF\nsee > %s for the rule\nEOF\n' "$WORK" "$DOC")" "$DOC_ERE")"

echo "== one parse: what the scan cannot resolve sends every door to the raw command"
# The conservative side of this parse, spelled as the doors read it: a false deny is a retry, a
# false allow is a write or a launch nobody authorised. Every shape below ran unflagged in review
# round 20260922T131804Z-50cea15, each because the scan quietly resolved to something the raw text
# does not say.
scan_of() { # command -> the scan's own output
  share_call 'printf "%s" "$2" | instruction_shell_scan' "$1"
}
unresolved() { # command -> yes when the scan tells its callers to read the raw command instead
  share_call 'printf "%s" "$2" | instruction_shell_scan |
    grep -Eq "$INSTRUCTION_INTERPRETER_RE|$INSTRUCTION_CMD_POSITION_RE" && printf yes || printf no' "$1"
}

# A language runtime re-parses its payload exactly as a shell does, and what it starts from there
# is any command at all — `python3 -c Q` says nothing about the `git push` inside the Q.
for interp in \
  'python3 -c '"'"'import subprocess; subprocess.run(["git","push"])'"'"'' \
  'perl -e '"'"'system("git push")'"'"'' \
  'ruby -e '"'"'system("git push")'"'"'' \
  'node -e '"'"'require("child_process").execSync("git push")'"'"'' \
  'awk '"'"'BEGIN{system("git push")}'"'"'' \
  'su -c '"'"'git push'"'"'' \
  'flock /tmp/l -c '"'"'git push'"'"''; do
  assert_eq yes "$(unresolved "$interp")"
done
# The write gate keeps its own reading of a runtime beside this one: a payload that names a
# guarded file without writing it is still a read.
assert_eq pass "$(decision "python3 -c \"open('$WORK/stage/notes.md','w').write('x')\"")"
assert_eq pass "$(decision "python3 -c \"open('$CLAUDE_MD','r').read()\"")"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','w').write('one more line')\"")"

# A `<<` whose terminator never appears is not a heredoc: an arithmetic shift and a quoted
# sentence both supply one, and every command after that line was dropped from the scanned text.
assert_contains "git commit -m x" "$(scan_of "$(printf 'echo $((1<<n))\ngit commit -m x\n')")"
assert_contains "git push" "$(scan_of "$(printf 'echo "shift is 1 << n"\ngit push\n')")"
assert_eq deny "$(decision "$(printf 'echo $((1<<n))\ncat %s/stage/tmp.md > %s\n' "$WORK" "$CLAUDE_MD")")"
# A heredoc whose terminator IS there keeps dropping its body, which is what the pass is for.
assert_eq 0 "$(scan_of "$(printf 'cat > %s/stage/scratch <<EOF\ngit push\nEOF\n' "$WORK")" | grep -c 'git push')"
assert_contains "git push" "$(scan_of "$(printf 'bash -c "$(cat <<EOF\ngit push\nEOF\n)"')")"
assert_eq pass "$(decision "$(printf 'cat > %s/stage/scratch <<EOF\nsee %s for the rule\nEOF\n' "$WORK" "$CLAUDE_MD")")"

# A git alias body is a program git hands to a shell, and it runs as a command line of its own.
assert_contains "git push zz" "$(scan_of "git -c alias.zz='!git push' zz")"
assert_contains "review-bench review . p" "$(scan_of "git -c alias.p='!review-bench review .' p")"
# A quoted run that is NOT an alias body is still the one word it is: a commit message naming a
# gated command carries it as text.
assert_eq "git commit -m Q" "$(scan_of 'git commit -m "remember to git push later"')"
assert_eq no "$(unresolved 'git commit -m "remember to git push later"')"

# A backtick is the other spelling of `$(`, and in command position it names an executable this
# parse cannot resolve.
assert_eq yes "$(unresolved '`which git` push')"
assert_eq yes "$(unresolved '`printf git` push')"
# Standing as an ARGUMENT it resolves nothing and hides nothing.
assert_eq no "$(unresolved 'ls `pwd`')"

# A brace group and an env-assignment prefix are command position typed two other ways, and `^`
# restarts at every line.
assert_eq yes "$(unresolved '{ $GIT push; }')"
assert_eq yes "$(unresolved 'GIT_DIR=/tmp/r.git $GIT push')"
assert_eq yes "$(unresolved "$(printf 'cd /repo\n$GIT push\n')")"
assert_eq no "$(unresolved '{ echo one; echo two; }')"
assert_eq no "$(unresolved 'GIT_DIR=/tmp/r.git git status')"
assert_eq no "$(unresolved 'git push $REMOTE')"

# Outside quotes a backslash escapes one character: the name it stands inside survives it.
assert_eq "git push" "$(scan_of 'gi\t push')"
assert_eq "echo a b" "$(scan_of 'echo a\ b')"
# ANSI-C quoting is a body this parse does not resolve, so the word stands in command position.
assert_eq "Q push" "$(scan_of "\$'g\\x69t' push")"
assert_eq yes "$(unresolved "\$'g\\x69t' push")"

# A variable in command position counts whatever follows it — a quoted word glued to it, a
# positional parameter, one of the shell's own specials.
assert_eq yes "$(unresolved "\$VAR'view-bench'")"
for special in '$1 push' '$@ push' '$* push' '$_ push' '$- push' '$! push' '$? push'; do
  assert_eq yes "$(unresolved "$special")"
done

echo "== in flight: the gate denies by the parse, the tripwire attributes by the clock"
# A call the gate lets through and whose window covers the write is its writer; bytes that landed
# before the call started are not, whatever destination the command names.
parse_case=0
while IFS='|' read -r owns cmd; do
  [ -n "$cmd" ] || continue
  parse_case=$((parse_case + 1))
  printf 'tier doc\n' > "$DOC"
  printf 'staged\n' > "$WORK/stage/review-tiers.md"
  span_base "sid-parse-$parse_case" >/dev/null
  if [ "$owns" = yes ]; then
    pre_call "sid-parse-$parse_case" Bash command "$cmd" "$SPAN_T"
    printf 'a line no human asked for\n' >> "$DOC"
  else
    printf 'a line no human asked for\n' >> "$DOC"
    pre_call "sid-parse-$parse_case" Bash command "$cmd" "$SPAN_T"
  fi
  ctx=$(span_check "sid-parse-$parse_case" Bash command "$cmd" "$SPAN_T")
  if [ "$owns" = yes ]; then
    assert_contains "REVERTED" "$ctx"
    assert_eq "tier doc" "$(cat "$DOC")"
  else
    assert_contains "CHANGED" "$ctx"
    case "$ctx" in *REVERTED*) fail "a command that wrote elsewhere was blamed for the growth: $cmd" ;; esac
  fi
  if [ "$owns" = yes ]; then
    assert_eq deny "$(GATE_CWD="$WORK" decision "$cmd")"
  else
    assert_eq pass "$(GATE_CWD="$WORK" decision "$cmd")"
  fi
done <<CASES
no|echo x > $DOC.bak
yes|mv $WORK/stage/tmp.md $DOC && true
no|cat < $DOC > $WORK/stage/copy.md
yes|cp $WORK/stage/review-tiers.md home/.claude/docs
CASES
printf 'tier doc\n' > "$DOC"

echo "== tripwire: a write that SHRANK the file is what the span exists for"
span_base sid-shrink >/dev/null
pre_call sid-shrink Bash command "printf tiny > $DOC" "$SPAN_T"
assert [ -s "$INSTRUCTION_WATCH_STATE/inflight/sid-shrink@tu-sid-shrink" ]
printf 'tiny\n' > "$DOC"
ctx=$(span_check sid-shrink Bash command "printf tiny > $DOC" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "the tripwire put back a shrink the span exists to allow" ;; esac
assert_eq "tiny" "$(cat "$DOC")"
printf 'tier doc\n' > "$DOC"
# The shape the bug arrived in: an Edit that cut 129 bytes out of ~/.claude/commands/worker.md
# inside the span, rolled back by a hook that measured that a file had changed and not which way.
CMD_MD="$HOME/.claude/commands/worker.md"
printf '%129s\n' | tr ' ' x > "$CMD_MD"
span_base sid-shrink-edit >/dev/null
pre_call sid-shrink-edit Edit file_path "$CMD_MD" "$SPAN_T"
printf 'x\n' > "$CMD_MD"
ctx=$(span_check sid-shrink-edit Edit file_path "$CMD_MD" "$SPAN_T")
assert_contains "CHANGED" "$ctx"
case "$ctx" in *REVERTED*) fail "an in-span Edit that CUT bytes was put back" ;; esac
assert_eq "x" "$(cat "$CMD_MD")"
printf 'command doc\n' > "$CMD_MD"

echo "== tripwire: settings.json is watched and never reverted"
# No gate speaks for it, in the span or out of it.
span_base sid-set-span >/dev/null
pre_call sid-set-span Bash command "echo x > $HOME/.claude/settings.json" "$SPAN_T"
printf '{"model":"opus","hooks":{"Stop":[],"PreToolUse":[]}}\n' > "$HOME/.claude/settings.json"
ctx=$(span_check sid-set-span Bash command "echo x > $HOME/.claude/settings.json" "$SPAN_T")
assert_contains "settings.json" "$ctx"
case "$ctx" in *REVERTED*) fail "the tripwire rolled back settings.json, which no gate speaks for" ;; esac

echo "== tripwire: growth through a path the gate cannot see is still put back"
# A script file names its target nowhere in the command, so no parse could ever attribute it; the
# clock does.
span_base sid-heredoc >/dev/null
pre_call sid-heredoc Bash command "python3 $WORK/stage/grow.py" "$SPAN_T"
printf 'a line through a script\n' >> "$DOC"
ctx=$(span_check sid-heredoc Bash command "python3 $WORK/stage/grow.py" "$SPAN_T")
assert_contains "REVERTED" "$ctx"
assert_eq "tier doc" "$(cat "$DOC")"

echo "OK ($asserts assertions)"
