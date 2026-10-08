#!/usr/bin/env bash
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

WARN_AT=85
DENY_AT=95
[ -z "${WORKER_GATE_WARN_PCT:-}" ] || WARN_AT="$WORKER_GATE_WARN_PCT"
[ -z "${WORKER_GATE_DENY_PCT:-}" ] || DENY_AT="$WORKER_GATE_DENY_PCT"
LIMITS_FILE="${LLM_LIMITS_FILE:-$HOME/.llm-limits.json}"
TOGGLE="${WORKER_PICK_CONFIG_FILE:-$HOME/.claude/worker-model}"
WORKER_PICK="${WORKER_GATE_WORKER_PICK:-/Volumes/Work/Projects/llm-legs/bin/worker-pick}"


input=$(cat) || exit 0
worker=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null) || exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null) || sid=''
[ -z "$sid" ] || export CLAUDE_CODE_SESSION_ID="$sid"

# Carries $toggle_note, so a vendor that disagrees with the toggle is reported without
# stealing the exit from a limit verdict that matters more. `warn ""` is the quiet path.
warn() {
  local msg=${1:-}
  if [ -n "${toggle_note:-}" ]; then
    if [ -n "$msg" ]; then msg="${toggle_note} ${msg}"; else msg="$toggle_note"; fi
  fi
  [ -n "$msg" ] || exit 0
  jq -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null || true
  exit 0
}

deny() {
  jq -cn --arg hook "${0##*/}" --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("[" + $hook + "] " + $r)}}' 2>/dev/null || true
  exit 0
}

prompt=$(printf '%s' "$input" | jq -r '.tool_input.prompt // empty' 2>/dev/null) || prompt=''

case "$worker" in
  claudeb-worker|codex-worker|gemini-worker|grok-worker|light-worker) ;;
  # Which native types may spawn at all is worker-spawn-hook.sh's decision alone; a deny here would
  # outrank its allow.
  *) exit 0 ;;
esac

pin=''
pin_key=''
# `spec_worker` is the row of the threshold table below this spawn is priced against, and
# `role_arg` the picker role it is routed under: the worker's own name and `workers` for the four
# vendor relays, the RESOLVED vendor and `light` for light-worker.
spec_worker=$worker
role_arg=workers
case "$worker" in
  claudeb-worker) pin_key=claudeb_profile; vendor=claudeb; limits_vendor=claude; label=Claude ;;
  codex-worker) pin_key=codex_profile; vendor=codex; limits_vendor=codex; label=Codex ;;
  gemini-worker) pin_key=gemini_profile; vendor=gemini; limits_vendor=gemini; label=Gemini ;;
  grok-worker) pin_key=grok_profile; vendor=grok; limits_vendor=grok; label=Grok ;;
esac
_load_wm() {
  command -v worker_model_pin_first >/dev/null 2>&1 && return 0
  local path=${BASH_SOURCE[0]} dir
  while [ -L "$path" ]; do
    dir=$(cd -P "$(dirname "$path")" && pwd) || return 1
    path=$(readlink "$path")
    [[ "$path" = /* ]] || path="$dir/$path"
  done
  dir=$(cd -P "$(dirname "$path")" && pwd) || return 1
  . "$dir/../share/worker-model.sh" 2>/dev/null
}
if [ "$worker" = light-worker ]; then
  # An unreadable or unlisted `light_edit` row is worker-run's own MODEL_REFUSED to word, before
  # an account is spent; a gate that guessed a vendor here would price the wrong quota.
  _load_wm || exit 0
  ! worker_light_off || exit 0
  vendor=$(worker_light_vendor edit 2>/dev/null) || exit 0
  case "$vendor" in
    claudeb) limits_vendor=claude; label='Light on Claude' ;;
    codex) limits_vendor=codex; label='Light on Codex' ;;
    gemini) limits_vendor=gemini; label='Light on Gemini' ;;
    grok) limits_vendor=grok; label='Light on Grok' ;;
    *) exit 0 ;;
  esac
  spec_worker="${vendor}-worker"
  role_arg=light
  pin_key="${vendor}_profile"
fi
[ -z "$pin_key" ] || _load_wm || true

# The toggle names the implementation worker for every session, and reading it before each
# delegation is the one step of that rule a hook can take over. A mismatch is reported, never
# denied: Egor routes a single task to another vendor by voice, without touching the file.
toggle_note=''
toggle_worker=''
[ -r "$TOGGLE" ] && toggle_worker=$(sed -n 's/^worker=//p' "$TOGGLE" | head -1 | tr -d '[:space:]')
case "$toggle_worker" in
  claudeb|codex|gemini|grok)
    # The Light leg is selected by the `light_edit` row and never by `worker=`, so a mismatch here
    # would advise a switch that changes nothing about where this spawn lands.
    if [ "$worker" != light-worker ] && [ "$toggle_worker" != "$vendor" ]; then
      toggle_note="The worker toggle says worker=${toggle_worker}, this spawns ${worker}. Fine if the task called for it; otherwise the toggle is the default and ${toggle_worker}-worker is the one to use."
    fi
    ;;
esac

if [ "$worker" = codex-worker ] && grep -Eq '^COMPUTER:[[:space:]]*yes[[:space:]]*$' <<<"$prompt"; then
  role_arg=computer
  toggle_note=''
fi

# An `ATTACH <run-id>:` relay opens no window: the run is already in flight on an account it is
# already spending, and this spawn only waits on it. Priced like a fresh launch it becomes
# unreachable exactly when a run matters most — the account it is on walls mid-run, every deny
# below fires, and the launch gate denies the Bash wait that would be the only way back to it.
#
# Which is why the prefix is CHECKED and not believed: it exits before every pressure verdict
# below, so a brief that merely opens with those words would be a way past all of them. The run
# directory worker-run keeps is the proof — it exists while the run does, and gains `exit_code`
# when the run ends, and a spawn naming neither is a fresh launch spelled as a re-attach and is
# priced as one.
attach_run=$(printf '%s\n' "$prompt" | head -n1 |
  sed -nE 's/^ATTACH[[:space:]]+([a-z0-9][a-z0-9-]*):.*/\1/p')
if [ -n "$attach_run" ]; then
  attach_dir="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}/$attach_run"
  if [ -d "$attach_dir" ] && [ ! -e "$attach_dir/exit_code" ]; then
    toggle_note=''
    warn ''
  fi
fi

brief_account=$(printf '%s\n' "$prompt" |
  sed -nE 's/^ACCOUNT:[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]*$/\1/p' | head -n1)

router_account=''
router_rc=0
if [ ! -x "$WORKER_PICK" ]; then
  router_rc=127
else
  if [ "$role_arg" = workers ]; then
    router_account=$("$WORKER_PICK" --account "$vendor" 2>/dev/null) || router_rc=$?
  else
    router_account=$("$WORKER_PICK" --account "$vendor" --role "$role_arg" 2>/dev/null) || router_rc=$?
  fi
  [[ "$router_account" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    [ "$router_rc" -ne 0 ] || router_rc=2
    router_account=''
  }
fi

if [ "$router_rc" -eq 3 ]; then
  deny "worker-pick found no selectable ${label} account. Do not spawn ${worker} until an account becomes selectable."
fi

# One definition for every reader below: the wall check (account_pressure) and the fallback
# decision must never disagree on what an account's effective pct is.
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
  def vendor_rows($vendor):
    (.vendors[$vendor] // {}) as $v |
    if (($v.accounts // []) | length) > 0 then $v.accounts else [$v + {account:"main"}] end;
'

account_pressure() {
  [ -r "$LIMITS_FILE" ] || return 0
  jq -r --arg vendor "$1" --arg account "$2" --argjson now "$(date +%s)" "$eff_defs"'
    vendor_rows($vendor) |
    first(.[] | select((.account // "main") == $account)) as $row |
    if $row == null then empty
    else ([eff($row.five_hour; "five_hour"), eff($row.weekly; "weekly")] |
      map(select(type == "number")) | if length > 0 then max else empty end)
    end
  ' "$LIMITS_FILE" 2>/dev/null
}

# An ACCOUNT line routes one task past worker-pick, never onto an account Egor switched off or removed
# in the menu: the wall below reads only percentages.
account_off() { # vendor limits_vendor account
  if _load_wm && command -v worker_pool_refuse_headless >/dev/null 2>&1 &&
    ! worker_pool_refuse_headless "$1" "$3" "$(worker_model_pin_csv < <(worker_model_pins "$1" 2>/dev/null))" 2>/dev/null; then
    return 0
  fi
  [ -r "$LIMITS_FILE" ] || return 1
  jq -e --arg vendor "$2" --arg account "$3" "$eff_defs"'
    any(vendor_rows($vendor)[]; (.account // "main") == $account and .removed == true)
  ' "$LIMITS_FILE" >/dev/null 2>&1
}
if [ -n "$brief_account" ] && account_off "$vendor" "$limits_vendor" "$brief_account"; then
  deny "The brief's ACCOUNT: ${brief_account} is switched off or removed in Egor's menu, so ${worker} cannot spawn on it. Put worker-pick's NEXT account${router_account:+ (${router_account})} in the ACCOUNT line, or drop the line."
fi

spawn_account=$brief_account
if [ -z "$spawn_account" ]; then
  if [ "$router_rc" -eq 0 ]; then
    spawn_account=$router_account
  else
    [ -z "$pin_key" ] || pin=$(worker_model_pin_first "$vendor" 2>/dev/null || true)
    spawn_account=$pin
    # claudeb and grok have no main account to name: claudeb keeps none, and grok's is the real
    # ~/.grok, which carries no login.
    case "$vendor" in claudeb|grok) ;; *) [ -n "$spawn_account" ] || spawn_account=main ;; esac
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
    note="ACCOUNT ${spawn_account} ≠ worker-pick ${router_account} (allowed)."
  fi
  if [ -n "$pressure" ] && jq -ne --argjson pct "$pressure" --argjson warn "$WARN_AT" '$pct >= $warn' >/dev/null; then
    pressure_note="${label} account ${spawn_account} is at ${pressure}% — close to the 100% hard wall."
    if [ -n "$note" ]; then note="$note $pressure_note"; else note="${label} account ${spawn_account} is at ${pressure}%. worker-pick selected it, so ${worker} is allowed, but the available window is close to the 100% hard wall."; fi
  fi
  if [ -n "$unknown_note" ]; then
    if [ -n "$note" ]; then note="$note $unknown_note"; else note="$unknown_note"; fi
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
decision=$(jq -c --arg worker "$spec_worker" --arg pin "$spawn_account" --argjson now "$now" --argjson warn "$WARN_AT" --argjson deny "$DENY_AT" "$eff_defs"'
  # Protective fallback, so stricter than worker-pick auth_ok: any status outside the live set the
  # vendor spec names, and any non-object .auth shape, is dead. Explicit branches — `.auth.status?`
  # on a string yields jq empty, which would either vanish the account or default it
  # to authorized depending on the surrounding operator.
  def auth_ok($live):
    .auth_needed != true and
    (if .auth == null then true
     elif (.auth | type) == "object" then ((.auth.status // "ok") | IN($live[]))
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
      },
      # Weekly is the only bucket grok measures, and its accounts carry an auth status of their own.
      # `available` is judged per account for the same reason as Gemini above: a vendor-level flag
      # cleared by full exhaustion would read as a silent allow. `expired` is live for this vendor
      # (the CLI refreshes the token itself); dropped here, a roster of expired-but-free accounts
      # would deny the worker over the one signed-in row worker-pick would have skipped.
      "grok-worker": {
        vendor:"grok", shape:"accounts_or_vendor", buckets:["weekly"], enabled:false, auth:true,
        auth_live:["ok","expired"],
        available:false, group:null, stale:false, missing:0, empty:"allow"
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
                    and (($spec.auth | not) or (. | auth_ok($spec.auth_live // ["ok"])))
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

case "$spec_worker:$state" in
  claudeb-worker:stale)
    warn "${fallback_prefix}Claude 5h limit data is stale or has no valid fetched_at timestamp — allowing ${worker} because stale data must not block delegation."
    ;;
  claudeb-worker:warn)
    warn "${fallback_prefix}Claude 5h window: ${summary} — no usable account below ${WARN_AT}%; allowing ${worker}, but the available window is close to the limit."
    ;;
  claudeb-worker:deny)
    deny "${fallback_prefix}Claude 5h window: ${summary} — no usable account below ${DENY_AT}%. Do not spawn ${worker} until an account becomes usable or its window resets."
    ;;
  codex-worker:warn)
    warn "${fallback_prefix}The freest Codex account is at ${best}% (${summary}). This ${worker} task may hit the wall mid-run; keep it small or be ready to reroute to a Claude worker."
    ;;
  codex-worker:deny)
    deny "${fallback_prefix}No Codex account below ${DENY_AT}% (${summary}) — do not spawn ${worker} now. Delegate this task to a Claude worker instead (owner rule: Fable agents while the Codex wall lasts), or wait for a reset."
    ;;
  gemini-worker:stale)
    warn "${fallback_prefix}Gemini limit data is stale or has no valid fetched_at timestamp — allowing ${worker} because stale data must not block delegation."
    ;;
  gemini-worker:warn)
    warn "${fallback_prefix}The Gemini account is at ${best}% (${summary}). This ${worker} task may hit the wall mid-run; keep it small or be ready to reroute according to worker-pick."
    ;;
  gemini-worker:deny)
    deny "${fallback_prefix}No Gemini account below ${DENY_AT}% (${summary}) — do not spawn ${worker} now. Reroute according to worker-pick, or wait for a reset."
    ;;
  grok-worker:warn)
    warn "${fallback_prefix}The freest Grok account is at ${best}% of its weekly window (${summary}). This ${worker} task may hit the wall mid-run; keep it small or be ready to reroute according to worker-pick."
    ;;
  grok-worker:deny)
    deny "${fallback_prefix}No Grok account below ${DENY_AT}% of its weekly window (${summary}) — do not spawn ${worker} now. Reroute according to worker-pick, or wait for the weekly reset."
    ;;
  *:allow|*:noop)
    warn "${fallback_prefix}The local threshold check allows ${worker}."
    ;;
esac

exit 0
exit; }
