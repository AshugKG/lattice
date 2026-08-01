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
  #expect(resolver.resolve(key: ":", timestamp: 4) == .showCommandPalette)
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

@Test func portalEndpointResolutionIsBidirectional() {
  let portal = Portal(source: anchor(page: 2), destination: anchor(page: 9))
  #expect(portal.oppositeAnchor(from: .source).pageIndex == 9)
  #expect(portal.oppositeAnchor(from: .destination).pageIndex == 2)
  #expect(portal.anchor(at: .destination).pageIndex == 9)
}

@Test func portalMarksIncludeAndSortCurrentDocumentSourcesOnly() {
  let sameDocument = Portal(source: anchor(page: 4, x: 0.5), destination: anchor(page: 1))
  let outgoing = Portal(
    source: anchor(page: 3), destination: anchor(fingerprint: "other", page: 8))
  let unrelated = Portal(
    source: anchor(fingerprint: "other", page: 0),
    destination: anchor(fingerprint: "third", page: 0))
  let entries = PortalMarks.entries(
    for: "document", portals: [sameDocument, outgoing, unrelated])
  #expect(entries.map(\.anchor.pageIndex) == [3, 4])
  #expect(entries.map(\.endpoint) == [.source, .source])
  #expect(entries.allSatisfy { $0.anchor.documentFingerprint == "document" })
}

@Test func commandCatalogSupportsExactAliasesAndFuzzyOrdering() {
  #expect(CommandCatalog.exact(":marks")?.action == .showMarks)
  #expect(CommandCatalog.exact("e")?.action == .open)
  #expect(CommandCatalog.matches("marks").first?.name == "marks")
  #expect(CommandCatalog.matches("mk").first?.name == "marks")
  #expect(CommandCatalog.matches("no command named this").isEmpty)
  #expect(CommandCatalog.matches("").count == CommandCatalog.commands.count)
}

@Test func jumpLocationClampsRestoredState() {
  let invalid = JumpLocation(
    documentFingerprint: "document",
    documentPath: "/tmp/document.pdf",
    pageIndex: 99,
    viewportCenter: NormalizedPoint(x: -4, y: 8),
    scaleFactor: 20
  ).clamped(pageCount: 5)
  #expect(invalid.pageIndex == 4)
  #expect(invalid.viewportCenter == NormalizedPoint(x: 0, y: 1))
  #expect(invalid.scaleFactor == 4)
}

@Test @MainActor func readingStateRepositoryRoundTripsAndReplacesLatestPosition() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = ReadingStateRepository(
    fileURL: directory.appendingPathComponent("reading-state.json"))
  let first = ReadingPosition(location: location(page: 2))
  try repository.save(["document": first])
  #expect(try repository.load() == ["document": first])

  let latest = ReadingPosition(location: location(page: 7))
  try repository.save(["document": latest])
  #expect(try repository.load()["document"] == latest)
}

@Test @MainActor func readingStateRepositoryMovesCorruptDataAside() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("reading-state.json")
  try Data("not json".utf8).write(to: url)
  let repository = ReadingStateRepository(fileURL: url)
  #expect(throws: ReadingStateRepositoryError.corruptFile) { try repository.load() }
  #expect(!FileManager.default.fileExists(atPath: url.path))
}
