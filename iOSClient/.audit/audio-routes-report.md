# iPad connection audio chooser

Owner is this chat. Task key is `ipad-audio-routes-20261016`. Work is local and uncommitted in the existing iPad worktree, at HEAD `7e0cc53e8eb13a02d07211d11bd86370a028dc0d` plus the preserved remote/retirement patch. Host and Vision source are owned by the user and were not edited.

## Supported behavior

The first admitted foreground stream offers an audio chooser once per connection. Input and output are independent. The input choices are off or this iPad's current microphone to the connected Mac. The output choices are off or the connected Mac's audio to this iPad's current output route. A direction is offered only when the current host/stream advertises the capability required by its existing controller. A host supporting neither direction gets an off-only chooser with a Korean explanation.

Opening, dismissing, or confirming unchanged choices sends no new audio consent. Applying changed choices uses the existing `toggleRemoteAudio` and `toggleIPadMicrophone` paths, including their ACKs, timeouts, capture ownership, and grants. Repeated apply does not toggle a pending request off. A stale peer, stream source, microphone capability scope, backgrounded app, or disconnected session cannot apply the draft. Source or connection changes reset the displayed draft without automatically enabling audio.

The chooser can be reopened from the streaming settings panel. On an iPad with the existing native menu bar, the app's own Korean Audio menu opens the same chooser even if the host supplies no application menus. The native action checks the currently focused single-window client again when invoked. Older versions keep the in-app settings entry.

The output section displays the OS's current route and embeds `AVRoutePickerView` with video priority disabled. Its list contains system-eligible output routes, not an invented catalog of Mac/Vision endpoints. The current input is read from the audio session. This patch does not add a hardware microphone picker, request permission merely to enumerate inputs, alter session categories, or promise that every physically connected device is routable. Some Bluetooth profiles couple physical input and output even though app consent is independent.

The host protocol exposes only the current peer's playback and microphone capabilities. It has no arbitrary Mac/Vision device inventory or hardware routing command. The chooser therefore does not advertise those endpoints. Mac playback remains governed by the existing subscription behavior; choosing no iPad output does not command the Mac's speakers off.

## Changed files

- `IPadAudioRoutePolicy.swift` adds typed input/output choices, capability-filtered options, a pure action plan, context identity, Korean errors, and one-off connection presentation state.
- `StreamClient+AudioRoutes.swift` validates the displayed context and forwards only changed consent to the existing controllers.
- `IPadAudioRouteChooser.swift` implements the Korean form, input/output selectors, current physical route labels, explicit apply/cancel, and native output picker.
- `ContentView.swift` presents the sheet on the first active stream, handles foreground/dismissal, and rebuilds the native menu after connection changes.
- `HostSettingsPanel.swift` adds the in-app chooser entry while retaining the existing status/consent controls.
- `SillAppDelegate.swift` adds the app's own Audio menu, independently of the host's menus.
- `StreamClient.swift` owns presentation state and resets it during teardown. Its prior remote startup and retirement methods are preserved.
- `Sill.xcodeproj/project.pbxproj` registers the three new client source files. Team, bundle identifier, signing settings, and deployment targets are unchanged.
- `Tests/audio-routes` adds the focused test runner, stand-in, behavioral checks, and rerun instructions. `.audit/audio-routes-*` contains this task's evidence.

The previous `RemoteDialPolicy.swift` and `StreamClient+Remote.swift` retain the exact hashes captured before this task. No existing audio consent controller, microphone capture, AVAudioSession owner, shared wire type, or host/Vision file changed.

## Verification

The focused audio route suite reports `90/90 audio route checks passed; 0 failed`. The existing microphone owner/cancellation and audio lease suites also pass. The route suite compiles the complete production adapter with the real consent controllers, while replacing transport and capture effects with recorded client calls.

The Xcode project passes `plutil -lint`, and changed Swift files pass an iOS-target syntax parse. The user supplied the explicit Xcode developer directory after the default Command Line Tools directory failed SDK discovery. With that directory, the complete native build reports `BUILD SUCCEEDED` and exits 0. It uses Xcode 27.0 build 27A266a, iPhoneOS 27.0, scheme Sill, Debug, generic iOS destination, and one build job. SwiftUI, UIKit menu integration, AVKit linking, and all three new sources compile in the actual iOS target.

The native log is `audio-routes-native-build.log`, and `audio-routes-native-receipt.json` records source and executable hashes, environment, prior-patch preservation, and artifact path. The output is `audio-routes-native-build/Build/Products/Debug-iphoneos/Sill.app`. `file` confirms an arm64 Mach-O executable. `codesign -dv` confirms it is unsigned. Bundle ID remains `com.ambrion.sillcanvas.ipad`. The existing deployment target produces minimum OS 27.0. The user must sign/build for their installation flow and perform physical acceptance.

After the audio patch, the prior remote startup suite again reports `35/35 checks passed; 0 failed`, and the real trust/retirement policy plus extracted integration again reports `52 passed, 0 failed`. Their new logs are `audio-routes-prior-startup.log` and `audio-routes-prior-security.log`. The prior remote policy and remote integration files match the pre-task hashes exactly.

No physical installation or device operations were performed. Runtime layout, touch targets, audible routing, system route picker contents, microphone permission UI, and Bluetooth coupling remain physical acceptance items for the user. Independent review is unavailable because this session has no subagent dispatch tool. No merge or shipping verdict is asserted.

## Design and skill procedure

`pstack:poteto-mode` routed this work through the Feature playbook. `how` traced capability and consent ownership. `architect` compared a typed supported-path chooser with a cross-device registry, using the documented sequential fallback because no subagent tool is exposed. The registry was rejected because it would advertise commands the protocol cannot execute.

Model the Domain kept input/output choices and one-time presentation state explicit. Boundary Discipline placed peer/source/capability checks in the adapter and kept decision logic pure. Laziness Protocol reused the existing consent controllers and system output picker. Test Behavior, Not Implementation drove the assertions on actual consent requests, preserved independent selections, and stale-request rejection. One worker serialized the coupled client changes after capability discovery; there were no delegated writes or repeated background tasks.

Apple references checked through Context7 support the route limits. [Available inputs](https://developer.apple.com/documentation/avfaudio/avaudiosession/availableinputs) depend on active category. [Preferred input](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredinput%28_%3A%29) requires an active configured session and an actual available port. [Bluetooth HFP routing](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetooth) can couple input/output. [AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview) supplies the system output chooser.
