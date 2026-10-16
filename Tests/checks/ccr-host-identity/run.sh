#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc -parse-as-library -package-name Sill \
    "$root/Sources/SillHost/KeychainIdentityNamespace.swift" \
    "$root/Tests/checks/ccr-host-identity/main.swift" -o "$temporary/check"
"$temporary/check"
