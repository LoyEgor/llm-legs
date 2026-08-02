# limits-view.sh — the ONE definition of limit-bucket display semantics
# (shared-invariants row y): what makes a bucket stale or expired, which
# percentage a surface may show, and how a text surface labels it. Sourced by
# bin/claudeb and llm-limits.sh, which prepend $LIMITS_VIEW_JQ to their jq
# programs. The Hammerspoon menu renders the effective_pct/stale/expired fields
# the collector computed with these defs and must never re-derive them.

LIMITS_STALE_FIVE_HOUR=1800
LIMITS_STALE_WEEKLY=21600
LIMITS_STALE_FABLE=21600

# Reset epochs below one year are placeholder zeros, never real times.
LIMITS_VIEW_JQ='
def limits_reset_epoch_floor: 31536000;
def limits_bucket_expired($now; $reset):
  ($reset != null and $reset >= limits_reset_epoch_floor and $reset <= $now);
def limits_bucket_stale($now; $thr; $auth_expired; $origin; $asof):
  ($auth_expired or ($origin == "cached") or (($now - $asof) > $thr));
def limits_effective_pct($pct; $expired):
  (if $expired then 0 else $pct end);
def limits_reset_text($epoch; $now):
  if $epoch == null or $epoch < limits_reset_epoch_floor then "-"
  elif ($epoch - $now) < 604800 then
    (if ($epoch | strflocaltime("%Y-%m-%d")) != ($now | strflocaltime("%Y-%m-%d"))
     then (["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][$epoch | strflocaltime("%w") | tonumber]
           + " " + ($epoch | strflocaltime("%H:%M")))
     else ($epoch | strflocaltime("%H:%M")) end)
  else ($epoch | strflocaltime("%m-%d %H:%M")) end;
def limits_age_text($seconds):
  if $seconds == null or $seconds < 0 then "-"
  elif $seconds < 60 then "0m"
  elif $seconds < 3600 then (($seconds / 60 | floor | tostring) + "m")
  elif $seconds < 86400 then
    (($seconds / 3600 | floor | tostring) + "h" +
     (if (($seconds % 3600) / 60 | floor) == 0 then ""
      else ((($seconds % 3600) / 60 | floor | tostring) + "m") end))
  else
    (($seconds / 86400 | floor | tostring) + "d" +
     (if (($seconds % 86400) / 3600 | floor) == 0 then ""
      else ((($seconds % 86400) / 3600 | floor | tostring) + "h") end))
  end;
def limits_markers($stale; $expired):
  ((if $stale then "~" else "" end) + (if $expired then "!" else "" end));
def limits_pct_text($eff; $stale; $expired):
  if $eff == null then "-"
  else ((($eff | round | tostring) + "%") + limits_markers($stale; $expired))
  end;
'
