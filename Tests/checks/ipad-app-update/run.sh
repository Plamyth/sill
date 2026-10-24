#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
output_dir="${1:-$PWD/.build/checks/ipad-app-update}"
mkdir -p "$output_dir"
swiftc -warnings-as-errors -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$output_dir/module-cache" \
  iOSClient/IPadAppUpdate.swift iOSClient/IPadAppUpdateController.swift iOSClient/SillLinks.swift \
  Tests/checks/ipad-app-update/main.swift -o "$output_dir/checks"
"$output_dir/checks" "$output_dir"
python3 -B Tests/checks/ipad-app-update/metadata.py "$output_dir"
