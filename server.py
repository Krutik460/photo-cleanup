"""Local review server for the photo cleanup.

Usage: python3 server.py <photo-folder> <out-folder> [port]

State, all inside <out-folder>:
  groups.json      grouping + automatic picks (from group.py; rebuilt here after collection edits)
  haiku/*.json     second-opinion picks from the Haiku review, {photoId: {"state", "why"}}
  decisions.json   your manual choices, {photoId: "fav" | "keep" | "remove"}; wins over everything
  reviewed.json    ids of photos whose cleanup group you marked as reviewed
  names.json       your names for trips and events, [{"photos": [photoId, ...], "name": "..."}]
  folders.json     collections whose kept photos get their own folder when you move, [[photoId, ...]]
  collection_edits.json  merges and collections that are not really a trip or event (see group.py)
  moves.jsonl      log of every file move (to _to_remove or into a collection folder), used by undo

Collection ids change when regrouping, so a name, folder switch or edit is stored with the photos of
the collection it was made on, and applies to the collection holding most of those photos now.

Effective state of a photo = your decision, else Haiku's, else the automatic one.
Nothing is ever deleted, and nothing moves until you click Move: then photos marked remove go into
<photo-folder>/_to_remove, and kept photos of collections with "make a folder" on go into
<photo-folder>/<date> <name>/. Undo puts everything back.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from collections import Counter
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
APP_DIR = os.path.join(HERE, "app")
GROUP_PY = os.path.join(HERE, "group.py")
BROWSER_SAFE = {".jpg", ".jpeg", ".png", ".gif", ".webp"}
STATES = {"fav", "keep", "remove"}
ID_RE = re.compile(r"^[0-9a-f]{16}$")
TRASH_DIR = "_to_remove"
NAME_MAX = 80
PREVIEW_MAX = 2400
KIND_LABEL = {"trip": "Trip", "daytrip": "Day trip", "event": "Event", "everyday": "Everyday"}
COMPANION_EXTS = {".mov"}  # the video half of a Live Photo moves with its photo

lock = threading.Lock()
preview_locks = {}


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


class Library:
    def __init__(self, root, out):
        self.root = os.path.realpath(root)
        self.out = os.path.realpath(out)
        self.decisions_path = os.path.join(self.out, "decisions.json")
        self.moves_path = os.path.join(self.out, "moves.jsonl")
        self.names_path = os.path.join(self.out, "names.json")
        self.reviewed_path = os.path.join(self.out, "reviewed.json")
        self.folders_path = os.path.join(self.out, "folders.json")
        self.edits_path = os.path.join(self.out, "collection_edits.json")
        os.makedirs(os.path.join(self.out, "previews"), exist_ok=True)

    def groups(self):
        return read_json(os.path.join(self.out, "groups.json"), {"groups": [], "photos": {}, "order": []})

    def haiku(self):
        merged = {}
        d = os.path.join(self.out, "haiku")
        if os.path.isdir(d):
            for name in sorted(os.listdir(d)):
                if name.endswith(".json"):
                    merged.update(read_json(os.path.join(d, name), {}))
        return merged

    def decisions(self):
        return read_json(self.decisions_path, {})

    def names(self):
        names = read_json(self.names_path, [])
        if isinstance(names, dict):  # older format: {firstPhotoId: name}
            names = [{"photos": [pid], "name": n} for pid, n in names.items()]
        return names

    def reviewed(self):
        return read_json(self.reviewed_path, [])

    def folders(self):
        return [f for f in read_json(self.folders_path, []) if isinstance(f, list)]

    def edits(self):
        e = read_json(self.edits_path, {})
        return {"merges": e.get("merges") or [], "moves": e.get("moves") or [],
                "not_collections": e.get("not_collections") or []}

    def locations(self):
        """Photos that are not at their original path: {photoId: {"op", "to", "chain"}}.

        op "move" = in _to_remove, op "file" = in a collection folder. "chain" is every move since the
        last restore (a filed photo can later be moved to _to_remove), so undo knows the original path.
        """
        chains = {}
        if os.path.exists(self.moves_path):
            with open(self.moves_path) as f:
                for line in f:
                    m = json.loads(line)
                    if m["op"] == "restore":
                        chains.pop(m["id"], None)
                    else:
                        chains.setdefault(m["id"], []).append(m)
        return {pid: {"op": ch[-1]["op"], "to": ch[-1]["to"], "chain": ch}
                for pid, ch in chains.items() if os.path.exists(ch[-1]["to"])}

    def regroup(self):
        r = subprocess.run([sys.executable, GROUP_PY, self.out], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError("group.py failed: " + (r.stderr.strip().splitlines() or ["?"])[-1])

    def carry_over(self, filed, eff):
        """Filed photos get new ids on the next ./analyze run, because ids come from the path.

        Copy everything about them to the new ids (what you kept, reviewed marks, names, folder
        switches, collection edits), so a rerun never suggests removing a photo you kept and filed.
        The old entries stay: the page uses them until the rerun, and again after an undo.
        """
        new_id = {old: photo_id(os.path.relpath(dst, self.root)) for old, dst in filed}
        decisions = self.decisions()
        for old, new in new_id.items():
            decisions[new] = eff[old]
        write_json(self.decisions_path, decisions)
        reviewed = set(self.reviewed())
        write_json(self.reviewed_path, sorted(reviewed | {new_id[o] for o in reviewed & new_id.keys()}))
        add = lambda ids: ids + [new_id[o] for o in ids if o in new_id]
        write_json(self.names_path, [{**e, "photos": add(e["photos"])} for e in self.names()])
        write_json(self.folders_path, [add(f) for f in self.folders()])
        edits = self.edits()
        edits["merges"] = [[add(part) for part in m] for m in edits["merges"]]
        edits["moves"] = [{"photos": add(m["photos"]), "into": add(m["into"])} for m in edits["moves"]]
        for e in edits["not_collections"]:
            e["photos"] = add(e["photos"])
            e["names"] = [{**n, "photos": add(n["photos"])} for n in e.get("names", [])]
            e["folders"] = [add(f) for f in e.get("folders", [])]
        write_json(self.edits_path, edits)

    def effective(self, data, haiku, decisions):
        out = {}
        for pid, p in data["photos"].items():
            out[pid] = decisions.get(pid) or (haiku.get(pid) or {}).get("state") or p["auto"]
        return out

    def log_move(self, entry):
        with open(self.moves_path, "a") as f:
            f.write(json.dumps(entry) + "\n")


def photo_id(rel):
    """Same id ./analyze gives a photo: the first 8 bytes of SHA-1 of its path inside the photo folder."""
    return hashlib.sha1(rel.encode()).hexdigest()[:16]


def owners(data):
    return {pid: c["id"] for c in data.get("collections", []) for pid in c["members"]}


def home_of(listed, owner):
    """The collection holding most of the listed photos now (same rule as group.py), or None."""
    where = Counter(owner[pid] for pid in listed if pid in owner)
    return where.most_common(1)[0][0] if where else None


def collection_names(data, names):
    """{collectionId: name}. A name applies to the collection holding most of its photos; when a merge
    brings several names together, the earliest part's name wins."""
    owner, best = owners(data), {}
    for e in names:
        home = home_of(e["photos"], owner)
        if home is None:
            continue
        first = min(data["photos"][pid]["time"] for pid in e["photos"] if owner.get(pid) == home)
        if home not in best or first < best[home][0]:
            best[home] = (first, e["name"])
    return {cid: name for cid, (_, name) in best.items()}


def folder_collections(data, folders):
    owner = owners(data)
    return {home_of(f, owner) for f in folders} - {None}


def folder_name(c, name):
    """Folder for a collection's kept photos: "2026-10-16 Seattle", or "2026-10-16 Trip" when unnamed."""
    # EXIF capture times are wall-clock values stored as if UTC; file times are real instants.
    start = datetime.fromtimestamp(c["start"], timezone.utc if c["timeKnown"] else None)
    date = start.strftime("%Y-%m" if c["kind"] == "everyday" else "%Y-%m-%d")
    label = name or KIND_LABEL.get(c["kind"], "Photos")
    name = label if label.startswith(date) else f"{date} {label}"
    name = "".join("-" if ch in '/:\\' else ch for ch in name if ch.isprintable())
    return " ".join(name.split()).strip(" .")[:100] or date


def unique_target(path):
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    i = 2
    while os.path.exists(f"{base} ({i}){ext}"):
        i += 1
    return f"{base} ({i}){ext}"


class Handler(SimpleHTTPRequestHandler):
    lib: Library = None

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=APP_DIR, **kwargs)

    def log_message(self, fmt, *args):
        if "/api/" in (self.path or ""):
            sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    def send_json(self, obj, status=HTTPStatus.OK):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path, ctype="image/jpeg", cache=True):
        try:
            size = os.path.getsize(path)
            f = open(path, "rb")
        except OSError:
            return self.send_error(HTTPStatus.NOT_FOUND)
        with f:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "max-age=86400" if cache else "no-store")
            self.end_headers()
            shutil.copyfileobj(f, self.wfile)

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def photo_or_404(self, pid):
        if not ID_RE.match(pid):
            self.send_error(HTTPStatus.NOT_FOUND)
            return None
        p = self.lib.groups()["photos"].get(pid)
        if not p:
            self.send_error(HTTPStatus.NOT_FOUND)
        return p

    def collection_of(self, data, pid):
        return next((c for c in data.get("collections", []) if pid in c["members"]), None)

    def edit_collections(self, op, ids, into=None):
        """Merge, split, move photos, mark as not a trip/event, or restore; then regroup. Returns a
        photo id of the resulting collection, so the page can open it."""
        lib = self.lib
        data = lib.groups()
        owner = owners(data)
        targets = []
        for pid in ids:
            c = self.collection_of(data, pid)
            if c and c not in targets:
                targets.append(c)
        targets.sort(key=lambda c: c["start"])
        edits = lib.edits()
        merged_into = lambda m, c: any(home_of(part, owner) == c["id"] for part in m)
        if op == "merge":
            if len(targets) < 2:
                raise ValueError("pick at least two collections to merge")
            parts, keep = [], []
            for m in edits["merges"]:  # merging an already merged collection keeps its original parts
                (parts if any(merged_into(m, c) for c in targets) else keep).append(m)
            parts = [part for m in parts for part in m]
            covered = {home_of(part, owner) for part in parts}
            parts += [c["members"] for c in targets if c["id"] not in covered]
            edits["merges"] = keep + [parts]
        elif op == "move":
            dest = self.collection_of(data, into)
            moving = [pid for pid in ids if pid in data["photos"] and dest and pid not in dest["members"]]
            if not moving:
                raise ValueError("nothing to move")
            # A newer move of a photo replaces its older one.
            newer = set(moving)
            older = [{**m, "photos": [pid for pid in m["photos"] if pid not in newer]} for m in edits["moves"]]
            edits["moves"] = [m for m in older if m["photos"]] + [{"photos": moving, "into": dest["members"]}]
            targets = [dest]
        elif op == "split":
            if not targets:
                raise ValueError("unknown collection")
            edits["merges"] = [m for m in edits["merges"] if not merged_into(m, targets[0])]
        elif op == "dissolve":
            if not targets or targets[0]["kind"] == "everyday":
                raise ValueError("only a trip, day trip or event can be marked as not one")
            c = targets[0]
            # Its name and folder switch go with the mark, so they come back on restore and do not
            # show up on the everyday month it joins.
            names, folders = lib.names(), lib.folders()
            here = lambda listed: home_of(listed, owner) == c["id"]
            edits["not_collections"].append({"photos": c["members"], "names": [e for e in names if here(e["photos"])],
                                             "folders": [f for f in folders if here(f)]})
            write_json(lib.names_path, [e for e in names if not here(e["photos"])])
            write_json(lib.folders_path, [f for f in folders if not here(f)])
        elif op == "restore":
            wanted = set(ids)
            restored = [e for e in edits["not_collections"] if not wanted.isdisjoint(e["photos"])]
            if not restored:
                raise ValueError("nothing to restore")
            edits["not_collections"] = [e for e in edits["not_collections"] if e not in restored]
            write_json(lib.names_path, lib.names() + [n for e in restored for n in e.get("names", [])])
            write_json(lib.folders_path, lib.folders() + [f for e in restored for f in e.get("folders", [])])
        else:
            raise ValueError("unknown operation")
        write_json(lib.edits_path, edits)
        lib.regroup()
        return targets[0]["members"][0] if op != "restore" else next(iter(wanted))

    def file_photo(self, pid, src, folder):
        """Move a kept photo into its collection folder, with its Live Photo video if it has one."""
        os.makedirs(folder, exist_ok=True)
        dst = unique_target(os.path.join(folder, os.path.basename(src)))
        stem = os.path.splitext(os.path.basename(src))[0]
        companions = []
        for name in os.listdir(os.path.dirname(src)):
            base, ext = os.path.splitext(name)
            if base == stem and ext.lower() in COMPANION_EXTS and not name.startswith("._"):
                to = unique_target(os.path.join(folder, os.path.splitext(os.path.basename(dst))[0] + ext))
                companions.append({"from": os.path.join(os.path.dirname(src), name), "to": to})
        shutil.move(src, dst)
        for comp in companions:
            shutil.move(comp["from"], comp["to"])
        self.lib.log_move({"op": "file", "id": pid, "from": src, "to": dst, "companions": companions, "at": time.time()})
        return dst

    def do_GET(self):
        path = urlparse(self.path).path
        lib = self.lib
        if path == "/api/data":
            data = lib.groups()
            names, on = collection_names(data, lib.names()), folder_collections(data, lib.folders())
            for c in data.get("collections", []):
                c["name"] = names.get(c["id"], "")
                c["folder"] = folder_name(c, c["name"])
                c["folderOn"] = c["id"] in on
            locations = lib.locations()
            data["haiku"] = lib.haiku()
            data["decisions"] = lib.decisions()
            data["reviewed"] = lib.reviewed()
            data["moved"] = sorted(pid for pid, loc in locations.items() if loc["op"] == "move")
            data["filed"] = {pid: os.path.relpath(loc["to"], lib.root) for pid, loc in locations.items() if loc["op"] == "file"}
            data["root"] = lib.root
            return self.send_json(data)
        if path.startswith("/thumb/"):
            pid = path[len("/thumb/"):]
            if not ID_RE.match(pid):
                return self.send_error(HTTPStatus.NOT_FOUND)
            return self.send_file(os.path.join(lib.out, "thumbs", pid + ".jpg"))
        if path.startswith("/full/"):
            pid = path[len("/full/"):]
            p = self.photo_or_404(pid)
            if not p:
                return
            loc = lib.locations().get(pid)
            src = loc["to"] if loc else p["path"]
            ext = os.path.splitext(src)[1].lower()
            if ext in BROWSER_SAFE:
                ctype = {".png": "image/png", ".gif": "image/gif", ".webp": "image/webp"}.get(ext, "image/jpeg")
                return self.send_file(src, ctype)
            preview = os.path.join(lib.out, "previews", pid + ".jpg")
            with lock:
                plock = preview_locks.setdefault(pid, threading.Lock())
            with plock:
                if not os.path.exists(preview):
                    tmp = preview + ".tmp.jpg"
                    cmd = ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "85"]
                    if max(p["w"], p["h"]) > PREVIEW_MAX:
                        cmd += ["-Z", str(PREVIEW_MAX)]  # -Z also upscales, so only pass it to shrink
                    r = subprocess.run(cmd + [src, "--out", tmp], capture_output=True)
                    if r.returncode != 0 or not os.path.exists(tmp):
                        return self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR, "preview failed")
                    os.replace(tmp, preview)
            return self.send_file(preview)
        if path == "/":
            self.path = "/index.html"
        self.app_file = True
        return super().do_GET()

    def end_headers(self):
        # App files carry only Last-Modified, so browsers would guess a cache lifetime and keep
        # running an old app.js after an update. no-cache makes them revalidate (a cheap 304).
        if getattr(self, "app_file", False):
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        lib = self.lib
        if path == "/api/decide":
            body = self.read_body()
            changes = body.get("changes") or {}
            with lock:
                photos = lib.groups()["photos"]
                decisions = lib.decisions()
                for pid, state in changes.items():
                    if pid not in photos:
                        continue
                    if state is None:
                        decisions.pop(pid, None)
                    elif state in STATES:
                        decisions[pid] = state
                write_json(lib.decisions_path, decisions)
            return self.send_json({"decisions": decisions})

        if path == "/api/name":
            body = self.read_body()
            name = " ".join(str(body.get("name") or "").split())[:NAME_MAX]
            with lock:
                data = lib.groups()
                c = self.collection_of(data, body.get("id"))
                if not c:
                    return self.send_error(HTTPStatus.BAD_REQUEST, "unknown collection")
                owner = owners(data)
                names = [e for e in lib.names() if home_of(e["photos"], owner) != c["id"]]
                if name:
                    names.append({"photos": c["members"], "name": name})
                write_json(lib.names_path, names)
            return self.send_json({"ok": True})

        if path == "/api/folder":
            body = self.read_body()
            with lock:
                data = lib.groups()
                c = self.collection_of(data, body.get("id"))
                if not c:
                    return self.send_error(HTTPStatus.BAD_REQUEST, "unknown collection")
                owner = owners(data)
                folders = [f for f in lib.folders() if home_of(f, owner) != c["id"]]
                if body.get("on"):
                    folders.append(c["members"])
                write_json(lib.folders_path, folders)
            return self.send_json({"ok": True})

        if path == "/api/collections":
            body = self.read_body()
            with lock:
                try:
                    anchor = self.edit_collections(body.get("op"), body.get("ids") or [], body.get("into"))
                except ValueError as e:
                    return self.send_error(HTTPStatus.BAD_REQUEST, str(e))
                except RuntimeError as e:
                    return self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR, str(e))
            return self.send_json({"anchor": anchor})

        if path == "/api/reviewed":
            body = self.read_body()
            on = bool(body.get("reviewed"))
            with lock:
                photos = lib.groups()["photos"]
                reviewed = set(lib.reviewed())
                for pid in body.get("ids") or []:
                    if pid not in photos:
                        continue
                    if on:
                        reviewed.add(pid)
                    else:
                        reviewed.discard(pid)
                reviewed = sorted(reviewed)
                write_json(lib.reviewed_path, reviewed)
            return self.send_json({"reviewed": reviewed})

        if path == "/api/apply":
            with lock:
                data = lib.groups()
                eff = lib.effective(data, lib.haiku(), lib.decisions())
                locations = lib.locations()
                moved, filed, errors = 0, [], []

                # 1. Photos marked remove go to _to_remove (from wherever they are now).
                for pid, state in eff.items():
                    loc = locations.get(pid)
                    if state != "remove" or (loc and loc["op"] == "move"):
                        continue
                    p = data["photos"][pid]
                    src = loc["to"] if loc else p["path"]
                    if not os.path.exists(src):
                        continue
                    dst = unique_target(os.path.join(lib.root, TRASH_DIR, p["rel"]))
                    try:
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        shutil.move(src, dst)
                        lib.log_move({"op": "move", "id": pid, "from": src, "to": dst, "at": time.time()})
                        moved += 1
                    except OSError as e:
                        errors.append(f"{p['rel']}: {e}")

                # 2. Kept photos of collections with "make a folder" on go to <date> <name>/.
                on, names = folder_collections(data, lib.folders()), collection_names(data, lib.names())
                used = set()
                for c in data.get("collections", []):
                    if c["id"] not in on:
                        continue
                    folder = os.path.join(lib.root, folder_name(c, names.get(c["id"])))
                    for pid in c["members"]:
                        p = data["photos"][pid]
                        src = p["path"]
                        if eff[pid] == "remove" or pid in locations or not os.path.exists(src) \
                                or os.path.dirname(src) == folder:
                            continue
                        try:
                            filed.append((pid, self.file_photo(pid, src, folder)))
                            used.add(folder)
                        except OSError as e:
                            errors.append(f"{p['rel']}: {e}")
                if filed:
                    lib.carry_over(filed, eff)
            return self.send_json({"moved": moved, "filed": len(filed), "folders": len(used), "errors": errors,
                                   "folder": os.path.join(lib.root, TRASH_DIR)})

        if path == "/api/undo":
            with lock:
                restored, errors, emptied = 0, [], {os.path.join(lib.root, TRASH_DIR)}
                for pid, loc in lib.locations().items():
                    original = loc["chain"][0]["from"]
                    try:
                        if os.path.exists(original):
                            raise OSError("a file already exists at the original location")
                        os.makedirs(os.path.dirname(original), exist_ok=True)
                        shutil.move(loc["to"], original)
                        for m in loc["chain"]:
                            emptied.add(os.path.dirname(m["to"]))
                            for comp in m.get("companions", []):
                                if os.path.exists(comp["to"]) and not os.path.exists(comp["from"]):
                                    shutil.move(comp["to"], comp["from"])
                        lib.log_move({"op": "restore", "id": pid, "from": loc["to"], "to": original, "at": time.time()})
                        restored += 1
                    except OSError as e:
                        errors.append(f"{loc['to']}: {e}")
                # Remove the folders the move created once they are empty again (rmdir refuses otherwise).
                for top in emptied:
                    if not os.path.isdir(top) or os.path.realpath(top) == lib.root:
                        continue
                    for d, _, _ in sorted(os.walk(top), key=lambda w: -len(w[0])):
                        try:
                            os.rmdir(d)
                        except OSError:
                            pass
            return self.send_json({"restored": restored, "errors": errors})

        self.send_error(HTTPStatus.NOT_FOUND)


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    Handler.lib = Library(sys.argv[1], sys.argv[2])
    port = int(sys.argv[3]) if len(sys.argv) == 4 else 8765
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Photo review: http://localhost:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
