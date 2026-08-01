import CryptoKit
import Foundation

public struct DocumentDescriptor: Equatable, Sendable {
  public let fingerprint: String
  public let url: URL
  public let name: String
  public let pageCount: Int

  public init(fingerprint: String, url: URL, name: String, pageCount: Int) {
    self.fingerprint = fingerprint
    self.url = url
    self.name = name
    self.pageCount = pageCount
  }
}

public enum DocumentFingerprint {
  public static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
