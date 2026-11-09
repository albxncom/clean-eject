import XCTest
@testable import CleanEjectCore

/// The report names the rule each item matched, so the app can group a preview by rule.
final class RuleMatchingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanEjectRules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRemovalsCarryTheirRule() throws {
        let planted: [String: HiddenFileRules.Rule] = [
            ".DS_Store": .dsStore, "a/.DS_Store": .dsStore, "a/._x": .appleDouble, ".Spotlight-V100/x": .spotlight,
            ".fseventsd/x": .fsevents, ".Trashes/x": .trashes, ".TemporaryItems/x": .temporaryItems, ".apdisk": .apdisk,
        ]
        for path in planted.keys {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("xx".utf8).write(to: url)
        }

        let report = try VolumeCleaner.cleanTree(root: root, rules: .all, dryRun: true)

        let prefix = root.standardizedFileURL.path + "/"
        var rules: [String: HiddenFileRules.Rule] = [:]
        for removal in report.removals {
            rules[String(removal.url.path.dropFirst(prefix.count))] = removal.rule
            XCTAssertEqual(removal.bytes, 2, removal.url.path)
            XCTAssertFalse(removal.merged)
        }
        // Top-level folders are removed as a whole, so the key is the folder, not the file in it.
        let expected = Dictionary(uniqueKeysWithValues: planted.map { path, rule in
            (path.hasPrefix(".") && path.contains("/") ? String(path.prefix(while: { $0 != "/" })) : path, rule)
        })
        XCTAssertEqual(rules, expected)
        XCTAssertEqual(report.removed.count, report.removals.count)
        XCTAssertEqual(report.removedBytes, 16)
        XCTAssertTrue(report.merged.isEmpty)
    }

    func testArchiveEntriesName__MACOSXAsItsOwnRule() {
        let rules = HiddenFileRules.all
        XCTAssertEqual(rules.rule(forArchiveEntry: "__MACOSX/"), .macosxFolder)
        XCTAssertEqual(rules.rule(forArchiveEntry: "__MACOSX/a/._b.txt"), .macosxFolder)
        XCTAssertEqual(rules.rule(forArchiveEntry: "a/._b.txt"), .appleDouble)
        XCTAssertEqual(rules.rule(forArchiveEntry: "a/.DS_Store"), .dsStore)
        XCTAssertEqual(rules.rule(forArchiveEntry: ".Trashes/x"), .trashes)
        XCTAssertEqual(rules.rule(forArchiveEntry: ".apdisk"), .apdisk)
        XCTAssertNil(rules.rule(forArchiveEntry: "a/.apdisk"))
        XCTAssertNil(rules.rule(forArchiveEntry: "a/b.txt"))
        XCTAssertNil(rules.rule(forArchiveEntry: "a/._"))

        var noAppleDouble = HiddenFileRules.all
        noAppleDouble.appleDouble = false
        XCTAssertNil(noAppleDouble.rule(forArchiveEntry: "__MACOSX/a/._b.txt"))
        XCTAssertNil(noAppleDouble.rule(forArchiveEntry: "a/._b.txt"))
        XCTAssertEqual(noAppleDouble.rule(forArchiveEntry: "__MACOSX/.DS_Store"), .dsStore)
    }

    func testShouldRemoveAgreesWithRule() {
        let rules = HiddenFileRules.all
        for (name, isDirectory, isTopLevel) in [(".DS_Store", false, false), (".Spotlight-V100", true, true), (".Spotlight-V100", true, false), ("photo.jpg", false, true)] {
            XCTAssertEqual(
                rules.shouldRemove(name: name, isDirectory: isDirectory, isRegularFile: !isDirectory, isTopLevel: isTopLevel),
                rules.rule(name: name, isDirectory: isDirectory, isRegularFile: !isDirectory, isTopLevel: isTopLevel) != nil,
                name
            )
        }
    }

    func testArchiveRefusal() throws {
        let text = root.appendingPathComponent("notes.txt")
        try Data().write(to: text)
        XCTAssertEqual(ArchiveCleaner.archiveRefusal(text), .notAZipArchive(text))

        let missing = root.appendingPathComponent("missing.zip")
        XCTAssertEqual(ArchiveCleaner.archiveRefusal(missing), .unreadable(missing))

        let folder = root.appendingPathComponent("folder.zip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(ArchiveCleaner.archiveRefusal(folder), .notAZipArchive(folder))

        let archive = root.appendingPathComponent("Archive.ZIP")
        try Data().write(to: archive)
        XCTAssertNil(ArchiveCleaner.archiveRefusal(archive))
    }
}
