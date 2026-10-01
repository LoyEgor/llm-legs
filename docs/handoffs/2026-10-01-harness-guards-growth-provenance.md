# Guard growth provenance follow-up

Status: open

For Harness Doctor (ledger owner), with content ownership routed to the video/film-lab and Google video generation integration chats. Run harness-guards-20261001T020645Z-3cf8.

The goal is to catch instruction growth without an audit (bin/harness-doctor guards_section; docs/harness-doctor-design.md section 11), and report each physical write once (bin/instruction-watch.sh alert_once). No judge or runtime state was changed; the existing Hyperframes install-scope gate was hardened. No quiet rows were included in the packet.

## growth-ungated:/Volumes/Work/Projects/film-lab/08a95dd4/hf/CLAUDE.md

Verdict: handoff. Event 078d5d2199bf5f20 at 2026-09-30T14:48:58Z reports an 8238-byte addition, writer ambiguous. Both current video/alona/R1-{A,B}/hf/CLAUDE.md copies are 8238 bytes; their filesystem mtimes precede the observer call. The observer transcript at 14:48:55 edits harness/skill/SKILL.md and briefs/alona.md, not these files, so observer identity is not writer evidence. No file history was returned by git log for the current paths. Originating initializer/copy is unconfirmed; video/film-lab is outside authorized worktrees. Ask its owner to identify the creator and gate generated instruction copies; do not trim its content here.

## growth-ungated:/Volumes/Work/Projects/film-lab/a19f6d01/hf/CLAUDE.md

Verdict: handoff. Event 078d5d2199bf5f20 at 2026-09-30T14:48:58Z reports an 8238-byte addition, writer ambiguous. Both current video/alona/R1-{A,B}/hf/CLAUDE.md copies are 8238 bytes; their filesystem mtimes precede the observer call. The observer transcript at 14:48:55 edits harness/skill/SKILL.md and briefs/alona.md, not these files, so observer identity is not writer evidence. No file history was returned by git log for the current paths. Originating initializer/copy is unconfirmed; video/film-lab is outside authorized worktrees. Ask its owner to identify the creator and gate generated instruction copies; do not trim its content here.

## growth-ungated:/Volumes/Work/Projects/llm-legs/docs

Verdict: handoff. Event 8eacc04fff044452 at 2026-09-30T02:49:37Z is +396 bytes in the previous night Codex worktree docs/shared-invariants.md, writer ambiguous. gates.jsonl has no matching pass in the existing 900s-before/60s-after window; later 04:25 growth has exact-worktree passes. Main-checkout passes are different paths and cannot authorize this copy. The tripwire caught actual external-worker growth; hook coverage of that writer remains unconfirmed. Owner must decide how non-Claude workers attest instruction audits; widening the temporal/path join would loosen the judge.

## growth-ungated:~/.claude/agents/image-gen.md

Verdict: handoff. Watcher events 6abd878e5e994831, 6abd92505a9ae4b5 and 6abdaf3873a00c54 report +443/+428/+1830 bytes at 22:05:02/22:50:56/00:54:16Z. The 19:17:25 Edit in Google video generation integration has a bloat passed record and is correctly absent from the packet; no equivalent matched pass exists for the three packet events. This rules out a general agents symlink join failure. Exact later writers remain unconfirmed; active image-agent work belongs to that chat. Retain detection and ask the owner for those writes/audits, not a blanket exemption.

## growth-ungated:~/.claude/plugins/marketplaces/claude-plugins-official/plugins/math-proof/README.md

Verdict: weather. Watcher event 6abd5e9b7ca01b57 at 2026-09-30T19:10:19Z added all six math-proof instruction roots. Packet history places each in official marketplace commit ab024cd (2026-09-30), outside both authorized repositories. No model tool gate can preflight a vendor marketplace refresh. Propose owner dismissal for this exact identity only; retain open status and unchanged judge. The later between-session observation is separately tracked under guards-tripwire-rejournal.

## growth-ungated:~/.claude/plugins/marketplaces/claude-plugins-official/plugins/math-proof/agents/math-proof-judge.md

Verdict: weather. Watcher event 6abd5e9b7ca01b57 at 2026-09-30T19:10:19Z added all six math-proof instruction roots. Packet history places each in official marketplace commit ab024cd (2026-09-30), outside both authorized repositories. No model tool gate can preflight a vendor marketplace refresh. Propose owner dismissal for this exact identity only; retain open status and unchanged judge. The later between-session observation is separately tracked under guards-tripwire-rejournal.

## growth-ungated:~/.claude/plugins/marketplaces/claude-plugins-official/plugins/math-proof/agents/math-proof-worker-deep.md

Verdict: weather. Watcher event 6abd5e9b7ca01b57 at 2026-09-30T19:10:19Z added all six math-proof instruction roots. Packet history places each in official marketplace commit ab024cd (2026-09-30), outside both authorized repositories. No model tool gate can preflight a vendor marketplace refresh. Propose owner dismissal for this exact identity only; retain open status and unchanged judge. The later between-session observation is separately tracked under guards-tripwire-rejournal.

## growth-ungated:~/.claude/plugins/marketplaces/claude-plugins-official/plugins/math-proof/agents/math-proof-worker.md

Verdict: weather. Watcher event 6abd5e9b7ca01b57 at 2026-09-30T19:10:19Z added all six math-proof instruction roots. Packet history places each in official marketplace commit ab024cd (2026-09-30), outside both authorized repositories. No model tool gate can preflight a vendor marketplace refresh. Propose owner dismissal for this exact identity only; retain open status and unchanged judge. The later between-session observation is separately tracked under guards-tripwire-rejournal.

## growth-ungated:~/.claude/plugins/marketplaces/claude-plugins-official/plugins/math-proof/skills/siege

Verdict: weather. Watcher event 6abd5e9b7ca01b57 at 2026-09-30T19:10:19Z added all six math-proof instruction roots. Packet history places each in official marketplace commit ab024cd (2026-09-30), outside both authorized repositories. No model tool gate can preflight a vendor marketplace refresh. Propose owner dismissal for this exact identity only; retain open status and unchanged judge. The later between-session observation is separately tracked under guards-tripwire-rejournal.

## growth-ungated:~/.claude/plugins/marketplaces/claude-plugins-official/plugins/math-proof/skills/solo

Verdict: weather. Watcher event 6abd5e9b7ca01b57 at 2026-09-30T19:10:19Z added all six math-proof instruction roots. Packet history places each in official marketplace commit ab024cd (2026-09-30), outside both authorized repositories. No model tool gate can preflight a vendor marketplace refresh. Propose owner dismissal for this exact identity only; retain open status and unchanged judge. The later between-session observation is separately tracked under guards-tripwire-rejournal.

## growth-ungated:~/.claude/skills/hyperframes

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## growth-ungated:~/.claude/skills/hyperframes-animation

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## growth-ungated:~/.claude/skills/hyperframes-audio

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## growth-ungated:~/.claude/skills/hyperframes-cli

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## growth-ungated:~/.claude/skills/hyperframes-core

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## growth-ungated:~/.claude/skills/hyperframes-creative

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## growth-ungated:~/.claude/skills/hyperframes-keyframes

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## growth-ungated:~/.claude/skills/hyperframes-registry

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## growth-ungated:~/.claude/skills/hyperframes-studio

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## growth-ungated:~/.claude/skills/media-use

Verdict: fixed. Watcher batches 6abce54f1ee2d7ca, 6abd23085f903f23 and 6abdbc4e6d7b9082 at 10:32:47/14:56:08/01:50:06Z reinstall the same ten global SKILL.md roots. Intervening deletion batches at 10:38 and 01:23, plus 01:52 removal, rule out mere repeated observation as the shared cause. A video worker transcript at 2026-10-01T01:49:21Z runs npx -y hyperframes init hf; init internally installs global skills. The owning video chat added init protection at 01:53:37Z and refined it at 01:55:54Z, already in claude-setup base 83cf539 hooks/skill-install-scope-gate.sh. Do not duplicate that active fix or claim new credit. Owner must confirm rollout and later absence; generic shell-parser bypasses and actual runtime hook loading were not established.

Fixed in this run: inherited HYPERFRAMES_SKIP_SKILLS=1 previously bypassed init inspection even when the command cleared or overrode it. The gate now evaluates the effective value per command prefix and export/unset segment. Regression suite adds six inherited-environment cases and clears ambient skip state for deterministic tests; old code fails the explicit =0 case, and six fixture probes pass after the change. This hardens the existing init fix rather than replacing it; runtime rollout remains the owner follow-up.

## guards-synced-skills-vendor-sync

Verdict: weather. Current retained events include vendor docs/docx syncs at 2026-09-30T00:44-03:59Z, including watcher 6abc6f522478d465 and tripwire bba946b035711a7e. This extends the prior google-workspace-only note: the match still names the vendor-owned synced tree, not a model file writer. No native PreToolUse event is available for org synchronization; retain open row and propose dismissal to Harness Doctor without broadening its match. Duplicate observations and missing write keys are separately handed off; the source cannot prove all sync records are distinct writes.

## guards-tripwire-rejournal

Verdict: handoff. The regression now includes 6bbd8cc122eaaeea (2026-09-30T09:42:45Z, 15 google-workspace files) and e4a27d26b246bec2 (2026-10-01T01:12:13Z, six math-proof files plus a 33-byte README). Math-proof was already reported by watcher 6abd5e9b7ca01b57 at 19:10:19Z. Current alert_once filters claimed files; Lua watchEmit does too; both derive hash@mtime via the same watch_mark_key and accept w-suffixed markers. Thus the original whole-batch re-journaling implementation is already removed. Historical records carry no hash@mtime, so an actual vendor rewrite versus expired/missing claim versus old resident watcher cannot be distinguished. Do not claim a dedup fix or suppress between-sessions. Owner must obtain write-key/runtime-version evidence and reproduce watcher-first then resumed-baseline behavior. Existing tripwire-duplicate-records blind spot remains applicable.

## Owner actions and limits

- Video/film-lab owner: trace the two generated CLAUDE.md copies; verify the existing Hyperframes init gate is loaded for new workers. The exact original installer of the first two batches was not established.
- Google video generation integration owner: supply the audit/writer evidence for the three image-gen growth events.
- Harness Doctor: decide vendor-only dismissals, non-Claude worker audit receipts, and instrumentation for duplicate-write proof. Do not equate an observer or a watcher candidate with the writer.
- Preserve the current deduplication and retention logic: no vendor-native write deduplication replacement was found in the component/history reviewed. The old batch behavior is already gone; a second speculative workaround would not establish the cause.

Validation and final suite results are recorded in the run report. Ten Hyperframes/media-use identities are fixed-pending; the remaining five handoffs and seven vendor-weather verdicts remain open.

## Adversarial check

The old gate fails the inherited-value explicit-zero fixture. The fix covers zero, empty, unset, export-zero and export removal, while preserving plain init under an effective inherited one. Existing quoted documentation, shell wrappers, project-local installation and help cases remain in the covering suite. This remains a command-shape guard, not an interpreter for arbitrary computed shell code; historical init calls were plain npx commands. New blind spot skill-install-effective-environment records that the reproduced environment bypass itself was not visible in the doctor packet.
