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

    /// Polarity-bit results for the last 16 otherwise-valid frames, newest in
    /// bit 0 (1 = balanced). Kept across silence: it describes the generator.
    private var polarityHistory: UInt16 = 0
    private var polarityFrames = 0
    /// Whether frames with an unbalanced polarity bit are rejected. On from
    /// the start, so corruption is caught from the first frame; see
    /// `notePolarity` for when it switches off and back on.
    private(set) var checkingPolarity = true

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
        let dropFrame = field(10, 1) == 1
        // Drop-frame labels ;00 and ;01 do not exist at the start of minutes
        // other than each tenth minute.
        guard !dropFrame || tc.seconds != 0 || tc.minutes.isMultiple(of: 10) || tc.frames >= 2
        else { syncErrors += 1; return }
        // The phase-correction bit makes the number of zero bits in an LTC
        // frame even (and, with 80 bits, the number of ones too). A single
        // corrupt data bit can still be valid BCD, so check this before it can
        // become a timecode jump or influence rate detection.
        let balanced = (dataReg.nonzeroBitCount + syncReg.nonzeroBitCount).isMultiple(of: 2)
        notePolarity(balanced)
        guard balanced || !checkingPolarity else { syncErrors += 1; return }
        framesDecoded += 1
        onFrame(LTCFrame(timecode: tc, dropFrameFlag: dropFrame, endSample: t))
    }

    /// The spec says to set the polarity bit, but it exists to keep the
    /// waveform's phase consistent, not to detect errors, and nothing forces a
    /// generator to set it. One that never does leaves roughly every other
    /// frame unbalanced; rejecting those would drop half the frames and never
    /// lock. So the check switches off once 3 of the source's last 8 frames
    /// are unbalanced (corruption alone almost never does that), and back on
    /// after 16 balanced frames in a row, which such a generator can't produce.
    private func notePolarity(_ balanced: Bool) {
        polarityHistory = (polarityHistory << 1) | (balanced ? 1 : 0)
        polarityFrames = min(polarityFrames + 1, 16)
        if checkingPolarity {
            let recent = min(polarityFrames, 8)
            let unbalanced = recent - (polarityHistory & ((1 << recent) - 1)).nonzeroBitCount
            if unbalanced >= 3 { checkingPolarity = false }
        } else if polarityFrames == 16 && polarityHistory == 0xFFFF {
            checkingPolarity = true
        }
    }
}

/// Works out the frame rate from recent LTC cadence and the drop-frame flag.
/// A few consecutive intervals confirm a new rate; an old high frame number
/// must never override a new source's clock or poison detection after noise.
struct RateDetector {
    private var lastEnd: Double?
    private var candidate: FrameRate?
    private var candidateCount = 0
    private(set) var rate: FrameRate?

    mutating func reset() { self = RateDetector() }

    /// Returns whether this frame can be forwarded using the confirmed rate.
    /// Missing frames and silence break candidate confirmation; a valid label
    /// at the confirmed rate can still re-anchor MTC as soon as LTC returns.
    @discardableResult
    mutating func observe(_ f: LTCFrame, sampleRate: Double) -> Bool {
        let last = lastEnd
        lastEnd = f.endSample
        guard let last else { return false }
        let d = f.endSample - last
        // Only clean one-frame gaps (1/31 s … 1/23 s) count. In particular,
        // don't mistake a skipped frame or an old source's timing for cadence.
        guard d > sampleRate / 31 && d < sampleRate / 23 else {
            candidate = nil
            candidateCount = 0
            return rate.map { f.timecode.frames < $0.framesPerSecond && f.dropFrameFlag == $0.isDropFrame } ?? false
        }
        let speed = sampleRate / d
        let observed: FrameRate
        if speed > 27.5 {
            observed = f.dropFrameFlag ? .fps2997DF : .fps30
        } else if speed > 24.5 {
            observed = .fps25
        } else {
            observed = .fps24
        }
        // A high but valid-BCD frame number is not evidence of a faster rate.
        // Reject labels that cannot exist at the cadence just measured.
        guard f.timecode.frames < observed.framesPerSecond,
              f.dropFrameFlag == observed.isDropFrame else {
            candidate = nil
            candidateCount = 0
            return false
        }

        if observed != candidate {
            candidate = observed
            candidateCount = 1
        } else {
            candidateCount = min(3, candidateCount + 1)
        }
        if observed == rate { return true }
        guard candidateCount >= 3 else { return false }
        rate = observed
        return true
    }
}
