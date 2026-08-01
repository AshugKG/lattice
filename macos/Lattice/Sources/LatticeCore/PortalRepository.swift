import Foundation

public enum PortalRepositoryError: Error, Equatable {
  case unsupportedSchema(Int)
  case corruptFile
}

@MainActor
public final class PortalRepository {
  public let fileURL: URL

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
  }

  public func load() throws -> [Portal] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      let file = try decoder.decode(PortalFile.self, from: Data(contentsOf: fileURL))
      guard file.schemaVersion == PortalFile.currentSchemaVersion else {
        throw PortalRepositoryError.unsupportedSchema(file.schemaVersion)
      }
      return file.portals
    } catch let error as PortalRepositoryError {
      throw error
    } catch {
      let backup = fileURL.deletingLastPathComponent().appendingPathComponent(
        "portals-corrupt-\(Int(Date().timeIntervalSince1970)).json")
      try? FileManager.default.moveItem(at: fileURL, to: backup)
      throw PortalRepositoryError.corruptFile
    }
  }

  public func save(_ portals: [Portal]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode(PortalFile(portals: portals)).write(to: fileURL, options: .atomic)
  }

  private static func defaultFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Lattice", isDirectory: true)
      .appendingPathComponent("portals-v1.json")
  }
}
