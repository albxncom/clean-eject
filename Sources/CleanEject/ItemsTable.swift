import CleanEjectCore
import SwiftUI

/// A headline, the items grouped by rule, and what goes below them; shared by findings and results.
/// Nothing in it grows the window: the table takes the free height of the detail and scrolls inside
/// it, the footer scrolls once it would squeeze the table, and without a table the block scrolls as a whole.
struct GroupedItemsReport<Headline: View, Footer: View>: View {
    let groups: [ReportItems.Group]
    @ViewBuilder let headline: Headline
    @ViewBuilder let footer: Footer

    var body: some View {
        if groups.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headline
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            // A Table inside a ScrollView collapses, so only the footer scrolls.
            TableReportLayout(spacing: 12, tableMinHeight: 80) {
                VStack(alignment: .leading, spacing: 12) { headline }
                ItemsTable(groups: groups)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { footer }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

/// Headline, table and footer from top to bottom. The footer gets its ideal height as long as the
/// table keeps `tableMinHeight`, and what is left otherwise; the table takes the rest. The minimum is
/// headline plus table minimum, so expanded failures or the Full Disk Access hint never raise the
/// window's minimum height.
private struct TableReportLayout: Layout {
    let spacing: CGFloat
    let tableMinHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: heights(width: width, height: proposal.height, subviews: subviews).total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = heights(width: bounds.width, height: bounds.height, subviews: subviews)
        var y = bounds.minY
        for (subview, height) in zip(subviews, [heights.headline, heights.table, heights.footer]) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    /// `height` nil or infinite asks for the ideal: everything at its ideal height, the table at its minimum.
    private func heights(width: CGFloat, height: CGFloat?, subviews: Subviews) -> (headline: CGFloat, table: CGFloat, footer: CGFloat, total: CGFloat) {
        let unbounded = ProposedViewSize(width: width, height: nil)
        let headline = subviews[0].sizeThatFits(unbounded).height
        let footerIdeal = subviews[2].sizeThatFits(unbounded).height
        let minimum = headline + spacing + tableMinHeight
        let total = height.flatMap { $0.isFinite ? max($0, minimum) : nil } ?? minimum + (footerIdeal > 0 ? spacing + footerIdeal : 0)
        // The footer's gap goes with it when there is no room left for it.
        let footer = min(footerIdeal, max(0, total - minimum - spacing))
        let table = total - headline - spacing - (footer > 0 ? spacing + footer : 0)
        return (headline, table, footer, total)
    }
}

/// One row per rule with its count and size; a row expands to the paths it covers. In an archive the
/// `__MACOSX` folder is a group of its own under the AppleDouble rule that covers it.
private struct ItemsTable: View {
    struct Row: Identifiable {
        let id: String
        let title: String
        /// Nil for a path row.
        let count: Int?
        let bytes: Int64
        let children: [Row]?
    }

    let rows: [Row]

    init(groups: [ReportItems.Group]) {
        rows = Self.rows(for: groups)
    }

    var body: some View {
        Table(rows, children: \.children) {
            TableColumn("Name") { row in
                Text(row.title)
                    .fontWeight(row.count == nil ? .regular : .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.title)
            }
            TableColumn("Items") { row in
                Text(row.count.map { $0.formatted() } ?? "")
            }
            .width(60)
            .alignment(.numeric)
            TableColumn("Size") { row in
                Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
            }
            .width(80)
            .alignment(.numeric)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
    }

    private static func rows(for groups: [ReportItems.Group]) -> [Row] {
        let byRule = Dictionary(uniqueKeysWithValues: groups.map { ($0.rule, $0) })
        var rows: [Row] = []
        for rule in HiddenFileRules.Rule.allCases where rule != .macosxFolder {
            var children = byRule[rule].map(pathRows) ?? []
            var count = children.count
            var bytes = byRule[rule]?.bytes ?? 0
            if rule == .appleDouble, let macosx = byRule[.macosxFolder] {
                children.append(Row(id: "group:macosxFolder", title: macosx.rule.title, count: macosx.count, bytes: macosx.bytes, children: pathRows(macosx)))
                count += macosx.count
                bytes += macosx.bytes
            }
            guard !children.isEmpty else { continue }
            rows.append(Row(id: "group:\(rule)", title: rule.title, count: count, bytes: bytes, children: children))
        }
        return rows
    }

    private static func pathRows(_ group: ReportItems.Group) -> [Row] {
        group.entries.map { Row(id: "item:\($0.path)", title: $0.path, count: nil, bytes: $0.bytes, children: nil) }
    }
}

extension HiddenFileRules.Rule {
    var title: String {
        switch self {
        case .dsStore: "Finder view settings (.DS_Store)"
        case .appleDouble: "AppleDouble sidecars (._*)"
        case .macosxFolder: "__MACOSX resource folder"
        case .spotlight: "Spotlight index"
        case .fsevents: "File system events journal"
        case .trashes: "Trash"
        case .temporaryItems: "Temporary items"
        case .apdisk: ".apdisk"
        }
    }
}
