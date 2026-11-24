"""Local review server for the photo cleanup.

Usage: python3 server.py <photo-folder> <out-folder> [port]

State, all inside <out-folder>:
  groups.json      grouping + automatic picks (from group.py, read-only here)
  haiku/*.json     second-opinion picks from the Haiku review, {photoId: {"state", "why"}}
  decisions.json   your manual choices, {photoId: "fav" | "keep" | "remove"}; wins over everything
  moves.jsonl      log of files moved to <photo-folder>/_to_remove (used by undo)
  names.json       your names for trips and events, {firstPhotoId: "name"}; keyed by the
                   collection's first photo because collection ids change when regrouping
  reviewed.json    ids of photos whose cleanup group you marked as reviewed

Effective state of a photo = your decision, else Haiku's, else the automatic one.
Nothing is ever deleted: "apply" only moves photos marked remove into <photo-folder>/_to_remove.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

APP_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "app")
BROWSER_SAFE = {".jpg", ".jpeg", ".png", ".gif", ".webp"}
STATES = {"fav", "keep", "remove"}
ID_RE = re.compile(r"^[0-9a-f]{16}$")
TRASH_DIR = "_to_remove"
NAME_MAX = 80
PREVIEW_MAX = 2400

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
        return read_json(self.names_path, {})

    def reviewed(self):
        return read_json(self.reviewed_path, [])

    def moved(self):
        """Photo ids currently sitting in _to_remove (moved and not undone)."""
        state = {}
        if os.path.exists(self.moves_path):
            with open(self.moves_path) as f:
                for line in f:
                    m = json.loads(line)
                    state[m["id"]] = m
        return {pid: m for pid, m in state.items() if m["op"] == "move" and os.path.exists(m["to"])}

    def effective(self, data, haiku, decisions):
        out = {}
        for pid, p in data["photos"].items():
            out[pid] = decisions.get(pid) or (haiku.get(pid) or {}).get("state") or p["auto"]
        return out

    def log_move(self, entry):
        with open(self.moves_path, "a") as f:
            f.write(json.dumps(entry) + "\n")


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

    def do_GET(self):
        path = urlparse(self.path).path
        lib = self.lib
        if path == "/api/data":
            data = lib.groups()
            data["haiku"] = lib.haiku()
            data["decisions"] = lib.decisions()
            data["names"] = lib.names()
            data["reviewed"] = lib.reviewed()
            data["moved"] = sorted(lib.moved())
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
            src = p["path"]
            moved = lib.moved().get(pid)
            if moved:
                src = moved["to"]
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
        return super().do_GET()

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
            pid = body.get("id")
            name = " ".join(str(body.get("name") or "").split())[:NAME_MAX]
            with lock:
                if pid not in lib.groups()["photos"]:
                    return self.send_error(HTTPStatus.BAD_REQUEST, "unknown photo id")
                names = lib.names()
                if name:
                    names[pid] = name
                else:
                    names.pop(pid, None)
                write_json(lib.names_path, names)
            return self.send_json({"names": names})

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
                already = lib.moved()
                moved, errors = 0, []
                for pid, state in eff.items():
                    if state != "remove" or pid in already:
                        continue
                    p = data["photos"][pid]
                    src = p["path"]
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
            return self.send_json({"moved": moved, "errors": errors, "folder": os.path.join(lib.root, TRASH_DIR)})

        if path == "/api/undo":
            with lock:
                restored, errors = 0, []
                for pid, m in lib.moved().items():
                    try:
                        if os.path.exists(m["from"]):
                            raise OSError("a file already exists at the original location")
                        os.makedirs(os.path.dirname(m["from"]), exist_ok=True)
                        shutil.move(m["to"], m["from"])
                        lib.log_move({"op": "restore", "id": pid, "from": m["to"], "to": m["from"], "at": time.time()})
                        restored += 1
                    except OSError as e:
                        errors.append(f"{m['to']}: {e}")
                trash = os.path.join(lib.root, TRASH_DIR)
                for d, _, _ in sorted(os.walk(trash), key=lambda w: -len(w[0])):
                    try:
                        os.rmdir(d)  # only succeeds for empty folders
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
