import XCTest
@testable import CleanEjectCore

/// `CleanTarget.resolve`, `TargetRunner.run`, `ReportItems` and the rule machine names. Folder targets refuse
/// everything under /private, the temporary directory included, so the fixtures live in the home folder.
final class TargetRunnerTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cleaneject-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func plant(_ relativePaths: [String]) throws {
        for path in relativePaths {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    /// lstat(2): sees `._*` files, which Foundation hides.
    private func exists(_ relativePath: String) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent(relativePath).path, &info) == 0
    }

    private func refusal(_ url: URL) -> CleanTarget.Refusal? {
        do {
            let target = try CleanTarget.resolve(url)
            XCTFail("\(url.path) resolved to \(target)")
            return nil
        } catch {
            return error
        }
    }

    private func zip(_ files: [String], to archive: URL) throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        for path in files {
            let url = staging.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, "."]
        process.currentDirectoryURL = staging
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try fm.removeItem(at: staging)
    }

    // MARK: CleanTarget.resolve

    func testResolvesFoldersFilesAndArchives() throws {
        try plant(["a/file.txt", "a/b/.DS_Store"])
        let realRoot = root.resolvingSymlinksInPath()
        XCTAssertEqual(try CleanTarget.resolve(root).url.path, realRoot.path)
        XCTAssertEqual(try CleanTarget.resolve(root.appendingPathComponent("a")), .folder(realRoot.appendingPathComponent("a", isDirectory: true)))
        XCTAssertEqual(
            try CleanTarget.resolve(root.appendingPathComponent("a/file.txt")), .folder(realRoot.appendingPathComponent("a", isDirectory: true)),
            "a non-zip file stands for its folder"
        )

        let archive = root.appendingPathComponent("x.ZIP")
        try zip(["y.txt"], to: archive)
        let target = try CleanTarget.resolve(archive)
        XCTAssertEqual(target, .archive(realRoot.appendingPathComponent("x.ZIP", isDirectory: false)))
        XCTAssertTrue(target.isArchive)
        XCTAssertFalse(target.isVolume)
    }

    func testRefusesWithTheCoresReasons() throws {
        let rootRefusal = try XCTUnwrap(refusal(URL(fileURLWithPath: "/")))
        XCTAssertEqual(rootRefusal.subject, .volume)
        XCTAssertEqual(rootRefusal.reason, .rootFileSystem(URL(fileURLWithPath: "/")))

        let system = try XCTUnwrap(refusal(URL(fileURLWithPath: "/private/tmp")))
        XCTAssertEqual(system.subject, .folder)
        XCTAssertEqual(system.message, VolumeCleaner.folderRefusal(URL(fileURLWithPath: "/private/tmp"))?.localizedDescription)

        let tmpLink = try XCTUnwrap(refusal(URL(fileURLWithPath: "/tmp")))
        XCTAssertEqual(tmpLink.subject, .item, "/tmp is a symbolic link")
        XCTAssertEqual(tmpLink.reason, .protectedFolder(URL(fileURLWithPath: "/tmp")))

        let missing = root.appendingPathComponent("missing")
        XCTAssertEqual(refusal(missing)?.subject, .item)

        try plant(["real/x"])
        let linkInHome = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: linkInHome, withDestinationURL: root.appendingPathComponent("real"))
        XCTAssertEqual(refusal(linkInHome), CleanTarget.Refusal(subject: .item, reason: .symbolicLink(linkInHome)))

        let readOnly = root.appendingPathComponent("ro", isDirectory: true)
        try fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let archive = readOnly.appendingPathComponent("a.zip")
        try zip(["y.txt"], to: archive)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let archiveRefusal = try XCTUnwrap(refusal(archive))
        XCTAssertEqual(archiveRefusal.subject, .archive)
        XCTAssertEqual(archiveRefusal.reason, ArchiveCleaner.archiveRefusal(archive))
    }

    // MARK: TargetRunner.run

    func testFolderRunNeverEjects() async throws {
        try plant([".DS_Store", "a/._y", "a/keep.txt"])
        let target = try CleanTarget.resolve(root)
        let ejectCalls = Counter()
        let directories = Counter()

        let result = try await TargetRunner.run(
            target, rules: .all, dryRun: false, ejectAfterwards: true,
            progress: { _ in directories.increment() },
            willEject: { ejectCalls.increment() }
        )

        XCTAssertEqual(result.target, target)
        XCTAssertNil(result.eject, "a folder is never ejected")
        XCTAssertEqual(ejectCalls.value, 0)
        XCTAssertGreaterThan(directories.value, 0)
        XCTAssertFalse(result.report.dryRun)
        XCTAssertEqual(result.report.removedCount, 2)
        XCTAssertFalse(exists(".DS_Store"))
        XCTAssertFalse(exists("a/._y"))
        XCTAssertTrue(exists("a/keep.txt"))
    }

    func testDryRunChangesNothing() async throws {
        try plant([".DS_Store", "a/._y"])

        let result = try await TargetRunner.run(try CleanTarget.resolve(root), rules: .all, dryRun: true)

        XCTAssertTrue(result.report.dryRun)
        XCTAssertNil(result.eject)
        XCTAssertEqual(result.report.removedCount, 2)
        XCTAssertTrue(exists(".DS_Store"))
        XCTAssertTrue(exists("a/._y"))
    }

    func testArchiveRun() async throws {
        let archive = root.appendingPathComponent("x.zip")
        try zip([".DS_Store", "keep.txt"], to: archive)

        let result = try await TargetRunner.run(try CleanTarget.resolve(archive), rules: .all, dryRun: false, ejectAfterwards: true)

        XCTAssertNil(result.eject)
        XCTAssertEqual(result.report.removals.map(\.rule), [.dsStore])
        XCTAssertEqual(result.report.removals.map(\.url.lastPathComponent), [".DS_Store"])
    }

    func testRunThrowsTheCleanersRefusal() async {
        do {
            _ = try await TargetRunner.run(.folder(URL(fileURLWithPath: "/private/tmp")), rules: .all, dryRun: true)
            XCTFail("a system location must be refused")
        } catch {
            XCTAssertEqual(error as? CleanerError, .protectedFolder(URL(fileURLWithPath: "/private/tmp")))
        }
    }

    // MARK: ReportItems

    func testReportItemsGroupByRuleWithRelativePaths() {
        let base = URL(fileURLWithPath: "/Volumes/X", isDirectory: true)
        var report = CleanReport(dryRun: true)
        report.recordRemoval(base.appendingPathComponent("b/._z"), bytes: 4, rule: .appleDouble)
        report.recordRemoval(base.appendingPathComponent(".Trashes", isDirectory: true), bytes: 100, rule: .trashes)
        report.recordRemoval(base.appendingPathComponent("a/.DS_Store"), bytes: 6, rule: .dsStore)
        report.recordRemoval(base.appendingPathComponent("._a"), bytes: 4, rule: .appleDouble, merged: true)
        report.recordFailure(base.appendingPathComponent("c/.DS_Store"), message: "busy")

        let items = ReportItems(report, root: base)

        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.bytes, 114)
        XCTAssertEqual(items.mergedCount, 1)
        XCTAssertEqual(items.groups.flatMap(\.entries).map(\.path), ["a/.DS_Store", "._a", "b/._z", ".Trashes/"], "relative, a directory ends in /")
        XCTAssertEqual(items.groups.map(\.rule), [.dsStore, .appleDouble, .trashes], "groups follow rule order")
        XCTAssertEqual(items.groups[1].entries.map(\.path), ["._a", "b/._z"])
        XCTAssertEqual(items.groups[1].bytes, 8)
        XCTAssertEqual(items.failureLines, ["c/.DS_Store: busy"])
        XCTAssertFalse(items.needsFullDiskAccess)
        XCTAssertEqual(items.mergedSummary, "Merged 1 sidecar into its file")
        XCTAssertEqual(items.failureSummary, "1 item could not be removed")
        XCTAssertTrue(items.summary.hasPrefix("4 items, "), items.summary)
    }

    func testEmptyReportItems() {
        let items = ReportItems(CleanReport(dryRun: false), root: root)
        XCTAssertEqual(items.count, 0)
        XCTAssertTrue(items.groups.isEmpty)
        XCTAssertNil(items.mergedSummary)
        XCTAssertNil(items.failureSummary)
    }

    // MARK: Rule machine names

    func testMachineNames() {
        XCTAssertEqual(
            HiddenFileRules.Rule.toggleable.map(\.machineName),
            ["ds-store", "appledouble", "spotlight", "fseventsd", "trashes", "temporary-items", "apdisk"]
        )
        XCTAssertEqual(Set(HiddenFileRules.Rule.allCases.map(\.machineName)).count, HiddenFileRules.Rule.allCases.count)
        for rule in HiddenFileRules.Rule.allCases {
            XCTAssertEqual(HiddenFileRules.Rule(machineName: rule.machineName), rule)
        }
        XCTAssertEqual(HiddenFileRules.Rule(machineName: "macosx-folder"), .macosxFolder)
        XCTAssertNil(HiddenFileRules.Rule(machineName: "DS-Store"))
        XCTAssertNil(HiddenFileRules.Rule(machineName: "fsevents"))
    }

    /// Each toggleable rule's key path turns off exactly its own delete toggle, so `--skip` maps 1:1.
    func testTogglesMapOneToOne() {
        let expected: [HiddenFileRules.Rule: HiddenFileRules] = [
            .dsStore: HiddenFileRules(dsStore: false),
            .appleDouble: HiddenFileRules(appleDouble: false),
            .spotlight: HiddenFileRules(spotlight: false),
            .fsevents: HiddenFileRules(fsevents: false),
            .trashes: HiddenFileRules(trashes: false),
            .temporaryItems: HiddenFileRules(temporaryItems: false),
            .apdisk: HiddenFileRules(apdisk: false),
        ]
        for rule in HiddenFileRules.Rule.toggleable {
            var rules = HiddenFileRules.all
            rules[keyPath: rule.toggle] = false
            XCTAssertEqual(rules, expected[rule], rule.machineName)
        }
        XCTAssertEqual(HiddenFileRules.Rule.macosxFolder.toggle, \HiddenFileRules.appleDouble)
    }
}

/// Thread-safe call counter for `@Sendable` callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
