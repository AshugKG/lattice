import LatticeCore
import PDFKit
import SwiftUI
import UIKit

struct PDFKitView: UIViewRepresentable {
  let documentURL: URL?
  var controller: PDFController
  var portalOverlay: PortalOverlayController
  var captureMode: PortalCaptureMode
  var onViewportChanged: () -> Void
  var onDocumentReady: (PDFDocument) -> Void

  func makeUIView(context: Context) -> PDFHostView {
    let host = PDFHostView()
    let pdfView = host.pdfView
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.usePageViewController(false)
    pdfView.backgroundColor = .systemBackground
    // Portals paint on per-page overlays (scroll/zoom with the page).
    pdfView.pageOverlayViewProvider = portalOverlay

    host.chromeView.controller = portalOverlay
    host.chromeView.pdfView = pdfView

    controller.pdfView = pdfView
    portalOverlay.pdfView = pdfView
    context.coordinator.host = host
    context.coordinator.onViewportChanged = onViewportChanged
    context.coordinator.observe(pdfView)
    context.coordinator.applyCaptureMode(captureMode, host: host)

    if let documentURL, let document = PDFDocument(url: documentURL) {
      pdfView.document = document
      context.coordinator.observeScroll(in: pdfView)
      DispatchQueue.main.async {
        onDocumentReady(document)
      }
    }

    return host
  }

  func updateUIView(_ host: PDFHostView, context: Context) {
    let pdfView = host.pdfView
    controller.pdfView = pdfView
    portalOverlay.pdfView = pdfView
    host.chromeView.controller = portalOverlay
    host.chromeView.pdfView = pdfView
    pdfView.pageOverlayViewProvider = portalOverlay
    context.coordinator.host = host
    context.coordinator.onViewportChanged = onViewportChanged
    context.coordinator.applyCaptureMode(captureMode, host: host)

    let currentPath = pdfView.document?.documentURL?.path
    let newPath = documentURL?.path
    if currentPath != newPath {
      if let documentURL, let document = PDFDocument(url: documentURL) {
        pdfView.document = document
        DispatchQueue.main.async {
          onDocumentReady(document)
        }
      } else {
        pdfView.document = nil
      }
    }
    // PDFKit builds its scroll view lazily with the first document.
    context.coordinator.observeScroll(in: pdfView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator {
    var onViewportChanged: (() -> Void)?
    weak var host: PDFHostView?
    private var observers: [any NSObjectProtocol] = []
    private var scrollObservation: ScrollOffsetObserver?
    private weak var observedScrollView: UIScrollView?
    private var lastCaptureMode: PortalCaptureMode?

    deinit {
      for observer in observers {
        NotificationCenter.default.removeObserver(observer)
      }
    }

    func observe(_ pdfView: PDFView) {
      for observer in observers {
        NotificationCenter.default.removeObserver(observer)
      }
      observers.removeAll()

      let names: [Notification.Name] = [
        .PDFViewPageChanged,
        .PDFViewScaleChanged,
        .PDFViewVisiblePagesChanged,
      ]
      for name in names {
        observers.append(
          NotificationCenter.default.addObserver(
            forName: name, object: pdfView, queue: .main
          ) { [weak self] _ in
            self?.onViewportChanged?()
          }
        )
      }
    }

    /// PDFKit posts no scroll notification, so scrolling inside the already-visible pages
    /// never reaches `onViewportChanged`. Watch the scroll view PDFKit manages instead.
    @MainActor
    func observeScroll(in pdfView: PDFView) {
      guard let scrollView = pdfView.lattice_scrollView, scrollView !== observedScrollView else {
        return
      }
      observedScrollView = scrollView
      scrollObservation = ScrollOffsetObserver(scrollView: scrollView) { [weak self] in
        self?.onViewportChanged?()
      }
    }

    func applyCaptureMode(_ mode: PortalCaptureMode, host: PDFHostView) {
      let drawing = mode.allowsDrawing
      host.chromeView.captureMode = mode
      // Freeze scroll only while drawing a portal box.
      host.pdfView.lattice_scrollView?.isScrollEnabled = !drawing
      if lastCaptureMode != mode {
        lastCaptureMode = mode
        host.chromeView.controller?.captureMode = mode
        host.chromeView.controller?.refreshAll()
      }
    }
  }
}

/// Reports scroll offset changes on the scroll view PDFKit owns. String-keyed KVO because
/// Swift cannot form a key path to `contentOffset` from outside the main actor.
final class ScrollOffsetObserver: NSObject {
  private weak var scrollView: UIScrollView?
  private let onChange: () -> Void
  private var lastOffset: CGPoint?

  init(scrollView: UIScrollView, onChange: @escaping () -> Void) {
    self.scrollView = scrollView
    self.onChange = onChange
    super.init()
    scrollView.addObserver(self, forKeyPath: "contentOffset", options: [.new], context: nil)
  }

  deinit {
    scrollView?.removeObserver(self, forKeyPath: "contentOffset")
  }

  override func observeValue(
    forKeyPath keyPath: String?,
    of object: Any?,
    change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    guard let offset = change?[.newKey] as? CGPoint else { return }
    if let lastOffset, abs(lastOffset.x - offset.x) < 0.5, abs(lastOffset.y - offset.y) < 0.5 {
      return
    }
    lastOffset = offset
    onChange()
  }
}

/// PDFView + always-on chrome for portal capture and taps (page overlays are display-only).
final class PDFHostView: UIView {
  let pdfView = PDFView()
  let chromeView = PortalChromeView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(pdfView)
    addSubview(chromeView)
    chromeView.backgroundColor = .clear
    chromeView.isOpaque = false
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    pdfView.frame = bounds
    chromeView.frame = bounds
  }
}

/// Full-bleed interaction: draw portals while capturing; tap portals when idle; otherwise pass-through.
final class PortalChromeView: UIView {
  weak var pdfView: PDFView?
  weak var controller: PortalOverlayController?

  var captureMode: PortalCaptureMode = .inactive {
    didSet {
      dragStart = nil
      dragCurrent = nil
      setNeedsDisplay()
    }
  }

  private var dragStart: CGPoint?
  private var dragCurrent: CGPoint?
  private let deleteBadgeSize: CGFloat = 22

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
    isUserInteractionEnabled = true

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.maximumNumberOfTouches = 1
    pan.cancelsTouchesInView = true
    addGestureRecognizer(pan)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
    if captureMode.allowsDrawing { return self }
    if deleteTarget(at: point) != nil { return self }
    if interactionTarget(at: point) != nil { return self }
    return nil  // let PDFView scroll / zoom
  }

  override func draw(_ rect: CGRect) {
    guard captureMode.allowsDrawing,
      let context = UIGraphicsGetCurrentContext(),
      let start = dragStart, let current = dragCurrent
    else { return }
    let dragRect = standardizedRect(from: start, to: current)
    let color = UIColor.tintColor
    context.setFillColor(color.withAlphaComponent(0.14).cgColor)
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(2)
    context.fill(dragRect)
    context.stroke(dragRect)
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    guard captureMode.allowsDrawing else { return }
    let point = gesture.location(in: self)

    switch gesture.state {
    case .began:
      dragStart = point
      dragCurrent = point
      setNeedsDisplay()
    case .changed:
      dragCurrent = clamp(point, to: bounds)
      setNeedsDisplay()
    case .ended, .cancelled:
      defer {
        dragStart = nil
        dragCurrent = nil
        setNeedsDisplay()
      }
      guard let start = dragStart, let current = dragCurrent,
        let pdfView, let document = pdfView.document
      else { return }
      let boxRect = standardizedRect(from: start, to: current).intersection(bounds)
      guard boxRect.width >= 8, boxRect.height >= 8,
        let captured = capturedBox(from: boxRect, in: pdfView, document: document)
      else { return }
      controller?.onBoxCaptured?(captured)
    default:
      break
    }
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard captureMode == .inactive, gesture.state == .ended else { return }
    let point = gesture.location(in: self)
    if let portalID = deleteTarget(at: point) {
      controller?.onDeletePortal?(portalID)
      return
    }
    guard let target = interactionTarget(at: point) else { return }
    controller?.onActivatePortal?(target)
  }

  private func deleteTarget(at point: CGPoint) -> UUID? {
    guard let controller, let fingerprint = controller.documentFingerprint else { return nil }
    for portal in controller.portals.reversed() {
      guard portal.source.documentFingerprint == fingerprint,
        let badge = deleteBadgeRect(for: portal.source),
        badge.insetBy(dx: -6, dy: -6).contains(point)
      else { continue }
      return portal.id
    }
    return nil
  }

  private func interactionTarget(at point: CGPoint) -> PortalInteractionTarget? {
    guard let controller, let fingerprint = controller.documentFingerprint else { return nil }
    let padding: CGFloat = 12
    for portal in controller.portals.reversed() {
      if portal.source.documentFingerprint == fingerprint,
        let rect = viewRect(for: portal.source)?.insetBy(dx: -padding, dy: -padding),
        rect.contains(point)
      {
        return PortalInteractionTarget(portal: portal, endpoint: .source)
      }
      if portal.destination.documentFingerprint == fingerprint,
        let rect = viewRect(for: portal.destination)?.insetBy(dx: -padding, dy: -padding),
        rect.contains(point)
      {
        return PortalInteractionTarget(portal: portal, endpoint: .destination)
      }
    }
    return nil
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

  /// Map a portal anchor into this chrome view via PDFKit page transforms.
  private func viewRect(for anchor: PortalAnchor) -> CGRect? {
    guard let pdfView, let document = pdfView.document,
      let page = document.page(at: anchor.pageIndex)
    else { return nil }
    let box = page.bounds(for: .cropBox)
    guard let pageRect = PortalGeometry.pageRect(for: anchor.bounds, in: box) else { return nil }
    let inPDF = pdfView.convert(pageRect, from: page)
    return convert(inPDF, from: pdfView)
  }

  private func capturedBox(from viewRect: CGRect, in pdfView: PDFView, document: PDFDocument)
    -> CapturedPortalBox?
  {
    let mid = CGPoint(x: viewRect.midX, y: viewRect.midY)
    let midInPDF = convert(mid, to: pdfView)
    guard let page = pdfView.page(for: midInPDF, nearest: true) else { return nil }

    let topLeft = pdfView.convert(convert(viewRect.origin, to: pdfView), to: page)
    let bottomRight = pdfView.convert(
      convert(CGPoint(x: viewRect.maxX, y: viewRect.maxY), to: pdfView), to: page)
    let pageRect = CGRect(
      x: min(topLeft.x, bottomRight.x),
      y: min(topLeft.y, bottomRight.y),
      width: abs(bottomRight.x - topLeft.x),
      height: abs(bottomRight.y - topLeft.y)
    ).intersection(page.bounds(for: .cropBox))

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
