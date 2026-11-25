'use strict';
/* What every screen shares: the toolbar, the sidebar, menus, sheets, toasts and the second-opinion panel. */

// What the app knows above a single folder (GET /app/state), and where the interface is.
let A = { folders: [], totals: {}, claude: { checking: true }, opinion: {}, open: null, scan: null, app: {} };
const U = {
  route: { name: 'home' }, booted: false, launch: true, lastNotice: 0, dataVersion: -1,
  kind: 'all', q: '', colSel: new Set(), renaming: null,
  sheet: null, pop: false, menu: null,
};
const folderNow = () => A.folders.find((f) => f.id === U.route.folder) || null;
const here = (rest) => U.route.folder + '/' + rest;
function go(hash) {
  if (location.hash === '#' + hash) route(); else location.hash = hash;  // adds a history entry; hashchange renders
}

/* ---------- library-wide views ---------- */
const LIBRARY = [
  { id: 'all', label: 'All photos', icon: 'photos', hint: 'Every photo in the folder, oldest first.', photos: () => S.order },
  { id: 'you', label: 'Photos of you', icon: 'person', hint: 'Photos your face was recognized in. These are kept unless a better shot of the same moment exists.',
    photos: () => S.order.filter((id) => S.photos[id].me), empty: 'No photos of you yet. Choose a clear photo of you, and every photo you are in shows up here.' },
  { id: 'groups', label: 'Cleanup groups', icon: 'stack', hint: 'Every set of near-identical shots, across all trips and events.',
    groups: () => S.groups, empty: 'No near-identical photos were found.' },
  { id: 'close', label: 'Close calls', icon: 'scale', hint: 'Groups where the favorite was hard to pick. Worth a second look.',
    groups: () => S.groups.filter((g) => g.close), empty: 'No close calls. Every group has a clear favorite.' },
  { id: 'singles', label: 'Singles', icon: 'one', hint: 'Photos that are not part of any group.',
    photos: () => S.order.filter((id) => !S.photos[id].group), empty: 'Every photo belongs to a group.' },
  { id: 'favs', label: 'Favorites', icon: 'star', hint: 'The best shot of each group, plus anything you starred.',
    photos: () => S.order.filter((id) => eff(id) === 'fav'), empty: 'No favorites yet. Press F on a photo to star it.' },
  { id: 'remove', label: 'Marked remove', icon: 'trash', hint: 'Everything that clean up will move to _to_remove.',
    photos: () => S.order.filter((id) => eff(id) === 'remove'), empty: 'Nothing is marked for removal.' },
  { id: 'blurry', label: 'Blurry', icon: 'blur', hint: 'Photos that look out of focus.',
    photos: () => S.order.filter((id) => S.photos[id].tags.includes('blurry')), empty: 'No blurry photos found.' },
  { id: 'utility', label: 'Screenshots and documents', icon: 'doc', hint: 'Screenshots, receipts, documents and similar.',
    photos: () => S.order.filter((id) => S.photos[id].tags.includes('utility')), empty: 'No screenshots or documents found.' },
];
const LIBRARY_BY_ID = Object.fromEntries(LIBRARY.map((v) => [v.id, v]));
const libraryCount = (lib) => (lib.groups ? lib.groups().length : lib.photos().filter(live).length);

/* ---------- toast ---------- */
let toastT = 0;
function toast(text, kind, icon) {
  const t = $('#toast');
  t.className = 'toast glass show' + (kind === 'err' ? ' err' : '');
  t.innerHTML = ic(icon || (kind === 'err' ? 'warn' : 'spark'), 16) + '<span>' + esc(text) + '</span>';
  clearTimeout(toastT);
  toastT = setTimeout(() => t.classList.remove('show'), kind === 'err' ? 9000 : Math.max(3200, text.length * 60));
}
const oops = (e) => toast(e.message || String(e), 'err');

/* ---------- menus: a small glass list next to the thing that opened it ---------- */
function openMenu(anchor, items) {
  closeMenu();
  const list = items.filter(Boolean);
  const m = document.createElement('div');
  m.className = 'menu glass';
  m.setAttribute('role', 'menu');
  m.innerHTML = list.map((it, i) => (it === '-' ? '<hr>' : '<button role="menuitem" data-i="' + i + '"' + (it.danger ? ' class="danger"' : '') + '>' + (it.icon ? ic(it.icon, 16) : '') + '<span>' + esc(it.label) + '</span></button>')).join('');
  $('#app').appendChild(m);
  const a = anchor.getBoundingClientRect(), w = m.offsetWidth, h = m.offsetHeight;
  m.style.left = Math.max(8, Math.min(a.left, innerWidth - w - 8)) + 'px';
  m.style.top = (a.bottom + 6 + h > innerHeight - 8 ? Math.max(8, a.top - h - 6) : a.bottom + 6) + 'px';
  m.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    e.stopPropagation();
    closeMenu();
    list[+b.dataset.i].run();
  });
  anchor.classList.add('open');
  U.menu = { el: m, anchor: anchor };
  const first = m.querySelector('button');
  if (first) first.focus({ preventScroll: true });
}
function closeMenu() {
  if (!U.menu) return;
  U.menu.el.remove();
  U.menu.anchor.classList.remove('open');
  U.menu = null;
}

/* ---------- sheets: one at a time, over everything ---------- */
function openSheet(name, html, wide) {
  U.sheet = name;
  const s = $('#sheet');
  s.className = 'sheet glass' + (wide ? ' wide' : '');
  s.innerHTML = html;
  $('#veil').classList.add('show');
  paintDocks();
  paintSeg();
  const f = s.querySelector('[autofocus]') || s.querySelector('.btn.primary,.btn.danger');
  if (f) f.focus({ preventScroll: true });
}
function closeSheet() {
  if (!U.sheet) return;
  U.sheet = null;
  $('#veil').classList.remove('show');
  paintDocks();
  paintSeg();
}
// A yes or no question. `yes` runs on confirm.
function confirmSheet(o) {
  openSheet('confirm',
    '<h2>' + esc(o.title) + '</h2><p>' + o.body + '</p>' +
    '<div class="btns"><button class="btn quiet" data-act="sheet-close">' + esc(o.no || 'Cancel') + '</button>' +
    '<button class="btn ' + (o.danger ? 'danger' : 'primary') + '" data-act="sheet-yes">' + esc(o.yes) + '</button></div>');
  U.onYes = o.run;
}

/* ---------- view transitions, where the web view has them ---------- */
function morph(fn) {
  if (!document.startViewTransition || reduced.matches) { fn(); return; }
  let ran = false;
  const once = () => { if (!ran) { ran = true; fn(); } };
  try {
    const vt = document.startViewTransition(once);
    const quiet = () => {};
    vt.ready.catch(quiet); vt.finished.catch(quiet); vt.updateCallbackDone.catch(quiet);
  } catch (e) { once(); }
}

/* ---------- toolbar ---------- */
function renderBars() {
  $('#bar-home').innerHTML = '<span class="title">' + esc((A.app && A.app.name) || 'Photo Cleanup') + '</span><span class="sp"></span>' +
    '<button class="btn glass icon" data-act="settings" title="Settings" aria-label="Settings">' + ic('gear', 16) + '</button>' +
    '<button class="btn glass" data-act="add">' + ic('plus', 15) + 'Add folder</button>';
  $('#bar-folder').innerHTML =
    '<div class="seg glass" id="seg"><span class="thumb"></span>' +
      '<button data-seg="organize">Organize</button>' +
      '<button data-seg="review">Review<em id="seg-left"></em></button>' +
      '<button data-seg="finish">Finish<em id="seg-rm"></em></button></div>' +
    '<span class="savest ok" id="savest" role="status"></span><span class="sp"></span>' +
    '<label class="search glass">' + ic('search', 15) + '<input id="q" type="text" placeholder="Search collections" spellcheck="false" autocomplete="off"></label>' +
    '<button class="btn glass" data-act="opinion" id="btn-opinion">' + ic('spark', 16, 'spark') + 'Second opinion</button>' +
    '<span id="scanslot"></span>' +
    '<button class="btn glass icon" data-act="help" title="Keyboard shortcuts" aria-label="Keyboard shortcuts">' + ic('help', 16) + '</button>';
  $('#q').addEventListener('input', (e) => {
    U.q = e.target.value;
    renderSidebar();
    if (U.route.name === 'organize') renderLibrary();
  });
  paintScan();
}
function paintSeg() {
  if (!S.loaded || !$('#seg')) return;
  const active = U.sheet === 'finish' ? 'finish' : U.route.name === 'organize' ? 'organize' : 'review';
  $('#seg-left').textContent = S.total.left || '';
  $('#seg-rm').textContent = S.total.remove || '';
  $$('#seg button').forEach((b) => {
    const on = b.dataset.seg === active;
    b.classList.toggle('on', on);
    if (on) { const th = $('#seg .thumb'); th.style.width = b.offsetWidth + 'px'; th.style.transform = 'translateX(' + b.offsetLeft + 'px)'; }
  });
}
// The Scan button, or the scan's progress while one runs.
function paintScan() {
  const slot = $('#scanslot');
  if (!slot) return;
  const s = A.scan;
  if (!s) {
    slot.innerHTML = '<button class="btn glass" data-act="scan" title="Look for new, moved and deleted photos">' + ic('scan', 16) + 'Scan</button>';
  } else {
    slot.innerHTML = '<span class="scanpill glass" role="status">' + (s.total ? ring(s.done / s.total, 18) : '<i class="spin"></i>') +
      '<span>' + esc(s.title) + (s.total ? ' ' + num(s.done) + ' of ' + num(s.total) : '') + '</span>' +
      '<button data-act="scan-cancel" title="Stop the scan" aria-label="Stop the scan">' + ic('x', 14) + '</button></span>';
  }
  // A folder with nothing analyzed yet has nothing else to show: the progress gets the floor.
  const first = !!s && S.loaded && !S.order.length && U.route.name !== 'home';
  let over = $('#scanning');
  if (!first) { if (over) over.remove(); return; }
  if (!over) {
    over = document.createElement('div');
    over.id = 'scanning';
    over.className = 'scanning';
    $('#app').appendChild(over);
  }
  over.innerHTML = '<div class="scancard glass">' + (s.total ? ring(s.done / s.total, 92) : ring(.22, 92, 'busy')) +
    '<h3>' + esc(s.title) + '</h3><p>' + (s.total ? num(s.done) + ' of ' + num(s.total) + (s.failed ? ' · ' + num(s.failed) + ' could not be read' : '') : 'This runs on your Mac. Nothing is uploaded.') + '</p>' +
    '<button class="btn quiet" data-act="scan-cancel">Stop</button></div>';
}

/* ---------- sidebar ---------- */
function filteredCols() {
  const q = U.q.trim().toLowerCase();
  return S.newestFirst.filter((c) => !q || (colTitle(c) + ' ' + KIND[c.kind] + ' ' + fmtRange(c, true)).toLowerCase().indexOf(q) >= 0);
}
function rowCount(c) {
  const st = S.stats.get(c.id);
  if (st.left) return '<span class="n" title="Groups left to review">' + st.left + '</span>';
  return st.groups ? '<span class="n done" title="Reviewed">' + ic('check', 14) + '</span>' : '<span class="n"></span>';
}
function renderSidebar() {
  const f = folderNow();
  if (!f || !S.loaded) { $('#sidebar').innerHTML = ''; return; }
  const list = filteredCols(), r = U.route;
  const years = [];
  list.forEach((c) => { const y = colYear(c); let g = years.find((x) => x.y === y); if (!g) { g = { y: y, a: [] }; years.push(g); } g.a.push(c); });
  const keep = $('.sb-list') ? $('.sb-list').scrollTop : 0;
  $('#sidebar').innerHTML =
    '<div class="sb-top"><button class="sb-back" data-act="home">' + ic('chevL', 15) + 'All folders</button></div>' +
    '<div class="sb-folder"><h2>' + esc(f.name) + '</h2><p title="' + esc(S.root) + '">' + esc(f.path) + '</p></div>' +
    (f.connected ? '' : '<div class="sb-warn">' + ic('unplug', 15) + '<span>The folder is not connected. You can review; moving files waits until it is back.</span></div>') +
    '<nav class="sb-list" aria-label="Collections">' +
      '<button class="row' + (r.name === 'organize' ? ' on' : '') + '" data-go="organize"><span class="th ico">' + ic('grid', 17) + '</span><span class="tx"><b>All collections</b><small>' + pl(S.total.photos, 'photo') + '</small></span><span class="n">' + S.collections.length + '</span></button>' +
      years.map((g) => '<h6>' + esc(g.y) + '</h6>' + g.a.map((c) => {
        const cover = coverPhotos(c, 1)[0];
        return '<button class="row' + (r.name === 'c' && r.id === c.id ? ' on' : '') + '" data-go="c/' + esc(c.id) + '" data-row="' + esc(c.id) + '"><span class="th">' + (cover ? img(thumbSrc(cover)) : '') + '</span><span class="tx"><b>' + esc(colTitle(c)) + '</b><small>' + esc(colMeta(c, true)) + '</small></span>' + rowCount(c) + '</button>';
      }).join('')).join('') +
      (list.length || !U.q.trim() ? '' : '<div class="empty" style="padding:28px 0;font-size:12.5px">No collection matches</div>') +
      '<h6>Library</h6>' +
      LIBRARY.map((v) => '<button class="row' + (r.name === 'view' && r.id === v.id ? ' on' : '') + '" data-go="view/' + v.id + '" data-view="' + v.id + '" title="' + esc(v.hint) + '"><span class="th ico">' + ic(v.icon, 17) + '</span><span class="tx"><b>' + esc(v.label) + '</b></span><span class="n">' + num(libraryCount(v)) + '</span></button>').join('') +
    '</nav>' +
    '<button class="sb-foot" data-act="finish" title="Finish: organize files and clean up"><span class="tx"><b></b><small></small></span>' + ic('chevR', 15, 'go') + '</button>';
  $('.sb-list').scrollTop = keep;
  paintCounts();
}
// After a choice or a reviewed mark: only the numbers change, so only they are repainted.
function paintCounts() {
  if (!S.loaded) return;
  const t = S.total, foot = $('.sb-foot');
  if (foot) {
    foot.querySelector('b').textContent = t.remove ? pl(t.remove, 'photo') + ' to remove' : 'Nothing to remove';
    foot.querySelector('small').textContent = (t.remove ? bytes(t.bytes).t + ' · ' : '') + (t.left ? t.left + ' of ' + pl(t.groups, 'group') + ' left' : t.groups ? 'all groups reviewed' : 'no groups');
  }
  $$('.sb-list [data-row]').forEach((row) => {
    const c = S.colById[row.dataset.row];
    if (c) row.lastElementChild.outerHTML = rowCount(c);
  });
  $$('.sb-list [data-view]').forEach((row) => { row.lastElementChild.textContent = num(libraryCount(LIBRARY_BY_ID[row.dataset.view])); });
  paintSeg();
}

/* ---------- second opinion ---------- */
// What to type in Terminal when Claude is missing or signed out. The app shows and copies these
// commands; it never runs them.
function claudeSetup() {
  const cl = A.claude || {};
  const installed = !!cl.path;
  const cmd = (c) => '<div class="cmd"><code>' + esc(c) + '</code><button data-copy="' + esc(c) + '">Copy</button></div>';
  return '<h3>' + (installed ? 'Sign in to Claude from Terminal' : 'Set up Claude from Terminal') + '</h3>' +
    '<p>' + (installed ? 'The Claude CLI is installed but not signed in. Run this line in Terminal.'
      : 'Install the Claude CLI, then sign in. Each line goes into Terminal. It needs a paid Claude plan or a Console account.') + '</p>' +
    (installed ? '' : cmd('curl -fsSL https://claude.ai/install.sh | bash')) + cmd('claude auth login') +
    '<div class="row2"><small>Photo Cleanup works without it. Only the second opinion needs Claude.</small>' +
    '<button class="btn small quiet" data-act="terminal">' + ic('terminal', 14) + 'Open Terminal</button></div>';
}
function renderOpinion() {
  let p = $('#pop');
  if (!U.pop || U.route.name === 'home') { if (p) p.remove(); return; }
  if (!p) {
    p = document.createElement('div');
    p.id = 'pop';
    p.className = 'pop glass';
    $('#app').appendChild(p);
  }
  const o = A.opinion || {}, cl = A.claude || {};
  let body;
  if (cl.checking) {
    body = '<div class="line"><i class="spin"></i>Looking for the Claude CLI</div>';
  } else if (!cl.ready) {
    body = '<div style="margin-top:14px">' + claudeSetup() + '</div><div class="btns"><button class="btn quiet" data-act="claude">Check again</button><button class="btn quiet" data-act="settings">Settings</button></div>';
  } else if (o.running) {
    body = '<p>Claude is comparing the shots in each group. You can keep reviewing; picks appear as they come in.</p>' +
      '<div class="track"><i style="width:' + (o.total ? (100 * o.done / o.total).toFixed(1) : 3) + '%"></i></div>' +
      '<div class="line">' + (o.total ? 'Batch ' + num(Math.min(o.done + 1, o.total)) + ' of ' + num(o.total) + ' · ' + pl(o.groups, 'group') + ' done' + (o.failed ? ' · ' + o.failed + ' failed' : '') : 'Getting the groups ready') + '</div>' +
      '<div class="btns"><button class="btn quiet" data-act="opinion-stop">' + ic('stop', 14) + 'Stop</button></div>';
  } else {
    body = '<p>' + (o.pending ? 'Claude looks at ' + pl(o.pending, 'group') + ' of similar shots it has not seen yet, picks the best of each and says why. Your own choices always win.'
      : 'Claude has looked at every group in this folder.') + '</p>' +
      '<div class="line"><i class="dot"></i>' + esc(cl.version ? 'Claude ' + String(cl.version).replace(/\s*\(.*\)$/, '') : 'Claude') + ' · ' + esc(cl.detail || '') + ' · model ' + esc(o.model || 'haiku') + '</div>' +
      '<div class="btns">' + (o.pending ? '<button class="btn primary" data-act="opinion-start">' + ic('spark', 15) + 'Ask about ' + pl(o.pending, 'group') + '</button>' : '') +
      '<button class="btn quiet" data-act="settings">Settings</button></div>';
  }
  const log = (o.log || []).slice(-40);
  const old = p.querySelector('.log'), bottom = !old || old.scrollTop + old.clientHeight >= old.scrollHeight - 4;
  p.innerHTML = '<h3>' + ic('spark', 18, 'spark') + 'Second opinion</h3>' + body +
    (log.length && cl.ready ? '<div class="log">' + log.map((l) => '<div>' + esc(l) + '</div>').join('') + '</div>' : '');
  const now = p.querySelector('.log');
  if (now && bottom) now.scrollTop = now.scrollHeight;
  p.querySelector('h3 svg').style.color = 'var(--accent)';
}

/* ---------- help ---------- */
function openHelp() {
  const k = (keys, what) => '<span class="k">' + keys.map((x) => '<span class="key">' + x + '</span>').join('') + '</span><span>' + what + '</span>';
  openSheet('help',
    '<h2>Keyboard shortcuts</h2><p style="margin-bottom:16px">They act on the highlighted photo, or on every selected photo.</p><div class="keys">' +
    k(['F'], 'Favorite') + k(['&larr;', '&rarr;'], 'Previous, next photo') +
    k(['K'], 'Keep') + k(['&uarr;', '&darr;'], 'Previous, next group') +
    k(['X'], 'Remove') + k(['Return'], 'Open the photo large') +
    k(['U'], 'Back to the suggestion') + k(['S'], 'Select, to move it') +
    k(['D'], 'Mark reviewed, go on') + k(['N'], 'Next group to review') +
    k(['Esc'], 'Close, clear, go back') + k(['?'], 'This list') +
    '</div><div class="btns"><button class="btn primary" data-act="sheet-close">Done</button></div>');
}
