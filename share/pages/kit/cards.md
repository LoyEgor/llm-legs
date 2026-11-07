# cards: numbered cards with image/audio/video and choice/multi/scale/text answers; versions of one picture go side by side as `compare` media, never glued into one image
Numbered cards, each with its pictures, clips or films and a few answers (choice, chips, scale, text)
plus a note; one clip plays at a time, a card's number turns green once it is answered.

## Spec (CONTRACT.md, schema 1)
- **Field kinds:** `choice`, `multi`, `scale` (`min`..`max`) and `text`; `label` is the row's name
  (default: `key`). Every card also has a free `note` field.
- **Options:** `id`, `label`, and `key` (an `event.code`, acting on the card most visible on screen).
- **Done:** every `choice` and `scale` field answered (without any: anything set).
- **Media:** `media[].kind` is `image`, `audio` or `video`, shown with the native element; only one
  clip plays at a time.
- **Compare media:** `{"kind": "compare", "images": [{"src", "caption"}, …], "caption"}` shows versions of
  one picture (an original and its edits) in a row, a column each; a click opens them all full screen side
  by side under one zoom and pan, each drawn at the first one's width, a click there toggling 1:1. A
  collage glued into one file shrinks every version and cannot be zoomed apart, so it is never needed.
- **Media caption:** `media[].caption`, a line under that medium (default none); `media_columns`
  (top level, default 1) lays each card's media out in that many columns, e.g. 2 for before/after.
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
