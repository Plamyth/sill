#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/vision-test-destinations.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 5 -emit-library -emit-module -module-name StreamProtocol \
    "$root/Sources/StreamProtocol/TestDestinations.swift" \
    -emit-module-path "$scratch/StreamProtocol.swiftmodule" -o "$scratch/libStreamProtocol.dylib"
xcrun swiftc -swift-version 5 -I "$scratch" -L "$scratch" -lStreamProtocol \
    -Xlinker -rpath -Xlinker "$scratch" \
    "$root/visionOSClient/VisionTestDestinations.swift" "$here/main.swift" -o "$scratch/check"
"$scratch/check" "$here/catalog.json"
