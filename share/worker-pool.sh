# Worker-pool membership, shared by claudeb, codexb, geminib, grokb and llm-limits.sh: one file per
# vendor holding one excluded account name per line, an absent file meaning everything is in.
#
# The file lives in a dot-directory beside that vendor's profiles, where the profile
# enumerators' `*` glob cannot see it, so a pool file can never be mistaken for an account.
#
# Membership IS reachability for every headless launch: a worker cannot touch an excluded
# account even when a caller names it outright. An exclusion that only steered the automatic
# selection was no answer at all — a model told "you have limits, use another account" simply
# named an excluded one and the toggle meant nothing. The only override is the vendor pin in
# worker-model: naming an account there is the deliberate "use this one anyway". Interactive
# launches are the human, never a worker, and are never gated — which is also why an empty pool
# is a legitimate state: it says "no worker may run", not "nobody may work".

worker_pool_file() { printf '%s/disabled\n' "$1"; }

# The pool directory per vendor, so the four CLIs and worker-run cannot drift apart on where a
# vendor's membership lives. Codex reads CODEXB_PROFILES_DIR alone — the variable codexb and
# llm-limits.sh already enumerate accounts by; honouring worker-run's CODEX_PROFILES_DIR as well
# would let one store hold the accounts and another the exclusions.
worker_pool_dir() {
  case "$1" in
    claudeb) printf '%s\n' "${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}" ;;
    codex) printf '%s/.codexb\n' "${CODEXB_PROFILES_DIR:-$HOME/.codex-profiles}" ;;
    gemini) printf '%s/.geminib\n' "${GEMINIB_PROFILES_DIR:-$HOME/.gemini-profiles}" ;;
    grok) printf '%s/.grokb\n' "${GROKB_PROFILES_DIR:-$HOME/.grok-profiles}" ;;
    *) return 1 ;;
  esac
}

# The wall itself: 0 when this account may carry a headless run, 1 with a refusal on stderr when
# the pool says no. The pin is passed in rather than read here, because the pin lives in
# worker-model and this file must stay loadable on its own.
worker_pool_refuse_headless() {
  local vendor="$1" account="$2" pin="$3" dir
  # Fail CLOSED on a vendor this file does not know, like every other rule here: a typo or a
  # fourth vendor wired in without a pool directory would otherwise switch the wall off silently.
  if ! dir=$(worker_pool_dir "$vendor"); then
    printf 'worker-pool: no pool directory for vendor %s; refusing the run rather than skipping the check\n' "$vendor" >&2
    return 1
  fi
  worker_pool_is_disabled "$dir" "$account" || return 0
  [ -n "$pin" ] && [ "$pin" = "$account" ] && return 0
  printf '%s: %s is out of the worker pool, so no headless run may use it. Turn "In worker pool" back on for it, or pin it in ~/.claude/worker-model.\n' \
    "$vendor" "$account" >&2
  return 1
}

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

# The vendor-wide switch behind the menu's "Enable all"/"Disable all": every account the tool's own
# enumerator knows ends in the requested state, accounts already there included, so the command is
# idempotent. `--all` is a flag to the caller and never an account name, whatever a directory
# happens to be called.
worker_pool_set_all() {
  local dir="$1" tool="$2" names_fn="$3" mode="$4" name verb=enabled
  if [ "$mode" = on ]; then verb=disabled; fi
  while IFS= read -r name; do
    [ -n "$name" ] && [ "$name" != --all ] || continue
    if [ "$mode" = on ]; then
      worker_pool_is_disabled "$dir" "$name" || worker_pool_set_disabled "$dir" "$name" on
    else
      ! worker_pool_is_disabled "$dir" "$name" || worker_pool_set_disabled "$dir" "$name" off
    fi
    printf '%s: %s %s\n' "$tool" "$verb" "$name"
  done < <("$names_fn")
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
