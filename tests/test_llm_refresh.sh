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
  # Stands in for the real merge: what revive left in the claudeb snapshot reaches the store
  # only here, never before.
  if [ -s "${CB_SNAPSHOT:-/dev/null}" ]; then
    tmp=$(mktemp "${LLM_LIMITS_CACHE}.tmp.XXXXXX") || exit 5
    jq --argjson now "$LLM_REFRESH_NOW" --slurpfile pending <(jq -Rn '[inputs]' <"$CB_SNAPSHOT") '
      .vendors.claude.accounts |= map(if (.account | IN($pending[0][])) then
        .refresh_error={cause:"HTTP 429 rate limit",at:$now} else . end)' \
      "$LLM_LIMITS_CACHE" >"$tmp" && mv -f "$tmp" "$LLM_LIMITS_CACHE"
  fi
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
  mixed)
    case " ${CB_LOGIN_ACCOUNTS:-} " in
      *" $account "*)
        restate '.vendors.claude.accounts |= map(if .account == $account then
                   .auth_needed=true else . end)'
        printf 'claudeb: revive: %s needs a human login\n' "$account" >&2
        exit 4
        ;;
    esac
    printf 'claudeb: revive failed account=%s cause=warm-429 http=429\n' "$account" >&2
    exit 5
    ;;
  snapshot-pushback)
    # The 429 lands in the claudeb snapshot only; stderr says nothing a reader could match.
    printf '%s\n' "$account" >>"${CB_SNAPSHOT:-/dev/null}"
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
  local path=$1 now=$2 claude_age=$3 codex_age=$4 gemini_age=$5 grok_age=${6:-}
  jq -cn --argjson now "$now" --argjson ca "$claude_age" --argjson coa "$codex_age" \
    --argjson ga "$gemini_age" --arg gra "$grok_age" '
    def row($name;$age):
      {account:$name,five_hour:{used_pct:10,as_of:($now-$age)},
       weekly:{used_pct:20,as_of:($now-$age)}};
    def weekly_row($name;$age):
      {account:$name,weekly:{used_pct:20,as_of:($now-$age)}};
    {schema:1,vendors:({
      claude:{available:true,accounts:[row("alpha";$ca)]},
      codex:{available:true,accounts:[row("beta";$coa)]},
      gemini:{available:true,accounts:[row("gamma";$ga)]}
    } + (if $gra == "" then {}
         else {grok:{available:true,accounts:[weekly_row("gr";($gra | tonumber))]}} end))}' >"$path"
}

# The grok rung is written only when a case names one: left out, the vendor falls to the same
# default every unseeded vendor gets, and a rung read back from there proves nothing.
write_state() {
  local path=$1 claude=$2 codex=$3 gemini=$4 last=$5 clean=$6 grok=${7:-}
  jq -cn --argjson claude "$claude" --argjson codex "$codex" --argjson gemini "$gemini" \
    --argjson last "$last" --argjson clean "$clean" --arg grok "$grok" '
    {vendors:{
      claude:{interval_min:$claude,last_attempt_epoch:$last,clean_since_epoch:$clean,attempts:{}},
      codex:{interval_min:$codex,last_attempt_epoch:$last,clean_since_epoch:$clean,attempts:{}},
      gemini:{interval_min:$gemini,last_attempt_epoch:$last,clean_since_epoch:$clean,attempts:{}}
    }} |
    if $grok == "" then .
    else .vendors.grok = {interval_min:($grok | tonumber),last_attempt_epoch:$last,
      clean_since_epoch:$clean,attempts:{}} end' >"$path"
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

# PATH grokb so a daemon that shells out to `grokb <name> exec models` lands in calls.log.
GROK_BIN="$WORK/bin"
mkdir -p "$GROK_BIN"
cat >"$GROK_BIN/grokb" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'grokb %s\n' "$*" >>"$STUB_LOG"
exit 0
EOF
chmod +x "$GROK_BIN/grokb"

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
    CB_TOKEN_FRESH="${CB_TOKEN_FRESH:-}" CB_SNAPSHOT="${CB_SNAPSHOT:-$dir/cb-snapshot.log}" \
    CB_LOGIN_ACCOUNTS="${CB_LOGIN_ACCOUNTS:-}" \
    LLM_LIMITS_REFRESH_REVIVE_TIMEOUT="${LLM_LIMITS_REFRESH_REVIVE_TIMEOUT:-240}" \
    LLM_LIMITS_REFRESH_PROBE_TIMEOUT="${LLM_LIMITS_REFRESH_PROBE_TIMEOUT:-90}" \
    LLM_LIMITS_REFRESH_LOCK_STALE_SECONDS="${LLM_LIMITS_REFRESH_LOCK_STALE_SECONDS:-1800}" \
    STUB_PUSHBACK_TARGET="${STUB_PUSHBACK_TARGET:-}" STUB_REFRESH_SUCCEED="${STUB_REFRESH_SUCCEED:-1}" \
    STUB_PASSIVE_RC="${STUB_PASSIVE_RC:-0}" \
    PATH="$GROK_BIN:$PATH" \
    bash "$SCRIPT"
}

NOW=2000000000

case_dir="$WORK/defaults"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 60 60
run_refresh "$case_dir" "$NOW" || fail 'first run failed'
jq -e --argjson now "$NOW" '
  all(.claude, .codex, .gemini, .grok; .interval_min == 30 and .last_attempt_epoch == $now and
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

# One tick can meet both: an account that needs a human and another being rate-limited. Only the
# 429 carries a cadence decision, so the login note must not be what the tick reports instead.
case_dir="$WORK/claude-login-and-429"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
jq --argjson now "$NOW" '.vendors.claude.accounts += [{account:"zeta",
  five_hour:{used_pct:10,as_of:($now - 7200)},weekly:{used_pct:20,as_of:($now - 7200)}}]' \
  "$case_dir/store.json" >"$case_dir/store.tmp" && mv "$case_dir/store.tmp" "$case_dir/store.json"
write_state "$case_dir/state.json" 30 30 30 0 "$((NOW - 1000))"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
CB_RESULT=mixed CB_LOGIN_ACCOUNTS=alpha CB_TOKEN_FRESH="alpha zeta" \
  run_refresh "$case_dir" "$NOW" || fail 'login-plus-429 run failed'
[ "$(jq -r '.claude.interval_min' "$case_dir/state.json")" -eq 45 ] || \
  fail 'a login note swallowed the 429 and left the cadence where it was'
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "pushback" and
  (.detail | test("429") and test("needs a human login")))' "$case_dir/journal.jsonl" >/dev/null || \
  fail 'the tick reported the login need and the 429 as if only one of them happened'
pass

# What a probe hit reaches the store only through the collect that follows it: a 429 recorded
# there and nowhere a reader could see earlier must still loosen the cadence.
case_dir="$WORK/claude-429-store-only"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
write_state "$case_dir/state.json" 30 30 30 0 "$((NOW - 1000))"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
CB_RESULT=snapshot-pushback CB_TOKEN_FRESH=alpha \
  run_refresh "$case_dir" "$NOW" || fail 'store-only 429 run failed'
[ "$(jq -r '.claude.interval_min' "$case_dir/state.json")" -eq 45 ] || \
  fail 'a 429 the collect recorded did not loosen the cadence from 30 to 45'
jq -eR 'fromjson | select(.vendor == "claude" and .outcome == "pushback")' \
  "$case_dir/journal.jsonl" >/dev/null || \
  fail 'a 429 visible only in the store was not journaled as pushback'
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

# Grok rides the normal cadence: the billing read is a usage query, so a stale account is
# refreshed like any codex or gemini one.
case_dir="$WORK/grok-stale"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 60 60 7200
write_state "$case_dir/state.json" 30 30 30 "$NOW" "$NOW" 45
# A seeded rung also decides when the vendor is next due, so its last attempt is one rung back.
jq -c --argjson due "$((NOW - 45 * 60))" '.vendors.grok.last_attempt_epoch = $due' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
run_refresh "$case_dir" "$NOW" || fail 'grok run failed'
grep -qx -- '--refresh-account grok/gr' "$case_dir/calls.log" || \
  fail 'a stale grok account was not refreshed'
grep -q '^grokb ' "$case_dir/calls.log" && \
  fail 'an account with no auth verdict on record was driven through the CLI'
jq -eR 'fromjson | select(.vendor == "grok" and .step == 1 and .accounts_tried == ["gr"] and
  .outcome == "refreshed")' "$case_dir/journal.jsonl" >/dev/null || \
  fail 'the grok refresh was not journaled'
[ "$(jq -r '.grok.interval_min' "$case_dir/state.json")" -eq 45 ] || \
  fail 'the grok cadence rung was not carried'
pass

# Grok has no fixed base account, so a vendor with no roster names nobody to refresh — inventing
# a `main` here would tell the owner to log into an account that does not exist.
case_dir="$WORK/grok-empty"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 60 60
write_state "$case_dir/state.json" 30 30 30 "$NOW" "$NOW"
run_refresh "$case_dir" "$NOW" || fail 'empty-grok run failed'
grep -q 'grok/' "$case_dir/calls.log" && fail 'an empty grok vendor was still given a main account'
jq -eR 'fromjson | select(.vendor == "grok" and .step == 0 and (.accounts_tried | length) == 0)' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'the empty grok vendor was not journaled'
pass

# Every expired-token case wants the same frame: grok alone due, its rung seeded, and one account
# carrying the auth verdict its last poll left behind.
seed_grok_case() { # <dir> <grok age> <auth status>
  local dir=$1
  mkdir -p "$dir/home"
  write_store "$dir/store.json" "$NOW" 60 60 60 "$2"
  jq -c --arg status "$3" '.vendors.grok.accounts[0].auth={status:$status}' "$dir/store.json" \
    >"$dir/store.tmp" && mv "$dir/store.tmp" "$dir/store.json"
  write_state "$dir/state.json" 30 30 30 "$NOW" "$NOW" 45
  jq -c --argjson due "$((NOW - 45 * 60))" '.vendors.grok.last_attempt_epoch = $due' \
    "$dir/state.json" >"$dir/state.tmp" && mv "$dir/state.tmp" "$dir/state.json"
}

# An expired grok access token is not a dead end: the collector's targeted refresh rotates it
# through the vendor CLI before polling (row ak), so the tick's whole job is to ask for that
# re-poll — once — instead of filing the account as unrefreshable.
case_dir="$WORK/grok-expired"
seed_grok_case "$case_dir" 7200 expired
run_refresh "$case_dir" "$NOW" || fail 'grok expired-token run failed'
[ "$(grep -c -- '^--refresh-account grok/gr$' "$case_dir/calls.log")" -eq 1 ] || \
  fail "the expired grok account was not re-polled exactly once: $(cat "$case_dir/calls.log")"
grep -q 'exec models' "$case_dir/calls.log" && \
  fail "the daemon ran the vendor CLI itself; the collector owns the touch: $(cat "$case_dir/calls.log")"
jq -eR 'fromjson | select(.vendor == "grok" and .step == 1 and .accounts_tried == ["gr"] and
  .outcome == "refreshed" and (.detail | test("unrefreshable") | not))' "$case_dir/journal.jsonl" >/dev/null || \
  fail "the grok re-poll was not journaled as the refresh it was: $(cat "$case_dir/journal.jsonl")"
# Grok takes no attempt stamp: the claude revive rotates over accounts and reads the stamps to do
# it, while every stale grok account is re-polled in the tick it comes up. A stamp nobody reads is
# state that drifts.
jq -e '.grok.attempts == {}' "$case_dir/state.json" >/dev/null || \
  fail "the re-poll left a stamp nothing reads: $(jq -c '.grok.attempts' "$case_dir/state.json")"
jq -e --argjson now "$NOW" '.grok.last_attempt_epoch == $now' "$case_dir/state.json" >/dev/null || \
  fail 'the vendor rung, which is what gates the next attempt, did not advance'
pass

# A re-poll that heals nothing must not turn into a retry storm: one attempt per account per tick,
# and the account waits for the next tick like any other stale one.
case_dir="$WORK/grok-repoll-failed"
seed_grok_case "$case_dir" 7200 expired
STUB_REFRESH_SUCCEED=0 run_refresh "$case_dir" "$NOW" || fail 'grok failed re-poll run failed'
[ "$(grep -c -- '^--refresh-account grok/gr$' "$case_dir/calls.log")" -eq 1 ] || \
  fail "a failing re-poll was retried inside one tick: $(cat "$case_dir/calls.log")"
jq -eR 'fromjson | select(.vendor == "grok" and .outcome == "error" and
  (.detail | test("accounts remain stale")))' "$case_dir/journal.jsonl" >/dev/null || \
  fail "a re-poll that did not heal the account was not journaled as such: $(cat "$case_dir/journal.jsonl")"
STUB_REFRESH_SUCCEED=0 run_refresh "$case_dir" "$((NOW + 3600))" || fail 'second failed re-poll run failed'
[ "$(grep -c -- '^--refresh-account grok/gr$' "$case_dir/calls.log")" -eq 2 ] || \
  fail "the next tick did not take exactly one more attempt: $(cat "$case_dir/calls.log")"
jq -e '.grok.attempts == {}' "$case_dir/state.json" >/dev/null || \
  fail 'a repeated re-poll started stamping state nothing reads'
pass

# What bounds the attempts is the vendor's rung, not a per-account stamp: a token the CLI cannot
# rotate leaves the account with no `as_of` and therefore stale on every heartbeat, so a heartbeat
# inside the rung must not reach the collector at all.
case_dir="$WORK/grok-rung-backoff"
seed_grok_case "$case_dir" 7200 expired
STUB_REFRESH_SUCCEED=0 run_refresh "$case_dir" "$NOW" || fail 'grok backoff first run failed'
STUB_REFRESH_SUCCEED=0 run_refresh "$case_dir" "$((NOW + 60))" || fail 'grok backoff second run failed'
[ "$(grep -c -- '--refresh-account grok/gr' "$case_dir/calls.log")" -eq 1 ] || \
  fail "a heartbeat inside the rung re-polled again: $(cat "$case_dir/calls.log")"
pass

# A signed-in account is the same plain usage re-poll.
case_dir="$WORK/grok-token-ok"
seed_grok_case "$case_dir" 7200 ok
run_refresh "$case_dir" "$NOW" || fail 'grok signed-in run failed'
grep -qx -- '--refresh-account grok/gr' "$case_dir/calls.log" || \
  fail 'the signed-in account was not re-polled'
jq -e '.grok.attempts == {}' "$case_dir/state.json" >/dev/null || \
  fail 'a plain re-poll took an attempt stamp'
pass

# Staleness is what asks for the work: an expired token on a fresh reading is nothing to do this
# tick — and it is not `unrefreshable` either, which is what kept these accounts stale for hours.
case_dir="$WORK/grok-expired-fresh"
seed_grok_case "$case_dir" 60 expired
run_refresh "$case_dir" "$NOW" || fail 'grok fresh-reading run failed'
grep -q 'grok' "$case_dir/calls.log" && fail 'a fresh grok reading was refreshed anyway'
jq -eR 'fromjson | select(.vendor == "grok" and .step == 0 and
  (.detail | test("unrefreshable") | not))' "$case_dir/journal.jsonl" >/dev/null || \
  fail "an expired grok token was reported as beyond refreshing: $(cat "$case_dir/journal.jsonl")"
pass

# Claude is the opposite contract: only an interactive session rotates its token, so an expired one
# stays unrefreshable rather than becoming work every tick repeats.
case_dir="$WORK/claude-expired-blocked"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 7200 60 60
jq -c '.vendors.claude.accounts[0].auth={status:"expired"}' "$case_dir/store.json" \
  >"$case_dir/store.tmp" && mv "$case_dir/store.tmp" "$case_dir/store.json"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
jq --argjson now "$NOW" '.vendors.codex.last_attempt_epoch=$now | .vendors.gemini.last_attempt_epoch=$now' \
  "$case_dir/state.json" >"$case_dir/state.tmp" && mv "$case_dir/state.tmp" "$case_dir/state.json"
run_refresh "$case_dir" "$NOW" || fail 'claude expired-token run failed'
[ -s "$case_dir/claudeb.log" ] && fail 'an expired Claude token was driven through revive'
jq -eR 'fromjson | select(.vendor == "claude" and .step == 0 and
  (.detail | test("unrefreshable: alpha")))' "$case_dir/journal.jsonl" >/dev/null || \
  fail "an expired Claude token stopped being unrefreshable: $(cat "$case_dir/journal.jsonl")"
pass

case_dir="$WORK/store-unreadable"
mkdir -p "$case_dir/home"
write_state "$case_dir/state.json" 30 30 30 0 "$NOW"
STUB_PASSIVE_RC=7 run_refresh "$case_dir" "$NOW" || fail 'unreadable-store run failed'
unset STUB_PASSIVE_RC
jq -eRn '[inputs | fromjson | select(.vendor != "opencode") |
  .outcome == "error" and (.detail | test("exited 7"))] |
  length == 4 and all' "$case_dir/journal.jsonl" >/dev/null || \
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

# A PAUSED vendor is parked for months and must not exist for this daemon: no tick, no state
# entry, no journal line — and so none of the per-account paths is ever reached for it. The switch lives in worker-pick's own file; the store cannot answer it,
# because the collector deliberately writes no entry for a parked vendor.
case_dir="$WORK/paused"
mkdir -p "$case_dir/home/.claude"
write_store "$case_dir/store.json" "$NOW" 7200 7200 7200 7200
seed_opencode_wall "$case_dir/store.json" "-" "2033-05-18T00:00:00Z"
printf 'codex_paused=on\ngrok_paused=on\nopencode_paused=on\n' >"$case_dir/home/.claude/worker-model"
run_refresh "$case_dir" "$NOW" || fail 'paused run failed'
jq -e '(keys | sort) == ["claude","gemini"]' "$case_dir/state.json" >/dev/null || \
  fail 'a paused vendor kept a cadence entry in the daemon state'
grep -Eq '(codex|grok|opencode)/' "$case_dir/calls.log" && \
  fail 'a paused vendor was refreshed'
[ ! -e "$case_dir/opencode.log" ] || fail 'a paused opencode was still probed'
jq -eRn '[inputs | fromjson | .vendor] | any(. == "codex" or . == "grok" or . == "opencode") | not' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'a paused vendor was journaled'
jq -eRn '[inputs | fromjson | .vendor] | (index("claude") != null) and (index("gemini") != null)' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'the pause stopped the vendors that are still running'
pass

# Deleting the line brings the vendor back whole — the pause writes nothing anywhere else.
: >"$case_dir/home/.claude/worker-model"
rm -f "$case_dir/state.json" "$case_dir/journal.jsonl"
run_refresh "$case_dir" "$((NOW + 7200))" || fail 'resumed run failed'
jq -e '(keys | sort) == ["claude","codex","gemini","grok","opencode"]' "$case_dir/state.json" \
  >/dev/null || fail 'resuming did not bring every vendor back into the cadence state'
pass

# The daemon reaches a vendor's accounts through `llm-limits.sh --refresh-account`, and that flag
# NAMES a vendor: a parked one is refused in the collector's own words rather than silently
# skipped, which would report an old reading as a fresh one.
printf 'grok_paused=on\n' >"$WORK/paused-config"
paused_err=$(env HOME="$case_dir/home" WORKER_PICK_CONFIG_FILE="$WORK/paused-config" \
  bash "$ROOT/llm-limits.sh" --refresh-account grok/gr 2>&1 >/dev/null)
paused_rc=$?
# Read the wording as well as the status: every other way this call can fail also exits non-zero,
# so a status alone would pass with the pause never consulted.
[ "$paused_rc" -eq 2 ] || fail "paused --refresh-account exit status: $paused_rc"
[ "$paused_err" = 'grok is paused (grok_paused=on in ~/.claude/worker-model)' ] || \
  fail "paused --refresh-account refusal wording: $paused_err"
pass

# The vendor-wide `refresh_error` is the OLD contract, and it joins the cause of every account
# into one string: read beside a per-account list it answers for accounts this call never asked
# about, so a 429 that belongs to another account of the same vendor loosened the cadence for one
# whose own recorded cause is a login screen. Only where the list has nothing to say is it read.
case_dir="$WORK/legacy-error-not-a-peer"
mkdir -p "$case_dir/home"
write_store "$case_dir/store.json" "$NOW" 60 7200 60
write_state "$case_dir/state.json" 30 30 30 "$NOW" "$((NOW - 1000))"
jq --argjson now "$NOW" '
  .vendors.codex.refresh_errors=[{account:"beta",cause:"needs a human login",at:$now}] |
  .vendors.codex.refresh_error={cause:"beta: needs a human login; other: HTTP 429 rate limit",
                                at:$now} |
  .vendors.codex.last_attempt_epoch=0' "$case_dir/store.json" >"$case_dir/store.tmp" && \
  mv "$case_dir/store.tmp" "$case_dir/store.json"
jq '.vendors.codex.last_attempt_epoch=0' "$case_dir/state.json" >"$case_dir/state.tmp" && \
  mv "$case_dir/state.tmp" "$case_dir/state.json"
STUB_REFRESH_SUCCEED=0 run_refresh "$case_dir" "$NOW" || fail 'legacy-error run failed'
[ "$(jq -r '.codex.interval_min' "$case_dir/state.json")" -eq 30 ] || \
  fail 'another account 429, joined into the legacy vendor error, loosened this one cadence'
jq -eR 'fromjson | select(.vendor == "codex" and .outcome == "pushback")' \
  "$case_dir/journal.jsonl" >/dev/null && \
  fail 'the legacy vendor error was read as this account pushback'
pass

# A docstring belongs to the function it heads: one that outlived its own now explains the next
# function down, and a comment that lost its wrap is read by nobody.
grep -q 'grok_token_expired' "$SCRIPT" && fail 'a docstring survived the function it described'
docstrings=$(sed -n '/^# A paused vendor is parked/,/^vendor_paused()/p
                     /^# Every attempt stamps/,/^stamp_attempt()/p' "$SCRIPT")
[ -n "$docstrings" ] || fail 'the docstrings under test are not where this check looks'
[ -z "$(awk 'length > 100' <<<"$docstrings")" ] || fail 'a docstring runs past 100 columns'
case "$docstrings" in
  *'refresh_token beside'*) fail 'the token-expiry docstring still heads stamp_attempt' ;;
esac
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
