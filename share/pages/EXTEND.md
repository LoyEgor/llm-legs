# A pages module lacks something

Read this only when `page help <module>` has no key for what your page needs. Everything lives in
`/Volumes/Work/Projects/llm-legs/share/pages/`.

## An option before a module
- **Opt-in spec key on the closest module:** absent means today's behaviour, so every existing page
  renders unchanged, and a page that does not ask for a feature pays nothing for it.
- **A new module** only for a new interaction shape, never for one page's look.
- **Never** a copy of a module, a fork of the kit for one page, or hand-made HTML beside it.
- **Data stays in the spec:** no paths, item names or one project's thresholds in the kit.

## Where things live
- `kit/<module>.js` exports `render(spec, again)`. It uses only the API listed at the top of
  `kit/shell.js`. Saving (outbox, retries, flush), polling, keys, notes, skip, sitting cap and lazy
  media are the shell's: a module never does its own fetch or localStorage. A need the shell lacks
  is a shell export, so the next module gets it too.
- `kit/<module>.md` is what `page help <module>` prints and the only doc a page-making chat reads.
  - Its first line is `# <module>: <one line>` (the `page help` list).
  - Then the spec keys with their defaults, the fields written and one example.
  - Keep it under ~2.5 KB; a new key gets one bullet.
- `CONTRACT.md` is the server↔kit interface. A key the server must understand (a new media path,
  validation, a hidden key) goes there and into `store.py`. `schema` bumps only on an incompatible
  change.

## Live at once
The server reads the kit from the main checkout, so an edit reaches every open page on its next
reload. Finish the change, add one check for the new key to `tests/pages-kit/run.mjs` (the
end-to-end check is `e2e.mjs`), run `tests/test_pages_kit.sh` (`tests/test_pages.sh` too if
`bin/page` or `store.py` changed), then commit. The commit message names the key, its default and
the page that needed it. Tests use a temp `PAGES_DIR`, never `~/Pages`.

## Planned, not built
Take one of these names before inventing another (plan: `docs/handoffs/2026-10-28-pages-plan.md`
§4):
- audio and video excerpts, A/B from the same position, a sample-exact loop;
- video frame-step and timeline marks;
- a question queue and a daily cap;
- region masks, and the transcription diff review.
