// share/pages/kit in headless Chromium over tests/pages-kit/server.mjs. Arguments: playwright-core
// directories to try in order. Screenshots go to tests/pages-kit/out/. Exit 0 PASS, 1 FAIL, 3 no
// browser could start (the suite skips).
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { fixtures, serve } from "./server.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url)), OUT = path.join(HERE, "out");
fs.mkdirSync(OUT, { recursive: true });
let browser = null;
for (const dir of process.argv.slice(2)) {
  try {
    browser = await createRequire(path.join(dir, "package.json"))(dir).chromium.launch({
      headless: true, args: ["--autoplay-policy=no-user-gesture-required"] });
    break;
  } catch (e) { console.error(`   (${dir}: ${String(e.message).split("\n")[0]})`); }
}
if (!browser) { console.log("SKIP: no headless Chromium for any playwright-core found"); process.exit(3); }

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pages-kit-"));
const F = fixtures(tmp);
const item = (id, title, extra = {}) => ({ id, title, original: F.orig,
  variants: [{ id: "v77", label: "champ77", src: F.a, meta: "64 px" }, { id: "v78", label: "champ78", src: F.b }], ...extra });
const vote = () => ({ module: "compare", schema: 1, title: "Калибровка", mode: "vote", pixelated: "auto",
  options: [{ id: "A" }, { id: "B" }, { id: "tie", label: "=" }, { id: "both_bad", label: "оба плохи" }, { id: "unsure", label: "не понять" }],
  tags: ["halo", "jaggies"],
  items: [item("p01", "frog", { q: "контекст", suggest: { choice: "B" } }), item("p02", "cat"),
    item("p03", "pixel", { variants: [{ id: "x", label: "px", src: F.px, meta: "4 px" }, { id: "y", label: "full", src: F.b }] })] });
const srv = await serve({
  vote1: vote(), vote2: vote(), vote3: vote(), vote4: vote(),
  view1: { ...vote(), mode: "view", title: "Обзор" },
  sq1: { ...vote(), integer_zoom: true, zoom_levels: [1, 2, 3] },
  blind1: { module: "compare", schema: 1, title: "Слепо", blind: true,
    items: [{ id: "b01", variants: [{ id: "v77", label: "champ77", src: F.a, meta: "64 px" }, { id: "v78", label: "champ78", src: F.b }] }] },
  cards1: { module: "cards", schema: 1, title: "Швы", sitting_cap: 2,
    fields: [{ key: "heard", label: "слышно", kind: "choice", options: [{ id: "0", label: "не слышу", key: "Digit1" }, { id: "1", label: "слышу", key: "Digit2" }] },
      { key: "kind", kind: "multi", options: [{ id: "click" }, { id: "gap" }] },
      { key: "score", kind: "scale", min: 1, max: 10 }],
    items: [{ id: "c11", n: 11, title: "трек 3", text: "склейка на 6 с", media: [{ kind: "audio", src: F.s1 }], suggest: { heard: "1" } },
      { id: "c12", n: 12, title: "трек 4", media: [{ kind: "audio", src: F.s2 }] },
      { id: "c13", n: 13, title: "кадр", media: [{ kind: "image", src: F.orig }] }] },
});
const base = `http://127.0.0.1:${srv.port}`;
let checks = 0, failed = 0;
const check = (name, ok, detail = "") => { checks++; if (!ok) { failed++; console.log(`FAIL: ${name} ${detail}`); } };
const until = async (fn, ms = 6000) => { const t0 = Date.now(); for (;;) { const v = await fn(); if (v || Date.now() - t0 > ms) return v; await new Promise((r) => setTimeout(r, 100)); } };
const posts = (pid) => srv.pages.get(pid).posts;
const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 }, colorScheme: "light" });
const shot = (page, name) => page.screenshot({ path: path.join(OUT, name) });
const open = async (pid, page) => {
  page = page || await ctx.newPage();
  page.on("pageerror", (e) => check(`no page error on ${pid}`, false, e.message));
  await page.goto(`${base}/p/${pid}/`);
  return page;
};
const ready = (page) => page.waitForFunction(() => document.querySelectorAll(".pc img[src]").length > 0 && [...document.querySelectorAll(".vp img")].every((i) => i.style.width));
const strong = (page) => page.$eval(".ttl strong", (e) => e.textContent);
const xf = (page) => page.$$eval(".vp img", (ims) => ims.map((i) => i.style.transform + " " + i.style.width));

try {
  // 1. vote: one POST per click with only {choice}; a typed note debounced into one {note}; KeyA as «ф»
  let page = await open("vote1");
  await ready(page);
  await page.click('.votes button[data-v="A"]');
  await until(() => posts("vote1").length >= 1, 2000);
  await page.waitForTimeout(600);
  check("click A → one POST", posts("vote1").length === 1, JSON.stringify(posts("vote1")));
  check("POST carries only {choice:A}", JSON.stringify(posts("vote1")[0]?.fields) === '{"choice":"A"}' && posts("vote1")[0]?.item === "p01" && posts("vote1")[0]?.spec_rev === 1);
  check("auto-advance to the next unvoted", (await strong(page)).startsWith("2"), await strong(page));
  await ready(page);
  await page.type(".side textarea", "halo left", { delay: 60 });
  await page.waitForTimeout(900);
  const typed = posts("vote1").slice(1);
  check("note typing → one POST with only {note}", typed.length === 1 && JSON.stringify(typed[0].fields) === '{"note":"halo left"}' && typed[0].item === "p02", JSON.stringify(typed));
  check("status says saved", /^сохранено \d\d:\d\d$/.test(await page.textContent("#status")), await page.textContent("#status"));
  await page.keyboard.press("Escape");
  check("Esc leaves the note", await page.evaluate(() => document.activeElement.tagName !== "TEXTAREA"));
  await page.evaluate(() => document.body.dispatchEvent(new KeyboardEvent("keydown", { code: "KeyA", key: "ф", bubbles: true })));
  await until(() => posts("vote1").length >= 3, 2000);
  check("KeyA with key «ф» votes A", JSON.stringify(posts("vote1")[2]?.fields) === '{"choice":"A"}' && posts("vote1")[2]?.item === "p02", JSON.stringify(posts("vote1")));
  check("count «2 из 3»", (await page.textContent("#count")) === "2 из 3", await page.textContent("#count"));
  check("suggest shown apart, not counted", (await page.$$eval(".strip i.v", (x) => x.length)) === 2);
  await page.waitForTimeout(500);
  await ready(page);
  check("pixel item: smaller variant drawn over the reference box", await page.$$eval(".vp img", (ims) => ims[1].naturalWidth === 120 && ims[1].style.width === ims[0].style.width));
  check("hotspots computed by block-diff", (await page.waitForFunction(() => document.querySelectorAll(".tools .tools button").length, null, { timeout: 3000 }).catch(() => null)) !== null);
  await page.click("text=←"); await page.click("text=←");
  await ready(page);
  await page.waitForFunction(() => document.querySelectorAll(".tools .tools button").length >= 2);
  const hs = await page.$$eval(".tools .tools button", (b) => b.length);
  check("p01 has ≥2 hotspots (two changed blocks)", hs >= 2, String(hs));
  await shot(page, "compare-vote.png");

  // 2. loupes: drag pans all, wheel zoom keeps the point under the pointer, release outside ends the drag
  const vb = await page.$$eval(".vp", (v) => v.map((e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; }));
  const before = await xf(page);
  await page.mouse.move(vb[1].x + vb[1].w / 2, vb[1].y + vb[1].h / 2);
  await page.mouse.down();
  await page.mouse.move(vb[1].x + vb[1].w / 2 - 60, vb[1].y + vb[1].h / 2 - 30, { steps: 5 });
  await page.mouse.up();
  const after = await xf(page);
  check("drag in one loupe pans all", after[0] !== before[0] && after.every((t) => t === after[0]), JSON.stringify([before, after]));
  const frac = () => page.$eval(".vp:nth-child(3) img", (im, p) => { const r = im.parentNode.getBoundingClientRect(), m = im.style.transform.match(/translate\(([-\d.]+)px, ?([-\d.]+)px\)/);
    return [(p.x - r.x - +m[1]) / parseFloat(im.style.width), (p.y - r.y - +m[2]) / parseFloat(im.style.height), parseFloat(im.style.width)]; }, pt);
  const pt = { x: vb[2].x + vb[2].w * 0.3, y: vb[2].y + vb[2].h * 0.7 };
  await page.mouse.move(pt.x, pt.y);
  const f0 = await frac();
  await page.mouse.wheel(0, -300);
  await page.waitForTimeout(300);
  const f1 = await frac();
  check("wheel zooms in", f1[2] > f0[2] * 1.3, JSON.stringify([f0, f1]));
  check("wheel zoom anchored at the pointer", Math.abs(f1[0] - f0[0]) < 0.002 && Math.abs(f1[1] - f0[1]) < 0.002, JSON.stringify([f0, f1]));
  await shot(page, "loupes-zoomed.png");
  await page.mouse.move(vb[0].x + 100, vb[0].y + 100);
  await page.mouse.down();
  await page.mouse.move(vb[0].x + 60, vb[0].y + 60, { steps: 3 });
  await page.mouse.move(-40, -40, { steps: 3 });
  await page.mouse.up();
  const out1 = await xf(page);
  await page.mouse.move(vb[0].x + 200, vb[0].y + 200, { steps: 4 });
  check("release outside the window ends the drag", JSON.stringify(await xf(page)) === JSON.stringify(out1) && !(await page.evaluate(() => document.body.classList.contains("drag"))));
  await page.mouse.move(vb[0].x + 100, vb[0].y + 100);
  await page.mouse.down();
  await page.mouse.move(vb[0].x + 80, vb[0].y + 80, { steps: 2 });
  await page.evaluate(() => window.dispatchEvent(new Event("blur")));
  const out2 = await xf(page);
  await page.mouse.move(vb[0].x + 20, vb[0].y + 20, { steps: 3 });
  check("window blur mid-drag ends the drag", JSON.stringify(await xf(page)) === JSON.stringify(out2));
  await page.mouse.up();
  const cdp = await ctx.newCDPSession(page);
  await page.mouse.move(vb[0].x + 100, vb[0].y + 100);
  await page.mouse.down();
  await page.mouse.move(vb[0].x + 90, vb[0].y + 90, { steps: 2 });
  for (const d of [0, 30, 60]) await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: vb[0].x + 90 - d, y: vb[0].y + 90, button: "none", buttons: 0 });
  const out3 = await xf(page);
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: vb[0].x + 10, y: vb[0].y + 10, button: "none", buttons: 0 });
  check("a move with no button held ends a drag whose release was lost", JSON.stringify(await xf(page)) === JSON.stringify(out3) && !(await page.evaluate(() => document.body.classList.contains("drag"))));
  await page.mouse.up();
  await page.keyboard.press("Digit0");
  await page.waitForTimeout(100);
  check("0 fits", (await xf(page))[0] !== out3[0]);
  await page.close();

  // 3. outbox: 503 → «не сохранилось», reload keeps the gesture, the server recovering gets it once
  const p2 = srv.pages.get("vote2");
  p2.fail = true;
  page = await open("vote2");
  await ready(page);
  await page.click('.votes button[data-v="B"]');
  await until(async () => (await page.textContent("#status")) === "не сохранилось — повторю", 3000);
  check("503 → status not saved", (await page.textContent("#status")) === "не сохранилось — повторю", await page.textContent("#status"));
  check("gesture kept in the outbox", (await page.evaluate(() => JSON.parse(localStorage.getItem("pages-outbox:vote2") || "[]").length)) === 1);
  await shot(page, "outbox-failed.png");
  await page.reload();
  await ready(page);
  check("after reload a pending vote counts: opens on item 2", (await strong(page)).startsWith("2"), await strong(page));
  await page.click(".strip i:first-child");
  await ready(page);
  check("after reload the pending vote still shows", await page.$eval('.votes button[data-v="B"]', (b) => b.classList.contains("on")));
  await page.type(".side textarea", "x", { delay: 10 });
  await page.reload();
  await ready(page);
  check("a note typed just before reload is in the outbox", (await page.evaluate(() => JSON.parse(localStorage.getItem("pages-outbox:vote2") || "[]").map((p) => Object.keys(p.fields)[0]).join())) === "choice,note");
  p2.fail = false;
  await until(() => p2.items.p01?.note, 8000);
  check("recovered server gets the outbox", p2.items.p01?.choice?.v === "B" && p2.items.p01?.note?.v === "x", JSON.stringify(p2.items));
  check("each gesture applied once", p2.rev === 2, String(p2.rev));
  await until(async () => (await page.evaluate(() => localStorage.getItem("pages-outbox:vote2"))) === null, 3000);
  check("outbox emptied", (await page.evaluate(() => localStorage.getItem("pages-outbox:vote2"))) === null);
  check("status saved after recovery", (await page.textContent("#status")).startsWith("сохранено"));
  await page.close();

  // 4. freshness: a chat `page set` shows within ~5 s; a pending edit survives it; a spec bump keeps the item
  page = await open("vote3");
  await ready(page);
  const t0 = Date.now();
  srv.set("vote3", "p01", { note: "from chat", choice: "unsure" });
  const seen = await until(() => page.$eval(".side textarea", (t) => t.value === "from chat"), 6000);
  check("chat's set shows within ~5 s", seen && Date.now() - t0 < 5500, String(Date.now() - t0));
  check("chat's choice shows", await page.$eval('.votes button[data-v="unsure"]', (b) => b.classList.contains("on")));
  srv.pages.get("vote3").fail = true;
  await page.click("text=→");
  await ready(page);
  await page.click('.votes button[data-v="tie"]');
  await page.waitForTimeout(400);
  if ((await strong(page)).startsWith("3")) { await page.click("text=←"); await ready(page); }
  srv.set("vote3", "p02", { choice: "A" });
  await page.waitForTimeout(4500);
  check("pending edit wins over a newer server value", await page.$eval('.votes button[data-v="tie"]', (b) => b.classList.contains("on")));
  srv.pages.get("vote3").fail = false;
  await until(() => srv.pages.get("vote3").items.p02?.choice?.v === "tie", 6000);
  check("pending edit lands after", srv.pages.get("vote3").items.p02?.choice?.v === "tie");
  srv.bump("vote3", (s) => { s.title = "Калибровка 2"; s.items.push(item("p04", "dog")); });
  await until(async () => (await page.textContent("#title")) === "Калибровка 2", 6000);
  check("spec bump re-renders", (await page.$$eval(".strip i", (x) => x.length)) === 4 && (await page.textContent("#title")) === "Калибровка 2");
  check("spec bump keeps the current item", (await strong(page)).startsWith("2"), await strong(page));
  await page.close();

  // 5. view grid; blind slots
  page = await open("view1");
  await page.waitForSelector(".grid .gc");
  check("view grid has every item", (await page.$$eval(".gc", (x) => x.length)) === 3);
  await page.waitForFunction(() => [...document.querySelectorAll(".gc img")].every((i) => i.complete && i.naturalWidth));
  await shot(page, "view-grid.png");
  await page.click(".gc:nth-child(2)");
  await ready(page);
  check("grid opens an item without a vote widget", (await strong(page)).startsWith("2") && !(await page.$(".votes")));
  await page.keyboard.press("Escape");
  check("Esc returns to the grid", !!(await page.$(".grid")));
  await page.close();
  page = await open("blind1");
  await ready(page);
  const badges = await page.$$eval(".bd span:first-child", (x) => x.map((e) => e.textContent));
  check("blind page shows slots A/B only", JSON.stringify(badges) === '["A","B"]' && !(await page.content()).includes("champ"), JSON.stringify(badges));
  check("pairwise page: two loupes, no original", (await page.$$eval(".vp", (x) => x.length)) === 2);
  await page.click('.votes button[data-v="B"]');
  await until(() => posts("blind1").length, 2000);
  check("blind vote writes the slot letter", posts("blind1")[0]?.fields.choice === "B");
  await shot(page, "blind.png");
  await page.close();

  // 6. cards: choice/multi/scale/note save; one clip at a time
  // integer_zoom + zoom_levels: variants at whole pixels on both axes, digits pick levels, 1 again fits
  page = await open("sq1");
  await ready(page);
  await page.click(".strip i:nth-child(3)");
  await ready(page);
  let r0;
  const sq = () => page.$$eval(".vp img", (ims) => ims.map((i) => [i.naturalWidth, i.naturalHeight, parseFloat(i.style.width), parseFloat(i.style.height), i.style.transform]));
  // a variant larger than the loupe at fit is downscaled, so only magnified ones must be whole
  const whole = (r) => r.slice(1).every(([nw, nh, w, hh, t]) => w < nw || (w % nw === 0 && w / nw === hh / nh && /translate\(-?\d+px, ?-?\d+px\)/.test(t)));
  r0 = await sq();
  check("integer_zoom: fitted 4 px variant at whole pixels", whole(r0) && r0[1][2] > r0[1][0], JSON.stringify(r0));
  await page.keyboard.press("Digit2");
  let r = await sq();
  check("Digit2 → original at 2x, 4 px variant at 8x", r[0][2] === 960 && r[1][2] === 960 && whole(r) && await page.$eval(".tools button.on", (b) => b.textContent) === "2×", JSON.stringify(r));
  await page.keyboard.press("Digit1");
  check("Digit1 → original at 1x", (await sq())[0][2] === 480);
  await page.keyboard.press("Digit1");
  r = await sq();
  check("Digit1 again fits", r[0][2] !== 480 && whole(r) && !(await page.$(".tools button.on")), JSON.stringify(r));
  await page.mouse.move(700, 600); await page.mouse.wheel(0, -137); await page.waitForTimeout(200);
  check("wheel zoom keeps whole pixels", whole(await sq()), JSON.stringify(await sq()));
  await shot(page, "compare-integer.png");
  await page.close();

  page = await open("cards1");
  await page.waitForSelector(".card");
  const c = '.card[data-id="c11"]';
  await page.click(`${c} .row[data-f="heard"] button[data-v="1"]`);
  await page.click(`${c} .row[data-f="kind"] button[data-v="click"]`);
  await page.click(`${c} .row[data-f="kind"] button[data-v="gap"]`);
  await page.click(`${c} .row[data-f="score"] button[data-v="7"]`);
  await page.type(`${c} > textarea`, "щелчок", { delay: 30 });
  await until(() => posts("cards1").length >= 5, 3000);
  check("cards save changed fields only", JSON.stringify(posts("cards1").map((p) => p.fields)) === JSON.stringify([{ heard: "1" }, { kind: ["click"] }, { kind: ["click", "gap"] }, { score: 7 }, { note: "щелчок" }]), JSON.stringify(posts("cards1")));
  check("card done turns its number", await page.$eval(c, (e) => e.classList.contains("done")));
  check("cards count «1 из 3»", (await page.textContent("#count")) === "1 из 3", await page.textContent("#count"));
  check("suggest shown apart", (await page.$eval(`${c} .sg`, (e) => getComputedStyle(e, "::before").content + e.textContent)).includes("слышно слышу"));
  await page.click('.card[data-id="c12"] h2');
  await page.keyboard.press("Digit1");
  await until(() => posts("cards1").length >= 6, 2000);
  check("option key acts on the card most visible", posts("cards1")[5]?.item === "c12" && posts("cards1")[5]?.fields.heard === "0", JSON.stringify(posts("cards1")[5]));
  await page.waitForFunction(() => [...document.querySelectorAll("audio")].every((a) => a.getAttribute("src")));
  const play = await page.evaluate(async () => {
    const [a, b] = document.querySelectorAll("audio");
    await a.play(); const first = !a.paused;
    await b.play(); await new Promise((r) => setTimeout(r, 100));
    return [first, a.paused, b.paused];
  });
  check("starting one clip pauses the other", JSON.stringify(play) === "[true,true,false]", JSON.stringify(play));
  await page.evaluate(() => scrollTo(0, 0));
  await shot(page, "cards.png");
  await page.close();

  const dark = await browser.newContext({ viewport: { width: 1400, height: 900 }, colorScheme: "dark" });
  page = await dark.newPage();
  await page.goto(`${base}/p/vote4/`);
  await ready(page);
  await shot(page, "compare-dark.png");
} catch (e) {
  check("run", false, e.stack);
} finally {
  await browser.close();
  srv.close();
  fs.rmSync(tmp, { recursive: true, force: true });
}
if (failed) process.exit(1);
console.log(`PASS: ${checks} checks; compare vote/loupes/outbox/freshness/view/blind/integer, cards; screenshots in ${path.relative(process.cwd(), OUT)}`);
