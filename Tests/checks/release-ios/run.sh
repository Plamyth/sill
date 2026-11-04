#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
source Scripts/release-ios.sh
mkdir -p .build/checks/release-ios
scratch="$(mktemp -d "$root/.build/checks/release-ios/fixture.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
passed=0 failed=0

result() {
    if [ "$2" = "$3" ]; then
        echo "PASS $1: $2"
        passed=$((passed + 1))
    else
        echo "FAIL $1: expected $3, got $2"
        failed=$((failed + 1))
    fi
}

xcodebuild() {
    [ "$*" = -version ] || { echo "Unexpected xcodebuild command: $*" >&2; return 99; }
    if [ -n "$selected_xcode" ]; then
        printf 'Xcode %s\nBuild version fixture\n' "$selected_xcode"
    fi
}

for selected_xcode in 26.4 27.0 27.1 28.0 ''; do
    expected=reject
    case "$selected_xcode" in 27.0|27.1) expected=accept ;; esac
    problem="$(xcode_problem)"
    actual=accept
    if [ -n "$problem" ]; then actual=reject; fi
    result "Xcode ${selected_xcode:-missing}" "$actual" "$expected"
done

app="$scratch/Sill.app"
mkdir "$app"
python3 - "$app/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "com.ambrion.sillcanvas.ipad",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "ITSAppUsesNonExemptEncryption": False,
        "NSLocalNetworkUsageDescription": "fixture",
        "NSBonjourServices": ["_sill._tcp"],
        "NSCameraUsageDescription": "fixture",
        "DTPlatformVersion": "27.0",
    }, output)
PY
cp iOSClient/PrivacyInfo.xcprivacy "$app/PrivacyInfo.xcprivacy"
selected_xcode=27.1
for sdk in 26.4 27.0 27.1 unknown ''; do
    expected=reject
    case "$sdk" in 27.0|27.1) expected=accept ;; esac
    /usr/libexec/PlistBuddy -c "Set :DTPlatformVersion $sdk" "$app/Info.plist"
    actual=accept
    if ! (check_app "$app" 1.0 1) >"$scratch/check.log" 2>&1; then actual=reject; fi
    result "App SDK ${sdk:-missing} with Xcode 27.1" "$actual" "$expected"
    if [ "$actual" != "$expected" ]; then cat "$scratch/check.log"; fi
done

/usr/libexec/PlistBuddy -c 'Set :DTPlatformVersion 27.0' "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier me.saffer.sill' "$app/Info.plist"
actual=accept
if ! (check_app "$app" 1.0 1) >"$scratch/check.log" 2>&1; then actual=reject; fi
result 'Wrong app identity' "$actual" reject

uncommitted_changes() { echo ' M iOSClient/Info.plist'; }
actual=accept
if ! (check_committed '--upload') >"$scratch/check.log" 2>&1; then actual=reject; fi
result 'Upload from dirty source' "$actual" reject

echo "$passed passed, $failed failed; archive/export/upload not invoked"
[ "$failed" = 0 ]
