'use strict';
/* The large viewer: one photo at full size, the photos around it, and the same keys as the review. */

const V = { id: null };
const viewerOpen = () => V.id !== null;
// Photos you can step through: what is on screen, except groups that are folded away.
function viewerList() {
  return shownIds().filter((id) => { const it = R.view.itemOf.get(id); return id === V.id || !(it.group && collapsed(it.group)); });
}
function openViewer(id) {
  if (!R.view || !R.view.itemOf.has(id)) return;
  V.id = id;
  const el = $('#viewer');
  el.hidden = false;
  el.dataset.id = '';
  // Each part is painted on its own, so a choice (F, K, X) never restarts a video that is playing.
  el.innerHTML = '<div class="vbg"></div><div class="vtop"></div><div class="vmain"><div class="vstage"></div><aside class="vside glass"></aside></div><div class="vfoot"></div>';
  renderActionBar();
  paintViewer();
}
function closeViewer() {
  if (!viewerOpen()) return;
  const id = V.id;
  V.id = null;
  $('#viewer').hidden = true;
  $('#viewer').innerHTML = '';  // also stops a video
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
// The photo or video itself. Drawn when another one is opened, not when its state changes.
function paintStage(id, list, i) {
  const p = S.photos[id], stage = $('#viewer .vstage');
  const nav = (i > 0 ? '<button class="vnav prev glass" data-act="viewer-prev" aria-label="Previous">' + ic('chevL', 20) + '</button>' : '') +
    (i < list.length - 1 ? '<button class="vnav next glass" data-act="viewer-next" aria-label="Next">' + ic('chevR', 20) + '</button>' : '');
  if (isVideo(id) && live(id)) {
    stage.innerHTML = '<video id="vvid" src="' + videoSrc(id) + '" poster="' + midSrc(id) + '" controls autoplay playsinline preload="auto" aria-label="' + esc(baseName(p.rel)) + '"></video>' +
      '<div class="vcant" hidden><p>This video cannot be played here.</p><small>Its format is one the app does not play. It is still organized, kept or removed like the rest.</small></div>' + nav;
    const video = $('#vvid');
    video.addEventListener('error', () => { video.hidden = true; $('#viewer .vcant').hidden = false; });
    const playing = video.play();
    if (playing && playing.catch) playing.catch(() => {});  // not allowed to start by itself: the controls are there
    return;
  }
  stage.innerHTML = '<img id="vimg" src="' + (isVideo(id) ? midSrc(id) : thumbSrc(id)) + '" alt="' + esc(baseName(p.rel)) + '" draggable="false">' + nav;
  // The small picture shows at once; the full one replaces it when it has arrived.
  if (live(id) && !isVideo(id)) {
    const full = new Image();
    full.onload = () => { const now = $('#vimg'); if (V.id === id && now) now.src = full.src; };
    full.src = fullSrc(id);
  }
}
function paintViewer() {
  if (!viewerOpen()) return;
  if (!R.view || !R.view.itemOf.has(V.id)) { closeViewer(); return; }
  const id = V.id, p = S.photos[id], s = eff(id), list = viewerList(), i = list.indexOf(id), video = isVideo(id);
  const it = R.view.itemOf.get(id), c = S.colById[p.collection], h = S.haiku[id];
  const src = S.decisions[id] ? 'Your choice' : h && h.state ? "Claude's pick" : 'Suggested';
  const fact = (k, v) => (v ? '<div class="vf"><small>' + k + '</small><span>' + v + '</span></div>' : '');
  const from = Math.max(0, Math.min(i - 9, list.length - 19)), strip = list.slice(from, from + 19);
  const el = $('#viewer'), what = video ? 'video' : 'photo';
  if (el.dataset.id !== id || el.dataset.at !== i + '/' + list.length) {
    el.dataset.id = id;
    el.dataset.at = i + '/' + list.length;
    $('.vbg', el).style.backgroundImage = 'url(' + thumbSrc(id) + ')';
    paintStage(id, list, i);
  }
  $('.vtop', el).innerHTML = '<button class="btn glass" data-act="viewer-close">' + ic('chevL', 15) + 'Back<span class="key">Esc</span></button>' +
    '<div class="vtitle"><b>' + esc(baseName(p.rel)) + '</b><small>' + esc(fmtTime(p, true)) + (c ? ' · ' + esc(colTitle(c)) : '') + '</small></div>' +
    '<span class="sp"></span><span class="vcount">' + num(i + 1) + ' of ' + num(list.length) + '</span>';
  $('.vside', el).innerHTML =
    '<div class="vstate s-' + s + '"><span class="mark">' + ic(STATE_ICON[s], 15) + '</span><div><b>' + STATE_LABEL[s] + '</b><small>' + (live(id) ? src : 'Moved to _to_remove') + '</small></div></div>' +
    (h && h.why ? '<div class="vnote">' + ic('spark', 14) + '<p>' + esc(h.why) + '</p></div>' : '') +
    fact('The app noted', esc(p.reason || '')) +
    fact('Taken', esc(fmtDay(p))) +
    fact('Length', video ? clock(p.dur) : '') +
    fact('Size', bytes(p.size).t + (p.w && p.h ? ' · ' + num(p.w) + ' x ' + num(p.h) : '')) +
    fact('People', p.me ? 'You are in this ' + what + (p.faces > 1 ? ', with ' + pl(p.faces - 1, 'other') : '') : p.faces ? pl(p.faces, 'face') + (video ? ' in its first moments' : '') : '') +
    fact('Noticed', (p.tags || []).map((t) => ({ blurry: 'Looks blurry', utility: 'Screenshot or document' }[t] || t)).join(', ')) +
    fact('In this group', it.group ? (video ? pl(it.group.members.length, 'copy', 'copies') + ' of this video' : pl(it.group.members.length, 'similar shot')) + (groupDone(it.group) ? ', reviewed' : '') : '') +
    fact('File', '<span class="vpath">' + esc(p.rel) + '</span>');
  $('.vfoot', el).innerHTML = '<div class="vacts glass">' +
      '<button class="act fav' + (s === 'fav' ? ' on' : '') + '" data-do="fav">' + ic('star', 17) + 'Favorite<span class="key">F</span></button>' +
      '<button class="act keep' + (s === 'keep' ? ' on' : '') + '" data-do="keep">' + ic('check', 17) + 'Keep<span class="key">K</span></button>' +
      '<button class="act remove' + (s === 'remove' ? ' on' : '') + '" data-do="remove">' + ic('x', 17) + 'Remove<span class="key">X</span></button>' +
      (video && live(id) ? '<span class="gap"></span><span class="hint"><span class="key">Space</span><span>Play, pause</span></span>' : '') + '</div>' +
    '<div class="vstrip">' + strip.map((x) => '<button class="vs s-' + eff(x) + (x === id ? ' on' : '') + '" data-view-id="' + esc(x) + '" aria-label="' + esc(baseName(S.photos[x].rel)) + '"><img src="' + thumbSrc(x) + '" alt="" draggable="false">' +
      (eff(x) === 'fav' ? '<i>' + ic('star', 10) + '</i>' : '') + (isVideo(x) ? '<em>' + ic('play', 9) + '</em>' : '') + '</button>').join('') + '</div>';
  const next = list[i + 1];
  if (next && live(next) && !isVideo(next)) new Image().src = fullSrc(next);
}
// Space plays and pauses a video; on a photo it closes the viewer, as Return does.
function viewerSpace() {
  const video = $('#vvid');
  if (!video || video.hidden) { closeViewer(); return; }
  if (video.paused) { const p = video.play(); if (p && p.catch) p.catch(() => {}); } else video.pause();
}
function viewerKey(e) {
  const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
  const map = {
    ArrowLeft: () => viewerStep(-1), ArrowRight: () => viewerStep(1), ArrowUp: () => viewerStep(-1), ArrowDown: () => viewerStep(1),
    f: () => applyState('fav'), k: () => applyState('keep'), x: () => applyState('remove'), u: () => applyState(null),
    d: () => { reviewAndAdvance(); if (viewerOpen() && R.view && R.view.itemOf.has(R.cursor)) { V.id = R.cursor; paintViewer(); } },
    Enter: closeViewer, ' ': viewerSpace,
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
