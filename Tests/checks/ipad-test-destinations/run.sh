#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
output_dir="${1:?Pass an isolated temporary build directory}"
mkdir -p "$output_dir"
check_target="$(uname -m)-apple-macosx14.0"
swiftc -target "$check_target" -emit-module -emit-library -module-name StreamProtocol Sources/StreamProtocol/TestDestinations.swift \
  -emit-module-path "$output_dir/StreamProtocol.swiftmodule" -o "$output_dir/libStreamProtocol.dylib"
swiftc -target "$check_target" -parse-as-library -I "$output_dir" -L "$output_dir" -lStreamProtocol \
  iOSClient/TestDestinations/TestDestinationsPolicy.swift \
  iOSClient/TestDestinations/TestDestinationsModel.swift \
  Tests/checks/ipad-test-destinations/main.swift -o "$output_dir/checks"
DYLD_LIBRARY_PATH="$output_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$output_dir/checks"
