import SwiftUI

/// Confirmation of one finished run: headline, what was removed grouped like the findings, failures,
/// and the Full Disk Access hint when macOS refused the Spotlight index.
struct RunResultView: View {
    let run: VolumeStore.LastRun

    private var symbolName: String {
        if run.hasProblems { return "exclamationmark.triangle.fill" }
        return run.ejected ? "eject.circle.fill" : "checkmark.circle.fill"
    }

    var body: some View {
        GroupedItemsReport(groups: run.items?.groups ?? []) {
            VStack(alignment: .leading, spacing: 8) {
                StatusHeadline(systemImage: symbolName, tint: run.hasProblems ? .orange : .green, text: run.headline)
                if let detail = run.detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if let items = run.items {
                if !items.failureLines.isEmpty {
                    FailuresDisclosure(lines: items.failureLines, verb: "Be Removed")
                }
                if items.needsFullDiskAccess {
                    FullDiskAccessHint()
                }
            }
        }
    }
}

/// A status symbol next to a bold line, for results and failures.
struct StatusHeadline: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.headline)
        }
    }
}

/// "3 Items Could Not Be Removed" in red, expanding to the paths and reasons.
struct FailuresDisclosure: View {
    let lines: [String]
    /// Completes "Could Not …": "Be Removed" for a run, "Be Read" for a scan.
    let verb: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            PathList(lines: lines)
        } label: {
            Text(lines.count == 1 ? "1 Item Could Not \(verb)" : "\(lines.count) Items Could Not \(verb)")
                .foregroundStyle(.red)
        }
    }
}

/// One selectable monospaced block, capped in height so hundreds of entries scroll instead of growing the window.
struct PathList: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
    }
}
