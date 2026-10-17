# iPad Mac monitor selection

The isolated branch `codex/ipad-monitor-switching-20261017` starts at `3c710f17f8568f13f9f046c6d5c838e944564c9d`. It adds a Korean monitor menu to the landscape and portrait stream bars. The work key is `ipad-monitor-switching-20261017`. The dictation worktree, `InputOverlay.swift`, and `TourOverlay.swift` are outside its ownership.

## Protocol and ownership

The existing `StreamSource.desktop` category remains unchanged. A new enum case carrying a display would force old clients to decode an unknown source. The chosen additive design uses optional `WindowList` fields and kind 211 instead. `SillProtocol.current` stays 1.

The host advertises `displaySelection: 1`, `displays`, `displayInventoryID`, `activeDisplayID`, and `desktopSelectionRequired`. A `DisplaySelection` request contains a display ID and the inventory UUID that advertised it. The client sends it only when version 1 is advertised and only on the connection that supplied the catalog. A host without the capability keeps the existing desktop button. Older clients ignore the new catalog keys.

`WindowCatalog` owns `DisplayInventory` and the selected `SCDisplay`. Built-in displays and external displays matching hardware registry vendor/product/serial information are eligible. Intel `IODisplayConnect` and Apple silicon `IOMobileFramebuffer` records supply that information. Sill virtual displays are excluded. Unknown external hardware is omitted rather than treated as a physical screen. The existing `catalog.display` accessor supplies capture, pointer geometry, fresh input bounds, encoder dimensions, and audio capture. No persistent numeric display ID is stored.

## Switching and invalidation

Each desktop selection first awaits a bounded fresh ScreenCaptureKit inventory read. The host checks the inventory token, display membership, and legacy input pin before committing selection. A refused request keeps the current selection when its inventory is still valid. Requests during a switch are refused and answered with a catalog.

Accepted desktop switches release held device input, rotate the input generation, revoke audio and microphone authority, and create a new video epoch. Capture startup rechecks selection, live display availability, and geometry after its asynchronous start before publishing that epoch. Scoped input from the previous monitor cannot enter the next generation.

A CoreGraphics reconfiguration callback increments a synchronized counter before its main actor task runs. The display accessor rejects an inventory from an older counter. The catalog then invalidates its token and selection, resets desktop video/input admission, revokes audio, and stops an invalid desktop. Polling also compares display identity and geometry. Any display configuration change requires explicit reselection, including arrangements and mode changes. This conservative policy also applies to virtual-display configuration notifications. Window streaming retains its existing source behavior.

Reconnecting hardware, even with the same numeric display ID, cannot reuse a pre-change request. A new iPad client suppresses automatic desktop fallback when reselection is required. Legacy raw-input clients pin the desktop's inventory/display identity until they disconnect or negotiate scoped input. Stopping never clears that pin. Repeating the original desktop remains allowed while its inventory is valid.

## Local verification

`bash Tests/checks/monitor-selection/run.sh` compiles actual protocol, inventory, input fence, and iPad audio-controller sources and runs 41 assertions. It covers stale/missing tokens, unlisted IDs, main-display default, unplug, ID reuse, changed geometry, mixed legacy clients, protocol compatibility, and audio consent revocation on a same-category generation change. It also parses the three edited iOS screen/client files.

`swift build --target SillHostCore --jobs 1` compiles the host with the actual ScreenCaptureKit, CoreGraphics, AppKit, and IOKit interfaces. Existing HALMicrophoneSink and CLT framework-search warnings are unrelated to this feature.

The existing `presentation-epoch` baseline passed 71 assertions using actual extracted input/server/decoder code and inert framework adapters. Mutation runs were omitted to keep local resource use bounded. Its fixture now includes the AudioRouting dependency already required by the base protocol and the new connection/catalog state.

The unsigned generic iOS Debug build passed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath .build/monitor-ios -jobs 1 CODE_SIGNING_ALLOWED=NO build`. No destination device was opened. A read-only CoreGraphics/IOKit check using the actual extracted hardware matcher found two active displays, one built-in and one matched external monitor, with zero unmatched external displays. That check does not validate ScreenCaptureKit capture or iPad input.

The pstack poteto-mode and architect guidance shaped the type sketch, two design alternatives, one serial owner, and final diff review. The Model the Domain principle puts selection and token validity in `DisplayInventory` and a desktop identity in `SourceInputFence.Target`. Subagent tools are unavailable in this session, so the design exploration and code review are sequential self-review. There is no independent review verdict or release approval.

## Physical acceptance still required

The installed host does not acquire monitor selection until this exact feature is reviewed, integrated, and separately installed. This task does not install or launch either app, open device/browser UI, push a branch, or create a PR.

Hardware acceptance must verify each connected monitor's inventory entry and actual video, mixed DPI and negative screen origins, pointer/touch placement, input fencing during rapid switches, portrait and landscape menu layout and touch targets, audio consent and selected-display capture, unplug/reconnect including reused display IDs, mirrored monitors, and legacy mixed-client behavior. Hardware registry coverage for docks and external displays also needs confirmation. These checks are not replaced by compilation or inert tests.
