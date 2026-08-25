#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/llm-refresh"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); }

STUB="$WORK/collector"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "$#" -eq 0 ]; then
  printf '<bare>\n' >>"$STUB_LOG"
  exit "${STUB_PASSIVE_RC:-0}"
fi
[ "${1:-}" = --refresh-account ] || exit 2
target=${2:-}
printf '%s\n' "$*" >>"$STUB_LOG"
vendor=${target%%/*}
account=${target#*/}
if [ "${STUB_PUSHBACK_TARGET:-}" = "$target" ]; then
  tmp=$(mktemp "${LLM_LIMITS_CACHE}.tmp.XXXXXX") || exit 5
  jq --arg vendor "$vendor" --argjson now "$LLM_REFRESH_NOW" \
    '.vendors[$vendor].refresh_error={cause:"HTTP 429 rate limit",at:$now}' \
    "$LLM_LIMITS_CACHE" >"$tmp" && mv -f "$tmp" "$LLM_LIMITS_CACHE"
  exit 0
fi
if [ "${STUB_REFRESH_SUCCEED:-1}" = 1 ]; then
  tmp=$(mktemp "${LLM_LIMITS_CACHE}.tmp.XXXXXX") || exit 5
  jq --arg vendor "$vendor" --arg account "$account" --argjson now "$LLM_REFRESH_NOW" '
    .vendors[$vendor].accounts |= map(
      if .account == $account then
        .five_hour.as_of=$now | .weekly.as_of=$now | del(.refresh_error)
      else . end) |
    .vendors[$vendor] |= del(.refresh_error)' "$LLM_LIMITS_CACHE" >"$tmp" && \
    mv -f "$tmp" "$LLM_LIMITS_CACHE"
fi
EOF
chmod +x "$STUB"

# Stands in for `claudeb revive` AND for the collect that follows it: the daemon reads the
# rows llm-limits.sh computed, so what a session rotated reaches it here.
CB_STUB="$WORK/claudeb"
cat >"$CB_STUB" <<'EOF'
#!/usr/bin/env bash
set -u
# Answered before any logging: the tick asks it about every stale account, and a token verdict
# is not an attempt at anything, so the argv assertions below stay whole-file comparisons.
if [ "${1:-}" = token-fresh ]; then
  case " ${CB_TOKEN_FRESH:-} " in *" ${2:-} "*) exit 0 ;; esac
  exit 1
fi
printf '%s\n' "$*" >>"$CB_LOG"
# Kept out of CB_LOG so the argv assertions stay whole-file comparisons.
if [ -d "${LLM_REFRESH_STATE}.lock" ]; then printf 'lock-held\n' >>"${CB_ENV:-/dev/null}"
else printf 'lock-free\n' >>"${CB_ENV:-/dev/null}"; fi
printf 'announce-suppress=%s\n' "${LLM_LIMITS_ANNOUNCE_SUPPRESS:-}" >>"${CB_ENV:-/dev/null}"
[ "${1:-}" = revive ] || exit 2
account=${2:-}
restate() {
  tmp=$(mktemp "${LLM_LIMITS_CACHE}.tmp.XXXXXX") || exit 5
  jq --arg account "$account" --argjson now "$LLM_REFRESH_NOW" "$1" "$LLM_LIMITS_CACHE" >"$tmp" && \
    mv -f "$tmp" "$LLM_LIMITS_CACHE"
}
case "${CB_RESULT:-ok}" in
  ok)
    restate '.vendors.claude.accounts |= map(if .account == $account then
               .five_hour.as_of=$now | .weekly.as_of=$now else . end)'
    ;;
  login)
    restate '.vendors.claude.accounts |= map(if .account == $account then
               .auth_needed=true else . end)'
    printf 'claudeb: revive: %s needs a human login\n' "$account" >&2
    exit 4
    ;;
  pushback)
    printf 'claudeb: revive failed account=%s cause=warm-429 http=429\n' "$account" >&2
    exit 5
    ;;
  fail)
    printf 'claudeb: revive: %s: session driver failed (exit 5)\n' "$account" >&2
    exit 5
    ;;
  hang) sleep 30 ;;
  peek)
    # Stands in for a concurrent tick: it reads the state file the running session left behind
    # and writes its own change into it while the lock is out.
    printf 'stamp=%s\n' "$(jq -r --arg a "$account" '.claude.attempts[$a] // "none"' "$LLM_REFRESH_STATE")" \
      >>"${CB_ENV:-/dev/null}"
    tmp=$(mktemp "${LLM_REFRESH_STATE}.other.XXXXXX") || exit 5
    jq -c '.codex.interval_min=60' "$LLM_REFRESH_STATE" >"$tmp" && mv -f "$tmp" "$LLM_REFRESH_STATE"
    ;;
  steal)
    # Another tick claimed the lock while this session was out; its owner is alive.
    mkdir -p "${LLM_REFRESH_STATE}.lock"
    printf '%s\n' "${CB_STEAL_PID:-$$}" >"${LLM_REFRESH_STATE}.lock/pid"
    ;;
esac
EOF
chmod +x "$CB_STUB"

write_store() {
  local path=$1 now=$2 claude_age=$3 codex_age=$4 gemini_age=$5
  jq -cn --argjson now "$now" --argjson ca "$claude_age" --argjson coa "$codex_age" \
    --argjson ga "$gemini_age" '
    def row($name;$age):
      {account:$name,five_hour:{used_pct:10,as_of:($now-$age)},
       weekly:{used_pct:20,as_of:($now-$age)}};
    {schema:1,vendors:{
      claude:{available:true,accounts:[row("alpha";$ca)]},
      codex:{available:true,accounts:[row("beta";$coa)]},
      gemini:{available:true,accounts:[row("gamma";$ga)]}
    }}' >"$path"
}

write_state() {
  local path=$1 claude=$2 codex=$3 gemini=$4 last=$5 clean=$6
  jq -cn --argjson claude "$claude" --argjson codex "$codex" --argjson gemini "$gemini" \
    --argjson last "$last" --argjson clean "$clean" '
    {vendors:{
      claude:{interval_min:$claude,last_attempt_epoch:$last,clean_since_epoch:$clean,attempts:{}},
      codex:{interval_min:$codex,last_attempt_epoch:$last,clean_since_epoch:$clean,attempts:{}},
      gemini:{interval_min:$gemini,last_attempt_epoch:$last,clean_since_epoch:$clean,attempts:{}}
    }}' >"$path"
}

# Stands in for opencode-go AND for the collect that follows it: the daemon reads the rows
# llm-limits.sh computed, never the wall record itself, so what a probe changed reaches it here.
OC_STUB="$WORK/opencode-go"
cat >"$OC_STUB" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s|%s\n' "${1:-}" "${OPENCODE_GO_PROFILE:-}" >>"$OC_LOG"
# The probe is a real completion against a gateway that can be wedged; holding the tick lock
# across it parks every other vendor's refresh behind this one.
[ ! -d "${LLM_REFRESH_STATE}.lock" ] || printf 'lock-held\n' >>"$OC_LOG"
profile=${OPENCODE_GO_PROFILE:--}
restate() { # <walled> <resets_at or null>
  tmp=$(mktemp "${LLM_LIMITS_CACHE}.tmp.XXXXXX") || exit 5
  jq -c --arg p "$profile" --argjson walled "$1" --argjson reset "$2" \
    '.vendors.opencode.accounts |= map(if .account == $p then
       {account:$p, walled:$walled,
        windows:(if $walled then [{window:"wk",resets_at:$reset}] else [] end)}
     else . end)' "$LLM_LIMITS_CACHE" >"$tmp" && mv -f "$tmp" "$LLM_LIMITS_CACHE"
}
case "${OC_STUB_RESULT:-clear}" in
  clear)
    restate false null
    printf 'served — the plan answered a completion; the wall is retired\n'
    ;;
  dormant)
    printf 'dormant — no wall stands on %s, so nothing was sent\n' "$profile"
    ;;
  walled)
    restate true "\"$(date -u -r "$(( $(date +%s) + 3 * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')\""
    printf 'walled — weekly, resets in 3 days\n'
    ;;
  *)
    printf 'inconclusive — the provider is down\n' >&2
    exit 1
    ;;
esac
EOF
chmod +x "$OC_STUB"

seed_opencode_wall() {
  local path=$1 profile=$2 reset=$3 tmp
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  jq -c --arg p "$profile" --arg reset "$reset" \
    '.vendors.opencode = {source:"opencode-go",
      accounts:[{account:$p,walled:true,windows:[{window:"wk",resets_at:$reset}]}]}' \
    "$path" >"$tmp" && mv -f "$tmp" "$path"
}

standing_opencode_walls() {
  jq -c '[.vendors.opencode.accounts[]? | select(.walled == true)]' "$1/store.json"
}

run_refresh() {
  local dir=$1 now=$2
  env HOME="$dir/home" LLM_REFRESH_COLLECTOR="$STUB" LLM_LIMITS_CACHE="$dir/store.json" \
    LLM_REFRESH_STATE="$dir/state.json" LLM_REFRESH_JOURNAL="$dir/journal.jsonl" \
    LLM_REFRESH_NOW="$now" STUB_LOG="$dir/calls.log" \
    LLM_LIMITS_REFRESH_OPENCODE_GO="$OC_STUB" OC_LOG="$dir/opencode.log" \
    OC_STUB_RESULT="${OC_STUB_RESULT:-clear}" \
    LLM_LIMITS_REFRESH_CLAUDEB="${CB_BIN:-$CB_STUB}" CB_LOG="$dir/claudeb.log" \
    CB_ENV="$dir/claudeb-env.log" \
    CB_RESULT="${CB_RESULT:-ok}" CB_STEAL_PID="${CB_STEAL_PID:-$$}" \
    CB_TOKEN_FRESH="${CB_TOKEN_FRESH:-}" \
    LLM_LIMITS_REFRESH_REVIVE_TIMEOUT="${LLM_LIMITS_REFRESH_REVIVE_TIMEOUT:-240}" \
    LLM_LIMITS_REFRESH_PROBE_TIMEOUT="${LLM_LIMITS_REFRESH_PROBE_TIMEOUT:-90}" \
    LLM_LIMITS_REFRESH_LOCK_STALE_SECONDS="${LLM_LIMITS_REFRESH_LOCK_STALE_SECONDS:-1800}" \
    STUB_PUSHBACK_TARGET="${STUB_PUSHBACK_TARGET:-}" STUB_REFRESH_SUCCEED="${STUB_REFRESH_SUCCEED:-1}" \
    STUB_PASSIVE_RC="${STUB_PASSIVE_RC:-0}" \
    bash "$SCRIPT"
}

NOW=2000000000

case_dir="$WORK/defaults"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 60 60
run_refresh "$case_dir" "$NOW" || fail 'first run failed'
jq -e --argjson now "$NOW" '
  all(.claude, .codex, .gemini; .interval_min == 30 and .last_attempt_epoch == $now and
      .clean_since_epoch == $now) and
  (.opencode | .interval_min == 45 and .last_attempt_epoch == $now)' \
  "$case_dir/state.json" >/dev/null || fail 'first run did not create default state'
[ "$(grep -c '^<bare>$' "$case_dir/calls.log")" -eq 1 ] || fail 'first run did not share one passive collect'
pass

case_dir="$WORK/stale-lock"
mkdir -p "$case_dir/home" "$case_dir/state.json.lock"
write_store "$case_dir/store.json" "$NOW" 60 60 60
touch -t 200001010000 "$case_dir/state.json.lock"
LLM_LIMITS_REFRESH_LOCK_STALE_SECONDS=1 run_refresh "$case_dir" "$NOW" || \
  fail 'stale-lock run failed'
[ -s "$case_dir/state.json" ] || fail 'stale lock blocked the tick'
[ -s "$case_dir/journal.jsonl" ] || fail 'stale lock prevented journaling'
[ ! -e "$case_dir/state.json.lock" ] || fail 'replacement lock was not released'
pass

case_dir="$WORK/fresh-lock"
mkdir -p "$case_dir/home" "$case_dir/state.json.lock"
write_store "$case_dir/store.json" "$NOW" 60 60 60
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
state_before=$(shasum -a 256 "$case_dir/state.json" | awk '{print $1}')
run_refresh "$case_dir" "$NOW" || fail 'fresh-lock skip failed'
[ "$(shasum -a 256 "$case_dir/state.json" | awk '{print $1}')" = "$state_before" ] || \
  fail 'fresh lock allowed state mutation'
[ ! -e "$case_dir/journal.jsonl" ] || fail 'fresh lock allowed journaling'
[ ! -e "$case_dir/calls.log" ] || fail 'fresh lock allowed collection'
[ -d "$case_dir/state.json.lock" ] || fail 'fresh lock was removed'
pass

case_dir="$WORK/gating"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 999999 60 60
write_state "$case_dir/state.json" 30 30 30 "$NOW" "$NOW"
jq '.vendors.codex.last_attempt_epoch=0 | .vendors.gemini.last_attempt_epoch=0' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
claude_before=$(jq -c '.vendors.claude' "$case_dir/state.json")
run_refresh "$case_dir" "$NOW" || fail 'interval-gating run failed'
[ "$(jq -c '.claude' "$case_dir/state.json")" = "$claude_before" ] || \
  fail 'not-due vendor state changed'
jq -eR 'fromjson | select(.vendor == "claude")' "$case_dir/journal.jsonl" >/dev/null 2>&1 && \
  fail 'not-due vendor was journaled'
pass

case_dir="$WORK/claude"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
run_refresh "$case_dir" "$NOW" || fail 'Claude stale run failed'
grep -q -- '--refresh-account' "$case_dir/calls.log" && \
  fail 'Claude was refreshed through the vendor-blocked token path'
[ "$(cat "$case_dir/claudeb.log")" = 'revive alpha' ] || \
  fail "the stale Claude account was not revived: $(cat "$case_dir/claudeb.log" 2>/dev/null)"
jq -eR 'fromjson | select(.vendor == "claude" and .step == 1 and
  .outcome == "refreshed" and .accounts_tried == ["alpha"])' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'Claude revive was not journaled as refreshed'
# An interactive session runs for minutes: the other vendors' tick must not queue behind it,
# and the tick's own collect replaces the announce revive would otherwise detach.
grep -qx 'lock-free' "$case_dir/claudeb-env.log" || \
  fail 'the tick held its lock across the revive session'
grep -qx 'announce-suppress=1' "$case_dir/claudeb-env.log" || \
  fail 'the heartbeat revive was left to fire its own second collect'
pass

# Gentleness: one interactive session per heartbeat tick, stalest first, and the rest wait —
# the next tick is what picks them up.
case_dir="$WORK/claude-one-per-tick"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
jq --argjson now "$NOW" '.vendors.claude.accounts += [{account:"zeta",
  five_hour:{used_pct:10,as_of:($now - 99999)},weekly:{used_pct:20,as_of:($now - 99999)}}]' \
  "$case_dir/store.json" >"$case_dir/store.tmp" && mv "$case_dir/store.tmp" "$case_dir/store.json"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
run_refresh "$case_dir" "$NOW" || fail 'one-per-tick run failed'
[ "$(cat "$case_dir/claudeb.log")" = 'revive zeta' ] || \
  fail "the tick did not drive exactly the stalest account: $(cat "$case_dir/claudeb.log")"
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "partial" and
  .accounts_tried == ["zeta"] and (.detail | test("still stale: alpha") and
  test("wait for the next tick")))' "$case_dir/journal.jsonl" >/dev/null || \
  fail 'the accounts left waiting are not named in the journal detail'
run_refresh "$case_dir" "$((NOW + 3600))" || fail 'second one-per-tick run failed'
[ "$(sed -n 2p "$case_dir/claudeb.log")" = 'revive alpha' ] || \
  fail 'the next tick did not move on to the account that waited'
pass

# A token that still carries a request needs no session: `claudeb revive` on it is one usage GET,
# so every such account is read in the SAME tick and only an expired token queues for the slot.
case_dir="$WORK/claude-direct-probes"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
jq --argjson now "$NOW" '.vendors.claude.accounts += [
  {account:"zeta",five_hour:{used_pct:10,as_of:($now - 7200)},weekly:{used_pct:20,as_of:($now - 7200)}},
  {account:"theta",five_hour:{used_pct:10,as_of:($now - 7200)},weekly:{used_pct:20,as_of:($now - 7200)}}]' \
  "$case_dir/store.json" >"$case_dir/store.tmp" && mv "$case_dir/store.tmp" "$case_dir/store.json"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
CB_TOKEN_FRESH="alpha zeta" run_refresh "$case_dir" "$NOW" || fail 'direct-probe run failed'
[ "$(tr '\n' ' ' <"$case_dir/claudeb.log")" = 'revive alpha revive zeta revive theta ' ] || \
  fail "the fresh-token accounts were not all read in one tick: $(tr '\n' ' ' <"$case_dir/claudeb.log")"
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "refreshed" and
  .accounts_tried == ["alpha","zeta","theta"] and (.detail | test("probed: alpha,zeta") and
  test("session: theta")))' "$case_dir/journal.jsonl" >/dev/null || \
  fail "the tick did not report what it probed and what it opened a session for: $(cat "$case_dir/journal.jsonl")"
# The attempts map rotates the ONE session slot; a probe that spends no session must not take a turn.
jq -e --argjson now "$NOW" '.claude.attempts == {theta:$now}' "$case_dir/state.json" >/dev/null || \
  fail "a direct probe stamped the session rotation: $(jq -c '.claude.attempts' "$case_dir/state.json")"
pass

# Worker-pool membership is spend consent: it says nothing about reading an account's usage,
# so a disabled account is refreshed like any other and is not `unrefreshable`.
case_dir="$WORK/claude-disabled-still-probed"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
jq --argjson now "$NOW" '.vendors.claude.accounts=[{account:"off1",enabled:false,
  five_hour:{used_pct:10,as_of:($now - 7200)},weekly:{used_pct:20,as_of:($now - 7200)}}]' \
  "$case_dir/store.json" >"$case_dir/store.tmp" && mv "$case_dir/store.tmp" "$case_dir/store.json"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
CB_TOKEN_FRESH="off1" run_refresh "$case_dir" "$NOW" || fail 'disabled-account run failed'
[ "$(cat "$case_dir/claudeb.log")" = 'revive off1' ] || \
  fail "an out-of-pool account was skipped by the refresh: $(cat "$case_dir/claudeb.log" 2>/dev/null)"
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "refreshed" and
  (.detail | test("probed: off1") and (test("unrefreshable") | not)))' \
  "$case_dir/journal.jsonl" >/dev/null || \
  fail "an out-of-pool account was journaled as unrefreshable: $(cat "$case_dir/journal.jsonl")"
pass

# The reserved names are unrefreshable whatever their token says: the split runs after they are
# dropped, so no probe may reach one either.
case_dir="$WORK/claude-reserved-not-probed"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
jq --argjson now "$NOW" '.vendors.claude.accounts += [{account:"main",
  five_hour:{used_pct:10,as_of:($now - 7200)},weekly:{used_pct:20,as_of:($now - 7200)}}]' \
  "$case_dir/store.json" >"$case_dir/store.tmp" && mv "$case_dir/store.tmp" "$case_dir/store.json"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
CB_TOKEN_FRESH="alpha main" run_refresh "$case_dir" "$NOW" || fail 'reserved-name probe run failed'
[ "$(cat "$case_dir/claudeb.log")" = 'revive alpha' ] || \
  fail "a reserved name was probed: $(cat "$case_dir/claudeb.log")"
jq -eR 'fromjson | select(.vendor == "claude" and (.detail | test("unrefreshable: main")))' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'a reserved name stopped being unrefreshable'
pass

# A failing revive leaves as_of untouched, so staleness alone would hand it every tick forever:
# the turn goes to whoever waited longest since their last attempt.
case_dir="$WORK/claude-failing-rotates"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
jq --argjson now "$NOW" '.vendors.claude.accounts += [{account:"zeta",
  five_hour:{used_pct:10,as_of:($now - 99999)},weekly:{used_pct:20,as_of:($now - 99999)}}]' \
  "$case_dir/store.json" >"$case_dir/store.tmp" && mv "$case_dir/store.tmp" "$case_dir/store.json"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now |
  .vendors.claude.attempts={ghost:1}' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
for offset in 0 3600 7200; do
  CB_RESULT=fail run_refresh "$case_dir" "$((NOW + offset))" || fail "failing-revive tick $offset failed"
done
[ "$(cut -d' ' -f2 <"$case_dir/claudeb.log" | tr '\n' ' ')" = 'zeta alpha zeta ' ] || \
  fail "a failing account was not rotated out of the way: $(tr '\n' ' ' <"$case_dir/claudeb.log")"
jq -e --argjson now "$NOW" '.claude.attempts.zeta == ($now + 7200) and .claude.attempts.alpha == ($now + 3600) and
  (.claude.attempts | has("ghost") | not)' "$case_dir/state.json" >/dev/null || \
  fail 'attempt stamps were not persisted per account, or a departed account still holds one'
pass

# Handing the lock back means it can be gone on return: the tick then drops its state write
# (the journal line is an append and lands either way), exactly like the opencode probe.
case_dir="$WORK/claude-lock-lost"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
# Claude must be the only vendor due: opencode hands the lock back too, and its own reacquire
# would set the same flag whatever the revive did.
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now |
  .vendors.opencode={interval_min:45,last_attempt_epoch:$now,clean_since_epoch:$now}' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
sleep 30 &
steal_pid=$!
CB_STEAL_PID=$steal_pid CB_RESULT=steal run_refresh "$case_dir" "$NOW" || fail 'lock-lost run failed'
kill "$steal_pid" 2>/dev/null
wait "$steal_pid" 2>/dev/null
# The mid-tick persist (the attempt stamp) is ours and lands before the lock goes; the
# end-of-tick write is what a tick without the lock must never do.
jq -e --argjson now "$NOW" '.claude.attempts.alpha == $now and .claude.last_attempt_epoch == 0' \
  "$case_dir/state.json" >/dev/null || \
  fail 'the tick wrote its cadence state without holding the lock, or lost the attempt stamp'
jq -eR 'fromjson | select(.vendor == "claude" and .accounts_tried == ["alpha"])' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'the attempt went unjournaled after the lock was lost'
rm -rf "$case_dir/state.json.lock"
pass

# The lock is out for minutes, so the stamp has to be ON DISK before it goes — otherwise the
# next tick picks the same account — and whatever the other tick wrote meanwhile must survive.
case_dir="$WORK/claude-concurrent-tick"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now |
  .vendors.opencode={interval_min:45,last_attempt_epoch:$now,clean_since_epoch:$now}' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
CB_RESULT=peek run_refresh "$case_dir" "$NOW" || fail 'concurrent-tick run failed'
grep -qx "stamp=$NOW" "$case_dir/claudeb-env.log" || \
  fail "the attempt stamp was not on disk while the session ran: $(cat "$case_dir/claudeb-env.log")"
jq -e --argjson now "$NOW" '.codex.interval_min == 60 and .claude.attempts.alpha == $now' \
  "$case_dir/state.json" >/dev/null || \
  fail 'the tick restored its pre-revive snapshot over a concurrent write'
pass

# Losing the lock mid-tick stops the tick: the vendors behind Claude belong to the new owner.
case_dir="$WORK/claude-lock-lost-stops"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 7200 60
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.gemini.last_attempt_epoch=$now |
  .vendors.opencode={interval_min:45,last_attempt_epoch:$now,clean_since_epoch:$now}' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
sleep 30 &
steal_pid=$!
CB_STEAL_PID=$steal_pid CB_RESULT=steal run_refresh "$case_dir" "$NOW" || fail 'lock-lost stop run failed'
kill "$steal_pid" 2>/dev/null
wait "$steal_pid" 2>/dev/null
grep -q 'codex/beta' "$case_dir/calls.log" && \
  fail 'the tick kept refreshing other vendors after losing its lock'
jq -eR 'fromjson | select(.vendor == "codex")' "$case_dir/journal.jsonl" >/dev/null && \
  fail 'a vendor the tick never attempted was journaled'
rm -rf "$case_dir/state.json.lock"
pass

# A login screen is not pushback: the account becomes unrefreshable and the cadence stands.
case_dir="$WORK/claude-login-needed"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
CB_RESULT=login run_refresh "$case_dir" "$NOW" || fail 'login-needed run failed'
[ "$(jq -r '.claude.interval_min' "$case_dir/state.json")" -eq 30 ] || \
  fail 'a login screen loosened the cadence like a 429'
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "error" and
  .accounts_tried == ["alpha"] and (.detail | test("needs a human login") and
  test("unrefreshable: alpha")))' "$case_dir/journal.jsonl" >/dev/null || \
  fail 'a login-needed account was not journaled as unrefreshable'
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "refreshed")' \
  "$case_dir/journal.jsonl" >/dev/null && \
  fail 'an account that left the stale list by needing a login was counted as refreshed'
pass

# An explicit override is the whole claudeb: escaping to PATH would drive real accounts from
# a run that deliberately pointed somewhere else.
case_dir="$WORK/claude-override-broken"
mkdir -p "$case_dir/home"
printf 'not executable\n' >"$WORK/cb-dud"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
CB_BIN="$WORK/cb-dud" run_refresh "$case_dir" "$NOW" || fail 'unusable-claudeb run failed'
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "error" and
  .step == 0 and .accounts_tried == [] and (.detail | test("no claudeb to revive with")))' \
  "$case_dir/journal.jsonl" >/dev/null || \
  fail 'an unusable claudeb override did not surface as its own error at step 0'
[ -s "$case_dir/claudeb.log" ] && fail 'the override fell back to another claudeb'
pass

# claudeb reserves `main` and `-`: selecting one would hand the tick an account revive refuses
# forever, so a store holding nothing else is "nothing to select", not an attempt.
case_dir="$WORK/claude-reserved-only"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
jq --argjson now "$NOW" '.vendors.claude.accounts=[{account:"main",
  five_hour:{used_pct:10,as_of:($now - 7200)},weekly:{used_pct:20,as_of:($now - 7200)}}]' \
  "$case_dir/store.json" >"$case_dir/store.tmp" && mv "$case_dir/store.tmp" "$case_dir/store.json"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
run_refresh "$case_dir" "$NOW" || fail 'reserved-name run failed'
[ -s "$case_dir/claudeb.log" ] && fail 'a reserved name was driven through revive'
jq -eR 'fromjson | select(.vendor == "claude" and .step == 0 and .accounts_tried == [] and
  .outcome != "error" and .outcome != "partial" and (.detail | test("unrefreshable: main")))' \
  "$case_dir/journal.jsonl" >/dev/null || \
  fail 'a reserved-only stale set was reported as failed work instead of unrefreshable'
pass

case_dir="$WORK/claude-429"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
write_state "$case_dir/state.json" 30 30 30 0 "$((NOW - 1000))"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
CB_RESULT=pushback run_refresh "$case_dir" "$NOW" || fail 'revive pushback run failed'
[ "$(jq -r '.claude.interval_min' "$case_dir/state.json")" -eq 45 ] || \
  fail 'a 429 from revive did not loosen the cadence from 30 to 45'
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "pushback" and
  .interval_min == 45 and .accounts_tried == ["alpha"])' "$case_dir/journal.jsonl" >/dev/null || \
  fail 'the revive 429 was not journaled as pushback'
pass

# The driver self-limits, but a hung session must never hold the tick past the heartbeat.
case_dir="$WORK/claude-hung"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
hung_started=$SECONDS
CB_RESULT=hang LLM_LIMITS_REFRESH_REVIVE_TIMEOUT=1 run_refresh "$case_dir" "$NOW" || \
  fail 'hung-revive run failed'
[ "$((SECONDS - hung_started))" -lt 20 ] || fail 'a hung revive stalled the tick'
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "error" and
  .accounts_tried == ["alpha"] and (.detail | test("accounts remain stale")))' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'the killed revive was not journaled as an error'
[ "$(jq -r '.claude.interval_min' "$case_dir/state.json")" -eq 30 ] || \
  fail 'a killed revive was read as pushback'
pass

case_dir="$WORK/pushback"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 7200 60
write_state "$case_dir/state.json" 30 30 30 "$NOW" "$((NOW - 1000))"
jq '.vendors.codex.last_attempt_epoch=0' "$case_dir/state.json" >"$case_dir/state.tmp" && \
  mv "$case_dir/state.tmp" "$case_dir/state.json"
STUB_PUSHBACK_TARGET=codex/beta run_refresh "$case_dir" "$NOW" || fail 'pushback run failed'
[ "$(jq -r '.codex.interval_min' "$case_dir/state.json")" -eq 45 ] || \
  fail 'pushback did not loosen cadence from 30 to 45'
jq -eR 'fromjson | select(.vendor == "codex" and .outcome == "pushback" and
  .interval_min == 45 and .accounts_tried == ["beta"])' "$case_dir/journal.jsonl" >/dev/null || \
  fail 'pushback journal entry missing'
pass

case_dir="$WORK/tighten"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 60 60
write_state "$case_dir/state.json" 30 30 30 "$NOW" "$((NOW - 259201))"
jq '.vendors.codex.last_attempt_epoch=0' "$case_dir/state.json" >"$case_dir/state.tmp" && \
  mv "$case_dir/state.tmp" "$case_dir/state.json"
run_refresh "$case_dir" "$NOW" || fail 'clean-window run failed'
[ "$(jq -r '.codex.interval_min' "$case_dir/state.json")" -eq 22 ] || \
  fail '72-hour clean window did not tighten cadence'
[ "$(jq -r '.codex.clean_since_epoch' "$case_dir/state.json")" -eq "$NOW" ] || \
  fail 'tightened rung did not restart its clean window'
pass

case_dir="$WORK/journal-block"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 60 60
write_state "$case_dir/state.json" 30 30 30 "$NOW" "$((NOW - 259201))"
jq '.vendors.codex.last_attempt_epoch=0' "$case_dir/state.json" >"$case_dir/state.tmp" && \
  mv "$case_dir/state.tmp" "$case_dir/state.json"
jq -cn --argjson ts "$((NOW - 60))" \
  '{ts:$ts,vendor:"codex",step:1,accounts_tried:["beta"],outcome:"pushback",
    detail:"rate limited",interval_min:30}' >"$case_dir/journal.jsonl"
run_refresh "$case_dir" "$NOW" || fail 'journal pushback run failed'
[ "$(jq -r '.codex.interval_min' "$case_dir/state.json")" -eq 30 ] || \
  fail 'journaled pushback did not block cadence tightening'
pass

case_dir="$WORK/clean-after-pushback"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 7200 60
write_state "$case_dir/state.json" 30 30 30 "$NOW" "$((NOW - 1000))"
jq '.vendors.codex.last_attempt_epoch=0' "$case_dir/state.json" >"$case_dir/state.tmp" && \
  mv "$case_dir/state.tmp" "$case_dir/state.json"
STUB_PUSHBACK_TARGET=codex/beta run_refresh "$case_dir" "$NOW" || fail 'pushback seeding run failed'
[ "$(jq -r '.codex.interval_min' "$case_dir/state.json")" -eq 45 ] || \
  fail 'pushback seeding did not loosen the cadence'
LATER=$((NOW + 259201))
write_store "$case_dir/store.json" "$LATER" 60 60 60
run_refresh "$case_dir" "$LATER" || fail 'clean-window-after-pushback run failed'
[ "$(jq -r '.codex.interval_min' "$case_dir/state.json")" -eq 30 ] || \
  fail 'the pushback that opened the clean window kept blocking the tightening'
pass

case_dir="$WORK/blocked-account"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 60 60
jq --argjson now "$NOW" '.vendors.gemini.accounts += [{account:"delta",auth_needed:true,
  five_hour:{used_pct:10,as_of:($now - 7200)},weekly:{used_pct:20,as_of:($now - 7200)}}]' \
  "$case_dir/store.json" >"$case_dir/store.tmp" && mv "$case_dir/store.tmp" "$case_dir/store.json"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
run_refresh "$case_dir" "$NOW" || fail 'blocked-account run failed'
grep -q -- '--refresh-account' "$case_dir/calls.log" && \
  fail 'an account that needs a login was still targeted for a refresh'
jq -eRn '[inputs | fromjson | .vendor == "gemini" and .outcome == "fresh-passive" and
  (.accounts_tried | length) == 0 and (.detail | test("; unrefreshable: delta$"))] | any' \
  "$case_dir/journal.jsonl" >/dev/null || \
  fail 'blocked account missing from the gemini journal detail'
pass

case_dir="$WORK/store-unreadable"
mkdir -p "$case_dir/home"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
STUB_PASSIVE_RC=7 run_refresh "$case_dir" "$NOW" || fail 'unreadable-store run failed'
unset STUB_PASSIVE_RC
jq -eRn '[inputs | fromjson | select(.vendor != "opencode") |
  .outcome == "error" and (.detail | test("exited 7"))] |
  length == 3 and all' "$case_dir/journal.jsonl" >/dev/null || \
  fail 'a failed collector plus an unreadable store was journaled as fresh'
pass

case_dir="$WORK/dead-holder-lock"
mkdir -p "$case_dir/home" "$case_dir/state.json.lock"
write_store "$case_dir/store.json" "$NOW" 60 60 60
sleep 0 &
dead_tick_pid=$!
wait "$dead_tick_pid" 2>/dev/null
printf '%s\n' "$dead_tick_pid" >"$case_dir/state.json.lock/pid"
run_refresh "$case_dir" "$NOW" || fail 'dead-holder lock run failed'
[ -s "$case_dir/state.json" ] || fail 'a lock whose holder has exited still blocked the tick'
[ ! -e "$case_dir/state.json.lock" ] || fail 'the replacement lock was not released'
pass

case_dir="$WORK/live-holder-lock"
mkdir -p "$case_dir/home" "$case_dir/state.json.lock"
write_store "$case_dir/store.json" "$NOW" 60 60 60
sleep 30 &
live_tick_pid=$!
printf '%s\n' "$live_tick_pid" >"$case_dir/state.json.lock/pid"
touch -t "$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '-10 minutes' +%Y%m%d%H%M)" \
  "$case_dir/state.json.lock"
LLM_LIMITS_REFRESH_LOCK_STALE_SECONDS=1 run_refresh "$case_dir" "$NOW" || \
  fail 'live-holder lock run failed'
unset LLM_LIMITS_REFRESH_LOCK_STALE_SECONDS
[ ! -e "$case_dir/state.json" ] || fail 'a running holder lost its lock to the next tick'
grep -qx "$live_tick_pid" "$case_dir/state.json.lock/pid" || \
  fail 'the running holder lost ownership of its lock'
kill "$live_tick_pid" 2>/dev/null
wait "$live_tick_pid" 2>/dev/null
pass

# OpenCode has no usage endpoint: its only probe is a real completion, so the vendor stays dormant
# until a wall stands and every tick that finds none must send nothing at all.
OC_NOW=$(date +%s)

case_dir="$WORK/opencode-dormant"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$OC_NOW" 60 60 60
write_state "$case_dir/state.json" 30 30 30 "$OC_NOW" "$OC_NOW"
run_refresh "$case_dir" "$OC_NOW" || fail 'dormant OpenCode run failed'
[ ! -e "$case_dir/opencode.log" ] || fail 'a dormant OpenCode account was still sent a completion'
jq -eR 'fromjson | select(.vendor == "opencode" and .step == 0 and .outcome == "dormant" and
  (.accounts_tried | length) == 0 and .interval_min == 45)' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'dormant OpenCode tick was not journaled'
jq -e '.opencode' "$case_dir/state.json" >/dev/null || \
  fail 'a state file written before OpenCode existed did not gain the vendor'
pass

case_dir="$WORK/opencode-walled"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$OC_NOW" 60 60 60
write_state "$case_dir/state.json" 30 30 30 "$OC_NOW" "$OC_NOW"
seed_opencode_wall "$case_dir/store.json" evyoxqy \
  "$(date -u -r "$((OC_NOW + 3 * 86400))" '+%Y-%m-%dT%H:%M:%SZ')"
OC_STUB_RESULT=walled run_refresh "$case_dir" "$OC_NOW" || fail 'walled OpenCode run failed'
[ "$(cat "$case_dir/opencode.log")" = 'wall-check|evyoxqy' ] || \
  fail "the wall was not probed once through wall-check: $(cat "$case_dir/opencode.log")"
jq -eR 'fromjson | select(.vendor == "opencode" and .step == 1 and .outcome == "walled" and
  .accounts_tried == ["evyoxqy"] and .interval_min == 45)' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'the repeated 429 was not journaled as a wall'
[ "$(standing_opencode_walls "$case_dir" | jq 'length')" -eq 1 ] || \
  fail 'the repeated 429 did not leave the wall standing'
pass

case_dir="$WORK/opencode-reopened"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$OC_NOW" 60 60 60
write_state "$case_dir/state.json" 30 30 30 "$OC_NOW" "$OC_NOW"
seed_opencode_wall "$case_dir/store.json" - \
  "$(date -u -r "$((OC_NOW + 3 * 86400))" '+%Y-%m-%dT%H:%M:%SZ')"
run_refresh "$case_dir" "$OC_NOW" || fail 'reopened OpenCode run failed'
[ "$(cat "$case_dir/opencode.log")" = 'wall-check|' ] || \
  fail 'the default profile was probed under a name nobody has a key for'
jq -eR 'fromjson | select(.vendor == "opencode" and .outcome == "reopened" and
  .accounts_tried == ["-"])' "$case_dir/journal.jsonl" >/dev/null || \
  fail 'a served probe was not journaled as a reopened window'
[ "$(standing_opencode_walls "$case_dir" | jq 'length')" -eq 0 ] || \
  fail 'a served probe left the wall standing'
run_refresh "$case_dir" "$((OC_NOW + 7200))" || fail 'post-reopening run failed'
[ "$(grep -c . "$case_dir/opencode.log")" -eq 1 ] || \
  fail 'the vendor kept probing after its window reopened'
grep -q '^lock-held$' "$case_dir/opencode.log" && \
  fail 'the tick lock was still held while the probe was out'
pass

case_dir="$WORK/opencode-nothing-sent"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$OC_NOW" 60 60 60
write_state "$case_dir/state.json" 30 30 30 "$OC_NOW" "$OC_NOW"
seed_opencode_wall "$case_dir/store.json" - \
  "$(date -u -r "$((OC_NOW + 3 * 86400))" '+%Y-%m-%dT%H:%M:%SZ')"
OC_STUB_RESULT=dormant run_refresh "$case_dir" "$OC_NOW" || fail 'nothing-sent OpenCode run failed'
jq -eR 'fromjson | select(.vendor == "opencode" and .outcome == "dormant")' \
  "$case_dir/journal.jsonl" >/dev/null || \
  fail 'a probe that sent nothing was not journaled as dormant'
jq -eR 'fromjson | select(.vendor == "opencode" and .outcome == "reopened")' \
  "$case_dir/journal.jsonl" >/dev/null && \
  fail 'a probe that sent nothing was read as a window that reopened'
pass

case_dir="$WORK/opencode-inconclusive"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$OC_NOW" 60 60 60
write_state "$case_dir/state.json" 30 30 30 "$OC_NOW" "$OC_NOW"
seed_opencode_wall "$case_dir/store.json" - \
  "$(date -u -r "$((OC_NOW + 3 * 86400))" '+%Y-%m-%dT%H:%M:%SZ')"
OC_STUB_RESULT=fail run_refresh "$case_dir" "$OC_NOW" || fail 'inconclusive OpenCode run failed'
jq -eR 'fromjson | select(.vendor == "opencode" and .outcome == "error" and
  (.detail | test("inconclusive")))' "$case_dir/journal.jsonl" >/dev/null || \
  fail 'a probe that answered nothing was journaled as a verdict, or without its reason'
[ "$(standing_opencode_walls "$case_dir" | jq 'length')" -eq 1 ] || \
  fail 'a probe that answered nothing retired the wall anyway'
pass

# The stated reset is day-granular, so it is a hint, not a deadline: the cadence tightens as it
# nears and stays tight past it, because only a served request ends the wall.
oc_cadence() {
  HOME="$WORK/functions-home" LLM_REFRESH_NOW=1000000 bash -c \
    '. "$1"; opencode_next_interval "$2" "$3"' _ "$SCRIPT" "$1" "$2"
}
[ "$(oc_cadence 30 '[{"reset_at":1259200}]')" = 45 ] || fail 'a reset days out did not loosen'
[ "$(oc_cadence 30 '[{"reset_at":1001200}]')" = 22 ] || fail 'an approaching reset did not tighten'
[ "$(oc_cadence 30 '[{"reset_at":999000}]')" = 22 ] || \
  fail 'a reset already past stopped tightening instead of probing on'
[ "$(oc_cadence 30 '[{"window":"weekly"}]')" = 22 ] || fail 'a wall with no stated reset loosened'
[ "$(oc_cadence 30 '[{"reset_at":1259200},{"reset_at":1001200}]')" = 22 ] || \
  fail 'the cadence followed a far reset while a nearer one stood'
pass

floor=$(HOME="$WORK/functions-home" bash -c '. "$1"; ladder_tighten 15' _ "$SCRIPT")
ceiling=$(HOME="$WORK/functions-home" bash -c '. "$1"; ladder_loosen 60' _ "$SCRIPT")
[ "$floor" = 15 ] || fail 'cadence ladder crossed the 15-minute floor'
[ "$ceiling" = 60 ] || fail 'cadence ladder crossed the 60-minute ceiling'
pass

for journal in "$WORK"/*/journal.jsonl; do
  jq -eRn '[inputs | fromjson |
    has("ts") and has("vendor") and has("step") and
    has("accounts_tried") and has("outcome") and has("detail") and has("interval_min") and
    (.ts | type) == "number" and (.vendor | type) == "string" and
    (.step | type) == "number" and (.accounts_tried | type) == "array" and
    (.outcome | type) == "string" and (.detail | type) == "string" and
    (.interval_min | type) == "number"] | length > 0 and all' "$journal" >/dev/null || \
    fail "invalid journal line in $journal"
done
pass

printf 'PASS: %s llm-refresh tests\n' "$passed"
