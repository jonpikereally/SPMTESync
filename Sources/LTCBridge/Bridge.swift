import AppKit
import AVFoundation
import CoreMIDI
import Foundation

/// Wires it all together: audio input → LTC decoder → MTC generator → MIDI,
/// plus the settings and the live status the window shows.
///
/// Threads: the decoder runs on the audio thread, the generator is polled by
/// a real-time sender thread, and the UI samples both 15 times a second. The
/// generator is shared, so every touch of it holds `genLock`.
final class Bridge: ObservableObject {
    enum Status: Equatable {
        case noPermission, noDevice, inputFailed, noSignal, noLTC, locking, running, freewheeling

        var text: String {
            switch self {
            case .noPermission: return "No permission to use audio input (\(ErrorCode.microphoneDenied.rawValue))"
            case .noDevice: return "Input not connected (\(ErrorCode.inputDeviceMissing.rawValue)) — waiting for it"
            case .inputFailed: return "Couldn't open the input (\(ErrorCode.inputStartFailed.rawValue)) — retrying"
            case .noSignal: return "No signal on this channel"
            case .noLTC: return "Signal present, but it isn't LTC"
            case .locking: return "Locking…"
            case .running: return "Sending MTC"
            case .freewheeling: return "LTC dropped out — freewheeling"
            }
        }

        var hasErrorCode: Bool { self == .noPermission || self == .noDevice || self == .inputFailed }
        var sendingMTC: Bool { self == .running || self == .freewheeling }
    }

    // MARK: Settings (saved)

    @Published var deviceUID: String {
        didSet { guard deviceUID != oldValue else { return }; save(); restartInput() }
    }
    /// Zero-based input channel.
    @Published var channel: Int {
        didSet { guard channel != oldValue else { return }; save(); restartInput() }
    }
    /// -1 = auto-detect, otherwise a FrameRate raw value.
    @Published var rateChoice: Int {
        didSet { save(); applyGeneratorSettings() }
    }
    @Published var freewheelFrames: Int {
        didSet { save(); applyGeneratorSettings() }
    }
    @Published var offsetMs: Double {
        didSet { save(); applyGeneratorSettings() }
    }
    @Published var extraDestination: MIDIUniqueID {
        didSet { save(); applyDestination() }
    }
    /// Also send MTC over Apple network MIDI (RTP-MIDI).
    @Published var networkEnabled: Bool {
        didSet { guard networkEnabled != oldValue else { return }; save(); applyNetwork() }
    }
    /// Addresses to connect to and keep connected ("host:port").
    @Published private(set) var networkHosts: [String]

    /// Feed the decoder a generated LTC signal instead of the input. Not
    /// saved: the app must never open at a gig still in test mode.
    @Published var testSignal = false {
        didSet { guard testSignal != oldValue else { return }; restartInput() }
    }

    // MARK: Live state

    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var destinations: [MIDIDestinationInfo] = []
    @Published private(set) var status: Status = .noSignal
    @Published private(set) var display = "--:--:--:--"
    @Published private(set) var level: Float = 0
    @Published private(set) var rate: FrameRate?
    @Published private(set) var framesDecoded = 0
    @Published private(set) var syncErrors = 0
    @Published private(set) var relocates = 0
    @Published private(set) var mtcMessages = 0
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var networkName = ""
    @Published private(set) var networkPort = 0
    @Published private(set) var networkPeers: [NetworkMIDI.Peer] = []
    /// Set while network output is on but the session isn't running.
    @Published private(set) var networkProblem: ErrorCode?

    var selectedDevice: InputDevice? { devices.first { $0.uid == deviceUID } }

    private let input = AudioInput()
    private let testSource = TestSignalSource()
    private let network = NetworkMIDI()
    private var watchdogTicks = 0
    private var networkWaitingSince: Date?
    private var decoder: LTCDecoder?
    private var detector = RateDetector()
    private let gen = MTCGenerator()
    private let genLock = NSLock()
    private var midi: MIDIOut?
    private var senderRunning = true
    private var permission: AVAuthorizationStatus = .notDetermined
    private var lastStartError: String?
    private var lastSendFailures = 0
    private var activity: NSObjectProtocol?
    private var timers: [Timer] = []

    // Audio-thread bookkeeping for turning sample positions into host times.
    private var samplesSoFar: Double = 0
    private var bufferHost: Double = 0
    private var bufferBase: Double = 0
    private var lastFrameHost: Double = 0
    private var lastTimecode: Timecode?
    private var forcedRate: FrameRate?
    private var sentCount = 0   // written by the sender thread

    private let defaults = UserDefaults.standard

    init() {
        deviceUID = defaults.string(forKey: "deviceUID") ?? ""
        channel = defaults.object(forKey: "channel") as? Int ?? 0
        rateChoice = defaults.object(forKey: "rateChoice") as? Int ?? -1
        freewheelFrames = defaults.object(forKey: "freewheelFrames") as? Int ?? 10
        offsetMs = defaults.object(forKey: "offsetMs") as? Double ?? 0
        extraDestination = MIDIUniqueID(defaults.integer(forKey: "extraDestination"))
        networkEnabled = defaults.bool(forKey: "networkEnabled")
        networkHosts = defaults.stringArray(forKey: "networkHosts") ?? []
    }

    private func save() {
        defaults.set(deviceUID, forKey: "deviceUID")
        defaults.set(channel, forKey: "channel")
        defaults.set(rateChoice, forKey: "rateChoice")
        defaults.set(freewheelFrames, forKey: "freewheelFrames")
        defaults.set(offsetMs, forKey: "offsetMs")
        defaults.set(Int(extraDestination), forKey: "extraDestination")
        defaults.set(networkEnabled, forKey: "networkEnabled")
        defaults.set(networkHosts, forKey: "networkHosts")
    }

    // MARK: Start-up

    func start() {
        // Show work must not be napped or throttled, and the Mac mustn't sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Converting LTC to MTC")

        do {
            midi = try MIDIOut()
        } catch let e as MIDIOut.SetupError {
            ErrorReporter.shared.report(AppError(.midiSetupFailed, "\(e.step) failed (OSStatus \(e.status))"), surface: .alert)
        } catch {
            ErrorReporter.shared.report(AppError(.midiSetupFailed, error.localizedDescription), surface: .alert)
        }
        applyGeneratorSettings()
        refreshDevices()
        if deviceUID.isEmpty {
            deviceUID = (devices.first { $0.name.localizedCaseInsensitiveContains("dante") } ?? devices.first)?.uid ?? ""
        }
        applyDestination()
        if networkEnabled { applyNetwork() }
        startSender()

        let ui = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.sampleState() }
        let watchdog = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.watchdog() }
        for t in [ui, watchdog] { RunLoop.main.add(t, forMode: .common) }
        timers = [ui, watchdog]

        requestPermissionThenStart()
    }

    private func requestPermissionThenStart() {
        permission = AVCaptureDevice.authorizationStatus(for: .audio)
        switch permission {
        case .authorized:
            restartInput()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.permission = granted ? .authorized : .denied
                    if granted { self.restartInput() } else { self.reportNoPermission() }
                }
            }
        default:
            reportNoPermission()
        }
    }

    private func reportNoPermission() {
        status = .noPermission
        DispatchQueue.main.async {
            ErrorReporter.shared.report(AppError(.microphoneDenied), surface: .banner)
            let picked = ErrorReporter.shared.present(AppError(.microphoneDenied),
                                                      title: "LTC Bridge can't hear the timecode",
                                                      actions: ["Open Privacy Settings"])
            if picked == 0, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Audio

    func restartInput() {
        input.stop()
        testSource.stop()
        if testSignal {
            let sr = 48_000.0
            genLock.lock(); let r = forcedRate ?? .fps25; genLock.unlock()
            testSource.start(rate: r, sampleRate: sr, handler: makeHandler(sampleRate: sr))
            sampleRate = sr
            return
        }
        guard permission == .authorized else { return }
        guard let device = selectedDevice ?? AudioDevices.device(uid: deviceUID) else {
            status = .noDevice
            return
        }
        let ch = min(channel, max(0, device.channelNames.count - 1))
        do {
            try input.start(device: device, channel: ch) { makeHandler(sampleRate: $0) }
            sampleRate = input.sampleRate
            lastStartError = nil
            ErrorReporter.shared.resolve(.inputStartFailed)
            ErrorReporter.shared.resolve(.inputDeviceMissing)
        } catch let e as AudioInput.StartError {
            input.stop()
            status = .inputFailed
            let detail = "\(device.name), channel \(ch + 1): \(e.step) failed (OSStatus \(e.status))"
            if lastStartError != detail {
                lastStartError = detail
                ErrorReporter.shared.report(AppError(.inputStartFailed, detail), surface: .banner)
            }
        } catch {
            input.stop()
            status = .inputFailed
        }
    }

    /// A fresh decoder for this sample rate and the audio callback that feeds
    /// it. Called before audio starts, so the audio thread never sees a
    /// half-built state.
    private func makeHandler(sampleRate: Double) -> AudioInput.Handler {
        let dec = LTCDecoder(sampleRate: sampleRate)
        dec.onFrame = { [unowned self] f in self.ltcFrame(f, sampleRate: sampleRate) }
        genLock.lock(); detector.reset(); decoder = dec; genLock.unlock()
        samplesSoFar = 0
        return { [unowned self] ptr, n, host in
            self.bufferHost = host
            self.bufferBase = self.samplesSoFar
            dec.process(ptr, count: n)
            self.samplesSoFar += Double(n)
        }
    }

    /// Audio thread.
    private func ltcFrame(_ f: LTCFrame, sampleRate sr: Double) {
        let t = bufferHost + (f.endSample - bufferBase) / sr
        genLock.lock()
        detector.observe(f, sampleRate: sr)
        let r = forcedRate ?? detector.rate ?? (f.dropFrameFlag ? .fps2997DF : .fps25)
        gen.rate = r
        gen.ltcFrame(f.timecode.frameNumber(r), endTime: t)
        lastTimecode = f.timecode
        lastFrameHost = t
        genLock.unlock()
    }

    // MARK: MIDI

    private func startSender() {
        let thread = Thread { [weak self] in
            let policy = Self.makeRealtime()
            if policy != KERN_SUCCESS {
                ErrorReporter.shared.report(AppError(.realtimeRefused, "thread_policy_set returned \(policy)"), surface: .banner)
            }
            while let self, self.senderRunning {
                let now = HostClock.now()
                self.genLock.lock()
                let (messages, next) = self.gen.poll(now: now)
                self.genLock.unlock()
                if !messages.isEmpty {
                    self.midi?.send(messages)
                    self.sentCount += messages.count
                }
                let wake = min(next, now + 0.005)
                if wake > now { mach_wait_until(HostClock.ticks(wake)) }
            }
        }
        thread.name = "MTC sender"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Time-constraint scheduling, like an audio thread, so quarter frames go
    /// out within a fraction of a millisecond of when they're due.
    private static func makeRealtime() -> kern_return_t {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let msToTicks = Double(tb.denom) / Double(tb.numer) * 1_000_000
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(5 * msToTicks), computation: UInt32(0.5 * msToTicks),
            constraint: UInt32(1 * msToTicks), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        return withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }

    private func applyGeneratorSettings() {
        let forced = rateChoice >= 0 ? FrameRate(rawValue: rateChoice) : nil
        genLock.lock()
        forcedRate = forced
        let fps = (forced ?? gen.rate).nominalSpeed
        gen.freewheel = Double(freewheelFrames) / fps
        gen.offset = offsetMs / 1000
        genLock.unlock()
    }

    private func applyDestination() {
        guard let midi else { return }
        if midi.setDestination(extraDestination) {
            ErrorReporter.shared.resolve(.midiDestinationMissing)
        } else {
            let name = destinations.first { $0.id == extraDestination }?.name ?? "ID \(extraDestination)"
            ErrorReporter.shared.report(AppError(.midiDestinationMissing, name), surface: .banner)
        }
    }

    // MARK: Network MIDI

    private func applyNetwork() {
        if networkEnabled {
            if network.enable() {
                midi?.setNetworkDestination(network.destination)
                networkWaitingSince = nil
                if networkProblem != nil { networkProblem = nil }
                ErrorReporter.shared.resolve(.networkSessionFailed)
                ErrorReporter.shared.resolve(.networkSessionMissing)
                reconnectHosts()
            } else {
                midi?.setNetworkDestination(0)
                // The session can take a moment to come up: only call it a
                // problem once it has stayed off for a few seconds.
                let since = networkWaitingSince ?? Date()
                networkWaitingSince = since
                if Date().timeIntervalSince(since) >= 3 {
                    let code: ErrorCode = network.sessionExists ? .networkSessionFailed : .networkSessionMissing
                    if networkProblem != code {
                        networkProblem = code
                        ErrorReporter.shared.report(AppError(code), surface: .banner)
                    }
                }
            }
        } else {
            midi?.setNetworkDestination(0)
            network.disable()
            networkWaitingSince = nil
            networkProblem = nil
            ErrorReporter.shared.resolve(.networkSessionFailed)
            ErrorReporter.shared.resolve(.networkSessionMissing)
        }
        refreshNetwork()
    }

    /// Adds an address to connect to (and keep reconnecting to). Returns
    /// false, after showing why, if it can't be used.
    @discardableResult
    func addNetworkHost(_ text: String) -> Bool {
        guard let target = NetworkMIDI.parse(text) else {
            ErrorReporter.shared.report(AppError(.networkHostInvalid, "“\(text)” isn't an address"), surface: .alert,
                                        title: "Couldn't connect")
            return false
        }
        guard network.connect(host: target.host, port: target.port) else {
            ErrorReporter.shared.report(AppError(.networkHostInvalid, "\(target.host):\(target.port) was refused by the network MIDI session"),
                                        surface: .alert, title: "Couldn't connect")
            return false
        }
        let key = Self.hostKey(target.host, target.port)
        if !networkHosts.contains(key) { networkHosts.append(key); save() }
        refreshNetwork()
        return true
    }

    func removePeer(_ peer: NetworkMIDI.Peer) {
        network.disconnect(peer)
        networkHosts.removeAll { key in
            NetworkMIDI.parse(key).map { $0.host == peer.address && $0.port == peer.port } ?? false
        }
        save()
        refreshNetwork()
    }

    private static func hostKey(_ host: String, _ port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private func reconnectHosts() {
        for key in networkHosts {
            if let t = NetworkMIDI.parse(key) { _ = network.connect(host: t.host, port: t.port) }
        }
    }

    private func refreshNetwork() {
        let on = networkEnabled && network.isEnabled
        let name = on ? network.name : ""
        let port = on ? network.port : 0
        let peers = on ? network.peers : []
        if name != networkName { networkName = name }
        if port != networkPort { networkPort = port }
        if peers != networkPeers { networkPeers = peers }
    }

    // MARK: Status sampling (main thread)

    private func sampleState() {
        let now = HostClock.now()
        genLock.lock()
        let genStatus = gen.status
        let pos = gen.position(at: now)
        let r = gen.rate
        let jumps = gen.jumps
        let tc = lastTimecode
        let detected = forcedRate ?? detector.rate
        genLock.unlock()

        let dec = decoder
        let inputActive = input.isRunning || testSignal
        level = inputActive ? (dec?.level ?? 0) : 0
        framesDecoded = dec?.framesDecoded ?? 0
        syncErrors = dec?.syncErrors ?? 0
        relocates = max(0, jumps)
        mtcMessages = sentCount
        rate = detected

        let newStatus: Status
        if testSignal {
            newStatus = genStatus == .running ? .running : genStatus == .locking ? .locking : .noSignal
        } else if permission != .authorized && permission != .notDetermined {
            newStatus = .noPermission
        } else if status == .noDevice || status == .inputFailed, !inputActive {
            newStatus = status
        } else {
            switch genStatus {
            case .running: newStatus = .running
            case .freewheeling: newStatus = .freewheeling
            case .locking: newStatus = .locking
            case .idle: newStatus = (dec?.hasSignal ?? false) ? .noLTC : .noSignal
            }
        }
        if status != newStatus { status = newStatus }

        let text: String
        if newStatus.sendingMTC {
            text = Timecode(frameNumber: Int(pos.rounded(.down)), rate: r).formatted(dropFrame: r.isDropFrame)
        } else if let tc, newStatus == .locking {
            text = tc.formatted(dropFrame: r.isDropFrame)
        } else {
            text = "--:--:--:--"
        }
        if display != text { display = text }
    }

    private func watchdog() {
        refreshDevices()
        watchdogTicks += 1
        if networkEnabled {
            if !network.isEnabled {
                applyNetwork()      // someone switched the session off in Audio MIDI Setup
            } else {
                midi?.setNetworkDestination(network.destination)
                if watchdogTicks % 5 == 0 { reconnectHosts() }
            }
            refreshNetwork()
        }

        if let midi, midi.sendFailures > lastSendFailures {
            lastSendFailures = midi.sendFailures
            ErrorReporter.shared.report(AppError(.midiSendFailed, "OSStatus \(midi.lastSendError)"), surface: .banner)
        }
        if extraDestination != 0, let midi {
            if midi.setDestination(extraDestination) {
                ErrorReporter.shared.resolve(.midiDestinationMissing)
            } else if ErrorReporter.shared.pending?.code != .midiDestinationMissing {
                applyDestination()
            }
        }

        guard permission == .authorized, !testSignal else { return }
        guard let device = selectedDevice else {
            if input.isRunning || status != .noDevice {
                input.stop()
                status = .noDevice
                if !deviceUID.isEmpty {
                    ErrorReporter.shared.report(AppError(.inputDeviceMissing, deviceUID), surface: .banner)
                }
            }
            return
        }
        if !input.isRunning {
            restartInput()      // device came back, or a failed start is retried
        } else if device.sampleRate > 0 && abs(device.sampleRate - input.sampleRate) > 1 {
            restartInput()      // the clock master changed the sample rate
        } else if HostClock.now() - input.lastCallback > 1.5 {
            ErrorReporter.shared.report(AppError(.inputStalled, device.name), surface: .banner)
            restartInput()
        }
    }

    private func refreshDevices() {
        let list = AudioDevices.inputs()
        if list != devices { devices = list }
        let dests = MIDIOut.destinations()
        if dests != destinations { destinations = dests }
    }

    func stop() {
        senderRunning = false
        input.stop()
        testSource.stop()
        timers.forEach { $0.invalidate() }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
