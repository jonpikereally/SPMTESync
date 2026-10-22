import Foundation

/// One decoded LTC frame.
struct LTCFrame {
    let timecode: Timecode
    let dropFrameFlag: Bool
    /// Absolute sample position (since the decoder started) of the transition
    /// that ends bit 79 — the exact moment the *next* frame begins.
    let endSample: Double
}

/// Decodes SMPTE LTC (biphase-mark code) from mono float audio.
///
/// Every bit starts with a transition; a "1" has an extra one in the middle.
/// So the decoder only needs the spacing between zero crossings: one long gap
/// is a 0, two short gaps are a 1. The bit period is tracked adaptively, so
/// 24–30 fps at any sample rate works without being told the rate, and the
/// signal's polarity and level don't matter.
///
/// Not thread-safe: call `process` from one thread (the audio thread).
final class LTCDecoder {
    let sampleRate: Double
    var onFrame: (LTCFrame) -> Void = { _ in }

    // Counters read by the UI (plain Ints; torn reads are harmless here).
    private(set) var framesDecoded = 0
    private(set) var syncErrors = 0
    /// Peak level of the input, 0…1, decaying.
    private(set) var level: Float = 0

    private var sampleIndex: Double = 0
    private var dc: Float = 0
    private var env: Float = 0
    private let envDecay: Float
    private let dcCoeff: Float
    private var prev: Float = 0
    private var state: Int = 0              // +1 / -1 once a level has been established
    private var pendingZeroCross: Double?   // where the signal last crossed zero
    private var lastTransition: Double?

    private let initialPeriod: Double
    private var period: Double              // samples per bit
    private var pendingShort = false
    private var consecutiveErrors = 0

    private var syncReg: UInt16 = 0         // the last 16 bits, newest in bit 0
    private var dataReg: UInt64 = 0         // the 64 bits before them, oldest in bit 0
    private var bitsSinceSync = 0

    /// Below this envelope (≈ -50 dBFS) the input counts as silent.
    static let silenceThreshold: Float = 0.003

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        initialPeriod = sampleRate / 2_160      // between 24 fps (1920 bit/s) and 30 fps (2400 bit/s)
        period = initialPeriod
        envDecay = Float(exp(-1.0 / (0.05 * sampleRate)))
        dcCoeff = Float(1.0 - exp(-1.0 / (0.02 * sampleRate)))
    }

    var hasSignal: Bool { env >= Self.silenceThreshold }

    func process(_ samples: UnsafePointer<Float>, count: Int) {
        for i in 0..<count {
            let x = samples[i]
            dc += (x - dc) * dcCoeff
            let y = x - dc
            let a = abs(y)
            env = max(a, env * envDecay)
            let n = sampleIndex + Double(i)

            if env < Self.silenceThreshold {
                if state != 0 { resetLine() }
                prev = y
                continue
            }

            // Remember the exact zero crossing (linear interpolation) so the
            // transition time doesn't depend on the hysteresis threshold.
            if (prev < 0) != (y < 0), prev != y {
                pendingZeroCross = n - 1 + Double(prev / (prev - y))
            }
            let h = env * 0.25
            if state <= 0 && y > h {
                transition(at: pendingZeroCross ?? n, first: state == 0)
                state = 1
            } else if state >= 0 && y < -h {
                transition(at: pendingZeroCross ?? n, first: state == 0)
                state = -1
            }
            prev = y
        }
        sampleIndex += Double(count)
        level = env
    }

    private func resetLine() {
        state = 0
        lastTransition = nil
        pendingZeroCross = nil
        resetBits()
        period = initialPeriod
    }

    private func resetBits() {
        pendingShort = false
        bitsSinceSync = 0
    }

    private func transition(at t: Double, first: Bool) {
        pendingZeroCross = nil
        defer { lastTransition = t }
        guard !first, let last = lastTransition else { return }
        let d = t - last
        let ratio = d / period

        if ratio < 0.3 || ratio > 1.6 {
            error()
            // A run of bad intervals means we drifted onto noise: go back to
            // the neutral starting period, which classifies 24–30 fps alike.
            // (Guessing from the bad intervals let a noisy lead-in push the
            // estimate far enough off to lose the first real frames.)
            if consecutiveErrors > 8 {
                period = initialPeriod
                consecutiveErrors = 0
            }
            return
        }
        consecutiveErrors = 0
        if ratio < 0.75 {
            period += (2 * d - period) * 0.05
            if pendingShort {
                pendingShort = false
                push(1, at: t)
            } else {
                pendingShort = true
            }
        } else {
            period += (d - period) * 0.05
            if pendingShort {
                // A lone half-bit: we were pairing the wrong halves. Drop it;
                // the frame in progress fails its sync check and we realign.
                pendingShort = false
                error()
            }
            push(0, at: t)
        }
    }

    private func error() {
        syncErrors += 1
        consecutiveErrors += 1
        resetBits()
    }

    private func push(_ bit: UInt16, at t: Double) {
        let out = UInt64(syncReg >> 15)
        syncReg = (syncReg << 1) | bit
        dataReg = (dataReg >> 1) | (out << 63)
        bitsSinceSync += 1
        // Sync word, bits 64…79 in transmission order: 0011 1111 1111 1101.
        // Requiring exactly 80 bits since the last sync rejects any frame
        // that had a glitch in it.
        if syncReg == 0x3FFD {
            if bitsSinceSync == 80 { decodeFrame(endingAt: t) }
            bitsSinceSync = 0
        }
    }

    private func field(_ start: Int, _ width: Int) -> Int {
        Int((dataReg >> UInt64(start)) & ((1 << UInt64(width)) - 1))
    }

    private func decodeFrame(endingAt t: Double) {
        let tc = Timecode(hours: field(48, 4) + 10 * field(56, 2),
                          minutes: field(32, 4) + 10 * field(40, 3),
                          seconds: field(16, 4) + 10 * field(24, 3),
                          frames: field(0, 4) + 10 * field(8, 2))
        guard field(0, 4) < 10, field(16, 4) < 10, field(32, 4) < 10, field(48, 4) < 10,
              tc.frames < 30, tc.seconds < 60, tc.minutes < 60, tc.hours < 24
        else { syncErrors += 1; return }
        framesDecoded += 1
        onFrame(LTCFrame(timecode: tc, dropFrameFlag: field(10, 1) == 1, endSample: t))
    }
}

/// Works out the frame rate from the LTC itself: the drop-frame flag, the
/// highest frame number seen, and how fast frames actually arrive.
struct RateDetector {
    private var maxFrame = 0
    private var lastEnd: Double?
    private var samplesPerFrame: Double?
    private(set) var rate: FrameRate?

    mutating func reset() { self = RateDetector() }

    mutating func observe(_ f: LTCFrame, sampleRate: Double) {
        maxFrame = max(maxFrame, f.timecode.frames)
        if let last = lastEnd {
            let d = f.endSample - last
            // Only clean one-frame gaps (1/31 s … 1/23 s) count.
            if d > sampleRate / 31 && d < sampleRate / 23 {
                samplesPerFrame = samplesPerFrame.map { $0 + (d - $0) * 0.2 } ?? d
            }
        }
        lastEnd = f.endSample
        guard let spf = samplesPerFrame else { return }
        let speed = sampleRate / spf
        if f.dropFrameFlag {
            rate = .fps2997DF
        } else if maxFrame >= 25 || speed > 27.5 {
            rate = .fps30
        } else if maxFrame == 24 || speed > 24.5 {
            rate = .fps25
        } else {
            rate = .fps24
        }
    }
}
