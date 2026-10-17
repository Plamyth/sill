#!/bin/bash
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -parse-as-library -emit-module -emit-object -whole-module-optimization -module-name StreamProtocol \
    Sources/StreamProtocol/*.swift -emit-module-path "$out/StreamProtocol.swiftmodule" -o "$out/StreamProtocol.o"
swiftc -I "$out" Sources/SillHost/DisplayInventory.swift Sources/SillHost/SourceInputFence.swift \
    iOSClient/IPadRemoteAudioController.swift "$here/main.swift" \
    "$out/StreamProtocol.o" -o "$out/check"
"$out/check"
swiftc -frontend -parse iOSClient/StreamClient.swift iOSClient/StreamScreen.swift iOSClient/PortraitStreamScreen.swift
