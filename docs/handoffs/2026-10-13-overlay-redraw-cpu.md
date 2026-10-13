# Hand-off: transcriptions-gpt overlay CPU (cpu:process/transcriptions-gpt/transcriber/overlay.py)

Status: open
To: next night, a fixer with a transcriptions-gpt worktree

22.2 CPU-min/day. `transcriber/overlay.py` runs a 60 FPS `NSTimer` (`tick:`) only while the pill
is shown, and `IndicatorView.advance` ends with `setNeedsDisplay_(True)` on every tick, so each
frame is a full Python `drawRect_`, also when nothing on it moved (a frozen timer, a settled pill).

Cost: one file, ~10 lines: redraw only when a drawn quantity changed. Measure CPU per shown second
on a live take first. Loss: none Egor sees if frames stay identical. Removing the overlay or
lowering `FPS` is a visible trade for Egor, not this. Recommendation: the change-gated redraw.
