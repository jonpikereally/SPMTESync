// Deterministic lifecycle and output-failure regressions. No MIDI server,
// microphone permission, or network session is needed.
import CoreMIDI
import Foundation

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures += 1; print("FAIL: \(message)") }
}

print("test source drains its callback before stop returns")
do {
    let source = TestSignalSource()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let stopStarted = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    source.start(rate: .fps25, sampleRate: 48_000) { _, _, _ in
        entered.signal()
        release.wait()
        finished.signal()
    }
    check(entered.wait(timeout: .now() + 2) == .success, "source did not call its handler")
    DispatchQueue.global().async {
        stopStarted.signal()
        source.stop()
        stopped.signal()
    }
    check(stopStarted.wait(timeout: .now() + 2) == .success, "stop worker did not start")
    check(stopped.wait(timeout: .now() + 0.1) == .timedOut, "stop returned with a callback still active")
    release.signal()
    check(stopped.wait(timeout: .now() + 2) == .success, "stop did not finish after the handler returned")
    check(finished.wait(timeout: .now()) == .success, "handler did not finish before stop")
    let replacement = DispatchSemaphore(value: 0)
    source.start(rate: .fps30, sampleRate: 48_000) { _, _, _ in replacement.signal() }
    check(replacement.wait(timeout: .now() + 2) == .success, "replacement source did not start")
    source.stop()
    source.stop() // idempotent after the worker has already been drained
}

final class FakeMIDI {
    var failCreationAt = ""
    var receiveError: OSStatus = noErr
    var destinationErrors: [MIDIEndpointRef: OSStatus] = [:]
    var delivered: [MIDIEndpointRef] = []
    var disposed: [String] = []
    var packetCounts: [UInt32] = []

    var backend: MIDIOut.Backend {
        MIDIOut.Backend(
            makeClient: { [self] in failCreationAt == "client" ? (-1, 0) : (noErr, 10) },
            makeSource: { [self] _ in failCreationAt == "source" ? (-2, 0) : (noErr, 20) },
            makePort: { [self] _ in failCreationAt == "port" ? (-3, 0) : (noErr, 30) },
            findDestination: { MIDIEndpointRef($0) },
            receive: { [self] endpoint, packets in
                delivered.append(endpoint)
                packetCounts.append(packets.pointee.numPackets)
                return receiveError
            },
            send: { [self] _, endpoint, packets in
                delivered.append(endpoint)
                packetCounts.append(packets.pointee.numPackets)
                return destinationErrors[endpoint] ?? noErr
            },
            disposeClient: { [self] _ in disposed.append("client") },
            disposeSource: { [self] _ in disposed.append("source") },
            disposePort: { [self] _ in disposed.append("port") })
    }
}

print("MIDI sends every independent output despite failures")
do {
    let fake = FakeMIDI()
    let output = try MIDIOut(backend: fake.backend)
    check(output.setDestination(40), "fake extra destination was not selected")
    output.setNetworkDestination(50)

    fake.destinationErrors[40] = -40
    output.send([[0xF1, 0x00]])
    check(fake.delivered == [20, 40, 50], "failed extra destination suppressed healthy network output")
    check(output.sendFailures == 1 && output.lastSendError == -40, "extra-destination failure was not recorded")
    check(fake.packetCounts.allSatisfy { $0 > 0 }, "an output received an empty packet list")

    fake.delivered.removeAll()
    fake.receiveError = -20
    output.send([[0xF1, 0x10]])
    check(fake.delivered == [20, 40, 50], "failed virtual source suppressed other outputs")
    check(output.sendFailures == 2 && output.lastSendError == -20, "first output error was not preserved")

    fake.delivered.removeAll()
    output.setNetworkDestination(40)
    output.send([[0xF1, 0x20]])
    check(fake.delivered == [20, 40], "same extra/network destination received duplicate MTC")
} catch {
    check(false, "fake MIDI setup failed: \(error)")
}

print("MIDI initialization failure and shutdown release all owned resources")
for (step, expected) in [("client", []), ("source", ["client"]), ("port", ["source", "client"])] {
    let fake = FakeMIDI()
    fake.failCreationAt = step
    do {
        _ = try MIDIOut(backend: fake.backend)
        check(false, "\(step) failure unexpectedly succeeded")
    } catch is MIDIOut.SetupError {
        check(fake.disposed == expected, "\(step) failure disposed \(fake.disposed), expected \(expected)")
    } catch {
        check(false, "unexpected setup error: \(error)")
    }
}
do {
    let fake = FakeMIDI()
    var output: MIDIOut? = try MIDIOut(backend: fake.backend)
    check(output?.sourceEndpoint == 20, "fake source was not created")
    output = nil
    check(fake.disposed == ["port", "source", "client"], "shutdown did not release each owned MIDI resource exactly once")
} catch {
    check(false, "fake MIDI setup failed: \(error)")
}

print(failures == 0 ? "Lifecycle tests passed." : "\(failures) lifecycle check(s) failed.")
exit(failures == 0 ? 0 : 1)
