# Handoff 2026-10-02: one account roster, no remnants

## Why

The owner removed codex `work4` from the menubar Pool menu around 2026-09-30. On 2026-10-02 it still
surfaced as a "live" account in the roster unification report (`share/gateway_auth.py`, its
gateway-only accounts). His rule: an account comes from ONE place, the menubar roster. An account removed
there is gone everywhere, and nothing may hold or resurrect it.

The 2026-10-01 roster pass built that one place: `share/account-roster.sh` and `share/account_roster.py`,
shared-invariants row `dg`, with every media engine reading it. This pass finishes the job and
removes the leftovers.

## Known remnants (starting points, not the whole list)

- **codex `work4`:**
  - `~/.codex-profiles/.codexb/fast-mode/work4`. `desktop-pro` there is not a profile either.
  - `~/.codex-profiles-removed/work4-20260930`, the removal archive.
  - `share/gateway_auth.py`, which treats it as a gateway-only live account. Find where that list comes from.
  - `share/doctor-ledger.json` rows.
- **gemini `egbor`:** removed 2026-10-02 with `geminib remove egbor`, on the owner's word. Its
  `~/.gemini-web/profiles/egbor` and any meta, walls, notices and lock entries under `~/.gemini-web` are still there.
- **gemini `mish`:** it has a `~/.gemini-web/profiles/mish` profile and is walled 365 d, but it is absent
  from `geminib list`. Establish whether it was ever removed. With no removal evidence, report it and do not delete it.
- **`codexb account_names`:** it still keeps its own enumeration, because a live chat owned `bin/codexb` on 2026-10-01.
  Re-check `git status`/`git diff bin/codexb`. Edit on top with targeted edits, never over the other chat's hunks.
- **grok:** the roster counts `main` only once `auth.json` exists, while `grokb list` always shows `main`.
  The same state must give the same answer.
- **review-bench `rbench.opencode_profiles`** (`/Volumes/Work/Projects/review-bench`) keeps its own list.

Test fixtures and historical docs (`docs/handoffs/*`, `menu-before.txt`) that merely name `work4` are
not remnants. Leave them alone.

## Required end state

1. **Inventory.** List every place, in llm-legs, claude-setup (`/Volumes/Work/Projects/claude-setup`),
   review-bench and `~/.hammerspoon`, that ENUMERATES accounts or STORES per-account data. That covers
   profile dirs, caches, ledgers, walls, notices, locks, claims, fast-mode, gateway lists, browser profiles
   and doctor ledgers, for every vendor: claudeb, codex, gemini, grok, opencode/gateway, gemini-web and chatgpt-web.
   For each place, say whether it reads the roster.
2. **One source.** Every enumerator reads the roster, intersected with its own readiness. No directory
   listing, cache or ledger serves as a roster. A gateway-only account (one with no menubar row) is a
   divergence: either it gets a roster entry through the menu's own source or it stops existing.
   Decide by the owner's doctrine: the menubar is the single source of truth, and a store with fewer
   rows than the menu is a P1.
3. **Remove purges.** The menu's Remove (`<vendor>b remove <name>`) purges every per-account store of
   that vendor in one shared helper per vendor:
   - gemini: the gemini-web profile, meta, walls, notices and locks;
   - codex: the chatgpt-web profile, `accounts/<name>.json` and walls, and the fast-mode file;
   - every vendor: claims and caches.

   The same behavior holds across vendors (one shared path). The `~/.codex-profiles-removed/*` archive:
   report what writes it, whether anything reads it, and how other vendors' remove differs. Do NOT delete
   archives. The owner decides on them after your report.
4. **Sweep the existing remnants.** Run the product's own purge on accounts that have removal evidence:
   a removal marker, a `-removed` archive, or a remove journal line. Before deleting anything, print the
   exact list of what goes. An account without evidence is reported, never deleted.
5. **Mechanical guard (automation over prose).**
   - Extend `tests/test_consistency.sh` row `dg` so that any new enumerator outside the roster owners fails it.
   - Add a fixture test that `remove` empties every store listed in the inventory.
   - Add an `llm-doctor` check that files a problem (one cause, its own group row) for any per-account file
     or directory whose account is off the roster. That way a future remnant shows up in the menu instead of
     waiting for the owner to spot it. Mutation-check every new assert.

## Constraints

- No commits or pushes; the night sweep lands it.
- Never point a test or ad-hoc check at the real `~/.claude-profiles/.claudeb` store; use `CLAUDEB_DIR`
  fixtures only. The live store changes only through the product's own remove/purge code path.
- Never mutate the live Hammerspoon singleton (`package.loaded["llm-limits"]`); `menuItems()` reads only.
- Never print keys, tokens or cookies. Launch no Chrome, and sign in nowhere.
- Uncommitted hunks you did not write are someone's live work. Use targeted edits on top, never
  revert, stash or clean them, and re-read a file right before editing it.
- Code comments stay near zero: only a "why" at a trap.
- Grep the live stores for names only (`grep -l`, `find -name`), never their contents.

## Verification

- `bash tests/run-all` passes.
- Mutation evidence for each new assert.
- A before/after `find`/`grep -l` for `work4` and `egbor` across the stores in the inventory, names only.

## Report (at most 250 words, outcome first)

1. The inventory table (place → reads roster yes/no → fixed).
2. What was deleted.
3. What stays and why (archives, `mish`, live co-tenant files).
4. Any decision left for the owner, as one line on cost and one on loss.
