# The one account roster per vendor: the set the menubar lists and its Remove takes accounts out of
# (shared-invariants row dg). Every consumer that picks or accepts an account reads it here and
# intersects it with its own local readiness (a signed-in browser profile, no wall); a local profile
# alone never makes an account.

account_roster_share=$(cd -P "${BASH_SOURCE[0]%/*}" && pwd)
. "$account_roster_share/gemini-accounts.sh"
. "$account_roster_share/codex-accounts.sh"

# A setup token, a limits snapshot or a profile directory each make a Claude account (row x).
claude_account_names() {
  local store="${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}" path name
  {
    if [ -d "$store/tokens" ]; then
      for path in "$store/tokens"/*; do
        if [ -f "$path" ]; then printf '%s\n' "${path##*/}"; fi
      done
    fi
    if [ -d "$store/limits" ]; then
      for path in "$store/limits"/*.json; do
        if [ -f "$path" ]; then
          name=${path##*/}
          printf '%s\n' "${name%.json}"
        fi
      done
    fi
    if [ -d "$HOME/.claude-profiles" ]; then
      for path in "$HOME/.claude-profiles"/*; do
        if [ -d "$path" ]; then printf '%s\n' "${path##*/}"; fi
      done
    fi
  } | LC_ALL=C sort -u | { grep -vx -e main -e - || true; }
}

# The roster grok-quota.py itself would walk: `main` is the real ~/.grok and counts only once it
# carries a login, dotted names are grokb's own state, and `main` under the profiles directory is
# a name nothing can address.
grok_account_names() {
  local dir="${GROKB_PROFILES_DIR:-$HOME/.grok-profiles}" path name
  [ -f "${GROKB_MAIN_GROK_HOME:-$HOME/.grok}/auth.json" ] && printf 'main\n'
  if [ -d "$dir" ]; then
    for path in "$dir"/*; do
      [ -d "$path" ] || continue
      name=${path##*/}
      case "$name" in .*|main) continue ;; esac
      printf '%s\n' "$name"
    done | LC_ALL=C sort
  fi
}

# Why no vendor can be read on this machine, one clause per vendor, or a failure when one could: no login here,
# or a login whose vendor CLI is not installed (a fresh node). grok reads its auth.json without its CLI. The roster
# keeps a Codex or Gemini `main` with nothing behind it; this asks whether anything is signed in at all.
accounts_unreadable_here() {
  local clauses=() codex_dir="${CODEXB_PROFILES_DIR:-$HOME/.codex-profiles}"
  local gemini_dir="${GEMINIB_PROFILES_DIR:-$HOME/.gemini-profiles}"
  claude_account_names | grep -q . && return 1
  clauses+=("claude: no account")
  if [ -f "$HOME/.codex/auth.json" ] || [ -n "$(ls -A "$codex_dir" 2>/dev/null)" ]; then
    command -v codex >/dev/null 2>&1 && return 1
    clauses+=("codex: CLI not installed")
  else
    clauses+=("codex: no account")
  fi
  if [ -d "$HOME/.gemini" ] || [ -n "$(ls -A "$gemini_dir" 2>/dev/null)" ]; then
    { command -v agy || [ -x "${AGY_BIN:-$HOME/.local/bin/agy}" ]; } >/dev/null 2>&1 && return 1
    clauses+=("gemini: agy not installed")
  else
    clauses+=("gemini: no account")
  fi
  grok_account_names | grep -q . && return 1
  clauses+=("grok: no account")
  local joined
  printf -v joined '%s; ' "${clauses[@]}"
  printf '%s\n' "${joined%; }"
}

# The profiles file, one name per line in key-priority order; an absent file is the one default
# profile `-` (row al).
opencode_account_names() {
  local file="${OPENCODE_GO_PROFILES:-$HOME/.config/opencode-go/profiles}"
  if [ -r "$file" ]; then
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" | { grep -v -e '^#' -e '^$' || true; }
  else
    printf -- '-\n'
  fi
}

account_roster() { # vendor
  case "$1" in
    claude|claudeb) claude_account_names ;;
    codex) codex_account_names ;;
    gemini)
      local gemini_base_home="${gemini_base_home:-$HOME}"
      local gemini_profiles_dir="${gemini_profiles_dir:-${GEMINIB_PROFILES_DIR:-$HOME/.gemini-profiles}}"
      gemini_account_names
      ;;
    grok) grok_account_names ;;
    opencode) opencode_account_names ;;
    *) printf 'account-roster: no roster for vendor %s\n' "$1" >&2; return 2 ;;
  esac
}

# 0 when the account may be used, 2 with one stderr line when the roster does not list it: an
# explicit name off the roster is a usage error, never a reason to fall back to another account.
account_roster_refuse() { # tool vendor account
  local roster
  roster=$(account_roster "$2") || return 2
  [ -n "$3" ] && grep -Fqx -- "$3" < <(printf '%s\n' "$roster") && return 0
  printf '%s: unknown account: %s (not on the %s roster the menubar lists: %s)\n' \
    "$1" "$3" "$2" "$(paste -sd, - < <(printf '%s\n' "$roster"))" >&2
  return 2
}

# Remove's second half, the same for every vendor (row di): whatever share/account_stores.py lists
# for the vendor still holding the removed name goes, one line per store.
account_purge() { # tool vendor name
  local gone
  if ! gone=$(python3 "$account_roster_share/account_stores.py" purge "$2" "$3"); then
    printf '%s: %s is off the roster, but its per-account stores were not purged; rerun: python3 %s purge %s %s\n' \
      "$1" "$3" "$account_roster_share/account_stores.py" "$2" "$3" >&2
    return 1
  fi
  [ -z "$gone" ] || printf '%s\n' "$gone" | sed "s|^|$1: purged |"
}

# `<vendor>b web <name>`: one sign-in shape for every vendor with a hidden-browser route.
account_web_cli() { # vendor
  case "$1" in
    gemini) printf '%s/../bin/gemini-web' "$account_roster_share" ;;
    codex) printf '%s/../bin/chatgpt-web' "$account_roster_share" ;;
    *) return 2 ;;
  esac
}

# The login alone binds nothing: only `status` writes the email and the balance the rotation and
# the menu read, so the owner is held here until the window is quit and status has run.
account_web_login() { # tool vendor name
  local cli out rc=0
  [ "$#" -eq 3 ] || { printf 'usage: %s web <name>\n' "$1" >&2; exit 2; }
  account_roster_refuse "$1" "$2" "$3" || exit 2
  cli=$(account_web_cli "$2")
  out=$("$cli" login --wait "$3") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: %s\n' "$1" "$(jq -r '.reason' < <(printf '%s\n' "$out") 2>/dev/null || printf 'the login window did not open')" >&2
    exit "$rc"
  fi
  out=$("$cli" status "$3") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: %s is not ready: %s\n' "$1" "$3" "$(jq -r '.reason // "signed in as \(.email), bound to \(.bound_to)"' \
      < <(printf '%s\n' "$out") 2>/dev/null || printf 'status failed')" >&2
    exit 4
  fi
  jq -r --arg tool "$1" --arg name "$3" '"\($tool): \($name) ready — \(.bound_to // .email), "
    + (if .plan then "plan \(.plan)" elif .credits != null then "\(.credits) credits" else "no balance read" end)' < <(printf '%s\n' "$out")
}

account_web_offer() { # tool vendor name
  local answer=''
  "$(account_web_cli "$2")" accounts 2>/dev/null |
    jq -e --arg name "$3" 'any(.accounts[]; .account == $name and .login)' >/dev/null && return 0
  printf 'Also sign %s into the web routes now? [y/N] ' "$3" >&2
  read -r answer || :
  case "$answer" in [yY]|[yY][eE][sS]) account_web_login "$1" "$2" "$3" ;; esac
}
