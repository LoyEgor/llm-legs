worker_model_file() {
  printf '%s' "${WORKER_PICK_CONFIG_FILE:-$HOME/.claude/worker-model}"
}

worker_model_pinned_account() {
  local key="$1" file
  file=$(worker_model_file)
  [ -f "$file" ] || return 0
  [ -r "$file" ] || return 1
  awk -v prefix="$key=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' \
    "$file" 2>/dev/null
}

worker_model_edit_distance() {
  WM_A="$1" WM_B="$2" awk 'BEGIN {
    a = ENVIRON["WM_A"]; b = ENVIRON["WM_B"]
    la = length(a); lb = length(b)
    for (i = 0; i <= la; i++) d[i, 0] = i
    for (j = 0; j <= lb; j++) d[0, j] = j
    for (i = 1; i <= la; i++) for (j = 1; j <= lb; j++) {
      c = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
      m = d[i-1, j] + 1; n = d[i, j-1] + 1; o = d[i-1, j-1] + c
      d[i, j] = (m < n ? (m < o ? m : o) : (n < o ? n : o))
    }
    print d[la, lb]
  }'
}

worker_model_similar_accounts() {
  local target="$1" list_fn="$2" name out='' distance
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" != "$target" ] || continue
    distance=$(worker_model_edit_distance "$target" "$name" || true)
    [[ "$distance" =~ ^[0-9]+$ ]] || continue
    [ "$distance" -le 2 ] || continue
    out="${out:+$out, }$name"
  done < <("$list_fn")
  printf '%s' "$out"
}

worker_model_account_exists() {
  local target="$1" list_fn="$2" name
  while IFS= read -r name; do
    [ "$name" != "$target" ] || return 0
  done < <("$list_fn")
  return 1
}

worker_model_pin_account() {
  local key="$1" vendor="$2" list_fn="$3" disabled_fn="$4" name="${5:-}"
  local file current near tmp
  file=$(worker_model_file)
  if ! current=$(worker_model_pinned_account "$key"); then
    printf '%s: %s exists but cannot be read; refusing to touch the pin\n' "$vendor" "$file" >&2
    return 2
  fi
  case "$name" in
    '')
      if [ -n "$current" ]; then
        printf '%s: workers are pinned to %s\n' "$vendor" "$current"
      else
        printf '%s: no pin — workers follow worker-pick\n' "$vendor"
      fi
      return 0
      ;;
    --clear)
      if [ -z "$current" ]; then
        printf '%s: no pin to clear\n' "$vendor"
        return 0
      fi
      ;;
    *)
      if ! [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
        printf '%s: unknown account: %s\n' "$vendor" "$name" >&2
        near=$(worker_model_similar_accounts "$name" "$list_fn" || true)
        [ -z "$near" ] || printf '%s: did you mean %s?\n' "$vendor" "$near" >&2
        return 2
      fi
      if ! worker_model_account_exists "$name" "$list_fn"; then
        printf '%s: unknown account: %s\n' "$vendor" "$name" >&2
        near=$(worker_model_similar_accounts "$name" "$list_fn" || true)
        [ -z "$near" ] || printf '%s: did you mean %s?\n' "$vendor" "$near" >&2
        return 2
      fi
      ;;
  esac
  mkdir -p "$(dirname "$file")"
  tmp="$file.tmp.$$"
  {
    if [ -r "$file" ]; then grep -v "^${key}=" "$file" || true; fi
    [ "$name" = --clear ] || printf '%s=%s\n' "$key" "$name"
  } >"$tmp"
  mv "$tmp" "$file"
  if [ "$name" = --clear ]; then
    printf '%s: cleared the pin — workers follow worker-pick again\n' "$vendor"
    return 0
  fi
  printf '%s: pinned workers to %s\n' "$vendor" "$name"
  if "$disabled_fn" "$name"; then
    printf '%s: note: %s is out of the worker pool; the direct pin still overrides automatic pool exclusion\n' \
      "$vendor" "$name" >&2
  fi
}
