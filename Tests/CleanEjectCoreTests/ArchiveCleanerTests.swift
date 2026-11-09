import XCTest
@testable import CleanEjectCore

final class ArchiveCleanerTests: XCTestCase {
    private let fm = FileManager.default
    private var directory: URL!

    override func setUpWithError() throws {
        directory = fm.temporaryDirectory.appendingPathComponent("CleanEjectArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? fm.removeItem(at: directory)
    }

    // MARK: Helpers

    /// Entry path → contents. `a/._`, `a/.DS_Store.bak` and the name with `*` and a space must survive.
    private static let fixture: [String: String] = [
        "a/.DS_Store": "ds-a",
        ".DS_Store": "ds-root",
        "a/._b.txt": "sidecar",
        "__MACOSX/a/._b.txt": "macosx sidecar",
        "a/b.txt": "real data",
        "a/._": "dot underscore",
        "a/.DS_Store.bak": "backup",
        "a/we*ird name.txt": "weird",
        ".Trashes/x": "trash",
    ]

    /// What `.all` removes from the fixture, as report paths (directory entries lose their slash).
    private static let fixtureJunk: Set<String> = [
        ".DS_Store", "a/.DS_Store", "a/._b.txt", "__MACOSX", "__MACOSX/a", "__MACOSX/a/._b.txt", ".Trashes", ".Trashes/x",
    ]
    private static let fixtureJunkBytes: Int64 = 7 + 4 + 7 + 14 + 5

    /// Zips `files` with /usr/bin/zip -r, which adds the directory entries as well. Files are created
    /// through open(2) with the exact UTF-8 of their names; Foundation would decompose them.
    private func makeArchive(_ name: String = "fixture.zip", files: [String: String] = fixture) throws -> URL {
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in files {
            let url = staging.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(staging.path + "/" + path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            XCTAssertGreaterThanOrEqual(descriptor, 0, path)
            _ = contents.utf8CString.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count - 1) }
            close(descriptor)
        }
        let archive = directory.appendingPathComponent(name)
        try run("/usr/bin/zip", ["-q", "-r", archive.path, "."], in: staging)
        try fm.removeItem(at: staging)
        return archive
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments)")
        return String(decoding: data, as: UTF8.self)
    }

    private func entries(of archive: URL) throws -> Set<String> {
        Set(try run("/usr/bin/unzip", ["-Z1", archive.path]).split(separator: "\n").map(String.init))
    }

    private func names(in report: CleanReport, of archive: URL) -> Set<String> {
        let prefix = archive.path + "/"
        return Set(report.removed.map { url in
            XCTAssertTrue(url.path.hasPrefix(prefix), url.path)
            return String(url.path.dropFirst(prefix.count))
        })
    }

    private func assertRefused(_ archive: URL, _ expected: CleanerError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await ArchiveCleaner.clean(archive: archive, rules: .all, dryRun: true)
            XCTFail("\(archive.lastPathComponent) must be refused", file: file, line: line)
        } catch let error as CleanerError {
            XCTAssertEqual(error, expected, file: file, line: line)
            XCTAssertNotNil(error.errorDescription, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Cleaning

    func testDryRunListsExactlyTheJunk() async throws {
        let archive = try makeArchive()
        let before = try Data(contentsOf: archive)

        let report = try await ArchiveCleaner.clean(archive: archive, rules: .all, dryRun: true)

        XCTAssertTrue(report.dryRun)
        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(names(in: report, of: archive), Self.fixtureJunk)
        XCTAssertEqual(report.removedCount, Self.fixtureJunk.count)
        XCTAssertEqual(report.removedBytes, Self.fixtureJunkBytes, "sizes come from the zipinfo listing")
        XCTAssertEqual(try Data(contentsOf: archive), before, "a dry run must not touch the archive")
    }

    func testRemovesExactlyTheJunk() async throws {
        let archive = try makeArchive()

        let report = try await ArchiveCleaner.clean(archive: archive, rules: .all)

        XCTAssertFalse(report.dryRun)
        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(names(in: report, of: archive), Self.fixtureJunk)
        XCTAssertEqual(report.removedBytes, Self.fixtureJunkBytes)
        XCTAssertEqual(try entries(of: archive), ["a/", "a/b.txt", "a/._", "a/.DS_Store.bak", "a/we*ird name.txt"])
        XCTAssertEqual(try run("/usr/bin/unzip", ["-p", archive.path, "a/b.txt"]), "real data")
        XCTAssertEqual(try run("/usr/bin/unzip", ["-p", archive.path, "a/we*ird name.txt"]), "weird")
    }

    func testTrashesEntriesGoOnlyWithTheirRule() async throws {
        let archive = try makeArchive()
        var rules = HiddenFileRules.all
        rules.trashes = false

        let report = try await ArchiveCleaner.clean(archive: archive, rules: rules)

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(names(in: report, of: archive), Self.fixtureJunk.subtracting([".Trashes", ".Trashes/x"]))
        XCTAssertTrue(try entries(of: archive).isSuperset(of: [".Trashes/", ".Trashes/x"]))
    }

    func testRulesOffKeepEveryEntry() async throws {
        let archive = try makeArchive()
        let before = try Data(contentsOf: archive)

        let report = try await ArchiveCleaner.clean(archive: archive, rules: .none)

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: archive), before)
    }

    func testAlreadyCleanArchiveYieldsAnEmptySuccessfulReport() async throws {
        let archive = try makeArchive()
        _ = try await ArchiveCleaner.clean(archive: archive, rules: .all)
        let before = try Data(contentsOf: archive)

        let report = try await ArchiveCleaner.clean(archive: archive, rules: .all)

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.removedBytes, 0)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: archive), before)
    }

    func testArchiveOfOnlyJunkStaysAnEmptyArchive() async throws {
        let archive = try makeArchive(files: [".DS_Store": "x", "__MACOSX/._x": "y"])

        let report = try await ArchiveCleaner.clean(archive: archive, rules: .all)

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(names(in: report, of: archive), [".DS_Store", "__MACOSX", "__MACOSX/._x"])
        XCTAssertTrue(fm.fileExists(atPath: archive.path), "zip keeps an empty archive")
        let again = try await ArchiveCleaner.clean(archive: archive, rules: .all, dryRun: true)
        XCTAssertEqual(again.removedCount, 0)
    }

    /// unzip reads `*`, `?`, `[` and `\` in an archive's file name as a pattern, and the decoy matches it.
    func testArchiveNameWithPatternCharactersIsTakenLiterally() async throws {
        let archive = try makeArchive("we*ird [1].zip")
        let decoy = try makeArchive("weXird 1.zip", files: ["decoy/.DS_Store": "decoy", "decoy/keep.txt": "keep"])
        let decoyBefore = try Data(contentsOf: decoy)

        let preview = try await ArchiveCleaner.clean(archive: archive, rules: .all, dryRun: true)
        XCTAssertEqual(names(in: preview, of: archive), Self.fixtureJunk)

        let report = try await ArchiveCleaner.clean(archive: archive, rules: .all)
        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(names(in: report, of: archive), Self.fixtureJunk)
        XCTAssertEqual(try Data(contentsOf: decoy), decoyBefore, "the decoy archive must be untouched")
    }

    func testCancelledRunLeavesTheArchiveAlone() async throws {
        let archive = try makeArchive()
        let before = try Data(contentsOf: archive)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ArchiveCleaner.clean(archive: archive, rules: .all)
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: archive), before)
    }

    // MARK: Wildcards and names

    /// zip -d reads "?" as a wildcard even with -nw, across "/": `a/._x?y` would take `a/._x/y` along.
    func testQuestionMarkNeverReachesAnotherEntry() async throws {
        let archive = try makeArchive(files: ["a/._x?y": "junk", "a/._x/y": "keep"])

        let report = try await ArchiveCleaner.clean(archive: archive, rules: .all)

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.failures.map(\.message), [ArchiveCleaner.wildcardMessage])
        XCTAssertEqual(report.failures.first?.url.lastPathComponent, "._x?y")
        XCTAssertEqual(try entries(of: archive), ["a/", "a/._x?y", "a/._x/", "a/._x/y"])

        let alone = try makeArchive("alone.zip", files: ["a/._x?y": "junk", "a/b.txt": "keep"])
        let cleaned = try await ArchiveCleaner.clean(archive: alone, rules: .all)
        XCTAssertTrue(cleaned.failures.isEmpty, cleaned.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(names(in: cleaned, of: alone), ["a/._x?y"])
        XCTAssertEqual(try entries(of: alone), ["a/", "a/b.txt"])
    }

    /// An app started from Finder has no LANG. Without a UTF-8 locale unzip prints `é` as `??`, which zip
    /// reads as two wildcards matching `/x`, so `a/._café.jpg` would delete `a/._caf/x.jpg`.
    func testNonASCIINamesRoundTripWithoutALocale() async throws {
        let locale = ProcessInfo.processInfo.environment.filter { $0.key == "LANG" || $0.key.hasPrefix("LC_") }
        for key in locale.keys { unsetenv(key) }
        addTeardownBlock { for (key, value) in locale { setenv(key, value, 1) } }
        XCTAssertFalse(ProcessInfo.processInfo.environment.keys.contains { $0 == "LANG" || $0.hasPrefix("LC_") })
        let archive = try makeArchive(files: ["a/._caf\u{00E9}.jpg": "junk", "a/._caf/x.jpg": "keep"])

        let report = try await ArchiveCleaner.clean(archive: archive, rules: .all)

        XCTAssertTrue(report.failures.isEmpty, report.failures.map { "\($0.url.path): \($0.message)" }.joined(separator: "\n"))
        XCTAssertEqual(names(in: report, of: archive), ["a/._caf\u{00E9}.jpg"])
        XCTAssertEqual(try entries(of: archive), ["a/", "a/._caf/", "a/._caf/x.jpg"])
    }

    /// zip takes "*" and "[" literally with -nw, but they are checked the same way, generously.
    func testStarAndBracketNamesAreCheckedToo() async throws {
        let colliding = try makeArchive(files: ["a/._x*y": "junk", "a/._x[!q]y": "junk", "a/._x/zzy": "keep", "a/._x/y": "keep"])
        let before = try Data(contentsOf: colliding)

        let report = try await ArchiveCleaner.clean(archive: colliding, rules: .all)

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(Set(report.failures.map(\.url.lastPathComponent)), ["._x*y", "._x[!q]y"])
        XCTAssertTrue(report.failures.allSatisfy { $0.message == ArchiveCleaner.wildcardMessage })
        XCTAssertEqual(try Data(contentsOf: colliding), before, "zip is not run for nothing")

        let alone = try makeArchive("alone.zip", files: ["a/._p*q": "junk", "a/._r[1]": "junk", "a/._r1": "junk", "a/b.txt": "keep"])
        let cleaned = try await ArchiveCleaner.clean(archive: alone, rules: .all)
        XCTAssertTrue(cleaned.failures.isEmpty, cleaned.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(names(in: cleaned, of: alone), ["a/._p*q", "a/._r[1]", "a/._r1"])
        XCTAssertEqual(try entries(of: alone), ["a/", "a/b.txt"])
    }

    func testWildcardReading() {
        let matching = [
            ("a/._x?y", "a/._x/y"), ("a/._caf??.jpg", "a/._caf/x.jpg"), ("a/._x?y", "a/._x\u{00E9}y"), ("a*", "a/b/c"),
            ("a*", "a"), ("x[ab]y", "xay"), ("x[ab]y", "x[ab]y"), ("a[b]?", "a[b]x"), ("x[!q]y", "x/y"), ("a\\?", "a\\x"),
        ]
        let different = [("a?b", "ab"), ("a?b", "a12345b"), ("abc", "abd"), ("a\\?", "a?"), ("x[ab]y", "xy"), ("abc", "abcd")]
        for (pattern, name) in matching {
            XCTAssertTrue(ArchiveCleaner.wildcardMatches(pattern, name), "\(pattern) should cover \(name)")
        }
        for (pattern, name) in different {
            XCTAssertFalse(ArchiveCleaner.wildcardMatches(pattern, name), "\(pattern) must not match \(name)")
        }
        XCTAssertEqual(ArchiveCleaner.namesMatchingOtherEntries(["a/._x?y", "a/._z"], entries: ["a/._x?y", "a/._z", "a/._x/y"]), ["a/._x?y"])
        XCTAssertEqual(ArchiveCleaner.namesMatchingOtherEntries(["a/._x?y", "a/._x/y"], entries: ["a/._x?y", "a/._x/y"]), [], "matching another candidate is fine")
    }

    // MARK: Archive metadata

    /// zip writes a new file; a downloaded archive must keep its quarantine (and tags, where-from).
    func testKeepsTheArchivesExtendedAttributes() async throws {
        let archive = try makeArchive()
        try run("/usr/bin/xattr", ["-w", "com.example.tag", "blue", archive.path])
        try run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0083;66b0c3a1;Safari;", archive.path])

        let report = try await ArchiveCleaner.clean(archive: archive, rules: .all)

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(names(in: report, of: archive), Self.fixtureJunk)
        XCTAssertEqual(try run("/usr/bin/xattr", ["-p", "com.example.tag", archive.path]), "blue\n")
        XCTAssertEqual(try run("/usr/bin/xattr", ["-p", "com.apple.quarantine", archive.path]), "0083;66b0c3a1;Safari;\n")
    }

    // MARK: Refusals

    func testRefusesReadOnlyArchive() async throws {
        let archive = try makeArchive()
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: archive.path)
        let before = try Data(contentsOf: archive)

        await assertRefused(archive, .notWritable(archive))

        XCTAssertEqual(try Data(contentsOf: archive), before)
    }

    func testRefusesArchiveInReadOnlyFolder() async throws {
        let folder = directory.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = try makeArchive()
        let moved = folder.appendingPathComponent("fixture.zip")
        try fm.moveItem(at: archive, to: moved)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        await assertRefused(moved, .notWritable(moved))
    }

    func testRefusesAnythingButARegularZipFile() async throws {
        let archive = try makeArchive()

        let text = directory.appendingPathComponent("notes.txt")
        try fm.copyItem(at: archive, to: text)
        await assertRefused(text, .notAZipArchive(text))

        let folder = directory.appendingPathComponent("folder.zip", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        await assertRefused(folder, .notAZipArchive(folder))

        let link = directory.appendingPathComponent("link.zip")
        try fm.createSymbolicLink(at: link, withDestinationURL: archive)
        await assertRefused(link, .notAZipArchive(link))

        let missing = directory.appendingPathComponent("missing.zip")
        await assertRefused(missing, .unreadable(missing))

        let damaged = directory.appendingPathComponent("damaged.zip")
        try Data("not a zip".utf8).write(to: damaged)
        await assertRefused(damaged, .unreadableArchive(damaged))

        let upper = directory.appendingPathComponent("UPPER.ZIP")
        try fm.copyItem(at: archive, to: upper)
        let report = try await ArchiveCleaner.clean(archive: upper, rules: .all, dryRun: true)
        XCTAssertEqual(names(in: report, of: upper), Self.fixtureJunk, "the extension is matched without regard to case")
    }

    // MARK: Rules

    func testArchiveEntryRules() {
        let junk = [
            ".DS_Store", "a/.DS_Store", "a/b/c/.DS_Store", "._x", "a/._b.txt", "a/b/._c",
            "__MACOSX/", "__MACOSX/a/", "__MACOSX/a/._b.txt", "__MACOSX/anything.txt",
            ".Spotlight-V100/", ".Spotlight-V100/Store-V2/x", ".fseventsd/", ".fseventsd/0001",
            ".Trashes/", ".Trashes/501/x", ".TemporaryItems/", ".TemporaryItems/x", ".apdisk",
        ]
        let kept = [
            "", "/", "a/", "a/b.txt", "._", "a/._", "a/.DS_Store.bak", "a/we*ird name.txt", "DS_Store",
            ".DS_Store/", "a/._dir/", ".apdisk/", "a/.apdisk", "__MACOSX", ".Trashes", ".Spotlight-V100",
            "a/__MACOSX/x", "a/.Trashes/x", "a/.Spotlight-V100/", "x/__MACOSX/",
        ]
        for name in junk {
            XCTAssertTrue(HiddenFileRules.all.shouldRemove(archiveEntry: name), "\(name) is junk")
            XCTAssertFalse(HiddenFileRules.none.shouldRemove(archiveEntry: name), "\(name) must survive with every rule off")
        }
        for name in kept {
            XCTAssertFalse(HiddenFileRules.all.shouldRemove(archiveEntry: name), "\(name) must survive")
        }

        let cases: [(WritableKeyPath<HiddenFileRules, Bool>, [String])] = [
            (\.dsStore, ["a/.DS_Store"]),
            (\.appleDouble, ["a/._x", "__MACOSX/", "__MACOSX/a/x"]),
            (\.spotlight, [".Spotlight-V100/x"]),
            (\.fsevents, [".fseventsd/x"]),
            (\.trashes, [".Trashes/x"]),
            (\.temporaryItems, [".TemporaryItems/x"]),
            (\.apdisk, [".apdisk"]),
        ]
        for (keyPath, names) in cases {
            var only = HiddenFileRules.none
            only[keyPath: keyPath] = true
            for (_, otherNames) in cases {
                for name in otherNames {
                    XCTAssertEqual(only.shouldRemove(archiveEntry: name), names.contains(name), "\(name) with only \(keyPath)")
                }
            }
        }
    }

    func testOnlyNamesZipMatchesExactlyAreHandedToZip() {
        for name in [".DS_Store", "a/._b", "__MACOSX/", "__MACOSX/a/", "a b/c*d [1]?.txt", "caf\u{00E9}/._x"] {
            XCTAssertTrue(ArchiveCleaner.isAddressable(name), name)
        }
        for name in ["/.DS_Store", "./.DS_Store", "a/./._x", "a/../._x", "../._x", "a//._x", "//", "._x\r", "a\n/._x"] {
            XCTAssertFalse(ArchiveCleaner.isAddressable(name), name)
        }
    }
}
