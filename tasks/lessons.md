# Lessons

## Test a new edit against every edit that already exists

- Pattern: a new step in an ordered pipeline (here `apply_edits` in `group.py`) was verified only on its
  own. Moving photos into an everyday month that had taken in a folded "not an event" lost the move:
  moves ran before the fold, so they targeted the not-yet-folded event, and the fold then sent every
  photo back to the month of its own date.
- Rule: when adding an edit type, write down the order of all edit types and test each pair on real
  shapes of data (a merged collection, a month that absorbed a folded event, a filed photo), and check
  the user's real edit file on a copy before calling it done.

## When files can move, check every reader of file paths

- Pattern: filing photos into folders worked in the server, but `group.py` (run on every collection
  edit) still looked for photos at their original paths and dropped every filed photo from the page.
- Rule: when adding anything that moves or renames files, list every place that opens or checks a path
  (`group.py` load, `faces.py`, previews, `/full/`, undo) and test a collection edit and a full rerun
  while files are moved. Compare folders with `os.path.samefile`, never path strings (symlinks such as
  `/tmp` -> `/private/tmp`).

## A reskin is not a redesign

- Pattern (2026-11-24): asked to make the app "feel like a modern app", I kept the layout of the old
  review page (fixed list sidebar, tab bar, bordered cards, thin progress bars, red outlines) and
  changed colors, radii and a few native screens around it. The user's verdict on the pictures:
  "this looks like very old app ui". My reading of why: every surface is a box with a 1 px border,
  the main workspace is a dense web page inside a plain native window, controls are defaults, photos
  are small, and nothing about the structure changed.
- Rule: when the ask is about how something looks or feels, do not start from the existing layout.
  Name the reference points first (current apps the result should sit next to), decide what the
  structure becomes, and show the direction as a picture before building all of it. One screen done
  boldly and confirmed beats eight screens recolored.
- Rule: judge my own screenshots against those references before sending them, and say plainly when a
  screen is only recolored.
