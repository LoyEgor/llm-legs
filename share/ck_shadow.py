# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "pillow==12.3.0", "opencv-python-headless==5.0.0.93", "scipy==1.18.1"]
# ///
"""Shadow layers for a cut-out on a flat backdrop, measured from the frame: grey (default), colour, GPT's drawn one.

Importable (share/ck_key.py, image-leg's GPT combination). Every array is float32 in 0..1, in the input's
EXIF-transposed frame: I HxWx3 the frame, A HxW a keyer's alpha (CorridorKey's), F HxWx3 its straight colour.
  grey(I, A, F) -> M HxW            the multiply layer (1 = no effect): the plate's darkening that A*F does not
                                    explain, I = A*F + (1-A)*M*B, so nothing darkens twice; under the subject's
                                    soft edge and body it carries the nearest floor values (a thinner object on top
                                    finds no bare seam)
  colour(I, A, F) -> M3 HxWx3       the same depth, tinted by the frame/plate ratio per channel, broad darkening
                                    only. On request only (Egor 2026-11-07): one RGBA cannot carry it, it stays a
                                    separate multiply layer, and a light caustic on a dark floor cannot show at all
  gpt_shadow(gpt_rgba, A, Mf) -> M  GPT's drawn shadow (a cut-out asked to keep it, laid in the input's frame,
                                    HxWx4) as a grey layer near the frame's own shadow Mf = grey(...): an
                                    alternative (it sometimes reads better on dark backdrops), never the default
  strip_shadow(I, A) -> A           an alpha with the shadow taken out: 0 outside the silhouette where the plate
                                    darkens achromatically and smoothly; strands (fine texture) and anything
                                    lighter than the plate keep theirs (a GPT object never carries a shadow)
  despill(I, A, F) -> F             the screen colour out of F everywhere on a chroma screen (F itself otherwise)
  screen(I) -> "green"|"blue"|"red"|None    the backdrop's chroma screen, None on white, grey or any neutral one
  save_layer(M, path)               8-bit RGBA: RGB = the layer, alpha 255 where it darkens (multiply it under the
                                    subject: CSS mix-blend-mode multiply)
Pass plate=Plate(I) to share one plate fit between calls on the same frame (each fit is ~0.3 s at 1080p).
"""
from __future__ import annotations

import cv2
import numpy as np
from scipy import ndimage as ndi

EXT = 6  # px the clean layer reaches in under the subject, from broad shadows only
BROAD = 4  # px: a darkening narrower than 2*BROAD+1 that joins no broader one is not shadow
DIV_MIN = 0.15  # a plate channel this dark (a chroma screen's) is noise to divide by: no tint from it
CARRY_SIGMAS = (1.5, 3, 6, 12, 24, 48, 96)  # px: the blurs that carry a layer under the subject's soft edge
TINT_AT = 0.05  # the tint comes in fully at this much darkening; fainter, the plate's noise would colour it
GPT_REACH = 25  # px: GPT's drawn shadow is kept this far around the frame's own shadow
TEX_SIGMA, TEX_WIN = 1.5, 3.0  # px: strand scale of the high-pass, and the window its energy is averaged over
TEX_REL, TEX_K = 0.1, 2.0  # strands: texture energy above this share of the darkening and this x the noise
LUMA = np.array([0.299, 0.587, 0.114], np.float32)


# ---------------------------------------------------------------- the plate

def _poly_terms(x, y, deg):
    return np.stack([x ** i * y ** j for i in range(deg + 1) for j in range(deg + 1 - i)], -1)


def estimate_plate(I, deg=3, iters=4, rows=False):
    """I HxWx3 -> (B, sigma, mask_small): a smooth polynomial surface per channel fitted to backdrop pixels (border
    first, then every pixel that fits), so sweeps and vignettes are modelled.
    rows: add a per-row correction (median residual of backdrop pixels, smoothed): a cyclorama's horizon bend is
    sharper than a cubic and otherwise reads as a faint shadow band across the frame."""
    H, W, _ = I.shape
    s = 8
    small = cv2.resize(I, (max(W // s, 4), max(H // s, 4)), interpolation=cv2.INTER_AREA)
    h, w, _ = small.shape
    yy, xx = np.mgrid[0:h, 0:w]
    xn, yn = xx / (w - 1) * 2 - 1, yy / (h - 1) * 2 - 1
    A = _poly_terms(xn, yn, deg).reshape(-1, (deg + 1) * (deg + 2) // 2)
    ring = np.zeros((h, w), bool)
    b = max(2, int(0.05 * min(h, w)))
    ring[:b], ring[-b:], ring[:, :b], ring[:, -b:] = True, True, True, True
    # border pixels that are not the subject running off the frame: near the ring's median colour
    med = np.median(small[ring], 0)
    mask = ring & (np.linalg.norm(small - med, axis=-1) < 0.12)
    if mask.sum() < A.shape[1]:
        mask = ring
    coef = None
    for _ in range(iters):
        coef, *_ = np.linalg.lstsq(A[mask.ravel()], small.reshape(-1, 3)[mask.ravel()], rcond=None)
        fit = (A @ coef).reshape(h, w, 3)
        r = np.linalg.norm(small - fit, axis=-1)
        sig = 1.4826 * np.median(np.abs(r[mask] - np.median(r[mask]))) + np.median(r[mask])
        nxt = r < max(4 * sig, 0.02)
        if nxt.sum() < A.shape[1]:
            break
        mask = nxt
    Y, X = np.mgrid[0:H, 0:W]
    Af = _poly_terms(X / (W - 1) * 2 - 1, Y / (H - 1) * 2 - 1, deg)
    B = np.clip(Af @ coef, 0, 1).astype(np.float32)
    bgfull = cv2.resize(mask.astype(np.uint8), (W, H), interpolation=cv2.INTER_NEAREST).astype(bool)
    if rows:
        res = I - B
        corr = np.full((H, 3), np.nan, np.float32)
        for y in range(H):
            m = bgfull[y]
            if m.sum() > 0.1 * W:
                corr[y] = np.median(res[y, m], 0)
        ok = ~np.isnan(corr[:, 0])
        if ok.sum() > 2:
            for c in range(3):
                corr[:, c] = np.interp(np.arange(H), np.flatnonzero(ok), corr[ok, c])
            corr = ndi.gaussian_filter1d(corr, 4, axis=0)
            B = np.clip(B + corr[:, None, :], 0, 1).astype(np.float32)
    r_full = np.linalg.norm(I - B, axis=-1)
    sample = r_full[bgfull]
    sigma = float(np.percentile(sample, 99)) if sample.size else 0.02
    return B, max(sigma, 2.0 / 255), mask


class Plate:
    """one frame's plate fits, each computed once: fit(rows) -> (B, sigma, mask)"""

    def __init__(self, I):
        self.I, self._fits = I, {}

    def fit(self, rows=False):
        if rows not in self._fits:
            self._fits[rows] = estimate_plate(self.I, rows=rows)
        return self._fits[rows]


def _plate(I, plate):
    return plate if plate is not None else Plate(I)


def _screen_channel(B):
    """the chroma screen's channel (red 0, green 1, blue 2) when the plate is one, else None"""
    c = int(np.argmax(np.median(B.reshape(-1, 3), 0)))
    o = [i for i in range(3) if i != c]
    return c if float(np.median(B[..., c] - np.maximum(B[..., o[0]], B[..., o[1]]))) >= 0.15 else None


def screen(I, plate=None):
    c = _screen_channel(_plate(I, plate).fit()[0])
    return None if c is None else ("red", "green", "blue")[c]


def despill(I, A, F, plate=None):
    """F with the screen's colour taken out everywhere: the screen channel no higher than the mean of the other two
    (Egor 2026-11-07: a colour lost in a shadow or glow costs little, a screen colour left there is a defect; sparing
    the opaque body left a green strip where a glow joins a bumper, green blotches on a car and a cast on a dog's
    chest). F itself when the plate is no chroma screen"""
    c = _screen_channel(_plate(I, plate).fit()[0])
    if c is None:
        return F
    o = [i for i in range(3) if i != c]
    Fd = F.copy()
    Fd[..., c] = np.minimum(F[..., c], (F[..., o[0]] + F[..., o[1]]) / 2)
    return Fd


# ---------------------------------------------------------------- the shadow zone and the clean layer

def _zone(I, soft, plate):
    """(B, zone, M): outside the silhouette (holes filled, +2 px), where the keyer is below 0.5, an achromatic change
    of the plate (I/B along the plate's colour) is shadow or floor light, never subject; plus whatever the keyer
    itself calls backdrop there (< 0.05) even if chromatic (the floor's reflection of the subject). M = the darkening
    there above the plate's noise floor (a ramp, no step), reaching EXT px in under the edge from broad shadows only"""
    B, s, _ = plate.fit(rows=True)
    outside = ~ndi.binary_dilation(ndi.binary_fill_holes(soft > 0.5), iterations=2)
    bb = np.maximum((B * B).sum(-1), 1e-4)
    rm = (I * B).sum(-1) / bb
    off = np.linalg.norm(I - rm[..., None] * B, axis=-1) / np.sqrt(bb)
    zone = outside & (soft < 0.5) & ((off < 0.04 + 0.1 * np.abs(1 - rm)) | (soft < 0.05))
    noise = float(np.median(np.linalg.norm(I - B, axis=-1)[zone])) if zone.any() else s
    fl = 3 * noise / np.sqrt(bb)
    d = 1 - rm
    M = np.where(zone, 1 - np.clip(d, 0, 1) * np.clip((d - fl / 2) / np.maximum(fl / 2, 1e-4), 0, 1), 1.0)
    M = M.astype(np.float32)
    dist, (iy, ix) = ndi.distance_transform_edt(~zone, return_indices=True)
    broad = ndi.binary_opening(zone & (M < 0.99), iterations=2)
    M = np.where(zone | (dist > EXT) | ~broad[iy, ix], M, M[iy, ix])
    return B, zone, cv2.GaussianBlur(M, (0, 0), 0.8).astype(np.float32)


def strip_shadow(I, A, plate=None):
    """A with 0 where it holds a shadow: in the zone (outside the silhouette, the plate only darkening
    achromatically), darker than the plate, and smooth in the frame. Strands are not: dark curls on white and blonde
    flyaways on grey sit in the zone too (the GPT chat's test, 2026-11-08: 40778 px of a curly halo zeroed), but they
    are fine high-contrast texture, the darkening's high-pass energy above TEX_REL of the darkening itself and above
    the plate's noise (hair 0.27-0.73, a floor shadow 0.007-0.014). Lighter than the plate is never shadow: the
    multiply layer cannot carry it, stripped it would be lost"""
    plate = _plate(I, plate)
    B, zone, _ = _zone(I, A, plate)
    bb = np.maximum((B * B).sum(-1), 1e-4)
    d = 1 - (I * B).sum(-1) / bb
    noise = float(np.median(np.linalg.norm(I - B, axis=-1)[zone] / np.sqrt(bb[zone]))) if zone.any() else 0.0
    e = cv2.GaussianBlur(np.abs(d - cv2.GaussianBlur(d, (0, 0), TEX_SIGMA)), (0, 0), TEX_WIN)
    strands = (e > TEX_REL * cv2.GaussianBlur(np.abs(d), (0, 0), TEX_WIN)) & (e > TEX_K * noise)
    return np.where(zone & (d > 0) & ~strands, 0.0, A).astype(np.float32)


def _carry(x, under):
    """x under `under` from the values outside it: their weighted blur at growing scales, each next scale weighted 10x
    less, so near the edge the nearest values rule and deep inside a wide average fills smoothly (the nearest pixel
    alone copies a row into stripes)"""
    w = (~under).astype(np.float32)
    x3 = x if x.ndim == 3 else x[..., None]
    num, den = np.zeros_like(x3, dtype=np.float32), np.zeros(x3.shape[:2] + (1,), np.float32)
    for k, sig in enumerate(CARRY_SIGMAS):
        a = 0.1 ** k
        num += a * cv2.GaussianBlur((x3 * w[..., None]).astype(np.float32), (0, 0), sig).reshape(x3.shape)
        den += a * cv2.GaussianBlur(w, (0, 0), sig)[..., None]
    fill = num / np.maximum(den, 1e-12)
    out = np.where(under[..., None], fill, x3)
    return out if x.ndim == 3 else out[..., 0]


# ---------------------------------------------------------------- the layers

def grey(I, A, F, plate=None):
    """the default shadow layer (bench «explain», scored best against the Blender truth)"""
    plate = _plate(I, plate)
    _, _, M = _zone(I, A, plate)
    keep = A > 0.02
    B = plate.fit()[0]
    body = ndi.binary_dilation(ndi.binary_fill_holes(A > 0.5), iterations=2)
    w = np.maximum(1 - A, 1e-3)
    bb = np.maximum((B * B).sum(-1), 1e-4)
    m = np.clip(((I - A[..., None] * F) * B).sum(-1) / (w * bb), 0, 1)
    out = np.where(keep & ~body, m, M)
    # under the body's own soft edge the layer takes the values outside it: a 1 there left a light seam wherever the
    # keyer's edge meets a shadow (tyres on the Blender floor)
    return cv2.GaussianBlur(_carry(out, keep & body).astype(np.float32), (0, 0), 0.8)


def colour(I, A, F, plate=None):
    """grey's depth, the frame/plate ratio per channel for its colour, broad darkening only (a missed strand or a
    logo's antialiased ring never becomes shadow); 1 where A is solid"""
    plate = _plate(I, plate)
    M1 = grey(I, A, F, plate)
    body = ndi.binary_dilation(ndi.binary_fill_holes(A > 0.5), iterations=2)
    dark = (1 - M1) > 2 / 255
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * BROAD + 1, 2 * BROAD + 1))
    seed = cv2.morphologyEx((dark & ~body).astype(np.uint8), cv2.MORPH_OPEN, k).astype(bool)
    broad = ndi.binary_propagation(seed, mask=dark)
    soft = np.clip(cv2.GaussianBlur(broad.astype(np.float32), (0, 0), 1.0) * 2, 0, 1)
    M1 = 1 - (1 - M1) * soft
    B = plate.fit()[0]
    w = np.maximum(1 - A, 1e-3)[..., None]
    R3 = np.clip((I - A[..., None] * F) / (w * np.maximum(B, 1e-3)), 0, 1.5)
    ok = B > DIV_MIN  # a pure screen's dark channels divide noise: they take the bright channels' ratio
    R3 = np.where(ok, R3, (R3 * ok).sum(-1, keepdims=True) / np.maximum(ok.sum(-1, keepdims=True), 1))
    R3 = cv2.GaussianBlur(R3.astype(np.float32), (0, 0), 1.5)
    tint = R3 / np.maximum(R3.mean(-1, keepdims=True), 1e-3)
    wt = np.clip((1 - M1) / TINT_AT, 0, 1)[..., None]
    tint = 1 + (tint - 1) * wt
    # a chroma screen bounces its own colour into the shadow, and a plate fit a bit too green reads as its opposite
    # (pink): the screen channel takes the other two's mean; other colours (a car's orange or violet bounce) stay
    c = _screen_channel(B)
    if c is not None:
        o = [i for i in range(3) if i != c]
        tint[..., c] = (tint[..., o[0]] + tint[..., o[1]]) / 2
    tint = _carry(tint, (A > 0.02) & body)  # under the body's soft edge the ratio is the keyer's guess
    M3 = np.clip(M1[..., None] * tint, 0, 1)
    return np.where((A >= 0.999)[..., None], 1.0, M3).astype(np.float32)


def gpt_shadow(gpt_rgba, A, Mf):
    """GPT's drawn shadow as a grey layer. Outside the keyer's body (holes filled) it is GPT's render over white,
    GPT's own object included where it reaches past the keyer's (its drawn tyre contact). Under the keyer's body the
    layer is the frame's own Mf: GPT's strands there doubled the keyer's and an outline-closed gap came out as a light
    hard-edged patch (curls, chiffon). Only near the frame's own shadow (Mf below 0.98, GPT_REACH px around, soft),
    so GPT's strands flying past the outline never read as shadow"""
    g = gpt_rgba
    Mg = 1 - g[..., 3] * (1 - np.clip(g[..., :3] @ LUMA, 0, 1))
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * GPT_REACH + 1, 2 * GPT_REACH + 1))
    zone = cv2.GaussianBlur(cv2.dilate((Mf < 0.98).astype(np.uint8), k).astype(np.float32), (0, 0), GPT_REACH / 3)
    Mg = 1 - zone * (1 - Mg)
    inside = cv2.GaussianBlur(ndi.binary_fill_holes(A > 0.5).astype(np.float32), (0, 0), 2.0)
    return np.clip(inside * Mf + (1 - inside) * Mg, 0, 1).astype(np.float32)


def save_layer(M, path):
    """M HxW (grey) or HxWx3 (colour) -> 8-bit RGBA PNG: RGB the layer, alpha 255 where any channel darkens"""
    from PIL import Image
    M3 = M if M.ndim == 3 else np.repeat(M[..., None], 3, -1)
    m8 = (np.clip(M3, 0, 1) * 255 + 0.5).astype(np.uint8)
    a = np.where(m8.min(-1) < 255, 255, 0).astype(np.uint8)
    Image.fromarray(np.dstack([m8, a]), "RGBA").save(path)
