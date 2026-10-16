# Verify iPad audio route choices

From the repository root, run:

```sh
python3 iOSClient/Tests/audio-routes/run.py
```

The route suite compiles the real `IPadAudioRoutePolicy`, `IPadAudioRouteOffer`, playback consent controller, microphone policy, and complete `StreamClient+AudioRoutes` adapter. A client stand-in records network consent effects. It never opens AVAudioEngine, Keychain, or a network connection.

The checks cover independent input/output choices, capability filtering, one offer per connection, inert menu opening, explicit consent, repeated application, late ACKs, stale peers/sources/microphone scopes, foreground checks, cleanup failures, and bounded microphone stop handling. The same runner executes the existing microphone cancellation and audio lease suites without changing their source.

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
