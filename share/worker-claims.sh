worker_claims_dir() { worker_claims_dir_r; printf '%s\n' "$WORKER_CLAIMS_R"; }
worker_claims_dir_r() { WORKER_CLAIMS_R=${WORKER_CLAIMS_DIR:-$HOME/.cache/worker-claims}; }

worker_claims_valid_name() {
  [ -n "$1" ] || return 1
  case "$1" in
    */*|*..*) return 1 ;;
  esac
}

worker_claims_ttl() {
  worker_claims_ttl_r || return 1
  printf '%s\n' "$WORKER_CLAIMS_R"
}

worker_claims_ttl_r() {
  case "${WORKER_CLAIMS_TTL:-600}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  WORKER_CLAIMS_R=${WORKER_CLAIMS_TTL:-600}
}

worker_claims_touch() { # root-function vendor account
  local root
  worker_claims_valid_name "$2" || return 1
  worker_claims_valid_name "$3" || return 1
  root=$("$1") || return 1
  mkdir -p -- "$root/$2" && touch -- "$root/$2/$3"
}

worker_claims_record() { worker_claims_touch worker_claims_dir "$1" "$2"; }

worker_claims_release() {
  local vendor="$1" account="$2" root
  worker_claims_valid_name "$vendor" || return 1
  worker_claims_valid_name "$account" || return 1
  root=$(worker_claims_dir) || return 1
  rm -f -- "$root/$vendor/$account"
}

# Lists the unexpired claims and says nothing else: the status is an error verdict only, never
# the freshness of whichever file `find` happened to hand over last.
worker_claims_fresh() {
  local status
  worker_claims_fresh_r "$@"
  status=$?
  printf '%s' "$WORKER_CLAIMS_R"
  return "$status"
}

# The same lines into WORKER_CLAIMS_R, forking only when the vendor has a claims directory.
worker_claims_fresh_r() {
  local vendor="$1" root ttl now file mtime out=''
  WORKER_CLAIMS_R=''
  worker_claims_valid_name "$vendor" || return 1
  worker_claims_dir_r
  root=$WORKER_CLAIMS_R
  worker_claims_ttl_r || { WORKER_CLAIMS_R=''; return 1; }
  ttl=$WORKER_CLAIMS_R
  WORKER_CLAIMS_R=''
  [ -d "$root/$vendor" ] || return 0
  now=$(date +%s) || return 1
  while IFS= read -r file; do
    mtime=$(stat -f '%m' "$file" 2>/dev/null) || continue
    if [ $((now - mtime)) -le "$ttl" ]; then
      out+="${file##*/}"$'\n'
    fi
  done < <(find -- "$root/$vendor" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null)
  WORKER_CLAIMS_R=$out
  return 0
}

# The media rotation stamp (shared-invariants row dh): one file per account whose mtime is when a NEW
# generation last started on it. Never under the claims root: a claims prune deletes every stale file
# there, and an idle account's stamp is old by definition.
worker_starts_dir() {
  local claims
  if [ -n "${WORKER_STARTS_DIR:-}" ]; then printf '%s\n' "$WORKER_STARTS_DIR"; return 0; fi
  claims=$(worker_claims_dir)
  printf '%s/media-starts\n' "${claims%/*}"
}

worker_starts_record() { worker_claims_touch worker_starts_dir "$1" "$2"; }

worker_starts_json() { # vendor -> {"account": epoch, ...}; a never-started account is absent
  local vendor="$1" root file mtime
  worker_claims_valid_name "$vendor" || return 1
  root=$(worker_starts_dir) || return 1
  [ -d "$root/$vendor" ] || { printf '{}\n'; return 0; }
  while IFS= read -r file; do
    mtime=$(stat -f '%m' "$file" 2>/dev/null) || continue
    printf '%s\t%s\n' "${file##*/}" "$mtime"
  done < <(find -- "$root/$vendor" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null) |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}'
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
