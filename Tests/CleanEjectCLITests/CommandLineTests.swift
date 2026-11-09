import XCTest
import CleanEjectCore
@testable import CleanEjectCLI

final class ArgumentParsingTests: XCTestCase {
    private func parse(_ arguments: String...) throws(UsageError) -> Command {
        try Command.parse(arguments)
    }

    private func assertUsageError(_ arguments: String..., file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Command.parse(arguments), "\(arguments)", file: file, line: line) {
            XCTAssertTrue($0 is UsageError, file: file, line: line)
        }
    }

    func testHelpInEveryForm() throws {
        for arguments in [["help"], ["-h"], ["--help"], ["clean", "x", "--help"], ["list", "-h"], ["clean", "--bogus", "-h"]] {
            XCTAssertEqual(try Command.parse(arguments), .help, "\(arguments)")
        }
    }

    func testHelpAfterDoubleDashIsAPath() throws {
        guard case .run(let options) = try parse("clean", "--", "-h") else { return XCTFail() }
        XCTAssertEqual(options.paths, ["-h"])
    }

    func testCleanDefaultsMatchAFreshAppInstall() throws {
        guard case .run(let options) = try parse("clean", "/Volumes/SD") else { return XCTFail() }
        XCTAssertEqual(options, RunOptions(paths: ["/Volumes/SD"], rules: HiddenFileRules(), dryRun: false, eject: false, verbose: false, json: false))
    }

    func testPreviewIsAVerboseDryRun() throws {
        guard case .run(let options) = try parse("preview", "a", "b", "--json") else { return XCTFail() }
        XCTAssertEqual(options.paths, ["a", "b"])
        XCTAssertTrue(options.dryRun)
        XCTAssertTrue(options.verbose)
        XCTAssertTrue(options.json)
        XCTAssertFalse(options.eject)
    }

    func testOptionsAnywhereAfterTheCommand() throws {
        guard case .run(let options) = try parse("clean", "--json", "a", "-v", "b", "--eject", "--merge-appledouble", "--prevent-recreation")
        else { return XCTFail() }
        XCTAssertEqual(options.paths, ["a", "b"])
        XCTAssertTrue(options.json)
        XCTAssertTrue(options.verbose)
        XCTAssertTrue(options.eject)
        XCTAssertTrue(options.rules.mergeAppleDouble)
        XCTAssertTrue(options.rules.preventRecreation)
    }

    func testDoubleDashEndsOptions() throws {
        guard case .run(let options) = try parse("clean", "--dry-run", "--", "--json", "-v") else { return XCTFail() }
        XCTAssertEqual(options.paths, ["--json", "-v"])
        XCTAssertFalse(options.json)
        XCTAssertFalse(options.verbose)
        XCTAssertTrue(options.dryRun)
    }

    func testSkipTakesListsAndRepeats() throws {
        guard case .run(let options) = try parse("clean", "--skip", "ds-store,spotlight", "x", "--skip=apdisk", "--skip", "temporary-items")
        else { return XCTFail() }
        var expected = HiddenFileRules()
        expected.dsStore = false
        expected.spotlight = false
        expected.apdisk = false
        expected.temporaryItems = false
        XCTAssertEqual(options.rules, expected)
    }

    func testEverySkippableRuleTurnsItsToggleOff() throws {
        for rule in HiddenFileRules.Rule.toggleable {
            guard case .run(let options) = try parse("clean", "x", "--skip", rule.machineName) else { return XCTFail() }
            XCTAssertFalse(options.rules[keyPath: rule.toggle], rule.machineName)
            var others = options.rules
            others[keyPath: rule.toggle] = true
            XCTAssertEqual(others, HiddenFileRules(), "only \(rule.machineName) changed")
        }
        XCTAssertEqual(HiddenFileRules.Rule.toggleable.map(\.machineName),
                       ["ds-store", "appledouble", "spotlight", "fseventsd", "trashes", "temporary-items", "apdisk"])
    }

    func testUsageErrors() {
        assertUsageError()
        assertUsageError("bogus")
        assertUsageError("clean")
        assertUsageError("preview")
        assertUsageError("eject")
        assertUsageError("clean", "x", "--bogus")
        assertUsageError("clean", "x", "--skip")
        assertUsageError("clean", "x", "--skip", "nope")
        assertUsageError("clean", "x", "--skip", "macosx-folder")
        assertUsageError("clean", "x", "--skip", "ds-store,")
        assertUsageError("clean", "x", "--skip", "--")
        assertUsageError("clean", "x", "--eject", "--dry-run")
        assertUsageError("clean", "x", "--json=yes")
        assertUsageError("preview", "x", "--eject")
        assertUsageError("preview", "x", "--dry-run")
        assertUsageError("list", "/Volumes/SD")
        assertUsageError("list", "--skip", "ds-store")
        assertUsageError("eject", "x", "--skip", "ds-store")
        assertUsageError("clean", "")
        assertUsageError("clean", "x", "")
        assertUsageError("clean", "--", "")
        assertUsageError("preview", "")
        assertUsageError("eject", "")
        assertUsageError("list", "")
    }

    func testListAndEject() throws {
        XCTAssertEqual(try parse("list"), .list(json: false))
        XCTAssertEqual(try parse("list", "--json"), .list(json: true))
        XCTAssertEqual(try parse("eject", "--json", "/Volumes/A", "/Volumes/B"), .eject(paths: ["/Volumes/A", "/Volumes/B"], json: true))
    }

    func testHelpNamesEveryRuleAndOption() {
        let text = Help.text
        for rule in HiddenFileRules.Rule.toggleable {
            XCTAssertTrue(text.contains("  \(rule.machineName) "), rule.machineName)
        }
        for word in ["list", "preview", "clean", "eject", "--skip", "--merge-appledouble", "--prevent-recreation", "--eject", "--dry-run", "--verbose", "--json", "--help", "Full Disk Access"] {
            XCTAssertTrue(text.contains(word), word)
        }
    }
}

/// Runs whole commands against a folder under the home directory (the temporary directory is a
/// protected location and refused).
final class RunnerTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cleaneject-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: realpath(base.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? base.path, isDirectory: true)
        for path in [".DS_Store", "sub/.DS_Store", "._a.txt", "a.txt", "sub/b.txt", "._", ".Trashes/x"] {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent(path).path, &info) == 0
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private let junk = [".DS_Store", "sub/.DS_Store", "._a.txt"]
    private let kept = ["a.txt", "sub/b.txt", "._", ".Trashes/x"]

    func testPreviewJSONListsExactlyTheJunkAndChangesNothing() async throws {
        let result = await runCommand("preview", root.path, "--json")
        XCTAssertEqual(result.code, 0, result.err)
        let document = try json(result.out)
        let results = try XCTUnwrap(document["results"] as? [[String: Any]])
        XCTAssertEqual((document["refusals"] as? [Any])?.count, 0)
        XCTAssertEqual(results.count, 1)
        let first = results[0]
        XCTAssertEqual(first["path"] as? String, root.path)
        XCTAssertEqual(first["kind"] as? String, "folder")
        XCTAssertEqual(first["dryRun"] as? Bool, true)
        XCTAssertEqual(first["removedCount"] as? Int, 3)
        XCTAssertTrue(first["eject"] is NSNull)
        let removals = try XCTUnwrap(first["removals"] as? [[String: Any]])
        XCTAssertEqual(Set(removals.compactMap { $0["path"] as? String }), Set(junk.map { root.appendingPathComponent($0).path }))
        XCTAssertEqual(Set(removals.compactMap { $0["rule"] as? String }), ["ds-store", "appledouble"])
        for path in junk + kept { XCTAssertTrue(exists(path), path) }
    }

    func testCleanRemovesJunkAndPrintsASummary() async throws {
        let result = await runCommand("clean", root.path)
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("\(root.path): removed 3 items"), result.out)
        XCTAssertTrue(result.out.contains("  ds-store"), result.out)
        XCTAssertFalse(result.out.contains("sub/.DS_Store"), "no paths without -v: \(result.out)")
        for path in junk { XCTAssertFalse(exists(path), path) }
        for path in kept { XCTAssertTrue(exists(path), path) }
    }

    func testSkipKeepsThatRule() async throws {
        let result = await runCommand("clean", "-v", "--skip", "ds-store", root.path)
        XCTAssertEqual(result.code, 0, result.err)
        XCTAssertTrue(result.out.contains("._a.txt"), result.out)
        XCTAssertTrue(exists(".DS_Store"))
        XCTAssertTrue(exists("sub/.DS_Store"))
        XCTAssertFalse(exists("._a.txt"))
    }

    func testEjectWithAFolderIsAUsageErrorAndRemovesNothing() async throws {
        let clean = await runCommand("clean", "--eject", root.path)
        XCTAssertEqual(clean.code, 2)
        XCTAssertTrue(clean.err.contains("--help"), clean.err)
        let eject = await runCommand("eject", root.path)
        XCTAssertEqual(eject.code, 2)
        for path in junk { XCTAssertTrue(exists(path), path) }
    }

    func testOneRefusedPathStopsTheWholeRun() async throws {
        let text = await runCommand("clean", root.path, "/tmp", "/")
        XCTAssertEqual(text.code, 1)
        XCTAssertTrue(text.err.contains("/tmp is a system location"), text.err)
        XCTAssertTrue(text.err.contains("startup volume"), text.err)
        XCTAssertEqual(text.out, "")

        let json = await runCommand("clean", "--json", root.path, "/tmp")
        XCTAssertEqual(json.code, 1)
        let document = try self.json(json.out)
        XCTAssertEqual((document["results"] as? [Any])?.count, 0)
        let refusals = try XCTUnwrap(document["refusals"] as? [[String: Any]])
        XCTAssertEqual(refusals.map { $0["path"] as? String }, ["/tmp"])
        for path in junk { XCTAssertTrue(exists(path), path) }
    }

    func testAnEmptyPathRemovesNothing() async throws {
        let result = await runCommand("clean", "")
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.err.contains("empty path"), result.err)
    }

    func testJSONRefusalPathsAreAbsoluteButNotResolved() async throws {
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "sub")
        let previous = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(root.path))
        defer { fm.changeCurrentDirectoryPath(previous) }

        let json = await runCommand("clean", "--json", "link", "sub")
        XCTAssertEqual(json.code, 1)
        let refusals = try XCTUnwrap(try self.json(json.out)["refusals"] as? [[String: Any]])
        XCTAssertEqual(refusals.map { $0["path"] as? String }, [link.path])
        XCTAssertTrue(exists("sub/.DS_Store"), "nothing ran")

        let text = await runCommand("clean", "link")
        XCTAssertTrue(text.err.contains("cleaneject: link: "), "text keeps the path as typed: \(text.err)")
    }

    func testAFileStandsForItsFolder() async throws {
        let result = await runCommand("preview", "--json", root.appendingPathComponent("sub/b.txt").path)
        XCTAssertEqual(result.code, 0, result.err)
        let first = try XCTUnwrap((try json(result.out)["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["path"] as? String, root.appendingPathComponent("sub").path)
    }

    func testUsageErrorGoesToStderrWithAHint() async {
        let result = await runCommand("clean", root.path, "--skip", "nope")
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(result.out, "")
        XCTAssertTrue(result.err.contains("unknown rule 'nope'"), result.err)
        XCTAssertTrue(result.err.contains("Run 'cleaneject --help' for usage."), result.err)
    }

    func testListJSONParses() async throws {
        let result = await runCommand("list", "--json")
        XCTAssertEqual(result.code, 0)
        XCTAssertNotNil(try json(result.out)["volumes"] as? [Any])
    }
}

private final class Capture {
    var out = ""
    var err = ""
}

/// One whole command with stdout and stderr captured; the tool's stderr is not a terminal here.
@MainActor
private func runCommand(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
    let capture = Capture()
    let runner = Runner(console: Console(out: { capture.out += $0 }, err: { capture.err += $0 }, errIsTerminal: false))
    let code = await runner.run(arguments: arguments)
    return (code, capture.out, capture.err)
}
