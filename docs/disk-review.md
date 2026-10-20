# Disk review

A by-hand pass over the system disk and Work, opened from Doctors → System → Disk space → "Review disk with Claude…"
(`bin/disk-review`). It finds what is big, old or forgotten, shows Egor one page with a checkbox per item, and moves
what he ticks to the Trash. The automatic side is elsewhere: `share/log-stores.json` sweeps registered stores daily and
under pressure, and the menu's "Emergency cleanup" runs `bin/log-sweep --emergency`. This chat handles what no store covers.

Talk to Egor in Russian, informal «ты», briefly. The page is in Russian; this doc and any code stay English.

## Hard rules

- Nothing leaves except through `share/disk_review/apply.py`, after Egor says «готово» in the chat. It uses
  `/usr/bin/trash` only. Never `rm`, never `~/.local/bin/trash` (that one deletes chats), never empty the Trash.
- Never edit a repository, a store registry or an app's settings files. A setting Egor changes in an app is an item
  with action `ui:<App>`; after apply, do it through the app's UI only if he ticked it.
- A store `share/log-stores.json` registers is the sweep's: leave it off the page (`bin/log-sweep --dry-run --json`
  lists what they hold).
- Never show a chat or session id. Every item's owner is a chat NAME (below) or an app name.

## Steps

1. `python3 -B share/disk_review/scan.py wait` — the launcher started the scan; it takes 10–30 minutes. Meanwhile read
   `~/.local/share/disk-review/decisions.json` (earlier answers by path) and the system doctor's
   `~/.cache/system-doctor/latest.json` (`log_stores`, the free-space and dir-growth facts).
2. Find candidates from the maps:
   - `scan.py kids ~ -n 25`, `scan.py kids /Volumes/Work -n 25`, then down into whatever is big;
   - `scan.py top '<regex>'` for patterns (`node_modules$`, `\.venv$`, `DerivedData`, `/Caches$`);
   - `~/.cache/disk-review/scan/big.tsv` (files over 200 MB: size, mtime, path) for installers, dumps, media, models;
   - `scan.py apps` for apps unused for months.
3. Verify each claim before it reaches the page. A duplicate is compared file by file; a "dump" is checked against
   the live database; anything that looks like data is grepped for references (scripts, configs, launchd plists)
   before it is called unused. When unsure what a folder is, say so on the page rather than guess.
4. Owner: the chat that made it. `chat-find <words from the path>` and `~/.claude/projects/<cwd with / as ->/` find
   it; `chat-name <id>` turns an id into its name. An owner chat with a real message in the last 30 days means the
   work is live: the item goes only to "big" with tag «в работе», never to the tickable list.
5. Write `items.json` in your scratchpad (schema in `share/disk_review/page.py`) and run
   `python3 -B share/disk_review/page.py <items.json>`: it measures every path, applies the ledger and opens the page
   in Dia (an open page reloads in place). Tick by default only what is clearly junk. `why` says in one plain Russian
   sentence what it is and why it can go; `last` is the last real use.
6. Tell Egor in two or three lines: the total on offer per disk and the two or three biggest calls. Answer his
   questions; on a correction, fix `items.json` and rerun `page.py`.
7. On «готово»: `python3 -B share/disk_review/apply.py` (`--dry-run` first if anything is unusual). Report what went
   to the Trash, what was skipped as busy and why, and that emptying the Trash is his. A root-owned leftover makes
   macOS ask for his password once (one Finder delete).

## What usually turns up

Installers (`.dmg`, `.pkg`, `.zip` in Downloads), old app support folders of apps that are gone, Python envs and
`node_modules` of finished experiments, re-downloadable models (HuggingFace, Ollama, LM Studio), iOS device support,
old simulators (`xcrun simctl delete unavailable` is an item with action `ui:Xcode`), photo and video renders already
exported, archived Telegram media. A folder that refills itself is not an item: hand it to the store registry (tell
Egor which store it belongs in; a chat working on llm-legs adds it).
