// cards: numbered cards with native image/audio/video media, fields choice/multi/scale/text and a
// note; a card is done once each choice and scale field has a value (or, with none, once anything is
// set). The spec is in cards.md. Ported from listen-bench defects.py page(): one clip plays at a
// time, an option's key acts on the card most visible on screen, a spec update keeps unchanged cards
// (and a playing clip) in place.
import { h, get, save, textBox, onState, doneWhen, firstOpen, keys, lazy, num } from "/kit/shell.js";

const CSS = `
.cards{max-width:1440px;margin:0 auto}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px 10px 56px;margin:10px 0;position:relative}
.card>.n{position:absolute;left:14px;top:12px;font:700 20px/1 system-ui;font-variant-numeric:tabular-nums}
.card.done>.n{color:var(--on)}
.card h2{font-size:15px;margin:0 0 4px}.card .tx{color:var(--mute);margin:0 0 6px;white-space:pre-line}
.card img,.card video{max-width:100%;min-height:40px;border-radius:6px;display:block;margin:4px 0}.card audio{width:100%;margin:4px 0}
.row{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:6px 0}.row>span:first-child{min-width:72px;color:var(--mute)}
.row button{padding:3px 12px}.row button.on{background:var(--on);border-color:var(--on);color:#fff}
.card>textarea{margin-top:4px}`;
const TAG = { image: "img", audio: "audio", video: "video" };
const app = document.getElementById("app");
let S, ids, cards = new Map(), first = true;

const graded = () => S.fields.filter((f) => f.kind === "choice" || f.kind === "scale");
function isDone(id) {
  const g = graded();
  return g.length ? g.every((f) => get(id, f.key) != null) : [...S.fields.map((f) => f.key), "note"].some((k) => get(id, k) != null);
}

export function render(spec) {
  S = { fields: [], ...spec };
  ids = S.items.map((it) => it.id);
  if (!document.getElementById("cards-css")) document.head.append(h("style", { id: "cards-css" }, CSS));
  doneWhen(isDone);
  onState((changed) => changed.forEach(paint));
  keys(keymap());
  const y = scrollY, old = cards;
  cards = new Map();
  app.replaceChildren(h("div", { class: "cards" }, S.items.map((it, i) => {
    const key = JSON.stringify([it, i, S.fields]), was = old.get(it.id);
    const el = was && was.dataset.key === key ? was : card(it, i);
    el.dataset.key = key;
    cards.set(it.id, el);
    return el;
  })));
  ids.forEach(paint);
  scrollTo(0, y);
  if (first) {
    first = false;
    const id = firstOpen(ids);
    if (id && id !== ids[0]) cards.get(id).scrollIntoView({ block: "start" });
  }
}

function card(it, i) {
  return h("section", { class: "card", "data-id": it.id }, h("div", { class: "n" }, `${num(it, i)}`),
    it.title ? h("h2", {}, it.title) : null, it.text ? h("p", { class: "tx" }, it.text) : null,
    (it.media || []).map((m) => {
      const tag = TAG[m.kind] || "img";
      return lazy(h(tag, { "data-src": m.src, alt: "", controls: tag !== "img", preload: tag === "img" ? null : "metadata" }));
    }),
    S.fields.map((f) => row(it.id, f)), suggest(it), textBox(it.id, "note", { placeholder: "заметка" }));
}

const values = (f) => f.kind === "scale"
  ? Array.from({ length: (f.max ?? 5) - (f.min ?? 1) + 1 }, (_, k) => ({ id: (f.min ?? 1) + k }))
  : f.options || [];

function row(id, f) {
  const label = h("span", {}, f.label || f.key);
  if (f.kind === "text") return h("div", { class: "row" }, label, textBox(id, f.key));
  return h("div", { class: "row", "data-f": f.key }, label, values(f).map((o) =>
    h("button", { "data-v": String(o.id), onclick: () => pick(id, f, o.id) }, o.label || String(o.id))));
}

function suggest(it) {
  if (!it.suggest) return null;
  const say = Object.entries(it.suggest).map(([k, v]) => {
    const f = S.fields.find((x) => x.key === k), opts = f ? values(f) : [];
    const name = (x) => (opts.find((o) => String(o.id) === String(x)) || {}).label || String(x);
    return `${f ? f.label || f.key : k} ${[].concat(v).map(name).join(", ")}`;
  });
  return h("div", { class: "row" }, h("span", { class: "sg" }, say.join(" · ")));
}

function pick(id, f, v) {
  const was = get(id, f.key);
  if (f.kind === "multi") {
    const s = new Set(was || []);
    if (s.has(v)) s.delete(v); else s.add(v);
    save(id, { [f.key]: s.size ? [...s] : null });
  } else save(id, { [f.key]: was === v ? null : v });
  paint(id);
}

function paint(id) {
  const el = cards.get(id);
  if (!el) return;
  el.querySelectorAll(".row[data-f]").forEach((r) => {
    const v = get(id, r.dataset.f), on = [].concat(v ?? []).map(String);
    r.querySelectorAll("button").forEach((b) => b.classList.toggle("on", on.includes(b.dataset.v)));
  });
  el.classList.toggle("done", isDone(id));
}

// The card a key acts on: the last one touched while it is still on screen, else the most visible.
let touched = null;
const visible = (el) => { const r = el.getBoundingClientRect(); return Math.min(r.bottom, innerHeight) - Math.max(r.top, 0); };
function seen() {
  if (touched && cards.get(touched) && visible(cards.get(touched)) > 0) return touched;
  let best = null, most = 0;
  for (const [id, el] of cards) if (visible(el) > most) { most = visible(el); best = id; }
  return best;
}
const touch = (e) => { const c = e.target.closest && e.target.closest(".card"); if (c) touched = c.dataset.id; };
document.addEventListener("pointerdown", touch, true);

function keymap() {
  const m = {};
  for (const f of S.fields) for (const o of f.kind === "choice" || f.kind === "multi" ? f.options || [] : [])
    if (o.key) m[o.key] = () => { const id = seen(); if (id) pick(id, f, o.id); };
  return m;
}

document.addEventListener("play", (e) => {
  touch(e);
  document.querySelectorAll("audio,video").forEach((a) => { if (a !== e.target) a.pause(); });
}, true);
