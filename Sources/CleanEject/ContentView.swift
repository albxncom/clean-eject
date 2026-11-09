import CleanEjectCore
import SwiftUI

/// Sidebar of targets, detail of the selected one; drops anywhere on the window add a target.
struct ContentView: View {
    let store: VolumeStore
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false
    @State private var columnVisibility: NavigationSplitViewVisibility

    init(store: VolumeStore) {
        self.store = store
        // An empty list is not worth a column: the sidebar opens with the first volume, folder or archive.
        _columnVisibility = State(initialValue: store.hasTargets ? .all : .detailOnly)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store, isDropTargeted: isDropTargeted)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            DetailColumn(store: store)
                .frame(minWidth: 400)
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.add(droppedURLs: urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onChange(of: store.hasTargets) { _, hasTargets in
            withAnimation { columnVisibility = hasTargets ? .all : .detailOnly }
        }
        .toolbar {
            // Two unrelated actions: on macOS 26 a fixed spacer keeps them from sharing one glass group.
            if #available(macOS 26, *) {
                ToolbarItem { openButton }
                ToolbarSpacer(.fixed)
                ToolbarItem { scanAgainButton }
            } else {
                ToolbarItemGroup {
                    openButton
                    scanAgainButton
                }
            }
        }
        .alert(store.alert?.title ?? "CleanEject", isPresented: isPresentingAlert, presenting: store.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .onAppear {
            store.isWindowOpen = true
            store.openMainWindow = { openWindow(id: "main") }
        }
        .onDisappear { store.isWindowOpen = false }
    }

    private var openButton: some View {
        Button {
            OpenTargetPanel.present(into: store)
        } label: {
            Label("Open…", systemImage: "folder")
        }
        .help("Open a volume, folder or ZIP archive")
    }

    private var scanAgainButton: some View {
        Button {
            store.scanAgain()
        } label: {
            Label("Scan Again", systemImage: "arrow.clockwise")
        }
        .help("Look for items to remove again")
        .disabled(store.selectedTarget.map(store.isBusy) ?? true)
    }

    private var isPresentingAlert: Binding<Bool> {
        Binding(
            get: { store.alert != nil },
            set: { if !$0 { store.alert = nil } }
        )
    }
}

private struct DetailColumn: View {
    let store: VolumeStore

    var body: some View {
        if let target = store.selectedTarget {
            TargetDetailView(target: target, store: store)
        } else if let run = store.departedRun {
            RunResultView(run: run)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
        } else if !store.hasTargets {
            EmptyStateView(
                systemImage: "externaldrive",
                title: "No External Volumes",
                description: "Insert a card or drop a volume, folder or ZIP archive on the window."
            ) {
                Button("Open…") { OpenTargetPanel.present(into: store) }
            }
        } else {
            EmptyStateView(
                systemImage: "externaldrive",
                title: store.added.isEmpty ? "Select a Volume" : "Select an Item",
                description: "Choose an item in the sidebar to see what would be removed."
            )
        }
    }
}
