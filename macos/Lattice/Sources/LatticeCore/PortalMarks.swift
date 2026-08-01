import Foundation

public struct PortalMark: Equatable, Identifiable, Sendable {
  public let portalID: UUID
  public let endpoint: PortalEndpoint
  public let anchor: PortalAnchor
  public let counterpart: PortalAnchor
  public let createdAt: Date

  public var id: String { "\(portalID.uuidString)-\(endpoint.rawValue)" }

  public init(
    portalID: UUID,
    endpoint: PortalEndpoint,
    anchor: PortalAnchor,
    counterpart: PortalAnchor,
    createdAt: Date
  ) {
    self.portalID = portalID
    self.endpoint = endpoint
    self.anchor = anchor
    self.counterpart = counterpart
    self.createdAt = createdAt
  }
}

public enum PortalMarks {
  public static func entries(for fingerprint: String, portals: [Portal]) -> [PortalMark] {
    portals.flatMap { portal -> [PortalMark] in
      var entries: [PortalMark] = []
      if portal.source.documentFingerprint == fingerprint {
        entries.append(
          PortalMark(
            portalID: portal.id,
            endpoint: .source,
            anchor: portal.source,
            counterpart: portal.destination,
            createdAt: portal.createdAt
          ))
      }
      return entries
    }.sorted {
      if $0.anchor.pageIndex != $1.anchor.pageIndex {
        return $0.anchor.pageIndex < $1.anchor.pageIndex
      }
      if $0.anchor.bounds.y != $1.anchor.bounds.y {
        return $0.anchor.bounds.y < $1.anchor.bounds.y
      }
      if $0.endpoint != $1.endpoint {
        return $0.endpoint.rawValue < $1.endpoint.rawValue
      }
      return $0.createdAt < $1.createdAt
    }
  }
}
