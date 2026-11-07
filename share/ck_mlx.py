"""CorridorKey 2.0 stills on MLX (ck2mlx), never scaled: each image reflect-padded to a graph of multiples of 128.

Runs in the engine's own venv (CK_HOME/venv: mlx, torch, cv2), called by share/ck_key.py, never by hand. CK_HOME
(default ~/.local/share/corridorkey, the internal SSD: first start ~4 s against ~14 s from the USB disk) holds:
  venv/       the runtime's Python (mlx, torch, opencv)
  ck2mlx/     peterteravskis/corridorkey-v2-mlx's corridorkey_mlx package (runtime code, its own licence)
  graphs/weights/<component>.safetensors   build «mix» weights (fp16 foundations + RVM, q8 stages), once for all sizes
  graphs/sizes/<H>x<W>-t1/<component>/{graph.json, local.safetensors}   a size's graph and its lifted constants
  graphs/sizes/<H>x<W>-t1/{stats.json, price.json}   price = idle compute seconds of one still at that size
  graphs/usage.jsonl   one row per image: exact graph, graph used, priced lost seconds, build seconds
  heavy.lock           one CorridorKey engine at a time on this Mac (stills here, clips in the bench's ck_key.py)

  ck_mlx.py run JOB.json      JOB = [{"in": png, "out": dir}]; writes dir/alpha.png (16-bit) and dir/fg.png (8-bit
                              straight colour), one JSON line on stdout: {"images": [...], "compute_s": ...}
  ck_mlx.py price [HxW ...]   measure and store prices (default: built sizes without one), on an idle machine

Graph choice: the exact one (sides rounded up to 128), else the cheapest built one at most MAX_PAD_AREA times its
area, else the exact one is built on the spot by the bench exporter (CK_BUILD, ≈1.5 min small to 5 min 4K).
Lost seconds = price(graph used) - price(exact graph); an unbuilt size is priced by a fit c + a*MP + b*MP^2 over the
built ones, so machine load at run time never moves the number.
"""
import contextlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

CK_HOME = Path(os.environ.get("CK_HOME", Path.home() / ".local/share/corridorkey"))
STORE = CK_HOME / "graphs"
COMPS = ("rvm", "foundations", "stage1", "stage2")
# graphs for new sizes are exported from upstream PyTorch in the bench (torch + MoGe venv, 2.5 GB weights)
CK_BUILD = Path(os.environ.get("CK_BUILD", "/Volumes/Work/tmp/corridorkey"))
MAX_PAD_AREA = 2.0  # see _holders: padding ladder 2026-11-07 (bench runs/ladder)
sys.path.insert(0, str(CK_HOME / "ck2mlx"))


def ceil128(n):
    return (n + 127) // 128 * 128


def parse(hw):
    H, W = map(int, hw.lower().split("x"))
    assert H % 128 == 0 and W % 128 == 0 and H > 0 and W > 0, f"{hw}: sides must be multiples of 128"
    return H, W


def built():
    """{(H, W): price seconds or None} of complete sizes"""
    out = {}
    for d in sorted((STORE / "sizes").glob("*x*-t1")):
        if all((d / c / "graph.json").exists() and (d / c / "local.safetensors").exists() for c in COMPS):
            p = d / "price.json"
            out[parse(d.name[:-3])] = json.loads(p.read_text())["seconds"] if p.exists() else None
    return out


def fit(prices):
    """least squares c + a*MP + b*MP^2 over {(H, W): seconds}; None below three points"""
    pts = [(H * W / 1e6, s) for (H, W), s in prices.items() if s is not None]
    if len(pts) < 3:
        return None
    mp = np.array([p[0] for p in pts]); y = np.array([p[1] for p in pts])
    return np.linalg.lstsq(np.stack([np.ones_like(mp), mp, mp * mp], 1), y, rcond=None)[0]


def price_of(hw, prices, coef):
    s = prices.get(hw)
    if s is not None:
        return s, "measured"
    if coef is None:
        return None, "unpriced"
    mp = hw[0] * hw[1] / 1e6
    return float(coef[0] + coef[1] * mp + coef[2] * mp * mp), "fit"


def holders(exact, prices):
    """built graphs an image of padded size `exact` may run on: the exact one, or a bigger one at most MAX_PAD_AREA
    times its area. Further padding is not just slower: a small frame mirrored over a big canvas reads as another
    scene. Ladder (glass, car, hair at 200x112 / 640x360 / 1080p): up to 2x the area nothing visible moved; at 4-9x a
    car grew translucent patches and a floor smear; at 56x+ a glass came out opaque. The ratio decides, not pixels"""
    return [hw for hw in prices if hw[0] >= exact[0] and hw[1] >= exact[1]
            and hw[0] * hw[1] <= MAX_PAD_AREA * exact[0] * exact[1]]


# ---------------------------------------------------------------- weights: shared + local, merged at load

@contextlib.contextmanager
def merged_weights():
    """MLXGraph reads <component>/weights.safetensors; a store size has local.safetensors there instead: serve the
    shared component weights with the size's constants over them"""
    import mlx.core as mx
    orig = mx.load

    def load(path, *a, **k):
        p = Path(path)
        if p.name == "weights.safetensors" and not p.exists() and (p.parent / "local.safetensors").exists():
            return {**orig(str(STORE / "weights" / f"{p.parent.name}.safetensors")), **orig(str(p.parent / "local.safetensors"))}
        return orig(path, *a, **k)
    mx.load = load
    try:
        yield
    finally:
        mx.load = orig


# ---------------------------------------------------------------- the runtime, phase by phase

def optimizations():
    """the release's DEFAULT_OPTIMIZATIONS plus half_kernels: its fp16 reconstruct and reflect pad, which the q8/fp16
    graphs skip by default (Fable/Argon/Astra panel 2026-11-07, checked against upstream fp32)"""
    from corridorkey_mlx import mlx_graph
    return tuple(mlx_graph.DEFAULT_OPTIMIZATIONS) + ("half_kernels",)


def fast_norm():
    """layer_norm / rms_norm on fp16 inputs straight into mx.fast (it accumulates in fp32 itself)"""
    import mlx.core as mx
    from corridorkey_mlx import mlx_graph
    if getattr(mlx_graph.execute_fp16, "_fast_norm", False):
        return
    orig = mlx_graph.execute_fp16

    def execute_fp16(op, args, kwargs, optimizations=()):
        name = op.split(".")[1] if op.startswith("aten.") else op
        if name == "layer_norm" and args[0].dtype == mx.float16:
            w, b = (args[2] if len(args) > 2 else None), (args[3] if len(args) > 3 else None)
            return mx.fast.layer_norm(args[0], w, b, args[4] if len(args) > 4 else 1e-5)
        if name == "rms_norm" and args[0].dtype == mx.float16:
            return mx.fast.rms_norm(args[0], args[2] if len(args) > 2 else None, args[3] if len(args) > 3 else 1e-6)
        return orig(op, args, kwargs, optimizations)
    execute_fp16._fast_norm = True
    mlx_graph.execute_fp16 = execute_fp16


def _features(fd, frame_bgr, timed, hw):
    """encode + RVM + foundations for one still, the frame reflect-padded to the graph's size hw (centred, never
    scaled); rounded as the release's disk path stores them"""
    import torch
    import torch.nn.functional as F
    from corridorkey_mlx.pipeline import encode_frame
    H0, W0 = frame_bgr.shape[:2]
    h, w = hw
    rgb, display = encode_frame(frame_bgr, (h, w))
    mean = fd.rvm_mean.reshape(1, 1, -1, 1, 1)
    std = fd.rvm_std.reshape(1, 1, -1, 1, 1).clamp_min(1e-6)
    small = F.interpolate(display[None], size=(h // 4, w // 4), mode="bilinear", align_corners=False)
    recurrent, _ = timed("rvm", fd.rvm, small[None].clamp(0, 1), None)
    feats = timed("foundations", fd, F.interpolate(display[None], size=(h // 4, w // 4), mode="area"),
                  F.interpolate(display[None], size=(h * 7 // 32, w * 7 // 32), mode="area"))
    rvm = torch.from_numpy(((recurrent - mean) / std)[0, 0].numpy().astype(np.float16)).float()
    return {"rgb": rgb, "moge": feats["moge"][0], "radio": feats["cradio"][0], "rvm": rvm, "hw": (H0, W0, h, w)}


def _baton(s1, f, timed):
    import torch
    H0, W0, h, w = f["hw"]
    s1o = timed("stage1", s1, f["rgb"][None, None], torch.zeros(1, 1, 1, h, w), f["moge"][None, None],
                f["radio"][None, None], f["rvm"][None, None], torch.full((1, 1), -1.).bfloat16().float())
    return torch.from_numpy(s1o["baton"][0].float().numpy().astype(np.float16)).float()


def _render(s2, renderer, f, baton, timed):
    """alpha and straight fg of the frame's own size; no despill here (ck_key.py despills on a chroma screen)"""
    from corridorkey_mlx.pipeline import checkerboard
    H0, W0, h, w = f["hw"]
    pred = timed("stage2", s2, f["rgb"][None, None], baton[None])
    meta = {"model_native_hw": (H0, W0), "output_hw": (H0, W0), "pad": ((w - W0) // 2, 0, (h - H0) // 2, 0),
            "despill_strength": 0.0, "screen": "green"}
    rendered = timed("render", renderer, meta, {"alpha", "fg"}, checkerboard(H0, W0), pred[0])
    return rendered["alpha"][0], rendered["fg"][0]


def _timer(timings):
    def timed(name, f, *a):
        t = time.perf_counter(); r = f(*a); timings[name] = timings.get(name, 0.) + time.perf_counter() - t
        return r
    return timed


def phased(H, W, items):
    """stills on one graph phase by phase: all through the foundations, then stage one, then stage two, each
    component's weights loaded for its phase and dropped after it (peak = the largest phase, not the sum).
    items: [(name, frame_bgr)] -> {name: (alpha16, fg16)}"""
    import gc
    import torch
    import mlx.core as mx
    from corridorkey_mlx.mlx_backend import Foundations, StageOne, StageTwo
    from corridorkey_mlx.mlx_render import MLXRenderer
    mx.set_cache_limit(256 * 1024 * 1024)
    root, opts, timed = STORE / "sizes", optimizations(), _timer({})
    with torch.no_grad(), merged_weights():
        fd = Foundations(root, H, W, True, 1, opts)
        feats = {n: _features(fd, im, timed, (H, W)) for n, im in items}
        del fd; gc.collect(); mx.clear_cache()
        s1 = StageOne(root, H, W, True, opts)
        batons = {n: _baton(s1, feats[n], timed) for n, _ in items}
        del s1; gc.collect(); mx.clear_cache()
        s2 = StageTwo(root, H, W, True, opts)
        renderer = MLXRenderer()
        return {n: _render(s2, renderer, feats[n], batons[n], timed) for n, _ in items}


# ---------------------------------------------------------------- commands

def _build(missing):
    sz = [f"{h}x{w}" for h, w in missing]
    py, tool = CK_BUILD / "metal/venv/bin/python", CK_BUILD / "scripts/ckgraphs.py"
    if not (py.exists() and tool.exists()):
        raise SystemExit(f"ck-key: no graph for {' '.join(sz)} and no exporter at {CK_BUILD} (CK_BUILD)")
    print(f"ck-key: building the graph for {' '.join(sz)}, once per size (≈1.5 min small, 5 min 4K)", file=sys.stderr,
          flush=True)
    t = time.perf_counter()
    subprocess.run([str(py), "-u", str(tool), "build", "--no-verify", *sz], check=True, stdout=sys.stderr,
                   env={**os.environ, "CKGRAPHS": str(STORE)})
    return {hw: round((time.perf_counter() - t) / len(missing), 1) for hw in missing}


def run(job):
    import cv2
    fast_norm()
    frames = []
    for j in job:
        im = cv2.imread(j["in"], cv2.IMREAD_COLOR)
        if im is None:
            raise SystemExit(f"ck-key: cannot read {j['in']}")
        frames.append((j, im))
    prices = built()
    need = sorted({(ceil128(im.shape[0]), ceil128(im.shape[1])) for _, im in frames})
    missing = [hw for hw in need if not holders(hw, prices)]
    built_s = _build(missing) if missing else {}
    prices = built() if missing else prices
    coef = fit(prices)
    groups, rows = {}, []
    for k, (j, im) in enumerate(frames):
        h0, w0 = im.shape[:2]
        exact = (ceil128(h0), ceil128(w0))
        cands = [(price_of(hw, prices, coef)[0] or hw[0] * hw[1] / 1e6, hw) for hw in holders(exact, prices)]
        used = exact if exact in prices else min(cands)[1]  # an exact graph is never beaten, whatever its price noise
        pu, pe = price_of(used, prices, coef), price_of(exact, prices, coef)
        lost = None if pu[0] is None or pe[0] is None else round(max(0.0, pu[0] - pe[0]), 3)
        rows.append({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "image": [w0, h0], "exact": "%dx%d" % exact,
                     "used": "%dx%d" % used, "lost_s": lost, "exact_price": pe[1], "built_s": built_s.get(exact)})
        groups.setdefault(used, []).append(k)
    t = time.perf_counter()
    for (H, W), ks in groups.items():
        res = phased(H, W, [(str(k), frames[k][1]) for k in ks])
        for k in ks:
            a16, f16 = res[str(k)]
            a16 = a16[..., 0] if a16.ndim == 3 else a16
            assert a16.shape == frames[k][1].shape[:2], (a16.shape, frames[k][1].shape)
            out = Path(frames[k][0]["out"]); out.mkdir(parents=True, exist_ok=True)
            cv2.imwrite(str(out / "alpha.png"), a16)
            cv2.imwrite(str(out / "fg.png"), np.round(f16.astype(np.float32) / 257.0).astype(np.uint8))
    compute = round(time.perf_counter() - t, 2)
    with open(STORE / "usage.jsonl", "a") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    print(json.dumps({"images": rows, "compute_s": compute}), flush=True)


def price(sizes):
    fast_norm()
    rng = np.random.default_rng(0)
    for H, W in sizes:
        frame = rng.integers(0, 256, (H, W, 3), dtype=np.uint8)
        runs = []
        for _ in range(3):
            t = time.perf_counter()
            phased(H, W, [("p", frame)])
            runs.append(time.perf_counter() - t)
        rec = {"seconds": round(min(runs), 3), "runs": [round(r, 3) for r in runs], "loadavg": os.getloadavg()[0],
               "measured": time.strftime("%Y-%m-%dT%H:%M:%S")}
        (STORE / "sizes" / f"{H}x{W}-t1" / "price.json").write_text(json.dumps(rec) + "\n")
        print(f"{H}x{W} price {rec['seconds']} s (runs {rec['runs']}, load {rec['loadavg']:.1f})", flush=True)


def main(argv):
    if argv[:1] == ["run"] and len(argv) == 2:
        run(json.loads(Path(argv[1]).read_text()))
    elif argv[:1] == ["price"]:
        price([parse(s) for s in argv[1:]] or [hw for hw, s in built().items() if s is None])
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
