"""Combines the design direction mockups in dist/design/ into one self-contained page,
dist/design-directions.html, with a switcher for direction, screen and light or dark.

    python3 scripts/design/build_compare.py

Each mockup is embedded as an iframe document (same origin as the page, so it reads the shared photo
data from the parent) and is drawn at a fixed 1440 x 900 window, scaled to fit.
"""
import json, os, re

here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = os.path.join(here, "dist", "design")
DIRECTIONS = [
    ("glass-workspace", "Glass workspace", "Floating translucent sidebar and toolbar, photos edge to edge. Closest to the current Photos app."),
    ("focus-review", "Focus review", "One group fills the window. Built for going through groups fast with the keyboard."),
    ("gallery-wall", "Gallery wall", "No sidebar. Trips and events as large photo stories; the review slides over them."),
    ("command-deck", "Command deck", "A precise pro tool: three panes, an inspector and a command palette."),
]

mocks = {}
for slug, _, _ in DIRECTIONS:
    path = os.path.join(src, slug + ".html")
    if os.path.exists(path):
        html = open(path).read()
        # The parent page carries the data once; the mockup reads window.parent.DATA.
        html, n = re.subn(r"<script\s+src=[\"']data\.js[\"']\s*>\s*</script>", "", html)
        assert n == 1, f"{slug}: expected exactly one data.js script tag, found {n}"
        mocks[slug] = html
data_js = open(os.path.join(src, "data.js")).read()


def js(value):
    """JSON that is safe inside a <script> element."""
    return json.dumps(value).replace("</", "<\\/")


page = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Photo Cleanup - design directions</title>
<style>
  :root { --bg: #f1f2f5; --bar: #ffffff; --text: #14171d; --muted: #5b6472; --line: #dfe3ea; --on: #14171d; --on-text: #ffffff; --hover: #e9ecf1; }
  :root[data-theme="dark"] { --bg: #08090c; --bar: #14161b; --text: #eceef2; --muted: #9aa3b0; --line: #262a33; --on: #eceef2; --on-text: #14171d; --hover: #20242c; }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body { display: flex; flex-direction: column; background: var(--bg); color: var(--text);
         font: 13px/1.4 -apple-system, "SF Pro Text", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
  header { display: flex; flex-wrap: wrap; align-items: center; gap: 10px 22px; padding: 10px 16px; background: var(--bar); border-bottom: 1px solid var(--line); }
  .set { display: flex; align-items: center; gap: 4px; }
  .set > span { color: var(--muted); margin-right: 6px; }
  button { font: inherit; font-weight: 550; color: var(--text); background: transparent; border: 0; border-radius: 7px; padding: 6px 11px; cursor: pointer; }
  button:hover { background: var(--hover); }
  button[aria-pressed="true"] { background: var(--on); color: var(--on-text); }
  #about { flex: 1 1 260px; color: var(--muted); min-width: 0; }
  #about b { color: var(--text); font-weight: 600; }
  main { flex: 1; min-height: 0; position: relative; overflow: hidden; }
  #stage { position: absolute; left: 50%; top: 50%; width: 1440px; height: 900px; transform-origin: center; border-radius: 12px; overflow: hidden;
           box-shadow: 0 24px 80px rgba(0, 0, 0, 0.28), 0 0 0 1px rgba(0, 0, 0, 0.12); background: #000; }
  iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; visibility: hidden; }
  iframe.on { visibility: visible; }
  #missing { position: absolute; inset: 0; display: none; align-items: center; justify-content: center; color: #9aa3b0; font-size: 15px; }
</style>
</head>
<body>
<header>
  <div class="set" id="directions"><span>Direction</span></div>
  <div class="set" id="screens"><span>Screen</span></div>
  <div class="set" id="themes"><span>Appearance</span></div>
  <div id="about"></div>
</header>
<main><div id="stage"><div id="missing">This direction has not been built.</div></div></main>
<script>__DATA__</script>
<script>
const DIRECTIONS = __DIRECTIONS__;
const MOCKS = __MOCKS__;
const SCREENS = [["home", "Home"], ["library", "Folder"], ["review", "Review"]];
const state = { direction: DIRECTIONS.find((d) => MOCKS[d[0]])?.[0] || DIRECTIONS[0][0], screen: "home",
                theme: matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light" };
const frames = {};
const stage = document.getElementById("stage");

function apply(frame) {
  const w = frame.contentWindow;
  try { w.setTheme && w.setTheme(state.theme); w.showScreen && w.showScreen(state.screen); } catch (e) { console.warn(e); }
}

function frameFor(slug) {
  if (frames[slug] || !MOCKS[slug]) return frames[slug];
  const f = document.createElement("iframe");
  f.title = slug;
  f.addEventListener("load", () => { f.dataset.ready = "1"; apply(f); });
  f.srcdoc = MOCKS[slug];
  stage.appendChild(f);
  return (frames[slug] = f);
}

function render() {
  document.documentElement.dataset.theme = state.theme;
  for (const [id, key] of [["directions", "direction"], ["screens", "screen"], ["themes", "theme"]]) {
    for (const b of document.querySelectorAll("#" + id + " button")) b.setAttribute("aria-pressed", String(b.dataset.value === state[key]));
  }
  const d = DIRECTIONS.find((x) => x[0] === state.direction);
  document.getElementById("about").innerHTML = "<b>" + d[1] + ".</b> " + d[2];
  const current = frameFor(state.direction);
  for (const f of Object.values(frames)) f.classList.toggle("on", f === current);
  document.getElementById("missing").style.display = current ? "none" : "flex";
  if (current && current.dataset.ready) { apply(current); current.contentWindow.focus(); }
}

function add(id, key, items) {
  const set = document.getElementById(id);
  for (const [value, label] of items) {
    const b = document.createElement("button");
    b.textContent = label;
    b.dataset.value = value;
    b.onclick = () => { state[key] = value; render(); };
    set.appendChild(b);
  }
}
add("directions", "direction", DIRECTIONS.map((d) => [d[0], d[1]]));
add("screens", "screen", SCREENS);
add("themes", "theme", [["light", "Light"], ["dark", "Dark"]]);

// The mockups are drawn as a 1440 x 900 window and scaled to whatever room there is.
function fit() {
  const m = document.querySelector("main").getBoundingClientRect();
  const s = Math.min((m.width - 32) / 1440, (m.height - 32) / 900);
  stage.style.transform = "translate(-50%, -50%) scale(" + s + ")";
}
addEventListener("resize", fit);
fit();
render();
</script>
</body>
</html>
"""
page = page.replace("__DIRECTIONS__", js([list(d) for d in DIRECTIONS])).replace("__MOCKS__", js(mocks)).replace("__DATA__", data_js.replace("</", "<\\/"))
out = os.path.join(here, "dist", "design-directions.html")
open(out, "w").write(page)
print(f"{out}: {len(mocks)} of {len(DIRECTIONS)} directions, {os.path.getsize(out) / 1e6:.1f} MB; missing: {[d[0] for d in DIRECTIONS if d[0] not in mocks]}")
