# Sourced by a suite that reaches `geminib families` or reads its models.json: every such reader
# gets a fixture cache, never ~/.cache/geminib, whether the suite runs alone or under run-suites.
geminib_families_seed() { # cache-dir
  mkdir -p "$1" &&
    jq --argjson now "$(date +%s)" '.fetched_at = $now | .attempted_at = $now' \
      "$(dirname "${BASH_SOURCE[0]}")/geminib-models.json" >"$1/models.json"
}
if [ -z "${GEMINIB_CACHE_DIR:-}" ]; then
  GEMINIB_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/geminib-cache.XXXXXX")
  export GEMINIB_CACHE_DIR
fi
[ -s "$GEMINIB_CACHE_DIR/models.json" ] || geminib_families_seed "$GEMINIB_CACHE_DIR"
# `families --union` reads every roster profile's own list and fetches a missing one: an empty roster
# and main's list seeded keep a suite on the real HOME from asking a real login.
if [ -z "${GEMINIB_PROFILES_DIR:-}" ]; then
  GEMINIB_PROFILES_DIR=$(mktemp -d "${TMPDIR:-/tmp}/geminib-profiles.XXXXXX")
  export GEMINIB_PROFILES_DIR
fi
[ -s "$GEMINIB_CACHE_DIR/models-main.json" ] || cp "$GEMINIB_CACHE_DIR/models.json" "$GEMINIB_CACHE_DIR/models-main.json"
