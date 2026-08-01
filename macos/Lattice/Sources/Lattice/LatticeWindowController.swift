import AppKit
import LatticeCore
import PDFKit

@MainActor
final class LatticeWindowController: NSWindowController, NSSearchFieldDelegate {
  private let pdfView = LatticePDFView()
  private let portalOverlay = PortalOverlayView()
  private let previewCard = PortalPreviewCard(frame: .zero)
  private let portalRepository = PortalRepository()
  private let previewRenderer = PortalPreviewRenderer()
  private let filenameLabel = NSTextField(labelWithString: "No document open")
  private let pageLabel = NSTextField(labelWithString: "— / —")
  private let scaleLabel = NSTextField(labelWithString: "100%")
  private let emptyLabel = NSTextField(labelWithString: "Drop a PDF here, or choose Open")
  private let searchField = NSSearchField()
  private let rootView = NSView()

  private var descriptor: DocumentDescriptor?
  private var portalDraft: PortalAnchor?
  private var portals: [Portal] = []
  private var jumpList = JumpList()
  private var observers: [NSObjectProtocol] = []
  private var scrollBoundsObserver: NSObjectProtocol?
  private var fingerprintGeneration = UUID()
  private var hoverWorkItem: DispatchWorkItem?
  private var hoveredPortalID: UUID?
  private var hoveredEndpoint: PortalEndpoint?
  private var searchOriginRecorded = false

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
    window.acceptsMouseMovedEvents = true
    window.center()
    super.init(window: window)
    configureUI()
    observePDFView()
    loadPortals()
  }

  required init?(coder: NSCoder) { nil }

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

  func openDocument(
    at url: URL,
    recordJump: Bool = true,
    completion: (@MainActor (DocumentDescriptor) -> Void)? = nil
  ) {
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

    if recordJump { recordCurrentBeforeJump() }
    if portalOverlay.captureMode == .inactive { portalDraft = nil }
    descriptor = nil
    portalOverlay.documentFingerprint = nil
    hidePreview()
    pdfView.document = document
    pdfView.autoScales = true
    installScrollObservation()
    DispatchQueue.main.async { [weak self] in self?.installScrollObservation() }
    emptyLabel.isHidden = true
    filenameLabel.stringValue = url.lastPathComponent
    window?.title = "\(url.lastPathComponent) — Lattice"
    updatePageAndScale()
    window?.makeFirstResponder(pdfView)

    let pageCount = document.pageCount
    let generation = UUID()
    fingerprintGeneration = generation
    Task { [weak self] in
      let fingerprint = await Task.detached(priority: .utility) {
        try? DocumentFingerprint.sha256(of: url)
      }.value
      guard let self, self.fingerprintGeneration == generation else { return }
      let descriptor = DocumentDescriptor(
        fingerprint: fingerprint ?? "\(url.lastPathComponent):\(pageCount)",
        url: url,
        name: url.lastPathComponent,
        pageCount: pageCount
      )
      self.descriptor = descriptor
      self.portalOverlay.documentFingerprint = descriptor.fingerprint
      self.portalOverlay.portals = self.portals
      completion?(descriptor)
    }
  }

  @objc func focusSearch(_ sender: Any?) {
    window?.makeFirstResponder(searchField)
  }

  func controlTextDidBeginEditing(_ obj: Notification) {
    searchOriginRecorded = false
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    searchOriginRecorded = false
  }

  func controlTextDidChange(_ obj: Notification) {
    let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty,
      let result = pdfView.document?.findString(query, withOptions: [.caseInsensitive]).first
    else {
      pdfView.setCurrentSelection(nil, animate: false)
      return
    }
    if !searchOriginRecorded {
      recordCurrentBeforeJump()
      searchOriginRecorded = true
    }
    pdfView.setCurrentSelection(result, animate: true)
    pdfView.go(to: result)
  }

  private func configureUI() {
    guard let window else { return }
    rootView.wantsLayer = true
    window.contentView = rootView

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
    pdfView.onCapturePortal = { [weak self] in self?.beginPortalCapture() }
    pdfView.onNonLocalCommand = { [weak self] command in self?.handleNonLocalCommand(command) }
    pdfView.onDropPDF = { [weak self] url in self?.openDocument(at: url) }
    pdfView.onViewportChanged = { [weak self] in
      self?.portalOverlay.viewportDidChange()
    }

    portalOverlay.translatesAutoresizingMaskIntoConstraints = false
    portalOverlay.pdfView = pdfView
    portalOverlay.onBoxCaptured = { [weak self] box in self?.capture(box) }
    portalOverlay.onActivatePortal = { [weak self] portal in self?.activate(portal) }
    portalOverlay.onDeletePortal = { [weak self] id in self?.deletePortal(id) }
    portalOverlay.onHoverPortal = { [weak self] target in self?.hover(target) }
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
    rootView.addSubview(toolbar)
    rootView.addSubview(pdfView)
    rootView.addSubview(emptyLabel)
    rootView.addSubview(previewCard)

    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: rootView.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 52),
      stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
      stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      filenameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
      pdfView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      pdfView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      pdfView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
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
        forName: .PDFViewPageChanged, object: pdfView, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.updatePageAndScale() } })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .PDFViewScaleChanged, object: pdfView, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.updatePageAndScale() } })
  }

  private func installScrollObservation() {
    if let scrollBoundsObserver {
      NotificationCenter.default.removeObserver(scrollBoundsObserver)
      self.scrollBoundsObserver = nil
    }
    guard let clipView = pdfView.scrollView?.contentView else { return }
    clipView.postsBoundsChangedNotifications = true
    scrollBoundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: clipView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.portalOverlay.viewportDidChange()
      }
    }
  }

  private func loadPortals() {
    do {
      portals = try portalRepository.load()
      portalOverlay.portals = portals
    } catch {
      portals = []
      portalOverlay.portals = []
      showError(
        title: "Portal data could not be loaded",
        message: "The invalid data was moved aside. New portals can still be created.")
    }
  }

  private func savePortals() {
    do {
      try portalRepository.save(portals)
    } catch {
      showError(
        title: "Portal could not be saved",
        message: "It will remain available for this session only.")
    }
    portalOverlay.portals = portals
  }

  private func beginPortalCapture() {
    guard descriptor != nil else {
      showError(
        title: "Open a PDF first", message: "Open a PDF, press p, then drag the source box.")
      return
    }
    guard portalOverlay.captureMode == .inactive else { return }
    portalDraft = nil
    portalOverlay.captureMode = .source
    hidePreview()
    filenameLabel.stringValue = "Portal source · drag a box · Esc cancels"
  }

  private func capture(_ box: CapturedPortalBox) {
    guard let descriptor else {
      NSSound.beep()
      return
    }
    let anchor = PortalAnchor(
      documentFingerprint: descriptor.fingerprint,
      documentPath: descriptor.url.path,
      pageIndex: box.pageIndex,
      bounds: box.bounds,
      quotedText: box.quotedText
    )
    switch portalOverlay.captureMode {
    case .source:
      portalDraft = anchor
      portalOverlay.captureMode = .destination
      filenameLabel.stringValue = "Portal destination · navigate or open a PDF, then drag a box"
    case .destination:
      guard let source = portalDraft else {
        cancelPortalCapture()
        return
      }
      portals.append(Portal(source: source, destination: anchor))
      portalDraft = nil
      portalOverlay.captureMode = .inactive
      savePortals()
      filenameLabel.stringValue = "Portal created · \(portals.count) total"
    case .inactive:
      break
    }
  }

  private func cancelPortalCapture() {
    guard portalOverlay.captureMode != .inactive else { return }
    portalDraft = nil
    portalOverlay.captureMode = .inactive
    filenameLabel.stringValue = descriptor?.name ?? "No document open"
  }

  private func deletePortal(_ id: UUID) {
    portals.removeAll { $0.id == id }
    if hoveredPortalID == id { hidePreview() }
    savePortals()
  }

  private func hover(_ target: PortalHoverTarget?) {
    hoverWorkItem?.cancel()
    guard let target else {
      hidePreview()
      return
    }
    let portal = target.portal
    let previewAnchor =
      target.endpoint == .source ? portal.destination : portal.source
    hoveredPortalID = portal.id
    hoveredEndpoint = target.endpoint
    let title =
      "\(URL(fileURLWithPath: previewAnchor.documentPath).lastPathComponent) · page \(previewAnchor.pageIndex + 1)"
    previewCard.showLoading(title: title)
    placePreview(beside: target.rect)
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.hoveredPortalID == portal.id,
        self.hoveredEndpoint == target.endpoint
      else { return }
      let appearance =
        self.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? "dark" : "light"
      let key = PreviewCacheKey(
        fingerprint: previewAnchor.documentFingerprint,
        pageIndex: previewAnchor.pageIndex,
        bounds: previewAnchor.bounds,
        backingScale: Double(self.window?.backingScaleFactor ?? 2),
        appearance: appearance
      )
      self.previewRenderer.render(anchor: previewAnchor, key: key) { [weak self] result in
        guard let self, self.hoveredPortalID == portal.id,
          self.hoveredEndpoint == target.endpoint
        else { return }
        switch result {
        case .image(let image): self.previewCard.show(image: image, title: title)
        case .unavailable(let message): self.previewCard.showUnavailable(message, title: title)
        }
        self.placePreview(beside: target.rect)
      }
    }
    hoverWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  private func hidePreview() {
    hoverWorkItem?.cancel()
    hoverWorkItem = nil
    hoveredPortalID = nil
    hoveredEndpoint = nil
    previewCard.isHidden = true
  }

  private func placePreview(beside overlayRect: NSRect) {
    let source = rootView.convert(overlayRect, from: portalOverlay)
    let size = NSSize(width: 440, height: 300)
    var x = source.maxX + 12
    if x + size.width > rootView.bounds.maxX - 12 { x = source.minX - size.width - 12 }
    x = min(max(12, x), max(12, rootView.bounds.maxX - size.width - 12))
    let y = min(
      max(12, source.midY - size.height / 2), max(12, rootView.bounds.maxY - size.height - 12))
    previewCard.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
  }

  private func activate(_ portal: Portal) {
    hidePreview()
    let target = portal.destination
    if descriptor?.fingerprint == target.documentFingerprint {
      recordCurrentBeforeJump()
      pdfView.go(to: target, scale: pdfView.scaleFactor)
      flashArrival(target)
      return
    }
    resolveURL(for: target) { [weak self] url in
      guard let self else { return }
      self.recordCurrentBeforeJump()
      self.openDocument(at: url, recordJump: false) { descriptor in
        guard descriptor.fingerprint == target.documentFingerprint else {
          self.locate(anchor: target)
          return
        }
        self.pdfView.autoScales = true
        self.pdfView.go(to: target)
        self.flashArrival(target)
      }
    }
  }

  private func resolveURL(for anchor: PortalAnchor, completion: @escaping (URL) -> Void) {
    let url = URL(fileURLWithPath: anchor.documentPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      locate(anchor: anchor, completion: completion)
      return
    }
    Task { [weak self] in
      let matches = await Task.detached(priority: .utility) {
        (try? DocumentFingerprint.sha256(of: url)) == anchor.documentFingerprint
      }.value
      guard let self else { return }
      matches ? completion(url) : self.locate(anchor: anchor, completion: completion)
    }
  }

  private func locate(anchor: PortalAnchor, completion: ((URL) -> Void)? = nil) {
    let panel = NSOpenPanel()
    panel.message = "Locate \(URL(fileURLWithPath: anchor.documentPath).lastPathComponent)"
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window!) { [weak self] response in
      guard let self, response == .OK, let url = panel.url else { return }
      Task { [weak self] in
        let matches = await Task.detached(priority: .utility) {
          (try? DocumentFingerprint.sha256(of: url)) == anchor.documentFingerprint
        }.value
        guard let self else { return }
        guard matches else {
          self.showError(
            title: "Different PDF",
            message: "The selected file does not match this portal destination.")
          return
        }
        self.portals = self.portals.map {
          $0.replacingDocumentPath(for: anchor.documentFingerprint, with: url.path)
        }
        self.savePortals()
        completion?(url)
      }
    }
  }

  private func flashArrival(_ anchor: PortalAnchor) {
    portalOverlay.arrivalAnchorID = anchor.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
      if self?.portalOverlay.arrivalAnchorID == anchor.id {
        self?.portalOverlay.arrivalAnchorID = nil
      }
    }
  }

  private func recordCurrentBeforeJump() {
    guard let descriptor, let location = pdfView.currentJumpLocation(descriptor: descriptor) else {
      return
    }
    jumpList.recordBeforeJump(location)
  }

  private func handleNonLocalCommand(_ command: ReaderCommand) {
    switch command {
    case .cancelPortal:
      cancelPortalCapture()
    case .jumpBackward:
      guard let descriptor, let current = pdfView.currentJumpLocation(descriptor: descriptor),
        let target = jumpList.goBackward(from: current)
      else { return }
      restore(target)
    case .jumpForward:
      guard let descriptor, let current = pdfView.currentJumpLocation(descriptor: descriptor),
        let target = jumpList.goForward(from: current)
      else { return }
      restore(target)
    case .documentStart, .documentEnd, .nextPage, .previousPage:
      recordCurrentBeforeJump()
      switch command {
      case .documentStart:
        if let page = pdfView.document?.page(at: 0) { pdfView.go(to: page) }
      case .documentEnd:
        if let document = pdfView.document, let page = document.page(at: document.pageCount - 1) {
          pdfView.go(to: page)
        }
      case .nextPage: pdfView.goToNextPage(nil)
      case .previousPage: pdfView.goToPreviousPage(nil)
      default: break
      }
    default:
      break
    }
  }

  private func restore(_ location: JumpLocation) {
    if descriptor?.fingerprint == location.documentFingerprint {
      pdfView.restore(location)
      return
    }
    let anchor = PortalAnchor(
      documentFingerprint: location.documentFingerprint,
      documentPath: location.documentPath,
      pageIndex: location.pageIndex,
      bounds: NormalizedRect(
        x: max(0, location.viewportCenter.x - 0.001),
        y: max(0, location.viewportCenter.y - 0.001),
        width: 0.002,
        height: 0.002
      )
    )
    resolveURL(for: anchor) { [weak self] url in
      self?.openDocument(at: url, recordJump: false) { descriptor in
        guard descriptor.fingerprint == location.documentFingerprint else { return }
        self?.pdfView.restore(location)
      }
    }
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
      ⌘F      Search           p  Create box portal
      ⌃O / ⌃I Back / forward jump     Esc  Cancel portal
      """
    alert.addButton(withTitle: "Done")
    alert.runModal()
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
