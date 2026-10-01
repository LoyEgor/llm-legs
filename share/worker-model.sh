. "${BASH_SOURCE[0]%/*}/worker-pool.sh"
. "${BASH_SOURCE[0]%/*}/worker-walls.sh"
. "${BASH_SOURCE[0]%/*}/codex-accounts.sh"

worker_model_file() {
  printf '%s' "${WORKER_PICK_CONFIG_FILE:-$HOME/.claude/worker-model}"
}

# Egor's per-model call: brief efforts need no extra word; word efforts and word-only
# models require his explicit request in orchestrator policy. The union of both effort
# columns is the mechanical rule; the first row of each vendor is its default model.
# Gemini runs at `high` and nothing else, on every leg (Egor, 2026-09-16), so its rows offer no
# other effort and `worker-run` raises a lower one instead of refusing the run.
# A lookup from $(...) is a subshell: a cache set there dies with it, and the next lookup
# rebuilds both catalogs. worker_model_prime stores the bytes in THIS shell first.
worker_model_table() {
  if [ -n "${_WM_TABLE_PRIMED+x}" ]; then
    printf '%s' "$_WM_TABLE"
    return 0
  fi
  _worker_model_table_build
}

_worker_model_table_build() {
  cat <<'TABLE'
claudeb opus high high,xhigh low,medium,max no
claudeb fable low low,medium,high xhigh,max yes
codex astra low low,medium,high xhigh no
codex sol medium medium,high low,xhigh yes
TABLE
  # Flash rows first in list order, `pro` last: the first gemini row is the vendor default, and a
  # Pro newer than every Flash would otherwise make the word-gated model everyone's default.
  if [ -z "${_WM_SKIP_GEMINI+x}" ]; then
    worker_model_gemini_families | awk -F'\t' '
      $2 == "pro" { pro = pro sprintf("gemini %s high high - yes\n", $2); next }
      { printf "gemini %s high high - no\n", $2 }
      END { printf "%s", pro }'
  fi
  # `auto` stays the vendor default: it is the CLI's own default model, so a release that moves it
  # self-integrates, and every slug the list prints is offered beside it.
  # A slug offers high/xhigh only where its catalog efforts carry them; `-` (unknown) offers both.
  if [ -z "${_WM_SKIP_GROK+x}" ]; then
    worker_model_grok_models | awk -F'\t' '
      function row(model, efforts,   n, e, i, allowed) {
        if (efforts == "" || efforts == "-") efforts = "high,xhigh"
        n = split(efforts, e, ",")
        for (i = 1; i <= n; i++) if (e[i] == "high") allowed = "high"
        for (i = 1; i <= n; i++) if (e[i] == "xhigh") allowed = allowed (allowed == "" ? "" : ",") "xhigh"
        if (allowed == "") allowed = efforts
        split(allowed, e, ",")
        return sprintf("grok %s %s %s - no\n", model, e[1], allowed)
      }
      { rows = rows row($1, $4); if ($2 == "yes") auto = row("auto", $4) }
      END { printf "%s%s", (auto == "" ? row("auto", "-") : auto), rows }'
  fi
}

# [vendor] empty = every catalog. A single-vendor prime omits the other catalog: its rows are not
# in that query's answer. A wider prime after a narrow one rebuilds.
worker_model_prime() {
  local scope="${1-}"
  case "$scope" in
    claudeb|codex|gemini|grok) ;;
    *) scope='' ;;
  esac
  if [ -n "${_WM_TABLE_PRIMED+x}" ] && [ "${_WM_TABLE_SCOPE-}" = "$scope" ]; then
    return 0
  fi
  case "$scope" in
    gemini) unset _WM_SKIP_GEMINI; _WM_SKIP_GROK=1 ;;
    grok) _WM_SKIP_GEMINI=1; unset _WM_SKIP_GROK ;;
    claudeb|codex) _WM_SKIP_GEMINI=1; _WM_SKIP_GROK=1 ;;
    *) unset _WM_SKIP_GEMINI _WM_SKIP_GROK ;;
  esac
  if [ -z "${_WM_SKIP_GROK+x}" ] && [ -z "${_WM_GROK_PRIMED+x}" ]; then
    _WM_GROK_MODELS=$(worker_model_grok_models; printf x)
    _WM_GROK_MODELS=${_WM_GROK_MODELS%x}
    _WM_GROK_PRIMED=1
  fi
  if [ -z "${_WM_SKIP_GEMINI+x}" ] && [ -z "${_WM_GEMINI_PRIMED+x}" ]; then
    _WM_GEMINI_FAMILIES=$(worker_model_gemini_families; printf x)
    _WM_GEMINI_FAMILIES=${_WM_GEMINI_FAMILIES%x}
    _WM_GEMINI_PRIMED=1
  fi
  _WM_TABLE=$(_worker_model_table_build; printf x)
  _WM_TABLE=${_WM_TABLE%x}
  _WM_TABLE_SCOPE=$scope
  _WM_TABLE_PRIMED=1
}

worker_model_grok_models() {
  if [ -n "${_WM_GROK_PRIMED+x}" ]; then
    printf '%s' "$_WM_GROK_MODELS"
    return 0
  fi
  "${BASH_SOURCE[0]%/*}/../bin/grokb" models 2>/dev/null
}

worker_model_grok_default() {
  worker_model_grok_models | awk -F'\t' '$2 == "yes" { print $1; exit }'
}

# `auto` is the knob's word for "the CLI's default", and the slug that default resolves to names no
# more than the vendor word does — on a row beside a claudeb twin of the same account name, the
# vendor word is what tells them apart. Any other slug is a choice someone made and shows itself.
worker_model_grok_label() { # model -> what a surface shows
  local model="${1-}" default
  default=$(worker_model_grok_default)
  if [ "$model" = auto ] || { [ -n "$default" ] && [ "$model" = "$default" ]; }; then
    printf 'grok\n'
  else
    printf '%s\n' "$model"
  fi
}

# The Build CLI's fast twin of the default model, read off the same list every other reader takes:
# the slug that carries the default's own prefix and a `-fast` tail. A release that renames either
# one self-integrates, and a list with no such slug answers nothing rather than a guess.
worker_model_grok_fast_sibling() {
  local default sibling
  default=$(worker_model_grok_default)
  [ -n "$default" ] || return 1
  # The separator is required: a bare prefix test would read `grok-4.5-build-fast` as the fast twin
  # of a default named `grok-4`, and the pin would silently run another model family.
  sibling=$(worker_model_grok_models |
    awk -F'\t' -v default="$default" 'index($1, default "-") == 1 && $1 ~ /-fast$/ { print $1; exit }')
  [ -n "$sibling" ] || return 1
  printf '%s\n' "$sibling"
}

# xAI serves each account a catalog of its own; the menu reads the same file for its Fast mark.
# An account with no readable catalog is unknown, not refused.
worker_model_grok_account_lists() { # account slug
  local cache
  [ -n "${1-}" ] || return 0
  if [ "$1" = main ]; then cache="$HOME/.grok/models_cache.json"
  else cache="${GROKB_PROFILES_DIR:-$HOME/.grok-profiles}/$1/models_cache.json"; fi
  jq -e '.models | type == "object" and length > 0' "$cache" >/dev/null 2>&1 || return 0
  jq -e --arg slug "$2" '.models | has($slug)' "$cache" >/dev/null 2>&1
}

worker_model_grok_account_fast() { # account
  [ -n "${1-}" ] || return 1
  [ "$(codex_fast_tier "$1" "${GROKB_PROFILES_DIR:-$HOME/.grok-profiles}" grokb)" = fast ]
}

# The grok slug a run really launches: `chat-pin grok-fast`, or the account's menu Fast Mode
# (`grokb fast-mode`), swaps the fast twin in for the marked default and for `auto` alone — a brief
# naming a slug runs unchanged — and only on a WORKERS leg. ONE resolution, because `worker-run`
# launches off it and the spawn hook labels its task row off it; two would let a row name a model
# the run does not use.
worker_model_grok_launch_model() { # model role [chat-pin-file] [account]
  local model="${1-}" role="${2-}" file="${3-}" account="${4-}" default sibling fast=false
  if [ "$role" = workers ]; then
    [ -n "$file" ] || file=$(worker_model_chat_pin_file) || file=''
    if [ -n "$file" ] && [ "$(worker_model_pin_line "$file" grok_fast)" = on ]; then fast=true; fi
    if worker_model_grok_account_fast "$account"; then fast=true; fi
    if [ "$fast" = true ]; then
      default=$(worker_model_grok_default)
      if [ "$model" = auto ] || { [ -n "$default" ] && [ "$model" = "$default" ]; }; then
        if sibling=$(worker_model_grok_fast_sibling); then
          if worker_model_grok_account_lists "$account" "$sibling"; then
            model=$sibling
          else
            printf 'grok: %s lists no %s now; running the default\n' "$account" "$sibling" >&2
          fi
        else
          printf 'grok: `grokb models` lists no fast model; running the default\n' >&2
        fi
      fi
    fi
  fi
  printf '%s\n' "$model"
}

# A codex slug is `gpt-<version>-<family>`; a slug with no word after the version (`gpt-5.5`) or
# no version at all is a family of its own. `codexb models` ranks by this split and the table keys
# on the family, so both read this one rule.
worker_model_codex_split() { # slug -> family<TAB>version (`-` when none)
  local slug="${1-}"
  if [[ "$slug" =~ ^gpt-([0-9]+(\.[0-9]+)*)-(.+)$ ]]; then
    printf '%s\t%s\n' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}"
  elif [[ "$slug" =~ ^gpt-([0-9]+(\.[0-9]+)*)$ ]]; then
    printf '%s\t%s\n' "$slug" "${BASH_REMATCH[1]}"
  else
    printf '%s\t-\n' "$slug"
  fi
}

worker_model_codex_family() { # word or slug -> the family word the table keys on
  local split
  split=$(worker_model_codex_split "${1-}")
  printf '%s\n' "${split%%$'\t'*}"
}

# The slug a codex launch runs: a family word follows the vendor's newest listed member and a full
# slug is a deliberate pin. With an account, both come from that account's own list alone.
worker_model_codex_slug() { # word-or-slug [account]
  local model="${1-}"
  [ -n "$model" ] || return 1
  if [ -n "${2-}" ]; then
    "${BASH_SOURCE[0]%/*}/../bin/codexb" models --own --family "$model" --account "$2" 2>/dev/null
  else
    case "$model" in
      gpt-*) printf '%s\n' "$model" ;;
      *) "${BASH_SOURCE[0]%/*}/../bin/codexb" models --family "$model" 2>/dev/null ;;
    esac
  fi
}

worker_model_codex_refuse() { # account slug — the server refused slug there; family words skip it a day
  "${BASH_SOURCE[0]%/*}/../bin/codexb" refuse-model "$1" "$2" >/dev/null 2>&1
}

worker_model_gemini_families() {
  if [ -n "${_WM_GEMINI_PRIMED+x}" ]; then
    printf '%s' "$_WM_GEMINI_FAMILIES"
    return 0
  fi
  "${BASH_SOURCE[0]%/*}/../bin/geminib" families 2>/dev/null
}

# `flash` predates versioned slugs and names the newest Flash family on the list.
worker_model_gemini_family() { # table slug, agy id or `flash` → its `geminib families` row
  worker_model_gemini_families | awk -F'\t' -v name="${1-}" '
    name == "flash" && $1 ~ /-flash$/ && legacy == "" { legacy = $0 }
    $2 == name || $3 == name || index(name, $3 "-") == 1 { print; found = 1; exit }
    END { if (!found && legacy != "") print legacy }'
}

# Models only a light row may name: cheap enough to be refused on the full worker leg.
worker_model_light_table() {
  cat <<'TABLE'
claudeb sonnet medium low,medium,high - no
TABLE
}

# A one-vendor lookup on an unprimed table builds that vendor's rows alone: the gemini and grok
# catalogs are CLI calls, and a codex launch paid for both on every row it read.
worker_model_rows() { # [workers|light] [vendor]
  if [ -n "${2-}" ] && [ -z "${_WM_TABLE_PRIMED+x}" ]; then
    case "$2" in
      gemini) local _WM_SKIP_GROK=1 ;;
      grok) local _WM_SKIP_GEMINI=1 ;;
      *) local _WM_SKIP_GEMINI=1 _WM_SKIP_GROK=1 ;;
    esac
    _worker_model_table_build
  else
    worker_model_table
  fi
  [ "${1-}" != light ] || worker_model_light_table
}

worker_model_allowed_models() { # vendor [class]
  worker_model_rows "${2-}" "${1-}" | awk -v vendor="${1-}" '
    $1 == vendor { print $2; found = 1 }
    END { if (!found) exit 2 }
  '
}

worker_model_default_model() {
  local models
  models=$(worker_model_allowed_models "${1-}" "${2-}") || return 2
  printf '%s\n' "${models%%$'\n'*}"
}

worker_model_row_key() { # vendor model -> the name the table keys the model on
  if [ "${1-}" = codex ]; then worker_model_codex_family "${2-}"; else printf '%s\n' "${2-}"; fi
}

worker_model_default_effort() { # vendor model [class]
  worker_model_rows "${3-}" "${1-}" | awk -v vendor="${1-}" -v model="$(worker_model_row_key "${1-}" "${2-}")" '
    $1 == vendor && $2 == model { print $3; found = 1; exit }
    END { if (!found) exit 2 }
  '
}

worker_model_effort_list() { # vendor model [class]
  worker_model_rows "${3-}" "${1-}" | awk -v vendor="${1-}" -v model="$(worker_model_row_key "${1-}" "${2-}")" '
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
  efforts=$(worker_model_effort_list "${1-}" "${2-}" "${4-}") || return 2
  [ -n "${3-}" ] || return 1
  while IFS= read -r allowed; do
    [ "$allowed" != "$3" ] || return 0
  done < <(tr '|' '\n' <<<"$efforts")
  return 1
}

worker_model_allows() { # vendor model [class]
  local allowed
  allowed=$(worker_model_allowed_models "${1-}" "${3-}") || return 2
  [ -n "${2-}" ] || return 1
  grep -qxF -- "$(worker_model_row_key "${1-}" "${2-}")" <<<"$allowed"
}

# The vendor's allowed ids as one phrase a refusal can quote, so no consumer respells the list.
worker_model_allowed_list() { # vendor [class]
  local allowed
  allowed=$(worker_model_allowed_models "${1-}" "${2-}") || return 2
  printf '%s' "$(tr '\n' '|' <<<"$allowed" | sed 's/|$//')"
}

worker_model_allowed_summary() { # every vendor, as one phrase
  local vendor out=''
  while IFS= read -r vendor; do
    out="${out:+$out; }$vendor $(worker_model_allowed_list "$vendor")"
  done < <(worker_model_table | awk '!seen[$1]++ { print $1 }')
  printf '%s' "$out"
}

# Egor's menu switch (LLM Limits -> Light): off, no Light leg exists and every consumer routes as if
# the class had never been built.
worker_light_off() { [ "$(worker_model_pin_line "$(worker_model_file)" light_paused)" = on ]; }

worker_light_row() { # research|edit
  case "${1-}" in research | edit) ;; *) return 2 ;; esac
  worker_model_pin_line "$(worker_model_file)" "light_$1"
}

# An absent row is the gemini default, which is what the Light leg ran on before the rows existed.
worker_light_vendor() { # research|edit
  local row vendor
  row=$(worker_light_row "${1-}") || return 2
  vendor=${row%%:*}
  case "${vendor:-gemini}" in
    claudeb | codex | gemini | grok) printf '%s\n' "${vendor:-gemini}" ;;
    *) printf 'worker-model: light_%s names no vendor of claudeb|codex|gemini|grok: %s\n' "$1" "$row" >&2
       return 2 ;;
  esac
}

worker_light_model() { # research|edit
  local row vendor model=''
  vendor=$(worker_light_vendor "${1-}") || return 2
  row=$(worker_light_row "$1")
  case "$row" in *:*) model=${row#*:} ;; esac
  [ -n "$model" ] || model=$(worker_model_default_model "$vendor") || return 2
  if ! worker_model_allows "$vendor" "$model" light; then
    printf 'worker-model: light_%s model %s is not among %s models %s\n' "$1" "$model" "$vendor" \
      "$(worker_model_allowed_list "$vendor" light)" >&2
    return 2
  fi
  printf '%s\n' "$model"
}

worker_light_effort() { # research|edit
  local vendor model
  vendor=$(worker_light_vendor "${1-}") || return 2
  model=$(worker_light_model "$1") || return 2
  worker_model_default_effort "$vendor" "$model" light
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
worker_model_chat_opens_all() {
  local file
  file=$(worker_model_chat_pin_file) && grep -qx 'open=all' "$file" 2>/dev/null
}

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
  ( . "${WORDS_LIB:-$HOME/.claude/hooks/lib/words.sh}" &&
    command -v words_span_live && command -v words_session_transcript && sid=$(worker_model_chat_session) &&
    words_span_live "$sid" "$(words_session_transcript "$sid")" ) >/dev/null 2>&1 && return 0
  [ -n "$(find "$(worker_model_pin_grant)" -mmin "-$WORKER_MODEL_PIN_TTL_MIN" 2>/dev/null)" ]
}

# Set in the parent shell after the pin file's last write of this process. A cache filled inside
# $(worker_model_pins) would not be there for the next vendor.
worker_model_prime_pins() { # file
  [ -n "${1-}" ] && [ -r "$1" ] || return 0
  _WM_PIN_FILE=$1
  # $(<file) keeps every line; a trailing newline is only a terminator for `read`.
  _WM_PIN_TEXT=$(<"$1")
}

worker_model_pin_line() { # file key
  local line=''
  if [ -n "${_WM_PIN_FILE+x}" ] && [ "$1" = "$_WM_PIN_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$2"=*) printf '%s\n' "${line#"$2"=}"; return 0 ;;
      esac
    done <<<"$_WM_PIN_TEXT"
    return 0
  fi
  [ -f "$1" ] || return 0
  [ -r "$1" ] || return 1
  awk -v prefix="$2=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' \
    "$1" 2>/dev/null
}

# Fast mode is a MODIFIER of the chat pin and lives on its second line, `<vendor>_fast=on`: it is
# written and cleared by the same `chat-pin` call, so it can never outlive the pin it belongs to.
worker_model_chat_fast() { # vendor
  local file
  file=$(worker_model_chat_pin_file) || return 1
  [ "$(worker_model_pin_line "$file" "${1}_fast")" = on ]
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
      # A pin that goes takes its own fast line with it: a modifier left behind by a met wall would
      # keep making that vendor's runs fast with no pin left to read it off.
      if [ -r "$file" ] && [ -n "$csv" ]; then grep -Ev "^${key}(_wall)?=" "$file" || true
      elif [ -r "$file" ]; then grep -Ev "^${key}(_wall)?=|^${key%_profile}_fast=" "$file" || true; fi
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
  case "$vendor" in claudeb | codex | gemini | grok | opencode | light) ;; *)
    printf 'worker-model: unknown vendor: %s\n' "$vendor" >&2; return 2 ;;
  esac
  case "$state" in on | off) ;; *)
    printf 'worker-model: unknown state: %s\n' "$state" >&2; return 2 ;;
  esac
  # Parking a vendor takes it out of every router at once, so it is Egor's hand only — the menubar
  # shells out from Hammerspoon, which carries no CLAUDECODE.
  if [ -n "${CLAUDECODE:-}" ]; then
    printf 'worker-model: pause switches are Egor'"'"'s: the menubar (LLM Limits -> vendor -> Pause/Resume, and LLM Limits -> Light) is his own hand on them\n' >&2
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
  ) 9>"$file.lock" || return
  [ "$vendor" = light ] || return 0
  worker_light_agents_sync ||
    printf 'worker-model: the Light switch moved, but the agent list in %s did not follow it\n' \
      "$(worker_light_settings_file)" >&2
  return 0
}

worker_light_settings_file() {
  printf '%s' "${WORKER_LIGHT_SETTINGS:-$HOME/.claude/settings.json}"
}

# Off, the two Light agent types leave every chat's agent list: the harness drops a type named by a
# deny rule `Agent(<type>)` from what it offers the model and refuses its spawn. The settings file
# is every profile's symlink target, so the write goes through to the real file, and only on change.
# Claude Code writes the same file without any lock this side could share, so the write is a
# compare-and-swap: a file that changed while the rules were computed is read again, never
# overwritten. `cp -p` keeps the file's mode, which a bare mktemp would turn into 0600.
worker_light_agents_sync() {
  local settings real tmp orig new off=false attempt
  settings=$(worker_light_settings_file)
  real=$(realpath "$settings" 2>/dev/null) && [ -f "$real" ] || return 2
  worker_light_off && off=true
  for attempt in 1 2 3; do
    orig=$(cat "$real") || return 2
    new=$(jq --argjson off "$off" '["Agent(light-research)", "Agent(light-worker)"] as $rules
      | .permissions.deny = (((.permissions.deny // []) - $rules) + (if $off then $rules else [] end))' \
      <<<"$orig" 2>/dev/null) || return 2
    [ "$new" != "$orig" ] || return 0
    tmp=$(mktemp "$real.light.XXXXXX") || return 2
    if ! { cp -p "$real" "$tmp" && printf '%s\n' "$new" >"$tmp"; }; then
      rm -f "$tmp"
      return 2
    fi
    if [ "$(cat "$real")" = "$orig" ]; then
      mv "$tmp" "$real" || { rm -f "$tmp"; return 2; }
      return 0
    fi
    rm -f "$tmp"
  done
  return 2
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
