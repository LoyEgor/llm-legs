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
      claude:{interval_min:$claude,last_attempt_epoch:$last,clean_since_epoch:$clean},
      codex:{interval_min:$codex,last_attempt_epoch:$last,clean_since_epoch:$clean},
      gemini:{interval_min:$gemini,last_attempt_epoch:$last,clean_since_epoch:$clean}
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
[ "$(wc -l <"$case_dir/calls.log" | tr -d ' ')" -eq 1 ] || fail 'Claude caused a targeted refresh call'
jq -eR 'fromjson | select(.vendor == "claude" and .step == 0 and
  .outcome == "stale-no-path" and (.accounts_tried | length) == 0)' \
  "$case_dir/journal.jsonl" >/dev/null || fail 'Claude stale-no-path journal entry missing'
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
