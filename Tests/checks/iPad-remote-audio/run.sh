#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 "$here/fixture.py" "$root" "$out"
python3 "$here/player-fixture.py" "$root" "$out"
xcrun swiftc -emit-library -emit-module -module-name StreamProtocol \
  Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/Switcher.swift \
  Sources/StreamProtocol/RemoteAudioSubscription.swift Sources/StreamProtocol/AudioPacket.swift -o "$out/libStreamProtocol.dylib" \
  -emit-module-path "$out/StreamProtocol.swiftmodule"
xcrun swiftc -parse-as-library -I "$out" -L "$out" -lStreamProtocol \
  -Xlinker -rpath -Xlinker "$out" \
  iOSClient/IPadMicrophoneCapture.swift iOSClient/IPadMicrophonePCM.swift \
  iOSClient/IPadAudioAdmission.swift iOSClient/IPadRemoteAudioController.swift "$out/ClientFixture.swift" "$out/PlaybackFixture.swift" "$here/main.swift" -o "$out/check"
"$out/check"
if [[ "${1:-}" == "--mutants" ]]; then python3 "$here/mutants.py" "$root" "$out"; fi
