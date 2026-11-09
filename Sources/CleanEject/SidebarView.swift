import CleanEjectCore
import SwiftUI

/// Source list of the mounted volumes and the folders and archives added explicitly.
struct SidebarView: View {
    let store: VolumeStore
    let isDropTargeted: Bool

    var body: some View {
        // The sidebar is collapsed while empty (see ContentView); opened by hand it still shows what it is for.
        List(selection: selection) {
            Section("Volumes") {
                if store.volumes.isEmpty {
                    Text("No Volumes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(store.volumes) { volume in
                    SidebarRow(name: volume.name, url: volume.url, isBusy: store.isBusy(volume.target))
                        .tag(volume.target)
                }
            }
            if !store.added.isEmpty {
                Section("Folders & Archives") {
                    ForEach(store.added, id: \.self) { target in
                        SidebarRow(name: store.name(of: target), url: target.url, isBusy: store.isBusy(target))
                            .contextMenu {
                                Button("Remove from List") { store.removeFromList(target) }
                            }
                            .tag(target)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let target = store.selectedTarget, !target.isVolume { store.removeFromList(target) }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var selection: Binding<CleanTarget?> {
        Binding(
            get: { store.selection },
            set: { if $0 != store.selection { store.select($0) } }
        )
    }
}

private struct SidebarRow: View {
    let name: String
    let url: URL
    let isBusy: Bool

    var body: some View {
        HStack {
            Label {
                Text(name)
            } icon: {
                Image(nsImage: url.finderIcon(size: 18))
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
