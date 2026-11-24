"""Group similar photos and auto-pick a favorite per group.

Reads <out>/analysis.jsonl and <out>/neighbors.json (written by ./analyze) and writes <out>/groups.json.
User decisions live in <out>/decisions.json and Haiku picks in <out>/haiku/*.json; this script never
touches them, so regrouping is always safe. Your fixes to trips and events from the review page
(<out>/collection_edits.json: merges, and collections that are not really a trip or event) are applied
before grouping.

Usage: python3 group.py <out-folder>
"""

import json
import math
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

# Feature-print distance thresholds (unit-vector Euclidean; 0 = identical, ~1.06 = typical unrelated pair).
DUPLICATE_DISTANCE = 0.40  # same shot or an edit/export of it: group no matter when it was taken
BURST_SECONDS, BURST_DISTANCE = 15, 0.70  # rapid-fire shots: allow blur and small movement
SCENE_SECONDS, SCENE_DISTANCE = 600, 0.50  # same people, same pose, a few minutes apart
MAX_GROUP_SPREAD = 0.80  # every pair inside a group must be at least this close (stops chaining)
EXACT_DUPLICATE = 0.06  # Vision feature prints jitter slightly, even for byte-identical files
CLOSE_CALL_MARGIN = 0.04  # top-two score gap under this is flagged for a second opinion
BLURRY_SHARPNESS = 15.0

# Collections (trips, events, everyday months). All offline: GPS coordinates are never sent anywhere.
MOMENT_GAP_HOURS = 3  # a pause this long between photos starts a new moment
MOMENT_MAX_KM = 25  # moving further than this starts a new moment
AWAY_KM = 50  # further than this from home counts as away
TRIP_MAX_GAP_HOURS = 36  # away moments closer than this in time form one trip
EVENT_MIN_PHOTOS = 20  # a day at home with at least this many photos is an event
HOME_GRID_DEGREES = 0.1  # ~10 km cells for finding home

# You (from faces.py -> me.json): keep more of your photos, prune everything else harder.
ME_RANK_BONUS = 0.20  # in a mixed group, a shot of you beats a slightly better shot without you
SECOND_OF_YOU_MARGIN = 0.10  # keep a second shot of you when it scores within this of the best one
SECOND_OF_YOU_DISTANCE = 0.30  # ...and is at least this different from it (not a near-copy)
EVENT_REPEAT_DISTANCE = 0.45  # without you: near-repeats anywhere in one trip or event form a group
LOW_QUALITY_PERCENTILE = 0.35  # singles without you scoring in the bottom 35% are suggested for removal


# "IMG_1.JPG" is the original of "IMG_1 2.JPG" (Finder), "IMG_1 copy.JPG" and "IMG_1(1).JPG" (downloads).
COPY_NAME = re.compile(r"( \d{1,2}| copy( \d+)?|\(\d+\))$", re.IGNORECASE)


def is_copy_name(rel):
    return bool(COPY_NAME.search(os.path.splitext(os.path.basename(rel))[0]))


def current_locations(out):
    """Photos the review page moved and that are still there: {photoId: {"op", "to", "chain"}}.

    Reads <out>/moves.jsonl, written by server.py. op "move" = in _to_remove, op "file" = in a
    collection folder. "chain" is every move since the last "restore" (a filed photo can later go to
    _to_remove); a "back" entry undoes only the last move of a photo.
    """
    chains = {}
    path = os.path.join(out, "moves.jsonl")
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                m = json.loads(line)
                if m["op"] == "restore":
                    chains.pop(m["id"], None)
                elif m["op"] == "back":
                    chain = chains.get(m["id"])
                    if chain:
                        chain.pop()
                        if not chain:
                            del chains[m["id"]]
                else:
                    chains.setdefault(m["id"], []).append(m)
    return {pid: {"op": ch[-1]["op"], "to": ch[-1]["to"], "chain": ch}
            for pid, ch in chains.items() if os.path.exists(ch[-1]["to"])}


def load(out):
    latest = {}
    with open(os.path.join(out, "analysis.jsonl")) as f:
        for line in f:
            r = json.loads(line)
            latest[r["path"]] = r  # append-only file: last record per path wins
    # A photo the page moved (into a collection folder or _to_remove) is still the same photo until
    # ./analyze sees it at its new path; from then on that newer record stands in for it.
    moved = current_locations(out)
    analyzed = {os.path.realpath(p) for p in latest}
    photos = {}
    for r in latest.values():
        if not os.path.exists(r["path"]):
            loc = moved.get(r["id"])
            if not loc or os.path.realpath(loc["to"]) in analyzed:
                continue
        r["time"] = r["taken"] if r.get("taken") else r["mtime"]
        photos[r["id"]] = r
    if latest and not photos:
        # Writing groups.json now would empty the review page; the drive is most likely unplugged.
        sys.exit(f"None of the {len(latest)} analyzed photos are where they were. "
                 "Is the drive with the photo folder connected?")
    with open(os.path.join(out, "neighbors.json")) as f:
        neighbors = json.load(f)
    me_path = os.path.join(out, "me.json")
    has_me = os.path.exists(me_path)
    if has_me:
        me = json.load(open(me_path))
        for pid, p in photos.items():
            m = me["photos"].get(pid)
            p["me_sim"] = m["sim"] if m else None
            p["me_crop"] = m["crop"] if m else None
            p["me"] = bool(m and m["sim"] >= me["threshold"])
    return photos, neighbors, has_me


def score(p):
    """0..1 quality estimate. Faces dominate when present: a sharp, open-eyed, well-framed face is
    what makes one shot of a burst better than the next."""
    aes = ((p.get("aesthetic") if p.get("aesthetic") is not None else 0) + 1) / 2
    sharp = min(max(math.log10(max(p["sharpness"], 1)) / 3.5, 0), 1)
    qualities = [f["quality"] for f in p["faces"] if f.get("quality") is not None]
    if p.get("me"):
        # Your face counts most: your eyes open and sharp matters more than anyone else's.
        mine = [f["quality"] for f in p["faces"] if f.get("crop") == p["me_crop"] and f.get("quality") is not None]
        others = [f["quality"] for f in p["faces"] if f.get("crop") != p["me_crop"] and f.get("quality") is not None]
        if mine:
            face = 0.7 * mine[0] + 0.3 * (min(others) if others else mine[0])
            return 0.55 * face + 0.30 * aes + 0.15 * sharp
    if qualities:
        face = 0.6 * min(qualities) + 0.4 * (sum(qualities) / len(qualities))
        return 0.55 * face + 0.30 * aes + 0.15 * sharp
    return 0.70 * aes + 0.30 * sharp


def linked(a, b, d, coll):
    gap = abs(a["time"] - b["time"])
    if d < DUPLICATE_DISTANCE:
        return True
    ca = coll[a["id"]]
    if (d < EVENT_REPEAT_DISTANCE and not a.get("me") and not b.get("me")
            and ca["id"] == coll[b["id"]]["id"] and ca["kind"] != "everyday"):
        return True  # without you, one good version of a scene per trip or event is enough
    fa, fb = len(a["faces"]), len(b["faces"])
    if fa and fb and abs(fa - fb) > 1:
        return False  # different set of people
    if fa and fb and bool(a.get("me")) != bool(b.get("me")):
        return False  # you in one, other people in the other: not the same shot
    return (gap <= BURST_SECONDS and d < BURST_DISTANCE) or (gap <= SCENE_SECONDS and d < SCENE_DISTANCE)


def build_groups(photos, neighbors, coll):
    dist = {}
    edges = []
    for a, near in neighbors.items():
        if a not in photos:
            continue
        for b, d in near:
            if b not in photos:
                continue
            dist[(a, b)] = dist[(b, a)] = d
            if a < b and linked(photos[a], photos[b], d, coll):
                edges.append((d, a, b))
    edges.sort()

    # Agglomerative merge, closest pairs first, refusing any merge that would put two photos
    # further apart than MAX_GROUP_SPREAD in the same group (complete linkage).
    cluster = {pid: {pid} for pid in photos}
    for d, a, b in edges:
        ca, cb = cluster[a], cluster[b]
        if ca is cb:
            continue
        if all(dist.get((x, y), math.inf) <= MAX_GROUP_SPREAD for x in ca for y in cb):
            ca |= cb
            for pid in cb:
                cluster[pid] = ca
    unique = {id(c): c for c in cluster.values()}
    return list(unique.values()), dist


def group_kind(members, dist, photos):
    ds = [dist.get((a, b), math.inf) for i, a in enumerate(members) for b in members[i + 1:]]
    same_dims = len({(photos[m]["width"], photos[m]["height"]) for m in members}) == 1
    if max(ds) < EXACT_DUPLICATE and same_dims:
        return "duplicate"
    if max(ds) < DUPLICATE_DISTANCE:
        return "near-duplicate"
    return "similar"


def km(a, b):
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(h))


def day_of(p):
    # EXIF capture times are wall-clock values stored as if UTC; file times are real instants.
    if p.get("taken"):
        return datetime.fromtimestamp(p["time"], timezone.utc).date()
    return datetime.fromtimestamp(p["time"]).date()


def centroid(points):
    if not points:
        return None
    return [sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points)]


def find_home(photos):
    """Home = the ~10 km area photographed on the most distinct days."""
    days = {}
    for p in photos:
        if p.get("gps"):
            cell = (round(p["gps"][0] / HOME_GRID_DEGREES), round(p["gps"][1] / HOME_GRID_DEGREES))
            days.setdefault(cell, set()).add(day_of(p))
    if not days:
        return None
    best = max(days, key=lambda c: len(days[c]))
    pts = [p["gps"] for p in photos if p.get("gps")
           and (round(p["gps"][0] / HOME_GRID_DEGREES), round(p["gps"][1] / HOME_GRID_DEGREES)) == best]
    return centroid(pts)


def build_collections(photos, edits):
    """Split the timeline into trips (away from home), events (busy days at home) and everyday months."""
    ordered = sorted(photos.values(), key=lambda p: (p["time"], p["rel"]))
    home = find_home(ordered)

    # 1. Moments: runs of photos without a long pause or a big move.
    moments = []
    for p in ordered:
        cur = moments[-1] if moments else None
        new = cur is None or p["time"] - cur["end"] > MOMENT_GAP_HOURS * 3600
        if not new and p.get("gps") and cur["last_gps"] and km(p["gps"], cur["last_gps"]) > MOMENT_MAX_KM:
            new = True
        if new:
            cur = {"photos": [], "end": p["time"], "last_gps": None}
            moments.append(cur)
        cur["photos"].append(p)
        cur["end"] = p["time"]
        if p.get("gps"):
            cur["last_gps"] = p["gps"]
    for m in moments:
        pts = [p["gps"] for p in m["photos"] if p.get("gps")]
        m["start"] = m["photos"][0]["time"]
        m["center"] = centroid(pts)
        m["away"] = bool(home and pts and sum(km(x, home) > AWAY_KM for x in pts) * 2 > len(pts))

    # 2. Away moments close together in time become one trip; home moments fold into their day.
    raw = []
    for m in moments:
        prev = raw[-1] if raw else None
        if m["away"]:
            if prev and prev["away"] and m["start"] - prev["end"] <= TRIP_MAX_GAP_HOURS * 3600:
                prev["photos"] += m["photos"]
                prev["end"] = m["end"]
            else:
                raw.append({"away": True, "photos": list(m["photos"]), "end": m["end"]})
        else:
            day = day_of(m["photos"][0])
            if prev and not prev["away"] and prev["day"] == day:
                prev["photos"] += m["photos"]
                prev["end"] = m["end"]
            else:
                raw.append({"away": False, "day": day, "photos": list(m["photos"]), "end": m["end"]})

    # 3. Name them. Quiet home days collapse into one "everyday" collection per month.
    collections, everyday = [], {}
    for r in raw:
        ps = r["photos"]
        if r["away"]:
            days = len({day_of(p) for p in ps})
            collections.append({"kind": "trip" if days > 1 else "daytrip", "photos": ps})
        elif len(ps) >= EVENT_MIN_PHOTOS:
            collections.append({"kind": "event", "photos": ps})
        else:
            key = r["day"].strftime("%Y-%m")
            if key not in everyday:
                everyday[key] = {"kind": "everyday", "photos": []}
                collections.append(everyday[key])
            everyday[key]["photos"] += ps

    collections = apply_edits(collections, edits)

    out = []
    for c in collections:
        c["photos"].sort(key=lambda p: (p["time"], p["rel"]))
    for c in sorted(collections, key=lambda c: (c["photos"][0]["time"], c["photos"][0]["rel"])):
        ps = c["photos"]
        pts = [p["gps"] for p in ps if p.get("gps")]
        center = centroid(pts)
        summary = {
            "kind": c["kind"],
            "start": ps[0]["time"],
            "end": ps[-1]["time"],
            "timeKnown": all(bool(p.get("taken")) for p in ps),
            "days": len({day_of(p) for p in ps}),
            "center": [round(x, 4) for x in center] if center else None,
            "homeKm": round(km(center, home)) if center and home else None,
            "members": [p["id"] for p in ps],
        }
        if c.get("parts", 1) > 1:
            summary["parts"] = c["parts"]
        if c.get("folded"):
            summary["folded"] = sorted(c["folded"].values(), key=lambda f: f["start"])
        out.append(summary)
    for i, c in enumerate(out):
        c["id"] = f"c{i + 1}"
    return out, home


def load_edits(out):
    """<out>/collection_edits.json, written by the review page:
    {"merges": [[[photoId, ...] per part], ...],
     "moves": [{"photos": [photoId, ...], "into": [photoId, ...]}, ...],
     "not_collections": [{"photos": [photoId, ...], "names": [...], "folders": [...]}, ...]}."""
    try:
        with open(os.path.join(out, "collection_edits.json")) as f:
            edits = json.load(f)
    except FileNotFoundError:
        edits = {}
    return {"merges": edits.get("merges") or [], "moves": edits.get("moves") or [],
            "not_collections": edits.get("not_collections") or []}


def home_of(listed, owner):
    """The collection holding most of the listed photos now, or None when none of them are left."""
    where = Counter(owner[pid] for pid in listed if pid in owner)
    return where.most_common(1)[0][0] if where else None


def apply_edits(collections, edits):
    """Apply your fixes from the review page to the detected collections ({kind, photos} each).

    An edit lists the photos of the collections it was made on and applies to the collection holding
    most of them now, so it survives reruns that add, remove or regroup photos. A photo that drifted
    into another collection (say an everyday month) never drags that whole collection along.
    1. merges: each part's collection joins the merge, and drifted photos of a part are pulled back;
    2. not_collections: a trip, day trip or event holding most of the listed photos is not really one,
       so its photos fold into the everyday collection of their month. That collection remembers what
       was folded in ("folded"), so the page can offer to restore it;
    3. moves: the listed photos go into the collection holding most of the "into" photos. Moves come
       last, so the target is the collection you picked as it looks now (an everyday month that took in
       a folded event is still that month), and nothing after them sends the photos elsewhere.
    """
    for parts in edits["merges"]:
        owner = {p["id"]: i for i, c in enumerate(collections) for p in c["photos"]}
        homes, drifted, found = set(), set(), 0
        for part in parts:
            home = home_of(part, owner)
            if home is None:
                continue
            found += 1
            homes.add(home)
            drifted.update(pid for pid in part if pid in owner and owner[pid] != home)
        drifted = {pid for pid in drifted if owner[pid] not in homes}
        if len(homes) < 2 and not drifted:
            continue
        merged = [collections[i] for i in sorted(homes)]
        ps = [p for c in merged for p in c["photos"]]
        for i, c in enumerate(collections):
            if i not in homes and drifted:
                ps += [p for p in c["photos"] if p["id"] in drifted]
                c["photos"] = [p for p in c["photos"] if p["id"] not in drifted]
        kinds = {c["kind"] for c in merged}
        if kinds & {"trip", "daytrip"}:
            kind = "trip" if len({day_of(p) for p in ps}) > 1 else "daytrip"
        elif "event" in kinds:
            kind = "event"
        else:
            kind = "everyday"
        collections = [c for i, c in enumerate(collections) if i not in homes and c["photos"]]
        collections.append({"kind": kind, "photos": ps, "parts": found})

    owner = {p["id"]: i for i, c in enumerate(collections) for p in c["photos"]}
    hits = {}  # collection index -> one photo per mark on it (the page sends these back to restore)
    for mark in edits["not_collections"]:
        home = home_of(mark["photos"], owner)
        if home is not None and collections[home]["kind"] != "everyday":
            hits.setdefault(home, []).append(next(pid for pid in mark["photos"] if owner.get(pid) == home))
    everyday = {}
    for i, c in enumerate(collections):
        if c["kind"] == "everyday" and i not in hits:
            for p in c["photos"]:
                everyday.setdefault(day_of(p).strftime("%Y-%m"), c)
    kept = [c for i, c in enumerate(collections) if i not in hits]
    for i, anchors in sorted(hits.items()):
        ps = sorted(collections[i]["photos"], key=lambda p: (p["time"], p["rel"]))
        note = {"anchors": anchors, "kind": collections[i]["kind"], "start": ps[0]["time"], "end": ps[-1]["time"],
                "timeKnown": all(bool(p.get("taken")) for p in ps), "photos": len(ps)}
        for p in ps:
            key = day_of(p).strftime("%Y-%m")
            if key not in everyday:
                everyday[key] = {"kind": "everyday", "photos": []}
                kept.append(everyday[key])
            everyday[key].setdefault("folded", {})[anchors[0]] = note
            everyday[key]["photos"].append(p)
    collections = kept

    for move in edits["moves"]:
        owner = {p["id"]: i for i, c in enumerate(collections) for p in c["photos"]}
        listed = set(move["photos"])
        target = home_of([pid for pid in move["into"] if pid not in listed], owner)
        if target is None:
            continue
        moving = {pid for pid in listed if pid in owner and owner[pid] != target}
        if not moving:
            continue
        dest = collections[target]
        for c in collections:
            if c is not dest:
                dest["photos"] += [p for p in c["photos"] if p["id"] in moving]
                c["photos"] = [p for p in c["photos"] if p["id"] not in moving]
        if dest["kind"] in ("trip", "daytrip"):
            dest["kind"] = "trip" if len({day_of(p) for p in dest["photos"]}) > 1 else "daytrip"
        collections = [c for c in collections if c["photos"]]
    return collections


def main(out):
    photos, neighbors, has_me = load(out)
    collections, home = build_collections(photos, load_edits(out))
    coll_of_photo = {pid: c for c in collections for pid in c["members"]}
    clusters, dist = build_groups(photos, neighbors, coll_of_photo)

    for p in photos.values():
        p["score"] = round(score(p), 4)
    auto = {}  # photoId -> (state, reason)

    groups = []
    for c in clusters:
        members = list(c)
        if len(members) < 2:
            continue
        max_px = max(photos[m]["width"] * photos[m]["height"] for m in members) or 1
        max_size = max(photos[m]["size"] for m in members) or 1

        def rank(m):
            p = photos[m]
            # Small bonus for the full-resolution original over a downscaled copy.
            return (p["score"] + 0.05 * (p["width"] * p["height"] / max_px) + 0.01 * (p["size"] / max_size)
                    + (ME_RANK_BONUS if p.get("me") else 0))

        # Ties (exact copies score the same) go to the original file name, then the shorter path, so
        # reruns always pick the same favorite.
        members.sort(key=lambda m: (-rank(m), is_copy_name(photos[m]["rel"]), len(photos[m]["rel"]), photos[m]["rel"]))
        kind = group_kind(members, dist, photos)
        if kind == "duplicate":
            close = False
        else:
            close = rank(members[0]) - rank(members[1]) < CLOSE_CALL_MARGIN
        fav = members[0]
        has_you = any(photos[m].get("me") for m in members)
        auto[fav] = ("fav", "Best shot of you in this group" if photos[fav].get("me") else "Best shot of this group")
        second = None
        if photos[fav].get("me"):
            second = next((m for m in members[1:] if photos[m].get("me")
                           and rank(m) >= rank(fav) - SECOND_OF_YOU_MARGIN
                           and dist.get((fav, m), math.inf) >= SECOND_OF_YOU_DISTANCE), None)
        for m in members[1:]:
            if m == second:
                auto[m] = ("keep", "Another good, different shot of you")
            elif photos[m].get("me"):
                auto[m] = ("remove", "A weaker repeat of a better shot of you")
            else:
                auto[m] = ("remove", "A weaker repeat of the favorite")
        groups.append({
            "members": members,
            "kind": kind,
            "close": close,
            "you": has_you,
            "time": min(photos[m]["time"] for m in members),
        })

    groups.sort(key=lambda g: (g["time"], photos[g["members"][0]]["rel"]))
    group_of = {}
    for i, g in enumerate(groups):
        g["id"] = f"g{i + 1}"
        for m in g["members"]:
            group_of[m] = g["id"]
        del g["time"]
    collection_of = {pid: c["id"] for c in collections for pid in c["members"]}
    for c in collections:
        c["groups"] = []
    coll_by_id = {c["id"]: c for c in collections}
    for g in groups:
        # A similar-shot group lives in the collection holding most of its photos (ties: the favorite's).
        votes = {}
        for m in g["members"]:
            votes[collection_of[m]] = votes.get(collection_of[m], 0) + 1
        top = max(votes.values())
        g["collection"] = collection_of[g["members"][0]] if votes[collection_of[g["members"][0]]] == top \
            else max(votes, key=votes.get)
        coll_by_id[g["collection"]]["groups"].append(g["id"])

    # Singles: always keep yours; without you, suggest removing blurry, screenshot/document and
    # (when we know which photos are yours) bottom-quality photos.
    others = sorted(p["score"] for p in photos.values() if not p.get("me"))
    low_cut = others[int(len(others) * LOW_QUALITY_PERCENTILE)] if has_me and others else -1
    out_photos = {}
    for pid, p in photos.items():
        tags = []
        if p.get("utility"):
            tags.append("utility")
        if p["sharpness"] < BLURRY_SHARPNESS:
            tags.append("blurry")
        g = group_of.get(pid)
        if g is None:
            if p.get("me"):
                auto[pid] = ("keep", "You're in this photo")
            elif "blurry" in tags:
                auto[pid] = ("remove", "Blurry")
            elif "utility" in tags:
                auto[pid] = ("remove", "Looks like a screenshot or document")
            elif p["score"] < low_cut:
                auto[pid] = ("remove", "Below-average quality and you're not in it")
            else:
                auto[pid] = ("keep", "")
        state, reason = auto[pid]
        out_photos[pid] = {
            "rel": p["rel"],
            "path": p["path"],
            "time": p["time"],
            "timeKnown": bool(p.get("taken")),
            "w": p["width"],
            "h": p["height"],
            "size": p["size"],
            "faces": len(p["faces"]),
            "faceQ": [round(f["quality"], 3) for f in p["faces"] if f.get("quality") is not None],
            "aes": None if p.get("aesthetic") is None else round(p["aesthetic"], 3),
            "sharp": round(p["sharpness"], 1),
            "score": p["score"],
            "tags": tags,
            "group": g,
            "collection": collection_of[pid],
            "gps": [round(x, 5) for x in p["gps"]] if p.get("gps") else None,
            "auto": state,
            "reason": reason,
            "me": bool(p.get("me")),
            "meSim": p.get("me_sim"),
        }

    # Photos outside any group, in time order, so the "All" view reads like a camera roll.
    order = sorted(out_photos, key=lambda k: (out_photos[k]["time"], out_photos[k]["rel"]))
    result = {
        "generated": datetime.now(timezone.utc).isoformat(),
        "settings": {
            "duplicate_distance": DUPLICATE_DISTANCE,
            "burst": [BURST_SECONDS, BURST_DISTANCE],
            "scene": [SCENE_SECONDS, SCENE_DISTANCE],
            "max_group_spread": MAX_GROUP_SPREAD,
        },
        "home": [round(x, 3) for x in home] if home else None,
        "collections": collections,
        "groups": groups,
        "photos": out_photos,
        "order": order,
    }
    tmp = os.path.join(out, "groups.json.tmp")
    with open(tmp, "w") as f:
        json.dump(result, f)
    os.replace(tmp, os.path.join(out, "groups.json"))

    grouped = sum(len(g["members"]) for g in groups)
    removals = sum(1 for p in out_photos.values() if p["auto"] == "remove")
    print(f"{len(photos)} photos -> {len(groups)} groups covering {grouped} photos, "
          f"{len(photos) - grouped} singles; auto-marked {removals} for removal; "
          f"{sum(g['close'] for g in groups)} close calls")
    kinds = {}
    for c in collections:
        kinds[c["kind"]] = kinds.get(c["kind"], 0) + 1
    print("collections:", ", ".join(f"{n} {k}" for k, n in kinds.items()))
    if has_me:
        mine = [p for p in out_photos.values() if p["me"]]
        print(f"you: in {len(mine)} photos; {sum(p['auto'] == 'remove' for p in mine)} of them suggested for removal "
              f"(weaker repeats); singles without you below score {low_cut:.3f} suggested for removal")
    else:
        print("no me.json: run faces.py with a photo of you to keep more of your photos")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
