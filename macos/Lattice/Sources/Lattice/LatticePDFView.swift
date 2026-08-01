import AppKit
import LatticeCore
import PDFKit

@MainActor
final class LatticePDFView: PDFView {
  var onOpen: (() -> Void)?
  var onHelp: (() -> Void)?
  var onFind: (() -> Void)?
  var onCapturePortal: (() -> Void)?
  var onNonLocalCommand: ((ReaderCommand) -> Void)?
  var onDropPDF: ((URL) -> Void)?
  var onViewportChanged: (() -> Void)?

  private var shortcutResolver = ShortcutResolver()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    guard let key = event.charactersIgnoringModifiers, !key.isEmpty else {
      super.keyDown(with: event)
      return
    }
    var modifiers: ShortcutModifiers = []
    if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
    if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
    guard
      let command = shortcutResolver.resolve(
        key: key,
        keyCode: event.keyCode,
        modifiers: modifiers,
        timestamp: event.timestamp
      )
    else {
      super.keyDown(with: event)
      return
    }
    perform(command)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedPDFURL(from: sender) == nil ? [] : .copy
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let url = droppedPDFURL(from: sender) else { return false }
    onDropPDF?(url)
    return true
  }

  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
    onViewportChanged?()
  }

  private func perform(_ command: ReaderCommand) {
    switch command {
    case .open: onOpen?()
    case .help: onHelp?()
    case .find: onFind?()
    case .scrollDown: scrollBy(x: 0, y: 88)
    case .scrollUp: scrollBy(x: 0, y: -88)
    case .scrollLeft: scrollBy(x: -88, y: 0)
    case .scrollRight: scrollBy(x: 88, y: 0)
    case .halfDown: scrollBy(x: 0, y: (scrollView?.contentView.bounds.height ?? 400) / 2)
    case .halfUp: scrollBy(x: 0, y: -(scrollView?.contentView.bounds.height ?? 400) / 2)
    case .documentStart, .documentEnd, .nextPage, .previousPage, .jumpBackward, .jumpForward:
      onNonLocalCommand?(command)
    case .zoomIn:
      autoScales = false
      scaleFactor = min(maxScaleFactor, scaleFactor + 0.15)
    case .zoomOut:
      autoScales = false
      scaleFactor = max(minScaleFactor, scaleFactor - 0.15)
    case .fitWidth: autoScales = true
    case .capturePortal: onCapturePortal?()
    case .cancelPortal: onNonLocalCommand?(command)
    }
  }

  func currentJumpLocation(descriptor: DocumentDescriptor) -> JumpLocation? {
    guard let document, let page = currentPage else { return nil }
    let viewCenter = NSPoint(x: bounds.midX, y: bounds.midY)
    let centerPage = self.page(for: viewCenter, nearest: true) ?? page
    let pagePoint = convert(viewCenter, to: centerPage)
    let box = centerPage.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0 else { return nil }
    return JumpLocation(
      documentFingerprint: descriptor.fingerprint,
      documentPath: descriptor.url.path,
      pageIndex: document.index(for: centerPage),
      viewportCenter: NormalizedPoint(
        x: min(1, max(0, (pagePoint.x - box.minX) / box.width)),
        y: min(1, max(0, (pagePoint.y - box.minY) / box.height))
      ),
      scaleFactor: scaleFactor
    )
  }

  func go(to anchor: PortalAnchor, scale: CGFloat? = nil) {
    guard let document, let page = document.page(at: anchor.pageIndex) else { return }
    if let scale {
      autoScales = false
      scaleFactor = min(maxScaleFactor, max(minScaleFactor, scale))
    }
    let box = page.bounds(for: .cropBox)
    guard let target = PortalGeometry.pageRect(for: anchor.bounds, in: box) else { return }
    center(pagePoint: NSPoint(x: target.midX, y: target.midY), on: page)
    onViewportChanged?()
  }

  func restore(_ location: JumpLocation) {
    guard let document, let page = document.page(at: location.pageIndex) else { return }
    autoScales = false
    scaleFactor = min(maxScaleFactor, max(minScaleFactor, location.scaleFactor))
    let box = page.bounds(for: .cropBox)
    let point = NSPoint(
      x: box.minX + box.width * location.viewportCenter.x,
      y: box.minY + box.height * location.viewportCenter.y
    )
    center(pagePoint: point, on: page)
    onViewportChanged?()
  }

  var scrollView: NSScrollView? {
    descendants(of: self).compactMap { $0 as? NSScrollView }.first
  }

  private func scrollBy(x: CGFloat, y: CGFloat) {
    guard let scrollView else { return }
    let clip = scrollView.contentView
    var point = clip.bounds.origin
    point.x += x
    point.y += clip.isFlipped ? y : -y
    point = clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin
    clip.scroll(to: point)
    scrollView.reflectScrolledClipView(clip)
    onViewportChanged?()
  }

  private func center(pagePoint: NSPoint, on page: PDFPage) {
    go(to: PDFDestination(page: page, at: pagePoint))
    DispatchQueue.main.async { [weak self, weak page] in
      guard let self, let page else { return }
      self.centerVisible(pagePoint: pagePoint, on: page)
    }
  }

  private func centerVisible(pagePoint: NSPoint, on page: PDFPage) {
    guard let scrollView, let documentView = scrollView.documentView else { return }
    layoutSubtreeIfNeeded()
    documentView.layoutSubtreeIfNeeded()
    let pointInPDFView = convert(pagePoint, from: page)
    let pointInDocument = documentView.convert(pointInPDFView, from: self)
    let clip = scrollView.contentView
    let proposed = NSRect(
      x: pointInDocument.x - clip.bounds.width / 2,
      y: pointInDocument.y - clip.bounds.height / 2,
      width: clip.bounds.width,
      height: clip.bounds.height
    )
    clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
    scrollView.reflectScrolledClipView(clip)
  }

  private func scrollToDocumentEdge(end: Bool) {
    guard let scrollView, let documentView = scrollView.documentView else { return }
    let clip = scrollView.contentView
    let maximumY = max(0, documentView.bounds.height - clip.bounds.height)
    let targetY = clip.isFlipped ? (end ? maximumY : 0) : (end ? 0 : maximumY)
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetY))
    scrollView.reflectScrolledClipView(clip)
    onViewportChanged?()
  }

  private func descendants(of root: NSView) -> [NSView] {
    root.subviews + root.subviews.flatMap(descendants(of:))
  }

  private func droppedPDFURL(from sender: NSDraggingInfo) -> URL? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: ["com.adobe.pdf"],
    ]
    return sender.draggingPasteboard
      .readObjects(forClasses: [NSURL.self], options: options)?
      .compactMap { $0 as? URL }
      .first { $0.pathExtension.lowercased() == "pdf" }
  }
}
