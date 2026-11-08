// The chats app: Egor's live Mac chats on the iPad (share/pages/CONTRACT.md "App"). No build step, no framework.
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const kept = (k) => { try { return JSON.parse(localStorage.getItem(k) || '{}'); } catch { return {}; } };
const keep = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} };
const now = () => Date.now() / 1000;

const seen = kept('seen');
const drafts = kept('drafts');
const S = {chats: [], workers: [], machine: null, view: '', sid: null, log: null, running: {}, menuOpen: new Set(),
  pages: null, screen: '', offline: false, auth: true, pending: []};

// ------------------------------------------------------------------ plumbing

let toastTimer = 0;
function toast(text) {
  const t = $('#toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 4000);
}

async function api(path, body) {
  const init = body ? {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)}
    : {cache: 'no-store'};
  let r;
  try {
    r = await fetch(path, init);
  } catch (e) {
    setOffline(true);
    throw e;
  }
  setOffline(false);
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

function setOffline(v) {
  if (S.offline !== v) { S.offline = v; renderMachine(); }
}

// One call of each kind in flight at a time; a slow Mac never stacks requests up.
async function once(key, fn) {
  if (S.running[key]) return;
  S.running[key] = true;
  try { await fn(); } catch (e) { if (e.message !== 'auth' && !(e instanceof TypeError)) console.warn(key, e); }
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

function left(t) {
  const s = (t || 0) - now();
  if (s <= 0) return '';
  const m = Math.ceil(s / 60);
  return m >= 60 ? Math.floor(m / 60) + 'h' + String(m % 60).padStart(2, '0') : m + 'm';
}

const base = (p) => (p || '').replace(/\/+$/, '').split('/').pop();
const shortModel = (m) => (m || '').replace(/^claude-/, '').replace(/-(\d+)-(\d+)$/, ' $1.$2').replace(/\[1m\]/, ' 1M');
const kTok = (n) => n ? (n >= 1000 ? Math.round(n / 1000) + 'k' : String(n)) : '';
const chat = (sid) => S.chats.find((c) => c.sid === sid) || S.workers.find((c) => c.sid === sid);

// ------------------------------------------------------------------ machine and the chat list

function meter(label, a, b, max, value) {
  const pa = Math.max(0, Math.min(100, (a / max) * 100));
  const pb = Math.max(0, Math.min(100 - pa, (b / max) * 100));
  return `<div class="meter"><span>${label}</span><div class="bar"><i class="a" style="left:0;width:${pa}%"></i>` +
    `<i class="b" style="left:${pa}%;width:${pb}%"></i></div><span class="v">${value}</span></div>`;
}

function renderMachine() {
  const box = $('#machine');
  if (!S.auth) {
    box.innerHTML = '<div style="color:var(--red)">⚠ 403 — open the <b>page lan --app</b> link once</div>';
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
  if (S.offline) html += '<div style="color:var(--red)">⚠ offline</div>';
  box.innerHTML = html || '<div class="v">…</div>';
  box.style.color = m.alarm ? 'var(--red)' : '';
}

function dotClass(c) {
  const st = c.load && c.load.state;
  if (c.status === 'busy') return 'busy';
  if (st === 'full speed' || st === 'needs CPU') return 'cpu';
  if (c.status === 'shell') return 'shell';
  return 'idle';
}

function snippet(c) {
  if (c.last && c.last.t) return (c.last.role === 'user' ? '› ' : '') + c.last.t;
  return c.away || c.cwd || '';
}

function chatRow(c) {
  const warm = left(c.until);
  const unread = c.spoke && c.spoke > (seen[c.sid] || 0) + 1 && S.sid !== c.sid;
  const load = c.load ? `${c.load.cores.toFixed(1)}c ${c.load.gb.toFixed(1)}G` : '';
  return `<a class="row${S.sid === c.sid ? ' sel' : ''}" href="#chat/${esc(c.sid)}">` +
    `<span class="dot ${dotClass(c)}"></span><div class="body">` +
    `<div class="l1"><span class="name">${esc(c.name)}</span>${unread ? '<span class="unread"></span>' : ''}` +
    `<span class="warm${warm ? ' hot' : ''}">${warm ? '◔' + warm : ago(c.spoke)}</span></div>` +
    `<div class="l2"><span class="acct">${esc(c.account || '?')}</span><span class="proj">${esc(base(c.cwd))}</span>` +
    `<span class="num">${load}</span></div><div class="l3">${esc(snippet(c))}</div></div></a>`;
}

function renderList() {
  const box = $('#list');
  const top = box.scrollTop;
  let html = S.chats.map(chatRow).join('');
  if (S.workers.length) html += '<div class="group">workers</div>' + S.workers.map(chatRow).join('');
  box.innerHTML = html;
  box.scrollTop = top;
}

async function refreshChats() {
  await once('chats', async () => {
    const d = await api('/api/chats');
    S.auth = true;
    // New client files reload the app (a home-screen app has no reload button); the draft and the open chat stay,
    // a running dictation or send finishes first.
    if (d.client && !S.client) S.client = d.client;
    if (d.client && d.client !== S.client && MIC.state === '' && !$('#send').disabled) {
      if (S.sid) { drafts[S.sid] = $('#input').value; keep('drafts', drafts); }
      location.reload();
      return;
    }
    S.chats = d.chats || [];
    S.workers = d.workers || [];
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
    if (S.view === 'chat') renderHead();
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
  return '<div style="overflow-x:auto"><table class="md">' + body.map((r, k) => '<tr>' +
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

function render(it, tools) {
  if (it.k === 'user') return node('msg user', esc(it.t.trim()));
  if (it.k === 'asst') return node('msg asst', md(it.t));
  if (it.k === 'event') return node('event', esc(it.t));
  if (it.k === 'away') return node('away', '↺ ' + esc(it.t));
  if (it.k === 'tool') {
    const d = document.createElement('details');
    d.className = 'tool';
    const [head, ...rest] = (it.s || '').split('\n');
    d.innerHTML = `<summary><span class="n">${esc(it.n)}</span> ${esc(head)}</summary>` +
      (rest.length ? `<pre>${esc(rest.join('\n'))}</pre>` : '');
    if (it.id) tools[it.id] = d;
    return d;
  }
  if (it.k === 'result') {
    const t = it.id && tools[it.id];
    const pre = `<pre>${esc(it.t || '∅')}</pre>`;
    if (t) {
      t.insertAdjacentHTML('beforeend', pre);
      if (it.err) t.classList.add('err');
      return null;
    }
    const d = document.createElement('details');
    d.className = 'tool' + (it.err ? ' err' : '');
    d.innerHTML = `<summary><span class="n">↳</span> ${esc((it.t || '').split('\n')[0])}</summary>${pre}`;
    return d;
  }
  return null;
}

function resetLog() {
  S.log = {start: null, end: null, tools: {}};
  $('#log').innerHTML = '';
}

function olderButton() {
  const b = document.createElement('button');
  b.className = 'older';
  b.textContent = '⌃';
  b.onclick = loadOlder;
  return b;
}

async function pullLog(first) {
  const sid = S.sid;
  if (!sid || !S.log) return;
  await once('log', async () => {
    const L = S.log;
    const d = await api(`/api/chat/${encodeURIComponent(sid)}/log` + (L.end == null ? '' : `?after=${L.end}`));
    if (sid !== S.sid || L !== S.log) return;
    if (L.end != null && d.size < L.end) { resetLog(); return; }
    const box = $('#log');
    const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 160;
    if (L.start == null) {
      L.start = d.start;
      if (d.start > 0) box.appendChild(olderButton());
    }
    L.end = d.end;
    const frag = document.createDocumentFragment();
    let said = false;
    for (const it of d.items || []) {
      const n = render(it, L.tools);
      if (n) frag.appendChild(n);
      if (it.k === 'user') said = true;
    }
    if (said) dropPending();
    box.insertBefore(frag, box.querySelector('.msg.pending'));
    renderChips(d.pages || []);
    if (first || atBottom) box.scrollTop = box.scrollHeight;
  });
}

async function loadOlder() {
  const sid = S.sid, L = S.log;
  if (!L || !L.start) return;
  await once('older', async () => {
    const d = await api(`/api/chat/${encodeURIComponent(sid)}/log?before=${L.start}`);
    if (sid !== S.sid || L !== S.log) return;
    const box = $('#log');
    const h0 = box.scrollHeight;
    box.querySelector('.older')?.remove();
    const frag = document.createDocumentFragment();
    if (d.start > 0) frag.appendChild(olderButton());
    for (const it of d.items || []) {
      const n = render(it, L.tools);
      if (n) frag.appendChild(n);
    }
    L.start = d.start;
    box.prepend(frag);
    box.scrollTop += box.scrollHeight - h0;
  });
}

function dropPending() {
  document.querySelectorAll('.msg.pending').forEach((n) => n.remove());
}

function renderChips(pages) {
  $('#chips').innerHTML = pages.map((p) => `<span class="chip" data-pid="${esc(p.pid)}">◫ ${esc(p.title)}</span>`).join('');
}

function renderHead() {
  const c = chat(S.sid);
  if (!c) {
    $('#title').innerHTML = `<b>${esc(S.sid)}</b><small>closed</small>`;
    $('#composer').hidden = true;
    return;
  }
  const warm = left(c.until);
  const bits = [c.account || '?', shortModel(c.model), kTok(c.ctx), warm ? '◔' + warm : '', base(c.cwd) + (c.branch && !['main', 'HEAD'].includes(c.branch) ? ':' + c.branch : '')];
  $('#title').innerHTML = `<b><span class="dot ${dotClass(c)}" style="display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px"></span>${esc(c.name)}</b>` +
    `<small>${esc(bits.filter(Boolean).join(' · '))}</small>`;
  $('#composer').hidden = !c.tty || S.workers.includes(c);
}

// ------------------------------------------------------------------ the Terminal screen and the menu answers

async function pullScreen() {
  const sid = S.sid;
  const c = chat(sid);
  if (!c || !c.tty || S.workers.includes(c)) { $('#screen').hidden = true; $('#opts').innerHTML = ''; return; }
  await once('screen', async () => {
    const d = await api(`/api/chat/${encodeURIComponent(sid)}/screen`);
    if (sid !== S.sid) return;
    $('#screen').hidden = false;
    if (!d.ok || d.res === 'no-tab') {
      S.screen = '';
      $('#screen').textContent = '⚠ ' + (d.res === 'no-tab' ? 'no Terminal tab' : d.err || 'no screen');
      $('#opts').innerHTML = '';
      return;
    }
    S.screen = d.res || '';
    renderScreen();
  });
}

function renderScreen() {
  const box = $('#screen');
  const lines = S.screen.replace(/[\s ]+$/, '').split('\n');
  const full = box.classList.contains('full');
  box.textContent = (full ? lines : lines.slice(-10)).join('\n');
  box.scrollTop = box.scrollHeight;
  renderOpts(lines);
}

function renderOpts(lines) {
  const opts = [];
  let cur = null;
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
  const box = $('#opts');
  if (cur == null || opts.length < 2) { box.innerHTML = ''; return; }
  box.innerHTML = opts.map((t, k) =>
    `<button type="button" data-choose="${k + 1}"${k + 1 === cur ? ' class="cur"' : ''}>${k + 1}. ${esc(t)}</button>`).join('');
}

async function key(body) {
  const sid = S.sid;
  const d = await api(`/api/chat/${encodeURIComponent(sid)}/key`, body).catch(() => ({ok: false, err: 'offline'}));
  if (!d.ok) toast('⚠ ' + (d.err || 'failed'));
  setTimeout(() => { pullScreen(); pullLog(); }, 350);
}

async function send() {
  const sid = S.sid;
  const box = $('#input');
  const text = box.value;
  if (!text.trim()) return;
  $('#send').disabled = true;
  const d = await api(`/api/chat/${encodeURIComponent(sid)}/send`, {text}).catch(() => ({ok: false, err: 'offline'}));
  $('#send').disabled = false;
  if (!d.ok) { toast('⚠ ' + (d.err || 'not sent')); return; }
  if (sid === S.sid) {
    box.value = '';
    grow();
    delete drafts[sid];
    keep('drafts', drafts);
    const log = $('#log');
    log.appendChild(node('msg user pending', esc(text)));
    log.scrollTop = log.scrollHeight;
  }
  setTimeout(() => { pullScreen(); pullLog(); }, 400);
}

// ------------------------------------------------------------------ the microphone (transcriptions-gpt on the Mac)

// '' -> starting (capture buffers while the Mac's take starts) -> live (250 ms uploads, in order) -> wait (the Mac
// transcribes) -> ''; the text lands at the end of the draft of the chat the dictation began in, never sent by itself.
const MIC = {state: '', id: null, sid: null, ctx: null, stream: null, frames: [], pump: null};

function micButton() {
  $('#mic').className = MIC.state;
}

async function micStart() {
  if (!navigator.mediaDevices || !window.AudioWorkletNode) {
    toast('⚠ the microphone needs the https link (page lan --app)');
    return;
  }
  Object.assign(MIC, {state: 'starting', id: null, sid: S.sid, frames: []});
  micButton();
  try {
    MIC.ctx = new AudioContext();  // inside the tap: iOS starts audio only from a gesture
    MIC.stream = await navigator.mediaDevices.getUserMedia({audio: {channelCount: 1}});
    await MIC.ctx.audioWorklet.addModule('/app/mic-worklet.js');
    const node = new AudioWorkletNode(MIC.ctx, 'mic16k');
    node.port.onmessage = (e) => { if (MIC.state === 'starting' || MIC.state === 'live') MIC.frames.push(e.data); };
    MIC.ctx.createMediaStreamSource(MIC.stream).connect(node);
    node.connect(MIC.ctx.destination);  // writes no output: silence, but the graph pulls it
    await MIC.ctx.resume();
    const d = await api('/api/mic/start', {});
    if (!d.ok) throw new Error(d.err || 'the Mac did not start');
    if (MIC.state !== 'starting') return;
    Object.assign(MIC, {state: 'live', id: d.id});
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
  Object.assign(MIC, {state: '', id: null, frames: []});
  micButton();
  if (id) api(`/api/mic/${id}/cancel`, {}).catch(() => {});
}

async function micStop() {
  const {id, sid} = MIC;
  if (MIC.stream) MIC.stream.getTracks().forEach((t) => t.stop());
  await new Promise((r) => setTimeout(r, 80));  // the worklet's last frames
  MIC.state = 'wait';
  micButton();
  micRelease();
  await MIC.pump;
  if (!(await micFlush(id))) return;
  const d = await api(`/api/mic/${id}/stop`, {}).catch(() => ({ok: false, err: 'offline'}));
  Object.assign(MIC, {state: '', id: null});
  micButton();
  if (!d.ok) { toast('⚠ ' + (d.err || 'no transcript')); return; }
  const text = (d.text || '').trim();
  if (!text) return;
  const join = (v) => (v && !/\s$/.test(v) ? v + ' ' : v || '') + text;
  if (sid === S.sid) {
    const box = $('#input');
    box.value = join(box.value);
    grow();
  }
  drafts[sid] = sid === S.sid ? $('#input').value : join(drafts[sid]);
  keep('drafts', drafts);
}

function grow() {
  const box = $('#input');
  box.style.height = 'auto';
  box.style.height = Math.min(box.scrollHeight + 2, window.innerHeight * 0.4) + 'px';
}

// ------------------------------------------------------------------ the menubar mirror

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

let lastMenu = null;
async function refreshMenu() {
  await once('menu', async () => {
    const d = await api('/api/menu');
    const box = $('#menu');
    if (d.err) { box.textContent = '⚠ ' + d.err; return; }
    lastMenu = d.items;
    const top = box.scrollTop;
    box.innerHTML = menuHtml(d.items, '');
    box.scrollTop = top;
  });
}

// ------------------------------------------------------------------ pages

async function refreshPages() {
  await once('pages', async () => {
    const d = await api('/api/pages');
    S.pages = d.pages || [];
    $('#pages').innerHTML = S.pages.map((p) =>
      `<div class="prow" data-pid="${esc(p.pid)}"><div class="t"><b>${esc(p.title)}</b>` +
      `<small>${esc(p.chat)} · ${esc(p.module)}</small></div><span class="at">${ago(Date.parse(p.updated) / 1000)}</span></div>`).join('');
  });
}

function overlay(path) {
  $('#frame').src = path;
  $('#overlay').hidden = false;
}

// ------------------------------------------------------------------ views and routing

function show(view) {
  S.view = view;
  for (const id of ['chat', 'menu', 'pages', 'empty']) $('#' + id).hidden = id !== (view || 'empty');
  document.querySelectorAll('#views a').forEach((a) => a.classList.toggle('sel', a.dataset.view === view));
  document.body.classList.toggle('inside', !!view);
  if (view !== 'chat') $('#chips').innerHTML = '';
}

function openChat(sid) {
  if (S.sid && S.sid !== sid) {
    drafts[S.sid] = $('#input').value;
    keep('drafts', drafts);
  }
  if (S.sid !== sid || !S.log) {
    S.sid = sid;
    resetLog();
    $('#opts').innerHTML = '';
    $('#screen').textContent = '';
    $('#screen').classList.remove('full');
    $('#input').value = drafts[sid] || '';
    grow();
    const c = chat(sid);
    if (c && c.spoke) { seen[sid] = c.spoke; keep('seen', seen); }
  }
  show('chat');
  renderHead();
  renderList();
  pullLog(true);
  pullScreen();
}

function route() {
  const [view, arg] = location.hash.slice(1).split('/');
  if (view === 'chat' && arg) return openChat(decodeURIComponent(arg));
  if (S.sid && view !== 'chat') {
    drafts[S.sid] = $('#input').value;
    keep('drafts', drafts);
    S.sid = null;
    S.log = null;
    renderList();
  }
  if (view === 'menu') {
    show('menu');
    $('#title').innerHTML = '<b>Menu</b>';
    refreshMenu();
  } else if (view === 'pages') {
    show('pages');
    $('#title').innerHTML = '<b>Pages</b>';
    refreshPages();
  } else {
    show('');
    $('#title').innerHTML = '';
  }
}

// ------------------------------------------------------------------ events

$('#composer').addEventListener('submit', (e) => { e.preventDefault(); send(); });
$('#input').addEventListener('input', () => { grow(); if (S.sid) drafts[S.sid] = $('#input').value; });
$('#input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
});
$('#mic').addEventListener('click', () => {
  if (MIC.state === '') micStart();
  else if (MIC.state === 'live') micStop();
});
document.querySelector('.keys').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-key]');
  if (b) key({key: b.dataset.key});
});
$('#opts').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-choose]');
  if (b) key({choose: +b.dataset.choose});
});
$('#screen').addEventListener('click', () => { $('#screen').classList.toggle('full'); renderScreen(); });
$('#menu').addEventListener('click', (e) => {
  const row = e.target.closest('.mi.has');
  if (!row) return;
  const id = row.dataset.id;
  if (S.menuOpen.has(id)) S.menuOpen.delete(id); else S.menuOpen.add(id);
  const box = $('#menu');
  const top = box.scrollTop;
  box.innerHTML = menuHtml(lastMenu, '');
  box.scrollTop = top;
});
document.addEventListener('click', (e) => {
  const p = e.target.closest('[data-pid]');
  if (p) { e.preventDefault(); overlay(`/p/${encodeURIComponent(p.dataset.pid)}/`); return; }
  const a = e.target.closest('#log a[href]');
  if (a) {
    const m = a.getAttribute('href').match(/^https?:\/\/(?:127\.0\.0\.1|localhost|[\w-]+\.local):4791(\/[^\s]*)$/);
    if (m) { e.preventDefault(); overlay(m[1]); }
  }
});
$('#close').addEventListener('click', () => { $('#overlay').hidden = true; $('#frame').src = 'about:blank'; });
window.addEventListener('hashchange', route);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') { refreshChats(); if (S.view === 'chat') { pullLog(); pullScreen(); } }
});

let tick = 0;
setInterval(() => {
  if (document.visibilityState !== 'visible') return;
  tick++;
  if (tick % 3 === 0) refreshChats();
  if (S.view === 'chat' && S.sid) {
    pullLog();
    if (tick % 2 === 0) pullScreen();
  }
  if (S.view === 'menu' && tick % 5 === 0) refreshMenu();
  if (S.view === 'pages' && tick % 20 === 0) refreshPages();
}, 1000);

renderMachine();
refreshChats().then(route);
