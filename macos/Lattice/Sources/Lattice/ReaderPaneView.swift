import AppKit
import LatticeCore
import LatticeReader
import PDFKit

@MainActor
final class ReaderPaneView: NSView {
  let pdfView = LatticePDFView()
  let portalOverlay = PortalOverlayView()
  var descriptor: DocumentDescriptor?
  var openGeneration = UUID()

  var showsActiveChrome = false {
    didSet { updateActiveChrome() }
  }

  private(set) var isActivePane = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 0

    pdfView.translatesAutoresizingMaskIntoConstraints = false
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.displaysPageBreaks = true
    pdfView.pageShadowsEnabled = true
    pdfView.minScaleFactor = 0.25
    pdfView.maxScaleFactor = 4
    pdfView.backgroundColor = .windowBackgroundColor

    portalOverlay.translatesAutoresizingMaskIntoConstraints = false
    portalOverlay.pdfView = pdfView

    addSubview(pdfView)
    pdfView.addSubview(portalOverlay)
    NSLayoutConstraint.activate([
      pdfView.topAnchor.constraint(equalTo: topAnchor),
      pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
      pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
      portalOverlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
      portalOverlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
      portalOverlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
      portalOverlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
    ])
    updateActiveChrome()
  }

  required init?(coder: NSCoder) { nil }

  func setActivePane(_ active: Bool) {
    isActivePane = active
    updateActiveChrome()
  }

  private func updateActiveChrome() {
    wantsLayer = true
    if showsActiveChrome, isActivePane {
      layer?.borderWidth = 2
      layer?.borderColor = NSColor.controlAccentColor.cgColor
    } else {
      layer?.borderWidth = 0
      layer?.borderColor = nil
    }
  }
}
