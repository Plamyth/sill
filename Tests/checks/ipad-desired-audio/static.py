import hashlib
import json
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[3]
base = "0dd10d1f9463001531416f37d756214b0ff32456"

def read(name):
    return (root / name).read_text()

def block(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

adapter = read("iOSClient/StreamClient+DesiredAudio.swift")
mic = read("iOSClient/StreamClient+Microphone.swift")
audio = read("iOSClient/StreamClient+Audio.swift")
client = read("iOSClient/StreamClient.swift")
model = read("iOSClient/IPadDesiredAudio.swift")
routes = read("iOSClient/StreamClient+AudioRoutes.swift")
pbx = read("iOSClient/Sill.xcodeproj/project.pbxproj")
wire = block(read("Sources/StreamProtocol/Switcher.swift"), "public struct AudioPrivacyState")
checks = {
    "wire type matches the shared contract": all(part in wire for part in [
        "public struct AudioPrivacyState: Codable, Equatable, Sendable", "public var version: Int",
        "public var protected: Bool", "public var reason: String?",
        "public init(version: Int = 1, protected: Bool, reason: String? = nil)"]),
    "legacy catalog privacy remains optional": "public var audioPrivacy: AudioPrivacyState?" in read("Sources/StreamProtocol/Switcher.swift"),
    "business microphone policy is unchanged": (root / "iOSClient/IPadMicrophonePolicy.swift").read_bytes() == subprocess.check_output(
        ["git", "show", base + ":iOSClient/IPadMicrophonePolicy.swift"], cwd=root),
    "no permission request in automatic adapter": "requestAccess" not in adapter and "allowPermissionPrompt: !automatically" in adapter,
    "permission request has an explicit manual flag": "else if allowPermissionPrompt &&" in mic,
    "new or missing unsafe privacy blocks starts": "state.version == 1 && state.protected" in model and "sawPrivacy ? .blocked : .legacy" in model,
    "privacy catalog is bound to its actual peer": "guard connection === peer else { return }" in block(adapter, "func desiredAudioObserve"),
    "privacy failure stops both directions": "if desiredAudio.privacy == .blocked { suspendDesiredAudio() }" in adapter and all(
        part in block(adapter, "func suspendDesiredAudio") for part in ["remoteAudioControl.backgrounded()", "microphonePolicy.backgrounded()"]),
    "automatic budget includes identity scope and direction": "Attempt(identity: identity, scope: scope, direction: direction)" in model,
    "actual UI input binding gates automatic resume": all(part in adapter for part in [
        "window?.hitTest(point, with: nil) as? InputOverlayView", "overlay?.videoSize == videoSize",
        "overlay?.superview === view.superview",
        "!inputPaused && !moveUnderWay", "desiredAudioInputGeneration.flatMap(UUID.init(uuidString:)) == scope?.generation"]),
    "actual display layer readiness gates presentation": all(part in adapter + model for part in [
        "layer.isReadyForDisplay", "layer.requiresFlushToResumeDecoding", "sawNotReady && sawKeyframe"]),
    "current source and input generation are applied before reconcile": re.search(
        r"self.inputGeneration = list.inputGeneration\s+self.active = list.active\s+#if os\(iOS\)\s+self.reconcileDesiredAudio\(\)", client) is not None,
    "capture begin rechecks desire phase request grant and scope": all(part in mic.split("case .beginCapture", 1)[1].split("case .openFrames", 1)[0] for part in [
        "desiredAudioPermits(.microphone)", "microphonePolicy.phase == .capturing", "microphonePolicy.startRequestID == request",
        "microphonePolicy.grantID == grant", "microphonePolicy.scope == scope", "desiredAudio.revision(for: .microphone) == revision"]),
    "frame opening rechecks current live grant": all(part in mic.split("case .openFrames", 1)[1].split("for (peer, control)", 1)[0] for part in [
        "desiredAudioPermits(.microphone)", "microphonePolicy.phase == .live", "microphonePolicy.scope == scope", "microphonePolicy.grantID == grant"]),
    "all manual iPad controls enter desired intent": all(part in routes + audio + mic for part in [
        "setDesiredAudio(.microphone, enabled:", "setDesiredAudio(.playback, enabled:"]) and "toggleIPadMicrophone()" not in routes and "toggleRemoteAudio()" not in routes,
    "outgoing positive requests recheck intent": "request.enabled && !desiredAudioPermits(.playback)" in audio and "control.operation == .start && !desiredAudioPermits(.microphone)" in mic,
    "saved preferences bind both Mac and pin": "records.first { $0.identity == identity }" in model and "pin.count == 32" in model,
    "each new app source is included in the project": all(pbx.count(name + " in Sources") == 2 and pbx.count("path = " + name + ";") + pbx.count('path = "' + name + '";') == 1
        for name in ["IPadDesiredAudio.swift", "StreamClient+DesiredAudio.swift"]),
    "sidecar does not call host hardware or remote compute": not any(part in adapter + model + mic + audio for part in [
        "AudioObjectSetPropertyData", "AudioHardware", "mini heavy", "mini run", "setDefaultInput", "setDefaultOutput"]),
    "chooser cancellation clears both saved directions": "client.cancelDesiredAudioRequest()" in read("iOSClient/IPadAudioRouteChooser.swift") and all(
        part in block(adapter, "func cancelDesiredAudioRequest") for part in [
            "setDesiredAudio(.microphone, enabled: false)", "setDesiredAudio(.playback, enabled: false)"]),
    "active scene and key window are required": "window?.isKeyWindow == true" in adapter and "window?.windowScene?.activationState == .foregroundActive" in adapter,
    "automatic cleanup does not retry a recorded failure": "if microphoneCleanupProblem == nil { retryMicrophoneCleanup() }" in mic,
    "denied async starts settle the current policy": mic.count("microphonePolicy.permissionResolved(false") == 3 and
        "capture_begin_skipped" in mic and "마이크 시작 전에 연결 상태가 바뀌었습니다." in mic and "마이크 시작 중 연결 상태가 바뀌었습니다." in mic,
}
sources = ["Sources/StreamProtocol/Switcher.swift",
           "iOSClient/IPadDesiredAudio.swift", "iOSClient/StreamClient+DesiredAudio.swift",
           "iOSClient/StreamClient+Microphone.swift", "iOSClient/StreamClient+Audio.swift",
           "iOSClient/StreamClient+AudioRoutes.swift", "iOSClient/StreamClient.swift",
           "iOSClient/IPadAudioRouteChooser.swift", "iOSClient/Sill.xcodeproj/project.pbxproj"]
changed = set(subprocess.check_output(["git", "diff", base, "--name-only"], cwd=root, text=True).splitlines())
changed.update(subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=root, text=True).splitlines())
allowed = set(sources) | {"docs/ipad-desired-audio-20261019.md"}
checks["only owned source tests and documentation differ from base"] = all(
    name in allowed or name.startswith("Tests/checks/ipad-desired-audio/") for name in changed)
print(json.dumps({"scope": "Static source checks only. No Swift compiler, SDK, runtime, UI, audio, or device acceptance.",
                  "checks": checks, "count": len(checks),
                  "sha256": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources}}, indent=2))
raise SystemExit(0 if all(checks.values()) else 1)
