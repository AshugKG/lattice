import Foundation
import LatticeCore
import PDFKit
import Observation

@MainActor
@Observable
final class ReaderModel {
  var recents: [RecentDocument] = []
  var openDocumentURL: URL?
  var descriptor: DocumentDescriptor?
  var portals: [Portal] = []
  var captureMode: PortalCaptureMode = .inactive
  var statusMessage: String?
  var canGoBack = false
  var canGoForward = false
  var pageLabel = ""
  var errorMessage: String?

  let pdfController = PDFController()
  let portalOverlay = PortalOverlayController()

  private let recentsRepo = RecentsRepository()
  private let readingRepo = ReadingStateRepository()
  private let portalsRepo = PortalRepository()
  private var readingPositions: [String: ReadingPosition] = [:]
  private var jumpList = JumpList()
  private var portalDraft: PortalAnchor?
  private var lastSearchQuery = ""
  private var searchWentBackward = false
  private var searchOriginRecorded = false
  private var persistTask: Task<Void, Never>?
  private var arrivalClearTask: Task<Void, Never>?
  private var suppressPersistUntil: Date?
  /// While true, ignore viewport callbacks so a transient page-1 layout can't clobber resume.
  private var isRestoringViewport = false
  /// Prevents makeUIView + updateUIView from applying resume twice for the same open.
  private var resumeAppliedForOpenID: UUID?
  private var currentOpenID: UUID?

  init() {
    portalOverlay.onBoxCaptured = { [weak self] box in
      self?.capture(box)
    }
    portalOverlay.onActivatePortal = { [weak self] target in
      self?.activate(target)
    }
    portalOverlay.onDeletePortal = { [weak self] id in
      self?.deletePortal(id)
    }
    reloadHomeData()
  }

  var isReading: Bool { openDocumentURL != nil }

  func reloadHomeData() {
    do {
      readingPositions = (try? readingRepo.load()) ?? [:]
      var loaded = try recentsRepo.load()
      if loaded.isEmpty {
        loaded = RecentsRepository.seeded(from: readingPositions)
        if !loaded.isEmpty { try? recentsRepo.save(loaded) }
      }
      recents = loaded
      portals = (try? portalsRepo.load()) ?? []
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func importAndOpen(from url: URL) {
    do {
      let local = try DocumentImporter.importPDF(from: url)
      open(url: local, resume: true, recordJumpFromHome: true)
    } catch {
      errorMessage = "Could not import PDF: \(error.localizedDescription)"
    }
  }

  func openRecent(_ recent: RecentDocument) {
    open(url: recent.url, resume: true, recordJumpFromHome: true)
  }

  func closeDocument() {
    persistCurrentReadingPosition()
    if let location = currentLocation() {
      jumpList.recordBeforeJump(location)
    } else {
      jumpList.recordBeforeJump(.home)
    }
    cancelPortalCapture()
    openDocumentURL = nil
    descriptor = nil
    currentOpenID = nil
    resumeAppliedForOpenID = nil
    portalOverlay.documentFingerprint = nil
    portalOverlay.portals = []
    pdfController.pdfView?.document = nil
    pageLabel = ""
    statusMessage = nil
    updateJumpButtons()
    reloadHomeData()
  }

  func documentDidLoad(_ document: PDFDocument) {
    guard let url = openDocumentURL else { return }
    let fingerprint: String
    do {
      fingerprint = try DocumentFingerprint.sha256(of: url)
    } catch {
      fingerprint = "pending:\(url.path)"
    }

    let desc = DocumentDescriptor(
      fingerprint: fingerprint,
      url: url,
      name: url.lastPathComponent,
      pageCount: document.pageCount
    )
    descriptor = desc
    portalOverlay.resetPages()
    portalOverlay.documentFingerprint = fingerprint
    portalOverlay.portals = portals
    syncPortalOverlayCapture()

    let recent = RecentDocument(
      fingerprint: fingerprint,
      path: url.path,
      name: desc.name,
      pageCount: document.pageCount
    )
    try? recentsRepo.record(recent, into: &recents)

    // Avoid overwriting the saved position with a transient page-1 reading while restore settles.
    suppressPersistUntil = Date().addingTimeInterval(1.0)

    let openID = currentOpenID
    let alreadyResumed = openID != nil && resumeAppliedForOpenID == openID

    if pendingJumpRestore == nil, pendingArrival == nil, !alreadyResumed {
      if let openID { resumeAppliedForOpenID = openID }
      if let saved = readingPositions[fingerprint]?.location {
        beginViewportRestore(saved.clamped(pageCount: document.pageCount))
      } else if let byPath = readingPositions.first(where: {
        $0.value.location.documentPath == url.path
      })?.value.location {
        beginViewportRestore(byPath.clamped(pageCount: document.pageCount))
      } else {
        updatePageLabel()
      }
    } else {
      updatePageLabel()
    }

    updateJumpButtons()
    statusMessage = desc.name
    portalOverlay.refreshAll()
  }

  func viewportChanged() {
    if isRestoringViewport { return }
    portalOverlay.viewportDidChange()
    updatePageLabel()
    if let suppressPersistUntil, Date() < suppressPersistUntil {
      return
    }
    schedulePersistReadingPosition()
  }

  // MARK: - Navigation

  func jumpBack() {
    let current = currentLocation() ?? (isReading ? nil : .home)
    guard let target = jumpList.goBackward(from: current) else { return }
    restoreJump(target) { [weak self] success in
      guard let self, !success else { return }
      self.jumpList.cancelBackward(target: target, current: current)
      self.updateJumpButtons()
    }
  }

  func jumpForward() {
    let current = currentLocation() ?? (isReading ? nil : .home)
    guard let target = jumpList.goForward(from: current) else { return }
    restoreJump(target) { [weak self] success in
      guard let self, !success else { return }
      self.jumpList.cancelForward(target: target, current: current)
      self.updateJumpButtons()
    }
  }

  func goToPage(oneBased: Int) {
    guard descriptor != nil, let document = pdfController.pdfView?.document else { return }
    let index = oneBased - 1
    guard index >= 0, index < document.pageCount else {
      errorMessage = "Page must be between 1 and \(document.pageCount)"
      return
    }
    recordCurrentBeforeJump()
    pdfController.goToPage(index: index)
    viewportChanged()
  }

  // MARK: - Find

  func find(query: String, backward: Bool = false) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let queryChanged = trimmed != lastSearchQuery
    lastSearchQuery = trimmed
    searchWentBackward = backward
    if queryChanged { searchOriginRecorded = false }
    if !searchOriginRecorded {
      recordCurrentBeforeJump()
      searchOriginRecorded = true
    }
    let found = pdfController.find(
      query: trimmed, backward: backward, fromCurrentSelection: !queryChanged)
    if !found, queryChanged {
      // Live typing: stay quiet until submit/next shows a miss on a stable query.
    } else if !found {
      errorMessage = "No matches for “\(trimmed)”"
    }
    viewportChanged()
  }

  var hasActiveSearch: Bool { !lastSearchQuery.isEmpty }

  func findAgain(opposite: Bool = false) {
    let query = lastSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    let backward = opposite ? !searchWentBackward : searchWentBackward
    if !searchOriginRecorded {
      recordCurrentBeforeJump()
      searchOriginRecorded = true
    }
    let found = pdfController.find(
      query: query, backward: backward, fromCurrentSelection: true)
    if !found { errorMessage = "No more matches" }
    viewportChanged()
  }

  func clearFind() {
    lastSearchQuery = ""
    searchWentBackward = false
    searchOriginRecorded = false
    pdfController.clearSelection()
  }

  // MARK: - Portals

  /// Portal button: 1st press → source drag; after source, 2nd press → destination drag.
  /// Press while actively dragging a phase cancels.
  func togglePortalCapture() {
    switch captureMode {
    case .inactive:
      guard descriptor != nil else {
        errorMessage = "Open a PDF first"
        return
      }
      portalDraft = nil
      captureMode = .source
      syncPortalOverlayCapture()
      statusMessage = "Portal source · drag a box"
    case .sourcePlaced:
      captureMode = .destination
      syncPortalOverlayCapture()
      statusMessage = "Portal destination · drag a box"
    case .source, .destination:
      cancelPortalCapture()
    }
  }

  func cancelPortalCapture() {
    portalDraft = nil
    captureMode = .inactive
    syncPortalOverlayCapture()
    statusMessage = descriptor?.name
  }

  var portalIconPhase: PortalPhaseIcon.Phase {
    switch captureMode {
    case .inactive, .source:
      return .source
    case .sourcePlaced, .destination:
      return .destination
    }
  }

  func portalEntriesForCurrentDocument() -> [PortalListEntry] {
    guard let fingerprint = descriptor?.fingerprint else { return [] }
    return PortalsIndex.entries(for: fingerprint, portals: portals)
  }

  func goToPortal(id: UUID) {
    guard let portal = portals.first(where: { $0.id == id }) else { return }
    activate(PortalInteractionTarget(portal: portal, endpoint: .source))
  }

  // MARK: - Private

  private func open(url: URL, resume: Bool, recordJumpFromHome: Bool) {
    if recordJumpFromHome, !isReading {
      jumpList.recordBeforeJump(.home)
    } else if let location = currentLocation() {
      jumpList.recordBeforeJump(location)
    }
    cancelPortalCapture()
    currentOpenID = UUID()
    resumeAppliedForOpenID = nil
    openDocumentURL = url
    // Resume handled in documentDidLoad via readingPositions; `resume` reserved for future skip.
    _ = resume
    updateJumpButtons()
  }

  private func capture(_ box: CapturedPortalBox) {
    guard let descriptor else { return }
    let anchor = PortalAnchor(
      documentFingerprint: descriptor.fingerprint,
      documentPath: descriptor.url.path,
      pageIndex: box.pageIndex,
      bounds: box.bounds,
      quotedText: box.quotedText
    )
    switch captureMode {
    case .source:
      portalDraft = anchor
      captureMode = .sourcePlaced
      syncPortalOverlayCapture()
      statusMessage = "Source set · press Portal again for destination"
    case .destination:
      guard let source = portalDraft else {
        cancelPortalCapture()
        return
      }
      portals.append(Portal(source: source, destination: anchor))
      portalDraft = nil
      captureMode = .inactive
      syncPortalOverlayCapture()
      portalOverlay.portals = portals
      portalOverlay.refreshAll()
      try? portalsRepo.save(portals)
      statusMessage = "Portal created · \(portals.count) total"
    case .inactive, .sourcePlaced:
      break
    }
  }

  private func activate(_ target: PortalInteractionTarget) {
    recordCurrentBeforeJump()
    let destination = target.portal.oppositeAnchor(from: target.endpoint)
    if destination.documentFingerprint != descriptor?.fingerprint,
      FileManager.default.fileExists(atPath: destination.documentPath)
    {
      open(url: URL(fileURLWithPath: destination.documentPath), resume: false, recordJumpFromHome: false)
      // After load, jump to anchor — store pending arrival.
      pendingArrival = destination
    } else {
      pdfController.go(to: destination)
      flashArrival(destination.id)
      portalOverlay.refreshAll()
      viewportChanged()
    }
  }

  private var pendingArrival: PortalAnchor?

  func applyPendingArrivalIfNeeded() {
    guard let pending = pendingArrival else { return }
    pendingArrival = nil
    pdfController.go(to: pending)
    flashArrival(pending.id)
    portalOverlay.refreshAll()
    viewportChanged()
  }

  private func deletePortal(_ id: UUID) {
    portals.removeAll { $0.id == id }
    portalOverlay.portals = portals
    portalOverlay.refreshAll()
    try? portalsRepo.save(portals)
    statusMessage = "Portal deleted"
  }

  private func flashArrival(_ id: UUID) {
    portalOverlay.arrivalAnchorID = id
    portalOverlay.refreshAll()
    arrivalClearTask?.cancel()
    arrivalClearTask = Task {
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      portalOverlay.arrivalAnchorID = nil
      portalOverlay.refreshAll()
    }
  }

  private func syncPortalOverlayCapture() {
    portalOverlay.captureMode = captureMode
    portalOverlay.refreshAll()
    // Capture uses a full-bleed layer; freeze PDF scrolling so drags draw portals.
    pdfController.setScrollingEnabled(!captureMode.allowsDrawing)
  }

  private func currentLocation() -> JumpLocation? {
    guard let descriptor else { return nil }
    return pdfController.currentJumpLocation(
      fingerprint: descriptor.fingerprint, path: descriptor.url.path)
  }

  private func recordCurrentBeforeJump() {
    if let location = currentLocation() {
      jumpList.recordBeforeJump(location)
    }
    updateJumpButtons()
  }

  private func restoreJump(_ target: JumpLocation, completion: @escaping (Bool) -> Void) {
    if target.isHome {
      persistCurrentReadingPosition()
      openDocumentURL = nil
      descriptor = nil
      portalOverlay.documentFingerprint = nil
      pdfController.pdfView?.document = nil
      reloadHomeData()
      updateJumpButtons()
      completion(true)
      return
    }

    let url = URL(fileURLWithPath: target.documentPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      completion(false)
      return
    }

    if descriptor?.fingerprint == target.documentFingerprint
      || openDocumentURL?.path == target.documentPath
    {
      beginViewportRestore(target)
      updateJumpButtons()
      completion(true)
      return
    }

    pendingJumpRestore = target
    currentOpenID = UUID()
    resumeAppliedForOpenID = nil
    openDocumentURL = url
    updateJumpButtons()
    completion(true)
  }

  private var pendingJumpRestore: JumpLocation?

  func applyPendingJumpRestoreIfNeeded() {
    guard let pending = pendingJumpRestore else {
      applyPendingArrivalIfNeeded()
      return
    }
    pendingJumpRestore = nil
    beginViewportRestore(pending)
    updateJumpButtons()
    applyPendingArrivalIfNeeded()
  }

  private func beginViewportRestore(_ location: JumpLocation) {
    isRestoringViewport = true
    suppressPersistUntil = Date().addingTimeInterval(1.0)
    let pageCount = descriptor?.pageCount ?? 0
    pageLabel = pageCount > 0 ? "\(location.pageIndex + 1) / \(pageCount)" : ""
    pdfController.restore(location)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard let self else { return }
      self.isRestoringViewport = false
      self.updatePageLabel()
      self.portalOverlay.refreshAll()
    }
  }

  private func schedulePersistReadingPosition() {
    persistTask?.cancel()
    persistTask = Task {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      persistCurrentReadingPosition()
    }
  }

  private func persistCurrentReadingPosition() {
    guard let descriptor, let location = currentLocation() else { return }
    readingPositions[descriptor.fingerprint] = ReadingPosition(location: location)
    try? readingRepo.save(readingPositions)
  }

  private func updateJumpButtons() {
    canGoBack = !jumpList.backward.isEmpty
    canGoForward = !jumpList.forward.isEmpty
  }

  private func updatePageLabel() {
    guard let pdfView = pdfController.pdfView,
      let document = pdfView.document,
      let page = pdfController.visiblePage(in: pdfView)
    else {
      pageLabel = ""
      return
    }
    let index = document.index(for: page) + 1
    pageLabel = "\(index) / \(document.pageCount)"
  }
}
