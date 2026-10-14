"""Per-model prices and cache multipliers.

Prices are USD per million tokens, from the Anthropic public API price list.
Egor is on a subscription, so USD here is a common unit for comparing spend
across models, not an invoice. See FINDINGS.md, "Unit".
"""

import datetime as dt
from dataclasses import dataclass


CACHE_READ_MULT = 0.1
CACHE_WRITE_5M_MULT = 1.25
CACHE_WRITE_1H_MULT = 2.0


@dataclass(frozen=True)
class Price:
    input_mtok: float
    output_mtok: float
    intro_input_mtok: float = 0.0
    intro_output_mtok: float = 0.0
    intro_until: str = ""
    cache_read_mult: float = CACHE_READ_MULT
    long_prompt_over: int = 0
    long_input_mtok: float = 0.0
    long_output_mtok: float = 0.0

    def is_long(self, prompt: int | None) -> bool:
        return bool(self.long_prompt_over) and (prompt or 0) > self.long_prompt_over

    def rates(self, day: str, prompt: int | None = None) -> tuple[float, float]:
        if self.is_long(prompt):
            return self.long_input_mtok, self.long_output_mtok
        if self.intro_until and day <= self.intro_until:
            return self.intro_input_mtok, self.intro_output_mtok
        return self.input_mtok, self.output_mtok


# Everything is reported as a multiple of one Sonnet 5 input token at its introductory
# price. Subscriptions are not billed per token, so a dollar figure is not a bill; a
# ratio between models is the part that survives. The base is pinned to the introductory
# rate so the unit keeps its meaning after Sonnet 5 returns to $3 on 2026-09-01 — from
# that day a Sonnet 5 token weighs 1.5 of these units, which is the real change.
S5_BASE_USD_PER_TOKEN = 2.0 / 1_000_000

# llm-legs night_spend resolves a bare alias (`opus`) to its family's first name here: newest first.
PRICES: dict[str, Price] = {
    "claude-fable-5-1": Price(10.0, 50.0, cache_read_mult=0.025),
    "claude-fable-5": Price(10.0, 50.0),
    "claude-mythos-5": Price(10.0, 50.0),
    "claude-mythos-preview": Price(10.0, 50.0),
    "claude-opus-5-5": Price(4.0, 20.0, cache_read_mult=0.05),
    "claude-opus-5": Price(5.0, 25.0),
    "claude-opus-4-8": Price(5.0, 25.0),
    "claude-opus-4-7": Price(5.0, 25.0),
    "claude-opus-4-6": Price(5.0, 25.0),
    "claude-opus-4-5": Price(5.0, 25.0),
    "claude-opus-4-1": Price(15.0, 75.0),
    "claude-sonnet-5-5": Price(2.0, 10.0, cache_read_mult=0.05),
    "claude-sonnet-5": Price(3.0, 15.0, 2.0, 10.0, "2026-08-31"),
    "claude-sonnet-4-6": Price(3.0, 15.0),
    "claude-sonnet-4-5": Price(3.0, 15.0),
    "claude-haiku-5-5": Price(0.1, 0.5, long_prompt_over=100_000, long_input_mtok=0.5, long_output_mtok=2.5),
    "claude-haiku-4-5": Price(1.0, 5.0),
}

OPUS_ANCHOR = "claude-opus-5-5"

# Fast mode runs the same model at premium rates.
FAST_PRICES: dict[str, Price] = {
    "claude-opus-5-5": Price(8.0, 40.0, cache_read_mult=0.05),
    "claude-opus-5": Price(10.0, 50.0),
    "claude-opus-4-8": Price(10.0, 50.0),
}

# Models that are generated locally and never billed.
UNBILLED_MODELS = {"<synthetic>", None, ""}

# A Claude model this build has never priced still has to weigh something, or Anthropic's
# next release lands in the index as free and its spend vanishes from every total while
# `is_billed` keeps calling it billed. Sonnet's list rate is the middle of the family, so an
# unpriced row is wrong by the family's spread rather than by everything it cost.
CLAUDE_FALLBACK = Price(3.0, 15.0)


def canonical_model(model: str | None) -> str:
    """Strip the date suffix so `claude-haiku-4-5-20251001` prices like `claude-haiku-4-5`."""
    if not model:
        return "unknown"
    if model in PRICES:
        return model
    parts = model.split("-")
    while parts:
        candidate = "-".join(parts)
        if candidate in PRICES:
            return candidate
        parts.pop()
    return model


def _price(model: str | None, fast: bool = False) -> Price | None:
    if model in UNBILLED_MODELS:
        return None
    name = canonical_model(model)
    table = FAST_PRICES if fast and name in FAST_PRICES else PRICES
    return table.get(name) or PRICES.get(name) or CLAUDE_FALLBACK


def price_for(
    model: str | None, day: str, fast: bool = False, *, prompt: int | None = None
) -> tuple[float, float]:
    """(input, output) USD per MTok; `prompt` is the request's whole input, for tiered models."""
    price = _price(model, fast)
    return price.rates(day, prompt) if price else (0.0, 0.0)


def cache_read_mult(model: str | None, fast: bool = False) -> float:
    price = _price(model, fast)
    return price.cache_read_mult if price else CACHE_READ_MULT


def tier_prompt(model: str | None, prompt: int | None) -> int:
    """The smallest prompt priced like `prompt`, so a cache keyed on it stays small."""
    price = _price(model)
    return price.long_prompt_over + 1 if price and price.is_long(prompt) else 0


def is_priced_claude_model(model: str | None) -> bool:
    """Whether a price list covers this model, or `CLAUDE_FALLBACK` is standing in for one."""
    return canonical_model(model) in PRICES


def input_cost_usd(
    model: str | None,
    day: str,
    *,
    fresh: int,
    cache_read: int,
    cache_5m: int,
    cache_1h: int,
    fast: bool = False,
    prompt: int | None = None,
) -> float:
    """`prompt` defaults to these tokens, the whole input of one request."""
    if prompt is None:
        prompt = fresh + cache_read + cache_5m + cache_1h
    rate, _ = price_for(model, day, fast, prompt=prompt)
    units = effective_input_tokens(
        fresh=fresh, cache_read=cache_read, cache_5m=cache_5m, cache_1h=cache_1h, model=model, fast=fast
    )
    return units * rate / 1_000_000.0


def output_cost_usd(
    model: str | None, day: str, output_tokens: int, fast: bool = False, *, prompt: int | None = None
) -> float:
    _, rate = price_for(model, day, fast, prompt=prompt)
    return output_tokens * rate / 1_000_000.0


def effective_input_tokens(
    *,
    fresh: int,
    cache_read: int,
    cache_5m: int,
    cache_1h: int,
    model: str | None = None,
    fast: bool = False,
) -> float:
    """Price-weighted input tokens, in units of one fresh input token of the same model.

    This is the quantity an earlier pass called "effective input tokens", corrected
    for the 1-hour cache-write multiplier (2.0x, not 1.25x).
    """
    return (
        fresh
        + cache_read * cache_read_mult(model, fast)
        + cache_5m * CACHE_WRITE_5M_MULT
        + cache_1h * CACHE_WRITE_1H_MULT
    )


def claude_costs(
    model: str | None,
    day: str,
    *,
    fresh: int,
    cache_read: int,
    cache_5m: int,
    cache_1h: int,
    output: int,
    fast: bool = False,
) -> tuple[float, float, float]:
    """(eff_input, cost_in, cost_out) for one Claude request, the shape of `vendor_costs`."""
    tokens = dict(fresh=fresh, cache_read=cache_read, cache_5m=cache_5m, cache_1h=cache_1h)
    return (
        effective_input_tokens(**tokens, model=model, fast=fast),
        input_cost_usd(model, day, **tokens, fast=fast),
        output_cost_usd(model, day, output, fast, prompt=sum(tokens.values())),
    )


def units(usd: float) -> float:
    """USD at public API rates, restated in Sonnet 5 input tokens."""
    return usd / S5_BASE_USD_PER_TOKEN


def weight(model: str | None, day: str | None = None) -> float:
    """How many Sonnet 5 input tokens one input token of this model is worth.

    Defaulting the day to a fixed one pinned Sonnet 5 at its introductory 1x forever; the
    weight of a model is a property of when it is asked about.
    """
    rate, _ = price_for(model, day or dt.date.today().isoformat())
    return rate / (S5_BASE_USD_PER_TOKEN * 1_000_000)


def is_billed(model: str | None) -> bool:
    return model not in UNBILLED_MODELS


@dataclass(frozen=True)
class VendorWeight:
    """What one token of a non-Claude model is worth in Sonnet 5 input tokens.

    `cache_read` and `cache_write` are multipliers on `input`, the shape the Claude side
    uses. How each number was derived from the published per-token rates, and the day
    those were read, is in FINDINGS.md — the rates themselves stay out of the code.
    """

    input: float
    output: float
    cache_read: float
    cache_write: float


VENDOR_WEIGHTS: dict[str, dict[str, VendorWeight]] = {
    "codex": {
        "gpt-5.6-sol": VendorWeight(2.0, 10.0, 0.1, 0.0),
        "gpt-5.5": VendorWeight(2.5, 15.0, 0.1, 0.0),
    },
    "grok": {
        "grok-4.5-build": VendorWeight(1.0, 3.0, 0.15, 0.0),
        "grok-4.5-build-free": VendorWeight(0.0, 0.0, 0.0, 0.0),
        "grok-4.6-build": VendorWeight(0.17, 0.51, 0.25, 0.0),
    },
    "gemini": {
        "gemini-3.6-flash": VendorWeight(0.15, 1.25, 0.25, 0.0),
        "gemini-3.7-flash": VendorWeight(0.15, 1.25, 0.25, 0.0),
        "gemini-3.7-flash-control": VendorWeight(0.15, 1.25, 0.25, 0.0),
        "gemini-3.7-flash-safety-le": VendorWeight(0.15, 1.25, 0.25, 0.0),
        "gemini-3p7-flash-exp-c": VendorWeight(0.15, 1.25, 0.25, 0.0),
        "gemini-3.7-flash-exp-b": VendorWeight(0.15, 1.25, 0.25, 0.0),
        "gemini-3-flash-medium-control": VendorWeight(0.15, 1.25, 0.25, 0.0),
        "gemini-3-flash-a": VendorWeight(0.15, 1.25, 0.25, 0.0),
        "gemini-default": VendorWeight(0.15, 1.25, 0.25, 0.0),
        "gemini-pro-default": VendorWeight(1.0, 6.0, 0.25, 0.0),
        "gemini-3.6-pro": VendorWeight(1.0, 6.0, 0.25, 0.0),
    },
}

# A model this build has never priced still has to weigh something, or a vendor's spend
# reads as free, so each fallback is a model of the tier the vendor's unpriced rows have
# actually turned out to be. For codex and grok that is also the most-used model; gemini's
# is deliberately the pro tier rather than the far more common flash, because the gemini
# rows this index cannot price are pro variants (`gemini-3.1-pro-low`) and flash would
# under-price them by the family's whole 6.7x spread.
VENDOR_FALLBACK: dict[str, VendorWeight] = {
    "codex": VENDOR_WEIGHTS["codex"]["gpt-5.6-sol"],
    "grok": VENDOR_WEIGHTS["grok"]["grok-4.6-build"],
    "gemini": VENDOR_WEIGHTS["gemini"]["gemini-3.6-pro"],
}

_UNKNOWN_VENDOR = VendorWeight(1.0, 5.0, CACHE_READ_MULT, CACHE_WRITE_5M_MULT)


def vendor_weight(vendor: str, model: str | None) -> VendorWeight:
    table = VENDOR_WEIGHTS.get(vendor, {})
    return table.get(model or "") or VENDOR_FALLBACK.get(vendor, _UNKNOWN_VENDOR)


# `claudegpt` drives Claude Code with OpenAI models on a Codex subscription: the requests land in
# Claude transcripts, but they draw on the Codex pool and never on a Claude account's.
ROUTED_MODELS = {"anthropic.ccr.": "codex"}


def routed_vendor(model: str | None) -> str | None:
    """The vendor whose pool a Claude-transcript request really draws on, when not Claude's."""
    for prefix, vendor in ROUTED_MODELS.items():
        if (model or "").startswith(prefix):
            return vendor
    return None


def is_priced_vendor_model(vendor: str, model: str | None) -> bool:
    return (model or "") in VENDOR_WEIGHTS.get(vendor, {})


def vendor_costs(
    vendor: str,
    model: str | None,
    *,
    fresh: int,
    cache_read: int,
    cache_write: int,
    output: int,
) -> tuple[float, float, float]:
    """(eff_input, cost_in, cost_out) for one non-Claude request.

    `eff_input` keeps its Claude meaning — input tokens of this model weighted by what
    each kind of them costs — so the model weight enters only when that becomes a price.
    Reasoning tokens are part of `output` in every vendor feed read so far and are priced
    there, not added on top.
    """
    weights = vendor_weight(vendor, model)
    eff_input = fresh + cache_read * weights.cache_read + cache_write * weights.cache_write
    return (
        eff_input,
        eff_input * weights.input * S5_BASE_USD_PER_TOKEN,
        output * weights.output * S5_BASE_USD_PER_TOKEN,
    )
