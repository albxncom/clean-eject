import SwiftUI

@main
struct CleanEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("CleanEject", id: "main") {
            ContentView(store: appDelegate.store)
                .frame(minHeight: 400)
        }
        .defaultSize(width: 720, height: 460)
        .commands {
            AppCommands(store: appDelegate.store)
        }

        Settings {
            SettingsView(settings: appDelegate.settings)
        }

        MenuBarExtra("CleanEject", systemImage: "externaldrive.badge.minus", isInserted: menuBarExtraInserted) {
            MenuBarExtraMenu(store: appDelegate.store, delegate: appDelegate)
        }
        .menuBarExtraStyle(.menu)
    }

    /// Backed by `GeneralSettings`, not `@AppStorage` (see there); the guard keeps SwiftUI's
    /// write-back of an unchanged value from touching the object at all.
    private var menuBarExtraInserted: Binding<Bool> {
        let settings = appDelegate.settings
        return Binding(
            get: { settings.showInMenuBar },
            set: { if settings.showInMenuBar != $0 { settings.showInMenuBar = $0 } }
        )
    }
}
