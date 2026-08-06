import PDFKit
import SwiftUI
import UIKit

struct PDFKitView: UIViewRepresentable {
  let documentURL: URL?
  var controller: PDFController
  var portalOverlay: PortalOverlayView
  var onViewportChanged: () -> Void
  var onDocumentReady: (PDFDocument) -> Void

  func makeUIView(context: Context) -> UIView {
    let container = UIView()
    container.backgroundColor = .systemBackground

    let pdfView = PDFView()
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.usePageViewController(false)
    pdfView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(pdfView)

    portalOverlay.removeFromSuperview()
    portalOverlay.translatesAutoresizingMaskIntoConstraints = false
    portalOverlay.pdfView = pdfView
    container.addSubview(portalOverlay)

    NSLayoutConstraint.activate([
      pdfView.topAnchor.constraint(equalTo: container.topAnchor),
      pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      portalOverlay.topAnchor.constraint(equalTo: container.topAnchor),
      portalOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      portalOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      portalOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    controller.pdfView = pdfView
    context.coordinator.pdfView = pdfView
    context.coordinator.observe(pdfView)

    if let documentURL, let document = PDFDocument(url: documentURL) {
      pdfView.document = document
      onDocumentReady(document)
    }

    return container
  }

  func updateUIView(_ container: UIView, context: Context) {
    guard let pdfView = context.coordinator.pdfView else { return }
    controller.pdfView = pdfView
    portalOverlay.pdfView = pdfView

    let currentPath = pdfView.document?.documentURL?.path
    let newPath = documentURL?.path
    if currentPath != newPath {
      if let documentURL, let document = PDFDocument(url: documentURL) {
        pdfView.document = document
        onDocumentReady(document)
      } else {
        pdfView.document = nil
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onViewportChanged: onViewportChanged, portalOverlay: portalOverlay)
  }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    var pdfView: PDFView?
    private let onViewportChanged: @MainActor () -> Void
    private let portalOverlay: PortalOverlayView
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    init(
      onViewportChanged: @escaping @MainActor () -> Void,
      portalOverlay: PortalOverlayView
    ) {
      self.onViewportChanged = onViewportChanged
      self.portalOverlay = portalOverlay
    }

    deinit {
      for observer in observers {
        NotificationCenter.default.removeObserver(observer)
      }
    }

    @MainActor
    func observe(_ pdfView: PDFView) {
      for observer in observers {
        NotificationCenter.default.removeObserver(observer)
      }
      observers.removeAll()

      let center = NotificationCenter.default
      let names: [Notification.Name] = [
        .PDFViewPageChanged,
        .PDFViewScaleChanged,
        Notification.Name("PDFViewVisiblePagesChanged"),
      ]
      for name in names {
        observers.append(
          center.addObserver(forName: name, object: pdfView, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
              self.portalOverlay.viewportDidChange()
              self.onViewportChanged()
            }
          }
        )
      }

      if let scrollView = nestedScrollView(in: pdfView) {
        scrollView.delegate = self
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      Task { @MainActor in
        portalOverlay.viewportDidChange()
        onViewportChanged()
      }
    }

    private func nestedScrollView(in root: UIView) -> UIScrollView? {
      if let scroll = root as? UIScrollView { return scroll }
      for child in root.subviews {
        if let found = nestedScrollView(in: child) { return found }
      }
      return nil
    }
  }
}
