# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["demucs==4.1.0", "torch==2.14.1", "numpy==2.5.4", "soundfile==0.14.0"]
# ///
"""Demucs htdemucs stems for audiokit: audiokit_stems.py <in> <out dir> writes <out dir>/{drums,bass,other,vocals}.wav
at 44.1 kHz. Apple's GPU (MPS) first, the CPU when it fails; about 30 s and 2.6 GB per 2-minute track. The model
(adefossez/HTDemucs) downloads into ~/.cache/huggingface on first use."""
import shutil
import sys
import tempfile
from pathlib import Path

import demucs.separate


def main(src, out):
    err = None
    for dev in (["-d", "mps"] if sys.platform == "darwin" else []), []:
        with tempfile.TemporaryDirectory() as tmp:
            try:
                demucs.separate.main(["-n", "htdemucs", *dev, "-o", tmp, src])
                d = next(Path(tmp).glob("htdemucs/*"))
            except (Exception, SystemExit) as e:  # MPS out of memory or missing an op: the CPU next
                err = e
                continue
            for n in ("drums", "bass", "other", "vocals"):
                shutil.move(d / f"{n}.wav", Path(out) / f"{n}.wav")
            return 0
    sys.exit(f"audiokit_stems: demucs failed on {src}: {err}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: audiokit_stems.py <in> <out dir>")
    sys.exit(main(*sys.argv[1:]))
