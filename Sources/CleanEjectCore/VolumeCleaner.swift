import Foundation

/// Outcome of one cleaning run. Removed items are reported as absolute URLs; a removed directory counts once.
/// For a ZIP archive every removed entry counts, as `archive.appendingPathComponent(entryName)`.
public struct CleanReport: Sendable {
    public struct Failure: Sendable {
        public let url: URL
        public let message: String
        /// macOS refused the Spotlight index for lack of Full Disk Access; `message` says so.
        public let needsFullDiskAccess: Bool
    }

    /// One removed item (or, in a dry run, one that would be removed) and the rule it matched.
    public struct Removal: Sendable {
        public let url: URL
        public let bytes: Int64
        public let rule: HiddenFileRules.Rule
        /// An AppleDouble sidecar whose data was merged into its file before removal.
        public let merged: Bool
    }

    public let dryRun: Bool
    public private(set) var removals: [Removal] = []
    public private(set) var failures: [Failure] = []

    public var removed: [URL] { removals.map(\.url) }
    public var removedCount: Int { removals.count }
    public var removedBytes: Int64 { removals.reduce(0) { $0 + $1.bytes } }
    /// AppleDouble sidecars whose data was merged into their file before removal; a subset of `removed`.
    public var merged: [URL] { removals.filter(\.merged).map(\.url) }
    public var needsFullDiskAccess: Bool { failures.contains(where: \.needsFullDiskAccess) }

    init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    mutating func recordRemoval(_ url: URL, bytes: Int64, rule: HiddenFileRules.Rule, merged: Bool = false) {
        removals.append(Removal(url: url, bytes: bytes, rule: rule, merged: merged))
    }

    mutating func recordFailure(_ url: URL, _ error: any Error) {
        recordFailure(url, message: error.localizedDescription)
    }

    mutating func recordFailure(_ url: URL, message: String) {
        failures.append(Failure(url: url, message: message, needsFullDiskAccess: false))
    }

    mutating func recordFullDiskAccessDenial(_ url: URL) {
        failures.append(Failure(url: url, message: VolumeCleaner.fullDiskAccessMessage, needsFullDiskAccess: true))
    }
}

public enum CleanerError: LocalizedError, Equatable {
    case rootFileSystem(URL)
    case internalVolume(URL)
    case notAVolumeRoot(URL)
    case unreadable(URL)
    case notAFolder(URL)
    case symbolicLink(URL)
    case volumeRoot(URL)
    case protectedFolder(URL)
    case notAZipArchive(URL)
    case notWritable(URL)
    case unreadableArchive(URL)

    public var errorDescription: String? {
        switch self {
        case .rootFileSystem: "The startup volume is never cleaned."
        case .internalVolume: "Fixed internal volumes are never cleaned."
        case .notAVolumeRoot(let url): "\(url.path) is not the root of a mounted volume."
        case .unreadable(let url): "\(url.path) cannot be read."
        case .notAFolder(let url): "\(url.path) is not a folder."
        case .symbolicLink(let url): "\(url.path) is a symbolic link, and links are never followed."
        case .volumeRoot(let url): "\(url.path) is the root of a volume. Clean it as a volume instead."
        case .protectedFolder(let url): "\(url.path) is a system location and is never cleaned."
        case .notAZipArchive(let url): "\(url.path) is not a ZIP archive."
        case .notWritable(let url): "\(url.path) cannot be changed because it or its folder is read-only."
        case .unreadableArchive(let url): "\(url.path) is damaged or not a ZIP archive."
        }
    }
}

public enum VolumeCleaner {
    /// Removes macOS metadata junk from one mounted volume. Runs off the main actor.
    ///
    /// - Parameters:
    ///   - volumeRoot: mount point of the volume. Anything else throws `CleanerError`; the startup volume
    ///     and internal volumes are always refused.
    ///   - rules: which items to remove.
    ///   - dryRun: collect candidates and sizes without deleting or writing anything.
    ///   - progress: called with each directory as it is entered.
    @concurrent
    public static func clean(
        volumeRoot: URL,
        rules: HiddenFileRules,
        dryRun: Bool = false,
        progress: (@Sendable (URL) -> Void)? = nil
    ) async throws -> CleanReport {
        let root = volumeRoot.resolvingSymlinksInPath().standardizedFileURL
        guard root.path != "/" else { throw CleanerError.rootFileSystem(root) }
        guard let volume = VolumeInfo(url: root) else { throw CleanerError.unreadable(root) }
        if let refusal = volume.refusal { throw refusal }
        guard volume.url.path == root.path else { throw CleanerError.notAVolumeRoot(root) }
        return try cleanTree(root: root, rules: rules, dryRun: dryRun, progress: progress)
    }

    /// Removes macOS metadata junk from one ordinary folder and everything below it. Runs off the main actor.
    ///
    /// Only the per-folder rules apply (`HiddenFileRules.forFolders`): the folder's children are not the
    /// top level of a volume, so `.Trashes` and friends inside it survive and no prevention markers are
    /// written. Like a volume run it never follows symbolic links and never enters another volume.
    ///
    /// - Parameters:
    ///   - folder: a real directory. Symbolic links, volume roots (use `clean(volumeRoot:)`) and system
    ///     locations (`isProtectedFolder`) throw `CleanerError`.
    ///   - rules: which items to remove; the top-level rules and prevention are ignored.
    ///   - dryRun: collect candidates and sizes without deleting anything.
    ///   - progress: called with each directory as it is entered.
    @concurrent
    public static func clean(
        folder: URL,
        rules: HiddenFileRules,
        dryRun: Bool = false,
        progress: (@Sendable (URL) -> Void)? = nil
    ) async throws -> CleanReport {
        let root = try resolveFolder(folder)
        return try cleanTree(root: root, rules: rules.forFolders, dryRun: dryRun, progress: progress)
    }

    /// Why `clean(folder:)` refuses `folder`, or nil when it may be cleaned, so the app can refuse early.
    public static func folderRefusal(_ folder: URL) -> CleanerError? {
        do {
            _ = try resolveFolder(folder)
            return nil
        } catch {
            return error
        }
    }

    /// True for anything at or under /System, /Library, /usr, /private, /bin, /sbin, /etc, /var, /dev or
    /// /tmp. Compared on the symlink-resolved path, so /tmp/x (really /private/tmp/x) counts, and without
    /// regard to case, which APFS ignores by default.
    public static func isProtectedFolder(_ url: URL) -> Bool {
        let path = (realPath(url.path) ?? url.path).lowercased()
        return protectedLocations.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static let protectedLocations = ["/system", "/library", "/usr", "/private", "/bin", "/sbin", "/etc", "/var", "/dev", "/tmp"]

    /// The folder as the walk sees it: a real directory, every symbolic link in its path resolved.
    /// Not `standardizedFileURL`, which turns /private/tmp into the symbolic link /tmp.
    static func resolveFolder(_ folder: URL) throws(CleanerError) -> URL {
        let path = folder.path
        var info = stat()
        guard lstat(path, &info) == 0, let resolved = realPath(path) else { throw .unreadable(folder) }
        let root = URL(fileURLWithPath: resolved, isDirectory: true)
        if isProtectedFolder(root) { throw .protectedFolder(folder) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFLNK: throw .symbolicLink(folder)
        default: throw .notAFolder(folder)
        }
        guard let values = try? root.resourceValues(forKeys: [.isVolumeKey]) else { throw .unreadable(folder) }
        if values.isVolume == true { throw .volumeRoot(folder) }
        return root
    }

    /// realpath(3): absolute, every symbolic link and `..` resolved; nil if the path does not exist.
    /// Not `URL.resolvingSymlinksInPath()`, which strips a leading /private again.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingCString: resolved)
    }

    /// The engine without the volume checks, so unit tests can run it on a temporary directory.
    ///
    /// Walks with fts(3) instead of `FileManager.enumerator`, because Foundation hides AppleDouble
    /// (`._*`) files from every directory listing. `FTS_PHYSICAL` never follows symbolic links and
    /// `FTS_XDEV` never descends into another mounted volume. Deletion goes through unlink(2) and
    /// rmdir(2) with the bytes fts returned, not `FileManager`: Foundation re-normalises Unicode in
    /// file names and ExFAT does not, so a re-encoded name misses the file.
    ///
    /// With `mergeAppleDouble` on a volume that stores extended attributes natively, a `._name` sidecar
    /// next to a file or folder `name` is merged into it first (`mergeSidecar`) and kept when that fails.
    static func cleanTree(
        root: URL,
        rules: HiddenFileRules,
        dryRun: Bool,
        progress: (@Sendable (URL) -> Void)? = nil
    ) throws -> CleanReport {
        var report = CleanReport(dryRun: dryRun)
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let mergesSidecars = rules.mergeAppleDouble && rules.appleDouble && !dryRun && storesExtendedAttributesNatively(rootPath)

        try Task.checkCancellation()
        progress?(root)

        var pathArguments: [UnsafeMutablePointer<CChar>?] = [strdup(rootPath), nil]
        defer { free(pathArguments[0]) }
        guard let stream = fts_open(&pathArguments, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            throw CleanerError.unreadable(root)
        }
        defer { fts_close(stream) }

        var rootDevice: dev_t?
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            let rawPath = entry.pointee.fts_path!
            if entry.pointee.fts_level == FTS_ROOTLEVEL {
                switch info {
                case FTS_D: rootDevice = entry.pointee.fts_statp.pointee.st_dev
                case FTS_DP: break
                default: throw CleanerError.unreadable(root)
                }
                continue
            }
            let isDirectory = info == FTS_D
            let url = URL(fileURLWithFileSystemRepresentation: rawPath, isDirectory: isDirectory, relativeTo: nil)
            switch info {
            case FTS_D:
                try Task.checkCancellation()
                progress?(url)
                if entry.pointee.fts_statp.pointee.st_dev != rootDevice {
                    fts_set(stream, entry, FTS_SKIP)
                    continue
                }
            case FTS_F:
                break
            case FTS_DNR, FTS_ERR, FTS_NS:
                recordFailure(entry.pointee.fts_errno, url: url, name: name(of: entry), isTopLevel: entry.pointee.fts_level == 1, in: &report)
                continue
            default:
                // Post-order directory visits, symbolic links, sockets, devices, cycles: never candidates.
                continue
            }
            let isTopLevel = entry.pointee.fts_level == 1
            let name = name(of: entry)
            guard let rule = rules.rule(name: name, isDirectory: isDirectory, isRegularFile: !isDirectory, isTopLevel: isTopLevel) else {
                continue
            }
            // A Swift String keeps the exact bytes, but only if they are valid UTF-8; a repaired string would name a different file.
            guard let path = String(validatingCString: rawPath) else {
                report.recordFailure(url, posixError(EILSEQ))
                continue
            }
            // Defense in depth: never touch anything that does not sit inside the volume root.
            guard path.hasPrefix(rootPrefix) else { continue }
            if isDirectory { fts_set(stream, entry, FTS_SKIP) }

            let bytes = isDirectory ? directorySize(rawPath) : Int64(entry.pointee.fts_statp.pointee.st_size)
            if dryRun {
                report.recordRemoval(url, bytes: bytes, rule: rule)
                continue
            }
            // Only the AppleDouble rule matches a name starting with "._".
            var merges = false
            if mergesSidecars && !isDirectory && name.hasPrefix("._"),
               let native = mergeTarget(ofSidecar: path, name: name, isTopLevel: isTopLevel, rules: rules, device: rootDevice) {
                if let reason = mergeSidecar(path, into: native) {
                    report.recordFailure(url, message: "Could not merge \(name) into \(name.dropFirst(2)): \(reason)")
                    continue
                }
                merges = true
            }
            let kind = entry.pointee.fts_statp.pointee.st_mode & S_IFMT
            if let code = isDirectory ? removeTree(path) : removeEntry(path, kind: kind) {
                recordFailure(code, url: url, name: name, isTopLevel: isTopLevel, in: &report)
            } else {
                report.recordRemoval(url, bytes: bytes, rule: rule, merged: merges)
            }
        }
        if errno != 0 {
            report.recordFailure(root, posixError(errno))
        }
        if rules.preventRecreation && !dryRun {
            writeRecreationBlockers(root: root, report: &report)
        }
        return report
    }

    /// Whether the volume holding `path` stores extended attributes itself (APFS, HFS+). FAT and ExFAT
    /// do not: there macOS keeps them in the very `._` sidecars, so there is nothing to merge into.
    static func storesExtendedAttributesNatively(_ path: String) -> Bool {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        // The reply is a UInt32 length followed by the capabilities.
        var reply = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size + MemoryLayout<vol_capabilities_attr_t>.size)
        guard getattrlist(path, &request, &reply, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else { return false }
        let capabilities = reply.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: vol_capabilities_attr_t.self)
        }
        let interfaces = capabilities.capabilities.1 & capabilities.valid.1  // VOL_CAPABILITIES_INTERFACES
        return interfaces & UInt32(VOL_CAP_INT_EXTENDED_ATTR) != 0
    }

    /// What a sidecar at `path` (named `._name`, matched by the AppleDouble rule) merges into: `name` in
    /// the same directory, if that is a regular file or a folder on the walk's own device (not a volume
    /// mounted there) and not junk itself, since merging into what is about to go is pointless. nil
    /// means there is nothing to merge into, and the sidecar is removed as before.
    private static func mergeTarget(ofSidecar path: String, name: String, isTopLevel: Bool, rules: HiddenFileRules, device: dev_t?) -> String? {
        // The rule matched "._" as two whole characters, so the name proper starts at the third byte.
        let nativeName = String(name.dropFirst(2))
        guard nativeName != ".", nativeName != "..", let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return nil }
        let native = String(path[...slash]) + nativeName
        var info = stat()
        guard lstat(native, &info) == 0, info.st_dev == device else { return nil }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { return nil }
        let nativeIsJunk = rules.rule(name: nativeName, isDirectory: kind == S_IFDIR, isRegularFile: kind == S_IFREG, isTopLevel: isTopLevel) != nil
        return nativeIsJunk ? nil : native
    }

    /// Copies every extended attribute stored in `sidecar` that `native` (a file or folder) lacks onto
    /// `native`, the resource fork and Finder info included (as com.apple.ResourceFork and
    /// com.apple.FinderInfo); an attribute `native` already has keeps its own value. nil on success, else
    /// why not. The sidecar is unpacked into a fresh scratch file first, because copyfile(3) unpacking onto
    /// `native` itself would replace every attribute it has. Unpacking drops whatever the scratch file
    /// had except its provenance, so with that skipped only the sidecar's own attributes are copied.
    private static func mergeSidecar(_ sidecar: String, into native: String) -> String? {
        var template = Array((NSTemporaryDirectory() + "CleanEject-merge-XXXXXX").utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { return String(cString: strerror(errno)) }
        close(descriptor)
        let scratch = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        defer { unlink(scratch) }

        guard copyfile(sidecar, scratch, nil, copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_XATTR | COPYFILE_NOFOLLOW)) == 0 else {
            return "it is not a readable AppleDouble file"
        }
        guard let names = ExtendedAttributes.names(of: scratch) else { return ExtendedAttributes.errorMessage() }
        for name in names where name != ExtendedAttributes.provenance && !ExtendedAttributes.has(name, at: native) {
            guard let value = ExtendedAttributes.value(name, of: scratch) else { return "\(name): \(ExtendedAttributes.errorMessage())" }
            if name == XATTR_RESOURCEFORK_NAME && isEmptyResourceFork(value) { continue }
            if let reason = ExtendedAttributes.set(name, value, on: native, createOnly: true) { return "\(name): \(reason)" }
        }
        return nil
    }

    /// A resource fork without resources: the resource data length, bytes 8..<12 of the header, is 0.
    /// FAT and ExFAT put such a placeholder ("This resource fork intentionally left blank") into every
    /// sidecar; carrying it over would only add junk to the file.
    private static func isEmptyResourceFork(_ value: [UInt8]) -> Bool {
        value.count < 16 || value[8..<12].allSatisfy { $0 == 0 }
    }

    static let fullDiskAccessMessage = "Needs Full Disk Access (System Settings > Privacy & Security)"

    /// macOS keeps `.Spotlight-V100` on every volume behind Full Disk Access (TCC); without it, opening
    /// or removing the directory and its `._` sidecar fails with EPERM. Every other EPERM stays generic.
    static func isFullDiskAccessDenial(code: Int32, name: String, isTopLevel: Bool) -> Bool {
        code == EPERM && isTopLevel && (name == ".Spotlight-V100" || name == "._.Spotlight-V100")
    }

    private static func recordFailure(_ code: Int32, url: URL, name: String, isTopLevel: Bool, in report: inout CleanReport) {
        if isFullDiskAccessDenial(code: code, name: name, isTopLevel: isTopLevel) {
            report.recordFullDiskAccessDenial(url)
        } else {
            report.recordFailure(url, posixError(code))
        }
    }

    private static func name(of entry: UnsafeMutablePointer<FTSENT>) -> String {
        withUnsafePointer(to: &entry.pointee.fts_name) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
    }

    /// unlink(2), or rmdir(2) when `kind` is `S_IFDIR`, on exactly this path; nil on success, else the errno.
    ///
    /// Tried with the bytes fts listed, then once more with the precomposed (NFC) form of the same
    /// path, provided lstat finds the same kind of item there: the ExFAT driver lists every name
    /// decomposed, but deletion accepts only the stored bytes, which are NFC for files written by
    /// cameras or Windows (lookups accept both forms). The rules match on ASCII, so the equivalent name
    /// is a match as well. ENOENT counts as success only when lstat confirms the item is gone, as on
    /// FAT/ExFAT, where the kernel drops a `._` sidecar together with its data file.
    private static func removeEntry(_ path: String, kind: mode_t) -> Int32? {
        let call: (String) -> Int32 = kind == S_IFDIR ? { rmdir($0) } : { unlink($0) }
        if call(path) == 0 { return nil }
        let code = errno
        guard code == ENOENT else { return code }
        let precomposed = path.precomposedStringWithCanonicalMapping
        if !precomposed.utf8.elementsEqual(path.utf8), fileType(precomposed) == kind, call(precomposed) == 0 { return nil }
        return exists(path) ? ENOENT : nil
    }

    /// Removes a directory tree post-order through `removeEntry`; nil on success, else the first errno.
    /// Not removefile(3): it deletes with the listed bytes and fails on every NFC name (see above).
    /// Symbolic links inside are unlinked as links, and a volume mounted inside is neither entered
    /// (FTS_XDEV) nor removable, so its rmdir fails and is reported.
    private static func removeTree(_ directory: String) -> Int32? {
        var pathArguments: [UnsafeMutablePointer<CChar>?] = [strdup(directory), nil]
        defer { free(pathArguments[0]) }
        guard let stream = fts_open(&pathArguments, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return errno }
        defer { fts_close(stream) }
        var firstError: Int32?
        while let entry = fts_read(stream) {
            let failure: Int32?
            switch Int32(entry.pointee.fts_info) {
            case FTS_D: continue
            case FTS_DNR, FTS_ERR, FTS_NS: failure = entry.pointee.fts_errno
            default:
                guard let path = String(validatingCString: entry.pointee.fts_path) else {
                    failure = EILSEQ
                    break
                }
                failure = removeEntry(path, kind: entry.pointee.fts_statp.pointee.st_mode & S_IFMT)
            }
            if let failure, firstError == nil { firstError = failure }
        }
        return firstError
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func fileType(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private static func posixError(_ code: Int32) -> any Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }

    /// Sum of regular file sizes below `directory`, for the report only; symlinks and other volumes are not followed.
    private static func directorySize(_ directory: UnsafePointer<CChar>) -> Int64 {
        var pathArguments: [UnsafeMutablePointer<CChar>?] = [strdup(directory), nil]
        defer { free(pathArguments[0]) }
        guard let stream = fts_open(&pathArguments, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(stream) }
        var total: Int64 = 0
        while let entry = fts_read(stream) {
            if Int32(entry.pointee.fts_info) == FTS_F {
                total += Int64(entry.pointee.fts_statp.pointee.st_size)
            }
        }
        return total
    }

    /// `.metadata_never_index` keeps Spotlight away; `.fseventsd/no_log` stops the FSEvents journal.
    /// Nothing here follows a symbolic link: mkdir(2) and open(2) with `O_EXCL | O_NOFOLLOW` refuse
    /// links, and lstat(2) confirms the kinds before anything is written or unlinked.
    private static func writeRecreationBlockers(root: URL, report: inout CleanReport) {
        let fseventsd = root.appendingPathComponent(".fseventsd", isDirectory: true)
        var sidecars = [root.appendingPathComponent("._.metadata_never_index"), root.appendingPathComponent("._.fseventsd")]

        createMarker(root.appendingPathComponent(".metadata_never_index"), report: &report)

        if mkdir(fseventsd.path, 0o755) != 0 && errno != EEXIST {
            report.recordFailure(fseventsd, posixError(errno))
        } else if fileType(fseventsd.path) != S_IFDIR {
            report.recordFailure(fseventsd, posixError(ENOTDIR))
        } else {
            createMarker(fseventsd.appendingPathComponent("no_log"), report: &report)
            sidecars.append(fseventsd.appendingPathComponent("._no_log"))
        }

        // macOS tags everything this process creates with a com.apple.provenance xattr. On FAT/ExFAT
        // that xattr lives in a `._` sidecar, which is exactly the junk we just removed, so drop it again.
        for sidecar in sidecars where fileType(sidecar.path) == S_IFREG {
            unlink(sidecar.path)
        }
    }

    private static func createMarker(_ marker: URL, report: inout CleanReport) {
        let descriptor = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        if descriptor >= 0 {
            close(descriptor)
            return
        }
        let code = errno
        // An existing regular file already does the job; a symlink or anything else there is left alone.
        if code == EEXIST && fileType(marker.path) == S_IFREG { return }
        report.recordFailure(marker, posixError(code))
    }
}
