# LTC Bridge

LTC (audio) → MTC (virtual MIDI source "LTC Bridge") for Logic Pro. Window
app, plain Swift + AppKit + SwiftUI, built with `swiftc` (not `swift build`).
Bundle id `com.jonpike.ltcbridge`, installs to `~/Applications/LTC Bridge.app`.
GitHub: https://github.com/jonpikereally/SPMTESync (public, branch main; the
repo name is Jon's choice, the app is still "LTC Bridge"). The updater reads
`updates/latest.json` there. The Dropbox folder is not a checkout: push from a
scratch clone, and diff against origin/main first in case Jon edited on GitHub.

## Layout

- `Timecode.swift` — FrameRate (MTC rate codes 0–3), drop-frame math.
- `LTCDecoder.swift` — biphase-mark decoder (adaptive bit period, zero-crossing
  interpolation, exact-80-bit sync check) + `RateDetector`.
- `MTCGenerator.swift` — pure, clock-injected model: LTC frames re-anchor the
  position; `poll(now:)` returns quarter frames due. Freewheel, relocate
  (full-frame) on jumps, midnight wrap. All timing tests drive this.
- `LTCEncoder.swift` — streaming LTC generator + `TestSignalSource` (the
  in-app Test mode).
- `AudioInput.swift` — AUHAL, one channel via ChannelMap; `HostClock`.
- `MIDIOut.swift` — virtual source + optional extra destination, and
  `NetworkMIDI` (the default MIDINetworkSession: RTP-MIDI to other Macs /
  rtpMIDI on Windows).
- `Bridge.swift` — wiring, settings, watchdog, real-time sender thread.
- `Resources/AppIcon.icns` — committed; regenerate with `tools/make-icon.swift`
  (renders the PNGs) + `tools/make-icns.py` (packs them; `iconutil` doesn't
  run in Claude's sandbox, though it does read the result in a normal shell).
- `Updater.swift` / `Errors.swift` — copied from PasteStack (LB- codes;
  swap script resets the Microphone TCC grant).

## Traps

- The sender thread MUST get `THREAD_TIME_CONSTRAINT_POLICY`. Without it,
  quarter-frame jitter measured 11–18 ms; with it, 0.02–0.1 ms. LB-304 reports
  a refusal.
- The audio handler is installed before `AudioOutputUnitStart` (via the
  `makeHandler` factory) so the IO thread never reads a closure mid-swap.
- CoreMIDI and AppKit don't work inside Claude's sandbox: `./test.sh` skips the
  CoreMIDI round trip there; run it from the terminal panel for the full test.
- Mic permission is required even for line inputs; without it the HAL
  delivers silence. Ad-hoc rebuilds invalidate the grant
  (`tccutil reset Microphone com.jonpike.ltcbridge`).
- `MIDINetworkSession.default()` can only switch on a session that already
  exists; sessions are created in Audio MIDI Setup → MIDI Network Setup. With
  none, its name is empty and `isEnabled` stays false (LB-307). Jon's Mac had
  none as of Oct 21 2026, so the network loopback test skips until one exists.
- Every new error code goes in `Errors.swift` and `ERRORS.md`; release.sh
  refuses to build otherwise.
