import XCTest
@testable import CleanEjectCore

final class VolumeCleanerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanEjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    private func plantFile(_ relativePath: String, bytes: Int = 4) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    private func plantDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// lstat(2) on the exact path: sees symlinks as themselves and `._*` files, which Foundation hides.
    private func rawExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func exists(_ relativePath: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path, isDirectory: &isDirectory)
            || (try? root.appendingPathComponent(relativePath).checkResourceIsReachable()) == true
    }

    @discardableResult
    private func clean(_ rules: HiddenFileRules = .all, dryRun: Bool = false) throws -> CleanReport {
        try VolumeCleaner.cleanTree(root: root, rules: rules, dryRun: dryRun)
    }

    // MARK: Rules

    func testRemovesDSStoreAtSeveralDepths() throws {
        try plantFile(".DS_Store")
        try plantFile("a/.DS_Store")
        try plantFile("a/b/c/.DS_Store")
        try plantFile("a/b/c/photo.jpg")

        let report = try clean()

        XCTAssertEqual(report.removedCount, 3)
        XCTAssertEqual(report.removedBytes, 12)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(exists(".DS_Store"))
        XCTAssertFalse(exists("a/.DS_Store"))
        XCTAssertFalse(exists("a/b/c/.DS_Store"))
        XCTAssertTrue(exists("a/b/c/photo.jpg"))
    }

    func testRemovesAppleDoubleFiles() throws {
        try plantFile("._foo")
        try plantFile("a/._.DS_Store")
        try plantFile("a/b/._IMG_0001.JPG")
        try plantFile("a/b/IMG_0001.JPG")

        try clean()

        XCTAssertFalse(exists("._foo"))
        XCTAssertFalse(exists("a/._.DS_Store"))
        XCTAssertFalse(exists("a/b/._IMG_0001.JPG"))
        XCTAssertTrue(exists("a/b/IMG_0001.JPG"))
    }

    func testKeepsLookalikes() throws {
        try plantFile(".hidden")
        try plantFile("_foo")
        try plantFile("a/_foo")
        // Exactly "._" is kept: the AppleDouble rule needs a name longer than two characters.
        try plantFile("._")
        try plantFile("DS_Store")
        try plantFile(".DS_Store.bak")
        try plantDirectory(".git")
        try plantFile(".git/config")

        let report = try clean()

        XCTAssertEqual(report.removedCount, 0)
        for path in [".hidden", "_foo", "a/_foo", "._", "DS_Store", ".DS_Store.bak", ".git/config"] {
            XCTAssertTrue(exists(path), "\(path) should be untouched")
        }
    }

    func testTopLevelFoldersOnlyAtTopLevel() throws {
        for name in [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems"] {
            try plantFile("\(name)/inner/file")
            try plantFile("nested/\(name)/inner/file")
        }
        try plantFile(".apdisk")
        try plantFile("nested/.apdisk")

        let report = try clean()

        XCTAssertEqual(report.removedCount, 5)
        for name in [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".apdisk"] {
            XCTAssertFalse(exists(name), "top-level \(name) should be removed")
            XCTAssertTrue(exists("nested/\(name)"), "nested \(name) should be kept")
        }
    }

    func testTopLevelRulesIgnoreWrongItemKind() throws {
        try plantFile(".Spotlight-V100")           // a file, rule wants a directory
        try plantDirectory(".apdisk")              // a directory, rule wants a file
        try plantDirectory(".DS_Store")            // a directory, rule wants a file

        let report = try clean()

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(exists(".Spotlight-V100"))
        XCTAssertTrue(exists(".apdisk"))
        XCTAssertTrue(exists(".DS_Store"))
    }

    func testEachRuleToggleRemovesOnlyItsTargets() throws {
        let cases: [(WritableKeyPath<HiddenFileRules, Bool>, String)] = [
            (\.dsStore, "a/.DS_Store"),
            (\.appleDouble, "a/._x"),
            (\.spotlight, ".Spotlight-V100"),
            (\.fsevents, ".fseventsd"),
            (\.trashes, ".Trashes"),
            (\.temporaryItems, ".TemporaryItems"),
            (\.apdisk, ".apdisk"),
        ]
        func plantAll() throws {
            try plantFile("a/.DS_Store")
            try plantFile("a/._x")
            try plantFile(".apdisk")
            for dir in [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems"] { try plantFile("\(dir)/x") }
        }

        for (keyPath, target) in cases {
            try plantAll()
            var only = HiddenFileRules.none
            only[keyPath: keyPath] = true
            let report = try clean(only)
            XCTAssertEqual(report.removedCount, 1, "rule for \(target) should remove exactly one item")
            XCTAssertFalse(exists(target), "\(target) should be removed")
            for (_, other) in cases where other != target {
                XCTAssertTrue(exists(other), "\(other) should survive when only \(target) is enabled")
            }

            try plantAll()
            var allButOne = HiddenFileRules.all
            allButOne[keyPath: keyPath] = false
            try clean(allButOne)
            XCTAssertTrue(exists(target), "\(target) should survive when its rule is off")
            for (_, other) in cases where other != target {
                XCTAssertFalse(exists(other), "\(other) should be removed when only \(target) is disabled")
            }
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    func testNoRulesRemovesNothing() throws {
        try plantFile(".DS_Store")
        try plantFile(".Trashes/x")
        XCTAssertFalse(HiddenFileRules.none.removesAnything)

        let report = try clean(.none)

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(exists(".DS_Store"))
        XCTAssertTrue(exists(".Trashes/x"))
    }

    // MARK: Modes

    func testDryRunDeletesNothingButReportsCandidates() throws {
        try plantFile(".DS_Store", bytes: 10)
        try plantFile("a/._x", bytes: 5)
        try plantFile(".Spotlight-V100/store", bytes: 100)
        try plantFile(".Spotlight-V100/deeper/store", bytes: 100)

        let report = try clean(HiddenFileRules(preventRecreation: true), dryRun: true)

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.removedCount, 3)
        XCTAssertEqual(report.removedBytes, 215)
        XCTAssertEqual(Set(report.removed.map(\.lastPathComponent)), [".DS_Store", "._x", ".Spotlight-V100"])
        XCTAssertTrue(exists(".DS_Store"))
        XCTAssertTrue(exists("a/._x"))
        XCTAssertTrue(exists(".Spotlight-V100/deeper/store"))
        XCTAssertFalse(exists(".metadata_never_index"))
        XCTAssertFalse(exists(".fseventsd/no_log"))
    }

    func testPreventRecreationWritesMarkers() throws {
        try plantFile(".fseventsd/0000001")

        let report = try clean(HiddenFileRules(preventRecreation: true))

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(exists(".fseventsd/0000001"))
        XCTAssertTrue(exists(".metadata_never_index"))
        XCTAssertTrue(exists(".fseventsd/no_log"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".metadata_never_index")).count, 0)
    }

    func testPreventRecreationNeverFollowsSymlinks() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanEjectOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideSidecar = outside.appendingPathComponent("._no_log")
        try Data("keep".utf8).write(to: outsideSidecar)
        let danglingTarget = outside.appendingPathComponent("never-created")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".fseventsd"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".metadata_never_index"), withDestinationURL: danglingTarget)
        let outsideBefore = try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted()

        let report = try clean(HiddenFileRules(preventRecreation: true))

        XCTAssertEqual(report.removedCount, 0, "symlinks are never removed")
        XCTAssertEqual(report.failures.count, 2, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(Set(report.failures.map(\.url.lastPathComponent)), [".fseventsd", ".metadata_never_index"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted(), outsideBefore)
        XCTAssertFalse(rawExists(danglingTarget), "a dangling marker symlink must not create its target")
        XCTAssertFalse(rawExists(outside.appendingPathComponent("no_log")))
        XCTAssertEqual(try Data(contentsOf: outsideSidecar), Data("keep".utf8), "sidecar unlink must not reach through the link")
        for link in [".fseventsd", ".metadata_never_index"] {
            XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(link).path), "\(link) symlink should be untouched")
        }
    }

    func testPreventRecreationLeavesAFseventsdFileAlone() throws {
        try plantFile(".fseventsd", bytes: 3)

        let report = try clean(HiddenFileRules(preventRecreation: true))

        XCTAssertEqual(report.removedCount, 0, "a regular file never matches the directory rule")
        XCTAssertEqual(report.failures.map(\.url.lastPathComponent), [".fseventsd"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".fseventsd")).count, 3)
        XCTAssertFalse(exists(".fseventsd/no_log"))
        XCTAssertTrue(exists(".metadata_never_index"))
    }

    func testPreventRecreationKeepsExistingMarkers() throws {
        try plantFile(".metadata_never_index", bytes: 2)
        try plantFile(".fseventsd/no_log", bytes: 2)

        let report = try clean(HiddenFileRules(fsevents: false, preventRecreation: true))

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".metadata_never_index")).count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".fseventsd/no_log")).count, 2)
    }

    func testPreventRecreationIsOffByDefault() throws {
        try clean()
        XCTAssertFalse(exists(".metadata_never_index"))
        XCTAssertFalse(exists(".fseventsd"))
    }

    // MARK: Safety

    func testDoesNotFollowSymlinks() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanEjectOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideJunk = outside.appendingPathComponent(".DS_Store")
        try Data().write(to: outsideJunk)
        try Data().write(to: outside.appendingPathComponent("._x"))

        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".DS_Store"), withDestinationURL: outsideJunk)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".Trashes"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("._link"), withDestinationURL: outsideJunk)

        let report = try clean()

        XCTAssertEqual(report.removedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideJunk.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("._x").path))
        for link in ["link", ".DS_Store", ".Trashes", "._link"] {
            XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(link).path), "\(link) symlink should be untouched")
        }
    }

    func testRemovesSymlinksInsideJunkFolderAsLinks() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanEjectOutside-\(UUID().uuidString)", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("data/file.txt")
        try FileManager.default.createDirectory(at: outsideFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outsideFile)
        defer { try? FileManager.default.removeItem(at: outside) }
        try plantFile(".Trashes/junk")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".Trashes/dirlink"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".Trashes/filelink"), withDestinationURL: outsideFile)

        let report = try clean()

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(report.removed.map(\.lastPathComponent), [".Trashes"])
        XCTAssertFalse(exists(".Trashes"))
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["data"])
    }

    func testContinuesAfterFailure() throws {
        try plantFile("locked/.DS_Store")
        try plantFile("zzz/.DS_Store")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let report = try clean()

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.url.lastPathComponent, ".DS_Store")
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertFalse(exists("zzz/.DS_Store"))
    }

    func testRefusesRootFileSystem() async throws {
        for path in ["/", "/Volumes/Macintosh HD", "/System/Volumes/Data"] where FileManager.default.fileExists(atPath: path) {
            do {
                _ = try await VolumeCleaner.clean(volumeRoot: URL(fileURLWithPath: path), rules: .all, dryRun: true)
                XCTFail("\(path) must be refused")
            } catch let error as CleanerError {
                guard case .rootFileSystem = error else { return XCTFail("\(path): unexpected \(error)") }
            }
        }
    }

    private func fakeVolume(path: String, isInternal: Bool, isRemovable: Bool, isEjectable: Bool, browsable: Bool = true, rootFileSystem: Bool = false) -> VolumeInfo {
        VolumeInfo(
            url: URL(fileURLWithPath: path, isDirectory: true), name: "Fake", formatDescription: "ExFAT",
            totalBytes: 1, availableBytes: 1, isRemovable: isRemovable, isEjectable: isEjectable, isInternal: isInternal,
            isLocal: true, isReadOnly: false, isBrowsable: browsable, isRootFileSystem: rootFileSystem
        )
    }

    func testRefusalRuleOnFakeVolumes() {
        // A card in the built-in reader: internal but removable. The main use case, must be accepted and listed.
        let cardInBuiltInReader = fakeVolume(path: "/Volumes/SDCARD", isInternal: true, isRemovable: true, isEjectable: false)
        XCTAssertNil(cardInBuiltInReader.refusal)
        XCTAssertTrue(cardInBuiltInReader.isExternalCandidate)
        XCTAssertNil(fakeVolume(path: "/Volumes/USB", isInternal: true, isRemovable: false, isEjectable: true).refusal)
        XCTAssertNil(fakeVolume(path: "/Volumes/Image", isInternal: false, isRemovable: false, isEjectable: false).refusal)

        let fixedInternal = fakeVolume(path: "/Volumes/Data2", isInternal: true, isRemovable: false, isEjectable: false)
        XCTAssertEqual(fixedInternal.refusal, .internalVolume(fixedInternal.url))
        XCTAssertFalse(fixedInternal.isExternalCandidate)
        XCTAssertEqual(fixedInternal.refusal?.localizedDescription, "Fixed internal volumes are never cleaned.")

        let system = fakeVolume(path: "/System/Volumes/Preboot", isInternal: false, isRemovable: true, isEjectable: true)
        XCTAssertEqual(system.refusal, .internalVolume(system.url))
        let startup = fakeVolume(path: "/", isInternal: true, isRemovable: false, isEjectable: false, rootFileSystem: true)
        XCTAssertEqual(startup.refusal, .rootFileSystem(startup.url))

        // Hidden volumes (Time Machine backups) may be cleaned when dropped, but are never listed.
        let hidden = fakeVolume(path: "/Volumes/Backups", isInternal: false, isRemovable: true, isEjectable: true, browsable: false)
        XCTAssertNil(hidden.refusal)
        XCTAssertFalse(hidden.isExternalCandidate)
    }

    func testRefusesInternalAndSystemVolumes() async throws {
        let startup = try XCTUnwrap(VolumeInfo.containing(URL(fileURLWithPath: "/")))
        XCTAssertTrue(startup.isInternal)
        guard case .rootFileSystem = startup.refusal else { return XCTFail("\(String(describing: startup.refusal))") }

        for path in ["/System/Volumes/Preboot", "/System/Volumes/VM", "/System/Volumes/Update"] where FileManager.default.fileExists(atPath: path) {
            let info = try XCTUnwrap(VolumeInfo.containing(URL(fileURLWithPath: path)))
            XCTAssertNotNil(info.refusal, path)
            XCTAssertFalse(info.isExternalCandidate, path)
            do {
                _ = try await VolumeCleaner.clean(volumeRoot: URL(fileURLWithPath: path), rules: .all, dryRun: true)
                XCTFail("\(path) must be refused")
            } catch let error as CleanerError {
                switch error {
                case .rootFileSystem, .internalVolume: break
                default: XCTFail("\(path): unexpected \(error)")
                }
            }
        }
        XCTAssertEqual(CleanerError.internalVolume(URL(fileURLWithPath: "/x")).localizedDescription, "Fixed internal volumes are never cleaned.")
        XCTAssertFalse(VolumeInfo.mountedExternal().contains { $0.refusal != nil || !$0.isBrowsable })
    }

    /// The temporary directory sits on the startup volume, so either check may fire first; the
    /// disk image tests cover `notAVolumeRoot` for a subdirectory of an external volume.
    func testRefusesDirectoryThatIsNotAVolumeRoot() async throws {
        try plantFile(".DS_Store")
        do {
            _ = try await VolumeCleaner.clean(volumeRoot: root, rules: .all)
            XCTFail("a plain directory must be refused")
        } catch is CleanerError {
            // expected
        }
        XCTAssertTrue(exists(".DS_Store"))
    }

    func testCancellationStopsTheRun() async throws {
        for i in 0..<50 { try plantFile("dir\(i)/.DS_Store") }
        let root = self.root!

        let task = Task.detached {
            try VolumeCleaner.cleanTree(root: root, rules: .all, dryRun: false) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let survivors = (0..<50).filter { exists("dir\($0)/.DS_Store") }
        XCTAssertFalse(survivors.isEmpty, "cancellation should stop before every directory was visited")
    }

    // MARK: Full Disk Access

    /// The TCC denial itself cannot be provoked in a test (it depends on the host's Full Disk Access
    /// state and on a Spotlight-created index), so only the mapping is tested.
    func testFullDiskAccessDenialMapping() throws {
        XCTAssertTrue(VolumeCleaner.isFullDiskAccessDenial(code: EPERM, name: ".Spotlight-V100", isTopLevel: true))
        XCTAssertTrue(VolumeCleaner.isFullDiskAccessDenial(code: EPERM, name: "._.Spotlight-V100", isTopLevel: true))
        XCTAssertFalse(VolumeCleaner.isFullDiskAccessDenial(code: EPERM, name: ".Spotlight-V100", isTopLevel: false))
        XCTAssertFalse(VolumeCleaner.isFullDiskAccessDenial(code: EACCES, name: ".Spotlight-V100", isTopLevel: true))
        XCTAssertFalse(VolumeCleaner.isFullDiskAccessDenial(code: EPERM, name: ".Trashes", isTopLevel: true))
        XCTAssertFalse(VolumeCleaner.isFullDiskAccessDenial(code: EPERM, name: "._x", isTopLevel: true))

        var report = CleanReport(dryRun: false)
        report.recordFullDiskAccessDenial(root.appendingPathComponent(".Spotlight-V100"))
        report.recordFailure(root.appendingPathComponent(".Trashes"), NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)))
        XCTAssertTrue(report.needsFullDiskAccess)
        XCTAssertEqual(report.failures.map(\.needsFullDiskAccess), [true, false])
        XCTAssertEqual(report.failures.first?.message, "Needs Full Disk Access (System Settings > Privacy & Security)")
        XCTAssertFalse(try clean().needsFullDiskAccess)
    }

    // MARK: VolumeInfo

    func testVolumeInfoContainingTemporaryDirectoryIsTheStartupVolume() throws {
        let info = try XCTUnwrap(VolumeInfo.containing(root))
        XCTAssertTrue(info.isRootFileSystem)
        XCTAssertFalse(info.isExternalCandidate)
        XCTAssertFalse(VolumeInfo.mountedExternal().contains(where: \.isRootFileSystem))
        XCTAssertFalse(VolumeInfo.mountedExternal().contains(where: { $0.url.path.hasPrefix("/System/") }))
    }
}
