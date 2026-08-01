import CoreGraphics
import Foundation
import Testing

@testable import LatticeCore

private func anchor(
  fingerprint: String = "document",
  path: String = "/tmp/document.pdf",
  page: Int = 1,
  x: Double = 0.1
) -> PortalAnchor {
  PortalAnchor(
    documentFingerprint: fingerprint,
    documentPath: path,
    pageIndex: page,
    bounds: NormalizedRect(x: x, y: 0.2, width: 0.3, height: 0.1),
    quotedText: "portal snippet"
  )
}

private func location(page: Int, x: Double = 0.5) -> JumpLocation {
  JumpLocation(
    documentFingerprint: "document",
    documentPath: "/tmp/document.pdf",
    pageIndex: page,
    viewportCenter: NormalizedPoint(x: x, y: 0.5),
    scaleFactor: 1.25
  )
}

@Test func vimChordNavigationAndJumpShortcutsResolve() {
  var resolver = ShortcutResolver()
  #expect(resolver.resolve(key: "g", timestamp: 1.0) == nil)
  #expect(resolver.resolve(key: "g", timestamp: 1.5) == .documentStart)
  #expect(resolver.resolve(key: "G", timestamp: 2.0) == .documentEnd)
  #expect(resolver.resolve(key: "d", modifiers: .control, timestamp: 2.0) == .halfDown)
  #expect(
    resolver.resolve(key: "\u{0f}", keyCode: 31, modifiers: .control, timestamp: 3) == .jumpBackward
  )
  #expect(
    resolver.resolve(key: "\t", keyCode: 34, modifiers: .control, timestamp: 3) == .jumpForward)
  #expect(resolver.resolve(key: "\u{1b}", keyCode: 53, timestamp: 3) == .cancelPortal)
}

@Test func portalFileRoundTripsThroughJSON() throws {
  let portal = Portal(source: anchor(), destination: anchor(fingerprint: "other", page: 8, x: 0.5))
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .secondsSince1970
  let data = try encoder.encode(PortalFile(portals: [portal]))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .secondsSince1970
  #expect(try decoder.decode(PortalFile.self, from: data) == PortalFile(portals: [portal]))
}

@Test @MainActor func repositoryPersistsDeletesAndReplacesAtomically() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = PortalRepository(fileURL: directory.appendingPathComponent("portals.json"))
  let first = Portal(source: anchor(), destination: anchor(page: 2))
  let second = Portal(source: anchor(page: 3), destination: anchor(page: 4))
  try repository.save([first, second])
  #expect(try repository.load() == [first, second])
  try repository.save([second])
  #expect(try repository.load() == [second])
}

@Test @MainActor func repositoryMovesCorruptDataAside() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("portals.json")
  try Data("not json".utf8).write(to: url)
  let repository = PortalRepository(fileURL: url)
  #expect(throws: PortalRepositoryError.corruptFile) { try repository.load() }
  #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func jumpListTraversesAndClearsForwardHistory() {
  var jumps = JumpList(capacity: 3)
  jumps.recordBeforeJump(location(page: 1))
  jumps.recordBeforeJump(location(page: 2))
  #expect(jumps.goBackward(from: location(page: 3))?.pageIndex == 2)
  #expect(jumps.goBackward(from: location(page: 2))?.pageIndex == 1)
  #expect(jumps.goForward(from: location(page: 1))?.pageIndex == 2)
  jumps.recordBeforeJump(location(page: 9))
  #expect(jumps.forward.isEmpty)
}

@Test func jumpListDeduplicatesAndHonorsCapacity() {
  var jumps = JumpList(capacity: 2)
  jumps.recordBeforeJump(location(page: 1))
  jumps.recordBeforeJump(location(page: 1, x: 0.500_5))
  jumps.recordBeforeJump(location(page: 2))
  jumps.recordBeforeJump(location(page: 3))
  #expect(jumps.backward.map(\.pageIndex) == [2, 3])
}

@Test func normalizedRectAndPreviewCacheKeyAreStable() {
  let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
  #expect(rect.isValid)
  #expect(!NormalizedRect(x: 0.9, y: 0.2, width: 0.3, height: 0.4).isValid)
  let a = PreviewCacheKey(
    fingerprint: "f", pageIndex: 1, bounds: rect, backingScale: 2, appearance: "dark")
  let b = PreviewCacheKey(
    fingerprint: "f", pageIndex: 1, bounds: rect, backingScale: 2.001, appearance: "dark")
  #expect(a == b)
}

@Test func portalGeometryHandlesCropOriginsAndClamping() {
  let cropBox = CGRect(x: 40, y: 80, width: 600, height: 800)
  let pageRect = CGRect(x: 100, y: 160, width: 180, height: 240)
  let normalized = PortalGeometry.normalized(rect: pageRect, in: cropBox)
  #expect(normalized == NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
  #expect(PortalGeometry.pageRect(for: normalized!, in: cropBox) == pageRect)

  let overflowing = CGRect(x: 20, y: 60, width: 80, height: 100)
  #expect(
    PortalGeometry.normalized(rect: overflowing, in: cropBox)
      == NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1))
}

@Test func replacingMissingDocumentPathPreservesPortalIdentity() {
  let original = Portal(
    source: anchor(fingerprint: "source", path: "/missing/source.pdf"),
    destination: anchor(fingerprint: "destination", path: "/missing/destination.pdf")
  )
  let recovered = original.replacingDocumentPath(
    for: "destination", with: "/located/destination.pdf")
  #expect(recovered.id == original.id)
  #expect(recovered.source.documentPath == original.source.documentPath)
  #expect(recovered.destination.documentPath == "/located/destination.pdf")
}

@Test func documentFingerprintIsStable() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("lattice".utf8).write(to: url)
  #expect(try DocumentFingerprint.sha256(of: url) == DocumentFingerprint.sha256(of: url))
}
