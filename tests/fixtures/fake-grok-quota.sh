#!/usr/bin/env bash
# Stands in for grok-quota.py wherever a test drives llm-limits.sh (LLM_LIMITS_GROK_QUOTA), so no
# test ever reaches the real billing endpoint or the owner's ~/.grok-profiles. FAKE_GROK_CASE picks
# the canned answer; the raw endpoint bodies are exercised against the real helper in
# tests/test_grok_quota.sh.
set -u

[ -z "${GROK_QUOTA_SENTINEL:-}" ] || printf '%s\n' "$*" >>"$GROK_QUOTA_SENTINEL"

as_of=${FAKE_GROK_AS_OF:-$(date +%s)}
reset=${FAKE_GROK_RESET:-2099-09-06T14:50:11Z}
case=${FAKE_GROK_CASE:-busy}

names=''
while [ $# -gt 0 ]; do
  case "$1" in
    --account) shift; names="$names ${1:-}" ;;
  esac
  shift
done
[ -n "$names" ] || names=${FAKE_GROK_ROSTER:-supergrok}

# A leg with no accounts at all, and a helper that dies before writing a payload: both answer
# nothing on stdout, and only the second is a failure.
if [ "$case" = empty_roster ]; then
  printf '{"accounts":[]}\n'
  exit 1
fi
if [ "$case" = helper_crash ]; then
  printf 'grok-quota.py: RuntimeError: the helper died before printing\n' >&2
  exit 1
fi

row() {
  case "$case" in
    # The owner's fresh account: the endpoint omits creditUsagePercent at 0 and names no tier.
    zero) printf '{"account":"%s","auth":"ok","used_pct":0,"resets_at":"%s","period":"USAGE_PERIOD_TYPE_WEEKLY","email":"owner@example.com","as_of":%s}' "$1" "$reset" "$as_of" ;;
    zero_with_build) printf '{"account":"%s","auth":"ok","used_pct":0,"resets_at":"%s","period":"USAGE_PERIOD_TYPE_WEEKLY","email":"owner@example.com","build_pct":18.5,"as_of":%s}' "$1" "$reset" "$as_of" ;;
    busy) printf '{"account":"%s","auth":"ok","used_pct":61.2,"resets_at":"%s","period":"USAGE_PERIOD_TYPE_WEEKLY","plan_type":"SUBSCRIPTION_TIER_SUPERGROK","email":"owner@example.com","build_pct":18.5,"as_of":%s}' "$1" "$reset" "$as_of" ;;
    # used_pct is creditUsagePercent; PRODUCT_GROK_BUILD is only build_pct, even when larger.
    credit_and_build) printf '{"account":"%s","auth":"ok","used_pct":10,"resets_at":"%s","period":"USAGE_PERIOD_TYPE_WEEKLY","plan_type":"SUBSCRIPTION_TIER_SUPERGROK","email":"owner@example.com","build_pct":90,"as_of":%s}' "$1" "$reset" "$as_of" ;;
    walled) printf '{"account":"%s","auth":"ok","used_pct":100,"resets_at":"%s","period":"USAGE_PERIOD_TYPE_WEEKLY","as_of":%s}' "$1" "$reset" "$as_of" ;;
    # The reset consumable the second endpoint reports, and the same count carried on a reading old
    # enough that no surface may act on it.
    with_resets) printf '{"account":"%s","auth":"ok","used_pct":61.2,"resets_at":"%s","period":"USAGE_PERIOD_TYPE_WEEKLY","email":"owner@example.com","reset_credits":1,"reset_credits_expires_at":"2099-09-12T18:49:00Z","as_of":%s}' "$1" "$reset" "$as_of" ;;
    stale_resets) printf '{"account":"%s","auth":"ok","used_pct":61.2,"resets_at":"%s","period":"USAGE_PERIOD_TYPE_WEEKLY","email":"owner@example.com","reset_credits":2,"reset_credits_as_of":%s,"reset_credits_expires_at":"2099-09-12T18:49:00Z","as_of":%s}' "$1" "$reset" "$((as_of - 90000))" "$as_of" ;;
    monthly) printf '{"account":"%s","auth":"ok","used_pct":12,"resets_at":"%s","period":"USAGE_PERIOD_TYPE_MONTHLY","as_of":%s}' "$1" "$reset" "$as_of" ;;
    no_period) printf '{"account":"%s","auth":"ok","used_pct":22.5,"resets_at":null,"email":"owner@example.com","as_of":%s}' "$1" "$as_of" ;;
    # A window name no surface knows: the percent still counts, and the period is carried as it came.
    bad_period) printf '{"account":"%s","auth":"ok","used_pct":33,"resets_at":null,"period":"USAGE_PERIOD_TYPE_UNSPECIFIED","email":"owner@example.com","as_of":%s}' "$1" "$as_of" ;;
    needs_login) printf '{"account":"%s","auth":"needs_login","as_of":%s}' "$1" "$as_of" ;;
    expired) printf '{"account":"%s","auth":"expired","cause":"token rejected: HTTP 401","as_of":%s}' "$1" "$as_of" ;;
    not_signed_in) printf '{"account":"%s","auth":"expired","cause":"token rejected: HTTP 401","as_of":%s}' "$1" "$as_of" ;;
    session_expired) printf '{"account":"%s","auth":"expired","cause":"token rejected: HTTP 401","as_of":%s}' "$1" "$as_of" ;;
    error) printf '{"account":"%s","error":"network error: timed out","as_of":%s}' "$1" "$as_of" ;;
    credit_limit) printf '{"account":"%s","auth":"ok","used_pct":100,"resets_at":null,"as_of":%s}' "$1" "$as_of" ;;
    unknown_402) printf '{"account":"%s","error":"HTTP 402","as_of":%s}' "$1" "$as_of" ;;
    too_many) printf '{"account":"%s","error":"HTTP 429","as_of":%s}' "$1" "$as_of" ;;
    unavailable) printf '{"account":"%s","error":"HTTP 503","as_of":%s}' "$1" "$as_of" ;;
    malformed) printf '{"account":"%s","error":"unparsable billing payload","as_of":%s}' "$1" "$as_of" ;;
    *) printf '{"account":"%s","error":"unknown fixture case %s","as_of":%s}' "$1" "$case" "$as_of" ;;
  esac
}

payload=''
for name in $names; do
  [ -z "$payload" ] || payload="$payload,"
  payload="$payload$(row "$name")"
done
printf '{"accounts":[%s]}\n' "$payload"

case "$case" in
  zero|zero_with_build|busy|credit_and_build|walled|credit_limit|monthly|no_period|bad_period) exit 0 ;;
  with_resets|stale_resets) exit 0 ;;
  needs_login|expired|not_signed_in|session_expired) exit 2 ;;
  *) printf 'fake-grok-quota.sh: %s\n' "$case" >&2; exit 1 ;;
esac
