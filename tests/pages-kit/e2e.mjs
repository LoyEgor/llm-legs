// The real `bin/page serve` + the real kit, end to end: pages made with `page new`, voted in headless
// Chromium, read back with `page state`, a chat's `page set` seen by the open page. A temp PAGES_DIR
// and port 0 only. Arguments: playwright-core directories to try in order. Exit 0 PASS, 1 FAIL, 3 no
// browser could start (the suite skips).
import { spawn, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
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
  PAGES_KIT_DIR: path.join(ROOT, "share/pages/kit"), CLAUDE_CODE_SESSION_ID: "chat-e2e" };
delete env.CLAUDE_LAUNCHER_SESSION;
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
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(failed ? `FAIL: ${failed} of ${checks} end-to-end checks` : `PASS: ${checks} end-to-end checks`);
process.exit(failed ? 1 : 0);
