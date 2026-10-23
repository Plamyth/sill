#!/bin/bash
# Package the fork as a separate Mac app. Never install over or launch original Sill.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 0 ]; then
    echo "usage: CCR_SILL_SIGN_IDENTITY='<codesign identity>' CCR_SILL_AUDIO_RUNTIME='<sealed package>' $0" >&2
    exit 2
fi
if [ -z "${CCR_SILL_SIGN_IDENTITY:-}" ]; then
    echo "CCR_SILL_SIGN_IDENTITY is required; ad hoc signatures lose Mac privacy grants on rebuild." >&2
    exit 2
fi
if [ -z "${CCR_SILL_AUDIO_RUNTIME:-}" ]; then
    echo "CCR_SILL_AUDIO_RUNTIME must name the sealed LocalAudioRelay package." >&2
    exit 2
fi
python3 Scripts/package-local-audio-runtime.py --verify "$CCR_SILL_AUDIO_RUNTIME"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product SillMenuBar --jobs 2
swift build -c release --product ProviderPeerVerifier --jobs 2
bin="$(swift build -c release --product SillMenuBar --show-bin-path)/SillMenuBar"
app="$PWD/.build/CCR Sill.app"
stage="$PWD/.build/CCR Sill.app.partial"
rm -rf "$stage"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources" "$stage/Contents/Helpers"
cp "$bin" "$stage/Contents/MacOS/Sill"
cp "$(dirname "$bin")/ProviderPeerVerifier" "$stage/Contents/Helpers/ProviderPeerVerifier"
codesign --force --options runtime --timestamp=none \
    --identifier com.ambrion.sillcanvas.provider-peer-verifier \
    --sign "$CCR_SILL_SIGN_IDENTITY" "$stage/Contents/Helpers/ProviderPeerVerifier"
cp Packaging/Info.plist "$stage/Contents/Info.plist"
cp -R "$CCR_SILL_AUDIO_RUNTIME" "$stage/Contents/Resources/LocalAudioRelay"
python3 Scripts/package-local-audio-runtime.py --verify "$stage/Contents/Resources/LocalAudioRelay"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.ambrion.sillcanvas.mac' "$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName CCR Sill' "$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName CCR Sill' "$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$stage/Contents/Info.plist"
printf 'APPL????' > "$stage/Contents/PkgInfo"
codesign --force --options runtime --timestamp=none --entitlements Packaging/SillDebug.entitlements \
    --sign "$CCR_SILL_SIGN_IDENTITY" "$stage"
codesign --verify --deep --strict "$stage"
actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stage/Contents/Info.plist")"
if [ "$actual" != 'com.ambrion.sillcanvas.mac' ]; then
    echo "Unexpected bundle identifier $actual" >&2
    exit 1
fi
rm -rf "$app"
mv "$stage" "$app"
echo "Packaged $app with isolated bundle identifier $actual; original Sill was not touched."
