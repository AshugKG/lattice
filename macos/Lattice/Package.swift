// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Lattice",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "Lattice", targets: ["Lattice"]),
    .library(name: "LatticeCore", targets: ["LatticeCore"]),
  ],
  targets: [
    .target(name: "LatticeCore"),
    .executableTarget(name: "Lattice", dependencies: ["LatticeCore"]),
    .testTarget(name: "LatticeCoreTests", dependencies: ["LatticeCore"]),
  ]
)
