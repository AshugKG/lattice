import AppKit

@MainActor
final class MarkPreviewCard: NSVisualEffectView {
  private let imageView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let messageLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .popover
    blendingMode = .withinWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.28
    layer?.shadowRadius = 12
    layer?.shadowOffset = NSSize(width: 0, height: -4)

    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.alignment = .center
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)
    addSubview(titleLabel)
    addSubview(messageLabel)
    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      imageView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      messageLabel.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      messageLabel.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func showLoading(title: String) {
    titleLabel.stringValue = title
    imageView.image = nil
    messageLabel.stringValue = "Loading preview…"
    isHidden = false
  }

  func show(image: NSImage, title: String) {
    titleLabel.stringValue = title
    imageView.image = image
    messageLabel.stringValue = ""
    isHidden = false
  }

  func showUnavailable(_ message: String, title: String) {
    titleLabel.stringValue = title
    imageView.image = nil
    messageLabel.stringValue = message
    isHidden = false
  }
}
