import AppKit
import LatticeCore
import PDFKit

enum MarkCaptureMode: Equatable {
  case inactive
  case source
  case destination
}

struct CapturedMarkBox {
  let pageIndex: Int
  let bounds: NormalizedRect
  let quotedText: String?
}

struct MarkInteractionTarget {
  let mark: Mark
  let endpoint: MarkEndpoint
  let rect: NSRect
}

@MainActor
final class MarkOverlayView: NSView {
  weak var pdfView: PDFView?
  var marks: [Mark] = [] { didSet { needsDisplay = true } }
  var documentFingerprint: String? { didSet { needsDisplay = true } }
  var captureMode: MarkCaptureMode = .inactive {
    didSet {
      dragStart = nil
      dragCurrent = nil
      window?.invalidateCursorRects(for: self)
      needsDisplay = true
    }
  }
  var arrivalAnchorID: UUID? { didSet { needsDisplay = true } }
  var onBoxCaptured: ((CapturedMarkBox) -> Void)?
  var onActivateMark: ((MarkInteractionTarget) -> Void)?
  var onDeleteMark: ((UUID) -> Void)?
  var onHoverMark: ((MarkInteractionTarget?) -> Void)?

  private var dragStart: NSPoint?
  private var dragCurrent: NSPoint?
  private var dragPage: PDFPage?
  private var pressedMarkID: UUID?
  private var pressedEndpoint: MarkEndpoint?
  private var pressedMarkPoint: NSPoint?
  private var hoveredMarkID: UUID?
  private var hoveredEndpoint: MarkEndpoint?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  func viewportDidChange() {
    hoveredMarkID = nil
    hoveredEndpoint = nil
    onHoverMark?(nil)
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
      for mark in marks {
        if let rect = destinationMarkerRect(for: mark) {
          addCursorRect(rect, cursor: .pointingHand)
        }
      }
    } else {
      addCursorRect(bounds, cursor: .crosshair)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01 else { return nil }
    if captureMode != .inactive { return self }
    return interactionTarget(at: point) == nil ? nil : self
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
    let target = interactionTarget(at: point)
    pressedMarkID = target?.mark.id
    pressedEndpoint = target?.endpoint
    pressedMarkPoint = point
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
        pressedMarkID = nil
        pressedEndpoint = nil
        pressedMarkPoint = nil
      }
      if let id = pressedMarkID,
        let endpoint = pressedEndpoint,
        let start = pressedMarkPoint,
        hypot(point.x - start.x, point.y - start.y) <= 6,
        let mark = marks.first(where: { $0.id == id }),
        let rect = interactionRect(for: mark, endpoint: endpoint)
      {
        onActivateMark?(MarkInteractionTarget(mark: mark, endpoint: endpoint, rect: rect))
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
    let target = interactionTarget(at: point)
    guard target?.mark.id != hoveredMarkID || target?.endpoint != hoveredEndpoint else {
      return
    }
    hoveredMarkID = target?.mark.id
    hoveredEndpoint = target?.endpoint
    onHoverMark?(target)
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    hoveredMarkID = nil
    hoveredEndpoint = nil
    onHoverMark?(nil)
    needsDisplay = true
  }

  override func rightMouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let mark = sourceMark(at: point) else {
      super.rightMouseDown(with: event)
      return
    }
    let menu = NSMenu()
    let delete = NSMenuItem(
      title: "Delete Mark", action: #selector(deleteMark(_:)), keyEquivalent: "")
    delete.representedObject = mark.id
    delete.target = self
    menu.addItem(delete)
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  @objc private func deleteMark(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    onDeleteMark?(id)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard documentFingerprint != nil else { return }

    for mark in marks {
      if mark.destination.documentFingerprint == documentFingerprint {
        drawDestinationMarker(for: mark)
      }
      if mark.source.documentFingerprint == documentFingerprint {
        drawSource(
          mark.source,
          hovered: mark.id == hoveredMarkID && hoveredEndpoint == .source)
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

  private func drawSource(_ anchor: MarkAnchor, hovered: Bool) {
    guard let rect = overlayRect(for: anchor) else { return }
    let isArrival = anchor.id == arrivalAnchorID
    let color = NSColor.controlAccentColor
    color.withAlphaComponent(isArrival ? 0.28 : (hovered ? 0.2 : 0.08)).setFill()
    color.withAlphaComponent(0.9).setStroke()
    let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
    path.lineWidth = isArrival ? 3 : 2
    path.fill()
    path.stroke()
  }

  private func drawDestinationMarker(for mark: Mark) {
    guard let markerRect = destinationMarkerRect(for: mark) else { return }
    let pageNumber = "\(mark.source.pageIndex + 1)"
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    let textSize = (pageNumber as NSString).size(withAttributes: [.font: font])
    let isArrival = mark.destination.id == arrivalAnchorID
    let isHovered = mark.id == hoveredMarkID && hoveredEndpoint == .destination
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

  private func visibleSourceRects() -> [(Mark, NSRect)] {
    marks.compactMap { mark in
      guard mark.source.documentFingerprint == documentFingerprint,
        let rect = overlayRect(for: mark.source)
      else { return nil }
      return (mark, rect)
    }
  }

  private func sourceMark(at point: NSPoint) -> Mark? {
    visibleSourceRects()
      .filter { $0.1.insetBy(dx: -3, dy: -3).contains(point) }
      .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
  }

  private func sourceRect(for mark: Mark) -> NSRect? {
    guard mark.source.documentFingerprint == documentFingerprint else { return nil }
    return overlayRect(for: mark.source)
  }

  private func destinationMarkerRect(for mark: Mark) -> NSRect? {
    guard mark.destination.documentFingerprint == documentFingerprint,
      let destinationRect = overlayRect(for: mark.destination),
      let pdfView,
      let page = pdfView.document?.page(at: mark.destination.pageIndex)
    else { return nil }
    let pageRect = overlayRect(for: page)
    let pageNumber = "\(mark.source.pageIndex + 1)"
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

  private func interactionTarget(at point: NSPoint) -> MarkInteractionTarget? {
    if let mark = sourceMark(at: point), let rect = sourceRect(for: mark) {
      return MarkInteractionTarget(mark: mark, endpoint: .source, rect: rect)
    }
    for mark in marks.reversed() {
      if let rect = destinationMarkerRect(for: mark), rect.contains(point) {
        return MarkInteractionTarget(mark: mark, endpoint: .destination, rect: rect)
      }
    }
    return nil
  }

  private func interactionRect(for mark: Mark, endpoint: MarkEndpoint) -> NSRect? {
    endpoint == .source ? sourceRect(for: mark) : destinationMarkerRect(for: mark)
  }

  private func overlayRect(for anchor: MarkAnchor) -> NSRect? {
    guard let pdfView, let document = pdfView.document,
      let page = document.page(at: anchor.pageIndex)
    else { return nil }
    let box = page.bounds(for: .cropBox)
    guard let pageRect = MarkGeometry.pageRect(for: anchor.bounds, in: box) else { return nil }
    return convert(pdfView.convert(pageRect, from: page), from: pdfView)
  }

  private func overlayRect(for page: PDFPage) -> NSRect {
    guard let pdfView else { return .zero }
    return convert(pdfView.convert(page.bounds(for: .cropBox), from: page), from: pdfView)
  }

  private func capturedBox(from overlayRect: NSRect, page: PDFPage) -> CapturedMarkBox? {
    guard let pdfView, let document = pdfView.document else { return nil }
    let viewRect = pdfView.convert(overlayRect, from: self)
    let pageRect = pdfView.convert(viewRect, to: page).intersection(page.bounds(for: .cropBox))
    let box = page.bounds(for: .cropBox)
    guard let normalized = MarkGeometry.normalized(rect: pageRect, in: box) else { return nil }
    let quote = page.selection(for: pageRect)?.string?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    return CapturedMarkBox(
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
