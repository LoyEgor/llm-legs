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
# Everything this hook keeps on disk — the baselines, the ranked cache, the alert markers — is a
# file the model can write, so it is evidence and never authority: a baseline that is gone or empty
# is itself an event (BASELINE-MISSING), a new session compares against the newest baseline any
# session left (the -BETWEEN-SESSIONS reports), and a path the ranked cache stops naming stays
# watched for as long as it exists. When this hook cannot run at all — its library, jq or the
# payload missing — it exits 2 with the reason instead of passing silently.
#
# Hot path cost is one find, one stat process and one join per call: the baseline comparison is
# shell builtins over the joined rows, and a hash runs only for a file whose fingerprint moved.
set -u

[ -n "${HOME:-}" ] || exit 0

STATE_DIR="${INSTRUCTION_WATCH_STATE:-$HOME/.cache/claude-instruction-watch}"
LOG_FILE="${INSTRUCTION_WATCH_LOG:-$HOME/.claude/instruction-changes.log}"
ALERT="${INSTRUCTION_WATCH_ALERT:-hs}"
# A rolled-back writer must be told or it may repeat the write.
CHAT="${INSTRUCTION_WATCH_CHAT:-reverts}"

# ~/.claude/hooks is a symlink into the config repository and the entry there is a symlink
# into this one, so follow the chain rather than the first hop.
self=$0
for _ in 1 2 3 4 5; do
  [ -L "$self" ] || break
  target=$(readlink "$self")
  case "$target" in /*) self=$target ;; *) self=$(dirname "$self")/$target ;; esac
done
. "$(dirname "$self")/../share/instruction-files.sh" 2>/dev/null ||
  { echo "instruction watch: cannot load share/instruction-files.sh, so no instruction-file change can be seen" >&2; exit 2; }
command -v jq >/dev/null 2>&1 ||
  { echo "instruction watch: jq is missing, so the hook payload cannot be read" >&2; exit 2; }

RANKED_CACHE="$STATE_DIR/ranked.txt"
repo_root=''

visible_paths() { instruction_visible_paths "$HOME" "$RANKED_CACHE" "$repo_root"; }

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
JOURNAL="$STATE_DIR/events.jsonl"
RECEIPT_DIR="$STATE_DIR/receipts"
JOURNAL_MAX=${INSTRUCTION_WATCH_JOURNAL_MAX:-200}
SNAP_MAX_BYTES=1048576
_watch_nl='
'
_watch_tab=$'\t'

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
# $4 is what the caller already compared, a row per file: `vis mtime size ino hash link real`.
# Such a file is recorded at exactly that fingerprint and hash and never hashed again here: bytes
# that landed after the comparison were never reported, and hashing them now would vouch for
# them. Its next check then sees a fingerprint that moved and reports what it finds.
# Every path the prior baseline watched stays in, whatever the ranked cache says now, and so does
# every repository root it recorded (`#root`); a path that exists but cannot be read or hashed is
# recorded as `#unwatchable`, so it is reported once rather than on every call.
write_baseline() {
  local out=$1 tmp=$2 prior=${3:-} pinned=${4:-} p real mtime size ino link hash trust ht line i k t
  local trusted='' had_prior='' kept='' roots='' rows=''
  local nl=$_watch_nl
  if [ -n "$prior" ] && [ -f "$prior" ]; then
    had_prior=1
    local _m _s _t _v
    while IFS=$'\t' read -r _m _s _ _t _ _ _v _; do
      case "$_m" in
        '#root') [ -n "$_s" ] && roots="$roots$_s$nl"; continue ;;
        '#'*) continue ;;
      esac
      [ -n "$_t$_v" ] || continue
      case "$_t" in
        1) [ -n "$_v" ] && trusted="$trusted$_v$nl" ;;
        0) ;;
        # An older row format lands its fourth column here. Distrusting the whole set over it
        # would be permanent — every later rewrite reads back the zeros this one wrote — so a
        # prior this one cannot parse counts as no prior at all.
        *) trusted=''; had_prior=''; kept=''; break ;;
      esac
      [ -n "$_v" ] && kept="$kept$_v$nl"
    done <"$prior"
  fi
  [ -n "$repo_root" ] && roots="$roots$repo_root$nl"
  : >"$tmp" || return 1
  printf '%s' "$roots" | LC_ALL=C awk 'length && !seen[$0]++ { print "#root\t" $0 }' >>"$tmp"
  mkdir -p "$SNAP_DIR" 2>/dev/null

  local -a wp=() wpin=() wst=()
  while IFS= read -r line; do
    wp+=("${line%%$'\036'*}"); wpin+=("${line#*$'\036'}")
  done < <({ printf '%s\n' "$pinned"; printf '\035\n'; visible_paths; printf '%s' "$kept"; } |
    LC_ALL=C awk -F'\t' '
      !sep { if ($0 == "\035") { sep = 1; next }
             if (length($1)) { P[$1] = substr($0, length($1) + 2); order[++n] = $1 }
             next }
      length($0) && !seen[$0]++ { print $0 "\036" P[$0] }
      END { for (k = 1; k <= n; k++) if (!seen[order[k]]++) print order[k] "\036" P[order[k]] }')
  if [ "${#wp[@]}" -eq 0 ]; then
    mv "$tmp" "$out" 2>/dev/null
    return
  fi
  # Two stat processes for the whole set, joined back by name: -L for what the name resolves to
  # (%R is its realpath), plain for the link text. A dangling link makes -L fall back to the
  # link itself, which %HT gives away.
  while IFS= read -r line; do wst+=("$line"); done < <(
    { stat -L -f '%N%t%R%t%HT%t%Fm%t%z%t%i' -- "${wp[@]}" 2>/dev/null; printf '\035\n'
      stat -f '%N%t%Y' -- "${wp[@]}" 2>/dev/null; printf '\035\n'
      printf '%s\n' "${wp[@]}"; } |
    LC_ALL=C awk -F'\t' '
      sep == 0 { if ($0 == "\035") { sep = 1; next } S[$1] = substr($0, length($1) + 2); next }
      sep == 1 { if ($0 == "\035") { sep = 2; next } L[$1] = $2; next }
      { print (($0 in S) ? S[$0] : "") "\036" L[$0] }')

  local -a r_m=() r_s=() r_i=() r_h=() r_l=() r_r=() r_snap=() fresh=()
  local f_m f_s f_i f_h f_l f_r
  for i in "${!wp[@]}"; do
    p=${wp[$i]}
    real='' ht='' mtime='' size='' ino=''
    line=${wst[$i]:-}
    link=${line#*$'\036'}
    line=${line%%$'\036'*}
    [ -n "$line" ] && IFS=$'\t' read -r real ht mtime size ino <<<"$line"
    [ "$ht" = "Symbolic Link" ] && size=''
    [ -n "$real" ] || real=$p
    # `-` rather than an empty column, and this is load-bearing: tab is an IFS WHITESPACE
    # character, so `read` collapses a run of them into one delimiter. An empty field would
    # shift every column after it left, and the row would be dropped as unreadable.
    link=${link//$'\n'/ }
    [ -n "$link" ] || link='-'
    hash=''
    r_snap[$i]=1
    if [ -n "${wpin[$i]}" ]; then
      IFS=$'\t' read -r f_m f_s f_i f_h f_l f_r <<<"${wpin[$i]}"
      if [ -n "$size" ] && [ "$mtime" = "$f_m" ] && [ "$size" = "$f_s" ] && [ "$ino" = "$f_i" ] &&
         [ "$link" = "$f_l" ]; then
        hash=$f_h
      else
        mtime=$f_m; size=$f_s; ino=$f_i; hash=$f_h; link=$f_l; real=${f_r:-$real}; r_snap[$i]=''
      fi
    elif [ -z "$size" ]; then
      { [ -e "$p" ] || [ -L "$p" ]; } && printf '#unwatchable\t%s\n' "$p" >>"$tmp"
      r_m[$i]=''
      continue
    else
      fresh+=("$i")
    fi
    r_m[$i]=$mtime; r_s[$i]=$size; r_i[$i]=$ino; r_h[$i]=$hash; r_l[$i]=$link; r_r[$i]=$real
  done

  if [ "${#fresh[@]}" -gt 0 ]; then
    local -a plain=()
    for i in "${fresh[@]}"; do
      case "${wp[$i]}" in
        */.claude/settings.json) r_h[$i]=$(hash_of "${r_r[$i]}" "${wp[$i]}") ;;
        *) plain+=("${r_r[$i]}") ;;
      esac
    done
    if [ "${#plain[@]}" -gt 0 ]; then
      local -a hashed=()
      while IFS= read -r line; do hashed+=("$line"); done < <(
        { shasum -a 256 -- "${plain[@]}" 2>/dev/null; printf '\035\n'; printf '%s\n' "${plain[@]}"; } |
        LC_ALL=C awk '
          !sep { if ($0 == "\035") { sep = 1; next } H[substr($0, 67)] = $1; next }
          { print H[$0] }')
      k=0
      for i in "${fresh[@]}"; do
        case "${wp[$i]}" in */.claude/settings.json) continue ;; esac
        r_h[$i]=${hashed[$k]:-}
        k=$((k + 1))
      done
    fi
  fi

  local -a snap_idx=()
  for i in "${!wp[@]}"; do
    [ -n "${r_m[$i]:-}" ] || continue
    p=${wp[$i]}
    # An empty hash would be recorded as a row that can never match, so the file would report
    # as changed on the next check and every check after it.
    if [ -z "${r_h[$i]}" ]; then
      printf '#unwatchable\t%s\n' "$p" >>"$tmp"
      continue
    fi
    trust=1
    if [ -n "$had_prior" ]; then
      case "$nl$trusted" in *"$nl$p$nl"*) ;; *) trust=0 ;; esac
    fi
    t=$_watch_tab
    rows="$rows${r_m[$i]}$t${r_s[$i]}$t${r_i[$i]}$t$trust$t${r_h[$i]}$t${r_l[$i]}$t$p$t${r_r[$i]}$nl"
    [ "$trust" = 1 ] && [ -n "${r_snap[$i]}" ] && [ "${r_s[$i]}" -le "$SNAP_MAX_BYTES" ] 2>/dev/null &&
      snap_idx+=("$i")
  done
  printf '%s' "$rows" >>"$tmp" || return 1

  # Copying only what the snapshot lacks and touching the rest: the bytes under a content-addressed
  # name are identical either way, and the fresh mtime is what keeps a version still in use from
  # ageing out of the sweep.
  if [ "${#snap_idx[@]}" -gt 0 ]; then
    local -a keys=() stale=()
    local key
    while IFS= read -r line; do keys+=("$line"); done < <(
      for i in "${snap_idx[@]}"; do printf '%s\n' "${wp[$i]}"; done |
        perl -MDigest::SHA=sha256_hex -ne 'chomp; my $b = $_; $b =~ s{.*/}{}; print $b, "-", substr(sha256_hex($_), 0, 8), "\n"')
    k=0
    for i in "${snap_idx[@]}"; do
      key=${keys[$k]:-}
      k=$((k + 1))
      [ -n "$key" ] || continue
      key="$SNAP_DIR/$key-${r_h[$i]}"
      if [ -f "$key" ]; then
        stale+=("$key")
      else
        cp "${r_r[$i]}" "$key" 2>/dev/null
      fi
    done
    [ "${#stale[@]}" -eq 0 ] || touch -c "${stale[@]}" 2>/dev/null
  fi
  mv "$tmp" "$out" 2>/dev/null
}

# A session id that cannot name a file gets one per CALLER (the parent is the CLI that runs every
# hook of one session), never a name every such caller shares — a shared baseline lets one
# caller's rewrite absorb a change another has not reported yet — and never one per call, which
# reads every check as a missing baseline.
session_baseline() {
  local sid=$1
  case "$sid" in
    ''|*[!A-Za-z0-9._-]*) printf '%s/session-unknown-%s.tsv' "$STATE_DIR" "$PPID" ;;
    *) printf '%s/session-%s.tsv' "$STATE_DIR" "$sid" ;;
  esac
}

has_rows() { [ -f "$1" ] && grep -q '^[^#]' "$1" 2>/dev/null; }

newest_baseline() { # own-baseline
  local f
  while IFS= read -r f; do
    [ "$f" = "$1" ] && continue
    has_rows "$f" || continue
    printf '%s' "$f"
    return 0
  done < <(ls -t "$STATE_DIR"/session-*.tsv 2>/dev/null)
  return 1
}

emit_context() {
  jq -cn --arg e "$1" --arg c "$2" \
    '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}' 2>/dev/null || true
}

log_line() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >>"$LOG_FILE" 2>/dev/null || true
}

journal_event() { # sent id summary
  local sent=$1 id=$2 summary=$3 line n
  local files='' vis k chat='' resolver=''
  if [ -n "${sid:-}" ]; then
    resolver=$(command -v chat-name 2>/dev/null) || resolver=''
    [ -n "$resolver" ] || { [ ! -x "$HOME/.local/bin/chat-name" ] || resolver=$HOME/.local/bin/chat-name; }
    [ -z "$resolver" ] || chat=$("$resolver" "$sid" 2>/dev/null) || true
  fi
  local lock="$STATE_DIR/journal.lock" i=0 born now
  for k in "${keys[@]}"; do files="$files${k%%"$_watch_nl"*}$_watch_nl"; done
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  line=$(jq -cn --arg id "$id" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg sid "${sid:-}" --arg summary "$summary" --arg sent "$sent" --arg kind "${kind:-change}" \
    --arg chat "$chat" --arg bytes "$(printf '%s\n' ${deltas[@]+"${deltas[@]}"})" \
    --arg files "$files" --arg restores "$(printf '%s\n' ${restores[@]+"${restores[@]}"})" \
    --arg reverted "$(printf '%s\n' ${reverted[@]+"${reverted[@]}"})" \
    '{id:$id,at:$at,sid:$sid,kind:$kind,summary:$summary,sent:$sent,
      files:($files|split("\n")|map(select(length>0))),
      bytes:($bytes|split("\n")|map(select(length>0)|tonumber)),
      restores:($restores|split("\n")|map(select(length>0))),
      reverted:($reverted|split("\n")|map(select(length>0)))} +
      (if $chat != "" then {chat:$chat} else {} end)' 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  # tail-then-mv of the journal drops a line another session appends between the two;
  # that session has already claimed its marker, so the record would vanish.
  while ! mkdir "$lock" 2>/dev/null; do
    born=$(stat -f %m "$lock" 2>/dev/null) || born=
    now=$(date +%s)
    if [ -n "$born" ] && [ $((now - born)) -gt 30 ]; then
      rmdir "$lock" 2>/dev/null || true
    fi
    i=$((i + 1))
    [ "$i" -lt 50 ] || return 1
    sleep 0.02
  done
  printf '%s\n' "$line" >>"$JOURNAL" 2>/dev/null || { rmdir "$lock" 2>/dev/null; return 1; }
  n=$(wc -l <"$JOURNAL" 2>/dev/null) || n=0
  if [ "${n:-0}" -gt $((JOURNAL_MAX * 2)) ] 2>/dev/null; then
    tail -n "$JOURNAL_MAX" "$JOURNAL" >"$JOURNAL.$$" 2>/dev/null &&
      mv "$JOURNAL.$$" "$JOURNAL" 2>/dev/null
    rm -f "$JOURNAL.$$" 2>/dev/null
  fi
  rmdir "$lock" 2>/dev/null || true
  return 0
}

poke_alert() {
  # Keep untrusted filenames in JSON, never in the Lua command.
  command -v "$ALERT" >/dev/null 2>&1 || return 1
  ( "$ALERT" -c 'local ok, m = pcall(require, "instruction-watch"); if ok then m.pump() end' \
      >/dev/null 2>&1 & ) &
  return 0
}

# One alert per change, machine-wide. This hook runs in EVERY live session — the chat Egor is
# typing in, its relay workers, every other window — and each keeps its own baseline, so a single
# edit flashed his screen once per session that happened to run a tool call after it. The marker is
# named for the FILE and the WRITE that produced what it now holds — the new content's hash and the
# mtime it landed at — never for the report text: a session with an older baseline measures a
# different delta for the same change, and a key carrying one would alert again for what he has
# already been told. The mtime is what makes it a transition rather than a state: content that goes
# A → B → A → B inside a day is two writes of B, and a key on the content alone swallowed the second.
# Only the session that wins the atomic claim speaks; every other one still rewrites its baseline
# and still reports the change to its own model, which is per-session context and stays.
watch_mark_key() { # path content-key
  printf '%s\n%s\n' "$1" "$2" | shasum -a 256 | cut -c1-16
}

clear_gone_marks() { # path
  local g
  for g in absent gone; do
    rmdir "$ALERT_DIR/$(watch_mark_key "$1" "$g")" 2>/dev/null || true
  done
}

# 1 when the journal could not take the record: the caller then keeps its baseline where it was, so
# the change is found and reported again rather than absorbed unrecorded.
alert_once() { # path content-key summary
  local key sent=unsent id='' claimed='' k
  # Keying only keys[0] skipped the rest of a multi-file check when that first
  # file was already marked by another session.
  for k in "${keys[@]}"; do
    key=$(watch_mark_key "${k%%"$_watch_nl"*}" "${k#*"$_watch_nl"}")
    if instruction_mark_once "$ALERT_DIR" "$key"; then
      claimed="$claimed$key "
      [ -n "$id" ] || id=$key
    fi
  done
  [ -n "$id" ] || return 0
  # Receipts live 30d, the marker 1d; reusing the marker as the journal id lets
  # a leftover receipt swallow a same-bytes repeat after the marker expires.
  id=$(printf '%s\n%s\n%s\n%s\n' "$id" "$$" "$RANDOM" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    | shasum -a 256 | cut -c1-16)
  command -v "$ALERT" >/dev/null 2>&1 && sent=attempted
  if ! journal_event "$sent" "$id" "$3"; then
    # A failed append would otherwise leave the change claimed and unjournaled.
    for key in $claimed; do
      rmdir "$ALERT_DIR/$key" 2>/dev/null || true
    done
    return 1
  fi
  poke_alert || return 0
}

# SessionStart. The baseline it writes is compared first against the newest one on disk — this
# session's own on a resume or a compaction, else whatever another session left — because
# everything that changed while no session of this one was watching would otherwise be absorbed
# into the new baseline unreported.
cmd_baseline() {
  local out=$1 ref=''
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  if has_rows "$out"; then ref=$out; else ref=$(newest_baseline "$out") || ref=''; fi
  # The per-session baselines age out at a week. Snapshots outlive them by far, because the
  # version a file has sat at for a month is exactly the one worth being able to restore; only a
  # version no baseline has vouched for since is abandoned. Every write refreshes the mtime of
  # the version still in use, so what this reaches is superseded copies alone.
  find "$STATE_DIR" -mindepth 1 -maxdepth 1 -name 'session-*' ! -path "${ref:-/}" -mtime +7 \
    -delete 2>/dev/null
  find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type f -mtime +90 -delete 2>/dev/null
  find "$RECEIPT_DIR" -mindepth 1 -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null
  instruction_ranked_refresh "$HOME" "$RANKED_CACHE" || true
  [ -z "$ref" ] || cmd_check "$out" "$event" "$sid" between "$ref"
  write_baseline "$out" "$out.$$" "$out" || true
  exit 0
}

# Both of these write into cmd_check's locals, which is what a function called from it sees.
# A report carries the price of the file it names, so the summary can quote the dearest one
# instead of the global file's rate for a skill that costs a fiftieth of it.
# $3 is the alert key's content half — the write it saw, or the state that replaced the file — and
# it exists for the alert alone: two sessions noticing the same change must key on the same string,
# and the report text is not that, since each measures the delta against its own baseline.
report() {
  local rate
  reports+=("$1")
  keys+=("$2$_watch_nl${3:-}")
  deltas+=("${4:-0}")
  moved=1
  rate=$(instruction_read_rate "$2" "$HOME")
  [ -n "$rate" ] || return 0
  [ -z "$top_rate" ] || [ "$rate" -gt "$top_rate" ] 2>/dev/null || return 0
  top_rate=$rate
}

pin() { # vis mtime size ino hash link real
  pinned="$pinned$1$_watch_tab$2$_watch_tab$3$_watch_tab$4$_watch_tab$5$_watch_tab$6$_watch_tab$7$_watch_nl"
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
# inside the body. Every spelling goes to the parse, none is pre-filtered against the raw text:
# the parse resolves `$'…'` and backslash escapes, and a name spelled through them never appears
# literally in the command.
# The answer decides a REVERT, so a row has to be a write by SHAPE. A redirection, a copy verb and
# a destination verb say so themselves. An interpreter row does not — it is the parse reporting a
# name it found inside a payload it does not read, and `python3 -c 'open("CLAUDE.md").read()'`
# produces exactly that row — so the interpreter shapes decide it, from the same shared spelling
# the gate ahead of this hook denies on (`instruction_interp_write_re`). Rolling back on a mention
# would put back growth another chat in the same checkout wrote, over a call that only read.
own_write() {
  local vis=$1 real=$2 p pr spelling names='' row_kind row_mode mention=''
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
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
      while IFS= read -r spelling; do
        [ -n "$spelling" ] || continue
        names="${names:+$names|}$(instruction_ere_escape "$spelling")"
      done <<SPELL
$(_instruction_spellings "$vis" "$HOME" "$cwd"
  [ "$vis" = "$real" ] || _instruction_spellings "$real" "$HOME" "$cwd")
SPELL
      [ -n "$names" ] || return 1
      while IFS=$'\t' read -r row_kind row_mode _; do
        case "$row_kind" in
          redirect|copy|refuse) return 0 ;;
          verb) if [ "$row_mode" = unknown ]; then mention=1; else return 0; fi ;;
        esac
      done < <(instruction_write_targets "$tool_cmd" "$names")
      [ -n "$mention" ] || return 1
      # Flattened, because a heredoc puts the interpreter on one line and the open() on the next.
      printf '%s' "${tool_cmd//$'\n'/ }" \
        | grep -Eiq "$(instruction_interp_write_re "$names")" || return 1
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
# the cleanup the span exists to allow, and an untrusted file has no good bytes to go back to. A
# comparison against any other reference — a missing baseline, a new session — never reverts.
revert_growth() {
  local i=$1 delta=$2 vis=${b_vis[$i]} real=${b_real[$i]} src parked fp
  [ "$mode" = check ] || return 1
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
  fp=$(stat -f '%Fm%t%z%t%i' "$real" 2>/dev/null)
  IFS=$'\t' read -r cur_mtime cur_size cur_ino <<<"$fp"
  pin "$vis" "$cur_mtime" "$cur_size" "$cur_ino" "${b_hash[$i]}" "${b_link[$i]}" "$real"
  reverted+=("$vis (+$delta bytes; what it wrote is parked at $parked)")
  report "REVERTED $vis (+$delta bytes)" "$vis" "revert:$grown_key" 0
}

# The hash of a file whose fingerprint moved, taken between two stats that agree: a writer still
# busy while the hash ran leaves a hash of bytes the first stat never described, and the delta
# and the pinned fingerprint have to belong to the bytes that were hashed.
stable_hash() { # real vis
  local k=0 before after
  before="$cur_mtime$_watch_tab$cur_size$_watch_tab$cur_ino"
  while :; do
    cur_hash=$(hash_of "$1" "$2")
    after=$(stat -f '%Fm%t%z%t%i' "$1" 2>/dev/null)
    [ "$after" = "$before" ] && return 0
    k=$((k + 1))
    [ "$k" -lt 3 ] || return 0
    before=$after
    cur_mtime='' cur_size='' cur_ino=''
    IFS=$'\t' read -r cur_mtime cur_size cur_ino <<<"$after"
  done
}

load_baseline() { # file — fills cmd_check's b_* arrays, roots_known and unw_known
  local mtime size ino trust hash link vis real
  [ -f "$1" ] || return 1
  while IFS=$'\t' read -r mtime size ino trust hash link vis real; do
    case "$mtime" in
      '#root') roots_known="$roots_known$size$_watch_nl"; continue ;;
      '#unwatchable') unw_known="$unw_known$size$_watch_nl"; continue ;;
      '#'*) continue ;;
    esac
    [ -n "$real" ] || continue
    b_mtime+=("$mtime"); b_size+=("$size"); b_ino+=("$ino"); b_trust+=("$trust")
    b_hash+=("$hash"); b_link+=("$link"); b_vis+=("$vis"); b_real+=("$real")
  done <"$1"
}

# $4 says what the comparison is against. `check`: this session's own baseline, after one of its
# tool calls. `missing`: that baseline is gone or empty — the event is reported in its own right
# and the newest baseline any session left stands in for it. `between`: a SessionStart, against the
# newest baseline on disk. Only `check` may put growth back; the other two cannot say whose call
# wrote anything.
cmd_check() {
  local baseline=$1 event=$2 sid=$3 mode=${4:-check} ref=${5:-$1}
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

  local -a reports=() keys=() deltas=() restores=() reverted=()
  local -a b_mtime=() b_size=() b_ino=() b_trust=() b_hash=() b_link=() b_vis=() b_real=()
  local roots_known='' unw_known='' pinned='' kind=change sfx='' moved=0 top_rate=''
  local relay_revert='' grown_key=''
  load_baseline "$ref"
  if [ "$mode" = check ] && [ "${#b_real[@]}" -eq 0 ]; then
    mode=missing
    report "BASELINE-MISSING $baseline" "$baseline" "missing@$$.$(date +%s)" 0
    roots_known=''; unw_known=''
    ref=$(newest_baseline "$baseline") && load_baseline "$ref"
  fi
  case "$mode" in
    missing) kind=baseline-missing ;;
    between) kind=changed-between-sessions; sfx=-BETWEEN-SESSIONS ;;
  esac
  [ "$mode" = check ] || moved=1

  local i line real vis cur cur_mtime cur_size cur_ino cur_link cur_hash delta
  local vis_seen vis_ino vis_mtime
  if [ "${#b_real[@]}" -gt 0 ]; then
    # One process for the whole set; %N echoes the path back so the rows can be joined. A
    # missing file makes stat exit 1 AFTER printing every row it could read, so the exit code is
    # deliberately ignored: discarding the output there reported the whole set as deleted.
    # The visible names ride along in the same call: stat does not follow symlinks, so a row for
    # one reports on the link itself — the only way a retargeted or removed link is ever seen.
    # The join is one awk rather than a lookup per row: at a few hundred files a shell scan of the
    # stat output per row is quadratic, and this runs after every tool call.
    local -a targets=() c_real=() c_vis=()
    for i in "${!b_real[@]}"; do
      targets+=("${b_real[$i]}")
      [ "${b_vis[$i]}" = "${b_real[$i]}" ] || targets+=("${b_vis[$i]}")
    done
    while IFS= read -r line; do
      c_real+=("${line%%$'\036'*}"); c_vis+=("${line#*$'\036'}")
    done < <(
      { stat -f '%N%t%Fm%t%z%t%i%t%Y' -- "${targets[@]}" 2>/dev/null; printf '\035\n'
        for i in "${!b_real[@]}"; do printf '%s\t%s\n' "${b_real[$i]}" "${b_vis[$i]}"; done; } |
      LC_ALL=C awk -F'\t' '
        !sep { if ($0 == "\035") { sep = 1; next } if (length($1)) S[$1] = substr($0, length($1) + 2); next }
        { r = ($1 in S) ? S[$1] : ""; v = ($2 != $1 && ($2 in S)) ? S[$2] : ""; print r "\036" v }')

    for i in "${!b_real[@]}"; do
      real=${b_real[$i]}; vis=${b_vis[$i]}
      cur=${c_real[$i]:-}
      vis_seen=''; vis_ino=''; cur_link=''; vis_mtime=''
      if [ "$vis" != "$real" ] && [ -n "${c_vis[$i]:-}" ]; then
        vis_seen=1
        IFS=$'\t' read -r vis_mtime _ vis_ino cur_link <<<"${c_vis[$i]}"
      fi
      if [ -z "$cur" ]; then
        # A recorded target that is gone under a name that still resolves is a retarget, not a
        # deletion: bytes restored at a path the name no longer means would restore nothing.
        if [ "$vis" != "$real" ] && [ -n "$vis_seen" ]; then
          report "RETARGETED$sfx $vis (its recorded target is gone)" "$vis" gone 0
          continue
        fi
        report "DELETED$sfx $vis" "$vis" absent "$((0 - ${b_size[$i]}))"
        offer_restore "$i"
        continue
      fi
      if [ "$vis" != "$real" ]; then
        # The name every session reads is gone or points somewhere else while the file it used to
        # name sits there untouched, reporting nothing. Restoring bytes would answer a question
        # nobody asked, so both of these report and neither offers an undo.
        if [ -z "$vis_seen" ]; then
          report "DELETED$sfx $vis" "$vis" absent "$((0 - ${b_size[$i]}))"
          continue
        fi
        # stat prints nothing for a name that is not a symlink, which is the baseline's `-`.
        if [ "${cur_link:--}" != "${b_link[$i]}" ]; then
          report "RETARGETED$sfx $vis -> ${cur_link:-not a symlink any more}" "$vis" "${cur_link:--}@$vis_mtime" 0
          continue
        fi
      fi
      IFS=$'\t' read -r cur_mtime cur_size cur_ino _ <<<"$cur"
      # A retargeted ANCESTOR symlink (docs/, agents/ — the class dirs are links) changes neither
      # the final component's %Y nor the recorded target, which sits untouched. The name and the
      # target disagreeing on inode is the one trace that leaves.
      if [ "$vis" != "$real" ] && [ "${b_link[$i]}" = '-' ] && [ -n "$vis_ino" ] &&
         [ "$vis_ino" != "$cur_ino" ]; then
        report "RETARGETED$sfx $vis (the name resolves to a different file)" "$vis" "$vis_ino@$vis_mtime" 0
        continue
      fi
      # Fractional mtime and the inode, not whole seconds and a size: a same-size rewrite landing
      # inside the same second was indistinguishable from no write at all, and skipping the hash
      # there is exactly the shape a smuggled edit has. What this still cannot see is a writer that
      # restores the original timestamp to the nanosecond (touch -r does) at an unchanged size and
      # inode; catching that means hashing every file after every call, so the trade is deliberate
      # rather than overlooked.
      if [ "$cur_mtime" = "${b_mtime[$i]}" ] && [ "$cur_size" = "${b_size[$i]}" ] &&
         [ "$cur_ino" = "${b_ino[$i]}" ]; then
        pin "$vis" "${b_mtime[$i]}" "${b_size[$i]}" "${b_ino[$i]}" "${b_hash[$i]}" "${b_link[$i]}" "$real"
        continue
      fi
      # A touched file still has to be hashed, but a rewrite that restored the same bytes
      # is not a change worth a word — only the baseline's stale fingerprint needs refreshing.
      moved=1
      cur_hash=''
      stable_hash "$real" "$vis"
      if [ -z "$cur_hash" ] || [ -z "$cur_size" ]; then
        if [ -e "$real" ]; then
          report "UNWATCHABLE$sfx $vis (it exists but cannot be read)" "$vis" unwatchable 0
        else
          report "DELETED$sfx $vis" "$vis" absent "$((0 - ${b_size[$i]}))"
          offer_restore "$i"
        fi
        continue
      fi
      if [ "$cur_hash" = "${b_hash[$i]}" ]; then
        pin "$vis" "$cur_mtime" "$cur_size" "$cur_ino" "$cur_hash" "${b_link[$i]}" "$real"
        continue
      fi
      delta=$((cur_size - ${b_size[$i]}))
      grown_key="$cur_hash@$cur_mtime"
      if [ "$delta" -gt 0 ] && revert_growth "$i" "$delta"; then
        continue
      fi
      pin "$vis" "$cur_mtime" "$cur_size" "$cur_ino" "$cur_hash" "${b_link[$i]}" "$real"
      [ "$delta" -ge 0 ] && delta="+$delta"
      report "CHANGED$sfx $vis ($delta bytes)" "$vis" "$cur_hash@$cur_mtime" "${delta#+}"
      offer_restore "$i"
    done
  fi

  # A file that appeared under the protected paths is a change too: an agent or a doc
  # nobody approved still lands in every context window from then on. Two arrivals are not: a
  # repository root no baseline has recorded brings its files in with it — this session just
  # opened it — and, outside a check, a path only the ranked cache names is the cache's own re-cut
  # at session start. Against no reference at all there is nothing to call new.
  if [ "${#b_real[@]}" -gt 0 ]; then
    local root_new='' ranked_set='' st ht size mtime ino p
    if [ -n "$repo_root" ]; then
      case "$_watch_nl$roots_known" in *"$_watch_nl$repo_root$_watch_nl"*) ;; *) root_new=1 ;; esac
    fi
    [ "$mode" = check ] || ranked_set="$_watch_nl$(instruction_ranked_names "$RANKED_CACHE")$_watch_nl"
    while IFS= read -r vis; do
      [ -n "$vis" ] || continue
      if [ -n "$root_new" ]; then
        case "$vis" in "$repo_root"/*) moved=1; continue ;; esac
      fi
      if [ "$mode" != check ]; then
        case "$vis" in
          "$HOME"/.claude/*) ;;
          *) case "$ranked_set" in *"$_watch_nl$vis$_watch_nl"*) moved=1; continue ;; esac ;;
        esac
      fi
      moved=1
      st=$(stat -L -f '%R%t%HT%t%Fm%t%z%t%i' -- "$vis" 2>/dev/null) || st=''
      real='' ht='' mtime='' size='' ino=''
      [ -n "$st" ] && IFS=$'\t' read -r real ht mtime size ino <<<"$st"
      cur_hash=''
      [ -n "$size" ] && [ "$ht" != "Symbolic Link" ] && cur_hash=$(hash_of "$real" "$vis")
      if [ -z "$cur_hash" ]; then
        case "$_watch_nl$unw_known" in *"$_watch_nl$vis$_watch_nl"*) continue ;; esac
        { [ -e "$vis" ] || [ -L "$vis" ]; } || continue
        report "UNWATCHABLE$sfx $vis (it exists but cannot be read)" "$vis" unwatchable 0
        continue
      fi
      cur_link='-'
      [ "$vis" = "$real" ] || cur_link=$(stat -f '%Y' "$vis" 2>/dev/null)
      [ -n "$cur_link" ] || cur_link='-'
      pin "$vis" "$mtime" "$size" "$ino" "$cur_hash" "$cur_link" "$real"
      report "ADDED$sfx $vis" "$vis" "$cur_hash@$mtime" "${size:-0}"
      clear_gone_marks "$vis"
    done < <({ printf '%s\n' "${b_vis[@]}"; printf '\035\n'; visible_paths; } |
      LC_ALL=C awk '!sep { if ($0 == "\035") { sep = 1; next } K[$0] = 1; next }
        length($0) && !($0 in K) && !seen[$0]++')
  fi

  # Rebuilding the baseline costs a stat of the whole set, so it happens only when
  # something actually moved. This runs after every call; on the quiet path the
  # whole check is one stat.
  [ "$moved" = 1 ] || exit 0
  if [ "${#reports[@]}" -eq 0 ]; then
    write_baseline "$baseline" "$baseline.$$" "$baseline" "$pinned" || true
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
  if ! alert_once "${keys[0]%%"$_watch_nl"*}" "${keys[0]#*"$_watch_nl"}" "$joined"; then
    stale=" The change journal could not be written, so the baseline was left where it was and this report repeats until it can."
  else
    # A baseline that cannot be rewritten means this same change is reported again after every
    # later call, so the repetition is named rather than left looking like fresh news.
    write_baseline "$baseline" "$baseline.$$" "$baseline" "$pinned" ||
      stale=" The baseline at $baseline could not be rewritten, so this report repeats until it can."
  fi
  # The dearest class in this report, not the global file's rate quoted over a skill that costs
  # a fiftieth of it. A report naming only files this table does not price says nothing at all.
  [ -n "$top_rate" ] && cost=" (up to ~$top_rate full-read equivalents/month)"
  case "$CHAT" in
    all) ;;
    reverts) [ "${#reverted[@]}" -gt 0 ] || exit 0 ;;
    *) exit 0 ;;
  esac
  emit_context "$event" "Instruction-file tripwire: $joined.$stale$undone$undo These files are re-read across sessions$cost, and Egor's standing rule is that they are read-only without his explicit OK in the current turn — no Edit, and equally no shell write. If he approved this change in this turn, nothing to do; this line is the audit trail. If he did not: tell him in ONE line what changed, hand him the restore command if there is one, and carry on with your task. Do NOT run that command and do not undo the change any other way — the writer may be another chat, a worker of yours, a tool that rewrote the file wholesale, or Egor himself, and this hook cannot tell which, so a rollback you decide on your own destroys someone's live work. Restore only if he asks for it."
  exit 0
}

payload=""
[ -t 0 ] || payload=$(cat 2>/dev/null)
# One jq for the whole payload: this runs after every call, and a second interpreter
# start buys nothing.
values=$(printf '%s' "$payload" | jq -er '
  if type != "object" then error("not an object") else . end
  | [(.hook_event_name // "PostToolUse"), (.session_id // ""), (.tool_name // ""),
     (.transcript_path // ""), (.cwd // ""),
     (.tool_input.file_path // .tool_input.notebook_path // ""), (.tool_input.command // "")]
  | join("\u001f")' 2>/dev/null) ||
  { echo "instruction watch: the hook payload does not parse, so no change can be attributed" >&2; exit 2; }
# NUL-delimited rather than a line read, and the command last: a Bash command is routinely several
# lines, and a line read would keep only its first one.
IFS=$'\x1f' read -r -d '' event sid tool transcript cwd tool_path tool_cmd <<<"$values" || :
# A read that found no field at all leaves the newline the here-string added, and that newline is
# the event name every emitted record would carry.
case "${event:-}" in ''|*[!A-Za-z]*) event=PostToolUse ;; esac
tool_cmd=${tool_cmd%$'\n'}
repo_root=$(instruction_repo_root "${cwd:-}") || repo_root=''
baseline=$(session_baseline "${sid:-}")

case "${1:-check}" in
  baseline) cmd_baseline "$baseline" ;;
  check)    cmd_check "$baseline" "$event" "$sid" ;;
  *)        exit 0 ;;
esac
