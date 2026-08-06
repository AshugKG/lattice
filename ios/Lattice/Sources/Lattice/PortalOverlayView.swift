import LatticeCore
import PDFKit
import UIKit

enum PortalCaptureMode: Equatable {
  case inactive
  case source
  case sourcePlaced
  case destination

  var allowsDrawing: Bool {
    self == .source || self == .destination
  }

  var isActive: Bool { self != .inactive }
}

struct CapturedPortalBox {
  let pageIndex: Int
  let bounds: NormalizedRect
  let quotedText: String?
}

struct PortalInteractionTarget {
  let portal: Portal
  let endpoint: PortalEndpoint
}

/// Owns per-page overlay views so portal rects are transformed by PDFKit with each page.
/// Drawing new portals happens on `PortalCaptureView` (full-bleed); these views only paint/hit-test.
final class PortalOverlayController: NSObject, PDFPageOverlayViewProvider, @unchecked Sendable {
  var portals: [Portal] = []
  var documentFingerprint: String?
  var captureMode: PortalCaptureMode = .inactive
  var arrivalAnchorID: UUID?

  var onBoxCaptured: ((CapturedPortalBox) -> Void)?
  var onActivatePortal: ((PortalInteractionTarget) -> Void)?
  var onDeletePortal: ((UUID) -> Void)?

  weak var pdfView: PDFView?
  private var pageViews: [Int: PortalPageOverlayView] = [:]
  private let lock = NSLock()

  func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    let pageIndex = view.document?.index(for: page) ?? -1
    lock.lock()
    defer { lock.unlock() }

    if pageIndex >= 0, let existing = pageViews[pageIndex] {
      existing.page = page
      existing.pageIndex = pageIndex
      existing.sync(from: self)
      return existing
    }

    let overlay = PortalPageOverlayView()
    overlay.page = page
    overlay.pageIndex = pageIndex
    overlay.controller = self
    overlay.sync(from: self)
    if pageIndex >= 0 {
      pageViews[pageIndex] = overlay
    }
    return overlay
  }

  func pdfView(
    _ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage
  ) {
    _ = overlayView
    _ = page
  }

  func refreshAll() {
    lock.lock()
    let views = Array(pageViews.values)
    lock.unlock()
    for view in views {
      view.sync(from: self)
      view.setNeedsDisplay()
    }
  }

  func resetPages() {
    lock.lock()
    pageViews.removeAll()
    lock.unlock()
  }

  func viewportDidChange() {}
}

/// Drawn on a PDFKit page overlay — scrolls and zooms with the page like ink on the PDF.
final class PortalPageOverlayView: UIView {
  weak var page: PDFPage?
  weak var controller: PortalOverlayController?
  var pageIndex: Int = -1

  private var portals: [Portal] = []
  private var documentFingerprint: String?
  private var captureMode: PortalCaptureMode = .inactive
  private var arrivalAnchorID: UUID?
  private let deleteBadgeSize: CGFloat = 22

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw
    isMultipleTouchEnabled = false
    // Taps/drags go through PortalChromeView; this layer only paints with the page.
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { nil }

  func sync(from controller: PortalOverlayController) {
    portals = controller.portals
    documentFingerprint = controller.documentFingerprint
    captureMode = controller.captureMode
    arrivalAnchorID = controller.arrivalAnchorID
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext(),
      let documentFingerprint
    else { return }

    let pageIndex = resolvedPageIndex()
    guard pageIndex >= 0 else { return }

    for portal in portals {
      if portal.destination.documentFingerprint == documentFingerprint,
        portal.destination.pageIndex == pageIndex
      {
        drawDestination(portal.destination, in: context)
      }
      if portal.source.documentFingerprint == documentFingerprint,
        portal.source.pageIndex == pageIndex
      {
        drawSource(portal.source, in: context)
        drawDeleteBadge(for: portal.source, in: context)
      }
    }
  }

  private func resolvedPageIndex() -> Int {
    if pageIndex >= 0 { return pageIndex }
    guard let page, let document = controller?.pdfView?.document else { return -1 }
    return document.index(for: page)
  }

  private func drawSource(_ anchor: PortalAnchor, in context: CGContext) {
    guard let rect = viewRect(for: anchor) else { return }
    let isArrival = anchor.id == arrivalAnchorID
    let color = UIColor.tintColor
    context.setFillColor(color.withAlphaComponent(isArrival ? 0.28 : 0.08).cgColor)
    context.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
    context.setLineWidth(isArrival ? 3 : 2)
    let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
    context.addPath(path.cgPath)
    context.drawPath(using: .fillStroke)
  }

  private func drawDestination(_ anchor: PortalAnchor, in context: CGContext) {
    guard let rect = viewRect(for: anchor) else { return }
    let isArrival = anchor.id == arrivalAnchorID
    let color = UIColor.tintColor
    context.setFillColor(color.withAlphaComponent(isArrival ? 0.16 : 0.04).cgColor)
    context.setStrokeColor(color.withAlphaComponent(isArrival ? 0.65 : 0.45).cgColor)
    context.setLineWidth(isArrival ? 2 : 1.5)
    let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
    context.addPath(path.cgPath)
    context.drawPath(using: .fillStroke)
  }

  private func drawDeleteBadge(for anchor: PortalAnchor, in context: CGContext) {
    guard let badge = deleteBadgeRect(for: anchor) else { return }
    context.setFillColor(UIColor.systemRed.cgColor)
    context.fillEllipse(in: badge)

    context.setStrokeColor(UIColor.white.cgColor)
    context.setLineWidth(2)
    context.setLineCap(.round)
    let inset: CGFloat = 6
    context.move(to: CGPoint(x: badge.minX + inset, y: badge.minY + inset))
    context.addLine(to: CGPoint(x: badge.maxX - inset, y: badge.maxY - inset))
    context.move(to: CGPoint(x: badge.maxX - inset, y: badge.minY + inset))
    context.addLine(to: CGPoint(x: badge.minX + inset, y: badge.maxY - inset))
    context.strokePath()
  }

  private func deleteBadgeRect(for anchor: PortalAnchor) -> CGRect? {
    guard let rect = viewRect(for: anchor) else { return nil }
    let size = deleteBadgeSize
    return CGRect(
      x: rect.maxX - size * 0.45,
      y: rect.minY - size * 0.55,
      width: size,
      height: size
    )
  }

  private func viewRect(for anchor: PortalAnchor) -> CGRect? {
    guard let page else { return nil }
    let box = page.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0, bounds.width > 0, bounds.height > 0,
      let pageRect = PortalGeometry.pageRect(for: anchor.bounds, in: box)
    else { return nil }

    let x = (pageRect.minX - box.minX) / box.width * bounds.width
    let width = pageRect.width / box.width * bounds.width
    let yFromTop = (box.maxY - pageRect.maxY) / box.height * bounds.height
    let height = pageRect.height / box.height * bounds.height
    return CGRect(x: x, y: yFromTop, width: width, height: height)
  }
}
