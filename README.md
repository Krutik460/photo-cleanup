# Photo Cleanup

A Mac app that finds near-identical shots in a photo folder, picks the best one of each group, marks
the rest for removal, and lets you review every decision. Photos are organized into trips, events and
everyday months, and you clean up inside each one.

Nothing is ever deleted. Files only move in the two steps of the Finish page, each with its own undo:
**Organize files** puts the photos of trips and events you switched on into a folder of their own, and
**Clean up** puts photos you marked "remove" into a `_to_remove` folder inside your photo folder.

## Install

```bash
./setup.sh
```

```bash
scripts/make-dmg.sh
```

`setup.sh` downloads the face model to `models/` (it also sets up the earlier scripts, see the end);
`make-dmg.sh` converts the model to Core ML on its first run and builds
`dist/Photo-Cleanup-<version>.dmg` (Apple silicon and Intel). Open the DMG and drag Photo Cleanup to Applications. The app is signed
with the Apple Development identity on the Mac that built it and is not notarized: on another Mac the
first launch needs System Settings > Privacy & Security > Open Anyway.

Needs macOS 15 or later. Building needs Xcode, `xcodegen` and `uv`.

## Using the app

- **Opening check.** The app checks what it needs: analysis on this Mac, face recognition, and the
  Claude CLI for second opinions. When Claude is not installed or not signed in it shows the Terminal
  commands (`claude auth login`), which you run yourself. Everything except the second opinion works
  without it.
- **Home.** The space your clean-ups have saved, what is waiting to be cleaned up, and every photo
  folder as a card. Click one to open it, or drop a folder on the window to add it. Removing a folder
  (the button on its card) sends only the app's data about it to the Trash; the photos stay.
- **Adding a folder.** Pick the folder and, optionally, one to three clear photos of you. The first
  scan analyzes every photo on this Mac; later scans (the Scan button, or File > Scan for New Photos)
  only look at what is new, changed or moved.
- **Collections.** Photos are sorted into trips, day trips, events and everyday months. A folder
  directly inside your photo folder is a collection as it is, named after the folder; its photos stay
  out of the detection and stay where they are.
- **Organize.** Every collection as a cover. Select several to merge them, rename one in place, mark a
  trip that is not one, or give a collection a folder of its own.
- **Review.** Each group of similar shots with its best one large, and why. `F` favorite, `K` keep,
  `X` remove, `U` back to the suggestion, `D` reviewed and on to the next group, `S` select (to move
  photos to another collection), Return for the large viewer, `?` for all keys. A photo marked remove
  keeps its real look and gets a red frame.
- **Finish.** Two steps that move files, each asked first and each with its own undo: organize the
  files into collection folders, and clean up (the photos marked remove go to `_to_remove`). Nothing
  is deleted.
- **Second opinion.** The sparkles button asks Claude which shots of each group to keep. It runs your
  installed `claude` command with your Claude sign-in; no API key is stored. Small contact sheets of
  the photos are sent to Anthropic; file names, locations and face data stay on the Mac. Your own
  choices always win over its picks.
- **Light and dark.** The app follows the system appearance.

## How it works

| Step | Where | Runs |
| --- | --- | --- |
| Analyze every photo: similarity embedding, face quality, aesthetic score, sharpness, capture time, GPS, thumbnail | `Core/.../Analyzer` (Apple Vision) | on device |
| Find the photos you are in: aligned face crops, ArcFace embeddings against your reference photo | `Core/.../Faces` (Core ML) | on device |
| Detect trips, events and everyday months; group similar shots; pick a favorite with a reason | `Core/.../Grouping` | on device |
| Second opinion on each group, from one numbered contact sheet per group | `Core/.../Review` + the Claude CLI | Anthropic, through your CLI |
| Your choices, names, merges and moves; organize, clean up, undo | `Core/.../Catalog` | on device |

### Cleanup policy

- Photos with you: never suggested for removal on their own. In a group, the best shot of you is the
  favorite and one more good, clearly different shot of you is kept.
- Photos without you: a group keeps only its single best shot; near-repeats anywhere in the same trip
  or event are grouped; singles are suggested for removal when blurry, a screenshot or document, or in
  the bottom 35% by quality.
- A photo's state is, in order: your choice, else Claude's pick, else the on-device pick.

### Where things are kept

Each photo folder has a library in `~/Library/Application Support/Photo Cleanup/Libraries/<id>/`:
`library.sqlite` (everything known and decided about the photos) plus thumbnails and previews, which
can always be rebuilt. A photo is a row in that database, not a path: moving or renaming a file, in
the app or in Finder, keeps everything decided about it. Every file the app moves is written to the
`file_move` table before it moves, so a crash mid-step cannot lose track of a file.

## Development

```
Core/            Swift package PhotoCleanupCore with all logic, and photocleanup-cli
MacApp/          the Mac app: one window with a web view, menus, pickers, drag and drop, Settings
ui/              the whole interface (HTML, CSS, JS, no build step), served through photocleanup://
app/             the review page of the earlier scripts (server.py); the app does not use it
scripts/         make-dmg.sh, make-icon.swift, convert_face_model.py, app-shot.sh
project.yml      XcodeGen project (the .xcodeproj is generated, not committed)
```

```bash
swift test --package-path Core
```

```bash
xcodegen generate && xcodebuild -project PhotoCleanup.xcodeproj -scheme PhotoCleanup -derivedDataPath build/DerivedData build
```

The interface is one page. What it shows above a single folder (the folders, scanning, Claude, the
second opinion) comes from `Workspace` in the core and is answered by `AppRouter` under `/app/*`;
everything about the open folder is answered by its `Router` under `/api/*`. The Mac app feeds both
from a custom URL scheme and adds what only a Mac app can do (pickers, Finder, Settings, moving the
window from the page's own toolbar).

`Core/.build/debug/photocleanup-cli` drives the core without the app: `analyze`, `second-opinion`,
`import-review`, `summary`, `clean-up`, `undo-clean-up`, and `serve`:

```bash
Core/.build/debug/photocleanup-cli serve <libraries-dir> ui 8770 --model models/ArcFace.mlmodelc
```

puts the whole interface on localhost for work in a browser (no pickers there: a folder is added with
`appAction('add', {path: '...'})` in the console). `scripts/app-shot.sh` launches the debug build and
saves a picture of its own window, for checking the UI without recording the screen; the variables it
takes are listed in `MacApp/DebugAutomation.swift`, and `PHOTOCLEANUP_UI=ui` reads the interface from
the source folder, so a change needs no rebuild. Those pictures do not show the blur behind glass.

`PHOTOCLEANUP_PARITY_DIR=<folder> swift test --package-path Core --filter GroupingParityTests`
compares the Swift grouping with `group.py` on a folder holding that script's input and output.

## The earlier scripts

The repository still holds the scripts the app replaces (`run.sh`, `analyze.swift`, `group.py`,
`faces.py`, `prepare_review.py`, `merge_review.py`, `server.py`). They keep their state as JSON files
in an output folder. File > Import Review from the Old Scripts brings such a folder's choices,
reviewed marks, picks, names and collection edits into the open library, matching photos by where
they are now.
