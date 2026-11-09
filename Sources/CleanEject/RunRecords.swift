import CleanEjectCore
import Foundation

/// What the store keeps about a target for the UI: its scan and findings, a run while it runs, and the finished run.
extension VolumeStore {
    enum RunState {
        /// The read-only scan of the selected target. Not busy: Clean, Clean & Eject and Eject stop it and run.
        case scanning(currentPath: String)
        case scanned(Findings)
        /// The user stopped the scan; nothing scans the target again until Scan Again or a new selection.
        case stopped
        case cleaning(currentPath: String)
        case ejecting
        case finished(LastRun)
        case failed(String)

        /// A real run (clean or eject) is on; the actions wait for it.
        var isBusy: Bool {
            switch self {
            case .cleaning, .ejecting: true
            case .scanning, .scanned, .stopped, .finished, .failed: false
            }
        }

        var isCancellable: Bool {
            switch self {
            case .cleaning: true
            case .scanning, .scanned, .stopped, .ejecting, .finished, .failed: false
            }
        }
    }

    /// A finished scan: what a run with `rules` would remove.
    struct Findings {
        /// The rules the scan used; a run started while these findings are on screen uses exactly these,
        /// and a rule change in Settings drops them and rescans, so what is shown is what gets removed.
        let rules: HiddenFileRules
        let items: ReportItems
        /// A real run merges the AppleDouble sidecars before removing them (volumes and folders only).
        let mergesAppleDouble: Bool

        init(target: CleanTarget, rules: HiddenFileRules, items: ReportItems) {
            self.rules = rules
            self.items = items
            mergesAppleDouble = rules.mergeAppleDouble && rules.appleDouble && !target.isArchive
        }
    }

    /// One finished run. Kept after a volume is gone so the user gets a confirmation of what happened,
    /// including per-item failures.
    struct LastRun: Identifiable {
        let id = UUID()
        let name: String
        /// Nil for an eject without cleaning.
        let items: ReportItems?
        let ejected: Bool
        /// The eject after cleaning failed with this message; the volume is still mounted.
        let ejectError: String?

        init(name: String, items: ReportItems?, ejected: Bool, ejectError: String? = nil) {
            self.name = name
            self.items = items
            self.ejected = ejected
            self.ejectError = ejectError
        }

        var hasProblems: Bool {
            ejectError != nil || items?.failureLines.isEmpty == false
        }

        var headline: String {
            if ejectError != nil { return "Cleaned \(name), but it could not be ejected" }
            switch (items != nil, ejected) {
            case (true, true): return "Cleaned and ejected \(name)"
            case (true, false): return "Cleaned \(name)"
            case (false, _): return "Ejected \(name)"
            }
        }

        /// What the cleaning did, failures included, and why the eject failed; nil for a plain eject.
        var detail: String? {
            var sentences: [String] = []
            if let items {
                if items.count > 0 { sentences.append("Removed \(items.summary)") }
                if let merged = items.mergedSummary { sentences.append(merged) }
                if let failed = items.failureSummary { sentences.append(failed) }
                if sentences.isEmpty { sentences.append("Nothing to remove, \(name) was already clean") }
            }
            if let ejectError {
                sentences.append("It is still mounted: \(ejectError.hasSuffix(".") ? String(ejectError.dropLast()) : ejectError)")
            }
            return sentences.isEmpty ? nil : sentences.joined(separator: ". ") + "."
        }
    }

    struct AlertInfo {
        let title: String
        let message: String
    }
}
