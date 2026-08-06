import AppKit
import LatticeCore
import LatticeReader
import PDFKit

enum PortalCaptureMode: Equatable {
  case inactive
  /// Drag to place the source box.
  case source
  /// Source placed; waiting for a second portal-button / `p` press before destination drag.
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
  let rect: NSRect
}

private struct PortalInteractionKey: Hashable {
  let portalID: UUID
  let endpoint: PortalEndpoint
}

@MainActor
private final class PortalHitTargetView: NSView {
  let key: PortalInteractionKey
  var onActivate: (() -> Void)?
  var onDelete: (() -> Void)?

  private var isPressed = false

  init(key: PortalInteractionKey) {
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
    let delete = NSMenuItem(title: "Delete Portal", action: #selector(deletePortal), keyEquivalent: "")
    delete.target = self
    menu.addItem(delete)
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  @objc private func deletePortal() {
    onDelete?()
  }
}

@MainActor
final class PortalOverlayView: NSView {
  weak var pdfView: PDFView?
  var portals: [Portal] = [] { didSet { rebuildInteractionViews() } }
  var documentFingerprint: String? { didSet { rebuildInteractionViews() } }
  var captureMode: PortalCaptureMode = .inactive {
    didSet {
      dragStart = nil
      dragCurrent = nil
      rebuildInteractionViews()
    }
  }
  var arrivalAnchorID: UUID? { didSet { needsDisplay = true } }
  /// External focus rect (LeetMath / CLI); drawn until cleared or replaced.
  var focusHighlight: PortalAnchor? { didSet { needsDisplay = true } }
  var onBoxCaptured: ((CapturedPortalBox) -> Void)?
  var onActivatePortal: ((PortalInteractionTarget) -> Void)?
  var onDeletePortal: ((UUID) -> Void)?
  var onHoverPortal: ((PortalInteractionTarget?) -> Void)?

  private var dragStart: NSPoint?
  private var dragCurrent: NSPoint?
  private var dragPage: PDFPage?
  private var hoveredPortalID: UUID?
  private var hoveredEndpoint: PortalEndpoint?
  private var interactionViews: [PortalInteractionKey: PortalHitTargetView] = [:]
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
    if captureMode.allowsDrawing {
      addCursorRect(bounds, cursor: .crosshair)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01 else { return nil }
    if captureMode.allowsDrawing { return self }
    let event = NSApp.currentEvent
    let isControlClick = event?.modifierFlags.contains(.control) == true
    let isSecondaryClick = event?.type == .rightMouseDown || event?.type == .rightMouseUp
    guard isControlClick || isSecondaryClick else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func mouseDown(with event: NSEvent) {
    guard captureMode.allowsDrawing, let pdfView else { return }
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
    guard captureMode.allowsDrawing, dragStart != nil, let dragPage else { return }
    let point = convert(event.locationInWindow, from: nil)
    dragCurrent = clamp(point, to: overlayRect(for: dragPage))
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard captureMode.allowsDrawing else { return }

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
    clearHoveredPortal()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard documentFingerprint != nil else { return }

    for portal in portals {
      if portal.destination.documentFingerprint == documentFingerprint {
        drawDestination(
          portal.destination,
          hovered: portal.id == hoveredPortalID && hoveredEndpoint == .destination)
      }
      if portal.source.documentFingerprint == documentFingerprint {
        drawSource(
          portal.source,
          hovered: portal.id == hoveredPortalID && hoveredEndpoint == .source)
      }
    }

    if let focus = focusHighlight {
      drawFocusHighlight(focus)
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

  private func drawFocusHighlight(_ anchor: PortalAnchor) {
    guard let rect = overlayRect(for: anchor) else { return }
    let color = NSColor.systemOrange
    color.withAlphaComponent(0.22).setFill()
    color.setStroke()
    let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
    path.lineWidth = 3
    path.fill()
    path.stroke()
  }

  private func drawSource(_ anchor: PortalAnchor, hovered: Bool) {
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

  private func drawDestination(_ anchor: PortalAnchor, hovered: Bool) {
    guard let rect = overlayRect(for: anchor) else { return }
    let isArrival = anchor.id == arrivalAnchorID
    let color = NSColor.controlAccentColor
    color.withAlphaComponent(isArrival ? 0.16 : (hovered ? 0.1 : 0.04)).setFill()
    color.withAlphaComponent(isArrival ? 0.65 : (hovered ? 0.55 : 0.45)).setStroke()
    let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
    path.lineWidth = isArrival ? 2 : 1.5
    path.fill()
    path.stroke()
  }

  private func sourceRect(for portal: Portal) -> NSRect? {
    guard portal.source.documentFingerprint == documentFingerprint else { return nil }
    return overlayRect(for: portal.source)
  }

  private func destinationRect(for portal: Portal) -> NSRect? {
    guard portal.destination.documentFingerprint == documentFingerprint else { return nil }
    return overlayRect(for: portal.destination)
  }

  private func interactionRect(for portal: Portal, endpoint: PortalEndpoint) -> NSRect? {
    endpoint == .source ? sourceRect(for: portal) : destinationRect(for: portal)
  }

  private func rebuildInteractionViews() {
    for view in interactionViews.values {
      view.removeFromSuperview()
    }
    interactionViews.removeAll(keepingCapacity: true)
    hoveredPortalID = nil
    hoveredEndpoint = nil
    onHoverPortal?(nil)

    guard !captureMode.allowsDrawing, captureMode != .sourcePlaced, let documentFingerprint else {
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
      return
    }

    for portal in portals {
      if portal.source.documentFingerprint == documentFingerprint {
        addInteractionView(for: portal.id, endpoint: .source)
      }
      if portal.destination.documentFingerprint == documentFingerprint {
        addInteractionView(for: portal.id, endpoint: .destination)
      }
    }
    layoutInteractionViews()
  }

  private func addInteractionView(for portalID: UUID, endpoint: PortalEndpoint) {
    let key = PortalInteractionKey(portalID: portalID, endpoint: endpoint)
    let view = PortalHitTargetView(key: key)
    view.onActivate = { [weak self] in self?.activate(key) }
    view.onDelete = { [weak self] in self?.onDeletePortal?(portalID) }
    addSubview(view)
    interactionViews[key] = view
  }

  private func layoutInteractionViews() {
    for (key, view) in interactionViews {
      guard captureMode == .inactive,
        let portal = portals.first(where: { $0.id == key.portalID }),
        let rect = interactionRect(for: portal, endpoint: key.endpoint)
      else {
        view.isHidden = true
        continue
      }
      let padding: CGFloat = 7
      let hitRect = rect.insetBy(dx: -padding, dy: -padding).intersection(bounds)
      view.frame = hitRect
      view.isHidden = hitRect.isEmpty
    }
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  private func activate(_ key: PortalInteractionKey) {
    guard captureMode == .inactive,
      let portal = portals.first(where: { $0.id == key.portalID }),
      let rect = interactionRect(for: portal, endpoint: key.endpoint)
    else { return }
    onActivatePortal?(PortalInteractionTarget(portal: portal, endpoint: key.endpoint, rect: rect))
  }

  private func updateModifierHover(at point: NSPoint, controlHeld: Bool) {
    guard captureMode == .inactive, controlHeld, let key = interactionKey(at: point) else {
      clearHoveredPortal()
      return
    }
    guard hoveredPortalID != key.portalID || hoveredEndpoint != key.endpoint,
      let portal = portals.first(where: { $0.id == key.portalID }),
      let rect = interactionRect(for: portal, endpoint: key.endpoint)
    else { return }
    hoveredPortalID = key.portalID
    hoveredEndpoint = key.endpoint
    onHoverPortal?(PortalInteractionTarget(portal: portal, endpoint: key.endpoint, rect: rect))
    needsDisplay = true
  }

  private func updateModifierHoverForCurrentPointer(controlHeld: Bool) {
    guard let window else {
      clearHoveredPortal()
      return
    }
    let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
    updateModifierHover(at: convert(windowPoint, from: nil), controlHeld: controlHeld)
  }

  private func interactionKey(at point: NSPoint) -> PortalInteractionKey? {
    for case let view as PortalHitTargetView in subviews.reversed()
    where !view.isHidden && view.frame.contains(point) {
      return view.key
    }
    return nil
  }

  private func clearHoveredPortal() {
    guard hoveredPortalID != nil || hoveredEndpoint != nil else { return }
    hoveredPortalID = nil
    hoveredEndpoint = nil
    onHoverPortal?(nil)
    needsDisplay = true
  }

  private func stopFlagsMonitor() {
    guard let flagsMonitor else { return }
    NSEvent.removeMonitor(flagsMonitor)
    self.flagsMonitor = nil
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
