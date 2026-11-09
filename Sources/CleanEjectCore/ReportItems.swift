import Foundation

/// A report's items as a front end lists them: paths relative to the target, sorted, and grouped by rule.
public struct ReportItems: Sendable {
    public struct Entry: Sendable {
        /// A directory removed as a whole ends in "/".
        public let path: String
        public let bytes: Int64
        public let rule: HiddenFileRules.Rule
    }

    public struct Group: Sendable {
        public let rule: HiddenFileRules.Rule
        public let entries: [Entry]
        public var count: Int { entries.count }
        public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    }

    public let count: Int
    public let bytes: Int64
    public let mergedCount: Int
    /// The non-empty groups, in rule order.
    public let groups: [Group]
    /// "relative path: reason" per item that could not be removed.
    public let failureLines: [String]
    /// A failure was macOS refusing the Spotlight index; the front end then points to Full Disk Access.
    public let needsFullDiskAccess: Bool

    public init(_ report: CleanReport, root: URL) {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        func relative(_ url: URL) -> String {
            let path = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
            return url.hasDirectoryPath ? path + "/" : path
        }
        let entries = report.removals
            .map { Entry(path: relative($0.url), bytes: $0.bytes, rule: $0.rule) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        count = entries.count
        bytes = report.removedBytes
        mergedCount = report.merged.count
        groups = HiddenFileRules.Rule.allCases.compactMap { rule in
            let matching = entries.filter { $0.rule == rule }
            return matching.isEmpty ? nil : Group(rule: rule, entries: matching)
        }
        failureLines = report.failures.map { "\(relative($0.url)): \($0.message)" }
        needsFullDiskAccess = report.needsFullDiskAccess
    }

    /// "12 items, 4 KB".
    public var summary: String {
        "\(count == 1 ? "1 item" : "\(count) items"), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    /// "Merged 12 sidecars into their files", or nil when the AppleDouble merge did nothing.
    public var mergedSummary: String? {
        switch mergedCount {
        case 0: nil
        case 1: "Merged 1 sidecar into its file"
        default: "Merged \(mergedCount) sidecars into their files"
        }
    }

    /// "3 items could not be removed", or nil without failures.
    public var failureSummary: String? {
        switch failureLines.count {
        case 0: nil
        case 1: "1 item could not be removed"
        default: "\(failureLines.count) items could not be removed"
        }
    }
}
