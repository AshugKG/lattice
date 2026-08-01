import AppKit
import LatticeCore
import PDFKit

@MainActor
final class LatticeWindowController: NSWindowController, NSSearchFieldDelegate, NSWindowDelegate {
  private let pdfView = LatticePDFView()
  private let markOverlay = MarkOverlayView()
  private let previewCard = MarkPreviewCard(frame: .zero)
  private let commandPalette = CommandPaletteView(frame: .zero)
  private let marksView = MarksListView(frame: .zero)
  private let markRepository = MarkRepository()
  private let readingStateRepository = ReadingStateRepository()
  private let previewRenderer = MarkPreviewRenderer()
  private let filenameLabel = NSTextField(labelWithString: "No document open")
  private let pageLabel = NSTextField(labelWithString: "— / —")
  private let scaleLabel = NSTextField(labelWithString: "100%")
  private let emptyLabel = NSTextField(labelWithString: "Drop a PDF here, or choose Open")
  private let searchField = NSSearchField()
  private let rootView = NSView()

  private var descriptor: DocumentDescriptor?
  private var markDraft: MarkAnchor?
  private var marks: [Mark] = []
  private var readingPositions: [String: ReadingPosition] = [:]
  private var jumpList = JumpList()
  private var observers: [NSObjectProtocol] = []
  private var scrollBoundsObserver: NSObjectProtocol?
  private var fingerprintGeneration = UUID()
  private var hoverWorkItem: DispatchWorkItem?
  private var readingSaveWorkItem: DispatchWorkItem?
  private var hoveredMarkID: UUID?
  private var hoveredEndpoint: MarkEndpoint?
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
    window.delegate = self
    configureUI()
    observePDFView()
    loadMarks()
    loadReadingState()
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
    resumeReadingPosition: Bool = true,
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

    if !commandPalette.isHidden { commandPalette.dismiss() }
    if !marksView.isHidden { marksView.dismiss() }
    persistCurrentReadingPosition()
    if recordJump { recordCurrentBeforeJump() }
    if markOverlay.captureMode == .inactive { markDraft = nil }
    descriptor = nil
    markOverlay.documentFingerprint = nil
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
      self.markOverlay.documentFingerprint = descriptor.fingerprint
      self.markOverlay.marks = self.marks
      if resumeReadingPosition, let saved = self.readingPositions[descriptor.fingerprint] {
        self.pdfView.restore(saved.location.clamped(pageCount: descriptor.pageCount))
      }
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
    pdfView.onCaptureMark = { [weak self] in self?.beginMarkCapture() }
    pdfView.onNonLocalCommand = { [weak self] command in self?.handleNonLocalCommand(command) }
    pdfView.onDropPDF = { [weak self] url in self?.openDocument(at: url) }
    pdfView.onViewportChanged = { [weak self] in
      self?.markOverlay.viewportDidChange()
      self?.scheduleReadingPositionSave()
    }

    markOverlay.translatesAutoresizingMaskIntoConstraints = false
    markOverlay.pdfView = pdfView
    markOverlay.onBoxCaptured = { [weak self] box in self?.capture(box) }
    markOverlay.onActivateMark = { [weak self] target in self?.activate(target) }
    markOverlay.onDeleteMark = { [weak self] id in self?.deleteMark(id) }
    markOverlay.onHoverMark = { [weak self] target in self?.hover(target) }
    pdfView.addSubview(markOverlay)

    commandPalette.translatesAutoresizingMaskIntoConstraints = false
    commandPalette.onExecute = { [weak self] command in
      guard let self else { return }
      self.window?.makeFirstResponder(self.pdfView)
      self.pdfView.execute(command.action)
    }
    commandPalette.onDismiss = { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self.pdfView)
    }

    marksView.translatesAutoresizingMaskIntoConstraints = false
    marksView.onActivate = { [weak self] mark in self?.activate(mark) }
    marksView.onDismiss = { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self.pdfView)
    }

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
    rootView.addSubview(commandPalette)
    rootView.addSubview(marksView)

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
      markOverlay.topAnchor.constraint(equalTo: pdfView.topAnchor),
      markOverlay.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
      markOverlay.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
      markOverlay.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
      commandPalette.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      commandPalette.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
      commandPalette.widthAnchor.constraint(equalToConstant: 640),
      commandPalette.heightAnchor.constraint(equalToConstant: 300),
      marksView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      marksView.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
      marksView.widthAnchor.constraint(equalToConstant: 680),
      marksView.heightAnchor.constraint(equalToConstant: 420),
    ])
  }

  private func observePDFView() {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .PDFViewPageChanged, object: pdfView, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.updatePageAndScale()
          self?.scheduleReadingPositionSave()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .PDFViewScaleChanged, object: pdfView, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.updatePageAndScale()
          self?.scheduleReadingPositionSave()
        }
      })
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
        self.markOverlay.viewportDidChange()
        self.scheduleReadingPositionSave()
      }
    }
  }

  private func loadMarks() {
    do {
      marks = try markRepository.load()
      markOverlay.marks = marks
    } catch {
      marks = []
      markOverlay.marks = []
      showError(
        title: "Mark data could not be loaded",
        message: "The invalid data was moved aside. New marks can still be created.")
    }
  }

  private func saveMarks() {
    do {
      try markRepository.save(marks)
    } catch {
      showError(
        title: "Mark could not be saved",
        message: "It will remain available for this session only.")
    }
    markOverlay.marks = marks
  }

  private func loadReadingState() {
    do {
      readingPositions = try readingStateRepository.load()
    } catch {
      readingPositions = [:]
      showError(
        title: "Reading state could not be loaded",
        message: "The invalid data was moved aside. Reading positions will be saved again.")
    }
  }

  private func scheduleReadingPositionSave() {
    guard descriptor != nil else { return }
    readingSaveWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.persistCurrentReadingPosition() }
    readingSaveWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  func persistCurrentReadingPosition() {
    readingSaveWorkItem?.cancel()
    readingSaveWorkItem = nil
    guard let descriptor, let location = pdfView.currentJumpLocation(descriptor: descriptor) else {
      return
    }
    readingPositions[descriptor.fingerprint] = ReadingPosition(location: location)
    do {
      try readingStateRepository.save(readingPositions)
    } catch {
      showError(
        title: "Reading position could not be saved",
        message: "Lattice will try again the next time the viewport changes.")
    }
  }

  func windowWillClose(_ notification: Notification) {
    persistCurrentReadingPosition()
  }

  private func beginMarkCapture() {
    guard descriptor != nil else {
      showError(
        title: "Open a PDF first", message: "Open a PDF, press m, then drag the source box.")
      return
    }
    guard markOverlay.captureMode == .inactive else { return }
    markDraft = nil
    markOverlay.captureMode = .source
    hidePreview()
    filenameLabel.stringValue = "Mark source · drag a box · Esc cancels"
  }

  private func capture(_ box: CapturedMarkBox) {
    guard let descriptor else {
      NSSound.beep()
      return
    }
    let anchor = MarkAnchor(
      documentFingerprint: descriptor.fingerprint,
      documentPath: descriptor.url.path,
      pageIndex: box.pageIndex,
      bounds: box.bounds,
      quotedText: box.quotedText
    )
    switch markOverlay.captureMode {
    case .source:
      markDraft = anchor
      markOverlay.captureMode = .destination
      filenameLabel.stringValue = "Mark destination · navigate or open a PDF, then drag a box"
    case .destination:
      guard let source = markDraft else {
        cancelMarkCapture()
        return
      }
      marks.append(Mark(source: source, destination: anchor))
      markDraft = nil
      markOverlay.captureMode = .inactive
      saveMarks()
      filenameLabel.stringValue = "Mark created · \(marks.count) total"
    case .inactive:
      break
    }
  }

  private func cancelMarkCapture() {
    guard markOverlay.captureMode != .inactive else { return }
    markDraft = nil
    markOverlay.captureMode = .inactive
    filenameLabel.stringValue = descriptor?.name ?? "No document open"
  }

  private func deleteMark(_ id: UUID) {
    marks.removeAll { $0.id == id }
    if hoveredMarkID == id { hidePreview() }
    saveMarks()
  }

  private func hover(_ target: MarkInteractionTarget?) {
    hoverWorkItem?.cancel()
    guard let target else {
      hidePreview()
      return
    }
    let mark = target.mark
    let previewAnchor =
      target.endpoint == .source ? mark.destination : mark.source
    hoveredMarkID = mark.id
    hoveredEndpoint = target.endpoint
    let title =
      "\(URL(fileURLWithPath: previewAnchor.documentPath).lastPathComponent) · page \(previewAnchor.pageIndex + 1)"
    previewCard.showLoading(title: title)
    placePreview(beside: target.rect)
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.hoveredMarkID == mark.id,
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
        guard let self, self.hoveredMarkID == mark.id,
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
    hoveredMarkID = nil
    hoveredEndpoint = nil
    previewCard.isHidden = true
  }

  private func placePreview(beside overlayRect: NSRect) {
    let source = rootView.convert(overlayRect, from: markOverlay)
    let size = NSSize(width: 440, height: 300)
    var x = source.maxX + 12
    if x + size.width > rootView.bounds.maxX - 12 { x = source.minX - size.width - 12 }
    x = min(max(12, x), max(12, rootView.bounds.maxX - size.width - 12))
    let y = min(
      max(12, source.midY - size.height / 2), max(12, rootView.bounds.maxY - size.height - 12))
    previewCard.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
  }

  private func activate(_ interaction: MarkInteractionTarget) {
    hidePreview()
    let target = interaction.mark.oppositeAnchor(from: interaction.endpoint)
    if descriptor?.fingerprint == target.documentFingerprint {
      recordCurrentBeforeJump()
      pdfView.go(to: target, scale: pdfView.scaleFactor)
      flashArrival(target)
      return
    }
    resolveURL(for: target) { [weak self] url in
      guard let self else { return }
      self.recordCurrentBeforeJump()
      self.openDocument(
        at: url,
        recordJump: false,
        resumeReadingPosition: false
      ) { descriptor in
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

  private func activate(_ mark: MarkListEntry) {
    marksView.dismiss()
    guard descriptor?.fingerprint == mark.anchor.documentFingerprint else { return }
    recordCurrentBeforeJump()
    pdfView.go(to: mark.anchor, scale: pdfView.scaleFactor)
    flashArrival(mark.anchor)
  }

  private func showCommandPalette() {
    marksView.dismiss()
    hidePreview()
    commandPalette.present()
  }

  private func showMarks() {
    commandPalette.dismiss()
    hidePreview()
    let entries =
      descriptor.map { MarksIndex.entries(for: $0.fingerprint, marks: marks) } ?? []
    marksView.present(entries: entries)
  }

  private func resolveURL(for anchor: MarkAnchor, completion: @escaping (URL) -> Void) {
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

  private func locate(anchor: MarkAnchor, completion: ((URL) -> Void)? = nil) {
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
            message: "The selected file does not match this mark destination.")
          return
        }
        self.marks = self.marks.map {
          $0.replacingDocumentPath(for: anchor.documentFingerprint, with: url.path)
        }
        self.saveMarks()
        completion?(url)
      }
    }
  }

  private func flashArrival(_ anchor: MarkAnchor) {
    markOverlay.arrivalAnchorID = anchor.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
      if self?.markOverlay.arrivalAnchorID == anchor.id {
        self?.markOverlay.arrivalAnchorID = nil
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
    case .showCommandPalette:
      showCommandPalette()
    case .showMarks:
      showMarks()
    case .quit:
      NSApp.terminate(nil)
    case .cancelMark:
      cancelMarkCapture()
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
    let anchor = MarkAnchor(
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
      self?.openDocument(
        at: url,
        recordJump: false,
        resumeReadingPosition: false
      ) { descriptor in
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
    markOverlay.needsDisplay = true
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
      ⌘F      Search           m  Create box mark
      ⌃O / ⌃I Back / forward jump     Esc  Cancel mark
      :       Fuzzy commands   :marks  List marks
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
