import Foundation

/// Turns decoded LTC frames into a correctly paced MTC stream.
///
/// Instead of relaying each LTC frame as it arrives (which would add the audio
/// buffer's latency and jitter), this keeps a model of where the timecode is:
/// every decoded frame re-anchors "position P at time T", and quarter-frame
/// messages are emitted at the exact moments the model says each quarter frame
/// starts. That also makes freewheeling through short dropouts free: the model
/// just keeps running until `freewheel` expires.
///
/// Pure logic with caller-supplied times (seconds on one monotonic clock), so
/// it can be tested without audio or MIDI. Not thread-safe; the caller locks.
final class MTCGenerator {
    enum Status: Equatable {
        case idle           // no timecode
        case locking        // valid frames arriving, not yet trusted
        case running        // sending MTC, LTC present
        case freewheeling   // sending MTC, LTC dropped out
        case relocating     // timecode jumped: MTC paused so the receiver stops, then restarts
    }

    /// Rate written into the MTC. Set by the caller (auto-detected or forced).
    var rate: FrameRate = .fps25
    /// How long to keep sending after LTC stops, in seconds.
    var freewheel: Double = 0.4
    /// Positive = MTC runs ahead of the incoming LTC, to make up for delay
    /// further down the line. Seconds.
    var offset: Double = 0
    /// Consecutive, contiguous LTC frames needed before MTC starts.
    var framesToLock = 3
    /// What to do when the incoming timecode jumps while running. 0 keeps
    /// MTC running and just sends a locate (full-frame) message. Anything
    /// above 0 stops MTC for that many seconds first, so the receiver stops,
    /// then locates and starts again cleanly — the way a tape machine or show
    /// controller would. DAWs that estimate speed from MTC (Logic) can take
    /// seconds to settle after a jump in a running stream.
    var relocatePause: Double = 0

    private(set) var status: Status = .idle
    private(set) var jumps = 0
    /// Measured duration of one frame, seconds (follows the LTC source's clock).
    private(set) var frameDuration: Double = 1.0 / 25

    private var anchorPos: Double = 0       // frames
    private var anchorTime: Double = 0
    private var lastLTCTime: Double = -.infinity
    private var lastLTCFrame: Int?
    private var contiguous = 0

    private var needsFullFrame = true
    private var pausedUntil: Double = -.infinity
    private var nextFrame = 0               // frame of the next quarter-frame slot
    private var nextQuarter = 0             // 0…3 within that frame
    private var secondHalf = false          // sending pieces 4–7 of the sequence
    private var sequenceFrame = 0           // the frame the current 8-piece sequence describes

    /// Feed every decoded LTC frame. `endTime` is when the frame ended, i.e.
    /// when the timecode reached `frameNumber + 1`.
    func ltcFrame(_ frameNumber: Int, endTime: Double) {
        let day = rate.framesPerDay
        if let last = lastLTCFrame, (last + 1) % day == frameNumber % day {
            let measured = endTime - lastLTCTime
            if measured > frameDuration * 0.8 && measured < frameDuration * 1.25 {
                frameDuration += (measured - frameDuration) * 0.1
            }
            contiguous += 1
        } else {
            contiguous = 1
            frameDuration = 1.0 / rate.nominalSpeed
        }
        lastLTCFrame = frameNumber
        lastLTCTime = endTime

        let pos = Double(frameNumber + 1)
        if status == .running || status == .freewheeling || status == .relocating {
            // Compare in a way that survives midnight: differences mod 24h.
            var drift = (anchorPos + (endTime - anchorTime) / frameDuration) - pos
            drift = drift.truncatingRemainder(dividingBy: Double(day))
            if drift > Double(day) / 2 { drift -= Double(day) }
            if drift < -Double(day) / 2 { drift += Double(day) }
            if abs(drift) > 1.5 {
                needsFullFrame = true
                jumps += 1
                if relocatePause > 0 { pausedUntil = endTime + relocatePause }
            }
            anchorPos = pos
            anchorTime = endTime
            status = .running
            // Past midnight the LTC restarts at 0 while our slot counter kept
            // counting; bring the counter into the same day as the anchor.
            let ahead = nextFrame - (frameNumber + 1)
            if ahead > day / 2 { nextFrame -= day; sequenceFrame -= day }
            if ahead < -day / 2 { nextFrame += day; sequenceFrame += day }
        } else if contiguous >= framesToLock {
            anchorPos = pos
            anchorTime = endTime
            needsFullFrame = true
            status = .running
        } else {
            status = .locking
        }
    }

    /// Timecode position (in frames, fractional) that the MTC describes at `time`.
    func position(at time: Double) -> Double {
        anchorPos + (time - anchorTime) / frameDuration + offset / frameDuration
    }

    private func time(ofPosition p: Double) -> Double {
        anchorTime + (p - anchorPos - offset / frameDuration) * frameDuration
    }

    /// Returns the MIDI messages due at `now` and when to call again.
    func poll(now: Double) -> (messages: [[UInt8]], nextTime: Double) {
        switch status {
        case .idle:
            return ([], now + 0.005)
        case .locking:
            if now - lastLTCTime > 0.5 { status = .idle; contiguous = 0; lastLTCFrame = nil }
            return ([], now + 0.005)
        case .running, .freewheeling, .relocating:
            break
        }

        let silence = now - lastLTCTime
        if silence > freewheel + frameDuration * 1.5 {
            status = .idle
            contiguous = 0
            lastLTCFrame = nil
            return ([], now + 0.005)
        }
        if now < pausedUntil {
            status = .relocating
            return ([], min(pausedUntil, now + 0.005))
        }
        status = silence > frameDuration * 1.5 ? .freewheeling : .running

        var out: [[UInt8]] = []
        if needsFullFrame {
            let n = Int(position(at: now).rounded(.up))
            out.append(Self.fullFrame(Timecode(frameNumber: n, rate: rate), rate: rate))
            nextFrame = n
            nextQuarter = 0
            secondHalf = false
            needsFullFrame = false
        }

        while true {
            let t = time(ofPosition: Double(nextFrame) + Double(nextQuarter) / 4)
            if t > now + 0.0002 { return (out, t) }
            if now - t > frameDuration * 2 {
                // We fell badly behind (the machine stalled): relocate rather
                // than burst out a pile of stale quarter frames.
                needsFullFrame = true
                return (out, now)
            }
            if !secondHalf && nextQuarter == 0 { sequenceFrame = nextFrame }
            let piece = (secondHalf ? 4 : 0) + nextQuarter
            out.append([0xF1, Self.quarterFrame(piece, Timecode(frameNumber: sequenceFrame, rate: rate), rate: rate)])
            nextQuarter += 1
            if nextQuarter == 4 {
                nextQuarter = 0
                nextFrame += 1
                secondHalf.toggle()
            }
        }
    }

    // MARK: - MTC message encoding

    static func quarterFrame(_ piece: Int, _ tc: Timecode, rate: FrameRate) -> UInt8 {
        let value: Int
        switch piece {
        case 0: value = tc.frames & 0x0F
        case 1: value = (tc.frames >> 4) & 0x01
        case 2: value = tc.seconds & 0x0F
        case 3: value = (tc.seconds >> 4) & 0x03
        case 4: value = tc.minutes & 0x0F
        case 5: value = (tc.minutes >> 4) & 0x03
        case 6: value = tc.hours & 0x0F
        default: value = ((tc.hours >> 4) & 0x01) | (rate.rawValue << 1)
        }
        return UInt8(piece << 4 | value)
    }

    static func fullFrame(_ tc: Timecode, rate: FrameRate) -> [UInt8] {
        [0xF0, 0x7F, 0x7F, 0x01, 0x01,
         UInt8(rate.rawValue << 5 | tc.hours), UInt8(tc.minutes), UInt8(tc.seconds), UInt8(tc.frames),
         0xF7]
    }
}
