---
name: parallel-sessions
when: the reviewed change's own job is coordinating simultaneous sessions or their workers — ownership records, commit journals and gates, worktree plumbing, run records, locks; its defects appear only when another chat works beside it, so a default review reads the code as correct
---

Review this change as one part of a machine several chats and their workers run at the same time,
over checkouts they all share. The change works when one session works alone. Ask what it does when
it does not: who is recorded as the author of a file, who answers for reviewing it, and what a
session is told when it meets work that is not its own.

Every finding names a file and line in the reviewed code and states the condition first: "when
<state>, <this code> <does what>, and <who> is left with <what>". A finding must also name the
smallest mechanism that would close it — a field a hook could print, a question a tool could ask of
data it already holds, a default it could take instead of a rule written in prose. A gap with no
proposed mechanism is half a finding.

Hunt along these seams:

- **Authorship** — who the record says wrote a file. A chat, an in-process subagent, a headless
  worker on another account, a worker that was resumed, a worker whose vendor keeps no per-file
  record, a chat that was compacted or reopened under a new id, the same chat in a worktree, one
  file written by two of them. Whose name ends up on the work, and whose work ends up with no name.
- **Coverage** — the promise that committed work was reviewed by the session that wrote it. Where
  the set of files a session is answerable for and the set a review actually read can differ:
  scope taken from a different source than ownership, a default that widens or narrows silently, a
  path that changes hands between the review and the commit, work that lands through a channel no
  record watches.
- **Standing off** — what a session does when the tree in front of it holds changes another session
  made. What tells it whether that other session is still working, finished hours ago, or was a
  one-shot process that cannot possibly still hold anything; what it is entitled to do in each case;
  and where the design leaves it waiting for something that will never happen. Blocking forever on
  absent evidence is a defect of the same weight as trampling live work.
- **What the machine says to a model** — every line these tools print into a model's context is the
  whole of what it will reason from. Name each one that states an owner, a state or a refusal
  without the fact needed to act on it — an age, a liveness, a count, a command — and say which
  missing fact the model will invent instead. Prose in a document that a hook could enforce is this
  same defect one level up.
- **Direction of failure** — for each rule, which way it errs when its evidence is thin: toward
  claiming work nobody did, toward losing work somebody did, toward stopping a session that could
  have proceeded. Say which direction this code chose and whether that is the safe one here.

Severity is about what the system loses, not about how clever the state is:

- **P1** — work silently escapes review, one session's work is recorded as another's, or a session
  is left unable to proceed with no evidence that would ever release it.
- **P2** — the machine leaves a model to guess a fact it already holds, or coverage is right only
  while every participant follows a rule written in prose.
- **P3** — hardening, redundancy, and cases needing an unlikely order of events.

Not this lens: happy-path correctness bugs, style, naming, test coverage, message wording, vendor
quota behaviour, and anything that needs an adversarial spelling to demonstrate — these tools guard
against honest sessions colliding, never against an attacker.
