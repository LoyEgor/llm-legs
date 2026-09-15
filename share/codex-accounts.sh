# Codex `main` is the real `~/.codex` — a mirror of whatever account the Codex app is signed into,
# so nothing under it is this tool's to delete: `codexb remove main` writes this marker instead,
# and every enumerator decides main's existence by it. The marker sits beside main's legacy cache
# FILE rather than inside any profile directory, because that is the path the menubar's
# `--codex-remove` writes; a second spelling leaves a removal only one of the two tools can see.
codex_removal_marker() {
  local main_cache
  # Named accounts are removed by deleting their profile directory and have no marker at all, so
  # asking for one is a caller bug rather than a path that happens not to exist yet.
  [ "$1" = main ] || return 1
  main_cache="${LLM_LIMITS_CODEX_CACHE:-${codex_base_home:-$HOME}/.llm-limits-codex.json}"
  printf '%s\n' "${LLM_LIMITS_CODEX_REMOVED:-$main_cache.removed}"
}

codex_main_removed() { [ -e "$(codex_removal_marker main)" ]; }

codex_fast_mode_helper() {
  local share_dir
  share_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  printf '%s\n' "${CODEXB_FAST_MODE_HELPER:-$share_dir/codex_fast_mode.py}"
}

codex_fast_tier() {
  local file tier
  file="${CODEXB_PROFILES_DIR:-$HOME/.codex-profiles}/.codexb/fast-mode/$1"
  [ -f "$file" ] && [ -r "$file" ] || { printf 'default\n'; return; }
  IFS= read -r tier <"$file" || [ -n "$tier" ] || { printf 'default\n'; return; }
  case "$tier" in
    fast|priority) printf 'fast\n' ;;
    default) printf '%s\n' "$tier" ;;
    *) printf 'default\n' ;;
  esac
}

codex_fast_mode_state() {
  local profiles="${CODEXB_PROFILES_DIR:-$HOME/.codex-profiles}"
  python3 "$(codex_fast_mode_helper)" "$profiles" "$1" state
}
