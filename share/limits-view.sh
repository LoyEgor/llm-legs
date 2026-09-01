# limits-view.sh — the ONE definition of limit-bucket display semantics
# (shared-invariants row y): what makes a bucket stale or expired, which
# percentage a surface may show, and how a text surface labels it. Sourced by
# bin/claudeb and llm-limits.sh, which prepend $LIMITS_VIEW_JQ to their jq
# programs. The Hammerspoon menu renders the effective_pct/stale/expired fields
# the collector computed with these defs and must never re-derive them.

LIMITS_STALE_FIVE_HOUR=1800
LIMITS_STALE_WEEKLY=21600
LIMITS_STALE_FABLE=21600
# A reading a day old and a row carrying no reading at all are one verdict — nothing here is
# worth trusting — so every surface paints both the same red instead of inventing its own alert.
LIMITS_AGE_ALARM=86400

# Reset epochs below one year are placeholder zeros, never real times.
LIMITS_VIEW_JQ='
def limits_reset_epoch_floor: 31536000;
def limits_bucket_expired($now; $reset):
  ($reset != null and $reset >= limits_reset_epoch_floor and $reset <= $now);
# A reset over a day past named a window that has rolled over unseen — a 5-hour one several
# times over — so the date describes no schedule anyone can wait for, and a surface printing it
# invites reading a dead row as a live one. The bucket stays `expired` either way: this drops
# the date, never the verdict.
def limits_reset_ancient($now; $reset):
  ($reset != null and $reset >= limits_reset_epoch_floor and ($now - $reset) > 86400);
def limits_bucket_stale($now; $thr; $auth_expired; $origin; $asof):
  ($auth_expired or ($origin == "cached") or (($now - $asof) > $thr));
def limits_effective_pct($pct; $expired):
  (if $expired then 0 else $pct end);
# A reset this file would refuse to print (placeholder or ancient) answers null days, not 0, so
# the budget falls back to a neutral full window instead of the 0.25-day floor — which would rank
# a garbage row first.
def limits_days_remaining($reset_epoch; $now):
  if ($reset_epoch | type) != "number" or $reset_epoch < limits_reset_epoch_floor
     or limits_reset_ancient($now; $reset_epoch) then null
  else ((($reset_epoch - $now) / 86400) as $d | if $d < 0 then 0 else $d end)
  end;
def limits_daily_budget($eff_pct; $days):
  if ($eff_pct | type) != "number" then null
  else
    ((if $eff_pct < 0 then 0 elif $eff_pct > 100 then 100 else $eff_pct end) as $p |
     (if ($days | type) != "number" then 7 elif $days < 0.25 then 0.25 else $days end) as $d |
     (100 - $p) / $d)
  end;
def limits_reset_text($epoch; $now):
  if $epoch == null or $epoch < limits_reset_epoch_floor
     or limits_reset_ancient($now; $epoch) then "-"
  elif ($epoch - $now) < 604800 then
    (if ($epoch | strflocaltime("%Y-%m-%d")) != ($now | strflocaltime("%Y-%m-%d"))
     then (["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][$epoch | strflocaltime("%w") | tonumber]
           + " " + ($epoch | strflocaltime("%H:%M")))
     else ($epoch | strflocaltime("%H:%M")) end)
  else ($epoch | strflocaltime("%m-%d %H:%M")) end;
def limits_age_alarm($seconds; $alarm):
  ($seconds == null) or ($seconds >= $alarm);
def limits_age_text($seconds):
  if $seconds == null then "never"
  elif $seconds < 0 then "-"
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
# The merged store writes reset times as ISO-8601 with an offset, the vendor snapshots behind it
# carry bare epochs; a reader of one spelling takes the other for no reset at all.
def limits_store_epoch:
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
def limits_store_eff($b; $now):
  ($b // {}) as $bucket | (($bucket.resets_at // null) | limits_store_epoch) as $reset |
  if (($bucket.used_pct // null) | type) != "number" then null
  elif $reset != null and $reset <= $now then 0
  elif (($bucket.effective_pct // null) | type) == "number" then $bucket.effective_pct
  else $bucket.used_pct end;
# How long the walls standing on an account run, null when none does. Dead auth is deliberately
# not a wall here: it is a login to fix, not a window to wait out.
def limits_store_wall_until($row; $now):
  [$row.five_hour?, $row.weekly? | select(type == "object") |
   select((limits_store_eff(.; $now) // -1) >= 100) |
   (.resets_at | limits_store_epoch) | select(type == "number" and . > $now)] | max;
'
