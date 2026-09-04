"""Whether a chat stopped on a question to Egor rather than on an answer.

A chat whose last human-visible turn is the assistant asking for his word — an ok, a go-ahead,
a plain question mark — is waiting on him and looks in a listing exactly like one that finished.
That difference is what `bin/chats` marks, and it is read the way every other reader of these
transcripts reads them: backward from the end, since a transcript is mostly tool results.

Consumers: `bin/chats`.
"""

import json
import os
import re

# An ask is what the CLOSING paragraph says, and only in its imperative shapes: an answer
# REPORTING that it committed and pushed uses the same verbs as one asking permission to, so a
# lexicon matched over the whole message marks half the corpus. Measured on his own listing.
ASK = re.compile(
    r"\bскажи\b|(?<!когда )(?<!как только )\bскажешь\b|\bподтверд(?:и|ишь)\b"
    r"|\bвыбери\b|\bреши\b|\bпиши\b|\bнапиши\b"
    r"|\bдай\s+(?:слово|добро|команду|го|ок)\b"
    r"|тво(?:им|его|ему|ё|е)\s+слов|нужн\w*\s+тво\w*\s+слов"
    r"|жд[уёе]\w*\s+(?:тво|от\s+тебя|слов|ответ|сигнал|решени|«)"
    r"|как(?:ой|ое|ие)\s+вариант|твой\s+выбор"
    r"|let me know|your call|say the word|which option|shall i\b|want me to\b|\bconfirm\b",
    re.IGNORECASE,
)
# A question mark that ends a sentence, not one inside a glob or a query string.
QUESTION = re.compile(r"\?[!\"'»”’)\]]*(?:\s|$)")
# What a `?` must never be counted in: a command he was handed to run, a quoted tool or hook
# line, a reminder the harness wrote. Tags go first, since their body can hold fences of its own.
TAGGED = re.compile(r"<([a-zA-Z][\w-]*)(?:\s[^>]*)?>[\s\S]*?</\1>")
FENCE = re.compile(r"```[\s\S]*?(?:```|\Z)")
SPAN = re.compile(r"`[^`\n]*`")
QUOTED = re.compile(r"^[ \t]*(?:>|\||│)[^\n]*$", re.M)
BLOCKS = re.compile(r"\n[ \t]*\n")
CLOSING_CHARS = 1200
# The same ladder chat-find's own tail reader widens through: the answer is in the last entries
# of the file, and a transcript whose tail holds nothing but tool output needs the next step up.
TAIL_WINDOWS = (256 * 1024, 4 * 1024 * 1024, 32 * 1024 * 1024)
MAX_LINE = 4 * 1024 * 1024
SYSTEM_REMINDER_CLOSE = "</system-reminder>"


def message_text(message):
    content = message.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "\n".join(
        block.get("text", "") for block in content
        if isinstance(block, dict) and block.get("type") == "text"
        and isinstance(block.get("text"), str)
    )


def tool_result_only(message):
    content = message.get("content")
    return (isinstance(content, list) and bool(content) and all(
        isinstance(block, dict) and block.get("type") == "tool_result" for block in content
    ))


def system_reminder_only(text):
    """A reminder the harness injected under the user's role, with nothing of his after it.

    It arrives as a user entry and would otherwise read as him having answered.
    """
    stripped = text.strip()
    if not stripped.startswith("<") or SYSTEM_REMINDER_CLOSE not in stripped:
        return False
    return stripped.endswith(SYSTEM_REMINDER_CLOSE)


def closing_words(text):
    """The paragraph the message ENDS on, with code, quoted lines and harness tags gone."""
    clean = QUOTED.sub("", SPAN.sub(" ", FENCE.sub("\n\n", TAGGED.sub("\n\n", text))))
    blocks = [block for block in BLOCKS.split(clean) if block.strip()]
    return blocks[-1][-CLOSING_CHARS:] if blocks else ""


def asks(text):
    closing = closing_words(text)
    return bool(QUESTION.search(closing) or ASK.search(closing))


def turn_verdict(entry):
    """`True`/`False` where this entry IS the last human-visible turn, `None` where it is not one.

    A sidechain entry is a subagent's turn with its own supervisor, not a turn with Egor, and an
    assistant message carrying only tool calls is the middle of a turn rather than its end.
    """
    kind = entry.get("type")
    if kind not in ("user", "assistant") or entry.get("isSidechain"):
        return None
    message = entry.get("message") or {}
    # The stub an API error leaves behind: it says nothing about who spoke last.
    if message.get("model") == "<synthetic>":
        return None
    if kind == "user":
        if tool_result_only(message) or entry.get("isMeta"):
            return None
        text = message_text(message)
        if not text.strip() or system_reminder_only(text):
            return None
        return False
    text = message_text(message)
    if not text.strip():
        return None
    return asks(text)


def awaiting_answer(path, size=None):
    """Whether this transcript's last human-visible turn is the assistant asking Egor."""
    try:
        size = os.path.getsize(path) if size is None else size
    except OSError:
        return False
    for window in TAIL_WINDOWS:
        verdict = _tail_verdict(path, size, window)
        if verdict is not None or window >= size:
            return bool(verdict)
    return False


def _tail_verdict(path, size, window):
    try:
        with open(path, "rb") as handle:
            handle.seek(max(0, size - window))
            chunk = handle.read(window)
    except OSError:
        return False
    lines = chunk.split(b"\n")
    if window < size:
        # The first line of a mid-file window is half a record; parsing it would be luck.
        lines = lines[1:]
    for raw in reversed(lines):
        if not raw.startswith(b"{") or len(raw) > MAX_LINE:
            continue
        try:
            entry = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        verdict = turn_verdict(entry)
        if verdict is not None:
            return verdict
    return None
