# Claude Code with OpenAI accounts

`claudegpt` opens Claude Code through a local OpenAI subscription bridge. It does
not change `claudeb`, `codexb`, the worker toggle, or their account stores.

```sh
claudegpt list
claudegpt p notcom
claudegpt p notcom --model astra
```

Sol is the default. Inside the conversation use `/model anthropic.ccr.sol` or
`/model anthropic.ccr.astra`. Claude models still use `claudeb`.
When shared settings contain an `anthropic.ccr.*` model, `claudeb` adds `--model fable[1m]` for interactive and headless launches unless the caller supplies `--model`, without changing the settings file.

`codexb status` on a TTY is the second way in: Enter on an account row runs
`claudegpt p <name> --model astra`, so picking a Codex account there opens Claude Code
on that OpenAI subscription rather than the Codex CLI. Every other `codexb` verb —
`profile`/`p`/`run`, `<name> exec`, `login` — still runs native Codex, and the
account stores are untouched by the change. Its rows are the OpenAI accounts only, the
way `claudeb status` shows the Anthropic ones only; neither picker offers the other
vendor's accounts, so each Enter reaches a launcher that can actually open the row.

`astra` rather than the `sol` default is deliberate wherever the OpenAI account is a
target he PICKED — the status picker's Enter and "Switch chat to this" onto a Codex row.
`share/chat_resume.py` `GATEWAY_SWITCH_ALIAS` is the one spelling, applied in that
module's `switch`/`launch` CLI modes — the "Switch chat to this" surfaces — and never
inside the library helpers (`docs/shared-invariants.md` row `cj`). A bare `sol`/`astra`
on the command line still wins. Reopening a chat is NOT a switch: `resume`, and the
library call `bin/chats` reopens through, keep the alias the chat was launched with, so
a saved Sol conversation reopens on Sol. Switching keeps the transcript either way —
the resolver emits `--resume <uuid>` exactly as before.

An account already signed in under `codexb` launches straight away: its canonical
login is reused read-only (see "Which accounts a gateway chat can open" below).
Launching a chat never opens a browser login automatically. Initial authorization
for a genuinely new account is explicit:

```sh
claudegpt login work4
```

Open the displayed OpenAI authorization link in the browser on this Mac. The
callback completes locally. The account name is a label: sign in to the account
that label represents. Existing gateway logins are reused. `claudegpt login work4`
remains available for login without launching a conversation; it cannot overwrite
an existing login. Headless `-p`/`--print` calls require a prior login.

To switch accounts, exit the chat, stay in the same project directory, then run:

```sh
claudegpt p work4 --continue
```

`--continue` resumes the latest conversation in that directory. Use Claude Code's
`--resume` picker when several conversations share a directory. History stays in
the shared Claude configuration; server-side cache reuse across accounts is not guaranteed.

Multiple concurrent conversations can run on the same gateway account. Login and
initial credential acquisition are serialized with an exclusive lock, while
authenticated launches run concurrently, each running its own isolated loopback bridge
and router database.

The launcher reads the usual Claude configuration. Every existing agent
definition is overridden only for this process to inherit the main model; their
prompts and tools remain unchanged. The override covers every agent, not just
the `*-worker.md` relays, because a launch is `--auth-mode provider-only`: an
agent keeping its own Claude `model:` pin reaches no credentials and 401s on its
first turn, before any tool call. A short launch-only instruction requests
delegation through the existing worker picker. Worker model and account policy
remain owned by `worker-run`. A process-local wrapper removes gateway authentication
from `worker-run` launches so workers use their own vendor profiles.

Prerequisites: Python 3, Claude Code, and the existing llm-legs commands on PATH.
Pinned bridge binaries are installed in `~/.local/lib/claudegpt/bin`: hishamkaram
Claude Code Router 0.4.13 (`ccr`) and CLIProxyAPI 7.2.152 (`cli-proxy-api`). Their
release archives were verified against the publishers' release checksums.
These are third-party adapters; provider compatibility can change.

## Which accounts a gateway chat can open

`share/gateway_auth.py` is the ONE resolver behind readiness, launch and
"Switch chat to this" — `bin/claudegpt`, `bin/claude-chat-switch` and
`share/chat_resume.py` all ask it, so no surface can advertise a target another
refuses. Its roster is every OpenAI account `codexb` knows
(`~/.codex-profiles/<name>`, `CODEXB_PROFILES_DIR` overrides it, `main` dropped by
the same removal marker `share/codex-accounts.sh` writes) plus any account that
still has only a gateway login of its own. That is what closed the systemic
mismatch: an account working as a Codex worker was refused by the menu item
because it had no directory in the gateway store.

A Codex profile needs **no second browser login**. The launch projects that
profile's ACCESS token — and nothing else — into a per-run directory the bridge
reads instead of the canonical store; the file is written atomically, `0600`,
inside the launch's own temporary directory and dies with the chat. It
deliberately carries no `refresh_token` and no `id_token`, which is what keeps the
Codex CLI the single owner of the rotating secret: with an empty refresh token the
bridge's refresh path returns the auth untouched (CLIProxyAPI 7.2.152,
`internal/runtime/executor/codex_executor_auth.go:29-31`, `if refreshToken == ""
{ return auth, nil }`), so no gateway copy can ever invalidate a working worker.
The launcher checks the canonical token before launch and periodically during a chat.
Near expiry, it asks the official Codex app-server `account/read` method with
`refreshToken: true` to renew the canonical login. A per-profile lock serializes
these gateway requests; Codex performs its own guarded reload and refresh. The
bridge receives only the updated access token, never the rotating secret. Other
Codex commands can also update the canonical login, and the projection follows it.
Renewal failures are reported without invoking browser authorization.

When both stores contain the name, their `account_id` values must match. A mismatch
or malformed canonical login is an error, not permission to choose another identity.
Gateway-only accounts keep their existing login. Each running projection pins its
initial identity, so replacing a profile cannot silently switch an active chat to
another account. Readiness and dry-run resolution perform no refreshes or writes.

Gateway logins live under `~/.local/share/claudegpt/accounts/<name>/auth` with
owner-only permissions. Each launch creates temporary routing settings, binds
the bridge to loopback, and stops it when Claude exits. No LaunchAgent is installed.
Both aliases use an 872,000-token window in router metadata and the launch-only
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` / `CLAUDE_CODE_AUTO_COMPACT_WINDOW` variables.
These variables are removed before `worker-run` starts its own vendor sessions.
No global Claude settings are changed. Relaunch to apply the window to an existing
conversation; statusline changes apply on its next render.

`sol` and `astra` are family words: each launch routes them to the newest slug of that family
`codexb models --family` names (shared-invariants row `cv`), so a new Codex version needs no edit.

Capacity evidence (2026-09-07): `sol` then routed to `gpt-5.6-sol`, `astra` to
`gpt-6-astra`. The locally fetched Codex model catalog reports `context_window`
272000 and `max_context_window` 872000 for both. The [public API catalog](https://developers.openai.com/api/docs/models/compare)
reports 1,050,000 for both, but that is not this subscription transport’s catalog.
The bridge’s bundled model catalog also differs by plan, so it is not a reliable
reason to paint 1M. The launcher uses the observed subscription maximum; no paid
long-context request was made to validate it end to end.

Claude Code 2.1.263 resolves unknown gateway aliases through
`CLAUDE_CODE_MAX_CONTEXT_TOKENS`; router discovery metadata alone does not set
that fallback. Its auto-compact window is clamped to the resolved model window.
The default trigger subtracts up to 20,000 output tokens and 13,000 summary tokens
(839,000 at this window with default output settings); an explicit lower
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` can trigger earlier. Neither compaction nor its
safety buffers are disabled.

## Thresholds

Three numbers govern a gateway chat, and **872000 is the only literal** — the launcher's
`CONTEXT_WINDOW` (`bin/claudegpt`), which becomes the router's `--context-window` and the
chat's `CLAUDE_CODE_MAX_CONTEXT_TOKENS` / `CLAUDE_CODE_AUTO_COMPACT_WINDOW`
(`docs/shared-invariants.md` row `ce`). The other two are derived from it and are spelled
nowhere:

- **Claude Code's autocompact trigger, 839,000** — the window minus the 20,000-token output
  reserve and 13,000 summary tokens, at default output settings.
- **The context nudge's ceiling, 839,000** — `../claude-setup/hooks/context-nudge.sh` reads
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` out of the environment and subtracts its own `RESERVE`
  of 33,000, which is those same two reserves added up. So the nudge speaks at the cut
  Claude Code actually compacts at, by construction rather than by coincidence; without the
  variable it falls back to its percentage-of-window rule.
- **The statusline's `ctx` cell, 872,000** — a percentage of the window the harness payload
  carries, so it holds no constant of its own and follows a relaunch on a different window.

Raising the window therefore moves all three, and only `CONTEXT_WINDOW` is edited.

CLIProxyAPI 7.2.152 translates Codex Responses usage into Anthropic fields:
`input_tokens` excludes `input_tokens_details.cached_tokens`, cache reads are
`cache_read_input_tokens`, and output is `output_tokens`. CCR passes these through
while rewriting the model ID to the selected alias. Cache writes arrive as a flat
`usage.cache_creation_input_tokens` integer and only when non-zero; the bridge
never emits the `cache_creation` OBJECT whose `ephemeral_5m_input_tokens` /
`ephemeral_1h_input_tokens` bucket names are the API's own TTL declaration, which
is what the shared Claude ctx renderer reads. With no bucket there is no declared
TTL, so ctx uses the unknown form (`ctx <pct> ? <n>k`) — never a fabricated expiry
arrow and never a separate used/window/cached layout. This transport does not run
Codex CLI; native Codex session token logs and its 95% effective-context policy do
not measure or compact this conversation.

## Cache lifetime: why ctx stays on the unknown form (2026-09-07)

The question was whether a real expiry timer could replace `?`, from a documented
retention window rather than a guess. It cannot, on three independent grounds.

1. **The transport carries no TTL in either direction.** CLIProxyAPI deletes
   `prompt_cache_options` and `prompt_cache_retention` from every Codex-bound
   request before it leaves the bridge — `internal/runtime/executor/codex_executor_execute.go`,
   `codex_executor_stream.go`, `codex_executor_tokens.go`, `codex_websockets_execute.go`
   and `internal/translator/codex/openai/responses/codex_openai-responses_request.go`,
   each with its own regression test. The only cache field it injects is a
   `prompt_cache_key` derived from the Claude Code session id, which OpenAI documents
   as routing influence, not a retention control. Coming back, the usage translation
   (`internal/translator/codex/claude/codex_claude_response.go`) reads
   `input_tokens_details.cached_tokens` and `cache_creation_tokens` and writes them
   as flat Anthropic integers; no TTL name survives the hop.
2. **OpenAI publishes no expiry field.** [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)
   documents `prompt_cache_key`, `prompt_cache_retention` (`in_memory` / `24h`, deprecated
   for GPT-5.6 and later), `prompt_cache_options.ttl` (`"30m"`) and
   `usage.input_tokens_details.cached_tokens` — and no response field, header or
   timestamp saying when a given entry expires. Retention is described as eligibility
   ("remains eligible for reuse for 30 minutes after its most recent write or reuse",
   earlier models "typically ... around 5 to 10 minutes"), not as a guarantee a
   countdown could render.
3. **The published window does not describe this transport.** The `sol` and
   `astra` slugs here are subscription aliases reached through the Codex backend, not
   the public API catalog — the same catalog that reports a 1,050,000-token context
   window for models this transport serves at 872,000 (see Capacity evidence above).
   Codex CLI has the identical shape and does not surface a cache TTL either: its
   binary carries `prompt_cache_options`/`prompt_cache_retention` only inside bundled
   API-migration guidance text, and what it shows a user per turn is cached input
   tokens, never a lifetime.

A 30-minute countdown drawn from a doc page would also contradict the statusline's own
rule, which already refuses to let locally MEASURED bounds authorize a warm arrow
(`docs/statusline-contract.md`, "Server TTL evidence and learned bounds"); a vendor
paragraph is weaker evidence than that, not stronger. So the unknown form stays, and it
is the end state — not a placeholder. The one thing that would change the verdict is the
bridge starting to emit a real `cache_creation.ephemeral_<n><m|h>_input_tokens` bucket,
which the existing renderer would pick up with no code change, since it parses the TTL
generically out of the field name.

The bare gateway account label selects `vendors.codex.accounts[]` in llm-legs for
5h/weekly statusline usage. Names must identify the same OpenAI account in both
stores; an unknown name shows `?`. No Claude quota cache is read or rewritten for
gateway usage.
Claude's estimated monetary cost for these aliases is not subscription usage.

Those two cells have no header ride-along to keep them fresh, so while a gateway chat
is open the statusline refreshes that account itself, off the render path: at most one
`llm-limits.sh --refresh-account codex/<account>` every 10 minutes per account (30 after
one that failed), which is the existing zero-spend `account/rateLimits/read` verb against
`~/.codex-profiles/<account>` and writes the store under the usual lock. It is neither a
new command nor a new store, and closing the chat stops it. Full contract:
`docs/statusline-contract.md`, "Codex quota kick".

## What already knows a gateway chat is not a Claude chat

A gateway chat runs on the shared `~/.claude` with no `CLAUDE_LIMITS_ACCOUNT` and no claudeb state,
so every surface that used to name the session's account from those facts named a stranger. They
ask `share/chat-account.sh` instead — one resolver, `<vendor> <account>` for the current process,
`CLAUDEGPT_ACCOUNT` first (`docs/routing-contract.md`, "Whose account is this chat?"). Already
covered by it: `bin/statusline.sh` (its own `CLAUDEGPT_ACCOUNT` branch and the Codex quota kick),
`bin/worker-pick` (the `*` own-row marker), `bin/claude-resume-timer` (times the resume off the codex five-hour window)
and `bin/workflow-burn-gate.sh` (prices a fan-out against the codex account).
`bin/chats`, `bin/chat-find`, `bin/claude-chat-switch` and the chat-link hooks go through
`share/chat_resume.py` for reopening, which is the same rule for a different question.

Doctrine follows the same line: `anthropic.ccr.sol` / `anthropic.ccr.astra` is a session model the
orchestrator rules bind exactly as they bind Fable — implementation through `worker-run` relay
workers, native agents only for read-only helpers, read-only fan-out rewritten onto
`light-research` — enforced by `orchestrator_model` in `bin/worker-limit-gate.sh`
(`docs/shared-invariants.md` row `bt`).

## Reopening a gateway chat

A transcript records the model (`anthropic.ccr.sol` / `anthropic.ccr.astra`) and never the
account, and a gateway account lives in this launcher's store rather than under
`~/.claude-profiles` — so `claudeb profile <account> --resume <uuid>`, which every reopen
path used to build, opens the same conversation on a Claude account and a Claude model.
Two things fix that, and neither is a second mechanism beside the existing ones.

**The stamp.** Every `claudegpt p` launch writes one line —
`v1 <account> <sol|astra>` — to `<claudegpt-home>/sessions/<conversation-id>`, owner-only,
before Claude Code starts. Claude Code names a fresh conversation itself, so the launcher
names it instead and passes `--session-id`; a launch handed an id (`--resume <uuid>`, an
explicit `--session-id`) keeps it. A launch that picks its conversation at runtime —
`--continue`, the bare `--resume` picker, `--fork-session` — cannot be known in advance and
is stamped after Claude Code exits, from the newest transcript of the launch directory's own
project. Nothing removes a stamp when the chat closes: it is the only record of which account
a transcript belongs to, and the chat is reopened months later. Each launch sweeps the stamps
whose transcript is gone, which is the whole of the cleanup. A chat launched before stamping
existed has none, and its reopen line carries the literal `<gateway-account>` for him to fill
in rather than a guess.

**The resolver.** `share/chat_resume.py` is the one place that answers "how do I reopen chat
`<uuid>`": `resume_argv` reopens a chat as it was launched (the chat's own launcher outranks
any ambient account) and `switch_argv` reopens it under an account he picked. The menu and resolver CLI select
the target kind explicitly: `--gateway` means a gateway login, its absence a Claude
profile; library callers without an explicit kind retain store-based selection, with
a shared name such as `com` preferring the Claude profile. `bin/chats`,
`bin/chat-find`, `bin/claude-chat-switch` and the `chat-switch-link` / `chat-link-format`
hooks all call it instead of spelling a launcher; the Claude-model answer is byte for byte
what those surfaces printed before. `claude-chat-switch --gateway <account>` is how the
Hammerspoon menu's "Switch chat to this" on a **Codex** account row reaches this — the same
item the Claude rows carry, same exit-and-relaunch handover, no hot switching.

“Switch chat to this” also works from a bare Terminal shell: `claude-chat-switch`
classifies one tty process snapshot and asks `chat_resume.py launch` for a fresh
command in the shell’s cwd (falling back to HOME when cwd cannot be read). Existing
chats use `switch` to keep the transcript; source kind comes from the wrapper or
process account stamp, target kind from the clicked row. Hammerspoon only types the
resolved launcher, with no fallback of its own: bare shells skip idle/exit/polling
and the cd prefix, while chats wait for the outer gateway wrapper’s cleanup before
relaunching. Failures name the detected mode. `--front --dry-run` prints mode, pids,
cwd and command without arming Hammerspoon or typing. Cross-kind verification on
2026-09-11 used real transcripts with `--resume`, `--fork-session`, print mode and
session persistence disabled: gateway → Claude `com` returned `ok` (exit 0); Claude
→ gateway `work4` / `sol` returned `ok` (exit 0) on confirmation with a minimal
system prompt; its first successful run answered the old transcript context instead.
Three short runs total. Both directions retain resume; neither needs a fresh-launch
fallback.

`bin/chats` lists gateway accounts in its ←→ account bar as `gpt:<name>`, with the share read
from `vendors.codex` (the same store the statusline reads for a gateway chat), and its model
column shows `Sol` / `Astra` like every other surface (`docs/shared-invariants.md` row `cc`).

For isolated tests, `CLAUDEGPT_HOME` and `CLAUDEGPT_BIN` replace the launcher stores;
`CLAUDE_CONFIG_DIR` selects a fixture Claude configuration. They do not change the
existing account managers. Run `python3 tests/test_claudegpt.py` for offline checks.
