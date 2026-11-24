"""Find the photos you are in, fully offline.

Embeds every aligned face crop written by ./analyze (faces/*.jpg) with the ArcFace model
(models/w600k_r50.onnx) and compares each face to your reference photo(s).

Usage: .venv/bin/python faces.py <out-folder> <reference photo or folder of photos of you>

Writes <out>/me.json:
  {"threshold": 0.36, "reference_faces": 2,
   "photos": {photoId: {"sim": 0.71, "crop": "<id>_0.jpg"}}}   # best-matching face per photo with faces
A photo counts as "you" when sim >= threshold. Embeddings are cached in <out>/face_embeddings.npz.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import onnxruntime as ort
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "models", "w600k_r50.onnx")
THRESHOLD = 0.36  # ArcFace cosine similarity: same person is typically > 0.4, different people < 0.2
BATCH = 64


class Embedder:
    def __init__(self):
        opts = ort.SessionOptions()
        opts.log_severity_level = 3
        self.session = ort.InferenceSession(MODEL, opts, providers=["CPUExecutionProvider"])
        self.input = self.session.get_inputs()[0].name

    def __call__(self, paths):
        out = []
        for i in range(0, len(paths), BATCH):
            chunk = paths[i:i + BATCH]
            x = np.stack([np.asarray(Image.open(p).convert("RGB").resize((112, 112)), dtype=np.float32) for p in chunk])
            x = ((x - 127.5) / 127.5).transpose(0, 3, 1, 2)
            y = self.session.run(None, {self.input: x})[0]
            out.append(y / np.linalg.norm(y, axis=1, keepdims=True))
        return np.concatenate(out) if out else np.zeros((0, 512), np.float32)


def latest_records(out):
    latest = {}
    with open(os.path.join(out, "analysis.jsonl")) as f:
        for line in f:
            r = json.loads(line)
            latest[r["path"]] = r
    return [r for r in latest.values() if os.path.exists(r["path"])]


def reference_crops(out, reference):
    """Run the analyzer on the reference photo(s) and return the largest face crop of each."""
    ref_out = os.path.join(out, "reference")
    shutil.rmtree(ref_out, ignore_errors=True)
    with tempfile.TemporaryDirectory() as tmp:
        if os.path.isdir(reference):
            src = reference
        else:
            src = tmp
            os.symlink(os.path.abspath(reference), os.path.join(tmp, os.path.basename(reference)))
        subprocess.run([os.path.join(HERE, "analyze"), src, ref_out], check=True, stdout=subprocess.DEVNULL)
        # Read while the temporary link still exists (latest_records skips missing files).
        records = latest_records(ref_out) if os.path.exists(os.path.join(ref_out, "analysis.jsonl")) else []
    crops = []
    for r in records:
        faces = [f for f in r["faces"] if f.get("crop")]
        if not faces:
            print(f"  no usable face in reference {r['rel']}")
            continue
        biggest = max(faces, key=lambda f: f["box"][2] * f["box"][3])
        if len(faces) > 1:
            print(f"  {r['rel']}: {len(faces)} faces, using the largest one")
        crops.append(os.path.join(ref_out, "faces", biggest["crop"]))
    return crops


def main(out, reference):
    out = os.path.realpath(out)
    embed = Embedder()

    ref = reference_crops(out, reference)
    if not ref:
        sys.exit("No usable face found in the reference photo(s). Use a clear, front-facing photo of you.")
    ref_vecs = embed(ref)

    cache_path = os.path.join(out, "face_embeddings.npz")
    cache = {}
    if os.path.exists(cache_path):
        data = np.load(cache_path)
        cache = dict(zip(data["names"].tolist(), data["vecs"]))

    records = latest_records(out)
    crops = {f["crop"] for r in records for f in r["faces"] if f.get("crop")}
    todo = sorted(c for c in crops if c not in cache)
    print(f"{len(crops)} faces, {len(todo)} to embed")
    if todo:
        vecs = embed([os.path.join(out, "faces", c) for c in todo])
        cache.update(zip(todo, vecs))
        names = sorted(cache)
        np.savez(cache_path, names=np.array(names), vecs=np.stack([cache[n] for n in names]))

    photos = {}
    for r in records:
        best = None
        for f in r["faces"]:
            c = f.get("crop")
            if not c:
                continue
            sim = float(np.max(ref_vecs @ cache[c]))
            if best is None or sim > best["sim"]:
                best = {"sim": round(sim, 4), "crop": c}
        if best:
            photos[r["id"]] = best

    result = {"threshold": THRESHOLD, "reference_faces": len(ref), "photos": photos}
    with open(os.path.join(out, "me.json.tmp"), "w") as f:
        json.dump(result, f)
    os.replace(os.path.join(out, "me.json.tmp"), os.path.join(out, "me.json"))
    you = sum(1 for p in photos.values() if p["sim"] >= THRESHOLD)
    print(f"you appear in {you} of {len(photos)} photos with faces (threshold {THRESHOLD})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
