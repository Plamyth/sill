#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
python3 "$here/wiring.py" "$root/Sources/SillHost/StreamCoordinator.swift"
python3 "$here/off_body.py" "$root/Sources/SillHost/StreamCoordinator.swift" "$out"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library \
  "$root/Sources/SillHost/RemoteAudioCaptureLifecycle.swift" "$here/main.swift" \
  -o "$out/check"
"$out/check"
