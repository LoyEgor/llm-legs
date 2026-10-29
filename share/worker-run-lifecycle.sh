# worker-run, run lifecycle: start, supervise, run state and journals; sourced by bin/worker-run in place, so
# an edit here runs its own suites rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

file_lstat() { # path -> FILE_SIZE FILE_MTIME FILE_INODE of the path itself, mtime in whole seconds
  local -A st=()
  local out rc
  if [ -n "$STAT_BUILTIN" ]; then
    enable stat
    stat -L -A st "$1" 2>/dev/null
    rc=$?
    enable -n stat
    [ "$rc" -eq 0 ] || return 1
    FILE_SIZE=${st[size]} FILE_MTIME=${st[mtime]} FILE_INODE=${st[inode]}
    return 0
  fi
  # Apart: GNU stat takes -f for a filesystem query, prints its answer and fails.
  out=$(stat -f '%z %m %i' "$1" 2>/dev/null) || out=$(stat -c '%s %Y %i' "$1" 2>/dev/null) || return 1
  read -r FILE_SIZE FILE_MTIME FILE_INODE <<<"$out"
}

# Whether a run's meta.json is the one last read under this key variable. Every write after its
# creation is a rename, so a rewrite always shows as a new inode.
meta_unchanged() { # directory key-variable
  local key=''
  [ -n "$STAT_BUILTIN" ] && file_lstat "$1/meta.json" && key="$1 $FILE_INODE $FILE_MTIME $FILE_SIZE"
  [ -z "$key" ] || [ "$key" != "${!2-}" ] || return 0
  printf -v "$2" '%s' "$key"
  return 1
}

# The brief as this ATTEMPT hands it to the vendor: the caller's text, worker-run's standing
# preamble, and a token unique to the attempt. Brief text is no identity — every profile writes
# into one transcript tree, a co-tenant run may carry the same brief word for word, and this run
# itself launches again on an effort-flag retry or a walled reroute — so the token is what
# discovery matches on. Rewriting the file also restamps it, and its mtime is the floor `find`
# uses: a transcript older than this attempt belongs to an attempt that was abandoned.
launch_attempt() { # directory
  local directory="$1" attempt token preamble
  attempt=$(head -n1 "$directory/attempt" 2>/dev/null)
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0
  attempt=$((attempt + 1))
  token="$(basename "$directory")-a$attempt"
  { for preamble in inbox-carried browser-preamble computer-preamble; do
      [ -f "$directory/$preamble" ] || continue
      cat "$directory/$preamble" || return 1
      printf '\n'
    done
    cat "$directory/brief" || return 1
    if [ -s "$directory/fix-rule" ]; then
      printf '\n'
      cat "$directory/fix-rule" || return 1
    fi
    for preamble in research-fence edit-fence md-guard; do
      [ -s "$directory/$preamble" ] || continue
      printf '\n'
      cat "$directory/$preamble" || return 1
    done
    # Live 2026-10-09: a judge rerouted off a walled account found its own half-written verdicts,
    # took them for another agent's, refused to touch them and reported "judged 0/38".
    [ "$attempt" -le 1 ] ||
      printf '\nCONTINUATION (worker-run-injected): this is attempt %s of this run; an earlier attempt, cut off by an account limit or relaunched, may have done part of this brief. Files it created or changed are this run'"'"'s own work, not another agent'"'"'s: check them, keep what is valid and continue from where it stopped; never refuse because an output already exists, never redo finished parts.\n' "$attempt"
    printf '\n%s\n\nRUN-TOKEN: %s\n' "$BRIEF_PREAMBLE" "$token"; } \
    >"$directory/brief.launch.tmp.$$" &&
    mv -f "$directory/brief.launch.tmp.$$" "$directory/brief.launch" || return 1
  printf '%s\n' "$attempt" >"$directory/attempt" 2>/dev/null || :
  printf '%s\n' "$token" >"$directory/launch-token" 2>/dev/null || :
  # The session this run answers by is the session of the attempt now starting; kept, the previous
  # attempt's id would be reported and resumed as if it held this attempt's work.
  rm -f "$directory/session" "$directory/session-file" 2>/dev/null || :
  return 0
}

valid_run_id() {
  case "$1" in
    ''|*[!a-z0-9-]*) return 1 ;;
    *) return 0 ;;
  esac
}

run_path() {
  valid_run_id "$1" || fail "invalid run id: $1"
  printf '%s/%s' "${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}" "$1"
}

meta_update() {
  local directory="$1" filter="$2" temporary
  shift 2
  temporary="$directory/meta.json.tmp.$$"
  if ! jq "$@" "$filter" "$directory/meta.json" >"$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  mv -f "$temporary" "$directory/meta.json"
}

read_json_array() {
  local expression="$1" file="$2" value
  while IFS= read -r value; do
    REPLY_ARRAY+=("$value")
  done < <(jq -r "$expression" "$file")
}

supervise() {
  local directory="$1" vendor workdir rc
  [ -r "$directory/meta.json" ] || return 4
  vendor=$(jq -r '.vendor' "$directory/meta.json")
  workdir=$(jq -r '.workdir' "$directory/meta.json")
  RUN_DIRECTORY=$directory
  # Into THIS run's tree and nowhere else: the supervisor is setsid'd, so every vendor child and
  # everything it spawns inherits these and nothing on the machine outside the run does. A serial,
  # daemonless nx is what keeps one agent's fan-out from being the tree memlogd's memory guard has
  # to cut down (docs/memory-guard.md).
  export NX_PARALLEL=1 NX_DAEMON=false
  # Even the run that never started answers for itself: absent, its record is indistinguishable from
  # the record of a run still going, and a reader takes that for a run that wrote nothing.
  cd "$workdir" || { persist_run_files "$directory"; return 4; }
  take_floor "$directory" "$workdir"
  # Every run takes one of WORKER_SLOTS (cores / 2 clamped 2 to 8, then up to 4 x the cores capped at 40
  # while slot_room finds room): a worker is model-bound between suite runs, which run-suites caps on its
  # own. started_at stays the launch, so the queue counts in a run's hours; the deadline clock is slot_at,
  # the slot's instant, kept fresh through the wait.
  local branch
  branch=$(linked_worktree_branch "$workdir")
  # A run nested under a slot holder's worker inherits WORKER_SLOT: waiting would deadlock on its ancestor.
  if [ -z "${WORKER_SLOT:-}" ] && [[ $branch == night/*/* ]] && ! night_admit "$directory" "$vendor" "$branch"; then
    persist_run_files "$directory"
    return 4
  fi
  if [ -z "${WORKER_SLOT:-}" ]; then
    RUN_SLOT=$(slot_wait "${WORKER_SLOTS_DIR:-${DOCTORS_DIR:-$HOME/.cache/doctors}/worker-slots}" \
      "${WORKER_SLOTS:-$(worker_slots)}" $((2 * DEADLINE + 900)) workers \
      "worker run ${directory##*/} on ${branch:-$workdir}" meta_update "$directory" '.slot_at = (now | floor)' 2>/dev/null) ||
      { persist_run_files "$directory"; return 4; }
    export WORKER_SLOT=$RUN_SLOT
    meta_update "$directory" '.slot_at = (now | floor)' || :
  fi
  if [ -n "$RUN_SLOT" ] && [[ $branch == night/*/* ]]; then
    local night gate
    night=${branch#night/} night=${night%%/*}
    gate=$("$SCRIPT_DIRECTORY/night-run" speed-gate "$night" "${branch#"night/$night/"}" \
      $(jq -r '.launcher_pid // empty' "$directory/meta.json" 2>/dev/null) 2>/dev/null)
    # Only 3 refuses: a night-run failure (no such night, a lock) never stops a fixer.
    if [ $? -eq 3 ]; then
      printf 'worker-run: %s\n' "$gate" >>"$directory/err"
      persist_run_files "$directory"
      return 4
    fi
  fi
  while :; do
    # The slot's ceiling runs from its mtime, and each walled reroute is an attempt with a deadline of its own.
    [ -z "$RUN_SLOT" ] || touch "$RUN_SLOT" 2>/dev/null
    case "$vendor" in
      claudeb) supervise_claudeb "$directory" ;;
      codex) supervise_codex "$directory" ;;
      gemini)
        if [ "$(jq -r '.role // "workers"' "$directory/meta.json")" = research ]; then
          . "$SCRIPT_DIRECTORY/../share/light-research.sh"
          supervise_gemini_research "$directory"
        else
          supervise_gemini "$directory"
        fi
        ;;
      grok) supervise_grok "$directory" ;;
      *) return 4 ;;
    esac
    rc=$?
    [ "$vendor" != gemini ] || gemini_record_served "$directory"
    # After EVERY attempt, not only the last one: a walled attempt wrote whatever it wrote before the
    # wall, and rerouting restamps the run's start and takes a new session — read afterwards, that
    # attempt's files are behind the cut and belong to nobody at all. A failed attempt counts the
    # same way; the record is a union across attempts.
    persist_run_files "$directory"
    [ "$rc" -eq 0 ] && return 0
    [ "$vendor" != claudeb ] || record_claudeb_auth_dead "$directory"
    # A run somebody signalled is over: rerouting it would answer an operator's kill by launching
    # the same brief again on another account.
    case "$(head -n1 "$directory/killed" 2>/dev/null)" in term|'signal '*) return "$rc" ;; esac
    reroute_walled "$directory" "$vendor" || return "$rc"
    # The rescue attempt is a session of its own on another account, and the walled attempt's
    # transcript is still the newest one in the tree it shares.
    launch_attempt "$directory" || return "$rc"
  done
}

record_worker_session() {
  local directory="$1" session
  # Every vendor, not claudeb alone. grok loads this machine's hooks out of `~/.claude/settings.json`
  # for Claude compatibility and journals under its OWN session id, which read without this pairing
  # is a chat nothing on the machine answers for (live: grok sessions 01a0641b…/01a0647f… against
  # chat 35c155ac…, 2026-09-03). A codex or agy id reaching a journal is the same case one level
  # down — a nested worker, a review-bench call — and one that never reaches one costs a reader
  # nothing: this mapping is only ever consulted about an id some row already carries.
  session=$(session_id "$directory")
  # A resumed run's id is known before its first token — the session keeps the id it already had,
  # and every entry it journals while the run is LIVE carries that one. Read only where the run
  # has not answered with an id of its own yet, so a session that somehow moved still wins.
  [ "$session" != - ] || session=$(jq -r '.resume // empty' "$directory/meta.json" 2>/dev/null)
  # Never a guess: an id nothing named, or one no journal record could carry, leaves no file.
  case "$session" in
    ''|-|.|..|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  grep -qxF -- "$session" "$directory/worker-session" 2>/dev/null && return 0
  printf '%s\n' "$session" >>"$directory/worker-session" 2>/dev/null || :
  journal_worker_attempt "$directory" "$session"
  return 0
}

WORKER_ATTEMPTS_ROTATE_BYTES=16777216

file_bytes() { # path
  local bytes
  bytes=$(wc -c 2>/dev/null <"$1")
  printf '%s\n' "$((${bytes:-0}))"
}

# tokenmap zones every worker session from this journal: the run directory is pruned after seven
# days and a wall reroute rewrites meta.account, so each attempt is written down while its facts
# still hold. Two segments of 16 MiB bound it; the rotation lock is re-checked inside because a
# second writer may have rotated between the size read and the mkdir, and a lock older than a
# minute is a killed rotation's, which would otherwise stop every later one.
journal_worker_attempt() { # directory session
  local directory="$1" journal ts attempt='' launcher=''
  journal="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/worker-attempts.jsonl"
  mkdir -p "${journal%/*}" 2>/dev/null || return 0
  if [ "$(file_bytes "$journal")" -gt "$WORKER_ATTEMPTS_ROTATE_BYTES" ] \
    && LLM_STORE_LOCK_RETRIES=1 store_lock_acquire "$journal.rotating"; then
    if [ "$(file_bytes "$journal")" -gt "$WORKER_ATTEMPTS_ROTATE_BYTES" ]; then
      [ ! -f "$journal.1" ] || limit_hit worker-run.attempts-rotate "$WORKER_ATTEMPTS_ROTATE_BYTES" bytes drop \
        "$(file_bytes "$journal.1") bytes of worker-attempts.jsonl.1 deleted: tokenmap can no longer zone those older worker sessions" \
        'bin/worker-run:WORKER_ATTEMPTS_ROTATE_BYTES=' "$(file_bytes "$journal")"
      mv -f "$journal" "$journal.1" 2>/dev/null
    fi
    store_lock_release "$journal.rotating"
  fi
  TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  IFS= read -r attempt 2>/dev/null <"$directory/attempt" || :
  IFS= read -r launcher 2>/dev/null <"$directory/launcher" || :
  jq -c --arg ts "$ts" --arg run "${directory##*/}" --arg session "$2" \
    --arg attempt "$attempt" --arg launcher "$launcher" \
    '{ts: $ts, run: $run, attempt: (($attempt | tonumber?) // null), session: $session,
      vendor, account, role, light: (.light // null), model, workdir,
      launcher: (($launcher | select(. != "")) // null)}' \
    "$directory/meta.json" >>"$journal" 2>/dev/null || :
}

WORKER_RUNS_KEEP_DAYS=35

# Appends and the daily prune share one lock: a prune rewriting the file under an unlocked append
# would drop that row.
journal_worker_run() { # directory status exit-code
  local directory="$1" journal now row marker reason user_md transcript line
  journal="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/runs.jsonl"
  printf -v now '%(%s)T' -1
  reason=$2
  IFS=' ' read -r reason _ 2>/dev/null <"$directory/killed" || reason=$2
  meta_update "$directory" '.ended_at = $now
    | .terminal_reason = (if $reason == "failed" and $code == "4" and ((.cli_starts // []) | length) == 0
        then "no-start" else $reason end)' \
    --argjson now "$now" --arg reason "$reason" --arg code "$3" 2>/dev/null || return 0
  # claudeMdExcludes alone keeps the chat's CLAUDE.md out of a worker: Spend reads this flag to see a
  # CLI that stopped honouring it.
  user_md=null
  if [ "$(jq -r '.vendor' "$directory/meta.json" 2>/dev/null)" = claudeb ] &&
    transcript=$(session_transcript claudeb "$(jq -r '.account' "$directory/meta.json")" "$(session_id "$directory" claudeb)"); then
    line=$(grep -m1 '"type":"instructions"' "$transcript" 2>/dev/null) || line='{}'
    user_md=$(jq '[.attachment.files[]? | select(.type == "User")] | length > 0' <<<"$line" 2>/dev/null) || user_md=null
  fi
  row=$(jq -c --arg run "${directory##*/}" --arg status "$2" --arg code "$3" --argjson user_md "${user_md:-null}" \
    --arg launcher "$(head -n1 "$directory/launcher" 2>/dev/null)" \
    '{run: $run, vendor, account, role, model, effort, light: (.light // null), workdir,
      launcher: (($launcher | select(. != "")) // null), resume: ((.resume // "") != ""),
      round: (.review_round // null), pid_started_at: (.pid_started_at // null), started_at,
      cli_starts: (.cli_starts // []), attempt_secs: (.attempt_secs // []), attempt_rcs: (.attempt_rcs // []),
      walled: (.walled_accounts // []), ended_at, exit_code: (($code | tonumber?) // null), status: $status,
      reason: .terminal_reason, orphans: (.orphans_ended // []), user_md_loaded: $user_md}' "$directory/meta.json" 2>/dev/null) || return 0
  mkdir -p "${journal%/*}" 2>/dev/null || return 0
  LLM_STORE_LOCK_RETRIES=40 store_lock_acquire "$journal.lock" || {
    limit_hit worker-run.journal-lock 40 count retry-exhausted "worker-stats runs.jsonl row of run ${directory##*/} ($2)" \
      'bin/worker-run:LLM_STORE_LOCK_RETRIES=40 store_lock_acquire "$journal.lock"'
    return 0
  }
  marker="$journal.pruned"
  if [ -s "$journal" ] && { [ ! -f "$marker" ] || [ -n "$(find "$marker" -mtime +1 2>/dev/null)" ]; }; then
    touch "$marker" 2>/dev/null
    jq -cR --argjson cut "$((now - WORKER_RUNS_KEEP_DAYS * 86400))" 'fromjson? | select((.ended_at // 0) >= $cut)' \
      "$journal" >"$journal.tmp.$$" 2>/dev/null && mv -f "$journal.tmp.$$" "$journal" || rm -f "$journal.tmp.$$"
  fi
  printf '%s\n' "$row" >>"$journal" 2>/dev/null
  store_lock_release "$journal.lock"
  return 0
}

# The task row the chat paints for this run reads this file, so every transition rewrites it whole.
write_run_state() { # directory phase [exit-code]
  local directory="$1" phase="$2" code="${3:-}" tag='' rest session='' meta='' tmp
  [ -d "$directory" ] || return 0
  IFS= read -r tag 2>/dev/null <"$directory/tag" || :
  rest=${tag#* · }
  IFS= read -r session 2>/dev/null <"$directory/launcher" || :
  { meta=$(<"$directory/meta.json"); } 2>/dev/null || :
  tmp="$directory/state.json.tmp.$$"
  if jq -n --arg phase "$phase" --arg code "$code" --arg meta "$meta" \
    --arg session "$session" --arg account "${tag%% · *}" --arg model "${rest%% · *}" --arg effort "${rest##* · }" \
    'def opt: if . == "" then null else . end;
     def raw: if . == null or . == false then "" elif type == "string" then . else tojson end;
     ((try ($meta | fromjson) catch {}) | if type == "object" then . else {} end) as $m |
     {phase: $phase, exit_code: ($code | opt | if . == null then . else (tonumber? // .) end),
      session: ($session | opt), account: ($account | opt),
      model: ($model | opt), effort: ($effort | opt), round_id: ($m.review_round | raw | opt),
      started_epoch: ($m.pid_started_at // $m.started_at | raw | opt | if . == null then . else (tonumber? // null) end),
      ts: (now | floor | todate)}' >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$directory/state.json" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# One writer at a time on a run's inbox; a holder that died is outwaited.
with_lock() { # directory command...
  local lock="$1/.claim.lock" waited=0 rc=0
  shift
  while ! mkdir "$lock" 2>/dev/null; do
    if { [ "$waited" -eq 0 ] || [ "$waited" -ge 50 ]; } \
      && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null
      waited=50
    fi
    if [ "$waited" -ge 50 ]; then
      lock=''
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  "$@" || rc=$?
  [ -z "$lock" ] || rmdir "$lock" 2>/dev/null || :
  return "$rc"
}

allocate_run_directory() { # vendor — sets root, run_id, directory
  local allocate_vendor="$1" stamp mark attempts=0 prune_marker
  root="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}"
  mkdir -p "$root" || fail "could not create run root: $root"
  root=$(cd "$root" && pwd -P) || fail "could not resolve run root: $root"
  prune_marker="$root/.prune"
  if [ ! -f "$prune_marker" ] || [ -n "$(find "$prune_marker" -mtime +1 2>/dev/null)" ]; then
    touch "$prune_marker" 2>/dev/null
    find "$root" -mindepth 1 -maxdepth 1 -type d ! -name browse -mtime +7 -exec rm -rf {} + 2>/dev/null
  fi
  stamp=$(date +%s)
  printf -v mark '%04x' "$RANDOM"
  run_id="$allocate_vendor-$stamp-$$-$mark"
  while :; do
    directory="$root/$run_id"
    mkdir "$directory" 2>/dev/null && break
    attempts=$((attempts + 1))
    printf -v mark '%04x' "$RANDOM"
    run_id="$allocate_vendor-$stamp-$$-$mark"
    [ "$attempts" -lt 50 ] || fail "could not create run directory under: $root"
  done
}

# One grep over the glob, in the glob's own order: that is the order the per-file loop stopped at.
refuse_live_matches() { # needle root filename
  local needle="$1" root="$2" name="$3" matches
  matches=$(grep -lxF -- "$needle" "$root"/*/"$name" 2>/dev/null) || true
  [ -n "$matches" ] || return 0
  printf '%s\n' "$matches"
}

run_wait_line() { # directory
  if [ "$(jq -r '.light // ""' "$1/meta.json" 2>/dev/null)" = research ]; then
    printf 'WAIT: light-research --attach %s --out <answer-file> (as a background Bash)\n' "${1##*/}"
  else
    printf 'WAIT: worker-run wait %s --report (as a background Bash)\n' "${1##*/}"
  fi
}

refuse_live_run() { # brief resume
  local brief="$1" resume="$2" root entry directory pid now started sha other_sha owner
  root="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}"
  if [ -n "$resume" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] && [ -f "$entry" ] || continue
      directory=${entry%/worker-session}
      [ ! -e "$directory/exit_code" ] || continue
      pid=$(jq -r '.pid // 0' "$directory/meta.json" 2>/dev/null)
      supervisor_running "$directory" "$pid" || continue
      outcome_line "RESUME_BUSY ${directory##*/}"
      run_wait_line "$directory"
      exit 4
    done < <(refuse_live_matches "$resume" "$root" worker-session)
  fi
  [ "${WORKER_RUN_ALLOW_DUPLICATE:-0}" != 1 ] || return 0
  # The same owner start_run writes into `launcher`: inside a worker CLAUDE_CODE_SESSION_ID is the
  # worker's own chat and never matches, so a nested duplicate would slip through.
  owner=${CLAUDE_LAUNCHER_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}
  [ -n "$owner" ] || return 0
  sha=$(shasum -a 256 "$brief" | awk '{print $1}')
  [ -n "$sha" ] || return 0
  now=$(date +%s)
  while IFS= read -r entry; do
    [ -n "$entry" ] && [ -f "$entry" ] || continue
    directory=${entry%/launcher}
    [ ! -e "$directory/exit_code" ] || continue
    started=$(jq -r '.pid_started_at // .started_at // 0' "$directory/meta.json" 2>/dev/null)
    [[ "$started" =~ ^[0-9]+$ ]] || continue
    [ "$started" -le "$now" ] && [ $((now - started)) -lt 1800 ] || continue
    pid=$(jq -r '.pid // 0' "$directory/meta.json" 2>/dev/null)
    supervisor_running "$directory" "$pid" || continue
    other_sha=$(shasum -a 256 "$directory/brief" 2>/dev/null | awk '{print $1}')
    [ "$sha" = "$other_sha" ] || continue
    outcome_line "DUPLICATE_RUN ${directory##*/}"
    run_wait_line "$directory"
    exit 4
  done < <(refuse_live_matches "$owner" "$root" launcher)
  return 0
}

# Linked worktrees only: main checkouts and scratch directories take parallel workers by design.
refuse_busy_worktree() { # workdir
  local root top git_dir common entry directory other nested=''
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" && pwd -P) || return 0
  git_dir=$(git -C "$top" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 0
  common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ "$git_dir" != "$common" ] || return 0
  root="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}"
  [ -z "${WORKER_RUN_RECORD:-}" ] || nested=$(cd "$WORKER_RUN_RECORD" 2>/dev/null && pwd -P)
  while IFS= read -r entry; do
    directory=${entry%/meta.json}
    [ ! -e "$directory/exit_code" ] && [ "$(cd "$directory" && pwd -P)" != "$nested" ] || continue
    other=$(jq -r 'select(.role != "research" and .light != "research") | .workdir // empty' "$entry" 2>/dev/null)
    [ "$other" = "$top" ] || [[ $other == "$top"/* ]] || continue
    supervisor_running "$directory" "$(jq -r '.pid // 0' "$entry" 2>/dev/null)" || continue
    outcome_line "WORKDIR_BUSY ${directory##*/}"
    printf 'REASON: run %s still works in %s; a second worker there would edit under it\n' "${directory##*/}" "$top"
    run_wait_line "$directory"
    exit 4
  done < <(grep -lF -- "$top" "$root"/*/meta.json 2>/dev/null)
  return 0
}

start_run() {
  [ "$#" -ge 1 ] || usage
  local vendor="$1" brief='' workdir="$PWD" explicit_account='' model='' effort='' resume='' first_line='' review_round='' round_flag='' role='workers' research_timeout='' sandbox_exec=''
  local round_source='' candidate='' rule='' image=''
  local -a text_rounds=() brief_images=()
  local account pin config_model model_label agy_model='' gemini_family='' grok_turns='' root run_id='' directory=''
  local explicit_model='' explicit_effort='' light='' light_model='' model_class=workers fix_rule='' commit_rule='' chat_fast=false fast_role='' grok_asked_model='' model_id='' slug_account=''
  local light_offrow=false inbox_settings='' resolved_add_dirs resolved_read
  local fit_round=''
  local started cli cmd_json add_dirs_json images_json pid supervisor_body value list_output list_rc launcher_session launcher_pid entry
  local web_search=false web_search_flag=false web_search_off_flag=false web_search_asked=''
  local web_search_state='' brief_cyrillic=''
  local chrome=false browser=false browser_preamble='' browser_device='' browser_account='' browser_profile=''
  local browser_target='' computer=false computer_home=''
  local -a add_dirs images command_meta command
  add_dirs=()
  images=()
  command_meta=()
  command=()
  shift
  case "$vendor" in claudeb|codex|gemini|grok|light) ;; *) usage ;; esac
  [ "$vendor" != gemini ] || worker_model_prime gemini
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --brief) [ "$#" -ge 2 ] || usage; brief="$2"; shift 2 ;;
      --workdir) [ "$#" -ge 2 ] || usage; workdir="$2"; shift 2 ;;
      --account) [ "$#" -ge 2 ] || usage; explicit_account="$2"; shift 2 ;;
      --model) [ "$#" -ge 2 ] || usage; model="$2"; shift 2 ;;
      --effort) [ "$#" -ge 2 ] || usage; effort="$2"; shift 2 ;;
      --resume) [ "$#" -ge 2 ] || usage; resume="$2"; shift 2 ;;
      --add-dir) [ "$#" -ge 2 ] || usage; add_dirs+=("$2"); shift 2 ;;
      --image) [ "$#" -ge 2 ] || usage; images+=("$2"); shift 2 ;;
      --web-search) web_search_flag=true; shift ;;
      --no-web-search) web_search_off_flag=true; shift ;;
      --round) [ "$#" -ge 2 ] || usage; round_flag="$2"; shift 2 ;;
      --role) [ "$#" -ge 2 ] || usage; role="$2"; shift 2 ;;
      --research-timeout) [ "$#" -ge 2 ] || usage; research_timeout="$2"; shift 2 ;;
      --browser) browser=true; shift ;;
      --computer) computer=true; shift ;;
      --target)
        [ "$#" -ge 2 ] || usage
        browser_target="$2"
        case "$browser_target" in dia|chrome) ;; *) usage ;; esac
        shift 2
        ;;
      *) usage ;;
    esac
  done
  [ -n "$brief" ] || usage
  [ "$web_search_flag" = false ] || [ "$web_search_off_flag" = false ] ||
    fail '--web-search and --no-web-search ask for opposite states: pass one of them'
  [ "$role" = workers ] || [ "$role" = research ] || usage
  # A flag a chat rebuilt from the header must not outvote it: a relay that lost `--effort` to a
  # shell quoting slip launched a Fable `EFFORT: high` brief on the low default (2026-09-30). A
  # research run read no header at all until 2026-10-12 and ran its `EFFORT: high` brief on low.
  local header_key header_value header_flag
  for header_key in ACCOUNT MODEL EFFORT; do
    [ "$header_key" = ACCOUNT ] || [ "$vendor" != light ] || continue
    header_value=$(brief_line_value "$brief" "$header_key")
    case "$header_key" in
      ACCOUNT) header_flag=$explicit_account ;;
      MODEL) header_flag=$model ;;
      EFFORT) header_flag=$effort ;;
    esac
    [ -z "$header_value" ] || [ -z "$header_flag" ] || [ "$header_flag" = "$header_value" ] ||
      fail "--$(tr '[:upper:]' '[:lower:]' <<<"$header_key") $header_flag contradicts the brief header '$header_key: $header_value': drop the flag, worker-run reads the header itself. Nothing was launched and no account was spent."
  done
  [ -n "$explicit_account" ] || explicit_account=$(brief_line_value "$brief" ACCOUNT)
  [ -n "$model" ] || [ "$vendor" = light ] || model=$(brief_line_value "$brief" MODEL)
  [ -n "$effort" ] || [ "$vendor" = light ] || effort=$(brief_line_value "$brief" EFFORT)
  if [ "$role" = workers ]; then
    [ "$computer" = true ] || [ "$(brief_line_value "$brief" COMPUTER)" != yes ] || computer=true
    browse_header "$brief"
    value=${model:-$(worker_model_gemini_stored_r "$(config_value gemini_model)"; printf '%s' "$WORKER_MODEL_R")}
    ! { [ "$(brief_line_value "$brief" STRONG)" = yes ] && { [ "$vendor" = light ] || { [ "$vendor" = gemini ] && ! worker_model_gemini_requested "$value"; }; }; } ||
      fail "the brief header 'STRONG: yes' takes no Light or Gemini Flash worker: start it on the next vendor worker-pick ranks. Nothing was launched and no account was spent."
    # A relay that dropped --resume launched a RESUME brief as a fresh session (2026-10-02).
    value=$(sed -n '1s/^RESUME \([^[:space:]:]\{1,\}\):.*/\1/p' "$brief" 2>/dev/null)
    [ -z "$value" ] || [ -z "$resume" ] || [ "$resume" = "$value" ] ||
      fail "--resume $resume contradicts the brief's first line 'RESUME $value:': drop the flag, worker-run reads the line itself. Nothing was launched and no account was spent."
    [ -n "$resume" ] || resume=$value
    # Chats resume by the run id they hold (2026-10-09: the CLI refused it as no session).
    if [ -n "$resume" ] && valid_run_id "$resume" &&
      [ "$(jq -r '.vendor // empty' "$(run_path "$resume")/meta.json" 2>/dev/null)" = "$vendor" ]; then
      value=$(sed '/^$/d' "$(run_path "$resume")/worker-session" 2>/dev/null | tail -n1)
      [ -n "$value" ] ||
        fail "RESUME $resume names a run that recorded no session to resume. Nothing was launched and no account was spent."
      resume=$value
    fi
    while IFS= read -r value; do
      [[ "$value" = /* ]] && [ -d "$value" ] ||
        fail "the brief's 'ADD-DIR: $value' names no absolute directory: give each other repository the run writes as its own ADD-DIR: line. Nothing was launched and no account was spent."
      add_dirs+=("$value")
    done < <(brief_add_dirs "$brief")
  fi
  # 2026-10-13: a night script passed a whole two-line worker-session file; the CLI refused it after launch.
  case "$resume" in *[[:space:]]*)
    fail "--resume takes one session id, not '${resume//$'\n'/ | }': pass the run id and worker-run resumes its last session. Nothing was launched and no account was spent." ;;
  esac
  if worker_light_off; then
    if [ "$vendor" = light ]; then
      outcome_line LIGHT_OFF
      fail "Light is off (Egor's menu: LLM Limits -> Light), so there is no light leg: give the task to the regular worker worker-pick names. Nothing was launched and no account was spent."
    fi
  elif [ "$role" = research ]; then light=research
  elif [ "$vendor" = light ]; then light=edit
  fi
  if [ -n "$light" ]; then
    model_class=light
    if [ "$vendor" = light ] || [ "$(worker_light_vendor "$light" 2>/dev/null)" = "$vendor" ]; then
      if ! vendor=$(worker_light_vendor "$light") || ! light_model=$(worker_light_model "$light"); then
        outcome_line MODEL_REFUSED
        fail "the light_$light row in $CONFIG_FILE names no vendor/model of the table. Nothing was launched and no account was spent."
      fi
    fi
    # Off the row's vendor there is no light model to fall to, and the vendor's own default is a
    # STRONG model: a run that silently answered on it would be a light class in name only. The
    # refusal itself waits until the flag-shape checks below have had their say.
    [ -n "$light_model" ] || [ -n "$model" ] || light_offrow=true
    model=${model:-${light_model:-$(worker_model_default_model "$vendor")}}
    effort=${effort:-$(worker_model_default_effort "$vendor" "$model" light)}
    # A light edit is not the implementation leg `<vendor>_workers=off` closes, so it asks the
    # picker under its own role; research already travels as `research` a few lines below.
    [ "$light" != edit ] || export WORKER_RUN_ROLE=light
  fi
  if [ "$role" = research ]; then
    [ -z "$resume" ] && [ "$browser" = false ] || fail 'research does not support resume or browser flags'
    [ -n "$research_timeout" ] || research_timeout=360m
    . "$SCRIPT_DIRECTORY/../share/light-research.sh"
    value=$(research_duration_seconds "$research_timeout") && [ "$value" -gt 0 ] || usage
    case "$vendor" in gemini|grok) sandbox_exec="${RESEARCH_SANDBOX_EXEC:-/usr/bin/sandbox-exec}" ;; esac
    export WORKER_RUN_ROLE=research
  elif [ -n "$research_timeout" ]; then
    usage
  fi
  [ -r "$brief" ] || fail "brief is not readable: $brief"
  [ -z "$explicit_account" ] || account_roster_refuse worker-run "$vendor" "$explicit_account" || exit 2
  # A browser run is not the implementation leg `<vendor>_workers=off` closes (Egor, 2026-10-12).
  [ "$browser" = false ] || [ -n "$light" ] || [ "$role" != workers ] || export WORKER_RUN_ROLE=browser
  [ "$role" != workers ] || [ -z "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ] || limit_gate "$vendor" "$light" "$brief" "$explicit_account" "$computer" "$model"
  # The first line is the run's handle: readers take `RESUME <id>:`
  # off the top of it, and every reader that falls back to a prefix of the brief
  # matches nothing useful with a blank one.
  # `|| :` and not `|| first_line=''`: a file with no trailing newline fails the read and still
  # assigns every byte of its one line.
  IFS= read -r first_line <"$brief" || :
  case "$first_line" in
    *[![:space:]]*) ;;
    *) fail "brief starts with a blank line: $brief — the first line is the run's handle (RESUME) and what a reader identifies it by" ;;
  esac
  # The flag is `review-bench fix`'s own composition and outranks the header, which stays the
  # fallback for a brief a chat wrote by hand.
  if [ -n "$round_flag" ]; then
    review_round_ok "$round_flag" ||
      fail "--round names no review round on record: '$round_flag' — the shape is <review-bench run id YYYYMMDDTHHMMSSZ-<7 hex>> and $(review_bench_dir "$round_flag") must exist"
    review_round=$round_flag
    round_source=flag
  else
    review_round=$(brief_review_round "$brief") || exit 4
    [ -z "$review_round" ] || round_source=header
  fi
  if [ -z "$round_flag" ]; then
    if [ "$review_round" = none ]; then
      review_round=''
      round_source=''
    elif [ -z "$review_round" ] && [ "$role" = workers ]; then
      # Prose that names a round with a confirmed finding left is asked about, never bound: bound,
      # a read-only audit citing a run as evidence was handed that round's findings to fix. Unasked,
      # a hand-written fix brief lands its fixes as the next chat's debt.
      while IFS= read -r candidate; do
        review_round_ok "$candidate" || continue
        rule=$(review-bench fix "$candidate" --print 2>/dev/null) ||
          fail "review-bench fix $candidate --print failed: the brief names that round and a round whose open findings cannot be read cannot be fixed"
        [ -z "$rule" ] || text_rounds+=("$candidate")
      done < <(brief_text_rounds "$brief")
      [ "${#text_rounds[@]}" -eq 0 ] ||
        fail "brief names open review round(s) ${text_rounds[*]} but has no ROUND: line: add 'ROUND: <id>' when this run fixes that round, or 'ROUND: none' when it only cites it"
    fi
  fi
  [ -z "$review_round" ] || [ "$role" = workers ] ||
    fail "a research run fixes nothing: drop --round / the ROUND: line, or launch it as a worker"
  if [ -n "$review_round" ]; then
    # Composed once at start: a relaunch must hand the worker the same rule text.
    fix_rule=$(review-bench fix "$review_round" --print 2>/dev/null) ||
      fail "review-bench fix $review_round --print failed: a round-tagged brief without the verdicts.jsonl rule cannot launch"
    # Only a brief holding every line of it (a `review-bench fix --brief` file) goes without it; a brief
    # merely naming verdicts.jsonl used to launch its fixer without the round's findings.
    # bin/fix-audit maps each landed fix to its finding by this name a week later.
    commit_rule="Each commit message names this round and the findings it fixes: \`$review_round F<index>[,<index>...]\`."
    [ -n "$fix_rule" ] && ! grep -Fqx -- "$commit_rule" "$brief" || commit_rule=''
    [ -n "$(grep . <<<"$fix_rule" | grep -Fxv -f "$brief")" ] || fix_rule=''
    [ -z "$commit_rule" ] || fix_rule+=${fix_rule:+$'\n'}$commit_rule
  fi
  brief_cyrillic=$(cyrillic_share <"$brief") ||
    fail "the brief's language could not be measured ($CYRILLIC_SHARE): nothing was launched; fix the tool rather than skipping the check"
  ! cyrillic_over "$brief_cyrillic" ||
    fail "brief has Russian ($brief_cyrillic% Cyrillic): the reader is a model — write it in English; $("$CYRILLIC_SHARE" --allowed 2>/dev/null)"
  [ -d "$workdir" ] || fail "workdir is not a directory: $workdir"
  workdir=$(cd "$workdir" && pwd -P) || fail "could not resolve workdir: $workdir"
  [ "$role" != workers ] || [ "$workdir" != "$(cd "$HOME" && pwd -P)" ] ||
    fail "workdir is the home directory, where no run's files can be tracked: launch with --workdir <the repository the brief works in>, plus one 'ADD-DIR: <dir>' header line per other repository it writes; a run that writes no repository launches in a scratch directory. Nothing was launched and no account was spent."
  # Every repository of the round is the fixer's to write, and a write outside workdir and
  # --add-dir has no content baseline: the run's changes there read as escaped. A codex resume and
  # grok take no --add-dir, so they are granted none and fix one repository a run.
  if [ -n "$review_round" ] && [ "$vendor" != grok ] &&
    { [ "$vendor" != codex ] || [ -z "$resume" ]; }; then
    while IFS= read -r value; do
      [ -d "$value" ] && ! same_repository "$value" "$workdir" ${add_dirs[@]+"${add_dirs[@]}"} &&
        add_dirs+=("$value")
    done < <(jq -r '.repos[]? | objects | .repo // empty' "$(review_bench_dir "$review_round")/meta.json" 2>/dev/null)
  fi
  if [ "$light" != research ] && [ "$vendor" != grok ] && { [ "$vendor" != codex ] || [ -z "$resume" ]; }; then
    resolved_add_dirs='' resolved_read=''
    while IFS= read -r value; do
      [ -d "$value" ] && value=$(cd "$value" && pwd -P) && [ "$value" != "$workdir" ] || continue
      if [ -z "$resolved_read" ]; then
        resolved_add_dirs=$(for entry in ${add_dirs[@]+"${add_dirs[@]}"}; do (cd "$entry" 2>/dev/null && pwd -P); done)
        resolved_read=1
      fi
      case $'\n'$resolved_add_dirs$'\n' in
        *$'\n'"$value"$'\n'*) ;;
        *) add_dirs+=("$value") resolved_add_dirs+=$'\n'$value ;;
      esac
    done < <(brief_worktree_roots "$brief"; resumed_add_dirs "$resume")
    while IFS= read -r value; do
      [ -n "$(git_common_dir "$value")" ] && value=$(cd "$value" && pwd -P) &&
        ! same_repository "$value" "$workdir" ${add_dirs[@]+"${add_dirs[@]}"} && add_dirs+=("$value")
    done < <(resumed_add_dirs "$resume" .workdir)
    value=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) && [ -d "$value/.git" ] &&
      while IFS= read -r value; do
        ! same_repository "$value" "$workdir" ${add_dirs[@]+"${add_dirs[@]}"} && add_dirs+=("$value")
      done < <(brief_checkout_roots "$brief")
  fi
  web_search_column "$vendor" on >/dev/null ||
    fail "share/web-search.sh has no row for $vendor: a launch with an unknown search state would take whichever one the CLI happens to stand in. Nothing was launched and no account was spent."
  [ "$role" != research ] || web_search=true
  value=$(web_search_brief_state "$brief") || fail "$value"
  case "$value" in
    on)
      [ "$web_search_off_flag" = false ] ||
        fail "--no-web-search and the brief's 'WEB: on' ask for opposite states: pass one of them. Nothing was launched and no account was spent."
      web_search=true; web_search_asked=on ;;
    off)
      [ "$web_search_flag" = false ] ||
        fail "--web-search and the brief's 'WEB: off' ask for opposite states: pass one of them. Nothing was launched and no account was spent."
      web_search=false; web_search_asked=off ;;
  esac
  if [ "$web_search_flag" = true ]; then web_search=true; web_search_asked=on; fi
  if [ "$web_search_off_flag" = true ]; then web_search=false; web_search_asked=off; fi
  if [ "$web_search" = true ] && [ "$(web_search_column "$vendor" on)" = '!' ]; then
    outcome_line MODEL_REFUSED
    fail "$vendor cannot search the web, and a run that answers such a brief from memory is worse than none: launch it on $(web_search_vendors on). Nothing was launched and no account was spent."
  fi
  # An unreachable OFF is refused the same way an unreachable ON is, and only when it was ASKED for:
  # the vendor's own default searching anyway is recorded as what the run got, but a caller who said
  # so would otherwise get live pages under a brief that ruled them out and learn it from nothing.
  if [ "$web_search_asked" = off ] && [ "$(web_search_column "$vendor" off)" = '!' ]; then
    outcome_line MODEL_REFUSED
    fail "$vendor has no switch that turns web search off — it searches whatever the brief says — so a run that must not rest on live pages launches on $(web_search_vendors off). Drop the ask to accept $vendor's own search-on default. Nothing was launched and no account was spent."
  fi
  # What the table can actually deliver, not what was asked: a vendor with no off switch searches
  # anyway, and meta.json is read by everything downstream as the state the answer may rest on.
  web_search_state=$(web_search_state "$vendor" "$web_search")
  case "$web_search_state" in on) web_search=true ;; *) web_search=false ;; esac
  case "$vendor" in
    claudeb)
      [ "${#images[@]}" -eq 0 ] || fail 'claudeb does not support --image'
      ;;
    codex)
      [ -z "$resume" ] || [ "${#add_dirs[@]}" -eq 0 ] || fail 'codex resume does not support --add-dir'
      ;;
    gemini)
      [ "${#images[@]}" -eq 0 ] || fail 'gemini does not support --image'
      # agy has no stdin mode — the brief travels on argv, and past the kernel's
      # per-argument ceiling execve fails with a bare E2BIG long after start.
      # 128 for the RUN-TOKEN line launch_attempt appends, whose run id is not known yet.
      [ "$(($(wc -c <"$brief" | tr -d '[:space:]') + ${#fix_rule} + ${#BRIEF_PREAMBLE} + 128))" -le 131072 ] || fail 'gemini takes the brief on argv; briefs over 128KB cannot launch — shorten it or use another vendor'
      ;;
    grok)
      # `--cwd` is the whole of grok's directory grant (1.0.13 has no --add-dir), so research gets no
      # exemption here the way claudeb's read-only mode does: the extra trees would reach neither the
      # CLI nor the run, and the answer would be about repositories nobody read. No image either.
      [ "${#add_dirs[@]}" -eq 0 ] && [ "${#images[@]}" -eq 0 ] || fail 'grok does not support --add-dir or --image; a run over several repositories needs another vendor, or one run per repository'
      ;;
  esac
  if [ "$light_offrow" = true ]; then
    outcome_line MODEL_REFUSED
    fail "the light_$light row names $(worker_light_vendor "$light" 2>/dev/null || printf 'no vendor'), not $vendor: a $vendor light run with no --model falls to that vendor's strong default. Add \`--model <id>\` with one of $vendor's light ids ($(worker_model_allowed_list "$vendor" light 2>/dev/null || printf 'none — the vendor has no row')), or launch on the row's vendor. Nothing was launched and no account was spent."
  fi
  [ -z "$browser_target" ] || [ "$browser" = true ] || usage
  if [ "$computer" = true ]; then
    [ "$vendor" = codex ] || fail 'only codex drives the computer (Codex Computer Use): launch --computer on codex'
    [ "$browser" = false ] || fail '--computer and --browser drive different surfaces: pass one of them'
    [ -z "$light" ] && [ "$role" = workers ] || fail 'a Light or research run does not drive the computer: launch --computer as a codex worker'
    export WORKER_RUN_ROLE=computer
  fi
  [ "$browser" = false ] || browse_vendor "$vendor" || return 2
  refuse_unlisted_model "$vendor" "$model" "$resume" "$model_class"
  explicit_effort=$effort
  if [ "$vendor" = codex ]; then
    config_model=$(codex_config_model)
    [ "$model" != default ] || model=$config_model
    explicit_model=$model
    # Computer Use runs on Sol unless the brief names a model (Egor, 2026-10-24).
    [ -n "$model" ] || [ "$computer" = false ] || model=sol
    model=${model:-$config_model}
  else
    if [ -z "$model" ] && [ "$vendor" = claudeb ] && [ -z "$light" ] && [ -n "$review_round" ]; then
      case $(jq -r '.lens // empty' "$(review_bench_dir "$review_round")/meta.json" 2>/dev/null) in
        fit | legacy | legacy-*) fit_round=1 ;;
      esac
    fi
    if [ -z "$model" ] && [ "$vendor" = gemini ]; then
      worker_model_gemini_stored_r "$(config_value gemini_model)"; model=$WORKER_MODEL_R
    fi
    model=${model:-$(config_value "${vendor}_model")}
    model=${model:-$(worker_model_default_model "$vendor")}
    # Fixers of fit and legacy rounds run Sonnet where the default is Opus (Egor, 2026-10-13); bugs rounds keep Opus.
    if [ -n "$fit_round" ] && [ "$model" = opus ] &&
      worker_model_effort_allowed claudeb sonnet "${effort:-$(worker_model_default_effort claudeb sonnet)}" workers; then
      model=sonnet
      effort=${effort:-$(worker_model_default_effort claudeb sonnet)}
    fi
  fi
  # Fast is the chat pin's modifier and it is WORKERS ONLY (Egor): a research or light leg carries
  # the model its own row names, whatever this chat asked for.
  chat_fast=false
  if [ "$role" = workers ] && [ -z "$light" ] && worker_model_chat_fast "$vendor"; then
    chat_fast=true
  fi
  # One resolution for the slug a fast chat launches; the spawn hook labels its row through the
  # same helper, so the row and the run can never name different models.
  if [ "$vendor" = grok ]; then
    fast_role=$role
    [ -z "$light" ] || fast_role=light
    # The account's catalog is only known at the second resolution below, which must judge the
    # model as asked: handed the swapped twin it would take it for a named slug and skip the check.
    grok_asked_model=$model
    model=$(worker_model_grok_launch_model "$model" "$fast_role")
  fi
  effort=${effort:-$(config_value "${vendor}_effort")}
  effort=${effort:-$(worker_model_default_effort "$vendor" "$model" "$model_class")}
  # Gemini is raised, never refused: Egor's rule is high on every Gemini leg, and a brief asking for
  # less is asking for a cheaper model than the vendor has, not for a different run. A word the
  # table knows nothing of is still a typo and still refused below.
  if [ "$vendor" = gemini ] && [ "$effort" != high ]; then
    case "$effort" in
      low | medium | xhigh | max)
        printf 'gemini effort forced to high\n' >&2
        effort=high
        ;;
    esac
  fi
  if { [ "$vendor" != codex ] || [ -z "$resume" ] || [ -n "$explicit_effort" ]; } &&
     ! worker_model_effort_allowed "$vendor" "$model" "$effort" "$model_class"; then
    outcome_line EFFORT_REFUSED
    fail "$vendor model $model does not allow effort $effort; allowed efforts: $(worker_model_effort_list "$vendor" "$model" "$model_class"). Nothing was launched and no account was spent."
  fi
  if [ "$role" = workers ] && [ "$vendor/$model" != claudeb/fable ] && [ -n "${WORKER_RUN_RECORD:-}" ] &&
     [ "$(jq -r '.model // empty' "$WORKER_RUN_RECORD/meta.json" 2>/dev/null)" = fable ]; then
    outcome_line NESTED_MODEL_REFUSED
    fail "this run is nested in a Fable worker and would hand its brief to $vendor $model; Egor chose Fable for that brief, so do the work in this session. Nothing was launched and no account was spent."
  fi
  if [ "$vendor" = codex ]; then
    slug_account=$explicit_account
    if [ -n "$slug_account" ]; then
      model_id=$(worker_model_codex_slug "$model" "$slug_account") || model_id=''
      [ -n "$model_id" ] || refuse_codex_model "$model"
    fi
  fi
  [ -z "$resume" ] || [ -n "$explicit_account" ] || fail '--resume requires --account: sessions live inside one vendor profile, and worker-pick may route elsewhere'
  refuse_live_run "$brief" "$resume"
  [ "$role" != workers ] || refuse_busy_worktree "$workdir"
  # Paths are re-resolved by the detached supervisor after it cds to workdir, so
  # relative arguments valid here would dangle there — pin them to the caller's cwd.
  for value in "${!images[@]}"; do
    [ -r "${images[$value]}" ] || fail "image is not readable: ${images[$value]}"
    [[ "${images[$value]}" = /* ]] || images[$value]="$PWD/${images[$value]}"
  done
  while IFS= read -r value; do brief_images+=("$value"); done < <(perl -nle 'print $1 while /(?:^|[\s"'\''`(<])(\/[^\s"'\''`()<>]+?\.(?:png|jpe?g|webp|gif))(?![\w\/-]|\.\w)/gi' "$brief" | awk '!seen[$0]++')
  if [ "$vendor" = codex ]; then
    for value in "${brief_images[@]}"; do
      [ -f "$value" ] && [ -r "$value" ] || continue
      for image in "${images[@]}"; do [ "$image" != "$value" ] || continue 2; done
      images+=("$value")
    done
  fi
  for value in "${!add_dirs[@]}"; do
    [[ "${add_dirs[$value]}" = /* ]] || add_dirs[$value]="$PWD/${add_dirs[$value]}"
  done

  if [ "$computer" = true ] || [ "$browser:$vendor:${browser_target:-chrome}" = true:codex:chrome ]; then
    computer_home=$(browse_real_home)
    cua_repl_sync "$(browse_codex_config "$computer_home")"
    if [ "$CUA_REPL_STATUS" = broken ]; then
      printf 'REASON: codex computer use unavailable — cua_repl registration failed: %s\n' "$CUA_REPL_ERROR"
      return 2
    fi
    if [ "$(sky_ensure "$computer_home")" = absent ]; then
      printf 'REASON: codex computer use unavailable — SkyComputerUseService is not running and Codex Computer Use.app did not start it\n'
      return 2
    fi
  fi

  if [ -n "$explicit_account" ]; then
    account="$explicit_account"
  else
    PICKED_RC=1
    value=$(worker_claims_fresh "$vendor" 2>/dev/null) || value=''
    [ "$browser:$vendor:${browser_target:-chrome}" != true:claudeb:chrome ] || pick_account_listing "$vendor" "$(browse_unready)" "$model"
    [ "$PICKED_RC" -eq 0 ] && [ -n "$PICKED_ACCOUNT" ] || pick_account_listing "$vendor" '' "$model"
    if [ "$PICKED_RC" -eq 0 ] && [ -n "$PICKED_ACCOUNT" ]; then
      account="$PICKED_ACCOUNT"
      # The pick claimed it for this launch; a refusal before the record exists hands it back.
      if ! grep -qxF -- "$account" <<<"$value"; then
        PICK_CLAIM="$vendor/$account"
        trap '[ -z "$PICK_CLAIM" ] || worker_claims_release "${PICK_CLAIM%%/*}" "${PICK_CLAIM#*/}" 2>/dev/null || :' EXIT
      fi
    elif [ "$PICKED_RC" -eq 3 ]; then
      if [ "$PICKED_POOL_EMPTY" = true ]; then
        outcome_line "$(vendor_name "$vendor")_UNAVAILABLE"
        fail "every $vendor account is out of the worker pool; ask Egor to put one back in or pin one"
      fi
      if [ "$PICKED_ROLE_OFF" = true ]; then
        outcome_line "$(vendor_name "$vendor")_UNAVAILABLE"
        fail "$vendor is switched off for workers; ask Egor to turn the role back on or name another vendor"
      fi
      if [ "$PICKED_NO_DATA" = true ]; then
        outcome_line "$(vendor_name "$vendor")_UNAVAILABLE"
        fail "worker-pick has no usage data for $vendor, so it can route to no account; name one with --account"
      fi
      # A wall behind the passed-over accounts is a quota to wait out, not a model to change.
      if [ -n "$PICKED_UNLISTED" ] && [ "$PICKED_WALLED" = false ]; then
        outcome_line MODEL_REFUSED
        fail "$vendor model $model: no selectable account lists it (passed over $PICKED_UNLISTED, whose catalogs lack it). Nothing was launched and no account was spent."
      fi
      outcome_line "$(vendor_name "$vendor")_USAGE_LIMIT"
      exit 3
    else
      pin=$(worker_model_pin_first "$vendor")
      if [ -n "$pin" ]; then
        account="$pin"
      elif [ "$vendor" = claudeb ]; then
        fail 'claudeb needs an explicit account or claudeb_profile pin when worker-pick is unavailable'
      elif [ "$vendor" = grok ]; then
        # `main` is the real ~/.grok and carries no login, so falling back to it would launch a run
        # that can only fail at authentication.
        outcome_line GROK_UNAVAILABLE
        fail 'grok has no account to fall back on: name one with --account, pin grok_profile, or bring worker-pick back'
      else
        account=main
      fi
    fi
  fi
  # The role switch walls the vendor exactly the way the pool walls an account: an explicit
  # --account, a resumed session or the pin fallback cannot get in under it; the vendor pin and the
  # chat's open=all (never for Gemini Flash) are the overrides, because naming either is the deliberate "use this one anyway";
  # so is a non-Flash Gemini family, which runs only where it was asked for.
  if [ "$role" = workers ] && [ -z "$light" ] && [ "$computer" = false ] && [ "$browser" = false ] && [ "$(config_value "${vendor}_workers")" = off ] &&
     ! worker_model_pin_has "$vendor" "$account" && ! worker_model_chat_opens_workers "$vendor" "$model" &&
     ! { [ "$vendor" = gemini ] && worker_model_gemini_requested "$model"; }; then
    outcome_line "$(vendor_name "$vendor")_UNAVAILABLE"
    fail "$vendor is switched off for workers; ask Egor to turn the role back on or name another vendor"
  fi
  # The pool is a wall, not advice to the picker: an account Egor took out cannot carry a worker
  # even when the brief names it outright — only the vendor pin overrides. A picked account is
  # already in the pool, so this only ever fires on --account.
  if ! worker_pool_refuse_headless "$vendor" "$account" "$(worker_model_pin_csv < <(worker_model_pins "$vendor"))"; then
    outcome_line "$(vendor_name "$vendor")_UNAVAILABLE"
    exit 4
  fi
  case "$vendor:$account" in
    codex:main) ! codex_main_removed || fail 'codex account main has been removed' ;;
    gemini:main) ! gemini_main_removed || fail 'gemini account main has been removed' ;;
    gemini:*) [[ "$account" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid gemini account: $account" ;;
    grok:*) [[ "$account" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid grok account: $account" ;;
    *) [[ "$account" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail "invalid account: $account" ;;
  esac
  # The account's own Fast Mode is only known now; the chat's was applied above.
  if [ "$vendor" = grok ]; then
    value=$(worker_model_grok_launch_model "$grok_asked_model" "$fast_role" '' "$account")
    if [ "$value" != "$model" ] && ! worker_model_effort_allowed grok "$value" "$effort" "$model_class"; then
      outcome_line EFFORT_REFUSED
      fail "grok model $value (this account's Fast Mode) does not allow effort $effort; allowed efforts: $(worker_model_effort_list grok "$value" "$model_class"). Nothing was launched and no account was spent."
    fi
    model=$value
  fi
  if [ "$vendor" = codex ] && [ "$account" != "$slug_account" ]; then
    if [ -n "${PICKED_SLUG:-}" ] && [ "$account" = "$PICKED_ACCOUNT" ]; then
      model_id=$PICKED_SLUG
    else
      model_id=$(worker_model_codex_slug "$model" "$account") && [ -n "$model_id" ] ||
        model_id=$(worker_model_codex_slug "$model") || model_id=''
    fi
    [ -n "$model_id" ] || refuse_codex_model "$model"
  fi
  [ "$vendor" != claudeb ] || [ -n "$resume" ] || own_headroom_guard "$account"
  refuse_stale_resume "$vendor" "$account" "$resume"
  if [ "$browser" = true ]; then
    browser_target=${browser_target:-chrome}
    browser_preamble=$(mktemp "${TMPDIR:-/tmp}/worker-run-browser.XXXXXX") || fail 'could not create the browser preamble'
    browse_prepare "$vendor" "$browser_target" "$account" "$browser_preamble" || { rm -f "$browser_preamble"; return 2; }
    browser_account=$account browser_device=$BROWSE_DEVICE browser_profile=$BROWSE_PROFILE
  fi

  case "$vendor" in
    claudeb)
      cli="${WORKER_RUN_CLAUDEB:-$HOME/.local/bin/claudeb}"
      inbox_settings=$(inbox_hook_settings) || fail 'could not compose the inbox hook settings. Nothing was launched and no account was spent.'
      # The user CLAUDE.md speaks to Egor's chat (language, routing, the worker toggle); a worker's share
      # of it rides BRIEF_PREAMBLE, and the repository's own CLAUDE.md still loads.
      inbox_settings=$(jq -c --arg home "$HOME" --arg real "$(realpath "$HOME/.claude/CLAUDE.md" 2>/dev/null)" \
        '. + {claudeMdExcludes: ([$home + "/.claude-profiles/*/CLAUDE.md", $home + "/.claude/CLAUDE.md", $real] | map(select(. != "")) | unique)}' \
        <<<"$inbox_settings") || fail 'could not compose the worker settings. Nothing was launched and no account was spent.'
      command_meta=("$cli" profile "$account" -p --model "$model" --effort "$effort" --output-format json --dangerously-skip-permissions --settings "$inbox_settings")
      while IFS= read -r value; do command_meta+=("$value"); done < <(web_search_claudeb_args "$web_search_state" "$CLAUDEB_DENIED_TOOLS")
      [ -z "$resume" ] || command_meta+=(--resume "$resume")
      [ "$chrome" = false ] || command_meta+=(--chrome)
      [ "$browser:${browser_target:-}" != true:dia ] || command_meta+=(--mcp-config "$(browse_dia_claude_config)")
      ;;
    codex)
      model_label=${model##*-}
      [[ "$model_label" =~ ^[A-Za-z0-9]+$ ]] || model_label=astra
      cli="${WORKER_RUN_CODEX:-codex}"
      if [ -n "$resume" ]; then
        # `exec resume` keeps the session's own model unless told otherwise, so
        # only an explicit request overrides it — config defaults must not.
        command=("$cli" exec resume "$resume")
        [ -z "$explicit_model" ] || command+=(-m "$model_id")
        [ -z "$explicit_effort" ] || command+=(-c "model_reasoning_effort=$explicit_effort")
      else
        command=("$cli" exec -C "$workdir" -m "$model_id" -c "model_reasoning_effort=$effort" --color never)
      fi
      [ "$role" != research ] || command+=(--sandbox read-only)
      for value in "${add_dirs[@]}"; do command+=(--add-dir "$value"); done
      for value in "${images[@]}"; do command+=(-i "$value"); done
      while IFS= read -r value; do command+=("$value"); done < <(web_search_args codex "$web_search_state")
      # The chat's own word outranks the account's standing switch for this run alone.
      fast_tier=false
      if [ "$chat_fast" = true ] || [ "$(codex_fast_tier "$account")" = fast ]; then fast_tier=true; fi
      while IFS= read -r value; do command+=("$value"); done < <(codex_tier_args "$account" "$model_id" "$fast_tier")
      command+=(-o OUT -)
      if [ "$account" = main ]; then command_meta=("${command[@]}"); else command_meta=(env "CODEX_HOME=$(codex_home "$account")" "${command[@]}"); fi
      ;;
    gemini)
      # The effort rides in the agy slug and never in an `--effort` flag (shared-invariants row h).
      [ "$effort" = high ] || { outcome_line GEMINI_UNAVAILABLE; exit 4; }
      if [ -n "${PICKED_SLUG:-}" ] && [ "$account" = "$PICKED_ACCOUNT" ]; then gemini_family=$PICKED_SLUG
      else gemini_family=$(worker_model_gemini_prefix "$model" "$account"); fi
      [ -n "$gemini_family" ] || { outcome_line MODEL_REFUSED; fail "gemini/$account lists no model $model. Nothing was launched and no account was spent."; }
      agy_model="$gemini_family-$effort"
      cli="${WORKER_RUN_GEMINIB:-$HOME/.local/bin/geminib}"
      if [ "$account" != main ]; then
        list_output=$("$cli" list 2>/dev/null)
        list_rc=$?
        if [ "$list_rc" -ne 0 ] || ! grep -Eq "^${account}:" <<<"$list_output"; then
          outcome_line GEMINI_UNAVAILABLE
          exit 4
        fi
      fi
      command_meta=("$cli" profile "$account" --model "$agy_model" --add-dir "$HOME/.claude")
      for value in "${add_dirs[@]}"; do command_meta+=(--add-dir "$value"); done
      command_meta+=(--print-timeout 360m --dangerously-skip-permissions --log-file LOG)
      while IFS= read -r value; do command_meta+=("$value"); done < <(web_search_args gemini "$web_search_state")
      [ -z "$resume" ] || command_meta+=(--conversation "$resume")
      command_meta+=(--print BRIEF_TEXT)
      ;;
    grok)
      model_label=$(worker_model_grok_label "$model")
      # No turn cap unless one is asked for: an implementation brief is bounded by the wall-clock
      # deadline like every other vendor's, and a cap ends a run the vendor was still serving.
      grok_turns=${WORKER_RUN_GROK_MAX_TURNS:-}
      [[ "$grok_turns" =~ ^[0-9]+$ ]] && [ "$grok_turns" -gt 0 ] || grok_turns=''
      cli="${WORKER_RUN_GROKB:-$HOME/.local/bin/grokb}"
      command_meta=(env GROK_MEMORY=0 "$cli" profile "$account" --prompt-file BRIEF
        --output-format streaming-json --always-approve --cwd "$workdir"
        --no-subagents --reasoning-effort "$effort")
      [ -z "$grok_turns" ] || command_meta+=(--max-turns "$grok_turns")
      [ "$model" = auto ] || command_meta+=(-m "$model")
      [ -z "$resume" ] || command_meta+=(-r "$resume")
      while IFS= read -r value; do command_meta+=("$value"); done < <(web_search_args grok "$web_search_state")
      ;;
  esac

  allocate_run_directory "$vendor"
  cp "$brief" "$directory/brief" || fail 'could not copy brief'
  value=$(brief_title "$brief")
  printf '%s\n' "$value" >"$directory/title.tmp.$$" && mv -f "$directory/title.tmp.$$" "$directory/title" ||
    fail 'could not write the run title'
  grep -q '^MD-GUARD' "$brief" || md_guard_text >"$directory/md-guard" || fail 'could not write the md guard'
  [ -z "$fix_rule" ] || printf '%s\n' "$fix_rule" >"$directory/fix-rule" || fail 'could not write the fix rule'
  [ "$vendor" != grok ] || [ "$role" != research ] ||
    printf '%s\n' "$GROK_RESEARCH_FENCE" >"$directory/research-fence" || fail 'could not write the research fence'
  [ "$vendor" != claudeb ] || [ "$role" = research ] ||
    printf '%s\n' "$CLAUDEB_EDIT_FENCE" >"$directory/edit-fence" || fail 'could not write the edit fence'
  if [ "$browser" = true ]; then
    cp "$browser_preamble" "$directory/browser-preamble" || fail 'could not copy browser preamble'
    rm -f "$browser_preamble"
  fi
  [ "$computer" = false ] || printf '%s\n' "$COMPUTER_PREAMBLE" >"$directory/computer-preamble" ||
    fail 'could not write the computer preamble'
  [ -z "$resume" ] || inbox_carry_resume "$directory" "$resume"
  # The recorded brief is the input, byte for byte — `worker-run report` and RESUME both
  # quote it back, and a preamble growing on every hop would be a brief nobody wrote. What the
  # vendor is handed is this second file, and only ever this one.
  launch_attempt "$directory" || fail 'could not compose the launched brief'
  : >"$directory/out"
  : >"$directory/err"
  [ "$vendor" != gemini ] || : >"$directory/log"
  for value in "${!command_meta[@]}"; do
    case "${command_meta[$value]}" in
      OUT) command_meta[$value]="$directory/out" ;;
      LOG) command_meta[$value]="$directory/log" ;;
      BRIEF) command_meta[$value]="$directory/brief.launch" ;;
      BRIEF_TEXT) command_meta[$value]=$(<"$directory/brief.launch") ;;
    esac
  done
  printf '%s · %s · %s\n' "$account" "${model_label:-$model}" "$effort" >"$directory/tag"
  cmd_json=$(jq -cn --args '$ARGS.positional' -- "${command_meta[@]}") || fail 'could not encode command metadata'
  add_dirs_json=$(jq -cn --args '$ARGS.positional' -- "${add_dirs[@]}") || fail 'could not encode add-dir metadata'
  images_json=$(jq -cn --args '$ARGS.positional' -- "${images[@]}") || fail 'could not encode image metadata'
  started=$(date +%s)
  jq -cn --arg vendor "$vendor" --arg account "$account" --arg model "$model" --arg effort "$effort" \
    --arg agy_model "$agy_model" --arg grok_turns "$grok_turns" --arg model_id "$model_id" \
    --arg workdir "$workdir" --arg resume "$resume" --arg cli "$cli" \
    --arg explicit_model "$explicit_model" --arg explicit_effort "$explicit_effort" --arg role "$role" --arg explicit_account "$explicit_account" \
    --arg research_timeout "$research_timeout" --arg sandbox_exec "$sandbox_exec" --arg review_round "$review_round" \
    --arg round_source "$round_source" \
    --argjson pid 0 --argjson started_at "$started" --argjson cmd "$cmd_json" \
    --argjson add_dirs "$add_dirs_json" --argjson images "$images_json" --argjson web_search "$web_search" \
    --argjson chrome "$chrome" --argjson browser "$browser" --argjson computer "$computer" --argjson chat_fast "$chat_fast" \
    --arg browser_device "$browser_device" --arg browser_account "$browser_account" --arg browser_target "$browser_target" \
    --arg browser_profile "$browser_profile" \
    --arg light "$light" --arg inbox_settings "$inbox_settings" \
    '{vendor:$vendor,account:$account,model:$model,effort:$effort,role:$role,research_timeout:$research_timeout,sandbox_exec:$sandbox_exec,workdir:$workdir,pid:$pid,cmd:$cmd,started_at:$started_at,resume:$resume,cli:$cli,add_dirs:$add_dirs,images:$images,web_search:$web_search,chrome:$chrome,browser:$browser,explicit_model:$explicit_model,explicit_effort:$explicit_effort}
     + {explicit_account:$explicit_account}
     + if $chat_fast then {fast:true} else {} end
     + if $computer then {computer:true} else {} end
     + if $light != "" then {light:$light} else {} end
     + if $inbox_settings != "" then {inbox_settings:$inbox_settings} else {} end
     + if $review_round != "" then {review_round:$review_round,round_source:$round_source} else {} end
     + if $browser then {browser_device:$browser_device,browser_account:$browser_account,browser_target:$browser_target,browser_profile:$browser_profile} else {} end
     + if $vendor == "gemini" then {agy_model:$agy_model} else {} end
     + if $model_id != "" then {model_id:$model_id} else {} end
     + if $vendor == "grok" and $grok_turns != "" then {max_turns:($grok_turns | tonumber)} else {} end' >"$directory/meta.json" || fail 'could not write metadata'
  # A picked account was claimed by worker-pick --claim; a named one spends the same window, so
  # unclaimed the next pick hands parallel lanes this account too (log_audit:worker-on-exhausted-account).
  [ -z "$explicit_account" ] || worker_claims_record "$vendor" "$account" 2>/dev/null || :
  PICK_CLAIM=''
  # Who this run answers to, written where a hook can find it without parsing anything: a worker a
  # chat spawned IS that chat (Egor, 2026-08-17), and the run is the only place that fact exists —
  # the report says who a worker is, never who asked for it, so ownership read off a report is
  # ownership assigned to whoever happened to read it. A file rather than a meta.json key because
  # the reader is a per-tool-call hook globbing hundreds of runs, and one grep is its whole budget.
  # And into the worker's own environment, under a name the harness does not overwrite: inside the
  # launched CLI `CLAUDE_CODE_SESSION_ID` is that process's OWN chat, so a report the worker
  # produces has no other way to name the chat it belongs to and lands in its own outbox. The
  # supervisor spawned below inherits this export, and `claudeb` passes the environment through
  # untouched.
  # Launched from inside a worker, CLAUDE_CODE_SESSION_ID is that worker's own chat, while the chat
  # that owns the whole chain — and whose tag cache the task rows read — arrives as the launcher.
  launcher_session=${CLAUDE_LAUNCHER_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}
  case "$launcher_session" in
    ''|.|..|*[!A-Za-z0-9._-]*) ;;
    *)
      printf '%s\n' "$launcher_session" >"$directory/launcher"
      # A script (log-audit, the code-doctor judge, a chat's launch loop) that starts several runs waits on
      # them itself; the Stop hooks leave a run alone while any process from its parent up to the chat's
      # CLI lives: in `id=$(worker-run start … | grep …)` the parent is a subshell gone at once.
      starter_now=$(date +%s)
      while read -r starter_pid starter_etime; do
        etime_parse "$starter_etime" && printf '%s %s\n' "$starter_pid" "$((starter_now - ETIME_SECONDS))"
      done < <(starter_chain "$PPID") >"$directory/starter"
      "$SCRIPT_DIRECTORY/statusline-place" add --session "$launcher_session" --kind worker-start \
        --path "$workdir" >/dev/null 2>&1 || :
      export CLAUDE_LAUNCHER_SESSION="$launcher_session"
      # The anchors store's own name for the same fact: every touch a hook inside this worker
      # records is the LAUNCHER's, whatever session id the vendor journals under.
      export CLAUDE_DEBT_OWNER="$launcher_session" ;;
  esac
  # The run's own directory, which a fixing worker writes its verdict rows into. Not
  # `WORKER_RUN_DIR`: that name is the store ROOT everywhere on this machine (claude-setup's
  # hooks, `share/chat_names.py`), and overwritten here every reader inside the worker would look
  # for run records under one run.
  export WORKER_RUN_RECORD="$directory" WORKER_RUN_ID="$run_id"

  supervisor_body='# Double-forked so no bare wait hangs on it, and without WORKER_RUN_ID so end_run_orphans never ends it as an orphan of the run;
# exec: without it the forked shell running `cd / &&` stays, the id in its env, as the parent of caffeinate, and both end as orphans.
# From / because, orphaned out of this tree, it would stand in the launcher cwd and the speed gate would refuse this very run.
command -v caffeinate >/dev/null 2>&1 && (cd / && exec env -u WORKER_RUN_ID caffeinate -i -w $$ </dev/null >/dev/null 2>&1 &)
enable -f "${BASH%/bin/*}/lib/bash/sleep" sleep 2>/dev/null || :
ticks=0
while [ ! -e "$2/.ready" ]; do
  ticks=$((ticks + 1))
  if [ "$ticks" -ge 6000 ]; then
    "$1" _deliver "$2" 4 >/dev/null 2>&1
    printf "4\n" >"$2/exit_code.tmp.$$"
    mv -f "$2/exit_code.tmp.$$" "$2/exit_code"
    exit 4
  fi
  sleep 0.01
done
rm -f "$2/.ready"
# Backgrounded and waited on, with the signal passed down: run in the foreground, this shell dies
# on a TERM without ever reaching the lines below, and the run it was supervising is left with no
# exit code and a vendor CLI still writing.
"$1" _supervise "$2" &
supervised=$!
trap "kill -TERM $supervised 2>/dev/null" TERM INT
wait "$supervised"
rc=$?
if [ "$rc" -gt 128 ]; then
  wait "$supervised" 2>/dev/null
  reaped=$?
  [ "$reaped" -eq 127 ] || rc=$reaped
fi
# _supervise delivers in its own forked deliverer; one that never took over leaves it to a fresh parse.
if [ -e "$2/.delivering" ]; then rm -f "$2/.delivering"; else "$1" _deliver "$2" "$rc" >/dev/null 2>&1; fi
# A suite that started this run counts its CPU: detached, it is no child the suite reaps.
[ -z "${RUN_SUITES_DETACHED_CPU:-}" ] || times >>"$RUN_SUITES_DETACHED_CPU" 2>/dev/null
printf "%s\n" "$rc" >"$2/exit_code.tmp.$$"
mv -f "$2/exit_code.tmp.$$" "$2/exit_code"
exit "$rc"'
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid bash -c "$supervisor_body" _ "$SCRIPT_PATH" "$directory" </dev/null >/dev/null 2>&1 &
  elif command -v perl >/dev/null 2>&1; then
    nohup perl -MPOSIX -e 'defined POSIX::setsid() or die "setsid failed\n"; exec @ARGV; die "exec failed\n"' \
      bash -c "$supervisor_body" _ "$SCRIPT_PATH" "$directory" </dev/null >/dev/null 2>&1 &
  else
    fail 'setsid is unavailable'
  fi
  pid=$!
  # pid_started_at is the supervisor's launch instant and never restamped: started_at moves on
  # every walled reroute (run_overdue budgets one deadline per attempt), and a liveness check
  # comparing the pid's own age against a restamped clock reads a live rerouted run as dead.
  pid_began=$(date +%s)
  # The speed gate runs in the detached supervisor, past the reach of its own-ancestry skip.
  launcher_pid=''
  case $workdir in */.claude/worktrees/night-*) launcher_pid=$(claude_ancestor "$PPID") || launcher_pid='' ;; esac
  jq --argjson pid "$pid" --argjson began "$pid_began" --arg launcher "$launcher_pid" \
    '.pid = $pid | .pid_started_at = $began | if $launcher == "" then . else .launcher_pid = ($launcher | tonumber) end' \
    "$directory/meta.json" >"$directory/meta.json.tmp.$$" \
    && mv -f "$directory/meta.json.tmp.$$" "$directory/meta.json" || fail 'could not record supervisor pid'
  inbox_carry_commit "$directory"
  # Before the run is readable and not only when it ends: a resumed session journals under an id
  # this launch already knows, and the gate that prices a live run's worker work reads this file.
  record_worker_session "$directory"
  write_run_state "$directory" start
  : >"$directory/.ready"
  # WEB: on the launch line, because the state the run really got is otherwise only in meta.json and
  # an orchestrator cannot tell a web-grounded answer from one written out of memory.
  printf 'RUN: %s\nTAG: %s · %s · %s\nWEB: %s\nDIR: %s\n' "$run_id" "$account" "${model_label:-$model}" "$effort" "$web_search_state" "$directory"
  for value in "${brief_images[@]}"; do
    [ -f "$value" ] && [ -r "$value" ] || printf 'IMAGE-MISSING: %s — the brief names it, it is not readable, the worker will not see it\n' "$value"
  done
  printf 'NEXT: worker-run wait %s as a background Bash; a mid-run note: worker-run say %s "<text>"\n' "$run_id" "$run_id"
}

newest_mtime() { # files... -> NEWEST_MTIME
  local newest=0 path
  for path in "$@"; do
    file_lstat "$path" || continue
    [[ "$FILE_MTIME" =~ ^[0-9]+$ ]] && [ "$FILE_MTIME" -gt "$newest" ] && newest=$FILE_MTIME
  done
  NEWEST_MTIME=$newest
}
