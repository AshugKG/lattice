import AppKit
import LatticeCore

@MainActor
private final class PortalMarksTableView: NSTableView {
  var onActivate: (() -> Void)?
  var onDismiss: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onDismiss?()
      return
    }
    if event.keyCode == 36 || event.keyCode == 76 {
      onActivate?()
      return
    }
    if event.modifierFlags.contains(.control) {
      if event.keyCode == 45 {
        moveDown(nil)
        return
      }
      if event.keyCode == 35 {
        moveUp(nil)
        return
      }
    }
    super.keyDown(with: event)
  }
}

@MainActor
final class PortalMarksView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
  var onActivate: ((PortalMark) -> Void)?
  var onDismiss: (() -> Void)?

  private let titleLabel = NSTextField(labelWithString: "Marks")
  private let tableView = PortalMarksTableView()
  private let emptyLabel = NSTextField(labelWithString: "No portal marks in this PDF")
  private var entries: [PortalMark] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .popover
    blendingMode = .withinWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 18
    layer?.shadowOffset = NSSize(width: 0, height: -5)

    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    let hint = NSTextField(
      labelWithString: "⌃N/⌃P or arrows to select · Enter to jump · Esc to close")
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = .secondaryLabelColor
    hint.translatesAutoresizingMaskIntoConstraints = false

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mark"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.rowHeight = 46
    tableView.intercellSpacing = .zero
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(activateSelection(_:))
    tableView.onActivate = { [weak self] in self?.activateSelectedMark() }
    tableView.onDismiss = { [weak self] in self?.dismiss() }

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.alignment = .center
    emptyLabel.isHidden = true
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(titleLabel)
    addSubview(hint)
    addSubview(scrollView)
    addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      hint.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { nil }

  func present(entries: [PortalMark]) {
    self.entries = entries
    titleLabel.stringValue = "Marks · \(entries.count)"
    tableView.reloadData()
    emptyLabel.isHidden = !entries.isEmpty
    isHidden = false
    window?.makeFirstResponder(tableView)
    if !entries.isEmpty {
      tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
  }

  func dismiss() {
    isHidden = true
    onDismiss?()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("MarkCell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? makeCell(identifier: identifier)
    let entry = entries[row]
    let direction = entry.endpoint == .source ? "→" : "←"
    let counterpartName = URL(fileURLWithPath: entry.counterpart.documentPath).lastPathComponent
    let headline =
      "p. \(entry.anchor.pageIndex + 1)  \(direction)  \(counterpartName) · p. \(entry.counterpart.pageIndex + 1)"
    let snippet = entry.anchor.quotedText ?? entry.counterpart.quotedText ?? "Portal snippet"
    cell.textField?.stringValue =
      "\(headline)\n\(snippet.replacingOccurrences(of: "\n", with: " "))"
    return cell
  }

  @objc private func activateSelection(_ sender: Any?) {
    activateSelectedMark()
  }

  private func activateSelectedMark() {
    guard entries.indices.contains(tableView.selectedRow) else { return }
    let entry = entries[tableView.selectedRow]
    isHidden = true
    onActivate?(entry)
  }

  private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let label = NSTextField(wrappingLabelWithString: "")
    label.font = .systemFont(ofSize: 12)
    label.maximumNumberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.textField = label
    cell.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}
