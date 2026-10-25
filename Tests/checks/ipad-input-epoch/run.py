"""기기·네트워크 없이 실제 iOS 전송 함수와 공통 permit을 실행한다."""
import importlib.util
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Tests/checks'))
from swift_platform import select_platform

spec = importlib.util.spec_from_file_location('prior', ROOT / 'Tests/checks/vision-input-controls/extract.py')
prior = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prior)
block = prior.block


def fixture():
    stream = (ROOT / 'iOSClient/StreamClient.swift').read_text()
    if '--baseline' in sys.argv or '--baseline-epoch' in sys.argv:
        stream = subprocess.check_output(['git', 'show', 'e564f03c6206f192c84a1a2703d17d43c4ec70a8:iOSClient/StreamClient.swift'], cwd=ROOT, text=True)
    select = lambda s: select_platform(s, vision=False, ios=True)
    markers = ['func sendInput(', 'private func flushPendingMove()', 'private func send(_ kind: StreamMessageKind, _ payload: Data)']
    if '--baseline' not in sys.argv and '--baseline-epoch' not in sys.argv:
        markers += ['private func sendPresentedInput(', 'func captureInputSender()', 'private func sendInput(_ event: InputEvent, binding:']
    core = ['private func replacePresentationConnection(', 'private func invalidatePresentedInput(',
            'private func observeVisionInputCatalog(', 'private func applyVisionInputCatalog(',
            'private func visionPresentationChanged(', 'func cancelVisionInputs(', 'private static func visionInputBytes(']
    current = (ROOT / 'iOSClient/StreamClient.swift').read_text()
    body = '\n'.join(select(block(stream, m)) for m in markers)
    body += '\n' + '\n'.join(select(block(current, m)) for m in core)
    body += '\n' + select(block(current, '@Published private(set) var visionInputBinding =')).replace('@Published private(set) ', '')
    coalescer = stream[stream.index('    // Pointer-move coalescing,'):stream.index('    /// DEBUG: saved Macs seeded')]
    gestures = ''
    if '// MARK: - iPad gesture admission' in current:
        gestures = select(current[current.index('    // MARK: - iPad gesture admission'):current.index("    /// This device's switch for three-finger gestures")])
        gestures += '\n' + block(current, 'func sendGesture(')
        gestures += '\n' + select(block(current, 'private func request(_ source:'))
        gestures += '''
    var connected = true
    var hostGestures: Int? = 1
    static var gesturesOn: Bool { true }
    var explicitSourceIntent: UInt64 = 0
    var selectionRevision: String?
    var sourceCatalogEpoch: UUID?
    enum ExpectedSourceIntent { case source(StreamSource) }
    var expectedSourceIntent: (choice: ExpectedSourceIntent, revision: String?, epoch: UUID?, origin: SourceRequest.Origin)?
    var choicesSent = 0
    final class AudioControl { func sourceWillChange() {} }
    let remoteAudioControl = AudioControl()
    func microphoneSourceWillChange() {}
    func noteAction() {}
    func noteSourceIntent() { explicitSourceIntent &+= 1 }
    func select(_ source: StreamSource) { noteSourceIntent(); request(source) }
'''
    return '''import Foundation
import Network
import StreamProtocol
func CACurrentMediaTime() -> Double { ProcessInfo.processInfo.systemUptime }
final class StreamClient {
    let link = SessionLink()
    let queue = DispatchQueue(label: "ipad.epoch.fixture")
    var inputGeneration: String? = "A"
    var lastInputAt = 0.0
    var appInForeground = true
    var active = StreamSource.desktop
    var windows: [WindowInfo] = []
    var dockApps: [AppInfo] = []
    var visionModernPeer: ObjectIdentifier?
    var visionWireBinding: (peer: ObjectIdentifier, binding: VisionInputBinding)?
    var visionWireSource: StreamSource?
    var visionMediaPS: (epoch: UUID, ps: ParameterSets)?
    var visionInputPermit: UUID?
    let visionInputDebt = VisionInputDebt()
    let displayView = FixtureDisplay()
    var connection: NWConnection? {
        get { link.connection }
        set { replacePresentationConnection(newValue) }
    }
    func pointerNoteSent(_ event: InputEvent) {}
    func catalog(_ list: WindowList, peer: NWConnection) {
        queue.sync { observeVisionInputCatalog(list, from: peer) }
        selectionRevision = list.selectionRevision
        sourceCatalogEpoch = list.videoEpoch?.id
        _ = applyVisionInputCatalog(list, from: peer)
    }
    func ready(_ ticket: VisionPresentation.Ticket?) { visionPresentationChanged(ticket) }
    func cancel() { invalidatePresentedInput() }
    func flush() { queue.sync { flushPendingMove() } }
    func coalesceNextMove() { queue.sync { lastMoveAt = CACurrentMediaTime() + 1 } }
''' + coalescer + gestures.replace('private ', '') + body.replace('private ', '') + '''
}
final class FixtureDisplay {
    var epoch: VideoEpoch?
    var peer: ObjectIdentifier?
    var mainOnly = true
    var onRevoke: (() -> Void)?
    func setPresentation(epoch: VideoEpoch?, peer: ObjectIdentifier?, modern: Bool) {
        mainOnly = mainOnly && Thread.isMainThread
        let changed = self.epoch != epoch || self.peer != peer
        self.epoch = epoch; self.peer = peer
        if changed { onRevoke?() }
    }
}
'''


def main():
    label = sys.argv[1]
    out = ROOT / '.build/checks/ipad-input-epoch' / label
    out.mkdir(parents=True, exist_ok=True)
    sources = {
        'Client.swift': fixture(),
        'Network.swift': (ROOT / 'Tests/checks/vision-input-controls/Network.swift').read_text(),
        'main.swift': (Path(__file__).parent / 'main.swift').read_text(),
    }
    producer_module = importlib.util.spec_from_file_location('producer_fixture', Path(__file__).parent / 'producer.py')
    producer = importlib.util.module_from_spec(producer_module)
    producer_module.loader.exec_module(producer)
    sources['Producer.swift'] = producer.fixture(ROOT, baseline='--producer-baseline' in sys.argv,
        trackpad_baseline='--trackpad-baseline' in sys.argv)
    if '--baseline-epoch' in sys.argv:
        sources['main.swift'] = '''import Foundation
import Network
import StreamProtocol
let client = StreamClient(), peer = NWConnection()
client.connection = peer
let epoch = VideoEpoch(generation: "A", source: .desktop,
    geometry: .init(x: 0, y: 0, width: 800, height: 600), width: 800, height: 600)
client.visionInputBinding = .presented(epoch)
client.sendInput(.text("기준 커밋의 epoch 반례")); client.queue.sync {}
let payload = Data(peer.sent.last!.dropFirst(StreamMessage.headerLength))
let input = Wire.decode(SourceInput.self, from: payload)!
print("기준 iOS 실제 출력 generation=\\(input.generation) videoEpoch=\\(String(describing: input.videoEpoch))")
guard input.videoEpoch == epoch.id else { print("FAIL iOS 실제 전송에 표시 epoch 누락"); exit(1) }
'''
    elif '--baseline' in sys.argv:
        sources['main.swift'] = '''import Foundation
import Network
import StreamProtocol
let client = StreamClient(), peer = NWConnection()
client.connection = peer
client.sendInput(.text("표시 전 입력")); client.queue.sync {}
guard peer.sent.isEmpty else { print("FAIL 현재 프레임 실제 표시 전 iOS 입력 거부"); exit(1) }
'''
    for name, source in sources.items():
        (out / name).write_text(source)
    cache = str(out / 'cache')
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', cache]
    commands = [
        base + ['-parse-as-library', '-emit-module', '-emit-object', '-module-name', 'Network', str(out / 'Network.swift'), '-emit-module-path', str(out / 'Network.swiftmodule'), '-o', str(out / 'Network.o')],
        base + ['-parse-as-library', '-whole-module-optimization', '-emit-module', '-emit-object', '-module-name', 'StreamProtocol'] + [str(p) for p in sorted((ROOT / 'Sources/StreamProtocol').glob('*.swift'))] + ['-emit-module-path', str(out / 'StreamProtocol.swiftmodule'), '-o', str(out / 'StreamProtocol.o')],
        base + ['-I', str(out), str(out / 'Client.swift'), str(out / 'Producer.swift'), str(ROOT / 'iOSClient/SessionLink.swift'), str(ROOT / 'iOSClient/KeyChords.swift'), str(ROOT / 'visionOSClient/VisionInputDebt.swift'), str(ROOT / 'visionOSClient/VisionPresentation.swift'), str(out / 'main.swift'), str(out / 'Network.o'), str(out / 'StreamProtocol.o'), '-o', str(out / 'check')],
        [str(out / 'check')],
    ]
    if '--reuse-modules' in sys.argv:
        modules = Path(sys.argv[sys.argv.index('--reuse-modules') + 1]).resolve()
        assert (modules / 'Network.swift').read_text() == sources['Network.swift']
        for path in (ROOT / 'Sources/StreamProtocol').glob('*.swift'):
            assert path.read_bytes() == subprocess.check_output(['git', 'show', 'HEAD:' + str(path.relative_to(ROOT))], cwd=ROOT)
        commands = [[str(modules / 'cache') if part == str(out / 'cache') else str(modules) if part == str(out) else str(modules / Path(part).name)
                     if part in [str(out / 'Network.o'), str(out / 'StreamProtocol.o')] else part
                     for part in command] for command in commands[2:]]
    before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [
        ROOT / 'iOSClient/StreamClient.swift', ROOT / 'iOSClient/SessionLink.swift', ROOT / 'visionOSClient/VisionInputDebt.swift',
        ROOT / 'visionOSClient/VisionPresentation.swift', ROOT / 'iOSClient/InputOverlay.swift', ROOT / 'iOSClient/TrackpadView.swift',
        ROOT / 'iOSClient/StreamScreen.swift', ROOT / 'iOSClient/PortraitStreamScreen.swift']}
    results = []
    for index, command in enumerate(commands):
        run = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        (out / f'{index}.log').write_text(run.stdout)
        results.append({'phase': index, 'exitCode': run.returncode})
        print(run.stdout, end='')
        if run.returncode: break
    record = {'commands': results, 'sourceSHA256': before,
              'generatedSHA256': {name: hashlib.sha256(source.encode()).hexdigest() for name, source in sources.items()},
              'sourceUnchanged': all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in before.items()),
              'scope': '실제 iOS 함수 추출과 메모리 전송 어댑터. UIKit·실제 디코더·기기 수용 증거 아님.'}
    (out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    return int(results[-1]['exitCode'] != 0)


if __name__ == '__main__':
    sys.exit(main())
