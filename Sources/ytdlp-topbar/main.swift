import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let ytDlpDir: URL = {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("ytdlp-topbar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    var ytDlpPath: URL { ytDlpDir.appendingPathComponent("yt-dlp") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Download yt-dlp if needed
        ensureYtDlpPresent()

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
        let downloadItem = NSMenuItem(title: "Download YouTube Video…", action: #selector(showDownloadWindow), keyEquivalent: "d")
        downloadItem.target = self
        menu.addItem(downloadItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    func ensureYtDlpPresent() {
        if FileManager.default.fileExists(atPath: ytDlpPath.path) {
            return
        }
        downloadAndUnpackYtDlp()
    }

    func downloadAndUnpackYtDlp() {
        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp")!
        let tmpURL = ytDlpDir.appendingPathComponent("yt-dlp.download")
        let sema = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            defer { sema.signal() }
            guard let location = location, error == nil else { return }
            do {
                try FileManager.default.moveItem(at: location, to: tmpURL)
                try FileManager.default.moveItem(at: tmpURL, to: self.ytDlpPath)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.ytDlpPath.path)
            } catch {
                print("Failed to install yt-dlp: \(error)")
            }
        }
        task.resume()
        sema.wait()
    }

    @objc func showDownloadWindow() {
        let alert = NSAlert()
        alert.messageText = "Download YouTube Video"
        alert.informativeText = "Enter the YouTube URL:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                downloadYouTubeVideo(url: url)
            }
        }
    }

    func downloadYouTubeVideo(url: String) {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Downloaded Video As"
        savePanel.nameFieldStringValue = "video"
        savePanel.canCreateDirectories = true
        savePanel.begin { result in
            guard result == .OK, let saveURL = savePanel.url else { return }
            let task = Process()
            task.launchPath = self.ytDlpPath.path
            task.arguments = ["-o", saveURL.path, url]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            task.terminationHandler = { proc in
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    if proc.terminationStatus == 0 {
                        alert.messageText = "Download Complete"
                        alert.informativeText = "The video was downloaded successfully."
                    } else {
                        alert.messageText = "Download Failed"
                        alert.informativeText = "yt-dlp failed to download the video."
                    }
                    alert.runModal()
                }
            }
            do {
                if #available(macOS 10.13, *) {
                    try task.run()
                } else {
                    task.launch()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Error"
                alert.informativeText = "Failed to launch yt-dlp: \(error)"
                alert.runModal()
            }
        }
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
