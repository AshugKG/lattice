import AppKit
import LatticeCore
import PDFKit

@MainActor
final class LatticePDFView: PDFView {
  var onOpen: (() -> Void)?
  var onHelp: (() -> Void)?
  var onFind: (() -> Void)?
  var onCapturePortal: (() -> Void)?
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
    case .documentStart: scrollToDocumentEdge(end: false)
    case .documentEnd: scrollToDocumentEdge(end: true)
    case .nextPage: goToNextPage(nil)
    case .previousPage: goToPreviousPage(nil)
    case .zoomIn:
      autoScales = false
      scaleFactor = min(maxScaleFactor, scaleFactor + 0.15)
    case .zoomOut:
      autoScales = false
      scaleFactor = max(minScaleFactor, scaleFactor - 0.15)
    case .fitWidth: autoScales = true
    case .capturePortal: onCapturePortal?()
    }
  }

  private var scrollView: NSScrollView? {
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
