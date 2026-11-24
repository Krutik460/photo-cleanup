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
"""Convert the ArcFace recognition model to Core ML for the Mac app. Build time only.

    uv run scripts/convert_face_model.py [models/w600k_r50.onnx] [models/ArcFace.mlmodelc]

The app ships the compiled Core ML model and no third-party runtime. The conversion keeps Float32
weights (Float16 moved embeddings by up to 0.003 in cosine) and refuses to write a model whose
embeddings differ from ONNX Runtime's on the same input. uv installs the pinned tools into a
throwaway environment; nothing is added to the project.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import warnings

warnings.filterwarnings("ignore")

import coremltools as ct  # noqa: E402
import numpy as np  # noqa: E402
import onnx  # noqa: E402
import onnxruntime as ort  # noqa: E402
import torch  # noqa: E402
from onnx2torch import convert  # noqa: E402

# InsightFace buffalo_l recognition model (non-commercial license), as fetched by setup.sh.
SHA256 = "4c06341c33c2ca1f86781dab0e829f88ad5b64be9fba56e56bc9ebdefc619e43"
MIN_COSINE = 0.99999


def unit(v):
    return v / np.linalg.norm(v, axis=1, keepdims=True)


def main(source, target):
    digest = hashlib.sha256(open(source, "rb").read()).hexdigest()
    if digest != SHA256:
        sys.exit(f"{source}: unexpected checksum {digest}")

    rng = np.random.default_rng(0)
    # Image-like inputs in the model's range: smooth random pictures, normalized to -1..1.
    samples = np.clip(rng.normal(0, 0.5, (16, 3, 112, 112)), -1, 1).astype(np.float32)
    session = ort.InferenceSession(source, providers=["CPUExecutionProvider"])
    name = session.get_inputs()[0].name
    reference = unit(np.concatenate([session.run(None, {name: s[None]})[0] for s in samples]))

    net = convert(onnx.load(source)).eval()
    traced = torch.jit.trace(net, torch.from_numpy(samples[:1]))
    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="face", shape=(1, 3, 112, 112), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )
    converted = unit(np.concatenate([model.predict({"face": s[None]})["embedding"] for s in samples]))
    cosine = float((converted * reference).sum(1).min())
    print(f"lowest cosine against ONNX Runtime on {len(samples)} inputs: {cosine:.7f}")
    if cosine < MIN_COSINE:
        sys.exit(f"converted model does not match the original (needs {MIN_COSINE})")

    with tempfile.TemporaryDirectory() as tmp:
        package = os.path.join(tmp, "ArcFace.mlpackage")
        model.save(package)
        subprocess.run(["xcrun", "coremlcompiler", "compile", package, tmp], check=True, stdout=subprocess.DEVNULL)
        shutil.rmtree(target, ignore_errors=True)
        shutil.move(os.path.join(tmp, "ArcFace.mlmodelc"), target)
    print("wrote", target)


if __name__ == "__main__":
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "models", "w600k_r50.onnx"),
         sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "models", "ArcFace.mlmodelc"))
