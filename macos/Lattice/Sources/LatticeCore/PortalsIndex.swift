import Foundation

public struct PortalListEntry: Equatable, Identifiable, Sendable {
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

public enum PortalsIndex {
  public static func entries(for fingerprint: String, portals: [Portal]) -> [PortalListEntry] {
    portals.flatMap { portal -> [PortalListEntry] in
      var entries: [PortalListEntry] = []
      if portal.source.documentFingerprint == fingerprint {
        entries.append(
          PortalListEntry(
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
