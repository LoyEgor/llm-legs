#!/usr/bin/env python3
"""Git merge driver `merge_ledger.py %O %A %B %P` for share/*-ledger.json: a three-way merge by row `id` (in `rows`
and in every other top-level list whose entries all carry a unique string `id`, such as `blind_spots`) and by
top-level key, writing the result into %A in the file's own layout. A side that changed an entry the other left
alone wins; two different changes, or a deletion against a change, become git conflict markers around that entry
and exit 1. A file it cannot read as a ledger gets git's own line merge, so nothing is lost, and still exits 1
so a malformed ledger (landed conflict markers) stops the merge instead of riding on."""
import json
import subprocess
import sys

MISSING = object()
ROWS = "\0rows merged by id"
LABELS = ("ours", "base", "theirs")


def load(path, base=False):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if base and not text.strip():
        return {}, text
    doc = json.loads(text)
    rows = doc.get("rows", []) if isinstance(doc, dict) else None
    if not isinstance(rows, list) or not all(isinstance(row, dict) and isinstance(row.get("id"), str) for row in rows):
        raise ValueError("not a ledger")
    if len({row["id"] for row in rows}) != len(rows):
        raise ValueError("duplicate row id")
    return doc, text


def canon(value):
    return MISSING if value is MISSING else json.dumps(value, sort_keys=True, ensure_ascii=False)


def merge(base, ours, theirs):
    """`[(key, value)]` in ours' order then theirs-only keys in theirs' order; a conflict's value is the
    `(ours, theirs)` pair, either MISSING where that side deleted the entry."""
    merged = []
    for key in list(ours) + [key for key in theirs if key not in ours]:
        o, a, b = (canon(side.get(key, MISSING)) for side in (base, ours, theirs))
        value_a, value_b = ours.get(key, MISSING), theirs.get(key, MISSING)
        if a == b or b == o:
            pick = value_a
        elif a == o:
            pick = value_b
        else:
            merged.append((key, (value_a, value_b), True))
            continue
        if pick is not MISSING:
            merged.append((key, pick, False))
    return merged


def container(entries, member, opening, closing, level, indent):
    if not entries:
        return opening + closing
    pad = " " * indent * (level + 1)
    lines = []
    for at, (key, value, conflict) in enumerate(entries):
        comma = "," if at < len(entries) - 1 else ""
        if not conflict:
            lines.append(pad + member(key, value) + comma)
            continue
        lines.append("<" * 7 + " " + LABELS[0])
        lines += [pad + member(key, value[0]) + comma] if value[0] is not MISSING else []
        lines.append("=" * 7)
        lines += [pad + member(key, value[1]) + comma] if value[1] is not MISSING else []
        lines.append(">" * 7 + " " + LABELS[2])
    return opening + "\n" + "\n".join(lines) + "\n" + " " * indent * level + closing


def nested(value, level, indent):
    return json.dumps(value, ensure_ascii=False, indent=indent).replace("\n", "\n" + " " * indent * level)


def id_list(value):
    return (isinstance(value, list) and all(isinstance(entry, dict) and isinstance(entry.get("id"), str) for entry in value)
            and len({entry["id"] for entry in value}) == len(value))


def render(base, ours, theirs, indent):
    sides = (base, ours, theirs)
    lists = {key for side in sides for key in side
             if all(id_list(other[key]) for other in sides if key in other)}
    merged_lists = {key: merge(*({entry["id"]: entry for entry in side.get(key, [])} for side in sides))
                    for key in lists}
    top = merge(*({key: ROWS + key if key in lists else value for key, value in side.items()} for side in sides))

    def member(key, value):
        if key in lists and value == ROWS + key:
            return json.dumps(key, ensure_ascii=False) + ": " + container(
                merged_lists[key], lambda _, entry: nested(entry, 2, indent), "[", "]", 1, indent)
        return json.dumps(key, ensure_ascii=False) + ": " + nested(value, 1, indent)

    conflicts = any(conflict for _, _, conflict in top + [e for entries in merged_lists.values() for e in entries])
    return container(top, member, "{", "}", 0, indent) + "\n", conflicts


def main(base_path, ours_path, theirs_path):
    try:
        base, _ = load(base_path, base=True)
        ours, text = load(ours_path)
        theirs, _ = load(theirs_path)
    except (OSError, ValueError):
        subprocess.run(["git", "merge-file", "-L", LABELS[0], "-L", LABELS[1], "-L", LABELS[2],
                        ours_path, base_path, theirs_path])
        return 1
    second = text.split("\n", 2)[1] if text.count("\n") > 1 else ""
    indent = len(second) - len(second.lstrip(" ")) or 2
    output, conflicts = render(base, ours, theirs, indent)
    with open(ours_path, "w", encoding="utf-8") as handle:
        handle.write(output)
    return 1 if conflicts else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:4]))
