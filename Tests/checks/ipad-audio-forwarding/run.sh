#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
out="${1:?승인된 외장 검사 출력 경로 필요}"
mkdir -p "$out"
cd "$root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -emit-library -emit-module -module-name StreamProtocol Sources/StreamProtocol/*.swift \
    -module-cache-path "$out/cache" -o "$out/libStreamProtocol.dylib" -emit-module-path "$out/StreamProtocol.swiftmodule"
xcrun swiftc -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    -module-cache-path "$out/cache" iOSClient/IPadDesiredAudio.swift iOSClient/IPadAudioForwarding.swift \
    Tests/checks/ipad-audio-forwarding/main.swift -o "$out/check"
"$out/check"
