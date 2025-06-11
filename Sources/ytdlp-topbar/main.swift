import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "ytdlp-topbar")
            } else if #available(macOS 10.12.2, *) {
                button.image = NSImage(named: NSImage.touchBarDownloadTemplateName)
            } else {
                button.image = NSImage(named: NSImage.Name("NSApplicationIcon"))
            }
        }

        // Create the menu
        let menu = NSMenu()
        let helloItem = NSMenuItem(title: "Hello World", action: nil, keyEquivalent: "")
        helloItem.isEnabled = false
        menu.addItem(helloItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// Configure the app to not appear in the Dock or Cmd+Tab
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
