import CleanEjectCore
import SwiftUI

/// Disk Utility style: icon, name and facts of the selected target, its scan findings or the state of
/// its run, and the actions in a trailing bar.
struct TargetDetailView: View {
    let target: CleanTarget
    let store: VolumeStore

    private var run: VolumeStore.RunState? { store.runs[target] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            actionBar
        }
        .padding(20)
    }

    @ViewBuilder
    private var header: some View {
        switch target {
        case .volume(let url):
            if let volume = store.volume(at: url) {
                VolumeHeader(volume: volume)
            }
        case .folder(let url):
            FolderHeader(url: url, store: store)
        case .archive(let url):
            ArchiveHeader(url: url)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch run {
        case .scanning(let path):
            ProgressLine(title: "Looking for items to remove…", path: path) {
                Button("Stop") { store.cancel(target) }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
        case .scanned(let findings):
            FindingsView(findings: findings, name: store.name(of: target))
        case .cleaning(let path):
            ProgressLine(title: "Cleaning…", path: path)
        case .ejecting:
            ProgressLine(title: "Ejecting…", path: nil)
        case .finished(let lastRun):
            RunResultView(run: lastRun)
        case .failed(let message):
            StatusHeadline(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: message)
        case .stopped, nil:
            // Nil only for the moment between the window opening and its scan starting.
            Text("Choose Scan Again to look for items to remove.")
                .foregroundStyle(.secondary)
        }
    }

    /// The actions stay enabled during a scan (they stop it first) and when nothing was found: Clean &
    /// Eject on a clean card is a plain eject. A real run swaps them for Cancel.
    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 12) {
            Spacer()
            if let run, run.isBusy {
                Button("Cancel") { store.cancel(target) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!run.isCancellable)
            } else if case .volume(let url) = target, let volume = store.volume(at: url) {
                Button("Eject") { store.eject(volume) }
                Button("Clean") { store.clean(target) }
                Button("Clean & Eject") { store.clean(target, ejectAfterwards: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Clean") { store.clean(target) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The large icon with the name and the facts next to it, shared by every target kind.
private struct TargetHeader<Details: View>: View {
    let url: URL
    let name: String
    @ViewBuilder let details: Details

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: url.finderIcon(size: 64))
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.title2)
                    .fontWeight(.semibold)
                details
            }
        }
    }
}

private struct VolumeHeader: View {
    let volume: VolumeInfo

    var body: some View {
        TargetHeader(url: volume.url, name: volume.name) {
            Text(capacityLine)
                .foregroundStyle(.secondary)
            // On macOS 26 `.labelsHidden()` no longer hides a linearCapacity gauge's label; VoiceOver keeps it.
            Gauge(value: usedFraction) {}
                .gaugeStyle(.linearCapacity)
                .accessibilityLabel("Capacity")
                .padding(.top, 4)
        }
    }

    private var capacityLine: String {
        let used = ByteCountFormatter.string(fromByteCount: volume.usedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: volume.totalBytes, countStyle: .file)
        return "\(volume.formatDescription), \(used) of \(total) used"
    }

    private var usedFraction: Double {
        guard volume.totalBytes > 0 else { return 0 }
        return min(1, Double(volume.usedBytes) / Double(volume.totalBytes))
    }
}

/// A folder gets only the per-folder rules; when its volume may be cleaned as a whole, a link offers that.
private struct FolderHeader: View {
    let url: URL
    let store: VolumeStore

    private var volume: VolumeInfo? { VolumeInfo.containing(url) }

    var body: some View {
        TargetHeader(url: url, name: url.lastPathComponent) {
            PathText(path: url.path)
            if let volume {
                HStack(spacing: 8) {
                    Text("on \(volume.name)")
                        .foregroundStyle(.secondary)
                    if volume.refusal == nil {
                        Button("Clean Whole Volume Instead") { store.add(droppedURLs: [volume.url]) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }
}

private struct ArchiveHeader: View {
    let url: URL

    var body: some View {
        TargetHeader(url: url, name: url.lastPathComponent) {
            Text(sizeLine)
                .foregroundStyle(.secondary)
            PathText(path: url.path)
        }
    }

    private var sizeLine: String {
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return "ZIP archive, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

/// A full path on one line, truncated in the middle and selectable for copying.
private struct PathText: View {
    let path: String

    var body: some View {
        Text(path)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
    }
}

/// An indeterminate bar with the directory the walk is in, as in Disk Utility's First Aid, and an
/// optional control (Stop) next to the title.
private struct ProgressLine<Accessory: View>: View {
    let title: String
    let path: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                accessory
            }
            ProgressView()
                .progressViewStyle(.linear)
            if let path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

extension ProgressLine where Accessory == EmptyView {
    init(title: String, path: String?) {
        self.init(title: title, path: path) { EmptyView() }
    }
}
