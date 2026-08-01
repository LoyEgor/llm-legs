#!/usr/bin/env bash
# Tripwire for the instruction files an LLM re-reads in every session.
#
# The Edit/Write gate can only see its own two tools. A shell write reaches the same
# bytes unseen — python3, sed -i, tee, cat >, a swapped symlink — and that is exactly
# how the gate was walked around on 2026-07-31. Parsing a shell command to stop that
# is not reliably possible (variables, $(), heredocs), and a parser wide enough to try
# would deny `git checkout` in the very repositories these files live in. A changed
# file, on the other hand, is a fact. So this reports rather than guesses.
#
# Hot path cost is one stat process per Bash call: globs and the baseline comparison
# are shell builtins, and a hash runs only for a file whose mtime or size moved.
set -u

[ -n "${HOME:-}" ] || exit 0

STATE_DIR="${INSTRUCTION_WATCH_STATE:-$HOME/.cache/claude-instruction-watch}"
LOG_FILE="${INSTRUCTION_WATCH_LOG:-$HOME/.claude/instruction-changes.log}"
ALERT="${INSTRUCTION_WATCH_ALERT:-hs}"

# ~/.claude/hooks is a symlink into the config repository and the entry there is a symlink
# into this one, so follow the chain rather than the first hop.
self=$0
for _ in 1 2 3 4 5; do
  [ -L "$self" ] || break
  target=$(readlink "$self")
  case "$target" in /*) self=$target ;; *) self=$(dirname "$self")/$target ;; esac
done
. "$(dirname "$self")/../share/instruction-files.sh" 2>/dev/null || exit 0

visible_paths() { instruction_visible_paths "$HOME"; }

# The harness rewrites settings.json whenever the model or the permission mode changes, and
# those are Egor's own switches, not an edit to the file's meaning: five alerts in seventeen
# minutes about `opus` becoming `sonnet` is how an alarm teaches everyone to ignore it. Both
# keys leave the fingerprint; everything else in the file — the hooks above all — still reports.
hash_of() {
  local h=''
  case "$1" in
    */.claude/settings.json)
      h=$(jq -S 'del(.model) | del(.permissions.defaultMode)' "$1" 2>/dev/null |
          shasum -a 256 | cut -d' ' -f1)
      # An unparseable settings.json falls back to the raw bytes rather than to a constant.
      [ -n "$h" ] && [ "$h" != "$(printf '' | shasum -a 256 | cut -d' ' -f1)" ] &&
        { printf '%s\n' "$h"; return 0; }
      ;;
  esac
  shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
}

# Reporting a change is not much use on its own: the bytes that were there are gone, and only
# one of these sixteen files — settings.json, the one that holds these very hooks — cannot be
# recovered from git. The whole set is 143 KB, so the tripwire keeps a copy. It is refreshed
# with the baseline, and a copy of the pre-change bytes is set aside before that happens, which
# is what turns "something changed" into "run this to put it back".
SNAP_DIR="$STATE_DIR/snapshot"
REVERT_DIR="$STATE_DIR/reverts"
SNAP_MAX_BYTES=1048576

snap_key() {
  printf '%s-%s' "$(basename "$1")" "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"
}

# Called before the baseline moves on, so it still holds what the file looked like beforehand.
keep_revert() {
  local visible=$1 real=$2 key stamp
  key=$(snap_key "$visible")
  [ -f "$SNAP_DIR/$key" ] || return 1
  # The snapshot is shared between sessions while the baselines are not, so a second session
  # checking after the first has already reported finds it refreshed to the new bytes. Keeping a
  # copy then would hand out the smuggled content as if it were the good version, and the first
  # session's genuine copy is the one that must survive.
  [ "$(hash_of "$SNAP_DIR/$key")" != "$(hash_of "$real")" ] || return 1
  mkdir -p "$REVERT_DIR" 2>/dev/null || return 1
  find "$REVERT_DIR" -mindepth 1 -maxdepth 1 -mtime +7 -delete 2>/dev/null
  # The pid is in the name because two sessions reporting inside the same second would otherwise
  # write the same file, and the second one's copy would replace the first one's.
  stamp="$REVERT_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$$-$key"
  cp "$SNAP_DIR/$key" "$stamp" 2>/dev/null || return 1
  printf '%s' "$stamp"
}

write_baseline() {
  local out=$1 tmp=$2 p real mtime size hash
  : >"$tmp" || return 1
  mkdir -p "$SNAP_DIR" 2>/dev/null
  while IFS= read -r p; do
    real=$(realpath "$p" 2>/dev/null) || real=$p
    IFS=' ' read -r mtime size <<<"$(stat -f '%m %z' "$real" 2>/dev/null)" || continue
    [ -n "${size:-}" ] || continue
    # An empty hash would be recorded as a row that can never match, so the file would report
    # as changed on the next check and every check after it.
    hash=$(hash_of "$real")
    [ -n "$hash" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$mtime" "$size" "$hash" "$p" "$real" >>"$tmp"
    [ "$size" -le "$SNAP_MAX_BYTES" ] 2>/dev/null &&
      cp "$real" "$SNAP_DIR/$(snap_key "$p")" 2>/dev/null
  done < <(visible_paths)
  mv "$tmp" "$out" 2>/dev/null
}

session_baseline() {
  local sid=$1
  case "$sid" in
    ''|*[!A-Za-z0-9._-]*) printf '%s/session-unknown.tsv' "$STATE_DIR" ;;
    *) printf '%s/session-%s.tsv' "$STATE_DIR" "$sid" ;;
  esac
}

emit_context() {
  jq -cn --arg e "$1" --arg c "$2" \
    '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}' 2>/dev/null || true
}

log_line() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >>"$LOG_FILE" 2>/dev/null || true
}

# Egor's own channel. Detached and silenced: a wedged Hammerspoon must not hold a hook
# that runs after every Bash call.
# The message carries a file name, and an ADDED report carries one nobody vetted, so it is
# escaped as a Lua literal rather than trusted: backslash first, then the quote, then the
# newlines a Lua string cannot hold at all.
alert_egor() {
  command -v "$ALERT" >/dev/null 2>&1 || return 0
  local msg=$1
  msg=${msg//\\/\\\\}
  msg=${msg//\"/\\\"}
  msg=${msg//$'\n'/ }
  msg=${msg//$'\r'/ }
  ( "$ALERT" -c "hs.alert.show(\"$msg\", 6)" >/dev/null 2>&1 & ) &
  return 0
}

cmd_baseline() {
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  # Only the per-session baselines age out. The snapshot and the reverts beside them are the
  # thing that makes a change undoable, and an unqualified sweep aimed at them every time.
  find "$STATE_DIR" -mindepth 1 -maxdepth 1 -name 'session-*' -mtime +7 -delete 2>/dev/null
  local out=$1
  write_baseline "$out" "$out.$$" || true
  exit 0
}

cmd_check() {
  local baseline=$1 event=$2 sid=$3
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  if [ ! -f "$baseline" ]; then
    write_baseline "$baseline" "$baseline.$$" || true
    exit 0
  fi

  local -a b_mtime=() b_size=() b_hash=() b_vis=() b_real=()
  local mtime size hash vis real
  while IFS=$'\t' read -r mtime size hash vis real; do
    [ -n "$real" ] || continue
    b_mtime+=("$mtime"); b_size+=("$size"); b_hash+=("$hash")
    b_vis+=("$vis"); b_real+=("$real")
  done <"$baseline"

  # One process for the whole set; %N echoes the path back so the rows can be matched. A
  # missing file makes stat exit 1 AFTER printing every row it could read, so the exit code is
  # deliberately ignored: discarding the output there reported the whole set as deleted.
  local stat_out=''
  [ "${#b_real[@]}" -gt 0 ] &&
    stat_out=$(stat -f '%N%t%m%t%z' -- "${b_real[@]}" 2>/dev/null)
  # Parallel arrays, not an associative one: /bin/bash is 3.2, where `local -A` is not a syntax
  # error but a silent downgrade to an indexed array — every path key then evaluates as
  # arithmetic to index 0, and the whole comparison quietly reads the wrong row. A session with
  # a PATH that misses Homebrew is exactly a headless worker, the case this watches for.
  local -a s_path=() s_val=()
  local n_path n_mtime n_size
  while IFS=$'\t' read -r n_path n_mtime n_size; do
    [ -n "$n_path" ] || continue
    s_path+=("$n_path"); s_val+=("$n_mtime $n_size")
  done <<<"$stat_out"

  local -a reports=() restores=()
  local i j cur cur_mtime cur_size cur_hash delta moved=0 kept
  for i in "${!b_real[@]}"; do
    real=${b_real[$i]}
    cur=''
    for j in "${!s_path[@]}"; do
      [ "${s_path[$j]}" = "$real" ] && { cur=${s_val[$j]}; break; }
    done
    if [ -z "$cur" ]; then
      reports+=("DELETED ${b_vis[$i]}")
      kept=$(keep_revert "${b_vis[$i]}" "${b_real[$i]}") && restores+=("cp '$kept' '${b_real[$i]}'")
      moved=1
      continue
    fi
    IFS=' ' read -r cur_mtime cur_size <<<"$cur"
    [ "$cur_mtime" = "${b_mtime[$i]}" ] && [ "$cur_size" = "${b_size[$i]}" ] && continue
    # A touched file still has to be hashed, but a rewrite that restored the same bytes
    # is not a change worth a word — only the baseline's stale mtime needs refreshing.
    moved=1
    cur_hash=$(hash_of "$real")
    [ -n "$cur_hash" ] || continue
    if [ "$cur_hash" != "${b_hash[$i]}" ]; then
      delta=$((cur_size - ${b_size[$i]}))
      [ "$delta" -ge 0 ] && delta="+$delta"
      reports+=("CHANGED ${b_vis[$i]} ($delta bytes)")
      kept=$(keep_revert "${b_vis[$i]}" "${b_real[$i]}") && restores+=("cp '$kept' '${b_real[$i]}'")
    fi
  done

  # A file that appeared under the protected globs is a change too: an agent or a doc
  # nobody approved still lands in every context window from then on.
  local known
  while IFS= read -r vis; do
    known=''
    for j in "${!b_vis[@]}"; do
      [ "${b_vis[$j]}" = "$vis" ] && { known=1; break; }
    done
    [ -n "$known" ] || { reports+=("ADDED $vis"); moved=1; }
  done < <(visible_paths)

  # Rebuilding the baseline costs a hash per protected file, so it happens only when
  # something actually moved. This runs after every Bash call; on the quiet path the
  # whole check is one stat.
  [ "$moved" = 1 ] || exit 0
  if [ "${#reports[@]}" -eq 0 ]; then
    write_baseline "$baseline" "$baseline.$$" || true
    exit 0
  fi

  local joined stale='' undo=''
  joined=$(printf '%s; ' "${reports[@]}")
  joined=${joined%; }
  if [ "${#restores[@]}" -gt 0 ]; then
    undo=" The bytes from before the change were kept, so this puts them back: $(printf '%s; ' "${restores[@]}")"
    undo=${undo%; }
  fi
  # The log is the durable half of the audit trail, so it is written before the baseline moves
  # on. Rebuilding first meant a hook killed in between erased the only record of the change.
  log_line "sid=${sid:-?} $joined${undo:+ | undo: ${restores[*]}}"
  alert_egor "Instruction file changed: ${reports[0]}"
  # A baseline that cannot be rewritten means this same change is reported again after every
  # later Bash call, so the repetition is named rather than left looking like fresh news.
  write_baseline "$baseline" "$baseline.$$" ||
    stale=" The baseline at $baseline could not be rewritten, so this report repeats until it can."
  emit_context "$event" "Instruction-file tripwire: $joined.$stale$undo These files are re-read in every context window (~15682 full-read equivalents/month), and Egor's standing rule is that they are read-only without his explicit OK in the current turn — no Edit, and equally no shell write. If he approved this change in this turn, nothing to do; this line is the audit trail. If he did not: stop, put the file back with the command above, and tell him what changed and why. Do not re-apply it through another tool."
  exit 0
}

payload=""
[ -t 0 ] || payload=$(cat 2>/dev/null)
# One jq for the whole payload: this runs after every Bash call, and a second interpreter
# start buys nothing.
values=$(printf '%s' "$payload" | jq -r '
  [(.hook_event_name // "PostToolUse"), (.session_id // "")] | join("\u001f")' 2>/dev/null) || values=""
IFS=$'\x1f' read -r event sid <<<"$values"
[ -n "${event:-}" ] || event=PostToolUse
baseline=$(session_baseline "${sid:-}")

case "${1:-check}" in
  baseline) cmd_baseline "$baseline" ;;
  check)    cmd_check "$baseline" "$event" "$sid" ;;
  *)        exit 0 ;;
esac
