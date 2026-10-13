# review-bench dies at import when agy drops a gemini family a panel names

Status: open — To: next night (review-bench)

Found 2026-10-13 10:09Z by night fixer run harness-speed-suite-audit-llm-legs-test-legs-routing-20261012T235326Z-6558:
`agy models` lists Gemini 3.8 Flash alone (no Pro), and geminib's families cache
(`~/.cache/geminib/models.json`, 24 h TTL) holds `flash38` alone. review-bench
`share/rbench/__init__.py:1008` runs `accounts.validate_review_tiers()` at import; `raters.parse_rater`
raises on `agy-pro-high` (T2 standard), so every `review-bench` command exits 1. That includes
`review-bench fix <round> --print`, which `bin/doctor-fix close` reads: every run with a `ROUND:` stays open.

Fix in review-bench: a cell whose gemini family the live list lacks is excluded like a retired cell
(its leg reads off), never an import-time crash; validation at import rejects only malformed specs.
Test: a fake `geminib families` without pro, `review-bench tiers` exits 0 and the pro cell reads excluded.

Done when `review-bench fix <round> --print` reads a round while `geminib families` lacks pro.
