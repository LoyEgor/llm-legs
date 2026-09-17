. "${BASH_SOURCE[0]%/*}/worker-pool.sh"
. "${BASH_SOURCE[0]%/*}/worker-walls.sh"

worker_model_file() {
  printf '%s' "${WORKER_PICK_CONFIG_FILE:-$HOME/.claude/worker-model}"
}

# Egor's per-model call: brief efforts need no extra word; word efforts and word-only
# models require his explicit request in orchestrator policy. The union of both effort
# columns is the mechanical rule; the first row of each vendor is its default model.
# Gemini runs at `high` and nothing else, on every leg (Egor, 2026-09-16), so its rows offer no
# other effort and `worker-run` raises a lower one instead of refusing the run.
worker_model_table() {
  cat <<'TABLE'
claudeb opus high high,xhigh low,medium,max no
claudeb fable low low,medium,high xhigh,max yes
codex gpt-6-astra low low,medium,high xhigh no
codex gpt-5.6-sol medium medium,high low,xhigh yes
TABLE
  # Flash rows first in list order, `pro` last: the first gemini row is the vendor default, and a
  # Pro newer than every Flash would otherwise make the word-gated model everyone's default.
  worker_model_gemini_families | awk -F'\t' '
    $2 == "pro" { pro = pro sprintf("gemini %s high high - yes\n", $2); next }
    { printf "gemini %s high high - no\n", $2 }
    END { printf "%s", pro }'
  cat <<'TABLE'
grok auto high high,xhigh - no
grok grok-4.6 high high,xhigh - no
TABLE
}

worker_model_gemini_families() {
  "${BASH_SOURCE[0]%/*}/../bin/geminib" families 2>/dev/null
}

# `flash` predates versioned slugs and names the newest Flash family on the list.
worker_model_gemini_family() { # table slug, agy id or `flash` → its `geminib families` row
  worker_model_gemini_families | awk -F'\t' -v name="${1-}" '
    name == "flash" && $1 ~ /-flash$/ && legacy == "" { legacy = $0 }
    $2 == name || $3 == name || index(name, $3 "-") == 1 { print; found = 1; exit }
    END { if (!found && legacy != "") print legacy }'
}

worker_model_allowed_models() {
  worker_model_table | awk -v vendor="${1-}" '
    $1 == vendor { print $2; found = 1 }
    END { if (!found) exit 2 }
  '
}

worker_model_default_model() {
  local models
  models=$(worker_model_allowed_models "${1-}") || return 2
  printf '%s\n' "${models%%$'\n'*}"
}

worker_model_default_effort() {
  worker_model_table | awk -v vendor="${1-}" -v model="${2-}" '
    $1 == vendor && $2 == model { print $3; found = 1; exit }
    END { if (!found) exit 2 }
  '
}

worker_model_effort_list() {
  worker_model_table | awk -v vendor="${1-}" -v model="${2-}" '
    $1 == vendor && $2 == model {
      found = 1; sep = ""
      for (col = 4; col <= 5; col++) {
        n = split($col, efforts, ",")
        for (i = 1; i <= n; i++) {
          if (efforts[i] == "-" || seen[efforts[i]]++) continue
          printf "%s%s", sep, efforts[i]; sep = "|"
        }
      }
      exit
    }
    END { if (!found) exit 2 }
  '
}

worker_model_effort_allowed() {
  local efforts allowed
  efforts=$(worker_model_effort_list "${1-}" "${2-}") || return 2
  [ -n "${3-}" ] || return 1
  while IFS= read -r allowed; do
    [ "$allowed" != "$3" ] || return 0
  done < <(tr '|' '\n' <<<"$efforts")
  return 1
}

worker_model_allows() { # vendor model
  local allowed
  allowed=$(worker_model_allowed_models "${1-}") || return 2
  [ -n "${2-}" ] || return 1
  grep -qxF -- "${2-}" <<<"$allowed"
}

# The vendor's allowed ids as one phrase a refusal can quote, so no consumer respells the list.
worker_model_allowed_list() { # vendor
  local allowed
  allowed=$(worker_model_allowed_models "${1-}") || return 2
  printf '%s' "$(tr '\n' '|' <<<"$allowed" | sed 's/|$//')"
}

worker_model_allowed_summary() { # every vendor, as one phrase
  local vendor out=''
  while IFS= read -r vendor; do
    out="${out:+$out; }$vendor $(worker_model_allowed_list "$vendor")"
  done < <(worker_model_table | awk '!seen[$1]++ { print $1 }')
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

worker_model_chat_session() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  worker_pool_valid_name "$sid" || return 1
  printf '%s' "$sid"
}

worker_model_chat_pin_grant() {
  local sid
  sid=$(worker_model_chat_session) || return 1
  printf '%s/chat-%s' "$(dirname "$(worker_model_pin_grant)")" "$sid"
}

worker_model_chat_pin_file() {
  local sid
  sid=$(worker_model_chat_session) || return 1
  printf '%s/%s' "${CHAT_PINS_DIR:-$HOME/.cache/claude-chat-pins}" "$sid"
}

# A non-empty chat file replaces the global pin tier whole — a vendor it does not name is unpinned
# for that chat, never filled in from the global file.
worker_model_pin_file() {
  local chat
  if chat=$(worker_model_chat_pin_file) && [ -s "$chat" ]; then
    printf '%s' "$chat"
  else
    worker_model_file
  fi
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

worker_model_pin_line() { # file key
  [ -f "$1" ] || return 0
  [ -r "$1" ] || return 1
  awk -v prefix="$2=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' \
    "$1" 2>/dev/null
}

worker_model_pinned_account() {
  local key="$1" file
  case "$key" in
    *_profile) file=$(worker_model_pin_file) ;;
    *) file=$(worker_model_file) ;;
  esac
  worker_model_pin_line "$file" "$key"
}

worker_model_pin_key() {
  case "${1-}" in
    claudeb|claude) printf 'claudeb_profile' ;;
    codex) printf 'codex_profile' ;;
    gemini) printf 'gemini_profile' ;;
    grok) printf 'grok_profile' ;;
    *) return 2 ;;
  esac
}

worker_model_pin_split() { # raw value -> one name per line
  local name rest="${1-}"
  while [ -n "$rest" ]; do
    name=${rest%%,*}
    if [ "$name" = "$rest" ]; then rest=
    else rest=${rest#*,}
    fi
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    [ -n "$name" ] || continue
    printf '%s\n' "$name"
  done
}

# The accounts a `*` pin covers: every account the limits store carries for the vendor that the
# pool admits. Out-of-pool accounts stay out — only an account pin overrides the pool.
worker_model_pool_accounts() {
  local vendor="${1-}" store_vendor dir name names store="${LLM_LIMITS_FILE:-$HOME/.llm-limits.json}"
  dir=$(worker_pool_dir "$vendor") || return 2
  store_vendor=$vendor
  [ "$store_vendor" != claudeb ] || store_vendor=claude
  if ! names=$(jq -r --arg v "$store_vendor" '
    .vendors[$v] | select(type == "object" and .removed != true) |
    if (.accounts | type) == "array" then .accounts[] | select(.removed != true) | (.account // "main")
    else "main" end' "$store" 2>/dev/null); then
    printf 'worker-model: cannot read the limits store %s — a * pin covers no %s account\n' \
      "$store" "$vendor" >&2
    return 1
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    worker_pool_is_disabled "$dir" "$name" || printf '%s\n' "$name"
  done < <(awk '!seen[$0]++' <<<"$names")
}

worker_model_pin_scope() {
  local key val names
  key=$(worker_model_pin_key "${1-}") || return 2
  val=$(worker_model_pinned_account "$key") || return 1
  names=$(worker_model_pin_split "$val")
  case "$names" in
    '') printf 'none' ;;
    '*') printf 'vendor' ;;
    *) printf 'account' ;;
  esac
}

worker_model_pins() {
  local key val names
  key=$(worker_model_pin_key "${1-}") || return 2
  val=$(worker_model_pinned_account "$key") || return 1
  names=$(worker_model_pin_split "$val")
  [ -n "$names" ] || return 0
  if [ "$names" = '*' ]; then
    worker_model_pool_accounts "$1"
  else
    printf '%s\n' "$names"
  fi
}

# A `*` pin's first account is the one worker-pick ranks first, never the store's listing order.
worker_model_pin_first() {
  local vendor="${1-}" pins first
  pins=$(worker_model_pins "$vendor")
  [ -n "$pins" ] || return 0
  if [ -z "${WORKER_MODEL_IN_PICK:-}" ] && [ "$(worker_model_pin_scope "$vendor")" = vendor ] &&
    first=$(WORKER_MODEL_IN_PICK=1 "${BASH_SOURCE[0]%/*}/../bin/worker-pick" --account "$vendor" \
      2>/dev/null) && grep -qxF -- "$first" <<<"$pins"; then
    printf '%s\n' "$first"
    return 0
  fi
  printf '%s\n' "${pins%%$'\n'*}"
}

worker_model_pin_has() {
  local want="${2-}" got
  while IFS= read -r got; do
    [ "$got" = "$want" ] && return 0
  done < <(worker_model_pins "${1-}")
  return 1
}

worker_model_pin_csv() {
  local out='' name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    out="${out:+$out,}$name"
  done
  printf '%s' "$out"
}

# The list is read and rewritten inside ONE critical section: a read outside the lock lets two
# concurrent adds each write a list missing the other's name. `*` never shares the line with a name.
worker_model_pin_write() { # vendor key op(set|add|remove) argument [file]
  local key="$2" op="$3" arg="$4" file="${5:-$(worker_model_file)}"
  mkdir -p "$(dirname "$file")" || return 2
  (
    local names csv tmp
    if ! "${WORKER_MODEL_LOCKF:-/usr/bin/lockf}" -s 9; then return 2; fi
    names=$(worker_model_pin_split "$(worker_model_pin_line "$file" "$key")")
    case "$op" in
      set) csv="$arg" ;;
      add) if [ "$arg" = '*' ] || [ "$names" = '*' ]; then csv=$arg
           else csv=$( { [ -z "$names" ] || printf '%s\n' "$names"
                         printf '%s\n' "$arg"
                       } | awk 'NF && !seen[$0]++' | worker_model_pin_csv )
           fi ;;
      remove) csv=$( printf '%s\n' "$names" |
                     awk -v drop="$arg" 'NF && $0 != drop' | worker_model_pin_csv ) ;;
      *) return 2 ;;
    esac
    tmp="$file.tmp.$$"
    trap 'rm -f "$tmp"' EXIT
    {
      if [ -r "$file" ]; then grep -Ev "^${key}(_wall)?=" "$file" || true; fi
      [ -z "$csv" ] || printf '%s=%s\n' "$key" "$csv"
    } >"$tmp" || return 2
    if [ ! -s "$tmp" ] && [ "$file" = "$(worker_model_chat_pin_file 2>/dev/null)" ]; then
      rm -f "$tmp" "$file" || return 2
    else
      mv "$tmp" "$file" || return 2
    fi
    trap - EXIT
  ) 9>"$file.lock"
}

# Ungated rewrite of one vendor pin key. Callers that need a grant check first.
worker_model_pin_store() {
  worker_model_pin_write '' "$1" set "$2"
}

worker_model_pin_add() { # vendor name [file]
  local vendor="${1-}" name="${2-}" key
  key=$(worker_model_pin_key "$vendor") || return 2
  [ -n "$name" ] || return 2
  worker_model_pin_write "$vendor" "$key" add "$name" "${3-}"
}

worker_model_pin_remove() { # vendor name [file]
  local vendor="${1-}" name="${2-}" key
  key=$(worker_model_pin_key "$vendor") || return 2
  [ -n "$name" ] || return 2
  worker_model_pin_write "$vendor" "$key" remove "$name" "${3-}"
}

# A met wall drops one name, and a `*` pin only once every account it covers has an unexpired
# observed wall. No grant: the accounts spent themselves. The file edited is the one the pin came
# from — the chat file or the global one.
worker_model_clear_walled_pin() { # vendor name [now]
  local vendor="${1-}" name="${2-}" file key walls acct
  [ -n "$vendor" ] && [ -n "$name" ] || return 2
  worker_model_pin_has "$vendor" "$name" || return 1
  key=$(worker_model_pin_key "$vendor") || return 2
  file=$(worker_model_pin_file)
  if [ "$(worker_model_pin_scope "$vendor")" = vendor ]; then
    walls=$(worker_walls_fresh "$vendor" "${3:-$(date +%s)}") || return 1
    while IFS= read -r acct; do
      [ -n "$acct" ] || continue
      grep -qxF -- "$acct" <<<"$walls" || return 1
    done < <(worker_model_pins "$vendor")
    worker_model_pin_write "$vendor" "$key" set '' "$file" || return 1
    printf 'pin * (every %s account) hit its wall — cleared\n' "$vendor" >&2
    return 0
  fi
  worker_model_pin_remove "$vendor" "$name" "$file" || return 1
  printf 'pin %s hit its wall — cleared\n' "$name" >&2
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

# A pause parks a vendor for months, so the key names the PARKED state and the literal `on` is its
# veto — inverted from the roles above, whose key names the closed state and vetoes on `off`.
# Resuming deletes the line, since every reader takes an absent key as running. `opencode` is
# parkable though it has no roles and no worker-pick leg: review-bench staffs it, and a vendor that
# cannot be parked is a vendor Egor cannot put away.
worker_model_set_paused() {
  local vendor="${1-}" state="${2-}" file key
  case "$vendor" in claudeb | codex | gemini | grok | opencode) ;; *)
    printf 'worker-model: unknown vendor: %s\n' "$vendor" >&2; return 2 ;;
  esac
  case "$state" in on | off) ;; *)
    printf 'worker-model: unknown state: %s\n' "$state" >&2; return 2 ;;
  esac
  # Parking a vendor takes it out of every router at once, so it is Egor's hand only — the menubar
  # shells out from Hammerspoon, which carries no CLAUDECODE.
  if [ -n "${CLAUDECODE:-}" ]; then
    printf 'worker-model: pause switches are Egor'"'"'s: the menubar (LLM Limits -> vendor -> Pause/Resume) is his own hand on them\n' >&2
    return 3
  fi
  file=$(worker_model_file)
  key="${vendor}_paused"
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
      [ "$state" = off ] || printf '%s=on\n' "$key"
    } >"$tmp" || return 2
    mv "$tmp" "$file" || return 2
    trap - EXIT
  ) 9>"$file.lock"
}

worker_model_pin_account() {
  local key="$1" vendor="$2" list_fn="$3" disabled_fn="$4" name="${5:-}" drop="${6:-}"
  local file current near pin_vendor action
  case "$key" in claudeb_profile | codex_profile | gemini_profile | grok_profile) ;; *)
    printf 'worker-model: unknown pin key: %s\n' "$key" >&2; return 2 ;;
  esac
  case "$key" in
    claudeb_profile) pin_vendor=claudeb ;;
    codex_profile) pin_vendor=codex ;;
    gemini_profile) pin_vendor=gemini ;;
    grok_profile) pin_vendor=grok ;;
  esac
  file=$(worker_model_file)
  action=add
  case "$name" in
    '')
      if ! current=$(worker_model_pin_line "$file" "$key"); then
        printf '%s: %s exists but cannot be read; refusing to touch the pin\n' "$vendor" "$file" >&2
        return 2
      fi
      if [ "$(worker_model_pin_split "$current")" = '*' ]; then
        printf '%s: workers are pinned to every %s pool account (*)\n' "$vendor" "$pin_vendor"
      elif [ -n "$current" ]; then
        printf '%s: workers are pinned to %s\n' "$vendor" "$current"
      else
        printf '%s: no pin — workers follow worker-pick\n' "$vendor"
      fi
      return 0
      ;;
    --clear) action=clear ;;
    --unpin)
      if [ -z "$drop" ]; then action=clear
      else name=$drop; action=unpin
      fi
      ;;
    '*') ;;
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
  if ! current=$(worker_model_pin_line "$file" "$key"); then
    printf '%s: %s exists but cannot be read; refusing to touch the pin\n' "$vendor" "$file" >&2
    return 2
  fi
  if [ "$action" = clear ]; then
    [ -n "$current" ] || { printf '%s: no pin to clear\n' "$vendor"; return 0; }
    worker_model_pin_store "$key" "" || return 2
    printf '%s: cleared the pin — workers follow worker-pick again\n' "$vendor"
    return 0
  fi
  if [ "$action" = unpin ]; then
    if [ "$(worker_model_pin_split "$current")" = '*' ]; then
      printf '%s: the whole vendor is pinned (*), not %s alone; use --clear\n' "$vendor" "$name" >&2
      return 1
    fi
    worker_model_pin_split "$current" | grep -qxF -- "$name" || {
      printf '%s: %s is not pinned\n' "$vendor" "$name" >&2
      return 1
    }
    worker_model_pin_remove "$pin_vendor" "$name" || return 2
    printf '%s: unpinned %s\n' "$vendor" "$name"
    return 0
  fi
  worker_model_pin_add "$pin_vendor" "$name" || return 2
  if [ "$name" = '*' ]; then
    printf '%s: pinned workers to every %s pool account (*)\n' "$vendor" "$pin_vendor"
    return 0
  fi
  printf '%s: pinned workers to %s\n' "$vendor" "$name"
  if "$disabled_fn" "$name"; then
    printf '%s: note: %s is out of the worker pool; the pin is the one override, so workers will still run on it\n' \
      "$vendor" "$name" >&2
  fi
}
