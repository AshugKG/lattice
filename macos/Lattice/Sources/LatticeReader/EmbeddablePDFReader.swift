import AppKit
import LatticeCore
import PDFKit

/// Compact PDFKit host for embedding Lattice's reader in another macOS app (e.g. LeetMath).
@MainActor
public final class EmbeddablePDFReader: NSView {
  public let pdfView = LatticePDFView()

  private var readingGuide: ReadingGuide = ReadingGuide(stops: [])
  private var excerptMode = false
  public private(set) var currentStopIndex: Int = 0

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.masksToBounds = true

    pdfView.translatesAutoresizingMaskIntoConstraints = false
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.displaysPageBreaks = true
    pdfView.pageShadowsEnabled = true
    pdfView.autoScales = true
    pdfView.minScaleFactor = 0.25
    pdfView.maxScaleFactor = 4
    pdfView.backgroundColor = .windowBackgroundColor

    addSubview(pdfView)
    NSLayoutConstraint.activate([
      pdfView.topAnchor.constraint(equalTo: topAnchor),
      pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
      pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  public required init?(coder: NSCoder) { nil }

  @discardableResult
  public func open(url: URL, pageIndex: Int = 0, topY: Double = 0) -> Bool {
    guard let document = PDFDocument(url: url) else { return false }
    excerptMode = false
    readingGuide = ReadingGuide(stops: [])
    currentStopIndex = 0
    pdfView.document = document
    pdfView.autoScales = true
    DispatchQueue.main.async { [weak self] in
      self?.pdfView.scrollProblemToTop(pageIndex: pageIndex, topY: topY)
    }
    return true
  }

  /// Builds a temporary PDF of tightly cropped bands — one excerpt page per reading stop.
  @discardableResult
  public func openReadingGuide(url: URL, guide: ReadingGuide, initialStopIndex: Int = 0) -> Bool {
    guard let source = PDFDocument(url: url) else { return false }
    guard !guide.stops.isEmpty else {
      return open(url: url)
    }

    let excerpt = PDFDocument()
    for stop in guide.stops {
      guard stop.pageIndex >= 0, stop.pageIndex < source.pageCount,
            let page = source.page(at: stop.pageIndex),
            let cropped = Self.croppedPage(from: page, topY: stop.topY, bottomY: stop.bottomY)
      else { continue }
      excerpt.insert(cropped, at: excerpt.pageCount)
    }
    guard excerpt.pageCount > 0 else { return false }

    excerptMode = true
    readingGuide = guide
    let start = min(max(0, initialStopIndex), guide.stops.count - 1)
    currentStopIndex = start
    pdfView.document = excerpt
    pdfView.autoScales = true
    // Capture intended stop — avoid racing a later goToStop by always jumping to `start`.
    DispatchQueue.main.async { [weak self] in
      self?.goToStop(at: start)
    }
    return true
  }

  public func jump(pageIndex: Int, topY: Double) {
    pdfView.scrollProblemToTop(pageIndex: pageIndex, topY: topY)
  }

  public func setReadingGuide(_ guide: ReadingGuide) {
    readingGuide = guide
    currentStopIndex = 0
    if !guide.isEmpty {
      goToStop(at: 0)
    }
  }

  public func clearReadingGuide() {
    readingGuide = ReadingGuide(stops: [])
    currentStopIndex = 0
    excerptMode = false
  }

  public func goToStop(at index: Int) {
    guard !readingGuide.stops.isEmpty else { return }
    let clamped = min(max(0, index), readingGuide.stops.count - 1)
    currentStopIndex = clamped
    if excerptMode {
      // Each stop maps 1:1 to an excerpt page (cropped already).
      let page = min(clamped, (pdfView.document?.pageCount ?? 1) - 1)
      pdfView.scrollProblemToTop(pageIndex: max(0, page), topY: 0)
    } else {
      let stop = readingGuide.stops[clamped]
      pdfView.scrollProblemToTop(pageIndex: stop.pageIndex, topY: stop.topY)
    }
  }

  @discardableResult
  public func nextStop() -> Bool {
    guard currentStopIndex + 1 < readingGuide.stops.count else { return false }
    goToStop(at: currentStopIndex + 1)
    return true
  }

  @discardableResult
  public func previousStop() -> Bool {
    guard currentStopIndex > 0 else { return false }
    goToStop(at: currentStopIndex - 1)
    return true
  }

  /// Extra normalized pad so glyph tops aren't flush with the crop edge.
  private static let cropPad: Double = 0.02

  /// Crops a page copy to the vertical band `[topY, bottomY]` (top-origin normalized).
  public static func croppedPage(from page: PDFPage, topY: Double, bottomY: Double) -> PDFPage? {
    let copy: PDFPage
    if let duplicated = page.copy() as? PDFPage {
      copy = duplicated
    } else {
      return nil
    }

    let box = copy.bounds(for: .mediaBox)
    guard box.width > 1, box.height > 1 else { return copy }

    let top = min(1, max(0, topY - cropPad))
    var bottom = min(1, max(0, bottomY + cropPad))
    if bottom <= top { bottom = min(1, top + 0.08) }
    if bottom <= top { return copy }

    // Top-origin → PDFKit bottom-origin crop box.
    let cropHeight = box.height * (bottom - top)
    let cropY = box.minY + box.height * (1 - bottom)
    let crop = CGRect(x: box.minX, y: cropY, width: box.width, height: cropHeight)
      .integral
    guard crop.height > 1 else { return copy }

    copy.setBounds(crop, for: .cropBox)
    copy.setBounds(crop, for: .mediaBox)
    return copy
  }
}
