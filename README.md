# Photo cleanup

Finds near-identical shots in a photo folder, picks the best one of each group, marks the rest for
removal, and lets you review every decision in a local web page. Photos are organized into trips,
events and everyday months, and you clean up inside each one.

Nothing is ever deleted, and nothing moves while you review. The final Move step puts photos you
marked "remove" into a `_to_remove` folder inside your photo folder and, for trips and events you
switched on, files the kept photos into a folder of their own. Undo in the page puts everything back.

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

## Fixing trips and events

The collection header in the page has:

- **Merge…**: join a trip, event or month with others (a picker lists them, nearest in time first).
  A merged collection shows "merged from N" and a **Split** button that undoes the merge.
- **Not a trip / Not a day trip / Not an event**: its photos go back to the everyday month they
  belong to; that month shows a note with **Restore**.
- **Make a folder after cleanup**: when you click Move, the kept photos (and the video half of a
  Live Photo) go into `<photo folder>/<date> <name>/`, for example `2026-10-16 Seattle` or
  `2026-10-16 Trip` when you did not rename it.

These only change the page until you click Move. Edits regroup immediately (`group.py` runs on the
server), so near-repeats across merged parts are grouped together. Every edit is stored with the photos
of the collection it was made on and applies to the collection holding most of those photos, so it
survives reruns. Filed photos get new ids on the next run (ids come from the path); the server copies
your choices to the new ids when it files them, so a rerun never suggests removing what you kept.

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
- `collection_edits.json` - merges and collections marked as not a trip or event
- `folders.json` - collections whose kept photos get their own folder when you move
- `reviewed.json` - groups you marked as reviewed
- `moves.jsonl` - log of moved and filed files, used by undo
- `previews/` - full-size JPEGs made on demand for HEIC/RAW

## Tuning

Thresholds are constants at the top of `group.py`: similarity distances, burst and scene time windows,
how far from home counts as a trip, and how many photos make a busy day an event.
