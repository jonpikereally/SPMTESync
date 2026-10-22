import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bridge = Bridge()
    private let state = AppState()
    private var window: NSWindow!
    private var updateMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "LTC Bridge"
        window.contentView = NSHostingView(rootView: ContentView(bridge: bridge, app: state))
        window.setFrameAutosaveName("LTCBridgeMain")
        if !window.setFrameUsingName("LTCBridgeMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        state.installUpdate = { [weak self] in self?.checkForUpdates() }
        state.showProblem = { [weak self] in self?.showPendingProblem() }
        ErrorReporter.shared.onChange = { [weak self] in self?.state.problem = ErrorReporter.shared.pending }

        reportFailedUpdateIfAny()
        Updater.shared.onChange = { [weak self] in self?.refreshUpdateItem() }
        Updater.shared.startAutomaticChecks()

        bridge.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting mid-show stops Logic, so ask first while MTC is going out.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard bridge.status.sendingMTC, !Updater.shared.installing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit LTC Bridge?"
        alert.informativeText = "MTC is being sent right now. Quitting stops it, and anything chasing it (Logic) will stop."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.stop()
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LTC Bridge", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        updateMenuItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateMenuItem.target = self
        appMenu.addItem(updateMenuItem)
        appMenu.addItem(withTitle: "Update Source…", action: #selector(editUpdateSource), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "LTC Bridge on GitHub", action: #selector(openGitHub), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Error Code List", action: #selector(openErrorList), keyEquivalent: "").target = self
        let version = NSMenuItem(title: "Version \(AppVersion.version) (built \(AppVersion.built))", action: nil, keyEquivalent: "")
        version.isEnabled = false
        appMenu.addItem(version)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LTC Bridge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit LTC Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "LTC Bridge",
            .applicationVersion: AppVersion.version,
            .credits: NSAttributedString(string: "Turns LTC from any audio input (Dante included) into MTC for Logic Pro."),
        ])
    }

    // MARK: - Updates

    private func refreshUpdateItem() {
        let preparing = Updater.shared.isPreparingInstall
        state.preparingUpdate = preparing
        updateMenuItem.isEnabled = !preparing
        if preparing { updateMenuItem.title = "Installing Update…"; return }
        if let m = Updater.shared.available {
            updateMenuItem.title = "⬆︎ Install Update to v\(m.version)…"
            state.updateVersion = m.version
        } else {
            updateMenuItem.title = "Check for Updates…"
            state.updateVersion = nil
        }
    }

    @objc private func checkForUpdates() {
        if let m = Updater.shared.available {
            offerInstall(m)
            return
        }
        updateMenuItem.title = "Checking for Updates…"
        Updater.shared.check { [weak self] result in
            guard let self else { return }
            self.refreshUpdateItem()
            switch result {
            case .success(let m?):
                self.offerInstall(m)
            case .success(nil):
                let alert = NSAlert()
                alert.messageText = "LTC Bridge is up to date"
                alert.informativeText = "You're running v\(AppVersion.version), the newest version available."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            case .failure(let error):
                self.showUpdateError(error)
            }
        }
    }

    private func offerInstall(_ m: UpdateManifest) {
        let alert = NSAlert()
        alert.messageText = "Update to LTC Bridge v\(m.version)?"
        var info = "You have v\(AppVersion.version)."
        if let notes = m.notes, !notes.isEmpty { info += "\n\nWhat's new:\n\(notes)" }
        info += "\n\nLTC Bridge will quit, update itself and reopen. Your settings are kept."
            + "\n\nAfterwards macOS will ask again for permission to use audio inputs (it asks after every update). "
            + "Allow it, or LTC Bridge can't hear the timecode."
        if bridge.status.sendingMTC {
            info += "\n\n⚠️ MTC is being sent right now. Updating stops it, so anything chasing it will stop."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        updateMenuItem.title = "Installing Update…"
        updateMenuItem.isEnabled = false
        Updater.shared.install(m) { [weak self] error in
            self?.updateMenuItem.isEnabled = true
            self?.refreshUpdateItem()
            self?.showUpdateError(error)
        }
    }

    private func showUpdateError(_ error: Error) {
        let e = AppError(wrapping: error)
        let sourceProblem = e.code == .noUpdateSource || e.code == .badUpdateSource
        let picked = ErrorReporter.shared.present(e, title: "Couldn't update LTC Bridge",
                                                  actions: sourceProblem ? ["Set Update Source…"] : [])
        if picked == 0 { editUpdateSource() }
    }

    /// The swap script leaves a coded marker when installing an update fails
    /// and it has put the previous version back.
    private func reportFailedUpdateIfAny() {
        let marker = Updater.swapFailureMarker
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: marker)
        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        let code = parts.first.flatMap { ErrorCode(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? .updateSwapFailed
        ErrorReporter.shared.report(AppError(code, parts.count > 1 ? parts[1] : nil),
                                    surface: .alert, title: "Couldn't install the update")
    }

    private func showPendingProblem() {
        guard let p = ErrorReporter.shared.pending else { return }
        ErrorReporter.shared.clearPending()
        ErrorReporter.shared.present(p, title: "LTC Bridge ran into a problem")
    }

    @objc private func editUpdateSource() {
        let alert = NSAlert()
        alert.messageText = "Update Source"
        alert.informativeText = "Where LTC Bridge looks for new versions: a web link or a file path to a latest.json feed. "
            + "Leave it empty to use the built-in source"
            + (AppVersion.updateFeed.isEmpty ? " (none in this build)." : ":\n\(AppVersion.updateFeed)")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: "updateFeed") ?? ""
        field.placeholderString = AppVersion.updateFeed.isEmpty ? "https://…/latest.json" : AppVersion.updateFeed
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && Updater.url(from: value) == nil {
            showUpdateError(AppError(.badUpdateSource, value))
            return
        }
        Updater.shared.feed = value
        Updater.shared.check { _ in }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/jonpikereally/SPMTESync") { NSWorkspace.shared.open(url) }
    }

    @objc private func openErrorList() {
        if let url = URL(string: ErrorReporter.helpURL) { NSWorkspace.shared.open(url) }
    }
}
