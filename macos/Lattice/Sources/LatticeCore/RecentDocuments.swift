import Foundation

public struct RecentDocument: Codable, Equatable, Sendable, Identifiable {
  public var id: String { fingerprint }

  public let fingerprint: String
  public let path: String
  public let name: String
  public let pageCount: Int
  public let lastOpenedAt: Date

  public init(
    fingerprint: String,
    path: String,
    name: String,
    pageCount: Int,
    lastOpenedAt: Date = Date()
  ) {
    self.fingerprint = fingerprint
    self.path = path
    self.name = name
    self.pageCount = pageCount
    let milliseconds = (lastOpenedAt.timeIntervalSince1970 * 1_000).rounded(.down)
    self.lastOpenedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
  }

  public var url: URL { URL(fileURLWithPath: path) }

  public var exists: Bool {
    FileManager.default.fileExists(atPath: path)
  }
}

public struct RecentsFile: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public var recents: [RecentDocument]

  public init(
    schemaVersion: Int = currentSchemaVersion,
    recents: [RecentDocument]
  ) {
    self.schemaVersion = schemaVersion
    self.recents = recents
  }
}

public enum RecentsRepositoryError: Error, Equatable {
  case unsupportedSchema(Int)
  case corruptFile
}

@MainActor
public final class RecentsRepository {
  public let fileURL: URL
  public let capacity: Int

  public init(fileURL: URL? = nil, capacity: Int = 24) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.capacity = max(1, capacity)
  }

  public func load() throws -> [RecentDocument] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      let file = try decoder.decode(RecentsFile.self, from: Data(contentsOf: fileURL))
      guard file.schemaVersion == RecentsFile.currentSchemaVersion else {
        throw RecentsRepositoryError.unsupportedSchema(file.schemaVersion)
      }
      return file.recents.filter(\.exists)
    } catch let error as RecentsRepositoryError {
      throw error
    } catch {
      let backup = fileURL.deletingLastPathComponent().appendingPathComponent(
        "recents-corrupt-\(Int(Date().timeIntervalSince1970)).json")
      try? FileManager.default.moveItem(at: fileURL, to: backup)
      throw RecentsRepositoryError.corruptFile
    }
  }

  public func save(_ recents: [RecentDocument]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    let trimmed = Array(recents.filter(\.exists).prefix(capacity))
    try encoder.encode(RecentsFile(recents: trimmed)).write(to: fileURL, options: .atomic)
  }

  public func record(_ document: RecentDocument, into recents: inout [RecentDocument]) throws {
    recents.removeAll { $0.fingerprint == document.fingerprint || $0.path == document.path }
    recents.insert(document, at: 0)
    try save(recents)
  }

  nonisolated public static func seeded(
    from positions: [String: ReadingPosition],
    capacity: Int = 24
  ) -> [RecentDocument] {
    positions.values
      .sorted { $0.updatedAt > $1.updatedAt }
      .compactMap { position -> RecentDocument? in
        let path = position.location.documentPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        return RecentDocument(
          fingerprint: position.location.documentFingerprint,
          path: path,
          name: url.lastPathComponent,
          pageCount: max(1, position.location.pageIndex + 1),
          lastOpenedAt: position.updatedAt
        )
      }
      .reduce(into: [RecentDocument]()) { partial, recent in
        guard
          !partial.contains(where: {
            $0.fingerprint == recent.fingerprint || $0.path == recent.path
          })
        else { return }
        partial.append(recent)
      }
      .prefix(capacity)
      .map { $0 }
  }

  private static func defaultFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Lattice", isDirectory: true)
      .appendingPathComponent("recents-v1.json")
  }
}
