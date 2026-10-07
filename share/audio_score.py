# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["torch==2.14.1", "torchaudio==2.11.0", "librosa==1.0.0", "audiobox_aesthetics==0.0.4"]
# ///
"""Local quality scores per audio file: UTMOS22 strong (speech MOS 1-5) and Meta Audiobox Aesthetics
(PQ production quality, PC production complexity, CE content enjoyment, CU content usefulness; 1-10).
One process for all files, CPU only. AUDIO_SCORE_FAKE=1 swaps both models for stubs (tests)."""
from __future__ import annotations

import gc
import json
import os
import sys

AXES = (("aes_pq", "PQ"), ("aes_pc", "PC"), ("aes_ce", "CE"), ("aes_cu", "CU"))


def models():
    if os.environ.get("AUDIO_SCORE_FAKE"):
        return (lambda path: len(path) % 5 + 1.0), (lambda path: {key: 5.0 for _, key in AXES})
    import librosa
    import torch

    # audiobox picks mps on its own; CPU keeps RAM flat and results the same on every Mac.
    torch.backends.mps.is_available = lambda: False
    from audiobox_aesthetics.infer import initialize_predictor

    aes = initialize_predictor()
    utmos = torch.hub.load("tarepan/SpeechMOS:v1.2.0", "utmos22_strong", trust_repo=True)
    loaded = {}

    def wave(path):
        if path not in loaded:
            loaded.clear()
            loaded[path] = torch.from_numpy(librosa.load(path, sr=16000, mono=True)[0]).unsqueeze(0)
        return loaded[path]

    def mos(path):
        with torch.inference_mode():
            return float(utmos(wave(path), 16000))

    def aesthetics(path):
        return aes.forward([{"path": wave(path), "sample_rate": 16000}])[0]

    return mos, aesthetics


def main(argv: list[str]) -> int:
    as_json = "--json" in argv
    files = [a for a in argv if a != "--json"]
    mos, aesthetics = models()
    scores = {}
    for path in files:
        aes = aesthetics(path)
        scores[path] = {"utmos": round(mos(path), 2)} | {name: round(float(aes[key]), 2) for name, key in AXES}
        gc.collect()
        if not as_json:
            print(" ".join(f"{k}={v}" for k, v in scores[path].items()) + f" file={path}", flush=True)
    if as_json:
        print(json.dumps(scores, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
