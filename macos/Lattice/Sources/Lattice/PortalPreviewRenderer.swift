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
    label: "com.ashugkg.lattice.portal-preview", qos: .userInitiated)
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
    guard let snippet = PortalGeometry.pageRect(for: anchor.bounds, in: pageBox) else {
      return .unavailable("Destination box is invalid")
    }

    let backingScale = max(1, CGFloat(key.backingScale) / 100)
    let maximumPixels = CGSize(width: 480 * backingScale, height: 320 * backingScale)
    let imageScale = min(maximumPixels.width / snippet.width, maximumPixels.height / snippet.height)
    let pixelWidth = max(1, Int((snippet.width * imageScale).rounded(.up)))
    let pixelHeight = max(1, Int((snippet.height * imageScale).rounded(.up)))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return .unavailable("Preview could not be rendered")
    }

    let dark = key.appearance == "dark"
    context.setFillColor(
      dark
        ? CGColor(gray: 0.10, alpha: 1)
        : CGColor(gray: 1, alpha: 1)
    )
    context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    context.scaleBy(x: imageScale, y: imageScale)
    context.translateBy(x: -snippet.minX, y: -snippet.minY)
    page.draw(with: .cropBox, to: context)
    guard let cgImage = context.makeImage() else {
      return .unavailable("Preview could not be rendered")
    }
    return .image(
      NSImage(
        cgImage: cgImage,
        size: NSSize(
          width: CGFloat(pixelWidth) / backingScale, height: CGFloat(pixelHeight) / backingScale)
      ))
  }

  private func keyString(_ key: PreviewCacheKey) -> String {
    "\(key.fingerprint)|\(key.pageIndex)|\(key.bounds.x)|\(key.bounds.y)|\(key.bounds.width)|\(key.bounds.height)|\(key.backingScale)|\(key.appearance)"
  }
}
