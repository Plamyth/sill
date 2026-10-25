"""Vision 생산 어댑터·갱신 타이머를 공개 fixture와 메모리 I/O로만 실행한다."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
IPAD = ROOT / 'iOSClient/Tests/owner-enrollment'
sys.path.insert(0, str(HERE.parent))
from swift_platform import select_platform

def vision(text):
    return select_platform(text.replace('os(iOS) || os(visionOS)', 'os(visionOS)'), vision=True)

with tempfile.TemporaryDirectory(prefix='vision-enrollment-', dir=HERE) as folder:
    out = Path(folder)
    common = ['swiftc', '-swift-version', '5', '-module-cache-path', str(out / 'cache')]
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(out / 'cache'))
    protocol = ['RemoteIdentity.swift', 'AudioRouting.swift', 'StreamMessage.swift', 'OwnerMacBootstrap.swift', 'AddressParser.swift']
    subprocess.run(common + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        *[str(ROOT / 'Sources/StreamProtocol' / p) for p in protocol], '-o', str(out / 'libStreamProtocol.dylib')], check=True, env=env, timeout=180)
    runtime = (IPAD / 'runtime.swift').read_text()
    extra = '''
    var visionStartupForeground = true
    var visionWindowRetired = false
    struct Selection { var lease: VisionWindowLease? = .init(window: UUID()) }
    var visionDisplaySelection = Selection()
    var ownerEnrollmentLease: VisionWindowLease?
    var ownerEnrollmentChanged: ((Result<P.Credential, Error>?) -> Void)?
    enum DialReason { case tap }
    var dials: [String] = []
    func dialSaved(_ id: String, why: DialReason) { dials.append(id) }
'''
    runtime = runtime.replace('    var appInForeground = true', extra + '    var appInForeground = true')
    runtime += '''
enum VisionReleaseTestContext { static var isTestBundle = false }
enum SavedMacs {
    static func automaticTarget(_ rows: [StreamClient.Saved], preferredID: String?) -> StreamClient.Saved? {
        rows.first { $0.macID == preferredID && $0.homeTLS == true && $0.revoked != true && $0.newKey != true && $0.fingerprintData != nil }
    }
}
'''
    runtime = runtime.replace('"/v1/snapshot"', '"/v1/events"').replace('"/v1/catalog"', '"/v1/events"')
    spec = importlib.util.spec_from_file_location('move_extractor', ROOT / 'Tests/checks/vision-autoconnect/run.py')
    extractor = importlib.util.module_from_spec(spec); spec.loader.exec_module(extractor)
    stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
    moves = '\n'.join(vision(extractor.block(stream, marker)).replace('private func ', 'func ') for marker in ['private func finishMove(', 'private func finishMoveAfterInputDrain('])
    runtime = runtime.replace('    var appInForeground = true', (HERE / 'move-standins.swift').read_text() + '\n' + moves + '\n    var appInForeground = true')
    old = '    var connection: NWConnection? { didSet { if oldValue !== connection { cancelOwnerEnrollment() } } }'
    assert runtime.count(old) == 1
    runtime = runtime.replace(old, '    let link = SessionLink()\n    var connectionSetterCalls = 0\n    var connection: NWConnection? {\n        get { link.connection }\n        set { connectionSetterCalls += 1; if link.connection !== newValue { cancelOwnerEnrollment() }; link.connection = newValue }\n    }')
    runtime = runtime.replace('struct Session { var macID: String? }', 'struct Session {\n        var macID: String?\n        var route = MemorySessionRoute.network\n        var candidate: Int?\n        var bonjourName: String?\n        var home: Int?\n        var row: Int?\n        var endpoint: Int?\n    }')
    runtime = runtime.replace('    var state: State = .ready', '    enum Completion { case contentProcessed((Error?) -> Void) }\n    var sent: [Data] = []\n    let endpoint = 1, currentPath = 1\n    func send(content: Data?, completion: Completion) {\n        if let content { sent.append(content) }\n        if case .contentProcessed(let done) = completion { done(nil) }\n    }\n    func cancel() { state = .cancelled }\n    func forceCancel() { cancel() }\n    var state: State = .ready')
    runtime = runtime.replace('    static func automaticTarget', '    static func seenOverTLS(_ ids: [String], in rows: [StreamClient.Saved]) -> [StreamClient.Saved]? { nil }\n    static func automaticTarget')
    runtime += '\nstruct MemorySessionRoute { var isRemote = false; static let network = Self() }\nenum MemorySource { case none, screen }\nfinal class MemoryMoveInput {\n    var moves: [Bool] = []\n    var releases = 0\n    func setMoving(_ value: Bool) { moves.append(value) }\n    func takeReleases() -> [Int] { releases += 1; return [] }\n}\nfinal class MemoryPointerFeed { func handedOver() -> Bool { false } }\nfinal class MemoryMoveSettings { var resets = 0; func reset() { resets += 1 } }\nenum DiscoveryPolicy { struct HomeMoveInfo {} }\n'
    (out / 'runtime.swift').write_text(runtime)
    (out / 'SessionLink.swift').write_text((ROOT / 'iOSClient/SessionLink.swift').read_text().replace('import Network\n', ''))
    extension = vision((ROOT / 'iOSClient/StreamClient+OwnerEnrollment.swift').read_text())
    extension = extension.replace('import Network\n', '').replace('import Security\n', '')
    clock = 'now: { Int64(Date().timeIntervalSince1970 * 1000) }'
    assert extension.count(clock) == 1
    extension = extension.replace(clock, 'now: { runtimeMemory!.now }')
    (out / 'extension.swift').write_text(extension)
    renewal = (IPAD / 'renewal.swift').read_text().replace('"/v1/catalog"', '"/v1/events"')
    renewal = renewal.replace('        let stream = StreamClient()', '''        let stream = StreamClient()
        var scheduled: [DispatchWorkItem] = []
        let control = MainActor.assumeIsolated {
            VisionControlEnrollmentController(events: ControlEventsController(stream: { _ in fatalError("실제 네트워크 금지") }),
                client: stream, now: { Double(memory.now) / 1000 }, schedule: { delay, work in
                    precondition(delay > 0); scheduled.append(work)
                })
        }
''')
    renewal = renewal.replace('        memory.now = initial + 3_600_001\n        stream.resumeOwnerEnrollment()', '''        try check(scheduled.count == 1, "화면·대화·401 없이 자격 만료 타이머 하나")
        memory.now = initial + 3_600_001
        scheduled[0].perform()
''')
    renewal = renewal.replace('        stream.cancelOwnerEnrollment()', '        _ = control\n        stream.cancelOwnerEnrollment()')
    (out / 'renewal.swift').write_text(renewal)
    main = (IPAD / 'main.swift').read_text() + '\ntry MainActor.assumeIsolated { try visionChecks(); try moveChecks() }\n'
    (out / 'main.swift').write_text(main)
    fixture = json.loads((IPAD / 'fixtures/device-enrollment-readback-golden.json').read_text())
    payload = json.loads(base64.urlsafe_b64decode(fixture['enrollRequest']['ownerReceipt']['payload'] + '==='))
    profile = dict(schema='ccr.owner-mac-bootstrap/v1', macID=payload['macID'], fingerprint=payload['macFingerprint'], addresses=['100.100.100.100'], remotePort=52342)
    profile_path = out / 'synthetic-owner-profile.json'
    profile_path.write_text(json.dumps(profile))
    lease = (ROOT / 'visionOSClient/VisionCableBootstrap.swift').read_text().split('enum VisionCableBootstrapReason')[0]
    (out / 'lease.swift').write_text(lease)
    sources = [ROOT / 'iOSClient' / p for p in ['IPadEnrollmentJSON.swift', 'IPadEnrollmentProtocol.swift', 'IPadDeviceEnrollment.swift']]
    sources += [ROOT / 'visionOSClient' / (p + '.swift') for p in ['ControlEventsModel', 'ControlEventsReducer', 'ControlEventsSSEParser', 'ControlEventsCodec', 'ControlEventsProjection', 'ControlEventsTransport', 'ControlEventsController', 'VisionControlEnrollment']]
    sources += [out / p for p in ['main.swift', 'runtime.swift', 'renewal.swift', 'extension.swift', 'lease.swift', 'SessionLink.swift']]
    sources += [IPAD / 'signed-payload.swift', HERE / 'vision.swift', HERE / 'move.swift']
    subprocess.run(common + ['-I', str(out), '-L', str(out), '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, sources), '-o', str(out / 'checks')], check=True, env=env, timeout=180)
    subprocess.run([str(out / 'checks'), str(IPAD / 'fixtures'), str(profile_path)], check=True, env=env, timeout=60)
