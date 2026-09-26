"""The one renderer of every report block Egor reads in his chat.

A block is a frame word and rows: `(label, value)`, where the value is a line or a list of item
lines. Width, label column, fitting and the number and time words live here and nowhere else;
`bin/report-bus` renders structured bodies through this file and review-bench imports it.
`tests/test_report_frame_guard.sh` fails on any other frame drawn in llm-legs, review-bench or
claude-setup.

CLI: `report_frame.py block < {"word": …, "rows": [[label, value | [items]], …]}` prints the block;
`report_frame.py time <seconds>` prints the time word.
"""

import json
import math
import sys

WIDTH = 56
LABEL_WIDTH = 14
RULE = "="
MORE = "…"
UNKNOWN = "–"
THIN_SPACE = " "
WORD_ROOM = WIDTH - 4


def header(word, width=WIDTH):
    word = fit_word(" ".join(str(word).split()), width - (WIDTH - WORD_ROOM))
    fill = max(2, width - len(word) - 2)
    left = fill // 2
    return f"{RULE * left} {word} {RULE * (fill - left)}"


def end(width=WIDTH):
    return RULE * width


def fit_word(word, room):
    """A frame word cut to `room`: the head segment gives way first, since the ` · ` tail
    (round number, STALE, date) is what tells two blocks apart."""
    if len(word) <= room:
        return word
    parts = word.split(" · ")
    tail = "".join(f" · {part}" for part in parts[1:])
    head_room = room - len(tail)
    if head_room < 2:
        return word[:room - 1].rstrip() + MORE
    return parts[0][:head_room - 1].rstrip() + MORE + tail


def flat(text):
    """One line; runs of spaces stay, leading ones too, since table rows align columns with them."""
    lines = [line.rstrip() for line in str(text).replace("\t", " ").splitlines() if line.strip()]
    return " ".join(lines)


def fit(text, room):
    """One line of at most `room` characters. A path keeps its tail, cut at a `/`; prose keeps
    its head, cut at a word where one is near."""
    text = flat(text)
    if len(text) <= room:
        return text
    if room < 2:
        return MORE[:room]
    head, _, last = text.rpartition(" ")
    prefix = f"{head} " if head else ""
    tail_room = room - len(prefix) - 1
    slash = last[-tail_room:].find("/") if tail_room >= 8 else -1
    if 0 < slash < tail_room - 1:
        return prefix + MORE + last[-tail_room:][slash:]
    cut = text[:room - 1]
    space = cut.rfind(" ")
    if space >= room // 2:
        cut = cut[:space]
    return cut.rstrip(" ·,;:") + MORE


def prose(text, lines=2, more=False, room=WIDTH - LABEL_WIDTH):
    """Prose folded at words into at most `lines` items of the value column. What does not fit,
    or `more` that the caller left out, ends the last item in `…`."""
    items = []
    for word in flat(text).split():
        if items and len(items[-1]) + 1 + len(word) <= room:
            items[-1] += f" {word}"
        else:
            items.append(word)
    if len(items) > lines:
        items = items[:lines - 1] + [fit(" ".join(items[lines - 1:]), room)]
    elif more and items:
        last = items[-1].rstrip(" ·,;:")
        items[-1] = last + MORE if len(last) < room else fit(f"{last} {MORE}", room)
    return [fit(item, room) for item in items]


def time_word(seconds):
    if not isinstance(seconds, (int, float)) or isinstance(seconds, bool) or not math.isfinite(seconds) or seconds < 0:
        return UNKNOWN
    if round(seconds) < 60:
        return f"{round(seconds)}s"
    minutes = seconds / 60
    return f"{minutes:.1f}m" if round(minutes, 1) < 10 else f"{round(minutes)}m"


def count(n):
    text = str(int(n)) if isinstance(n, float) and n.is_integer() else str(n)
    if not text.isdigit():
        return text
    groups = []
    while len(text) > 3:
        groups.insert(0, text[-3:])
        text = text[:-3]
    return THIN_SPACE.join([text, *groups])


def tallies(rows):
    rows = [[str(value) for value in row] for row in rows]
    widths = [max((len(row[column]) for row in rows if len(row) > column), default=0)
              for column in range(max(map(len, rows), default=0))]
    return ["/".join(f"{value:>{widths[column]}}" for column, value in enumerate(row))
            for row in rows]


def text_of(part):
    if isinstance(part, bool) or part is None:
        return str(part or "")
    if isinstance(part, (int, float)):
        return count(part) if float(part).is_integer() and part >= 0 else str(part)
    if isinstance(part, dict) and set(part) == {"seconds"}:
        return time_word(part["seconds"])
    if isinstance(part, (list, tuple)):
        return "".join(text_of(item) for item in part)
    if isinstance(part, str):
        return part
    raise ValueError(f"not a value: {part!r}")


def items_of(value):
    if isinstance(value, (list, tuple)):
        items = [text_of(item) for item in value]
    else:
        items = text_of(value).split("\n")
    return [item for item in map(flat, items) if item]


def row_lines(label, value, width=WIDTH, label_width=LABEL_WIDTH):
    label = f"{label}:" if label else ""
    room = width - label_width
    items = items_of(value)
    if not items:
        return []
    lines = []
    if len(label) >= label_width:
        lines.append(fit(label, width))
        label = ""
    for item in items:
        lines.append(f"{label:<{label_width}}{fit(item, room)}".rstrip())
        label = ""
    return lines


def body_lines(rows, width=WIDTH, label_width=LABEL_WIDTH):
    lines = []
    for label, value in rows:
        lines += row_lines(label, value, width, label_width)
    return lines


def block(word, rows, width=WIDTH):
    return "\n".join([header(word, width), *body_lines(rows, width), end(width)])


def main(argv):
    if len(argv) == 3 and argv[1] == "time":
        try:
            print(time_word(float(argv[2])))
        except ValueError:
            print(UNKNOWN)
        return 0
    if len(argv) == 2 and argv[1] == "block":
        document = json.load(sys.stdin)
        word, rows = document["word"], document["rows"]
        if not isinstance(word, str) or not word.strip() or not isinstance(rows, list):
            raise ValueError("a block is a word and a list of rows")
        print(block(word, [(str(row[0] or ""), row[1]) for row in rows]))
        return 0
    print("usage: report_frame.py block < document | report_frame.py time <seconds>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        print(f"report_frame: {exc}", file=sys.stderr)
        raise SystemExit(2)
