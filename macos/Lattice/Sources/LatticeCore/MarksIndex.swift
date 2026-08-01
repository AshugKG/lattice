import Foundation

public struct MarkListEntry: Equatable, Identifiable, Sendable {
  public let markID: UUID
  public let endpoint: MarkEndpoint
  public let anchor: MarkAnchor
  public let counterpart: MarkAnchor
  public let createdAt: Date

  public var id: String { "\(markID.uuidString)-\(endpoint.rawValue)" }

  public init(
    markID: UUID,
    endpoint: MarkEndpoint,
    anchor: MarkAnchor,
    counterpart: MarkAnchor,
    createdAt: Date
  ) {
    self.markID = markID
    self.endpoint = endpoint
    self.anchor = anchor
    self.counterpart = counterpart
    self.createdAt = createdAt
  }
}

public enum MarksIndex {
  public static func entries(for fingerprint: String, marks: [Mark]) -> [MarkListEntry] {
    marks.flatMap { mark -> [MarkListEntry] in
      var entries: [MarkListEntry] = []
      if mark.source.documentFingerprint == fingerprint {
        entries.append(
          MarkListEntry(
            markID: mark.id,
            endpoint: .source,
            anchor: mark.source,
            counterpart: mark.destination,
            createdAt: mark.createdAt
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
