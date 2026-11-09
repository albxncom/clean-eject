import AppKit

public enum VolumeEjector {
    /// Unmounts and ejects the volume at `url`, throwing the system error (e.g. volume busy) on failure.
    /// Runs off the main actor because NSWorkspace blocks until the volume is flushed.
    @concurrent
    public static func eject(_ url: URL) async throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }
}
