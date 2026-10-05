#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/llm_limits_harness.sh"

home_fixture_after_first_suite
seed_claudeb_store

# zoe: distant 5h reset but imminent weekly reset — --sort reset must use min(5h, weekly).
printf '{"five_hour":{"used_percentage":11,"resets_at":%s},"seven_day":{"used_percentage":97,"resets_at":%s}}\n' "$((now + 50000))" "$((now + 990))" >"$CLAUDEB/limits/zoe.json"
reset_sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort reset) || fail "reset-sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$reset_sorted" | paste -sd, -)
[ "$order" = "claude/zoe,codex,claude/alona*,gemini,grok" ] || fail "--sort reset min(5h, weekly) order mismatch: $order"
rm "$CLAUDEB/limits/zoe.json"
SORT_RESET_STORE="$WORK/sort-reset-store"
EMPTY_SORT_HOME="$WORK/sort-reset-home"
mkdir -p "$SORT_RESET_STORE/limits" "$EMPTY_SORT_HOME"
printf 'future-a\n' >"$SORT_RESET_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$((now + 1000))" >"$SORT_RESET_STORE/limits/future-a.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"fable":{"used_percentage":40,"resets_at":%s}}\n' \
  "$((now + 2000))" "$((now + 500))" >"$SORT_RESET_STORE/limits/future-b.json"
printf '{"five_hour":{"used_percentage":30,"resets_at":%s}}\n' "$((now - 18000))" >"$SORT_RESET_STORE/limits/expired.json"
reset_expired=$(HOME="$EMPTY_SORT_HOME" CLAUDEB_DIR="$SORT_RESET_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort reset) || fail "expired reset-sort collection failed"
order=$(awk 'NR > 1 && $1 ~ /^claude\// {print $1}' <<<"$reset_expired" | paste -sd, -)
[ "$order" = "claude/future-b,claude/future-a*,claude/expired" ] \
  || fail "--sort reset must include Fable and place expired windows last: $order"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort bogus >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "unknown --sort value: expected exit 2, got $rc"
HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort= >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "empty --sort=: expected exit 2, got $rc"
bare=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT") || fail "bare piped collection failed"
jq -e '.schema == 1 and (.vendors | keys == ["claude","codex","gemini","grok","opencode"])' <<<"$bare" >/dev/null || fail "piped bare invocation must emit schema-1 JSON"

sleep 1
TRUNCATED="$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-truncated.jsonl"
printf '{"padding":"%0700d"}\n' 0 >"$TRUNCATED"
printf '{"timestamp":"2026-07-11T12:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":88,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":44,"window_minutes":10080,"resets_at":%s},"plan_type":"plus"}}}\n' "$((now + 3000))" "$((now + 4000))" >>"$TRUNCATED"
truncated=$(HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_CHUNK_BYTES=512 bash "$SCRIPT" --json) || fail "truncated-chunk collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 88 and .vendors.codex.weekly.used_pct == 44' <<<"$truncated" >/dev/null || fail "valid event after truncated boundary was lost"

CROSS_HOME="$WORK/cross-home"
mkdir -p "$CROSS_HOME/.codex/sessions"
printf '{"timestamp":"2026-07-12T03:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":37,"resets_at":%s},"secondary":{"used_percent":23,"resets_at":%s}}}}\n' "$((now + 5000))" "$((now + 9000))" >"$CROSS_HOME/.codex/sessions/rollout-numeric.jsonl"
printf '%s\n' '{"timestamp":"2026-07-12T04:00:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":{"used_percent":99}}}}' >"$CROSS_HOME/.codex/sessions/rollout-null.jsonl"
touch -t 202607120100 "$CROSS_HOME/.codex/sessions/rollout-numeric.jsonl"
touch -t 202607120200 "$CROSS_HOME/.codex/sessions/rollout-null.jsonl"
cross_null=$(HOME="$CROSS_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "cross-file null-primary collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 37 and .vendors.codex.weekly.used_pct == 23' <<<"$cross_null" >/dev/null || fail "null-primary file hid a valid cross-file event"

printf '{"timestamp":"2026-07-12T02:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":61,"resets_at":%s},"secondary":{"used_percent":41,"resets_at":%s}}}}\n' "$((now + 6000))" "$((now + 10000))" >"$CROSS_HOME/.codex/sessions/rollout-mtime-newest.jsonl"
printf '{"timestamp":"2026-07-12T08:00:00+03:00","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":17,"resets_at":%s},"secondary":{"used_percent":11,"resets_at":%s}}}}\n' "$((now + 7000))" "$((now + 11000))" >"$CROSS_HOME/.codex/sessions/rollout-timestamp-latest.jsonl"
touch -t 202607120400 "$CROSS_HOME/.codex/sessions/rollout-timestamp-latest.jsonl"
touch -t 202607120500 "$CROSS_HOME/.codex/sessions/rollout-mtime-newest.jsonl"
cross_latest=$(HOME="$CROSS_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "cross-file timestamp collection failed"
jq -e '.vendors.codex.five_hour.used_pct == 17 and .vendors.codex.weekly.used_pct == 11' <<<"$cross_latest" >/dev/null || fail "mtime order outranked the latest event timestamp"

# Passive snapshot whose 5h reset already passed: flagged expired, table keeps the last
# known value and reset time (dimmed only on a TTY, so piped output stays escape-free),
# sort treats the stale 100% as 0. The fresh weekly window stays unflagged.
sleep 1
printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":44,"window_minutes":10080,"resets_at":%s},"plan_type":"plus"}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$((now - 600))" "$((now + 4000))" \
  >"$HOME_FIXTURE/.codex/sessions/2026/07/11/rollout-expired.jsonl"
expired_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "expired-window collection failed"
jq -e '.vendors.codex.five_hour.expired == true and .vendors.codex.five_hour.used_pct == 100 and
  .vendors.codex.five_hour.effective_pct == 0 and .vendors.codex.usable_now == true and
  (.vendors.codex.weekly | has("expired") | not) and
  (.vendors.claude.accounts[0].five_hour | has("expired") | not)' <<<"$expired_json" >/dev/null || fail "expired flag mismatch"
expired_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "expired table collection failed"
codex_row=$(awk 'NR > 1 && $1 == "codex"' <<<"$expired_table")
# The kept reset time may carry a weekday prefix: an expired window lies in the past, so
# around midnight it renders as yesterday. The cell shows the effective value (0, row y).
grep -Eq '^codex +0%! +44% +- +([A-Za-z]{3} )?[0-9]{2}:[0-9]{2}' <<<"$codex_row" || fail "expired window must render effective 0 and keep its reset time: $codex_row"
expired_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "expired plain collection failed"
grep -q 'codex: 5h 0%! @ .* | wk 44% @ ' <<<"$expired_plain" || fail "expired plain output must render effective 0 with the expired marker"
expired_sorted=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$CLAUDEB" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table --sort 5h) || fail "expired sorted table collection failed"
order=$(awk 'NR > 1 {print $1}' <<<"$expired_sorted" | paste -sd, -)
[ "$order" = "claude/alona*,codex,gemini,grok" ] || fail "expired 5h sort must rank the stale 100% as 0: $order"

HONEST_STORE="$WORK/honest-store"
HONEST_HOME="$WORK/honest-home"
mkdir -p "$HONEST_STORE/limits" "$HONEST_HOME"
printf 'honest\n' >"$HONEST_STORE/.claudeb-state"
# as_of is relative to a fresh capture, not the script-start `now`: the displayed age is
# (collect time - as_of), so a script-start base would silently add all elapsed test seconds
# and drift 1h1m -> 1h2m as the suite grows.
honest_now=$(date +%s)
printf '{"five_hour":{"used_percentage":100,"resets_at":%s,"as_of":%s,"origin":"usage"},"seven_day":{"used_percentage":44,"resets_at":%s,"as_of":%s,"origin":"usage"}}\n' \
  "$((honest_now + 5000))" "$((honest_now - 3660))" "$((honest_now - 60))" "$((honest_now - 120))" >"$HONEST_STORE/limits/honest.json"
honest_table=$(HOME="$HONEST_HOME" CLAUDEB_DIR="$HONEST_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) \
  || fail "honesty table fixture failed"
honest_plain=$(HOME="$HONEST_HOME" CLAUDEB_DIR="$HONEST_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) \
  || fail "honesty plain fixture failed"
head -n 1 <<<"$honest_table" | grep -Eq 'FB RESET +AGE +ROT +CR +STATUS' || fail "table universal state columns missing"
head -n 1 <<<"$honest_table" | grep -q 'NOTE' && fail "table NOTE column was not abolished"
honest_row=$(awk '$1 == "claude/honest*"' <<<"$honest_table")
grep -Eq '^claude/honest\* +100%~ +0%! ' <<<"$honest_row" || fail "honesty table lost markers or the effective expired value"
grep -Eq ' +1h1m +limit-5h +- +-$' <<<"$honest_row" || fail "table age or limit-derived state fields missing: $honest_row"
grep -q 'claude/honest\*: 5h 100%~ @ .* | wk 0%! @ ' <<<"$honest_plain" || fail "honesty plain lost markers or the effective expired value"
grep 'claude/honest\*:' <<<"$honest_plain" | grep -q '| age 1h1m | rot limit-5h | cr - | status -' \
  || fail "plain age or explicit state fields missing"

# A row carrying no dated window and a row a day old are one verdict, and neither may render as an
# ordinary age. The flag is the collector's alone: every surface paints it, none re-derives it.
ALARM_STORE="$WORK/alarm-store"
ALARM_CACHE="$WORK/alarm-cache.json"
mkdir -p "$ALARM_STORE/limits"
alarm_now=$(date +%s)
printf 'recent\n' >"$ALARM_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":12,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((alarm_now + 5000))" "$((alarm_now - 120))" "$alarm_now" >"$ALARM_STORE/limits/recent.json"
printf '{"five_hour":{"used_percentage":21,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((alarm_now + 5000))" "$((alarm_now - 172800))" "$alarm_now" >"$ALARM_STORE/limits/twodays.json"
printf '{"auth":{"status":"ok","checked_at":%s}}\n' "$alarm_now" >"$ALARM_STORE/limits/nodata.json"
alarm_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" LLM_LIMITS_CACHE="$ALARM_CACHE" \
  bash "$SCRIPT" --json) || fail "age-alarm collection failed"
jq -e '
  ([.vendors.claude.accounts[] | select(.account == "nodata")][0]
   | .age_alarm == true and (has("as_of") | not)) and
  ([.vendors.claude.accounts[] | select(.account == "twodays")][0] | .age_alarm == true) and
  ([.vendors.claude.accounts[] | select(.account == "recent")][0] | .age_alarm == false) and
  .vendors.claude.age_alarm == false' <<<"$alarm_json" >/dev/null \
  || fail "age_alarm mismatch on Claude accounts or the hoisted vendor object"
jq -e '[.vendors[] | (.accounts[]? // .) | .age_alarm] | length > 0 and all(type == "boolean")' \
  <<<"$alarm_json" >/dev/null || fail "an account or vendor object reached the projection without age_alarm"
ALARM_UNDATED_STORE="$WORK/alarm-undated-store"
mkdir -p "$ALARM_UNDATED_STORE/limits"
printf 'nodata\n' >"$ALARM_UNDATED_STORE/.claudeb-state"
printf '{"auth":{"status":"ok","checked_at":%s}}\n' "$alarm_now" >"$ALARM_UNDATED_STORE/limits/nodata.json"
alarm_undated=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_UNDATED_STORE" \
  LLM_LIMITS_CACHE="$WORK/alarm-undated-cache.json" bash "$SCRIPT" --json) \
  || fail "undated-vendor age-alarm collection failed"
jq -e '.vendors.claude | .age_alarm == true and (has("as_of") | not)' <<<"$alarm_undated" >/dev/null \
  || fail "a vendor with no dated window did not raise age_alarm"
alarm_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" LLM_LIMITS_CACHE="$ALARM_CACHE" \
  bash "$SCRIPT" --table) || fail "age-alarm table collection failed"
awk '$1 == "claude/nodata" {print $(NF-3)}' <<<"$alarm_table" | grep -qx never \
  || fail "an account with no dated window must render AGE as never: $alarm_table"
awk '$1 == "claude/twodays" {print $(NF-3)}' <<<"$alarm_table" | grep -qx 2d \
  || fail "a two-day age lost its span: $alarm_table"
printf '%s' "$alarm_table" | grep -q $'\033' && fail "the redirected table emitted color escapes"
alarm_color=$(CLICOLOR_FORCE=1 HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" \
  LLM_LIMITS_CACHE="$ALARM_CACHE" bash "$SCRIPT" --table) \
  || fail "age-alarm color table collection failed"
grep -q $'\033\[31mnever' <<<"$alarm_color" || fail "the never age did not render red"
grep -q $'\033\[31m2d' <<<"$alarm_color" || fail "a day-old age did not render red"
grep '^claude/recent' <<<"$alarm_color" | grep -q $'\033\[31m' \
  && fail "a fresh age rendered red"
alarm_plain=$(CLICOLOR_FORCE=1 HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" \
  LLM_LIMITS_CACHE="$ALARM_CACHE" bash "$SCRIPT" --plain) \
  || fail "age-alarm color plain collection failed"
grep '^claude/nodata:' <<<"$alarm_plain" | grep -q "| age "$'\033\[31m'"never" \
  || fail "the never age did not render red in plain"
grep '^claude/twodays:' <<<"$alarm_plain" | grep -q "| age "$'\033\[31m'"2d" \
  || fail "a day-old age did not render red in plain"
grep '^claude/recent' <<<"$alarm_plain" | grep -q $'\033\[31m' \
  && fail "a fresh age rendered red in plain"
alarm_plain_piped=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$ALARM_STORE" \
  LLM_LIMITS_CACHE="$ALARM_CACHE" bash "$SCRIPT" --plain) || fail "age-alarm plain collection failed"
printf '%s' "$alarm_plain_piped" | grep -q $'\033' && fail "the redirected plain output emitted color escapes"

# Hours-old data short of the day alarm is still data nobody may trust: STATUS says so and AGE is red.
STALE_STORE="$WORK/stale-store"
mkdir -p "$STALE_STORE/limits"
printf 'fresh\n' >"$STALE_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":0,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((alarm_now + 5000))" "$((alarm_now - 120))" "$alarm_now" >"$STALE_STORE/limits/fresh.json"
printf '{"five_hour":{"used_percentage":0,"resets_at":%s,"as_of":%s,"origin":"usage"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((alarm_now + 5000))" "$((alarm_now - 19 * 3600))" "$alarm_now" >"$STALE_STORE/limits/old.json"
stale_routing=$(. "$ROOT/share/limits-view.sh" && printf '%s' "$LIMITS_STALE_ROUTING")
stale_json=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" LLM_LIMITS_CACHE="$WORK/stale-cache.json" \
  bash "$SCRIPT" --json) || fail "stale-data collection failed"
jq -e --argjson thr "$stale_routing" '.account_stale_after_s == $thr' <<<"$stale_json" >/dev/null \
  || fail "the store does not publish the account staleness threshold"
stale_table=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" LLM_LIMITS_CACHE="$WORK/stale-cache.json" \
  bash "$SCRIPT" --table) || fail "stale-data table collection failed"
awk '$1 == "claude/old" {print $NF}' <<<"$stale_table" | grep -qx stale \
  || fail "a 19h-old account did not say stale in STATUS: $stale_table"
awk '$1 == "claude/fresh*" {print $NF}' <<<"$stale_table" | grep -qx -- - \
  || fail "a fresh account said stale: $stale_table"
stale_color=$(CLICOLOR_FORCE=1 HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" \
  LLM_LIMITS_CACHE="$WORK/stale-cache.json" bash "$SCRIPT" --table) || fail "stale-data color table failed"
grep '^claude/old' <<<"$stale_color" | grep -q $'\033\[31m19h' || fail "a 19h-old age did not render red"
stale_plain=$(HOME="$HOME_FIXTURE" CLAUDEB_DIR="$STALE_STORE" LLM_LIMITS_CACHE="$WORK/stale-cache.json" \
  bash "$SCRIPT" --plain) || fail "stale-data plain collection failed"
grep '^claude/old:' <<<"$stale_plain" | grep -q '| status stale$' \
  || fail "a 19h-old account did not say stale in plain: $stale_plain"

USABLE_STORE="$WORK/usable-store"
USABLE_HOME="$WORK/usable-home"
mkdir -p "$USABLE_STORE/limits" "$USABLE_HOME/.codex/sessions"
printf 'full\n' >"$USABLE_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":100,"resets_at":%s},"seven_day":{"used_percentage":100,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" "$now" >"$USABLE_STORE/limits/full.json"
claude_full=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude exhausted usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_full" >/dev/null || fail "Claude all-exhausted usability mismatch"
# The shield takes the account out of the POOL (`enabled`), which is consent; its auth is alive, so
# capability still reads true (shared-invariants row o) and a pin could still reach it.
jq -e '.vendors.claude.accounts[0] |
  .shielded == true and .enabled == false and
  .rotation == {usable:{general:true,fable:false}}' \
  <<<"$claude_full" >/dev/null || fail "exhausted main account did not enter the worker-pool shield"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" "$now" >"$USABLE_STORE/limits/free.json"
claude_free=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude free-account usability collection failed"
jq -e '.vendors.claude.usable_now == true' <<<"$claude_free" >/dev/null || fail "Claude one-free-account usability mismatch"
printf 'free\n' >"$USABLE_STORE/disabled"
claude_disabled=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude disabled-account usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_disabled" >/dev/null || fail "Disabled under-limit account must not make Claude usable"
jq -e '.vendors.claude.accounts[] | select(.account == "free") |
  .enabled == false and .blocked == true and
  .rotation == {usable:{general:true,fable:false}}' <<<"$claude_disabled" >/dev/null \
  || fail "a pool-excluded account must read blocked while its live auth still reads usable"
rm "$USABLE_STORE/disabled"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"auth":{"status":"expired"}}\n' \
  "$((now + 5000))" "$((now + 9000))" >"$USABLE_STORE/limits/free.json"
claude_expired_auth=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude expired-auth usability collection failed"
jq -e '.vendors.claude.usable_now == false' <<<"$claude_expired_auth" >/dev/null || fail "Expired-auth under-limit account must not make Claude usable"
rm "$USABLE_STORE/limits/free.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s},"fable":{"used_percentage":100,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$((now + 9000))" "$((now + 6000))" "$now" >"$USABLE_STORE/limits/full.json"
claude_fable=$(HOME="$USABLE_HOME" CLAUDEB_DIR="$USABLE_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Claude fable usability collection failed"
jq -e '.vendors.claude.fable.effective_pct == 100 and .vendors.claude.usable_now == true' <<<"$claude_fable" >/dev/null || fail "Fable exhaustion must not block general Claude work"
jq -e '.vendors.claude.accounts[0].rotation.usable.fable == true' <<<"$claude_fable" >/dev/null \
  || fail "numeric Fable snapshot was not marked Fable-capable"

PLAN_BIN="$WORK/plan-bin"
PLAN_HOME="$WORK/plan-home"
PLAN_STORE="$WORK/plan-store"
mkdir -p "$PLAN_BIN" "$PLAN_HOME/.claude-profiles" "$PLAN_STORE/limits"
printf 'pro\n' >"$PLAN_STORE/.claudeb-state"
cat >"$PLAN_BIN/security" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -w "*) printf '{"claudeAiOauth":{"subscriptionType":"%s"}}\n' "$PLAN_TYPE" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$PLAN_BIN/security"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s},"fable":{"used_percentage":42,"resets_at":%s},"auth":{"status":"ok"}}\n' \
  "$((now + 5000))" "$((now + 6000))" >"$PLAN_STORE/limits/pro.json"
pro_plan=$(PLAN_TYPE=pro PATH="$PLAN_BIN:$PATH" HOME="$PLAN_HOME" CLAUDE_PROFILES_DIR="$PLAN_HOME/.claude-profiles" \
  CLAUDEB_DIR="$PLAN_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) \
  || fail "Pro-plan Fable fixture collection failed"
jq -e '.vendors.claude.accounts[] | select(.account == "pro") |
  .plan_type == "pro" and .rotation.usable.fable == false' <<<"$pro_plan" >/dev/null \
  || fail "Pro-plan account with numeric Fable snapshot remained Fable-capable"
rm -f "$PLAN_STORE/limits/pro.json"
printf 'team\n' >"$PLAN_STORE/.claudeb-state"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s},"fable":{"used_percentage":42,"resets_at":%s},"auth":{"status":"ok"}}\n' \
  "$((now + 5000))" "$((now + 6000))" >"$PLAN_STORE/limits/team.json"
team_plan=$(PLAN_TYPE=team PATH="$PLAN_BIN:$PATH" HOME="$PLAN_HOME" CLAUDE_PROFILES_DIR="$PLAN_HOME/.claude-profiles" \
  CLAUDEB_DIR="$PLAN_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) \
  || fail "non-Pro-plan Fable fixture collection failed"
jq -e '.vendors.claude.accounts[] | select(.account == "team") |
  .plan_type == "team" and .rotation.usable.fable == true' <<<"$team_plan" >/dev/null \
  || fail "non-Pro account with numeric Fable snapshot was not Fable-capable"

printf '{"timestamp":"%s","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"resets_at":%s},"secondary":{"used_percent":40,"resets_at":%s}}}}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$((now + 5000))" "$((now + 9000))" >"$USABLE_HOME/.codex/sessions/rollout-full.jsonl"
codex_full=$(HOME="$USABLE_HOME" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "Codex exhausted usability collection failed"
jq -e '.vendors.codex.five_hour.effective_pct == 100 and .vendors.codex.usable_now == false' <<<"$codex_full" >/dev/null || fail "Codex exhausted usability mismatch"

FORMAT_STORE="$WORK/reset-format-store"
FORMAT_HOME="$WORK/reset-format-home"
mkdir -p "$FORMAT_STORE/limits" "$FORMAT_STORE/tokens" "$FORMAT_HOME"
printf 'clock\n' >"$FORMAT_STORE/.claudeb-state"
clock_epoch=$(( $(date +%s) + 3600 ))
weekday_epoch=$(( clock_epoch + 172800 ))
date_epoch=$(( clock_epoch + 691200 ))
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$clock_epoch" >"$FORMAT_STORE/limits/clock.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s}}\n' "$weekday_epoch" >"$FORMAT_STORE/limits/weekday.json"
printf '{"five_hour":{"used_percentage":30,"resets_at":%s}}\n' "$date_epoch" >"$FORMAT_STORE/limits/date.json"
touch "$FORMAT_STORE/tokens/clock" "$FORMAT_STORE/tokens/weekday" "$FORMAT_STORE/tokens/date"
clock_text=$(date -r "$clock_epoch" '+%H:%M')
weekday_num=$(date -r "$weekday_epoch" '+%w')
weekdays=(Sun Mon Tue Wed Thu Fri Sat)
weekday_text="${weekdays[$weekday_num]} $(date -r "$weekday_epoch" '+%H:%M')"
date_text=$(date -r "$date_epoch" '+%m-%d %H:%M')
format_table=$(HOME="$FORMAT_HOME" CLAUDEB_DIR="$FORMAT_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --table) || fail "reset-format table fixture failed"
format_plain=$(HOME="$FORMAT_HOME" CLAUDEB_DIR="$FORMAT_STORE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --plain) || fail "reset-format plain fixture failed"
claudeb_plain=$(HOME="$FORMAT_HOME" CLAUDEB_DIR="$FORMAT_STORE" bash "$ROOT/bin/claudeb" status --cached --plain) || fail "claudeb reset-format fixture failed"
for rendered in "$clock_text" "$weekday_text" "$date_text"; do
  grep -Fq "$rendered" <<<"$format_table" || fail "table reset tier missing: $rendered"
  grep -Fq "$rendered" <<<"$format_plain" || fail "plain reset tier missing: $rendered"
  grep -Fq "$rendered" <<<"$claudeb_plain" || fail "claudeb reset tier missing: $rendered"
done

XMID_STORE="$WORK/xmid-store"
XMID_HOME="$WORK/xmid-home"
mkdir -p "$XMID_STORE/limits" "$XMID_STORE/tokens" "$XMID_HOME"
printf 'sameday\n' >"$XMID_STORE/.claudeb-state"
pinned_now=$(date -j -f '%Y-%m-%d %H:%M:%S' '2027-01-15 12:00:00' '+%s')
sameday_epoch=$(( pinned_now + 14400 ))
crossmid_epoch=$(( pinned_now + 72000 ))
farweek_epoch=$(( pinned_now + 259200 ))
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' "$sameday_epoch" >"$XMID_STORE/limits/sameday.json"
printf '{"five_hour":{"used_percentage":20,"resets_at":%s}}\n' "$crossmid_epoch" >"$XMID_STORE/limits/crossmid.json"
printf '{"five_hour":{"used_percentage":30,"resets_at":%s}}\n' "$farweek_epoch" >"$XMID_STORE/limits/farweek.json"
touch "$XMID_STORE/tokens/sameday" "$XMID_STORE/tokens/crossmid" "$XMID_STORE/tokens/farweek"
sameday_bare=$(date -r "$sameday_epoch" '+%H:%M')
sameday_daytext="${weekdays[$(date -r "$sameday_epoch" '+%w')]} $sameday_bare"
crossmid_text="${weekdays[$(date -r "$crossmid_epoch" '+%w')]} $(date -r "$crossmid_epoch" '+%H:%M')"
farweek_text="${weekdays[$(date -r "$farweek_epoch" '+%w')]} $(date -r "$farweek_epoch" '+%H:%M')"
xmid_table=$(HOME="$XMID_HOME" CLAUDEB_DIR="$XMID_STORE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_NOW="$pinned_now" bash "$SCRIPT" --table) || fail "cross-midnight table fixture failed"
xmid_plain=$(HOME="$XMID_HOME" CLAUDEB_DIR="$XMID_STORE" LLM_LIMITS_CACHE="$CACHE" LLM_LIMITS_NOW="$pinned_now" bash "$SCRIPT" --plain) || fail "cross-midnight plain fixture failed"
xmid_claudeb=$(HOME="$XMID_HOME" CLAUDEB_DIR="$XMID_STORE" CLAUDEB_NOW="$pinned_now" bash "$ROOT/bin/claudeb" status --cached --plain) || fail "cross-midnight claudeb fixture failed"
for surface_name in table plain claudeb; do
  case "$surface_name" in
    table) surface="$xmid_table" ;;
    plain) surface="$xmid_plain" ;;
    claudeb) surface="$xmid_claudeb" ;;
  esac
  grep -Fq "$crossmid_text" <<<"$surface" || fail "$surface_name: within-24h cross-midnight reset lacks the day marker ($crossmid_text)"
  grep -Fq "$sameday_bare" <<<"$surface" || fail "$surface_name: same-day reset lost its bare clock time ($sameday_bare)"
  grep -Fq "$sameday_daytext" <<<"$surface" && fail "$surface_name: same-day reset wrongly gained a day marker ($sameday_daytext)"
  grep -Fq "$farweek_text" <<<"$surface" || fail "$surface_name: >24h reset tier changed ($farweek_text)"
done

# Header-origin week must render unknown, not as a number that walls the account.
PROV_STORE="$WORK/prov-store"
mkdir -p "$PROV_STORE/limits" "$PROV_STORE/tokens"
printf 'prov\n' >"$PROV_STORE/.claudeb-state"
: >"$PROV_STORE/tokens/prov"
printf '{"five_hour":{"used_percentage":5,"resets_at":%s,"as_of":%s,"origin":"headers"},"seven_day":{"used_percentage":100,"resets_at":%s,"as_of":%s,"origin":"headers"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$now" "$((now + 300000))" "$now" "$now" >"$PROV_STORE/limits/prov.json"
prov_json=$(CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null) \
  || fail "header-origin weekly fixture failed"
jq -e '.vendors.claude.accounts[0] | (.weekly == null) and .five_hour.used_pct == 5' <<<"$prov_json" >/dev/null \
  || fail "a header-origin weekly bucket was reported instead of being dropped"
printf '{"five_hour":{"used_percentage":5,"resets_at":%s,"as_of":%s,"origin":"headers"},"seven_day":{"used_percentage":76,"resets_at":%s,"as_of":%s,"origin":"session"},"auth":{"status":"ok","checked_at":%s}}\n' \
  "$((now + 5000))" "$now" "$((now + 300000))" "$now" "$now" >"$PROV_STORE/limits/prov.json"
prov_measured=$(CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null) \
  || fail "session-origin weekly fixture failed"
jq -e '.vendors.claude.accounts[0].weekly.used_pct == 76' <<<"$prov_measured" >/dev/null \
  || fail "a measured weekly reading was dropped"

EXP_REG="$WORK/experiments.json"
EXP_MARKER="$WORK/experiment-marker"
printf '{"until":9999999999,"reason":"fixture"}\n' >"$EXP_MARKER"
printf '[{"id":"trial-x","what":"fixture experiment for the banner contract","started":"2026-01-01","review_by":"2999-01-01","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
exp_json=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null) \
  || fail "experiment-registry fixture failed"
jq -e '.experiments == []' <<<"$exp_json" >/dev/null \
  || fail "an in-date experiment must stay off the banner"
exp_table=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --table --no-write 2>/dev/null)
! grep -Fq 'EXPERIMENT trial-x' <<<"$exp_table" || fail "--table announced an in-date experiment"
printf '[{"id":"undated","what":"fixture experiment with no review date","started":"2026-01-01","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
exp_undated=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.experiments == ["EXPERIMENT undated until  — temporary, see EXPERIMENTS.json"]' <<<"$exp_undated" >/dev/null \
  || fail "an experiment without review_by must keep announcing (it can never go OVERDUE)"
printf '[{"id":"spent","what":"fixture experiment whose review date has passed","started":"2026-01-01","review_by":"2026-01-02","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
exp_past=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.experiments == ["EXPERIMENT spent OVERDUE since 2026-01-02 — decide: remove or extend (EXPERIMENTS.json)"]' <<<"$exp_past" >/dev/null \
  || fail "an overdue-but-live experiment is not announced as OVERDUE"

printf '[{"id":"broken",,}]\n' >"$EXP_REG"
exp_broken=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.experiments | length == 1 and (.[0] | startswith("EXPERIMENT registry unreadable"))' <<<"$exp_broken" >/dev/null \
  || fail "an unreadable experiment registry was silently reported as no experiments"

printf '[{"id":"trial-x","what":"fixture experiment for the banner contract","started":"2026-01-01","review_by":"2999-01-01","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
for spent_until in -1 1.5; do
  printf '{"until":%s,"reason":"fixture"}\n' "$spent_until" >"$EXP_MARKER"
  exp_numeric=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
  jq -e '.experiments == []' <<<"$exp_numeric" >/dev/null \
    || fail "a marker with until=$spent_until is spent but still announced"
done

printf '{"until":1,"reason":"fixture"}\n' >"$EXP_MARKER"
printf '[{"id":"resumed","what":"fixture experiment whose marker has expired","started":"2026-01-01","review_by":"2999-01-01","state_marker":"%s","surfaces":["fixture"],"how_to_remove":"delete the fixture"}]\n' "$EXP_MARKER" >"$EXP_REG"
exp_spent_marker=$(EXPERIMENTS_REGISTRY="$EXP_REG" CLAUDEB_DIR="$PROV_STORE" LLM_LIMITS_CACHE="$WORK/prov-cache.json" bash "$SCRIPT" --no-write 2>/dev/null)
jq -e '.experiments == []' <<<"$exp_spent_marker" >/dev/null || fail "an expired marker is still being announced"

# Account order in the cache is the order every surface renders: the hardcoded primaries first,
# then oldest profile directory first, and an account with no directory (hence no birth time) last
# by name. `current` no longer buys a place in that order — it is carried by is_current instead.
ORDER_HOME="$WORK/order-home"
ORDER_STORE="$WORK/order-claudeb-store"
mkdir -p "$ORDER_HOME/.claude" "$ORDER_HOME/.claude-profiles" "$ORDER_STORE/limits"
# Created youngest-name-first so a passing order cannot also be the alphabet.
for order_profile in zed mid abe com notcom; do
  mkdir -p "$ORDER_HOME/.claude-profiles/$order_profile"
  sleep 1
done
for order_account in zed mid abe com notcom ghosta ghostb; do
  order_pct=5
  # The current account is neither first in render order nor the only one with data, so a
  # vendor-level five_hour of 42 can only have come from the current account itself.
  [ "$order_account" != mid ] || order_pct=42
  printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"auth":{"status":"ok","checked_at":%s}}\n' \
    "$order_pct" "$((now + 5000))" "$now" >"$ORDER_STORE/limits/$order_account.json"
done
printf 'mid\n' >"$ORDER_STORE/.claudeb-state"
order_claude=$(HOME="$ORDER_HOME" CLAUDEB_DIR="$ORDER_STORE" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --json) || fail "claude account-order collection failed"
jq -e '[.vendors.claude.accounts[].account] ==
  ["notcom","com","zed","mid","abe","ghosta","ghostb"]' <<<"$order_claude" >/dev/null \
  || fail "claude accounts are not ordered priority-first, then by profile birth time, unknowns last"
jq -e '.vendors.claude.current_account == "mid" and
  ([.vendors.claude.accounts[] | select(.is_current)] | length) == 1 and
  [.vendors.claude.accounts[] | select(.is_current)][0].account == "mid"' <<<"$order_claude" >/dev/null \
  || fail "claude current account was not decoupled from the array order"
jq -e '.vendors.claude.five_hour ==
  ([.vendors.claude.accounts[] | select(.is_current)][0].five_hour) and
  .vendors.claude.five_hour.used_pct == 42' <<<"$order_claude" >/dev/null \
  || fail "the vendor five_hour hoist took the first ordered account instead of the current one"
order_claude_table=$(HOME="$ORDER_HOME" CLAUDEB_DIR="$ORDER_STORE" LLM_LIMITS_CACHE="$CACHE" \
  bash "$SCRIPT" --table) || fail "claude account-order table failed"
[ "$(awk 'NR > 1 && $1 ~ /^claude\// {sub(/\*$/, "", $1); print $1}' <<<"$order_claude_table" | paste -sd, -)" \
  = "claude/notcom,claude/com,claude/zed,claude/mid,claude/abe,claude/ghosta,claude/ghostb" ] \
  || fail "the table did not render claude accounts in cache order"

ORDER_CODEX_HOME="$WORK/order-codex-home"
ORDER_CODEX_CACHE="$WORK/order-codex-cache.json"
mkdir -p "$ORDER_CODEX_HOME/.codex"
for order_profile in zed abe; do
  mkdir -p "$ORDER_CODEX_HOME/.codex-profiles/$order_profile"
  sleep 1
done
cat >"$ORDER_CODEX_CACHE" <<EOF
{"accounts":[{"account":"abe","five_hour":{"used_pct":3,"resets_at":$((now + 5000))},"weekly":{"used_pct":4,"resets_at":$((now + 90000))},"as_of":$now},{"account":"ghost","five_hour":{"used_pct":5,"resets_at":$((now + 5000))},"weekly":{"used_pct":6,"resets_at":$((now + 90000))},"as_of":$now},{"account":"zed","five_hour":{"used_pct":7,"resets_at":$((now + 5000))},"weekly":{"used_pct":8,"resets_at":$((now + 90000))},"as_of":$now},{"account":"main","five_hour":{"used_pct":9,"resets_at":$((now + 5000))},"weekly":{"used_pct":10,"resets_at":$((now + 90000))},"as_of":$now}],"current":"abe"}
EOF
order_codex=$(HOME="$ORDER_CODEX_HOME" LLM_LIMITS_CODEX_CACHE="$ORDER_CODEX_CACHE" \
  LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) || fail "codex account-order collection failed"
jq -e '[.vendors.codex.accounts[].account] == ["main","zed","abe","ghost"] and
  .vendors.codex.current_account == "abe"' <<<"$order_codex" >/dev/null \
  || fail "codex accounts are not ordered main-first, then by profile birth time, unknowns last"

ORDER_GEMINI_PROFILES="$WORK/order-gemini-profiles"
ORDER_GEMINI_CACHE_DIR="$WORK/order-gemini-cache"
mkdir -p "$ORDER_GEMINI_CACHE_DIR"
for order_profile in zed abe com; do
  mkdir -p "$ORDER_GEMINI_PROFILES/$order_profile"
  sleep 1
done
order_gemini_snapshot='{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.5,"resetTime":"2099-01-01T00:00:00Z"},{"window":"5h","remainingFraction":0.6,"resetTime":"2099-01-01T00:00:00Z"}]}]}'
for order_account in zed abe com; do
  printf '%s\n' "$order_gemini_snapshot" >"$ORDER_GEMINI_CACHE_DIR/$order_account.json"
done
printf '%s\n' "$order_gemini_snapshot" >"$WORK/order-gemini-main.json"
order_gemini=$(GEMINIB_PROFILES_DIR="$ORDER_GEMINI_PROFILES" \
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$ORDER_GEMINI_CACHE_DIR" \
  LLM_LIMITS_GEMINI_CACHE="$WORK/order-gemini-main.json" \
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$CACHE" bash "$SCRIPT" --json) \
  || fail "gemini account-order collection failed"
jq -e '[.vendors.gemini.accounts[].account] == ["com","main","zed","abe"]' <<<"$order_gemini" >/dev/null \
  || fail "gemini accounts are not ordered priority-first, then by profile birth time"

# The final merge sees vendor data read before the store lock, so a racing writer's newer row has
# to survive it per account — while the local state this run read stays authoritative.
MERGE_PROFILES="$WORK/merge-gemini-profiles"
MERGE_CACHE_DIR="$WORK/merge-gemini-cache"
MERGE_CACHE="$WORK/merge-cache.json"
mkdir -p "$MERGE_PROFILES/alpha" "$MERGE_PROFILES/beta" "$MERGE_PROFILES/gamma" "$MERGE_CACHE_DIR"
for merge_account in alpha beta gamma; do
  printf '%s\n' "$order_gemini_snapshot" >"$MERGE_CACHE_DIR/$merge_account.json"
done
printf '%s\n' "$order_gemini_snapshot" >"$WORK/merge-gemini-main.json"
merge_env=(GEMINIB_PROFILES_DIR="$MERGE_PROFILES"
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$MERGE_CACHE_DIR"
  LLM_LIMITS_GEMINI_CACHE="$WORK/merge-gemini-main.json"
  HOME="$HOME_FIXTURE" LLM_LIMITS_CACHE="$MERGE_CACHE")
env "${merge_env[@]}" bash "$SCRIPT" --json >/dev/null || fail "merge fixture collection failed"
jq --argjson future "$((now + 5000))" '.vendors.gemini.accounts |= map(
  if .account == "beta" then
    .race_marker = "older" | .five_hour.as_of = 1 | .weekly.as_of = 1 |
    .as_of = "2000-01-01T00:00:00Z" | del(.as_of_epoch)
  elif .account == "alpha" or .account == "gamma" then
    .race_marker = "newer" | .five_hour.as_of = $future | .weekly.as_of = $future |
    (if .account == "alpha" then .blocked = true | .is_current = true else . end)
  else . end)' "$MERGE_CACHE" >"$WORK/merge-cache.tmp" || fail "merge fixture edit failed"
mv "$WORK/merge-cache.tmp" "$MERGE_CACHE"
# gamma logs out between the two collects: its newer stored row is kept, its auth verdict is not.
printf '{"auth_needed":true}\n' >"$MERGE_CACHE_DIR/gamma.json"
env "${merge_env[@]}" bash "$SCRIPT" --json >/dev/null || fail "merge collection failed"
jq -e '([.vendors.gemini.accounts[].account] | sort) == ["alpha","beta","gamma","main"]' \
  "$MERGE_CACHE" >/dev/null || fail "the merge changed the account set"
jq -e 'first(.vendors.gemini.accounts[] | select(.account == "alpha")) | .race_marker == "newer"' \
  "$MERGE_CACHE" >/dev/null || fail "a strictly newer stored row was overwritten with older data"
jq -e 'first(.vendors.gemini.accounts[] | select(.account == "alpha")) |
  (has("blocked") | not) and .is_current == false' "$MERGE_CACHE" >/dev/null || \
  fail "a kept stored row carried stale local pool state past this collect's fresh verdicts"
jq -e 'first(.vendors.gemini.accounts[] | select(.account == "beta")) | has("race_marker") | not' \
  "$MERGE_CACHE" >/dev/null || fail "an older stored row survived the merge"
jq -e 'first(.vendors.gemini.accounts[] | select(.account == "gamma")) |
  .race_marker == "newer" and .auth_needed == true' "$MERGE_CACHE" >/dev/null || \
  fail "a kept stored row buried the login-needed verdict of this collect"

# A bare vendor name means "every account of this vendor, free" and must leave the other vendors
# untouched: their probes never run and their cached data survives the run.
VENDOR_SCOPE_LOG="$WORK/vendor-scope-gemini.log"
cat >"$WORK/vendor-scope-agy" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$HOME" >>"$VENDOR_SCOPE_LOG"
printf '%s\n' '$order_gemini_snapshot'
EOF
CODEX_SCOPE_SENTINEL="$WORK/codex-scope-called"
cat >"$WORK/vendor-scope-codex" <<EOF
#!/usr/bin/env bash
printf 'called %s\n' "\$*" >>"$CODEX_SCOPE_SENTINEL"
printf '%s\n' '{"accounts":[{"account":"main","five_hour":{"used_pct":9,"resets_at":$((now + 5000))},"weekly":{"used_pct":10,"resets_at":$((now + 90000))},"as_of":$now}],"current":"main"}'
EOF
CLAUDEB_SCOPE_SENTINEL="$WORK/claudeb-scope-called"
cat >"$WORK/vendor-scope-claudeb" <<EOF
#!/usr/bin/env bash
printf 'called %s\n' "\$*" >>"$CLAUDEB_SCOPE_SENTINEL"
exit 0
EOF
chmod +x "$WORK/vendor-scope-agy" "$WORK/vendor-scope-codex" "$WORK/vendor-scope-claudeb"
vendor_scope_env=(GEMINIB_PROFILES_DIR="$ORDER_GEMINI_PROFILES"
  LLM_LIMITS_GEMINI_ACCOUNTS_DIR="$ORDER_GEMINI_CACHE_DIR"
  LLM_LIMITS_GEMINI_CACHE="$WORK/order-gemini-main.json"
  LLM_LIMITS_GEMINI_CMD="$WORK/vendor-scope-agy"
  LLM_LIMITS_CODEX_QUOTA_CMD="$WORK/vendor-scope-codex"
  LLM_LIMITS_CODEX_CACHE="$WORK/vendor-scope-codex-cache.json"
  LLM_LIMITS_CLAUDEB_CMD="$WORK/vendor-scope-claudeb"
  GEMINIB_SECURITY_CMD="$GEMINI_SECURITY_STUB"
  CLAUDEB_DIR="$ORDER_STORE" HOME="$ORDER_HOME" LLM_LIMITS_CACHE="$CACHE")
env "${vendor_scope_env[@]}" LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_CODEX_REFRESH=1 \
  bash "$SCRIPT" --refresh-account gemini --json >/dev/null 2>&1 \
  || fail "vendor-scoped gemini refresh failed"
[ "$(sort "$VENDOR_SCOPE_LOG" | paste -sd, -)" \
  = "$ORDER_GEMINI_PROFILES/abe,$ORDER_GEMINI_PROFILES/com,$ORDER_GEMINI_PROFILES/zed,$ORDER_HOME" ] \
  || fail "--refresh-account gemini did not refresh every gemini account: $(cat "$VENDOR_SCOPE_LOG")"
[ ! -e "$CODEX_SCOPE_SENTINEL" ] || fail "--refresh-account gemini also probed codex"
[ ! -e "$CLAUDEB_SCOPE_SENTINEL" ] || fail "--refresh-account gemini also probed claude"
: >"$VENDOR_SCOPE_LOG"
env "${vendor_scope_env[@]}" LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_CODEX_REFRESH=1 \
  bash "$SCRIPT" --refresh-account codex --json >/dev/null 2>&1 \
  || fail "vendor-scoped codex refresh failed"
grep -q -- '--all-accounts' "$CODEX_SCOPE_SENTINEL" \
  || fail "--refresh-account codex did not run the all-accounts helper path"
[ ! -s "$VENDOR_SCOPE_LOG" ] || fail "--refresh-account codex also probed gemini"
[ ! -e "$CLAUDEB_SCOPE_SENTINEL" ] || fail "--refresh-account codex also probed claude"
rm -f "$CODEX_SCOPE_SENTINEL"
env "${vendor_scope_env[@]}" LLM_LIMITS_GEMINI_REFRESH=1 LLM_LIMITS_CODEX_REFRESH=1 \
  bash "$SCRIPT" --refresh-account claude --json >/dev/null 2>&1 \
  || fail "vendor-scoped claude refresh failed"
grep -q 'called accounts --no-spend' "$CLAUDEB_SCOPE_SENTINEL" \
  || fail "--refresh-account claude did not run the free all-account claudeb path"
[ ! -e "$CODEX_SCOPE_SENTINEL" ] || fail "--refresh-account claude also probed codex"
[ ! -s "$VENDOR_SCOPE_LOG" ] || fail "--refresh-account claude also probed gemini"
# A vendor-scoped refresh with no store to refresh from is a reason, never a silent no-op.
NO_STORE="$WORK/vendor-scope-no-store"
mkdir -p "$NO_STORE"
no_store_err=$(env "${vendor_scope_env[@]}" CLAUDEB_DIR="$NO_STORE" LLM_LIMITS_CACHE="$WORK/no-store-cache.json" \
  bash "$SCRIPT" --refresh-account claude --json 2>&1 >/dev/null)
grep -q 'no claudeb store' <<<"$no_store_err" \
  || fail "--refresh-account claude without a claudeb store said nothing"
jq -e '.vendors.claude.refresh_error.cause == "no claudeb store"' "$WORK/no-store-cache.json" >/dev/null \
  || fail "--refresh-account claude without a claudeb store recorded no refresh_error"
# The paid window-opening path stays a single-account request.
if env "${vendor_scope_env[@]}" bash "$SCRIPT" --refresh-account claude --start-windows \
  >/dev/null 2>&1; then
  fail "a bare vendor accepted --start-windows"
fi

echo "PASS: table sorts, truncated and expired rollouts, age alarm, usability, plans, reset formats, provenance, account order and merge, vendor-scoped --refresh-account"
