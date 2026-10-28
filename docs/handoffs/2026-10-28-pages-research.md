# Local pages: research and design draft (2026-10-28)

Status: DESIGN, nothing built. Source chat: «Артефакты Claude AI и HTML-страницы» (claude-setup).

## Why
Chats keep building vote/compare pages from scratch, sometimes as claude.ai artifacts. Egor has three
Claude accounts and an artifact opens only under the publishing chat's account. Proven pages get
forgotten: the Vector Magic chat had an ideal compare page (`vote.tpl.html`) and wrote a new one on
10-28; the pixel-forge chat rebuilt the same thing as a claude.ai artifact the same day.

## Egor's requirements (2026-10-28)
- A chat must not even try an artifact: prevent, don't catch late (no double work).
- No mandatory Submit: every click is stored at once; the chat reads partial votes and changed choices
  whenever it wants. He often votes on 2-10 items and stops; nothing may be lost.
- Reusable functional modules, extended in one place, never rewritten; design matters little.
- A chat knows its own pages (after compaction too) and reuses them; he can browse all pages.
- Zero context cost for chats that make no pages.

## Facts found
- `enableArtifact: false` (user settings; also `CLAUDE_CODE_DISABLE_ARTIFACT=1`, or a deny rule on
  Artifact) turns the Artifact tool off — the tool and its long description leave the model's context.
  Off in user/--settings/managed wins; project/local settings can only turn it off (2.1.312 schema).
- `hooks/word-gate.sh` refuses nothing: the «артефакт» word family only records a grant.
- He votes on the iPad too (pages were capped to iPad width, lazy loading for iPad memory).
- The live path that worked (listen-bench, oversharp): a local server, the whole state POSTed on each
  change (300 ms debounce), atomic tmp→rename write, the chat reads the JSON any time.

## Design draft
- **One permanent server** (launchd KeepAlive, fixed port → stable URLs): static files with HTTP/1.1,
  Range/206, no-cache, connection errors ignored; per-page store with per-item merge + revision (a stale
  tab must not overwrite the chat), append-only change log; SSE "page changed → reload".
- **A page = a folder** under one durable root: `spec.json` (what to show/ask), `state.json` (live marks),
  `log.jsonl` (every change in order). Media referenced in place, not copied. Never /tmp.
- **Modules in a tracked kit** (`share/pages/kit/`): the page HTML is a fixed loader; a chat writes only
  `spec.json`. A missing feature is added to the module (reviewed, in git), never forked.
- **CLI `page`**: `new <module> --spec`, `list` (this chat / all), `state <page>` (compact summary,
  `--since` = what changed since the chat last read), `open <page>`, `help` (modules and their spec).
- **Registry**: page → chat (session), project, module, created; index page at the server root grouped
  by chat name.
- **Discovery**: artifacts off; one global CLAUDE.md line ("a page for Egor → `page help`, never hand
  HTML") — no hook can foresee the model's intent; a PreToolUse gate on writing `*.html` pages outside
  the kit as the backstop; after compaction a SessionStart(compact) hook lists the chat's pages, only
  if it has any.

## Seed modules (from proven pages)
1. `compare` ← logo-vectorizer-bench `tools/vote.tpl.html` + `mkvote.py`: N synced loupes (original + A + B),
   shared pan/zoom anchored at the pointer, preview with clipped view boxes, hotspot jumps, fit, pointer
   capture fixes; + pixel-forge extras (both_bad/unsure, per-side tags, pixel-size badge, auto-advance,
   preload, always-pixelated option).
2. `cards` ← listen-bench `defects.py`/`page.py`: stable numbered cards growing by batch, fields
   choice/multi/scale/text/time, progress + save status, one clip plays at a time.
3. media players ← listen-bench + `share/video_glitch.py`: audio excerpt («минута»), A/B from the same
   position, sample-exact Web Audio loop, video frame-step/speeds/timeline marks.
4. `pairs` ← video likeness `rate` / listen-bench `pairs.html`: ←/→/↓/↑, resume, progress.
Later, when a chat needs them: slider compare (`upscale/compare.html`), brush/region mask (oversharp),
diff review popover (transcriptions judge), question queue with a daily cap (video_glitch).

## Simplicity rules (his words behind each are in the reports)
Every click saves and stays changeable, with a visible saved state; stable short ids, never renumbered;
compared items side by side with their numbers, original one key away; one question per screen in his
words, no internal names; offer "can't tell"/skip and do not ask near-ties; cap a sitting (~20 items);
a free-text note is always enough; one interface per task kind; the page outlives the chat.

---

# Report: Vector Magic compare pages

Partially done: I identified both pages and reconstructed the good one. Its leveldb vote reader (`lsread.py`) is lost, so I rebuilt its logic from the transcript; nothing was run or edited. Changed files: none. Tests: none (read-only research).

## 1. Page inventory (all are local `file://` pages opened with `open -a Dia`, unless marked artifact)

| Page | Exists | When | What | Size |
|---|---|---|---|---|
| `/Volumes/Work/Projects/logo-vectorizer-bench/results/lanes/coord/tools/vote.tpl.html` (**the good template**) + generator `…/tools/mkvote.py` (+ `…/coord/s/mkvote76.py`, `mkvote78.py` wrappers) | y | final form 2026-10-08 19:04 | blind A/B, original + A + B loupes | 10 KB / 2.6 KB |
| `…/bench/report/judge-vote-c78.html` (**previous-to-last page, the good one**) | y | opened 2026-10-19 23:15, CSV received 2026-10-20 16:26 | 59 panels, champ77 vs champ78, blind | 32 KB |
| Same template, other runs: `report/judge-vote-{c46-vm,c46-mix,c46-disputes,c46-vm-p006-p015,c48-vm,c48-reveal,c46v73,c73v76,c76v77,grad-cal}.html` | y | 10-08 to 10-17 | apart from the generator's placeholders, identical to the template | 10–48 KB |
| `report/judge-exam.html`, `judge-lowres.html`, `judge-disputes.html`, `judge-questions.html` | y | 09-30 to 10-07 | earlier static-panel versions (no loupes; disputes added a question box) | 30–66 KB |
| `…/coord/s/vmpage.tpl.html` + `vmpage.py` → `report/vm98-aigrid4.html` (**the last page**) | y | 2026-10-28 12:30 | unblinded overview: input / ours / VM grid with judge filters | 5.4 KB / 47 KB |
| `scratchpad/report/index.html`: published as a **claude.ai artifact** three times (10-02 01:14, 02:56, 03:28; one URL `DEBfiHSvRkqKaSKgZN2RRH`), deleted 09:47 | **n** | 10-02 | champ23→31 report | — |
| `scratchpad/judge-tpl.html`, `scratchpad/lsread.py` | **n** (scratchpad cleaned) | — | — | — |

The other pages shown from 10-23 to 10-24 (`scratchpad/stars90/index.html`, `s446/index.html`, `torn.html`, PNG sheets) were throwaway view-only pages.

**How the good and last pages differ:** `vm98-aigrid4.html` has no votes, comments, localStorage, keyboard, loupes or synced view. It is a grid with click-to-lightbox and judge-verdict filters. The chat read `mkvote.py` at 12:25 and 12:28 and still wrote a new template, because it framed the request as an "overview" rather than a vote. Neither template is in git: `report/` and `results/` are in `.gitignore`.

## 2. Data path
- **Storage:** votes live only in the page's `localStorage`, under `KEY="vote-<tag>"` = `{panel:{vote,note}}`, plus `KEY-cur` for the current position. They are saved on every click and keystroke (`vote.tpl.html:57,104-105`). There is no server.
- **On submit:** the "Сохранить CSV" button writes a Blob download, `~/Downloads/judge-<tag>-votes.csv` (`:112-114`). Egor pastes that path into chat. This is how every round ended, c78 included.
- **Live (the "pulled almost immediately" Egor remembers):** on 2026-10-08 12:46 the chat read his 22 partial votes straight from Dia's `~/Library/Application Support/Dia/User Data/Profile 8/Local Storage/leveldb`. It decoded `.ldb` with libsnappy via ctypes, and on 10-11 parsed `.log` records with `lsread.py <log> vote-c48-vm`. Its report to Egor: «забрал прямо из браузера, экспортировать ничего не нужно». The script lived in the scratchpad and is gone.

## 3. UI features that worked (`vote.tpl.html`)
- **Wide-screen layout:** a sticky header with a progress count and a per-panel strip (`:8-13,61-62`). A small top panel preview sits next to the vote side (`:15-16`). Below are three equal loupes, original · A · B, spanning the full width and filling to the bottom of the window (`:25,68-69,95`). They are resized on window resize at the same zoom factor (`:103`).
- **One shared view state `L{cx,cy,z}` for all three loupes:** dragging or zooming any loupe moves all of them. This is the "mirrored cursor" Egor describes (`:71-81,86-89`).
- **Wheel and pinch zoom anchored at the pointer**, faster with ctrlKey (`:77-79`). Zoom is clamped to 0.05–16× (`:78,96`). Images switch to pixelated rendering at ≥3× (`:89`).
- **Preview rectangles:** the blue boxes on the top preview show where the loupe is looking in each of the three cells. They are clipped to the image bounds and hidden when out of view (`:91-94`). This is the "leaving the bounds tracked correctly" behaviour.
- **Click the preview** to centre the loupe there (`:99-102`).
- **Jumps:** "место 1/2" go to the two largest-difference crops computed by `mkvote.py` (`hot()`), keys 1 and 2. "целиком" fits the whole image (key 0). Double-click resets (`:76,84-85,97-98,110`).
- **Keyboard (`:109-111`):**

  | Key | Action |
  |---|---|
  | A / B / T | vote A / B / tie |
  | ф / и / е | same votes on the Russian layout |
  | ← / → | previous / next panel |

  Keys are ignored while typing in the note or when a modifier is held.
- **Per-panel question/context box `q`** (`:21,65`). It was used for reveal pages ("A = champ46 … Твой голос: B — «…»") and dispute pages (judge argument plus pixel check).
- **Generator (`mkvote.py`):**
  - `--panels` and `--q` give a subset its own page, storage key and CSV.
  - It merges several folders into one page.
  - It writes relative `../` image paths, and the chat checked them for missing files before opening the page.

## 4. Bugs hit and fixes
1. Static crops only: Egor wanted to pan himself (10-07). Fixed by turning the crops into draggable live loupes.
2. Six small loupes in two rows were too small (10-08). Fixed with one row of three that resizes with the window.
3. **Drag stuck after releasing the mouse outside the window** (10-08). Fixed with `setPointerCapture`, `lostpointercapture`, window-level pointerup/cancel/**blur**, and a check of `e.buttons&1` on move (`:74-82`).
4. Image ghost-drag and text selection. Fixed with `draggable=false`, `-webkit-user-drag:none`, `pointer-events:none` on the img, and `user-select:none` (`:26,28`).
5. Dia dropped the `#q=…` URL hash, so a subset page opened all 20 panels (10-07). Fixed by generating a separate file per subset.
6. Votes survive a regenerated page because the localStorage key is stable («Старую вкладку закрой. Голоса… сохранились»). Each page needs its own key, since all `file://` pages share one origin.
7. Lost tooling: on 10-19 the chat was searching the scratchpad for lost helper scripts (`mkvote`, `lanejudge`, …), and `lsread.py` vanished the same way. The fix belongs in the registry design: templates and readers must live in a durable, tracked home.
8. Egor lost pages: «страницу «Ди» случайно закрыл» (10-19), «Я ее пропустил» (10-09). There is a need to re-open a page by name.

## 5. Egor's words
- 2026-10-02: «Мне артефакт не подойдет, удали его, запусти HTML, ну как ты раньше делал.»
- 2026-10-07: «дай мне возможность, драгом, зумленую версию подрагать … чтобы я не только вырезанные тобой части видел»
- 2026-10-08: «сделать не шесть блоков, а три блока, и они по горизонтали растягиваются»
- 2026-10-08: «если я тяну и попадаю за край … бывает, что не отпускается»
- 2026-10-08: «лишний текст можно поубирать с объяснениями. Мне он особо не нужен.»
- 2026-10-07: «мне без, я никогда не вижу, логотип, мне сложно ответить» (when asked questions without the page)
- 2026-09-30: «Там микроскопические отличия … мое время, оно же тоже имеет ценность.»
- 2026-10-28: «Но только без перебора. У меня нет очень много времени на … фидбэк»

## 6. Module candidates
- **compare-loupes:** N synced viewports, a preview with clipped boxes, hotspot jumps and fit. Spec per item: `w,h`, `src[]`, `labels[]`, `hotspots[[x,y]]`, an optional preview image with a cell geometry. Today the geometry is hard-coded (1552×542, 3×512 at a 520 stride, y+22: `:91-101`); that must become data.
- **vote:** options, keymap with layout aliases, per-item note, progress strip, auto-advance.
- **state store:** per-change persistence plus a live channel to the chat, replacing the Downloads CSV and leveldb scraping. The chat should be able to read partial votes at any time; keep CSV export as a fallback.
- **context box:** per-item question, reveal or dispute text.
- **overview grid:** the vmpage-style filter grid as a separate read-only module.
- **page registry:** title → file, storage key, creation time, so the chat re-opens its own page.

## 7. What "compare" must expose for the pixel-art chat
- **Per item:** `id`, `title`, `original` (path), `variants[{label, src, meta}]` with N≥2. Blind mode hides the labels and keeps a key (abpanels-style A/B swap). Also `w,h` or natural size, optional `hotspots`, optional `q` text, and optional per-variant `meta` such as pixel scale or dimensions.
- **View:** shared pan and zoom, a pixelated rendering threshold (pixel art wants it always on), fit/1:1, and a preview with view boxes.
- **Vote options:** configurable, defaulting to `A`, `B`, `tie`. Pixel-art also uses `both_bad`, `unsure`, and per-side tag chips; all of these should be options/tags in the spec.
- **Keyboard:** option keys plus Russian-layout aliases, ←/→ to navigate, 1..k for hotspots, 0 for fit. Ignore keys while the note has focus or a modifier is held.
- **Output:** live `{id:{choice,note,tags,at}}`, readable mid-session.

**What the pixel-art page lacks** (`…/calib/page/index.html`, 16 KB): it stores votes in the claude.ai artifact `window.claude.use("db")`, so it is account-bound and shows "offline" as a local file. It has:
- no separate original/variant viewports: one pre-composited webp sheet, with click-to-1:1 inside a scroll box;
- no synced pan or zoom;
- no hotspot jumps;
- no Russian-layout keys;
- no export fallback.

Its note is saved only on blur, and only after a vote. It does have useful extras: per-side defect tags, `both_bad`/`unsure`, a pixel-size badge, auto-advance to the next unvoted item, and next-image preload.

**Not confirmed:** I could not find `scratchpad/judge-tpl.html` or `scratchpad/report/index.html` on disk, and found no trace of the former in the files I checked. The transcript is the only source for `lsread.py`. The worktree was not checked out; I touched no tree state.

MD-PROPOSAL: none.

# Report: Audio and video voting pages

Done: I mined all three chats and every page file they used is still on disk. Nothing was edited, created or run against a live server.

The second chat (`da82a98e`, «создвавали склейку аудио») is not separate work. It is a `/branch` of `9709db43`, taken on 2026-10-22 at 19:54, and holds that chat only up to 17:21. So all audio material comes from `9709db43`.

## 1. Page inventory
All audio pages are in `/Volumes/Work/Projects/listen-bench` and all exist. They are written by Python generators and served by `serve.py` on port 8797.

| Page | Generator | Compared | Size |
|---|---|---|---|
| `mark.html` | `page.py` | 28 tracks (22 required): background fit 1–10, voice, drums, lead, build, notes | 70 KB |
| `pairs.html` | `pairs_page.py` | 20 blind A/B pairs of one deck's takes on 3 axes (A / ≈ / B) | 37 KB |
| `defects.html` | `defects.py page()` | 29 made splice defects, 12 s clips with the defect at 6 s | 32 KB |
| `jumps.html` | `defects.py jumps` | 11 clips, round 2 | 15 KB |
| `loops.html` | `defects.py loops()` | **the splice/loop voting page**: 41 wrap clips (last 6 s → first 6 s), "heard?" 0/1/2 plus kind chips plus a note | 45 KB |
| `mood.html` | `mood.py` | 14 takes rated 1–5 per part, with marked break points | 12 KB |
| `storm.html`, `startup*.html` | `blind.py` | blind vendor rounds, 1–5 per axis | ~8 KB each |
| `yura-loop`, `loop5`, `loop12`, `remix5`, `card5` | — | listen-only loop players, no votes | 4–7 KB each |

- The marks land in `dataset/<set>-marks.json`. The hidden key (source, tool prediction) is in `dataset/<set>-set.json`.
- The 10-23 pages (`storm`, `startup*`, `yura-loop`, `loop5`, `remix5`) came from a chat I could not find. I grepped transcripts modified since 10-23 and none matched.
- **Video:** `/Volumes/Work/Projects/llm-legs/share/video_glitch.py` (34 KB) holds the page inline (`PAGE`, lines ~409–575) plus its server. You start it with `bin/video-glitch label`. Its data is `share/video-glitch/{clips,flags,labels}.jsonl`: 127 clips, and 103 label rows covering 29 clips.

## 2. Data path
Every page saves live, on each change. None has a Submit button.

- **Audio:** the page keeps one state object `S` keyed by card number.
  - Every change writes it to localStorage and, after a 300 ms pause, POSTs the whole object to `/<set>-marks` (`defects.py:242`).
  - `serve.py` writes it to `dataset/<set>-marks.json` via tmp + rename. It also accepts any `/<set>-marks` name.
  - On load the page GETs the server copy and falls back to localStorage if that is empty (`defects.py:249`).
  - The chat simply reads the JSON when Egor says «я проголосовал».
- **Video:** the page POSTs `/api/label` after a 500 ms pause (`video_glitch.py:548`).
  - The server validates the body (`clean_label`, :307) and appends a row to `labels.jsonl`; the newest row per clip wins.
  - `/api/state` recomputes the question queue on every load.

## 3. UI features that worked
- **Numbered cards:** the number turns green when the card is done, and a sticky header shows "готово N из M" or a save-failure message (`defects.py:216-240`).
- **Card numbering across batches:** `loops.html` is one page that grows by 6 held-out cards per round (11–17, 18–23, …, 36–41). Numbers stay stable, so old marks keep their keys.
  - Each batch's predictions are committed before he marks it (`LOOP_V5`/`V6`/`V7`, `defects.py:368-404`).
  - The page is blind: the source and the tool's verdict live only in `loop-set.json`.
- **One clip plays at a time:** starting a clip pauses all others (a capture-phase `play` listener, `defects.py:248`).
- **«▶ минута» button:** plays 0:00–0:30, then 1:15–1:45, then stops (`page.py:86-91`). It was added when Egor said a full listen was too long.
- **A/B switch from the same position:** carries `currentTime` over to the other take and waits for `loadedmetadata` if needed (`pairs.html:119-121`). It sits next to «минута A» and «минута B».
- **Sample-exact loop playback:** `AudioBufferSourceNode`, `loop=true`, `loopEnd` set from the exact length, plus a lap counter ("круг N, m:ss из m:ss") (`yura-loop.html` script). `<audio loop>` adds a gap.
- **Break marking (mood):** «✂ перелом здесь» stamps the playhead and splits the ratings into "Часть 1/2"; clicking a break removes it.
  - A mark within 3 s of the start, the end or another break is rejected (`mood.html:85`).
- **Video player:** muted and looping, with a timeline bar showing judge flags and his defects; clicking the bar seeks (`video_glitch.py:536-545`).
  - Frame step uses the clip's fps (`step`, :552). Speeds are 1×/½×/¼×.
  - Verdicts are ✓ / ~ / ✗. «＋ глюк здесь» stamps a defect with kind chips, «⇥ до сюда» to set its end, and words (`addDefect`, :556).
  - Keys: space, ←/→, 1/2/3, G/п, N/т; keys are ignored while typing and Esc leaves the field (:566). Both layouts work.
- **Question queue (video):**
  - Ranked by how much an answer settles (`ask_for`, :270): accepted film flagged > known-bad take nobody flagged > flag on an unjudged take.
  - Sibling takes are pushed down. At most `SITTING = 20` questions a day (:43), with a "сегодня" counter (:490).
  - Opening a clip pre-seeks 0.5 s before the first flag (:512).
- **Merged judge flags:** flags whose times overlap become one group, so he answers once (`flag_groups`, :253).
- **Every card has a free-text note.** In both pages it is optional.

## 4. Bugs hit and fixes
1. **Seeking jumped back to 0:00.** Python's `http.server` ignores Range requests.
   - Fixed with 206 answers in `serve.py` `do_GET` and in `video_glitch.py send_clip` (:357).
   - The logo decks hit the same bug (arbostar-logo 70b789e). There it was worked around by loading the whole film as a blob first.
   - The server must also ignore `ConnectionError` when a clip switch drops a range request (:340).
2. **The chat's own test POST erased two of Egor's real marks.** They were restored by hand (10-19 11:45). Tests must never write to the live store.
3. **A stale tab overwrote the chat's edits.** When the chat marked labels for him («Можешь отметить за меня?»), the page would re-POST its old copy. The chat had to say «Обнови страницу (F5)… иначе она перезапишет». This is the same "whole object, last writer wins" risk in both designs.
4. **Port taken:** port 8765 was held by the arbostar `serve.py`. Fixed with a free-port fallback (`cmd_label`, :396), but that changes the URL. Separately, «Address already in use» on 8797 just meant the server was already up.
5. **A page changed under an open tab:** the chat had to tell him to reload each time.
6. **Video layout:** the timeline bar collapsed (fixed with `main>*{flex:none}`), and autoplay rejection was handled with `v.play().catch(()=>{})` in three places.
7. **Too many questions:** 127 clips were cut to 20 a sitting. The loop round was cut from 27 clips to 11.
8. **The prepared clips themselves clicked:** every clip had an audible click at 6 s. `seams.py` was fixed to read files to their container length (2334405, "find silent gaps", then recut). Clip preparation must be sample-exact.
9. **Axis wording confused him:** «динамичнее» and «ровнее» read as opposites, so the smoothness row was dropped and the hints clarified (a650c8e, 9c26121).

## 5. Egor's words
- 2026-10-19: «мне очень много мелодий слушать, и, может быть, я могу вас послушать по минуте, не слушать целиком?»
- 2026-10-21: «Я проголосовал. Можешь посмотреть, получили, получились ли данные?»
- 2026-10-21: «А ты уверен, что мне надо второй раз голосовать?… это очень много времени я на это все потратил.»
- 2026-10-20: «я прочитал… динамичное - это больше движение… А равнее - это меньше резких скачков… как будто бы одно противоположно другому.»
- 2026-10-22: «в первом треке он до 32 секунд один… а после совершенно другие [оценки]… Как с этим быть, как это оценивать?»
- 2026-10-22: «я максимум проголосую там, 20 клипов… чтобы я просто не ревьювил очевидные баги, где сомнений нету.»
- 2026-10-22: «я не отметил брак это или не брак. Это брак. Можешь отметить за меня?»
- 2026-10-22: «Для меня это полубрак, полунорма… у меня там ответ может скакать.» The answer was "~ терпимо", which counts neither as a hit nor as a miss.

## 6. Module candidates
- **Store server:** static files with Range support, GET/POST `/<set>-marks`, atomic write, append-only history.
  - Add a revision number or per-item merge, so a stale tab cannot overwrite the chat.
  - Add a "page changed, reload" push.
  - Spec: set name, folder, port taken from the registry.
- **Card list:** stable numbering that grows by batch, a done rule per card, a progress/save header, notes, one clip playing at a time.
  - Spec: `items[{n, media, hidden_key}]` and `fields[{key, kind: choice|multi|scale|text|time, options, required}]`.
- **Clip player variants:**
  - audio excerpt ("minute" segments);
  - A/B from the same position;
  - sample-exact Web Audio loop with `loopEnd` and a lap counter;
  - video with frame step, speeds and a marker timeline.
  - Spec: segments, fps, loop end.
- **Time marks:** "mark here" with a range end, kind chips and severity (video `defects[]`, mood `breaks[]`).
- **Question queue:** a priority function, a daily cap, a "today" counter, and pre-seek to the point in question.
- **Prediction/key file:** the hidden source and tool prediction, committed before marks, so the blind check stays honest.

## Tree state
- **claude-setup:** `M local-config/links.tsv` and untracked `local-config/home/.local/libexec/ipad-mic-refresh`.
- **listen-bench:** `M dataset/mood-marks.json` and untracked `dataset/audio/.DS_Store`.

None of these are mine; all were left in place.

# Report: Other voting chats and local page infrastructure

Done: all five chats and their page files are mined, and the seven listed projects are scanned for vote servers. I changed no files. The shared checkout already had changes that aren't mine (`M local-config/links.tsv`, untracked `local-config/home/.local/libexec/ipad-mic-refresh`); I left them alone.

## 1. Page inventory
| Page | Exists | Chat | Compared | Size |
|---|---|---|---|---|
| `/Users/egorloy/Arbostar/arbostar-logo/tools/serve.py` (site server, port 8765) | y | logo | serves `site/`; POST only to a whitelist | 93 lines |
| `…/arbostar-logo/site/index.html` (hub) | y | logo | links to the decks and logo grids; no voting | 16 KB |
| `…/site/oversharp/index.html` + `marks.json` | y | logo | each film: verdict `пережат`/`норм`, plus a brush to paint where he sees oversharp | 110 KB (+769 KB marks) |
| `…/site/oversharp/fix/index.html` | y | logo | up to 6 states of one film (cleaned / 720p / …); he answered by voice, no voting on the page | 26 KB |
| `…/site/oversharp/rank/`, `takes/` | y | logo | ranked films, duplicate takes | 53 KB / 17 KB |
| `…/site/upscale/index.html`, `compare.html`, `v1.html` | y | upscaler | enhancer before/after; any two numbered variants side by side | 19 / 12 / 11 KB |
| `…/site/pool/index.html` | y | logo | all marks with the LLM judges' scores | 411 KB |
| `/Volumes/Work/Projects/video/alona/R7-A/assets/gen/stills/r9-likeness/rate{,-hard,-hard2,-hard3}/` | y | video | pairwise "which face looks more like her" | ~5.7 KB each |
| `/Volumes/Work/Projects/video/research/likeness/ihor/rate/{index.html,server.py}` | y | video | same, for a second person (Ihor) | 5.7 KB + 635 B |
| `…/research/likeness/metrics-view/index.html` | y | video | read-only face-metrics view; only view state in localStorage | 10 KB |
| `/Volumes/Work/Projects/transcriptions-gpt/transcriber/judge_last.py` (`render_page` :5497, `LastHandler` :5888) on top of `reference_judge.py` (`JudgeHandler` :1093) | y | transcription | one take: judge diff, a minor/critical/taste mark per change unit, edit/accept | 6454 + 1331 lines |
| dark-adapt `scratchpad/compare.html`, `dwdemo/index.html` | **n** (the /tmp scratchpad was wiped) | dark-adapt | rows "загрузка / раньше / станет" | — |
| `/Volumes/Work/Projects/logo-dark-adapt/pages/{votes,bg-removal,annotate}/*.ts` | y | earlier August chat | ✓/★/✗ per variant, with bad reasons | 18 / 23 / 15 KB |

Other infrastructure from the scan:
- **listen-bench** (`serve.py` + `mark.html`, `pairs.html`, `defects.html`, `mood.html`, `jumps.html`, `loops.html`): one generic store, where any `/<set>-marks` path is read and written as `dataset/<set>-marks.json` (`serve.py:20`). It uses an atomic tmp→replace write and Range requests for audio. The logo chat's 22-melody vote ran here.
- **llm-legs** `share/video_glitch.py label`: each change is appended to `labels.jsonl` (POST `/api/label`, 500 ms debounce). The page has timeline defect marks, frame stepping and playback-rate buttons.
- **logo-vectorizer-bench** `bench/gallery.py`: localStorage plus an "Экспорт разметки" download.
- **pixel-forge** `viewer/`: no vote path.

## 2. Data path
Five ways votes have reached the chat:
- **Local HTTP server, whole state POSTed on every change, debounced 300 ms** (oversharp `index.html:602`, listen-bench pages). The chat reads the JSON file at any time. This is the live path that worked.
- **Per-answer POST** (likeness `index.html` `pick()` → `answers.json`). It resumes where he stopped by GETting `answers.json`.
- **Append-only jsonl** (video_glitch), so the chat sees each change in order.
- **Submit button** (dark-adapt `votes.ts:569 send()` → `localhost:5198`, with a clipboard fallback). The receiver isn't in the repo, so it was ad hoc. Transcription judge: marks stay local ("unsent") until Accept/Save, then each later click calls `amendMarks` (`judge_last.py:5030`).
- **Voice/text only.** On the oversharp fix page and in the dark-adapt and upscaler chats he described what he saw in words.

## 3. UI features that worked
- **Keys act on the card most visible on screen.** `seen()` in `oversharp/fix/index.html`: 1–9 pick a state, ←/→ cycle, Space holds, Z zooms, Esc resets. He asked for this himself.
- **Switching states keeps the playback time** (`pick()` waits for `seeked`). `align()` lines up every state on a held frame.
- **Zoom levels fit → 1:1 → 2×**, centred on the click, with drag to pan; the zoom survives state switches (`levels/step/apply`).
- **iPad memory.** Films load lazily through an IntersectionObserver, and films two screens away are unloaded (`far` observer).
- **Left/right slider compare of any two numbered variants**, with the number shown on each half (`upscale/compare.html` `show()`). The spec is inline: `S=[{key,title,items:[{num,label,src,thumb}]}]`.
- **Pair voting:** ←/→/↓/↑ (left / right / same / "neither"), Backspace goes back, F toggles the full frame, a progress bar, and it resumes from saved answers (likeness).
- **Brush mask over a film:** `[`/`]` resize the brush, there is an eraser, the mask is stored as a PNG data URL with the time `t` (oversharp).
- **Save status:** `сохранено`/`не сохранилось` flash. Listen-bench also keeps a localStorage copy if the server is down.
- **Transcription judge:** a popover on the inline diff to mark minor/critical/taste. The vote count only counts marks that differ from the judge (`votedNote/overrides`). Status shows "saved hh:mm". It has a per-run token header and a loopback-only + Host check (`reference_judge.py:1115-1131`).

## 4. Bugs and fixes
- **`python -m http.server` dropped pictures** (connection resets, broken thumbnails). Fixed by `serve.py`: HTTP/1.1, a queue of 512, Range requests, `Cache-Control: no-cache`.
- **Seeking failed without 206 responses** (audio jumped back to 0:00). Fixed in listen-bench `serve.py:33`.
- **Brightness jumped between states.** The cleaned film carried a different colour-space tag from the source. Fixed in the shared encoder, which now keeps the source's tag.
- **On the iPad the picture didn't shrink to the screen.** The pages now cap width at the browser's.
- **Item numbers moved after every update.** He asked for stable ids (A/B).
- **The server was dead when he came back to vote.** "Можешь поднять еще раз сервер?"; it came back on a new port (8765→8766→8767→8769).
- **Scratchpad pages in /tmp vanished.**
- **Transcription page confusion:** the same text appeared in two items, labels like "17, 86" meant nothing to him, it was unclear who said what, and he couldn't go back to earlier items. Votes were also locked until Accept. Re-picking the LLM's own value counted as his vote; it now counts only when it differs. Two different interfaces existed for the same task (09-22).
- **Pages named things with internal labels** ("now / keep / plate") and spread the rows to compare far apart (dark-adapt 09-28).

## 5. Egor's words
1. 2026-10-22 «А пока мне кажется, что это перебор с, суперсложным голосованием.»
2. 2026-10-06 «я проголосовал, но что-то было опять супер сложное. Сильно не уверен в этом больше, чем в предыдущие разы.»
3. 2026-10-05 «Там было суперсложно. Я прям сильно не уверен, что мои ответы не плавали.»
4. 2026-10-26 «Просто не сдвигать их, потому что мне сложно ориентироваться после каждого нового апдейта - другой номер.»
5. 2026-08-31 «Можно ли кнопку не убирать, чтобы я мог поменять мнение?»
6. 2026-09-01 «как-то невнятно видно что проголосовано и учтен результат. Я не вижу по ui»
7. 2026-09-28 «Давай проще, куда смотреть, потому что ты же там все по-другому назвал совершенно.»
8. 2026-10-20 «не до, после, а прям писать номер, какой был, какой с какой, с каким я сравниваю.»

## 6. Module candidates (and their spec)
- **Store server:** generic `/<set>-marks` GET/POST plus an append-only log, atomic writes, Range, no-cache, HTTP/1.1. Combines listen-bench `serve.py`, arbostar `serve.py` and video_glitch. Spec: set name and the directory.
- **State switcher:** spec `cards:[{id, states:[{label, src, kind:video|image|audio}]}]`, plus optional zoom levels. Source: `oversharp/fix`.
- **Slider compare:** spec `sections:[{title, items:[{num, label, src, thumb}]}]`. Source: `upscale/compare.html`.
- **Pairwise vote:** spec `refs[]`, `pairs:[{id, a, b}]`, `options: L/R/same/none/skip`. Source: likeness `rate`.
- **Verdict + comment per card:** spec `options[]` and `comment: bool`.
- **Region marking:** brush or point with a time `t`, on image or video.
- **Diff review with a popover mark:** spec `base`, `final`, `units[]`, `marks[]`, `machine_value`.
- **Shared shell:** status line ("saved hh:mm · N voted"), visible-card keys, lazy loading with memory release, stable ids, phone/iPad width.

## 7. What made voting "too complex": rules
1. **Don't ask a question whose answer you can't act on yet.** The oversharp per-film texture spots were cut because no fix existed to use them.
2. **Don't force a choice between near-identical items.** The likeness "hard" sets drifted (he agreed with himself on 3 of 4 repeated pairs). Offer "can't tell" and skip, and screen out near-ties by metric first.
3. **One question per screen,** in his words, with fixed short ids. No internal names, no renumbering.
4. **The items being compared sit next to each other,** each labelled with its number, and the original is always one key away.
5. **Every click saves at once, and he can always change it.** Show the saved state; count only what he actually changed.
6. **Context he needs is shown in plain form,** e.g. who said what and in which order; no unexplained numbers.
7. **One interface per kind of task,** reused across chats.
8. **The page outlives the chat:** a persistent server on a stable URL, never /tmp.
9. **A free-text or voice comment is always enough.** Structured marks are optional.

Not confirmed: the receiver on `localhost:5198` for the dark-adapt pages (not in the repo, and its chat isn't in scope). I didn't trace the 22-melody vote to its exact `mark.html` submission, only to listen-bench's server.
