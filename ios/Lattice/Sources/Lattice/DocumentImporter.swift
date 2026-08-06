import Foundation

enum DocumentImporter {
  static var pdfsDirectory: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("PDFs", isDirectory: true)
  }

  /// Copies a picked PDF into the app sandbox and returns the local URL.
  static func importPDF(from sourceURL: URL) throws -> URL {
    let accessing = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessing { sourceURL.stopAccessingSecurityScopedResource() }
    }

    try FileManager.default.createDirectory(at: pdfsDirectory, withIntermediateDirectories: true)

    let baseName = sourceURL.deletingPathExtension().lastPathComponent
    var destination = pdfsDirectory.appendingPathComponent("\(baseName).pdf")
    var suffix = 1
    while FileManager.default.fileExists(atPath: destination.path) {
      if fileContentsEqual(sourceURL, destination) { return destination }
      destination = pdfsDirectory.appendingPathComponent("\(baseName)-\(suffix).pdf")
      suffix += 1
    }

    try FileManager.default.copyItem(at: sourceURL, to: destination)
    return destination
  }

  private static func fileContentsEqual(_ a: URL, _ b: URL) -> Bool {
    guard
      let atrA = try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      let atrB = try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      atrA == atrB
    else { return false }
    guard let dataA = try? Data(contentsOf: a), let dataB = try? Data(contentsOf: b) else {
      return false
    }
    return dataA == dataB
  }
}
