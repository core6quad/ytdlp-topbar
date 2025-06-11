import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let ytDlpDir: URL = {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("ytdlp-topbar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    var ytDlpPath: URL { ytDlpDir.appendingPathComponent("yt-dlp") }
    @objc func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

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
    var optionsMenuItem: NSMenuItem?
    var optionsWindow: NSWindow?

    // Add progress tracking variables
    var downloadProgress: (percent: Double, speed: String, eta: String)? = nil {
        didSet { updateStatusUI() }
    }
    var ytDlpProgressWindow: NSWindow?

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

        let optionsItem = NSMenuItem(title: "Options…", action: #selector(showOptionsWindow), keyEquivalent: ",")
        optionsItem.target = self
        menu.addItem(optionsItem)
        self.optionsMenuItem = optionsItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q"))
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
        showYtDlpProgressWindow()
        downloadAndUnpackYtDlp()
        hideYtDlpProgressWindow()
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
                if line.range(of: #"\[download\]\s+([0-9.]+)%.*?at\s+([0-9.]+[KMG]?i?B/s).*?ETA\s+([0-9:]+)"#, options: .regularExpression) != nil {
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

    // --- Options Window Implementation ---
    @objc func showOptionsWindow() {
        if optionsWindow != nil {
            optionsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Options"
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))

        if #available(macOS 10.12, *) {
            // Autostart checkbox
            let autostartCheckbox = NSButton(checkboxWithTitle: "Start at login", target: self, action: #selector(toggleAutostart(_:)))
            autostartCheckbox.frame = NSRect(x: 20, y: 170, width: 200, height: 24)
            autostartCheckbox.state = isAutostartEnabled() ? .on : .off
            contentView.addSubview(autostartCheckbox)

            // yt-dlp version label
            let versionLabel = NSTextField(labelWithString: "yt-dlp version: Checking…")
            versionLabel.frame = NSRect(x: 20, y: 130, width: 350, height: 24)
            contentView.addSubview(versionLabel)
            // Only check version if not currently reinstalling
            if case .downloadingYtDlp = appStatus {
                versionLabel.stringValue = "yt-dlp version: (reinstalling...)"
            } else {
                getYtDlpVersion { version in
                    DispatchQueue.main.async {
                        versionLabel.stringValue = "yt-dlp version: \(version)"
                    }
                }
            }

            // Reinstall yt-dlp button
            let reinstallButton = NSButton(title: "Reinstall yt-dlp", target: self, action: #selector(reinstallYtDlp))
            reinstallButton.frame = NSRect(x: 20, y: 90, width: 150, height: 30)
            contentView.addSubview(reinstallButton)

            // Placeholder for more options
            let moreLabel = NSTextField(labelWithString: "More options coming soon…")
            moreLabel.frame = NSRect(x: 20, y: 50, width: 350, height: 24)
            contentView.addSubview(moreLabel)
        } else {
            // Fallback for older macOS versions
            let infoLabel = NSTextField(frame: NSRect(x: 20, y: 100, width: 350, height: 24))
            infoLabel.isEditable = false
            infoLabel.isBordered = false
            infoLabel.drawsBackground = false
            infoLabel.stringValue = "Options are only available on macOS 10.12 or newer."
            contentView.addSubview(infoLabel)
        }

        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.optionsWindow = window
        window.delegate = self
    }

    // --- Autostart on login ---
    @objc func toggleAutostart(_ sender: NSButton) {
        let enabled = (sender.state == .on)
        setAutostart(enabled: enabled)
    }

    func isAutostartEnabled() -> Bool {
        let helperBundleID = "com.core6quad.ytdlp-topbar.HelperApp"
        // Only use legacy API, SMAppService is not available in SwiftPM/Xcode 13-
        let jobs = (SMCopyAllJobDictionaries(kSMDomainUserLaunchd)?.takeRetainedValue() as? [[String: AnyObject]]) ?? []
        return jobs.contains { ($0["Label"] as? String) == helperBundleID }
    }

    func setAutostart(enabled: Bool) {
        let helperBundleID = "com.core6quad.ytdlp-topbar.HelperApp"
        if !SMLoginItemSetEnabled(helperBundleID as CFString, enabled) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Autostart Error"
            alert.informativeText = "Failed to change autostart."
            alert.runModal()
        }
    }

    // --- yt-dlp version ---
    func getYtDlpVersion(completion: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            guard FileManager.default.fileExists(atPath: self.ytDlpPath.path) else {
                completion("Not installed")
                return
            }
            let task = Process()
            task.launchPath = self.ytDlpPath.path
            task.arguments = ["--version"]
            let pipe = Pipe()
            task.standardOutput = pipe
            do {
                if #available(macOS 10.13, *) {
                    try task.run()
                } else {
                    task.launch()
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
                completion(version)
            } catch {
                completion("Error")
            }
        }
    }

    @objc func reinstallYtDlp() {
        appStatus = .downloadingYtDlp
        DispatchQueue.global().async {
            // Remove old yt-dlp if exists
            try? FileManager.default.removeItem(at: self.ytDlpPath)
            DispatchQueue.main.async {
                self.showYtDlpProgressWindow()
            }
            self.downloadAndUnpackYtDlp()
            DispatchQueue.main.async {
                self.hideYtDlpProgressWindow()
            }
        }
    }

    func showYtDlpProgressWindow() {
        DispatchQueue.main.async {
            if self.ytDlpProgressWindow != nil { return }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: false)
            window.title = "Downloading yt-dlp"
            window.isReleasedWhenClosed = false
            window.level = .floating

            let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
            if #available(macOS 10.12, *) {
                let label = NSTextField(labelWithString: "Downloading yt-dlp, please wait…")
                label.frame = NSRect(x: 20, y: 60, width: 280, height: 24)
                contentView.addSubview(label)
            } else {
                let label = NSTextField(frame: NSRect(x: 20, y: 60, width: 280, height: 24))
                label.stringValue = "Downloading yt-dlp, please wait…"
                label.isEditable = false
                label.isBordered = false
                label.drawsBackground = false
                contentView.addSubview(label)
            }

            let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 30, width: 280, height: 20))
            progress.style = .bar
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = 0
            progress.startAnimation(nil)
            progress.controlTint = .blueControlTint
            progress.usesThreadedAnimation = true
            progress.isDisplayedWhenStopped = true
            progress.identifier = NSUserInterfaceItemIdentifier("yt-dlp-progress")
            contentView.addSubview(progress)

            window.contentView = contentView
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.ytDlpProgressWindow = window
        }
    }

    func updateYtDlpProgress(_ percent: Double?) {
        DispatchQueue.main.async {
            guard let window = self.ytDlpProgressWindow,
                  let progress = window.contentView?.subviews.first(where: { $0.identifier?.rawValue == "yt-dlp-progress" }) as? NSProgressIndicator else { return }
            if let percent = percent {
                progress.isIndeterminate = false
                progress.doubleValue = percent / 100.0
            } else {
                progress.isIndeterminate = true
                progress.startAnimation(nil)
            }
        }
    }

    func hideYtDlpProgressWindow() {
        DispatchQueue.main.async {
            self.ytDlpProgressWindow?.close()
            self.ytDlpProgressWindow = nil
        }
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
                try? FileManager.default.removeItem(at: self.ytDlpPath)
                try FileManager.default.moveItem(at: location, to: tmpURL)
                try FileManager.default.moveItem(at: tmpURL, to: self.ytDlpPath)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.ytDlpPath.path)
                self.appStatus = .idle
            } catch {
                self.appStatus = .error("Failed to install yt-dlp: \(error)")
            }
        }
        // Progress reporting (only on macOS 10.13+)
        if #available(macOS 10.13, *) {
            task.progress.addObserver(self, forKeyPath: #keyPath(Progress.fractionCompleted), options: [.new], context: nil)
            task.resume()
            while sema.wait(timeout: .now() + 0.1) == .timedOut {
                let percent = task.progress.fractionCompleted.isFinite ? task.progress.fractionCompleted * 100.0 : nil
                self.updateYtDlpProgress(percent)
            }
            task.progress.removeObserver(self, forKeyPath: #keyPath(Progress.fractionCompleted), context: nil)
        } else {
            task.resume()
            while sema.wait(timeout: .now() + 0.1) == .timedOut {
                self.updateYtDlpProgress(nil)
            }
        }
    }

    // --- NSWindowDelegate to clear reference on close ---
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? NSWindow, win == self.optionsWindow {
            self.optionsWindow = nil
        }
    }

    // Handle KVO for yt-dlp download progress (no-op, prevents crash)
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(Progress.fractionCompleted) {
            // No-op: progress is polled in downloadAndUnpackYtDlp, so nothing needed here
            return
        }
        // For other keys, call super
        (self as NSObject).observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }
}

// Configure the app to not appear in the Dock or Cmd+Tab
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
