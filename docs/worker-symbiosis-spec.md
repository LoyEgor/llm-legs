# Worker/limits symbiosis — spec for worker-pick v2

Goal: move Egor's account-routing judgment out of CLAUDE.md prose into deterministic
llm-legs code, so that (a) session-start context shrinks, (b) routing decisions are
data-driven and identical in every session, (c) policy text is loaded on demand (printed
by worker-pick at delegation time), never preloaded.

After this lands, the "Worker model toggle" section of global CLAUDE.md shrinks to a
stable contract: "before every delegation run worker-pick, obey NEXT/POLICY, brief format
MODEL:/EFFORT:/ACCOUNT:". That compression happens in the claude-setup chat, not here.

## 1. Data layer (llm-limits) — MOSTLY EXISTS, verify and fill gaps

Already present in ~/.llm-limits.json (verified 2026-07-20):
- Per-account `fable` bucket alongside `five_hour`/`weekly` (used_pct, resets_at,
  effective_pct, staleness) — FB% column in the table.
- `rotation.usable/blocked {general, fable}` flags per claude account.
- Codex: `reset_credits` (integer, ↻N in the table's CR column) and `plan_type`.

Gaps to close:
- Reflect Anthropic's 2026-07-20 change (Fable unavailable on Pro plans) in
  `rotation.usable.fable` for Pro accounts (olx) so consumers need no plan knowledge.
- Confirm freshness semantics apply to the `fable` bucket and `reset_credits` like any
  other reading. Tier dollars stay as is (alona/com/notcom $100, olx $20).

## 2. Scoring rules (worker-pick)

All rules operate on effective (staleness-aware) data. Weights/thresholds live as
constants in the script, unit-tested with frozen fixtures — never re-derived in prose.

- R1 fable-burnt → worker-preferred: high Fable-bucket usage makes an account MORE
  attractive for workers (its remaining general quota has little Fable value to Egor).
- R2 fable-fresh + weekly-high → protected: low Fable-bucket usage but high overall
  weekly means the remainder should be reserved for Egor's Fable sessions; strong
  penalty as a worker target.
- R3 fable-incapable → top worker priority: accounts with `fable=false` (olx) sort
  first among worker candidates at comparable effective remaining, tier-weighted as
  today (30% left on $20 ≪ 30% on $100).
- R4 floor — never drain to zero: an account past FLOOR_PCT (default 90%) in the
  relevant bucket is not selectable; if ALL candidates are floored, report that
  explicitly (orchestrator asks Egor) instead of picking the least-bad.
- R5 extra capacity beyond remaining_now, two distinct sources:
  a. Reset proximity (time): remaining = remaining_now + refund discounted by
     time-to-reset (reset within hours → "spent 50%" behaves closer to 150% capacity
     ahead). Applies per bucket; resets_at is already collected.
  b. Codex `reset_credits` (count): each credit ≈ one full 100% quota refill on top of
     the current window (main at 48% spent with ↻1 has ~152% runway, not 52%). Scoring
     and the POLICY/FRESH-TIGHT verdicts must include credits; confirm the exact
     consumption mechanics (auto-applied on exhaustion vs manual) during implementation
     and encode them, don't assume.
- R6 pacing before reset: R5 must not authorize draining an account to the floor
  BEFORE its reset lands — cap the pre-reset draw so the account stays usable
  (e.g. never plan below FLOOR_PCT until the reset actually occurs).
- R7 session-account exclusion stays as today.

Same shape applies to codex (codexb accounts): tier/floor/reset logic where data
exists; "prefer codex less as it nears limits" becomes a score, not prose.

## 3. Policy text emission (on-demand context)

- New file in llm-legs (e.g. `share/worker-policy.md`), printed by worker-pick after
  the NEXT/DATA lines. Contains the semantic routing heuristics that need an LLM:
  codex strong for design, NOT for animation (Fable-side better for animation);
  codex when speed matters; effort medium vs high by task complexity; claudeb for
  long/multi-step or repo-convention-heavy work; ~ratio guidance under fresh codex.
- Editing this file is the ONLY place routing prose changes; CLAUDE.md never grows
  for policy reasons again (claude-md-guard enforces the budget).
- Output contract stays: NEXT / per-account data / POLICY; existing consumers
  (statusline prediction, hooks) must keep parsing.

## 4. Optional: session-side suggestion

A `SESSION:` line suggesting which account Egor should open his next Fable session on
(inverse of worker routing: fable-capable, low Fable bucket, healthy weekly). Cheap to
add once buckets exist; purely informational.

## 5. Acceptance scenarios (fixture-driven)

1. Account A fable-bucket 80%, weekly 40% → ranks above B (fable 5%, weekly 40%) for workers (R1).
2. Account B fable 5%, weekly 75% → excluded/heavily penalized for workers (R2), named as Fable-reserved.
3. olx healthy → first among worker candidates despite $20 tier discount when others are Fable-reserved (R3).
4. Any account ≥ FLOOR in target bucket → never NEXT; all floored → explicit "ALL FLOORED, ask Egor" (R4).
5. Account 50% spent, weekly reset in 3h vs sibling 50% spent, reset in 5d → the former ranks higher (R5) but is not drawn below floor pre-reset (R6).
6. codex 48% spent with reset_credits=1 → verdict FRESH (runway ~152%); same 48% with
   0 credits → plain remaining math; 85% with 0 credits → TIGHT (R5b).
7. Stale/expired rows: behavior unchanged from v1 (trust effective_pct, refresh policy untouched).
8. worker-pick output still parseable by statusline + worker-spawn-hook (golden-file test).

## 6. Explicitly out of scope here

- Rewriting global CLAUDE.md (done afterwards in claude-setup, Egor reviews the diff).
- Any change to commit/push permission rules, hook gates (85/95), or refresh discipline.
