#!/bin/zsh
# Analyze a photo folder, find the photos you are in, and (re)build groups and collections.
# Safe to rerun: already-analyzed photos and already-embedded faces are skipped.
# Usage: ./run.sh <photo-folder> <output-folder> [photo of you | folder of photos of you]
# The reference is remembered in <output-folder>/reference_path.txt, so later runs can omit it.
set -euo pipefail
here=${0:A:h}
photos=$1 out=$2 ref=${3:-}
if [[ ! -x $here/analyze || $here/analyze.swift -nt $here/analyze ]]; then
  echo "building analyzer..."
  swiftc -O -parse-as-library -swift-version 5 -Xcc -DACCELERATE_NEW_LAPACK $here/analyze.swift -o $here/analyze
fi
$here/analyze "$photos" "$out" 2> >(grep -v FBBA >&2)
if [[ -n $ref ]]; then
  print -r -- ${ref:A} > "$out/reference_path.txt"
elif [[ -f $out/reference_path.txt ]]; then
  ref=$(<"$out/reference_path.txt")
fi
if [[ -n $ref ]]; then
  $here/.venv/bin/python -I $here/faces.py "$out" "$ref" 2> >(grep -v FBBA >&2)
else
  echo "no photo of you given: skipping face matching (pass one as the third argument)"
fi
python3 $here/group.py "$out"
