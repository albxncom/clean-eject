import Foundation

/// The outcome of one `TargetRunner.run`: the cleaner's report, and the eject when one was attempted.
public struct RunResult: Sendable {
    public enum Eject: Sendable, Equatable {
        case ejected
        /// The system's message; the volume is still mounted.
        case failed(String)
    }

    public let target: CleanTarget
    public let report: CleanReport
    /// Nil when no eject was attempted: not asked for, a dry run, or a folder or archive target.
    public let eject: Eject?
}

/// The one run path shared by the app and the command-line tool.
public enum TargetRunner {
    /// Cleans (or dry-runs) a resolved target and then, when `ejectAfterwards` is set, the run is real and
    /// the target is a volume, ejects it. Runs off the main actor.
    ///
    /// Throws what the cleaner throws (a refusal, an unreadable target, `CancellationError`); nothing is
    /// ejected then. An eject failure does not throw: the report is kept and the failure is in `eject`.
    ///
    /// - Parameters:
    ///   - progress: called with each directory as it is entered (volumes and folders only).
    ///   - willEject: awaited after cleaning, right before the eject starts.
    @concurrent
    public static func run(
        _ target: CleanTarget,
        rules: HiddenFileRules,
        dryRun: Bool,
        ejectAfterwards: Bool = false,
        progress: (@Sendable (URL) -> Void)? = nil,
        willEject: (@Sendable () async -> Void)? = nil
    ) async throws -> RunResult {
        let report: CleanReport
        switch target {
        case .volume(let url):
            report = try await VolumeCleaner.clean(volumeRoot: url, rules: rules, dryRun: dryRun, progress: progress)
        case .folder(let url):
            report = try await VolumeCleaner.clean(folder: url, rules: rules, dryRun: dryRun, progress: progress)
        case .archive(let url):
            report = try await ArchiveCleaner.clean(archive: url, rules: rules, dryRun: dryRun)
        }
        guard ejectAfterwards, !dryRun, case .volume(let url) = target else {
            return RunResult(target: target, report: report, eject: nil)
        }
        await willEject?()
        do {
            try await VolumeEjector.eject(url)
            return RunResult(target: target, report: report, eject: .ejected)
        } catch {
            return RunResult(target: target, report: report, eject: .failed(error.localizedDescription))
        }
    }
}
