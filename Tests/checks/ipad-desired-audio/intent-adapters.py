"""Parent-only actual-adapter extraction. Run after run.sh with the same approved OUTPUT."""
import importlib.util
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).resolve()
if not out.is_dir() or out == root or root in out.parents:
    raise SystemExit("Pass an existing isolated volatile OUTPUT used by run.sh")
spec = importlib.util.spec_from_file_location("platform", root / "Tests/checks/swift_platform.py")
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)
source = platform.select_platform((root / "iOSClient/StreamClient+DesiredAudio.swift").read_text(), vision=False, ios=True)
start = source.index("extension StreamClient")
end = source.index("final class IPadAudioResumeObserver")
adapter = source[start:end]
standins = '''import Foundation
import StreamProtocol
final class NWConnection {}
final class UIApplication {
 enum State { case active, inactive, background }
 static let shared = UIApplication()
 var applicationState = State.active
}
enum AVCaptureDevice {
 enum Media { case audio }; enum Status { case authorized, denied }
 static func authorizationStatus(for: Media) -> Status { .authorized }
}
final class IPadAudioSession { static let shared = IPadAudioSession(); var microphoneAvailable = true }
final class IPadAudioResumeObserver { init(client: StreamClient) {} }
final class Frames { func close() {} }
final class StreamClient {
 struct Trusted { let macID: String; let pin: Data }
 var audioRouteTrustedMac: Trusted? = Trusted(macID: "fixture", pin: Data(repeating: 7, count: 32))
 var desiredAudio = IPadDesiredAudio()
 let suite = "IntentAdapter." + UUID().uuidString
 lazy var desiredAudioStore = IPadDesiredAudioStore(defaults: UserDefaults(suiteName: suite)!)
 var desiredAudioSelection = IPadDesiredAudio.Selection()
 var audioPrivacyState: AudioPrivacyState?
 var audioPendingMicrophonePermission: (() -> Void)?
 var audioAutomaticDirections: Set<IPadDesiredAudio.Direction> = []
 var audioRouteAuthorization: UUID?
 var audioResumeObserver: IPadAudioResumeObserver?
 var connected = true
 var connection: NWConnection?
 var appInForeground = true
 var microphonePolicy = IPadMicrophonePolicy()
 let microphoneFrames = Frames()
 var microphoneCleanupProblem: String?
 var microphoneCaptureToken: UUID?
 var microphoneAttempts = 0
 var subscriptions: [RemoteAudioSubscription] = []
 lazy var remoteAudioControl = IPadRemoteAudioController(send: { [weak self] _, request in self?.subscriptions.append(request) },
     stop: {}, play: { _, _ in }, changed: { _ in })
 var remoteAudioStatus: IPadRemoteAudioController.Status { remoteAudioControl.status }
 func applyMicrophone(_ effects: [IPadMicrophonePolicy.Effect], allowPermissionPrompt: Bool = true) {
  for effect in effects { if case .requestPermission = effect { microphoneAttempts += 1 } }
 }
 func beginRemoteAudioRequest() { remoteAudioControl.toggle() }
 deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
}
'''
main = '''import Foundation
import StreamProtocol
func check(_ value: @autoclosure () -> Bool, _ name: String) {
 if !value() { fatalError("FAIL " + name) }
}
let client = StreamClient(), peer = NWConnection(), generation = UUID()
let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
 geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
let scope = MicrophoneScope(peer: UUID(), source: .desktop, inputGeneration: generation,
 videoEpoch: epoch.id, destination: UUID(), capability: UUID())
let catalog = WindowList(macName: "fixture", windows: [], active: .desktop, remoteAudio: 1,
 inputGeneration: generation.uuidString, videoEpoch: epoch,
 microphone: .init(peer: scope.peer, destination: scope.destination, generation: scope.capability), audioPrivacy: .init(version: 2, protected: true))
client.connection = peer
client.desiredAudioSetConnection(peer)
_ = client.microphonePolicy.setConnection(ObjectIdentifier(peer))
_ = client.microphonePolicy.observe(catalog, from: ObjectIdentifier(peer))
client.remoteAudioControl.setConnection(ObjectIdentifier(peer))
client.remoteAudioControl.receive(catalog, from: ObjectIdentifier(peer))
client.desiredAudioStore.save(.init(microphone: true, playback: true), for: client.desiredAudioIdentity!)
client.desiredAudioObserve(catalog, from: peer)
client.reconcileDesiredAudio()
check(client.microphoneAttempts == 1 && client.subscriptions.filter(\\.enabled).count == 1, "drawing without a renderer resumes audio intent")
client.reconcileDesiredAudio()
check(client.microphoneAttempts == 1, "same lifecycle cannot retry failed attempt")
UIApplication.shared.applicationState = .background
client.appInForeground = false
client.reconcileDesiredAudio()
UIApplication.shared.applicationState = .active
client.appInForeground = true
client.reconcileDesiredAudio()
check(client.microphoneAttempts == 2 && client.subscriptions.filter(\\.enabled).count == 2, "foreground starts fresh requests without video callbacks")
client.setDesiredAudio(.microphone, enabled: false)
client.desiredAudio.observeForeground(false)
client.suspendDesiredAudio()
client.reconcileDesiredAudio()
check(client.microphoneAttempts == 2 && !client.desiredAudio.selection.microphone, "explicit OFF survives lifecycle renewal")
var unknown = catalog
unknown.audioPrivacy = nil
client.desiredAudioObserve(unknown, from: peer)
check(!client.desiredAudioPermits(.microphone) && !client.desiredAudioPermits(.playback), "unknown privacy cannot be bypassed")
print("PASS 5 actual desired-audio adapter checks with inert audio effects, no video objects")
'''
for name, text in [("Adapter.swift", standins + adapter), ("main.swift", main)]:
    (out / name).write_text(text)
command = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-I", str(out), "-L", str(out), "-lStreamProtocol",
           "-Xlinker", "-rpath", "-Xlinker", str(out), str(out / "Adapter.swift"),
           str(root / "iOSClient/IPadDesiredAudio.swift"), str(root / "iOSClient/IPadMicrophonePolicy.swift"),
           str(root / "iOSClient/IPadRemoteAudioController.swift"), str(out / "main.swift"), "-o", str(out / "intent-adapters")]
subprocess.run(command, check=True, timeout=90)
subprocess.run([str(out / "intent-adapters")], check=True, timeout=20)
