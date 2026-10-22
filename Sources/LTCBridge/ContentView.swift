import AppKit
import CoreMIDI
import SwiftUI

/// Window-level state that isn't part of the bridge: the update banner and
/// the background-problem banner.
final class AppState: ObservableObject {
    @Published var updateVersion: String?
    @Published var problem: AppError?
    var installUpdate: () -> Void = {}
    var showProblem: () -> Void = {}
}

struct ContentView: View {
    @ObservedObject var bridge: Bridge
    @ObservedObject var app: AppState
    @State private var showLogicHelp = false
    @State private var connectText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let v = app.updateVersion {
                Banner(color: .blue) {
                    Text("LTC Bridge v\(v) is available.")
                    Spacer()
                    Button("Install…", action: app.installUpdate)
                }
            }
            if let p = app.problem {
                Banner(color: .orange) {
                    Button(action: app.showProblem) {
                        Text("⚠️ Problem \(p.code.rawValue) — \(p.code.summary) Click for details.")
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .help(ErrorReporter.tooltip)
                    Spacer()
                }
            }

            if bridge.testSignal {
                Banner(color: .purple) {
                    Text("TEST SIGNAL — the MTC comes from LTC Bridge's own generator (starting at 01:00:00:00), not from the input.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Stop") { bridge.testSignal = false }
                }
            }

            readout
            LevelMeter(level: bridge.level)
                .frame(height: 8)
                .help("Input level on the selected channel. Aim for the green; LTC decodes fine anywhere from about −40 to 0 dBFS.")

            Divider()
            settings
            Divider()
            stats

            DisclosureGroup("Setting up Logic Pro", isExpanded: $showLogicHelp) {
                Text("""
                1. File → Project Settings → Synchronization → General: set Sync Mode to MTC, and the frame rate to \(bridge.rate?.label ?? "the LTC's rate") fps.
                2. In the same panel, set “Bar position 1 1 1 1 plays at SMPTE” to where the song's timecode starts.
                3. Turn on the Sync button in the control bar (right-click the control bar → Customize to add it).
                4. Logic hears the “\(MIDIOut.sourceName)” MIDI port automatically; no IAC bus needed.
                5. If Logic is consistently early or late, nudge “Offset” here (or Logic's own sync offset).
                """)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var statusColor: Color {
        switch bridge.status {
        case .running: return .green
        case .freewheeling: return .orange
        case .locking: return .yellow
        case .noLTC, .noSignal: return .secondary
        case .noPermission, .noDevice, .inputFailed: return .red
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bridge.display)
                .font(.system(size: 66, weight: .semibold, design: .monospaced))
                .foregroundColor(bridge.status.sendingMTC ? statusColor : .secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("Timecode \(bridge.display)")
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(bridge.status.text)
                    .font(.headline)
                    .help(bridge.status.hasErrorCode ? ErrorReporter.tooltip : "")
                Spacer()
                if let r = bridge.rate {
                    Text("\(r.label) fps\(bridge.rateChoice >= 0 ? " (forced)" : "")")
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label("Input device")
                Picker("", selection: $bridge.deviceUID) {
                    if bridge.selectedDevice == nil {
                        Text(bridge.deviceUID.isEmpty ? "Choose…" : "Not connected").tag(bridge.deviceUID)
                    }
                    ForEach(bridge.devices) { d in
                        Text("\(d.name)  (\(d.channelNames.count) ch)").tag(d.uid)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                label("LTC channel")
                Picker("", selection: $bridge.channel) {
                    let names = bridge.selectedDevice?.channelNames ?? []
                    if bridge.channel >= names.count {
                        Text("\(bridge.channel + 1)").tag(bridge.channel)
                    }
                    ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                        Text(name.isEmpty ? "\(i + 1)" : "\(i + 1) — \(name)").tag(i)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                label("Frame rate")
                Picker("", selection: $bridge.rateChoice) {
                    Text("Auto-detect").tag(-1)
                    ForEach(FrameRate.allCases, id: \.rawValue) { r in
                        Text("\(r.label) fps").tag(r.rawValue)
                    }
                }
                .labelsHidden()
                .help("Auto-detect reads the rate from the LTC. 29.97 non-drop is sent as 30, which is how MTC works.")
            }
            GridRow {
                label("Freewheel")
                Stepper(value: $bridge.freewheelFrames, in: 0...100) {
                    Text("\(bridge.freewheelFrames) frames")
                        .monospacedDigit()
                }
                .help("If the LTC drops out, keep sending MTC this long so Logic doesn't stop on a glitch. When it runs out, Logic stops.")
            }
            GridRow {
                label("Offset")
                HStack {
                    TextField("", value: $bridge.offsetMs, format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $bridge.offsetMs, in: -500...500, step: 1)
                        .labelsHidden()
                    Text("ms")
                    Text(bridge.offsetMs > 0 ? "MTC runs ahead of the LTC" : bridge.offsetMs < 0 ? "MTC runs behind the LTC" : "")
                        .foregroundColor(.secondary)
                        .font(.callout)
                }
                .help("Positive values send MTC early, to make up for delay elsewhere (Dante latency, Logic's own sync delay).")
            }
            GridRow {
                label("Test")
                Toggle("Generate a test LTC signal instead of using the input", isOn: $bridge.testSignal)
                    .help("For checking that Logic chases, without the real timecode source. Uses the forced frame rate, or 25 fps on Auto. Always off when the app opens.")
            }
            GridRow {
                label("MTC out")
                Text("“\(MIDIOut.sourceName)” MIDI port")
                    .help("A virtual MIDI source. Logic and other apps on this Mac see it as a MIDI input.")
            }
            GridRow {
                label("Also send to")
                Picker("", selection: $bridge.extraDestination) {
                    Text("None").tag(MIDIUniqueID(0))
                    if bridge.extraDestination != 0 && !bridge.destinations.contains(where: { $0.id == bridge.extraDestination }) {
                        Text("Not connected").tag(bridge.extraDestination)
                    }
                    ForEach(bridge.destinations) { d in
                        Text(d.name).tag(d.id)
                    }
                }
                .labelsHidden()
                .help("Optional: copy the MTC to another MIDI output, such as a MIDI interface feeding another machine.")
            }
            GridRow {
                label("Network")
                Toggle("Also send MTC over the network (Apple network MIDI / RTP-MIDI)", isOn: $bridge.networkEnabled)
                    .help("Turns on this Mac's network MIDI session and sends MTC to every machine connected to it: other Macs (Audio MIDI Setup) or Windows PCs running rtpMIDI.")
            }
            if bridge.networkEnabled {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem = bridge.networkProblem {
                            HStack(alignment: .top) {
                                Text("⚠️ \(problem.summary) (\(problem.rawValue)) \(problem.hint)")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(ErrorReporter.tooltip)
                                Button("Open Audio MIDI Setup") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                                }
                            }
                        } else if bridge.networkPort == 0 {
                            Text("Starting network MIDI…").font(.callout).foregroundColor(.secondary)
                        }
                        if bridge.networkPort > 0 {
                            Text("Session “\(bridge.networkName)” on port \(String(bridge.networkPort)) · anyone can connect")
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        if bridge.networkPeers.isEmpty && bridge.networkProblem == nil && bridge.networkPort > 0 {
                            Text("Nothing connected yet.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                        ForEach(bridge.networkPeers, id: \.self) { peer in
                            HStack(spacing: 6) {
                                Image(systemName: "network")
                                Text(peer.name == peer.address ? "\(peer.address):\(String(peer.port))"
                                                               : "\(peer.name) (\(peer.address):\(String(peer.port)))")
                                    .font(.callout)
                                Button { bridge.removePeer(peer) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.secondary)
                                    .help("Disconnect, and stop reconnecting to it")
                            }
                        }
                        HStack {
                            TextField("Connect to IP or host[:port]", text: $connectText)
                                .onSubmit(connect)
                            Button("Connect", action: connect)
                                .disabled(connectText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .help("Connect out to a machine on the network, e.g. a Windows PC running rtpMIDI (port 5004 unless you changed it). LTC Bridge reconnects to it automatically.")
                        Text("Other Macs can also connect in: Audio MIDI Setup → Window → Show MIDI Network Setup → pick this session → Connect.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func connect() {
        if bridge.addNetworkHost(connectText) { connectText = "" }
    }

    private var stats: some View {
        HStack(spacing: 18) {
            stat("Frames decoded", bridge.framesDecoded)
            stat("Sync errors", bridge.syncErrors)
            stat("Relocates", bridge.relocates)
            stat("MTC messages", bridge.mtcMessages)
            Spacer()
            if bridge.sampleRate > 0 {
                Text("\(Int(bridge.sampleRate)) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundColor(.secondary).gridColumnAlignment(.trailing)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.body.monospacedDigit())
            Text(title).font(.caption).foregroundColor(.secondary)
        }
    }
}

struct Banner<Content: View>: View {
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack { content }
            .padding(10)
            .background(color.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Peak meter, dBFS scale from −60 to 0.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let db = level > 0 ? 20 * log10(Double(level)) : -60
            let fraction = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(db > -3 ? Color.red : db > -40 ? Color.green : Color.yellow)
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}
