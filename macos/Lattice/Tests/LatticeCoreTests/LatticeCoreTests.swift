import Foundation
import Testing

@testable import LatticeCore

@Test func vimChordAndNavigationShortcutsResolve() {
  var resolver = ShortcutResolver()
  #expect(resolver.resolve(key: "g", timestamp: 1.0) == nil)
  #expect(resolver.resolve(key: "g", timestamp: 1.5) == .documentStart)
  #expect(resolver.resolve(key: "G", timestamp: 2.0) == .documentEnd)
  #expect(resolver.resolve(key: "d", modifiers: .control, timestamp: 2.0) == .halfDown)
}

@Test func portalAnchorRoundTripsThroughJSON() throws {
  let anchor = PortalAnchor(
    documentFingerprint: "abc",
    pageIndex: 4,
    quotedText: "proper morphism",
    pageBounds: [NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)]
  )
  let data = try JSONEncoder().encode(anchor)
  #expect(try JSONDecoder().decode(PortalAnchor.self, from: data) == anchor)
}

@Test func portalRoundTripsThroughJSON() throws {
  let source = PortalAnchor(
    documentFingerprint: "source",
    pageIndex: 1,
    quotedText: "source text",
    pageBounds: [NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)]
  )
  let destination = PortalAnchor(
    documentFingerprint: "destination",
    pageIndex: 2,
    quotedText: "destination text",
    pageBounds: [NormalizedRect(x: 0.4, y: 0.5, width: 0.2, height: 0.04)]
  )
  let portal = Portal(source: source, destination: destination)
  let data = try JSONEncoder().encode(portal)
  #expect(try JSONDecoder().decode(Portal.self, from: data) == portal)
}

@Test func portalShortcutResolves() {
  var resolver = ShortcutResolver()
  #expect(resolver.resolve(key: "p", timestamp: 1.0) == .capturePortal)
}

@Test func documentFingerprintIsStable() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("lattice".utf8).write(to: url)
  #expect(try DocumentFingerprint.sha256(of: url) == DocumentFingerprint.sha256(of: url))
}
