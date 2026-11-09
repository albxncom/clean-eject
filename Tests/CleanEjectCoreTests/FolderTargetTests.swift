import XCTest
@testable import CleanEjectCore

/// Folder targets refuse everything under /private and /var, the temporary directory included, so the
/// fixtures live in the home folder and are removed again in teardown.
final class FolderTargetTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cleaneject-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func plant(_ relativePaths: [String], under base: URL? = nil) throws {
        for path in relativePaths {
            let url = (base ?? root).appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    /// lstat(2): sees `._*` files, which Foundation hides, and symlinks as themselves.
    private func exists(_ relativePath: String) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent(relativePath).path, &info) == 0
    }

    private func relativeNames(_ report: CleanReport) -> Set<String> {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return Set(report.removed.map { String($0.path.dropFirst(prefix.count)) })
    }

    private func assertRefused(_ folder: URL, file: StaticString = #filePath, line: UInt = #line, _ matches: (CleanerError) -> Bool) async {
        XCTAssertNotNil(VolumeCleaner.folderRefusal(folder), folder.path, file: file, line: line)
        do {
            _ = try await VolumeCleaner.clean(folder: folder, rules: .all, dryRun: true)
            XCTFail("\(folder.path) must be refused", file: file, line: line)
        } catch let error as CleanerError {
            XCTAssertTrue(matches(error), "\(folder.path): unexpected \(error)", file: file, line: line)
            XCTAssertNotNil(error.errorDescription, file: file, line: line)
        } catch {
            XCTFail("\(folder.path): unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Rules

    /// The folder's children are not a volume's top level: `.Trashes` and friends inside a user folder survive.
    func testAppliesOnlyThePerFolderRules() async throws {
        let junk = [".DS_Store", "a/.DS_Store", "._x", "a/._y"]
        let kept = [".Trashes/x", ".Spotlight-V100/x", ".fseventsd/x", ".TemporaryItems/x", ".apdisk", "a/keep.txt", "a/._"]
        try plant(junk + kept)

        let report = try await VolumeCleaner.clean(folder: root, rules: HiddenFileRules(preventRecreation: true))

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(relativeNames(report), Set(junk))
        for path in junk { XCTAssertFalse(exists(path), "\(path) should be removed") }
        for path in kept { XCTAssertTrue(exists(path), "\(path) must survive in a folder") }
        XCTAssertFalse(exists(".metadata_never_index"), "folders never get prevention markers")
        XCTAssertFalse(exists(".fseventsd/no_log"))
    }

    func testRuleTogglesStillApply() async throws {
        try plant([".DS_Store", "a/._y"])
        var rules = HiddenFileRules.all
        rules.appleDouble = false

        let report = try await VolumeCleaner.clean(folder: root, rules: rules)

        XCTAssertEqual(relativeNames(report), [".DS_Store"])
        XCTAssertTrue(exists("a/._y"))
    }

    func testDryRunDeletesNothing() async throws {
        try plant([".DS_Store", "a/._y", ".Trashes/x"])

        let report = try await VolumeCleaner.clean(folder: root, rules: .all, dryRun: true)

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(relativeNames(report), [".DS_Store", "a/._y"])
        XCTAssertTrue(exists(".DS_Store"))
        XCTAssertTrue(exists("a/._y"))
    }

    func testDoesNotFollowSymlinks() async throws {
        let outside = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cleaneject-tests-\(UUID().uuidString)", isDirectory: true)
        try plant([".DS_Store", "._x"], under: outside)
        defer { try? fm.removeItem(at: outside) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent(".DS_Store"), withDestinationURL: outside.appendingPathComponent(".DS_Store"))

        let report = try await VolumeCleaner.clean(folder: root, rules: .all)

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent(".DS_Store").path))
        var info = stat()
        XCTAssertEqual(lstat(outside.appendingPathComponent("._x").path, &info), 0)
        XCTAssertTrue(exists("link"))
        XCTAssertTrue(exists(".DS_Store"), "a symlink named .DS_Store is not a .DS_Store file")
    }

    /// Only the folder itself must not be a link; links further up its path are resolved.
    func testResolvesLinksAboveTheFolder() async throws {
        try plant(["sub/.DS_Store"])
        let alias = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cleaneject-tests-link-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? fm.removeItem(at: alias) }

        await assertRefused(alias) { $0 == .symbolicLink(alias) }
        let report = try await VolumeCleaner.clean(folder: alias.appendingPathComponent("sub"), rules: .all)

        XCTAssertEqual(relativeNames(report), ["sub/.DS_Store"])
        XCTAssertFalse(exists("sub/.DS_Store"))
    }

    /// Random bytes are no AppleDouble file: the sidecar stays, is reported, and its file is untouched.
    func testCorruptSidecarIsKeptAndReported() async throws {
        try plant(["x"])
        let file = root.appendingPathComponent("x")
        let sidecar = root.appendingPathComponent("._x")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: sidecar)
        let attributesBefore = try attributeNames(file)
        XCTAssertTrue(VolumeCleaner.storesExtendedAttributesNatively(root.path), "the home folder is on APFS")

        let report = try await VolumeCleaner.clean(folder: root, rules: HiddenFileRules(mergeAppleDouble: true))

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.url.lastPathComponent, "._x")
        XCTAssertTrue(report.failures.first?.message.hasPrefix("Could not merge ._x into x: ") == true, report.failures.first?.message ?? "")
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(report.merged.isEmpty)
        XCTAssertTrue(exists("._x"), "a sidecar that cannot be merged is kept")
        XCTAssertEqual(try Data(contentsOf: file), Data("x".utf8))
        XCTAssertEqual(try attributeNames(file), attributesBefore)
    }

    func testCorruptSidecarOfAFolderIsKeptAndReported() async throws {
        try fm.createDirectory(at: root.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: root.appendingPathComponent("._Photos"))

        let report = try await VolumeCleaner.clean(folder: root, rules: HiddenFileRules(mergeAppleDouble: true))

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures.first?.message.hasPrefix("Could not merge ._Photos into Photos: ") == true, report.failures.first?.message ?? "")
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(exists("._Photos"))
    }

    /// Nothing is merged into "." or "..", nor into an item that is junk itself and about to go; those
    /// sidecars are removed as before (these hold random bytes, so a merge attempt would fail loudly).
    func testSidecarsOfDotsAndJunkAreRemovedWithoutMerging() async throws {
        for name in ["._.", "._..", "._.Trashes"] {
            try Data((0..<64).map { _ in UInt8.random(in: 0...255) }).write(to: root.appendingPathComponent(name))
        }
        try plant([".Trashes/x"])

        let report = try VolumeCleaner.cleanTree(root: root, rules: HiddenFileRules(mergeAppleDouble: true), dryRun: false)

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(Set(report.removed.map(\.lastPathComponent)), ["._.", "._..", "._.Trashes", ".Trashes"])
        XCTAssertTrue(report.merged.isEmpty)
    }

    func testMergeNeedsTheAppleDoubleRule() async throws {
        try plant(["x"])
        try Data(repeating: 0, count: 16).write(to: root.appendingPathComponent("._x"))

        let report = try await VolumeCleaner.clean(folder: root, rules: HiddenFileRules(appleDouble: false, mergeAppleDouble: true))

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(exists("._x"))
    }

    private func attributeNames(_ url: URL) throws -> [String] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        var buffer = [CChar](repeating: 0, count: max(size, 0))
        let read = listxattr(url.path, &buffer, buffer.count, XATTR_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(read, 0)
        return buffer.prefix(max(read, 0)).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
    }

    // MARK: Refusals

    func testRefusesVolumeRoots() async throws {
        await assertRefused(URL(fileURLWithPath: "/", isDirectory: true)) { $0 == .volumeRoot(URL(fileURLWithPath: "/", isDirectory: true)) }
    }

    func testRefusesSystemLocations() async throws {
        var folders = ["/System/Library", "/Library", "/usr/bin", "/private/tmp", "/tmp", "/var", "/etc", "/bin", "/sbin", "/dev"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        folders.append(fm.temporaryDirectory)
        for folder in folders where fm.fileExists(atPath: folder.path) {
            await assertRefused(folder) { $0 == .protectedFolder(folder) }
        }
    }

    func testRefusesFilesLinksAndMissingPaths() async throws {
        try plant(["file.txt"])
        let file = root.appendingPathComponent("file.txt")
        await assertRefused(file) { $0 == .notAFolder(file) }

        let link = root.appendingPathComponent("link", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
        await assertRefused(link) { $0 == .symbolicLink(link) }

        let missing = root.appendingPathComponent("missing", isDirectory: true)
        await assertRefused(missing) { $0 == .unreadable(missing) }

        XCTAssertNil(VolumeCleaner.folderRefusal(root))
    }

    func testProtectedFolderRule() {
        let protected = [
            "/System", "/System/Library/CoreServices", "/SYSTEM/library", "/Library/Preferences", "/usr", "/usr/local/bin",
            "/private", "/private/var/folders", "/var/nonexistent-cleaneject", "/tmp/nonexistent-cleaneject",
            "/etc", "/bin", "/sbin", "/dev", fm.temporaryDirectory.path,
        ]
        let allowed = [
            "/", "/Users", fm.homeDirectoryForCurrentUser.path, "/Applications", "/Volumes/CARD/DCIM", "/usr2", "/Systematic",
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library").path,
        ]
        for path in protected {
            XCTAssertTrue(VolumeCleaner.isProtectedFolder(URL(fileURLWithPath: path)), path)
        }
        for path in allowed {
            XCTAssertFalse(VolumeCleaner.isProtectedFolder(URL(fileURLWithPath: path)), path)
        }
    }

    func testFolderRulesKeepOnlyThePerFolderRules() {
        var rules = HiddenFileRules(mergeAppleDouble: true, preventRecreation: true)
        XCTAssertEqual(rules.forFolders, HiddenFileRules.none.with(dsStore: true, appleDouble: true, mergeAppleDouble: true))
        rules = .none
        XCTAssertEqual(rules.forFolders, .none)
        XCTAssertFalse(HiddenFileRules.all.mergeAppleDouble, "the merge is opt-in")
    }
}

private extension HiddenFileRules {
    func with(dsStore: Bool, appleDouble: Bool, mergeAppleDouble: Bool) -> HiddenFileRules {
        var rules = self
        rules.dsStore = dsStore
        rules.appleDouble = appleDouble
        rules.mergeAppleDouble = mergeAppleDouble
        return rules
    }
}
