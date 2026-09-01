worker_claims_dir() { printf '%s\n' "${WORKER_CLAIMS_DIR:-$HOME/.cache/worker-claims}"; }

worker_claims_valid_name() {
  [ -n "$1" ] || return 1
  case "$1" in
    */*|*..*) return 1 ;;
  esac
}

worker_claims_ttl() {
  case "${WORKER_CLAIMS_TTL:-600}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "${WORKER_CLAIMS_TTL:-600}"
}

worker_claims_record() {
  local vendor="$1" account="$2" root
  worker_claims_valid_name "$vendor" || return 1
  worker_claims_valid_name "$account" || return 1
  root=$(worker_claims_dir) || return 1
  mkdir -p -- "$root/$vendor" && touch -- "$root/$vendor/$account"
}

worker_claims_fresh() {
  local vendor="$1" root ttl now file mtime
  worker_claims_valid_name "$vendor" || return 1
  root=$(worker_claims_dir) || return 1
  ttl=$(worker_claims_ttl) || return 1
  [ -d "$root/$vendor" ] || return 0
  now=$(date +%s) || return 1
  find -- "$root/$vendor" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null |
    while IFS= read -r file; do
      mtime=$(stat -f '%m' "$file" 2>/dev/null) || continue
      [ $((now - mtime)) -le "$ttl" ] && printf '%s\n' "${file##*/}"
    done
}

worker_claims_prune() {
  local vendor="${1-}" root ttl now file mtime target
  if [ "$#" -gt 1 ]; then return 1; fi
  if [ -n "$vendor" ]; then worker_claims_valid_name "$vendor" || return 1; fi
  root=$(worker_claims_dir) || return 1
  ttl=$(worker_claims_ttl) || return 1
  [ -d "$root" ] || return 0
  target="$root"
  if [ -n "$vendor" ]; then
    target="$root/$vendor"
    [ -d "$target" ] || return 0
  fi
  now=$(date +%s) || return 1
  find -- "$target" -type f -print 2>/dev/null |
    while IFS= read -r file; do
      mtime=$(stat -f '%m' "$file" 2>/dev/null) || continue
      [ $((now - mtime)) -le "$ttl" ] || rm -f -- "$file"
    done
}
