import XCTest
import CleanEjectCore
@testable import CleanEject

/// The scan-first flow of `VolumeStore` on folder targets. Folder targets refuse the temporary
/// directory, so the fixtures live in the home folder; the rules come from a throwaway defaults suite.
final class VolumeStoreScanTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    /// Per folder: two .DS_Store files and one AppleDouble sidecar, plus files that always stay.
    private static let junk = [".DS_Store", "sub/.DS_Store", "._photo.jpg"]
    private static let kept = ["photo.jpg", "sub/notes.txt"]

    override func setUpWithError() throws {
        root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cleaneject-tests-\(UUID().uuidString)", isDirectory: true)
        for folder in ["A", "B"] {
            for path in Self.junk + Self.kept {
                let url = root.appendingPathComponent(folder).appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
        }
        suiteName = "CleanEjectAppTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Tests

    @MainActor
    func testSelectingAFolderScansItAndShowsTheFindings() async throws {
        let store = VolumeStore(defaults: defaults)
        store.isWindowOpen = true
        let a = add("A", to: store)

        XCTAssertTrue(isScanning(a, in: store), "selecting starts the scan")
        try await waitUntil { findings(a, in: store) != nil }

        let found = try XCTUnwrap(findings(a, in: store))
        XCTAssertEqual(found.items.count, Self.junk.count)
        XCTAssertEqual(Set(paths(found.items)), Set(Self.junk))
        XCTAssertEqual(found.rules, HiddenFileRules.fromUserDefaults(defaults))
        for path in Self.junk { XCTAssertTrue(exists("A/\(path)"), "a scan removes nothing: \(path)") }
    }

    @MainActor
    func testCleanAfterAScanRemovesExactlyTheFindings() async throws {
        defaults.set(false, forKey: RuleDefaults.appleDouble)
        let store = VolumeStore(defaults: defaults)
        store.isWindowOpen = true
        let a = add("A", to: store)
        try await waitUntil { findings(a, in: store) != nil }
        let found = try XCTUnwrap(findings(a, in: store))
        XCTAssertFalse(found.rules.appleDouble)
        XCTAssertEqual(Set(paths(found.items)), [".DS_Store", "sub/.DS_Store"])

        store.clean(a)
        try await waitUntil { lastRun(a, in: store) != nil }

        let result = try XCTUnwrap(lastRun(a, in: store)?.items)
        XCTAssertEqual(paths(result), paths(found.items), "the run removes what the findings listed")
        XCTAssertFalse(exists("A/.DS_Store"))
        XCTAssertTrue(exists("A/._photo.jpg"), "the findings' rules left AppleDouble off")
        for path in Self.kept { XCTAssertTrue(exists("A/\(path)")) }
    }

    @MainActor
    func testRuleChangeDropsOtherFindingsAndRescansTheSelection() async throws {
        let store = VolumeStore(defaults: defaults)
        store.isWindowOpen = true
        let a = add("A", to: store)
        try await waitUntil { findings(a, in: store) != nil }
        let b = add("B", to: store)
        try await waitUntil { findings(b, in: store) != nil }
        XCTAssertEqual(findings(b, in: store)?.items.count, 3)

        defaults.set(1, forKey: "unrelated")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(findings(b, in: store)?.items.count, 3, "a write that is not a rule keeps the findings")
        XCTAssertNotNil(findings(a, in: store))

        defaults.set(false, forKey: RuleDefaults.appleDouble)
        try await waitUntil { findings(b, in: store)?.rules.appleDouble == false }

        XCTAssertEqual(findings(b, in: store)?.items.count, 2, "the selection rescans with the new rules")
        XCTAssertNil(store.runs[a], "findings of another target made with the old rules are dropped")
        store.select(a)
        XCTAssertTrue(isScanning(a, in: store))
        try await waitUntil { findings(a, in: store) != nil }
        XCTAssertEqual(findings(a, in: store)?.items.count, 2)
    }

    @MainActor
    func testCleanDuringAScanStopsTheScanAndCleans() async throws {
        let store = VolumeStore(defaults: defaults)
        store.isWindowOpen = true
        let a = add("A", to: store)
        XCTAssertTrue(isScanning(a, in: store))

        store.clean(a)
        XCTAssertTrue(store.isBusy(a), "the clean runs instead of the scan")
        try await waitUntil { lastRun(a, in: store) != nil }

        XCTAssertEqual(lastRun(a, in: store)?.items?.count, Self.junk.count)
        for path in Self.junk { XCTAssertFalse(exists("A/\(path)"), "\(path) should be removed") }
        for path in Self.kept { XCTAssertTrue(exists("A/\(path)")) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(lastRun(a, in: store), "the stopped scan never replaces the result")

        store.scanAgain()
        try await waitUntil { findings(a, in: store) != nil }
        XCTAssertEqual(findings(a, in: store)?.items.count, 0, "after the clean, Scan Again finds nothing")
    }

    @MainActor
    func testNoScanWhileTheWindowIsClosed() async throws {
        let store = VolumeStore(defaults: defaults)
        let a = add("A", to: store)
        XCTAssertEqual(store.selectedTarget, a)
        XCTAssertNil(store.runs[a])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.runs[a], "nothing scans without the window")

        store.isWindowOpen = true
        XCTAssertTrue(isScanning(a, in: store), "the selection scans once the window opens")
        try await waitUntil { findings(a, in: store) != nil }

        store.scanAgain()
        store.isWindowOpen = false
        XCTAssertNil(store.runs[a], "closing the window stops the scan")
    }

    @MainActor
    func testSwitchingTheSelectionStopsTheRunningScan() async throws {
        let store = VolumeStore(defaults: defaults)
        store.isWindowOpen = true
        let a = add("A", to: store)
        XCTAssertTrue(isScanning(a, in: store))

        let b = add("B", to: store)

        XCTAssertNil(store.runs[a], "the previous selection's scan stops and its state goes back to none")
        XCTAssertTrue(isScanning(b, in: store))
        try await waitUntil { findings(b, in: store) != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.runs[a], "the stopped scan writes nothing")

        store.select(a)
        XCTAssertTrue(isScanning(a, in: store), "it rescans when selected again")
        store.cancel(a)
        XCTAssertTrue(isStopped(a, in: store), "Stop leaves the target stopped")
        XCTAssertNotNil(findings(b, in: store), "findings of the other target stay")
    }

    @MainActor
    func testAStoppedScanStaysStoppedUntilScanAgainOrReselection() async throws {
        let store = VolumeStore(defaults: defaults)
        store.isWindowOpen = true
        let b = add("B", to: store)
        try await waitUntil { findings(b, in: store) != nil }
        let a = add("A", to: store)
        XCTAssertTrue(isScanning(a, in: store))

        store.cancel(a)
        XCTAssertTrue(isStopped(a, in: store))
        store.refresh()
        store.isWindowOpen = false
        store.isWindowOpen = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(isStopped(a, in: store), "refreshes and reopening the window do not restart a stopped scan")

        store.scanAgain()
        XCTAssertTrue(isScanning(a, in: store), "Scan Again starts it")
        try await waitUntil { findings(a, in: store) != nil }

        store.scanAgain()
        store.cancel(a)
        store.clean(b)
        try await waitUntil { lastRun(b, in: store) != nil }
        XCTAssertTrue(isStopped(a, in: store), "another target's run finishing does not restart it")
        store.select(b)
        store.select(a)
        XCTAssertTrue(isScanning(a, in: store), "selecting it again starts it")
    }

    @MainActor
    func testSelectingAgainRescansFindingsButKeepsAResult() async throws {
        let store = VolumeStore(defaults: defaults)
        store.isWindowOpen = true
        let a = add("A", to: store)
        try await waitUntil { findings(a, in: store) != nil }
        let b = add("B", to: store)
        try await waitUntil { findings(b, in: store) != nil }

        try Data("x".utf8).write(to: root.appendingPathComponent("A/sub/._notes.txt"))
        store.select(a)
        XCTAssertTrue(isScanning(a, in: store), "selecting a target with findings scans it afresh")
        try await waitUntil { findings(a, in: store) != nil }
        XCTAssertEqual(findings(a, in: store)?.items.count, Self.junk.count + 1)

        _ = add("A", to: store)
        XCTAssertTrue(isScanning(a, in: store), "adding the selected target again rescans it too")
        try await waitUntil { findings(a, in: store) != nil }

        store.clean(a)
        try await waitUntil { lastRun(a, in: store) != nil }
        store.select(b)
        store.select(a)
        XCTAssertNotNil(lastRun(a, in: store), "a finished run's result stays on reselection")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(lastRun(a, in: store))
    }

    // MARK: Helpers

    @MainActor
    private func add(_ folder: String, to store: VolumeStore) -> CleanTarget {
        store.add(droppedURLs: [root.appendingPathComponent(folder, isDirectory: true)])
        XCTAssertNil(store.alert?.message)
        guard case .folder? = store.selection else {
            XCTFail("\(folder) should be the selected folder target")
            return .folder(root.appendingPathComponent(folder))
        }
        return store.selection!
    }

    @MainActor
    private func findings(_ target: CleanTarget, in store: VolumeStore) -> VolumeStore.Findings? {
        guard case .scanned(let findings)? = store.runs[target] else { return nil }
        return findings
    }

    @MainActor
    private func lastRun(_ target: CleanTarget, in store: VolumeStore) -> VolumeStore.LastRun? {
        guard case .finished(let run)? = store.runs[target] else { return nil }
        return run
    }

    @MainActor
    private func isStopped(_ target: CleanTarget, in store: VolumeStore) -> Bool {
        guard case .stopped? = store.runs[target] else { return false }
        return true
    }

    /// The relative paths in rule order, sorted within each rule.
    private func paths(_ items: ReportItems) -> [String] {
        items.groups.flatMap(\.entries).map(\.path)
    }

    @MainActor
    private func isScanning(_ target: CleanTarget, in store: VolumeStore) -> Bool {
        guard case .scanning? = store.runs[target] else { return false }
        return true
    }

    /// lstat(2): sees `._*` files as they are.
    private func exists(_ relativePath: String) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent(relativePath).path, &info) == 0
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("timed out", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
