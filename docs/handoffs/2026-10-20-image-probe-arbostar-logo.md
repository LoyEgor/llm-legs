# Hand-off: arbostar-logo's own image-crop command

Status: open
To: «Логотип CRM для арбористов» (/Users/egorloy/Arbostar/arbostar-logo)

This repository (Speed row `adhoc/image-probe`, 200 calls/day in 64 sessions, 53 of 58 sampled calls
here; median 0.2 s, 272 B out). Most are PIL/ffmpeg crop+resize+print-size to look at a detail (zoom a feet region, tile a
tall shot, vstack two crops), the rest mean RGB or Laplacian sharpness over video frames. Lever: `tools/zoom.py <img>
x,y,w,h [--w N] [-o out]` (printing `out WxH` only), named in `tools/README.md` § Showing and judging where the script
starts; frame sharpness stays `r17/bin/sharp.py`. `logocheck.py` forbids pixel metrics on renders, so look, never score.
Done when `share/tool_mining.py --calls` shows it instead of the scripts.
