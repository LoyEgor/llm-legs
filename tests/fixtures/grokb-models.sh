# Sourced by a suite that reaches `grokb models` or reads its models.json: every such reader gets a
# fixture cache, never ~/.cache/grokb and never the real `grok` CLI behind it, whether the suite
# runs alone or under run-suites.
grokb_models_seed() { # cache-dir
  mkdir -p "$1" &&
    jq --argjson now "$(date +%s)" '.fetched_at = $now | .attempted_at = $now' \
      "$(dirname "${BASH_SOURCE[0]}")/grokb-models.json" >"$1/models.json"
}
if [ -z "${GROKB_CACHE_DIR:-}" ]; then
  GROKB_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/grokb-cache.XXXXXX")
  export GROKB_CACHE_DIR
fi
[ -s "$GROKB_CACHE_DIR/models.json" ] || grokb_models_seed "$GROKB_CACHE_DIR"
# The `grok` CLI behind grokb, stubbed to fail: a suite that let a fetch through would put a live
# network call inside a test run AND stamp `attempted_at` for a day afterwards. It records the call
# in `$GROK_FETCH_MARKER` when that is set, so a suite can assert a code path never fetched.
if [ -z "${GROKB_GROK_BIN:-}" ]; then
  GROKB_GROK_BIN="$GROKB_CACHE_DIR/no-grok"
  printf '#!/usr/bin/env bash\n[ -z "${GROK_FETCH_MARKER:-}" ] || printf "%%s\\n" "$*" >>"$GROK_FETCH_MARKER"\nexit 1\n' \
    >"$GROKB_GROK_BIN" && chmod +x "$GROKB_GROK_BIN"
  export GROKB_GROK_BIN
fi
