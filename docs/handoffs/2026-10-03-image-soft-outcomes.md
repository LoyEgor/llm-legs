# Image soft outcomes in legs.jsonl

Status: open

To: LLM doctor owner, image block (share/doctor-ledger.json owners.image). From the image routes chat
«Google video generation integration».

The image block judges hard failures only (rc and error words). A run that exits 0 but did not do what
was meant is invisible to it; the 2026-10-03 case was an edit whose composite silently skipped
(`several-inputs`). Every media wrapper now writes the soft outcome into its `legs.jsonl` record
(`share/image-leg.sh` `image_leg_log`, records from 2026-10-03 17:35 UTC on; older records lack the keys):

| key | meaning | suspicious when |
|---|---|---|
| `composite` `{kind, changed, reason}` | how the edit was pasted back onto its input | `kind: skipped` or `refused` with a `reason` other than `new-generation` while the prompt is an edit |
| `aspect` `{asked, achieved, fit}` | the ratio asked vs delivered, 2% tolerance | `fit: miss` |
| `requested`, `delivered` | takes asked vs files delivered (Flow `--count`) | `delivered < requested` |
| `route`, `fallback_from`, `fallback_reason` | web/Flow first, CLI as the automatic fallback | a fallback share that grows per account or reason |
| `phases` | seconds from start to `lock`, `browser`, `page`, `sent`, `media`, `saved` | a phase far above its own median |
| `queued` | seconds waited on the account lock | sustained waits on one account |

Asked: a doctor rule that groups these by reason per tool and route, flags the suspicious rows above,
and hands them to the night LLM like failures (fix or hand to the owner). Image quality stays an
eye-check, never a nightly judge. The data is two records thin today; build the rule on what accrues.
