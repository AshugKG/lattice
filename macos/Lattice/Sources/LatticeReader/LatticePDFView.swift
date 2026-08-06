import AppKit
import LatticeCore
import PDFKit

@MainActor
public final class LatticePDFView: PDFView {
  public var onOpen: (() -> Void)?
  public var onHelp: (() -> Void)?
  public var onFind: (() -> Void)?
  public var onCapturePortal: (() -> Void)?
  public var onNonLocalCommand: ((ReaderCommand) -> Void)?
  public var onDropPDF: ((URL) -> Void)?
  public var onViewportChanged: (() -> Void)?
  public var onBecameActive: (() -> Void)?
  public var onWillFollowLink: (() -> Void)?

  private var shortcutResolver = ShortcutResolver()

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  public required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  public override var acceptsFirstResponder: Bool { true }

  public override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onBecameActive?() }
    return accepted
  }

  public override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onBecameActive?()
    let point = convert(event.locationInWindow, from: nil)
    if hasInternalNavigationLink(at: point) {
      onWillFollowLink?()
    }
    super.mouseDown(with: event)
  }

  public override func keyDown(with event: NSEvent) {
    if let command = resolveCommand(from: event) {
      execute(command)
      return
    }
    super.keyDown(with: event)
  }

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.control) || flags.contains(.command) else {
      return super.performKeyEquivalent(with: event)
    }
    if let command = resolveCommand(from: event) {
      execute(command)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedPDFURL(from: sender) == nil ? [] : .copy
  }

  public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let url = droppedPDFURL(from: sender) else { return false }
    onDropPDF?(url)
    return true
  }

  public override func scrollWheel(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onBecameActive?()
    super.scrollWheel(with: event)
    onViewportChanged?()
  }

  public override func magnify(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onBecameActive?()
    super.magnify(with: event)
    onViewportChanged?()
  }

  public func execute(_ command: ReaderCommand) {
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
    case .documentStart, .documentEnd, .nextPage, .previousPage, .goToPage, .findForward,
      .findBackward, .findNext, .findPrevious, .jumpBackward, .jumpForward, .showCommandPalette,
      .showPortals, .showHome, .verticalSplit, .horizontalSplit, .closeSplit, .focusLeft, .focusRight,
      .focusUp, .focusDown, .quit:
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

  /// Caret-like selection at the visible viewport edge, for Vim-style find-from-here.
  /// PDFKit's `findString(fromSelection:)` ignores invalid origins and starts at the document edge,
  /// so this must return a real page selection even when the point lands in whitespace.
  public func searchOriginSelection(backward: Bool) -> PDFSelection? {
    guard let document else { return nil }
    let viewPoint = NSPoint(
      x: bounds.midX,
      y: backward ? bounds.minY + 2 : bounds.maxY - 2
    )
    guard let page = page(for: viewPoint, nearest: true) ?? currentPage else { return nil }
    let box = page.bounds(for: .cropBox)
    let raw = convert(viewPoint, to: page)
    let pagePoint = CGPoint(
      x: min(max(raw.x, box.minX), box.maxX),
      y: min(max(raw.y, box.minY), box.maxY)
    )
    let charCount = page.numberOfCharacters
    if charCount > 0 {
      var index = page.characterIndex(at: pagePoint)
      if index < 0 || index >= charCount {
        index = nearestCharacterIndex(on: page, to: pagePoint, backward: backward) ?? (backward
          ? charCount - 1 : 0)
      }
      let start = max(0, index)
      let end = min(index + 1, charCount)
      if let selection = document.selection(
        from: page, atCharacterIndex: start, to: page, atCharacterIndex: end)
      {
        return selection
      }
    }
    return document.selection(from: page, at: pagePoint, to: page, at: pagePoint)
  }

  private func nearestCharacterIndex(on page: PDFPage, to point: CGPoint, backward: Bool) -> Int? {
    let count = page.numberOfCharacters
    guard count > 0 else { return nil }
    var bestIndex: Int?
    var bestDistance = CGFloat.greatestFiniteMagnitude
    let step = max(1, count / 800)
    for index in stride(from: 0, to: count, by: step) {
      let bounds = page.characterBounds(at: index)
      guard !bounds.isNull, !bounds.isEmpty else { continue }
      let mid = CGPoint(x: bounds.midX, y: bounds.midY)
      // PDF y grows upward; reading continues toward lower y.
      if !backward && mid.y > point.y + 0.5 { continue }
      if backward && mid.y < point.y - 0.5 { continue }
      let dx = mid.x - point.x
      let dy = mid.y - point.y
      let distance = dx * dx + dy * dy
      if distance < bestDistance {
        bestDistance = distance
        bestIndex = index
      }
    }
    return bestIndex ?? (backward ? count - 1 : 0)
  }

  private func resolveCommand(from event: NSEvent) -> ReaderCommand? {
    let key = event.charactersIgnoringModifiers ?? ""
    var modifiers: ShortcutModifiers = []
    if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
    if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
    return shortcutResolver.resolve(
      key: key,
      keyCode: event.keyCode,
      modifiers: modifiers,
      timestamp: event.timestamp
    )
  }

  private func hasInternalNavigationLink(at viewPoint: NSPoint) -> Bool {
    guard let page = page(for: viewPoint, nearest: false) else { return false }
    let pagePoint = convert(viewPoint, to: page)
    guard let annotation = page.annotation(at: pagePoint) else { return false }
    if annotation.destination != nil { return true }
    if annotation.action is PDFActionGoTo || annotation.action is PDFActionRemoteGoTo {
      return true
    }
    return false
  }

  public func currentJumpLocation(descriptor: DocumentDescriptor) -> JumpLocation? {
    currentJumpLocation(fingerprint: descriptor.fingerprint, path: descriptor.url.path)
  }

  public func currentJumpLocation(fingerprint: String, path: String) -> JumpLocation? {
    guard let document, let page = currentPage else { return nil }
    let viewCenter = NSPoint(x: bounds.midX, y: bounds.midY)
    let centerPage = self.page(for: viewCenter, nearest: true) ?? page
    let pagePoint = convert(viewCenter, to: centerPage)
    let box = centerPage.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0 else { return nil }
    return JumpLocation(
      documentFingerprint: fingerprint,
      documentPath: path,
      pageIndex: document.index(for: centerPage),
      viewportCenter: NormalizedPoint(
        x: min(1, max(0, (pagePoint.x - box.minX) / box.width)),
        y: min(1, max(0, (pagePoint.y - box.minY) / box.height))
      ),
      scaleFactor: scaleFactor
    )
  }

  public func go(to anchor: PortalAnchor, scale: CGFloat? = nil) {
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

  public func restore(_ location: JumpLocation) {
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

  /// Scroll so a normalized top-of-page Y (0 = top, 1 = bottom) sits near the viewport top.
  public func scrollProblemToTop(pageIndex: Int, topY: Double) {
    guard let document, let page = document.page(at: pageIndex) else { return }
    let box = page.bounds(for: .cropBox)
    let clamped = min(1, max(0, topY))
    // Indexer / CLI use top-origin; PDFKit crop box is bottom-origin.
    let pagePoint = NSPoint(
      x: box.midX,
      y: box.minY + box.height * (1 - clamped)
    )
    go(to: PDFDestination(page: page, at: pagePoint))
    DispatchQueue.main.async { [weak self, weak page] in
      guard let self, let page else { return }
      self.alignVisibleTop(pagePoint: pagePoint, on: page)
      self.onViewportChanged?()
    }
  }

  private func alignVisibleTop(pagePoint: NSPoint, on page: PDFPage) {
    guard let scrollView, let documentView = scrollView.documentView else { return }
    layoutSubtreeIfNeeded()
    documentView.layoutSubtreeIfNeeded()
    let pointInPDFView = convert(pagePoint, from: page)
    let pointInDocument = documentView.convert(pointInPDFView, from: self)
    let clip = scrollView.contentView
    let padding: CGFloat = 16
    let proposed: NSRect
    if clip.isFlipped {
      proposed = NSRect(
        x: pointInDocument.x - clip.bounds.width / 2,
        y: pointInDocument.y - padding,
        width: clip.bounds.width,
        height: clip.bounds.height
      )
    } else {
      proposed = NSRect(
        x: pointInDocument.x - clip.bounds.width / 2,
        y: pointInDocument.y - clip.bounds.height + padding,
        width: clip.bounds.width,
        height: clip.bounds.height
      )
    }
    clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
    scrollView.reflectScrolledClipView(clip)
  }

  public var scrollView: NSScrollView? {
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
