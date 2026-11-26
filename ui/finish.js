'use strict';
/* Finish: the two steps that touch files. Organize into folders, then clean up. Each asks first, in
   place, and each has its own undo. Nothing is ever deleted. */

const Fin = { ask: null };  // the step being confirmed: "organize", "dups", "cleanup", or "undo-" + step
function openFinish() {
  if (!S.loaded) return;
  Fin.ask = null;
  openSheet('finish', '', true);
  renderFinish();
}
// The foot of a step: its button, the question in place of it, and its own undo.
function stepFoot(step, n, done, text, off) {
  if (Fin.ask === step) {
    return '<div class="ffootr ask"><p><b>' + text.ask + '</b> ' + text.sentence + '</p><button class="btn small quiet" data-fin="cancel">Cancel</button>' +
      '<button class="btn small ' + (text.danger ? 'danger' : 'primary') + '" data-fin="run:' + step + '">' + text.yes + '</button></div>';
  }
  if (Fin.ask === 'undo-' + step) {
    return '<div class="ffootr ask"><p><b>' + text.undoAsk + '</b></p><button class="btn small quiet" data-fin="cancel">Cancel</button>' +
      '<button class="btn small primary" data-fin="undo:' + step + '">Yes, put them back</button></div>';
  }
  return '<div class="ffootr"><p>' + (off || (n ? text.sentence : text.idle)) + '</p>' +
    (done && text.undo ? '<button class="btn small quiet" data-fin="ask:undo-' + step + '"' + (off ? ' disabled' : '') + '>' + ic('undo', 13) + text.undo + '</button>' : '') +
    '<button class="btn small ' + (text.danger ? 'danger' : 'primary') + '" data-fin="ask:' + step + '"' + (n && !off ? '' : ' disabled') + '>' + (n ? text.go : 'Nothing to move') + '</button></div>';
}
function renderFinish() {
  if (U.sheet !== 'finish') return;
  const m = movePlan(), t = S.total, f = folderNow(), root = baseName(S.root.replace(/\/+$/, ''));
  const filedN = Object.keys(S.filed).length, movedN = S.moved.size;
  const off = f && !f.connected ? 'The folder is not connected. Files can move again when it is back.' : '';

  // Step one: organize the files by collection. Can happen before the review.
  const rows = S.newestFirst.map((c) => {
    const p = folderPlan(c);
    let sub;
    if (c.folderOn) sub = (p.toFile ? files(p.toFile) + ' into ' : 'All in ') + '<code>' + esc(c.folder) + '/</code>' + (p.filed && p.toFile ? ' · ' + num(p.filed) + ' already there' : '');
    else sub = p.toBack ? files(p.toBack) + ' go back where they came from' : c.source ? 'In your folder <code>' + esc(c.source) + '/</code>' : 'Photos stay where they are';
    return '<div class="frow"><span class="fk">' + ic(c.kind, 15) + '</span><span class="tx"><b>' + esc(colTitle(c)) + '</b><small>' + sub + '</small></span>' +
      '<button class="switch" role="switch" aria-checked="' + !!c.folderOn + '" data-fin-switch="' + esc(c.id) + '" aria-label="Make a folder for ' + esc(colTitle(c)) + '"></button></div>';
  }).join('');
  const orgN = m.toFile + m.toBack, orgParts = [];
  if (m.toFile) orgParts.push(files(m.toFile) + ' into ' + pl(m.folders.length, 'folder'));
  if (m.toBack) orgParts.push(files(m.toBack) + ' back where they came from');
  const orgLead = orgN ? orgParts.join(', ') : filedN ? 'The folders match your collections' : 'Switch on the collections that should get a folder';
  const organizeStep = '<section class="fstep"><div class="fh"><span class="fi">' + ic('folder', 18) + '</span><div><h3>Organize files</h3><div class="lead">' + orgLead + '</div>' +
    '<p>Every photo of a switched-on trip, event or month moves into a folder named after its date and name. You can do this before reviewing, and run it again after renaming or moving photos.</p></div></div>' +
    (rows ? '<div class="frows">' + rows + '</div>' : '') +
    stepFoot('organize', orgN, filedN, {
      go: 'Organize ' + files(orgN), ask: 'Move ' + orgParts.join(', and ') + ' now?', sentence: 'Nothing is deleted, and you can keep reviewing afterwards.',
      yes: 'Yes, organize ' + files(orgN),
      idle: filedN ? files(filedN) + ' ' + isAre(filedN) + ' in collection folders.' : 'Nothing is organized into folders yet.',
      undo: 'Undo organize', undoAsk: 'Put the ' + pl(filedN, 'filed photo') + ' back where they came from?',
    }, off) + '</section>';

  // Step two: clean up, best done once everything is reviewed. Exact copies need no judgment, so
  // they can go first and take their groups off the review list.
  const dupGroups = S.groups.filter((g) => g.kind === 'duplicate');
  let dups = 0, dupBytes = 0, dupOpen = 0;
  for (const g of dupGroups) {
    if (!groupDone(g)) dupOpen++;
    for (const id of g.members) if (live(id) && eff(id) === 'remove') { dups++; dupBytes += S.photos[id].size; }
  }
  const open = S.newestFirst.filter((c) => S.stats.get(c.id).left);
  const rmIds = S.order.filter((id) => live(id) && eff(id) === 'remove').slice(0, 8);
  const cleanStep = '<section class="fstep"><div class="fh"><span class="fi rm">' + ic('trash', 18) + '</span><div><h3>Clean up</h3><div class="lead">' +
    (m.remove ? tallyRemove(t) + ' to remove · ' + bytes(m.bytes).t : movedN ? 'Everything marked remove is in _to_remove (' + num(movedN) + ')' : 'Nothing marked for removal') + '</div>' +
    '<p>They move into <code>' + esc(root) + '/_to_remove/</code>, from wherever they are now, keeping their subfolders. Delete that folder yourself once you are sure.</p></div>' +
    (m.remove ? '<button class="btn small glass" data-fin="see">See them</button>' : '') + '</div>' +
    (rmIds.length ? '<div class="strip">' + rmIds.map((id) => img(thumbSrc(id))).join('') + '</div>' : '') +
    (dupGroups.length ? '<div class="fpart"><div class="lead">' + (dups ? pl(dups, 'duplicate copy', 'duplicate copies') + ' · ' + bytes(dupBytes).t : 'No duplicate copies left') + '</div>' +
      '<p>Exact copies of photos you keep, in ' + pl(dupGroups.length, 'group') + '. Nothing to judge, so they can go first' + (dupOpen ? ', and their ' + pl(dupOpen, 'group') + ' ' + isAre(dupOpen) + ' marked reviewed.' : '.') + '</p>' +
      stepFoot('dups', dups, 0, {
        go: 'Remove duplicate copies', ask: 'Move ' + pl(dups, 'duplicate copy', 'duplicate copies') + ' (' + bytes(dupBytes).t + ') to _to_remove now?',
        sentence: 'Only the extra copies go; the copy you keep stays. Undo clean-up puts them back.', yes: 'Yes, remove the copies', danger: true, idle: '',
      }, off) + '</div>' : '') +
    (open.length ? '<div class="fwarn">' + ic('warn', 16) + '<span>' + pl(t.left, 'group') + ' in ' + pl(open.length, 'collection') + ' ' + isAre(t.left) + ' not reviewed yet. Their suggestions are used as they are.</span>' +
      '<button class="btn small glass" data-fin="review">Keep reviewing</button></div>' : '') +
    stepFoot('cleanup', m.remove, movedN, {
      go: 'Move ' + files(m.remove) + ' to _to_remove', ask: 'Move ' + files(m.remove) + ' (' + bytes(m.bytes).t + ') to _to_remove now?',
      sentence: 'Nothing is deleted, and Undo clean-up puts them back where they were.', yes: 'Yes, move ' + files(m.remove), danger: true,
      idle: movedN ? files(movedN) + ' ' + isAre(movedN) + ' in _to_remove.' : 'Nothing is in _to_remove yet.',
      undo: 'Undo clean-up', undoAsk: 'Put the ' + files(movedN) + ' in _to_remove back where they were?',
    }, off) + '</section>';

  const body = $('#sheet .sbody'), top = body ? body.scrollTop : 0, rtop = $('#sheet .frows') ? $('#sheet .frows').scrollTop : 0;
  $('#sheet').innerHTML = '<div class="shead"><h2>Finish</h2><p>Two steps that move files, each with its own undo. <b>Nothing is deleted.</b></p></div>' +
    '<div class="sbody">' + organizeStep + cleanStep + '</div>' +
    '<div class="sfoot"><button class="btn quiet" data-act="sheet-close">Done</button></div>';
  $('#sheet .sbody').scrollTop = top;
  if ($('#sheet .frows')) $('#sheet .frows').scrollTop = rtop;
}

async function runMove(url, describe, body) {
  try {
    await Q.chain;
    const r = await call(url, body || {});
    Fin.ask = null;
    await reload();
    renderFinish();
    refreshApp();
    toast(describe(r) + (r.errors.length ? ' (' + r.errors.length + ' failed: ' + r.errors[0] + ')' : ''), r.errors.length ? 'err' : null, 'folder');
  } catch (e) { Fin.ask = null; renderFinish(); oops(e); }
}
function runStep(step) {
  if (step === 'organize') {
    runMove('/api/organize', (r) => {
      const done = [];
      if (r.filed) done.push('Moved ' + files(r.filed) + ' into ' + pl(r.folders, 'folder'));
      if (r.back) done.push((done.length ? 'put ' : 'Put ') + files(r.back) + ' back where they came from');
      return done.length ? done.join(', ') + '.' : 'The folders already matched your collections.';
    });
  } else if (step === 'dups') {
    runMove('/api/cleanup', (r) => (r.moved ? 'Moved ' + pl(r.moved, 'duplicate copy', 'duplicate copies') + ' to _to_remove.' : 'No duplicate copies to move.') +
      (r.reviewed ? ' ' + pl(r.reviewed, 'group') + ' of duplicates marked reviewed.' : ''), { only: 'duplicates' });
  } else {
    runMove('/api/cleanup', (r) => (r.moved ? 'Moved ' + files(r.moved) + ' to _to_remove.' : 'Nothing needed moving.'));
  }
}
function runUndo(step) {
  runMove('/api/undo', (r) => 'Put ' + files(r.restored) + ' back.' +
    (r.skipped ? ' ' + files(r.skipped) + ' ' + isAre(r.skipped) + ' in _to_remove and stayed there: undo the clean-up first.' : ''), { step: step === 'dups' ? 'cleanup' : step });
}

document.addEventListener('click', (e) => {
  if (U.sheet !== 'finish') return;
  let el;
  if ((el = e.target.closest('[data-fin-switch]'))) {
    const c = S.colById[el.dataset.finSwitch];
    if (c) { setFolders([c], !c.folderOn); Fin.ask = null; renderFinish(); }
    return;
  }
  if (!(el = e.target.closest('[data-fin]'))) return;
  const a = el.dataset.fin.split(':');
  if (a[0] === 'ask') Fin.ask = a[1];
  if (a[0] === 'cancel') Fin.ask = null;
  if (a[0] === 'see') { closeSheet(); go(here('view/remove')); return; }
  if (a[0] === 'review') { closeSheet(); go(here('review')); return; }
  if (a[0] === 'run') { el.disabled = true; runStep(a[1]); return; }
  if (a[0] === 'undo') { el.disabled = true; runUndo(a[1]); return; }
  renderFinish();
});
