import CleanEjectCore

extension CleanTarget.Refusal {
    /// The alert title; the message is the core's.
    var title: String {
        switch subject {
        case .volume: "This Volume Cannot Be Cleaned"
        case .folder: "This Folder Cannot Be Cleaned"
        case .archive: "This Archive Cannot Be Cleaned"
        case .item: "This Item Cannot Be Cleaned"
        }
    }
}
