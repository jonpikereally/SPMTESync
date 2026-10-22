# LTC Bridge

Turns **LTC** (SMPTE audio timecode) arriving on any audio input — including a
Dante channel via a Dante interface or Dante Virtual Soundcard — into **MTC**
(MIDI Timecode) on a virtual MIDI port, so **Logic Pro** can chase timecode
from a Q-SYS, media server or show controller.

macOS 13+, native Swift, no dependencies.

## How it works

1. Pick the input device and the channel carrying LTC.
2. LTC Bridge decodes the timecode (24, 25, 29.97 DF, 29.97 ND, 30 fps;
   auto-detected), and the readout turns green: **Sending MTC**.
3. MTC goes out on a virtual MIDI source called **LTC Bridge**, which Logic
   sees on its own (no IAC bus needed). It can also be copied to another MIDI
   output under **Also send to**, and sent over the network (below).

MTC timing is modelled, not just relayed: every decoded LTC frame re-anchors
the timecode position, and quarter frames are sent from a real-time thread at
the exact moments they're due. In testing, MTC arrives within 0.005 of a frame
of the incoming LTC, with quarter-frame jitter around 0.1 ms.

- **Freewheel**: if LTC drops out briefly, MTC keeps running for the set
  number of frames, so Logic doesn't stop on a glitch. Past that, MTC stops
  and Logic stops.
- **On a jump**: when the incoming timecode jumps (a cue change, or moving
  to another part of the source), MTC stops for 0.5 s by default, then
  restarts with a full-frame locate at the new position, so Logic stops,
  locates and starts again cleanly. "Keep running, just relocate" sends the
  locate without stopping; that is instant, but Logic can take several seconds
  to settle on the right speed after it.
- **Offset**: shift MTC earlier (+) or later (−) in milliseconds to make up
  for delay elsewhere in the chain.
- **Network**: sends MTC over Apple network MIDI (RTP-MIDI) to other Macs
  or to Windows PCs running [rtpMIDI](https://www.tobias-erichsen.de/software/rtpmidi.html).
  Connect out by typing an address (`192.168.1.20` or `host:port`, default
  port 5004), or let machines connect in: on another Mac, Audio MIDI Setup →
  Window → Show MIDI Network Setup → pick this session → Connect. Addresses you
  add are reconnected automatically. macOS needs one network session to exist
  first: create it once in that same MIDI Network Setup window (click + under
  My Sessions and tick it); LTC Bridge shows this if it's missing (LB-307).
- **Test**: generates LTC internally (from 01:00:00:00) so you can check that
  Logic chases without the real source. Always off when the app opens.
- Reconnects by itself when the input device disappears and comes back, and
  restarts the input if the sample rate changes or audio stalls.
- Rejects LTC frames whose polarity bit doesn't balance, as corrupt, unless
  the source turns out not to set that bit (some generators don't). Then it
  accepts them and the window says so.
- Retries MIDI setup if the MIDI service is unavailable. A failed extra
  destination leaves the other enabled outputs running.
- Updates are validated and staged before replacing the app. Failed replacements
  restore the installed version. A successful update keeps the previous version
  in `~/Library/Application Support/LTC Bridge/Previous Version.noindex`, out of
  the Applications folder and out of Spotlight, so only one LTC Bridge ever
  shows up. If a new version misbehaves, quit it and drag that copy into
  ~/Applications to go back.
- Keeps the Mac awake and out of App Nap while running, and asks before
  quitting while MTC is going out.

## Logic Pro setup

1. File → Project Settings → Synchronization → General: **Sync Mode: MTC**,
   frame rate matching the LTC.
2. Set **Bar position 1 1 1 1 plays at SMPTE** to the song's start timecode.
3. Turn on the **Sync** button in the control bar.

## Build / test / release

```bash
./build.sh      # local build → "LTC Bridge.app"
./test.sh       # decoder + MTC tests, then a real-time run (CoreMIDI part needs a non-sandboxed shell)
UPDATE_NOTES="What changed" ./release.sh   # universal build into updates/, then commit + push
```

Errors carry `LB-xxx` codes; see [ERRORS.md](ERRORS.md).
