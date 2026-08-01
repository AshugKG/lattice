import Foundation

public struct NormalizedPoint: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
      && x >= 0 && y >= 0 && x + width <= 1.000_001 && y + height <= 1.000_001
  }
}

public enum PortalEndpoint: String, Codable, Equatable, Hashable, Sendable {
  case source
  case destination
}

public struct PortalAnchor: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let documentFingerprint: String
  public let documentPath: String
  public let pageIndex: Int
  public let bounds: NormalizedRect
  public let quotedText: String?

  public init(
    id: UUID = UUID(),
    documentFingerprint: String,
    documentPath: String,
    pageIndex: Int,
    bounds: NormalizedRect,
    quotedText: String? = nil
  ) {
    self.id = id
    self.documentFingerprint = documentFingerprint
    self.documentPath = documentPath
    self.pageIndex = pageIndex
    self.bounds = bounds
    self.quotedText = quotedText
  }

  public func replacingDocumentPath(_ path: String) -> PortalAnchor {
    PortalAnchor(
      id: id,
      documentFingerprint: documentFingerprint,
      documentPath: path,
      pageIndex: pageIndex,
      bounds: bounds,
      quotedText: quotedText
    )
  }
}

public struct Portal: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let source: PortalAnchor
  public let destination: PortalAnchor
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    source: PortalAnchor,
    destination: PortalAnchor,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.source = source
    self.destination = destination
    let milliseconds = (createdAt.timeIntervalSince1970 * 1_000).rounded(.down)
    self.createdAt = Date(timeIntervalSince1970: milliseconds / 1_000)
  }

  public func replacingDocumentPath(for fingerprint: String, with path: String) -> Portal {
    Portal(
      id: id,
      source: source.documentFingerprint == fingerprint
        ? source.replacingDocumentPath(path) : source,
      destination: destination.documentFingerprint == fingerprint
        ? destination.replacingDocumentPath(path) : destination,
      createdAt: createdAt
    )
  }

  public func anchor(at endpoint: PortalEndpoint) -> PortalAnchor {
    endpoint == .source ? source : destination
  }

  public func oppositeAnchor(from endpoint: PortalEndpoint) -> PortalAnchor {
    endpoint == .source ? destination : source
  }
}

public struct PortalFile: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public var portals: [Portal]

  public init(schemaVersion: Int = currentSchemaVersion, portals: [Portal]) {
    self.schemaVersion = schemaVersion
    self.portals = portals
  }
}

public struct PreviewCacheKey: Hashable, Sendable {
  public let fingerprint: String
  public let pageIndex: Int
  public let bounds: NormalizedRect
  public let backingScale: Int
  public let appearance: String

  public init(
    fingerprint: String,
    pageIndex: Int,
    bounds: NormalizedRect,
    backingScale: Double,
    appearance: String
  ) {
    self.fingerprint = fingerprint
    self.pageIndex = pageIndex
    self.bounds = bounds
    self.backingScale = Int((backingScale * 100).rounded())
    self.appearance = appearance
  }
}
