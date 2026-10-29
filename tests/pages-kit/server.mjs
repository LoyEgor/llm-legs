// An in-memory stand-in for `page serve` (share/pages/CONTRACT.md routes) over generated fixture
// media, for tests/pages-kit/run.mjs. Never touches PAGES_DIR: pages live in this process only.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const KIT = path.resolve(process.env.PAGES_KIT_DIR || path.join(path.dirname(fileURLToPath(import.meta.url)), "../../share/pages/kit"));
const TYPES = { ".js": "text/javascript", ".html": "text/html; charset=utf-8", ".md": "text/markdown",
  ".png": "image/png", ".wav": "audio/wav" };

function png(w, h, rgb) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) raw.set(rgb(x, y), y * (w * 3 + 1) + 1 + x * 3);
  const chunk = (type, data) => {
    const td = Buffer.concat([Buffer.from(type), data]), out = Buffer.alloc(8 + td.length);
    out.writeUInt32BE(data.length, 0); td.copy(out, 4); out.writeUInt32BE(zlib.crc32(td), 4 + td.length);
    return out;
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

function wav(freq, secs) {
  const rate = 8000, n = rate * secs, b = Buffer.alloc(44 + n * 2);
  b.write("RIFF", 0); b.writeUInt32LE(36 + n * 2, 4); b.write("WAVEfmt ", 8); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate * 2, 28);
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write("data", 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(8000 * Math.sin((2 * Math.PI * freq * i) / rate)), 44 + i * 2);
  return b;
}

// A scene of 480×240: a gradient, a disc and a bar; variants differ in one known block each.
const scene = (x, y) => {
  if ((x - 120) ** 2 + (y - 120) ** 2 < 60 ** 2) return [30, 90, 200];
  if (x > 260 && x < 420 && y > 100 && y < 140) return [40, 40, 40];
  return [230 - (x >> 3), 220, 200 + (y >> 4)];
};
export function fixtures(dir) {
  fs.mkdirSync(dir, { recursive: true });
  const put = (name, buf) => { fs.writeFileSync(path.join(dir, name), buf); return path.join(dir, name); };
  return {
    orig: put("orig.png", png(480, 240, scene)),
    a: put("a.png", png(480, 240, (x, y) => (x >= 96 && x < 144 && y >= 40 && y < 80 ? [220, 30, 30] : scene(x, y)))),
    b: put("b.png", png(480, 240, (x, y) => (x >= 360 && x < 400 && y >= 170 && y < 210 ? [30, 200, 60] : scene(x, y)))),
    px: put("px.png", png(120, 60, (x, y) => scene(x * 4, y * 4))),
    s1: put("s1.wav", wav(440, 3)),
    s2: put("s2.wav", wav(660, 3)),
  };
}

// pages: {pid: spec with absolute media paths}. Serving follows the contract: media paths become
// /p/<pid>/m/<n>?v=…, `_` keys go, blind variants lose id/label (in a fixed swap per item).
export function serve(pages) {
  const P = new Map();
  for (const [pid, spec] of Object.entries(pages)) P.set(pid, { spec, specRev: 1, rev: 0, items: {}, ops: new Set(), posts: [], fail: false, stateHits: 0 });
  const served = (pid) => {
    const p = P.get(pid), media = [];
    const walk = (v) => {
      if (Array.isArray(v)) return v.map(walk);
      if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).filter(([k]) => !k.startsWith("_")).map(([k, x]) => [k, walk(x)]));
      if (typeof v === "string" && v.startsWith("/") && fs.existsSync(v)) { media.push(v); return `/p/${pid}/m/${media.length - 1}?v=1`; }
      return v;
    };
    const s = walk(p.spec);
    if (s.blind) for (const it of s.items) {
      it.variants = it.variants.map(({ id, label, ...rest }) => rest);
      if (it.id.charCodeAt(it.id.length - 1) % 2) it.variants.reverse();
      it.variants.forEach((v, i) => { v.slot = "ABCDEFGHIJ"[i]; });
    }
    return { spec: { ...s, pid, rev: p.specRev }, media };
  };
  const send = (res, code, body, type = "application/json", extra = {}) => {
    res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-cache", ...extra });
    res.end(typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  };
  const apply = (p, item, fields, by, op) => {
    const s = (p.items[item] ||= {}), at = new Date().toISOString();
    for (const [f, v] of Object.entries(fields)) if (v === null) delete s[f]; else s[f] = { v, at, by };
    p.rev += 1;
    if (op) p.ops.add(op);
  };
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, "http://x"), m = u.pathname.match(/^\/p\/([a-z0-9][a-z0-9-]{0,63})\/(.*)$/);
    if (u.pathname.startsWith("/kit/")) {
      const f = path.resolve(KIT, u.pathname.slice(5));
      if (!f.startsWith(KIT + path.sep) || !fs.existsSync(f)) return send(res, 404, "no");
      return send(res, 200, fs.readFileSync(f), TYPES[path.extname(f)] || "application/octet-stream");
    }
    const p = m && P.get(m[1]);
    if (!p) return send(res, 404, "no");
    const [, pid, rest] = m;
    if (rest === "") return send(res, 200, fs.readFileSync(path.join(KIT, "loader.html")), TYPES[".html"]);
    if (rest === "spec") return send(res, 200, served(pid).spec);
    if (rest === "state") { p.stateHits += 1; return send(res, 200, { rev: p.rev, spec_rev: p.specRev, items: p.items }); }
    const mm = rest.match(/^m\/(\d+)$/);
    if (mm) {
      const f = served(pid).media[+mm[1]];
      if (!f) return send(res, 404, "no");
      const buf = fs.readFileSync(f), type = TYPES[path.extname(f)], r = (req.headers.range || "").match(/bytes=(\d+)-(\d*)/);
      if (!r) return send(res, 200, buf, type, { "Accept-Ranges": "bytes" });
      const a = +r[1], b = r[2] ? Math.min(+r[2], buf.length - 1) : buf.length - 1;
      return send(res, 206, buf.subarray(a, b + 1), type, { "Content-Range": `bytes ${a}-${b}/${buf.length}`, "Accept-Ranges": "bytes" });
    }
    if (rest === "patch" && req.method === "POST") {
      let body = "";
      req.on("data", (c) => { body += c; });
      req.on("end", () => {
        const bad = !String(req.headers["content-type"]).startsWith("application/json")
          || (req.headers.origin && req.headers.origin !== `http://${req.headers.host}`);
        if (bad) return send(res, 403, "no");
        let j;
        try { j = JSON.parse(body); } catch (e) { return send(res, 400, "no"); }
        p.posts.push(j);
        if (p.fail) return send(res, 503, "down");
        if (p.ops.has(j.op)) return send(res, 200, { rev: p.rev, spec_rev: p.specRev, dup: true });
        if (!p.spec.items.some((it) => it.id === j.item)) return send(res, 409, "no item");
        apply(p, j.item, j.fields, "egor", j.op);
        send(res, 200, { rev: p.rev, spec_rev: p.specRev, dup: false });
      });
      return;
    }
    send(res, 404, "no");
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok({
    port: server.address().port, pages: P, close: () => { server.closeAllConnections(); server.close(); },
    set: (pid, item, fields) => apply(P.get(pid), item, fields, "chat"),   // `page set`
    bump: (pid, change) => { const p = P.get(pid); change(p.spec); p.specRev += 1; },   // `page new` update
  })));
}
