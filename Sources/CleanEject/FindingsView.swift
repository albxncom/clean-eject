import CleanEjectCore
import SwiftUI

/// What a finished scan found, inline in the detail: count and size, the grouped table, then what
/// could not be read and the notes that apply to a real run.
struct FindingsView: View {
    let findings: VolumeStore.Findings
    let name: String
    @Environment(\.openSettings) private var openSettings
    @AppStorage(GeneralDefaults.settingsTabKey) private var settingsTab = SettingsTab.general

    private var items: ReportItems { findings.items }

    var body: some View {
        GroupedItemsReport(groups: items.groups) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                headline
                Spacer()
                Button("What CleanEject Removes") {
                    settingsTab = .rules
                    openSettings()
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        } footer: {
            if findings.mergesAppleDouble, items.groups.contains(where: { $0.rule == .appleDouble }) {
                Text("The data in the AppleDouble sidecars is merged back into their files first where the volume can store it (APFS, HFS+).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !items.failureLines.isEmpty {
                FailuresDisclosure(lines: items.failureLines, verb: "Be Read")
            }
            if items.needsFullDiskAccess {
                FullDiskAccessHint()
            }
        }
    }

    @ViewBuilder
    private var headline: some View {
        if items.count > 0 {
            Text(items.count == 1 ? "1 Item to Remove" : "\(items.count.formatted()) Items to Remove")
                .font(.headline)
            Text(ByteCountFormatter.string(fromByteCount: items.bytes, countStyle: .file))
                .foregroundStyle(.secondary)
        } else {
            Label {
                Text(items.failureLines.isEmpty
                    ? "No items to remove, \(name) is already clean."
                    : "No items to remove among the items that could be read.")
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .foregroundStyle(.secondary)
        }
    }
}
