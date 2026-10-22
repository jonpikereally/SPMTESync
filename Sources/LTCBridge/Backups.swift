import Foundation

/// Where updates keep the previous version, and cleanup of the old layout.
///
/// Since v1.6 the install helper (Resources/InstallBundle.sh) moves the
/// replaced version to "Previous Version.noindex" in Application Support,
/// never beside the app. Updates made by v1.5 and earlier left it in the
/// Applications folder as "<name> Previous.app", where it showed up as a
/// second copy of the app; `tidyLegacyCopies` moves those to the new place.
enum Backups {
    static let folderName = "Previous Version.noindex"

    struct Result: Equatable {
        var kept: URL?              // the copy now in the backup folder
        var discarded: [URL] = []
    }

    /// Moves the newest "<name> Previous*.app" beside `app` into the backup
    /// folder in `support`, replacing the backup there, and discards any
    /// other such copies. Copies that are running, or that belong to a
    /// different app, are left alone. The app passes the Trash as `discard`.
    static func tidyLegacyCopies(app: URL, bundleID: String, support: URL,
                                 isRunning: (URL) -> Bool,
                                 discard: (URL) throws -> Void,
                                 fm: FileManager = .default) throws -> Result {
        let dir = app.deletingLastPathComponent()
        let stem = app.deletingPathExtension().lastPathComponent
        let legacy = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(stem + " Previous") && $0.hasSuffix(".app") }
            .map { dir.appendingPathComponent($0, isDirectory: true) }
            .filter { info($0)?["CFBundleIdentifier"] as? String == bundleID && !isRunning($0) }
            .sorted { isNewer(version($0), than: version($1)) }      // newest first
        var result = Result()
        guard let newest = legacy.first else { return result }

        let folder = support.appendingPathComponent(folderName, isDirectory: true)
        let previous = folder.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: previous.path) {
            try discard(previous)
            result.discarded.append(previous)
        }
        do {
            try fm.moveItem(at: newest, to: previous)
            result.kept = previous
        } catch where !fm.fileExists(atPath: newest.path) {
            // An older install helper renamed it while we looked; next launch tidies it.
        }
        for extra in legacy.dropFirst() where fm.fileExists(atPath: extra.path) {
            try discard(extra)
            result.discarded.append(extra)
        }
        return result
    }

    /// Read straight from disk: Bundle(url:) caches per path for the life of
    /// the process, which goes stale when bundles are swapped.
    private static func info(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func version(_ app: URL) -> String {
        info(app)?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Dotted versions compared numerically, as the update check does.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
