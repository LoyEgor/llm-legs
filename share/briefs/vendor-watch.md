## Vendor watch — monthly, updater direction

Find what the vendors shipped for the web apps and CLIs we drive that we could use and do not use yet, and
open it as integration work. `bin/vendor-fingerprint` sees only CLI facets; this job reads what vendors announce.

1. What we drive: `share/image-caps/*.json` (`.scripts` names each route), `share/image-caps/README.md`,
   `docs/image-vendors.md`, the routes of `bin/media-run`. What reached us already: earlier rows,
   `grep -h '^+' $(grep -l '^### watch' ~/.cache/vendor-cli-update/events/*.diff)`. A feature already
   integrated, already a row, or not usable by a script driving that surface is no row.
2. Read each source since the newest earlier row (none: the last 45 days). Official pages only; a page that
   will not load is read through web search of its URL, and named under UNREACHED in the report.

| vendor key | surfaces | source |
|---|---|---|
| codex | ChatGPT web images, Codex | https://help.openai.com/en/articles/6825453-chatgpt-release-notes (direct fetch 403: search it) · https://learn.chatgpt.com/docs/changelog |
| gemini | Gemini app, Flow video and image, Flow Music, AI Studio speech, agy | https://gemini.google/release-notes/ · https://blog.google/technology/google-labs/rss/ (Flow, Flow Music) · https://ai.google.dev/gemini-api/docs/changelog (TTS, Veo, Imagen) · https://antigravity.google/docs/changelog |
| grok | grok.com, Grok Imagine, Grok Build | https://docs.x.ai/docs/release-notes (month headings; grok.com has no changelog: search `site:x.ai/news`) |
| claude | Claude apps, Claude Code | https://support.claude.com/en/articles/12138966-release-notes · https://github.com/anthropics/claude-code/releases.atom |
| elevenlabs | ElevenLabs | https://elevenlabs.io/docs/changelog |

3. A region-locked feature (not offered where Egor's accounts are) is no row: name it under REGION in the
   report. Never propose a VPN, a proxy or a country change.
4. One rows file per vendor key with news, one line per feature:
   `<surface> · <feature> · <source URL> · <entry date YYYY-MM-DD> · proposal: <route or file to change, what it gains us>`.
   Then `bin/vendor-fingerprint watch <vendor key> <rows file>` per file: it opens an event the next night's
   `vendor-fingerprint request --night` hands to that vendor's integration worker (`docs/vendor-release.md`),
   who decides each row. A source that moved: fix its URL in this brief (`share/briefs/vendor-watch.md`) and commit.
5. Report, outcome first, ≤ 200 words: the event ids with their row counts, per source its newest dated entry,
   UNREACHED, REGION.
