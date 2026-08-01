import AppKit

@MainActor
final class LatticeAppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: LatticeWindowController?
  private var pendingDocumentURLs: [URL] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()
    let controller = LatticeWindowController()
    windowController = controller
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)

    let commandLineURL = CommandLine.arguments.dropFirst().first(where: {
      $0.lowercased().hasSuffix(".pdf")
    }).map { URL(fileURLWithPath: $0) }
    if let url = pendingDocumentURLs.last ?? commandLineURL {
      pendingDocumentURLs.removeAll()
      openDocument(at: url)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    let urls =
      filenames
      .map { URL(fileURLWithPath: $0) }
      .filter { $0.pathExtension.lowercased() == "pdf" }
    guard !urls.isEmpty else {
      sender.reply(toOpenOrPrint: .failure)
      return
    }
    if windowController == nil {
      pendingDocumentURLs.append(contentsOf: urls)
    } else if let url = urls.last {
      openDocument(at: url)
    }
    sender.reply(toOpenOrPrint: .success)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    windowController?.showWindow(nil)
    windowController?.window?.makeKeyAndOrderFront(nil)
    return true
  }

  @objc private func openDocument(_ sender: Any?) {
    windowController?.presentOpenPanel()
  }

  private func openDocument(at url: URL) {
    guard let windowController else {
      pendingDocumentURLs.append(url)
      return
    }
    windowController.showWindow(nil)
    windowController.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    windowController.openDocument(at: url)
  }

  private func installMainMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About Lattice", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Lattice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let openItem = NSMenuItem(
      title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
    openItem.target = self
    fileMenu.addItem(openItem)
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenu.addItem(
      withTitle: "Find", action: #selector(LatticeWindowController.focusSearch(_:)),
      keyEquivalent: "f")
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(
      withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowItem.submenu = windowMenu
    mainMenu.addItem(windowItem)
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
  }
}
