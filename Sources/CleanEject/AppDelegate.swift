import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = VolumeStore()
    let settings = GeneralSettings()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bare binary from `swift build` has no Info.plist; without this it would stay a background process.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.servicesProvider = self
    }

    /// Volumes or files dropped on the Dock icon (document types in Info.plist).
    func application(_ application: NSApplication, open urls: [URL]) {
        store.add(droppedURLs: urls)
        showMainWindow()
    }

    /// With the menu bar extra on, the app lives on without a Dock icon once its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard settings.showInMenuBar else { return true }
        NSApplication.shared.setActivationPolicy(.accessory)
        return false
    }

    /// Brings the Dock icon back, opens or raises the main window and activates the app.
    func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        store.openMainWindow?()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Finder's "Clean with CleanEject" service (NSServices in Info.plist). Lists and selects the
    /// items like a drop; nothing is removed until the user acts.
    @objc func cleanWithCleanEject(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "CleanEject did not receive any files."
            return
        }
        store.add(droppedURLs: urls)
        showMainWindow()
    }
}
