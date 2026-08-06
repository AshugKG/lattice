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

  func currentJumpLocation(fingerprint: String, path: String) -> JumpLocation? {
    guard let pdfView, let document = pdfView.document,
      let page = visiblePage(in: pdfView)
    else { return nil }
    let box = page.bounds(for: .cropBox)
    guard box.width > 0, box.height > 0 else { return nil }

    let visibleInPage = pdfView.convert(pdfView.bounds, to: page)
    let visibleRect = PortalGeometry.normalized(rect: visibleInPage, in: box)

    let viewCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
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

  /// Restore exact viewport via PDFKit `go(to:on:)` — no scroll-offset math.
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

    // One layout-settled apply only (avoids the old Destination + centerVisible double walk).
    let work = DispatchWorkItem { [weak pdfView] in
      guard let pdfView else { return }
      pdfView.autoScales = false
      pdfView.scaleFactor = scale
      pdfView.layoutIfNeeded()
      pdfView.go(to: pageRect, on: page)
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
    let viewPoint = CGPoint(
      x: pdfView.bounds.midX,
      y: backward ? pdfView.bounds.maxY - 2 : pdfView.bounds.minY + 2
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
