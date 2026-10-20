#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
route=$(/Users/ambrion/.local/bin/storage-route path development-archive --project BT_CCR --filename "automatic-device-access-$(date -u +%Y%m%dT%H%M%S)-$$")
out=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])' <<< "$route")
mkdir -p "$out/module-cache" "$out/tmp"
printf '검사 출력 경로 %s\n' "$out"
TMPDIR="$out/tmp" xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -typecheck \
    -target arm64-apple-macosx14.0 -module-cache-path "$out/module-cache" \
    "$root/Sources/SillHost/OriginPolicy.swift" \
    "$root/Sources/SillHost/AutomaticDevicePrincipal.swift" \
    "$root/Sources/SillHost/AutomaticSessionAuthorization.swift" \
    "$root/Sources/SillHost/TailnetDeviceAccess.swift"
TMPDIR="$out/tmp" xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -D AUTOMATIC_DEVICE_ACCESS_CONTRACT \
    -whole-module-optimization -target arm64-apple-macosx14.0 \
    -module-cache-path "$out/module-cache" \
    "$root/Sources/SillHost/OriginPolicy.swift" \
    "$root/Sources/SillHost/AutomaticDevicePrincipal.swift" \
    "$root/Sources/SillHost/AutomaticSessionAuthorization.swift" \
    "$root/Sources/SillHost/TailnetDeviceAccess.swift" \
    "$here/Contract.swift" -o "$out/check"
python3 - "$out/check" "$@" <<'PY'
import subprocess, sys
sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
PY
