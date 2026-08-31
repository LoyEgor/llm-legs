#!/usr/bin/env bash
# PreToolUse(Bash): the shell half of the instruction gate.
#
# Deliberately narrow, and narrower than it used to be. A shell command cannot be parsed for
# intent, and a matcher wide enough to try would deny `git checkout` in the very repositories
# these files live in, or refuse a plain `grep CLAUDE.md`. Four review rounds spent on the verbs
# whose destination has to be located inside an argument list produced most of this file's
# defects and, measured against a real month, almost none of its catches — so those verbs are
# gone. What remains are the three shapes where the target stands in a fixed place.
#
# This gate is a speed bump, not the guarantee. The guarantee is instruction-watch.sh, which
# reports every change however it was made and now keeps the previous bytes, so anything that
# slips past here is one command away from being put back.
#
# Not covered, on purpose: cp, mv, ln, rm, truncate, sed -i, perl -pi, ex, ed, patch, dd. Nor a
# path held in a variable, a name broken up by shell quoting (`> CLAUDE.m\d`), or a new file
# created by bare name from inside a guarded directory. The accepted false denials run the other
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
. "$(dirname "$self")/../share/instruction-files.sh" 2>/dev/null || exit 0

input=$(cat) || exit 0
values=$(printf '%s' "$input" | jq -r '
  [(.tool_name // ""), (.session_id // ""), (.cwd // ""), (.transcript_path // ""),
   (.tool_input.command // "")]
  | join("\u001f")' 2>/dev/null) || exit 0
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
case "$command" in
  *.md*|*.claude/*|*settings.json*|*review-debt-ignore*) ;;
  *) exit 0 ;;
esac

# Full ERE metacharacter set: a skill directory or a home path is free to contain (), + or ?,
# and an unescaped one silently changes what the pattern means.
ere_escape() { printf '%s' "$1" | sed 's#[][\.*^$/+?(){}|#]#\\&#g'; }

alternation=''
while IFS= read -r path; do
  case "$command" in *"$path"*) ;; *) continue ;; esac
  alternation="${alternation:+$alternation|}$(ere_escape "$path")"
done < <(instruction_all_paths "$HOME" "$cwd")

dir_alternation=''
while IFS= read -r path; do
  case "$command" in *"$path"/*) ;; *) continue ;; esac
  dir_alternation="${dir_alternation:+$dir_alternation|}$(ere_escape "$path")"
done < <(instruction_all_dirs "$HOME" "$cwd")
# Matched by name as well as by path: there is no list of every repository, and a project's
# own CLAUDE.md or MEMORY.md costs the same per read as the global one. Both ends are bounded,
# or `CLAUDE.md.backup-20260713` and `dummyCLAUDE.md` are denied as if they were the file
# itself — and this repository keeps exactly such backups.
# The backslash belongs in both classes: a path inside an escaped quote, which is how an
# interpreter one-liner is actually written, has \" pressed against it on both sides.
# No pipe in the start class. A guarded name pressed against one is a delimiter inside a script
# far more often than it is a target — `perl -pi -e 's|/x/MEMORY.md|y|' notes.txt` writes to
# notes.txt — and reading it as a target denied ordinary rewrites.
NAME_START="(^|[[:space:]>;&(=,\"'/\`\\\\])"
# The backtick and the closing brace end a name as surely as a space does: without them
# \`cp a CLAUDE.md\` and `{ cp a CLAUDE.md; }` had no character the name could end on.
NAME_END="($|[[:space:]>|;&),}\"'\`\\\\])"
by_name="([^[:space:];|&'\"]*/)?${INSTRUCTION_GUARDED_BASENAMES}"
# A file that does not exist yet is a file every later session still pays for, so the guarded
# directories are matched as well as the guarded files. `> new.md` typed from INSIDE such a
# directory carries no directory at all and stays the tripwire's job.
by_dir=''
[ -n "$dir_alternation" ] && by_dir="(${dir_alternation})/[^[:space:];|&'\"]*\.md|"
TARGET="(${alternation:+$alternation|}${by_dir}${by_name})"
BOUNDED="${NAME_START}['\"]?${TARGET}${NAME_END}"

# Three shapes, and only three. Over a measured month of 60372 shell commands 1709 named a
# guarded file, and of the 113 that wrote to one, 52 did it by redirection, 50 through an
# interpreter and 3 through tee. cp/mv/ln, rm/truncate and sed -i accounted for the remaining
# handful; ex, ed, patch and dd for none at all. Finding those verbs' destination inside an
# argument list is what every second defect in this file came from, so they are the tripwire's
# business now — it reports them however they are typed. What makes these three cheap is that
# the target stands in a fixed place: after the operator, after the verb, inside the open().
# Verb boundary: `add` is not `dd`. The slash belongs in the class because `/usr/bin/tee` is the
# same write typed another way, and the backtick and brace because so are `\`…\`` and `{ …; }`.
B="(^|[[:space:]|;&({\`/])"
# One run of arguments. It stops at a pipeline or the next command, and at # as well, because
# `tee a b # note about CLAUDE.md` names its target in a comment and is not a write to it.
ARG="[^|;&#]*"
# The verb's own space is a boundary, but BOUNDED wants to consume one of its own, and with a
# single space between them there is no character left: `tee CLAUDE.md` needs the form without
# a leading boundary of its own, `tee log.txt CLAUDE.md` the form with one.
FIRST="['\"]?${TARGET}${NAME_END}"
# `>|` is the same write as `>` with noclobber turned off, and it was the one redirection
# spelling the operator class did not cover.
redirect=">[>|]?[[:space:]]*['\"]?${TARGET}${NAME_END}"
# tee takes any number of destinations, so the guarded one may sit anywhere in its arguments.
tee="${B}g?tee[[:space:]](${FIRST}|${ARG}${BOUNDED})"
# An interpreter is a write only when the same command also carries a write mode AND names the
# file, all three within one pipeline stage: `python3 -c "open(other,'w')" | grep CLAUDE.md`
# satisfies all three across the pipe and is an ordinary read of nothing at all.
IW="${B}(python[0-9.]*|perl|ruby|node|bun|deno)[[:space:]][^|]*"
# The open mode is matched in argument position — after a comma, after `mode=`, or as the sole
# argument of .open() — because a bare 'a' or 'w' anywhere in the command denied
# `python3 -c "print('a'); print('CLAUDE.md')"`, an ordinary read.
# Every mode string that can write, letter order free: Python accepts 'bw' and '+rb' as readily
# as 'wb', so any string over rwaxbt+ counts once it carries a w, a, x or +. `r`, `rb` and their
# reorderings never reach one of those letters and stay out, which is the whole reason the modes
# are enumerated rather than matched loosely. Perl's spellings, `+>>` included, stand apart.
MODE="['\"]([rbt]*[wax+][rwaxbt+]*|>>?|\+[<>]>?)['\"]"
write_mode="([,=][[:space:]]*${MODE}|mode[[:space:]]*[:=][[:space:]]*${MODE}|\.open\(${MODE}|write_text|write_bytes|writelines|\.write\(|writeFile|appendFile|shutil\.copy|copyfile)"
# Reading a guarded file and printing it is not writing to it, and `.write(` alone said it was.
scrubbed=$command
for stream in sys.stdout sys.stderr process.stdout process.stderr; do
  scrubbed=${scrubbed//"$stream.write("/}
done
# grep is line-based, and a heredoc puts the interpreter on one line and the open() on the next.
# Flattening keeps them in one pipeline stage; the cost is that two unrelated commands on two
# lines can look like one, which is a denial too many rather than a write too few.
scrubbed=${scrubbed//$'\n'/ }

interp_write="${IW}${write_mode}[^|]*${BOUNDED}|${IW}${BOUNDED}[^|]*${write_mode}"

# The name is taken from inside the construct that matched, not from the whole line: a name that
# stands elsewhere in the command belongs to the arguments, and reporting it would point Egor at
# a file the command never wrote and key the retry stamp on it. `where` says which end of the
# matched text holds the destination.
name_in() {
  local text=$1 pattern=$2 where=$3 m name
  m=$(printf '%s' "$text" | grep -Eo "$pattern" | head -n 1)
  [ -n "$m" ] || return 1
  if [ "$where" = last ]; then
    name=$(printf '%s' "$m" | grep -Eo "$TARGET" | tail -n 1)
  else
    name=$(printf '%s' "$m" | grep -Eo "$TARGET" | head -n 1)
  fi
  # The extractor runs on the unbounded TARGET, so a quote or a delimiter never rides along.
  printf '%s' "${name%%[\"\'[:space:]]*}"
}

# One combined pass decides whether anything matched at all; the per-construct extraction below
# costs a process per rule and runs only once something has. This hook precedes every Bash call.
hit=''
if printf '%s' "$command" | grep -Eq "${redirect}|${tee}"; then
  # Both patterns end at their target, so the name to report is the last one inside the matched
  # text — an earlier one belongs to the arguments, as in `tee notes.md CLAUDE.md`.
  hit=$(name_in "$command" "$redirect" last)
  [ -n "$hit" ] || hit=$(name_in "$command" "$tee" last)
elif printf '%s' "$scrubbed" | grep -Eq "${interp_write}"; then
  hit=$(name_in "$scrubbed" "$interp_write" first)
fi
[ -n "$hit" ] || exit 0

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
# wrong before it starts. $hit is the spelling the command used, so it is expanded back to an
# absolute path first; realpath runs only here, on the denial, never on the hot path.
abs=$hit
case "$abs" in
  '~/'*)       abs="$HOME/${abs#\~/}" ;;
  '$HOME/'*)   abs="$HOME/${abs#\$HOME/}" ;;
  '${HOME}/'*) abs="$HOME/${abs#\$\{HOME\}/}" ;;
  /*) ;;
  *) abs="${cwd:-$PWD}/${abs#./}" ;;
esac
reads=$(instruction_read_rate "$abs" "$HOME")
# The global file answers to the repository path behind its symlink as well, and that spelling
# prices as an ordinary project file — a fifth of the real cost.
abs_real=$(realpath "$abs" 2>/dev/null)
global_real=$(realpath "$HOME/.claude/CLAUDE.md" 2>/dev/null)
[ -n "$abs_real" ] && [ -n "$global_real" ] && [ "$abs_real" = "$global_real" ] && reads=15682
# The docs/agents/instructions/skills trees answer to repository spellings too, and those
# matched no class at all — a denial demanding cost arithmetic while withholding the number.
if [ -z "$reads" ] && [ -n "$abs_real" ]; then
  for class_dir in docs agents instructions skills commands; do
    class_real=$(realpath "$HOME/.claude/$class_dir" 2>/dev/null) && [ -n "$class_real" ] ||
      continue
    case "$abs_real" in
      "$class_real"/*)
        reads=$(instruction_read_rate "$HOME/.claude/$class_dir/${abs_real#"$class_real"/}" "$HOME")
        break ;;
    esac
  done
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

jq -cn --arg r "Instruction gate: this command writes to $hit, a file LLMs re-read across sessions$cost. Egor's standing rule is that these files are read-only without his explicit OK in the current turn, and that rule binds every tool equally — a shell write is not a way around a denied Edit. If the change is genuinely needed: state the byte delta, the weekly token cost with monthly context, what the change SAVES, ask him, and wait. With his OK the identical command passes on retry." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null || true
exit 0
