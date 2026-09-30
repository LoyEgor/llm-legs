"""Whether text a model reads is English: the one rule behind bin/cyrillic-share, the hooks that
call it and review-bench's own input checks.

Model-to-model text is English. Russian in code (a closed fence or backticks) or in a closed quote
of at most QUOTE_WORDS_MAX words, QUOTED_WORDS_MAX in all, is not counted, and neither are paths and
URLs; what is left may still hold up to SHARE_MAX percent of the letters — a pasted label or error
line is data, and a deny over it costs a whole rewrite.
"""
import re

CYRILLIC_RANGES = (
    (0x0400, 0x04FF),
    (0x0500, 0x052F),
    (0x1C80, 0x1C8F),
    (0x2DE0, 0x2DFF),
    (0xA640, 0xA69F),
)

FENCE = re.compile(r"```.*?```", re.DOTALL)
INLINE = re.compile(r"`[^`\n]*`")
# Typographic quotes only: a straight quote also delimits every string literal, and a Russian prompt
# inside agent("...") or codex exec "..." is exactly the text this rule exists to catch.
QUOTED = re.compile(r"«([^«»]*)»|“([^“”]*)”|„([^„“”]*)[“”]")
# A Latin path or URL pads the letter count of a Russian brief under SHARE_MAX.
PATHISH = re.compile(r"\S*/\S*")
QUOTE_WORDS_MAX = 6
# A Russian brief cut into short quotes is still a Russian brief.
QUOTED_WORDS_MAX = 24
SHARE_MAX = 15
ALLOWED = ("Russian only as code in backticks, phrases of up to 6 words (24 in all) in «…» or “…”, "
           "or stray words under 15% of the letters")


def is_cyrillic(ch):
    point = ord(ch)
    return any(low <= point <= high for low, high in CYRILLIC_RANGES)


def cyrillic_words(text):
    words, run = [], ""
    for ch in text + " ":
        if ch.isalpha() and is_cyrillic(ch):
            run += ch
            continue
        if run:
            words.append(run)
        run = ""
    return words


def prose(text):
    for pattern in (FENCE, INLINE, PATHISH):
        text = pattern.sub(" ", text)
    budget = QUOTED_WORDS_MAX

    def trigger_phrase(match):
        nonlocal budget
        phrase = next(group for group in match.groups() if group is not None)
        words = len(cyrillic_words(phrase))
        if words > QUOTE_WORDS_MAX or words > budget:
            return match.group(0)
        budget -= words
        return " "

    return QUOTED.sub(trigger_phrase, text)


def russian_words(text):
    return cyrillic_words(prose(text))


def cyrillic_share(text):
    """(percent rounded up, letters): a single Russian word in a long English text is already 1."""
    text = prose(text)
    letters = sum(1 for ch in text if ch.isalpha())
    if not letters:
        return 0, 0
    cyrillic = sum(len(word) for word in cyrillic_words(text))
    return -(-cyrillic * 100 // letters), letters
