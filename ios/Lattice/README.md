# Lattice for iOS

Minimal SwiftUI + PDFKit reader that reuses `LatticeCore` from `macos/Lattice`.

## Features

- Recent PDFs home (imported into the app sandbox)
- Resume reading position / zoom
- Back / forward jump list
- Touch mark capture (source box → destination box → teleport)
- Go to page and Find

## Requirements

- Xcode 16+ with an iOS Simulator runtime installed
- iOS 17+ (iPhone and iPad)

## Generate / open

```sh
cd ios/Lattice
xcodegen generate
open Lattice.xcodeproj
```

Select a Simulator (or your device + signing team) and Run.

## CLI build (simulator)

```sh
cd ios/Lattice
xcodegen generate
xcodebuild -project Lattice.xcodeproj -scheme Lattice \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build build
```
