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

    // FFmpeg path and status
    var ffmpegPath: URL { ytDlpDir.appendingPathComponent("ffmpeg") }
    var ffmpegProgressWindow: NSWindow?

    // Format selection
    let supportedFormats = ["mp4", "mkv", "webm", "flv", "mp3"]
    var selectedFormat: String = "mp4"

    // Track selection state
    struct TrackInfo {
        let formatID: String
        let ext: String
        let resolution: String
        let fps: String
        let vcodec: String
        let acodec: String
        let filesize: Int64?
        let formatNote: String
    }
    var availableVideoTracks: [TrackInfo] = []
    var availableAudioTracks: [TrackInfo] = []
    var selectedVideoFormatIDs: Set<String> = []
    var selectedAudioFormatIDs: Set<String> = []

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

    // Caption options
    var downloadCaptions: Bool = false
    var embedCaptions: Bool = false

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
        let needsYtDlp = !FileManager.default.fileExists(atPath: ytDlpPath.path)
        let needsFfmpeg = !FileManager.default.fileExists(atPath: ffmpegPath.path)
        if !needsYtDlp && !needsFfmpeg {
            appStatus = .idle
            return
        }
        if needsYtDlp {
            appStatus = .downloadingYtDlp
            showYtDlpProgressWindow()
            downloadAndUnpackYtDlp()
            hideYtDlpProgressWindow()
        }
        if needsFfmpeg {
            showFfmpegProgressWindow()
            downloadAndUnpackFfmpeg()
            hideFfmpegProgressWindow()
        }
        appStatus = .idle
    }

    // --- FFmpeg Download ---
    func showFfmpegProgressWindow() {
        DispatchQueue.main.async {
            if self.ffmpegProgressWindow != nil { return }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                styleMask: [.titled],
                backing: .buffered,
                defer: false)
            window.title = "Downloading ffmpeg"
            window.isReleasedWhenClosed = false
            window.level = .floating

            let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
            let label: NSTextField
            if #available(macOS 10.12, *) {
                label = NSTextField(labelWithString: "Downloading ffmpeg, please wait…")
            } else {
                label = NSTextField(frame: NSRect(x: 20, y: 70, width: 280, height: 24))
                label.stringValue = "Downloading ffmpeg, please wait…"
                label.isEditable = false
                label.isBordered = false
                label.drawsBackground = false
            }
            label.frame = NSRect(x: 20, y: 70, width: 280, height: 24)
            contentView.addSubview(label)

            let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 40, width: 280, height: 20))
            progress.style = .bar
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = 0
            progress.startAnimation(nil)
            progress.controlTint = .blueControlTint
            progress.usesThreadedAnimation = true
            progress.isDisplayedWhenStopped = true
            progress.identifier = NSUserInterfaceItemIdentifier("ffmpeg-progress")
            contentView.addSubview(progress)

            let redownloadButton: NSButton
            if #available(macOS 10.12, *) {
                redownloadButton = NSButton(title: "Redownload", target: self, action: #selector(self.redownloadFfmpeg))
            } else {
                redownloadButton = NSButton(frame: NSRect(x: 200, y: 10, width: 100, height: 24))
                redownloadButton.title = "Redownload"
                redownloadButton.target = self
                redownloadButton.action = #selector(self.redownloadFfmpeg)
            }
            redownloadButton.frame = NSRect(x: 200, y: 10, width: 100, height: 24)
            contentView.addSubview(redownloadButton)

            window.contentView = contentView
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.ffmpegProgressWindow = window
        }
    }

    @objc func redownloadFfmpeg() {
        DispatchQueue.global().async {
            try? FileManager.default.removeItem(at: self.ffmpegPath)
            self.showFfmpegProgressWindow()
            self.downloadAndUnpackFfmpeg()
            self.hideFfmpegProgressWindow()
        }
    }

    func updateFfmpegProgress(_ percent: Double?) {
        DispatchQueue.main.async {
            guard let window = self.ffmpegProgressWindow,
                  let progress = window.contentView?.subviews.first(where: { $0.identifier?.rawValue == "ffmpeg-progress" }) as? NSProgressIndicator else { return }
            if let percent = percent {
                progress.isIndeterminate = false
                progress.doubleValue = percent / 100.0
            } else {
                progress.isIndeterminate = true
                progress.startAnimation(nil)
            }
        }
    }

    func hideFfmpegProgressWindow() {
        DispatchQueue.main.async {
            self.ffmpegProgressWindow?.close()
            self.ffmpegProgressWindow = nil
        }
    }

    func downloadAndUnpackFfmpeg() {
        // Download static ffmpeg binary for macOS (from evermeet.cx or gyan.dev)
        let url = URL(string: "https://evermeet.cx/ffmpeg/ffmpeg-6.1.1.zip")!
        let tmpZip = ytDlpDir.appendingPathComponent("ffmpeg.zip")
        let sema = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            defer { sema.signal() }
            guard let location = location, error == nil else { return }
            do {
                try? FileManager.default.removeItem(at: tmpZip)
                try FileManager.default.moveItem(at: location, to: tmpZip)
                // Unzip ffmpeg binary
                let unzipTask = Process()
                unzipTask.launchPath = "/usr/bin/unzip"
                unzipTask.arguments = ["-o", tmpZip.path, "-d", self.ytDlpDir.path]
                if #available(macOS 10.13, *) {
                    try? unzipTask.run()
                } else {
                    unzipTask.launch()
                }
                unzipTask.waitUntilExit()
                // ffmpeg binary will be at ytDlpDir/ffmpeg
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.ffmpegPath.path)
                try? FileManager.default.removeItem(at: tmpZip)
            } catch {}
        }
        if #available(macOS 10.13, *) {
            task.progress.addObserver(self, forKeyPath: #keyPath(Progress.fractionCompleted), options: [.new], context: nil)
            task.resume()
            while sema.wait(timeout: .now() + 0.1) == .timedOut {
                let percent = task.progress.fractionCompleted.isFinite ? task.progress.fractionCompleted * 100.0 : nil
                self.updateFfmpegProgress(percent)
            }
            task.progress.removeObserver(self, forKeyPath: #keyPath(Progress.fractionCompleted), context: nil)
        } else {
            task.resume()
            while sema.wait(timeout: .now() + 0.1) == .timedOut {
                self.updateFfmpegProgress(nil)
            }
        }
    }

    // --- Download Window with format selector and captions ---
    @objc func showDownloadWindow() {
        let alert = NSAlert()
        alert.messageText = "Download YouTube Video"
        alert.informativeText = "Enter the YouTube URL and options:"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 420))

        let input = NSTextField(frame: NSRect(x: 0, y: 396, width: 380, height: 24))
        input.placeholderString = "YouTube URL"
        container.addSubview(input)

        // Format selector
        var formatLabel: NSTextField
        if #available(macOS 10.12, *) {
            formatLabel = NSTextField(labelWithString: "Format:")
        } else {
            formatLabel = NSTextField(frame: NSRect(x: 0, y: 372, width: 50, height: 20))
            formatLabel.stringValue = "Format:"
            formatLabel.isEditable = false
            formatLabel.isBordered = false
            formatLabel.drawsBackground = false
        }
        formatLabel.frame = NSRect(x: 0, y: 372, width: 50, height: 20)
        container.addSubview(formatLabel)

        let formatPopup = NSPopUpButton(frame: NSRect(x: 60, y: 370, width: 100, height: 24), pullsDown: false)
        formatPopup.addItems(withTitles: supportedFormats)
        formatPopup.selectItem(withTitle: selectedFormat)
        container.addSubview(formatPopup)

        var captionsCheckbox: NSButton
        var embedCheckbox: NSButton

        if #available(macOS 10.12, *) {
            captionsCheckbox = NSButton(checkboxWithTitle: "Download captions", target: nil, action: nil)
            captionsCheckbox.frame = NSRect(x: 0, y: 346, width: 200, height: 20)
            captionsCheckbox.state = downloadCaptions ? .on : .off
            container.addSubview(captionsCheckbox)

            embedCheckbox = NSButton(checkboxWithTitle: "Embed captions", target: nil, action: nil)
            embedCheckbox.frame = NSRect(x: 0, y: 322, width: 200, height: 20)
            embedCheckbox.state = embedCaptions ? .on : .off
            container.addSubview(embedCheckbox)
        } else {
            captionsCheckbox = NSButton(frame: NSRect(x: 0, y: 346, width: 200, height: 20))
            captionsCheckbox.setButtonType(.switch)
            captionsCheckbox.title = "Download captions"
            captionsCheckbox.state = downloadCaptions ? .on : .off
            container.addSubview(captionsCheckbox)

            embedCheckbox = NSButton(frame: NSRect(x: 0, y: 322, width: 200, height: 20))
            embedCheckbox.setButtonType(.switch)
            embedCheckbox.title = "Embed captions"
            embedCheckbox.state = embedCaptions ? .on : .off
            container.addSubview(embedCheckbox)
        }

        // Video/audio track selectors (multi-choice, checkboxes, autoprobe)
        var videoLabel: NSTextField
        if #available(macOS 10.12, *) {
            videoLabel = NSTextField(labelWithString: "Video Tracks:")
        } else {
            videoLabel = NSTextField(frame: NSRect(x: 0, y: 298, width: 100, height: 20))
            videoLabel.stringValue = "Video Tracks:"
            videoLabel.isEditable = false
            videoLabel.isBordered = false
            videoLabel.drawsBackground = false
        }
        videoLabel.frame = NSRect(x: 0, y: 298, width: 100, height: 20)
        container.addSubview(videoLabel)

        // --- Video ScrollView with always-on vertical scrollbar ---
        let videoScroll = NSScrollView(frame: NSRect(x: 0, y: 170, width: 380, height: 120))
        videoScroll.hasVerticalScroller = true
        videoScroll.autohidesScrollers = false
        videoScroll.borderType = .bezelBorder
        videoScroll.drawsBackground = false
        let videoList = NSStackView()
        videoList.orientation = .vertical
        videoList.alignment = .leading
        videoList.spacing = 2
        videoList.translatesAutoresizingMaskIntoConstraints = false
        videoScroll.documentView = videoList
        // Only use widthAnchor if available (macOS 10.11+)
        if #available(macOS 10.11, *) {
            videoList.widthAnchor.constraint(equalTo: videoScroll.widthAnchor).isActive = true
        }
        container.addSubview(videoScroll)

        var audioLabel: NSTextField
        if #available(macOS 10.12, *) {
            audioLabel = NSTextField(labelWithString: "Audio Tracks:")
        } else {
            audioLabel = NSTextField(frame: NSRect(x: 0, y: 146, width: 100, height: 20))
            audioLabel.stringValue = "Audio Tracks:"
            audioLabel.isEditable = false
            audioLabel.isBordered = false
            audioLabel.drawsBackground = false
        }
        audioLabel.frame = NSRect(x: 0, y: 146, width: 100, height: 20)
        container.addSubview(audioLabel)

        // --- Audio ScrollView with always-on vertical scrollbar ---
        let audioScroll = NSScrollView(frame: NSRect(x: 0, y: 18, width: 380, height: 120))
        audioScroll.hasVerticalScroller = true
        audioScroll.autohidesScrollers = false
        audioScroll.borderType = .bezelBorder
        audioScroll.drawsBackground = false
        let audioList = NSStackView()
        audioList.orientation = .vertical
        audioList.alignment = .leading
        audioList.spacing = 2
        audioList.translatesAutoresizingMaskIntoConstraints = false
        audioScroll.documentView = audioList
        if #available(macOS 10.11, *) {
            audioList.widthAnchor.constraint(equalTo: audioScroll.widthAnchor).isActive = true
        }
        container.addSubview(audioScroll)

        // Loading indicator
        let loadingIndicator = NSProgressIndicator(frame: NSRect(x: 340, y: 300, width: 24, height: 24))
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.isHidden = true
        container.addSubview(loadingIndicator)

        // Helper to update checkboxes (macOS 10.11+ only)
        func updateTrackCheckboxes() {
            // Remove all previous checkboxes
            if #available(macOS 10.11, *) {
                for v in videoList.arrangedSubviews {
                    videoList.removeArrangedSubview(v)
                    v.removeFromSuperview()
                }
                for a in audioList.arrangedSubviews {
                    audioList.removeArrangedSubview(a)
                    a.removeFromSuperview()
                }
            } else {
                for v in videoList.subviews { v.removeFromSuperview() }
                for a in audioList.subviews { a.removeFromSuperview() }
            }
            // Add new checkboxes, all unchecked by default
            for (idx, v) in availableVideoTracks.enumerated() {
                let cb: NSButton
                if #available(macOS 10.12, *) {
                    cb = NSButton(checkboxWithTitle:
                        "\(v.resolution.isEmpty ? "" : "\(v.resolution)p") \(v.fps.isEmpty ? "" : "\(v.fps)fps") \(v.ext)\(v.formatNote.isEmpty ? "" : " (\(v.formatNote))")\(v.filesize != nil ? String(format: " %.1fMB", Double(v.filesize!) / 1024 / 1024) : "") [\(v.formatID)]",
                        target: self, action: #selector(AppDelegate.handleVideoTrackCheckboxChanged(_:)))
                } else {
                    cb = NSButton(frame: NSRect(x: 0, y: 0, width: 340, height: 20))
                    cb.setButtonType(.switch)
                    cb.title = "\(v.resolution.isEmpty ? "" : "\(v.resolution)p") \(v.fps.isEmpty ? "" : "\(v.fps)fps") \(v.ext)\(v.formatNote.isEmpty ? "" : " (\(v.formatNote))")\(v.filesize != nil ? String(format: " %.1fMB", Double(v.filesize!) / 1024 / 1024) : "") [\(v.formatID)]"
                    cb.target = self
                    cb.action = #selector(AppDelegate.handleVideoTrackCheckboxChanged(_:))
                }
                cb.state = .off // Unchecked by default
                cb.tag = idx
                if #available(macOS 10.11, *) {
                    videoList.addArrangedSubview(cb)
                } else {
                    videoList.addSubview(cb)
                }
            }
            for (idx, a) in availableAudioTracks.enumerated() {
                let cb: NSButton
                if #available(macOS 10.12, *) {
                    cb = NSButton(checkboxWithTitle:
                        "\(a.acodec) \(a.ext)\(a.formatNote.isEmpty ? "" : " (\(a.formatNote))")\(a.filesize != nil ? String(format: " %.1fMB", Double(a.filesize!) / 1024 / 1024) : "") [\(a.formatID)]",
                        target: self, action: #selector(AppDelegate.handleAudioTrackCheckboxChanged(_:)))
                } else {
                    cb = NSButton(frame: NSRect(x: 0, y: 0, width: 340, height: 20))
                    cb.setButtonType(.switch)
                    cb.title = "\(a.acodec) \(a.ext)\(a.formatNote.isEmpty ? "" : " (\(a.formatNote))")\(a.filesize != nil ? String(format: " %.1fMB", Double(a.filesize!) / 1024 / 1024) : "") [\(a.formatID)]"
                    cb.target = self
                    cb.action = #selector(AppDelegate.handleAudioTrackCheckboxChanged(_:))
                }
                cb.state = .off // Unchecked by default
                cb.tag = idx
                if #available(macOS 10.11, *) {
                    audioList.addArrangedSubview(cb)
                } else {
                    audioList.addSubview(cb)
                }
            }
        }

        // Autoprobe logic with loading animation
        func autoprobeIfValidURL(_ url: String) {
            guard !url.isEmpty, url.contains("://") else { return }
            loadingIndicator.isHidden = false
            loadingIndicator.startAnimation(nil)
            self.probeTracks(url: url) { videoTracks, audioTracks in
                self.availableVideoTracks = videoTracks.sorted { ($0.resolution, $0.fps) > ($1.resolution, $1.fps) }
                self.availableAudioTracks = audioTracks
                DispatchQueue.main.async {
                    // Clear all selections (everything unchecked by default)
                    self.selectedVideoFormatIDs.removeAll()
                    self.selectedAudioFormatIDs.removeAll()
                    updateTrackCheckboxes()
                    loadingIndicator.stopAnimation(nil)
                    loadingIndicator.isHidden = true
                }
            }
        }
        // Observe input changes for autoprobe
        NotificationCenter.default.addObserver(forName: NSTextField.textDidChangeNotification, object: input, queue: .main) { _ in
            autoprobeIfValidURL(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Initial autoprobe if prefilled
        autoprobeIfValidURL(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))

        alert.accessoryView = container
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            downloadCaptions = (captionsCheckbox.state == .on)
            embedCaptions = (embedCheckbox.state == .on)
            if let selected = formatPopup.selectedItem?.title {
                selectedFormat = selected
            }
            // No need to updateSelectedTracks, checkboxes are always up to date
            if !url.isEmpty {
                downloadYouTubeVideo(url: url)
            }
        }
    }

    // Checkbox actions must be class methods and visible to selectors
    @objc func handleVideoTrackCheckboxChanged(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < availableVideoTracks.count else { return }
        let id = availableVideoTracks[idx].formatID
        if sender.state == .on {
            selectedVideoFormatIDs.insert(id)
        } else {
            selectedVideoFormatIDs.remove(id)
        }
    }

    @objc func handleAudioTrackCheckboxChanged(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < availableAudioTracks.count else { return }
        let id = availableAudioTracks[idx].formatID
        if sender.state == .on {
            selectedAudioFormatIDs.insert(id)
        } else {
            selectedAudioFormatIDs.remove(id)
        }
    }

    @objc func updateSelectedTracksAction(_ sender: Any?) {
        // No-op: selection is updated in showDownloadWindow's updateSelectedTracks closure
    }

    func probeTracks(url: String, completion: @escaping ([TrackInfo], [TrackInfo]) -> Void) {
        DispatchQueue.global().async {
            let task = Process()
            task.launchPath = self.ytDlpPath.path
            task.arguments = ["-J", url]
            let pipe = Pipe()
            task.standardOutput = pipe
            do {
                if #available(macOS 10.13, *) {
                    try task.run()
                } else {
                    task.launch()
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let formats = json["formats"] as? [[String: Any]] else {
                    completion([], [])
                    return
                }
                var videoTracks: [TrackInfo] = []
                var audioTracks: [TrackInfo] = []
                for f in formats {
                    let formatID = f["format_id"] as? String ?? ""
                    let ext = f["ext"] as? String ?? ""
                    let resolution = f["height"].flatMap { "\($0)" } ?? ""
                    let fps = f["fps"].flatMap { "\($0)" } ?? ""
                    let vcodec = f["vcodec"] as? String ?? ""
                    let acodec = f["acodec"] as? String ?? ""
                    let filesize = (f["filesize"] as? NSNumber)?.int64Value
                    let note = f["format_note"] as? String ?? ""
                    let info = TrackInfo(formatID: formatID, ext: ext, resolution: resolution, fps: fps, vcodec: vcodec, acodec: acodec, filesize: filesize, formatNote: note)
                    if vcodec != "none" && !resolution.isEmpty {
                        videoTracks.append(info)
                    } else if acodec != "none" && vcodec == "none" {
                        audioTracks.append(info)
                    }
                }
                completion(videoTracks, audioTracks)
            } catch {
                completion([], [])
            }
        }
    }

    func downloadYouTubeVideo(url: String) {
        let savePanel = NSSavePanel()
        savePanel.title = "Save Downloaded Video As"
        savePanel.nameFieldStringValue = "video.\(selectedFormat)"
        savePanel.allowedFileTypes = [selectedFormat]
        savePanel.canCreateDirectories = true
        savePanel.begin { result in
            guard result == .OK, let saveURL = savePanel.url else { return }
            self.appStatus = .downloadingVideo(url)
            self.downloadProgress = nil

            var args = ["-o", saveURL.deletingPathExtension().path + ".%(ext)s", url, "--progress", "--newline"]
            args.append("--ffmpeg-location")
            args.append(self.ffmpegPath.path)

            // Format selection logic
            let isMp3 = self.selectedFormat == "mp3"
            let hasVideo = !self.selectedVideoFormatIDs.isEmpty
            let hasAudio = !self.selectedAudioFormatIDs.isEmpty

            if hasVideo || hasAudio {
                let vIDs = self.selectedVideoFormatIDs.sorted().joined(separator: "+")
                let aIDs = self.selectedAudioFormatIDs.sorted().joined(separator: "+")
                var formatString = ""
                if !vIDs.isEmpty && !aIDs.isEmpty {
                    formatString = "\(vIDs)+\(aIDs)"
                } else if !vIDs.isEmpty {
                    formatString = vIDs
                } else if !aIDs.isEmpty {
                    formatString = aIDs
                }
                if !formatString.isEmpty {
                    args.append("-f")
                    args.append(formatString)
                }
                // If user selected mp3, extract audio and set output extension to mp3
                if isMp3 {
                    args.append("-x")
                    args.append("--audio-format")
                    args.append("mp3")
                } else {
                    args.append("--merge-output-format")
                    args.append(self.selectedFormat)
                }
            } else if isMp3 {
                // No tracks selected, but mp3 requested: fallback to bestaudio
                args.append("-f")
                args.append("bestaudio")
                args.append("-x")
                args.append("--audio-format")
                args.append("mp3")
            } else {
                args.append("-f")
                args.append("bestvideo+bestaudio/best")
                args.append("--merge-output-format")
                args.append(self.selectedFormat)
            }

            // Disable captions if no video tracks selected
            let enableCaptions = hasVideo && self.downloadCaptions

            if enableCaptions {
                args.append("--write-auto-subs")
                args.append("--sub-lang")
                args.append("en")
            }
            if self.embedCaptions && enableCaptions {
                args.append("--embed-subs")
            }

            let task = Process()
            task.launchPath = self.ytDlpPath.path
            task.arguments = args
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
