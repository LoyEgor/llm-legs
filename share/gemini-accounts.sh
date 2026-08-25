# main runs under the real HOME, so nothing about it can be deleted to mark it gone: `geminib
# remove main` writes this marker instead, and every enumerator decides main's existence by it.
gemini_removal_marker() {
  printf '%s/%s.json.removed\n' \
    "${gemini_accounts_cache_dir:-${LLM_LIMITS_GEMINI_ACCOUNTS_DIR:-$gemini_base_home/.llm-limits-gemini}}" \
    "$1"
}

gemini_main_removed() { [ -e "$(gemini_removal_marker main)" ]; }

gemini_account_names() {
  local path
  gemini_main_removed || printf 'main\n'
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

# agy keeps its OAuth token in the keychain macOS resolves from $HOME — item svce="gemini",
# acct="antigravity" — and opens it strictly as Library/Keychains/login.keychain-db, so profiles
# sharing a keychain silently share one Google account however isolated their HOMEs are. That
# basename is the trap: macOS routes every `security` command naming it — absolute path included —
# to the session's own keychain, so a profile keychain called login.keychain-db can never be
# unlocked, and unlocking a renamed copy does not survive renaming it back. The database therefore
# lives under a name security can address, login.keychain-db is only a symlink to it, and every
# launch unlocks it by the real name. Measured 2026-07-27 across reboots: without that unlock agy's
# token refresh — a write — raises the modal keychain password dialog on the first run after every
# boot; with it nothing prompts. HOME is pinned on every security call, or the profile keychain
# lands in the real session's search list where a locked entry makes unrelated lookups prompt too.
gemini_ensure_keychain() {
  local home="$1" keychains="$1/Library/Keychains" name status
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
  mkdir -p "$keychains" 2>/dev/null || return 0
  # Probes run in parallel and the lock only orders them: every step below repairs whatever the
  # previous run left behind, so a machine without lockf, or a run that waited out the timeout, is
  # better served by racing than by skipping the unlock and letting agy prompt.
  status=97
  if [ -x /usr/bin/lockf ]; then
    (
      /usr/bin/lockf -s -t 15 9 2>/dev/null || exit 97
      gemini_prepare_keychain "$home" "$name" "$security_cmd"
    ) 9>"$home/.geminib-keychain.lock" || status=$?
  fi
  [ "$status" != 97 ] || gemini_prepare_keychain "$home" "$name" "$security_cmd" || true
  # Callers run under `set -e` and a keychain that could not be prepared is a reason to warn, never
  # a reason to leave the account unusable: agy signs in from its own token file either way.
  return 0
}

gemini_prepare_keychain() {
  local home="$1" name="$2" security_cmd="$3"
  local keychains="$1/Library/Keychains"
  local real="$keychains/gemini.keychain-db" link="$keychains/login.keychain-db"
  local password_file="$home/.keychain-password" password_tmp="$home/.keychain-password.new"
  local password usable=0
  # agy recreates login.keychain-db as a real file whenever it is missing, so a real file at that
  # path is always the database it has been writing and outranks whatever this function left there.
  # `mv -f` rather than a delete first: nothing is thrown away until the replacement is in place.
  if [ ! -L "$link" ] && [ -f "$link" ]; then
    mv -f "$link" "$real" 2>/dev/null || return 1
  fi
  # rm -rf throughout: a directory sitting on either path would otherwise survive every repair and
  # fail create-keychain forever.
  if [ -L "$real" ]; then
    rm -rf "$real"
  fi
  if [ ! -L "$link" ] && [ -e "$link" ]; then
    rm -rf "$link" 2>/dev/null || return 1
  fi
  if [ "$(readlink "$link" 2>/dev/null)" != gemini.keychain-db ]; then
    rm -f "$link" 2>/dev/null
    ln -s gemini.keychain-db "$link" 2>/dev/null || return 1
  fi
  if [ -f "$real" ] && [ -s "$password_file" ]; then
    password=$(cat "$password_file" 2>/dev/null) || password=''
    if [ -n "$password" ] &&
      HOME="$home" "$security_cmd" unlock-keychain -p "$password" "$real" >/dev/null 2>&1; then
      usable=1
    fi
  fi
  # A keychain whose password nobody holds can only be replaced: it can never be unlocked, so agy
  # would prompt for it after every boot, and it holds nothing the profile's own
  # antigravity-oauth-token file does not — that file, not the keychain, is what agy signs in with.
  if [ "$usable" -eq 0 ]; then
    rm -rf "$real"
    password=$(head -c 24 /dev/urandom 2>/dev/null | base64 | tr -dc 'A-Za-z0-9') || password=''
    # The password reaches its file only once the keychain it opens exists, and by rename from a
    # fresh 0600 file: writing in place would both keep the mode of a pre-existing loose file and
    # leave a password behind that matches no keychain when create-keychain fails.
    if [ -z "$password" ] ||
      ! (umask 077; rm -f "$password_tmp"; printf '%s' "$password" >"$password_tmp") ||
      ! HOME="$home" "$security_cmd" create-keychain -p "$password" "$real" >/dev/null 2>&1 ||
      ! mv -f "$password_tmp" "$password_file"; then
      rm -f "$password_tmp"
      printf 'geminib: could not create a keychain for %s; agy will ask for its password on the next token refresh.\n' \
        "$name" >&2
      return 1
    fi
    # create-keychain already leaves it unlocked; asked again so that "every run ends with an
    # unlocked keychain" holds by construction rather than by trusting that.
    HOME="$home" "$security_cmd" unlock-keychain -p "$password" "$real" >/dev/null 2>&1 || true
  fi
  # Registered under the symlink because that is the path agy opens, and left without a lock
  # timeout so one unlock covers every run until the next boot.
  HOME="$home" "$security_cmd" list-keychains -d user -s "$link" >/dev/null 2>&1 || true
  HOME="$home" "$security_cmd" default-keychain -d user -s "$link" >/dev/null 2>&1 || true
  HOME="$home" "$security_cmd" set-keychain-settings -u "$real" >/dev/null 2>&1 || true
}
