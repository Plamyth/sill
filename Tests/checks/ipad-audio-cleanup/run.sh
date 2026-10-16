#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
out="${TMPDIR:-/tmp}/sill-ipad-audio-cleanup-$$"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT
swiftc "$root/iOSClient/IPadAudioLeaseState.swift" \
  "$root/iOSClient/IPadAudioLeaseCoordinator.swift" \
  "$root/Tests/checks/ipad-audio-cleanup/main.swift" -o "$out/check"
"$out/check"
