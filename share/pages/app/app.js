// The chats app: Egor's live Mac chats on the iPad (share/pages/CONTRACT.md "App"). No build step, no framework.
import {VENDOR, ICON, DEFS} from './icons.js';

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const kept = (k) => { try { return JSON.parse(localStorage.getItem(k) || '{}'); } catch { return {}; } };
const keep = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} };
const now = () => Date.now() / 1000;
const norm = (t) => String(t || '').replace(/\s+/g, ' ').trim();

const seen = kept('seen');
const drafts = kept('drafts');
const S = {chats: [], workers: [], runs: [], machine: null, sid: null, log: null, running: {}, menuOpen: new Set(),
  pages: null, screen: '', screenAt: 0, screenFails: 0, screenErr: '', scr: parseScreen(''), auth: true, sheet: '',
  activity: ''};

document.body.insertAdjacentHTML('afterbegin', DEFS);
for (const el of document.querySelectorAll('[data-icon]')) el.innerHTML = ICON[el.dataset.icon] || '';

// ------------------------------------------------------------------ plumbing

let toastTimer = 0;
function toast(text) {
  const t = $('#toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 4000);
}

// What went wrong on this side, for `page report` (the server caps it): a lost connection once it is back.
function report(doc) {
  fetch('/api/client-log', {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(Object.assign({ua: navigator.userAgent.slice(0, 120), sid: S.sid || ''}, doc))}).catch(() => {});
}
let errors = 0;
window.addEventListener('error', (e) => {
  if (errors++ < 3) report({kind: 'error', msg: String(e.message || e.error), path: `${e.filename || ''}:${e.lineno || ''}`});
});

// "No connection" only for a real outage: three failed calls over 5 s while the page is visible. iOS fails every
// fetch of a page it suspends, so calls made hidden or within 3 s of coming back never count.
const NET = {fails: 0, since: 0, last: '', shown: false, visibleAt: 0};
function failed(path, e) {
  if (document.visibilityState !== 'visible' || now() - NET.visibleAt < 3) return;
  NET.fails++;
  NET.since = NET.since || now();
  NET.last = `${path}: ${e.name || ''} ${e.message || e}`.slice(0, 200);
  if (!NET.shown && NET.fails >= 3 && now() - NET.since >= 5) { NET.shown = true; $('#offline').hidden = false; }
}
function reached() {
  if (!NET.fails) return;
  if (NET.shown || NET.fails >= 2) {
    report({kind: NET.shown ? 'offline' : 'blip', ms: Math.round((now() - NET.since) * 1000), count: NET.fails,
      msg: NET.last, hidden: document.visibilityState !== 'visible'});
  }
  Object.assign(NET, {fails: 0, since: 0, last: '', shown: false});
  $('#offline').hidden = true;
}

async function api(path, body) {
  const init = body ? {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)}
    : {cache: 'no-store'};
  if (!body && AbortSignal.timeout) init.signal = AbortSignal.timeout(20000);
  let r;
  try {
    r = await fetch(path, init);
  } catch (e) {
    failed(path, e);
    throw e;
  }
  reached();
  if (r.status === 403) {
    S.auth = false;
    renderMachine();
    throw new Error('auth');
  }
  let d = {};
  try { d = await r.json(); } catch {}
  if (!r.ok && !body) throw new Error(d.err || 'HTTP ' + r.status);
  return d;
}

// One call of each kind in flight at a time; a slow Mac never stacks requests up.
async function once(key, fn) {
  if (S.running[key]) return;
  S.running[key] = true;
  try { await fn(); } catch (e) { if (e.message !== 'auth' && e.name !== 'TypeError' && e.name !== 'TimeoutError') console.warn(key, e); }
  finally { S.running[key] = false; }
}

function ago(t) {
  const s = now() - t;
  if (!t || isNaN(s)) return '';
  if (s < 60) return 'now';
  if (s < 3600) return Math.floor(s / 60) + 'm';
  if (s < 86400) return Math.floor(s / 3600) + 'h';
  return Math.floor(s / 86400) + 'd';
}
// The statusline's own elapsed format (docs/statusline-contract.md "Work lines"): 45s, 4m 05s, 1h 02m.
function dur(s) {
  s = Math.max(0, Math.floor(s));
  if (s < 60) return s + 's';
  if (s < 3600) return Math.floor(s / 60) + 'm ' + String(s % 60).padStart(2, '0') + 's';
  return Math.floor(s / 3600) + 'h ' + String(Math.floor((s % 3600) / 60)).padStart(2, '0') + 'm';
}
function left(t) {
  const s = (t || 0) - now();
  if (s <= 0) return '';
  const m = Math.ceil(s / 60);
  return m >= 60 ? Math.floor(m / 60) + 'h' + String(m % 60).padStart(2, '0') : m + 'm';
}

const base = (p) => (p || '').replace(/\/+$/, '').split('/').pop();
const shortModel = (m) => (m || '').replace(/^claude-/, '').replace(/-(\d+)-(\d+)$/, ' $1.$2').replace(/\[1m\]/, ' 1M');
const kTok = (n) => n ? (n >= 1000 ? Math.round(n / 1000) + 'k' : String(n)) : '';
const runOf = (sid) => S.runs.find((r) => r.sid === sid);
const chat = (sid) => S.chats.find((c) => c.sid === sid) || S.workers.find((c) => c.sid === sid);
const live = (c) => !!c && S.chats.includes(c) && !!c.tty;
const busy = (c) => !!c && (c.status === 'busy' || (!!S.scr.spin && S.sid === c.sid && now() - S.screenAt < 8));

// Every [data-since] counts up once a second without a re-render.
function clocks(root = document) {
  for (const el of root.querySelectorAll('[data-since]')) el.textContent = dur(now() - +el.dataset.since);
}

// ------------------------------------------------------------------ machine and the sidebar

function meter(label, a, b, max, value) {
  const pa = Math.max(0, Math.min(100, (a / max) * 100));
  const pb = Math.max(0, Math.min(100 - pa, (b / max) * 100));
  return `<span>${label}</span><div class="bar"><i class="a" style="left:0;width:${pa}%"></i>` +
    `<i class="b" style="left:${pa}%;width:${pb}%"></i></div><span>${value}</span>`;
}

function renderMachine() {
  const box = $('#machine');
  if (!S.auth) {
    box.innerHTML = '<div class="warn">403: open the <b>page lan --app</b> link once</div>';
    return;
  }
  const m = S.machine || {lines: []};
  let html = '';
  const cpu = (m.lines || []).map((l) => l.match(/CPU\s+([\d.]+) chats \+\s+([\d.]+) other =\s+([\d.]+) of (\d+)/)).find(Boolean);
  const mem = (m.lines || []).map((l) => l.match(/Mem\s+([\d.]+) chats \+\s+([\d.]+) other =\s+([\d.]+) GB · RAM ([\d.]+) of (\d+)(?: · swap ([\d.]+))?/)).find(Boolean);
  if (cpu) html += meter('CPU', +cpu[1], +cpu[2], +cpu[4], `${(+cpu[3]).toFixed(1)}/${cpu[4]}`);
  if (mem) {
    const used = +mem[4], max = +mem[5], share = (+mem[1]) / Math.max(0.1, +mem[3]);
    html += meter('RAM', used * share, used * (1 - share), max, `${used.toFixed(1)}/${max}` + (mem[6] ? ` ⇄${(+mem[6]).toFixed(0)}` : ''));
  }
  box.innerHTML = html;
  box.classList.toggle('alarm', !!m.alarm);
}

function snippet(c) {
  if (c.last && c.last.t) return (c.last.role === 'user' ? 'You: ' : '') + c.last.t;
  return c.away || base(c.cwd) || '';
}

const SPIN = '<svg class="spin" viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" opacity=".3" d="M18 12a6 6 0 1 0-12 0 6 6 0 0 0 12 0zm2 0a8 8 0 1 1-16 0 8 8 0 0 1 16 0z"/><path fill="currentColor" d="M12 4a8 8 0 1 1-8 8h2a6 6 0 1 0 6-6V4z"/></svg>';

function chatRow(c, usual) {
  const warm = left(c.until);
  const unread = c.spoke && c.spoke > (seen[c.sid] || 0) + 1 && S.sid !== c.sid;
  const lead = c.status === 'busy' ? SPIN : c.status === 'shell' ? SPIN.replace('class="spin"', 'class="spin dim"')
    : unread ? '<span class="dot"></span>' : '';
  const acct = c.account && c.account !== usual ? c.account + ' · ' : '';
  return `<a class="row${S.sid === c.sid ? ' sel' : ''}${unread ? ' unread' : ''}" href="#chat/${esc(c.sid)}">` +
    `<span class="lead">${lead}</span><div class="body"><div class="l1"><span class="name">${esc(c.name)}</span>` +
    `<span class="tm${warm ? ' warm' : ''}">${warm ? '◔ ' + warm : ago(c.spoke)}</span></div>` +
    `<div class="l2">${esc(acct + snippet(c))}</div></div></a>`;
}

function runMeta(r) {
  return [r.account, [shortModel(r.model), r.effort].filter(Boolean).join(' ')].filter(Boolean).join(' · ');
}

function runRow(r) {
  const launcher = S.chats.find((c) => c.sid === r.launcher);
  const tag = r.sid ? 'a' : 'div';
  const sub = [r.queued ? 'waiting for a slot' : '', runMeta(r), launcher ? '↖ ' + launcher.name : ''].filter(Boolean).join(' · ');
  return `<${tag} class="row run${r.queued ? ' queued' : ''}${r.sid && S.sid === r.sid ? ' sel' : ''}"` +
    `${r.sid ? ` href="#chat/${esc(r.sid)}"` : ''}><span class="lead">${VENDOR[r.vendor] || VENDOR.claude}</span>` +
    `<div class="body"><div class="l1"><span class="name">${esc(r.title)}</span>` +
    `<span class="tm" data-since="${r.started}"></span></div><div class="l2">${esc(sub)}</div></div></${tag}>`;
}

function renderList() {
  const box = $('#list');
  const top = box.scrollTop;
  // The account shows only where it is not the usual one.
  const count = {};
  for (const c of S.chats) count[c.account] = (count[c.account] || 0) + 1;
  const usual = Object.keys(count).sort((a, b) => count[b] - count[a])[0];
  let html = '<div class="sec">Chats</div>' + S.chats.map((c) => chatRow(c, usual)).join('');
  const others = S.workers.map((w) => Object.assign({}, w, {vendor: 'claude', title: w.name, started: w.started, sid: w.sid}));
  if (S.runs.length || others.length) {
    html += `<div class="sec">Workers <span>${S.runs.length + others.length}</span></div>` +
      S.runs.map(runRow).join('') + others.map(runRow).join('');
  }
  box.innerHTML = html;
  box.scrollTop = top;
  clocks(box);
}

async function refreshChats() {
  await once('chats', async () => {
    const d = await api('/api/chats');
    S.auth = true;
    // New client files reload the app (a home-screen app has no reload button); the draft and the open chat stay,
    // a running dictation or a message on its way finishes first.
    if (d.client && !S.client) S.client = d.client;
    if (d.client && d.client !== S.client && MIC.state === '' && !OUT.some((o) => o.state === 'sending')) {
      if (S.sid) { drafts[S.sid] = $('#input').value; keep('drafts', drafts); }
      location.reload();
      return;
    }
    S.chats = d.chats || [];
    S.workers = d.workers || [];
    S.runs = d.runs || [];
    let fresh = false;
    for (const c of S.chats.concat(S.workers)) {
      // A chat the app has never shown starts read: the dot means "spoke since you last looked here".
      if (c.spoke && seen[c.sid] == null) { seen[c.sid] = c.spoke; fresh = true; }
    }
    if (fresh) keep('seen', seen);
    S.machine = d.machine;
    const open = S.sid && chat(S.sid);
    if (open && open.spoke) { seen[S.sid] = open.spoke; keep('seen', seen); }
    renderMachine();
    renderList();
    if (S.sid) { renderHead(); renderActivity(); renderDock(); }
  });
}

// ------------------------------------------------------------------ markdown, the small part Claude writes

function inline(s) {
  return s.split(/(`[^`\n]+`)/).map((p) => {
    if (p.length > 1 && p[0] === '`' && p[p.length - 1] === '`') return '<code>' + esc(p.slice(1, -1)) + '</code>';
    return esc(p)
      .replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>')
      .replace(/\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>')
      .replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, '$1<a href="$2" target="_blank" rel="noopener">$2</a>');
  }).join('');
}

function table(rows) {
  const cells = (r) => r.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
  const body = rows.filter((r) => !(/^[\s|:-]+$/.test(r) && r.includes('-')));
  return '<div class="tblw"><table class="md">' + body.map((r, k) => '<tr>' +
    cells(r).map((c) => (k === 0 ? `<th>${inline(c)}</th>` : `<td>${inline(c)}</td>`)).join('') + '</tr>').join('') +
    '</table></div>';
}

function md(src) {
  const lines = src.split('\n');
  const out = [];
  let para = [], list = null, i = 0;
  const endPara = () => {
    if (para.length) out.push('<p>' + para.map(inline).join('<br>') + '</p>');
    para = [];
  };
  const endList = () => { if (list) out.push(`</${list}>`); list = null; };
  while (i < lines.length) {
    const line = lines[i];
    let m;
    if (/^\s*```/.test(line)) {
      endPara(); endList();
      const buf = [];
      i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) buf.push(lines[i++]);
      i++;
      out.push('<pre class="code"><code>' + esc(buf.join('\n')) + '</code></pre>');
      continue;
    }
    if (/^\s*\|.*\|\s*$/.test(line)) {
      endPara(); endList();
      const buf = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) buf.push(lines[i++]);
      out.push(table(buf));
      continue;
    }
    if ((m = line.match(/^(#{1,4})\s+(.*)/))) {
      endPara(); endList();
      out.push(`<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`);
    } else if ((m = line.match(/^\s*([-*•]|(\d+)[.)])\s+(.*)/))) {
      endPara();
      const kind = m[2] ? 'ol' : 'ul';
      if (list !== kind) { endList(); out.push(`<${kind}>`); list = kind; }
      out.push(`<li${m[2] ? ` value="${m[2]}"` : ''}>${inline(m[3])}</li>`);
    } else if ((m = line.match(/^>\s?(.*)/))) {
      endPara(); endList();
      out.push('<blockquote>' + inline(m[1]) + '</blockquote>');
    } else if (!line.trim()) {
      endPara(); endList();
    } else {
      endList();
      para.push(line);
    }
    i++;
  }
  endPara(); endList();
  return out.join('');
}

// ------------------------------------------------------------------ the transcript

function node(cls, html) {
  const d = document.createElement('div');
  d.className = cls;
  d.innerHTML = html;
  return d;
}

function toolNode(it, L) {
  const d = document.createElement('details');
  d.className = 'tool';
  const [head, ...rest] = (it.s || '').split('\n');
  d.innerHTML = `<summary><span class="n">${esc(it.n)}</span> ${esc(head)}</summary>` +
    (rest.length ? `<pre>${esc(rest.join('\n'))}</pre>` : '');
  if (it.id) L.tools[it.id] = d;
  return d;
}

function resultNode(it) {
  const d = document.createElement('details');
  d.className = 'tool' + (it.err ? ' err' : '');
  d.innerHTML = `<summary><span class="n">↳</span> ${esc((it.t || '').split('\n')[0])}</summary><pre>${esc(it.t || '∅')}</pre>`;
  return d;
}

// A run of tool calls between two things said folds into one "Worked 1m 20s · Bash 3 · Read" row, as Codex does.
function workGroup() {
  const el = document.createElement('details');
  el.className = 'work';
  el.innerHTML = '<summary><span class="wl"></span><span class="names"></span><span class="err"></span></summary><div class="wbody"></div>';
  return {el, body: el.lastChild, n: 0, tools: 0, head: '', names: {}, first: null, last: null, err: false};
}
const toolName = (n) => (n || '?').replace(/^mcp__[^_]+__/, '');
function summarize(g) {
  const names = Object.entries(g.names).sort((a, b) => b[1] - a[1]).map(([n, k]) => (k > 1 ? `${n} ${k}` : n));
  const secs = g.first && g.last ? (Date.parse(g.last) - Date.parse(g.first)) / 1000 : NaN;
  const sum = g.el.firstChild;
  const one = g.tools === 1;
  sum.children[0].textContent = one ? Object.keys(g.names)[0] : secs >= 1 ? 'Worked ' + dur(secs) : g.n + ' steps';
  sum.children[1].textContent = one ? g.head : names.slice(0, 4).join(' · ') + (names.length > 4 ? ' …' : '');
  sum.children[2].textContent = g.err ? '!' : '';
}

function userNode(text, cls = '') {
  return node('msg user' + cls, esc(text.trim()));
}

// items -> nodes in frag; ctx.group is the work row still taking tool calls (L itself while appending).
function addItems(items, L, ctx, frag) {
  for (const it of items) {
    if (it.k === 'result' && it.id && L.tools[it.id]) {
      if (L.running && L.running.id === it.id) L.running = null;
      const t = L.tools[it.id];
      t.insertAdjacentHTML('beforeend', `<pre>${esc(it.t || '∅')}</pre>`);
      const g = L.groups[it.id];
      if (it.err) { t.classList.add('err'); if (g) g.err = true; }
      if (g) { if (it.at) g.last = it.at; summarize(g); }
      continue;
    }
    if (it.k === 'tool' || it.k === 'result') {
      if (!ctx.group) { ctx.group = workGroup(); frag.appendChild(ctx.group.el); }
      const g = ctx.group;
      g.body.appendChild(it.k === 'tool' ? toolNode(it, L) : resultNode(it));
      g.n++;
      if (it.k === 'tool') {
        const name = toolName(it.n);
        g.names[name] = (g.names[name] || 0) + 1;
        g.tools++;
        g.head = g.head || (it.s || '').split('\n')[0];
        if (it.id) L.groups[it.id] = g;
        if (!ctx.older) L.running = {id: it.id, n: name, head: (it.s || '').split('\n')[0]};
      }
      if (it.err) g.err = true;
      if (it.at) { g.first = g.first || it.at; g.last = it.at; }
      summarize(g);
      continue;
    }
    // Claude Code's queue, mirrored: what he typed while the chat works waits there until the next step takes
    // it. History (an older window) has no live queue left to show.
    if (it.k === 'queued' || it.k === 'unqueued') {
      if (!ctx.older) queueItem(it, L, frag);
      continue;
    }
    ctx.group = null;
    if (!ctx.older && (it.k === 'user' || it.k === 'asst')) L.running = null;
    if (it.k === 'user') { settle(it.t, it.at); unqueue(L, (q) => q.t === norm(it.t)); frag.appendChild(userNode(it.t)); }
    else if (it.k === 'asst') frag.appendChild(node('msg asst', md(it.t)));
    else if (it.k === 'event') frag.appendChild(node('event', esc(it.t)));
    else if (it.k === 'away') frag.appendChild(node('away', '↺ ' + esc(it.t)));
  }
}

// One queue entry: {id, t, raw, nodes}; nodes is null for Claude Code's own notifications, kept only to stay in
// step. His can be taken back until the chat reads it (Delete: POST unqueue).
let qSeq = 0;
function queueItem(it, L, frag) {
  if (it.k === 'queued') {
    const q = {id: ++qSeq, t: norm(it.t), raw: it.t, nodes: null};
    if (!it.hide) {
      q.nodes = [userNode(it.t, ' queued'),
        node('state q', `<span>Queued · goes in at the next step</span><button data-unq="${q.id}">Delete</button>`)];
      q.nodes.forEach((x) => frag.appendChild(x));
      settle(it.t, it.at);
    }
    L.queue.push(q);
  } else if (it.op === 'dequeue') {
    unqueue(L, () => true);  // names no text: the head goes in as the next turn
  } else {
    unqueue(L, it.hide ? (q) => !q.nodes : (q) => q.t === norm(it.t));
  }
}
function unqueue(L, match) {
  const k = L.queue.findIndex(match);
  if (k < 0) return;
  const [q] = L.queue.splice(k, 1);
  if (q.nodes) q.nodes.forEach((x) => x.remove());
}

function resetLog() {
  OLDER.disconnect();
  S.log = {start: null, end: null, tools: {}, groups: {}, queue: [], group: null};
  $('#col').innerHTML = '';
  S.activity = '';
  $('#activity').innerHTML = '';
  STICK.on = true;
}

// Earlier history loads itself as he scrolls near the top (the button stays for a tap); the block that came in fades
// up and a line glows for a moment where it meets what was already there.
const OLDER = new IntersectionObserver((seen) => {
  if (seen.some((e) => e.isIntersecting) && S.log && S.log.first === false) loadOlder();
}, {root: $('#log'), rootMargin: '600px 0px 0px 0px'});

function olderButton() {
  const b = document.createElement('button');
  b.className = 'older';
  b.textContent = 'Earlier';
  b.onclick = loadOlder;
  OLDER.observe(b);
  return b;
}

async function pullLog() {
  const sid = S.sid;
  if (!sid || !S.log) return;
  await once('log', async () => {
    const L = S.log;
    const d = await api(`/api/chat/${encodeURIComponent(sid)}/log` + (L.end == null ? '' : `?after=${L.end}`));
    if (sid !== S.sid || L !== S.log) return;
    if (L.end != null && d.size < L.end) { resetLog(); return; }
    const col = $('#col');
    if (L.start == null) {
      L.start = d.start;
      if (d.start > 0) col.appendChild(olderButton());
    }
    L.end = d.end;
    const items = d.items || [];
    if (items.length) {
      const frag = document.createDocumentFragment();
      addItems(items, L, L, frag);
      col.insertBefore(frag, col.querySelector('.out-first'));
      renderActivity();
    }
    if (L.first !== false) { L.first = false; outRender(); toBottom(); }
    else if (items.length) grew();
  });
}

async function loadOlder() {
  const sid = S.sid, L = S.log;
  if (!L || !L.start) return;
  await once('older', async () => {
    const was = $('#col .older');
    if (was) was.classList.add('busy');
    let d;
    try { d = await api(`/api/chat/${encodeURIComponent(sid)}/log?before=${L.start}`); }
    finally { if (was) was.classList.remove('busy'); }
    if (sid !== S.sid || L !== S.log) return;
    const box = $('#log');
    const h0 = box.scrollHeight;
    if (was) { OLDER.unobserve(was); was.remove(); }
    const frag = document.createDocumentFragment();
    if (d.start > 0) frag.appendChild(olderButton());
    addItems(d.items || [], L, {group: null, older: true}, frag);
    for (const n of frag.children) if (!n.classList.contains('older')) n.classList.add('came');
    const seam = document.createElement('div');
    seam.className = 'seam';
    seam.addEventListener('animationend', () => seam.remove());
    frag.appendChild(seam);
    L.start = d.start;
    $('#col').prepend(frag);
    box.scrollTop += box.scrollHeight - h0;
  });
}

// Stick to the end only while he is there: new items, a growing dock or keyboard keep the last line in view, a
// scroll up stays put (no poll moves it), and nothing scrolls under a finger.
const STICK = {on: true, touch: false};
function toBottom() {
  const box = $('#log');
  box.scrollTop = box.scrollHeight;
  STICK.on = true;
  $('#jump').hidden = true;
}
function grew() {
  if (STICK.on && !STICK.touch) toBottom();
  else $('#jump').hidden = false;
}
$('#log').addEventListener('scroll', () => {
  const b = $('#log');
  STICK.on = b.scrollHeight - b.scrollTop - b.clientHeight < 40;
  $('#jump').hidden = STICK.on;
}, {passive: true});
$('#log').addEventListener('touchstart', () => { STICK.touch = true; }, {passive: true});
$('#log').addEventListener('touchend', () => { setTimeout(() => { STICK.touch = false; }, 400); }, {passive: true});
$('#jump').addEventListener('click', toBottom);
new ResizeObserver(() => {
  $('#chat').style.setProperty('--dock', $('#dock').offsetHeight + 'px');
  if (STICK.on && !STICK.touch) toBottom();
}).observe($('#log'));

// ------------------------------------------------------------------ the outbox: what he sent, bound to its chat

// A message belongs to the chat it was written in from the tap on: the composer empties at once, the request runs
// whatever he opens next, and its bubble stays in that chat until the transcript shows it (as said or queued).
const OUT = [];
let outSeq = 0;

function outbox(sid, text) {
  const o = {id: ++outSeq, sid, text, state: 'sending', err: ''};
  OUT.push(o);
  deliver(o);
  return o;
}

async function deliver(o) {
  o.state = 'sending';
  o.at = now();
  outRender();
  const d = await api(`/api/chat/${encodeURIComponent(o.sid)}/send`, {text: o.text}).catch(() => ({ok: false, err: 'no connection'}));
  if (!OUT.includes(o)) return;
  o.state = d.ok ? 'sent' : 'failed';
  o.err = d.err || '';
  outRender();
  if (d.ok && o.sid === S.sid) setTimeout(() => { pullScreen(); pullLog(); }, 400);
}

// The transcript took a message of the open chat, said at `at`: its own bubble, else (a text the transcript
// rewrote) the oldest one on its way since. History older than a send never settles it: a chat reopened replays
// its whole tail. Clocks of the iPad and the Mac agree within seconds (both NTP).
function settle(text, at) {
  const t = Date.parse(at) / 1000;
  if (!t) return;
  const mine = OUT.filter((o) => o.sid === S.sid && o.state !== 'failed');
  const o = mine.find((x) => norm(x.text) === norm(text) && t >= x.at - 30)
    || (OUT.some((x) => norm(x.text) === norm(text)) ? null : mine.find((x) => t >= x.at - 2));
  if (o) { OUT.splice(OUT.indexOf(o), 1); outRender(); }
}

function outRender() {
  const col = $('#col');
  col.querySelectorAll('.out-n').forEach((n) => n.remove());
  const mine = OUT.filter((o) => o.sid === S.sid);
  mine.forEach((o, k) => {
    const b = userNode(o.text, ' out out-n' + (o.state === 'failed' ? ' failed' : '') + (k === 0 ? ' out-first' : ''));
    col.appendChild(b);
    const s = node('state out-n' + (o.state === 'failed' ? ' err' : ''), o.state === 'failed'
      ? `Not sent: ${esc(o.err)}<button data-retry="${o.id}">Retry</button><button data-drop="${o.id}">Delete</button>`
      : o.state === 'sending' ? 'Sending…' : 'Sent');
    col.appendChild(s);
  });
  if (mine.length) grew();
}

async function takeBack(q) {
  const sid = S.sid, label = q.nodes[1].firstChild;
  q.nodes[1].querySelector('button').hidden = true;
  label.textContent = 'Taking it back…';
  const d = await api(`/api/chat/${encodeURIComponent(sid)}/unqueue`, {text: q.raw}).catch(() => ({ok: false, err: 'no connection'}));
  if (!d.ok) {
    toast('⚠ ' + (d.err || 'failed'));
    label.textContent = 'Queued · goes in at the next step';
    q.nodes[1].querySelector('button').hidden = false;
  }
  // What the Mac's input lost on the way comes back as unsent messages of that chat, one tap from going again.
  for (const t of d.back || []) OUT.push({id: ++outSeq, sid, text: t, state: 'failed', err: 'it came out of the queue', at: now()});
  if ((d.back || []).length) outRender();
  setTimeout(pullLog, 300);
}

$('#col').addEventListener('click', (e) => {
  const u = e.target.closest('[data-unq]');
  if (u) {
    const q = S.log && S.log.queue.find((x) => x.id === +u.dataset.unq);
    if (q && q.nodes) takeBack(q);
    return;
  }
  const r = e.target.closest('[data-retry]'), x = e.target.closest('[data-drop]');
  const o = OUT.find((m) => m.id === +(r || x || {dataset: {}}).dataset[r ? 'retry' : 'drop']);
  if (!o) return;
  if (r) deliver(o);
  else { OUT.splice(OUT.indexOf(o), 1); outRender(); }
});

// ------------------------------------------------------------------ the Terminal screen

// What the screen says that the transcript does not: the spinner line while it works, a menu's numbered options,
// the suggestion dimmed in the empty prompt (Tab takes it), and the statusline under the prompt box.
function parseScreen(text) {
  const lines = (text || '').replace(/[\s ]+$/, '').split('\n');
  const out = {lines, opts: [], cur: null, spin: null, prompt: '', status: []};
  const rule = (l) => /^\s*─{8,}\s*$/.test(l);
  let r2 = -1, r1 = -1;
  for (let i = lines.length - 1; i > 0 && i > lines.length - 40; i--) {
    if (rule(lines[i])) {
      for (let j = i - 1; j >= 0 && j > i - 12; j--) {
        if (rule(lines[j])) {
          if (/^\s*❯/.test(lines[j + 1] || '')) { r1 = j; r2 = i; }
          break;
        }
      }
      if (r1 >= 0) break;
    }
  }
  if (r1 >= 0) {
    out.prompt = lines.slice(r1 + 1, r2).map((l, k) => (k === 0 ? l.replace(/^\s*❯\s?/, '') : l).trim()).join(' ').trim();
    out.status = lines.slice(r2 + 1).map((l) => l.trim())
      .filter((l) => l && !/^(⏵⏵|⏸|\?\s*for shortcuts)/.test(l)).slice(0, 2);
    for (let i = r1 - 1; i >= 0 && i > r1 - 25; i--) {
      const m = lines[i].match(/^\s*([·✢✳✶✻✽*])\s+([^\s(][^(]*?…)\s*(?:\((.*?)\)?)?\s*$/u);
      if (m) {
        const detail = (m[3] || '').split('·').map((s) => s.trim()).filter((s) => s && !/esc to|ctrl\+|tokens?$|^[↓↑]/.test(s));
        out.spin = {verb: m[2].trim(), detail: detail.join(' · ')};
        break;
      }
      if (/^\s*⏺/.test(lines[i])) break;
    }
  }
  let cur = null;
  const opts = [];
  for (const line of lines.slice(-40)) {
    const m = line.match(/^[\s│|]*(❯)?\s*(\d{1,2})\.\s+(.+?)[\s│|]*$/);
    if (!m) continue;
    const n = +m[2];
    if (n === 1) { opts.length = 0; cur = null; }
    if (n === opts.length + 1) {
      opts.push(m[3]);
      if (m[1]) cur = n;
    }
  }
  if (cur != null && opts.length >= 2) {
    out.opts = opts;
    out.cur = cur;
    // The question: the few text lines right above option 1, up to a rule, a ⏺ line or a gap after text.
    const tail = lines.slice(-40);
    const first = tail.findIndex((l, k) => /^[\s│|]*(❯\s*)?1\.\s/.test(l) && tail.slice(k).some((x) => /^[\s│|]*(❯\s*)?2\.\s/.test(x)));
    const ask = [];
    for (let k = first - 1; k >= 0 && ask.length < 3; k--) {
      const t = tail[k].replace(/[│|╭╮╰╯]/g, '').trim();
      if (/^[─━]{4,}$/.test(t) || /^⏺/.test(t) || /^[☐☒✔]/.test(t) && ask.length) break;
      if (!t) { if (ask.length) break; continue; }
      ask.unshift(t);
    }
    out.ask = ask.join(' ');
  }
  return out;
}

async function pullScreen() {
  const sid = S.sid;
  const c = chat(sid);
  if (!live(c)) return;
  await once('screen', async () => {
    const d = await api(`/api/chat/${encodeURIComponent(sid)}/screen`);
    if (sid !== S.sid) return;
    if (!d.ok || d.res === 'no-tab') {
      // One slow Hammerspoon answer is not a lost tab: the last good screen stands until three in a row fail.
      S.screenFails++;
      S.screenErr = d.res === 'no-tab' ? 'no Terminal tab' : d.err || 'no screen';
      if (S.screenFails >= 3) { S.screen = ''; S.scr = parseScreen(''); }
    } else {
      S.screenFails = 0;
      S.screenErr = '';
      S.screen = d.res || '';
      S.screenAt = now();
      S.scr = parseScreen(S.screen);
    }
    renderHead();
    renderActivity();
    renderDock();
    if (S.sheet === 'term') renderSheet();
  });
}

async function key(body) {
  const sid = S.sid;
  const d = await api(`/api/chat/${encodeURIComponent(sid)}/key`, body).catch(() => ({ok: false, err: 'no connection'}));
  if (!d.ok) toast('⚠ ' + (d.err || 'failed'));
  setTimeout(() => { pullScreen(); pullLog(); }, 350);
}

// ------------------------------------------------------------------ the open chat: header, activity, dock

function renderHead() {
  const c = chat(S.sid), r = runOf(S.sid);
  $('#termbtn').hidden = !live(c);
  $('#termbtn').classList.toggle('warn', S.screenFails >= 3);
  $('#infobtn').hidden = !S.sid;
  if (!c && !r) {
    $('#title').innerHTML = `<b>${esc(S.sid)}</b><small>closed</small>`;
    $('#dock').hidden = true;
    return;
  }
  // The chat's own statusline in full words and its colours, else what the screen shows under the prompt.
  const status = S.info && S.info.sid === S.sid ? S.info.status || [] : [];
  let sub;
  if (r) sub = esc(['worker', runMeta(r)].filter(Boolean).join(' · '));
  else if (status.length) sub = status.map((line) => groups(line).map(runsHtml).join(SEP)).join(SEP);
  else if (S.scr.status.length) sub = esc(S.scr.status.join('  │  '));
  else {
    const warm = left(c.until);
    sub = esc([c.account || '?', shortModel(c.model), kTok(c.ctx), warm ? '◔' + warm : '',
      base(c.cwd) + (c.branch && !['main', 'HEAD'].includes(c.branch) ? ':' + c.branch : '')].filter(Boolean).join(' · '));
  }
  const up = r && S.chats.find((x) => x.sid === r.launcher);
  $('#title').innerHTML = `<b>${esc(r ? r.title : c.name)}</b><small>${sub}` +
    `${up ? ` · <a href="#chat/${esc(up.sid)}">↖ ${esc(up.name)}</a>` : ''}</small>`;
  $('#dock').hidden = !live(c);
}

// ------------------------------------------------------------------ the info panel: statusline and changed files

const SEP = '<span class="c-dim"> · </span>';
const runsHtml = (runs) => runs.map(([t, c]) => c ? `<span class="c-${esc(c)}">${esc(t)}</span>` : esc(t)).join('');

// One statusline line's coloured runs -> its segments, split where the line prints │, edges trimmed.
function groups(line) {
  const out = [[]];
  for (const [t, c] of line) {
    String(t).split('│').forEach((part, k) => { if (k) out.push([]); if (part) out[out.length - 1].push([part, c]); });
  }
  return out.map((g) => {
    if (g.length) { g[0] = [g[0][0].trimStart(), g[0][1]]; g[g.length - 1] = [g[g.length - 1][0].trimEnd(), g[g.length - 1][1]]; }
    return g.filter(([t]) => t);
  }).filter((g) => g.length && !/^\$[\d.]+$/.test(g.map(([t]) => t).join('')));  // no money on his screen
}

// A `label N%` segment (ctx, wk, fb, ...) as a bar in its own colour; anything else in the line's colours.
function segHtml(g) {
  const plain = g.map(([t]) => t).join('');
  const m = plain.match(/^(\S+)\s+(\d{1,3})%\s*(.*)$/);
  if (!m) return `<div class="sg">${runsHtml(g)}</div>`;
  const run = g.find(([t]) => t.includes(m[2] + '%'));
  const tone = (run && run[1]) || 'dim';
  return `<div class="sg pct"><span class="bl">${esc(m[1])}</span>` +
    `<span class="bt"><i class="b-${esc(tone)}" style="width:${Math.min(100, +m[2])}%"></i></span>` +
    `<span class="bp c-${esc(tone)}">${m[2]}%</span><span class="br">${esc(m[3])}</span></div>`;
}

function infoHtml(d) {
  const root = (d.root || '').replace(/\/$/, '') + '/';
  const status = (d.status || []).map((line) => groups(line).map(segHtml).join('')).join('');
  const files = d.files || [];
  const sum = (k) => files.reduce((n, f) => n + (f[k] || 0), 0);
  const rows = files.map((f) => {
    const rel = f.p.startsWith(root) ? f.p.slice(root.length) : f.p.replace(/^\/Users\/[^/]+/, '~');
    const cut = rel.lastIndexOf('/');
    return `<div class="fr"><span class="fn">${esc(rel.slice(cut + 1))}</span><span class="fd">${esc(cut > 0 ? rel.slice(0, cut) : '')}</span>` +
      `<span class="c-green">${f.add ? '+' + f.add : ''}</span><span class="c-red">${f.del ? '−' + f.del : ''}</span></div>`;
  }).join('');
  return (status ? `<div class="sgs">${status}</div>` : '') +
    `<div class="ch"><b>Changes</b><span class="n">${files.length || ''}</span>` +
    `<span class="c-green">${files.length ? '+' + sum('add') : ''}</span><span class="c-red">${files.length ? '−' + sum('del') : ''}</span></div>` +
    (rows || '<div class="none">No files changed in this chat</div>');
}

async function pullInfo() {
  const sid = S.sid;
  if (!sid) return;
  await once('info', async () => {
    const d = await api(`/api/chat/${encodeURIComponent(sid)}/info`);
    if (sid !== S.sid) return;
    const h = JSON.stringify(d);
    if (S.info && S.info.sid === sid && S.info.h === h) return;
    S.info = Object.assign(d, {sid, h});
    renderHead();
    if (S.sheet === 'info') renderSheet();
  });
}

function subRow(r) {
  const tag = r.sid ? 'a' : 'div';
  return `<${tag} class="sub"${r.sid ? ` href="#chat/${esc(r.sid)}"` : ''}>${VENDOR[r.vendor] || VENDOR.claude}` +
    `<span class="st">${esc(r.title)}</span><span class="tm" data-since="${r.started}"></span>` +
    `<span class="sm">${esc([r.queued ? 'waiting for a slot' : '', runMeta(r)].filter(Boolean).join(' · '))}</span></${tag}>`;
}

function renderActivity() {
  const c = chat(S.sid);
  let html = '';
  if (live(c) && busy(c)) {
    const sp = S.scr.spin;
    const detail = sp && sp.detail ? esc(sp.detail) : c.status_at ? `<span data-since="${c.status_at}"></span>` : '';
    html += `<div class="think"><span class="shimmer">${esc(sp ? sp.verb : 'Working…')}</span><span class="td">${detail}</span></div>`;
    const run = S.log && S.log.running;
    if (run) html += `<div class="cmd">${esc(run.n)} · ${esc(run.head)}</div>`;
  }
  const mine = S.runs.filter((r) => r.launcher === S.sid);
  if (mine.length) html += '<div class="subs">' + mine.map(subRow).join('') + '</div>';
  if (html === S.activity) return;
  S.activity = html;
  const box = $('#activity');
  box.innerHTML = html;
  clocks(box);
  grew();
}

function renderDock() {
  const c = chat(S.sid), o = S.scr;
  const optHtml = (o.opts.length && o.ask ? `<div class="q">${esc(o.ask)}</div>` : '') + o.opts.map((t, k) =>
    `<button type="button" data-choose="${k + 1}"${k + 1 === o.cur ? ' class="cur"' : ''}><span class="num">${k + 1}</span>${esc(t)}</button>`).join('');
  const opts = $('#opts');
  if (opts.dataset.h !== optHtml) { opts.innerHTML = optHtml; opts.dataset.h = optHtml; }
  const typed = $('#input').value.trim();
  const sug = !optHtml && live(c) && !busy(c) && MIC.state === '' && !typed && !OUT.some((x) => x.sid === S.sid)
    && o.prompt && !/^Try "/.test(o.prompt)
    && !/^\[Pasted text/.test(o.prompt) && !/^[!#/]/.test(o.prompt) ? o.prompt : '';
  const box = $('#suggest');
  if (box.dataset.h !== sug) {
    box.dataset.h = sug;
    box.innerHTML = sug ? `<button type="button" class="sug" title="Put it in the message">${ICON.tab}<span>${esc(sug)}</span></button>` : '';
  }
  renderSend();
}

// Send: an arrow; a red stop while the chat works and nothing is typed (its Esc); during a dictation it stops it and
// sends what was said.
function renderSend() {
  const b = $('#send'), c = chat(S.sid);
  const text = $('#input').value.trim();
  const mode = MIC.state ? (MIC.state === 'wait' ? 'wait' : 'dict') : text ? 'send' : busy(c) && live(c) ? 'stop' : 'idle';
  if (b.dataset.mode === mode) return;
  b.dataset.mode = mode;
  b.disabled = mode === 'idle' || mode === 'wait';
  b.classList.toggle('stop', mode === 'stop');
  b.innerHTML = mode === 'stop' ? ICON.stop : ICON.up;
  b.title = {send: 'Send', stop: 'Stop the chat (Esc)', dict: 'Stop dictating and send', idle: 'Send', wait: 'Transcribing'}[mode];
}

function send() {
  const sid = S.sid;
  const box = $('#input');
  const text = box.value;
  if (!text.trim()) return;
  box.value = '';
  grow();
  delete drafts[sid];
  keep('drafts', drafts);
  outbox(sid, text);
  toBottom();
  renderDock();
}

// ------------------------------------------------------------------ the microphone (transcriptions-gpt on the Mac)

// '' -> starting (capture buffers while the Mac's take starts) -> live (250 ms uploads, in order) -> wait (the Mac
// transcribes) -> ''; the text lands at the end of the draft of the chat the dictation began in, or, when Send ended
// the dictation, goes out to that chat with the draft. The level bars are the browser's own capture.
const MIC = {state: '', id: null, sid: null, ctx: null, stream: null, frames: [], pump: null, then: '', levels: [],
  peak: 0, began: 0, raf: 0};

function micButton() {
  const rec = MIC.state !== '';
  $('#composer').classList.toggle('rec', rec);
  $('#wave').hidden = !rec;
  $('#mic').innerHTML = rec ? ICON.x : ICON.mic;
  $('#mic').title = rec ? 'Cancel the dictation' : 'Dictate';
  $('#mic').disabled = MIC.state === 'wait';
  renderSend();
  renderDock();
  if (rec && !MIC.raf) MIC.raf = requestAnimationFrame(drawWave);
}

function level(buf) {
  const a = new Int16Array(buf);
  let sum = 0;
  for (let i = 0; i < a.length; i++) sum += a[i] * a[i];
  const rms = Math.sqrt(sum / Math.max(1, a.length)) / 32768;
  return Math.max(0, Math.min(1, (20 * Math.log10(rms + 1e-6) + 55) / 45));
}

let lastPush = 0;
function drawWave(t) {
  MIC.raf = 0;
  if (!MIC.state) return;
  const cv = $('#wavec');
  const w = cv.clientWidth, h = cv.clientHeight, dpr = window.devicePixelRatio || 1;
  if (cv.width !== w * dpr) { cv.width = w * dpr; cv.height = h * dpr; }
  const bars = Math.max(8, Math.floor(w / 4));
  if (t - lastPush > 60) {
    lastPush = t;
    MIC.levels.push(MIC.state === 'live' ? MIC.peak : 0);
    MIC.peak = 0;
    if (MIC.levels.length > bars) MIC.levels.splice(0, MIC.levels.length - bars);
  }
  const g = cv.getContext('2d');
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, w, h);
  g.fillStyle = getComputedStyle(cv).color;
  const lv = MIC.levels;
  for (let i = 0; i < lv.length; i++) {
    const x = w - (lv.length - i) * 4;
    const bh = Math.max(2, lv[i] * h);
    g.globalAlpha = MIC.state === 'live' ? 0.85 : 0.35;
    g.fillRect(x, (h - bh) / 2, 2, bh);
  }
  $('#wavet').innerHTML = MIC.state === 'wait' ? '<span class="shimmer">Transcribing…</span>'
    : MIC.state === 'starting' ? '<span class="shimmer">Starting…</span>' : dur(now() - MIC.began).replace(/^(\d+)s$/, '0:$1').replace(/^0:(\d)$/, '0:0$1');
  MIC.raf = requestAnimationFrame(drawWave);
}

async function micStart() {
  if (!navigator.mediaDevices || !window.AudioWorkletNode) {
    toast('⚠ the microphone needs the https link (page lan --app)');
    return;
  }
  Object.assign(MIC, {state: 'starting', id: null, sid: S.sid, frames: [], then: '', levels: [], peak: 0, began: now()});
  micButton();
  try {
    MIC.ctx = new AudioContext();  // inside the tap: iOS starts audio only from a gesture
    MIC.stream = await navigator.mediaDevices.getUserMedia({audio: {channelCount: 1}});
    await MIC.ctx.audioWorklet.addModule('/app/mic-worklet.js');
    const worklet = new AudioWorkletNode(MIC.ctx, 'mic16k');
    worklet.port.onmessage = (e) => {
      if (MIC.state !== 'starting' && MIC.state !== 'live') return;
      MIC.frames.push(e.data);
      MIC.peak = Math.max(MIC.peak, level(e.data));
    };
    MIC.ctx.createMediaStreamSource(MIC.stream).connect(worklet);
    worklet.connect(MIC.ctx.destination);  // writes no output: silence, but the graph pulls it
    await MIC.ctx.resume();
    const d = await api('/api/mic/start', {});
    if (!d.ok) throw new Error(d.err || 'the Mac did not start');
    if (MIC.state !== 'starting') return;
    Object.assign(MIC, {state: 'live', id: d.id, began: now()});
    micButton();
    MIC.pump = micPump(d.id);
  } catch (e) {
    micDrop();
    toast('⚠ ' + (e.message || e));
  }
}

async function micPump(id) {
  while (MIC.id === id && MIC.state === 'live') {
    await new Promise((r) => setTimeout(r, 250));
    if (!(await micFlush(id))) return;
  }
}

// Everything buffered, in pieces under the server's 256 KB cap -> false when the server dropped the dictation.
async function micFlush(id) {
  while (MIC.frames.length) {
    const take = MIC.frames.splice(0, 200);
    const body = new Int16Array(take.length * 320);
    take.forEach((f, k) => body.set(new Int16Array(f), k * 320));
    const r = await fetch(`/api/mic/${id}/chunk`, {method: 'POST', body: body.buffer,
      headers: {'Content-Type': 'application/octet-stream'}}).catch(() => null);
    if (r && r.status === 404) {
      if (MIC.id === id) { micDrop(); toast('⚠ the dictation was dropped on the Mac'); }
      return false;
    }
  }
  return true;
}

function micRelease() {
  if (MIC.stream) MIC.stream.getTracks().forEach((t) => t.stop());
  const ctx = MIC.ctx;
  if (ctx) setTimeout(() => ctx.close().catch(() => {}), 100);
  MIC.stream = MIC.ctx = null;
}

function micDrop() {
  const id = MIC.id;
  micRelease();
  Object.assign(MIC, {state: '', id: null, frames: [], then: ''});
  micButton();
  if (id) api(`/api/mic/${id}/cancel`, {}).catch(() => {});
}

async function micStop(then = '') {
  if (MIC.state === 'starting') { micDrop(); return; }
  const {id, sid} = MIC;
  MIC.then = then;
  if (MIC.stream) MIC.stream.getTracks().forEach((t) => t.stop());
  await new Promise((r) => setTimeout(r, 80));  // the worklet's last frames
  MIC.state = 'wait';
  micButton();
  micRelease();
  await MIC.pump;
  if (!(await micFlush(id))) return;
  const d = await api(`/api/mic/${id}/stop`, {}).catch(() => ({ok: false, err: 'no connection'}));
  const sendAfter = MIC.then === 'send';
  Object.assign(MIC, {state: '', id: null, then: ''});
  micButton();
  if (!d.ok) { toast('⚠ ' + (d.err || 'no transcript')); return; }
  const text = (d.text || '').trim();
  const join = (v) => (text ? (v && !/\s$/.test(v) ? v + ' ' : v || '') + text : v || '');
  const open = sid === S.sid;
  const full = join(open ? $('#input').value : drafts[sid]);
  if (sendAfter && full.trim()) {
    if (open) { $('#input').value = ''; grow(); }
    delete drafts[sid];
    keep('drafts', drafts);
    outbox(sid, full);
    if (open) toBottom();
  } else {
    if (open) { $('#input').value = full; grow(); }
    drafts[sid] = full;
    keep('drafts', drafts);
  }
  renderDock();
}

function grow() {
  const box = $('#input');
  box.style.height = 'auto';
  box.style.height = Math.min(box.scrollHeight, window.innerHeight * 0.4) + 'px';
}

// ------------------------------------------------------------------ the side sheet: Terminal, Pages, Menu

function seg(s) {
  let style = '';
  if (s.c) {
    const grey = /^(000000|ffffff)$/.test(s.c);
    if (!grey) style += `color:#${s.c};`;
    if (s.a != null && s.a < 0.99) style += `opacity:${Math.max(0.35, s.a * (grey ? 1.6 : 1)).toFixed(2)};`;
  }
  if (s.b) style += 'font-weight:700;';
  return style ? `<span style="${style}">${esc(s.t)}</span>` : esc(s.t);
}

function menuHtml(items, path) {
  return (Array.isArray(items) ? items : []).map((it, k) => {
    if (it.sep) return '<div class="msep"></div>';
    const text = (it.r || []).map((s) => s.t).join('');
    const word = (text.trim().match(/^[\p{L}\p{N}_./-]+/u) || [''])[0];
    const id = `${path}/${k}:${word}`;
    const open = it.sub && S.menuOpen.has(id);
    const row = `<div class="mi${it.dis ? ' dis' : ''}${it.sub ? ' has' : ''}${open ? ' open' : ''}" data-id="${esc(id)}">` +
      `<span class="ck">${it.ck ? '✓' : ''}</span>${(it.r || []).map(seg).join('')}</div>`;
    return row + (open ? `<div class="msub">${menuHtml(it.sub, id)}</div>` : '');
  }).join('');
}

let lastMenu = null, menuErr = '';
async function refreshMenu() {
  await once('menu', async () => {
    const d = await api('/api/menu');
    menuErr = d.err || '';
    if (!d.err) lastMenu = d.items;
    if (S.sheet === 'menu') renderSheet();
  });
}

async function refreshPages() {
  await once('pages', async () => {
    const d = await api('/api/pages');
    S.pages = d.pages || [];
    if (S.sheet === 'pages') renderSheet();
  });
}

// The info panel stays where he left it, open or shut, across chats and reloads (Codex's right panel).
const ui = kept('ui');
function openSheet(kind) {
  if (S.sheet === kind) { closeSheet(); return; }
  if (kind === 'info') { ui.info = true; keep('ui', ui); }
  S.sheet = kind;
  $('#sheet').className = kind;
  $('#sheet').hidden = $('#scrim').hidden = false;
  $('#sheetb').innerHTML = '';
  document.querySelectorAll('[data-sheet]').forEach((b) => b.classList.toggle('on', b.dataset.sheet === kind));
  document.body.classList.add('docked');
  renderSheet();
  if (kind === 'menu') refreshMenu();
  if (kind === 'pages') refreshPages();
  if (kind === 'term') pullScreen();
  if (kind === 'info') pullInfo();
}

// quiet: the app closed it (no chat left to show), not his choice; else closing another sheet brings info back.
function closeSheet(quiet) {
  const was = S.sheet;
  if (was === 'info' && quiet !== true) { ui.info = false; keep('ui', ui); }
  S.sheet = '';
  $('#sheet').hidden = $('#scrim').hidden = true;
  document.body.classList.remove('docked');
  document.querySelectorAll('[data-sheet]').forEach((b) => b.classList.remove('on'));
  if (quiet !== true && was !== 'info') infoBack();
}
const wide = () => matchMedia('(min-width: 1000px)').matches;
function infoBack() { if (ui.info && S.sid && !S.sheet && wide()) openSheet('info'); }

function renderSheet() {
  requestAnimationFrame(() => document.body.style.setProperty('--sheetw', $('#sheet').offsetWidth + 'px'));
  const body = $('#sheetb');
  const top = body.scrollTop, end = body.scrollHeight - body.scrollTop - body.clientHeight < 30;
  if (S.sheet === 'term') {
    const c = chat(S.sid);
    $('#sheett').textContent = 'Terminal';
    $('#sheets').textContent = c ? (c.tty || '').replace('/dev/', '') : '';
    body.innerHTML = (S.screenErr ? `<div class="term-err">⚠ ${esc(S.screenErr)}</div>` : '') +
      `<pre class="term">${esc(S.scr.lines.join('\n'))}</pre>`;
    body.scrollTop = end || !top ? body.scrollHeight : top;
  } else if (S.sheet === 'menu') {
    $('#sheett').textContent = 'Menu';
    $('#sheets').textContent = '';
    body.innerHTML = menuErr ? `<div class="term-err">⚠ ${esc(menuErr)}</div>` : lastMenu ? menuHtml(lastMenu, '') : '';
    body.scrollTop = top;
  } else if (S.sheet === 'info') {
    const d = S.info && S.info.sid === S.sid ? S.info : null;
    $('#sheett').textContent = d && d.root ? base(d.root) : 'Info';
    $('#sheets').textContent = '';
    body.innerHTML = d ? infoHtml(d) : '';
    body.scrollTop = top;
  } else if (S.sheet === 'pages') {
    $('#sheett').textContent = 'Pages';
    $('#sheets').textContent = S.pages ? String(S.pages.length) : '';
    body.innerHTML = (S.pages || []).map((p) =>
      `<div class="prow" data-pid="${esc(p.pid)}"><div class="t"><b>${p.owner && p.owner === S.sid ? '<i class="dot"></i>' : ''}` +
      `<span>${esc(p.title)}</span></b><small>${esc(p.chat)}</small></div>` +
      `<span class="at">${ago(Date.parse(p.updated) / 1000)}</span></div>`).join('');
    body.scrollTop = top;
  }
}

function overlay(path) {
  $('#frame').src = path;
  $('#overlay').hidden = false;
}

// ------------------------------------------------------------------ views and routing

function show(inside) {
  $('#chat').hidden = !inside;
  $('#empty').hidden = inside;
  document.body.classList.toggle('inside', inside);
}

function openChat(sid) {
  if (S.sid && S.sid !== sid) {
    drafts[S.sid] = $('#input').value;
    keep('drafts', drafts);
  }
  if (S.sid !== sid || !S.log) {
    S.sid = sid;
    resetLog();
    Object.assign(S, {screen: '', screenAt: 0, screenFails: 0, screenErr: '', scr: parseScreen('')});
    $('#opts').innerHTML = $('#suggest').innerHTML = '';
    $('#opts').dataset.h = $('#suggest').dataset.h = '';
    $('#input').value = drafts[sid] || '';
    grow();
    S.info = null;
    const c = chat(sid);
    if (c && c.spoke) { seen[sid] = c.spoke; keep('seen', seen); }
  }
  show(true);
  renderHead();
  renderList();
  renderDock();
  pullLog();
  pullScreen();
  pullInfo();
  if (S.sheet === 'info') renderSheet(); else infoBack();
}

function route() {
  const [view, arg] = location.hash.slice(1).split('/');
  if (view === 'menu' || view === 'pages') {
    history.replaceState(null, '', S.sid ? '#chat/' + encodeURIComponent(S.sid) : '#');
    openSheet(view);
    return;
  }
  if (view === 'chat' && arg) return openChat(decodeURIComponent(arg));
  if (S.sid) {
    drafts[S.sid] = $('#input').value;
    keep('drafts', drafts);
    S.sid = null;
    S.log = null;
    renderList();
  }
  if (S.sheet === 'term' || S.sheet === 'info') closeSheet(true);
  show(false);
  $('#title').innerHTML = '';
  $('#termbtn').hidden = true;
}

// ------------------------------------------------------------------ events

$('#composer').addEventListener('submit', (e) => {
  e.preventDefault();
  const mode = $('#send').dataset.mode;
  if (mode === 'dict') micStop('send');
  else if (mode === 'stop') key({key: 'esc'});
  else send();
});
$('#input').addEventListener('input', () => { grow(); if (S.sid) drafts[S.sid] = $('#input').value; renderDock(); });
$('#input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
});
$('#mic').addEventListener('click', () => {
  if (MIC.state === '') micStart();
  else if (MIC.state === 'live' || MIC.state === 'starting') micDrop();
});
$('#opts').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-choose]');
  if (b) key({choose: +b.dataset.choose});
});
$('#suggest').addEventListener('click', (e) => {
  const text = $('#suggest').dataset.h;
  if (!e.target.closest('.sug') || !text || !S.sid) return;
  // Tab's meaning in the CLI: the suggestion becomes the draft, one tap on Send away (no keyboard pops up).
  $('#input').value = text;
  grow();
  drafts[S.sid] = text;
  keep('drafts', drafts);
  renderDock();
});
document.querySelectorAll('[data-sheet]').forEach((b) => b.addEventListener('click', () => openSheet(b.dataset.sheet)));
$('#sheetx').addEventListener('click', closeSheet);
$('#scrim').addEventListener('click', closeSheet);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && S.sheet) closeSheet(); });
$('#sheetb').addEventListener('click', (e) => {
  const row = e.target.closest('.mi.has');
  if (!row) return;
  const id = row.dataset.id;
  if (S.menuOpen.has(id)) S.menuOpen.delete(id); else S.menuOpen.add(id);
  renderSheet();
});
document.addEventListener('click', (e) => {
  const p = e.target.closest('[data-pid]');
  if (p) { e.preventDefault(); overlay(`/p/${encodeURIComponent(p.dataset.pid)}/`); return; }
  const a = e.target.closest('#log a[href]');
  if (a) {
    const m = a.getAttribute('href').match(/^https?:\/\/(?:127\.0\.0\.1|localhost|[\w.-]+\.local|[\w.-]+\.ts\.net)(?::\d+)?(\/(?:p|app)\/[^\s]*)$/);
    if (m) { e.preventDefault(); overlay(m[1]); }
  }
});
$('#close').addEventListener('click', () => { $('#overlay').hidden = true; $('#frame').src = 'about:blank'; });
window.addEventListener('hashchange', route);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible') return;
  NET.visibleAt = now();
  refreshChats();
  if (S.sid) { pullLog(); pullScreen(); }
});

// The on-screen keyboard: iOS pans the whole page to the input rather than resizing it, which moved the header out
// of view. The app is sized to the visible part instead (not while pinch-zoomed), so only the thread moves.
const VV = window.visualViewport;
if (VV) {
  const fit = () => {
    if (Math.abs(VV.scale - 1) > 0.01) return;
    const st = document.documentElement.style;
    st.setProperty('--vvh', VV.height + 'px');
    st.setProperty('--vvt', VV.offsetTop + 'px');
    if (STICK.on) toBottom();
  };
  VV.addEventListener('resize', fit);
  VV.addEventListener('scroll', fit);
}

// The polls, only while visible: chats every 3 s, the open transcript every 1 s (new bytes only), its screen every
// 2 s while it works or asks, 4 s idle, 1 s with the Terminal sheet open; its statusline and changed files every 3 s;
// menu 5 s and pages 20 s while shown.
let tick = 0;
setInterval(() => {
  if (document.visibilityState !== 'visible') return;
  tick++;
  if (tick % 3 === 0) refreshChats();
  if (S.sid) {
    pullLog();
    const c = chat(S.sid);
    const every = S.sheet === 'term' ? 1 : busy(c) || S.scr.opts.length ? 2 : 4;
    if (live(c) && tick % every === 0) pullScreen();
  }
  if (S.sid && tick % 3 === 1) pullInfo();
  if (S.sheet === 'menu' && tick % 5 === 0) refreshMenu();
  if (S.sheet === 'pages' && tick % 20 === 0) refreshPages();
  clocks();
}, 1000);

NET.visibleAt = now();
renderMachine();
refreshChats().then(route);
