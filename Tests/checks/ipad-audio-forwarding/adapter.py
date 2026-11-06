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
 var peerPin: Data? = Data(repeating: 7, count: 32)
 enum Completion { case contentProcessed((NWError?) -> Void) }
 var messages: [Data] = []
 var cancellations = 0
 func cancel() { cancellations += 1 }
 enum SendFailure: Error { case fixture }
 var holdSendCompletions = false
 var completions: [(NWError?) -> Void] = []
 func failSends() { let old = completions; completions = []; old.forEach { $0(.posix(.EIO)) } }
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
enum NWError: Error { case posix(POSIXErrorCode) }
final class UIApplication {
 enum State { case active, inactive, background }
 static let shared = UIApplication(); var applicationState = State.active
 static let willResignActiveNotification = Notification.Name("fixture.resign")
 static let didEnterBackgroundNotification = Notification.Name("fixture.background")
 static let didBecomeActiveNotification = Notification.Name("fixture.active")
}
enum AVAudioSession {
 enum RouteChangeReason: UInt { case unknown = 0, newDeviceAvailable = 1, oldDeviceUnavailable = 2, categoryChange = 3, override = 4, wakeFromSleep = 6, noSuitableRouteForCategory = 7, routeConfigurationChange = 8 }
 enum InterruptionType: UInt { case ended = 0, began = 1 }
 struct InterruptionOptions: OptionSet { let rawValue: UInt; static let shouldResume = Self(rawValue: 1) }
 static let routeChangeNotification = Notification.Name("fixture.route")
 static let interruptionNotification = Notification.Name("fixture.interruption")
 static let mediaServicesWereResetNotification = Notification.Name("fixture.reset")
}
let AVAudioSessionRouteChangeReasonKey = "reason"
let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionInterruptionOptionKey = "options"
struct UIDevice { enum Idiom { case pad, phone }; static let current = UIDevice(); var userInterfaceIdiom: Idiom { .pad } }
enum AVCaptureDevice {
 enum Media { case audio }; enum Status { case authorized, denied, notDetermined }
 static var status = Status.authorized
 static func authorizationStatus(for: Media) -> Status { status }
 static var holdPermission = false
 static var permissionWaiter: CheckedContinuation<Bool, Never>?
 static func requestAccess(for: Media) async -> Bool {
  if holdPermission { return await withCheckedContinuation { permissionWaiter = $0 } }
  return status == .authorized
 }
}
enum DeviceIdentity {
 struct Identity { let fingerprint = Data(repeating: 0xaa, count: 32) }
 static func existing() -> Identity? { Identity() }
}
final class IPadAudioSession { static let shared = IPadAudioSession(); var microphoneAvailable = true }
enum RemoteTLS { static func peerFingerprint(_ peer: NWConnection) -> Data? { peer.peerPin } }
final class Frames { var closes = 0; func close() { closes += 1 } }
final class IPadMicrophoneDiagnostics {
 func connectionChanged() {}
 static var records: [(String, [String: String], UUID)] = []
 final class Attempt {
  let id: UUID
  init(_ id: UUID) { self.id = id }
  func record(_ s: String, _ fields: [String:String] = [:]) {
   guard !IPadMicrophoneDiagnostics.records.contains(where: { $0.0 == s && $0.2 == id }) else { return }
   IPadMicrophoneDiagnostics.records.append((s, fields, id))
  }
  FORWARDING_GUARDS_METHOD
 }
 static let shared = IPadMicrophoneDiagnostics()
 func attempt(_ id: UUID) -> Attempt { Attempt(id) }
 static func route() -> String { "controlled route" }
}
final class StreamClient {
 var configuredCraftCapability: Int?
 func configuredCraftSetConnection(_ peer: NWConnection?) {}
 func reconcileConfiguredCraftAction() {}
 func observeAudioDiagnostics() {}
 struct Saved { let macID: String; let fingerprintData: Data? }
 struct Session {
  struct Route { var isRemote = true }
  enum Home: Equatable { case saved(pin: Data), unknown }
  var macID: String? = "fixture"
  var route = Route()
  var home = Home.unknown
 }
 var macInfoSaved = true
 var macInfoVerified: (info: Session, fingerprint: Data)? = (Session(), Data(repeating: 7, count: 32))
 let suite = "forwarding-adapter-" + UUID().uuidString
 let clock = Clock()
 lazy var audioAdmission = IPadAudioAdmission(now: { [clock] in clock.now })
 var audioCatalogAdmission: IPadAudioAdmission.Ticket?
 var desiredAudio = IPadDesiredAudio()
 lazy var desiredAudioStore = IPadDesiredAudioStore(defaults: UserDefaults(suiteName: suite)!)
 var desiredAudioSelection = IPadDesiredAudio.Selection()
 var desiredAudioSelectionGeneration = UUID()
 var audioPrivacyState: AudioPrivacyState?
 var audioPendingMicrophonePermission: (() -> Void)?
 var audioAutomaticDirections: Set<IPadDesiredAudio.Direction> = []
 var audioRouteAuthorization: IPadAudioRoutePolicy.Authorization?
 var audioResumeObserver: IPadAudioResumeObserver?
 lazy var providerCall = IPadProviderCall(connection: UUID(), clock: { [clock] in clock.now })
 var providerCallConnection = UUID()
 var providerCallPeer: ObjectIdentifier?
 var providerCallCapability: Int?
 var providerCallKindsCapability: [String]?
 var providerCallQueryWake: DispatchWorkItem?
 var inputPaused = false
 var authenticated = true
 var audioForwarding = IPadAudioForwarding()
 var audioForwardingLocalGeneration = UUID()
 var audioForwardingWake: DispatchWorkItem?
 var audioForwardingWire: ForwardingExchange?
 var audioForwardingStopDiagnostic: (id: UUID, context: IPadAudioForwarding.Context?)?
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
 var playbackStops = 0
 var subscriptions: [RemoteAudioSubscription] = []
 lazy var remoteAudioControl = IPadRemoteAudioController(send: { [weak self] peer, request in self?.subscriptions.append(request); self?.sendRemoteAudio(request, to: peer) },
     stop: { [weak self] in self?.playbackStops += 1 }, play: { _, _ in }, changed: { _ in })
 var remoteAudioStatus: IPadRemoteAudioController.Status { remoteAudioControl.status }
 var authenticatedMacAudioRoutePeer: ObjectIdentifier? { authenticated && connected ? connection.map(ObjectIdentifier.init) : nil }
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
   case .closeFrames: microphoneFrames.close()
   default: break
   }
  }
 }
 var connectionLosses = 0
 func connectionLost(_ c: NWConnection, error: NWError) { connectionLosses += 1 }
 func beginRemoteAudioRequest() { remoteAudioControl.toggle() }
 func recordMicrophoneDiagnostic(_ event: String, _ fields: [String: String]) {}
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
  let message = connection!.messages.last { $0.first == 217 }!
  return Wire.decode(AudioForwardingControl.self, from: Data(message.dropFirst(StreamMessage.headerLength)))!
 }
 func receive(_ state: AudioForwardingState) { connection!.forwardingInFlight = 0; acceptAudioForwarding(state, from: connection!) }

 deinit { providerCallQueryWake?.cancel(); audioForwardingWake?.cancel(); audioForwardingWireTimeout?.cancel(); UserDefaults.standard.removePersistentDomain(forName: suite) }
}
'''
diagnostics = (root/'iOSClient/IPadMicrophoneCapture.swift').read_text()
a = diagnostics.index('        func recordForwardingGuards(')
b = diagnostics.index('\n        }', a) + len('\n        }')
fixture = fixture.replace('FORWARDING_GUARDS_METHOD', diagnostics[a:b])
def method(file, name):
    s = (root/'iOSClient'/file).read_text()
    start = s.index('    private func ' + name) if '    private func ' + name in s else s.index('    func ' + name)
    end = s.index('\n    }', start) + len('\n    }')
    return select_platform(s[start:end], vision=False, ios=True)
transport = 'extension StreamClient {\n' + method('StreamClient+Audio.swift', 'sendRemoteAudio') + '\n' + method('StreamClient+Microphone.swift', 'sendMicrophoneControl') + '\n' + method('StreamClient+Microphone.swift', 'microphoneInterrupted') + '\n}\n'
timer_mode = sys.argv[3] if len(sys.argv) > 3 else ''
if timer_mode == 'preparation-boundaries':
    fixture += '''
enum ScenePhase { case active, inactive, background }
@MainActor final class ChooserFixture {
 let client: StreamClient
 var context: IPadAudioRoutePolicy.Context?
 var acknowledgedMac: IPadAudioRouteAcknowledgments.Identity?
 var selection = IPadAudioRoutePolicy.Selection()
 var selectionEdited = false
 var problem: String?
 var operation: Task<Void, Never>?
 var operationID: UUID? = UUID()
 var preparingCall = true
 var preparingCraft = false
 init(_ client: StreamClient) { self.client = client; context = client.audioRouteContext }
 CHOOSER_METHODS
}
'''.replace('CHOOSER_METHODS', '\n'.join(method('IPadAudioRouteChooser.swift', name).replace('private func ', 'func ', 1)
                                       for name in ['handleScenePhase', 'handleRouteContext', 'cancelOperation']))
    # Frozen 6b82e77f counterexamples must run in Git-free source snapshots.
    fixture += r'''
extension StreamClient {
    @MainActor func legacyPrepareAndStartIPadProviderCall(_ selection: IPadAudioRoutePolicy.Selection,
                                                   context: IPadAudioRoutePolicy.Context?,
                                                   target: IPadCallTarget) async throws {
        guard iPadProviderCanPrepareCall, let peer = connection, let context,
              context == audioRouteContext, target == providerCall.target,
              let forwarding = audioForwardingContext, let hostKey = providerCallTrustedHostKey else {
            throw IPadAudioRoutePolicy.Problem.changedConnection
        }
        let generation = providerCallConnection
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var submitted = false
        var preparedRevisions: [UUID]?
        defer {
            if !submitted, connection === peer, context == audioRouteContext,
               forwarding == audioForwardingContext, providerCallConnection == generation,
               providerCallTrustedHostKey == hostKey, target == providerCall.target,
               preparedRevisions == IPadDesiredAudio.Direction.allCases.map({ desiredAudio.revision(for: $0) }),
               selection == audioRouteSelection {
                cancelDesiredAudioRequest()
            }
        }
        func validate() throws {
            try Task.checkCancellation()
            guard connection === peer, context == audioRouteContext, forwarding == audioForwardingContext,
                  providerCallConnection == generation, providerCallTrustedHostKey == hostKey,
                  target == providerCall.target, iPadProviderCanPrepareCall else {
                throw IPadAudioRoutePolicy.Problem.changedConnection
            }
            if let preparedRevisions,
               preparedRevisions != IPadDesiredAudio.Direction.allCases.map({ desiredAudio.revision(for: $0) }) {
                throw IPadAudioRoutePolicy.Problem.changedConnection
            }
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "IPadProviderCall", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "음성 입출력 준비 시간이 지났습니다. 통화는 시작하지 않았습니다."])
            }
        }
        try validate()
        if selection != audioRouteSelection || !iPadProviderCanStart {
            try await applyAudioRoutes(selection, context: context)
        }
        preparedRevisions = IPadDesiredAudio.Direction.allCases.map { desiredAudio.revision(for: $0) }
        while true {
            try validate()
            guard selection == audioRouteSelection, audioForwarding.phase != .blocked,
                  microphoneCleanupProblem == nil else { throw IPadAudioRoutePolicy.Problem.changedConnection }
            if case .failed(let reason) = microphonePhase {
                throw NSError(domain: "IPadProviderCall", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            if case .failed(let reason) = remoteAudioStatus {
                throw NSError(domain: "IPadProviderCall", code: 3, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            if iPadProviderCanStart {
                performIPadProviderCall(.start, target: target)
                guard providerCall.pending != nil else { throw IPadAudioRoutePolicy.Problem.changedConnection }
                submitted = true
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

extension ChooserFixture { func legacyHandleScenePhase(_ next: ScenePhase) {
            if next != .active { cancelOperation(stopPreparingAudio: true) }
} }
'''

if timer_mode in ('microphone-timers', 'microphone-timers-legacy'):
    microphone = (root/'iOSClient/StreamClient+Microphone.swift').read_text()
    start = microphone.index('            case .send(let peer, let control):')
    end = microphone.index('            case .beginCapture(', start)
    body = microphone[start:end].split('\n', 1)[1]
    if timer_mode == 'microphone-timers-legacy':
        assert body.count('deadline: .now() + 12') == 1
        body = body.replace('deadline: .now() + 12', 'deadline: .now() + 6', 1)
    body = body.replace('DispatchQueue.main.asyncAfter(deadline:', 'recordMicrophoneTimer(control, deadline:')
    fixture = fixture.replace('case .send(let peer, let control): sendMicrophoneControl(control, to: peer)',
                              'case .send(let peer, let control): fixtureMicrophoneSend(peer, control)')
    fixture = fixture.replace('func beginRemoteAudioRequest() { remoteAudioControl.toggle() }',
                              method('StreamClient+Audio.swift', 'beginRemoteAudioRequest').strip())
    fixture = fixture.replace('func observeAudioDiagnostics() {}',
                              'var microphoneReceipt: MicrophoneReceipt?\n var microphoneTimers: [(operation: MicrophoneControl.Operation, request: UUID, seconds: Double)] = []\n func observeAudioDiagnostics() {}')
    fixture = fixture.replace('func connectionChanged() {}',
                              'enum ReceptionKind { case microphoneReceipt }\n func received(_ kind: ReceptionKind, hostTimestamp: Double) {}\n func connectionChanged() {}')
    transport += '\nextension StreamClient {\n func fixtureMicrophoneSend(_ peer: ObjectIdentifier, _ control: MicrophoneControl) {\n var pendingStops: [(ObjectIdentifier, MicrophoneControl)] = []\n' + body + '\n for (peer, control) in pendingStops { sendMicrophoneControl(control, to: peer) }\n }\n func recordMicrophoneTimer(_ control: MicrophoneControl, deadline: DispatchTime, execute action: @escaping @Sendable () -> Void) {\n microphoneTimers.append((control.operation, control.requestID, Double(deadline.uptimeNanoseconds) / 1_000_000_000 - Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000))\n DispatchQueue.main.asyncAfter(deadline: deadline, execute: action)\n }\n' + method('StreamClient+Microphone.swift', 'receiveMicrophone') + '\n}\n'
screen = (root/'iOSClient/StreamScreen.swift').read_text()
callbacks = ''
for event, name in [('routeChangeNotification', 'routeChanged'), ('interruptionNotification', 'interrupted'), ('mediaServicesWereResetNotification', 'mediaReset')]:
    start = screen.index('.onReceive(NotificationCenter.default.publisher(for: AVAudioSession.' + event)
    start = screen.index('{', start) + 1
    end = start
    depth = 1
    while depth:
        depth += (screen[end] == '{') - (screen[end] == '}')
        end += 1
    body = screen[start:end-1].split(' in\n', 1)[1].replace('client.', 'self.')
    callbacks += ' func ' + name + '(_ note: Notification) {\n' + body + '\n }\n'
(out/'Adapter.swift').write_text(fixture + forward + desired + routes + transport + extension('StreamClient+ProviderCall.swift') + '\nextension StreamClient {\n' + callbacks + '}\n')
flags=['-module-cache-path',str(out/'cache'),'-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out)]
if timer_mode == 'preparation-boundaries': flags += ['-D', 'PREPARATION_BOUNDARIES', '-whole-module-optimization']
files=['IPadProviderCall.swift','IPadAudioForwarding.swift','IPadDesiredAudio.swift','IPadAudioAdmission.swift','IPadMicrophonePolicy.swift','IPadRemoteAudioController.swift','IPadAudioRoutePolicy.swift']
subprocess.run(['xcrun','swiftc','-parse-as-library',*flags,*[str(root/'iOSClient'/f) for f in files],str(out/'Adapter.swift'),str(Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).with_name('adapter-main.swift')),'-o',str(out/'adapter-check')],check=True)
subprocess.run([str(out/'adapter-check'), *(['--expect-six'] if timer_mode == 'microphone-timers-legacy' else [])],check=True)
