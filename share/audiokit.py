# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["numpy==2.5.4"]
# ///
"""Audio kit: loop a music track so the wrap is not heard, and check a file for the joins people hear.
Guide: docs/audiokit.md. Run through bin/audiokit.

    audiokit.py loop <in> <out .m4a|.wav|.flac> [--min 30] [--max <s>] [--at <start>,<end>] [--lufs -20] [--clip <out .wav>]
    audiokit.py points <in> [--top 10] [--min 30] [--max <s>]
    audiokit.py check <file> [--loop] [--at <s>,<s>...]

Every threshold is Egor's ear on the listen-bench (/Volumes/Work/Projects/listen-bench, README "Editing defects"):
- a hard cut clicks; a crossfade of 1 ms or more does not;
- silence inside music: faint from about 4 ms, clear from 8 ms;
- two beat grids at once: faint from 10-20 ms apart, clear from 40 ms;
- a level dip: faint at 6 dB, clear at 12 dB (a 0.3 s dip; at a join a 10 ms window dips up to 8 dB in clean music,
  and an 11 dB one passed his ear: a join reports 12 and over);
- a jump inside a track: he hears the music, not the join: a voice that sounds through the end and stops or moves to
  another note after it («тянущийся инструмент немного меняет тональность», «у гитары тянущийся звук обрывается»).
  Voice cut: the tones (quarter tones 80 Hz-2.1 kHz, dB over each 11 ms frame's median) standing 6 dB out in every
  frame of the 0.3 s before the join; for each, how far its level in the 0.03-0.33 s that plays after the join falls
  under its level where the take itself went on; the largest. 31 joins he marked in three rounds: every heard one
  11 dB and more but one (a guitar note, 2.9), every clean one 8.3 and less;
- a whole part dropping out or coming in («инструмент явно исчез», «скрипки на фоне играют ровно до склейки»), which
  in the mix can sit 20 dB under the rest: per Demucs stem (htdemucs: drums, bass, other, vocals = any lead), the
  power over the 1 s and the 2 s that play after the join against the take's own continuation there, stems within
  35 dB of the loudest; heard from 8 dB over 1 s or 15 dB over 2 s. 37 marked joins: clean ones reach 4.0 and 11.1,
  heard ones 13 and more over 1 s or 19 and more over 2 s. Two Demucs runs of one file split a quiet part between
  stems differently (card 18's entering part, 1.75 s after the join, sat in "vocals" once and half in "other" the
  next time): the 2 s window catches it in both. Stems come from audiokit_stems.py (uv provisions Demucs on first use),
  cached by the file's content under ~/.cache/audiokit (~30 s and 2.6 GB per 2-minute track); AUDIOKIT_STEMS=off
  or no uv skips the stems and the notes, and the output says so. Held out on cards 24-29 (2026-10-22) both
  measures called the three clear ones (a part dropping out or coming in) and passed the clean one;
- an instrument playing other notes after the join («пианино играет одно, резко перестаёт и начинает играть другое»,
  «партия не там обрывается и не там начинается»): per stem but the drums, frames of 8192 samples every 23 ms from
  the join itself to 0.2 s after it, pitch classes, cosine distance frame by frame against the take's own
  continuation, weighted by power; stems within 35 dB of the loudest. 49 marked joins: clean ones 0.18 and less but
  one (a round-1 cut in sprout-f, 0.50), the parts he heard 0.35-0.94. Heard from 0.30. The first version averaged
  0.03-0.33 s on a 23 ms grid of its own, up to a frame apart on the two sides, and read half of these at 0.30-0.45;
- the music around the end against the music around the start (likeness: pitch classes and band levels, 3 s before
  and after both points): no clean join under 0.37, and under 0.30 the lead lands elsewhere in its phrase (card 31,
  «последние два аккорда партии у гитары… доигрываются, хотя до этого их не было», 0.15, every other measure clean).
  Heard at 0.30 and under. Its higher range ranks: clean joins reach 0.46, and heard ones 0.88.

Near the limits he hears it often: share = the largest of the four measures as a share of its limit (likeness from 1
down to 0.30). 55 marked joins: under 0.85, 20 of 21 clean; 0.85-1, 3 of 5 heard (cards 36, 38, 41, 2026-10-22);
1 and over, all heard but one. So clean is under 0.85, borderline under 1.

loop: start and end on whole bars of the track's own beat with share under 0.85; within 0.03 of the best likeness
among them, the longest. A take with no such pair gets its least share and verdict=borderline or audible. The start is nudged onto the end's grid by onset cross-correlation, kept only where the
timbre agrees, then moved by up to 5 ms to the best waveform match. The file is the music from start to end, its first 10 ms
crossfaded from what follows the end, so the last sample runs into the first. Gain is one linear factor: no
resampling or limiter after the cut (in tools/music_prep.py they pulled the last samples to zero: a click at every
wrap). An .m4a is encoded with the loop's own end before it and its start after it, and its edit list plays only the
loop: the encoder never meets silence at the edges. The loop ends on an AAC frame edge, so Chrome's decodeAudioData and
ffmpeg, which skip the edit list's end and run to the last frame's edge, return the exact length, as Apple's decoder
(Safari) does (Egor's deck loops before it: 148-850 samples of the loop's start past the end, a click at every wrap;
Apple's encoder and afconvert pad ~600 samples ffmpeg plays as a gap; ffmpeg's default ms timescale cuts up to 1 ms). It decodes its own output and checks it; `verdict=clean`, `verdict=borderline: <why>` or
`verdict=audible: <why>`.
points: the loop pairs that keep their voices and parts, by likeness, for choosing by hand (loop --at).
check: digital silence and beat-grid jumps anywhere; with --at (the joins you made) and --loop (the wrap) also the
waveform step and the level dip there. A grid jump where nobody cut is a place to listen, not a verdict
(four-sides-fb1's generator slipped a drum hit at 62.4 s; 14 of 16 untouched deck takes show none).

Files are read to their container length: ffmpeg also decodes the AAC end padding (~20 ms of silence), which glued
to the next piece is itself a click; check --loop also counts what a browser decodes past that length. A browser's <audio loop> restarts with its own gap; Web Audio's
AudioBufferSourceNode with loop=true plays a loop sample-exact.
"""
import argparse
import hashlib
import itertools
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

from pathlib import Path

import numpy as np

SR, ASR = 48000, 22050
XF = 0.010  # the join's crossfade, s
CUT_BAD = 10.0  # dB of voice cut from which the join is heard
STEM_BAD = ((1.0, 8.0), (2.0, 15.0))  # (s after the join, dB a stem may differ there from the take's continuation)
STEM_NAMES = ("drums", "bass", "other", "vocals")
NOTES_BAD = 0.30  # pitch-class distance of a stem across the join from which its other notes are heard
LIKE_BAD = 0.30  # likeness at and under which the join is heard
SAFE = 0.85  # share of the nearest limit under which a join is clean
PART_TONES = 55 * 2 ** (np.arange(148) / 24)  # quarter tones 55 Hz-4 kHz, for the stems' notes
CACHE = Path(os.environ.get("AUDIOKIT_CACHE", Path.home() / ".cache/audiokit"))
ROLL = 4096  # samples of the loop's own end and start around an encoded .m4a


def duration(path):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                                check=True, capture_output=True, text=True).stdout)


def read(path, sr=SR, ch=2, whole=False):
    """Samples to the container length; whole: every decoded sample, as Chrome's decodeAudioData returns them (it
    and ffmpeg skip the edit list's end and run to the last AAC frame's edge)."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", str(ch), "-ar", str(sr), "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    x = np.frombuffer(raw, np.float32).astype(np.float64)
    x = x.reshape(-1, ch) if ch > 1 else x
    return x if whole else x[:round(duration(path) * sr)]


def read_apple(path):
    """Safari's view: Apple's decoder at 48 kHz stereo, or None off a Mac."""
    if not shutil.which("afconvert"):
        return None
    with tempfile.NamedTemporaryFile(suffix=".wav") as f:
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@48000", "-c", "2", path, f.name], check=True)
        return read(f.name)


def to_mono(y, sr=ASR):
    """48 kHz stereo samples to mono at sr, through ffmpeg's resampler."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-f", "f64le", "-ar", str(SR), "-ac", "2", "-i", "-", "-ac", "1", "-ar",
                          str(sr), "-f", "f64le", "-"], input=np.ascontiguousarray(y).tobytes(), check=True,
                         capture_output=True).stdout
    return np.frombuffer(raw, np.float64)


def write(path, y, loop=False):
    ext = path.rsplit(".", 1)[-1].lower()
    codec = {"wav": ["-c:a", "pcm_s24le"], "flac": ["-c:a", "flac"],
             "m4a": ["-c:a", "aac", "-b:a", "256k", "-movie_timescale", str(SR)]}
    if ext not in codec:
        sys.exit(f"audiokit: write .m4a, .wav or .flac (mp3 has no exact length, so a loop would gap): {path}")
    roll = ext == "m4a" and loop
    front = ROLL + -len(y) % 1024  # the loop ends on an AAC frame edge: decoders that skip the edit list's end stop there
    z = np.concatenate([y[-front:], y, y[:ROLL]]) if roll else y
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f64le", "-ar", str(SR), "-ac", "2", "-i", "-", *codec[ext], path],
                   input=np.ascontiguousarray(z).tobytes(), check=True)
    if roll:  # the edit list plays the loop only: it starts past the encoder delay and the roll, and lasts the loop
        b = bytearray(open(path, "rb").read())
        i = b.find(b"elst")
        if b[i + 4] != 0 or struct.unpack(">I", b[i + 8:i + 12])[0] != 1:
            sys.exit(f"audiokit: unexpected edit list in {path}")
        start = struct.unpack(">I", b[i + 16:i + 20])[0]
        b[i + 12:i + 20] = struct.pack(">II", len(y), start + front)
        for box, off in ((b"mvhd", 20), (b"tkhd", 24)):
            j = b.find(box)
            b[j + off:j + off + 4] = struct.pack(">I", len(y))
        open(path, "wb").write(b)


def stft(x, sr, n, hop):
    fr = np.lib.stride_tricks.sliding_window_view(x, n)[::hop] * np.hanning(n)
    return np.abs(np.fft.rfft(fr, axis=1)), np.fft.rfftfreq(n, 1 / sr)


def bands(spec, f, edges):
    return np.stack([spec[:, (f >= lo) & (f < hi)].sum(1) for lo, hi in zip(edges[:-1], edges[1:])], 1)


GFPS = ASR / 256  # the beat grid's frames
QTONES = 80 * 2 ** (np.arange(113) / 24)  # quarter tones, 80 Hz-2.1 kHz


def grid_onsets(m):
    """Band flux at 11.6 ms frames of mono 22050 Hz samples."""
    b = np.log1p(bands(*stft(m, ASR, 2048, 256), np.geomspace(40, 10000, 33)))
    return np.maximum(np.diff(b, axis=0, prepend=b[:1]), 0).sum(1)


def beat_of(o):
    """The beat in grid frames: the autocorrelation peak in 0.3-1.0 s, refined on its 4th and 16th multiples."""
    e = o - o.mean()
    r = np.correlate(e, e, "full")[len(e) - 1:]
    lo, hi = int(0.3 * GFPS), int(1.0 * GFPS)
    b = float(lo + np.argmax(r[lo:hi]))
    for m, tol in ((4, 0.01), (16, 0.004)):
        c = m * b
        if c * (1 + tol) + 2 >= len(r) / 2:
            break
        j = int(c * (1 - tol)) + int(np.argmax(r[int(c * (1 - tol)):int(c * (1 + tol)) + 1]))
        y0, y1, y2 = r[j - 1:j + 2]
        b = (j + 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2)) / m
    return b


def grid(o, b, side=8.0):
    """Every 0.25 s: (t s, ms the onsets of the 8 s after sit off those of the 8 s before, the gain of that fit).
    Onsets are folded modulo the beat into 48 phase bins; clean music keeps its grid through any arrangement change."""
    def fold(i0, i1):
        i = np.arange(i0, i1)
        h = np.bincount(((i / b) % 1 * 48).astype(int) % 48, o[i0:i1], 48)
        h = 2 * h + np.roll(h, 1) + np.roll(h, -1)  # a one-bin shift of a weak beat is noise (crown-e read +442 ms)
        h = h - h.mean()
        return h / (np.sqrt((h * h).sum()) + 1e-9)

    w, out = int(side * GFPS), []
    for i in range(w, len(o) - w, int(0.25 * GFPS)):
        pre, post = fold(i - w, i), fold(i, i + w)
        c = np.array([(pre * np.roll(post, -k)).sum() for k in range(48)])
        k = int(np.argmax(c))
        out.append((i / GFPS, ((k + 24) % 48 - 24) * b / 48 / GFPS * 1000, float(c[k] - c[0])))
    return out


def stems_cmd():
    """The command that writes <out dir>/{drums,bass,other,vocals}.wav of <in>; None when off or uv is missing."""
    cmd = os.environ.get("AUDIOKIT_STEMS", "")
    if cmd == "off":
        return None
    if cmd:
        return cmd.split()
    uv = os.environ.get("AUDIOKIT_UV") or shutil.which("uv") or "/opt/homebrew/bin/uv"
    return [uv, "run", "-q", "--script", str(Path(__file__).resolve().parent / "audiokit_stems.py")] if Path(uv).exists() else None


def stems(path):
    """The folder of path's htdemucs stems, cached by the file's content; None when stems are off."""
    d = CACHE / "stems" / hashlib.sha1(Path(path).read_bytes()).hexdigest()[:16]
    if all((d / f"{n}.wav").exists() for n in STEM_NAMES):
        return d
    cmd = stems_cmd()
    if cmd is None:
        print("audiokit: stems off (AUDIOKIT_STEMS=off or no uv): parts dropping out and wrong notes are not checked",
              file=sys.stderr)
        return None
    with tempfile.TemporaryDirectory() as tmp:
        r = subprocess.run(["nice", "-n", "10", *cmd, str(path), tmp], capture_output=True, text=True)
        if r.returncode != 0 or not all((Path(tmp) / f"{n}.wav").exists() for n in STEM_NAMES):
            sys.exit(f"audiokit: stems failed on {path}: {(r.stderr or r.stdout).strip()[-400:]}")
        d.mkdir(parents=True, exist_ok=True)
        for n in STEM_NAMES:
            shutil.move(Path(tmp) / f"{n}.wav", d / f"{n}.wav")
    return d


class Track:
    """One file's analysis: the beat, the onsets, and the per-frame pitch classes and band levels."""

    def __init__(self, path, use_stems=True):
        d = stems(path) if use_stems else None
        self.stems, self.parts, self._tones = None, {}, {}
        if d is not None:
            self.stems = {}
            for n in STEM_NAMES:
                x = read(str(d / f"{n}.wav"), 44100, 1)
                self.stems[n] = self._envelope(x)
                if n != "drums":
                    self.parts[n] = x
        self.x = read(path)
        self.L = len(self.x) / SR
        m = to_mono(self.x)
        self.bands = np.log1p(bands(*stft(m, ASR, 1024, 64), np.geomspace(60, 10000, 25)))
        self.fps = ASR / 64  # 2.9 ms frames, for alignment
        self.on = np.maximum(np.diff(self.bands, axis=0, prepend=self.bands[:1]), 0).sum(1)
        o = grid_onsets(m)
        bf = beat_of(o)
        h = np.bincount(((np.arange(len(o)) / bf) % 1 * 48).astype(int) % 48, o, 48)
        self.beat, self.phase = bf / GFPS, (np.argmax(h) + 0.5) / 48 * bf / GFPS
        spec, f = stft(self.x.mean(1), SR, 4096, 1024)
        p = spec ** 2
        k = (f >= 55) & (f <= 4000)
        pc = np.round(12 * np.log2(f[k] / 440)).astype(int) % 12
        self.chroma = np.stack([p[:, k][:, pc == c].sum(1) for c in range(12)], 1)
        self.level = np.log10(bands(p, f, np.geomspace(40, 12000, 13)) + 1e-9)
        self.ffps = SR / 1024
        spec, f = stft(self.x.mean(1), SR, 8192, 512)
        g = 10 * np.log10(np.stack([np.interp(QTONES, f, q) for q in spec ** 2]) + 1e-12)
        self.voices = g - np.median(g, axis=1, keepdims=True)
        self.vfps = SR / 512

    @property
    def bar(self):
        return self.beat * (8 if self.beat < 0.45 else 4)  # a short beat is read as the eighth note

    def likeness(self, a, b, w=3.0):
        """How alike the music sounds around a and around b: frame-by-frame pitch-class cosine over w s before and
        after both points, less half the mean band-level difference."""
        ia, ib, n = int(a * self.ffps), int(b * self.ffps), int(w * self.ffps)
        A, B = self.chroma[ia - n:ia + n], self.chroma[ib - n:ib + n]
        cos = ((A * B).sum(1) / (np.linalg.norm(A, axis=1) * np.linalg.norm(B, axis=1) + 1e-12)).mean()
        return float(cos - 0.5 * np.abs(self.level[ia - n:ia + n] - self.level[ib - n:ib + n]).mean())

    def align(self, a, b):
        """b moved within a fifth of a beat so the onsets of the 4 s after it line up with those after a."""
        w, m = int(4 * self.fps), int(0.2 * self.beat * self.fps)
        z = lambda v: (v - v.mean()) / (np.sqrt(((v - v.mean()) ** 2).sum()) + 1e-9)
        ia, ib = int(a * self.fps), int(b * self.fps)
        ref = z(self.on[ia:ia + w])
        c = np.array([(ref * z(self.on[ib + d:ib + d + w])).sum() for d in range(-m, m + 1)])
        j = int(np.clip(np.argmax(c), 1, len(c) - 2))
        y0, y1, y2 = c[j - 1:j + 2]
        den = y0 - 2 * y1 + y2
        return b + (j - m + (0.5 * (y0 - y2) / den if den else 0)) / self.fps

    def agrees(self, a, b):
        """The timbre around b, moved within 0.6 of a beat, matches that around a best within 25 ms of b."""
        w = int(3 * self.fps)
        z = lambda v: (v - v.mean()) / (np.sqrt(((v - v.mean()) ** 2).sum()) + 1e-9)
        ref = z(self.bands[int(a * self.fps) - w:int(a * self.fps) + w].ravel())
        ds = np.arange(-int(0.6 * self.beat * self.fps), int(0.6 * self.beat * self.fps) + 1)
        c = [(ref * z(self.bands[int(b * self.fps) + d - w:int(b * self.fps) + d + w].ravel())).sum() for d in ds]
        return abs(ds[int(np.argmax(c))]) / self.fps <= 0.025

    @staticmethod
    def _envelope(x):
        """Power per 50 ms of 44.1 kHz, dB."""
        return 10 * np.log10((x[:len(x) // 2205 * 2205].reshape(-1, 2205) ** 2).mean(1) + 1e-12)

    def stem_change(self, a, b):
        """(share of its limit, dB, stem, window s) of the window in STEM_BAD that hears most: the stem whose power over
        the window after b differs most from the take's own window after a, of the stems within 35 dB of the loudest;
        + it comes in, - it drops out. Heard when the share is 1 or more; (0, 0, None, 0) without stems."""
        if not self.stems:
            return 0.0, 0.0, None, 0.0
        mean = lambda v: 10 * np.log10((10 ** (v / 10)).mean())
        out = []
        for w, lim in STEM_BAD:
            ia, ib, n = int(a * 20), int(b * 20), int(w * 20)
            lv = {k: (mean(e[ia:ia + n]), mean(e[ib:ib + n])) for k, e in self.stems.items()}
            top = max(max(v) for v in lv.values())
            d, k = max(((p - q, k) for k, (q, p) in lv.items() if max(q, p) >= top - 35), key=lambda v: abs(v[0]))
            out.append((abs(d) / lim, float(d), k, w))
        return max(out)

    def tones(self, k, t):
        """Stem k's pitch classes (power) in 9 frames of 8192 samples starting at t, 23 ms apart (0.2 s)."""
        i = round(t * 44100)
        if (k, i) not in self._tones:
            x = self.parts[k]
            fr = np.stack([x[i + j:i + j + 8192] for j in range(0, 8820, 1014)]) * np.hanning(8192)
            f = np.fft.rfftfreq(8192, 1 / 44100)
            pc = np.round(np.arange(len(PART_TONES)) / 2).astype(int) % 12
            self._tones[k, i] = np.stack([np.bincount(pc, np.interp(PART_TONES, f, q), 12)
                                          for q in np.abs(np.fft.rfft(fr, axis=1)) ** 2])
        return self._tones[k, i]

    def notes(self, a, b):
        """(distance, stem): of the stems but the drums within 35 dB of the loudest, the largest power-weighted mean
        pitch-class cosine distance, frame by frame, between the 0.2 s from b and the take's own 0.2 s from a.
        (0, None) without stems."""
        if not self.parts:
            return 0.0, None
        P = {k: (self.tones(k, a), self.tones(k, b)) for k in self.parts}
        lv = lambda v: 10 * np.log10(v.sum() + 1e-14)
        top = max(lv(v) for pq in P.values() for v in pq)
        out = (0.0, None)
        for k, (p, q) in P.items():
            if max(lv(p), lv(q)) < top - 35:
                continue
            cos = (p * q).sum(1) / (np.linalg.norm(p, axis=1) * np.linalg.norm(q, axis=1) + 1e-14)
            w = p.sum(1) + q.sum(1)
            c = float(1 - (cos * w).sum() / w.sum())
            if c > out[0]:
                out = (c, k)
        return out

    def cut(self, a, b):
        """Voice cut of a jump from a to b, dB: of the tones standing 6 dB out through the 0.3 s before a, the largest
        fall of the 0.03-0.33 s after b under the take's own 0.03-0.33 s after a."""
        v, fps = self.voices, self.vfps
        ia, ib, n, p0, p1 = int(a * fps), int(b * fps), int(0.3 * fps), int(0.03 * fps), int(0.33 * fps)
        held = (v[ia - n:ia] > 6).all(0)
        if not held.any():
            return 0.0
        return float((v[ia + p0:ia + p1].mean(0) - v[ib + p0:ib + p1].mean(0))[held].max())

    def pairs(self, lo, hi):
        """Every (likeness, start, end) loop of whole bars lo..hi s long, the start on the end's grid."""
        out, bar = [], self.bar
        first = self.phase + bar * np.ceil((4 - self.phase) / bar)
        for s in np.arange(first, self.L - lo - 5, bar):
            for e in np.arange(s + bar * np.ceil(lo / bar), min(s + hi, self.L - 5) + 1e-6, bar):
                s2 = self.align(e, s)
                if s2 > 3.5 and self.agrees(e, s2):
                    out.append((self.likeness(e, s2), s2, e))
        return sorted(out, reverse=True)


def share(cut, stem, notes, like):
    """The largest of the four measures as a share of its limit: 1 and over is heard, under SAFE clean."""
    return max(cut / CUT_BAD, stem[0], notes[0] / NOTES_BAD, (1 - like) / (1 - LIKE_BAD))


def phase_join(x, a, b, max_ms=5):
    """b (samples) moved within max_ms so the 20 ms after it best match the 20 ms after a; that correlation."""
    n, m = round(0.02 * SR), round(max_ms / 1000 * SR)
    p = x[a:a + n].mean(1)

    def corr(d):
        q = x[b + d:b + d + n].mean(1)
        return p @ q / (np.linalg.norm(p) * np.linalg.norm(q) + 1e-12)

    best = max(range(-m, m + 1), key=corr)
    return b + best, float(corr(best))


def xfade(p, q, r):
    """p into q, linear gains scaled to keep the power for two pieces that correlate at r: an equal-power fade of
    pieces in phase swells, one of pieces in opposite phase dips."""
    t = np.linspace(0, 1, len(p))[:, None]
    g, h = 1 - t, t
    return (p * g + q * h) / np.sqrt(np.maximum(g * g + h * h + 2 * r * g * h, 0.25))


def lufs_gain(y, target):
    """One linear factor to the target integrated loudness, held so the sample peak stays under -1 dBFS."""
    err = subprocess.run(["ffmpeg", "-nostats", "-f", "f64le", "-ar", str(SR), "-ac", "2", "-i", "-", "-af", "ebur128",
                          "-f", "null", "-"], input=np.ascontiguousarray(y).tobytes(), capture_output=True).stderr.decode()
    i = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", err)[-1])
    return min(10 ** ((target - i) / 20), 10 ** (-1 / 20) / (np.abs(y).max() + 1e-9))


def db(s):
    return 20 * np.log10(np.sqrt((s * s).mean()) + 1e-9)


def at_join(y, j):
    """At sample j of y (48 kHz stereo): the largest waveform step within 1 ms over the 99.9th-percentile step of the
    surrounding second, and how far the quietest 10 ms window within 10 ms sits under the median one of the 150 ms
    around it."""
    s = np.abs(np.diff(y[max(j - SR // 2, 0):j + SR // 2], axis=0))
    near = np.abs(np.diff(y[j - SR // 1000:j + SR // 1000 + 1], axis=0))
    step = float(max(near[:, c].max() / (np.percentile(s[:, c], 99.9) + 1e-12) for c in range(2)))
    m, w, st = y.mean(1), SR // 100, SR // 1000
    lv = lambda i: db(m[i - w // 2:i + w // 2])
    ctx = [lv(i) for i in itertools.chain(range(j - 150 * st, j - 20 * st, st), range(j + 20 * st, j + 150 * st, st))]
    return step, float(np.median(ctx) - min(lv(i) for i in range(j - 10 * st, j + 10 * st + 1, st)))


def inspect(y, joins=(), loop=False, beat=None):
    """What a listener would hear in y (48 kHz stereo): [(time s, what, 'clear'|'faint'|'listen')]. joins are the
    cut points in s; loop also checks the wrap, the end running into the start; beat (s), when the source's is known."""
    L, out = len(y) / SR, []
    m, n = y.mean(1), SR // 1000
    lv = 20 * np.log10(np.sqrt((m[:len(m) // n * n].reshape(-1, n) ** 2).mean(1)) + 1e-9)
    if loop:
        lv = np.r_[lv, lv[:200]]
    i = 0
    for quiet, run in itertools.groupby(lv < -60):
        k = i + len(list(run))
        if quiet and k - i >= 4 and i >= 100 and k + 100 <= len(lv) and lv[i - 100:i].max() > -40 and lv[k:k + 100].max() > -40:
            out.append((i / 1000 % L, f"{k - i} ms of silence inside the music", "clear" if k - i >= 8 else "faint"))
        i = k
    o = grid_onsets(to_mono(np.concatenate([y, y[:12 * SR]]) if loop else y))
    places = [*joins, *([L] if loop else [])]
    spans = []
    for r in grid(o, beat * GFPS if beat else beat_of(o)):
        if abs(r[1]) >= 20 and r[2] >= 0.25:
            if spans and r[0] - spans[-1][-1][0] <= 0.375:
                spans[-1].append(r)
            else:
                spans.append([r])
    for sp in spans:
        t, ms, _ = max(sp, key=lambda r: r[2])
        if any(sp[0][0] - 0.5 <= p <= sp[-1][0] + 0.5 for p in places):
            out.append((t % L, f"the beat after the join lands {ms:+.0f} ms off the one before",
                        "clear" if abs(ms) >= 40 else "faint"))
        elif abs(ms) >= 25:
            out.append((t % L, f"the beat grid moves {ms:+.0f} ms", "listen"))
    for p in places:
        step, dip = at_join(np.concatenate([y[-SR:], y[:SR]]), SR) if loop and p == L else at_join(y, round(p * SR))
        if step >= 2:
            out.append((p % L, f"click: the wave jumps {step:.1f}x its largest steps", "clear"))
        if dip >= 12:
            out.append((p % L, f"a {dip:.0f} dB dip", "clear"))
    return sorted(out)


def mmss(t):
    return f"{int(t // 60)}:{t % 60:06.3f}"


def loop(a):
    t = Track(a.src)
    if a.at:  # points chosen by hand (from `points`): the start still goes onto the end's grid
        s, e = (float(v) for v in a.at.split(","))
        s = t.align(e, s)
        like, cut, (so, sd, sk, sw), (nd, nk) = t.likeness(e, s), t.cut(e, s), t.stem_change(e, s), t.notes(e, s)
    else:
        hi = a.max or t.L
        ps = t.pairs(a.min, hi)
        if not ps:
            sys.exit(f"audiokit: no loop of {a.min:.0f}-{hi:.0f} s fits {a.src} ({t.L:.1f} s, bar {t.bar:.2f} s)")
        ps = [(t.cut(e, s), t.stem_change(e, s), t.notes(e, s), like, s, e) for like, s, e in ps]
        keep = [p for p in ps if share(*p[:4]) < SAFE]
        if keep:
            top = max(p[3] for p in keep)
            cut, (so, sd, sk, sw), (nd, nk), like, s, e = max((p for p in keep if p[3] >= top - 0.03), key=lambda p: p[5] - p[4])
        else:  # the least heard
            cut, (so, sd, sk, sw), (nd, nk), like, s, e = min(ps, key=lambda p: share(*p[:4]))
    S, E = round(s * SR), round(e * SR)
    S, r = phase_join(t.x, E, S)
    n = round(XF * SR)
    y = t.x[S:E].copy()
    y[:n] = xfade(t.x[E:E + n], t.x[S:S + n], r)
    if a.lufs is not None:
        y *= lufs_gain(y, a.lufs)
    write(a.dst, y, loop=True)
    found, checked = [], []
    for name, z in (("chrome", read(a.dst, whole=True)), ("apple", read_apple(a.dst) if a.dst.endswith(".m4a") else None)):
        if z is None:
            continue
        checked.append(name)
        if len(z) != len(y):
            found.append((0.0, f"{name} decodes {len(z) - len(y):+d} samples off the loop's length", "clear"))
        else:
            found += [f for f in inspect(z, loop=True, beat=t.beat) if f not in found]
    if a.clip:
        z = read(a.dst)
        write(a.clip, np.concatenate([z[-6 * SR:], z[:6 * SR]]))
    why = [f"{mmss(t_)} {w} ({k})" for t_, w, k in found if k != "listen"]
    if cut >= CUT_BAD:
        why.insert(0, f"a voice that sounds through the end falls {cut:.0f} dB after the wrap (heard from {CUT_BAD:.0f})"
                      f"{'' if a.at else ', the least this take has'}: it stops or moves to another note; "
                      "try points at phrase starts, a fade, or another take")
    if so >= 1:
        why.insert(0, f"the {sk} stem {'comes in' if sd > 0 else 'drops out'} in the {sw:g} s after the wrap ({sd:+.0f} dB "
                      f"against the take, heard from {dict(STEM_BAD)[sw]:.0f}){'' if a.at else ', the least this take has'}: a part "
                      "starts or stops at the join; try other points, a fade, or another take")
    print(f"loop {S / SR:.3f}-{E / SR:.3f} s of {t.L:.1f} s: {(E - S) / SR:.3f} s, {(E - S) / SR / t.bar:.2f} bars of "
          f"{t.bar:.3f} s (beat {t.beat * 1000:.1f} ms)")
    if nd >= NOTES_BAD:
        why.insert(0, f"the {nk} stem plays other notes after the wrap (pitch classes {nd:.2f} off the take's own, heard "
                      f"from {NOTES_BAD}){'' if a.at else ', the least this take has'}: it jumps to another place in its "
                      "phrase; try points at phrase starts, a fade, or another take")
    if like <= LIKE_BAD:
        why.insert(0, f"the music around the start is not the music around the end (likeness {like:.2f}, heard at "
                      f"{LIKE_BAD} and under){'' if a.at else ', the least this take has'}: the lead lands elsewhere in "
                      "its phrase; try points at phrase starts, a fade, or another take")
    q = share(cut, (so,), (nd,), like)
    near = max((cut / CUT_BAD, f"voice cut {cut:.1f} dB"), (so, f"{sk} stem {sd:+.1f} dB"),
               (nd / NOTES_BAD, f"{nk} notes {nd:.2f}"), ((1 - like) / (1 - LIKE_BAD), f"likeness {like:.2f}"))
    print(f"share={q:.2f} (worst measure: {near[1]}; clean under {SAFE}, heard from 1)")
    print(f"voice_cut={cut:.1f}dB stems={f'{sd:+.1f}dB ({sk}, {sw:g} s) notes={nd:.2f} ({nk})' if t.stems else 'skipped (no Demucs)'} "
          f"likeness={like:.3f} join_corr={r:+.2f} checked={'+'.join(checked)}")
    for t_, w, k in found:
        if k == "listen":
            print(f"listen {mmss(t_)}: {w} (in the take itself)")
    print(f"dest={a.dst}")
    print("verdict=" + ("audible: " + "; ".join(why) if why else "clean" if q < SAFE else
                        f"borderline: {near[1]} is at {near[0]:.0%} of its limit; of 5 marked joins at 85-100% he heard "
                        "3; listen, or try other points"))


def points(a):
    t = Track(a.src)
    print("share  likeness  cut dB  stem dB  notes     start ->      end   length")
    ps = [(share(cut, st, nt, like), like, cut, st, nt[0], s, e) for like, s, e in t.pairs(a.min, a.max or t.L)
          for cut, st, nt in [(t.cut(e, s), t.stem_change(e, s), t.notes(e, s))]]
    word = lambda q: "clean" if q < SAFE else "borderline" if q < 1 else "heard"
    for p in sorted(ps, key=lambda p: (word(p[0]) != "clean", p[0] if p[0] >= SAFE else 0, -p[1]))[:a.top]:
        print(f"{p[0]:.2f}  {p[1]:.3f}  {p[2]:6.1f}  {p[3][1]:+7.1f}  {p[4]:5.2f}  {p[5]:8.3f} -> {p[6]:8.3f}  "
              f"{p[6] - p[5]:7.3f} s  {word(p[0])}")


def check(a):
    y = read(a.file)
    found = inspect(y, [float(v) for v in a.at.split(",")] if a.at else [], a.loop)
    tail = len(read(a.file, whole=True)) - len(y)
    if a.loop and tail:
        found.append((len(y) / SR, f"browsers decode {tail} samples past the loop's end, a click at every wrap: set the "
                                   f"player's loopEnd to {len(y) / SR:.6f} s, or re-cut with audiokit loop", "clear"))
    for t, w, k in found:
        print(f"{mmss(t)}  {k:6} {w}")
    print("verdict=" + ("clean" if all(k == "listen" for *_, k in found) else "audible"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("loop")
    p.add_argument("src")
    p.add_argument("dst")
    p.add_argument("--min", type=float, default=30.0)
    p.add_argument("--max", type=float)
    p.add_argument("--at")
    p.add_argument("--lufs", type=float)
    p.add_argument("--clip")
    p = sub.add_parser("points")
    p.add_argument("src")
    p.add_argument("--min", type=float, default=30.0)
    p.add_argument("--max", type=float)
    p.add_argument("--top", type=int, default=10)
    p = sub.add_parser("check")
    p.add_argument("file")
    p.add_argument("--loop", action="store_true")
    p.add_argument("--at")
    a = ap.parse_args()
    {"loop": loop, "points": points, "check": check}[a.cmd](a)


if __name__ == "__main__":
    main()
