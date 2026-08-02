# Fired where an account starts existing (add / first-launch create) so the
# limits menu learns about it without a manual refresh. Detached because callers
# often exec right after, and a broken collector must never fail the CLI.
announce_account_added() {
  local root="$1" vendor="$2" name="$3"
  local collector="${LLM_LIMITS_ANNOUNCE_CMD:-$root/llm-limits.sh}"
  [ -x "$collector" ] || return 0
  ("$collector" --refresh-account "$vendor/$name" </dev/null >/dev/null 2>&1 &) || true
}

# Fired where an account stops existing. A targeted refresh would fail on a name
# no store knows anymore, so this is a passive collect: it rebuilds the merged
# cache from the vendor stores, which is exactly what drops the removed row.
announce_account_removed() {
  local root="$1"
  local collector="${LLM_LIMITS_ANNOUNCE_CMD:-$root/llm-limits.sh}"
  [ -x "$collector" ] || return 0
  ("$collector" </dev/null >/dev/null 2>&1 &) || true
}
