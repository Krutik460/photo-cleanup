#!/bin/zsh
# Builds Photo Cleanup.app (Release, Apple silicon and Intel) and packs it into dist/Photo-Cleanup-<version>.dmg.
#
#   scripts/make-dmg.sh            for your own Macs: with the face model, signed with the Apple
#                                  Development identity on this Mac when there is one (so macOS keeps
#                                  folder permissions across updates)
#   scripts/make-dmg.sh --public   for a public download: without the face model (its license does not
#                                  allow passing it on freely) and signed ad hoc, so the app carries
#                                  nothing about who built it
#
# Neither is notarized: on a Mac that downloaded it, the first launch needs System Settings >
# Privacy & Security > Open Anyway.
# Needs: Xcode, xcodegen (brew install xcodegen), and for the first form the face model (see below).
set -euo pipefail
here=${0:A:h:h}
cd $here
public=0
[[ ${1:-} == --public ]] && public=1

if (( ! public )) && [[ ! -d models/ArcFace.mlmodelc ]]; then
  if [[ ! -f models/w600k_r50.onnx ]]; then
    echo "The face model is missing. Fetch it first:  ./setup.sh   (downloads models/w600k_r50.onnx)"
    exit 1
  fi
  echo "converting the face model to Core ML (one time)..."
  uv run --quiet scripts/convert_face_model.py
fi

echo "building..."
xcodegen generate --quiet
rm -rf build/Release
xcodebuild -project PhotoCleanup.xcodeproj -scheme PhotoCleanup -configuration Release -derivedDataPath build/Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build 2>&1 | grep -E "error:|warning: .*deprecated|BUILD (SUCCEEDED|FAILED)" | grep -v "warning:" || true
app="build/Release/Build/Products/Release/Photo Cleanup.app"
[[ -d $app ]] || { echo "build failed: run the xcodebuild line by hand to see why"; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

# The public build leaves the model out: the app then says that photos of you are not picked out.
if (( public )) && [[ -d "$app/Contents/Resources/ArcFace.mlmodelc" ]]; then
  echo "leaving the face model out..."
  rm -r "$app/Contents/Resources/ArcFace.mlmodelc"
fi

identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')
(( public )) && identity=""
if (( public )); then
  echo "signing ad hoc..."
  codesign --force --sign - "$app"
elif [[ -n $identity ]]; then
  echo "signing with your Apple Development identity..."
  codesign --force --sign $identity --timestamp=none "$app"
else
  echo "no Apple Development identity found: signing ad hoc (folder permissions are asked again after each update)"
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"

echo "packing..."
stage=$(mktemp -d)
trap 'rm -rf $stage' EXIT
cp -R "$app" $stage/
ln -s /Applications $stage/Applications
mkdir -p dist
dmg="dist/Photo-Cleanup-$version.dmg"
rm -f $dmg
hdiutil create -quiet -volname "Photo Cleanup" -srcfolder $stage -format UDZO -ov $dmg
hdiutil verify -quiet $dmg
echo "$dmg  ($(du -h $dmg | cut -f1), $(lipo -archs "$app/Contents/MacOS/Photo Cleanup"))"
