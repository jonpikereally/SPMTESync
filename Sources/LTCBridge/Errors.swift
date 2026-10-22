import AppKit

/// Every failure a user can run into has a stable code, so it can be looked up
/// on the public error list (ERRORS.md) or pasted into an LLM. Add new codes
/// here and to ERRORS.md together, and never show a user an error without one.
/// Codes are never reused or renumbered.
enum ErrorCode: String, CaseIterable {
    // 1xx — updates
    case noUpdateSource = "LB-101"
    case badUpdateSource = "LB-102"
    case updateSourceUnreachable = "LB-103"
    case updateServerError = "LB-104"
    case updateInfoMalformed = "LB-105"
    case updateDownloadFailed = "LB-106"
    case updateUnpackFailed = "LB-107"
    case updateMissingApp = "LB-108"
    case updateWrongApp = "LB-109"
    case updateDamagedApp = "LB-110"
    case updateInstallerFailed = "LB-111"
    case updateSwapFailed = "LB-112"
    // 2xx — audio input
    case microphoneDenied = "LB-201"
    case inputDeviceMissing = "LB-202"
    case inputStartFailed = "LB-203"
    case inputStalled = "LB-204"
    // 3xx — MIDI output
    case midiSetupFailed = "LB-301"
    case midiDestinationMissing = "LB-302"
    case midiSendFailed = "LB-303"
    case realtimeRefused = "LB-304"
    case networkSessionFailed = "LB-305"
    case networkHostInvalid = "LB-306"
    case networkSessionMissing = "LB-307"
    // 6xx — reserved for the Install LTC Bridge.command script (release.sh)
    // 9xx — anything not covered above
    case unexpected = "LB-999"

    var summary: String {
        switch self {
        case .noUpdateSource: return "No update source is set."
        case .badUpdateSource: return "The update source isn't a web link or a file path."
        case .updateSourceUnreachable: return "Couldn't reach the update source."
        case .updateServerError: return "The update server returned an error."
        case .updateInfoMalformed: return "The update information is damaged or in the wrong format."
        case .updateDownloadFailed: return "Couldn't download the update."
        case .updateUnpackFailed: return "Couldn't unpack the downloaded update."
        case .updateMissingApp: return "The downloaded update doesn't contain LTC Bridge."
        case .updateWrongApp: return "The downloaded update is a different app."
        case .updateDamagedApp: return "The downloaded update is damaged."
        case .updateInstallerFailed: return "Couldn't start installing the update."
        case .updateSwapFailed: return "Installing the update failed, so the previous version was kept."
        case .microphoneDenied: return "LTC Bridge isn't allowed to use audio inputs, so it can't hear the timecode."
        case .inputDeviceMissing: return "The selected audio input isn't connected."
        case .inputStartFailed: return "Couldn't start listening to the audio input."
        case .inputStalled: return "The audio input stopped delivering audio, so LTC Bridge restarted it."
        case .midiSetupFailed: return "Couldn't create the “LTC Bridge” MIDI port, so no MTC can be sent."
        case .midiDestinationMissing: return "The extra MIDI destination isn't connected, so MTC only goes to the “LTC Bridge” port."
        case .midiSendFailed: return "Sending MTC failed."
        case .networkSessionFailed: return "Couldn't turn on network MIDI, so MTC isn't going out over the network."
        case .networkHostInvalid: return "Couldn't connect to that network address."
        case .networkSessionMissing: return "This Mac has no network MIDI session yet, so MTC can't go out over the network."
        case .realtimeRefused: return "macOS refused real-time priority for the MTC sender, so MTC timing may wobble by a few milliseconds."
        case .unexpected: return "Something unexpected went wrong."
        }
    }

    var hint: String {
        switch self {
        case .noUpdateSource, .badUpdateSource:
            return "Set one with “Update Source…” in the LTC Bridge menu, or leave it empty to use the built-in source."
        case .updateSourceUnreachable:
            return "Check your internet connection and try again."
        case .updateServerError, .updateDownloadFailed:
            return "Try again in a few minutes. If it keeps happening, download the latest version from GitHub."
        case .updateInfoMalformed, .updateUnpackFailed, .updateMissingApp, .updateWrongApp, .updateDamagedApp:
            return "The published update is broken. Download the latest version from GitHub instead."
        case .updateInstallerFailed, .updateSwapFailed:
            return "Make sure LTC Bridge is in ~/Applications and that the folder isn't locked, then try again."
        case .microphoneDenied:
            return "Turn LTC Bridge on in System Settings → Privacy & Security → Microphone, then quit and reopen it. If it's already on, turn it off and on again."
        case .inputDeviceMissing:
            return "Plug the interface back in or start Dante Virtual Soundcard. LTC Bridge reconnects by itself as soon as the device appears."
        case .inputStartFailed:
            return "Check that the device works in Audio MIDI Setup and isn't in use exclusively by another app, then pick it again."
        case .inputStalled:
            return "Usually a driver hiccup or a sample-rate change. If it keeps happening, check the interface's clock and connection."
        case .midiSetupFailed:
            return "Quit and reopen LTC Bridge. If it keeps happening, restart the Mac (the MIDI system may be stuck)."
        case .midiDestinationMissing:
            return "Reconnect the device or network session, or choose “None” under “Also send to”."
        case .midiSendFailed:
            return "Check the destination under “Also send to”, or choose “None”."
        case .networkSessionFailed:
            return "Check that this Mac is on a network, then open Audio MIDI Setup → Window → Show MIDI Network Setup and look at the session there. Turn network output off and on again in LTC Bridge."
        case .networkSessionMissing:
            return "Open Audio MIDI Setup → Window → Show MIDI Network Setup, click + under My Sessions, and tick the new session. LTC Bridge picks it up within a few seconds."
        case .networkHostInvalid:
            return "Type an IP address or host name, optionally followed by :port — rtpMIDI on Windows uses 5004 by default. Example: 192.168.1.20:5004"
        case .realtimeRefused:
            return "Quit and reopen LTC Bridge. Close heavy apps you don't need during the show. Logic usually still chases fine."
        case .unexpected:
            return "Try again. If it keeps happening, copy the details and ask for help."
        }
    }
}

struct AppError: LocalizedError {
    let code: ErrorCode
    /// Technical specifics (device names, system error numbers).
    let detail: String?

    init(_ code: ErrorCode, _ detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    init(wrapping error: Error, as code: ErrorCode = .unexpected) {
        if let e = error as? AppError { self = e } else { self.init(code, error.localizedDescription) }
    }

    var errorDescription: String? { "\(code.summary) (\(code.rawValue))" }
}

/// Logs every error to ~/Library/Application Support/LTC Bridge/errors.log and
/// shows it to the user with its code: in an alert, or as a banner in the main
/// window for background failures (an alert mid-show would steal focus).
final class ErrorReporter {
    enum Surface {
        case alert     // shown right away
        case banner    // "⚠️ Problem LB-xxx" row in the window
        case logOnly   // e.g. an automatic update check while offline
    }

    static let shared = ErrorReporter()
    /// The public error list. Both URLs work without a GitHub account; the raw
    /// one is plain text, which AI assistants read most reliably.
    static let helpURL = "https://github.com/jonpikereally/SPMTESync/blob/main/ERRORS.md"
    static let plainTextHelpURL = "https://raw.githubusercontent.com/jonpikereally/SPMTESync/main/ERRORS.md"

    /// Hover text for anything that shows an error.
    static let tooltip = "Look up this error code on the LTC Bridge error list: \(helpURL)\n"
        + "You can also give that page and the copied error details to an AI assistant for help."

    /// Latest background problem waiting in the window, if any.
    private(set) var pending: AppError?
    var onChange: () -> Void = {}
    private var lastLogged: [ErrorCode: Date] = [:]

    static let logURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LTC Bridge", isDirectory: true)
            .appendingPathComponent("errors.log")
    }()

    func report(_ error: AppError, surface: Surface, title: String = "LTC Bridge ran into a problem") {
        DispatchQueue.main.async {
            self.log(error)
            switch surface {
            case .alert:
                self.present(error, title: title)
            case .banner:
                self.pending = error
                self.onChange()
            case .logOnly:
                break
            }
        }
    }

    func clearPending() {
        pending = nil
        onChange()
    }

    /// Clears the banner only if it's showing this code (the problem went away).
    func resolve(_ code: ErrorCode) {
        if pending?.code == code { clearPending() }
    }

    /// Shows the error with its code. `actions` become extra buttons; returns
    /// the index of the action picked, or nil for OK.
    @discardableResult
    func present(_ error: AppError, title: String, actions: [String] = []) -> Int? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        var text = error.code.summary
        if let d = error.detail, !d.isEmpty { text += "\n\n\(d)" }
        text += "\n\n\(error.code.hint)\n\nError code: \(error.code.rawValue)"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        for a in actions { alert.addButton(withTitle: a) }
        alert.addButton(withTitle: "Copy Error Details")
        alert.addButton(withTitle: "Open Error List")
        Self.addTooltips(to: alert)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if response == actions.count + 1 {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(Self.details(error), forType: .string)
            return nil
        }
        if response == actions.count + 2 {
            if let url = URL(string: Self.helpURL) { NSWorkspace.shared.open(url) }
            return nil
        }
        if response >= 1 && response <= actions.count { return response - 1 }
        return nil
    }

    /// Puts the error-list hover text on every piece of text in the alert,
    /// and on the alert itself for the space between them.
    static func addTooltips(to alert: NSAlert) {
        alert.layout()
        func walk(_ view: NSView) {
            if view is NSTextField { view.toolTip = tooltip }
            view.subviews.forEach(walk)
        }
        if let content = alert.window.contentView {
            content.toolTip = tooltip
            walk(content)
        }
    }

    /// Copyable report: everything needed to troubleshoot, nothing private.
    static func details(_ error: AppError) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        var lines = ["LTC Bridge error \(error.code.rawValue): \(error.code.summary)"]
        if let d = error.detail, !d.isEmpty { lines.append("Details: \(d)") }
        lines.append("Suggested fix: \(error.code.hint)")
        lines.append("LTC Bridge v\(AppVersion.version) (built \(AppVersion.built)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(arch)")
        lines.append("Time: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Error code list: \(helpURL)")
        lines.append("Plain-text error list for AI assistants: \(plainTextHelpURL)")
        return lines.joined(separator: "\n")
    }

    private func log(_ error: AppError) {
        // The same code repeating (a device unplugged for an hour) is logged
        // at most once a minute.
        let now = Date()
        if let last = lastLogged[error.code], now.timeIntervalSince(last) < 60 { return }
        lastLogged[error.code] = now

        let line = "\(ISO8601DateFormatter().string(from: now)) \(error.code.rawValue) v\(AppVersion.version) "
            + error.code.summary + (error.detail.map { " — \($0)" } ?? "") + "\n"
        let url = Self.logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
