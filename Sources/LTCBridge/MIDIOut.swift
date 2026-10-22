import CoreMIDI
import Foundation

struct MIDIDestinationInfo: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
}

/// Publishes MTC on a virtual MIDI source called "LTC Bridge" (Logic and any
/// other app on this Mac see it as an input, no IAC bus needed), and can also
/// copy it to one existing destination — an IAC bus, a network session or a
/// hardware MIDI out to another machine.
///
/// Messages are sent "now" (timestamp 0); the sender thread does the timing.
final class MIDIOut {
    static let sourceName = "LTC Bridge"

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var port = MIDIPortRef()
    private var destination: MIDIEndpointRef = 0
    private var networkDestination: MIDIEndpointRef = 0
    private let lock = NSLock()
    private var packetBuffer = [UInt8](repeating: 0, count: 1024)
    private(set) var sendFailures = 0
    private(set) var lastSendError: OSStatus = noErr

    struct SetupError: Error { let step: String; let status: OSStatus }

    var sourceEndpoint: MIDIEndpointRef { source }

    init() throws {
        var s = MIDIClientCreateWithBlock("LTC Bridge" as CFString, &client) { _ in }
        guard s == noErr else { throw SetupError(step: "create MIDI client", status: s) }
        s = MIDISourceCreate(client, Self.sourceName as CFString, &source)
        guard s == noErr else { throw SetupError(step: "create the “LTC Bridge” MIDI source", status: s) }
        // Keep the same identity across launches so Logic remembers the port.
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, 0x4C54_4342)  // "LTCB"
        s = MIDIOutputPortCreate(client, "MTC Out" as CFString, &port)
        guard s == noErr else { throw SetupError(step: "create MIDI output port", status: s) }
    }

    static func destinations() -> [MIDIDestinationInfo] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            let ep = MIDIGetDestination(i)
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(ep, kMIDIPropertyUniqueID, &uid)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &name)
            guard let n = name?.takeRetainedValue() as String? else { return nil }
            return MIDIDestinationInfo(id: uid, name: n)
        }
    }

    /// Picks the extra destination by unique ID (0 = none). Returns false if
    /// it isn't connected right now.
    @discardableResult
    func setDestination(_ uid: MIDIUniqueID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        destination = 0
        guard uid != 0 else { return true }
        var obj = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(uid, &obj, &type) == noErr, type == .destination else { return false }
        destination = obj
        return true
    }

    /// The network session's destination (0 = don't send over the network).
    func setNetworkDestination(_ endpoint: MIDIEndpointRef) {
        lock.lock(); defer { lock.unlock() }
        networkDestination = endpoint
    }

    func send(_ messages: [[UInt8]]) {
        lock.lock(); defer { lock.unlock() }
        packetBuffer.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            var packet: UnsafeMutablePointer<MIDIPacket>? = MIDIPacketListInit(list)
            for m in messages {
                guard let p = packet else { break }
                packet = MIDIPacketListAdd(list, raw.count, p, 0, m.count, m)
            }
            var s = MIDIReceived(source, list)
            if s == noErr, destination != 0 { s = MIDISend(port, destination, list) }
            if s == noErr, networkDestination != 0 { s = MIDISend(port, networkDestination, list) }
            if s != noErr { sendFailures += 1; lastSendError = s }
        }
    }
}

/// Apple's network MIDI (RTP-MIDI): the same session as Audio MIDI Setup →
/// MIDI Network Setup. Anything sent to its destination goes to every
/// connected peer — other Macs, or Windows PCs running rtpMIDI — so MTC can
/// reach a machine that has no audio or MIDI cable to this one.
final class NetworkMIDI {
    struct Peer: Hashable {
        let name: String
        let address: String
        let port: Int
    }

    private let session = MIDINetworkSession.default()
    /// Whether the session was already on before we touched it, so turning
    /// network output off doesn't switch off a session the user set up.
    private var wasEnabledBefore: Bool?

    static let defaultPort = 5004

    var isEnabled: Bool { session.isEnabled }
    /// macOS can only switch on a session that exists, and sessions are
    /// created in Audio MIDI Setup. Until one has been, the default session
    /// has no name and stays disabled whatever we set.
    var sessionExists: Bool { !session.networkName.isEmpty || session.isEnabled }
    var name: String { session.networkName }
    var port: Int { Int(session.networkPort) }
    var destination: MIDIEndpointRef { session.destinationEndpoint() }

    var peers: [Peer] {
        session.connections().map { Peer(name: $0.host.name, address: $0.host.address, port: Int($0.host.port)) }
            .sorted { $0.name < $1.name }
    }

    /// Turns the session on and lets anyone connect. Returns false if macOS
    /// wouldn't enable it.
    func enable() -> Bool {
        if wasEnabledBefore == nil { wasEnabledBefore = session.isEnabled }
        session.isEnabled = true
        session.connectionPolicy = .anyone
        return session.isEnabled
    }

    func disable() {
        if wasEnabledBefore == false { session.isEnabled = false }
        wasEnabledBefore = nil
    }

    /// "host", "host:port" or "[v6addr]:port". Returns nil if it can't be parsed.
    static func parse(_ text: String) -> (host: String, port: Int)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            let host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()), (1...65535).contains(p) else { return nil }
            return (host, p)
        }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 { return (t, defaultPort) }
        if parts.count == 2, !parts[0].isEmpty, let p = Int(parts[1]), (1...65535).contains(p) {
            return (String(parts[0]), p)
        }
        return parts.count > 2 ? (t, defaultPort) : nil   // bare IPv6 address
    }

    /// Adds a connection unless one to the same address and port exists.
    func connect(host: String, port: Int) -> Bool {
        let target = MIDINetworkHost(name: host, address: host, port: port)
        if session.connections().contains(where: { $0.host.hasSameAddress(as: target) }) { return true }
        return session.addConnection(MIDINetworkConnection(host: target))
    }

    func disconnect(_ peer: Peer) {
        for c in session.connections() where c.host.address == peer.address && Int(c.host.port) == peer.port {
            session.removeConnection(c)
        }
    }
}
