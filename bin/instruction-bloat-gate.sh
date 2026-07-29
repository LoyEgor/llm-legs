#!/usr/bin/env bash
# Growth gate for files LLMs re-read across sessions. Any growth beyond the
# threshold is denied ONCE with the recurring token cost quoted; retrying the
# exact same edit passes (the deny is the "stop and tell Egor" step, not a wall).
set -u

[ -n "${HOME:-}" ] || exit 0

THRESHOLD_BYTES=120
STAMP_DIR="$HOME/.cache/claude-instruction-gate"

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

# Reads-per-month factor by how often the file class lands in a context window.
# Rough daily-use estimates; the point is the order of magnitude, not precision.
reads=0
case "$file_path" in
  */MEMORY.md|*/CLAUDE.md|*/CLAUDE.local.md) reads=240 ;;      # every session
  */.claude/instructions/*) reads=40 ;;                        # loaded on topic
  */SKILL.md|*/.claude/skills/*) reads=40 ;;                   # loaded on trigger
  "$HOME"/.claude/docs/*) reads=40 ;;                          # protocol docs, read per task type
  "$HOME"/.claude/agents/*) reads=150 ;;                       # per worker spawn
  *) exit 0 ;;
esac

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

hash=$(printf '%s\n%s\n' "$file_path" "$(jq -r '.tool_input | tostring' "$input_file" 2>/dev/null)" | shasum -a 256 | cut -c1-16)
mkdir -p "$STAMP_DIR" 2>/dev/null || exit 0
find "$STAMP_DIR" -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf {} + 2>/dev/null
stamp="$STAMP_DIR/$hash"
# mkdir is the atomic claim: creator denies, anyone finding it existing passes once.
if ! mkdir "$stamp" 2>/dev/null; then
  rmdir "$stamp" 2>/dev/null
  exit 0
fi

tokens=$((delta / 4))
monthly=$((tokens * reads))

deny "Instruction-bloat gate: this file is re-read by LLMs (~${reads} reads/month). Growth +${delta} bytes ≈ +${tokens} tokens per read ≈ ~${monthly} tokens/month at Egor's daily usage. His standing rule: (1) prefer a hook/mechanical control over prose; (2) if prose is genuinely required, compress it hard; (3) present Egor the NET BALANCE, not just this cost — estimate what the rule SAVES per month (avoided repeated output, avoided corrections, avoided worker calls) and compare; a rule that saves less than it costs does not get written. Wait for his explicit OK, then retry the identical edit — the gate passes the exact retry once."
