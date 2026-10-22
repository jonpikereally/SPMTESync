#!/bin/zsh
# Headless regressions for timecode, source lifecycle, MIDI recovery, and
# installer rollback, followed by a real-time run of the test-signal pipeline.
set -e
cd "$(dirname "$0")"
CACHE="${TMPDIR:-/tmp}/ltcbridge-modcache"
mkdir -p "$CACHE"
CORE=(Sources/LTCBridge/Timecode.swift Sources/LTCBridge/LTCDecoder.swift Sources/LTCBridge/MTCGenerator.swift
      Sources/LTCBridge/LTCEncoder.swift Sources/LTCBridge/AudioInput.swift)
swiftc -O -module-cache-path "$CACHE" -o "$CACHE/ltcbridge-tests" $CORE Sources/LTCBridge/MIDIOut.swift tests/unit/main.swift
swiftc -O -module-cache-path "$CACHE" -o "$CACHE/ltcbridge-realtime" $CORE Sources/LTCBridge/MIDIOut.swift tests/realtime/main.swift
swiftc -O -module-cache-path "$CACHE" -o "$CACHE/ltcbridge-lifecycle" $CORE Sources/LTCBridge/MIDIOut.swift tests/lifecycle/main.swift
swiftc -O -module-cache-path "$CACHE" -o "$CACHE/ltcbridge-recovery" $CORE Sources/LTCBridge/MIDIOut.swift Sources/LTCBridge/Bridge.swift Sources/LTCBridge/Errors.swift tests/bridge/main.swift
"$CACHE/ltcbridge-tests"
"$CACHE/ltcbridge-lifecycle"
"$CACHE/ltcbridge-recovery"
python3 tests/updater/test_installer.py
echo
"$CACHE/ltcbridge-realtime"
