#!/usr/bin/env bash
# PreToolUse(Bash): the shell half of the instruction gate.
#
# What it reads off the shell: redirections, tee, the copy verbs (cp, mv, ln, install, rsync, dd,
# patch, git checkout/restore) and the interpreter write shapes, each located by the one shared
# parse. A copy onto a guarded file lands whole bytes nobody reviewed, and leaving it to the
# tripwire alone let it land unseen wherever the tripwire was not watching.
#
# This gate is a speed bump, not the guarantee. The guarantee is instruction-watch.sh, which
# reports every change however it was made and now keeps the previous bytes, so anything that
# slips past here is one command away from being put back.
#
# Not covered, on purpose: rm, truncate, sed -i, perl -pi, ex, ed. Nor a path held in a variable,
# or a new file created by bare name from inside a guarded directory. When this gate cannot tell
# — its library, jq or the payload missing — it refuses the call rather than passing it. The
# accepted false denials run the other
# way: an interpreter that READS a guarded file and writes the result elsewhere
# ("open(other,'w').write(open(CLAUDE.md).read())"), and a redirection written inside a quoted
# string (`echo 'see >CLAUDE.md' >> notes.txt`), which is indistinguishable from a real one
# without the shell's own parser. Both cost one round trip; the retry passes.
#
# Same contract as the Edit/Write gate: the exact retry passes ONCE, so a deny costs Egor one
# round trip and never becomes a wall.
set -u

[ -n "${HOME:-}" ] || exit 0

STAMP_DIR="${INSTRUCTION_WRITE_GATE_STAMPS:-$HOME/.cache/claude-instruction-write-gate}"

self=$0
for _ in 1 2 3 4 5; do
  [ -L "$self" ] || break
  target=$(readlink "$self")
  case "$target" in /*) self=$target ;; *) self=$(dirname "$self")/$target ;; esac
done
. "$(dirname "$self")/../share/instruction-files.sh" 2>/dev/null ||
  { echo "instruction write gate: cannot load share/instruction-files.sh, so no shell write can be checked" >&2; exit 2; }
command -v jq >/dev/null 2>&1 ||
  { echo "instruction write gate: jq is missing, so the hook payload cannot be read" >&2; exit 2; }

input=$(cat) || input=''
values=$(printf '%s' "$input" | jq -er '
  [(.tool_name // ""), (.session_id // ""), (.cwd // ""), (.transcript_path // ""),
   (.tool_input.command // "")]
  | join("\u001f")' 2>/dev/null) ||
  { echo "instruction write gate: the hook payload does not parse" >&2; exit 2; }
IFS=$'\x1f' read -r -d '' tool_name sid cwd transcript command <<< "$values" || :
[ "$tool_name" = Bash ] || exit 0
[ -n "$command" ] || exit 0

# A continuation is one command to the shell but two lines to grep, and every pattern below is
# anchored within a line: `cp src \` + newline + the path walked through untouched.
command=${command//\\$'\n'/ }

# Fast path before any glob or realpath: this runs ahead of every Bash call, and a command that
# names none of the guarded things cannot be a write to one.
# `.md` rather than the guarded basenames: a command typed from inside ~/.claude/docs names its
# target `review-tiers.md` and carries no other guarded substring at all. The spellings list
# already knows the cwd-relative form, so the fast path was the only thing hiding it.
# `review-debt-ignore` carries no `.md` and is written from inside `.claude/` as a bare name, so
# neither of the first two patterns sees it and the guarded basename below is never reached.
# An ANSI-C quoted run spells a name through escapes, and the volume folds letter case, so neither
# the literal suffix nor its case is a safe reason to leave early.
case "$command" in
  *.[Mm][Dd]*|*.claude/*|*[Rr][Ee][Vv][Ii][Ee][Ww]-[Dd][Ee][Bb][Tt]*|*"\$'"*) ;;
  *) exit 0 ;;
esac

alternation=''
while IFS= read -r path; do
  case "$command" in *"$path"*) ;; *) continue ;; esac
  alternation="${alternation:+$alternation|}$(instruction_ere_escape "$path")"
done < <(instruction_all_paths "$HOME" "$cwd" '' "$command")

dir_alternation=''
while IFS= read -r path; do
  case "$command" in *"$path"/*) ;; *) continue ;; esac
  dir_alternation="${dir_alternation:+$dir_alternation|}$(instruction_ere_escape "$path")"
done < <(instruction_all_dirs "$HOME" "$cwd")
# Matched by name as well as by path: there is no list of every repository, and a project's
# own CLAUDE.md or MEMORY.md costs the same per read as the global one.
by_name="([^[:space:];|&'\"]*/)?${INSTRUCTION_GUARDED_BASENAMES}"
by_claude="([^[:space:];|&'\"]*/)?\.claude/[^[:space:];|&'\"]*$(instruction_md_ere)"
# A file that does not exist yet is a file every later session still pays for, so the guarded
# directories are matched as well as the guarded files. `> new.md` typed from INSIDE such a
# directory carries no directory at all and stays the tripwire's job.
by_dir=''
[ -n "$dir_alternation" ] && by_dir="(${dir_alternation})/[^[:space:];|&'\"]*$(instruction_md_ere)|"
TARGET="(${alternation:+$alternation|}${by_dir}${by_claude}|${by_name})"

# Destinations are read off the command with its heredoc bodies dropped and its quoted runs
# resolved (instruction_shell_scan in the shared module). A guarded name a command merely CARRIES
# — a scratchpad heredoc quoting a rule, a commit message, a note appended to a log — is data, and
# reading it as a destination denied ordinary work while saying nothing true about what the command
# wrote. A shell interpreter in the command line turns that quoted text back into a program, and a
# command-position word the scan cannot resolve may be one, so both fall back to the raw command.
scan=$(printf '%s' "$command" | instruction_shell_scan 2>/dev/null) || scan=''
[ -n "$scan" ] || scan=$command
if printf '%s' "$scan" | grep -Eq "$INSTRUCTION_INTERPRETER_RE|$INSTRUCTION_CMD_POSITION_RE"; then
  scan=$command
fi
case "$command" in *"\$'"*) scan=$command ;; esac

# grep is line-based, and a heredoc puts the interpreter on one line and the open() on the next.
# Flattening keeps them in one pipeline stage; the cost is that two unrelated commands on two
# lines can look like one, which is a denial too many rather than a write too few.
flat=${command//$'\n'/ }
# The interpreter shapes are the shared module's, asked here and by the tripwire alike
# (`instruction_interp_write_re`): the parse below can only say an interpreter NAMED the file, and
# a second spelling of what makes that a write is a one-liner one door denies and the other never
# rolls back.
interp_write=$(instruction_interp_write_re "$TARGET")

# The name is taken from inside the construct that matched, not from the whole line: a name that
# stands elsewhere in the command belongs to the arguments, and reporting it would point Egor at
# a file the command never wrote and key the retry stamp on it. An interpreter construct ENDS at
# its destination, so the LAST name inside it is the one written — `shutil.copy(src, dst)` names
# a guarded file twice and only the second is a write.
name_in() {
  local name
  name=$(printf '%s' "$1" | grep -Eio "$TARGET" | tail -n 1)
  [ -n "$name" ] || return 1
  # The extractor runs on the unbounded TARGET, so a quote or a delimiter never rides along.
  printf '%s' "${name%%[\"\'[:space:]]*}"
}

# Egor's autonomy span, asked at most once and only about a row that could answer to it: the
# reader sources a 90 KB library and walks the whole transcript.
autonomous=''
span_active() {
  if [ -z "$autonomous" ]; then
    if instruction_autonomous "$sid" "$transcript"; then autonomous=yes; else autonomous=no; fi
  fi
  [ "$autonomous" = yes ]
}

# Inside Egor's autonomy span the on-demand instruction files may be RESHAPED but not grown: he is
# away, the model is the only actor, and a write that replaces a doc's bytes is exactly the cleanup
# he left it — while an append can only add to a file every later session re-reads. What this gate
# can know before the call is the SHAPE of the write; what the bytes come to is settled afterwards
# by the tripwire, which puts back growth this session's own call produced. The every-session class
# and the review-debt list are out of it entirely: both are denied always.
#
# Returns 0 for a REFUSED destination and publishes the state the denial is written from. realpath
# runs here and nowhere else, and only for a name that already matched a guarded spelling.
hit=''; class=''; span=''; abs=''; abs_real=''
judge_row() { # name mode [verb]
  local row_abs row_real row_class row_span=''
  row_abs=$1
  case "$row_abs" in
    '~/'*)       row_abs="$HOME/${row_abs#\~/}" ;;
    '$HOME/'*)   row_abs="$HOME/${row_abs#\$HOME/}" ;;
    '${HOME}/'*) row_abs="$HOME/${row_abs#\$\{HOME\}/}" ;;
    /*) ;;
    *) row_abs="${cwd:-$PWD}/${row_abs#./}" ;;
  esac
  case "${3:-}" in */) [ -d "${row_abs%/*}" ] || return 1 ;; esac
  row_real=$(realpath "$row_abs" 2>/dev/null)
  instruction_carved_out "${row_real:-$row_abs}" "$HOME" && return 1
  # An empty class is a path no gate speaks for — settings.json above all, which the tripwire
  # watches and nothing denies.
  row_class=$(instruction_write_class "${row_real:-$row_abs}")
  [ -n "$row_class" ] || return 1
  if [ "$row_class" = span ] && span_active; then
    row_span=1
    [ "$2" = trunc ] && return 1
  fi
  hit=$1; class=$row_class; span=$row_span; abs=$row_abs; abs_real=$row_real
  return 0
}

# Where the command leaves its bytes, from the ONE parse both doors ask
# (`instruction_write_targets`). The rows this gate speaks for: a redirection, tee, a copy verb,
# dd and patch. The in-place editors and the loose interpreter rows are the tripwire's, and an
# interpreter is judged by the shared shapes above instead, because a name merely CARRIED inside a
# payload is not a destination. A `refuse` row is a destination whose name holds a tab or a newline:
# no check here can hold it, so the call is refused outright.
# EVERY row is judged, and each against its OWN shape. A class read off the FIRST row while the
# shrink shape was read off ANY row is how `tee -a ~/.claude/docs/a.md; : > ~/.claude/docs/b.md`
# passed inside the span: the second row can shrink its file, so the first row grew its own
# unasked. The first refused row is the one the denial speaks about.
denied=''
row_sep=$(printf '\t')
while IFS=$row_sep read -r row_kind row_mode row_verb row_name; do
  [ -n "$row_name" ] || continue
  case "$row_kind" in
    redirect|copy) ;;
    refuse)
      echo "instruction write gate: this command writes to a path holding a tab or a newline ($row_name) under an instruction-file location; no gate can check such a name, so it is refused. Use a plain name." >&2
      exit 2
      ;;
    verb) case "$row_verb" in tee|gtee|dd|patch) ;; *) continue ;; esac ;;
    *) continue ;;
  esac
  [ -n "$denied" ] && continue
  judge_row "$row_name" "$row_mode" "$row_verb" && denied=1
done < <(instruction_write_targets "$scan" "$TARGET")
# The interpreter rows the same way: EVERY construct, each against its own shape. One match of
# the whole rule reaches from the interpreter to the last construct on the line, so a mode read
# off it and a name taken from its front belong to two different writes — that is how in-span
# `python3 -c "open(<doc>,'w')"; python3 -c "open(CLAUDE.md,'a')"` passed, the append judged as
# the truncation before it.
if [ -z "$denied" ] && printf '%s' "$flat" | grep -Eiq "${interp_write}"; then
  interp_cons=$(instruction_interp_write_construct_re "$TARGET")
  interp_cons_trunc=$(instruction_interp_trunc_construct_re "$TARGET")
  while IFS= read -r construct; do
    [ -n "$construct" ] || continue
    interp_name=$(name_in "$construct") || continue
    interp_mode=append
    printf '%s' "$construct" | grep -Eiq "$interp_cons_trunc" && interp_mode=trunc
    if judge_row "$interp_name" "$interp_mode"; then
      denied=1
      break
    fi
  done < <(printf '%s' "$flat" | grep -Eio "$interp_cons")
fi
[ -n "$denied" ] || exit 0

# A relay worker gets no stamp and no honour path: the retry both doors grant is for the chat Egor
# negotiated with, and a worker spends it by asking twice. The review-debt list keeps its own
# reason below — what a line in it retires is a review, not a context window.
case "$class" in
  always|span) instruction_in_relay && { instruction_relay_refusal "$hit" >&2; exit 2; } ;;
esac

# The session is part of the key: a parallel chat spending its own retry must not spend this
# one's, and a later session must not inherit approval Egor gave in an earlier turn.
hash=$(printf '%s\n%s\n%s\n' "$sid" "$hit" "$command" | shasum -a 256 | cut -c1-16)
if instruction_stamp_ready "$STAMP_DIR" "$hash"; then
  if instruction_user_turn_after_stamp "$transcript" "$STAMP_DIR/$hash"; then
    instruction_stamp_consume "$STAMP_DIR" "$hash" && exit 0
  fi
fi

# The number has to be the one THIS file costs. A skill and an agent doc are a factor of thirty
# apart, and one blanket figure quoted at every class makes the arithmetic the denial asks for
# wrong before it starts.
reads=$(instruction_read_rate "$abs" "$HOME")
# The global file answers to the repository path behind its symlink as well, and that spelling
# prices as an ordinary project file — a fifth of the real cost.
global_real=$(realpath "$HOME/.claude/CLAUDE.md" 2>/dev/null)
[ -n "$abs_real" ] && [ -n "$global_real" ] && [ "$abs_real" = "$global_real" ] && reads=15682
# The docs/agents/instructions/skills trees answer to repository spellings too, and those
# matched no class at all — a denial demanding cost arithmetic while withholding the number.
if [ -z "$reads" ] && [ -n "$abs_real" ]; then
  while IFS= read -r class_dir; do
    class_real=$(realpath "$class_dir" 2>/dev/null) && [ -n "$class_real" ] || continue
    case "$abs_real" in
      "$class_real"/*)
        reads=$(instruction_read_rate "$class_dir/${abs_real#"$class_real"/}" "$HOME")
        break ;;
    esac
  done < <(_instruction_class_dirs "$HOME")
fi
# The measured rate outranks the frozen one here for the same reason it does in the bloat gate:
# two gates quoting different numbers for the same file teach their reader that neither is real.
# Identity before spelling: a repo-path spelling of the global file must never take the project
# lookup, or its denial quotes that directory's rate instead of the global one.
if [ -n "$abs_real" ] && [ -n "$global_real" ] && [ "$abs_real" = "$global_real" ]; then
  live_info=$(instruction_live_rates "$HOME/.claude/CLAUDE.md" "$HOME")
else
  live_info=$(instruction_live_rates "$abs" "$HOME")
fi
cost=''
if [ -n "$live_info" ]; then
  IFS='|' read -r rate_state weekly_reads monthly_reads cheap_floor <<< "$live_info"
else
  rate_state=''
fi
# A memory file's recalls leave no path behind, so what the index holds for one is the odd
# hand-opened copy. Both gates drop it for the same reason, or the two quote different numbers for
# the file and teach their reader that neither is real.
if instruction_index_blind "$abs"; then
  rate_state=''
fi
round_rate() {
  instruction_display_rate "$1"
}
weekly_display=''
monthly_display=''
if [ "$rate_state" = measured ]; then
  weekly_display=$(round_rate "$weekly_reads") || weekly_display=''
  monthly_display=$(round_rate "$monthly_reads") || monthly_display=''
  [ -n "$weekly_display" ] && [ -n "$monthly_display" ] && reads=$monthly_display
elif [ "$rate_state" = legacy ]; then
  live=$(jq -nr --argjson n "$monthly_reads" '$n | if . < 1 then 1 else round end' 2>/dev/null) || live=''
  [ -z "$live" ] || reads=$live
fi
# A measured file has both windows already; a class constant has only the month, and the week is
# the same seventh-of-thirty rescale the export applies. Every figure goes through the display
# ladder, constants included: this gate and the bloat gate quote the same file in the same turn,
# and the moment their numbers differ a reader learns that neither is worth acting on.
if [ -z "$monthly_display" ] && [ -n "$reads" ]; then
  monthly_display=$(round_rate "$reads") || monthly_display=''
  weekly_display=$(round_rate "$(jq -nr --argjson n "$reads" '$n * 7 / 30' 2>/dev/null)") || weekly_display=''
fi
if [ -n "$weekly_display" ] && [ -n "$monthly_display" ]; then
  # Only a measured file has a row to look up. Sending a reader to `tokenmap reads` for a price
  # that came from a class constant costs them a command that answers nothing.
  lookup=''
  [ "$rate_state" = measured ] && lookup="; check tokenmap reads $abs"
  cost=" (re-read ~$(instruction_times "$(instruction_format_count "$weekly_display")") a week, ~$(instruction_times "$(instruction_format_count "$monthly_display")") a month, so every token added here is paid for that many times over${lookup})"
fi

case "$class" in
  debt)
    # Not a cost at all, so no figure is quoted: the file is two lines long and the reason it is
    # guarded is what a line in it DOES.
    reason="Instruction gate: $hit is the review-debt ignore list — the ONE way a path leaves review debt, so a line written into it retires unreviewed work. That is the project's answer and never a model's, inside Egor's autonomy span as much as outside it: settle the debt by review, or put the case for a waiver to him in one line and wait. With his OK the identical command passes on retry."
    ;;
  *)
    if [ -n "$span" ]; then
      reason="Instruction gate: this command ADDS to $hit rather than replacing it$cost. Egor's autonomy span covers reshaping these files, never growing them: while it stands, a write that leaves the file no larger passes here unasked, and growth of an instruction file waits for him. Rewrite the whole file smaller if the change is a net cut; otherwise keep the addition for his next turn and say so in one line. The tripwire measures the bytes either way and puts back growth this session produced."
    else
      reason="Instruction gate: this command writes to $hit, a file LLMs re-read across sessions$cost. Egor's standing rule is that these files are read-only without his explicit OK in the current turn, and that rule binds every tool equally — a shell write is not a way around a denied Edit. If the change is genuinely needed: state the byte delta, the weekly token cost with monthly context, what the change SAVES, ask him, and wait. With his OK the identical command passes on retry."
    fi
    ;;
esac

jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null || true
exit 0
