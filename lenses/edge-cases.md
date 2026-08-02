---
name: edge-cases
---

Review the states that sit next to this change, not the path it was written for. The change
works when everything around it behaves. For each category below, ask one question against the
changed code — what nearby state does this change fail to survive, and what is the user left
holding when it does — and follow the answer through the diff.

- **Environment** — something this change leans on is missing, slow, half-answering, out of
  order, restarted mid-operation, or returns a shape it never returns in testing.
- **Boundaries and extremes** — empty, one, exactly at the limit, one past it, zero, negative,
  duplicate, unsorted, absurdly large, wrong encoding, already present.
- **Resource exhaustion** — disk, memory, handles, quota, rate limit, unbounded growth over
  time: what this change consumes that nothing reclaims.
- **Timing, concurrency, reentry** — two of these at once, the same one retried after a partial
  success, interrupted halfway with some state written and some not, a stale read, a clock that
  moves backwards.
- **Human factors** — a misclick, a double submit, the back button, a closed lid, steps taken
  in the wrong order, an abandoned flow, an input pasted from somewhere else.
- **Domain physics** — the material reality this artifact lives in: load on a printed part,
  money and refunds on a payment, tokens on a model call, what a number physically means.
- **Security-adjacent misuse** — who else reaches this code path, and what they can make it do
  by hand without exploiting anything.

Every finding names the file and the changed line whose behavior breaks, and puts the condition
first: "when <state>, <this code> <does what>". A claim with no concrete location in the diff
is not a finding.

Report only states with a real path to occurring in this system. A gap that predates the change
counts when the changed code is what now meets it; one nobody can reach does not.

- **P1** — an adjacent state that breaks the change's primary outcome, or loses data, money or a
  safety margin, with no recovery short of manual repair.
- **P2** — degraded but recoverable: real users or real conditions will plausibly reach it, at
  the cost of a retry, a wrong-but-fixable state, or a misleading result.
- **P3** — rare, cosmetic, or hardening only.

Not this lens: happy-path correctness bugs, naming, structure, style, duplication, missing
tests, message wording. The stock review already hunts those, and repeating them here spends a
finding slot without adding one.
