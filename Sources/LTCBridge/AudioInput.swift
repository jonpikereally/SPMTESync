import AudioToolbox
import CoreAudio
import Foundation

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channelNames: [String]      // one per input channel; "" when the driver gives none
    let sampleRate: Double
}

enum AudioDevices {
    static func inputs() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let names = (1...channels).map { channelName(id, $0) ?? "" }
            return InputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "Unnamed device",
                               channelNames: names, sampleRate: nominalSampleRate(id))
        }
    }

    static func device(uid: String) -> InputDevice? {
        inputs().first { $0.uid == uid }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let s = value else { return nil }
        return s.takeRetainedValue() as String
    }

    private static func channelName(_ id: AudioDeviceID, _ channel: Int) -> String? {
        string(id, kAudioObjectPropertyElementName, scope: kAudioObjectPropertyScopeInput,
               element: AudioObjectPropertyElement(channel))
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    /// Device + stream input latency and safety offset, in samples: how long
    /// before the callback's timestamp a sample actually hit the converter.
    static func inputLatencyFrames(_ id: AudioDeviceID) -> UInt32 {
        func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : 0
        }
        var total = u32(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput)
            + u32(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first {
                total += u32(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        return total
    }
}

/// Captures one channel of one input device through an AUHAL unit. The
/// channel map makes the HAL hand us just that channel, so a 64-channel Dante
/// device costs no more than a mono one.
final class AudioInput {
    /// Called on the real-time audio thread: samples, count, host time (seconds)
    /// at which the first sample was captured.
    typealias Handler = (UnsafePointer<Float>, Int, Double) -> Void
    private var onSamples: Handler = { _, _, _ in }

    private(set) var sampleRate: Double = 0
    private(set) var lastCallback: Double = 0
    private var unit: AudioUnit?
    private var buffer = [Float](repeating: 0, count: 16_384)
    private var latencySeconds: Double = 0

    struct StartError: Error { let step: String; let status: OSStatus }

    /// `makeHandler` gets the device's sample rate and returns the callback;
    /// it's installed before the unit starts, so the audio thread never sees
    /// it change.
    func start(device: InputDevice, channel: Int, makeHandler: (Double) -> Handler) throws {
        stop()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw StartError(step: "find AUHAL", status: -1) }
        var au: AudioUnit?
        try ok(AudioComponentInstanceNew(comp, &au), "create AUHAL")
        guard let au else { throw StartError(step: "create AUHAL", status: -1) }
        unit = au

        var one: UInt32 = 1, zero: UInt32 = 0
        try ok(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
        try ok(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable output")
        var dev = device.id
        try ok(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")

        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try ok(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "read device format")
        sampleRate = hw.mSampleRate > 0 ? hw.mSampleRate : AudioDevices.nominalSampleRate(device.id)

        var fmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        try ok(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                    &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set mono float format")
        var map: [Int32] = [Int32(channel)]
        try ok(AudioUnitSetProperty(au, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                    &map, UInt32(MemoryLayout<Int32>.size)), "select channel")
        var maxFrames = UInt32(buffer.count)
        try ok(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                    &maxFrames, 4), "set buffer size")

        var cb = AURenderCallbackStruct(inputProc: { refCon, flags, ts, bus, frames, _ in
            Unmanaged<AudioInput>.fromOpaque(refCon).takeUnretainedValue().render(flags, ts, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try ok(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                    &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "install callback")

        latencySeconds = Double(AudioDevices.inputLatencyFrames(device.id)) / sampleRate
        onSamples = makeHandler(sampleRate)
        try ok(AudioUnitInitialize(au), "initialize")
        try ok(AudioOutputUnitStart(au), "start")
        lastCallback = HostClock.now()
    }

    func stop() {
        guard let au = unit else { return }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        unit = nil
    }

    var isRunning: Bool { unit != nil }

    private func ok(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw StartError(step: step, status: status) }
    }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let au = unit, Int(frames) <= buffer.count else { return noErr }
        return buffer.withUnsafeMutableBufferPointer { buf -> OSStatus in
            var abl = AudioBufferList(mNumberBuffers: 1,
                                      mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4,
                                                            mData: UnsafeMutableRawPointer(buf.baseAddress)))
            let status = AudioUnitRender(au, flags, ts, bus, frames, &abl)
            guard status == noErr else { return status }
            let hostValid = ts.pointee.mFlags.contains(.hostTimeValid)
            let start = (hostValid ? HostClock.seconds(ts.pointee.mHostTime)
                                   : HostClock.now() - Double(frames) / sampleRate) - latencySeconds
            lastCallback = HostClock.now()
            onSamples(buf.baseAddress!, Int(frames), start)
            return noErr
        }
    }
}

/// mach_absolute_time in seconds — the clock CoreAudio timestamps use.
enum HostClock {
    private static let factor: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }()

    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * factor }
    static func ticks(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) / factor) }
    static func now() -> Double { seconds(mach_absolute_time()) }
}
