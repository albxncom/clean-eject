import CleanEjectCore
import Foundation

/// Where the tool writes: results on `out`, errors and hints on `err`. Tests capture both.
struct Console {
    var out: (String) -> Void
    var err: (String) -> Void
    /// Progress lines ("Cleaning …") are written only to a terminal.
    var errIsTerminal: Bool
}

enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
}

/// Runs a parsed command against the real file system and reports in text or JSON. On the main actor;
/// the core does the file system work off it.
@MainActor
struct Runner {
    let console: Console

    func run(arguments: [String]) async -> Int32 {
        let command: Command
        do {
            command = try Command.parse(arguments)
        } catch {
            return usage(error)
        }
        switch command {
        case .help:
            console.out(Help.text)
            return ExitCode.ok
        case .list(let json):
            return list(json: json)
        case .run(let options):
            return await clean(options)
        case .eject(let paths, let json):
            return await eject(paths, json: json)
        }
    }

    func usage(_ error: UsageError) -> Int32 {
        console.err("cleaneject: \(error.message)\nRun 'cleaneject --help' for usage.\n")
        return ExitCode.usage
    }

    // MARK: list

    private func list(json: Bool) -> Int32 {
        let volumes = VolumeInfo.mountedExternal()
        if json {
            printJSON(["volumes": volumes.map { volume -> [String: Any] in
                ["name": volume.name, "path": volume.url.path, "refusal": volume.refusal.map(\.localizedDescription) ?? NSNull()]
            }])
        } else if volumes.isEmpty {
            console.err("No external volumes are mounted.\n")
        } else {
            for volume in volumes {
                let refusal = volume.refusal.map { " (refused: \($0.localizedDescription))" } ?? ""
                console.out("\(volume.name)\t\(volume.url.path)\(refusal)\n")
            }
        }
        return ExitCode.ok
    }

    // MARK: preview and clean

    private func clean(_ options: RunOptions) async -> Int32 {
        let resolved = resolve(options.paths)
        if options.eject, let folder = resolved.targets.first(where: { !$0.target.isVolume }) {
            return usage(UsageError("--eject works only on volumes; \(folder.target.url.path) is \(kind(of: folder.target))"))
        }
        guard resolved.refusals.isEmpty else { return report(refusals: resolved.refusals, json: options.json) }

        var results: [RunResult] = []
        var errors: [Refused] = []
        for (index, item) in resolved.targets.enumerated() {
            let target = item.target
            if console.errIsTerminal && !options.json {
                console.err("\(options.dryRun ? "Scanning" : "Cleaning") \(target.url.path)…\n")
            }
            do {
                let result = try await TargetRunner.run(target, rules: options.rules, dryRun: options.dryRun, ejectAfterwards: options.eject)
                results.append(result)
                if !options.json { printText(result, verbose: options.verbose, separated: index > 0) }
            } catch {
                // Refused at run time (the item changed since it was resolved) or unreadable.
                let refused = Refused(item.path, message: error.localizedDescription)
                errors.append(refused)
                if !options.json { console.err("cleaneject: \(refused.path): \(refused.message)\n") }
            }
        }
        if results.contains(where: \.report.needsFullDiskAccess) { console.err(Self.fullDiskAccessHint) }
        if options.json {
            printJSON(["results": results.map(json), "refusals": errors.map(\.json)])
        }
        let failed = !errors.isEmpty || results.contains { !$0.report.failures.isEmpty || $0.eject?.isFailure == true }
        return failed ? ExitCode.failure : ExitCode.ok
    }

    static let fullDiskAccessHint = """
        Hint: macOS protects Spotlight indexes. Give your terminal app Full Disk Access in System Settings > \
        Privacy & Security > Full Disk Access, restart it, and run the command again.

        """

    private func printText(_ result: RunResult, verbose: Bool, separated: Bool) {
        let items = ReportItems(result.report, root: result.target.url)
        let path = result.target.url.path
        var lines: [String] = separated ? [""] : []
        if items.count == 0 {
            lines.append("\(path): nothing to remove")
        } else {
            lines.append("\(path): \(result.report.dryRun ? "would remove" : "removed") \(items.summary)")
            let width = items.groups.map(\.rule.machineName.count).max() ?? 0
            for group in items.groups {
                let size = ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file)
                let count = group.count == 1 ? "1 item" : "\(group.count) items"
                lines.append("  " + group.rule.machineName.padding(toLength: width + 2, withPad: " ", startingAt: 0) + "\(count), \(size)")
                if verbose { lines += group.entries.map { "      \($0.path)" } }
            }
        }
        if let merged = items.mergedSummary { lines.append(merged) }
        if result.eject == .ejected { lines.append("Ejected \(path)") }
        console.out(lines.joined(separator: "\n") + "\n")

        if let failures = items.failureSummary {
            console.err("cleaneject: \(path): \(failures):\n" + items.failureLines.map { "  \($0)\n" }.joined())
        }
        if case .failed(let message) = result.eject {
            console.err("cleaneject: \(path) could not be ejected: \(message)\n")
        }
    }

    private func json(_ result: RunResult) -> [String: Any] {
        let report = result.report
        return [
            "path": result.target.url.path,
            "kind": kind(of: result.target),
            "dryRun": report.dryRun,
            "removedCount": report.removedCount,
            "removedBytes": report.removedBytes,
            "removals": report.removals.map {
                ["path": $0.url.path, "rule": $0.rule.machineName, "bytes": $0.bytes, "merged": $0.merged] as [String: Any]
            },
            "failures": report.failures.map {
                ["path": $0.url.path, "message": $0.message, "needsFullDiskAccess": $0.needsFullDiskAccess] as [String: Any]
            },
            "eject": result.eject.map(\.json) ?? NSNull(),
        ]
    }

    // MARK: eject

    private func eject(_ paths: [String], json: Bool) async -> Int32 {
        let resolved = resolve(paths)
        if let folder = resolved.targets.first(where: { !$0.target.isVolume }) {
            return usage(UsageError("eject works only on volumes; \(folder.target.url.path) is \(kind(of: folder.target))"))
        }
        guard resolved.refusals.isEmpty else { return report(refusals: resolved.refusals, json: json) }

        var results: [[String: Any]] = []
        var failed = false
        for item in resolved.targets {
            let path = item.target.url.path
            let outcome: RunResult.Eject
            do {
                try await VolumeEjector.eject(item.target.url)
                outcome = .ejected
                if !json { console.out("Ejected \(path)\n") }
            } catch {
                outcome = .failed(error.localizedDescription)
                failed = true
                if !json { console.err("cleaneject: \(path) could not be ejected: \(error.localizedDescription)\n") }
            }
            results.append(["path": path, "kind": kind(of: item.target), "eject": outcome.json])
        }
        if json { printJSON(["results": results, "refusals": [Any]()]) }
        return failed ? ExitCode.failure : ExitCode.ok
    }

    // MARK: shared

    private struct Resolved {
        var targets: [(path: String, target: CleanTarget)] = []
        var refusals: [Refused] = []
    }

    private struct Refused {
        /// As typed, for the text output.
        let path: String
        let message: String

        init(_ path: String, message: String) {
            self.path = path
            self.message = message
        }

        /// Absolute against the working directory but not resolved: the refusal may be about a symbolic link.
        var json: [String: Any] { ["path": URL(fileURLWithPath: path).path, "message": message] }
    }

    /// Resolves every path the way the app resolves a drop, before anything runs.
    private func resolve(_ paths: [String]) -> Resolved {
        var resolved = Resolved()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                resolved.targets.append((path, try CleanTarget.resolve(url)))
            } catch {
                resolved.refusals.append(Refused(path, message: error.message))
            }
        }
        return resolved
    }

    /// Every refusal, nothing run: exit 1.
    private func report(refusals: [Refused], json: Bool) -> Int32 {
        if json {
            printJSON(["results": [Any](), "refusals": refusals.map(\.json)])
        } else {
            for refusal in refusals { console.err("cleaneject: \(refusal.path): \(refusal.message)\n") }
            console.err("cleaneject: nothing was changed.\n")
        }
        return ExitCode.failure
    }

    private func kind(of target: CleanTarget) -> String {
        switch target {
        case .volume: "volume"
        case .folder: "folder"
        case .archive: "archive"
        }
    }

    private func printJSON(_ object: [String: Any]) {
        // Only strings, numbers, booleans, arrays, dictionaries and NSNull go in, so this cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        console.out(String(decoding: data, as: UTF8.self) + "\n")
    }
}

extension RunResult.Eject {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var json: [String: Any] {
        switch self {
        case .ejected: ["ejected": true, "error": NSNull()]
        case .failed(let message): ["ejected": false, "error": message]
        }
    }
}
