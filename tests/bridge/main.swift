import CoreMIDI
import Foundation

// Errors.swift includes version details, but this test does not build an app.
enum AppVersion {
    static let version = "test"
    static let built = "test"
}

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

var received: [[UInt8]] = []
let backend = MIDIOut.Backend(
    makeClient: { (noErr, 1) }, makeSource: { _ in (noErr, 2) }, makePort: { _ in (noErr, 3) },
    findDestination: { _ in nil },
    receive: { _, list in
        for packet in list.unsafeSequence() {
            withUnsafeBytes(of: packet.pointee.data) {
                received.append(Array($0.prefix(Int(packet.pointee.length))))
            }
        }
        return noErr
    },
    send: { _, _, _ in noErr }, disposeClient: { _ in }, disposeSource: { _ in }, disposePort: { _ in })

// A private, empty preferences domain prevents any dependence on saved settings.
let defaults = UserDefaults(suiteName: "LTCBridge.Tests.\(UUID().uuidString)")!
var attempts = 0
let bridge = Bridge(defaults: defaults, midiFactory: {
    attempts += 1
    if attempts == 1 { throw MIDIOut.SetupError(step: "test unavailable service", status: -1) }
    return try MIDIOut(backend: backend)
})
bridge.retryMIDI()
bridge.sampleState()
check(attempts == 1, "first MIDI setup was attempted")
check(bridge.status == .midiFailed, "missing MIDI output has an unavailable status")
check(!bridge.status.sendingMTC && bridge.mtcMessages == 0, "failed setup cannot claim MTC was sent")
bridge.watchdog()
bridge.sampleState()
check(attempts == 2, "watchdog retries failed MIDI setup")
check(bridge.status != .midiFailed, "successful retry clears the unavailable status")
bridge.watchdog()
check(attempts == 2, "watchdog preserves a healthy MIDI output")
bridge.stop()

// Recovery must locate a receiver before resuming an established sequence.
let gen = MTCGenerator()
for n in 0..<4 { gen.ltcFrame(n, endTime: Double(n + 1) / 25) }
_ = gen.poll(now: 0.16)
gen.requestLocate()
let messages = gen.poll(now: 0.17).messages
check(messages.first?.first == 0xF0, "recovered output starts with a full-frame locate")

print(failures == 0 ? "Bridge recovery tests passed." : "\(failures) bridge check(s) failed.")
exit(failures == 0 ? 0 : 1)
