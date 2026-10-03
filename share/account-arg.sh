# Sourced by every media script that spends a generation: an explicit --account that is empty or
# not a profile name is refused before anything runs, never read as "no account" (rotation).
account_arg() { # value
  [[ "${1-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] && return 0
  printf '%s: --account needs a profile name matching ^[a-z0-9][a-z0-9-]*$, got '\''%s'\''\n' "${0##*/}" "${1-}" >&2
  exit 2
}
