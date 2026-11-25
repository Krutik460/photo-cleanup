# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#   "coremltools==9.0",
#   "numpy==2.5.5",
#   "onnx==1.23.2",
#   "onnx2torch==1.5.15",
#   "onnxruntime==1.32.0",
#   "torch==2.7.1",
# ]
# ///
"""Fetch the face recognition model and convert it to Core ML for the Mac app. Build time only.

    uv run scripts/convert_face_model.py [models/face_recognition_sface_2021dec.onnx] [models/SFace.mlmodelc]

The model is SFace from OpenCV's model zoo (MobileFaceNet trained with the SFace loss, Apache 2.0
license, so the app may ship it). It takes an aligned 112x112 face as RGB values 0..255 and returns
128 numbers; it does its own normalization.

The app ships the compiled Core ML model and no third-party runtime. The conversion keeps Float32
weights and refuses to write a model whose embeddings differ from ONNX Runtime's on the same input.
uv installs the pinned tools into a throwaway environment; nothing is added to the project.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import warnings

warnings.filterwarnings("ignore")

import coremltools as ct  # noqa: E402
import numpy as np  # noqa: E402
import onnx  # noqa: E402
import onnxruntime as ort  # noqa: E402
import torch  # noqa: E402
from onnx2torch import convert  # noqa: E402

URL = "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx"
SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
MIN_COSINE = 0.99999


def unit(v):
    return v / np.linalg.norm(v, axis=1, keepdims=True)


def main(source, target):
    if not os.path.exists(source):
        print("downloading SFace from OpenCV's model zoo (37 MB)...")
        os.makedirs(os.path.dirname(source), exist_ok=True)
        urllib.request.urlretrieve(URL, source + ".part")
        os.replace(source + ".part", source)
    digest = hashlib.sha256(open(source, "rb").read()).hexdigest()
    if digest != SHA256:
        sys.exit(f"{source}: unexpected checksum {digest}")

    # The file lists its weights as inputs, the old way; as plain constants the tools read it cleanly.
    graph = onnx.load(source)
    weights = {w.name for w in graph.graph.initializer}
    for i in [i for i in graph.graph.input if i.name in weights]:
        graph.graph.input.remove(i)

    rng = np.random.default_rng(0)
    # Image-like inputs in the model's range: random pictures with values 0..255.
    samples = np.clip(rng.normal(127.5, 64, (16, 3, 112, 112)), 0, 255).astype(np.float32)
    session = ort.InferenceSession(graph.SerializeToString(), providers=["CPUExecutionProvider"])
    name = session.get_inputs()[0].name
    reference = unit(np.concatenate([session.run(None, {name: s[None]})[0] for s in samples]))

    net = convert(graph).eval()
    traced = torch.jit.trace(net, torch.from_numpy(samples[:1]))
    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="face", shape=(1, 3, 112, 112), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )
    converted = unit(np.concatenate([model.predict({"face": s[None]})["embedding"].reshape(1, -1) for s in samples]))
    cosine = float((converted * reference).sum(1).min())
    print(f"lowest cosine against ONNX Runtime on {len(samples)} inputs: {cosine:.7f}")
    if cosine < MIN_COSINE:
        sys.exit(f"converted model does not match the original (needs {MIN_COSINE})")

    with tempfile.TemporaryDirectory() as tmp:
        package = os.path.join(tmp, "SFace.mlpackage")
        model.save(package)
        subprocess.run(["xcrun", "coremlcompiler", "compile", package, tmp], check=True, stdout=subprocess.DEVNULL)
        shutil.rmtree(target, ignore_errors=True)
        shutil.move(os.path.join(tmp, "SFace.mlmodelc"), target)
    print("wrote", target)


if __name__ == "__main__":
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "models", "face_recognition_sface_2021dec.onnx"),
         sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "models", "SFace.mlmodelc"))
