import LatticeCore
import PDFKit
import UIKit

/// Thin helpers around PDFKit for jump restore, page goto, and find.
@MainActor
final class PDFController {
  weak var pdfView: PDFView?
  private var restoreWorkItem: DispatchWorkItem?

  func visiblePage(in pdfView: PDFView) -> PDFPage? {
    let visible = Self.visibleContentRect(in: pdfView)
    let center = CGPoint(x: visible.midX, y: visible.midY)
    return pdfView.page(for: center, nearest: true) ?? pdfView.currentPage
  }

  func currentJumpLocation(fingerprint: String, path: String) -> JumpLocation? {
    guard let pdfView, let document = pdfView.document,
      let page = visiblePage(in: pdfView)
    else { return nil }
    let box = page.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0 else { return nil }

    let visible = Self.visibleContentRect(in: pdfView)
    let visibleInPage = pdfView.convert(visible, to: page)
    let visibleRect = PortalGeometry.normalized(rect: visibleInPage, in: box)

    let viewCenter = CGPoint(x: visible.midX, y: visible.midY)
    let pagePoint = pdfView.convert(viewCenter, to: page)
    return JumpLocation(
      documentFingerprint: fingerprint,
      documentPath: path,
      pageIndex: document.index(for: page),
      viewportCenter: NormalizedPoint(
        x: min(1, max(0, (pagePoint.x - box.minX) / box.width)),
        y: min(1, max(0, (pagePoint.y - box.minY) / box.height))
      ),
      scaleFactor: Double(pdfView.scaleFactor),
      visibleRect: visibleRect
    )
  }

  /// Restore exact viewport by pinning the saved page rect via scroll offset + one correction.
  func restore(_ location: JumpLocation) {
    guard let pdfView, let document = pdfView.document,
      let page = document.page(at: location.pageIndex)
    else { return }

    restoreWorkItem?.cancel()

    let scale = min(
      pdfView.maxScaleFactor,
      max(pdfView.minScaleFactor, CGFloat(location.scaleFactor))
    )
    pdfView.autoScales = false
    pdfView.scaleFactor = scale

    let box = page.bounds(for: .cropBox)
    guard let pageRect = location.pageSpaceRect(in: box), !pageRect.isNull, !pageRect.isEmpty
    else { return }

    let work = DispatchWorkItem { [weak pdfView] in
      guard let pdfView else { return }
      pdfView.autoScales = false
      pdfView.scaleFactor = scale
      pdfView.layoutIfNeeded()
      pdfView.lattice_scrollView?.layoutIfNeeded()
      Self.pinPageRect(pageRect, on: page, in: pdfView)

      // Second pass after PDFKit finishes laying out pages at the new scale.
      DispatchQueue.main.async { [weak pdfView] in
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = scale
        pdfView.layoutIfNeeded()
        pdfView.lattice_scrollView?.layoutIfNeeded()
        Self.pinPageRect(pageRect, on: page, in: pdfView)
      }
    }
    restoreWorkItem = work
    DispatchQueue.main.async(execute: work)
  }

  func goToPage(index: Int) {
    guard let pdfView, let document = pdfView.document,
      let page = document.page(at: index)
    else { return }
    pdfView.go(to: page)
  }

  func go(to anchor: PortalAnchor, scale: CGFloat? = nil) {
    guard let pdfView, let document = pdfView.document,
      let page = document.page(at: anchor.pageIndex)
    else { return }
    if let scale {
      pdfView.autoScales = false
      pdfView.scaleFactor = min(
        pdfView.maxScaleFactor, max(pdfView.minScaleFactor, scale))
    }
    let box = page.bounds(for: .cropBox)
    guard let pageRect = PortalGeometry.pageRect(for: anchor.bounds, in: box),
      !pageRect.isNull, !pageRect.isEmpty
    else { return }
    pdfView.go(to: pageRect, on: page)
    DispatchQueue.main.async { [weak pdfView] in
      pdfView?.go(to: pageRect, on: page)
    }
  }

  func setScrollingEnabled(_ enabled: Bool) {
    pdfView?.lattice_scrollView?.isScrollEnabled = enabled
  }

  func searchOriginSelection(backward: Bool) -> PDFSelection? {
    guard let pdfView, let document = pdfView.document else { return nil }
    let visible = Self.visibleContentRect(in: pdfView)
    let viewPoint = CGPoint(
      x: visible.midX,
      y: backward ? visible.maxY - 2 : visible.minY + 2
    )
    guard let page = pdfView.page(for: viewPoint, nearest: true) ?? pdfView.currentPage else {
      return nil
    }
    let box = page.bounds(for: .cropBox)
    let raw = pdfView.convert(viewPoint, to: page)
    let pagePoint = CGPoint(
      x: min(max(raw.x, box.minX), box.maxX),
      y: min(max(raw.y, box.minY), box.maxY)
    )
    let charCount = page.numberOfCharacters
    if charCount > 0 {
      var index = page.characterIndex(at: pagePoint)
      if index < 0 || index >= charCount {
        index = backward ? charCount - 1 : 0
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

  @discardableResult
  func find(
    query: String,
    backward: Bool,
    fromCurrentSelection: Bool
  ) -> Bool {
    guard let pdfView, let document = pdfView.document else { return false }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    var options: NSString.CompareOptions = [.caseInsensitive]
    if backward { options.insert(.backwards) }

    let origin: PDFSelection?
    if fromCurrentSelection {
      origin = pdfView.currentSelection
    } else {
      origin = searchOriginSelection(backward: backward)
    }

    if let match = document.findString(trimmed, fromSelection: origin, withOptions: options) {
      pdfView.setCurrentSelection(match, animate: true)
      pdfView.go(to: match)
      return true
    }
    if origin != nil,
      let match = document.findString(trimmed, fromSelection: nil, withOptions: options)
    {
      pdfView.setCurrentSelection(match, animate: true)
      pdfView.go(to: match)
      return true
    }
    return false
  }

  func clearSelection() {
    pdfView?.setCurrentSelection(nil, animate: false)
    pdfView?.highlightedSelections = nil
  }

  // MARK: - Exact viewport pin

  /// Visible page area in `pdfView` coordinates (bounds minus scroll adjusted insets).
  static func visibleContentRect(in pdfView: PDFView) -> CGRect {
    let bounds = pdfView.bounds
    guard let scroll = pdfView.lattice_scrollView else { return bounds }
    let inset = scroll.adjustedContentInset
    let rect = bounds.inset(by: inset)
    guard rect.width > 1, rect.height > 1 else { return bounds }
    return rect
  }

  /// Pin the saved page-space rect so its visual top-left matches the visible content origin.
  private static func pinPageRect(_ pageRect: CGRect, on page: PDFPage, in pdfView: PDFView) {
    guard let scrollView = pdfView.lattice_scrollView else {
      pdfView.go(to: pageRect, on: page)
      return
    }

    let topLeft = visualTopLeft(of: pageRect, from: page, in: pdfView)
    align(pagePoint: topLeft, on: page, toVisibleOriginIn: pdfView, scrollView: scrollView)

    // Measure-and-correct: remaining error is desired point vs visible origin in view space.
    let visible = visibleContentRect(in: pdfView)
    let desiredInView = pdfView.convert(topLeft, from: page)
    let origin = CGPoint(x: visible.minX, y: visible.minY)
    let delta = CGPoint(x: desiredInView.x - origin.x, y: desiredInView.y - origin.y)
    guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }

    var offset = scrollView.contentOffset
    offset.x += delta.x
    offset.y += delta.y
    scrollView.setContentOffset(clampedContentOffset(offset, in: scrollView), animated: false)
  }

  /// Page-space point that maps to the visual top-left of `pageRect` in the view.
  private static func visualTopLeft(of pageRect: CGRect, from page: PDFPage, in pdfView: PDFView)
    -> CGPoint
  {
    let corners = [
      CGPoint(x: pageRect.minX, y: pageRect.minY),
      CGPoint(x: pageRect.minX, y: pageRect.maxY),
      CGPoint(x: pageRect.maxX, y: pageRect.minY),
      CGPoint(x: pageRect.maxX, y: pageRect.maxY),
    ]
    return corners.min { a, b in
      let av = pdfView.convert(a, from: page)
      let bv = pdfView.convert(b, from: page)
      if abs(av.y - bv.y) > 0.5 { return av.y < bv.y }
      return av.x < bv.x
    } ?? CGPoint(x: pageRect.midX, y: pageRect.maxY)
  }

  private static func align(
    pagePoint: CGPoint,
    on page: PDFPage,
    toVisibleOriginIn pdfView: PDFView,
    scrollView: UIScrollView
  ) {
    let pointInPDFView = pdfView.convert(pagePoint, from: page)
    let pointInScroll = scrollView.convert(pointInPDFView, from: pdfView)
    let visible = visibleContentRect(in: pdfView)
    let originInScroll = scrollView.convert(CGPoint(x: visible.minX, y: visible.minY), from: pdfView)

    var offset = scrollView.contentOffset
    offset.x += pointInScroll.x - originInScroll.x
    offset.y += pointInScroll.y - originInScroll.y
    scrollView.setContentOffset(clampedContentOffset(offset, in: scrollView), animated: false)
  }

  private static func clampedContentOffset(_ offset: CGPoint, in scrollView: UIScrollView) -> CGPoint
  {
    let inset = scrollView.adjustedContentInset
    let minX = -inset.left
    let minY = -inset.top
    let maxX = max(
      minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
    let maxY = max(
      minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
    return CGPoint(
      x: min(max(offset.x, minX), maxX),
      y: min(max(offset.y, minY), maxY)
    )
  }
}

extension PDFView {
  var lattice_scrollView: UIScrollView? {
    if let scroll = subviews.compactMap({ $0 as? UIScrollView }).first {
      return scroll
    }
    var stack = subviews
    while let view = stack.popLast() {
      if let scroll = view as? UIScrollView { return scroll }
      stack.append(contentsOf: view.subviews)
    }
    return nil
  }
}
