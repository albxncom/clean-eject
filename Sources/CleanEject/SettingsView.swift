import AppKit
import CleanEjectCore
import SwiftUI

/// UserDefaults keys shared by the rule toggles and the store.
enum RuleDefaults {
    static let dsStore = "rule.dsStore"
    static let appleDouble = "rule.appleDouble"
    static let mergeAppleDouble = "rule.mergeAppleDouble"
    static let spotlight = "rule.spotlight"
    static let fsevents = "rule.fsevents"
    static let trashes = "rule.trashes"
    static let temporaryItems = "rule.temporaryItems"
    static let apdisk = "rule.apdisk"
    static let preventRecreation = "rule.preventRecreation"
}

/// UserDefaults keys of Settings > General, with readers for code outside SwiftUI.
enum GeneralDefaults {
    static let showInMenuBarKey = "general.showInMenuBar"
    static let settingsTabKey = "settings.selectedTab"

    static var showInMenuBar: Bool { bool(showInMenuBarKey, default: true) }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

enum SettingsTab: String {
    case general
    case rules
}

/// The "Show in Menu Bar" setting as an object, mirrored to UserDefaults. The menu bar extra's
/// `isInserted` must not be an `@AppStorage` binding from the App body: SwiftUI (macOS 26 SDK) writes
/// that binding back during every scene update, and the UserDefaults round trip re-invalidates the
/// scenes until the main thread spins. Observed: 100% CPU and no run loop service right after launch.
@MainActor @Observable
final class GeneralSettings {
    var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: GeneralDefaults.showInMenuBarKey) }
    }

    init() {
        showInMenuBar = GeneralDefaults.showInMenuBar
    }
}

extension HiddenFileRules {
    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> HiddenFileRules {
        func bool(_ key: String, default value: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? value
        }
        return HiddenFileRules(
            dsStore: bool(RuleDefaults.dsStore, default: true),
            appleDouble: bool(RuleDefaults.appleDouble, default: true),
            mergeAppleDouble: bool(RuleDefaults.mergeAppleDouble, default: false),
            spotlight: bool(RuleDefaults.spotlight, default: true),
            fsevents: bool(RuleDefaults.fsevents, default: true),
            trashes: bool(RuleDefaults.trashes, default: true),
            temporaryItems: bool(RuleDefaults.temporaryItems, default: true),
            apdisk: bool(RuleDefaults.apdisk, default: true),
            preventRecreation: bool(RuleDefaults.preventRecreation, default: false)
        )
    }
}

struct SettingsView: View {
    let settings: GeneralSettings
    @AppStorage(GeneralDefaults.settingsTabKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            RulesSettingsView()
                .tabItem { Label("Rules", systemImage: "checklist") }
                .tag(SettingsTab.rules)
        }
        .frame(width: 480)
    }
}

private struct GeneralSettingsView: View {
    @Bindable var settings: GeneralSettings

    var body: some View {
        Form {
            Section {
                Toggle("Show in Menu Bar", isOn: $settings.showInMenuBar)
            } footer: {
                Text("CleanEject stays available from the menu bar after you close its window.")
            }
            CommandLineToolSection()
        }
        .formStyle(.grouped)
        .frame(height: 300)
        .onChange(of: settings.showInMenuBar) { _, isOn in
            // Turned off while the app sits in the menu bar without a window: become a normal app again.
            if !isOn { NSApplication.shared.setActivationPolicy(.regular) }
        }
    }
}

/// Installs `cleaneject` as a link in ~/.local/bin; the rules for what may be replaced live in the core.
private struct CommandLineToolSection: View {
    private let installer = CommandLineToolInstaller()
    @State private var state: CommandLineToolInstaller.State = .notInstalled
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Status") {
                Text(status)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            HStack {
                if let reason = installer.unavailableReason {
                    Text(reason).foregroundStyle(.secondary)
                }
                Spacer()
                if canRemove {
                    Button("Remove") { perform(installer.remove) }
                }
                if state != .installed {
                    Button(isReplacing ? "Replace with This Copy" : "Install Command Line Tool") { perform(installer.install) }
                        .disabled(installer.unavailableReason != nil || isBlocked)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Command Line Tool")
        } footer: {
            Text("Links cleaneject into ~/.local/bin, which must be on your PATH. Run cleaneject --help in a terminal to get started.")
        }
        .onAppear { state = installer.state() }
    }

    private var linkPath: String { (installer.linkURL.path as NSString).abbreviatingWithTildeInPath }

    private var status: String {
        switch state {
        case .notInstalled: "Not installed"
        case .installed: "Installed at \(linkPath)"
        case .linkedElsewhere(let destination): "\(linkPath) points to another copy of CleanEject: \(destination)"
        case .blocked(let reason): "Not installed. \(reason) Remove or rename it to install."
        }
    }

    private var canRemove: Bool {
        switch state {
        case .installed, .linkedElsewhere: true
        case .notInstalled, .blocked: false
        }
    }

    private var isReplacing: Bool {
        if case .linkedElsewhere = state { return true }
        return false
    }

    private var isBlocked: Bool {
        if case .blocked = state { return true }
        return false
    }

    private func perform(_ action: () throws(CommandLineToolInstaller.Failure) -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        state = installer.state()
    }
}

private struct RulesSettingsView: View {
    @AppStorage(RuleDefaults.dsStore) private var dsStore = true
    @AppStorage(RuleDefaults.appleDouble) private var appleDouble = true
    @AppStorage(RuleDefaults.mergeAppleDouble) private var mergeAppleDouble = false
    @AppStorage(RuleDefaults.spotlight) private var spotlight = true
    @AppStorage(RuleDefaults.fsevents) private var fsevents = true
    @AppStorage(RuleDefaults.trashes) private var trashes = true
    @AppStorage(RuleDefaults.temporaryItems) private var temporaryItems = true
    @AppStorage(RuleDefaults.apdisk) private var apdisk = true
    @AppStorage(RuleDefaults.preventRecreation) private var preventRecreation = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $dsStore) {
                    Text(".DS_Store")
                    Text("Finder view settings")
                }
                Toggle(isOn: $appleDouble) {
                    Text("._* AppleDouble files")
                    Text("Resource forks and extended attributes stored next to files")
                }
                Toggle("Merge AppleDouble Data Back Into Files First", isOn: $mergeAppleDouble)
                    .disabled(!appleDouble)
            } header: {
                Text("In every folder")
            } footer: {
                Text("Before removing a ._ file, copies the resource fork and extended attributes it holds into the original where the volume can store them (APFS, HFS+). Has no effect on FAT and ExFAT volumes. A sidecar that cannot be merged is kept and listed.")
            }
            Section {
                Toggle(isOn: $spotlight) {
                    Text(".Spotlight-V100")
                    Text("Spotlight index")
                }
                FullDiskAccessHint()
                Toggle(isOn: $fsevents) {
                    Text(".fseventsd")
                    Text("File system events journal")
                }
                Toggle(isOn: $trashes) {
                    Text(".Trashes")
                    Text("Trash; items in it are gone for good")
                }
                Toggle(isOn: $temporaryItems) {
                    Text(".TemporaryItems")
                    Text("Scratch files of macOS apps")
                }
                Toggle(isOn: $apdisk) {
                    Text(".apdisk")
                    Text("Finder metadata for shared disks")
                }
            } header: {
                Text("At the top level of the volume")
            } footer: {
                Text("Nothing else is ever removed. Files and folders you created stay untouched.")
            }
            Section {
                Toggle("Prevent macOS from Recreating Them", isOn: $preventRecreation)
            } footer: {
                Text("Writes empty .metadata_never_index and .fseventsd/no_log files to the volume root.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
    }
}

/// The one permission the app may need, with a shortcut to the System Settings pane. Shown under
/// the Spotlight rule and in a result once macOS has refused a Spotlight index.
struct FullDiskAccessHint: View {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CleanEject needs Full Disk Access to remove Spotlight indexes.")
            HStack(spacing: 8) {
                Button("Open Full Disk Access Settings") {
                    NSWorkspace.shared.open(Self.settingsURL)
                }
                .controlSize(.small)
                Text("If access is on but removal still fails, remove CleanEject from the list and add it again.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
