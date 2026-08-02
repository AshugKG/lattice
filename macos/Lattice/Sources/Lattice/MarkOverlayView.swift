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

private struct MarkInteractionKey: Hashable {
  let markID: UUID
  let endpoint: MarkEndpoint
}

@MainActor
private final class MarkHitTargetView: NSView {
  let key: MarkInteractionKey
  var onActivate: (() -> Void)?
  var onDelete: (() -> Void)?

  private var isPressed = false

  init(key: MarkInteractionKey) {
    self.key = key
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  override var acceptsFirstResponder: Bool { false }

  override func mouseExited(with event: NSEvent) {
    isPressed = false
  }

  override func mouseDown(with event: NSEvent) {
    isPressed = event.modifierFlags.contains(.control)
  }

  override func mouseUp(with event: NSEvent) {
    defer { isPressed = false }
    guard isPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onActivate?()
  }

  override func rightMouseDown(with event: NSEvent) {
    if event.modifierFlags.contains(.control) {
      onActivate?()
      return
    }
    guard key.endpoint == .source else {
      super.rightMouseDown(with: event)
      return
    }
    let menu = NSMenu()
    let delete = NSMenuItem(title: "Delete Mark", action: #selector(deleteMark), keyEquivalent: "")
    delete.target = self
    menu.addItem(delete)
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  @objc private func deleteMark() {
    onDelete?()
  }
}

@MainActor
final class MarkOverlayView: NSView {
  weak var pdfView: PDFView?
  var marks: [Mark] = [] { didSet { rebuildInteractionViews() } }
  var documentFingerprint: String? { didSet { rebuildInteractionViews() } }
  var captureMode: MarkCaptureMode = .inactive {
    didSet {
      dragStart = nil
      dragCurrent = nil
      rebuildInteractionViews()
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
  private var hoveredMarkID: UUID?
  private var hoveredEndpoint: MarkEndpoint?
  private var interactionViews: [MarkInteractionKey: MarkHitTargetView] = [:]
  private var hoverTrackingArea: NSTrackingArea?
  private var flagsMonitor: Any?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  func viewportDidChange() {
    layoutInteractionViews()
  }

  func refreshInteractions() {
    rebuildInteractionViews()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopFlagsMonitor()
    guard window != nil else { return }
    flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      let controlHeld = event.modifierFlags.contains(.control)
      Task { @MainActor [weak self] in
        self?.updateModifierHoverForCurrentPointer(controlHeld: controlHeld)
      }
      return event
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let hoverTrackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(hoverTrackingArea)
    self.hoverTrackingArea = hoverTrackingArea
  }

  override func resetCursorRects() {
    if captureMode != .inactive {
      addCursorRect(bounds, cursor: .crosshair)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01 else { return nil }
    if captureMode != .inactive { return self }
    let event = NSApp.currentEvent
    let isControlClick = event?.modifierFlags.contains(.control) == true
    let isSecondaryClick = event?.type == .rightMouseDown || event?.type == .rightMouseUp
    guard isControlClick || isSecondaryClick else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func mouseDown(with event: NSEvent) {
    guard captureMode != .inactive, let pdfView else { return }
    let point = convert(event.locationInWindow, from: nil)
    let pdfPoint = pdfView.convert(point, from: self)
    guard let page = pdfView.page(for: pdfPoint, nearest: false) else {
      NSSound.beep()
      return
    }
    dragPage = page
    dragStart = point
    dragCurrent = point
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard captureMode != .inactive, dragStart != nil, let dragPage else { return }
    let point = convert(event.locationInWindow, from: nil)
    dragCurrent = clamp(point, to: overlayRect(for: dragPage))
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard captureMode != .inactive else { return }

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
    let point = convert(event.locationInWindow, from: nil)
    updateModifierHover(
      at: point,
      controlHeld: event.modifierFlags.contains(.control)
    )
  }

  override func mouseExited(with event: NSEvent) {
    clearHoveredMark()
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

  private func interactionRect(for mark: Mark, endpoint: MarkEndpoint) -> NSRect? {
    endpoint == .source ? sourceRect(for: mark) : destinationMarkerRect(for: mark)
  }

  private func rebuildInteractionViews() {
    for view in interactionViews.values {
      view.removeFromSuperview()
    }
    interactionViews.removeAll(keepingCapacity: true)
    hoveredMarkID = nil
    hoveredEndpoint = nil
    onHoverMark?(nil)

    guard captureMode == .inactive, let documentFingerprint else {
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
      return
    }

    for mark in marks {
      if mark.source.documentFingerprint == documentFingerprint {
        addInteractionView(for: mark.id, endpoint: .source)
      }
      if mark.destination.documentFingerprint == documentFingerprint {
        addInteractionView(for: mark.id, endpoint: .destination)
      }
    }
    layoutInteractionViews()
  }

  private func addInteractionView(for markID: UUID, endpoint: MarkEndpoint) {
    let key = MarkInteractionKey(markID: markID, endpoint: endpoint)
    let view = MarkHitTargetView(key: key)
    view.onActivate = { [weak self] in self?.activate(key) }
    view.onDelete = { [weak self] in self?.onDeleteMark?(markID) }
    addSubview(view)
    interactionViews[key] = view
  }

  private func layoutInteractionViews() {
    for (key, view) in interactionViews {
      guard captureMode == .inactive,
        let mark = marks.first(where: { $0.id == key.markID }),
        let rect = interactionRect(for: mark, endpoint: key.endpoint)
      else {
        view.isHidden = true
        continue
      }
      let padding: CGFloat = key.endpoint == .source ? 7 : 5
      let hitRect = rect.insetBy(dx: -padding, dy: -padding).intersection(bounds)
      view.frame = hitRect
      view.isHidden = hitRect.isEmpty
    }
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  private func activate(_ key: MarkInteractionKey) {
    guard captureMode == .inactive,
      let mark = marks.first(where: { $0.id == key.markID }),
      let rect = interactionRect(for: mark, endpoint: key.endpoint)
    else { return }
    onActivateMark?(MarkInteractionTarget(mark: mark, endpoint: key.endpoint, rect: rect))
  }

  private func updateModifierHover(at point: NSPoint, controlHeld: Bool) {
    guard captureMode == .inactive, controlHeld, let key = interactionKey(at: point) else {
      clearHoveredMark()
      return
    }
    guard hoveredMarkID != key.markID || hoveredEndpoint != key.endpoint,
      let mark = marks.first(where: { $0.id == key.markID }),
      let rect = interactionRect(for: mark, endpoint: key.endpoint)
    else { return }
    hoveredMarkID = key.markID
    hoveredEndpoint = key.endpoint
    onHoverMark?(MarkInteractionTarget(mark: mark, endpoint: key.endpoint, rect: rect))
    needsDisplay = true
  }

  private func updateModifierHoverForCurrentPointer(controlHeld: Bool) {
    guard let window else {
      clearHoveredMark()
      return
    }
    let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
    updateModifierHover(at: convert(windowPoint, from: nil), controlHeld: controlHeld)
  }

  private func interactionKey(at point: NSPoint) -> MarkInteractionKey? {
    for case let view as MarkHitTargetView in subviews.reversed()
    where !view.isHidden && view.frame.contains(point) {
      return view.key
    }
    return nil
  }

  private func clearHoveredMark() {
    guard hoveredMarkID != nil || hoveredEndpoint != nil else { return }
    hoveredMarkID = nil
    hoveredEndpoint = nil
    onHoverMark?(nil)
    needsDisplay = true
  }

  private func stopFlagsMonitor() {
    guard let flagsMonitor else { return }
    NSEvent.removeMonitor(flagsMonitor)
    self.flagsMonitor = nil
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
