# Vendor release integration

A vendor shipped something (a model, a CLI version, a tool parameter, a doc) and
`bin/vendor-fingerprint` saw it change. Turn that event into a fully integrated, tested, reported
change nobody has to ask about. Egor opened this chat with the Updater doctor's Fix button or «сделай
апдейт» (night: §6) and may be away: work autonomously, go deep; his word only where a gate says so.

The standing goal: every surface runs each vendor's newest model with no hardcoded id (a pin survives
only with a stated reason), and every new capability is supported, per account, over a changing set.

## 0. Entry

- `bin/vendor-fingerprint show <id>` — the event: vendor, versions, `changed`, `substantive`, and
  the paths of its `.diff` and of the current fingerprint (`snapshot <vendor>` re-takes one).
- Read your vendor's lines in `docs/vendor-release-open.md`: prove what this release lets you
  prove, and never re-check what a closed event already settled.
- No id given: `bin/vendor-fingerprint events` lists the open ones; handle each vendor's together.
- Several ids given: the chat carries every event that waited when Egor asked, each already folding
  its vendor's changes since it opened; do the procedure per event, one vendor after another.
- A manual request (`request [--here] <vendor>` with no event waiting) diffs the whole current
  fingerprint: the full checklist, every line decided (a `+*` row per facet is fine).
- Model: this runs on a strong model (Opus 5.5+ or Fable). Any other session model stops here and
  says so. Research legs run on a strong model with web access, never on Light.

## 1. Ground rules

- Purpose before change: before you change a surface (a wrapper, a pin, a resolver, a menu row, a
  test), learn why it is built the way it is — `git log --follow` / `git log -S` on its lines, the
  commit that made it, its handoff or design doc, its `docs/shared-invariants.md` row. Say its goal
  in one sentence and check the release still serves it, not only that the tests stay green; a pin
  or fallback kept for a reason that no longer holds is removed, one whose reason holds stays.
- Work in a worktree per repository you change (llm-legs, review-bench, claude-setup), on branch
  `vendor-release/<vendor>-<version>`, per `~/.claude/docs/worktrees.md`. Never review, commit or
  push: Egor's end-of-day pass does all three for everything at once (night: §6).
- Every vendor is open for workers and reviews (chat pin `open=all`, as «воркер на все»): a live proof
  on a vendor Egor switched off in the menu runs anyway; pauses, walls and the Light switch apply.
- Tests use fixtures only; never point one at `~/.claude-profiles/.claudeb`, a real `~/.codex`,
  `~/.grok` or `~/.gemini`, and never mutate the live Hammerspoon singleton (`menuItems()` only).
- Never generate an image or video: every generation needs Egor's «сгенерируй». Collect what only a
  generation can prove (§3 step 10) into one ask in the report.
- Before building a capability for this vendor, study how the other vendors expose the same or an
  analogous one — the Hammerspoon menu, `<vendor>b` verbs, worker-run, chat pins, statusline, review
  pins — and put it in the same places with the same names and look (codex's per-account "Fast Mode
  (workers)" toggle means grok's fast model gets that toggle too, not a chat tag). Share the mechanism
  where it fits; where vendors really differ, an own implementation is fine but the visible surface
  matches. Egor never has to ask for this parity.
- A worker's "done" is a claim: diff the files it says it changed, and diff every test/spec change
  against HEAD — a weakened assertion is a regression, not a pass.
- Blocked on the owner (ZDR/privacy toggles, generation budget, paid API): record it as
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
4. Vendor web docs and release notes via web search: good for what exists and GA/deprecation dates,
   misleading about what the subscription CLI carries. A cited id counts only if the page has it.
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
   roles, relay agent md files (every flag the leg accepts), review-bench catalog, cells, raters and
   tests, Light rows, image legs and `image-fanout`, the Hammerspoon menu (read-only), statusline short
   names (`docs/statusline-contract.md`), `docs/image-vendors*.md`, `docs/DIAGNOSTICS.md`. And the
   review-bench transport (`share/rbench/launch.py` `run_<side>`, its stream-evidence parser): a
   changed event shape, tool name or parameter, output truncation or sandbox flag silently breaks what
   a cell reads or the report counts; where the release touches one, run one real cell and compare
   its stream with its `rater_runs` row.
9. Per account: resolve and check each account the pool holds today (`codexb models --account`,
   per-account catalogs, entitlements); an entitlement refusal is typed apart from a usage limit.
10. Live proof. LLM models: one real `worker-run` per new model (cheapest fitting account from
    `worker-pick`), its `SERVED:` line must name it. Images/video: list each generation as
    "generation → the claim only it can settle", parameters riding in the same call, nothing a free
    source settles. The list is the report's one ask; typically empty for a CLI bump, 1–3 otherwise.
11. Deprecations and silent fallbacks get a dated tripwire (a test that fails on the date), and a
    temporary shim is registered in `EXPERIMENTS.json`.
12. Manifests: bump `cli.version`/`verified` only after the checks above pass; every value agrees
    with its `field_sources` note.
13. Tests: every new behaviour asserted; each new assertion shown red on the old code (mutation);
    `bash tests/run-all` green in every worktree touched.
14. Pour it into main, uncommitted, so it works at once: per worktree `git add -N` the new files,
    `git -C <worktree> diff HEAD >patch`, `git -C <main checkout> apply patch` — on top of others'
    uncommitted work, never reverting, stashing or overwriting it; a hunk that fails (`--reject`) is
    merged by hand, keeping both sides. Rerun the suites your diff touches in the main checkout, then
    remove the worktree and its branch.
    Last, `bin/vendor-fingerprint check --here <vendor>`: your change can move what a facet reads (a
    new cache field), and the event it records is yours to decide and close, never a new chat's.

## 4. Close — the completeness gate

One row per changed diff line: `facet<TAB>line<TAB>integrated|not-applicable|blocked<TAB>purpose<TAB>evidence`.
`purpose` states the §1 goal of the surface the line lands on: `repo@hash` or a file(:line), judged
by `bin/doctor-fix`'s rule. Evidence: a file:line, test name, artifact path or source line. A `line`
ending in `*` covers every line it prefixes (`ids<TAB>+gpt-7*<TAB>...`). Then `bin/vendor-fingerprint
close <id> --decisions <file> <one-line note>` refuses while a line is undecided or a purpose resolves
nowhere. First update `docs/vendor-release-open.md` (a line per `blocked` or unproven claim, the ones
you proved or made moot deleted), and fail yourself if a capability claim has neither a schema/doc
line nor an artifact, or an "observed" value came from our own config.

## 5. Report — to Egor, in Russian, short

Per feature: integrated (where, which test), not applicable (why), blocked (what his word unlocks).
What became automatic (hardcodes removed), every pin moved with its proof, what was poured into main
(files) for the end-of-day pass, the one ask for generations (step 10's list). No session ids, diffs
or transcripts.

## 6. Night (`docs/night-run.md`)

`bin/vendor-fingerprint request --night <night-id>`: one headless worker per vendor with a real waiting
release (never a manual one), a brief beside the event, a worktree `.claude/worktrees/night-<night>-<vendor>`
on branch `night/<night>/<vendor>`. The day procedure holds except:
- Step 14: commit on your branch in every worktree you changed (a second repository gets its own
  worktree on the same branch name, from its `refs/night/<night>/base`); no pour, push, merge or removal: the orchestrator reviews,
  rebases and pushes. `check --here <vendor>` runs in your worktree, waiting for the shared lock.
- Steps 3 and 4 start in parallel. A generation (step 10), or any step needing Egor's word, is decided
  `blocked` with evidence `blocked-on-egor: <what his word unlocks>`; never wait for him.
- The report is the brief's, in English, to the orchestrator; §5 is the day chat's.
