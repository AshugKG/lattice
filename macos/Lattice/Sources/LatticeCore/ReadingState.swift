import Foundation

public struct ReadingPosition: Codable, Equatable, Sendable {
  public let location: JumpLocation
  public let updatedAt: Date

  public init(location: JumpLocation, updatedAt: Date = Date()) {
    self.location = location
    let milliseconds = (updatedAt.timeIntervalSince1970 * 1_000).rounded(.down)
    self.updatedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
  }
}

public struct ReadingStateFile: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public var positions: [String: ReadingPosition]

  public init(
    schemaVersion: Int = currentSchemaVersion,
    positions: [String: ReadingPosition]
  ) {
    self.schemaVersion = schemaVersion
    self.positions = positions
  }
}

public enum ReadingStateRepositoryError: Error, Equatable {
  case unsupportedSchema(Int)
  case corruptFile
}

@MainActor
public final class ReadingStateRepository {
  public let fileURL: URL

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
  }

  public func load() throws -> [String: ReadingPosition] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      let file = try decoder.decode(ReadingStateFile.self, from: Data(contentsOf: fileURL))
      guard file.schemaVersion == ReadingStateFile.currentSchemaVersion else {
        throw ReadingStateRepositoryError.unsupportedSchema(file.schemaVersion)
      }
      return file.positions
    } catch let error as ReadingStateRepositoryError {
      throw error
    } catch {
      let backup = fileURL.deletingLastPathComponent().appendingPathComponent(
        "reading-state-corrupt-\(Int(Date().timeIntervalSince1970)).json")
      try? FileManager.default.moveItem(at: fileURL, to: backup)
      throw ReadingStateRepositoryError.corruptFile
    }
  }

  public func save(_ positions: [String: ReadingPosition]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode(ReadingStateFile(positions: positions)).write(to: fileURL, options: .atomic)
  }

  private static func defaultFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Lattice", isDirectory: true)
      .appendingPathComponent("reading-state-v1.json")
  }
}
