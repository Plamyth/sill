#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
python3 "$HERE/entry-fixture.py" "$ROOT" "$OUT/EntryHarness.swift"
swiftc -O "$ROOT"/Sources/StreamProtocol/*.swift "$ROOT/Sources/SillHost/PeerCloseTrace.swift" \
    "$OUT/EntryHarness.swift" "$HERE/main.swift" -o "$OUT/check"
"$OUT/check"
