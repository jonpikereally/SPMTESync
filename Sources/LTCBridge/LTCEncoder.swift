import Foundation

/// Generates a continuous LTC signal — the app's built-in test signal, so the
/// whole chain into Logic can be checked without the real timecode source.
final class LTCEncoder {
    let rate: FrameRate
    let sampleRate: Double
    private let bitsPerSample: Double
    private var frameNumber: Int
    private var bits = [Int](repeating: 0, count: 80)
    private var bitPos: Double = 0          // position within the current frame, in bits
    private var level: Float = 0.5
    private var lastHalf = 0                // half-bit index we last toggled at

    init(rate: FrameRate, sampleRate: Double, start: Timecode) {
        self.rate = rate
        self.sampleRate = sampleRate
        bitsPerSample = rate.nominalSpeed * 80 / sampleRate
        frameNumber = start.frameNumber(rate)
        loadFrame()
        lastHalf = -1
    }

    private func loadFrame() {
        let tc = Timecode(frameNumber: frameNumber, rate: rate)
        func put(_ v: Int, _ start: Int, _ width: Int) {
            for i in 0..<width { bits[start + i] = (v >> i) & 1 }
        }
        bits = [Int](repeating: 0, count: 80)
        put(tc.frames % 10, 0, 4); put(tc.frames / 10, 8, 2)
        bits[10] = rate.isDropFrame ? 1 : 0
        put(tc.seconds % 10, 16, 4); put(tc.seconds / 10, 24, 3)
        put(tc.minutes % 10, 32, 4); put(tc.minutes / 10, 40, 3)
        put(tc.hours % 10, 48, 4); put(tc.hours / 10, 56, 2)
        let sync = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
        for i in 0..<16 { bits[64 + i] = sync[i] }
        let pcBit = rate == .fps25 ? 59 : 27
        if bits.filter({ $0 == 0 }).count % 2 == 1 { bits[pcBit] ^= 1 }
    }

    func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            // Toggle at every bit start, and mid-bit for a 1.
            let half = Int(bitPos * 2)
            if half != lastHalf {
                lastHalf = half
                if half % 2 == 0 || bits[min(79, half / 2)] == 1 { level = -level }
            }
            out[i] = level
            bitPos += bitsPerSample
            if bitPos >= 80 {
                bitPos -= 80
                frameNumber += 1
                loadFrame()
                lastHalf = -1
            }
        }
    }
}

/// Plays an LTCEncoder in real time into the same handler the audio input
/// uses, in 512-sample blocks like an interface would.
final class TestSignalSource {
    private final class Run {
        private let condition = NSCondition()
        private var running = true
        private var finished = false

        var shouldContinue: Bool {
            condition.lock(); defer { condition.unlock() }
            return running
        }

        func finish() {
            condition.lock(); defer { condition.unlock() }
            finished = true
            condition.broadcast()
        }

        func stopAndWait() {
            condition.lock(); defer { condition.unlock() }
            running = false
            while !finished { condition.wait() }
        }
    }

    private let lifecycleLock = NSLock()
    private var run: Run?

    func start(rate: FrameRate, sampleRate: Double, handler: @escaping AudioInput.Handler) {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        run?.stopAndWait()
        let run = Run()
        self.run = run
        let encoder = LTCEncoder(rate: rate, sampleRate: sampleRate, start: Timecode(hours: 1))
        let thread = Thread {
            defer { run.finish() }
            let block = 512
            var buf = [Float](repeating: 0, count: block)
            let start = HostClock.now()
            var produced = 0.0
            while run.shouldContinue {
                let due = (HostClock.now() - start) * sampleRate
                while run.shouldContinue && produced + Double(block) <= due {
                    buf.withUnsafeMutableBufferPointer { p in
                        encoder.render(into: p.baseAddress!, count: block)
                        handler(p.baseAddress!, block, start + produced / sampleRate)
                    }
                    produced += Double(block)
                }
                usleep(2_000)
            }
        }
        thread.name = "LTC test signal"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Called outside the handler. Waits for any in-flight callback before the
    /// bridge resets the decoder and sample-position bookkeeping.
    func stop() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        run?.stopAndWait()
        run = nil
    }

    deinit { stop() }
}
