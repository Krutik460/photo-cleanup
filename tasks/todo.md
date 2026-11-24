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
