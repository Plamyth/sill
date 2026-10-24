"""Mini RAM에서 실제 consumer·키 adapter·SessionLink를 컴파일하고 대역만 실행한다."""
import ast
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
label = sys.argv[1]
route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
    'development-archive', '--project', 'BT_CCR-ipad', '--filename', 'sentry-return-consumer-20261025-' + label], text=True))
out = Path(route['path'])
out.mkdir(parents=True, exist_ok=True)
if (out / (label + '.json')).exists():
    raise SystemExit('기존 검사 영수증을 먼저 대조하세요.')
sha = lambda data: hashlib.sha256(data).hexdigest()
fixture = root / 'Tests/checks/sentry-return/fixtures.json'
assert sha(fixture.read_bytes()) == '16a280f5d9f8623bc30eee88dd4fd3c143523d1c14bdb0e9a8869231c4282187'
paths = list((root / 'Sources/StreamProtocol').glob('*.swift'))
paths += [root / 'iOSClient' / name for name in ['IPadSentryObservation.swift', 'IPadSentryControl.swift',
    'IPadSentryReturn.swift', 'IPadSentryReturnKeys.swift', 'SessionLink.swift', 'StreamClient+SentryReturn.swift',
    'StreamClient.swift', 'StreamClient+Sentry.swift']]
paths += [here / 'Main.swift', here / 'run.py', root / 'Tests/checks/reconnect-glue/mini.py', fixture]
original = {str(path.relative_to(root)): sha(path.read_bytes()) for path in paths}
files = {str(path.relative_to(root)): path.read_bytes() for path in paths}
network = b'''import Foundation
public final class NWConnection {
    public enum Completion { case contentProcessed((Error?) -> Void) }
    public var sent: [Data] = []
    public var pin = Data(repeating: 0xab, count: 32)
    public var alpn: String? = "sill/1"
    public init() {}
    public func send(content: Data?, completion: Completion) {
        if let content { sent.append(content) }
        if case .contentProcessed(let callback) = completion { callback(nil) }
    }
}
'''
files['Network.swift'] = network
# OS 가드만 iOS로 선택하며 본문·SessionLink는 수정하지 않는다.
files['iOSClient/StreamClient+SentryReturn.swift'] = files['iOSClient/StreamClient+SentryReturn.swift'].replace(b'#if os(iOS)', b'#if true')
files['iOSClient/StreamClient+Sentry.swift'] = files['iOSClient/StreamClient+Sentry.swift'].replace(b'#if os(iOS)', b'#if true')
def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(marker)
stream = (root / 'iOSClient/StreamClient.swift').read_text()
properties = '\n'.join(block(stream, marker).replace('@Published ', '') for marker in
    ['@Published var connected = false', '@Published var savedMacs: [SavedMac] = []', 'var session: Session? {'])
properties = properties.replace('var connected = false', 'var connected = true').replace('var savedMacs: [SavedMac] = []', 'var savedMacs: [SavedMac] = [SavedMac()]').replace('var session: Session? {', 'var session: Session? = Session() {').replace('#if os(iOS)', '#if true')
assert properties.count('sentryReturnTrustChanged()') == 3
move = block(stream, 'private func finishMoveAfterInputDrain(')
assert move.index('invalidateIPadSentryReturn()') < move.index('link.handOver(')
assert move.index('sentryReturn.bind(ObjectIdentifier(c))') < move.index('link.adopt(')
inactive = block(stream, 'private func wentToBackground()')
assert 'invalidateIPadSentryReturn()' in inactive
ios = stream[stream.index('#else\n        displayView.setPresentationForeground'):]
def notification(name):
    body = block(ios, 'NotificationCenter.default.addObserver(forName: UIApplication.' + name)
    return body[body.index(' _ in') + len(' _ in'):-1].replace('self?', 'self')
resign = notification('willResignActiveNotification')
active = notification('didBecomeActiveNotification')
background = inactive[inactive.index('#if os(iOS)'):inactive.index('        reconnectCheck?.cancel()')]
properties += '\n' + '\n'.join(line.strip() for line in stream.splitlines()
    if line.strip().startswith(('var sentryReturnIsActive', 'var sentryReturnKeyCompletion')))
properties = properties.replace('UIApplication.shared.applicationState == .active', 'true')
assert properties.count('var sentryReturnKeyCompletion') == 1
lifecycle = 'func resignActive() {' + resign + '}\nfunc becomeActive() {' + active + '}\nfunc enterBackground() {' + background + '}\n'
timeout = next(line.strip() for line in stream.splitlines() if 'self.sentryReturn.checkTimeout(' in line or 'self.checkIPadSentryReturnTimeout(' in line)
lifecycle += 'func checkReturnTimeout(now: TimeInterval) { ' + timeout.replace('ProcessInfo.processInfo.systemUptime', 'now') + ' }'

files['Client.swift'] = b'''import Foundation
import Network
import StreamProtocol
enum RemoteTLS {
    static let sessionALPN = "sill/1"
    static func negotiatedALPN(_ peer: NWConnection) -> String? { peer.alpn }
    static func peerFingerprint(_ peer: NWConnection) -> Data? { peer.pin }
}
enum DeviceIdentity {
    struct Identity { let fingerprint: Data }
    static func existing() -> Identity? { .init(fingerprint: Data(repeating: 0xcd, count: 32)) }
}
enum MacID {
    static func make(fingerprint: Data) -> String { fingerprint == Data(repeating: 0xab, count: 32) ? "fixtureMac" : "otherMac" }
}
struct SavedMac {
    var macID = "fixtureMac"
    var fingerprintData: Data? = Data(repeating: 0xab, count: 32)
    var revoked: Bool? = false
    var newKey: Bool? = false
}
final class StreamClient {
    enum Route { case remote, network; var isRemote: Bool { self == .remote } }
    enum Home: Equatable { case saved(pin: Data) }
    struct Session {
        var macID: String? = "fixtureMac"
        var route: Route = .network
        var home: Home? = .saved(pin: Data(repeating: 0xab, count: 32))
    }
    __TRUST_PROPERTIES__
    __LIFECYCLE__
    var visionInputPermit: Int?
    struct Display { func setPresentationForeground(_ value: Bool) {} }
    let displayView = Display()
    func cancelVisionInputs() {}
    func cancelOwnerEnrollment() {}
    var audioRouteAuthorization: Int?
    struct Bootstrap { enum Phase { case ready }; let phase = Phase.ready }
    let ownerBootstrap = Bootstrap()
    func cancelOwnerBootstrap(resumable: Bool) {}

    func refreshExtendedDesktopAdmission() {}
    func ownerEnrollmentTrustChanged() {}
    let link = SessionLink()
    var connection: NWConnection? { get { link.connection } set { link.connection = newValue } }
    var appInForeground = true
    var sentryObservation = IPadSentryObservation()
    var sentryControl = IPadSentryControl(store: .init(load: { nil }, save: { _ in }))
    func acceptIPadSentryReply(_ data: Data, from peer: NWConnection, binding: IPadSentryControl.Binding?) {}
    var sentryReturn = IPadSentryReturn(store: Memory().store)
    var sentryReturnKeyProblem: String?
    var sentryReturnKeys = IPadSentryReturnKeys(store: Memory().store, adapter: .init(
        create: { _ in fatalError("unexpected native key creation") }, sign: { _, _, _ in fatalError("unexpected native sign") }))
    var sentryReturnKeyOperation: IPadSentryReturnKeys.Operation?
    var sentryReturnSubmissions: [UUID: SessionLink.Submission] = [:]
    var sentryReturnDeviceIntent: (reference: SentryReturnReference, peer: ObjectIdentifier)?
}
'''
files['Client.swift'] = files['Client.swift'].replace(b'__TRUST_PROPERTIES__', properties.encode()).replace(b'__LIFECYCLE__', lifecycle.replace('#if os(iOS)', '#if true').encode())
module = ast.parse((root / 'Tests/checks/reconnect-glue/mini.py').read_text())
runner = next(ast.literal_eval(node.value) for node in module.body if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Name) and target.id == 'runner' for target in node.targets))
start = runner.index(" sources=[str(package/'DiscoveryPolicy.swift')")
end = runner.index(" record['commandExitCodes']=[]", start)
commands = ''' flags=['-swift-version','5','-parse-as-library','-module-cache-path',cache]
 protocol=sorted(str(f) for f in (package/'Sources/StreamProtocol').glob('*.swift'))
 consumer=[str(package/('iOSClient/'+n)) for n in ['IPadSentryObservation.swift','IPadSentryControl.swift','IPadSentryReturn.swift','IPadSentryReturnKeys.swift','SessionLink.swift','StreamClient+SentryReturn.swift','StreamClient+Sentry.swift']]
 commands=[['/usr/bin/xcrun','swiftc',*flags,'-emit-module','-emit-object','-whole-module-optimization','-module-name','Network',str(package/'Network.swift'),'-emit-module-path',str(output/'Network.swiftmodule'),'-o',str(output/'Network.o')],
 ['/usr/bin/xcrun','swiftc',*flags,'-emit-module','-emit-object','-whole-module-optimization','-module-name','StreamProtocol',*protocol,'-emit-module-path',str(output/'StreamProtocol.swiftmodule'),'-o',str(output/'StreamProtocol.o')],
 ['/usr/bin/xcrun','swiftc',*flags,'-I',str(output),*consumer,str(package/'Client.swift'),str(package/'Tests/checks/ipad-sentry-return/Main.swift'),str(output/'Network.o'),str(output/'StreamProtocol.o'),'-o',str(output/'consumer')],
 [str(output/'consumer'),str(package/'Tests/checks/sentry-return/fixtures.json')]] + [[str(output/'consumer'),str(package/'Tests/checks/sentry-return/fixtures.json'),mode] for mode in ['lifecycle','late-cancel','cancel-terminal']]
'''
runner = runner[:start] + commands + runner[end:]
runner = runner.replace('CCRReconnect', 'CCRReturn').replace('ccr-reconnect-output-', 'ccr-return-output-')
emitted = {name: sha(data) for name, data in files.items()}
payload = json.dumps({'source': {name: base64.b64encode(data).decode() for name, data in files.items()}, 'hashes': emitted}).encode()
process = subprocess.Popen(['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--',
    'python3', '-B', '-c', runner], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
try:
    log, _ = process.communicate(payload, timeout=600)
except subprocess.TimeoutExpired:
    process.terminate(); log, _ = process.communicate(timeout=30)
(out / (label + '.log')).write_bytes(log)
records = [line[len('RESULT_JSON '):] for line in log.decode(errors='replace').splitlines() if line.startswith('RESULT_JSON ')]
remote = json.loads(records[-1]) if records else None
record = dict(exitCode=process.returncode, sourceHEAD=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    sourceSHA256=original, emittedSHA256=emitted, inputSHA256=sha(payload),
    extractionSHA256={'trustProperties': sha(properties.encode()), 'lifecycle': sha(lifecycle.encode()), 'client': sha(files['Client.swift']), 'runner': sha(runner.encode())},
    sourceUnchanged=all(sha((root / name).read_bytes()) == value for name, value in original.items()),
    inputHashMatched=('INPUT_SHA256 ' + sha(payload)).encode() in log,
    remote=remote, checks=sum(line.startswith('PASS ') and not line.startswith(('PASS total ', 'PASS regression ')) for line in log.decode(errors='replace').splitlines()),
    realKeyCreation=0, biometricUI=0, hostEffects=0, sdkBuild='parent', independentReview='parent',
    scope='실제 consumer/키 adapter/SessionLink. Network는 기록 대역, 키 연산은 알려진 fixture 전용. codex-source-guard 작업 이전 수용과 별도.')
(out / (label + '.json')).write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(log.decode(errors='replace')[-18000:])
print(json.dumps({key: value for key, value in record.items() if key not in ['sourceSHA256', 'emittedSHA256']}, ensure_ascii=False))
sys.exit(0 if process.returncode == 0 and record['sourceUnchanged'] and record['inputHashMatched'] and remote
    and remote.get('sourceRemoved') and remote.get('outputRemoved') and remote.get('memorySourcesUnchanged') else 1)
