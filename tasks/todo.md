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
