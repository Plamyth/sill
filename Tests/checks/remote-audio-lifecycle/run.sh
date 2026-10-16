#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library \
  "$root/Sources/SillHost/RemoteAudioStopGate.swift" "$here/main.swift" \
  -o "$out/check"
"$out/check"
