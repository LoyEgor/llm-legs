// The module API of the pages kit (share/pages/CONTRACT.md). loader.html calls start(); a module
// exports render(spec, again) and uses only what is exported here:
//   get(id, field)               the shown value: a typed draft, else the outbox, else the server
//   state()                      {id: {field: value}} with the same overlay
//   save(id, fields)             one gesture's changed fields, sent at once (null clears a field)
//   saveText(id, field, value)   the same, debounced 400 ms (sent at once on blur)
//   textBox(id, field, props)    a <textarea> bound to saveText, refreshed when the state moves; it
//                                sits in a .atw box that also holds its pictures
//   onState(cb)                  cb(Set of item ids) when the server state changed them
//   doneWhen(fn)                 fn(id) → answered; feeds «N из M» and sitting_cap (null: no count)
//   firstOpen(ids), nextOpen(ids, from)   the first answered-nor-skipped id after index `from`
//   skip(id), capped()           skip for this sitting; sitting_cap answers given this sitting
//   keys(map)                    {event.code: fn}; ignored in text fields and with Cmd/Ctrl/Alt
//   lazy(el)                     el's data-src loads near the viewport and is released far away
//   attachPicture(el, blob, mark)  a picture the module drew, stored and named at el's caret like a paste → [names];
//                                with mark {at: Date.now() of Egor's action, about} a running dictation takes the name
//                                at the word he said then, and the caret gets nothing (see dictated)
//   pending(el)                  the names a running dictation will paste into el (marks it took, not yet arrived,
//                                not taken back with ×); el fires a "pictures" event whenever that set changes
//   num(item, i), h(tag, props, ...kids)   the shown number; a DOM element
// render, onState, doneWhen and keys replace their previous value, so a re-render is idempotent.
// Every text field on every page takes pictures (the picture section below): no module wires them.
// Every gesture goes to the localStorage outbox `pages-outbox:<pid>` before it is sent and leaves it
// only on 200 (dup included) or 409 (item gone); sends are FIFO, one in flight, so a field's last
// gesture is the one the server keeps.

let spec, pid, render, BOX, queue = [];
let server = {}, rev = -1, ackRev = -1;
let sending = false, failed = false, savedAt = null, polling = false, specBusy = false;
let doneFn = null, stateCb = null, keymap = {};
const drafts = new Map(), boxes = new Set(), sitting = new Set(), skipped = new Set();
const $ = (id) => document.getElementById(id);
const uuid = () => crypto.randomUUID ? crypto.randomUUID()
  : [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
const json = { "Content-Type": "application/json" };

export function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "class") el.className = v;
    else if (k in el && !k.includes("-")) el[k] = v;
    else el.setAttribute(k, v);
  }
  el.append(...kids.flat().filter((k) => k != null && k !== false));
  return el;
}

export const num = (item, i) => item.n ?? i + 1;
export const onState = (cb) => { stateCb = cb; };
export const keys = (map) => { keymap = map; };
export const doneWhen = (fn) => { doneFn = fn; paint(); };
export const skip = (id) => { skipped.add(id); };
export const capped = () => spec.sitting_cap > 0 && sitting.size >= spec.sitting_cap;
const done = (id) => !!(doneFn && doneFn(id));

export function nextOpen(ids, from = -1) {
  for (let k = 1; k <= ids.length; k++) {
    const id = ids[(from + k + ids.length) % ids.length];
    if (!done(id) && !skipped.has(id)) return id;
  }
  return null;
}
export const firstOpen = (ids) => nextOpen(ids, -1);

export function get(id, field) {
  const d = drafts.get(id + "\t" + field);
  if (d) return d.value;
  for (let i = queue.length - 1; i >= 0; i--)
    if (queue[i].item === id && field in queue[i].fields) return queue[i].fields[field];
  const s = server[id] && server[id][field];
  return s ? s.v : null;
}

export function state() {
  const out = {};
  for (const id of spec.items.map((it) => it.id)) {
    const fields = new Set(Object.keys(server[id] || {}));
    queue.forEach((p) => p.item === id && Object.keys(p.fields).forEach((f) => fields.add(f)));
    drafts.forEach((d) => d.id === id && fields.add(d.field));
    for (const f of fields) if (get(id, f) != null) (out[id] ||= {})[f] = get(id, f);
  }
  return out;
}

function persist() {
  try {
    if (queue.length) localStorage.setItem(BOX, JSON.stringify(queue));
    else localStorage.removeItem(BOX);
  } catch (e) { /* storage refused: the queue still lives in memory */ }
}

export function save(id, fields) {
  const was = done(id);
  queue.push({ op: uuid(), item: id, fields, spec_rev: spec.rev });
  persist();
  if (!was && done(id)) sitting.add(id);
  paint();
  pump();
}

export function saveText(id, field, value) {
  const k = id + "\t" + field, d = drafts.get(k);
  if (d) clearTimeout(d.timer);
  drafts.set(k, { id, field, value, timer: setTimeout(() => commit(k), 400) });
  paint();
}

function commit(k) {
  const d = drafts.get(k);
  if (!d) return;
  clearTimeout(d.timer);
  drafts.delete(k);
  save(d.id, { [d.field]: d.value === "" ? null : d.value });
}

export function textBox(id, field, props) {
  const el = h("textarea", { rows: 1, ...props });
  Object.assign(el.dataset, { item: id, field });
  el.value = get(id, field) ?? "";
  el.addEventListener("input", () => saveText(id, field, el.value));
  el.addEventListener("blur", () => commit(id + "\t" + field));
  boxes.add(el);
  requestAnimationFrame(() => { if (el.isConnected) { slot(el); strip(el); grow(el); } });
  return el;
}

async function post(p, keepalive) {
  let r;
  try {
    r = await fetch(`/p/${pid}/patch`, { method: "POST", headers: json, body: JSON.stringify(p), keepalive });
  } catch (e) { return false; }
  if (r.status === 409) { drop(p); refreshSpec(); return true; }
  if (!r.ok) return false;
  const a = await r.json().catch(() => ({}));
  if (drop(p)) {
    const s = (server[p.item] ||= {}), at = new Date().toISOString();
    for (const [f, v] of Object.entries(p.fields)) if (v === null) delete s[f]; else s[f] = { v, at, by: "egor" };
  }
  if (a.rev > ackRev) ackRev = a.rev;
  savedAt = new Date();
  return true;
}

function drop(p) {
  const n = queue.length;
  queue = queue.filter((q) => q.op !== p.op);
  if (queue.length !== n) persist();
  return queue.length !== n;
}

async function pump() {
  if (sending) return;
  sending = true;
  while (queue.length) {
    if (!(await post(queue[0], false))) { failed = true; break; }
    failed = false;
  }
  sending = false;
  paint();
}

function flushAll() {
  [...drafts.keys()].forEach(commit);
  queue.forEach((p) => post(p, true));
}

const poll = () => document.visibilityState === "visible" && loadState();

async function loadState() {
  if (polling) return;
  polling = true;
  try {
    const r = await fetch(`/p/${pid}/state`, { cache: "no-store" });
    if (r.ok) merge(await r.json());
  } catch (e) { /* the next tick retries */ }
  polling = false;
}

const vals = (o) => JSON.stringify(Object.keys(o || {}).sort().map((f) => [f, o[f].v]));

function merge(s) {
  if (s.spec_rev != null && s.spec_rev !== spec.rev) refreshSpec();
  if (s.rev === rev || s.rev < ackRev) return;
  rev = s.rev;
  const items = s.items || {}, changed = new Set();
  for (const id of new Set([...Object.keys(server), ...Object.keys(items)]))
    if (vals(server[id]) !== vals(items[id])) changed.add(id);
  server = items;
  if (!changed.size) return;
  for (const el of boxes) {
    if (!el.isConnected) boxes.delete(el);
    else if (changed.has(el.dataset.item) && el !== document.activeElement) {
      el.value = get(el.dataset.item, el.dataset.field) ?? "";
      strip(el); grow(el);
    }
  }
  if (stateCb) stateCb(changed);
  paint();
}

async function refreshSpec() {
  if (specBusy) return;
  specBusy = true;
  try {
    const r = await fetch(`/p/${pid}/spec`, { cache: "no-store" });
    const s = r.ok ? await r.json() : null;
    if (s && s.rev !== spec.rev) {
      spec = { pid, ...s };
      header();
      render(spec, true);
      paint();
    }
  } catch (e) { /* the next poll retries */ }
  specBusy = false;
}

function paint() {
  if (!spec) return;
  const pending = queue.length + drafts.size, st = $("status");
  st.textContent = failed && pending ? "не сохранилось — повторю" : pending ? "сохраняю…"
    : savedAt ? "сохранено " + savedAt.toTimeString().slice(0, 5) : "";
  st.classList.toggle("err", failed && pending > 0);
  const ids = spec.items.map((it) => it.id);
  $("count").textContent = doneFn ? `${ids.filter(doneFn).length} из ${ids.length}` : "";
  $("cap").hidden = !capped();
}

function header() {
  document.title = spec.title || "страница";
  $("title").textContent = spec.title || "";
  $("intro").textContent = spec.intro || "";
}

function onKey(e) {
  const t = e.target;
  if (t.closest && t.closest("input,textarea,select,[contenteditable]")) {
    if (e.code === "Escape") t.blur();
    return;
  }
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const f = keymap[e.code];
  if (f) { e.preventDefault(); f(e); }
}

const loadEl = (el) => { if (!el.getAttribute("src") && el.dataset.src) el.src = el.dataset.src; };
function releaseEl(el) {
  if (!el.getAttribute("src") || (el.paused === false)) return;
  el.removeAttribute("src");
  if (el.load) el.load();
}
const near = new IntersectionObserver((es) => es.forEach((e) => e.isIntersecting && loadEl(e.target)),
  { rootMargin: "100% 0px" });
const far = new IntersectionObserver((es) => es.forEach((e) => !e.isIntersecting && releaseEl(e.target)),
  { rootMargin: "300% 0px" });
export function lazy(el) { near.observe(el); far.observe(el); return el; }

// Every picture on every page opens full screen on a click, so no page ever leaves one too small to
// read: the wheel or a pinch zooms at the pointer, a drag pans, a click on the picture toggles its actual
// size (1:1, at the click) and the whole picture, ← → step through the page's pictures, Esc, ✕ or a click
// beside the picture closes. The pictures of one [data-compare] box (cards' `compare` media) open side by
// side, a pane each, under one zoom and pan: each is drawn at the first one's width, so one place lines up.
// A module with its own zoom marks its root data-own-zoom and keeps its pictures out.
// A field's pictures step among themselves, apart from the page's own.
const zoomable = (from) => {
  if (from && from.closest(".att")) return [...from.closest(".att").querySelectorAll("img")].map((im) => [im]);
  const out = [], groups = new Map();
  for (const im of document.querySelectorAll("main img")) {
    if (im.closest("[data-own-zoom],.att")) continue;
    const g = im.closest("[data-compare]");
    if (!g) out.push([im]); else if (groups.has(g)) groups.get(g).push(im); else { groups.set(g, [im]); out.push(groups.get(g)); }
  }
  return out;
};
let Z = null;
// a point on screen -> [x, y] in the pane under it (the pictures' shared coordinates) and that pane's index
const local = (cx, cy) => {
  const n = Z.panes.length, pw = innerWidth / n, k = Math.min(n - 1, Math.max(0, Math.floor(cx / pw)));
  return [cx - k * pw, cy, k];
};
function zoomOpen(from) {
  if (!Z) {
    const pos = h("span", { class: "zpos" }), msg = h("span", { class: "zmsg" });
    const band = h("div", { class: "zband", hidden: true });
    const tb = h("button", { onclick: zoomTool, title: "Q · или держи ⌥ · перо метит само: клик — точка, протяни — рамка" }, "Метка");
    const el = h("div", { class: "zoom", role: "dialog", "aria-modal": "true" }, band,
      h("div", { class: "zbar" }, pos, h("span", { class: "mute" }, "колесо — зум · тащи · клик — 1:1 или целиком · ← → · Esc"), msg, tb,
        h("button", { onclick: zoomClose, title: "Esc" }, "✕")));
    Z = { el, pos, msg, band, tb, panes: [], pts: new Map(), s: 1, x: 0, y: 0, fit: 1, tool: false, mark: null };
    const at = (s, px, py) => { s = Math.min(Math.max(s, Math.min(Z.fit / 2, 1)), 8); Z.x = px - (px - Z.x) * s / Z.s; Z.y = py - (py - Z.y) * s / Z.s; Z.s = s; zoomPaint(); };
    Z.at = at;
    el.addEventListener("wheel", (e) => { e.preventDefault(); const [x, y] = local(e.clientX, e.clientY); at(Z.s * Math.exp(-e.deltaY * 0.0015), x, y); }, { passive: false });
    el.addEventListener("pointerdown", (e) => {
      if (e.target.closest(".zbar")) return;
      try { el.setPointerCapture(e.pointerId); } catch (_) { /* pointer already gone */ }
      if ((Z.tool || e.altKey || e.pointerType === "pen") && e.button === 0) {   // an Apple Pencil marks without Q
        Z.mark = { a: [e.clientX, e.clientY], b: [e.clientX, e.clientY], t: Date.now(), k: local(e.clientX, e.clientY)[2] }; return;
      }
      Z.pts.set(e.pointerId, [e.clientX, e.clientY]); Z.moved = 0;
    });
    el.addEventListener("pointermove", (e) => {
      if (Z.mark) return markMove(e);
      const p = Z.pts.get(e.pointerId); if (!p) return;
      const all = [...Z.pts.values()], d0 = all.length === 2 ? Math.hypot(all[0][0] - all[1][0], all[0][1] - all[1][1]) : 0;
      Z.pts.set(e.pointerId, [e.clientX, e.clientY]); Z.moved += Math.abs(e.clientX - p[0]) + Math.abs(e.clientY - p[1]);
      if (all.length === 2) {
        const [a, b] = [...Z.pts.values()], d1 = Math.hypot(a[0] - b[0], a[1] - b[1]), [mx, my] = local((a[0] + b[0]) / 2, (a[1] + b[1]) / 2);
        if (d0) at(Z.s * d1 / d0, mx, my);
      } else { Z.x += e.clientX - p[0]; Z.y += e.clientY - p[1]; zoomPaint(); }
    });
    const up = (e) => {
      if (Z.mark) return markEnd(e.type === "pointerup" ? e : null);
      if (!Z.pts.delete(e.pointerId) || Z.moved > 4 || e.type !== "pointerup") return;
      const [x, y, k] = local(e.clientX, e.clientY), r = Z.panes[k].img.getBoundingClientRect();
      if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) zoomClose();
      else if (Math.abs(Z.s - 1) < 1e-3) zoomFit(); else at(1, x, y);   // a click: its actual size there, again: the whole
    };
    el.addEventListener("pointerup", up); el.addEventListener("pointercancel", up);
    document.addEventListener("keydown", (e) => {
      if (!Z.el.isConnected) return;
      const step = { ArrowLeft: -1, ArrowRight: 1 }[e.code];
      if (e.key === "Alt") return Z.el.classList.add("pin");
      if (e.code === "Escape") zoomClose(); else if (step) zoomShow(Z.i + step);
      else if (e.code === "KeyQ" && !e.metaKey && !e.ctrlKey) zoomTool();
      else if (e.code === "Equal" || e.code === "Minus") at(Z.s * (e.code === "Equal" ? 1.5 : 1 / 1.5), innerWidth / Z.panes.length / 2, innerHeight / 2);
      else if (e.code === "Digit0") zoomFit(); else return;
      e.preventDefault(); e.stopImmediatePropagation();
    }, true);
    document.addEventListener("keyup", (e) => e.key === "Alt" && Z.el.classList.remove("pin"));
  }
  Z.list = zoomable(from);
  Z.field = fieldFor(from); Z.msg.textContent = "";
  document.body.append(Z.el); document.body.style.overflow = "hidden";
  zoomShow(Math.max(0, Z.list.findIndex((set) => set.includes(from))));
}
function zoomShow(i) {
  const n = Z.list.length; Z.i = (i + n) % n;
  const set = Z.list[Z.i];
  Z.pos.textContent = n > 1 ? `${Z.i + 1} / ${n}` : "";
  while (Z.panes.length > set.length) Z.panes.pop().box.remove();
  while (Z.panes.length < set.length) {
    const k = Z.panes.length, img = h("img", { alt: "", draggable: false }), cap = h("span", { class: "zcap" });
    img.addEventListener("load", () => (k ? zoomPaint() : zoomFit()));   // the first picture sets the scale for all
    Z.panes.push({ box: h("div", { class: "zpane" }, img, cap), img, cap });
    Z.el.insertBefore(Z.panes[k].box, Z.band);
  }
  set.forEach((im, k) => {
    const p = Z.panes[k];
    Object.assign(p.box.style, { left: 100 * k / set.length + "%", width: 100 / set.length + "%" });
    p.cap.textContent = set.length > 1 ? im.dataset.cap || im.alt || "" : "";
    p.cap.hidden = !p.cap.textContent;
    p.img.src = im.currentSrc || im.getAttribute("src") || im.dataset.src;
  });
  zoomFit();
}
function zoomFit() {
  const ref = Z.panes[0].img, w = ref.naturalWidth, hh = ref.naturalHeight, W = innerWidth / Z.panes.length, H = innerHeight - 44;
  if (!ref.complete || !w) return;
  Z.fit = Z.s = Math.min(W / w, H / hh); Z.x = (W - w * Z.s) / 2; Z.y = (H - hh * Z.s) / 2; zoomPaint();
}
function zoomPaint() {
  const rw = Z.panes[0].img.naturalWidth || 1;
  for (const p of Z.panes) p.img.style.transform = `translate(${Z.x}px,${Z.y}px) scale(${Z.s * rw / (p.img.naturalWidth || rw)})`;
}
function zoomTool() { Z.tool = !Z.tool; Z.el.classList.toggle("tool", Z.tool); Z.tb.classList.toggle("on", Z.tool); }
function zoomClose() { Z.el.remove(); Z.pts.clear(); Z.mark = null; Z.band.hidden = true; document.body.style.overflow = ""; }

// «Метка» on any picture shown full screen (compare's loupes have their own): ⌥ held, Q or the button, or a pen, a click marks a pixel, a
// drag a box. A sheet (the whole picture with the place framed, the place enlarged, an English caption) is stored like
// a pasted picture and named in the picture's own text field (the one beside it, the strip's field, else the last
// one typed in); a running dictation takes the name instead, at the word Egor said when he began the mark.
let lastField = null;
function fieldFor(from) {
  const own = from.closest(".atw");
  if (own) return own.querySelector(FIELD);
  for (let n = from.parentElement; n && n !== document.body; n = n.parentElement) {
    const near = [...n.querySelectorAll(FIELD)];
    if (near.length) return near.includes(lastField) ? lastField : near.at(-1);
  }
  return lastField && lastField.isConnected ? lastField : null;
}
// a point on screen -> px of pane k's own picture
const zpx = ([cx, cy], k) => {
  const f = Z.panes[k].img.naturalWidth / (Z.panes[0].img.naturalWidth || 1);
  return [(cx - k * innerWidth / Z.panes.length - Z.x) / Z.s * f, (cy - Z.y) / Z.s * f];
};
function markMove(e) {
  const m = Z.mark;
  m.b = [e.clientX, e.clientY];
  Z.band.hidden = Math.hypot(m.b[0] - m.a[0], m.b[1] - m.a[1]) <= 5;
  Object.assign(Z.band.style, { left: Math.min(m.a[0], m.b[0]) + "px", top: Math.min(m.a[1], m.b[1]) + "px",
    width: Math.abs(m.b[0] - m.a[0]) + "px", height: Math.abs(m.b[1] - m.a[1]) + "px" });
}
function markEnd(e) {
  const m = Z.mark, im = Z.panes[m.k].img, W = im.naturalWidth, H = im.naturalHeight;
  Z.mark = null; Z.band.hidden = true;
  if (!e || !W) return;
  m.b = [e.clientX, e.clientY];
  const [ax, ay] = zpx(m.a, m.k), [bx, by] = zpx(m.b, m.k), c = (v, top) => Math.min(top, Math.max(0, v));
  let at;
  if (Math.hypot(m.b[0] - m.a[0], m.b[1] - m.a[1]) <= 5) {
    if (ax < 0 || ay < 0 || ax >= W || ay >= H) return;
    at = [Math.floor(ax), Math.floor(ay)];
  } else {
    at = [c(Math.floor(Math.min(ax, bx)), W), c(Math.floor(Math.min(ay, by)), H), c(Math.ceil(Math.max(ax, bx)), W), c(Math.ceil(Math.max(ay, by)), H)];
    if (at[2] <= at[0] || at[3] <= at[1]) return;
  }
  zoomMark(at, m.t, im);
}
async function zoomMark(at, t, im) {
  const src = decodeURIComponent((im.getAttribute("src") || "").split("?")[0].split("/").pop() || "picture");
  const where = (at.length === 2 ? "point " : "box ") + at.join(",") + " px", mark = { at: t, about: `${where} on ${src}` };
  const blob = await new Promise((r) => markSheet(im, at, src, where, Z.s * (Z.panes[0].img.naturalWidth || 1) / im.naturalWidth).toBlob(r, "image/png"));
  if (!blob) return;
  Z.msg.textContent = "сохраняю метку…";
  told = false;
  const names = Z.field ? await attachPicture(Z.field, blob, mark) : [await upload(null, blob, "image/png", mark)].filter(Boolean);
  Z.msg.textContent = !names.length ? "метка не сохранилась" : told ? `[${names[0]}] придёт с диктовкой`
    : Z.field ? `[${names[0]}] — в заметке` : `сохранено как ${names[0]}, но поля для имени нет`;
}
function markSheet(im, at, src, where, z) {
  const W = im.naturalWidth, H = im.naturalHeight, [x0, y0, x1 = x0 + 1, y1 = y0 + 1] = at;
  const m = Math.max(Math.ceil(Math.max(x1 - x0, y1 - y0) / 2), 24), c = [Math.max(0, x0 - m), Math.max(0, y0 - m), Math.min(W, x1 + m), Math.min(H, y1 + m)];
  const k1 = Math.min(480 / W, 480 / H), k2 = Math.min(480 / (c[2] - c[0]), 480 / (c[3] - c[1]), 8);
  const w1 = Math.round(W * k1), h1 = Math.round(H * k1), w2 = Math.round((c[2] - c[0]) * k2), h2 = Math.round((c[3] - c[1]) * k2);
  const text = `${src} (${W}x${H}): Egor marked the ${where} (magenta), looking at ${Math.round(z * 100) / 100}× zoom. `
    + "Left the whole picture, right that place enlarged.";
  const cv = h("canvas", { width: w1 + w2 + 36 }), g = cv.getContext("2d"), font = "13px system-ui", lines = [""];
  g.font = font;
  for (const w of text.split(" ")) {                    // wrapped to the sheet's width, never squeezed
    const t = lines.at(-1) ? lines.at(-1) + " " + w : w;
    if (g.measureText(t).width > cv.width - 24 && lines.at(-1)) lines.push(w); else lines[lines.length - 1] = t;
  }
  cv.height = Math.max(h1, h2) + 30 + lines.length * 17;
  g.fillStyle = "#fff"; g.fillRect(0, 0, cv.width, cv.height);
  g.drawImage(im, 12, 12, w1, h1);
  g.imageSmoothingEnabled = k2 < 3;
  g.drawImage(im, c[0], c[1], c[2] - c[0], c[3] - c[1], w1 + 24, 12, w2, h2);
  g.strokeStyle = "#f0f"; g.lineWidth = 2;
  g.setLineDash([6, 4]); g.strokeRect(12 + c[0] * k1, 12 + c[1] * k1, (c[2] - c[0]) * k1, (c[3] - c[1]) * k1); g.setLineDash([]);
  g.strokeRect(12 + x0 * k1 - 2, 12 + y0 * k1 - 2, (x1 - x0) * k1 + 4, (y1 - y0) * k1 + 4);
  g.strokeRect(w1 + 24 + (x0 - c[0]) * k2 - 2, 12 + (y0 - c[1]) * k2 - 2, (x1 - x0) * k2 + 4, (y1 - y0) * k2 + 4);
  g.fillStyle = "#222"; g.font = font; g.textBaseline = "top";
  lines.forEach((l, i) => g.fillText(l, 12, Math.max(h1, h2) + 22 + i * 17));
  return cv;
}
function onZoomClick(e) {
  const im = e.target.closest && e.target.closest("main img");
  if (!im || (im.closest("[data-own-zoom]") && !im.closest(".att"))) return;
  e.preventDefault(); zoomOpen(im);
}

// Pictures in text. A picture pasted or dropped into any text field (a screenshot, an image copied in a
// browser or an app, an image file copied in Finder or dragged in) is stored by the server and its short
// name, [img3.png], goes in at the caret, so Egor writes «on [img1.png] the bush slides» and the chat's
// `page state` prints img1.png=<absolute path> beside the text. The field sits in a box that shows its
// pictures above the text as equal tiles: a click opens one full screen, the name on a tile puts the name
// back at the caret, × takes the picture and its name out of the field (⌘Z brings both back), and a tile
// whose name is no longer in the text is dimmed. Text-only clipboards paste as text.
const FIELD = "textarea,input[type=text],input:not([type])";
const TOKEN = /\[(img[1-9][0-9]{0,4}\.(?:png|jpg|gif|webp))\]/g;
const strips = new WeakMap();
let known = new Map();   // name -> {item, field}: every picture of the page
const textField = (t) => (t && t.closest ? t.closest(FIELD) : null);
const order = (a, b) => parseInt(a.slice(3)) - parseInt(b.slice(3));

async function loadFiles() {
  try {
    const r = await fetch(`/p/${pid}/files`, { cache: "no-store" });
    if (r.ok) known = new Map((await r.json()).map((f) => [f.name, f]));
  } catch (e) { /* no pictures shown until a paste */ }
}

// The field moves into its box once; one that has the focus keeps it and its selection.
function slot(el) {
  let s = strips.get(el);
  if (!s) strips.set(el, s = { box: h("div", { class: "att", hidden: true }), msg: h("span", { class: "atm" }), chips: new Map(),
    coming: new Set(), gone: new Set() });   // coming: names a dictation will paste here; gone: those taken back with ×
  if (!s.box.isConnected) {
    const had = document.activeElement === el, a = el.selectionStart, b = el.selectionEnd, wrap = h("div", { class: "atw" });
    el.before(wrap);
    wrap.append(s.box, el);
    if (had) { el.focus({ preventScroll: true }); el.setSelectionRange(a, b); }
  }
  return s;
}

function strip(el) {
  if (!el.isConnected) return;
  const inText = new Set([...(el.value || "").matchAll(TOKEN)].map((m) => m[1]).filter((n) => known.has(n)));
  const mine = el.dataset.item ? [...known].filter(([, f]) => f.item === el.dataset.item && f.field === el.dataset.field).map(([n]) => n) : [];
  if (!strips.has(el) && !mine.length && !inText.size) return;
  const s = slot(el);
  for (const name of [...mine, ...inText]) if (!s.chips.has(name)) s.chips.set(name, h("span", { class: "atc" },
    h("img", { src: `/p/${pid}/f/${name}`, alt: name, title: "открыть" }),
    h("button", { type: "button", class: "atn", title: "вставить имя в текст", onmousedown: (e) => e.preventDefault(),
      onclick: () => put(el, `[${name}]`) }, name),
    h("button", { type: "button", class: "atx", title: "убрать картинку", "aria-label": "убрать картинку",
      onmousedown: (e) => e.preventDefault(), onclick: () => remove(el, name) })));
  s.chips.forEach((c, name) => { c.classList.toggle("off", !inText.has(name)); c.title = inText.has(name) ? "" : "имени нет в тексте"; });
  s.box.replaceChildren(...[...s.chips.keys()].sort(order).map((n) => s.chips.get(n)), s.msg);
  s.box.hidden = !s.chips.size && !s.msg.textContent;
}

// A textarea fits its text: two lines at least (the CSS min-height), seven at most, then it scrolls.
function grow(el) {
  if (el.tagName !== "TEXTAREA" || !el.isConnected) return;
  const cs = getComputedStyle(el), px = (k) => parseFloat(cs[k]) || 0;
  const border = px("borderTopWidth") + px("borderBottomWidth"), line = px("lineHeight") || px("fontSize") * 1.45;
  el.style.height = "auto";
  el.style.height = Math.min(el.scrollHeight + border, 7 * line + px("paddingTop") + px("paddingBottom") + border) + "px";
}

// × on a tile: every [name] leaves the text, with one space beside it, through the browser's editing
// (⌘Z restores the text and with it the tile); a picture this field owns stops being shown under it. A mark a
// running dictation took leaves the dictation too (the server's `unmark`); should the paste still bring its name
// here, the name leaves again as it arrives.
function remove(el, name) {
  const s = slot(el), f = known.get(name), waited = s.coming.delete(name);
  if (waited) { s.gone.add(name); el.dispatchEvent(new Event("pictures")); }
  if (f && el.dataset.item && f.item === el.dataset.item && f.field === el.dataset.field) {
    known.set(name, { ...f, item: null, field: null });
    fetch(`/p/${pid}/drop`, { method: "POST", headers: json,
      body: JSON.stringify({ name, item: el.dataset.item, field: el.dataset.field }) })
      .then((r) => r.json()).then((r) => waited && say(el, /^ok /.test(r.unmark || "") ? `[${name}] убрана из диктовки`
        : r.unmark === "ignored pasted" ? `[${name}] уже ушла с диктовкой в другое место — убери её там`
        : `[${name}] уберу, когда диктовка вставится сюда`)).catch(() => {});
  }
  s.chips.delete(name);
  el.focus();
  unput(el, `[${name}]`);
  strip(el);
}
function unput(el, tag) {
  for (let at = el.value.lastIndexOf(tag); at >= 0; at = at ? el.value.lastIndexOf(tag, at - 1) : -1) {
    let a = at, b = at + tag.length;
    if (el.value[a - 1] === " ") a--; else if (el.value[b] === " ") b++;
    el.setSelectionRange(a, b);
    if (!document.execCommand("delete")) {
      el.setRangeText("", a, b, "end");
      el.dispatchEvent(new Event("input", { bubbles: true }));
    }
  }
}

function say(el, text, bad) {
  const s = slot(el);
  s.msg.textContent = text;
  s.msg.classList.toggle("err", !!bad);
  strip(el);
}

// Text at [start, end), one space from its neighbours, through the browser's own editing so ⌘Z undoes
// it and the field's input listener saves it.
function put(el, text, start = el.selectionStart ?? el.value.length, end = el.selectionEnd ?? start) {
  const before = el.value.slice(0, start), after = el.value.slice(end);
  if (before && !/\s$/.test(before)) text = " " + text;
  if (after && !/^\s/.test(after)) text += " ";
  el.focus();
  el.setSelectionRange(start, end);
  if (!document.execCommand("insertText", false, text)) {
    el.setRangeText(text, start, end, "end");
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }
}

// What a clipboard or a drop holds: {files} or {urls} of pictures, {finder} for a Finder copy whose files
// the browser did not hand over, null for text. A file Finder copied comes with its name as the text; a
// rich selection with words in it stays text even when it carries pictures.
function pictures(dt) {
  const plain = dt.getData("text/plain") || "", html = dt.getData("text/html") || "";
  // files and items list the same files, as distinct File objects, so only one of them is read
  const files = (dt.files && dt.files.length ? [...dt.files] : [...(dt.items || [])].filter((i) => i.kind === "file").map((i) => i.getAsFile()))
    .filter((f) => f && /^image\//.test(f.type) && f.type !== "image/svg+xml");
  const names = plain.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const finder = files.filter((f) => names.includes(f.name));
  if (finder.length) return { files: finder };
  const doc = html ? new DOMParser().parseFromString(html, "text/html") : null;
  const words = (doc ? doc.body.textContent : plain).trim().replace(/^https?:\/\/\S+$/, "");
  if (files.length && names.length && names.every((n) => /^[^/\\]+\.[A-Za-z0-9]{2,5}$/.test(n)) && !doc) return { finder: true };
  if (files.length) return words ? null : { files };
  const urls = doc && !words ? [...doc.querySelectorAll("img[src]")].map((i) => i.getAttribute("src")).filter((u) => /^(https?|data):/.test(u)) : [];
  return urls.length ? { urls } : null;
}

// -> the stored name, or null; a marked upload also sets told when a dictation took the name
let told = false;
async function upload(el, body, type, mark) {
  const q = new URLSearchParams(el && el.dataset.item ? { item: el.dataset.item, field: el.dataset.field || "" } : {});
  if (mark) { q.set("at", String(mark.at)); q.set("about", mark.about || ""); }
  try {
    const r = await fetch(`/p/${pid}/upload?${q}`, { method: "POST", headers: { "Content-Type": type }, body });
    if (!r.ok) return null;
    const { name, mark: reply } = await r.json();
    if (!known.has(name)) known.set(name, { item: el && el.dataset.item || null, field: el && el.dataset.field || null });
    if (mark && /^ok /.test(reply || "")) told = true;
    return name;
  } catch (e) { return null; }
}

async function attach(el, got, start, end, mark) {
  if (got.finder) { say(el, "файл из Finder так не вставляется — перетащи его в поле мышкой", true); return []; }
  const was = el.value, names = [];
  say(el, "сохраняю картинку…");
  told = false;
  for (const f of got.files || []) names.push(await upload(el, f, f.type || "application/octet-stream", mark));
  for (const u of got.urls || []) {
    let blob = null;
    if (u.startsWith("data:")) try { blob = await (await fetch(u)).blob(); } catch (e) { /* not a picture */ }
    names.push(blob ? await upload(el, blob, blob.type || "application/octet-stream")
      : await upload(el, JSON.stringify({ url: u }), "application/json"));
  }
  const ok = [...new Set(names.filter(Boolean))], lost = names.filter((n) => !n).length;
  say(el, lost ? (ok.length ? "не все картинки сохранились" : "картинка не сохранилась") : "", lost > 0);
  if (!ok.length) return [];
  if (told) return dictated(el, ok);
  if (el.value !== was) start = end = el.selectionEnd;
  put(el, ok.map((n) => `[${n}]`).join(" "), start, end);
  strip(el);
  return ok;
}
// A picture a module draws itself (compare's «Метка» sheet) goes in like a pasted one; resolves to its stored names.
export const attachPicture = (el, blob, mark) => attach(el, { files: [blob] }, el.selectionStart, el.selectionEnd, mark);

// A mark made while Egor dictates (transcriptions-gpt MARKS.md, relayed by the server): the dictation carries
// [name] at the word he said when he marked, so the caret gets nothing; the field takes the focus back, since the
// dictation pastes into whatever holds it, and says where the name will come from until it arrives.
export const pending = (el) => new Set(strips.get(el)?.coming || []);
function dictated(el, names) {
  const s = slot(el);
  names.forEach((n) => s.coming.add(n));
  el.dispatchEvent(new Event("pictures"));
  say(el, names.map((n) => `[${n}]`).join(" ") + " — придёт с диктовкой");
  s.waiting = true;
  el.focus({ preventScroll: true });
  strip(el);
  return names;
}

// A dictation's paste brought names: those still awaited have arrived, those taken back with × leave again.
function arrived(el, s) {
  const has = (n) => el.value.includes(`[${n}]`), came = [...s.coming].filter(has), back = [...s.gone].filter(has);
  came.forEach((n) => s.coming.delete(n));
  back.forEach((n) => { s.gone.delete(n); unput(el, `[${n}]`); });
  if (came.length) el.dispatchEvent(new Event("pictures"));
}

function onPaste(e) {
  const el = textField(e.target), got = el && e.clipboardData && pictures(e.clipboardData);
  if (!got) return;
  e.preventDefault();
  attach(el, got, el.selectionStart, el.selectionEnd);
}

const carriesFiles = (dt) => dt && [...(dt.types || [])].includes("Files");
function onDragOver(e) {
  if (!carriesFiles(e.dataTransfer)) return;
  e.preventDefault();
  e.dataTransfer.dropEffect = textField(e.target) ? "copy" : "none";
}
// A file dropped anywhere else would navigate away from the page; it is refused instead.
function onDrop(e) {
  const el = textField(e.target), got = el && pictures(e.dataTransfer);
  if (got) { e.preventDefault(); return attach(el, got, el.selectionStart, el.selectionEnd); }
  if (carriesFiles(e.dataTransfer)) e.preventDefault();
}

export async function start(s, r) {
  spec = s; pid = s.pid; render = r; BOX = "pages-outbox:" + pid;
  try { queue = JSON.parse(localStorage.getItem(BOX) || "[]"); } catch (e) { queue = []; }
  header();
  await Promise.all([loadState(), loadFiles()]);
  render(spec, false);
  paint();
  pump();
  setInterval(poll, 4000);
  setInterval(() => queue.length && pump(), 3000);
  addEventListener("online", pump);
  addEventListener("pagehide", flushAll);
  document.addEventListener("visibilitychange", () => (document.visibilityState === "visible" ? poll() : flushAll()));
  document.addEventListener("keydown", onKey);
  document.addEventListener("click", onZoomClick);
  document.addEventListener("paste", onPaste, true);
  document.addEventListener("dragover", onDragOver, true);
  document.addEventListener("drop", onDrop, true);
  document.addEventListener("focusin", (e) => { const el = textField(e.target); if (el) lastField = el; });
  document.addEventListener("input", (e) => {
    const el = textField(e.target), s = el && strips.get(el);
    if (s && s.waiting) { s.waiting = false; s.msg.textContent = ""; }
    if (s && (s.coming.size || s.gone.size)) arrived(el, s);
    if (el) { strip(el); grow(el); }
  }, true);
  addEventListener("resize", () => document.querySelectorAll("textarea").forEach(grow));
}
