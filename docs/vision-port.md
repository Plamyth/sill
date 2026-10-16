# Sill Vision client

## Scope and ownership

The original PC screen remains the workspace. This target reuses Sill's transport, HEVC renderer, TLS identities, pairing and reconnect logic. It adds a native visionOS window and explicit pointer, scroll and keyboard controls. It does not recreate PC apps or their question and approval forms.

The shared fork is https://github.com/Plamyth/sill. Its upstream is https://github.com/Saffsanity/sill. Both platform owners selected release `v0.5.1`, commit `d669a813454603f76074491724ecb4339ad2185c`, to match the installed Mac host. The original Apache-2.0 license remains in `LICENSE`.

The Vision owner maintains branch `codex/vision-sill-20261016`. The iPad owner maintains its separate platform branch. Each owns its platform UI and checkout. Common wire and host changes require one designated owner and commit exchange. The iPad owner accepted the source-only host mouse-release fix on 2026-10-16. No installed host replacement is part of this unit.

## Architecture choice

Two shapes were examined. Retargeting the entire iPad UI keeps its phone layouts, foldable-device APIs and menu assumptions. The unchanged iPad project rejected the generic native visionOS destination. A separate native target reuses the existing client core and renderer while excluding those screens. Source inspection and the successful native Release build support the second shape.

`SillVision.xcodeproj` contains 21 existing client core files, two existing keyboard files, and five native files. `Scripts/make-vision-project.py` regenerates the project with stable identifiers. The native target does not define `DEBUG`, because upstream test hooks refer to the excluded iPad harness screens. `HIDKey.swift` preserves the pure enum from the release's `PortraitStreamScreen.swift`; extracting it into a common file is deferred to a coordinated change.

The native minimum is visionOS 2.5 because the existing TLS implementation uses an API introduced there. Mac and iOS deployment floors remain unchanged. Platform branches replace screen-scale lookup, iPhone haptics and the device name without changing iPad behavior. The shared wire format is unchanged.

## Input and transition contract

SwiftUI `SpatialTapGesture` and `DragGesture` use system-mediated selection. The app does not request raw gaze, hand tracking or a Full Space. Pointer coordinates use the same aspect-fit rectangle as `HEVCDisplayView`. Letterbox taps and invalid geometry are refused. Drag movement clamps to the picture edge. Right-click mode sends no left press. Scroll strokes have explicit begin and end events.

`VisionPointer` owns the drag or scroll state. Ending twice emits no duplicate release. Gesture cancellation, source or geometry changes, scene inactivity and keyboard resignation release held input. Hardware key-up and other release events remain admissible while inactive, while new presses do not.

`StreamClient.afterVisionInputRelease` queues a unique ping after pending input events on the existing network queue. `VisionInputFence` accepts its echo only from the same connection. The UI changes source or disconnects only after that receipt and a fresh connection-identity check. A typed pending transition gives disconnect priority over source selection, including a window closing while its receipt is pending. Tickets prevent an old receipt from consuming a replacement request. The receipt proves the host read the preceding messages, not that a physical action was observed. An eight-second deadline refuses the transition and suspends new input. It does not repeatedly retry. A stale callback cannot act on a replacement connection.

## Preserve the existing iPad and movie

The installed notarized `/Applications/Sill.app` remains version 0.5.1, build 563. A locally rebuilt Mac host can use a different keychain domain, so it must not replace that app during this work. The native client has its own bundle ID, `dev.ambrion.SillVision`, and needs its own normal pairing. Device keys, certificates and saved credentials are not copied from the iPad.

The release host shares one selected source among clients. Native auto-Desktop selection is disabled. An explicit source change displays its effect on the iPad before sending it. No viewport is sent automatically: even `scale: nil` can resize an existing virtual stage because that host interprets it as 1. Native window resizing remains local.

No app launch, device installation, host connection, capture, recording, speaker or microphone routing, AirPlay change, or existing session termination was performed for these compile and headless checks.

## Comparison with Moonlight and Sunshine

| Requirement | Sill 0.5.1 | Moonlight and Sunshine |
| --- | --- | --- |
| Original Mac screen | Desktop and individual-window source already exist | Desktop streaming already exists |
| Vision UX development | Swift client source with Apache-2.0 license; this native target builds | Existing public Vision client candidate; installed-client identity and behavior need verification |
| Remote connection | Paired TLS, Bonjour, USB, Direct Wireless and VPN paths already exist | Existing host and Vision pairing record; remote streaming still needs acceptance |
| Speed and stability | Frame dropping and reconnect code exist; no local latency or recovery benchmark yet | No comparison measurement from this work |
| Mac audio and microphone uplink | No audio pipeline in this release | Output audio exists in the candidate; microphone uplink is not established |
| Independent simultaneous screens | One shared source in this release | Not accepted by this work |
| Other PC platforms | Mac host only | Windows and Linux hosts also supported by Sunshine |

Sill is the preferred foundation for the user's Mac workspace and shared iPad development. It is not yet a complete replacement for Moonlight and Sunshine, and has not been shown faster or more stable. Existing engines remain installed.

Primary references are the [Sill README](https://github.com/Saffsanity/sill), [Moonlight setup guide](https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide), [Vision client source](https://github.com/RikuKunMS2/moonlight-ios-vision), and [Sunshine Mac documentation](https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2getting__started.html). Source inspection is pinned to the release above, with main `5c323e6965b5011809548e5067f9e8e6fa6adf54` used only for comparison. Main has additional reconnect safeguards that are not automatically included in this release branch.

## Verification and remaining acceptance

The unsigned native XROS Release build passed. Built metadata reports platform `VISIONOS`, minimum 2.5, SDK 27.0 and the separate bundle ID. Actual built `Info.plist` readback includes `_sill._tcp` and the Local Network explanation; the first generated-array attempt omitted Bonjour and was corrected with an explicit plist.

38 headless behavior checks passed on Mac mini against streamed source in a temporary RAM volume. They cover aspect fit, letterboxes, invalid geometry, click and drag ordering, cancellation, inactive release classification, same-peer echo receipts, duplicate echoes bounded missing-echo failure, disconnect priority while a source selection waits, and obsolete transition tickets. Sender and receiver hashes matched, source was unchanged, and RAM input and temporary outputs were removed. Swap remained 9736 MB before and after. This is independent compilation and logic validation, not the `codex-source-guard` same-task transfer gate or a Vision gesture test.

The first independent review found two input-lifecycle defects and one viewport effect. These were corrected in the candidate. A second review confirmed those fixes and found a lost disconnect intent during a pending source change. A typed transition fixed it, and an independent narrow review returned CLEAR. The closure verdict and final source/build receipt are kept by the original owner under `work/verification/vision-remote-spatial-20261016` in the Control Room workspace.

Signing, installation, new-device pairing, physical gaze and pinch, Korean IME and hardware shortcuts, actual LAN and off-LAN latency, controlled reconnects, audio and microphone acceptance remain open. The installed host can retain a mouse press on abrupt connection loss; the iPad owner is preparing a separate source fix. The native client does not claim to solve an unreachable host's input state. Complete acceptance still follows E1 through E4 in the original owner's `Docs/VisionRemoteGoal.md`.

Build the reviewable local candidate with:

```sh
python3 Scripts/make-vision-project.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project SillVision.xcodeproj -scheme SillVision -configuration Release -sdk xros -destination 'generic/platform=visionOS' -derivedDataPath .build/vision -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

The command builds only. It does not install, launch or pair.
