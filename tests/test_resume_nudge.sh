#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${RESUME_NUDGE_HOOK:-$HOME/.claude/hooks/resume-timer-nudge.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$HOOK" ] || fail "resume nudge hook is not executable: $HOOK"

mtime_probe="$WORK/mtime-probe"
touch "$mtime_probe"
RESUME_NUDGE_SOURCE_ONLY=1 source "$HOOK"
unset RESUME_NUDGE_SOURCE_ONLY
helper_mtime=$(file_mtime "$mtime_probe") || fail "file_mtime helper failed"
expected_mtime=$(stat -f %m "$mtime_probe" 2>/dev/null || stat -c %Y "$mtime_probe" 2>/dev/null) \
  || fail "fixture mtime lookup failed"
[ "$helper_mtime" = "$expected_mtime" ] || fail "file_mtime helper returned the wrong value"

now=$(date +%s)
future=$((now + 3600))
past=$((now - 1))

run_hook() {
  local fixture=$1 suffix=$2
  printf '{"session_id":"resume-nudge-test-%s-%s"}\n' "$$" "$suffix" |
    HOME="$WORK/home" LLM_LIMITS_FILE="$fixture" CLAUDE_LIMITS_ACCOUNT=fixture \
      RESUME_NUDGE_PCT=95 bash "$HOOK"
}

write_fixture() {
  local file=$1 account_age=$2 bucket_age=$3 five_pct=$4 five_reset=$5 fable=$6
  jq -n --argjson now "$now" --argjson account_age "$account_age" \
    --argjson bucket_age "$bucket_age" --argjson five_pct "$five_pct" \
    --argjson five_reset "$five_reset" --argjson fable "$fable" '
    {fetched_at:"2099-01-01T00:00:00Z",vendors:{claude:{accounts:[{
      account:"fixture",as_of:($now - $account_age),stale_seconds:$account_age,
      five_hour:{used_pct:$five_pct,effective_pct:$five_pct,resets_at:$five_reset,
        as_of:($now - $bucket_age),stale:false}
    } + (if $fable == null then {} else {fable:$fable} end)]}}}' >"$file"
}

offset_reset() {
  local epoch=$1 shifted
  shifted=$((epoch + 10800))
  date -u -r "$shifted" '+%Y-%m-%dT%H:%M:%S+03:00' 2>/dev/null \
    || date -u -d "@$shifted" '+%Y-%m-%dT%H:%M:%S+03:00'
}

write_offset_fixture() {
  local file=$1 reset=$2
  jq -n --argjson now "$now" --arg reset "$reset" '
    {fetched_at:"2099-01-01T00:00:00Z",vendors:{claude:{accounts:[{
      account:"fixture",as_of:($now - 60),stale_seconds:60,
      five_hour:{used_pct:97,effective_pct:97,resets_at:$reset,
        as_of:($now - 60),stale:false}
    }]}}}' >"$file"
}

fable_fixture="$WORK/fable.json"
write_fixture "$fable_fixture" 120 120 100 "$future" \
  "$(jq -n --argjson now "$now" --argjson future "$future" \
    '{used_pct:96,effective_pct:96,resets_at:$future,as_of:($now - 120),stale:false}')"
output=$(run_hook "$fable_fixture" fable) || fail "fresh fable fixture invocation failed"
jq -e '.hookSpecificOutput.additionalContext |
  contains("fable segment is at 96% (data 2m old") and
  contains("CONFIRM before acting") and contains("llm-limits.sh --refresh") and
  contains("only then arm `claude-resume-timer auto`")' <<<"$output" >/dev/null \
  || fail "fresh fable nudge lacks segment, age, or confirmation instructions"

five_fixture="$WORK/five.json"
write_fixture "$five_fixture" 120 120 97 "$future" null
output=$(run_hook "$five_fixture" five) || fail "fresh 5h fixture invocation failed"
jq -e '.hookSpecificOutput.additionalContext | contains("5h segment is at 97% (data 2m old")' \
  <<<"$output" >/dev/null || fail "fresh 5h nudge lacks segment or age"

fresh_lock="/tmp/claude-resume-timer-nudge-resume-nudge-test-$$-fresh-lock.lock"
mkdir "$fresh_lock"
[ -z "$(run_hook "$five_fixture" fresh-lock)" ] || fail "fresh lock was not honored"
[ -d "$fresh_lock" ] || fail "fresh lock was reclaimed"
rmdir "$fresh_lock"

stale_lock="/tmp/claude-resume-timer-nudge-resume-nudge-test-$$-stale-lock.lock"
mkdir "$stale_lock"
touch -t 202001010000 "$stale_lock"
output=$(run_hook "$five_fixture" stale-lock) || fail "stale lock fixture invocation failed"
jq -e '.hookSpecificOutput.additionalContext | contains("5h segment is at 97%")' \
  <<<"$output" >/dev/null || fail "stale lock was not reclaimed for a nudge"
[ ! -d "$stale_lock" ] || fail "reclaimed lock was not released"

future_offset=$(offset_reset "$future") || fail "future offset timestamp creation failed"
future_offset_fixture="$WORK/future-offset.json"
write_offset_fixture "$future_offset_fixture" "$future_offset"
output=$(run_hook "$future_offset_fixture" future-offset) || fail "future offset fixture invocation failed"
jq -e --arg reset "$future_offset" '.hookSpecificOutput.additionalContext | contains("resets " + $reset)' \
  <<<"$output" >/dev/null || fail "future offset timestamp did not nudge"

past_offset=$(offset_reset "$past") || fail "past offset timestamp creation failed"
past_offset_fixture="$WORK/past-offset.json"
write_offset_fixture "$past_offset_fixture" "$past_offset"
[ -z "$(run_hook "$past_offset_fixture" past-offset)" ] || fail "past offset timestamp bypassed rollover gate"

stale_account="$WORK/stale-account.json"
write_fixture "$stale_account" 1801 60 97 "$future" null
[ -z "$(run_hook "$stale_account" stale-account)" ] || fail "stale account frame nudged"

stale_bucket="$WORK/stale-bucket.json"
write_fixture "$stale_bucket" 60 1801 97 "$future" null
[ -z "$(run_hook "$stale_bucket" stale-bucket)" ] || fail "stale triggering bucket nudged"

rolled="$WORK/rolled.json"
write_fixture "$rolled" 60 60 97 "$past" null
[ -z "$(run_hook "$rolled" rolled)" ] || fail "rolled-over bucket nudged"

under="$WORK/under.json"
write_fixture "$under" 60 60 94 "$future" null
[ -z "$(run_hook "$under" under)" ] || fail "under-threshold bucket nudged"

echo "PASS: resume nudge mtime helper, stale/fresh locks, offset resets, freshness, segment, age, rollover, threshold, and confirm-first contract"
