# Vendor release integration

A vendor shipped something (a model, a CLI version, a tool parameter, a doc) and
`bin/vendor-fingerprint` saw it change. Turn that event into a fully integrated, tested, reported
change nobody has to ask about. You are a headless worker the fix orchestrator dispatched
(`docs/fix-orchestrator.md`) after the Updater doctor's Fix button or «сделай апдейт» (night: §6): work
autonomously, go deep, never wait for Egor.

The standing goal: every surface runs each vendor's newest model with no hardcoded id (a pin survives
only with a stated reason), and every new capability is supported, per account, over a changing set.

## 0. Entry

- `bin/vendor-fingerprint show <id>` — the event: vendor, versions, `changed`, `substantive`, and
  the paths of its `.diff` and of the current fingerprint (`snapshot <vendor>` re-takes one).
- Read your vendor's lines in `docs/vendor-release-open.md`: prove what this release lets you
  prove, and never re-check what a closed event already settled.
- Several ids: the procedure per event, each folding its vendor's changes since it opened.
- A manual request (`request [--here] <vendor>` with no event waiting) diffs the whole current
  fingerprint: the full checklist, every line decided (a `+*` row per facet is fine).
- A vendor-watch event (facet `watch`, `share/briefs/vendor-watch.md`): a web feature per line with its
  proposal; integrate it in its route, or decide it not-applicable/blocked.
- Model: a strong model (Opus 5.5+ or Fable); Sonnet only under the brief's `MODEL: sonnet`, which ends
  `ESCALATE: <reason>` on more than it names. Any other stops here and says so. Research legs: a strong
  model with web access, never Light.

## 1. Ground rules

- Purpose before change: before you change a surface (a wrapper, a pin, a resolver, a menu row, a
  test), learn why it is built the way it is — `git log --follow` / `git log -S` on its lines, the
  commit that made it, its handoff or design doc, its `docs/shared-invariants.md` row. Say its goal
  in one sentence and check the release still serves it, not only that the tests stay green; a pin
  or fallback kept for a reason that no longer holds is removed, one whose reason holds stays.
- A model change is never Egor's decision; the run proves and records the defaults: a new
  version replaces its class's older; a new class enters where a consumer derives from the union
  (Frontier: each vendor's strongest), workers keep it `request`; a family some accounts serve
  (`divergence`, `plans`) stays on those; a dropped one takes every pin, option and menu row naming
  it along, and a choice left with one option goes too — cleanup, never `blocked`.
- Work only in the brief's worktree and its `ADD-DIR:` worktrees (review-bench, claude-setup), on its
  branch; a change in a repository without one is a handoff. Commit there; never push, merge or review:
  the orchestrator lands it.
- Workers and reviews use exactly the vendors Egor's worker switches allow; the chat gets no pin. A
  live proof that needs a vendor he switched off is not run: it goes into the report's ask.
- Tests use fixtures only; never point one at `~/.claude-profiles/.claudeb`, a real `~/.codex`,
  `~/.grok` or `~/.gemini`, and never mutate the live Hammerspoon singleton (`menuItems()` only).
- Never generate an image or video: every generation needs Egor's «сгенерируй». What only a generation
  can prove (§3 step 10) is decided `blocked` with evidence `blocked-on-egor: <what his word unlocks>`.
- Before building a capability for this vendor, study how the other vendors expose the same or an
  analogous one — the Hammerspoon menu, `<vendor>b` verbs, worker-run, chat pins, statusline, review
  pins — and put it in the same places with the same names and look. Share the mechanism where it
  fits; where vendors differ, the visible surface still matches.
- A worker's "done" is a claim: diff the files it says it changed, and diff every test/spec change
  against HEAD — a weakened assertion is a regression, not a pass.
- Blocked on the owner (ZDR/privacy toggles, generation budget, paid API): `blocked` with what his
  word unlocks; go on with the rest.

## 2. Sources of truth, most reliable first

1. Live vendor output: served model from `modelUsage`, codex rollout `turn_context`/`model_reroute`,
   grok/gemini session files, C2PA `softwareAgent` of a generated file. A value we wrote into a
   config ourselves is never evidence of what served.
2. The native binary's strings (`vendor-fingerprint snapshot` resolves it — never the npm launcher;
   an empty dump is a broken probe, not "no such model"): tool schemas, enums, limits, config keys.
3. `--help`, bundled docs (`~/.grok/docs`, codex `skills/.system`), `agy changelog`, catalogs
   (`codexb models [--account]`, `grokb models`, `geminib families`, `agy models`). Catalogs are
   filtered by client version (`minimal_client_version`) and may differ per account.
4. Vendor web docs and release notes: good for what exists and GA/deprecation dates, misleading about
   what the subscription CLI carries. A cited id counts only if the page has it.
5. Model memory: not a source.

## 3. Checklist — every item gets a verdict in the report

1. Read the diff line by line; every changed line will need a decision (§4).
2. CLI current and models not hidden: `bin/vendor-cli-update status` (divergence lines too), and
   no catalog model needs a newer client than the installed one.
3. Research what changed: release notes/changelog of this version and of the models it names —
   new models, efforts, speed tiers, tools, tool parameters, limits, deprecations with dates.
4. Blind cross-check: the orchestrator chat starts a research run on ANOTHER vendor alongside you (a
   headless worker cannot start a run; every other vendor off for workers: another Claude account) that writes its own feature list for this release from the
   same sources without seeing yours; the orchestrator resumes you with every difference, and you
   reconcile each with a source line.
5. Separate what the CLI carries from API-only features (image manifests keep them in `api_only`).
6. Tool schemas (image, video, LLM tools): diff strings/help/docs against
   `share/image-caps/<vendor>.json` and the wrapper's flags. Every field is wired, `unsupported`, or
   `api_only`; the vendor's default is sent unless a reason is stated; no wrapper suppresses a
   native feature; the output parser handles every result tag the tool can emit (negative test).
7. Models — resolve, never type. First learn how resolution works (`docs/DIAGNOSTICS.md` system map,
   `docs/routing-contract.md`, invariant rows `cr`, `cu`): family words and aliases resolve to the
   newest (`codexb models --family`, `geminib families`, `grokb models`, Claude aliases). A version
   number you would edit is a hardcode to remove: make that surface read the live list. Where the
   vendor needs an explicit id to serve the newest (grok Imagine falls back to an old model without
   one), send the RESOLVED id. A literal survives only where nothing lists the ids: an `image-caps`
   pin a live run proved, or the line under `# pin: <reason>`; the `ids` facet reports its successor.
   `*_builtin()` fallback lists are frozen. `tests/test_consistency.sh` (row `cr`) fails on any other
   versioned id in the three repositories; a new id family goes into the fingerprint's `id_prefixes`.
8. Surfaces: `share/worker-model.sh` table, `share/worker-policy.md`, `bin/worker-run`, `worker-pick`
   roles, worker-run usage (every flag the leg accepts), review-bench catalog, cells, raters and
   tests, Light rows, image legs and `image-fanout`, the Hammerspoon menu (read-only), statusline short
   names (`docs/statusline-contract.md`), `docs/image-vendors*.md`, `docs/DIAGNOSTICS.md`. And the
   review-bench transport (`share/rbench/launch.py` `run_<side>`, its stream-evidence parser): a
   changed event shape, tool name or parameter, output truncation or sandbox flag silently breaks what
   a cell reads or the report counts; where the release touches one, run one real cell and compare
   its stream with its `rater_runs` row. On every surface, remove an older workaround around what you
   touch that the vendor now does natively or whose reason is gone.
9. Per account: resolve and check each account the pool holds today (`codexb models --account`,
   per-account catalogs, entitlements); an entitlement refusal is typed apart from a usage limit.
10. Live proof. LLM models: your RETURN asks the orchestrator for one `worker-run` per new model
    (you cannot start one); its `SERVED:` line must name it. Images/video: list each generation as
    "generation → the claim only it settles", parameters riding in one call, nothing a free
    source settles. The list is the report's one ask.
11. Deprecations and silent fallbacks get a dated tripwire (a test that fails on the date), and a
    temporary shim is registered in `EXPERIMENTS.json`.
12. Manifests: bump `cli.version`/`verified` only after the checks above pass; every value agrees
    with its `field_sources` note.
13. `tests/run-all --changed` green in every worktree touched.
14. Commit on your branch in every worktree you changed. Last, for a CLI vendor, `bin/vendor-fingerprint
    check --here <vendor>` in your worktree: your change can move what a facet reads, and the event it
    records is yours to decide and close, never a new run's.

## 4. Close — the completeness gate

One row per changed diff line: `facet<TAB>line<TAB>integrated|not-applicable|blocked<TAB>purpose<TAB>evidence`.
`purpose` states the §1 goal of the surface the line lands on: `repo@hash` or a file(:line), judged
by `bin/doctor-fix`'s rule. Evidence: a file:line, test name, artifact path or source line. A `line`
ending in `*` covers every line it prefixes (`ids<TAB>+gpt-7*<TAB>...`). Then `bin/vendor-fingerprint
close <id> --decisions <file> <one-line note>` refuses while a line is undecided or a purpose resolves
nowhere. First update `docs/vendor-release-open.md` (a line per `blocked` or unproven claim, the ones
you proved or made moot deleted), and fail yourself if a capability claim has neither a schema/doc
line nor an artifact, or an "observed" value came from our own config.

## 5. Report — to the orchestrator, in English, short

Per feature: integrated (where, which test), not applicable (why), blocked (what his word unlocks).
What became automatic (hardcodes removed), every pin moved with its proof, the commits as `repo@hash`,
every `blocked-on-egor` line. No session ids, diffs or transcripts.

## 6. Night (`docs/night-run.md`)

`bin/vendor-fingerprint request --night <night-id>` takes per vendor its real waiting release and vendor-watch events, on
branch `night/<night>/<vendor>` from `refs/night/<night>/base` in every repository. Steps 3 and 4 start
in parallel.
