// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Lattice",
  platforms: [.macOS(.v13), .iOS(.v17)],
  products: [
    .executable(name: "Lattice", targets: ["Lattice"]),
    .library(name: "LatticeCore", targets: ["LatticeCore"]),
    .library(name: "LatticeReader", targets: ["LatticeReader"]),
  ],
  targets: [
    .target(name: "LatticeCore"),
    .target(name: "LatticeReader", dependencies: ["LatticeCore"]),
    .executableTarget(name: "Lattice", dependencies: ["LatticeCore", "LatticeReader"]),
    .testTarget(name: "LatticeCoreTests", dependencies: ["LatticeCore"]),
  ]
)
