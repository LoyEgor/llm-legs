#!/usr/bin/env bash
# Growth gate for files LLMs re-read across sessions. Any growth beyond the
# threshold is denied ONCE with the recurring token cost quoted; retrying the
# exact same edit passes (the deny is the "stop and tell Egor" step, not a wall).
set -u

[ -n "${HOME:-}" ] || exit 0

THRESHOLD_BYTES=120
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

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null || true
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
classify() {
  case "$1" in
    */MEMORY.md|*/CLAUDE.md|*/CLAUDE.local.md) printf 3131 ;;  # every session of one project
    */.claude/instructions/*) printf 160 ;;                    # loaded on topic
    */SKILL.md|*/.claude/skills/*) printf 90 ;;                # loaded on trigger
    "$HOME"/.claude/docs/*) printf 160 ;;                      # protocol docs, read per task type
    "$HOME"/.claude/agents/*) printf 2500 ;;                   # per spawn of a busy worker
  esac
}
# The global file answers to more names than two: every profile directory carries its own symlink
# to it. Asking the generic project pattern first would price all of those at a fifth of the real
# cost, so the question "is this the global one" is settled before anything else — and settled on
# the resolved name, which is the only spelling they all share.
reads=''
if is_global "$file_path"; then
  reads=15682
else
  case "$file_path" in
    */CLAUDE.md)
      file_real=$(realpath "$file_path" 2>/dev/null)
      [ -n "$file_real" ] && is_global "$file_real" && reads=15682
      ;;
  esac
fi
[ -n "$reads" ] || reads=$(classify "$file_path")
# ~/.claude/docs and ~/.claude/agents are symlinks into the config repository, so the same file
# has a second absolute path that matches none of the patterns above — and that repository path
# is the one anybody editing the repo actually types. Resolving the directory (not the file:
# a Write may be creating it) is what closes that.
if [ -z "$reads" ]; then
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
        for pair in docs:160 agents:2500 instructions:160 skills:90; do
          guarded=$(CDPATH= cd -- "$HOME/.claude/${pair%%:*}" 2>/dev/null && pwd -P) || continue
          [ -n "$guarded" ] || continue
          case "$file_dir" in "$guarded"|"$guarded"/*) reads=${pair##*:}; break ;; esac
        done
      fi
      ;;
  esac
fi
[ -n "$reads" ] || exit 0

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

[ "$delta" -gt "$THRESHOLD_BYTES" ] 2>/dev/null || exit 0

# The session is part of the key, exactly as it is in the write gate: approval Egor gave in one
# chat is not approval a parallel or later one inherits for the same edit.
# -S sorts the keys: the retry is the same edit, but nothing promises it arrives with its JSON
# keys in the same order, and an unsorted fingerprint would deny the very retry it exists to pass.
sid=$(jq -r '.session_id // ""' "$input_file" 2>/dev/null) || sid=''
hash=$(printf '%s\n%s\n%s\n' "$sid" "$file_path" "$(jq -Sc '.tool_input' "$input_file" 2>/dev/null)" | shasum -a 256 | cut -c1-16)
instruction_claim_stamp "$STAMP_DIR" "$hash" && exit 0

tokens=$((delta / 4))
monthly=$((tokens * reads))

deny "Instruction-bloat gate: LLMs re-read this file ~${reads}x/month at full-read price (measured; content in the cached prefix is re-read on every request, not once per session). Growth +${delta} bytes ≈ +${tokens} tokens per read ≈ ~${monthly} tokens/month at Egor's daily usage. His standing rule: (1) prefer a hook/mechanical control over prose; (2) if prose is genuinely required, compress it hard; (3) present Egor the NET BALANCE, not just this cost — estimate what the rule SAVES per month (avoided repeated output, avoided corrections, avoided worker calls) and compare; a rule that saves less than it costs does not get written. Content rules apply before cost math — history/changelog, anything derivable from the code, linter rules as prose, and defensive verification scaffolding are cut, not costed; keep/cut criteria: ~/.claude/docs/context-file-hygiene.md. Wait for his explicit OK, then retry the identical edit — the gate passes the exact retry once."
