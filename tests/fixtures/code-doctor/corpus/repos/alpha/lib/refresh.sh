user_curl_refresh() {
  curl -fsS "https://example.invalid/refresh" -o /tmp/alpha-refresh.json
  echo "refreshed on request"
}

robot_curl_refresh() {
  while true; do
    curl -fsS "https://example.invalid/refresh" -o /tmp/alpha-refresh.json
    sleep 600
  done
}
