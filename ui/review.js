'use strict';
/* Review: one collection, or a library-wide view. "One at a time" shows one group of look-alike shots
   per screen, side by side, then the photos with no look-alike; "All" is the whole view as one page of
   bands and days. */

const R = { key: '', view: null, cursor: null, sel: new Set(), selFrom: null, expanded: new Set(), rendered: 0, watch: null,
  step: 0, restSeen: false, sized: null };
const CHUNK = 240;  // photos drawn per batch; more follow as you scroll
let reviewMode = 'one';
try { if (localStorage.getItem('reviewMode') === 'all') reviewMode = 'all'; } catch (e) { /* private mode */ }
// One group per screen: when that is the chosen way and the view has groups to step through.
const oneMode = () => reviewMode === 'one' && !!R.view && R.view.steps.length > 0;
const collapsed = (g) => !oneMode() && groupDone(g) && !R.expanded.has(g.id);
const clampAr = (p) => Math.max(.66, Math.min(1.8, p.w && p.h ? p.w / p.h : 1));

/* ---------- what is on the screen ---------- */
// Keepers first (favorite, then keep), then the rest, each in time order. Worked out when the view is
// built, so a photo never jumps while you change its state.
function displayOrder(g) {
  const rank = (id) => ({ fav: 0, keep: 1, remove: 2 })[eff(id)];
  return g.members.map((id, i) => [id, i]).sort((a, b) => rank(a[0]) - rank(b[0]) || a[1] - b[1]).map((x) => x[0]);
}
function buildView(r) {
  const v = { type: r.name, col: null, lib: null, items: [], groups: [], flat: [], itemOf: new Map(), steps: [], stepOf: new Map() };
  const groupItem = (g) => ({ group: g, order: displayOrder(g) });
  const days = (ids) => {
    const out = [];
    let last = null;
    for (const id of ids) {
      const p = S.photos[id], d = dayIndex(p.time, p.timeKnown);
      if (!out.length || d !== last) { out.push({ day: fmtDay(p), photos: [] }); last = d; }
      out[out.length - 1].photos.push(id);
    }
    return out;
  };
  if (r.name === 'c') {
    const c = (v.col = S.colById[r.id]);
    v.groups = c.groups.map((id) => S.groupById[id]);
    v.items = v.groups.map(groupItem).concat(days(c.members.filter((id) => !S.photos[id].group)));
  } else {
    const lib = (v.lib = LIBRARY_BY_ID[r.id]);
    if (lib.groups) { v.groups = lib.groups(); v.items = v.groups.map(groupItem); } else v.items = days(lib.photos());
  }
  v.items.forEach((it, i) => {
    it.i = i;
    for (const id of it.group ? it.order : it.photos) { v.flat.push(id); v.itemOf.set(id, it); }
  });
  // One at a time: every group is a step, and a collection's photos with no look-alike are the last
  // one, those suggested for removal first (they are the ones to look at).
  v.steps = v.items.filter((it) => it.group);
  const singles = v.items.filter((it) => !it.group);
  if (v.steps.length && v.col && singles.length) {
    const all = [].concat.apply([], singles.map((it) => it.photos));
    const out = all.filter((id) => live(id) && eff(id) === 'remove'), outSet = new Set(out);
    const sections = out.length ? [{ title: 'Suggested for removal', photos: out }] : [];
    for (const it of singles) {
      const left = it.photos.filter((id) => !outSet.has(id));
      if (left.length) sections.push({ title: it.day, photos: left });
    }
    v.steps.push({ rest: true, sections: sections, order: [].concat.apply([], sections.map((x) => x.photos)) });
  }
  v.steps.forEach((st, i) => { for (const id of st.order) v.stepOf.set(id, i); });
  return v;
}
// The photos on screen now, in the order the arrows walk them.
const shownIds = () => (oneMode() ? R.view.steps[R.step].order : R.view.flat);
function firstUnreviewed(from) {
  const gs = R.view.groups;
  for (let k = 0; k < gs.length; k++) {
    const g = gs[((from || 0) + k) % gs.length];
    if (!groupDone(g)) return g;
  }
  return null;
}
const itemIds = (it) => (it.group ? (collapsed(it.group) ? [] : it.order) : it.photos);

/* ---------- drawing ---------- */
// `sharp`: drawn large enough to need the 1,280 px picture instead of the thumbnail.
function tile(id, big, named, sharp) {
  const p = S.photos[id], s = eff(id), moved = !live(id), video = isVideo(id);
  const label = baseName(p.rel) + (video ? ', video, ' + clock(p.dur) : '') + ', ' + STATE_LABEL[s].toLowerCase();
  return '<button class="tile s-' + s + (big ? ' big' : '') + (id === R.cursor ? ' focus' : '') + (R.sel.has(id) ? ' sel' : '') + (moved ? ' moved' : '') + '" data-id="' + esc(id) + '" tabindex="-1" ' +
    'style="--ar:' + clampAr(p).toFixed(3) + (named ? ';view-transition-name:ph-' + esc(id) : '') + '" title="' + esc(baseName(p.rel)) + '" aria-label="' + esc(label) + '">' +
    (big ? img(thumbSrc(id), 'glow') : '') +
    '<span class="timg">' + (big || sharp ? coverImg(id, true) : img(thumbSrc(id))) + '</span>' +
    (moved ? '<span class="flag">In _to_remove</span>' : '<span class="mark">' + ic(STATE_ICON[s], big ? 16 : 13) + '</span>') +
    (S.decisions[id] ? '<span class="mine" title="Changed by you"></span>' : '') +
    (video || p.me ? '<span class="chips">' + (video ? '<span class="chip">' + ic('play', 11) + clock(p.dur) + '</span>' : '') + (p.me ? '<span class="chip">' + ic('person', 12) + 'You</span>' : '') + '</span>' : '') +
    '<span class="size">' + bytes(p.size).t + '</span>' +
    '<span class="pickbox" title="Select (S). Shift-click selects a range.">' + ic('check', 13) + '</span></button>';
}
function groupH4(it) {
  const g = it.group, t = tally(g.members), n = g.members.length;
  const movedN = g.members.filter((id) => !live(id)).length;
  const kind = isVideo(g.members[0]) ? pl(n, 'copy', 'copies') + ' of one video'
    : g.kind === 'duplicate' ? pl(n, 'duplicate') : g.kind === 'near-duplicate' ? pl(n, 'near-duplicate') : pl(n, 'similar shot');
  const where = R.view.type !== 'c' && S.colById[g.collection];
  const gi = R.view.groups.indexOf(g) + 1;
  return esc(kind) +
    (groupDone(g) ? '<span class="tagc rev">' + ic('check', 12) + 'Reviewed</span>' : '') +
    (g.members.some((id) => S.haiku[id]) ? '' : g.close ? '<span class="tagc close">Close call</span>' : '') +
    (g.members.some((id) => S.decisions[id]) ? '<span class="tagc edit">Edited</span>' : '') +
    (movedN ? '<span class="tagc plain">' + movedN + ' in _to_remove</span>' : '') +
    (where ? '<a class="col" data-go="c/' + esc(where.id) + '">' + esc(colTitle(where)) + '</a>' : '') +
    '<span class="saves">Group ' + gi + ' of ' + R.view.groups.length + ' · keeping ' + (t.photos - t.remove) + ' of ' + t.photos + (t.bytes ? ' · frees ' + bytes(t.bytes).t : '') + '</span>';
}
function groupActs(it) {
  const g = it.group, done = groupDone(g), all = g.members.every((id) => R.sel.has(id));
  return '<button class="btn small ' + (done ? 'quiet' : 'glass') + '" data-gact="review">' + ic('check', 13) + (done ? 'Reviewed' : 'Mark reviewed') + '</button>' +
    (done && !oneMode() ? '<button class="btn small quiet" data-gact="hide">Fold away</button>' : '') +
    '<button class="btn small quiet" data-gact="keepall">Keep all</button>' +
    '<button class="btn small quiet" data-gact="reset">Reset</button>' +
    '<button class="btn small quiet" data-gact="select">' + (all ? 'Deselect' : 'Select, to move') + '</button>';
}
function groupWhyHTML(it) {
  const g = it.group, lead = S.photos[it.order[0]], why = groupWhy(g);
  const title = why ? 'Claude compared these shots' : eff(it.order[0]) === 'fav' ? 'Why this one is the favorite' : isVideo(it.order[0]) ? 'About this video' : 'About this photo';
  const text = why || lead.reason;
  return '<span class="ico">' + ic('spark', 15) + '</span><div><b>' + title + '</b>' +
    (text ? '<p>' + esc(text) + '</p>' : '<p class="none">No note for this group yet. Second opinion asks Claude to compare the shots.</p>') + '</div>';
}
function bandHTML(it, named) {
  if (!it.group) {
    return '<section class="band singles" data-i="' + it.i + '"><h4>' + esc(it.day) + ' <small>' + countOf(it.photos) + (R.view.type === 'c' ? ' with no look-alike' : '') + '</small></h4>' +
      '<div class="rest">' + it.photos.map((id) => tile(id)).join('') + '</div></section>';
  }
  const g = it.group;
  if (collapsed(g)) {
    const t = tally(g.members);
    const kept = it.order.filter((id) => live(id) && eff(id) !== 'remove');
    return '<section class="band done" data-i="' + it.i + '" data-g="' + esc(g.id) + '"><div class="keepers">' +
      kept.slice(0, 6).map((id) => '<img src="' + thumbSrc(id) + '" style="--ar:' + clampAr(S.photos[id]).toFixed(3) + '" alt="" draggable="false" loading="lazy">').join('') + '</div>' +
      '<div class="dinfo"><b>' + ic('check', 14) + 'Reviewed</b><span>Kept ' + (t.photos - t.remove) + ' of ' + t.photos + ' · ' + esc(fmtTime(S.photos[g.members[0]], true)) + '</span></div>' +
      '<button class="btn small quiet" data-gact="show">Show</button></section>';
  }
  const n = it.order.length;
  return '<section class="band' + (it === R.view.itemOf.get(R.cursor) ? ' focus' : '') + '" data-i="' + it.i + '" data-g="' + esc(g.id) + '">' + tile(it.order[0], true, named) +
    '<div class="side"><h4>' + groupH4(it) + '</h4>' +
    '<div class="why">' + groupWhyHTML(it) + '</div>' +
    '<div class="fwhy"><i></i><span></span></div>' +
    '<div class="rest' + (n > 11 ? ' many' : n > 6 ? ' mid' : '') + '">' + it.order.slice(1).map((id) => tile(id, false, named)).join('') + '</div>' +
    '<div class="bact">' + groupActs(it) + '</div></div></section>';
}

/* ---------- one group per screen ---------- */
// Splits tiles (by aspect ratio, in order) over `rows` rows of a `W` wide, `H` high box, each row as
// high as its width allows and no higher than its share of the box.
function justify(ars, rows, W, H, gap) {
  const total = ars.reduce((a, b) => a + b, 0), out = [];
  let row = [], sum = 0, done = 0;
  ars.forEach((a, i) => {
    row.push(i);
    sum += a;
    const left = ars.length - i - 1, rowsLeft = rows - out.length - 1;
    if (rowsLeft > 0 && (left === rowsLeft || (left > rowsLeft && done + sum >= total * (out.length + 1) / rows - a / 2))) {
      out.push(row);
      done += sum;
      row = [];
      sum = 0;
    }
  });
  if (row.length) out.push(row);
  const cap = (H - gap * (out.length - 1)) / out.length;
  const heights = out.map((r) => Math.min(cap, (W - gap * (r.length - 1)) / r.reduce((t, i) => t + ars[i], 0)));
  return { rows: out, heights: heights, min: Math.min.apply(null, heights) };
}
// Every shot of the group at once, sized to the room there is: the first (the favorite) on the left
// and clearly the largest, the others next to it in rows. Of all the ways to split the room, the
// one that shows the others largest wins, as long as the favorite still stands out.
function boardHTML(it, W, H, named) {
  const gap = 12, ids = it.order, ar = (id) => clampAr(S.photos[id]), a0 = ar(ids[0]);
  if (ids.length === 1) {
    const h = Math.min(H, W / a0);
    return '<div class="bin"><div class="bhero" style="--bh:' + h.toFixed(0) + 'px">' + tile(ids[0], true, named) + '</div></div>';
  }
  const others = ids.slice(1), ars = others.map(ar), n = ids.length;
  const lead = n === 2 ? 1.25 : n === 3 ? 1.3 : 1.5;  // how much higher than the others the favorite is, at least
  let best = null;
  for (let share = .26; share <= .7001; share += .02) {
    const hw = Math.min(H * a0, W * share), hh = hw / a0, rw = W - hw - gap;
    for (let rows = 1; rows <= Math.min(others.length, 6); rows++) {
      const lay = justify(ars, rows, rw, H, gap), stands = hh >= lead * lay.min;
      const score = lay.min + .25 * hh + (stands ? 1e4 : 0);
      if (!best || score > best.score + .5) best = { score: score, hh: hh, rw: rw, lay: lay };
    }
  }
  const hero = '<div class="bhero" style="--bh:' + best.hh.toFixed(0) + 'px">' + tile(ids[0], true, named) + '</div>';
  // Too many to fit at a size worth looking at: the others scroll.
  if (best.lay.min < 92) {
    const hw = Math.min(H * a0, W * .4), rw = W - hw - gap;
    return '<div class="bin top"><div class="bhero" style="--bh:' + (hw / a0).toFixed(0) + 'px">' + tile(ids[0], true, named) + '</div>' +
      '<div class="bothers scroll" style="width:' + rw.toFixed(0) + 'px;max-height:' + H.toFixed(0) + 'px;--bh:112px">' + others.map((id) => tile(id, false, named)).join('') + '</div></div>';
  }
  return '<div class="bin">' + hero + '<div class="bothers" style="width:' + best.rw.toFixed(0) + 'px">' + best.lay.rows.map((row, k) =>
    '<div class="brow" style="--bh:' + best.lay.heights[k].toFixed(0) + 'px">' + row.map((i) => tile(others[i], false, named, best.lay.heights[k] > 230)).join('') + '</div>').join('') + '</div></div>';
}
function oneGroupHTML(it) {
  return '<section class="band onegroup" data-i="' + it.i + '" data-g="' + esc(it.group.id) + '">' +
    '<h4>' + groupH4(it) + '</h4>' +
    '<div class="gnote"><div class="why">' + groupWhyHTML(it) + '</div><div class="bact">' + groupActs(it) + '</div></div>' +
    '<div class="fwhy"><i></i><span></span></div>' +
    '<div class="board"></div></section>';
}
function restHTML(st) {
  const t = tally(st.order);
  return '<section class="band reststep"><h4>' + (isVideo(st.order[0]) && t.videos === t.photos ? 'Videos' : 'Photos') + ' with no look-alike' +
    '<span class="saves">' + tallyAll(t) + ' · ' + (t.remove ? tallyRemove(t) + ' marked remove · frees ' + bytes(t.bytes).t : 'nothing marked remove') + '</span></h4>' +
    '<div class="restscroll">' + st.sections.map((x) => '<section class="band singles"><h4>' + esc(x.title) + ' <small>' + countOf(x.photos) + '</small></h4>' +
      '<div class="rest">' + x.photos.map((id) => tile(id)).join('') + '</div></section>').join('') +
    '<div class="endp" id="endp" hidden></div></div></section>';
}
// Draws the step that is on: the band first, then its board once the room for it is known.
function drawStep(named) {
  const v = R.view, bands = $('#bands');
  if (!v || !bands || !oneMode()) return;
  R.step = Math.max(0, Math.min(R.step, v.steps.length - 1));
  const st = v.steps[R.step];
  if (st.rest) R.restSeen = true;
  if (v.stepOf.get(R.cursor) !== R.step) R.cursor = st.order[0];
  bands.innerHTML = st.rest ? restHTML(st) : oneGroupHTML(st);
  const board = $('.board', bands);
  if (board) {
    R.sized = board.clientWidth + 'x' + board.clientHeight;
    board.innerHTML = boardHTML(st, board.clientWidth, board.clientHeight, named);
  }
  paintTicks();
  paintWhy();
  paintEnd();
  renderActionBar();
  const t = tileEl(R.cursor);
  if (t) {
    t.focus({ preventScroll: true });
    if (st.rest) t.scrollIntoView({ block: 'nearest' });
  }
}
function paintTicks() {
  const el = $('#ticks'), v = R.view;
  if (!el || !v) return;
  el.innerHTML = v.steps.map((st, i) => {
    const done = !st.rest && groupDone(st.group);
    return '<button class="tick' + (i === R.step ? ' on' : '') + (st.rest ? ' rest' : done ? ' done' : '') + '" data-step="' + i + '" role="tab" aria-selected="' + (i === R.step) + '" ' +
      'title="' + (st.rest ? 'With no look-alike' : 'Group ' + (i + 1) + (done ? ', reviewed' : '')) + '"><i></i></button>';
  }).join('');
}
function goStep(i) {
  if (!oneMode() || i < 0 || i >= R.view.steps.length) return;
  R.step = i;
  R.cursor = R.view.steps[i].order[0];
  drawStep();
  const band = $('#bands > .band');
  if (band) band.classList.add('enter');
}
function setReviewMode(mode) {
  reviewMode = mode;
  try { localStorage.setItem('reviewMode', mode); } catch (e) { /* private mode */ }
  renderReview();
  if (!oneMode() && R.cursor) setCursor(R.cursor, true);
}

const bandEl = (it) => $('#bands > [data-i="' + it.i + '"]');
function refreshBand(it, named) {
  if (oneMode()) { if (R.view.steps[R.step] === it) drawStep(named); return; }
  const el = bandEl(it);
  if (el) el.outerHTML = bandHTML(it, named);
}
function refreshGroupHead(g) {
  const it = R.view && R.view.itemOf.get(g.members[0]), el = it && bandEl(it);
  if (!el || el.classList.contains('done')) return;
  el.querySelector('h4').innerHTML = groupH4(it);
  el.querySelector('.bact').innerHTML = groupActs(it);
}

// The switch between the two ways to review, where there are groups to step through.
function modeSwitch() {
  if (!R.view.steps.length) return '';
  const b = (mode, label) => '<button data-mode="' + mode + '"' + (reviewMode === mode ? ' class="on" aria-pressed="true"' : ' aria-pressed="false"') + '>' + label + '</button>';
  return '<div class="seg glass modesw" role="group" aria-label="How to review">' + b('one', 'One at a time') + b('all', 'All') + '</div>';
}
function headHTML() {
  const v = R.view, slim = oneMode() ? ' slim' : '';
  if (v.lib) {
    return '<div class="head' + slim + '"><div><div class="kicker">Library</div><h1>' + esc(v.lib.label) + '</h1><p>' + esc(v.lib.hint) + '</p></div>' +
      '<div class="right"><div class="ring-lab" id="ringlab"></div>' + modeSwitch() +
      (v.lib.id === 'you' && A.faceModel ? '<button class="btn glass" data-act="me" title="One to three clear photos of you. Every face in the folder is compared with them, on this Mac.">' + ic('person', 15) + 'Choose photos of you</button>' : '') + '</div></div>' +
      (v.items.length ? '' : '<div class="empty">' + esc(v.lib.empty || 'Nothing here.') + '</div>');
  }
  const c = v.col, plan = folderPlan(c);
  let hint;
  if (!c.folderOn) hint = c.source ? 'They are in <code>' + esc(c.source) + '/</code>, a folder of yours, and stay there.' : 'Photos stay where they are.';
  else if (plan.toFile) hint = files(plan.toFile) + ' will move to <code>' + esc(c.folder) + '/</code> when you organize the files in Finish.';
  else hint = 'Everything is in <code>' + esc(c.folder) + '/</code>.';
  if (c.folderOn && plan.filed && plan.toFile) hint += ' ' + files(plan.filed) + ' ' + isAre(plan.filed) + ' already there.';
  const folded = (c.folded || []).map((f, i) => '<div class="fnote">' + ic(f.kind, 15) + '<span>Includes ' + files(f.photos) + ' from <b>' + esc(defaultTitle(f)) + '</b>, which you marked as ' + NOT_KIND[f.kind].toLowerCase() + '.</span>' +
    '<button class="btn small glass" data-restore="' + i + '">' + ic('undo', 13) + 'Restore</button></div>').join('');
  const head = '<div class="head' + slim + '"><div><div class="kicker">' + KIND[c.kind] + '</div><h1 data-rename title="Click to rename">' + esc(colTitle(c)) + '</h1><p>' + esc(colMeta(c).replace(KIND[c.kind] + ' · ', '')) + ' · ' + countOf(c.members) + '</p></div>' +
    '<div class="right"><div class="ring-lab" id="ringlab"></div>' + modeSwitch() +
    '<button class="btn glass icon" data-col-menu="' + esc(c.id) + '" aria-label="More for this collection">' + ic('more', 16) + '</button></div></div>';
  // One group fills the screen: the folder switch and the notes are on the All page and in the menu.
  if (slim) return head;
  return head +
    '<div class="fline"><button class="switch" role="switch" aria-checked="' + !!c.folderOn + '" data-folder-switch aria-label="Make a folder for these photos"></button><span><b>' + (c.source && !c.folderOn ? 'Keep the folder in line with this collection.' : 'Make a folder for these photos.') + '</b> ' + hint + '</span></div>' + folded;
}
function paintHead() {
  const el = $('#ringlab'), v = R.view;
  if (!el || !v) return;
  const st = v.col ? S.stats.get(v.col.id) : Object.assign(tally(v.flat), progress(v.groups));
  el.innerHTML = (st.groups ? ring(st.done / st.groups, oneMode() ? 32 : 40) : '') + '<div><b>' + (st.groups ? st.done + ' of ' + pl(st.groups, 'group') + ' reviewed' : v.col ? 'No look-alikes here' : tallyAll(st)) + '</b><small>' +
    (st.remove ? tallyRemove(st) + ' to remove · ' + bytes(st.bytes).t : 'Nothing marked remove') + '</small></div>';
  paintTicks();
  paintEnd();
}
// The end of a collection: what is left, and where to go next.
function paintEnd() {
  const el = $('#endp'), v = R.view;
  if (!el) return;
  if (!v.col || (!oneMode() && R.rendered < v.items.length)) { el.hidden = true; return; }
  const st = S.stats.get(v.col.id), next = nextCollection(v.col);
  el.hidden = false;
  if (st.left) {
    el.innerHTML = ring(st.done / st.groups, 34) + '<div><b>' + pl(st.left, 'group') + ' still to review</b><small>' + (oneMode() ? 'Each group gets the screen to itself.' : 'Reviewed groups fold away, so what is left stays easy to find.') + '</small></div>' +
      '<button class="btn primary" data-act="next-group">Review the next group<span class="key">N</span></button>';
    return;
  }
  const what = !st.groups ? 'Nothing to review here' : st.groups === 1 ? 'The group is reviewed' : 'All ' + pl(st.groups, 'group') + ' are reviewed';
  el.innerHTML = '<span class="okc">' + ic('check', 18) + '</span><div><b>' + what + '</b><small>' + (next ? 'Up next: ' + esc(colTitle(next)) + ' · ' + colStatus(S.stats.get(next.id)) : 'Every trip, event and month is reviewed. Finish when you are ready.') + '</small></div>' +
    (next ? '<button class="btn primary" data-go="c/' + esc(next.id) + '">Next: ' + esc(colTitle(next)) + ic('arrowR', 15) + '</button>' : '<button class="btn primary" data-act="finish">Finish' + ic('arrowR', 15) + '</button>');
}

function renderReview() {
  const r = U.route, key = r.folder + '/' + r.name + '/' + r.id, same = R.key === key;
  const keepN = same ? R.rendered : 0;
  R.key = key;
  if (!same) { R.sel.clear(); R.selFrom = null; R.expanded.clear(); R.cursor = null; R.restSeen = false; }
  const v = (R.view = buildView(r));
  R.sel = new Set(Array.from(R.sel).filter((id) => v.itemOf.has(id)));
  if (!v.itemOf.has(R.cursor) || !itemIds(v.itemOf.get(R.cursor)).length) R.cursor = startCursor();
  const one = oneMode(), scr = $('#s-review');
  if (R.watch) R.watch.disconnect();
  scr.classList.toggle('one', one);
  $('#app').classList.toggle('selecting', R.sel.size > 0);
  R.rendered = 0;
  if (one) {
    scr.innerHTML = headHTML() + '<div class="ticks" id="ticks" role="tablist" aria-label="Groups"></div><div class="bands" id="bands"></div>';
    R.step = v.stepOf.has(R.cursor) ? v.stepOf.get(R.cursor) : 0;
    paintHead();
    drawStep();
    // The board is laid out for the room it has: a resized window lays it out again.
    R.watch = new ResizeObserver(() => { const b = $('#bands .board'); if (b && R.sized !== b.clientWidth + 'x' + b.clientHeight) drawStep(); });
    R.watch.observe($('#bands'));
    return;
  }
  scr.innerHTML = headHTML() + '<div class="bands" id="bands"></div><div class="endp" id="endp" hidden></div><div id="sentinel" style="height:1px"></div>';
  fill(Math.max(keepN, R.cursor ? v.itemOf.get(R.cursor).i + 1 : 0));
  R.watch = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) fill(); }, { root: scr, rootMargin: '1400px' });
  R.watch.observe($('#sentinel'));
  paintHead();
  paintWhy();
  renderActionBar();
}
// Where the highlight starts: the first group that still needs a look, else the first photo.
function startCursor() {
  const g = R.view.groups.length ? firstUnreviewed() : null;
  if (g) return R.view.itemOf.get(g.members[0]).order[0];
  const it = R.view.items.find((x) => itemIds(x).length);
  return it ? itemIds(it)[0] : null;
}
function fill(upTo) {
  const v = R.view, bands = $('#bands');
  if (!v || !bands || oneMode()) return;
  let n = 0, html = '';
  while (R.rendered < v.items.length && (n < CHUNK || R.rendered < (upTo || 0))) {
    const it = v.items[R.rendered++];
    html += bandHTML(it);
    n += it.group ? it.order.length : it.photos.length;
  }
  if (html) bands.insertAdjacentHTML('beforeend', html);
  paintEnd();
}
function ensureRendered(id) {
  if (oneMode()) { const i = R.view.stepOf.get(id); if (i !== undefined && i !== R.step) { R.step = i; R.cursor = id; drawStep(); } return; }
  const it = R.view.itemOf.get(id);
  if (it && it.i >= R.rendered) fill(it.i + 1);
}

/* ---------- the highlight ---------- */
const tileEl = (id) => $('#bands .tile[data-id="' + id + '"]');
function setCursor(id, scroll) {
  if (!id || !R.view.itemOf.has(id)) return;
  const it = R.view.itemOf.get(id);
  if (it.group && collapsed(it.group)) { R.expanded.add(it.group.id); refreshBand(it); }
  ensureRendered(id);
  const old = tileEl(R.cursor), oldBand = old && old.closest('.band');
  if (old) old.classList.remove('focus');
  if (oldBand) oldBand.classList.remove('focus');
  R.cursor = id;
  const t = tileEl(id);
  if (t) {
    t.classList.add('focus');
    const band = t.closest('.band');
    if (band.dataset.g) band.classList.add('focus');
    if (scroll) {
      (!oneMode() && (t.classList.contains('big') || band.dataset.g) ? band : t).scrollIntoView({ block: 'nearest', behavior: reduced.matches ? 'auto' : 'smooth' });
      t.focus({ preventScroll: true });
    }
  }
  paintWhy();
  renderActionBar();
}
// The line under Claude's note: what the app saw in the highlighted photo, when it is not the large one.
function paintWhy() {
  const p = S.photos[R.cursor], it = R.view && R.view.itemOf.get(R.cursor);
  $$('#bands .fwhy.on').forEach((el) => { el.className = 'fwhy'; });
  if (!it || !it.group || it.order[0] === R.cursor || !p.reason) return;
  const el = bandEl(it) && bandEl(it).querySelector('.fwhy');
  if (!el) return;
  el.className = 'fwhy on s-' + eff(R.cursor);
  el.lastChild.textContent = p.reason;
}
function moveCursor(d) {
  const flat = shownIds();
  let i = flat.indexOf(R.cursor);
  if (i < 0) { setCursor(startCursor(), true); return; }
  for (i += d; i >= 0 && i < flat.length; i += d) {
    const it = R.view.itemOf.get(flat[i]);
    if (!(it.group && collapsed(it.group))) { setCursor(flat[i], true); return; }
  }
}
// Up and down follow what is on screen: the nearest photo in the row above or below, in this band
// first, then in the next band that shows its photos.
function moveVertical(d) {
  const cur = tileEl(R.cursor);
  if (!cur) { setCursor(startCursor(), true); return; }
  const c = cur.getBoundingClientRect(), cx = c.left + c.width / 2;
  const pick = (tiles) => {
    let best = null, bestRow = Infinity, bestDx = Infinity;
    for (const t of tiles) {
      const r = t.getBoundingClientRect();
      if (d > 0 ? r.top < c.bottom - 4 : r.bottom > c.top + 4) continue;
      const row = d > 0 ? r.top : -r.bottom, dx = Math.abs(r.left + r.width / 2 - cx);
      if (row < bestRow - 6 || (Math.abs(row - bestRow) <= 6 && dx < bestDx)) { best = t; bestRow = row; bestDx = dx; }
    }
    return best;
  };
  const here = pick($$('.tile', cur.closest(oneMode() ? '#bands' : '.band')).filter((t) => t !== cur));
  if (here) { setCursor(here.dataset.id, true); return; }
  if (oneMode()) return;  // the arrows stay inside the group on screen
  const items = R.view.items;
  for (let i = R.view.itemOf.get(R.cursor).i + d; i >= 0 && i < items.length; i += d) {
    const ids = itemIds(items[i]);
    if (!ids.length) continue;
    ensureRendered(ids[0]);
    const near = pick($$('.tile', bandEl(items[i])));
    setCursor(near ? near.dataset.id : ids[0], true);
    return;
  }
}

/* ---------- choices ---------- */
function paintTile(id) {
  const s = eff(id), p = S.photos[id];
  $$('#bands .tile[data-id="' + id + '"]').forEach((t) => {
    t.classList.remove('s-fav', 's-keep', 's-remove');
    t.classList.add('s-' + s);
    const big = t.classList.contains('big');
    const mark = t.querySelector('.mark');
    if (mark) mark.innerHTML = ic(STATE_ICON[s], big ? 16 : 13);
    const mine = t.querySelector('.mine');
    if (S.decisions[id] && !mine) t.querySelector('.timg').insertAdjacentHTML('afterend', '<span class="mine" title="Changed by you"></span>');
    if (!S.decisions[id] && mine) mine.remove();
    t.setAttribute('aria-label', baseName(p.rel) + (isVideo(id) ? ', video, ' + clock(p.dur) : '') + ', ' + STATE_LABEL[s].toLowerCase());
  });
}
// F, K, X and U act on the selected photos, or on the highlighted one.
function applyState(state) {
  const ids = (R.sel.size ? Array.from(R.sel) : R.cursor ? [R.cursor] : []).filter(live);
  if (!ids.length) return;
  const changes = {};
  ids.forEach((id) => { changes[id] = state; });
  // A group has one favorite: starring another shot turns the earlier favorite into a keep.
  const g = state === 'fav' && ids.length === 1 ? S.groupById[S.photos[ids[0]].group] : null;
  if (g) g.members.forEach((m) => { if (m !== ids[0] && live(m) && eff(m) === 'fav') changes[m] = 'keep'; });
  // Taking a star back gives it to the shot that had it by suggestion.
  if (state === null) {
    ids.forEach((id) => {
      const og = S.decisions[id] === 'fav' && S.groupById[S.photos[id].group];
      if (og) og.members.forEach((m) => { if (!(m in changes) && S.decisions[m] === 'keep' && suggestion(m) === 'fav') changes[m] = null; });
    });
  }
  setStates(changes);
  afterStates(Object.keys(changes), state === 'fav' && ids.length === 1 ? ids[0] : null);
}
function afterStates(ids, starred) {
  ids.forEach(paintTile);
  const groups = new Set(ids.map((id) => S.photos[id].group).filter(Boolean));
  // A newly starred photo takes the large place in its group.
  const it = starred && R.view.itemOf.get(starred);
  if (it && it.group && it.order[0] !== starred && eff(starred) === 'fav') {
    refreshBand(it, true);  // name the photos so they can glide to their new places
    morph(() => {
      it.order = [starred].concat(it.order.filter((x) => x !== starred));
      R.view.flat = [].concat.apply([], R.view.items.map((x) => (x.group ? x.order : x.photos)));
      refreshBand(it, true);
    });
    setTimeout(() => { $$('.tile', bandEl(it) || document.createElement('div')).forEach((t) => { t.style.viewTransitionName = ''; }); }, 700);
  }
  groups.forEach((gid) => refreshGroupHead(S.groupById[gid]));
  paintCounts();
  paintHead();
  paintWhy();
  renderActionBar();
  if (typeof paintViewer === 'function') paintViewer();
}
function markReviewed(g, on) {
  setReviewed(g, on);
  R.expanded.delete(g.id);  // marking reviewed folds the group away
  const it = R.view.itemOf.get(g.members[0]);
  if (oneMode()) refreshGroupHead(g); else if (it) refreshBand(it);
  paintCounts();
  paintHead();
}
// D: this group is done, on to the next one that is not. One at a time, the photos with no
// look-alike come after the last group, once.
function reviewAndAdvance() {
  const it = R.view.itemOf.get(R.cursor), one = oneMode(), onRest = one && R.view.steps[R.step].rest;
  if (it && it.group && !groupDone(it.group)) markReviewed(it.group, true);
  const from = it && it.group ? R.view.groups.indexOf(it.group) + 1 : 0;
  const next = R.view.groups.length ? firstUnreviewed(from) : null;
  if (next) { focusGroup(next); return; }
  const last = R.view.steps[R.view.steps.length - 1];
  if (one && !onRest && last.rest && !R.restSeen) { goStep(R.view.steps.length - 1); return; }
  if (R.view.col) {
    const col = nextCollection(R.view.col);
    if (col) { toast('On to ' + colTitle(col), null, 'arrowR'); go(here('c/' + col.id)); return; }
    if (!S.total.left) { openFinish(); return; }
  }
  renderActionBar();
  toast(R.view.groups.length ? 'Every group here is reviewed.' : 'Nothing to review here.', null, 'check');
}
function focusGroup(g) {
  const it = R.view.itemOf.get(g.members[0]);
  if (oneMode()) { goStep(R.view.steps.indexOf(it)); return; }
  ensureRendered(it.order[0]);
  setCursor(it.order[0], false);
  const el = bandEl(it);
  if (el) el.scrollIntoView({ block: 'start', behavior: reduced.matches ? 'auto' : 'smooth' });
}

/* ---------- selecting photos, and moving them to another collection ---------- */
function selectIds(ids, on) {
  ids.forEach((id) => { if (on) R.sel.add(id); else R.sel.delete(id); });
  ids.forEach((id) => $$('#bands .tile[data-id="' + id + '"]').forEach((t) => t.classList.toggle('sel', on)));
  new Set(ids.map((id) => S.photos[id].group).filter(Boolean)).forEach((gid) => refreshGroupHead(S.groupById[gid]));
  $('#app').classList.toggle('selecting', R.sel.size > 0);
  renderActionBar();
}
function toggleSelect(id, range) {
  const flat = shownIds();
  if (range && R.selFrom && flat.indexOf(R.selFrom) >= 0) {
    const a = flat.indexOf(R.selFrom), b = flat.indexOf(id);
    selectIds(flat.slice(Math.min(a, b), Math.max(a, b) + 1), true);
    return;
  }
  R.selFrom = id;
  selectIds([id], !R.sel.has(id));
}
function clearSelection() {
  selectIds(Array.from(R.sel), false);
  R.selFrom = null;
}
function openMoveTo() {
  const ids = Array.from(R.sel);
  if (!ids.length) return;
  const at = Math.min.apply(null, ids.map((id) => S.photos[id].time));
  const targets = S.collections.filter((c) => !ids.every((id) => S.photos[id].collection === c.id)).sort((a, b) => Math.abs(a.start - at) - Math.abs(b.start - at));
  openSheet('moveto',
    '<div class="shead"><h2>Move ' + countOf(ids) + ' to</h2><p>They become part of that collection. Nothing moves on disk until you organize the files.</p></div>' +
    '<div class="sbody"><div class="picks">' + targets.map((c) => pickRow(c, 'data-move-to="' + esc(c.id) + '"', ic('arrowR', 15))).join('') + '</div></div>' +
    '<div class="sfoot"><button class="btn quiet" data-act="sheet-close">Cancel</button></div>', true);
}
async function moveSelected(dest) {
  const ids = Array.from(R.sel), moving = new Set(ids), v = R.view, title = colTitle(dest), what = countOf(ids);
  // Stay on the collection you were looking at (its id can change when regrouping).
  const stay = v.col ? v.col.members.find((id) => !moving.has(id)) : null;
  closeSheet();
  try {
    await Q.chain;
    await call('/api/collections', { op: 'move', ids: ids, into: dest.members[0] });
    R.sel.clear();
    R.selFrom = null;
    await reload(stay || ids[0]);
    toast('Moved ' + what + ' to ' + title + '.', null, 'arrowR');
  } catch (e) { oops(e); }
}

/* ---------- the floating bar ---------- */
function renderActionBar() {
  const bar = $('#actionbar');
  const on = (U.route.name === 'c' || U.route.name === 'view') && !U.sheet && !!R.view && R.view.flat.length > 0 && !(typeof viewerOpen === 'function' && viewerOpen());
  bar.classList.toggle('show', on);
  if (!on) return;
  const n = R.sel.size, s = !n && R.cursor ? eff(R.cursor) : null;
  const acts = '<button class="act fav' + (s === 'fav' ? ' on' : '') + '" data-do="fav">' + ic('star', 17) + 'Favorite<span class="key">F</span></button>' +
    '<button class="act keep' + (s === 'keep' ? ' on' : '') + '" data-do="keep">' + ic('check', 17) + 'Keep<span class="key">K</span></button>' +
    '<button class="act remove' + (s === 'remove' ? ' on' : '') + '" data-do="remove">' + ic('x', 17) + 'Remove<span class="key">X</span></button>';
  if (n) {
    bar.innerHTML = '<span class="lab">' + countOf(Array.from(R.sel)) + ' selected</span>' + acts + '<span class="gap"></span>' +
      '<button class="act" data-act="move-to">' + ic('arrowR', 17) + 'Move to</button><button class="act" data-act="sel-clear">Clear</button>';
    return;
  }
  const it = R.view.itemOf.get(R.cursor), done = it && it.group && groupDone(it.group);
  // What D does from here: mark this group, or go on to what is next.
  let next = 'Mark reviewed';
  if (done || !(it && it.group)) {
    const one = oneMode(), last = R.view.steps[R.view.steps.length - 1];
    next = firstUnreviewed() ? 'Next group' : one && last.rest && !R.restSeen ? 'The rest' : R.view.col && nextCollection(R.view.col) ? 'Next collection' : R.view.col && !S.total.left ? 'Finish' : 'Next group';
  }
  bar.innerHTML = '<span class="hint"><span class="key">&larr;</span><span class="key">&rarr;</span><span>Move</span></span>' + acts +
    (R.view.groups.length ? '<span class="gap"></span><button class="act primary" data-do="done">' + next + '<span class="key">D</span></button>' : '');
}

/* ---------- renaming from the head ---------- */
function renameHead() {
  const h = $('#s-review h1[data-rename]'), c = R.view && R.view.col;
  if (!h || !c || h.isContentEditable) return;
  h.contentEditable = 'true';
  h.spellcheck = false;
  editTitle(h, c, () => { h.contentEditable = 'false'; });
}

/* ---------- events ---------- */
document.addEventListener('click', (e) => {
  const t = e.target;
  let el;
  if (!R.view || (U.route.name !== 'c' && U.route.name !== 'view')) return;
  if ((el = t.closest('#bands .tile'))) {
    const id = el.dataset.id;
    if (t.closest('.pickbox') || e.shiftKey || e.metaKey) { toggleSelect(id, e.shiftKey); setCursor(id, false); } else setCursor(id, false);
    return;
  }
  if ((el = t.closest('[data-gact]'))) {
    const band = el.closest('.band'), g = S.groupById[band.dataset.g], it = R.view.itemOf.get(g.members[0]);
    switch (el.dataset.gact) {
      case 'review': markReviewed(g, !groupDone(g)); break;
      case 'show': R.expanded.add(g.id); refreshBand(it); setCursor(it.order[0], false); break;
      case 'hide': R.expanded.delete(g.id); refreshBand(it); break;
      case 'keepall': { const ch = {}; g.members.filter(live).forEach((id) => { ch[id] = eff(id) === 'fav' ? 'fav' : 'keep'; }); setStates(ch); afterStates(Object.keys(ch)); break; }
      case 'reset': { const ch = {}; g.members.filter(live).forEach((id) => { ch[id] = null; }); setStates(ch); afterStates(Object.keys(ch)); break; }
      case 'select': selectIds(g.members, !g.members.every((id) => R.sel.has(id))); break;
    }
    return;
  }
  if ((el = t.closest('[data-do]'))) { if (el.dataset.do === 'done') reviewAndAdvance(); else applyState(el.dataset.do); return; }
  if ((el = t.closest('[data-step]'))) { goStep(+el.dataset.step); return; }
  if ((el = t.closest('[data-mode]'))) { if (el.dataset.mode !== reviewMode) setReviewMode(el.dataset.mode); return; }
  if (t.closest('h1[data-rename]')) { renameHead(); return; }
  if ((el = t.closest('[data-folder-switch]'))) { setFolders([R.view.col], !R.view.col.folderOn); rerender(); return; }
  if ((el = t.closest('[data-restore]'))) {
    const f = R.view.col.folded[+el.dataset.restore];
    editCollections('restore', f.anchors, 'Restored as ' + KIND[f.kind].toLowerCase() + '.');
    return;
  }
  if ((el = t.closest('[data-move-to]'))) { const c = S.colById[el.dataset.moveTo]; if (c) moveSelected(c); }
});
document.addEventListener('dblclick', (e) => {
  const el = e.target.closest('#bands .tile');
  if (el && !e.target.closest('.pickbox')) openViewer(el.dataset.id);
});
// New photos of you for this folder: the app asks for them, then matches every face again.
async function chooseMe() {
  try {
    const r = await appAction('choose', { kind: 'me' });
    if (!r.paths || !r.paths.length) return;
    await appAction('me', { paths: r.paths.slice(0, 3) });
    toast('Looking for you in every photo of this folder.', null, 'person');
  } catch (e) { oops(e); }
}
function reviewAct(a) {
  if (a === 'me') chooseMe();
  if (a === 'move-to') openMoveTo();
  if (a === 'sel-clear') clearSelection();
  if (a === 'next-group') { const g = firstUnreviewed(); if (g) focusGroup(g); }
}
// [ and ]: the group before and after, without marking anything.
function stepGroup(d) {
  if (oneMode()) { goStep(R.step + d); return; }
  const gs = R.view.groups, it = R.view.itemOf.get(R.cursor);
  if (!gs.length) return;
  const at = it && it.group ? gs.indexOf(it.group) : d > 0 ? -1 : gs.length;
  const g = gs[Math.max(0, Math.min(gs.length - 1, at + d))];
  if (g) focusGroup(g);
}
function reviewKey(e) {
  if (!R.view) return;
  const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
  const map = {
    ArrowLeft: () => moveCursor(-1), ArrowRight: () => moveCursor(1), ArrowUp: () => moveVertical(-1), ArrowDown: () => moveVertical(1),
    f: () => applyState('fav'), k: () => applyState('keep'), x: () => applyState('remove'), u: () => applyState(null),
    d: reviewAndAdvance,
    '[': () => stepGroup(-1), ']': () => stepGroup(1),
    s: () => { if (R.cursor) toggleSelect(R.cursor, e.shiftKey); },
    n: () => { const it = R.view.itemOf.get(R.cursor), g = firstUnreviewed(it && it.group ? R.view.groups.indexOf(it.group) + 1 : 0); if (g) focusGroup(g); else toast('Every group here is reviewed.', null, 'check'); },
    Enter: () => { if (R.cursor) openViewer(R.cursor); },
    ' ': () => { if (R.cursor) openViewer(R.cursor); },
    Escape: () => { if (R.sel.size) clearSelection(); else go(here('organize')); },
  };
  if (map[k]) { e.preventDefault(); map[k](); }
}
