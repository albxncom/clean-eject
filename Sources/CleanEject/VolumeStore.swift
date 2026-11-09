import AppKit
import CleanEjectCore
import Observation

/// Volume list, mount notifications, the folders and archives added explicitly, the sidebar selection
/// and the per-target scan and run state for the UI. Every action (window, menu, menu bar extra, service)
/// goes through here.
@MainActor @Observable
final class VolumeStore {
    private(set) var volumes: [VolumeInfo] = []
    /// Folders and ZIP archives from drops, Open… and the Finder service, in that order. Gone again
    /// when their path vanishes or the user removes them from the list.
    private(set) var added: [CleanTarget] = []
    var hasTargets: Bool { !volumes.isEmpty || !added.isEmpty }
    private(set) var runs: [CleanTarget: RunState] = [:]
    /// The sidebar selection. Set through `select(_:)`: a new selection dismisses `departedRun` and is scanned.
    private(set) var selection: CleanTarget?
    /// The run that ejected the selected volume; the detail keeps showing it until the user selects
    /// something else or a new volume mounts.
    private(set) var departedRun: LastRun?
    var alert: AlertInfo?
    /// Set by the main window's content while it is on screen. Only then is the selection scanned;
    /// results of runs that finish while the window is closed go out as notifications instead.
    var isWindowOpen = false {
        didSet { if isWindowOpen != oldValue { updateScan() } }
    }
    /// Opens the main window scene; installed by its content, used by the menu bar extra and the
    /// Finder service after the window was closed.
    var openMainWindow: (@MainActor () -> Void)?

    private struct ScanJob {
        let target: CleanTarget
        let rules: HiddenFileRules
        let id: UUID
        let task: Task<Void, Never>
    }

    private let defaults: UserDefaults
    /// The rules last read from `defaults`, to tell a rule change from any other defaults write.
    private var currentRules: HiddenFileRules
    /// Dropped volumes that the automatic filter would not list (e.g. network shares). Explicit user intent.
    private var pinned: Set<URL> = []
    /// Real runs (clean, eject), one per target.
    private var tasks: [CleanTarget: Task<Void, Never>] = [:]
    /// The one scan, always of the selected target. A scan that was stopped or replaced finishes
    /// without writing anything because its id no longer matches.
    private var scan: ScanJob?
    private var observers: [any NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        currentRules = HiddenFileRules.fromUserDefaults(defaults)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // A folder or archive deleted or moved in Finder drops off the list when the app comes to the front.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // Settings > Rules writes through @AppStorage; window frames and other settings land here too.
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rulesMayHaveChanged() }
        })
        refresh()
    }

    /// The selection while it is listed; nil once its volume is gone or its path vanished.
    var selectedTarget: CleanTarget? {
        guard let selection, isListed(selection) else { return nil }
        return selection
    }

    var selectedVolume: VolumeInfo? {
        guard case .volume(let url)? = selectedTarget else { return nil }
        return volume(at: url)
    }

    func volume(at url: URL) -> VolumeInfo? {
        volumes.first { $0.url == url }
    }

    func name(of target: CleanTarget) -> String {
        switch target {
        case .volume(let url): volume(at: url)?.name ?? url.lastPathComponent
        case .folder(let url), .archive(let url): url.lastPathComponent
        }
    }

    func isBusy(_ target: CleanTarget) -> Bool {
        runs[target]?.isBusy == true
    }

    /// Selects `target` and scans it afresh: its findings may be stale by now, and a stopped or failed
    /// target is retried. A finished run's result stays until Scan Again. A scan of the previous
    /// selection stops. Every call is a selection by the user, so the sidebar calls it only on a change.
    func select(_ target: CleanTarget?) {
        selection = target
        if let target {
            departedRun = nil
            switch runs[target] {
            case .scanned?, .stopped?, .failed?: runs[target] = nil
            default: break
            }
        }
        updateScan()
    }

    /// "Remove from List" for a folder or archive; a volume stays listed as long as it is mounted.
    func removeFromList(_ target: CleanTarget) {
        guard !target.isVolume else { return }
        cancelScan(of: target)
        tasks[target]?.cancel()
        added.removeAll { $0 == target }
        runs[target] = nil
        if selection == target { selection = nil }
    }

    /// Re-reads the mounted volumes and drops added folders and archives whose paths are gone. The
    /// selection survives; a newly mounted volume is selected when nothing is, and replaces a departed
    /// run's result in the detail.
    func refresh() {
        var list = VolumeInfo.mountedExternal()
        for url in pinned where !list.contains(where: { $0.url == url }) {
            if let info = VolumeInfo(url: url), info.refusal == nil {
                list.append(info)
            } else {
                pinned.remove(url)
            }
        }
        let known = Set(volumes.map(\.url))
        volumes = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        added = added.filter { tasks[$0] != nil || Self.exists($0) }
        runs = runs.filter { target, _ in isListed(target) }
        if let selection, !isListed(selection), tasks[selection] == nil {
            self.selection = nil
        }
        if let mounted = volumes.first(where: { !known.contains($0.url) }) {
            departedRun = nil
            if selection == nil { selection = mounted.target }
        }
        updateScan()
    }

    /// Resolves dropped, opened or service-provided items to targets (see `CleanTarget.resolve`), lists
    /// them and selects the last one. Refusals show as an alert.
    func add(droppedURLs urls: [URL]) {
        var lastAdded: CleanTarget?
        for url in urls {
            let target: CleanTarget
            do {
                target = try CleanTarget.resolve(url)
            } catch {
                alert = AlertInfo(title: error.title, message: error.message)
                continue
            }
            switch target {
            case .volume(let volumeURL):
                pinned.insert(volumeURL)
            case .folder, .archive:
                if !added.contains(target) { added.append(target) }
            }
            lastAdded = target
        }
        refresh()
        if let lastAdded { select(lastAdded) }
    }

    /// Cleans `target` and, for a volume with `ejectAfterwards`, ejects it. With findings on screen the
    /// run uses their rules, otherwise the current ones; a running scan of `target` stops first.
    func clean(_ target: CleanTarget, ejectAfterwards: Bool = false) {
        guard tasks[target] == nil, !isBusy(target) else { return }
        let rules: HiddenFileRules
        if case .scanned(let findings)? = runs[target] {
            rules = findings.rules
        } else {
            rules = HiddenFileRules.fromUserDefaults(defaults)
        }
        let stoppedScan = cancelScan(of: target)
        run(target, rules: rules, ejectAfterwards: ejectAfterwards, after: stoppedScan)
    }

    func eject(_ volume: VolumeInfo) {
        let target = volume.target
        guard tasks[target] == nil, !isBusy(target) else { return }
        let stoppedScan = cancelScan(of: target)
        let before = runs[target]
        runs[target] = .ejecting
        tasks[target] = Task {
            defer { tasks[target] = nil; updateScan() }
            await stoppedScan?.value
            do {
                try await VolumeEjector.eject(volume.url)
                runs[target] = nil
                finish(LastRun(name: volume.name, items: nil, ejected: true), departed: target)
            } catch {
                runs[target] = before
                presentFailure(title: "Could Not Eject \(volume.name)", message: error.localizedDescription)
            }
            refresh()
        }
    }

    /// Scan Again: drops the findings or result of the selected target and scans it afresh.
    func scanAgain() {
        guard let target = selectedTarget, !isBusy(target) else { return }
        cancelScan(of: target)
        runs[target] = nil
        updateScan()
    }

    /// Stops the scan of `target` (Stop) or its clean (Cancel); an eject cannot be stopped. A stopped
    /// scan stays stopped until Scan Again or until the user selects the target again.
    func cancel(_ target: CleanTarget) {
        if scan?.target == target {
            cancelScan(of: target)
            runs[target] = .stopped
        } else {
            tasks[target]?.cancel()
        }
    }

    // MARK: Scanning

    /// Keeps the one scan in line with the window and the selection: stops a scan of anything but the
    /// selected target, and scans the selected target while the window is open and it has no state yet
    /// (a stopped scan is a state: refreshes and finished runs do not restart it).
    private func updateScan() {
        let wanted = isWindowOpen ? selectedTarget : nil
        if let scan, scan.target != wanted { cancelScan(of: scan.target) }
        guard let target = wanted, scan == nil, tasks[target] == nil, runs[target] == nil else { return }
        startScan(target)
    }

    private func startScan(_ target: CleanTarget) {
        let rules = HiddenFileRules.fromUserDefaults(defaults)
        let id = UUID()
        runs[target] = .scanning(currentPath: target.url.path)
        let task = Task {
            let outcome: Result<CleanReport, any Error>
            do {
                outcome = .success(try await TargetRunner.run(target, rules: rules, dryRun: true, progress: progress(for: target)).report)
            } catch {
                outcome = .failure(error)
            }
            guard scan?.id == id else { return }
            scan = nil
            switch outcome {
            case .success(let report):
                runs[target] = .scanned(Findings(target: target, rules: rules, items: ReportItems(report, root: target.url)))
            case .failure(let error) where error is CancellationError:
                runs[target] = nil
            case .failure(let error):
                runs[target] = .failed(error.localizedDescription)
            }
        }
        scan = ScanJob(target: target, rules: rules, id: id, task: task)
    }

    /// Stops the scan of `target`, if one runs, and returns its task so a run can wait for it to wind
    /// down. The target's state goes back to none.
    @discardableResult
    private func cancelScan(of target: CleanTarget) -> Task<Void, Never>? {
        guard let scan, scan.target == target else { return nil }
        scan.task.cancel()
        self.scan = nil
        if case .scanning? = runs[target] { runs[target] = nil }
        return scan.task
    }

    /// Findings and results computed with other rules are dropped and the selected target rescans, so
    /// what is shown is what gets removed.
    private func rulesMayHaveChanged() {
        let rules = HiddenFileRules.fromUserDefaults(defaults)
        guard rules != currentRules else { return }
        currentRules = rules
        for (target, state) in runs {
            switch state {
            case .scanned(let findings) where findings.rules != rules: runs[target] = nil
            case .finished: runs[target] = nil
            default: break
            }
        }
        if let scan, scan.rules != rules { cancelScan(of: scan.target) }
        updateScan()
    }

    // MARK: Running

    /// `after` is a scan that was just stopped; the run starts once it has wound down. Afterwards the
    /// target keeps its result; a target left without state (a failed eject) is scanned again.
    private func run(_ target: CleanTarget, rules: HiddenFileRules, ejectAfterwards: Bool, after stoppedScan: Task<Void, Never>?) {
        let name = name(of: target)
        runs[target] = .cleaning(currentPath: target.url.path)
        tasks[target] = Task {
            defer { tasks[target] = nil; updateScan() }
            await stoppedScan?.value
            let result: RunResult
            do {
                result = try await TargetRunner.run(
                    target, rules: rules, dryRun: false, ejectAfterwards: ejectAfterwards,
                    progress: progress(for: target),
                    willEject: { @MainActor in self.runs[target] = .ejecting }
                )
            } catch is CancellationError {
                runs[target] = .failed("Cancelled.")
                notifyIfWindowClosed(title: "Cancelled cleaning \(name)", body: "Nothing more was removed.")
                return
            } catch {
                runs[target] = .failed(error.localizedDescription)
                notifyIfWindowClosed(title: "Could Not Clean \(name)", body: error.localizedDescription)
                return
            }
            let items = ReportItems(result.report, root: target.url)
            switch result.eject {
            case nil:
                let cleaned = LastRun(name: name, items: items, ejected: false)
                runs[target] = .finished(cleaned)
                finish(cleaned, departed: nil)
            case .ejected:
                runs[target] = nil
                finish(LastRun(name: name, items: items, ejected: true), departed: target)
            case .failed(let message):
                // The result must say the volume is still mounted; a plain "Cleaned" invites pulling the card.
                let stillMounted = LastRun(name: name, items: items, ejected: false, ejectError: message)
                runs[target] = .finished(stillMounted)
                finish(stillMounted, departed: nil)
                if isWindowOpen { alert = AlertInfo(title: "Could Not Eject \(name)", message: message) }
            }
            refresh()
        }
    }

    /// Directory progress for a scan or run of `target`, landing in `runs`.
    private func progress(for target: CleanTarget) -> @Sendable (URL) -> Void {
        { directory in
            Task { @MainActor in self.updateProgress(target, path: directory.path) }
        }
    }

    /// Keeps the run in the detail when it ejected the selected volume (the unmount notification may
    /// have refreshed the list already, so this compares targets, not list entries); notifies when
    /// nobody is looking at the window.
    private func finish(_ run: LastRun, departed: CleanTarget?) {
        if let departed, selection == departed {
            departedRun = run
            selection = nil
        }
        notifyIfWindowClosed(title: run.headline, body: run.detail)
    }

    /// A failure outside a run's result: an alert while the window is open, a notification otherwise
    /// (an alert set now would only surface, stale, when the window reopens).
    private func presentFailure(title: String, message: String) {
        if isWindowOpen {
            alert = AlertInfo(title: title, message: message)
        } else {
            RunNotifier.post(title: title, body: message)
        }
    }

    /// Runs started from the menu bar have no window to show their outcome in.
    private func notifyIfWindowClosed(title: String, body: String?) {
        if !isWindowOpen {
            RunNotifier.post(title: title, body: body)
        }
    }

    private func updateProgress(_ target: CleanTarget, path: String) {
        switch runs[target] {
        case .cleaning: runs[target] = .cleaning(currentPath: path)
        case .scanning: runs[target] = .scanning(currentPath: path)
        default: break
        }
    }

    private func isListed(_ target: CleanTarget) -> Bool {
        switch target {
        case .volume(let url): volume(at: url) != nil
        case .folder, .archive: added.contains(target)
        }
    }

    /// lstat(2) on the exact path: a folder must still be a directory, an archive a regular file.
    private static func exists(_ target: CleanTarget) -> Bool {
        var info = stat()
        guard lstat(target.url.path, &info) == 0 else { return false }
        switch target {
        case .volume: return true
        case .folder: return info.st_mode & S_IFMT == S_IFDIR
        case .archive: return info.st_mode & S_IFMT == S_IFREG
        }
    }
}
