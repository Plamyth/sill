"""실제 어댑터 본문을 가짜 전송/시계와 연결한다. UI·기기·오디오·네트워크 없음."""
from pathlib import Path
import subprocess, sys
root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(root/'Tests/checks'))
from swift_platform import select_platform

def extension(file):
    s = select_platform((root/'iOSClient'/file).read_text(), vision=False, ios=True)
    s = s[s.index('extension StreamClient'):]
    if 'final class IPadAudioResumeObserver' in s:
        s = s[:s.index('final class IPadAudioResumeObserver')]
    return s

forward = extension('StreamClient+AudioForwarding.swift').replace(
    'Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000', 'clock.now')
desired = extension('StreamClient+DesiredAudio.swift')
routes = extension('StreamClient+AudioRoutes.swift')
# The actual transport entry point is exercised for malformed and peer/request checks too.
fixture = '''import Foundation
import StreamProtocol
final class Clock: @unchecked Sendable { var now = 0.0 }
final class NWConnection {
 enum Completion { case contentProcessed((Error?) -> Void) }
 var messages: [Data] = []
 enum SendFailure: Error { case fixture }
 var holdSendCompletions = false
 var completions: [(Error?) -> Void] = []
 func failSends() { let old = completions; completions = []; old.forEach { $0(SendFailure.fixture) } }
 var forwardingInFlight = 0
 var maximumForwardingInFlight = 0
 func send(content: Data?, completion: Completion) {
  if let content {
   if content.first == 217 {
    forwardingInFlight += 1
    maximumForwardingInFlight = max(maximumForwardingInFlight, forwardingInFlight)
   }
   messages.append(content)
  }
  if case .contentProcessed(let f) = completion { if holdSendCompletions { completions.append(f) } else { f(nil) } }
 }
}
final class UIApplication {
 enum State { case active, inactive, background }
 static let shared = UIApplication(); var applicationState = State.active
}
struct UIDevice { enum Idiom { case pad, phone }; static let current = UIDevice(); var userInterfaceIdiom: Idiom { .pad } }
enum AVCaptureDevice {
 enum Media { case audio }; enum Status { case authorized, denied, notDetermined }
 static var status = Status.authorized
 static func authorizationStatus(for: Media) -> Status { status }
 static func requestAccess(for: Media) async -> Bool { status == .authorized }
}
enum DeviceIdentity {
 struct Identity { let fingerprint = Data(repeating: 0xaa, count: 32) }
 static func existing() -> Identity? { Identity() }
}
final class IPadAudioSession { static let shared = IPadAudioSession(); var microphoneAvailable = true }
final class IPadAudioResumeObserver { init(client: StreamClient) {} }
final class Frames { func close() {} }
final class IPadMicrophoneDiagnostics {
 final class Attempt { func record(_ s: String, _ fields: [String:String] = [:]) {} }
 static let shared = IPadMicrophoneDiagnostics()
 func attempt(_ id: UUID) -> Attempt { Attempt() }
}
final class StreamClient {
 struct Saved { let macID: String; let fingerprintData: Data? }
 struct Session { var macID: String? = "fixture" }
 let suite = "forwarding-adapter-" + UUID().uuidString
 let clock = Clock()
 lazy var audioAdmission = IPadAudioAdmission(now: { [clock] in clock.now })
 var audioCatalogAdmission: IPadAudioAdmission.Ticket?
 var desiredAudio = IPadDesiredAudio()
 lazy var desiredAudioStore = IPadDesiredAudioStore(defaults: UserDefaults(suiteName: suite)!)
 var desiredAudioSelection = IPadDesiredAudio.Selection()
 var audioPrivacyState: AudioPrivacyState?
 var audioPendingMicrophonePermission: (() -> Void)?
 var audioAutomaticDirections: Set<IPadDesiredAudio.Direction> = []
 var audioRouteAuthorization: IPadAudioRoutePolicy.Authorization?
 var audioResumeObserver: IPadAudioResumeObserver?
 var audioForwarding = IPadAudioForwarding()
 var audioForwardingLocalGeneration = UUID()
 var audioForwardingWake: DispatchWorkItem?
 var audioForwardingWire: ForwardingExchange?
 var audioForwardingWireTimeout: DispatchWorkItem?
 var audioForwardingDevice: AudioForwardingDeviceID?
 var audioForwardingCatalogAt: TimeInterval?
 var audioForwardingSubmissionAt: TimeInterval?
 var audioForwardingPhase = IPadAudioForwarding.Phase.unknown
 var connected = true
 var connection: NWConnection? = NWConnection()
 var appInForeground = true
 var active = StreamSource.desktop
 var microphonePolicy = IPadMicrophonePolicy()
 let microphoneFrames = Frames()
 var microphoneCleanupProblem: String?
 var microphoneCaptureToken: UUID?
 var microphoneAttempts = 0
 var subscriptions: [RemoteAudioSubscription] = []
 lazy var remoteAudioControl = IPadRemoteAudioController(send: { [weak self] peer, request in self?.subscriptions.append(request); self?.sendRemoteAudio(request, to: peer) },
     stop: {}, play: { _, _ in }, changed: { _ in })
 var remoteAudioStatus: IPadRemoteAudioController.Status { remoteAudioControl.status }
 var authenticatedMacAudioRoutePeer: ObjectIdentifier? { connection.map(ObjectIdentifier.init) }
 var session: Session? = Session()
 var savedMacs = [Saved(macID: "fixture", fingerprintData: Data(repeating: 7, count: 32))]
 var audioRouteOffer = IPadAudioRouteOffer()
 var audioRouteAcknowledgments = IPadAudioRouteAcknowledgments()
 var audioRoutePresentation: IPadAudioRoutePolicy.Presentation?
 var audioRouteChooserPresented = false
 var microphonePhase: IPadMicrophonePolicy.Phase { microphonePolicy.phase }
 func applyMicrophone(_ effects: [IPadMicrophonePolicy.Effect], allowPermissionPrompt: Bool = true) {
  for effect in effects {
   switch effect {
   case .requestPermission(let peer, let scope, let request):
    microphoneAttempts += 1
    if desiredAudioPermits(.microphone) { applyMicrophone(microphonePolicy.permissionResolved(true, requestID: request, scope: scope, from: peer)) }
   case .send(let peer, let control): sendMicrophoneControl(control, to: peer)
   default: break
   }
  }
 }
 func connectionLost(_ c: NWConnection, error: Error) {}
 func beginRemoteAudioRequest() { remoteAudioControl.toggle() }
 func fixtureObserve(_ list: WindowList) {
  let peer = connection!
  let ticket = audioAdmission.observe(list, from: ObjectIdentifier(peer))
  if admitAudioCatalog(ticket) {
   remoteAudioControl.receive(list, from: ObjectIdentifier(peer))
   applyMicrophone(microphonePolicy.observe(list, from: ObjectIdentifier(peer)))
   desiredAudioObserve(list, from: peer)
  }
  reconcileDesiredAudio()
 }
 func command() -> AudioForwardingControl {
  let message = connection!.messages.last!
  return Wire.decode(AudioForwardingControl.self, from: Data(message.dropFirst(StreamMessage.headerLength)))!
 }
 func receive(_ state: AudioForwardingState) { connection!.forwardingInFlight = 0; acceptAudioForwarding(state, from: connection!) }

 deinit { audioForwardingWake?.cancel(); audioForwardingWireTimeout?.cancel(); UserDefaults.standard.removePersistentDomain(forName: suite) }
}
'''
def method(file, name):
    s = (root/'iOSClient'/file).read_text()
    start = s.index('    private func ' + name) if '    private func ' + name in s else s.index('    func ' + name)
    end = s.index('\n    }', start) + len('\n    }')
    return select_platform(s[start:end], vision=False, ios=True)
transport = 'extension StreamClient {\n' + method('StreamClient+Audio.swift', 'sendRemoteAudio') + '\n' + method('StreamClient+Microphone.swift', 'sendMicrophoneControl') + '\n}\n'
(out/'Adapter.swift').write_text(fixture + forward + desired + routes + transport)
flags=['-module-cache-path',str(out/'cache'),'-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out)]
files=['IPadAudioForwarding.swift','IPadDesiredAudio.swift','IPadAudioAdmission.swift','IPadMicrophonePolicy.swift','IPadRemoteAudioController.swift','IPadAudioRoutePolicy.swift']
subprocess.run(['xcrun','swiftc','-parse-as-library',*flags,*[str(root/'iOSClient'/f) for f in files],str(out/'Adapter.swift'),str(Path(__file__).with_name('adapter-main.swift')),'-o',str(out/'adapter-check')],check=True)
subprocess.run([str(out/'adapter-check')],check=True)
