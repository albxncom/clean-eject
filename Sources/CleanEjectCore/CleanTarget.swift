import Foundation

/// What a run acts on: a mounted volume, or a folder or ZIP archive named explicitly.
public enum CleanTarget: Hashable, Sendable {
    case volume(URL)
    case folder(URL)
    case archive(URL)

    public var url: URL {
        switch self {
        case .volume(let url), .folder(let url), .archive(let url): url
        }
    }

    public var isVolume: Bool {
        if case .volume = self { return true }
        return false
    }

    public var isArchive: Bool {
        if case .archive = self { return true }
        return false
    }

    /// Why an item cannot become a target: what it would have been, and the core's reason.
    public struct Refusal: Error, Sendable, Equatable {
        /// `item` when the path is neither a usable directory nor a regular file (missing, a symbolic link,
        /// a socket or device).
        public enum Subject: Sendable, Equatable {
            case volume, folder, archive, item
        }

        public let subject: Subject
        public let reason: CleanerError

        public var message: String { reason.localizedDescription }
    }

    /// Resolves a dropped, opened, service-provided or command-line item: the root of a volume is a
    /// volume target, any other directory a folder target, a `.zip` file an archive target, and any other
    /// file stands for the folder that contains it. Symbolic links, system locations and unwritable
    /// archives are refused with the core's reasons; nothing is removed here.
    public static func resolve(_ url: URL) throws(Refusal) -> CleanTarget {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw itemRefusal(url) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            if (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true {
                return try volumeTarget(url)
            }
            if let refusal = VolumeCleaner.folderRefusal(url) {
                throw Refusal(subject: .folder, reason: refusal)
            }
            return .folder(realURL(url, isDirectory: true))
        case S_IFREG:
            guard url.pathExtension.lowercased() == "zip" else {
                return try resolve(url.deletingLastPathComponent())
            }
            if let refusal = ArchiveCleaner.archiveRefusal(url) {
                throw Refusal(subject: .archive, reason: refusal)
            }
            return .archive(realURL(url, isDirectory: false))
        default:
            // A symbolic link, socket or device: the folder rules say why it is refused.
            throw itemRefusal(url)
        }
    }

    private static func volumeTarget(_ url: URL) throws(Refusal) -> CleanTarget {
        guard let info = VolumeInfo(url: url) else {
            throw Refusal(subject: .volume, reason: .unreadable(url))
        }
        if let refusal = info.refusal { throw Refusal(subject: .volume, reason: refusal) }
        return .volume(info.url)
    }

    private static func itemRefusal(_ url: URL) -> Refusal {
        Refusal(subject: .item, reason: VolumeCleaner.folderRefusal(url) ?? .unreadable(url))
    }

    /// The path as the cleaner reports it: realpath(3), every symbolic link resolved, so the report's
    /// absolute paths sit under the target's. Not `resolvingSymlinksInPath()`, which strips /private.
    private static func realURL(_ url: URL, isDirectory: Bool) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: isDirectory)
    }
}

extension VolumeInfo {
    public var target: CleanTarget { .volume(url) }
}
