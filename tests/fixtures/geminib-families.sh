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
