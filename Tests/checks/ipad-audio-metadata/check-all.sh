#!/bin/sh
set -eu
out="$PWD/.build/audio-metadata-checks"
mkdir -p "$out"
python3 -B Tests/checks/ipad-audio-metadata/run.py "$out/metadata"
python3 -B Tests/checks/ipad-audio-admission/run.py "$out/admission"
python3 -B Tests/checks/ipad-audio-admission/nearby.py "$out/admission"
swiftc iOSClient/IPadAudioLeaseState.swift iOSClient/IPadAudioLeaseCoordinator.swift Tests/checks/ipad-audio-lease/main.swift -o "$out/lease"
"$out/lease"
mkdir -p "$out/conversion-source"
cp Tests/checks/ipad-microphone-pcm/conversion.swift "$out/conversion-source/main.swift"
swiftc iOSClient/IPadMicrophonePCM.swift iOSClient/IPadMicrophoneCapture.swift "$out/conversion-source/main.swift" -o "$out/conversion"
"$out/conversion"
