# worker-run, account picks, walls, floors and the night's admission; sourced by bin/worker-run in place, so
# an edit here runs its own suites rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

run_picker() {
  local picker="$1" vendor="$2" exclude="$3" errors="$4" model="${5-}"
  local role_arg=${WORKER_RUN_ROLE:-workers}
  local -a args=(--account "$vendor")
  [ "$role_arg" = workers ] || args+=(--role "$role_arg")
  [ "$vendor" != gemini ] || [ -z "$model" ] || args+=(--model "$model")
  args+=(--claim)
  [ -z "$exclude" ] || args+=(--exclude "$exclude")
  "$picker" "${args[@]}" 2>"$errors"
}

pick_account() {
  local vendor="$1" walled="$2" model="${3-}" picker errors
  PICKED_ACCOUNT=''
  PICKED_RC=0
  PICKED_POOL_EMPTY=false
  PICKED_ROLE_OFF=false
  PICKED_NO_DATA=false
  picker="${WORKER_RUN_WORKER_PICK:-worker-pick}"
  errors=$(mktemp "${TMPDIR:-/tmp}/worker-run-pick.XXXXXX") ||
    fail 'could not create a temporary file for the account query'
  PICKED_ACCOUNT=$(run_picker "$picker" "$vendor" "$walled" "$errors" "$model")
  PICKED_RC=$?
  [ ! -s "$errors" ] || cat "$errors" >&2
  # An empty pool is Egor's choice, not a limit: reporting it as a usage limit would send the
  # orchestrator hunting for quota that is not the problem.
  ! grep -Eq 'every [a-z]+ account is out of the worker pool' "$errors" || PICKED_POOL_EMPTY=true
  # A vendor closed for this role is the same kind of decision, and its accounts may be at 0%.
  # Only workers is asked for here, so only workers can come back.
  ! grep -q 'is switched off for workers' "$errors" || PICKED_ROLE_OFF=true
  ! grep -Eq 'worker-pick: [a-z]+ is paused \(' "$errors" || PICKED_ROLE_OFF=true
  # A vendor the picker cannot read at all — no accounts, no usage snapshot — is not a walled one.
  # Its quota may be untouched, and this whole system exists so that nothing reports a limit it has
  # no data for (docs/DIAGNOSTICS.md, the 429 taxonomy).
  # worker-pick puts its whole vendor line inside those parens, so the reason may carry a
  # pin-lapse clause before it and, on older builds, a vendor prefix (`grok: unavailable`).
  ! grep -Eq 'no selectable [a-z]+ account \(([a-z]+: )?([^)]*[|—] )?(unavailable|no( [A-Za-z]+)* quota data|no accounts)\)' "$errors" ||
    PICKED_NO_DATA=true
  PICKED_WALLED=false
  ! grep -Eq '(^|[^[:alnum:]_])WALLED([^[:alnum:]_]|$)' "$errors" || PICKED_WALLED=true
  if [ "${WORKER_RUN_ROLE:-workers}" = research ] && [ "$PICKED_WALLED" = false ]; then
    PICKED_NO_DATA=true
  fi
  rm -f "$errors"
  PICKED_ACCOUNT=${PICKED_ACCOUNT%%$'\n'*}
}

# The picker ranks quota only, and a codex or gemini catalog is per account: a lapsed plan lists the
# free models alone, so its idle account ranks first and would launch an id it does not serve.
pick_account_listing() { # vendor exclude model
  local exclude=$2 claimed=''
  PICKED_UNLISTED='' PICKED_SLUG=''
  while :; do
    case "$1" in codex | gemini) claimed=$(worker_claims_fresh "$1" 2>/dev/null) || claimed='' ;; esac
    pick_account "$1" "$exclude" "$3"
    [ "$PICKED_RC" -eq 0 ] && [ -n "$PICKED_ACCOUNT" ] || return 0
    case "$1" in
      codex) PICKED_SLUG=$(worker_model_codex_slug "$3" "$PICKED_ACCOUNT") ;;
      gemini) PICKED_SLUG=$(worker_model_gemini_prefix "$3" "$PICKED_ACCOUNT") ;;
      *) return 0 ;;
    esac
    [ -z "$PICKED_SLUG" ] || return 0
    case ",$exclude," in *",$PICKED_ACCOUNT,"*) PICKED_ACCOUNT='' PICKED_RC=3; return 0 ;; esac
    # The picker claimed it for this launch; a claim someone else already held stays theirs.
    grep -qxF -- "$PICKED_ACCOUNT" <<<"$claimed" || worker_claims_release "$1" "$PICKED_ACCOUNT" || :
    printf 'worker-run: %s/%s lists no model of %s; routing past it\n' "$1" "$PICKED_ACCOUNT" "$3" >&2
    PICKED_UNLISTED=${PICKED_UNLISTED:+$PICKED_UNLISTED,}$PICKED_ACCOUNT
    exclude=${exclude:+$exclude,}$PICKED_ACCOUNT
  done
}

record_run_wall() {
  local directory="$1" vendor="$2" account reset epoch event
  account=$(jq -r '.account' "$directory/meta.json" 2>/dev/null) || return 0
  [ -n "$account" ] || return 0
  event="$directory/wall-reset.$(head -n1 "$directory/attempt" 2>/dev/null)"
  local target="${vendor/#claudeb/claude}/$account" wall
  if ! IFS= read -r epoch 2>/dev/null <"$event"; then
    reset=$(worker_walls_extract_reset "$directory/out" "$directory/err")
    epoch=$(worker_walls_parse_reset "$reset") || epoch=''
    # Once per attempt: the second call (reroute_walled after the watchdog's) no longer holds the
    # reset text, and read without it a codex weekly wall is `unknown`. Fired BEFORE the mark that
    # stops the second call: the watchdog's tree kill can land between the two, and a mark written
    # first would lose the armed redeem for good. Detached and off the run's id, or that kill and
    # end_run_orphans end it while it waits for the arm lock.
    if [ -f "${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/reset-arm/${target/\//-}" ]; then
      wall=$(worker_walls_kind "$vendor" "${reset:+$epoch}" "$directory/out" "$directory/err")
      child_group_prefix
      (env -u WORKER_RUN_ID ${CHILD_GROUP_PREFIX[@]+"${CHILD_GROUP_PREFIX[@]}"} "$SCRIPT_DIRECTORY/llm-reset-redeem" \
        --fire-armed "$target" --wall "$wall" </dev/null >/dev/null 2>&1 &)
    fi
    # A timeless wall keeps the attempt's first sighting, so a re-record never moves its retry time.
    printf '%s\n' "${epoch:-@$(date +%s)}" >"$event" || return 1
  fi
  local since='' bucket=''
  case "$epoch" in @*) since=${epoch#@}; epoch='' ;; esac
  [ "$vendor" != gemini ] || { bucket=$(jq -r '.model // empty' "$directory/meta.json" 2>/dev/null) &&
    worker_model_gemini_requested "$bucket"; } || bucket=''
  worker_walls_record "$vendor" "$account" "$epoch" '' "$since" "$bucket" || true
  worker_model_clear_walled_pin "$vendor" "$account" || true
}

reroute_walled() {
  # At most ONE reroute per run (Egor, 2026-10-05): each rescue is a fresh session rereading the whole
  # context, and a chain of them burnt a pool for hours unseen; the second wall hands the choice back
  # to the launching chat. A resumed session never moves: it lives inside one profile.
  local directory="$1" vendor="$2" walled tag
  # The research leg reads the quota out of the answer stream and the agy log too, which
  # has_limit_signature deliberately never scans; its own verdict is the wall for that run.
  if ! has_limit_signature "$directory" "$vendor"; then
    [ "$(cat "$directory/research-outcome" 2>/dev/null)" = GEMINI_USAGE_LIMIT ] || return 1
  fi
  record_run_wall "$directory" "$vendor"
  # An account-bound browser preamble cannot follow the ordinary pool reroute.
  if [ "$vendor" = claudeb ] && jq -e '.browser == true' "$directory/meta.json" >/dev/null; then return 1; fi
  [ -z "$(jq -r '.resume // empty' "$directory/meta.json")" ] || return 1
  if jq -e '.role == "research" and .explicit_account != ""' "$directory/meta.json" >/dev/null; then return 1; fi
  if jq -e '(.walled_accounts // []) | length > 0' "$directory/meta.json" >/dev/null; then return 1; fi
  walled=$(jq -r '((.walled_accounts // []) + [.account]) | join(",")' "$directory/meta.json")
  pick_account_listing "$vendor" "$walled" "$(jq -r '.model' "$directory/meta.json")"
  [ "$PICKED_RC" -eq 0 ] && [ -n "$PICKED_ACCOUNT" ] || return 1
  # Defence against a picker that ignores --exclude: relaunching on an account
  # this run already burnt would wall again forever.
  case ",$walled," in *",$PICKED_ACCOUNT,"*) return 1 ;; esac
  if [ "$vendor" = gemini ]; then
    grep -Eq "^${PICKED_ACCOUNT}:" <<<"$("$(jq -r '.cli' "$directory/meta.json")" list 2>/dev/null)" ||
      return 1
  fi
  # started_at is restamped because run_overdue budgets one deadline, and a chain
  # of full-length attempts would otherwise read as a wedged CLI.
  # Per-attempt facts belong to the attempt that recorded them: carried over, the abandoned run's
  # served model and refused tools would be reported as the rescue attempt's own.
  meta_update "$directory" \
    '.walled_accounts = ((.walled_accounts // []) + [.account]) | .account = $next | .started_at = $now
     | if .browser then .browser_account = $next else . end
     | del(.served_model, .denied_tools)' \
    --arg next "$PICKED_ACCOUNT" --argjson now "$(date +%s)" || return 1
  if IFS= read -r tag 2>/dev/null <"$directory/tag"; then
    printf '%s · %s\n' "$PICKED_ACCOUNT" "${tag#* · }" >"$directory/tag"
  fi
  : >"$directory/out"
  : >"$directory/err"
  [ "$vendor" != gemini ] || : >"$directory/log"
}

# In the detached supervisor, before the first attempt: hashing a large dirty tree takes minutes, and
# held in start's foreground a caller interrupted there left a run with no supervisor (ledger W6).
take_floor() { # directory workdir
  local directory="$1" workdir="$2" review_round shas_rc
  review_round=$(jq -r '.review_round // empty' "$directory/meta.json" 2>/dev/null) || review_round=''
  REPLY_ARRAY=()
  read_json_array '.add_dirs[]' "$directory/meta.json"
  # What was already uncommitted here before this run touched anything. It is the floor the dirt
  # snapshot at the end is measured against: without it, every file Egor or a co-tenant chat had
  # open would be evidence produced by whichever run happened to finish beside them.
  workdir_dirty_shas "$workdir" "$directory/unshaped-before" "$directory/dirty-before.tmp.$$" "$directory/dirty-stat" \
    >"$directory/dirty-before-shas.tmp.$$" 2>/dev/null; shas_rc=$?
  [ -f "$directory/dirty-before.tmp.$$" ] &&
    mv -f "$directory/dirty-before.tmp.$$" "$directory/dirty-before" 2>/dev/null ||
    rm -f "$directory/dirty-before.tmp.$$" 2>/dev/null
  [ "$shas_rc" = 0 ] &&
    mv -f "$directory/dirty-before-shas.tmp.$$" "$directory/dirty-before-shas" 2>/dev/null ||
    rm -f "$directory/dirty-before-shas.tmp.$$" "$directory/unshaped-before" 2>/dev/null
  # And the commit the tree stood on, which is what a path NOT already dirty is measured against.
  # Never restamped by a reroute: an attempt's floor is the run's floor, and read off the end of the
  # run instead every link the run itself committed would be measured against its own result.
  git -C "$workdir" rev-parse --verify --quiet HEAD >"$directory/head-before.tmp.$$" 2>/dev/null &&
    mv -f "$directory/head-before.tmp.$$" "$directory/head-before" 2>/dev/null ||
    rm -f "$directory/head-before.tmp.$$" 2>/dev/null
  git -C "$workdir" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
    >"$directory/worktrees-before" 2>/dev/null || :
  # A round fixer's fold reads the start, branch and HEAD this record keeps, so a commit landed
  # during the run is never anchored as the fix.
  if [ -n "$review_round" ] && [ -s "$directory/launcher" ] &&
    git -C "$workdir" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$workdir" rev-parse --path-format=absolute --git-common-dir >"$directory/anchors-common" 2>/dev/null ||
      rm -f "$directory/anchors-common" 2>/dev/null
    review_anchors run-start --repo "$workdir" --run "${directory##*/}" --session "$(cat "$directory/launcher")" \
      >/dev/null 2>&1 || :
  fi
  [ -z "$review_round" ] || [ ! -s "$directory/launcher" ] ||
    snapshot_other_families "$directory" "$workdir" "$(cat "$directory/launcher")" \
      ${REPLY_ARRAY[@]+"${REPLY_ARRAY[@]}"}
}

night_admit() { # directory vendor branch -> fails only when the night defers the job; a long wait re-picks the account
  local night=${3#night/} out rc began=$SECONDS tag model
  night=${night%%/*}
  model=$(jq -r '.model // empty' "$1/meta.json" 2>/dev/null)
  out=$("${WORKER_RUN_NIGHT_RUN:-$SCRIPT_DIRECTORY/night-run}" admit "$night" "${3#"night/$night/"}" "$2" $$ "$model" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 3 ]; then
    printf 'worker-run: %s\n' "$out" >>"$1/err"
    return 1
  fi
  [ "$rc" -eq 0 ] && [ $((SECONDS - began)) -ge "${WORKER_RUN_ADMIT_REPICK_S:-60}" ] && [ "$2" = claudeb ] || return 0
  jq -e '(.explicit_account // "") == "" and (.resume // "") == ""' "$1/meta.json" >/dev/null 2>&1 || return 0
  pick_account_listing claudeb '' "$model"
  [ "$PICKED_RC" -eq 0 ] && [ -n "$PICKED_ACCOUNT" ] || return 0
  meta_update "$1" '.account = $next' --arg next "$PICKED_ACCOUNT" || return 0
  if IFS= read -r tag 2>/dev/null <"$1/tag"; then
    printf '%s · %s\n' "$PICKED_ACCOUNT" "${tag#* · }" >"$1/tag"
  fi
}

# The pressure check a chat's delegation passes before any account is picked: a deny refuses the
# launch, a note rides along on stderr.
limit_gate() { # vendor light brief account computer model
  local gate=${WORKER_RUN_LIMIT_GATE:-$SCRIPT_DIRECTORY/worker-limit-gate.sh} verdict reason note worker=$1 family=''
  [ -x "$gate" ] || return 0
  [ -z "$2" ] || worker=light
  [ "${5:-false}" != true ] || worker=computer
  [ "${WORKER_RUN_ROLE:-}" != browser ] || worker=$1-browser
  if [ "$worker" = gemini ] && [ -n "${6-}" ]; then
    family=$(worker_model_gemini_family "$6" | cut -f2)
    family=${family:-$6}
  fi
  verdict=$(WORKER_GATE_MODEL=$family "$gate" --start "$worker" "$3" ${4:+"$4"} 2>/dev/null) || return 0
  [ -n "$verdict" ] || return 0
  reason=$(jq -r 'select(.hookSpecificOutput.permissionDecision == "deny") | .hookSpecificOutput.permissionDecisionReason // empty' <<<"$verdict" 2>/dev/null)
  [ -z "$reason" ] || fail "$reason Nothing was launched and no account was spent."
  note=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$verdict" 2>/dev/null)
  [ -z "$note" ] || printf 'worker-run: note: %s\n' "$note" >&2
}

own_headroom_guard() {
  local account=$1 threshold=${WORKER_RUN_OWN_HEADROOM:-80} reading alternative picker pct
  [ "$threshold" != 0 ] || return 0
  . "$SCRIPT_DIRECTORY/../share/chat-account.sh"
  chat_account_resolve
  [ "$CHAT_ACCOUNT_VENDOR" = claude ] && [ "${CHAT_ACCOUNT_NAME:-main}" = "$account" ] || return 0
  [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'WORKER_RUN_OWN_HEADROOM must be a percentage (0 disables)'
  . "$SCRIPT_DIRECTORY/../share/limits-view.sh"
  reading=$(jq -r --arg account "$account" --argjson threshold "$threshold" --argjson now "$(date +%s)" "$LIMITS_VIEW_JQ"'
    .vendors.claude.accounts[]? | select(.account == $account) |
    limits_store_eff(.five_hour; $now) as $pct |
    ((.five_hour.as_of // .as_of) | limits_store_epoch) as $asof |
    (if $asof == null then null else $now - $asof end) as $age |
    (if $age != null and limits_data_stale($age; 600) then 10 else 0 end) as $margin |
    select($pct != null and $pct + $margin >= $threshold) |
    ["5h \($pct)% (age \(limits_age_text($age)), +\($margin) points staleness margin >= \($threshold)% threshold)",
     limits_reset_text((.five_hour.resets_at | limits_store_epoch); $now), $pct] | @tsv
  ' "${LLM_LIMITS_FILE:-$HOME/.llm-limits.json}" 2>/dev/null) || return 0
  [ -n "$reading" ] || return 0
  pct=${reading##*$'\t'} reading=${reading%$'\t'*}
  picker=${WORKER_RUN_WORKER_PICK:-worker-pick}
  alternative=$("$picker" --account claudeb --role "${WORKER_RUN_ROLE:-workers}" --exclude "$account" 2>/dev/null) || alternative=''
  if [ -n "$alternative" ] && [ "$alternative" != "$account" ]; then
    alternative="use claude/$alternative"
  else
    alternative="wait for the 5h reset at ${reading#*$'\t'}"
  fi
  limit_hit worker-run.own-headroom "$threshold" pct skip "a claudeb launch on the chat's own account $account refused: $alternative" \
    'bin/worker-run:WORKER_RUN_OWN_HEADROOM:-80' "$pct"
  fail "own-account headroom: claude/$account ${reading%%$'\t'*}; $alternative. Nothing was launched and no account was spent. Only Egor's «обойди» lifts it, for one launch: WORKER_RUN_OWN_HEADROOM=0."
}
