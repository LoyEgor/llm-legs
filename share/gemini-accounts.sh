gemini_account_names() {
  local path
  printf 'main\n'
  if [ -d "$gemini_profiles_dir" ]; then
    for path in "$gemini_profiles_dir"/*; do
      [ -d "$path" ] && basename "$path"
    done | LC_ALL=C sort
  fi
}

gemini_account_home() {
  if [ "$1" = main ]; then
    printf '%s\n' "$gemini_base_home"
  else
    printf '%s\n' "$gemini_profiles_dir/$1"
  fi
}

# agy stores its OAuth token in the login keychain macOS resolves from $HOME — item svce="gemini",
# acct="antigravity" — and prefers it over the profile's own antigravity-oauth-token file, so
# profiles sharing a keychain silently share one Google account however isolated their HOMEs are.
# Owning one is the only alternative: with no keychain at all agy raises a modal "A keychain cannot
# be found to store antigravity" dialog on every token refresh. It must be named login.keychain-db
# for agy to find it, which is also why nothing here unlocks it — macOS routes
# `security unlock-keychain` on that name to the session's own keychain and rejects the password,
# and unlocking a renamed copy does not carry over when the file is renamed back, so the
# keychain stays locked and agy's own prompt is the only thing that opens it. HOME is pinned on
# every security call: create-keychain otherwise registers the profile keychain in the real
# session's search list, where a locked entry makes unrelated lookups prompt.
gemini_ensure_keychain() {
  local home="$1" keychains="$1/Library/Keychains" name staging password
  local security_cmd="${GEMINIB_SECURITY_CMD:-/usr/bin/security}"
  [ "$home" != "$gemini_base_home" ] || return 0
  # A profile removed between listing and probing must stay removed, not be rebuilt as a ghost.
  [ -d "$home" ] || return 0
  name=$(basename "$home")
  # Plain rm, and inside the condition: a concurrent probe that already replaced the link with a
  # real directory must neither be reported twice nor abort a caller running under `set -e`.
  if [ -L "$keychains" ] && rm "$keychains" 2>/dev/null; then
    printf 'geminib: %s shared the main keychain and was signed in as its account; sign it in again.\n' \
      "$name" >&2
  fi
  if [ -f "$keychains/login.keychain-db" ]; then
    if [ ! -s "$home/.keychain-password" ]; then
      printf 'geminib: %s has a keychain but no saved password; it cannot be unlocked, so sign the profile in again if agy asks.\n' \
        "$name" >&2
    fi
    return 0
  fi
  mkdir -p "$keychains" 2>/dev/null || return 0
  # Probes run in parallel. Staging the keychain and publishing it with a hard link elects one
  # winner atomically, and a run killed before the link leaves only a stray staging directory —
  # a lock would survive the same crash and keep the profile keychain-less forever. The password
  # follows the link rather than leading it: a loser that had written it first would strand the
  # winner's keychain behind a password nobody kept.
  staging=$(mktemp -d "$keychains/.staging.XXXXXX" 2>/dev/null) || return 0
  password=$(head -c 24 /dev/urandom 2>/dev/null | base64 | tr -dc 'A-Za-z0-9') || password=''
  if [ -n "$password" ] &&
    (umask 077; printf '%s' "$password" >"$staging/password") &&
    HOME="$home" "$security_cmd" create-keychain -p "$password" "$staging/login.keychain-db" \
      >/dev/null 2>&1 &&
    HOME="$home" "$security_cmd" set-keychain-settings -u "$staging/login.keychain-db" \
      >/dev/null 2>&1; then
    if ln "$staging/login.keychain-db" "$keychains/login.keychain-db" 2>/dev/null; then
      mv -f "$staging/password" "$home/.keychain-password" || true
    fi
  else
    printf 'geminib: could not create a keychain for %s; agy will ask for one on its next token refresh.\n' \
      "$name" >&2
  fi
  rm -rf "$staging"
}
