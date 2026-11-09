import AppKit
import CleanEjectCore

extension URL {
    /// The Finder icon of the item at this path at `size` points; a copy, so the workspace's cached image keeps its size.
    func finderIcon(size: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path).copy() as! NSImage
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}

extension VolumeInfo {
    func icon(size: CGFloat) -> NSImage {
        url.finderIcon(size: size)
    }
}
