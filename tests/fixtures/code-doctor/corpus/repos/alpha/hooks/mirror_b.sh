staleness_window() {
  local hours=${1:-3} now stamp
  now=$(date +%s)
  stamp=$(cat "${STAMP_FILE:-/tmp/alpha-stamp}" 2>/dev/null || echo 0)
  if [ $((now - stamp)) -gt $((hours * 3600)) ]; then
    echo stale
    return 1
  fi
  echo fresh
}
