#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
out="${TMPDIR:-/tmp}/sill-ipad-mic-check-$$"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT
swiftc "$root/iOSClient/IPadMicrophonePCM.swift" "$root/Tests/checks/ipad-microphone-pcm/main.swift" -o "$out/pcm"
"$out/pcm"
cp "$root/Tests/checks/ipad-microphone-pcm/conversion.swift" "$out/main.swift"
swiftc "$root/iOSClient/IPadMicrophonePCM.swift" "$root/iOSClient/IPadMicrophoneCapture.swift" \
  "$out/main.swift" -o "$out/conversion"
"$out/conversion"
