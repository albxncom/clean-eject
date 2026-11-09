import Foundation
import os

public enum ArchiveCleaner {
    /// Removes macOS metadata junk entries from a ZIP archive in place. Runs off the main actor.
    ///
    /// Entries are listed with `unzip` and deleted with `zip -d`, both shipped with macOS; what counts as
    /// junk is `HiddenFileRules.shouldRemove(archiveEntry:)`. Removed entries are reported as
    /// `archive.appendingPathComponent(entryName)` with their uncompressed size, or 0 bytes when the
    /// listing cannot be parsed reliably. If zip fails, every entry it should have removed is reported as
    /// a failure with zip's message; the call itself throws only when the archive is refused or unreadable.
    /// zip writes a new file, so the archive's extended attributes (quarantine, tags, where-from) are
    /// read before and written back after.
    ///
    /// - Parameters:
    ///   - archive: a regular, writable file with a `.zip` extension (any case) in a writable folder;
    ///     anything else throws `CleanerError`.
    ///   - rules: which entries to remove; prevention and the AppleDouble merge do not apply.
    ///   - dryRun: list the junk entries without changing the archive.
    @concurrent
    public static func clean(archive: URL, rules: HiddenFileRules, dryRun: Bool = false) async throws -> CleanReport {
        try checkArchive(archive)

        var report = CleanReport(dryRun: dryRun)
        let entries = try await listEntries(of: archive)
        guard entries.contains(where: rules.shouldRemove(archiveEntry:)) else { return report }
        let sizes = try await uncompressedSizes(of: entries, in: archive)
        var candidates: [(name: String, bytes: Int64, rule: HiddenFileRules.Rule)] = []
        for (name, bytes) in zip(entries, sizes) {
            guard let rule = rules.rule(forArchiveEntry: name) else { continue }
            if isAddressable(name) {
                candidates.append((name, bytes, rule))
            } else {
                report.recordFailure(archive.appendingPathComponent(name), message: unaddressableMessage)
            }
        }
        let ambiguous = namesMatchingOtherEntries(candidates.map(\.name), entries: entries)
        for name in ambiguous {
            report.recordFailure(archive.appendingPathComponent(name), message: wildcardMessage)
        }
        candidates.removeAll { ambiguous.contains($0.name) }
        if dryRun {
            for candidate in candidates {
                report.recordRemoval(archive.appendingPathComponent(candidate.name), bytes: candidate.bytes, rule: candidate.rule)
            }
            return report
        }
        guard !candidates.isEmpty else { return report }
        guard let attributes = extendedAttributes(of: archive) else {
            let message = "Not removed: the archive's extended attributes cannot be read, and zip would lose them."
            for candidate in candidates {
                report.recordFailure(archive.appendingPathComponent(candidate.name), message: message)
            }
            return report
        }

        // -nw turns off "*" and "[", but zip still reads "?" as a wildcard; namesMatchingOtherEntries kept
        // out every name where that could reach an entry that stays. -@: names come from standard input,
        // one per line, so neither ARG_MAX nor a name starting with "-" is a concern.
        let names = candidates.map(\.name).joined(separator: "\n") + "\n"
        let result = try await Subprocess.run("/usr/bin/zip", ["-d", "-nw", archive.path, "-@"], input: Data(names.utf8))
        for (name, value) in attributes {
            if let reason = ExtendedAttributes.set(name, value, on: archive.path) {
                report.recordFailure(archive, message: "Could not restore the archive's extended attribute \(name): \(reason)")
            }
        }
        guard result.status == 0 || result.status == 12 else {
            let message = zipMessage(result)
            for candidate in candidates {
                report.recordFailure(archive.appendingPathComponent(candidate.name), message: message)
            }
            return report
        }
        // 12 is "nothing to do". Either way the listing, not zip's word, says what is gone: zip skips a
        // name it cannot match (unzip prints control characters escaped, for one) with only a warning.
        let remaining = Set(try await listEntries(of: archive))
        let removing = Set(candidates.map(\.name))
        var checked: Set<String> = []
        for name in entries where !removing.contains(name) && checked.insert(name).inserted && !remaining.contains(name) {
            log.fault("zip removed \(name, privacy: .public) from \(archive.path, privacy: .public), which is not junk")
            report.recordFailure(archive.appendingPathComponent(name), message: "zip removed this entry although it is not junk.")
        }
        for candidate in candidates {
            let url = archive.appendingPathComponent(candidate.name)
            if remaining.contains(candidate.name) {
                report.recordFailure(url, message: "zip did not remove this entry.")
            } else {
                report.recordRemoval(url, bytes: candidate.bytes, rule: candidate.rule)
            }
        }
        return report
    }

    /// Why `clean(archive:)` refuses `archive`, or nil when it may be cleaned, so the app can refuse early.
    public static func archiveRefusal(_ archive: URL) -> CleanerError? {
        do {
            try checkArchive(archive)
            return nil
        } catch {
            return error
        }
    }

    /// Refuses anything but a regular `.zip` file that zip can rewrite. zip writes a temporary copy next
    /// to the archive and renames it over the original, so the folder must be writable too.
    private static func checkArchive(_ archive: URL) throws(CleanerError) {
        var info = stat()
        guard lstat(archive.path, &info) == 0 else { throw .unreadable(archive) }
        guard info.st_mode & S_IFMT == S_IFREG, archive.pathExtension.lowercased() == "zip" else {
            throw .notAZipArchive(archive)
        }
        guard access(archive.path, W_OK) == 0, access(archive.deletingLastPathComponent().path, W_OK) == 0 else {
            throw .notWritable(archive)
        }
    }

    /// Entry names in archive order, from `unzip -Z1`. The archive is handed over as standard input and
    /// named /dev/stdin, because unzip treats `*`, `?`, `[` and `\` in an archive's file name as a
    /// pattern and would list every matching archive in the folder.
    private static func listEntries(of archive: URL) async throws -> [String] {
        let listing = try await unzip(["-Z1", "/dev/stdin"], archive: archive)
        return listing.split(separator: "\n").map(String.init)
    }

    /// Uncompressed sizes in the order of `entries`, from zipinfo's short listing (`unzip -Z -s`), whose
    /// lines read `-rw-r--r--  3.0 unx  2802 tx defX 24-Oct-30 13:48 name`. Every line is checked
    /// against the name `unzip -Z1` gave; if any does not line up, every size is 0.
    private static func uncompressedSizes(of entries: [String], in archive: URL) async throws -> [Int64] {
        let unknown = [Int64](repeating: 0, count: entries.count)
        let listing = try await unzip(["-Z", "-s", "/dev/stdin"], archive: archive)
        var lines = listing.split(separator: "\n")[...]
        var sizes: [Int64] = []
        for entry in entries {
            guard let size = nextSize(of: entry, in: &lines) else { return unknown }
            sizes.append(size)
        }
        return sizes
    }

    private static func nextSize(of entry: String, in lines: inout ArraySlice<Substring>) -> Int64? {
        let name = Array(entry.utf8)
        while let line = lines.popFirst() {
            let bytes = Array(line.utf8)
            guard bytes.count > name.count, bytes.suffix(name.count).elementsEqual(name) else { continue }
            let prefix = String(decoding: bytes.dropLast(name.count), as: UTF8.self)
            let fields = prefix.split(separator: " ")
            if prefix.hasSuffix(" "), fields.count == 8, let size = Int64(fields[3]) { return size }
        }
        return nil
    }

    /// Exit 1 is a warning and still lists everything; an empty archive prints "Empty zipfile." that way.
    private static func unzip(_ arguments: [String], archive: URL) async throws -> String {
        let descriptor = open(archive.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CleanerError.unreadable(archive) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let result = try await Subprocess.run("/usr/bin/unzip", arguments, standardInput: handle)
        guard result.status == 0 || result.status == 1 else { throw CleanerError.unreadableArchive(archive) }
        return result.output
    }

    private static let log = Logger(subsystem: "com.albxn.CleanEject", category: "ArchiveCleaner")

    /// The archive's extended attributes but its provenance, which zip's new file gets anyway; nil if
    /// they cannot be read.
    private static func extendedAttributes(of archive: URL) -> [(name: String, value: [UInt8])]? {
        guard let names = ExtendedAttributes.names(of: archive.path) else { return nil }
        var attributes: [(name: String, value: [UInt8])] = []
        for name in names where name != ExtendedAttributes.provenance {
            guard let value = ExtendedAttributes.value(name, of: archive.path) else { return nil }
            attributes.append((name, value))
        }
        return attributes
    }

    static let wildcardMessage = "Not removed: the name contains a wildcard character that would match other entries."

    /// The candidate names zip must not get: zip -d reads "?" in a name as a wildcard even with -nw, and
    /// it matches across "/", so `a/._x?y` would also delete `a/._x/y`. A name counts when its wildcard
    /// reading could match an entry that stays, which includes a name refused here, hence the loop.
    static func namesMatchingOtherEntries(_ candidates: [String], entries: [String]) -> Set<String> {
        let wildcards = candidates.filter { $0.contains(where: { "?*[".contains($0) }) }
        var refused: Set<String> = []
        while true {
            let removing = Set(candidates).subtracting(refused)
            let staying = entries.filter { !removing.contains($0) }
            let newlyRefused = wildcards.filter { name in
                !refused.contains(name) && staying.contains { wildcardMatches(name, $0) }
            }
            if newlyRefused.isEmpty { return refused }
            refused.formUnion(newlyRefused)
        }
    }

    /// Whether `pattern` read as a wildcard could match `name`, generously, so it covers zip's matcher:
    /// "?" is one character (one to four bytes), "*" any run of bytes, "[...]" one character or the
    /// literal text, all across "/". Everything else, a backslash included, matches itself.
    static func wildcardMatches(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.utf8)
        let s = Array(name.utf8)
        var memo: [Int: Bool] = [:]
        func match(_ i: Int, _ j: Int) -> Bool {
            if i == p.count { return j == s.count }
            let key = i * (s.count + 1) + j
            if let known = memo[key] { return known }
            let oneCharacter = (1...4).map { j + $0 }.filter { $0 <= s.count }
            var result: Bool
            switch p[i] {
            case UInt8(ascii: "*"):
                result = (j...s.count).contains { match(i + 1, $0) }
            case UInt8(ascii: "?"):
                result = oneCharacter.contains { match(i + 1, $0) }
            default:
                result = j < s.count && s[j] == p[i] && match(i + 1, j + 1)
                if !result && p[i] == UInt8(ascii: "[") {
                    // Any later "]" may close the class, depending on how the matcher reads "[]...]".
                    let closings = p.indices.filter { $0 > i && p[$0] == UInt8(ascii: "]") }
                    result = closings.contains { close in oneCharacter.contains { match(close + 1, $0) } }
                }
            }
            memo[key] = result
            return result
        }
        return match(0, 0)
    }

    /// Whether `zip -d` can be trusted to delete exactly this entry. zip strips a leading "/" or "./"
    /// before matching, looks a name up on disk first if it exists there (relative to /var/empty, so only
    /// an absolute name or one climbing out with ".." can), and drops a carriage return read from -@.
    static func isAddressable(_ name: String) -> Bool {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        let significant = name.hasSuffix("/") ? components.dropLast() : components[...]
        return !significant.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static let unaddressableMessage = "Not removed: zip cannot address this entry name exactly."

    private static func zipMessage(_ result: Subprocess.Result) -> String {
        let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "zip failed with exit status \(result.status)." : message
    }
}
