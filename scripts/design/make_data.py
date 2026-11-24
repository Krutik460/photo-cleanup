"""Builds the data the design mockups share: dist/design/data.js (window.DATA, thumbnails inlined)
and dist/design/data.sample.json (the same shape without image bytes, for reading).

    python3 scripts/design/make_data.py <library-dir>

Uses photocleanup-cli page-data for the library as the review page sees it. dist/ is not committed:
the output contains the library's own photos.
"""
import base64, datetime, json, os, subprocess, sys, tempfile

here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
library = sys.argv[1]
out = os.path.join(here, "dist", "design")
os.makedirs(out, exist_ok=True)
cli = os.path.join(here, "Core", ".build", "release", "photocleanup-cli")
d = json.loads(subprocess.run([cli, "page-data", library], check=True, capture_output=True).stdout)

KIND = {"trip": "Trip", "daytrip": "Day trip", "event": "Event", "everyday": "Everyday"}


def when(t, known):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc if known else None)


# Made-up names for three collections, so the mockups show what a named trip or event looks like.
MOCK_NAMES = {"2026-10-16": "Diwali", "2026-07-05": "North Cascades", "2026-06-06": "Family weekend"}


def title(c):
    a, b = when(c["start"], c["timeKnown"]), when(c["end"], c["timeKnown"])
    if c["name"] or f"{a:%Y-%m-%d}" in MOCK_NAMES and c["kind"] != "everyday":
        return c["name"] or MOCK_NAMES[f"{a:%Y-%m-%d}"]
    if c["kind"] == "everyday":
        return f"Everyday · {a:%B}"
    if a.date() == b.date():
        return f"{KIND[c['kind']]} · {a:%a, %b} {a.day}"
    return f"{KIND[c['kind']]} · {a:%b} {a.day} - {b:%b} {b.day}"


def dates(c):
    a, b = when(c["start"], c["timeKnown"]), when(c["end"], c["timeKnown"])
    return f"{a:%b} {a.day}, {a.year}" if a.date() == b.date() else f"{a:%b} {a.day} - {b:%b} {b.day}, {b.year}"


state = {pid: d["decisions"].get(pid) or (d["haiku"].get(pid) or {}).get("state") or p["auto"] for pid, p in d["photos"].items()}
photos = {}
with tempfile.TemporaryDirectory() as tmp:
    for pid, p in d["photos"].items():
        small = os.path.join(tmp, pid + ".jpg")
        subprocess.run(["sips", "-Z", "400", "-s", "formatOptions", "68", os.path.join(library, "thumbs", pid + ".jpg"), "--out", small],
                       check=True, capture_output=True)
        photos[pid] = {
            "id": pid, "w": p["w"], "h": p["h"], "time": p["time"], "sizeBytes": p["size"],
            "state": state[pid],  # "fav" | "keep" | "remove": your choice, else Claude's pick, else the automatic one
            "reason": (d["haiku"].get(pid) or {}).get("why") or p["reason"],
            "you": p["me"], "faces": p["faces"], "group": p["group"], "collection": p["collection"],
            "src": "data:image/jpeg;base64," + base64.b64encode(open(small, "rb").read()).decode(),
        }

groups = [{"id": g["id"], "collection": g["collection"], "members": g["members"], "kind": g["kind"], "closeCall": g["close"], "you": g["you"],
           "reviewed": set(g["members"]) <= set(d["reviewed"])} for g in d["groups"]]
by_collection = {}
for g in groups:
    by_collection.setdefault(g["collection"], []).append(g["id"])
collections = []
for c in sorted(d["collections"], key=lambda c: -c["start"]):
    members = c["members"]
    keepers = sorted((m for m in members if state[m] != "remove"), key=lambda m: -d["photos"][m]["score"])
    removing = [m for m in members if state[m] == "remove"]
    collections.append({
        "id": c["id"], "kind": c["kind"], "kindLabel": KIND[c["kind"]], "title": title(c), "dates": dates(c), "days": c["days"],
        "kmFromHome": c["homeKm"], "photos": members, "covers": (keepers or members)[:5], "groups": by_collection.get(c["id"], []),
        "toRemove": len(removing), "toRemoveBytes": sum(d["photos"][m]["size"] for m in removing), "folderOn": c["folderOn"],
    })

data = {
    "app": {"name": "Photo Cleanup", "tagline": "Keep the best shot. Let the rest go."},
    "claude": {"ready": True, "version": "2.1.330"},
    "totals": {"savedBytes": 1_290_000_000, "waitingBytes": 430_000_000, "toRemove": sum(c["toRemove"] for c in collections),
               "toRemoveBytes": sum(c["toRemoveBytes"] for c in collections), "photos": len(photos),
               "groups": len(groups), "groupsReviewed": sum(g["reviewed"] for g in groups)},
    # The home screen lists every photo folder; only the first is real, the others reuse its photos.
    "folders": [
        {"id": "f1", "name": "2026", "path": "/Volumes/Photos/Pictures/2026", "photos": len(photos), "groups": len(groups),
         "groupsReviewed": sum(g["reviewed"] for g in groups), "toRemove": sum(c["toRemove"] for c in collections),
         "savedBytes": 0, "connected": True, "covers": collections[4]["covers"][:1] + collections[0]["covers"][:1] + collections[5]["covers"][:2], "lastOpened": "Today"},
        {"id": "f2", "name": "2025", "path": "/Volumes/Photos/Pictures/2025", "photos": 2314, "groups": 402, "groupsReviewed": 402,
         "toRemove": 0, "savedBytes": 1_290_000_000, "connected": True, "covers": collections[5]["covers"][:1] + collections[8]["covers"][:1] + collections[9]["covers"][:2], "lastOpened": "Last week"},
        {"id": "f3", "name": "Phone import", "path": "~/Pictures/Phone import", "photos": 861, "groups": 147, "groupsReviewed": 38,
         "toRemove": 291, "savedBytes": 0, "connected": False, "covers": collections[1]["covers"][:1] + collections[6]["covers"][:1] + collections[2]["covers"][:2], "lastOpened": "3 weeks ago"},
    ],
    "collections": collections, "groups": groups, "photos": photos,
}
open(os.path.join(out, "data.js"), "w").write("window.DATA = " + json.dumps(data) + ";\n")
sample = json.loads(json.dumps(data))
for p in sample["photos"].values():
    p["src"] = "data:image/jpeg;base64,..."
sample["photos"] = dict(list(sample["photos"].items())[:3])
sample["collections"] = sample["collections"][:3]
sample["groups"] = sample["groups"][:3]
json.dump(sample, open(os.path.join(out, "data.sample.json"), "w"), indent=1)
print(f"{len(photos)} photos, {len(collections)} collections, {len(groups)} groups -> {out}/data.js ({os.path.getsize(os.path.join(out, 'data.js')) / 1e6:.1f} MB)")
print("collections:", [(c["title"], len(c["photos"]), len(c["groups"])) for c in collections])
