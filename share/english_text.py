"""Whether text a model reads is English: the one rule behind bin/cyrillic-share, the hooks that
call it and review-bench's own input checks.

Model-to-model text is English; Russian may appear only as code (a closed fence or backticks) or as
a trigger phrase in a closed «...» of at most QUOTE_WORDS_MAX words. Everything else counts.
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
QUOTED = re.compile(r"«([^«»]*)»")
QUOTE_WORDS_MAX = 6
ALLOWED = "Russian only as code in backticks or a trigger phrase of up to 6 words in «…»"


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


def _trigger_phrase(match):
    return " " if len(cyrillic_words(match.group(1))) <= QUOTE_WORDS_MAX else match.group(0)


def prose(text):
    for pattern in (FENCE, INLINE):
        text = pattern.sub(" ", text)
    return QUOTED.sub(_trigger_phrase, text)


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
