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
# Reports, and inside Egor's autonomy span also PUTS BACK: growth of a guarded file that this
# session's own tool call produced goes back to the bytes the baseline vouches for, because there
# the span's rule (reshape these files, do not grow them) is the only arbiter left in the room and
# the gate ahead of this one can read a command's shape but never its result. Everything else is
# still reported and never touched — see revert_growth for the three conditions, all required.
#
# Hot path cost is one find and one stat process per Bash call: the baseline comparison is
# shell builtins, and a hash runs only for a file whose fingerprint moved.
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
# The second argument names WHICH file's rules to hash by, so a copy of settings.json kept
# somewhere else — the snapshot, whose name is a fingerprint — is hashed through the same filter
# as the original. Hashing the copy raw and the original filtered makes the two never compare
# equal, which silently disabled every guard built on that comparison.
hash_of() {
  local f=$1 class=${2:-$1} h=''
  case "$class" in
    */.claude/settings.json)
      h=$(jq -S 'del(.model) | del(.permissions.defaultMode)' "$f" 2>/dev/null |
          shasum -a 256 | cut -d' ' -f1)
      # An unparseable settings.json falls back to the raw bytes rather than to a constant.
      [ -n "$h" ] && [ "$h" != "$(printf '' | shasum -a 256 | cut -d' ' -f1)" ] &&
        { printf '%s\n' "$h"; return 0; }
      ;;
  esac
  shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1
}

# The restore commands are shell text Egor is invited to paste. A path carrying a quote would
# end the string it is quoted in and turn the rest of it into arguments.
shq() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# Reporting a change is not much use on its own: the bytes that were there are gone, and only
# one of these files — settings.json, the one that holds these very hooks — cannot be recovered
# from git. The whole set is 143 KB, so the tripwire keeps a copy, and a copy of the pre-change
# bytes is set aside before the baseline moves on. That is what turns "something changed" into
# "here is the command that puts it back" — a command for Egor to ask for, never one an agent
# runs on its own: the writer is as often another session or a worker as the agent reading this,
# and a rollback nobody asked for is how one session eats another's live work.
#
# A snapshot is named for the CONTENT it holds, not just the file it came from. The baselines
# are per-session while this directory is shared, so a session that has just started — or one
# that noticed the change first and moved on — would otherwise overwrite the one good copy
# another session is about to need. Under a content-addressed name a second version lands
# beside the first instead of on top of it, every session can add without destroying, and the
# name a session asks for is proof of what it will get back.
SNAP_DIR="$STATE_DIR/snapshot"
REVERT_DIR="$STATE_DIR/reverts"
ALERT_DIR="$STATE_DIR/alerts"
SNAP_MAX_BYTES=1048576
_watch_nl='
'

snap_key() {
  printf '%s-%s' "$(basename "$1")" "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"
}

# Called before the baseline moves on, so it still holds what the file looked like beforehand.
# $3 is the hash the caller's own baseline recorded, and asking for the snapshot BY that hash is
# the whole guarantee: what comes back is the version this session saw, never a newer one another
# session left behind and never a stale copy nobody remembers the provenance of.
keep_revert() {
  local visible=$1 real=$2 want=$3 src stamp
  src="$SNAP_DIR/$(snap_key "$visible")-$want"
  [ -f "$src" ] || return 1
  mkdir -p "$REVERT_DIR" 2>/dev/null || return 1
  find "$REVERT_DIR" -mindepth 1 -maxdepth 1 -mtime +7 -delete 2>/dev/null
  # The pid is in the name because two sessions reporting inside the same second would otherwise
  # write the same file, and the second one's copy would replace the first one's.
  stamp="$REVERT_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$$-$(basename "$src")"
  cp "$src" "$stamp" 2>/dev/null || return 1
  printf '%s' "$stamp"
}

# The bytes about to be overwritten by a revert. Nothing this hook does may be unrecoverable:
# what it is putting back is the model's own work, and Egor may want to look at it or keep it.
park_current() {
  local src=$1 stamp
  mkdir -p "$REVERT_DIR" 2>/dev/null || return 1
  stamp="$REVERT_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$$-grown-$(basename "$src")"
  cp "$src" "$stamp" 2>/dev/null || return 1
  printf '%s' "$stamp"
}

# $3 is the baseline this one replaces, and its absence is what says "no session here has ever
# vetted these files". That distinction drives both of the snapshot's rules:
#   - Trust. A file this baseline has never seen before is one that appeared unreviewed, and
#     copying it into the snapshot would make its later removal look like a violation and offer
#     the unvetted bytes back as the fix. Absence is the state worth preserving for those, so
#     they are recorded untrusted and never snapshotted; the flag rides along in the baseline,
#     because by the next rewrite the file is no longer new.
#   - Clobbering. A session that has no baseline has no idea whether what it sees is the good
#     version, and copying it over the snapshot destroys the one recovery copy another session
#     is about to need. It may fill an empty slot; it may not overwrite.
write_baseline() {
  local out=$1 tmp=$2 prior=${3:-} p real mtime size ino link hash trust key
  local trusted='' had_prior=''
  local nl='
'
  if [ -n "$prior" ] && [ -f "$prior" ]; then
    had_prior=1
    local _t _v
    while IFS=$'\t' read -r _ _ _ _t _ _ _v _; do
      [ -n "$_t$_v" ] || continue
      case "$_t" in
        1) [ -n "$_v" ] && trusted="$trusted$_v$nl" ;;
        0) ;;
        # An older row format lands its fourth column here. Distrusting the whole set over it
        # would be permanent — every later rewrite reads back the zeros this one wrote — so a
        # prior this one cannot parse counts as no prior at all.
        *) trusted=''; had_prior=''; break ;;
      esac
    done <"$prior"
  fi
  : >"$tmp" || return 1
  mkdir -p "$SNAP_DIR" 2>/dev/null
  while IFS= read -r p; do
    real=$(realpath "$p" 2>/dev/null) || real=$p
    IFS=$'\t' read -r mtime size ino <<<"$(stat -f '%Fm%t%z%t%i' "$real" 2>/dev/null)"
    [ -n "${size:-}" ] || continue
    # The visible name is watched in its own right, so what it points AT is part of the
    # fingerprint: retargeting a symlink leaves the file it used to name untouched.
    # `-` rather than an empty column, and this is load-bearing: tab is an IFS WHITESPACE
    # character, so `read` collapses a run of them into one delimiter. An empty field would
    # shift every column after it left, and the row would be dropped as unreadable.
    link='-'
    [ "$p" = "$real" ] || link=$(stat -f '%Y' "$p" 2>/dev/null)
    link=${link//$'\t'/ }
    link=${link//$'\n'/ }
    [ -n "$link" ] || link='-'
    # An empty hash would be recorded as a row that can never match, so the file would report
    # as changed on the next check and every check after it.
    hash=$(hash_of "$real" "$p")
    [ -n "$hash" ] || continue
    trust=1
    if [ -n "$had_prior" ]; then
      case "$nl$trusted" in *"$nl$p$nl"*) ;; *) trust=0 ;; esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$mtime" "$size" "$ino" "$trust" "$hash" "$link" "$p" "$real" >>"$tmp"
    # Copying every time rather than only when the name is new: the bytes are identical either
    # way, and the fresh mtime is what keeps a version still in use from ageing out of the sweep.
    key=$SNAP_DIR/$(snap_key "$p")-$hash
    [ "$trust" = 1 ] && [ "$size" -le "$SNAP_MAX_BYTES" ] 2>/dev/null &&
      cp "$real" "$key" 2>/dev/null
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

# One alert per change, machine-wide. This hook runs in EVERY live session — the chat Egor is
# typing in, its relay workers, every other window — and each keeps its own baseline, so a single
# edit flashed his screen once per session that happened to run a tool call after it. The marker is
# named for the FILE and the bytes it now holds, never for the report text: a session with an older
# baseline measures a different delta for the same change, and a key carrying one would alert again
# for what he has already been told. Only the session that wins the atomic claim speaks; every
# other one still rewrites its baseline and still reports the change to its own model, which is
# per-session context and stays.
alert_once() { # path content-key message
  local key
  key=$(printf '%s\n%s\n' "$1" "$2" | shasum -a 256 | cut -c1-16)
  instruction_mark_once "$ALERT_DIR" "$key" || return 0
  alert_egor "$3"
}

cmd_baseline() {
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  # The per-session baselines age out at a week. Snapshots outlive them by far, because the
  # version a file has sat at for a month is exactly the one worth being able to restore; only a
  # version no baseline has vouched for since is abandoned. Every write refreshes the mtime of
  # the version still in use, so what this reaches is superseded copies alone.
  find "$STATE_DIR" -mindepth 1 -maxdepth 1 -name 'session-*' -mtime +7 -delete 2>/dev/null
  find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type f -mtime +90 -delete 2>/dev/null
  local out=$1
  write_baseline "$out" "$out.$$" "$out" || true
  exit 0
}

# Both of these write into cmd_check's locals, which is what a function called from it sees.
# A report carries the price of the file it names, so the summary can quote the dearest one
# instead of the global file's rate for a skill that costs a fiftieth of it.
# $3 is what the file now HOLDS — its content hash, or the state that replaced one — and it exists
# for the alert alone: two sessions noticing the same change must key on the same string, and the
# report text is not that, since each measures the delta against its own baseline.
report() {
  local rate
  reports+=("$1")
  keys+=("$2$_watch_nl${3:-}")
  moved=1
  rate=$(instruction_read_rate "$2" "$HOME")
  [ -n "$rate" ] || return 0
  [ -z "$top_rate" ] || [ "$rate" -gt "$top_rate" ] 2>/dev/null || return 0
  top_rate=$rate
}

# Only a file the baseline vouches for gets a restore command. One that appeared unreviewed has
# no trusted bytes to go back to, and offering the unvetted ones would make its removal look
# like the violation.
offer_restore() {
  local i=$1 kept
  [ "${b_trust[$i]}" = 1 ] || return 0
  kept=$(keep_revert "${b_vis[$i]}" "${b_real[$i]}" "${b_hash[$i]}") || return 0
  restores+=("cp $(shq "$kept") $(shq "${b_real[$i]}")")
}

# Whether the tool call that just ran is what wrote this file. An Edit or a Write says so in its
# own file_path; a Bash command says so by leaving its bytes in one of the file's spellings — the
# absolute path, the tilde form, the name relative to the working directory — which the shared
# parse the gate ahead of this hook asks the same question of (`instruction_write_targets`). Read
# on the RAW command, heredoc bodies and quoted runs included, because the whole point of this
# half is the writes the gate could not see: a heredoc fed to an interpreter names its target
# inside the body.
# The answer decides a REVERT, so a row has to be a write by SHAPE. A redirection, a copy verb and
# a destination verb say so themselves. An interpreter row does not — it is the parse reporting a
# name it found inside a payload it does not read, and `python3 -c 'open("CLAUDE.md").read()'`
# produces exactly that row — so the interpreter shapes decide it, from the same shared spelling
# the gate ahead of this hook denies on (`instruction_interp_write_re`). Rolling back on a mention
# would put back growth another chat in the same checkout wrote, over a call that only read.
own_write() {
  local vis=$1 real=$2 p pr spelling names='' row_kind row_mode mention=''
  case "$tool" in
    Edit|Write|NotebookEdit)
      [ -n "$tool_path" ] || return 1
      p=$tool_path
      case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
      case "$p" in "$vis"|"$real") return 0 ;; esac
      pr=$(realpath "$p" 2>/dev/null) || return 1
      case "$pr" in "$vis"|"$real") return 0 ;; esac
      return 1
      ;;
    Bash)
      [ -n "$tool_cmd" ] || return 1
      # The BASENAME is what a command is filtered on, not the whole spelling: a copy into a
      # DIRECTORY never spells the file it lands in, and dropping the spelling here left the
      # resolved destination with nothing to match.
      while IFS= read -r spelling; do
        [ -n "$spelling" ] || continue
        case "$tool_cmd" in *"${spelling##*/}"*) ;; *) continue ;; esac
        names="${names:+$names|}$(instruction_ere_escape "$spelling")"
      done <<SPELL
$(_instruction_spellings "$vis" "$HOME" "$cwd"
  [ "$vis" = "$real" ] || _instruction_spellings "$real" "$HOME" "$cwd")
SPELL
      [ -n "$names" ] || return 1
      while IFS=$'\t' read -r row_kind row_mode _; do
        case "$row_kind" in
          redirect|copy) return 0 ;;
          verb) if [ "$row_mode" = unknown ]; then mention=1; else return 0; fi ;;
        esac
      done < <(instruction_write_targets "$tool_cmd" "$names")
      [ -n "$mention" ] || return 1
      # Flattened, because a heredoc puts the interpreter on one line and the open() on the next.
      printf '%s' "${tool_cmd//$'\n'/ }" \
        | grep -Eq "$(instruction_interp_write_re "$names")" || return 1
      return 0
      ;;
  esac
  return 1
}

# Growth put back rather than reported. Three conditions, every one of them required:
#   - the file is one the write gate speaks for (instruction_write_class), which leaves out
#     settings.json — the harness rewrites that on its own and no gate ever denied it;
#   - the call that just ran AIMED a write at it. A shared checkout means the writer is as often
#     another chat or a worker as this session, and a rollback decided on a guess eats that chat's
#     live work — the standing rule for everything else in this hook;
#   - Egor's autonomy span stands, OR the writer is a relay worker. In the first case he is away;
#     in the second he never negotiated with the writer at all — an instruction file is the
#     orchestrating model's to edit, after its audit, and a worker proposes. Both leave growth of a
#     file every later session re-reads with no arbiter in the room. Outside either, he is here to
#     arbiter and this hook reports.
# Only growth, and only against the version this session's own baseline vouches for: a shrink is
# the cleanup the span exists to allow, and an untrusted file has no good bytes to go back to.
revert_growth() {
  local i=$1 delta=$2 vis=${b_vis[$i]} real=${b_real[$i]} src parked
  [ "${b_trust[$i]}" = 1 ] || return 1
  [ -n "$(instruction_write_class "$real")" ] || return 1
  own_write "$vis" "$real" || return 1
  # Asked of every rollback and not only of the ones the span did not already authorise: WHO wrote
  # decides the wording, and a worker inside a span told to leave the addition for Egor's next turn
  # is a worker handed a human's instruction instead of the MD-PROPOSAL protocol it answers by.
  ! instruction_in_relay || relay_revert=1
  if ! instruction_autonomous "$sid" "$transcript"; then
    # A worker's own class check, narrower than the span's: the review-debt list and anything else
    # a class speaks for but no session re-reads is not what the orchestrator's rule is about.
    [ -n "$relay_revert" ] && instruction_always_loaded "$vis" "$HOME" >/dev/null || return 1
  fi
  src="$SNAP_DIR/$(snap_key "$vis")-${b_hash[$i]}"
  [ -f "$src" ] || return 1
  parked=$(park_current "$real") || return 1
  cp "$src" "$real" 2>/dev/null || return 1
  reverted+=("$vis (+$delta bytes; what it wrote is parked at $parked)")
  report "REVERTED $vis (+$delta bytes)" "$vis" "${b_hash[$i]}"
}

cmd_check() {
  local baseline=$1 event=$2 sid=$3
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  if [ ! -f "$baseline" ]; then
    write_baseline "$baseline" "$baseline.$$" || true
    exit 0
  fi

  local -a b_mtime=() b_size=() b_ino=() b_trust=() b_hash=() b_link=() b_vis=() b_real=()
  local mtime size ino trust hash link vis real
  while IFS=$'\t' read -r mtime size ino trust hash link vis real; do
    [ -n "$real" ] || continue
    b_mtime+=("$mtime"); b_size+=("$size"); b_ino+=("$ino"); b_trust+=("$trust")
    b_hash+=("$hash"); b_link+=("$link"); b_vis+=("$vis"); b_real+=("$real")
  done <"$baseline"
  # A baseline left by an earlier row format parses to nothing. Rebuilding it silently is the
  # only honest answer: reporting the whole watched set as newly added is not a finding.
  if [ "${#b_real[@]}" -eq 0 ]; then
    write_baseline "$baseline" "$baseline.$$" || true
    exit 0
  fi

  # One process for the whole set; %N echoes the path back so the rows can be matched. A
  # missing file makes stat exit 1 AFTER printing every row it could read, so the exit code is
  # deliberately ignored: discarding the output there reported the whole set as deleted.
  # The visible names ride along in the same call: stat does not follow symlinks, so a row for
  # one reports on the link itself — the only way a retargeted or removed link is ever seen.
  local -a targets=()
  local i j
  for i in "${!b_real[@]}"; do
    targets+=("${b_real[$i]}")
    [ "${b_vis[$i]}" = "${b_real[$i]}" ] || targets+=("${b_vis[$i]}")
  done
  local stat_out=''
  [ "${#targets[@]}" -gt 0 ] &&
    stat_out=$(stat -f '%N%t%Fm%t%z%t%i%t%Y' -- "${targets[@]}" 2>/dev/null)
  # Parallel arrays, not an associative one: /bin/bash is 3.2, where `local -A` is not a syntax
  # error but a silent downgrade to an indexed array — every path key then evaluates as
  # arithmetic to index 0, and the whole comparison quietly reads the wrong row. A session with
  # a PATH that misses Homebrew is exactly a headless worker, the case this watches for.
  local -a s_path=() s_val=()
  local n_path n_rest
  while IFS=$'\t' read -r n_path n_rest; do
    [ -n "$n_path" ] || continue
    s_path+=("$n_path"); s_val+=("$n_rest")
  done <<<"$stat_out"

  local -a reports=() keys=() restores=() reverted=()
  local cur cur_mtime cur_size cur_ino cur_link cur_hash delta moved=0 top_rate=''
  local relay_revert=''
  local vis_seen vis_ino
  for i in "${!b_real[@]}"; do
    real=${b_real[$i]}; vis=${b_vis[$i]}
    cur=''
    for j in "${!s_path[@]}"; do
      [ "${s_path[$j]}" = "$real" ] && { cur=${s_val[$j]}; break; }
    done
    vis_seen=''; vis_ino=''; cur_link=''
    if [ "$vis" != "$real" ]; then
      for j in "${!s_path[@]}"; do
        [ "${s_path[$j]}" = "$vis" ] || continue
        vis_seen=1
        IFS=$'\t' read -r _ _ vis_ino cur_link <<<"${s_val[$j]}"
        break
      done
    fi
    if [ -z "$cur" ]; then
      # A recorded target that is gone under a name that still resolves is a retarget, not a
      # deletion: bytes restored at a path the name no longer means would restore nothing.
      if [ "$vis" != "$real" ] && [ -n "$vis_seen" ]; then
        report "RETARGETED $vis (its recorded target is gone)" "$vis" gone
        continue
      fi
      report "DELETED $vis" "$vis" absent
      offer_restore "$i"
      continue
    fi
    if [ "$vis" != "$real" ]; then
      # The name every session reads is gone or points somewhere else while the file it used to
      # name sits there untouched, reporting nothing. Restoring bytes would answer a question
      # nobody asked, so both of these report and neither offers an undo.
      if [ -z "$vis_seen" ]; then
        report "DELETED $vis" "$vis" absent
        continue
      fi
      # stat prints nothing for a name that is not a symlink, which is the baseline's `-`.
      if [ "${cur_link:--}" != "${b_link[$i]}" ]; then
        report "RETARGETED $vis -> ${cur_link:-not a symlink any more}" "$vis" "${cur_link:--}"
        continue
      fi
    fi
    IFS=$'\t' read -r cur_mtime cur_size cur_ino _ <<<"$cur"
    # A retargeted ANCESTOR symlink (docs/, agents/ — the class dirs are links) changes neither
    # the final component's %Y nor the recorded target, which sits untouched. The name and the
    # target disagreeing on inode is the one trace that leaves.
    if [ "$vis" != "$real" ] && [ "${b_link[$i]}" = '-' ] && [ -n "$vis_ino" ] &&
       [ "$vis_ino" != "$cur_ino" ]; then
      report "RETARGETED $vis (the name resolves to a different file)" "$vis" "$vis_ino"
      continue
    fi
    # Fractional mtime and the inode, not whole seconds and a size: a same-size rewrite landing
    # inside the same second was indistinguishable from no write at all, and skipping the hash
    # there is exactly the shape a smuggled edit has. What this still cannot see is a writer that
    # restores the original timestamp to the nanosecond (touch -r does) at an unchanged size and
    # inode; catching that means hashing all 44 files after every Bash call, which is 13ms here
    # against 3ms for the stat, so the trade is deliberate rather than overlooked.
    [ "$cur_mtime" = "${b_mtime[$i]}" ] && [ "$cur_size" = "${b_size[$i]}" ] &&
      [ "$cur_ino" = "${b_ino[$i]}" ] && continue
    # A touched file still has to be hashed, but a rewrite that restored the same bytes
    # is not a change worth a word — only the baseline's stale fingerprint needs refreshing.
    moved=1
    cur_hash=$(hash_of "$real" "$vis")
    [ -n "$cur_hash" ] || continue
    if [ "$cur_hash" != "${b_hash[$i]}" ]; then
      delta=$((cur_size - ${b_size[$i]}))
      if [ "$delta" -gt 0 ] && revert_growth "$i" "$delta"; then
        continue
      fi
      [ "$delta" -ge 0 ] && delta="+$delta"
      report "CHANGED $vis ($delta bytes)" "$vis" "$cur_hash"
      offer_restore "$i"
    fi
  done

  # A file that appeared under the protected paths is a change too: an agent or a doc
  # nobody approved still lands in every context window from then on.
  local known
  while IFS= read -r vis; do
    known=''
    for j in "${!b_vis[@]}"; do
      [ "${b_vis[$j]}" = "$vis" ] && { known=1; break; }
    done
    [ -n "$known" ] || report "ADDED $vis" "$vis" "$(hash_of "$vis" "$vis")"
  done < <(visible_paths)

  # Rebuilding the baseline costs a hash per protected file, so it happens only when
  # something actually moved. This runs after every Bash call; on the quiet path the
  # whole check is one stat.
  [ "$moved" = 1 ] || exit 0
  if [ "${#reports[@]}" -eq 0 ]; then
    write_baseline "$baseline" "$baseline.$$" "$baseline" || true
    exit 0
  fi

  local joined stale='' undo='' undone='' cost=''
  joined=$(printf '%s; ' "${reports[@]}")
  joined=${joined%; }
  if [ "${#restores[@]}" -gt 0 ]; then
    undo=" The bytes from before the change were kept, so this puts them back: $(printf '%s; ' "${restores[@]}")"
    undo=${undo%; }
  fi
  if [ "${#reverted[@]}" -gt 0 ]; then
    local why tail
    if [ -n "$relay_revert" ]; then
      why="instruction files are the orchestrator's to edit (Egor's rule) and a relay worker proposes rather than writes"
      tail="Do not write it again — put the exact proposed text and its byte delta under MD-PROPOSAL in your RETURN, with the cut you suggest to pay for it."
    else
      why="Egor's autonomy span covers reshaping these files and not growing them"
      tail="Do not write it again — an instruction file grows when he says so, not while he is away. If the addition is worth its recurring cost, say so in one line and leave it for his next turn."
    fi
    undone=" Growth this session's own call produced was PUT BACK, because $why: $(printf '%s; ' "${reverted[@]}")"
    undone=${undone%; }
    undone="$undone. $tail"
  fi
  # The log is the durable half of the audit trail, so it is written before the baseline moves
  # on. Rebuilding first meant a hook killed in between erased the only record of the change.
  log_line "sid=${sid:-?} $joined${undo:+ | undo: ${restores[*]}}${undone:+ | reverted: ${reverted[*]}}"
  # Keyed on the report the alert NAMES, which is the first one: what Egor reads is that line.
  alert_once "${keys[0]%%"$_watch_nl"*}" "${keys[0]#*"$_watch_nl"}" \
    "Instruction file changed: ${reports[0]}"
  # A baseline that cannot be rewritten means this same change is reported again after every
  # later Bash call, so the repetition is named rather than left looking like fresh news.
  write_baseline "$baseline" "$baseline.$$" "$baseline" ||
    stale=" The baseline at $baseline could not be rewritten, so this report repeats until it can."
  # The dearest class in this report, not the global file's rate quoted over a skill that costs
  # a fiftieth of it. A report naming only files this table does not price says nothing at all.
  [ -n "$top_rate" ] && cost=" (up to ~$top_rate full-read equivalents/month)"
  emit_context "$event" "Instruction-file tripwire: $joined.$stale$undone$undo These files are re-read across sessions$cost, and Egor's standing rule is that they are read-only without his explicit OK in the current turn — no Edit, and equally no shell write. If he approved this change in this turn, nothing to do; this line is the audit trail. If he did not: tell him in ONE line what changed, hand him the restore command if there is one, and carry on with your task. Do NOT run that command and do not undo the change any other way — the writer may be another chat, a worker of yours, a tool that rewrote the file wholesale, or Egor himself, and this hook cannot tell which, so a rollback you decide on your own destroys someone's live work. Restore only if he asks for it."
  exit 0
}

payload=""
[ -t 0 ] || payload=$(cat 2>/dev/null)
# One jq for the whole payload: this runs after every Bash call, and a second interpreter
# start buys nothing.
values=$(printf '%s' "$payload" | jq -r '
  [(.hook_event_name // "PostToolUse"), (.session_id // ""), (.tool_name // ""),
   (.transcript_path // ""), (.cwd // ""), (.tool_input.file_path // ""),
   (.tool_input.command // "")]
  | join("\u001f")' 2>/dev/null) || values=""
# NUL-delimited rather than a line read, and the command last: a Bash command is routinely several
# lines, and a line read would keep only its first one.
IFS=$'\x1f' read -r -d '' event sid tool transcript cwd tool_path tool_cmd <<<"$values" || :
# A read that found no field at all leaves the newline the here-string added, and that newline is
# the event name every emitted record would carry.
case "${event:-}" in ''|*[!A-Za-z]*) event=PostToolUse ;; esac
baseline=$(session_baseline "${sid:-}")

case "${1:-check}" in
  baseline) cmd_baseline "$baseline" ;;
  check)    cmd_check "$baseline" "$event" "$sid" ;;
  *)        exit 0 ;;
esac
