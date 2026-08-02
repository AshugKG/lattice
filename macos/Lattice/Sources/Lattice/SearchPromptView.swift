import AppKit
import LatticeCore

@MainActor
final class SearchPromptView: NSVisualEffectView, NSTextFieldDelegate {
  enum Direction: Equatable {
    case forward
    case backward
  }

  var onSearch: ((String, Direction) -> Void)?
  var onDismiss: (() -> Void)?

  private let promptLabel = NSTextField(labelWithString: "/")
  private let queryField = NSTextField()
  private var direction: Direction = .forward
  private var keyMonitor: Any?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .popover
    blendingMode = .withinWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 16
    layer?.shadowOffset = NSSize(width: 0, height: -5)

    promptLabel.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
    promptLabel.translatesAutoresizingMaskIntoConstraints = false

    queryField.placeholderString = "search"
    queryField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    queryField.isBezeled = false
    queryField.drawsBackground = false
    queryField.focusRingType = .none
    queryField.delegate = self
    queryField.translatesAutoresizingMaskIntoConstraints = false

    addSubview(promptLabel)
    addSubview(queryField)
    NSLayoutConstraint.activate([
      promptLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      promptLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      promptLabel.widthAnchor.constraint(equalToConstant: 14),
      queryField.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 2),
      queryField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      queryField.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { nil }

  func present(direction: Direction, initialQuery: String = "") {
    self.direction = direction
    promptLabel.stringValue = direction == .forward ? "/" : "?"
    queryField.placeholderString = direction == .forward ? "search forward" : "search backward"
    queryField.stringValue = initialQuery
    isHidden = false
    startKeyMonitor()
    window?.makeFirstResponder(queryField)
    if let editor = window?.fieldEditor(true, for: queryField) as? NSTextView {
      let end = (queryField.stringValue as NSString).length
      editor.selectedRange = NSRange(location: end, length: 0)
    }
  }

  func dismiss() {
    stopKeyMonitor()
    isHidden = true
    onDismiss?()
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      submit()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      dismiss()
      return true
    default:
      return false
    }
  }

  private func submit() {
    let query = queryField.stringValue
    let direction = self.direction
    stopKeyMonitor()
    isHidden = true
    onSearch?(query, direction)
  }

  private func startKeyMonitor() {
    stopKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      switch event.keyCode {
      case 36, 76:
        Task { @MainActor [weak self] in
          guard let self, !self.isHidden else { return }
          self.submit()
        }
        return nil
      case 53:
        Task { @MainActor [weak self] in
          guard let self, !self.isHidden else { return }
          self.dismiss()
        }
        return nil
      default:
        return event
      }
    }
  }

  private func stopKeyMonitor() {
    guard let keyMonitor else { return }
    NSEvent.removeMonitor(keyMonitor)
    self.keyMonitor = nil
  }
}
