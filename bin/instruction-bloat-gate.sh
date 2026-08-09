#!/usr/bin/env bash
# Growth gate for files LLMs re-read across sessions. Any growth beyond the
# threshold is denied ONCE with the recurring token cost quoted; the same edit
# passes on retry once the transcript shows the file re-read after that denial
# (the deny is the "audit it, then tell Egor" step, not a wall).
set -u

[ -n "${HOME:-}" ] || exit 0

THRESHOLD_BYTES=120
# Measured over this corpus: 3.2 UTF-8 bytes per token for instruction-file prose. The 4 this
# replaced was a guess that understated every quoted cost by a quarter.
CHARS_PER_TOKEN=3.2
# 85k tokens/week keeps the global CLAUDE.md, at ~2237 weekly limit units, on today's 120-byte
# gate. Recalibrate this alongside any change to what the rate export counts, or every threshold
# in the ladder silently moves with it.
WEEKLY_TOKEN_BUDGET=85000
STAMP_DIR="${INSTRUCTION_BLOAT_GATE_STAMPS:-$HOME/.cache/claude-instruction-gate}"

# ~/.claude/hooks is a symlink into the config repository and the entry there is a symlink into
# this one, so follow the chain rather than the first hop.
self=$0
for _ in 1 2 3 4 5; do
  [ -L "$self" ] || break
  target=$(readlink "$self")
  case "$target" in /*) self=$target ;; *) self=$(dirname "$self")/$target ;; esac
done
. "$(dirname "$self")/../share/instruction-files.sh" 2>/dev/null || exit 0

# A size warning about the global file is not a decision of its own: the edit may still be priced,
# denied and retried, so the note rides along with whatever this gate ends up saying.
ceiling_note=''

deny() {
  local reason=$1
  [ -n "$ceiling_note" ] && reason="$reason $ceiling_note"
  jq -cn --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null || true
  exit 0
}

pass() {
  [ -n "$ceiling_note" ] && jq -cn --arg c "$ceiling_note" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null
  exit 0
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/instruction-gate.XXXXXX") || exit 0
trap 'rm -rf "$tmp_dir" 2>/dev/null' EXIT
input_file="$tmp_dir/input.json"
cat >"$input_file" || exit 0

jq -e '
  (.tool_name == "Edit" or .tool_name == "Write")
  and (.tool_input | type == "object")
  and (.tool_input.file_path | type == "string")
' "$input_file" >/dev/null 2>&1 || exit 0

file_path=$(jq -r '.tool_input.file_path' "$input_file" 2>/dev/null) || exit 0
case "$file_path" in
  /*) ;;
  *)
    cwd=$(jq -r '.cwd // ""' "$input_file" 2>/dev/null) || exit 0
    [ -n "$cwd" ] || exit 0
    file_path="$cwd/$file_path"
    ;;
esac

# Full-price read equivalents per month, measured over the 31 days to 2026-07-31
# (1954 sessions, 132386 requests). The numbers look large because content in the
# cached system prefix is re-read on EVERY request at 0.1x, not once per session:
# 0.1 * requests + 1.25 * sessions. On-demand classes are measured loads times
# (1.25 + 0.1 * requests left in the session) — two orders of magnitude cheaper,
# which is why moving prose out of an always-on file is the whole game.
# Only the global CLAUDE.md is in EVERY session. A project's CLAUDE.md or memory index rides
# along in that project's sessions alone: the busiest measured project ran 389 of the 1954,
# so 8.05 * 389. Quieter projects cost proportionally less; this is the ceiling, not the mean.
GLOBAL_CLAUDE="$HOME/.claude/CLAUDE.md"
GLOBAL_CLAUDE_REAL=$(realpath "$GLOBAL_CLAUDE" 2>/dev/null) || GLOBAL_CLAUDE_REAL=$GLOBAL_CLAUDE
is_global() {
  case "$1" in "$GLOBAL_CLAUDE"|"$GLOBAL_CLAUDE_REAL") return 0 ;; esac
  return 1
}
# The per-class rates live in share/instruction-files.sh, so the write gate's denial and this
# one's arithmetic cannot drift apart.
# The global file answers to more names than two: every profile directory carries its own symlink
# to it. Asking the generic project pattern first would price all of those at a fifth of the real
# cost, so the question "is this the global one" is settled before anything else — and settled on
# the resolved name, which is the only spelling they all share.
reads=''
live=''
rate_state=''
weekly_reads=''
monthly_reads=''
cheap_floor=''
global=''
if is_global "$file_path"; then
  global=1
else
  case "$file_path" in
    */CLAUDE.md)
      file_real=$(realpath "$file_path" 2>/dev/null)
      [ -n "$file_real" ] && is_global "$file_real" && global=1
      ;;
  esac
fi
# Which class the file belongs to is settled from its name alone, before any rate is asked for: the
# English-only rule and the global file's ceiling are not prices, and neither may lapse because the
# local index happens to have no figure for this file today.
if [ -n "$global" ]; then
  class_reads=15682
else
  class_reads=$(instruction_read_rate "$file_path" "$HOME")
fi
# ~/.claude/docs and ~/.claude/agents are symlinks into the config repository, so the same file
# has a second absolute path that matches none of the patterns above — and that repository path
# is the one anybody editing the repo actually types. Resolving the directory (not the file:
# a Write may be creating it) is what closes that.
if [ -z "$class_reads" ]; then
  case "$file_path" in
    *.md)
      # A Write creates the file, and may be creating its directory too, so the walk goes up to
      # the nearest ancestor that exists: a new subdirectory of docs/ is still under docs/.
      # CDPATH makes cd print where it landed, which would ride along in the captured path.
      probe=$(dirname "$file_path")
      file_dir=''
      while [ -n "$probe" ] && [ "$probe" != / ] && [ "$probe" != . ]; do
        file_dir=$(CDPATH= cd -- "$probe" 2>/dev/null && pwd -P) && [ -n "$file_dir" ] && break
        file_dir=''
        probe=$(dirname "$probe")
      done
      if [ -n "$file_dir" ]; then
        for pair in docs:160 agents:2500 instructions:160 skills:90 commands:90; do
          guarded=$(CDPATH= cd -- "$HOME/.claude/${pair%%:*}" 2>/dev/null && pwd -P) || continue
          [ -n "$guarded" ] || continue
          case "$file_dir" in "$guarded"|"$guarded"/*) class_reads=${pair##*:}; break ;; esac
        done
      fi
      ;;
  esac
fi
# This hook runs before every Edit and every Write in every session, so what it does for a file it
# will never price has to be nothing. Only markdown is ever measured (the export indexes no other
# extension) and only markdown carries a class rate, so a source file with neither leaves here
# rather than paying for a Cyrillic scan and a lookup over the whole rate index.
case "$file_path" in
  *.md|*.markdown) ;;
  *) [ -n "$class_reads" ] || [ -n "$global" ] || exit 0 ;;
esac

# Every guarded instruction file is English-only. Russian survives only inside «...», which is how a
# verbatim user phrase — a trigger word Egor actually types — is marked, and the only reason one of
# these files would carry Cyrillic at all.
cyrillic=$(jq -r '
  (if .tool_name == "Edit" then .tool_input.new_string else .tool_input.content end)
  | if type == "string" then gsub("«[^»]*»"; "") else "" end
  | if test("[А-Яа-яЁё]") then "yes" else "no" end
' "$input_file" 2>/dev/null) || cyrillic=''
if [ -n "$class_reads" ] && [ "$cyrillic" = "yes" ]; then
  deny "${file_path} is English-only. Russian is allowed only inside «...»-quoted verbatim user phrases."
fi

# All sizes in UTF-8 bytes via files + wc -c; jq's `length` counts codepoints
# and silently understates multibyte (Cyrillic) growth against the threshold.
tool_name=$(jq -r '.tool_name' "$input_file" 2>/dev/null) || exit 0
if [ "$tool_name" = "Write" ]; then
  jq -j '.tool_input.content // ""' "$input_file" >"$tmp_dir/new" 2>/dev/null || exit 0
  new_bytes=$(wc -c <"$tmp_dir/new" | tr -d '[:space:]')
  old_bytes=0
  [ -f "$file_path" ] && old_bytes=$(wc -c <"$file_path" | tr -d '[:space:]')
  delta=$((new_bytes - old_bytes))
else
  jq -e '(.tool_input.old_string | type == "string") and (.tool_input.new_string | type == "string")' \
    "$input_file" >/dev/null 2>&1 || exit 0
  jq -j '.tool_input.old_string' "$input_file" >"$tmp_dir/old" 2>/dev/null || exit 0
  jq -j '.tool_input.new_string' "$input_file" >"$tmp_dir/new" 2>/dev/null || exit 0
  old_len=$(wc -c <"$tmp_dir/old" | tr -d '[:space:]')
  new_len=$(wc -c <"$tmp_dir/new" | tr -d '[:space:]')
  delta=$((new_len - old_len))
  replace_all=$(jq -r '.tool_input.replace_all // false' "$input_file" 2>/dev/null) || exit 0
  if [ "$replace_all" = "true" ] && [ -f "$file_path" ] && [ "$old_len" -gt 0 ]; then
    count=$(perl -e '
      local $/; open my $f, "<", $ARGV[0] or exit; my $hay = <$f>;
      open my $n, "<", $ARGV[1] or exit; my $needle = <$n>;
      exit unless defined $hay && defined $needle && length $needle;
      my $c = 0; my $pos = 0;
      while (($pos = index($hay, $needle, $pos)) != -1) { $c++; $pos += length $needle }
      print $c;
    ' "$file_path" "$tmp_dir/old" 2>/dev/null)
    [ -n "$count" ] && [ "$count" -gt 1 ] 2>/dev/null && delta=$((delta * count))
  fi
fi

# The global file's ceiling, checked before the retry stamp is ever consulted: the audit-then-retry
# ritual below is a speed bump for ordinary growth, and it must not be a way past a hard cap.
if [ -n "$global" ] && [ "$delta" -gt 0 ] 2>/dev/null; then
  current_bytes=0
  [ -f "$file_path" ] && current_bytes=$(wc -c <"$file_path" | tr -d '[:space:]')
  case "$current_bytes" in ''|*[!0-9]*) current_bytes=0 ;; esac
  prospective=$((current_bytes + delta))
  bound="Keep it bounded: put new detail in an on-demand instruction document and leave only a pointer in global CLAUDE.md."
  if [ "$prospective" -gt "$INSTRUCTION_GLOBAL_HARD_BYTES" ] 2>/dev/null; then
    deny "Global CLAUDE.md would be ${prospective} bytes, past its ${INSTRUCTION_GLOBAL_HARD_BYTES}-byte ceiling. ${bound} An edit that shrinks the file passes at any size; this one grows it."
  fi
  if [ "$prospective" -gt "$INSTRUCTION_GLOBAL_WARN_BYTES" ] 2>/dev/null; then
    ceiling_note="Global CLAUDE.md would be ${prospective} bytes. ${bound}"
  fi
fi

# Nothing below the base threshold is ever denied: a measured rate only raises the bound above it,
# and the cheap notice speaks past it too. Deciding that here is what keeps an ordinary edit to an
# ordinary markdown file — which every session makes, on the pre-tool path — from paying for a
# lookup over the whole rate index to be told what its size already settled.
[ "$delta" -gt "$THRESHOLD_BYTES" ] 2>/dev/null || pass

# The global identity is settled before its spelling, so a repository path behind the symlink
# cannot take a project rate. Current path entries carry both windows; old exports retain their
# original monthly always-on lookup until the producer's next run.
if [ -n "$global" ]; then
  rate_info=$(instruction_live_rates "$GLOBAL_CLAUDE" "$HOME")
else
  rate_info=$(instruction_live_rates "$file_path" "$HOME")
fi
if [ -n "$rate_info" ]; then
  IFS='|' read -r rate_state weekly_reads monthly_reads cheap_floor <<< "$rate_info"
fi
# What loads a memory file leaves no path behind, so whatever the index holds for one is the odd
# hand-opened copy and nothing else. Preferring it — as every other class rightly does, a
# measurement being the whole point of this gate — would price the file at a number that measures
# how often it was inspected rather than how often it is read to Egor's model.
if instruction_index_blind "$file_path"; then
  rate_state=''
  weekly_reads=''
fi
# "Cheap" is a claim about a file nothing else in the export accounts for, and it is decided from
# the export alone — which knows nothing about the classes resolved above, because those live in
# this gate's own symlink walk. A skill or an agent brief the index has never recorded is not a
# file of unknown value; it is a file whose class already names its price, and answering "cheap"
# for it waves through exactly the growth the class constant exists to price.
if [ "$rate_state" = cheap ] && [ -n "$class_reads" ]; then
  rate_state=''
fi
display_rate() {
  instruction_display_rate "$1"
}
display_floor() {
  jq -nr --argjson n "$1" '$n | if . < 10 then ((. * 100 | round) / 100) else round end' 2>/dev/null
}
fallback_rate() {
  jq -nr --argjson n "$1" '$n | if . < 1 then 1 else round end' 2>/dev/null
}
case "$rate_state" in
  measured)
    weekly_display=$(display_rate "$weekly_reads") || pass
    monthly_display=$(display_rate "$monthly_reads") || pass
    reads=$monthly_display
    live=1
    ;;
  legacy)
    reads=$(fallback_rate "$monthly_reads") || pass
    live=legacy
    ;;
  cheap) ;;
  *) reads=$class_reads ;;
esac
[ -n "$reads" ] || [ "$rate_state" = cheap ] || pass

if [ "$rate_state" = cheap ]; then
  if [ "$delta" -gt "$THRESHOLD_BYTES" ] 2>/dev/null; then
    cheap_display=$(display_floor "$cheap_floor") || pass
    sid=$(jq -r '.session_id // ""' "$input_file" 2>/dev/null) || sid=''
    notice_hash=$(printf '%s\n%s\n' "$sid" "$file_path" | shasum -a 256 | cut -c1-16)
    if instruction_mark_once "$STAMP_DIR/notices" "$notice_hash"; then
      case "$cheap_display" in
        1) unit="limit unit" ;;
        *) unit="limit units" ;;
      esac
      ceiling_note="${file_path} is below ~${cheap_display} ${unit}/month; not gated."
    fi
  fi
  pass
fi

threshold=$THRESHOLD_BYTES
# A weekly rate of zero under a positive monthly one cannot happen while the export rescales one
# from the other, and if it ever does it is a broken measurement, not a free file: the derived
# threshold is skipped and the base one still applies. Passing on it waived the gate outright.
weekly_zero=$(jq -nr --argjson reads "${weekly_reads:-0}" '$reads == 0' 2>/dev/null) || weekly_zero=false
if [ "$rate_state" = measured ] && [ "$weekly_zero" != true ]; then
  # Snapped down to a coarse ladder for the same reason the displayed rate is: a threshold
  # recomputed from a sliding window would otherwise move a few bytes every night, and the
  # boundary between a passing and a denied edit is exactly where that must not happen.
  derived=$(jq -nr --argjson budget "$WEEKLY_TOKEN_BUDGET" --argjson reads "$weekly_reads" \
    --argjson per_token "$CHARS_PER_TOKEN" \
    '[120, 250, 500, 1000, 2000, 5000, 10000, 25000, 50000, 100000]
     | map(select(. <= ($budget * $per_token / $reads))) | last // 120' 2>/dev/null) || derived=''
  case "$derived" in ''|*[!0-9]*) derived=$THRESHOLD_BYTES ;; esac
  [ "$derived" -gt "$threshold" ] 2>/dev/null && threshold=$derived
fi
[ "$delta" -gt "$threshold" ] 2>/dev/null || pass

# The session is part of the key, exactly as it is in the write gate: approval Egor gave in one
# chat is not approval a parallel or later one inherits for the same edit.
# -S sorts the keys: the retry is the same edit, but nothing promises it arrives with its JSON
# keys in the same order, and an unsorted fingerprint would deny the very retry it exists to pass.
sid=$(jq -r '.session_id // ""' "$input_file" 2>/dev/null) || sid=''
hash=$(printf '%s\n%s\n%s\n' "$sid" "$file_path" "$(jq -Sc '.tool_input' "$input_file" 2>/dev/null)" | shasum -a 256 | cut -c1-16)
note="$STAMP_DIR/$hash.read"

# The denial asks for an audit of the whole file, so the retry is only a retry once the file has
# actually been re-read: the transcript is searched past the byte it stood at when the denial went
# out, and a read from before it is not that audit. Everything this cannot establish for itself —
# no transcript in the payload, no note, one written against another transcript, jq refusing the
# tail — counts as read. A gate that bricks editing whenever a path it does not own is missing is
# worse than one that lets an unaudited retry through.
retry_read_seen() {
  local size='' recorded='' transcript='' now='' target_real='' seen='' cand='' cand_real=''
  [ -f "$note" ] || return 0
  { IFS= read -r size && IFS= read -r recorded; } <"$note" 2>/dev/null || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  transcript=$(jq -r '.transcript_path // ""' "$input_file" 2>/dev/null) || return 0
  [ -n "$transcript" ] && [ -f "$transcript" ] && [ "$transcript" = "$recorded" ] || return 0
  # A transcript shorter than the byte the note remembers was truncated or rotated under the same
  # name, and every read this gate could have verified went with it: the tail is empty from here
  # on, which would deny the retry forever rather than once.
  now=$(wc -c <"$transcript" 2>/dev/null | tr -d '[:space:]')
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -le "$now" ] || return 0
  seen=$(tail -c "+$((size + 1))" "$transcript" 2>/dev/null | jq -R -r '
    (fromjson? // empty)
    | (.message.content? // empty)
    | select(type == "array") | .[]
    | select(type == "object" and .type == "tool_use" and .name == "Read")
    # A ranged read is not the audit the denial asked for, and the message promises the check is
    # mechanical: only a read of the whole file, which carries neither bound, answers it.
    | select((.input.offset? // null) == null and (.input.limit? // null) == null)
    | .input.file_path? | strings
  ' 2>/dev/null) || return 0
  # An instruction file is reached through a symlink as often as by its own name, and the read and
  # the edit rarely pick the same spelling, so both sides are compared resolved as well as typed.
  target_real=$(realpath "$file_path" 2>/dev/null) || target_real=$file_path
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    # The tool takes a tilde path and records it unexpanded, and realpath resolves it against the
    # working directory instead of $HOME, so the spelling has to be undone here.
    case "$cand" in "~/"*) cand="$HOME/${cand#\~/}" ;; esac
    case "$cand" in "$file_path"|"$target_real") return 0 ;; esac
    cand_real=$(realpath "$cand" 2>/dev/null) || continue
    case "$cand_real" in "$file_path"|"$target_real") return 0 ;; esac
  done <<SEEN
$seen
SEEN
  return 1
}

if instruction_stamp_ready "$STAMP_DIR" "$hash"; then
  if retry_read_seen; then
    rm -f "$note" 2>/dev/null
    instruction_stamp_consume "$STAMP_DIR" "$hash" && pass
  else
    deny "Gate retry requires re-reading the file first: Read ${file_path} in full, then retry the same edit — it will pass."
  fi
fi

# Where the transcript stands at the moment of the denial, so the read that answers it can be told
# from one that came before. Rewritten every time, never only when absent: a note the sweep
# outlived its stamp would otherwise let a day-old read answer today's denial. The retry that is
# refused for want of a read leaves before this point, so what a pending audit has to beat is
# always the newest denial. A file that does not exist yet has nothing to re-read, and leaving the
# note unwritten is what lets that retry pass on its own.
if [ -f "$file_path" ]; then
  transcript_now=$(jq -r '.transcript_path // ""' "$input_file" 2>/dev/null) || transcript_now=''
  if [ -n "$transcript_now" ] && [ -f "$transcript_now" ]; then
    size_now=$(wc -c <"$transcript_now" 2>/dev/null | tr -d '[:space:]')
    case "$size_now" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n%s\n' "$size_now" "$transcript_now" >"$note" 2>/dev/null || true ;;
    esac
  fi
fi

tokens=$(jq -nr --argjson d "$delta" --argjson c "$CHARS_PER_TOKEN" '($d / $c) | round' 2>/dev/null) || exit 0
case "$tokens" in ''|*[!0-9]*) exit 0 ;; esac
# Multiplied from the SHOWN rate, not the measured one. The denial orders its reader to quote all
# three figures to Egor verbatim, so the token count, the re-read count and the cost have to be a
# sentence he can multiply out; snapping the product to the ladder a second time broke that —
# 1.3k tokens at 3,000 reads printed as 3M, not the 3.9M the two numbers beside it promise.
cost() {
  instruction_format_tokens "$(jq -nr --argjson t "$tokens" --argjson r "$1" '($t * $r) | round' 2>/dev/null)"
}
tokens_shown=$(instruction_format_tokens "$tokens")
if [ "$rate_state" != measured ]; then
  # Both headlines carry a weekly figure because the report the denial demands names one, and a
  # reader told to quote it verbatim and forbidden to derive its own has nowhere else to get it.
  # The rescale is the export's own: a month of measurement is the only window wide enough to
  # price a file, and a seventh-of-thirty slice of it is what a week of that behaviour costs.
  monthly_display=$(display_rate "$reads") || exit 0
  weekly_display=$(display_rate "$(jq -nr --argjson n "$reads" '$n * 7 / 30' 2>/dev/null)") || exit 0
fi
weekly=$(cost "$weekly_display") || exit 0
monthly=$(cost "$monthly_display") || exit 0
weekly_shown=$(instruction_times "$(instruction_format_count "$weekly_display")")
monthly_shown=$(instruction_times "$(instruction_format_count "$monthly_display")")
if [ "$rate_state" = measured ]; then
  measured='measured by the local read index; check tokenmap reads '"$file_path"
elif [ "$live" = legacy ]; then
  measured='measured by the local read index over its last 30-day window'
else
  measured='measured'
fi
headline="+${delta} bytes (~${tokens_shown} tokens) costs ~${weekly} tokens/week and ~${monthly}/month against the weekly usage limit, because this file re-enters the cached prefix ~${weekly_shown} a week and ~${monthly_shown} a month — every token added is paid for that many times over (${measured})."

deny "Instruction-bloat gate: ${headline} Protocol, fastest path first: (1) AUDIT — re-read the WHOLE file now and look for up to 3 lines that are stale, duplicated in another live surface, or restate what code/hooks already enforce (criteria: ~/.claude/docs/context-file-hygiene.md). A combined edit that adds your text AND cuts enough for net <= 0 passes immediately, no approval needed — name the cuts in your reply so Egor can veto them. (2) 'Nothing defensibly cuttable' is a fully valid audit outcome — NEVER cut a live rule to make room. In that case present Egor the NET BALANCE and wait for his explicit OK in this turn. Report it as exactly three lines in his language, quoting the figures from this message verbatim rather than deriving your own, and adding nothing else: line 1 COST — the file, the byte delta, the token delta, the weekly cost, the monthly cost; line 2 CUT — what you cut, or that nothing was safely cuttable; line 3 PAYS BACK — what the addition saves per month (avoided corrections, repeated output, worker calls), or that it does not pay for itself. A rule that saves less than it costs does not get written. (3) Content rules trump cost math: history/changelog, anything derivable from code, linter rules as prose, and defensive verification scaffolding are cut, not costed; prefer a hook/mechanical control over prose, and compress what remains. The gate verifies the audit mechanically: after this denial, Read the target file, then retry — the same edit passes once. A retry without that Read is denied again."
