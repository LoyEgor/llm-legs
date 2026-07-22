# Shared invariants

Some values are duplicated across scripts written in different languages (bash,
jq, Lua, prose) because each implementation is independent — no shared library
spans `bin/claudeb`, `bin/statusline.sh`, `bin/worker-pick`, `llm-limits.sh`, the
Hammerspoon renderer, and the docs. When such a value drifts in one place, the
system misbehaves silently. `tests/test_consistency.sh` re-extracts each value
from the live files and fails if any site disagrees with the canonical value
below. This table is the canonical source; the test names it in every failure.

| # | Invariant | Canonical value | Implementation sites |
|---|---|---|---|
| a | Staleness / dim thresholds | five_hour `1800`s, weekly `21600`s, fable `21600`s | `bin/claudeb` `account_data` jq (`is_stale(.five_hour; 1800)` / `.seven_day; 21600` / `.fable; 21600`); `bin/statusline.sh` dim logic (`now - h5_as_of > 1800`, `now - wk_as_of > 21600`, `now - limits_mtime > 21600`); `docs/statusline-contract.md` usage-table prose (`as_of` >1800s / >21600s, mtime >21600s); `hammerspoon/llm-limits.lua` consumes the collector's `.stale` flag rather than a local threshold (`bucket.stale == true`) — it must stay flag-driven, never hardcode a number |
| b | Keychain service formula | `Claude Code-credentials-` + first 8 hex of `shasum -a 256` of the profile path | `bin/claudeb` `keychain_service`; `llm-limits.sh` `claude_subscription_type` |
| c | worker-pick cache line format | `cx<mark><acct>·<model>·<eff> cb<~|@><acct>·<model>·<eff>` (producer printf `cx%s%s·<model>·%s %s·%s·%s` with the codex model label interpolated from `~/.codex/config.toml`, `cb` prefixes `cb~`/`cb@`/`cb~?`) | producer `bin/worker-pick` `write_cache`; consumer `bin/statusline.sh` reads `worker-pick.line.<acct>` verbatim |
| d | Weather HTTP classes | `000`, `429`, `5xx` (`5[0-9][0-9]`) are weather — they never write an auth verdict (`expired`/`revoked`/`auth-failed`) | `bin/claudeb` `probe_weather_failed` case pattern; `bin/claudeb` `oauth_refresh` outcome classification |
| e | OAuth token-endpoint 429 cooldown | `900 * 2^(max(1, strikes)-1)`, capped at `14400`s (4h); a longer vendor `Retry-After` wins | `bin/claudeb` `oauth_backoff_until`; `llm-limits.sh` `claude_stale_cause` |
