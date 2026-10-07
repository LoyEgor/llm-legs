"""A chat transcript reduced to what a reader needs to spot odd behaviour: what was asked, said and
done, what failed, and where time went. Tool outputs are dropped except failures."""
import datetime
import json
import os
import re

import chat_names

REMINDER_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
USER_MAX, SAID_MAX, TOOL_MAX, ERROR_MAX, HOOK_MAX = 1500, 500, 160, 300, 200
GAP_S = 300
LONG_TURN_MS = 600000


def clip(text, limit):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def clock(stamp):
    try:
        return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def tool_summary(block):
    data = block.get("input") or {}
    for key in ("command", "file_path", "pattern", "description", "prompt", "query", "url"):
        if data.get(key):
            return "%s %s" % (block.get("name"), clip(data[key], TOOL_MAX))
    return "%s %s" % (block.get("name"), clip(json.dumps(data, ensure_ascii=False), TOOL_MAX))


def result_text(block):
    content = block.get("content")
    if isinstance(content, list):
        content = " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return content or ""


def entry_lines(row, repeats):
    kind = row.get("type")
    message = row.get("message") or {}
    content = message.get("content")
    if kind == "user" and not row.get("isMeta"):
        if isinstance(content, str):
            text = REMINDER_RE.sub("", content).strip()
            return ["U: " + clip(text, USER_MAX)] if text else []
        lines = []
        for block in content or ():
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text":
                text = REMINDER_RE.sub("", block.get("text", "")).strip()
                if text:
                    lines.append("U: " + clip(text, USER_MAX))
            elif block.get("type") == "tool_result" and block.get("is_error"):
                lines.append("E: " + clip(result_text(block), ERROR_MAX))
        return lines
    if kind == "assistant":
        lines = []
        for block in content or ():
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and block.get("text", "").strip():
                lines.append("A: " + clip(block["text"], SAID_MAX))
            elif block.get("type") == "tool_use":
                lines.append("T: " + tool_summary(block))
        return lines
    if kind == "attachment":
        item = row.get("attachment") or {}
        if item.get("type") == "queued_command" and item.get("prompt"):
            return ["U: " + clip(item["prompt"], USER_MAX)]
        if item.get("type") == "hook_success" and (item.get("stderr") or "").strip():
            line = "H: %s stderr %s" % (item.get("hookName"), clip(item["stderr"], HOOK_MAX))
        elif item.get("type") in ("hook_blocking_error", "hook_non_blocking_error", "hook_error_during_execution"):
            line = "H: %s %s %s" % (item.get("hookName"), item["type"], clip(item.get("content") or item.get("stderr") or "", HOOK_MAX))
        elif item.get("type") == "hook_system_message":
            line = "H: %s says %s" % (item.get("hookName"), clip(item.get("content") or "", HOOK_MAX))
        else:
            return []
        repeats[line] = repeats.get(line, 0) + 1
        return [line] if repeats[line] == 1 else []
    if kind == "system":
        if row.get("subtype") == "turn_duration" and (row.get("durationMs") or 0) >= LONG_TURN_MS:
            return ["D: turn took %d min" % (row["durationMs"] // 60000)]
        if row.get("subtype") == "compact_boundary":
            return ["D: context compacted"]
    return []


def skeleton(path, since=None, launchers=None, store=None):
    """(header, lines) for one transcript; entries before `since` (epoch seconds) are skipped."""
    lines, repeats, last, first, meta = [], {}, None, None, {}
    titles = {"custom-title": None, "ai-title": None}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            try:
                row = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            for key in ("cwd", "entrypoint", "gitBranch", "sessionId"):
                if row.get(key) and key not in meta:
                    meta[key] = row[key]
            title = row.get("customTitle") if row.get("type") == "custom-title" else row.get("aiTitle")
            if row.get("type") in titles and isinstance(title, str) and title.strip():
                titles[row["type"]] = title
            at = clock(row.get("timestamp"))
            if since is not None and (at is None or at < since):
                continue
            produced = entry_lines(row, repeats)
            if not produced:
                continue
            if at is not None:
                if last is not None and at - last >= GAP_S:
                    lines.append("D: %d min gap" % ((at - last) // 60))
                last = at
                first = first if first is not None else at
                stamp = datetime.datetime.fromtimestamp(at).strftime("%H:%M")
                produced = ["%s %s" % (stamp, line) for line in produced]
            lines.extend(produced)
    tail = ["H×%d: %s" % (count, line[3:]) for line, count in repeats.items() if count > 1]
    headless = meta.get("entrypoint") == chat_names.HEADLESS_VIA
    session = meta.get("sessionId") or os.path.splitext(os.path.basename(path))[0]
    name = chat_names.chat_label(session, titles["custom-title"] or titles["ai-title"], headless, launchers, store)
    header = "### %s · %s · %s" % (name, "worker" if headless else meta.get("entrypoint") or "?",
                                  chat_names.project_label(meta.get("cwd")))
    return header, lines + tail
