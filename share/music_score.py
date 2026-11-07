# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["essentia-tensorflow==2.1b6.dev1389", "numpy==2.5.4"]
# ///
"""Background fit of music per file: MTG's Essentia engagement (Discogs-EffNet head; lower = more background)
and the top mood/theme tags (MTG-Jamendo). On Egor's 16 marked deck takes (listen-bench, 2026-10-19) low
engagement followed his background fit best of every layer tried: +0.58, Argon +0.41, Flash -0.11.
It misses a calm take in the wrong mood (his "sauna"); the mood tags show that.
The weights (22 MB, CC BY-NC-SA, essentia.upf.edu) download once into ~/.cache/essentia.
AUDIO_SCORE_FAKE=1 swaps the models for stubs (tests)."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

BASE = "https://essentia.upf.edu/models/"
WEIGHTS = {
    "feature-extractors/discogs-effnet/discogs-effnet-bs64-1.pb":
        "3ed9af50d5367c0b9c795b294b00e7599e4943244f4cbd376869f3bfc87721b1",
    "classification-heads/engagement/engagement_regression-discogs-effnet-1.pb":
        "43031d40b3a380e1995c8495a108d14ca74f620d924fad9b28df4189c84d20c5",
    "classification-heads/mtg_jamendo_moodtheme/mtg_jamendo_moodtheme-discogs-effnet-1.pb":
        "03f2b047020aee4ab39f8880da7bdae2a36d06a1508d656c6d424ad4d6de07a9",
    "classification-heads/mtg_jamendo_moodtheme/mtg_jamendo_moodtheme-discogs-effnet-1.json":
        "d62cd90263e4d613fa7fcce7a831e339450394794af63685f96e065c1a896ab0",
}
MOODS = 5


def weight(rel: str) -> str:
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "essentia"
    path = cache / rel.rsplit("/", 1)[1]
    if not path.exists():
        cache.mkdir(parents=True, exist_ok=True)
        data = urllib.request.urlopen(BASE + rel, timeout=120).read()
        if hashlib.sha256(data).hexdigest() != WEIGHTS[rel]:
            sys.exit(f"music-score: {BASE + rel} changed upstream (sha256 mismatch); update WEIGHTS")
        tmp = path.with_suffix(".part")
        tmp.write_bytes(data)
        tmp.replace(path)
    return str(path)


def models():
    if os.environ.get("AUDIO_SCORE_FAKE"):
        return lambda path: {"engagement": round(len(path) % 7 / 10, 3), "mood": ["relaxing", "calm", "film"]}
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")
    import numpy as np
    from essentia.standard import TensorflowPredict2D, TensorflowPredictEffnetDiscogs

    names = list(WEIGHTS)
    emb = TensorflowPredictEffnetDiscogs(graphFilename=weight(names[0]), output="PartitionedCall:1")
    engagement = TensorflowPredict2D(graphFilename=weight(names[1]), output="model/Identity")
    mood = TensorflowPredict2D(graphFilename=weight(names[2]))
    classes = json.loads(Path(weight(names[3])).read_text())["classes"]

    def score(path):
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", "16000", "-f", "f32le", "-"],
                             capture_output=True, check=True).stdout
        e = emb(np.frombuffer(raw, np.float32).copy())
        pr = mood(e).mean(0)
        return {"engagement": round(float(engagement(e).mean()), 3),
                "mood": [classes[i] for i in np.argsort(-pr)[:MOODS]]}

    return score


def main(argv: list[str]) -> int:
    as_json = "--json" in argv
    files = [a for a in argv if a != "--json"]
    score = models()
    scores = {}
    for path in files:
        scores[path] = score(path)
        if not as_json:
            r = scores[path]
            print(f"engagement={r['engagement']} mood={','.join(r['mood'])} file={path}", flush=True)
    if as_json:
        print(json.dumps(scores, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
