# Diagnostics: llm-legs multi-account/limits ecosystem

For LLM sessions asked to fix limits, the menu, or claudeb. Read this before touching code.
Facts below are grounded in the code as of 2026-07-16 (line numbers may drift — re-grep, don't trust blindly).

## System map

- `llm-limits.sh` — read-only collector, writes `~/.llm-limits.json` (schema `{schema, fetched_at, vendors}`). A failed vendor refresh preserves its last valid buckets and records `vendors.<vendor>.refresh_error` as `{cause,at}`; passive collects preserve that outcome, and the next successful refresh of that vendor clears it. A full refresh with no successful vendor records the same shape at top-level `refresh_error` and exits nonzero; partial and targeted failures exit zero. `--refresh` polls free usage endpoints; `--start-windows` is the only paid path (never call from scripts). `--table`/`--plain`/`--json` control rendering; piped output defaults to JSON.
- `bin/claudeb` — account prober/launcher. Snapshots per account in `~/.claude-profiles/.claudeb/limits/<name>.json`:
  ```json
  {"five_hour":{"used_percentage":6,"resets_at":1784044800,"as_of":1784031056,"origin":"usage"},
   "seven_day":{...}, "fable":{...}, "auth":{"status":"ok","checked_at":1784031056}}
  ```
  `origin` ∈ `usage|headers|cached`. `auth.status` is only ever `"ok"` or `"expired"` (never `needs re-login`/`auth_needed` — those are free-text `cause`s or Codex-only concepts, respectively).
  Two independent OAuth-heal paths sharing `oauth-attempts.json`: **warm** (drives the real `claude` CLI's own OAuth rotation, zero-cost, comment at `bin/claudeb:632-635` — a token-endpoint 429/failed record must never gate it) and **direct refresh** (claudeb's own curl POST to the token endpoint, `oauth_refresh()`). `.claudeb-state` = current account name (single line); `disabled` = one excluded-account name per line, absent file = all enabled — this is the **worker pool**, and all three vendors now share it (`share/worker-pool.sh`, one file per vendor: `~/.claude-profiles/.claudeb/disabled`, `~/.codex-profiles/.codexb/disabled`, `~/.gemini-profiles/.geminib/disabled`; the dot-directory keeps it outside the profile enumerators' `*` glob). Exclusion speaks for AUTOMATIC selection only — `worker-pick`, `codexb pick`, and every menu-driven choice skip the account, while naming it directly still runs it. Each vendor refuses to exclude its last member, because an empty pool leaves selection nothing to answer and no way back except editing the file. `claudeb enable|disable`, `codexb enable|disable`, `geminib enable|disable`; the state is visible in each tool's own `list`/`status` (`(out of pool)`), in the table's `ROT` column (`off`), and as the menu checkbox.
  Entry points, and the whole reason there is no daemon: an **interactive** run must name a profile (`claudeb profile <name>`; bare `claudeb` and any argument list without `-p`/`--print` print the profile list and exit 2), while a **headless** run (`-p`/`--print`, i.e. a program calling claudeb — find-truth, usage-ai-report, any script) takes its account from `worker-pick --account claudeb` and then runs exactly the `claudeb profile <acct> …` path — in-process, so there is no second `claudeb` in the process tree. That path has no wall, no hold, and no retry: nothing selectable exits immediately with the query's own **3** (a caller choosing between "retry after the reset" and "this is misconfigured" needs those apart), a missing or unusable `worker-pick` exits 2, and no request is ever parked until it becomes a 503. `CLAUDEB_WORKER_PICK` overrides the binary (a sibling of the resolved script wins over `PATH`, so both halves of the query contract come from one checkout). Headless runs never restamp `.claudeb-state`. `claudeb use <name>` writes the same `claudeb_profile=` pin in `~/.claude/worker-model` that `/worker claudeb <name>` sets — the pin every consumer already reads (worker-pick routing, `worker-limit-gate.sh`, the statusline `w:cb @`) — leaving `worker=` alone so naming an account cannot also re-route work to another vendor; `use` with no name prints the pin, `use --clear` removes it, an unroutable name is refused, and a pin on an out-of-pool account warns that worker-pick will not honor it.
- `bin/codexb` + `codex-quota.py` — same idea for Codex CLI, no proxy: per-account `CODEX_HOME` under `~/.codex-profiles/<name>`; quota via zero-spend app-server RPC (`account/rateLimits/read`), cached in `~/.llm-limits-codex.json`. `codexb status` prints one line per account (`main: Logged in ... | 5H ... | WEEKLY ...`); an account needing login shows `auth_needed`/`Not logged in` with no usage buckets.
- `bin/geminib` + `agy-quota.py` — Antigravity profiles without touching the live login: `main` uses the real `HOME`; named profiles run with `HOME=~/.gemini-profiles/<name>`. There is no supported narrower profile flag or environment variable. `geminib profile <name>` creates and launches a profile for its one-time Google login; `list`/`status` probe each profile independently. Main quota stays in `~/.llm-limits-gemini.json`; named caches live in `~/.llm-limits-gemini/<name>.json`.
- `bin/review-bench` — blind review benchmark runner. Antigravity cells are explicit-only and always run the review skill (`--raters agy-pro-<low|high>-skill`, `agy-flash36-<low|medium|high>-skill`, or `agy-flash35-<low|medium|high>-skill`; a skill-less spelling is refused) and launch through `geminib profile <account>`, since agy resolves its Google account from HOME and takes no account flag. Every run executes in a sealed clone and keeps `raw-<rater>.md`, `agy-<rater>.log`, `usage-<rater>.jsonl`, and normalized `findings-<rater>.jsonl` under the run directory. Empty, malformed, error, and headless permission-denied output fail closed. Skill cells invoke the imported official Gemini CLI `code-review` extension; its Markdown is adapted to the shared finding schema. OpenCode cells (`oc-*`, optionally suffixed `-anthropic`/`-google` to inject a published review methodology into the toolless prompt) share one subscription gateway: the gate admits the longest expected job first (and cells are submitted slowest-first, since priority only orders what is already queued), because the gateway parallelises fine and the makespan is decided by whether a slow cell waits behind fast ones. Each cell's deadline and token ceiling are scaled from its measured cost rather than shared, and a cell that summarises the diff instead of reviewing it — one low-severity change description per hunk, which parses as findings and looks productive — fails closed. A model that ignores reasoning suppression is offered only with an effort (`oc-grok45-low`), because the effortless spec would stall the gateway for minutes. `--verify <oc-model>` checks every finding back against the file it cites with a second cheap in-plan call and keeps only the survivors, writing the full judgment to `verified-<rater>.jsonl`; it fails open on an unusable answer. The verifier is resolved through the same `parse_rater` refusals as a cell (a model measured unusable, or one that needs an explicit effort, cannot verify) and obeys the same 429 stop-the-run rule — findings left unchecked by a wall are counted in `verifier_unverified`, so an unverified run never reads as a verified one. Every side must declare a clean review with the literal marker `NO FINDINGS`: an empty findings file otherwise means the rater answered in prose or stopped mid-turn, and that cell is recorded as errored to be rerun rather than as a commit with nothing wrong with it. `--repeat N` keeps `raw-<rater>-sN.json`/`usage-<rater>-sN.json` per sample and returns the canonicalised union of all of them. Finding paths are canonicalised to repository-relative form first, since raters cite markdown links, absolute paths and sealed-clone paths that otherwise defeat both the file lookup and deduplication. `review-bench oc-models` prints what the tool actually knows about the gateway: the measured capability table (`OPENCODE_MODEL_FACTS` — whether reasoning-off works, whether an effort scales thinking, measured review seconds) next to the recorded per-cell success rate from every past run, so a model that starts failing is visible without editing prose. A cell measured unusable is refused by name with its evidence. Account handling is shared by every side: `SIDE_RUNNERS`/`SIDE_WALL`/`SIDE_POOL_VENDOR` in `bin/review-bench` say how a vendor launches, how it words an exhausted account, and which pool vendor it is, and one runner then asks `worker-pick --account <vendor> [--exclude …]` for each attempt, retires a walled account for the rest of the run (keyed per quota bucket, since Claude bills fable separately and Gemini bills per model, so a walled 3.1 Pro must leave that account's flash cells alone), and records the account that actually answered — so an OpenCode 429 (its own dollar window, not weather) stops that side outright while Gemini or Claude simply continue on the next account.

  A review-bench rater reviews commit X in isolation from every descendant of X, because descendants usually contain the fixes. Every current and future rater path must use a sealed view, either a sealed clone or a SHA-pinned prompt, and every new rater kind must be added to the guard test.
- `bin/opencode-go` — OpenAI-compatible client for the OpenCode **Go** subscription only
  (`https://opencode.ai/zen/go/v1`, key from keychain service `opencode-go`, never in argv;
  `run` refuses any model outside the plan's `/models` list, cached 10 minutes). The Go plan's
  own usage percentage is not exposed by any endpoint. Latency is decided by output volume, so
  reasoning is the whole game: `--no-reasoning` negotiates `reasoning_effort:"none"` →
  `chat_template_kwargs.enable_thinking:false` → a `</think>` assistant prefix → plain, because
  which one a model accepts varies **between requests for the same model** (a rejection is a hard
  400, and the prefix can make a model answer nothing at all, which retires that strategy too).
  The gateway's own ~190s **upstream idle timeout** is the root cause of every intermittent 503
  here (opencode#30002: a reasoning model emits no output token for 2-4 minutes, the connection is
  closed for inactivity, input tokens already billed; a configurable timeout and reasoning-token
  keepalive were both declined). It is not a local bug and there is no vendor status page, so
  reproduce a failure at least twice before chasing it in this repo. Some models — grok-4.5 and the
  deepseek family — ignore every reasoning-off knob and walk straight into that timeout, but they
  do honour an explicit `--effort low`: grok-4.5 reviewed a 54k-token diff in 8-91s over six runs
  with no failure, against 196-436s with 503s on the reasoning-off path. So a stall on such a model
  is a missing budget, not weather.
  Requests are buffered and retried on 5xx; a 5xx that arrives only after `OPENCODE_GO_SLOW_SWITCH_S`
  means the generation outlived that deadline, so the next attempt streams. A transport failure —
  curl exits non-zero and reports `000` because the gateway hung, reset or spoke bad HTTP/2 —
  counts as the same class, and is the case the escalation exists for — which helps only a
  model that actually emits tokens while working, never one that is silently thinking. A
  stream's stall detector (`OPENCODE_GO_STALL_S`) is its only deadline — it deliberately carries no
  `-m` cap, because any cap short enough to matter also kills a legitimate long generation
  (`deepseek-v4-pro` needs ~1000s). `minimax-m3` ignores every strategy and needs ~38k tokens of
  thinking before it answers, so it only works with a token ceiling above that, never below it.
  **An empty answer with exit code 0 is two different bugs, and the envelope names which.**
  `finish_reason:"length"` with empty content means the whole token budget went into reasoning and
  the answer never started — suppress reasoning (`--no-reasoning`) or raise the ceiling above the
  model's thinking, and never lower `--max-tokens` to "save" anything, because the budget is spent
  on thinking first. `finish_reason:"stop"` with empty content is the opposite: the model chose to
  end the turn, which is weak instruction following, not a budget — grok-4.5 does this when a
  review methodology is injected into its prompt (2 of 3 passes, after 88-122s), and the
  `</think>` prefill strategy can trigger it in any model. Neither case is a usage limit; a real
  wall is an HTTP 429 naming `limitName`. Because both symptoms look identical from the outside,
  read `finish_reason` before changing any knob.
- `bin/llm-limitsd` — **SHADOW MODE** (step 2 of the sqlite control-plane migration; runs alongside
  the legacy path and touches none of it). Small Python 3 stdlib daemon (`sqlite3` + `http.server`),
  the sole writer of a durable ledger that replaces the flock'd JSON read-modify-write the bash
  writers use today. HTTP API on `LLM_LIMITSD_PORT` (default 45791, 127.0.0.1 only):
  `POST /runs` (enqueue with a target set fixed at enqueue),
  `POST /runs/<id>/steps` (step transitions with evidence), `POST /observations` (typed observation
  ingest), `GET /runs/<id>`, `GET /state` (reducer-derived per-account auth+window state),
  `GET /healthz`. SQLite db at `LLM_LIMITSD_DB` (default `~/.claude-profiles/.claudeb/limitsd.sqlite`,
  WAL, single-process writer); tables `runs`/`steps`/`observations`. After each mutation it atomically
  rewrites a read-only projection at `LLM_LIMITSD_PROJECTION` (default `~/.llm-limits-shadow.json` —
  **NOT** the real `~/.llm-limits.json`) in the real cache's schema. Invariants: a run reaches
  `succeeded` only when every required target has a proven success terminal, else
  `partial/failed/interrupted` (never silently clean); `start-window` success needs a post-action
  reconcile observation (`observed_at >= step.started_at`, fresh `resets_at`) — HTTP 200 alone is not
  success; a timeout is a recorded step outcome; on restart an orphaned `running` step becomes
  `interrupted` (reason_code 87), never a silent kill; account auth is reducer-derived and only
  affirmative evidence (reason_code 2) can expire it — capacity weather (reason_code 75) never does;
  the projection is a pure, byte-stable function of ledger state. A corrupt/foreign db is never
  silently recreated: the daemon exits `78` (EXIT_DB_UNRECOVERABLE) with the reason on stderr, and
  the plist's `ThrottleInterval` (30s) keeps `KeepAlive` from hot-looping on it. Launchd plist FILE
  at `launchd/com.llm-limitsd.plist` exists but is NOT installed — rollout is a later migration step.
  Suite: `bash tests/test_llm_limitsd.sh` (hermetic: temp db, child daemon on an ephemeral port).
- `bin/llm-limitsd-shadow-feed` — read-only bridge that feeds the shadow daemon from the legacy
  collector cache. It only READS `~/.llm-limits.json` (override `LLM_LIMITS_CACHE`) and POSTs typed
  observations to `LLM_LIMITSD_URL` (default `http://127.0.0.1:45791`): a `window` observation per
  present `five_hour`/`weekly`/`fable` bucket, a `rotation` observation (`enabled`+`is_current`), and
  — claude-only, default-deny — an `auth` `expired`/`affirmative` observation ONLY when
  `auth.status=="expired"` (never manufactures an "ok"). Idempotent: it stores the cache's
  `fetched_at` in `~/.claude-profiles/.claudeb/shadow-feed.state` (override `LLM_SHADOW_FEED_STATE`)
  and no-ops with zero HTTP when unchanged; state advances only on a fully-successful run, so any
  failure (unreachable daemon, non-2xx, malformed cache) exits nonzero and retries the whole batch.
  Collector `refresh_error` objects are run metadata, not usage observations, and are ignored by
  the bridge and shadow projection.
  Log at `~/.claude-profiles/.claudeb/shadow-feed.log`. Launchd plist FILE at
  `launchd/com.llm-limitsd-shadow-feed.plist` (WatchPaths on the cache + 900s poll) exists but is
  NOT installed. Suite: `bash tests/test_llm_limitsd_shadow_feed.sh`.
- `hammerspoon/llm-limits.lua` — menubar menu. Reads only `~/.llm-limits.json`; opening the menu renders the existing cache immediately, then `collectOnOpen()` starts a detached, rate-limited `llm-limits.sh` task and re-renders after completion. The collector owns execution timeouts; Lua's registry budgets only remove verifiably-dead task entries and never kill or forget a live task.
- `bin/worker-pick` — token-free implementation-worker routing over the passive merged cache. It prints independent Codex, Gemini, and Claude sides; every Gemini profile reads only its normalized `Gemini Models` five-hour/weekly buckets. Gemini reuses the existing effective-percentage, floor, runway, reset-bonus, staleness, and non-main-first ranking. `worker=gemini` makes the selected profile the leading `NEXT` candidate with `ACCOUNT: <name>`; `worker=auto` includes it conservatively until benchmarks establish a stronger routing weight. `gemini_profile=` is an explicit pin. `worker-pick --account claudeb|codex|gemini` is the machine-readable face of the same selection for callers that must pick an account themselves (`claudeb`'s headless routing, `review-bench`'s per-rater choice): one bare account name on stdout and nothing else, exit 3 when nothing is selectable — including an unhonorable `claudeb_profile=` pin, which fails rather than resolving to another account — and no `worker-pick.line.<acct>` write, because a query answers a caller instead of announcing a routing decision. `--exclude name[,name...]` drops accounts from that one query, which is how a caller that just watched an account wall asks for the next one; running out of candidates is exit 3, not a quieter answer. Unknown arguments are refused (exit 2) rather than ignored, since a silently dropped flag lets a caller believe it constrained an answer it did not. Callers must use this query rather than parsing the human-readable lines, whose wording is not a contract.
- `bin/statusline.sh` — Claude Code statusline. Per-segment sources: model/effort/`⚡`(fast_mode)/`1m` chip from the stdin payload; location from `~/.cache/claude-statusline/workdir-<session_id>` when it points at a live git dir (dangling record → unlinked + fall back to `workspace.current_dir`), rendered `<project> » <active>` whenever the active toplevel differs from the launch repo, `@<short-sha>` in red on detached HEAD; `w:` from `~/.claude/worker-model` shows the NEXT delegation target, account included: `w:codex @<pin>·<eff>` when `codex_profile` is pinned, else `w:codex ~<acct>·<eff>` where `~<acct>` is the `cx<mark><acct>` field of `worker-pick.line.<acct>` — the account a spawn would actually use, not a second ranking of the limits file; no parsable field → `~?`); `w:cb @<pin>·<model>·<eff>` when `claudeb_profile` is pinned, else `w:cb ~<account>·<model>·<eff>` where the account is the `cb<mark><acct>` field of `worker-pick.line.<acct>` — the account a spawn would actually use, NOT `.claudeb-state` (which records only the last profile launched); no parsable cache field → `~?`; `w:gem @<pin>·pro·hi` when `gemini_profile` is pinned, otherwise the Gemini account predicted by `worker-pick.line.<acct>`; `w:son` (+optional `sonnet_effort` tier) with missing file = the documented sonnet default and an unknown `worker=` value = `w:?`. Auto mode renders the cached Codex, claudeb, and Gemini candidate segments. Efforts abbreviate low/med/hi/xh/max/ultra; the account part renders magenta with `@` = pinned, `~` = an unpinned prediction. Rate limits always render from a stamped merged cache, never raw headers: `~/.claude/statusline-cache-rl` for `main` sessions and `~/.claude-profiles/.claudeb/limits/<acct>.json` for explicit claudeb accounts. A live `rate_limits` payload is merged strictly-newer (tmp+mv), and the merge result is what renders so a partial header backfills from cache. Uniform dimming on every path: `five_hour` past 1800s of `as_of` age (legacy caches without `as_of` use file mtime), `seven_day` past 21600s, plus origin=`cached`, expired auth, past `resets_at`, and llm-limits per-bucket stale flags; the `fb` segment reads `$LLM_LIMITS_FILE` (default `~/.llm-limits.json`) and also dims when that file itself is older than 21600s.

## Where to look, per symptom

| Symptom | Look here |
|---|---|
| Menu entry gray (stale), unsure why | `jq '.vendors.claude.accounts' ~/.llm-limits.json` for per-account `as_of`/`stale`/`origin` and local `enabled`/`rotation.usable` state |
| Auth expired / re-login loops | `jq '.auth' ~/.claude-profiles/.claudeb/limits/*.json`; `cat ~/.claude-profiles/.claudeb/oauth-attempts.json` — `outcome` values: `attempting/success/success-adopted/failed/429/revoked/warming/warm-failed`; only `revoked` (invalid_grant + unrotated refresh token, 6h/21600s backoff) sets `cause=needs re-login` in claudeb's own logs — `auth.status` itself is only ever `"ok"` or `"expired"` |
| One account shows zeroed/phantom buckets | Distinguish a genuinely-disabled/auth-needed account (`~/.claude-profiles/.claudeb/disabled`, Codex's `auth_needed: true` + no usage buckets in `codexb status` / `codex-quota.py`, or Gemini profile `auth_needed`) from a stale-but-real snapshot (has `as_of`, just old). Run `geminib status` and inspect `jq '.vendors.gemini.accounts' ~/.llm-limits.json`; Gemini routing accepts only `group == "Gemini Models"` |
| Wrong account picked | `cat ~/.claude-profiles/.claudeb/.claudeb-state` (last launched, drives `*`/`●`/`cb:`), `~/.claude-profiles/.claudeb/disabled` (out of the worker pool), `sed -n 's/^claudeb_profile=//p' ~/.claude/worker-model` (the pin, set by `claudeb use` or `/worker`, and it overrides the math), `cat ~/.cache/worker-pick.line.<acct>` (what the statusline's `w:cb` predicts), then inspect `worker-pick` output |
| A script's `claudeb -p …` run fails or lands on an unexpected account | It routes through `worker-pick --account claudeb`: run that directly for the name, and on exit 3 for the one-line reason it refused; plain `worker-pick` next to it for the full Claude-side account line behind that reason. An unhonorable `claudeb_profile=` pin fails instead of falling back, and `CLAUDE_LIMITS_ACCOUNT` inherited from a surrounding session excludes that account from selection — a `claudeb -p` launched inside a `claudeb profile X` session deliberately never picks X |
| Codex account shows blank buckets | `codexb status` or `python3 codex-quota.py \| jq '.accounts'` — `auth_needed: true` + an `error` field means the account needs `codex login`, distinct from a real zero-usage account |
| An `oc-*` review-bench cell is slow, empty, or errors | `review-bench oc-models` — the measured capability row says whether reasoning-off works for that model and what its review normally costs, and the health row says how often that exact cell has failed before. A 429 naming `limitName` is the plan's own dollar window: stop and come back in hours, never retry into it |
| An OpenCode call returned exit 0 with no findings | Read `finish_reason` in `raw-<cell>.json` before touching a knob: `length` means the budget went into reasoning (suppress it or raise the ceiling), `stop` means the model ended the turn on its own (weak instruction following — drop an injected methodology, drop the `</think>` prefill). Neither is a limit |
| Choosing which OpenCode models to review with | `review-bench run <sha> --leg` — the composition that survived strict adjudication on four commits, with its verifier, and no vendor quota. `oc-models` prints why every other cell lost, including the plan models that failed screening, so the comparison is not re-run from scratch |
| An `agy-*` review-bench rater errors or unexpectedly has no findings | `run=$(find ~/.claude-profiles/.claudeb/worker-stats/benches -name meta.json -print \| sort \| tail -1 \| xargs dirname); jq '.rater_runs[] \| select(.side=="agy")' "$run/meta.json"; tail -80 "$run"/agy-agy-*.log; cat "$run"/usage-agy-*.jsonl` — empty output, malformed JSON/Markdown, quota/auth failures, and headless `/code-review` command-permission denials are rater failures, never clean zero-finding reviews |
| Suspected agy language-server port/lock clash | Live verdict (2026-07-24): three simultaneous flash/low `--print` processes in one checkout all returned rc=0 in 5s; each bound distinct random gRPC/HTTP ports, so multiple Gemini workers may run concurrently |
| macOS "A keychain cannot be found to store antigravity" dialog during a refresh | A Gemini profile HOME has no keychain: `ls -l ~/.gemini-profiles/<name>/Library/Keychains` must show a real directory holding `login.keychain-db`, with the matching password in the profile's `.keychain-password`. `bin/geminib help` creates a missing one, but never replaces a keychain already sitting there. Only agy's token-refresh path raises the dialog, so a probe on a still-valid token looks clean |
| Two Gemini profiles report identical quota, or a profile signs in as the wrong account | They are sharing one keychain, so they share the Google account: `grep applyAuthResult $(ls -t ~/.gemini-profiles/<name>/.gemini/antigravity-cli/log/*.log \| head -1)` prints the address each profile actually authenticated as. A `Library/Keychains` symlink is the cause; the next `geminib` run replaces it with the profile's own keychain and the profile then needs one interactive `geminib profile <name>` sign-in |
| Suspected agy `--print` argument-contract regression after an update | Canary: `out="$(~/.local/bin/agy --model gemini-3.6-flash --effort low --print-timeout 2m --dangerously-skip-permissions --print 'Reply with exactly AGY_PRINT_CANARY_OK and nothing else.')"; test "$out" = AGY_PRINT_CANARY_OK` — the prompt argument must remain last |

## The 429 taxonomy (do not conflate these)

Transient upstream 429s are still real. They are passed to the Claude CLI, which owns its
retry behavior; this project no longer turns them into account walls, holds, or locally
generated 503 responses.

1. **OAuth token-endpoint 429** — `bin/claudeb`'s `oauth_refresh()` backs off only the direct-refresh path (`oauth_backoff_until`); the warm/heal path uses its separate `oauth_heal_backoff_until` state.
2. **Warm-probe failure classification** (`bin/claudeb`'s `heal_one()`/`warm_accounts()`) — a failed zero-cost warm probe is classified into a cause (`timeout`, `warm-429`, `usage-probe-failed`, `warm-failed` = capacity-shaped upstream weather, vs. `needs-relogin`/`profile-setup` = auth-shaped), persisted as `warm_cause` in `oauth-attempts.json`. Capacity-shaped failures leave valid snapshots untouched and do not stamp auth expiry.

**Token-freeze switch** (experiment, see `docs/EXIT-PLAN.md`) — the file `~/.claude-profiles/.claudeb/token-freeze` (JSON `{started_at,until,reason}`; `until` in the past or missing = ignored/held) freezes every ROBOT path to the OAuth token endpoint: `oauth_refresh()`'s curl POST, `token-upkeep`, and all non-manual (heal, start-window, `--refresh --heal`) warm sessions all short-circuit. The only allowed token traffic is the user's manual per-account `claudeb warm <name>` (menu Hard-refresh) and the real Claude Code CLI's own refreshes. Every token-endpoint-relevant event — real attempts and outcomes, warm outcomes, adoptions, and freeze skips — is journaled append-only to `~/.claude-profiles/.claudeb/token-attempts.jsonl` (`{ts,account,kind,outcome,http,pid}`); a `frozen-skip` outcome means the freeze held that path (deliberate evidence, not an error). A dark account under freeze renders its stale-cause as `auto-refresh frozen (experiment); enter the account to refresh`.

## How to test

Suites (run from repo root):
- `bash tests/test_llm_limits.sh` — hermetic collector tests: schema, per-vendor normalization, freshness/`stale`, `usable_now`, table/plain/sort formatting.
- `bash tests/test_claudeb.sh` — `bin/claudeb` sourced as a bash library against a fixture `CLAUDEB_DIR` with stubbed `curl`/`security`/`claude`: merge/store/OAuth-attempt logic.
- `bash tests/e2e_surfaces.sh` — drives the **REAL** running Hammerspoon menubar (via `hs -c`), the real `llm-limits` CLI, and `claudeb status` against the real `~/.llm-limits.json`. Golden rule: every `hs -c` snippet only reads `package.loaded["llm-limits"]` and calls `menuItems()` — never assigns to a module field, or it silently breaks the user's live menubar.
- `bash tests/test_codexb.sh` — `bin/codexb` against a fixture `$HOME/.codex` tree and a fake `codex` binary.
- `bash tests/test_geminib.sh` — `bin/geminib` against fixture profile homes, a fake agy binary, and a fake zero-spend quota helper.
- `bash tests/test_opencode_go.sh` — `bin/opencode-go` against a scripted fake `curl`/`security`: the key stays out of argv, a transport failure retries and escalates instead of aborting, the escalated stream carries no wall-clock cap, and an empty streamed answer retires its reasoning-off strategy.
- `bash tests/test_review_bench.sh` — hermetic review-bench grammar, normalization, sealed-clone, the skill-only agy gate, per-run usage, and `/code-review` Markdown adapter tests; all agy calls use fixtures.
- `bash tests/test_llm_selfcheck.sh` — `bin/llm-selfcheck` (the daily safety-net job) against a fixture `$HOME`/repo with stubbed suites, `hs`/`osascript`/`launchctl`.

Golden rules:
- Verify the user-visible surface (menu render, `--table` output), not just internal state.
- Never mutate the live Hammerspoon singleton (see e2e_surfaces.sh rule above).
- Never point a test at the real `~/.claude-profiles/.claudeb` store — use `CLAUDEB_DIR` for fixtures.
- Reload the menu after a Lua change: `hs.reload()` (via `hs -c 'hs.reload()'`), then rerun `tests/e2e_surfaces.sh`.

## Reading `~/.llm-limits.json` as an LLM

Treat `stale`, `expired`, `as_of`, and `effective_pct` as the data-honesty contract. Never infer current availability from raw `used_pct` alone: keep it as provenance, check the bucket's `resets_at` against the current time, and refresh before acting on an old or rolled-over frame.

## Display contract (hammerspoon/llm-limits.lua)

- **Gray** = stale bucket (`.stale == true`), or the collector's own `.expired == true`, or the renderer's own render-time check that `resets_at` has already passed (>60s clock-skew tolerance) — this last case covers a window whose reset landed between collects, before the stored `expired` flag catches up. Missing or false `.stale`/`.expired` alone is not gray; a future `resets_at` is never gray.
- **Reset time** = the collector converts raw zero, empty, absent, and 1970-era reset placeholders to `resets_at: null`; Lua renders null/absent as `–`. Any real reset timestamp, including one the renderer now treats as past-due, remains visible as its actual clock time.
- **Refresh failure** = vendor `refresh_error` is `{cause:string,at:epoch}` from the collector. It renders as a dim `refresh failed <cause> · <age>` line inside that vendor section and persists across passive menu-open collects until that vendor refresh succeeds. Partial failures keep valid old buckets, do not raise alerts, and do not fail the collector process. Top-level `refresh_error` has the same shape and renders as a red top row; it is reserved for no available vendor data or a full refresh with zero successful vendors. The menu also renders an observed nonzero collector exit as a red runtime error when no cache-level global error exists; any later successful task, including a passive collect, clears that runtime residue after reading a valid cache without a top-level error.
- **Red** = usage warning colors only. Claude rotation metadata is computed locally from the enabled flag and snapshot auth status; wall metadata no longer exists.
- **Fable early warning** = when an `fb` bucket is at least 80%, only its usage-bar substring is red. The rest of the row retains its normal or stale color.
- **Table model and markers** = every row has first-class `5H%`/`WK%`/`FB%` and matching reset columns, plus `AGE`, `ROT`, `CR`, and `STATUS`; there is no `NOTE`. Rows without Fable render `-`. A `~` suffix marks a stale bucket and `!` marks an expired bucket; both may appear, and displayed percentages remain raw `used_pct` values. `AGE` comes from that row's account/vendor `as_of` (`2m`, `1h48m`, and similar).
- **Table rotation and credits** = `ROT` is `off` when the account is out of its vendor's worker pool (all three vendors), `limit-5h`/`limit-weekly`/`fb:limit-fable` when a local effective percentage reaches 100, otherwise `-`. Claude `rotation.usable.general` and `.fable` remain available to worker-pick. `CR` renders a numeric Codex `reset_credits` as `↻N`, including `↻0`.
- **Table status** = `STATUS` is `login needed` for a Codex account with `auth_needed == true`, a Claude account with a present non-`ok` `auth.status`, or a logged-out Gemini profile (`auth_needed == true`, collector-owned status `login needed`); other unavailable rows show their collector-owned status text; all other rows render `-`. A logged-out Gemini profile records its own `refresh_error` cause from the agy helper; a successful profile refresh clears it without changing sibling snapshots.
- **Gemini account rows** = with only `main`, the legacy single Gemini row remains unchanged. Once a named profile exists, every non-removed profile gets its own account, 5h, and weekly rows. A logged-out profile uses the shared `Log in…`/`Hard refresh`/`Remove…` submenu; login opens `geminib profile <name>`, hard refresh targets `gemini/<name>`, and `main` cannot be removed through geminib.
- **Plain model** = each line mirrors the table's labeled 5h/weekly/Fable values and resets, age, rotation, credits, and status. The same `~`/`!` markers apply, expired values are never rewritten to zero, and an unavailable vendor's `last_wall` is appended when present.
- **●** marks the current account from the account block's collector-owned `is_current` flag.
- **In-flight indicator** = passive menu-open collects never render an indicator. Verified-live explicit, hard, and start-window tasks share one registry and prefix the normal menubar title with `⟳ ` immediately; standing vendor or global errors prefix it with `⚠ ` when no explicit task is active. Resume-timer text remains visible. Ordinary entries use a 360s cleanup budget and start-window entries 1200s, but an over-budget task that still reports running remains registered and suppresses duplicates; only a verifiably-dead entry is removed.
- **Checkbox ("In worker pool")** appears on every real account row of all three vendors (`enabled` = not explicitly excluded) — toggling it calls that vendor's own `enable`/`disable`. It is also the first item of a **login-needed** row, since pool membership is independent of login state and that row would otherwise show the state without a way to change it. An explicit/pinned Claude profile entry is not part of `claudeb-store` and so still has no checkbox.
- An **explicit/pinned profile entry** is not part of `claudeb-store` and so never gets a checkbox: it's always shown direct, independent of worker-pool membership.

## Claude Code statusline hooks

`statusline-workdir-hook.sh` (PostToolUse matcher `Bash|Edit|Write|NotebookEdit|EnterWorktree|ExitWorktree`)
records the git toplevel a session actually works in; the status line shows it with a magenta `»`
marker when it differs from the launch repo. Rules:
- Events carrying `agent_id`/`agent_type` are ignored — subagent tool calls report the PARENT
  `session_id` and must never retarget the parent's display.
- Bash: the LAST `cd`/`git -C` in the command wins (`;`, `&`, `|`, `&&`, `||`, and
  newline-separated all match). `git -C <dir>` counts only when followed by a mutating
  subcommand (worktree/checkout/switch/commit/merge/rebase/cherry-pick/revert/restore/stash/
  am/reset/pull); read-only `git -C ... status/log/diff` never retargets.
- EnterWorktree records the toplevel of the `worktree at <absolute path>` in `.tool_response`
  (string or object); ExitWorktree deletes the session's state file. tmp/system/`~/.claude*`/
  node_modules paths are excluded; records older than 7 days are pruned.
- Also registered for SessionStart: `source` `startup`/`resume`/`clear` deletes the session's
  workdir state file (a fresh shell starts in the project dir, so surviving state would lie
  until the first cd); `compact` keeps it — the shell and its cwd survive `/compact`. This
  runs before the agent filter on purpose: `agent_type` on SessionStart means a top-level
  `claude --agent` session, not a subagent.
The statusline itself unlinks a state file that no longer points at a git dir.

State files are stored at:
- `~/.cache/claude-statusline/workdir-<session_id>`
- `~/.cache/claude-worker-tags/<agent_id>`

`worker-tag-hook.sh` derives the actual relay account/model/effort from Codex, claudeb, or `geminib profile`
launch commands and prefixes the tag onto later Bash activity descriptions for `codex-worker`,
`claudeb-worker`, and `gemini-worker` agents. It exits
silently for any `hook_event_name` other than PreToolUse (its rewrite payload hardcodes
`hookEventName: "PreToolUse"`, so a mis-registration must be a no-op).

`limits-triage-nudge.sh` (PostToolUse matcher `Bash`) scans Bash tool output for a limit-shaped
pattern (`no available accounts`, `API Error: 503/529`, `usage limit`, `overloaded`,
`anthropic-ratelimit`, `CLAUDEB_USAGE_LIMIT`, `claudeb ... timed out`) alongside a
claude/claudeb/anthropic/fable context word in the same output, and nudges the session to run
`llm-limits --table --no-write` instead of theorizing. Dedup: one nudge per session per
15 minutes, state in `/tmp/claude-limits-triage-nudge-<session_id>`.

To disable any of these hooks, remove its entry from `hooks.PostToolUse` or `hooks.PreToolUse` in
`~/.claude/settings.json`.

Debug workdir tracking (a mutating `git -C` subcommand or a `cd` is required to record):
`jq -cn --arg dir "$PWD" '{hook_event_name:"PostToolUse",tool_name:"Bash",session_id:"debug",cwd:$dir,tool_input:{command:("cd " + ($dir | @sh))}}' | ~/.claude/hooks/statusline-workdir-hook.sh; cat ~/.cache/claude-statusline/workdir-debug`

Debug worker tag capture:
`echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"codex-worker","agent_id":"debug","tool_input":{"command":"true","description":"Worker account: main · high"}}' | ~/.claude/hooks/worker-tag-hook.sh; cat ~/.cache/claude-worker-tags/debug`
