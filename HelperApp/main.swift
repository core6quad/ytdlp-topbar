import Cocoa

class HelperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch the main app if not already running
        let mainBundleID = "com.core6quad.ytdlp-topbar" // <-- Replace with your main app's bundle identifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleID)
        if running.isEmpty {
            // Find main app path relative to helper
            if let mainAppURL = Bundle.main.bundleURL
                .deletingLastPathComponent() // LoginItems
                .deletingLastPathComponent() // Contents
                .deletingLastPathComponent() // Main app bundle
                .appendingPathComponent("ytdlp-topbar.app"),
               FileManager.default.fileExists(atPath: mainAppURL.path) {
                NSWorkspace.shared.open(mainAppURL)
            } else {
                // Fallback: try by bundle id
                let workspace = NSWorkspace.shared
                workspace.launchApplication(withBundleIdentifier: mainBundleID, options: [], additionalEventParamDescriptor: nil, launchIdentifier: nil)
            }
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = HelperAppDelegate()
app.delegate = delegate
app.run()
