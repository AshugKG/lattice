import LatticeCore
import PDFKit
import UIKit

enum PortalCaptureMode: Equatable {
  case inactive
  /// Drag to place the source box.
  case source
  /// Source placed; waiting for a second Portal button press.
  case sourcePlaced
  /// Drag to place the destination box.
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

@MainActor
final class PortalOverlayView: UIView {
  weak var pdfView: PDFView?
  var portals: [Portal] = [] { didSet { setNeedsDisplay() } }
  var documentFingerprint: String? { didSet { setNeedsDisplay() } }
  var captureMode: PortalCaptureMode = .inactive {
    didSet {
      dragStart = nil
      dragCurrent = nil
      dragPage = nil
      isUserInteractionEnabled = true
      setNeedsDisplay()
    }
  }
  var arrivalAnchorID: UUID? { didSet { setNeedsDisplay() } }

  var onBoxCaptured: ((CapturedPortalBox) -> Void)?
  var onActivatePortal: ((PortalInteractionTarget) -> Void)?
  var onDeletePortal: ((UUID) -> Void)?

  private var dragStart: CGPoint?
  private var dragCurrent: CGPoint?
  private var dragPage: PDFPage?
  private let deleteBadgeSize: CGFloat = 22

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.maximumNumberOfTouches = 1
    addGestureRecognizer(pan)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) { nil }

  func viewportDidChange() {
    setNeedsDisplay()
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
    if captureMode.allowsDrawing { return self }
    if deleteTarget(at: point) != nil { return self }
    if interactionTarget(at: point) != nil { return self }
    return nil
  }

  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext(), documentFingerprint != nil else { return }

    for portal in portals {
      if portal.destination.documentFingerprint == documentFingerprint {
        drawDestination(portal.destination, in: context)
      }
      if portal.source.documentFingerprint == documentFingerprint {
        drawSource(portal.source, in: context)
        drawDeleteBadge(for: portal.source, in: context)
      }
    }

    if let start = dragStart, let current = dragCurrent {
      let dragRect = standardizedRect(from: start, to: current)
      let color = UIColor.tintColor
      context.setFillColor(color.withAlphaComponent(0.14).cgColor)
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(2)
      context.fill(dragRect)
      context.stroke(dragRect)
    }
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    guard captureMode.allowsDrawing, let pdfView else { return }
    let point = gesture.location(in: self)

    switch gesture.state {
    case .began:
      let pdfPoint = pdfView.convert(point, from: self)
      guard let page = pdfView.page(for: pdfPoint, nearest: false) else { return }
      dragPage = page
      dragStart = point
      dragCurrent = point
      setNeedsDisplay()
    case .changed:
      guard let dragPage else { return }
      dragCurrent = clamp(point, to: overlayRect(for: dragPage))
      setNeedsDisplay()
    case .ended, .cancelled:
      defer {
        dragStart = nil
        dragCurrent = nil
        dragPage = nil
        setNeedsDisplay()
      }
      guard let start = dragStart, let current = dragCurrent, let page = dragPage else { return }
      let boxRect = standardizedRect(from: start, to: current).intersection(overlayRect(for: page))
      guard boxRect.width >= 8, boxRect.height >= 8,
        let captured = capturedBox(from: boxRect, page: page)
      else { return }
      onBoxCaptured?(captured)
    default:
      break
    }
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard captureMode == .inactive, gesture.state == .ended else { return }
    let point = gesture.location(in: self)
    if let portalID = deleteTarget(at: point) {
      onDeletePortal?(portalID)
      return
    }
    guard let target = interactionTarget(at: point) else { return }
    onActivatePortal?(target)
  }

  private func deleteTarget(at point: CGPoint) -> UUID? {
    guard let documentFingerprint else { return nil }
    for portal in portals.reversed() {
      guard portal.source.documentFingerprint == documentFingerprint,
        let badge = deleteBadgeRect(for: portal.source),
        badge.insetBy(dx: -4, dy: -4).contains(point)
      else { continue }
      return portal.id
    }
    return nil
  }

  private func interactionTarget(at point: CGPoint) -> PortalInteractionTarget? {
    guard let documentFingerprint else { return nil }
    let padding: CGFloat = 10
    for portal in portals.reversed() {
      if portal.source.documentFingerprint == documentFingerprint,
        let rect = overlayRect(for: portal.source)?.insetBy(dx: -padding, dy: -padding),
        rect.contains(point)
      {
        return PortalInteractionTarget(portal: portal, endpoint: .source)
      }
      if portal.destination.documentFingerprint == documentFingerprint,
        let rect = overlayRect(for: portal.destination)?.insetBy(dx: -padding, dy: -padding),
        rect.contains(point)
      {
        return PortalInteractionTarget(portal: portal, endpoint: .destination)
      }
    }
    return nil
  }

  private func drawSource(_ anchor: PortalAnchor, in context: CGContext) {
    guard let rect = overlayRect(for: anchor) else { return }
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
    guard let rect = overlayRect(for: anchor) else { return }
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
    guard let rect = overlayRect(for: anchor) else { return nil }
    let size = deleteBadgeSize
    return CGRect(
      x: rect.maxX - size * 0.45,
      y: rect.minY - size * 0.55,
      width: size,
      height: size
    )
  }

  private func overlayRect(for anchor: PortalAnchor) -> CGRect? {
    guard let pdfView, let document = pdfView.document,
      let page = document.page(at: anchor.pageIndex)
    else { return nil }
    let box = page.bounds(for: .cropBox)
    guard let pageRect = PortalGeometry.pageRect(for: anchor.bounds, in: box) else { return nil }
    return convert(pdfView.convert(pageRect, from: page), from: pdfView)
  }

  private func overlayRect(for page: PDFPage) -> CGRect {
    guard let pdfView else { return .zero }
    return convert(pdfView.convert(page.bounds(for: .cropBox), from: page), from: pdfView)
  }

  private func capturedBox(from overlayRect: CGRect, page: PDFPage) -> CapturedPortalBox? {
    guard let pdfView, let document = pdfView.document else { return nil }
    let viewRect = pdfView.convert(overlayRect, from: self)
    let pageRect = pdfView.convert(viewRect, to: page).intersection(page.bounds(for: .cropBox))
    let box = page.bounds(for: .cropBox)
    guard let normalized = PortalGeometry.normalized(rect: pageRect, in: box) else { return nil }
    let quote = page.selection(for: pageRect)?.string?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    return CapturedPortalBox(
      pageIndex: document.index(for: page),
      bounds: normalized,
      quotedText: quote?.isEmpty == true ? nil : quote
    )
  }

  private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
    CGPoint(
      x: min(max(point.x, rect.minX), rect.maxX),
      y: min(max(point.y, rect.minY), rect.maxY)
    )
  }

  private func standardizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
    CGRect(
      x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }
}
