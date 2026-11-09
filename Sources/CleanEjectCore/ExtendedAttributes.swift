import Darwin

/// listxattr(2), getxattr(2) and setxattr(2) on one path, never following a symbolic link.
enum ExtendedAttributes {
    /// The kernel's record of which app wrote a file. Never copied: every file this process creates
    /// carries CleanEject's own, which must not end up on the user's files.
    static let provenance = "com.apple.provenance"

    static func names(of path: String) -> [String]? {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard read >= 0 else { return nil }
        return buffer.prefix(read).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    static func value(_ name: String, of path: String) -> [UInt8]? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &value, size, 0, XATTR_NOFOLLOW)
        guard read >= 0 else { return nil }
        return Array(value.prefix(read))
    }

    static func has(_ name: String, at path: String) -> Bool {
        getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// nil on success, else the reason.
    static func set(_ name: String, _ value: [UInt8], on path: String, createOnly: Bool = false) -> String? {
        let options = XATTR_NOFOLLOW | (createOnly ? XATTR_CREATE : 0)
        let result = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, options) }
        return result == 0 ? nil : errorMessage()
    }

    static func errorMessage() -> String {
        String(cString: strerror(errno))
    }
}
