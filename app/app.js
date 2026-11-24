"use strict";

/* ---------- tiny DOM helpers ---------- */

const $ = (s) => document.querySelector(s);

function el(tag, cls, ...kids) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  e.append(...kids.filter((k) => k != null && k !== false));
  return e;
}

// Inline icons (24px grid, drawn with strokes) so nothing is loaded from outside.
const ICONS = {
  star: '<path d="M12 3.6l2.6 5.3 5.8.8-4.2 4.1 1 5.8-5.2-2.8-5.2 2.8 1-5.8-4.2-4.1 5.8-.8z" fill="currentColor" stroke-width="1.5"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  x: '<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>',
  menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
  prev: '<path d="M15 5l-7 7 7 7"/>',
  next: '<path d="M9 5l7 7-7 7"/>',
  arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  overview: '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
  trip: '<path d="M3 19l6.5-11 4 6.5 2.5-3.5 5 8z"/>',
  daytrip: '<circle cx="12" cy="12" r="3.5"/><path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.4 1.4M16.6 16.6L18 18M18 6l-1.4 1.4M7.4 16.6L6 18"/>',
  event: '<rect x="4" y="5.5" width="16" height="14" rx="2"/><path d="M4 10h16M8.5 3.5v4M15.5 3.5v4"/>',
  everyday: '<path d="M4 11l8-7 8 7"/><path d="M6 9.5V20h12V9.5"/>',
  merge: '<path d="M6 4v5a5 5 0 005 5h7"/><path d="M6 20v-5"/><path d="M15 10.5l3.5 3.5-3.5 3.5"/>',
  split: '<path d="M12 20v-7"/><path d="M12 13L6 6M12 13l6-7"/><path d="M6 10V6h4M18 10V6h-4"/>',
  folder: '<path d="M3.5 7.5a2 2 0 012-2h4l2 2.5h7a2 2 0 012 2v7.5a2 2 0 01-2 2h-13a2 2 0 01-2-2z"/>',
  undo: '<path d="M9 14l-5-5 5-5"/><path d="M4 9h10a6 6 0 010 12h-3"/>',
  more: '<circle cx="5.5" cy="12" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="18.5" cy="12" r="1.3" fill="currentColor"/>',
  chev: '<path d="M6 9l6 6 6-6"/>',
  pencil: '<path d="M4 20h4L19 9a2.8 2.8 0 00-4-4L4 16z"/><path d="M13.5 6.5l4 4"/>',
  trash: '<path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13"/>',
  warn: '<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17.2v.1"/>',
};

function icon(name, size = 16) {
  const t = document.createElement("template");
  t.innerHTML = `<svg class="ico" width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
  return t.content.firstChild;
}

const plural = (n, word, many = word + "s") => `${n.toLocaleString()} ${n === 1 ? word : many}`;

/* ---------- constants ---------- */

const STATES = ["fav", "keep", "remove"];
const STATE_LABEL = { fav: "Favorite", keep: "Keep", remove: "Remove" };
const STATE_ICON = { fav: "star", keep: "check", remove: "x" };
const STATE_KEY = { fav: "F", keep: "K", remove: "X" };
const KEY_STATE = { f: "fav", k: "keep", x: "remove", u: null };
const GROUP_KIND = { duplicate: "Duplicates", "near-duplicate": "Near-duplicates", similar: "Similar shots" };
const COLLECTION_KIND = { trip: "Trip", daytrip: "Day trip", event: "Event", everyday: "Everyday" };
const NOT_KIND = { trip: "Not a trip", daytrip: "Not a day trip", event: "Not an event" };

// Library-wide views. Each one lists either groups or single photos.
const LIBRARY = [
  { id: "all", label: "All photos", hint: "Every photo in the folder, oldest first.",
    photos: () => S.order },
  { id: "you", label: "Photos of you", hint: "Photos your face was recognized in. These are kept unless a better shot of the same moment exists.",
    photos: () => S.order.filter((id) => S.photos[id].me),
    empty: "No photos of you yet. Run faces.py with a photo of you, then regroup." },
  { id: "groups", label: "Cleanup groups", hint: "Every set of near-identical shots, across all trips and events.",
    groups: () => S.groups, empty: "No near-identical photos were found." },
  { id: "close", label: "Close calls", hint: "Groups where the favorite was hard to pick. Worth a second look.",
    groups: () => S.groups.filter((g) => g.close), empty: "No close calls. Every group has a clear favorite." },
  { id: "singles", label: "Singles", hint: "Photos that are not part of any group.",
    photos: () => S.order.filter((id) => !S.photos[id].group), empty: "Every photo belongs to a group." },
  { id: "favs", label: "Favorites", hint: "The best shot of each group, plus anything you starred.",
    photos: () => S.order.filter((id) => eff(id) === "fav"), empty: "No favorites yet. Press F on a photo to star it." },
  { id: "remove", label: "Marked remove", hint: "Everything that will be moved to _to_remove.",
    photos: () => S.order.filter((id) => eff(id) === "remove"), empty: "Nothing is marked for removal." },
  { id: "blurry", label: "Blurry", hint: "Photos that look out of focus.",
    photos: () => S.order.filter((id) => S.photos[id].tags.includes("blurry")), empty: "No blurry photos found." },
  { id: "utility", label: "Screenshots & docs", hint: "Screenshots, receipts, documents and similar.",
    photos: () => S.order.filter((id) => S.photos[id].tags.includes("utility")), empty: "No screenshots or documents found." },
];
const LIBRARY_BY_ID = Object.fromEntries(LIBRARY.map((v) => [v.id, v]));

const CHUNK = 240;  // tiles rendered per batch

const S = {
  root: "", photos: {}, order: [], groups: [], groupById: {},
  collections: [], colById: {}, newestFirst: [],
  decisions: {}, haiku: {}, moved: new Set(), filed: {}, reviewed: new Set(),
  total: null, stats: new Map(),
  route: "organize", view: null, rendered: 0, lastDay: null, wrap: null,
  cursor: null, nextId: null, renaming: false, navRefs: new Map(),
  lb: null, saving: Promise.resolve(), pending: 0,
  sel: new Set(), selFrom: null, colSel: new Set(), expanded: new Set(), dupTitles: new Set(),
  finish: null,  // the confirm step on the Finish page: a step ("organize", "dups", "cleanup"), "undo-" + step, or null
};

/* ---------- decisions ---------- */

const suggestion = (id) => (S.haiku[id] && S.haiku[id].state) || S.photos[id].auto;
const eff = (id) => S.decisions[id] || suggestion(id);
const source = (id) => (S.decisions[id] ? "you" : S.haiku[id] && S.haiku[id].state ? "haiku" : "auto");
const live = (id) => !S.moved.has(id);
const groupDone = (g) => g.members.every((id) => S.reviewed.has(id));

function setStates(changes) {
  const body = {};
  for (const [id, state] of Object.entries(changes)) {
    const value = state && state !== suggestion(id) ? state : null;
    if (value) S.decisions[id] = value; else delete S.decisions[id];
    body[id] = value;
  }
  for (const id of Object.keys(changes)) refreshPhoto(id);
  refreshCounts();
  save("/api/decide", { changes: body });
}

function setReviewed(g, on) {
  for (const id of g.members) if (on) S.reviewed.add(id); else S.reviewed.delete(id);
  S.expanded.delete(g.id);  // marking reviewed folds the group away
  updateNext();
  refreshGroup(g.id);
  refreshCounts();
  save("/api/reviewed", { ids: g.members, reviewed: on });
}

async function post(url, body) {
  const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
  if (!r.ok) {
    const err = await r.json().catch(() => null);  // the server explains what went wrong when it can
    throw new Error((err && err.error) || "HTTP " + r.status);
  }
  return r.json();
}

// Saves run one after another so a slow request can never overwrite a newer one.
function save(url, body) {
  S.pending++;
  setSave("Saving…", "busy");
  S.saving = S.saving
    .then(() => post(url, body))
    .then(() => { if (--S.pending === 0) setSave("Saved", "ok"); })
    .catch((e) => {
      S.pending--;
      setSave("Not saved", "err");
      toast("Could not save your change (" + e.message + "). Is the server still running?", true);
    });
}

function setSave(text, kind) {
  const s = $("#save");
  s.textContent = text;
  s.className = "save " + kind;
}

/* ---------- formatting ---------- */

const zone = (known) => (known ? { timeZone: "UTC" } : {});
const fmtDate = (sec, known, opts) => new Date(sec * 1000).toLocaleDateString(undefined, { ...opts, ...zone(known) });

function fmtTime(p, withDate = true) {
  // EXIF capture times are wall-clock values stored as if UTC; file times are real instants.
  const opts = { hour: "numeric", minute: "2-digit", second: "2-digit", ...zone(p.timeKnown) };
  if (withDate) Object.assign(opts, { year: "numeric", month: "short", day: "numeric" });
  return new Date(p.time * 1000).toLocaleString(undefined, opts);
}
const fmtDay = (p) => fmtDate(p.time, p.timeKnown, { weekday: "short", year: "numeric", month: "long", day: "numeric" });

function fmtBytes(n) {
  if (n >= 1e9) return (n / 1e9).toFixed(1) + " GB";
  if (n >= 1e6) return (n / 1e6).toFixed(1) + " MB";
  return Math.round(n / 1e3) + " KB";
}
const baseName = (rel) => rel.split("/").pop();
const faceText = (p) => (p.faces ? plural(p.faces, "face") : "");

/* ---------- collections ---------- */

function fmtRange(c, withYear) {
  const opts = { month: "short", day: "numeric", ...zone(c.timeKnown) };
  if (withYear) opts.year = "numeric";
  const f = new Intl.DateTimeFormat(undefined, opts);
  const a = new Date(c.start * 1000), b = new Date(c.end * 1000);
  return f.format(a) === f.format(b) ? f.format(a) : f.formatRange(a, b);
}

const colYear = (c) => fmtDate(c.start, c.timeKnown, { year: "numeric" });
const colName = (c) => c.name || "";
const sameAt = (c, opts) => fmtDate(c.start, c.timeKnown, opts) === fmtDate(c.end, c.timeKnown, opts);

// Works for collections and for the notes of folded ones (kind, start, end, timeKnown).
function defaultTitle(c) {
  const oneDay = sameAt(c, { year: "numeric", month: "numeric", day: "numeric" });
  switch (c.kind) {
    case "trip": return "Trip · " + fmtRange(c);
    case "daytrip": return "Day trip · " + fmtDate(c.start, c.timeKnown, { weekday: "short", month: "short", day: "numeric" });
    case "event": return "Event · " + (oneDay ? fmtDate(c.start, c.timeKnown, { weekday: "long", month: "short", day: "numeric" }) : fmtRange(c));
    default: {
      if (sameAt(c, { year: "numeric", month: "numeric" })) return "Everyday · " + fmtDate(c.start, c.timeKnown, { month: "long" });
      const f = new Intl.DateTimeFormat(undefined, { month: "long", ...zone(c.timeKnown) });
      return "Everyday · " + f.formatRange(new Date(c.start * 1000), new Date(c.end * 1000));
    }
  }
}
// Unnamed collections whose default title repeats (an everyday month in two years) get their year.
function colTitle(c) {
  if (colName(c)) return colName(c);
  const t = defaultTitle(c);
  return S.dupTitles.has(t) ? t + (c.kind === "everyday" ? " " : ", ") + colYear(c) : t;
}

// The line under a title: what kind of collection it is, when, and how far from home.
function colMeta(c) {
  const parts = [];
  if (colName(c)) parts.push(COLLECTION_KIND[c.kind]);
  parts.push(fmtRange(c, true));
  if (c.days > 1 && c.kind !== "everyday") parts.push(plural(c.days, "day"));
  if ((c.kind === "trip" || c.kind === "daytrip") && c.homeKm != null) parts.push(`about ${c.homeKm.toLocaleString()} km from home`);
  if (c.parts > 1) parts.push(`merged from ${c.parts}`);
  return parts.join(" · ");
}

// Cover photo: the best favorite, else the best photo that is still in place.
function colCover(c) {
  let best = null, bestRank = -1;
  for (const id of c.members) {
    const rank = (eff(id) === "fav" ? 4 : 0) + (live(id) ? 2 : 0) + S.photos[id].score;
    if (rank > bestRank) { best = id; bestRank = rank; }
  }
  return best;
}

function tally(ids) {
  const t = { photos: 0, fav: 0, remove: 0, bytes: 0 };
  for (const id of ids) {
    if (!live(id)) continue;
    t.photos++;
    const s = eff(id);
    if (s === "fav") t.fav++;
    else if (s === "remove") { t.remove++; t.bytes += S.photos[id].size; }
  }
  return t;
}

function progress(groups) {
  let done = 0;
  for (const g of groups) if (groupDone(g)) done++;
  return { groups: groups.length, done, left: groups.length - done };
}

function recount() {
  S.total = { ...tally(S.order), ...progress(S.groups) };
  S.stats = new Map(S.collections.map((c) => [c.id, { ...tally(c.members), ...progress(c.groups.map((id) => S.groupById[id])) }]));
}

function colStatus(st) {
  if (st.left) return `${plural(st.left, "group")} to review`;
  if (st.groups) return "all reviewed";
  return st.remove ? `${st.remove.toLocaleString()} to remove` : "nothing to clean up";
}

// The newest collection that still has groups to review, skipping `except`.
const nextCollection = (except) => S.newestFirst.find((c) => c !== except && S.stats.get(c.id).left > 0);

/* ---------- views ---------- */

// Keepers first (favorite, then keep), then the rest, each in time order. Worked out when the view is
// built, so a photo never jumps while you change its state.
function displayOrder(g) {
  const rank = (id) => ({ fav: 0, keep: 1, remove: 2 })[eff(id)];
  return g.members.map((id, i) => [id, i]).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map((x) => x[0]);
}

function buildView(route) {
  const v = { route, type: route, title: route === "finish" ? "Finish" : "Organize", items: [], groups: [], flat: [], itemOf: new Map() };
  const c = S.colById[route];
  const lib = LIBRARY_BY_ID[route];
  const groupItem = (g) => ({ group: g, order: displayOrder(g) });
  if (c) {
    v.type = "collection";
    v.col = c;
    v.title = colTitle(c);
    v.groups = c.groups.map((id) => S.groupById[id]);
    const singles = c.members.filter((id) => !S.photos[id].group);
    if (v.groups.length) v.items.push({ section: "Groups to clean up", count: v.groups.length }, ...v.groups.map(groupItem));
    if (singles.length) v.items.push({ section: v.groups.length ? "Other photos" : "Photos", count: singles.length }, ...singles.map((id) => ({ photo: id })));
    v.items.push({ end: true });
  } else if (lib) {
    v.type = "library";
    v.lib = lib;
    v.title = lib.label;
    if (lib.groups) {
      v.groups = lib.groups();
      v.items = v.groups.map(groupItem);
    } else {
      v.items = lib.photos().map((id) => ({ photo: id }));
    }
  }
  v.items.forEach((item, i) => {
    item.i = i;
    for (const id of item.group ? item.order : item.photo ? [item.photo] : []) {
      v.flat.push(id);
      v.itemOf.set(id, item);
    }
  });
  return v;
}

function libraryCount(lib) {
  return lib.groups ? lib.groups().length : lib.photos().filter(live).length;
}

const hasGroups = () => S.view && (S.view.type === "collection" || S.view.type === "library") && S.view.groups.length > 0;

function renderView() {
  const v = (S.view = buildView(S.route));
  for (const id of S.sel) if (!v.itemOf.has(id)) S.sel.delete(id);
  if (v.type !== "organize") S.colSel.clear();
  if (v.type !== "finish") S.finish = null;
  closeMenu();
  paintSelection();
  S.rendered = 0;
  S.lastDay = null;
  S.wrap = null;
  S.renaming = false;
  if (S.cursor && !v.itemOf.has(S.cursor)) S.cursor = null;
  S.nextId = (firstUnreviewed() || {}).id || null;
  document.title = v.title + " - Photo cleanup";
  paintSteps();
  for (const a of document.querySelectorAll(".nav-item")) {
    const on = a.dataset.route === v.route;
    a.classList.toggle("on", on);
    if (on) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
  }
  if (v.type === "library") $("#nav-lib").open = true;
  $("#size-box").hidden = v.type === "organize" || v.type === "finish";

  const main = $("#main");
  main.className = "view-" + v.type;
  main.replaceChildren(viewHead());
  if (v.type === "organize") main.append(organizeBody());
  else if (v.type === "finish") main.append(finishBody());
  else if (!v.flat.length) main.append(el("div", "empty", v.lib.empty || "Nothing here."));
  else fill();
  markCursor();
  watchHead();
}

// Appends the next batch of the current view. Returns false when everything is rendered.
function renderMore() {
  const v = S.view;
  if (!v || S.rendered >= v.items.length) return false;
  const main = $("#main");
  let budget = CHUNK;
  while (budget > 0 && S.rendered < v.items.length) {
    const item = v.items[S.rendered++];
    if (item.section) {
      const h = el("h3", "section", item.section, el("span", "n", item.count.toLocaleString()));
      if (item.section === "Other photos") h.id = "others";
      main.append(h);
      S.wrap = S.lastDay = null;
    } else if (item.end) {
      main.append(endPanel());
    } else if (item.group) {
      main.append(groupCard(item));
      S.wrap = S.lastDay = null;
      budget -= item.group.members.length;
    } else {
      const day = fmtDay(S.photos[item.photo]);
      if (day !== S.lastDay || !S.wrap) {
        S.lastDay = day;
        S.wrap = el("div", "tiles");
        main.append(el("div", "day", day), S.wrap);
      }
      S.wrap.append(tile(item.photo));
      budget--;
    }
  }
  return true;
}

// Renders batches until the page extends well below the visible area.
function fill() {
  const sentinel = $("#sentinel");
  while (sentinel.getBoundingClientRect().top < innerHeight + 1200 && renderMore());
}

function ensureRendered(selector) {
  let node = document.querySelector(selector);
  while (!node && renderMore()) node = document.querySelector(selector);
  return node;
}

/* ---------- small shared pieces ---------- */

function thumb(id, cls) {
  const img = el("img", cls);
  img.loading = "lazy";
  img.decoding = "async";
  img.alt = "";
  if (id) img.src = "/thumb/" + id;
  return img;
}

function progressBar(st) {
  const bar = el("span", "bar" + (st.groups && !st.left ? " full" : ""), el("i"));
  bar.firstChild.style.width = (st.groups ? (st.done / st.groups) * 100 : 0) + "%";
  return bar;
}

function progressText(st) {
  return st.groups ? `${st.done.toLocaleString()} of ${plural(st.groups, "group")} reviewed` : "No near-identical photos here";
}

function actionButton(label, onClick, primary) {
  const b = el("button", "btn" + (primary ? " primary" : ""), el("span", "btn-text", label), icon("arrow", 15));
  b.onclick = onClick;
  return b;
}

function linkButton(label, route, cls) {
  const a = el("a", "btn" + (cls ? " " + cls : ""), el("span", "btn-text", label), icon("arrow", 15));
  a.href = "#" + route;
  return a;
}

// "1,037 to remove · 2.1 GB" style counts with the colored marks.
function countsLine(st) {
  return el("span", "counts",
    el("span", null, plural(st.photos, "photo")),
    el("span", "fav", icon("star", 12), st.fav.toLocaleString()),
    el("span", "remove", icon("x", 12), st.remove.toLocaleString() + (st.remove ? " · " + fmtBytes(st.bytes) : "")));
}

/* ---------- menus ---------- */

// One popup menu for the whole page; items are {label, icon, onClick}.
function openMenu(anchor, items) {
  const m = $("#menu-pop");
  if (!m.hidden && S.menuAnchor === anchor) return closeMenu();
  closeMenu();
  m.replaceChildren(...items.filter(Boolean).map((it) => {
    const b = el("button", "menu-item", it.icon ? icon(it.icon, 15) : null, it.label);
    b.setAttribute("role", "menuitem");
    b.onclick = () => { closeMenu(); it.onClick(); };
    return b;
  }));
  m.hidden = false;
  S.menuAnchor = anchor;
  anchor.setAttribute("aria-expanded", "true");
  const r = anchor.getBoundingClientRect();
  const left = Math.max(8, Math.min(r.right - m.offsetWidth, innerWidth - m.offsetWidth - 8));
  const below = r.bottom + 6 + m.offsetHeight < innerHeight - 8;
  m.style.left = left + "px";
  m.style.top = (below ? r.bottom + 6 : r.top - m.offsetHeight - 6) + "px";
  m.querySelector("button").focus();
}

function closeMenu() {
  const m = $("#menu-pop");
  if (m.hidden) return;
  m.hidden = true;
  if (S.menuAnchor) S.menuAnchor.setAttribute("aria-expanded", "false");
  S.menuAnchor = null;
}

function moreButton(label, items) {
  const b = el("button", "btn ghost small more", icon("more", 16));
  b.title = label;
  b.setAttribute("aria-label", label);
  b.setAttribute("aria-haspopup", "menu");
  b.setAttribute("aria-expanded", "false");
  b.onclick = () => openMenu(b, items());
  return b;
}

// Capture phase: a click outside closes the menu before anything else reacts. Its own button toggles it.
document.addEventListener("click", (e) => {
  if (!$("#menu-pop").hidden && !e.target.closest("#menu-pop") && (!S.menuAnchor || !S.menuAnchor.contains(e.target))) closeMenu();
}, true);
addEventListener("scroll", closeMenu, { passive: true });
addEventListener("resize", closeMenu);

/* ---------- step tabs ---------- */

function paintSteps() {
  const v = S.view;
  if (!v) return;
  const t = S.total, m = movePlan();
  const n = m.remove + m.toFile + m.toBack;
  const active = v.type === "organize" ? "organize" : v.type === "finish" ? "finish" : "review";
  const step = (id, label, status) => {
    const a = el("a", "step" + (id === active ? " on" : ""), el("span", "step-label", label), el("span", "step-status", status));
    a.href = "#" + id;
    if (id === active) a.setAttribute("aria-current", "page");
    return a;
  };
  $("#steps").replaceChildren(
    step("organize", "Organize", plural(S.collections.length, "collection")),
    step("review", "Review", t.groups ? `${t.done.toLocaleString()} of ${plural(t.groups, "group")}` : "nothing to review"),
    step("finish", "Finish", n ? `${n.toLocaleString()} to move` : S.moved.size + Object.keys(S.filed).length ? "moved" : "nothing to move"));
}

/* ---------- view header ---------- */

function viewHead() {
  const v = S.view;
  const head = el("header", "vhead");
  head.id = "vhead";

  if (v.type === "collection") {
    const c = v.col, st = S.stats.get(c.id);
    const rename = el("button", "btn ghost small", icon("pencil", 13), "Rename");
    rename.onclick = () => startRename(c, head.querySelector(".title-row"));
    head.append(el("div", "vhead-top",
      el("span", "kind-ico big " + c.kind, icon(c.kind, 22)),
      el("div", "vhead-text",
        el("div", "title-row", el("h2", null, colTitle(c)), rename),
        el("p", "vmeta", colMeta(c))),
      moreButton("More actions for this collection", () => collectionMenu(c))));
    if (c.folded) head.append(foldedNotes(c.folded));
    let action = null;
    if (st.left) action = actionButton("Review next group", () => focusGroup(firstUnreviewed(), "start"), true);
    else {
      const next = nextCollection(c);
      action = next ? actionButton("Next: " + colTitle(next), () => go(next.id), st.groups > 0) : linkButton("Finish", "finish", "primary");
    }
    head.append(el("div", "vbar",
      el("div", "vbar-progress", el("div", "vbar-line", el("span", null, progressText(st)), countsLine(st)), st.groups ? progressBar(st) : null),
      action),
      folderLine(c));
    return head;
  }

  if (v.type === "organize") {
    const kinds = {};
    for (const c of S.collections) kinds[c.kind] = (kinds[c.kind] || 0) + 1;
    const names = { trip: "trip", daytrip: "day trip", event: "event", everyday: "everyday month" };
    const summary = Object.keys(names).filter((k) => kinds[k]).map((k) => plural(kinds[k], names[k])).join(" · ");
    head.append(el("div", "vhead-top", el("div", "vhead-text",
      el("div", "title-row", el("h2", null, "Organize")),
      el("p", "vmeta", "Merge the trips and events that belong together, and unmark the ones that are not really trips or events. Only this page changes; no files move.")),
      S.collections.length ? linkButton("Start reviewing", "review", "primary") : null));
    if (summary) head.append(el("p", "vsummary", summary));
    return head;
  }

  if (v.type === "finish") {
    head.append(el("div", "vhead-top", el("div", "vhead-text",
      el("div", "title-row", el("h2", null, "Finish")),
      el("p", "vmeta", "Two separate steps, each with its own Undo. Organize the files into collection folders whenever you like, even before reviewing; clean up once the review is done. Nothing is deleted."))));
    return head;
  }

  const count = libraryCount(v.lib);
  head.append(el("div", "vhead-top", el("div", "vhead-text",
    el("div", "title-row", el("h2", null, v.title), el("span", "title-count", count.toLocaleString())),
    el("p", "vmeta", v.lib.hint))));
  if (v.groups.length) {
    const st = progress(v.groups);
    const action = st.left ? actionButton("Review next group", () => focusGroup(firstUnreviewed(), "start"), true) : null;
    head.append(el("div", "vbar", el("div", "vbar-progress", el("div", "vbar-line", el("span", null, progressText(st))), progressBar(st)), action));
  }
  return head;
}

function refreshHead() {
  if (S.renaming) return;
  const old = $("#vhead");
  if (old && S.view.type !== "organize") old.replaceWith(viewHead());
}

// Renames in place: `row` is the element holding the title.
function startRename(c, row) {
  closeMenu();
  S.renaming = true;
  const input = el("input", "rename-input");
  input.type = "text";
  input.maxLength = 80;
  input.value = colName(c);
  input.placeholder = defaultTitle(c);
  input.setAttribute("aria-label", "Name for this collection");
  const saveBtn = el("button", "btn primary small", "Save");
  const cancelBtn = el("button", "btn ghost small", "Cancel");
  const done = () => {
    S.renaming = false;
    if (S.view.type === "organize") refreshOrganize(); else refreshHead();
  };
  const commit = async () => {
    const name = input.value.trim();
    if (name === colName(c)) return done();
    try {
      await S.saving;
      await post("/api/name", { id: c.members[0], name });
      S.renaming = false;
      await load();  // the name also changes the folder name, which the server works out
    } catch (e) {
      toast("Could not save the name (" + e.message + "). Is the server still running?", true);
      done();
    }
  };
  input.onkeydown = (e) => {
    if (e.key === "Enter") commit();
    else if (e.key === "Escape") { e.stopPropagation(); done(); }
  };
  saveBtn.onclick = commit;
  cancelBtn.onclick = done;
  row.replaceChildren(input, saveBtn, cancelBtn);
  input.focus();
  input.select();
}

/* ---------- sticky progress under the top bar ---------- */

const headObserver = new IntersectionObserver((entries) => {
  S.headAway = !entries[entries.length - 1].isIntersecting;
  paintSubbar();
}, { rootMargin: "-60px 0px 0px 0px" });

function watchHead() {
  headObserver.disconnect();
  S.headAway = false;
  paintSubbar();
  if (hasGroups()) headObserver.observe($("#vhead"));
}

function paintSubbar() {
  const bar = $("#subbar");
  const show = S.headAway && hasGroups();
  bar.hidden = !show;
  document.body.classList.toggle("has-subbar", show);
  if (!show) return;
  const v = S.view;
  const st = v.type === "collection" ? S.stats.get(v.col.id) : progress(v.groups);
  let action;
  if (st.left) action = actionButton("Next group", () => focusGroup(firstUnreviewed(), "start"));
  else {
    const next = nextCollection(v.col);
    action = next ? actionButton("Next: " + colTitle(next), () => go(next.id), true) : linkButton("Finish", "finish", "primary");
  }
  action.classList.add("small");
  const title = el("button", "subbar-title", v.col ? el("span", "kind-ico " + v.col.kind, icon(v.col.kind, 14)) : null, el("span", "subbar-name", v.title));
  title.title = "Back to the top";
  title.onclick = () => window.scrollTo({ top: 0, behavior: "smooth" });
  bar.replaceChildren(title,
    el("span", "subbar-progress", el("span", null, st.groups ? `${st.done.toLocaleString()} of ${st.groups.toLocaleString()}` : ""), progressBar(st)),
    action);
}

/* ---------- fixing collections: merge, split, not a trip, folder ---------- */

const colOfPhoto = (pid) => S.photos[pid] && S.colById[S.photos[pid].collection];

function collectionMenu(c) {
  return [
    { icon: "merge", label: "Merge with…", onClick: () => openMerge(c) },
    c.parts > 1 && { icon: "split", label: `Split back into ${c.parts}`, onClick: () => splitCollection(c) },
    NOT_KIND[c.kind] && { icon: "x", label: NOT_KIND[c.kind], onClick: () => dissolveCollection(c) },
  ];
}

const splitCollection = (c) => editCollections("split", [c.members[0]], "Split back into the original collections.");
const dissolveCollection = (c) => editCollections("dissolve", [c.members[0]]);
const mergeCollections = (cols) => editCollections("merge", cols.map((o) => o.members[0]), `Merged ${plural(cols.length, "collection")} into one.`);

function foldedNote(f) {
  const restore = el("button", "btn small", icon("undo", 14), "Restore");
  restore.onclick = () => editCollections("restore", f.anchors, "Restored as " + COLLECTION_KIND[f.kind].toLowerCase() + ".");
  return el("div", "folded",
    el("span", null, `Includes ${plural(f.photos, "photo")} from `, el("b", null, defaultTitle(f)),
      `, which you marked as ${NOT_KIND[f.kind].replace("Not ", "not ")}.`),
    restore);
}

// One note, or a single line that opens to the list when several were folded in.
function foldedNotes(list) {
  if (list.length === 1) return el("div", "note", foldedNote(list[0]));
  const n = list.reduce((sum, f) => sum + f.photos, 0);
  const box = el("details", "note");
  box.append(el("summary", null, icon("chev", 14), `Includes ${plural(n, "photo")} from ${list.length} trips or events you marked as not one`),
    ...list.map(foldedNote));
  return box;
}

// Where a collection's photos are, against where "Organize files" would put them. Photos marked
// remove are filed too: organizing can come before the review, and clean-up takes them out later.
function folderPlan(c) {
  let toFile = 0, filed = 0, toBack = 0;
  const inFolder = c.folder + "/";
  for (const id of c.members) {
    if (!live(id)) continue;  // in _to_remove
    const at = S.filed[id];
    if (c.folderOn) {
      if (at && at.startsWith(inFolder)) filed++;
      else toFile++;
    } else if (at) toBack++;
  }
  return { toFile, filed, toBack };
}

function folderSwitch(c, onChange, label) {
  const input = el("input");
  input.type = "checkbox";
  input.setAttribute("role", "switch");
  input.checked = !!c.folderOn;
  input.onchange = () => {
    c.folderOn = input.checked;
    save("/api/folder", { id: c.members[0], on: c.folderOn });
    onChange();
  };
  const sw = el("label", "switch", input, el("span", "track", el("i")));
  if (label) sw.append(el("span", "switch-label", label));
  else input.setAttribute("aria-label", "Make a folder for " + colTitle(c));
  return sw;
}

function folderHint(c) {
  const { toFile, filed } = folderPlan(c);
  const where = el("code", null, `${c.folder}/`);
  let hint;
  if (!c.folderOn) hint = el("span", null, "Photos stay where they are.");
  else if (toFile) hint = el("span", null, `${plural(toFile, "photo")} will move to `, where, " when you organize the files on the Finish page.");
  else hint = el("span", null, "Everything is in ", where, ".");
  if (filed) hint.append(` ${plural(filed, "photo")} ${filed === 1 ? "is" : "are"} already there.`);
  return hint;
}

function folderLine(c) {
  return el("div", "folder-line" + (c.folderOn ? " on" : ""),
    folderSwitch(c, () => { refreshCounts(); }, el("span", "switch-text", icon("folder", 15), "Make a folder for these photos")),
    el("span", "folder-hint", folderHint(c)));
}

// Collection edits regroup on the server, which renumbers collections: reload, then show the result.
async function editCollections(op, ids, message) {
  closeMenu();
  try {
    await S.saving;
    const r = await post("/api/collections", { op, ids });
    if (S.lb) closeLightbox();
    S.colSel.clear();
    await load();
    const c = colOfPhoto(r.anchor);
    if (S.view.type === "organize") flashRow(c);
    else if (c) go(c.id);
    toast(op === "dissolve" ? `Moved into ${c ? colTitle(c) : "everyday"}. You can restore it from there.` : message);
  } catch (e) {
    toast("That did not work (" + e.message + "). Is the server still running?", true);
  }
}

function pickRow(o, tail) {
  return [
    thumb(colCover(o), "pick-cover"),
    el("span", "pick-text", el("span", "pick-title", colTitle(o)),
      el("span", "pick-sub", [COLLECTION_KIND[o.kind], fmtRange(o, true), plural(o.members.length, "photo")].join(" · "))),
    tail,
  ];
}

function openMerge(c) {
  const dlg = $("#merge");
  const others = S.collections.filter((o) => o !== c)
    .sort((a, b) => Math.abs(a.start - c.start) - Math.abs(b.start - c.start));
  const mergeBtn = $("#merge-go");
  const picked = new Set();
  const paint = () => {
    mergeBtn.disabled = !picked.size;
    mergeBtn.textContent = picked.size ? `Merge ${plural(picked.size + 1, "collection")}` : "Merge";
  };
  const list = $("#merge-list");
  list.replaceChildren(...others.map((o) => {
    const box = el("input");
    box.type = "checkbox";
    box.onchange = () => { if (box.checked) picked.add(o); else picked.delete(o); paint(); };
    return el("label", "pick", box, ...pickRow(o));
  }));
  $("#merge-title").textContent = "Merge " + colTitle(c) + " with…";
  mergeBtn.onclick = () => {
    closeDialog(dlg);
    mergeCollections([c, ...picked]);
  };
  paint();
  openDialog(dlg);
  list.scrollTop = 0;
}

/* ---------- organize ---------- */

// Calendar day of a timestamp: capture times are wall-clock values stored as UTC, file times are instants.
const dayIndex = (sec, known) => Math.floor((known ? sec : sec - new Date(sec * 1000).getTimezoneOffset() * 60) / 86400);

// Trips, day trips and events that start at most two calendar days after the previous one ends (one
// day at home in between) may well be one. Overlaps are left out: they come from a long merged
// collection, not from a trip split in two; a few hours are allowed for clocks in another time zone.
function mergeHints() {
  const hints = new Map();
  const away = S.collections.filter((c) => c.kind !== "everyday").sort((a, b) => a.start - b.start);
  for (let i = 1; i < away.length; i++) {
    const a = away[i - 1], b = away[i];
    const days = dayIndex(b.start, b.timeKnown) - dayIndex(a.end, a.timeKnown);
    if (b.start - a.end > -6 * 3600 && days <= 2) hints.set(b.id, { other: a, days: Math.max(0, days) });
  }
  return hints;
}

function gapText(h) {
  const t = colTitle(h.other);
  return h.days === 0 ? "Same day as " + t : h.days === 1 ? "The day after " + t : "2 days after " + t;
}

const ratio = (id) => {
  const p = S.photos[id];
  return String(Math.min(2, Math.max(0.5, p.w && p.h ? p.w / p.h : 1)));
};

function organizeBody() {
  const wrap = el("div", "organize");
  wrap.id = "organize";
  if (!S.collections.length) {
    const all = el("a", "btn", "Open all photos");
    all.href = "#all";
    wrap.append(el("div", "empty", el("p", null, "No trips or events were found in this folder."), all));
    return wrap;
  }
  const hints = mergeHints();
  let year = null, board = null;
  for (const c of S.newestFirst) {
    if (colYear(c) !== year) {
      year = colYear(c);
      board = el("div", "obento");
      wrap.append(el("h3", "section", year), board);
    }
    board.append(orgCard(c, hints.get(c.id)));
  }
  return wrap;
}

function refreshOrganize() {
  const old = $("#organize");
  if (old) old.replaceWith(organizeBody());
}

// Bento board: a collection's tile grows with the photos it holds, so the big trips and busy months
// stand out; the cover is a small mosaic of its best shots.
const cardSize = (n) => (n >= 100 ? "xl" : n >= 25 ? "wide" : "small");
const MOSAIC = { xl: 3, wide: 3, small: 1 };

function coverPhotos(c, n) {
  const rank = (id) => (eff(id) === "fav" ? 4 : eff(id) === "keep" ? 1 : 0) + S.photos[id].score;
  return c.members.filter(live).sort((a, b) => rank(b) - rank(a)).slice(0, n);
}

function orgCard(c, hint) {
  const st = S.stats.get(c.id);
  const size = cardSize(st.photos);
  const card = el("div", `ocard size-${size} ${c.kind}` + (S.colSel.has(c.id) ? " selected" : ""));
  card.dataset.col = c.id;

  const cover = el("a", "ocard-cover");
  cover.href = "#" + c.id;
  cover.setAttribute("aria-label", "Open " + colTitle(c));
  cover.append(...coverPhotos(c, MOSAIC[size]).map((id) => thumb(id)));

  const box = el("input");
  box.type = "checkbox";
  box.checked = S.colSel.has(c.id);
  box.setAttribute("aria-label", "Select " + colTitle(c) + " to merge");
  box.onchange = () => toggleColSel(c, box.checked);

  const actions = el("div", "ocard-actions");
  const action = (ico, label, onClick) => {
    const b = el("button", "icon-chip", icon(ico, 15));
    b.title = label;
    b.setAttribute("aria-label", label);
    b.onclick = onClick;
    actions.append(b);
  };
  const body = el("div", "ocard-body");
  action("pencil", "Rename", () => startRename(c, body.querySelector(".ocard-head")));
  if (c.parts > 1) action("split", `Split back into the ${c.parts} collections it was made of`, () => splitCollection(c));
  if (NOT_KIND[c.kind]) action("x", NOT_KIND[c.kind] + ": its photos go back to their everyday month", () => dissolveCollection(c));

  const title = el("a", "ocard-title", colTitle(c));
  title.href = "#" + c.id;
  const meta = [fmtRange(c), plural(st.photos, "photo")];
  if (st.groups) meta.push(colStatus(st));
  body.append(el("div", "ocard-head", title), el("div", "ocard-meta", meta.join(" · ")));
  if (hint) {
    const m = el("button", "chip", icon("merge", 12), "Merge with " + colTitle(hint.other));
    m.title = gapText(hint) + ". Merge them into one?";
    m.onclick = () => mergeCollections([c, hint.other]);
    body.append(m);
  }
  if (c.folded && c.folded.length) {
    const f = c.folded[0];
    const chip = el("button", "chip quiet", icon("undo", 12),
      c.folded.length > 1 ? `Includes ${c.folded.length} unmarked · Open`
        : size === "small" ? `Restore ${COLLECTION_KIND[f.kind].toLowerCase()}` : `Includes ${COLLECTION_KIND[f.kind].toLowerCase()} · Restore`);
    chip.title = c.folded.map((x) => `${defaultTitle(x)} · ${plural(x.photos, "photo")}`).join("\n");
    chip.onclick = c.folded.length === 1
      ? () => editCollections("restore", f.anchors, "Restored as " + COLLECTION_KIND[f.kind].toLowerCase() + ".")
      : () => go(c.id);
    body.append(chip);
  }
  if (st.groups) body.append(progressBar(st));

  card.append(cover,
    el("div", "ocard-top", el("label", "ocard-check", box),
      el("span", "kind-tag " + c.kind, icon(c.kind, 13), c.parts > 1 ? `${COLLECTION_KIND[c.kind]} · ${c.parts} merged` : COLLECTION_KIND[c.kind]),
      actions),
    body);
  return card;
}

function toggleColSel(c, on) {
  if (on) S.colSel.add(c.id); else S.colSel.delete(c.id);
  const card = document.querySelector(`.ocard[data-col="${c.id}"]`);
  if (card) {
    card.classList.toggle("selected", on);
    card.querySelector(".ocard-check input").checked = on;
  }
  paintSelection();
}

function clearColSel() {
  for (const id of [...S.colSel]) toggleColSel(S.colById[id], false);
}

function flashRow(c) {
  const card = c && document.querySelector(`.ocard[data-col="${c.id}"]`);
  if (!card) return;
  card.scrollIntoView({ block: "nearest", behavior: "smooth" });
  card.classList.add("flash");
  setTimeout(() => card.classList.remove("flash"), 1600);
}

/* ---------- selecting photos and moving them to another collection ---------- */

function toggleSelect(id, range) {
  const flat = S.view.flat;
  if (range && S.selFrom && flat.includes(S.selFrom)) {
    const [a, b] = [flat.indexOf(S.selFrom), flat.indexOf(id)].sort((x, y) => x - y);
    return selectIds(flat.slice(a, b + 1), true);
  }
  S.selFrom = id;
  selectIds([id], !S.sel.has(id));
}

function selectIds(ids, on) {
  for (const id of ids) if (on) S.sel.add(id); else S.sel.delete(id);
  for (const id of ids) for (const t of document.querySelectorAll(`.tile[data-id="${id}"]`)) t.classList.toggle("selected", on);
  for (const gid of new Set(ids.map((id) => S.photos[id].group).filter(Boolean))) refreshGroup(gid);
  paintSelection();
}

function clearSelection() {
  selectIds([...S.sel], false);
  S.selFrom = null;
}

// The bottom bar: selected photos (Move to…) or, on Organize, selected collections (Merge).
function paintSelection() {
  const org = !!S.view && S.view.type === "organize";
  const n = org ? S.colSel.size : S.sel.size;
  document.body.classList.toggle("selecting", !org && n > 0);
  document.body.classList.toggle("bar-up", n > 0);
  $("#selbar").hidden = !n;
  $("#sel-count").textContent = plural(n, org ? "collection" : "photo") + " selected";
  const go = $("#sel-go");
  go.textContent = org ? (n > 1 ? `Merge ${n}` : "Pick another to merge") : "Move to…";
  go.disabled = org && n < 2;
}

function openMoveTo() {
  const ids = [...S.sel];
  if (!ids.length) return;
  const at = Math.min(...ids.map((id) => S.photos[id].time));
  const targets = S.collections.filter((c) => !ids.every((id) => S.photos[id].collection === c.id))
    .sort((a, b) => Math.abs(a.start - at) - Math.abs(b.start - at));
  $("#moveto-title").textContent = `Move ${plural(ids.length, "photo")} to…`;
  $("#moveto-list").replaceChildren(...targets.map((c) => {
    const b = el("button", "pick", ...pickRow(c, icon("arrow", 15)));
    b.onclick = () => { closeDialog($("#moveto")); moveSelected(ids, c); };
    return b;
  }));
  openDialog($("#moveto"));
  $("#moveto-list").scrollTop = 0;
}

async function moveSelected(ids, dest) {
  const moving = new Set(ids);
  const v = S.view;
  // Stay on the collection you were looking at (its id can change when regrouping).
  const stay = v.type === "collection" ? v.col.members.find((id) => !moving.has(id)) : null;
  const destTitle = colTitle(dest);
  try {
    await S.saving;
    await post("/api/collections", { op: "move", ids, into: dest.members[0] });
    clearSelection();
    await load();
    if (v.type === "collection") {
      const c = colOfPhoto(stay || ids[0]);
      if (c) go(c.id);
    }
    toast(`Moved ${plural(ids.length, "photo")} to ${destTitle}.`);
  } catch (e) {
    toast("That did not work (" + e.message + "). Is the server still running?", true);
  }
}

$("#sel-go").onclick = () => (S.view.type === "organize" ? mergeCollections(S.newestFirst.filter((c) => S.colSel.has(c.id))) : openMoveTo());
$("#sel-clear").onclick = () => (S.view.type === "organize" ? clearColSel() : clearSelection());

/* ---------- navigator ---------- */

function renderNav() {
  const nav = $("#nav");
  S.navRefs = new Map();
  nav.replaceChildren();

  const link = (route, cls) => {
    const a = el("a", "nav-item" + (cls ? " " + cls : ""));
    a.href = "#" + route;
    a.dataset.route = route;
    return a;
  };

  // Library views are a side trip from the main flow: one folded line at the top.
  const lib = el("details", "nav-lib");
  lib.id = "nav-lib";
  lib.open = localStorage.getItem("libOpen") === "1";
  lib.ontoggle = () => localStorage.setItem("libOpen", lib.open ? "1" : "0");
  lib.append(el("summary", "nav-label", icon("chev", 13), "Library"));
  for (const v of LIBRARY) {
    const a = link(v.id, "lib");
    const count = el("span", "nav-count");
    a.append(el("span", "nav-title", v.label), count);
    S.navRefs.set(v.id, { count });
    lib.append(a);
  }
  nav.append(lib);

  let year = null;
  for (const c of S.newestFirst) {
    if (colYear(c) !== year) {
      year = colYear(c);
      nav.append(el("div", "nav-label", year));
    }
    const a = link(c.id, "col");
    const title = el("span", "nav-title");
    const sub = el("span", "nav-sub");
    const barSlot = el("span", "bar-slot");
    a.append(el("span", "kind-ico " + c.kind, icon(c.kind, 16)), el("span", "nav-text", title, sub, barSlot));
    S.navRefs.set(c.id, { a, title, sub, barSlot });
    nav.append(a);
  }
  if (!S.collections.length) nav.append(el("div", "nav-empty", "No trips or events yet."));
  paintNav();
}

function paintNav() {
  for (const lib of LIBRARY) S.navRefs.get(lib.id).count.textContent = libraryCount(lib).toLocaleString();
  for (const c of S.collections) {
    const ref = S.navRefs.get(c.id), st = S.stats.get(c.id);
    ref.title.textContent = colTitle(c);
    ref.sub.textContent = (colName(c) ? fmtRange(c) + " · " : "") + plural(st.photos, "photo") + " · " + colStatus(st);
    ref.a.title = colTitle(c) + "\n" + colMeta(c);
    ref.a.classList.toggle("done", st.groups > 0 && !st.left);
    ref.barSlot.replaceChildren(...(st.groups ? [progressBar(st)] : []));
  }
  const t = S.total;
  $("#totals").replaceChildren(
    el("div", "totals-row", countsLine(t)),
    el("div", "totals-progress",
      el("span", null, t.groups ? progressText(t) : "No groups to review"),
      t.groups ? progressBar(t) : null));
}

// What the two Finish steps would do now: organize (photos into their collection folders, or back
// out of folders whose switch is off) and clean up (photos marked remove into _to_remove).
function movePlan() {
  const plans = S.collections.map((c) => ({ c, ...folderPlan(c) }));
  const folders = plans.filter((f) => f.toFile);
  return { remove: S.total.remove, bytes: S.total.bytes, folders,
    toFile: folders.reduce((n, f) => n + f.toFile, 0), toBack: plans.reduce((n, f) => n + f.toBack, 0) };
}

function refreshCounts() {
  recount();
  paintNav();
  paintSteps();
  refreshHead();
  refreshEnd();
  paintSubbar();
  if (S.view && S.view.type === "finish") refreshFinish();
}

/* ---------- groups + tiles ---------- */

// A reviewed group folds into one short row unless you open it again.
const collapsed = (g) => groupDone(g) && !S.expanded.has(g.id);

function firstUnreviewed(from = 0) {
  const gs = S.view.groups;
  for (let k = 0; k < gs.length; k++) {
    const g = gs[(from + k) % gs.length];
    if (!groupDone(g)) return g;
  }
  return null;
}

// Keeps the "Next up" marker on the first group that still needs a look.
function updateNext() {
  const old = S.nextId;
  S.nextId = (firstUnreviewed() || {}).id || null;
  if (old !== S.nextId) for (const gid of [old, S.nextId]) if (gid) refreshGroup(gid);
}

function groupCard(item) {
  const g = item.group;
  const card = el("section", "group");
  card.dataset.group = g.id;
  const why = groupWhy(g);
  card.append(groupHead(g));
  if (why) card.append(el("div", "why", el("b", null, "Haiku"), why));
  const tiles = el("div", "tiles" + (g.members.length <= 3 ? " few" : ""));
  for (const id of item.order) tiles.append(tile(id));
  const keepers = el("button", "keepers");
  keepers.title = "Show the whole group";
  card.append(tiles, keepers);
  paintGroup(card, g);
  return card;
}

function paintGroup(card, g) {
  const fold = collapsed(g);
  card.classList.toggle("done", groupDone(g));
  card.classList.toggle("collapsed", fold);
  card.classList.toggle("next", g.id === S.nextId);
  const keepers = card.querySelector(".keepers");
  if (fold) {
    const order = (S.view.itemOf.get(g.members[0]) || {}).order || g.members;
    keepers.replaceChildren(...order.filter((id) => live(id) && eff(id) !== "remove").map((id) => {
      const img = thumb(id, eff(id) === "fav" ? "fav" : null);
      img.style.setProperty("--r", ratio(id));
      return img;
    }));
  } else keepers.replaceChildren();
}

function refreshGroup(gid) {
  const card = document.querySelector(`.group[data-group="${gid}"]`);
  if (!card) return;
  paintGroup(card, S.groupById[gid]);
  card.querySelector(".ghead").replaceWith(groupHead(S.groupById[gid]));
}

function expandGroup(g, on) {
  if (on) S.expanded.add(g.id); else S.expanded.delete(g.id);
  refreshGroup(g.id);
}

function groupWhy(g) {
  for (const id of g.members) if (S.haiku[id] && S.haiku[id].why) return S.haiku[id].why;
  return "";
}

function groupHead(g) {
  const head = el("div", "ghead");
  const t = tally(g.members);
  const movedCount = g.members.filter((id) => !live(id)).length;
  const done = groupDone(g);
  const kept = t.photos - t.remove;

  const info = el("div", "ginfo");
  if (collapsed(g)) info.append(el("span", "reviewed-mark", icon("check", 14), "Reviewed"));
  info.append(el("span", "title", plural(g.members.length, "photo")), el("span", "meta", fmtTime(S.photos[g.members[0]])));
  const c = S.view.type !== "collection" && S.colById[g.collection];
  if (c) {
    const a = el("a", "meta link", colTitle(c));
    a.href = "#" + c.id;
    info.append(a);
  }
  if (collapsed(g)) {
    info.append(el("span", "outcome", `Kept ${kept} of ${t.photos}`));
    const show = el("button", "btn small ghost", "Show");
    show.title = "Open this group again";
    show.onclick = () => expandGroup(g, true);
    head.append(info, el("div", "gactions", show));
    return head;
  }
  if (g.id === S.nextId) info.append(el("span", "badge next", "Next up"));
  info.append(el("span", "badge", GROUP_KIND[g.kind] || g.kind));
  if (g.you) info.append(el("span", "badge you", "You"));
  if (g.members.some((id) => S.haiku[id])) {
    const b = el("span", "badge ai", "Haiku");
    b.title = "Reviewed by Haiku: " + groupWhy(g);
    info.append(b);
  } else if (g.close) info.append(el("span", "badge close", "Close call"));
  if (g.members.some((id) => S.decisions[id])) info.append(el("span", "badge edited", el("i", "dot"), "Edited"));
  if (movedCount) info.append(el("span", "badge", `${movedCount} moved`));
  info.append(el("span", "outcome", `Keeping ${kept} of ${t.photos}`));

  const all = g.members.every((id) => S.sel.has(id));
  const more = moreButton("More actions for this group", () => [
    { icon: "check", label: "Keep all", onClick: () => setStates(Object.fromEntries(g.members.map((id) => [id, eff(id) === "fav" ? "fav" : "keep"]))) },
    { icon: "undo", label: "Reset to suggestion", onClick: () => setStates(Object.fromEntries(g.members.map((id) => [id, null]))) },
    { icon: "arrow", label: all ? "Deselect the group" : "Select the group, to move it", onClick: () => selectIds(g.members, !all) },
  ]);
  const actions = el("div", "gactions", more);
  if (done) {
    const hide = el("button", "btn small ghost", "Hide");
    hide.title = "Fold this reviewed group away";
    hide.onclick = () => expandGroup(g, false);
    actions.append(hide);
  }
  const review = el("button", "btn small review" + (done ? " on" : ""), icon("check", 13), done ? "Reviewed" : "Mark reviewed");
  if (!done) review.append(el("kbd", null, "D"));
  review.title = done ? "Click to mark as not reviewed" : "Mark this group as reviewed and fold it away (D)";
  review.setAttribute("aria-pressed", String(done));
  review.onclick = () => setReviewed(g, !done);
  actions.append(review);
  head.append(info, actions);
  return head;
}

function tile(id) {
  const p = S.photos[id];
  const t = el("div", "tile");
  t.dataset.id = id;
  t.title = p.reason ? `${p.rel}\n${p.reason}` : p.rel;
  t.classList.toggle("is-you", !!p.me);
  t.style.setProperty("--r", ratio(id));
  const img = thumb(id);
  img.alt = baseName(p.rel);
  const mine = el("span", "mine");
  mine.title = "Changed by you";
  const ctrl = el("div", "ctrl");
  for (const s of STATES) {
    const b = el("button", s, icon(STATE_ICON[s], 15));
    b.dataset.state = s;
    b.title = `${STATE_LABEL[s]} (${STATE_KEY[s]})`;
    b.setAttribute("aria-label", STATE_LABEL[s]);
    b.tabIndex = -1;  // the keyboard works through the highlighted photo instead
    ctrl.append(b);
  }
  const pick = el("span", "pick-box", icon("check", 13));
  pick.title = "Select (S). Shift-click selects a range.";
  t.append(img, el("span", "flag"), mine, pick, el("div", "info", el("span", null, fmtTime(p, false)), p.me ? el("span", "you", "You") : el("span", null, faceText(p))), ctrl);
  paintTile(t, id);
  return t;
}

function paintTile(t, id) {
  const s = eff(id);
  const moved = S.moved.has(id);
  t.classList.remove("s-fav", "s-keep", "s-remove");
  t.classList.add("s-" + s);
  t.classList.toggle("moved", moved);
  const flag = t.querySelector(".flag");
  if (moved) flag.replaceChildren("Moved");
  else flag.replaceChildren(icon(STATE_ICON[s], 12), el("span", "flag-text", STATE_LABEL[s]));
  flag.title = moved ? "Moved to _to_remove" : STATE_LABEL[s];
  t.querySelector(".mine").hidden = !S.decisions[id];
  t.classList.toggle("selected", S.sel.has(id));
  for (const b of t.querySelectorAll(".ctrl button")) b.classList.toggle("on", b.dataset.state === s);
}

function refreshPhoto(id) {
  for (const t of document.querySelectorAll(`.tile[data-id="${id}"]`)) paintTile(t, id);
  const gid = S.photos[id].group;
  if (gid) refreshGroup(gid);
  if (S.lb && S.lb.id === id) paintLightbox();
  else if (S.lb) paintStrip();
}

/* ---------- end of a collection ---------- */

function endPanel() {
  const c = S.view.col, st = S.stats.get(c.id);
  const next = nextCollection(c);
  const p = el("div", "endpanel");
  p.id = "endpanel";
  if (st.left) {
    p.append(icon("check", 20), el("div", "end-text",
      el("b", null, `${plural(st.left, "group")} still to review`),
      el("span", null, "Reviewed groups fold away, so what is left stays near the top.")),
      actionButton("Review next group", () => focusGroup(firstUnreviewed(), "start"), true));
    return p;
  }
  p.classList.add("done");
  const what = !st.groups ? "Nothing to review here" : st.groups === 1 ? "The group is reviewed" : `All ${plural(st.groups, "group")} are reviewed`;
  p.append(icon("check", 20), el("div", "end-text",
    el("b", null, what),
    el("span", null, next ? "Up next: " + colTitle(next) + " · " + colStatus(S.stats.get(next.id)) : "Every trip, event and month is reviewed. Finish when you are ready.")),
    next ? actionButton("Next: " + colTitle(next), () => go(next.id), true) : linkButton("Finish", "finish", "primary"));
  return p;
}

function refreshEnd() {
  const old = $("#endpanel");
  if (old) old.replaceWith(endPanel());
}

function goNextCollection() {
  const next = nextCollection(S.view.col);
  if (next) go(next.id);
  else toast("Everything is reviewed. Finish when you are ready.");
}

/* ---------- finish ---------- */

function finishBody() {
  const wrap = el("div", "finish");
  wrap.id = "finish";
  const m = movePlan(), t = S.total;
  const filedN = Object.keys(S.filed).length;

  // Step one: organize the files by collection. Can happen before the review.
  const rows = S.newestFirst.map((c) => {
    const { toFile, filed, toBack } = folderPlan(c);
    let sub;
    if (c.folderOn) sub = el("span", "frow-sub", toFile ? `${plural(toFile, "photo")} into ` : "All in ", el("code", null, c.folder + "/"));
    else sub = el("span", "frow-sub", toBack ? `${plural(toBack, "photo")} go back where they came from` : "Photos stay where they are");
    if (c.folderOn && filed && toFile) sub.append(` · ${filed.toLocaleString()} already there`);
    const title = el("a", "frow-title", colTitle(c));
    title.href = "#" + c.id;
    return el("div", "frow" + (c.folderOn ? " on" : ""),
      el("span", "kind-ico " + c.kind, icon(c.kind, 15)),
      el("span", "frow-text", title, sub),
      folderSwitch(c, refreshCounts));
  });
  const orgN = m.toFile + m.toBack;
  const orgParts = [];
  if (m.toFile) orgParts.push(`${plural(m.toFile, "photo")} into ${plural(m.folders.length, "folder")}`);
  if (m.toBack) orgParts.push(`${plural(m.toBack, "photo")} back where they came from`);
  const orgTitle = orgN ? orgParts.join(", ")
    : filedN ? "The folders match your collections" : "Switch on the collections that should get a folder";
  wrap.append(el("section", "fcard",
    el("div", "fcard-head",
      el("span", "fcard-ico", icon("folder", 18)),
      el("div", "fcard-text",
        el("h3", null, "Organize files"),
        el("p", "fcard-lead", orgTitle),
        el("p", null, "Every photo of a switched-on trip, event or month moves into a folder named after its date and name. " +
          "You can do this before reviewing: cleaning up later takes the removed photos out of these folders. " +
          "Run it again after renaming or moving photos to keep the folders in line."))),
    el("div", "frows", ...rows),
    stepFoot("organize", orgN, filedN, {
      go: `Organize ${plural(orgN, "photo")}`,
      ask: `Move ${orgParts.join(", and ")} now?`,
      sentence: "Nothing is deleted, and you can keep reviewing afterwards.",
      yes: `Yes, organize ${plural(orgN, "photo")}`,
      idle: filedN ? `${plural(filedN, "photo")} ${filedN === 1 ? "is" : "are"} in collection folders.` : "Nothing is organized into folders yet.",
      undo: "Undo organize",
      undoAsk: `Put the ${plural(filedN, "filed photo")} back where they came from?`,
    })));

  // Step two: clean up, best done once everything is reviewed.
  const see = el("a", "btn small", "See them", icon("arrow", 14));
  see.href = "#remove";
  const open = S.newestFirst.filter((c) => S.stats.get(c.id).left);
  const card = el("section", "fcard",
    el("div", "fcard-head",
      el("span", "fcard-ico remove", icon("trash", 18)),
      el("div", "fcard-text",
        el("h3", null, "Clean up"),
        el("p", "fcard-lead", m.remove ? `${plural(m.remove, "photo")} to remove · ${fmtBytes(m.bytes)}`
          : S.moved.size ? `All marked photos are in _to_remove (${S.moved.size.toLocaleString()})` : "Nothing marked for removal"),
        el("p", null, "Moved into ", el("code", null, `${baseName(S.root)}/_to_remove/`),
          ", from wherever they are now (their collection folder too), keeping their original subfolders. Delete that folder yourself once you are sure.")),
      m.remove ? see : null));
  // Exact copies need no judgment, so they can go first and take their groups off the review list.
  const dupGroups = S.groups.filter((g) => g.kind === "duplicate");
  if (dupGroups.length) {
    let dups = 0, dupBytes = 0, dupOpen = 0;
    for (const g of dupGroups) {
      if (!groupDone(g)) dupOpen++;
      for (const id of g.members) if (live(id) && eff(id) === "remove") { dups++; dupBytes += S.photos[id].size; }
    }
    card.append(el("div", "fcard-part",
      el("div", "fcard-part-text",
        el("b", null, dups ? `${plural(dups, "duplicate copy", "duplicate copies")} · ${fmtBytes(dupBytes)}` : "No duplicate copies left"),
        el("span", null, `Exact copies of photos you keep (like IMG_1 2.JPG next to IMG_1.JPG), in ${plural(dupGroups.length, "group")}. ` +
          "Nothing to judge, so they can go first" + (dupOpen ? `, and their ${plural(dupOpen, "group")} ${dupOpen === 1 ? "is" : "are"} marked reviewed.` : "."))),
      stepFoot("dups", dups, 0, {
        go: "Remove duplicate copies",
        ask: `Move ${plural(dups, "duplicate copy", "duplicate copies")} (${fmtBytes(dupBytes)}) to _to_remove now?`,
        sentence: "Only the extra copies go; the copy you keep stays. Undo clean-up puts them back.",
        yes: "Yes, remove the copies",
        danger: true,
        idle: "",
      })));
  }
  if (open.length) {
    card.append(el("div", "fnote warn", icon("warn", 16),
      el("span", null, `${plural(t.left, "group")} in ${open.length === 1 ? "1 collection" : open.length + " collections"} ${t.left === 1 ? "is" : "are"} not reviewed yet. Their suggestions are used as they are.`),
      linkButton("Keep reviewing", "review", "small")));
  }
  card.append(stepFoot("cleanup", m.remove, S.moved.size, {
    go: `Move ${plural(m.remove, "photo")} to _to_remove`,
    ask: `Move ${plural(m.remove, "photo")} (${fmtBytes(m.bytes)}) to _to_remove now?`,
    sentence: "Nothing is deleted, and Undo clean-up puts them back where they were.",
    yes: `Yes, move ${plural(m.remove, "photo")}`,
    danger: true,
    idle: S.moved.size ? `${plural(S.moved.size, "photo")} ${S.moved.size === 1 ? "is" : "are"} in _to_remove.` : "Nothing is in _to_remove yet.",
    undo: "Undo clean-up",
    undoAsk: `Put the ${plural(S.moved.size, "photo")} in _to_remove back where they were?`,
  }));
  wrap.append(card);
  return wrap;
}

// The footer of a Finish step: its button, an in-page confirm, and its own Undo.
function stepFoot(step, n, done, text) {
  const foot = el("div", "fcard-foot");
  const cancel = () => {
    const b = el("button", "btn ghost", "Cancel");
    b.onclick = () => { S.finish = null; refreshFinish(); };
    return b;
  };
  if (S.finish === step) {
    const yes = el("button", "btn " + (text.danger ? "danger strong" : "primary"), text.yes);
    yes.onclick = () => runStep(step);
    foot.classList.add("confirm");
    if (!text.danger) foot.classList.add("soft");
    foot.append(el("p", "fact-text", el("b", null, text.ask), " " + text.sentence), el("div", "fact-buttons", cancel(), yes));
    return foot;
  }
  if (S.finish === "undo-" + step) {
    const yes = el("button", "btn primary", "Yes, put them back");
    yes.onclick = () => runUndo(step);
    foot.classList.add("confirm", "soft");
    foot.append(el("p", "fact-text", el("b", null, text.undoAsk)), el("div", "fact-buttons", cancel(), yes));
    return foot;
  }
  const buttons = el("div", "fact-buttons");
  if (done) {
    const undo = el("button", "btn ghost", icon("undo", 14), text.undo);
    undo.onclick = () => { S.finish = "undo-" + step; refreshFinish(); };
    buttons.append(undo);
  }
  const go = el("button", "btn " + (text.danger ? "danger strong" : "primary"), n ? text.go : "Nothing to move");
  go.disabled = !n;
  go.onclick = () => { S.finish = step; refreshFinish(); };
  buttons.append(go);
  foot.append(el("p", "fact-text", n ? text.sentence : text.idle), buttons);
  return foot;
}

function refreshFinish() {
  const old = $("#finish");
  if (old) old.replaceWith(finishBody());
}

/* ---------- cursor + keyboard ---------- */

const tileEl = (id) => document.querySelector(`.tile[data-id="${id}"]`);

// Photos of folded groups are skipped by the arrow keys and the viewer.
function hiddenId(id) {
  const item = S.view.itemOf.get(id);
  return !!(item && item.group && collapsed(item.group));
}

function setCursor(id, scroll) {
  S.cursor = id;
  if (scroll) {
    const t = ensureRendered(`.tile[data-id="${id}"]`);
    if (t) t.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }
  markCursor();
}

function markCursor() {
  for (const t of document.querySelectorAll(".tile.cursor")) t.classList.remove("cursor");
  for (const g of document.querySelectorAll(".group.cursor-in")) g.classList.remove("cursor-in");
  const t = S.cursor && tileEl(S.cursor);
  if (!t) return;
  t.classList.add("cursor");
  const g = t.closest(".group");
  if (g) g.classList.add("cursor-in");
}

function focusGroup(g, block = "nearest") {
  if (!g) return;
  if (collapsed(g)) expandGroup(g, true);
  const card = ensureRendered(`.group[data-group="${g.id}"]`);
  S.cursor = S.view.itemOf.get(g.members[0]).order[0];
  markCursor();
  if (card) card.scrollIntoView({ block, behavior: "smooth" });
}

function moveCursor(delta) {
  const flat = S.view.flat;
  if (!flat.length) return;
  let i = flat.indexOf(S.cursor);
  if (i < 0) { i = -1; delta = 1; }
  do i += delta; while (i >= 0 && i < flat.length && hiddenId(flat[i]));
  if (i >= 0 && i < flat.length) setCursor(flat[i], true);
}

// The tile in the row above or below `t` (same day block) that sits closest horizontally.
function rowNeighbor(t, delta) {
  const step = (n) => (delta > 0 ? n.nextElementSibling : n.previousElementSibling);
  const x = t.offsetLeft + t.offsetWidth / 2;
  let best = null, bestDist = Infinity, rowTop = null;
  for (let n = step(t); n; n = step(n)) {
    if (n.offsetTop === t.offsetTop) continue;
    if (rowTop == null) rowTop = n.offsetTop;
    else if (n.offsetTop !== rowTop) break;
    const dist = Math.abs(n.offsetLeft + n.offsetWidth / 2 - x);
    if (dist < bestDist) { best = n; bestDist = dist; }
  }
  return best;
}

const skipItem = (it) => it.section || it.end || (it.group && collapsed(it.group));

// Up / down: between groups, and row by row through loose photos.
function moveVertical(delta) {
  const v = S.view;
  if (!v.flat.length) return;
  const item = v.itemOf.get(S.cursor);
  if (!item || skipItem(item)) {
    const first = v.items.find((it) => !skipItem(it));
    if (!first) return;
    return first.group ? focusGroup(first.group) : setCursor(first.photo, true);
  }

  let from = item.i;
  if (item.photo) {
    const t = tileEl(S.cursor);
    const target = t && rowNeighbor(t, delta);
    if (target) return setCursor(target.dataset.id, true);
    // No further row in this day block: continue from its first or last photo.
    if (t) from = v.itemOf.get((delta > 0 ? t.parentNode.lastElementChild : t.parentNode.firstElementChild).dataset.id).i;
  }
  let i = from + delta;
  while (v.items[i] && skipItem(v.items[i])) i += delta;
  const to = v.items[i];
  if (!to) return;
  if (to.group) focusGroup(to.group);
  else setCursor(to.photo, true);
}

function reviewAndAdvance() {
  const item = S.view.itemOf.get(S.cursor);
  if (!item || !item.group) return;
  const g = item.group;
  if (!groupDone(g)) setReviewed(g, true);
  const next = firstUnreviewed(S.view.groups.indexOf(g) + 1);
  if (next) return focusGroup(next, "start");
  if (S.view.type !== "collection") return toast("All groups here are reviewed.");
  // Last group: show what is left of the collection, then the way on.
  const others = ensureRendered("#others");
  const target = others || ensureRendered("#endpanel");
  if (target) target.scrollIntoView({ block: "start", behavior: "smooth" });
  S.cursor = null;
  markCursor();
  toast(others ? "All groups reviewed. Look over the other photos, then press N for the next collection." : "All groups reviewed. Press N for the next collection.");
}

const openDialogEl = () => document.querySelector(".dialog:not([hidden])");
function openDialog(dlg) {
  dlg.hidden = false;
  dlg.querySelector("[data-close]").focus();
}
function closeDialog(dlg) {
  dlg.hidden = true;
}
const showHelp = (on) => (on ? openDialog($("#help")) : closeDialog($("#help")));

document.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey || !S.view) return;
  if (!$("#menu-pop").hidden) {
    if (e.key === "Escape") { const a = S.menuAnchor; closeMenu(); if (a) a.focus(); e.preventDefault(); }
    return;
  }
  const dlg = openDialogEl();
  if (dlg) { if (e.key === "Escape") closeDialog(dlg); return; }
  const tag = e.target.tagName;
  if (tag === "INPUT" && e.target.type !== "checkbox" || tag === "TEXTAREA" || tag === "SELECT") return;
  if ((tag === "BUTTON" || tag === "A" || tag === "INPUT" || tag === "SUMMARY") && (e.key === "Enter" || e.key === " ")) return;
  const key = e.key.toLowerCase();
  if (S.lb) {
    if (key === "escape") closeLightbox();
    else if (key === "arrowright") lbStep(1);
    else if (key === "arrowleft") lbStep(-1);
    else if (key in KEY_STATE) setStates({ [S.lb.id]: KEY_STATE[key] });
    else return;
    e.preventDefault();
    return;
  }
  const t = S.view.type;
  if (key === "escape" && document.body.classList.contains("nav-open")) setDrawer(false);
  else if (key === "escape" && t === "organize" && S.colSel.size) clearColSel();
  else if (key === "escape" && S.sel.size) clearSelection();
  else if (key === "escape" && S.finish) { S.finish = null; refreshFinish(); }
  else if (key === "?") showHelp(true);
  else if (t === "organize" || t === "finish") return;
  else if (key === "arrowright") moveCursor(1);
  else if (key === "arrowleft") moveCursor(-1);
  else if (key === "arrowdown") moveVertical(1);
  else if (key === "arrowup") moveVertical(-1);
  else if (key === "enter" && S.cursor) openLightbox(S.cursor);
  else if (key === "d" && S.cursor) reviewAndAdvance();
  else if (key === "n" && t === "collection") goNextCollection();
  else if (key === "s" && S.cursor) toggleSelect(S.cursor, e.shiftKey);
  else if (key in KEY_STATE && S.cursor) setStates({ [S.cursor]: KEY_STATE[key] });
  else return;
  e.preventDefault();
});

$("#main").addEventListener("click", (e) => {
  const k = e.target.closest(".keepers");
  if (k) return expandGroup(S.groupById[k.closest(".group").dataset.group], true);
  const t = e.target.closest(".tile");
  if (!t) return;
  const id = t.dataset.id;
  const b = e.target.closest(".ctrl button");
  setCursor(id);
  if (b) setStates({ [id]: b.dataset.state });
  // While selecting, a click anywhere on a photo selects it, like in a photo app.
  else if (e.target.closest(".pick-box") || S.sel.size || e.shiftKey) toggleSelect(id, e.shiftKey);
  else openLightbox(id);
});

// mousemove rather than mouseover: content scrolling under a resting pointer must not steal the highlight.
$("#main").addEventListener("mousemove", (e) => {
  const t = e.target.closest(".tile");
  if (t && t.dataset.id !== S.cursor) setCursor(t.dataset.id);
});

/* ---------- lightbox ---------- */

function openLightbox(id) {
  closeMenu();
  S.lb = { id };
  $("#lightbox").hidden = false;
  document.body.classList.add("locked");
  paintLightbox();
}

function closeLightbox() {
  const id = S.lb && S.lb.id;
  S.lb = null;
  $("#lightbox").hidden = true;
  document.body.classList.remove("locked");
  $("#lb-img").removeAttribute("src");
  delete $("#lb-img").dataset.id;
  if (id) setCursor(id, true);
}

// The photos the viewer steps through: everything in the view except folded groups.
const lbList = () => S.view.flat.filter((id) => !hiddenId(id) || id === S.lb.id);

function lbStep(delta) {
  const flat = lbList();
  const j = flat.indexOf(S.lb.id) + delta;
  if (j < 0 || j >= flat.length) return;
  S.lb.id = flat[j];
  paintLightbox();
}

function paintLightbox() {
  const id = S.lb.id;
  const p = S.photos[id];
  const flat = lbList();
  const pos = flat.indexOf(id);
  const img = $("#lb-img");
  if (img.dataset.id !== id) {
    img.dataset.id = id;
    img.alt = baseName(p.rel);
    img.src = "/thumb/" + id;  // instant placeholder while the full-size image loads
    const full = new Image();
    full.onload = () => { if (img.dataset.id === id) img.src = full.src; };
    full.src = "/full/" + id;
    // Warm the next photo so arrowing through a group feels instant.
    if (flat[pos + 1]) new Image().src = "/full/" + flat[pos + 1];
  }
  const s = eff(id);
  $("#lightbox").className = "lightbox s-" + s + (S.moved.has(id) ? " moved" : "");

  const parts = [fmtTime(p), `${p.w}×${p.h}`, fmtBytes(p.size)];
  if (p.faces) parts.push(faceText(p) + (p.faceQ.length ? ` (quality ${p.faceQ.map((q) => q.toFixed(2)).join(", ")})` : ""));
  parts.push(`score ${p.score.toFixed(2)}`);
  if (p.tags.length) parts.push(p.tags.join(", "));
  if (p.me) parts.push(`you are in this photo (match ${p.meSim.toFixed(2)})`);
  const src = source(id);
  parts.push(src === "you" ? "set by you" : src === "haiku" ? "suggested by Haiku" : "suggested automatically");
  if (src === "auto" && p.reason) parts.push(p.reason.toLowerCase());
  if (S.moved.has(id)) parts.push("moved to _to_remove");
  if (S.filed[id]) parts.push("moved to " + S.filed[id].split("/").slice(0, -1).join("/") + "/");
  const why = S.haiku[id] && S.haiku[id].why;
  const meta = $("#lb-meta");
  meta.replaceChildren(
    el("div", "name", el("span", "pos", `${pos + 1} of ${flat.length}`), p.rel),
    el("div", "facts", parts.join(" · ")));
  if (why) meta.append(el("div", "ai", el("b", null, "Haiku"), why));

  const states = $("#lb-states");
  states.replaceChildren();
  for (const st of STATES) {
    const b = el("button", st + (s === st ? " on" : ""), icon(STATE_ICON[st], 15), STATE_LABEL[st], el("kbd", null, STATE_KEY[st]));
    b.setAttribute("aria-pressed", String(s === st));
    b.onclick = () => setStates({ [id]: st });
    states.append(b);
  }
  $("#lb-prev").disabled = pos <= 0;
  $("#lb-next").disabled = pos >= flat.length - 1;
  paintStrip();
}

// Filmstrip: the whole group in the order it is shown, or the neighbors of a loose photo.
function paintStrip() {
  const id = S.lb.id;
  const item = S.view.itemOf.get(id);
  let ids;
  if (item && item.group) ids = item.order;
  else if (S.photos[id].group) ids = S.groupById[S.photos[id].group].members;
  else {
    const flat = lbList();
    const i = flat.indexOf(id);
    ids = flat.slice(Math.max(0, i - 6), i + 7);
  }
  const strip = $("#lb-strip");
  strip.replaceChildren();
  for (const m of ids) {
    const d = el("button", `mini s-${eff(m)}` + (m === id ? " on" : "") + (S.moved.has(m) ? " moved" : ""), thumb(m));
    d.title = S.moved.has(m) ? "Moved" : STATE_LABEL[eff(m)];
    d.setAttribute("aria-label", baseName(S.photos[m].rel));
    d.onclick = () => { S.lb.id = m; paintLightbox(); };
    strip.append(d);
  }
  const on = strip.querySelector(".on");
  if (on) on.scrollIntoView({ inline: "center", block: "nearest" });
}

$("#lb-close").append(icon("x", 22));
$("#lb-prev").append(icon("prev", 26));
$("#lb-next").append(icon("next", 26));
$("#lb-close").onclick = closeLightbox;
$("#lb-prev").onclick = () => lbStep(-1);
$("#lb-next").onclick = () => lbStep(1);
$("#lightbox").addEventListener("click", (e) => { if (e.target.classList.contains("lb-stage")) closeLightbox(); });

/* ---------- move / undo ---------- */

async function runMove(url, describe, body) {
  try {
    await S.saving;
    const r = await post(url, body);
    S.finish = null;
    await load();
    toast(describe(r) + (r.errors.length ? ` (${r.errors.length} failed: ${r.errors[0]})` : ""), r.errors.length > 0);
  } catch (e) {
    toast("That did not work (" + e.message + "). Is the server still running?", true);
  }
}

function runStep(step) {
  if (step === "organize") {
    runMove("/api/organize", (r) => {
      const done = [];
      if (r.filed) done.push(`Moved ${plural(r.filed, "photo")} into ${plural(r.folders, "folder")}`);
      if (r.back) done.push(`put ${plural(r.back, "photo")} back where they came from`);
      return done.length ? done.join(", ") + "." : "The folders already matched your collections.";
    });
  } else if (step === "dups") {
    runMove("/api/cleanup", (r) => (r.moved ? `Moved ${plural(r.moved, "duplicate copy", "duplicate copies")} to ${r.folder}.` : "No duplicate copies to move.") +
      (r.reviewed ? ` ${plural(r.reviewed, "group")} of duplicates marked reviewed.` : ""), { only: "duplicates" });
  } else {
    runMove("/api/cleanup", (r) => r.moved ? `Moved ${plural(r.moved, "photo")} to ${r.folder}.` : "Nothing needed moving.");
  }
}

function runUndo(step) {
  runMove("/api/undo", (r) => `Put ${plural(r.restored, "photo")} back.` +
    (r.skipped ? ` ${plural(r.skipped, "photo")} ${r.skipped === 1 ? "is" : "are"} in _to_remove and stayed there: undo the clean-up first.` : ""),
  { step });
}

/* ---------- drawer, help, toast, thumbnail size ---------- */

function setDrawer(open) {
  document.body.classList.toggle("nav-open", open);
  $("#scrim").hidden = !open;
  $("#menu").setAttribute("aria-expanded", String(open));
}
$("#menu").append(icon("menu", 20));
$("#menu").onclick = () => setDrawer(!document.body.classList.contains("nav-open"));
$("#scrim").onclick = () => setDrawer(false);
$("#nav").addEventListener("click", (e) => { if (e.target.closest("a")) setDrawer(false); });

let toastTimer;
function toast(msg, err) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.toggle("err", !!err);
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), err ? 9000 : 5000);
}

$("#help-btn").onclick = () => showHelp(true);
for (const dlg of document.querySelectorAll(".dialog")) {
  dlg.addEventListener("click", (e) => { if (e.target === dlg || e.target.closest("[data-close]")) closeDialog(dlg); });
}

const size = $("#size");
size.value = localStorage.getItem("tile") || size.value;
function applySize() {
  document.documentElement.style.setProperty("--tile", size.value + "px");
  document.documentElement.classList.toggle("compact", Number(size.value) < 150);
  localStorage.setItem("tile", size.value);
}
size.oninput = () => { applySize(); fill(); };
applySize();

new IntersectionObserver((entries) => {
  if (entries.some((e) => e.isIntersecting)) fill();
}, { rootMargin: "1200px" }).observe($("#sentinel"));

/* ---------- routing + loading ---------- */

// #review opens the next collection with groups left (or the newest one when all are done).
function parseRoute() {
  let want = decodeURIComponent(location.hash.slice(1));
  if (want === "overview") want = "organize";
  if (want === "review") {
    const c = nextCollection() || S.newestFirst[0];
    if (!c) return S.order.length ? "all" : "organize";
    history.replaceState(null, "", "#" + c.id);
    return c.id;
  }
  if (want === "organize" || want === "finish" || S.colById[want] || LIBRARY_BY_ID[want]) return want;
  return S.collections.length || !S.order.length ? "organize" : "all";
}

function go(route) {
  if (location.hash === "#" + route) showRoute();
  else location.hash = route;  // adds a history entry; the hashchange handler renders
}

function showRoute(keepScroll) {
  S.route = parseRoute();
  renderView();
  if (!keepScroll) window.scrollTo(0, 0);
}

window.addEventListener("hashchange", () => {
  if (S.lb) closeLightbox();
  setDrawer(false);
  showRoute();
});

async function load() {
  const r = await fetch("/api/data");
  if (!r.ok) throw new Error("HTTP " + r.status);
  const d = await r.json();
  S.root = d.root;
  S.photos = d.photos;
  S.order = d.order;
  S.groups = d.groups;
  S.groupById = Object.fromEntries(d.groups.map((g) => [g.id, g]));
  S.collections = d.collections || [];
  S.colById = Object.fromEntries(S.collections.map((c) => [c.id, c]));
  S.newestFirst = [...S.collections].sort((a, b) => b.start - a.start);
  const seen = new Map();
  for (const c of S.collections) if (!c.name) seen.set(defaultTitle(c), (seen.get(defaultTitle(c)) || 0) + 1);
  S.dupTitles = new Set([...seen].filter(([, n]) => n > 1).map(([t]) => t));
  S.decisions = d.decisions;
  S.haiku = d.haiku || {};
  S.moved = new Set(d.moved);
  S.filed = d.filed || {};
  S.reviewed = new Set(d.reviewed || []);
  $("#root").textContent = "‎" + d.root;  // left-to-right mark: the path is clipped from its start
  $("#root").title = d.root;
  recount();
  renderNav();
  showRoute(true);
}

load().catch((e) => {
  $("#main").replaceChildren(el("div", "empty", "Could not load the photo data. Is the server still running?"));
  toast("Could not load data: " + e.message, true);
});
