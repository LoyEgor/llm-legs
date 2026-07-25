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

# macOS resolves the login keychain from $HOME, so a profile without this link makes agy's token
# refresh raise a modal "keychain cannot be found" dialog. The shared items are safe-storage
# encryption keys, not account credentials, so borrowing them keeps the profiles isolated.
gemini_link_keychain() {
  local home="$1" source="$gemini_base_home/Library/Keychains" target="$1/Library/Keychains"
  [ "$home" != "$gemini_base_home" ] || return 0
  [ -d "$source" ] || return 0
  # A profile removed between listing and probing must stay removed, not be rebuilt as a ghost.
  [ -d "$home" ] || return 0
  [ ! -d "$target" ] || return 0
  [ ! -L "$target" ] || rm -f "$target"
  [ ! -e "$target" ] || return 0
  mkdir -p "$home/Library" 2>/dev/null || return 0
  # -n: without it a link that a concurrent probe just created is followed, and the new link
  # lands nested inside the user's real keychain directory.
  ln -sn "$source" "$target" 2>/dev/null || true
}
