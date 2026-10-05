import json
import sys

WIDTH = 56


def block(word, rows):
    lines = ["== %s %s" % (word, "=" * (WIDTH - len(word) - 4))]
    for label, value in rows:
        lines.append("%-14s%s" % (label, value))
    return "\n".join(lines + ["=" * WIDTH])


if __name__ == "__main__":
    doc = json.load(sys.stdin)
    print(block(doc["word"], doc["rows"]))
