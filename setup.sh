#!/bin/zsh
# One-time setup: builds the Swift tools, creates the Python environment for face matching and
# fetches the ArcFace model. Safe to rerun; finished steps are skipped.
# Needs: Xcode command line tools (swiftc), uv (brew install uv).
set -euo pipefail
here=${0:A:h}
cd $here

echo "building Swift tools..."
swiftc -O -parse-as-library -swift-version 5 -Xcc -DACCELERATE_NEW_LAPACK analyze.swift -o analyze
swiftc -O -swift-version 5 sheet.swift -o sheet

if [[ ! -x .venv/bin/python ]]; then
  echo "creating Python 3.12 environment..."
  uv venv --python 3.12 .venv
fi
uv pip install --python .venv/bin/python --quiet onnxruntime numpy pillow

model=models/w600k_r50.onnx
sha=4c06341c33c2ca1f86781dab0e829f88ad5b64be9fba56e56bc9ebdefc619e43
if [[ ! -f $model ]]; then
  echo "downloading InsightFace buffalo_l (289 MB, keeps only the 174 MB recognition model)..."
  tmp=$(mktemp -d)
  curl -fL --progress-bar -o $tmp/buffalo_l.zip https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip
  mkdir -p models
  unzip -j -o $tmp/buffalo_l.zip w600k_r50.onnx -d models >/dev/null
  rm -rf $tmp
fi
echo "$sha  $model" | shasum -a 256 -c --quiet || { echo "model checksum mismatch: delete $model and rerun"; exit 1; }
echo "ready"
