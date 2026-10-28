// compare: synced loupes over an original and its variants (or two variants, pairwise), a preview
// with clipped view boxes, vote options and per-side tags; mode `view` is a numbered grid. The spec
// is in compare.md. Ported from logo-vectorizer-bench vote.tpl.html: one shared view state L for
// every loupe, zoom anchored at the pointer, and drags that end whichever way the pointer leaves.
// Geometry is the reference image's natural size (the original, else the largest variant); every
// image is drawn over that box (or a variant's `box` in it), so a smaller pixel-art variant lands on
// the same coordinates at the same scale.
import { h, get, save, textBox, onState, doneWhen, nextOpen, firstOpen, capped, keys, lazy, num } from "/kit/shell.js";

const CSS = `
.strip{display:flex;flex-wrap:wrap;gap:3px;margin-bottom:8px}
.strip i{min-width:24px;padding:0 4px;border-radius:4px;background:var(--line);color:var(--mute);font:600 11px/18px system-ui;text-align:center;font-style:normal;cursor:pointer}
.strip i.v{background:var(--accent);color:var(--bg)}.strip i.cur{outline:2px solid var(--ink)}
.upper{display:flex;gap:16px;align-items:flex-start}
.pv{display:flex;gap:6px;flex:none}
.pc{position:relative;overflow:hidden;border-radius:6px;cursor:crosshair;background:#fff;outline:1px solid var(--line)}
.pc img{width:100%;height:100%;display:block;pointer-events:none}
.pc i{position:absolute;border:2px solid var(--accent);box-shadow:0 0 0 1px #fff;pointer-events:none}
.side{flex:1 1 340px;min-width:340px;display:flex;flex-direction:column;gap:8px}
.ttl{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:8px}.nav{display:flex;gap:6px;align-items:center}
.q{padding:6px 10px;border-left:3px solid var(--accent);background:var(--card);border-radius:6px;font-size:14px;white-space:pre-line}
.votes{display:flex;gap:8px;flex-wrap:wrap}.votes button{flex:1 0 auto;font-size:17px;font-weight:600;padding:8px;white-space:nowrap}
.trow,.tools{display:flex;gap:6px;flex-wrap:wrap;align-items:center}.trow b{width:16px}.trow button,.tools button{padding:3px 10px;font-size:13px}
.lrow{display:grid;gap:8px;margin-top:10px}
.vp{position:relative;overflow:hidden;height:var(--lh,480px);background:#fff;border-radius:6px;cursor:grab;touch-action:none;user-select:none;-webkit-user-select:none;outline:1px solid var(--line)}
body.drag,body.drag .vp{cursor:grabbing}
.vp img{position:absolute;left:0;top:0;max-width:none;transform-origin:0 0;pointer-events:none;-webkit-user-drag:none}
.bd{position:absolute;left:6px;top:4px;display:flex;gap:4px;z-index:1;pointer-events:none;font:600 12px/1.4 system-ui}
.bd span{background:rgba(0,0,0,.6);color:#fff;padding:1px 6px;border-radius:4px}.bd span:first-child{font-size:14px}
.vp canvas{position:absolute;left:0;top:0;pointer-events:none}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:10px}
.gc{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:8px;cursor:pointer}
.gi{display:flex;gap:4px;margin-top:4px}.gi figure{margin:0;flex:1;min-width:0}
.gi img{width:100%;max-height:240px;object-fit:contain;background:#fff;border-radius:4px;display:block}
.gi figcaption{font-size:12px;color:var(--mute);text-align:center}
@media (max-width:900px){.upper{flex-direction:column}}`;
const LETTERS = "ABCDEFGHIJ", KEYS = { A: "KeyA", B: "KeyB", tie: "KeyT" }, LINE = "rgba(0,229,255,.8)";
const app = document.getElementById("app");
let S, ids, cur = null, E = null, L = null, geo = null, drag = null, token = 0, lastW = 0, lines = false;
const hot = new Map();

export function render(spec) {
  S = spec;
  ids = S.items.map((it) => it.id);
  if (!document.getElementById("cmp-css")) document.head.append(h("style", { id: "cmp-css" }, CSS));
  const view = S.mode === "view";
  doneWhen(view ? null : (id) => get(id, "choice") != null);
  onState((changed) => { if (E && changed.has(cur)) paintSide(); if (E) strip(); });
  keys(keymap());
  if (cur !== null && !ids.includes(cur)) cur = null;
  if (cur === null && !view) cur = firstOpen(ids) ?? ids[0];
  if (cur === null) grid(); else show(cur, true);
}

const item = (id) => S.items.find((it) => it.id === id);
const opts = () => (S.options || [...((item(cur) || S.items[0]).variants || []).map((v, i) => ({ id: v.slot || LETTERS[i] })),
  { id: "tie", label: "=" }]).map((o) => ({ ...o, key: o.key ?? KEYS[o.id] }));

function frames(it) {
  const vs = (it.variants || []).map((v, i) => ({ src: v.src, side: v.slot || LETTERS[i],
    name: S.blind ? "" : v.label || "", meta: v.meta || "", box: v.box }));
  return it.original ? [{ src: it.original, side: "", name: "оригинал", meta: "" }, ...vs] : vs;
}

function keymap() {
  const m = { ArrowLeft: () => go(-1), ArrowRight: () => go(1), Digit0: fitView,
    Equal: () => zoomBy(1.5), Minus: () => zoomBy(1 / 1.5), Escape: () => S.mode === "view" && grid(),
    KeyG: () => E && E.gb && toggleLines() };
  for (let k = 1; k <= 9; k++) m["Digit" + k] = (S.zoom_levels || [])[k - 1] != null ? () => level(k - 1) : () => jump(k - 1);
  if (S.mode !== "view") for (const o of (S.items.length ? opts() : [])) if (o.key) m[o.key] = () => vote(o.id);
  return m;
}

function grid() {
  cur = null; E = null; geo = null; L = null;
  app.replaceChildren(h("div", { class: "grid" }, S.items.map((it, i) => h("div", { class: "gc", onclick: () => show(it.id) },
    h("b", {}, `${num(it, i)}`), it.title ? h("span", { class: "mute" }, " · " + it.title) : null,
    h("div", { class: "gi" }, frames(it).map((f) => h("figure", {},
      lazy(h("img", { "data-src": f.src, alt: "", loading: "lazy" })), h("figcaption", {}, [f.side, f.name].filter(Boolean).join(" · ")))))))));
}

function show(id, keepView) {
  const it = item(id), i = ids.indexOf(id), fs = frames(it), my = ++token, voting = S.mode !== "view";
  if (cur !== id || !keepView) { L = null; geo = null; }
  cur = id;
  const vps = fs.map((f) => h("div", { class: "vp", ondblclick: fitView },
    h("div", { class: "bd" }, h("span", {}, f.side || f.name), f.side && f.name ? h("span", {}, f.name) : null,
      f.meta ? h("span", {}, f.meta) : null, h("span", { class: "dim" })),
    h("img", { src: f.src, alt: "", draggable: false }), h("canvas")));
  const cells = fs.map(() => h("div", { class: "pc", onclick: aim }, h("img", { alt: "", draggable: false }), h("i")));
  E = { vps, cells, imgs: vps.map((v) => v.querySelector("img")), boxes: cells.map((c) => c.querySelector("i")),
    hs: h("span", { class: "tools" }), strip: h("div", { class: "strip" }), cvs: vps.map((v) => v.querySelector("canvas")),
    gb: S.pixel_grid || it.grid ? h("button", { onclick: toggleLines, title: "G" }, "Сетка") : null,
    pos: h("span", { class: "mute num" }), votes: null, tags: [], sg: h("span", { class: "sg", hidden: true }),
    lv: (S.zoom_levels || []).map((z, k) => h("button", { onclick: () => level(k), title: k < 9 ? `${k + 1}` : null }, `${z}×`)) };
  E.votes = voting ? h("div", { class: "votes" }, opts().map((o) =>
    h("button", { "data-v": o.id, onclick: () => vote_(o.id) }, o.label || o.id))) : null;
  E.tags = voting && S.tags ? fs.filter((f) => f.side).map((f) => h("div", { class: "trow", "data-side": f.side },
    h("b", {}, f.side), S.tags.map((t) => h("button", { "data-t": t, onclick: () => tag(f.side, t) }, t)))) : [];
  const nav = h("span", { class: "nav" }, S.mode === "view" ? h("button", { onclick: grid, title: "Esc" }, "▦") : null,
    h("button", { onclick: () => go(-1) }, "←"), E.pos, h("button", { onclick: () => go(1) }, "→"));
  // with zoom_levels the first level fits and the digits are taken, so no fit button and no hotspots
  const tools = h("div", { class: "tools" }, E.lv, S.zoom_levels ? null : [E.hs, h("button", { onclick: fitView, title: "0" }, "целиком")], E.gb);
  app.replaceChildren(E.strip, h("div", { class: "upper" }, h("div", { class: "pv" }, cells),
    h("div", { class: "side" }, h("div", { class: "ttl" }, h("strong", {}, `${num(it, i)}${it.title ? " · " + it.title : ""}`), nav),
      it.q ? h("div", { class: "q" }, it.q) : null, E.votes, E.sg, E.tags, tools,
      textBox(id, "note", { placeholder: "заметка" }))),
    h("div", { class: "lrow", style: `grid-template-columns:repeat(${fs.length},1fr)` }, vps));
  vps.forEach(wire);
  paintSide(); strip(); layout();
  Promise.all(E.imgs.map((im) => im.complete ? 0 : new Promise((r) => { im.onload = im.onerror = r; }))).then(() => {
    if (my !== token) return;
    const ref = it.original ? E.imgs[0] : E.imgs.reduce((a, b) => (b.naturalWidth * b.naturalHeight > a.naturalWidth * a.naturalHeight ? b : a));
    geo = { w: ref.naturalWidth || 1, h: ref.naturalHeight || 1 };
    E.imgs.forEach((im, k) => {
      E.cells[k].querySelector("img").src = im.src;
      E.cells[k].style.aspectRatio = `${geo.w}/${geo.h}`;
      vps[k].querySelector(".dim").textContent = im.naturalWidth ? `${im.naturalWidth}×${im.naturalHeight}` : "—";
    });
    layout();
    if (!L) L = fit();
    draw();
    E.spots = hotspots(it);
    E.hs.replaceChildren(...E.spots.map((_, k) => h("button", { onclick: () => jump(k) }, `${k + 1}`)));
  });
  const nx = item(ids[(i + 1) % ids.length]);
  if (nx !== it) frames(nx).forEach((f) => { new Image().src = f.src; });
}

function paintSide() {
  if (!E) return;
  const it = item(cur), c = get(cur, "choice"), tg = get(cur, "tags") || {};
  E.pos.textContent = `${ids.indexOf(cur) + 1} / ${ids.length}`;
  if (E.votes) E.votes.querySelectorAll("button").forEach((b) => b.classList.toggle("on", b.dataset.v === c));
  E.tags.forEach((row) => row.querySelectorAll("button").forEach((b) => b.classList.toggle("on", (tg[row.dataset.side] || []).includes(b.dataset.t))));
  const sg = it.suggest && (typeof it.suggest === "object" ? it.suggest.choice : it.suggest);
  E.sg.hidden = sg == null;
  E.sg.textContent = sg == null ? "" : String(sg);
}

function strip() {
  E.strip.replaceChildren(...S.items.map((it, i) => h("i", { class: (get(it.id, "choice") != null ? "v " : "") + (it.id === cur ? "cur" : ""),
    title: it.title || it.id, onclick: () => show(it.id) }, `${num(it, i)}`)));
}

function vote_(o) {
  const was = get(cur, "choice");
  if (was === o) return;
  save(cur, { choice: o });
  paintSide(); strip();
  if (was != null || capped()) return;
  const at = cur;
  setTimeout(() => { const n = cur === at && nextOpen(ids, ids.indexOf(cur)); if (n && n !== cur) show(n); }, 350);
}
function vote(o) { if (E && E.votes) vote_(o); }

function tag(side, t) {
  const all = { ...(get(cur, "tags") || {}) }, set = new Set(all[side] || []);
  if (set.has(t)) set.delete(t); else set.add(t);
  if (set.size) all[side] = [...set]; else delete all[side];
  save(cur, { tags: Object.keys(all).length ? all : null });
  paintSide();
}

function go(d) { if (cur !== null) show(ids[(ids.indexOf(cur) + d + ids.length) % ids.length]); }

const size = () => ({ W: E.vps[0].clientWidth, H: E.vps[0].clientHeight });
function fit() { const { W, H } = size(); return { cx: geo.w / 2, cy: geo.h / 2, z: Math.min(W / geo.w, H / geo.h) }; }
const clampZ = (z) => Math.min(64, Math.max(fit().z / 4, z));
function setL(v) { if (geo) { L = v; draw(); } }
const fitView = () => geo && setL(fit());
function zoomBy(k) { if (geo) setL({ ...L, z: clampZ(L.z * k) }); }
function jump(k) {
  const hs = geo && E.spots;
  if (hs && hs[k]) setL({ cx: hs[k][0], cy: hs[k][1], z: clampZ(Math.max(fit().z * 2, size().W / 256)) });
}
// zoom_levels[k] as the original's magnification; the first level pressed again fits the view
function toggleLines() { lines = !lines; draw(); }
function level(k) {
  const z = (S.zoom_levels || [])[k];
  if (geo && L && z != null) setL(k === 0 && L.z === z ? fit() : { ...L, z });
}

function aim(e) {
  if (!geo) return;
  const r = e.currentTarget.getBoundingClientRect(), k = geo.w / r.width;
  setL({ ...L, cx: (e.clientX - r.left) * k, cy: (e.clientY - r.top) * k });
}

function wire(vp) {
  vp.onpointerdown = (e) => {
    if (e.button !== 0 || !L) return;
    e.preventDefault();
    drag = [e.clientX, e.clientY];
    document.body.classList.add("drag");
    try { vp.setPointerCapture(e.pointerId); } catch (_) { /* pointer already gone */ }
  };
  vp.onlostpointercapture = endDrag;
  vp.addEventListener("wheel", (e) => {
    if (!L) return;
    e.preventDefault();
    const b = vp.getBoundingClientRect(), px = e.clientX - b.left - b.width / 2, py = e.clientY - b.top - b.height / 2;
    const d = e.deltaY * (e.deltaMode === 1 ? 16 : 1), nz = clampZ(L.z * Math.exp(-d * (e.ctrlKey ? 0.01 : 0.002)));
    setL({ cx: L.cx + px / L.z - px / nz, cy: L.cy + py / L.z - py / nz, z: nz });
  }, { passive: false });
}
function endDrag() { drag = null; document.body.classList.remove("drag"); }
addEventListener("pointermove", (e) => {
  if (!drag) return;
  if (!(e.buttons & 1)) return endDrag();
  setL({ ...L, cx: L.cx - (e.clientX - drag[0]) / L.z, cy: L.cy - (e.clientY - drag[1]) / L.z });
  drag = [e.clientX, e.clientY];
});
addEventListener("pointerup", endDrag);
addEventListener("pointercancel", endDrag);
addEventListener("blur", endDrag);
addEventListener("resize", () => {
  if (!E) return;
  const w = lastW;
  layout();
  if (L && w) L.z *= E.vps[0].clientWidth / w;
  draw();
});

function layout() {
  if (!E) return;
  if (geo) {
    const n = E.cells.length, room = Math.max(160, app.clientWidth - 32 - 356 - 6 * (n - 1));
    const ch = Math.min(innerHeight * 0.24, 180, room / n / (geo.w / geo.h));
    E.cells.forEach((c) => { c.style.height = ch + "px"; });
  }
  // measured after the previews take their height, which moves the loupe row
  const row = E.vps[0].parentNode, top = row.getBoundingClientRect().top + scrollY;
  document.documentElement.style.setProperty("--lh", Math.max(300, innerHeight - top - 16) + "px");
  lastW = E.vps[0].clientWidth;
}

function draw() {
  if (!E || !geo || !L) return;
  const { W, H } = size(), pix = String(S.pixelated ?? "auto"), first = item(cur).original ? 1 : 0, fs = frames(item(cur));
  // where each image's pixel grid lands in its loupe: origin and screen px per image px on each axis
  const at = E.imgs.map((im, i) => {
    const nw = im.naturalWidth, nh = im.naturalHeight, [bx, by, bx1, by1] = fs[i].box || [0, 0, geo.w, geo.h];
    const x = W / 2 + (bx - L.cx) * L.z, y = H / 2 + (by - L.cy) * L.z, w = (bx1 - bx) * L.z, hh = (by1 - by) * L.z;
    Object.assign(im.style, { width: w + "px", height: hh + "px", transform: `translate(${x}px,${y}px)` });
    const k = w / (nw || geo.w);
    im.style.imageRendering = pix === "true" || (pix !== "false" && k >= 3) ? "pixelated" : "auto";
    return nw ? { x, y, sx: w / nw, sy: hh / nh, nw, nh } : null;
  });
  E.lv.forEach((b, k) => b.classList.toggle("on", L.z === S.zoom_levels[k]));
  if (E.gb) paintLines(W, H, at, first);
  const x0 = Math.max(0, L.cx - W / 2 / L.z), x1 = Math.min(geo.w, L.cx + W / 2 / L.z);
  const y0 = Math.max(0, L.cy - H / 2 / L.z), y1 = Math.min(geo.h, L.cy + H / 2 / L.z);
  E.boxes.forEach((b) => {
    const k = b.parentNode.clientWidth / geo.w;
    Object.assign(b.style, { display: x1 > x0 && y1 > y0 ? "block" : "none", left: x0 * k + "px", top: y0 * k + "px",
      width: (x1 - x0) * k + "px", height: (y1 - y0) * k + "px" });
  });
}

// «Сетка»: the item's `grid` (cell bounds in the original's pixels) over the original, and each variant's own
// pixel grid in its loupe; a grid whose cells are under 5 screen px is left out
function paintLines(W, H, at, first) {
  const d = devicePixelRatio || 1, it = item(cur);
  E.gb.classList.toggle("on", lines);
  E.cvs.forEach((c, i) => {
    Object.assign(c, { width: Math.round(W * d), height: Math.round(H * d) });
    Object.assign(c.style, { width: W + "px", height: H + "px" });
    const a = at[i];
    let xs, ys;
    if (!lines) return;
    if (i < first) {
      if (!it.grid) return;
      xs = it.grid.x.map((v) => W / 2 + (v - L.cx) * L.z);
      ys = it.grid.y.map((v) => H / 2 + (v - L.cy) * L.z);
    } else if (a) {
      xs = Array.from({ length: a.nw + 1 }, (_, k) => a.x + k * a.sx);
      ys = Array.from({ length: a.nh + 1 }, (_, k) => a.y + k * a.sy);
    } else return;
    if (Math.min((xs.at(-1) - xs[0]) / (xs.length - 1), (ys.at(-1) - ys[0]) / (ys.length - 1)) < 5) return;
    const g = c.getContext("2d"), px = (v) => Math.round(v * d) + 0.5;
    const [x0, x1, y0, y1] = [Math.max(0, px(xs[0])), Math.min(c.width, px(xs.at(-1))), Math.max(0, px(ys[0])), Math.min(c.height, px(ys.at(-1)))];
    g.strokeStyle = LINE; g.lineWidth = 1; g.beginPath();
    for (const x of xs) { const v = px(x); if (v >= 0 && v <= c.width) { g.moveTo(v, y0); g.lineTo(v, y1); } }
    for (const y of ys) { const v = px(y); if (v >= 0 && v <= c.height) { g.moveTo(x0, v); g.lineTo(x1, v); } }
    g.stroke();
  });
}

// Up to 9 places where the variants differ most: 8 px blocks of |variant − first variant| on a
// ≤192 px copy, each pick clearing its neighbours (mkvote.py hot() in the browser).
function hotspots(it) {
  const key = E.imgs.map((im) => im.src).join("\n");
  if (it.hotspots && it.hotspots.length) return it.hotspots;
  if (hot.has(key)) return hot.get(key);
  const vs = E.imgs.slice(it.original ? 1 : 0).filter((im) => im.naturalWidth), out = [];
  try {
    if (vs.length < 2) throw 0;
    const s = Math.min(1, 192 / Math.max(geo.w, geo.h)), w = Math.max(1, Math.round(geo.w * s)), hh = Math.max(1, Math.round(geo.h * s));
    const px = vs.map((im) => {
      const g = h("canvas", { width: w, height: hh }).getContext("2d", { willReadFrequently: true });
      g.drawImage(im, 0, 0, w, hh);
      return g.getImageData(0, 0, w, hh).data;
    });
    const B = 8, gw = Math.ceil(w / B), gh = Math.ceil(hh / B), d = new Float64Array(gw * gh);
    for (let y = 0; y < hh; y++) for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 4;
      let t = 0;
      for (let v = 1; v < px.length; v++) for (let c = 0; c < 3; c++) t += Math.abs(px[v][o + c] - px[0][o + c]);
      d[((y / B) | 0) * gw + ((x / B) | 0)] += t;
    }
    while (out.length < 9) {
      let bi = 0;
      for (let k = 1; k < d.length; k++) if (d[k] > d[bi]) bi = k;
      if (d[bi] < B * B * 6) break;
      const bx = bi % gw, by = (bi / gw) | 0;
      out.push([Math.min(geo.w, Math.round((bx + 0.5) * B / s)), Math.min(geo.h, Math.round((by + 0.5) * B / s))]);
      for (let y = by - 2; y <= by + 2; y++) for (let x = bx - 2; x <= bx + 2; x++)
        if (x >= 0 && y >= 0 && x < gw && y < gh) d[y * gw + x] = 0;
    }
  } catch (e) { /* fewer than two variants, or an image the canvas cannot read: no hotspots */ }
  hot.set(key, out);
  return out;
}
