# Photo cleanup

Finds near-identical shots in a photo folder, picks the best one of each group, marks the rest for
removal, and lets you review every decision in a local web page. Photos are organized into trips,
events and everyday months, and you clean up inside each one.

Nothing is ever deleted. Files only move in the two steps of the Finish page, each with its own undo:
**Organize files** puts the photos of trips and events you switched on into a folder of their own (you
can do this before reviewing), and **Clean up** puts photos you marked "remove" into a `_to_remove`
folder inside your photo folder (duplicate copies can go first, on their own).

## How it works

| Step | Tool | Cost |
| --- | --- | --- |
| Analyze every photo: similarity embedding, face quality, aesthetic score, sharpness, capture time, GPS, thumbnail | `analyze` (Swift, Apple Vision, on-device) | free |
| Group shots of the same people in a similar pose, pick a favorite by score | `group.py` | free |
| Find the photos you are in: aligned face crops (Vision landmarks) + ArcFace embeddings vs. your reference photo | `analyze` + `faces.py` (local model) | free, offline |
| Detect trips (days away from home), events (busy days at home) and everyday months | `group.py` | free, offline |
| Second opinion on each group from Haiku, looking at one numbered contact sheet per group | `prepare_review.py`, Haiku agents, `merge_review.py` | small |
| Review and change anything | `server.py` + `app/` | free |

GPS coordinates and faces never leave the machine.

## Cleanup policy

- Photos with you: never suggested for removal on their own. In a group, the best shot of you is the
  favorite (judged mostly by your face) and one more good, clearly different shot of you is kept.
- Photos without you (aggressive): a group keeps only its single best shot; near-repeats anywhere in
  the same trip or event are grouped; singles are suggested for removal when blurry, a screenshot or
  document, or in the bottom 35% by quality.
- Every automatic decision carries a reason, shown on hover and in the large viewer.

## Setup

```bash
./setup.sh
```

Builds the Swift tools (`analyze`, `sheet`), creates a Python 3.12 environment in `.venv` with
onnxruntime, numpy and Pillow, and downloads InsightFace's ArcFace model to `models/w600k_r50.onnx`
(buffalo_l release, non-commercial license, checksum verified). Needs the Xcode command line tools
and `uv`. Rerunning skips finished steps.

## Run it

```bash
./run.sh "<photo folder>" "<output folder>" "<photo of you>"
```

Analyzes new or changed photos (reruns are incremental), finds the photos you are in, and rebuilds the
groups and collections. The photo of you (or a folder of 2-3 clear, front-facing photos) is remembered,
so later runs can leave it out.

```bash
python3 prepare_review.py "<output folder>"
```

Writes contact sheets and review batches. Each batch is reviewed by a Haiku agent using
`haiku_prompt.md`, then:

```bash
python3 merge_review.py "<output folder>"
```

```bash
python3 server.py "<photo folder>" "<output folder>" 8765
```

Then open http://localhost:8765.

## Using the page

The page follows the three steps of the work, shown as tabs at the top:

- **Organize** is a bento board of every trip, event and month, newest first: a collection's tile grows
  with its photo count (100+ photos get a big tile with a mosaic of its best shots), so the big trips
  and busy months stand out.
  - **Merge**: tick two or more tiles and click **Merge** in the bar at the bottom. When a trip or event
    starts at most two days after the previous one, its tile offers **Merge with ...**. A merged
    collection says "N merged" and has **Split** to undo it. Merge with... in a collection's ... menu
    does the same from the collection page.
  - **Not a trip / Not a day trip / Not an event**: its photos go back to the everyday month they
    belong to; that month's tile (and page) offers **Restore**.
  - **Rename** gives a collection a name. The tile's tools show on hover.
- **Review** opens the next collection with groups left. Each group is a bento of its photos: the
  favorite is the big tile, keepers come next, and photos marked remove have a red frame (shown in their
  original lighting). `D` marks a group reviewed and goes to the next one; reviewed groups fold
  into one short row (**Show** opens them again). After the last group, `N` (or the button at the end
  of the page) goes to the next collection. A slim bar under the tabs keeps the progress in view.
  - **Moving photos**: select photos with the check in their corner (Shift-click for a range, `S` on
    the highlighted photo, or **Select the group** in a group's ... menu), then **Move to...** in the
    bar at the bottom to put them in another trip, event or month. Esc clears the selection.
- **Finish** has two independent steps, each with an in-page confirm and its own Undo:
  - **Organize files**: every photo of a collection with **Make a folder for these photos** switched
    on (with the video half of a Live Photo) goes into `<photo folder>/<date> <name>/`, for example
    `2026-10-16 Seattle`, or `2026-10-16 Trip` when you did not rename it. Do it before or after the
    review; running it again makes the folders match the collections (renamed collections and moved
    photos follow, photos of a collection switched off go back). The switches for all collections are
    on this page too.
  - **Clean up**: **Remove duplicate copies** first moves only the extra copies of exact duplicates
    (`IMG_1 2.JPG` next to `IMG_1.JPG`) and marks those groups reviewed, which takes them off the review
    list; then the rest of the photos marked remove go, from wherever they are (folders included). Undo
    clean-up puts them back where they were, inside their folder if they were filed.

The library views (all photos, photos of you, close calls, blurry, ...) are in the folded **Library**
section at the top of the sidebar.

These only change the page; no file moves until a Finish step. Edits regroup immediately (`group.py` runs on the
server), so near-repeats across merged parts are grouped together. Every edit is stored with the photos
of the collection it was made on and applies to the collection holding most of those photos, so it
survives reruns. A filed photo stays the same photo until the next run, which gives it a new id (ids
come from the path); the server copies your choices, Haiku's picks and reviewed marks to the new ids when
it files them, so a rerun keeps your review.

## Decisions

A photo's state is, in order of priority: your choice in the page, else Haiku's pick, else the
on-device pick. Your choices are saved on every click in `<output folder>/decisions.json` and survive
reruns and regrouping. Ties between identical copies always go to the original file name
(`IMG_1.JPG` over `IMG_1 2.JPG`), so reruns pick the same favorite.

## Output folder

- `analysis.jsonl`, `neighbors.json`, `thumbs/`, `faces/` - analyzer output
- `reference/`, `face_embeddings.npz`, `me.json`, `reference_path.txt` - face matching
- `groups.json` - groups, collections, automatic picks
- `review_batches/`, `review_sheets/`, `review_raw/`, `haiku/` - Haiku review
- `decisions.json` - your choices
- `names.json` - your names for trips and events
- `collection_edits.json` - merges, photos moved between collections, and collections marked as not a trip or event
- `folders.json` - collections whose photos get their own folder when you organize the files
- `reviewed.json` - groups you marked as reviewed
- `moves.jsonl` - log of moved and filed files, used by undo
- `previews/` - full-size JPEGs made on demand for HEIC/RAW

## Tuning

Thresholds are constants at the top of `group.py`: similarity distances, burst and scene time windows,
how far from home counts as a trip, and how many photos make a busy day an event.
