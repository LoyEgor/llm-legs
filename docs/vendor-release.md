# Vendor release integration

A vendor shipped something — a model, a CLI version, a tool parameter, a doc — and
`bin/vendor-fingerprint` saw it change. This procedure turns that event into a fully integrated,
tested, reported change, with nobody having to ask "did you check X?". Egor may be away: the chat was
opened by a LaunchAgent. Work autonomously; his word is needed only where a gate below says so.

The standing goal it serves: every surface runs each vendor's newest model with no hardcoded id
(a pin survives only with a stated reason), and every new capability is supported, per account,
over an account set that changes.

## 0. Entry

- `bin/vendor-fingerprint show <id>` — the event: vendor, versions, `changed`, `substantive`, and
  the paths of its `.diff` and of the current fingerprint (`snapshot <vendor>` re-takes one).
- No id given: `bin/vendor-fingerprint events` lists the open ones; handle each vendor's together.
- A manual request (`request [--here] <vendor>`) has no diff: do the whole checklist against the
  current CLI.
- Model: this runs on a strong model (Opus 5.5+ or Fable). Any other session model stops here and
  says so. Research legs run on a strong model with web access, never on Light.

## 1. Ground rules

- Work in a worktree per repository you change (llm-legs, review-bench, claude-setup), on branch
  `vendor-release/<vendor>-<version>`, per `~/.claude/docs/worktrees.md`. Never commit or push:
  that is Egor's word. The report names the branches.
- Tests use fixtures only; never point one at `~/.claude-profiles/.claudeb`, a real `~/.codex`,
  `~/.grok` or `~/.gemini`, and never mutate the live Hammerspoon singleton (read-only
  `menuItems()` only).
- Never generate an image or video: every generation needs Egor's «сгенерируй». Collect what only a
  generation can prove (§3 step 10) into one ask in the report.
- A worker's "done" is a claim: diff the files it says it changed, and diff every test/spec change
  against HEAD — a weakened assertion is a regression, not a pass.
- Blocked on the owner (ZDR/privacy toggles, generation budget, paid API, commit word): record it as
  `blocked` with what his word unlocks, and keep going on everything else.

## 2. Sources of truth, most reliable first

1. Live vendor output: served model from `modelUsage`, codex rollout `turn_context`/`model_reroute`,
   grok/gemini session files, C2PA `softwareAgent` of a generated file. A value we wrote into a
   config ourselves is never evidence of what served.
2. The native binary's strings (`vendor-fingerprint snapshot` resolves it — never the npm launcher;
   an empty dump is a broken probe, not "no such model"): tool schemas, enums, limits, config keys.
3. `--help`, bundled docs (`~/.grok/docs`, codex `skills/.system`), `agy changelog`, catalogs
   (`codexb models [--account]`, `grokb models`, `geminib families`, `agy models`). Catalogs are
   filtered by client version (`minimal_client_version`) and may differ per account.
4. Vendor web docs and release notes, fetched with web search: good for what exists and for
   GA/deprecation dates, misleading about what the subscription CLI carries. A cited id counts only
   if it appears in the fetched page.
5. Model memory: not a source.

## 3. Checklist — every item gets a verdict in the report

1. Read the diff line by line; every changed line will need a decision (§4).
2. CLI current and models not hidden: `bin/vendor-cli-update status` (divergence lines too), and
   no catalog model needs a newer client than the installed one.
3. Research what changed: release notes/changelog of this version and of the models it names —
   new models, efforts, speed tiers, tools, tool parameters, limits, deprecations with dates.
4. Blind cross-check: a research run on ANOTHER vendor (`worker-run start <vendor> --role research`,
   web on, per `worker-pick`) writes its own feature list for this release from the same sources
   without seeing yours; reconcile every difference with a source line.
5. Separate what the CLI carries from API-only features (image manifests keep them in `api_only`).
6. Tool schemas (image, video, LLM tools): diff strings/help/docs against
   `share/image-caps/<vendor>.json` and the wrapper's flags. Every field is wired, `unsupported`, or
   `api_only`; the vendor's default is sent unless a reason is stated; no wrapper suppresses a
   native feature; the output parser handles every result tag the tool can emit (negative test).
7. Models: family words and aliases resolve to the newest (`codexb models --family`, `geminib
   families`, `grokb models`, Claude aliases). Grep llm-legs, review-bench and claude-setup for
   literal versioned ids (`gpt-`, `grok-`, `gemini-`, `claude-`, `imagen-`, `veo-`); every survivor
   is a pin with its reason written next to it, or it goes. A new id family the fingerprint's
   `id_prefixes` does not know is added there.
8. Surfaces: `share/worker-model.sh` table and `share/worker-policy.md`, `bin/worker-run`,
   `worker-pick` roles, relay agent md files (every flag the leg accepts), review-bench catalog,
   cells, raters and tests, Light rows, image legs and `image-fanout`, the Hammerspoon menu (read-only
   checks), statusline short names (`docs/statusline-contract.md`), `docs/image-vendors*.md`,
   `docs/DIAGNOSTICS.md`.
9. Per account: resolve and check each account the pool holds today (`codexb models --account`,
   per-account catalogs, entitlements); an entitlement refusal is typed apart from a usage limit.
10. Live proof. LLM models: one real `worker-run` per new model (cheapest fitting account from
    `worker-pick`), its `SERVED:` line must name it. Images/video: list each generation as
    "generation → the claim only it can settle", parameters riding in the same call; nothing a free
    source settles is on the list. The list is the report's one ask; typically empty for a CLI bump,
    one to three when an image model or its features change.
11. Deprecations and silent fallbacks get a dated tripwire (a test that fails on the date), and a
    temporary shim is registered in `EXPERIMENTS.json`.
12. Manifests: bump `cli.version`/`verified` only after the checks above pass; every value agrees
    with its `field_sources` note.
13. Tests: every new behaviour asserted; each new assertion shown red on the old code (mutation);
    `bash tests/run-all` green in every worktree touched.
14. Review the worktree diff at the tier `~/.claude/docs/review-tiers.md` gives it; fix what it
    finds.

## 4. Close — the completeness gate

Write a decisions file, one row per changed diff line:
`facet<TAB>line<TAB>integrated|not-applicable|blocked<TAB>evidence`, where evidence is a file:line,
a test name, an artifact path or a source line, and a `line` ending in `*` covers every line it
prefixes (`ids<TAB>+gpt-7*<TAB>...`). Then
`bin/vendor-fingerprint close <id> --decisions <file> <one-line note>`; it refuses while any changed
line is undecided. Before closing, also fail yourself if any capability claim has neither a
schema/doc line nor an artifact, or any "observed" value came from our own config.

## 5. Report — to Egor, in Russian, short

Per feature: integrated (where, which test), not applicable (why), blocked (what his word
unlocks). The worktree branches to commit. The one ask for generations, if any, as the list from
step 10. No session ids, no diffs, no transcripts.
