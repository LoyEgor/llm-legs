#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
eq() { [ "$1" = "$2" ] || { echo "  got '$1' want '$2'" >&2; return 1; }; }

. "$ROOT/share/limits-view.sh"

NOW=1750000000
DAY=86400

# Evaluates a jq expression against the shared defs with $now pinned to the suite clock.
v() { jq -n --argjson now "$NOW" "$LIMITS_VIEW_JQ""$1"; }
# Same, but the expression must itself evaluate true.
t() { jq -ne --argjson now "$NOW" "$LIMITS_VIEW_JQ""$1" >/dev/null; }

# --- limits_days_remaining ----------------------------------------------------
assert eq "$(v "limits_days_remaining(\$now + 5 * $DAY; \$now)")" 5
assert eq "$(v "limits_days_remaining(\$now + $DAY / 2; \$now)")" 0.5
assert eq "$(v 'limits_days_remaining($now; $now)')" 0
# A reset already behind us is a rolled-over window, not negative time.
assert eq "$(v 'limits_days_remaining($now - 3600; $now)')" 0
assert t 'limits_days_remaining($now - 3600; $now) >= 0'
# Sweep: no offset, forward or back, may produce a negative day count.
assert t "[range(-30; 30) | limits_days_remaining(\$now + . * $DAY; \$now)]
  | map(select(. != null)) | (length > 0) and all(. >= 0)"

# Garbage resets follow the rest of the file: placeholder epochs and dates the
# renderer refuses to print carry no schedule, so they answer null, not zero.
assert eq "$(v 'limits_days_remaining(null; $now)')" null
assert eq "$(v 'limits_days_remaining("tomorrow"; $now)')" null
assert eq "$(v 'limits_days_remaining(true; $now)')" null
assert eq "$(v 'limits_days_remaining(0; $now)')" null
assert eq "$(v 'limits_days_remaining(limits_reset_epoch_floor - 1; $now)')" null
assert eq "$(v "limits_days_remaining(\$now - 2 * $DAY; \$now)")" null
assert t "limits_reset_ancient(\$now; \$now - 2 * $DAY)
  and (limits_days_remaining(\$now - 2 * $DAY; \$now) == null)"
# Monotonic in the reset epoch: a later reset never means fewer days.
assert t "[range(0; 14) | limits_days_remaining(\$now + . * $DAY; \$now)] | . == sort"

# --- limits_daily_budget ------------------------------------------------------
# 50% of the window left over 5 days is 10 points a day.
assert eq "$(v 'limits_daily_budget(50; 5)')" 10
assert eq "$(v 'limits_daily_budget(0; 4)')" 25
assert eq "$(v 'limits_daily_budget(100; 4)')" 0

# Equal pct, different horizon: the account resetting tomorrow may spend faster.
assert eq "$(v "limits_daily_budget(40; limits_days_remaining(\$now + $DAY; \$now))")" 60
assert eq "$(v "limits_daily_budget(40; limits_days_remaining(\$now + 7 * $DAY; \$now))")" \
  8.571428571428571
assert t "limits_daily_budget(40; limits_days_remaining(\$now + $DAY; \$now))
  > limits_daily_budget(40; limits_days_remaining(\$now + 7 * $DAY; \$now))"
# Same horizon, different pct: more burned is less to spend.
assert t 'limits_daily_budget(20; 5) > limits_daily_budget(80; 5)'

# A reset in the past leaves zero days, and the 0.25 floor keeps the divide finite.
assert eq "$(v 'limits_daily_budget(20; limits_days_remaining($now - 3600; $now))')" 320
assert eq "$(v 'limits_daily_budget(20; 0)')" 320
assert eq "$(v 'limits_daily_budget(20; 0.25)')" 320
assert eq "$(v 'limits_daily_budget(20; 0.1)')" 320
assert t 'limits_daily_budget(20; 0) == limits_daily_budget(20; 0.25)'
# Below the floor the budget stops growing instead of running to infinity.
assert t '[0, 0.001, 0.1, 0.25] | map(limits_daily_budget(50; .)) | unique | length == 1'

# Null days is the neutral full week, not the floor.
assert eq "$(v 'limits_daily_budget(30; null)')" 10
assert eq "$(v 'limits_daily_budget(30; limits_days_remaining(null; $now))')" 10
assert eq "$(v "limits_daily_budget(30; limits_days_remaining(\$now - 2 * $DAY; \$now))")" 10
assert eq "$(v 'limits_daily_budget(30; "soon")')" 10
assert t 'limits_daily_budget(50; null) < limits_daily_budget(50; 0)'

# An unmeasured or non-numeric pct cannot be ranked and stays null.
assert eq "$(v 'limits_daily_budget(null; 5)')" null
assert eq "$(v 'limits_daily_budget(null; null)')" null
assert eq "$(v 'limits_daily_budget("50"; 5)')" null
assert eq "$(v 'limits_daily_budget(true; 5)')" null
assert eq "$(v 'limits_daily_budget([]; 5)')" null

# Out-of-range pct clamps into [0,100] before the subtraction, so the budget is
# never negative and never exceeds a full window.
assert eq "$(v 'limits_daily_budget(120; 5)')" 0
assert eq "$(v 'limits_daily_budget(1e9; 5)')" 0
assert eq "$(v 'limits_daily_budget(-40; 5)')" 20
assert t 'limits_daily_budget(-40; 5) == limits_daily_budget(0; 5)'
assert t 'limits_daily_budget(120; 5) == limits_daily_budget(100; 5)'
assert t '[range(-50; 151) | limits_daily_budget(.; 5)] | all(. >= 0 and . <= 20)'

# The defs are pure: same inputs, same answer.
assert t 'limits_daily_budget(50; 5) == limits_daily_budget(50; 5)'
assert t "limits_days_remaining(\$now + $DAY; \$now) == limits_days_remaining(\$now + $DAY; \$now)"

echo "PASS: $asserts asserts; limits_days_remaining floors at 0 and answers null for placeholder, non-numeric and ancient resets while staying monotonic in the reset epoch, and limits_daily_budget clamps pct into [0,100], divides by a 0.25-day floor, treats null/non-numeric days as a neutral 7-day window, orders a reset tomorrow above one a week out at equal pct, and answers null for an unmeasured pct"
