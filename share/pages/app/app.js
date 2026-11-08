// The chats app: Egor's live Mac chats on the iPad (share/pages/CONTRACT.md "App"). No build step, no framework.
import {VENDOR, ICON, DEFS} from './icons.js';

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const kept = (k) => { try { return JSON.parse(localStorage.getItem(k) || '{}'); } catch { return {}; } };
const keep = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} };
const now = () => Date.now() / 1000;
const norm = (t) => String(t || '').replace(/\s+/g, ' ').trim();

const seen = kept('seen');
// One draft for every chat: he can switch chats while he types or dictates; Send takes it to the chat open then.
const draft = kept('draft');
if (draft.text == null) {
  // The per-chat drafts before it: the open chat's carries over.
  const old = kept('drafts'), m = location.hash.match(/^#chat\/(.+)$/);
  draft.text = (m && old[decodeURIComponent(m[1])]) || '';
  localStorage.removeItem('drafts');
}
const saveDraft = () => { draft.text = $('#input').value; keep('draft', draft); };
const S = {chats: [], workers: [], runs: [], machine: null, sid: null, log: null, running: {}, menuOpen: new Set(),
  pages: null, screen: '', screenAt: 0, screenFails: 0, screenErr: '', scr: parseScreen(''), auth: true, sheet: '',
  activity: '', hist: [], histN: 25, q: '', found: null, opening: null, pins: []};

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

async function api(path, body, ms) {
  const init = body ? {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)}
    : {cache: 'no-store'};
  if ((!body || ms) && AbortSignal.timeout) init.signal = AbortSignal.timeout(ms || 20000);
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
    box.dataset.h = '';
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
  if (box.dataset.h !== html) { box.dataset.h = html; box.innerHTML = html; }
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

// ------------------------------------------------------------------ past chats: the list, a search, open, close

// Every chat he can go back to (chat-find --recent), newest first; the open ones are already above. The search field
// filters names and last lines at once; Enter (or the row under them) asks chat-find for everything said, which
// reads every transcript and takes a while.
function histRow(r, pin) {
  const sub = [base(r.cwd), r.text || r.title].filter(Boolean).join(' · ');
  return `<a class="row past${S.sid === r.sid ? ' sel' : ''}" href="#chat/${esc(r.sid)}"><span class="lead">${pin ? '⚑' : ''}</span>` +
    `<div class="body"><div class="l1"><span class="name">${esc(r.name || r.sid.slice(0, 8))}</span>` +
    `<span class="tm">${ago(r.spoke)}</span></div><div class="l2">${esc(sub)}</div></div></a>`;
}

// A pinned chat that is not open sits at the very top, as `chats` lists it (⚑); an open one is where it would be.
function pinnedHtml(hit) {
  const open = new Set(S.chats.map((c) => c.sid));
  const rows = S.pins.filter((sid) => !open.has(sid)).map((sid) => pastRow(sid) || {sid, name: '', cwd: ''})
    .filter((r) => hit(r.name, r.cwd, r.text));
  return rows.length ? '<div class="sec">Pinned</div>' + rows.map((r) => histRow(r, true)).join('') : '';
}

function historyHtml(q, hit) {
  const open = new Set(S.chats.concat(S.workers, S.runs).map((c) => c.sid).filter(Boolean).concat(S.pins));
  const past = S.hist.filter((r) => !open.has(r.sid));
  let html = '';
  if (!q) {
    if (!past.length) return '';
    html = '<div class="sec">Earlier</div>' + past.slice(0, S.histN).map((r) => histRow(r)).join('');
    if (past.length > S.histN) html += `<button type="button" class="more" data-more>Show more · ${past.length - S.histN}</button>`;
    return html;
  }
  const near = past.filter((r) => hit(r.name, r.cwd, r.text)).slice(0, 50);
  if (near.length) html += '<div class="sec">Earlier</div>' + near.map((r) => histRow(r)).join('');
  const f = S.found && S.found.q === q ? S.found : null;
  if (!f) return html + `<button type="button" class="more" data-said>Search everything said · “${esc(q)}”</button>`;
  html += `<div class="sec">Said “${esc(q)}”${f.busy ? ' <span class="shimmer">searching every chat…</span>' : ''}</div>`;
  if (f.err) html += `<div class="more">${esc(f.err)}</div>`;
  else if (f.rows && !f.rows.length) html += '<div class="more">Nothing said matches</div>';
  return html + (f.rows || []).map((r) => histRow(open.has(r.sid) ? Object.assign({}, r, {text: ['open', r.text].filter(Boolean).join(' · ')}) : r)).join('');
}

async function refreshHistory() {
  await once('history', async () => {
    const d = await api('/api/history');
    S.hist = d.chats || [];
    renderList();
    if (S.sid && !chat(S.sid)) renderHead();
  });
}

async function searchSaid() {
  const q = S.q.trim().toLowerCase();
  if (!q || (S.found && S.found.q === q && (S.found.busy || S.found.rows))) return;
  const f = S.found = {q, rows: null, busy: true, err: ''};
  renderList();
  try {
    const d = await api('/api/search?q=' + encodeURIComponent(q), null, 100000);
    f.rows = d.chats || [];
  } catch (e) {
    f.err = 'search failed: ' + (e.message || e);
  }
  f.busy = false;
  if (S.found === f) renderList();
}

const pastRow = (sid) => S.hist.find((r) => r.sid === sid) || (S.found && (S.found.rows || []).find((r) => r.sid === sid));

// Open in Terminal: the server runs `chats --open-command` and types it into a new Terminal window; the chat then
// shows up live (the same id, or a new one in the same folder) and the view follows it.
async function openPast() {
  const sid = S.sid, p = pastRow(sid) || {};
  $('#openbtn').disabled = true;
  $('#pastnote').innerHTML = '<span class="shimmer">Opening in Terminal on the Mac…</span>';
  const d = await api(`/api/chat/${encodeURIComponent(sid)}/open`, {}, 45000).catch((e) => ({ok: false, err: e.message || 'no connection'}));
  $('#openbtn').disabled = false;
  if (!d.ok) { $('#pastnote').textContent = '⚠ ' + (d.err || 'did not open'); return; }
  if (d.live) { refreshChats(); return; }
  S.opening = {sid, at: now(), cwd: p.cwd || '', known: new Set(S.chats.map((c) => c.sid))};
  $('#pastnote').innerHTML = `<span class="shimmer">Opened${d.account ? ' as ' + esc(d.account) : ''} · waiting for it…</span>`;
  refreshChats();
}

function followOpening() {
  const o = S.opening;
  if (!o) return;
  if (chat(o.sid)) { S.opening = null; if (S.sid === o.sid) openChat(o.sid); return; }
  const fresh = S.chats.find((c) => !o.known.has(c.sid) && (!o.cwd || c.cwd === o.cwd));
  if (fresh) { S.opening = null; if (S.sid === o.sid) location.hash = '#chat/' + encodeURIComponent(fresh.sid); return; }
  if (now() - o.at > 60) { S.opening = null; if (S.sid === o.sid) $('#pastnote').textContent = 'Opened in Terminal; it has not shown up here yet'; }
}

// Pin: the chat stays at the top of the list while it is not open (share/chat_pins.py, the same pins as `chats`).
async function togglePin() {
  const sid = S.sid, on = !S.pins.includes(sid);
  const d = await api(`/api/chat/${encodeURIComponent(sid)}/pin`, {on}, 10000).catch(() => ({ok: false}));
  if (!d.ok) { toast('⚠ the pin did not change'); return; }
  S.pins = d.pins || [];
  renderList();
  renderSheet();
}

// End an idle chat (/exit, as if typed) and close its Terminal window: from the info panel, after a confirm.
async function closeLive() {
  const sid = S.sid, c = chat(sid);
  if (!live(c)) return;
  if (busy(c)) { toast('⚠ it is working: stop it first'); return; }
  if (!confirm(`End “${c.name}” and close its Terminal window?`)) return;
  const d = await api(`/api/chat/${encodeURIComponent(sid)}/close`, {}, 30000).catch((e) => ({ok: false, err: e.message || 'no connection'}));
  if (!d.ok) { toast('⚠ ' + (d.err || 'did not close')); return; }
  toast(d.window === 'closed' ? `Ended “${c.name}”, its window closed` : `Ended “${c.name}”; its window stays (${d.window === 'tabs' ? 'other tabs in it' : 'Terminal did not answer'})`);
  await refreshChats();
  refreshHistory();
  renderHead();
}

let listHtml = '';
function renderList() {
  const box = $('#list');
  const top = box.scrollTop;
  // The account shows only where it is not the usual one.
  const count = {};
  for (const c of S.chats) count[c.account] = (count[c.account] || 0) + 1;
  const usual = Object.keys(count).sort((a, b) => count[b] - count[a])[0];
  const q = S.q.trim().toLowerCase();
  const hit = (...xs) => !q || q.split(/\s+/).every((w) => xs.some((x) => String(x || '').toLowerCase().includes(w)));
  const chats = S.chats.filter((c) => hit(c.name, c.cwd, snippet(c)));
  let html = pinnedHtml(hit) + (chats.length || !q ? '<div class="sec">Chats</div>' + chats.map((c) => chatRow(c, usual)).join('') : '');
  const others = S.workers.map((w) => Object.assign({}, w, {vendor: 'claude', title: w.name, started: w.started, sid: w.sid}));
  const runs = S.runs.filter((r) => hit(r.title, r.account)), more = others.filter((r) => hit(r.title));
  if (runs.length || more.length) {
    html += `<div class="sec">Workers <span>${runs.length + more.length}</span></div>` +
      runs.map(runRow).join('') + more.map(runRow).join('');
  }
  html += historyHtml(q, hit);
  // Redrawn only when it changed: a row replaced under his finger loses the tap (iOS cancels a tap whose node is gone).
  if (listHtml !== html) {
    listHtml = html;
    box.innerHTML = html;
    box.scrollTop = top;
  }
  clocks(box);
}

function reload() {
  if (MIC.state) { toast('Reloads when the dictation ends'); return; }
  saveDraft();
  location.reload();
}

async function refreshChats() {
  await once('chats', async () => {
    const d = await api('/api/chats');
    S.auth = true;
    // New client files reload the app (a home-screen app has no reload button); the draft and the open chat stay,
    // a running dictation or a message on its way finishes first, the next poll after it reloads. Meanwhile a thin
    // bar says an update waits; a tap on it reloads at once (not during a dictation).
    if (d.client && !S.client) S.client = d.client;
    if (d.client && d.client !== S.client) {
      if (MIC.state === '' && !OUT.some((o) => o.state === 'sending')) { reload(); return; }
      $('#update').hidden = false;
    }
    S.chats = d.chats || [];
    S.workers = d.workers || [];
    S.runs = d.runs || [];
    S.pins = d.pins || [];
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
    followOpening();
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
  S.log = {start: null, end: null, tools: {}, groups: {}, queue: [], group: null, olderAt: performance.now()};
  $('#col').innerHTML = '';
  S.activity = '';
  $('#activity').innerHTML = '';
  Object.assign(STICK, {on: true, owed: false});
}

// Earlier history comes one block per scroll of his: his own scroll near the top after the last block came in loads
// the next (the button stays for a tap). Nothing else does: a short block that leaves the button in view, the
// layout's own scroll and the bounce at the edge load nothing. The block fades up and a line glows for a moment where
// it meets what was already there.
const OLDER_NEAR = 600;  // px from the top
function olderButton() {
  const b = document.createElement('button');
  b.className = 'older';
  b.textContent = 'Earlier';
  b.onclick = loadOlder;
  return b;
}
function nearTop(b, t) {
  const L = S.log;
  if (b.scrollTop < OLDER_NEAR && L && L.first === false && L.start > 0 && t > L.olderAt) loadOlder();
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
    if (L.first !== false) { L.first = false; outRender(); toBottom(true); }
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
    try {
      d = await api(`/api/chat/${encodeURIComponent(sid)}/log?before=${L.start}`);
      // The block goes in once his fling has stopped: a scroll set mid-fling jerks the thread.
      for (let k = 0; k < 100 && !settled(); k++) await new Promise((r) => setTimeout(r, 100));
    } finally { if (was) was.classList.remove('busy'); }
    if (sid !== S.sid || L !== S.log) return;
    const box = $('#log');
    const h0 = box.scrollHeight;
    if (was) was.remove();
    const frag = document.createDocumentFragment();
    if (d.start > 0 && d.start < L.start) frag.appendChild(olderButton());  // a window that did not move ends Earlier
    addItems(d.items || [], L, {group: null, older: true}, frag);
    for (const n of frag.children) if (!n.classList.contains('older')) n.classList.add('came');
    const seam = document.createElement('div');
    seam.className = 'seam';
    seam.addEventListener('animationend', () => seam.remove());
    frag.appendChild(seam);
    L.start = d.start;
    $('#col').prepend(frag);
    STICK.own = true;
    box.scrollTop += box.scrollHeight - h0;
    L.olderAt = performance.now();
  });
}

// Stick to the end only while he is there: new items, a growing dock or keyboard keep the last line in view, a
// scroll up stays put (no poll moves it). Only his own scroll unsticks it: a finger, its fling (a scroll every frame
// after the finger lifts), a wheel, a key, a dragged scrollbar; a scroll the layout made (the dock grew, content
// came) never does. Nothing moves the thread while his scroll, its fling or the edge bounce is still going (iOS
// jerks a scroll that is set mid-fling): a move asked meanwhile waits until it has settled.
const STICK = {on: true, touch: false, input: 0, moved: 0, own: false, owed: false};
const settled = () => !STICK.touch && performance.now() - STICK.moved > 700;
function toBottom(force) {
  if (force !== true && !settled()) { STICK.owed = true; return; }
  STICK.owed = false;
  const box = $('#log');
  STICK.own = box.scrollTop !== box.scrollHeight - box.clientHeight;
  box.scrollTop = box.scrollHeight;
  STICK.on = true;
  $('#jump').hidden = true;
}
function grew() {
  if (STICK.on) toBottom();
  else $('#jump').hidden = false;
}
$('#log').addEventListener('scroll', () => {
  const b = $('#log'), t = performance.now();
  const his = STICK.touch || t - STICK.input < 300 || t - STICK.moved < 150;
  const own = STICK.own;
  STICK.own = false;
  const end = b.scrollHeight - b.scrollTop - b.clientHeight < 40;
  if (his && !own) {
    STICK.moved = t;
    STICK.on = end;
    later();
    nearTop(b, t);
  } else if (end) STICK.on = true;
  else if (STICK.on) toBottom();
  $('#jump').hidden = STICK.on;
}, {passive: true});
const log = $('#log');
const mark = () => { STICK.input = performance.now(); };
log.addEventListener('touchstart', () => { STICK.touch = true; STICK.moved = performance.now(); }, {passive: true});
log.addEventListener('touchend', () => { STICK.touch = false; STICK.moved = performance.now(); later(); }, {passive: true});
log.addEventListener('touchcancel', () => { STICK.touch = false; }, {passive: true});
log.addEventListener('wheel', mark, {passive: true});
log.addEventListener('keydown', mark);
log.addEventListener('mousedown', () => { STICK.touch = true; mark(); });
window.addEventListener('mouseup', () => { if (STICK.touch) { STICK.touch = false; mark(); } });
$('#jump').addEventListener('click', () => toBottom(true));
new ResizeObserver(() => {
  $('#chat').style.setProperty('--dock', $('#dock').offsetHeight + 'px');
  if (STICK.on) toBottom();
}).observe(log);
// What waited for the thread to settle goes once it has.
function payOwed() {
  if (STICK.owed && settled() && STICK.on) toBottom();
}
let settleTimer = 0;
function later() {
  clearTimeout(settleTimer);
  settleTimer = setTimeout(payOwed, 750);
}

// ------------------------------------------------------------------ the outbox: what he sent, bound to its chat

// A message belongs to the chat it was written in from the tap on: the composer empties at once, the request runs
// whatever he opens next, and its bubble stays in that chat until the transcript shows it (as said or queued).
// Kept across a reload (an update reloads the app by itself): a sent one stays until the transcript shows it (an
// hour at most), a failed one until he deletes it, and one a reload cut mid-request is offered as not sent.
let outSeq = 0;
const OUT = (kept('outbox').list || []).filter((o) => o && o.sid && o.text && (o.state !== 'sent' || now() - o.at < 3600))
  .map((o) => Object.assign(o, {id: ++outSeq}, o.state === 'sending'
    ? {state: 'failed', unsure: true, err: 'the app reloaded while sending: check the chat before Retry'} : {}));
const saveOut = () => keep('outbox', {list: OUT.map(({sid, text, state, err, at, unsure}) => ({sid, text, state, err, at, unsure}))});

function outbox(sid, text) {
  const o = {id: ++outSeq, sid, text, state: 'sending', err: ''};
  OUT.push(o);
  deliver(o);
  return o;
}

async function deliver(o) {
  o.state = 'sending';
  o.unsure = false;
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
  const mine = OUT.filter((o) => o.sid === S.sid && (o.state !== 'failed' || o.unsure));
  const o = mine.find((x) => norm(x.text) === norm(text) && t >= x.at - 30)
    || (OUT.some((x) => norm(x.text) === norm(text)) ? null : mine.find((x) => t >= x.at - 2));
  if (o) { OUT.splice(OUT.indexOf(o), 1); outRender(); }
}

function outRender() {
  saveOut();
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
  $('#pagesbtn').classList.toggle('none', !!c && c.pages === 0);
  $('#pastbar').hidden = !!(c || r);
  if (!c && !r) {
    const p = pastRow(S.sid);
    title(`<b>${esc(p && p.name || S.sid)}</b><small>${esc([p && base(p.cwd), p && ago(p.spoke), 'not open'].filter(Boolean).join(' · '))}</small>`);
    if (!S.opening || S.opening.sid !== S.sid) { $('#openbtn').disabled = false; $('#pastnote').textContent = 'Not open on the Mac'; }
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
  title(`<b>${esc(r ? r.title : c.name)}</b><small>${sub}` +
    `${up ? ` · <a href="#chat/${esc(up.sid)}">↖ ${esc(up.name)}</a>` : ''}</small>`);
}
function title(html) {
  const t = $('#title');
  if (t.dataset.h !== html) { t.dataset.h = html; t.innerHTML = html; }
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

// A `label N%` segment (ctx, wk, fb, ...) as a bar; anything else in the line's colours. The bar and its % take the
// segment's most urgent colour, the statusline's own warning included (a cold cache's yellow or red size), and what
// follows the % keeps its colours.
const URGENT = ['red', 'yellow', 'green'];
function segHtml(g) {
  const plain = g.map(([t]) => t).join('');
  const m = plain.match(/^(\S+)\s+(\d{1,3})%\s*(.*)$/);
  if (!m) return `<div class="sg">${runsHtml(g)}</div>`;
  const k = g.findIndex(([t]) => t.includes(m[2] + '%'));
  const tone = URGENT.find((c) => g.some((r) => r[1] === c)) || (k >= 0 && g[k][1]) || 'dim';
  const rest = k >= 0 ? g.slice(k + 1).map(([t, c], j) => [j ? t : t.replace(/^\s+/, ''), c]) : [[m[3], '']];
  return `<div class="sg pct"><span class="bl">${esc(m[1])}</span>` +
    `<span class="bt"><i class="b-${esc(tone)}" style="width:${Math.min(100, +m[2])}%"></i></span>` +
    `<span class="bp c-${esc(tone)}">${m[2]}%</span><span class="br">${runsHtml(rest)}</span></div>`;
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
    && !$('#composer').classList.contains('lost')
    && o.prompt && !/^Try "/.test(o.prompt)
    && !/^\[Pasted text/.test(o.prompt) && !/^[!#/]/.test(o.prompt) ? o.prompt : '';
  const box = $('#suggest');
  if (box.dataset.h !== sug) {
    box.dataset.h = sug;
    box.innerHTML = sug ? `<button type="button" class="pill sug" title="Put it in the message">${ICON.tab}<span>${esc(sug)}</span></button>` : '';
  }
  renderSend();
}

// Send: an arrow; a red stop while the chat works and nothing is typed (its Esc); during a dictation it stops it and
// sends what was said.
function renderSend() {
  const b = $('#send'), c = chat(S.sid);
  const text = $('#input').value.trim();
  const mode = MIC.state ? (MIC.state === 'wait' ? 'wait' : 'dict') : !live(c) ? 'idle' : text ? 'send' : busy(c) ? 'stop' : 'idle';
  if (b.dataset.mode === mode) return;
  b.dataset.mode = mode;
  b.disabled = mode === 'idle' || mode === 'wait';
  b.classList.toggle('stop', mode === 'stop');
  b.innerHTML = mode === 'stop' ? ICON.stop : ICON.up;
  b.title = {send: 'Send', stop: 'Stop the chat (Esc)', dict: 'Stop dictating and send', idle: 'Send', wait: 'Transcribing'}[mode];
}

function send() {
  const sid = S.sid;
  if (!live(chat(sid))) return;
  const box = $('#input');
  const text = box.value;
  if (!text.trim()) return;
  box.value = '';
  grow();
  saveDraft();
  outbox(sid, text);
  toBottom(true);
  renderDock();
}

// ------------------------------------------------------------------ the microphone (transcriptions-gpt on the Mac)

// '' -> starting (capture buffers while the Mac's take starts) -> live (250 ms uploads, in order) -> wait (the Mac
// transcribes) -> ''. The text lands at the end of the one draft; when Send ended the dictation, it goes out with
// what was typed to the chat open at that tap, whichever chat is open when the text comes. The level bars are the
// browser's own capture.
// Nothing iOS leaves hanging leaves the button dead: every step has a deadline (a microphone it never hands over,
// an audio context it keeps suspended, a request it froze while the app was away), the take then fails with the
// step's name (reported to the Mac) and the next tap starts clean; a capture that goes silent is reopened once, then
// ends the take with what was said; the worklet has the old ScriptProcessor behind it.
const MIC = {state: '', id: null, take: null, frames: [], pump: null, held: null, levels: [], peak: 0, began: 0,
  waitFrom: 0, heard: 0, step: '', tap: 0, raf: 0, takes: 0, refused: ''};
const MIC_STEP = {microphone: 20, audio: 5, capture: 6, mac: 12, upload: 10, transcript: 130};  // s

function within(step, p) {
  MIC.step = step;
  let timer;
  const late = new Promise((_, no) => {
    timer = setTimeout(() => no(new Error(`${step}: no answer in ${MIC_STEP[step]} s`)), MIC_STEP[step] * 1000);
  });
  return Promise.race([p, late]).finally(() => clearTimeout(timer));
}

// A mic request with its step's deadline -> the server's answer with its status (0: no connection or too late).
async function micCall(path, body, step) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), MIC_STEP[step] * 1000);
  MIC.step = step;
  try {
    const r = await fetch(path, {method: 'POST', body, signal: ctl.signal,
      headers: {'Content-Type': typeof body === 'string' ? 'application/json' : 'application/octet-stream'}});
    let d = {};
    try { d = await r.json(); } catch {}
    return Object.assign({status: r.status}, d);
  } catch {
    return {ok: false, status: 0, err: ctl.signal.aborted ? `${step}: no answer in ${MIC_STEP[step]} s` : `${step}: no connection`};
  } finally {
    clearTimeout(timer);
  }
}

function micButton() {
  const rec = MIC.state !== '';
  $('#composer').classList.toggle('rec', rec);
  if (!rec) takePill('');
  $('#wave').hidden = !rec;
  if ($('#mic').dataset.rec !== String(rec)) { $('#mic').dataset.rec = rec; $('#mic').innerHTML = rec ? ICON.x : ICON.mic; }
  $('#mic').title = rec ? 'Stop and put the text in the box' : 'Dictate';
  $('#mic').disabled = MIC.state === 'wait' || BUB.busy;
  renderSend();
  renderDock();
  renderMicbar();
  if (rec && !MIC.raf) MIC.raf = requestAnimationFrame(drawWave);
}

function level(buf) {
  const a = new Int16Array(buf);
  let sum = 0;
  for (let i = 0; i < a.length; i++) sum += a[i] * a[i];
  return fromRms(Math.sqrt(sum / Math.max(1, a.length)) / 32768);
}
const fromRms = (rms) => Math.max(0, Math.min(1, (20 * Math.log10(rms + 1e-6) + 55) / 45));

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
    if (!(MIC.take && MIC.take.macmic)) MIC.peak = 0;  // MacMic's level holds until its next beat
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
  const b = BUB.doc, polish = MIC.state === 'wait' && b && b.remote && b.pill === 'polish' && b.polish_since;
  const clock = (t) => { const k = Math.max(0, Math.floor(now() - t)); return Math.floor(k / 60) + ':' + String(k % 60).padStart(2, '0'); };
  const text = polish ? 'Polishing ' + clock(polish) : MIC.state === 'wait' ? 'Transcribing…'
    : MIC.state === 'starting' ? 'Starting…' : clock(MIC.began) + (MIC.take && MIC.take.macmic ? ' · MacMic' : '');
  const html = MIC.state === 'live' ? text : `<span class="shimmer">${text}</span>`;
  if ($('#wavet').dataset.h !== html) { $('#wavet').dataset.h = html; $('#wavet').innerHTML = html; }
  takePill(text);
  MIC.raf = requestAnimationFrame(drawWave);
}

// A take runs on whatever he opens in the app; where the composer is out of sight (a page, a covering sheet, no
// chat open) this pill says it still runs: a tap on it brings the composer back, × ends the take into the box.
function takePill(text) {
  const hidden = !MIC.state || (S.sid && $('#overlay').hidden && !$('#chat').hidden
    && ($('#sheet').hidden || document.body.classList.contains('docked')));
  const pill = $('#takepill');
  if (pill.hidden !== hidden) pill.hidden = hidden;
  if (hidden) return;
  if ($('#takept').textContent !== text) $('#takept').textContent = text;
  const x = MIC.state !== 'live' && MIC.state !== 'starting';
  if ($('#takex').hidden !== x) $('#takex').hidden = x;
}

function release(take) {
  if (take.stream) take.stream.getTracks().forEach((t) => t.stop());
  const ctx = take.ctx;
  if (ctx) setTimeout(() => ctx.close().catch(() => {}), 100);
  take.stream = take.ctx = null;
}

const microphone = () => navigator.mediaDevices.getUserMedia({audio: {channelCount: 1}});

async function micStart() {
  if (BUB.busy) return;
  if (BUB.doc && BUB.doc.macmic === 'streaming') return micMacMic();
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    toast('⚠ the microphone needs the https link (page lan --app)');
    return;
  }
  const take = {ctx: null, stream: null, src: null, node: null, reopened: false};
  Object.assign(MIC, {state: 'starting', id: null, take, frames: [], held: null, levels: [], peak: 0, began: now(),
    heard: 0});
  micButton();
  try {
    // Inside the tap: iOS starts and resumes audio only from a gesture, so neither waits behind the microphone.
    const ctx = take.ctx = new (window.AudioContext || window.webkitAudioContext)();
    const resumed = ctx.resume();
    take.stream = await microphoneOrPlain(take);
    if (MIC.take !== take) return release(take);
    if (take.ctx === ctx) await within('audio', resumed);
    await micCapture(take);
    if (MIC.take !== take) return release(take);
    const d = await micCall('/api/mic/start', '{}', 'mac');
    if (MIC.take !== take) {
      if (d.ok) micCall(`/api/mic/${d.id}/cancel`, '{}', 'upload');
      return;
    }
    if (!d.ok) throw new Error(d.err || 'the Mac did not start');
    Object.assign(MIC, {state: 'live', id: d.id, began: now(), heard: now(), refused: ''});
    MIC.takes++;
    micButton();
    MIC.pump = micPump(d.id, take);
  } catch (e) {
    if (MIC.take !== take) release(take);
    else if (e && e.name === 'NotAllowedError') micRefused(e);
    else micFail(String(e.message || e));
  }
}

// A take on MacMic's stream (transcriptions-gpt ipad-mic/, the native iPad app): iPadOS refuses the browser the
// microphone at times (Egor 2026-11-08: through reloads and an app relaunch, no prompt) while MacMic has it. The
// pill's every look keeps MacMic streaming in the background (ipad-want), so while it streams a take uses it: no
// microphone of the page's, which would interrupt MacMic, nothing to upload; /alive beats tell the Mac the page is
// still there, as chunks do for a browser take.
async function micMacMic() {
  const take = {ctx: null, stream: null, macmic: true};
  Object.assign(MIC, {state: 'starting', id: null, take, frames: [], held: null, levels: [], peak: 0, began: now(),
    heard: 0});
  micButton();
  const d = await micCall('/api/mic/start', '{"via": "macmic"}', 'mac');
  if (MIC.take !== take) {
    if (d.ok) micCall(`/api/mic/${d.id}/cancel`, '{}', 'upload');
    return;
  }
  if (!d.ok) {
    if (d.status === 409 && /MacMic/.test(d.err || '')) {
      if (BUB.doc) BUB.doc.macmic = 'asleep';
      micDrop();
      MIC.refused = MIC.refused || 'asleep';
      renderMicbar();
    } else micFail(d.err || 'the Mac did not start');
    return;
  }
  Object.assign(MIC, {state: 'live', id: d.id, began: now(), heard: now(), refused: ''});
  MIC.takes++;
  micButton();
  MIC.pump = micAlive(d.id, take);
}

// A beat each 0.3 s: the take's client is there, and the receiver's level of MacMic's stream draws the wave.
async function micAlive(id, take) {
  let lost = 0, gone = 0;
  while (MIC.take === take && MIC.state === 'live') {
    await new Promise((r) => setTimeout(r, 300));
    if (MIC.take !== take || MIC.state !== 'live') return;
    const d = await micCall(`/api/mic/${id}/alive`, '{}', 'upload');
    if (MIC.take !== take || MIC.state !== 'live') return;
    if (d.status === 404) { micFail('the Mac dropped the take'); return; }
    if (!d.ok) {
      if (++lost >= 3) { micFail(d.err || 'the Mac does not answer'); return; }
      continue;
    }
    lost = 0;
    MIC.peak = fromRms(d.level || 0);
    // MacMic suspended or gone (iOS, a call): what it streamed is the take.
    gone = d.macmic && d.macmic !== 'streaming' ? gone + 1 : 0;
    if (gone >= 4) { micStop('', 'MacMic stopped: kept what was said'); return; }
  }
}

// A refusal (NotAllowedError) is asked again the plainest way: no AudioContext running, no constraints, the context
// made after the stream. Egor 2026-11-08: refused with the permission at "prompt", focus, a tap, and a reload did
// not help; which way works, and how many inputs the iPad lists, goes to page report.
async function microphoneOrPlain(take) {
  try {
    return await within('microphone', microphone());
  } catch (e) {
    if (!e || e.name !== 'NotAllowedError' || MIC.take !== take) throw e;
    if (take.ctx) { const old = take.ctx; take.ctx = null; old.close().catch(() => {}); }
    let inputs = '?';
    try { inputs = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'audioinput').length; } catch {}
    let stream = null;
    try {
      stream = await within('microphone', navigator.mediaDevices.getUserMedia({audio: true}));
      take.ctx = new (window.AudioContext || window.webkitAudioContext)();
      await within('audio', take.ctx.resume());
      report({kind: 'mic', msg: `refused, then the plain request worked · inputs ${inputs}`});
      return stream;
    } catch (again) {
      if (stream) stream.getTracks().forEach((t) => t.stop());
      e.diag = `inputs ${inputs} · plain retry ${stream ? 'got it, audio ' : ''}${again && again.name || again}`;
      throw e;
    }
  }
}

// The iPad refusing the microphone at once, no prompt shown (Egor 2026-11-08: three in a row, ~185 ms each, on a
// day it had recorded): what the browser says about it goes to page report, and the composer says so with a Reload,
// the one thing a page can do (a fresh page asks for the microphone anew).
async function micRefused(e) {
  const step = MIC.step;
  micDrop();
  let perm = '?';
  try {
    perm = (await Promise.race([navigator.permissions.query({name: 'microphone'}),
      new Promise((_, no) => setTimeout(no, 1000))])).state;
  } catch {}
  const ua = navigator.userActivation;
  report({kind: 'mic', msg: [`refused at ${step}: ${e.name} ${String(e.message).slice(0, 60)}`, `permission ${perm}`, `focus ${document.hasFocus()}`,
    `visible ${document.visibilityState}`, `activation ${ua ? ua.isActive + '/' + ua.hasBeenActive : '?'}`,
    `standalone ${matchMedia('(display-mode: standalone)').matches}`, `loaded ${Math.round(performance.now() / 1000)} s ago`,
    `takes ${MIC.takes}`, e.diag || ''].filter(Boolean).join(' · ').slice(0, 300)});
  MIC.refused = perm === 'denied' ? 'denied' : 'refused';
  renderMicbar();
  // The tap meant a take: MacMic streaming takes it at once; else the row offers to open MacMic.
  const asked = now();  // a fresh look, not one already on its way
  for (let i = 0; i < 16 && BUB.at <= asked; i++) { pullBubble(); await new Promise((r) => setTimeout(r, 250)); }
  if (MIC.state === '' && MIC.refused && BUB.doc && BUB.doc.macmic === 'streaming') micMacMic();
}

// The worklet, or the ScriptProcessor iOS still has when the worklet will not load; both give 20 ms frames.
async function micCapture(take) {
  const got = (buf) => {
    if (MIC.take !== take || (MIC.state !== 'starting' && MIC.state !== 'live')) return;
    MIC.frames.push(buf);
    MIC.heard = now();
    MIC.peak = Math.max(MIC.peak, level(buf));
  };
  const ctx = take.ctx;
  try {
    if (!window.AudioWorkletNode) throw new Error('no AudioWorklet');
    await within('capture', ctx.audioWorklet.addModule('/app/mic-worklet.js'));
    take.node = new AudioWorkletNode(ctx, 'mic16k');
    take.node.port.onmessage = (e) => got(e.data);
  } catch (e) {
    if (MIC.take !== take) return;
    report({kind: 'mic', msg: `worklet: ${e.message || e}; script processor instead`});
    take.node = ctx.createScriptProcessor(4096, 1, 1);
    const feed = frames16k(ctx.sampleRate, got);
    take.node.onaudioprocess = (ev) => feed(ev.inputBuffer.getChannelData(0));
  }
  take.src = ctx.createMediaStreamSource(take.stream);
  take.src.connect(take.node);
  take.node.connect(ctx.destination);  // writes no output: silence, but the graph pulls it
}

// mic-worklet.js's resampling for the ScriptProcessor: each 16 kHz sample averages the input samples it covers.
function frames16k(rate, out) {
  const step = rate / 16000;
  let pos = 0, sum = 0, n = 0, k = 0, frame = new Int16Array(320);
  return (ch) => {
    for (let i = 0; i < ch.length; i++) {
      sum += ch[i];
      n++;
      if (++pos < step) continue;
      pos -= step;
      const v = Math.max(-1, Math.min(1, sum / n));
      frame[k++] = v < 0 ? v * 32768 : v * 32767;
      sum = n = 0;
      if (k === 320) { out(frame.buffer); frame = new Int16Array(320); k = 0; }
    }
  };
}

// A capture that stopped giving frames (iOS hands the microphone to a call, Siri, another app) gets a new one once.
async function micReopen(take) {
  take.reopened = true;
  report({kind: 'mic', msg: 'capture went silent; reopened', ms: Math.round((now() - MIC.began) * 1000)});
  try {
    if (take.stream) take.stream.getTracks().forEach((t) => t.stop());
    if (take.src) take.src.disconnect();
    take.stream = await within('microphone', microphone());
    if (MIC.take !== take) return release(take);
    if (take.ctx.state !== 'running') await within('audio', take.ctx.resume());
    take.src = take.ctx.createMediaStreamSource(take.stream);
    take.src.connect(take.node);
    take.bad = 0;
    MIC.heard = now();
  } catch (e) {
    if (MIC.take === take) micStop('', 'the microphone went silent: kept what was said');
  }
}

async function micPump(id, take) {
  while (MIC.take === take && MIC.state === 'live') {
    await new Promise((r) => setTimeout(r, 250));
    if (!(await micFlush(id, take))) return;
  }
}

// Everything buffered, in pieces under the server's 256 KB cap -> false when the take is over. A lost piece is
// silence to the receiver; three lost in a row end it.
async function micFlush(id, take) {
  let lost = 0;
  while (MIC.frames.length && MIC.take === take) {
    const batch = MIC.frames.splice(0, 200);
    const body = new Int16Array(batch.length * 320);
    batch.forEach((f, k) => body.set(new Int16Array(f), k * 320));
    const d = await micCall(`/api/mic/${id}/chunk`, body.buffer, 'upload');
    if (MIC.take !== take) return false;
    if (d.status === 404) { micFail('the Mac dropped the take'); return false; }
    if (d.ok) lost = 0;
    else if (++lost >= 3) { micFail(d.err || 'uploads fail'); return false; }
  }
  return MIC.take === take;
}

// quiet: the Mac ends the take itself (a restore over it), so no cancel goes there.
function micDrop(quiet) {
  const id = MIC.id, take = MIC.take, held = MIC.held;
  if (take) release(take);
  if (take && take.stream) take.stream.getTracks().forEach((t) => t.stop());
  Object.assign(MIC, {state: '', id: null, take: null, frames: [], held: null});
  if (held && held.head) putBack(held.head);
  micButton();
  if (id && quiet !== true) micCall(`/api/mic/${id}/cancel`, '{}', 'upload');
}

function micFail(msg) {
  report({kind: 'mic', msg: `${MIC.state} ${MIC.step}: ${msg}`.slice(0, 300), ms: Math.round((now() - MIC.began) * 1000)});
  micDrop();
  toast('⚠ dictation: ' + msg);
  setTimeout(pullBubble, 1500);  // a take the Mac kept is offered back at once
}

// text at the end of v, a space between.
const joined = (v, text) => (text ? (v && !/\s$/.test(v) ? v + ' ' : v || '') + text : v || '');

// ------------------------------------------------------------------ the Mac's voice pill, mirrored
// transcriptions-gpt's pill on the Mac shows and offers more than this composer: a cut take to restore, the other
// result ready, the polish seconds. He never sees it from the iPad, so its state comes here (/api/mic/bubble: the
// daemon's own record of what the pill was sent) and these buttons do what its clicks do. A take restored comes back
// as text in the box, for editing.
const BUB = {doc: null, at: 0, busy: false, gone: kept('restored')};
async function pullBubble() {
  await once('bubble', async () => {
    const d = await api('/api/mic/bubble', null, 5000);
    BUB.doc = d.ok ? d : null;
    BUB.at = now();
    renderMicbar();
  });
}

const hhmm = (t) => new Date(t * 1000).toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'});
// One composer for all of it (Egor 2026-11-08: no bar of their own above it). A take's row holds what its moment
// offers: a restore armed at its start, Paste now through the polish, the other result. Idle, a cut take takes the
// box's place until it is restored into the box or hidden: typing and a lost take do not share it.
function renderMicbar() {
  const b = BUB.doc, r = b && b.restore;
  const offer = r && r.name && !BUB.gone[r.name] ? r : null;
  const when = offer ? `<small>${hhmm(offer.at)}${offer.chars ? ' · ' + kTok(offer.chars) + ' chars' : ''}</small>` : '';
  let inTake = '', lost = '';
  if (MIC.state === 'live' && offer && offer.armed) {
    inTake = `<button type="button" class="pill" data-restore="${esc(offer.name)}">↺ Restore the cut one${when}</button>`;
  } else if (b && MIC.state === 'wait' && b.remote) {
    const polish = b.pill === 'polish' && b.polish_since;
    if (polish || b.alt === 'ready') {
      inTake = `<button type="button" class="pill" data-usealt>${polish && b.alt !== 'ready' ? 'Paste now' : 'Use the other result'}</button>`;
    } else if (b.alt === 'failed') inTake = '<span class="mt c-red">● ● the other result failed</span>';
  }
  if (BUB.busy) lost = '<span class="mt shimmer">Restoring the cut dictation…</span>';
  else if (MIC.state === '' && MIC.refused && !offer && !(b && b.macmic === 'streaming')) {
    // macmic:// opens MacMic, which streams once in front; back here the next tap records it.
    lost = `<span class="mt c-red">⚠ ${MIC.refused === 'asleep' ? 'MacMic is asleep'
      : 'The iPad refused the microphone' + (MIC.refused === 'denied' ? ' (blocked in Settings)' : '')}</span>` +
      '<a class="pill" href="macmic://open">Open MacMic</a>' +
      (MIC.refused === 'asleep' ? '' : '<button type="button" class="pill" data-reload>Reload</button>') +
      `<button type="button" class="ib" data-unrefuse aria-label="Hide">${ICON.x}</button>`;
  }
  else if (MIC.state === '' && offer) {
    lost = `<span class="mt">↺ Cut dictation ${when}</span>` +
      `<button type="button" class="pill" data-restore="${esc(offer.name)}">Restore</button>` +
      `<button type="button" class="ib" data-forget="${esc(offer.name)}" aria-label="Hide">${ICON.x}</button>`;
  }
  $('#composer').classList.toggle('degraded', !!(b && b.degraded && MIC.state));
  if ($('#composer').classList.contains('lost') !== !!lost) {
    $('#composer').classList.toggle('lost', !!lost);
    renderDock();
  }
  for (const [box, html] of [[$('#waveb'), inTake], [$('#lost'), lost]]) {
    box.hidden = box.id === 'lost' && !html;
    if (box.dataset.h === html) continue;
    box.dataset.h = html;
    box.innerHTML = html;
  }
}

async function micRestore(name) {
  if (BUB.busy || (MIC.state && MIC.state !== 'live')) return;
  BUB.busy = true;
  if (MIC.state === 'live') micDrop(true);  // the Mac discards that take for the restore, as its pill does
  renderMicbar();
  micButton();
  const d = await api('/api/mic/restore', {name}, 250000).catch(() => ({ok: false, err: 'no connection'}));
  BUB.busy = false;
  const text = (d.ok && d.text || '').trim();
  if (text) {
    BUB.gone[name] = now();
    for (const [k, t] of Object.entries(BUB.gone)) if (now() - t > 86400) delete BUB.gone[k];
    keep('restored', BUB.gone);
    $('#input').value = joined($('#input').value, text);
    saveDraft();
    grow();
  } else toast('⚠ restore: ' + (d.err || 'nothing came back'));
  micButton();
  pullBubble();
}

// What was typed before a dictation that never came back goes back into the draft, ahead of anything typed since.
function putBack(text) {
  const box = $('#input');
  box.value = box.value.trim() ? text.replace(/\s*$/, '\n') + box.value : text;
  saveDraft();
  grow();
}

// then 'send': the transcript goes out with what was typed, to the chat open now; the input is his again at once.
async function micStop(then = '', why = '') {
  if (MIC.state === 'starting') { micDrop(); return; }
  if (MIC.state !== 'live') return;
  const {id, take} = MIC;
  if (then === 'send' && S.sid) {
    const box = $('#input');
    MIC.held = {to: S.sid, head: box.value};
    box.value = '';
    saveDraft();
    grow();
  }
  if (take.stream) take.stream.getTracks().forEach((t) => t.stop());
  await new Promise((r) => setTimeout(r, 80));  // the worklet's last frames
  if (MIC.take !== take) return;
  Object.assign(MIC, {state: 'wait', waitFrom: now()});
  micButton();
  release(take);
  await MIC.pump;
  if (MIC.take !== take || !(await micFlush(id, take))) return;
  const d = await micCall(`/api/mic/${id}/stop`, '{}', 'transcript');
  if (MIC.take !== take) return;
  const held = MIC.held;
  Object.assign(MIC, {state: '', id: null, take: null, held: null});
  micButton();
  if (why) toast('⚠ ' + why);
  const text = (d.ok && d.text || '').trim();
  if (!d.ok) {
    report({kind: 'mic', msg: `wait transcript: ${d.err || d.status}`, ms: Math.round((now() - MIC.waitFrom) * 1000)});
    toast('⚠ ' + (d.err || 'no transcript'));
  }
  const join = (v) => joined(v, text);
  if (held) {
    const full = join(held.head);
    if (d.ok && full.trim()) {
      outbox(held.to, full);
      if (held.to === S.sid) toBottom(true);
    } else if (held.head) putBack(held.head);
  } else {
    $('#input').value = join($('#input').value);
    saveDraft();
    grow();
  }
  renderDock();
}

// The 1 s tick's look at a take: a start or a transcript past every deadline, a capture gone silent.
function micWatch() {
  if (!MIC.take) return;
  const t = now();
  if (MIC.state === 'starting' && t - MIC.began > 45) micFail('the start hung at ' + MIC.step);
  else if (MIC.state === 'wait' && t - MIC.waitFrom > MIC_STEP.transcript + 20) micFail('no transcript');
  else if (MIC.state === 'live' && MIC.take.macmic) {
    // The daemon ended the take itself (its stall salvage): the transcript is in the take's file, the stop fetches it.
    if (BUB.at > MIC.began + 1 && BUB.doc && BUB.doc.state !== 'recording') micStop('', 'MacMic stopped: kept what was said');
  } else if (MIC.state === 'live') {
    // Dead: no frames (iOS suspended the audio), or a track the system ended or muted (a call, Siri, another app);
    // a pause in his speech is neither.
    const take = MIC.take, tr = take.stream && take.stream.getAudioTracks()[0];
    take.bad = !tr || tr.readyState === 'ended' || tr.muted ? take.bad || t : 0;
    if (t - MIC.heard < 2.5 && !(take.bad && t - take.bad >= 2)) return;
    if (!take.reopened) micReopen(take);
    else micStop('', 'the microphone went silent: kept what was said');
  }
}

function grow() {
  const box = $('#input');
  if (!box.offsetParent) return;  // not shown: a hidden textarea measures 0, it is sized when its chat opens
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
    const id = it.key ? `${path}/${it.key}` : `${path}/${k}:${word}`;
    const open = it.sub && S.menuOpen.has(id);
    const row = `<div class="mi${it.dis ? ' dis' : ''}${it.sub ? ' has' : ''}${open ? ' open' : ''}${it.cls ? ' ' + it.cls : ''}"` +
      ` data-id="${esc(id)}"${it.sid ? ` data-sid="${esc(it.sid)}"` : ''}>` +
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

// The load per chat, as the menubar's Chats/other shows it (bin/chat-load's chats.json, one tick old at most): a
// row with workers or apps under it opens them, a chat's row opens the chat.
async function refreshLoad() {
  await once('load', async () => {
    S.load = await api('/api/load');
    if (S.sheet === 'load') renderSheet();
  });
}
function loadItems(rows) {
  return (rows || []).map((r) => {
    if (r === '-') return {sep: true};
    if (typeof r === 'string') return {r: [{t: r}]};
    return {r: [{t: r.text || ''}], cls: r.alarm ? 'alarm' : r.dim ? 'dim' : '', sid: r.sub ? '' : r.session || '', key: r.session || '',
      sub: r.sub ? loadItems(r.sub) : null};
  });
}

// The info panel stays where he left it, open or shut, across chats and reloads (Codex's right panel): only its ×
// (or Esc) turns it off. Both sidebars keep the width he dragged them to, the sheet's per kind.
const ui = kept('ui');
ui.w = ui.w || {};
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
function openSheet(kind) {
  if (S.sheet === kind) { closeSheet(); return; }
  if (kind === 'info') { ui.info = true; keep('ui', ui); }
  S.sheet = kind;
  const sh = $('#sheet');
  sh.className = 'sheet ' + kind;
  sh.style.width = ui.w[kind] ? ui.w[kind] + 'px' : '';
  sh.hidden = $('#scrim').hidden = false;
  $('#sheetb').innerHTML = '';
  sheetHtml = '';
  document.querySelectorAll('[data-sheet]').forEach((b) => b.classList.toggle('on', b.dataset.sheet === kind));
  if (kind === 'term') S.term = {hist: '', end: true, busy: false};
  renderSheet();
  dock();
  if (kind === 'menu') refreshMenu();
  if (kind === 'pages') refreshPages();
  if (kind === 'term') pullScreen();
  if (kind === 'info') pullInfo();
  if (kind === 'load') refreshLoad();
}

// quiet: not his choice to turn info off (the app had no chat to show, or a tap beside a covering sheet); else
// closing another sheet brings info back.
function closeSheet(quiet) {
  const was = S.sheet;
  if (was === 'info' && quiet !== true) { ui.info = false; keep('ui', ui); }
  S.sheet = '';
  $('#sheet').hidden = $('#scrim').hidden = true;
  dock();
  document.querySelectorAll('[data-sheet]').forEach((b) => b.classList.remove('on'));
  if (quiet !== true && was !== 'info') infoBack();
}
// A sheet docks beside the thread (Codex's side panel) only while the thread keeps room of its own; else it covers
// the thread, a tap beside it closes it.
const THREAD_MIN = 380;
const fits = (w) => innerWidth > 760 && innerWidth - $('#side').offsetWidth - w - 16 >= THREAD_MIN;
function dock() {
  const on = !!S.sheet && fits($('#sheet').offsetWidth);
  document.body.classList.toggle('docked', on);
  document.body.style.setProperty('--sheetw', $('#sheet').offsetWidth + 'px');
}
function infoBack() { if (ui.info && S.sid && !S.sheet && fits(ui.w.info || 340)) openSheet('info'); }
window.addEventListener('resize', dock);

// A drag on a sidebar's inner edge sets its width, kept across reloads.
function grip(el, width) {
  el.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    el.setPointerCapture(e.pointerId);
    el.classList.add('drag');
    document.body.classList.add('dragging');
    const move = (ev) => { width(ev.clientX); dock(); };
    const up = () => {
      el.removeEventListener('pointermove', move);
      el.classList.remove('drag');
      document.body.classList.remove('dragging');
      keep('ui', ui);
      dock();
    };
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up, {once: true});
    el.addEventListener('pointercancel', up, {once: true});
  });
}
const sideWidth = () => { if (ui.w.side) document.documentElement.style.setProperty('--sidew', ui.w.side + 'px'); };
grip($('#sidegrip'), (x) => { ui.w.side = clamp(Math.round(x), 220, Math.min(520, innerWidth - 420)); sideWidth(); });
grip($('#sheetgrip'), (x) => {
  if (!S.sheet) return;
  ui.w[S.sheet] = clamp(Math.round(innerWidth - 8 - x), 300, Math.min(900, innerWidth - 240));
  $('#sheet').style.width = ui.w[S.sheet] + 'px';
});
sideWidth();

// The Terminal sheet: the screen, redrawn only when it changed, so his scroll stays where he put it; at the end it
// follows new lines. His scroll to the top brings the tab's whole scrollback (Terminal keeps it), held still while
// he reads it, until he is back at the end.
let termSet = 0;
function termScroll() {
  const body = $('#sheetb'), tm = S.term;
  if (S.sheet !== 'term' || !tm || performance.now() - termSet < 120) return;
  tm.end = body.scrollHeight - body.scrollTop - body.clientHeight < 30;
  if (tm.end && tm.hist) { tm.hist = ''; renderSheet(); }
  else if (body.scrollTop < 40 && !tm.hist && !tm.busy) pullHistory();
}
async function pullHistory() {
  const sid = S.sid, tm = S.term;
  tm.busy = true;
  const d = await api(`/api/chat/${encodeURIComponent(sid)}/screen?history=1`, null, 30000).catch(() => ({ok: false}));
  tm.busy = false;
  if (sid !== S.sid || tm !== S.term || S.sheet !== 'term' || tm.end) return;
  const text = d.ok ? String(d.res || '').replace(/[\s ]+$/, '') : '';
  if (!text || text.split('\n').length <= S.scr.lines.length) return;
  const body = $('#sheetb'), h0 = body.scrollHeight;
  tm.hist = text;
  renderSheet();
  termSet = performance.now();
  body.scrollTop += body.scrollHeight - h0;
}

function footer(html) {
  const f = $('#sheetf');
  if (f.dataset.h === html) return;
  f.dataset.h = html;
  f.innerHTML = html;
  f.hidden = !html;
}

let sheetHtml = '';  // what #sheetb shows: an unchanged sheet is not redrawn, his scroll and the layout stay
function renderSheet() {
  const body = $('#sheetb');
  const top = body.scrollTop;
  let html = '', foot = '';
  if (S.sheet === 'term') {
    const c = chat(S.sid), tm = S.term || (S.term = {hist: '', end: true, busy: false});
    $('#sheett').textContent = 'Terminal';
    $('#sheets').textContent = [c ? (c.tty || '').replace('/dev/', '') : '', tm.hist ? 'scrollback' : ''].filter(Boolean).join(' · ');
    // One slow answer is no lost tab: the warning waits for three in a row, as the screen itself does.
    html = (S.screenFails >= 3 && S.screenErr ? `<div class="term-err">⚠ ${esc(S.screenErr)}</div>` : '') +
      `<pre class="term">${esc(tm.hist || S.scr.lines.join('\n'))}</pre>`;
    if (sheetHtml !== html) {
      sheetHtml = html;
      body.innerHTML = html;
      termSet = performance.now();
      body.scrollTop = tm.end ? body.scrollHeight : top;
      dock();
    }
    footer('');
    return;
  }
  if (S.sheet === 'menu') {
    $('#sheett').textContent = 'Menu';
    $('#sheets').textContent = '';
    html = menuErr ? `<div class="term-err">⚠ ${esc(menuErr)}</div>` : lastMenu ? menuHtml(lastMenu, '') : '';
  } else if (S.sheet === 'load') {
    const d = S.load || {};
    $('#sheett').textContent = 'Load';
    $('#sheets').textContent = d.as_of ? ago(d.as_of) : '';
    html = d.rows ? menuHtml(loadItems(d.rows), 'load') || '<div class="none">No load data from the Mac</div>' : '';
  } else if (S.sheet === 'info') {
    const d = S.info && S.info.sid === S.sid ? S.info : null;
    $('#sheett').textContent = d && d.root ? base(d.root) : 'Info';
    $('#sheets').textContent = '';
    html = d ? infoHtml(d) : '';
    if (!runOf(S.sid) && !S.workers.some((w) => w.sid === S.sid)) {
      foot = `<button type="button" class="btn ghost" data-pin>${S.pins.includes(S.sid) ? 'Unpin' : '⚑ Pin to the top'}</button>`;
    }
    if (live(chat(S.sid))) foot += '<button type="button" class="btn" data-end>End chat · close its window</button>';
  } else if (S.sheet === 'pages') {
    // This chat's pages; all of them a tap away (and with no chat open).
    const mine = S.sid && !S.pagesAll, all = S.pages || [];
    const list = mine ? all.filter((p) => p.owner === S.sid) : all;
    $('#sheett').textContent = mine ? 'Pages of this chat' : 'Pages';
    $('#sheets').textContent = S.pages ? String(list.length) : '';
    html = list.map((p) =>
      `<div class="prow" data-pid="${esc(p.pid)}"><div class="t"><b>${p.owner && p.owner === S.sid ? '<i class="dot"></i>' : ''}` +
      `<span>${esc(p.title)}</span></b><small>${esc(p.chat)}</small></div>` +
      `<span class="at">${ago(Date.parse(p.updated) / 1000)}</span></div>`).join('') ||
      (S.pages ? `<div class="none">${mine ? 'This chat made no pages' : 'No pages'}</div>` : '');
    if (S.sid) foot = `<button type="button" class="btn" data-allpages>${mine ? 'All pages · ' + all.length : 'Only this chat'}</button>`;
  }
  if (sheetHtml !== html) {
    sheetHtml = html;
    body.innerHTML = html;
    body.scrollTop = top;
    dock();
  }
  footer(foot);
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
  if (S.sid !== sid || !S.log) {
    S.sid = sid;
    resetLog();
    Object.assign(S, {screen: '', screenAt: 0, screenFails: 0, screenErr: '', scr: parseScreen('')});
    $('#opts').innerHTML = $('#suggest').innerHTML = '';
    $('#opts').dataset.h = $('#suggest').dataset.h = '';
    S.info = null;
    S.pagesAll = false;
    S.term = {hist: '', end: true, busy: false};
    const c = chat(sid);
    if (c && c.spoke) { seen[sid] = c.spoke; keep('seen', seen); }
  }
  show(true);
  grow();
  renderHead();
  renderList();
  renderDock();
  pullLog();
  pullScreen();
  pullInfo();
  if (S.sheet) renderSheet(); else infoBack();
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
    saveDraft();
    S.sid = null;
    S.log = null;
    renderList();
  }
  if (S.sheet === 'term' || S.sheet === 'info') closeSheet(true);
  show(false);
  title('');
  $('#termbtn').hidden = true;
}

// ------------------------------------------------------------------ events

$('#composer').addEventListener('submit', (e) => {
  e.preventDefault();
  const mode = $('#send').dataset.mode;
  if (mode === 'dict') micStop(live(chat(S.sid)) ? 'send' : '');  // a chat not open takes nothing: the draft keeps it
  else if (mode === 'stop') key({key: 'esc'});
  else send();
});
$('#input').addEventListener('input', () => { grow(); saveDraft(); renderDock(); });
$('#input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
});
$('#mic').addEventListener('click', () => {
  const t = performance.now();
  if (t - MIC.tap < 500) return;  // a double tap would start the take and cancel it at once
  MIC.tap = t;
  // × ends the take with what was said in the box, for editing; Send sends it. Only a take not yet started drops.
  if (MIC.state === '') micStart();
  else if (MIC.state === 'live') micStop();
  else if (MIC.state === 'starting') micDrop();
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
  saveDraft();
  renderDock();
});
document.querySelectorAll('[data-sheet]').forEach((b) => b.addEventListener('click', () => openSheet(b.dataset.sheet)));
$('#sheetx').addEventListener('click', closeSheet);
$('#scrim').addEventListener('click', () => closeSheet(true));
$('#sheetb').addEventListener('scroll', termScroll, {passive: true});
$('#sheetf').addEventListener('click', (e) => {
  if (e.target.closest('[data-end]')) closeLive();
  else if (e.target.closest('[data-pin]')) togglePin();
  else if (e.target.closest('[data-allpages]')) { S.pagesAll = !S.pagesAll; renderSheet(); }
});
$('#update').addEventListener('click', reload);
$('#composer').addEventListener('click', (e) => {
  const r = e.target.closest('[data-restore]'), f = e.target.closest('[data-forget]');
  if (r) micRestore(r.dataset.restore);
  else if (f) { BUB.gone[f.dataset.forget] = now(); keep('restored', BUB.gone); renderMicbar(); }
  else if (e.target.closest('[data-reload]')) reload();
  else if (e.target.closest('[data-unrefuse]')) { MIC.refused = ''; renderMicbar(); }
  else if (e.target.closest('[data-usealt]')) api('/api/mic/usealt', {}, 5000).then((d) => { if (!d.ok) toast('⚠ ' + (d.err || 'nothing to use')); pullBubble(); }).catch(() => {});
});
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && S.sheet) closeSheet(); });
$('#sheetb').addEventListener('click', (e) => {
  const go = e.target.closest('.mi[data-sid]');
  if (go) {
    if (!document.body.classList.contains('docked')) closeSheet(true);
    location.hash = '#chat/' + encodeURIComponent(go.dataset.sid);
    return;
  }
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
$('#find').addEventListener('input', () => { S.q = $('#find').value; renderList(); });
$('#find').addEventListener('focus', () => { if (now() - (S.histAt || 0) > 20) { S.histAt = now(); refreshHistory(); } });
$('#find').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); searchSaid(); } });
$('#list').addEventListener('click', (e) => {
  if (e.target.closest('[data-more]')) { S.histN += 50; renderList(); }
  else if (e.target.closest('[data-said]')) searchSaid();
});
$('#openbtn').addEventListener('click', openPast);
$('#close').addEventListener('click', () => { $('#overlay').hidden = true; $('#frame').src = 'about:blank'; });
$('#takepill').addEventListener('click', (e) => {
  if (e.target.closest('#takex')) { if (MIC.state === 'live') micStop(); else if (MIC.state === 'starting') micDrop(); return; }
  if (!$('#overlay').hidden) $('#close').click();
  if (S.sheet && !document.body.classList.contains('docked')) closeSheet(true);
  if (!S.sid || $('#chat').hidden) { const c = S.chats.find((x) => live(x)); if (c) location.hash = '#chat/' + c.sid; }
});
window.addEventListener('hashchange', route);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible') return;
  NET.visibleAt = now();
  refreshChats();
  pullBubble();  // back from MacMic: its stream is what the next tap records
  if (S.sid) { pullLog(); pullScreen(); }
});

// The on-screen keyboard: iOS pans the whole page to the input rather than resizing it, which moved the header out
// of view. The app is sized to the visible part instead (not while pinch-zoomed), so only the thread moves.
// Only a real change of the visible part (the keyboard coming or going) moves anything: the viewport's scroll events
// of a bounce leave the layout and the thread alone.
const VV = window.visualViewport;
if (VV) {
  let was = '';
  const fit = () => {
    if (Math.abs(VV.scale - 1) > 0.01) return;
    const h = Math.round(VV.height), top = Math.max(0, Math.round(VV.offsetTop));
    if (h + ',' + top === was) return;
    const grown = was && +was.split(',')[0] !== h;
    was = h + ',' + top;
    const st = document.documentElement.style;
    st.setProperty('--vvh', h + 'px');
    st.setProperty('--vvt', top + 'px');
    if (grown && STICK.on) toBottom(true);
  };
  VV.addEventListener('resize', fit);
  VV.addEventListener('scroll', fit);
}

// ------------------------------------------------------------------ taps that did nothing
// Egor 2026-11-08: on the iPad a first tap often does nothing and the second works. A tap (one finger, no slide)
// on something that acts but followed by no click within 0.7 s goes to `page report` (op client, kind tap-lost) with
// what happened under the finger: the touched node gone (a redraw), how much of the page changed meanwhile, a scroll
// still gliding, the keyboard up, how long the finger stayed.
const ACTS = 'a[href],button,summary,input,textarea,select,label,[data-sheet],[data-pid],[data-sid],.mi.has';
const TAPS = {cur: null, ended: null, scroll: 0, sent: 0};
const describe = (el) => !el ? '' : el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') +
  (el.classList.length ? '.' + [...el.classList].join('.') : '') +
  Object.keys(el.dataset).filter((k) => k !== 'h').map((k) => `[${k}]`).join('') +
  ` “${norm(el.textContent).slice(0, 24)}”`;
document.addEventListener('scroll', () => { TAPS.scroll = performance.now(); }, {capture: true, passive: true});
document.addEventListener('touchstart', (e) => {
  if (TAPS.cur && TAPS.cur.obs) TAPS.cur.obs.disconnect();
  const p = e.touches[0], el = e.target, act = el.closest && el.closest(ACTS);
  if (e.touches.length !== 1 || !act) { TAPS.cur = null; return; }
  const tap = {t: performance.now(), x: p.clientX, y: p.clientY, el, act, moved: false, muts: 0, clicked: false,
    glide: Math.round(performance.now() - TAPS.scroll), obs: new MutationObserver((m) => { tap.muts += m.length; })};
  tap.obs.observe(document.body, {childList: true, subtree: true, characterData: true});
  TAPS.cur = tap;
  // A redraw that removes the touched node leaves its touchend to the detached node, out of the document's reach.
  el.addEventListener('touchend', tapEnd, {once: true, passive: true});
  el.addEventListener('touchcancel', tapCancel, {once: true, passive: true});
}, {capture: true, passive: true});
document.addEventListener('touchmove', (e) => {
  const tap = TAPS.cur, p = e.touches[0];
  if (tap && p && Math.hypot(p.clientX - tap.x, p.clientY - tap.y) > 10) tap.moved = true;
}, {capture: true, passive: true});
function tapEnd() {
  const tap = TAPS.cur;
  TAPS.cur = null;
  if (!tap) return;
  tap.held = Math.round(performance.now() - tap.t);
  if (tap.moved) { tap.obs.disconnect(); return; }
  TAPS.ended = tap;
  setTimeout(() => {
    tap.obs.disconnect();
    if (tap.clicked || TAPS.sent >= 30) return;
    TAPS.sent++;
    const gone = !tap.el.isConnected ? 'node' : !tap.act.isConnected ? 'target' : '';
    report({kind: 'tap-lost', path: describe(tap.act).slice(0, 120), ms: tap.held,
      msg: [`replaced ${gone || 'no'}`, `mutations ${tap.muts}`, `scrolled ${tap.glide} ms before`,
        `focus ${(document.activeElement || {}).id || (document.activeElement || {}).tagName || ''}`,
        `sheet ${S.sheet || '-'}`, `mic ${MIC.state || '-'}`].join(' · ')});
  }, 700);
}
function tapCancel() { if (TAPS.cur) TAPS.cur.obs.disconnect(); TAPS.cur = null; }
document.addEventListener('touchend', tapEnd, {capture: true, passive: true});
document.addEventListener('touchcancel', tapCancel, {capture: true, passive: true});
document.addEventListener('click', () => { if (TAPS.ended) TAPS.ended.clicked = true; }, true);
// The composer's Send is a submit: a tap that reaches it submits, which is its click.
document.addEventListener('submit', () => { if (TAPS.ended) TAPS.ended.clicked = true; }, true);

// The polls, only while visible: chats every 3 s, the open transcript every 1 s (new bytes only), its screen every
// 2 s while it works or asks, 4 s idle, 1 s with the Terminal sheet open; its statusline and changed files every 3 s;
// menu 5 s, load 3 s and pages 20 s while shown; the Mac's pill 1 s through a dictation, 10 s else.
let tick = 0;
setInterval(() => {
  if (document.visibilityState !== 'visible') return;
  tick++;
  if (tick % 3 === 0) refreshChats();
  if (tick % 60 === 30) refreshHistory();
  if (S.sid) {
    pullLog();
    const c = chat(S.sid);
    const every = S.sheet === 'term' ? 1 : busy(c) || S.scr.opts.length ? 2 : 4;
    if (live(c) && tick % every === 0) pullScreen();
  }
  if (S.sid && tick % 3 === 1) pullInfo();
  if (S.sheet === 'menu' && tick % 5 === 0) refreshMenu();
  if (S.sheet === 'pages' && tick % 20 === 0) refreshPages();
  if (S.sheet === 'load' && tick % 3 === 2) refreshLoad();
  // The Mac's pill: every second through a take (a restore offered at its start, the polish seconds), else now and then.
  // A refusal on screen looks every second: MacMic opened, the row goes and the next tap records it.
  if (MIC.state || BUB.busy || MIC.refused ? true : S.sid && tick % 10 === 5) pullBubble();
  micWatch();
  payOwed();
  clocks();
}, 1000);

NET.visibleAt = now();
$('#input').value = draft.text;
grow();
renderMachine();
refreshChats().then(route);
refreshHistory();
