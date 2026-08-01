import Foundation

public struct NormalizedRect: Codable, Equatable, Sendable {
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
}

public struct PortalAnchor: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let documentFingerprint: String
  public let pageIndex: Int
  public let quotedText: String
  public let pageBounds: [NormalizedRect]

  public init(
    id: UUID = UUID(),
    documentFingerprint: String,
    pageIndex: Int,
    quotedText: String,
    pageBounds: [NormalizedRect]
  ) {
    self.id = id
    self.documentFingerprint = documentFingerprint
    self.pageIndex = pageIndex
    self.quotedText = quotedText
    self.pageBounds = pageBounds
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
    self.createdAt = createdAt
  }
}
