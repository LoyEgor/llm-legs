// compare: synced loupes over an original and its variants (or two variants, pairwise), a preview
// with clipped view boxes, vote options and per-side tags; mode `view` is a numbered grid. The spec
// is in compare.md. Ported from logo-vectorizer-bench vote.tpl.html: one shared view state L for
// every loupe, zoom anchored at the pointer, and drags that end whichever way the pointer leaves.
// Geometry is the reference image's natural size (the original, else the largest variant); every
// image is drawn over that box (or a variant's `box` in it), so a smaller pixel-art variant lands on
// the same coordinates at the same scale.
import { h, get, save, textBox, onState, doneWhen, nextOpen, firstOpen, capped, keys, lazy, num, attachPicture } from "/kit/shell.js";

const CSS = `
.strip{display:flex;flex-wrap:wrap;gap:3px;margin-bottom:8px}
.strip i{min-width:24px;padding:0 4px;border-radius:4px;background:var(--line);color:var(--mute);font:600 11px/18px system-ui;text-align:center;font-style:normal;cursor:pointer}
.strip i.v{background:var(--accent);color:var(--bg)}.strip i.cur{outline:2px solid var(--ink)}
.upper{display:flex;gap:16px;align-items:flex-start}
.pv{display:flex;gap:6px;flex:none}
.pc{position:relative;overflow:hidden;border-radius:6px;cursor:crosshair;background:#fff;outline:1px solid var(--line)}
.pc img{width:100%;height:100%;display:block;-webkit-user-drag:none}
.pc i{position:absolute;border:2px solid var(--accent);box-shadow:0 0 0 1px #fff;pointer-events:none}
.pc input,.vp>input{position:absolute;right:4px;top:4px;z-index:3;margin:0;width:16px;height:16px;cursor:pointer;accent-color:var(--accent)}.vp>input{right:6px;top:6px;width:18px;height:18px}.pc.off img{opacity:.35}
.side{flex:1 1 340px;min-width:340px;display:flex;flex-direction:column;gap:8px}
.ttl{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:8px}.nav{display:flex;gap:6px;align-items:center}
.q{padding:6px 10px;border-left:3px solid var(--accent);background:var(--card);border-radius:6px;font-size:14px;white-space:pre-line}
.votes{display:flex;gap:8px;flex-wrap:wrap}.votes button{flex:1 0 auto;font-size:17px;font-weight:600;padding:8px;white-space:nowrap}
.trow,.tools{display:flex;gap:6px;flex-wrap:wrap;align-items:center}.trow b{width:16px}.trow button,.tools button{padding:3px 10px;font-size:13px}
.lrow{display:grid;gap:8px;margin-top:10px}
.vp[hidden]{display:none}.vp{position:relative;overflow:hidden;height:var(--lh,480px);background:#fff;border-radius:6px;cursor:grab;touch-action:none;user-select:none;-webkit-user-select:none;outline:1px solid var(--line)}
body.drag,body.drag .vp{cursor:grabbing}
.vp img{position:absolute;left:0;top:0;max-width:none;transform-origin:0 0;-webkit-user-drag:none}
.bd{position:absolute;left:6px;top:4px;display:flex;gap:4px;z-index:1;pointer-events:none;font:600 12px/1.4 system-ui}
.vp:has(>input) .bd{right:30px}.bd span{background:rgba(0,0,0,.6);color:#fff;padding:1px 6px;border-radius:4px}.bd span:first-child{font-size:14px}
.vp canvas{position:absolute;left:0;top:0;pointer-events:none}
.pc .mk{position:absolute;border:2px solid #f0f;box-sizing:border-box;pointer-events:none}
body.pin .vp{cursor:crosshair}.vp .band{position:absolute;border:1px dashed #f0f;background:rgba(255,0,255,.08);pointer-events:none;z-index:2}
.pins{position:absolute;inset:0;pointer-events:none;overflow:hidden}.pins div{position:absolute;box-sizing:border-box;border:2px solid #f0f;box-shadow:0 0 0 1px #fff}
.pins div.pt{border-radius:50%}.pins div.far{border-style:dashed;opacity:.55;box-shadow:none}
.pins b{position:absolute;right:-2px;bottom:100%;background:#f0f;color:#fff;font:700 11px/14px system-ui;padding:0 4px;border-radius:3px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:10px}
.gc{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:8px;cursor:pointer}
.gi{display:flex;gap:4px;margin-top:4px}.gi figure{margin:0;flex:1;min-width:0}
.gi img{width:100%;max-height:240px;object-fit:contain;background:#fff;border-radius:4px;display:block}
.gi figcaption{font-size:12px;color:var(--mute);text-align:center}
@media (max-width:900px){.upper{flex-direction:column}}`;
const LETTERS = "ABCDEFGHIJ", KEYS = { A: "KeyA", B: "KeyB", tie: "KeyT" }, LINE = "rgba(0,229,255,.8)", MARK = "#f0f";
const app = document.getElementById("app");
let S, ids, cur = null, E = null, L = null, geo = null, drag = null, token = 0, lastW = 0, lines = false, marked = true;
let pinTool = false, pinning = null; // «Метка»: the tool's state, the mark being drawn
const coming = new Set(); // marks a running dictation took: shown before their names arrive in the note
const hot = new Map(), inked = new WeakSet(), off = new Set(); // off: frames whose loupe is hidden, by badge

export function render(spec) {
  S = spec;
  ids = S.items.map((it) => it.id);
  app.dataset.ownZoom = ""; // the loupes are this module's zoom, so the shell's stays out
  if (!document.getElementById("cmp-css")) document.head.append(h("style", { id: "cmp-css" }, CSS));
  const view = S.mode === "view";
  doneWhen(view ? null : (id) => get(id, "choice") != null);
  onState((changed) => { if (E && changed.has(cur)) { paintSide(); paintPins(); } if (E) strip(); });
  keys(keymap());
  if (cur !== null && !ids.includes(cur)) cur = null;
  if (cur === null && !view) cur = firstOpen(ids) ?? ids[0];
  if (cur === null) grid(); else show(cur, true);
}

const item = (id) => S.items.find((it) => it.id === id);
// One options list serves items of 2, 3 or 4 variants: a letter the shown item has no variant for is left out.
const allOpts = () => (S.options || [...((item(cur) || S.items[0]).variants || []).map((v, i) => ({ id: v.slot || LETTERS[i] })),
  { id: "tie", label: "=" }]).map((o) => ({ ...o, key: o.key ?? KEYS[o.id] }));
const opts = () => {
  const sides = frames(item(cur) || S.items[0]).map((f) => f.side);
  return allOpts().filter((o) => !/^[A-J]$/.test(o.id) || sides.includes(o.id));
};

function frames(it) {
  const vs = (it.variants || []).map((v, i) => ({ src: v.src, side: v.slot || LETTERS[i],
    name: S.blind ? "" : v.label || "", meta: v.meta || "", box: v.box, grid: v.grid }));
  return it.original ? [{ src: it.original, side: "", name: "оригинал", meta: "" }, ...vs] : vs;
}

function keymap() {
  const m = { ArrowLeft: () => go(-1), ArrowRight: () => go(1), Digit0: fitView,
    Equal: () => zoomBy(1.5), Minus: () => zoomBy(1 / 1.5), Escape: () => S.mode === "view" && grid(),
    KeyG: () => E && E.gb && toggleLines(), KeyM: () => E && E.mb && toggleMarks(), KeyQ: togglePin };
  for (let k = 1; k <= 9; k++) m["Digit" + k] = (S.zoom_levels || [])[k - 1] != null ? () => level(k - 1) : () => jump(k - 1);
  if (S.mode !== "view") for (const o of (S.items.length ? allOpts() : [])) if (o.key) m[o.key] = () => vote(o.id);
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
  // From four frames up each preview and each loupe carry one checkbox (top right, the same state): it hides or
  // shows that loupe. A click on it never starts a drag or fits the view.
  const toggle = (k) => fs.length > 3 ? h("input", { type: "checkbox", title: "показывать внизу", onclick: (e) => e.stopPropagation(),
    onpointerdown: (e) => e.stopPropagation(), ondblclick: (e) => e.stopPropagation(),
    onchange: (e) => { e.target.blur(); pane(k, e.target.checked); } }) : null;
  const vps = fs.map((f, k) => h("div", { class: "vp", ondblclick: (e) => !(pinTool || e.altKey) && fitView() },
    h("div", { class: "bd" }, h("span", {}, f.side || f.name), f.side && f.name ? h("span", {}, f.name) : null,
      f.meta ? h("span", {}, f.meta) : null, h("span", { class: "dim" })),
    h("img", { src: f.src, alt: "", draggable: false }), h("canvas"), h("div", { class: "pins" }), toggle(k)));
  const cells = fs.map((f, k) => h("div", { class: "pc", onclick: aim }, h("img", { alt: "", draggable: false }), h("i"),
    (it.marks || []).map(() => h("span", { class: "mk" })), toggle(k)));
  E = { vps, cells, imgs: vps.map((v) => v.querySelector("img")), boxes: cells.map((c) => c.querySelector("i")),
    hs: h("span", { class: "tools" }), strip: h("div", { class: "strip" }), cvs: vps.map((v) => v.querySelector("canvas")),
    gb: S.pixel_grid || it.grid ? h("button", { onclick: toggleLines, title: "G" }, "Сетка") : null,
    mb: it.marks && it.marks.length ? h("button", { onclick: toggleMarks, title: "M" }, "Рамка") : null,
    pb: h("button", { onclick: togglePin, title: "Q · или держи ⌥: клик — точка, протяни — рамка; картинка-метка в заметку" }, "Метка"),
    pls: vps.map((v) => v.querySelector(".pins")), note: textBox(id, "note", { placeholder: "заметка" }), ref: 0,
    pos: h("span", { class: "mute num" }), votes: null, tags: [], sg: h("span", { class: "sg", hidden: true }),
    lv: (S.zoom_levels || []).map((z, k) => h("button", { onclick: () => level(k), title: k < 9 ? `${k + 1}` : null }, `${z}×`)) };
  E.votes = voting ? h("div", { class: "votes" }, opts().map((o) =>
    h("button", { "data-v": o.id, onclick: () => vote_(o.id) }, o.label || o.id))) : null;
  E.tags = voting && S.tags ? fs.filter((f) => f.side).map((f) => h("div", { class: "trow", "data-side": f.side },
    h("b", {}, f.side), S.tags.map((t) => h("button", { "data-t": t, onclick: () => tag(f.side, t) }, t)))) : [];
  const nav = h("span", { class: "nav" }, S.mode === "view" ? h("button", { onclick: grid, title: "Esc" }, "▦") : null,
    h("button", { onclick: () => go(-1) }, "←"), E.pos, h("button", { onclick: () => go(1) }, "→"));
  // with zoom_levels the first level fits and the digits are taken, so no fit button and no hotspots
  const tools = h("div", { class: "tools" }, E.lv, S.zoom_levels ? null : [E.hs, h("button", { onclick: fitView, title: "0" }, "целиком")], E.pb, E.gb, E.mb);
  E.note.addEventListener("input", paintPins);
  E.pb.classList.toggle("on", pinTool);
  app.replaceChildren(E.strip, h("div", { class: "upper" }, h("div", { class: "pv" }, cells),
    h("div", { class: "side" }, h("div", { class: "ttl" }, h("strong", {}, `${num(it, i)}${it.title ? " · " + it.title : ""}`), nav),
      it.q ? h("div", { class: "q" }, it.q) : null, E.votes, E.sg, E.tags, tools,
      E.note)),
    h("div", { class: "lrow" }, vps));
  vps.forEach(wire);
  panes(); paintSide(); strip(); layout();
  Promise.all(E.imgs.map((im) => im.complete ? 0 : new Promise((r) => { im.onload = im.onerror = r; }))).then(() => {
    if (my !== token) return;
    const ref = it.original ? E.imgs[0] : E.imgs.reduce((a, b) => (b.naturalWidth * b.naturalHeight > a.naturalWidth * a.naturalHeight ? b : a));
    E.ref = E.imgs.indexOf(ref);
    geo = { w: ref.naturalWidth || 1, h: ref.naturalHeight || 1 };
    E.imgs.forEach((im, k) => {
      E.cells[k].querySelector("img").src = im.src;
      E.cells[k].style.aspectRatio = `${geo.w}/${geo.h}`;
      vps[k].querySelector(".dim").textContent = im.naturalWidth ? `${im.naturalWidth}×${im.naturalHeight}` : "—";
    });
    layout();
    if (!L) L = fit();
    paintPins();
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
function vote(o) { if (E && E.votes && opts().some((x) => x.id === o)) vote_(o); }

function tag(side, t) {
  const all = { ...(get(cur, "tags") || {}) }, set = new Set(all[side] || []);
  if (set.has(t)) set.delete(t); else set.add(t);
  if (set.size) all[side] = [...set]; else delete all[side];
  save(cur, { tags: Object.keys(all).length ? all : null });
  paintSide();
}

// From four frames up the checkbox on a preview and on its loupe hides or shows that loupe, for every item of the
// visit; the last loupe shown stays, and an item whose frames would all be hidden shows them all.
const badge = (f) => f.side || f.name;
function panes() {
  const fs = frames(item(cur)), hide = fs.map((f) => fs.length > 3 && off.has(badge(f)));
  if (hide.every(Boolean)) hide.fill(false);
  E.vps.forEach((v, k) => {
    v.hidden = hide[k];
    E.cells[k].classList.toggle("off", hide[k]);
    for (const cb of [E.cells[k].querySelector("input"), E.vps[k].querySelector(":scope>input")]) if (cb) cb.checked = !hide[k];
  });
  E.vps[0].parentNode.style.gridTemplateColumns = `repeat(${hide.filter((x) => !x).length},1fr)`;
}
function pane(k, on) {
  const name = badge(frames(item(cur))[k]);
  if (on) off.delete(name); else if (E.vps.filter((v) => !v.hidden).length > 1) off.add(name);
  panes(); reflow();
}

function go(d) { if (cur !== null) show(ids[(ids.indexOf(cur) + d + ids.length) % ids.length]); }

const shown = () => E.vps.find((v) => !v.hidden) || E.vps[0];
const size = () => ({ W: shown().clientWidth, H: shown().clientHeight });
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
function toggleMarks() { marked = !marked; draw(); }
const markW = () => item(cur).mark_width ?? S.mark_width ?? 0; // the frame's thickness in the original's px
function level(k) {
  const z = (S.zoom_levels || [])[k];
  if (geo && L && z != null) setL(k === 0 && L.z === z ? fit() : { ...L, z });
}

function aim(e) {
  if (!geo) return;
  const r = e.currentTarget.getBoundingClientRect(), k = geo.w / r.width;
  setL({ ...L, cx: (e.clientX - r.left) * k, cy: (e.clientY - r.top) * k });
}

function wire(vp, k) {
  vp.onpointerdown = (e) => {
    if (e.button !== 0 || !L) return;
    e.preventDefault();
    if (pinTool || e.altKey) {
      const band = h("div", { class: "band", hidden: true });
      vp.append(band);
      pinning = { k, vp, band, a: [e.clientX, e.clientY], b: [e.clientX, e.clientY], t: Date.now() };
      try { vp.setPointerCapture(e.pointerId); } catch (_) { /* pointer already gone */ }
      return;
    }
    drag = [e.clientX, e.clientY];
    document.body.classList.add("drag");
    try { vp.setPointerCapture(e.pointerId); } catch (_) { /* pointer already gone */ }
  };
  vp.onlostpointercapture = () => { endDrag(); endPin(false); };
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
  if (pinning) return movePin(e);
  if (!drag) return;
  if (!(e.buttons & 1)) return endDrag();
  setL({ ...L, cx: L.cx - (e.clientX - drag[0]) / L.z, cy: L.cy - (e.clientY - drag[1]) / L.z });
  drag = [e.clientX, e.clientY];
});
addEventListener("pointerup", (e) => { endPin(true, e); endDrag(); });
addEventListener("pointercancel", () => { endPin(false); endDrag(); });
addEventListener("blur", () => { endPin(false); endDrag(); hold(false); });
const hold = (on) => document.body.classList.toggle("pin", pinTool || on);  // ⌥ held: the crosshair shows
addEventListener("keydown", (e) => e.key === "Alt" && hold(true));
addEventListener("keyup", (e) => e.key === "Alt" && hold(false));
// a loupe that changes width keeps showing the same span of the picture
function reflow() {
  if (!E) return;
  const w = lastW;
  layout();
  if (L && w) L.z *= shown().clientWidth / w;
  draw();
}
addEventListener("resize", reflow);

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
  lastW = shown().clientWidth;
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
  placePins(W, H);
  if (E.gb || E.mb) paintLines(W, H, at, first);
  const x0 = Math.max(0, L.cx - W / 2 / L.z), x1 = Math.min(geo.w, L.cx + W / 2 / L.z);
  const y0 = Math.max(0, L.cy - H / 2 / L.z), y1 = Math.min(geo.h, L.cy + H / 2 / L.z);
  const mk = item(cur).marks || [];
  E.boxes.forEach((b) => {
    const k = b.parentNode.clientWidth / geo.w;
    const bw = Math.max(1, markW() * k);
    b.parentNode.querySelectorAll(".mk").forEach((m, j) => { const [a, c, a1, c1] = mk[j];
      Object.assign(m.style, { display: marked ? "block" : "none", borderWidth: bw + "px", left: a * k - bw + "px", top: c * k - bw + "px",
        width: (a1 - a) * k + 2 * bw + "px", height: (c1 - c) * k + 2 * bw + "px" }); });
    Object.assign(b.style, { display: x1 > x0 && y1 > y0 ? "block" : "none", left: x0 * k + "px", top: y0 * k + "px",
      width: (x1 - x0) * k + "px", height: (y1 - y0) * k + "px" });
  });
}

// «Сетка»: the item's `grid` (cell bounds in the original's pixels, or `paths`: bent lines; several in a list) over the original, and in each variant's loupe its
// own `grid` (cell bounds in its own pixels), else its own pixel grid; a grid whose cells are under 5 screen px is left out. A canvas is resized only when the
// loupe is (resizing reallocates it) and cleared only when it holds lines, since draw() runs on every drag move.
// «Рамка» (M, on by default): the item's `marks`, boxes in the original's pixels, framed on every loupe and preview.
function paintLines(W, H, at, first) {
  const d = devicePixelRatio || 1, it = item(cur), fs = frames(it), cw = Math.round(W * d), chh = Math.round(H * d);
  if (E.gb) E.gb.classList.toggle("on", lines);
  if (E.mb) E.mb.classList.toggle("on", marked);
  E.cvs.forEach((c, i) => {
    if (c.width !== cw || c.height !== chh) {
      Object.assign(c, { width: cw, height: chh });
      Object.assign(c.style, { width: W + "px", height: H + "px" });
    } else if (inked.has(c)) c.getContext("2d").clearRect(0, 0, cw, chh);
    inked.delete(c);
    const a = at[i], step = (b) => (b.at(-1) - b[0]) / (b.length - 1) * L.z;
    let xs, ys;
    if (E.mb && marked) {
      const g = c.getContext("2d"), lw = Math.max(2, markW() * L.z) * d;  // drawn just outside the box, so it hides none of it
      g.strokeStyle = MARK; g.lineWidth = lw; inked.add(c);
      for (const [a, b, a1, b1] of it.marks) g.strokeRect((W / 2 + (a - L.cx) * L.z) * d - lw / 2, (H / 2 + (b - L.cy) * L.z) * d - lw / 2,
        (a1 - a) * L.z * d + lw, (b1 - b) * L.z * d + lw);
    }
    if (!lines || !E.gb) return;
    const g = c.getContext("2d"), px = (v) => Math.round(v * d) + 0.5;
    const lattice = (xs, ys, color) => {
      const [x0, x1, y0, y1] = [Math.max(0, px(xs[0])), Math.min(c.width, px(xs.at(-1))), Math.max(0, px(ys[0])), Math.min(c.height, px(ys.at(-1)))];
      inked.add(c); g.strokeStyle = color || LINE; g.lineWidth = 1; g.beginPath();
      for (const x of xs) { const v = px(x); if (v >= 0 && v <= c.width) { g.moveTo(v, y0); g.lineTo(v, y1); } }
      for (const y of ys) { const v = px(y); if (v >= 0 && v <= c.height) { g.moveTo(x0, v); g.lineTo(x1, v); } }
      g.stroke();
    };
    if (i < first) {                                    // one lattice or several, straight (`x`/`y`) or bent (`paths`)
      const ox = (v) => W / 2 + (v - L.cx) * L.z, oy = (v) => H / 2 + (v - L.cy) * L.z;
      for (const gr of [].concat(it.grid || [])) {
        if (!gr.paths) { if (Math.min(step(gr.x), step(gr.y)) >= 5) lattice(gr.x.map(ox), gr.y.map(oy), gr.color); continue; }
        if ((gr.cell || 0) * L.z < 5) continue;
        inked.add(c); g.strokeStyle = gr.color || LINE; g.lineWidth = 1; g.beginPath();
        for (const p of gr.paths) p.forEach(([x, y], k) => g[k ? "lineTo" : "moveTo"](ox(x) * d, oy(y) * d));
        g.stroke();
      }
      return;
    } else if (a && fs[i].grid) {
      const g = fs[i].grid, at = (b, s) => (b.at(-1) - b[0]) / (b.length - 1) * s;
      if (Math.min(at(g.x, a.sx), at(g.y, a.sy)) < 5) return;
      xs = g.x.map((v) => a.x + v * a.sx);
      ys = g.y.map((v) => a.y + v * a.sy);
    } else if (a && Math.min(a.sx, a.sy) >= 5) {
      xs = Array.from({ length: a.nw + 1 }, (_, k) => a.x + k * a.sx);
      ys = Array.from({ length: a.nh + 1 }, (_, k) => a.y + k * a.sy);
    } else return;
    lattice(xs, ys);
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

// «Метка» (Q, or ⌥ held): on any loupe a click marks one pixel and a drag a box, in the original's px. The page draws
// a sheet for the reading model (the whole picture with the context framed, then the same context cut from every
// frame, the mark in magenta, an English caption), stores it like a pasted picture so its [imgN.png] goes in the note
// at the caret, and saves `pins` {name: {on, at, z}}. A pin whose name the note still holds shows on every loupe.
const TILE = 360, GAP = 10, LAB = 22, PAD = 12, cl = (v, a, b) => Math.min(b, Math.max(a, v));
function togglePin() { pinTool = !pinTool; hold(false); if (E) E.pb.classList.toggle("on", pinTool); }
const toPx = (vp, [x, y]) => {
  const r = vp.getBoundingClientRect();
  return [L.cx + (x - r.left - vp.clientWidth / 2) / L.z, L.cy + (y - r.top - vp.clientHeight / 2) / L.z];
};
const far = (p) => Math.hypot(p.b[0] - p.a[0], p.b[1] - p.a[1]) > 5;
function movePin(e) {
  if (!(e.buttons & 1)) return endPin(false);
  const p = pinning, r = p.vp.getBoundingClientRect();
  p.b = [e.clientX, e.clientY];
  p.band.hidden = !far(p);
  Object.assign(p.band.style, { left: Math.min(p.a[0], p.b[0]) - r.left + "px", top: Math.min(p.a[1], p.b[1]) - r.top + "px",
    width: Math.abs(p.b[0] - p.a[0]) + "px", height: Math.abs(p.b[1] - p.a[1]) + "px" });
}
function endPin(ok, e) {
  const p = pinning;
  if (!p) return;
  pinning = null;
  p.band.remove();
  if (!ok || !E || !geo || !L || !E.vps.includes(p.vp)) return;
  if (e) p.b = [e.clientX, e.clientY];
  const [ax, ay] = toPx(p.vp, p.a), [bx, by] = toPx(p.vp, p.b);
  let at;
  if (!far(p)) {
    if (ax < 0 || ay < 0 || ax >= geo.w || ay >= geo.h) return;
    at = [Math.floor(ax), Math.floor(ay)];
  } else {
    at = [cl(Math.floor(Math.min(ax, bx)), 0, geo.w), cl(Math.floor(Math.min(ay, by)), 0, geo.h),
      cl(Math.ceil(Math.max(ax, bx)), 0, geo.w), cl(Math.ceil(Math.max(ay, by)), 0, geo.h)];
    if (at[2] <= at[0] || at[3] <= at[1]) return;
  }
  pin(p.k, at, p.t);
}

// t: when the mark began, so a running dictation puts the sheet's name at the word Egor said then (shell's dictated)
async function pin(k, at, t) {
  const id = cur, el = E.note, z = Math.round(L.z * 1000) / 1000, on = frames(item(id))[k].side || "original";
  const c = sheet(k, at, z), blob = await new Promise((r) => c.toBlob(r, "image/png"));
  const it = item(id), where = (at.length === 2 ? "point " : "box ") + at.join(",") + " px";
  const [name] = blob ? await attachPicture(el, blob, { at: t, about: `${where} on ${on}, item ${it.title || id}` }) : [];
  if (!name) return;
  if (!el.value.includes(`[${name}]`)) coming.add(name);
  save(id, { pins: { ...(get(id, "pins") || {}), [name]: { on, at, z } } });
  if (cur === id) paintPins();
}

// The frame's cell range [c0, r0, c1, r1] (inclusive) under the mark, with its bounds in the original's px; null off the frame.
function cells(f, im, [x0, y0, x1, y1]) {
  const [bx, by, bx1, by1] = f.box || [0, 0, geo.w, geo.h], nw = im.naturalWidth, nh = im.naturalHeight;
  if (!nw || x1 <= bx || y1 <= by || x0 >= bx1 || y0 >= by1) return null;
  const cw = (bx1 - bx) / nw, ch = (by1 - by) / nh;
  const c = [cl(Math.floor((x0 - bx) / cw), 0, nw - 1), cl(Math.floor((y0 - by) / ch), 0, nh - 1),
    cl(Math.ceil((x1 - bx) / cw) - 1, 0, nw - 1), cl(Math.ceil((y1 - by) / ch) - 1, 0, nh - 1)];
  return { c, nw, nh, cw, px: [bx + c[0] * cw, by + c[1] * ch, bx + (c[2] + 1) * cw, by + (c[3] + 1) * ch] };
}

function sheet(k, at, z) {
  const it = item(cur), fs = frames(it), box = at.length === 4, m = box ? at : [at[0], at[1], at[0] + 1, at[1] + 1];
  // the mark fills about half the tile (never less zoom than Egor's loupe had), the region kept inside the picture
  const lo = 2 * Math.max(m[2] - m[0], m[3] - m[1]);
  const side = Math.max(1, Math.round(Math.min(Math.max(lo, 0.35 * Math.max(geo.w, geo.h)), Math.max(24, lo, 400 / z))));
  const inside = (v, n) => (side < n ? cl(v, 0, n - side) : Math.round((n - side) / 2));
  const rx = inside(Math.round((m[0] + m[2]) / 2 - side / 2), geo.w), ry = inside(Math.round((m[1] + m[3]) / 2 - side / 2), geo.h), s = TILE / side;
  const name = (f, i) => (i === 0 && it.original ? "original" : f.side + (f.name ? " · " + f.name : ""));
  const on = name(fs[k], k), ref = it.original ? "the original" : `the shared ${geo.w}x${geo.h} frame`;
  const cc = k === 0 && it.original ? null : cells(fs[k], E.imgs[k], m);
  const cr = cc && (box ? ` = cells x ${cc.c[0]}..${cc.c[2]}, y ${cc.c[1]}..${cc.c[3]}` : ` = cell ${cc.c[0]},${cc.c[1]}`);
  const where = (box ? `Box x ${m[0]}..${m[2] - 1}, y ${m[1]}..${m[3] - 1} px of ${ref}` : `Point ${at[0]},${at[1]} px of ${ref}`)
    + (cr ? `${cr} of ${fs[k].side}'s ${cc.nw}x${cc.nh}` : "") + " (0-based from the top left).";
  const text = `Mark on ${on} (${box ? "box" : "point"}): where the note names this picture, it means the place in the magenta `
    + `${box ? "rectangle" : "ring"}. Same place on every picture; tile 1 is the whole picture with the region shown framed. ${where}`;
  const tiles = [null, ...fs], cols = Math.min(4, tiles.length), rows = Math.ceil(tiles.length / cols);
  const W = 2 * PAD + cols * TILE + (cols - 1) * GAP, c = h("canvas"), g = c.getContext("2d"), font = "px -apple-system, Helvetica, Arial, sans-serif";
  g.font = "15" + font;
  const lines = [""];
  for (const w of text.split(" ")) {
    const t = lines.at(-1) ? lines.at(-1) + " " + w : w;
    if (g.measureText(t).width > W - 2 * PAD && lines.at(-1)) lines.push(w); else lines[lines.length - 1] = t;
  }
  const top = PAD + lines.length * 20 + 6;
  Object.assign(c, { width: W, height: top + rows * (LAB + TILE) + (rows - 1) * GAP + PAD });
  g.fillStyle = "#fff"; g.fillRect(0, 0, c.width, c.height);
  g.fillStyle = "#000"; g.font = "15" + font; g.textBaseline = "top";
  lines.forEach((l, i) => g.fillText(l, PAD, PAD + i * 20));
  const ring = (x, y, r) => { g.beginPath(); g.arc(x, y, r, 0, 2 * Math.PI); g.stroke(); };
  tiles.forEach((f, t) => {
    const X = PAD + (t % cols) * (TILE + GAP), Y = top + Math.floor(t / cols) * (LAB + TILE + GAP) + LAB, i = t - 1, mine = i === k;
    const label = f ? name(f, i) : "whole picture";
    g.font = (mine ? "bold 14" : "14") + font;
    if (mine) { g.fillStyle = MARK; g.fillRect(X, Y - LAB, Math.min(TILE, g.measureText(label).width + 12), LAB - 3); }
    g.fillStyle = mine ? "#fff" : "#000"; g.fillText(label, X + 6, Y - LAB + 3, TILE - 12);
    g.save();
    g.beginPath(); g.rect(X, Y, TILE, TILE); g.clip();
    g.strokeStyle = MARK; g.lineWidth = 2;
    if (!f) {                                             // the whole reference picture, the region framed
      const im = E.imgs[E.ref], q = Math.min(TILE / geo.w, TILE / geo.h), ox = X + (TILE - geo.w * q) / 2, oy = Y + (TILE - geo.h * q) / 2;
      g.imageSmoothingEnabled = q < 1;
      if (im.naturalWidth) g.drawImage(im, ox, oy, geo.w * q, geo.h * q);
      g.strokeRect(ox + rx * q, oy + ry * q, side * q, side * q);
      if (box) g.strokeRect(ox + m[0] * q - 1, oy + m[1] * q - 1, (m[2] - m[0]) * q + 2, (m[3] - m[1]) * q + 2);
      else ring(ox + (m[0] + 0.5) * q, oy + (m[1] + 0.5) * q, 5);
    } else {                                              // the same region from this frame, through its box
      const im = E.imgs[i], nw = im.naturalWidth, nh = im.naturalHeight, [bx, by, bx1, by1] = f.box || [0, 0, geo.w, geo.h];
      const ix = Math.max(rx, bx), iy = Math.max(ry, by), ix1 = Math.min(rx + side, bx1), iy1 = Math.min(ry + side, by1);
      if (nw && ix1 > ix && iy1 > iy) {
        const sw = (ix1 - ix) / (bx1 - bx) * nw, dw = (ix1 - ix) * s;
        g.imageSmoothingEnabled = dw < sw;
        g.drawImage(im, (ix - bx) / (bx1 - bx) * nw, (iy - by) / (by1 - by) * nh, sw, (iy1 - iy) / (by1 - by) * nh,
          X + (ix - rx) * s, Y + (iy - ry) * s, dw, (iy1 - iy) * s);
      }
      const px = (v) => X + (v - rx) * s, py = (v) => Y + (v - ry) * s;
      if (box) g.strokeRect(px(m[0]) - 1, py(m[1]) - 1, (m[2] - m[0]) * s + 2, (m[3] - m[1]) * s + 2);
      else ring(px(m[0] + 0.5), py(m[1] + 0.5), Math.max(9, s * 0.75 + 5));
      const own = mine && cells(f, im, m);                // the frame's own pixel/cell under the mark, when it is big enough
      if (own && own.cw * s >= 4) {
        g.lineWidth = 1; g.setLineDash([3, 2]);
        g.strokeRect(px(own.px[0]) + 0.5, py(own.px[1]) + 0.5, (own.px[2] - own.px[0]) * s - 1, (own.px[3] - own.px[1]) * s - 1);
      }
    }
    g.restore();
    g.strokeStyle = mine ? MARK : "#bbb"; g.lineWidth = 1;
    g.strokeRect(X - 0.5, Y - 0.5, TILE + 1, TILE + 1);
  });
  return c;
}

// The note's pins on every loupe: solid with the picture's number on the frame the mark was made on, dashed elsewhere.
function paintPins() {
  if (!E) return;
  const fs = frames(item(cur)), all = get(cur, "pins") || {}, text = E.note.value;
  const list = Object.entries(all).filter(([n, p]) => p && Array.isArray(p.at) && (text.includes(`[${n}]`) || coming.has(n)));
  E.pinEls = E.pls.map((layer, i) => {
    const els = list.map(([n, p]) => {
      const mine = p.on === (fs[i].side || "original");
      return { p, el: h("div", { class: (p.at.length === 2 ? "pt" : "bx") + (mine ? "" : " far") }, mine ? h("b", {}, String(parseInt(n.slice(3)))) : null) };
    });
    layer.replaceChildren(...els.map((x) => x.el));
    return els;
  });
  if (geo && L) { const { W, H } = size(); placePins(W, H); }
}
function placePins(W, H) {
  for (const els of E.pinEls || []) for (const { p, el } of els) {
    const [a, b, a1 = a + 1, b1 = b + 1] = p.at, x = W / 2 + (a - L.cx) * L.z, y = H / 2 + (b - L.cy) * L.z, w = (a1 - a) * L.z, hh = (b1 - b) * L.z;
    const r = Math.max(7, w / 2 + 4);
    Object.assign(el.style, p.at.length === 2
      ? { left: x + w / 2 - r + "px", top: y + hh / 2 - r + "px", width: 2 * r + "px", height: 2 * r + "px" }
      : { left: x - 2 + "px", top: y - 2 + "px", width: w + 4 + "px", height: hh + 4 + "px" });
  }
}
