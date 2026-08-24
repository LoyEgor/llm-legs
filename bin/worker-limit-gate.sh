#!/usr/bin/env bash
set -u

WARN_AT=85
DENY_AT=95
[ -z "${WORKER_GATE_WARN_PCT:-}" ] || WARN_AT="$WORKER_GATE_WARN_PCT"
[ -z "${WORKER_GATE_DENY_PCT:-}" ] || DENY_AT="$WORKER_GATE_DENY_PCT"
LIMITS_FILE="${LLM_LIMITS_FILE:-$HOME/.llm-limits.json}"
TOGGLE="${WORKER_MODEL_FILE:-$HOME/.claude/worker-model}"
WORKER_PICK="${WORKER_GATE_WORKER_PICK:-/Volumes/Work/Projects/llm-legs/bin/worker-pick}"

STAMP_DIR="${WORKER_GATE_STAMPS:-$HOME/.cache/claude-worker-gate}"

input=$(cat) || exit 0
worker=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null) || exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null) || sid=''

# Stamped from warn() because every allowed spawn leaves through it and no refused one does: a
# denied spawn, a fork or a plain agent quoting `record <id>` must not silence the triage Stop
# gate. Claimed at the spawn because `worker-run` stamps its pid about a minute later and the
# Stop gate fires in that minute; the pid stamp overwrites the claim, which is live for
# DELEGATED_CLAIM_SECONDS (review-bench) and dead after.
claim_delegated_triage() {
  case "$worker" in claudeb-worker|codex-worker|gemini-worker|sonnet-worker) ;; *) return 0 ;; esac
  local claimed_run claim_stamp
  for claimed_run in $(printf '%s' "$brief_text" |
      grep -Eo "review-bench[[:blank:]]+record[[:blank:]]+$run_id_re" | awk '{print $NF}' | sort -u); do
    claim_stamp="$REVIEW_STATE/benches/$claimed_run/delegated"
    [ -d "$REVIEW_STATE/benches/$claimed_run" ] || continue
    # Never over a live worker's pid stamp: only an absent stamp or an earlier claim is replaced.
    if [ -e "$claim_stamp" ] && ! head -n1 "$claim_stamp" 2>/dev/null | grep -q '^claimed '; then
      continue
    fi
    printf 'claimed %s %s\n' "${sid:-unknown}" "$(date +%s)" >"$claim_stamp" 2>/dev/null || :
  done
}

# Carries $toggle_note, so a vendor that disagrees with the toggle is reported without
# stealing the exit from a limit verdict that matters more. `warn ""` is the quiet path.
warn() {
  local msg=${1:-}
  claim_delegated_triage
  if [ -n "${toggle_note:-}" ]; then
    if [ -n "$msg" ]; then msg="${toggle_note} ${msg}"; else msg="$toggle_note"; fi
  fi
  [ -n "$msg" ] || exit 0
  jq -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null || true
  exit 0
}

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null || true
  exit 0
}

# The brief is the prompt plus every readable file an absolute path in it names: a worker is
# routinely told "follow the brief at /path" and the review-bench commands stand in that file.
REVIEW_STATE="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}"
brief_text=$(printf '%s' "$input" | jq -r '.tool_input.prompt // empty' 2>/dev/null) || brief_text=''
for brief_file in $(printf '%s\n' "$brief_text" | grep -Eo '/[^[:space:]"'"'"'`<>]+' |
    sed -E 's/[.,;:)]+$//' | sort -u); do
  real_brief=$(realpath "$brief_file" 2>/dev/null) || continue
  [ -f "$real_brief" ] && [ -r "$real_brief" ] || continue
  [ "$(wc -c <"$real_brief" | tr -d '[:space:]')" -le 1048576 ] || continue
  brief_text="$brief_text"$'\n'"$(cat "$real_brief")"
done
run_id_re='[0-9]{8}T[0-9]{6}Z-[0-9a-f]+(-[0-9]+)?'
# One command-span regex keeps the flag with the `fixes <id>` it belongs to: a brief that merely
# cites a run beside an unrelated --done is not a fixing pass, and a pass without the flag is none.
# review-bench's `fork --check` is the whole verdict (exit 3 names the command): no threshold
# is priced here.
fixing_pass_re="review-bench[[:blank:]]+fixes([[:blank:]]+[^[:blank:]]+)*"
fixing_segments=$(printf '%s\n' "$brief_text" |
  awk '{
    line = continued $0
    if (line ~ /\\[[:blank:]]*$/) {
      sub(/\\[[:blank:]]*$/, "", line)
      continued = line " "
      next
    }
    continued = ""
    gsub(/[;|&`]/, "\n", line)
    gsub(/review-bench/, "\nreview-bench", line)
    print line
  }
  END { if (continued != "") print continued }')
for fork_run in $(printf '%s\n' "$fixing_segments" | grep -Eo "$fixing_pass_re" |
    grep -E -- '(^|[[:blank:]])--(done|blocked)([[:blank:]]|$)' |
    grep -Eo "$run_id_re" | sort -u); do
  fork_refusal=$(review-bench fork "$fork_run" --check 2>&1 >/dev/null)
  [ "$?" -eq 3 ] || continue
  deny "REVIEW GATE: $fork_refusal"
done

# 0 = deny or re-arm, 1 = pass the retry, 2 = cache error.
claim_once() {
  local hash stamp now born age
  hash=$(printf '%s\n%s\n' "$1" "$sid" | shasum -a 256 | cut -c1-16)
  [[ "$hash" =~ ^[0-9a-f]{16}$ ]] || return 2
  mkdir -p "$STAMP_DIR" 2>/dev/null || return 2
  # The sweep is housekeeping: a hiccup in it (a racer already collected an entry) must not
  # become a cache-error verdict that waves the spawn through.
  find "$STAMP_DIR" -mindepth 1 -maxdepth 1 -type f \
    -name 'session-account-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].stamp' \
    -mmin +1440 -exec rm -f {} + 2>/dev/null

  stamp="$STAMP_DIR/session-account-$hash.stamp"
  (set -C; : >"$stamp") 2>/dev/null && return 0
  [ -f "$stamp" ] && [ ! -L "$stamp" ] || return 2
  now=$(date +%s 2>/dev/null) || return 2
  born=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null) || return 2
  case "$now$born" in *[!0-9]*) return 2 ;; esac
  age=$((now - born))
  # Duplicate calls in one tool batch must not consume the deny retry.
  [ "$age" -ge 2 ] || return 0
  rm "$stamp" 2>/dev/null && return 1
  if [ -e "$stamp" ]; then
    # A stamp that reappeared this young was re-armed by a racer that lost the same rm: that
    # claim is a deny, not a cache fault to warn-and-allow over.
    born=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null) || return 2
    case "$born" in ''|*[!0-9]*) return 2 ;; esac
    [ $((now - born)) -lt 2 ] && return 0
    return 2
  fi
  (set -C; : >"$stamp") 2>/dev/null && return 0
  [ -f "$stamp" ] && [ ! -L "$stamp" ] && return 0
  return 2
}

# Every assistant record carries the model, so the tail only has to reach the last one; 200
# lines clears the longest stretch of tool traffic. Unreadable or model-less transcripts read
# as empty and the caller stays silent — a gate that cannot tell must not block ordinary work.
session_model() {
  local transcript
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || return 0
  [ -r "$transcript" ] || return 0
  # -R with fromjson? so a truncated or non-object line is skipped instead of ending the scan.
  tail -n 200 "$transcript" 2>/dev/null | jq -rR '
    fromjson? | select(type == "object" and .type == "assistant")
    | .message | objects | .model // empty' 2>/dev/null | tail -n 1
}

case "$worker" in
  claudeb-worker|codex-worker|gemini-worker|sonnet-worker) ;;
  # A fork always inherits the parent model; the override field is ignored for it.
  fork) exit 0 ;;
  *)
    # A plain agent with a model override runs on the SESSION account. On a Fable session
    # that is exactly what the worker pool exists to prevent, and it is the one spawn shape
    # no other gate sees. Everywhere else it is ordinary work, so this stays silent.
    model_override=$(printf '%s' "$input" | jq -r '.tool_input.model // empty' 2>/dev/null) || exit 0
    [ -n "$model_override" ] || exit 0
    current_session_model=$(session_model)
    case "$current_session_model" in claude-fable-*) ;; *) exit 0 ;; esac
    tool_fingerprint=$(printf '%s' "$input" | jq -cS '.tool_input' 2>/dev/null) ||
      warn "The session-account gate could not fingerprint this Agent call, so it is letting the spawn through unjudged. ${worker:-This agent} with model=${model_override} runs on the SESSION account — check that is what Egor asked for."
    # The session model belongs in the key: a stamp lives a day, and a chat that moved to Opus
    # and back must not find its earlier Fable deny already spent.
    claim_once "session-account:$current_session_model:$tool_fingerprint"
    case $? in
      1) exit 0 ;;
      2) warn "The session-account gate could not use its stamp cache at ${STAMP_DIR}, so it is letting this spawn through unjudged. ${worker:-This agent} with model=${model_override} runs on the SESSION account — check that is what Egor asked for." ;;
    esac
    deny "This spawns ${worker:-an agent} with model=${model_override} — a plain agent runs on the SESSION account, the one this Fable chat is living on. Route implementation through the worker the toggle selects (claudeb-, codex- or gemini-worker on an account from worker-pick). If Egor asked for this spawn on purpose, retry the identical call — it passes once."
    ;;
esac

pin=''
case "$worker" in
  claudeb-worker) pin_key=claudeb_profile; vendor=claudeb; limits_vendor=claude; label=Claude ;;
  codex-worker) pin_key=codex_profile; vendor=codex; limits_vendor=codex; label=Codex ;;
  gemini-worker) pin_key=gemini_profile; vendor=gemini; limits_vendor=gemini; label=Gemini ;;
  sonnet-worker) pin_key=''; vendor=sonnet; limits_vendor=''; label=Sonnet ;;
esac
[ -n "$pin_key" ] && [ -r "$TOGGLE" ] &&
  pin=$(sed -n "s/^${pin_key}=//p" "$TOGGLE" | head -1 | tr -d '[:space:]')

# The toggle names the implementation worker for every session, and reading it before each
# delegation is the one step of that rule a hook can take over. A mismatch is reported, never
# denied: Egor routes a single task to another vendor by voice, without touching the file.
toggle_note=''
toggle_worker=''
[ -r "$TOGGLE" ] && toggle_worker=$(sed -n 's/^worker=//p' "$TOGGLE" | head -1 | tr -d '[:space:]')
case "$toggle_worker" in
  sonnet|claudeb|codex|gemini)
    [ "$toggle_worker" = "$vendor" ] ||
      toggle_note="The worker toggle says worker=${toggle_worker}, this spawns ${worker}. Fine if the task called for it; otherwise the toggle is the default and ${toggle_worker}-worker is the one to use."
    ;;
esac

[ "$worker" = sonnet-worker ] && warn ""

prompt=$(printf '%s' "$input" | jq -r '.tool_input.prompt // empty' 2>/dev/null) || prompt=''
brief_account=$(printf '%s\n' "$prompt" |
  sed -nE 's/^ACCOUNT:[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]*$/\1/p' | head -n1)

router_account=''
router_rc=0
if [ ! -x "$WORKER_PICK" ]; then
  router_rc=127
else
  router_account=$("$WORKER_PICK" --account "$vendor" 2>/dev/null) || router_rc=$?
  [[ "$router_account" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    [ "$router_rc" -ne 0 ] || router_rc=2
    router_account=''
  }
fi

if [ "$router_rc" -eq 3 ]; then
  deny "worker-pick found no selectable ${label} account. Do not spawn ${worker} until an account becomes selectable."
fi

# One definition for both callers: the wall check (account_pressure) and the
# inventory note must never disagree on what an account's effective pct is.
eff_defs='
  def epoch:
    if type == "number" then .
    elif type == "string" then
      (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})?$") // null |
       if . == null then null
       else (.d + "Z" | fromdateiso8601) -
         (if .tz == null or .tz == "Z" then 0
          else (.tz | capture("^(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$") |
                (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60)) end)
       end)
    else null end;
  def eff($bucket; $name):
    ($bucket // {}) as $b | (($b.resets_at // null) | epoch) as $reset |
    # Invariant n (llm-legs docs/shared-invariants.md): a weekly bucket stamped origin "headers"
    # carries no real percentage and must read as unknown, never as a number.
    if $name == "weekly" and $b.origin == "headers" then null
    elif $b.expired == true then 0
    elif $reset != null and $reset <= $now then 0
    elif (($b.effective_pct // null) | type) == "number" then $b.effective_pct
    elif (($b.used_pct // null) | type) == "number" then $b.used_pct
    else null end;
'

account_pressure() {
  [ -r "$LIMITS_FILE" ] || return 0
  jq -r --arg vendor "$1" --arg account "$2" --argjson now "$(date +%s)" "$eff_defs"'
    (.vendors[$vendor] // {}) as $v |
    (if (($v.accounts // []) | length) > 0 then $v.accounts
     else [{account:"main", five_hour:($v.five_hour // {}), weekly:($v.weekly // {})}] end) |
    first(.[] | select((.account // "main") == $account)) as $row |
    if $row == null then empty
    else ([eff($row.five_hour; "five_hour"), eff($row.weekly; "weekly")] |
      map(select(type == "number")) | if length > 0 then max else empty end)
    end
  ' "$LIMITS_FILE" 2>/dev/null
}

account_inventory() {
  [ -r "$LIMITS_FILE" ] || return 0
  jq -r --arg vendor "$1" --argjson now "$(date +%s)" "$eff_defs"'
    (.vendors[$vendor] // {}) as $v |
    (if (($v.accounts // []) | length) > 0 then $v.accounts
     else [{account:"main", enabled:$v.enabled, auth_needed:$v.auth_needed, auth:$v.auth,
            five_hour:($v.five_hour // {}), weekly:($v.weekly // {})}] end) |
    map(select(.removed != true)) |
    map({
      name:(.account // "main"),
      off:(.enabled == false),
      # A logged-out account reads 0% and would sort as the freest pick; the marker
      # keeps the orchestrator from routing at a dead entry. Negated worker-pick
      # auth_ok, kept in its exact shape: a bare `.auth.status? != "ok"` drops
      # string-auth accounts (empty propagates) and brands "unknown" as dead.
      auth:(.auth_needed == true or ((.auth.status? // "ok") | IN("expired", "failed"))),
      value:([eff(.five_hour; "five_hour"), eff(.weekly; "weekly")] |
             map(select(type == "number")) | if length > 0 then max else null end)
    }) |
    sort_by([(if .off or .auth then 1 else 0 end), (if .value == null then 1 else 0 end), (.value // 0)]) |
    map("\(.name) \(.value // "?")%\(if .off then " off" else "" end)\(if .auth then " auth!" else "" end)") | join(", ")
  ' "$LIMITS_FILE" 2>/dev/null
}

spawn_account=$brief_account
if [ -z "$spawn_account" ]; then
  if [ "$router_rc" -eq 0 ]; then
    spawn_account=$router_account
  else
    spawn_account=$pin
    [ -n "$spawn_account" ] || [ "$vendor" = claudeb ] || spawn_account=main
  fi
fi

unknown_note=''
if [ -n "$spawn_account" ]; then
  pressure=$(account_pressure "$limits_vendor" "$spawn_account")
  if [ -n "$pressure" ] && jq -ne --argjson pct "$pressure" '$pct >= 100' >/dev/null; then
    deny "${label} account ${spawn_account} is at effective ${pressure}% — 100% is a hard wall, so ${worker} cannot spawn."
  fi
  # No reading is not 0%: an unreadable limits file and an account at rest are the same emptiness
  # here, and the wall above cannot fire on either. The spawn still goes through — a gate that
  # cannot tell must not block work — but not as though headroom had been confirmed.
  [ -n "$pressure" ] ||
    unknown_note="${label} account ${spawn_account} has no usage reading (limit data absent, unreadable, or without that account's row), so the 100% wall could not be checked: confirm with llm-limits --table --no-write before treating it as having headroom."
else
  pressure=''
fi

if [ "$router_rc" -eq 0 ]; then
  # One combined message: warn() exits, so separate calls would shadow each other.
  note=''
  if [ "$spawn_account" != "$router_account" ]; then
    note="The brief names ${spawn_account}, while worker-pick would use ${router_account} for ${vendor}. Allowing the explicit account; the router recommendation for this task is ${router_account}."
  fi
  if [ -n "$pressure" ] && jq -ne --argjson pct "$pressure" --argjson warn "$WARN_AT" '$pct >= $warn' >/dev/null; then
    pressure_note="${label} account ${spawn_account} is at ${pressure}% — close to the 100% hard wall."
    if [ -n "$note" ]; then note="$note $pressure_note"; else note="${label} account ${spawn_account} is at ${pressure}%. worker-pick selected it, so ${worker} is allowed, but the available window is close to the 100% hard wall."; fi
  fi
  if [ -n "$unknown_note" ]; then
    if [ -n "$note" ]; then note="$note $unknown_note"; else note="$unknown_note"; fi
  fi
  # Orchestrators quote whatever account list their context still holds, so every routed spawn
  # carries the live one back — this is why a plain allow is no longer silent.
  inventory=$(account_inventory "$limits_vendor")
  if [ -n "$inventory" ]; then
    inventory_note="${label} accounts: ${inventory}; worker-pick selects ${router_account}."
    if [ -n "$note" ]; then note="$note $inventory_note"; else note="$inventory_note"; fi
  fi
  warn "$note"
fi

case "$router_rc" in
  127) fallback_reason="worker-pick is missing or not executable" ;;
  2) fallback_reason="worker-pick rejected the account query (exit 2)" ;;
  *) fallback_reason="worker-pick failed (exit ${router_rc})" ;;
esac

# If the router cannot answer, the legacy thresholds remain the protective fallback.
if [ ! -r "$LIMITS_FILE" ]; then
  warn "${fallback_reason}; fell back to local thresholds, but limit data is absent or unreadable. Allowing ${worker} with no threshold verdict."
fi

now=$(date +%s) ||
  deny "${fallback_reason}; local threshold fallback could not read the clock. Do not spawn ${worker}."
decision=$(jq -c --arg worker "$worker" --arg pin "$spawn_account" --argjson now "$now" --argjson warn "$WARN_AT" --argjson deny "$DENY_AT" "$eff_defs"'
  # Protective fallback, so stricter than worker-pick auth_ok: any status other than
  # "ok" and any non-object .auth shape is dead. Explicit branches — `.auth.status?`
  # on a string yields jq empty, which would either vanish the account or default it
  # to authorized depending on the surrounding operator.
  def auth_ok:
    .auth_needed != true and
    (if .auth == null then true
     elif (.auth | type) == "object" then ((.auth.status // "ok") == "ok")
     else false end);
  def specs:
    {
      "claudeb-worker": {
        vendor:"claude", shape:"accounts", buckets:["five_hour"], enabled:true, auth:true,
        available:false, group:null, stale:true, missing:100, empty:"deny"
      },
      "codex-worker": {
        vendor:"codex", shape:"accounts_or_vendor", buckets:["five_hour","weekly"], enabled:false, auth:false,
        available:true, group:null, stale:false, missing:0, empty:"allow"
      },
      # available stays false for Gemini on purpose: the collector clears both `available` and the
      # vendor-level `group` exactly when no account is usable (every bucket at 100%), so trusting
      # them here would turn full exhaustion into a silent allow. Judge the accounts themselves.
      "gemini-worker": {
        vendor:"gemini", shape:"accounts_or_vendor", buckets:["five_hour","weekly"], enabled:false, auth:true,
        available:false, group:"gemini", stale:true, missing:0, empty:"allow"
      }
    }[$worker];
  specs as $spec |
  (.vendors[$spec.vendor] // {}) as $vendor |
  if $spec.available and $vendor.available != true then {decision:"noop"}
  else
    (if $spec.shape == "accounts" then ($vendor.accounts // [])
     else
       if (($vendor.accounts // []) | length) > 0 then $vendor.accounts
       else [{account:"main", group:($vendor.group // null), auth_needed:$vendor.auth_needed,
              auth:$vendor.auth, five_hour:($vendor.five_hour // {}), weekly:($vendor.weekly // {})}] end
     end) as $all |
    (if $pin != "" and any($all[]; (.account // "") == $pin)
     then [$all[] | select((.account // "") == $pin)] else $all end) as $accounts |
    (($vendor.as_of // $vendor.fetched_at // .fetched_at // null) | epoch) as $fetched |
    if $spec.stale and ($fetched == null or ($now - $fetched) > 7200) then {decision:"stale"}
    else
      ([$accounts[] |
        . as $account |
        ([$spec.buckets[] as $bucket | eff($account[$bucket]; $bucket)] | map(select(type == "number"))) as $values |
        (($values | if length > 0 then max else $spec.missing end)) as $pressure |
        {
          name:(.account // "unknown"),
          pressure:$pressure,
          shown:$pressure,
          eligible:(.removed != true and .enabled != false
                    and (($spec.enabled | not) or .enabled == true)
                    and (($spec.auth | not) or (. | auth_ok))
                    and ($spec.group == null
                         or (((.group // "") | ascii_downcase | contains($spec.group)))))
        }
      ]) as $rows |
      ($rows | map("\(.name) \(if (.shown | type) == "number" then .shown else "?" end)%") | join(", ")) as $summary |
      ($rows | map(select(.eligible and (.pressure | type) == "number")) | map(.pressure)) as $pressures |
      if ($pressures | length) == 0 then
        if $spec.empty == "deny" then {decision:"deny",summary:$summary,best:null}
        else {decision:"noop"} end
      else ($pressures | min) as $best |
        if $best >= $deny then {decision:"deny",summary:$summary,best:$best}
        elif $best >= $warn then {decision:"warn",summary:$summary,best:$best}
        else {decision:"allow"} end
      end
    end
  end
' "$LIMITS_FILE" 2>/dev/null) ||
  deny "${fallback_reason}; local threshold fallback could not evaluate the limit data. Do not spawn ${worker}."

state=$(printf '%s' "$decision" | jq -r '.decision // empty' 2>/dev/null) ||
  deny "${fallback_reason}; local threshold fallback returned an invalid verdict. Do not spawn ${worker}."
case "$state" in
  stale|warn|deny|allow|noop) ;;
  *) deny "${fallback_reason}; local threshold fallback returned no verdict. Do not spawn ${worker}." ;;
esac
summary=$(printf '%s' "$decision" | jq -r '.summary // empty' 2>/dev/null) || summary=''
best=$(printf '%s' "$decision" | jq -r '.best // empty' 2>/dev/null) || best=''
fallback_prefix="${fallback_reason}; fell back to local thresholds. "

case "$worker:$state" in
  claudeb-worker:stale)
    warn "${fallback_prefix}Claude 5h limit data is stale or has no valid fetched_at timestamp — allowing claudeb-worker because stale data must not block delegation."
    ;;
  claudeb-worker:warn)
    warn "${fallback_prefix}Claude 5h window: ${summary} — no usable account below ${WARN_AT}%; allowing claudeb-worker, but the available window is close to the limit."
    ;;
  claudeb-worker:deny)
    deny "${fallback_prefix}Claude 5h window: ${summary} — no usable account below ${DENY_AT}%. Do not spawn claudeb-worker until an account becomes usable or its window resets."
    ;;
  codex-worker:warn)
    warn "${fallback_prefix}The freest Codex account is at ${best}% (${summary}). This codex-worker task may hit the wall mid-run; keep it small or be ready to reroute to a Claude worker."
    ;;
  codex-worker:deny)
    deny "${fallback_prefix}No Codex account below ${DENY_AT}% (${summary}) — do not spawn codex-worker now. Delegate this task to a Claude worker instead (owner rule: Fable agents while the Codex wall lasts), or wait for a reset."
    ;;
  gemini-worker:stale)
    warn "${fallback_prefix}Gemini limit data is stale or has no valid fetched_at timestamp — allowing gemini-worker because stale data must not block delegation."
    ;;
  gemini-worker:warn)
    warn "${fallback_prefix}The Gemini account is at ${best}% (${summary}). This gemini-worker task may hit the wall mid-run; keep it small or be ready to reroute according to worker-pick."
    ;;
  gemini-worker:deny)
    deny "${fallback_prefix}No Gemini account below ${DENY_AT}% (${summary}) — do not spawn gemini-worker now. Reroute according to worker-pick, or wait for a reset."
    ;;
  *:allow|*:noop)
    warn "${fallback_prefix}The local threshold check allows ${worker}."
    ;;
esac

exit 0
