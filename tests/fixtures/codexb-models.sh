# Sourced by a suite that reaches `codexb models` (every codex launch resolves its family word
# through it): the list comes from this fixture cache, never ~/.codex or a codexb profile home,
# whether the suite runs alone or under run-suites. Its astra is gpt-6.1-astra, a slug no code
# spells, so a launch that names it went through the resolution.
[ -n "${CODEXB_MODELS_CACHE:-}" ] ||
  export CODEXB_MODELS_CACHE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codexb-models.json"
