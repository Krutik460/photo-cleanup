'use strict';
/* Routing, the app's live state, and the events every screen shares. Loaded last. */

/* ---------- routes: #home, #<folder>/organize, #<folder>/c/<collection>, #<folder>/view/<name>, #<folder>/review ---------- */
function parseHash() {
  const h = decodeURIComponent(location.hash.slice(1));
  if (!h || h === 'home') return { name: 'home' };
  const p = h.split('/');
  return { folder: p[0], name: p[1] || 'organize', id: p.slice(2).join('/') };
}
let routeToken = 0;
async function route() {
  const my = ++routeToken, r = parseHash(), from = U.route;
  closeMenu();
  closeSheet();
  if (typeof closeViewer === 'function') closeViewer();
  try {
    if (r.name === 'home') {
      if (A.open) { await Q.chain; await appAction('close'); }
      if (my !== routeToken) return;
      S.loaded = false;
      U.route = r;
      U.colSel.clear();
      U.pop = false;
      show();
      return;
    }
    if (A.open !== r.folder) {
      await Q.chain;
      await appAction('open', { id: r.folder });
      S.loaded = false;
    }
    if (!S.loaded) {
      await load();
      U.dataVersion = A.dataVersion;
      U.kind = 'all';
      U.q = '';
      if ($('#q')) $('#q').value = '';
    }
    if (my !== routeToken) return;
    // "review" means the next collection with groups left (or the newest when all are done).
    if (r.name === 'review') {
      const c = nextCollection() || S.newestFirst[0];
      history.replaceState(null, '', '#' + r.folder + '/' + (c ? 'c/' + c.id : S.order.length ? 'view/all' : 'organize'));
      return route();
    }
    if ((r.name === 'c' && !S.colById[r.id]) || (r.name === 'view' && !LIBRARY_BY_ID[r.id]) || ['organize', 'c', 'view'].indexOf(r.name) < 0) {
      r.name = 'organize';
      r.id = '';
      history.replaceState(null, '', '#' + r.folder + '/organize');
    }
    U.route = r;
    if (r.name !== 'organize') U.colSel.clear();
    show();
    if (from.name !== r.name || from.id !== r.id || from.folder !== r.folder) $(r.name === 'organize' ? '#s-library' : '#s-review').scrollTop = 0;
  } catch (e) {
    oops(e);
    if (r.name !== 'home' && my === routeToken) location.hash = 'home';
  }
}
function show() {
  const r = U.route;
  const screen = r.name === 'home' ? 'home' : r.name === 'organize' ? 'library' : 'review';
  $('#app').dataset.screen = screen;
  renderAmbient();
  if (screen === 'home') renderHome();
  else {
    renderSidebar();
    if (screen === 'library') renderLibrary(); else renderReview();
  }
  paintDocks();
  paintSeg();
  paintScan();
  renderOpinion();
}
// Draws the current screen again where it is.
function rerender() {
  const scr = $(U.route.name === 'home' ? '#s-home' : U.route.name === 'organize' ? '#s-library' : '#s-review');
  const top = scr.scrollTop;
  show();
  scr.scrollTop = top;
  if (typeof paintViewer === 'function') paintViewer();
  if (U.sheet === 'finish') renderFinish();
}
// Loads the folder's data again. Regrouping renumbers collections, so the one on screen is found
// again through a photo: `anchor`, or the first photo of the collection being shown.
let reloading = false;
async function reload(anchor) {
  if (reloading) return;
  reloading = true;
  try {
    const r = U.route;
    const stay = anchor || (r.name === 'c' && S.colById[r.id] ? S.colById[r.id].members[0] : null);
    await Q.chain;
    await load();
    if (U.route !== r) return;
    if (r.name === 'c') {
      const c = stay && colOfPhoto(stay);
      if (!c) { go(here('organize')); return; }
      if (c.id !== r.id) { r.id = c.id; history.replaceState(null, '', '#' + here('c/' + c.id)); }
    }
    rerender();
  } finally { reloading = false; }
}
function paintDocks() {
  renderSelectBar();
  renderActionBar();
}

/* ---------- the app's state ---------- */
let homeKey = '', pollT = 0, appT = 0;
function setApp(state) {
  const prev = A;
  A = state;
  if (A.notice && A.notice.id !== U.lastNotice) {
    U.lastNotice = A.notice.id;
    if (U.booted) toast(A.notice.text, A.notice.error ? 'err' : null);
  }
  if (U.booted && prev.scan && !A.scan && A.lastScan) scanToast(A.lastScan);
  if (U.launch) renderLaunch();
  const key = JSON.stringify([A.folders, A.totals, A.claude]);
  if (U.booted && key !== homeKey) {
    if (U.route.name === 'home') { renderHome(); renderAmbient(); } else if (S.loaded) renderSidebar();
  }
  homeKey = key;
  if (U.booted && U.route.name !== 'home') { paintScan(); renderOpinion(); }
  paintUpdate();
  // A scan or a second opinion changed the folder's data under the page.
  if (U.booted && S.loaded && A.open && A.open === U.route.folder && A.dataVersion !== U.dataVersion) {
    U.dataVersion = A.dataVersion;
    reload().catch(oops);
  }
  clearTimeout(pollT);
  if (A.scan || (A.opinion && A.opinion.running) || (A.claude && A.claude.checking)) pollT = setTimeout(refreshApp, 500);
}
async function refreshApp() {
  try { setApp(await call('/app/state')); } catch (e) { clearTimeout(pollT); pollT = setTimeout(refreshApp, 1500); }
}
async function appAction(name, body) {
  const r = await call('/app/' + name, body || {});
  if (r && r.state) setApp(r.state);
  return r || {};
}
function scanToast(s) {
  if (s.cancelled) { toast('Scan stopped. What was analyzed is kept; scan again to continue.', null, 'scan'); return; }
  const parts = [];
  if (s.analyzed) parts.push('analyzed ' + mixed(s.analyzed - (s.videos || 0), s.videos || 0).replace(/ (photos?|videos?)/g, ' new $1'));
  if (s.relinked) parts.push('found ' + pl(s.relinked, S.videos ? 'moved file' : 'moved photo') + ' again');
  if (s.missing) parts.push(files(s.missing) + ' ' + isAre(s.missing) + ' no longer in the folder');
  const failed = (s.failed || []).length;
  if (failed) parts.push(pl(failed, 'file') + ' could not be read');
  const text = parts.join(', ');
  toast(text ? text.charAt(0).toUpperCase() + text.slice(1) + '.' : 'Up to date: ' + tallyAll(S.total) + ', ' + pl(S.groups.length, 'group') + '.', failed ? 'err' : null, 'scan');
}
// The Mac app calls these: something changed outside the page, or a folder is over the window.
window.appChanged = () => { clearTimeout(appT); appT = setTimeout(refreshApp, 60); };
window.appDrop = (on) => { $('#app').classList.toggle('dropping', !!on); };
window.appDropped = (path) => { window.appDrop(false); addFolder(path); };

/* ---------- events ---------- */
// A click anywhere else closes an open menu; on its own button it must not open it again.
document.addEventListener('click', (e) => {
  if (!U.menu || e.target.closest('.menu')) return;
  const again = U.menu.anchor.contains(e.target);
  closeMenu();
  if (again) { e.stopPropagation(); e.preventDefault(); }
}, true);

document.addEventListener('click', (e) => {
  const t = e.target;
  let el;
  if (U.pop && !t.closest('#pop') && !t.closest('[data-act="opinion"]')) { U.pop = false; renderOpinion(); }
  if ((el = t.closest('[data-copy]'))) {
    copyText(el.dataset.copy);
    el.textContent = 'Copied';
    setTimeout(() => { el.textContent = 'Copy'; }, 1400);
    return;
  }
  if ((el = t.closest('[data-folder-menu]'))) { e.stopPropagation(); folderMenu(el, el.dataset.folderMenu); return; }
  if ((el = t.closest('[data-col-menu]'))) { const c = S.colById[el.dataset.colMenu]; if (c) openMenu(el, colMenuItems(c)); return; }
  if ((el = t.closest('[data-pick]'))) { toggleColSel(el.dataset.pick); return; }
  if ((el = t.closest('[data-merge-hint]'))) {
    const c = S.colById[el.dataset.mergeHint], h = c && mergeHints().get(c.id);
    if (h) mergeCollections([h.other, c]);
    return;
  }
  if ((el = t.closest('[data-merge-pick]'))) { mergePick(el); return; }
  if ((el = t.closest('[data-org]'))) { organize(el.dataset.org); return; }
  if ((el = t.closest('[data-kind]'))) { U.kind = el.dataset.kind; renderLibrary(); return; }
  if ((el = t.closest('[data-seg]'))) {
    if (el.dataset.seg === 'finish') openFinish(); else go(here(el.dataset.seg));
    return;
  }
  if ((el = t.closest('[data-go]'))) { go(here(el.dataset.go)); return; }
  if ((el = t.closest('[data-folder]'))) { const f = A.folders.find((x) => x.id === el.dataset.folder); if (f) openFolder(f); return; }
  if ((el = t.closest('.ccard[data-col]'))) {
    if (t.closest('[contenteditable="true"]')) return;
    if (U.colSel.size) toggleColSel(el.dataset.col); else go(here('c/' + el.dataset.col));
    return;
  }
  if ((el = t.closest('[data-act]'))) { act(el.dataset.act, el); return; }
  if (t.id === 'veil') closeSheet();
});

function act(a, el) {
  switch (a) {
    case 'home': go('home'); break;
    case 'add': addFolder(); break;
    case 'add-me':
      appAction('choose', { kind: 'me' }).then((r) => { if (r.paths && r.paths.length) { Add.me = r.paths.slice(0, 3); renderAdd(); } }).catch(oops);
      break;
    case 'add-go': addGo(); break;
    case 'settings': appAction('settings').catch(oops); break;
    case 'terminal': appAction('terminal').catch(oops); break;
    case 'claude': appAction('claude').catch(oops); break;
    case 'launch': U.launch = true; launchShown = 0; $('#launch').dataset.key = ''; renderLaunch(); break;
    case 'launch-done': endLaunch(); break;
    case 'scan': appAction('scan').catch(oops); break;
    case 'scan-cancel': appAction('scan-cancel').catch(oops); break;
    case 'opinion': U.pop = !U.pop; renderOpinion(); break;
    case 'opinion-start': appAction('opinion', { action: 'start' }).catch(oops); break;
    case 'opinion-stop': appAction('opinion', { action: 'stop' }).catch(oops); break;
    case 'help': openHelp(); break;
    case 'update': openUpdate(); break;
    case 'update-get': closeSheet(); appAction('update-open', { what: 'download' }).catch(oops); break;
    case 'update-notes': appAction('update-open', { what: 'notes' }).catch(oops); break;
    case 'start': if (S.total.left) go(here('review')); else openFinish(); break;
    case 'finish': openFinish(); break;
    case 'sheet-close': closeSheet(); break;
    case 'sheet-yes': { const run = U.onYes; closeSheet(); if (run) run(); break; }
    case 'merge-go': { const cols = [Merge.c].concat(S.collections.filter((c) => Merge.picked.has(c.id))); closeSheet(); mergeCollections(cols); break; }
    default: if (typeof reviewAct === 'function') reviewAct(a, el);
  }
}

document.addEventListener('keydown', (e) => {
  const typing = e.target.matches && e.target.matches('input,textarea,[contenteditable="true"]');
  if (e.key === 'Escape') {
    if (U.menu) { closeMenu(); e.preventDefault(); return; }
    if (typing) { if (e.target.id === 'q') { e.target.value = ''; e.target.dispatchEvent(new Event('input')); e.target.blur(); } return; }
    if (typeof viewerOpen === 'function' && viewerOpen()) { closeViewer(); e.preventDefault(); return; }
    if (U.sheet) { closeSheet(); e.preventDefault(); return; }
    if (U.pop) { U.pop = false; renderOpinion(); e.preventDefault(); return; }
    if (U.launch && !(A.claude && A.claude.checking)) { endLaunch(); return; }
  }
  if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
  if (U.menu) {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      const bs = $$('button', U.menu.el), i = bs.indexOf(document.activeElement);
      bs[(i + (e.key === 'ArrowDown' ? 1 : bs.length - 1)) % bs.length].focus();
      e.preventDefault();
    }
    return;
  }
  if (U.launch) return;
  if (typeof viewerOpen === 'function' && viewerOpen()) { viewerKey(e); return; }
  if (U.sheet) return;
  if ((e.key === 'Enter' || e.key === ' ') && e.target.classList && (e.target.classList.contains('ccard') || e.target.classList.contains('fcard'))) {
    e.preventDefault();
    e.target.click();
    return;
  }
  if (e.key === '?' && U.route.name !== 'home') { openHelp(); e.preventDefault(); return; }
  if (U.route.name === 'organize') {
    if (e.key === 'Escape' && U.colSel.size) { organize('clear'); e.preventDefault(); }
    return;
  }
  if (U.route.name === 'c' || U.route.name === 'view') reviewKey(e);
});

// The page draws its own toolbar, so it also says where the window can be dragged from.
document.addEventListener('mousedown', (e) => {
  if (e.button !== 0 || e.clientY > 56 || !document.documentElement.classList.contains('in-app')) return;
  if (e.target.closest('button,input,a,label,[contenteditable="true"],.seg,.menu,.pop,.sheet,.launch-in,.toast')) return;
  call('/app/window', { action: e.detail === 2 ? 'zoom' : 'drag' }).catch(() => {});
});
window.addEventListener('resize', paintSeg);
window.addEventListener('hashchange', route);

/* ---------- start ---------- */
(async function boot() {
  let seen = false;
  try { seen = !!sessionStorage.getItem('launched'); } catch (e) { /* private mode */ }
  U.launch = !(seen || /[?&]launch=skip/.test(location.search));
  if (!U.launch) $('#launch').classList.add('out');
  renderBars();
  try {
    setApp(await call('/app/state'));
  } catch (e) {
    $('#s-home').innerHTML = '<div class="empty">Photo Cleanup could not start: ' + esc(e.message) + '</div>';
    $('#launch').classList.add('out');
    return;
  }
  U.booted = true;
  if (!location.hash) history.replaceState(null, '', A.open ? '#' + A.open + '/organize' : '#home');
  await route();
})();
