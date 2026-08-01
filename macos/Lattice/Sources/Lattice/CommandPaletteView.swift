import AppKit
import LatticeCore

@MainActor
private final class CommandInputField: NSTextField {
  var onMoveSelection: ((Int) -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.control) {
      if event.keyCode == 45 {
        onMoveSelection?(1)
        return
      }
      if event.keyCode == 35 {
        onMoveSelection?(-1)
        return
      }
    }
    super.keyDown(with: event)
  }
}

@MainActor
final class CommandPaletteView: NSVisualEffectView, NSTextFieldDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  var onExecute: ((CommandDescriptor) -> Void)?
  var onDismiss: (() -> Void)?

  private let commandField = CommandInputField()
  private let tableView = NSTableView()
  private let emptyLabel = NSTextField(labelWithString: "No matching commands")
  private var matches = CommandCatalog.commands

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

    let colon = NSTextField(labelWithString: ":")
    colon.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
    colon.translatesAutoresizingMaskIntoConstraints = false

    commandField.placeholderString = "fuzzy-find a command"
    commandField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    commandField.isBezeled = false
    commandField.drawsBackground = false
    commandField.focusRingType = .none
    commandField.delegate = self
    commandField.onMoveSelection = { [weak self] delta in self?.moveSelection(by: delta) }
    commandField.translatesAutoresizingMaskIntoConstraints = false

    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.rowHeight = 32
    tableView.intercellSpacing = .zero
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(activateSelection(_:))

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.isHidden = true
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(colon)
    addSubview(commandField)
    addSubview(separator)
    addSubview(scrollView)
    addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      colon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      colon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      colon.widthAnchor.constraint(equalToConstant: 12),
      commandField.leadingAnchor.constraint(equalTo: colon.trailingAnchor, constant: 2),
      commandField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      commandField.centerYAnchor.constraint(equalTo: colon.centerYAnchor),
      separator.topAnchor.constraint(equalTo: colon.bottomAnchor, constant: 10),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 3),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
      emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { nil }

  func present() {
    commandField.stringValue = ""
    updateMatches()
    isHidden = false
    window?.makeFirstResponder(commandField)
  }

  func dismiss() {
    isHidden = true
    onDismiss?()
  }

  func controlTextDidChange(_ obj: Notification) {
    updateMatches()
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.moveUp(_:)):
      moveSelection(by: -1)
      return true
    case #selector(NSResponder.moveDown(_:)):
      moveSelection(by: 1)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      activateSelectedCommand()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      dismiss()
      return true
    default:
      return false
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("CommandCell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? makeCell(identifier: identifier)
    let command = matches[row]
    let aliasText = command.aliases.isEmpty ? "" : "  \(command.aliases.joined(separator: ", "))"
    let shortcut = command.shortcut.map { "    \($0)" } ?? ""
    cell.textField?.stringValue = "\(command.name)\(aliasText)    \(command.summary)\(shortcut)"
    return cell
  }

  @objc private func activateSelection(_ sender: Any?) {
    activateSelectedCommand()
  }

  private func activateSelectedCommand() {
    guard !matches.isEmpty else {
      NSSound.beep()
      return
    }
    let selected = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
    guard matches.indices.contains(selected) else { return }
    let command = matches[selected]
    isHidden = true
    onExecute?(command)
  }

  private func updateMatches() {
    matches = CommandCatalog.matches(commandField.stringValue)
    tableView.reloadData()
    emptyLabel.isHidden = !matches.isEmpty
    if !matches.isEmpty {
      tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      tableView.scrollRowToVisible(0)
    }
  }

  private func moveSelection(by delta: Int) {
    guard !matches.isEmpty else { return }
    let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
    let row = min(matches.count - 1, max(0, current + delta))
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
  }

  private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 12)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.textField = label
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -9),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}
