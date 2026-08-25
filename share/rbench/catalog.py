

EFFORTS = ("low", "medium", "high", "xhigh", "max")
OPENCODE_EFFORTS = ("low", "medium", "high")
OPENCODE_MODEL_IDS = {
    "oc-glm52": "glm-5.2",
    "oc-dsv4pro": "deepseek-v4-pro",
    "oc-grok45": "grok-4.5",
    "oc-qwen37max": "qwen3.7-max",
    "oc-kimik3": "kimi-k3",
    "oc-kimik27code": "kimi-k2.7-code",
    "oc-glm51": "glm-5.1",
    "oc-dsv4flash": "deepseek-v4-flash",
    "oc-qwen37plus": "qwen3.7-plus",
    "oc-mmm3": "minimax-m3",
    "oc-mimo25pro": "mimo-v2.5-pro",
    "oc-mimo25": "mimo-v2.5",
    "oc-hy3": "hy3",
}
OPENCODE_MAX_TOKENS = (32000, 16384, 8192)
# A model whose thinking cannot be suppressed needs a ceiling above its thinking,
# not below it: minimax-m3 spends ~38k tokens before it answers at all, so the
# shared ladder guarantees it stops mid-thought and returns nothing (measured: 32k
# ends at finish_reason=length with no review, 64k answers in ~690s).
OPENCODE_MAX_TOKENS_BY_MODEL = {"oc-mmm3": (64000, 32000)}
# Measured per model, not guessable: a buffered reply is dropped at the upstream
# response deadline, while streaming lifts that deadline but makes some models
# emit reasoning forever and never start the answer. Only models proven to need
# streaming get it; everything else stays buffered and relies on 5xx retries.
OPENCODE_STREAM_MODELS = frozenset({"oc-dsv4pro", "oc-grok45"})
# Measured capability table — the module's own knowledge of a gateway whose models
# behave differently, so nothing here is folklore. Probed 2026-07-25 with n=2 per mode
# on a small reasoning task, and cross-checked against every recorded review run on
# 143fc2f (`review-bench oc-models` prints this next to the live success rate).
#   off     — whether `--no-reasoning` actually silences thinking. Measured as an
#             answer of 2-4 tokens with no reasoning tokens; False means the knob is
#             accepted and ignored, which on a large diff walks into the gateway's
#             ~190s idle timeout.
#   scales  — whether an effort visibly scales thinking (low < medium), so asking for
#             more is meaningful rather than noise. No model on the plan REJECTS an
#             effort: 104 probe calls produced zero 400s.
#   off_s   — median review seconds with reasoning off on the 54k-token diff.
#   low_s   — same at `--effort low`, None where not measured.
# Reasoning stays off by default because it is 20x faster; the cost is correctness on
# a task that needs thought (in the probe, every compliant model answered the puzzle
# WRONG with reasoning off and right at any effort), which is why an effort cell is a
# genuinely different reviewer rather than a duplicate.
OPENCODE_MODEL_FACTS = {
    "oc-glm52": {"off": True, "scales": False, "off_s": 13, "low_s": 234,
                 "note": "1 true claim of 14 bare, 0 of 9 with a review profile; an effort costs 18x"},
    "oc-glm51": {"off": True, "scales": False, "off_s": 14, "low_s": None,
                 "note": "adjudicated 1 true claim of 11 over 3 passes, same defect glm-5.2 found"},
    "oc-qwen37max": {"off": True, "scales": True, "off_s": 9, "low_s": None,
                     "note": "1 true claim of 8 bare, 0 of 5 with a review profile; invents missing code"},
    "oc-qwen37plus": {"off": True, "scales": True, "off_s": 8, "low_s": None,
                      "note": "adjudicated 0 true claims of 10 over 3 passes: wholly speculative or narrative"},
    "oc-kimik3": {"off": True, "scales": True, "off_s": 23, "low_s": 186,
                  "note": "the leg's net and verifier: 5 true of 31, but 4 defects grok-4.5 misses"},
    "oc-kimik27code": {"off": False, "scales": False, "off_s": 10, "low_s": None,
                       "note": "1-30 findings per run and failed 2 of 3 passes; kimi-k3 replaces it"},
    "oc-mimo25": {"off": True, "scales": False, "off_s": 43, "low_s": None,
                  "note": "adjudicated 0 true claims of 13 over 3 passes; narrates the diff"},
    "oc-mimo25pro": {"off": True, "scales": False, "off_s": 14, "low_s": None,
                     "note": "1 true claim of 17 bare, 0 of 4 with a review profile; thinks in text"},
    "oc-hy3": {"off": True, "scales": True, "off_s": 14, "low_s": None,
               "note": "effort scales cleanly, but adjudicated 1 true claim of 18 over 3 passes"},
    "oc-mmm3": {"off": False, "scales": False, "off_s": 204, "low_s": None,
                "note": "ignores every knob, needs the 64k ceiling; 1 of 7 runs completed"},
    "oc-grok45": {"off": False, "scales": True, "off_s": None, "low_s": 87,
                  "note": "was the leg's precise half (11 true of 15); retired 2026-08-24 — "
                          "79% of attempts fail with in-gate 5xx walks, 0 confirmed since 08-13"},
    "oc-dsv4pro": {"off": False, "scales": False, "off_s": 905, "low_s": None,
                   "note": "precise but 2 of 12 runs completed, ~900s each; too slow for any tier"},
    "oc-dsv4flash": {"off": True, "scales": True, "off_s": 12, "low_s": 79,
                     "note": "34 true claims of 123 over 12 passes on 4 commits; also the leg's "
                             "verifier"},
}
# Derived, so the policy cannot drift from the measurement: a model that ignores the
# reasoning-off knob AND is measurably fixed by a budget is offered only with one.
OPENCODE_EFFORT_REQUIRED_MODELS = frozenset({"oc-grok45"})
# A gateway failure, spelled only where the text says the number IS a status (`HTTP 504`,
# `status: 502`, the curl-level `HTTP 000`): a rater's prose cites line numbers, and a bare
# `5[0-9][0-9]` read `line 512` as a dead gateway and retried a cell that had already answered.
# The class itself — 5xx plus 000 — is the client's own (shared-invariants row az).
HTTP_SERVER_STATUS = r"(?:HTTP(?:/[0-9.]+)?\s+|status(?:_code)?\s*[:=]\s*)(?:5[0-9][0-9]|000)\b"
# Refused outright, with the evidence in the message. Not a taste call: no
# configuration of these ever produced a review, so a cell would only spend the
# subscription's window and the run's wall clock.
OPENCODE_UNUSABLE_MODELS = set()
# The only OpenCode cells that survived strict adjudication AND the 2026-08-24 waits audit
# (docs/analysis/review-waits-2026-08-24.md): kimi-k3 is the wide net and earns its repeats
# (a second copy adds a defect in 26% of panels), deepseek-v4-flash finds what it misses but
# runs single — its second copy added a panel-unique defect once in 100 runs while setting the
# panel wall in 10 of them. grok-4.5 is retired in WORTHLESS_MODELS. Every other cell scored at
# most one true claim per three passes. Also the tiers' eco OpenCode block.
OPENCODE_REVIEW_LEG = ("oc-kimik3 x2", "oc-dsv4flash")
OPENCODE_REVIEW_LEG_MAX = ("oc-kimik3 x3", "oc-dsv4flash")
OPENCODE_VERIFIER = "oc-dsv4flash"
# Fallbacks for a verifier the gateway is refusing, in measured order. Scored 2026-08-04 against
# hand-adjudicated verdicts: deepseek-v4-flash on the shapes prompt keeps 16 of 24 real defects
# while dropping 41 of 52 false ones, and kimi-k3 on the dual prompt keeps 11 and drops 47. The
# rest are measured on the stock prompt only — qwen kept 9 of 12 real and dropped 6 of 12 false,
# mmm3 9 and 5. The other two permitted verifiers are worse than none at all and are deliberately
# absent — mimo25 threw away 5 real defects of 12, and mimo25pro dropped 1 false one of 12 while
# taking longer than any other cell in the table.
OPENCODE_VERIFIER_CHAIN = ["oc-kimik3", "oc-qwen37plus", "oc-mmm3"]
# Every chain link above answers through the one opencode gateway, so its router outage retires
# all of them in a single move — twice on 2026-08-04. The agy side has a transport of its own,
# and judges its own findings first. Measured 2026-08-08 on 150 held-out agy claims, one call
# each: gemini-3.6-flash at medium on the stock wording kept 63 of 75 real and dropped 40 of 75
# false, deepseek-v4-flash on its own best wording kept 61 and dropped 25, both losing 4 of the
# 31 canonical defects. Effort does not move it (high scored 93%/52% against medium's 92%/52%
# on 120 shared claims) and neither does the wording — a persona, the review skill's do-not-
# comment list and its substance rubric all landed within 4 points of stock. The model is the
# whole difference, so the leg keeps the stock prompt and swaps who answers first.
GEMINI_VERIFIER = "agy-flash36"
GEMINI_VERIFIER_EFFORT = "medium"
GEMINI_VERIFIER_RATER = {"model": GEMINI_VERIFIER, "effort": GEMINI_VERIFIER_EFFORT}
# Highest effort a model has ever returned a review of a large diff at; None would mean
# no effort at all. An entry needs a replication, because one silent attempt is not a
# ceiling: kimi-k3 at medium looked dead after two attempts with no output, then finished a
# third in 623s once the client escalated a 236s buffered 503 to streaming, and it is
# deliberately absent. deepseek-v4-flash earned its entry twice per effort on the 143fc2f
# diff — medium spent all 32k tokens on reasoning in 234s and again in 2176s, high lost the
# stream after a 236s 503 and then spent the budget the same way. Only a model that NEVER
# completes belongs here — a slow or flaky effort is priced, not refused.
OPENCODE_EFFORT_CEILING = {"oc-dsv4flash": "low"}
# Screened once each with reasoning off on the 143fc2f diff (2026-07-25) and NOT
# adopted as cells: none produced a single true finding, so there is nothing to
# benchmark yet. Kept here because "which plan models did we try" is the question
# this table exists to answer — review-bench oc-models prints it. A single sample is
# a screening, not a verdict: promoting one needs a real three-pass run.
WORTHLESS_CELLS = {
    "oc-glm51": "26 claims over 2 commits, 1 true",
    "oc-glm52": "33 claims over 2 commits, 3 true, never the only cell to find a defect",
    "oc-grok45-medium": (
        "answers with a one-line announce and stops (10-token completions, findings leak into "
        "reasoning_content); 0 parseable reviews in 3 runs on 2026-07-28"
    ),
    # Retired on failure cost, not on claim quality: its early precision never came back.
    "oc-grok45-low": (
        "79% of 1166 recorded attempts failed, spending 546 failing minutes against 111 model "
        "minutes and holding a gate slot through its 5xx walks; 0 confirmed defects in the "
        "2026-08-13..24 triage window (162 instances)"
    ),
    "oc-grok45-high": (
        "retired with the model on 2026-08-24: grok-4.5 answers 5xx to most calls whatever "
        "the effort (see oc-grok45-low), and high has 1 recorded attempt to price it by"
    ),
    "oc-hy3": "23 claims over 2 commits, 4 true",
    "oc-kimik27code": "21 claims over 2 commits, 3 true",
    "oc-qwen37max": "18 claims over 2 commits, 4 true",
    "agy-flash36-low-skill": "16 claims over 10 commits, 0 true",
    # Retired on defects rather than on claim counts: 3 claims is an order of magnitude less
    # evidence than every row above, but an Opus cell is priced per run, and the two runs it did
    # get are decisive on the axis a rater is bought for.
    "opus-xhigh": (
        "1 of the 17 defects on the 2 commits it ran, where opus-high took 7 of one commit's 8; "
        "it spent 5 tool turns to that cell's 18 there, so the higher effort bought fewer reads "
        "rather than deeper ones"
    ),
}
# Read after the per-cell list above and keyed by the model: an effort and a review-profile
# suffix are spellings of one model, so a list of exact specs leaves whichever spelling nobody
# thought to write down launchable.
WORTHLESS_MODELS = {
    "oc-grok45": (
        "grok-4.5 is retired: 79% of 1166 recorded attempts failed at every effort, spending 546 "
        "failing minutes against 111 model minutes, and 0 of its claims were confirmed in the "
        "2026-08-13..24 triage window"
    ),
}
EXCLUDED_CELLS = {
    "agy-flash35-low-skill": (
        "server serves Medium for the low model id (model_mismatch, 2026-07)"
    ),
}
EXCLUDED_CELL_REPLACEMENTS = {
    "agy-flash35-low-skill": "agy-flash35-medium-skill",
}
OPENCODE_SCREENED_MODELS = {
    "glm-5": "19s, no findings and no no-issues marker",
    "kimi-k2.5": "12s, narrated the diff instead of reviewing",
    "kimi-k2.6": "10s, narrated the diff instead of reviewing",
    "minimax-m2.5": "24s, empty completion",
    "minimax-m2.7": "24s, empty completion",
    "qwen3.5-plus": "40s, 5 findings, all false when read against the code",
    "qwen3.6-plus": "202s, 1 finding, false when read against the code",
    "hy3-preview": "HTTP 400: not served for completions on this plan",
    "mimo-v2-omni": "HTTP 500 after the client's own retries",
    "mimo-v2-pro": "HTTP 500 after the client's own retries",
}
# Reserved for a model that needs a think-tag prefix pinned from here. Empty by
# measurement: which reasoning-off knob a model accepts turns out to vary between
# requests for the same model, so the client negotiates per request and pinning a
# strategy here would only defeat that. The prefix is also not free — a model can
# read the closing tag as "the turn is over" and answer nothing.
OPENCODE_PREFILL_MODELS = frozenset()
OPENCODE_EXPECTED_DEFAULT_S = 60
# A cell that asks for an effort asks for reasoning, which on this gateway means a
# long generation, so it is expected to be slow whatever the model.
OPENCODE_EFFORT_EXPECTED_S = 600


AGY_EFFORTS = {
    "agy-pro": ("low", "high"),
    # Served from CLI 1.1.12. All three efforts were label-probed on 2026-08-13 and each came back
    # as its own — including low, which is the spelling agy-flash35 is excluded for serving as
    # Medium, so this family is not born with that defect.
    "agy-flash37": ("low", "medium", "high"),
    "agy-flash36": ("low", "medium", "high"),
    "agy-flash35": ("low", "medium", "high"),
}
# v1.1.9 still misroutes the pro-high slug to Flash; every other id carries its effort.
AGY_MODEL_IDS = {
    "agy-pro": "gemini-3.1-pro",
    "agy-flash37": "gemini-3.7-flash",
    "agy-flash36": "gemini-3.6-flash",
    "agy-flash35": "gemini-3.5-flash",
}
RATER_TIMEOUT_S = 1800
AGY_TIMEOUT_MAX_S = 600
AGY_TIMEOUT_GRACE_S = 30
# The duration cap per (model, effort) pair is anchored on yield: the longest of the pair's
# completions that produced a CONFIRMED finding over the window + grace, or, with too few of
# them, the longest of all its completions + grace. Kills raise nothing — the cap follows what a
# pair delivers, never what it merely survived (docs/analysis/review-latency-2026-08-24.md,
# section 5). The max and not a quantile: q95 lost 6.1% of panel-unique confirmed findings for
# the same p90 wall, which the ceiling and the window earn on their own.
CAP_WINDOW_DAYS = 21
DURATION_CAP_GRACE_S = 180
DURATION_CAP_THIN_SAMPLES = 5
DURATION_CAP_DEFAULT_S = 900
# Gemini's ceiling per tier, applied after the yield rule. Only agy: its tail past these holds no
# confirmed findings (section 4), while opus and sol legitimately run 300-1200s for theirs.
AGY_DURATION_CEILING_S = {"T0": 480, "T1": 480, "T2": 600, "T3": 600}
# The stall cap under the duration cap: the longest silent gap the pair's completions showed
# over the window + grace. A cell that stands silent past that is cut; waiting for it has no value.
STALL_CAP_GRACE_S = 120
STALL_CAP_FLOOR_S = 240
# Under a second on purpose: every reader that measures real waits filters patched-sleep noise at
# the one-second line, and a poll nap is exactly such noise.
STALL_POLL_S = 0.25
AUTO_RATERS = tuple(
    spec for spec in (
        tuple(
            f"{model}-{effort}"
            for effort in ("medium", "high", "xhigh", "low", "max")
            for model in ("sol", "opus")
        ) + tuple(
            f"sol-{effort}-bare"
            for effort in EFFORTS
        ) + tuple(
            f"{model}-{effort}-skill"
            for model, efforts in AGY_EFFORTS.items()
            for effort in efforts
        )
    )
    # --auto must never offer a cell the run then refuses; the retirement list is the authority.
    if spec not in WORTHLESS_CELLS and spec not in EXCLUDED_CELLS
)
CLAUDE_MODEL_IDS = {"fable": "claude-fable-5"}
VERDICTS = {"confirmed", "false_positive", "duplicate"}
WEIGHTS = {"P1": 5, "P2": 2, "P3": 1}
ADJUDICATION_TOK_ESTIMATE = {"duplicate": 400, "false_positive": 1500}
# One spelling for every surface a human reads — report frames, the tiers table, the health
# table — so the same cell is recognisable across them without translating. Each name carries the
# family and then only what the pool it is read in needs to tell it from its neighbours: version
# digits when two versions of the family run, effort when the family runs more than one, `-bare`
# when the family runs both with and without the vendor's review skill. Nothing is hand-listed —
# a second variant entering a tier renames its family by itself. Machine specs (`--raters`,
# commands, corpus rows) keep the full ids: that grammar is parsed, and only this is read.
SHORT_MODEL_NAMES = {
    "agy-pro": ("gem-pro", ""),
    "agy-flash37": ("gem-flash", "37"),
    "agy-flash35": ("gem-flash", "35"),
    "agy-flash36": ("gem-flash", "36"),
    "oc-kimik3": ("kimi", "k3"),
    "oc-kimik27code": ("kimi", "k27code"),
    "oc-grok45": ("grok", "45"),
    "oc-dsv4flash": ("deepseek", "v4flash"),
    "sol": ("sol", ""),
    "opus": ("opus", ""),
    "sonnet": ("sonnet", ""),
    "haiku": ("haiku", ""),
    "fable": ("fable", ""),
}
SHORT_EFFORT_NAMES = {"medium": "med"}
# Every tier carries the whole OpenCode block (owner's rule, 2026-07-28): it costs no
# subscription quota at all, so no OpenCode cell is ever dropped for budget.
#
# The Gemini block is a ladder of its own, because it is not free and its price is not the
# panel's wall clock. Every agy cell bills its own Google account, so the panel's Gemini price is
# the SUM of its cells' minutes, not the slowest of them — which is why one shared composition
# for T1, T2 and T3 spent T3's quota on every T1 review.
#
# Minutes, and nothing per run: the 5h-window brackets taken 2026-08-07 fit
# `0.0637*seconds - 1.64`, but every run measured lasted 52-156s, so that intercept is
# extrapolation below the whole sample and budgeting by it pays a panel for splitting its work
# into short runs. Priced proportionally and weighted by how often each tier runs, the ladder
# spends about 12% less Gemini than the flat floor it replaces, and that is worth having only
# because nothing was given up for it.
#
# Nothing given up is the constraint the compositions are chosen under, checked on all four
# populations these tiers are ever quoted over: whole-panel coverage and whole-panel P1 on the
# commits `coverage_pct` reads, and Gemini-only coverage and P1 over the 235-defect corpus. Each
# tier's --max Gemini panel also CONTAINS that tier's own eco panel, so escalating never runs
# fewer attempts of a cell than the default panel would have. Within a tier and over this block
# only: across tiers T0 and T1 read different diffs, so a superset there protects nothing and
# costs about nine points of the saving — repeat counts fall as well as rise from tier to tier on
# purpose — and panel-wide the guarantee does not hold at all, because frontier composes T3's
# Codex ceiling without one cell of T3's default panel.
#
# Most of that saving is Pro. Per minute of its own run, pro-low returns 0.48 confirmed defects
# and pro-high 0.57, against 0.96-1.33 for every Flash cell, and the flat floor spent 38% of its
# minutes on the two of them. pro-low is gone; one pro-high stays wherever a tier can still afford
# the cell with the panel's best precision.
#
# Eco panels stop at ROSTER_MAX cells and the --max panels at most one over: the panel runs its
# cells at once, and a cell past the roster wraps onto an account another cell already holds and
# bills it twice instead of spreading. ROSTER_MAX bounds the roster that is enumerated, it does
# not promise that many accounts — walled ones are dropped before the wrap, so a panel this wide
# already doubles up whenever fewer Google accounts are usable than it has cells. Staying inside
# the roster is the most a composition can do about that.
#
# Gemini 3.7 Flash (2026-08-14, corpus at 235): flash37-medium runs a 1.58 min median against
# flash35-medium's 1.81 and is the cleanest Flash on raw claims (2 false of 19 adjudicated), so
# it takes a slot in every panel; flash37-high (2.38 min, the priciest Flash, 9 of 34 attempts
# lost to transport errors that the rates already price) holds the P1 coverage the dropped
# repeats held at T0, and since 2026-08-24 runs one copy in T1/T2 as well to collect statistics
# beside the other legs (Egor). flash37-low earned 22 attempts and still no slot: no
# composition holding it matches these panels on all four populations at their price. Same
# enumeration, every population no lower, every tier cheaper.
REVIEW_TIER_AGY = {
    "T0": [
        "agy-flash35-medium-skill",
        "agy-flash35-high-skill",
        "agy-flash36-medium-skill",
        "agy-flash37-medium-skill",
        "agy-flash37-high-skill",
    ],
    "T1": [
        "agy-flash35-medium-skill",
        "agy-flash35-high-skill",
        "agy-flash36-medium-skill",
        "agy-flash36-high-skill x2",
        "agy-flash37-medium-skill",
        "agy-flash37-high-skill",
        "agy-pro-high-skill",
    ],
}
# T2 runs T1's Gemini panel: both tiers are answered by the same cheapest block that gives up
# nothing, and T2 is 43% of reviews, so this is where most of the saving lands.
REVIEW_TIER_AGY["T2"] = list(REVIEW_TIER_AGY["T1"])
REVIEW_TIER_AGY["T3"] = [
    "agy-flash35-medium-skill x2",
    "agy-flash35-high-skill",
    "agy-flash36-medium-skill",
    "agy-flash36-high-skill",
    "agy-flash37-medium-skill",
    "agy-pro-high-skill",
]
REVIEW_TIER_AGY_MAX = {
    # T0 has no heavier Gemini panel of its own (owner's rule, 2026-08-07): a tier for at most
    # twenty changed lines has nothing to spend a ceiling on.
    "T0": list(REVIEW_TIER_AGY["T0"]),
    "T1": [
        "agy-flash35-medium-skill x2",
        "agy-flash35-high-skill",
        "agy-flash36-medium-skill",
        "agy-flash36-high-skill x2",
        "agy-flash37-medium-skill",
        "agy-flash37-high-skill",
        "agy-pro-high-skill",
    ],
    # flash37-high x1 (2026-08-24, Egor): collecting statistics beside the other legs in T1/T2.
    # The ceiling stays inside ROSTER_MAX + 1, so T2's second flash36-medium copy (one repeat on
    # record, nothing added) gives up its slot.
    "T2": [
        "agy-flash35-medium-skill x2",
        "agy-flash35-high-skill",
        "agy-flash36-medium-skill",
        "agy-flash36-high-skill x2",
        "agy-flash37-medium-skill",
        "agy-flash37-high-skill",
        "agy-pro-high-skill",
    ],
    "T3": [
        "agy-flash35-medium-skill x2",
        "agy-flash35-high-skill x2",
        "agy-flash36-medium-skill",
        "agy-flash36-high-skill",
        "agy-flash37-medium-skill",
        "agy-pro-high-skill",
    ],
}
REVIEW_TIER_FLOOR = {
    tier: [*OPENCODE_REVIEW_LEG, *cells] for tier, cells in REVIEW_TIER_AGY.items()
}
REVIEW_TIER_FLOOR_MAX = {
    tier: [*OPENCODE_REVIEW_LEG_MAX, *cells] for tier, cells in REVIEW_TIER_AGY_MAX.items()
}
# Eco is the paid composition with the least Sol spend that at least matches the prior eco
# coverage; max is the measured ceiling within the tier's budget, trimmed of cells whose
# marginal is under ~1 defect on the corpus (owner rule 2026-08-04). The OpenCode layer is never
# trimmed (owner rule). `coverage_pct` is the whole panel over the four commits every one of its
# cells ran on (143fc2f, 8448a35, 8553616, fabcae4) — recomputed 2026-08-25 with
# `frontier_inputs` + `hit_rates` + `composition_coverage` over that corpus, after the OpenCode
# leg lost grok-4.5 and the second deepseek copy — which cost every tier 5 to 7 points of it. Recompute the Codex
# cells with frontier, don't hand-edit. It answers for no other side, each for its own reason.
# Not for the Gemini block: it prices a composition at the max of its cells' minutes under a
# wall-clock budget, which is the model the block above rejects, so a frontier answer there
# ignores the sum-of-cells rule. That
# block is recomputed by enumerating multisets of the pool's agy cells, pricing each at the sum
# of its cells' median `duration_ms` over the worktree runs in `benches/*/meta.json`, and taking
# the cheapest that `composition_coverage` scores no lower than the panel it replaces on each of
# the four populations — whole panel over the `coverage_pct` commits, agy cells alone over the
# whole corpus, coverage and P1 apiece.
#
# And not for the Claude block, which is recomputed by that same enumeration (2026-08-08) with
# three differences that cost a day to find — the first of them is why frontier cannot be asked
# here either:
#   - Price it in dollars, not minutes. `meta.json` has no usage, but `benches/*/raw-<cell>.json`
#     carries `modelUsage`, whose `costUSD` includes the nested agents a skill cell spawns. A run
#     is billed mostly for re-reading code, not for thinking: on f0906b7 opus-xhigh took 5 tool
#     turns to opus-high's 18 and so cost less at a higher effort while finding 1 defect to 7.
#   - Balance that price per commit. Cells have wildly different run mixes (opus-low: 113 runs,
#     8 of them on the corpus commits), so a median over all of a cell's runs compares different
#     diffs. Take each cell's median per commit, then the mean over the seven.
#   - Score on all four populations, never the panel alone. Dropping opus-high from T2 costs 0.7
#     points of panel coverage and 29% of what the Claude leg itself finds; the other three legs
#     overlap it and hide the loss.
# Buy variety, not repetition: a second run of a cell already in the panel returns ~0.5 defects
# per dollar against ~4 for adding a different one. opus-high-skill earns no tier slot ($3.32 for
# 25.5 defects against opus-medium's $1.78 for 34.5); opus-xhigh is retired in WORTHLESS_CELLS,
# which is what keeps --auto from offering it.
#
# Two consequences of this refit that are invisible from one tier. The Claude panels now reach
# four cells at T3 and five at its ceiling against a four-profile pool, so the ceiling doubles up
# on an account and bills it twice before a single profile is even walled — accepted here, on the
# same trade the agy block above takes, because the fifth cell is worth more than the spread is.
# The test bounds these panels by ROSTER_MAX, which is the width the enumeration can staff at
# all, not a promise of one account per cell: that promise is what this tier deliberately gives
# up. And putting skilled cells in the
# tiers moved the whole opus family onto the skill axis, so the bare cells are spelled
# `opus-low-bare` / `opus-med-bare` / `opus-high-bare` from here on and reports written before
# this commit cannot be compared to later ones by cell name.
REVIEW_TIERS = {
    "T0": {
        "budget_min": 3,
        "when": "Up to 20 changed lines in up to 2 files",
        "coverage_pct": {"eco": 34.2, "max": 37.5},
        "cells": [
            *REVIEW_TIER_FLOOR["T0"],
            "opus-low",
            "sol-low",
            "sol-low-bare",
        ],
        "cells_max": [
            *REVIEW_TIER_FLOOR_MAX["T0"],
            "opus-low",
            "opus-low-skill",
            "sol-low",
            "sol-low-bare",
        ],
    },
    "T1": {
        "budget_min": 6,
        "when": "Up to 150 changed lines, or any change under bin/ or tests/",
        "coverage_pct": {"eco": 42.6, "max": 48.1},
        "cells": [
            *REVIEW_TIER_FLOOR["T1"],
            "opus-medium",
            "sol-low",
            "sol-low-bare",
            "sol-medium-bare",
        ],
        "cells_max": [
            *REVIEW_TIER_FLOOR_MAX["T1"],
            "opus-low",
            "opus-low-skill",
            "opus-medium",
            "sol-low",
            "sol-low-bare",
            "sol-medium-bare",
        ],
    },
    "T2": {
        "budget_min": 10,
        "when": "Up to 600 changed lines, or a core measurement tool change",
        "coverage_pct": {"eco": 53.7, "max": 60.7},
        "cells": [
            *REVIEW_TIER_FLOOR["T2"],
            "opus-high",
            "opus-medium",
            "opus-low",
            "sol-high",
            "sol-high-bare x2",
        ],
        "cells_max": [
            *REVIEW_TIER_FLOOR_MAX["T2"],
            "opus-high",
            "opus-medium",
            "opus-low",
            "opus-low-skill",
            "sol-high",
            "sol-high-bare x2",
            "sol-xhigh",
            "sol-xhigh-bare",
        ],
    },
    "T3": {
        "budget_min": 20,
        "when": "More than 600 changed lines",
        "coverage_pct": {"eco": 66.1, "max": 72.3},
        "cells": [
            *REVIEW_TIER_FLOOR["T3"],
            "opus-high",
            "opus-medium",
            "opus-low",
            "opus-low-skill",
            "sol-high",
            "sol-high-bare",
            "sol-max-bare",
        ],
        "cells_max": [
            *REVIEW_TIER_FLOOR_MAX["T3"],
            "opus-high",
            "opus-medium",
            "opus-medium-skill",
            "opus-low",
            "opus-low-skill",
            "sol-high",
            "sol-max x2",
            "sol-max-bare",
            "sol-xhigh-bare",
        ],
    },
}

# What one run of a Go-plan model costs, in the only currency that subscription buys: requests
# granted per 5h window. gpt-5.6-luna bills every request at 2x, so its 4100 is really 2050.
GO_REQUESTS_5H = {
    "kimi-k3": 110,
    "grok-4.5": 120,
    "qwen3.8-max": 160,
    "glm-5.2": 880,
    "deepseek-v4-pro": 1050,
    "minimax-m3": 3200,
    "deepseek-v4-flash": 3800,
    "gpt-5.6-luna": 4100,
    "qwen3.7-plus": 4300,
    "hy3": 4300,
    "mimo-v2.5": 30100,
}
GO_USAGE_WEIGHT = {"gpt-5.6-luna": 2}
# Live plan models the Go plan publishes no per-request grant for. Their cost stays blank on
# purpose: a made-up grant would rank them against the models that publish one.
GO_UNPRICED = frozenset({"qwen3.7-max", "kimi-k2.7-code", "glm-5.1", "mimo-v2.5-pro"})
assert all(plan_model in GO_REQUESTS_5H or plan_model in GO_UNPRICED
           for plan_model in OPENCODE_MODEL_IDS.values())
# The other three vendors bill windows that no measured ruler converts into Go requests, and no
# limit share of theirs converts into another's either. PRICE_WEIGHTS stands in until such a
# ruler exists, and prices a run rather than a window — which is why the two cost columns never
# compare (the board's footer says so to the reader).
# price-proxy, 2026-08-17: list price per token relative to each vendor's cheapest tier, not a
# bill and not a limit share.
PRICE_WEIGHTS = {
    "anthropic": {"haiku": 1, "sonnet": 2, "opus": 5, "fable": 10},
    "openai": {"gpt-5.6-luna": 1, "gpt-5.6-terra": 10, "sol": 25},
    "google": {"flash-lite": 1, "flash": 6, "pro": 8},
}
BOARD_COST_SCALE = 1000

def model_name_parts(model):
    # A model outside the table still has to render: the vendor prefix is what the surrounding
    # column or row already says, so dropping it leaves the part that identifies the model.
    parts = SHORT_MODEL_NAMES.get(model)
    if parts:
        return parts
    return str(model).removeprefix("oc-").removeprefix("agy-"), ""


