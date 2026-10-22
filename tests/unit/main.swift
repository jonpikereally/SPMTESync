// Headless tests for the LTC decoder and MTC generator. Builds synthetic LTC
// audio, decodes it, drives the generator on a simulated clock, and checks
// the MTC a receiver would reassemble against the true timecode position.
// Run with ./test.sh.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("  FAIL: \(what)") }
}

// MARK: - LTC encoder

struct LTCSignal {
    var rate: FrameRate
    var speed: Double                // real frames per second (29.97 for pulled-down)
    var sampleRate: Double
    var amplitude: Float = 0.5
    var invert = false
    var noise: Float = 0
    var lowpass = false              // round the edges like a long cable would
    /// Timecode segments: (start frame number, number of frames).
    var segments: [(start: Int, count: Int)]
    /// Silent gaps inserted before segment i, in seconds.
    var gapsBefore: [Int: Double] = [:]

    func frameBits(_ tc: Timecode, df: Bool) -> [Int] {
        var b = [Int](repeating: 0, count: 80)
        func put(_ v: Int, _ start: Int, _ width: Int) {
            for i in 0..<width { b[start + i] = (v >> i) & 1 }
        }
        put(tc.frames % 10, 0, 4); put(tc.frames / 10, 8, 2)
        b[10] = df ? 1 : 0
        put(tc.seconds % 10, 16, 4); put(tc.seconds / 10, 24, 3)
        put(tc.minutes % 10, 32, 4); put(tc.minutes / 10, 40, 3)
        put(tc.hours % 10, 48, 4); put(tc.hours / 10, 56, 2)
        let sync = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
        for i in 0..<16 { b[64 + i] = sync[i] }
        // Polarity correction bit: even number of zeros per frame.
        let pcBit = rate.framesPerSecond == 25 ? 59 : 27
        if b.filter({ $0 == 0 }).count % 2 == 1 { b[pcBit] = b[pcBit] == 0 ? 1 : 0 }
        return b
    }

    /// Returns samples plus, for each frame, (frame number, true end time in seconds).
    func render() -> (samples: [Float], frames: [(fn: Int, end: Double)]) {
        let frameDur = 1 / speed
        let bitDur = frameDur / 80
        var edges: [Double] = []
        var truth: [(Int, Double)] = []
        var t = 0.05            // a little silence first
        for (i, seg) in segments.enumerated() {
            if let g = gapsBefore[i] { t += g }
            for k in 0..<seg.count {
                let fn = seg.start + k
                let bits = frameBits(Timecode(frameNumber: fn, rate: rate), df: rate.isDropFrame)
                for (j, bit) in bits.enumerated() {
                    let bt = t + Double(j) * bitDur
                    edges.append(bt)
                    if bit == 1 { edges.append(bt + bitDur / 2) }
                }
                t += frameDur
                truth.append((fn, t))
            }
            edges.append(t)    // final edge closing the last bit of the segment
        }
        let total = Int((t + 0.1) * sampleRate)
        var out = [Float](repeating: 0, count: total)
        var level: Float = invert ? -1 : 1
        var e = 0
        var lp: Float = 0
        var rng = SystemRandomNumberGenerator()
        // Silence wherever there's a gap between segments: track segment spans.
        var spans: [(Double, Double)] = []
        do {
            var tt = 0.05
            for (i, seg) in segments.enumerated() {
                if let g = gapsBefore[i] { tt += g }
                spans.append((tt, tt + Double(seg.count) * frameDur))
                tt += Double(seg.count) * frameDur
            }
        }
        for s in 0..<total {
            let t0 = Double(s) / sampleRate, t1 = Double(s + 1) / sampleRate
            var acc: Float = 0
            var cursor = t0
            while e < edges.count && edges[e] < t1 {
                acc += level * Float(max(0, edges[e] - cursor) * sampleRate)
                cursor = max(cursor, edges[e])
                level = -level
                e += 1
            }
            acc += level * Float((t1 - cursor) * sampleRate)
            let active = spans.contains { t0 >= $0.0 && t0 < $0.1 }
            var v = active ? acc * amplitude : 0
            if lowpass { lp += (v - lp) * 0.35; v = lp }
            if noise > 0 { v += Float.random(in: -noise...noise, using: &rng) }
            out[s] = v
        }
        return (out, truth)
    }
}

// MARK: - MTC receiver (what Logic does with the stream)

struct MTCReceiver {
    var pieces = [Int](repeating: -1, count: 8)
    var expect = 0
    var fullFrames: [(time: Double, tc: Timecode)] = []
    /// (time of piece 7, reassembled frame number, rate code)
    var decoded: [(time: Double, fn: Int, rate: Int)] = []
    var qfTimes: [Double] = []

    mutating func receive(_ msg: [UInt8], at time: Double, rate: FrameRate) {
        if msg.first == 0xF0 {
            let tc = Timecode(hours: Int(msg[5] & 0x1F), minutes: Int(msg[6]), seconds: Int(msg[7]), frames: Int(msg[8]))
            fullFrames.append((time, tc))
            expect = 0
            pieces = [Int](repeating: -1, count: 8)
            return
        }
        guard msg.count == 2, msg[0] == 0xF1 else { return }
        qfTimes.append(time)
        let piece = Int(msg[1] >> 4), value = Int(msg[1] & 0x0F)
        if piece != expect { expect = 0; pieces = [Int](repeating: -1, count: 8); if piece != 0 { return } }
        pieces[piece] = value
        expect = (piece + 1) % 8
        if piece == 7 {
            let tc = Timecode(hours: pieces[6] | (pieces[7] & 1) << 4,
                              minutes: pieces[4] | pieces[5] << 4,
                              seconds: pieces[2] | pieces[3] << 4,
                              frames: pieces[0] | pieces[1] << 4)
            decoded.append((time, tc.frameNumber(rate), value >> 1))
        }
    }
}

// MARK: - Simulation

struct Result {
    var decodedFrames: [LTCFrame] = []
    var receiver = MTCReceiver()
    var detectedRate: FrameRate?
    var maxStatusTransitions: [MTCGenerator.Status] = []
}

/// Runs the signal through decoder + generator on a simulated clock: audio
/// arrives in buffers (plus processing delay), the sender thread polls every
/// `tick` seconds.
func simulate(_ sig: LTCSignal, buffer: Int = 512, latency: Double = 0.003, tick: Double = 0.0005,
              freewheel: Double = 0.4, offset: Double = 0, relocatePause: Double = 0) -> Result {
    let (samples, _) = sig.render()
    let decoder = LTCDecoder(sampleRate: sig.sampleRate)
    let gen = MTCGenerator()
    gen.rate = sig.rate
    gen.freewheel = freewheel
    gen.offset = offset
    gen.relocatePause = relocatePause
    var res = Result()
    var detector = RateDetector()
    decoder.onFrame = { f in
        res.decodedFrames.append(f)
        detector.observe(f, sampleRate: sig.sampleRate)
        gen.ltcFrame(f.timecode.frameNumber(sig.rate), endTime: f.endSample / sig.sampleRate)
    }
    var pos = 0
    var now = 0.0
    var nextPoll = 0.0
    let end = Double(samples.count) / sig.sampleRate + 1.0
    while now < end {
        // Deliver any buffer that has been fully captured (+ latency) by now.
        while pos < samples.count, Double(pos + buffer) / sig.sampleRate + latency <= now {
            let n = min(buffer, samples.count - pos)
            samples.withUnsafeBufferPointer { decoder.process($0.baseAddress! + pos, count: n) }
            pos += n
        }
        if now >= nextPoll {
            let r = gen.poll(now: now)
            for m in r.messages { res.receiver.receive(m, at: now, rate: sig.rate) }
            if res.maxStatusTransitions.last != gen.status { res.maxStatusTransitions.append(gen.status) }
            nextPoll = min(r.nextTime, now + 0.005)
        }
        now += tick
    }
    res.detectedRate = detector.rate
    return res
}

/// True timecode position (frames) at time t for a single continuous segment.
func truePosition(_ sig: LTCSignal, segment: Int, at t: Double) -> Double {
    var start = 0.05
    for i in 0...segment {
        if let g = sig.gapsBefore[i] { start += g }
        if i < segment { start += Double(sig.segments[i].count) / sig.speed }
    }
    return Double(sig.segments[segment].start) + (t - start) * sig.speed
}

func checkDecode(_ sig: LTCSignal, _ res: Result, name: String) {
    let expected = sig.segments.reduce(0) { $0 + $1.count }
    // The first frame of each segment can't be decoded (no 80 bits before its sync).
    check(res.decodedFrames.count >= expected - sig.segments.count,
          "\(name): decoded \(res.decodedFrames.count) of \(expected) frames")
    let truth = sig.render().frames
    var byFN: [Int: Double] = [:]
    for t in truth { byFN[t.fn % sig.rate.framesPerDay] = t.end }
    var worst = 0.0
    for f in res.decodedFrames {
        guard let end = byFN[f.timecode.frameNumber(sig.rate)] else {
            check(false, "\(name): decoded a frame that wasn't sent: \(f.timecode.formatted())"); return
        }
        worst = max(worst, abs(f.endSample / sig.sampleRate - end))
    }
    check(worst < 2 / sig.sampleRate + 0.00002, "\(name): frame-end timing off by \(worst * 1000) ms")
    print("  decoded \(res.decodedFrames.count)/\(expected) frames, timing error ≤ \(String(format: "%.3f", worst * 1000)) ms")
}

/// Every reassembled MTC value should equal the true position minus 1.75
/// frames at the moment piece 7 arrives (receivers add 2 = next quarter).
func checkMTC(_ sig: LTCSignal, _ res: Result, segment: Int, offset: Double = 0, name: String,
              from: Double = 0, to: Double = .infinity) {
    let rx = res.receiver.decoded.filter { $0.time >= from && $0.time <= to }
    check(!rx.isEmpty, "\(name): no MTC reassembled")
    var worst = 0.0
    let day = Double(sig.rate.framesPerDay)
    for d in rx {
        var err = truePosition(sig, segment: segment, at: d.time) + offset * sig.speed - (Double(d.fn) + 1.75)
        err = err.truncatingRemainder(dividingBy: day)
        if err > day / 2 { err -= day }
        if err < -day / 2 { err += day }
        worst = max(worst, abs(err))
        check(d.rate == sig.rate.rawValue, "\(name): MTC rate code \(d.rate), expected \(sig.rate.rawValue)")
        if d.rate != sig.rate.rawValue { break }
    }
    check(worst < 0.1, "\(name): MTC off by \(String(format: "%.3f", worst)) frames")
    print("  \(rx.count) MTC sequences, worst error \(String(format: "%.3f", worst)) frames")
}

func checkQuarterSpacing(_ sig: LTCSignal, _ res: Result, name: String) {
    let ts = res.receiver.qfTimes
    guard ts.count > 10 else { check(false, "\(name): too few quarter frames"); return }
    let expected = 1 / sig.speed / 4
    var worst = 0.0
    for i in 1..<ts.count where ts[i] - ts[i - 1] < expected * 3 {
        worst = max(worst, abs(ts[i] - ts[i - 1] - expected))
    }
    check(worst < 0.0011, "\(name): quarter-frame spacing jitter \(worst * 1000) ms")
    print("  \(ts.count) quarter frames, spacing jitter ≤ \(String(format: "%.2f", worst * 1000)) ms")
}

func tc(_ h: Int, _ m: Int, _ s: Int, _ f: Int, _ r: FrameRate) -> Int {
    Timecode(hours: h, minutes: m, seconds: s, frames: f).frameNumber(r)
}

// MARK: - Cases

print("Timecode math")
for r in FrameRate.allCases {
    var ok = true
    for n in stride(from: 0, to: r.framesPerDay, by: 997) where Timecode(frameNumber: n, rate: r).frameNumber(r) != n {
        ok = false
    }
    check(ok, "frame number round trip at \(r.label)")
}
check(Timecode(frameNumber: tc(0, 0, 59, 29, .fps2997DF) + 1, rate: .fps2997DF) == Timecode(hours: 0, minutes: 1, seconds: 0, frames: 2),
      "29.97 DF skips ;00 and ;01 at the minute")
check(Timecode(frameNumber: tc(0, 9, 59, 29, .fps2997DF) + 1, rate: .fps2997DF) == Timecode(hours: 0, minutes: 10, seconds: 0, frames: 0),
      "29.97 DF keeps ;00 at every tenth minute")

print("Network address parsing")
check(NetworkMIDI.parse("192.168.1.20")! == ("192.168.1.20", 5004), "bare IPv4 gets port 5004")
check(NetworkMIDI.parse(" 10.0.0.5:5010 ")! == ("10.0.0.5", 5010), "IPv4 with port")
check(NetworkMIDI.parse("qsys-core.local:5004")! == ("qsys-core.local", 5004), "host name with port")
check(NetworkMIDI.parse("[fe80::1]:5006")! == ("fe80::1", 5006), "bracketed IPv6 with port")
check(NetworkMIDI.parse("fe80::1")! == ("fe80::1", 5004), "bare IPv6")
check(NetworkMIDI.parse("10.0.0.5:99999") == nil, "port out of range rejected")
check(NetworkMIDI.parse("10.0.0.5:") == nil, "missing port rejected")
check(NetworkMIDI.parse("two words") == nil, "spaces rejected")
check(NetworkMIDI.parse("") == nil, "empty rejected")

let cases: [(String, LTCSignal)] = [
    ("25 fps @ 48 kHz", LTCSignal(rate: .fps25, speed: 25, sampleRate: 48_000,
                                  segments: [(tc(0, 59, 58, 0, .fps25), 250)])),
    ("30 fps @ 44.1 kHz", LTCSignal(rate: .fps30, speed: 30, sampleRate: 44_100,
                                    segments: [(tc(1, 0, 0, 0, .fps30), 300)])),
    ("24 fps @ 96 kHz", LTCSignal(rate: .fps24, speed: 24, sampleRate: 96_000,
                                  segments: [(tc(2, 0, 0, 0, .fps24), 240)])),
    ("29.97 DF across a minute", LTCSignal(rate: .fps2997DF, speed: 30000.0 / 1001, sampleRate: 48_000,
                                           segments: [(tc(0, 0, 55, 0, .fps2997DF), 300)])),
    ("29.97 non-drop (sent as 30)", LTCSignal(rate: .fps30, speed: 30000.0 / 1001, sampleRate: 48_000,
                                              segments: [(tc(1, 0, 0, 0, .fps30), 600)])),
    ("quiet, noisy, inverted, rounded edges", LTCSignal(rate: .fps25, speed: 25, sampleRate: 48_000, amplitude: 0.03,
                                                        invert: true, noise: 0.006, lowpass: true,
                                                        segments: [(tc(1, 0, 0, 0, .fps25), 250)])),
    ("past midnight", LTCSignal(rate: .fps25, speed: 25, sampleRate: 48_000,
                                segments: [(tc(23, 59, 58, 0, .fps25), 100)])),
]

for (name, sig) in cases {
    print(name)
    let res = simulate(sig)
    checkDecode(sig, res, name: name)
    checkMTC(sig, res, segment: 0, name: name)
    checkQuarterSpacing(sig, res, name: name)
    check(res.detectedRate == sig.rate, "\(name): detected \(res.detectedRate?.label ?? "nothing"), expected \(sig.rate.label)")
    check(res.receiver.fullFrames.count == 1, "\(name): \(res.receiver.fullFrames.count) full-frame messages, expected 1")
}

print("big buffers (2048 samples ≈ 43 ms)")
do {
    let sig = cases[0].1
    let res = simulate(sig, buffer: 2048, latency: 0.01)
    checkMTC(sig, res, segment: 0, name: "big buffers")
    checkQuarterSpacing(sig, res, name: "big buffers")
}

print("offset +20 ms")
do {
    let sig = cases[0].1
    let res = simulate(sig, offset: 0.02)
    checkMTC(sig, res, segment: 0, offset: 0.02, name: "offset")
}

print("short dropout (0.2 s) is freewheeled through")
do {
    var sig = LTCSignal(rate: .fps25, speed: 25, sampleRate: 48_000,
                        segments: [(tc(1, 0, 0, 0, .fps25), 100), (tc(1, 0, 4, 5, .fps25), 100)])
    sig.gapsBefore[1] = 0.2       // 5 frames of silence; TC continues as if it had kept running
    let res = simulate(sig)
    check(res.receiver.fullFrames.count == 1, "dropout: \(res.receiver.fullFrames.count) full frames, expected 1 (no relocate)")
    check(res.maxStatusTransitions.contains(.freewheeling), "dropout: never reported freewheeling")
    checkMTC(sig, res, segment: 1, name: "dropout, after", from: 0.05 + 4 + 0.2 + 0.3)
    checkMTC(sig, res, segment: 0, name: "dropout, before", to: 0.05 + 4)
}

print("long dropout (1 s) stops, then relocks")
do {
    var sig = LTCSignal(rate: .fps25, speed: 25, sampleRate: 48_000,
                        segments: [(tc(1, 0, 0, 0, .fps25), 100), (tc(1, 0, 5, 0, .fps25), 100)])
    sig.gapsBefore[1] = 1.0
    let res = simulate(sig)
    check(res.receiver.fullFrames.count == 2, "long dropout: \(res.receiver.fullFrames.count) full frames, expected 2")
    let quiet = res.receiver.qfTimes.filter { $0 > 0.05 + 4 + 0.5 && $0 < 0.05 + 5 }
    check(quiet.isEmpty, "long dropout: \(quiet.count) quarter frames sent after freewheel ran out")
    check(res.maxStatusTransitions.contains(.idle), "long dropout: never went idle")
    checkMTC(sig, res, segment: 1, name: "long dropout, after", from: 0.05 + 5 + 0.3)
}

print("jump (cue change) relocates immediately")
do {
    let sig = LTCSignal(rate: .fps25, speed: 25, sampleRate: 48_000,
                        segments: [(tc(1, 0, 5, 0, .fps25), 100), (tc(2, 0, 0, 0, .fps25), 100)])
    let res = simulate(sig)
    check(res.receiver.fullFrames.count == 2, "jump: \(res.receiver.fullFrames.count) full frames, expected 2")
    if res.receiver.fullFrames.count == 2 {
        let ff = res.receiver.fullFrames[1]
        check(ff.time < 0.05 + 4 + 0.1, "jump: relocate took \(ff.time - 4.05) s")
        check(ff.tc.hours == 2 && ff.tc.minutes == 0 && ff.tc.seconds == 0, "jump: relocated to \(ff.tc.formatted())")
    }
    checkMTC(sig, res, segment: 1, name: "jump, after", from: 0.05 + 4 + 0.2)
}

print("jump with stop-then-restart (0.5 s pause)")
do {
    let sig = LTCSignal(rate: .fps25, speed: 25, sampleRate: 48_000,
                        segments: [(tc(1, 0, 5, 0, .fps25), 100), (tc(2, 0, 0, 0, .fps25), 150)])
    let res = simulate(sig, relocatePause: 0.5)
    let jumpAt = 0.05 + 4.0
    let during = res.receiver.qfTimes.filter { $0 > jumpAt + 0.08 && $0 < jumpAt + 0.5 }
    check(during.isEmpty, "pause: \(during.count) quarter frames sent during the pause")
    check(res.maxStatusTransitions.contains(.relocating), "pause: never reported relocating")
    check(res.receiver.fullFrames.count == 2, "pause: \(res.receiver.fullFrames.count) full frames, expected 2")
    if res.receiver.fullFrames.count == 2 {
        let ff = res.receiver.fullFrames[1]
        check(ff.time >= jumpAt + 0.45 && ff.time < jumpAt + 0.65, "pause: restart came \(ff.time - jumpAt) s after the jump")
        let expect = truePosition(sig, segment: 1, at: ff.time)
        let got = Double(ff.tc.frameNumber(.fps25))
        check(abs(got - expect) <= 1.5, "pause: restarted at \(ff.tc.formatted()), expected about frame \(expect)")
    }
    checkMTC(sig, res, segment: 1, name: "pause, after", from: jumpAt + 0.8)
}

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
