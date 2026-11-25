'use strict';
/* The opening check and the home screen: space saved, what is waiting, and every photo folder. */

/* ---------- opening check ---------- */
let launchShown = 0, launchT = 0;
function renderLaunch() {
  const el = $('#launch');
  if (!U.launch) { el.classList.add('out'); return; }
  if (!launchShown) launchShown = Date.now();
  const cl = A.claude || {}, n = A.folders.length;
  const st = (kind) => '<span class="st ' + kind + '">' + (kind === 'wait' ? '<i class="spin"></i>' : ic(kind === 'ok' ? 'check' : 'warn', 15)) + '</span>';
  const row = (kind, title, detail) => '<div class="check">' + st(kind) + '<div><b>' + esc(title) + '</b><small>' + esc(detail) + '</small></div></div>';
  const claude = cl.checking ? row('wait', 'Claude for second opinions', 'Looking for the Claude CLI')
    : cl.ready ? row('ok', 'Claude is ready for second opinions', [cl.version ? String(cl.version).replace(/\s*\(.*\)$/, '') : '', cl.detail].filter(Boolean).join(' · '))
    : row('warn', cl.path ? 'Claude is not signed in' : 'Claude is not installed', 'Second opinions are off until it is set up');
  const key = [n, A.faceModel, cl.checking, cl.ready, cl.path].join('|');
  if (el.dataset.key === key) return;  // nothing new: leave the animations alone
  const first = !el.dataset.key;
  el.dataset.key = key;
  el.classList.remove('out');
  el.innerHTML = '<div class="launch-in">' +
    '<img class="lmark" src="/icon.png" alt="" draggable="false">' +
    '<h1>' + esc((A.app && A.app.name) || 'Photo Cleanup') + '</h1><div class="tagline">' + esc((A.app && A.app.tagline) || '') + '</div>' +
    '<div class="checks glass">' +
      row('ok', n ? pl(n, 'photo folder') : 'No photo folders yet', n ? pl(A.folders.reduce((t, f) => t + f.photos, 0), 'photo') + ' analyzed on this Mac' : 'Add one to start. Everything is analyzed on this Mac.') +
      row(A.faceModel ? 'ok' : 'warn', A.faceModel ? 'Face recognition is on this Mac' : 'Face recognition is not in this build', A.faceModel ? 'It finds the photos you are in. Nothing is uploaded.' : 'Photos of you are not picked out.') +
      claude +
    '</div>' +
    (!cl.checking && !cl.ready ? '<div class="setup glass">' + claudeSetup() + '</div>' : '') +
    '<div class="btns">' + (cl.checking || cl.ready ? '' : '<button class="btn glass" data-act="claude">Check again</button><button class="btn primary" data-act="launch-done">Continue without Claude</button>') + '</div>' +
    '</div>';
  if (!first) $$('#launch *:not(.spin)').forEach((e) => { e.style.animationDelay = '0s'; e.style.animationDuration = '.01s'; });
  // All good: stay long enough to be read, then get out of the way.
  clearTimeout(launchT);
  if (!cl.checking && cl.ready) launchT = setTimeout(endLaunch, Math.max(900, 2100 - (Date.now() - launchShown)));
}
function endLaunch() {
  clearTimeout(launchT);
  U.launch = false;
  try { sessionStorage.setItem('launched', '1'); } catch (e) { /* private mode */ }
  $('#launch').classList.add('out');
}

/* ---------- home ---------- */
const coverSrc = (f, id) => '/app/thumb/' + encodeURIComponent(f.id) + '/' + id;
function renderHome() {
  const F = A.folders, t = A.totals || {}, cl = A.claude || {};
  const saved = bytes(t.savedBytes || 0);
  const sum = (k) => F.reduce((n, f) => n + (f[k] || 0), 0);
  const gAll = sum('groups'), gRev = sum('groupsReviewed'), rmAll = sum('toRemove'), rmF = F.filter((f) => f.toRemove > 0).length, wait = bytes(sum('toRemoveBytes'));
  const cards = F.map((f) => {
    const done = f.groups > 0 && f.groupsReviewed >= f.groups;
    const pct = f.groups ? f.groupsReviewed / f.groups : 0;
    const covers = (f.covers || []).slice(0, 4).map((id) => coverSrc(f, id));
    const last = f.savedBytes > 0
      ? '<div><b class="ok">' + bytes(f.savedBytes).t + '</b><small>saved</small></div>'
      : '<div><b' + (f.toRemove ? ' class="rm"' : '') + '>' + num(f.toRemove) + '</b><small>to remove</small></div>';
    return '<div class="fcard' + (f.connected ? '' : ' off') + (covers.length ? '' : ' blank') + '" data-folder="' + esc(f.id) + '" role="button" tabindex="0" aria-label="Open ' + esc(f.name) + '">' +
      (covers[0] ? img(covers[0], 'glow') : '') +
      '<span class="fcard-in">' + (covers.length ? mosaic(covers) : '') + '<span class="scrim"></span>' +
      '<button class="cardbtn" data-folder-menu="' + esc(f.id) + '" aria-label="More for ' + esc(f.name) + '">' + ic('more', 16) + '</button>' +
      '<span class="chipd">' + (f.connected ? esc(ago(f.lastOpened)) : ic('unplug', 12) + 'Not connected') + '</span>' +
      '<span class="fcap"><h3>' + esc(f.name) + '</h3><p>' + esc(f.path) + '</p></span>' +
      '<span class="ffoot"><div><b>' + num(f.photos) + '</b><small>photos</small></div>' +
      '<div class="prog"><b>' + (!f.groups ? (f.photos ? 'No look-alikes' : 'Not scanned yet') : done ? '<span class="ok">All ' + num(f.groups) + ' reviewed</span>' : num(f.groupsReviewed) + ' of ' + num(f.groups) + ' groups') + '</b><div class="track"><i style="width:' + (pct * 100).toFixed(1) + '%"></i></div></div>' +
      last + '</span></span></div>';
  }).join('');
  const hero = F.length
    ? '<div><div class="eyebrow">Space saved so far</div><div class="saved">' + saved.n + '<span>' + saved.u + '</span></div><div class="tag">' + esc((A.app && A.app.tagline) || '') + '</div></div>'
    : '<div><div class="eyebrow">Welcome</div><div class="saved">Keep the best shot.</div><div class="tag">Add a photo folder. Look-alike shots are grouped on this Mac, and you decide what goes.</div></div>';
  $('#s-home').innerHTML =
    '<div class="hero' + (F.length ? '' : ' first') + '">' + hero +
    '<div class="figs glass">' +
      (F.length ? '<div class="fig"><label>Waiting to clean up</label><strong>' + wait.n + '<span>' + wait.u + '</span></strong><small>' + pl(rmAll, 'photo') + ' in ' + pl(rmF, 'folder') + '</small></div>' +
      '<div class="fig"><label>Reviewed' + ring(gAll ? gRev / gAll : 0, 18) + '</label><strong>' + num(gRev) + '<span>of ' + num(gAll) + '</span></strong><small>groups of similar shots</small></div>' : '') +
      '<button class="fig" data-act="launch" title="Show the opening check"><label><i class="dot' + (cl.ready ? '' : ' off') + '"></i>Claude</label><strong>' + (cl.checking ? 'Checking' : cl.ready ? 'Ready' : 'Not set up') + '</strong><small>' + (cl.ready && cl.version ? 'Version ' + esc(String(cl.version).replace(/\s*\(.*\)$/, '')) : cl.checking ? 'Looking for the CLI' : 'Second opinions are off') + '</small></button>' +
    '</div></div>' +
    (F.length ? '<div class="sec"><h2>Folders</h2><p>' + pl(F.length, 'folder') + ' · ' + pl(sum('photos'), 'photo') + '</p></div>' : '') +
    '<div class="folders">' + cards +
      '<button class="addcard glass" data-act="add"><span class="plus">' + ic('plus', 22) + '</span><b>Add a folder</b><small>Choose one, or drop it on the window</small></button>' +
    '</div>' +
    '<div class="note">' + ic('folder', 15) + '<span><b>Nothing is deleted.</b> Clean up moves the photos you remove into a _to_remove folder next to the originals.' +
      (t.waitingBytes ? ' ' + bytes(t.waitingBytes).t + ' is in those folders until you empty them.' : '') + '</span></div>';
}
// A few real photos, blurred far out, give the glass something to hold.
function renderAmbient() {
  const srcs = [];
  if (U.route.name !== 'home' && S.loaded) {
    S.newestFirst.slice(0, 4).forEach((c) => { const id = coverPhotos(c, 1)[0]; if (id) srcs.push(thumbSrc(id)); });
  } else {
    A.folders.forEach((f) => (f.covers || []).forEach((id) => srcs.push(coverSrc(f, id))));
  }
  const key = srcs.slice(0, 4).join(' ');
  const amb = $('#ambient');
  if (amb.dataset.key === key) return;
  amb.dataset.key = key;
  amb.innerHTML = srcs.slice(0, 4).map((s) => '<img src="' + s + '" alt="" draggable="false">').join('');
}

function folderMenu(btn, id) {
  const f = A.folders.find((x) => x.id === id);
  if (!f) return;
  openMenu(btn, [
    { icon: 'arrowR', label: 'Open', run: () => openFolder(f) },
    { icon: 'finder', label: 'Show in Finder', run: () => appAction('reveal', { id: f.id }).catch(oops) },
    '-',
    { icon: 'trash', label: 'Remove from Photo Cleanup', danger: true, run: () => confirmSheet({
      title: 'Remove ' + f.name + ' from Photo Cleanup?',
      body: 'Its review (your choices, names and thumbnails) goes to the Trash. <b>The photos in ' + esc(f.path) + ' are not touched.</b>',
      yes: 'Remove', danger: true,
      run: () => appAction('remove', { id: f.id }).then(() => toast(f.name + ' was removed. Its review is in the Trash.', null, 'trash')).catch(oops),
    }) },
  ]);
}
function openFolder(f) {
  if (!f.connected && !f.photos) { toast(f.name + ' is not connected. Plug the drive back in to scan it.', 'err', 'unplug'); return; }
  go(f.id + '/organize');
}

/* ---------- adding a folder ---------- */
// The app shows the pickers; the page gets paths back. A folder dropped on the window arrives here too.
const Add = { path: '', me: [] };
async function addFolder(path) {
  try {
    if (!path) {
      const r = await appAction('choose', { kind: 'folder' });
      path = r.paths && r.paths[0];
      if (!path) return;
    }
    Add.path = path;
    Add.me = [];
    renderAdd();
  } catch (e) { oops(e); }
}
function renderAdd() {
  const name = Add.path.replace(/\/+$/, '').split('/').pop();
  openSheet('add',
    '<h2>Add ' + esc(name) + '</h2><p>' + esc(Add.path) + '</p>' +
    '<p>The photos are analyzed on this Mac: look-alike shots are grouped and the best of each is suggested. Nothing in the folder changes until you ask.</p>' +
    (A.faceModel ? '<div class="pk" style="margin:16px -6px 0;background:var(--fill)"><span class="th" style="display:grid;place-items:center;color:var(--accent)">' + ic('person', 20) + '</span>' +
      '<span class="tx"><b>' + (Add.me.length ? pl(Add.me.length, 'photo') + ' of you' : 'Photos of you (optional)') + '</b><small>' + (Add.me.length ? esc(Add.me.map((p) => p.split('/').pop()).join(', ')) : 'One to three clear photos, so shots you are in are kept') + '</small></span>' +
      '<button class="btn small glass" data-act="add-me">Choose</button></div>' : '') +
    '<div class="btns"><button class="btn quiet" data-act="sheet-close">Cancel</button><button class="btn primary" data-act="add-go">Add and scan</button></div>');
}
async function addGo() {
  closeSheet();
  try {
    const r = await appAction('add', { path: Add.path, me: Add.me });
    if (r.state && r.state.open) go(r.state.open + '/organize');
  } catch (e) { oops(e); }
}
