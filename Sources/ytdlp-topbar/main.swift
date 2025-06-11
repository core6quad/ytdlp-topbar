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

    // Status tracking
    enum AppStatus {
        case idle
        case downloadingYtDlp
        case downloadingVideo(String)
        case error(String)
    }
    var appStatus: AppStatus = .idle {
        didSet { updateStatusUI() }
    }
    var infoMenuItem: NSMenuItem?
    var downloadMenuItem: NSMenuItem?

    // Add progress tracking variables
    var downloadProgress: (percent: Double, speed: String, eta: String)? = nil {
        didSet { updateStatusUI() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()

        // Create the menu
        let menu = NSMenu()
        let helloItem = NSMenuItem(title: "Hello World", action: nil, keyEquivalent: "")
        helloItem.isEnabled = false
        menu.addItem(helloItem)
        menu.addItem(NSMenuItem.separator())

        let infoItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        self.infoMenuItem = infoItem

        let downloadItem = NSMenuItem(title: "Download YouTube Video…", action: #selector(showDownloadWindow), keyEquivalent: "d")
        downloadItem.target = self
        menu.addItem(downloadItem)
        self.downloadMenuItem = downloadItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Download yt-dlp if needed
        DispatchQueue.global().async {
            self.ensureYtDlpPresent()
        }
    }

    func updateStatusUI() {
        DispatchQueue.main.async {
            // Update menu info
            switch self.appStatus {
            case .idle:
                self.infoMenuItem?.title = "Status: Idle"
                self.downloadMenuItem?.isEnabled = true
            case .downloadingYtDlp:
                self.infoMenuItem?.title = "Status: Downloading yt-dlp…"
                self.downloadMenuItem?.isEnabled = false
            case .downloadingVideo(let url):
                var status = "Status: Downloading video…"
                if let progress = self.downloadProgress {
                    status += String(format: "\n%.1f%%, %@, ETA: %@", progress.percent, progress.speed, progress.eta)
                }
                status += "\n\(url)"
                self.infoMenuItem?.title = status
                self.downloadMenuItem?.isEnabled = false
            case .error(let msg):
                self.infoMenuItem?.title = "Status: Error\n\(msg)"
                self.downloadMenuItem?.isEnabled = true
            }
            self.updateStatusIcon()
        }
    }

    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        switch appStatus {
        case .idle, .error:
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "ytdlp-topbar")
            } else if #available(macOS 10.12.2, *) {
                button.image = NSImage(named: NSImage.touchBarDownloadTemplateName)
            } else {
                button.image = NSImage(named: NSImage.Name("NSApplicationIcon"))
            }
        case .downloadingYtDlp, .downloadingVideo:
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle", accessibilityDescription: "Loading")
            } else {
                button.image = NSImage(named: NSImage.Name("NSRefreshTemplate"))
            }
        }
    }

    func ensureYtDlpPresent() {
        if FileManager.default.fileExists(atPath: ytDlpPath.path) {
            appStatus = .idle
            return
        }
        appStatus = .downloadingYtDlp
        downloadAndUnpackYtDlp()
    }

    func downloadAndUnpackYtDlp() {
        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp")!
        let tmpURL = ytDlpDir.appendingPathComponent("yt-dlp.download")
        let sema = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            defer { sema.signal() }
            guard let location = location, error == nil else {
                self.appStatus = .error("Failed to download yt-dlp")
                return
            }
            do {
                try FileManager.default.moveItem(at: location, to: tmpURL)
                try FileManager.default.moveItem(at: tmpURL, to: self.ytDlpPath)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.ytDlpPath.path)
                self.appStatus = .idle
            } catch {
                self.appStatus = .error("Failed to install yt-dlp: \(error)")
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
            self.appStatus = .downloadingVideo(url)
            self.downloadProgress = nil
            let task = Process()
            task.launchPath = self.ytDlpPath.path
            task.arguments = ["-o", saveURL.path, url, "--progress", "--newline"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            // Progress parsing
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                // Try to parse yt-dlp progress lines
                // Example: [download]   0.0% of ~4.97MiB at  1.23MiB/s ETA 00:04
                if let match = line.range(of: #"\[download\]\s+([0-9.]+)%.*?at\s+([0-9.]+[KMG]?i?B/s).*?ETA\s+([0-9:]+)"#, options: .regularExpression) {
                    let regex = try! NSRegularExpression(pattern: #"\[download\]\s+([0-9.]+)%.*?at\s+([0-9.]+[KMG]?i?B/s).*?ETA\s+([0-9:]+)"#)
                    if let result = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                       let percentRange = Range(result.range(at: 1), in: line),
                       let speedRange = Range(result.range(at: 2), in: line),
                       let etaRange = Range(result.range(at: 3), in: line) {
                        let percent = Double(line[percentRange]) ?? 0
                        let speed = String(line[speedRange])
                        let eta = String(line[etaRange])
                        self.downloadProgress = (percent, speed, eta)
                    }
                }
            }

            task.terminationHandler = { proc in
                DispatchQueue.main.async {
                    self.downloadProgress = nil
                    if proc.terminationStatus == 0 {
                        self.appStatus = .idle
                        let alert = NSAlert()
                        alert.messageText = "Download Complete"
                        alert.informativeText = "The video was downloaded successfully."
                        alert.runModal()
                    } else {
                        self.appStatus = .error("yt-dlp failed to download the video.")
                        let alert = NSAlert()
                        alert.messageText = "Download Failed"
                        alert.informativeText = "yt-dlp failed to download the video."
                        alert.runModal()
                    }
                }
            }
            do {
                if #available(macOS 10.13, *) {
                    try task.run()
                } else {
                    task.launch()
                }
            } catch {
                self.appStatus = .error("Failed to launch yt-dlp: \(error)")
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
