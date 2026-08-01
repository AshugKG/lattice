import Foundation

public enum MarkRepositoryError: Error, Equatable {
  case unsupportedSchema(Int)
  case corruptFile
}

@MainActor
public final class MarkRepository {
  public let fileURL: URL
  private let legacyFileURL: URL?

  public init(fileURL: URL? = nil, legacyFileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    self.legacyFileURL =
      fileURL == nil ? (legacyFileURL ?? Self.defaultLegacyFileURL()) : legacyFileURL
  }

  public func load() throws -> [Mark] {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      return try decodeMarks(at: fileURL, legacy: false)
    }
    guard let legacyFileURL,
      FileManager.default.fileExists(atPath: legacyFileURL.path)
    else { return [] }

    let marks = try decodeMarks(at: legacyFileURL, legacy: true)
    try save(marks)
    try FileManager.default.removeItem(at: legacyFileURL)
    return marks
  }

  private func decodeMarks(at url: URL, legacy: Bool) throws -> [Mark] {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      let data = try Data(contentsOf: url)
      let schemaVersion: Int
      let marks: [Mark]
      if legacy {
        let file = try decoder.decode(LegacyMarkFile.self, from: data)
        schemaVersion = file.schemaVersion
        marks = file.marks
      } else {
        let file = try decoder.decode(MarkFile.self, from: data)
        schemaVersion = file.schemaVersion
        marks = file.marks
      }
      guard schemaVersion == MarkFile.currentSchemaVersion else {
        throw MarkRepositoryError.unsupportedSchema(schemaVersion)
      }
      return marks
    } catch let error as MarkRepositoryError {
      throw error
    } catch {
      let backup = url.deletingLastPathComponent().appendingPathComponent(
        "marks-corrupt-\(Int(Date().timeIntervalSince1970)).json")
      try? FileManager.default.moveItem(at: url, to: backup)
      throw MarkRepositoryError.corruptFile
    }
  }

  public func save(_ marks: [Mark]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode(MarkFile(marks: marks)).write(to: fileURL, options: .atomic)
  }

  private static func defaultFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Lattice", isDirectory: true)
      .appendingPathComponent("marks-v1.json")
  }

  private static func defaultLegacyFileURL() -> URL {
    defaultFileURL().deletingLastPathComponent().appendingPathComponent("portals-v1.json")
  }
}

private struct LegacyMarkFile: Decodable {
  let schemaVersion: Int
  let marks: [Mark]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case marks = "portals"
  }
}
