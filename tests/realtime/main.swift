// Real-time test: the built-in test signal → decoder → MTC generator, on real
// threads and the real host clock, with the sender loop as the app runs it.
// Checks that MTC lands where the LTC says it should and that quarter frames
// are evenly paced — first at the sender, then (when CoreMIDI is reachable,
// i.e. not in a sandbox) through the real MIDIOut as another client hears it.
import CoreMIDI
import Foundation

let seconds = 6.0
let realtime = !CommandLine.arguments.contains("--no-realtime")

/// Same policy as Bridge.makeRealtime.
func makeRealtime() {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let msToTicks = Double(tb.denom) / Double(tb.numer) * 1_000_000
    var policy = thread_time_constraint_policy_data_t(
        period: UInt32(5 * msToTicks), computation: UInt32(0.5 * msToTicks),
        constraint: UInt32(1 * msToTicks), preemptible: 1)
    let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &policy) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_policy_set(pthread_mach_thread_np(pthread_self()),
                              thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
        }
    }
    if r != KERN_SUCCESS { print("  (real-time policy refused: \(r))") }
}
var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("  FAIL: \(what)") }
}

/// Runs the pipeline for `seconds`. Without `midi`, quarter frames are
/// checked as the sender emits them; with it, they go out through the real
/// MIDIOut class and are checked as a CoreMIDI client receives them.
func run(_ rate: FrameRate, midi: MIDIOut?, listenTo: MIDIEndpointRef? = nil, label: String = "through CoreMIDI",
         maxError: Double = 0.15, maxJitterMs: Double = 2) {
    print("real-time, \(rate.label) fps\(midi == nil ? "" : ", \(label)")")
    let gen = MTCGenerator()
    gen.rate = rate
    let lock = NSLock()
    var lastFrame: (fn: Int, end: Double)?
    var samplesSoFar = 0.0, bufferHost = 0.0, bufferBase = 0.0
    let sr = 48_000.0
    let dec = LTCDecoder(sampleRate: sr)
    dec.onFrame = { f in
        let t = bufferHost + (f.endSample - bufferBase) / sr
        lock.lock()
        gen.ltcFrame(f.timecode.frameNumber(rate), endTime: t)
        lastFrame = (f.timecode.frameNumber(rate), t)
        lock.unlock()
    }
    let source = TestSignalSource()
    source.start(rate: rate, sampleRate: sr) { ptr, n, host in
        bufferHost = host
        bufferBase = samplesSoFar
        dec.process(ptr, count: n)
        samplesSoFar += Double(n)
    }

    // What a receiver sees. Guarded by `rx`, since CoreMIDI delivers on its own thread.
    let rx = NSLock()
    var qfTimes: [Double] = []
    var pieces = [Int](repeating: 0, count: 8)
    var errors: [Double] = []
    var lastSeq: Int?
    var seqJumps = 0
    func observe(_ byte: UInt8, at t: Double) {
        lock.lock(); let anchor = lastFrame; let speed = 1 / gen.frameDuration; lock.unlock()
        rx.lock(); defer { rx.unlock() }
        qfTimes.append(t)
        let piece = Int(byte >> 4)
        pieces[piece] = Int(byte & 0x0F)
        guard piece == 7, let a = anchor else { return }
        let tc = Timecode(hours: pieces[6] | (pieces[7] & 1) << 4, minutes: pieces[4] | pieces[5] << 4,
                          seconds: pieces[2] | pieces[3] << 4, frames: pieces[0] | pieces[1] << 4)
        let v = tc.frameNumber(rate)
        errors.append(Double(a.fn + 1) + (t - a.end) * speed - (Double(v) + 1.75))
        if let s = lastSeq, v != s + 2 { seqJumps += 1 }
        lastSeq = v
    }

    var client = MIDIClientRef(), port = MIDIPortRef()
    if midi != nil {
        MIDIClientCreateWithBlock("LTC Bridge test receiver" as CFString, &client) { _ in }
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { list, _ in
            let now = HostClock.now()
            for packet in list.unsafeSequence() {
                let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(Int(packet.pointee.length))) }
                var i = 0
                while i < bytes.count {
                    if bytes[i] == 0xF1, i + 1 < bytes.count { observe(bytes[i + 1], at: now); i += 2 } else { i += 1 }
                }
            }
        }
        // Listen to this test's own port, not by name: a running copy of the
        // app owns another source called "LTC Bridge".
        MIDIPortConnectSource(port, listenTo ?? midi!.sourceEndpoint, nil)
    }

    let stopAt = HostClock.now() + seconds
    let done = DispatchSemaphore(value: 0)
    let sender = Thread {
        if realtime { makeRealtime() }
        while HostClock.now() < stopAt {
            let now = HostClock.now()
            lock.lock()
            let (messages, next) = gen.poll(now: now)
            lock.unlock()
            if let midi {
                if !messages.isEmpty { midi.send(messages) }
            } else {
                let sentAt = HostClock.now()
                for m in messages where m.count == 2 { observe(m[1], at: sentAt) }
            }
            let wake = min(next, now + 0.005)
            if wake > now { mach_wait_until(HostClock.ticks(wake)) }
        }
        done.signal()
    }
    sender.qualityOfService = .userInteractive
    sender.start()
    done.wait()
    source.stop()
    usleep(50_000)
    if midi != nil { MIDIPortDispose(port); MIDIClientDispose(client) }

    rx.lock(); defer { rx.unlock() }
    let sortedErr = errors.map(abs).sorted()
    let expected = 1 / rate.nominalSpeed / 4
    var gaps: [Double] = []
    for i in 1..<max(1, qfTimes.count) where qfTimes[i] - qfTimes[i - 1] < expected * 3 {
        gaps.append(abs(qfTimes[i] - qfTimes[i - 1] - expected) * 1000)
    }
    gaps.sort()
    let worst = sortedErr.last ?? .infinity
    let jitter = gaps.last ?? .infinity
    if !sortedErr.isEmpty && !gaps.isEmpty {
        print("  \(dec.framesDecoded) LTC frames, \(dec.syncErrors) sync errors, \(errors.count) MTC sequences")
        print("  position error: p50 \(String(format: "%.3f", sortedErr[sortedErr.count / 2])), worst \(String(format: "%.3f", worst)) frames")
        print("  quarter-frame spacing error: p50 \(String(format: "%.2f", gaps[gaps.count / 2])), p99 \(String(format: "%.2f", gaps[gaps.count * 99 / 100])), worst \(String(format: "%.2f", jitter)) ms")
    }
    check(errors.count > Int(seconds * rate.nominalSpeed / 2) - 10, "too few MTC sequences (\(errors.count))")
    check(worst < maxError, "MTC off by \(worst) frames")
    check(jitter < maxJitterMs, "quarter-frame jitter \(jitter) ms")
    check(seqJumps == 0, "\(seqJumps) discontinuities in the MTC sequence")
    check(dec.syncErrors <= 1, "\(dec.syncErrors) sync errors on a clean signal")
}

for rate in [FrameRate.fps25, .fps2997DF] { run(rate, midi: nil) }

do {
    let midi = try MIDIOut()
    run(.fps30, midi: midi)

    // Network MIDI: turn the session on, connect it to itself over
    // localhost, and listen on its source — MTC makes a real RTP-MIDI
    // round trip.
    let net = NetworkMIDI()
    var up = net.enable()
    for _ in 0..<15 where !up { usleep(200_000); up = net.isEnabled }
    if !net.sessionExists && !up {
        print("network MIDI: skipped — this Mac has no network session yet (create one in Audio MIDI Setup → MIDI Network Setup)")
    } else if up {
        print("network MIDI session “\(net.name)” on port \(net.port)")
        midi.setNetworkDestination(net.destination)
        check(net.connect(host: "127.0.0.1", port: net.port), "couldn't add a loopback connection")
        usleep(1_500_000)   // let the RTP-MIDI handshake finish
        print("  peers: \(net.peers.map { "\($0.address):\($0.port)" })")
        run(.fps25, midi: midi, listenTo: MIDINetworkSession.default().sourceEndpoint(), label: "over network MIDI (loopback)",
            maxError: 0.25, maxJitterMs: 5)
        midi.setNetworkDestination(0)
        for p in net.peers where p.address == "127.0.0.1" { net.disconnect(p) }
        net.disable()
    } else {
        check(false, "network MIDI session wouldn't turn on")
    }
} catch {
    print("CoreMIDI: couldn't create the MIDI source (\(error)) — expected inside Claude's sandbox; run ./test.sh from Terminal to include it.")
}

print(failures == 0 ? "\nReal-time tests passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
