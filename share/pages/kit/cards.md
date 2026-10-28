# cards: numbered cards with image/audio/video and choice/multi/scale/text answers
Numbered cards, each with its pictures, clips or films and a few answers (choice, chips, scale, text)
plus a note; one clip plays at a time, a card's number turns green once it is answered.

## Spec (CONTRACT.md, schema 1)
- **Field kinds:** `choice`, `multi`, `scale` (`min`..`max`) and `text`; `label` is the row's name
  (default: `key`). Every card also has a free `note` field.
- **Options:** `id`, `label`, and `key` (an `event.code`, acting on the card most visible on screen).
- **Done:** every `choice` and `scale` field answered (without any: anything set).
- **Media:** `media[].kind` is `image`, `audio` or `video`, shown with the native element; only one
  clip plays at a time.
- **Numbering:** `n` is the shown number. It is stable and never renumbered when items are added.
- **Per item:** `id` (immutable), `n`, `title`, `text`, `media`, `suggest` (`{field: value}`, shown
  apart, never counted).
- **Common:** `title`, `intro`, `sitting_cap`; any `_` key (e.g. an item's `_expected`) is never served
  and shows in `page state`.
- **Fields written:** each field's `key`, plus `note`.

## Example
```json
{"module": "cards", "schema": 1, "title": "Loop seams, round 3",
 "fields": [{"key": "heard", "kind": "choice",
             "options": [{"id": "0", "label": "не слышу", "key": "Digit1"}, {"id": "1", "label": "слышу"}]},
            {"key": "kind", "kind": "multi", "options": [{"id": "click"}, {"id": "gap"}]},
            {"key": "score", "kind": "scale", "min": 1, "max": 10}],
 "items": [{"id": "c11", "n": 11, "title": "track 3 wrap", "text": "optional context",
            "media": [{"kind": "audio", "src": "/abs/c11.m4a"}], "suggest": {"heard": "1"}}]}
```
