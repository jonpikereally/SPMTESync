#!/bin/zsh
# Headless tests: decoder + MTC generator against synthetic LTC, then a
# real-time run of the test signal through the same pipeline the app uses.
set -e
cd "$(dirname "$0")"
CACHE="${TMPDIR:-/tmp}/ltcbridge-modcache"
mkdir -p "$CACHE"
CORE=(Sources/LTCBridge/Timecode.swift Sources/LTCBridge/LTCDecoder.swift Sources/LTCBridge/MTCGenerator.swift
      Sources/LTCBridge/LTCEncoder.swift Sources/LTCBridge/AudioInput.swift)
swiftc -O -module-cache-path "$CACHE" -o "$CACHE/ltcbridge-tests" $CORE Sources/LTCBridge/MIDIOut.swift tests/unit/main.swift
swiftc -O -module-cache-path "$CACHE" -o "$CACHE/ltcbridge-realtime" $CORE Sources/LTCBridge/MIDIOut.swift tests/realtime/main.swift
"$CACHE/ltcbridge-tests"
echo
"$CACHE/ltcbridge-realtime"
