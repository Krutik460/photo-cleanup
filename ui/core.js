'use strict';
/* Shared by every screen: small helpers, icons, requests, and the open folder's data with everything
   derived from it. Classic scripts on purpose: no build step, and the files share these names. */

const $ = (s, r) => (r || document).querySelector(s);
const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (m) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
const num = (n) => Number(n).toLocaleString();
const pl = (n, w, many) => num(n) + ' ' + (n === 1 ? w : many || w + 's');
const isAre = (n) => (n === 1 ? 'is' : 'are');
const reduced = matchMedia('(prefers-reduced-motion: reduce)');

function bytes(n) {
  const u = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = n || 0;
  while (v >= 1000 && i < 4) { v /= 1000; i++; }
  const s = i === 0 ? String(v) : v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2);
  return { n: s, u: u[i], t: s + ' ' + u[i] };
}

/* ---------- icons ---------- */
const I = {
  chevL: '<path d="M14.5 5.5 8 12l6.5 6.5"/>',
  chevR: '<path d="M9.5 5.5 16 12l-6.500 6.500"/>',
  chevD: '<path d="m5.500 9 6.500 6.500L18.500 9"/>',
  search: '<circle cx="11" cy="11" r="6.3"/><path d="m15.8 15.8 4.4 4.4"/>',
  scan: '<path d="M4 8.5V6.2A2.2 2.2 0 0 1 6.2 4h2.3M15.5 4h2.3A2.2 2.2 0 0 1 20 6.2v2.3M20 15.5v2.3a2.2 2.2 0 0 1-2.2 2.2h-2.3M8.5 20H6.2A2.2 2.2 0 0 1 4 17.8v-2.3M8 12h8"/>',
  check: '<path d="m5.5 12.6 4.2 4.2 8.8-9.4"/>',
  x: '<path d="m6.8 6.8 10.4 10.4M17.2 6.8 6.8 17.2"/>',
  plus: '<path d="M12 5.5v13M5.5 12h13"/>',
  folder: '<path d="M3.5 7.8a2 2 0 0 1 2-2h3.4l2 2.2h7.600a2 2 0 0 1 2 2v7.200a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/>',
  grid: '<rect x="4" y="4" width="6.8" height="6.8" rx="1.8"/><rect x="13.2" y="4" width="6.8" height="6.8" rx="1.8"/><rect x="4" y="13.2" width="6.8" height="6.8" rx="1.8"/><rect x="13.2" y="13.2" width="6.8" height="6.8" rx="1.8"/>',
  merge: '<path d="M6 4v3.5a6 6 0 0 0 6 6V20M18 4v3.5a6 6 0 0 1-6 6M8.8 17l3.2 3.2 3.2-3.2"/>',
  split: '<path d="M12 20v-6.500M12 13.500 6.500 7M12 13.500 17.500 7M6.500 11V7h4M17.500 11V7h-4"/>',
  pencil: '<path d="m4.5 19.5.9-4L16.600 4.300a2 2 0 0 1 2.900 0l.2.2a2 2 0 0 1 0 2.900L8.500 18.600z"/>',
  person: '<circle cx="12" cy="8.2" r="3.6"/><path d="M5 19.8c.9-3.500 3.600-5.300 7-5.300s6.100 1.800 7 5.300"/>',
  unplug: '<circle cx="12" cy="12" r="8"/><path d="m6.5 6.5 11 11"/>',
  arrowR: '<path d="M5 12h14M13.5 6.5 19 12l-5.500 5.500"/>',
  undo: '<path d="M8.500 13.500 4 9l4.500-4.500"/><path d="M4 9h9.500a5.500 5.500 0 0 1 0 11H11"/>',
  trash: '<path d="M4.500 7h15M9.500 7V4.500h5V7M6.500 7l1 13h9l1-13"/>',
  warn: '<path d="M12 4.200 20.800 19.500H3.200z"/><path d="M12 10v4.200M12 17.100v.1"/>',
  copy: '<rect x="8.500" y="8.500" width="11" height="11" rx="2.500"/><path d="M15.500 8.500V6.500a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h2"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 3.500v2.200M12 18.300v2.200M3.500 12h2.200M18.300 12h2.200M6 6l1.600 1.600M16.400 16.400 18 18M18 6l-1.600 1.600M7.600 16.400 6 18"/>',
  help: '<circle cx="12" cy="12" r="8.200"/><path d="M9.600 9.600a2.500 2.500 0 1 1 3.600 2.300c-.8.4-1.200 1-1.200 1.800M12 16.700v.1"/>',
  stop: '<rect x="7" y="7" width="10" height="10" rx="2"/>',
  eye: '<path d="M2.800 12S6.200 6 12 6s9.200 6 9.200 6-3.400 6-9.200 6-9.200-6-9.200-6z"/><circle cx="12" cy="12" r="2.600"/>',
  photos: '<rect x="3.500" y="5" width="17" height="14" rx="2.500"/><path d="m3.800 16.200 4.700-4.700 3.800 3.800 2.700-2.700 5.200 5.200"/><circle cx="15.500" cy="9.300" r="1.300"/>',
  stack: '<rect x="7" y="7.500" width="13" height="12" rx="2.300"/><path d="M4 16V6.800A2.300 2.300 0 0 1 6.300 4.500H16"/>',
  scale: '<path d="M12 4.500v15M7.500 19.500h9M5 8.500 12 6l7 2.500M5 8.500 2.800 14a2.600 2.600 0 0 0 4.400 0zM19 8.500 16.800 14a2.600 2.600 0 0 0 4.400 0z"/>',
  one: '<rect x="5" y="5" width="14" height="14" rx="2.500"/>',
  blur: '<circle cx="12" cy="12" r="7.500" stroke-dasharray="2.200 3.200"/><circle cx="12" cy="12" r="2.500"/>',
  doc: '<path d="M7 3.500h7l4 4V19a1.500 1.500 0 0 1-1.500 1.500h-9.500A1.500 1.500 0 0 1 5.500 19V5A1.500 1.500 0 0 1 7 3.500z"/><path d="M13.500 3.800V8h4M8.500 12.500h7M8.500 16h5"/>',
  trip: '<path d="M3 19 9.500 8l4 6.500L16 11l5 8z"/>',
  daytrip: '<circle cx="12" cy="12" r="3.500"/><path d="M12 3.500v2M12 18.500v2M3.500 12h2M18.500 12h2M6 6l1.400 1.400M16.600 16.600 18 18M18 6l-1.400 1.400M7.400 16.600 6 18"/>',
  event: '<rect x="4" y="5.500" width="16" height="14" rx="2"/><path d="M4 10h16M8.500 3.500v4M15.500 3.500v4"/>',
  everyday: '<path d="m4 11 8-7 8 7"/><path d="M6 9.500V20h12V9.500"/>',
  terminal: '<rect x="3.500" y="5" width="17" height="14" rx="2.500"/><path d="m7.500 10 3 2.500-3 2.500M13 15h3.500"/>',
  finder: '<rect x="4" y="4.500" width="16" height="15" rx="3"/><path d="M12 4.500c-1 3-1.200 5.500-1.200 8h2.400c0 2.500.3 4.500.8 7M8.300 9v1.200M15.700 9v1.200M8 15c2.300 1.500 5.700 1.500 8 0"/>',
  film: '<rect x="3.500" y="5.500" width="12.500" height="13" rx="2.500"/><path d="m16 10.300 4.500-2.600v8.600L16 13.700"/>',
  expand: '<path d="M9 4.500H4.500V9M15 4.500h4.500V9M9 19.500H4.500V15M15 19.500h4.500V15"/>',
};
const SOLID = {
  star: '<path d="m12 3.3 2.7 5.5 6 .9-4.400 4.200 1.100 6L12 17l-5.400 2.900 1.100-6-4.400-4.200 6-.9z"/>',
  spark: '<path d="m10.5 3 1.9 5.100 5.100 1.900-5.100 1.900-1.900 5.100-1.900-5.100L3.500 10l5.100-1.900zM18.500 14l.9 2.600 2.600.9-2.600.9-.9 2.600-.9-2.600-2.600-.9 2.600-.9z"/>',
  more: '<circle cx="5.500" cy="12" r="1.700"/><circle cx="12" cy="12" r="1.700"/><circle cx="18.500" cy="12" r="1.700"/>',
  play: '<path d="M8.300 5.200v13.600a.9.9 0 0 0 1.400.8l10.300-6.800a.9.9 0 0 0 0-1.500L9.700 4.400a.9.9 0 0 0-1.400.8z"/>',
};
function ic(name, size, cls) {
  const s = size || 16, c = cls ? ' class="' + cls + '"' : '';
  if (SOLID[name]) return '<svg' + c + ' width="' + s + '" height="' + s + '" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">' + SOLID[name] + '</svg>';
  return '<svg' + c + ' width="' + s + '" height="' + s + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + I[name] + '</svg>';
}
function ring(pct, size, cls) {
  const c = 2 * Math.PI * 15;
  return '<svg class="ring' + (cls ? ' ' + cls : '') + '" width="' + size + '" height="' + size + '" viewBox="0 0 36 36"><circle class="tr" cx="18" cy="18" r="15"/><circle class="pr" cx="18" cy="18" r="15" transform="rotate(-90 18 18)" stroke-dasharray="' + c.toFixed(2) + '" stroke-dashoffset="' + (c * (1 - Math.max(0, Math.min(1, pct)))).toFixed(2) + '"/></svg>';
}

/* ---------- pictures: three sizes of every photo ---------- */
const thumbSrc = (id) => '/thumb/' + id;  // 480 px, made by the scan
const midSrc = (id) => '/mid/' + id;      // 1,280 px, for covers and the large favorite
const fullSrc = (id) => '/full/' + id;
const videoSrc = (id) => '/video/' + id;  // the file itself, played in parts
const img = (src, cls) => '<img' + (cls ? ' class="' + cls + '"' : '') + ' src="' + src + '" alt="" draggable="false" decoding="async" loading="lazy">';
function mosaic(srcs) {
  const a = srcs.slice(0, 4);
  return '<div class="mosaic m' + (a.length || 1) + '">' + a.map((s) => img(s)).join('') + '</div>';
}

/* ---------- requests ---------- */
async function call(url, body) {
  const r = await fetch(url, body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const j = await r.json().catch(() => null);
  if (!r.ok) throw new Error((j && j.error) || 'HTTP ' + r.status);  // the app explains what went wrong when it can
  return j;
}

// Saves run one after another, so a slow request can never overwrite a newer one.
const Q = { chain: Promise.resolve(), pending: 0 };
function save(url, body) {
  Q.pending++;
  paintSave('busy');
  Q.chain = Q.chain
    .then(() => call(url, body))
    .then(() => { if (--Q.pending === 0) paintSave('ok'); })
    .catch((e) => {
      Q.pending--;
      paintSave('err');
      toast('Could not save your change: ' + e.message, 'err');
    });
}
function paintSave(kind) {
  const el = $('#savest');
  if (!el) return;
  el.className = 'savest ' + kind;
  el.textContent = kind === 'busy' ? 'Saving' : kind === 'err' ? 'Not saved' : 'Saved';
}

/* ---------- the open folder ---------- */
const KIND = { trip: 'Trip', daytrip: 'Day trip', event: 'Event', everyday: 'Everyday' };
const KINDS = { trip: 'Trips', daytrip: 'Day trips', event: 'Events', everyday: 'Everyday' };
const NOT_KIND = { trip: 'Not a trip', daytrip: 'Not a day trip', event: 'Not an event' };
const GROUP_KIND = { duplicate: 'Duplicates', 'near-duplicate': 'Near-duplicates', similar: 'Similar shots' };
const STATE_LABEL = { fav: 'Favorite', keep: 'Keep', remove: 'Remove' };
const STATE_ICON = { fav: 'star', keep: 'check', remove: 'x' };

const S = {
  loaded: false, root: '', photos: {}, order: [], groups: [], groupById: {},
  collections: [], colById: {}, newestFirst: [], dupTitles: new Set(),
  decisions: {}, haiku: {}, moved: new Set(), filed: {}, reviewed: new Set(),
  total: null, stats: new Map(), videos: 0,
};

async function load() {
  const d = await call('/api/data');
  S.root = d.root;
  S.photos = d.photos;
  S.order = d.order;
  S.groups = d.groups;
  S.groupById = Object.fromEntries(d.groups.map((g) => [g.id, g]));
  S.collections = d.collections || [];
  S.colById = Object.fromEntries(S.collections.map((c) => [c.id, c]));
  S.newestFirst = S.collections.slice().sort((a, b) => b.start - a.start);
  const seen = new Map();
  for (const c of S.collections) if (!c.name) seen.set(defaultTitle(c), (seen.get(defaultTitle(c)) || 0) + 1);
  S.dupTitles = new Set(Array.from(seen).filter((e) => e[1] > 1).map((e) => e[0]));
  S.decisions = d.decisions || {};
  S.haiku = d.haiku || {};
  S.moved = new Set(d.moved);
  S.filed = d.filed || {};
  S.reviewed = new Set(d.reviewed || []);
  S.videos = S.order.filter(isVideo).length;
  S.loaded = true;
  recount();
}

/* photos and videos: a video is an item like a photo, and says how long it is */
const isVideo = (id) => S.photos[id].dur != null;
const clock = (sec) => { const s = Math.max(0, Math.round(sec)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
// "25 photos and 3 videos", "25 photos", "3 videos"
const mixed = (photos, videos) => (photos || !videos ? pl(photos, 'photo') : '') + (photos && videos ? ' and ' : '') + (videos ? pl(videos, 'video') : '');
function countOf(ids) {
  let v = 0;
  for (const id of ids) if (isVideo(id)) v++;
  return mixed(ids.length - v, v);
}
// A number of the folder's files when it is not known which of them are videos (what a file step moved).
const files = (n) => pl(n, S.videos ? 'file' : 'photo');

/* your choice, else Claude's pick, else the app's own suggestion */
const suggestion = (id) => (S.haiku[id] && S.haiku[id].state) || S.photos[id].auto;
const eff = (id) => S.decisions[id] || suggestion(id);
const live = (id) => !S.moved.has(id);  // not in _to_remove
const groupDone = (g) => g.members.every((id) => S.reviewed.has(id));
const groupWhy = (g) => { for (const id of g.members) if (S.haiku[id] && S.haiku[id].why) return S.haiku[id].why; return ''; };
const colOfPhoto = (pid) => S.photos[pid] && S.colById[S.photos[pid].collection];

/* dates: capture times are wall-clock values stored as if UTC; file times are real instants */
const zone = (known) => (known ? { timeZone: 'UTC' } : {});
const fmtDate = (sec, known, opts) => new Date(sec * 1000).toLocaleDateString(undefined, Object.assign({}, opts, zone(known)));
function fmtTime(p, withDate) {
  const opts = Object.assign({ hour: 'numeric', minute: '2-digit' }, zone(p.timeKnown));
  if (withDate) Object.assign(opts, { year: 'numeric', month: 'short', day: 'numeric' });
  return new Date(p.time * 1000).toLocaleString(undefined, opts);
}
const fmtDay = (p) => fmtDate(p.time, p.timeKnown, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
const dayIndex = (sec, known) => Math.floor((known ? sec : sec - new Date(sec * 1000).getTimezoneOffset() * 60) / 86400);
const baseName = (rel) => rel.split('/').pop();
function fmtRange(c, withYear) {
  const opts = Object.assign({ month: 'short', day: 'numeric' }, zone(c.timeKnown));
  if (withYear) opts.year = 'numeric';
  const f = new Intl.DateTimeFormat(undefined, opts);
  const a = new Date(c.start * 1000), b = new Date(c.end * 1000);
  return (f.format(a) === f.format(b) ? f.format(a) : f.formatRange(a, b)).replace(/ ?[–—] ?/g, ' - ');
}
function ago(sec) {
  if (!sec) return 'Not opened yet';
  const d = Date.now() / 1000 - sec;
  if (d < 90) return 'Opened just now';
  if (d < 3600) return 'Opened ' + Math.round(d / 60) + ' minutes ago';
  if (d < 86400) return 'Opened ' + pl(Math.round(d / 3600), 'hour') + ' ago';
  if (d < 86400 * 14) return 'Opened ' + pl(Math.round(d / 86400), 'day') + ' ago';
  return 'Opened ' + new Date(sec * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

/* collections */
const colYear = (c) => fmtDate(c.start, c.timeKnown, { year: 'numeric' });
const sameAt = (c, opts) => fmtDate(c.start, c.timeKnown, opts) === fmtDate(c.end, c.timeKnown, opts);
// Works for collections and for the notes of folded ones (kind, start, end, timeKnown).
function defaultTitle(c) {
  const oneDay = sameAt(c, { year: 'numeric', month: 'numeric', day: 'numeric' });
  switch (c.kind) {
    case 'trip': return 'Trip · ' + fmtRange(c);
    case 'daytrip': return 'Day trip · ' + fmtDate(c.start, c.timeKnown, { weekday: 'short', month: 'short', day: 'numeric' });
    case 'event': return 'Event · ' + (oneDay ? fmtDate(c.start, c.timeKnown, { weekday: 'long', month: 'short', day: 'numeric' }) : fmtRange(c));
    default: {
      if (sameAt(c, { year: 'numeric', month: 'numeric' })) return 'Everyday · ' + fmtDate(c.start, c.timeKnown, { month: 'long' });
      const f = new Intl.DateTimeFormat(undefined, Object.assign({ month: 'long' }, zone(c.timeKnown)));
      return 'Everyday · ' + f.formatRange(new Date(c.start * 1000), new Date(c.end * 1000)).replace(/ ?[–—] ?/g, ' - ');
    }
  }
}
// Unnamed collections whose default title repeats (an everyday month in two years) get their year.
function colTitle(c) {
  if (c.name) return c.name;
  const t = defaultTitle(c);
  return S.dupTitles.has(t) ? t + (c.kind === 'everyday' ? ' ' : ', ') + colYear(c) : t;
}
// The line under a title: what kind of collection it is, when, and how far from home.
function colMeta(c, short) {
  const parts = [];
  if (c.name) parts.push(KIND[c.kind]);
  parts.push(fmtRange(c, true));
  if (short) return parts.join(' · ');
  if (c.days > 1 && c.kind !== 'everyday') parts.push(pl(c.days, 'day'));
  if ((c.kind === 'trip' || c.kind === 'daytrip') && c.homeKm != null) parts.push('about ' + num(c.homeKm) + ' km from home');
  if (c.parts > 1) parts.push('merged from ' + c.parts);
  return parts.join(' · ');
}
// The best photos of a collection for its cover: favorites first, never one that was moved out.
function coverPhotos(c, n) {
  const rank = (id) => (eff(id) === 'fav' ? 4 : eff(id) === 'keep' ? 1 : 0) + S.photos[id].score;
  const liveOnes = c.members.filter(live);
  return (liveOnes.length ? liveOnes : c.members).slice().sort((a, b) => rank(b) - rank(a)).slice(0, n);
}

/* counts */
// `photos` and `remove` count photos and videos alike; `videos` and `rmVideos` say how many are videos.
function tally(ids) {
  const t = { photos: 0, videos: 0, fav: 0, remove: 0, rmVideos: 0, bytes: 0 };
  for (const id of ids) {
    if (!live(id)) continue;
    const v = isVideo(id);
    t.photos++;
    if (v) t.videos++;
    const s = eff(id);
    if (s === 'fav') t.fav++;
    else if (s === 'remove') { t.remove++; if (v) t.rmVideos++; t.bytes += S.photos[id].size; }
  }
  return t;
}
const tallyAll = (t) => mixed(t.photos - t.videos, t.videos);
const tallyRemove = (t) => mixed(t.remove - t.rmVideos, t.rmVideos);
function progress(groups) {
  let done = 0;
  for (const g of groups) if (groupDone(g)) done++;
  return { groups: groups.length, done: done, left: groups.length - done };
}
function recount() {
  S.total = Object.assign(tally(S.order), progress(S.groups));
  S.stats = new Map(S.collections.map((c) => [c.id, Object.assign(tally(c.members), progress(c.groups.map((id) => S.groupById[id])))]));
}
function colStatus(st) {
  if (st.left) return pl(st.left, 'group') + ' to review';
  if (st.groups) return 'all reviewed';
  return st.remove ? num(st.remove) + ' to remove' : 'nothing to clean up';
}
// The newest collection that still has groups to review, skipping `except`.
const nextCollection = (except) => S.newestFirst.find((c) => c !== except && S.stats.get(c.id).left > 0);

// Trips, day trips and events that start at most two calendar days after the previous one ends (one
// day at home in between) may well be one. Overlaps are left out: they come from a long merged
// collection, not from a trip split in two; a few hours are allowed for clocks in another time zone.
function mergeHints() {
  const hints = new Map();
  const away = S.collections.filter((c) => c.kind !== 'everyday').sort((a, b) => a.start - b.start);
  for (let i = 1; i < away.length; i++) {
    const a = away[i - 1], b = away[i];
    const days = dayIndex(b.start, b.timeKnown) - dayIndex(a.end, a.timeKnown);
    if (b.start - a.end > -6 * 3600 && days <= 2) hints.set(b.id, { other: a, days: Math.max(0, days) });
  }
  return hints;
}
const gapText = (h) => (h.days === 0 ? 'Same day as ' : h.days === 1 ? 'The day after ' : '2 days after ') + colTitle(h.other);

// Where a collection's photos are, against where "Organize files" would put them. Photos marked
// remove are filed too: organizing can come before the review, and clean-up takes them out later.
function folderPlan(c) {
  let toFile = 0, filed = 0, toBack = 0;
  const inFolder = c.folder + '/';
  for (const id of c.members) {
    if (!live(id)) continue;
    const at = S.filed[id], where = at || S.photos[id].rel;  // where the file is now
    if (c.folderOn) {
      if (where.startsWith(inFolder)) filed++; else toFile++;
    } else if (at) toBack++;
  }
  return { toFile: toFile, filed: filed, toBack: toBack };
}
function movePlan() {
  const plans = S.collections.map((c) => Object.assign({ c: c }, folderPlan(c)));
  const folders = plans.filter((f) => f.toFile);
  return { remove: S.total.remove, bytes: S.total.bytes, folders: folders,
    toFile: folders.reduce((n, f) => n + f.toFile, 0), toBack: plans.reduce((n, f) => n + f.toBack, 0) };
}

/* changes: the page updates at once and the save follows */
function setStates(changes) {
  const body = {};
  for (const id of Object.keys(changes)) {
    const state = changes[id];
    const value = state && state !== suggestion(id) ? state : null;
    if (value) S.decisions[id] = value; else delete S.decisions[id];
    body[id] = value;
  }
  recount();
  save('/api/decide', { changes: body });
}
function setReviewed(g, on) {
  for (const id of g.members) if (on) S.reviewed.add(id); else S.reviewed.delete(id);
  recount();
  save('/api/reviewed', { ids: g.members, reviewed: on });
}

/* copy text without the clipboard API, which a custom URL scheme does not get */
function copyText(text) {
  const t = document.createElement('textarea');
  t.value = text;
  t.style.cssText = 'position:fixed;opacity:0';
  document.body.appendChild(t);
  t.select();
  let ok = false;
  try { ok = document.execCommand('copy'); } catch (e) { /* fall through */ }
  t.remove();
  if (!ok && navigator.clipboard) navigator.clipboard.writeText(text).catch(() => {});
}
