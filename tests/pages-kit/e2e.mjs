// The real `bin/page serve` + the real kit, end to end: pages made with `page new`, voted in headless
// Chromium, read back with `page state`, a chat's `page set` seen by the open page. A temp PAGES_DIR
// and port 0 only. Arguments: playwright-core directories to try in order. Exit 0 PASS, 1 FAIL, 3 no
// browser could start (the suite skips).
import { spawn, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { fixtures } from "./server.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const PAGE = path.join(ROOT, "bin/page");
let browser = null;
for (const dir of process.argv.slice(2)) {
  try {
    browser = await createRequire(path.join(dir, "package.json"))(dir).chromium.launch({ headless: true });
    break;
  } catch (e) { console.error(`   (${dir}: ${String(e.message).split("\n")[0]})`); }
}
if (!browser) { console.log("SKIP: no headless Chromium for any playwright-core found"); process.exit(3); }

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "pages-e2e-")));
const F = fixtures(path.join(tmp, "media"));
fs.mkdirSync(path.join(tmp, "bin"));
fs.writeFileSync(path.join(tmp, "bin/chat-name"), '#!/bin/sh\necho \'{"name": "e2e chat"}\'\n', { mode: 0o755 });
const env = { ...process.env, PATH: `${tmp}/bin:${process.env.PATH}`, PAGES_DIR: path.join(tmp, "pages"),
  PAGES_KIT_DIR: path.join(ROOT, "share/pages/kit"), CLAUDE_CODE_SESSION_ID: "chat-e2e", TRANSCRIBER_RUNTIME_DIR: path.join(tmp, "tgpt") };
delete env.CLAUDE_LAUNCHER_SESSION;
// A stand-in for transcriptions-gpt's daemon (its MARKS.md): every mark line the server relays, answered by `daemon`.
const marks = [];
let daemon = () => "ignored idle";
fs.mkdirSync(env.TRANSCRIBER_RUNTIME_DIR);
const fake = net.createServer((c) => {
  let got = "";
  c.on("data", (d) => { got += d; if (got.endsWith("\n")) { const m = JSON.parse(got.slice(5)); marks.push(m); c.end(daemon(m) + "\n"); } });
}).listen(path.join(env.TRANSCRIBER_RUNTIME_DIR, "control.sock"));
const page = (args, input) => {
  const r = spawnSync(PAGE, args, { env, input, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`page ${args.join(" ")}: ${r.stderr}`);
  return r.stdout;
};
let checks = 0, failed = 0;
const check = (name, ok, detail = "") => { checks++; if (!ok) { failed++; console.log(`FAIL: ${name} ${detail}`); } };
const until = async (fn, ms = 6000) => { const t0 = Date.now(); for (;;) { const v = await fn(); if (v || Date.now() - t0 > ms) return v; await new Promise((r) => setTimeout(r, 100)); } };

const server = spawn(PAGE, ["serve", "--port", "0"], { env, stdio: ["ignore", "pipe", "inherit"] });
try {
  const port = await new Promise((ok, no) => {
    server.stdout.on("data", (d) => { const m = /127\.0\.0\.1:(\d+)/.exec(String(d)); if (m) ok(m[1]); });
    server.on("exit", (c) => no(new Error(`page serve exited ${c}`)));
  });
  const variants = [{ id: "v77", label: "champ77", src: F.a }, { id: "v78", label: "champ78", src: F.b }];
  const cmp = page(["new", "compare", "--slug", "calib", "--title", "Calib", "--no-open"], JSON.stringify({ blind: true,
    items: [{ id: "p01", original: F.orig, variants, _expected: "v78" }, { id: "p02", original: F.orig, variants }] })).split(" ")[1];
  const crd = page(["new", "cards", "--slug", "seams", "--title", "Seams", "--no-open"], JSON.stringify({
    fields: [{ key: "heard", kind: "choice", options: [{ id: "0" }, { id: "1" }] }],
    items: [{ id: "c11", n: 11, media: [{ kind: "audio", src: F.s1 }] }] })).split(" ")[1];
  const slots = JSON.parse(fs.readFileSync(path.join(env.PAGES_DIR, cmp, "key.json"))).blind.p01;

  const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 } });
  let tab = await ctx.newPage();
  tab.on("pageerror", (e) => check("no page error", false, e.message));
  await tab.goto(`http://127.0.0.1:${port}/p/${cmp}/`);
  await tab.waitForFunction(() => [...document.querySelectorAll(".vp img")].length === 3 && [...document.querySelectorAll(".vp img")].every((i) => i.naturalWidth));
  check("served media loads", true);
  await tab.click('.votes button[data-v="A"]');
  await tab.waitForFunction(() => document.querySelector(".ttl strong")?.textContent.startsWith("2"));
  await tab.type(".side textarea", "halo left", { delay: 30 });
  await until(async () => /^сохранено/.test(await tab.textContent("#status")) && !(await tab.evaluate(() => localStorage.length && Object.keys(localStorage).some((k) => k.startsWith("pages-outbox:") && localStorage.getItem(k) !== "[]"))), 4000);
  const state = page(["state", "calib", "--all"]);
  check("page state shows the blind click with its variant", state.includes(`p01 choice=A(${slots.A}) _expected=v78 by=egor`), state);
  check("page state shows the note", state.includes("p02 note=") && state.includes("halo left"), state);
  check("page state totals", state.includes("answered=1/2"), state);
  check("first unread read shows both, the next none", page(["state", "calib"]).split("\n").length === 4 && page(["state", "calib"]).trim().startsWith("answered="));

  page(["set", "calib", "p02", "choice=B"]);
  check("chat's set shows in the open page", await until(() => tab.$eval('.votes button[data-v="B"]', (b) => b.classList.contains("on")), 6000));

  await tab.goto(`http://127.0.0.1:${port}/p/${crd}/`);
  await tab.waitForFunction(() => document.querySelector("audio")?.getAttribute("src"));
  check("audio Range answers 206", (await tab.evaluate(async () => (await fetch(document.querySelector("audio").src, { headers: { Range: "bytes=0-99" } })).status)) === 206);
  await tab.click('.card[data-id="c11"] .row[data-f="heard"] button[data-v="1"]');
  check("cards vote reaches the store", await until(() => page(["state", "seams", "--all"]).includes("c11 heard=1 by=egor"), 4000));
  // Pictures in text: every way a picture reaches a field, read back by the chat as a path.
  const origin = `http://127.0.0.1:${port}`, note = '.card[data-id="c11"] > .atw > textarea', files = path.join(env.PAGES_DIR, crd, "files");
  const conv = (fmt, ext) => { const out = path.join(tmp, `a.${ext}`); return spawnSync("/usr/bin/sips", ["-s", "format", fmt, F.a, "--out", out]).status === 0 ? out : null; };
  const jpg = conv("jpeg", "jpg"), tiff = conv("tiff", "tiff"), b64 = (p) => fs.readFileSync(p).toString("base64");
  const send = (data, kind = "paste", sel = note) => tab.evaluate(({ sel, data, kind }) => {
    const el = document.querySelector(sel), dt = new DataTransfer();
    el.focus();
    for (const f of data.files || []) dt.items.add(new File([Uint8Array.from(atob(f.b64), (c) => c.charCodeAt(0))], f.name, { type: f.type, lastModified: f.at }));
    for (const [t, v] of Object.entries(data.text || {})) dt.setData(t, v);
    const e = kind === "paste" ? new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true })
      : new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true });
    el.dispatchEvent(e);
    return e.defaultPrevented;
  }, { sel, data, kind });
  const value = () => tab.$eval(note, (el) => el.value);
  const stored = () => (fs.existsSync(files) ? fs.readdirSync(files).filter((n) => n.startsWith("img")).sort() : []);
  await ctx.grantPermissions(["clipboard-read", "clipboard-write"], { origin });
  await tab.click(note);
  await tab.keyboard.type("на куст", { delay: 20 });
  await tab.$eval(note, (el) => el.setSelectionRange(3, 3));
  await tab.evaluate(async (b) => navigator.clipboard.write([new ClipboardItem({
    "image/png": new Blob([Uint8Array.from(atob(b), (c) => c.charCodeAt(0))], { type: "image/png" }),
    "text/html": new Blob(['<meta charset=utf-8><img src="https://example.test/a.png">'], { type: "text/html" }) })]), b64(F.a));
  await tab.keyboard.press("ControlOrMeta+V");
  check("a keyboard paste of a copied picture puts its name at the caret", await until(async () => (await value()) === "на [img1.png] куст"), await value());
  check("…and says nothing", await tab.$eval('.card[data-id="c11"] .atm', (m) => m.textContent === ""));
  const ihdr = (p) => { const b = fs.readFileSync(p); return b.subarray(1, 4).toString() === "PNG" && [b.readUInt32BE(16), b.readUInt32BE(20)].join("x"); };
  check("the pasted picture is stored whole", await until(() => stored().includes("img1.png")) && ihdr(path.join(files, "img1.png")) === "480x240");
  check("page state prints the named picture's path", await until(() => page(["state", "seams", "--all"]).includes(`img1.png=${path.join(files, "img1.png")}`), 4000), page(["state", "seams", "--all"]));
  check("the field's box shows the picture above its text", await until(() => tab.$eval('.card[data-id="c11"] > .atw', (w) =>
    w.firstElementChild.matches(".att") && w.lastElementChild.matches("textarea") && w.querySelector(".att img").naturalWidth > 0).catch(() => false)));
  await tab.keyboard.press("End");
  check("a file copied in Finder is attached, its file name is not typed",
    (await send({ files: [{ b64: b64(jpg), name: "photo.jpg", type: "image/jpeg" }], text: { "text/plain": "photo.jpg" } }))
    && await until(async () => (await value()).endsWith(" [img2.jpg]")), await value());
  const before = await value();
  check("a Finder copy without its file says how to bring it, attaches nothing",
    (await send({ files: [{ b64: b64(F.b), name: "image.png", type: "image/png" }], text: { "text/plain": "IMG_0042.HEIC" } }))
    && await until(() => tab.$eval('.card[data-id="c11"] .atm', (m) => m.classList.contains("err") && /Finder/.test(m.textContent)))
    && (await value()) === before && stored().length === 2);
  check("words with a picture inside paste as words",
    !(await send({ files: [{ b64: b64(F.b), name: "image.png", type: "image/png" }], text: { "text/html": "<p>hello <img src='https://example.test/b.png'></p>", "text/plain": "hello" } }))
    && stored().length === 2);
  check("plain text pastes as text", !(await send({ text: { "text/plain": "просто текст" } })));
  await send({ text: { "text/html": `<img src="data:image/png;base64,${b64(F.b)}">` } });
  check("a picture the clipboard holds only as a data: link is stored", await until(async () => (await value()).includes("[img3.png]")) && stored().includes("img3.png"));
  await send({ text: { "text/html": `<meta charset=utf-8><img src="${origin}/p/${cmp}/m/0?v=1">` } });
  check("a picture the clipboard holds only as a web link is fetched by the server", await until(async () => (await value()).includes("[img4.png]")), await value());
  if (tiff) {
    await send({ files: [{ b64: b64(tiff), name: "shot.tiff", type: "image/tiff" }] }, "drop");
    check("a dropped TIFF becomes a PNG the browser and the model read", await until(async () => (await value()).includes("[img5.png]")) && ihdr(path.join(files, "img5.png")) === "480x240");
  }
  await send({ files: [{ b64: b64(path.join(files, "img1.png")), name: "image.png", type: "image/png" }] });
  check("the same picture again keeps its first name", await until(async () => (await value()).match(/\[img1\.png\]/g)?.length === 2) && !stored().includes("img6.png"), await value());
  const twice = (await value()).split("[img3.png]").length;
  await send({ files: [1, 2].map((at) => ({ b64: b64(F.b), name: "image.png", type: "image/png", at })) });
  check("one picture handed over as two files is one name and no error",
    await until(async () => (await value()).split("[img3.png]").length === twice + 1)
    && await tab.$eval('.card[data-id="c11"] .atm', (m) => m.textContent === ""), await value());
  const chips = stored().length;
  const tiles = await tab.$$eval('.card[data-id="c11"] .att .atc', (c) => c.map((e) => `${e.offsetWidth}x${e.offsetHeight}`));
  check("every picture is a tile of one square size", tiles.length === chips && tiles.every((t) => t === tiles[0]) && /^(\d+)x\1$/.test(tiles[0]), JSON.stringify(tiles));
  await tab.$eval(note, (el) => { el.focus(); el.select(); });
  await tab.keyboard.press("Backspace");
  check("a name deleted from the text leaves its picture dimmed under the field",
    await until(() => tab.$$eval('.card[data-id="c11"] .att .atc.off', (c) => c.length)) === chips);
  await tab.click('.card[data-id="c11"] .att button:text-is("img2.jpg")');
  check("its name button puts the name back", await until(async () => (await value()) === "[img2.jpg]") &&
    await tab.$$eval('.card[data-id="c11"] .att .atc:not(.off)', (c) => c.length) === 1, await value());
  check("page state names only the pictures the text still names", await until(() => {
    const st = page(["state", "seams", "--all"]); return st.includes("img2.jpg=") && !st.includes("img1.png="); }, 4000));
  await tab.reload();
  check("after a reload the field still shows every picture pasted into it",
    await until(() => tab.$$eval('.card[data-id="c11"] .att .atc', (c) => c.length).catch(() => 0)) === chips);
  await tab.click('.card[data-id="c11"] .att img');
  check("a click on a picture opens it full screen among the field's pictures only",
    await until(() => tab.$eval(".zoom .zpos", (z) => z.textContent).catch(() => "")) === `1 / ${chips}` &&
    (await tab.$eval(".zoom > img", (im) => im.src)).endsWith("/f/img1.png"));
  await tab.keyboard.press("Escape");
  const tile = '.card[data-id="c11"] .atc:has(.atn:text-is("img2.jpg"))', shownTiles = () => tab.$$eval('.card[data-id="c11"] .att .atc', (c) => c.length).catch(() => 0);
  await tab.hover(tile);
  await tab.click(`${tile} .atx`);
  check("× takes the picture and its name out of the field", await until(async () => (await value()) === "" && await shownTiles() === chips - 1), await value());
  await tab.keyboard.press("ControlOrMeta+Z");
  check("⌘Z brings both back", await until(async () => (await value()) === "[img2.jpg]" && await shownTiles() === chips), await value());
  await tab.click(`${tile} .atx`);
  check("a removed picture leaves its field for good", await until(async () => (await value()) === "") &&
    await until(async () => (await (await fetch(`${origin}/p/${crd}/files`)).json()).find((f) => f.name === "img2.jpg")?.item === null) &&
    (await tab.reload(), await until(async () => await shownTiles() === chips - 1)));
  await tab.goto(`${origin}/p/${cmp}/`);
  await tab.waitForSelector(".side textarea");
  await send({ files: [{ b64: b64(F.b), name: "image.png", type: "image/png" }] }, "paste", ".side textarea");
  check("compare's note takes pictures too, numbered per page", await until(() => tab.$eval(".side textarea", (el) => el.value.endsWith("[img1.png]"))));
  // «Метка»: ⌥-drag on a loupe marks a box, ⌥-click a point; each becomes a sheet picture named in the note, with a pin.
  const vpBox = (k) => tab.$$eval(".vp", (v, k) => { const r = v[k].getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; }, k);
  const [bx, by] = await vpBox(2);
  await tab.keyboard.down("Alt");
  await tab.mouse.move(bx - 40, by - 30); await tab.mouse.down(); await tab.mouse.move(bx, by, { steps: 4 }); await tab.mouse.move(bx + 40, by + 30, { steps: 4 });
  check("a ⌥-drag shows the rubber band", await tab.$$eval(".vp .band:not([hidden])", (b) => b.length) === 1);
  await tab.mouse.up();
  const cmpFiles = path.join(env.PAGES_DIR, cmp, "files"), pins = async () => (await (await fetch(`${origin}/p/${cmp}/state`)).json()).items.p01?.pins?.v || {};
  check("a ⌥-drag on a variant puts its sheet's name in the note", await until(() => tab.$eval(".side textarea", (el) => el.value.endsWith("[img1.png] [img2.png]"))));
  check("…the sheet is stored, the whole picture and three frames in one row", await until(() => fs.existsSync(path.join(cmpFiles, "img2.png"))) && /^1494x\d+$/.test(ihdr(path.join(cmpFiles, "img2.png"))));
  check("…and a box pin on its slot", await until(async () => { const p = (await pins())["img2.png"]; return p && p.on === "B" && p.at.length === 4 && p.z > 0; }), JSON.stringify(await pins()));
  const [ox, oy] = await vpBox(1);
  await tab.mouse.click(ox + 2, oy + 3);
  await tab.keyboard.up("Alt");
  check("a ⌥-click makes a point pin", await until(async () => { const p = (await pins())["img3.png"]; return p && p.on === "A" && p.at.length === 2; }), JSON.stringify(await pins()));
  check("pins show on every loupe, solid with the number on their own", await until(() => tab.$$eval(".vp", (v) => v.map((e) =>
    [...e.querySelectorAll(".pins div")].map((d) => d.classList.contains("far") ? "-" : d.textContent).join(",")).join(" "))) === "-,- -,3 2,-");
  let pinState = "";
  check("page state unblinds the pin's frame and names its sheet", await until(() => {
    pinState = page(["state", "calib", "--all"]);
    return /p01 .*pins=.*img3\.png/.test(pinState) && pinState.includes(`B(${slots.B})`) && pinState.includes(`A(${slots.A})`)
      && pinState.includes(`img2.png=${path.join(cmpFiles, "img2.png")}`) && pinState.includes("answered=2/2");
  }, 4000), pinState);
  // transcriptions-gpt: every mark goes to its daemon with the moment it began; a running dictation takes the name
  const m2 = marks.find((m) => m.tag === "img2.png");
  check("a mark reaches the dictation daemon with its moment, its sheet and its page", m2 && Math.abs(m2.at - Date.now()) < 60000
    && m2.ref === path.join(cmpFiles, "img2.png") && m2.note.startsWith(`http://127.0.0.1:${port}/p/${cmp}/ - box `), JSON.stringify(marks));
  daemon = (m) => `ok ${m.tag} 2.5`;
  const said = await tab.$eval(".side textarea", (el) => el.value);
  await tab.keyboard.down("Alt"); await tab.mouse.click(ox + 8, oy + 8); await tab.keyboard.up("Alt");
  check("a mark a dictation takes leaves the note alone and says the name comes with the dictation",
    await until(() => tab.$eval(".side .atm", (m) => /\[img4\.png\] .*диктовк/.test(m.textContent))) && await tab.$eval(".side textarea", (el) => el.value) === said);
  check("…the note has the focus for the dictation's paste", await tab.evaluate(() => document.activeElement.matches(".side textarea")));
  check("…and its pin shows before the name arrives", await until(() => tab.$$eval(".vp .pins b", (b) => b.map((x) => x.textContent).includes("4"))));
  await tab.$eval(".side textarea", (el) => el.setSelectionRange(el.value.length, el.value.length));
  await tab.keyboard.insertText(" вот тут [img4.png] криво");
  check("the dictation's paste brings the name; the note says nothing more", await until(() => tab.$eval(".side .atm", (m) => m.textContent === ""))
    && await until(() => page(["state", "calib", "--all"]).includes(`img4.png=${path.join(cmpFiles, "img4.png")}`), 4000));
  await tab.goto(`${origin}/p/${crd}/`);
  await tab.waitForSelector(note);
  // «Метка» on any picture opened full screen: here a picture of the card's note
  daemon = () => "ignored idle";
  await tab.click('.card[data-id="c11"] .att img');
  await tab.waitForFunction(() => document.querySelector(".zoom > img")?.naturalWidth);
  const [zx, zy] = await tab.$eval(".zoom > img", (im) => { const r = im.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; });
  const was = await value();
  await tab.keyboard.down("Alt");
  await tab.mouse.move(zx - 30, zy - 20); await tab.mouse.down(); await tab.mouse.move(zx + 30, zy + 20, { steps: 4 }); await tab.mouse.up();
  await tab.keyboard.up("Alt");
  check("a ⌥-drag on a full-screen picture names its sheet in that picture's own field",
    await until(async () => /\[img\d+\.png\]$/.test(await value()) && (await value()) !== was)
    && await tab.$eval(".zmsg", (m) => /в заметке/.test(m.textContent)), await value());
  daemon = (m) => `ok ${m.tag} 1.0`;
  const kept = await value();
  await tab.keyboard.press("KeyQ"); await tab.mouse.click(zx, zy); await tab.keyboard.press("KeyQ");
  check("…with Q too, and a running dictation takes the name instead",
    await until(() => tab.$eval(".zmsg", (m) => /диктовк/.test(m.textContent))) && (await value()) === kept
    && marks.at(-1).note.includes(`/p/${crd}/ - point `) && await tab.evaluate(() => document.activeElement.matches(".card textarea")), JSON.stringify(marks.at(-1)));
  await tab.keyboard.press("Escape");
  const index = await (await fetch(`http://127.0.0.1:${port}/`)).text();
  check("index lists both pages under the chat name", index.includes("e2e chat") && index.includes(cmp) && index.includes(crd));
  const events = path.join(env.PAGES_DIR, ".events.jsonl");
  check("normal use writes no event line", !fs.existsSync(events));
  tab.removeAllListeners("pageerror");
  await tab.evaluate(() => setTimeout(() => { throw new Error("kit probe"); }));
  const logged = await until(() => fs.existsSync(events) && fs.readFileSync(events, "utf8"), 3000);
  check("a kit error in the page reaches .events.jsonl", logged && JSON.parse(logged).pid === crd && JSON.parse(logged).msg.includes("kit probe"), String(logged));
} catch (e) {
  check("run", false, e.stack);
} finally {
  await browser.close();
  server.kill();
  fake.close();
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(failed ? `FAIL: ${failed} of ${checks} end-to-end checks` : `PASS: ${checks} end-to-end checks`);
process.exit(failed ? 1 : 0);
