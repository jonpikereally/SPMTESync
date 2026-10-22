// Cleanup of the pre-v1.6 backup layout (Backups.tidyLegacyCopies), on fake
// bundles in temporary folders. Discarded copies are deleted here; the app
// moves them to the Trash.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

let fm = FileManager.default
func makeApp(_ url: URL, id: String = "com.jonpike.ltcbridge", version: String) {
    try! fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
    try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
}
func version(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return info["CFBundleShortVersionString"] as? String
}
func names(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
func folders() -> (apps: URL, support: URL, backups: URL) {
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? fm.temporaryDirectory
    let root = tmp.appendingPathComponent("ltc-backups-\(UUID().uuidString)")
    let apps = root.appendingPathComponent("Applications"), support = root.appendingPathComponent("Support")
    try! fm.createDirectory(at: apps, withIntermediateDirectories: true)
    try! fm.createDirectory(at: support, withIntermediateDirectories: true)
    return (apps, support, support.appendingPathComponent(Backups.folderName))
}
var discardedVersions: [String] = []
let discard: (URL) throws -> Void = { discardedVersions.append(version($0) ?? "?"); try fm.removeItem(at: $0) }
func tidy(_ f: (apps: URL, support: URL, backups: URL), running: Set<String> = []) throws -> Backups.Result {
    try Backups.tidyLegacyCopies(app: f.apps.appendingPathComponent("LTC Bridge.app"), bundleID: "com.jonpike.ltcbridge",
                                 support: f.support, isRunning: { running.contains($0.lastPathComponent) }, discard: discard)
}

print("old-style backups beside the app move out of Applications")
do {
    let f = folders()
    makeApp(f.apps.appendingPathComponent("LTC Bridge.app"), version: "1.6")
    makeApp(f.apps.appendingPathComponent("LTC Bridge Previous.app"), version: "1.5")
    makeApp(f.apps.appendingPathComponent("LTC Bridge Previous.4242.app"), version: "1.4")       // a crashed swap's leftover
    makeApp(f.apps.appendingPathComponent("LTC Bridge Previous Copy.app"), id: "com.example.other", version: "1.0")
    makeApp(f.apps.appendingPathComponent("Other Previous.app"), version: "1.0")
    makeApp(f.backups.appendingPathComponent("LTC Bridge.app"), version: "1.3")                  // an older backup
    discardedVersions = []
    let result = try tidy(f)
    check(result.kept == f.backups.appendingPathComponent("LTC Bridge.app"), "kept copy isn't in the backup folder")
    check(version(f.backups.appendingPathComponent("LTC Bridge.app")) == "1.5", "the backup isn't the newest old copy")
    check(names(f.backups) == ["LTC Bridge.app"], "backup folder holds \(names(f.backups))")
    check(names(f.apps) == ["LTC Bridge Previous Copy.app", "LTC Bridge.app", "Other Previous.app"],
          "Applications folder holds \(names(f.apps))")
    check(discardedVersions.sorted() == ["1.3", "1.4"], "discarded \(discardedVersions), expected the 1.3 backup and the 1.4 leftover")
}

print("a running old copy, or nothing to do, is left alone")
do {
    let f = folders()
    makeApp(f.apps.appendingPathComponent("LTC Bridge.app"), version: "1.6")
    makeApp(f.apps.appendingPathComponent("LTC Bridge Previous.app"), version: "1.5")
    discardedVersions = []
    check(try tidy(f, running: ["LTC Bridge Previous.app"]) == Backups.Result(), "touched a running copy")
    check(names(f.apps) == ["LTC Bridge Previous.app", "LTC Bridge.app"], "a running copy was moved")
    check(!fm.fileExists(atPath: f.backups.path) && discardedVersions.isEmpty, "made changes with nothing to tidy")

    let g = folders()
    makeApp(g.apps.appendingPathComponent("LTC Bridge.app"), version: "1.6")
    check(try tidy(g) == Backups.Result(), "reported work with no old copies")
    check(!fm.fileExists(atPath: g.backups.path), "created a backup folder with nothing to keep")
}

print("versions compare numerically (1.10 is newer than 1.4)")
do {
    let f = folders()
    makeApp(f.apps.appendingPathComponent("LTC Bridge.app"), version: "1.11")
    makeApp(f.apps.appendingPathComponent("LTC Bridge Previous.app"), version: "1.4")
    makeApp(f.apps.appendingPathComponent("LTC Bridge Previous.999.app"), version: "1.10")
    discardedVersions = []
    _ = try tidy(f)
    check(version(f.backups.appendingPathComponent("LTC Bridge.app")) == "1.10", "kept the wrong copy")
    check(discardedVersions == ["1.4"], "discarded \(discardedVersions)")
}

print(failures == 0 ? "Backup tidy tests passed." : "\(failures) backup check(s) failed.")
exit(failures == 0 ? 0 : 1)
