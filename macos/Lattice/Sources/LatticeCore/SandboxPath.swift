import Foundation

/// Recovers stored file paths when the sandbox container they lived in changes identity.
///
/// iOS hands each install of an app a fresh container UUID, so a stored path like
/// `.../Application/<UUID>/Documents/PDFs/book.pdf` stops resolving after a device restore or
/// a development reinstall even though the file itself came along. Without this, every recent,
/// reading position, and portal pointing into the container is silently dropped.
public enum SandboxPath {
  /// The stored path, or its equivalent inside the current container when the original is gone.
  ///
  /// Rebasing applies only when the stored file is missing *and* the rebased one exists, so a
  /// path that merely happens to contain a `Documents` component is never redirected.
  public static func resolved(
    _ path: String,
    documentsDirectory: URL? = nil,
    fileManager: FileManager = .default
  ) -> String {
    guard !path.isEmpty, !fileManager.fileExists(atPath: path) else { return path }
    guard
      let documents = documentsDirectory
        ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
      let rebased = rebased(path, onto: documents),
      fileManager.fileExists(atPath: rebased)
    else { return path }
    return rebased
  }

  private static func rebased(_ path: String, onto documents: URL) -> String? {
    let components = URL(fileURLWithPath: path).pathComponents
    guard let documentsIndex = components.lastIndex(of: documents.lastPathComponent),
      documentsIndex + 1 < components.count
    else { return nil }
    return components[(documentsIndex + 1)...]
      .reduce(documents) { $0.appendingPathComponent($1) }
      .path
  }
}
