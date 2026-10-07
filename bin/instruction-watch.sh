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
# "This call produced it" is read off the clock, never off the command text: the PreToolUse gates
# mark the call in flight (`inflight/<session>`), and bytes whose mtime lies between that mark and
# this check are the call's — unless another session's mark covers the same instant too.
#
# Everything this hook keeps on disk — the baselines, the ranked cache, the alert markers — is a
# file the model can write, so it is evidence and never authority: a baseline that is gone or empty
# is itself an event (BASELINE-MISSING), a new session compares against the newest baseline any
# session left (the -BETWEEN-SESSIONS reports), and a path the ranked cache stops naming stays
# watched for as long as it exists. When this hook cannot run at all — its library, jq or the
# payload missing — it exits 2 with the reason instead of passing silently.
#
# Hot path cost is one enumeration, one stat process and one awk join per call: only the rows
# whose fingerprint moved reach the shell, and a hash runs only for those.
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

[ -n "${HOME:-}" ] || exit 0

LOG_FILE="${INSTRUCTION_WATCH_LOG:-$HOME/.claude/instruction-changes.log}"
# A rolled-back writer must be told or it may repeat the write.
CHAT="${INSTRUCTION_WATCH_CHAT:-reverts}"

# ~/.claude/hooks is a symlink into the config repository and the entry there is a symlink
# into this one, so follow the chain rather than the first hop.
self=$0
for _ in 1 2 3 4 5; do
  [ -L "$self" ] || break
  target=$(readlink "$self")
  case "$target" in /*) self=$target ;; *) self=${self%/*}/$target ;; esac
done
case "$self" in */*) self=${self%/*} ;; *) self=. ;; esac
. "$self/../share/gate-journal.sh" 2>/dev/null || gate_journal() { :; }
. "$self/../share/instruction-files.sh" 2>/dev/null ||
  { gate_journal watch fault '' '' '' 'share/instruction-files.sh missing'
    echo "instruction watch: cannot load share/instruction-files.sh, so no instruction-file change can be seen" >&2; exit 2; }
command -v jq >/dev/null 2>&1 ||
  { gate_journal watch fault '' '' '' 'jq missing'
    echo "instruction watch: jq is missing, so the hook payload cannot be read" >&2; exit 2; }

STATE_DIR=$(instruction_watch_state)
RANKED_CACHE="$STATE_DIR/ranked.txt"
repo_root=''

visible_set='' visible_ready='' ranked_names=''
# Enumerated once per run: the check, the between-sessions check and the rewrite all ask for it.
load_visible() {
  ranked_names=$(instruction_ranked_names "$RANKED_CACHE")
  visible_set=$(instruction_visible_cached "$HOME" "$RANKED_CACHE" "$repo_root" "$STATE_DIR")
  visible_ready=1
}
visible_paths() {
  [ -n "$visible_ready" ] || load_visible
  printf '%s\n' "$visible_set"
}

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
RECEIPT_DIR="$STATE_DIR/receipts"
INFLIGHT_DIR="$STATE_DIR/inflight"
CLOSED_DIR="$STATE_DIR/closed"
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
  prune_reverts
  # Named by content, as the snapshot is: every session that reports this version shares one copy.
  # A copy per report grew the directory to 159k files, and the prune's scan of it outran the hook's
  # timeout on every call. The touch keeps a copy a report just named clear of the week's prune.
  stamp="$REVERT_DIR/$(basename "$src")"
  # -c and the re-check: the prune just launched in the background may delete an old copy between
  # the test and the touch, and a plain touch would recreate it empty.
  if [ -f "$stamp" ] && touch -c "$stamp" 2>/dev/null && [ -f "$stamp" ]; then
    :
  else
    cp "$src" "$stamp.tmp.$$" 2>/dev/null && mv -f "$stamp.tmp.$$" "$stamp" 2>/dev/null ||
      { rm -f "$stamp.tmp.$$" 2>/dev/null; return 1; }
  fi
  printf '%s' "$stamp"
}

prune_reverts() {
  local mark="$STATE_DIR/reverts.pruned"
  [ -z "$(find "$mark" -mmin -60 2>/dev/null)" ] || return 0
  : >"$mark" 2>/dev/null || return 0
  ( find "$REVERT_DIR" -mindepth 1 -maxdepth 1 -mtime +7 -delete </dev/null >/dev/null 2>&1 & )
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
# recorded as `#unwatchable`, so it is reported once rather than on every call. The `#ranked` rows,
# led by an empty one marking that they were recorded, are the names the ranked cache held.
write_baseline() {
  local out=$1 tmp=$2 prior=${3:-} pinned=${4:-} p real mtime size ino link hash trust ht line i k t
  local trusted='' had_prior='' kept='' roots=''
  local -a rows=()
  local nl=$_watch_nl
  if [ -n "$prior" ] && [ -f "$prior" ]; then
    had_prior=1
    # An older row format lands a fourth column other than 0/1. Distrusting the whole set over it
    # would be permanent — every later rewrite reads back the zeros this one wrote — so a prior
    # this one cannot parse counts as no prior at all, from that row on.
    { IFS= read -r -d $'\035' roots; IFS= read -r -d $'\035' kept; IFS= read -r -d $'\035' trusted
      IFS= read -r line; } < <(LC_ALL=C awk -F'\t' "$_watch_row_awk"'
        F[1] == "#root" { if (F[2] != "") print F[2]; next }
        F[1] ~ /^#/ || F[4] F[7] == "" { next }
        F[4] != "1" && F[4] != "0" { bad = 1; exit }
        F[4] == "1" && F[7] != "" { T[++nt] = F[7] }
        F[7] != "" { K[++nk] = F[7] }
        END {
          printf "\035"; if (!bad) for (k = 1; k <= nk; k++) print K[k]
          printf "\035"; if (!bad) for (k = 1; k <= nt; k++) print T[k]
          printf "\035%s\n", bad ? "bad" : ""
        }' "$prior")
    [ -z "$line" ] || had_prior=''
  fi
  [ -n "$repo_root" ] && roots="$roots$repo_root$nl"
  [ -n "$visible_ready" ] || load_visible
  : >"$tmp" || return 1
  printf '%s' "$roots" | LC_ALL=C awk 'length && !seen[$0]++ { print "#root\t" $0 }' >>"$tmp"
  printf '\n%s\n' "$ranked_names" | LC_ALL=C awk 'NR == 1 || (length && !seen[$0]++) { print "#ranked\t" $0 }' >>"$tmp"
  mkdir -p "$SNAP_DIR" 2>/dev/null

  local -a wp=() wpin=() wst=() wtrust=()
  while IFS= read -r line; do
    wp+=("${line%%$'\036'*}"); line=${line#*$'\036'}
    wpin+=("${line%$'\036'*}"); wtrust+=("${line##*$'\036'}")
  done < <({ printf '%s' "$trusted"; printf '\035\n'; printf '%s\n' "$pinned"; printf '\035\n'
             visible_paths; printf '%s' "$kept"; } |
    LC_ALL=C awk -F'\t' '
      sep == 0 { if ($0 == "\035") { sep = 1; next } T[$0] = 1; next }
      sep == 1 { if ($0 == "\035") { sep = 2; next }
                 if (length($1)) { P[$1] = substr($0, length($1) + 2); order[++n] = $1 }
                 next }
      length($0) && !seen[$0]++ { print $0 "\036" P[$0] "\036" ($0 in T) }
      END { for (k = 1; k <= n; k++) if (!seen[order[k]]++) print order[k] "\036" P[order[k]] "\036" (order[k] in T) }')
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
          # shasum escapes a name holding a backslash and flags its line with a leading one.
          !sep { if ($0 == "\035") { sep = 1; next }
                 if (substr($0, 1, 1) != "\\") { H[substr($0, 67)] = $1; next }
                 name = substr($0, 68); gsub(/\\\\/, "\\", name); H[name] = substr($1, 2); next }
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
    [ -z "$had_prior" ] || trust=${wtrust[$i]}
    t=$_watch_tab
    rows+=("${r_m[$i]}$t${r_s[$i]}$t${r_i[$i]}$t$trust$t${r_h[$i]}$t${r_l[$i]}$t$p$t${r_r[$i]}")
    [ "$trust" = 1 ] && [ -n "${r_snap[$i]}" ] && [ "${r_s[$i]}" -le "$SNAP_MAX_BYTES" ] 2>/dev/null &&
      snap_idx+=("$i")
  done
  [ "${#rows[@]}" -eq 0 ] || printf '%s\n' "${rows[@]}" >>"$tmp" || return 1

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

session_baseline() {
  printf '%s/session-%s.tsv' "$STATE_DIR" "$(instruction_sid_name "$1")"
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
  local sent=$1 id=$2 summary=$3 line files='' k chat='' c cands='' writer owner='' observer=''
  writer=$(record_writer ${won_attrs[@]+"${won_attrs[@]}"})
  if [ "$writer" = this-call ] || [ "${kind:-change}" = baseline-missing ]; then
    owner=${sid:-}
    [ -z "$owner" ] || chat=$(instruction_chat_name "$owner") || chat=''
  else
    observer=${sid:-}
  fi
  for k in "${won_keys[@]}"; do files="$files${k%%"$_watch_nl"*}$_watch_nl"; done
  for c in ${won_cands[@]+"${won_cands[@]}"}; do
    cands="$cands$c$_watch_tab$(instruction_chat_name "$c" | head -n 1)$_watch_nl"
  done
  line=$(jq -cn --arg id "$id" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg sid "$owner" --arg observer "$observer" --arg summary "$summary" --arg sent "$sent" --arg kind "${kind:-change}" \
    --arg chat "$chat" --arg bytes "$(printf '%s\n' ${won_deltas[@]+"${won_deltas[@]}"})" \
    --arg files "$files" --arg restores "$(printf '%s\n' ${won_restores[@]+"${won_restores[@]}"})" \
    --arg reverted "$(printf '%s\n' ${won_reverted[@]+"${won_reverted[@]}"})" \
    --arg writer "$writer" --arg cands "$cands" \
    '{id:$id,at:$at,sid:$sid,kind:$kind,summary:$summary,sent:$sent,writer:$writer,
      files:($files|split("\n")|map(select(length>0))),
      bytes:($bytes|split("\n")|map(select(length>0)|tonumber)),
      restores:($restores|split("\n")|map(select(length>0))),
      reverted:($reverted|split("\n")|map(select(length>0)))} +
      (if $chat != "" then {chat:$chat} else {} end) +
      (if $observer != "" then {observer:$observer} else {} end) +
      (if $cands != "" then {candidates:($cands|split("\n")|map(select(length>0)|split("\t")
        | {sid:.[0]} + (if (.[1] // "") != "" then {chat:.[1]} else {} end)))} else {} end)' \
    2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  instruction_journal_append "$line"
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
# A key naming one write (`…@mtime`) ends in `w`: instruction_mark_once keeps those while any
# baseline that predates them is on disk, and a state key such as `absent` a day.
watch_mark_key() { # path content-key
  local key
  key=$(printf '%s\n%s\n' "$1" "$2" | shasum -a 256 | cut -c1-16)
  case "$2" in *@*) key="${key}w" ;; esac
  printf '%s\n' "$key"
}

clear_gone_marks() { # path
  local g
  for g in absent gone; do
    rmdir "$ALERT_DIR/$(watch_mark_key "$1" "$g")" 2>/dev/null || true
  done
}

release_marks() { # key...
  local key last
  for key; do
    rmdir "$ALERT_DIR/$key" 2>/dev/null || true
    for last in "$ALERT_DIR"/*.last; do
      [ "$(cut -d' ' -f2 "$last" 2>/dev/null)" = "$key" ] && rm -f "$last"
    done
  done
}

# The write key carries the mtime, so a rewrite of the same bytes (a rebase putting them back) is a
# new key, and a session whose baseline predates the first write would journal its growth again.
# `.last` holds the content the journal last carried for the path; any other kind of report clears
# it, so a deletion and the same bytes coming back are two records.
watch_claim() { # path content-key → the key on stdout when this caller journals the write
  local key hash=${2%@*} last
  last="$ALERT_DIR/$(watch_mark_key "$1" last).last"
  [[ $2 == *@* && $hash =~ ^[0-9a-f]{64}$ ]] || hash=''
  [ -n "$hash" ] && [ "$(cut -d' ' -f1 "$last" 2>/dev/null)" = "$hash" ] && return 1
  key=$(watch_mark_key "$1" "$2")
  instruction_mark_once "$ALERT_DIR" "$key" "$STATE_DIR" || return 1
  if [ -n "$hash" ]; then printf '%s %s\n' "$hash" "$key" > "$last"; else rm -f "$last"; fi 2>/dev/null
  printf '%s\n' "$key"
}

# 1 when the journal could not take the record: the caller then keeps its baseline where it was, so
# the change is found and reported again rather than absorbed unrecorded.
alert_once() { # path content-key summary
  local key sent=unsent id='' claimed='' i c summary=''
  local -a won_keys=() won_deltas=() won_attrs=() won_restores=() won_reverted=() won_cands=()
  # Keying only keys[0] skipped the rest of a multi-file check when that first
  # file was already marked by another session. Everything of a file another session's claim
  # already journaled stays out of this record — its writer and restore included — or the doctor
  # counts that one write twice.
  for i in "${!keys[@]}"; do
    if key=$(watch_claim "${keys[$i]%%"$_watch_nl"*}" "${keys[$i]#*"$_watch_nl"}"); then
      claimed="$claimed$key "
      [ -n "$id" ] || id=$key
      won_keys+=("${keys[$i]}"); won_deltas+=("${deltas[$i]}")
      [ -z "${r_attr[$i]}" ] || won_attrs+=("${r_attr[$i]}")
      [ -z "${r_restore[$i]}" ] || won_restores+=("${r_restore[$i]}")
      [ -z "${r_revert[$i]}" ] || won_reverted+=("${r_revert[$i]}")
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        case "$_watch_nl$(printf '%s\n' ${won_cands[@]+"${won_cands[@]}"})$_watch_nl" in *"$_watch_nl$c$_watch_nl"*) continue ;; esac
        won_cands+=("$c")
      done <<<"${r_cands[$i]}"
      summary="$summary${summary:+; }${reports[$i]}"
    fi
  done
  [ -n "$id" ] || return 0
  # Receipts live 30d, a marker a day or more; reusing the marker as the journal id lets
  # a leftover receipt swallow a same-bytes repeat after the marker expires.
  id=$(printf '%s\n%s\n%s\n%s\n' "$id" "$$" "$RANDOM" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    | shasum -a 256 | cut -c1-16)
  instruction_alert_sendable && sent=attempted
  if ! journal_event "$sent" "$id" "$summary"; then
    # A failed append would otherwise leave the change claimed and unjournaled.
    release_marks $claimed
    return 1
  fi
  instruction_alert_poke || return 0
}

# SessionStart. The baseline it writes is compared first against the newest one on disk — this
# session's own on a resume or a compaction, else whatever another session left — because
# everything that changed while no session of this one was watching would otherwise be absorbed
# into the new baseline unreported.
cmd_baseline() {
  local out=$1 ref=''
  mkdir -p "$STATE_DIR" 2>/dev/null || { gate_journal watch fault "$sid" '' '' 'state dir not creatable'; exit 0; }
  if has_rows "$out"; then ref=$out; else ref=$(newest_baseline "$out") || ref=''; fi
  # The per-session baselines age out at a week. Snapshots outlive them by far, because the
  # version a file has sat at for a month is exactly the one worth being able to restore; only a
  # version no baseline has vouched for since is abandoned. Every write refreshes the mtime of
  # the version still in use, so what this reaches is superseded copies alone.
  find "$STATE_DIR" -mindepth 1 -maxdepth 1 \( -name 'session-*' ! -path "${ref:-/}" -mtime +7 \
    -o -name 'visible-*' -mtime +1 \) -delete 2>/dev/null
  find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type f -mtime +90 -delete 2>/dev/null
  find "$RECEIPT_DIR" -mindepth 1 -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null
  find "$ALERT_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.last' -mtime +30 -delete 2>/dev/null
  # A read-only call that exits non-zero gets no PostToolUse, so its note is never taken.
  find "$STATE_DIR/readonly" -mindepth 1 -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null
  instruction_ranked_refresh "$HOME" "$RANKED_CACHE" || true
  load_visible
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
  r_attr+=("$pending_attr"); r_cands+=("$pending_cands"); r_restore+=(''); r_revert+=('')
  pending_attr='' pending_cands=''
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
  r_restore[$((${#reports[@]} - 1))]=${restores[$((${#restores[@]} - 1))]}
}

inflight_window() { # file name start agent
  if [ "$2" = "$own_name" ]; then
    own_count=$((own_count + 1))
    if [ -z "$tool_use_id" ]; then
      own_file=$1; own_start=$3
    elif [ "$4" = "$own_agent" ]; then
      own_stale+=("$1"); own_stale_starts+=("$3")
    fi
    return 0
  fi
  other_sids+=("$2"); other_starts+=("$3"); other_ends+=("")
}

# The in-flight windows, read once per check: this session's own mark, consumed only when it names
# this call's tool_use_id (a call another PreToolUse hook denied never reaches PostToolUse and
# leaves its mark behind) and never aged out, since this call is alive however long it ran; every
# other mark older than an hour is a call that died and is swept without a word — unless this call
# itself ran over an hour, when an equally old mark may be just as alive and stays a window.
load_inflight() {
  local f name m_start m_id m_agent m_end start own_name own_file='' own_count=0 k own_agent
  local aged_files=() aged_names=() aged_starts=() aged_agents=() own_stale=() own_stale_starts=()
  instruction_ns_to now_ns "$(instruction_now)" || { now_ns=''; return 0; }
  own_name=$(instruction_sid_name "$sid")
  own_agent=${agent_id:--}
  own_agent=${own_agent//[^A-Za-z0-9._-]/_}
  for f in "$INFLIGHT_DIR"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    name=${name%%@*}
    read -r m_start m_id _ m_agent _ <"$f" 2>/dev/null || continue
    instruction_ns_to start "$m_start" || continue
    if [ "$name" = "$own_name" ] && [ -n "$tool_use_id" ] && [ "$m_id" = "${tool_use_id//[^A-Za-z0-9._-]/_}" ]; then
      own_count=$((own_count + 1)); own_file=$f; own_start=$start
      continue
    fi
    if [ $((now_ns - start)) -gt 3600000000000 ]; then
      aged_files+=("$f"); aged_names+=("$name"); aged_starts+=("$start"); aged_agents+=("$m_agent")
      continue
    fi
    inflight_window "$f" "$name" "$start" "$m_agent"
  done
  # A consumed mark stays a window for ten minutes: the writer's own check takes its mark away, and
  # another chat's long call covering the same instant would then read the bytes as its own.
  for f in "$CLOSED_DIR"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    name=${name%%@*}
    read -r start m_end _ <"$f" 2>/dev/null || continue
    case "$start$m_end" in ''|*[!0-9]*) rm -f "$f" 2>/dev/null; continue ;; esac
    if [ $((now_ns - m_end)) -gt 600000000000 ]; then rm -f "$f" 2>/dev/null; continue; fi
    [ "$name" = "$own_name" ] && continue
    other_sids+=("$name"); other_starts+=("$start"); other_ends+=("$m_end")
  done
  for k in ${aged_files[@]+"${!aged_files[@]}"}; do
    if [ -n "$own_start" ] && [ $((now_ns - own_start)) -gt 3600000000000 ]; then
      inflight_window "${aged_files[$k]}" "${aged_names[$k]}" "${aged_starts[$k]}" "${aged_agents[$k]}"
    else
      rm -f "${aged_files[$k]}" 2>/dev/null
    fi
  done
  # Without a tool_use_id only a lone mark can be this call's; with several, any could be.
  if [ -z "$tool_use_id" ] && [ "$own_count" -gt 1 ]; then
    own_file=''; own_start=''
  fi
  # Calls of one agent start together or in turn, so its mark a minute older than this call's is a
  # call another hook denied: it never reaches a check, and every other chat's watcher read it as live.
  # Parallel subagents share the session id, and another agent's older mark is its live long call.
  if [ -n "$own_file" ]; then
    for k in ${own_stale[@]+"${!own_stale[@]}"}; do
      [ "${own_stale_starts[$k]}" -lt $((own_start - 60000000000)) ] && rm -f "${own_stale[$k]}" 2>/dev/null
    done
    mkdir -p "$CLOSED_DIR" 2>/dev/null &&
      printf '%s %s\n' "$own_start" "$now_ns" >"$CLOSED_DIR/${own_file##*/}" 2>/dev/null
    rm -f "$own_file" 2>/dev/null
  fi
}

add_candidate() {
  case "$_watch_nl$pending_cands" in *"$_watch_nl$1$_watch_nl"*) return 0 ;; esac
  pending_cands="$pending_cands$1$_watch_nl"
}

# Who wrote bytes that landed at mtime $1: `this-call` when they fall inside this call's window
# alone, `ambiguous` when another session's window covers the same instant, `unknown` otherwise —
# including every check the gate did not mark, since only a mark says a call of this session ran.
attribute() { # mtime
  local m k hit=''
  attr=unknown pending_attr=unknown
  [ -n "$now_ns" ] || return 0
  m=$(instruction_ns "$1") || return 0
  if [ -n "$own_start" ] && [ "$m" -ge "$own_start" ] && [ "$m" -le "$now_ns" ]; then
    attr=this-call
  fi
  for k in ${other_starts[@]+"${!other_starts[@]}"}; do
    [ "$m" -ge "${other_starts[$k]}" ] && [ "$m" -le "${other_ends[$k]:-$now_ns}" ] || continue
    hit=1
    add_candidate "${other_sids[$k]}"
  done
  if [ "$attr" = this-call ] && [ -n "$hit" ]; then
    attr=ambiguous
    add_candidate "$(instruction_sid_name "$sid")"
  fi
  pending_attr=$attr
}

record_writer() { # attr...
  case " $* " in
    *" ambiguous "*) printf ambiguous ;;
    *" unknown "*) printf unknown ;;
    *" this-call "*) printf this-call ;;
    *) printf unknown ;;
  esac
}

# Growth put back rather than reported. Three conditions, every one of them required:
#   - the file is one the write gate speaks for (instruction_write_class), which leaves out
#     settings.json — the harness rewrites that on its own and no gate ever denied it;
#   - the bytes landed while this session's call was in flight and no other session's was
#     (`attribute`). A shared checkout means the writer is as often another chat or a worker as
#     this session, and a rollback decided on a guess eats that chat's live work;
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
  [ "$attr" = this-call ] || return 1
  # Asked of every rollback and not only of the ones the span did not already authorise: WHO wrote
  # decides the wording, and a worker inside a span told to leave the addition for Egor's next turn
  # is a worker handed a human's instruction instead of the MD-PROPOSAL protocol it answers by.
  ! instruction_in_relay || relay_revert=1
  if ! instruction_autonomous "$sid" "$transcript" || instruction_span_live "$sid" "$transcript"; then
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
  r_revert[$((${#reports[@]} - 1))]=${reverted[$((${#reverted[@]} - 1))]}
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

# Splits a baseline row the way `IFS=$'\t' read` does — a run of tabs is one separator — into
# F[1..8], n being the field count, so awk and the shell agree on which rows exist.
_watch_row_awk='{ row = $0; gsub(/\t+/, "\t", row); sub(/^\t/, "", row); sub(/\t$/, "", row)
  n = split(row, F, "\t"); for (k = 9; k <= n; k++) F[8] = F[8] "\t" F[k] }
  F[1] !~ /^#/ && unloaded(F[7]) { next }'"$_instruction_unloaded_awk"
export _INSTRUCTION_HOME=$HOME _INSTRUCTION_UNLOADED_ERE=$INSTRUCTION_HOME_UNLOADED_ERE

# Only rows whose fingerprint moved reach the b_* arrays; the rest go straight to `pinned`. The
# visible names ride along in the same stat: stat does not follow symlinks, so a row for one
# reports on the link itself — the only way a retargeted or removed link is ever seen. A missing
# file makes stat exit 1 AFTER printing every row it could read, so the exit code is ignored.
load_baseline() { # file
  local mtime size ino trust hash link vis real line IFS=$'\n'
  local -a targets=()
  [ -f "$1" ] || return 1
  set -f
  targets=($(LC_ALL=C awk -F'\t' "$_watch_row_awk"'
    n >= 8 && F[1] !~ /^#/ { if (!seen[F[8]]++) print F[8]; if (!seen[F[7]]++) print F[7] }' "$1"))
  set +f
  # Captured whole and split on IFS: a here-string this size costs bash a forked writer and a
  # byte-wise `read` (14 ms CPU, ~55 ms wall per quiet check), and a `%%` pattern over it is quadratic.
  local rows
  local -a parts=()
  rows=$(
    { [ "${#targets[@]}" -eq 0 ] || stat -f '%N%t%Fm%t%z%t%i%t%Y' -- "${targets[@]}" 2>/dev/null; } |
    LC_ALL=C awk -F'\t' '
      FILENAME == "-" { if (length($1)) S[$1] = substr($0, length($1) + 2); next }
      '"$_watch_row_awk"'
      F[1] ~ /^#/ { rest[++nr] = $0; next }
      n < 8 { next }
      {
        all[++na] = F[7]
        r = (F[8] in S) ? S[F[8]] : ""; v = (F[7] != F[8] && (F[7] in S)) ? S[F[7]] : ""
        split(r, R, "\t"); split(v, V, "\t")
        # Compared as strings: 1.50 and 1.5 are one number and two different mtimes.
        if (r != "" && "x" R[1] == "x" F[1] && "x" R[2] == "x" F[2] && "x" R[3] == "x" F[3] &&
            (F[7] == F[8] || (v != "" && (V[4] == "" ? "-" : V[4]) == F[6] && (F[6] != "-" || V[3] == R[3])))) {
          print F[7] "\t" F[1] "\t" F[2] "\t" F[3] "\t" F[5] "\t" F[6] "\t" F[8]
          next
        }
        rest[++nr] = $0 "\036" r "\036" v
      }
      END {
        printf "\035"; for (k = 1; k <= na; k++) print all[k]
        printf "\035"; for (k = 1; k <= nr; k++) print rest[k]
      }' - "$1")
  set -f
  IFS=$'\035'
  parts=($rows)
  IFS=$'\n'
  set +f
  pinned=${parts[0]:-}
  b_all=${parts[1]:-}
  {
    while IFS= read -r line; do
      IFS=$'\t' read -r mtime size ino trust hash link vis real <<<"${line%%$'\036'*}"
      case "$mtime" in
        '#root') roots_known="$roots_known$size$_watch_nl"; continue ;;
        '#ranked') ranked_rec=1; [ -z "$size" ] || ranked_known="$ranked_known$size$_watch_nl"; continue ;;
        '#unwatchable') unw_known="$unw_known$size$_watch_nl"; continue ;;
        '#'*) continue ;;
      esac
      [ -n "$real" ] || continue
      b_mtime+=("$mtime"); b_size+=("$size"); b_ino+=("$ino"); b_trust+=("$trust")
      b_hash+=("$hash"); b_link+=("$link"); b_vis+=("$vis"); b_real+=("$real")
      line=${line#*$'\036'}
      c_real+=("${line%%$'\036'*}"); c_vis+=("${line#*$'\036'}")
    done
  } <<<"${parts[2]:-}"
}

# $4 says what the comparison is against. `check`: this session's own baseline, after one of its
# tool calls. `missing`: that baseline is gone or empty — the event is reported in its own right
# and the newest baseline any session left stands in for it. `between`: a SessionStart, against the
# newest baseline on disk. Only `check` may put growth back; the other two cannot say whose call
# wrote anything.
cmd_check() {
  local baseline=$1 event=$2 sid=$3 mode=${4:-check} ref=${5:-$1}
  local budget=${INSTRUCTION_WATCH_BUDGET:-20}
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || { gate_journal watch fault "$sid" '' '' 'state dir not creatable'; exit 0; }
  [ -n "$visible_ready" ] || load_visible

  local -a reports=() keys=() deltas=() restores=() reverted=() r_attr=() r_cands=() r_restore=() r_revert=()
  local -a b_mtime=() b_size=() b_ino=() b_trust=() b_hash=() b_link=() b_vis=() b_real=() c_real=() c_vis=()
  local roots_known='' unw_known='' pinned='' b_all='' kind=change sfx='' moved=0 top_rate=''
  local ranked_known='' ranked_rec=''
  local relay_revert='' grown_key=''
  local attr='' own_start='' now_ns='' pending_attr='' pending_cands=''
  local -a other_sids=() other_starts=() other_ends=()
  [ "$mode" != check ] || load_inflight
  load_baseline "$ref"
  if [ "$mode" = check ] && [ -z "$b_all" ]; then
    mode=missing
    report "BASELINE-MISSING $baseline" "$baseline" "missing@$$.$(date +%s)" 0
    roots_known=''; unw_known=''; ranked_known=''; ranked_rec=''
    ref=$(newest_baseline "$baseline") && load_baseline "$ref"
  fi
  case "$mode" in
    missing) kind=baseline-missing ;;
    between) kind=changed-between-sessions; sfx=-BETWEEN-SESSIONS ;;
  esac
  [ "$mode" = check ] || moved=1

  local i line real vis cur cur_mtime cur_size cur_ino cur_link cur_hash delta
  local vis_seen vis_ino vis_mtime handled=0 deferred=''
  if [ "${#b_real[@]}" -gt 0 ]; then
    for i in "${!b_real[@]}"; do
      real=${b_real[$i]}; vis=${b_vis[$i]}
      # Past the budget a moved file keeps its old fingerprint, so the next call reports it: a
      # check the hook timeout kills advances nothing and repeats every report it had made.
      if [ "$handled" -gt 0 ] && [ "$SECONDS" -ge "$budget" ]; then
        pin "$vis" "${b_mtime[$i]}" "${b_size[$i]}" "${b_ino[$i]}" "${b_hash[$i]}" "${b_link[$i]}" "$real"
        continue
      fi
      handled=$((handled + 1))
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
      attribute "$cur_mtime"
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
  # opened it — and a path only the ranked cache names is the cache's own re-cut: at session start,
  # or inside a check another session's, since the cache is shared. The baseline's `#ranked` rows
  # are the names the cache held when this session last fixed its watch set: a newcomer among them
  # was added, whatever its mtime says. Against no reference at all there is nothing to call new.
  if [ -n "$b_all" ]; then
    local root_new='' ranked_set='' st ht size mtime ino p
    if [ -n "$repo_root" ]; then
      case "$_watch_nl$roots_known" in *"$_watch_nl$repo_root$_watch_nl"*) ;; *) root_new=1 ;; esac
    fi
    ranked_set="$_watch_nl$ranked_names$_watch_nl"
    while IFS= read -r vis; do
      [ -n "$vis" ] || continue
      if [ -n "$root_new" ]; then
        case "$vis" in "$repo_root"/*) moved=1; continue ;; esac
      fi
      case "$vis" in
        "$HOME"/.claude/*) ;;
        *) case "$ranked_set" in *"$_watch_nl$vis$_watch_nl"*)
             if [ "$mode" != check ] || { [ -n "$ranked_rec" ] &&
                 case "$_watch_nl$ranked_known" in *"$_watch_nl$vis$_watch_nl"*) false ;; esac; }; then
               moved=1; continue
             fi ;;
           esac ;;
      esac
      if [ "$handled" -gt 0 ] && [ "$SECONDS" -ge "$budget" ]; then
        deferred="$deferred$vis$_watch_nl"
        continue
      fi
      handled=$((handled + 1))
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
      attribute "$mtime"
      report "ADDED$sfx $vis" "$vis" "$cur_hash@$mtime" "${size:-0}"
      clear_gone_marks "$vis"
    done < <({ printf '%s' "$b_all"; printf '\035\n'; visible_paths; } |
      LC_ALL=C awk '!sep { if ($0 == "\035") { sep = 1; next } K[$0] = 1; next }
        length($0) && !($0 in K) && !seen[$0]++')
  fi
  # An arrival left for the next call stays out of the rewritten baseline, or it would be absorbed.
  [ -z "$deferred" ] || visible_set=$({ printf '%s\035\n' "$deferred"; printf '%s\n' "$visible_set"; } |
    LC_ALL=C awk '!sep { if ($0 == "\035") { sep = 1; next } D[$0] = 1; next } !($0 in D)')

  # Rebuilding the baseline costs a stat of the whole set, so it happens only when
  # something actually moved. This runs after every call; on the quiet path the
  # whole check is one stat.
  # The touch is the session's last-hook stamp the week-old sweep in cmd_baseline keys on: a quiet
  # session never rewrites its baseline, and the file's mtime would otherwise say it is dead.
  if [ "$moved" != 1 ]; then
    [ "$mode" != check ] || touch -c "$baseline" 2>/dev/null
    exit 0
  fi
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
  emit_context "$event" "Instruction-file tripwire: $joined.$stale$undone$undo $(instruction_standing_rule)${cost:+ These cost$cost.} If this change keeps to that rule, nothing to do; this line is the audit trail. If it does not: tell him in ONE line what changed, hand him the restore command if there is one, and carry on with your task. Do NOT run that command and do not undo the change any other way — the writer may be another chat, a worker of yours, a tool that rewrote the file wholesale, or Egor himself, and this hook cannot tell which, so a rollback you decide on your own destroys someone's live work. Restore only if he asks for it."
  exit 0
}

# One jq straight off stdin for the whole payload: this runs after every call, and a second
# process start buys nothing.
values=$([ ! -t 0 ] && jq -er '
  if type != "object" then error("not an object") else . end
  | [(.hook_event_name // "PostToolUse"), (.session_id // ""), (.transcript_path // ""),
     (.tool_use_id // "" | tostring), (.cwd // ""), (.agent_id // "" | tostring)]
  | join("\u001f")' 2>/dev/null) ||
  { gate_journal watch fault '' '' '' 'payload does not parse'
    echo "instruction watch: the hook payload does not parse, so no change can be attributed" >&2; exit 2; }
IFS=$'\x1f' read -r -d '' event sid transcript tool_use_id cwd agent_id <<<"$values" || :
if [ "${1:-check}" = check ] && instruction_readonly_take "${sid:-}" "${tool_use_id:-}"; then
  exit 0
fi
# A read that found no field at all leaves the newline the here-string added, and that newline is
# the event name every emitted record would carry.
case "${event:-}" in ''|*[!A-Za-z]*) event=PostToolUse ;; esac
cwd=${cwd%$'\n'}
agent_id=${agent_id%$'\n'}
repo_root=$(instruction_repo_root "${cwd:-}") || repo_root=''
baseline=$(session_baseline "${sid:-}")

case "${1:-check}" in
  baseline) cmd_baseline "$baseline" ;;
  check)    cmd_check "$baseline" "$event" "$sid" ;;
  *)        gate_journal watch fault "$sid" '' '' "unknown mode ${1:-}"; exit 0 ;;
esac
exit; }
