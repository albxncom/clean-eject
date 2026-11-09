import CleanEjectCore
import SwiftUI

/// File > Open…, View > Hide Sidebar, the Volume menu and the Help menu. Every toolbar action has its command here (HIG).
struct AppCommands: Commands {
    let store: VolumeStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage(GeneralDefaults.settingsTabKey) private var settingsTab = SettingsTab.general

    private var target: CleanTarget? { store.selectedTarget }
    private var canAct: Bool { target.map { !store.isBusy($0) } ?? false }
    /// Eject applies to volumes only; folders and archives get Clean.
    private var canEject: Bool { canAct && store.selectedVolume != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { OpenTargetPanel.present(into: store) }
                .keyboardShortcut("o")
        }
        SidebarCommands()
        CommandMenu("Volume") {
            Button("Clean & Eject") { if let target { store.clean(target, ejectAfterwards: true) } }
                .keyboardShortcut("e")
                .disabled(!canEject)
            Button("Clean") { if let target { store.clean(target) } }
                .disabled(!canAct)
            Button("Eject") { if let volume = store.selectedVolume { store.eject(volume) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!canEject)
            Divider()
            Button("Scan Again") { store.scanAgain() }
                .keyboardShortcut("r")
                .disabled(!canAct)
        }
        CommandGroup(replacing: .help) {
            Button("What CleanEject Removes") {
                settingsTab = .rules
                openSettings()
            }
        }
    }
}
