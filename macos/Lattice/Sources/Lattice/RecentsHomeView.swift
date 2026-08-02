@preconcurrency import AppKit
import LatticeCore
import PDFKit

@MainActor
final class RecentsHomeView: NSView {
  var onOpen: ((URL) -> Void)?
  var onBrowse: (() -> Void)?

  private let scrollView = NSScrollView()
  private let contentView = FlippedView()
  private let titleLabel = NSTextField(labelWithString: "Recent PDFs")
  private let emptyLabel = NSTextField(labelWithString: "Drop a PDF here, or choose Open")
  private let browseButton = NSButton(title: "Open PDF…", target: nil, action: nil)
  private var cards: [RecentCardView] = []
  private var recents: [RecentDocument] = []
  private let thumbnailCache = NSCache<NSString, NSImage>()
  private let thumbnailQueue = DispatchQueue(
    label: "com.ashugkg.lattice.recents-thumbnails", qos: .userInitiated)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
    titleLabel.textColor = .labelColor
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false

    browseButton.bezelStyle = .rounded
    browseButton.target = self
    browseButton.action = #selector(browsePressed(_:))
    browseButton.translatesAutoresizingMaskIntoConstraints = false

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .noBorder
    scrollView.documentView = contentView

    addSubview(titleLabel)
    addSubview(browseButton)
    addSubview(scrollView)
    addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 28),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
      browseButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      browseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
      scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
      emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 12),
    ])

    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { nil }

  func setRecents(_ items: [RecentDocument]) {
    recents = items
    emptyLabel.isHidden = !items.isEmpty
    titleLabel.stringValue = items.isEmpty ? "Lattice" : "Recent PDFs"
    rebuildCards()
  }

  override func layout() {
    super.layout()
    layoutCards()
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedPDFURL(from: sender) == nil ? [] : .copy
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let url = droppedPDFURL(from: sender) else { return false }
    onOpen?(url)
    return true
  }

  @objc private func browsePressed(_ sender: Any?) {
    onBrowse?()
  }

  private func rebuildCards() {
    for card in cards {
      card.removeFromSuperview()
    }
    cards = recents.map { recent in
      let card = RecentCardView(recent: recent)
      card.onOpen = { [weak self] url in self?.onOpen?(url) }
      contentView.addSubview(card)
      loadThumbnail(for: recent, into: card)
      return card
    }
    layoutCards()
  }

  private func layoutCards() {
    let width = max(scrollView.contentView.bounds.width, 320)
    let cardWidth: CGFloat = 180
    let cardHeight: CGFloat = 240
    let spacing: CGFloat = 16
    let columns = max(1, Int((width + spacing) / (cardWidth + spacing)))
    let totalWidth = CGFloat(columns) * cardWidth + CGFloat(max(0, columns - 1)) * spacing
    let leading = max(0, (width - totalWidth) / 2)
    let rows = cards.isEmpty ? 0 : (cards.count + columns - 1) / columns
    let contentHeight = max(
      scrollView.contentView.bounds.height,
      CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * spacing + 8
    )
    contentView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)

    for (index, card) in cards.enumerated() {
      let row = index / columns
      let column = index % columns
      card.frame = NSRect(
        x: leading + CGFloat(column) * (cardWidth + spacing),
        y: CGFloat(row) * (cardHeight + spacing),
        width: cardWidth,
        height: cardHeight
      )
    }
  }

  private func loadThumbnail(for recent: RecentDocument, into card: RecentCardView) {
    let fingerprint = recent.fingerprint
    if let image = thumbnailCache.object(forKey: fingerprint as NSString) {
      card.setThumbnail(image)
      return
    }
    let path = recent.path
    thumbnailQueue.async { [weak self] in
      let image = RecentThumbnailRenderer.render(at: path)
      Task { @MainActor in
        guard let self, let image else { return }
        self.thumbnailCache.setObject(image, forKey: fingerprint as NSString)
        card.setThumbnail(image)
      }
    }
  }

  private func droppedPDFURL(from sender: NSDraggingInfo) -> URL? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: ["com.adobe.pdf"],
    ]
    return sender.draggingPasteboard
      .readObjects(forClasses: [NSURL.self], options: options)?
      .compactMap { $0 as? URL }
      .first { $0.pathExtension.lowercased() == "pdf" }
  }
}

private enum RecentThumbnailRenderer {
  static func render(at path: String) -> NSImage? {
    let url = URL(fileURLWithPath: path)
    guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
    return page.thumbnail(of: NSSize(width: 320, height: 420), for: .cropBox)
  }
}

@MainActor
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
private final class RecentCardView: NSView {
  var onOpen: ((URL) -> Void)?

  private let recent: RecentDocument
  private let imageView = NSImageView()
  private let nameLabel = NSTextField(labelWithString: "")
  private let metaLabel = NSTextField(labelWithString: "")
  private var isPressed = false

  init(recent: RecentDocument) {
    self.recent = recent
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor

    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = 6
    imageView.layer?.masksToBounds = true
    imageView.translatesAutoresizingMaskIntoConstraints = false

    nameLabel.stringValue = recent.name
    nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    nameLabel.lineBreakMode = .byTruncatingMiddle
    nameLabel.translatesAutoresizingMaskIntoConstraints = false

    metaLabel.stringValue = "\(max(1, recent.pageCount)) pages"
    metaLabel.font = .systemFont(ofSize: 11, weight: .regular)
    metaLabel.textColor = .secondaryLabelColor
    metaLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(imageView)
    addSubview(nameLabel)
    addSubview(metaLabel)
    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      imageView.heightAnchor.constraint(equalToConstant: 170),
      nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 10),
      nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
      metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      metaLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func setThumbnail(_ image: NSImage) {
    imageView.image = image
  }

  override func mouseDown(with event: NSEvent) {
    isPressed = true
    alphaValue = 0.85
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      isPressed = false
      alphaValue = 1
    }
    guard isPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onOpen?(recent.url)
  }
}
