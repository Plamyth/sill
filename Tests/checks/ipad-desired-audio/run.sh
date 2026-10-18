#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
out="${1:?Pass an existing owner-approved volatile output directory}"
test -d "$out"
cd "$root"
swiftc -emit-library -emit-module -module-name StreamProtocol \
    Sources/StreamProtocol/*.swift \
    -o "$out/libStreamProtocol.dylib" -emit-module-path "$out/StreamProtocol.swiftmodule"
swiftc -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    iOSClient/IPadDesiredAudio.swift iOSClient/IPadMicrophonePolicy.swift \
    iOSClient/IPadRemoteAudioController.swift Tests/checks/ipad-desired-audio/main.swift -o "$out/desired-audio-check"
"$out/desired-audio-check"
