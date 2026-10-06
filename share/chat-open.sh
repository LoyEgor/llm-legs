# Sourced. chat_open <command-file> <workdir> <prompt> [<session to resume>] -> prints "<account> <session>", or one
# reason line on stderr and returns 1. The caller hands in CHAT_OPEN_OPENER (a command line),
# CHAT_OPEN_WORKER_PICK (a path) and, optionally, CHAT_OPEN_PREFIX (words in front of claudeb).
chat_open_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

chat_open() {
  local file=$1 workdir=$2 prompt=$3 resume=${4:-} claudeb account session word prefix_quoted='' model=opus line
  local -a opener prefix=() launch=()
  read -r -a opener <<<"${CHAT_OPEN_OPENER:-open -a Terminal}"
  # %q: a prefix word is data. The generated script is what actually runs.
  if [ -n "${CHAT_OPEN_PREFIX:-}" ]; then
    read -r -a prefix <<<"$CHAT_OPEN_PREFIX"
    for word in "${prefix[@]}"; do prefix_quoted+=$(printf '%q ' "$word"); done
  fi
  # A bare `claude` runs on ~/.claude, which holds no login: the chat opens on a picked profile.
  claudeb=$(command -v claudeb) || { printf 'no claudeb on PATH\n' >&2; return 1; }
  # The chat role: this is an interactive chat, and the workers switch it meets is lifted only by the
  # pin written below, once the account is already chosen. --claim is what spreads parallel launches:
  # the marker ages out (WORKER_CLAIMS_TTL, default 600s); nothing releases it early.
  account=$("${CHAT_OPEN_WORKER_PICK:-$chat_open_repo/bin/worker-pick}" --account claudeb --role chat --model "$model" --claim 2>/dev/null) &&
    [ -n "$account" ] || { printf 'worker-pick names no Claude account\n' >&2; return 1; }
  session=${resume:-$(uuidgen | tr '[:upper:]' '[:lower:]')}
  if [ -n "$resume" ]; then
    # The chat's own launcher: a gateway chat reopened through claudeb is another conversation.
    line=$(python3 -B "$chat_open_repo/share/chat_resume.py" resume "$session" --account "$account") &&
      read -r -a launch <<<"$line" && [ "${#launch[@]}" -ge 3 ] &&
      launch[0]=$(command -v "${launch[0]}") ||
      { printf 'no launcher reopens chat %s: %s\n' "$session" "${line:-chat_resume failed}" >&2; return 1; }
    account=${launch[2]}
  fi
  {
    printf '#!/bin/bash\n'
    printf 'cd %q || exit 1\n' "$workdir"
    # No chat pin: an opened chat uses exactly what Egor's worker switches allow; `open=all` is his
    # word in a chat of his, never a launch default (2026-10-01).
    if [ -n "$resume" ]; then
      # --resume keeps the chat's own model and effort; a --model here would switch it.
      printf 'exec %s' "$prefix_quoted"
      printf '%q ' "${launch[@]}"
      printf -- '--permission-mode bypassPermissions %q\n' "$prompt"
    else
      printf 'exec %s%q profile %q --session-id %q --model %q --effort high %q\n' \
        "$prefix_quoted" "$claudeb" "$account" "$session" "$model" "$prompt"
    fi
  } >"$file" || { printf 'cannot write %s\n' "$file" >&2; return 1; }
  chmod 755 "$file"
  "${opener[@]}" "$file" >/dev/null 2>&1 || { printf 'the opener failed\n' >&2; return 1; }
  printf '%s %s\n' "$account" "$session"
}
