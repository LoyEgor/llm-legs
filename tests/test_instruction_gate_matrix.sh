#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/instruction_gate_harness.sh"
profile_link
docs_link
alert_log_stub

echo "== gate matrix: settings.json is out of the deny gate entirely"
# Not an instruction file — nothing re-reads it into a context window — and the harness rewrites
# it on every model or permission-mode switch, so a denial here cost Egor a tactical "ok" and
# caught nothing. The tripwire still watches it, which is the half that can put its bytes back.
assert_eq pass "$(decision "echo x > $HOME/.claude/settings.json")"
assert_eq pass "$(GATE_CWD="$HOME/.claude" decision 'echo x > settings.json')"
assert_eq pass "$(decision "printf x | tee $HOME/.claude/settings.json")"
assert_eq pass "$(in_span decision "echo y >> $HOME/.claude/settings.json")"
assert_eq pass "$(decision "python3 -c \"open('$HOME/.claude/settings.json','w').write('{}')\"")"

echo "== gate matrix: the every-session class is denied in the span as much as out of it"
# The global file, a project file, the local override. Growing or shrinking, span or no span:
# these ride in the prefix of every session, and no cleanup of them is a model's own call.
printf 'project rules\n' > "$REPO/CLAUDE.md"
printf 'local rules\n' > "$HOME/.claude/CLAUDE.local.md"
for state in in_span out_span; do
  assert_eq deny "$($state decision "printf tiny > $CLAUDE_MD")"
  assert_eq deny "$($state decision "echo more >> $CLAUDE_MD")"
  assert_eq deny "$($state decision "printf tiny > $REAL_MD")"
  assert_eq deny "$($state decision "printf tiny > $REPO/CLAUDE.md")"
  assert_eq deny "$($state decision "printf tiny > $HOME/.claude/CLAUDE.local.md")"
  assert_eq deny "$($state decision "printf tiny | tee $CLAUDE_MD")"
  assert_eq deny "$($state decision "python3 -c \"open('$CLAUDE_MD','w').write('x')\"")"
done

echo "== gate matrix: the span reshapes the on-demand instruction files but never grows them"
# Egor is away and the model is the only actor, so a write that REPLACES a doc's bytes is the
# cleanup he left it; an append can only add to a file every later session re-reads. Out of the
# span nothing moved: both shapes are still denied.
for f in "$HOME/.claude/docs/review-tiers.md" "$HOME/.claude/agents/codex-worker.md" \
         "$HOME/.claude/skills/demo/SKILL.md" "$HOME/.claude/commands/worker.md"; do
  assert_eq pass "$(in_span decision "printf shorter > $f")"
  assert_eq deny "$(in_span decision "echo more >> $f")"
  assert_eq deny "$(out_span decision "printf shorter > $f")"
  assert_eq deny "$(out_span decision "echo more >> $f")"
done

echo "== gate matrix: the live span helper lets the span grow the on-demand files and CLAUDE.md too"
for f in "$HOME/.claude/docs/review-tiers.md" "$HOME/.claude/agents/codex-worker.md" \
         "$HOME/.claude/skills/demo/SKILL.md" "$HOME/.claude/commands/worker.md"; do
  assert_eq pass "$(live_span in_span decision "echo live-more >> $f")"
  assert_eq deny "$(live_span out_span decision "echo live-more >> $f")"
done
assert_eq pass "$(live_span in_span decision "python3 -c \"open('$HOME/.claude/docs/review-tiers.md','a').write('x')\"")"
assert_eq pass "$(live_span in_span decision "echo live-more >> $CLAUDE_MD")"
assert_eq deny "$(live_span out_span decision "echo live-more >> $CLAUDE_MD")"
assert_contains "orchestrator's to edit" "$(CLAUDEB_WORKER=1 live_span in_span gate "echo live-more >> $CLAUDE_MD" 2>&1)"
assert_eq deny "$(live_span in_span decision "echo live-more >> $HOME/.claude/review-debt-ignore")"

echo "== bloat gate: the live span helper passes growth, out of the span it is still priced"
bloat_as() { # session transcript path
  local out
  out=$(jq -cn --arg p "$3" --arg n "$big" --arg s "$1" --arg t "$2" \
          '{tool_name:"Edit",cwd:"/tmp",session_id:$s,transcript_path:$t,tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
        | bash "$BLOAT")
  [ -n "$out" ] || { printf 'pass\n'; return 0; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null
}
assert_eq pass "$(live_span bloat_as matrix-span "$SPAN_T" "$CLAUDE_MD")"
assert_eq pass "$(live_span bloat_as matrix-span "$SPAN_T" "$HOME/.claude/docs/review-tiers.md")"
assert_eq deny "$(live_span bloat_as matrix-plain "$NOSPAN_T" "$HOME/.claude/docs/review-tiers.md")"
assert_eq deny "$(bloat_as matrix-span "$SPAN_T" "$HOME/.claude/agents/codex-worker.md")"

echo "== gate matrix: every write shape the gate reads is judged on whether it can shrink"
assert_eq pass "$(in_span decision "printf x >| $DOC")"
assert_eq pass "$(in_span decision "printf x | tee $DOC")"
assert_eq deny "$(in_span decision "printf x | tee -a $DOC")"
assert_eq pass "$(in_span decision "python3 -c \"open('$DOC','w').write('x')\"")"
assert_eq deny "$(in_span decision "python3 -c \"open('$DOC','a').write('x')\"")"
# `r+` and `a+` write past what is already there, so neither is a replacement.
assert_eq deny "$(in_span decision "python3 -c \"open('$DOC','r+').write('x')\"")"
assert_eq pass "$(in_span decision "python3 -c \"Path('$DOC').write_text('x')\"")"
assert_eq pass "$(in_span decision "node -e \"fs.writeFileSync('$DOC','x')\"")"
assert_eq pass "$(in_span decision "python3 -c \"p='$DOC'; open(p,'w').write('x')\"")"
assert_eq deny "$(in_span decision "python3 -c \"p='$DOC'; open(p,'a').write('x')\"")"
assert_eq deny "$(in_span decision "python3 -c \"p='$DOC'; t='/tmp/t'; open(t,'w'); open(p,'a')\"")"
assert_eq deny "$(in_span decision "node -e \"fs.appendFileSync('$DOC','x')\"")"
assert_eq pass "$(in_span decision "perl -e \"open(my \$f, '>', '$DOC')\"")"
assert_eq deny "$(in_span decision "perl -e \"open(my \$f, '>>', '$DOC')\"")"
# A doc that does not exist yet: the shape still says replacement, and what the bytes come to is
# the tripwire's to measure.
assert_eq pass "$(in_span decision "printf x > $HOME/.claude/docs/new-in-span.md")"
assert_eq deny "$(out_span decision "printf x > $HOME/.claude/docs/new-in-span.md")"

echo "== gate matrix: a compound is judged row by row, never one row's class against another's shape"
# The class used to come off the FIRST destination and the shrink shape off ANY of them, so a
# command whose later row could shrink a doc carried an earlier row that only grew one.
AGENT_DOC="$HOME/.claude/agents/codex-worker.md"
assert_eq deny "$(in_span decision "true; : > $CLAUDE_MD")"
assert_eq deny "$(out_span decision "true; : > $CLAUDE_MD")"
assert_eq deny "$(in_span decision "echo more >> $DOC; printf shorter > $AGENT_DOC")"
assert_eq deny "$(in_span decision "printf shorter > $DOC; echo more >> $CLAUDE_MD")"
# The denial has to name the row it refused, not the one that stood first.
msg=$(in_span gate "printf shorter > $DOC; echo more >> $CLAUDE_MD" \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$CLAUDE_MD" "$msg"
case "$msg" in *"$DOC"*) fail "the denial named a destination it let through" ;; esac
# A row the span covers is still covered when it stands beside one no gate speaks for.
assert_eq pass "$(in_span decision "printf shorter > $DOC; grep -c . $CLAUDE_MD")"
assert_eq pass "$(in_span decision "printf shorter > $DOC; printf x > $HOME/.claude/settings.json")"
# An interpreter row is judged the same way, and a permitted redirection beside it never buys it
# a pass: the redirect rows and the interpreter constructs are two lists of one command.
assert_eq deny "$(in_span decision "printf shorter > $DOC; python3 -c \"open('$CLAUDE_MD','a').write('x')\"")"
# EVERY construct, each against its own shape: the second write is not judged by the first's
# mode, and its own name is the one refused.
assert_eq deny "$(in_span decision "python3 -c \"open('$DOC','w')\"; python3 -c \"open('$CLAUDE_MD','a')\"")"
msg=$(in_span gate "python3 -c \"open('$DOC','w')\"; python3 -c \"open('$AGENT_DOC','a')\"" \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$AGENT_DOC" "$msg"
# A copy verb inside an interpreter writes its DESTINATION: reading the source instead denies a
# read out of a guarded file and lets the write into one through.
assert_eq deny "$(in_span decision "python3 -c \"import shutil; shutil.copy('/tmp/x.md','$CLAUDE_MD')\"")"
assert_eq pass "$(in_span decision "python3 -c \"import shutil; shutil.copy('$CLAUDE_MD','/tmp/x.md')\"")"

echo "== gate matrix: the in-span denial names growth, the standing one names Egor's rule"
msg=$(in_span gate "echo grow-a >> $DOC" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "ADDS to" "$msg"
assert_contains "waits for him" "$msg"
msg=$(out_span gate "echo grow-b >> $DOC" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$(fmt instruction_standing_rule)" "$msg"
assert_contains "denied whatever its size" "$msg"
case "$msg" in *"autonomy span"*) fail "the standing denial talks about a span that is not standing" ;; esac

echo "== gate matrix: the review-debt ignore list is denied always, with its own reason"
for state in in_span out_span; do
  assert_eq deny "$($state decision "echo path >> $HOME/.claude/review-debt-ignore")"
  assert_eq deny "$($state decision "printf path > $HOME/.claude/review-debt-ignore")"
  assert_eq deny "$($state decision 'echo path >> review-debt-ignore')"
done
msg=$(in_span gate "echo one-path >> $HOME/.claude/review-debt-ignore" \
      | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "review debt" "$msg"
assert_contains "never a model's" "$msg"
case "$msg" in *"re-read across sessions"*) fail "the debt list was priced like an always-on file" ;; esac

echo "== gate matrix: ~/.claude/commands is guarded like every other class directory"
assert_eq deny "$(decision "echo x > $HOME/.claude/commands/worker.md")"
assert_eq deny "$(decision "echo x > $HOME/.claude/commands/brand-new.md")"
assert_eq deny "$(GATE_CWD="$HOME/.claude/commands" decision 'echo x >> worker.md')"
assert_eq deny "$(GATE_CWD="$HOME/.claude" decision 'echo x > commands/brand-new.md')"

echo "== gate matrix: a command is judged by its write TARGET, never by a name it carries"
# A guarded name inside a heredoc body or a quoted run is data being passed along. Reading it as a
# destination denied ordinary work — a scratchpad note quoting a rule, a commit message — while
# saying nothing true about what the command wrote.
mkdir -p "$WORK/scratch"
assert_eq pass "$(decision "cat > $WORK/scratch/notes.md <<'EOF'
CLAUDE.md says to keep instruction files short
EOF")"
assert_eq pass "$(decision "cat >> $WORK/scratch/notes.md <<'EOF'
the shape to avoid is a redirect into CLAUDE.md
EOF")"
assert_eq pass "$(decision "cat >> $WORK/scratch/notes.md <<'EOF'
echo x > CLAUDE.md
EOF")"
assert_eq pass "$(decision "printf x | tee $WORK/scratch/notes.md <<'EOF'
CLAUDE.md
EOF")"
assert_eq pass "$(decision "echo 'the note mentions CLAUDE.md' >> $WORK/scratch/notes.md")"
assert_eq pass "$(decision "python3 -c \"open('$WORK/scratch/notes.md','w').write('see CLAUDE.md for rules')\"")"
# An indented heredoc terminator is the same body.
assert_eq pass "$(decision "cat > $WORK/scratch/notes.md <<-'IND'
	CLAUDE.md
	IND")"
# A herestring declares no body, so nothing after it may be swallowed.
assert_eq deny "$(decision "grep -f - $WORK/unrelated.py <<<'pattern' > $CLAUDE_MD")"
# The target itself is still the target, however it is spelled.
assert_eq deny "$(decision "cat > $HOME/.claude/docs/heredoc-target.md <<'EOF'
a new doc nobody asked for
EOF")"
assert_eq deny "$(decision "echo x > \"$CLAUDE_MD\"")"
assert_eq deny "$(decision "echo x > '$CLAUDE_MD'")"
# An interpreter handed a quoted program is handed a program: there the quoted runs are syntax
# again, so the scan falls back to the raw command.
assert_eq deny "$(decision "bash -c 'echo x > $CLAUDE_MD'")"
assert_eq deny "$(decision "sh -c \"printf x > $CLAUDE_MD\"")"
# An interpreter writes a guarded file when it NAMES it in the call that writes, and not when the
# name is merely an argument somewhere in the same payload.
assert_eq pass "$(decision "python3 -c \"open('$WORK/scratch/o.md','w').write('$CLAUDE_MD')\"")"
assert_eq pass "$(decision "node -e \"fs.writeFileSync('$WORK/scratch/o.md', 'see $CLAUDE_MD')\"")"
assert_eq deny "$(decision "python3 -c \"open('$CLAUDE_MD','w').write('$WORK/scratch/o.md')\"")"

echo "OK ($asserts assertions)"
