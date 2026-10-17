#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
out="${TMPDIR:-/tmp}/sill-ipad-mic-gate-$$"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT
cd "$root"
swift build --target StreamProtocol -c debug -j 2 >/dev/null
bin_path="$(swift build --show-bin-path)"
swiftc -I "$bin_path" iOSClient/IPadMicrophonePCM.swift \
  iOSClient/IPadMicrophoneCapture.swift \
  iOSClient/IPadMicrophoneFrameGate.swift \
  Tests/checks/ipad-microphone-frame-gate/main.swift \
  "$bin_path/StreamProtocol.o" -o "$out/check"
"$out/check"
