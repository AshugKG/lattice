import AppKit

@MainActor
final class LatticeAppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: LatticeWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()
    let controller = LatticeWindowController()
    windowController = controller
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)

    if let path = CommandLine.arguments.dropFirst().first(where: {
      $0.lowercased().hasSuffix(".pdf")
    }) {
      controller.openDocument(at: URL(fileURLWithPath: path))
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    guard let first = filenames.first else {
      sender.reply(toOpenOrPrint: .failure)
      return
    }
    windowController?.openDocument(at: URL(fileURLWithPath: first))
    sender.reply(toOpenOrPrint: .success)
  }

  @objc private func openDocument(_ sender: Any?) {
    windowController?.presentOpenPanel()
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
