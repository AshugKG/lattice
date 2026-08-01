import AppKit
import LatticeCore
import PDFKit

@MainActor
final class PortalOverlayView: NSView {
  weak var pdfView: PDFView?
  var anchors: [PortalAnchor] = [] { didSet { needsDisplay = true } }
  var documentFingerprint: String? { didSet { needsDisplay = true } }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let pdfView, let document = pdfView.document, let fingerprint = documentFingerprint else {
      return
    }

    NSColor.systemYellow.withAlphaComponent(0.18).setFill()
    NSColor.systemYellow.withAlphaComponent(0.75).setStroke()
    for anchor in anchors where anchor.documentFingerprint == fingerprint {
      guard let page = document.page(at: anchor.pageIndex) else { continue }
      let pageBox = page.bounds(for: .cropBox)
      for normalized in anchor.pageBounds {
        let pageRect = NSRect(
          x: pageBox.minX + pageBox.width * normalized.x,
          y: pageBox.minY + pageBox.height * normalized.y,
          width: pageBox.width * normalized.width,
          height: pageBox.height * normalized.height
        )
        let pdfRect = pdfView.convert(pageRect, from: page)
        let overlayRect = convert(pdfRect, from: pdfView)
        let path = NSBezierPath(roundedRect: overlayRect, xRadius: 3, yRadius: 3)
        path.fill()
        path.lineWidth = 1.5
        path.stroke()
      }
    }
  }

  func anchor(from selection: PDFSelection, descriptor: DocumentDescriptor) -> PortalAnchor? {
    guard let page = selection.pages.first,
      let pageIndex = pdfView?.document?.index(for: page)
    else { return nil }
    let pageBox = page.bounds(for: .cropBox)
    guard pageBox.width > 0, pageBox.height > 0 else { return nil }
    let lineBounds = selection.selectionsByLine()
      .filter { $0.pages.contains(page) }
      .map { $0.bounds(for: page) }
      .filter { !$0.isEmpty && !$0.isNull }
    let bounds = (lineBounds.isEmpty ? [selection.bounds(for: page)] : lineBounds).map {
      NormalizedRect(
        x: ($0.minX - pageBox.minX) / pageBox.width,
        y: ($0.minY - pageBox.minY) / pageBox.height,
        width: $0.width / pageBox.width,
        height: $0.height / pageBox.height
      )
    }
    return PortalAnchor(
      documentFingerprint: descriptor.fingerprint,
      pageIndex: pageIndex,
      quotedText: selection.string ?? "",
      pageBounds: bounds
    )
  }
}
