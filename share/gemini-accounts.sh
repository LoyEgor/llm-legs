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

gemini_heal_keychain_search_list() {
  local security_cmd="${GEMINIB_SECURITY_CMD:-/usr/bin/security}"
  local lock_dir="$gemini_profiles_dir/.geminib" line path changed=0
  local -a kept=()
  mkdir -p "$lock_dir" 2>/dev/null || return 0
  (
    /usr/bin/lockf -s -t 10 8 || return 0
    while IFS= read -r line; do
      path=${line#*\"}
      path=${path%\"}
      [ "$path" != "$line" ] || continue
      case "$path" in
        "$gemini_profiles_dir"/*/Library/Keychains/login.keychain-db|\
        "$gemini_profiles_dir"/*/Library/Keychains/.staging.*/login.keychain-db|\
        /private/var/folders/*/tmp.*/gp/*/Library/Keychains/.staging.*/login.keychain-db)
          changed=1
          ;;
        *) kept+=("$path") ;;
      esac
    done < <(HOME="$gemini_base_home" "$security_cmd" list-keychains -d user 2>/dev/null)
    if [ "$changed" -eq 1 ] && [ "${#kept[@]}" -gt 0 ]; then
      HOME="$gemini_base_home" "$security_cmd" list-keychains -d user -s "${kept[@]}" \
        >/dev/null 2>&1 || true
    fi
  ) 8>"$lock_dir/keychain-search-list.lock"
}

# agy stores its OAuth token in the login keychain macOS resolves from $HOME — item svce="gemini",
# acct="antigravity" — and prefers it over the profile's own antigravity-oauth-token file, so
# profiles sharing a keychain silently share one Google account however isolated their HOMEs are.
# With no keychain at all agy raises a modal "A keychain cannot be found" dialog on every token
# refresh, and agy only finds the file when it is named login.keychain-db — a basename
# `security unlock-keychain` misroutes to the session keychain even given the absolute path,
# so every unlock below renames the file away first and back after.
gemini_ensure_keychain() {
  local home="$1" keychains="$1/Library/Keychains" keychain unlock_path legacy_path
  local password_file version_file name password token version rc
  local security_cmd="${GEMINIB_SECURITY_CMD:-/usr/bin/security}"
  gemini_heal_keychain_search_list
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
  mkdir -p "$keychains" 2>/dev/null || return 0
  keychain="$keychains/login.keychain-db"
  unlock_path="$keychains/.geminib-unlock.keychain-db"
  legacy_path="$keychains/.geminib-legacy.keychain-db"
  password_file="$home/.keychain-password"
  version_file="$home/.keychain-version"
  (
    /usr/bin/lockf -s -t 15 9 || {
      printf 'geminib: timed out preparing the keychain for %s.\n' "$name" >&2
      return 1
    }
    if [ ! -f "$keychain" ] && [ -f "$unlock_path" ]; then
      mv "$unlock_path" "$keychain" || return 1
    fi
    if [ -f "$keychain" ]; then
      if [ ! -s "$password_file" ]; then
        printf 'geminib: %s has a keychain but no saved password; sign the profile in again.\n' \
          "$name" >&2
        return 1
      fi
      password=$(<"$password_file")
      version=$(cat "$version_file" 2>/dev/null) || version=''
      if [ "$version" != 2 ]; then
        # Staged hard links are separate keychain handles on macOS. Rebuilding at the final path
        # preserves the token and makes later rename-based unlocks affect agy's handle.
        if [ -e "$legacy_path" ] || ! mv "$keychain" "$legacy_path"; then
          printf 'geminib: could not migrate the keychain for %s.\n' "$name" >&2
          return 1
        fi
        if ! HOME="$home" "$security_cmd" unlock-keychain -p "$password" "$legacy_path" \
          >/dev/null 2>&1; then
          mv "$legacy_path" "$keychain" || true
          printf 'geminib: could not unlock the legacy keychain for %s.\n' "$name" >&2
          return 1
        fi
        token=$(HOME="$home" "$security_cmd" find-generic-password \
          -s gemini -a antigravity -w "$legacy_path" 2>/dev/null) || token=''
        if ! HOME="$home" "$security_cmd" create-keychain -p "$password" "$keychain" \
            >/dev/null 2>&1 ||
          ! HOME="$home" "$security_cmd" set-keychain-settings -u "$keychain" \
            >/dev/null 2>&1; then
          rm -f "$keychain"
          mv "$legacy_path" "$keychain" || true
          printf 'geminib: could not rebuild the keychain for %s.\n' "$name" >&2
          return 1
        fi
        HOME="$home" "$security_cmd" list-keychains -d user -s "$keychain" >/dev/null 2>&1 || true
        HOME="$home" "$security_cmd" default-keychain -d user -s "$keychain" >/dev/null 2>&1 || true
        if [ -n "$token" ] &&
          ! HOME="$home" "$security_cmd" add-generic-password -U \
            -s gemini -a antigravity -w "$token" >/dev/null 2>&1; then
          rm -f "$keychain"
          mv "$legacy_path" "$keychain" || true
          HOME="$home" "$security_cmd" list-keychains -d user -s "$keychain" >/dev/null 2>&1 || true
          HOME="$home" "$security_cmd" default-keychain -d user -s "$keychain" >/dev/null 2>&1 || true
          printf 'geminib: could not migrate the token for %s.\n' "$name" >&2
          return 1
        fi
        (umask 077; printf '2\n' >"$version_file")
        token=''
        return 0
      fi
      HOME="$home" "$security_cmd" list-keychains -d user -s "$keychain" >/dev/null 2>&1 || true
      HOME="$home" "$security_cmd" default-keychain -d user -s "$keychain" >/dev/null 2>&1 || true
      if [ -e "$unlock_path" ] || ! mv "$keychain" "$unlock_path"; then
        printf 'geminib: could not prepare the keychain for %s.\n' "$name" >&2
        return 1
      fi
      rc=0
      HOME="$home" "$security_cmd" unlock-keychain -p "$password" "$unlock_path" \
        >/dev/null 2>&1 || rc=$?
      if ! mv "$unlock_path" "$keychain"; then
        printf 'geminib: could not restore the keychain for %s from %s.\n' \
          "$name" "$unlock_path" >&2
        return 1
      fi
      if [ "$rc" -ne 0 ]; then
        printf 'geminib: could not unlock the keychain for %s.\n' "$name" >&2
        return 1
      fi
      return 0
    fi
    if [ -s "$password_file" ]; then
      password=$(<"$password_file")
    else
      password=$(head -c 24 /dev/urandom 2>/dev/null | base64 | tr -dc 'A-Za-z0-9') || password=''
      [ -n "$password" ] && (umask 077; printf '%s' "$password" >"$password_file")
    fi
    if [ -z "$password" ] ||
      ! HOME="$home" "$security_cmd" create-keychain -p "$password" "$keychain" \
        >/dev/null 2>&1 ||
      ! HOME="$home" "$security_cmd" set-keychain-settings -u "$keychain" \
        >/dev/null 2>&1; then
      printf 'geminib: could not create a keychain for %s.\n' "$name" >&2
      return 1
    fi
    HOME="$home" "$security_cmd" list-keychains -d user -s "$keychain" >/dev/null 2>&1 || true
    HOME="$home" "$security_cmd" default-keychain -d user -s "$keychain" >/dev/null 2>&1 || true
    (umask 077; printf '2\n' >"$version_file")
  ) 9>"$keychains/.geminib-keychain.lock"
}
