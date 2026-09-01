# The pin carries a reading of the limits store (the wall standing when it was placed), so the
# bucket semantics come from their one home rather than a second copy here.
. "${BASH_SOURCE[0]%/*}/limits-view.sh"

worker_model_file() {
  printf '%s' "${WORKER_PICK_CONFIG_FILE:-$HOME/.claude/worker-model}"
}

# Until when the walls standing on <vendor>/<account> run, empty when none stands. Read from the
# merged store `worker-pick` routes on, so the horizon stored beside a pin and the wall the picker
# later sees are one reading rather than two that can disagree.
worker_model_pin_wall_until() {
  local vendor="$1" account="${2:-}" store now out
  store="${LLM_LIMITS_FILE:-$HOME/.llm-limits.json}"
  case "$account" in '' | --*) return 0 ;; esac
  [ -r "$store" ] || return 0
  now=$(date +%s) || return 0
  out=$(jq -r --arg vendor "$vendor" --arg account "$account" --argjson now "$now" \
    "$LIMITS_VIEW_JQ"'
    (.vendors[$vendor] // {}) as $v |
    (if ($v.accounts | type) == "array"
     then (first($v.accounts[] | select((.account // "main") == $account)) // null)
     elif $account == "main" then $v else null end) as $row |
    if $row == null then empty else (limits_store_wall_until($row; $now) // empty) end
  ' "$store" 2>/dev/null) || return 0
  [[ "$out" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$out"
}

# The pin is the ONE override above the pool, and a session that sets or clears it silently
# redirects every worker after it — including the ones Egor never watches. So it is his hands only,
# and both of them stay open: the menubar shells out from Hammerspoon, which carries no CLAUDECODE,
# and words in chat are turned into a grant by worker-pin-gate.sh. A session helping itself to the
# pin because an account merely came up in conversation is neither (Egor, 2026-08-08).
WORKER_MODEL_PIN_TTL_MIN="${WORKER_MODEL_PIN_TTL_MIN:-30}"

worker_model_pin_grant() {
  local state="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}"
  printf '%s/pin-grants/pin' "$state"
}

worker_model_canonical_path() {
  local path="$1" dir base
  case "$path" in '~') path="$HOME" ;; '~/'*) path="$HOME/${path#\~/}" ;; esac
  dir=$(dirname -- "$path") || { printf '%s' "$path"; return; }
  base=$(basename -- "$path") || { printf '%s' "$path"; return; }
  if dir=$(cd -- "$dir" 2>/dev/null && pwd -P); then
    printf '%s/%s' "$dir" "$base"
  else
    printf '%s' "$path"
  fi
}

worker_model_pin_allowed() {
  [ -n "${CLAUDECODE:-}" ] || return 0
  # A fixture named through WORKER_PICK_CONFIG_FILE is a test's own file, not his — but the FILE
  # decides that, never the spelling: `$HOME/.claude//worker-model` and a `..` hop reach the real
  # pin, and a session that only has to type the path differently has no gate at all.
  [ "$(worker_model_canonical_path "$(worker_model_file)")" \
    = "$(worker_model_canonical_path "$HOME/.claude/worker-model")" ] || return 0
  [ -n "$(find "$(worker_model_pin_grant)" -mmin "-$WORKER_MODEL_PIN_TTL_MIN" 2>/dev/null)" ]
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

# A wall ends a pin instead of pausing it: Egor pins an account to spend it, and once it is spent
# he does not want it back — the pin sitting in the file until he notices it is the surprise
# (Egor, 2026-08-09). This is the account's own doing, not a session helping itself, so it is the
# one clear that needs no grant; it removes only the exact name the caller measured, so a pin moved
# between that reading and this write survives. Exit 1 means nothing was cleared.
worker_model_clear_walled_pin() {
  local key="$1" name="$2" file current tmp
  [ -n "$key" ] && [ -n "$name" ] || return 2
  file=$(worker_model_file)
  [ -r "$file" ] || return 1
  (
    if ! "${WORKER_MODEL_LOCKF:-/usr/bin/lockf}" -s 9; then return 2; fi
    current=$(worker_model_pinned_account "$key") || return 2
    [ "$current" = "$name" ] || return 1
    tmp="$file.tmp.$$"
    trap 'rm -f "$tmp"' EXIT
    grep -Ev "^${key}(_wall)?=" "$file" >"$tmp" || true
    mv "$tmp" "$file" || return 2
    trap - EXIT
  ) 9>"$file.lock"
}

# A role is a per-vendor wall over the pool, and an ABSENT key is what every reader takes as open,
# so turning a role back on deletes the line instead of inventing an "=on" spelling. Under the same
# lock as the pin: an unlocked rewrite from the menubar would resurrect a `*_profile=` line
# worker-pick had just cleared.
worker_model_set_role() {
  local vendor="${1-}" role="${2-}" state="${3-}" file key
  case "$vendor" in claudeb | codex | gemini | grok) ;; *)
    printf 'worker-model: unknown vendor: %s\n' "$vendor" >&2; return 2 ;;
  esac
  case "$role" in workers | reviewers) ;; *)
    printf 'worker-model: unknown role: %s\n' "$role" >&2; return 2 ;;
  esac
  case "$state" in on | off) ;; *)
    printf 'worker-model: unknown state: %s\n' "$state" >&2; return 2 ;;
  esac
  # Closing a vendor for a role redirects every worker and rater after it, so it is Egor's hand
  # only — the menubar shells out from Hammerspoon, which carries no CLAUDECODE.
  if [ -n "${CLAUDECODE:-}" ]; then
    printf 'worker-model: role switches are Egor'"'"'s: the menubar (LLM Limits -> vendor -> For workers/For reviewers) is his own hand on them\n' >&2
    return 3
  fi
  file=$(worker_model_file)
  key="${vendor}_${role}"
  mkdir -p "$(dirname "$file")" || return 2
  (
    local tmp="$file.tmp.$$"
    if ! "${WORKER_MODEL_LOCKF:-/usr/bin/lockf}" -s 9; then
      printf 'worker-model: failed to lock %s\n' "$file.lock" >&2
      return 2
    fi
    trap 'rm -f "$tmp"' EXIT
    {
      if [ -r "$file" ]; then grep -v "^${key}=" "$file" || true; fi
      [ "$state" = on ] || printf '%s=off\n' "$key"
    } >"$tmp" || return 2
    mv "$tmp" "$file" || return 2
    trap - EXIT
  ) 9>"$file.lock"
}

worker_model_pin_account() {
  local key="$1" vendor="$2" list_fn="$3" disabled_fn="$4" name="${5:-}" wall_until="${6:-}"
  local file current near
  # A horizon already past says nothing about the pin being placed now; worker-pick reads a missing
  # companion as "no wall was standing", which is also the right answer for a hand-written pin.
  case "$wall_until" in '' | *[!0-9]*) wall_until='' ;; esac
  [ -z "$wall_until" ] || [ "$wall_until" -gt "$(date +%s)" ] || wall_until=''
  case "$key" in claudeb_profile | codex_profile | gemini_profile | grok_profile) ;; *)
    printf 'worker-model: unknown pin key: %s\n' "$key" >&2; return 2 ;;
  esac
  file=$(worker_model_file)
  case "$name" in
    '')
      if ! current=$(worker_model_pinned_account "$key"); then
        printf '%s: %s exists but cannot be read; refusing to touch the pin\n' "$vendor" "$file" >&2
        return 2
      fi
      if [ -n "$current" ]; then
        printf '%s: workers are pinned to %s\n' "$vendor" "$current"
      else
        printf '%s: no pin — workers follow worker-pick\n' "$vendor"
      fi
      return 0
      ;;
    --clear)
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
  if ! worker_model_pin_allowed; then
    printf '%s: the pin is Egor'\''s to move, and he has not asked for it here. Ask him in one line, or leave it: the menubar (LLM Limits → account → Pin) is his own hand on it.\n' \
      "$vendor" >&2
    return 3
  fi
  mkdir -p "$(dirname "$file")" || return 2
  (
    local tmp="$file.tmp.$$"
    if ! "${WORKER_MODEL_LOCKF:-/usr/bin/lockf}" -s 9; then
      printf '%s: failed to lock %s\n' "$vendor" "$file.lock" >&2
      return 2
    fi
    if ! current=$(worker_model_pinned_account "$key"); then
      printf '%s: %s exists but cannot be read; refusing to touch the pin\n' "$vendor" "$file" >&2
      return 2
    fi
    if [ "$name" = --clear ] && [ -z "$current" ]; then
      printf '%s: no pin to clear\n' "$vendor"
      return 0
    fi
    trap 'rm -f "$tmp"' EXIT
    {
      if [ -r "$file" ]; then grep -Ev "^${key}(_wall)?=" "$file" || true; fi
      if [ "$name" != --clear ]; then
        printf '%s=%s\n' "$key" "$name"
        # Pinning an ALREADY walled account asks for the window after that wall, not for the one
        # that is gone: the recorded horizon is what lets worker-pick tell that wall from a later
        # one, which does end the pin (docs/routing-contract.md rule 3).
        [ -z "$wall_until" ] || printf '%s_wall=%s\n' "$key" "$wall_until"
      fi
    } >"$tmp" || return 2
    mv "$tmp" "$file" || return 2
    trap - EXIT
    if [ "$name" = --clear ]; then
      printf '%s: cleared the pin — workers follow worker-pick again\n' "$vendor"
      return 0
    fi
    printf '%s: pinned workers to %s\n' "$vendor" "$name"
    if "$disabled_fn" "$name"; then
      printf '%s: note: %s is out of the worker pool; the pin is the one override, so workers will still run on it\n' \
        "$vendor" "$name" >&2
    fi
  ) 9>"$file.lock"
}
