#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ios/Lattice"
xcodegen generate
DEST="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
xcodebuild -project Lattice.xcodeproj -scheme Lattice \
  -destination "$DEST" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
