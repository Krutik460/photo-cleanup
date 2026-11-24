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
};

function icon(name, size = 16) {
  const t = document.createElement("template");
  t.innerHTML = `<svg class="ico" width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
  return t.content.firstChild;
}

const plural = (n, word) => `${n.toLocaleString()} ${word}${n === 1 ? "" : "s"}`;

/* ---------- constants ---------- */

const STATES = ["fav", "keep", "remove"];
const STATE_LABEL = { fav: "Favorite", keep: "Keep", remove: "Remove" };
const STATE_ICON = { fav: "star", keep: "check", remove: "x" };
const STATE_KEY = { fav: "F", keep: "K", remove: "X" };
const KEY_STATE = { f: "fav", k: "keep", x: "remove", u: null };
const GROUP_KIND = { duplicate: "Duplicates", "near-duplicate": "Near-duplicates", similar: "Similar shots" };
const COLLECTION_KIND = { trip: "Trip", daytrip: "Day trip", event: "Event", everyday: "Everyday" };

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
  decisions: {}, haiku: {}, moved: new Set(), names: {}, reviewed: new Set(),
  total: null, stats: new Map(),
  route: "overview", view: null, rendered: 0, lastDay: null, wrap: null,
  cursor: null, nextId: null, renaming: false, navRefs: new Map(),
  lb: null, saving: Promise.resolve(), pending: 0,
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
  updateNext();
  refreshGroup(g.id);
  refreshCounts();
  save("/api/reviewed", { ids: g.members, reviewed: on });
}

async function post(url, body) {
  const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
  if (!r.ok) throw new Error("HTTP " + r.status);
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
const colName = (c) => S.names[c.members[0]] || "";

function defaultTitle(c) {
  switch (c.kind) {
    case "trip": return "Trip · " + fmtRange(c);
    case "daytrip": return "Day trip · " + fmtDate(c.start, c.timeKnown, { weekday: "short", month: "short", day: "numeric" });
    case "event": return "Event · " + fmtDate(c.start, c.timeKnown, { weekday: "long", month: "short", day: "numeric" });
    default: return "Everyday · " + fmtDate(c.start, c.timeKnown, { month: "long" });
  }
}
const colTitle = (c) => colName(c) || defaultTitle(c);

// The line under a title: what kind of collection it is, when, and how far from home.
function colMeta(c) {
  const parts = [];
  if (colName(c)) parts.push(COLLECTION_KIND[c.kind]);
  parts.push(fmtRange(c, true));
  if (c.kind === "trip") parts.push(plural(c.days, "day"));
  if ((c.kind === "trip" || c.kind === "daytrip") && c.homeKm != null) parts.push(`about ${c.homeKm.toLocaleString()} km from home`);
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

function buildView(route) {
  const v = { route, type: "overview", title: "Overview", items: [], groups: [], flat: [], itemOf: new Map() };
  const c = S.colById[route];
  const lib = LIBRARY_BY_ID[route];
  if (c) {
    v.type = "collection";
    v.col = c;
    v.title = colTitle(c);
    v.groups = c.groups.map((id) => S.groupById[id]);
    const singles = c.members.filter((id) => !S.photos[id].group);
    if (v.groups.length) v.items.push({ section: "Groups to clean up", count: v.groups.length }, ...v.groups.map((g) => ({ group: g })));
    if (singles.length) v.items.push({ section: v.groups.length ? "Other photos" : "Photos", count: singles.length }, ...singles.map((id) => ({ photo: id })));
  } else if (lib) {
    v.type = "library";
    v.lib = lib;
    v.title = lib.label;
    if (lib.groups) {
      v.groups = lib.groups();
      v.items = v.groups.map((g) => ({ group: g }));
    } else {
      v.items = lib.photos().map((id) => ({ photo: id }));
    }
  }
  v.items.forEach((item, i) => {
    item.i = i;
    for (const id of item.group ? item.group.members : item.photo ? [item.photo] : []) {
      v.flat.push(id);
      v.itemOf.set(id, item);
    }
  });
  return v;
}

function libraryCount(lib) {
  return lib.groups ? lib.groups().length : lib.photos().filter(live).length;
}

function renderView() {
  const v = (S.view = buildView(S.route));
  S.rendered = 0;
  S.lastDay = null;
  S.wrap = null;
  S.renaming = false;
  if (S.cursor && !v.itemOf.has(S.cursor)) S.cursor = null;
  S.nextId = (firstUnreviewed() || {}).id || null;
  document.title = v.title + " - Photo cleanup";
  paintCrumbs();
  for (const a of document.querySelectorAll(".nav-item")) {
    const on = a.dataset.route === v.route;
    a.classList.toggle("on", on);
    if (on) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
  }

  const main = $("#main");
  main.replaceChildren(viewHead());
  if (v.type === "overview") main.append(overviewBody());
  else if (!v.flat.length) main.append(el("div", "empty", v.lib.empty || "Nothing here."));
  else fill();
  markCursor();
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
      main.append(el("h3", "section", item.section, el("span", "n", item.count.toLocaleString())));
      S.wrap = S.lastDay = null;
    } else if (item.group) {
      main.append(groupCard(item.group));
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

/* ---------- view header ---------- */

function statBlock(value, label, cls) {
  return el("div", "stat" + (cls ? " " + cls : ""), el("b", null, value), el("span", null, label));
}

function progressBar(st) {
  const bar = el("span", "bar" + (st.groups && !st.left ? " full" : ""), el("i"));
  bar.firstChild.style.width = (st.groups ? (st.done / st.groups) * 100 : 0) + "%";
  return bar;
}

function progressBox(st, action) {
  const label = st.groups
    ? `${st.done.toLocaleString()} of ${plural(st.groups, "group")} reviewed`
    : "No near-identical photos here, nothing to review";
  return el("div", "progress-box", el("div", "progress-text", el("span", null, label), st.groups ? progressBar(st) : null), action);
}

function actionButton(label, onClick, primary) {
  const b = el("button", "btn" + (primary ? " primary" : ""), label, icon("arrow", 15));
  b.onclick = onClick;
  return b;
}

function viewHead() {
  const v = S.view;
  const head = el("header", "vhead");
  head.id = "vhead";

  if (v.type === "collection") {
    const c = v.col, st = S.stats.get(c.id);
    const rename = el("button", "btn ghost small", "Rename");
    rename.onclick = startRename;
    head.append(el("div", "vhead-top",
      el("span", "kind-ico big " + c.kind, icon(c.kind, 22)),
      el("div", "vhead-text",
        el("div", "title-row", el("h2", null, colTitle(c)), rename),
        el("p", "vmeta", colMeta(c)))));
    let action = null;
    if (st.left) action = actionButton("Review next group", () => focusGroup(firstUnreviewed(), "start"), true);
    else {
      const next = nextCollection(c);
      if (next) action = actionButton("Next: " + colTitle(next), () => go(next.id), st.groups > 0);
    }
    head.append(el("div", "vhead-bottom",
      el("div", "stats",
        statBlock(st.photos.toLocaleString(), st.photos === 1 ? "photo" : "photos"),
        statBlock(st.fav.toLocaleString(), st.fav === 1 ? "favorite" : "favorites", "fav"),
        statBlock(st.remove.toLocaleString(), "to remove" + (st.remove ? " · " + fmtBytes(st.bytes) : ""), "remove")),
      progressBox(st, action)));
    return head;
  }

  if (v.type === "overview") {
    const t = S.total;
    head.append(el("div", "vhead-top", el("div", "vhead-text",
      el("div", "title-row", el("h2", null, "Overview")),
      el("p", "vmeta", "Your photos by trip and event. Open one to clean it up, newest first."))));
    head.append(el("div", "vhead-bottom",
      el("div", "stats",
        statBlock(t.photos.toLocaleString(), t.photos === 1 ? "photo" : "photos"),
        statBlock(S.collections.length.toLocaleString(), "trips, events and months"),
        statBlock(t.fav.toLocaleString(), t.fav === 1 ? "favorite" : "favorites", "fav"),
        statBlock(t.remove.toLocaleString(), "to remove" + (t.remove ? " · " + fmtBytes(t.bytes) : ""), "remove")),
      progressBox(t, null)));
    return head;
  }

  const count = libraryCount(v.lib);
  head.append(el("div", "vhead-top", el("div", "vhead-text",
    el("div", "title-row", el("h2", null, v.title), el("span", "title-count", count.toLocaleString())),
    el("p", "vmeta", v.lib.hint))));
  if (v.groups.length) {
    const st = progress(v.groups);
    const action = st.left ? actionButton("Review next group", () => focusGroup(firstUnreviewed(), "start"), true) : null;
    head.append(el("div", "vhead-bottom", progressBox(st, action)));
  }
  return head;
}

function refreshHead() {
  if (S.renaming) return;
  const old = $("#vhead");
  if (old) old.replaceWith(viewHead());
}

function startRename() {
  const c = S.view.col;
  S.renaming = true;
  const input = el("input", "rename-input");
  input.type = "text";
  input.maxLength = 80;
  input.value = colName(c);
  input.placeholder = defaultTitle(c);
  input.setAttribute("aria-label", "Name for this collection");
  const saveBtn = el("button", "btn primary small", "Save");
  const cancelBtn = el("button", "btn ghost small", "Cancel");
  const done = () => { S.renaming = false; refreshHead(); };
  const commit = async () => {
    const name = input.value.trim();
    if (name === colName(c)) return done();
    try {
      S.names = (await post("/api/name", { id: c.members[0], name })).names;
      S.view.title = colTitle(c);
      document.title = S.view.title + " - Photo cleanup";
      paintCrumbs();
      paintNav();
    } catch (e) {
      toast("Could not save the name (" + e.message + "). Is the server still running?", true);
    }
    done();
  };
  input.onkeydown = (e) => {
    if (e.key === "Enter") commit();
    else if (e.key === "Escape") done();
  };
  saveBtn.onclick = commit;
  cancelBtn.onclick = done;
  $("#vhead .title-row").replaceChildren(input, saveBtn, cancelBtn);
  input.focus();
  input.select();
}

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

  const overview = link("overview");
  overview.append(el("span", "nav-ico", icon("overview", 16)), el("span", "nav-title", "Overview"));
  nav.append(overview);

  nav.append(el("div", "nav-label", "Library"));
  for (const lib of LIBRARY) {
    const a = link(lib.id, "lib");
    const count = el("span", "nav-count");
    a.append(el("span", "nav-title", lib.label), count);
    S.navRefs.set(lib.id, { count });
    nav.append(a);
  }

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
    el("div", "totals-row",
      el("span", null, plural(t.photos, "photo")),
      el("span", "fav", icon("star", 12), t.fav.toLocaleString()),
      el("span", "remove", icon("x", 12), t.remove.toLocaleString() + (t.remove ? " · " + fmtBytes(t.bytes) : ""))),
    el("div", "totals-progress",
      el("span", null, t.groups ? `${t.done.toLocaleString()} of ${plural(t.groups, "group")} reviewed` : "No groups to review"),
      t.groups ? progressBar(t) : null));
}

function paintCrumbs() {
  const v = S.view;
  const crumbs = $("#crumbs");
  if (v.type === "overview") return crumbs.replaceChildren(el("span", "here", "Overview"));
  const home = el("a", null, "Overview");
  home.href = "#overview";
  crumbs.replaceChildren(home, el("span", "sep", "/"), el("span", "here", v.title));
}

function paintApply() {
  const t = S.total;
  const apply = $("#apply");
  apply.replaceChildren(...(t.remove
    ? ["Move " + t.remove.toLocaleString(), el("span", "long", t.remove === 1 ? "marked photo" : "marked photos")]
    : ["Nothing to move"]));
  apply.disabled = !t.remove;
  apply.title = t.remove ? `Move ${plural(t.remove, "photo")} (${fmtBytes(t.bytes)}) into _to_remove. Nothing is deleted.` : "";
  $("#undo").hidden = S.moved.size === 0;
}

function refreshCounts() {
  recount();
  paintNav();
  paintApply();
  refreshHead();
}

/* ---------- overview ---------- */

function overviewBody() {
  const wrap = el("div", "overview");
  if (!S.collections.length) {
    const all = el("a", "btn", "Open all photos");
    all.href = "#all";
    wrap.append(el("div", "empty", el("p", null, "No trips or events were found in this folder."), all));
    return wrap;
  }

  const next = nextCollection();
  if (next) {
    const st = S.stats.get(next.id);
    const a = el("a", "upnext");
    a.href = "#" + next.id;
    a.append(
      thumb(colCover(next), "upnext-cover"),
      el("div", "upnext-text",
        el("span", "upnext-label", st.done ? "Continue where you left off" : "Up next"),
        el("span", "upnext-title", colTitle(next)),
        el("span", "upnext-sub", colMeta(next) + " · " + colStatus(st))),
      el("span", "btn primary", st.done ? "Continue" : "Start reviewing", icon("arrow", 15)));
    wrap.append(a);
  } else if (S.total.groups) {
    wrap.append(el("div", "alldone", icon("check", 18),
      el("span", null, S.total.remove
        ? "Every group is reviewed. Move the marked photos when you are ready."
        : "Every group is reviewed and nothing is marked for removal.")));
  }

  let year = null, grid = null;
  for (const c of S.newestFirst) {
    if (colYear(c) !== year) {
      year = colYear(c);
      grid = el("div", "cards");
      wrap.append(el("h3", "section", year), grid);
    }
    grid.append(collectionCard(c));
  }
  return wrap;
}

function thumb(id, cls) {
  const img = el("img", cls);
  img.loading = "lazy";
  img.decoding = "async";
  img.alt = "";
  if (id) img.src = "/thumb/" + id;
  return img;
}

function collectionCard(c) {
  const st = S.stats.get(c.id);
  const a = el("a", "card-col" + (st.groups && !st.left ? " done" : ""));
  a.href = "#" + c.id;
  const counts = [plural(st.photos, "photo")];
  if (st.fav) counts.push(plural(st.fav, "favorite"));
  if (st.remove) counts.push(`${st.remove.toLocaleString()} to remove`);
  a.append(
    el("div", "card-cover", thumb(colCover(c)), el("span", "kind-tag " + c.kind, icon(c.kind, 13), COLLECTION_KIND[c.kind])),
    el("div", "card-body",
      el("span", "card-title", colTitle(c)),
      el("span", "card-meta", colMeta(c)),
      el("span", "card-counts", counts.join(" · ")),
      el("span", "card-progress",
        st.groups ? progressBar(st) : null,
        el("span", st.left ? "todo" : null, st.groups ? (st.left ? colStatus(st) : "All groups reviewed") : "No groups to review"))));
  return a;
}

/* ---------- groups + tiles ---------- */

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

function groupCard(g) {
  const card = el("section", "group");
  card.dataset.group = g.id;
  paintGroup(card, g);
  const why = groupWhy(g);
  card.append(groupHead(g));
  if (why) card.append(el("div", "why", el("b", null, "Haiku"), why));
  const tiles = el("div", "tiles");
  for (const id of g.members) tiles.append(tile(id));
  card.append(tiles);
  return card;
}

function paintGroup(card, g) {
  card.classList.toggle("done", groupDone(g));
  card.classList.toggle("next", g.id === S.nextId);
}

function refreshGroup(gid) {
  const card = document.querySelector(`.group[data-group="${gid}"]`);
  if (!card) return;
  paintGroup(card, S.groupById[gid]);
  card.querySelector(".ghead").replaceWith(groupHead(S.groupById[gid]));
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

  const info = el("div", "ginfo");
  info.append(el("span", "title", plural(g.members.length, "photo")), el("span", "meta", fmtTime(S.photos[g.members[0]])));
  const c = S.view.type !== "collection" && S.colById[g.collection];
  if (c) {
    const a = el("a", "meta link", colTitle(c));
    a.href = "#" + c.id;
    info.append(a);
  }
  if (g.id === S.nextId) info.append(el("span", "badge next", "Next up"));
  info.append(el("span", "badge", GROUP_KIND[g.kind] || g.kind));
  if (g.you) info.append(el("span", "badge you", "You"));
  if (g.members.some((id) => S.haiku[id])) {
    const b = el("span", "badge ai", "Reviewed by Haiku");
    b.title = groupWhy(g);
    info.append(b);
  } else if (g.close) info.append(el("span", "badge close", "Close call"));
  if (g.members.some((id) => S.decisions[id])) info.append(el("span", "badge edited", el("i", "dot"), "Edited by you"));
  if (movedCount) info.append(el("span", "badge", `${movedCount} moved`));
  info.append(el("span", "outcome", `Keeping ${t.photos - t.remove}, removing ${t.remove}`));

  const keepAll = el("button", "btn small", "Keep all");
  keepAll.onclick = () => setStates(Object.fromEntries(g.members.map((id) => [id, eff(id) === "fav" ? "fav" : "keep"])));
  const reset = el("button", "btn small ghost", "Reset to suggestion");
  reset.onclick = () => setStates(Object.fromEntries(g.members.map((id) => [id, null])));
  const review = el("button", "btn small review" + (done ? " on" : ""), icon("check", 13), done ? "Reviewed" : "Mark reviewed");
  review.title = done ? "Click to mark as not reviewed" : "Mark this group as reviewed (D)";
  review.setAttribute("aria-pressed", String(done));
  review.onclick = () => setReviewed(g, !done);
  head.append(info, el("div", "gactions", keepAll, reset, review));
  return head;
}

function tile(id) {
  const p = S.photos[id];
  const t = el("div", "tile");
  t.dataset.id = id;
  t.title = p.reason ? `${p.rel}\n${p.reason}` : p.rel;
  t.classList.toggle("is-you", !!p.me);
  t.style.setProperty("--r", String(Math.min(2, Math.max(0.5, p.w && p.h ? p.w / p.h : 1))));
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
  t.append(img, el("span", "flag"), mine, el("div", "info", el("span", null, fmtTime(p, false)), p.me ? el("span", "you", "You") : el("span", null, faceText(p))), ctrl);
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
  t.querySelector(".mine").hidden = !S.decisions[id];
  for (const b of t.querySelectorAll(".ctrl button")) b.classList.toggle("on", b.dataset.state === s);
}

function refreshPhoto(id) {
  for (const t of document.querySelectorAll(`.tile[data-id="${id}"]`)) paintTile(t, id);
  const gid = S.photos[id].group;
  if (gid) refreshGroup(gid);
  if (S.lb && S.lb.id === id) paintLightbox();
  else if (S.lb) paintStrip();
}

/* ---------- cursor + keyboard ---------- */

const tileEl = (id) => document.querySelector(`.tile[data-id="${id}"]`);

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
  const card = ensureRendered(`.group[data-group="${g.id}"]`);
  S.cursor = g.members[0];
  markCursor();
  if (card) card.scrollIntoView({ block, behavior: "smooth" });
}

function moveCursor(delta) {
  const flat = S.view.flat;
  if (!flat.length) return;
  const i = flat.indexOf(S.cursor);
  const next = i < 0 ? 0 : Math.min(flat.length - 1, Math.max(0, i + delta));
  setCursor(flat[next], true);
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

// Up / down: between groups, and row by row through loose photos.
function moveVertical(delta) {
  const v = S.view;
  if (!v.flat.length) return;
  const item = v.itemOf.get(S.cursor);
  if (!item) return v.items.find((it) => it.group) ? focusGroup(v.items.find((it) => it.group).group) : setCursor(v.flat[0], true);

  let from = item.i;
  if (item.photo) {
    const t = tileEl(S.cursor);
    const target = t && rowNeighbor(t, delta);
    if (target) return setCursor(target.dataset.id, true);
    // No further row in this day block: continue from its first or last photo.
    if (t) from = v.itemOf.get((delta > 0 ? t.parentNode.lastElementChild : t.parentNode.firstElementChild).dataset.id).i;
  }
  let i = from + delta;
  while (v.items[i] && v.items[i].section) i += delta;
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
  if (next) focusGroup(next, "start");
  else toast(S.view.type === "collection" ? "All groups in this collection are reviewed." : "All groups here are reviewed.");
}

const helpOpen = () => !$("#help").hidden;
function showHelp(on) {
  $("#help").hidden = !on;
  if (on) $("#help [data-close]").focus();
}

document.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey || !S.view) return;
  if (helpOpen()) { if (e.key === "Escape") showHelp(false); return; }
  const tag = e.target.tagName;
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
  if ((tag === "BUTTON" || tag === "A") && (e.key === "Enter" || e.key === " ")) return;
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
  if (key === "escape" && document.body.classList.contains("nav-open")) setDrawer(false);
  else if (key === "?") showHelp(true);
  else if (S.view.type === "overview") return;
  else if (key === "arrowright") moveCursor(1);
  else if (key === "arrowleft") moveCursor(-1);
  else if (key === "arrowdown") moveVertical(1);
  else if (key === "arrowup") moveVertical(-1);
  else if (key === "enter" && S.cursor) openLightbox(S.cursor);
  else if (key === "d" && S.cursor) reviewAndAdvance();
  else if (key in KEY_STATE && S.cursor) setStates({ [S.cursor]: KEY_STATE[key] });
  else return;
  e.preventDefault();
});

$("#main").addEventListener("click", (e) => {
  const t = e.target.closest(".tile");
  if (!t) return;
  const id = t.dataset.id;
  const b = e.target.closest(".ctrl button");
  setCursor(id);
  if (b) setStates({ [id]: b.dataset.state });
  else openLightbox(id);
});

// mousemove rather than mouseover: content scrolling under a resting pointer must not steal the highlight.
$("#main").addEventListener("mousemove", (e) => {
  const t = e.target.closest(".tile");
  if (t && t.dataset.id !== S.cursor) setCursor(t.dataset.id);
});

/* ---------- lightbox ---------- */

function openLightbox(id) {
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

function lbStep(delta) {
  const flat = S.view.flat;
  const j = flat.indexOf(S.lb.id) + delta;
  if (j < 0 || j >= flat.length) return;
  S.lb.id = flat[j];
  paintLightbox();
}

function paintLightbox() {
  const id = S.lb.id;
  const p = S.photos[id];
  const flat = S.view.flat;
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

// Filmstrip: the whole group, or the neighbors of a loose photo.
function paintStrip() {
  const id = S.lb.id;
  const p = S.photos[id];
  let ids;
  if (p.group) ids = S.groupById[p.group].members;
  else {
    const i = S.view.flat.indexOf(id);
    ids = S.view.flat.slice(Math.max(0, i - 6), i + 7);
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

async function runMove(url, describe) {
  try {
    await S.saving;
    const r = await post(url);
    await load();
    toast(describe(r) + (r.errors.length ? ` (${r.errors.length} failed: ${r.errors[0]})` : ""), r.errors.length > 0);
  } catch (e) {
    toast("That did not work (" + e.message + "). Is the server still running?", true);
  }
}

$("#apply").onclick = () => {
  const { remove, bytes } = S.total;
  if (!remove) return;
  const ok = confirm(`Move ${remove.toLocaleString()} photos (${fmtBytes(bytes)}) marked "Remove" into\n\n${S.root}/_to_remove\n\nNothing is deleted. You can undo this from this page, or delete that folder yourself once you are sure.`);
  if (ok) runMove("/api/apply", (r) => `Moved ${r.moved} photos to ${r.folder}`);
};

$("#undo").onclick = () => {
  if (!confirm(`Put all ${S.moved.size.toLocaleString()} moved photos back where they were?`)) return;
  runMove("/api/undo", (r) => `Restored ${r.restored} photos`);
};

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
$("#help").addEventListener("click", (e) => { if (e.target.id === "help" || e.target.dataset.close != null) showHelp(false); });

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

function parseRoute() {
  const want = decodeURIComponent(location.hash.slice(1));
  if (S.colById[want] || LIBRARY_BY_ID[want]) return want;
  return S.collections.length || !S.order.length ? "overview" : "all";
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
  S.decisions = d.decisions;
  S.haiku = d.haiku || {};
  S.moved = new Set(d.moved);
  S.names = d.names || {};
  S.reviewed = new Set(d.reviewed || []);
  $("#root").textContent = "\u200e" + d.root;  // left-to-right mark: the path is clipped from its start
  $("#root").title = d.root;
  recount();
  renderNav();
  paintApply();
  showRoute(true);
}

load().catch((e) => {
  $("#main").replaceChildren(el("div", "empty", "Could not load the photo data. Is the server still running?"));
  toast("Could not load data: " + e.message, true);
});
