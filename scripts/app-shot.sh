#!/bin/zsh
# Development: launch the debug build with a scratch libraries folder and save a picture of its window.
# Usage: scripts/app-shot.sh <scratch folder> <picture name> [NAME=value ...]
#   scripts/app-shot.sh /tmp/apptest 02-add PHOTOCLEANUP_SHOW=add
# The variables are the PHOTOCLEANUP_* ones read by MacApp/DebugAutomation.swift.
set -euo pipefail
here=${0:A:h:h}
scratch=$1 name=$2
shift 2
mkdir -p $scratch/libs $scratch/shots
env PHOTOCLEANUP_LIBRARIES=$scratch/libs PHOTOCLEANUP_SNAPSHOT=$scratch/shots/$name.png "$@" \
  "$here/build/DerivedData/Build/Products/Debug/Photo Cleanup.app/Contents/MacOS/Photo Cleanup" 2>&1 \
  | grep -vE "^$|IMKC|CFPrefs|os_unix|Greymatter|TSM|RBSService|ViewBridge" || true
ls $scratch/shots | grep "^$name" || { echo "no picture written"; exit 1; }
