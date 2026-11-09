import SwiftUI
import XCTest
import CleanEjectCore
@testable import CleanEject

/// Findings and results must never raise the window's minimum height, however tall their footer
/// (expanded failures, the Full Disk Access hint, the merge caption) gets.
final class GroupedItemsReportLayoutTests: XCTestCase {
    @MainActor
    func testATallFooterScrollsInsteadOfRaisingTheMinimumHeight() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cleaneject-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        let report = try await TargetRunner.run(.folder(root), rules: HiddenFileRules(), dryRun: true).report
        let groups = ReportItems(report, root: root).groups
        XCTAssertFalse(groups.isEmpty)

        // What an expanded failures disclosure shows, plus the Full Disk Access hint.
        let failureLines = (1...60).map { "sub/._file\($0): Operation not permitted" }
        let controller = NSHostingController(rootView: GroupedItemsReport(groups: groups) {
            Text("Headline")
        } footer: {
            PathList(lines: failureLines)
            FullDiskAccessHint()
        })

        let minimum = controller.sizeThatFits(in: CGSize(width: 500, height: 0)).height
        XCTAssertLessThan(minimum, 150, "headline, gap and the table's 80 pt minimum; the footer adds nothing")
        XCTAssertEqual(controller.sizeThatFits(in: CGSize(width: 500, height: 200)).height, 200, "it fits the free height it is given")
        let ideal = controller.sizeThatFits(in: CGSize(width: 500, height: CGFloat.infinity)).height
        XCTAssertGreaterThan(ideal, 300, "with room to spare the footer shows in full")
    }
}
