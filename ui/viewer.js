'use strict';
/* The large viewer: one photo at full size, the photos around it, and the same keys as the review. */

const V = { id: null };
const viewerOpen = () => V.id !== null;
// Photos you can step through: everything in the view except groups that are folded away.
function viewerList() {
  return R.view.flat.filter((id) => { const it = R.view.itemOf.get(id); return id === V.id || !(it.group && collapsed(it.group)); });
}
function openViewer(id) {
  if (!R.view || !R.view.itemOf.has(id)) return;
  V.id = id;
  $('#viewer').hidden = false;
  renderActionBar();
  paintViewer();
}
function closeViewer() {
  if (!viewerOpen()) return;
  const id = V.id;
  V.id = null;
  $('#viewer').hidden = true;
  $('#viewer').innerHTML = '';
  if (R.view && R.view.itemOf.has(id)) setCursor(id, true);
  renderActionBar();
}
function viewerStep(d) {
  const list = viewerList(), i = list.indexOf(V.id) + d;
  if (i < 0 || i >= list.length) return;
  V.id = list[i];
  setCursor(V.id, false);
  paintViewer();
}
function paintViewer() {
  if (!viewerOpen()) return;
  if (!R.view || !R.view.itemOf.has(V.id)) { closeViewer(); return; }
  const id = V.id, p = S.photos[id], s = eff(id), list = viewerList(), i = list.indexOf(id);
  const it = R.view.itemOf.get(id), c = S.colById[p.collection], h = S.haiku[id];
  const src = S.decisions[id] ? 'Your choice' : h && h.state ? "Claude's pick" : 'Suggested';
  const fact = (k, v) => (v ? '<div class="vf"><small>' + k + '</small><span>' + v + '</span></div>' : '');
  const from = Math.max(0, Math.min(i - 9, list.length - 19)), strip = list.slice(from, from + 19);
  const el = $('#viewer');
  const keepImg = el.dataset.id === id && $('#vimg');
  el.dataset.id = id;
  el.innerHTML =
    '<div class="vbg" style="background-image:url(' + thumbSrc(id) + ')"></div>' +
    '<div class="vtop"><button class="btn glass" data-act="viewer-close">' + ic('chevL', 15) + 'Back<span class="key">Esc</span></button>' +
      '<div class="vtitle"><b>' + esc(baseName(p.rel)) + '</b><small>' + esc(fmtTime(p, true)) + (c ? ' · ' + esc(colTitle(c)) : '') + '</small></div>' +
      '<span class="sp"></span><span class="vcount">' + num(i + 1) + ' of ' + num(list.length) + '</span></div>' +
    '<div class="vmain">' +
      '<div class="vstage"><img id="vimg" src="' + thumbSrc(id) + '" alt="' + esc(baseName(p.rel)) + '" draggable="false">' +
        (i > 0 ? '<button class="vnav prev glass" data-act="viewer-prev" aria-label="Previous photo">' + ic('chevL', 20) + '</button>' : '') +
        (i < list.length - 1 ? '<button class="vnav next glass" data-act="viewer-next" aria-label="Next photo">' + ic('chevR', 20) + '</button>' : '') + '</div>' +
      '<aside class="vside glass">' +
        '<div class="vstate s-' + s + '"><span class="mark">' + ic(STATE_ICON[s], 15) + '</span><div><b>' + STATE_LABEL[s] + '</b><small>' + (live(id) ? src : 'Moved to _to_remove') + '</small></div></div>' +
        (h && h.why ? '<div class="vnote">' + ic('spark', 14) + '<p>' + esc(h.why) + '</p></div>' : '') +
        fact('The app noted', esc(p.reason || '')) +
        fact('Taken', esc(fmtDay(p))) +
        fact('Size', bytes(p.size).t + (p.w && p.h ? ' · ' + num(p.w) + ' x ' + num(p.h) : '')) +
        fact('People', p.me ? 'You are in this photo' + (p.faces > 1 ? ', with ' + pl(p.faces - 1, 'other') : '') : p.faces ? pl(p.faces, 'face') : '') +
        fact('Noticed', (p.tags || []).map((t) => ({ blurry: 'Looks blurry', utility: 'Screenshot or document' }[t] || t)).join(', ')) +
        fact('In this group', it.group ? pl(it.group.members.length, 'similar shot') + (groupDone(it.group) ? ', reviewed' : '') : '') +
        fact('File', '<span class="vpath">' + esc(p.rel) + '</span>') +
      '</aside></div>' +
    '<div class="vfoot"><div class="vacts glass">' +
      '<button class="act fav' + (s === 'fav' ? ' on' : '') + '" data-do="fav">' + ic('star', 17) + 'Favorite<span class="key">F</span></button>' +
      '<button class="act keep' + (s === 'keep' ? ' on' : '') + '" data-do="keep">' + ic('check', 17) + 'Keep<span class="key">K</span></button>' +
      '<button class="act remove' + (s === 'remove' ? ' on' : '') + '" data-do="remove">' + ic('x', 17) + 'Remove<span class="key">X</span></button></div>' +
      '<div class="vstrip">' + strip.map((x) => '<button class="vs s-' + eff(x) + (x === id ? ' on' : '') + '" data-view-id="' + esc(x) + '" aria-label="' + esc(baseName(S.photos[x].rel)) + '"><img src="' + thumbSrc(x) + '" alt="" draggable="false">' + (eff(x) === 'fav' ? '<i>' + ic('star', 10) + '</i>' : '') + '</button>').join('') + '</div></div>';
  // The small picture shows at once; the full one replaces it when it has arrived.
  if (live(id)) {
    const full = new Image();
    full.onload = () => { const now = $('#vimg'); if (V.id === id && now) now.src = full.src; };
    full.src = fullSrc(id);
    if (keepImg && keepImg.src.indexOf('/full/') >= 0) $('#vimg').src = keepImg.src;
  }
  const next = list[i + 1];
  if (next && live(next)) new Image().src = fullSrc(next);
}
function viewerKey(e) {
  const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
  const map = {
    ArrowLeft: () => viewerStep(-1), ArrowRight: () => viewerStep(1), ArrowUp: () => viewerStep(-1), ArrowDown: () => viewerStep(1),
    f: () => applyState('fav'), k: () => applyState('keep'), x: () => applyState('remove'), u: () => applyState(null),
    d: () => { reviewAndAdvance(); if (viewerOpen() && R.view && R.view.itemOf.has(R.cursor)) { V.id = R.cursor; paintViewer(); } },
    Enter: closeViewer, ' ': closeViewer,
  };
  if (map[k]) { e.preventDefault(); map[k](); }
}
document.addEventListener('click', (e) => {
  if (!viewerOpen()) return;
  const t = e.target;
  let el;
  if ((el = t.closest('[data-view-id]'))) { V.id = el.dataset.viewId; setCursor(V.id, false); paintViewer(); return; }
  if ((el = t.closest('#viewer [data-act]'))) {
    if (el.dataset.act === 'viewer-close') closeViewer();
    if (el.dataset.act === 'viewer-prev') viewerStep(-1);
    if (el.dataset.act === 'viewer-next') viewerStep(1);
  }
});
