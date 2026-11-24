"""Prepare the Haiku review: one numbered contact sheet per group, split into batches.

A Haiku agent reads one batch file, looks at its contact sheets, and writes its picks (by photo
number) to the batch's `output` path. merge_review.py then validates those answers and turns them
into <out>/haiku/<batch>.json, which the review page reads.

Groups already reviewed (any member present in <out>/haiku/*.json) and exact-duplicate groups (nothing
to judge) are skipped, so this is safe to rerun after regrouping.

Usage: python3 prepare_review.py <out-folder> [sheets-per-batch]
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PER_SHEET = 16


def ensure_sheet_tool():
    exe, src = os.path.join(HERE, "sheet"), os.path.join(HERE, "sheet.swift")
    if not os.path.exists(exe) or os.path.getmtime(src) > os.path.getmtime(exe):
        subprocess.run(["swiftc", "-O", "-swift-version", "5", src, "-o", exe], check=True)
    return exe


def main(out, per_batch=20):
    out = os.path.realpath(out)
    sheet = ensure_sheet_tool()
    data = json.load(open(os.path.join(out, "groups.json")))
    hdir = os.path.join(out, "haiku")
    os.makedirs(hdir, exist_ok=True)
    reviewed = set()
    for name in os.listdir(hdir):
        if name.endswith(".json"):
            reviewed |= set(json.load(open(os.path.join(hdir, name))))

    todo = [g for g in data["groups"] if g["kind"] != "duplicate" and not reviewed & set(g["members"])]
    for sub in ("review_batches", "review_sheets", "review_raw"):
        d = os.path.join(out, sub)
        os.makedirs(d, exist_ok=True)
        if sub != "review_raw":
            for name in os.listdir(d):
                os.remove(os.path.join(d, name))

    entries = []
    for g in todo:
        sheets = []
        for start in range(0, len(g["members"]), PER_SHEET):
            chunk = g["members"][start:start + PER_SHEET]
            path = os.path.join(out, "review_sheets", f"{g['id']}_{start // PER_SHEET + 1}.jpg")
            thumbs = [os.path.join(out, "thumbs", pid + ".jpg") for pid in chunk]
            you = [str(start + 1 + i) for i, pid in enumerate(chunk) if data["photos"][pid].get("me")]
            flag = ["--you=" + ",".join(you)] if you else []
            subprocess.run([sheet, path, str(start + 1), *flag, *thumbs], check=True)
            sheets.append(path)
        entries.append({
            "group": g["id"],
            "photos": len(g["members"]),
            "faces": max(data["photos"][m]["faces"] for m in g["members"]),
            "suggested_fav": 1,  # members are sorted best-first by the on-device score
            "you": [i + 1 for i, pid in enumerate(g["members"]) if data["photos"][pid].get("me")],
            "sheets": sheets,
            "members": {str(i + 1): pid for i, pid in enumerate(g["members"])},
        })

    batches, cur, count = [], [], 0
    for e in entries:
        if cur and count + len(e["sheets"]) > per_batch:
            batches.append(cur)
            cur, count = [], 0
        cur.append(e)
        count += len(e["sheets"])
    if cur:
        batches.append(cur)

    taken = {n[:-5] for n in os.listdir(hdir) if n.endswith(".json")}
    n, paths = 0, []
    for batch in batches:
        n += 1
        while f"batch_{n:03d}" in taken:
            n += 1
        name = f"batch_{n:03d}"
        path = os.path.join(out, "review_batches", name + ".json")
        with open(path, "w") as f:
            json.dump({"name": name, "output": os.path.join(out, "review_raw", name + ".json"), "groups": batch}, f, indent=1)
        paths.append(path)

    photos = sum(len(g["members"]) for g in todo)
    print(f"{len(todo)} groups ({photos} photos) to review in {len(batches)} batches")
    for p in paths:
        print(p)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) == 3 else 20)
