import Foundation

/// Which macOS metadata items the cleaner removes. Every rule is independently toggleable.
///
/// Volumes get every rule. Folder targets get only the per-folder rules (see `forFolders`). ZIP archives
/// get the same rules with the archive root as the top level (see `rule(forArchiveEntry:)`).
public struct HiddenFileRules: Sendable, Equatable {
    /// The rule an item matched, so a report can be grouped by what was removed and why.
    public enum Rule: CaseIterable, Sendable, Hashable {
        case dsStore
        case appleDouble
        /// The top-level `__MACOSX` folder of a ZIP archive; governed by `appleDouble`.
        case macosxFolder
        case spotlight
        case fsevents
        case trashes
        case temporaryItems
        case apdisk
    }

    /// `.DS_Store` regular files at any depth.
    public var dsStore: Bool
    /// AppleDouble sidecars: regular files named `._<something>` (more than two characters) at any depth.
    /// In ZIP archives also the top-level `__MACOSX` folder, where Archive Utility stores them.
    public var appleDouble: Bool
    /// Before the AppleDouble rule removes a `._name` sidecar, copy the extended attributes it holds
    /// (resource fork and Finder info included) that the file or folder `name` lacks onto `name`; a
    /// sidecar that cannot be merged is kept and reported. Needs `appleDouble`, and works only on volumes that
    /// store extended attributes natively (APFS, HFS+); on FAT and ExFAT the sidecar is that storage and
    /// is removed as before. Applies to volumes and folders, never to archives.
    public var mergeAppleDouble: Bool
    /// Top-level `.Spotlight-V100` directory.
    public var spotlight: Bool
    /// Top-level `.fseventsd` directory.
    public var fsevents: Bool
    /// Top-level `.Trashes` directory.
    public var trashes: Bool
    /// Top-level `.TemporaryItems` directory.
    public var temporaryItems: Bool
    /// Top-level `.apdisk` regular file.
    public var apdisk: Bool
    /// After cleaning a volume, write `.metadata_never_index` and `.fseventsd/no_log` so macOS stops recreating the junk.
    public var preventRecreation: Bool

    public init(
        dsStore: Bool = true,
        appleDouble: Bool = true,
        mergeAppleDouble: Bool = false,
        spotlight: Bool = true,
        fsevents: Bool = true,
        trashes: Bool = true,
        temporaryItems: Bool = true,
        apdisk: Bool = true,
        preventRecreation: Bool = false
    ) {
        self.dsStore = dsStore
        self.appleDouble = appleDouble
        self.mergeAppleDouble = mergeAppleDouble
        self.spotlight = spotlight
        self.fsevents = fsevents
        self.trashes = trashes
        self.temporaryItems = temporaryItems
        self.apdisk = apdisk
        self.preventRecreation = preventRecreation
    }

    /// Every removal rule on; the AppleDouble merge and prevention off (the app's defaults).
    public static let all = HiddenFileRules()

    /// Nothing is removed or merged. Useful as a base for enabling a single rule.
    public static let none = HiddenFileRules(
        dsStore: false, appleDouble: false, mergeAppleDouble: false, spotlight: false, fsevents: false,
        trashes: false, temporaryItems: false, apdisk: false, preventRecreation: false
    )

    public var removesAnything: Bool {
        dsStore || appleDouble || spotlight || fsevents || trashes || temporaryItems || apdisk
    }

    /// The rules a folder target gets: `.DS_Store`, AppleDouble and the merge. A folder's children are not
    /// the top level of a volume, so the top-level rules and prevention are off, and a `.Trashes` folder
    /// inside a user folder survives.
    public var forFolders: HiddenFileRules {
        var rules = HiddenFileRules.none
        rules.dsStore = dsStore
        rules.appleDouble = appleDouble
        rules.mergeAppleDouble = mergeAppleDouble
        return rules
    }

    /// Decides whether a directory entry is junk under these rules. Symbolic links never match:
    /// a regular-file rule needs `isRegularFile`, a directory rule needs `isDirectory`, and the
    /// enumerator reports both as false for links.
    public func shouldRemove(name: String, isDirectory: Bool, isRegularFile: Bool, isTopLevel: Bool) -> Bool {
        rule(name: name, isDirectory: isDirectory, isRegularFile: isRegularFile, isTopLevel: isTopLevel) != nil
    }

    /// The active rule a directory entry matches, or nil when it is not junk; see `shouldRemove(name:...)`.
    public func rule(name: String, isDirectory: Bool, isRegularFile: Bool, isTopLevel: Bool) -> Rule? {
        if isRegularFile {
            if dsStore && name == ".DS_Store" { return .dsStore }
            if appleDouble && name.hasPrefix("._") && name.count > 2 { return .appleDouble }
            if apdisk && isTopLevel && name == ".apdisk" { return .apdisk }
            return nil
        }
        if isDirectory && isTopLevel {
            switch name {
            case ".Spotlight-V100": return spotlight ? .spotlight : nil
            case ".fseventsd": return fsevents ? .fsevents : nil
            case ".Trashes": return trashes ? .trashes : nil
            case ".TemporaryItems": return temporaryItems ? .temporaryItems : nil
            default: return nil
            }
        }
        return nil
    }

    /// Decides whether a ZIP archive entry is junk; `entry` is the name as `unzip -Z1` lists it, directory
    /// entries ending in `/`. Mirrors `shouldRemove(name:...)` with the archive root as the top level: a
    /// top-level folder rule takes the folder's entry and everything under it, and `__MACOSX` counts as
    /// AppleDouble. A file entry never matches a folder rule, nor a directory entry a file rule.
    public func shouldRemove(archiveEntry entry: String) -> Bool {
        rule(forArchiveEntry: entry) != nil
    }

    /// The active rule a ZIP archive entry matches, or nil when it is not junk; see `shouldRemove(archiveEntry:)`.
    public func rule(forArchiveEntry entry: String) -> Rule? {
        let isDirectory = entry.hasSuffix("/")
        let components = entry.dropLast(isDirectory ? 1 : 0).split(separator: "/", omittingEmptySubsequences: false)
        guard let first = components.first, let last = components.last else { return nil }
        if isDirectory || components.count > 1 {
            if first == "__MACOSX" {
                if appleDouble { return .macosxFolder }
            } else if let folderRule = rule(name: String(first), isDirectory: true, isRegularFile: false, isTopLevel: true) {
                return folderRule
            }
        }
        guard !isDirectory else { return nil }
        return rule(name: String(last), isDirectory: false, isRegularFile: true, isTopLevel: components.count == 1)
    }
}

/// Stable machine names for the rules, shared by the command-line flags and its JSON `rule` field.
extension HiddenFileRules.Rule {
    /// The rules with their own delete toggle, in rule order: every rule but `macosxFolder`, which the
    /// AppleDouble toggle governs.
    public static var toggleable: [Self] { allCases.filter { $0 != .macosxFolder } }

    public var machineName: String {
        switch self {
        case .dsStore: "ds-store"
        case .appleDouble: "appledouble"
        case .macosxFolder: "macosx-folder"
        case .spotlight: "spotlight"
        case .fsevents: "fseventsd"
        case .trashes: "trashes"
        case .temporaryItems: "temporary-items"
        case .apdisk: "apdisk"
        }
    }

    /// The rule with this machine name, `macosx-folder` included; nil for an unknown name.
    public init?(machineName: String) {
        guard let rule = Self.allCases.first(where: { $0.machineName == machineName }) else { return nil }
        self = rule
    }

    /// The `HiddenFileRules` delete toggle that governs this rule.
    public var toggle: WritableKeyPath<HiddenFileRules, Bool> {
        switch self {
        case .dsStore: \.dsStore
        case .appleDouble, .macosxFolder: \.appleDouble
        case .spotlight: \.spotlight
        case .fsevents: \.fsevents
        case .trashes: \.trashes
        case .temporaryItems: \.temporaryItems
        case .apdisk: \.apdisk
        }
    }
}
