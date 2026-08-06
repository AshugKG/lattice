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

private func location(
  fingerprint: String = "document",
  path: String = "/tmp/document.pdf",
  page: Int,
  x: Double = 0.5
) -> JumpLocation {
  JumpLocation(
    documentFingerprint: fingerprint,
    documentPath: path,
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
  #expect(resolver.resolve(key: "h", modifiers: .control, timestamp: 2.1) == .focusLeft)
  #expect(
    resolver.resolve(key: "\u{8}", keyCode: 4, modifiers: .control, timestamp: 2.15)
      == .focusLeft)
  #expect(resolver.resolve(key: "j", modifiers: .control, timestamp: 2.2) == .focusDown)
  #expect(resolver.resolve(key: "k", modifiers: .control, timestamp: 2.3) == .focusUp)
  #expect(resolver.resolve(key: "l", modifiers: .control, timestamp: 2.4) == .focusRight)
  #expect(
    resolver.resolve(key: "", keyCode: 37, modifiers: .control, timestamp: 2.5) == .focusRight)
  #expect(
    resolver.resolve(key: "\u{0f}", keyCode: 31, modifiers: .control, timestamp: 3) == .jumpBackward
  )
  #expect(
    resolver.resolve(key: "\t", keyCode: 34, modifiers: .control, timestamp: 3) == .jumpForward)
  #expect(resolver.resolve(key: "\u{1b}", keyCode: 53, timestamp: 3) == .cancelPortal)
  #expect(resolver.resolve(key: "p", timestamp: 3) == .capturePortal)
  #expect(resolver.resolve(key: "m", timestamp: 3) == nil)
  #expect(resolver.resolve(key: ":", timestamp: 4) == .showCommandPalette)
  #expect(resolver.resolve(key: "/", timestamp: 5) == .findForward)
  #expect(resolver.resolve(key: "?", timestamp: 5) == .findBackward)
  #expect(resolver.resolve(key: "n", timestamp: 5) == .findNext)
  #expect(resolver.resolve(key: "N", timestamp: 5) == .findPrevious)
  #expect(resolver.resolve(key: "?", timestamp: 5) != .help)
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
  let repository = PortalRepository(fileURL: directory.appendingPathComponent("marks.json"))
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
  let url = directory.appendingPathComponent("marks.json")
  try Data("not json".utf8).write(to: url)
  let repository = PortalRepository(fileURL: url)
  #expect(throws: PortalRepositoryError.corruptFile) { try repository.load() }
  #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func repositoryMigratesLegacyStorage() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let currentURL = directory.appendingPathComponent("portals-v1.json")
  let legacyURL = directory.appendingPathComponent("marks-v1.json")
  let portal = Portal(source: anchor(), destination: anchor(page: 4))
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .secondsSince1970
  // Old on-disk payload used a "marks" array key.
  var object = try #require(
    JSONSerialization.jsonObject(with: encoder.encode(PortalFile(portals: [portal])))
      as? [String: Any])
  object["marks"] = object.removeValue(forKey: "portals")
  try JSONSerialization.data(withJSONObject: object).write(to: legacyURL)

  let repository = PortalRepository(fileURL: currentURL, legacyFileURL: legacyURL)
  #expect(try repository.load() == [portal])
  #expect(FileManager.default.fileExists(atPath: currentURL.path))
  #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
  #expect(try repository.load() == [portal])
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

@Test func jumpListTraversesFromHomeAndAcrossDocuments() {
  var jumps = JumpList()
  let first = location(fingerprint: "a", path: "/tmp/a.pdf", page: 2)
  let second = location(fingerprint: "b", path: "/tmp/b.pdf", page: 5)
  jumps.recordBeforeJump(first)
  jumps.recordBeforeJump(second)

  // :q leaves the document, then Ctrl+O / Ctrl+I round-trips through home.
  #expect(jumps.goBackward(from: .home) == second)
  #expect(jumps.forward.last?.isHome == true)
  #expect(jumps.goForward(from: second)?.isHome == true)
  #expect(jumps.goBackward(from: .home) == second)

  #expect(jumps.goBackward(from: second) == first)
  #expect(jumps.forward.last == second)
  #expect(jumps.goForward(from: first) == second)
  #expect(jumps.goForward(from: second)?.isHome == true)
}

@Test func jumpListKeepsHistoryThroughHomeAndNewDocuments() {
  var jumps = JumpList()
  let first = location(fingerprint: "pending:/tmp/a.pdf", path: "/tmp/a.pdf", page: 1)
  jumps.recordBeforeJump(.home)
  jumps.recordBeforeJump(first)
  jumps.recordBeforeJump(.home)
  let second = location(fingerprint: "pending:/tmp/b.pdf", path: "/tmp/b.pdf", page: 3)
  jumps.recordBeforeJump(second)

  jumps.rewriteFingerprint(from: "pending:/tmp/a.pdf", to: "sha-a", path: "/tmp/a.pdf")
  jumps.rewriteFingerprint(from: "pending:/tmp/b.pdf", to: "sha-b", path: "/tmp/b.pdf")

  #expect(jumps.goBackward(from: .home)?.documentFingerprint == "sha-b")
  #expect(jumps.goBackward(from: location(fingerprint: "sha-b", path: "/tmp/b.pdf", page: 3))?.isHome == true)
  #expect(
    jumps.goBackward(from: .home)
      == location(fingerprint: "sha-a", path: "/tmp/a.pdf", page: 1))

  // Re-recording the current home must not wipe forward history.
  let forwardCount = jumps.forward.count
  jumps.recordBeforeJump(.home)
  #expect(jumps.forward.count == forwardCount)
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

@Test func markGeometryHandlesCropOriginsAndClamping() {
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

@Test func replacingMissingDocumentPathPreservesMarkIdentity() {
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

@Test func markEndpointResolutionIsBidirectional() {
  let portal = Portal(source: anchor(page: 2), destination: anchor(page: 9))
  #expect(portal.oppositeAnchor(from: .source).pageIndex == 9)
  #expect(portal.oppositeAnchor(from: .destination).pageIndex == 2)
  #expect(portal.anchor(at: .destination).pageIndex == 9)
}

@Test func marksIndexIncludesAndSortsCurrentDocumentSourcesOnly() {
  let sameDocument = Portal(source: anchor(page: 4, x: 0.5), destination: anchor(page: 1))
  let outgoing = Portal(
    source: anchor(page: 3), destination: anchor(fingerprint: "other", page: 8))
  let unrelated = Portal(
    source: anchor(fingerprint: "other", page: 0),
    destination: anchor(fingerprint: "third", page: 0))
  let entries = PortalsIndex.entries(
    for: "document", portals: [sameDocument, outgoing, unrelated])
  #expect(entries.map(\.anchor.pageIndex) == [3, 4])
  #expect(entries.map(\.endpoint) == [.source, .source])
  #expect(entries.allSatisfy { $0.anchor.documentFingerprint == "document" })
}

@Test func commandCatalogSupportsExactAliasesAndFuzzyOrdering() {
  #expect(CommandCatalog.exact(":portals")?.action == .showPortals)
  #expect(CommandCatalog.exact(":marks")?.action == .showPortals)
  #expect(CommandCatalog.exact("e")?.action == .open)
  #expect(CommandCatalog.exact(":vsplit")?.action == .verticalSplit)
  #expect(CommandCatalog.exact("vs")?.action == .verticalSplit)
  #expect(CommandCatalog.exact(":hsplit")?.action == .horizontalSplit)
  #expect(CommandCatalog.exact("sp")?.action == .horizontalSplit)
  #expect(CommandCatalog.exact(":q")?.action == .closeSplit)
  #expect(CommandCatalog.exact("quit")?.action == .closeSplit)
  #expect(CommandCatalog.exact(":qa")?.action == .quit)
  #expect(CommandCatalog.exact("quitall")?.action == .quit)
  #expect(CommandCatalog.exact(":home")?.action == .showHome)
  #expect(CommandCatalog.exact("recents")?.action == .showHome)
  #expect(CommandCatalog.exact(":help")?.action == .help)
  #expect(CommandCatalog.exact("help")?.action == .help)
  #expect(CommandCatalog.exact("find")?.action == .findForward)
  #expect(CommandCatalog.matches("portals").first?.name == "portals")
  #expect(CommandCatalog.matches("marks").first?.name == "portals")
  #expect(CommandCatalog.matches("no command named this").isEmpty)
  #expect(CommandCatalog.matches("").count == CommandCatalog.commands.count)
}

@Test func commandCatalogParsesGoToPageExCommands() {
  #expect(CommandCatalog.pageNumber(from: "12") == 12)
  #expect(CommandCatalog.pageNumber(from: ":12") == 12)
  #expect(CommandCatalog.pageNumber(from: "  :42  ") == 42)
  #expect(CommandCatalog.pageNumber(from: "0") == nil)
  #expect(CommandCatalog.pageNumber(from: "-3") == nil)
  #expect(CommandCatalog.pageNumber(from: "12a") == nil)
  #expect(CommandCatalog.pageNumber(from: "marks") == nil)
  #expect(CommandCatalog.exact(":12")?.action == .goToPage(12))
  #expect(CommandCatalog.exact("7")?.action == .goToPage(7))
  #expect(CommandCatalog.matches("12") == [CommandCatalog.goToPageCommand(12)])
  #expect(CommandCatalog.matches(":99").first?.action == .goToPage(99))
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

@Test @MainActor func recentsRepositoryRecordsAndDeduplicates() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let pdfURL = directory.appendingPathComponent("paper.pdf")
  try Data("%PDF-1.4".utf8).write(to: pdfURL)
  let repository = RecentsRepository(
    fileURL: directory.appendingPathComponent("recents.json"), capacity: 2)
  var recents: [RecentDocument] = []
  let first = RecentDocument(
    fingerprint: "a", path: pdfURL.path, name: "paper.pdf", pageCount: 3)
  try repository.record(first, into: &recents)
  let secondPath = directory.appendingPathComponent("other.pdf")
  try Data("%PDF-1.4".utf8).write(to: secondPath)
  try repository.record(
    RecentDocument(fingerprint: "b", path: secondPath.path, name: "other.pdf", pageCount: 1),
    into: &recents)
  try repository.record(
    RecentDocument(fingerprint: "a", path: pdfURL.path, name: "paper.pdf", pageCount: 3),
    into: &recents)
  #expect(recents.map(\.fingerprint) == ["a", "b"])
  #expect(try repository.load().map(\.fingerprint) == ["a", "b"])
}

@Test func recentsSeedFromReadingPositions() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let pdfURL = directory.appendingPathComponent("seed.pdf")
  try Data("%PDF-1.4".utf8).write(to: pdfURL)
  let positions = [
    "fp": ReadingPosition(
      location: JumpLocation(
        documentFingerprint: "fp",
        documentPath: pdfURL.path,
        pageIndex: 2,
        viewportCenter: NormalizedPoint(x: 0.5, y: 0.5),
        scaleFactor: 1
      ))
  ]
  let seeded = RecentsRepository.seeded(from: positions)
  #expect(seeded.count == 1)
  #expect(seeded[0].fingerprint == "fp")
  #expect(seeded[0].name == "seed.pdf")
}

@Test func launchArgumentsParseGotoFlags() {
  let parsed = LaunchArguments.parse([
    "Lattice",
    "/tmp/rising_sea.pdf",
    "--page-index",
    "14",
    "--rect",
    "0.12,0.40,0.76,0.18",
    "--label",
    "3.1.3",
  ])
  #expect(parsed.pdfURL?.path == "/tmp/rising_sea.pdf")
  #expect(parsed.goto?.pageIndex == 14)
  #expect(parsed.goto?.topY == 0.40)
  #expect(parsed.goto?.label == "3.1.3")
}

@Test func launchArgumentsRejectInvalidRect() {
  let parsed = LaunchArguments.parse([
    "Lattice",
    "/tmp/book.pdf",
    "--page-index",
    "1",
    "--rect",
    "bad",
  ])
  #expect(parsed.pdfURL?.path == "/tmp/book.pdf")
  #expect(parsed.goto == nil)
}
