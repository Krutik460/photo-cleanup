'use strict';
/* One folder open, Organize: its collections as covers, and everything that changes what a collection is. */

// A cover is drawn from the small picture at once and sharpens when the larger one arrives.
const coverImg = (id, big) => '<img src="' + (big ? midSrc(id) : thumbSrc(id)) + '"' + (big ? ' style="background:center/cover url(' + thumbSrc(id) + ')"' : '') + ' alt="" draggable="false" decoding="async" loading="lazy">';
function coverMosaic(c) {
  const n = c.members.length >= 60 ? 4 : c.members.length >= 12 ? 3 : c.members.length >= 4 ? 2 : 1;
  const ids = coverPhotos(c, n);
  return '<div class="mosaic m' + (ids.length || 1) + '">' + ids.map((id, i) => coverImg(id, i === 0)).join('') + '</div>';
}

function colCard(c, hint) {
  const st = S.stats.get(c.id), title = colTitle(c), cover = coverPhotos(c, 1)[0];
  const chips = (c.folderOn || c.source ? '<span class="chipd" title="' + (c.source ? 'A folder of yours: ' + esc(c.source) : 'Gets its own folder when you organize the files') + '">' + ic('folder', 12) + 'Folder</span>' : '') +
    (st.left ? '<span class="chipd">' + st.left + ' to review</span>' : st.groups ? '<span class="chipd done">' + ic('check', 12) + 'Reviewed</span>' : '');
  return '<article class="ccard' + (U.colSel.has(c.id) ? ' sel' : '') + '" data-col="' + esc(c.id) + '" tabindex="0" aria-label="' + esc(title) + '">' +
    (cover ? img(thumbSrc(cover), 'glow') : '') +
    '<div class="ccard-in">' + coverMosaic(c) + '<div class="scrim"></div>' +
    '<button class="pick" data-pick="' + esc(c.id) + '" aria-label="Select ' + esc(title) + '">' + ic('check', 15) + '</button>' +
    '<button class="cardbtn" data-col-menu="' + esc(c.id) + '" aria-label="More for ' + esc(title) + '">' + ic('more', 15) + '</button>' +
    '<div class="tr">' + chips + '</div>' +
    '<div class="ccap">' +
    (hint ? '<button class="mhint" data-merge-hint="' + esc(c.id) + '" title="Merge these two into one collection">' + ic('merge', 12) + '<span>' + esc(gapText(hint)) + '</span><b>Merge</b></button>' : '') +
    '<h3' + (U.renaming === c.id ? ' contenteditable="true" spellcheck="false"' : '') + '>' + esc(title) + '</h3>' +
    '<div class="sub"><p>' + esc(colMeta(c, true)) + ' · ' + pl(st.photos, 'photo') + '</p>' +
    (st.remove ? '<span class="rm"><i></i>' + num(st.remove) + ' to remove</span>' : '') + '</div></div>' +
    '</div></article>';
}

function renderLibrary() {
  const f = folderNow(), t = S.total, el = $('#s-library');
  if (!f) return;
  if (!S.order.length) {
    el.innerHTML = '<div class="head"><div><h1>' + esc(f.name) + '</h1><p>' + (A.scan ? 'The first scan is running.' : f.connected ? 'Nothing has been analyzed in this folder yet.' : 'The folder is not connected, and nothing was analyzed yet.') + '</p></div>' +
      (A.scan || !f.connected ? '' : '<div class="right"><button class="btn primary" data-act="scan">' + ic('scan', 15) + 'Scan the folder</button></div>') + '</div>';
    renderSelectBar();
    return;
  }
  const kinds = [];
  S.collections.forEach((c) => { let k = kinds.find((x) => x.k === c.kind); if (!k) { k = { k: c.kind, n: 0 }; kinds.push(k); } k.n++; });
  kinds.sort((a, b) => Object.keys(KIND).indexOf(a.k) - Object.keys(KIND).indexOf(b.k));
  if (U.kind !== 'all' && !kinds.some((k) => k.k === U.kind)) U.kind = 'all';
  const list = filteredCols().filter((c) => U.kind === 'all' || c.kind === U.kind);
  const hints = mergeHints();
  const years = [];
  list.forEach((c) => { const y = colYear(c); let g = years.find((x) => x.y === y); if (!g) { g = { y: y, a: [] }; years.push(g); } g.a.push(c); });
  const picking = U.colSel.size ? ' picking' : '';
  const body = !S.collections.length
    ? '<div class="empty">No trips or events were found in this folder.<br><br><button class="btn quiet" data-go="view/all">Open all photos</button></div>'
    : !list.length ? '<div class="empty">No collection matches' + (U.q.trim() ? ' "' + esc(U.q.trim()) + '"' : '') + '</div>'
    : years.map((g) => (years.length > 1 ? '<h3 class="yr">' + esc(g.y) + '</h3>' : '') + '<div class="grid' + picking + '">' + g.a.map((c) => colCard(c, hints.get(c.id))).join('') + '</div>').join('');
  el.innerHTML =
    '<div class="head"><div><h1>' + esc(f.name) + '</h1><p><b>' + pl(S.collections.length, 'collection') + '</b> · ' + pl(t.photos, 'photo') + ' · ' + pl(t.left, 'group') + ' to review · ' + num(t.remove) + ' marked remove' + (t.remove ? ', ' + bytes(t.bytes).t : '') + '</p></div>' +
    '<div class="right"><button class="btn primary" data-act="start">' + (t.left ? 'Review ' + pl(t.left, 'group') : 'Finish') + ic('arrowR', 15) + '</button></div></div>' +
    (kinds.length > 1 ? '<div class="filters"><button class="fchip' + (U.kind === 'all' ? ' on' : '') + '" data-kind="all">All<em>' + S.collections.length + '</em></button>' +
      kinds.map((k) => '<button class="fchip' + (U.kind === k.k ? ' on' : '') + '" data-kind="' + k.k + '">' + KINDS[k.k] + '<em>' + k.n + '</em></button>').join('') + '</div>' : '') +
    body;
  renderSelectBar();
  if (U.renaming) editTitle($('.ccard[data-col="' + U.renaming + '"] h3'), S.colById[U.renaming], () => { U.renaming = null; });
}

// Rename in place. Return keeps the name, Escape leaves it as it was, an empty name goes back to the date.
function editTitle(h, c, done) {
  if (!h || !c) { done(); return; }
  let cancelled = false;
  h.textContent = c.name || '';
  h.dataset.ph = c.source || defaultTitle(c);
  h.focus({ preventScroll: true });
  const r = document.createRange();
  r.selectNodeContents(h);
  const sel = getSelection();
  sel.removeAllRanges();
  sel.addRange(r);
  h.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Escape') cancelled = true;
    if (e.key === 'Enter' || e.key === 'Escape') { e.preventDefault(); h.blur(); }
  });
  h.addEventListener('paste', (e) => {
    e.preventDefault();
    document.execCommand('insertText', false, (e.clipboardData.getData('text/plain') || '').replace(/\s+/g, ' '));
  });
  h.addEventListener('blur', async () => {
    const name = h.textContent.replace(/\s+/g, ' ').trim().slice(0, 80);
    done();
    if (cancelled || name === (c.name || '') || (!name && c.name === c.source)) { rerender(); return; }
    try {
      await Q.chain;
      await call('/api/name', { id: c.members[0], name: name });
      await reload(c.members[0]);
    } catch (e) { oops(e); rerender(); }
  }, { once: true });
}

/* ---------- selection and the bar that acts on it ---------- */
function renderSelectBar() {
  const n = U.colSel.size, bar = $('#selectbar');
  const on = U.route.name === 'organize' && n > 0 && !U.sheet;
  bar.classList.toggle('show', on);
  if (!on) return;
  const cols = S.collections.filter((c) => U.colSel.has(c.id));
  const anyOff = cols.some((c) => !c.folderOn);
  bar.innerHTML = '<span class="lab">' + n + ' selected</span>' +
    '<button class="act" data-org="merge"' + (n < 2 ? ' disabled' : '') + '>' + ic('merge', 17) + 'Merge</button>' +
    '<button class="act" data-org="rename"' + (n !== 1 ? ' disabled' : '') + '>' + ic('pencil', 16) + 'Rename</button>' +
    '<button class="act" data-org="folder">' + ic('folder', 17) + (anyOff ? 'Make a folder' : 'Keep in main folder') + '</button>' +
    '<span class="gap"></span><button class="act" data-org="clear">Done</button>';
}
function toggleColSel(id) {
  if (U.colSel.has(id)) U.colSel.delete(id); else U.colSel.add(id);
  const card = $('.ccard[data-col="' + id + '"]');
  if (card) card.classList.toggle('sel', U.colSel.has(id));
  $$('#s-library .grid').forEach((g) => g.classList.toggle('picking', U.colSel.size > 0));
  renderSelectBar();
}
function setFolders(cols, on) {
  cols.forEach((c) => { if (!!c.folderOn !== on) { c.folderOn = on; save('/api/folder', { id: c.members[0], on: on }); } });
}
function organize(what) {
  const cols = S.newestFirst.filter((c) => U.colSel.has(c.id));
  if (what === 'clear') { U.colSel.clear(); renderLibrary(); return; }
  if (what === 'rename' && cols.length === 1) { U.renaming = cols[0].id; U.colSel.clear(); renderLibrary(); return; }
  if (what === 'merge' && cols.length > 1) { mergeCollections(cols); return; }
  if (what === 'folder') {
    const on = cols.some((c) => !c.folderOn);
    setFolders(cols, on);
    toast(on ? pl(cols.length, 'collection') + ' will get a folder of ' + (cols.length === 1 ? 'its' : 'their') + ' own when you organize the files' : 'Kept in the main folder', null, 'folder');
    renderLibrary();
  }
}

/* ---------- edits that regroup: the app renumbers collections, so the data is loaded again ---------- */
async function editCollections(op, ids, message, into) {
  try {
    await Q.chain;
    const r = await call('/api/collections', { op: op, ids: ids, into: into });
    U.colSel.clear();
    await reload(r.anchor);
    const c = colOfPhoto(r.anchor);
    toast(op === 'dissolve' ? 'Moved into ' + (c ? colTitle(c) : 'everyday') + '. You can restore it from there.' : message, null, op === 'split' ? 'split' : 'merge');
    if (U.route.name === 'organize' && c) flashCard(c.id);
  } catch (e) { oops(e); }
}
const mergeCollections = (cols) => editCollections('merge', cols.map((c) => c.members[0]), 'Merged ' + pl(cols.length, 'collection') + ' into one.');
function flashCard(id) {
  const card = $('.ccard[data-col="' + id + '"]');
  if (!card) return;
  card.scrollIntoView({ block: 'center', behavior: reduced.matches ? 'auto' : 'smooth' });
  card.classList.add('sel');
  setTimeout(() => { if (!U.colSel.has(id)) card.classList.remove('sel'); }, 1600);
}

function colMenuItems(c) {
  return [
    { icon: 'pencil', label: 'Rename', run: () => { if (U.route.name === 'organize') { U.renaming = c.id; renderLibrary(); } else renameHead(); } },
    { icon: 'merge', label: 'Merge with other collections', run: () => openMerge(c) },
    c.parts > 1 && { icon: 'split', label: 'Split back into ' + c.parts, run: () => editCollections('split', [c.members[0]], 'Split back into the original collections.') },
    NOT_KIND[c.kind] && { icon: 'x', label: NOT_KIND[c.kind], run: () => editCollections('dissolve', [c.members[0]]) },
    '-',
    { icon: 'folder', label: c.folderOn ? 'Keep in the main folder' : 'Make a folder for these photos', run: () => { setFolders([c], !c.folderOn); rerender(); } },
  ].concat((c.folded || []).map((f) => ({ icon: 'undo', label: 'Restore ' + defaultTitle(f), run: () => editCollections('restore', f.anchors, 'Restored as ' + KIND[f.kind].toLowerCase() + '.') })));
}

// One row of a list of collections to pick from (Merge with, Move to).
function pickRow(o, attrs, tail) {
  const cover = coverPhotos(o, 1)[0];
  return '<button class="pk" ' + attrs + '><span class="th">' + (cover ? img(thumbSrc(cover)) : '') + '</span><span class="tx"><b>' + esc(colTitle(o)) + '</b><small>' +
    esc([KIND[o.kind], fmtRange(o, true), pl(o.members.length, 'photo')].join(' · ')) + '</small></span>' + tail + '</button>';
}
const Merge = { c: null, picked: new Set() };
function openMerge(c) {
  Merge.c = c;
  Merge.picked = new Set();
  const others = S.collections.filter((o) => o !== c).sort((a, b) => Math.abs(a.start - c.start) - Math.abs(b.start - c.start));
  openSheet('merge',
    '<div class="shead"><h2>Merge ' + esc(colTitle(c)) + ' with</h2><p>Pick the collections that belong to it. Nearest in time come first.</p></div>' +
    '<div class="sbody"><div class="picks">' + others.map((o) => pickRow(o, 'data-merge-pick="' + esc(o.id) + '" role="checkbox" aria-checked="false"', '<span class="box">' + ic('check', 14) + '</span>')).join('') + '</div></div>' +
    '<div class="sfoot"><button class="btn quiet" data-act="sheet-close">Cancel</button><button class="btn primary" id="merge-go" data-act="merge-go" disabled>Merge</button></div>', true);
}
function mergePick(btn) {
  const id = btn.dataset.mergePick;
  if (Merge.picked.has(id)) Merge.picked.delete(id); else Merge.picked.add(id);
  btn.classList.toggle('on', Merge.picked.has(id));
  btn.setAttribute('aria-checked', String(Merge.picked.has(id)));
  const go = $('#merge-go');
  go.disabled = !Merge.picked.size;
  go.textContent = Merge.picked.size ? 'Merge ' + pl(Merge.picked.size + 1, 'collection') : 'Merge';
}
