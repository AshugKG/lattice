import AppKit
import LatticeCore
import PDFKit

enum PortalCaptureMode: Equatable {
  case inactive
  case source
  case destination
}

struct CapturedPortalBox {
  let pageIndex: Int
  let bounds: NormalizedRect
  let quotedText: String?
}

enum PortalEndpoint: Equatable {
  case source
  case destination
}

struct PortalHoverTarget {
  let portal: Portal
  let endpoint: PortalEndpoint
  let rect: NSRect
}

@MainActor
final class PortalOverlayView: NSView {
  weak var pdfView: PDFView?
  var portals: [Portal] = [] { didSet { needsDisplay = true } }
  var documentFingerprint: String? { didSet { needsDisplay = true } }
  var captureMode: PortalCaptureMode = .inactive {
    didSet {
      dragStart = nil
      dragCurrent = nil
      window?.invalidateCursorRects(for: self)
      needsDisplay = true
    }
  }
  var arrivalAnchorID: UUID? { didSet { needsDisplay = true } }
  var onBoxCaptured: ((CapturedPortalBox) -> Void)?
  var onActivatePortal: ((Portal) -> Void)?
  var onDeletePortal: ((UUID) -> Void)?
  var onHoverPortal: ((PortalHoverTarget?) -> Void)?

  private var dragStart: NSPoint?
  private var dragCurrent: NSPoint?
  private var dragPage: PDFPage?
  private var pressedPortalID: UUID?
  private var pressedPortalPoint: NSPoint?
  private var hoveredPortalID: UUID?
  private var hoveredEndpoint: PortalEndpoint?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  func viewportDidChange() {
    hoveredPortalID = nil
    hoveredEndpoint = nil
    onHoverPortal?(nil)
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
        owner: self,
        userInfo: nil
      ))
  }

  override func resetCursorRects() {
    if captureMode == .inactive {
      for (_, rect) in visibleSourceRects() { addCursorRect(rect, cursor: .pointingHand) }
      for portal in portals {
        if let rect = destinationMarkerRect(for: portal) { addCursorRect(rect, cursor: .arrow) }
      }
    } else {
      addCursorRect(bounds, cursor: .crosshair)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01 else { return nil }
    if captureMode != .inactive { return self }
    return hoverTarget(at: point) == nil ? nil : self
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if captureMode != .inactive {
      guard let pdfView else { return }
      let pdfPoint = pdfView.convert(point, from: self)
      guard let page = pdfView.page(for: pdfPoint, nearest: false) else {
        NSSound.beep()
        return
      }
      dragPage = page
      dragStart = point
      dragCurrent = point
      needsDisplay = true
      return
    }
    pressedPortalID = sourcePortal(at: point)?.id
    pressedPortalPoint = point
  }

  override func mouseDragged(with event: NSEvent) {
    guard captureMode != .inactive, dragStart != nil, let dragPage else { return }
    let point = convert(event.locationInWindow, from: nil)
    dragCurrent = clamp(point, to: overlayRect(for: dragPage))
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if captureMode == .inactive {
      defer {
        pressedPortalID = nil
        pressedPortalPoint = nil
      }
      if let id = pressedPortalID,
        let start = pressedPortalPoint,
        hypot(point.x - start.x, point.y - start.y) <= 6,
        let portal = portals.first(where: { $0.id == id })
      {
        onActivatePortal?(portal)
      }
      return
    }

    defer {
      dragStart = nil
      dragCurrent = nil
      dragPage = nil
      needsDisplay = true
    }
    guard let start = dragStart, let current = dragCurrent, let page = dragPage else { return }
    let rect = standardizedRect(from: start, to: current).intersection(overlayRect(for: page))
    guard rect.width >= 8, rect.height >= 8, let captured = capturedBox(from: rect, page: page)
    else {
      NSSound.beep()
      return
    }
    onBoxCaptured?(captured)
  }

  override func mouseMoved(with event: NSEvent) {
    guard captureMode == .inactive else { return }
    let point = convert(event.locationInWindow, from: nil)
    let target = hoverTarget(at: point)
    guard target?.portal.id != hoveredPortalID || target?.endpoint != hoveredEndpoint else {
      return
    }
    hoveredPortalID = target?.portal.id
    hoveredEndpoint = target?.endpoint
    onHoverPortal?(target)
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    hoveredPortalID = nil
    hoveredEndpoint = nil
    onHoverPortal?(nil)
    needsDisplay = true
  }

  override func rightMouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let portal = sourcePortal(at: point) else {
      super.rightMouseDown(with: event)
      return
    }
    let menu = NSMenu()
    let delete = NSMenuItem(
      title: "Delete Portal", action: #selector(deletePortal(_:)), keyEquivalent: "")
    delete.representedObject = portal.id
    delete.target = self
    menu.addItem(delete)
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  @objc private func deletePortal(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    onDeletePortal?(id)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard documentFingerprint != nil else { return }

    for portal in portals {
      if portal.destination.documentFingerprint == documentFingerprint {
        drawDestinationMarker(for: portal)
      }
      if portal.source.documentFingerprint == documentFingerprint {
        drawSource(
          portal.source,
          hovered: portal.id == hoveredPortalID && hoveredEndpoint == .source)
      }
    }

    if let start = dragStart, let current = dragCurrent {
      let rect = standardizedRect(from: start, to: current)
      NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
      NSColor.controlAccentColor.setStroke()
      let path = NSBezierPath(rect: rect)
      path.lineWidth = 2
      path.fill()
      path.stroke()
    }
  }

  private func drawSource(_ anchor: PortalAnchor, hovered: Bool) {
    guard let rect = overlayRect(for: anchor) else { return }
    let color = NSColor.controlAccentColor
    color.withAlphaComponent(hovered ? 0.2 : 0.08).setFill()
    color.withAlphaComponent(0.9).setStroke()
    let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
    path.lineWidth = 2
    path.fill()
    path.stroke()
  }

  private func drawDestinationMarker(for portal: Portal) {
    guard let markerRect = destinationMarkerRect(for: portal) else { return }
    let pageNumber = "\(portal.source.pageIndex + 1)"
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    let textSize = (pageNumber as NSString).size(withAttributes: [.font: font])
    let isArrival = portal.destination.id == arrivalAnchorID
    let isHovered = portal.id == hoveredPortalID && hoveredEndpoint == .destination
    let color = isArrival || isHovered ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
    color.withAlphaComponent(isArrival ? 0.95 : (isHovered ? 0.88 : 0.78)).setFill()
    let markerPath = NSBezierPath(roundedRect: markerRect, xRadius: 6, yRadius: 6)
    markerPath.fill()

    if let icon = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil) {
      icon.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))?.draw(
        in: NSRect(x: markerRect.minX + 6, y: markerRect.midY - 5, width: 10, height: 10))
    }
    let textRect = NSRect(
      x: markerRect.minX + 19,
      y: markerRect.midY - textSize.height / 2,
      width: textSize.width,
      height: textSize.height
    )
    (pageNumber as NSString).draw(
      in: textRect,
      withAttributes: [
        .font: font,
        .foregroundColor: NSColor.white,
      ])
  }

  private func visibleSourceRects() -> [(Portal, NSRect)] {
    portals.compactMap { portal in
      guard portal.source.documentFingerprint == documentFingerprint,
        let rect = overlayRect(for: portal.source)
      else { return nil }
      return (portal, rect)
    }
  }

  private func sourcePortal(at point: NSPoint) -> Portal? {
    visibleSourceRects()
      .filter { $0.1.insetBy(dx: -3, dy: -3).contains(point) }
      .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
  }

  private func sourceRect(for portal: Portal) -> NSRect? {
    guard portal.source.documentFingerprint == documentFingerprint else { return nil }
    return overlayRect(for: portal.source)
  }

  private func destinationMarkerRect(for portal: Portal) -> NSRect? {
    guard portal.destination.documentFingerprint == documentFingerprint,
      let destinationRect = overlayRect(for: portal.destination),
      let pdfView,
      let page = pdfView.document?.page(at: portal.destination.pageIndex)
    else { return nil }
    let pageRect = overlayRect(for: page)
    let pageNumber = "\(portal.source.pageIndex + 1)"
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    let textSize = (pageNumber as NSString).size(withAttributes: [.font: font])
    let markerSize = NSSize(width: max(34, textSize.width + 23), height: 20)
    return NSRect(
      x: pageRect.maxX - markerSize.width - 7,
      y: destinationRect.midY - markerSize.height / 2,
      width: markerSize.width,
      height: markerSize.height
    )
  }

  private func hoverTarget(at point: NSPoint) -> PortalHoverTarget? {
    if let portal = sourcePortal(at: point), let rect = sourceRect(for: portal) {
      return PortalHoverTarget(portal: portal, endpoint: .source, rect: rect)
    }
    for portal in portals.reversed() {
      if let rect = destinationMarkerRect(for: portal), rect.contains(point) {
        return PortalHoverTarget(portal: portal, endpoint: .destination, rect: rect)
      }
    }
    return nil
  }

  private func overlayRect(for anchor: PortalAnchor) -> NSRect? {
    guard let pdfView, let document = pdfView.document,
      let page = document.page(at: anchor.pageIndex)
    else { return nil }
    let box = page.bounds(for: .cropBox)
    guard let pageRect = PortalGeometry.pageRect(for: anchor.bounds, in: box) else { return nil }
    return convert(pdfView.convert(pageRect, from: page), from: pdfView)
  }

  private func overlayRect(for page: PDFPage) -> NSRect {
    guard let pdfView else { return .zero }
    return convert(pdfView.convert(page.bounds(for: .cropBox), from: page), from: pdfView)
  }

  private func capturedBox(from overlayRect: NSRect, page: PDFPage) -> CapturedPortalBox? {
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

  private func clamp(_ point: NSPoint, to rect: NSRect) -> NSPoint {
    NSPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
  }

  private func standardizedRect(from a: NSPoint, to b: NSPoint) -> NSRect {
    NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }
}
