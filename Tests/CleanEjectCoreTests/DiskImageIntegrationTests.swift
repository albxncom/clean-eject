import XCTest
@testable import CleanEjectCore

/// Runs the real cleaner and ejector against throwaway ExFAT disk images. hdiutil needs no sudo for this.
final class DiskImageIntegrationTests: XCTestCase {
    private let fm = FileManager.default

    /// Creates and attaches a 20 MB ExFAT image; it is force-detached when the test ends, pass or fail.
    private func mountImage(at mountPoint: URL? = nil) throws -> URL {
        let image = try DiskImage.create(megabytes: 20)
        addTeardownBlock { image.detach() }
        try image.attach(at: mountPoint)
        return image.mountPoint!
    }

    /// Directory entries straight from readdir(3): Foundation hides `._*` AppleDouble files from its own listings.
    private func rawNames(in directory: URL) -> [String] {
        guard let stream = opendir(directory.path) else { return [] }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    private func plant(_ relativePaths: [String], under root: URL) throws {
        for path in relativePaths {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    func testCleansAndEjectsRealVolume() async throws {
        let volume = try mountImage()
        let planted = [".DS_Store", "sub/.DS_Store", "._x", ".Spotlight-V100/store", ".fseventsd/x", ".Trashes/x"]
        try plant(planted + ["keep.txt"], under: volume)

        let info = try XCTUnwrap(VolumeInfo.containing(volume.appendingPathComponent("keep.txt")))
        XCTAssertEqual(info.url, volume)
        XCTAssertNil(info.refusal, "a disk image is not internal")
        XCTAssertFalse(info.isInternal)
        XCTAssertTrue(info.formatDescription.localizedCaseInsensitiveContains("exfat"), info.formatDescription)
        XCTAssertFalse(info.isRootFileSystem)
        XCTAssertFalse(VolumeInfo.mountedExternal().contains(info), "a -nobrowse image is hidden and must not be listed")

        // Files written to ExFAT grow `._` sidecars (com.apple.provenance), so there is more junk than planted.
        XCTAssertTrue(rawNames(in: volume).contains("._keep.txt"), "\(rawNames(in: volume))")

        let report = try await VolumeCleaner.clean(volumeRoot: volume, rules: .all)

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(report.removedCount, 6)
        for path in planted {
            XCTAssertFalse(fm.fileExists(atPath: volume.appendingPathComponent(path).path), "\(path) should be gone")
        }
        XCTAssertEqual(rawNames(in: volume).filter { $0 != ".fseventsd" }, ["keep.txt", "sub"])
        XCTAssertEqual(rawNames(in: volume.appendingPathComponent("sub")), [])
        XCTAssertEqual(try Data(contentsOf: volume.appendingPathComponent("keep.txt")), Data("x".utf8))

        let prevention = try await VolumeCleaner.clean(volumeRoot: volume, rules: HiddenFileRules(preventRecreation: true))
        XCTAssertTrue(prevention.failures.isEmpty, prevention.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(rawNames(in: volume), [".fseventsd", ".metadata_never_index", "keep.txt", "sub"])
        XCTAssertTrue(rawNames(in: volume.appendingPathComponent(".fseventsd")).contains("no_log"))
        XCTAssertFalse(rawNames(in: volume.appendingPathComponent(".fseventsd")).contains { $0.hasPrefix("._") })

        try await VolumeEjector.eject(volume)

        let deadline = Date().addingTimeInterval(10)
        while fm.fileExists(atPath: volume.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertFalse(fm.fileExists(atPath: volume.path), "mount point should disappear after eject")
    }

    /// A volume mounted inside a junk folder: the folder's own files go, the mount point cannot be
    /// removed, the failure is reported and nothing on the nested volume is touched.
    func testJunkFolderContainingNestedVolumeIsReported() async throws {
        let outer = fm.temporaryDirectory.appendingPathComponent("CleanEjectNested-\(UUID().uuidString)", isDirectory: true)
        let inner = outer.appendingPathComponent(".Trashes/inner", isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outer) }
        _ = try mountImage(at: inner)
        try plant([".Trashes/junk", ".Trashes/inner/.DS_Store", ".Trashes/inner/keep.txt"], under: outer)

        let report = try VolumeCleaner.cleanTree(root: outer, rules: .all, dryRun: false)

        XCTAssertEqual(report.failures.map(\.url.lastPathComponent), [".Trashes"])
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertFalse(fm.fileExists(atPath: outer.appendingPathComponent(".Trashes/junk").path))
        XCTAssertTrue(fm.fileExists(atPath: inner.appendingPathComponent(".DS_Store").path), "nested volume must be left alone")
        XCTAssertTrue(fm.fileExists(atPath: inner.appendingPathComponent("keep.txt").path))
    }

    /// Writes a file with exactly these UTF-8 bytes through open(2); Foundation would re-normalise the name.
    private func createRaw(_ relativePath: String, under root: URL) throws {
        let descriptor = open(root.path + "/" + relativePath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        close(descriptor)
    }

    /// ExFAT keeps names as written and Foundation re-normalises Unicode on the way to the kernel, so
    /// deletion has to use the raw bytes fts returned. Before the fix these ran as 0 removed, 0 failures.
    func testRemovesSidecarsWithUnicodeNames() async throws {
        let volume = try mountImage()
        try fm.createDirectory(at: volume.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: volume.appendingPathComponent(".Trashes/501"), withIntermediateDirectories: true)
        try createRaw(".Trashes/501/caf\u{00E9}.txt", under: volume)
        let sidecars = [
            "._caf\u{00E9}",                    // NFC
            "._\u{00DC}n\u{00EF}code.txt",      // NFC
            "._na\u{0069}\u{0308}ve.txt",       // NFD
            "sub/._\u{00E9}t\u{00E9}.jpg",      // NFC, nested
        ]
        for name in sidecars { try createRaw(name, under: volume) }
        try createRaw("\u{00DC}bung.txt", under: volume)
        try plant(["keep.txt"], under: volume)
        // The kernel adds provenance sidecars for keep.txt, sub and the Unicode file on top of the planted ones.
        for name in sidecars.prefix(3) {
            XCTAssertTrue(rawNames(in: volume).contains(name), "\(name) should be planted: \(rawNames(in: volume))")
        }
        XCTAssertEqual(rawNames(in: volume.appendingPathComponent("sub")).count, 1)

        let report = try await VolumeCleaner.clean(volumeRoot: volume, rules: .all)

        XCTAssertTrue(report.failures.isEmpty, report.failures.map { "\($0.url.path): \($0.message)" }.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(report.removedCount, 5)
        XCTAssertTrue(report.removed.map(\.lastPathComponent).contains(".Trashes"), "a junk folder with an NFC child must be removed as a whole")
        XCTAssertEqual(Set(rawNames(in: volume).filter { $0 != ".fseventsd" }), ["keep.txt", "sub", "\u{00DC}bung.txt"])
        XCTAssertEqual(rawNames(in: volume.appendingPathComponent("sub")), [])
        XCTAssertEqual(try Data(contentsOf: volume.appendingPathComponent("keep.txt")), Data("x".utf8))
    }

    func testRefusesAnythingButTheVolumeRoot() async throws {
        let volume = try mountImage()
        try plant(["sub/.DS_Store"], under: volume)

        do {
            _ = try await VolumeCleaner.clean(volumeRoot: volume.appendingPathComponent("sub"), rules: .all)
            XCTFail("a subdirectory must be refused")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .notAVolumeRoot(volume.appendingPathComponent("sub")))
        }
        do {
            _ = try await VolumeCleaner.clean(volumeRoot: volume.appendingPathComponent("missing"), rules: .all)
            XCTFail("a missing directory must be refused")
        } catch is CleanerError {
            // expected
        }
        XCTAssertTrue(fm.fileExists(atPath: volume.appendingPathComponent("sub/.DS_Store").path))

        let report = try await VolumeCleaner.clean(volumeRoot: volume.appendingPathComponent("sub/.."), rules: .all, dryRun: true)
        let names = report.removed.map(\.lastPathComponent)
        XCTAssertTrue(names.contains(".DS_Store"), "the root reached through .. is still the root: \(names)")
        XCTAssertTrue(names.allSatisfy { $0 == ".DS_Store" || $0.hasPrefix("._") }, "\(names)")
        XCTAssertTrue(fm.fileExists(atPath: volume.appendingPathComponent("sub/.DS_Store").path), "dry run must not delete")
    }

    /// A volume mounted inside the tree being cleaned must be left alone. DiskArbitration refuses mount
    /// points on the ExFAT image itself, so the outer tree is a temporary directory and the engine is
    /// called directly.
    func testDoesNotDescendIntoNestedVolume() async throws {
        let outer = fm.temporaryDirectory.appendingPathComponent("CleanEjectNested-\(UUID().uuidString)", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outer) }
        let nested = try mountImage(at: inner)
        try plant([".DS_Store", "a/.DS_Store", "inner/.DS_Store", "inner/._y", "inner/.Trashes/x", "inner/deep/.DS_Store"], under: outer)
        XCTAssertEqual(nested.resolvingSymlinksInPath().path, inner.resolvingSymlinksInPath().path)

        let report = try VolumeCleaner.cleanTree(root: outer, rules: .all, dryRun: false)

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(report.removedCount, 2)
        XCTAssertFalse(fm.fileExists(atPath: outer.appendingPathComponent(".DS_Store").path))
        XCTAssertFalse(fm.fileExists(atPath: outer.appendingPathComponent("a/.DS_Store").path))
        for path in ["inner/.DS_Store", "inner/._y", "inner/.Trashes/x", "inner/deep/.DS_Store"] {
            XCTAssertTrue(fm.fileExists(atPath: outer.appendingPathComponent(path).path), "\(path) on the nested volume must survive")
        }
    }

    // MARK: Folder targets

    /// A folder on an external volume is a folder target: per-folder rules only, inside it and nowhere else.
    func testFolderTargetOnExternalVolume() async throws {
        let volume = try mountImage()
        try plant(["sub/.DS_Store", "sub/deeper/.DS_Store", "sub/.Trashes/x", "sub/keep.txt", ".DS_Store", ".Trashes/x"], under: volume)
        let sub = volume.appendingPathComponent("sub", isDirectory: true)
        XCTAssertTrue(rawNames(in: sub).contains("._keep.txt"), "ExFAT grows provenance sidecars: \(rawNames(in: sub))")

        let report = try await VolumeCleaner.clean(folder: sub, rules: .all)

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(rawNames(in: sub), [".Trashes", "deeper", "keep.txt"])
        XCTAssertEqual(rawNames(in: sub.appendingPathComponent(".Trashes")), ["x"], "a .Trashes inside a folder survives")
        XCTAssertEqual(rawNames(in: sub.appendingPathComponent("deeper")), [])
        XCTAssertTrue(Set(rawNames(in: volume)).isSuperset(of: [".DS_Store", ".Trashes"]), "nothing outside the folder is touched")

        do {
            _ = try await VolumeCleaner.clean(folder: volume, rules: .all)
            XCTFail("a volume root must be cleaned as a volume")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .volumeRoot(volume))
        }
        XCTAssertTrue(rawNames(in: volume).contains(".DS_Store"))
    }

    /// The same walk as for volumes: a volume mounted inside the folder is left alone, and with the merge
    /// on, the sidecar next to its mount point is not merged into the other volume's root.
    func testFolderTargetDoesNotEnterNestedVolume() async throws {
        let outer = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cleaneject-tests-\(UUID().uuidString)", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outer) }
        _ = try mountImage(at: inner)
        try plant([".DS_Store", "a/._x", "._inner", "inner/.DS_Store", "inner/._y", "inner/deep/.DS_Store"], under: outer)

        let report = try await VolumeCleaner.clean(folder: outer, rules: HiddenFileRules(mergeAppleDouble: true))

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(Set(report.removed.map(\.lastPathComponent)), [".DS_Store", "._x", "._inner"])
        XCTAssertTrue(report.merged.isEmpty)
        for path in ["inner/.DS_Store", "inner/._y", "inner/deep/.DS_Store"] {
            XCTAssertTrue(fm.fileExists(atPath: outer.appendingPathComponent(path).path), "\(path) on the nested volume must survive")
        }
    }

    // MARK: AppleDouble merge

    /// A folder under the home directory (APFS), removed again in teardown.
    private func homeFixture() throws -> URL {
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cleaneject-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func attribute(_ name: String, of url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &value, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: value, as: UTF8.self)
    }

    private func attributeNames(of url: URL) -> Set<String> {
        Set(ExtendedAttributes.names(of: url.path) ?? [])
    }

    private func rawExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// `xattr -w` on ExFAT stores the attribute in a `._file.txt` sidecar. The data file is copied with
    /// `cp -X` (no attributes) and the sidecar byte for byte into `folder`, as cp -X or rsync leave them.
    private func copySidecarFixture(from volume: URL, into folder: URL) throws {
        let file = volume.appendingPathComponent("file.txt")
        if !fm.fileExists(atPath: file.path) {
            try Data("data".utf8).write(to: file)
            try run("/usr/bin/xattr", ["-w", "com.example.k", "v", file.path])
        }
        XCTAssertTrue(rawNames(in: volume).contains("._file.txt"), "\(rawNames(in: volume))")
        try run("/bin/cp", ["-X", file.path, folder.appendingPathComponent("file.txt").path])
        try Data(contentsOf: volume.appendingPathComponent("._file.txt")).write(to: folder.appendingPathComponent("._file.txt"))
        XCTAssertNil(attribute("com.example.k", of: folder.appendingPathComponent("file.txt")), "cp -X must not carry the attribute")
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments)")
    }

    func testMergesSidecarIntoItsFile() async throws {
        let volume = try mountImage()
        let folder = try homeFixture()
        try copySidecarFixture(from: volume, into: folder)
        let file = folder.appendingPathComponent("file.txt")
        let sidecar = folder.appendingPathComponent("._file.txt")
        let rules = HiddenFileRules(mergeAppleDouble: true)
        XCTAssertTrue(VolumeCleaner.storesExtendedAttributesNatively(folder.path))
        let namesBefore = attributeNames(of: file)
        let provenanceBefore = attribute(ExtendedAttributes.provenance, of: file)

        let preview = try await VolumeCleaner.clean(folder: folder, rules: rules, dryRun: true)
        XCTAssertTrue(preview.merged.isEmpty, "a dry run merges nothing")
        XCTAssertTrue(rawExists(sidecar))
        XCTAssertNil(attribute("com.example.k", of: file))

        let report = try await VolumeCleaner.clean(folder: folder, rules: rules)

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(attribute("com.example.k", of: file), "v")
        XCTAssertNil(attribute(XATTR_RESOURCEFORK_NAME, of: file), "the placeholder resource fork is not carried over")
        XCTAssertEqual(attributeNames(of: file), namesBefore.union(["com.example.k"]), "only what the sidecar held is added")
        XCTAssertEqual(attribute(ExtendedAttributes.provenance, of: file), provenanceBefore, "the file's own provenance is untouched")
        XCTAssertFalse(rawExists(sidecar))
        XCTAssertEqual(report.merged.map(\.lastPathComponent), ["._file.txt"])
        XCTAssertEqual(report.removed.map(\.lastPathComponent), ["._file.txt"], "merged sidecars count as removed")
        XCTAssertEqual(try Data(contentsOf: file), Data("data".utf8))
    }

    /// A folder's AppleDouble data sits in `._Photos` next to it; it merges into the folder itself.
    func testMergesSidecarIntoAFolder() async throws {
        let volume = try mountImage()
        let photos = volume.appendingPathComponent("Photos", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try run("/usr/bin/xattr", ["-w", "com.example.k", "v", photos.path])
        XCTAssertTrue(rawNames(in: volume).contains("._Photos"), "\(rawNames(in: volume))")
        let folder = try homeFixture()
        let copy = folder.appendingPathComponent("Photos", isDirectory: true)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data(contentsOf: volume.appendingPathComponent("._Photos")).write(to: folder.appendingPathComponent("._Photos"))

        let report = try await VolumeCleaner.clean(folder: folder, rules: HiddenFileRules(mergeAppleDouble: true))

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(attribute("com.example.k", of: copy), "v")
        XCTAssertEqual(report.merged.map(\.lastPathComponent), ["._Photos"])
        XCTAssertFalse(rawExists(folder.appendingPathComponent("._Photos")))
    }

    func testMergeOffRemovesWithoutMerging() async throws {
        let volume = try mountImage()
        let folder = try homeFixture()
        try copySidecarFixture(from: volume, into: folder)

        let report = try await VolumeCleaner.clean(folder: folder, rules: .all)

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.removed.map(\.lastPathComponent), ["._file.txt"])
        XCTAssertTrue(report.merged.isEmpty)
        XCTAssertFalse(rawExists(folder.appendingPathComponent("._file.txt")))
        XCTAssertNil(attribute("com.example.k", of: folder.appendingPathComponent("file.txt")))
    }

    func testMergeKeepsTheFilesOwnValue() async throws {
        let volume = try mountImage()
        let folder = try homeFixture()
        try copySidecarFixture(from: volume, into: folder)
        let file = folder.appendingPathComponent("file.txt")
        try run("/usr/bin/xattr", ["-w", "com.example.k", "mine", file.path])

        let report = try await VolumeCleaner.clean(folder: folder, rules: HiddenFileRules(mergeAppleDouble: true))

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(attribute("com.example.k", of: file), "mine")
        XCTAssertFalse(rawExists(folder.appendingPathComponent("._file.txt")))
    }

    func testSidecarWithoutItsFileIsRemovedNotMerged() async throws {
        let volume = try mountImage()
        let folder = try homeFixture()
        try copySidecarFixture(from: volume, into: folder)
        try fm.removeItem(at: folder.appendingPathComponent("file.txt"))

        let report = try await VolumeCleaner.clean(folder: folder, rules: HiddenFileRules(mergeAppleDouble: true))

        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.removed.map(\.lastPathComponent), ["._file.txt"])
        XCTAssertTrue(report.merged.isEmpty)
        XCTAssertFalse(rawExists(folder.appendingPathComponent("._file.txt")))
    }

    /// On ExFAT the sidecar is where macOS keeps the attributes: nothing to merge into, removed as before.
    func testMergeIsANoOpOnExFAT() async throws {
        let volume = try mountImage()
        let file = volume.appendingPathComponent("file.txt")
        try Data("data".utf8).write(to: file)
        try run("/usr/bin/xattr", ["-w", "com.example.k", "v", file.path])
        XCTAssertTrue(rawNames(in: volume).contains("._file.txt"))
        XCTAssertFalse(VolumeCleaner.storesExtendedAttributesNatively(volume.path))

        let report = try await VolumeCleaner.clean(volumeRoot: volume, rules: HiddenFileRules(mergeAppleDouble: true))

        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(report.merged.isEmpty)
        XCTAssertTrue(report.removed.map(\.lastPathComponent).contains("._file.txt"))
        XCTAssertFalse(rawNames(in: volume).contains("._file.txt"))
        XCTAssertEqual(try Data(contentsOf: file), Data("data".utf8))
    }

    // MARK: Shared run path

    private func waitUntilGone(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(10)
        while fm.fileExists(atPath: url.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    func testRunCleansThenEjectsAVolume() async throws {
        let volume = try mountImage()
        try plant([".DS_Store", "sub/.DS_Store", ".Trashes/x", "keep.txt"], under: volume)
        let target = try CleanTarget.resolve(volume)
        XCTAssertEqual(target, .volume(volume))
        let ejectCalls = Counter()

        let result = try await TargetRunner.run(target, rules: .all, dryRun: false, ejectAfterwards: true, willEject: {
            XCTAssertTrue(FileManager.default.fileExists(atPath: volume.appendingPathComponent("keep.txt").path), "willEject runs before the eject")
            ejectCalls.increment()
        })

        XCTAssertEqual(result.eject, .ejected)
        XCTAssertEqual(ejectCalls.value, 1)
        XCTAssertTrue(result.report.failures.isEmpty, result.report.failures.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(Set(result.report.removed.map(\.lastPathComponent)).isSuperset(of: [".DS_Store", ".Trashes"]))
        try await waitUntilGone(volume)
        XCTAssertFalse(fm.fileExists(atPath: volume.path), "mount point should disappear after eject")
    }

    func testDryRunNeverEjects() async throws {
        let volume = try mountImage()
        try plant([".DS_Store"], under: volume)
        let ejectCalls = Counter()

        let result = try await TargetRunner.run(.volume(volume), rules: .all, dryRun: true, ejectAfterwards: true, willEject: { ejectCalls.increment() })

        XCTAssertNil(result.eject)
        XCTAssertEqual(ejectCalls.value, 0)
        XCTAssertTrue(result.report.removed.map(\.lastPathComponent).contains(".DS_Store"))
        XCTAssertTrue(fm.fileExists(atPath: volume.appendingPathComponent(".DS_Store").path))
    }

    /// An open file keeps the volume busy: the eject fails, the run does not throw and keeps its report.
    func testEjectFailureKeepsTheReport() async throws {
        let volume = try mountImage()
        try plant([".DS_Store", "open.txt"], under: volume)
        let handle = try FileHandle(forReadingFrom: volume.appendingPathComponent("open.txt"))
        defer { try? handle.close() }

        let result = try await TargetRunner.run(.volume(volume), rules: .all, dryRun: false, ejectAfterwards: true)

        guard case .failed(let message)? = result.eject else {
            return XCTFail("expected a failed eject, got \(String(describing: result.eject))")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(result.report.removed.map(\.lastPathComponent).contains(".DS_Store"))
        XCTAssertTrue(fm.fileExists(atPath: volume.appendingPathComponent("open.txt").path), "still mounted")
    }
}

/// One hdiutil disk image: created in the temporary directory, detached with -force on teardown.
private final class DiskImage: @unchecked Sendable {
    let dmg: URL
    let volumeName: String
    private(set) var device: String?
    private(set) var mountPoint: URL?

    private init(dmg: URL, volumeName: String) {
        self.dmg = dmg
        self.volumeName = volumeName
    }

    static func create(megabytes: Int) throws -> DiskImage {
        // ExFAT labels are limited to 11 characters.
        let volumeName = "CETEST-" + String(UUID().uuidString.prefix(4))
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("\(volumeName)-\(UUID().uuidString).dmg")
        _ = try DiskImage.shell("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(megabytes)m", "-fs", "ExFAT", "-volname", volumeName, dmg.path])
        return DiskImage(dmg: dmg, volumeName: volumeName)
    }

    func attach(at mountPoint: URL?) throws {
        var arguments = ["attach", "-nobrowse", "-plist", dmg.path]
        if let mountPoint { arguments += ["-mountpoint", mountPoint.path] }
        let output = try DiskImage.shell("/usr/bin/hdiutil", arguments)
        let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let mounted = entities.first(where: { $0["mount-point"] != nil }),
              let path = mounted["mount-point"] as? String,
              let device = mounted["dev-entry"] as? String
        else { throw NSError(domain: "DiskImage", code: 1, userInfo: [NSLocalizedDescriptionKey: "no mount point in hdiutil output"]) }
        self.device = device
        self.mountPoint = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    func detach() {
        if let device {
            _ = try? DiskImage.shell("/usr/bin/hdiutil", ["detach", "-force", "-quiet", device])
        }
        try? FileManager.default.removeItem(at: dmg)
    }

    @discardableResult
    private static func shell(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DiskImage", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed: \(String(decoding: errorOutput, as: UTF8.self))",
            ])
        }
        return output
    }
}
