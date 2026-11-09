import AppKit
import UniformTypeIdentifiers

/// File > Open… and the toolbar's Open… button: volumes, folders and ZIP archives, resolved like a drop.
@MainActor
enum OpenTargetPanel {
    static func present(into store: VolumeStore) {
        let panel = NSOpenPanel()
        panel.message = "Choose a volume, folder or ZIP archive to clean."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        store.add(droppedURLs: panel.urls)
    }
}
