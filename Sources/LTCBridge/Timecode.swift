import Foundation

/// The four rates MTC can express. 29.97 non-drop LTC is sent as 30 — that's
/// how the MTC spec handles it, and receivers expect it.
enum FrameRate: Int, CaseIterable {
    case fps24 = 0
    case fps25 = 1
    case fps2997DF = 2
    case fps30 = 3

    /// Frame numbers per second as counted in the timecode (not the speed).
    var framesPerSecond: Int {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997DF, .fps30: return 30
        }
    }

    var isDropFrame: Bool { self == .fps2997DF }

    var nominalSpeed: Double {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997DF: return 30000.0 / 1001.0
        case .fps30: return 30
        }
    }

    var label: String {
        switch self {
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps2997DF: return "29.97 DF"
        case .fps30: return "30"
        }
    }

    /// Frames in 24 hours, for wrapping past midnight.
    var framesPerDay: Int {
        isDropFrame ? 2_589_408 : framesPerSecond * 86_400
    }
}

struct Timecode: Equatable {
    var hours = 0
    var minutes = 0
    var seconds = 0
    var frames = 0

    /// Frames since 00:00:00:00, counting drop-frame properly.
    func frameNumber(_ rate: FrameRate) -> Int {
        let fps = rate.framesPerSecond
        var n = ((hours * 60 + minutes) * 60 + seconds) * fps + frames
        if rate.isDropFrame {
            let totalMinutes = hours * 60 + minutes
            n -= 2 * (totalMinutes - totalMinutes / 10)
        }
        return n
    }

    init(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, frames: Int = 0) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    init(frameNumber: Int, rate: FrameRate) {
        let day = rate.framesPerDay
        var n = ((frameNumber % day) + day) % day
        if rate.isDropFrame {
            let d = n / 17_982
            let m = n % 17_982
            n += 18 * d + (m > 1 ? 2 * ((m - 2) / 1_798) : 0)
        }
        let fps = rate.framesPerSecond
        frames = n % fps
        seconds = (n / fps) % 60
        minutes = (n / (fps * 60)) % 60
        hours = (n / (fps * 3600)) % 24
    }

    func formatted(dropFrame: Bool = false) -> String {
        String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, dropFrame ? ";" : ":", frames)
    }
}
