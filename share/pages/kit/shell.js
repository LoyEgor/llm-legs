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
  requestAnimationFrame(() => strip(el));
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
      strip(el);
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
// read: the wheel or a pinch zooms at the pointer, a drag pans, a double click toggles fit and 1:1,
// ← → step through the page's pictures, Esc, ✕ or a click beside the picture closes. A module with
// its own zoom marks its root data-own-zoom and keeps its pictures out.
// A field's pictures step among themselves, apart from the page's own.
const zoomable = (from) => from && from.closest(".att") ? [...from.closest(".att").querySelectorAll("img")]
  : [...document.querySelectorAll("main img")].filter((im) => !im.closest("[data-own-zoom],.att"));
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
  Z.list = zoomable(from);
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
  if (!im || (im.closest("[data-own-zoom]") && !im.closest(".att"))) return;
  e.preventDefault(); zoomOpen(im);
}

// Pictures in text. A picture pasted or dropped into any text field (a screenshot, an image copied in a
// browser or an app, an image file copied in Finder or dragged in) is stored by the server and its short
// name, [img3.png], goes in at the caret, so Egor writes «on [img1.png] the bush slides» and the chat's
// `page state` prints img1.png=<absolute path> beside the text. Under the field a strip shows its
// pictures: a click opens one full screen, its name button puts the name back at the caret, and a
// picture whose name is no longer in the text is dimmed. Text-only clipboards paste as text.
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

function slot(el) {
  let s = strips.get(el);
  if (!s) strips.set(el, s = { box: h("div", { class: "att" }), msg: h("span", { class: "atm" }), chips: new Map() });
  if (!s.box.isConnected) el.after(s.box);
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
    h("button", { type: "button", title: "вставить имя в текст", onmousedown: (e) => e.preventDefault(),
      onclick: () => put(el, `[${name}]`) }, name)));
  s.chips.forEach((c, name) => { c.classList.toggle("off", !inText.has(name)); c.title = inText.has(name) ? "" : "имени нет в тексте"; });
  s.box.replaceChildren(...[...s.chips.keys()].sort(order).map((n) => s.chips.get(n)), s.msg);
  s.box.hidden = !s.chips.size && !s.msg.textContent;
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
  const files = [];
  for (const f of [...(dt.files || []), ...[...(dt.items || [])].filter((i) => i.kind === "file").map((i) => i.getAsFile())])
    if (f && /^image\//.test(f.type) && f.type !== "image/svg+xml"
        && !files.some((g) => g.name === f.name && g.size === f.size && g.lastModified === f.lastModified)) files.push(f);
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

async function upload(el, body, type) {
  const q = el.dataset.item ? `?item=${encodeURIComponent(el.dataset.item)}&field=${encodeURIComponent(el.dataset.field || "")}` : "";
  try {
    const r = await fetch(`/p/${pid}/upload${q}`, { method: "POST", headers: { "Content-Type": type }, body });
    if (!r.ok) return null;
    const { name } = await r.json();
    if (!known.has(name)) known.set(name, { item: el.dataset.item || null, field: el.dataset.field || null });
    return name;
  } catch (e) { return null; }
}

async function attach(el, got, start, end) {
  if (got.finder) return say(el, "файл из Finder так не вставляется — перетащи его в поле мышкой", true);
  const was = el.value, names = [];
  say(el, "сохраняю картинку…");
  for (const f of got.files || []) names.push(await upload(el, f, f.type || "application/octet-stream"));
  for (const u of got.urls || []) {
    let blob = null;
    if (u.startsWith("data:")) try { blob = await (await fetch(u)).blob(); } catch (e) { /* not a picture */ }
    names.push(blob ? await upload(el, blob, blob.type || "application/octet-stream")
      : await upload(el, JSON.stringify({ url: u }), "application/json"));
  }
  const ok = [...new Set(names.filter(Boolean))];
  say(el, ok.length < names.length ? (ok.length ? "не все картинки сохранились" : "картинка не сохранилась") : "", ok.length < names.length);
  if (!ok.length) return;
  if (el.value !== was) start = end = el.selectionEnd;
  put(el, ok.map((n) => `[${n}]`).join(" "), start, end);
  strip(el);
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
  document.addEventListener("input", (e) => { const el = textField(e.target); if (el) strip(el); }, true);
}
