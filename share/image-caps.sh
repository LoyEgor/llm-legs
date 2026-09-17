#!/usr/bin/env bash
# Sourced by the image scripts. Manifests: share/image-caps/<vendor>.json (schema: share/image-caps/README.md).

image_caps_file() { printf '%s/share/image-caps/%s.json' "$1" "$2"; }

image_caps_get() { # root vendor jq-filter
  jq -r "$3" "$(image_caps_file "$1" "$2")"
}

# The tool schema lives in the CLI binary, so a CLI version other than the verified one means the
# manifest may promise the wrong limits. Never fatal: the generation still runs, the caller relays.
image_caps_check() { # root vendor binary -> "caps=fresh" | "caps=stale cli=<live> verified=<manifest>"
  local root=$1 vendor=$2 binary=$3 file expected live
  local -a args=()
  file=$(image_caps_file "$root" "$vendor")
  expected=$(jq -r '.cli.version' "$file")
  while IFS= read -r arg; do args+=("$arg"); done < <(jq -r '.cli.version_args[]' "$file")
  live=$("$binary" "${args[@]}" 2>/dev/null | head -n 1 | LC_ALL=C grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1) || live=''
  if [ -n "$live" ] && [ "$live" = "$expected" ]; then
    printf 'caps=fresh\n'
  else
    printf 'caps=stale cli=%s verified=%s\n' "${live:-unknown}" "$expected"
  fi
}

image_caps_model_check() { # root vendor kind observed -> "model=<observed> model_caps=fresh|stale|unknown"
  local root=$1 vendor=$2 kind=$3 observed=$4 expected
  expected=$(image_caps_get "$root" "$vendor" ".model.$kind // empty")
  if [ -n "$expected" ] && [ -z "$(image_caps_get "$root" "$vendor" ".short.$kind // empty")" ]; then
    printf 'model=%s model_caps=stale short=missing\n' "${observed:-unknown}"
  elif [ -z "$observed" ]; then
    printf 'model=unknown model_caps=unknown\n'
  elif [ "$observed" = "$expected" ]; then
    printf 'model=%s model_caps=fresh\n' "$observed"
  else
    printf 'model=%s model_caps=stale verified=%s\n' "$observed" "${expected:-none}"
  fi
}
