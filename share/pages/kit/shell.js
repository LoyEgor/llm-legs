// The module API of the pages kit (share/pages/CONTRACT.md). loader.html calls start(); a module
// exports render(spec, again) and uses only what is exported here:
//   get(id, field)               the shown value: a typed draft, else the outbox, else the server
//   state()                      {id: {field: value}} with the same overlay
//   save(id, fields)             one gesture's changed fields, sent at once (null clears a field)
//   saveText(id, field, value)   the same, debounced 400 ms (sent at once on blur)
//   textBox(id, field, props)    a <textarea> bound to saveText, refreshed when the state moves
//   onState(cb)                  cb(Set of item ids) when the server state changed them
//   doneWhen(fn)                 fn(id) → answered; feeds «N из M» and sitting_cap (null: no count)
//   firstOpen(ids), nextOpen(ids, from)   the first answered-nor-skipped id after index `from`
//   skip(id), capped()           skip for this sitting; sitting_cap answers given this sitting
//   keys(map)                    {event.code: fn}; ignored in text fields and with Cmd/Ctrl/Alt
//   lazy(el)                     el's data-src loads near the viewport and is released far away
//   num(item, i), h(tag, props, ...kids)   the shown number; a DOM element
// render, onState, doneWhen and keys replace their previous value, so a re-render is idempotent.
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
    else if (changed.has(el.dataset.item) && el !== document.activeElement)
      el.value = get(el.dataset.item, el.dataset.field) ?? "";
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
// read: the wheel or a pinch zooms at the pointer, a drag pans, a double click toggles fit and 1:1,
// ← → step through the page's pictures, Esc, ✕ or a click beside the picture closes. A module with
// its own zoom marks its root data-own-zoom and keeps its pictures out.
const zoomable = () => [...document.querySelectorAll("main img")].filter((im) => !im.closest("[data-own-zoom]"));
let Z = null;
function zoomOpen(from) {
  if (!Z) {
    const img = h("img", { alt: "", draggable: false }), pos = h("span", { class: "zpos" });
    const el = h("div", { class: "zoom", role: "dialog", "aria-modal": "true" }, img,
      h("div", { class: "zbar" }, pos, h("span", { class: "mute" }, "колесо — зум · тащи · двойной клик — 1:1 · ← → · Esc"),
        h("button", { onclick: zoomClose, title: "Esc" }, "✕")));
    Z = { el, img, pos, pts: new Map(), s: 1, x: 0, y: 0 };
    const at = (s, px, py) => { s = Math.min(Math.max(s, Z.fit / 2), 8); Z.x = px - (px - Z.x) * s / Z.s; Z.y = py - (py - Z.y) * s / Z.s; Z.s = s; zoomPaint(); };
    Z.at = at;
    el.addEventListener("wheel", (e) => { e.preventDefault(); at(Z.s * Math.exp(-e.deltaY * 0.0015), e.clientX, e.clientY); }, { passive: false });
    el.addEventListener("pointerdown", (e) => { if (e.target.closest(".zbar")) return; el.setPointerCapture(e.pointerId); Z.pts.set(e.pointerId, [e.clientX, e.clientY]); Z.moved = 0; });
    el.addEventListener("pointermove", (e) => {
      const p = Z.pts.get(e.pointerId); if (!p) return;
      const all = [...Z.pts.values()], d0 = all.length === 2 ? Math.hypot(all[0][0] - all[1][0], all[0][1] - all[1][1]) : 0;
      Z.pts.set(e.pointerId, [e.clientX, e.clientY]); Z.moved += Math.abs(e.clientX - p[0]) + Math.abs(e.clientY - p[1]);
      if (all.length === 2) {
        const [a, b] = [...Z.pts.values()], d1 = Math.hypot(a[0] - b[0], a[1] - b[1]);
        if (d0) at(Z.s * d1 / d0, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2);
      } else { Z.x += e.clientX - p[0]; Z.y += e.clientY - p[1]; zoomPaint(); }
    });
    const up = (e) => {
      if (!Z.pts.delete(e.pointerId) || Z.moved > 4 || e.type !== "pointerup") return;
      const r = img.getBoundingClientRect();
      if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) zoomClose();
    };
    el.addEventListener("pointerup", up); el.addEventListener("pointercancel", up);
    el.addEventListener("dblclick", (e) => at(Math.abs(Z.s - Z.fit) < 1e-3 ? Math.max(1, Z.fit * 2) : Z.fit, e.clientX, e.clientY));
    img.addEventListener("load", zoomFit);
    document.addEventListener("keydown", (e) => {
      if (!Z.el.isConnected) return;
      const step = { ArrowLeft: -1, ArrowRight: 1 }[e.code];
      if (e.code === "Escape") zoomClose(); else if (step) zoomShow(Z.i + step);
      else if (e.code === "Equal" || e.code === "Minus") at(Z.s * (e.code === "Equal" ? 1.5 : 1 / 1.5), innerWidth / 2, innerHeight / 2);
      else if (e.code === "Digit0") zoomFit(); else return;
      e.preventDefault(); e.stopImmediatePropagation();
    }, true);
  }
  Z.list = zoomable();
  document.body.append(Z.el); document.body.style.overflow = "hidden";
  zoomShow(Math.max(0, Z.list.indexOf(from)));
}
function zoomShow(i) {
  const n = Z.list.length; Z.i = (i + n) % n;
  const im = Z.list[Z.i];
  Z.pos.textContent = n > 1 ? `${Z.i + 1} / ${n}` : "";
  Z.img.src = im.currentSrc || im.getAttribute("src") || im.dataset.src;
  if (Z.img.complete && Z.img.naturalWidth) zoomFit();
}
function zoomFit() {
  const w = Z.img.naturalWidth, hh = Z.img.naturalHeight, W = innerWidth, H = innerHeight - 44;
  if (!w) return;
  Z.fit = Z.s = Math.min(W / w, H / hh); Z.x = (W - w * Z.s) / 2; Z.y = (H - hh * Z.s) / 2; zoomPaint();
}
function zoomPaint() { Z.img.style.transform = `translate(${Z.x}px,${Z.y}px) scale(${Z.s})`; }
function zoomClose() { Z.el.remove(); Z.pts.clear(); document.body.style.overflow = ""; }
function onZoomClick(e) {
  const im = e.target.closest && e.target.closest("main img");
  if (!im || im.closest("[data-own-zoom]")) return;
  e.preventDefault(); zoomOpen(im);
}

export async function start(s, r) {
  spec = s; pid = s.pid; render = r; BOX = "pages-outbox:" + pid;
  try { queue = JSON.parse(localStorage.getItem(BOX) || "[]"); } catch (e) { queue = []; }
  header();
  await loadState();
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
}
