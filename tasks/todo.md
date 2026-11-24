# Photo cleanup - plan

Goal: go through thousands of photos in one folder, group shots of the same people in a similar pose,
pick a favorite per group, mark the rest for removal, and review/adjust everything in a local web page.
Organize by trips and events (date + location) and clean up inside each.

Code: this folder (see README.md).

## Steps

- [x] 1. Swift analyzer (`analyze`): Apple Vision feature print, face capture quality, aesthetics + utility flag, Laplacian sharpness, EXIF time, GPS, 480px thumbnails; incremental reruns; nearest-neighbor index via Accelerate
- [x] 2. Grouping (`group.py`): duplicate (any time) / burst (15 s) / scene (10 min) rules with complete linkage; ranking by face quality, aesthetics, sharpness, resolution
- [x] 3. Collections: home detection, moments, trips, day trips, events (20+ photos on a home day), everyday months; offline only
- [x] 4. Haiku review: numbered contact sheet per group (`sheet`), batches, prompt, validated merge (missing answers never remove anything)
- [x] 5. Local server: data API, decisions saved per click, HEIC/RAW previews, move to `_to_remove` with undo log
- [x] 6. Review page v1, verified in the browser (states, keyboard, lightbox, save, move/undo via API)
- [x] 7. Fable redesign around trips and events, then verify end to end
- [x] 7b. Keep-you policy: aligned face crops + local ArcFace (faces.py), you-first ranking, second distinct shot of you kept, aggressive pruning of photos without you, reasons on every automatic decision, YOU badges for Haiku, "Photos of you" view
- [x] 8. Run on the real folder (`/Volumes/KRUTIK/TEMP - Archieve/Pictures/2026`, output in `../photo-cleanup-data/2026`), Haiku review, open the page
- [ ] 9. Final move to `_to_remove` only when the user clicks it

## Safety

- Original files are never modified, renamed, or deleted. The only file operation is a user-triggered move into `_to_remove`, logged and undoable.
- All output (thumbnails, JSON) lives outside the photo folder.
- GPS coordinates are never sent to any service.

## Findings along the way

- Vision feature prints jitter under concurrency: byte-identical files can be up to ~0.036 apart, so "duplicate" means < 0.06 and the same pixel dimensions.
- `sips -Z` also upscales; previews only pass it when shrinking.
- Haiku cost is dominated by per-tool-call overhead, not image tokens: contact sheets plus ~20 groups per agent keep it low.
- Haiku first kept near-identical "backups"; the prompt now says near-identical copies of the favorite are removed.

## Review

Verified on a generated 97-photo library with real EXIF dates and GPS (everyday at home, birthday event, 4-day trip ~249 km away, day trip, screenshots):
- Collections detected exactly as generated; cleanup groups land inside their trip/event.
- Haiku reviewed 25 groups in 2 batches (~94k tokens for a 20-group batch), merged with 0 problems.
- Fable redesign: overview with cover cards and "Up next", sidebar of trips/events, collection view with groups then other photos, rename (names.json), per-group "reviewed" (reviewed.json), hash routing. Checked at 1400px and 620px.
- Real move of 44 photos to `_to_remove` and undo through the page: all 97 files back, folder removed.
- Scale: 1,290 photos analyzed in 7.7 s, grouped in 0.08 s.

Face matching tested on 15 stock images from app bundles: the 7 images of the reference person scored 0.75-1.0, all others <= 0.14 (threshold 0.36). Found and fixed along the way: symlinked files were skipped, empty folders crashed the analyzer, and photos of you could be grouped with photos of other people.

Real folder (2026-11-24): `/Volumes/KRUTIK/TEMP - Archieve/Pictures/2026` -> `../photo-cleanup-data/2026`, reference photo in `me/krutik.jpg` there.
- 1,547 photos (videos are not analyzed) in 2 min 48 s from the external drive, 0 errors; 438 of them are Finder copies ("name 2.JPG"), giving 125 exact-duplicate groups.
- Faces: you in 309 of 745 photos with faces; clean gap between matches and non-matches (12 faces between 0.2 and 0.36). Recall drops for sunglasses and motion blur with one reference photo.
- 316 groups, 42 collections (4 trips, 11 day trips, 15 events, 12 everyday months). On-device: 1,162 to remove.
- Haiku: 191 groups in 11 batches, ~1.14M tokens, 2.7 min, merged with 0 problems; it rescued 84 photos (1,078 to remove after merge). Every group with you keeps a photo of you.
- Fixed along the way: a group card without a Haiku note rendered the text "null" (native append with null); app files were cached heuristically by the browser, so `server.py` now sends `Cache-Control: no-cache` for them.

# Fix up collections + folder per collection - plan

Three additions to the review page:
- merge trips/events/months into one collection,
- mark a collection that is not really a trip or event, so its photos go back to everyday,
- a per-collection switch "Make a folder after cleanup" that files the kept photos into a folder named
  after it.

Everything is page state until the very end: merges, "not a trip" marks and folder switches only
change what the page shows. No file moves until you click Move once the whole review is finished.

## Collection edits (merge, not a trip)

- Storage: `<out>/collection_edits.json`:
  `{"merges": [[[photoId, ...] per part], ...], "not_collections": [{"photos", "names", "folders"}, ...]}`.
  An edit lists the photos of the collections it was made on and applies to the collection holding
  most of them now, so it stays valid when a rerun adds, removes or regroups photos.
- Applied in `group.py` right after `build_collections`, before grouping:
  1. merges: a merged collection gets recomputed start/end/days/center/distance from home, `parts`
     and its kind by priority: away (trip if it spans several days, else day trip) > event > everyday;
  2. "not a trip/event": that collection's photos fold into the everyday collection of their month(s)
     (created if missing); the everyday collection lists what was folded in, so the page can offer
     "Restore".
  Grouping then runs on the edited collections: near-repeats across merged parts can group together.
- Server: `POST /api/collections {op: "merge" | "split" | "dissolve" | "restore", ids}` updates the
  file, reruns `group.py` (well under a second) and returns a photo of the resulting collection.
  When merging, if the earliest part has no name but another part does, that name moves over.
- Decisions, reviewed marks and Haiku picks are keyed by photo id, so nothing you did is lost. New
  groups that span old parts have no Haiku pick until `prepare_review.py` runs again.
- Page (collection header):
  - "Merge..." opens a picker of the other collections, nearest in time first, with checkboxes;
    "Merge N" confirms and opens the merged collection. A merged one shows "Merged from N" + "Split".
  - "Not a trip" / "Not an event" (hidden for everyday months) folds it into everyday and opens the
    month it went to; that month shows "Includes photos from Trip · Oct 16 - 19 · Restore".
  - Titles of multi-day events and multi-month everyday collections show a date range.

## Folder after cleanup

- Storage: `<out>/folders.json`, `[[photoId, ...] per collection]`; names likewise in `names.json`. A switch in the collection header, with
  "N kept photos will move to <photo folder>/<folder name>/ when you click Move" under it.
- Folder name: see open question. Sanitized for the file system (no `/` or `:`, no leading dot, max 80
  chars). An existing folder with that name is reused; file name clashes get " (2)".
- Move button (the final step): photos marked remove -> `_to_remove` (as today), then kept photos (fav
  and keep) of each collection with the switch on -> its folder, together with a same-name Live Photo
  `.MOV`. The confirm dialog lists both. Every file move is logged in `moves.jsonl` (`op: "file"`)
  and Undo puts everything back.
- Server state: `moved` (in `_to_remove`, dimmed) and `filed` (in a folder, shown normally with a
  folder badge); the full-size view reads each photo from where it is now.
- Reruns: photo ids come from the path, so filed photos get new ids on the next `run.sh`. When filing,
  the server also writes your state under the new ids (decision = what you kept, reviewed, names,
  collection edits, folder switches), so a rerun never suggests removing what you kept and filed.
  The old entries stay, so the page keeps working until the rerun and after an undo.

## Steps

- [x] C1. `group.py`: read `collection_edits.json`; merges, "not a trip", `parts`/`folded` fields
- [x] C2. `server.py`: `/api/collections` (merge, split, dissolve, restore; rerun group.py; carry names)
- [x] C3. Page: Merge picker, Merged from N + Split, Not a trip + Restore, date-range titles
- [x] F1. `server.py`: `folders.json`, `/api/folder`, filing in `/api/apply`, `moved` + `filed`, undo, id carry-over
- [x] F2. Page: switch + destination preview, confirm dialog, folder badge
- [x] V1. Verify on a scratch copy of ~80 real photos (never the real folder): merge, split, not a
      trip, restore, rename, switch, Move, Undo, rerun after filing keeps decisions; desktop and narrow
- [x] V2. README: the new state files and the final Move step

## Decided

1. Folder name: date first, `2026-10-16 Seattle`, or `2026-10-16 Trip` when not renamed (everyday: `2026-10 Everyday`).
2. Live Photos: the same-name `.MOV` moves with a filed photo (only 4 pairs in the 2026 folder, no `.AAE`).

## Review

Built as planned, with two changes found during verification:
- Edits are stored with all photos of the collection they were made on (merges per part, names and
  folder switches per collection) and apply to the collection holding most of those photos. The first
  version matched "any photo", and a rerun after Move pulled a whole everyday month into a merged trip:
  one trip photo without GPS lost its neighbors and drifted into the month. Drifted photos are now
  pulled back on their own.
- `group.py` was not deterministic: exact copies tie on score and their order came from a Python set, so
  210 photos flipped their automatic state between two identical runs. Ties now go to the original
  name, then the shorter path. On the real library this only swapped identical copies (144 photos,
  removal count unchanged at 1,037).

Verified on a scratch copy of 126 real photos (`scenario.py`, all checks pass): merge 3, rename, folder
switch, merge again (keeps 4 parts), split, re-merge, not an event + restore (name and folder switch
come back), Move (95 to `_to_remove`, 11 filed into 2 folders, Live Photo videos along), rerun (merge,
name and switch survive; filed photos stay kept; no month pulled in), Undo (all 130 files back, folders
removed). Checked in the browser at desktop and phone width. Real library regrouped and its server
restarted on the new code; both existing names resolve.

Known, not changed: an event needs 20+ photos, counted after cleanup, so a rerun after Move can turn a
cleaned-up event into an everyday month (seen in the scenario: 53 -> 8 photos).

# Move photos to another collection - plan

Select any photos and move them into another trip, event or month. Page state only (no files move
until the final Move), and it survives reruns.

- Storage: `collection_edits.json` gets `"moves": [{"photos": [photoId, ...], "into": [photoId, ...]}]`;
  `into` is the target collection's photos, so the move applies to the collection holding most of them
  now. A newer move of a photo replaces its older one.
- `group.py`: after merges and before "not a trip", pull the moved photos out of wherever they are into
  the target (a day trip that gains photos on other days becomes a trip; emptied collections disappear).
- `server.py`: `/api/collections` op `move` with `ids` + `into`; id carry-over covers moves.
- Page: a check on every photo (on hover, always while selecting), Shift-click for a range, `S` key,
  "Select" on each group card, Esc clears. A bar at the bottom: "N selected · Move to… · Clear".
  "Move to…" lists collections nearest in time first; picking one moves the photos and keeps you on the
  collection you were looking at.

## Steps

- [x] P1. `group.py` + `server.py`: moves edit, op, carry-over
- [x] P2. Page: selection, bottom bar, Move to picker, shortcut and help
- [x] P3. Verify on the scratch library (move a group and singles, rerun, move back), desktop + phone
- [x] P4. README

## Review

Verified on the scratch library: Select on a group + a single photo + Shift range + `S` key + Esc;
Move to… lists other collections nearest first; 3 photos moved from Everyday · October (28 -> 25)
into Seattle Fall (35 -> 38) and the page stayed on October although its id changed; the move survived
a rerun; moving them back replaced the older move (one stored move, sizes back to 28 / 35). Checked
the selected state and bottom bar at desktop and narrow width. Real server restarted on the new code.

# UI/UX pass around the real workflow - plan

How the page is used: (1) Organize: go over every trip, event and month, merge the ones that belong
together, mark the ones that are not really trips/events. (2) Review: go collection by collection and
review its groups. (3) Finish: Move once at the very end.

Today the page is built around neither step. Organizing means opening each collection, then a text-only
Merge dialog. Reviewing means scrolling past a ~400px header and walls of loud red "Remove" flags, with
reviewed groups taking as much room as open ones. The final Move is a red button that is always on screen,
confirmed with a native `confirm()`.

Seen on the real library (1440x900):
- Overview cards have different heights: a portrait cover stretches its `aspect-ratio` box (bug).
- A 16-photo group with 14 removes is 14 red borders + red labels; the 2 keepers are the hard thing to find.
- Collection header (title, tools, two "Includes photos from..." notes, stats box, folder switch) fills half
  the screen before the first group.
- Library views (9 rows) sit above the collections in the sidebar, the collections are below the fold.
- Titles repeat across years ("Everyday · April" twice) in the Merge and Move to pickers.

## The three steps become the spine

Top bar: `Organize · Review · Finish` as three tabs (no numbers), each with a short status
("18 collections", "64 of 317 groups", "1,249 to move"). The red Move button leaves the top bar.

## Organize (replaces the cover-card overview)

One row per collection, oldest first so neighbors in time sit next to each other:
- kind icon, title (year added when it repeats), dates, photo count, distance from home for trips;
- a strip of 8-10 thumbnails (favorites first, then best scored) so you can see what it is; click a
  thumbnail or the title to open the collection;
- between two rows, the gap ("2 days later"); when two neighbors look like one trip/event (both away
  and under ~2 days apart, or same kind on the same/next day) a quiet "Merge these" link sits in the gap;
- a checkbox per row; checking 2+ shows the bottom bar "N selected · Merge · Clear" (same bar as photo
  selection);
- row actions on hover: Rename (inline), Not a trip / Not an event, Split (merged ones), and for
  everyday months that absorbed something: Restore.
No page navigation is needed for the whole organize pass. The Merge... dialog in the collection header
stays as a secondary path, now with a cover thumbnail per row.

## Review (the collection page)

- Compact header: kind icon, title + Rename, one meta line, an inline progress bar "12 of 39 groups",
  primary "Review next group". Merge / Split / Not a trip move into a "More" menu. The folded notes
  collapse into one line ("Includes 274 photos from 2 events you unmarked · Show"). The folder switch
  becomes a small toggle in the header.
- Sticky slim progress under the top bar once the header scrolls away: title, "12 of 39", Next collection.
- Group cards:
  - keepers first (favorite, then keep), removes after them in time order;
  - removes dimmed (about 40% opacity, small x in the corner, no red border or label); favorite keeps
    its gold frame; hover or cursor brings a dimmed photo to full opacity;
  - one line of badges: kind, You, Close call / Haiku (the Haiku reason stays as the line under it);
  - actions: "Mark reviewed (D)" as the main button, Keep all / Reset / Select in a "More" menu.
- Reviewed groups collapse into one short row (small thumbnails of the keepers, "Kept 2 of 16",
  Reopen), so the page shrinks as you work and the next group is always near the top.
- End of a collection: a panel after the last group "All 39 groups reviewed · Next: Philly ->"; `D` on
  the last open group shows it and `Enter` (or `N`) goes on. Same "Next collection" in the sticky bar.

## Finish (replaces the always-on red button and `confirm()`)

A page that lists exactly what Move will do: N photos (size) into `_to_remove`, then per collection
whether its kept photos get filed into a folder, with the folder switch for each one right there (so
the switches can be set in one place) and the target folder name. One "Move N photos" button, an
in-page confirm step, then the result and Undo. Groups still not reviewed are listed as a warning, not
a blocker.

## Sidebar

Collections by year, with progress bars, as now; Library views in a folded section at the top.
Totals footer stays.

## Small fixes on the way

- Overview/organize covers: fixed size boxes (`min-height: 0` / absolute img) so cards never stretch.
- Year in titles that repeat across years, in pickers and the sidebar tooltip.
- Merge and Move to pickers: a small cover per row.

## Not changing

Data model, server API, keyboard shortcuts (F K X U D S, arrows, Enter, Esc), lightbox, file safety.
Only `app/*` changes, plus `README.md` for the new layout. The uncommitted "move photos to another
collection" work (P1/P2 above) is kept and verified as part of V1 (its P3/P4).

## Steps

- [x] U1. Top bar step tabs, routes `#organize` (default), `#review` (next collection), `#finish`; sidebar reorder
- [x] U2. Organize view: rows with thumbnail strips, gaps, merge hints, row selection + Merge bar, inline rename, row actions
- [x] U3. Collection page: compact header, More menu, folded line, sticky progress, end-of-collection panel
- [x] U4. Group cards: keepers first, dimmed removes, trimmed badges, More menu, collapsed reviewed groups
- [x] U5. Finish page: plan, folder switches, in-page confirm, result + Undo
- [x] U6. Small fixes: cover sizing, years in repeated titles, picker covers
- [x] V1. Verify on the scratch library (never the real folder): organize pass (merge via hint and via
      selection, not a trip, restore, split, rename), review pass with D through a whole collection to the
      next, move photos to another collection + rerun, Finish -> Move -> Undo; desktop 1440, 900 and phone
- [x] V2. README

## Review

Built as planned, with these changes found while building and checking it:
- Organize lists collections newest first, like the sidebar and Review (neighbors in time sit next to
  each other either way), and has no gap rows between them: everyday months overlap the trips inside
  them, so "N days later" between rows meant little. The merge hint sits in the row instead.
- Merge hint: a trip, day trip or event that starts at most two calendar days after the previous one ends.
  Overlaps are left out (on the real library the only hint was "Camping with Fam overlaps with
  Concerts", a merged event spanning months). The real library shows no hints now; the scratch library
  showed "2 days after Day trip · Wed, Oct 14" for Seattle Fall, which is the split it was made from.
- Library views moved to a folded line at the top of the sidebar rather than the bottom: one line, always
  reachable, collections still start right below.
- Reviewed groups fold to a row with the kept photos; the arrow keys and the viewer skip folded groups.
  `D` on the last group scrolls to the other photos (or the end panel) and `N` goes on.
- Anything scrolled into view leaves room for the progress bar under the tabs (it appears once the
  header scrolls away, so a margin set only while it is visible was too late).
- The old overview, its cover cards (and their height bug), the always-on Move/Undo buttons and the
  native `confirm()` dialogs are gone.
- Mobile layout is not a goal (said during the work); only basic narrow-width rules were kept.

Verified on a copy of the scratch library (126 real photos, `review-ux` in `.claude/launch.json`):
- Organize: select 2 rows -> Merge 2 (stays on Organize, row flashes), Split, Restore, Not an event,
  inline rename, the hint's Merge them.
- Review: `#review` opens the next collection; `D` through all 4 groups folds them, scrolls to the other
  photos, the bar and end panel offer the next collection, `N` opens it; Show / Hide; More menus
  (collection and group) open, Esc closes; keepers first and the viewer's strip in the same order.
- Move photos to another collection from the selection bar (3 photos to Portland weekend).
- Finish: switch on a folder (counts update), Move -> in-page confirm -> 95 photos in `_to_remove`,
  14 filed into 3 folders; Undo all moves -> all 130 files back, folders removed.
- All library views render without errors. Checked at 1440 and 900 px; the real library viewed read-only
  (Organize, a collection, Finish).
