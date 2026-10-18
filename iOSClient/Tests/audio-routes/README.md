# Verify iPad audio route choices

From the repository root, run:

```sh
python3 iOSClient/Tests/audio-routes/run.py
```

The route suite compiles the real `IPadAudioRoutePolicy`, `IPadAudioRouteOffer`, playback consent controller, microphone policy, and complete `StreamClient+AudioRoutes` adapter. A client stand-in records network consent effects. It never opens AVAudioEngine, Keychain, or a network connection.

The checks cover independent input/output choices, capability filtering, inert menu opening, explicit consent, repeated application, late ACKs, stale peers/sources/microphone scopes, foreground checks, cleanup failures, and bounded microphone stop handling. The same runner executes the existing microphone cancellation and audio lease suites without changing their source.

iPad onboarding stores only an acknowledgment for a verified Mac ID and host pin. The adapter checks reconnect, a fresh store instance, a separate cold process, changed identity/pin, malformed storage, interactive dismissal and programmatic scene dismissal. No media grant is persisted. Unsupported and unverified iPad hosts do not force an automatic chooser. The iPhone retains its prior offer per connection.

Toolbar state checks run separately:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 iOSClient/Tests/toolbar-visibility/run.py
```

They check idle, activity, pinned panels, VoiceOver policy, deferred hide/reveal while a remote touch is held, and disabled iPhone behavior. Actual hit testing, layout, first responder and drag continuity require the parent's combined SDK build and iPad review. These pure checks do not open the UI.

Compiler inputs and executables use temporary directories below this directory. The compiler cache reuses the previous iOSClient test cache. No host or Vision source is compiled.

The native iPad build uses Xcode explicitly:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project iOSClient/Sill.xcodeproj -scheme Sill -configuration Debug \
  -sdk iphoneos -destination generic/platform=iOS \
  -derivedDataPath iOSClient/.audit/audio-routes-native-build \
  -jobs 1 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The native build verifies iOS compilation and linking. The focused tests verify client decisions through recorded effects. Neither verifies audible output, microphone permission UI, system output discovery, layout/touch behavior, or physical device acceptance. Installation and physical acceptance belong to the user.

## Combined input and output

The first section now offers **iPad 입력·출력 함께 사용** and both local statuses. The iPad microphone and **iPad 스피커·연결된 출력** selectors precede Mac system device settings. Unsupported output remains visible with a reason.

The combined action checks microphone permission before requesting either direction, then validates the same peer/source/capability and active foreground. Denial, cancellation, changed context or background sends no new consent. Returning to the foreground never resumes a cancelled action.

A playback ACK means local preparation is pending. The player reports readiness only after engine startup succeeds; failure is visible and unsubscribes without automatic retry. Metadata is appended to the existing bounded, PCM-free `Library/Application Support/CCR Sill/microphone-diagnostics.json` in the iPad app container.

Focused checks run only on isolated Mini RAM input:

```sh
python3 Tests/checks/ipad-full-duplex/run.py /absolute/path/to/new-receipt-directory
```

They compile the production route adapter/controller and player startup body with fake permission, engine, session and network boundaries. Receipts include exact input hashes, source immutability and RAM/child cleanup. This is independent input validation, not source-guard task transfer, SDK build, audible playback or physical full duplex acceptance. Parent owns the SDK build and physical checks.
