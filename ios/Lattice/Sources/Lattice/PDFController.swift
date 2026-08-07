import LatticeCore
import PDFKit
import UIKit

/// Thin helpers around PDFKit for jump restore, page goto, and find.
@MainActor
final class PDFController {
  weak var pdfView: PDFView?
  private var restoreWorkItem: DispatchWorkItem?

  func visiblePage(in pdfView: PDFView) -> PDFPage? {
    let center = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
    return pdfView.page(for: center, nearest: true) ?? pdfView.currentPage
  }

  /// The viewport's top-left, resolved against the page that actually contains it.
  ///
  /// Anchoring on the page under the *center* would let `PortalGeometry.normalized` clip the
  /// anchor to a page boundary whenever the viewport straddles two pages, which in continuous
  /// mode is most of the time — that clipping is what made resume land off the saved spot.
  private func viewportAnchor(in pdfView: PDFView) -> (page: PDFPage, point: CGPoint)? {
    let topLeft = CGPoint(x: pdfView.bounds.minX, y: pdfView.bounds.minY)
    guard let page = pdfView.page(for: topLeft, nearest: true) ?? pdfView.currentPage else {
      return nil
    }
    let box = page.bounds(for: .cropBox)
    let inPage = pdfView.convert(topLeft, to: page)
    // A top edge landing in the gap between pages converts just outside the crop box.
    return (
      page,
      CGPoint(
        x: min(max(inPage.x, box.minX), box.maxX),
        y: min(max(inPage.y, box.minY), box.maxY)
      )
    )
  }

  /// Capture the viewport, storing its top-left as the top-left of `visibleRect`.
  func currentJumpLocation(fingerprint: String, path: String) -> JumpLocation? {
    guard let pdfView, let document = pdfView.document,
      let anchor = viewportAnchor(in: pdfView)
    else { return nil }

    let box = anchor.page.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0 else { return nil }

    // Build the window downward from the anchor so clipping to the page trims the far
    // edges and leaves the anchor corner — `(minX, maxY)` — exactly where it was.
    let viewportInPage = pdfView.convert(pdfView.bounds, to: anchor.page).standardized
    let window = CGRect(
      x: anchor.point.x,
      y: anchor.point.y - viewportInPage.height,
      width: viewportInPage.width,
      height: viewportInPage.height
    )

    return JumpLocation(
      documentFingerprint: fingerprint,
      documentPath: path,
      pageIndex: document.index(for: anchor.page),
      viewportCenter: NormalizedPoint(
        x: min(1, max(0, (window.midX - box.minX) / box.width)),
        y: min(1, max(0, (window.midY - box.minY) / box.height))
      ),
      scaleFactor: Double(pdfView.scaleFactor),
      visibleRect: PortalGeometry.normalized(rect: window, in: box)
    )
  }

  /// Restore the exact viewport by putting the saved anchor back at the view's top-left.
  ///
  /// PDFKit offers no exact-restore API on iOS: `go(to:on:)` only scrolls a rect far enough to
  /// be visible, and `currentDestination` / `go(to:)` are not inverses in continuous mode (the
  /// former reports the viewport's bottom edge, the latter realigns by a viewport height plus
  /// the bottom inset). So drive the scroll view PDFKit manages.
  func restore(_ location: JumpLocation, completion: (() -> Void)? = nil) {
    guard let pdfView, let document = pdfView.document,
      let page = document.page(at: location.pageIndex)
    else {
      completion?()
      return
    }

    restoreWorkItem?.cancel()

    let scale = min(
      pdfView.maxScaleFactor,
      max(pdfView.minScaleFactor, CGFloat(location.scaleFactor))
    )
    // Zoom first: a page point maps to a scroll offset that depends on scale.
    pdfView.autoScales = false
    pdfView.scaleFactor = scale

    let work = DispatchWorkItem { [weak pdfView] in
      guard let pdfView else {
        completion?()
        return
      }
      pdfView.autoScales = false
      pdfView.scaleFactor = scale
      pdfView.layoutIfNeeded()
      Self.scrollAnchorToTopLeft(of: location, page: page, in: pdfView)
      // Aligning is idempotent, so repeating it once absorbs any page layout that PDFKit
      // finishes after the first pass; a settled view moves by zero.
      DispatchQueue.main.async { [weak pdfView] in
        if let pdfView {
          pdfView.layoutIfNeeded()
          Self.scrollAnchorToTopLeft(of: location, page: page, in: pdfView)
        }
        completion?()
      }
    }
    restoreWorkItem = work
    DispatchQueue.main.async(execute: work)
  }

  private static func scrollAnchorToTopLeft(
    of location: JumpLocation, page: PDFPage, in pdfView: PDFView
  ) {
    guard let scrollView = pdfView.lattice_scrollView,
      let anchor = anchorPoint(for: location, page: page, in: pdfView)
    else { return }

    let inView = pdfView.convert(anchor, from: page)
    var offset = scrollView.contentOffset
    offset.x += inView.x - pdfView.bounds.minX
    offset.y += inView.y - pdfView.bounds.minY
    scrollView.setContentOffset(Self.clamped(offset, in: scrollView), animated: false)
  }

  /// Page-space anchor that belongs at the view's top-left: the saved rect's top-left.
  private static func anchorPoint(for location: JumpLocation, page: PDFPage, in pdfView: PDFView)
    -> CGPoint?
  {
    let box = page.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0 else { return nil }

    if let visibleRect = location.visibleRect,
      let pageRect = PortalGeometry.pageRect(for: visibleRect, in: box),
      !pageRect.isNull, !pageRect.isEmpty
    {
      // Page space is bottom-origin, so the top of the viewport is `maxY`.
      return CGPoint(x: pageRect.minX, y: pageRect.maxY)
    }

    // Legacy entries stored only a viewport center; offset it back out to a top-left.
    let center = CGPoint(
      x: box.minX + box.width * location.viewportCenter.x,
      y: box.minY + box.height * location.viewportCenter.y
    )
    let viewportInPage = pdfView.convert(pdfView.bounds, to: page).standardized
    return CGPoint(
      x: center.x - viewportInPage.width / 2,
      y: center.y + viewportInPage.height / 2
    )
  }

  private static func clamped(_ offset: CGPoint, in scrollView: UIScrollView) -> CGPoint {
    let inset = scrollView.adjustedContentInset
    let minX = -inset.left
    let minY = -inset.top
    let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
    let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
    return CGPoint(x: min(max(offset.x, minX), maxX), y: min(max(offset.y, minY), maxY))
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
    let bounds = pdfView.bounds
    let viewPoint = CGPoint(
      x: bounds.midX,
      y: backward ? bounds.maxY - 2 : bounds.minY + 2
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
