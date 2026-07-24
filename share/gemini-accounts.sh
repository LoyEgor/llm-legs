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
