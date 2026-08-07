import Foundation

public enum PortalRepositoryError: Error, Equatable {
  case unsupportedSchema(Int)
  case corruptFile
}

@MainActor
public final class PortalRepository {
  public let fileURL: URL
  private let marksLegacyURL: URL?
  private let portalsLegacyURL: URL?

  public init(fileURL: URL? = nil, legacyFileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    if fileURL == nil {
      let base = Self.supportDirectory
      self.marksLegacyURL = legacyFileURL ?? base.appendingPathComponent("marks-v1.json")
      self.portalsLegacyURL = base.appendingPathComponent("portals-v1.json")
    } else {
      self.marksLegacyURL = legacyFileURL
      self.portalsLegacyURL = nil
    }
  }

  public func load() throws -> [Portal] {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      return try decodePortals(at: fileURL)
    }

    // Prefer older marks-v1.json, then any prior portals-v1.json / portals key files.
    for candidate in [marksLegacyURL, portalsLegacyURL].compactMap({ $0 })
    where FileManager.default.fileExists(atPath: candidate.path) {
      let portals = try decodePortals(at: candidate)
      try save(portals)
      if candidate != fileURL {
        try? FileManager.default.removeItem(at: candidate)
      }
      return portals
    }
    return []
  }

  private func decodePortals(at url: URL) throws -> [Portal] {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      let data = try Data(contentsOf: url)
      // Current schema (portals or marks key).
      if let file = try? decoder.decode(PortalFile.self, from: data) {
        guard file.schemaVersion == PortalFile.currentSchemaVersion else {
          throw PortalRepositoryError.unsupportedSchema(file.schemaVersion)
        }
        return file.portals.map { $0.resolvingDocumentPaths() }
      }
      // Very old portal-named payload.
      let legacy = try decoder.decode(LegacyPortalFile.self, from: data)
      guard legacy.schemaVersion == PortalFile.currentSchemaVersion else {
        throw PortalRepositoryError.unsupportedSchema(legacy.schemaVersion)
      }
      return legacy.portals.map { $0.resolvingDocumentPaths() }
    } catch let error as PortalRepositoryError {
      throw error
    } catch {
      let backup = url.deletingLastPathComponent().appendingPathComponent(
        "portals-corrupt-\(Int(Date().timeIntervalSince1970)).json")
      try? FileManager.default.moveItem(at: url, to: backup)
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

  private static var supportDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Lattice", isDirectory: true)
  }

  private static func defaultFileURL() -> URL {
    supportDirectory.appendingPathComponent("portals-v1.json")
  }
}

private struct LegacyPortalFile: Decodable {
  let schemaVersion: Int
  let portals: [Portal]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case portals
  }
}
