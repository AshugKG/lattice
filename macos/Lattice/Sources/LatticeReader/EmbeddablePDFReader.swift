import AppKit
import PDFKit

/// Compact PDFKit host for embedding Lattice's reader in another macOS app (e.g. LeetMath).
@MainActor
public final class EmbeddablePDFReader: NSView {
  public let pdfView = LatticePDFView()

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
    pdfView.document = document
    pdfView.autoScales = true
    DispatchQueue.main.async { [weak self] in
      self?.pdfView.scrollProblemToTop(pageIndex: pageIndex, topY: topY)
    }
    return true
  }

  public func jump(pageIndex: Int, topY: Double) {
    pdfView.scrollProblemToTop(pageIndex: pageIndex, topY: topY)
  }
}
