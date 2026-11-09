import Foundation

/// A mounted volume as the app shows it.
public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let formatDescription: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isInternal: Bool
    public let isLocal: Bool
    public let isReadOnly: Bool
    public let isBrowsable: Bool
    public let isRootFileSystem: Bool

    public var id: URL { url }
    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    /// Why the cleaner refuses this volume however it was selected, or nil when it may be cleaned:
    /// the startup volume, anything under /System/Volumes, and fixed internal disks. A card in the
    /// built-in reader is internal too, but removable, and is accepted. Internal APFS volumes never
    /// carry `._*` files, and removing `.Spotlight-V100` there would wipe a live Spotlight index.
    public var refusal: CleanerError? {
        if isRootFileSystem { return .rootFileSystem(url) }
        if url.path.hasPrefix("/System/Volumes/") || (isInternal && !isRemovable && !isEjectable) {
            return .internalVolume(url)
        }
        return nil
    }

    /// Browsable local volumes that look like external media: not refused, not read-only, not under
    /// /System, and removable, ejectable or at least not internal. Network shares are left out.
    public static func mountedExternal() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap(VolumeInfo.init).filter(\.isExternalCandidate)
    }

    /// Hidden (`nobrowse`) volumes are excluded here as well as by `.skipHiddenVolumes` above: the Time
    /// Machine backup volume is writable, removable and ejectable and stays off the list only by being hidden.
    var isExternalCandidate: Bool {
        refusal == nil && isBrowsable && isLocal && !isReadOnly && !url.path.hasPrefix("/System/")
            && (isRemovable || isEjectable || !isInternal)
    }

    private static let keys: Set<URLResourceKey> = [
        .volumeURLKey, .volumeNameKey, .volumeLocalizedNameKey, .volumeLocalizedFormatDescriptionKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
    ]
}

// The initializer lives in an extension so the synthesized memberwise initializer stays available to tests.
extension VolumeInfo {
    /// Reads the volume that `url` is on; nil if the resource values cannot be read.
    public init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Self.keys), let volumeURL = values.volume else { return nil }
        self.init(
            url: volumeURL.standardizedFileURL,
            name: values.volumeLocalizedName ?? values.volumeName ?? volumeURL.lastPathComponent,
            formatDescription: values.volumeLocalizedFormatDescription ?? "Unknown format",
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            // Disk images report no value here; unknown is not internal.
            isInternal: values.volumeIsInternal ?? false,
            isLocal: values.volumeIsLocal ?? false,
            isReadOnly: values.volumeIsReadOnly ?? false,
            isBrowsable: values.volumeIsBrowsable ?? true,
            isRootFileSystem: values.volumeIsRootFileSystem ?? false
        )
    }

    /// The volume containing `url`, e.g. for a dropped file.
    public static func containing(_ url: URL) -> VolumeInfo? {
        VolumeInfo(url: url)
    }
}
