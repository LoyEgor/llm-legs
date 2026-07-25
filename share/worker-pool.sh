# Worker-pool membership, shared by claudeb, codexb, geminib and llm-limits.sh: one file per
# vendor holding one excluded account name per line, an absent file meaning everything is in.
#
# The file lives in a dot-directory beside that vendor's profiles, where the profile
# enumerators' `*` glob cannot see it, so a pool file can never be mistaken for an account.
#
# Membership is deliberately NOT the same thing as reachability: an excluded account still
# launches when named directly, because the exclusion speaks for automatic selection only.

worker_pool_file() { printf '%s/disabled\n' "$1"; }

# A file that exists but cannot be read fails CLOSED — every account of that vendor is treated as
# excluded, loudly. Reading it as "no exclusions" would do the one thing the file exists to
# prevent: hand an automatic selection the account the user told it not to burn.
# `--` on every grep: an account name may start with a hyphen, and without it grep reads the
# name as its own options.
worker_pool_is_disabled() {
  local file="$1/disabled"
  [ -e "$file" ] || return 1
  if [ -f "$file" ] && [ -r "$file" ]; then
    grep -qxF -- "$2" "$file" && return 0
    return 1
  fi
  printf 'worker-pool: %s cannot be read; treating every account as out of the pool\n' "$file" >&2
  return 0
}

worker_pool_set_disabled() {
  local dir="$1" name="$2" mode="$3" file="$1/disabled" tmp
  # Rewriting a file we could not read would silently drop every exclusion already in it: the
  # read half below is skipped and the `mv` publishes a file holding only this one change.
  if [ -e "$file" ] && { [ ! -f "$file" ] || [ ! -r "$file" ]; }; then
    printf 'worker-pool: %s cannot be read; refusing to rewrite it\n' "$file" >&2
    return 1
  fi
  mkdir -p "$dir"
  tmp="$file.tmp.$$"
  {
    if [ -r "$file" ]; then grep -vxF -- "$name" "$file" || true; fi
    if [ "$mode" = on ]; then printf '%s\n' "$name"; fi
  } > "$tmp"
  mv "$tmp" "$file"
}

# JSON array of the excluded names for the collector's jq filters, or `null` when the file exists
# but cannot be read or parsed — the same fail-closed rule, which the consumer must read as
# "every account of this vendor is out".
worker_pool_disabled_json() {
  local file="$1/disabled"
  [ -e "$file" ] || { printf '[]'; return 0; }
  if [ -f "$file" ] && [ -r "$file" ] &&
     jq -Rn '[inputs | select(length > 0)]' < "$file" 2>/dev/null; then
    return 0
  fi
  printf 'worker-pool: %s cannot be read; treating every account as out of the pool\n' "$file" >&2
  printf 'null'
}
