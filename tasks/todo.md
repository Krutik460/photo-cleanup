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

Bug found in use: moves into an everyday month that had taken in a folded "not an event" were lost
(0 of 76 photos landed). Moves ran before the fold, so their target was the not-yet-folded event, and
the fold then sent each photo to the month of its own date. Moves now run last in `apply_edits`. Checked
on the real edits (copy, then live: 78 of 78 moved photos in their targets, every other collection
unchanged) and on the scratch library through the server, against the previous `group.py` (move lost).

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

# Finish in two steps: organize files, then clean up - plan

The user wants to put photos into their collection folders first and keep reviewing afterwards, so
the Finish page gets two independent steps instead of one Move:

1. Organize files: every photo of the collections whose folder switch is on (except those already in
   `_to_remove`) goes into `<photo folder>/<date> <name>/`, with its Live Photo video. Running it again
   makes the folders match the collections after later edits: photos moved to another collection or a
   renamed collection move along, photos of a collection switched off go back to where they came from,
   emptied folders are removed. Undo organize puts filed photos back where they came from.
2. Clean up: photos marked remove go to `_to_remove` from wherever they are now (a folder included).
   Undo clean-up puts them back where they were just before (their folder, if they were filed).

Details:
- Server: `/api/organize`, `/api/cleanup`, `/api/undo {step}`; `/api/apply` goes. moves.jsonl gains
  op `back` (undo of the last move of a photo); `locations()` pops one entry for it.
- Rerun carry-over no longer turns suggestions into your choices (filing now happens before review):
  explicit choices, Haiku picks (`haiku/carried.json`), reviewed marks, names, folder switches and edits
  are copied to the new ids.
- Page: Finish shows two cards, each with its own plan, button, in-page confirm and Undo; the "not
  reviewed yet" warning moves into the clean-up card. Folder switch texts count all photos, not kept ones.

## Steps

- [x] O1. server.py: organize, cleanup, per-step undo, `back` op, carry-over
- [x] O2. app.js: Finish page in two steps, counts and texts
- [x] O3. Verify on the scratch library: organize -> review -> rename + move a photo -> organize again ->
      clean up -> undo clean-up -> undo organize -> rerun; desktop + narrow

Added while building (user request): **Remove duplicate copies** in the clean-up step moves only the
extra copies of exact-duplicate groups and marks those groups reviewed (125 of 317 groups in the real
library, 128 copies).

## Review

- Found and fixed: after organizing, any collection edit (merge, move, not a trip) rebuilt the
  collections without the filed photos, because `group.py` only looked at original paths. It now reads
  the move log (`current_locations`, shared with the server) and keeps a moved photo until a rerun has
  analyzed it at its new path, so nothing shows twice.
- Found and fixed: "already in its folder" compared path spellings, so `/tmp` vs `/private/tmp` re-filed
  photos as `IMG (2).JPG`; it now compares the folders themselves.
- `scenario2.py` on the scratch library, all checks pass: organize (40 photos, removes included) ->
  rename + organize (folder follows, old one removed) -> move 2 photos to a collection without a
  folder + organize (they go back) -> duplicates first (only the copy, its group reviewed) -> clean-up
  (96 more, 27 of them out of the folder) -> undo clean-up (back into the folder) -> undo organize
  (every file back, folders gone). Also: a merge while filed keeps all 128 photos; a full rerun while
  filed gives 128 unique photos and carries your choice to the new id. Finish page checked in the browser.

# Photo Cleanup as a Mac app (DMG, SQLite, Claude CLI) - plan

## Context

Today the tool is a set of scripts: `setup.sh` and `run.sh` in a terminal, a Haiku review that only
runs when a Claude Code session orchestrates it, `python3 server.py` to open the page, and about ten
JSON files per library as storage. The goal is one installable Mac app: drag it from a DMG, pick a
photo folder, and everything (analysis, face matching, grouping, the second opinion from Claude, the
review, the file moves) happens inside it, with a SQLite database as the store.

Decided with you:
- Only for your own Macs: signed with the Apple Development identity already on this Mac, no
  notarization, the 174 MB face model ships inside the app.
- The app starts your installed `claude` command itself, in the background, using your Claude login.
  Progress, log, cancel and resume live in the app.

## Pake: checked, not a fit

Pake (v3.15+) can package a folder of static files into a DMG, so it could wrap `app/`. But it is
only a web view wrapper: the docs cover no sidecar binaries, no process spawning, no file access
beyond a download folder and no native database. Anything more means forking Pake's Rust source
and writing custom Tauri commands. This app's backend is the hard part and it is Apple-only code
(Vision analysis is already Swift), so Pake would mean a forked GPL Rust project plus Swift helper
binaries plus the page: three languages. On macOS Pake/Tauri render with WKWebView anyway, the same
web view a native Swift app embeds. A native Swift app gives the same result with one language and
no fork, so that is the plan. The page you tuned is reused as is.

## Architecture

One Swift codebase, no Python and no local web server in the shipped app.

```
PhotoCleanup.app
  SwiftUI shell          libraries, add folder, pipeline progress, toolbar, menus, settings
  WKWebView              the existing app/ page (Organize, Review, Finish), loaded through a
                         custom URL scheme, so its relative /api, /thumb, /full calls keep working
  PhotoCleanupCore       Swift package with all logic, testable without the UI
    Store                SQLite via GRDB (migrations, WAL)
    Analyzer             from analyze.swift (Vision feature print, faces, aesthetics, thumbs)
    Faces                ArcFace w600k_r50 converted to Core ML at build time (no runtime dependency)
    Grouping             port of group.py (collections, edits, groups, automatic picks)
    FileOps              organize / clean up / undo, from server.py
    Review               contact sheets (sheet.swift), batches, ClaudeRunner, answer validation
    Router               handle(method, path, body) -> response; the same routes server.py has
```

Key decisions:
- **Web view transport**: a `WKURLSchemeHandler` serves the page files, `/thumb`, `/full` and
  `/api/*` straight from `Router`. `app/app.js` needs no transport changes. Nothing listens on a
  port, so no other process or browser tab can trigger file moves.
- **Debug bridge for verification**: debug builds accept `--serve <port>`, which exposes the same
  `Router` on 127.0.0.1 so the page can be driven by the browser tools exactly as today. Not in
  release builds.
- **Faces run on Core ML** (changed 2026-11-24, decided with you: the ONNX Runtime repositories
  are gone from GitHub). `w600k_r50.onnx` is converted once at build time (onnx2torch, then
  coremltools, Float32) and the script checks the result against ONNX Runtime before it is used.
  The shipped app has no third-party runtime. The 0.36 threshold stays valid (see spike c).
- **Not sandboxed** (it must run `claude` and work in any folder or external drive); Info.plist
  carries the usage strings for removable volumes, Documents, Desktop and Downloads. Signing with
  the Apple Development identity keeps those permissions stable across rebuilds.
- **macOS 15 or later**, which is what the analyzer's Vision requests already require.
- Project generated with XcodeGen (`project.yml`, already installed); dependencies: GRDB.
  Nothing else.

## SQLite design

One database per library: `~/Library/Application Support/Photo Cleanup/Libraries/<uuid>/library.sqlite`,
next to its `thumbs/`, `faces/`, `previews/`, `sheets/` caches. The library list is a scan of that
folder (each database knows its photo folder and name), so there is no second registry to keep in
sync. Deleting a library is deleting its folder.

This fixes two root problems of the JSON design instead of carrying them over:
- **Photo identity no longer comes from the path.** A photo is a row with a stable id, its current
  relative path, its original path and a cheap fingerprint (size, modified time, hash of the first
  and last 64 KB). The app updates the path in the same step as a move, and a rescan re-links files
  moved in Finder by fingerprint. `carry_over` (copying every choice to new ids after filing) and
  the replay of `moves.jsonl` (`current_locations`) disappear. There is exactly one place that
  knows where a photo is (lesson 2 in `tasks/lessons.md`).
- **Every change is a transaction**, replacing ten independently rewritten JSON files.

Tables (sketch):
- `photo` - path, original path, fingerprint, size, dims, times, GPS, feature print, sharpness,
  aesthetics, utility flag, location (in place / filed / to remove), `me_sim`; derived: score,
  group, collection, automatic state and reason
- `face` (box, quality, crop, embedding), `neighbor` (a, b, distance), `reference_face`
- derived, rebuilt in one transaction per regroup: `collection`, `grp`
- your state: `decision`, `reviewed`, `ai_pick` (state, why, batch)
- edits: `anchor_set` + `anchor_set_photo` (the photos an edit was made on, applied to the
  collection holding most of them now - the existing rule, kept because it survives regrouping),
  used by `collection_name`, `folder_switch`, `edit_merge_part`, `edit_move`, `edit_not_collection`
- `file_move` - journal for undo. Written as an intent before the file moves and completed after;
  unfinished intents are reconciled at launch, so a crash mid-move never loses track of a file
- `review_batch` - status, timing, cost, error; makes the Claude run resumable

## Claude CLI integration

- **Finding it**: a GUI app does not get the shell's PATH. Order: path set in Settings, then
  `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, then asking a login
  shell (`zsh -lic 'command -v claude'`). Settings shows the path, version and login state, with a
  clear message when it is missing or signed out.
- **One process per batch** (about 20 groups, as today), 3 at a time by default:
  `claude -p --model haiku --output-format json --json-schema <schema> --tools "" --no-session-persistence --strict-mcp-config`,
  run from the library's `sheets/` folder. Not `--bare`: that mode ignores the Claude login.
- **No tools at all**: the contact sheets go in as image blocks of the prompt
  (`--input-format stream-json`) and the answer comes back as schema-validated JSON on stdout. The
  model cannot read or write any file, and the per-tool-call overhead that dominated cost before
  is gone. Fallback if the spike shows image input does not work this way: `--tools Read` limited
  to the sheets folder.
- Prompt: `haiku_prompt.md` minus the file-reading and file-writing instructions.
- **Validation** keeps the rules of `merge_review.py`: a missing or malformed answer changes
  nothing, an unmentioned photo is kept, a group with you always keeps a photo of you.
- **In the app**: a "Second opinion" toolbar button with "N of M batches", picks appearing in the
  page as batches land, a log sheet (batch start, finish, error, stderr), Cancel, and Resume of
  unfinished batches on the next click. Model and parallelism are in Settings.
- Privacy is unchanged and stated next to the button: contact sheets of thumbnails go to Anthropic
  through your CLI; GPS, file names and face data never leave the Mac.

## The app shell

- First launch and File > Add Photo Folder: pick a folder, optionally drop 1-3 photos of you, Start.
- Pipeline view: Analyze, Find you, Group, with counts, a cancel button and a list of files that
  failed. Rescan (toolbar and File menu) is incremental, as `run.sh` is today.
- Main window: toolbar (library switcher, Rescan, Second opinion, Settings) above the page. Standard
  Mac menus and shortcuts; the page keeps its own keys (F K X U D S N, arrows, Enter, Esc).
- Photo folder unavailable (drive unplugged): a banner, and file steps stay disabled, as today.
- Native controls and system colors only; no custom chrome.

## Existing 2026 library

File > Import Review Data reads the old output folder (`../photo-cleanup-data/2026`). The photos are
re-analyzed natively (about 3 minutes) and only your state is imported, matched through the old id
(SHA-1 of the relative path, recomputable for every photo): 
`decisions.json`, `reviewed.json`, `haiku/*.json`, `names.json`, `folders.json`,
`collection_edits.json`, `reference_path.txt`. That library has no `moves.jsonl` (no file has been
moved yet), so the importer refuses a folder with outstanding moves rather than handling them.

No longer true (seen 2026-11-24 16:16): the old page organized the real library while this work
was running. `moves.jsonl` now has 2,029 entries, 751 photos are filed into 6 folders, 128 went to
`_to_remove` and are logged as `gone`, an operation added to `server.py` and `group.py` by another
session after `6e29afe`. The importer therefore has to follow the move log to find each photo's
current path, and steps 3, 5 and 8 must be ported from the Python as it stands when that other
work is finished, not from `6e29afe`.

## Steps

- [x] 0. Commit the pending "Finish in two steps" work on `main`, branch `mac-app`, copy this plan
      into `tasks/todo.md`
- [x] 1. Spikes (a: passed, POST bodies arrive, 2026-11-24. b: passed on 2 groups from a minimal
      environment on the Claude login, 9.2 s; full 20-group batch: 51.7 s, 20 of 20 groups answered
      with every number covered once, 15,736 cache-creation + 992 cache-read input tokens, 7,418
      output tokens, reported cost 0.0069, no tools, 3.81 MB of images on stdin (the tool-based run
      was recorded as ~94k tokens per batch). `--setting-sources ""` is accepted but still loads 4
      plugins (8 without it). The same group got a different keep/remove split in the two runs. c: the ONNX Runtime
      route was dropped: `microsoft/onnxruntime-swift-package-manager` and `microsoft/onnxruntime`
      return 404 on GitHub with no redirect; mirrors on personal accounts were deliberately not used.
      Core ML instead, passed: the Float32 conversion matches ONNX Runtime exactly on the same pixels
      (cosine 1.000000 on 200 crops; Float16 drops to 0.9969 and was rejected). From Swift on all
      2,375 crops of the real library, 10 ms per face: the same 309 "you" photos as `me.json`, none
      gained or lost; similarities differ by up to 0.0097 (mean 0.0018), because ImageIO and PIL
      decode the same JPEG differently (27% of pixels, up to 27 levels), not because of the model.
      The closest photo to the 0.36 threshold sits 0.016 away. Done in a throwaway environment in
      the scratchpad; `.venv` was not changed.)
      Original text: each a throwaway under 100 lines, to settle the three unknowns before building:
      (a) POST bodies reach a `WKURLSchemeHandler` (fallback: `WKScriptMessageHandlerWithReply` for
      `/api` calls); (b) one real batch through `claude -p` with image input and `--json-schema` on
      your login, tokens and time noted; (c) ONNX Runtime in Swift reproduces the Python embeddings
- [x] 2. `PhotoCleanupCore` package, GRDB store with migrations, Analyzer writing to the database;
      a small CLI target (`analyze`, `group`, `serve`) to drive it without the UI
      (2026-11-24: package, store, analyzer, neighbors and `photocleanup-cli analyze` are in `Core/`,
      17 tests pass on generated photos: scan, rescan, changed file, file moved outside the app,
      identical copies moved together, deleted and restored file, unplugged folder, `_to_remove`,
      unreadable file. Compared with the old `analyze` on a scratch copy of 120 real photos (56 HEIC,
      64 JPEG, 170 faces): every field identical (size, times, dimensions, GPS, utility, sharpness,
      aesthetics, face boxes and quality, 768-float feature prints) and the same 818 neighbor pairs
      at the same distances; 5.2 s against 5.0 s. The `group` and `serve` commands come with steps
      3 and 5. Since 2026-11-24 16:30 this work lives in the worktree `../photo-cleanup-mac-app`;
      the original folder is back on `main` for the other session.)
- [x] 3. Grouping port with parity tests against `group.py`
      (2026-11-24: `Core/Sources/PhotoCleanupCore/Grouping`, a pure function from photos, close
      pairs and edits to collections, groups and automatic picks. Compared with `group.py` at
      `6e29afe` on a copy of the real library's analysis files, all 1,547 photos, every field the
      page shows: 0 differences with the real `collection_edits.json` (17 collections, 317
      groups), 0 without edits (42 collections, 316 groups), 0 without face matching (313
      groups). A deliberately mismatched case reports 2,512 differences, so the comparison is not
      vacuous. It runs when `PHOTOCLEANUP_PARITY_DIR` is set; the data stays out of the repository.
      17 unit tests on made-up libraries cover each edit type and the pairs from
      `tasks/lessons.md`. One intended difference: `group.py` linked a close pair only when the
      photo with the smaller id listed the other among its 40 nearest (9,371 of the real pairs are
      known only from the other side); the port lets every close pair link. On the real data that
      changes nothing: same groups, same picks. The move-log reading that the other session is
      changing in `group.py` has no counterpart here, a photo's location is a column.)
- [x] 4. Faces: `scripts/convert_face_model.py` (build time, self-checking), Core ML embedder in
      Swift fed from the aligned crop in memory (no JPEG round trip), same "you" set as `me.json`
      (2026-11-24: `uv run scripts/convert_face_model.py` writes `models/ArcFace.mlmodelc`, 166 MB,
      cosine 0.9999999 against ONNX Runtime, in a throwaway environment. `CoreMLFaceEmbedder` and
      `Me` (reference faces, `me_sim` per photo) are in `Core/Sources/PhotoCleanupCore/Faces`; 21
      tests pass. On the 120 real sample photos with the real reference photo: the same 42 photos
      get a similarity and the same 19 are "you". Similarities differ from `me.json` by up to
      0.0112 (mean 0.0056, 5 photos over 0.01), a little more than the JPEG-decoded spike because
      the crop no longer goes through JPEG at all. Lowest "you" 0.64, highest "not you" 0.18.
      Not yet run on the whole real library; that happens with the import in step 8.)
- [x] 5. Router + FileOps; the page running against Swift through `--serve`
      (File steps added 2026-11-24 17:15, `Catalog/FileSteps.swift`: organize, clean up (all or
      duplicate copies only) and undo of each. Every move is written to `file_move` before the
      file moves and marked done after the database caught up; unfinished ones are settled when
      the library opens. Nothing is overwritten; only folders the app made are removed when empty.
      The other session's `relocate` (catch up with Finder moves, write off what is gone) is done
      here by the scan: a moved file keeps its row, a filed photo in a renamed folder stays filed
      and can still be put back, an emptied `_to_remove` means those photos are missing.
      13 tests on temporary folders, 81 in all. Through the Finish page on the scratch copy of 120
      real photos: 36 filed into `2026-07-05 Day trip/`, 55 to `_to_remove` (17 of them out of
      that folder), undo clean-up, undo organize; afterwards the same 120 files in the same places,
      the app's two folders gone, the original subfolder untouched.)
      Earlier note on the router half:
      (2026-11-24, router half done: `Catalog` keeps your choices, reviewed marks, names, folder
      switches, merges, moves and "not a trip" marks in SQLite and derives collections and groups
      in memory on every change, so there are no derived tables to go stale, a simplification of
      the table sketch above. `Router` answers the page's requests; `photocleanup-cli serve` puts it
      on localhost for development. Checked in the browser with the unchanged `app/` on the
      120-photo sample library: Organize and Review render with thumbnails and "You" badges, no
      console errors; mark reviewed, rename ("Diwali at Mom's") and the folder switch through the
      page; merge (becomes a trip, name and switch follow), a refused merge with its message,
      split and decide through the same requests; a HEIC opens as a 2400 px JPEG preview, a JPEG
      as the file itself; `/../` and unknown ids give 404. 53 tests pass.
      Open: FileOps (organize, clean up, undo). Those requests answer 501 "not part of this build
      yet" and change nothing. They wait for the other session's Python, which is changing exactly
      that code. Folder names already follow its newer rule (your name as it is, else date and kind).)
- [ ] 6. App shell: libraries, add folder, pipeline progress, web view, menus, settings, icon
      (2026-11-24, first half: `project.yml` (XcodeGen) and `MacApp/` (not `App/`: the page is in
      `app/` and the file system does not tell the two apart). Start screen with the library list,
      Add Photo Folder sheet, scan with progress, the page in a `WKWebView` fed by `Router` through
      `photocleanup://`, File menu. Debug builds can save a picture of their own window
      (`MacApp/DebugAutomation.swift`, `scripts/app-shot.sh`), so the UI is checked without
      recording the screen. Checked that way on the 120-photo sample: empty start screen, the
      sheet, add + scan + find you + group, the Organize page, relaunch with the library listed,
      Review page. Not done: settings, icon, scan progress and error states pictured, keyboard
      shortcuts inside the web view tried by hand, a second window size.
      Incident: the test run that showed the sheet did not quit (terminate is refused while a sheet
      is open; fixed with exit). While it sat on screen for about a minute a library for
      `/Volumes/KRUTIK/Pictures/2026` was created in it at 16:47:20, which no command of mine asked
      for, so it was most likely added by hand in that window. I stopped that process without
      knowing, at 86 photos analyzed. The folder was only read. The library is still in the
      scratchpad (`apptest/libs/3678941E-...`) and has not been touched since.)
- [x] 7. Review: native contact sheets, batches, ClaudeRunner, validation, toolbar UI
      (2026-11-24: `Core/Sources/PhotoCleanupCore/Review`. Unit tests use a stand-in `claude`
      script: answers into picks with the safety rules, batching, the message (no paths or file
      names in it), failures explained, cancel stops the command, a failed batch changes nothing,
      a second run has nothing left. Real runs on the 120-photo sample through the Claude login:
      from the command line 15 groups in 53 s (13,227 input and 7,375 output tokens, reported cost
      0.0063, 41 of 63 photos to remove); inside the app 15 groups in 42 s (reported 0.004, 34 of
      63 to remove), page refreshed in place from 66 to 55 photos to move. The two runs differ on
      7 photos with identical input: the model is not deterministic. No `review_batch` table: a
      group needs a second opinion while none of its photos has a pick, which is all resuming needs.
      Settings shows the CLI found, its version and sign-in, model and batches at a time.)
- [ ] 8. Import of the existing library
      (2026-11-24 17:20: `Core/Sources/PhotoCleanupCore/Import/LegacyImport.swift` and
      `photocleanup-cli import-review`, 4 tests. Read-only run on the real folder
      `/Volumes/KRUTIK/TEMP - Archieve/Pictures/2026` into a scratch library, nothing written to
      the drive or to the old output folder:
      - scan: 1,161 images, all analyzed, 0 unreadable, 98.7 s. The old tool had analyzed 1,547.
      - accounting of the 1,547: 1,161 found, 128 written off by the old tool, 0 in `_to_remove`,
        258 not found. It sums. 251 of the found ones were not at the path the old log gives
        (folders renamed or files moved by hand since) and were matched by file name and size.
      - imported: 92 of 172 choice entries, 425 of 888 reviewed marks, 956 of 2,075 picks, 6 of 7
        names, 6 folder switches, 4 merges, 6 moves, 19 not-a-trip marks; 805 photos recognised as
        filed by the old tool. The old files list a filed photo under two ids, so entry counts
        overstate photos; a separate script counted 103 distinct photos with a choice, of which 30
        are among the missing and 2 written off. That script could not map 48 choice ids that the
        importer does map, so the 92 is not independently confirmed.
      - result: 17 collections, 188 groups, 714 to remove; you in 246 of 570 photos with a face.
      OPEN, not resolved: 258 photos that carry review state are no longer under that folder and
      the old log does not say they left. Where they are is unknown. `/Volumes/KRUTIK/Pictures/2026`
      holds 4,545 images including same-name same-size copies of 1,164 old photos; whether the 258
      are there was not established. Not done: the comparison with the old page (it now shows a
      different set of photos), the face check on the matched 1,161 against `me.json`, the menu
      item in the app, and importing into a real library.)
- [ ] 9. `scripts/make-dmg.sh`: Release build (universal), sign, `hdiutil` DMG with an Applications
      link, into `dist/`; `setup.sh` shrinks to fetching the model for the build
      (2026-11-24: `scripts/make-dmg.sh` writes `dist/Photo-Cleanup-0.1.0.dmg`, 160 MB, arm64 and
      x86_64, signed with the Apple Development identity; `scripts/make-icon.swift` draws the icon.
      Checked: mounted, the app and an Applications link are in it, the copied-out app passes
      `codesign --verify --strict`, has the icon, the model and the page, no debug automation, and
      stays running when launched (stopped after 8 s). `spctl` rejects it, as expected for an app
      that is not notarized. Not checked: the release app's window contents (only debug builds
      can picture themselves; the UI code is the same), the Intel half, a second Mac. Not done:
      `setup.sh` still builds the old tools, and the app was not copied to /Applications.)
- [ ] 10. README rewrite; with your OK, remove the Python scripts and `run.sh` (history keeps them)
- [ ] 11. Review section in `tasks/todo.md`; PR with `docs/pr/<num>-mac-app.md`

## Files

- New: `project.yml`, `Core/` (Swift package: `Sources/PhotoCleanupCore/{Store,Analyzer,Faces,Grouping,FileOps,Review,Router}`,
  `Tests/`), `App/` (SwiftUI shell, `WebView.swift`, `SchemeHandler.swift`, `Info.plist`, assets),
  `CLI/`, `scripts/make-dmg.sh`
- Moved into Core and adapted: `analyze.swift`, `sheet.swift`
- Ported, then removed in step 10: `group.py` (collections, `apply_edits`, grouping, picks),
  `server.py` (`Library`, `organize`, `cleanup`, `undo`, `file_photo`, `folder_name`,
  `collection_names`, `edit_collections`), `faces.py`, `prepare_review.py`, `merge_review.py`
- Reused unchanged: `app/index.html`, `app/app.css`, `app/app.js` (photo ids stay opaque strings);
  bundled as resources
- `haiku_prompt.md` edited for tool-free input

## Verification

- **Grouping parity**: golden output from `group.py` on a scratch library and on the real
  library's data (read only), compared field by field with the Swift port: collections, members,
  kinds, group order, automatic state and reason of every photo. Float rounding and tie-breaks are
  the known hazards.
- **Edits**: a test per pair of edit types on the awkward shapes from `tasks/lessons.md` (merged
  collection, a month that absorbed a folded event, filed photos), plus the real
  `collection_edits.json` on a copy.
- **File steps** on temporary folders with generated photos, never the real folder: organize,
  rename + organize, move a photo out + organize, duplicates first, clean up, undo each, Live Photo
  pairs, `/tmp` vs `/private/tmp`, a killed process mid-move, a Finder move followed by a rescan.
- **Faces**: same set of "you" photos as `me.json`; every photo whose old and new similarity fall
  on different sides of 0.36 is listed and looked at. A fixed tolerance on the similarity turned
  out to be the wrong test: 0.001 does not hold across two JPEG decoders and 0.01 does not hold
  without the JPEG round trip (0.0112 seen), while the model itself matches exactly.
- **Claude**: validation rules as unit tests on recorded answers; one real small run end to end;
  cancel and resume; `claude` missing and signed out.
- **Page**: through `--serve` on a scratch copy with the browser tools: the Organize, Review and
  Finish flows already listed in `tasks/todo.md`, at desktop widths only.
- **The app itself**: build the DMG, mount it, drag to Applications, launch. Add a scratch copy of
  real photos, run the pipeline, a second opinion, review, organize, clean up, undo, quit and
  reopen. Checked with screenshots and held to the same pixel standard as the page.
- **Real library**: import, then compare with the old page: photo, collection and to-remove
  counts, number of your choices, names, merges. Look only, no file step.

## Risks

- Vision feature prints jitter between runs, so a re-analysis can shift a few group boundaries.
  Your state is per photo, so nothing you decided is lost; the comparison in the last check shows
  how much moved.
- If the Swift grouping cannot match Python exactly because of float formatting, the differences
  get listed and judged one by one rather than hidden behind a tolerance.
- An app signed for development and not notarized needs one "Open Anyway" on a second Mac.

## Folder names and folders renamed by hand

- Folders are now named after the collection as it is (`Bronx 10 Mile`); unnamed collections keep the
  date in front (`2026-10-16 Trip`) so they never share a folder.
- The user renamed filed folders in Finder (972 tracked moves pointed at paths that no longer existed).
  The server now catches up on its own (`relocate`, on page load and before every Finish step, free
  when nothing is missing): a missing photo is found by file name + size when exactly one file matches
  (Live Photo video too), a photo found nowhere is logged as `gone`. Real library: 844 found in the
  renamed folders, 128 duplicate copies from the emptied `_to_remove` written off. Backups of the log and
  groups from before: `moves.backup-before-relocate.jsonl`, `groups.backup-before-relocate.json`.
  Tested on the scratch library: organize -> rename folders by hand -> page load finds all 44 -> undo
  puts every file back and removes the renamed folders; emptied `_to_remove` -> gone, next load 0.01 s.

## Review (2026-11-24, state at the end of the first working session)

Built on branch `mac-app` in the worktree `../photo-cleanup-mac-app`; `main` was left to the other
session. 85 tests pass (1 more runs only with real data and passed with 0 differences).

Done and checked:
- Core in Swift on SQLite: analyzer (identical to the old one on 120 real photos), faces on Core ML
  (same 19 "you" on the sample), grouping (0 differences from `group.py` on 1,547 real photos),
  catalog, router, file steps with a move journal, second opinion through the Claude CLI, import of
  the old review, library summaries.
- The app: opening check with Claude sign-in help, home overview with space saved and folder cards,
  library window with the review page, second opinion panel, settings, File menu, icon. Pictured in
  light and dark with the debug build: the three opening states, the overview, Organize, Review,
  Finish. Dark was only pictured for the opening screen and the overview; the dark Review picture
  was taken but not looked at.
- File steps through the Finish page on a scratch copy of 120 real photos, then both undos: the
  folder ended exactly as it began.
- `dist/Photo-Cleanup-0.1.0.dmg` (161 MB, both architectures, signed); the release build launches.

Changed from the plan, and why:
- Pake was checked and not used (a web view wrapper with no backend).
- Faces run on Core ML, not ONNX Runtime: its repositories returned 404 and personal mirrors were
  not used. Decided with the user.
- No derived tables and no `review_batch` table: collections and groups are computed in memory, and
  "needs a second opinion" is "has no pick yet".
- `App/` became `MacApp/` (the file system does not tell `App` from `app`).
- The face-similarity tolerance was replaced by "same set of you photos" after it failed twice.
- The importer follows the old move log, because the real library was organized during this work.

Not done:
- The 258 photos with review state that are no longer under the real folder (see step 8).
- Importing the real library into the app, and the comparison with the old page.
- Removing the Python scripts and shrinking `setup.sh` (step 10 needs the user's OK).
- The pull request and `docs/pr/` write-up (step 11).
- Merging `main`: the other session's uncommitted edits touch `README.md`, `app/app.js`,
  `group.py` and `server.py`; `README.md` will conflict with the rewrite here.
- Not tried by hand or pictured: keyboard shortcuts inside the web view, drag and drop of a folder,
  the scan progress ring, the import menu item, removing a library, a window narrower than 1,440 pt,
  the Intel build, a second Mac.

Incidents during the work, both recorded above where they happened:
- A test window stayed open for about a minute and was most likely used to add a real folder; its
  process was stopped mid-scan. That half-scanned library is still in the scratchpad, untouched.
- The page server from an earlier check appeared to answer a later one; it was the browser tab
  keeping old data across a hash-only navigation, found by asking the server directly.
