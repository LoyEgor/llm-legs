import re
from collections import Counter, defaultdict

from . import catalog as _catalog

# Effort is a launch parameter on these two sides — the same cell is run at another effort next
# round — so it is spelled out even where this pool happens to hold only one. Everywhere else it
# names a distinct cell in a fixed composition and appears only when it separates two of them.
ALWAYS_EFFORT_SIDES = ("claude", "codex")
_REVIEW_POOL_RATERS = None
_DEFAULT_NAME_SCHEME = None
RATER_RE = re.compile(
    r"^(sol|opus|sonnet|haiku|fable|agy-pro|agy-flash35|agy-flash36|agy-flash37"
    r"|oc-glm52|oc-glm51|oc-dsv4pro|oc-dsv4flash|oc-grok45|oc-qwen37max"
    r"|oc-qwen37plus|oc-kimik3|oc-kimik27code|oc-mmm3|oc-mimo25pro|oc-mimo25|oc-hy3)"
    r"(?:-(low|medium|high|xhigh|max))?(-skill|-bare|-anthropic|-google)?$"
)
RATER_REPEAT_RE = re.compile(r"^(\S+) x([2-9])$")
RATER_ATTEMPT_RE = re.compile(r"#\d+$")
PRIORITY_RE = re.compile(r"\b(P[123])\b", re.IGNORECASE)
# Half this repository's files have no extension, so a cited path is anything carrying a
# directory separator as well as anything carrying a suffix.
LOCATION_RE = re.compile(
    r"(?P<file>[^\s:()\[\]{}<>,]+/[^\s:()\[\]{}<>,]+|[^\s:()\[\]{}<>,]+\.[A-Za-z0-9]+)"
    r":(?P<line>\d+)(?:[-–]\d+)?"
)
def parse_rater(spec):
    match = RATER_RE.fullmatch(spec.strip().lower())
    if not match:
        raise ValueError(
            f"invalid rater {spec!r}; expected sol-<effort>[-bare], "
            "opus|sonnet|haiku|fable-<effort>, "
            "agy-pro-<low|high>-skill, agy-flash37|agy-flash36-<low|medium|high>-skill, "
            "agy-flash35-<low|medium|high>-skill, "
            "oc-glm52|oc-kimik27code[-<low|medium|high>], "
            "oc-grok45|oc-dsv4pro|oc-dsv4flash-<low|medium|high>, "
            "or a Claude/agy -skill variant such as opus-medium-skill"
        )
    model, effort, suffix = match.groups()
    profile = suffix[1:] if suffix in ("-anthropic", "-google") else None
    skill = suffix == "-skill"
    bare = suffix == "-bare"
    if model in _catalog.OPENCODE_MODEL_IDS:
        side = "opencode"
    elif model in _catalog.AGY_EFFORTS:
        side = "agy"
    elif model == "sol":
        side = "codex"
    else:
        side = "claude"
    if side != "opencode" and effort is None:
        raise ValueError(f"invalid rater {spec!r}; effort is required")
    if skill and side not in ("claude", "agy"):
        raise ValueError(f"invalid rater {spec!r}; -skill mode is Claude/agy-only")
    if bare and side != "codex":
        raise ValueError(f"invalid rater {spec!r}; -bare mode is Sol-only")
    if profile and side != "opencode":
        raise ValueError(
            f"invalid rater {spec!r}; -{profile} review profiles are OpenCode-only"
        )
    if side == "opencode" and effort not in (None, *_catalog.OPENCODE_EFFORTS):
        raise ValueError(
            f"invalid rater {spec!r}; OpenCode supports only low, medium, or high effort"
        )
    if model in _catalog.OPENCODE_UNUSABLE_MODELS:
        raise ValueError(
            f"invalid rater {spec!r}; {_catalog.OPENCODE_MODEL_IDS[model]} is measured unusable "
            f"for review ({_catalog.OPENCODE_MODEL_FACTS[model]['note']}) — see review-bench oc-models"
        )
    if model in _catalog.OPENCODE_EFFORT_CEILING and effort is not None:
        ceiling = _catalog.OPENCODE_EFFORT_CEILING[model]
        if ceiling is None or _catalog.OPENCODE_EFFORTS.index(effort) > _catalog.OPENCODE_EFFORTS.index(ceiling):
            allowed = f"use {model}-{ceiling} or {model}" if ceiling else f"use {model}"
            raise ValueError(
                f"invalid rater {spec!r}; {_catalog.OPENCODE_MODEL_IDS[model]} never finished a "
                f"review at {effort} effort ({_catalog.OPENCODE_MODEL_FACTS[model]['note']}) — "
                f"{allowed}"
            )
    if model in _catalog.OPENCODE_EFFORT_REQUIRED_MODELS and effort is None:
        raise ValueError(
            f"invalid rater {spec!r}; {_catalog.OPENCODE_MODEL_IDS[model]} ignores reasoning "
            f"suppression and stalls the gateway, so it needs an explicit budget: "
            f"use {model}-low"
        )
    if model in _catalog.AGY_EFFORTS and effort not in _catalog.AGY_EFFORTS[model]:
        efforts = _catalog.AGY_EFFORTS[model]
        allowed = (
            " or ".join(efforts)
            if len(efforts) == 2
            else f"{', '.join(efforts[:-1])}, or {efforts[-1]}"
        )
        raise ValueError(
            f"invalid rater {spec!r}; {model} supports only {allowed} effort"
        )
    canonical = model
    if effort:
        canonical += f"-{effort}"
    if skill:
        canonical += "-skill"
    if bare:
        canonical += "-bare"
    if profile:
        canonical += f"-{profile}"
    return {"spec": canonical, "model": model, "effort": effort,
            "side": side, "skill": skill, "bare": bare, "profile": profile}


def parse_raters(value):
    specs = [item.strip() for item in value.split(",") if item.strip()]
    if not specs:
        raise ValueError("--raters must contain at least one rater")
    parsed = []
    seen = set()
    for spec in specs:
        match = RATER_REPEAT_RE.fullmatch(spec)
        base, repeat = (match.group(1), int(match.group(2))) if match else (spec, 1)
        rater = parse_rater(base)
        if rater["spec"] in seen:
            raise ValueError("--raters contains duplicates")
        seen.add(rater["spec"])
        for attempt in range(1, repeat + 1):
            instance = dict(rater)
            if attempt > 1:
                instance["spec"] = f"{rater['spec']}#{attempt}"
            parsed.append(instance)
    return parsed


def normalize_legacy_rater(rater):
    rater = RATER_ATTEMPT_RE.sub("", rater)
    # The Gemini flash rater was renamed agy-flash -> agy-flash36 (versioned).
    # Credit legacy persisted rows to the new id so --auto counts them as reviewed;
    # agy-flash35 is unaffected (its next char is a digit, not a dash).
    if rater.startswith("agy-flash-"):
        return "agy-flash36-" + rater[len("agy-flash-"):]
    return rater


RECORDED_RATER_RE = re.compile(
    r"^(.+?)(?:-(low|medium|high|xhigh|max))?(-skill|-bare|-anthropic|-google)?$"
)


def recorded_rater(spec):
    """A saved run's cell, read the way every other corpus reader reads one: leniently.

    A side retired since the run was written no longer parses, and refusing its spec here is
    what strands the whole run from adjudication — the run is already on disk, and nothing
    about recording it asks whether the cell could be launched again.
    """
    family = normalize_legacy_rater(spec)
    try:
        return parse_rater(family)
    except ValueError:
        match = RECORDED_RATER_RE.fullmatch(family)
        # Leniency stops at a spec that is not a cell name at all: re-raised, the caller gets the
        # refusal parse_rater already wrote instead of an AttributeError from the fallback.
        if not match:
            raise
        model, effort, suffix = match.groups()
        return {"spec": family, "model": model, "effort": effort, "side": None,
                "skill": suffix == "-skill", "bare": suffix == "-bare",
                "profile": suffix[1:] if suffix in ("-anthropic", "-google") else None}


def collapse_rater_attempts(raters):
    normalized = [normalize_legacy_rater(rater) for rater in raters]
    counts = Counter(normalized)
    ordered = dict.fromkeys(normalized)
    return [
        f"{rater} x{counts[rater]}" if counts[rater] > 1 else rater
        for rater in ordered
    ]


def rater_family(spec):
    return normalize_legacy_rater(spec) if isinstance(spec, str) else ""


def rater_side(spec):
    """Which pool a cell draws from, for rows recorded before the side was written down.

    Asked of the family, because the instance suffix of a repeated cell is not part of any spec
    the parser knows: unresolved, `oc-kimik3#2` was a cell of no side at all, and the row that
    collapses a whole walled leg into one line let it print beside itself as its own failure.
    """
    try:
        return parse_rater(rater_family(spec))["side"] if spec else None
    except ValueError:
        return None


def cell_runs_skill(rater):
    """The single axis `-bare` marks. Codex cells run the vendor's review skill unless `-bare`
    opts out of it; every other side has to ask for it by name.

    The mark is decided per family, not per family-and-effort: `sol-medium-bare` is the only
    medium Codex cell in the pool, so an effort-scoped rule would drop its mark and leave it
    reading as the skilled run standing next to `sol-low`.
    """
    if rater.get("side") == "codex":
        return not rater.get("bare")
    return bool(rater.get("skill"))


def name_scheme(extra_raters=()):
    """What a pool cell's name has to carry to stay apart from the other pool cells: which
    families run two versions, which run more than one effort, and which run both with and
    without the review skill. Read off the pool ALONE — a pool cell's spelling is the same on
    every surface and in every report, so `opus` is one model wherever it is printed.

    Cells a run holds that no tier can launch — a retired composition, another vendor's model —
    do not enter that reading. They are named against it instead: `extra_raters` that collide
    with a pool cell take on the components that separate them, and a collision that survives
    every component keeps the machine spec, which is unambiguous by construction.
    """
    versions = defaultdict(set)
    efforts = defaultdict(set)
    skills = defaultdict(set)
    for rater in review_pool_raters():
        base, version = _catalog.model_name_parts(rater["model"])
        versions[base].add(version)
        efforts[rater["model"]].add(rater.get("effort"))
        skills[rater["model"]].add(cell_runs_skill(rater))
    scheme = {
        "versions": dict(versions), "efforts": dict(efforts), "skills": dict(skills),
        "overrides": {},
    }
    pool_families = {rater_family(rater["spec"]) for rater in review_pool_raters()}
    taken = {pool_cell_name(rater, scheme) for rater in review_pool_raters()}
    overrides = {}
    newcomers = {
        rater_family(rater["spec"]): rater
        for rater in extra_raters
        if rater_family(rater["spec"]) not in pool_families
    }
    for family, rater in sorted(newcomers.items()):
        for candidate in newcomer_names(rater, scheme):
            if candidate not in taken:
                break
        else:
            candidate = family
        overrides[family] = candidate
        taken.add(candidate)
    scheme["overrides"] = overrides
    return scheme


def review_pool_raters():
    """Every cell any tier can launch. It is the baseline a name is disambiguated against, so a
    cell keeps one spelling across reports instead of changing with what a run happened to hold.
    """
    global _REVIEW_POOL_RATERS
    if _REVIEW_POOL_RATERS is None:
        _REVIEW_POOL_RATERS = [
            rater
            for tier in _catalog.REVIEW_TIERS.values()
            for key in ("cells", "cells_max")
            for cell in tier[key]
            for rater in parse_raters(cell)
        ]
    return _REVIEW_POOL_RATERS


def default_name_scheme():
    global _DEFAULT_NAME_SCHEME
    if _DEFAULT_NAME_SCHEME is None:
        _DEFAULT_NAME_SCHEME = name_scheme()
    return _DEFAULT_NAME_SCHEME


def compose_cell_name(rater, version=False, effort=False, mark=False):
    base, digits = _catalog.model_name_parts(rater["model"])
    name = base + (digits if version else "")
    level = rater.get("effort")
    if level and effort:
        name += f"-{_catalog.SHORT_EFFORT_NAMES.get(level, level)}"
    if mark:
        name += "-skill" if cell_runs_skill(rater) else "-bare"
    if rater.get("profile"):
        name += f"-{rater['profile']}"
    return name


def pool_cell_name(rater, scheme):
    """A cell spelled by what the pool needs to tell it from the other pool cells, and no more."""
    base, _ = _catalog.model_name_parts(rater["model"])
    return compose_cell_name(
        rater,
        version=len(scheme["versions"].get(base, ())) > 1,
        effort=(
            rater.get("side") in ALWAYS_EFFORT_SIDES
            or len(scheme["efforts"].get(rater["model"], ())) > 1
        ),
        # Only the skill-less side of a family that runs both carries a mark: the skilled run is
        # what the family name has always meant on every surface that prints it.
        mark=(
            len(scheme["skills"].get(rater["model"], ())) > 1
            and not cell_runs_skill(rater)
        ),
    )


def newcomer_names(rater, scheme):
    """The spellings an off-pool cell is offered, in order, each one carrying more than the last.
    It starts at the pool's own spelling and adds only what a collision forces, so a cell no tier
    can launch never costs a pool cell the name it has everywhere else.
    """
    base, _ = _catalog.model_name_parts(rater["model"])
    pool_style = pool_cell_name(rater, scheme)
    yield pool_style
    effort = (
        rater.get("side") in ALWAYS_EFFORT_SIDES
        or len(scheme["efforts"].get(rater["model"], ())) > 1
    )
    for flags in ((True, effort, False), (True, True, False), (True, True, True)):
        candidate = compose_cell_name(rater, *flags)
        if candidate != pool_style:
            yield candidate


def short_cell_name(rater, scheme=None):
    """The one spelling of a parsed cell, for every surface a human reads."""
    scheme = default_name_scheme() if scheme is None else scheme
    override = scheme["overrides"].get(rater_family(rater.get("spec") or ""))
    return override or pool_cell_name(rater, scheme)


def human_cell_name(spec, scheme=None):
    family = rater_family(spec)
    scheme = default_name_scheme() if scheme is None else scheme
    if family == _catalog.GEMINI_VERIFIER:
        # The verifier is spelled without an effort, but it runs one, and a cell at that same
        # effort is in the tiers: named off the bare family it would print `gem-flash36` in the
        # verifier row beside `gem-flash36-med` in the cells row of the same report, as two
        # models rather than one doing two jobs. Against the pool and never against the run,
        # because the effort-qualified family is itself a legal skill-less cell: a run holding
        # THAT cell earns it a `-bare` override, which the verifier row would otherwise wear.
        family = f"{family}-{_catalog.GEMINI_VERIFIER_EFFORT}"
        scheme = default_name_scheme()
    try:
        rater = parse_rater(family)
    except ValueError:
        # The verifier chain names models that have no cell spelling, and the report prints
        # those beside cell names.
        if not family:
            return str(spec)
        base, version = _catalog.model_name_parts(family)
        return base + (version if len(scheme["versions"].get(base, ())) > 1 else "")
    return short_cell_name(rater, scheme)


def report_name_scheme(specs):
    """The scheme a report's names are read in: the pool spelled as it always spells itself, plus
    a name for whatever this run holds that no tier can launch — a retired or renamed cell has to
    stand apart from the ones beside it without respelling any of them.
    """
    extra = []
    for spec in specs:
        family = rater_family(spec)
        if not family:
            continue
        try:
            extra.append(parse_rater(family))
        except ValueError:
            continue
    return name_scheme(extra)


