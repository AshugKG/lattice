import AppKit
import LatticeCore
import PDFKit

@MainActor
final class LatticeWindowController: NSWindowController, NSSearchFieldDelegate {
  private let pdfView = LatticePDFView()
  private let portalOverlay = PortalOverlayView()
  private let filenameLabel = NSTextField(labelWithString: "No document open")
  private let pageLabel = NSTextField(labelWithString: "— / —")
  private let scaleLabel = NSTextField(labelWithString: "100%")
  private let emptyLabel = NSTextField(labelWithString: "Drop a PDF here, or choose Open")
  private let searchField = NSSearchField()
  private var descriptor: DocumentDescriptor?
  private var portalDraft: PortalAnchor?
  private var sessionPortals: [Portal] = []
  private var observers: [NSObjectProtocol] = []
  private var fingerprintGeneration = UUID()

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Lattice"
    window.titlebarAppearsTransparent = true
    window.minSize = NSSize(width: 720, height: 520)
    window.center()
    super.init(window: window)
    configureUI()
    observePDFView()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func presentOpenPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window!) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.openDocument(at: url)
    }
  }

  func openDocument(at url: URL) {
    guard url.pathExtension.lowercased() == "pdf" else {
      showError(title: "Not a PDF", message: "Choose a file with the .pdf extension.")
      return
    }
    guard let document = PDFDocument(url: url) else {
      showError(
        title: "Could not open this PDF",
        message: "The document is missing, unreadable, or malformed.")
      return
    }
    if document.isLocked, !unlock(document: document, named: url.lastPathComponent) { return }

    descriptor = nil
    portalDraft = nil
    portalOverlay.documentFingerprint = nil
    pdfView.document = document
    pdfView.autoScales = true
    emptyLabel.isHidden = true
    filenameLabel.stringValue = url.lastPathComponent
    window?.title = "\(url.lastPathComponent) — Lattice"
    updatePageAndScale()
    window?.makeFirstResponder(pdfView)

    let pageCount = document.pageCount
    let generation = UUID()
    fingerprintGeneration = generation
    Task.detached(priority: .utility) {
      let fingerprint = try? DocumentFingerprint.sha256(of: url)
      await MainActor.run { [weak self] in
        guard let self, self.fingerprintGeneration == generation else { return }
        let descriptor = DocumentDescriptor(
          fingerprint: fingerprint ?? "\(url.lastPathComponent):\(pageCount)",
          url: url,
          name: url.lastPathComponent,
          pageCount: pageCount
        )
        self.descriptor = descriptor
        self.portalOverlay.documentFingerprint = descriptor.fingerprint
      }
    }
  }

  @objc func focusSearch(_ sender: Any?) {
    window?.makeFirstResponder(searchField)
  }

  func controlTextDidChange(_ obj: Notification) {
    let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty,
      let result = pdfView.document?.findString(query, withOptions: [.caseInsensitive]).first
    else {
      pdfView.setCurrentSelection(nil, animate: false)
      return
    }
    pdfView.setCurrentSelection(result, animate: true)
    pdfView.go(to: result)
  }

  private func configureUI() {
    guard let window else { return }
    let root = NSView()
    root.wantsLayer = true
    window.contentView = root

    let toolbar = NSVisualEffectView()
    toolbar.material = .headerView
    toolbar.blendingMode = .withinWindow
    toolbar.state = .active
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    pdfView.translatesAutoresizingMaskIntoConstraints = false
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.displaysPageBreaks = true
    pdfView.pageShadowsEnabled = true
    pdfView.minScaleFactor = 0.25
    pdfView.maxScaleFactor = 4.0
    pdfView.backgroundColor = .windowBackgroundColor
    pdfView.onOpen = { [weak self] in self?.presentOpenPanel() }
    pdfView.onHelp = { [weak self] in self?.showShortcutHelp() }
    pdfView.onFind = { [weak self] in self?.focusSearch(nil) }
    pdfView.onCapturePortal = { [weak self] in self?.capturePortalEndpoint() }
    pdfView.onDropPDF = { [weak self] url in self?.openDocument(at: url) }
    pdfView.onViewportChanged = { [weak self] in self?.portalOverlay.needsDisplay = true }

    portalOverlay.translatesAutoresizingMaskIntoConstraints = false
    portalOverlay.pdfView = pdfView
    pdfView.addSubview(portalOverlay)

    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyLabel.font = .systemFont(ofSize: 17, weight: .medium)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center

    let openButton = button(symbol: "folder", label: "Open", action: #selector(openPressed(_:)))
    let zoomOut = button(symbol: "minus", label: nil, action: #selector(zoomOutPressed(_:)))
    let zoomIn = button(symbol: "plus", label: nil, action: #selector(zoomInPressed(_:)))
    let fit = button(
      symbol: "arrow.up.left.and.arrow.down.right", label: nil, action: #selector(fitPressed(_:)))
    let help = button(symbol: "questionmark.circle", label: nil, action: #selector(helpPressed(_:)))

    searchField.placeholderString = "Search"
    searchField.delegate = self
    searchField.widthAnchor.constraint(equalToConstant: 160).isActive = true

    filenameLabel.lineBreakMode = .byTruncatingMiddle
    filenameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    pageLabel.textColor = .secondaryLabelColor
    pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    scaleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let stack = NSStackView(views: [
      openButton, filenameLabel, pageLabel, spacer, searchField, zoomOut, scaleLabel, zoomIn, fit,
      help,
    ])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(stack)
    root.addSubview(toolbar)
    root.addSubview(pdfView)
    root.addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: root.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 52),
      stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
      stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      filenameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
      pdfView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      portalOverlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
      portalOverlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
      portalOverlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
      portalOverlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
    ])
  }

  private func observePDFView() {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .PDFViewPageChanged,
        object: pdfView,
        queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.updatePageAndScale() } })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .PDFViewScaleChanged,
        object: pdfView,
        queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.updatePageAndScale() } })
  }

  private func unlock(document: PDFDocument, named name: String) -> Bool {
    while document.isLocked {
      let alert = NSAlert()
      alert.messageText = "Password required"
      alert.informativeText = name
      alert.addButton(withTitle: "Unlock")
      alert.addButton(withTitle: "Cancel")
      let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
      password.placeholderString = "Password"
      alert.accessoryView = password
      guard alert.runModal() == .alertFirstButtonReturn else { return false }
      if document.unlock(withPassword: password.stringValue) { break }
      NSSound.beep()
      alert.informativeText = "Incorrect password. Try again."
    }
    return !document.isLocked
  }

  private func updatePageAndScale() {
    guard let document = pdfView.document else {
      pageLabel.stringValue = "— / —"
      scaleLabel.stringValue = "100%"
      return
    }
    let page = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
    pageLabel.stringValue = "\(page) / \(document.pageCount)"
    scaleLabel.stringValue = "\(Int((pdfView.scaleFactor * 100).rounded()))%"
    portalOverlay.needsDisplay = true
  }

  @objc private func openPressed(_ sender: Any?) { presentOpenPanel() }
  @objc private func zoomOutPressed(_ sender: Any?) {
    pdfView.autoScales = false
    pdfView.scaleFactor = max(pdfView.minScaleFactor, pdfView.scaleFactor - 0.15)
  }
  @objc private func zoomInPressed(_ sender: Any?) {
    pdfView.autoScales = false
    pdfView.scaleFactor = min(pdfView.maxScaleFactor, pdfView.scaleFactor + 0.15)
  }
  @objc private func fitPressed(_ sender: Any?) { pdfView.autoScales = true }
  @objc private func helpPressed(_ sender: Any?) { showShortcutHelp() }

  private func showShortcutHelp() {
    let alert = NSAlert()
    alert.messageText = "Lattice shortcuts"
    alert.informativeText = """
      o / ⌘O  Open PDF       j k  Scroll vertically
      h l     Scroll sideways  ⌃d ⌃u  Half screen
      gg / G  Start / end      [ ]  Previous / next page
      + −     Zoom             0  Fit width
      ⌘F      Search           ?  This help
      p       Capture source/destination portal endpoint
      """
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  private func capturePortalEndpoint() {
    guard let descriptor,
      let selection = pdfView.currentSelection,
      let anchor = portalOverlay.anchor(from: selection, descriptor: descriptor)
    else {
      showError(
        title: "Select text first",
        message: "Select a passage, then press p to capture a portal endpoint.")
      return
    }

    if let source = portalDraft {
      let portal = Portal(source: source, destination: anchor)
      sessionPortals.append(portal)
      portalDraft = nil
      portalOverlay.anchors = sessionPortals.flatMap { [$0.source, $0.destination] }
      filenameLabel.stringValue = "Portal created · \(sessionPortals.count) this session"
    } else {
      portalDraft = anchor
      portalOverlay.anchors = sessionPortals.flatMap { [$0.source, $0.destination] } + [anchor]
      filenameLabel.stringValue = "Portal source captured · select a destination and press p"
    }
  }

  private func showError(title: String, message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
  }

  private func button(symbol: String, label: String?, action: Selector) -> NSButton {
    let button = NSButton(title: label ?? "", target: self, action: action)
    button.bezelStyle = .texturedRounded
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.imagePosition = label == nil ? .imageOnly : .imageLeading
    return button
  }
}
