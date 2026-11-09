import XCTest
@testable import CleanEjectCore

final class CommandLineToolInstallerTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var bin: URL { root.appendingPathComponent("home/.local/bin", isDirectory: true) }
    private var link: URL { bin.appendingPathComponent("cleaneject") }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("cleaneject-installer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// An executable placeholder at `<root>/<name>/CleanEject.app/Contents/Helpers/cleaneject`.
    private func helper(in name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name)/CleanEject.app/Contents/Helpers/cleaneject")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func installer(_ helper: URL?) -> CommandLineToolInstaller {
        CommandLineToolInstaller(linkURL: link, helperURL: helper)
    }

    func testInstallCreatesTheFolderAndTheLink() throws {
        let installer = installer(try helper(in: "A"))
        XCTAssertEqual(installer.state(), .notInstalled)
        XCTAssertFalse(fm.fileExists(atPath: bin.path))

        try installer.install()

        XCTAssertEqual(installer.state(), .installed)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), installer.helperURL?.path)
        try installer.install()
        XCTAssertEqual(installer.state(), .installed, "installing twice is a no-op")
    }

    func testRemoveDeletesOnlyTheLink() throws {
        let installer = installer(try helper(in: "A"))
        try installer.install()
        try installer.remove()
        XCTAssertEqual(installer.state(), .notInstalled)
        XCTAssertTrue(fm.isExecutableFile(atPath: installer.helperURL!.path), "the helper stays")
        XCTAssertTrue(fm.fileExists(atPath: bin.path), "the folder stays")
        try installer.remove()
    }

    func testALinkToAnotherBundleIsReplaced() throws {
        let other = try helper(in: "B")
        let installer = installer(try helper(in: "A"))
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: other.path)
        XCTAssertEqual(installer.state(), .linkedElsewhere(other.path))

        try installer.install()

        XCTAssertEqual(installer.state(), .installed)
        XCTAssertTrue(fm.isExecutableFile(atPath: other.path))
    }

    func testADanglingLinkToARemovedBundleCountsAsCleanEjects() throws {
        let installer = installer(try helper(in: "A"))
        let gone = root.appendingPathComponent("gone/CleanEject.app/Contents/Helpers/cleaneject").path
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: gone)
        XCTAssertEqual(installer.state(), .linkedElsewhere(gone))
        try installer.remove()
        XCTAssertEqual(installer.state(), .notInstalled)
    }

    func testARelativeLinkToThisHelperIsInstalled() throws {
        let installer = installer(try helper(in: "A"))
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../A/CleanEject.app/Contents/Helpers/cleaneject")
        XCTAssertEqual(installer.state(), .installed)
    }

    func testAnythingElseBlocksAndIsNeverTouched() throws {
        let installer = installer(try helper(in: "A"))
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

        let foreign = root.appendingPathComponent("other-tool")
        try Data("mine".utf8).write(to: foreign)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: foreign.path)
        try assertBlocked(installer)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), foreign.path)
        try fm.removeItem(at: link)

        try Data("mine".utf8).write(to: link)
        try assertBlocked(installer)
        XCTAssertEqual(try Data(contentsOf: link), Data("mine".utf8))
        try fm.removeItem(at: link)

        try fm.createDirectory(at: link, withIntermediateDirectories: false)
        try assertBlocked(installer)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: link.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    private func assertBlocked(_ installer: CommandLineToolInstaller, line: UInt = #line) throws {
        guard case .blocked(let reason) = installer.state() else {
            return XCTFail("expected blocked, got \(installer.state())", line: line)
        }
        XCTAssertTrue(reason.contains(link.path), reason, line: line)
        XCTAssertThrowsError(try installer.install(), line: line) { XCTAssertEqual($0 as? CommandLineToolInstaller.Failure, .blocked(reason)) }
        XCTAssertThrowsError(try installer.remove(), line: line) { XCTAssertEqual($0 as? CommandLineToolInstaller.Failure, .blocked(reason)) }
    }

    func testWithoutAHelperInstallIsUnavailable() throws {
        let installer = CommandLineToolInstaller(bundle: .main, linkDirectory: bin)
        XCTAssertNil(installer.helperURL, "the test bundle has no Contents/Helpers/cleaneject")
        XCTAssertNotNil(installer.unavailableReason)
        XCTAssertEqual(installer.linkURL, link)
        XCTAssertThrowsError(try installer.install()) { XCTAssertEqual($0 as? CommandLineToolInstaller.Failure, .noHelper) }
        XCTAssertEqual(installer.state(), .notInstalled)
    }

    func testABundleWithAHelperIsFound() throws {
        let helper = try helper(in: "A")
        let bundle = try XCTUnwrap(Bundle(path: root.appendingPathComponent("A/CleanEject.app").path))
        let installer = CommandLineToolInstaller(bundle: bundle, linkDirectory: bin)
        XCTAssertEqual(installer.helperURL?.path, helper.path)
        XCTAssertNil(installer.unavailableReason)
    }

    func testDefaultLinkIsInLocalBin() {
        XCTAssertEqual(
            CommandLineToolInstaller().linkURL.path,
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cleaneject").path
        )
    }
}
