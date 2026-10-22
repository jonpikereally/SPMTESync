import AppKit

/// Update feed format (latest.json):
///   {"version": "1.0", "url": "LTCBridge.zip", "notes": "What changed"}
/// `url` may be absolute or relative to the feed's own location.
struct UpdateManifest: Decodable {
    let version: String
    let url: String
    let notes: String?
}

/// Low-level read failure; callers turn it into the right LB-code for the step.
private struct ReadFailure: Error {
    let detail: String
    let httpStatus: Int?
}

final class Updater {
    static let shared = Updater()

    /// Newer version found by the most recent check, if any.
    private(set) var available: UpdateManifest?
    var onChange: () -> Void = {}
    private var timer: Timer?
    /// True once the swap helper is running and the app is quitting for it,
    /// so the "timecode will stop" quit confirmation is skipped.
    private(set) var installing = false

    /// User override first, then the feed baked in at build time.
    var feed: String? {
        get {
            if let s = UserDefaults.standard.string(forKey: "updateFeed"), !s.isEmpty { return s }
            return AppVersion.updateFeed.isEmpty ? nil : AppVersion.updateFeed
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: "updateFeed")
        }
    }

    static func url(from s: String) -> URL? {
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("file://") {
            return URL(string: s)
        }
        guard s.hasPrefix("/") || s.hasPrefix("~") else { return nil }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
    }

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

    /// Silent check shortly after launch and every 6 hours after that.
    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.check(completion: Self.logBackgroundFailure)
        }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.check(completion: Self.logBackgroundFailure)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Automatic checks are silent: a failure (say, while offline) is logged
    /// with its code but not shown.
    private static func logBackgroundFailure(_ result: Result<UpdateManifest?, Error>) {
        if case .failure(let error) = result {
            ErrorReporter.shared.report(AppError(wrapping: error), surface: .logOnly)
        }
    }

    /// Completion runs on the main thread with the newer manifest, or nil if up to date.
    func check(completion: @escaping (Result<UpdateManifest?, Error>) -> Void) {
        guard let feed else { completion(.failure(AppError(.noUpdateSource))); return }
        guard let feedURL = Self.url(from: feed) else {
            completion(.failure(AppError(.badUpdateSource, feed))); return
        }
        DispatchQueue.global(qos: .utility).async {
            let result: Result<UpdateManifest?, Error>
            do {
                let data: Data
                do { data = try Self.read(feedURL) } catch let f as ReadFailure {
                    throw AppError(f.httpStatus == nil ? .updateSourceUnreachable : .updateServerError,
                                   "\(feedURL.absoluteString) — \(f.detail)")
                }
                let manifest: UpdateManifest
                do { manifest = try JSONDecoder().decode(UpdateManifest.self, from: data) } catch {
                    throw AppError(.updateInfoMalformed, "\(feedURL.absoluteString) — \(error.localizedDescription)")
                }
                result = .success(Self.isNewer(manifest.version, than: AppVersion.version) ? manifest : nil)
            } catch {
                result = .failure(AppError(wrapping: error))
            }
            DispatchQueue.main.async {
                if case .success(let newer) = result {
                    self.available = newer
                    self.onChange()
                }
                completion(result)
            }
        }
    }

    /// Download, unpack and verify the update, then hand off to a helper
    /// script that swaps the app bundle once this process has quit and
    /// relaunches it. Completion only runs on failure.
    func install(_ manifest: UpdateManifest, completion: @escaping (Error) -> Void) {
        guard let feed, let feedURL = Self.url(from: feed),
              let zipURL = URL(string: manifest.url, relativeTo: feedURL)?.absoluteURL
        else { completion(AppError(.noUpdateSource)); return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LTCBridge-update-\(UUID().uuidString)", isDirectory: true)
                let zip = work.appendingPathComponent("update.zip")
                do {
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                } catch {
                    throw AppError(.updateInstallerFailed, "\(work.path) — \(error.localizedDescription)")
                }
                do { try Self.read(zipURL).write(to: zip) } catch let f as ReadFailure {
                    throw AppError(.updateDownloadFailed, "\(zipURL.absoluteString) — \(f.detail)")
                } catch {
                    throw AppError(.updateDownloadFailed, "\(zip.path) — \(error.localizedDescription)")
                }

                do { try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) } catch let f as ReadFailure {
                    throw AppError(.updateUnpackFailed, f.detail)
                } catch {
                    throw AppError(.updateUnpackFailed, error.localizedDescription)
                }
                guard let newApp = Self.findApp(in: work) else {
                    throw AppError(.updateMissingApp, zipURL.absoluteString)
                }
                let newBundle = Bundle(url: newApp)
                guard newBundle?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw AppError(.updateWrongApp,
                                   "bundle ID \(newBundle?.bundleIdentifier ?? "none"), expected \(Bundle.main.bundleIdentifier ?? "?")")
                }
                guard let exe = newBundle?.executableURL,
                      FileManager.default.isExecutableFile(atPath: exe.path) else {
                    throw AppError(.updateDamagedApp, "no executable inside \(newApp.lastPathComponent)")
                }

                let script = work.appendingPathComponent("swap.sh")
                do {
                    try Self.swapScript.write(to: script, atomically: false, encoding: .utf8)
                    let helper = Process()
                    helper.executableURL = URL(fileURLWithPath: "/bin/bash")
                    helper.arguments = [script.path,
                                        String(ProcessInfo.processInfo.processIdentifier),
                                        newApp.path,
                                        Bundle.main.bundleURL.path,
                                        Bundle.main.bundleIdentifier ?? "com.jonpike.ltcbridge",
                                        Self.swapFailureMarker.path]
                    try helper.run()
                } catch {
                    throw AppError(.updateInstallerFailed, error.localizedDescription)
                }

                DispatchQueue.main.async { self.installing = true; NSApp.terminate(nil) }
            } catch {
                DispatchQueue.main.async { completion(AppError(wrapping: error)) }
            }
        }
    }

    // MARK: - Helpers

    private static func read(_ url: URL) throws -> Data {
        if url.isFileURL {
            do { return try Data(contentsOf: url) }
            catch { throw ReadFailure(detail: error.localizedDescription, httpStatus: nil) }
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var out: Result<Data, Error> = .failure(ReadFailure(detail: "no response", httpStatus: nil))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                out = .failure(ReadFailure(detail: error.localizedDescription, httpStatus: nil))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                out = .failure(ReadFailure(detail: "HTTP \(http.statusCode)", httpStatus: http.statusCode))
            } else {
                out = .success(data ?? Data())
            }
            sem.signal()
        }.resume()
        sem.wait()
        return try out.get()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ReadFailure(detail: "\((tool as NSString).lastPathComponent) exited with status \(p.terminationStatus)",
                              httpStatus: nil)
        }
    }

    private static func findApp(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e {
            if url.lastPathComponent == "LTC Bridge.app" { return url }
            if url.pathExtension == "app" { e.skipDescendants() }
        }
        return nil
    }

    /// The swap script writes "LB-xxx|detail" here when installing fails; the
    /// relaunched (old) app reads it, reports it, and deletes it.
    static let swapFailureMarker: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LTC Bridge", isDirectory: true)
            .appendingPathComponent("update-failed.txt")
    }()

    /// Waits for the old process to exit, swaps bundles, and relaunches. The
    /// installed app is only removed once the new one is fully copied; if the
    /// copy fails, the old one is moved back. The Microphone reset matters:
    /// an ad-hoc-signed rebuild invalidates the old grant while System Settings
    /// still shows it switched on, so we clear it and let the new build ask.
    private static let swapScript = """
    #!/bin/bash
    PID="$1"; NEW="$2"; DEST="$3"; BID="$4"; MARKER="$5"
    fail() { mkdir -p "$(dirname "$MARKER")"; printf '%s|%s' "$1" "$2" > "$MARKER"; }
    for _ in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    rm -rf "$DEST.old"
    if ! mv "$DEST" "$DEST.old" 2>/dev/null; then
        fail "LB-112" "couldn't move $DEST aside to make room for the new version"
    elif ! /usr/bin/ditto --norsrc "$NEW" "$DEST" 2>/dev/null; then
        rm -rf "$DEST"
        mv "$DEST.old" "$DEST"
        fail "LB-112" "couldn't copy the new version into $DEST"
    else
        rm -rf "$DEST.old"
        /usr/bin/tccutil reset Microphone "$BID" >/dev/null 2>&1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
    /usr/bin/codesign --force --sign - "$DEST" 2>/dev/null
    /usr/bin/open "$DEST"
    """
}
