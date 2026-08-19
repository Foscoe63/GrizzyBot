import Foundation

/// Global vs per-user Application Support layout.
public enum AccountLayout {
    public static func defaultGlobalRoot() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GrizzyBot", isDirectory: true)
    }

    public static func userDirectory(global: URL, userId: String) -> URL {
        global.appendingPathComponent("users/\(userId)", isDirectory: true)
    }

    public static func ensureUserDirectory(global: URL, userId: String) -> URL {
        let dir = userDirectory(global: global, userId: userId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
