import AppKit
import LatticeCore
import PDFKit

@MainActor
final class LatticeWindowController: NSWindowController, NSSearchFieldDelegate, NSWindowDelegate {
  private let primaryPane = ReaderPaneView()
  private let splitView = NSSplitView()
  private let previewCard = MarkPreviewCard(frame: .zero)
  private let commandPalette = CommandPaletteView(frame: .zero)
  private let searchPrompt = SearchPromptView(frame: .zero)
  private let marksView = MarksListView(frame: .zero)
  private let markRepository = MarkRepository()
  private let readingStateRepository = ReadingStateRepository()
  private let recentsRepository = RecentsRepository()
  private let previewRenderer = MarkPreviewRenderer()
  private let filenameLabel = NSTextField(labelWithString: "No document open")
  private let pageLabel = NSTextField(labelWithString: "— / —")
  private let scaleLabel = NSTextField(labelWithString: "100%")
  private let homeView = RecentsHomeView(frame: .zero)
  private let searchField = NSSearchField()
  private let rootView = NSView()

  private var secondaryPane: ReaderPaneView?
  private weak var selectedPane: ReaderPaneView?
  private var activePane: ReaderPaneView { selectedPane ?? primaryPane }
  private var pdfView: LatticePDFView { activePane.pdfView }
  private var markOverlay: MarkOverlayView { activePane.markOverlay }
  private var panes: [ReaderPaneView] {
    secondaryPane.map { [primaryPane, $0] } ?? [primaryPane]
  }
  private var activePaneKeyMonitor: Any?
  private var paneShortcutResolver = ShortcutResolver()

  private var descriptor: DocumentDescriptor?
  private var markDraft: MarkAnchor?
  private weak var capturePane: ReaderPaneView?
  private var marks: [Mark] = []
  private var readingPositions: [String: ReadingPosition] = [:]
  private var recents: [RecentDocument] = []
  private var jumpList = JumpList()
  private var observers: [NSObjectProtocol] = []
  private var scrollBoundsObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
  private var hoverWorkItem: DispatchWorkItem?
  private var readingSaveWorkItem: DispatchWorkItem?
  private var hoveredMarkID: UUID?
  private var hoveredEndpoint: MarkEndpoint?
  private var searchOriginRecorded = false
  private var lastSearchQuery = ""
  private var lastSearchDirection: SearchPromptView.Direction = .forward

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
    selectedPane = primaryPane
    configureUI()
    observePDFView(in: primaryPane)
    installActivePaneKeyMonitor()
    loadMarks()
    loadReadingState()
    loadRecents()
    selectPane(primaryPane)
    showHome()
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
    if recordJump { recordJumpListLocation() }
    let pendingCapture = currentMarkCaptureMode()
    if pendingCapture == .inactive { markDraft = nil }
    hidePreview()
    hideHome()

    let targetPane = activePane
    let pageCount = document.pageCount
    let knownFingerprint = readingPositions.first(where: {
      $0.value.location.documentPath == url.path
    })?.key
    let provisionalFingerprint = knownFingerprint ?? "pending:\(url.path)"
    let provisional = DocumentDescriptor(
      fingerprint: provisionalFingerprint,
      url: url,
      name: url.lastPathComponent,
      pageCount: pageCount
    )
    let generation = UUID()
    targetPane.openGeneration = generation
    targetPane.descriptor = provisional
    descriptor = provisional
    targetPane.markOverlay.documentFingerprint = provisional.fingerprint
    targetPane.markOverlay.marks = marks
    targetPane.pdfView.document = document
    targetPane.pdfView.autoScales = true
    installScrollObservation(in: targetPane)
    if pendingCapture != .inactive {
      targetPane.markOverlay.captureMode = pendingCapture
      capturePane = targetPane
      for pane in panes where pane !== targetPane {
        pane.markOverlay.captureMode = .inactive
      }
    }
    DispatchQueue.main.async { [weak self, weak targetPane] in
      guard let self, let targetPane else { return }
      self.installScrollObservation(in: targetPane)
    }
    window?.title = "\(url.lastPathComponent) — Lattice"
    updatePageAndScale()
    activatePane(targetPane)
    refreshMarkCaptureStatus()

    if resumeReadingPosition, let saved = readingPositions[provisional.fingerprint] {
      let location = saved.location.clamped(pageCount: pageCount)
      targetPane.pdfView.restore(location)
    }

    Task { [weak self, weak targetPane] in
      let fingerprint = await Task.detached(priority: .utility) {
        try? DocumentFingerprint.sha256(of: url)
      }.value
      guard let self, let targetPane else { return }
      let resolvedFingerprint = fingerprint ?? "\(url.lastPathComponent):\(pageCount)"
      let descriptor = DocumentDescriptor(
        fingerprint: resolvedFingerprint,
        url: url,
        name: url.lastPathComponent,
        pageCount: pageCount
      )
      guard targetPane.openGeneration == generation else {
        completion?(descriptor)
        return
      }
      targetPane.descriptor = descriptor
      if self.activePane === targetPane {
        self.descriptor = descriptor
      }
      targetPane.markOverlay.documentFingerprint = descriptor.fingerprint
      targetPane.markOverlay.marks = self.marks
      if descriptor.fingerprint != provisionalFingerprint {
        self.jumpList.rewriteFingerprint(
          from: provisionalFingerprint,
          to: descriptor.fingerprint,
          path: url.path
        )
        if let draft = self.markDraft,
          draft.documentFingerprint == provisionalFingerprint
            || (draft.documentPath == url.path
              && draft.documentFingerprint.hasPrefix("pending:"))
        {
          self.markDraft = MarkAnchor(
            id: draft.id,
            documentFingerprint: descriptor.fingerprint,
            documentPath: url.path,
            pageIndex: draft.pageIndex,
            bounds: draft.bounds,
            quotedText: draft.quotedText
          )
        }
      }
      if resumeReadingPosition,
        descriptor.fingerprint != provisionalFingerprint,
        let saved = self.readingPositions[descriptor.fingerprint]
      {
        let location = saved.location.clamped(pageCount: descriptor.pageCount)
        targetPane.pdfView.restore(location)
      }
      self.recordRecent(descriptor)
      if self.activePane === targetPane {
        self.refreshMarkCaptureStatus()
        self.window?.title = "\(descriptor.name) — Lattice"
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
    lastSearchQuery = query
    lastSearchDirection = .forward
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

    configureReaderPane(primaryPane)
    splitView.translatesAutoresizingMaskIntoConstraints = false
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    splitView.addArrangedSubview(primaryPane)

    commandPalette.translatesAutoresizingMaskIntoConstraints = false
    commandPalette.onExecute = { [weak self] command in
      guard let self else { return }
      self.activatePane(self.activePane)
      self.activePane.pdfView.execute(command.action)
    }
    commandPalette.onDismiss = { [weak self] in
      guard let self else { return }
      self.activatePane(self.activePane)
    }

    searchPrompt.translatesAutoresizingMaskIntoConstraints = false
    searchPrompt.onSearch = { [weak self] query, direction in
      guard let self else { return }
      self.activatePane(self.activePane)
      self.performSearch(query: query, direction: direction, wrap: true)
    }
    searchPrompt.onDismiss = { [weak self] in
      guard let self else { return }
      self.activatePane(self.activePane)
    }

    marksView.translatesAutoresizingMaskIntoConstraints = false
    marksView.onActivate = { [weak self] mark in self?.activate(mark) }
    marksView.onDismiss = { [weak self] in
      guard let self else { return }
      self.activatePane(self.activePane)
    }

    homeView.translatesAutoresizingMaskIntoConstraints = false
    homeView.onOpen = { [weak self] url in self?.openDocument(at: url) }
    homeView.onBrowse = { [weak self] in self?.presentOpenPanel() }

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
    rootView.addSubview(splitView)
    rootView.addSubview(homeView)
    rootView.addSubview(previewCard)
    rootView.addSubview(commandPalette)
    rootView.addSubview(searchPrompt)
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
      splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      splitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      splitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      splitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
      homeView.topAnchor.constraint(equalTo: splitView.topAnchor),
      homeView.leadingAnchor.constraint(equalTo: splitView.leadingAnchor),
      homeView.trailingAnchor.constraint(equalTo: splitView.trailingAnchor),
      homeView.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),
      commandPalette.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      commandPalette.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
      commandPalette.widthAnchor.constraint(equalToConstant: 640),
      commandPalette.heightAnchor.constraint(equalToConstant: 300),
      searchPrompt.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      searchPrompt.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
      searchPrompt.widthAnchor.constraint(equalToConstant: 420),
      searchPrompt.heightAnchor.constraint(equalToConstant: 44),
      marksView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      marksView.centerYAnchor.constraint(equalTo: splitView.centerYAnchor),
      marksView.widthAnchor.constraint(equalToConstant: 680),
      marksView.heightAnchor.constraint(equalToConstant: 420),
    ])
  }

  private func configureReaderPane(_ pane: ReaderPaneView) {
    let pdfView = pane.pdfView
    let markOverlay = pane.markOverlay
    pdfView.onBecameActive = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.activatePane(pane)
    }
    pdfView.onOpen = { [weak self] in self?.presentOpenPanel() }
    pdfView.onHelp = { [weak self] in self?.showShortcutHelp() }
    pdfView.onFind = { [weak self] in self?.focusSearch(nil) }
    pdfView.onCaptureMark = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.activatePane(pane)
      self.beginMarkCapture()
    }
    pdfView.onNonLocalCommand = { [weak self, weak pane] command in
      guard let self, let pane else { return }
      self.activatePane(pane)
      self.handleNonLocalCommand(command)
    }
    pdfView.onDropPDF = { [weak self, weak pane] url in
      guard let self, let pane else { return }
      self.activatePane(pane)
      self.openDocument(at: url)
    }
    pdfView.onViewportChanged = { [weak self, weak pane] in
      guard let self, let pane else { return }
      if self.selectedPane !== pane { self.activatePane(pane) }
      pane.markOverlay.viewportDidChange()
      self.scheduleReadingPositionSave()
    }
    pdfView.onWillFollowLink = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.activatePane(pane)
      self.recordCurrentBeforeJump()
    }
    markOverlay.onBoxCaptured = { [weak self, weak pane] box in
      guard let self, let pane else { return }
      self.activatePane(pane)
      self.capture(box)
    }
    markOverlay.onActivateMark = { [weak self, weak pane] target in
      guard let self, let pane else { return }
      self.activatePane(pane)
      self.activate(target)
    }
    markOverlay.onDeleteMark = { [weak self] id in self?.deleteMark(id) }
    markOverlay.onHoverMark = { [weak self, weak markOverlay] target in
      guard let self, let markOverlay else { return }
      self.hover(target, from: markOverlay)
    }
  }

  private func selectPane(_ pane: ReaderPaneView) {
    selectedPane = pane
    descriptor = pane.descriptor
    let splitActive = secondaryPane != nil
    for candidate in panes {
      candidate.showsActiveChrome = splitActive
      candidate.setActivePane(candidate === pane)
    }
    if let descriptor {
      window?.title = "\(descriptor.name) — Lattice"
    } else if homeView.isHidden {
      window?.title = "Lattice"
    }
    updatePageAndScale()
    refreshMarkCaptureStatus()
  }

  private func activatePane(_ pane: ReaderPaneView) {
    let captureMode = currentMarkCaptureMode()
    if captureMode != .inactive, let previous = capturePane, previous !== pane {
      previous.markOverlay.captureMode = .inactive
      pane.markOverlay.captureMode = captureMode
      capturePane = pane
    }
    if selectedPane !== pane {
      selectPane(pane)
    } else {
      descriptor = pane.descriptor
      let splitActive = secondaryPane != nil
      pane.showsActiveChrome = splitActive
      pane.setActivePane(true)
      updatePageAndScale()
      refreshMarkCaptureStatus()
    }
    if window?.firstResponder !== pane.pdfView {
      window?.makeFirstResponder(pane.pdfView)
    }
  }

  private func installActivePaneKeyMonitor() {
    activePaneKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self else { return event }
      guard event.window === self.window else { return event }
      guard self.commandPalette.isHidden, self.searchPrompt.isHidden, self.marksView.isHidden else {
        return event
      }
      if self.window?.firstResponder is NSTextView || self.window?.firstResponder is NSTextField
        || self.window?.firstResponder === self.searchField
      {
        return event
      }

      var modifiers: ShortcutModifiers = []
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if flags.contains(.command) { modifiers.insert(.command) }
      if flags.contains(.control) { modifiers.insert(.control) }
      guard
        let command = self.paneShortcutResolver.resolve(
          key: event.charactersIgnoringModifiers ?? "",
          keyCode: event.keyCode,
          modifiers: modifiers,
          timestamp: event.timestamp
        )
      else { return event }

      if !self.homeView.isHidden {
        if command == .cancelMark, self.currentMarkCaptureMode() != .inactive {
          self.cancelMarkCapture()
          return nil
        }
        if command == .jumpBackward || command == .jumpForward {
          self.handleNonLocalCommand(command)
          return nil
        }
        return event
      }
      guard self.pdfView.document != nil else { return event }

      switch command {
      case .focusLeft, .focusRight, .focusUp, .focusDown:
        guard self.secondaryPane != nil else { return event }
        self.handleNonLocalCommand(command)
        return nil
      case .scrollDown, .scrollUp, .scrollLeft, .scrollRight, .halfDown, .halfUp, .zoomIn, .zoomOut,
        .fitWidth, .documentStart, .documentEnd, .nextPage, .previousPage, .goToPage, .findForward,
        .findBackward, .findNext, .findPrevious, .jumpBackward, .jumpForward, .showCommandPalette,
        .showMarks, .showHome, .verticalSplit, .horizontalSplit, .closeSplit, .captureMark,
        .cancelMark, .open, .help, .find, .quit:
        if self.secondaryPane != nil {
          self.activatePane(self.activePane)
          self.activePane.pdfView.execute(command)
          return nil
        }
        return event
      }
    }
  }

  private func showHome() {
    homeView.setRecents(recents)
    homeView.isHidden = false
    pageLabel.stringValue = "— / —"
    scaleLabel.stringValue = "100%"
    window?.title = "Lattice"
    refreshMarkCaptureStatus()
  }

  private func returnToHome(recordJump: Bool = true) {
    if !homeView.isHidden, descriptor == nil {
      showHome()
      return
    }

    let pendingCapture = currentMarkCaptureMode()
    let pendingDraft = markDraft
    persistCurrentReadingPosition()
    if recordJump { recordJumpListLocation() }
    hidePreview()
    if !commandPalette.isHidden { commandPalette.dismiss() }
    if !marksView.isHidden { marksView.dismiss() }

    if let secondary = secondaryPane {
      if let observer = scrollBoundsObservers.removeValue(forKey: ObjectIdentifier(secondary)) {
        NotificationCenter.default.removeObserver(observer)
      }
      secondary.descriptor = nil
      secondary.openGeneration = UUID()
      secondary.markOverlay.captureMode = .inactive
      secondary.pdfView.document = nil
      secondary.removeFromSuperview()
      secondaryPane = nil
    }

    for pane in panes {
      pane.descriptor = nil
      pane.openGeneration = UUID()
      pane.pdfView.document = nil
      pane.markOverlay.documentFingerprint = nil
      pane.markOverlay.marks = marks
      pane.markOverlay.captureMode = .inactive
      pane.showsActiveChrome = false
      pane.setActivePane(pane === primaryPane)
    }
    if pendingCapture != .inactive {
      markDraft = pendingDraft
      primaryPane.markOverlay.captureMode = pendingCapture
      capturePane = primaryPane
    } else {
      markDraft = nil
      capturePane = nil
    }
    descriptor = nil
    selectPane(primaryPane)
    showHome()
  }

  private func hideHome() {
    homeView.isHidden = true
  }

  private func loadRecents() {
    do {
      recents = try recentsRepository.load()
    } catch {
      recents = []
    }
    if recents.isEmpty {
      recents = RecentsRepository.seeded(from: readingPositions)
      if !recents.isEmpty {
        try? recentsRepository.save(recents)
      }
    }
    homeView.setRecents(recents)
  }

  private func recordRecent(_ descriptor: DocumentDescriptor) {
    let recent = RecentDocument(
      fingerprint: descriptor.fingerprint,
      path: descriptor.url.path,
      name: descriptor.name,
      pageCount: descriptor.pageCount
    )
    do {
      try recentsRepository.record(recent, into: &recents)
      homeView.setRecents(recents)
    } catch {
      // Keep the in-memory list even if persistence fails.
      recents.removeAll { $0.fingerprint == recent.fingerprint || $0.path == recent.path }
      recents.insert(recent, at: 0)
      homeView.setRecents(recents)
    }
  }

  private func observePDFView(in pane: ReaderPaneView) {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .PDFViewPageChanged, object: pane.pdfView, queue: .main
      ) { [weak self, weak pane] _ in
        MainActor.assumeIsolated {
          guard let self, let pane else { return }
          if self.activePane === pane { self.updatePageAndScale() }
          self.scheduleReadingPositionSave()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .PDFViewScaleChanged, object: pane.pdfView, queue: .main
      ) { [weak self, weak pane] _ in
        MainActor.assumeIsolated {
          guard let self, let pane else { return }
          if self.activePane === pane { self.updatePageAndScale() }
          self.scheduleReadingPositionSave()
        }
      })
  }

  private func installScrollObservation(in pane: ReaderPaneView) {
    let identifier = ObjectIdentifier(pane)
    if let observer = scrollBoundsObservers.removeValue(forKey: identifier) {
      NotificationCenter.default.removeObserver(observer)
    }
    guard let clipView = pane.pdfView.scrollView?.contentView else { return }
    clipView.postsBoundsChangedNotifications = true
    scrollBoundsObservers[identifier] = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: clipView,
      queue: .main
    ) { [weak self, weak pane] _ in
      MainActor.assumeIsolated {
        guard let self, let pane else { return }
        pane.markOverlay.viewportDidChange()
        if self.activePane !== pane { return }
        self.scheduleReadingPositionSave()
      }
    }
  }

  private func loadMarks() {
    do {
      marks = try markRepository.load()
      for pane in panes {
        pane.markOverlay.marks = marks
      }
    } catch {
      marks = []
      for pane in panes {
        pane.markOverlay.marks = []
      }
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
    for pane in panes {
      pane.markOverlay.marks = marks
    }
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
    guard panes.contains(where: { $0.descriptor != nil }) else { return }
    readingSaveWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.persistCurrentReadingPosition() }
    readingSaveWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  func persistCurrentReadingPosition() {
    readingSaveWorkItem?.cancel()
    readingSaveWorkItem = nil
    var didChange = false
    for pane in panes {
      guard let paneDescriptor = pane.descriptor,
        let location = pane.pdfView.currentJumpLocation(descriptor: paneDescriptor)
      else { continue }
      readingPositions[paneDescriptor.fingerprint] = ReadingPosition(location: location)
      didChange = true
    }
    guard didChange else { return }
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
    capturePane = activePane
    markDraft = nil
    markOverlay.captureMode = .source
    hidePreview()
    refreshMarkCaptureStatus()
  }

  private func capture(_ box: CapturedMarkBox) {
    let pane = capturePane ?? activePane
    guard let descriptor = pane.descriptor ?? descriptor else {
      NSSound.beep()
      return
    }
    let overlay = pane.markOverlay
    let anchor = MarkAnchor(
      documentFingerprint: descriptor.fingerprint,
      documentPath: descriptor.url.path,
      pageIndex: box.pageIndex,
      bounds: box.bounds,
      quotedText: box.quotedText
    )
    switch overlay.captureMode {
    case .source:
      markDraft = anchor
      overlay.captureMode = .destination
      refreshMarkCaptureStatus()
    case .destination:
      guard let source = markDraft else {
        cancelMarkCapture()
        return
      }
      marks.append(Mark(source: source, destination: anchor))
      markDraft = nil
      overlay.captureMode = .inactive
      capturePane = nil
      saveMarks()
      filenameLabel.stringValue = "Mark created · \(marks.count) total"
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.markOverlay.refreshInteractions()
        self.window?.makeFirstResponder(self.pdfView)
      }
    case .inactive:
      break
    }
  }

  private func cancelMarkCapture() {
    guard
      let overlay = capturePane?.markOverlay
        ?? panes.map(\.markOverlay).first(where: {
          $0.captureMode != .inactive
        })
    else { return }
    markDraft = nil
    overlay.captureMode = .inactive
    capturePane = nil
    refreshMarkCaptureStatus()
  }

  private func clearSearch() {
    lastSearchQuery = ""
    lastSearchDirection = .forward
    searchOriginRecorded = false
    searchField.stringValue = ""
    for pane in panes {
      pane.pdfView.setCurrentSelection(nil, animate: false)
      pane.pdfView.highlightedSelections = nil
    }
  }

  private func cancelMarkOrSearch() {
    if currentMarkCaptureMode() != .inactive {
      cancelMarkCapture()
      return
    }
    if !searchPrompt.isHidden {
      searchPrompt.dismiss()
      return
    }
    guard !lastSearchQuery.isEmpty || pdfView.currentSelection != nil else { return }
    clearSearch()
  }

  private func currentMarkCaptureMode() -> MarkCaptureMode {
    if let mode = capturePane?.markOverlay.captureMode, mode != .inactive {
      return mode
    }
    return panes.map(\.markOverlay.captureMode).first(where: { $0 != .inactive }) ?? .inactive
  }

  private func refreshMarkCaptureStatus() {
    switch currentMarkCaptureMode() {
    case .source:
      filenameLabel.stringValue = "Mark source · drag a box · Esc cancels"
    case .destination:
      filenameLabel.stringValue =
        "Mark destination · navigate, :q / home, or open a PDF, then drag a box"
    case .inactive:
      filenameLabel.stringValue = descriptor?.name ?? "No document open"
    }
  }

  private func deleteMark(_ id: UUID) {
    marks.removeAll { $0.id == id }
    if hoveredMarkID == id { hidePreview() }
    saveMarks()
  }

  private func hover(_ target: MarkInteractionTarget?, from overlay: MarkOverlayView) {
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
    placePreview(beside: target.rect, from: overlay)
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
        self.placePreview(beside: target.rect, from: overlay)
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

  private func placePreview(beside overlayRect: NSRect, from overlay: MarkOverlayView) {
    let source = rootView.convert(overlayRect, from: overlay)
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
    if let matching = panes.first(where: {
      $0.descriptor?.fingerprint == target.documentFingerprint
    }) {
      recordCurrentBeforeJump()
      activatePane(matching)
      matching.pdfView.go(to: target, scale: matching.pdfView.scaleFactor)
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
    searchPrompt.dismiss()
    hidePreview()
    commandPalette.present()
  }

  private func showSearchPrompt(direction: SearchPromptView.Direction) {
    commandPalette.dismiss()
    marksView.dismiss()
    hidePreview()
    searchPrompt.present(direction: direction, initialQuery: lastSearchQuery)
  }

  private func showMarks() {
    commandPalette.dismiss()
    searchPrompt.dismiss()
    hidePreview()
    let entries =
      descriptor.map { MarksIndex.entries(for: $0.fingerprint, marks: marks) } ?? []
    marksView.present(entries: entries)
  }

  private func performSearch(
    query: String,
    direction: SearchPromptView.Direction,
    wrap: Bool,
    fromCurrentSelection: Bool = false
  ) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedQuery = trimmed.isEmpty ? lastSearchQuery : trimmed
    guard !resolvedQuery.isEmpty else {
      NSSound.beep()
      return
    }
    guard let document = pdfView.document else {
      NSSound.beep()
      return
    }

    lastSearchQuery = resolvedQuery
    lastSearchDirection = direction
    searchField.stringValue = resolvedQuery

    var options: NSString.CompareOptions = [.caseInsensitive]
    if direction == .backward { options.insert(.backwards) }

    // `/`/`?` always start from the viewport. Only `n`/`N` continue from the current match.
    let origin =
      fromCurrentSelection
      ? (pdfView.currentSelection
        ?? pdfView.searchOriginSelection(backward: direction == .backward))
      : pdfView.searchOriginSelection(backward: direction == .backward)

    if let origin,
      let match = document.findString(resolvedQuery, fromSelection: origin, withOptions: options)
    {
      recordCurrentBeforeJump()
      pdfView.setCurrentSelection(match, animate: true)
      pdfView.go(to: match)
      return
    }

    // Wrap only after a real from-here search misses (vim-style).
    if wrap, origin != nil,
      let match = document.findString(resolvedQuery, fromSelection: nil, withOptions: options)
    {
      recordCurrentBeforeJump()
      pdfView.setCurrentSelection(match, animate: true)
      pdfView.go(to: match)
      return
    }

    // Origin could not be built; last resort is a whole-document search.
    if origin == nil,
      let match = document.findString(resolvedQuery, fromSelection: nil, withOptions: options)
    {
      recordCurrentBeforeJump()
      pdfView.setCurrentSelection(match, animate: true)
      pdfView.go(to: match)
      return
    }

    NSSound.beep()
  }

  private func findAgain(opposite: Bool) {
    guard !lastSearchQuery.isEmpty else {
      NSSound.beep()
      return
    }
    let direction = opposite ? inverted(lastSearchDirection) : lastSearchDirection
    performSearch(
      query: lastSearchQuery, direction: direction, wrap: true, fromCurrentSelection: true)
  }

  private func inverted(_ direction: SearchPromptView.Direction) -> SearchPromptView.Direction {
    direction == .forward ? .backward : .forward
  }

  private func splitDocument(vertical: Bool) {
    let sourcePane = activePane
    guard let document = sourcePane.pdfView.document else {
      showError(title: "Open a PDF first", message: "Open a PDF before creating a split.")
      return
    }
    guard panes.allSatisfy({ $0.markOverlay.captureMode == .inactive }) else {
      showError(title: "Finish the current mark", message: "Complete or cancel mark capture first.")
      return
    }

    let sourceDescriptor = sourcePane.descriptor ?? descriptor
    let fingerprint =
      sourceDescriptor?.fingerprint ?? sourcePane.markOverlay.documentFingerprint ?? "pending"
    let path = sourceDescriptor?.url.path ?? document.documentURL?.path ?? ""
    let location = sourcePane.pdfView.currentJumpLocation(fingerprint: fingerprint, path: path)
    let targetPane: ReaderPaneView
    if let secondaryPane {
      targetPane = sourcePane === primaryPane ? secondaryPane : primaryPane
    } else {
      let pane = ReaderPaneView()
      secondaryPane = pane
      configureReaderPane(pane)
      observePDFView(in: pane)
      splitView.addArrangedSubview(pane)
      targetPane = pane
    }

    splitView.isVertical = vertical
    targetPane.descriptor = sourceDescriptor
    targetPane.openGeneration = sourcePane.openGeneration
    targetPane.pdfView.document = document
    targetPane.pdfView.autoScales = false
    targetPane.pdfView.scaleFactor = sourcePane.pdfView.scaleFactor
    targetPane.markOverlay.documentFingerprint = fingerprint
    targetPane.markOverlay.marks = marks
    activatePane(targetPane)
    finalizeSplitLayout(
      target: targetPane, location: location, vertical: vertical, attempt: 0)
  }

  private func finalizeSplitLayout(
    target: ReaderPaneView,
    location: JumpLocation?,
    vertical: Bool,
    attempt: Int
  ) {
    splitView.layoutSubtreeIfNeeded()
    splitView.adjustSubviews()
    let length = vertical ? splitView.bounds.width : splitView.bounds.height
    if length > 1, splitView.subviews.count > 1 {
      splitView.setPosition(
        max(1, (length - splitView.dividerThickness) / 2),
        ofDividerAt: 0
      )
    }
    if let location {
      target.pdfView.restore(location)
    }
    target.markOverlay.viewportDidChange()
    installScrollObservation(in: target)
    activatePane(target)

    let needsRetry = length <= 1 || target.pdfView.scrollView == nil
    if attempt == 0 || (needsRetry && attempt < 4) {
      DispatchQueue.main.async { [weak self, weak target] in
        guard let self, let target else { return }
        self.finalizeSplitLayout(
          target: target, location: location, vertical: vertical, attempt: attempt + 1)
      }
    }
  }

  private func closeActiveSplit() {
    guard let secondary = secondaryPane else {
      returnToHome()
      return
    }

    persistCurrentReadingPosition()
    hidePreview()
    if !commandPalette.isHidden { commandPalette.dismiss() }
    if !marksView.isHidden { marksView.dismiss() }

    let pendingCapture = currentMarkCaptureMode()
    let closingPrimary = activePane === primaryPane
    if closingPrimary {
      primaryPane.descriptor = secondary.descriptor
      primaryPane.openGeneration = secondary.openGeneration
      primaryPane.pdfView.document = secondary.pdfView.document
      primaryPane.pdfView.autoScales = secondary.pdfView.autoScales
      primaryPane.pdfView.scaleFactor = secondary.pdfView.scaleFactor
      primaryPane.markOverlay.documentFingerprint = secondary.markOverlay.documentFingerprint
      primaryPane.markOverlay.marks = marks
      if let secondaryDescriptor = secondary.descriptor,
        let location = secondary.pdfView.currentJumpLocation(descriptor: secondaryDescriptor)
      {
        primaryPane.pdfView.restore(location)
      }
      primaryPane.markOverlay.viewportDidChange()
    }

    if let observer = scrollBoundsObservers.removeValue(forKey: ObjectIdentifier(secondary)) {
      NotificationCenter.default.removeObserver(observer)
    }
    secondary.descriptor = nil
    secondary.openGeneration = UUID()
    secondary.markOverlay.captureMode = .inactive
    secondary.pdfView.document = nil
    secondary.removeFromSuperview()
    secondaryPane = nil
    if pendingCapture != .inactive {
      primaryPane.markOverlay.captureMode = pendingCapture
      capturePane = primaryPane
    } else {
      capturePane = nil
    }
    activatePane(primaryPane)
    refreshMarkCaptureStatus()
  }

  private enum SplitFocusDirection {
    case left, right, up, down
  }

  private func focusSplit(direction: SplitFocusDirection) {
    guard let secondary = secondaryPane else { return }
    let target: ReaderPaneView
    if splitView.isVertical {
      switch direction {
      case .left:
        target = primaryPane
      case .right:
        target = secondary
      case .up, .down:
        target = activePane === primaryPane ? secondary : primaryPane
      }
    } else {
      switch direction {
      case .up:
        target = primaryPane
      case .down:
        target = secondary
      case .left, .right:
        target = activePane === primaryPane ? secondary : primaryPane
      }
    }
    activatePane(target)
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
    let overlay = markOverlay
    overlay.arrivalAnchorID = anchor.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak overlay] in
      if overlay?.arrivalAnchorID == anchor.id {
        overlay?.arrivalAnchorID = nil
      }
    }
  }

  private func currentJumpListLocation() -> JumpLocation? {
    if !homeView.isHidden || descriptor == nil {
      return .home
    }
    return descriptor.flatMap { pdfView.currentJumpLocation(descriptor: $0) }
  }

  private func recordJumpListLocation() {
    guard let location = currentJumpListLocation() else { return }
    jumpList.recordBeforeJump(location)
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
    case .findForward:
      showSearchPrompt(direction: .forward)
    case .findBackward:
      showSearchPrompt(direction: .backward)
    case .findNext:
      findAgain(opposite: false)
    case .findPrevious:
      findAgain(opposite: true)
    case .showMarks:
      showMarks()
    case .showHome:
      returnToHome()
    case .verticalSplit:
      splitDocument(vertical: true)
    case .horizontalSplit:
      splitDocument(vertical: false)
    case .closeSplit:
      closeActiveSplit()
    case .focusLeft:
      focusSplit(direction: .left)
    case .focusRight:
      focusSplit(direction: .right)
    case .focusUp:
      focusSplit(direction: .up)
    case .focusDown:
      focusSplit(direction: .down)
    case .quit:
      returnToHome()
    case .cancelMark:
      cancelMarkOrSearch()
    case .jumpBackward:
      let current = currentJumpListLocation()
      guard let target = jumpList.goBackward(from: current) else { return }
      restore(target) { [weak self] success in
        guard let self, !success else { return }
        self.jumpList.cancelBackward(target: target, current: current)
      }
    case .jumpForward:
      let current = currentJumpListLocation()
      guard let target = jumpList.goForward(from: current) else { return }
      restore(target) { [weak self] success in
        guard let self, !success else { return }
        self.jumpList.cancelForward(target: target, current: current)
      }
    case .documentStart, .documentEnd, .nextPage, .previousPage, .goToPage:
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
      case .goToPage(let pageNumber):
        guard let document = pdfView.document, document.pageCount > 0 else { return }
        let index = min(max(1, pageNumber), document.pageCount) - 1
        if let page = document.page(at: index) { pdfView.go(to: page) }
      default: break
      }
    default:
      break
    }
  }

  private func restore(
    _ location: JumpLocation,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    if location.isHome {
      returnToHome(recordJump: false)
      completion?(true)
      return
    }
    if let matching = panes.first(where: {
      guard let paneDescriptor = $0.descriptor else { return false }
      return paneDescriptor.fingerprint == location.documentFingerprint
        || paneDescriptor.url.path == location.documentPath
    }) {
      activatePane(matching)
      matching.pdfView.restore(location)
      completion?(true)
      return
    }

    let url = URL(fileURLWithPath: location.documentPath)
    if FileManager.default.fileExists(atPath: url.path) {
      openDocument(
        at: url,
        recordJump: false,
        resumeReadingPosition: false
      ) { [weak self] descriptor in
        guard let self else {
          completion?(false)
          return
        }
        let matches =
          descriptor.fingerprint == location.documentFingerprint
          || descriptor.url.path == location.documentPath
          || location.documentFingerprint.hasPrefix("pending:")
        guard matches else {
          completion?(false)
          return
        }
        self.pdfView.restore(location)
        completion?(true)
      }
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
    resolveURL(for: anchor) { [weak self] resolved in
      guard let self else {
        completion?(false)
        return
      }
      self.openDocument(
        at: resolved,
        recordJump: false,
        resumeReadingPosition: false
      ) { descriptor in
        guard descriptor.fingerprint == location.documentFingerprint
          || descriptor.url.path == location.documentPath
        else {
          completion?(false)
          return
        }
        self.pdfView.restore(location)
        completion?(true)
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
    activatePane(activePane)
    activePane.pdfView.execute(.zoomOut)
  }
  @objc private func zoomInPressed(_ sender: Any?) {
    activatePane(activePane)
    activePane.pdfView.execute(.zoomIn)
  }
  @objc private func fitPressed(_ sender: Any?) {
    activatePane(activePane)
    activePane.pdfView.execute(.fitWidth)
  }
  @objc private func helpPressed(_ sender: Any?) { showShortcutHelp() }

  private func showShortcutHelp() {
    let alert = NSAlert()
    alert.messageText = "Lattice shortcuts"
    alert.informativeText = """
      o / ⌘O  Open PDF       j k  Scroll vertically
      h l     Scroll sideways  ⌃d ⌃u  Half screen
      gg / G  Start / end      [ ]  Previous / next page
      + −     Zoom             0  Fit width
      / ?     Search forward / back    n N  Next / previous match
      ⌘F      Toolbar search   m  Create box mark
      ⌃O / ⌃I Back / forward jump     Esc  Cancel mark / clear search
      ⌃Hover  Preview mark     ⌃Click  Follow mark
      :       Fuzzy commands   :help  This shortcut list
      :marks  List marks       :N  Go to page N
      :vsplit Side-by-side PDF :hsplit Top/bottom PDF
      :home   Recent PDFs home :q / :qa  Close view / go home
      ⌃h ⌃j ⌃k ⌃l  Focus left/down/up/right split
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
