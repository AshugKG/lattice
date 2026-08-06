@preconcurrency import AppKit
import CoreGraphics
import LatticeCore
import PDFKit

enum PortalPreviewResult {
  case image(NSImage)
  case unavailable(String)
}

final class PortalPreviewRenderer: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.ashugkg.lattice.mark-preview", qos: .userInitiated)
  private let cache = NSCache<NSString, NSImage>()
  private var verifiedFiles: Set<String> = []

  @MainActor
  func render(
    anchor: PortalAnchor,
    key: PreviewCacheKey,
    completion: @escaping @MainActor (PortalPreviewResult) -> Void
  ) {
    let cacheKey = keyString(key)
    if let image = cache.object(forKey: cacheKey as NSString) {
      completion(.image(image))
      return
    }

    queue.async { [weak self] in
      guard let self else { return }
      let result = self.makePreview(anchor: anchor, key: key)
      if case .image(let image) = result {
        self.cache.setObject(image, forKey: cacheKey as NSString)
      }
      Task { @MainActor in completion(result) }
    }
  }

  private func makePreview(anchor: PortalAnchor, key: PreviewCacheKey) -> PortalPreviewResult {
    let url = URL(fileURLWithPath: anchor.documentPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .unavailable("Destination PDF is missing")
    }

    let verificationKey = "\(anchor.documentFingerprint)|\(url.path)"
    if !verifiedFiles.contains(verificationKey) {
      guard (try? DocumentFingerprint.sha256(of: url)) == anchor.documentFingerprint else {
        return .unavailable("Destination PDF has changed")
      }
      verifiedFiles.insert(verificationKey)
    }

    guard let document = PDFDocument(url: url),
      let page = document.page(at: anchor.pageIndex)
    else {
      return .unavailable("Destination page is unavailable")
    }

    let pageBox = page.bounds(for: .cropBox)
    guard let snippet = PortalGeometry.pageRect(for: anchor.bounds, in: pageBox), !snippet.isEmpty
    else {
      return .unavailable("Destination box is invalid")
    }

    let backingScale = max(1, CGFloat(key.backingScale) / 100)
    let maximumPixels = CGSize(width: 480 * backingScale, height: 320 * backingScale)
    let imageScale = min(maximumPixels.width / snippet.width, maximumPixels.height / snippet.height)
    // `PDFPage.draw(with:to:)` remaps the full box into the context (ignoring a
    // crop CTM) and is unreliable in raw bitmap contexts. Thumbnail the page,
    // then crop in upright image space.
    let maxPageDimension: CGFloat = 4096
    let pageRenderScale = min(
      imageScale,
      maxPageDimension / max(pageBox.width, pageBox.height, 1)
    )
    let thumbSize = NSSize(
      width: max(1, pageBox.width * pageRenderScale),
      height: max(1, pageBox.height * pageRenderScale)
    )
    let thumbnail = page.thumbnail(of: thumbSize, for: .cropBox)
    var proposed = NSRect(origin: .zero, size: thumbnail.size)
    guard let pageImage = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    else {
      return .unavailable("Preview could not be rendered")
    }

    let scaleX = CGFloat(pageImage.width) / pageBox.width
    let scaleY = CGFloat(pageImage.height) / pageBox.height
    let cropInImage = CGRect(
      x: (snippet.minX - pageBox.minX) * scaleX,
      y: (pageBox.maxY - snippet.maxY) * scaleY,
      width: snippet.width * scaleX,
      height: snippet.height * scaleY
    ).integral.intersection(
      CGRect(x: 0, y: 0, width: pageImage.width, height: pageImage.height)
    )
    guard !cropInImage.isNull, !cropInImage.isEmpty,
      let cgImage = pageImage.cropping(to: cropInImage)
    else {
      return .unavailable("Preview could not be rendered")
    }

    return .image(
      NSImage(
        cgImage: cgImage,
        size: NSSize(
          width: CGFloat(cgImage.width) / backingScale,
          height: CGFloat(cgImage.height) / backingScale)
      ))
  }

  private func keyString(_ key: PreviewCacheKey) -> String {
    "\(key.fingerprint)|\(key.pageIndex)|\(key.bounds.x)|\(key.bounds.y)|\(key.bounds.width)|\(key.bounds.height)|\(key.backingScale)|\(key.appearance)"
  }
}
