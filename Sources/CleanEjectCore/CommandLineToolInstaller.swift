import Foundation

/// Puts the bundled `cleaneject` on PATH as a symbolic link, by default `~/.local/bin/cleaneject`.
///
/// Only a link that points at a CleanEject helper (`…/CleanEject.app/Contents/Helpers/cleaneject`) is
/// ever replaced or removed; a file, folder or any other link at that path blocks installing.
public struct CommandLineToolInstaller: Sendable {
    public enum State: Sendable, Equatable {
        case notInstalled
        /// The link points at this bundle's helper.
        case installed
        /// The link points at another CleanEject bundle's helper (the destination path); Install replaces it.
        case linkedElsewhere(String)
        /// Something else is at the link path; it is never overwritten.
        case blocked(String)
    }

    public enum Failure: LocalizedError, Sendable, Equatable {
        case noHelper
        case blocked(String)
        case system(String)

        public var errorDescription: String? {
            switch self {
            case .noHelper: Self.noHelperMessage
            case .blocked(let reason): reason
            case .system(let message): message
            }
        }

        static let noHelperMessage = "This copy of CleanEject has no bundled command line tool. Build it with make."
    }

    public static let helperSuffix = "/CleanEject.app/Contents/Helpers/cleaneject"

    /// Where the link goes.
    public let linkURL: URL
    /// The helper to link to; nil when the running bundle has none (e.g. `swift run`).
    public let helperURL: URL?

    public init(linkURL: URL, helperURL: URL?) {
        self.linkURL = linkURL
        self.helperURL = helperURL
    }

    /// `~/.local/bin/cleaneject` pointing at `<bundle>/Contents/Helpers/cleaneject`, when that is executable.
    public init(bundle: Bundle = .main, linkDirectory: URL? = nil) {
        let directory = linkDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/cleaneject")
        self.init(
            linkURL: directory.appendingPathComponent("cleaneject"),
            helperURL: FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
        )
    }

    /// Why Install is unavailable regardless of the link, or nil.
    public var unavailableReason: String? {
        helperURL == nil ? Failure.noHelperMessage : nil
    }

    public func state() -> State {
        let path = linkURL.path
        var info = stat()
        guard lstat(path, &info) == 0 else { return .notInstalled }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            break
        case S_IFDIR:
            return .blocked("\(path) is a folder.")
        default:
            return .blocked("\(path) is a file, not a link to CleanEject's tool.")
        }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return .blocked("\(path) cannot be read.")
        }
        let absolute = destination.hasPrefix("/")
            ? destination
            : linkURL.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path
        if let helperURL, Self.samePath(absolute, helperURL.path) { return .installed }
        if absolute.hasSuffix(Self.helperSuffix) { return .linkedElsewhere(absolute) }
        return .blocked("\(path) links to \(destination), which is not CleanEject's tool.")
    }

    /// Links the helper; replaces only a link to another CleanEject helper. Creates the link's folder if needed.
    public func install() throws(Failure) {
        guard let helperURL else { throw .noHelper }
        switch state() {
        case .installed:
            return
        case .blocked(let reason):
            throw .blocked(reason)
        case .linkedElsewhere:
            try removeLink()
        case .notInstalled:
            break
        }
        do {
            try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .system(error.localizedDescription)
        }
        guard symlink(helperURL.path, linkURL.path) == 0 else {
            throw .system("\(linkURL.path) cannot be created: \(String(cString: strerror(errno))).")
        }
    }

    /// Removes the link when it points at a CleanEject helper; anything else is left alone.
    public func remove() throws(Failure) {
        switch state() {
        case .notInstalled:
            return
        case .blocked(let reason):
            throw .blocked(reason)
        case .installed, .linkedElsewhere:
            try removeLink()
        }
    }

    private func removeLink() throws(Failure) {
        guard unlink(linkURL.path) == 0 || errno == ENOENT else {
            throw .system("\(linkURL.path) cannot be removed: \(String(cString: strerror(errno))).")
        }
    }

    /// Equal as written or after realpath(3), so a bundle reached through a symbolic link still counts.
    private static func samePath(_ a: String, _ b: String) -> Bool {
        a == b || (realPath(a).map { $0 == realPath(b) } ?? false)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
