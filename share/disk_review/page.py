#!/usr/bin/env python3
"""Disk review page (docs/disk-review.md): items.json in, one local HTML page with a checkbox per item, opened in Dia
(an open page reloads in place).

  page.py ITEMS.json

ITEMS.json, written by the review chat:
  {"items": [{"id", "group": "mac"|"work", "title", "why", "owner", "last", "risk"?, "checked": bool,
              "action": "trash" | "move:<dir on Work>" | "ui:<App>", "paths": [...], "gb"?: number}],
   "big":   [{"group", "title", "owner", "note", "tag"?, "path"? | "kids"?: [[name, gb]], "gb"?}]}
Sizes come from the scan maps (scan.py); "gb" only where no path can be measured (an in-app setting).
A path in the decisions ledger (apply.py) marked keep moves its item to the "decided keep" section, unticked.
"""
import datetime
import html
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan  # noqa: E402

OUT = os.path.join(os.environ.get("DISK_REVIEW_DIR") or os.path.join(scan.HOME, ".cache", "disk-review"), "page")
LEDGER = os.environ.get("DISK_REVIEW_LEDGER") or os.path.join(scan.HOME, ".local", "share", "disk-review", "decisions.json")
DISKS = {"mac": "/", "work": scan.WORK}
E = html.escape


def ledger():
    try:
        with open(LEDGER) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def gb_of(paths):
    return round(sum(scan.size_kb(p) for p in paths) / scan.GIB, 2)


def resolve(spec):
    decisions = ledger()
    items = []
    for i in spec.get("items", []):
        i = dict(i)
        i["paths"] = [os.path.expanduser(p) for p in i.get("paths", [])]
        i["gb"] = gb_of(i["paths"]) or float(i.get("gb") or 0)
        marks = {decisions.get(p, {}).get("decision") for p in i["paths"]}
        i["decided"] = "keep" if i["paths"] and marks == {"keep"} else ("yes" if "yes" in marks else None)
        if i["decided"] == "keep":
            i["checked"] = False
        items.append(i)
    big = []
    for b in spec.get("big", []):
        b = dict(b)
        if b.get("path"):
            path = os.path.expanduser(b["path"])
            b["gb"] = round(scan.size_kb(path) / scan.GIB, 1)
            b.setdefault("kids", [[os.path.basename(p), round(v / scan.GIB, 2)] for v, p in scan.kids(path, 8, 102400)])
        big.append(b)
    disks = {}
    for g, mount in DISKS.items():
        try:
            st = os.statvfs(mount)
        except OSError:
            continue
        total, free = st.f_blocks * st.f_frsize / 2**30, st.f_bavail * st.f_frsize / 2**30
        disks[g] = {"total": round(total, 1), "free": round(free, 1), "used": round(total - free, 1)}
    return {"items": items, "big": big, "disks": disks}


def gb(x):
    return (f"{x:.1f}" if x >= 1 else f"{x:.2f}").replace(".", ",")


def kind(action):
    if action.startswith("move:"):
        return "Перенести на Work", "move"
    if action.startswith("ui:"):
        return "Настрою в приложении", "ui"
    return "В корзину", "trash"


def item_row(i):
    label, cls = kind(i.get("action", "trash"))
    dec = {"yes": '<span class="dec yes">ты: да</span>', "keep": '<span class="dec keep">ты: оставить</span>'}.get(
        i["decided"], '<span class="dec mine">мой совет — решай</span>')
    risk = f'<span class="risk">риск: {E(i["risk"])}</span>' if i.get("risk") else ""
    return f'''<label class="item" data-gb="{i['gb']}" data-act="{cls}" data-g="{E(i['group'])}">
  <input type="checkbox" data-id="{E(i['id'])}" data-default="{int(bool(i.get('checked')))}" {"checked" if i.get("checked") else ""}>
  <div class="body">
    <div class="top"><span class="title">{E(i['title'])}</span><span class="gb">{gb(i['gb'])} ГБ</span></div>
    <div class="why">{E(i.get('why', ''))}</div>
    <div class="owner">чьё: {E(i.get('owner', '—'))}</div>
    <div class="meta"><span class="badge {cls}">{label}</span>{dec}<span>последний раз: {E(i.get('last', '—'))}</span>{risk}</div>
  </div>
</label>'''


def big_row(b):
    kids = "".join(f'<li><span>{E(str(k))}</span><span class="gb">{gb(v)} ГБ</span></li>' for k, v in b.get("kids", []))
    tag = f' <span class="dec keep">{E(b["tag"])}</span>' if b.get("tag") else ""
    return f'''<details class="kp"><summary><span class="title">{E(b['title'])}{tag}</span><span class="gb">{gb(float(b.get('gb') or 0))} ГБ</span></summary>
<div class="why">{E(b.get('note', ''))}</div><div class="owner">чьё: {E(b.get('owner', '—'))}</div><ul class="kids">{kids}</ul></details>'''


def disk(g, name, d):
    return f'''<div class="disk" data-g="{g}" data-total="{d['total']}" data-used="{d['used']}" data-free="{d['free']}">
  <div class="dh"><b>{E(name)}</b><span>{gb(d['total'])} ГБ</span></div>
  <div class="track"><i class="s-used"></i><i class="s-freed"></i><i class="s-in"></i><i class="s-free"></i></div>
  <div class="legend"><span><i class="k used"></i>занято <b class="v-used"></b></span><span><i class="k freed"></i>освободится <b class="v-freed"></b></span><span class="in-wrap"><i class="k in"></i>приедет с Mac <b class="v-in"></b></span><span><i class="k free"></i>свободно <b class="v-free"></b> → <b class="v-after"></b></span></div>
</div>'''


CSS = """
:root{--bg:#f6f5f2;--card:#fff;--ink:#1d1d1b;--mute:#6b6a66;--line:#e4e2dc;--acc:#2f6f4f;--trash:#a3412b;--move:#2c5d8f;--ui:#7a5a9e;--mid:#9a6a00;--used:#8e8d88;--freed:#3d9a6a;--free:#e9e7e1}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--card:#21201e;--ink:#ecebe7;--mute:#9b9a95;--line:#34332f;--acc:#6fbf94;--trash:#e08a72;--move:#7fb0e0;--ui:#b9a0dc;--mid:#e0b250;--used:#77766f;--freed:#5fbf8a;--free:#34332f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:28px 16px 120px}
h1{font-size:26px;margin:0 0 6px}.lead{color:var(--mute);margin:0 0 18px}
.disks{display:grid;gap:12px;margin-bottom:8px}
.disk{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.dh{display:flex;justify-content:space-between;margin-bottom:8px}.dh span{color:var(--mute)}
.track{display:flex;height:22px;border-radius:6px;overflow:hidden;background:var(--free)}
.track i{display:block;height:100%;transition:width .25s}
.s-used{background:var(--used)}.s-freed{background:repeating-linear-gradient(135deg,var(--freed) 0 6px,color-mix(in srgb,var(--freed) 70%,transparent) 6px 12px)}
.s-in{background:var(--move)}.s-free{background:var(--free)}
.legend{display:flex;flex-wrap:wrap;gap:4px 16px;margin-top:8px;font-size:13px;color:var(--mute)}.legend b{color:var(--ink);font-variant-numeric:tabular-nums}
.k{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:5px;vertical-align:-1px}.k.used{background:var(--used)}.k.freed{background:var(--freed)}.k.in{background:var(--move)}.k.free{background:var(--free);border:1px solid var(--line)}
.disk:not(.has-in) .in-wrap{display:none}
.group{margin:26px 0}.group header{display:flex;justify-content:space-between;align-items:baseline;gap:12px;border-bottom:2px solid var(--ink);padding-bottom:6px}
h2{font-size:19px;margin:0}.gsum{color:var(--mute);white-space:nowrap}.gsum b{color:var(--ink)}.sub{color:var(--mute);margin:8px 0 10px;font-size:14px}
.item{display:flex;gap:12px;align-items:flex-start;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin:8px 0;cursor:pointer}
.item:has(input:checked){border-color:var(--acc);box-shadow:inset 3px 0 0 var(--acc)}
.item input{width:20px;height:20px;margin-top:2px;accent-color:var(--acc);flex:none}
.body{flex:1;min-width:0}.top{display:flex;justify-content:space-between;gap:10px}.title{font-weight:600}
.gb{font-variant-numeric:tabular-nums;font-weight:600;white-space:nowrap}
.why{color:var(--mute);font-size:14px;margin-top:3px}.owner{font-size:13px;margin-top:4px}
.meta{display:flex;flex-wrap:wrap;gap:6px 12px;font-size:12.5px;color:var(--mute);margin-top:7px;align-items:center}
.badge{font-weight:600;padding:1px 7px;border-radius:5px;border:1px solid currentColor}.badge.trash{color:var(--trash)}.badge.move{color:var(--move)}.badge.ui{color:var(--ui)}
.dec{padding:1px 7px;border-radius:5px;font-weight:600}.dec.yes{background:color-mix(in srgb,var(--acc) 18%,transparent);color:var(--acc)}.dec.keep{background:color-mix(in srgb,var(--move) 18%,transparent);color:var(--move)}.dec.mine{font-weight:500;font-style:italic}
.risk{color:var(--mid)}
.kp{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 14px;margin:8px 0}
.kp summary{display:flex;justify-content:space-between;gap:10px;cursor:pointer;list-style:none}.kp summary::-webkit-details-marker{display:none}
.kp summary .title::before{content:"▸ ";color:var(--mute)}.kp[open] summary .title::before{content:"▾ "}
ul.kids{list-style:none;padding:0;margin:8px 0 2px;font-size:13.5px}ul.kids li{display:flex;justify-content:space-between;gap:10px;padding:3px 0;border-bottom:1px dashed var(--line)}ul.kids .gb{font-weight:500}
footer{position:fixed;left:0;right:0;bottom:0;background:var(--card);border-top:1px solid var(--line);padding:12px 16px}
.bar{max-width:860px;margin:0 auto;display:flex;gap:14px;align-items:center;justify-content:space-between;flex-wrap:wrap}
.tot{font-size:15px}.tot b{font-size:18px;font-variant-numeric:tabular-nums}
button{font:inherit;font-weight:600;background:var(--acc);color:#fff;border:0;border-radius:8px;padding:10px 18px;cursor:pointer}
button.ghost{background:transparent;color:var(--ink);border:1px solid var(--line);font-weight:500}
.done-msg{display:none;color:var(--acc);font-weight:600}body.done .done-msg{display:block}
@media (max-width:560px){.top{flex-direction:column;gap:2px}}
"""

# Ticks persist per page generation; both on and off ids are stored, so an item added later keeps its default.
JS = """
const boxes=[...document.querySelectorAll('input[type=checkbox]')];
const fmt=x=>(x>=1?x.toFixed(1):x.toFixed(2)).replace('.',',');
try{const s=JSON.parse(localStorage.getItem(KEY)||'null');if(s){boxes.forEach(b=>{if(s.on.includes(b.dataset.id))b.checked=true;else if(s.off.includes(b.dataset.id))b.checked=false});if(s.done)document.body.classList.add('done')}}catch(e){}
function sum(){const fr={mac:0,work:0},inc={mac:0,work:0};
document.querySelectorAll('.item').forEach(it=>{if(!it.querySelector('input').checked)return;const v=+it.dataset.gb,g=it.dataset.g;fr[g]=(fr[g]||0)+v;if(it.dataset.act==='move')inc.work+=v});
document.querySelectorAll('.group[data-group]').forEach(s=>{let t=0;s.querySelectorAll('.item').forEach(it=>{if(it.querySelector('input').checked)t+=+it.dataset.gb});s.querySelector('.sel').textContent=fmt(t)});
document.querySelectorAll('.disk').forEach(d=>{const g=d.dataset.g,T=+d.dataset.total,U=+d.dataset.used,F=+d.dataset.free,f=Math.min(fr[g]||0,U),n=inc[g]||0;
const pc=x=>(100*x/T)+'%';d.querySelector('.s-used').style.width=pc(U-f);d.querySelector('.s-freed').style.width=pc(f);d.querySelector('.s-in').style.width=pc(n);d.querySelector('.s-free').style.width=pc(Math.max(F-n,0));
d.classList.toggle('has-in',n>0);d.querySelector('.v-used').textContent=fmt(U)+' ГБ';d.querySelector('.v-freed').textContent=fmt(f)+' ГБ';d.querySelector('.v-in').textContent=fmt(n)+' ГБ';
d.querySelector('.v-free').textContent=fmt(F)+' ГБ';d.querySelector('.v-after').textContent=fmt(F+f-n)+' ГБ'});
document.getElementById('t-mac').textContent=fmt(fr.mac);document.getElementById('t-work').textContent=fmt(fr.work)}
function save(done){const on=boxes.filter(b=>b.checked).map(b=>b.dataset.id),off=boxes.filter(b=>!b.checked).map(b=>b.dataset.id);try{localStorage.setItem(KEY,JSON.stringify({on,off,done:!!done}))}catch(e){}}
boxes.forEach(b=>b.addEventListener('change',()=>{document.body.classList.remove('done');sum();save(false)}));
document.getElementById('none').onclick=()=>{boxes.forEach(b=>b.checked=false);document.body.classList.remove('done');sum();save(false)};
document.getElementById('go').onclick=()=>{document.body.classList.add('done');save(true)};
sum();
"""


def render(data, key):
    items, disks = data["items"], data["disks"]
    groups = [("mac", "Системный диск Mac"), ("work", "Внешний диск Work")]
    sections = []
    for g, name in groups:
        rows = sorted((i for i in items if i["group"] == g and i["decided"] != "keep"), key=lambda i: -i["gb"])
        if rows:
            sections.append(f'''<section class="group" data-group="{g}">
  <header><h2>{E(name)}</h2><div class="gsum"><b class="sel">0</b> ГБ выбрано</div></header>
  {"".join(item_row(i) for i in rows)}
</section>''')
    kept = [i for i in items if i["decided"] == "keep"]
    if kept:
        sections.append(f'<section class="group"><header><h2>Решено оставить — можно передумать</h2></header>'
                        f'{"".join(item_row(i) for i in sorted(kept, key=lambda i: -i["gb"]))}</section>')
    for g, name in (("mac", "Крупное — Mac"), ("work", "Крупное — Work")):
        rows = sorted((b for b in data["big"] if b.get("group") == g), key=lambda b: -float(b.get("gb") or 0))
        if rows:
            sections.append(f'<section class="group"><header><h2>{name}</h2></header>'
                            f'<p class="sub">Нажми на строку — раскроются главные папки.</p>{"".join(big_row(b) for b in rows)}</section>')
    bars = "".join(disk(g, n, disks[g]) for g, n in (("mac", "Mac — системный диск"), ("work", "Work — внешний диск")) if g in disks)
    return f'''<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Уборка диска</title><style>{CSS}</style></head><body><main>
<h1>Уборка диска</h1>
<p class="lead">Галочки стоят там, где ты сказал «да» или где я советую. Всё уходит в Корзину — пока не очистишь её, любой пункт можно вернуть.</p>
<div class="disks">{bars}</div>
{"".join(sections)}
</main>
<footer><div class="bar"><div class="tot">Освободится: <b id="t-mac">0</b> ГБ на Mac · <span id="t-work">0</span> ГБ на Work<div class="done-msg">Принято — напиши в чат «готово».</div></div>
<div><button class="ghost" id="none">Снять всё</button> <button id="go">Готово</button></div></div></footer>
<script>const KEY={json.dumps(key)};{JS}</script></body></html>'''


def show(path):
    """Reload the open page in Dia, or open it."""
    r = subprocess.run(["dia-js", "--url-contains", "disk-review.html"], input="location.reload(); 'ok'",
                       capture_output=True, text=True)
    if r.returncode != 0 or "ok" not in r.stdout:
        subprocess.run(["open", "-a", "Dia", path])


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(sys.argv[1]) as f:
        data = resolve(json.load(f))
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "items.json"), "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    page = os.path.join(OUT, "disk-review.html")
    with open(page, "w") as f:
        f.write(render(data, "disk-review-" + datetime.date.today().isoformat()))
    for i in sorted(data["items"], key=lambda i: -i["gb"]):
        print(f"{i['gb']:7.2f}  {i['group']:4}  {'x' if i.get('checked') else ' '}  {i['decided'] or '-':4}  {i['id']}")
    if os.environ.get("DISK_REVIEW_NO_OPEN") != "1":
        show(page)
    print(page)
    return 0


if __name__ == "__main__":
    sys.exit(main())
