import AppKit
import CleanEjectCore
import SwiftUI

/// Contents of the menu bar extra: one submenu per volume (folders and archives need the window), then
/// the app-level items.
struct MenuBarExtraMenu: View {
    let store: VolumeStore
    let delegate: AppDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if store.volumes.isEmpty {
            Text("No External Volumes")
        } else {
            ForEach(store.volumes) { volume in
                Menu {
                    if let run = store.runs[volume.target], run.isBusy {
                        Text(statusText(run))
                    } else {
                        // Runs directly; the menu bar extra never scans, the window may be closed.
                        Button("Clean & Eject") { store.clean(volume.target, ejectAfterwards: true) }
                        Button("Clean") { store.clean(volume.target) }
                        Button("Eject") { store.eject(volume) }
                    }
                } label: {
                    Label {
                        Text(volume.name)
                    } icon: {
                        Image(nsImage: volume.icon(size: 16))
                    }
                }
            }
        }
        Divider()
        Button("Open CleanEject") { delegate.showMainWindow() }
        Button("Settings…") {
            // The app may be in accessory mode and inactive; the window needs an activation too.
            openSettings()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit CleanEject") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func statusText(_ run: VolumeStore.RunState) -> String {
        switch run {
        case .cleaning: "Cleaning…"
        case .ejecting: "Ejecting…"
        case .scanning, .scanned, .stopped, .finished, .failed: ""
        }
    }
}
